#include "../platform/native_gl.h"
#include "../platform/desktop_host_api.h"
#include "../utils/product_diagnostics.h"
// glfw_compat.cpp — GLFW 兼容层核心实现
// 职责：GLFW 核心 API（init/createWindow/pollEvents/swap 等）
// EGL → glfw_egl.cpp | 回调/stub → glfw_callbacks.cpp | JNI → glfw_jni.cpp

#include "glfw_internal.h"
#if !AMCL_NATIVE_DESKTOP_ONLY
#include "amcl_mg_source_identity.h"
#endif
// ⚰️ 这里曾 #include "glfw_osmesa.h"（zink/OSMesa 上屏）。zink 已完全退役，
//    本文件的 17 处 zink 分支已于 2026-08-27 摘除，见施工记录 §S7；
//    恢复索引 prebuilt/mesa-zink/integration-archive/README.md。
#include "ohos_render_scheduler.h"
#include "ohos_surface_state.h"
#include "../input/adapters/backend_input_bridge.h"
#include "../input/adapters/glfw_input_adapter.h"
#include "../input/adapters/glfw_source_plane_aggregate.h"
#include "../input/adapters/glfw_typed_absolute_route.h"
#include "../input/adapters/glfw_typed_input_resolve_guard.h"
#include "../input/adapters/glfw_typed_runtime_dispatch.h"
#include "../input/adapters/glfw_input_mode.h"
#include "../input/adapters/glfw_typed_look_route.h"
#include "../input/amcl_input_host_descriptor.h"
#include "../input/text_utf8_codec.h"
#include "../platform/physical_wheel_quantizer.h"
#include "../platform/graphics_observation_abi.h"
#include "utils/stack_sampler.h"
#if !AMCL_NATIVE_DESKTOP_ONLY
#include "../platform/gl_host.h"
#endif
#include <hilog/log.h>
#include <native_window/external_window.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <mutex>
#include <shared_mutex>
#include <string>
#include "egl_dispatch.h"
#include "../platform/window_host.h"
#include "../platform/graphics_backend_session.h"
#include "../platform/vulkan_wsi.h"
#include "../utils/amcl_log_bridge.h"

#undef LOG_TAG
#define LOG_TAG "GLFW_COMPAT"

// Forward declarations from input_bridge_ohos.c
typedef void (*GLFW_invoke_CursorPos_func_t)(void* window, double xpos, double ypos);
typedef void (*GLFW_invoke_MouseButton_func_t)(void* window, int button, int action, int mods);
typedef void (*GLFW_invoke_Key_func_t)(void* window, int key, int scancode, int action, int mods);
typedef void (*GLFW_invoke_Scroll_func_t)(void* window, double xoffset, double yoffset);

extern "C" {
    void inputBridgeStartPumping(void);
    void inputBridgePumpEvents(void* window);
    void inputBridgeStopPumping(void);
    void inputBridge_notifyFramePresented(void);
    void inputBridge_cancelMenuTransaction(void* window);
    void inputBridge_cancelAllState(void* window, int reason);
    void inputBridge_setWindowSize(int w, int h);
    void inputBridge_publishAddress(void);
    void inputBridge_setCursorPosCallback(GLFW_invoke_CursorPos_func_t cb);
    void inputBridge_setMouseButtonCallback(GLFW_invoke_MouseButton_func_t cb);
    void inputBridge_setKeyCallback(GLFW_invoke_Key_func_t cb);
    void inputBridge_setScrollCallback(GLFW_invoke_Scroll_func_t cb);
    void inputBridge_dispatchCursorEnter(void* window, int entered);
    void inputBridge_dispatchCharCodepoint(
        void* window, unsigned int codepoint);
    // ⭐ grab 的**跨后端**权威状态：唯一写者是 `inputBridge_setGrabState`，而三条消费链
    // 全都经它（GLFW3 经 `glfwSetInputMode`，LWJGL2 与 SDL 各经自己的 grab 出口）。
    // ⇒ 本文件里唯一一个"MC 是否要 grab"的后端中立答案，且 delegate-aware。
    bool inputBridge_isGrabbing(void);
}

// Touch event counter (used in glfwPollEvents DIAG)
static int g_touchTotalCount = 0;

// ==================== 全局状态（声明在 glfw_internal.h）====================
GLFWwindow* g_currentWindow = nullptr;
static std::atomic<uint64_t> g_desktopPolledEpoch{0};
static std::atomic<uint64_t> g_windowLifetime{0};
// GLFW current-context state is per-thread.  g_currentWindow remains the one
// application window used by the input bridge; it must not be cleared merely
// because one render thread logically releases its context.
static thread_local GLFWwindow* g_threadCurrentContext = nullptr;
// 创建/销毁与current转移串行化，避免两个线程同时通过“owner=0”的检查。swap不持此锁。
static std::recursive_mutex g_contextLifecycleMutex;
static std::vector<GLFWwindow*> g_windows;
static bool g_hintVisible = true;
GLFWerrorfun g_errorCallback = nullptr;
int g_initialized = 0;
static auto g_startTime = std::chrono::steady_clock::now();

// 窗口 hint 缓存
// DSO 装载早于图形计划发布；禁止全局构造期间绑定默认 provider。glfwInit 后再设定缺省 hint。
int g_hintClientAPI = GLFW_OPENGL_ES_API;
int g_hintMajor = 3;
int g_hintProfile = 0;
bool g_hintForwardCompatible = false;
int g_hintMinor = 0;

// OHOS 扩展状态
// The host DSO owns NativeWindow state. This small per-libglfw marker only
// identifies the XComponent image that is allowed to republish input routes.
static std::atomic<uint64_t> g_inputPublisherPid{0};
static std::atomic<uint64_t> g_inputPublisherGeneration{0};
static std::once_flag g_runtimeImageIdentityOnce;

static void logRuntimeImageIdentity() {
    std::call_once(g_runtimeImageIdentityOnce, []() {
        Dl_info info {};
        const void *self = reinterpret_cast<const void *>(&glfwInit);
        const char *imagePath = "unresolved";
        if (dladdr(self, &info) != 0 && info.dli_fname != nullptr) {
            imagePath = info.dli_fname;
        }

        struct stat imageStat {};
        const bool haveStat = std::strcmp(imagePath, "unresolved") != 0 &&
                              stat(imagePath, &imageStat) == 0;
        int mappedImages = -1;
        FILE *maps = std::fopen("/proc/self/maps", "r");
        if (maps != nullptr) {
            mappedImages = 0;
            char line[2048];
            while (std::fgets(line, sizeof(line), maps) != nullptr) {
                unsigned long long start = 0;
                unsigned long long end = 0;
                unsigned long long offset = 0;
                unsigned long long inode = 0;
                char permissions[8] = {};
                char device[32] = {};
                char path[1024] = {};
                const int fields = std::sscanf(
                    line, "%llx-%llx %7s %llx %31s %llu %1023[^\n]",
                    &start, &end, permissions, &offset, device, &inode, path);
                if (fields == 7 && offset == 0 &&
                    std::strstr(path, "libglfw.so") != nullptr) {
                    ++mappedImages;
                }
            }
            std::fclose(maps);
        }

#if AMCL_NATIVE_DESKTOP_ONLY
        OH_LOG_INFO(LOG_APP, "GLFW system OpenGL image=%{public}s mappings=%{public}d host=%{public}s", imagePath, mappedImages, AMCL_HOST_BUILD_IDENTITY);
#else
        OH_LOG_INFO(LOG_APP,
                    "GLFW/MG image self=%{public}p path=%{public}s dev=%{public}llu "
                    "inode=%{public}llu mappedImages=%{public}d mg_head=%{public}s "
                    "mg_tree=%{public}s mg_dirty=%{public}d mg_build=%{public}s "
                    "host=%{public}s",
                    self, imagePath,
                    haveStat ? static_cast<unsigned long long>(imageStat.st_dev) : 0ULL,
                    haveStat ? static_cast<unsigned long long>(imageStat.st_ino) : 0ULL,
                    mappedImages, AMCL_MG_SOURCE_COMMIT, AMCL_MG_WORKTREE_SHA256,
                    AMCL_MG_WORKTREE_DIRTY, AMCL_MG_BUILD_IDENTITY,
                    AMCL_HOST_BUILD_IDENTITY);
#endif
        if (mappedImages > 1) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                        "multiple libglfw mappings observed; compare each glfwInit image "
                        "address/path/dev/inode before claiming one runtime instance");
        }
    });
}

struct BackendSessionHandle {
    std::shared_ptr<amcl::graphics::AbiNativeWindowBroker> broker;
    std::shared_ptr<amcl::graphics::BackendAdapter> adapter;
    std::unique_ptr<amcl::graphics::BackendSession> session;
    bool presentRecordFailureLogged = false;
};
static std::atomic<uint64_t> g_nextBackendSessionId{1};

static amcl::graphics::BackendAdapterCallbacks makeGraphicsSessionCallbacks(GLFWwindow* window) {
    amcl::graphics::BackendAdapterCallbacks callbacks;
    callbacks.prepare = [window](std::string& error) {
        if (!window || window->clientAPI == GLFW_NO_API) {
            error = "EGL adapter requires an OpenGL window";
            return false;
        }
        return true;
    };
    callbacks.attach = [window](const amcl::graphics::NativeWindowLease& lease, std::string& error) {
        window->nativeWindow = lease.nativeWindow;
        window->nativeWindowGeneration = lease.generation;
        window->width = lease.width;
        window->height = lease.height;
        const bool ready = window->context != EGL_NO_CONTEXT ?
            AttachEGLSurface(window, lease.nativeWindow, lease.width, lease.height) : InitEGL(window);
        if (!ready) { error = "EGL context/surface initialization failed"; return false; }
        window->contextOwnerTid = static_cast<int>(gettid());
        return true;
    };
    callbacks.resourcesCreated = [window](std::string& error) {
        if (window->display == EGL_NO_DISPLAY || window->context == EGL_NO_CONTEXT || window->surface == EGL_NO_SURFACE) {
            error = "EGL resource commit requires a real context and surface";
            return false;
        }
        return true;
    };
    callbacks.resourcesRetired = [window](std::string& error) {
        if (window->display != EGL_NO_DISPLAY || window->context != EGL_NO_CONTEXT || window->surface != EGL_NO_SURFACE) {
            error = "EGL resource retirement requires completed teardown";
            return false;
        }
        return true;
    };
    callbacks.resize = [window](int width, int height, std::string& error) {
        if (width <= 0 || height <= 0) { error = "invalid EGL surface dimensions"; return false; }
        if (window->contextOwnerTid && window->contextOwnerTid != static_cast<int>(gettid())) {
            error = "geometry update must execute on the context owner thread"; return false;
        }
        window->width = width;
        window->height = height;
        return true;
    };
    callbacks.suspend = [window](std::string& error) {
        if (!SuspendEGLSurface(window)) { error = "EGL surface suspension failed"; return false; }
        window->eglSurfaceDetachPending = false;
        return true;
    };
    callbacks.resume = [window](const amcl::graphics::NativeWindowLease& lease, std::string& error) {
        if (!AttachEGLSurface(window, lease.nativeWindow, lease.width, lease.height)) {
            error = "EGL replacement surface attachment failed";
            return false;
        }
        window->nativeWindowGeneration = lease.generation;
        return true;
    };
    callbacks.detach = callbacks.suspend;
    callbacks.destroy = [window](bool, std::string& error) {
        if (!TerminateEGL(window)) { error = "EGL teardown failed; handles and ownership retained"; return false; }
        return true;
    };
    return callbacks;
}

static bool attachGraphicsBackendSession(GLFWwindow* window) {
    if (!window) return false;
    if (window->clientAPI == GLFW_NO_API) return true;
    if (window->graphicsBackendSession) return false;
    if (!window->nativeWindowLeaseBroker || !window->nativeWindowLeaseObject || window->nativeWindowGeneration == 0) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: OpenGL session requires a published NativeWindow lease broker");
        return false;
    }
    auto* handle = new BackendSessionHandle();
    const auto* abi = static_cast<const AmclNativeWindowLeaseBrokerV2*>(window->nativeWindowLeaseBroker);
    handle->broker = std::make_shared<amcl::graphics::AbiNativeWindowBroker>(abi, 1u);
    const auto* boundRuntime = amcl::graphics::BoundGraphicsRuntime();
    const char* selectedProfile = boundRuntime ? boundRuntime->profile->id : nullptr;
    auto callbacks = makeGraphicsSessionCallbacks(window);
    if (selectedProfile && (strcmp(selectedProfile, "mobilegl") == 0 || strcmp(selectedProfile, "mobileglues") == 0 || strcmp(selectedProfile, "gl4es") == 0)) {
        handle->adapter = std::make_shared<amcl::graphics::MobileGlBackendSessionAdapter>(std::move(callbacks));
    } else {
        handle->adapter = std::make_shared<amcl::graphics::SystemOpenGLBackendSessionAdapter>(std::move(callbacks));
    }
    handle->session = std::make_unique<amcl::graphics::BackendSession>(
        g_nextBackendSessionId.fetch_add(1, std::memory_order_relaxed),
        selectedProfile ? selectedProfile : "system-opengl", handle->broker, handle->adapter);
    // Store the handle before the first EGL operation, including partial init.
    // A failed cleanup leaves an owned window reachable by glfwTerminate.
    window->graphicsBackendSession = handle;
    std::string error;
    if (!handle->session->prepare(error) || !handle->session->attach(error) ||
        !handle->session->markResourcesCreated(error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: BackendSession attach refused: %{public}s", error.c_str());
        return false;
    }
    return true;
}

static bool destroyGraphicsBackendSession(GLFWwindow* window, bool resourcesDestroyed) {
    if (!window || !window->graphicsBackendSession) return true;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    const uint64_t generation = handle->session->generation();
    std::string error;
    if (!handle->session->destroy(resourcesDestroyed, error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: BackendSession destruction retained owner: %{public}s", error.c_str());
        return false;
    }
    OH_LOG_INFO(LOG_APP,
        "graphics_gl_session_destroyed windowId=%{public}llu profile=%{public}s generation=%{public}llu presentCount=%{public}llu",
        static_cast<unsigned long long>(window->windowId), handle->session->profile().c_str(),
        static_cast<unsigned long long>(generation), static_cast<unsigned long long>(handle->session->presentCount()));
    delete handle;
    window->graphicsBackendSession = nullptr;
    return true;
}

static void recordGraphicsBackendSessionPresent(GLFWwindow* window) {
    if (!window || window->clientAPI == GLFW_NO_API || !window->graphicsBackendSession) return;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    if (!handle->session->recordPresent(error)) {
        if (!handle->presentRecordFailureLogged) {
            handle->presentRecordFailureLogged = true;
            AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: successful EGL swap could not be recorded: %{public}s", error.c_str());
        }
        return;
    }
    if (handle->session->presentCount() == 1) {
        OH_LOG_INFO(LOG_APP,
            "graphics_gl_first_present windowId=%{public}llu profile=%{public}s generation=%{public}llu presentCount=1",
            static_cast<unsigned long long>(window->windowId), handle->session->profile().c_str(),
            static_cast<unsigned long long>(handle->session->generation()));
    }
}

static bool markGraphicsBackendSessionResources(GLFWwindow* window) {
    if (!window || !window->graphicsBackendSession) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    if (!handle->session->markResourcesCreated(error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: graphics resource commit rejected: %{public}s", error.c_str());
        return false;
    }
    return true;
}
static bool suspendGraphicsBackendSession(GLFWwindow* window) {
    if (!window || !window->graphicsBackendSession) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    if (!handle->session->suspend(error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: session suspend rejected: %{public}s", error.c_str());
        return false;
    }
    return true;
}
static bool resumeGraphicsBackendSession(GLFWwindow* window) {
    if (!window || !window->graphicsBackendSession) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    if (!handle->session->resume(error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: session resume rejected: %{public}s", error.c_str());
        return false;
    }
    return true;
}
static bool resizeGraphicsBackendSession(GLFWwindow* window, int width, int height, uint64_t generation) {
    if (!window || !window->graphicsBackendSession) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    if (!handle->session->resize(width, height, generation, error)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: session resize rejected: %{public}s", error.c_str());
        return false;
    }
    return true;
}

extern "C" int glfwOHOS_GetWindowClientAPI(const GLFWwindow* window) {
    return window ? window->clientAPI : -1;
}
extern "C" uint64_t glfwOHOS_GetWindowId(const GLFWwindow* window) {
    return window ? window->windowId : 0;
}
bool glfwOHOS_BeginGraphicsSession(GLFWwindow* window, const char* api,
                                   void* nativeWindow, uint64_t generation) {
    if (!window || !window->graphicsBackendSession || !nativeWindow || generation == 0 ||
        !api || !*api) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    amcl::graphics::NativeWindowLease expected{nativeWindow, generation, window->width, window->height, false};
    std::string error;
    if (handle->session->state() == amcl::graphics::BackendSessionState::kPrepared ||
        handle->session->state() == amcl::graphics::BackendSessionState::kDetached) {
        return handle->session->attach(expected, error);
    }
    return handle->session->generation() == generation && handle->session->lease().nativeWindow == nativeWindow;
}

void glfwOHOS_GraphicsSurfaceCreated(GLFWwindow* window) { (void)markGraphicsBackendSessionResources(window); }

bool glfwOHOS_GraphicsSurfaceRetired(GLFWwindow* window) {
    if (!window || !window->graphicsBackendSession) return false;
    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    std::string error;
    return handle->session->markResourcesRetired(error);
}

bool glfwOHOS_EndGraphicsSession(GLFWwindow* window, bool resourcesDestroyed) {
    return destroyGraphicsBackendSession(window, resourcesDestroyed);
}

bool glfwOHOS_GraphicsSessionHasSurface(const GLFWwindow* window) {
    if (!window || !window->graphicsBackendSession) return false;
    const auto* handle = static_cast<const BackendSessionHandle*>(window->graphicsBackendSession);
    return handle->session->hasResources();
}

class ScopedNativeWindowLease {
public:
    ScopedNativeWindowLease(void* nativeWindow, void* broker)
        : nativeWindow_(nativeWindow), broker_(broker) {}
    ~ScopedNativeWindowLease() {
        if (nativeWindow_ && broker_) {
            glfwOHOS_ReleaseNativeWindowLease(nativeWindow_, broker_);
        }
    }

    void* detachBroker() {
        void* broker = broker_;
        nativeWindow_ = nullptr;
        broker_ = nullptr;
        return broker;
    }

private:
    void* nativeWindow_;
    void* broker_;
};

static void releaseWindowNativeWindowLease(GLFWwindow* window) {
    if (!window || !window->nativeWindowLeaseBroker) return;
    void* leasedObject = window->nativeWindowLeaseObject;
    void* leaseBroker = window->nativeWindowLeaseBroker;
    window->nativeWindowLeaseObject = nullptr;
    window->nativeWindowLeaseBroker = nullptr;
    if (!leasedObject) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: NativeWindow lease broker had no retained object");
        return;
    }
    glfwOHOS_ReleaseNativeWindowLease(leasedObject, leaseBroker);
}

static void adoptWindowNativeWindowLease(GLFWwindow* window,
                                         void* nativeWindow,
                                         ScopedNativeWindowLease& lease) {
    if (!window || !nativeWindow) return;
    void* broker = lease.detachBroker();
    if (!broker) return;
    releaseWindowNativeWindowLease(window);
    window->nativeWindowLeaseObject = nativeWindow;
    window->nativeWindowLeaseBroker = broker;
}

// 统计
int g_swapCount = 0;
int g_pollCount = 0;

// MC 退出检测：最后一次 swap 的时间戳
// 出帧线程写、诊断线程读；原子时间戳避免停帧判据跨线程出现数据竞争。
static std::atomic<long long> g_lastSwapTimeMs{0};
static long long currentTimeMs() {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
}

// 既有退出检测和兼容诊断只需要计数及最后呈现时间；统一帧分布由中立运行时维护。
// 此处不排序、不拼JSON、不输出日志，避免开启诊断后在渲染线程引入周期性尖峰。
static void observePresentedFrame() {
    g_swapCount++;
    g_lastSwapTimeMs = currentTimeMs();
}

// cursor mode
int g_cursorMode = GLFW_CURSOR_NORMAL;

// MC 退出回调
static glfwOHOS_WindowDestroyCallback g_windowDestroyCallback = nullptr;

// shouldClose 日志标志（需要在 glfwInit 中重置）
static bool s_loggedClose = false;

// ==================== Input bridge → GLFWwindow callback wrappers ====================
static std::atomic<uint64_t> g_invalidCursorPositionCallbackCount{0u};
static void bridgeCursorPosCallback(void* window, double xpos, double ypos) {
    if (!std::isfinite(xpos) || !std::isfinite(ypos)) {
        const uint64_t count = g_invalidCursorPositionCallbackCount.fetch_add(
                                   1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            AMCL_EXTERNAL_LOG_E(LOG_TAG,
                "GLFW: cursor callback rejected non-finite position count=%{public}llu",
                static_cast<unsigned long long>(count));
        }
        return;
    }
    GLFWwindow* win = (GLFWwindow*)window;
    if (!win) win = g_currentWindow;
    if (win) {
        win->cursorX = xpos;
        win->cursorY = ypos;
        if (win->cursorPosCb) win->cursorPosCb(win, xpos, ypos);
    }
}

// The typed adapter already aggregates physical contributors, while the legacy
// ring aggregates virtual/touch owners. This final mapped-control ledger owns
// coexistence between those two source planes. Its sink runs after the ledger
// lock is released, so Minecraft callbacks may synchronously reenter GLFW.
static amcl::input::GlfwSourcePlaneAggregate g_sourcePlaneAggregate;

// GLFW 语义下 `mods` 是**事件发生那一刻的修饰键状态**，由 GLFW 自己从按键状态推出，
// 而不是由事件生产者携带。我们此前把它一路写死成 0：
//     sendEvent(EVENT_TYPE_KEY,          code, 0, action, 0);
//     sendEvent(EVENT_TYPE_MOUSE_BUTTON, code, action, 0, 0);
// 于是 MC 收到的每一个键/鼠标事件都声称"没有任何修饰键按下"。
//
// 这是一处确定的保真缺陷（不是推断）：桌面端 shift+左键在创造物品栏取整组物品，
// 而我们这边它退化成普通取一个 —— 现象与"修饰符丢失"完全一致。
//
// 修法就是按 GLFW 的定义来：在分发点从**权威的轮询状态** `win->keys[]` 现算。
// 这样 mods 与 `glfwGetKey` 必然自洽，不可能出现"轮询说按着、事件说没按"的分裂。
// 键码取值见 GlfwKeys.ets：340/344=SHIFT，341/345=CONTROL，342/346=ALT，343/347=SUPER。
//
// ⚠️ 两个分发点曾写作 `event.modifiers != 0 ? event.modifiers : currentModifierMask(win)`
// （"生产者若已给出非零 mods 则以它为准"）。**那个 fallback 破坏了上一段亲口承诺的
// 那条不变量**，2026-08-20 已删除，理由三条：
//
//   1. **它用 `0` 当"生产者没给"的哨兵**，而 `0` 是一个合法值（没按任何修饰键）。
//      本项目在 `AMCL_LOCK_STATE_VALID` 那里已经为同一个问题付过学费 ——
//      那个位存在的全部理由就是"0 无法区分'三个锁存都关'和'平台没报告'"。
//   2. **跨生产者会丢修饰键。** `win->keys[]` 由 aggregate 为**两个 source plane**
//      共同维护，所以它同时包含物理键盘、屏幕虚拟 Shift 按钮（`routerKey` 也写它）、
//      手柄映射键。生产者的 `modifiersSnapshot` 只知道**它自己那一路**。
//      "物理 Shift + 屏幕虚拟 Ctrl"会因为走进生产者分支而丢掉 Ctrl ——
//      而 §42.3 声称"纯触摸玩家用屏幕 Shift 键也能取整组"，那条声称只在
//      生产者 mods 恒为 0 时才成立。
//   3. **锁存位会漏进去。** ArkTS 的 `composeGlfwMods` 会置 `GLFW_MOD_CAPS_LOCK` /
//      `GLFW_MOD_NUM_LOCK`，而真 GLFW 默认**不上报**锁存位（`GLFW_LOCK_KEY_MODS` 默认关闭，
//      MC 从不打开它）——见 §42.6。走生产者分支会让 MC 收到桌面端不会收到的位。
//
// 触发条件很明确：legacy 平面的 mods 恒为 0（ledger emit 写死 0，真机
// `AMCL_KBD leftPress modsIn=0x0 modsOut=0x1` 已确认），所以**今天不可达**；
// 而 typed 平面的 `glfw_input_adapter` **确实**把 `modifiersSnapshot` 一路传到 sink，
// 所以 `AMCL_GLFW_TYPED_PHYSICAL_DEFAULT`（当前产品构建为 `0`）一旦打开就立即生效。
// 也就是说这是一条**潜伏在计划路径上**的缺陷：它会在 typed 迁移那一轮同时破坏
// 上面两条已验收的行为，而两者都不会编译报错、不会抛异常。
//
// 现在的规则是无条件的：**mods 永远由 `currentModifierMask(win)` 现算。**
//
// ⚠️ **本文件一共有四个会带 mods 的回调调用点，四个都必须遵守这条规则**（清单钉在这里，
// 因为 2026-08-20 第一次修的时候只改了前两个）：
//   1. `dispatchAggregateKey`   → `win->keyCb(...)`         （legacy + typed 键都走它）
//   2. `dispatchAggregateButton`→ `win->mouseButtonCb(...)` （legacy 按钮）
//   3. `typedButtonSink` 的 **unbound** 分支 → `callback(...)`（typed 按钮，无需绝对授权）
//   4. `typedButtonSink` 的 **授权** 分支   → `callback(...)`（typed 按钮，三元组授权后）
// 第 5 个回调点是 cursorPos，它没有 mods 参数。
//
// 第一次修复漏掉 3 与 4 的原因值得记：我按"aggregate 的 sink 有几个"去找，
// 而 3/4 **不经过 sink** —— typed 绝对路由有它自己的 commit/notify 对。
// 正确的搜法是按 **"callback 被调用了几次"** 穷举（`keyCb(` / `mouseButtonCb(` /
// `callback(callbackWindow`），而不是按抽象层级去推。
// 代价是一个边界情形 —— 若某个修饰键的 DOWN 我们从未收到（例如失焦期间按下的 Shift），
// 平台的 `modifiersSnapshot` 会比我们准。但那种情况下 `glfwGetKey` 同样返回 RELEASE，
// 于是 MC 的 `hasShiftDown()`（走轮询）也会说 false —— 采用生产者值只会制造
// "事件说按着、轮询说没按"的反向分裂。**自洽性比那个边界情形更值钱**，
// 这也正是上一段的原意。
static int currentModifierMask(const GLFWwindow* win) {
    if (!win) return 0;
    int mods = 0;
    if (win->keys[340] != GLFW_RELEASE || win->keys[344] != GLFW_RELEASE) {
        mods |= 0x0001;  // GLFW_MOD_SHIFT
    }
    if (win->keys[341] != GLFW_RELEASE || win->keys[345] != GLFW_RELEASE) {
        mods |= 0x0002;  // GLFW_MOD_CONTROL
    }
    if (win->keys[342] != GLFW_RELEASE || win->keys[346] != GLFW_RELEASE) {
        mods |= 0x0004;  // GLFW_MOD_ALT
    }
    if (win->keys[343] != GLFW_RELEASE || win->keys[347] != GLFW_RELEASE) {
        mods |= 0x0008;  // GLFW_MOD_SUPER
    }
    return mods;
}

static void dispatchAggregateKey(
        void* context, const amcl::input::GlfwAggregateKeyEvent& event) {
    GLFWwindow* win = static_cast<GLFWwindow*>(context);
    if (!win) win = g_currentWindow;
    if (!win) return;
    if (event.key >= 0 && event.key < 512) {
        // GLFW polling remains binary even when the callback action is REPEAT.
        win->keys[event.key] =
            event.action == amcl::input::GlfwAggregateAction::kRelease
                ? GLFW_RELEASE : GLFW_PRESS;
    }
    if (win->keyCb) {
        // 轮询状态已在上面更新，所以这里算出的 mods 已经包含**本次边沿自身**的效果 ——
        // 与真 GLFW 一致（按下 Shift 的那一条事件自己就带 SHIFT 位）。
        // 无条件现算，不看 `event.modifiers`（理由见 currentModifierMask 上方）。
        const int mods = currentModifierMask(win);
        // scancode 同理：ledger emit 与 ArkTS 的 hardwareScan 都恒为 0，而真 GLFW 的
        // scancode 永不为 0。我们的 `glfwGetKeyScancode()` 是恒等映射，所以这里用 key
        // 兜底即与查询接口自洽。影响面是 `InputConstants.Type.SCANCODE.getOrCreate()`：
        // 若某个绑定走 scancode 路径，全键盘会撞到同一个 0 号键。
        const int scanCode = event.scanCode != 0 ? event.scanCode : event.key;
        win->keyCb(win, event.key, scanCode,
                   static_cast<int>(event.action), mods);
    }
}

static void dispatchAggregateButton(
        void* context, const amcl::input::GlfwAggregateButtonEvent& event) {
    GLFWwindow* win = static_cast<GLFWwindow*>(context);
    if (!win) win = g_currentWindow;
    if (!win) return;
    if (event.button >= 0 && event.button < 8) {
        win->mouseButtons[event.button] =
            event.action == amcl::input::GlfwAggregateAction::kRelease
                ? GLFW_RELEASE : GLFW_PRESS;
    }
    // ---- 决定性探针：按下左键的那一刻，MC 能不能轮询到 Shift ----
    //
    // Minecraft 的 shift+左键（整组取物）**不看鼠标事件的 mods**，它调
    // `Screen.hasShiftDown()` → `InputConstants.isKeyDown(window, 340/344)` →
    // `glfwGetKey`，而我们的 `glfwGetKey` 读的正是 `win->keys[]`。
    // 所以这一行同时给出三件事：MC 会看到的 shift 轮询值、我们收到的 mods、
    // 以及左键本身的 action。三者一比就能定位 shift+左键失效到底断在哪一段。
    //
    // 只在左键按下时打，且限量 40 条：频率极低，稳态零噪声。
    if (event.button == GLFW_MOUSE_BUTTON_LEFT &&
        event.action != amcl::input::GlfwAggregateAction::kRelease) {
        static std::atomic<int> logged{0};
        if (logged.fetch_add(1, std::memory_order_relaxed) < 40) {
            // 本 TU 没有 include GLFW 的键码宏，这里用字面值并注明，避免为一条诊断
            // 引入新的头依赖：340=LEFT_SHIFT，344=RIGHT_SHIFT，341=LEFT_CONTROL。
            //
            // 同时打出 `win->cursorX/Y` —— 那是经 CursorPos 回调投给 MC 的**同一份**坐标，
            // 也就是 MC 判定"点在哪个 slot 上"所用的值。第一轮数据已证明 pollShiftL=1
            // （shift 输入链没问题），所以 shift+左键失效的剩余嫌疑就在这对坐标上：
            // 菜单按钮很大、物品 slot 只有十几像素，坐标有小偏差时完全可能
            // "按钮点得中、slot 点不中"。
            // `modsIn` = 生产者给的，`modsOut` = 我们按 GLFW 语义现算并真正交给 MC 的。
            // 自 2026-08-20 起 `modsIn` **不再参与决策**（见 currentModifierMask 上方）。
            //
            // ⚠️ 这里曾接着写「如果哪天它不再恒为 0，说明 typed 平面被打开了 ——
            // 这一行就是那件事的判据」。**那条判据永不成立**，两个独立原因叠加：
            //   ① typed 按钮**不经过本函数**。`typedButtonSink` 走
            //      `GlfwTypedRuntimeCommitButton` → `aggregate.CommitButton`（不带 sink、
            //      不回调），然后自己调 `mouseButtonCb`。本函数只由 `SubmitButton` 触发，
            //      而它的唯一调用方是 legacy 的 `bridgeMouseButtonCallback`。
            //   ② 即使经过，`modsIn` 也仍恒为 0：`AmclInputPointerButtonPayload
            //      .modifiersSnapshot` 在产品侧**零写者**（只有 host test 写），
            //      事件本身零初始化。
            // 这是"修复留下的自测判据本身失效"，属规范 §八.6 推论 a 那一族
            // （祈使句/判据的前提已不成立）。真要观察 typed 是否打开，应当读
            // `PlatformInputPhysicalRouteUsesTyped()` 或让 `typedButtonSink` 自己打一行。
            // `modsIn` 保留只为对照 legacy 侧的 0，不再声称能判定任何东西。
            OH_LOG_INFO(LOG_APP,
                        "AMCL_KBD leftPress pollShiftL=%{public}d pollShiftR=%{public}d "
                        "pollCtrlL=%{public}d modsIn=0x%{public}x modsOut=0x%{public}x "
                        "cursor=%{public}.1f,%{public}.1f",
                        win->keys[340], win->keys[344], win->keys[341],
                        event.modifiers, currentModifierMask(win),
                        win->cursorX, win->cursorY);
        }
    }
    if (win->mouseButtonCb) {
        // 同上：按 GLFW 语义无条件现算事件时刻的修饰键状态。这条正是 shift+左键的关键 ——
        // 此前恒为 0，MC 收到的每一次点击都声称"没按 Shift"。
        const int mods = currentModifierMask(win);
        win->mouseButtonCb(win, event.button,
                           static_cast<int>(event.action), mods);
    }
}

static amcl::input::GlfwAggregateSink aggregateSink(void* window = nullptr) {
    return {window, dispatchAggregateKey, dispatchAggregateButton};
}

static void bridgeMouseButtonCallback(
        void* window, int button, int action, int mods) {
    g_sourcePlaneAggregate.SubmitButton(
        amcl::input::GlfwSourcePlane::kLegacy, button,
        static_cast<amcl::input::GlfwAggregateAction>(action), mods,
        aggregateSink(window));
}

static void bridgeKeyCallback(
        void* window, int key, int scancode, int action, int mods) {
    g_sourcePlaneAggregate.SubmitKey(
        amcl::input::GlfwSourcePlane::kLegacy, key, scancode,
        static_cast<amcl::input::GlfwAggregateAction>(action), mods,
        aggregateSink(window));
}

static void bridgeScrollCallback(void* window, double xoffset, double yoffset) {
    GLFWwindow* win = (GLFWwindow*)window;
    if (!win) win = g_currentWindow;
    if (win && win->scrollCb) win->scrollCb(win, xoffset, yoffset);
}

// ==================== Phase 3.1 typed GLFW consumer ====================
// The source-plane decision is latched once in the XComponent-owning host API
// capability table. Both libentry producers and a namespace-duplicated GLFW
// consumer read that same table; neither independently re-reads the environment.
// Legacy pumping remains active only for virtual touch/gamepad controls.
static amcl::input::GlfwInputAdapter g_typedInputAdapter;
static amcl::input::GlfwTypedAbsoluteRoute g_typedAbsoluteRoute;
static bool g_typedInputOpenFailureLogged = false;
static const AmclInputHostApiV1* g_typedInputHost = nullptr;
static amcl::input::GlfwTypedInputResolveGuard g_typedInputResolveGuard;
// glfwPollEvents runs once per Minecraft frame, so resolving the typed host
// descriptor must never sit on that path: amclInputHostDescriptorResolveV1
// takes a process-wide flock, reads the descriptor file, and probes
// /proc/self/maps for the table plus every callback. An open consumer is
// therefore reused directly, and a not-ready route is retried on this coarse
// monotonic interval instead of on every frame.
static constexpr long long kTypedInputResolveRetryMs = 500;
static long long g_nextTypedInputResolveMs = 0;
// kLegacyCapability is decided by the one published host table, whose capability
// bits are latched once from an immutable build/startup selection. Unlike a
// resolve failure (the XComponent owner may simply not be loaded yet) it can
// never become typed later, so retrying it forever would pay the descriptor
// flock plus a /proc/self/maps probe twice a second for the whole session.
static bool g_typedInputLegacyLatched = false;
static std::atomic<uint64_t> g_typedUnsupportedKeyMappingCount{0u};
static std::atomic<uint64_t> g_typedUnsupportedButtonMappingCount{0u};
static std::atomic<uint64_t> g_typedDiagnosticDropCount{0u};
// 横轴 fail-closed 计数。⚠️ 相对视角的拒绝计数**刻意不在这里另立一个** —— 它由
// `GlfwTypedLookRoute::RejectCount()` 唯一持有，见那个头文件的说明（计划 §86）。
static std::atomic<uint64_t> g_typedWheelUnsupportedAxisCount{0u};

struct TypedWindowInputBinding {
    GLFWwindow* window = nullptr;
    uint64_t generation = 0u;
    uint32_t widthPx = 0u;
    uint32_t heightPx = 0u;
    bool active = false;
};

static amcl::input::GlfwTypedRuntimeTarget makeTypedRuntimeTarget(
        GLFWwindow* window, uint64_t generation, uint32_t widthPx,
        uint32_t heightPx, bool active) {
    return {
        window,
        window ? &window->cursorX : nullptr,
        window ? &window->cursorY : nullptr,
        window ? window->mouseButtons : nullptr,
        window ? 8u : 0u,
        generation,
        widthPx,
        heightPx,
        active && window != nullptr,
    };
}

// Render lifecycle fields in GLFWwindow are deliberately plain and may only be
// read by their owner thread. This independently published binding is the sole
// cross-thread input view. The shared lease protects only exact validation and
// internal GLFW commit. The adapter callback fence, not this mutex, keeps the
// target alive while user code is notified after every lifecycle lock is free.
static std::shared_mutex g_typedWindowInputBindingMutex;
static TypedWindowInputBinding g_typedWindowInputBinding;

static void publishTypedWindowInputBinding(GLFWwindow* window, bool active) {
    std::unique_lock<std::shared_mutex> lock(g_typedWindowInputBindingMutex);
    if (!active || !window || !window->nativeWindow ||
        window->nativeWindowGeneration == 0u || window->width <= 0 ||
        window->height <= 0) {
        g_typedWindowInputBinding = {};
        return;
    }
    g_typedWindowInputBinding = {
        window, window->nativeWindowGeneration,
        static_cast<uint32_t>(window->width),
        static_cast<uint32_t>(window->height), true};
}

static void clearTypedWindowInputBinding(GLFWwindow* expectedWindow) {
    std::unique_lock<std::shared_mutex> lock(g_typedWindowInputBindingMutex);
    if (!expectedWindow || g_typedWindowInputBinding.window == expectedWindow) {
        g_typedWindowInputBinding = {};
    }
}

class ScopedTypedWindowInputBinding {
public:
    ScopedTypedWindowInputBinding()
        : lock_(g_typedWindowInputBindingMutex),
          binding_(g_typedWindowInputBinding) {}

    amcl::input::GlfwTypedRuntimeTarget target() const {
        return makeTypedRuntimeTarget(
            binding_.window, binding_.generation, binding_.widthPx,
            binding_.heightPx, binding_.active);
    }

private:
    std::shared_lock<std::shared_mutex> lock_;
    TypedWindowInputBinding binding_{};
};

class ScopedTypedNativeWindowPublication {
public:
    ScopedTypedNativeWindowPublication() {
        active_ = glfwOHOS_BeginNativeWindowInputPublication(
            &width_, &height_, &generation_, &broker_) != 0;
    }

    ~ScopedTypedNativeWindowPublication() {
        if (active_) glfwOHOS_EndNativeWindowInputPublication(broker_);
    }

    ScopedTypedNativeWindowPublication(
        const ScopedTypedNativeWindowPublication&) = delete;
    ScopedTypedNativeWindowPublication& operator=(
        const ScopedTypedNativeWindowPublication&) = delete;

    explicit operator bool() const { return active_; }
    amcl::input::GlfwTypedRuntimePublication publication() const {
        return {generation_, static_cast<uint32_t>(width_),
                static_cast<uint32_t>(height_), active_};
    }

private:
    void* broker_ = nullptr;
    int width_ = 0;
    int height_ = 0;
    uint64_t generation_ = 0u;
    bool active_ = false;
};

static void logTypedAbsoluteRouteDrop(const char* stage) {
    const uint64_t count = g_typedAbsoluteRoute.DropCount();
    if (count != 0u && (count & (count - 1u)) == 0u) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
            "GLFW: typed absolute route rejected stage=%{public}s "
            "count=%{public}llu",
            stage ? stage : "unknown",
            static_cast<unsigned long long>(count));
    }
}

static void typedKeySink(void*, const amcl::input::GlfwKeySinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    g_sourcePlaneAggregate.SubmitKey(
        amcl::input::GlfwSourcePlane::kTyped, event.key, event.scanCode,
        static_cast<amcl::input::GlfwAggregateAction>(event.action),
        static_cast<int>(event.modifiers), aggregateSink());
}

static void typedButtonSink(
        void*, const amcl::input::GlfwButtonSinkEvent& event) {
    if (!event.requiresAbsoluteAuthorization) {
        GLFWwindow* callbackWindow = g_currentWindow;
        GLFWmousebuttonfun callback = nullptr;
        amcl::input::GlfwTypedRuntimeButtonCommit committed{};
        const auto status = amcl::input::GlfwTypedRuntimeCommitButton(
            g_typedAbsoluteRoute, g_sourcePlaneAggregate, event,
            makeTypedRuntimeTarget(callbackWindow, 0u, 0u, 0u,
                                   callbackWindow != nullptr),
            {}, committed);
        if (status != amcl::input::GlfwTypedRuntimeCommitStatus::kCommitted) {
            if (status != amcl::input::GlfwTypedRuntimeCommitStatus::
                              kTargetUnavailable) {
                logTypedAbsoluteRouteDrop("button-unbound");
            }
            return;
        }
        if (committed.notify && callbackWindow) {
            callback = callbackWindow->mouseButtonCb;
        }
        if (committed.notify && callback) {
            // mods 与另外两个分发点同一规则：**无条件**从权威轮询状态现算，
            // 不用 `committed.event.modifiers`（那是生产者给的，只知道自己那一路）。
            // 理由三条见 currentModifierMask 上方。
            // ⚠️ 这里是 2026-08-20 那次修复**漏掉**的第三个 notify 点 ——
            // 当时只改了 dispatchAggregateKey / dispatchAggregateButton，
            // 而 typed 绝对路由有它自己的两个 notify 点（本处与下方授权分支），
            // 直接把生产者 mods 交给 MC。漏掉的原因是它们不经过 aggregate 的 sink，
            // 而我按"sink 有几个"去找而不是按"callback 被调用了几次"去找。
            callback(callbackWindow, committed.event.button,
                     static_cast<int>(committed.event.action),
                     currentModifierMask(callbackWindow));
        }
        return;
    }

    GLFWwindow* callbackWindow = nullptr;
    GLFWmousebuttonfun callback = nullptr;
    amcl::input::GlfwTypedRuntimeButtonCommit committed{};
    {
        ScopedTypedWindowInputBinding windowBinding;
        ScopedTypedNativeWindowPublication publication;
        const auto status = amcl::input::GlfwTypedRuntimeCommitButton(
            g_typedAbsoluteRoute, g_sourcePlaneAggregate, event,
            windowBinding.target(), publication.publication(), committed);
        if (status != amcl::input::GlfwTypedRuntimeCommitStatus::kCommitted) {
            logTypedAbsoluteRouteDrop(
                status == amcl::input::GlfwTypedRuntimeCommitStatus::
                              kTargetPublicationMismatch
                    ? (!publication ? "button-publication"
                                    : "button-window-binding")
                    : "button-authorization");
            return;
        }

        callbackWindow = static_cast<GLFWwindow*>(committed.target);
        if (committed.notify && callbackWindow) {
            callback = callbackWindow->mouseButtonCb;
        }
        // Linearization point: aggregate ownership and GLFW polling state are
        // committed while both exact publication guards are held.
    }
    // User code may destroy the window or republish the surface synchronously.
    // The adapter callback fence keeps callbackWindow alive for this call; do
    // not dereference it after the callback returns.
    if (committed.notify && callback) {
        // 同上：无条件现算，不用生产者 mods。这是第四个 notify 点。
        // 注意 `callbackWindow` 在这里已经是 `committed.target`，且注释上方明确说
        // 回调返回后不得再解引用它 —— 现算发生在 callback **实参求值**时，
        // 即窗口仍存活的那一刻，与该约束不冲突。
        callback(callbackWindow, committed.event.button,
                 static_cast<int>(committed.event.action),
                 currentModifierMask(callbackWindow));
    }
}

static void typedAbsoluteSink(
        void*, const amcl::input::GlfwAbsoluteSinkEvent& event) {
    GLFWwindow* callbackWindow = nullptr;
    GLFWcursorposfun callback = nullptr;
    amcl::input::GlfwTypedRuntimeAbsoluteCommit committed{};
    {
        ScopedTypedWindowInputBinding windowBinding;
        ScopedTypedNativeWindowPublication publication;
        const auto status = amcl::input::GlfwTypedRuntimeCommitAbsolute(
            g_typedAbsoluteRoute, event, windowBinding.target(),
            publication.publication(), committed);
        if (status != amcl::input::GlfwTypedRuntimeCommitStatus::kCommitted) {
            logTypedAbsoluteRouteDrop(
                status == amcl::input::GlfwTypedRuntimeCommitStatus::
                              kTargetPublicationMismatch
                    ? (!publication ? "cursor-publication-lease"
                                    : "cursor-window-binding")
                    : "cursor-authorization");
            return;
        }
        callbackWindow = static_cast<GLFWwindow*>(committed.target);
        callback = callbackWindow->cursorPosCb;
        // Linearization point: the public polling state is committed under the
        // exact target/publication guards. Notification is deliberately later.
    }
    // A newer publication may complete here; this callback is notification of
    // an already-committed old event, never a commit against the new target.
    // callbackWindow is fenced by the adapter until this sink returns.
    if (committed.notify && callback) {
        callback(callbackWindow, committed.x, committed.y);
    }
}

static void typedSurfaceSink(
        void*, const amcl::input::GlfwSurfaceSinkEvent& event) {
    g_typedAbsoluteRoute.ConsumeSurface(event);
}

static std::mutex g_inputSurfaceContextMutex;
static AmclInputSurfaceContextPayload g_inputSurfaceContext{};
static bool g_hasInputSurfaceContext = false;

bool glfwOHOS_ReadInputSurfaceContext(
        AmclInputSurfaceContextPayload* outContext) {
    if (!outContext) return false;
    std::lock_guard<std::mutex> lock(g_inputSurfaceContextMutex);
    if (!g_hasInputSurfaceContext) return false;
    *outContext = g_inputSurfaceContext;
    return true;
}

void glfwOHOS_ClearInputSurfaceContext() {
    std::lock_guard<std::mutex> lock(g_inputSurfaceContextMutex);
    g_inputSurfaceContext = {};
    g_hasInputSurfaceContext = false;
}

static void typedSurfaceContextSink(
        void*, const amcl::input::GlfwSurfaceContextSinkEvent& event) {
    std::lock_guard<std::mutex> lock(g_inputSurfaceContextMutex);
    g_inputSurfaceContext = event.surfaceContext;
    g_hasInputSurfaceContext = true;
}

// typed 平面的 px 分格余量。与 legacy 的 `s_axisVAccum` 是两条平面各自的累加器，
// 刻意不共享：同一次滚动只会被一条平面拥有（通道仲裁保证），共享反而会让两条互相清零。
// ⚠️ 累加器不共享，但**分格契约共享**（`kGlfwPhysicalWheelPolicy`）：此前这里另有一份
// `kTypedWheelStepPx = 1.0` / `kTypedWheelMaxDetents = 256u`，是跨 TU 的数值镜像，
// 且 256 这个上限与 legacy 的"一个事件最多一格"直接冲突。详见计划 §83.9。
// ⚠️ 声明刻意放在 `typedResetSink` **之前** —— 复位点在那里（计划 §86.5）。
static double g_typedWheelRemainderPx = 0.0;
static std::atomic<uint64_t> g_typedTextDecodeFailureCount{0u};
static std::atomic<uint64_t> g_typedTextSelectionDegradedCount{0u};

static void typedResetSink(
        void*, const amcl::input::GlfwResetSinkEvent&) {
    g_typedAbsoluteRoute.Reset();
    if (g_currentWindow) {
        amcl::input::GlfwApplyCaptureState(
            &g_currentWindow->inputCapture, false, false);
    }
    // ⚠️ 滚轮残量也必须在这里清零。legacy 那半边一直有复位点（`s_axisVAccum` 在完整
    // 生命周期取消边界清零），typed 这半边此前**一个复位点都没有** —— 于是失焦 /
    // surface 换代 / 窗口重建之后，最多一格的残量会跨会话存活，让下一次会话的第一格
    // 提前触发。这正是本批声称消掉的那种两条平面不对称（计划 §86.5）。
    g_typedWheelRemainderPx = 0.0;
    glfwOHOS_ResetPreedit(g_currentWindow, true);
}

static bool decodeTypedUtf8(
        const std::vector<uint8_t>& utf8,
        std::vector<unsigned int>* output) {
    if (!output) return false;
    size_t count = 0u;
    if (amcl::input::DecodeTextUtf8Scalars(
            utf8.data(), utf8.size(), nullptr, 0u, &count) !=
            amcl::input::TextUtf8CodecStatus::kOk) {
        return false;
    }
    std::vector<uint32_t> decoded(count);
    if (amcl::input::DecodeTextUtf8Scalars(
            utf8.data(), utf8.size(), decoded.data(), decoded.size(),
            &count) != amcl::input::TextUtf8CodecStatus::kOk) {
        return false;
    }
    output->assign(decoded.begin(), decoded.end());
    return true;
}

static void recordTypedTextDecodeFailure(const char* kind) {
    const uint64_t count = g_typedTextDecodeFailureCount.fetch_add(
                               1u, std::memory_order_relaxed) + 1u;
    if ((count & (count - 1u)) == 0u) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG,
            "GLFW: typed text decode failed kind=%{public}s count=%{public}llu",
            kind, static_cast<unsigned long long>(count));
    }
}

static void typedTextSessionSink(
        void*, const amcl::input::GlfwTextSessionSinkEvent& event) {
    GLFWwindow* window = g_currentWindow;
    if (!window) return;
    if (event.change != AMCL_INPUT_TEXT_SESSION_STARTED) {
        glfwOHOS_ResetPreedit(window, true);
    }
    glfwOHOS_NotifyImeStatus(window);
}

static void typedTextCommitSink(
        void*, const amcl::input::GlfwTextCommitSinkEvent& event) {
    std::vector<unsigned int> scalars;
    if (!decodeTypedUtf8(event.utf8, &scalars)) {
        recordTypedTextDecodeFailure("commit");
        return;
    }
    GLFWwindow* window = g_currentWindow;
    if (!window) return;
    for (unsigned int scalar : scalars) {
        inputBridge_dispatchCharCodepoint(window, scalar);
    }
    glfwOHOS_ResetPreedit(window, true);
}

static void typedTextEditingSink(
        void*, const amcl::input::GlfwTextEditingSinkEvent& event) {
    std::vector<unsigned int> scalars;
    if (!decodeTypedUtf8(event.utf8, &scalars)) {
        recordTypedTextDecodeFailure("editing");
        return;
    }
    glfwOHOS_UpdatePreedit(
        g_currentWindow, scalars,
        static_cast<int>(event.selectionStart),
        static_cast<int>(event.selectionLength));
}

static void typedTextCandidatesSink(
        void*, const amcl::input::GlfwTextCandidatesSinkEvent& event) {
    std::vector<std::vector<unsigned int>> candidates;
    candidates.reserve(event.items.size());
    for (const std::string& item : event.items) {
        const std::vector<uint8_t> utf8(item.begin(), item.end());
        std::vector<unsigned int> scalars;
        if (!decodeTypedUtf8(utf8, &scalars)) {
            recordTypedTextDecodeFailure("candidates");
            return;
        }
        candidates.push_back(std::move(scalars));
    }
    glfwOHOS_UpdatePreeditCandidates(
        g_currentWindow, candidates, static_cast<int>(event.selected),
        static_cast<int>(event.pageStart), static_cast<int>(event.pageSize));
}

static void typedTextSelectionSink(
        void*, const amcl::input::GlfwTextSelectionSinkEvent& event) {
    if (glfwOHOS_UpdatePreeditSelection(
            g_currentWindow, static_cast<int>(event.selectionStart),
            static_cast<int>(event.selectionLength))) {
        return;
    }
    const uint64_t count = g_typedTextSelectionDegradedCount.fetch_add(
                               1u, std::memory_order_relaxed) + 1u;
    if ((count & (count - 1u)) == 0u) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
            "GLFW: typed text selection has no active preedit; "
            "document selection unsupported count=%{public}llu",
            static_cast<unsigned long long>(count));
    }
}

static amcl::input::GlfwTypedLookRoute g_typedLookRoute;

static void resolveTypedLookRoute() {
    if (g_typedLookRoute.HasSink()) return;
    const uintptr_t address = amcl::input::ParseGlfwTypedLookTrampoline(
        getenv("AMCL_LOOK_DELTA_CB"));
    if (address == 0u) return;  // libentry 尚未 publish；下一个样本再试，不缓存失败。
    (void)g_typedLookRoute.Latch(
        reinterpret_cast<amcl::input::GlfwTypedLookSink>(address));
}

// 相对位移被那道门丢掉了多少条。⚠️ **必须把三个合取项分别打出来**，否则这个计数回答不了
// 唯一重要的问题："是 MC 没请求 capture，还是平台没授予？"两者的修法完全不同，而它们此前
// 共用同一条静默 return（2026-09-05 报告 §4.3 与 K1 就是这样被混在一起的）。
static std::atomic<uint64_t> g_typedRelativeDroppedCount{0u};

static void typedRelativeSink(
        void*, const amcl::input::GlfwRelativeSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    GLFWwindow* window = g_currentWindow;
    // ⭐ 2026-09-05：这里曾经用 `g_cursorMode == GLFW_CURSOR_DISABLED`，而那是一个
    // **后端专有量** —— 它的唯一写者是 `glfwSetInputMode`，只有 GLFW3 那条链会调。
    // 真机否证（1.12.2，`AMCL_GLFW_RELDROP cursorDisabled=0 requested=1 active=1`）：
    // LWJGL2 世代的 grab 走 `inputBridge_setGrabState`，永远设不到 `g_cursorMode`，
    // 于是**"MC 请求了、平台也授予了、这道门却仍然关着"** —— ≤1.12 的物理鼠标视角
    // 结构上没有任何生产者。⚠️ 注意 `requested`/`active` 当时都是 1：它们由
    // `typedCaptureSink` 从平台 capture 结果写入，与 MC 调没调 GLFW API 无关 ——
    // 也就是说这道门的四个合取项里，**只有这一个**混进了后端身份。
    //
    // 现在改用 `inputBridge_isGrabbing()`：它是三条链共同的 grab 权威（见上方声明处）。
    // ⚠️ 这不放松准入 —— `glfwSetInputMode(GLFW_CURSOR, DISABLED)` 自己就会调
    // `inputBridge_setGrabState(true)`，所以对 GLFW3 而言两者同真，行为不变。
    const bool grabActive = inputBridge_isGrabbing();
    if (!window || !amcl::input::GlfwShouldDispatchRelative(
            window->inputCapture, grabActive, event.hardwareRaw)) {
        const uint64_t count = g_typedRelativeDroppedCount.fetch_add(
                                   1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                "AMCL_GLFW_RELDROP window=%{public}d grabActive=%{public}d "
                "cursorDisabled=%{public}d "
                "requested=%{public}d active=%{public}d rawMode=%{public}d "
                "hardwareRaw=%{public}d count=%{public}llu",
                window ? 1 : 0,
                grabActive ? 1 : 0,
                g_cursorMode == GLFW_CURSOR_DISABLED ? 1 : 0,
                window && window->inputCapture.requested ? 1 : 0,
                window && window->inputCapture.active ? 1 : 0,
                window && window->inputCapture.rawMouseMotion ? 1 : 0,
                event.hardwareRaw ? 1 : 0,
                static_cast<unsigned long long>(count));
        }
        return;
    }
    // ⭐ 2026-08-23 重写。此前这里自己做 `window->cursorX + dx` 再直调
    // `bridgeCursorPosCallback`，于是 legacy 漏斗的**九件事一件都不生效**：灵敏度、
    // 倒置 Y、加速、端级量纲归一、census、端计数、守恒 backlog、双坐标隔离、grab
    // 重锚。切到 typed 的当天用户会看到 Back-to-Game 瞬移 + ESC 回来视角猛甩 +
    // 滑条全部失效，而其中"倒置 Y 失效"零日志。逐项对照见计划 §85。
    //
    // 现在它只做**生产者**：把增量交给同一条漏斗（跨 DSO，见 GlfwTypedLookRoute 头）。
    resolveTypedLookRoute();
    const amcl::input::GlfwTypedLookStatus status =
        g_typedLookRoute.Apply(event.dx, event.dy);
    if (status == amcl::input::GlfwTypedLookStatus::kApplied) return;
    const uint64_t count = g_typedLookRoute.RejectCount();
    if ((count & (count - 1u)) == 0u) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG,
            "GLFW: typed relative look rejected status=%{public}d count=%{public}llu",
            static_cast<int>(status),
            static_cast<unsigned long long>(count));
    }
}

static void typedWheelSink(
        void*, const amcl::input::GlfwWheelSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    double x = 0.0;
    double y = 0.0;
    // ⭐ 未知量纲 **fail closed**，不当 px 用。折算本体在 `WheelSamplePxFromUnit`：此前它
    // 内联在这里，于是 `backend_input_bridge` 那条新通道又写了一遍（而且漏读了 unit）——
    // "三处各说一套量纲"是计划 §90 与 §102.1 同一族缺陷，收敛成一份才算真的修完。
    if (!amcl::input::WheelSamplePxFromUnit(
            event.x, event.y, event.unit,
            amcl::input::kGlfwPhysicalWheelPolicy, &x, &y)) {
        const uint64_t count = g_typedWheelUnsupportedAxisCount.fetch_add(
                                   1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            AMCL_EXTERNAL_LOG_E(LOG_TAG,
                "GLFW: typed wheel rejected unknown unit=%{public}u count=%{public}llu",
                event.unit, static_cast<unsigned long long>(count));
        }
        return;
    }
    // ⭐ 分格、横轴 fail-closed、零样本、以及**拒绝时的余量处置**全部由与 legacy
    // **同一个** `StepPhysicalWheel` 决定（计划 §91）。此前这里与 legacy 各写一遍，
    // 而拒绝路径上一个清零一个保留 ⇒ 一个非法样本之后两条平面的格数序列可以永久分叉。
    amcl::input::PhysicalWheelStepOutcome step{};
    amcl::input::StepPhysicalWheel(
        g_typedWheelRemainderPx, x, y,
        amcl::input::kGlfwPhysicalWheelPolicy, &step);
    // 无条件写回，与 legacy 逐字相同。
    g_typedWheelRemainderPx = step.remainder;
    if (step.status == amcl::input::PhysicalWheelStepStatus::kRejectedAxis) {
        const uint64_t count = g_typedWheelUnsupportedAxisCount.fetch_add(
                                   1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            AMCL_EXTERNAL_LOG_E(LOG_TAG,
                "GLFW: typed wheel rejected non-zero horizontal axis count=%{public}llu",
                static_cast<unsigned long long>(count));
        }
        return;
    }
    if (step.status != amcl::input::PhysicalWheelStepStatus::kEmit) return;
    bridgeScrollCallback(g_currentWindow, 0.0,
                         static_cast<double>(step.glfwY));
}

static void typedFocusSink(
        void*, const amcl::input::GlfwFocusSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    GLFWwindow* window = g_currentWindow;
    if (!window) return;
    if (!amcl::input::kGlfwNotifyBackendFocusChange) return;
    const bool notify = amcl::input::GlfwApplyFocusState(
        &window->focused, event.focused, event.baseline);
    if (!event.focused) window->inputCapture.active = false;
    if (notify && window->focusCb) window->focusCb(window, window->focused);
}

static void typedCaptureSink(
        void*, const amcl::input::GlfwCaptureSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    GLFWwindow* window = g_currentWindow;
    if (!window) return;
    amcl::input::GlfwApplyCaptureState(
        &window->inputCapture, event.requested, event.active);
}

static void typedEnterSink(
        void*, const amcl::input::GlfwEnterSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    inputBridge_dispatchCursorEnter(g_currentWindow,
                                    event.entered ? GLFW_TRUE : GLFW_FALSE);
}

static bool shouldLogDiagnosticCount(uint64_t count) {
    // Keep persistent counters exact while bounding device log volume: the
    // first rejection and powers of two retain onset and growth evidence.
    return count != 0u && (count & (count - 1u)) == 0u;
}

static void typedUnsupportedMappingSink(
        void*, const amcl::input::GlfwUnsupportedMappingSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    uint64_t count = 0u;
    const char* kind = "invalid";
    switch (event.kind) {
        case amcl::input::GlfwUnsupportedMappingKind::kKey:
            kind = "key";
            count = g_typedUnsupportedKeyMappingCount.fetch_add(
                        1u, std::memory_order_relaxed) + 1u;
            break;
        case amcl::input::GlfwUnsupportedMappingKind::kButton:
            kind = "button";
            count = g_typedUnsupportedButtonMappingCount.fetch_add(
                        1u, std::memory_order_relaxed) + 1u;
            break;
    }
    if (!shouldLogDiagnosticCount(count)) return;

    // This sink is diagnostic-only: it never feeds the final source-plane
    // aggregate, so an unfamiliar raw control cannot become a guessed GLFW
    // key/button or disturb unrelated polling state.
    AMCL_EXTERNAL_LOG_W(LOG_TAG,
        "GLFW: unsupported typed mapping kind=%{public}s raw=%{public}u "
        "action=%{public}u device=%{public}llu scan=%{public}u "
        "hid=%{public}u sequence=%{public}llu count=%{public}llu",
        kind, event.rawControl, event.action,
        static_cast<unsigned long long>(event.deviceId),
        event.hardwareScanCode, event.hidUsage,
        static_cast<unsigned long long>(event.sequence),
        static_cast<unsigned long long>(count));
}

static void typedDiagnosticDropSink(
        void*, const amcl::input::GlfwDiagnosticDropSinkEvent& event) {
    g_typedAbsoluteRoute.CancelAuthorization();
    const uint64_t count = g_typedDiagnosticDropCount.fetch_add(
                               1u, std::memory_order_relaxed) + 1u;
    if (!shouldLogDiagnosticCount(count)) return;

    // A core/adapter drop is evidence only. It never enters the source-plane
    // aggregate, so an ownerless or duplicate edge cannot alter GLFW polling
    // or manufacture a normal callback while remaining operationally visible.
    AMCL_EXTERNAL_LOG_W(LOG_TAG,
        "GLFW: typed edge dropped reason=%{public}u type=%{public}u "
        "raw=%{public}u action=%{public}u device=%{public}llu "
        "scan=%{public}u hid=%{public}u sequence=%{public}llu "
        "count=%{public}llu",
        event.reason, event.originalEventType, event.rawControl, event.action,
        static_cast<unsigned long long>(event.deviceId),
        event.hardwareScanCode, event.hidUsage,
        static_cast<unsigned long long>(event.sequence),
        static_cast<unsigned long long>(count));
}

static amcl::input::GlfwInputSink typedInputSink() {
    amcl::input::GlfwInputSink sink{};
    sink.key = typedKeySink;
    sink.button = typedButtonSink;
    sink.absolute = typedAbsoluteSink;
    sink.relative = typedRelativeSink;
    sink.wheel = typedWheelSink;
    sink.focus = typedFocusSink;
    sink.enter = typedEnterSink;
    sink.capture = typedCaptureSink;
    sink.surface = typedSurfaceSink;
    sink.surfaceContext = typedSurfaceContextSink;
    sink.reset = typedResetSink;
    sink.unsupportedMapping = typedUnsupportedMappingSink;
    sink.diagnosticDrop = typedDiagnosticDropSink;
    sink.textSession = typedTextSessionSink;
    sink.textCommit = typedTextCommitSink;
    sink.textEditing = typedTextEditingSink;
    sink.textCandidates = typedTextCandidatesSink;
    sink.textSelection = typedTextSelectionSink;
    return sink;
}

static amcl::input::GlfwInputSink typedTextOnlySink() {
    amcl::input::GlfwInputSink sink{};
    sink.reset = typedResetSink;
    sink.textSession = typedTextSessionSink;
    sink.textCommit = typedTextCommitSink;
    sink.textEditing = typedTextEditingSink;
    sink.textCandidates = typedTextCandidatesSink;
    sink.textSelection = typedTextSelectionSink;
    return sink;
}

static bool typedInputAdapterHasConsumer(void* context) {
    return static_cast<amcl::input::GlfwInputAdapter*>(context)->HasConsumer();
}

static int32_t typedInputAdapterClose(void* context) {
    const int32_t status = static_cast<int32_t>(
        static_cast<amcl::input::GlfwInputAdapter*>(context)->Close());
    g_typedAbsoluteRoute.Reset();
    glfwOHOS_ClearInputSurfaceContext();
    glfwOHOS_ResetPreedit(g_currentWindow, true);
    if (g_currentWindow) {
        amcl::input::GlfwApplyCaptureState(
            &g_currentWindow->inputCapture, false, false);
    }
    return status;
}

static bool ensureTypedInputOpen() {
    const AmclInputHostApiV1* host = nullptr;
    const int32_t resolve = amclInputHostDescriptorResolveV1(&host);
    const amcl::input::GlfwTypedInputRetireOps retireOps{
        &g_typedInputAdapter, typedInputAdapterHasConsumer,
        typedInputAdapterClose};
    const amcl::input::GlfwTypedInputResolveResult route =
        g_typedInputResolveGuard.Apply(resolve, host, retireOps);
    const bool textOnlyRoute =
        route.outcome ==
            amcl::input::GlfwTypedInputResolveOutcome::kLegacyCapability &&
        host != nullptr &&
        (host->capabilityBits & AMCL_INPUT_CAP_TEXT_INPUT_SESSION) != 0u;
    if (route.outcome !=
            amcl::input::GlfwTypedInputResolveOutcome::kTypedRoute &&
        !textOnlyRoute) {
        g_typedInputHost = nullptr;
        if (route.outcome ==
            amcl::input::GlfwTypedInputResolveOutcome::kLegacyCapability) {
            // Permanent, not a retry state: see g_typedInputLegacyLatched.
            g_typedInputLegacyLatched = true;
        }
        if (route.outcome ==
                amcl::input::GlfwTypedInputResolveOutcome::kResolveFailure &&
            amcl::input::ShouldLogGlfwTypedInputResolveFailure(
                route.failureCount)) {
            AMCL_EXTERNAL_LOG_E(LOG_TAG,
                "GLFW: typed host descriptor resolve failed rc=%{public}d "
                "reason=%{public}u count=%{public}llu hadConsumer=%{public}d "
                "closeInvoked=%{public}d close=%{public}d; physical input "
                "remains fail-closed (legacy fallback forbidden)",
                resolve, static_cast<uint32_t>(route.failure),
                static_cast<unsigned long long>(route.failureCount),
                route.adapterHadConsumer ? 1 : 0,
                route.closeInvoked ? 1 : 0, route.closeStatus);
        }
        if (route.closeInvoked &&
            route.closeStatus !=
                static_cast<int32_t>(amcl::input::GlfwAdapterStatus::kOk)) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                "GLFW: typed route retirement incomplete outcome=%{public}u "
                "close=%{public}d retained=%{public}d",
                static_cast<uint32_t>(route.outcome), route.closeStatus,
                g_typedInputAdapter.HasConsumer() ? 1 : 0);
        }
        return false;
    }
    if (g_typedInputAdapter.IsReady() && g_typedInputHost == host) return true;
    if (g_typedInputAdapter.HasConsumer()) {
        // A valid descriptor changing address is an owner rollover boundary.
        // A failed Open/Close may also retain a non-ready handle for cleanup.
        // Retire either form before opening a fresh baseline; otherwise the
        // core's unique READY/RETIRE gate could remain owned by an orphan.
        const amcl::input::GlfwAdapterStatus closeStatus =
            static_cast<amcl::input::GlfwAdapterStatus>(
                typedInputAdapterClose(&g_typedInputAdapter));
        g_typedInputHost = nullptr;
        if (closeStatus != amcl::input::GlfwAdapterStatus::kOk ||
            g_typedInputAdapter.HasConsumer()) {
            if (!g_typedInputOpenFailureLogged) {
                g_typedInputOpenFailureLogged = true;
                AMCL_EXTERNAL_LOG_W(LOG_TAG,
                    "GLFW: typed consumer cleanup incomplete close=%{public}d "
                    "retained=%{public}d; fresh READY is deferred",
                    static_cast<int>(closeStatus),
                    g_typedInputAdapter.HasConsumer() ? 1 : 0);
            }
            return false;
        }
    }

    amcl::input::GlfwAdapterStatus status = g_typedInputAdapter.Open(
        host, amcl::input::GlfwOhosInputMapper(),
        textOnlyRoute ? typedTextOnlySink() : typedInputSink());
    if (status == amcl::input::GlfwAdapterStatus::kOk) {
        g_typedInputHost = host;
        g_typedInputOpenFailureLogged = false;
        OH_LOG_INFO(LOG_APP,
                    "GLFW: typed physical input consumer ready epoch=%{public}llu",
                    (unsigned long long)g_typedInputAdapter.SessionEpoch());
        return true;
    }
    if (!g_typedInputOpenFailureLogged) {
        g_typedInputOpenFailureLogged = true;
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
                    "GLFW: typed physical input unavailable resolve=%{public}d "
                    "open=%{public}d; startup mode remains fail-closed",
                    resolve, static_cast<int>(status));
    }
    return false;
}

// Frame-rate safe gate in front of ensureTypedInputOpen(). The resolve it
// performs is deliberately expensive and is called once per rendered frame, so
// it must only run when there is no live consumer, and then at a bounded rate.
static bool ensureTypedInputOpenThrottled() {
    if (g_typedInputAdapter.IsReady()) return true;
    if (g_typedInputLegacyLatched) {
        // The legacy physical owner is this process's final decision. Never
        // resolve again; the descriptor probe is far too expensive to repeat.
        return false;
    }
    if (g_typedInputAdapter.IsReady() && g_typedInputHost != nullptr) {
        // A live consumer needs no descriptor re-resolve. Host loss is reported
        // by Pump(), which clears g_typedInputHost so this path re-opens a
        // fresh baseline on the next retry tick.
        return true;
    }
    const long long now = currentTimeMs();
    if (g_nextTypedInputResolveMs != 0 && now < g_nextTypedInputResolveMs) {
        return false;
    }
    g_nextTypedInputResolveMs = now + kTypedInputResolveRetryMs;
    return ensureTypedInputOpen();
}

static void pumpTypedInput() {
    if (!ensureTypedInputOpenThrottled()) return;
    const amcl::input::GlfwPumpResult result = g_typedInputAdapter.Pump();
    if (result.eventsDiscarded != 0u || result.abandoned) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
            "GLFW: typed input recovery status=%{public}d drained=%{public}u "
            "discarded=%{public}u abandoned=%{public}d host=%{public}d",
            static_cast<int>(result.status), result.eventsDrained,
            result.eventsDiscarded, result.abandoned ? 1 : 0,
            result.recoveryHostStatus);
    }
    if (result.status == amcl::input::GlfwAdapterStatus::kOk ||
        result.status == amcl::input::GlfwAdapterStatus::kOverflowReset) {
        if (result.status ==
            amcl::input::GlfwAdapterStatus::kOverflowReset) {
            g_typedAbsoluteRoute.CancelAuthorization();
        }
        return;
    }
    g_typedInputHost = nullptr;
    g_typedAbsoluteRoute.Reset();
    // The adapter already released every aggregate before becoming not-ready.
    // Retry a fresh descriptor/baseline on a later poll; never switch this
    // session to legacy after typed events may have been dispatched.
    AMCL_EXTERNAL_LOG_W(LOG_TAG,
                "GLFW: typed input pump closed status=%{public}d drained=%{public}u "
                "discarded=%{public}u abandoned=%{public}d host=%{public}d",
                static_cast<int>(result.status), result.eventsDrained,
                result.eventsDiscarded, result.abandoned ? 1 : 0,
                result.recoveryHostStatus);
}

static long long scheduleSurfaceRecovery(GLFWwindow* window) {
    ++window->surfaceRecoveryFailures;
    const unsigned int shift = window->surfaceRecoveryFailures > 4
                                   ? 4
                                   : window->surfaceRecoveryFailures;
    const long long delayMs = 125LL << shift;
    window->nextSurfaceRecoveryAttemptMs = currentTimeMs() + delayMs;
    return delayMs;
}

static void markEglSurfaceDetachPending(GLFWwindow* window, const char* reason) {
    if (!window) return;
    window->eglSurfaceDetachPending = true;
    const long long delayMs = scheduleSurfaceRecovery(window);
    if (window->surfaceRecoveryFailures == 1 ||
        (window->surfaceRecoveryFailures % 10) == 0) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
                    "GLFW: stale EGLSurface detach pending (%{public}s); "
                    "retry=%{public}u backoff=%{public}lldms",
                    reason ? reason : "unknown", window->surfaceRecoveryFailures,
                    delayMs);
    }
}

static void clearEglContextOwnershipAfterDetach(GLFWwindow* window,
                                                const char* reason) {
    if (!window) return;
    const int currentTid = static_cast<int>(gettid());
    const bool ownedHere = window->contextOwnerTid == currentTid ||
                           g_threadCurrentContext == window;
    // 三条 GLFW OpenGL 路线都保持同一个 current context。surface 暂失只停止上屏，
    // 后续 GL 资源更新仍落在停车 pbuffer 对应的原对象域；不要清除 TLS/owner，
    // 否则另一线程可能错误接管仍 current 的 context。显式 Release 的路径不满足此条件。
    if (ownedHere && window->context != EGL_NO_CONTEXT &&
        eglGetCurrentDisplay() == window->display &&
        eglGetCurrentContext() == window->context &&
        eglGetCurrentSurface(EGL_DRAW) == window->parkingSurface &&
        window->parkingSurface != EGL_NO_SURFACE) {
        if (ownedHere) amcl::ohos::LeaveInteractiveRenderQoS(reason);
        return;
    }
    if (window->contextOwnerTid == currentTid) window->contextOwnerTid = 0;
    if (g_threadCurrentContext == window) g_threadCurrentContext = nullptr;
    if (ownedHere) amcl::ohos::LeaveInteractiveRenderQoS(reason);
}

static void clearEglTlsAfterPartialDetach(GLFWwindow* window) {
    if (!window || g_threadCurrentContext != window) return;
    const bool stillCurrent = window->display != EGL_NO_DISPLAY &&
                              eglGetCurrentDisplay() == window->display &&
                              eglGetCurrentContext() == window->context;
    if (!stillCurrent) {
        // eglMakeCurrent(NULL) succeeded but stale-surface destruction did
        // not. Keep contextOwnerTid as the cleanup-thread gate while making
        // GLFW TLS accurately report that no context is actually current.
        g_threadCurrentContext = nullptr;
    }
}

static bool isBackendSurfaceReady(const GLFWwindow* window) {
    if (!window || !window->nativeWindow || window->width <= 0 || window->height <= 0) {
        return false;
    }
    if (window->clientAPI == GLFW_NO_API) return true;
    return window->graphicsBackendSession && window->display != EGL_NO_DISPLAY && window->surface != EGL_NO_SURFACE;
}

// Consume the UI-thread publication on the render thread. All EGL calls stay
// here; XComponent callbacks only publish immutable pointer/size epochs.
static bool consumePublishedSurfaceState(GLFWwindow* window, const char* checkpoint,
                                         bool presentationCheckpoint) {
    if (!window) return false;
    if (window->clientAPI != GLFW_NO_API && (window->contextLostFatal || window->eglSurfaceDetachPending ||
        window->eglTeardownPending || !window->graphicsBackendSession)) {
        publishTypedWindowInputBinding(window, false);
        return false;
    }
    void* publishedWindow = nullptr;
    int publishedWidth = 0;
    int publishedHeight = 0;
    uint64_t publishedGeneration = 0;
    void* publishedLeaseBroker = nullptr;
    glfwOHOS_AcquireNativeWindowSnapshot(window->nativeWindowLeaseObject, window->nativeWindowGeneration,
        window->nativeWindowLeaseBroker, &publishedWindow, &publishedWidth, &publishedHeight,
        &publishedGeneration, &publishedLeaseBroker);
    ScopedNativeWindowLease publishedLease(publishedWindow, publishedLeaseBroker);
    const bool publishedReady = publishedWindow && publishedWidth > 0 && publishedHeight > 0;

    if (window->clientAPI == GLFW_NO_API) {
        // This is input/window bookkeeping only. The Vulkan shim keeps an
        // independent lease/token until the game destroys its real VkSurface.
        if (publishedLeaseBroker) adoptWindowNativeWindowLease(window, publishedWindow, publishedLease);
        if (!publishedReady) releaseWindowNativeWindowLease(window);
        window->nativeWindow = publishedReady ? publishedWindow : nullptr;
        window->nativeWindowGeneration = publishedGeneration;
        window->width = publishedWidth;
        window->height = publishedHeight;
        window->sizeNotifications.Observe(publishedWidth, publishedHeight);
        if (publishedReady) inputBridge_setWindowSize(publishedWidth, publishedHeight);
        publishTypedWindowInputBinding(window, publishedReady);
        return publishedReady;
    }

    const int currentTid = static_cast<int>(gettid());
    if (window->contextOwnerTid != 0 && window->contextOwnerTid != currentTid) {
        if (presentationCheckpoint) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG, "GLFW: surface consume refused on thread %{public}d owner=%{public}d",
                currentTid, window->contextOwnerTid);
            return false;
        }
        return isBackendSurfaceReady(window);
    }
    if (window->contextOwnerTid == 0 && !presentationCheckpoint) return isBackendSurfaceReady(window);

    auto* handle = static_cast<BackendSessionHandle*>(window->graphicsBackendSession);
    if (handle->session->state() == amcl::graphics::BackendSessionState::kFailed) {
        window->contextLostFatal = true;
        window->shouldClose = 1;
        setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
        publishTypedWindowInputBinding(window, false);
        return false;
    }
    if (!publishedReady) {
        if (!suspendGraphicsBackendSession(window)) {
            clearEglTlsAfterPartialDetach(window);
            markEglSurfaceDetachPending(window, "lifecycle-lost");
            return false;
        }
        clearEglContextOwnershipAfterDetach(window, "surface-lost");
        // Session still owns its old epoch while the host publication is absent.
        releaseWindowNativeWindowLease(window);
        window->nativeWindow = nullptr;
        window->nativeWindowGeneration = publishedGeneration;
        window->width = publishedWidth;
        window->height = publishedHeight;
        window->sizeNotifications.Observe(publishedWidth, publishedHeight);
        publishTypedWindowInputBinding(window, false);
        return false;
    }

    if (handle->session->state() == amcl::graphics::BackendSessionState::kAttached &&
        handle->session->generation() == publishedGeneration && window->nativeWindowGeneration == publishedGeneration &&
        window->nativeWindow == publishedWindow && isBackendSurfaceReady(window)) {
        if (publishedLeaseBroker) adoptWindowNativeWindowLease(window, publishedWindow, publishedLease);
        publishTypedWindowInputBinding(window, true);
        return true;
    }

    // 只有新版 broker 在取得引用的同一事务中给出资源身份，并原子移动呈现 token，
    // 才接受原地几何更新。旧 broker、漏看的 clear→publish、零尺寸暂停都保留完整重建。
    std::string geometryError;
    if (isBackendSurfaceReady(window) && handle->session->refreshGeometry(
            publishedWidth, publishedHeight, publishedGeneration, geometryError)) {
        if (publishedLeaseBroker) adoptWindowNativeWindowLease(window, publishedWindow, publishedLease);
        window->nativeWindow = publishedWindow;
        window->nativeWindowGeneration = publishedGeneration;
        window->width = publishedWidth; window->height = publishedHeight;
        window->sizeNotifications.Observe(publishedWidth, publishedHeight);
        publishTypedWindowInputBinding(window, true);
        OH_LOG_INFO(LOG_APP, "graphics_surface_geometry generation=%{public}llu resource=%{public}llu geometry=%{public}llu preserved=1",
            static_cast<unsigned long long>(publishedGeneration),
            static_cast<unsigned long long>(handle->session->lease().resourceEpoch),
            static_cast<unsigned long long>(handle->session->lease().geometryEpoch));
        return true;
    }
    const bool needsAttach = handle->session->generation() != publishedGeneration || !isBackendSurfaceReady(window);
    if (needsAttach) {
        if (currentTimeMs() < window->nextSurfaceRecoveryAttemptMs) return false;
        OH_LOG_INFO(LOG_APP, "GLFW: session consume generation %{public}llu to %{public}llu at %{public}s",
            static_cast<unsigned long long>(handle->session->generation()),
            static_cast<unsigned long long>(publishedGeneration), checkpoint ? checkpoint : "unknown");
        // Adapter suspend destroys the old surface before the broker atomically
        // moves its token. Resume attaches the new surface while both references
        // remain retained; only successful attachment releases the old lease.
        if (!suspendGraphicsBackendSession(window)) {
            clearEglTlsAfterPartialDetach(window);
            markEglSurfaceDetachPending(window, "lifecycle-replaced");
            return false;
        }
        clearEglContextOwnershipAfterDetach(window, "surface-replaced");
        if (!resumeGraphicsBackendSession(window)) {
            const long long retryDelay = scheduleSurfaceRecovery(window);
            if (handle->session->state() == amcl::graphics::BackendSessionState::kFailed) {
                window->contextLostFatal = true;
                window->shouldClose = 1;
                setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
            }
            publishTypedWindowInputBinding(window, false);
            AMCL_EXTERNAL_LOG_W(LOG_TAG, "GLFW: session attach retained ownership; failure=%{public}u backoff=%{public}lldms",
                window->surfaceRecoveryFailures, retryDelay);
            return false;
        }
        window->contextOwnerTid = currentTid;
        g_threadCurrentContext = window;
        amcl::ohos::EnterInteractiveRenderQoS("egl-surface");
    }
    if (!resizeGraphicsBackendSession(window, publishedWidth, publishedHeight, publishedGeneration)) {
        publishTypedWindowInputBinding(window, false);
        return false;
    }
    if (publishedLeaseBroker) adoptWindowNativeWindowLease(window, publishedWindow, publishedLease);
    window->nativeWindow = publishedWindow;
    window->nativeWindowGeneration = publishedGeneration;
    window->width = publishedWidth;
    window->height = publishedHeight;
    window->surfaceRecoveryFailures = 0;
    window->nextSurfaceRecoveryAttemptMs = 0;
    window->eglSurfaceDetachPending = false;
    window->sizeNotifications.Observe(publishedWidth, publishedHeight);
    inputBridge_setWindowSize(publishedWidth, publishedHeight);
    publishTypedWindowInputBinding(window, true);
    return isBackendSurfaceReady(window);
}
// ==================== GLFW 核心实现 ====================
int glfwInit(void) {
    // One record per mapped libglfw image. This turns linker-namespace copies
    // into observable device evidence without assuming that one HAP DSO entry
    // implies one process mapping.
    logRuntimeImageIdentity();
    if (g_initialized) return GLFW_TRUE;
    if (!glfwOHOS_ValidatePlatformHint()) return GLFW_FALSE;

    // 函数表完整后才提交 GLFW 初始化。所有 EGL/GL 入口随后读取同一不可变绑定，
    // 环境被第三方库改写也不会切换 provider；MG 的初始化也在绑定内部完成。
    std::string bindingError;
    if (!amcl::graphics::RequireGraphicsRuntime()) {
        bindingError = "graphics runtime is unavailable";
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: provider binding failed: %{public}s", bindingError.c_str());
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, bindingError.c_str());
        return GLFW_FALSE;
    }
    if (g_hintClientAPI != GLFW_NO_API)
        g_hintClientAPI = amcl::desktop::UsesDesktopOpenGlContext() ? GLFW_OPENGL_API : GLFW_OPENGL_ES_API;
    g_startTime = std::chrono::steady_clock::now();
    g_initialized = 1;
    g_swapCount = 0;
    g_pollCount = 0;
    g_currentWindow = nullptr;
    clearTypedWindowInputBinding(nullptr);
    // No callback target exists at init. A prior fully torn-down session must
    // not lend mapped source owners to the next GLFWwindow; runtime teardown
    // emits releases while the old window is alive, this is only a final guard.
    g_sourcePlaneAggregate.Abandon();
    g_typedAbsoluteRoute.Reset();
    g_lastSwapTimeMs = 0;
    s_loggedClose = false;
    g_cursorMode = GLFW_CURSOR_NORMAL;
    // NativeWindow state lives in amcl_window_host and survives GLFW image
    // reinitialization; the local publisher marker is only for input routing.
    OH_LOG_INFO(LOG_APP, "GLFW: glfwInit — all state reset for new session");

    /* Only the libglfw image that owns the XComponent may publish the input
     * function descriptors.  LWJGL/SDL can load a second libglfw image in a
     * linker namespace; letting that copy overwrite the environment would
     * point consumers at its private ring, which never receives host events.
     * The owner publishes again from glfwOHOS_PublishNativeWindow(), covering
     * the normal case where the surface is created after glfwInit().
     *
     * ⚠️ 2026-09-01 到 2026-09-03 之间，这道守卫**单独**成立而 legacy ring 还没有跨 image
     * 通道，于是 GLFW3/LWJGL2 消费者从此 drain 自己那份永远为空的 ring（回归报告：
     * docs/reports/2026-09-03_LEGACY_GLFW_ROUTE_INPUT_REGRESSION_INVESTIGATION.md）。
     * 守卫本身没错 —— 错在它的作用域被当成了全部答案。现在补上的那条通道是
     * input_bridge_instance_descriptor.h：非 owner 的那份 image 会把每个 inputBridge_*
     * 入口转发给 owner，所以"不发布"对它已经不再等于"没有输入"。
     * ⇒ 删掉这道守卫会让 26.3 重新坏掉；删掉那条实例通道会让 ≤26.2 重新坏掉。两者都要在。 */
    if (g_inputPublisherGeneration.load(std::memory_order_acquire) != 0 &&
        g_inputPublisherPid.load(std::memory_order_acquire) == static_cast<uint64_t>(getpid())) {
        amclBackendInputPublishAddress();
        inputBridge_publishAddress();
    }

    // Register C-level callback wrappers
    inputBridge_setCursorPosCallback(bridgeCursorPosCallback);
    inputBridge_setMouseButtonCallback(bridgeMouseButtonCallback);
    inputBridge_setKeyCallback(bridgeKeyCallback);
    inputBridge_setScrollCallback(bridgeScrollCallback);

    // Establish READY as soon as both source-plane callback wrappers exist.
    // The descriptor may legitimately be absent here (or select legacy); the
    // create/poll checkpoints retry without ever enabling a silent fallback.
    (void)ensureTypedInputOpen();

    // ⭐ 构建身份行。`AMCL_GATE0_EVIDENCE_IDS` 在此之前**没有任何运行期读者** ——
    // 它只被 `Gate0EvidenceIdsRecorded()` 在编译期读，于是字符串字面量根本不会进产物。
    // ⇒ `Gate0Evidence.cmake` 与 `CMakeLists.txt` 里"产物能自证是哪份证据授权了这个能力、
    // 可直接从产物反查"那两句是**假的**（规范 §八 第六条那一族）。这一行让它变成真的。
    // 它同时是双包对比的前提：两个包的日志必须能被区分，否则拿到的数字无法归属。
    // ⚠️ 每个字段都带 `{public}`，缺它 hilog 打成 `<private>`（计划 §78.4 整批栽过）。
    // ⚠️ 删掉这一行会让上面那两句注释重新变成假话 —— 要删请连它们一起改。
    OH_LOG_INFO(LOG_APP,
        "AMCL_GATE0 build evidence=%{public}s typedPhysicalDefault=%{public}d "
        "relativeVerified=%{public}d api26RawMouseMotion=%{public}d "
        "nativeAbsoluteVerified=%{public}d "
        "typedRouteLatched=%{public}d",
        AMCL_GATE0_EVIDENCE_IDS,
        amcl::input::kGlfwTypedPhysicalDefaultByBuild ? 1 : 0,
        amcl::input::kGlfwRelativeVerifiedByBuild ? 1 : 0,
        amcl::input::kGlfwApi26RawMouseMotionByBuild ? 1 : 0,
        amcl::input::kGlfwNativeAbsoluteVerifiedByBuild ? 1 : 0,
        amcl::input::LatchedGlfwInputRouteConfig().typedPhysical ? 1 : 0);

    OH_LOG_INFO(LOG_APP, "GLFW: Initialized (OHOS compat layer), input bridge published + callbacks registered");
    return GLFW_TRUE;
}

void glfwTerminate(void) {
    std::lock_guard<std::recursive_mutex> lifecycle(g_contextLifecycleMutex);
    // 主辅可以任意顺序退休；任何owner线程/驱动拒绝均保留整个GLFW寿命，不释放悬空指针。
    const auto windows = g_windows;
    for (auto* window : windows) {
        glfwDestroyWindow(window);
        if (std::find(g_windows.begin(), g_windows.end(), window) != g_windows.end()) return;
    }
    if (g_currentWindow) {
        GLFWwindow* terminatingWindow = g_currentWindow;
        glfwDestroyWindow(terminatingWindow);
        if (g_currentWindow == terminatingWindow) {
            AMCL_EXTERNAL_LOG_E(LOG_TAG,
                         "GLFW: terminate deferred because window teardown is still pending");
            return;
        }
    }
    // ⚰️ 这里曾在 terminate 时拆 zink 的进程级 OSMesa context，见 §S7。
    // By this point no GLFWwindow callback target remains. Close is idempotent
    // and clears adapter polling state even if the host session rolled stale.
    (void)typedInputAdapterClose(&g_typedInputAdapter);
    g_typedInputHost = nullptr;
    g_threadCurrentContext = nullptr;
    amcl::ohos::LeaveInteractiveRenderQoS("glfw-terminate");
    g_initialized = 0;
    OH_LOG_INFO(LOG_APP, "GLFW: Terminated");
}

void glfwWindowHint(int hint, int value) {
    switch (hint) {
        case 0x00022008: g_hintProfile = value; break;
        case 0x00022006: g_hintForwardCompatible = value != 0; break;
        case GLFW_VISIBLE: g_hintVisible = value != 0; break;
        case GLFW_CLIENT_API: g_hintClientAPI = value; break;
        case GLFW_CONTEXT_VERSION_MAJOR: g_hintMajor = value; break;
        case GLFW_CONTEXT_VERSION_MINOR: g_hintMinor = value; break;
        default: break;
    }
}

GLFWwindow* glfwCreateWindow(int width, int height, const char* title,
                              GLFWmonitor* monitor, GLFWwindow* share) {
    std::lock_guard<std::recursive_mutex> lifecycle(g_contextLifecycleMutex);
    if ((g_hintVisible && g_currentWindow) || amcl::graphics::BackendSession::quarantinedCount() != 0) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,
            "A window or failed backend still owns presentation; complete its teardown first");
        return nullptr;
    }
    const char* allowedVulkan = getenv("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN");
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    const char* selectedProfile = runtime ? runtime->profile->id : nullptr;
    const char* graphicsApi = runtime ? runtime->profile->api : nullptr;
    if (!runtime || width <= 0 || height <= 0 || (!g_hintVisible && monitor) ||
        (share && std::find(g_windows.begin(), g_windows.end(), share) == g_windows.end()) ||
        ((!g_windows.empty() || share) && !amcl::graphics::GraphicsAuxiliaryVerified(*runtime, share != nullptr))) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Invalid window dimensions, unbound provider or unsupported shared context");
        return nullptr;
    }
    const bool selectedVulkanPlan = selectedProfile && strcmp(selectedProfile, "minecraft-vulkan") == 0 &&
        graphicsApi && strcmp(graphicsApi, "VULKAN") == 0;
    const bool nativeVulkanAdmission = allowedVulkan && strcmp(allowedVulkan, "1") == 0 &&
        amclVulkanAdmissionGranted() == 1;
    const bool admittedVulkanWindow = g_hintClientAPI == GLFW_NO_API && selectedVulkanPlan &&
        nativeVulkanAdmission;
    // NO_API is the Vulkan window shape in this adapter. Never let a forged or
    // incomplete marker create one before the immutable graphics plan granted
    // native Vulkan admission. This check is independent of NativeGlRequested
    // because a desktop build may intentionally be running its Vulkan peer.
    if (g_hintClientAPI == GLFW_NO_API && !admittedVulkanWindow) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,
            "GLFW_NO_API requires an admitted Minecraft Vulkan graphics plan");
        return nullptr;
    }
    if (amcl::desktop::RuntimeProfileIs("nativegl") &&
        ((g_hintClientAPI != GLFW_OPENGL_API && !admittedVulkanWindow) || width <= 0 || height <= 0)) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,
            "Desktop host requires one OpenGL or admitted Vulkan window; shared windows are unsupported");
        return nullptr;
    }
    // MobileGL 的窗口仍有 OpenGL context；内部 Vulkan 不允许绕过 GL 生命周期。
    if (selectedProfile && strcmp(selectedProfile, "mobilegl") == 0 &&
        (g_hintClientAPI != GLFW_OPENGL_API || width <= 0 || height <= 0)) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "MobileGL requires one unshared OpenGL window");
        return nullptr;
    }
    if (share && share->context == EGL_NO_CONTEXT) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_WINDOW_CONTEXT, "Shared window has no OpenGL context");
        return nullptr;
    }
    if (!g_initialized) {
        OH_LOG_INFO(LOG_APP, "GLFW: glfwCreateWindow before glfwInit, auto-init...");
        if (!glfwInit()) return nullptr;
    }
    const EGLDisplay previousDisplay = runtime->egl.ready ? eglGetCurrentDisplay() : EGL_NO_DISPLAY;
    const EGLContext previousContext = runtime->egl.ready ? eglGetCurrentContext() : EGL_NO_CONTEXT;
    const EGLSurface previousDraw = runtime->egl.ready ? eglGetCurrentSurface(EGL_DRAW) : EGL_NO_SURFACE;
    const EGLSurface previousRead = runtime->egl.ready ? eglGetCurrentSurface(EGL_READ) : EGL_NO_SURFACE;
    const auto restorePrevious = [&]() {
        if (previousContext == EGL_NO_CONTEXT) return true;
        const bool restored = eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext) == EGL_TRUE;
        if (!restored) {
            setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
            amclGraphicsFatalV1("context-restore-failed", 0, 0);
        }
        return restored;
    };
    GLFWwindow* win = new GLFWwindow();
    memset(win, 0, sizeof(GLFWwindow));
    win->clientAPI = g_hintClientAPI;
    // The live object address is unique across duplicate libglfw images too.
    // The WSI live-surface guard prevents freeing/reusing it before retirement.
    win->windowId = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(win));
    win->width = width;
    win->height = height;
    // Copy: the caller's buffer (LWJGL MemoryStack) dies when this returns.
    win->title = title ? strdup(title) : nullptr;
    win->focused = g_hintVisible ? 1 : 0;
    win->visible = g_hintVisible;
    win->cursorMode = GLFW_CURSOR_NORMAL;
    win->auxiliary = !g_hintVisible && win->clientAPI != GLFW_NO_API;
    win->display = EGL_NO_DISPLAY;
    win->surface = EGL_NO_SURFACE;
    win->context = EGL_NO_CONTEXT;
    win->shareContext = share ? share->context : EGL_NO_CONTEXT;
    // 在分配任何驱动资源之前登记一次；可见窗口、隐藏窗口和部分初始化失败都共用同一清理集合。
    g_windows.push_back(win);

    if (win->auxiliary) {
        // 离屏窗口不取得NativeWindow/呈现token、不打开输入目标，也不触发世界首帧。
        // 首个隐藏窗口可稍后show成为主窗口；额外context已在上面的实测能力门通过。
        win->sizeNotifications.Prime(++g_windowLifetime, width, height);
        if (!InitEGL(win) || !eglMakeCurrent(win->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            amclGraphicsFatalV1("window-create-failed", 0, 0);
            glfwDestroyWindow(win); (void)restorePrevious(); return nullptr;
        }
        win->contextOwnerTid = 0;
        if (!restorePrevious()) { glfwDestroyWindow(win); return nullptr; }
        return win;
    }

    OH_LOG_INFO(LOG_APP, "GLFW: glfwCreateWindow thread=%{public}d", (int)gettid());

    void* nativeWindow = nullptr;
    int nwWidth = 0, nwHeight = 0;

    uint64_t nativeWindowGeneration = 0;
    void* nativeWindowLeaseBroker = nullptr;
    bool nativeWindowFromSnapshot =
        glfwOHOS_AcquireNativeWindowSnapshot(
            nullptr, 0, nullptr, &nativeWindow, &nwWidth, &nwHeight,
            &nativeWindowGeneration,
            &nativeWindowLeaseBroker) != 0;
    if (!nativeWindowFromSnapshot) {
        // An invalid-size publication is a deliberate suspended epoch, not a
        // usable pointer. Keep it out of EGL until a newer valid generation.
        nativeWindow = nullptr;
    }

    // 兼容旧宿主：尚未调用原子发布 API 时才回退到环境变量。
    const char* envPtr = nullptr;
    if (!nativeWindow && nativeWindowGeneration == 0) {
        envPtr = getenv("AMCL_NATIVE_WINDOW");
        if (envPtr && envPtr[0] != '\0') {
            nativeWindow = (void*)(uintptr_t)strtoull(envPtr, nullptr, 10);
            nativeWindowGeneration = 0;
            const char* envW = getenv("AMCL_WINDOW_WIDTH");
            const char* envH = getenv("AMCL_WINDOW_HEIGHT");
            if (envW) nwWidth = atoi(envW);
            if (envH) nwHeight = atoi(envH);
        }
    }

    if (!nativeWindow) {
        OH_LOG_INFO(LOG_APP, "GLFW: Waiting for NativeWindow (env AMCL_NATIVE_WINDOW)...");
        int waitMs = 0;
        while (!nativeWindow && waitMs < 30000) {
            usleep(50000);
            waitMs += 50;
            nativeWindowFromSnapshot =
                glfwOHOS_AcquireNativeWindowSnapshot(
                    nullptr, 0, nullptr, &nativeWindow, &nwWidth, &nwHeight,
                    &nativeWindowGeneration,
                    &nativeWindowLeaseBroker) != 0;
            if (!nativeWindowFromSnapshot) {
                nativeWindow = nullptr;
                if (nativeWindowGeneration == 0) {
                    envPtr = getenv("AMCL_NATIVE_WINDOW");
                    if (envPtr && envPtr[0] != '\0') {
                        nativeWindow = (void*)(uintptr_t)strtoull(envPtr, nullptr, 10);
                        const char* envW = getenv("AMCL_WINDOW_WIDTH");
                        const char* envH = getenv("AMCL_WINDOW_HEIGHT");
                        if (envW) nwWidth = atoi(envW);
                        if (envH) nwHeight = atoi(envH);
                    }
                }
            }
            if (waitMs % 2000 == 0 && !nativeWindow) {
                OH_LOG_INFO(LOG_APP, "GLFW: Still waiting... %{public}dms env=%{public}s",
                            waitMs, envPtr ? envPtr : "null");
            }
        }
    }
    bool backendReady = false;
    if (nativeWindow) {
        win->nativeWindow = nativeWindow;
        win->nativeWindowLeaseBroker = nativeWindowLeaseBroker;
        win->nativeWindowLeaseObject = nativeWindowLeaseBroker ? nativeWindow : nullptr;
        nativeWindowLeaseBroker = nullptr;
        win->nativeWindowGeneration = nativeWindowGeneration;
        if (nwWidth > 0) win->width = nwWidth;
        if (nwHeight > 0) win->height = nwHeight;
        if (win->clientAPI == GLFW_NO_API) {
            // The WSI shim claims its own token when vkCreateSurfaceOHOS runs.
            backendReady = win->nativeWindowLeaseBroker && win->nativeWindowGeneration != 0;
        } else {
            for (int attempt = 0; attempt <= 5 && !backendReady; ++attempt) {
                // context lost 已要求结束本局；即使部分清理成功，也不能在同一创建循环
                // 中再分配一个空context冒充恢复。外层仍负责真实退休和冷进程失败回执。
                if (win->contextLostFatal) break;
                if (attempt != 0) {
                    // The previous adapter must finish actual EGL teardown
                    // before another attempt may claim the presentation token.
                    if (!destroyGraphicsBackendSession(win, false)) break;
                    usleep(500000);
                    void* nextWindow = nullptr;
                    int nextWidth = 0;
                    int nextHeight = 0;
                    uint64_t nextGeneration = 0;
                    void* nextBroker = nullptr;
                    const int snapshotResult = glfwOHOS_AcquireNativeWindowSnapshot(
                        win->nativeWindowLeaseObject, win->nativeWindowGeneration,
                        win->nativeWindowLeaseBroker, &nextWindow, &nextWidth, &nextHeight,
                        &nextGeneration, &nextBroker);
                    ScopedNativeWindowLease nextLease(nextWindow, nextBroker);
                    if (!snapshotResult || !nextWindow) {
                        releaseWindowNativeWindowLease(win);
                        win->nativeWindow = nullptr;
                        win->nativeWindowGeneration = nextGeneration;
                        continue;
                    }
                    if (nextBroker) adoptWindowNativeWindowLease(win, nextWindow, nextLease);
                    win->nativeWindow = nextWindow;
                    win->nativeWindowGeneration = nextGeneration;
                    win->width = nextWidth;
                    win->height = nextHeight;
                }
                if (!win->nativeWindow) continue;
                backendReady = attachGraphicsBackendSession(win);
                if (!backendReady) {
                    AMCL_EXTERNAL_LOG_W(LOG_TAG, "GLFW: owned EGL initialization attempt %{public}d failed", attempt + 1);
                }
            }
        }
    }
    if (!backendReady) {
        amclGraphicsFatalV1("window-create-failed", 0, win->nativeWindowGeneration);
        if (destroyGraphicsBackendSession(win, false)) {
            releaseWindowNativeWindowLease(win);
            free(const_cast<char*>(win->title));
            g_windows.erase(std::remove(g_windows.begin(), g_windows.end(), win), g_windows.end());
            delete win;
        } else {
            win->contextLostFatal = true;
            win->shouldClose = 1;
            g_currentWindow = win;
            setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
        }
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,
            "Window creation failed: the native window and presentation owner must both be available");
        (void)restorePrevious();
        return nullptr;
    }
    g_currentWindow = win;
    win->sizeNotifications.Prime(++g_windowLifetime, win->width, win->height);
    glfwOHOS_PrimeDesktopWindow(win);
    publishTypedWindowInputBinding(win, isBackendSurfaceReady(win));
    // The GLFW window has now accepted one concrete surface size. Commit the same pair to the input bridge
    // before any LWJGL2/3 consumer can query dimensions; env remains transport between linker namespaces,
    // not a second runtime state source.
    inputBridge_setWindowSize(win->width, win->height);
    // A host session may not exist at glfwInit time. Retry only after the final
    // callback target and the accepted window size are visible, so events
    // admitted by READY cannot dispatch into a half-published GLFWwindow.
    (void)ensureTypedInputOpen();

    // 验证 GL context 是否正常工作
    if (win->display != EGL_NO_DISPLAY) {
#if AMCL_NATIVE_DESKTOP_ONLY
        const auto getError = reinterpret_cast<decltype(&glGetError)>(amcl::desktop::NativeGlProc("glGetError"));
#else
        const auto getError = reinterpret_cast<decltype(&glGetError)>(glfwGetProcAddress("glGetError"));
#endif
#if AMCL_NATIVE_DESKTOP_ONLY
        const auto getString = reinterpret_cast<decltype(&glGetString)>(amcl::desktop::NativeGlProc("glGetString"));
#else
        const auto getString = reinterpret_cast<decltype(&glGetString)>(glfwGetProcAddress("glGetString"));
#endif
        GLenum err = getError ? getError() : GL_INVALID_OPERATION;
        const char* vendor = getString ? reinterpret_cast<const char*>(getString(GL_VENDOR)) : nullptr;
        const char* renderer = getString ? reinterpret_cast<const char*>(getString(GL_RENDERER)) : nullptr;
        const char* version = getString ? reinterpret_cast<const char*>(getString(GL_VERSION)) : nullptr;
        OH_LOG_INFO(LOG_APP, "GLFW: GL context OK! glGetError=0x%{public}x", err);
        OH_LOG_INFO(LOG_APP, "GLFW: GL_VENDOR=%{public}s", vendor ? vendor : "null");
        OH_LOG_INFO(LOG_APP, "GLFW: GL_RENDERER=%{public}s", renderer ? renderer : "null");
        OH_LOG_INFO(LOG_APP, "GLFW: GL_VERSION=%{public}s", version ? version : "null");
        // 通过宿主唯一日志桥交付实际上下文事实；独立 GLFW DSO 不反向链接 libentry。
        if (vendor) amclExternalLogWrite(1, "SessionEnvironment", "AMCL_ENV_V1\tgpu.vendor\t%s\tGLFW.current-context", vendor);
        if (renderer) amclExternalLogWrite(1, "SessionEnvironment", "AMCL_ENV_V1\tgpu.model\t%s\tGLFW.current-context", renderer);
        if (version) amclExternalLogWrite(1, "SessionEnvironment", "AMCL_ENV_V1\tgpu.apiVersion\t%s\tGLFW.current-context", version);

    }

    // 标准 GLFW 行为：glfwCreateWindow 创建上下文但不使其为当前
    // 应用程序应调用 glfwMakeContextCurrent() 在需要的线程上绑定上下文
    // Forge EarlyDisplay: Thread-0 创建窗口 → 渲染线程调用 glfwMakeContextCurrent(window)
    // 如果不释放，渲染线程的 eglMakeCurrent 会因 EGL_BAD_ACCESS(0x3002) 失败
    // ⚰️ zink 曾在此建 OSMesa GL4.6 context + OHNativeWindow CPU producer，见 §S7。
    if (win->display != EGL_NO_DISPLAY) {
        const bool released = eglMakeCurrent(win->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) == EGL_TRUE;
        if (!released) {
            if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,"OpenGL context release failed");
            glfwDestroyWindow(win);
            (void)restorePrevious();
            return nullptr;
        }
        if (released) win->contextOwnerTid = 0;
        OH_LOG_INFO(LOG_APP, "GLFW: Released EGL context after creation (standard GLFW behavior)");
    }

    OH_LOG_INFO(LOG_APP, "GLFW: Window created \"%s\" (%dx%d) EGL=%{public}s thread=%{public}d",
                title, win->width, win->height,
                win->display != EGL_NO_DISPLAY ? "yes" : "NO", (int)gettid());
    if (!restorePrevious()) { glfwDestroyWindow(win); return nullptr; }
    if (monitor && !glfwOHOS_ApplyInitialMonitor(win, monitor, width, height)) {
        glfwDestroyWindow(win); (void)restorePrevious(); return nullptr;
    }
    return win;
}

void glfwDestroyWindow(GLFWwindow* window) {
    std::lock_guard<std::recursive_mutex> lifecycle(g_contextLifecycleMutex);
    if (!window || std::find(g_windows.begin(), g_windows.end(), window) == g_windows.end()) return;
    // 先验证线程所有权，再触碰输入、取消标记或teardown字段，拒绝不能损坏活窗口。
    if (window->contextOwnerTid && window->contextOwnerTid != static_cast<int>(gettid())) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Release the context on its owner thread before destruction");
        return;
    }
    if (window->auxiliary && !window->graphicsBackendSession) {
        if (!TerminateEGL(window)) return;
        if (g_threadCurrentContext == window) g_threadCurrentContext = nullptr;
        g_windows.erase(std::remove(g_windows.begin(), g_windows.end(), window), g_windows.end());
        free(const_cast<char*>(window->title)); glfwOHOS_DestroyPreeditState(window); delete window;
        return;
    }
    if (window->clientAPI == GLFW_NO_API && amclVulkanWindowHasLiveSurface(window->windowId)) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: window %{public}llu still has a game-owned VkSurface; destruction deferred",
            static_cast<unsigned long long>(window->windowId));
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,
            "Destroy the Vulkan surface before destroying its GLFW window");
        return;
    }
    // The EGL adapter retains the token until its real teardown completes.
    if (!window->sizeNotifications.closed) {
        const auto& sizes = window->sizeNotifications;
        OH_LOG_INFO(LOG_APP, "GLFW: resize lifecycle=%{public}llu observed=%{public}llu "
            "framebufferDispatched=%{public}llu windowDispatched=%{public}llu coalesced=%{public}llu",
            (unsigned long long)sizes.lifetime, (unsigned long long)sizes.observed,
            (unsigned long long)sizes.framebufferDispatched, (unsigned long long)sizes.windowDispatched,
            (unsigned long long)sizes.coalesced);
    }
    window->sizeNotifications.Cancel();
    // 关键区分（2026-06 Vulkan 实验定位）：窗口销毁 ≠ MC 退出。
    //   MC 官方 Vulkan 后端协商失败时会**销毁窗口再重建**走 OpenGL 回退（实测日志：
    //   destroy → 立刻又 createWindow + eglMakeCurrent OK）。若无条件把"窗口销毁"当成
    //   "MC 已退出"写 marker，看门狗 mcIsRunning() 会在 MC 正常回退途中把进程 _exit(0) 误杀。
    //   真正的退出有两个可靠信号：① 用户关闭 → window->shouldClose 被置 true（关闭回调）；
    //   ② MC main() 返回 → 启动线程把 g_mcRunning 置 false（mcIsRunning 首先就检查它）。
    //   因此这里只在 shouldClose=true（真退出）时才写 marker；shouldClose=false 视为
    //   后端切换/重建的瞬态销毁，不发退出信号。即便某些退出路径没置 shouldClose，
    //   g_mcRunning 仍会兜底，不会漏判真退出。
    bool genuineExit = (window->shouldClose != 0);
    OH_LOG_INFO(LOG_APP, "GLFW: glfwDestroyWindow called (shouldClose=%{public}d → %{public}s)",
                window->shouldClose, genuineExit ? "genuine exit" : "transient (backend switch?)");
    if (genuineExit) {
        // 真退出：停止渲染线程栈采样器（瞬态销毁/后端切换不停，渲染线程会重建并重新绑定）。
        amcl_sampler_stop();
    }
    // ⚰️ 这里曾有一整段 zink 专属的销毁前处理（进程级 OSMesa context 刻意跨越
    //    瞬态 destroy/recreate：先摘 NativeWindow、再按实际 owner tid 决定是否
    //    推迟销毁、真退出时才 teardown）。zink 已退役，见 §S7。
    // window 仍有效时完成整个输入取消事务，而不只结束菜单 token：
    // libentry owner/finger → 旧 window 已消费的 key/mouse RELEASE → 丢弃旧 ring 批次 → LWJGL2 reset。
    // reason=5 与公开 AmclInputCancelReason::WINDOW_RECREATE 一致。必须发生在 TerminateEGL/delete 前，
    // 否则 RELEASE callback 可能持有已销毁 window，或旧 pending 事件落入紧随其后的新窗口。
    clearTypedWindowInputBinding(window);
    glfwSetCharCallback(window, nullptr);
    glfwSetCharModsCallback(window, nullptr);
    glfwSetCursorEnterCallback(window, nullptr);
    inputBridge_cancelAllState(window, 5);
    // The typed RESET queued by libentry cannot be pumped while destroy is in
    // progress. Close its consumer synchronously while the old callback target
    // is valid, then fail-safe clear any plane whose release was unavailable.
    // ClearAll dispatches outside its lock and is idempotent after normal edges.
    (void)typedInputAdapterClose(&g_typedInputAdapter);
    g_typedInputHost = nullptr;
    g_sourcePlaneAggregate.ClearAll(aggregateSink(window));
    if (!destroyGraphicsBackendSession(window, false)) {
        clearEglTlsAfterPartialDetach(window);
        setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
        AMCL_EXTERNAL_LOG_E(LOG_TAG,
                     "GLFW: BackendSession retained its token and lease after failed EGL teardown");
        return;
    }
    releaseWindowNativeWindowLease(window);
    window->nativeWindow = nullptr;
    if (g_threadCurrentContext == window) g_threadCurrentContext = nullptr;
    amcl::ohos::LeaveInteractiveRenderQoS("window-destroyed");
    if (g_currentWindow == window) g_currentWindow = nullptr;
    g_windows.erase(std::remove(g_windows.begin(), g_windows.end(), window), g_windows.end());
    free(const_cast<char*>(window->title));
    window->title = nullptr;
    glfwOHOS_DestroyPreeditState(window);
    delete window;
    OH_LOG_INFO(LOG_APP, "GLFW: Window destroyed");

    if (!genuineExit) {
        // 瞬态销毁（后端切换/重建）——不写退出 marker，避免看门狗误杀正在回退的 MC。
        OH_LOG_INFO(LOG_APP, "GLFW: skip exit marker (transient window destroy, MC likely recreating window)");
        return;
    }

    // 真退出：写标记文件通知 mcIsRunning()，路径从环境变量获取（避免硬编码）
    const char* filesDir = getenv("AMCL_FILES_DIR");
    std::string marker;
    if (filesDir && filesDir[0]) {
        marker = std::string(filesDir) + "/.mc_window_destroyed";
    } else {
        marker = "/data/storage/el2/base/haps/entry/files/.mc_window_destroyed";
    }
    FILE* f = fopen(marker.c_str(), "w");
    if (f) {
        fprintf(f, "1");
        fclose(f);
        OH_LOG_INFO(LOG_APP, "GLFW: Wrote window destroy marker file (genuine exit)");
    } else {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: Failed to write marker file: %{public}s", marker.c_str());
    }
}

int glfwWindowShouldClose(GLFWwindow* window) {
    int val = window ? window->shouldClose : 1;
    // 只在 shouldClose 变为 true 时打一次日志
    if (val && !s_loggedClose) {
        s_loggedClose = true;
        OH_LOG_INFO(LOG_APP, "GLFW: glfwWindowShouldClose returning TRUE — MC is closing");
    }
    return val;
}

void glfwSetWindowShouldClose(GLFWwindow* window, int value) {
    if (window) {
        if (window->contextLostFatal && !value) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                        "GLFW: ignoring attempt to clear shouldClose after fatal context loss");
            return;
        }
        window->shouldClose = value;
        if (value) {
            OH_LOG_INFO(LOG_APP, "GLFW: glfwSetWindowShouldClose(TRUE) called — MC requesting close");
        }
    }
}

void glfwSwapBuffers(GLFWwindow* window) {
    if (window && window->auxiliary) {
        if (g_threadCurrentContext != window || window->contextOwnerTid != static_cast<int>(gettid())) {
            if (g_errorCallback) g_errorCallback(GLFW_NO_CURRENT_CONTEXT, "Auxiliary swap requires its owning current context");
            return;
        }
        if (eglSwapBuffers(window->display, window->surface) != EGL_TRUE && g_errorCallback)
            g_errorCallback(GLFW_PLATFORM_ERROR, "Auxiliary pbuffer swap failed");
        return;
    }

    if (window && window->clientAPI == GLFW_NO_API) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_WINDOW_CONTEXT, "A GLFW_NO_API window has no OpenGL swap operation");
        return;
    }
    if (!window || window->contextLostFatal || window->eglTeardownPending) return;
    // 三条 GL 路线均先验证真实 current，再消费宿主发布。SwapBuffers 不能替应用
    // 重新绑定已经显式释放的 context，也不能从其他线程抢走仍在停车的 context。
    const EGLenum clientApi = amcl::desktop::UsesDesktopOpenGlContext() ? EGL_OPENGL_API : EGL_OPENGL_ES_API;
    if (eglBindAPI(clientApi) != EGL_TRUE || g_threadCurrentContext != window ||
         eglGetCurrentDisplay() != window->display ||
         eglGetCurrentContext() != window->context) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_CURRENT_CONTEXT,"OpenGL swap requires this window's current context");
        return;
    }
    if (window->eglSurfaceDetachPending) {
        const long long now = currentTimeMs();
        if (now < window->nextSurfaceRecoveryAttemptMs) return;
        const int currentTid = static_cast<int>(gettid());
        if (window->contextOwnerTid != 0 && window->contextOwnerTid != currentTid) {
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                        "GLFW: stale EGLSurface detach retry refused on thread %{public}d; "
                        "owner=%{public}d",
                        currentTid, window->contextOwnerTid);
            return;
        }
        if (!suspendGraphicsBackendSession(window)) {
            markEglSurfaceDetachPending(window, "owner-retry");
            return;
        }
        window->eglSurfaceDetachPending = false;
        clearEglContextOwnershipAfterDetach(window, "egl-stale-surface-detached");
        window->surfaceRecoveryFailures = 0;
        window->nextSurfaceRecoveryAttemptMs = 0;
    }
    // Surface callbacks run on the ArkUI thread. Consume their latest atomic
    // epoch here before touching either EGLSurface or OHNativeWindow, so a
    // frame can never be presented through a destroyed/replaced pointer even
    // when Minecraft skipped glfwPollEvents for this iteration.
    if (!consumePublishedSurfaceState(window, "swap", true)) {
        return;
    }
    // 恢复成功才允许真正 present，parking surface 不能计作窗口呈现。
    if (g_threadCurrentContext != window || eglGetCurrentContext() != window->context ||
        eglGetCurrentDisplay() != window->display || eglGetCurrentSurface(EGL_DRAW) != window->surface) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_CURRENT_CONTEXT,"OpenGL swap requires this window's current context and surface");
        return;
    }
    // ⚰️ zink 曾在此 lock/flush 租来的 OHNativeWindow producer buffer 并直接返回，
    //    不走下面的 eglSwapBuffers。zink 已退役，见 §S7。
    if (window && window->display != EGL_NO_DISPLAY && window->surface != EGL_NO_SURFACE) {
        const bool sampleSwap = amclGraphicsObservationEnabledV1() != 0;
        uint64_t beforePresent = 0;
        const bool requiresPresentEvidence = amclGraphicsReadPresentSequenceV1(&beforePresent) != 0;
        const auto swapStarted = sampleSwap ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
        const EGLBoolean swapped = eglSwapBuffers(window->display, window->surface);
        const uint64_t swapNs = sampleSwap ? static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - swapStarted).count()) : 0;
        uint64_t afterPresent = 0;
        const bool actualPresent = requiresPresentEvidence ?
            amclGraphicsReadPresentSequenceV1(&afterPresent) && afterPresent > beforePresent : swapped == EGL_TRUE;
        // 本帧已经呈现而下一帧acquire失败时，两种事实都成立：先推进呈现安全计数，
        // 再记录失败，避免首帧之后的致命错误被误当成可冷重试的首帧前故障。
        if (actualPresent && swapped != EGL_TRUE) {
            recordGraphicsBackendSessionPresent(window);
            inputBridge_notifyFramePresented();
            observePresentedFrame();
        }
        if (swapped != EGL_TRUE) {
            const EGLint error = eglGetError();
            amclGraphicsSwapV1("GLFW", swapNs, 0, static_cast<uint32_t>(error));
            if (error == EGL_CONTEXT_LOST) {
                amclGraphicsFatalV1("egl-context-lost", static_cast<uint32_t>(error), window->nativeWindowGeneration);
                // A new context would not contain Minecraft's textures,
                // buffers, programs, or sync objects.  Never advertise this as
                // a recovered surface; terminate the unusable EGL state and
                // make the standard close path report a genuine session exit.
                AMCL_EXTERNAL_LOG_E(LOG_TAG,
                             "GLFW: EGL_CONTEXT_LOST is fatal; requesting game shutdown");
                window->contextLostFatal = true;
                window->shouldClose = 1;
                window->eglSurfaceDetachPending = false;
                if (destroyGraphicsBackendSession(window, false)) {
                    clearEglContextOwnershipAfterDetach(window,
                                                        "egl-context-lost-fatal");
                } else {
                    clearEglTlsAfterPartialDetach(window);
                    AMCL_EXTERNAL_LOG_E(LOG_TAG,
                                 "GLFW: fatal context teardown deferred; handles/lease retained");
                }
                if (g_errorCallback) {
                    g_errorCallback(GLFW_PLATFORM_ERROR,
                                    "HarmonyOS EGL context was lost; GL resources cannot be recovered");
                }
                return;
            }
            AMCL_EXTERNAL_LOG_W(LOG_TAG,
                        "GLFW: eglSwapBuffers failed 0x%{public}x; scheduling surface recovery",
                        error);
            if (error == EGL_BAD_SURFACE || error == EGL_BAD_NATIVE_WINDOW) {
                if (suspendGraphicsBackendSession(window)) {
                    scheduleSurfaceRecovery(window);
                    clearEglContextOwnershipAfterDetach(window, "egl-swap-surface-lost");
                } else {
                    // Keep the NativeWindow lease: EGL may still own the stale
                    // surface.  Block all presentation and retry detach with
                    // backoff on this same owner thread.
                    clearEglTlsAfterPartialDetach(window);
                    markEglSurfaceDetachPending(window, "swap-failure");
                }
            } else {
                scheduleSurfaceRecovery(window);
            }
            return;
        }
        window->surfaceRecoveryFailures = 0;
        window->nextSurfaceRecoveryAttemptMs = 0;
        // MobileGL可以因零面积合法暂缓而返回EGL_TRUE；只有实际序列推进才放行输入、
        // 学习历史或累计游戏帧。普通EGL后端继续采用其原有成功语义。
        if (!actualPresent) return;
        recordGraphicsBackendSessionPresent(window);
        amclGraphicsSwapV1("GLFW", swapNs, 1, 0);
        inputBridge_notifyFramePresented();
        observePresentedFrame();
    }
}

void glfwPollEvents(void) {
    const auto* eventHost = amclDesktopHostResolve();
    if (eventHost) g_desktopPolledEpoch = eventHost->eventEpoch();
    glfwOHOS_PollDesktopDisplays();
    if (g_currentWindow) {
        const auto* host = amclDesktopHostResolve();
        if (host) {
            AmclDesktopSnapshot facts{}; host->snapshot(&facts);
            if (facts.closeRequested && !g_currentWindow->shouldClose) {
                g_currentWindow->shouldClose = 1;
                if (g_currentWindow->closeCb) g_currentWindow->closeCb(g_currentWindow);
            }
        }
    }
    g_pollCount++;
    if (!g_currentWindow) return;

    // glfwPollEvents may run on ArkUI/the main thread while rendering occurs
    // elsewhere. Only the thread whose GLFW TLS says this context is current
    // may read/mutate the plain render lifecycle fields; swap/MakeCurrent are
    // the authoritative checkpoints for all other arrangements.
    if (g_currentWindow->clientAPI == GLFW_NO_API) {
        consumePublishedSurfaceState(g_currentWindow, "poll-no-api", false);
        GLFWwindow* dispatchWindow = g_currentWindow;
        if (!amcl::glfw::DispatchSizeNotifications(dispatchWindow,
            [](GLFWwindow* candidate, uint64_t lifetime) {
                return g_currentWindow == candidate && candidate->sizeNotifications.lifetime == lifetime &&
                    !candidate->sizeNotifications.closed;
            })) return;
    } else if (g_threadCurrentContext == g_currentWindow) {
        consumePublishedSurfaceState(g_currentWindow, "poll", false);
        GLFWwindow* dispatchWindow = g_currentWindow;
        if (dispatchWindow->contextLostFatal || dispatchWindow->eglTeardownPending ||
            dispatchWindow->context == EGL_NO_CONTEXT ||
            eglGetCurrentContext() != dispatchWindow->context) return;
        if (!amcl::glfw::DispatchSizeNotifications(dispatchWindow,
            [](GLFWwindow* candidate, uint64_t lifetime) {
                return g_currentWindow == candidate &&
                    candidate->sizeNotifications.lifetime == lifetime &&
                    !candidate->sizeNotifications.closed;
            })) return;
    }

    // Typed physical input and the compatibility ring have disjoint producers
    // in typed startup mode. Pump typed first so its polling state is current;
    // keep legacy pumping for phone/tablet virtual controls and gamepads.
    pumpTypedInput();
    inputBridgeStartPumping();
    inputBridgePumpEvents((void*)g_currentWindow);
    inputBridgeStopPumping();

    // 诊断信息：只在首次 poll 打一次（确认 poll 循环已起来）。
    // v7.3：原来每 60 万次 poll 打一行 [GLFW-DIAG]，会持续刷进 mc_output.log，
    // 尤其在 MC 退出（Stopping!）之后 poll 循环空转还在打 → 把"Stopping!"挤出日志尾部，
    // 导致 SessionMarker.looksLikeNormalExit 读不到关闭标记、把【正常退出】误判成崩溃、
    // 弹错误 Sheet（且技术详情里全是这条刷屏行）。改为只打一次，既留启动确认又不污染日志。
    static bool s_pollDiagLogged = false;
    if (!s_pollDiagLogged) {
        s_pollDiagLogged = true;
        // Do not read GLFWwindow fields here: PollEvents is permitted on a
        // non-render thread and resize/destroy mutate those plain fields.
        fprintf(stderr, "[GLFW-DIAG] poll#1 swap=%d touches=%d\n",
                g_swapCount, g_touchTotalCount);
        fflush(stderr);
    }
}

void glfwMakeContextCurrent(GLFWwindow* window) {
    std::lock_guard<std::recursive_mutex> lifecycle(g_contextLifecycleMutex);
    if (window && window->clientAPI == GLFW_NO_API) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_WINDOW_CONTEXT, "A GLFW_NO_API window has no OpenGL context");
        return;
    }
    if (!window && !g_threadCurrentContext) return;
    const int currentTid = static_cast<int>(gettid());
    // EGL 的 client API 与 current 查询均按线程生效；接收线程必须选择对应 API。
    // MG 还在 wrapper 中记录 frontend API，GL4ES 的 context 则来自系统 GLES。
    const EGLenum clientApi = amcl::desktop::UsesDesktopOpenGlContext() ? EGL_OPENGL_API : EGL_OPENGL_ES_API;
    if (eglBindAPI(clientApi) != EGL_TRUE) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR,"Cannot select this thread's EGL client API");
        return;
    }
    if (!window) {
        GLFWwindow* releasedWindow = g_threadCurrentContext;
        // ⚰️ zink 曾在此走 osmesaReleaseCurrent() 而非 eglMakeCurrent(NULL)，见 §S7。
        EGLDisplay curDisplay = eglGetCurrentDisplay();
        if (curDisplay != EGL_NO_DISPLAY) {
            EGLBoolean rc =
                eglMakeCurrent(curDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (rc != EGL_TRUE) {
                AMCL_EXTERNAL_LOG_W(LOG_TAG,
                            "GLFW: eglMakeCurrent(NULL) failed: 0x%{public}x "
                            "(thread %{public}d)",
                            eglGetError(), currentTid);
                if (g_errorCallback)
                    g_errorCallback(GLFW_PLATFORM_ERROR, "EGL context release failed; binding retained");
                return;
            }
        }
        if (releasedWindow && releasedWindow->contextOwnerTid == currentTid) {
            releasedWindow->contextOwnerTid = 0;
        }
        g_threadCurrentContext = nullptr;
        amcl::ohos::LeaveInteractiveRenderQoS("context-released");
        OH_LOG_INFO(LOG_APP, "GLFW: context actually released (thread %{public}d)", currentTid);
        return;
    }

    if (window->contextLostFatal || window->eglTeardownPending) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: refusing MakeCurrent after fatal EGL context loss");
        if (g_errorCallback)
            g_errorCallback(GLFW_PLATFORM_ERROR, "EGL context is lost or awaiting teardown");
        return;
    }

    if (window->contextOwnerTid != 0 && window->contextOwnerTid != currentTid) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
                    "GLFW: refusing context bind on thread %{public}d; owner is %{public}d",
                    currentTid, window->contextOwnerTid);
        if (g_errorCallback)
            g_errorCallback(GLFW_PLATFORM_ERROR, "EGL context is current on another thread");
        return;
    }
    // ⚰️ zink 曾在此额外校验进程级 OSMesa context 的实际 owner tid，见 §S7。
    GLFWwindow* previousWindow = g_threadCurrentContext;

    // Render-thread acquisition checkpoint: callbacks may have published Lost
    // or Replaced after create/release but before Forge claims the context. Do
    // not bind a stale EGLSurface; consume and safely detach/attach first.
    const bool presentationReady = window->auxiliary || consumePublishedSurfaceState(window, "make-current", true);
    EGLSurface contextSurface = window->surface;
    if (!presentationReady) {
        if (window->contextLostFatal || window->eglTeardownPending) return;
        // 显式 MakeCurrent 在宿主暂不能呈现时仍可工作。使用初次初始化已验证的停车
        // surface，继续使用原 context/对象域；不分 nativegl、MG 或 GL4ES。
        contextSurface = window->parkingSurface;
    }

    // ⚰️ zink 曾在此把 GL4.6 context 绑到它的 render-thread park buffer 并直接返回，
    //    不走下面的 eglMakeCurrent。zink 已退役，见 §S7。
    if (window->display != EGL_NO_DISPLAY && contextSurface != EGL_NO_SURFACE &&
        window->context != EGL_NO_CONTEXT) {
        const bool alreadyCurrent = eglGetCurrentDisplay() == window->display &&
                                    eglGetCurrentContext() == window->context &&
                                    eglGetCurrentSurface(EGL_DRAW) == contextSurface &&
                                    eglGetCurrentSurface(EGL_READ) == contextSurface;
        EGLBoolean rc = alreadyCurrent
                            ? EGL_TRUE
                            : eglMakeCurrent(window->display, contextSurface,
                                             contextSurface, window->context);
        if (rc == EGL_TRUE) {
            OH_LOG_INFO(LOG_APP, "GLFW: eglMakeCurrent OK (thread %{public}d)", (int)gettid());
            // 持有 GL context 的线程即渲染线程。记录其 tid 并启动 native 栈采样器，
            // 用于定位"渲染线程 native 层 CPU 空转/黑屏"的根因（仅在停滞时才打印）。
            if (!window->auxiliary) {
                amcl_sampler_set_render_tid((int)gettid());
                amcl_sampler_start();
                amcl::ohos::EnterInteractiveRenderQoS("egl");
            }
            if (previousWindow && previousWindow != window &&
                previousWindow->contextOwnerTid == currentTid) {
                previousWindow->contextOwnerTid = 0;
            }
            window->contextOwnerTid = currentTid;
            g_threadCurrentContext = window;
            // 注：gl4es（老 MC ≤1.16.5 固定管线后端）不再需要在此显式初始化。gl4es 由 LWJGL 经
            //   org.lwjgl.opengl.libname 在 JVM 命名空间加载，并在【首个 GL 调用】时自行懒初始化
            //   （OHOS 补丁 0002：getter.c 入口调 gl4es_ensure_init），那一刻正好在本渲染线程、
            //   context 已 current、且非 dlopen 内 → 安全。详见 prebuilt/gl4es/README.md。
        } else {
            AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: eglMakeCurrent FAILED: 0x%{public}x (thread %{public}d)",
                         eglGetError(), (int)gettid());
            if (g_errorCallback)
                g_errorCallback(GLFW_PLATFORM_ERROR, "EGL context bind failed");
        }
    } else {
        AMCL_EXTERNAL_LOG_W(LOG_TAG,
                    "GLFW: makeContextCurrent but EGL backend is incomplete (thread %{public}d)",
                    currentTid);
        if (g_errorCallback)
            g_errorCallback(GLFW_PLATFORM_ERROR, "EGL context or surface is unavailable");
    }
}

bool glfwOHOS_PromoteWindow(GLFWwindow* window) {
    std::lock_guard<std::recursive_mutex> lifecycle(g_contextLifecycleMutex);
    if (!window || std::find(g_windows.begin(), g_windows.end(), window) == g_windows.end()) return false;
    if (!window->auxiliary) { window->visible = true; return true; }
    if (g_currentWindow || window->contextLostFatal || window->eglTeardownPending ||
        (window->contextOwnerTid && window->contextOwnerTid != static_cast<int>(gettid()))) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Only one presented window is supported; promotion requires its context owner");
        return false;
    }
    void* nativeWindow = nullptr; void* brokerPointer = nullptr;
    int width = 0, height = 0; uint64_t generation = 0;
    if (glfwOHOS_AcquireNativeWindowSnapshot(nullptr, 0, nullptr, &nativeWindow, &width, &height, &generation, &brokerPointer) != 1
        || !nativeWindow || !brokerPointer || !generation) return false;
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(brokerPointer);
    const EGLDisplay previousDisplay = eglGetCurrentDisplay(); const EGLContext previousContext = eglGetCurrentContext();
    const EGLSurface previousDraw = eglGetCurrentSurface(EGL_DRAW), previousRead = eglGetCurrentSurface(EGL_READ);
    // pbuffer退役前没有呈现权；失败释放刚借入的快照，原辅助context/句柄继续保留。
    if (!SuspendEGLSurface(window)) { broker->release(nativeWindow); return false; }
    window->nativeWindow = nativeWindow; window->nativeWindowLeaseBroker = brokerPointer;
    window->nativeWindowLeaseObject = nativeWindow; window->nativeWindowGeneration = generation;
    window->width = width; window->height = height;
    if (!attachGraphicsBackendSession(window)) {
        window->contextLostFatal = true; window->shouldClose = 1;
        amclGraphicsFatalV1("window-create-failed", 0, generation);
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Hidden context promotion failed; resources retained for teardown");
        return false;
    }
    window->auxiliary = false; window->visible = true; window->focused = 1; g_currentWindow = window;
    // ShowWindow不应偷换调用者current。原来就是本context时保留新window surface；其他情况
    // 还原旧context或解除当前绑定。任何还原失败都要求退出，不能交付相互矛盾的TLS/驱动状态。
    if (previousContext != window->context) {
        const bool restored = previousContext != EGL_NO_CONTEXT ?
            eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext) == EGL_TRUE :
            eglMakeCurrent(window->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) == EGL_TRUE;
        if (!restored) {
            window->contextLostFatal = true; window->shouldClose = 1;
            amclGraphicsFatalV1("context-restore-failed", 0, generation); return false;
        }
        window->contextOwnerTid = 0;
    }
    // Minecraft 先对隐藏 pbuffer MakeCurrent，再通过 ShowWindow 原地取得呈现权。
    // 隐藏阶段不启动采样器，而 promotion 又不会再次经过 MakeContextCurrent，过去因此
    // 只注入了 JVM hooks，却始终没有渲染 tid。仅当前调用线程确实持有本 context 时补上
    // 观察关系；其他线程/未绑定窗口仍等正常 MakeCurrent。生产构建中的采样 API 为空操作。
    if (g_threadCurrentContext == window && eglGetCurrentContext() == window->context) {
        amcl_sampler_set_render_tid(static_cast<int>(gettid()));
        amcl_sampler_start();
    }
    // 先前隐藏窗口的尺寸查询可能已被游戏缓存；保留其lifetime并补发尺寸变更，不能Prime掉事件。
    window->sizeNotifications.Observe(width, height);
    glfwOHOS_PrimeDesktopWindow(window);
    publishTypedWindowInputBinding(window, true);
    inputBridge_setWindowSize(width, height); (void)ensureTypedInputOpen();
    // 隐藏阶段只保存窗口自己的输入请求；取得呈现权后才发布为唯一输入目标。
    if (window->charCallbackAssigned) glfwSetCharCallback(window, window->charCb);
    if (window->charModsCallbackAssigned) glfwSetCharModsCallback(window, window->charModsCb);
    if (window->cursorEnterCallbackAssigned) glfwSetCursorEnterCallback(window, window->cursorEnterCb);
    if (window->cursorModeAssigned) glfwSetInputMode(window, GLFW_CURSOR, window->cursorMode);
    amclExternalLogWrite(1, LOG_TAG, "graphics_window_promoted window=%{public}llu shareGroup=%{public}llu context_preserved=1",
        static_cast<unsigned long long>(window->windowId), static_cast<unsigned long long>(window->shareGroup));
    return true;
}

GLFWwindow* glfwGetCurrentContext(void) {
    return g_threadCurrentContext;
}

void glfwSwapInterval(int interval) {
    GLFWwindow* window = g_threadCurrentContext;
    if (!window) return;
    // Remember the request regardless of surface state: EGL swap interval is
    // per-surface, so AttachEGLSurface/InitEGL must replay it after every
    // surface (re)creation or vsync-off silently reverts to the default 1.
    window->swapInterval = interval;
    window->swapIntervalSet = true;
    if (window->display != EGL_NO_DISPLAY && window->surface != EGL_NO_SURFACE) {
        eglSwapInterval(window->display, interval);
    }
}

double glfwGetTime(void) {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration<double>(now - g_startTime).count();
}

void glfwSetTime(double time) {
    g_startTime = std::chrono::steady_clock::now() - std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(time));
}

void glfwGetWindowSize(GLFWwindow* window, int* width, int* height) {
    if (window) {
        if (width) *width = window->width;
        if (height) *height = window->height;
    }
}

void glfwGetFramebufferSize(GLFWwindow* window, int* width, int* height) {
    glfwGetWindowSize(window, width, height);
}

// glfwGetWindowTitle — 上游 GLFW 3.4 新增必需符号（apiGetFunctionAddress，缺则 GLFW 类初始化抛异常）。
// 方案 B 需要 native 导出全部 118 个必需 C 符号；这是此前唯一缺的一个。
// 返回当前窗口标题（C 字符串，生命周期由 GLFWwindow->title 持有；无标题返回空串而非 NULL，
// 避免上游 Java 绑定对返回指针做 memUTF8 时 NPE）。
const char* glfwGetWindowTitle(GLFWwindow* window) {
    if (window && window->title) return window->title;
    return "";
}

// ==================== 版本/信息 ====================
void glfwGetVersion(int* major, int* minor, int* rev) {
    if (major) *major = GLFW_VERSION_MAJOR;
    if (minor) *minor = GLFW_VERSION_MINOR;
    if (rev) *rev = GLFW_VERSION_REVISION;
}

const char* glfwGetVersionString(void) {
#if AMCL_NATIVE_DESKTOP_ONLY
    return "3.4.2 OHOS-Desktop AMCL_DESKTOP_EGL_V2_PARKED";
#else
    return "3.4.2 OHOS-Compat AMCL_UNIFIED_EGL_V1";
#endif
}

void glfwDefaultWindowHints(void) {
    g_hintVisible = true;
    g_hintProfile = 0; g_hintForwardCompatible = false;
    g_hintClientAPI = amcl::desktop::UsesDesktopOpenGlContext() ? GLFW_OPENGL_API : GLFW_OPENGL_ES_API;
    g_hintMajor = 3;
    g_hintMinor = 0;
}

void glfwWaitEvents(void) {
    const auto* host=amclDesktopHostResolve();
    if(host && g_currentWindow) host->waitEvents(g_desktopPolledEpoch.load(), -1);
    glfwPollEvents();
}
void glfwWaitEventsTimeout(double timeout) {
    if(!std::isfinite(timeout) || timeout<=0 || timeout>9.0e9){if(g_errorCallback)g_errorCallback(GLFW_INVALID_VALUE,"Invalid event wait timeout");return;}
    const auto* host=amclDesktopHostResolve();
    if(host && g_currentWindow) host->waitEvents(g_desktopPolledEpoch.load(),static_cast<int64_t>(timeout*1.0e9));
    glfwPollEvents();
}
void glfwPostEmptyEvent(void) { const auto* host=amclDesktopHostResolve(); if(host)host->wakeEvents(); }

// ==================== GL 加载 ====================
GLFWglproc glfwGetProcAddress(const char* procname) {
    if (!procname || (g_currentWindow && g_currentWindow->clientAPI == GLFW_NO_API)) return nullptr;
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    return runtime ? reinterpret_cast<GLFWglproc>(runtime->glProc(procname)) : nullptr;
}

int glfwExtensionSupported(const char* extension) {
    if (!extension || !*extension || strpbrk(extension, " \t\r\n")) {
        if (g_errorCallback) g_errorCallback(GLFW_INVALID_VALUE, "Invalid extension name");
        return GLFW_FALSE;
    }
    if (!g_threadCurrentContext || g_threadCurrentContext->clientAPI == GLFW_NO_API ||
        eglGetCurrentContext() == EGL_NO_CONTEXT) {
        if (g_errorCallback) g_errorCallback(GLFW_NO_CURRENT_CONTEXT, "No current OpenGL context");
        return GLFW_FALSE;
    }
    const auto contains = [extension](const char* list) {
        if (!list) return false;
        const size_t length = strlen(extension);
        for (const char* p = list; (p = strstr(p, extension)) != nullptr; p += length)
            if ((p == list || p[-1] == ' ') && (p[length] == '\0' || p[length] == ' ')) return true;
        return false;
    };
    using GetInt = void (*)(unsigned, int*);
    using GetString = const unsigned char* (*)(unsigned);
    using GetStringi = const unsigned char* (*)(unsigned, unsigned);
    const auto getInt = reinterpret_cast<GetInt>(glfwGetProcAddress("glGetIntegerv"));
    const auto getStringi = reinterpret_cast<GetStringi>(glfwGetProcAddress("glGetStringi"));
    if (getInt && getStringi) {
        int count = 0; getInt(0x821D /*GL_NUM_EXTENSIONS*/, &count);
        for (int i = 0; i < count; ++i) {
            const char* value = reinterpret_cast<const char*>(getStringi(0x1F03 /*GL_EXTENSIONS*/, i));
            if (value && strcmp(value, extension) == 0) return GLFW_TRUE;
        }
    } else {
        const auto getString = reinterpret_cast<GetString>(glfwGetProcAddress("glGetString"));
        if (getString && contains(reinterpret_cast<const char*>(getString(0x1F03)))) return GLFW_TRUE;
    }
    if (contains(eglQueryString(eglGetCurrentDisplay(), EGL_EXTENSIONS))) return GLFW_TRUE;
    return GLFW_FALSE;
}

// glfwVulkanSupported / glfwGetRequiredInstanceExtensions / glfwCreateWindowSurface 等
// Vulkan surface 函数已移到 glfw_vulkan.cpp（Phase 2，接 OHOS VK_OHOS_surface）。
// 历史上这里有 `int glfwVulkanSupported(void) { return GLFW_FALSE; }` 的写死实现，已删除。

// ==================== OHOS 扩展 ====================
// NativeWindow publication is implemented by amcl_window_host. These exports
// remain the ABI-compatible GLFW facade used by ArkTS/XComponent and legacy
// consumers; no window ledger is kept in this image.
static void publishInputBindingsBeforeCommit(const AmclWindowHostSnapshot* snapshot, void*) {
    if (!snapshot || !snapshot->nativeWindow) return;
    const int descriptorResult = amclInputHostDescriptorPublishV1(amclInputGetHostApiV1());
    if (descriptorResult != AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG, "GLFW: input host descriptor publication failed rc=%{public}d", descriptorResult);
    }
    // These callbacks only publish the input bridge after the host has accepted
    // a real NativeWindow reference. They execute under the host's exclusive
    // publication transaction, so input never observes a torn epoch/size pair.
    amclBackendInputPublishAddress();
    inputBridge_publishAddress();
}

void glfwOHOS_SetNativeWindow(void* nativeWindow, int width, int height) {
    (void)glfwOHOS_PublishNativeWindow(nativeWindow, width, height);
}

void* glfwOHOS_GetNativeWindow(int* outWidth, int* outHeight) {
    void* nativeWindow = nullptr;
    glfwOHOS_GetNativeWindowSnapshot(&nativeWindow, outWidth, outHeight, nullptr);
    return nativeWindow;
}

uint64_t glfwOHOS_NextNativeWindowGeneration(uint64_t currentGeneration) {
    return amclWindowHostNextGeneration(currentGeneration);
}

uint64_t glfwOHOS_PeekNativeWindowGeneration(void) {
    return amclWindowHostPeekGeneration();
}

AmclNativeWindowPublicationState glfwOHOS_PeekNativeWindowPublicationState(void) {
    return amclWindowHostPeekState();
}

uint64_t glfwOHOS_PublishNativeWindow(void* nativeWindow, int width, int height) {
    const uint64_t generation = amclWindowHostPublish(
        nativeWindow, width, height, publishInputBindingsBeforeCommit, nullptr);
    if (generation == 0) {
        AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: NativeWindow host rejected publication ptr=%{public}p", nativeWindow);
        return 0;
    }
    const uint64_t currentPid = static_cast<uint64_t>(getpid());
    g_inputPublisherPid.store(currentPid, std::memory_order_release);
    g_inputPublisherGeneration.store(generation, std::memory_order_release);
    OH_LOG_INFO(LOG_APP,
        "GLFW: Native window snapshot published by host gen=%{public}llu (%{public}dx%{public}d) ptr=%{public}p",
        static_cast<unsigned long long>(generation), width, height, nativeWindow);
    return generation;
}

uint64_t glfwOHOS_UpdateNativeWindowSize(void* expectedWindow,
                                         uint64_t expectedPublicationGeneration,
                                         int width, int height) {
    const uint64_t generation = amclWindowHostUpdateSize(
        expectedWindow, expectedPublicationGeneration, width, height);
    if (generation == 0) {
        AMCL_EXTERNAL_LOG_W(LOG_TAG, "GLFW: NativeWindow host rejected size update ptr=%{public}p gen=%{public}llu",
                    expectedWindow, static_cast<unsigned long long>(expectedPublicationGeneration));
    }
    return generation;
}

uint64_t glfwOHOS_ClearNativeWindow(void* expectedWindow,
                                    uint64_t expectedPublicationGeneration) {
    const uint64_t generation = amclWindowHostClear(expectedWindow, expectedPublicationGeneration);
    if (generation != 0) {
        const uint64_t currentPid = static_cast<uint64_t>(getpid());
        if (g_inputPublisherPid.load(std::memory_order_acquire) == currentPid) {
            g_inputPublisherGeneration.store(0, std::memory_order_release);
        }
    }
    return generation;
}

int glfwOHOS_AcquireNativeWindowSnapshot(void* retainedNativeWindow,
                                         uint64_t retainedGeneration,
                                         void* retainedLeaseBroker,
                                         void** outNativeWindow, int* outWidth,
                                         int* outHeight, uint64_t* outGeneration,
                                         void** outLeaseBroker) {
    return amclWindowHostAcquire(retainedNativeWindow, retainedGeneration,
        retainedLeaseBroker, outNativeWindow, outWidth, outHeight, outGeneration, outLeaseBroker);
}

void glfwOHOS_ReleaseNativeWindowLease(void* nativeWindow, void* leaseBroker) {
    amclWindowHostRelease(nativeWindow, leaseBroker);
}

int glfwOHOS_BeginNativeWindowInputPublication(
        int* outWidth, int* outHeight, uint64_t* outGeneration, void** outBroker) {
    return amclWindowHostBeginInputPublication(outWidth, outHeight, outGeneration, outBroker);
}

void glfwOHOS_EndNativeWindowInputPublication(void* brokerToken) {
    amclWindowHostEndInputPublication(brokerToken);
}

int glfwOHOS_GetNativeWindowSnapshot(void** outNativeWindow, int* outWidth, int* outHeight,
                                     uint64_t* outGeneration) {
    AmclWindowHostSnapshot snapshot{};
    const int hasReadySurface = amclWindowHostReadSnapshot(&snapshot);
    if (outNativeWindow) *outNativeWindow = snapshot.nativeWindow;
    if (outWidth) *outWidth = snapshot.width;
    if (outHeight) *outHeight = snapshot.height;
    if (outGeneration) *outGeneration = snapshot.generation;
    return hasReadySurface;
}
void glfwOHOS_SetTouchEvent(float x, float y, int action) {
    // No-op: touch events now flow through OHOS_INPUT_BRIDGE
}

const char* glfwOHOS_GetCompatInfo(void) {
    static std::string info;
    std::ostringstream ss;

    ss << "===== GLFW 兼容层信息 =====\n\n";
    ss << "GLFW 版本: 3.x OHOS Compat\n";
    ss << "后端: XComponent + EGL\n";
    ss << "状态: " << (g_initialized ? "已初始化" : "未初始化") << "\n\n";

    if (g_currentWindow) {
        ss << "===== 窗口状态 =====\n\n";
        ss << "标题: " << (g_currentWindow->title ? g_currentWindow->title : "N/A") << "\n";
        ss << "大小: " << g_currentWindow->width << " x " << g_currentWindow->height << "\n";
        ss << "焦点: " << (g_currentWindow->focused ? "YES" : "NO") << "\n";
        ss << "EGL Display: " << (g_currentWindow->display != EGL_NO_DISPLAY ? "YES" : "NO") << "\n";
        ss << "EGL Surface: " << (g_currentWindow->surface != EGL_NO_SURFACE ? "YES" : "NO") << "\n";
        ss << "EGL Context: " << (g_currentWindow->context != EGL_NO_CONTEXT ? "YES" : "NO") << "\n";
        ss << "NativeWindow: " << (g_currentWindow->nativeWindow ? "YES" : "NO") << "\n\n";
    }

    ss << "===== 统计 =====\n\n";
    ss << "SwapBuffers 调用: " << g_swapCount << "\n";
    ss << "PollEvents 调用: " << g_pollCount << "\n";
    ss << "Typed 未映射键: "
       << g_typedUnsupportedKeyMappingCount.load(std::memory_order_relaxed)
       << "\n";
    ss << "Typed 未映射鼠标按钮: "
       << g_typedUnsupportedButtonMappingCount.load(std::memory_order_relaxed)
       << "\n";
    ss << "Typed 已诊断丢弃边沿: "
       << g_typedDiagnosticDropCount.load(std::memory_order_relaxed)
       << "\n";
    ss << "Typed 相对视角路由拒绝（无 sink / 非有限 / 漏斗拒收）: "
       << g_typedLookRoute.RejectCount() << "\n";
    ss << "Typed 滚轮横轴拒收（与 legacy 对齐 fail-closed）: "
       << g_typedWheelUnsupportedAxisCount.load(std::memory_order_relaxed)
       << "\n";
    ss << "Typed absolute adapter 拒绝: "
       << g_typedInputAdapter.AbsoluteRouteDropCount() << "\n";
    ss << "Typed absolute runtime 拒绝: "
       << g_typedAbsoluteRoute.DropCount() << "\n";
    ss << "Typed 已取出后取消事件: "
       << g_typedInputAdapter.DiscardedFetchedEventCount() << "\n";
    ss << "Typed consumer abandon 次数: "
       << g_typedInputAdapter.AbandonCount() << "\n";
    const amcl::input::GlfwTypedInputResolveDiagnostics resolveDiagnostics =
        g_typedInputResolveGuard.Snapshot();
    ss << "Typed descriptor 解析失败: "
       << resolveDiagnostics.failureCount << "\n";
    ss << "Typed descriptor 最近状态/结果/原因: "
       << resolveDiagnostics.lastResolveStatus << "/"
       << static_cast<uint32_t>(resolveDiagnostics.lastOutcome) << "/"
       << static_cast<uint32_t>(resolveDiagnostics.lastFailure) << "\n";
    ss << "运行时间: " << glfwGetTime() << " 秒\n\n";

    ss << "===== LWJGL/MC 兼容性 =====\n\n";
    ss << "glfwInit: YES\n";
    ss << "glfwCreateWindow: YES\n";
    ss << "glfwMakeContextCurrent: YES (EGL)\n";
    ss << "glfwSwapBuffers: YES (eglSwapBuffers)\n";
    ss << "glfwPollEvents: YES (touch→mouse映射)\n";
    ss << "glfwGetTime: YES (steady_clock)\n";
    ss << "glfwGetFramebufferSize: YES\n";
    ss << "回调机制: YES (key/cursor/mouseButton/scroll)\n";

    info = ss.str();
    return info.c_str();
}

long long glfwOHOS_GetLastSwapTimeMs(void) {
    return g_lastSwapTimeMs;
}

void glfwOHOS_ForceClose(void) {
    OH_LOG_INFO(LOG_APP, "GLFW: glfwOHOS_ForceClose called");
    if (g_currentWindow) {
        g_currentWindow->shouldClose = 1;
        // This extension is normally called from the ArkTS/UI thread.  EGL and
        // render-thread QoS must be released by the owning render thread after
        // it observes shouldClose and runs glfwDestroyWindow/glfwTerminate.
    }
}

void glfwOHOS_SetWindowDestroyCallback(glfwOHOS_WindowDestroyCallback cb) {
    g_windowDestroyCallback = cb;
}

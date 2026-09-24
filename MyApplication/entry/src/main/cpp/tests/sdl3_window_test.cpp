/*
 * SDL3 混合双窗口真机探针 —— 验证 SDL3 OpenHarmony hybrid 方案的
 * auxiliary-pbuffer + 单一 presented host 窗口链路是否真的成立。
 *
 * 为什么需要它（C2 探针不覆盖这一段）：
 *   C2 探针（sdl3_c2_test.cpp）只做到 SDL_GL_LoadLibrary，验证的是
 *   SDL_GL_GetProcAddress 与 dlsym(libglfw) 同址（MC 的 glGetError 硬校验）。
 *   它跑在 DevTools 页，那里**没有 XComponent**，所以永远走不到 SDL_CreateWindow。
 *
 *   而 hybrid 修复解决的恰恰是 SDL_CreateWindow：上游的 OPENHARMONY_CreateWindow 要求
 *   native_xcomponent + native_window 两个指针，它们只由 SDL 自己注册的 OnSurfaceCreated
 *   回调填充；AMCL 的 XComponent 属于宿主，那个回调永不触发。patch 让后端改为从
 *   AMCL 既有的环境变量约定（AMCL_NATIVE_WINDOW / _WIDTH / _HEIGHT）采纳 window，
 *   并容忍 xcomponent 为 NULL。
 *
 *   所以本探针必须跑在**有活跃 XComponent surface** 的页面上（RenderPage / VulkanPage），
 *   这样 platform/xcomponent.cpp 的 OnSurfaceCreated 已经把三个变量 setenv 出来了。
 *   这与 runVulkanSelfTest 复用同一机制（见 VulkanPage.ets 的注释）。
 *
 * 验证链（一次跑完，任一步失败即停并报出 SDL_GetError）：
 *   SDL_SetMainReady → SDL_Init(VIDEO) → SDL_GL_LoadLibrary(libglfw)
 *   → SDL_CreateWindow(auxiliary + presented)        ← hybrid 方案的正题
 *   → SDL_GL_CreateContext → SDL_GL_MakeCurrent
 *   → glGetString(GL_VERSION/RENDERER) 证明上下文真的活着
 *   → 查询 SDL 选中的 EGLConfig 的 WINDOW/PBUFFER 能力
 *   → 实建 320x480 pbuffer，用同一 context 验证 host→pbuffer→host
 *   → context unbind/destroy → auxiliary → presented → SDL_Quit 清理
 *
 * 见 docs/adaptation/SDL3_OPENHARMONY_HYBRID_MULTI_WINDOW_PLAN.md 的 Phase 0。
 */

#include "tests.h"

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>

#include <sstream>
#include <string>

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "SDL3_WIN"

namespace {

// SDL 的常量，避免为了几个数字去 include SDL 头（本文件刻意不链接 libSDL3，全走 dlsym）。
constexpr unsigned int kSdlInitVideo = 0x00000020u;
constexpr unsigned long long kSdlWindowOpenGL = 0x0000000000000002ull;
constexpr unsigned long long kSdlWindowHidden = 0x0000000000000008ull;
constexpr unsigned long long kSdlWindowUtility = 0x0000000000020000ull;
constexpr unsigned long long kSdlWindowNotFocusable = 0x0000000080000000ull;

// GL 枚举
constexpr unsigned int kGlVendor = 0x1F00;
constexpr unsigned int kGlRenderer = 0x1F01;
constexpr unsigned int kGlVersion = 0x1F02;

// EGL ABI 最小子集。与本文件的 SDL 调用一样，故意不 include/link EGL：
// 要测的是 SDL 指向的那一份 libglfw/MobileGlues EGL 前端，不是系统 EGL。
using EGLDisplay = void *;
using EGLConfig = void *;
using EGLSurface = void *;
using EGLContext = void *;
using EGLint = int;
using EGLBoolean = unsigned int;

constexpr EGLint kEglNone = 0x3038;
constexpr EGLint kEglConfigId = 0x3028;
constexpr EGLint kEglMaxPbufferHeight = 0x302A;
constexpr EGLint kEglMaxPbufferPixels = 0x302B;
constexpr EGLint kEglMaxPbufferWidth = 0x302C;
constexpr EGLint kEglSurfaceType = 0x3033;
constexpr EGLint kEglVendor = 0x3053;
constexpr EGLint kEglVersion = 0x3054;
constexpr EGLint kEglExtensions = 0x3055;
constexpr EGLint kEglPbufferBit = 0x0001;
constexpr EGLint kEglWindowBit = 0x0004;
constexpr EGLint kEglWidth = 0x3057;
constexpr EGLint kEglHeight = 0x3056;
constexpr EGLint kEglDraw = 0x3059;
constexpr EGLint kProbePbufferWidth = 320;
constexpr EGLint kProbePbufferHeight = 480;
constexpr unsigned int kGlColorBufferBit = 0x00004000u;
constexpr unsigned int kGlRgba = 0x1908u;
constexpr unsigned int kGlUnsignedByte = 0x1401u;
constexpr unsigned int kGlNoError = 0x0000u;
constexpr unsigned int kGlTexture2D = 0x0DE1u;
constexpr unsigned int kGlScissorTest = 0x0C11u;

using fn_SDL_SetMainReady = void (*)();
using fn_SDL_Init = bool (*)(unsigned int);
using fn_SDL_Quit = void (*)();
using fn_SDL_GetError = const char *(*)();
using fn_SDL_GL_LoadLibrary = bool (*)(const char *);
using fn_SDL_GL_UnloadLibrary = void (*)();
using fn_SDL_CreateWindow = void *(*)(const char *, int, int, unsigned long long);
using fn_SDL_DestroyWindow = void (*)(void *);
using fn_SDL_GL_CreateContext = void *(*)(void *);
using fn_SDL_GL_DestroyContext = bool (*)(void *);
using fn_SDL_GL_MakeCurrent = bool (*)(void *, void *);
using fn_SDL_GL_SwapWindow = bool (*)(void *);
using fn_SDL_GetWindowSize = bool (*)(void *, int *, int *);
using fn_SDL_GetWindowProperties = uint32_t (*)(void *);
using fn_SDL_GetPointerProperty = void *(*)(uint32_t, const char *, void *);
using fn_SDL_GetCurrentVideoDriver = const char *(*)();
using fn_SDL_EGL_GetCurrentDisplay = EGLDisplay (*)();
using fn_SDL_EGL_GetCurrentConfig = EGLConfig (*)();
using fn_SDL_EGL_GetWindowSurface = EGLSurface (*)(void *);
using fn_glGetString = const unsigned char *(*)(unsigned int);
using fn_glClearColor = void (*)(float, float, float, float);
using fn_glClear = void (*)(unsigned int);
using fn_glReadPixels = void (*)(int, int, int, int, unsigned int, unsigned int, void *);
using fn_glFinish = void (*)();

using fn_eglGetConfigAttrib = EGLBoolean (*)(EGLDisplay, EGLConfig, EGLint, EGLint *);
using fn_eglCreatePbufferSurface = EGLSurface (*)(EGLDisplay, EGLConfig, const EGLint *);
using fn_eglDestroySurface = EGLBoolean (*)(EGLDisplay, EGLSurface);
using fn_eglMakeCurrent = EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
using fn_eglGetCurrentContext = EGLContext (*)();
using fn_eglGetCurrentSurface = EGLSurface (*)(EGLint);
using fn_eglQuerySurface = EGLBoolean (*)(EGLDisplay, EGLSurface, EGLint, EGLint *);
using fn_eglQueryString = const char *(*)(EGLDisplay, EGLint);
using fn_eglGetError = EGLint (*)();

// Minimal GL object API used by the persistence sub-check.  These are resolved
// from the exact GL provider handle (libglfw/MobileGlues), never from the
// process default scope, so the probe cannot accidentally test another EGL/GL
// implementation loaded by the host.
using fn_glGenTextures = void (*)(int, unsigned int *);
using fn_glBindTexture = void (*)(unsigned int, unsigned int);
using fn_glIsTexture = unsigned char (*)(unsigned int);
using fn_glDeleteTextures = void (*)(int, const unsigned int *);
using fn_glGetError = unsigned int (*)();
using fn_glViewport = void (*)(int, int, int, int);
using fn_glDisable = void (*)(unsigned int);

std::string g_report;

// 端到端判据用单调计数，不用一次性的“ready”。多次运行探针时，
// 只要数字不再增长，就能看出真正停在了哪个边界。
std::atomic<uint64_t> g_pbufferProbeRuns{0};
std::atomic<uint64_t> g_pbufferCreatedTotal{0};
std::atomic<uint64_t> g_hostToPbufferTotal{0};
std::atomic<uint64_t> g_pbufferToHostTotal{0};
std::atomic<uint64_t> g_pbufferProbePassTotal{0};

class Report {
public:
    void line(const std::string &s) { oss_ << s << "\n"; }

    void linef(const char *fmt, ...) __attribute__((format(printf, 2, 3)))
    {
        char buf[1024];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        oss_ << buf << "\n";
        OH_LOG_INFO(LOG_APP, "%{public}s", buf);
    }

    std::string str() const { return oss_.str(); }

private:
    std::ostringstream oss_;
};

/* The probe temporarily sets private SDL/driver environment variables.  A
 * developer can invoke it while another diagnostic or a game session is alive,
 * so every touched value must be restored on all return paths (including a
 * failed dlopen or SDL_Init).  Capture strings rather than retaining getenv's
 * storage: setenv/unsetenv may invalidate that buffer. */
class ScopedEnvRestore {
public:
    ScopedEnvRestore()
        : entries_{
              {"SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE", false, std::string()},
              {"SDL_VIDEODRIVER", false, std::string()},
              {"SDL_VIDEO_DRIVER", false, std::string()},
              {"SDL_NO_SIGNAL_HANDLERS", false, std::string()},
              {"SDL_OPENGL_LIBRARY", false, std::string()},
              {"SDL_EGL_LIBRARY", false, std::string()},
              {"AMCL_RENDERER_REQUIRES_PROCESS_RESTART", false, std::string()}}
    {
        for (Entry &entry : entries_) {
            const char *value = ::getenv(entry.name);
            if (value != nullptr) {
                entry.present = true;
                entry.value = value;
            }
        }
    }

    ~ScopedEnvRestore()
    {
        for (const Entry &entry : entries_) {
            if (entry.present) {
                (void)::setenv(entry.name, entry.value.c_str(), 1);
            } else {
                (void)::unsetenv(entry.name);
            }
        }
    }

    ScopedEnvRestore(const ScopedEnvRestore &) = delete;
    ScopedEnvRestore &operator=(const ScopedEnvRestore &) = delete;

private:
    struct Entry {
        const char *name;
        bool present;
        std::string value;
    };
    Entry entries_[7];
};

// 从 maps 里找已加载的库全路径（与 C2 探针同一手法：dladdr 不总给绝对路径）。
std::string findLoadedPath(const char *soname)
{
    FILE *fp = fopen("/proc/self/maps", "r");
    if (!fp) {
        return std::string();
    }
    char lineBuf[512];
    std::string found;
    while (fgets(lineBuf, sizeof(lineBuf), fp)) {
        const char *hit = strstr(lineBuf, soname);
        if (!hit) {
            continue;
        }
        const char *slash = strchr(lineBuf, '/');
        if (!slash) {
            continue;
        }
        std::string path(slash);
        while (!path.empty() && (path.back() == '\n' || path.back() == '\r' || path.back() == ' ')) {
            path.pop_back();
        }
        found = path;
        break;
    }
    fclose(fp);
    return found;
}

struct EglApi {
    fn_eglGetConfigAttrib getConfigAttrib = nullptr;
    fn_eglCreatePbufferSurface createPbufferSurface = nullptr;
    fn_eglDestroySurface destroySurface = nullptr;
    fn_eglMakeCurrent makeCurrent = nullptr;
    fn_eglGetCurrentContext getCurrentContext = nullptr;
    fn_eglGetCurrentSurface getCurrentSurface = nullptr;
    fn_eglQuerySurface querySurface = nullptr;
    fn_eglQueryString queryString = nullptr;
    fn_eglGetError getError = nullptr;
};

bool resolveEglApi(void *scope, EglApi &egl, Report &r)
{
    struct EglSymSpec {
        const char *name;
        void **slot;
    };
    const EglSymSpec specs[] = {
        { "eglGetConfigAttrib", reinterpret_cast<void **>(&egl.getConfigAttrib) },
        { "eglCreatePbufferSurface", reinterpret_cast<void **>(&egl.createPbufferSurface) },
        { "eglDestroySurface", reinterpret_cast<void **>(&egl.destroySurface) },
        { "eglMakeCurrent", reinterpret_cast<void **>(&egl.makeCurrent) },
        { "eglGetCurrentContext", reinterpret_cast<void **>(&egl.getCurrentContext) },
        { "eglGetCurrentSurface", reinterpret_cast<void **>(&egl.getCurrentSurface) },
        { "eglQuerySurface", reinterpret_cast<void **>(&egl.querySurface) },
        { "eglQueryString", reinterpret_cast<void **>(&egl.queryString) },
        { "eglGetError", reinterpret_cast<void **>(&egl.getError) },
    };

    int missing = 0;
    for (const EglSymSpec &spec : specs) {
        dlerror();
        *spec.slot = dlsym(scope, spec.name);
        if (!*spec.slot) {
            const char *error = dlerror();
            r.linef("    [X] dlsym(%s) 失败: %s", spec.name, error ? error : "(dlerror 为空)");
            ++missing;
        }
    }
    if (missing != 0) {
        r.linef("    [X] EGL 入口点缺失 %d/9，无法实测 pbuffer 切换", missing);
        return false;
    }
    r.line("    9/9 egl* 入口点解析成功");
    return true;
}

void reportPbufferCounters(Report &r)
{
    r.linef("    单调计数: runs=%llu pbufferCreated=%llu hostToPbuffer=%llu pbufferToHost=%llu pass=%llu",
            static_cast<unsigned long long>(g_pbufferProbeRuns.load(std::memory_order_relaxed)),
            static_cast<unsigned long long>(g_pbufferCreatedTotal.load(std::memory_order_relaxed)),
            static_cast<unsigned long long>(g_hostToPbufferTotal.load(std::memory_order_relaxed)),
            static_cast<unsigned long long>(g_pbufferToHostTotal.load(std::memory_order_relaxed)),
            static_cast<unsigned long long>(g_pbufferProbePassTotal.load(std::memory_order_relaxed)));
}

/* End-to-end hybrid probe.  It deliberately creates the same two logical SDL
 * windows as the target renderer: auxiliary first, then the host-presented
 * window, with one context moving across their two independent surfaces. */
const char *runSdl3HybridWindowProbe(const char *sdl3PathHint)
{
    ScopedEnvRestore envGuard;
    Report r;
    const uint64_t runSeq = g_pbufferProbeRuns.fetch_add(1, std::memory_order_relaxed) + 1;
    r.line("========================================");
    r.line("  SDL3 混合双窗口真机探针");
    r.line("========================================");
    r.linef("probeRunSeq=%llu", static_cast<unsigned long long>(runSeq));
    const char *preexistingRestartMarker =
        ::getenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART");
    if (preexistingRestartMarker && *preexistingRestartMarker) {
        r.linef("警告：探针开始前已存在 AMCL_RENDERER_REQUIRES_PROCESS_RESTART=%s；"
                "探针不会吞掉该外部标记", preexistingRestartMarker);
    }

    const char *envPtr = getenv("AMCL_NATIVE_WINDOW");
    const char *envW = getenv("AMCL_WINDOW_WIDTH");
    const char *envH = getenv("AMCL_WINDOW_HEIGHT");
    const char *envBroker = getenv("AMCL_NATIVE_WINDOW_LEASE_BROKER");
    const char *envSnapshot = getenv("AMCL_NATIVE_WINDOW_SNAPSHOT");
    r.linef("宿主 NativeWindow=%s broker=%s snapshot=%s size=%sx%s",
            (envPtr && *envPtr) ? envPtr : "(未设)",
            (envBroker && *envBroker) ? envBroker : "(未设)",
            (envSnapshot && *envSnapshot) ? envSnapshot : "(未设)",
            envW ? envW : "?", envH ? envH : "?");
    if ((!envPtr || !*envPtr) && (!envBroker || !*envBroker) &&
        (!envSnapshot || !*envSnapshot)) {
        r.line("判定: INCOMPLETE（宿主 surface 未发布）");
        g_report = r.str();
        return g_report.c_str();
    }

    const std::string sdl3Path = (sdl3PathHint && *sdl3PathHint) ?
        sdl3PathHint : "libSDL3.so";
    void *sdl = dlopen(sdl3Path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!sdl) {
        r.linef("判定: INCOMPLETE（dlopen SDL3 失败: %s）", dlerror());
        g_report = r.str();
        return g_report.c_str();
    }

    struct SymSpec { const char *name; void **slot; };
    void *pSetMainReady = nullptr, *pInit = nullptr, *pQuit = nullptr;
    void *pGetError = nullptr, *pGLLoad = nullptr, *pGLUnload = nullptr;
    void *pCreateWindow = nullptr, *pDestroyWindow = nullptr;
    void *pCreateContext = nullptr, *pDestroyContext = nullptr;
    void *pMakeCurrent = nullptr, *pSwapWindow = nullptr;
    void *pGetWindowSize = nullptr, *pGetWindowProperties = nullptr;
    void *pGetPointerProperty = nullptr, *pGetDriver = nullptr;
    void *pGetDisplay = nullptr, *pGetConfig = nullptr, *pGetSurface = nullptr;
    const SymSpec symbols[] = {
        { "SDL_SetMainReady", &pSetMainReady }, { "SDL_Init", &pInit },
        { "SDL_Quit", &pQuit }, { "SDL_GetError", &pGetError },
        { "SDL_GL_LoadLibrary", &pGLLoad }, { "SDL_GL_UnloadLibrary", &pGLUnload },
        { "SDL_CreateWindow", &pCreateWindow }, { "SDL_DestroyWindow", &pDestroyWindow },
        { "SDL_GL_CreateContext", &pCreateContext },
        { "SDL_GL_DestroyContext", &pDestroyContext },
        { "SDL_GL_MakeCurrent", &pMakeCurrent }, { "SDL_GL_SwapWindow", &pSwapWindow },
        { "SDL_GetWindowSize", &pGetWindowSize },
        { "SDL_GetWindowProperties", &pGetWindowProperties },
        { "SDL_GetPointerProperty", &pGetPointerProperty },
        { "SDL_GetCurrentVideoDriver", &pGetDriver },
        { "SDL_EGL_GetCurrentDisplay", &pGetDisplay },
        { "SDL_EGL_GetCurrentConfig", &pGetConfig },
        { "SDL_EGL_GetWindowSurface", &pGetSurface },
    };
    int missing = 0;
    for (const SymSpec &spec : symbols) {
        *spec.slot = dlsym(sdl, spec.name);
        if (!*spec.slot) {
            r.linef("缺少 SDL 符号: %s", spec.name);
            ++missing;
        }
    }
    if (missing != 0) {
        r.linef("判定: INCOMPLETE（缺少 %d 个符号）", missing);
        dlclose(sdl);
        g_report = r.str();
        return g_report.c_str();
    }

    bool probeEnvOk = true;
    if (::setenv("SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE", "pbuffer", 1) != 0) {
        probeEnvOk = false;
    }
    // SDL's canonical selector is SDL_VIDEODRIVER; retain the historical
    // SDL_VIDEO_DRIVER spelling as well because older OpenHarmony builds used
    // it in their bootstrap path.
    if (::setenv("SDL_VIDEODRIVER", "openharmony", 1) != 0 ||
        ::setenv("SDL_VIDEO_DRIVER", "openharmony", 1) != 0 ||
        ::setenv("SDL_NO_SIGNAL_HANDLERS", "1", 1) != 0) {
        probeEnvOk = false;
    }
    if (!findLoadedPath("libglfw.so").empty()) {
        const std::string glfw = findLoadedPath("libglfw.so");
        if (::setenv("SDL_OPENGL_LIBRARY", glfw.c_str(), 1) != 0 ||
            ::setenv("SDL_EGL_LIBRARY", glfw.c_str(), 1) != 0) {
            probeEnvOk = false;
        }
    }
    if (!probeEnvOk) {
        r.linef("判定: INCOMPLETE（探针环境变量设置失败 errno=%d）", errno);
        dlclose(sdl);
        g_report = r.str();
        return g_report.c_str();
    }

    auto getError = [&]() -> const char * {
        const char *error = reinterpret_cast<fn_SDL_GetError>(pGetError)();
        return (error && *error) ? error : "(无 SDL 错误串)";
    };
    int liveWindowResources = 0;
    int liveSurfaceResources = 0;
    int liveContextResources = 0;
    void *secondPresented = nullptr;
    auto destroyTrackedWindow = [&](void *window) {
        if (!window) {
            return;
        }
        reinterpret_cast<fn_SDL_DestroyWindow>(pDestroyWindow)(window);
        if (liveWindowResources > 0) {
            --liveWindowResources;
        }
    };
    auto cleanup = [&](void *aux, void *presented, void *context,
                       bool loaded, bool initialized) {
        if (context) {
            reinterpret_cast<fn_SDL_GL_MakeCurrent>(pMakeCurrent)(nullptr, nullptr);
            reinterpret_cast<fn_SDL_GL_DestroyContext>(pDestroyContext)(context);
            if (liveContextResources > 0) {
                --liveContextResources;
            }
        }
        if (aux) {
            destroyTrackedWindow(aux);
            if (liveSurfaceResources > 0) {
                --liveSurfaceResources;
            }
        }
        if (secondPresented) {
            destroyTrackedWindow(secondPresented);
            secondPresented = nullptr;
        }
        if (presented) {
            destroyTrackedWindow(presented);
            if (liveSurfaceResources > 0) {
                --liveSurfaceResources;
            }
        }
        if (loaded) {
            reinterpret_cast<fn_SDL_GL_UnloadLibrary>(pGLUnload)();
        }
        if (initialized) {
            reinterpret_cast<fn_SDL_Quit>(pQuit)();
        }
        dlclose(sdl);
    };

    reinterpret_cast<fn_SDL_SetMainReady>(pSetMainReady)();
    if (!reinterpret_cast<fn_SDL_Init>(pInit)(kSdlInitVideo)) {
        r.linef("SDL_Init 失败: %s", getError());
        cleanup(nullptr, nullptr, nullptr, false, false);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    const char *driver = reinterpret_cast<fn_SDL_GetCurrentVideoDriver>(pGetDriver)();
    r.linef("SDL_Init OK driver=%s", driver ? driver : "(NULL)");
    if (!driver || ::strcmp(driver, "openharmony") != 0) {
        r.linef("[X] SDL video driver mismatch: expected openharmony, got %s",
                driver ? driver : "(NULL)");
        cleanup(nullptr, nullptr, nullptr, false, true);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    if (!reinterpret_cast<fn_SDL_GL_LoadLibrary>(pGLLoad)(nullptr)) {
        r.linef("SDL_GL_LoadLibrary 失败: %s", getError());
        cleanup(nullptr, nullptr, nullptr, false, true);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }

    const unsigned long long auxiliaryFlags = kSdlWindowOpenGL |
        kSdlWindowHidden | kSdlWindowUtility | kSdlWindowNotFocusable;
    void *aux = reinterpret_cast<fn_SDL_CreateWindow>(pCreateWindow)(
        "SDL auxiliary probe", kProbePbufferWidth, kProbePbufferHeight,
        auxiliaryFlags);
    if (!aux) {
        r.linef("auxiliary SDL_CreateWindow 失败: %s", getError());
        cleanup(nullptr, nullptr, nullptr, true, true);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    ++liveWindowResources;
    void *context = reinterpret_cast<fn_SDL_GL_CreateContext>(pCreateContext)(aux);
    if (!context) {
        r.linef("auxiliary SDL_GL_CreateContext 失败: %s", getError());
        cleanup(aux, nullptr, nullptr, true, true);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    ++liveContextResources;

    void *presented = reinterpret_cast<fn_SDL_CreateWindow>(pCreateWindow)(
        "SDL presented probe", 0, 0, kSdlWindowOpenGL);
    if (!presented) {
        r.linef("presented SDL_CreateWindow 失败: %s", getError());
        cleanup(aux, nullptr, context, true, true);
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    ++liveWindowResources;

    const std::string activeGlfwPath = findLoadedPath("libglfw.so");
    void *glfw = activeGlfwPath.empty()
        ? dlopen("libglfw.so", RTLD_NOW | RTLD_NOLOAD)
        : dlopen(activeGlfwPath.c_str(), RTLD_NOW | RTLD_NOLOAD);
    auto glGetStr = reinterpret_cast<fn_glGetString>(
        glfw ? dlsym(glfw, "glGetString") : nullptr);
    auto glClearColor = reinterpret_cast<fn_glClearColor>(
        glfw ? dlsym(glfw, "glClearColor") : nullptr);
    auto glClear = reinterpret_cast<fn_glClear>(
        glfw ? dlsym(glfw, "glClear") : nullptr);
    auto glReadPixels = reinterpret_cast<fn_glReadPixels>(
        glfw ? dlsym(glfw, "glReadPixels") : nullptr);
    auto glFinish = reinterpret_cast<fn_glFinish>(
        glfw ? dlsym(glfw, "glFinish") : nullptr);
    auto glGenTextures = reinterpret_cast<fn_glGenTextures>(
        glfw ? dlsym(glfw, "glGenTextures") : nullptr);
    auto glBindTexture = reinterpret_cast<fn_glBindTexture>(
        glfw ? dlsym(glfw, "glBindTexture") : nullptr);
    auto glIsTexture = reinterpret_cast<fn_glIsTexture>(
        glfw ? dlsym(glfw, "glIsTexture") : nullptr);
    auto glDeleteTextures = reinterpret_cast<fn_glDeleteTextures>(
        glfw ? dlsym(glfw, "glDeleteTextures") : nullptr);
    auto glGetError = reinterpret_cast<fn_glGetError>(
        glfw ? dlsym(glfw, "glGetError") : nullptr);
    auto glViewport = reinterpret_cast<fn_glViewport>(
        glfw ? dlsym(glfw, "glViewport") : nullptr);
    auto glDisable = reinterpret_cast<fn_glDisable>(
        glfw ? dlsym(glfw, "glDisable") : nullptr);

    const EGLDisplay display = reinterpret_cast<fn_SDL_EGL_GetCurrentDisplay>(pGetDisplay)();
    const EGLConfig config = reinterpret_cast<fn_SDL_EGL_GetCurrentConfig>(pGetConfig)();
    const EGLSurface auxSurface = reinterpret_cast<fn_SDL_EGL_GetWindowSurface>(pGetSurface)(aux);
    const EGLSurface presentedSurface = reinterpret_cast<fn_SDL_EGL_GetWindowSurface>(pGetSurface)(presented);
    r.linef("handles aux=%p presented=%p context=%p surfaces aux=%p presented=%p",
            aux, presented, context, auxSurface, presentedSurface);

    bool ok = aux != presented && auxSurface && presentedSurface &&
              auxSurface != presentedSurface && display && config;
    if (!ok) {
        r.linef("[X] 双 handle/surface/config 身份检查失败: %s", getError());
    }
    if (auxSurface != nullptr) {
        ++liveSurfaceResources;
        g_pbufferCreatedTotal.fetch_add(1, std::memory_order_relaxed);
    }
    if (presentedSurface != nullptr) {
        ++liveSurfaceResources;
    }

    const uint32_t auxProps = reinterpret_cast<fn_SDL_GetWindowProperties>(pGetWindowProperties)(aux);
    const uint32_t presentedProps = reinterpret_cast<fn_SDL_GetWindowProperties>(pGetWindowProperties)(presented);
    const char *nativeName = "SDL.window.openharmony.window";
    const void *auxNative = reinterpret_cast<fn_SDL_GetPointerProperty>(pGetPointerProperty)(
        auxProps, nativeName, nullptr);
    const void *presentedNative = reinterpret_cast<fn_SDL_GetPointerProperty>(
        pGetPointerProperty)(presentedProps, nativeName, nullptr);
    r.linef("native properties auxiliary=%p presented=%p", auxNative, presentedNative);
    if (auxNative != nullptr || presentedNative == nullptr) {
        r.line("[X] auxiliary/presented NativeWindow ownership 不符合 role 契约");
        ok = false;
    }

    EGLint configId = 0;
    EGLint surfaceType = 0;
    EGLint maxPbufferWidth = 0;
    EGLint maxPbufferHeight = 0;
    EGLint maxPbufferPixels = 0;
    EglApi egl;
    if (!glfw || !resolveEglApi(glfw, egl, r) ||
        !egl.getConfigAttrib(display, config, kEglConfigId, &configId) ||
        !egl.getConfigAttrib(display, config, kEglSurfaceType, &surfaceType)) {
        ok = false;
    } else {
        r.linef("config id=%d surface_type=0x%x WINDOW=%d PBUFFER=%d", configId,
                surfaceType, (surfaceType & kEglWindowBit) != 0,
                (surfaceType & kEglPbufferBit) != 0);
        if ((surfaceType & (kEglWindowBit | kEglPbufferBit)) !=
            (kEglWindowBit | kEglPbufferBit)) {
            ok = false;
        }

        const char *eglVendor = egl.queryString(display, kEglVendor);
        const char *eglVersion = egl.queryString(display, kEglVersion);
        const char *eglExtensions = egl.queryString(display, kEglExtensions);
        r.linef("EGL_VENDOR=%s", eglVendor ? eglVendor : "(NULL)");
        r.linef("EGL_VERSION=%s", eglVersion ? eglVersion : "(NULL)");
        r.linef("EGL_EXTENSIONS=%s", eglExtensions ? eglExtensions : "(NULL)");
        if (!eglVendor || !eglVersion || !eglExtensions) {
            r.line("[X] EGL vendor/version/extensions 查询不完整");
            ok = false;
        }

        const bool limitsOk =
            egl.getConfigAttrib(display, config, kEglMaxPbufferWidth,
                                &maxPbufferWidth) &&
            egl.getConfigAttrib(display, config, kEglMaxPbufferHeight,
                                &maxPbufferHeight) &&
            egl.getConfigAttrib(display, config, kEglMaxPbufferPixels,
                                &maxPbufferPixels);
        r.linef("pbuffer limits width=%d height=%d pixels=%d", maxPbufferWidth,
                maxPbufferHeight, maxPbufferPixels);
        const long long requestedPixels =
            static_cast<long long>(kProbePbufferWidth) *
            static_cast<long long>(kProbePbufferHeight);
        if (!limitsOk || maxPbufferWidth < kProbePbufferWidth ||
            maxPbufferHeight < kProbePbufferHeight ||
            maxPbufferPixels < requestedPixels) {
            r.linef("[X] config %d pbuffer limits cannot satisfy %dx%d (%lld pixels)",
                    configId, kProbePbufferWidth, kProbePbufferHeight,
                    requestedPixels);
            ok = false;
        }
    }

    if (ok) {
        EGLint actualAuxWidth = 0;
        EGLint actualAuxHeight = 0;
        if (!egl.querySurface(display, auxSurface, kEglWidth,
                              &actualAuxWidth) ||
            !egl.querySurface(display, auxSurface, kEglHeight,
                              &actualAuxHeight)) {
            r.line("[X] auxiliary pbuffer 实际尺寸查询失败");
            ok = false;
        } else {
            r.linef("auxiliary pbuffer actual=%dx%d requested=%dx%d",
                    actualAuxWidth, actualAuxHeight, kProbePbufferWidth,
                    kProbePbufferHeight);
            if (actualAuxWidth != kProbePbufferWidth ||
                actualAuxHeight != kProbePbufferHeight) {
                r.line("[X] auxiliary pbuffer 实际尺寸与请求不一致");
                ok = false;
            }
        }
    }

    int auxW = 0, auxH = 0, mainW = 0, mainH = 0;
    reinterpret_cast<fn_SDL_GetWindowSize>(pGetWindowSize)(aux, &auxW, &auxH);
    reinterpret_cast<fn_SDL_GetWindowSize>(pGetWindowSize)(presented, &mainW, &mainH);
    r.linef("logical sizes auxiliary=%dx%d presented=%dx%d", auxW, auxH, mainW, mainH);

    /* A legal hybrid session has exactly one host-presented window.  Prove
     * that a second ordinary OpenGL window is rejected instead of silently
     * being converted to another pbuffer (or consuming a second host lease).
     * Keep this check before any context alternation so an unexpected success
     * cannot contaminate the authoritative surface identities below. */
    secondPresented = reinterpret_cast<fn_SDL_CreateWindow>(pCreateWindow)(
        "SDL second presented probe", 1, 1, kSdlWindowOpenGL);
    if (secondPresented) {
        r.line("[X] 第二个 presented SDL_CreateWindow 意外成功（角色限制失效）");
        ok = false;
        ++liveWindowResources;
        destroyTrackedWindow(secondPresented);
        secondPresented = nullptr;
    } else {
        const char *secondError = getError();
        r.linef("second presented rejected: %s", secondError);
        if (!secondError || !*secondError ||
            (::strstr(secondError, "one presented") == nullptr &&
             ::strstr(secondError, "presented window") == nullptr)) {
            r.line("[X] 第二个 presented 失败原因不是明确的 single-presented 限制");
            ok = false;
        }
    }

    auto exerciseCurrent = [&](void *target, EGLSurface expected, const char *label) {
        /* A missing/partial EGL provider is a probe failure, not a reason to
         * call through a null function pointer while trying to print a second
         * diagnostic.  The caller still runs cleanup so SDL can unwind. */
        if (!egl.makeCurrent || !egl.getCurrentSurface || !egl.getCurrentContext) {
            r.linef("[X] %s EGL current API 不完整，跳过切换", label);
            return false;
        }
        if (!reinterpret_cast<fn_SDL_GL_MakeCurrent>(pMakeCurrent)(target, context)) {
            r.linef("[X] %s SDL_GL_MakeCurrent 失败: %s", label, getError());
            return false;
        }
        const EGLSurface actual = egl.getCurrentSurface(kEglDraw);
        const EGLContext actualContext = egl.getCurrentContext();
        const unsigned char *version = glGetStr ? glGetStr(kGlVersion) : nullptr;
        r.linef("%s current=%p expected=%p context=%p expectedContext=%p GL_VERSION=%s",
                label, actual, expected, actualContext, context,
                version ? reinterpret_cast<const char *>(version) : "(NULL)");
        bool pass = actual == expected && actualContext == context &&
                    (!glGetStr || version != nullptr);
        EGLint targetWidth = 0;
        EGLint targetHeight = 0;
        const bool targetSizeOk =
            egl.querySurface(display, expected, kEglWidth, &targetWidth) &&
            egl.querySurface(display, expected, kEglHeight, &targetHeight) &&
            targetWidth > 0 && targetHeight > 0;
        if (glViewport && glDisable && targetSizeOk) {
            /* Do not inherit viewport/scissor state from the utility
             * bootstrap surface when the presented surface becomes current. */
            glViewport(0, 0, targetWidth, targetHeight);
            glDisable(kGlScissorTest);
        } else {
            r.linef("[X] %s 无法明确设置 viewport/scissor（size=%d/%d api=%d/%d）",
                    label, targetWidth, targetHeight,
                    glViewport ? 1 : 0, glDisable ? 1 : 0);
            pass = false;
        }
        if (glClearColor && glClear && glReadPixels && glFinish) {
            unsigned char pixel[4] = { 0, 0, 0, 0 };
            glClearColor(0.13f, 0.27f, 0.41f, 1.0f);
            glClear(kGlColorBufferBit);
            glFinish();
            glReadPixels(0, 0, 1, 1, kGlRgba, kGlUnsignedByte, pixel);
            r.linef("%s clear/readback=%u,%u,%u,%u", label, pixel[0], pixel[1],
                    pixel[2], pixel[3]);
        } else {
            r.linef("%s clear/readback API 未解析，跳过像素子断言", label);
        }
        if (glGetError) {
            const unsigned int glError = glGetError();
            r.linef("%s glGetError=0x%x", label, glError);
            if (glError != kGlNoError) {
                pass = false;
            }
        }
        return pass;
    };

    const bool objectApiAvailable = glGenTextures && glBindTexture &&
                                    glIsTexture && glDeleteTextures &&
                                    glGetError;
    unsigned int probeTexture = 0;
    bool objectPersistenceOk = true;
    auto clearGlErrors = [&]() {
        if (!glGetError) {
            return;
        }
        // Drain at most a small bounded number: a persistent driver error must
        // never turn a diagnostic probe into an infinite loop.
        for (int i = 0; i < 8; ++i) {
            if (glGetError() == kGlNoError) {
                break;
            }
        }
    };
    auto createProbeObject = [&]() {
        if (!objectApiAvailable) {
            r.line("GL object persistence: SKIP（provider 未导出完整 texture API）");
            return true;  // Optional sub-check; EGL/context proof remains authoritative.
        }
        clearGlErrors();
        glGenTextures(1, &probeTexture);
        if (probeTexture != 0) {
            glBindTexture(kGlTexture2D, probeTexture);
        }
        const unsigned int error = glGetError();
        const bool created = probeTexture != 0 && error == kGlNoError &&
                             glIsTexture(probeTexture) != 0;
        r.linef("GL object create texture=%u glIsTexture=%d glError=0x%x",
                probeTexture, probeTexture ? (glIsTexture(probeTexture) != 0) : 0,
                error);
        if (!created) {
            r.line("[X] 同一 context 中 GL object 创建失败");
        }
        return created;
    };
    auto verifyProbeObject = [&](const char *label) {
        if (!objectApiAvailable || probeTexture == 0) {
            return true;
        }
        clearGlErrors();
        const int alive = glIsTexture(probeTexture) != 0 ? 1 : 0;
        const unsigned int error = glGetError();
        r.linef("%s GL object texture=%u alive=%d glError=0x%x", label,
                probeTexture, alive, error);
        return alive != 0 && error == kGlNoError;
    };
    auto destroyProbeObject = [&]() {
        if (!objectApiAvailable || probeTexture == 0) {
            return;
        }
        if (!egl.getCurrentContext || egl.getCurrentContext() != context) {
            /* The object is owned by this context and will be reclaimed when
             * SDL destroys it.  Do not issue GL calls without a current
             * context merely to force a best-effort delete. */
            r.linef("GL object destroy texture=%u SKIP（context 非 current）", probeTexture);
            objectPersistenceOk = false;
            probeTexture = 0;
            return;
        }
        clearGlErrors();
        glDeleteTextures(1, &probeTexture);
        const unsigned int error = glGetError();
        r.linef("GL object destroy texture=%u glError=0x%x", probeTexture, error);
        if (error != kGlNoError) {
            objectPersistenceOk = false;
        }
        probeTexture = 0;
    };

    /* Context starts on auxiliary; exercise the complete alternating path and
     * leave it on the presented surface for one real swap. */
    if (!exerciseCurrent(aux, auxSurface, "auxiliary-initial")) ok = false;
    if (ok && !createProbeObject()) {
        objectPersistenceOk = false;
        ok = false;
    }
    if (ok && exerciseCurrent(presented, presentedSurface, "auxiliary-to-presented")) {
        g_pbufferToHostTotal.fetch_add(1, std::memory_order_relaxed);
        if (!verifyProbeObject("auxiliary-to-presented")) {
            objectPersistenceOk = false;
            ok = false;
        }
    } else if (ok) ok = false;
    if (ok && exerciseCurrent(aux, auxSurface, "presented-to-auxiliary")) {
        g_hostToPbufferTotal.fetch_add(1, std::memory_order_relaxed);
        if (!verifyProbeObject("presented-to-auxiliary")) {
            objectPersistenceOk = false;
            ok = false;
        }
    } else if (ok) ok = false;
    if (ok && exerciseCurrent(presented, presentedSurface, "auxiliary-to-presented-2")) {
        g_pbufferToHostTotal.fetch_add(1, std::memory_order_relaxed);
        if (!verifyProbeObject("auxiliary-to-presented-2")) {
            objectPersistenceOk = false;
            ok = false;
        }
    } else if (ok) ok = false;
    if (ok && exerciseCurrent(aux, auxSurface, "presented-to-auxiliary-2")) {
        g_hostToPbufferTotal.fetch_add(1, std::memory_order_relaxed);
        if (!verifyProbeObject("presented-to-auxiliary-2")) {
            objectPersistenceOk = false;
            ok = false;
        }
    } else if (ok) ok = false;
    if (ok && exerciseCurrent(presented, presentedSurface, "auxiliary-to-presented-3")) {
        g_pbufferToHostTotal.fetch_add(1, std::memory_order_relaxed);
        if (!verifyProbeObject("auxiliary-to-presented-3")) {
            objectPersistenceOk = false;
            ok = false;
        }
    } else if (ok) ok = false;

    destroyProbeObject();

    if (ok && !reinterpret_cast<fn_SDL_GL_SwapWindow>(pSwapWindow)(presented)) {
        r.linef("[X] presented SDL_GL_SwapWindow 失败: %s", getError());
        ok = false;
    }

    if (!objectPersistenceOk) {
        ok = false;
    }

    r.linef("GL object persistence: %s",
            objectPersistenceOk ? "PASS" : "FAIL");
    if (ok) {
        g_pbufferProbePassTotal.fetch_add(1, std::memory_order_relaxed);
        r.line("Phase 0 判定: PASS —— 实际 SDL auxiliary + presented 双窗口、同 context 切换及对象持久性通过");
    } else {
        r.line("Phase 0 判定: FAIL —— 见首个 [X]");
    }
    reportPbufferCounters(r);
    r.linef("resource counts before cleanup: windows=%d surfaces=%d contexts=%d",
            liveWindowResources, liveSurfaceResources, liveContextResources);

    cleanup(aux, presented, context, true, true);
    if (glfw) dlclose(glfw);
    r.linef("resource counts after cleanup: windows=%d surfaces=%d contexts=%d",
            liveWindowResources, liveSurfaceResources, liveContextResources);
    r.line(ok ? "判定: PASS" : "判定: FAIL");
    g_report = r.str();
    return g_report.c_str();
}

} // namespace

const char *runSdl3WindowTest(const char *sdl3PathHint)
{
    return runSdl3HybridWindowProbe(sdl3PathHint);

    /* Kept below while old diagnostic output is being retired; the hybrid
     * probe above is the authoritative Phase 0 path. */
    Report r;
    r.line("========================================");
    r.line("  SDL3 窗口创建探针（patch 0001 验证）");
    r.line("========================================");
    r.line("目标：在宿主的 XComponent surface 上走通");
    r.line("      SDL_CreateWindow → GL_CreateContext → GL_MakeCurrent");
    r.line("");

    // ---------------------------------------------------------------------
    // [0] 宿主是否已经发布 surface
    // ---------------------------------------------------------------------
    r.line("[0] 宿主 surface（patch 0001 依赖的环境变量约定）");
    const char *envPtr = getenv("AMCL_NATIVE_WINDOW");
    const char *envW = getenv("AMCL_WINDOW_WIDTH");
    const char *envH = getenv("AMCL_WINDOW_HEIGHT");
    r.linef("    AMCL_NATIVE_WINDOW = %s", (envPtr && *envPtr) ? envPtr : "(未设)");
    r.linef("    AMCL_WINDOW_WIDTH  = %s", envW ? envW : "(未设)");
    r.linef("    AMCL_WINDOW_HEIGHT = %s", envH ? envH : "(未设)");
    if (!envPtr || !*envPtr) {
        r.line("");
        r.line("    [X] 宿主还没发布 NativeWindow。");
        r.line("        本探针必须在带 XComponent 的页面上跑（RenderPage / VulkanPage），");
        r.line("        DevTools 页没有 surface，跑不出结果。");
        r.line("判定: INCOMPLETE（无宿主 surface）");
        g_report = r.str();
        return g_report.c_str();
    }
    r.line("");

    // ---------------------------------------------------------------------
    // [1] 加载 libSDL3 并取符号
    // ---------------------------------------------------------------------
    r.line("[1] 加载 libSDL3.so");
    const std::string sdl3Path = (sdl3PathHint && sdl3PathHint[0]) ? sdl3PathHint : "libSDL3.so";
    void *h = dlopen(sdl3Path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        r.linef("    [X] dlopen(%s) 失败: %s", sdl3Path.c_str(), dlerror());
        r.line("判定: INCOMPLETE（libSDL3 未就位）");
        g_report = r.str();
        return g_report.c_str();
    }
    {
        const std::string loaded = findLoadedPath("libSDL3.so");
        r.linef("    实际加载 = %s", loaded.empty() ? sdl3Path.c_str() : loaded.c_str());
    }

    struct SymSpec {
        const char *name;
        void **slot;
    };
    void *pSetMainReady = nullptr, *pInit = nullptr, *pQuit = nullptr, *pGetError = nullptr;
    void *pGLLoad = nullptr, *pGLUnload = nullptr, *pCreateWin = nullptr, *pDestroyWin = nullptr;
    void *pGLCreateCtx = nullptr, *pGLDestroyCtx = nullptr, *pGLMakeCurrent = nullptr;
    void *pGLSwapWindow = nullptr;
    void *pGetWinSize = nullptr, *pCurDrv = nullptr;
    void *pGetWinProps = nullptr, *pGetPtrProp = nullptr;
    void *pEglGetDisplay = nullptr, *pEglGetConfig = nullptr, *pEglGetWindowSurface = nullptr;
    const SymSpec specs[] = {
        { "SDL_SetMainReady", &pSetMainReady },
        { "SDL_Init", &pInit },
        { "SDL_Quit", &pQuit },
        { "SDL_GetError", &pGetError },
        { "SDL_GL_LoadLibrary", &pGLLoad },
        { "SDL_GL_UnloadLibrary", &pGLUnload },
        { "SDL_CreateWindow", &pCreateWin },
        { "SDL_DestroyWindow", &pDestroyWin },
        { "SDL_GL_CreateContext", &pGLCreateCtx },
        { "SDL_GL_DestroyContext", &pGLDestroyCtx },
        { "SDL_GL_MakeCurrent", &pGLMakeCurrent },
        { "SDL_GL_SwapWindow", &pGLSwapWindow },
        { "SDL_GetWindowSize", &pGetWinSize },
        { "SDL_GetWindowProperties", &pGetWinProps },
        { "SDL_GetPointerProperty", &pGetPtrProp },
        { "SDL_GetCurrentVideoDriver", &pCurDrv },
        { "SDL_EGL_GetCurrentDisplay", &pEglGetDisplay },
        { "SDL_EGL_GetCurrentConfig", &pEglGetConfig },
        { "SDL_EGL_GetWindowSurface", &pEglGetWindowSurface },
    };
    int missing = 0;
    for (const SymSpec &s : specs) {
        *s.slot = dlsym(h, s.name);
        if (!*s.slot) {
            r.linef("    [!] dlsym(%s) 失败", s.name);
            missing++;
        }
    }
    if (missing) {
        r.linef("    [X] 缺 %d 个 SDL 符号，中止", missing);
        r.line("判定: INCOMPLETE");
        g_report = r.str();
        return g_report.c_str();
    }
    r.line("    19 个 SDL 符号全部取到");
    r.line("");

    auto sdlErr = [&]() -> const char * {
        const char *e = reinterpret_cast<fn_SDL_GetError>(pGetError)();
        return (e && *e) ? e : "(SDL_GetError 为空)";
    };

    // ---------------------------------------------------------------------
    // [2] GL 库指向 libglfw：与 C2 一致，MC/LWJGL 侧拿到的就是这一份
    // ---------------------------------------------------------------------
    r.line("[2] 初始化 SDL");
    const std::string glfwPath = findLoadedPath("libglfw.so");
    if (!glfwPath.empty()) {
        setenv("SDL_OPENGL_LIBRARY", glfwPath.c_str(), 1);
        setenv("SDL_EGL_LIBRARY", glfwPath.c_str(), 1);
        r.linef("    SDL_OPENGL_LIBRARY = SDL_EGL_LIBRARY = %s", glfwPath.c_str());
    } else {
        r.line("    libglfw.so 未加载，GL 库交给 SDL 默认解析");
    }
    setenv("SDL_VIDEO_DRIVER", "openharmony", 1);
    setenv("SDL_NO_SIGNAL_HANDLERS", "1", 1);  // 不让 SDL 抢 AMCL/JVM 的信号处理器

    // OHOS 上 SDL_MAIN_NEEDED 生效，SDL_MainIsReady 初值 false，
    // 宿主直调 SDL_Init 必失败（§C1.1，已真机实证）。
    reinterpret_cast<fn_SDL_SetMainReady>(pSetMainReady)();
    r.line("    SDL_SetMainReady() 已调用");

    if (!reinterpret_cast<fn_SDL_Init>(pInit)(kSdlInitVideo)) {
        r.linef("    [X] SDL_Init 失败: %s", sdlErr());
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    {
        const char *drv = reinterpret_cast<fn_SDL_GetCurrentVideoDriver>(pCurDrv)();
        r.linef("    SDL_Init OK，driver = %s", drv ? drv : "(null)");
    }

    if (!reinterpret_cast<fn_SDL_GL_LoadLibrary>(pGLLoad)(glfwPath.empty() ? nullptr : glfwPath.c_str())) {
        r.linef("    [X] SDL_GL_LoadLibrary 失败: %s", sdlErr());
        reinterpret_cast<fn_SDL_Quit>(pQuit)();
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    r.line("    SDL_GL_LoadLibrary OK");
    r.line("");

    // ---------------------------------------------------------------------
    // [3] patch 0001 的正题：能不能用宿主的 window 建出 SDL_Window
    // ---------------------------------------------------------------------
    r.line("[3] SDL_CreateWindow（patch 0001 的正题）");
    void *win = reinterpret_cast<fn_SDL_CreateWindow>(pCreateWin)(
        "AMCL SDL3 window probe", 0, 0, kSdlWindowOpenGL);
    if (!win) {
        r.linef("    [X] SDL_CreateWindow 失败: %s", sdlErr());
        r.line("        若报 \"Don't have a Native Window\"，说明 patch 0001 没生效");
        r.line("        （产物没打 patch，或环境变量没被采纳）。");
        reinterpret_cast<fn_SDL_GL_UnloadLibrary>(pGLUnload)();
        reinterpret_cast<fn_SDL_Quit>(pQuit)();
        r.line("判定: FAIL");
        g_report = r.str();
        return g_report.c_str();
    }
    r.linef("    ✅ SDL_CreateWindow OK，window = %p", win);
    {
        int gw = 0, gh = 0;
        if (reinterpret_cast<fn_SDL_GetWindowSize>(pGetWinSize)(win, &gw, &gh)) {
            r.linef("    SDL_GetWindowSize = %dx%d（宿主报的是 %sx%s）",
                    gw, gh, envW ? envW : "?", envH ? envH : "?");
        }
    }
    r.line("");

    // ---------------------------------------------------------------------
    // [4] GL 上下文：证明 EGL surface 真的建在宿主 surface 上
    // ---------------------------------------------------------------------
    r.line("[4] GL 上下文");
    bool windowContextOk = false;
    bool pbufferOk = false;
    void *ctx = reinterpret_cast<fn_SDL_GL_CreateContext>(pGLCreateCtx)(win);
    if (!ctx) {
        r.linef("    [X] SDL_GL_CreateContext 失败: %s", sdlErr());
    } else {
        r.linef("    SDL_GL_CreateContext OK，ctx = %p", ctx);
        if (!reinterpret_cast<fn_SDL_GL_MakeCurrent>(pGLMakeCurrent)(win, ctx)) {
            r.linef("    [X] SDL_GL_MakeCurrent 失败: %s", sdlErr());
        } else {
            r.line("    SDL_GL_MakeCurrent OK");

            // SDL_GL_LoadLibrary 后重新从 maps 取实际路径：进入本函数时
            // libglfw 不一定已在进程里，不能沿用初始 glfwPath 的空值作结论。
            const std::string activeGlfwPath = findLoadedPath("libglfw.so");
            void *hglfw = activeGlfwPath.empty()
                ? dlopen("libglfw.so", RTLD_NOW | RTLD_NOLOAD)
                : dlopen(activeGlfwPath.c_str(), RTLD_NOW | RTLD_NOLOAD);
            void *pGetStr = hglfw ? dlsym(hglfw, "glGetString") : nullptr;
            auto glGetStr = reinterpret_cast<fn_glGetString>(pGetStr);
            if (glGetStr) {
                const unsigned char *ver = glGetStr(kGlVersion);
                const unsigned char *rend = glGetStr(kGlRenderer);
                const unsigned char *vend = glGetStr(kGlVendor);
                r.linef("    GL_VERSION  = %s", ver ? reinterpret_cast<const char *>(ver) : "(NULL)");
                r.linef("    GL_RENDERER = %s", rend ? reinterpret_cast<const char *>(rend) : "(NULL)");
                r.linef("    GL_VENDOR   = %s", vend ? reinterpret_cast<const char *>(vend) : "(NULL)");
                windowContextOk = (ver != nullptr);
                if (!windowContextOk) {
                    r.line("    [X] glGetString(GL_VERSION) 返回 NULL —— 宿主上下文没有真正 current");
                }
            } else {
                r.line("    [!] 取不到 glGetString，保留原探针语义：MakeCurrent 成功即记为基础链路成功");
                windowContextOk = true;
            }

            // -----------------------------------------------------------------
            // [5] Phase 0：不创建第二 host window，使用 SDL 当前的
            //     display/config/context 实测 pbuffer 与 host surface 双向切换。
            // -----------------------------------------------------------------
            r.line("");
            r.line("[5] Phase 0: EGLConfig + 320x480 pbuffer 双向切换");
            const uint64_t runSeq = g_pbufferProbeRuns.fetch_add(1, std::memory_order_relaxed) + 1;
            r.linef("    probeRunSeq=%llu", static_cast<unsigned long long>(runSeq));

            EglApi egl;
            if (!hglfw) {
                const char *error = dlerror();
                r.linef("    [X] 无法取得已加载 libglfw.so 的精确 handle: %s",
                        error ? error : "(未在 /proc/self/maps 找到 libglfw.so)");
                r.line("    Phase 0 判定: INCOMPLETE（拒绝回退到 RTLD_DEFAULT 以避免测错 EGL 实现）");
            } else if (!resolveEglApi(hglfw, egl, r)) {
                r.line("    Phase 0 判定: INCOMPLETE（EGL 入口点不完整）");
            } else {
                const EGLDisplay display = reinterpret_cast<fn_SDL_EGL_GetCurrentDisplay>(pEglGetDisplay)();
                const EGLConfig config = reinterpret_cast<fn_SDL_EGL_GetCurrentConfig>(pEglGetConfig)();
                const EGLSurface hostSurface =
                    reinterpret_cast<fn_SDL_EGL_GetWindowSurface>(pEglGetWindowSurface)(win);
                const EGLContext currentContext = egl.getCurrentContext();
                const EGLSurface currentDrawSurface = egl.getCurrentSurface(kEglDraw);
                r.linef("    display=%p config=%p hostSurface=%p currentContext=%p currentDraw=%p",
                        display, config, hostSurface, currentContext, currentDrawSurface);

                bool identityOk = true;
                if (!display) {
                    r.linef("    [X] SDL_EGL_GetCurrentDisplay 返回 EGL_NO_DISPLAY: %s", sdlErr());
                    identityOk = false;
                }
                if (!config) {
                    r.linef("    [X] SDL_EGL_GetCurrentConfig 返回 NULL: %s", sdlErr());
                    identityOk = false;
                }
                if (!hostSurface) {
                    r.linef("    [X] SDL_EGL_GetWindowSurface 返回 EGL_NO_SURFACE: %s", sdlErr());
                    identityOk = false;
                }
                if (currentContext != reinterpret_cast<EGLContext>(ctx)) {
                    r.linef("    [X] EGL current context 与 SDL context 不同: egl=%p sdl=%p",
                            currentContext, ctx);
                    identityOk = false;
                }
                if (currentDrawSurface != hostSurface) {
                    r.linef("    [X] EGL current draw surface 不是 SDL host surface: current=%p host=%p",
                            currentDrawSurface, hostSurface);
                    identityOk = false;
                }

                EGLint configId = 0;
                EGLint surfaceType = 0;
                EGLint maxPbufferWidth = 0;
                EGLint maxPbufferHeight = 0;
                EGLint maxPbufferPixels = 0;
                bool attrsOk = identityOk;
                struct ConfigQuery {
                    EGLint attribute;
                    const char *name;
                    EGLint *value;
                };
                const ConfigQuery queries[] = {
                    { kEglConfigId, "EGL_CONFIG_ID", &configId },
                    { kEglSurfaceType, "EGL_SURFACE_TYPE", &surfaceType },
                    { kEglMaxPbufferWidth, "EGL_MAX_PBUFFER_WIDTH", &maxPbufferWidth },
                    { kEglMaxPbufferHeight, "EGL_MAX_PBUFFER_HEIGHT", &maxPbufferHeight },
                    { kEglMaxPbufferPixels, "EGL_MAX_PBUFFER_PIXELS", &maxPbufferPixels },
                };
                if (identityOk) {
                    for (const ConfigQuery &query : queries) {
                        if (!egl.getConfigAttrib(display, config, query.attribute, query.value)) {
                            r.linef("    [X] eglGetConfigAttrib(%s) 失败: EGL error=0x%04x",
                                    query.name, egl.getError());
                            attrsOk = false;
                        }
                    }
                }
                if (attrsOk) {
                    r.linef("    EGL_CONFIG_ID=%d", configId);
                    r.linef("    EGL_SURFACE_TYPE=0x%04x (WINDOW=%d PBUFFER=%d)", surfaceType,
                            (surfaceType & kEglWindowBit) ? 1 : 0,
                            (surfaceType & kEglPbufferBit) ? 1 : 0);
                    r.linef("    EGL_MAX_PBUFFER_WIDTH=%d", maxPbufferWidth);
                    r.linef("    EGL_MAX_PBUFFER_HEIGHT=%d", maxPbufferHeight);
                    r.linef("    EGL_MAX_PBUFFER_PIXELS=%d", maxPbufferPixels);
                }

                const int64_t requiredPixels =
                    static_cast<int64_t>(kProbePbufferWidth) * kProbePbufferHeight;
                bool capabilityOk = attrsOk;
                if (attrsOk && (surfaceType & (kEglWindowBit | kEglPbufferBit)) !=
                                   (kEglWindowBit | kEglPbufferBit)) {
                    r.linef("    [X] config %d 不同时支持 EGL_WINDOW_BIT|EGL_PBUFFER_BIT",
                            configId);
                    capabilityOk = false;
                }
                if (attrsOk && (maxPbufferWidth < kProbePbufferWidth ||
                                maxPbufferHeight < kProbePbufferHeight ||
                                static_cast<int64_t>(maxPbufferPixels) < requiredPixels)) {
                    r.linef("    [X] config %d 的 pbuffer 上限不足 320x480/%lld pixels",
                            configId, static_cast<long long>(requiredPixels));
                    capabilityOk = false;
                }

                EGLSurface pbuffer = nullptr;
                bool pbufferMadeCurrent = false;
                bool hostToPbufferOk = false;
                bool pbufferToHostOk = false;
                bool destroyOk = false;
                if (capabilityOk) {
                    const EGLint pbufferAttribs[] = {
                        kEglWidth, kProbePbufferWidth,
                        kEglHeight, kProbePbufferHeight,
                        kEglNone,
                    };
                    pbuffer = egl.createPbufferSurface(display, config, pbufferAttribs);
                    if (!pbuffer) {
                        r.linef("    [X] eglCreatePbufferSurface(320x480) 失败: EGL error=0x%04x",
                                egl.getError());
                    } else {
                        g_pbufferCreatedTotal.fetch_add(1, std::memory_order_relaxed);
                        EGLint actualWidth = 0;
                        EGLint actualHeight = 0;
                        const bool widthOk = egl.querySurface(display, pbuffer, kEglWidth, &actualWidth) != 0u;
                        if (!widthOk) {
                            r.linef("    [X] eglQuerySurface(EGL_WIDTH) 失败: EGL error=0x%04x",
                                    egl.getError());
                        }
                        const bool heightOk = egl.querySurface(display, pbuffer, kEglHeight, &actualHeight) != 0u;
                        if (!heightOk) {
                            r.linef("    [X] eglQuerySurface(EGL_HEIGHT) 失败: EGL error=0x%04x",
                                    egl.getError());
                        }
                        r.linef("    pbuffer=%p actual=%dx%d", pbuffer, actualWidth, actualHeight);

                        if (widthOk && heightOk && actualWidth == kProbePbufferWidth &&
                            actualHeight == kProbePbufferHeight) {
                            pbufferMadeCurrent = egl.makeCurrent(
                                display, pbuffer, pbuffer, currentContext) != 0u;
                            if (!pbufferMadeCurrent) {
                                r.linef("    [X] host→pbuffer eglMakeCurrent 失败: EGL error=0x%04x",
                                        egl.getError());
                            } else if (egl.getCurrentContext() != currentContext ||
                                       egl.getCurrentSurface(kEglDraw) != pbuffer) {
                                r.linef("    [X] host→pbuffer 返回成功但 current 身份不对: "
                                        "ctx=%p/%p draw=%p/%p",
                                        egl.getCurrentContext(), currentContext,
                                        egl.getCurrentSurface(kEglDraw), pbuffer);
                            } else {
                                const unsigned char *pbufferVersion = glGetStr ? glGetStr(kGlVersion) : nullptr;
                                if (glGetStr && !pbufferVersion) {
                                    r.line("    [X] host→pbuffer 后 glGetString(GL_VERSION) 返回 NULL");
                                } else {
                                    hostToPbufferOk = true;
                                    g_hostToPbufferTotal.fetch_add(1, std::memory_order_relaxed);
                                    r.linef("    host→pbuffer OK，同一 context=%p，GL_VERSION=%s",
                                            currentContext,
                                            pbufferVersion
                                                ? reinterpret_cast<const char *>(pbufferVersion)
                                                : "(未解析 glGetString)");
                                }
                            }
                        } else if (widthOk && heightOk) {
                            r.linef("    [X] pbuffer 实际尺寸不是 320x480: %dx%d",
                                    actualWidth, actualHeight);
                        }

                        // 绕过 SDL_GL_MakeCurrent 恢复是有意的：上面直接调了 EGL，
                        // SDL TLS 仍认为 (win,ctx) 已 current，用 SDL API 会短路而不落到 EGL。
                        if (pbufferMadeCurrent) {
                            if (!egl.makeCurrent(display, hostSurface, hostSurface, currentContext)) {
                                r.linef("    [X] pbuffer→host eglMakeCurrent 失败: EGL error=0x%04x",
                                        egl.getError());
                                if (!egl.makeCurrent(display, nullptr, nullptr, nullptr)) {
                                    r.linef("    [X] 恢复 host 失败后解绑 context 也失败: EGL error=0x%04x",
                                            egl.getError());
                                }
                            } else if (egl.getCurrentContext() != currentContext ||
                                       egl.getCurrentSurface(kEglDraw) != hostSurface) {
                                r.linef("    [X] pbuffer→host 返回成功但 current 身份不对: "
                                        "ctx=%p/%p draw=%p/%p",
                                        egl.getCurrentContext(), currentContext,
                                        egl.getCurrentSurface(kEglDraw), hostSurface);
                                if (!egl.makeCurrent(display, nullptr, nullptr, nullptr)) {
                                    r.linef("    [X] current 身份异常后解绑 context 失败: EGL error=0x%04x",
                                            egl.getError());
                                }
                            } else {
                                const unsigned char *hostVersion = glGetStr ? glGetStr(kGlVersion) : nullptr;
                                if (glGetStr && !hostVersion) {
                                    r.line("    [X] pbuffer→host 后 glGetString(GL_VERSION) 返回 NULL");
                                } else {
                                    pbufferToHostOk = true;
                                    g_pbufferToHostTotal.fetch_add(1, std::memory_order_relaxed);
                                    r.linef("    pbuffer→host OK，同一 context=%p，GL_VERSION=%s",
                                            currentContext,
                                            hostVersion
                                                ? reinterpret_cast<const char *>(hostVersion)
                                                : "(未解析 glGetString)");
                                }
                            }
                        }

                        destroyOk = egl.destroySurface(display, pbuffer) != 0u;
                        if (!destroyOk) {
                            r.linef("    [X] eglDestroySurface(pbuffer) 失败: EGL error=0x%04x",
                                    egl.getError());
                        } else {
                            r.line("    eglDestroySurface(pbuffer) OK");
                        }
                    }
                }

                pbufferOk = capabilityOk && pbuffer && hostToPbufferOk &&
                            pbufferToHostOk && destroyOk;
                if (pbufferOk) {
                    g_pbufferProbePassTotal.fetch_add(1, std::memory_order_relaxed);
                    r.line("    Phase 0 判定: PASS —— 同一 config/context 的 pbuffer↔host 可行");
                } else {
                    r.line("    Phase 0 判定: FAIL —— 失败边界见上方首条 [X]");
                }
            }
            reportPbufferCounters(r);

            if (hglfw) {
                dlclose(hglfw);
            }
        }

        if (!reinterpret_cast<fn_SDL_GL_MakeCurrent>(pGLMakeCurrent)(win, nullptr)) {
            r.linef("    [X] 清理时 SDL_GL_MakeCurrent(NULL) 失败: %s", sdlErr());
        }
        if (!reinterpret_cast<fn_SDL_GL_DestroyContext>(pGLDestroyCtx)(ctx)) {
            r.linef("    [X] SDL_GL_DestroyContext 失败: %s", sdlErr());
        }
    }
    r.line("");

    // ---------------------------------------------------------------------
    // [6] 清理。逆序，且必须在 SDL_Quit 之前销毁窗口 ——
    //     否则 OPENHARMONY_DestroyWindow 之后 OPENHARMONY_Window 悬空，
    //     与崩溃 #1（触摸空指针）是同一类风险。
    // ---------------------------------------------------------------------
    reinterpret_cast<fn_SDL_DestroyWindow>(pDestroyWin)(win);
    reinterpret_cast<fn_SDL_GL_UnloadLibrary>(pGLUnload)();
    reinterpret_cast<fn_SDL_Quit>(pQuit)();
    r.line("[6] 已清理（DestroyWindow → GL_UnloadLibrary → SDL_Quit）");
    r.line("");

    r.line("========================================");
    if (windowContextOk && pbufferOk) {
        r.line("判定: PASS ✅ —— 宿主窗口链路成立，且 pbuffer↔host 双向切换通过");
        r.line("      ⇒ Snapshot 9 隐藏 utility window 的 offscreen EGL 前提已被真机实测");
    } else if (windowContextOk) {
        r.line("判定: CAPABILITY_FAIL ❌ —— 原宿主窗口链路成立，但 pbuffer 双向切换不成立");
    } else {
        r.line("判定: PARTIAL ⚠️ —— SDL_CreateWindow 成功，但 GL 上下文未完全验证（见上）");
    }
    r.line("========================================");

    g_report = r.str();
    return g_report.c_str();
}

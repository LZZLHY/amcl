// glfw_internal.h — GLFW 兼容层内部共享状态
// 仅供 glfw/ 目录下的 .cpp 文件 include，不对外暴露

#ifndef GLFW_INTERNAL_H
#define GLFW_INTERNAL_H

#include "glfw_compat.h"
#include "size_notification_state.h"
#include "../platform/graphics_egl_context.h"

bool glfwOHOS_ValidatePlatformHint();
#include "../input/amcl_input_event.h"
#include "../input/adapters/glfw_backend_lifecycle.h"
#include "../platform/desktop_window_observation.h"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <atomic>
#include <chrono>
#include <string>
#include <sstream>
#include <vector>

struct GlfwPreeditState {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    std::vector<unsigned int> text;
    std::vector<std::vector<unsigned int>> candidates;
    int selectionStart = 0;
    int selectionLength = 0;
};

// ==================== GLFWwindow 内部结构 ====================
struct GLFWwindow : amcl::graphics::EglContextState {
    // 创建时锁存API与逻辑窗口身份；实际EGL句柄/尺寸/current owner在中立EglContextState中。
    int clientAPI;
    uint64_t windowId;
    int focused;
    bool visible;
    int cursorMode;
    bool cursorModeAssigned;
    // 标题由本窗口strdup/free持有，不能借用LWJGL临时MemoryStack上的UTF-8字节。
    const char* title;
    // 仅渲染owner消费并更新已发布的窗口代际；UI线程只向WindowHost发布快照。
    uint64_t nativeWindowGeneration;
    // broker负责NativeWindow引用。引用对象与当前呈现指针分开，surface替换期间不能误放新窗口。
    void* nativeWindowLeaseBroker;
    void* nativeWindowLeaseObject;
    long long nextSurfaceRecoveryAttemptMs;
    unsigned int surfaceRecoveryFailures;
    // 只存在于呈现窗口的BackendSession协调token与租约；EGL操作失败时保持可重试的资源状态。
    void* graphicsBackendSession;

    // 输入状态
    double cursorX;
    double cursorY;
    int mouseButtons[8];
    int keys[512];
    amcl::input::GlfwBackendCaptureState inputCapture;

    // 回调
    GLFWwindowsizefun windowSizeCb;
    GLFWframebuffersizefun framebufferSizeCb;
    GLFWkeyfun keyCb;
    GLFWcharfun charCb;
    GLFWcharmodsfun charModsCb;
    GLFWcursorenterfun cursorEnterCb;
    // 旧JNI输入路线直接在bridge注册，不经过C setter；未分配的C回调不能在show时覆盖它。
    bool charCallbackAssigned, charModsCallbackAssigned, cursorEnterCallbackAssigned;
    GLFWcursorposfun cursorPosCb;
    GLFWmousebuttonfun mouseButtonCb;
    GLFWscrollfun scrollCb;
    GLFWwindowclosefun closeCb;
    GLFWwindowfocusfun focusCb;
    GLFWwindowposfun positionCb;
    GLFWwindowiconifyfun iconifyCb;
    GLFWwindowmaximizefun maximizeCb;
    GLFWwindowcontentscalefun contentScaleCb;
    GLFWwindowrefreshfun refreshCb;
    GLFWdropfun dropCb;
    amcl::desktop::WindowObservation desktopObservation;
    void* userPointer;
    GLFWpreeditfun preeditCb;
    GLFWimestatusfun imeStatusCb;
    GLFWpreeditcandidatefun preeditCandidateCb;
    GlfwPreeditState* preeditState;
    amcl::glfw::SizeNotificationState sizeNotifications;
};
// 隐藏窗口显示时由GLFW核心取得唯一呈现权；成功后才允许前端发送系统show命令。
bool glfwOHOS_PromoteWindow(GLFWwindow* window);

struct GLFWmonitor {
    int64_t desktopId;
    int dummy;
    void* userPointer;
};

// ==================== 全局状态（定义在 glfw_compat.cpp）====================
extern GLFWwindow* g_currentWindow;
extern GLFWerrorfun g_errorCallback;
extern int g_initialized;

// Coherent Window/display facts delivered by the typed SurfaceContext sink.
// Returns false until the first context generation has been consumed.
bool glfwOHOS_ReadInputSurfaceContext(
    AmclInputSurfaceContextPayload* outContext);
void glfwOHOS_ClearInputSurfaceContext();
void glfwOHOS_PollDesktopDisplays();
void glfwOHOS_PrimeDesktopWindow(GLFWwindow* window);
bool glfwOHOS_ApplyInitialMonitor(GLFWwindow* window, GLFWmonitor* monitor, int width, int height);

void glfwOHOS_UpdatePreedit(
    GLFWwindow* window, const std::vector<unsigned int>& text,
    int selectionStart, int selectionLength);
bool glfwOHOS_UpdatePreeditSelection(
    GLFWwindow* window, int selectionStart, int selectionLength);
void glfwOHOS_UpdatePreeditCandidates(
    GLFWwindow* window,
    const std::vector<std::vector<unsigned int>>& candidates,
    int selectedIndex, int pageStart, int pageSize);
void glfwOHOS_NotifyImeStatus(GLFWwindow* window);
void glfwOHOS_ResetPreedit(GLFWwindow* window, bool notify);
void glfwOHOS_DestroyPreeditState(GLFWwindow* window);

// 窗口 hint 缓存
extern int g_hintClientAPI;
extern int g_hintMajor;
extern int g_hintProfile;
extern bool g_hintForwardCompatible;
extern int g_hintMinor;

// 统计
extern int g_swapCount;
extern int g_pollCount;

// cursor mode
extern int g_cursorMode;

// ==================== EGL 函数（定义在 glfw_egl.cpp）====================
bool InitEGL(GLFWwindow* win);
bool TerminateEGL(GLFWwindow* win);
// Surface-only lifecycle used for XComponent recreation. These preserve the
// EGLDisplay/EGLContext and therefore preserve Minecraft's GL objects.
bool SuspendEGLSurface(GLFWwindow* win);
bool AttachEGLSurface(GLFWwindow* win, void* nativeWindow, int width, int height);

// EGL session boundaries run the real adapter lifecycle. Vulkan WSI owns its
// own surface lease/token and never borrows this OpenGL session.
bool glfwOHOS_BeginGraphicsSession(GLFWwindow* win, const char* api,
                                   void* nativeWindow, uint64_t generation);
void glfwOHOS_GraphicsSurfaceCreated(GLFWwindow* win);
bool glfwOHOS_GraphicsSurfaceRetired(GLFWwindow* win);
bool glfwOHOS_EndGraphicsSession(GLFWwindow* win, bool resourcesDestroyed);
bool glfwOHOS_GraphicsSessionHasSurface(const GLFWwindow* win);
extern "C" int glfwOHOS_GetWindowClientAPI(const GLFWwindow* win);
extern "C" uint64_t glfwOHOS_GetWindowId(const GLFWwindow* win);

#endif // GLFW_INTERNAL_H

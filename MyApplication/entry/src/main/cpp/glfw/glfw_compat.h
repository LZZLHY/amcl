// glfw_compat.h — 最小 GLFW 兼容层头文件
// 模拟 GLFW 3.x API，底层映射到 HarmonyOS XComponent + EGL
// 用于验证 Minecraft/LWJGL 所需的窗口管理接口可行性

#ifndef GLFW_COMPAT_H
#define GLFW_COMPAT_H

#include <stdint.h>
#include "amcl_native_window_lease_broker_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

// ==================== GLFW 常量 ====================
#define GLFW_TRUE  1
#define GLFW_FALSE 0
#define GLFW_PLATFORM_ERROR 0x00010008
#define GLFW_NO_CURRENT_CONTEXT 0x00010002
#define GLFW_INVALID_VALUE 0x00010004
#define GLFW_NO_WINDOW_CONTEXT 0x0001000A
#define GLFW_PLATFORM_UNAVAILABLE 0x0001000E
#define GLFW_PLATFORM 0x00050003
#define GLFW_ANY_PLATFORM 0x00060000
#define GLFW_PLATFORM_NULL 0x00060005

// 按键状态
#define GLFW_RELEASE 0
#define GLFW_PRESS   1
#define GLFW_REPEAT  2

// 鼠标按钮
#define GLFW_MOUSE_BUTTON_LEFT   0
#define GLFW_MOUSE_BUTTON_RIGHT  1
#define GLFW_MOUSE_BUTTON_MIDDLE 2

// 窗口属性
#define GLFW_FOCUSED     0x00020001
#define GLFW_ICONIFIED   0x00020002
#define GLFW_VISIBLE     0x00020004
#define GLFW_RESIZABLE   0x00020003

// 上下文属性
#define GLFW_CLIENT_API          0x00022001
#define GLFW_NO_API              0
#define GLFW_CONTEXT_VERSION_MAJOR 0x00022002
#define GLFW_CONTEXT_VERSION_MINOR 0x00022003
#define GLFW_OPENGL_ES_API       0x00030002

// 输入模式
#define GLFW_CURSOR              0x00033001
#define GLFW_CURSOR_NORMAL       0x00034001
#define GLFW_CURSOR_HIDDEN       0x00034002
#define GLFW_CURSOR_DISABLED     0x00034003

// ==================== GLFW 类型 ====================
typedef struct GLFWwindow GLFWwindow;
typedef struct GLFWmonitor GLFWmonitor;

typedef void (*GLFWerrorfun)(int error, const char* description);
typedef void (*GLFWwindowsizefun)(GLFWwindow* window, int width, int height);
typedef void (*GLFWframebuffersizefun)(GLFWwindow* window, int width, int height);
typedef void (*GLFWkeyfun)(GLFWwindow* window, int key, int scancode, int action, int mods);
typedef void (*GLFWcursorposfun)(GLFWwindow* window, double xpos, double ypos);
typedef void (*GLFWmousebuttonfun)(GLFWwindow* window, int button, int action, int mods);
typedef void (*GLFWscrollfun)(GLFWwindow* window, double xoffset, double yoffset);
typedef void (*GLFWwindowclosefun)(GLFWwindow* window);
typedef void (*GLFWwindowfocusfun)(GLFWwindow* window, int focused);

// ==================== GLFW 版本 ====================
#define GLFW_VERSION_MAJOR 3
#define GLFW_VERSION_MINOR 4
#define GLFW_VERSION_REVISION 1

// 更多窗口 hint
#define GLFW_OPENGL_PROFILE        0x00022008
#define GLFW_OPENGL_FORWARD_COMPAT 0x00022006
#define GLFW_OPENGL_CORE_PROFILE   0x00032001
#define GLFW_OPENGL_ANY_PROFILE    0
#define GLFW_OPENGL_API            0x00030001
#define GLFW_CONTEXT_CREATION_API  0x0002200B
#define GLFW_NATIVE_CONTEXT_API    0x00036001
#define GLFW_DECORATED             0x00020005
#define GLFW_FLOATING              0x00020007
#define GLFW_MAXIMIZED             0x00020008
#define GLFW_CENTER_CURSOR         0x00020009
#define GLFW_TRANSPARENT_FRAMEBUFFER 0x0002000A
#define GLFW_FOCUS_ON_SHOW         0x0002000C
#define GLFW_SCALE_TO_MONITOR      0x0002200C
#define GLFW_RED_BITS              0x00021001
#define GLFW_GREEN_BITS            0x00021002
#define GLFW_BLUE_BITS             0x00021003
#define GLFW_ALPHA_BITS            0x00021004
#define GLFW_DEPTH_BITS            0x00021005
#define GLFW_STENCIL_BITS          0x00021006
#define GLFW_SAMPLES               0x0002100D
#define GLFW_REFRESH_RATE          0x0002100F
#define GLFW_DOUBLEBUFFER          0x00021010
#define GLFW_CONTEXT_ROBUSTNESS    0x00022005
#define GLFW_CONTEXT_RELEASE_BEHAVIOR 0x00022009
#define GLFW_NO_ROBUSTNESS         0
#define GLFW_ANY_RELEASE_BEHAVIOR  0
#define GLFW_RAW_MOUSE_MOTION      0x00033005
#define GLFW_STICKY_KEYS           0x00033002
#define GLFW_STICKY_MOUSE_BUTTONS  0x00033003
#define GLFW_LOCK_KEY_MODS         0x00033004

// 视频模式
typedef struct GLFWvidmode {
    int width;
    int height;
    int redBits;
    int greenBits;
    int blueBits;
    int refreshRate;
} GLFWvidmode;

// 图像
typedef struct GLFWimage {
    int width;
    int height;
    unsigned char* pixels;
} GLFWimage;

// 游标
typedef struct GLFWcursor GLFWcursor;

// 更多回调类型
typedef void (*GLFWcharfun)(GLFWwindow* window, unsigned int codepoint);
typedef void (*GLFWcharmodsfun)(GLFWwindow* window, unsigned int codepoint, int mods);
typedef void (*GLFWdropfun)(GLFWwindow* window, int count, const char** paths);
typedef void (*GLFWwindowiconifyfun)(GLFWwindow* window, int iconified);
typedef void (*GLFWwindowmaximizefun)(GLFWwindow* window, int maximized);
typedef void (*GLFWwindowcontentscalefun)(GLFWwindow* window, float xscale, float yscale);
typedef void (*GLFWwindowrefreshfun)(GLFWwindow* window);
typedef void (*GLFWwindowposfun)(GLFWwindow* window, int xpos, int ypos);
typedef void (*GLFWjoystickfun)(int jid, int event);
typedef void (*GLFWmonitorfun)(GLFWmonitor* monitor, int event);

// ==================== GLFW 核心函数 ====================
int glfwInit(void);
void glfwTerminate(void);
void glfwWindowHint(int hint, int value);
void glfwDefaultWindowHints(void);
GLFWwindow* glfwCreateWindow(int width, int height, const char* title,
                              GLFWmonitor* monitor, GLFWwindow* share);
void glfwDestroyWindow(GLFWwindow* window);
int glfwWindowShouldClose(GLFWwindow* window);
void glfwSetWindowShouldClose(GLFWwindow* window, int value);
void glfwSwapBuffers(GLFWwindow* window);
void glfwPollEvents(void);
void glfwWaitEvents(void);
void glfwWaitEventsTimeout(double timeout);
void glfwPostEmptyEvent(void);
void glfwMakeContextCurrent(GLFWwindow* window);
GLFWwindow* glfwGetCurrentContext(void);
void glfwSwapInterval(int interval);
double glfwGetTime(void);
void glfwSetTime(double time);
void glfwGetVersion(int* major, int* minor, int* rev);
const char* glfwGetVersionString(void);
void glfwGetWindowSize(GLFWwindow* window, int* width, int* height);
void glfwSetWindowSize(GLFWwindow* window, int width, int height);
void glfwGetFramebufferSize(GLFWwindow* window, int* width, int* height);
void glfwSetWindowTitle(GLFWwindow* window, const char* title);
const char* glfwGetWindowTitle(GLFWwindow* window);
void glfwSetWindowIcon(GLFWwindow* window, int count, const GLFWimage* images);
void glfwSetWindowPos(GLFWwindow* window, int xpos, int ypos);
void glfwGetWindowPos(GLFWwindow* window, int* xpos, int* ypos);
void glfwSetWindowSizeLimits(GLFWwindow* window, int minw, int minh, int maxw, int maxh);
void glfwSetWindowAspectRatio(GLFWwindow* window, int numer, int denom);
void glfwIconifyWindow(GLFWwindow* window);
void glfwRestoreWindow(GLFWwindow* window);
void glfwMaximizeWindow(GLFWwindow* window);
void glfwShowWindow(GLFWwindow* window);
void glfwHideWindow(GLFWwindow* window);
void glfwFocusWindow(GLFWwindow* window);
void glfwRequestWindowAttention(GLFWwindow* window);
int glfwGetWindowAttrib(GLFWwindow* window, int attrib);
void glfwSetWindowAttrib(GLFWwindow* window, int attrib, int value);
void glfwSetWindowUserPointer(GLFWwindow* window, void* pointer);
void* glfwGetWindowUserPointer(GLFWwindow* window);
void glfwGetWindowContentScale(GLFWwindow* window, float* xscale, float* yscale);
float glfwGetWindowOpacity(GLFWwindow* window);
void glfwSetWindowOpacity(GLFWwindow* window, float opacity);

// ==================== 监视器 ====================
GLFWmonitor* glfwGetPrimaryMonitor(void);
GLFWmonitor** glfwGetMonitors(int* count);
const GLFWvidmode* glfwGetVideoMode(GLFWmonitor* monitor);
const GLFWvidmode* glfwGetVideoModes(GLFWmonitor* monitor, int* count);
void glfwGetMonitorPos(GLFWmonitor* monitor, int* xpos, int* ypos);
void glfwGetMonitorWorkarea(GLFWmonitor* monitor, int* xpos, int* ypos, int* width, int* height);
void glfwGetMonitorPhysicalSize(GLFWmonitor* monitor, int* widthMM, int* heightMM);
void glfwGetMonitorContentScale(GLFWmonitor* monitor, float* xscale, float* yscale);
const char* glfwGetMonitorName(GLFWmonitor* monitor);
GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun callback);

// ==================== 输入 ====================
int glfwGetKey(GLFWwindow* window, int key);
int glfwGetMouseButton(GLFWwindow* window, int button);
void glfwGetCursorPos(GLFWwindow* window, double* xpos, double* ypos);
void glfwSetCursorPos(GLFWwindow* window, double xpos, double ypos);
void glfwSetInputMode(GLFWwindow* window, int mode, int value);
int glfwGetInputMode(GLFWwindow* window, int mode);
int glfwRawMouseMotionSupported(void);
const char* glfwGetKeyName(int key, int scancode);
int glfwGetKeyScancode(int key);
GLFWcursor* glfwCreateStandardCursor(int shape);
GLFWcursor* glfwCreateCursor(const GLFWimage* image, int xhot, int yhot);
void glfwDestroyCursor(GLFWcursor* cursor);
void glfwSetCursor(GLFWwindow* window, GLFWcursor* cursor);
int glfwJoystickPresent(int jid);
const float* glfwGetJoystickAxes(int jid, int* count);
const unsigned char* glfwGetJoystickButtons(int jid, int* count);
const unsigned char* glfwGetJoystickHats(int jid, int* count);
const char* glfwGetJoystickName(int jid);
const char* glfwGetJoystickGUID(int jid);
int glfwJoystickIsGamepad(int jid);
const char* glfwGetGamepadName(int jid);
GLFWjoystickfun glfwSetJoystickCallback(GLFWjoystickfun callback);
const char* glfwGetClipboardString(GLFWwindow* window);
void glfwSetClipboardString(GLFWwindow* window, const char* string);

// ==================== 回调设置 ====================
GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun callback);
GLFWwindowsizefun glfwSetWindowSizeCallback(GLFWwindow* window, GLFWwindowsizefun callback);
GLFWframebuffersizefun glfwSetFramebufferSizeCallback(GLFWwindow* window, GLFWframebuffersizefun callback);
GLFWkeyfun glfwSetKeyCallback(GLFWwindow* window, GLFWkeyfun callback);
GLFWcursorposfun glfwSetCursorPosCallback(GLFWwindow* window, GLFWcursorposfun callback);
GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow* window, GLFWmousebuttonfun callback);
GLFWscrollfun glfwSetScrollCallback(GLFWwindow* window, GLFWscrollfun callback);
GLFWwindowclosefun glfwSetWindowCloseCallback(GLFWwindow* window, GLFWwindowclosefun callback);
GLFWcharfun glfwSetCharCallback(GLFWwindow* window, GLFWcharfun callback);
GLFWcharmodsfun glfwSetCharModsCallback(GLFWwindow* window, GLFWcharmodsfun callback);
GLFWdropfun glfwSetDropCallback(GLFWwindow* window, GLFWdropfun callback);
GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow* window, GLFWwindowiconifyfun callback);
GLFWwindowmaximizefun glfwSetWindowMaximizeCallback(GLFWwindow* window, GLFWwindowmaximizefun callback);
GLFWwindowcontentscalefun glfwSetWindowContentScaleCallback(GLFWwindow* window, GLFWwindowcontentscalefun callback);
GLFWwindowrefreshfun glfwSetWindowRefreshCallback(GLFWwindow* window, GLFWwindowrefreshfun callback);
GLFWwindowposfun glfwSetWindowPosCallback(GLFWwindow* window, GLFWwindowposfun callback);
GLFWwindowfocusfun glfwSetWindowFocusCallback(GLFWwindow* window, GLFWwindowfocusfun callback);

// ==================== GLFW 3.3+ 新增 ====================
void glfwInitHint(int hint, int value);
void glfwInitAllocator(const void* allocator);
int glfwGetError(const char** description);
int glfwGetPlatform(void);
int glfwPlatformSupported(int platform);
void glfwSetMonitorUserPointer(GLFWmonitor* monitor, void* pointer);
void* glfwGetMonitorUserPointer(GLFWmonitor* monitor);
void glfwSetGamma(GLFWmonitor* monitor, float gamma);
const void* glfwGetGammaRamp(GLFWmonitor* monitor);
void glfwSetGammaRamp(GLFWmonitor* monitor, const void* ramp);
void glfwWindowHintString(int hint, const char* value);
void glfwGetWindowFrameSize(GLFWwindow* window, int* left, int* top, int* right, int* bottom);

// ==================== GLFW IME/preedit 扩展（LWJGL 3.4 fcitx/ibus fork 绑定）====================
// MC 26.1 的 InputConstants.setupKeyboardCallbacks 会调用 glfwSetPreeditCallback 等。
// 这些在上游 LWJGL 是 apiGetFunctionAddressOptional（类初始化不抛），但 MC 真调用时
// LWJGL 的 Checks.check(__functionAddress) 对 null 地址抛 NPE → 必须导出非空 C 符号（stub）。
typedef void (*GLFWpreeditfun)(GLFWwindow* window, int preeditCount,
                               unsigned int* preeditString, int blockCount,
                               int* blockSizes, int focusedBlock, int caret);
typedef void (*GLFWimestatusfun)(GLFWwindow* window);
typedef void (*GLFWpreeditcandidatefun)(GLFWwindow* window, int candidatesCount,
                                        int selectedIndex, int pageStart, int pageSize);
GLFWpreeditfun glfwSetPreeditCallback(GLFWwindow* window, GLFWpreeditfun cbfun);
GLFWimestatusfun glfwSetIMEStatusCallback(GLFWwindow* window, GLFWimestatusfun cbfun);
GLFWpreeditcandidatefun glfwSetPreeditCandidateCallback(GLFWwindow* window, GLFWpreeditcandidatefun cbfun);
void glfwGetPreeditCursorRectangle(GLFWwindow* window, int* x, int* y, int* w, int* h);
void glfwSetPreeditCursorRectangle(GLFWwindow* window, int x, int y, int w, int h);
void glfwResetPreeditText(GLFWwindow* window);
unsigned int* glfwGetPreeditCandidate(GLFWwindow* window, int index, int* textCount);
GLFWmonitor* glfwGetWindowMonitor(GLFWwindow* window);
void glfwSetWindowMonitor(GLFWwindow* window, GLFWmonitor* monitor, int xpos, int ypos, int width, int height, int refreshRate);

// 更多回调
typedef void (*GLFWcursorenterfun)(GLFWwindow* window, int entered);
GLFWcursorenterfun glfwSetCursorEnterCallback(GLFWwindow* window, GLFWcursorenterfun callback);

// Joystick 扩展
void glfwSetJoystickUserPointer(int jid, void* pointer);
void* glfwGetJoystickUserPointer(int jid);
int glfwUpdateGamepadMappings(const char* string);
typedef struct GLFWgamepadstate { unsigned char buttons[15]; float axes[6]; } GLFWgamepadstate;
int glfwGetGamepadState(int jid, GLFWgamepadstate* state);

// Timer
unsigned long long glfwGetTimerValue(void);
unsigned long long glfwGetTimerFrequency(void);

// ==================== GL 加载 ====================
typedef void (*GLFWglproc)(void);
GLFWglproc glfwGetProcAddress(const char* procname);
int glfwExtensionSupported(const char* extension);
int glfwVulkanSupported(void);

// ==================== Vulkan surface（Phase 2，实现见 glfw_vulkan.cpp）====================
// LWJGL GLFWVulkan 从 libglfw.so 按符号名 dlsym 这组函数（glfwInitVulkanLoader /
// glfwGetRequiredInstanceExtensions / glfwGetInstanceProcAddress /
// glfwGetPhysicalDevicePresentationSupport / glfwCreateWindowSurface），运行时解析、
// **不经 C 头声明**。这里故意不声明它们：其真实签名用 Vulkan 类型（PFN_vkGetInstanceProcAddr /
// VkInstance / VkResult ...），定义在 glfw_vulkan.cpp。若在此用基础类型（void*/int）声明，
// extern "C" 下会与 .cpp 的真实签名「conflicting types / 仅返回类型不同无法重载」编译失败。
// glfwVulkanSupported 已在上面声明（int(void)，与真实签名一致，无冲突）。

// ==================== OHOS 特有扩展 ====================
// 将 XComponent 的 NativeWindow 绑定到 GLFW 窗口
void glfwOHOS_SetNativeWindow(void* nativeWindow, int width, int height);
// 原子窗口快照：pointer / size / generation 在同一临界区内提交和读取。
// generation 从 1 开始递增；Update/Clear 必须同时匹配 pointer + expected generation，
// 返回 0 时不会修改 snapshot、NativeWindow ref、ready 或跨 namespace env publication。
// Pure/testable overflow seam: UINT64_MAX has no nonzero successor.
uint64_t glfwOHOS_NextNativeWindowGeneration(uint64_t currentGeneration);
uint64_t glfwOHOS_PublishNativeWindow(void* nativeWindow, int width, int height);
uint64_t glfwOHOS_UpdateNativeWindowSize(void* expectedWindow,
                                         uint64_t expectedPublicationGeneration,
                                         int width, int height);
uint64_t glfwOHOS_ClearNativeWindow(void* expectedWindow,
                                    uint64_t expectedPublicationGeneration);
int glfwOHOS_GetNativeWindowSnapshot(void** outNativeWindow, int* outWidth, int* outHeight,
                                     uint64_t* outGeneration);
// Lock-free publication checkpoint used by SDL's steady-state MakeCurrent/Swap
// path. Generation is the commit token; a changed value requires a full broker
// acquire before dereferencing any newly published NativeWindow.
uint64_t glfwOHOS_PeekNativeWindowGeneration(void);
AmclNativeWindowPublicationState glfwOHOS_PeekNativeWindowPublicationState(void);
// Linearizable input-side publication lease. A successful begin prevents
// Publish/Update/Clear from completing until End, so validation and the GLFW
// cursor/button callback share one NativeWindow generation even across linker
// namespaces. `outBroker` is an opaque process-owner token and must be ended on
// the same thread.
int glfwOHOS_BeginNativeWindowInputPublication(
    int* outWidth, int* outHeight, uint64_t* outGeneration, void** outBroker);
void glfwOHOS_EndNativeWindowInputPublication(void* brokerToken);
// Safe render-side snapshot. A successful call owns one NativeWindow reference;
// pass both returned window and broker token to ReleaseNativeWindowLease only
// after EGL/OSMesa has stopped using that window.
int glfwOHOS_AcquireNativeWindowSnapshot(void* retainedNativeWindow,
                                         uint64_t retainedGeneration,
                                         void* retainedLeaseBroker,
                                         void** outNativeWindow, int* outWidth,
                                         int* outHeight, uint64_t* outGeneration,
                                         void** outLeaseBroker);
void glfwOHOS_ReleaseNativeWindowLease(void* nativeWindow, void* leaseBroker);
// Borrowed compatibility view. Do not retain this pointer across an
// XComponent callback or use it for asynchronous rendering.
void* glfwOHOS_GetNativeWindow(int* outWidth, int* outHeight);
void glfwOHOS_SetTouchEvent(float x, float y, int action);
const char* glfwOHOS_GetCompatInfo(void);

// MC 退出检测：获取最后一次 glfwSwapBuffers 的时间戳（毫秒）
long long glfwOHOS_GetLastSwapTimeMs(void);

// 强制关闭 GLFW 窗口（设置 shouldClose = 1）
void glfwOHOS_ForceClose(void);

// 注册窗口销毁回调（MC 退出时 glfwDestroyWindow 被调用时触发）
typedef void (*glfwOHOS_WindowDestroyCallback)(void);
void glfwOHOS_SetWindowDestroyCallback(glfwOHOS_WindowDestroyCallback cb);

#ifdef __cplusplus
}
#endif

#endif // GLFW_COMPAT_H

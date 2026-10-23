#include "../input/amcl_input_api.h"
#include "../input/delivery/look_transport.h"
#include "../input/input_look_core_hook.h"
#include "../input/source/source_control.h"
#include "../input/delivery/l2_keyboard_scope.h"

#if AMCL_DESKTOP_EVENT_BRIDGE
#ifdef __cplusplus
extern "C" void amclDesktopNotifyInput(void);
#else
extern void amclDesktopNotifyInput(void);
#endif
#else
#define amclDesktopNotifyInput() ((void)0)
#endif
/**
 * input_bridge_ohos.c — HarmonyOS GLFW Input Bridge
 *
 * Adapted from PojavLauncher's input_bridge_v3.c for HarmonyOS (AMCL).
 * Key differences from the original:
 *   - Single JVM (no Dalvik/MC JVM split)
 *   - Touch events come from NAPI (ArkTS XComponent.onTouch)
 *   - No Android Choreographer dependency
 *   - Simplified clipboard (TODO: OHOS pasteboard)
 *
 * Architecture:
 *   ArkTS touch → NAPI → ohos_send_touch() → ring buffer
 *   MC thread → glfwPollEvents() → inputBridgeStartPumping/PumpEvents/StopPumping
 *     → dispatches to GLFW callback function pointers
 *
 * JNI functions provided (called by lwjgl-glfw-ohos.jar):
 *   - CallbackBridge: nativeSendCursorPos, nativeSendMouseButton, nativeSendKey, etc.
 *   - GLFW: nglfwSetXxxCallback, nglfwGetCursorPos, glfwSetCursorPos
 */

#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
// The production bridge is C11 + pthread. Host integration tests compile this
// exact source as C++, replacing only platform primitives; ring, pump, overflow
// and cancel behavior below remains the shipping implementation.
//
// ⚠️ 2026-08-23：**替身只在 Windows 需要，POSIX 宿主用真 pthread**。此前 mutex 那三件
// （`pthread_mutex_t` / `PTHREAD_MUTEX_INITIALIZER` / 两个 lock 函数）无条件替换，在 Linux 上
// 与 glibc 真实声明**直接冲突**（`conflicting declaration`、`redefined`、`declared extern and
// later static`）。⇒ 现在 Linux/GCC 那条路线跑的是**真 pthread 互斥量**，这正是它相对 MSVC
// 路线多买到的证据之一（ring 是并发结构，`std::mutex` 替身证明不了真 pthread 语义）。
// 原子量仍统一用 C++ `<atomic>`：本 TU 被 CMake 显式 `LANGUAGE CXX` 编译，而 `<stdatomic.h>`
// 在 C++ 模式下的可用性依赖编译器与标准版本，不是可依赖的前提。
#include <atomic>
#include <cstdlib>
// `<mutex>` 无条件包含：本 TU 在 host 配置下另有一处直接用 `std::recursive_mutex`
// （见下方 `g_physicalMotionModeMutex`），与 Windows 的 pthread 替身是两回事。
#include <mutex>
using atomic_bool = std::atomic_bool;
using atomic_uint = std::atomic_uint;
using atomic_ullong = std::atomic_ullong;
using std::atomic_exchange_explicit;
using std::atomic_fetch_add_explicit;
using std::atomic_fetch_sub_explicit;
using std::atomic_load_explicit;
using std::atomic_store_explicit;
using std::atomic_thread_fence;
using std::memory_order_acq_rel;
using std::memory_order_acquire;
using std::memory_order_relaxed;
using std::memory_order_release;
#define _Thread_local thread_local
#ifdef _WIN32
#include <process.h>
// Windows 没有 pthread，也没有 POSIX `setenv`：这两组替身是 Windows 专用的。
using pthread_mutex_t = std::mutex;
#define PTHREAD_MUTEX_INITIALIZER {}
static int pthread_mutex_lock(pthread_mutex_t* mutex) {
    mutex->lock();
    return 0;
}
static int pthread_mutex_unlock(pthread_mutex_t* mutex) {
    mutex->unlock();
    return 0;
}
static int amclHostSetEnv(const char* name, const char* value, int) {
    return _putenv_s(name, value);
}
#define setenv amclHostSetEnv
#else
#include <pthread.h>
// POSIX宿主同样执行真实PID围栏；getpid声明不能依赖仅生产NDK分支才包含的头文件。
#include <unistd.h>
#endif
#else
#include <stdatomic.h>
#include <pthread.h>
#endif
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <hilog/log.h>

// 非 GLFW 后端的 typed 拉取 ABI。刻意 include 而不是本地重声明函数原型：原型漂移会变成
// 一次 ABI 不匹配的调用，而那在真机上表现为随机键码。
#include "../input/adapters/backend_input_bridge.h"
// LWJGL2 出线翻译的纯函数接缝。本文件只留取事件与写回余量的循环。
#include "../input/adapters/lwjgl2_event_translate.h"
// 跨 image 实例描述符的 env 编解码（纯函数，有 host 断言）。见下方"跨 image 实例委派"。
#include "input_bridge_instance_descriptor.h"

// JNI types (OHOS NDK doesn't have jni.h, our JVM provides it at runtime)
// We forward-declare what we need
typedef void* JNIEnv_ptr;
typedef void* jclass_ptr;
typedef void* jobject_ptr;
typedef long long jlong;
typedef int jint;
typedef short jshort;
typedef char jbyte;
typedef unsigned char jboolean;
typedef float jfloat;
typedef double jdouble;
typedef unsigned short jchar;

// Use the real JNI types from our embedded JVM's headers
// The JVM is loaded at runtime, so we use dlsym for JNI_OnLoad
// For now, define the function signatures we need
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
#define JNIEXPORT
#else
#define JNIEXPORT __attribute__((visibility("default")))
#endif
#define JNICALL

#undef LOG_TAG
#define LOG_TAG "InputBridge"
#define LOG_DOMAIN 0x0000

#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)
#include "../input/input_latency_observation.h"

#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
#include <unistd.h>
#include "../platform/graphics_observation_abi.h"
#endif
static void registerGraphicsPresentationSinks(void);
static void publishGraphicsPresentation(const char* provider);
static void advanceGlfwPresentation(uint64_t window, uint64_t generation);
static void advanceSdlPresentation(uint64_t window, uint64_t generation);

// ============================================================
//  MC 退出回调（当 glfwTerminate Java 层调用 nativeSetInputReady(false) 时触发）
// ============================================================
typedef void (*mc_exit_callback_t)(void);
static mc_exit_callback_t g_mcExitCallback = NULL;
// 定义在下方"跨 image 实例委派"之后 —— 它和其它每一个公开入口一样需要那道委派闸门。
JNIEXPORT void inputBridge_setMcExitCallback(mc_exit_callback_t cb);

// 所有 GLFW2/GLFW3/Java 兼容入口最终都必须经过这些权威写点。
JNIEXPORT void inputBridge_setGrabState(int grabbing);
JNIEXPORT bool inputBridge_isGrabbing(void);
JNIEXPORT int inputBridge_beginPhysicalMotionTransaction(int* outGrabbing);
JNIEXPORT void inputBridge_endPhysicalMotionTransaction(void);
// 下面三个由 inputBridge_publishAddress() 发布给 SDL3 消费端（定义在本文件后半部分）。
void inputBridge_getCursorSnapshot(double* outX, double* outY);
JNIEXPORT void inputBridge_setLookCursor(double x, double y);
int inputBridge_sdlNextEvent(int* outType, int* o1, int* o2, int* o3, int* o4);
void inputBridge_sdlSetActive(int active);
void inputBridge_sdlNotifyFramePresented(void);
void inputBridge_setWindowSize(int w, int h);

// ============================================================
//  Constants
// ============================================================

#ifndef EVENT_WINDOW_SIZE
#define EVENT_WINDOW_SIZE 4096
#endif

// Event types (must match CallbackBridge.java constants)
#define EVENT_TYPE_CHAR          1000
#define EVENT_TYPE_CHAR_MODS     1001
#define EVENT_TYPE_CURSOR_ENTER  1002
#define EVENT_TYPE_KEY           1005
#define EVENT_TYPE_MOUSE_BUTTON  1006
#define EVENT_TYPE_SCROLL        1007
// Native-only ordered menu pointer transaction (not part of CallbackBridge.java ABI).
#define EVENT_TYPE_MENU_POINTER  1008
#define EVENT_TYPE_TOUCH_MENU_TOOL 1011
#define EVENT_TYPE_TOUCH_MENU_CURSOR 1012
#define EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR 1013
#define EVENT_TYPE_TOUCH_MENU_SCROLL 1014
#define EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL 1015
#define EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE 1016
#define EVENT_TYPE_TOUCH_MENU_RELATIVE 1017
// Native-only LWJGL2 recovery marker. It never enters GLFW3 callbacks; the Java backend uses it to
// clear its own key/button polling arrays after native ring recovery, because those arrays are a
// separate state cache that cannot be repaired by only clearing g_keyDownBuffer/g_mouseDownBuffer.
#define EVENT_TYPE_INPUT_RESET   1009
// 两个 IEEE double 的位模式占四个 int；坐标与其它边沿一起排队，禁止读取未来坐标。
#define EVENT_TYPE_CURSOR_POSITION 1010
#define MENU_POINTER_MOVE         0
#define MENU_POINTER_DOWN         1
#define MENU_POINTER_UP           2
#define MENU_POINTER_CANCEL       3
#define MENU_POINTER_BEGIN        4
#define MENU_POINTER_END          5

// GLFW constants
#define GLFW_PRESS   1
#define GLFW_RELEASE 0
#define GLFW_MOUSE_BUTTON_LEFT   0
#define GLFW_MOUSE_BUTTON_RIGHT  1
#define GLFW_MOUSE_BUTTON_MIDDLE 2
#define GLFW_CURSOR              0x00033001
#define GLFW_CURSOR_NORMAL       0x00034001
#define GLFW_CURSOR_HIDDEN       0x00034002
#define GLFW_CURSOR_DISABLED     0x00034003

// ============================================================
//  Event structure
// ============================================================

typedef struct {
    int type;
    int i1, i2, i3, i4;
} GLFWInputEvent;

// ============================================================
//  Callback function pointer types
// ============================================================

typedef void (*GLFW_invoke_Char_func)(void* window, unsigned int codepoint);
typedef void (*GLFW_invoke_CharMods_func)(void* window, unsigned int codepoint, int mods);
typedef void (*GLFW_invoke_CursorEnter_func)(void* window, int entered);
typedef void (*GLFW_invoke_CursorPos_func)(void* window, double xpos, double ypos);
typedef void (*GLFW_invoke_FramebufferSize_func)(void* window, int width, int height);
typedef void (*GLFW_invoke_Key_func)(void* window, int key, int scancode, int action, int mods);
typedef void (*GLFW_invoke_MouseButton_func)(void* window, int button, int action, int mods);
typedef void (*GLFW_invoke_Scroll_func)(void* window, double xoffset, double yoffset);
typedef void (*GLFW_invoke_WindowSize_func)(void* window, int width, int height);

// ============================================================
//  ⭐ 跨 image 实例委派（2026-09-03）
//
//  `libglfw.so` 在进程里有两份，而本文件的状态全是 TU 静态 ⇒ 两份 image = 两条互不相干
//  的 bridge。本节令 bridge 成为**进程单例**：owner（拥有 XComponent 的那份）在
//  `inputBridge_publishAddress()` 里发布整张函数表；其它 image 的每个公开入口先问
//  `bridgeDelegate()`，非 NULL 即整体转发，本地 ring / 游标 / 回调 / 事务状态不参与。
//  因果、为何必须转发整张表而不只是 pump、真机判据：见计划 §114。
//
//  ⚠️ 三条不变量，改本节前逐条确认：
//   1. 表里存的就是公开入口本身，不另写"真身" ⇒ owner 自己调进来时 `bridgeDelegate()`
//      返回 NULL 直落本地实现，结构上不可能自递归。
//   2. env 缺失**不得**缓存成"我是 owner"：宿主可能还没发布，缓存即让 MC 那份永久
//      drain 自己的空 ring —— 那正是本次回归的形状。
//   3. 回调注册可能早于 owner 出现 ⇒ 注册先落本地，解析到 owner 时补发一次（幂等）。
// ============================================================

#include "../input/input_interaction_order.h"
#include "../input/input_menu_cursor_snapshot.h"
#include "../input/delivery/pointer_transaction.h"
#include "../input/delivery/control_delivery.h"
#ifdef AMCL_CONTROL_DELIVERY_HOST_TESTING
// 仅替换host可编程transport路由；Core/控制owner仍是真实实现。
#ifdef __cplusplus
extern "C" int amclBackendInputHostStubTypedRouteActive(void);
#else
extern int amclBackendInputHostStubTypedRouteActive(void);
#endif
#endif
#include "../input/input_surface_context_snapshot.h"
// 旧私有槽只在此边缘解码；机械核对阶段值，避免新共同实现与保留的 transport 漂移。
#define AMCL_POINTER_PHASE_CONTRACT (MENU_POINTER_MOVE == AMCL_POINTER_MOVE && \
    MENU_POINTER_DOWN == AMCL_POINTER_DOWN && MENU_POINTER_UP == AMCL_POINTER_UP && \
    MENU_POINTER_CANCEL == AMCL_POINTER_CANCEL && MENU_POINTER_BEGIN == AMCL_POINTER_BEGIN && \
    MENU_POINTER_END == AMCL_POINTER_END)
#ifdef __cplusplus
static_assert(AMCL_POINTER_PHASE_CONTRACT, "private pointer phase encoding drift");
#else
_Static_assert(AMCL_POINTER_PHASE_CONTRACT, "private pointer phase encoding drift");
#endif
#undef AMCL_POINTER_PHASE_CONTRACT
// 有序泵回调在队列锁外执行；返回 0 说明目标生命周期已失效，立即停止本轮。
typedef int (*InputBridgeOrderedPump)(void* context, uint64_t maxOrder);
void inputBridge_pumpOrdered(void* window, InputBridgeOrderedPump pump, void* context,
                             uint64_t maxOrder);
uint64_t inputBridge_sdlPeekOrder(void);
int inputBridge_sdlNextThrough(int* type, int* a, int* b, int* c, int* d, uint64_t maxOrder);
void inputBridge_publishMenuCursor(double x, double y);
// 仅推进触控菜单作用域，不调用 Native 或游戏；真正释放在各消费者自己的线程完成。
JNIEXPORT void inputBridge_retireTouchMenuScopeV1(void);
JNIEXPORT void inputBridge_retireTouchMenuToolScopeV1(void);
JNIEXPORT void inputBridge_pushTouchMenuToolV1(int code, int action);
JNIEXPORT void inputBridge_publishTouchMenuCursorV1(double x, double y);
JNIEXPORT void inputBridge_sdlSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity);
JNIEXPORT void inputBridge_sdlNotifyFramePresentedForTargetV1(uint64_t window, uint64_t generation);
JNIEXPORT void inputBridge_glfwSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity);
JNIEXPORT void inputBridge_publishTouchMenuScrollV1(int xoffset, int yoffset);
JNIEXPORT void inputBridge_pushTouchMenuToolScrollV1(int xoffset, int yoffset);
JNIEXPORT void inputBridge_publishTouchMenuToolCursorV1(double x, double y);
JNIEXPORT void inputBridge_publishTouchMenuToolRelativeV1(double dx, double dy, double maxX, double maxY);
JNIEXPORT void inputBridge_publishTouchMenuRelativeV1(int phase, uint32_t token, double dx, double dy, double maxX, double maxY);

// 公开入口的前向声明。表里每一项都必须是这些符号之一（见不变量 1）。
JNIEXPORT void inputBridge_pushEvent(int type, int i1, int i2, int i3, int i4);
JNIEXPORT void inputBridge_addLookDelta(double dx, double dy);
JNIEXPORT void inputBridge_setMenuCursor(double x, double y);
JNIEXPORT void inputBridge_notifyFramePresented(void);
JNIEXPORT void inputBridge_notifyFramePresentedForTargetV1(uint64_t window, uint64_t generation);
JNIEXPORT void inputBridge_cancelMenuTransaction(void* window);
JNIEXPORT void inputBridge_cancelAllState(void* window, int reason);
JNIEXPORT int inputBridge_setInputReady(int ready);
void inputBridge_getWindowSizeSnapshot(int* outWidth, int* outHeight);
void inputBridge_setCursorPosCallback(GLFW_invoke_CursorPos_func cb);
void inputBridge_setMouseButtonCallback(GLFW_invoke_MouseButton_func cb);
void inputBridge_setKeyCallback(GLFW_invoke_Key_func cb);
void inputBridge_setScrollCallback(GLFW_invoke_Scroll_func cb);
void* inputBridge_replaceCharCallback(void* cb);
void* inputBridge_replaceCharModsCallback(void* cb);
void* inputBridge_replaceCursorEnterCallback(void* cb);
void inputBridge_dispatchCursorEnter(void* window, int entered);
void inputBridge_dispatchCharCodepoint(void* window, unsigned int codepoint);
unsigned char* inputBridge_getKeyDownBuffer(void);
unsigned char* inputBridge_getMouseDownBuffer(void);
void inputBridgeStartPumping(void);
void inputBridgePumpEvents(void* window);
void inputBridgeStopPumping(void);
int inputBridge_l2NextEvent(int* outType, int* o1, int* o2, int* o3, int* o4);
// ⭐ LWJGL2 消费者的**显式窗口生命周期边沿**（2026-09-05）。
// 在它之前 LWJGL2 那条 typed 通道**没有任何激活者** —— `1b6087d7` 把
// `amclBackendInputNext` 里的惰性激活兜底换成 `return NOT_READY` 之后，
// ≤1.12 世代的物理键/按钮/滚轮全部静默失效（真机 `AMCL_BACKEND_INACTIVE backend=2
// pulls=2048+`）。SDL3 有 `TypedSetActive`，GLFW3 走自己的 `ensureTypedInputOpen`，
// **只有 LWJGL2 靠那条被删掉的兜底活着**。本函数补上它缺的那一半。
void inputBridge_l2SetActive(int active);
// 来源保留的视角入口：公共加工已在平台层完成，桥只负责一次累计与线程安全快照。
JNIEXPORT void inputBridge_addSourceLookDelta(int32_t source, double dx, double dy);
JNIEXPORT void inputBridge_sdlGetNonPhysicalCursorSnapshot(double* outX, double* outY);
JNIEXPORT void inputBridge_glfwSetActive(void* window, int active);
// legacy ring 不连续 epoch 的强链接 getter（libentry 直接链接；定义见 ring 状态一节）。
JNIEXPORT unsigned long long inputBridge_legacyRingDiscontinuityEpochV1(void);

typedef struct InputBridgeInstanceV1 {
    unsigned int abiVersion;
    unsigned int structSize;

    // 生产侧
    void (*pushEvent)(int type, int i1, int i2, int i3, int i4);
    void (*addLookDelta)(double dx, double dy);
    void (*setMenuCursor)(double x, double y);
    void (*setLookCursor)(double x, double y);
    void (*notifyFramePresented)(void);
    void (*setWindowSize)(int w, int h);

    // 状态查询
    void (*getCursorSnapshot)(double* outX, double* outY);
    void (*getWindowSizeSnapshot)(int* outWidth, int* outHeight);
    bool (*isGrabbing)(void);
    unsigned char* (*getKeyDownBuffer)(void);
    unsigned char* (*getMouseDownBuffer)(void);
    // 单键查询刻意与整表快照分开：`glfwGetKey` 是每帧多次的轮询路径，走整表会变成
    // 每次一趟 512 B memcpy + 一次全局锁。两者都不是公开符号的新增面（见下方 static）。
    int (*getKeyDown)(int key);
    int (*getMouseDown)(int button);

    // 状态转换与生命周期边界
    void (*setGrabState)(int grabbing);
    int (*beginPhysicalMotionTransaction)(int* outGrabbing);
    void (*endPhysicalMotionTransaction)(void);
    void (*cancelMenuTransaction)(void* window);
    void (*cancelAllState)(void* window, int reason);
    void (*setMcExitCallback)(mc_exit_callback_t cb);
    int (*setInputReady)(int ready);

    // 回调注册（GLFW3 的分发出口）
    void (*setCursorPosCallback)(GLFW_invoke_CursorPos_func cb);
    void (*setMouseButtonCallback)(GLFW_invoke_MouseButton_func cb);
    void (*setKeyCallback)(GLFW_invoke_Key_func cb);
    void (*setScrollCallback)(GLFW_invoke_Scroll_func cb);
    void* (*replaceCharCallback)(void* cb);
    void* (*replaceCharModsCallback)(void* cb);
    void* (*replaceCursorEnterCallback)(void* cb);
    void (*dispatchCursorEnter)(void* window, int entered);
    void (*dispatchCharCodepoint)(void* window, unsigned int codepoint);

    // 三个消费者
    void (*startPumping)(void);
    void (*pumpEvents)(void* window);
    void (*stopPumping)(void);
    int (*l2NextEvent)(int* outType, int* o1, int* o2, int* o3, int* o4);
    // ⚠️ **必须进这张表**：typed 通道的 `g_channels[]` 是 backend_input_bridge.cpp 的 TU
    // 静态 ⇒ 每份 image 一套。`l2NextEvent` 转发到 owner 之后 drain 的是 owner 那套，
    // 所以 SetActive 不转发就会激活 MC 那份**永远没人 drain** 的通道。
    void (*l2SetActive)(int active);
    int (*sdlNextEvent)(int* outType, int* o1, int* o2, int* o3, int* o4);
    void (*sdlSetActive)(int active);
    void (*sdlNotifyFramePresented)(void);
    // V1可选尾部，旧前缀布局不变；新SDL通过独立导出取得非物理累计视角。
    void (*addSourceLookDelta)(int32_t source, double dx, double dy);
    void (*sdlGetNonPhysicalCursorSnapshot)(double* outX, double* outY);
    void (*glfwSetActive)(void* window, int active);
    // 可选尾部：owner 的 legacy ring 不连续 epoch（消费侧每次溢出恢复加一）。旧 owner 没有这一项，
    // delegate 据 structSize 判定后返回 0（“没有信息”），libentry 因此不会误做复位。
    unsigned long long (*legacyRingDiscontinuityEpoch)(void);
    // 新尾部显式协商；缺少时只保留旧行为，绝不能在 delegate 本地构造另一把顺序锁。
    void (*pumpOrdered)(void*, InputBridgeOrderedPump, void*, uint64_t);
    uint64_t (*sdlPeekOrder)(void);
    int (*sdlNextThrough)(int*, int*, int*, int*, int*, uint64_t);
    void (*publishMenuCursor)(double, double);
    // 兼容追加尾部：零触点不代表已结束的菜单点击已经消费，退休必须覆盖全部旧菜单槽。
    void (*retireTouchMenuScope)(void);
    // 真实呈现窗口/代次追加入口；旧0身份入口只用于兼容，不覆盖已有精确身份。
    void (*notifyFramePresentedForTarget)(uint64_t, uint64_t);
    // 面板来源必须独立于ordinary账本，才能在触控作用域退休时只撤销LEFT/RIGHT/Shift工具。
    void (*pushTouchMenuTool)(int, int);
    void (*publishTouchMenuCursor)(double, double);
    // SDL独立尾协议：逻辑输入目标/发布代次与实际图形呈现代次分别保留。
    void (*sdlSetTarget)(uint64_t, uint64_t, uint64_t);
    void (*sdlNotifyFramePresentedForTarget)(uint64_t, uint64_t);
    void (*glfwSetTarget)(uint64_t, uint64_t, uint64_t);
    // 只退休面板工具，不撤另一指直接菜单事务；完整touch scope仍同时退休两种epoch。
    void (*retireTouchMenuToolScope)(void);
    void (*publishTouchMenuScroll)(int, int);
    void (*pushTouchMenuToolScroll)(int, int);
    void (*publishTouchMenuToolCursor)(double, double);
    int (*configureMenuCursorConsumer)(uint32_t, uint64_t);
    int (*getCommittedMenuCursor)(AmclCommittedMenuCursorV1*);
    uint64_t (*beginGlfwMenuCursor)(uint64_t, uint64_t, uint64_t, uint64_t, double, double);
    int (*completeGlfwMenuCursor)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, double, double);
    void (*publishTouchMenuToolRelative)(double, double, double, double);
    void (*publishTouchMenuRelative)(int, uint32_t, double, double, double, double);
    // void旧前缀不改；产品wrapper借尾部明确报告actual游戏callback的完成资格。
    void (*setCursorReceiptCallback)(AmclGlfwCursorReceiptCallbackV1);
    // current metadata私有尾部，delegate不能另读本image Core；旧/缺失尾字段返回无current。
    int (*readSurfaceContext)(AmclInputSurfaceContextPayload*);
    // 私有look整组追加尾部。旧V1前缀位置保持；begin/end和线程局部批深度必须归同一个owner，
    // 因此不能逐方法降级。新consumer遇到旧/短/未知版本owner只报告NotReady，不另造本地规则。
    uint32_t lookTransportVersion;
    int (*getLookResource)(AmclLookResourceV1*);
    int (*submitLook)(uint64_t, double, double, uint64_t, uint32_t);
    int (*beginLookAction)(void);
    int (*beginSourceAction)(uint32_t);
    void (*endLookAction)(void);
    void (*setLookPrefixCallback)(AmclLookPrefixCallbackV1);
    int (*submitProcessedLook)(int32_t, double, double);
#if AMCL_INPUT_TRACE
    // 只观察的可选尾：缺席不改变look/输入冷握手，不在delegate本地补另一诊断表。
    uint32_t latencyVersion;
    void (*noteInputLatency)(uint32_t,const AmclInputLatencyV1*);
    void (*finishInputLatency)(uint64_t,uint32_t);
    uint32_t (*drainInputLatency)(AmclInputLatencyV1*,uint32_t,AmclInputLatencyStatsV1*);
    // 独立诊断票尾：旧v1字段/offset不动；短尾/未知版本不降级prefix-only终结。
    uint32_t latencyTicketVersion;
    void (*finishInputLatencyTicket)(const AmclInputLatencyV1*,uint32_t);
#endif
} InputBridgeInstanceV1;

// 可选尾部字段是否存在于 owner 的表里：按该字段自身的结束偏移比较 structSize，而不是整张
// 当前结构的 sizeof —— 否则每追加一个尾部字段，都会让新 delegate 拒绝旧 owner 早已提供的旧字段。
#define INPUT_BRIDGE_OWNER_HAS_TAIL(owner, field)                                   \
    ((owner)->structSize >= (unsigned int)(offsetof(InputBridgeInstanceV1, field) + \
                                           sizeof((owner)->field)) &&               \
     (owner)->field != NULL)

/** 先核最后字段的真实长度，再读版本和整组地址；缺尾部不访问越界字段或采用本地副本。 */
static bool bridgeOwnerHasLookTransportV1(const InputBridgeInstanceV1* owner) {
    return owner && INPUT_BRIDGE_OWNER_HAS_TAIL(owner, submitProcessedLook) &&
        owner->lookTransportVersion == AMCL_LOOK_TRANSPORT_VERSION && owner->getLookResource &&
        owner->submitLook && owner->beginLookAction && owner->beginSourceAction &&
        owner->endLookAction && owner->setLookPrefixCallback;
}

static InputBridgeInstanceV1 g_bridgeInstance;
#if AMCL_INPUT_TRACE
/** 诊断整组只在末字段长度与版本成立后借用；旧/损坏尾不影响lookTransport能力。 */
static bool bridgeOwnerHasLatencyV1(const InputBridgeInstanceV1* owner){
    return owner&&INPUT_BRIDGE_OWNER_HAS_TAIL(owner,drainInputLatency)&&owner->latencyVersion==1&&
        owner->noteInputLatency&&owner->finishInputLatency&&owner->drainInputLatency;
}
static bool bridgeOwnerHasLatencyTicketV1(const InputBridgeInstanceV1* owner){
    return bridgeOwnerHasLatencyV1(owner)&&INPUT_BRIDGE_OWNER_HAS_TAIL(owner,finishInputLatencyTicket)&&
        owner->latencyTicketVersion==1&&owner->finishInputLatencyTicket;
}
#endif

// 0 = 还没解析（**可重试**，见不变量 2）；1 = 本 image 就是 owner；其余 = owner 的表地址。
#define INPUT_BRIDGE_OWNER_UNRESOLVED 0ULL
#define INPUT_BRIDGE_OWNER_SELF 1ULL
static atomic_ullong g_bridgeOwner = 0;
static atomic_bool g_bridgeCallbacksReplayed = false;
static atomic_bool g_bridgeRoleLogged = false;

static void replayLocalCallbacksToOwner(const InputBridgeInstanceV1* owner);

static const InputBridgeInstanceV1* resolveBridgeOwnerSlow(void) {
    unsigned long long address = 0ULL;
    const AmclLegacyBridgeDescriptorStatus status =
        amclLegacyBridgeParseInstanceEnv(
            getenv(AMCL_LEGACY_BRIDGE_INSTANCE_ENV), &address);
    if (status != AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK) {
        if (status != AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT &&
            !atomic_exchange_explicit(&g_bridgeRoleLogged, true,
                                      memory_order_acq_rel)) {
            // 格式坏了与"还没发布"必须分开报（AGENTS.md §二.9）：前者永远不会自愈。
            LOGE("InputBridge instance descriptor rejected status=%{public}d "
                 "(this image keeps its own ring; legacy consumers in it will "
                 "see no host events)", (int)status);
        }
        return NULL;
    }

    // 与发布侧那道 release 栅栏配对：先取到地址，再保证之后读到的是**填满之后**的表。
    atomic_thread_fence(memory_order_acquire);
    const InputBridgeInstanceV1* candidate =
        (const InputBridgeInstanceV1*)(uintptr_t)address;
    if (candidate->abiVersion != AMCL_LEGACY_BRIDGE_INSTANCE_VERSION ||
        candidate->structSize < (unsigned int)offsetof(InputBridgeInstanceV1, addSourceLookDelta) ||
        candidate->pushEvent == NULL || candidate->pumpEvents == NULL) {
        if (!atomic_exchange_explicit(&g_bridgeRoleLogged, true,
                                      memory_order_acq_rel)) {
            LOGE("InputBridge instance table rejected abi=%{public}u "
                 "size=%{public}u (expected abi=%{public}u size=%{public}u)",
                 candidate->abiVersion, candidate->structSize,
                 AMCL_LEGACY_BRIDGE_INSTANCE_VERSION,
                 (unsigned int)sizeof(InputBridgeInstanceV1));
        }
        return NULL;
    }

    if (candidate->pushEvent == &inputBridge_pushEvent) {
        // 同一份 image（单 image 进程，或本 image 就是发布者）。
        atomic_store_explicit(&g_bridgeOwner, INPUT_BRIDGE_OWNER_SELF,
                              memory_order_release);
        if (!atomic_exchange_explicit(&g_bridgeRoleLogged, true,
                                      memory_order_acq_rel)) {
            LOGI("AMCL_INPUTBRIDGE role=owner table=%{public}p",
                 (const void*)candidate);
        }
        return NULL;
    }

    atomic_store_explicit(&g_bridgeOwner, (unsigned long long)(uintptr_t)candidate,
                          memory_order_release);
    if (!atomic_exchange_explicit(&g_bridgeRoleLogged, true,
                                  memory_order_acq_rel)) {
        LOGI("AMCL_INPUTBRIDGE role=delegate table=%{public}p self=%{public}p "
             "(this image forwards every legacy bridge entry point to the "
             "XComponent-owning image)",
             (const void*)candidate,
             (const void*)(uintptr_t)&inputBridge_pushEvent);
    }
    if (!atomic_exchange_explicit(&g_bridgeCallbacksReplayed, true,
                                  memory_order_acq_rel)) {
        replayLocalCallbacksToOwner(candidate);
    }
    return candidate;
}

static const InputBridgeInstanceV1* bridgeDelegate(void) {
    const unsigned long long owner =
        atomic_load_explicit(&g_bridgeOwner, memory_order_acquire);
    if (owner == INPUT_BRIDGE_OWNER_SELF) return NULL;
    if (owner != INPUT_BRIDGE_OWNER_UNRESOLVED) {
        return (const InputBridgeInstanceV1*)(uintptr_t)owner;
    }
    return resolveBridgeOwnerSlow();
}

// ============================================================
//  Global state
// ============================================================

// ==================== 双坐标光标模型 ====================
// g_lookX/Y：grabbed 模式的相对视角累加坐标；菜单绝对坐标绝不写入它。
// g_menuX/Y：normal 模式的菜单绝对指针；视角增量绝不写入它。
//
// v7 不再把这些 double 的地址暴露给 libentry.so。触摸/UI/MC pump 可并发访问，volatile 既不
// 保证原子 double，也不能把 X/Y/grab 组成一致快照；所有坐标与中心重锚都由 g_cursorMutex
// 串行，grab 标志单独用 C11 atomic 发布。调用外部 GLFW callback 前必须先释放此锁，避免回调
// 同步进入 glfwSetInputMode/setCursorPos 时反向自锁。
//
// Minecraft 1.21.11 的 grabMouse() 会先把 MouseHandler.xpos/ypos 设为窗口中心，再依次调用
// glfwSetCursorPos(center) 和 glfwSetInputMode(DISABLED)，并忽略重新抓取后的首个 cursor callback。
// 因此 glfwSetCursorPos 只记录程序请求的中心，menu→grabbed 时 inputBridge_setGrabState() 将
// g_lookX/Y 与 pump 去重基准一起重锚到该中心；之后只有真实 look 增量继续累加。
static pthread_mutex_t g_cursorMutex = PTHREAD_MUTEX_INITIALIZER;
static double g_lookX = 0, g_lookY = 0;
// 非物理来源使用独立的单调累计量，不随鼠标移动取得/丢失所有权。
// SDL物理相对量直接由typed通道投递，因此只差分这份触控/手柄累计值。
static double g_nonPhysicalLookX = 0, g_nonPhysicalLookY = 0;
static double g_menuX = 0, g_menuY = 0;
static double g_cLastX = 0, g_cLastY = 0;          // 上次上报值（仅 pump/同步 grab 线程读写）
static double g_lastSetCursorX = 1400.0, g_lastSetCursorY = 920.0;
static atomic_ullong g_invalidCursorWriteCount = 0;
// ring 里出现了一个 GLFW3 pump 不认识的事件类型的次数（2026-09-01）。
//
// 存在理由：pump 的 `switch` 此前**没有 `default` 分支** —— 任何未知 type（越界值、
// 将来新增却忘了接线的类型、`CallbackBridge.java` 与本文件的常量漂移）都被静默消费掉，
// 零日志零计数。而 typed 平面对同一件事有 `diagnosticDrop` sink + 2 的幂日志，
// 两条平面在"不认识的东西怎么处理"上不对称。
// ⇒ 规范 §八 纪律 5：一个没有观测点的丢弃路径，与"这件事不会发生"在日志里长得一样。
static atomic_ullong g_unknownRingEventCount = 0;

// ==================== 菜单光标必须是**绝对映射**，不允许偏移 ====================
//
// 这一节是一次失败尝试的结论，写下来是为了不再犯。
//
// 桌面 GLFW 在 CURSOR_DISABLED → CURSOR_NORMAL 时会把**系统光标**warp 回它记录的
// virtual cursor position，而 MC 在 grabMouse() 里把那个值设成了窗口中心，所以桌面端
// 每次按 ESC 打开 GUI 光标都从中心出现。诱人的推论是：我们没法 warp 系统指针，那就让
// g_menuX/Y 变成一个"虚拟光标"，与系统指针之间维护一个 warp 偏移。
//
// **这个推论是错的。** 前提缺了一条：菜单模式下 OHOS 的系统指针箭头是**可见的**
// （见 PointerVisibilityCoordinator —— grabbed 才隐藏，菜单必须显示）。桌面端"显示位置"
// 与"逻辑位置"是同一个东西，因为 GLFW 真的移动了那个箭头；我们一旦引入偏移，箭头留在原处
// 而 MC 以为光标在别处，于是**悬浮高亮与点击判定全部落在箭头看不见的地方**。真机实测正是
// 如此，且偏移量等于视角漂移量，可以很大。
//
// 因此：**g_menuX/Y 必须恒等于系统指针的绝对位置**，唯一写法是绝对写入
// （inputBridge_setMenuCursor）。触摸落点也是绝对位置，天然同构。
//
// "按 ESC 回中"在本平台**做不到**，除非满足其中之一：
//   ① 拿到移动系统指针的能力（MouseController.moveTo 属 API 26 inputEventClient，
//      仅 PC/2in1 且需 CONTROL_DEVICE 权限 —— 手机/平板无解，已列入华为提单诉求）；
//   ② 菜单模式改为隐藏系统指针 + 由 ArkTS overlay 自绘一个跟随虚拟光标的光标图标。
//      那时显示与逻辑重新统一，偏移才合法。
// 在两者都没有之前，"光标跟着系统指针箭头"就是唯一正确的行为，哪怕它与桌面端观感不同。

static bool isFirstOrPowerOfTwoUll(unsigned long long count) {
    return count == 1ULL || (count & (count - 1ULL)) == 0ULL;
}

static void recordInvalidCursorWrite(const char* kind) {
    const unsigned long long count = atomic_fetch_add_explicit(
        &g_invalidCursorWriteCount, 1ULL, memory_order_relaxed) + 1ULL;
    if (isFirstOrPowerOfTwoUll(count)) {
        LOGE("InputBridge rejected invalid cursor write kind=%{public}s count=%{public}llu",
             kind, count);
    }
}

// 与上面同一个形状（首次 + 2 的幂限流），刻意不共用函数：那个的日志文案说的是
// "拒绝了一次非法的光标写入"，语义完全不同，共用会让两类问题在日志里无法区分。
// ==================== look 样本的 in→out 时延（2026-09-01）====================
//
// ⭐ **这一段缺了很久，而"它需要跨 DSO"是一个错的判断**（规范 §九 与提案 §十一 都记着
// "需要 bridge 侧与 pump 侧也打时间戳，跨 DSO"）。实际上 **`inputBridge_addLookDelta` 与
// pump 的 cursor 上报都在本 DSO 内** —— 缺的正好是这两点之间那一段，一个 `.so` 就量得完。
// libentry 那一段（漏斗入口 → bridge）的延迟由 `LookPipelineStats` 的 backlog 深度覆盖。
//
// 为什么它重要：提案原话是"**没有埋点不要再调参**"。用户报的"视角有延迟感"在按端关掉平滑
// （τ≈18.2ms）之后仍有剩余，而**复测被这条埋点阻塞** —— 在它之前日志里根本没有"一个位移
// 样本从进 bridge 到被 MC 看见花了多久"这个量。
//
// 判据（三条，缺一条就会误读）：
//   · **只在真的调用了 `g_invoke_CursorPos` 时结算。** 被去重吞掉的样本让 pending 保留到
//     下一次真上报 —— 那正是我们要测的"完整延迟"，而不是"最后一次采样到上报"。
//   · **`g_lookPendingSinceNs` 只由第一个样本置位**（`0 -> now` 的 CAS）。一轮里的后续样本
//     不覆盖它，否则测出来的是"最后一个样本的延迟"，永远接近 0。
//   · **只有 grabbed 那条主上报路径结算**。菜单绝对坐标走 `inputBridge_setMenuCursor`，
//     不经 look 累加器；让它结算会把一个与 look 无关的时刻算成 look 延迟。
static unsigned long long lookMonotonicNowNs(void) {
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
    return (unsigned long long)std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
#else
    struct timespec ts;
    // 失败返回 0，而 0 在下面等于"无待报样本" ⇒ 静默丢掉这次测量。
    // 纯诊断路径，刻意不为它加告警：时钟不可用时 `AMCL_SURFGATE` 那条 error 已经会响。
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0ULL;
    return (unsigned long long)ts.tv_sec * 1000000000ULL +
           (unsigned long long)ts.tv_nsec;
#endif
}

// 最早一个尚未被上报的 look 样本的时刻。0 = 当前没有待报样本。
static atomic_ullong g_lookPendingSinceNs = 0;
static atomic_ullong g_lookLatencySamples = 0;
static atomic_ullong g_lookLatencySumNs = 0;
static atomic_ullong g_lookLatencyMaxNs = 0;
// 上一次打印统计的时刻（节流用，与 census 的 1 秒节流同一个形状）。
static atomic_ullong g_lookLatencyNextLogNs = 0;

// `inputBridge_addLookDelta` 成功累加之后调用。
static void noteLookSampleQueued(void) {
    const unsigned long long now = lookMonotonicNowNs();
    if (now == 0ULL) return;
    unsigned long long expected = 0ULL;
    // 只有第一个样本置位；失败即说明已有更早的待报样本，正是我们要保留的那个。
    (void)atomic_compare_exchange_strong_explicit(
        &g_lookPendingSinceNs, &expected, now,
        memory_order_acq_rel, memory_order_acquire);
}

// pump **真的**把 cursor 交给 MC 之后调用。
static void noteLookSampleReported(void) {
    const unsigned long long since = atomic_exchange_explicit(
        &g_lookPendingSinceNs, 0ULL, memory_order_acq_rel);
    if (since == 0ULL) return;   // 本次上报不是 look 驱动的（例如 grab 重锚后的首帧）
    const unsigned long long now = lookMonotonicNowNs();
    if (now <= since) return;    // 时钟异常或同一纳秒，不污染统计
    const unsigned long long latency = now - since;
    atomic_fetch_add_explicit(&g_lookLatencySamples, 1ULL, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_lookLatencySumNs, latency, memory_order_relaxed);
    unsigned long long worst = atomic_load_explicit(&g_lookLatencyMaxNs,
                                                    memory_order_relaxed);
    while (latency > worst &&
           !atomic_compare_exchange_weak_explicit(
               &g_lookLatencyMaxNs, &worst, latency,
               memory_order_relaxed, memory_order_relaxed)) {}

    // 1 秒节流。⚠️ 打**平均与最大**而不是逐条：逐条会淹没日志，而单条延迟本身没有判读价值
    // （视角是连续量，要看的是分布的两端）。
    const unsigned long long due = atomic_load_explicit(&g_lookLatencyNextLogNs,
                                                        memory_order_relaxed);
    if (due == 0ULL) {
        atomic_store_explicit(&g_lookLatencyNextLogNs, now + 1000000000ULL,
                              memory_order_relaxed);
        return;
    }
    if (now < due) return;
    unsigned long long expectedDue = due;
    if (!atomic_compare_exchange_strong_explicit(
            &g_lookLatencyNextLogNs, &expectedDue, now + 1000000000ULL,
            memory_order_acq_rel, memory_order_relaxed)) {
        return;
    }
    const unsigned long long samples = atomic_load_explicit(
        &g_lookLatencySamples, memory_order_relaxed);
    const unsigned long long sum = atomic_load_explicit(
        &g_lookLatencySumNs, memory_order_relaxed);
    const unsigned long long worstNow = atomic_load_explicit(
        &g_lookLatencyMaxNs, memory_order_relaxed);
    if (samples == 0ULL) return;
    LOGI("AMCL_LOOKLAT bridge->pump samples=%{public}llu avgUs=%{public}llu "
         "maxUs=%{public}llu (in=addLookDelta out=cursorPos callback; "
         "the libentry funnel segment is covered by AMCL_LOOK backlog)",
         samples, (sum / samples) / 1000ULL, worstNow / 1000ULL);
}

static void recordUnknownRingEvent(int type) {
    const unsigned long long count = atomic_fetch_add_explicit(
        &g_unknownRingEventCount, 1ULL, memory_order_relaxed) + 1ULL;
    if (isFirstOrPowerOfTwoUll(count)) {
        LOGE("InputBridge dropped unknown ring event type=%{public}d "
             "count=%{public}llu (GLFW3 pump has no case for it; check the "
             "EVENT_TYPE_* constants against CallbackBridge.java)",
             type, count);
    }
}
static atomic_bool g_isGrabbing = false;

// Physical source-plane classification and the authoritative grab writer share
// this transaction fence. It is distinct from g_cursorMutex because legacy
// routing legitimately enters addLookDelta/setMenuCursor while the mode fence
// is held. The writer publishes its capture callback before releasing the fence,
// so an old-mode event is always committed before that boundary and a new-mode
// event always begins after it.
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
static std::recursive_mutex g_physicalMotionModeMutex;
static bool lockPhysicalMotionMode(void) {
    g_physicalMotionModeMutex.lock();
    return true;
}
static void unlockPhysicalMotionMode(void) {
    g_physicalMotionModeMutex.unlock();
}
static atomic_uint g_testGrabWriterWaiters = 0;
#else
static pthread_mutex_t g_physicalMotionModeMutex;
static pthread_once_t g_physicalMotionModeMutexOnce = PTHREAD_ONCE_INIT;
static atomic_bool g_physicalMotionModeMutexReady = false;

static void initPhysicalMotionModeMutex(void) {
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) != 0) return;
    const int typeResult =
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    const int initResult = typeResult == 0
        ? pthread_mutex_init(&g_physicalMotionModeMutex, &attr) : -1;
    pthread_mutexattr_destroy(&attr);
    if (initResult == 0) {
        atomic_store_explicit(
            &g_physicalMotionModeMutexReady, true, memory_order_release);
    }
}

static bool lockPhysicalMotionMode(void) {
    pthread_once(&g_physicalMotionModeMutexOnce, initPhysicalMotionModeMutex);
    if (!atomic_load_explicit(
            &g_physicalMotionModeMutexReady, memory_order_acquire)) {
        return false;
    }
    return pthread_mutex_lock(&g_physicalMotionModeMutex) == 0;
}

static void unlockPhysicalMotionMode(void) {
    pthread_mutex_unlock(&g_physicalMotionModeMutex);
}
#endif

static void bridgeCursorSnapshot(double* outX, double* outY) {
    pthread_mutex_lock(&g_cursorMutex);
    const bool grabbing = atomic_load_explicit(&g_isGrabbing, memory_order_relaxed);
    *outX = grabbing ? g_lookX : g_menuX;
    *outY = grabbing ? g_lookY : g_menuY;
    pthread_mutex_unlock(&g_cursorMutex);
}

// MC pump 用同一临界区比较并推进去重基准，避免 setGrabState 的中心重锚与 cursor 检查交错。
static bool bridgeTakeCursorChange(double* outX, double* outY) {
    bool changed = false;
    pthread_mutex_lock(&g_cursorMutex);
    const bool grabbing = atomic_load_explicit(&g_isGrabbing, memory_order_relaxed);
    const double x = grabbing ? g_lookX : g_menuX;
    const double y = grabbing ? g_lookY : g_menuY;
    if (g_cLastX != x || g_cLastY != y) {
        g_cLastX = x;
        g_cLastY = y;
        changed = true;
    }
    pthread_mutex_unlock(&g_cursorMutex);
    *outX = x;
    *outY = y;
    return changed;
}

// 三个实际消费者独立持有同一种事务状态；算法共用，实例、线程与呈现政策独立。
static AmclPointerTransaction g_glfwPointer, g_l2Pointer;
static const AmclPointerDeliveryPolicy g_glfwPointerPolicy = {2u, false, false};
static const AmclPointerDeliveryPolicy g_l2PointerPolicy = {0u, false, false};
static const AmclPointerDeliveryPolicy g_sdlPointerPolicy = {1u, true, true};

// 菜单指针事务状态只由 MC pump/setGrabState/glfwDestroyWindow 所在线程修改。i4 不再是可复用
// finger id，而是 libentry 分配的单调 transaction token；旧 UP/CANCEL 无权结束新 DOWN。
// DOWN 所在 pump 只提交 cursor；PRESS 必须保持 presentSerial+2，确保 1.21.11 的
// poll → swap → poll 与下一帧 accumulated movement 消费完整跨越。后续 MOVE/UP 仍停在
// 原有序队列中，准入后先源点 PRESS，再按原序交付按住区间与终点 RELEASE。
static unsigned long long g_presentSerial = 0;
static void* g_lastPumpWindow = NULL;
// 延期边沿仍属于原入队动作，不能借最新全局坐标或新的公共顺序重新解释。
// pending 屏障期间不消费后续普通/typed事件，坐标、目标和退出权限一起冻结。
static void* g_menuTargetWindow = NULL;
static uint64_t g_glfwPresentedWindow = 0, g_glfwPresentedGeneration = 0;
static uint64_t g_menuPresentedWindow = 0, g_menuPresentedGeneration = 0;
static uint64_t g_glfwPresentedIdentity = 0, g_menuPresentedIdentity = 0;
// Vulkan present可以来自另一线程。sink只写此成对快照，consumer plain状态及pending只在pump线程读写。
// 此锁不与push/down/cursor同时持有，也不调用任何Native/游戏出口。
typedef struct {
    uint64_t serial;
    uint64_t window, generation, identity;
    uint64_t targetWindow, wsiIdentity;
    bool targetRequired;
} GlfwPresentationClock;
static pthread_mutex_t g_glfwPresentationMutex = PTHREAD_MUTEX_INITIALIZER;
static GlfwPresentationClock g_glfwPresentationClock;

/** 将实际呈现快照复制到consumer线程；首次render identity认领也在此线程完成。 */
static void refreshGlfwPresentationState(void) {
    pthread_mutex_lock(&g_glfwPresentationMutex);
    g_presentSerial = g_glfwPresentationClock.serial;
    g_glfwPresentedWindow = g_glfwPresentationClock.window;
    g_glfwPresentedGeneration = g_glfwPresentationClock.generation;
    g_glfwPresentedIdentity = g_glfwPresentationClock.identity;
    pthread_mutex_unlock(&g_glfwPresentationMutex);
    if (g_glfwPointer.token != 0 && g_menuPresentedGeneration == 0 &&
        g_glfwPresentedWindow == g_menuPresentedWindow && g_glfwPresentedGeneration != 0) {
        g_menuPresentedGeneration = g_glfwPresentedGeneration;
        g_menuPresentedIdentity = g_glfwPresentedIdentity;
    }
}

/** 激活/完整窗口边界只重置已观测身份，计数保持单调；target映射由其独立setter发布。 */
static void resetGlfwPresentationIdentity(void) {
    pthread_mutex_lock(&g_glfwPresentationMutex);
    g_glfwPresentationClock.window = g_glfwPresentationClock.generation = g_glfwPresentationClock.identity = 0;
    pthread_mutex_unlock(&g_glfwPresentationMutex);
    g_glfwPresentedWindow = g_glfwPresentedGeneration = g_glfwPresentedIdentity = 0;
}
static atomic_ullong g_touchMenuScopeEpoch = 1ULL;
static atomic_ullong g_touchMenuToolScopeEpoch = 1ULL;
static uint64_t g_gestureTokenEpoch[4];
static uint32_t g_gestureTokenHigh[4];
// 图形暂停时撤销尚未提交的动作，不绕过真实 present 保护制造恢复后的迟到点击。
// 时钟只负责失效上限，不替代 +2/+1 的准入；已提交且仍贴屏的拖动不因这个上限退休。
#define MENU_PENDING_TIMEOUT_NS 500000000ULL
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
static uint64_t g_menuTestNowNs = 0;
JNIEXPORT void inputBridge_testSetMenuNowNs(uint64_t now) { g_menuTestNowNs = now; }
#endif
static uint64_t menuMonotonicNowNs(void) {
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
    if (g_menuTestNowNs != 0) return g_menuTestNowNs;
#endif
    return lookMonotonicNowNs();
}
static bool menuPendingExpired(uint64_t since) {
    const uint64_t now = menuMonotonicNowNs();
    return since == 0 || now == 0 || (now >= since && now - since >= MENU_PENDING_TIMEOUT_NS);
}

// Window/surface snapshot. XComponent publishes dimensions through env because it lives in libentry.so;
// glfw_compat is the single importer and commits each accepted pair here on the MC thread. The mutex keeps
// width/height in one epoch for future paired consumers and removes the old volatile data race with JNI reads.
// Do not make XComponent and CallbackBridge independent authoritative writers again: JNI compatibility input
// is routed through inputBridge_setWindowSize(), and GLFW's accepted surface pair wins on create/resize.
static pthread_mutex_t g_windowSizeMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_windowWidth = 1280;
static int g_windowHeight = 720;
static volatile bool g_shouldUpdateMouse = false;
// 只在neutral运输TU存在；TLS深度允许一个ledger批产生多个边沿，禁止嵌套取得push锁。
static _Thread_local unsigned g_lookActionDepth = 0;
// Source显式携原keygen的临时运输参数；只包围一次已预留slot复制，不是新的持有状态。
static _Thread_local bool g_explicitKeyScope=false;
static _Thread_local uint64_t g_originalKeyScope=0;
static atomic_ullong g_lookModeEpoch = 1;
static AmclLookPrefixCallbackV1 g_lookPrefixCallback = NULL;
// 显式NULL也是一次注册事实，晚到owner必须收到退休，而不是回放此前非空callback。
static bool g_lookPrefixCallbackRegistered = false;
static unsigned long long g_lookReclaimedSequence = 0;

// Input ready flag is a JNI lifecycle handshake; nativeSetInputReady may be called from a Java thread while
// launcher/session code observes transitions through the callback, so publish it atomically.
static atomic_bool g_inputReady = false;

// Event ring：多生产者在 g_pushMutex 下分配单调 sequence；consumer 也在同一锁下验证并复制
// 普通 event 字段，防止 producer 绕环覆盖时与复制发生 C 数据竞争。LWJGL3、LWJGL2 与 SDL
// 各有独立读 sequence，不能再用一个 pending counter：
// LWJGL2-only 模式不会调用 StopPumping，旧 counter 会无限增长并在 target 只减一次时越界。
//
// producer 允许覆盖最老槽以保持输入线程非阻塞，但会为已激活且落后一圈的 consumer 设置
// overflowPending。consumer 在 MC 线程统一 recovery：跳到最新 write sequence、清全部 down buffer、
// 结束菜单 transaction，并向已注册 GLFW callback 发 RELEASE。宁可丢一整批旧输入，也不能只丢
// RELEASE 后留下永久按键。日志只在 recovery 时输出，避免卡顿期间刷屏。
typedef struct {
    int phase;
    uint32_t token;
    double maxX, maxY;
} MenuRelativeMetadata;
typedef struct {
    bool left, right, shift;
    bool ordinaryRight, ordinaryShift;
    uint64_t epoch;
    // 生产镜像保留首次acquire槽序号+1，SDL局部target切换后旧held不能借新overflow快照复活。
    unsigned long long leftAcquired, rightAcquired, shiftAcquired;
} LegacyMenuToolState;
static LegacyMenuToolState g_producerMenuTool, g_l3MenuTool, g_l2MenuTool, g_sdlMenuTool;
static atomic_ullong g_sdlInputTargetEpoch = 1ULL;
static atomic_ullong g_sdlMenuTargetCutoff = 0ULL;
static uint64_t g_sdlInputTargetWindow = 0, g_sdlInputTargetGeneration = 0;
static uint64_t g_sdlWsiPresentationIdentity = 0;
static bool g_sdlTargetIdentityRequired = false;
static atomic_ullong g_l3InputTargetEpoch = 1ULL;
static atomic_ullong g_l3MenuTargetCutoff = 0ULL;
static uint64_t g_l3InputTargetWindow = 0, g_l3InputTargetGeneration = 0;
static uint64_t g_l3WsiPresentationIdentity = 0;
static bool g_l3TargetIdentityRequired = false;
typedef struct {
    atomic_ullong publishedSequence; // 0=未发布；值为 event sequence + 1，避免初始 0 歧义
    GLFWInputEvent event;
    uint64_t interactionOrder; // 与 typed core 共用 owner 分配器，发布后不可改写
    uint64_t menuScopeEpoch; // 所有槽都冻结作用域；仅 MENU_POINTER 读取，拒绝退休前的旧输入
    uint64_t toolScopeEpoch; // 工具CANCEL独立作用域，只有1011读取，不伤直接菜单及普通来源
    uint64_t l2KeyboardScope; // 接受时原Keyboard资源，仅L2 key/char读取，标准五int不扩
    uint32_t gestureToken; // BEGIN到END/Cancel全手势，包括无LEFT阶段的位置/滚轮
    MenuRelativeMetadata relative; // private相对命令的冻结phase/token/窗口边界，四int仍只装dx/dy
} GLFWInputSlot;

static GLFWInputSlot g_events[EVENT_WINDOW_SIZE];
static pthread_mutex_t g_pushMutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_ullong g_writeSequence = 0;
static atomic_ullong g_l3ReadSequence = 0;
static atomic_ullong g_l2ReadSequence = 0;
static atomic_ullong g_sdlReadSequence = 0;
// ordinary生产镜像与ring槽在同一g_pushMutex内提交。只保存当前aggregate持有，
// 不保存历史动作、菜单pending或typed；REPEAT不能制造owner，PRESS保留实际scan/mods。
typedef struct {
    // 普通schema键码包含512；polling旧ABI另有512槽边界，不能因此丢失合法回调/5int边沿。
    GLFWInputEvent keys[513];
    uint64_t keyScopes[513]; // 与同一已接受的PRESS同步保存，overflow不能补新current
    GLFWInputEvent buttons[16];
} LegacyOrdinarySnapshot;
typedef struct {
    LegacyOrdinarySnapshot held;
    unsigned nextKey;
    unsigned nextButton;
    bool pending;
    unsigned long long cutoff;
    uint64_t interactionOrder;
    LegacyMenuToolState tool;
    unsigned nextTool;
    uint64_t toolTargetEpoch;
} LegacyRecoveryBaseline;
static LegacyOrdinarySnapshot g_producerOrdinary;
static uint32_t g_producerMenuGestureToken = 0; // 仅producer锁内更新，Scroll在同锁冻结当时的token
static LegacyRecoveryBaseline g_l3Baseline;
static LegacyRecoveryBaseline g_l2Baseline;
static LegacyRecoveryBaseline g_sdlBaseline;

/** 仅持producer锁调用；快照与跳过历史的cutoff属于同一个原子发布边界。 */
static void captureRecoveryBaselineLocked(LegacyRecoveryBaseline* baseline,
                                         atomic_ullong* cursor, atomic_bool* overflow) {
    baseline->held = g_producerOrdinary;
    baseline->nextKey = baseline->nextButton = 0;
    baseline->tool = g_producerMenuTool;
    baseline->nextTool = 0;
    // L2的真实呈现provider也是GLFW窗口；它不能借SDL target epoch恢复已退休工具。
    baseline->toolTargetEpoch = atomic_load_explicit(baseline == &g_sdlBaseline ?
        &g_sdlInputTargetEpoch : &g_l3InputTargetEpoch, memory_order_relaxed);
    baseline->pending = true;
    baseline->cutoff = atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
    // 调用方先持公共order batch再持producer锁，因此该fence与快照/cutoff严格同一发布点。
    baseline->interactionOrder = amclInputInteractionFence();
    atomic_store_explicit(cursor, baseline->cutoff, memory_order_release);
    atomic_store_explicit(overflow, false, memory_order_release);
}

/** RESET是局部控制项；普通held基线绑定capture fence，早于cutoff后ring，每次只交付一条。 */
static uint64_t recoveryBaselineOrder(LegacyRecoveryBaseline* baseline) {
    pthread_mutex_lock(&g_pushMutex);
    const uint64_t order = baseline->pending ? baseline->interactionOrder : UINT64_MAX;
    pthread_mutex_unlock(&g_pushMutex);
    return order;
}
static bool takeRecoveryBaselineEvent(LegacyRecoveryBaseline* baseline, GLFWInputEvent* event) {
    bool found = false;
    pthread_mutex_lock(&g_pushMutex);
    if (baseline->pending) {
        while (baseline->nextKey < 513 && !found) {
            const GLFWInputEvent value = baseline->held.keys[baseline->nextKey++];
            if (value.type != 0) { *event = value; found = true; }
        }
        while (baseline->nextKey == 513 && baseline->nextButton < 16 && !found) {
            const GLFWInputEvent value = baseline->held.buttons[baseline->nextButton++];
            if (value.type != 0) { *event = value; found = true; }
        }
        // 工具镜像与ordinary同cutoff绑定，但过期作用域不能在恢复后重新按下。
        while (!found && baseline->nextKey == 513 && baseline->nextButton == 16 && baseline->nextTool < 3) {
            const unsigned tool = baseline->nextTool++;
            if (baseline->tool.epoch != atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire)) continue;
            if (baseline == &g_sdlBaseline && baseline->toolTargetEpoch !=
                atomic_load_explicit(&g_sdlInputTargetEpoch, memory_order_acquire)) continue;
            if ((baseline == &g_l3Baseline || baseline == &g_l2Baseline) && baseline->toolTargetEpoch !=
                atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire)) continue;
            const bool held = tool == 0 ? baseline->tool.left : tool == 1 ? baseline->tool.right : baseline->tool.shift;
            const unsigned long long acquired = tool == 0 ? baseline->tool.leftAcquired :
                tool == 1 ? baseline->tool.rightAcquired : baseline->tool.shiftAcquired;
            if (baseline == &g_sdlBaseline && acquired <=
                atomic_load_explicit(&g_sdlMenuTargetCutoff, memory_order_acquire)) continue;
            if ((baseline == &g_l3Baseline || baseline == &g_l2Baseline) && acquired <=
                atomic_load_explicit(&g_l3MenuTargetCutoff, memory_order_acquire)) continue;
            if (held) {
                memset(event, 0, sizeof(*event));
                event->type = EVENT_TYPE_TOUCH_MENU_TOOL;
                event->i1 = tool == 0 ? -1 : tool == 1 ? -2 : 340;
                event->i2 = GLFW_PRESS;
                found = true;
            }
        }
        if (!found) baseline->pending = false;
    }
    pthread_mutex_unlock(&g_pushMutex);
    return found;
}
static unsigned long long g_l3TargetSequence = 0; // StartPumping 快照，仅 MC pump 线程读写
static atomic_bool g_l3Active = false;
// 旧JNI调用仍可由Start首次激活；现役GLFW显式声明资格后，pump不能自行重新开门。
static atomic_bool g_l3ExplicitActivation = false;
// 激活代次是回调重入栅栏。Hide→Show可能在同一个Minecraft回调里完成，最终active
// 仍为true，因此不能只检查布尔值；旧pump也绝不能把自己的游标写回新代次。
static atomic_ullong g_l3ActivationGeneration = 1ULL;

static bool l3ActivationMatches(unsigned long long generation) {
    return atomic_load_explicit(&g_l3ActivationGeneration, memory_order_acquire) == generation;
}
static atomic_bool g_l2Active = false;
static atomic_bool g_sdlActive = false;
static atomic_bool g_l3OverflowPending = false;
static atomic_bool g_l2OverflowPending = false;
static atomic_bool g_sdlOverflowPending = false;
static atomic_ullong g_overflowDropCount = 0;
static atomic_ullong g_sdlOverflowDropCount = 0;
// 全生产不连续epoch保留旧恢复合同：不能绑定完整ordinary快照的恢复才通知libentry按自身锁序归零。
// 正常单consumer overflow使用本consumer的生产镜像/cutoff基线，不推进此epoch，
// 否则下一次producer入口会releaseAll并误松仍活跃的兄弟。生产者检测仍只置overflow标志。
// 刻意不计：inputBridge_cancelAllState（它先同步调用 libentry 的完整 cancel）与各消费者
// SetActive 的对齐（局部资格变化不得清兄弟消费者仍在使用的持有，规范 §0.3）。
static atomic_ullong g_legacyRingDiscontinuityEpoch = 0;

// 仅真实全生产不连续/无法重建的恢复使用；局部consumer基线不调用。
static void noteLegacyRingDiscontinuity(void) {
    atomic_fetch_add_explicit(&g_legacyRingDiscontinuityEpoch, 1ULL,
                              memory_order_release);
}

// 无锁 getter，任意线程可调用（libentry 在 NAPI / 触摸入口与 250ms 心跳里读）。delegate 转发到
// owner：真正丢历史的是 owner 的 ring；旧 owner 的表没有这一项时返回 0，即“没有信息”。
JNIEXPORT unsigned long long inputBridge_legacyRingDiscontinuityEpochV1(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, legacyRingDiscontinuityEpoch)
            ? owner->legacyRingDiscontinuityEpoch() : 0ULL;
    }
    return atomic_load_explicit(&g_legacyRingDiscontinuityEpoch,
                                memory_order_acquire);
}
static bool g_l3RecoveryPending = false; // 仅 MC pump 线程
// Window recreate 与 overflow 都必须通知 LWJGL2 Java 清它自己的 polling arrays。该标志只表达
// “返回一次 1009 reset”，不承载普通输入，因此可安全合并多次边界。
static atomic_bool g_l2ResetPending = false;
// 每个consumer的legacy LEFT是ordinary账本出口与已commit菜单token的并集。
// pending菜单没有贡献，不能提前吞掉面板PRESS。函数只计算边沿，不在状态锁内调用游戏。
typedef struct {
    bool ordinaryLeftHeld;
    bool committedMenuActive;
    bool toolLeftHeld;
} LegacyLeftContribution;
static LegacyLeftContribution g_l3LeftContribution;
static LegacyLeftContribution g_l2LeftContribution;
static bool legacyLeftHeld(const LegacyLeftContribution* state) {
    return state->ordinaryLeftHeld || state->committedMenuActive || state->toolLeftHeld;
}
static int setLegacyLeftContribution(LegacyLeftContribution* state, bool menu, bool held) {
    const bool before = legacyLeftHeld(state);
    if (menu) state->committedMenuActive = held;
    else state->ordinaryLeftHeld = held;
    const bool after = legacyLeftHeld(state);
    return before == after ? -1 : after ? GLFW_PRESS : GLFW_RELEASE;
}

/** 末级仅合并来源贡献，不改生产ledger。工具只允许固定三控件；ordinary与tool分别持有。
 * 调用方持自己的consumer状态锁，函数只更新状态/重写载荷，不执行任何回调。
 */
static bool applyMenuToolEvent(LegacyLeftContribution* left, LegacyMenuToolState* tool,
                              GLFWInputEvent* event, bool fromTool, uint64_t epoch) {
    const bool key = fromTool ? event->i1 == 340 : event->type == EVENT_TYPE_KEY;
    const int code = event->i1;
    if (fromTool && code != -1 && code != -2 && code != 340) return false;
    const int action = fromTool ? event->i2 : key ? event->i3 : event->i2;
    if (!fromTool && key && code == 340 && action == 2) return tool->ordinaryShift;
    if (action != GLFW_PRESS && action != GLFW_RELEASE) return false;
    const bool held = action == GLFW_PRESS;
    bool before = false, after = false;
    if (fromTool && epoch != atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire)) return false;
    if (fromTool) tool->epoch = epoch;
    if ((!fromTool && !key && code == GLFW_MOUSE_BUTTON_LEFT) || (fromTool && code == -1)) {
        before = legacyLeftHeld(left);
        if (fromTool) { tool->left = held; left->toolLeftHeld = held; }
        else left->ordinaryLeftHeld = held;
        after = legacyLeftHeld(left);
    } else if ((!fromTool && !key && code == GLFW_MOUSE_BUTTON_RIGHT) || (fromTool && code == -2)) {
        before = tool->ordinaryRight || tool->right;
        if (fromTool) tool->right = held;
        else tool->ordinaryRight = held;
        after = tool->ordinaryRight || tool->right;
    } else if (key && code == 340) {
        before = tool->ordinaryShift || tool->shift;
        if (fromTool) tool->shift = held;
        else tool->ordinaryShift = held;
        after = tool->ordinaryShift || tool->shift;
    } else return false;
    if (before == after) return false;
    if (fromTool) memset(event, 0, sizeof(*event));
    event->type = key ? EVENT_TYPE_KEY : EVENT_TYPE_MOUSE_BUTTON;
    event->i1 = key ? 340 : code == -1 || code == GLFW_MOUSE_BUTTON_LEFT ? GLFW_MOUSE_BUTTON_LEFT : GLFW_MOUSE_BUTTON_RIGHT;
    if (key) event->i3 = after ? GLFW_PRESS : GLFW_RELEASE;
    else event->i2 = after ? GLFW_PRESS : GLFW_RELEASE;
    return true;
}

/** 一次只退休一个工具出口，拉取型消费者可逐条交付，保留other-plane和ordinary。 */
static bool retireMenuToolEvent(LegacyLeftContribution* left, LegacyMenuToolState* tool,
                               GLFWInputEvent* event) {
    const uint64_t current = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire);
    if (tool->epoch == current) return false;
    for (int i = 0; i < 3; ++i) {
        if (!(i == 0 ? tool->left : i == 1 ? tool->right : tool->shift)) continue;
        memset(event, 0, sizeof(*event));
        event->type = EVENT_TYPE_TOUCH_MENU_TOOL;
        event->i1 = i == 0 ? -1 : i == 1 ? -2 : 340;
        event->i2 = GLFW_RELEASE;
        if (applyMenuToolEvent(left, tool, event, true, current)) {
            // 还有其它未退休工具时仍保留旧epoch，下次拉取继续精确释放。
            if (tool->left || tool->right || tool->shift) tool->epoch = current - 1ULL;
            return true;
        }
        tool->epoch = current - 1ULL;
    }
    tool->epoch = current;
    return false;
}
// L2即时有序消费中新DOWN替换旧token可能形成RELEASE→PRESS。第二条只留到下一次拉取，
// 保持同一事务顺序；窗口/activation/reset会同时丢弃旧目标的待发边沿。
static int g_l2FinalLeftPending = -1;
static pthread_mutex_t g_downMutex = PTHREAD_MUTEX_INITIALIZER;

/** grab只安排L2菜单贡献退休，实际边沿由L2拉取线程交付，ordinary/carry保持。 */
static void cancelL2MenuTransaction(void) {
    pthread_mutex_lock(&g_downMutex);
    const bool unreportedPress = g_l2FinalLeftPending == GLFW_PRESS;
    (void)amclPointerRetire(&g_l2Pointer);
    const int action = setLegacyLeftContribution(&g_l2LeftContribution, true, false);
    // pull 的第二条边沿还没领取时允许取消；已领取的首按只结束本接触贡献。
    if (unreportedPress) g_l2FinalLeftPending = -1;
    else if (action >= 0) g_l2FinalLeftPending = action;
    pthread_mutex_unlock(&g_downMutex);
}
static atomic_bool g_sdlResetPending = false;

// SDL3 菜单触摸拥有自己的消费状态，不能复用 GLFW 的 g_presentSerial：26.3+ 不调用
// glfwSwapBuffers，复用它会让 pending press 永远无法提交。该状态只描述 SDL 专属消费游标
// 已经接受的 MENU_POINTER 事务；producer ring、GLFW3 和 LWJGL2 的语义均不受影响。
//
// 2026-08-26 的故障根因也记录在这里：旧实现于 sdlNextEvent 消费 DOWN 时先改 g_menuX/Y，
// 随即在同一次调用返回 PRESS；但 SDL OpenHarmony pump 已经在调用 NextEvent 之前读过 cursor
// snapshot，于是 Minecraft 先收到旧坐标上的 PRESS，下一次 pump 才收到新坐标的 MOTION。
// 表现就是“第一次只把虚拟鼠标移过去，第二次才点中”。现在 DOWN 只提交坐标并锁存 PRESS；
// SDL backend 在同一 pump 末尾再次读取 cursor，从而先投递 MOTION。只有一次成功的 SDL
// present 之后，下一轮 NextEvent 才允许返回 PRESS，保证 Minecraft 在 Screen 仍打开时消费
// menu movement，避免修点击的同时恢复历史上的关闭菜单后视角跳变。
typedef struct {
    // 与 GLFW/L2 完全相同的私有事务，只把 SDL 实际呈现快照与来源并集留在适配边缘。
    AmclPointerTransaction pointer;
    unsigned long long presentSerial;
    uint64_t presentedWindow, presentedGeneration;
    uint64_t targetPresentedWindow, targetPresentedGeneration;
    uint64_t presentedIdentity, targetPresentedIdentity;
    LegacyLeftContribution left;
} SDLMenuPointerState;

static pthread_mutex_t g_sdlMenuMutex = PTHREAD_MUTEX_INITIALIZER;
static SDLMenuPointerState g_sdlMenuState;

// ACK按实际consumer隔离。GLFW provider即使同时poll，也不能改L2已领取的坐标和Native相对基线。
typedef struct {
    bool active;
    uint64_t target, publication, activation, wsiIdentity;
    uint64_t menuScopeEpoch; // authority绑定的scope，不在callback返回后把旧cookie改贴新epoch
    double currentX, currentY;
    bool currentInitialized;
    AmclCommittedMenuCursorV1 committed;
} MenuCursorAuthority;
static pthread_mutex_t g_menuCursorSnapshotMutex = PTHREAD_MUTEX_INITIALIZER;
static MenuCursorAuthority g_menuCursorAuthorities[4];
static uint64_t g_menuCursorSelectedPid = 0, g_menuCursorSelectedSession = 0;
static uint32_t g_menuCursorSelectedBackend = 0;

/** ACK PID不混用平台CRT接口；Windows宿主用_getpid，OHOS继续POSIX getpid。 */
static uint64_t menuCursorProcessId(void) {
#if defined(_WIN32)
    return (uint64_t)_getpid();
#else
    return (uint64_t)getpid();
#endif
}

/** 生命周期/reset保持目标事实，但使旧领取点无资格；调用者不与其它锁同时持有snapshot锁。 */
static void resetCommittedMenuCursor(uint32_t backend, bool active) {
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
    authority->active = active;
    ++authority->activation;
    authority->menuScopeEpoch = atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire);
    memset(&authority->committed, 0, sizeof(authority->committed));
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** 完整touch scope退休后的ACK栅栏。caller已释放order/producer锁；不反入Native、不执行游戏。
 * current是实际consumer的鼠标位置，必须保留给新相对指令累加；ACK与旧callback cookie一起失效。
 * getter/commit另核绑定scope，因此epoch先推进、这里尚未取得锁的短间隙也没有伪造新ACK的资格。
 */
static void retireCommittedMenuCursorScope(void) {
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    const uint64_t scope = atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire);
    for (uint32_t backend = 1; backend <= 3; ++backend) {
        MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
        ++authority->activation;
        authority->menuScopeEpoch = scope;
        memset(&authority->committed, 0, sizeof(authority->committed));
    }
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** 目标的真实identity由消费者本线程发布；同一目标重发幂等，几何/换窗不能继承旧ACK。 */
static void targetCommittedMenuCursor(uint32_t backend, uint64_t target, uint64_t publication, uint64_t wsiIdentity) {
    double initialX = 0.0, initialY = 0.0;
    // 激活时沿用本进程既有菜单ABI的初始数值，只建立current基线，绝不把它标成已回调ACK。
    bridgeCursorSnapshot(&initialX, &initialY);
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
    if (authority->target != target || authority->publication != publication || authority->wsiIdentity != wsiIdentity) {
        if (authority->target != target || !authority->currentInitialized) {
            authority->currentX = initialX; authority->currentY = initialY;
            authority->currentInitialized = target != 0;
        }
        authority->target = target;
        authority->publication = publication;
        authority->wsiIdentity = wsiIdentity;
        ++authority->activation;
        authority->menuScopeEpoch = atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire);
        memset(&authority->committed, 0, sizeof(authority->committed));
    }
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** 实际不可撤回出口的成对提交点，所有字段同锁冻结；低层setMenuCursor/生产desired不调用它。 */
static uint64_t committedMenuCursorActivation(uint32_t backend) {
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    const uint64_t activation = g_menuCursorAuthorities[backend].activation;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    return activation;
}
static void commitMenuCursor(uint32_t backend, double x, double y, uint64_t order, uint64_t activation) {
    if (!isfinite(x) || !isfinite(y) || atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) return;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
    if (authority->active && authority->target != 0 && authority->publication != 0 &&
        authority->activation == activation &&
        authority->menuScopeEpoch == atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) &&
        g_menuCursorSelectedPid == menuCursorProcessId() && g_menuCursorSelectedSession != 0) {
        authority->currentX = x; authority->currentY = y; authority->currentInitialized = true;
        AmclCommittedMenuCursorV1* point = &authority->committed;
        memset(point, 0, sizeof(*point));
        point->structSize = sizeof(*point); point->abiVersion = AMCL_MENU_CURSOR_SNAPSHOT_VERSION;
        point->backend = backend; point->flags = AMCL_MENU_CURSOR_COMMITTED;
        point->processId = g_menuCursorSelectedPid; point->gameSession = g_menuCursorSelectedSession;
        point->logicalTarget = authority->target; point->inputPublication = authority->publication;
        point->activationEpoch = authority->activation; point->interactionOrder = order;
        point->menuScopeEpoch = authority->menuScopeEpoch;
        point->x = x; point->y = y;
    }
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** current是consumer自己的鼠标状态；不是ACK，callback前允许更新而不给Native作已消费重锚。 */
static void updateCurrentMenuCursor(uint32_t backend, double x, double y) {
    if (!isfinite(x) || !isfinite(y)) return;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    g_menuCursorAuthorities[backend].currentX = x;
    g_menuCursorAuthorities[backend].currentY = y;
    g_menuCursorAuthorities[backend].currentInitialized = true;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** typed实际sink的前半段，不执行callback；普通legacy位置也在callback之前更新自己的current。 */
JNIEXPORT uint64_t inputBridge_beginGlfwMenuCursorV1(uint64_t target, uint64_t publication,
        uint64_t wsiIdentity, uint64_t order, double x, double y) {
    (void)order; // ACK order仅在complete冻结；begin只提交当前point，不能提前声称已消费。
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, beginGlfwMenuCursor)
        ? owner->beginGlfwMenuCursor(target, publication, wsiIdentity, order, x, y) : 0;
    if (!isfinite(x) || !isfinite(y) || atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) return 0;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    MenuCursorAuthority* authority = &g_menuCursorAuthorities[1];
    const uint64_t cookie = authority->active && target != 0 && authority->target == target &&
        authority->publication == publication && authority->wsiIdentity == wsiIdentity &&
        authority->menuScopeEpoch == atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) &&
        g_menuCursorSelectedBackend == 1 && g_menuCursorSelectedSession != 0 &&
        g_menuCursorSelectedPid == menuCursorProcessId() ? authority->activation : 0;
    if (cookie) { authority->currentX = x; authority->currentY = y; authority->currentInitialized = true; }
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    if (cookie) inputBridge_setMenuCursor(x, y); // 同步旧GLFW getter的B；这一步不发布ACK。
    return cookie;
}

/** callback返回后重新核冻结tuple/activation，不能把旧点绑定到Hide→Show或新surface。 */
JNIEXPORT int inputBridge_completeGlfwMenuCursorV1(uint64_t target, uint64_t publication,
        uint64_t wsiIdentity, uint64_t cookie, uint64_t order, double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, completeGlfwMenuCursor)
        ? owner->completeGlfwMenuCursor(target, publication, wsiIdentity, cookie, order, x, y) : 0;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    const MenuCursorAuthority* authority = &g_menuCursorAuthorities[1];
    const bool valid = cookie != 0 && authority->active && authority->activation == cookie &&
        authority->menuScopeEpoch == atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) &&
        authority->target == target && authority->publication == publication && authority->wsiIdentity == wsiIdentity;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    if (!valid) return 0;
    commitMenuCursor(1, x, y, order, cookie);
    return atomic_load_explicit(&g_isGrabbing, memory_order_acquire) ? 0 : 1;
}

/** 本局选择只来自entry已核冻结InputPlan的实际ABI/session；同PID换局拒绝，
 * fork后不认父ACK。诊断只借这次成功选择，不能反向改变原输入准备结果。 */
JNIEXPORT int inputBridge_configureMenuCursorConsumerV1(uint32_t backend, uint64_t gameSession) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, configureMenuCursorConsumer)
        ? owner->configureMenuCursorConsumer(backend, gameSession) : 0;
    if (backend < 1 || backend > 3 || gameSession == 0) return 0;
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
    if(!look||look->bindSession(gameSession)<0||look->publishMode(gameSession,
        atomic_load_explicit(&g_lookModeEpoch,memory_order_acquire),
        atomic_load_explicit(&g_isGrabbing,memory_order_acquire)?1u:0u)<0)return 0;
    const uint64_t currentPid = menuCursorProcessId();
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    // 原冻结计划已核身份；共同控制owner只接受同一进程的本局session，不在producer/pump重建。
    if (amclControlDeliveryBindSessionV1(gameSession) < 0) return 0;
#endif
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    int accepted = 0;
    if (g_menuCursorSelectedPid != currentPid || g_menuCursorSelectedSession == 0) {
        g_menuCursorSelectedPid = currentPid;
        g_menuCursorSelectedBackend = backend;
        g_menuCursorSelectedSession = gameSession;
        for (uint32_t i = 1; i <= 3; ++i) memset(&g_menuCursorAuthorities[i].committed, 0,
                                                   sizeof(g_menuCursorAuthorities[i].committed));
        accepted = 1;
    } else if (g_menuCursorSelectedBackend == backend && g_menuCursorSelectedSession == gameSession) accepted = 1;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    if(accepted){
        amclInputOwnerSelectKeyboardBackendV1(backend);
#if AMCL_INPUT_TRACE
        amclInputLatencyConfigureBackendV2(backend,gameSession);
#endif
    }
    return accepted;
}

/** Native只读取当前实际选定consumer的有效领取点；缺ACK返回0并清字段，绝不读取shared latest伪造。 */
JNIEXPORT int inputBridge_getCommittedMenuCursorV1(AmclCommittedMenuCursorV1* out) {
    if (!out || out->structSize < sizeof(*out)) return 0;
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, getCommittedMenuCursor)) return owner->getCommittedMenuCursor(out);
        // 旧owner缺尾能力同样必须清无效前缀，不能把调用者上一份ACK字段留作可误读的成功状态。
        memset(out, 0, sizeof(*out)); out->structSize = sizeof(*out); out->abiVersion = AMCL_MENU_CURSOR_SNAPSHOT_VERSION;
        return 0;
    }
    memset(out, 0, sizeof(*out)); out->structSize = sizeof(*out); out->abiVersion = AMCL_MENU_CURSOR_SNAPSHOT_VERSION;
    if (atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) return 0;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    const uint32_t backend = g_menuCursorSelectedBackend;
    int valid = 0;
    if (backend >= 1 && backend <= 3 && g_menuCursorSelectedPid == menuCursorProcessId()) {
        const MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
        const AmclCommittedMenuCursorV1* point = &authority->committed;
        if (authority->active && point->flags == AMCL_MENU_CURSOR_COMMITTED &&
            point->gameSession == g_menuCursorSelectedSession && point->activationEpoch == authority->activation &&
            point->menuScopeEpoch == atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) &&
            point->logicalTarget == authority->target && point->inputPublication == authority->publication) {
            *out = *point;
            out->toolScopeEpoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire);
            valid = 1;
        }
    }
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    return valid;
}
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
// 每例模拟新进程选择，不进入产品；真实进程没有解除frozen gameSession的入口。
JNIEXPORT void inputBridge_testResetMenuCursorSelectionV1(void) {
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    g_menuCursorSelectedPid = g_menuCursorSelectedSession = 0; g_menuCursorSelectedBackend = 0;
    memset(g_menuCursorAuthorities, 0, sizeof(g_menuCursorAuthorities));
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}
#endif

static void clearSdlMenuTransactionLocked(void) {
    // 只归零本实例事务，不清 SDL clock、ordinary/tool 来源和实际 cursor。
    (void)amclPointerRetire(&g_sdlMenuState.pointer);
}

static void resetSdlMenuSession(void) {
    pthread_mutex_lock(&g_sdlMenuMutex);
    memset(&g_sdlMenuState, 0, sizeof(g_sdlMenuState));
    memset(&g_sdlMenuTool, 0, sizeof(g_sdlMenuTool));
    pthread_mutex_unlock(&g_sdlMenuMutex);
    resetCommittedMenuCursor(3, atomic_load_explicit(&g_sdlActive, memory_order_acquire));
}

// Grab/focus/window boundaries may arrive after SDL has already accepted a PRESS. In that case
// preserve exactly one RELEASE for the SDL consumer; a pending-but-not-yet-visible press is simply
// discarded so CANCEL can never turn into a click.
static void cancelSdlMenuTransaction(void) {
    pthread_mutex_lock(&g_sdlMenuMutex);
    amclPointerRequestRetire(&g_sdlMenuState.pointer);
    pthread_mutex_unlock(&g_sdlMenuMutex);
}

// Key/mouse state buffers
static unsigned char g_keyDownBuffer[512];
static unsigned char g_mouseDownBuffer[16];
// L2和L3可以同时活跃；局部ring recovery必须连同自己的polling镜像归零，不能释放兄弟窗口。
static unsigned char g_l2KeyDownBuffer[512];
static unsigned char g_l2MouseDownBuffer[16];

// `glfwGetKey`/`glfwGetMouseButton` 的轮询查询。刻意是 `static` 而不是新的 `inputBridge_*`
// 导出符号：委派身份只挂在 `inputBridge_pushEvent` 上（不变量 1），其余表项不需要可按名解析，
// 而少一个导出符号就少一条"绕过委派"的旁路。
static int bridgeQueryKeyDown(int key) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->getKeyDown(key);
    if (key < 0 || key >= 512) return 0;
    pthread_mutex_lock(&g_downMutex);
    const int down = g_keyDownBuffer[key] ? 1 : 0;
    pthread_mutex_unlock(&g_downMutex);
    return down;
}

static int bridgeQueryMouseDown(int button) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->getMouseDown(button);
    if (button < 0 || button >= 16) return 0;
    pthread_mutex_lock(&g_downMutex);
    const int down = g_mouseDownBuffer[button] ? 1 : 0;
    pthread_mutex_unlock(&g_downMutex);
    return down;
}

// Callback function pointers (set by MC via nglfwSetXxxCallback)
static GLFW_invoke_Char_func           g_invoke_Char = NULL;
static GLFW_invoke_CharMods_func       g_invoke_CharMods = NULL;
static GLFW_invoke_CursorEnter_func    g_invoke_CursorEnter = NULL;
static GLFW_invoke_CursorPos_func      g_invoke_CursorPos = NULL;
static AmclGlfwCursorReceiptCallbackV1 g_invoke_CursorReceipt = NULL;
static GLFW_invoke_FramebufferSize_func g_invoke_FramebufferSize = NULL;
static GLFW_invoke_Key_func            g_invoke_Key = NULL;
static GLFW_invoke_MouseButton_func    g_invoke_MouseButton = NULL;
static GLFW_invoke_Scroll_func         g_invoke_Scroll = NULL;
static GLFW_invoke_WindowSize_func     g_invoke_WindowSize = NULL;

// 诊断（2026-05-30）：CHAR 事件分发日志预算，只打前 N 条，确认聊天字符到底走哪个回调。
static int g_charLogBudget = 12;

// 委派不变量 3 的兑现点。MC 的 `glfwInit` 在 surface 发布之前跑是**合法时序**
// （`glfwCreateWindow` 才等 NativeWindow），此时本 image 还解析不到 owner，于是那一批
// 回调只落在本地。解析成功的那一刻必须补发，否则 owner 的 `g_invoke_*` 恒为 NULL，
// pump 会照常 drain 事件再逐条丢掉 —— 那是比空 ring 更难查的一种"零输入"。
//
// 原legacy callback只补发非NULL，避免覆盖owner的独立注册者；新增look callback另存
// 显式注册事实，最新NULL必须补发给同一owner以退休backend资格，不能沿旧legacy约定忽略。
#if AMCL_INPUT_TRACE
/** 外部消费者只沿实际bridge owner尾记录；短/旧尾不做本地fallback，不改变输入能力。 */
JNIEXPORT void inputBridge_noteInputLatencyV1(uint32_t stage,const AmclInputLatencyV1* value){
    const InputBridgeInstanceV1* owner=bridgeDelegate();if(owner){if(bridgeOwnerHasLatencyV1(owner))owner->noteInputLatency(stage,value);return;}
    if(atomic_load_explicit(&g_bridgeOwner,memory_order_acquire)!=INPUT_BRIDGE_OWNER_SELF)return;
    amclInputLatencyNoteV1(stage,value);
}
JNIEXPORT void inputBridge_finishInputLatencyV1(uint64_t prefix,uint32_t outcome){
    const InputBridgeInstanceV1* owner=bridgeDelegate();if(owner){if(bridgeOwnerHasLatencyV1(owner))owner->finishInputLatency(prefix,outcome);return;}
    if(atomic_load_explicit(&g_bridgeOwner,memory_order_acquire)!=INPUT_BRIDGE_OWNER_SELF)return;
    amclInputLatencyFinishV1(prefix,outcome);
}
JNIEXPORT void inputBridge_finishInputLatencyTicketV1(const AmclInputLatencyV1* original,uint32_t outcome){
    const InputBridgeInstanceV1* owner=bridgeDelegate();
    if(owner){if(bridgeOwnerHasLatencyTicketV1(owner))owner->finishInputLatencyTicket(original,outcome);return;}
    if(atomic_load_explicit(&g_bridgeOwner,memory_order_acquire)!=INPUT_BRIDGE_OWNER_SELF)return;
    amclInputLatencyFinishTicketV1(original,outcome);
}
JNIEXPORT uint32_t inputBridge_drainInputLatencyV1(AmclInputLatencyV1* out,uint32_t count,AmclInputLatencyStatsV1* stats){
    const InputBridgeInstanceV1* owner=bridgeDelegate();if(owner)return bridgeOwnerHasLatencyV1(owner)?owner->drainInputLatency(out,count,stats):0;
    if(atomic_load_explicit(&g_bridgeOwner,memory_order_acquire)!=INPUT_BRIDGE_OWNER_SELF)return 0;
    return amclInputLatencyDrainV1(out,count,stats);
}
/** client可选表不具有neutral原运输READ权限。只转原SDK/L2实际CACHE和终点，
 * 即使调用者猜到原token/seq/order，也不能替真实slot读取时点补READ。此static
 * 接缝只拒诊断，不改输入；真正Next读取继续直接调用内部NoteBackendV2。
 */
static void inputLatencyClientNoteV2(uint32_t stage,uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original){
    if(stage!=AMCL_ILAT_CACHE&&stage!=AMCL_ILAT_RETURN)return;
    amclInputLatencyNoteBackendV2(stage,backend,endpoint,original);
}
/** 新可选诊断表只由真正neutral映像借出。SDK/L2冷借用者另核原look/control
 * ownerHost、PID及全部可执行地址；其它bridge映像缺新能力只返回缺席，不能建
 * 第二collector或从RTLD_DEFAULT最新owner补表。OFF编译不保留此getter/表对象。
 */
JNIEXPORT const AmclInputLatencyPortV2* inputBridge_getInputLatencyPortV2(void){
    // 该getter只借真正SELF，不负责解析/回放bridge。未解析或delegate时直接缺席，
    // 避免冷握手中fork继承未知owner后先resolve/replay再由look PID拒绝。
    // 已SELF的foreign child由下面原look getter的module-load PID检查先拒；
    // 不用会学习当前PID的字段冒称继承身份，也不提前建立另一个local Core。
    if(atomic_load_explicit(&g_bridgeOwner,memory_order_acquire)!=INPUT_BRIDGE_OWNER_SELF)return NULL;
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
    if(!look||!look->ownerHost||look->verifyOwner(look->ownerHost)<0)return NULL;
    // 生产TU按C编译，static initializer只能含常量。PID/ownerHost在已经核SELF的
    // 冷getter中一次填入；显式CAS代C++静态guard，竞争只缺诊断，不等待/建owner。
    // state0未初始化、2原线程正在填值、1已release发布；读者acquire后才读两个字段。
    static AmclInputLatencyPortV2 port={AMCL_INPUT_LATENCY_PORT_MAGIC_V2,2,sizeof(AmclInputLatencyPortV2),
        0,0,0,
        &inputLatencyClientNoteV2,&amclInputLatencyFinishBackendV2};
    static atomic_uint state=0;
    if(atomic_load_explicit(&state,memory_order_acquire)!=1u){
        unsigned int expected=0;
        if(!atomic_compare_exchange_strong_explicit(&state,&expected,2u,memory_order_acq_rel,memory_order_acquire))return NULL;
        port.pid=(uint32_t)menuCursorProcessId();port.ownerHost=(uint64_t)look->ownerHost;
        atomic_store_explicit(&state,1u,memory_order_release);
    }
    return port.pid==(uint32_t)menuCursorProcessId()&&port.ownerHost==look->ownerHost?&port:NULL;
}
#endif
static void replayLocalCallbacksToOwner(const InputBridgeInstanceV1* owner) {
    if (g_lookPrefixCallbackRegistered && bridgeOwnerHasLookTransportV1(owner)) {
        // 注册可早于owner发布；只向同一整组owner补发最新事实，NULL同步退休其backend资格。
        owner->setLookPrefixCallback(g_lookPrefixCallback);
    }
    if (g_invoke_CursorPos && owner->setCursorPosCallback) {
        owner->setCursorPosCallback(g_invoke_CursorPos);
    }
    if (g_invoke_CursorReceipt && INPUT_BRIDGE_OWNER_HAS_TAIL(owner, setCursorReceiptCallback)) {
        // 与原回调一样允许注册早于owner出现；整表委派不能在delegate本地解释receipt。
        owner->setCursorReceiptCallback(g_invoke_CursorReceipt);
    }
    if (g_invoke_MouseButton && owner->setMouseButtonCallback) {
        owner->setMouseButtonCallback(g_invoke_MouseButton);
    }
    if (g_invoke_Key && owner->setKeyCallback) {
        owner->setKeyCallback(g_invoke_Key);
    }
    if (g_invoke_Scroll && owner->setScrollCallback) {
        owner->setScrollCallback(g_invoke_Scroll);
    }
    if (g_invoke_Char && owner->replaceCharCallback) {
        (void)owner->replaceCharCallback((void*)(uintptr_t)g_invoke_Char);
    }
    if (g_invoke_CharMods && owner->replaceCharModsCallback) {
        (void)owner->replaceCharModsCallback((void*)(uintptr_t)g_invoke_CharMods);
    }
    if (g_invoke_CursorEnter && owner->replaceCursorEnterCallback) {
        (void)owner->replaceCursorEnterCallback(
            (void*)(uintptr_t)g_invoke_CursorEnter);
    }
    LOGI("AMCL_INPUTBRIDGE replayed local callbacks to owner "
         "cursorPos=%{public}d mouseButton=%{public}d key=%{public}d "
         "scroll=%{public}d char=%{public}d charMods=%{public}d "
         "cursorEnter=%{public}d",
         g_invoke_CursorPos ? 1 : 0, g_invoke_MouseButton ? 1 : 0,
         g_invoke_Key ? 1 : 0, g_invoke_Scroll ? 1 : 0,
         g_invoke_Char ? 1 : 0, g_invoke_CharMods ? 1 : 0,
         g_invoke_CursorEnter ? 1 : 0);
}

// 结束菜单事务时必须同时清 pending PRESS、快速 tap 锁存、down buffer 与 token；只清其中一个
// 会让旧事务的 RELEASE 落到下一次点击。emitRelease 只在已经向 Minecraft 发过 PRESS 时生效。
// 调用方位于 MC pump/grab/window 线程，且不得持 g_cursorMutex；鼠标回调可同步重入 grab。
// 调用者已完成consumer生命周期/顺序检查。先提交聚合与polling，再在down锁外执行回调。
static void submitGlfwLeftContribution(void* window, bool menu, bool held, bool emitCallback, int mods) {
    pthread_mutex_lock(&g_downMutex);
    const int action = setLegacyLeftContribution(&g_l3LeftContribution, menu, held);
    g_mouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = legacyLeftHeld(&g_l3LeftContribution) ? 1 : 0;
    pthread_mutex_unlock(&g_downMutex);
    if (action >= 0 && emitCallback && g_invoke_MouseButton)
        g_invoke_MouseButton(window, GLFW_MOUSE_BUTTON_LEFT, action, mods);
}

/** 已归约的legacy出口：先更新polling，再在状态锁外执行游戏回调，允许同步grab/Hide。 */
static void dispatchGlfwToolEdge(void* window, const GLFWInputEvent* event) {
    pthread_mutex_lock(&g_downMutex);
    if (event->type == EVENT_TYPE_KEY) g_keyDownBuffer[340] = event->i3 != GLFW_RELEASE;
    else g_mouseDownBuffer[event->i1] = event->i2 != GLFW_RELEASE;
    pthread_mutex_unlock(&g_downMutex);
    if (event->type == EVENT_TYPE_KEY) {
        if (g_invoke_Key) g_invoke_Key(window, event->i1, event->i2, event->i3, event->i4);
    } else if (g_invoke_MouseButton) g_invoke_MouseButton(window, event->i1, event->i2, event->i3);
}

/** GLFW触控作用域退休只清tool，未改变的ordinary/typed不产生多余RELEASE。 */
static bool retireGlfwMenuTools(void* window, unsigned long long generation) {
    for (int budget = 0; budget < 3; ++budget) {
        GLFWInputEvent event;
        pthread_mutex_lock(&g_downMutex);
        const bool emitted = retireMenuToolEvent(&g_l3LeftContribution, &g_l3MenuTool, &event);
        pthread_mutex_unlock(&g_downMutex);
        if (!emitted) break;
        dispatchGlfwToolEdge(window, &event);
        if (!l3ActivationMatches(generation)) return false;
    }
    return true;
}

/** callback内仍能同步读当前B；ACK等返回后才成立，回调换目标/失活不能给新身份记旧点。 */
static bool submitGlfwMenuCursor(void* window, double x, double y, uint64_t order,
                                 unsigned long long generation) {
    updateCurrentMenuCursor(AMCL_MENU_CURSOR_BACKEND_GLFW, x, y);
    if (!g_invoke_CursorReceipt && !g_invoke_CursorPos) return true;
    const uint64_t cursorActivation = committedMenuCursorActivation(AMCL_MENU_CURSOR_BACKEND_GLFW);
    bool delivered = true;
    if (g_invoke_CursorReceipt) delivered = g_invoke_CursorReceipt(window, x, y) == 1;
    else g_invoke_CursorPos(window, x, y); // 旧ABI/宿主直达callback仍以返回作为交付边界。
    if (!l3ActivationMatches(generation)) return false;
    // receipt=0仅说明没有实际游戏callback；wrapper提交的同步current仍保留给后面的相对输入。
    if (delivered) commitMenuCursor(AMCL_MENU_CURSOR_BACKEND_GLFW, x, y, order, cursorActivation);
    return true;
}

static bool hasGlfwCursorCallback(void) {
    return g_invoke_CursorReceipt != NULL || g_invoke_CursorPos != NULL;
}

static void cancelMenuTransaction(void* window, bool emitRelease) {
    // 共同归约器先退休旧身份；回调重入不会看到一个仍可重新提交的 pending PRESS。
    const AmclPointerPlan plan = amclPointerRetire(&g_glfwPointer);
    g_menuTargetWindow = NULL;
    if (plan.contribution == 0)
        submitGlfwLeftContribution(window, true, false, emitRelease, 0);
}

// glfwDestroyWindow 在旧 window 仍有效时调用；这确保瞬态重建不会把旧 pending token 带到新窗口。
JNIEXPORT void inputBridge_cancelMenuTransaction(void* window) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->cancelMenuTransaction(window); return; }
    cancelMenuTransaction(window, true);
    if (g_lastPumpWindow == window) g_lastPumpWindow = NULL;
}

// 退出回调与 `nativeSetInputReady` 在两份 image 上会分家：注册方在宿主侧，而 JNI 入口在
// MC 那侧。委派让两者重新落在同一份状态上。
JNIEXPORT void inputBridge_setMcExitCallback(mc_exit_callback_t cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->setMcExitCallback(cb); return; }
    g_mcExitCallback = cb;
}

// 只清 bridge/GLFW 已经实际消费到的按住状态。锁内摘取并清零，外部 callback 一律在锁外调用，
// 因为 Minecraft callback 可能同步调用 glfwSetInputMode 并重入 bridge。
static void clearConsumedDownState(void* window, bool emitCallbacks) {
    resetCommittedMenuCursor(1, atomic_load_explicit(&g_l3Active, memory_order_acquire));
    const unsigned long long generation = atomic_load_explicit(
        &g_l3ActivationGeneration, memory_order_acquire);
    unsigned char releasedKeys[512];
    unsigned char releasedButtons[16];

    pthread_mutex_lock(&g_downMutex);
    memcpy(releasedKeys, g_keyDownBuffer, sizeof(releasedKeys));
    memcpy(releasedButtons, g_mouseDownBuffer, sizeof(releasedButtons));
    memset(g_keyDownBuffer, 0, sizeof(g_keyDownBuffer));
    memset(g_mouseDownBuffer, 0, sizeof(g_mouseDownBuffer));
    memset(&g_l3LeftContribution, 0, sizeof(g_l3LeftContribution));
    memset(&g_l3MenuTool, 0, sizeof(g_l3MenuTool));
    pthread_mutex_unlock(&g_downMutex);

    for (int key = 0; key < 512; key++) {
        if (!l3ActivationMatches(generation)) return;
        if (!releasedKeys[key]) continue;
        if (emitCallbacks && g_invoke_Key) g_invoke_Key(window, key, 0, GLFW_RELEASE, 0);
    }
    for (int button = 0; button < 16; button++) {
        if (!l3ActivationMatches(generation)) return;
        if (!releasedButtons[button]) continue;
        if (emitCallbacks && g_invoke_MouseButton) {
            g_invoke_MouseButton(window, button, GLFW_RELEASE, 0);
        }
    }
}

static void recoverOverflowState(void* window, bool emitCallbacks, const char* consumer) {
    const unsigned long long generation = atomic_load_explicit(
        &g_l3ActivationGeneration, memory_order_acquire);
    // 原历史已不可靠；先在producer锁内捕获当前held和cutoff，随后只退休本consumer。
    // snapshot无法绑定时才保留原全生产epoch路径；所有callback仍在consumer锁外。
    // 正常consumer落后可由完整ordinary生产镜像恢复，不制造全producer不连续epoch。
    // 无可绑定的未知恢复调用仍沿旧epoch对账；显式全局取消另由同步native cancel覆盖。
    const bool l2Recovery = strncmp(consumer, "LWJGL2", 6) == 0;
    const bool l3Recovery = strncmp(consumer, "LWJGL3", 6) == 0;
    if (l2Recovery || l3Recovery) {
        amclInputBeginInteractionBatch();
        pthread_mutex_lock(&g_pushMutex);
        captureRecoveryBaselineLocked(l2Recovery ? &g_l2Baseline : &g_l3Baseline,
            l2Recovery ? &g_l2ReadSequence : &g_l3ReadSequence,
            l2Recovery ? &g_l2OverflowPending : &g_l3OverflowPending);
        if (l3Recovery) g_l3TargetSequence = g_l3Baseline.cutoff;
        pthread_mutex_unlock(&g_pushMutex);
        amclInputEndInteractionBatch();
    } else {
        noteLegacyRingDiscontinuity();
    }
    if (l2Recovery) {
        resetCommittedMenuCursor(2, atomic_load_explicit(&g_l2Active, memory_order_acquire));
        pthread_mutex_lock(&g_downMutex);
        memset(&g_l2LeftContribution, 0, sizeof(g_l2LeftContribution));
        memset(&g_l2MenuTool, 0, sizeof(g_l2MenuTool));
        memset(g_l2KeyDownBuffer, 0, sizeof(g_l2KeyDownBuffer));
        memset(g_l2MouseDownBuffer, 0, sizeof(g_l2MouseDownBuffer));
        (void)amclPointerRetire(&g_l2Pointer);
        // overflow结束整个手势身份；新raw DOWN不能继承旧BEGIN并错误地等待不存在的END。

        g_l2FinalLeftPending = -1;
        pthread_mutex_unlock(&g_downMutex);
        const unsigned long long dropped = atomic_exchange_explicit(&g_overflowDropCount, 0ULL, memory_order_relaxed);
        LOGE("InputBridge ring recovered consumer=%{public}s overwritten=%{public}llu baseline=%{public}llu",
            consumer, dropped, g_l2Baseline.cutoff);
        return; // L2的Java数组由随后的RESET归零；不能调用L3 callback或取消L3菜单。
    }
    // Recovery 必须在 MC consumer 线程做：producer 线程只置标志，绝不能跨线程调用 Minecraft callback。
    cancelMenuTransaction(window, emitCallbacks);
    if (!l3ActivationMatches(generation)) return;
    clearConsumedDownState(window, emitCallbacks);

    const unsigned long long dropped =
        atomic_exchange_explicit(&g_overflowDropCount, 0ULL, memory_order_relaxed);
    LOGE("InputBridge ring overflow recovered consumer=%{public}s overwritten=%{public}llu",
         consumer, dropped);
}

/** GLFW恢复只重放当前ordinary持有，先写polling后callback；每pump沿既有容量预算有界前进。 */
static bool flushGlfwRecoveryBaseline(void* window, unsigned long long generation,
        InputBridgeOrderedPump pump, void* context, uint64_t maxOrder) {
    const uint64_t order = recoveryBaselineOrder(&g_l3Baseline);
    if (order != UINT64_MAX) {
        if (order > maxOrder) return false;
        // RESET控制项先处理，但held重放是capture fence处的新基线，必须先交付更早typed记录。
        if (pump && !pump(context, order)) return false;
        if (!l3ActivationMatches(generation)) return false;
    }
    GLFWInputEvent event;
    for (unsigned budget = 0; budget < EVENT_WINDOW_SIZE; ++budget) {
        if (!l3ActivationMatches(generation)) return false;
        if (!takeRecoveryBaselineEvent(&g_l3Baseline, &event)) return true;
        if (event.type == EVENT_TYPE_TOUCH_MENU_TOOL ||
            (event.type == EVENT_TYPE_KEY && event.i1 == 340) ||
            (event.type == EVENT_TYPE_MOUSE_BUTTON && event.i1 <= GLFW_MOUSE_BUTTON_RIGHT)) {
            pthread_mutex_lock(&g_downMutex);
            const bool emitted = applyMenuToolEvent(&g_l3LeftContribution, &g_l3MenuTool,
                &event, event.type == EVENT_TYPE_TOUCH_MENU_TOOL, g_l3Baseline.tool.epoch);
            pthread_mutex_unlock(&g_downMutex);
            if (emitted) dispatchGlfwToolEdge(window, &event);
            continue;
        }
        if (event.type == EVENT_TYPE_KEY) {
            pthread_mutex_lock(&g_downMutex);
            if (event.i1 < 512) g_keyDownBuffer[event.i1] = 1;
            pthread_mutex_unlock(&g_downMutex);
            if (g_invoke_Key) g_invoke_Key(window,event.i1,event.i2,GLFW_PRESS,event.i4);
        } else if (event.i1 == GLFW_MOUSE_BUTTON_LEFT) {
            submitGlfwLeftContribution(window,false,true,true,event.i3);
        } else {
            pthread_mutex_lock(&g_downMutex);
            g_mouseDownBuffer[event.i1] = 1;
            pthread_mutex_unlock(&g_downMutex);
            if (g_invoke_MouseButton) g_invoke_MouseButton(window,event.i1,GLFW_PRESS,event.i3);
        }
    }
    return false;
}

// ============================================================
//  C-level callback setters (called from glfw_compat.cpp)
//  Used when MC registers callbacks via glfwSetXxxCallback (C)
//  instead of nglfwSetXxxCallback (JNI)
// ============================================================

// ⚠️ 委派时这七个注册入口（四个 setter + 三个 replacer）**先解析再改本地**，顺序不可换：
// 解析那一刻可能触发补发，补发读的必须是**旧**值，否则 replacer 会把刚设进去的新回调当成
// "上一个 callback"返回。本地副本在委派生效后不再被分发路径读到，只作为补发的数据源。
void inputBridge_setCursorPosCallback(GLFW_invoke_CursorPos_func cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (!g_invoke_CursorPos) g_invoke_CursorPos = cb;
    if (owner) owner->setCursorPosCallback(cb);
}

/** 产品GLFW注册带领取结果的wrapper；显式NULL恢复旧直达ABI，正常产品初始化始终强注册。
 * 注册可早于owner发布，补发与末级消费都沿同一整表尾能力，不能把两个image的receipt混合。
 */
JNIEXPORT void inputBridge_setCursorReceiptCallbackV1(AmclGlfwCursorReceiptCallbackV1 callback) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    g_invoke_CursorReceipt = callback;
    if (owner && INPUT_BRIDGE_OWNER_HAS_TAIL(owner, setCursorReceiptCallback)) owner->setCursorReceiptCallback(callback);
}

JNIEXPORT int inputBridge_readSurfaceContextV1(AmclInputSurfaceContextPayload* outContext) {
    if (!outContext) return 0;
    memset(outContext, 0, sizeof(*outContext));
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, readSurfaceContext)
        ? owner->readSurfaceContext(outContext) : 0;
    return amcl_input_owner_read_surface_context(outContext);
}

void inputBridge_setMouseButtonCallback(GLFW_invoke_MouseButton_func cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (!g_invoke_MouseButton) g_invoke_MouseButton = cb;
    if (owner) owner->setMouseButtonCallback(cb);
}

void inputBridge_setKeyCallback(GLFW_invoke_Key_func cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (!g_invoke_Key) g_invoke_Key = cb;
    if (owner) owner->setKeyCallback(cb);
}

void inputBridge_setScrollCallback(GLFW_invoke_Scroll_func cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (!g_invoke_Scroll) g_invoke_Scroll = cb;
    if (owner) owner->setScrollCallback(cb);
}

// ============================================================
//  方案 B 用：直接覆盖式 setter（区别于上面 A 路径的 "只在为空时设"）。
//
//  方案 B 下上游原版 GLFW.class 直接调 C 的 glfwSetXxxCallback(win, cbPtr)
//  （libffi → glfw_callbacks.cpp）。那些 C 函数需要把 cbPtr 存进这里的全局指针，
//  供 inputBridgePumpEvents 分发。上游每次 set 都应"覆盖"旧值（含置 NULL 注销），
//  所以不能用上面的 "if(!g_invoke_X)" 惰性语义。
//
//  返回旧指针（上游 glfwSetXxxCallback 语义要求返回上一个 callback）。委派生效时返回的是
//  **owner 的**旧值 —— 那才是上游语义要的"上一个真正在分发的 callback"。
// ============================================================
void* inputBridge_replaceCharCallback(void* cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    void* old = (void*)(uintptr_t)g_invoke_Char;
    g_invoke_Char = (GLFW_invoke_Char_func)(uintptr_t)cb;
    if (owner) return owner->replaceCharCallback(cb);
    return old;
}
void* inputBridge_replaceCharModsCallback(void* cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    void* old = (void*)(uintptr_t)g_invoke_CharMods;
    g_invoke_CharMods = (GLFW_invoke_CharMods_func)(uintptr_t)cb;
    if (owner) return owner->replaceCharModsCallback(cb);
    return old;
}
void* inputBridge_replaceCursorEnterCallback(void* cb) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    void* old = (void*)(uintptr_t)g_invoke_CursorEnter;
    g_invoke_CursorEnter = (GLFW_invoke_CursorEnter_func)(uintptr_t)cb;
    if (owner) return owner->replaceCursorEnterCallback(cb);
    return old;
}

// Typed GLFW input is consumed on glfwPollEvents' thread, exactly like the
// legacy ring. Keep cursor-enter callback storage in one place so JNI and C
// registration paths do not acquire competing callback owners.
void inputBridge_dispatchCursorEnter(void* window, int entered) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->dispatchCursorEnter(window, entered); return; }
    if (g_invoke_CursorEnter) g_invoke_CursorEnter(window, entered);
}

// Typed TextInputSession commits are already copied/validated by the adapter
// and are consumed on glfwPollEvents' thread. Dispatch directly to the same
// callback owner as legacy CHAR without touching the bounded physical ring.
void inputBridge_dispatchCharCodepoint(void* window, unsigned int codepoint) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->dispatchCharCodepoint(window, codepoint); return; }
    if (g_invoke_Char) {
        g_invoke_Char(window, codepoint);
    } else if (g_invoke_CharMods) {
        g_invoke_CharMods(window, codepoint, 0);
    }
}

// ============================================================
//  Internal: push event to ring buffer
//
// producer 在 g_pushMutex 内写 event 后发布槽与 write sequence；consumer 必须持同一锁完成
// sequence 验证和普通 event 复制，原子 publishedSequence 本身不能保护非原子 event 字段。
// ============================================================

static void sendData_locked(int type, int i1, int i2, int i3, int i4, const MenuRelativeMetadata* relative) {
    const unsigned long long sequence =
        atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
    GLFWInputSlot* slot = &g_events[sequence % EVENT_WINDOW_SIZE];
    slot->event.type = type;
    slot->event.i1 = i1;
    slot->event.i2 = i2;
    slot->event.i3 = i3;
    slot->event.i4 = i4;
    slot->interactionOrder = amclInputNextInteractionOrder();
    slot->l2KeyboardScope=g_explicitKeyScope?g_originalKeyScope:amclInputOwnerL2KeyboardScopeV1();
    slot->menuScopeEpoch = atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_relaxed);
    slot->toolScopeEpoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_relaxed);
    memset(&slot->relative, 0, sizeof(slot->relative));
    if (relative) slot->relative = *relative;
    const int phase = type == EVENT_TYPE_MENU_POINTER ? i1 : relative ? relative->phase : -1;
    const uint32_t token = type == EVENT_TYPE_MENU_POINTER ? (uint32_t)i4 : relative ? relative->token : 0;
    if ((type == EVENT_TYPE_MENU_POINTER || type == EVENT_TYPE_TOUCH_MENU_RELATIVE) &&
        (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_DOWN)) g_producerMenuGestureToken = token;
    slot->gestureToken = type == EVENT_TYPE_TOUCH_MENU_SCROLL ? g_producerMenuGestureToken : token;
    if ((type == EVENT_TYPE_MENU_POINTER || type == EVENT_TYPE_TOUCH_MENU_RELATIVE) &&
        (phase == MENU_POINTER_END || phase == MENU_POINTER_CANCEL) && token == g_producerMenuGestureToken)
        g_producerMenuGestureToken = 0;
    if (type == EVENT_TYPE_TOUCH_MENU_TOOL && (i1 == -1 || i1 == -2 || i1 == 340) &&
        (i2 == GLFW_PRESS || i2 == GLFW_RELEASE)) {
        g_producerMenuTool.epoch = slot->toolScopeEpoch;
        bool* held = i1 == -1 ? &g_producerMenuTool.left : i1 == -2 ? &g_producerMenuTool.right : &g_producerMenuTool.shift;
        unsigned long long* acquired = i1 == -1 ? &g_producerMenuTool.leftAcquired :
            i1 == -2 ? &g_producerMenuTool.rightAcquired : &g_producerMenuTool.shiftAcquired;
        if (i2 == GLFW_PRESS && !*held) *acquired = sequence + 1ULL;
        if (i2 == GLFW_RELEASE) *acquired = 0;
        *held = i2 == GLFW_PRESS;
    }

    // 与真正接受的slot同步更新镜像；不因overflow丢失最后一个PRESS/RELEASE的当前事实。
    if (type == EVENT_TYPE_KEY && i1 >= 0 && i1 <= 512) {
        if (i3 == GLFW_PRESS) {g_producerOrdinary.keys[i1] = slot->event;g_producerOrdinary.keyScopes[i1]=slot->l2KeyboardScope;}
        else if (i3 == GLFW_RELEASE) {memset(&g_producerOrdinary.keys[i1], 0, sizeof(GLFWInputEvent));g_producerOrdinary.keyScopes[i1]=0;}
    } else if (type == EVENT_TYPE_MOUSE_BUTTON && i1 >= 0 && i1 < 16) {
        if (i2 == GLFW_PRESS) g_producerOrdinary.buttons[i1] = slot->event;
        else if (i2 == GLFW_RELEASE) memset(&g_producerOrdinary.buttons[i1], 0, sizeof(GLFWInputEvent));
    }

    // 先发布完整 slot，再推进全局 writeSequence；consumer 的 acquire 读不会看到半写事件。
    atomic_store_explicit(&slot->publishedSequence, sequence + 1ULL, memory_order_release);
    atomic_store_explicit(&g_writeSequence, sequence + 1ULL, memory_order_release);

    const unsigned long long next = sequence + 1ULL;
    if (atomic_load_explicit(&g_l3Active, memory_order_relaxed)) {
        const unsigned long long read = atomic_load_explicit(&g_l3ReadSequence, memory_order_relaxed);
        if (next - read > EVENT_WINDOW_SIZE) {
            atomic_store_explicit(&g_l3OverflowPending, true, memory_order_release);
            atomic_fetch_add_explicit(&g_overflowDropCount, 1ULL, memory_order_relaxed);
        }
    }
    if (atomic_load_explicit(&g_l2Active, memory_order_relaxed)) {
        const unsigned long long read = atomic_load_explicit(&g_l2ReadSequence, memory_order_relaxed);
        if (next - read > EVENT_WINDOW_SIZE) {
            atomic_store_explicit(&g_l2OverflowPending, true, memory_order_release);
            atomic_fetch_add_explicit(&g_overflowDropCount, 1ULL, memory_order_relaxed);
        }
    }
    if (atomic_load_explicit(&g_sdlActive, memory_order_relaxed)) {
        const unsigned long long read = atomic_load_explicit(&g_sdlReadSequence, memory_order_relaxed);
        if (next - read > EVENT_WINDOW_SIZE) {
            atomic_store_explicit(&g_sdlOverflowPending, true, memory_order_release);
            atomic_fetch_add_explicit(&g_sdlOverflowDropCount, 1ULL, memory_order_relaxed);
        }
    }
}

static void sendData(int type, int i1, int i2, int i3, int i4) {
    // 所有publish/capture统一order→producer。NextInteractionOrder在既有递归batch内分配，
    // 不再以producer→order与core/跨平面batch形成逆序；此短事务不调用游戏/UI出口。
    if (g_lookActionDepth) { sendData_locked(type,i1,i2,i3,i4,NULL); return; }
    amclInputBeginInteractionBatch();
    pthread_mutex_lock(&g_pushMutex);
    sendData_locked(type, i1, i2, i3, i4, NULL);
    pthread_mutex_unlock(&g_pushMutex);
    amclInputEndInteractionBatch();
}

/** 已发布的Core与bridge模式快照，先查询Core再入运输锁，不把sensor ns混入模式时钟。 */
JNIEXPORT int inputBridge_getLookResourceV1(AmclLookResourceV1* out) {
    if (!out) return 0; memset(out,0,sizeof(*out));
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return bridgeOwnerHasLookTransportV1(owner) ? owner->getLookResource(out) : 0;
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1(); if(!look) return 0;
    AmclInputLookCoreResourceV1 core;memset(&core,0,sizeof(core));
    if(!amclInputOwnerReadLookResourceV1(&core)||!core.active)return 0;out->context=core.context;
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    out->gameSession=g_menuCursorSelectedPid==menuCursorProcessId()?g_menuCursorSelectedSession:0;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    out->size=sizeof(*out);out->sessionEpoch=core.sessionEpoch;out->surfaceEpoch=core.surfaceEpoch;out->focusEpoch=core.focusEpoch;
    out->grabbed=atomic_load_explicit(&g_isGrabbing,memory_order_acquire)?1u:0u;
    out->modeEpoch=atomic_load_explicit(&g_lookModeEpoch,memory_order_acquire);
    return out->gameSession&&out->grabbed;
}
/** 只检查本批实际运输容量；不溢出覆盖slow consumer，也不以无接收者伪造接受。 */
static int lookRingReserveLocked(unsigned count) {
    // prefix/order/后续action最多三个序号；先拒耗尽，不在数学提交后触发旧allocator abort。
    if(count>EVENT_WINDOW_SIZE||amclInputInteractionFence()>UINT64_MAX-(uint64_t)count-3u)return 0;
    const unsigned long long write=atomic_load_explicit(&g_writeSequence,memory_order_relaxed);
    unsigned long long oldest=write;unsigned mask=0;
    if(atomic_load_explicit(&g_l3Active,memory_order_acquire)){mask|=1;const unsigned long long r=atomic_load_explicit(&g_l3ReadSequence,memory_order_acquire);if(r<oldest)oldest=r;}
    if(atomic_load_explicit(&g_l2Active,memory_order_acquire)){mask|=2;const unsigned long long r=atomic_load_explicit(&g_l2ReadSequence,memory_order_acquire);if(r<oldest)oldest=r;}
    if(atomic_load_explicit(&g_sdlActive,memory_order_acquire)){mask|=4;const unsigned long long r=atomic_load_explicit(&g_sdlReadSequence,memory_order_acquire);if(r<oldest)oldest=r;}
    if(!mask||write>UINT64_MAX-count||write-oldest>EVENT_WINDOW_SIZE-count)return 0;
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
    while(g_lookReclaimedSequence<oldest){const GLFWInputEvent* e=&g_events[g_lookReclaimedSequence% EVENT_WINDOW_SIZE].event;
        if(e->type==AMCL_LOOK_PREFIX_EVENT){const uint64_t token=(uint32_t)e->i1|((uint64_t)(uint32_t)e->i2<<32);
            if(look->retirePrefix(token)==AMCL_LOOK_NOT_READY)break;}
        ++g_lookReclaimedSequence;}
    return (int)mask;
}
/** owner候选与ring发布在一批，sendData_locked只执行预留好的值复制。 */
static int commitLookLocked(uint64_t stream,double dx,double dy,uint64_t sampleNs,uint32_t flush,uint64_t session,int mask,int processed) {
    const uint64_t order=amclInputNextInteractionOrder();if(!order)return 0;
    AmclLookPrefixV1 prefix;memset(&prefix,0,sizeof(prefix));const uint64_t now=menuMonotonicNowNs();
    const int result=processed?amclLookExecutionCommitProcessedV1(stream,dx,dy,session,order,now,&prefix):
        amclLookExecutionCommitV1(stream,dx,dy,sampleNs,session,order,now,flush,&prefix);
    if(result<0)return 0;if(result==AMCL_LOOK_PREFIX_READY){amclLookExecutionSetRecipientsV1(prefix.token,(uint32_t)mask);
        sendData_locked(AMCL_LOOK_PREFIX_EVENT,(int)(uint32_t)prefix.token,(int)(uint32_t)(prefix.token>>32),0,0,NULL);
#if AMCL_INPUT_TRACE
        // prefixOrder与slot另取的ringOrder分别记录；原push锁内发布已真实完成，不取current fence。
        const uint64_t next=atomic_load_explicit(&g_writeSequence,memory_order_relaxed);
        AmclInputLatencyV1 note;memset(&note,0,sizeof(note));note.prefix=prefix.token;note.ringSequence=next;
        note.ringOrder=g_events[(next-1)%EVENT_WINDOW_SIZE].interactionOrder;
        amclInputLatencyNoteV1(AMCL_ILAT_ENQUEUE,&note);
#endif
    }
    return 1;
}
JNIEXPORT int inputBridge_submitLookV1(uint64_t stream,double dx,double dy,uint64_t sampleNs,uint32_t flush) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return bridgeOwnerHasLookTransportV1(owner) ? owner->submitLook(stream,dx,dy,sampleNs,flush) : 0;
#if AMCL_INPUT_TRACE
#ifdef __cplusplus
    // 既有宿主将本TU编为C++：保留原析构，调用链抛出异常时也恢复重入前观察域。
    // result在提交/解锁完成后才赋accepted；通知抛出时仍保持原accepted诊断事实。
    struct LatencyScope {uint64_t previous;int result=0;
        explicit LatencyScope(uint64_t stream):previous(amclInputLatencyBeginV1(stream)){}
        ~LatencyScope(){amclInputLatencyEndV1(previous,result);}} observation(stream);
#else
    // 生产.c按C编译，没有析构：只保存本次Begin返回的原TLS，两个正常出口各恢复一次。
    // 观察域不生成production order；跨C边界外泄异常不是这里可承诺的C语言返回路径。
    const uint64_t observationPrevious=amclInputLatencyBeginV1(stream);
#endif
#endif
    AmclLookResourceV1 resource;if(!inputBridge_getLookResourceV1(&resource)){
#if AMCL_INPUT_TRACE && !defined(__cplusplus)
        // 原资源拒绝即result=0；End先恢复原TLS，诊断锁忙/缺采样也不得漏恢复。
        amclInputLatencyEndV1(observationPrevious,0);
#endif
        return 0;
    }
    amclInputBeginInteractionBatch();pthread_mutex_lock(&g_pushMutex);const int mask=lookRingReserveLocked(1);
    const int accepted=mask?commitLookLocked(stream,dx,dy,sampleNs,flush,resource.gameSession,mask,0):0;
    pthread_mutex_unlock(&g_pushMutex);amclInputEndInteractionBatch();
#if AMCL_INPUT_TRACE && defined(__cplusplus)
    observation.result=accepted;
#endif
    if(accepted)amclDesktopNotifyInput();
#if AMCL_INPUT_TRACE && !defined(__cplusplus)
    // 与原RAII离开函数的位置一致：通知可同步重入，须待它正常返回后才恢复外层TLS。
    amclInputLatencyEndV1(observationPrevious,accepted);
#endif
    return accepted;
}
JNIEXPORT int inputBridge_beginLookActionV1(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return bridgeOwnerHasLookTransportV1(owner) ? owner->beginLookAction() : 0;
    if(g_lookActionDepth){++g_lookActionDepth;return 1;}
    if(!atomic_load_explicit(&g_isGrabbing,memory_order_acquire))return 1;
    AmclLookResourceV1 resource;if(!inputBridge_getLookResourceV1(&resource))return 0;
    amclInputBeginInteractionBatch();pthread_mutex_lock(&g_pushMutex);const int mask=lookRingReserveLocked(2);
    if(!mask||!commitLookLocked(0,0,0,0,1,resource.gameSession,mask,0)){
        pthread_mutex_unlock(&g_pushMutex);amclInputEndInteractionBatch();return 0;}
    g_lookActionDepth=1;return 1;
}
/** Source 候选使用真实全批预算，不能借旧单码 reserve2。整个批始终持 order→push，
 * 包括菜单态，sendData_locked 发布之后才释放批锁；没有逐码 half commit。
 * 合法共持没有最终边沿时仍可提交来源：无接收者/满队列下不凭空制造输出或消耗 look，
 * 后续真正有边沿的批仍必须封旧前缀。count 是候选实际边沿加 terminal 恢复集合的总数。 */
JNIEXPORT int inputBridge_beginSourceActionV1(uint32_t count) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return bridgeOwnerHasLookTransportV1(owner) ? owner->beginSourceAction(count) : 0;
    if(count>EVENT_WINDOW_SIZE-1u)return 0;
    if(g_lookActionDepth){
        // 已封 look 的外层仍需为本次 source 真实边沿单独核全预算，不能把2槽当六码容量。
        if(count&&!lookRingReserveLocked(count))return 0;
        ++g_lookActionDepth;return 1;
    }
    AmclLookResourceV1 resource;memset(&resource,0,sizeof(resource));
    const int grabbed=atomic_load_explicit(&g_isGrabbing,memory_order_acquire)?1:0;
    // 菜单态也不能凭 ring 活跃猜真实 surface/focus。原 Core 私有一致读取在 order/push 前，
    // 标准104字节公开快照不扩字段；terminal 可由 owner 明确退休而单独保留未交付量。
    AmclInputLookCoreResourceV1 core;memset(&core,0,sizeof(core));
    if(count&&(!amclInputOwnerReadLookResourceV1(&core)||!core.active))return 0;
    if(count&&grabbed&&!inputBridge_getLookResourceV1(&resource))return 0;
    amclInputBeginInteractionBatch();pthread_mutex_lock(&g_pushMutex);
    const int mask=lookRingReserveLocked(count+(grabbed?1u:0u));
    // 零边沿的共持/重复请求只提交来源账目，不是游戏动作。它不能推进速率积分或
    // 排空另一根手指的视角平滑余量；否则摇杆MOVE频率会改变相机轨迹并增加回调。
    // 真正的按键边沿及待恢复末松仍先封旧look，再原子发布整个动作批。
    if((count&&!mask)||(count&&grabbed&&mask&&resource.gameSession&&!commitLookLocked(0,0,0,0,1,resource.gameSession,mask,0))){
        pthread_mutex_unlock(&g_pushMutex);amclInputEndInteractionBatch();return 0;
    }
    g_lookActionDepth=1;return 1;
}
JNIEXPORT void inputBridge_endLookActionV1(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { if (bridgeOwnerHasLookTransportV1(owner)) owner->endLookAction(); return; }
    if(!g_lookActionDepth)return;if(--g_lookActionDepth)return;
    pthread_mutex_unlock(&g_pushMutex);amclInputEndInteractionBatch();amclDesktopNotifyInput();
}
/** callback地址属于真实GLFW映像，实际调用、接收者mask与退休仍由发布ring的owner持有。
 * 保留最新注册供late owner replay；delegate绝不激活自己的look registry来伪装资格。 */
JNIEXPORT void inputBridge_setLookPrefixCallbackV1(AmclLookPrefixCallbackV1 callback){
    g_lookPrefixCallback=callback;g_lookPrefixCallbackRegistered=true;
    const InputBridgeInstanceV1* owner=bridgeDelegate();
    if(owner){if(bridgeOwnerHasLookTransportV1(owner))owner->setLookPrefixCallback(callback);return;}
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
    if(look)(void)look->setBackendActive(1,callback&&atomic_load_explicit(&g_l3Active,memory_order_acquire)?1u:0u);}
/** 明确旧processed调用仍用新prefix运输；没有冻结game plan的隔离legacy fixture保原ABI。 */
JNIEXPORT int inputBridge_submitProcessedLookV1(int32_t source,double dx,double dy) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return bridgeOwnerHasLookTransportV1(owner) ? owner->submitProcessedLook(source,dx,dy) : 0;
    if(source<0||source>=5||!isfinite(dx)||!isfinite(dy))return 0;
    AmclLookResourceV1 resource;if(!inputBridge_getLookResourceV1(&resource))return 0;
    static pthread_mutex_t leaseMutex=PTHREAD_MUTEX_INITIALIZER;
    static uint64_t handles[5];static AmclLookResourceV1 resources[5];
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();if(!look)return 0;
    pthread_mutex_lock(&leaseMutex);
    if(handles[source]&&(resources[source].sessionEpoch!=resource.sessionEpoch||resources[source].surfaceEpoch!=resource.surfaceEpoch||
        resources[source].focusEpoch!=resource.focusEpoch||resources[source].modeEpoch!=resource.modeEpoch)){
        (void)look->retireStream(handles[source]);handles[source]=0;}
    if(!handles[source]){AmclLookStreamV1 stream;memset(&stream,0,sizeof(stream));stream.size=sizeof(stream);stream.source=source;
        stream.kind=AMCL_LOOK_COMPAT_DELTA;stream.unit=AMCL_LOOK_VIRTUAL_COUNTS;stream.clock=AMCL_LOOK_OWNER_MONOTONIC;stream.resource=resource;
        if(look->openStream(&stream,&handles[source])<0){pthread_mutex_unlock(&leaseMutex);return 0;}resources[source]=resource;}
    amclInputBeginInteractionBatch();pthread_mutex_lock(&g_pushMutex);const int mask=lookRingReserveLocked(1);
    const int accepted=mask?commitLookLocked(handles[source],dx,dy,0,0,resource.gameSession,mask,1):0;
    pthread_mutex_unlock(&g_pushMutex);amclInputEndInteractionBatch();pthread_mutex_unlock(&leaseMutex);
    if(accepted)amclDesktopNotifyInput();return accepted;
}

/** 生产线程退休触控菜单：order→producer 锁只发布代次，不跨线程调用回调。
 * 已结束的 DOWN/UP 仍可能停在 ring/pending；冻结槽代次使其与新作用域完全分开。
 * ordinary、typed、其它消费者游标和持有账本不变，消费线程只退休自己的菜单贡献。
 */
JNIEXPORT void inputBridge_retireTouchMenuScopeV1(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, retireTouchMenuScope)) owner->retireTouchMenuScope();
        return;
    }
    amclInputBeginInteractionBatch();
    pthread_mutex_lock(&g_pushMutex);
    atomic_fetch_add_explicit(&g_touchMenuScopeEpoch, 1ULL, memory_order_release);
    g_producerMenuGestureToken = 0;
    atomic_fetch_add_explicit(&g_touchMenuToolScopeEpoch, 1ULL, memory_order_release);
    memset(&g_producerMenuTool, 0, sizeof(g_producerMenuTool));
    g_producerMenuTool.epoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_relaxed);
    pthread_mutex_unlock(&g_pushMutex);
    amclInputEndInteractionBatch();
    // 先结束生产事务，再独立退休ACK，不能把snapshot锁加入order→push的生产锁链。
    retireCommittedMenuCursorScope();
    amclDesktopNotifyInput();
}

/** 面板CANCEL/销毁独立退休工具来源：旧1011尚未交付时不再合成点击，已commit仅撤其贡献。
 * 不改变直接菜单token、菜单epoch、ordinary/typed，也不在producer线程执行游戏回调。
 */
JNIEXPORT void inputBridge_retireTouchMenuToolScopeV1(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, retireTouchMenuToolScope)) owner->retireTouchMenuToolScope();
        return;
    }
    amclInputBeginInteractionBatch();
    pthread_mutex_lock(&g_pushMutex);
    atomic_fetch_add_explicit(&g_touchMenuToolScopeEpoch, 1ULL, memory_order_release);
    memset(&g_producerMenuTool, 0, sizeof(g_producerMenuTool));
    g_producerMenuTool.epoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_relaxed);
    pthread_mutex_unlock(&g_pushMutex);
    amclInputEndInteractionBatch();
    amclDesktopNotifyInput();
}

/** Native独立面板账本的首按末松出口；固定合法控件防止该私有通道成为任意键绕门入口。 */
JNIEXPORT void inputBridge_pushTouchMenuToolV1(int code, int action) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, pushTouchMenuTool)) owner->pushTouchMenuTool(code, action);
        return;
    }
    if ((code != -1 && code != -2 && code != 340) ||
        (action != GLFW_PRESS && action != GLFW_RELEASE)) return;
    sendData(EVENT_TYPE_TOUCH_MENU_TOOL, code, action, 0, 0);
    amclDesktopNotifyInput();
}

/** 触控候选与面板移动使用作用域坐标，独立于实体/JNI普通坐标；模态后旧位置也不能迟到。 */
JNIEXPORT void inputBridge_publishTouchMenuCursorV1(double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishTouchMenuCursor)) owner->publishTouchMenuCursor(x, y);
        return;
    }
    if (!isfinite(x) || !isfinite(y)) { recordInvalidCursorWrite("touch-menu-position"); return; }
    int words[4];
    memcpy(words, &x, sizeof(x));
    memcpy(words + 2, &y, sizeof(y));
    sendData(EVENT_TYPE_TOUCH_MENU_CURSOR, words[0], words[1], words[2], words[3]);
    amclDesktopNotifyInput();
}

/** 工具光标与直接触控候选分开归属；已取消的panel位置不能移动另一指的直接菜单事务。 */
JNIEXPORT void inputBridge_publishTouchMenuToolCursorV1(double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishTouchMenuToolCursor)) owner->publishTouchMenuToolCursor(x, y);
        return;
    }
    if (!isfinite(x) || !isfinite(y)) { recordInvalidCursorWrite("touch-menu-tool-position"); return; }
    int words[4];
    memcpy(words, &x, sizeof(x));
    memcpy(words + 2, &y, sizeof(y));
    sendData(EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR, words[0], words[1], words[2], words[3]);
    amclDesktopNotifyInput();
}

/** 两指菜单滚动保留touch scope；普通实体/手柄滚轮继续使用原1007，不被触控退休误清。 */
JNIEXPORT void inputBridge_publishTouchMenuScrollV1(int xoffset, int yoffset) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishTouchMenuScroll)) owner->publishTouchMenuScroll(xoffset, yoffset);
        return;
    }
    if (xoffset == 0 && yoffset == 0) return;
    sendData(EVENT_TYPE_TOUCH_MENU_SCROLL, xoffset, yoffset, 0, 0);
    amclDesktopNotifyInput();
}

/** panel滚轮也属于tool intent，CANCEL精确撤其旧队列；不合并/重放离散滚轮脉冲。 */
JNIEXPORT void inputBridge_pushTouchMenuToolScrollV1(int xoffset, int yoffset) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, pushTouchMenuToolScroll)) owner->pushTouchMenuToolScroll(xoffset, yoffset);
        return;
    }
    if (xoffset == 0 && yoffset == 0) return;
    sendData(EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL, xoffset, yoffset, 0, 0);
    amclDesktopNotifyInput();
}

/** 相对操作在最终consumer的current上应用，不能把Native desired绝对位置当作实际基线。 */
static void publishMenuRelative(int type, int phase, uint32_t token,
        double dx, double dy, double maxX, double maxY) {
    if (!isfinite(dx) || !isfinite(dy) || !isfinite(maxX) || !isfinite(maxY) ||
        fabs(dx) > 1048576 || fabs(dy) > 1048576 || maxX < 0 || maxY < 0 || maxX > 1048576 || maxY > 1048576) return;
    int words[4]; memcpy(words, &dx, sizeof(dx)); memcpy(words + 2, &dy, sizeof(dy));
    MenuRelativeMetadata metadata = {phase, token, maxX, maxY};
    amclInputBeginInteractionBatch();
    pthread_mutex_lock(&g_pushMutex);
    sendData_locked(type, words[0], words[1], words[2], words[3], &metadata);
    pthread_mutex_unlock(&g_pushMutex);
    amclInputEndInteractionBatch();
    amclDesktopNotifyInput();
}
JNIEXPORT void inputBridge_publishTouchMenuToolRelativeV1(double dx, double dy, double maxX, double maxY) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishTouchMenuToolRelative)) owner->publishTouchMenuToolRelative(dx, dy, maxX, maxY);
        return;
    }
    publishMenuRelative(EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE, MENU_POINTER_MOVE, 0, dx, dy, maxX, maxY);
}
JNIEXPORT void inputBridge_publishTouchMenuRelativeV1(int phase, uint32_t token,
        double dx, double dy, double maxX, double maxY) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishTouchMenuRelative)) owner->publishTouchMenuRelative(phase, token, dx, dy, maxX, maxY);
        return;
    }
    if (phase < MENU_POINTER_MOVE || phase > MENU_POINTER_END || (phase != MENU_POINTER_MOVE && token == 0)) return;
    publishMenuRelative(EVENT_TYPE_TOUCH_MENU_RELATIVE, phase, token, dx, dy, maxX, maxY);
}

/** 目标cutoff涵盖全部菜单/tool输出；只有scoped类型退休，普通1005/1006/1007/1010保持。 */
static bool isScopedMenuEvent(int type) {
    return type == EVENT_TYPE_MENU_POINTER || type == EVENT_TYPE_TOUCH_MENU_TOOL ||
        type == EVENT_TYPE_TOUCH_MENU_CURSOR || type == EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR ||
        type == EVENT_TYPE_TOUCH_MENU_SCROLL || type == EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL ||
        type == EVENT_TYPE_TOUCH_MENU_RELATIVE || type == EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE;
}

/** 在最终consumer处核两类冻结资格，tool-only退休不改变direct菜单的epoch。 */
static bool scopedMenuEventValid(int type, uint64_t menuEpoch, uint64_t toolEpoch) {
    if (isScopedMenuEvent(type) && menuEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire)) return false;
    const bool tool = type == EVENT_TYPE_TOUCH_MENU_TOOL || type == EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR ||
        type == EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL || type == EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE;
    return !tool || toolEpoch == atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire);
}

/** 候选提交前检查整个当前快照中的取消权限，不能先提交 due PRESS 再读 CANCEL。
 * 只扫描、不推进消费游标；有效后续 MOVE/UP 仍按原序等待源点 PRESS。
 * 新 DOWN 是旧 token 的替换边界；过期槽交由既有 overflow 恢复，候选先安全撤销。
 */
static bool queuedMenuInvalidates(uint32_t token, uint64_t epoch,
        unsigned long long read, unsigned long long target, uint64_t maxOrder, bool gestureBegun) {
    // 控制项撤销尚未发生的动作，不是普通事件交付；SDL调用者的maxOrder可能就是原DOWN。
    // 若据该order截断，就永远看不到后面的CANCEL。普通后继仍由消费游标严格按序推进。
    (void)maxOrder;
    bool canceled = epoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire);
    bool normallyEnded = false;
    pthread_mutex_lock(&g_pushMutex);
    for (unsigned budget = 0; !canceled && read < target && budget < EVENT_WINDOW_SIZE; ++budget, ++read) {
        const GLFWInputSlot* slot = &g_events[read % EVENT_WINDOW_SIZE];
        if (atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed) != read + 1ULL) {
            canceled = true;
            break;
        }
        const GLFWInputEvent* event = &slot->event;
        if (slot->menuScopeEpoch != epoch) continue;
        if (event->type == EVENT_TYPE_MENU_POINTER || event->type == EVENT_TYPE_TOUCH_MENU_RELATIVE) {
            const int phase = event->type == EVENT_TYPE_MENU_POINTER ? event->i1 : slot->relative.phase;
            const uint32_t value = event->type == EVENT_TYPE_MENU_POINTER ? (uint32_t)event->i4 : slot->relative.token;
            if (value == token && phase == MENU_POINTER_CANCEL) canceled = true;
            // BEGIN手势的UP只松LEFT，后面仍可能有位置/滚轮或Cancel；必须END才正式关闭。
            // 旧无BEGIN的raw事务没有END字段，继续以原UP兼容，不能因此丢掉旧完整tap。
            if (value == token && (phase == MENU_POINTER_END || (!gestureBegun && phase == MENU_POINTER_UP))) normallyEnded = true;
            // 正常关闭tap1以后BEGIN2：保留两次点击，未关闭的旧active才作为替换撤销。
            if (!normallyEnded && (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_DOWN) && value != token) canceled = true;
        }
    }
    pthread_mutex_unlock(&g_pushMutex);
    return canceled;
}

/** 读取该consumer自身当前点；只有启用/target基线和该consumer真实出口能更新，不取兄弟latest。 */
static void currentMenuCursor(uint32_t backend, double* x, double* y) {
    pthread_mutex_lock(&g_menuCursorSnapshotMutex);
    *x = g_menuCursorAuthorities[backend].currentX;
    *y = g_menuCursorAuthorities[backend].currentY;
    pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
}

/** 将同顺序中的相对命令在consumer末级应用。clamp边界随源packet冻结，不读取Native desired。 */
static void resolveRelativeMenuCursor(uint32_t backend, const GLFWInputEvent* event,
        const MenuRelativeMetadata* relative, double* x, double* y) {
    double dx = 0.0, dy = 0.0;
    const int words[4] = {event->i1, event->i2, event->i3, event->i4};
    memcpy(&dx, words, sizeof(dx)); memcpy(&dy, words + 2, sizeof(dy));
    currentMenuCursor(backend, x, y);
    if (relative->phase == MENU_POINTER_MOVE || relative->phase == MENU_POINTER_UP ||
        relative->phase == MENU_POINTER_DOWN || relative->phase == MENU_POINTER_END) { *x += dx; *y += dy; }
    *x = fmin(relative->maxX, fmax(0.0, *x));
    *y = fmin(relative->maxY, fmax(0.0, *y));
}

static bool relativeMenuEndMoves(const GLFWInputEvent* event, const MenuRelativeMetadata* relative) {
    if (event->type != EVENT_TYPE_TOUCH_MENU_RELATIVE || relative->phase != MENU_POINTER_END) return false;
    double dx = 0.0, dy = 0.0; const int words[4] = {event->i1, event->i2, event->i3, event->i4};
    memcpy(&dx, words, sizeof(dx)); memcpy(&dy, words + 2, sizeof(dy));
    return dx != 0.0 || dy != 0.0;
}

/** 相对传输只在此末级解算；菜单阶段保留double源点，工具/无token移动转换为旧1010。 */
static bool resolveRelativeMenuEvent(uint32_t backend, GLFWInputEvent* event,
        const MenuRelativeMetadata* relative, uint32_t currentToken, double* menuX, double* menuY) {
    *menuX = event->i2; *menuY = event->i3;
    if (event->type != EVENT_TYPE_TOUCH_MENU_RELATIVE && event->type != EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE) return true;
    const bool tool = event->type == EVENT_TYPE_TOUCH_MENU_TOOL_RELATIVE;
    const int phase = tool ? MENU_POINTER_MOVE : relative->phase;
    const uint32_t token = tool ? 0 : relative->token;
    if (!tool && phase != MENU_POINTER_BEGIN && phase != MENU_POINTER_DOWN && token != 0 && token != currentToken) return false;
    resolveRelativeMenuCursor(backend, event, relative, menuX, menuY);
    if (tool || (phase == MENU_POINTER_MOVE && token == 0)) {
        const double x = *menuX, y = *menuY;
        event->type = EVENT_TYPE_CURSOR_POSITION;
        int words[4]; memcpy(words, &x, sizeof(x)); memcpy(words + 2, &y, sizeof(y));
        event->i1 = words[0]; event->i2 = words[1]; event->i3 = words[2]; event->i4 = words[3];
    } else {
        event->type = EVENT_TYPE_MENU_POINTER; event->i1 = phase; event->i4 = (int)token;
    }
    return true;
}

/** 结束/取消后的迟到DOWN不能把已退休BEGIN重新认领；同token只允许BEGIN后的首次实际DOWN。 */
static bool acceptMenuGestureStart(uint32_t backend, int phase, uint32_t token,
        uint32_t currentToken, bool begun, bool heldOrPending, bool downAccepted) {
    const uint64_t epoch = atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire);
    if (g_gestureTokenEpoch[backend] != epoch) { g_gestureTokenEpoch[backend] = epoch; g_gestureTokenHigh[backend] = 0; }
    if (amclPointerIsContinuation(phase, token, currentToken, begun, heldOrPending, downAccepted)) return true;
    if (token <= g_gestureTokenHigh[backend]) return false;
    g_gestureTokenHigh[backend] = token;
    return true;
}

/** 五 int 既有坐标载荷，不增加公共 ABI；让拉取后端也观察到按键边沿之间的每次移动。 */
static int returnOrderedMenuCursor(double x, double y,
        uint32_t backend, uint64_t order, int* outType, int* o1, int* o2, int* o3, int* o4) {
    int words[4];
    memcpy(words, &x, sizeof(x));
    memcpy(words + 2, &y, sizeof(y));
    if (outType) *outType = EVENT_TYPE_CURSOR_POSITION;
    if (o1) *o1 = words[0];
    if (o2) *o2 = words[1];
    if (o3) *o3 = words[2];
    if (o4) *o4 = words[3];
    commitMenuCursor(backend, x, y, order, committedMenuCursorActivation(backend));
    return 1;
}

/** 拉取接口的统一不可变离散载荷出口；内部来源类别在最终归约后不泄漏到游戏ABI。 */
static int returnLegacyEvent(const GLFWInputEvent* event,
        int* outType, int* o1, int* o2, int* o3, int* o4) {
    if (outType) *outType = event->type;
    if (o1) *o1 = event->i1;
    if (o2) *o2 = event->i2;
    if (o3) *o3 = event->i3;
    if (o4) *o4 = event->i4;
    return 1;
}

// ============================================================
//  Cross-.so push entry
//
//  libentry.so（touch_input.cpp）通过 dlsym 拿到这个函数指针，把所有事件
//  写入路径串行化进同一把 mutex。导出符号经 glfw_mg.version 的
//  "inputBridge_*" 通配生效。
// ============================================================

JNIEXPORT void inputBridge_pushEvent(int type, int i1, int i2, int i3, int i4) {
    // ⭐ 委派身份判据就挂在这个函数上（见"跨 image 实例委派"不变量 1）：owner 的表里
    // `pushEvent` 存的就是本函数，所以 owner 自己进来时 `bridgeDelegate()` 返回 NULL。
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->pushEvent(type, i1, i2, i3, i4); return; }
    sendData(type, i1, i2, i3, i4);
    // 批内只复制已预留 slot。不得逐码通知并同步回入 source/SDK，让半组合被观察；
    // 最外层 endLookAction 在 Source 已解锁且全批发布后只通知一次。
    if(!g_lookActionDepth)amclDesktopNotifyInput();
}
/** 唯一neutral Source调用的私有已预留key复制口。保持原keygen，不通过delegate/global
 * current重签旧deferred终端；调用者已经完成原owner、全批预算与scope最终核验。 */
JNIEXPORT void inputBridge_pushKeyScopedV1(int key,int scan,int action,int mods,uint64_t originalScope){
    if(!g_lookActionDepth)return;
    g_explicitKeyScope=true;g_originalKeyScope=originalScope;
    sendData_locked(EVENT_TYPE_KEY,key,scan,action,mods,NULL);
    g_explicitKeyScope=false;g_originalKeyScope=0;
}

// v7 唯一跨 .so 坐标 ABI。libentry 只能表达“look 增量”或“菜单绝对位置”，不能取得内部
// 地址，也就无法绕过锁或把菜单坐标误写进相机坐标。双坐标隔离是 Back-to-Game 零瞬移修复
// 的组成部分，不得为了兼容旧协议重新合并。
JNIEXPORT void inputBridge_addLookDelta(double dx, double dy) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->addLookDelta(dx, dy); return; }
    // 旧ABI没有来源字段，保持其作为合成视角的兼容语义；现役物理入口必须用新接口。
    inputBridge_addSourceLookDelta(0, dx, dy);
}

JNIEXPORT void inputBridge_addSourceLookDelta(int32_t source, double dx, double dy) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, addSourceLookDelta)) {
            owner->addSourceLookDelta(source, dx, dy);
        } else {
            owner->addLookDelta(dx, dy);
        }
        return;
    }
    // Final cross-DSO defense: never let a malformed producer permanently turn
    // the authoritative cursor pair into NaN/Inf. Higher layers reject earlier,
    // but this exported ABI must remain safe when called directly.
    if (!isfinite(dx) || !isfinite(dy)) {
        recordInvalidCursorWrite("look-delta-nonfinite");
        return;
    }
    pthread_mutex_lock(&g_cursorMutex);
    // 冻结新计划期间兼容符号只转新owner运输，不能与ordered记录双写future累计。
    if(g_menuCursorSelectedSession){pthread_mutex_unlock(&g_cursorMutex);(void)inputBridge_submitProcessedLookV1(source,dx,dy);return;}
    const double nextX = g_lookX + dx;
    const double nextY = g_lookY + dy;
    // 3是平台control-source的实体键鼠端，与typed ABI的source枚举不同。
    const bool nonPhysical = source != 3;
    const double nextNonPhysicalX = g_nonPhysicalLookX + (nonPhysical ? dx : 0.0);
    const double nextNonPhysicalY = g_nonPhysicalLookY + (nonPhysical ? dy : 0.0);
    if (!isfinite(nextX) || !isfinite(nextY) ||
        !isfinite(nextNonPhysicalX) || !isfinite(nextNonPhysicalY)) {
        pthread_mutex_unlock(&g_cursorMutex);
        recordInvalidCursorWrite("look-delta-overflow");
        return;
    }
    g_lookX = nextX;
    g_lookY = nextY;
    g_nonPhysicalLookX = nextNonPhysicalX;
    g_nonPhysicalLookY = nextNonPhysicalY;
    pthread_mutex_unlock(&g_cursorMutex);
    // 时延埋点的 in 端。放在**解锁之后**：它自己是原子操作，不需要 g_cursorMutex，
    // 而在锁内多做一次 clock_gettime 会把这条热路径的临界区拉长。
    noteLookSampleQueued();
    amclDesktopNotifyInput();
}

JNIEXPORT void inputBridge_sdlGetNonPhysicalCursorSnapshot(double* outX, double* outY) {
    if (!outX || !outY) return;
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, sdlGetNonPhysicalCursorSnapshot)) {
            owner->sdlGetNonPhysicalCursorSnapshot(outX, outY);
        } else {
            // 旧owner不能证明已排除物理量，拒绝伪造一个可能重复投递的grabbed快照。
            *outX = 0.0; *outY = 0.0;
        }
        return;
    }
    pthread_mutex_lock(&g_cursorMutex);
    const bool grabbing = atomic_load_explicit(&g_isGrabbing, memory_order_relaxed);
#ifdef AMCL_CONTROL_DELIVERY_HOST_TESTING
    // 组合host的typed queue可切路由，但Core/neutral owner是实际生产实现，不能替换其函数表。
    const bool typed = amclBackendInputHostStubTypedRouteActive() != 0;
#else
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    const bool typed = api && (api->capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE);
#endif
    // 显式legacy启动仍由累计流承载实体量；只有typed生效时才排除该来源。
    *outX = grabbing ? (typed ? g_nonPhysicalLookX : g_lookX) : g_menuX;
    *outY = grabbing ? (typed ? g_nonPhysicalLookY : g_lookY) : g_menuY;
    pthread_mutex_unlock(&g_cursorMutex);
}

// 菜单光标的**唯一**写点，语义是绝对：参数就是系统指针 / 触摸落点在组件内的物理 px。
// 不允许在这里引入任何偏移或增量累加，理由见上方"菜单光标必须是绝对映射"一节。
JNIEXPORT void inputBridge_setMenuCursor(double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->setMenuCursor(x, y); return; }
    if (!isfinite(x) || !isfinite(y)) {
        recordInvalidCursorWrite("menu-position");
        return;
    }
    pthread_mutex_lock(&g_cursorMutex);
    g_menuX = x;
    g_menuY = y;
    pthread_mutex_unlock(&g_cursorMutex);
}

// 外部坐标生产入口。低层 setMenuCursor 仍只提交消费态，不能递归入队。
void inputBridge_publishMenuCursor(double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, publishMenuCursor)) owner->publishMenuCursor(x, y);
        else owner->setMenuCursor(x, y);
        return;
    }
    if (!isfinite(x) || !isfinite(y)) { recordInvalidCursorWrite("ordered-menu"); return; }
    int words[4];
    memcpy(words, &x, sizeof(x));
    memcpy(words + 2, &y, sizeof(y));
    sendData(EVENT_TYPE_CURSOR_POSITION, words[0], words[1], words[2], words[3]);
}

// 有序坐标的同一解码用于三个消费者；消费前不修改公开光标状态。
static void consumeOrderedCursor(const GLFWInputEvent* event, uint32_t backend) {
    const int words[4] = {event->i1, event->i2, event->i3, event->i4};
    double x = 0.0, y = 0.0;
    memcpy(&x, words, sizeof(x));
    memcpy(&y, words + 2, sizeof(y));
    inputBridge_setMenuCursor(x, y);
    updateCurrentMenuCursor(backend, x, y);
}

// 由 glfwSwapBuffers 在一次真实 present 完成后调用；与 PumpEvents 同属 MC 渲染线程，无需原子/锁。
// ⚠️ 必须与 pump 落在同一份 image 上：菜单 PRESS 的屏障是 `g_presentSerial + 2`，两者分家
// 会让每一次菜单点击永久停在 pending（而光标照常跟手）。委派保证了这一点。
JNIEXPORT void inputBridge_notifyFramePresented(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->notifyFramePresented(); return; }
    publishGraphicsPresentation("GLFW");
}

/** 真实GLFW swap调用的精确目标尾接口；旧公共入口保留，delegate必须同表同owner。 */
JNIEXPORT void inputBridge_notifyFramePresentedForTargetV1(uint64_t window, uint64_t generation) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, notifyFramePresentedForTarget))
            owner->notifyFramePresentedForTarget(window, generation);
        else owner->notifyFramePresented();
        return;
    }
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    registerGraphicsPresentationSinks();
    if (amclGraphicsDispatchPresentV1("GLFW", window, generation)) return;
#endif
    advanceGlfwPresentation(window, generation);
}

// ============================================================
//  Event pump (called from glfwPollEvents on MC render thread)
// ============================================================

// ==================== GLFW3 pump 的端到端计数（2026-09-03）====================
//
// ⭐ 这一组是本次回归的**直接教训**（AGENTS.md §二.3）：2026-09-01 之后 GLFW3 路线 drain
// 的是一条永远为空的 ring，而日志里"通道建起来了但一条都没流过"与"工作正常"长得一模一样
// —— 三条 pump 函数此前没有任何计数，`[GLFW-DIAG] poll#1` 只证明 poll 循环在跑。
// 26.3 那次（`host_presented_active`）也是同一形状，两次都是零计数把它藏住的。
//
// 判据（三条，缺一条都读不出结论）：
//   · `drained` 是**单调累计**的 ring 出货数，不是就绪声明；
//   · 必须与 `produced`（`g_writeSequence`，同样单调且从不回退）成对打，否则读不出
//     "没人产" 与 "产了没人取" 的差别；
//   · 告警条件是 `produced > 0 && drained == 0` —— 只有这一条没有善意解释。
//     ⚠️ **不能只看 `drained == 0`**：玩家停在主菜单不点任何东西时它本来就是 0，
//     那样的告警会在正常场景里响，而会误报的计数器比没有计数器更糟（规范 §八 纪律 5）。
static atomic_ullong g_l3PumpCalls = 0;
static atomic_ullong g_l3DrainedEvents = 0;

static void notePumpCycle(unsigned long long drainedThisCycle) {
    const unsigned long long polls = atomic_fetch_add_explicit(
        &g_l3PumpCalls, 1ULL, memory_order_relaxed) + 1ULL;
    const unsigned long long drained = drainedThisCycle == 0ULL
        ? atomic_load_explicit(&g_l3DrainedEvents, memory_order_relaxed)
        : atomic_fetch_add_explicit(&g_l3DrainedEvents, drainedThisCycle,
                                    memory_order_relaxed) + drainedThisCycle;
    const unsigned long long produced =
        atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
    // 本函数只在 owner 的 pump 本体里跑（delegate 的 `inputBridgePumpEvents` 早已转发返回），
    // 所以 role 只有两种可能，而 `unresolved` 恰好就是"宿主还没发布"这一段的名字。
    const char* role =
        atomic_load_explicit(&g_bridgeOwner, memory_order_relaxed) ==
            INPUT_BRIDGE_OWNER_SELF ? "owner" : "unresolved";

    if (drainedThisCycle != 0ULL && isFirstOrPowerOfTwoUll(drained)) {
        LOGI("AMCL_INPUTBRIDGE_PUMP polls=%{public}llu drained=%{public}llu "
             "produced=%{public}llu role=%{public}s",
             polls, drained, produced, role);
        return;
    }
    // 64 次 poll ≈ 1 秒；之后按 2 的幂退避，稳态零噪声。
    if (produced != 0ULL && drained == 0ULL && polls >= 64ULL &&
        isFirstOrPowerOfTwoUll(polls)) {
        LOGE("AMCL_INPUTBRIDGE_PUMP polls=%{public}llu drained=0 "
             "produced=%{public}llu role=%{public}s (events reached this ring but "
             "the GLFW3 consumer has never taken one)",
             polls, produced, role);
    }
}

void inputBridgeStartPumping(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->startPumping(); return; }
    if (atomic_load_explicit(&g_l3ExplicitActivation, memory_order_acquire) &&
        !atomic_load_explicit(&g_l3Active, memory_order_acquire)) return;
    // terminal 恢复是泵维护，绝不塞进合法 getter/query。先恢复真运输，再冻结本轮 write 上限。
    (void)amclSourceControlDrainTerminalsV1();
    registerGraphicsPresentationSinks();
    atomic_store_explicit(&g_l3Active, true, memory_order_release);
    const unsigned long long write = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    unsigned long long read = atomic_load_explicit(&g_l3ReadSequence, memory_order_relaxed);
    const bool flagged = atomic_exchange_explicit(&g_l3OverflowPending, false, memory_order_acq_rel);
    if (flagged || write - read > EVENT_WINDOW_SIZE) {
        // 旧槽已被覆盖，不能从“最后 4096 条”中猜一个边界继续，否则首条可能是 RELEASE/组合键
        // 中段。整批丢弃并让 PumpEvents 在有 window 的 MC 线程执行 fail-safe release。
        read = write;
        atomic_store_explicit(&g_l3ReadSequence, read, memory_order_release);
        g_l3RecoveryPending = true;
    }
    g_l3TargetSequence = write;

    // 对当前生效的坐标源做一次成对快照，并在同一锁内推进 pump 去重基准。
    double rx = 0.0, ry = 0.0;
    if (bridgeTakeCursorChange(&rx, &ry) && hasGlfwCursorCallback()) {
        g_shouldUpdateMouse = true;
    }
}

void inputBridgePumpEvents(void* window) {
    inputBridge_pumpOrdered(window, NULL, NULL, UINT64_MAX);
}

/** 消费线程推进完整延期事务。false 表示仍有更早 PRESS，后续所有普通/typed必须等待。 */
static bool advanceGlfwMenuPending(void* window, unsigned long long read,
        unsigned long long target, uint64_t maxOrder, unsigned long long generation) {
    if (!g_glfwPointer.pressPending) return true;
    refreshGlfwPresentationState();
    const unsigned long long cancelTarget = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    (void)target;
    const bool cancelled = queuedMenuInvalidates(g_glfwPointer.token, g_glfwPointer.scopeEpoch,
        read, cancelTarget, maxOrder, g_glfwPointer.gestureBegun);
    const bool invalid = g_glfwPointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire) ||
        (g_glfwPresentedWindow != 0 && (g_glfwPresentedWindow != g_menuPresentedWindow ||
         (g_menuPresentedGeneration != 0 && (g_glfwPresentedGeneration != g_menuPresentedGeneration ||
          g_glfwPresentedIdentity != g_menuPresentedIdentity)))) ||
        atomic_load_explicit(&g_isGrabbing, memory_order_acquire);
    double x = 0, y = 0; bridgeCursorSnapshot(&x, &y);
    const enum AmclPointerAdvanceKind step = amclPointerAdvance(&g_glfwPointer,
        &g_glfwPointerPolicy, invalid, cancelled, menuPendingExpired(g_glfwPointer.pendingSinceNs),
        maxOrder, g_presentSerial, x, y);
    if (step == AMCL_POINTER_RETIRED || step == AMCL_POINTER_RELEASE) {
        g_menuTargetWindow = NULL;
        if (step == AMCL_POINTER_RELEASE) submitGlfwLeftContribution(window, true, false, true, 0);
        return l3ActivationMatches(generation);
    }
    if (step == AMCL_POINTER_RESTORE_SOURCE) {
        // 仅恢复冻结源点；实际 callback 仍锁外执行，返回后才冻结 +2 帧基线。
        inputBridge_setMenuCursor(g_glfwPointer.sourceX, g_glfwPointer.sourceY);
        if (!submitGlfwMenuCursor(window, g_glfwPointer.sourceX, g_glfwPointer.sourceY,
                g_glfwPointer.pendingOrder, generation)) return false;
        refreshGlfwPresentationState();
        amclPointerSourceDelivered(&g_glfwPointer, g_presentSerial, &g_glfwPointerPolicy);
        return false;
    }
    if (step == AMCL_POINTER_ACQUIRE) {
        submitGlfwLeftContribution(window, true, true, true, 0);
        return l3ActivationMatches(generation);
    }
    return false;
}

void inputBridge_pumpOrdered(void* window, InputBridgeOrderedPump pump, void* context,
                             uint64_t maxOrder) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, pumpOrdered)) owner->pumpOrdered(window, pump, context, maxOrder);
        else { if (pump && !pump(context, maxOrder)) return; owner->pumpEvents(window); }
        return;
    }
    if (atomic_load_explicit(&g_l3ExplicitActivation, memory_order_acquire) &&
        !atomic_load_explicit(&g_l3Active, memory_order_acquire)) return;
    unsigned long long drainedThisCycle = 0ULL;
    const unsigned long long activationGeneration = atomic_load_explicit(
        &g_l3ActivationGeneration, memory_order_acquire);
    g_lastPumpWindow = window;
    refreshGlfwPresentationState();
    if (!retireGlfwMenuTools(window, activationGeneration)) return;
    if (g_l3RecoveryPending) {
        g_l3RecoveryPending = false;
        g_l3Baseline.pending = false;
        recoverOverflowState(window, true, "LWJGL3");
        if (!l3ActivationMatches(activationGeneration)) return;
    }
    // 旧历史已被快照cutoff替换；基线完整交付前不越过它解释新ring或pending菜单。
    if (!flushGlfwRecoveryBaseline(window, activationGeneration, pump, context, maxOrder)) return;
    // 首先核退休代次和目标。已经 UP 的候选仍有同等取消权限，不能由下一帧复活。
    if (g_glfwPointer.token != 0 &&
        (g_glfwPointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
         g_glfwPointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire) ||
         g_menuTargetWindow != window ||
         (g_menuPresentedWindow != 0 && g_glfwPresentedWindow != 0 &&
          (g_menuPresentedWindow != g_glfwPresentedWindow ||
           (g_menuPresentedGeneration != 0 &&
            (g_menuPresentedGeneration != g_glfwPresentedGeneration ||
             g_menuPresentedIdentity != g_glfwPresentedIdentity)))))) {
        cancelMenuTransaction(window, true);
        if (!l3ActivationMatches(activationGeneration)) return;
    }

    // Window/framebuffer size callbacks are emitted by glfw_compat immediately after it accepts and commits
    // one surface pair. The bridge no longer re-reads env or emits a second callback here: doing so created
    // an independent resize path whose width/height could belong to a different surface epoch.

    // Process event queue。target 是 StartPumping 的 write sequence 快照；本轮之后到达的事件留给
    // 下一次 poll。只在验证并复制 slot 时持 producer lock，callback 分发始终在锁外。
    unsigned long long readSequence =
        atomic_load_explicit(&g_l3ReadSequence, memory_order_relaxed);
    const unsigned long long targetSequence = g_l3TargetSequence;

    while (readSequence < targetSequence) {
        if (!l3ActivationMatches(activationGeneration)) return;
        if (!retireGlfwMenuTools(window, activationGeneration)) return;
        if (g_glfwPointer.token != 0 &&
            (g_glfwPointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
             g_glfwPointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire))) {
            cancelMenuTransaction(window, true);
            if (!l3ActivationMatches(activationGeneration)) return;
        }
        if (g_glfwPointer.token != 0 && !g_glfwPointer.pressPending && !g_glfwPointer.buttonDown &&
            queuedMenuInvalidates(g_glfwPointer.token, g_glfwPointer.scopeEpoch, readSequence, targetSequence, maxOrder, g_glfwPointer.gestureBegun)) {
            cancelMenuTransaction(window, true);
        }
        // DOWN 已发布源点，但 PRESS 延期期间，后续坐标、UP、按键和 typed 全部等待。
        // CANCEL/替换/退休只是撤销资格的控制，先扫描当前快照再尝试到期提交。
        if (!advanceGlfwMenuPending(window, readSequence, targetSequence, maxOrder,
                activationGeneration)) break;
        GLFWInputEvent event;
        pthread_mutex_lock(&g_pushMutex);
        GLFWInputSlot* slot = &g_events[readSequence % EVENT_WINDOW_SIZE];
        const unsigned long long published =
            atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed);
        if (published != readSequence + 1ULL) {
            // producer 在本轮 pump 期间又推进超过一圈。停止解释不完整批次，直接跳到最新序列并
            // fail-safe release；不能继续 switch 一个可能来自另一 sequence 的槽。
            const unsigned long long latest =
                atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
            pthread_mutex_unlock(&g_pushMutex);
            readSequence = latest;
            atomic_store_explicit(&g_l3ReadSequence, readSequence, memory_order_release);
            atomic_store_explicit(&g_l3OverflowPending, false, memory_order_release);
            recoverOverflowState(window, true, "LWJGL3-mid-pump");
            if (!l3ActivationMatches(activationGeneration)) return;
            // 恢复函数已在producer锁内更新严格cutoff；旧局部游标不得覆盖新基线。
            (void)flushGlfwRecoveryBaseline(window, activationGeneration, pump, context, maxOrder);
            notePumpCycle(drainedThisCycle);
            return;
        }
        event = slot->event;
        const uint64_t interactionOrder = slot->interactionOrder;
        const uint64_t menuScopeEpoch = slot->menuScopeEpoch;
        const uint64_t toolScopeEpoch = slot->toolScopeEpoch;
        const uint32_t gestureToken = slot->gestureToken;
        const MenuRelativeMetadata relative = slot->relative;
        pthread_mutex_unlock(&g_pushMutex);
        // 生产边界可以在队首快照之后推进；读到新scope槽后再次退休旧工具，才能安全接受新owner。
        if (!retireGlfwMenuTools(window, activationGeneration)) return;
        if (g_glfwPointer.token != 0 &&
            (g_glfwPointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
             g_glfwPointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire))) {
            cancelMenuTransaction(window, true);
            if (!l3ActivationMatches(activationGeneration)) return;
        }
        if (interactionOrder > maxOrder) break;
        if (isScopedMenuEvent(event.type) &&
            readSequence < atomic_load_explicit(&g_l3MenuTargetCutoff, memory_order_acquire)) {
            ++readSequence;
            ++drainedThisCycle;
            continue;
        }
        // 只让更早的 typed 记录先执行，回调不持 producer/core 锁。
        const uint64_t targetEpochBeforeTyped = atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire);
        if (pump && !pump(context, interactionOrder - 1u)) return;
        if (!l3ActivationMatches(activationGeneration)) return;
        // typed callback可在同指针/同activation下采纳新pub并推进cutoff；旧slot副本不可重绑新目标。
        if (isScopedMenuEvent(event.type) &&
            (targetEpochBeforeTyped != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire) ||
             readSequence < atomic_load_explicit(&g_l3MenuTargetCutoff, memory_order_acquire))) {
            ++readSequence; ++drainedThisCycle; continue;
        }
        if (isScopedMenuEvent(event.type) && !scopedMenuEventValid(event.type, menuScopeEpoch, toolScopeEpoch)) {
            ++readSequence; ++drainedThisCycle; continue;
        }
        if (event.type == EVENT_TYPE_TOUCH_MENU_SCROLL && gestureToken != 0 && gestureToken != g_glfwPointer.token) {
            ++readSequence; ++drainedThisCycle; continue;
        }
        double menuPointX = 0.0, menuPointY = 0.0;
        const bool menuEndMoves = relativeMenuEndMoves(&event, &relative);
        if (!resolveRelativeMenuEvent(1, &event, &relative, g_glfwPointer.token, &menuPointX, &menuPointY)) {
            ++readSequence; ++drainedThisCycle; continue;
        }
        switch (event.type) {
            case AMCL_LOOK_PREFIX_EVENT: {
                // 只解释本记录冻结token；后续动作不能再取本帧future累计坐标。
                const uint64_t token=(uint32_t)event.i1|((uint64_t)(uint32_t)event.i2<<32);
#if AMCL_INPUT_TRACE
                // 只给已经验证和复制的原slot记读取，peek/过期/截止阻挡不触此点。
                AmclInputLatencyV1 note;memset(&note,0,sizeof(note));note.prefix=token;note.ringSequence=readSequence+1;
                note.ringOrder=interactionOrder;amclInputLatencyNoteV1(AMCL_ILAT_READ,&note);
#endif
                if(g_lookPrefixCallback)(void)g_lookPrefixCallback(window,token);
                break;
            }
            case EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR:
            case EVENT_TYPE_TOUCH_MENU_CURSOR:
                if (!scopedMenuEventValid(event.type, menuScopeEpoch, toolScopeEpoch)) break;
                // 下游游戏只看到既有1010；域身份在此资格检查后不再泄漏到游戏接口。
                event.type = EVENT_TYPE_CURSOR_POSITION;
                /* fall through */
            case EVENT_TYPE_CURSOR_POSITION: {
                consumeOrderedCursor(&event, 1);
                double x = 0.0, y = 0.0;
                if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire) &&
                    bridgeTakeCursorChange(&x, &y) && hasGlfwCursorCallback()) {
                    if (!submitGlfwMenuCursor(window, x, y, interactionOrder, activationGeneration)) return;
                }
                break;
            }
            case EVENT_TYPE_CHAR:
                // 字符事件容错（2026-05-30）：现代 MC 注册的是 charMods 回调（GLFWCharModsCallback），
                // 不一定注册纯 char 回调。若 g_invoke_Char 为空就回退走 charMods（mods=0），
                // 否则聊天框收不到字符（按键事件正常是因为 MC 一定注册了 key 回调）。
                if (g_charLogBudget > 0) {
                    g_charLogBudget--;
                    LOGI("InputBridge: CHAR cp=%d char=%p charMods=%p", event.i1,
                         (void*)(uintptr_t)g_invoke_Char, (void*)(uintptr_t)g_invoke_CharMods);
                }
                if (g_invoke_Char) {
                    g_invoke_Char(window, event.i1);
                } else if (g_invoke_CharMods) {
                    g_invoke_CharMods(window, event.i1, 0);
                }
                break;
            case EVENT_TYPE_CHAR_MODS:
                if (g_invoke_CharMods) {
                    g_invoke_CharMods(window, event.i1, event.i2);
                } else if (g_invoke_Char) {
                    g_invoke_Char(window, event.i1);
                }
                break;
            case EVENT_TYPE_CURSOR_ENTER:
                if (g_invoke_CursorEnter) g_invoke_CursorEnter(window, event.i1);
                break;
            case EVENT_TYPE_KEY:
                if (event.i1 == 340) {
                    pthread_mutex_lock(&g_downMutex);
                    const bool emitted = applyMenuToolEvent(&g_l3LeftContribution, &g_l3MenuTool,
                                                            &event, false, menuScopeEpoch);
                    pthread_mutex_unlock(&g_downMutex);
                    if (emitted) dispatchGlfwToolEdge(window, &event);
                    break;
                }
                // 多键轮询状态（2026-05-30）：所有来源（NAPI 虚拟按键 / native 触摸 / Java）
                // 的按键事件在此统一更新 g_keyDownBuffer，使 glfwGetKey() 能反映"键是否按住"。
                // MC 的 F3+F4 切游戏模式靠 glfwGetKey(F3) 轮询判断 F3 是否按住——之前只有
                // nativeSendKey（Java 路径）更新该 buffer，虚拟按键走 NAPI 不更新 → F3+F4 不触发。
                if (event.i1 >= 0 && event.i1 < 512) {
                    pthread_mutex_lock(&g_downMutex);
                    g_keyDownBuffer[event.i1] = (event.i3 != 0) ? 1 : 0;
                    pthread_mutex_unlock(&g_downMutex);
                }
                if (g_invoke_Key) g_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MENU_POINTER: {
                // i1=phase, i2=x, i3=y, i4=稳定 transaction token。坐标与阶段位于同一 ring 槽；
                // token 使旧 finger id 复用、迟到 UP 或 lifecycle CANCEL 都不能结束后来的点击。
                const uint32_t token = (uint32_t)event.i4;
                const bool isDown = event.i1 == MENU_POINTER_DOWN;
                const bool isBegin = event.i1 == MENU_POINTER_BEGIN;
                if (menuScopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire)) break;
                if ((isDown || isBegin) && g_l3TargetIdentityRequired &&
                    g_l3InputTargetWindow != (uint64_t)(uintptr_t)window) break;
                if (token == 0 || event.i1 < MENU_POINTER_MOVE || event.i1 > MENU_POINTER_END) break;
                if ((isDown || isBegin) && !acceptMenuGestureStart(1, event.i1, token,
                        g_glfwPointer.token, g_glfwPointer.gestureBegun, g_glfwPointer.buttonDown || g_glfwPointer.pressPending, g_glfwPointer.downAccepted)) break;
                if (isBegin && queuedMenuInvalidates(token, menuScopeEpoch, readSequence + 1ULL, targetSequence, maxOrder, true)) break;

                if (isDown || isBegin) {
                    // 新 DOWN 覆盖旧事务前必须先完整结束旧事务；特别是旧 PRESS 已发时要补 RELEASE。
                    if ((g_glfwPointer.token != 0 || g_glfwPointer.pressPending || g_glfwPointer.buttonDown) &&
                        !amclPointerIsContinuation(event.i1, token, g_glfwPointer.token,
                            g_glfwPointer.gestureBegun, g_glfwPointer.buttonDown || g_glfwPointer.pressPending, g_glfwPointer.downAccepted)) {
                        cancelMenuTransaction(window, true);
                        if (!l3ActivationMatches(activationGeneration)) return;
                    }
                    g_menuTargetWindow = window;
                    g_menuPresentedWindow = (uint64_t)(uintptr_t)window;
                    g_menuPresentedGeneration = g_glfwPresentedWindow == g_menuPresentedWindow
                        ? g_glfwPresentedGeneration : 0;
                    g_menuPresentedIdentity = g_menuPresentedGeneration != 0 ? g_glfwPresentedIdentity : 0;
                }
                const AmclPointerPlan plan = amclPointerAccept(&g_glfwPointer, &g_glfwPointerPolicy,
                    event.i1, token, menuPointX, menuPointY, menuEndMoves, interactionOrder,
                    menuMonotonicNowNs(), menuScopeEpoch,
                    atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire));
                if (!plan.accepted) break;

                // CANCEL 的坐标没有语义（lifecycle/grab 可能没有新采样），不能把占位 0,0
                // 写成可见菜单位置；DOWN/MOVE/UP 才更新 absolute cursor。
                if (plan.position) {
                    inputBridge_setMenuCursor(menuPointX, menuPointY);
                    updateCurrentMenuCursor(1, menuPointX, menuPointY);
                    double menuReportX = 0.0, menuReportY = 0.0;
                    if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire) &&
                        bridgeTakeCursorChange(&menuReportX, &menuReportY) && hasGlfwCursorCallback()) {
                        if (!submitGlfwMenuCursor(window, menuReportX, menuReportY, interactionOrder, activationGeneration)) return;
                    }
                }

                if (isDown && !atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
                    // 源点 callback 已返回，先核原 tuple 再取真实 clock；旧回调不能重建 pending。
                    if (g_glfwPointer.token == token && g_glfwPointer.scopeEpoch == menuScopeEpoch &&
                        g_glfwPointer.inputTargetEpoch == atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire)) {
                        refreshGlfwPresentationState();
                        amclPointerSourceDelivered(&g_glfwPointer, g_presentSerial, &g_glfwPointerPolicy);
                    }
                }
                if (plan.contribution >= 0)
                    submitGlfwLeftContribution(window, true, plan.contribution != 0, true, 0);
                if (event.i1 == MENU_POINTER_CANCEL || event.i1 == MENU_POINTER_END) g_menuTargetWindow = NULL;
                break;
            }
            case EVENT_TYPE_MOUSE_BUTTON:
                // ordinary RELEASE只退休生产ledger聚合贡献；不取消另一手指仍有效的menu token。
                if (event.i1 == GLFW_MOUSE_BUTTON_LEFT || event.i1 == GLFW_MOUSE_BUTTON_RIGHT) {
                    if (event.i2 != GLFW_PRESS && event.i2 != GLFW_RELEASE) break;
                    pthread_mutex_lock(&g_downMutex);
                    const bool emitted = applyMenuToolEvent(&g_l3LeftContribution, &g_l3MenuTool,
                                                            &event, false, menuScopeEpoch);
                    pthread_mutex_unlock(&g_downMutex);
                    if (emitted) dispatchGlfwToolEdge(window, &event);
                    break;
                }
                // 鼠标按键轮询状态（glfwGetMouseButton）。MOUSE_BUTTON 的 i1=button、i2=action。
                if (event.i1 >= 0 && event.i1 < 16) {
                    pthread_mutex_lock(&g_downMutex);
                    g_mouseDownBuffer[event.i1] = (event.i2 != 0) ? 1 : 0;
                    pthread_mutex_unlock(&g_downMutex);
                }
                if (g_invoke_MouseButton) g_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_TOUCH_MENU_TOOL: {
                if (!scopedMenuEventValid(event.type, menuScopeEpoch, toolScopeEpoch)) break;
                pthread_mutex_lock(&g_downMutex);
                const bool emitted = applyMenuToolEvent(&g_l3LeftContribution, &g_l3MenuTool,
                                                        &event, true, toolScopeEpoch);
                pthread_mutex_unlock(&g_downMutex);
                if (emitted) dispatchGlfwToolEdge(window, &event);
                break;
            }
            case EVENT_TYPE_SCROLL:
                if (g_invoke_Scroll) g_invoke_Scroll(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_TOUCH_MENU_SCROLL:
            case EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL:
                if (scopedMenuEventValid(event.type, menuScopeEpoch, toolScopeEpoch) && g_invoke_Scroll)
                    g_invoke_Scroll(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_INPUT_RESET:
                // ⚠️ **刻意无操作，而且这个 case 必须显式存在。**
                // 它是给 LWJGL2 Java 侧清自己 polling arrays 用的标记（见该宏的定义处），
                // 从来不进 GLFW3 回调。若让它落到下面的 `default`，那个"未知类型"计数器
                // 就会在每次 ring 恢复后持续上升 —— 一个恒非零的告警计数器会被下一轮判读
                // 当成噪声，那正是"计数器不可信比没有计数器更糟"。
                break;
            default:
                // 未知类型：**不再静默丢弃**。理由与限流形状见 `recordUnknownRingEvent`。
                recordUnknownRingEvent(event.type);
                break;
        }

        readSequence++;
        // 计"从 ring 里取出并解释过"的条数，不是"投给 MC 的回调数"：后者会被回调未注册、
        // grabbed 抑制、菜单屏障等合法情形拉低，用它当判据会把正常状态误报成故障。
        ++drainedThisCycle;
        // switch中的任意用户回调都可同步Hide/Show/Destroy。代次变化时立即退出，
        // 保留新生命周期已经发布的read cursor，下一poll从新baseline开始。
        if (!l3ActivationMatches(activationGeneration)) {
            notePumpCycle(drainedThisCycle);
            return;
        }
    }
    if (!l3ActivationMatches(activationGeneration)) return;
    atomic_store_explicit(&g_l3ReadSequence, readSequence, memory_order_release);
    // 队列已空也需要推进 PRESS；有 pending 时最终 typed flush 上限仍停在原DOWN之前。
    (void)advanceGlfwMenuPending(window, readSequence, targetSequence, maxOrder, activationGeneration);
    if (!l3ActivationMatches(activationGeneration)) return;
    const uint64_t typedCeiling = g_glfwPointer.pressPending && g_glfwPointer.pendingOrder <= maxOrder
        ? g_glfwPointer.pendingOrder - 1ULL : maxOrder;
    if (pump && !pump(context, typedCeiling)) return;
    if (!l3ActivationMatches(activationGeneration)) return;
    // 所有本轮 typed 相对增量加工后再通知累计视角；菜单绝对位置只从有序记录通知。
    if (!g_lookPrefixCallback && (g_shouldUpdateMouse || pump) && hasGlfwCursorCallback() &&
        atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
        double reportX = 0.0, reportY = 0.0;
        bridgeCursorSnapshot(&reportX, &reportY);
        if (g_invoke_CursorReceipt) (void)g_invoke_CursorReceipt(window, floor(reportX), floor(reportY));
        else g_invoke_CursorPos(window, floor(reportX), floor(reportY));
        if (!l3ActivationMatches(activationGeneration)) return;
        // 时延埋点的 out 端。**必须在回调之后**：我们要测的是"MC 看见它"的时刻，
        // 而不是"我们决定要报"的时刻 —— 回调本身是 MC 的代码，可能同步做不少事。
        // ⚠️ 只有这一处结算。菜单绝对坐标那条上报（下方 MENU_POINTER 分支）刻意不碰，
        // 理由见 `noteLookSampleReported` 上方第三条判据。
        noteLookSampleReported();
    }

    notePumpCycle(drainedThisCycle);
}

void inputBridgeStopPumping(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->stopPumping(); return; }
    // readSequence 已在 PumpEvents 发布给 producer；Stop 只结束本轮 cursor 通知。
    g_shouldUpdateMouse = false;
}

// GLFW局部窗口资格。只移动L3游标并撤销其已投递的legacy边沿；不触发宿主退出、
// 不清producer ledger，不移动L2/SDL游标。所有Minecraft回调都在producer锁外执行。
JNIEXPORT void inputBridge_glfwSetActive(void* window, int active) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, glfwSetActive))
            owner->glfwSetActive(window, active);
        return;
    }
    atomic_store_explicit(&g_l3ExplicitActivation, true, memory_order_release);
    const bool desired = active != 0;
    const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
    if(look)(void)look->setBackendActive(1,desired&&g_lookPrefixCallback?1u:0u);
    pthread_mutex_lock(&g_pushMutex);
    const bool before = atomic_exchange_explicit(&g_l3Active, desired, memory_order_acq_rel);
    if (before != desired) {
        atomic_fetch_add_explicit(&g_l3ActivationGeneration, 1ULL, memory_order_acq_rel);
        const unsigned long long write = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
        atomic_store_explicit(&g_l3ReadSequence, write, memory_order_release);
        atomic_store_explicit(&g_l3OverflowPending, false, memory_order_release);
        g_l3TargetSequence = write;
        g_l3RecoveryPending = false;
        g_shouldUpdateMouse = false;
        // 新激活会话等待自己的第一次真实swap身份，旧窗口的帧计数资格不能承接。
    }
    pthread_mutex_unlock(&g_pushMutex);
    if (before != desired) {
        resetGlfwPresentationIdentity();
        resetCommittedMenuCursor(1, desired);
    }
    if (before && !desired) {
        const unsigned long long generation = atomic_load_explicit(
            &g_l3ActivationGeneration, memory_order_acquire);
        cancelMenuTransaction(window, true);
        if (!l3ActivationMatches(generation)) return;
        clearConsumedDownState(window, true);
        if (!l3ActivationMatches(generation)) return;
        if (g_lastPumpWindow == window) g_lastPumpWindow = NULL;
    }
}

/** GLFW渲染owner发布真实逻辑指针、Native输入发布代次和WSI稳定windowId的映射。
 * setter不调用游戏，几何/目标变更以本consumer epoch和严格cutoff退休；下一pump才交付释放。
 * WSI windowId来自GLFWwindow的生命周期counter，绝不能把它当作GLFWwindow*强转比较。
 */
JNIEXPORT void inputBridge_glfwSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) {
        if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, glfwSetTarget)) owner->glfwSetTarget(window, generation, wsiIdentity);
        return;
    }
    if ((window == 0) != (generation == 0) || (window == 0 && wsiIdentity != 0)) return;
    if (window != 0) g_l3TargetIdentityRequired = true;
    if (g_l3InputTargetWindow == window && g_l3InputTargetGeneration == generation &&
        g_l3WsiPresentationIdentity == wsiIdentity) return;
    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long cutoff = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    atomic_store_explicit(&g_l3MenuTargetCutoff, cutoff, memory_order_release);
    atomic_fetch_add_explicit(&g_l3InputTargetEpoch, 1ULL, memory_order_release);
    pthread_mutex_unlock(&g_pushMutex);
    g_l3InputTargetWindow = window;
    g_l3InputTargetGeneration = generation;
    g_l3WsiPresentationIdentity = wsiIdentity;
    targetCommittedMenuCursor(1, window, generation, wsiIdentity);
    targetCommittedMenuCursor(2, window, generation, wsiIdentity);
    pthread_mutex_lock(&g_downMutex);
    if (g_l3MenuTool.left || g_l3MenuTool.right || g_l3MenuTool.shift)
        g_l3MenuTool.epoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire) - 1ULL;
    if (g_l2MenuTool.left || g_l2MenuTool.right || g_l2MenuTool.shift)
        g_l2MenuTool.epoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire) - 1ULL;
    pthread_mutex_unlock(&g_downMutex);
    // 输入代次不冒充图形lease代次；新候选由该真实目标的首帧重新认领实际render identity。
    pthread_mutex_lock(&g_glfwPresentationMutex);
    g_glfwPresentationClock.targetWindow = window;
    g_glfwPresentationClock.wsiIdentity = wsiIdentity;
    g_glfwPresentationClock.targetRequired = g_l3TargetIdentityRequired;
    g_glfwPresentationClock.window = g_glfwPresentationClock.generation = g_glfwPresentationClock.identity = 0;
    pthread_mutex_unlock(&g_glfwPresentationMutex);
    g_glfwPresentedWindow = g_glfwPresentedGeneration = g_glfwPresentedIdentity = 0;
}

// ============================================================
//  Cross-.so bridge: publish internal state addresses via env var
//  NAPI (in libentry.so) reads these pointers to inject touch events
//  directly into this buffer, eliminating the separate glfw_bridge.c
// ============================================================

// v7 是唯一接受的跨 .so ABI：发布四个受同步保护的操作函数，加一对 grab 事务函数；
// 不发布任何坐标或 ring 内部地址。
// libentry 若解析不到完整 v7 会 fail closed；禁止恢复 v1-v6 fallback，因为它们缺少当前同步契约、
// 无锁多生产者写 ring 或 double 撕裂。协议字段变化必须同时升级版本与 touch_input 解析器。
//
// 历史：曾短暂存在过一个 v8（多一个 trackMenuPointerFn 槽位，用于"菜单虚拟光标 + warp 偏移"）。
// 该模型在真机上把悬浮/点击判定与可见的系统指针箭头分离，已整体回退，槽位随之删除。
#define INPUT_BRIDGE_PROTO_MAGIC "AMCLINPV"
#define INPUT_BRIDGE_PROTO_VERSION 7

// SDL3 消费端通道（见 inputBridge_publishAddress 末尾）。独立于 v7 演进：
// 解析方是 prebuilt/sdl3/patches 里的 SDL_openharmonyamcl.c，两侧必须同版本。
#define INPUT_BRIDGE_SDL_PROTO_MAGIC "AMCLSDLV"
#define INPUT_BRIDGE_SDL_PROTO_VERSION 3

// 把本 image 的整张函数表填好并经 env 发布，同时把本 image 的角色钉成 owner。
//
// ⚠️ **只有拥有 XComponent 的那份 image 允许走到这里**（调用点在 glfw_compat.cpp 的
// `glfwOHOS_PublishNativeWindow` 与 `glfwInit` 的 `g_ohosNativeWindow != nullptr` 分支）。
// 若一份已经解析出 owner 的 image 仍来发布，那是接线错误，必须 fail closed 而不是把
// 所有消费者指向一份没有生产者的私有 ring —— 那正是 2026-09-01 那次回归的后果。
static bool publishBridgeInstanceDescriptor(void) {
    if (atomic_load_explicit(&g_bridgeOwner, memory_order_acquire) ==
        INPUT_BRIDGE_OWNER_SELF) {
        // 已发布过就**整段跳过，连 setenv 也不重做**：重发要重填一张内容恒等、正被另一份
        // image 并发解引用的表，而 setenv 同名覆盖会释放读者可能正持有的旧串（I27-05）。
        return true;
    }
    const InputBridgeInstanceV1* existingOwner = bridgeDelegate();
    if (existingOwner != NULL) {
        LOGE("InputBridge refusing to publish: this image already delegates to "
             "table=%{public}p (only the XComponent-owning image may publish)",
             (const void*)existingOwner);
        return false;
    }

    g_bridgeInstance.abiVersion = AMCL_LEGACY_BRIDGE_INSTANCE_VERSION;
    g_bridgeInstance.structSize = (unsigned int)sizeof(InputBridgeInstanceV1);
    g_bridgeInstance.pushEvent = &inputBridge_pushEvent;
    g_bridgeInstance.addLookDelta = &inputBridge_addLookDelta;
    g_bridgeInstance.addSourceLookDelta = &inputBridge_addSourceLookDelta;
    g_bridgeInstance.sdlGetNonPhysicalCursorSnapshot = &inputBridge_sdlGetNonPhysicalCursorSnapshot;
    g_bridgeInstance.glfwSetActive = &inputBridge_glfwSetActive;
    g_bridgeInstance.legacyRingDiscontinuityEpoch =
        &inputBridge_legacyRingDiscontinuityEpochV1;
    g_bridgeInstance.setMenuCursor = &inputBridge_setMenuCursor;
    g_bridgeInstance.setLookCursor = &inputBridge_setLookCursor;
    g_bridgeInstance.notifyFramePresented = &inputBridge_notifyFramePresented;
    g_bridgeInstance.setWindowSize = &inputBridge_setWindowSize;
    g_bridgeInstance.getCursorSnapshot = &inputBridge_getCursorSnapshot;
    g_bridgeInstance.getWindowSizeSnapshot = &inputBridge_getWindowSizeSnapshot;
    g_bridgeInstance.isGrabbing = &inputBridge_isGrabbing;
    g_bridgeInstance.getKeyDownBuffer = &inputBridge_getKeyDownBuffer;
    g_bridgeInstance.getMouseDownBuffer = &inputBridge_getMouseDownBuffer;
    g_bridgeInstance.getKeyDown = &bridgeQueryKeyDown;
    g_bridgeInstance.getMouseDown = &bridgeQueryMouseDown;
    g_bridgeInstance.setGrabState = &inputBridge_setGrabState;
    g_bridgeInstance.beginPhysicalMotionTransaction =
        &inputBridge_beginPhysicalMotionTransaction;
    g_bridgeInstance.endPhysicalMotionTransaction =
        &inputBridge_endPhysicalMotionTransaction;
    g_bridgeInstance.cancelMenuTransaction = &inputBridge_cancelMenuTransaction;
    g_bridgeInstance.cancelAllState = &inputBridge_cancelAllState;
    g_bridgeInstance.setMcExitCallback = &inputBridge_setMcExitCallback;
    g_bridgeInstance.setInputReady = &inputBridge_setInputReady;
    g_bridgeInstance.setCursorPosCallback = &inputBridge_setCursorPosCallback;
    g_bridgeInstance.setMouseButtonCallback = &inputBridge_setMouseButtonCallback;
    g_bridgeInstance.setKeyCallback = &inputBridge_setKeyCallback;
    g_bridgeInstance.setScrollCallback = &inputBridge_setScrollCallback;
    g_bridgeInstance.replaceCharCallback = &inputBridge_replaceCharCallback;
    g_bridgeInstance.replaceCharModsCallback =
        &inputBridge_replaceCharModsCallback;
    g_bridgeInstance.replaceCursorEnterCallback =
        &inputBridge_replaceCursorEnterCallback;
    g_bridgeInstance.dispatchCursorEnter = &inputBridge_dispatchCursorEnter;
    g_bridgeInstance.dispatchCharCodepoint = &inputBridge_dispatchCharCodepoint;
    g_bridgeInstance.startPumping = &inputBridgeStartPumping;
    g_bridgeInstance.pumpEvents = &inputBridgePumpEvents;
    g_bridgeInstance.pumpOrdered = &inputBridge_pumpOrdered;
    g_bridgeInstance.sdlPeekOrder = &inputBridge_sdlPeekOrder;
    g_bridgeInstance.sdlNextThrough = &inputBridge_sdlNextThrough;
    g_bridgeInstance.publishMenuCursor = &inputBridge_publishMenuCursor;
    g_bridgeInstance.retireTouchMenuScope = &inputBridge_retireTouchMenuScopeV1;
    g_bridgeInstance.notifyFramePresentedForTarget = &inputBridge_notifyFramePresentedForTargetV1;
    g_bridgeInstance.pushTouchMenuTool = &inputBridge_pushTouchMenuToolV1;
    g_bridgeInstance.publishTouchMenuCursor = &inputBridge_publishTouchMenuCursorV1;
    g_bridgeInstance.sdlSetTarget = &inputBridge_sdlSetTargetV1;
    g_bridgeInstance.sdlNotifyFramePresentedForTarget = &inputBridge_sdlNotifyFramePresentedForTargetV1;
    g_bridgeInstance.glfwSetTarget = &inputBridge_glfwSetTargetV1;
    g_bridgeInstance.retireTouchMenuToolScope = &inputBridge_retireTouchMenuToolScopeV1;
    g_bridgeInstance.publishTouchMenuScroll = &inputBridge_publishTouchMenuScrollV1;
    g_bridgeInstance.pushTouchMenuToolScroll = &inputBridge_pushTouchMenuToolScrollV1;
    g_bridgeInstance.publishTouchMenuToolCursor = &inputBridge_publishTouchMenuToolCursorV1;
    g_bridgeInstance.configureMenuCursorConsumer = &inputBridge_configureMenuCursorConsumerV1;
    g_bridgeInstance.getCommittedMenuCursor = &inputBridge_getCommittedMenuCursorV1;
    g_bridgeInstance.beginGlfwMenuCursor = &inputBridge_beginGlfwMenuCursorV1;
    g_bridgeInstance.completeGlfwMenuCursor = &inputBridge_completeGlfwMenuCursorV1;
    g_bridgeInstance.publishTouchMenuToolRelative = &inputBridge_publishTouchMenuToolRelativeV1;
    g_bridgeInstance.publishTouchMenuRelative = &inputBridge_publishTouchMenuRelativeV1;
    g_bridgeInstance.setCursorReceiptCallback = &inputBridge_setCursorReceiptCallbackV1;
    g_bridgeInstance.readSurfaceContext = &inputBridge_readSurfaceContextV1;
    g_bridgeInstance.lookTransportVersion = AMCL_LOOK_TRANSPORT_VERSION;
    g_bridgeInstance.getLookResource = &inputBridge_getLookResourceV1;
    g_bridgeInstance.submitLook = &inputBridge_submitLookV1;
    g_bridgeInstance.beginLookAction = &inputBridge_beginLookActionV1;
    g_bridgeInstance.beginSourceAction = &inputBridge_beginSourceActionV1;
    g_bridgeInstance.endLookAction = &inputBridge_endLookActionV1;
    g_bridgeInstance.setLookPrefixCallback = &inputBridge_setLookPrefixCallbackV1;
    g_bridgeInstance.submitProcessedLook = &inputBridge_submitProcessedLookV1;
#if AMCL_INPUT_TRACE
    g_bridgeInstance.latencyVersion=1;
    g_bridgeInstance.noteInputLatency=&inputBridge_noteInputLatencyV1;
    g_bridgeInstance.finishInputLatency=&inputBridge_finishInputLatencyV1;
    g_bridgeInstance.drainInputLatency=&inputBridge_drainInputLatencyV1;
    g_bridgeInstance.latencyTicketVersion=1;
    g_bridgeInstance.finishInputLatencyTicket=&inputBridge_finishInputLatencyTicketV1;
#endif
    g_bridgeInstance.stopPumping = &inputBridgeStopPumping;
    g_bridgeInstance.l2NextEvent = &inputBridge_l2NextEvent;
    g_bridgeInstance.l2SetActive = &inputBridge_l2SetActive;
    g_bridgeInstance.sdlNextEvent = &inputBridge_sdlNextEvent;
    g_bridgeInstance.sdlSetActive = &inputBridge_sdlSetActive;
    g_bridgeInstance.sdlNotifyFramePresented =
        &inputBridge_sdlNotifyFramePresented;

    // 表填满之后才发布地址：读方一旦看见 env 就会立刻解引用。⚠️ 这道 release 栅栏是**必需**
    // 的，不能靠 `setenv` 内部的锁：读方在另一个线程、另一份 image 上，aarch64 允许它先看到
    // env 再看到半张表。解析侧有配对的 acquire 栅栏。
    atomic_thread_fence(memory_order_release);
    char descriptor[AMCL_LEGACY_BRIDGE_INSTANCE_ENV_CAPACITY];
    const AmclLegacyBridgeDescriptorStatus status =
        amclLegacyBridgeEncodeInstanceEnv(
            descriptor, sizeof(descriptor),
            (unsigned long long)(uintptr_t)&g_bridgeInstance);
    if (status != AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK) {
        LOGE("InputBridge instance descriptor encode failed status=%{public}d",
             (int)status);
        return false;
    }
    setenv(AMCL_LEGACY_BRIDGE_INSTANCE_ENV, descriptor, 1);
    atomic_store_explicit(&g_bridgeOwner, INPUT_BRIDGE_OWNER_SELF,
                          memory_order_release);
    return true;
}

// 三个描述符（实例、v7、SDL 通道）都只含本 image 的函数/表地址，是进程常量。成功发布一次后
// 置位，之后 surface 重建、glfwInit 与 libentry 早期发布的重复调用都直接返回，不再碰 environ
// （I27-05：游戏线程上的 glfwInit 重发曾会释放并发读者持有的旧串）。
static atomic_bool g_bridgeAddressPublished = false;

void inputBridge_publishAddress(void) {
    if (atomic_load_explicit(&g_bridgeAddressPublished, memory_order_acquire)) return;
    // ⭐ 实例描述符必须**先**发布，且它失败就整体不发：v7 与 SDL 通道公布的是**本 image**
    // 的函数地址，从一份非 owner 的 image 发出去，等于把生产者与 SDL 一起指向一条没有
    // XComponent 的私有 ring —— 那正是 2026-09-01 那次回归的后果，必须 fail closed。
    if (!publishBridgeInstanceDescriptor()) {
        LOGE("InputBridge: refusing to publish v7/SDL channels from a non-owner "
             "image (see the cross-image delegation section)");
        return;
    }

    // v7 格式："<MAGIC>:7:addLookFn,setMenuFn,isGrabFn,pushFn,beginGrabFn,endGrabFn,windowSize"
    char buf[256];
    snprintf(buf, sizeof(buf), "%s:%d:%llu,%llu,%llu,%llu,%llu,%llu,%d",
             INPUT_BRIDGE_PROTO_MAGIC, INPUT_BRIDGE_PROTO_VERSION,
             (unsigned long long)(uintptr_t)&inputBridge_addLookDelta,
             (unsigned long long)(uintptr_t)&inputBridge_publishMenuCursor,
             (unsigned long long)(uintptr_t)&inputBridge_isGrabbing,
             (unsigned long long)(uintptr_t)&inputBridge_pushEvent,
             (unsigned long long)(uintptr_t)&inputBridge_beginPhysicalMotionTransaction,
             (unsigned long long)(uintptr_t)&inputBridge_endPhysicalMotionTransaction,
             EVENT_WINDOW_SIZE);
    setenv("OHOS_INPUT_BRIDGE", buf, 1);

    // ── SDL3 消费端专用通道（MC 26.3+）────────────────────────────────────
    //
    // 为什么必须走 env，而不是让 SDL 侧 dlsym 找我们：
    //   2026-08-04 真机实测，libSDL3 是被 MC 的 JVM（class loader namespace）
    //   dlopen 进来的，而本库是宿主 libentry 的 DT_NEEDED 依赖。从 libSDL3 那侧：
    //     · dlsym(RTLD_DEFAULT, "inputBridge_*")        → 5 个全 NULL
    //     · dlopen("libglfw.so", RTLD_NOLOAD|RTLD_NOW)  → NULL
    //   即 OHOS 的 linker namespace 隔离让「按符号找」和「按名字找已加载实例」
    //   两条路都走不通，SDL 侧只能报 "no host input bridge" 然后整体退化为无输入。
    //   env 是本项目既有的、已验证可跨 namespace 的通道（窗口宿主 broker 描述符同理）。
    //
    // 刻意另开一个变量：SDL 有独立预编译解析方，不应与 libentry 的 v7
    // 生命周期/物理事务协议耦合；新增变量对两侧演进都透明。
    //
    // v2 发布的是 SDL 后端真正需要的七个函数，全部是受同步保护的操作入口 ——
    // 与 v7 同一条纪律：不发布任何坐标、ring 内部地址或状态变量。
    //   sdlNextEvent      SDL 专属消费游标（与 LWJGL2/3 的读位置互不抢占）
    //   sdlSetActive      SDL window 生命周期边界；禁止事务跨窗口/会话复用
    //   sdlNotifyPresent  只由成功的 SDL swap 推进，解锁 move-after-present 的 PRESS
    //   setGrabState      grab 的单一权威写点
    //   isGrabbing        grab 查询
    //   getCursorSnapshot 两轴成对原子读（避免撕裂出跨坐标系的假位移）
    //   setLookCursor     SDL_WarpMouseInWindow → 记录调用方认为的光标基准
    {
        // 有序扩展先于 legacy 描述符发布，SDL 一旦观察到后者即可原子选择完整四槽契约。
        // 序号/fence 始终来自本 owner，避免链接 namespace 各有一套静态计数器。
        char orderbuf[192];
        snprintf(orderbuf, sizeof(orderbuf), "AMCLORDER:1:%llu,%llu,%llu,%llu",
                 (unsigned long long)(uintptr_t)&amclInputInteractionFence,
                 (unsigned long long)(uintptr_t)&amclBackendInputNextThrough,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlPeekOrder,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNextThrough);
        setenv("AMCL_INPUT_ORDER_BRIDGE", orderbuf, 1);
        // 新SDL尾协议整体先发布；旧两份协议及其字段顺序保持原样。
        char touchbuf[128];
        snprintf(touchbuf, sizeof(touchbuf), "AMCLSDLTOUCH:1:%llu,%llu",
                 (unsigned long long)(uintptr_t)&inputBridge_sdlSetTargetV1,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNotifyFramePresentedForTargetV1);
        setenv("AMCL_SDL_TOUCH_BRIDGE", touchbuf, 1);
        char sdlbuf[256];
        snprintf(sdlbuf, sizeof(sdlbuf), "%s:%d:%llu,%llu,%llu,%llu,%llu,%llu,%llu",
                 INPUT_BRIDGE_SDL_PROTO_MAGIC, INPUT_BRIDGE_SDL_PROTO_VERSION,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNextEvent,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlSetActive,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNotifyFramePresented,
                 (unsigned long long)(uintptr_t)&inputBridge_setGrabState,
                 (unsigned long long)(uintptr_t)&inputBridge_isGrabbing,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlGetNonPhysicalCursorSnapshot,
                 (unsigned long long)(uintptr_t)&inputBridge_setLookCursor);
        setenv("AMCL_SDL_INPUT_BRIDGE", sdlbuf, 1);
    }
    atomic_store_explicit(&g_bridgeAddressPublished, true, memory_order_release);

    LOGI("InputBridge: published function ABI magic=%{public}s ver=%{public}d "
         "(+ SDL channel %{public}s v%{public}d, instance %{public}s v%{public}u)",
         INPUT_BRIDGE_PROTO_MAGIC, INPUT_BRIDGE_PROTO_VERSION,
         INPUT_BRIDGE_SDL_PROTO_MAGIC, INPUT_BRIDGE_SDL_PROTO_VERSION,
         AMCL_LEGACY_BRIDGE_INSTANCE_MAGIC, AMCL_LEGACY_BRIDGE_INSTANCE_VERSION);
}

// ============================================================
//  JNI: CallbackBridge native methods
//  Called from org.lwjgl.glfw.CallbackBridge (Java, MC's JVM)
// ============================================================

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorPos(void* env, void* clazz, jfloat x, jfloat y) {
    // MC → native 主动设置光标（罕见；grabbed 态 MC 不走此路）。绝对位置只进入 menu 坐标，
    // 绝不能覆盖 look 累加基准。
    inputBridge_publishMenuCursor((double)x, (double)y);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendMouseButton(void* env, void* clazz, jint button, jint action, jint mods) {
    // 公共签名没有 device/contact，只授予 source0 自己的兼容持有。与旧 NAPI source0
    // 共用 neutral registry；无配对 UP 不能直接清 legacy plane 进而撤 touch/gamepad。
    // facade 用原 Core/同映像 descriptor 解析唯一 owner，禁止 namespace 本地 ring 回退。
    (void)amclSourceControlCompatEdgeV1(1u,button,0,action,mods);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey(void* env, void* clazz, jint key, jint scancode, jint action, jint mods) {
    // DOWN/REPEAT/UP 都先经过同一兼容贡献事务，原 scancode/mods 只在真实最终边沿编码。
    // 已运输与 consumer 实际写缓存仍是两层；JNI void 不向 Java 伪造游戏已领取的回执。
    (void)amclSourceControlCompatEdgeV1(0u,key,scancode,action,mods);
}

// 多键轮询查询（2026-05-30）：GLFW.glfwGetKey() 经此读 native 维护的按住状态。
// 之前 Java 侧 keyDownBuffer 是个从不被写入的空分配，glfwGetKey 永远返回 RELEASE，
// 导致 MC 的 F3+F4 切游戏模式（靠 glfwGetKey(F3) 轮询）从来不触发。现在所有事件源
// （NAPI 虚拟按键 / native 触摸 / Java 键盘）都在事件泵里更新 g_keyDownBuffer。
JNIEXPORT jint JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeGetKeyDown(void* env, void* clazz, jint key) {
    // 经委派查询而不是直读本地数组：down buffer 与 ring 属同一份状态，读错 image 会让
    // glfwGetKey 恒返回 RELEASE（F3+F4 那类轮询组合键静默失效）。
    return bridgeQueryKeyDown(key);
}

JNIEXPORT jint JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeGetMouseDown(void* env, void* clazz, jint button) {
    return bridgeQueryMouseDown(button);
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendChar(void* env, void* clazz, jchar codepoint) {
    inputBridge_pushEvent(EVENT_TYPE_CHAR, (int)codepoint, 0, 0, 0);
    return 1;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendCharMods(void* env, void* clazz, jchar codepoint, jint mods) {
    inputBridge_pushEvent(EVENT_TYPE_CHAR_MODS, (int)codepoint, mods, 0, 0);
    return 1;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendScroll(void* env, void* clazz, jdouble xoffset, jdouble yoffset) {
    inputBridge_pushEvent(EVENT_TYPE_SCROLL, (int)xoffset, (int)yoffset, 0, 0);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendScreenSize(void* env, void* clazz, jint width, jint height) {
    // Compatibility callers share the same validated write point as XComponent/GLFW surface updates.
    inputBridge_setWindowSize(width, height);
}

// 生命周期握手的权威写点。JNI 入口在 MC 那份 image，而退出回调的注册方在宿主侧 ⇒ 必须
// 委派，否则 `g_mcExitCallback` 与 `g_inputReady` 永远分属两份 image。
JNIEXPORT int inputBridge_setInputReady(int ready) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->setInputReady(ready);
    const bool nextReady = ready != 0;
    const bool wasReady = atomic_exchange_explicit(&g_inputReady, nextReady, memory_order_acq_rel);
    // MC 退出时 glfwTerminate Java 层调用 nativeSetInputReady(false)
    // 这是检测 MC 退出的最可靠信号
    if (!nextReady && wasReady && g_mcExitCallback) {
        LOGI("InputBridge: nativeSetInputReady(false) — MC is terminating, invoking exit callback");
        g_mcExitCallback();
    }
    return wasReady ? 1 : 0;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetInputReady(void* env, void* clazz, jboolean ready) {
    return inputBridge_setInputReady(ready != 0 ? 1 : 0) ? 1 : 0;
}

// ============================================================
//  Grab 变化回调（方案 B）：libentry.so 把它的 C trampoline 指针经环境变量
//  AMCL_GRAB_CB 发布过来（与 OHOS_INPUT_BRIDGE 同一"反向 env 句柄"机制——
//  libglfw→libentry 方向 dlsym 不可靠，故用 env）。这里在 grab 翻转时惰性解析
//  （解析成功即缓存，trampoline 地址稳定不变）并回调，取代 ArkTS 的 300ms 轮询。
//  低频（仅进/出世界等切换时触发），getenv 命中一次即缓存，无热路径开销。
// ============================================================
typedef void (*amcl_grab_change_cb_t)(int grabbing);
static amcl_grab_change_cb_t g_grabChangeCb = NULL;
// 触摸核心 epoch 通知（libentry 轻量 atomic trampoline，与 ArkTS TSFN 回调分离）。
static amcl_grab_change_cb_t g_touchGrabCb = NULL;
// Window recreate 不是普通 grab flip：必须同步清 OutputLedger/finger owner。libentry 通过 env
// 发布这个低频 trampoline，避免 libglfw 反向 dlsym 在不同 linker namespace 下失效。
static amcl_grab_change_cb_t g_touchCancelCb = NULL;

static void resolveTouchCancelCb(void) {
    if (g_touchCancelCb) return;
    const char* p = getenv("AMCL_TOUCH_CANCEL_CB");
    if (!p || !p[0]) return;
    unsigned long long ptr = 0;
    if (sscanf(p, "%llu", &ptr) == 1 && ptr != 0ULL)
        g_touchCancelCb = (amcl_grab_change_cb_t)(uintptr_t)ptr;
}

static void resolveTouchGrabCb(void) {
    if (g_touchGrabCb) return;
    const char* p = getenv("AMCL_TOUCH_GRAB_CB");
    if (!p || !p[0]) return;
    unsigned long long ptr = 0;
    if (sscanf(p, "%llu", &ptr) == 1 && ptr != 0ULL)
        g_touchGrabCb = (amcl_grab_change_cb_t)(uintptr_t)ptr;
}

static void resolveGrabChangeCb(void) {
    if (g_grabChangeCb) return;   // 已解析（trampoline 地址稳定，解析一次即可）
    const char* p = getenv("AMCL_GRAB_CB");
    // libentry 在模块初始化时发布（I27-05）；缺席只见于没有 libentry 的宿主测试等拓扑——下次翻转再试。
    // 解析到地址不代表 ArkTS 已注册回调：未注册时 trampoline 自身是安全的空操作。
    if (!p || !p[0]) return;
    unsigned long long ptr = 0;
    if (sscanf(p, "%llu", &ptr) == 1 && ptr != 0ULL) {
        g_grabChangeCb = (amcl_grab_change_cb_t)(uintptr_t)ptr;
        LOGI("InputBridge: grab-change callback resolved from env");
    }
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(void* env, void* clazz, jboolean grabbing) {
    // Java 兼容路径也汇入同一个状态转换函数，禁止直接改 g_isGrabbing 形成第二权威写点。
    // 这里跑在游戏线程，不写任何环境变量（I27-05）：grab 状态只经原子量对外可见。
    inputBridge_setGrabState(grabbing != 0);
    const bool currentGrab = inputBridge_isGrabbing();
    LOGI("InputBridge: Grab state changed to %{public}d (%{public}s)",
         currentGrab ? 1 : 0, currentGrab ? "grabbed" : "normal");
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetUseInputStackQueue(void* env, void* clazz, jboolean use) {
    // Not needed for OHOS (single JVM), but must exist for CallbackBridge.java
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetWindowAttrib(void* env, void* clazz, jint attrib, jint value) {
    // TODO: handle window attributes if needed
}

// Gamepad buffers (stub for now)
JNIEXPORT jobject_ptr JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadButtonBuffer(void* env, void* clazz) {
    // Return null for now - gamepad not yet supported
    return 0;
}

JNIEXPORT jobject_ptr JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadAxisBuffer(void* env, void* clazz) {
    return 0;
}

// Clipboard (stub - TODO: implement with OHOS pasteboard API)
JNIEXPORT jobject_ptr JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(void* env, void* clazz, jint action, void* copySrc) {
    return 0; // null = no clipboard content
}

// ============================================================
//  Accessors (called from glfw_compat.cpp and NAPI)
// ============================================================

void inputBridge_getCursorSnapshot(double* outX, double* outY) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->getCursorSnapshot(outX, outY); return; }
    double x = 0.0, y = 0.0;
    bridgeCursorSnapshot(&x, &y);
    if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
        pthread_mutex_lock(&g_menuCursorSnapshotMutex);
        const uint32_t backend = g_menuCursorSelectedBackend;
        if ((backend == AMCL_MENU_CURSOR_BACKEND_LWJGL2 || backend == AMCL_MENU_CURSOR_BACKEND_SDL3) &&
            g_menuCursorSelectedPid == menuCursorProcessId() && g_menuCursorSelectedSession != 0) {
            const MenuCursorAuthority* authority = &g_menuCursorAuthorities[backend];
            if (authority->active && authority->target != 0 && authority->publication != 0 && authority->currentInitialized) {
                // 普通getter读本consumer真实current，fullscope清ACK后释放仍在C，不借兄弟provider的B。
                // current不带COMMITTED资格；Native必须单独getCommitted，不能把这里的点作ACK。
                x = authority->currentX; y = authority->currentY;
            }
        }
        pthread_mutex_unlock(&g_menuCursorSnapshotMutex);
    }
    if (outX) *outX = x;
    if (outY) *outY = y;
}
// ⚠️ 这两个经 snapshot 而不是直调 `bridgeCursorSnapshot`：它们是 LWJGL2 后端 dlsym 到的
// 入口，落在 MC 那份 image 上，直读本地坐标会读到一对从未被写过的 0。
double inputBridge_getCursorX(void) {
    double x = 0.0, y = 0.0;
    inputBridge_getCursorSnapshot(&x, &y);
    return x;
}
double inputBridge_getCursorY(void) {
    double x = 0.0, y = 0.0;
    inputBridge_getCursorSnapshot(&x, &y);
    return y;
}
void inputBridge_getWindowSizeSnapshot(int* outWidth, int* outHeight) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->getWindowSizeSnapshot(outWidth, outHeight); return; }
    pthread_mutex_lock(&g_windowSizeMutex);
    if (outWidth) *outWidth = g_windowWidth;
    if (outHeight) *outHeight = g_windowHeight;
    pthread_mutex_unlock(&g_windowSizeMutex);
}
int inputBridge_getWindowWidth(void) {
    int width = 0;
    inputBridge_getWindowSizeSnapshot(&width, NULL);
    return width;
}
int inputBridge_getWindowHeight(void) {
    int height = 0;
    inputBridge_getWindowSizeSnapshot(NULL, &height);
    return height;
}
JNIEXPORT bool inputBridge_isGrabbing(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->isGrabbing();
    return atomic_load_explicit(&g_isGrabbing, memory_order_acquire);
}

// ⚠️ begin/end 必须落在**同一份** image 上，否则拿的是两把不同的递归互斥量，那道
// "旧模式事件一定在边界前提交"的事务栅栏就整体失效。委派保证配对：begin 委派了，
// end 也必然委派（角色一旦解析就不再变）。
JNIEXPORT int inputBridge_beginPhysicalMotionTransaction(int* outGrabbing) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->beginPhysicalMotionTransaction(outGrabbing);
    if (!outGrabbing || !lockPhysicalMotionMode()) return 0;
    *outGrabbing = atomic_load_explicit(
        &g_isGrabbing, memory_order_acquire) ? 1 : 0;
    return 1;
}

JNIEXPORT void inputBridge_endPhysicalMotionTransaction(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->endPhysicalMotionTransaction(); return; }
    unlockPhysicalMotionMode();
}

// real GLFW/Pojav 语义：MC 调 setCursorPos 回中时先记录它要求的 grabbed 基准。
// 真机顺序稳定为 menu cursor → glfwSetCursorPos(center) → setInputMode(DISABLED)。
JNIEXPORT void inputBridge_setLookCursor(double x, double y) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->setLookCursor(x, y); return; }
    if (!isfinite(x) || !isfinite(y)) {
        recordInvalidCursorWrite("look-position");
        return;
    }
    pthread_mutex_lock(&g_cursorMutex);
    g_lastSetCursorX = x;
    g_lastSetCursorY = y;
    // ⚠️ 这里**不能**顺手把菜单光标也移到 (x, y)，尽管真 GLFW 的 glfwSetCursorPos 在 normal
    // 模式下确实是 warp。原因是我们无法移动系统指针箭头：改了菜单光标而箭头不动，MC 的悬浮
    // 与点击判定就会落到箭头之外（真机实测偏移可达整个屏幕）。详见"菜单光标必须是绝对映射"。
    pthread_mutex_unlock(&g_cursorMutex);
}

#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
unsigned long long inputBridge_testInvalidCursorWriteCount(void) {
    return atomic_load_explicit(
        &g_invalidCursorWriteCount, memory_order_relaxed);
}

unsigned long long inputBridge_testUnknownRingEventCount(void) {
    return atomic_load_explicit(
        &g_unknownRingEventCount, memory_order_relaxed);
}

unsigned long long inputBridge_testLookLatencySamples(void) {
    return atomic_load_explicit(&g_lookLatencySamples, memory_order_relaxed);
}

// 当前是否有待报的 look 样本（0 = 无）。测试用它区分"结算了"与"还压着"。
int inputBridge_testLookLatencyPending(void) {
    return atomic_load_explicit(&g_lookPendingSinceNs, memory_order_relaxed) != 0ULL
        ? 1 : 0;
}

unsigned long long inputBridge_testPumpCalls(void) {
    return atomic_load_explicit(&g_l3PumpCalls, memory_order_relaxed);
}

unsigned long long inputBridge_testDrainedRingEvents(void) {
    return atomic_load_explicit(&g_l3DrainedEvents, memory_order_relaxed);
}

// 当前全局写序列，测试据此定位“下一条被读的槽”。
unsigned long long inputBridge_testWriteSequence(void) {
    return atomic_load_explicit(&g_writeSequence, memory_order_acquire);
}

// 把某个序列号的槽标成“已被后来的生产者覆盖”，在单线程测试里确定性地走到三个消费者的
// slot 恢复分支（真实场景里是消费者复制槽时生产者恰好绕环）。只改发布序号，不动事件内容。
void inputBridge_testRetireSlot(unsigned long long sequence) {
    pthread_mutex_lock(&g_pushMutex);
    atomic_store_explicit(&g_events[sequence % EVENT_WINDOW_SIZE].publishedSequence,
                          0ULL, memory_order_relaxed);
    pthread_mutex_unlock(&g_pushMutex);
}
#endif

JNIEXPORT void inputBridge_setGrabState(int grabbing) {
    // grab 是**单一权威状态**：`glfwSetInputMode` 在 MC 那份 image 里写，而触摸生产者经 env
    // 读宿主那份。不委派的话两者永久分家 —— 触摸会一直以为还在菜单态。
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->setGrabState(grabbing); return; }
    const bool nextGrab = (grabbing != 0);
    bool oldGrab = atomic_load_explicit(&g_isGrabbing, memory_order_acquire);
    if (nextGrab == oldGrab) return;

    // grab/window 边界必须同步终止两个后端各自的菜单 token。若 GLFW PRESS 回调正在关闭
    // Screen，本调用会在同一 MC 栈内补出 RELEASE；SDL 不能在这里直接调用 SDL_Send*，
    // 因此只锁存一条 RELEASE，由下一次 SDL pump 在它自己的线程/事件队列里提交。
    cancelMenuTransaction(g_lastPumpWindow, true);
    cancelSdlMenuTransaction();
    cancelL2MenuTransaction();

#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
    atomic_fetch_add_explicit(
        &g_testGrabWriterWaiters, 1u, memory_order_release);
#endif
    if (!lockPhysicalMotionMode()) {
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
        atomic_fetch_sub_explicit(
            &g_testGrabWriterWaiters, 1u, memory_order_release);
#endif
        LOGE("InputBridge: grab mode transaction unavailable; refusing transition");
        return;
    }
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
    atomic_fetch_sub_explicit(
        &g_testGrabWriterWaiters, 1u, memory_order_release);
#endif
    // A callback triggered by cancelMenuTransaction may already have completed
    // the requested transition. Re-read only after owning the transaction fence.
    oldGrab = atomic_load_explicit(&g_isGrabbing, memory_order_acquire);
    if (nextGrab == oldGrab) {
        unlockPhysicalMotionMode();
        return;
    }

    pthread_mutex_lock(&g_cursorMutex);
    if (!nextGrab && oldGrab) {   // grabbed → menu：初始化菜单位置，等待新菜单事务覆盖
        // ⚠️ 这两行看着像"把视角累加量当屏幕坐标用"的 bug，其实是**承重的**，不要"顺手修好"：
        // 它令 g_menu 恰好等于 g_cLast（grabbed 期间 g_cLast 一直跟着 g_look 推进），于是
        // bridgeTakeCursorChange 的去重会把这一条吞掉 —— 效果是"在拿到第一个真实绝对采样之前，
        // 不向 MC 声称任何光标位置"。这正是我们想要的保守行为：ungrab 时**没人知道**系统指针
        // 箭头在哪（grabbed 期间它被隐藏但仍随物理鼠标移动，可能已夹在某条屏幕边上），
        // 任何"聪明"的初值都是猜的，猜错就会让悬浮/点击落在箭头之外。
        //
        // 已实测并回退的两种猜法：① 写成 g_lastSetCursor（窗口中心，复刻桌面端 ESC 回中）；
        // ② 保留旧菜单位置并强制上报一次。两者都会制造"箭头在一处、判定在另一处"。
        // 详见本文件"菜单光标必须是绝对映射"一节。
        g_menuX = g_lookX;
        g_menuY = g_lookY;
    } else if (nextGrab && !oldGrab) {
        // menu → grabbed：MC 紧邻本调用前已 glfwSetCursorPos(center)，这就是它新的 this.xpos/ypos。
        // 同步 look 与 pump 去重基准，首个 grabbed delta=0；后续只有真实 look 增量继续累加。
        // 不可回退：单独中心重锚不足以修复瞬移，必须与双坐标、有序 MENU_POINTER 以及
        // g_presentSerial + 2ULL 共同保留。
        g_lookX = g_lastSetCursorX;
        g_lookY = g_lastSetCursorY;
        g_cLastX = g_lastSetCursorX;
        g_cLastY = g_lastSetCursorY;
    }
    // SDL在每次grab翻转重新建立baseline，因此非物理累计可在同一边界安全重锚。
    // 否则某次合法但极大的有限输入会永久吃掉后续小delta，退出再进入也无法恢复精度。
    g_nonPhysicalLookX = 0.0;
    g_nonPhysicalLookY = 0.0;
    // grab 标志与坐标迁移在同一临界区发布，snapshot 不会观察到混合 epoch。
    atomic_store_explicit(&g_isGrabbing, nextGrab, memory_order_release);
    // 逻辑grab代次与physical capture不同，旧stream/prefix在新模式前作废，不补停局dt。
    const uint64_t lookEpoch=atomic_load_explicit(&g_lookModeEpoch,memory_order_relaxed);
    if(lookEpoch!=UINT64_MAX){atomic_store_explicit(&g_lookModeEpoch,lookEpoch+1,memory_order_release);
        const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
        if(look&&g_menuCursorSelectedSession)(void)look->publishMode(g_menuCursorSelectedSession,lookEpoch+1,nextGrab?1u:0u);}
    pthread_mutex_unlock(&g_cursorMutex);
    resetCommittedMenuCursor(1, atomic_load_explicit(&g_l3Active, memory_order_acquire));
    resetCommittedMenuCursor(2, atomic_load_explicit(&g_l2Active, memory_order_acquire));
    resetCommittedMenuCursor(3, atomic_load_explicit(&g_sdlActive, memory_order_acquire));

    // touch 只收原子 epoch（跨层旧手指作废），ArkTS TSFN 只观察显隐；两者都不拥有 grab 状态。
    resolveTouchGrabCb();
    if (g_touchGrabCb) g_touchGrabCb(nextGrab ? 1 : 0);
    resolveGrabChangeCb();
    if (g_grabChangeCb) g_grabChangeCb(nextGrab ? 1 : 0);
    unlockPhysicalMotionMode();
}

#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
unsigned int inputBridge_testGrabWriterWaiters(void) {
    return atomic_load_explicit(
        &g_testGrabWriterWaiters, memory_order_acquire);
}
#endif

// GLFW window destroy/recreate 的完整输入边界。调用顺序不可交换：
// 1) 先同步回 libentry 取消 finger/schema/OutputLedger owner；其 RELEASE 会进入旧 ring；
// 2) 再把 Minecraft 已实际看见的 down 状态直接 RELEASE 到仍有效的旧 window；
// 3) 最后在 producer lock 下把三个 consumer 跳到当前 write，丢掉旧批次和步骤 1 的重复 RELEASE。
// 这样既不会把旧 PRESS/菜单 token 带入新窗口，也不会把 RELEASE 排到 window delete 之后才回调。
// LWJGL2 另有 Java polling arrays，故再锁存一次 1009 reset，由下一次 drain 在 Java 线程归零。
JNIEXPORT void inputBridge_cancelAllState(void* window, int reason) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->cancelAllState(window, reason); return; }
    inputBridge_retireTouchMenuScopeV1();
    resetGlfwPresentationIdentity();
    // 窗口销毁/重建即使没有显式Hide也结束旧pump代次，禁止旧window继续接收批内事件。
    atomic_fetch_add_explicit(&g_l3ActivationGeneration, 1ULL, memory_order_acq_rel);
    resolveTouchCancelCb();
    if (g_touchCancelCb) g_touchCancelCb(reason);

    // 新窗口会重新声明 cursor mode。先回到 normal，并保留 setGrabState 内不可回退的双坐标重锚语义。
    inputBridge_setGrabState(0);
    cancelMenuTransaction(window, true);
    pthread_mutex_lock(&g_downMutex);
    (void)amclPointerRetire(&g_l2Pointer);
    // 窗口取消同时关闭BEGIN标记，token与阶段身份必须成对复位。

    g_l2FinalLeftPending = -1;
    memset(&g_l2LeftContribution, 0, sizeof(g_l2LeftContribution));
    memset(&g_l2MenuTool, 0, sizeof(g_l2MenuTool));
    memset(g_l2KeyDownBuffer, 0, sizeof(g_l2KeyDownBuffer));
    memset(g_l2MouseDownBuffer, 0, sizeof(g_l2MouseDownBuffer));
    pthread_mutex_unlock(&g_downMutex);
    clearConsumedDownState(window, true);

    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long write =
        atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    atomic_store_explicit(&g_l3ReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_l2ReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_sdlReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_l3OverflowPending, false, memory_order_release);
    atomic_store_explicit(&g_l2OverflowPending, false, memory_order_release);
    atomic_store_explicit(&g_sdlOverflowPending, false, memory_order_release);
    memset(&g_producerOrdinary, 0, sizeof(g_producerOrdinary));
    memset(&g_producerMenuTool, 0, sizeof(g_producerMenuTool));
    g_l3Baseline.pending = g_l2Baseline.pending = g_sdlBaseline.pending = false;
    pthread_mutex_unlock(&g_pushMutex);

    g_l3TargetSequence = write;
    g_l3RecoveryPending = false;
    atomic_store_explicit(&g_l2ResetPending, true, memory_order_release);
    atomic_store_explicit(&g_sdlResetPending, true, memory_order_release);
    atomic_store_explicit(&g_overflowDropCount, 0ULL, memory_order_relaxed);
    atomic_store_explicit(&g_sdlOverflowDropCount, 0ULL, memory_order_relaxed);
    if (g_lastPumpWindow == window) g_lastPumpWindow = NULL;
    LOGI("InputBridge cancelAll window=%{public}p reason=%{public}d sequence=%{public}llu",
         window, reason, write);
}

void inputBridge_setWindowSize(int w, int h) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->setWindowSize(w, h); return; }
    if (w <= 0 || h <= 0) {
        LOGW("InputBridge: rejected invalid window size %{public}dx%{public}d", w, h);
        return;
    }
    bool changed = false;
    pthread_mutex_lock(&g_windowSizeMutex);
    if (g_windowWidth != w || g_windowHeight != h) {
        g_windowWidth = w;
        g_windowHeight = h;
        changed = true;
    }
    pthread_mutex_unlock(&g_windowSizeMutex);
    if (changed) {
        LOGI("InputBridge: surface snapshot updated to %{public}dx%{public}d", w, h);
    }
}

// Legacy pointer accessors return per-thread snapshots so callers cannot bypass g_downMutex.
// 委派时返回的是 owner image 里那份 thread-local 快照的地址 —— 同一线程、同一进程，寿命
// 与调用线程一致，正是调用方需要的。
unsigned char* inputBridge_getKeyDownBuffer(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->getKeyDownBuffer();
    static _Thread_local unsigned char snapshot[512];
    pthread_mutex_lock(&g_downMutex);
    memcpy(snapshot, g_keyDownBuffer, sizeof(snapshot));
    pthread_mutex_unlock(&g_downMutex);
    return snapshot;
}
unsigned char* inputBridge_getMouseDownBuffer(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->getMouseDownBuffer();
    static _Thread_local unsigned char snapshot[16];
    pthread_mutex_lock(&g_downMutex);
    memcpy(snapshot, g_mouseDownBuffer, sizeof(snapshot));
    pthread_mutex_unlock(&g_downMutex);
    return snapshot;
}

// ============================================================
//  LWJGL2 消费端 API（MC ≤1.12 真·LWJGL2 后端 liblwjgl_v2.so 经 dlsym 调）
//
//  LWJGL2 是 poll + event 双模型，与 LWJGL3 的回调模型不同：
//    - 状态查询（光标 / 按键按住 / 鼠标按住）走线程安全 cursor snapshot；
//    - 离散事件使用独立 g_l2ReadSequence，与 LWJGL3 的 g_l3ReadSequence 互不抢占。
//  键码翻译（GLFW→LWJGL2）与坐标系转换（左下原点 + grabbed poll-delta）仍在 liblwjgl_v2
//  后端完成；这里保持 absolute menu + 原始 GLFW 事件语义。
//
//  返回 1 并填出参表示取到一个事件；返回 0 表示队列空。
//  overflow/window recovery 不是“空队列”：必须返回一次 1009，使 Java 同步清除自己的 polling state。
// ============================================================
static int returnResetEvent(int* outType, int* o1, int* o2, int* o3, int* o4) {
    if (outType) *outType = EVENT_TYPE_INPUT_RESET;
    if (o1) *o1 = 0;
    if (o2) *o2 = 0;
    if (o3) *o3 = 0;
    if (o4) *o4 = 0;
    return 1;
}

/** L2/SDL在原RESET后逐条恢复自己的ordinary平面；五int ABI保持，typed与菜单不被重放。 */
static int returnRecoveryBaseline(LegacyRecoveryBaseline* baseline, bool sdl,
                                  int* outType, int* o1, int* o2, int* o3, int* o4) {
    GLFWInputEvent event;
    for (;;) {
        if (!takeRecoveryBaselineEvent(baseline, &event)) return 0;
        if(!sdl&&event.type==EVENT_TYPE_KEY&&amclInputOwnerSelectedKeyboardBackendV1()==2u){
            const uint64_t scope=event.i1>=0&&event.i1<=512?baseline->held.keyScopes[event.i1]:0;
            if(!scope||scope!=amclInputOwnerL2KeyboardScopeV1())continue;
        }
        const bool special = event.type == EVENT_TYPE_TOUCH_MENU_TOOL ||
            (event.type == EVENT_TYPE_KEY && event.i1 == 340) ||
            (event.type == EVENT_TYPE_MOUSE_BUTTON && event.i1 <= GLFW_MOUSE_BUTTON_RIGHT);
        if (special) {
            pthread_mutex_t* mutex = sdl ? &g_sdlMenuMutex : &g_downMutex;
            pthread_mutex_lock(mutex);
            const bool emitted = applyMenuToolEvent(sdl ? &g_sdlMenuState.left : &g_l2LeftContribution,
                sdl ? &g_sdlMenuTool : &g_l2MenuTool, &event,
                event.type == EVENT_TYPE_TOUCH_MENU_TOOL, baseline->tool.epoch);
            pthread_mutex_unlock(mutex);
            if (!emitted) continue;
        }
        if (!sdl) {
            pthread_mutex_lock(&g_downMutex);
            if (event.type == EVENT_TYPE_KEY) {
                if (event.i1 < 512) g_l2KeyDownBuffer[event.i1] = 1;
            } else g_l2MouseDownBuffer[event.i1] = 1;
            pthread_mutex_unlock(&g_downMutex);
        }
        break;
    }
    if (outType) *outType = event.type;
    if (o1) *o1 = event.i1;
    if (o2) *o2 = event.i2;
    if (o3) *o3 = event.i3;
    if (o4) *o4 = event.i4;
    return 1;
}

// ⭐ LWJGL2 的 typed 物理事件在**宿主侧**合并进本函数，而不是给 LWJGL2 另开一条通道。
// 三条理由：
//   ① 不需要重建 liblwjgl_v2.so（native JNI 面完全不变）——它的构建要容器 + 从上游 clone
//      LWJGL2 源码，而那条流水线还缺 JDK8/ant/sysroot；
//   ② 五个 int 对 LWJGL2 **不是有损**的：`Keyboard`/`Mouse` 的 API 里根本没有 timestamp、
//      deviceId、lockState 的位置（那些字段是 SDL3 需要的，所以 SDL3 才要 64 字节通道）；
//   ③ 合并在这里，虚拟按键/手柄/字符（仍在 ring 里）与物理键鼠（在 typed 里）自然汇成
//      一条流，Java 侧不需要知道两条来源。
//
// **编码判别靠 type 号**：2005/2006/2007/2009 表示 i1 已经是 LWJGL2（DirectInput）编码，
// 1005/1006/1007/1009 仍是 GLFW 编码。刻意不复用同一组 type 号再加一个"编码"字段 ——
// 老宿主 + 新 Java 与新宿主 + 老 Java 两个方向都必须自动退化正确，而 type 号做到了：
// 老宿主永不发 2xxx，老 Java 收到 2xxx 会落进 switch 的 default（丢弃，不会错译）。
// 滚轮余量本通道私有。⚠️ 复位时必须归零 —— 由接缝无条件写回保证，本文件不判断。
static double g_l2TypedWheelRemainder = 0.0;
static uint32_t g_l2TextScalars[4096];
static uint32_t g_l2TextScalarCount = 0;
static uint32_t g_l2TextScalarIndex = 0;
static uint64_t g_l2TextKeyboardScope=0; // 原完整包的接受资格，分标量输出也不借新Keyboard
static atomic_ullong g_l2TextEditingDegraded = 0;
static atomic_ullong g_l2TextCandidatesDegraded = 0;
static atomic_ullong g_l2TextSelectionDegraded = 0;

static void recordL2TextDegradation(
        const char* kind, atomic_ullong* counter) {
    const unsigned long long count =
        atomic_fetch_add_explicit(counter, 1ULL, memory_order_relaxed) + 1ULL;
    if ((count & (count - 1ULL)) == 0ULL) {
        LOGW("LWJGL2 typed text degraded kind=%{public}s count=%{public}llu",
             kind, count);
    }
}

// 从 typed 通道取一个已是 LWJGL2 编码的物理事件。返回 1 = 有、0 = 没有（含"本通道不适用"）。
//
// ⚠️ 翻译本体在 `lwjgl2_event_translate.cpp` 里，**不在这里** —— 那个 TU 是纯函数、能进
// host 构建，所以"滚轮分格 / 拒绝时归零 / action 三态 / 未知类型丢弃"这几条有断言钉着。
// 本文件留的只是取事件与写回余量的循环，因为 hilog/pthread/atomic 让它进不了 host 构建
// （与 §91 把 `StepPhysicalWheel` 抽出来是同一手法）。
// 队首窥视与复制共享 producer 锁；不会提前推进游标。返回的 order 用作另一通道
// 的上限，即使其间溢出，真正 dequeue 仍会核验槽并走恢复，不能解释覆盖后的载荷。
static uint64_t peekRingOrder(atomic_ullong* readCursor, atomic_bool* overflow) {
    pthread_mutex_lock(&g_pushMutex);
    const uint64_t read = atomic_load_explicit(readCursor, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
    uint64_t order = UINT64_MAX;
    if (atomic_load_explicit(overflow, memory_order_relaxed) || write - read > EVENT_WINDOW_SIZE) order = 0u;
    else if (read != write) {
        GLFWInputSlot* slot = &g_events[read % EVENT_WINDOW_SIZE];
        order = atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed) == read + 1u
            ? slot->interactionOrder : 0u;
    }
    pthread_mutex_unlock(&g_pushMutex);
    return order;
}

// LWJGL2 以连续 Next 调用表达一轮 drain，没有独立 Begin/End。第一次调用冻结共同
// fence，返回 EMPTY 或耗尽预算才结束；持续生产者不能把同一 Java poll 无限延长。
static bool g_l2FrameOpen = false;
static uint64_t g_l2FrameFence = 0u;
static unsigned g_l2FrameEvents = 0u;

static int l2NextTypedEvent(int* outType, int* o1, int* o2, int* o3, int* o4, uint64_t maxOrder) {
    for (;;) {
        if (g_l2TextScalarIndex < g_l2TextScalarCount) {
            if(amclInputOwnerSelectedKeyboardBackendV1()==2u&&(!g_l2TextKeyboardScope||g_l2TextKeyboardScope!=amclInputOwnerL2KeyboardScopeV1())){
                g_l2TextScalarIndex=g_l2TextScalarCount=0;continue;
            }
            *outType = EVENT_TYPE_CHAR;
            *o1 = (int)g_l2TextScalars[g_l2TextScalarIndex++];
            *o2 = 0;
            *o3 = 0;
            *o4 = 0;
            if (g_l2TextScalarIndex == g_l2TextScalarCount) {
                g_l2TextScalarIndex = 0;
                g_l2TextScalarCount = 0;
            }
            return 1;
        }
        AmclBackendInputEvent ev;
        const int status = amclBackendInputNextThrough(AMCL_BACKEND_INPUT_LWJGL2, &ev, maxOrder);
        // ⚠️ UNAVAILABLE 必须与 EMPTY 分开：前者意味着 legacy 路由生效、物理边沿在 ring 里，
        // 继续往下读 ring 即可；把它当错误直接返回会丢掉全部物理输入。
        if (status != AMCL_BACKEND_INPUT_EVENT) return 0;
        if(ev.eventType==AMCL_BACKEND_INPUT_EVENT_RELATIVE&&amclInputOwnerLookCommitReadyV1()){
            // NextThrough的sequence是共同order；C++内部原Coreseq已在唯一owner memo关联。
            uint64_t token=0;const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
            if(!look||look->physicalPrefixByOrder(ev.sequence,&token)!=AMCL_LOOK_PREFIX_READY)continue;
            *outType=AMCL_LOOK_PREFIX_EVENT;*o1=(int)(uint32_t)token;*o2=(int)(uint32_t)(token>>32);*o3=0;*o4=0;return 1;
        }
        if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT) {
            uint64_t originalTextKeyboardScope=0;
            (void)amclBackendInputL2ReadKeyScopeV1(ev.sequence,&originalTextKeyboardScope);
            uint32_t scalarCount = 0;
            const int query = amclBackendInputReadTextScalars(
                AMCL_BACKEND_INPUT_LWJGL2, ev.deviceId, NULL, 0,
                &scalarCount);
            int read = query;
            if (query == AMCL_BACKEND_INPUT_EVENT &&
                scalarCount <= 4096u) {
                read = amclBackendInputReadTextScalars(
                    AMCL_BACKEND_INPUT_LWJGL2, ev.deviceId,
                    g_l2TextScalars, 4096u, &scalarCount);
            }
            const int released = amclBackendInputReleaseText(
                AMCL_BACKEND_INPUT_LWJGL2, ev.deviceId);
            if (read == AMCL_BACKEND_INPUT_EVENT &&
                released == AMCL_BACKEND_INPUT_EVENT &&
                scalarCount != 0u && scalarCount <= 4096u) {
                g_l2TextScalarCount = scalarCount;
                g_l2TextScalarIndex = 0u;
                // typed queue已按原记录scope校验；完整包展开保该资源，不在后续标量补戳。
                g_l2TextKeyboardScope=originalTextKeyboardScope;
            }
            continue;
        }
        if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING ||
            ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES) {
            (void)amclBackendInputReleaseText(
                AMCL_BACKEND_INPUT_LWJGL2, ev.deviceId);
            if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING) {
                recordL2TextDegradation(
                    "editing", &g_l2TextEditingDegraded);
            } else {
                recordL2TextDegradation(
                    "candidates", &g_l2TextCandidatesDegraded);
            }
            continue;
        }
        if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION) {
            recordL2TextDegradation(
                "selection", &g_l2TextSelectionDegraded);
            continue;
        }
        if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION) {
            continue;
        }
        AmclLwjgl2WireEvent wire;
        double next = 0.0;
        const int emitted = amclTranslateBackendEventToLwjgl2(
            &ev, g_l2TypedWheelRemainder, &next, &wire);
        // 无条件写回，不产出的那一路也一样 —— 与 `StepPhysicalWheel` 同一条纪律：把写回
        // 变成有条件的，这个调用点就有了一个可以做错的选择（§91.2 抓到过那条真缺陷）。
        g_l2TypedWheelRemainder = next;
        if (!emitted) continue;
        *outType = wire.type;
        *o1 = wire.i1;
        *o2 = wire.i2;
        *o3 = wire.i3;
        *o4 = wire.i4;
        return 1;
    }
}

void inputBridge_l2SetActive(int active) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->l2SetActive(active); return; }
    resetCommittedMenuCursor(2, active != 0);
    g_l2FrameOpen = false;
    // legacy ring 侧与 `inputBridge_sdlSetActive` 同一形状：先停收，再把读游标对齐到
    // "此刻"。**不重放**是刻意的 —— 重放会把窗口存在之前按下的键注入进去，而它们的 UP
    // 早已过去（那在游戏里读作卡键）。
    atomic_store_explicit(&g_l2Active, false, memory_order_release);
    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long write =
        atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    atomic_store_explicit(&g_l2ReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_l2OverflowPending, false, memory_order_release);
    atomic_store_explicit(&g_l2ResetPending, false, memory_order_release);
    g_l2Baseline.pending = false;
    pthread_mutex_unlock(&g_pushMutex);
    // 这三样与 ring 的读游标同属"此刻之前的历史"，一起清（滚轮余量留着会让下一次会话
    // 的第一格提前或延后到达；菜单 token 留着会让新会话认领旧事务）。
    pthread_mutex_lock(&g_downMutex);
    (void)amclPointerRetire(&g_l2Pointer);
    // 新activation从无手势开始，不能只清token而保留上一会话的BEGIN模式。

    g_l2FinalLeftPending = -1;
    memset(&g_l2LeftContribution, 0, sizeof(g_l2LeftContribution));
    memset(&g_l2MenuTool, 0, sizeof(g_l2MenuTool));
    memset(g_l2KeyDownBuffer, 0, sizeof(g_l2KeyDownBuffer));
    memset(g_l2MouseDownBuffer, 0, sizeof(g_l2MouseDownBuffer));
    pthread_mutex_unlock(&g_downMutex);
    g_l2TypedWheelRemainder = 0.0;
    g_l2TextScalarCount = 0u;
    g_l2TextScalarIndex = 0u;
    atomic_store_explicit(&g_l2Active, active != 0, memory_order_release);
    // ⭐ 本函数存在的**唯一理由**：typed 通道此前零激活者。
    // ⚠️ 必须在 delegate 转发**之后**才走到这里 —— 见上面那条早退与结构体字段注释。
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, active);
}

int inputBridge_l2NextEvent(int* outType, int* o1, int* o2, int* o3, int* o4) {
    // ⚠️ 这是 `liblwjgl_v2.so` 在 **MC 的 linker namespace 里** dlsym 到的符号 ⇒ 它落进的是
    // MC 那份 image。没有委派的话 ≤1.12 世代读的是一条永远为空的 ring（本次回归里
    // "26.2 及以下"覆盖到 LWJGL2 世代就是这么来的）。
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->l2NextEvent(outType, o1, o2, o3, o4);
    (void)amclSourceControlDrainTerminalsV1();
    atomic_store_explicit(&g_l2Active, true, memory_order_release);
    // 退休是立即可见的触控控制边界；释放仍在L2拉取线程，绝不清ordinary/typed贡献。
    pthread_mutex_lock(&g_downMutex);
    const bool scopeRetired = g_l2Pointer.token != 0 &&
        (g_l2Pointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
         g_l2Pointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire));
    pthread_mutex_unlock(&g_downMutex);
    if (scopeRetired) cancelL2MenuTransaction();
    GLFWInputEvent retiredTool;
    pthread_mutex_lock(&g_downMutex);
    const bool toolRelease = retireMenuToolEvent(&g_l2LeftContribution, &g_l2MenuTool, &retiredTool);
    if (toolRelease) {
        if (retiredTool.type == EVENT_TYPE_KEY) g_l2KeyDownBuffer[340] = retiredTool.i3 != GLFW_RELEASE;
        else g_l2MouseDownBuffer[retiredTool.i1] = retiredTool.i2 != GLFW_RELEASE;
    }
    pthread_mutex_unlock(&g_downMutex);
    if (toolRelease) return returnLegacyEvent(&retiredTool, outType, o1, o2, o3, o4);
    if (atomic_exchange_explicit(&g_l2ResetPending, false, memory_order_acq_rel)) {
        g_l2FrameOpen = false;
        resetCommittedMenuCursor(2, true);
        g_l2TextScalarCount = 0u;
        g_l2TextScalarIndex = 0u;
        pthread_mutex_lock(&g_downMutex);
        // RESET是Java数组与neutral菜单身份的同一消费边界，清理零token以外的阶段字段。
        (void)amclPointerRetire(&g_l2Pointer);

        g_l2FinalLeftPending = -1;
        memset(&g_l2LeftContribution, 0, sizeof(g_l2LeftContribution));
    memset(&g_l2MenuTool, 0, sizeof(g_l2MenuTool));
        memset(g_l2KeyDownBuffer, 0, sizeof(g_l2KeyDownBuffer));
        memset(g_l2MouseDownBuffer, 0, sizeof(g_l2MouseDownBuffer));
        pthread_mutex_unlock(&g_downMutex);
        return returnResetEvent(outType, o1, o2, o3, o4);
    }
    // 每次拉取在同一 owner 顺序内选队首；无输出记录也必须重新比较，不能越过另一队列。
    if (g_l2FrameOpen && g_l2FrameEvents >= EVENT_WINDOW_SIZE) {
        g_l2FrameOpen = false;
        return 0;
    }
    if (!g_l2FrameOpen) {
        g_l2FrameOpen = true;
        g_l2FrameFence = amclInputInteractionFence();
        g_l2FrameEvents = 0u;
    }
    ++g_l2FrameEvents;
    const uint64_t frameFence = g_l2FrameFence;
    const uint64_t baselineOrder = recoveryBaselineOrder(&g_l2Baseline);
    if (baselineOrder != UINT64_MAX) {
        const uint64_t ceiling = baselineOrder < frameFence ? baselineOrder : frameFence;
        if (l2NextTypedEvent(outType,o1,o2,o3,o4,ceiling)) return 1;
        if (baselineOrder > frameFence) { g_l2FrameOpen = false; return 0; }
        if (returnRecoveryBaseline(&g_l2Baseline,false,outType,o1,o2,o3,o4)) return 1;
    }
    pthread_mutex_lock(&g_downMutex);
    if (g_l2FinalLeftPending >= 0) {
        // 同一菜单替换事务第二条边沿必须先于后来的ring/typed记录交付。
        const int action = g_l2FinalLeftPending;
        g_l2FinalLeftPending = -1;
        g_l2MouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = action != GLFW_RELEASE;
        pthread_mutex_unlock(&g_downMutex);
        if (outType) *outType = EVENT_TYPE_MOUSE_BUTTON;
        if (o1) *o1 = GLFW_MOUSE_BUTTON_LEFT;
        if (o2) *o2 = action;
        if (o3) *o3 = 0;
        if (o4) *o4 = 0;
        return 1;
    }
    pthread_mutex_unlock(&g_downMutex);
    for (;;) {
        const uint64_t legacyOrder = peekRingOrder(&g_l2ReadSequence, &g_l2OverflowPending);
        const uint64_t ceiling = legacyOrder < frameFence ? legacyOrder : frameFence;
        if (l2NextTypedEvent(outType, o1, o2, o3, o4, ceiling)) return 1;
        if (legacyOrder > frameFence) { g_l2FrameOpen = false; return 0; }
        const unsigned long long write =
            atomic_load_explicit(&g_writeSequence, memory_order_acquire);
        unsigned long long read =
            atomic_load_explicit(&g_l2ReadSequence, memory_order_relaxed);
        const bool flagged =
            atomic_exchange_explicit(&g_l2OverflowPending, false, memory_order_acq_rel);
        if (flagged || write - read > EVENT_WINDOW_SIZE) {
            atomic_store_explicit(&g_l2ReadSequence, write, memory_order_release);
            recoverOverflowState(NULL, false, "LWJGL2");
            return returnResetEvent(outType, o1, o2, o3, o4);
        }
        if (read == write) { g_l2FrameOpen = false; return 0; }

        GLFWInputEvent e;
        pthread_mutex_lock(&g_pushMutex);
        GLFWInputSlot* slot = &g_events[read % EVENT_WINDOW_SIZE];
        const unsigned long long published =
            atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed);
        if (published != read + 1ULL) {
            const unsigned long long latest =
                atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
            pthread_mutex_unlock(&g_pushMutex);
            atomic_store_explicit(&g_l2ReadSequence, latest, memory_order_release);
            recoverOverflowState(NULL, false, "LWJGL2-slot");
            return returnResetEvent(outType, o1, o2, o3, o4);
        }
        e = slot->event;
        const uint64_t interactionOrder = slot->interactionOrder;
        const uint64_t menuScopeEpoch = slot->menuScopeEpoch;
        const uint64_t toolScopeEpoch = slot->toolScopeEpoch;
        const uint64_t keyScope=slot->l2KeyboardScope;
        const uint32_t gestureToken = slot->gestureToken;
        const MenuRelativeMetadata relative = slot->relative;
        pthread_mutex_unlock(&g_pushMutex);
        if(amclInputOwnerSelectedKeyboardBackendV1()==2u&&(e.type==EVENT_TYPE_KEY||e.type==EVENT_TYPE_CHAR||e.type==EVENT_TYPE_CHAR_MODS)&&
           (!keyScope||keyScope!=amclInputOwnerL2KeyboardScopeV1())){
            atomic_store_explicit(&g_l2ReadSequence,read+1ULL,memory_order_release);continue;
        }
        // 快照之后可能恰好退休再发布新工具；新槽先等待旧贡献控制边沿，游标不能提前跳过它。
        pthread_mutex_lock(&g_downMutex);
        const bool staleMenu = g_l2Pointer.token != 0 &&
            (g_l2Pointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
             g_l2Pointer.inputTargetEpoch != atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire));
        pthread_mutex_unlock(&g_downMutex);
        if (staleMenu) {
            cancelL2MenuTransaction();
            pthread_mutex_lock(&g_downMutex);
            const int release = g_l2FinalLeftPending;
            g_l2FinalLeftPending = -1;
            if (release >= 0) g_l2MouseDownBuffer[0] = release != GLFW_RELEASE;
            pthread_mutex_unlock(&g_downMutex);
            if (release >= 0) {
                GLFWInputEvent control = {EVENT_TYPE_MOUSE_BUTTON, 0, release, 0, 0};
                return returnLegacyEvent(&control, outType, o1, o2, o3, o4);
            }
        }
        pthread_mutex_lock(&g_downMutex);
        const bool retired = retireMenuToolEvent(&g_l2LeftContribution, &g_l2MenuTool, &retiredTool);
        if (retired) {
            if (retiredTool.type == EVENT_TYPE_KEY) g_l2KeyDownBuffer[340] = retiredTool.i3 != GLFW_RELEASE;
            else g_l2MouseDownBuffer[retiredTool.i1] = retiredTool.i2 != GLFW_RELEASE;
        }
        pthread_mutex_unlock(&g_downMutex);
        if (retired) return returnLegacyEvent(&retiredTool, outType, o1, o2, o3, o4);
        if (isScopedMenuEvent(e.type) && (read < atomic_load_explicit(&g_l3MenuTargetCutoff, memory_order_acquire) ||
            !scopedMenuEventValid(e.type, menuScopeEpoch, toolScopeEpoch))) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        pthread_mutex_lock(&g_downMutex);
        uint32_t menuToken = g_l2Pointer.token;
        const bool menuHeld = g_l2LeftContribution.committedMenuActive;
        const bool menuBegun = g_l2Pointer.gestureBegun, menuDownAccepted = g_l2Pointer.downAccepted;
        pthread_mutex_unlock(&g_downMutex);
        if (menuToken && !menuHeld && queuedMenuInvalidates(menuToken, menuScopeEpoch, read, write, frameFence, menuBegun)) {
            cancelL2MenuTransaction(); menuToken = 0;
        }
        if (e.type == EVENT_TYPE_TOUCH_MENU_SCROLL && gestureToken != 0 && gestureToken != menuToken) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        double menuPointX = 0.0, menuPointY = 0.0;
        const bool menuEndMoves = relativeMenuEndMoves(&e, &relative);
        if (!resolveRelativeMenuEvent(2, &e, &relative, menuToken, &menuPointX, &menuPointY)) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        const bool start = e.type == EVENT_TYPE_MENU_POINTER &&
            (e.i1 == MENU_POINTER_BEGIN || e.i1 == MENU_POINTER_DOWN);
        const bool continuation = start && amclPointerIsContinuation(e.i1, (uint32_t)e.i4, menuToken, menuBegun, menuHeld, menuDownAccepted);
        if (start && !continuation && g_gestureTokenEpoch[2] == menuScopeEpoch && (uint32_t)e.i4 <= g_gestureTokenHigh[2]) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        if (start && !continuation && menuToken != 0) {
            pthread_mutex_lock(&g_downMutex);
            const int release = setLegacyLeftContribution(&g_l2LeftContribution, true, false);
            (void)amclPointerRetire(&g_l2Pointer);
            if (release >= 0) g_l2MouseDownBuffer[0] = release != GLFW_RELEASE;
            pthread_mutex_unlock(&g_downMutex);
            if (release >= 0) {
                GLFWInputEvent control = {EVENT_TYPE_MOUSE_BUTTON, 0, release, 0, 0};
                return returnLegacyEvent(&control, outType, o1, o2, o3, o4);
            }
        }
        if (start && !acceptMenuGestureStart(2, e.i1, (uint32_t)e.i4, menuToken, menuBegun, menuHeld, menuDownAccepted)) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        if (start && e.i1 == MENU_POINTER_BEGIN && queuedMenuInvalidates((uint32_t)e.i4, menuScopeEpoch, read + 1ULL, write, frameFence, true)) {
            atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release); continue;
        }
        if (e.type == EVENT_TYPE_TOUCH_MENU_CURSOR || e.type == EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR) e.type = EVENT_TYPE_CURSOR_POSITION;
        if (e.type == EVENT_TYPE_TOUCH_MENU_SCROLL || e.type == EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL) e.type = EVENT_TYPE_SCROLL;
        if (e.type == EVENT_TYPE_CURSOR_POSITION) consumeOrderedCursor(&e, 2);
        atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release);
        if (e.type == EVENT_TYPE_MENU_POINTER) {
            const int phase = e.i1; const uint32_t token = (uint32_t)e.i4;
            if (!token || phase < MENU_POINTER_MOVE || phase > MENU_POINTER_END) continue;
            pthread_mutex_lock(&g_downMutex);
            const AmclPointerPlan plan = amclPointerAccept(&g_l2Pointer, &g_l2PointerPolicy,
                phase, token, menuPointX, menuPointY, menuEndMoves, interactionOrder,
                menuMonotonicNowNs(), menuScopeEpoch,
                atomic_load_explicit(&g_l3InputTargetEpoch, memory_order_acquire));
            const int action = plan.contribution >= 0
                ? setLegacyLeftContribution(&g_l2LeftContribution, true, plan.contribution != 0) : -1;
            pthread_mutex_unlock(&g_downMutex);
            if (!plan.accepted) continue;
            if (plan.position) {
                inputBridge_setMenuCursor(menuPointX, menuPointY); updateCurrentMenuCursor(2, menuPointX, menuPointY);
            }
            if (phase == MENU_POINTER_MOVE || phase == MENU_POINTER_UP || phase == MENU_POINTER_BEGIN || menuEndMoves) {
                if (action >= 0) { pthread_mutex_lock(&g_downMutex); g_l2FinalLeftPending = action; pthread_mutex_unlock(&g_downMutex); }
                return returnOrderedMenuCursor(menuPointX, menuPointY, 2, interactionOrder, outType, o1, o2, o3, o4);
            }
            if (action < 0) continue;
            if (phase == MENU_POINTER_DOWN) commitMenuCursor(2, menuPointX, menuPointY, interactionOrder, committedMenuCursorActivation(2));
            e.type = EVENT_TYPE_MOUSE_BUTTON; e.i1 = 0; e.i2 = action; e.i3 = e.i4 = 0;
        } else if (e.type == EVENT_TYPE_TOUCH_MENU_TOOL || (e.type == EVENT_TYPE_KEY && e.i1 == 340) ||
                   (e.type == EVENT_TYPE_MOUSE_BUTTON && e.i1 <= GLFW_MOUSE_BUTTON_RIGHT)) {
            pthread_mutex_lock(&g_downMutex);
            const bool emitted = applyMenuToolEvent(&g_l2LeftContribution, &g_l2MenuTool, &e,
                e.type == EVENT_TYPE_TOUCH_MENU_TOOL, toolScopeEpoch);
            pthread_mutex_unlock(&g_downMutex);
            if (!emitted) continue;
        }
        // polling在本consumer接受事件之后更新；ACK只给实际领取的成对位置。
        pthread_mutex_lock(&g_downMutex);
        if (e.type == EVENT_TYPE_KEY && e.i1 >= 0 && e.i1 < 512) g_l2KeyDownBuffer[e.i1] = e.i3 != GLFW_RELEASE;
        if (e.type == EVENT_TYPE_MOUSE_BUTTON && e.i1 >= 0 && e.i1 < 16) g_l2MouseDownBuffer[e.i1] = e.i2 != GLFW_RELEASE;
        pthread_mutex_unlock(&g_downMutex);
        if (e.type == EVENT_TYPE_CURSOR_POSITION) {
            const int words[4] = {e.i1, e.i2, e.i3, e.i4}; double x = 0, y = 0;
            memcpy(&x, words, sizeof(x)); memcpy(&y, words + 2, sizeof(y));
            commitMenuCursor(2, x, y, interactionOrder, committedMenuCursorActivation(2));
        }
        #if AMCL_INPUT_TRACE
        if(e.type==AMCL_LOOK_PREFIX_EVENT){
            // 真L2运输槽已复制并通过原顺序/资格，使用该slot的read+1和order，
            // 不能从已推进global游标或五整数client重构序号。
            AmclInputLatencyV1 note;memset(&note,0,sizeof(note));
            note.prefix=(uint32_t)e.i1|((uint64_t)(uint32_t)e.i2<<32);
            note.ringSequence=read+1ULL;note.ringOrder=interactionOrder;
            amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,2,AMCL_ILAT_ENDPOINT_L2_POLL_VIEW,&note);
        }
        #endif
        return returnLegacyEvent(&e, outType, o1, o2, o3, o4);
    }
}

// SDL私有消费会话。所有共享状态用sdlMenuMutex；回调/输出和snapshot提交都在锁外。
static int returnSdlMenuButtonEvent(int action, int* outType, int* o1, int* o2, int* o3, int* o4) {
    GLFWInputEvent event = {EVENT_TYPE_MOUSE_BUTTON, 0, action, 0, 0};
    return returnLegacyEvent(&event, outType, o1, o2, o3, o4);
}

/** 先退休、再准入；源码帧门+1在源点1010被调用者领取后的后继Next冻结。 */
static int returnDueSdlMenuButton(int* outType, int* o1, int* o2, int* o3, int* o4, uint64_t maxOrder) {
    int action = -1; bool cursor = false; double x = 0, y = 0; uint64_t cursorOrder = 0;
    pthread_mutex_lock(&g_sdlMenuMutex);
    const bool retired = g_sdlMenuState.pointer.token != 0 &&
        (g_sdlMenuState.pointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
         g_sdlMenuState.pointer.inputTargetEpoch != atomic_load_explicit(&g_sdlInputTargetEpoch, memory_order_acquire) ||
         (g_sdlMenuState.targetPresentedWindow != 0 && g_sdlMenuState.presentedWindow != 0 &&
          (g_sdlMenuState.targetPresentedWindow != g_sdlMenuState.presentedWindow ||
           g_sdlMenuState.targetPresentedGeneration != g_sdlMenuState.presentedGeneration ||
           g_sdlMenuState.targetPresentedIdentity != g_sdlMenuState.presentedIdentity)));
    const unsigned long long read = atomic_load_explicit(&g_sdlReadSequence, memory_order_acquire);
    const unsigned long long write = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    const bool cancelled = queuedMenuInvalidates(g_sdlMenuState.pointer.token,
        g_sdlMenuState.pointer.scopeEpoch, read, write, maxOrder, g_sdlMenuState.pointer.gestureBegun);
    double currentX = 0, currentY = 0; bridgeCursorSnapshot(&currentX, &currentY);
    const enum AmclPointerAdvanceKind step = amclPointerAdvance(&g_sdlMenuState.pointer, &g_sdlPointerPolicy,
        retired || (g_sdlMenuState.pointer.pressPending && atomic_load_explicit(&g_isGrabbing, memory_order_acquire)),
        cancelled, menuPendingExpired(g_sdlMenuState.pointer.pendingSinceNs), maxOrder,
        g_sdlMenuState.presentSerial, currentX, currentY);
    if (step == AMCL_POINTER_RELEASE || step == AMCL_POINTER_ACQUIRE)
        action = setLegacyLeftContribution(&g_sdlMenuState.left, true, step == AMCL_POINTER_ACQUIRE);
    else if (step == AMCL_POINTER_RESTORE_SOURCE) {
        cursor = true; x = g_sdlMenuState.pointer.sourceX; y = g_sdlMenuState.pointer.sourceY;
        cursorOrder = g_sdlMenuState.pointer.pendingOrder;
    }
    pthread_mutex_unlock(&g_sdlMenuMutex);
    if (cursor) { inputBridge_setMenuCursor(x, y); updateCurrentMenuCursor(3, x, y);
        return returnOrderedMenuCursor(x, y, 3, cursorOrder, outType, o1, o2, o3, o4); }
    return action >= 0 ? returnSdlMenuButtonEvent(action, outType, o1, o2, o3, o4) : 0;
}

/** 阶段与坐标使用同一不可变slot，BEGIN无LEFT、UP末点先MOTION后RELEASE、END正常关闭。 */
static int consumeSdlMenuPointer(const GLFWInputEvent* event, uint64_t order, uint64_t epoch,
        double x, double y, bool endMoves, int* outType, int* o1, int* o2, int* o3, int* o4) {
    const int phase = event->i1; const uint32_t token = (uint32_t)event->i4;
    if (!token || phase < 0 || phase > MENU_POINTER_END) return 0;
    int action = -1; AmclPointerPlan plan = {false, false, -1};
    pthread_mutex_lock(&g_sdlMenuMutex);
    if ((phase != MENU_POINTER_BEGIN && phase != MENU_POINTER_DOWN) ||
        (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire) &&
         (!g_sdlTargetIdentityRequired || g_sdlInputTargetWindow != 0))) {
        plan = amclPointerAccept(&g_sdlMenuState.pointer, &g_sdlPointerPolicy, phase, token,
            x, y, endMoves, order, menuMonotonicNowNs(), epoch,
            atomic_load_explicit(&g_sdlInputTargetEpoch, memory_order_acquire));
        if (plan.accepted && (phase == MENU_POINTER_BEGIN || phase == MENU_POINTER_DOWN)) {
            g_sdlMenuState.targetPresentedWindow = g_sdlMenuState.presentedWindow;
            g_sdlMenuState.targetPresentedGeneration = g_sdlMenuState.presentedGeneration;
            g_sdlMenuState.targetPresentedIdentity = g_sdlMenuState.presentedIdentity;
        }
        if (plan.contribution >= 0)
            action = setLegacyLeftContribution(&g_sdlMenuState.left, true, plan.contribution != 0);
    }
    const bool cursor = plan.accepted && plan.position && !atomic_load_explicit(&g_isGrabbing, memory_order_acquire);
    pthread_mutex_unlock(&g_sdlMenuMutex);
    if (cursor) { inputBridge_setMenuCursor(x, y); updateCurrentMenuCursor(3, x, y);
        return returnOrderedMenuCursor(x, y, 3, order, outType, o1, o2, o3, o4); }
    return action >= 0 ? returnSdlMenuButtonEvent(action, outType, o1, o2, o3, o4) : 0;
}

void inputBridge_sdlSetActive(int active) {
    const InputBridgeInstanceV1* owner = bridgeDelegate(); if (owner) { owner->sdlSetActive(active); return; }
    registerGraphicsPresentationSinks(); atomic_store_explicit(&g_sdlActive, false, memory_order_release);
    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long write = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    atomic_store_explicit(&g_sdlReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_sdlOverflowPending, false, memory_order_release);
    atomic_store_explicit(&g_sdlResetPending, false, memory_order_release); g_sdlBaseline.pending = false;
    atomic_store_explicit(&g_sdlOverflowDropCount, 0ULL, memory_order_relaxed);
    pthread_mutex_unlock(&g_pushMutex); resetSdlMenuSession();
    atomic_store_explicit(&g_sdlActive, active != 0, memory_order_release); resetCommittedMenuCursor(3, active != 0);
}
void inputBridge_sdlNotifyFramePresented(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate(); if (owner) { owner->sdlNotifyFramePresented(); return; }
    publishGraphicsPresentation("SDL3");
}

/** logical SDL_WindowID、input pubgen、真实WSI高位identity分轴。只退休本consumer scoped前缀。 */
JNIEXPORT void inputBridge_sdlSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, sdlSetTarget)) owner->sdlSetTarget(window, generation, wsiIdentity); return; }
    if ((window == 0) != (generation == 0) || (window == 0 && wsiIdentity != 0)) return;
    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long cutoff = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    pthread_mutex_unlock(&g_pushMutex); pthread_mutex_lock(&g_sdlMenuMutex);
    if (window) g_sdlTargetIdentityRequired = true;
    if (window != g_sdlInputTargetWindow || generation != g_sdlInputTargetGeneration || wsiIdentity != g_sdlWsiPresentationIdentity) {
        g_sdlInputTargetWindow = window; g_sdlInputTargetGeneration = generation; g_sdlWsiPresentationIdentity = wsiIdentity;
        atomic_store_explicit(&g_sdlMenuTargetCutoff, cutoff, memory_order_release);
        atomic_fetch_add_explicit(&g_sdlInputTargetEpoch, 1ULL, memory_order_release);
        amclPointerRequestRetire(&g_sdlMenuState.pointer);
        if (g_sdlMenuTool.left || g_sdlMenuTool.right || g_sdlMenuTool.shift)
            g_sdlMenuTool.epoch = atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire) - 1ULL;
        g_sdlMenuState.presentedWindow = g_sdlMenuState.presentedGeneration = g_sdlMenuState.presentedIdentity = 0;
    }
    pthread_mutex_unlock(&g_sdlMenuMutex); targetCommittedMenuCursor(3, window, generation, wsiIdentity);
}
JNIEXPORT void inputBridge_sdlNotifyFramePresentedForTargetV1(uint64_t window, uint64_t generation) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { if (INPUT_BRIDGE_OWNER_HAS_TAIL(owner, sdlNotifyFramePresentedForTarget)) owner->sdlNotifyFramePresentedForTarget(window, generation);
        else owner->sdlNotifyFramePresented(); return; }
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    registerGraphicsPresentationSinks(); if (amclGraphicsDispatchPresentV1("SDL3", window, generation)) return;
#endif
    advanceSdlPresentation(window, generation);
}

/** sink只改成对clock，不读写consumer pending；Vulkan worker也可安全通知。 */
static void advanceGlfwPresentation(uint64_t window, uint64_t generation) {
    pthread_mutex_lock(&g_glfwPresentationMutex); const uint64_t identity = window;
    if (g_glfwPresentationClock.targetRequired) {
        if (!window || (window != g_glfwPresentationClock.targetWindow && window != g_glfwPresentationClock.wsiIdentity)) {
            pthread_mutex_unlock(&g_glfwPresentationMutex); return; }
        window = g_glfwPresentationClock.targetWindow;
    } else if (!window && g_glfwPresentationClock.identity) { pthread_mutex_unlock(&g_glfwPresentationMutex); return; }
    if (window) { g_glfwPresentationClock.window = window; g_glfwPresentationClock.generation = generation; g_glfwPresentationClock.identity = identity; }
    ++g_glfwPresentationClock.serial; pthread_mutex_unlock(&g_glfwPresentationMutex);
}
static void advanceSdlPresentation(uint64_t window, uint64_t generation) {
    if (!atomic_load_explicit(&g_sdlActive, memory_order_acquire)) return;
    pthread_mutex_lock(&g_sdlMenuMutex); const uint64_t identity = window;
    if (g_sdlTargetIdentityRequired && (!window || (window != g_sdlInputTargetWindow && window != g_sdlWsiPresentationIdentity))) {
        pthread_mutex_unlock(&g_sdlMenuMutex); return; }
    if (g_sdlTargetIdentityRequired) window = g_sdlInputTargetWindow;
    if (window) {
        g_sdlMenuState.presentedWindow = window; g_sdlMenuState.presentedGeneration = generation; g_sdlMenuState.presentedIdentity = identity;
        if (g_sdlMenuState.pointer.token && !g_sdlMenuState.targetPresentedWindow) {
            g_sdlMenuState.targetPresentedWindow = window; g_sdlMenuState.targetPresentedGeneration = generation; g_sdlMenuState.targetPresentedIdentity = identity;
        }
    }
    ++g_sdlMenuState.presentSerial; pthread_mutex_unlock(&g_sdlMenuMutex);
}
static void registerGraphicsPresentationSinks(void) {
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    static atomic_uint_fast64_t registeredPid = 0; const uint64_t currentPid = (uint64_t)getpid();
    if (atomic_load_explicit(&registeredPid, memory_order_acquire) == currentPid) return;
    if (amclGraphicsRegisterPresentSinkV1("GLFW", advanceGlfwPresentation) && amclGraphicsRegisterPresentSinkV1("SDL3", advanceSdlPresentation))
        atomic_store_explicit(&registeredPid, currentPid, memory_order_release);
#endif
}
static void publishGraphicsPresentation(const char* provider) {
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    registerGraphicsPresentationSinks(); if (amclGraphicsDispatchPresentV1(provider, 0, 0)) return;
#endif
    if (strcmp(provider, "GLFW") == 0) advanceGlfwPresentation(0, 0); else if (strcmp(provider, "SDL3") == 0) advanceSdlPresentation(0, 0);
}

/** pending仍保留原order；caller看到无输出且Peek变化会重选队首，无变化才结束本帧。 */
uint64_t inputBridge_sdlPeekOrder(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, sdlPeekOrder) ? owner->sdlPeekOrder() : UINT64_MAX;
    if (atomic_load_explicit(&g_sdlResetPending, memory_order_acquire)) return 0;
    pthread_mutex_lock(&g_sdlMenuMutex);
    const bool invalid = g_sdlMenuState.pointer.token && (g_sdlMenuState.pointer.scopeEpoch != atomic_load_explicit(&g_touchMenuScopeEpoch, memory_order_acquire) ||
        g_sdlMenuState.pointer.inputTargetEpoch != atomic_load_explicit(&g_sdlInputTargetEpoch, memory_order_acquire) ||
        (g_sdlMenuState.targetPresentedWindow && g_sdlMenuState.presentedWindow &&
         (g_sdlMenuState.targetPresentedWindow != g_sdlMenuState.presentedWindow || g_sdlMenuState.targetPresentedGeneration != g_sdlMenuState.presentedGeneration ||
          g_sdlMenuState.targetPresentedIdentity != g_sdlMenuState.presentedIdentity)));
    const bool toolInvalid = g_sdlMenuTool.epoch != atomic_load_explicit(&g_touchMenuToolScopeEpoch, memory_order_acquire) &&
        (g_sdlMenuTool.left || g_sdlMenuTool.right || g_sdlMenuTool.shift);
    const uint64_t pending = g_sdlMenuState.pointer.pressPending || g_sdlMenuState.pointer.finalReleasePending ? g_sdlMenuState.pointer.pendingOrder : UINT64_MAX;
    const bool release = g_sdlMenuState.pointer.releasePending;
    pthread_mutex_unlock(&g_sdlMenuMutex);
    if (invalid || toolInvalid || release) return 0; if (pending != UINT64_MAX) return pending;
    const uint64_t baseline = recoveryBaselineOrder(&g_sdlBaseline); if (baseline != UINT64_MAX) return baseline;
    return peekRingOrder(&g_sdlReadSequence, &g_sdlOverflowPending);
}
int inputBridge_sdlNextEvent(int* outType, int* o1, int* o2, int* o3, int* o4) {
    return inputBridge_sdlNextThrough(outType, o1, o2, o3, o4, UINT64_MAX);
}
int inputBridge_sdlNextThrough(int* outType, int* o1, int* o2, int* o3, int* o4, uint64_t maxOrder) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return INPUT_BRIDGE_OWNER_HAS_TAIL(owner, sdlNextThrough) ? owner->sdlNextThrough(outType, o1, o2, o3, o4, maxOrder) : owner->sdlNextEvent(outType, o1, o2, o3, o4);
    (void)amclSourceControlDrainTerminalsV1();
    if (!atomic_load_explicit(&g_sdlActive, memory_order_acquire)) inputBridge_sdlSetActive(1);
    if (atomic_exchange_explicit(&g_sdlResetPending, false, memory_order_acq_rel)) { resetSdlMenuSession(); return returnResetEvent(outType, o1, o2, o3, o4); }
    GLFWInputEvent retiredTool;
    pthread_mutex_lock(&g_sdlMenuMutex);
    bool toolRelease = retireMenuToolEvent(&g_sdlMenuState.left, &g_sdlMenuTool, &retiredTool);
    pthread_mutex_unlock(&g_sdlMenuMutex);
    if (toolRelease) return returnLegacyEvent(&retiredTool, outType, o1, o2, o3, o4);
    const int due = returnDueSdlMenuButton(outType, o1, o2, o3, o4, maxOrder); if (due) return due;
    pthread_mutex_lock(&g_sdlMenuMutex); const bool blocked = g_sdlMenuState.pointer.pressPending || g_sdlMenuState.pointer.finalReleasePending;
    pthread_mutex_unlock(&g_sdlMenuMutex); if (blocked) return 0;
    const uint64_t baseline = recoveryBaselineOrder(&g_sdlBaseline);
    if (baseline != UINT64_MAX) { if (baseline > maxOrder) return 0; if (returnRecoveryBaseline(&g_sdlBaseline, true, outType, o1, o2, o3, o4)) return 1; }
    for (;;) {
        const unsigned long long write = atomic_load_explicit(&g_writeSequence, memory_order_acquire);
        const unsigned long long read = atomic_load_explicit(&g_sdlReadSequence, memory_order_relaxed);
        const bool overflow = atomic_exchange_explicit(&g_sdlOverflowPending, false, memory_order_acq_rel);
        if (overflow || write - read > EVENT_WINDOW_SIZE) {
            amclInputBeginInteractionBatch(); pthread_mutex_lock(&g_pushMutex);
            captureRecoveryBaselineLocked(&g_sdlBaseline, &g_sdlReadSequence, &g_sdlOverflowPending);
            pthread_mutex_unlock(&g_pushMutex); amclInputEndInteractionBatch(); resetSdlMenuSession();
            return returnResetEvent(outType, o1, o2, o3, o4);
        }
        if (read == write) return 0;
        pthread_mutex_lock(&g_pushMutex); const GLFWInputSlot* slot = &g_events[read % EVENT_WINDOW_SIZE];
        if (atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed) != read + 1ULL) {
            pthread_mutex_unlock(&g_pushMutex); amclInputBeginInteractionBatch(); pthread_mutex_lock(&g_pushMutex);
            captureRecoveryBaselineLocked(&g_sdlBaseline, &g_sdlReadSequence, &g_sdlOverflowPending);
            pthread_mutex_unlock(&g_pushMutex); amclInputEndInteractionBatch(); resetSdlMenuSession(); return returnResetEvent(outType, o1, o2, o3, o4);
        }
        if (slot->interactionOrder > maxOrder) { pthread_mutex_unlock(&g_pushMutex); return 0; }
        GLFWInputEvent e = slot->event; const uint64_t interactionOrder = slot->interactionOrder;
        const uint64_t menuScopeEpoch = slot->menuScopeEpoch, toolScopeEpoch = slot->toolScopeEpoch;
        const uint32_t gestureToken = slot->gestureToken; const MenuRelativeMetadata relative = slot->relative;
        pthread_mutex_unlock(&g_pushMutex);
        pthread_mutex_lock(&g_sdlMenuMutex); toolRelease = retireMenuToolEvent(&g_sdlMenuState.left, &g_sdlMenuTool, &retiredTool);
        const uint32_t menuToken = g_sdlMenuState.pointer.token; const bool begun = g_sdlMenuState.pointer.gestureBegun;
        const bool downAccepted = g_sdlMenuState.pointer.downAccepted;
        const bool held = g_sdlMenuState.pointer.buttonDown || g_sdlMenuState.pointer.pressPending; pthread_mutex_unlock(&g_sdlMenuMutex);
        if (toolRelease) return returnLegacyEvent(&retiredTool, outType, o1, o2, o3, o4);
        if (isScopedMenuEvent(e.type) && (read < atomic_load_explicit(&g_sdlMenuTargetCutoff, memory_order_acquire) || !scopedMenuEventValid(e.type, menuScopeEpoch, toolScopeEpoch))) {
            atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue;
        }
        if (e.type == EVENT_TYPE_TOUCH_MENU_SCROLL && gestureToken && gestureToken != menuToken) { atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue; }
        double x = 0, y = 0; const bool endMoves = relativeMenuEndMoves(&e, &relative);
        if (!resolveRelativeMenuEvent(3, &e, &relative, menuToken, &x, &y)) { atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue; }
        const bool start = e.type == EVENT_TYPE_MENU_POINTER && (e.i1 == MENU_POINTER_BEGIN || e.i1 == MENU_POINTER_DOWN);
        const bool continuation = start && amclPointerIsContinuation(e.i1, (uint32_t)e.i4, menuToken, begun, held, downAccepted);
        if (start && !continuation && g_gestureTokenEpoch[3] == menuScopeEpoch && (uint32_t)e.i4 <= g_gestureTokenHigh[3]) { atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue; }
        if (start && !continuation && menuToken) {
            pthread_mutex_lock(&g_sdlMenuMutex); const int action = setLegacyLeftContribution(&g_sdlMenuState.left, true, false);
            clearSdlMenuTransactionLocked(); pthread_mutex_unlock(&g_sdlMenuMutex);
            if (action >= 0) return returnSdlMenuButtonEvent(action, outType, o1, o2, o3, o4);
        }
        if (start && !acceptMenuGestureStart(3, e.i1, (uint32_t)e.i4, menuToken, begun, held, downAccepted)) { atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue; }
        if (start && e.i1 == MENU_POINTER_BEGIN && queuedMenuInvalidates((uint32_t)e.i4, menuScopeEpoch, read + 1ULL, write, maxOrder, true)) { atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release); continue; }
        if (e.type == EVENT_TYPE_TOUCH_MENU_CURSOR || e.type == EVENT_TYPE_TOUCH_MENU_TOOL_CURSOR) e.type = EVENT_TYPE_CURSOR_POSITION;
        if (e.type == EVENT_TYPE_TOUCH_MENU_SCROLL || e.type == EVENT_TYPE_TOUCH_MENU_TOOL_SCROLL) e.type = EVENT_TYPE_SCROLL;
        if (e.type == EVENT_TYPE_CURSOR_POSITION) consumeOrderedCursor(&e, 3);
        atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release);
        if (e.type == EVENT_TYPE_MENU_POINTER) { const int emitted = consumeSdlMenuPointer(&e, interactionOrder, menuScopeEpoch, x, y, endMoves, outType, o1, o2, o3, o4); if (emitted) return emitted; continue; }
        if (e.type == EVENT_TYPE_INPUT_RESET) resetSdlMenuSession();
        if (e.type == EVENT_TYPE_TOUCH_MENU_TOOL || (e.type == EVENT_TYPE_KEY && e.i1 == 340) || (e.type == EVENT_TYPE_MOUSE_BUTTON && e.i1 <= GLFW_MOUSE_BUTTON_RIGHT)) {
            pthread_mutex_lock(&g_sdlMenuMutex); const bool emitted = applyMenuToolEvent(&g_sdlMenuState.left, &g_sdlMenuTool, &e, e.type == EVENT_TYPE_TOUCH_MENU_TOOL, toolScopeEpoch);
            pthread_mutex_unlock(&g_sdlMenuMutex); if (!emitted) continue;
        }
        if (e.type == EVENT_TYPE_CURSOR_POSITION) {
            const int words[4] = {e.i1, e.i2, e.i3, e.i4}; double px = 0, py = 0; memcpy(&px, words, sizeof(px)); memcpy(&py, words + 2, sizeof(py));
            commitMenuCursor(3, px, py, interactionOrder, committedMenuCursorActivation(3));
        }
        #if AMCL_INPUT_TRACE
        if(e.type==AMCL_LOOK_PREFIX_EVENT){
            // 真SDL原Next成功边缘只给该运输slot记READ，peek/截止等待不记。
            AmclInputLatencyV1 note;memset(&note,0,sizeof(note));
            note.prefix=(uint32_t)e.i1|((uint64_t)(uint32_t)e.i2<<32);
            note.ringSequence=read+1ULL;note.ringOrder=interactionOrder;
            amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,3,AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD,&note);
        }
        #endif
        return returnLegacyEvent(&e, outType, o1, o2, o3, o4);
    }
}

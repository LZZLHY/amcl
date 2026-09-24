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

#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
#include <unistd.h>
#include "../platform/graphics_observation_abi.h"
#endif
static void registerGraphicsPresentationSinks(void);
static void publishGraphicsPresentation(const char* provider);

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
// Native-only LWJGL2 recovery marker. It never enters GLFW3 callbacks; the Java backend uses it to
// clear its own key/button polling arrays after native ring recovery, because those arrays are a
// separate state cache that cannot be repaired by only clearing g_keyDownBuffer/g_mouseDownBuffer.
#define EVENT_TYPE_INPUT_RESET   1009
#define MENU_POINTER_MOVE         0
#define MENU_POINTER_DOWN         1
#define MENU_POINTER_UP           2
#define MENU_POINTER_CANCEL       3

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

// 公开入口的前向声明。表里每一项都必须是这些符号之一（见不变量 1）。
JNIEXPORT void inputBridge_pushEvent(int type, int i1, int i2, int i3, int i4);
JNIEXPORT void inputBridge_addLookDelta(double dx, double dy);
JNIEXPORT void inputBridge_setMenuCursor(double x, double y);
JNIEXPORT void inputBridge_notifyFramePresented(void);
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
} InputBridgeInstanceV1;

static InputBridgeInstanceV1 g_bridgeInstance;

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
        candidate->structSize < (unsigned int)sizeof(InputBridgeInstanceV1) ||
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

// 菜单指针事务状态只由 MC pump/setGrabState/glfwDestroyWindow 所在线程修改。i4 不再是可复用
// finger id，而是 libentry 分配的单调 transaction token；旧 UP/CANCEL 无权结束新 DOWN。
// DOWN 所在 pump 只提交 cursor；PRESS 必须保持 presentSerial+2，确保 1.21.11 的
// poll → swap → poll 与下一帧 accumulated movement 消费完整跨越。极快 tap 的 UP 会锁存，
// 随后仍与同一 token 的 PRESS 配对。
static bool g_menuPressPending = false;
static bool g_menuReleasePending = false;
static bool g_menuButtonDown = false;
static uint32_t g_menuTransactionToken = 0;
static unsigned long long g_presentSerial = 0;
static unsigned long long g_menuPressAfterPresent = 0;
static void* g_lastPumpWindow = NULL;

// Window/surface snapshot. XComponent publishes dimensions through env because it lives in libentry.so;
// glfw_compat is the single importer and commits each accepted pair here on the MC thread. The mutex keeps
// width/height in one epoch for future paired consumers and removes the old volatile data race with JNI reads.
// Do not make XComponent and CallbackBridge independent authoritative writers again: JNI compatibility input
// is routed through inputBridge_setWindowSize(), and GLFW's accepted surface pair wins on create/resize.
static pthread_mutex_t g_windowSizeMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_windowWidth = 1280;
static int g_windowHeight = 720;
static volatile bool g_shouldUpdateMouse = false;

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
    atomic_ullong publishedSequence; // 0=未发布；值为 event sequence + 1，避免初始 0 歧义
    GLFWInputEvent event;
} GLFWInputSlot;

static GLFWInputSlot g_events[EVENT_WINDOW_SIZE];
static atomic_ullong g_writeSequence = 0;
static atomic_ullong g_l3ReadSequence = 0;
static atomic_ullong g_l2ReadSequence = 0;
static atomic_ullong g_sdlReadSequence = 0;
static unsigned long long g_l3TargetSequence = 0; // StartPumping 快照，仅 MC pump 线程读写
static atomic_bool g_l3Active = false;
static atomic_bool g_l2Active = false;
static atomic_bool g_sdlActive = false;
static atomic_bool g_l3OverflowPending = false;
static atomic_bool g_l2OverflowPending = false;
static atomic_bool g_sdlOverflowPending = false;
static atomic_ullong g_overflowDropCount = 0;
static atomic_ullong g_sdlOverflowDropCount = 0;
static bool g_l3RecoveryPending = false; // 仅 MC pump 线程
// Window recreate 与 overflow 都必须通知 LWJGL2 Java 清它自己的 polling arrays。该标志只表达
// “返回一次 1009 reset”，不承载普通输入，因此可安全合并多次边界。
static atomic_bool g_l2ResetPending = false;
static uint32_t g_l2MenuTransactionToken = 0;
static atomic_bool g_sdlResetPending = false;
static pthread_mutex_t g_pushMutex = PTHREAD_MUTEX_INITIALIZER;

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
    uint32_t token;
    bool pressPending;
    bool releasePending;
    bool buttonDown;
    unsigned long long presentSerial;
    unsigned long long pressAfterPresent;
} SDLMenuPointerState;

static pthread_mutex_t g_sdlMenuMutex = PTHREAD_MUTEX_INITIALIZER;
static SDLMenuPointerState g_sdlMenuState;

static void clearSdlMenuTransactionLocked(void) {
    g_sdlMenuState.token = 0;
    g_sdlMenuState.pressPending = false;
    g_sdlMenuState.releasePending = false;
    g_sdlMenuState.buttonDown = false;
    g_sdlMenuState.pressAfterPresent = 0;
}

static void resetSdlMenuSession(void) {
    pthread_mutex_lock(&g_sdlMenuMutex);
    memset(&g_sdlMenuState, 0, sizeof(g_sdlMenuState));
    pthread_mutex_unlock(&g_sdlMenuMutex);
}

// Grab/focus/window boundaries may arrive after SDL has already accepted a PRESS. In that case
// preserve exactly one RELEASE for the SDL consumer; a pending-but-not-yet-visible press is simply
// discarded so CANCEL can never turn into a click.
static void cancelSdlMenuTransaction(void) {
    pthread_mutex_lock(&g_sdlMenuMutex);
    if (g_sdlMenuState.buttonDown) {
        g_sdlMenuState.token = 0;
        g_sdlMenuState.pressPending = false;
        g_sdlMenuState.releasePending = true;
        g_sdlMenuState.pressAfterPresent = 0;
    } else {
        clearSdlMenuTransactionLocked();
    }
    pthread_mutex_unlock(&g_sdlMenuMutex);
}

// Key/mouse state buffers
static unsigned char g_keyDownBuffer[512];
static unsigned char g_mouseDownBuffer[16];
static pthread_mutex_t g_downMutex = PTHREAD_MUTEX_INITIALIZER;

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
// ⚠️ 只补发非 NULL 的：NULL 在两侧 setter 里的语义都是"不注册/注销"，无条件补发会把
// owner 已注册的回调注销掉（若 owner 那侧另有注册者）。
static void replayLocalCallbacksToOwner(const InputBridgeInstanceV1* owner) {
    if (g_invoke_CursorPos && owner->setCursorPosCallback) {
        owner->setCursorPosCallback(g_invoke_CursorPos);
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
static void cancelMenuTransaction(void* window, bool emitRelease) {
    g_menuPressPending = false;
    g_menuReleasePending = false;
    g_menuPressAfterPresent = 0;
    g_menuTransactionToken = 0;
    if (g_menuButtonDown) {
        g_menuButtonDown = false;
        pthread_mutex_lock(&g_downMutex);
        g_mouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = 0;
        pthread_mutex_unlock(&g_downMutex);
        if (emitRelease && g_invoke_MouseButton) {
            g_invoke_MouseButton(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);
        }
    }
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
    unsigned char releasedKeys[512];
    unsigned char releasedButtons[16];

    pthread_mutex_lock(&g_downMutex);
    memcpy(releasedKeys, g_keyDownBuffer, sizeof(releasedKeys));
    memcpy(releasedButtons, g_mouseDownBuffer, sizeof(releasedButtons));
    memset(g_keyDownBuffer, 0, sizeof(g_keyDownBuffer));
    memset(g_mouseDownBuffer, 0, sizeof(g_mouseDownBuffer));
    pthread_mutex_unlock(&g_downMutex);

    for (int key = 0; key < 512; key++) {
        if (!releasedKeys[key]) continue;
        if (emitCallbacks && g_invoke_Key) g_invoke_Key(window, key, 0, GLFW_RELEASE, 0);
    }
    for (int button = 0; button < 16; button++) {
        if (!releasedButtons[button]) continue;
        if (emitCallbacks && g_invoke_MouseButton) {
            g_invoke_MouseButton(window, button, GLFW_RELEASE, 0);
        }
    }
}

static void recoverOverflowState(void* window, bool emitCallbacks, const char* consumer) {
    // Recovery 必须在 MC consumer 线程做：producer 线程只置标志，绝不能跨线程调用 Minecraft callback。
    cancelMenuTransaction(window, emitCallbacks);
    g_l2MenuTransactionToken = 0;
    clearConsumedDownState(window, emitCallbacks);

    const unsigned long long dropped =
        atomic_exchange_explicit(&g_overflowDropCount, 0ULL, memory_order_relaxed);
    LOGE("InputBridge ring overflow recovered consumer=%{public}s overwritten=%{public}llu",
         consumer, dropped);
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

static void sendData_locked(int type, int i1, int i2, int i3, int i4) {
    const unsigned long long sequence =
        atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
    GLFWInputSlot* slot = &g_events[sequence % EVENT_WINDOW_SIZE];
    slot->event.type = type;
    slot->event.i1 = i1;
    slot->event.i2 = i2;
    slot->event.i3 = i3;
    slot->event.i4 = i4;

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
    pthread_mutex_lock(&g_pushMutex);
    sendData_locked(type, i1, i2, i3, i4);
    pthread_mutex_unlock(&g_pushMutex);
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
    amclDesktopNotifyInput();
}

// v7 唯一跨 .so 坐标 ABI。libentry 只能表达“look 增量”或“菜单绝对位置”，不能取得内部
// 地址，也就无法绕过锁或把菜单坐标误写进相机坐标。双坐标隔离是 Back-to-Game 零瞬移修复
// 的组成部分，不得为了兼容旧协议重新合并。
JNIEXPORT void inputBridge_addLookDelta(double dx, double dy) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->addLookDelta(dx, dy); return; }
    // Final cross-DSO defense: never let a malformed producer permanently turn
    // the authoritative cursor pair into NaN/Inf. Higher layers reject earlier,
    // but this exported ABI must remain safe when called directly.
    if (!isfinite(dx) || !isfinite(dy)) {
        recordInvalidCursorWrite("look-delta-nonfinite");
        return;
    }
    pthread_mutex_lock(&g_cursorMutex);
    const double nextX = g_lookX + dx;
    const double nextY = g_lookY + dy;
    if (!isfinite(nextX) || !isfinite(nextY)) {
        pthread_mutex_unlock(&g_cursorMutex);
        recordInvalidCursorWrite("look-delta-overflow");
        return;
    }
    g_lookX = nextX;
    g_lookY = nextY;
    pthread_mutex_unlock(&g_cursorMutex);
    // 时延埋点的 in 端。放在**解锁之后**：它自己是原子操作，不需要 g_cursorMutex，
    // 而在锁内多做一次 clock_gettime 会把这条热路径的临界区拉长。
    noteLookSampleQueued();
    amclDesktopNotifyInput();
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

// 由 glfwSwapBuffers 在一次真实 present 完成后调用；与 PumpEvents 同属 MC 渲染线程，无需原子/锁。
// ⚠️ 必须与 pump 落在同一份 image 上：菜单 PRESS 的屏障是 `g_presentSerial + 2`，两者分家
// 会让每一次菜单点击永久停在 pending（而光标照常跟手）。委派保证了这一点。
JNIEXPORT void inputBridge_notifyFramePresented(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->notifyFramePresented(); return; }
    publishGraphicsPresentation("GLFW");
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
    if (bridgeTakeCursorChange(&rx, &ry) && g_invoke_CursorPos) {
        g_shouldUpdateMouse = true;
    }
}

void inputBridgePumpEvents(void* window) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->pumpEvents(window); return; }
    unsigned long long drainedThisCycle = 0ULL;
    g_lastPumpWindow = window;
    if (g_l3RecoveryPending) {
        g_l3RecoveryPending = false;
        recoverOverflowState(window, true, "LWJGL3");
    }
    // 菜单事务消费屏障：1.21.11 的每个 flipFrame 内会 poll→swap→poll 两次。
    // DOWN 的 cursor callback 可能发生在第一次 poll；必须跨过两次 present，才能保证 PRESS 前至少有一轮
    // MouseHandler.handleAccumulatedMovement() 在 Screen 仍打开时消费并清零 accumulatedDX/DY。
    // PRESS 回调可同步关闭 Screen 并切换 grabbed，此时已不存在会泄漏到相机的菜单位移。
    if (g_menuPressPending && g_presentSerial >= g_menuPressAfterPresent) {
        g_menuPressPending = false;
        if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire) && g_invoke_MouseButton) {
            pthread_mutex_lock(&g_downMutex);
            g_mouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = 1;
            pthread_mutex_unlock(&g_downMutex);
            g_menuButtonDown = true;
            g_invoke_MouseButton(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS, 0);
            if (g_menuReleasePending) {
                pthread_mutex_lock(&g_downMutex);
                g_mouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = 0;
                pthread_mutex_unlock(&g_downMutex);
                g_menuButtonDown = false;
                g_menuTransactionToken = 0;
                g_invoke_MouseButton(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);
            }
        }
        g_menuReleasePending = false;
    }

    // Window/framebuffer size callbacks are emitted by glfw_compat immediately after it accepts and commits
    // one surface pair. The bridge no longer re-reads env or emits a second callback here: doing so created
    // an independent resize path whose width/height could belong to a different surface epoch.

    // Send cursor position update。StartPumping 已比较成对快照；这里重新快照以包含同一 poll 中
    // MENU_POINTER 之前由其他生产线程提交的最新值，仍保证 X/Y 来自同一坐标 epoch。
    if (g_shouldUpdateMouse && g_invoke_CursorPos) {
        double reportX = 0.0, reportY = 0.0;
        bridgeCursorSnapshot(&reportX, &reportY);
        g_invoke_CursorPos(window, floor(reportX), floor(reportY));
        // 时延埋点的 out 端。**必须在回调之后**：我们要测的是"MC 看见它"的时刻，
        // 而不是"我们决定要报"的时刻 —— 回调本身是 MC 的代码，可能同步做不少事。
        // ⚠️ 只有这一处结算。菜单绝对坐标那条上报（下方 MENU_POINTER 分支）刻意不碰，
        // 理由见 `noteLookSampleReported` 上方第三条判据。
        noteLookSampleReported();
    }

    // Process event queue。target 是 StartPumping 的 write sequence 快照；本轮之后到达的事件留给
    // 下一次 poll。只在验证并复制 slot 时持 producer lock，callback 分发始终在锁外。
    unsigned long long readSequence =
        atomic_load_explicit(&g_l3ReadSequence, memory_order_relaxed);
    const unsigned long long targetSequence = g_l3TargetSequence;

    while (readSequence < targetSequence) {
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
            break;
        }
        event = slot->event;
        pthread_mutex_unlock(&g_pushMutex);
        switch (event.type) {
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
                if (token == 0) break; // 0 保留为“无事务”，fail closed

                if (isDown) {
                    // 新 DOWN 覆盖旧事务前必须先完整结束旧事务；特别是旧 PRESS 已发时要补 RELEASE。
                    if (g_menuTransactionToken != 0 || g_menuPressPending || g_menuButtonDown) {
                        cancelMenuTransaction(window, true);
                    }
                    g_menuTransactionToken = token;
                } else if (token != g_menuTransactionToken) {
                    break;
                }

                // CANCEL 的坐标没有语义（lifecycle/grab 可能没有新采样），不能把占位 0,0
                // 写成可见菜单位置；DOWN/MOVE/UP 才更新 absolute cursor。
                if (event.i1 != MENU_POINTER_CANCEL) {
                    inputBridge_setMenuCursor((double)event.i2, (double)event.i3);
                    double menuReportX = 0.0, menuReportY = 0.0;
                    if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire) &&
                        bridgeTakeCursorChange(&menuReportX, &menuReportY) && g_invoke_CursorPos) {
                        g_invoke_CursorPos(window, menuReportX, menuReportY);
                    }
                }

                if (isDown) {
                    if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
                        // 不可回退历史修复：必须跨两个真实 present，而不是 +1 或“下一次 poll”。
                        // 这与双坐标、中心重锚共同保证菜单 accumulated delta 不泄漏到相机。
                        g_menuPressAfterPresent = g_presentSerial + 2ULL;
                        g_menuPressPending = true;
                        g_menuReleasePending = false;
                    }
                } else if (event.i1 == MENU_POINTER_UP) {
                    if (g_menuButtonDown) {
                        pthread_mutex_lock(&g_downMutex);
                        g_mouseDownBuffer[GLFW_MOUSE_BUTTON_LEFT] = 0;
                        pthread_mutex_unlock(&g_downMutex);
                        g_menuButtonDown = false;
                        g_menuTransactionToken = 0;
                        if (g_invoke_MouseButton)
                            g_invoke_MouseButton(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);
                    } else if (g_menuPressPending) {
                        // 快速 tap：UP 先被消费，锁存到同 token 的延迟 PRESS 之后配对释放。
                        g_menuReleasePending = true;
                    } else {
                        g_menuTransactionToken = 0;
                    }
                } else if (event.i1 == MENU_POINTER_CANCEL) {
                    // CANCEL 永不合成点击；无论 PRESS 是否已发，结束后所有事务字段必须归零。
                    cancelMenuTransaction(window, true);
                }
                break;
            }
            case EVENT_TYPE_MOUSE_BUTTON:
                // 普通 left RELEASE 也可能是 grab/lifecycle 的兜底。它本身就是配对 RELEASE，故先
                // 清菜单事务但不额外回调，随后只分发这一条，避免 g_menuButtonDown 跨 epoch 残留。
                if (event.i1 == GLFW_MOUSE_BUTTON_LEFT && event.i2 == GLFW_RELEASE &&
                    (g_menuTransactionToken != 0 || g_menuPressPending || g_menuButtonDown)) {
                    cancelMenuTransaction(window, false);
                }
                // 鼠标按键轮询状态（glfwGetMouseButton）。MOUSE_BUTTON 的 i1=button、i2=action。
                if (event.i1 >= 0 && event.i1 < 16) {
                    pthread_mutex_lock(&g_downMutex);
                    g_mouseDownBuffer[event.i1] = (event.i2 != 0) ? 1 : 0;
                    pthread_mutex_unlock(&g_downMutex);
                }
                if (g_invoke_MouseButton) g_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if (g_invoke_Scroll) g_invoke_Scroll(window, event.i1, event.i2);
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
    }
    atomic_store_explicit(&g_l3ReadSequence, readSequence, memory_order_release);
    notePumpCycle(drainedThisCycle);
}

void inputBridgeStopPumping(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->stopPumping(); return; }
    // readSequence 已在 PumpEvents 发布给 producer；Stop 只结束本轮 cursor 通知。
    g_shouldUpdateMouse = false;
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
#define INPUT_BRIDGE_SDL_PROTO_VERSION 2

// 把本 image 的整张函数表填好并经 env 发布，同时把本 image 的角色钉成 owner。
//
// ⚠️ **只有拥有 XComponent 的那份 image 允许走到这里**（调用点在 glfw_compat.cpp 的
// `glfwOHOS_PublishNativeWindow` 与 `glfwInit` 的 `g_ohosNativeWindow != nullptr` 分支）。
// 若一份已经解析出 owner 的 image 仍来发布，那是接线错误，必须 fail closed 而不是把
// 所有消费者指向一份没有生产者的私有 ring —— 那正是 2026-09-01 那次回归的后果。
static bool publishBridgeInstanceDescriptor(void) {
    if (atomic_load_explicit(&g_bridgeOwner, memory_order_acquire) ==
        INPUT_BRIDGE_OWNER_SELF) {
        // 已发布过就**整段跳过，连 setenv 也不重做**。`glfwOHOS_PublishNativeWindow` 每次
        // surface 事件都会来，而重发既要重填一张内容恒等的表（给并发解引用的另一份 image
        // A once guard avoids setenv invalidating environment readers.
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

void inputBridge_publishAddress(void) {
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
             (unsigned long long)(uintptr_t)&inputBridge_setMenuCursor,
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
    //   env 是本项目既有的、已验证可跨 namespace 的通道（AMCL_NATIVE_WINDOW 同理）。
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
        char sdlbuf[256];
        snprintf(sdlbuf, sizeof(sdlbuf), "%s:%d:%llu,%llu,%llu,%llu,%llu,%llu,%llu",
                 INPUT_BRIDGE_SDL_PROTO_MAGIC, INPUT_BRIDGE_SDL_PROTO_VERSION,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNextEvent,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlSetActive,
                 (unsigned long long)(uintptr_t)&inputBridge_sdlNotifyFramePresented,
                 (unsigned long long)(uintptr_t)&inputBridge_setGrabState,
                 (unsigned long long)(uintptr_t)&inputBridge_isGrabbing,
                 (unsigned long long)(uintptr_t)&inputBridge_getCursorSnapshot,
                 (unsigned long long)(uintptr_t)&inputBridge_setLookCursor);
        setenv("AMCL_SDL_INPUT_BRIDGE", sdlbuf, 1);
    }

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
    inputBridge_setMenuCursor((double)x, (double)y);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendMouseButton(void* env, void* clazz, jint button, jint action, jint mods) {
    // Down state is committed only when a consumer accepts this event. Updating it here would let
    // an overwritten RELEASE disappear before overflow recovery can observe the consumed PRESS.
    //
    // ⚠️ 全部 JNI 生产者都必须经 `inputBridge_pushEvent` 而不是直接 `sendData`：这些入口跑在
    // MC 那份 image 里，直写本地 ring 会绕过跨 image 委派，事件从此谁也看不到。
    inputBridge_pushEvent(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey(void* env, void* clazz, jint key, jint scancode, jint action, jint mods) {
    // Keep producer enqueue separate from consumed state for overflow fail-safe recovery.
    inputBridge_pushEvent(EVENT_TYPE_KEY, key, scancode, action, mods);
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
    if (!p || !p[0]) return;      // libentry 尚未注册（未进游戏页）——下次翻转再试
    unsigned long long ptr = 0;
    if (sscanf(p, "%llu", &ptr) == 1 && ptr != 0ULL) {
        g_grabChangeCb = (amcl_grab_change_cb_t)(uintptr_t)ptr;
        LOGI("InputBridge: grab-change callback resolved from env");
    }
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(void* env, void* clazz, jboolean grabbing) {
    // Java 兼容路径也汇入同一个状态转换函数，禁止直接改 g_isGrabbing 形成第二权威写点。
    inputBridge_setGrabState(grabbing != 0);
    const bool currentGrab = inputBridge_isGrabbing();
    setenv("AMCL_CURSOR_MODE", currentGrab ? "grabbed" : "normal", 1);
    LOGI("InputBridge: Grab state changed to %{public}d, AMCL_CURSOR_MODE=%{public}s",
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
    // grab 标志与坐标迁移在同一临界区发布，snapshot 不会观察到混合 epoch。
    atomic_store_explicit(&g_isGrabbing, nextGrab, memory_order_release);
    pthread_mutex_unlock(&g_cursorMutex);

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
    resolveTouchCancelCb();
    if (g_touchCancelCb) g_touchCancelCb(reason);

    // 新窗口会重新声明 cursor mode。先回到 normal，并保留 setGrabState 内不可回退的双坐标重锚语义。
    inputBridge_setGrabState(0);
    cancelMenuTransaction(window, true);
    g_l2MenuTransactionToken = 0;
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
static int l2NextTypedEvent(int* outType, int* o1, int* o2, int* o3, int* o4) {
    for (;;) {
        if (g_l2TextScalarIndex < g_l2TextScalarCount) {
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
        const int status = amclBackendInputNext(AMCL_BACKEND_INPUT_LWJGL2, &ev);
        // ⚠️ UNAVAILABLE 必须与 EMPTY 分开：前者意味着 legacy 路由生效、物理边沿在 ring 里，
        // 继续往下读 ring 即可；把它当错误直接返回会丢掉全部物理输入。
        if (status != AMCL_BACKEND_INPUT_EVENT) return 0;
        if (ev.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT) {
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
    pthread_mutex_unlock(&g_pushMutex);
    // 这三样与 ring 的读游标同属"此刻之前的历史"，一起清（滚轮余量留着会让下一次会话
    // 的第一格提前或延后到达；菜单 token 留着会让新会话认领旧事务）。
    g_l2MenuTransactionToken = 0;
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
    atomic_store_explicit(&g_l2Active, true, memory_order_release);
    if (atomic_exchange_explicit(&g_l2ResetPending, false, memory_order_acq_rel)) {
        g_l2TextScalarCount = 0u;
        g_l2TextScalarIndex = 0u;
        return returnResetEvent(outType, o1, o2, o3, o4);
    }
    // typed 物理优先出货，然后才是 ring。**两者来源不重叠**（bit10 开时物理不进 ring），
    // 而 bit10 关时 typed 通道整条不可用 ⇒ 无论开关，同一个边沿只会出现一次。
    if (l2NextTypedEvent(outType, o1, o2, o3, o4)) return 1;

    for (;;) {
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
        if (read == write) return 0;

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
        pthread_mutex_unlock(&g_pushMutex);
        atomic_store_explicit(&g_l2ReadSequence, read + 1ULL, memory_order_release);

        if (e.type == EVENT_TYPE_MENU_POINTER) {
            const int phase = e.i1;
            const uint32_t token = (uint32_t)e.i4;
            if (token == 0) continue;
            if (phase == MENU_POINTER_DOWN) {
                // 新 token 覆盖旧 token；LWJGL2 状态查询会在 overflow/window 边界被 fail-safe 清零。
                g_l2MenuTransactionToken = token;
            } else if (token != g_l2MenuTransactionToken) {
                continue;
            }
            // LWJGL2 保持 absolute-menu 模型；grabbed 视角仍由后端 poll-delta 计算。CANCEL 的
            // 0,0 只是无采样占位，不能移动 menu cursor。
            if (phase != MENU_POINTER_CANCEL) {
                inputBridge_setMenuCursor((double)e.i2, (double)e.i3);
            }
            if (phase == MENU_POINTER_MOVE) continue;
            e.type = EVENT_TYPE_MOUSE_BUTTON;
            e.i1 = GLFW_MOUSE_BUTTON_LEFT;
            e.i2 = (phase == MENU_POINTER_DOWN) ? GLFW_PRESS : GLFW_RELEASE;
            e.i3 = 0;
            e.i4 = 0;
            if (phase == MENU_POINTER_UP || phase == MENU_POINTER_CANCEL) {
                g_l2MenuTransactionToken = 0;
            }
        }
        // Like the GLFW3 pump, publish polling state only after this consumer accepted the event.
        if (e.type == EVENT_TYPE_KEY && e.i1 >= 0 && e.i1 < 512) {
            pthread_mutex_lock(&g_downMutex);
            g_keyDownBuffer[e.i1] = (e.i3 != 0) ? 1 : 0;
            pthread_mutex_unlock(&g_downMutex);
        } else if (e.type == EVENT_TYPE_MOUSE_BUTTON && e.i1 >= 0 && e.i1 < 16) {
            pthread_mutex_lock(&g_downMutex);
            g_mouseDownBuffer[e.i1] = (e.i2 != 0) ? 1 : 0;
            pthread_mutex_unlock(&g_downMutex);
        }
        if (outType) *outType = e.type;
        if (o1) *o1 = e.i1;
        if (o2) *o2 = e.i2;
        if (o3) *o3 = e.i3;
        if (o4) *o4 = e.i4;
        return 1;
    }
}

// ============================================================
//  SDL3 消费端 API（MC 26.3+ 的 OpenHarmony video backend 经 dlsym 调）
//
//  SDL 必须拥有第三条独立 sequence；复用 g_l2ReadSequence 会把两个后端的生命周期、
//  overflow 和 reset 绑在一起，并可能在版本切换后继承另一个消费者的旧位置。
//  SetActive 应在 SDL video init/quit 调用。NextEvent 保留惰性激活兜底，但惰性激活会从
//  “此刻”开始消费，不重放 SDL 尚未初始化时产生的历史输入。
//
//  EVENT_TYPE_INPUT_RESET 表示 ring overflow 或 surface/window 边界。SDL 消费端收到后必须
//  释放它已经注入 SDL 的全部键和鼠标按钮，并重建相对光标基准，不能只清键盘。
// ============================================================

static int returnSdlMenuButtonEvent(int action,
                                    int* outType, int* o1, int* o2, int* o3, int* o4) {
    if (outType) *outType = EVENT_TYPE_MOUSE_BUTTON;
    if (o1) *o1 = GLFW_MOUSE_BUTTON_LEFT;
    if (o2) *o2 = action;
    if (o3) *o3 = 0;
    if (o4) *o4 = 0;
    return 1;
}

// Called only after the ring snapshot is drained. A queued CANCEL/UP must be interpreted before a
// present-qualified PRESS; otherwise a finger canceled before the frame boundary could still click.
static int returnDueSdlMenuButton(int* outType, int* o1, int* o2, int* o3, int* o4) {
    int action = -1;
    pthread_mutex_lock(&g_sdlMenuMutex);
    if (g_sdlMenuState.buttonDown && g_sdlMenuState.releasePending) {
        action = GLFW_RELEASE;
        clearSdlMenuTransactionLocked();
    } else if (g_sdlMenuState.pressPending &&
               g_sdlMenuState.presentSerial >= g_sdlMenuState.pressAfterPresent) {
        if (atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
            clearSdlMenuTransactionLocked();
        } else {
            g_sdlMenuState.pressPending = false;
            g_sdlMenuState.buttonDown = true;
            action = GLFW_PRESS;
        }
    }
    pthread_mutex_unlock(&g_sdlMenuMutex);
    return action >= 0 ? returnSdlMenuButtonEvent(action, outType, o1, o2, o3, o4) : 0;
}

// Consume one complete menu-pointer slot. Coordinates and phase come from the same ring entry;
// g_menuX/Y is updated only so the SDL backend's second cursor snapshot in this pump can publish
// the corresponding MOTION before this state machine becomes eligible to publish PRESS.
static int consumeSdlMenuPointer(const GLFWInputEvent* event,
                                 int* outType, int* o1, int* o2, int* o3, int* o4) {
    const int phase = event->i1;
    const uint32_t token = (uint32_t)event->i4;
    if (token == 0 || phase < MENU_POINTER_MOVE || phase > MENU_POINTER_CANCEL) return 0;

    bool publishCursor = false;
    bool emitRelease = false;
    pthread_mutex_lock(&g_sdlMenuMutex);
    if (phase == MENU_POINTER_DOWN) {
        emitRelease = g_sdlMenuState.buttonDown;
        clearSdlMenuTransactionLocked();
        if (!atomic_load_explicit(&g_isGrabbing, memory_order_acquire)) {
            g_sdlMenuState.token = token;
            g_sdlMenuState.pressPending = true;
            g_sdlMenuState.pressAfterPresent = g_sdlMenuState.presentSerial + 1ULL;
            publishCursor = true;
        }
    } else if (token == g_sdlMenuState.token) {
        if (phase != MENU_POINTER_CANCEL) publishCursor = true;
        if (phase == MENU_POINTER_UP) {
            if (g_sdlMenuState.buttonDown) {
                emitRelease = true;
                clearSdlMenuTransactionLocked();
            } else if (g_sdlMenuState.pressPending) {
                // A quick tap may finish before its movement frame is presented. Preserve the UP,
                // then emit PRESS+RELEASE as a pair after the barrier rather than dropping the tap.
                g_sdlMenuState.releasePending = true;
            } else {
                clearSdlMenuTransactionLocked();
            }
        } else if (phase == MENU_POINTER_CANCEL) {
            emitRelease = g_sdlMenuState.buttonDown;
            clearSdlMenuTransactionLocked();
        }
    }
    pthread_mutex_unlock(&g_sdlMenuMutex);

    if (publishCursor) {
        inputBridge_setMenuCursor((double)event->i2, (double)event->i3);
    }
    return emitRelease
        ? returnSdlMenuButtonEvent(GLFW_RELEASE, outType, o1, o2, o3, o4)
        : 0;
}

void inputBridge_sdlSetActive(int active) {
    // SDL 正常经 `AMCL_SDL_INPUT_BRIDGE` 拿到的就是 owner 的地址，所以这三条委派在
    // 26.3 路线上是恒等的。保留它们是为了让"按符号找"（历史 patch 里的 HostSym 形状）
    // 也落在同一份状态上，而不是悄悄开出第四条消费游标。
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->sdlSetActive(active); return; }
    registerGraphicsPresentationSinks();
    // Make the producer stop charging this consumer for overflow before moving its read cursor.
    // Re-activation starts at “now”: input created before SDL owned a window cannot be replayed safely.
    atomic_store_explicit(&g_sdlActive, false, memory_order_release);
    pthread_mutex_lock(&g_pushMutex);
    const unsigned long long write =
        atomic_load_explicit(&g_writeSequence, memory_order_acquire);
    atomic_store_explicit(&g_sdlReadSequence, write, memory_order_release);
    atomic_store_explicit(&g_sdlOverflowPending, false, memory_order_release);
    atomic_store_explicit(&g_sdlResetPending, false, memory_order_release);
    atomic_store_explicit(&g_sdlOverflowDropCount, 0ULL, memory_order_relaxed);
    pthread_mutex_unlock(&g_pushMutex);
    resetSdlMenuSession();
    atomic_store_explicit(&g_sdlActive, active != 0, memory_order_release);
}

void inputBridge_sdlNotifyFramePresented(void) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) { owner->sdlNotifyFramePresented(); return; }
    publishGraphicsPresentation("SDL3");
}

// 以下两个订阅者只负责输入屏障。真实呈现已由公共owner记录，SDL失活只影响输入，
// 不能使图形观测漏帧。GLFW回调仍在其渲染/pump线程执行，SDL状态继续由原互斥保护。
static void advanceGlfwPresentation(uint64_t window, uint64_t generation) {
    (void)window; (void)generation;
    g_presentSerial++;
}
static void advanceSdlPresentation(uint64_t window, uint64_t generation) {
    (void)window; (void)generation;
    if (!atomic_load_explicit(&g_sdlActive, memory_order_acquire)) return;
    pthread_mutex_lock(&g_sdlMenuMutex);
    g_sdlMenuState.presentSerial++;
    pthread_mutex_unlock(&g_sdlMenuMutex);
}
static void registerGraphicsPresentationSinks(void) {
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    // 输入owner可以早于图形观测owner建立，所以失败允许在下一次pump/激活时重试。
    // 成功后按PID缓存，fork后的新owner必须重新注册，不能沿用父进程发布状态。
    static atomic_uint_fast64_t registeredPid = 0;
    const uint64_t currentPid = (uint64_t)getpid();
    if (atomic_load_explicit(&registeredPid, memory_order_acquire) == currentPid) return;
    if (amclGraphicsRegisterPresentSinkV1("GLFW", advanceGlfwPresentation) &&
        amclGraphicsRegisterPresentSinkV1("SDL3", advanceSdlPresentation))
        atomic_store_explicit(&registeredPid, currentPid, memory_order_release);
#endif
}
static void publishGraphicsPresentation(const char* provider) {
#ifndef AMCL_INPUT_BRIDGE_HOST_TESTING
    registerGraphicsPresentationSinks();
    if (amclGraphicsDispatchPresentV1(provider, 0, 0)) return;
#endif
    // 观测owner尚未发布或宿主测试没有观测模块时，只保留原输入行为；不制造观测成功。
    if (strcmp(provider, "GLFW") == 0) advanceGlfwPresentation(0, 0);
    else if (strcmp(provider, "SDL3") == 0) advanceSdlPresentation(0, 0);
}

int inputBridge_sdlNextEvent(int* outType, int* o1, int* o2, int* o3, int* o4) {
    const InputBridgeInstanceV1* owner = bridgeDelegate();
    if (owner) return owner->sdlNextEvent(outType, o1, o2, o3, o4);
    if (!atomic_load_explicit(&g_sdlActive, memory_order_acquire)) {
        inputBridge_sdlSetActive(1);
    }
    if (atomic_exchange_explicit(&g_sdlResetPending, false, memory_order_acq_rel)) {
        resetSdlMenuSession();
        return returnResetEvent(outType, o1, o2, o3, o4);
    }

    for (;;) {
        const unsigned long long write =
            atomic_load_explicit(&g_writeSequence, memory_order_acquire);
        unsigned long long read =
            atomic_load_explicit(&g_sdlReadSequence, memory_order_relaxed);
        const bool flagged =
            atomic_exchange_explicit(&g_sdlOverflowPending, false, memory_order_acq_rel);
        if (flagged || write - read > EVENT_WINDOW_SIZE) {
            atomic_store_explicit(&g_sdlReadSequence, write, memory_order_release);
            resetSdlMenuSession();
            const unsigned long long dropped =
                atomic_exchange_explicit(&g_sdlOverflowDropCount, 0ULL, memory_order_relaxed);
            LOGE("InputBridge ring overflow recovered consumer=SDL overwritten=%{public}llu", dropped);
            return returnResetEvent(outType, o1, o2, o3, o4);
        }
        if (read == write) {
            return returnDueSdlMenuButton(outType, o1, o2, o3, o4);
        }

        GLFWInputEvent e;
        pthread_mutex_lock(&g_pushMutex);
        GLFWInputSlot* slot = &g_events[read % EVENT_WINDOW_SIZE];
        const unsigned long long published =
            atomic_load_explicit(&slot->publishedSequence, memory_order_relaxed);
        if (published != read + 1ULL) {
            const unsigned long long latest =
                atomic_load_explicit(&g_writeSequence, memory_order_relaxed);
            pthread_mutex_unlock(&g_pushMutex);
            atomic_store_explicit(&g_sdlReadSequence, latest, memory_order_release);
            resetSdlMenuSession();
            const unsigned long long dropped =
                atomic_exchange_explicit(&g_sdlOverflowDropCount, 0ULL, memory_order_relaxed);
            LOGE("InputBridge slot recovery consumer=SDL overwritten=%{public}llu", dropped);
            return returnResetEvent(outType, o1, o2, o3, o4);
        }
        e = slot->event;
        pthread_mutex_unlock(&g_pushMutex);
        atomic_store_explicit(&g_sdlReadSequence, read + 1ULL, memory_order_release);

        if (e.type == EVENT_TYPE_MENU_POINTER) {
            const int emitted = consumeSdlMenuPointer(&e, outType, o1, o2, o3, o4);
            if (emitted) return emitted;
            continue;
        }
        if (e.type == EVENT_TYPE_INPUT_RESET) resetSdlMenuSession();

        if (outType) *outType = e.type;
        if (o1) *o1 = e.i1;
        if (o2) *o2 = e.i2;
        if (o3) *o3 = e.i3;
        if (o4) *o4 = e.i4;
        return 1;
    }
}

// window_event_filter.cpp — 窗口级多模输入事件过滤器实现。契约与理由见 .h。
#include "window_event_filter.h"

#include <dlfcn.h>
#include <hilog/log.h>

#include <atomic>
#include <mutex>

#include "cursor_lock.h"
#include "input_channel_census.h"
#include "input_channel_policy.h"
#include "touch_input.h"

#undef LOG_TAG
#define LOG_TAG "AMCL_WINFILTER"

namespace {

// Input Kit 的事件对象只以指针形式穿过本模块，因此前向声明即可。
// 刻意**不** include multimodalinput/oh_input_manager.h：那会让 API 24 才有的
// Input_TouchEventToolType 成为编译期依赖，而本模块必须能在更低的
// compatibleSdkVersion 上编译并在运行期降级。
struct Input_TouchEvent;
struct Input_MouseEvent;

using TouchFilterCb = bool (*)(Input_TouchEvent*);
using MouseFilterCb = bool (*)(Input_MouseEvent*);
using RegisterTouchFilterFn = int32_t (*)(int32_t, TouchFilterCb);
using UnregisterTouchFilterFn = int32_t (*)(int32_t);
using RegisterMouseFilterFn = int32_t (*)(int32_t, MouseFilterCb);
using UnregisterMouseFilterFn = int32_t (*)(int32_t);

// 逐字对照 SDK 头：这些 getter 都是**直接返回值**，不是 out 参数 + Input_Result。
// §21.4 记录过一次按错误 ABI 复刻导致"除 action==0 外所有事件被静默丢弃"的事故，
// 这里的注释就是那次的防复发标记。
using GetTouchToolTypeFn = int32_t (*)(const Input_TouchEvent*);
using GetTouchActionFn = int32_t (*)(const Input_TouchEvent*);
using GetMouseActionFn = int32_t (*)(const Input_MouseEvent*);
using GetMouseButtonFn = int32_t (*)(const Input_MouseEvent*);
using GetMouseAxisTypeFn = int32_t (*)(const Input_MouseEvent*);
// ⚠️ 返回 float，不是 out 参数。§21.4 记录过一次把直接返回值误写成
// `Input_Result f(ev, T* out)` 导致整条通道静默失效的事故，这里逐字对照过 SDK 头。
using GetMouseAxisValueFn = float (*)(const Input_MouseEvent*);

// Input_TouchEventToolType（@since 24）。只用到鼠标那一档，本地定义避免头依赖。
constexpr int32_t kToolTypeMouse = 6;
// Input_TouchEventAction（@since 12）。
constexpr int32_t kTouchActionCancel = 0;
constexpr int32_t kTouchActionDown = 1;
constexpr int32_t kTouchActionUp = 3;
// Input_MouseEventAction（@since 12）：CANCEL=0 MOVE=1 BUTTON_DOWN=2 BUTTON_UP=3
// AXIS_BEGIN=4 AXIS_UPDATE=5 AXIS_END=6。本模块只把这些取值打进日志（见
// MouseEventFilter 的 action 探针），不再据此做任何分支 —— 接管已全部删除。
// WindowManager_ErrorCode::OK
constexpr int32_t kWindowManagerOk = 0;

struct Resolver {
    RegisterTouchFilterFn registerTouch = nullptr;
    UnregisterTouchFilterFn unregisterTouch = nullptr;
    RegisterMouseFilterFn registerMouse = nullptr;
    UnregisterMouseFilterFn unregisterMouse = nullptr;
    GetTouchToolTypeFn touchToolType = nullptr;
    GetTouchActionFn touchAction = nullptr;
    GetMouseActionFn mouseAction = nullptr;
    GetMouseButtonFn mouseButton = nullptr;
    GetMouseAxisTypeFn mouseAxisType = nullptr;
    GetMouseAxisValueFn mouseAxisValue = nullptr;
    bool attempted = false;
};

std::mutex g_mutex;
Resolver g_resolver;
bool g_installed = false;
int32_t g_installedWindowId = 0;

// ---- 回调热路径只碰这些原子量。绝不加锁：过滤回调位于每个输入包的必经路径上，
// ---- 在这里取锁会重演"每帧扫 /proc/self/maps"那次的个位数 FPS 回归。----
std::atomic<bool> g_filterArmed{false};   // 已安装且 toolType 可用
std::atomic<bool> g_degraded{false};      // 看门狗已降级：只观测、不过滤

// 看门狗状态。只在过滤回调线程访问（系统对同一窗口只维持一个回调，因此无并发写）。
// 用 relaxed 原子仅为了让诊断读取安全。
std::atomic<int32_t> g_gestureMoves{0};
std::atomic<bool> g_gestureSawArkts{false};
std::atomic<int32_t> g_consecutiveBlindGestures{0};
// 一次拖动至少要有这么多个被掐断的 MOVE，才有资格作为"onMouse 没恢复"的证据。
// 太小会把"轻点一下"误判成失败。
constexpr int32_t kWatchdogMinMovesPerGesture = 8;
// 连续这么多次"既没有合成包也没有 ArkTS 相对样本"就降级。取 2 而不是 1：
// 首次拖动可能恰好落在设备/焦点抖动上。
constexpr int32_t kWatchdogFailuresBeforeDegrade = 2;

// 首包取证日志：每个 (toolType, action) 组合只打一条，避免热路径刷屏。
std::atomic<uint32_t> g_loggedToolActionMask{0};

void LogOncePerToolAction(int32_t tool, int32_t action, bool dropped) {
    // tool 收敛到 0..7，action 收敛到 0..3 → 32 个组合刚好一个 uint32 位图。
    const int32_t t = (tool >= 0 && tool <= 7) ? tool : 7;
    const int32_t a = (action >= 0 && action <= 3) ? action : 3;
    const uint32_t bit = 1u << static_cast<uint32_t>(t * 4 + a);
    uint32_t seen = g_loggedToolActionMask.load(std::memory_order_relaxed);
    if (seen & bit) return;
    if (!g_loggedToolActionMask.compare_exchange_strong(
            seen, seen | bit, std::memory_order_acq_rel,
            std::memory_order_relaxed)) {
        return;  // 另一线程刚打过同一组合，不重复。
    }
    OH_LOG_INFO(LOG_APP,
                "AMCL_WINFILTER touch tool=%{public}d action=%{public}d "
                "dropped=%{public}d",
                tool, action, dropped ? 1 : 0);
}

// 触摸过滤回调。返回 true = 该事件不再向下分发。
bool TouchEventFilter(Input_TouchEvent* event) {
    if (event == nullptr) return false;
    amcl::input::census::Bump(
        amcl::input::census::Channel::WindowFilterTouchSeen);

    const GetTouchToolTypeFn toolTypeFn = g_resolver.touchToolType;
    const GetTouchActionFn actionFn = g_resolver.touchAction;
    // 解析器在安装时一次性写入、之后只读；安装与回调之间由窗口管理器的注册动作
    // 建立 happens-before，因此这里无需再同步。
    if (toolTypeFn == nullptr) return false;

    const int32_t tool = toolTypeFn(event);
    const int32_t action = actionFn != nullptr ? actionFn(event) : -1;
    if (tool != kToolTypeMouse) {
        // 真手指（或手写笔等）——永远放行。这条分支必须最短：它是触摸屏的正常路径。
        return false;
    }
    amcl::input::census::Bump(
        amcl::input::census::Channel::WindowFilterMouseDerived);

    // 边界 1：菜单态放行。本机左键不出现在 onMouse，菜单点击只以合成包存在。
    // 边界 2：看门狗已降级则只观测。
    const bool drop = g_filterArmed.load(std::memory_order_relaxed) &&
                      !g_degraded.load(std::memory_order_relaxed) &&
                      amcl_cursor_lock_active();
    LogOncePerToolAction(tool, action, drop);
    if (!drop) return false;

    // ---- 看门狗记账。只在真的掐断时统计，否则"没掐断"也会被算成失败。----
    if (action == kTouchActionDown) {
        g_gestureMoves.store(0, std::memory_order_relaxed);
        g_gestureSawArkts.store(false, std::memory_order_relaxed);
    } else if (action == kTouchActionUp || action == kTouchActionCancel) {
        const int32_t moves = g_gestureMoves.load(std::memory_order_relaxed);
        const bool sawArkts = g_gestureSawArkts.load(std::memory_order_relaxed);
        if (moves >= kWatchdogMinMovesPerGesture && !sawArkts) {
            const int32_t fails =
                g_consecutiveBlindGestures.fetch_add(1, std::memory_order_relaxed) + 1;
            OH_LOG_WARN(LOG_APP,
                        "AMCL_WINFILTER blind drag gesture moves=%{public}d "
                        "consecutive=%{public}d",
                        moves, fails);
            if (fails >= kWatchdogFailuresBeforeDegrade) {
                g_degraded.store(true, std::memory_order_relaxed);
                // 这条必须醒目：它意味着"掐断合成包后 onMouse 会恢复"这个推断在本
                // 设备上不成立。
                //
                // ⚠️ 这里曾写「视角通道已交还触摸镜像（有界但可用）」——**已不成立**：
                // 触摸镜像视角通道整条在 §30.2 按用户实测删除了（`lookMirror` 计数器
                // 也已随之移除）。降级之后的真实后果是**该状态下没有任何视角通道**，
                // 比"有界但可用"严重得多。措辞必须如实，否则下一轮判读会以为已有兜底。
                OH_LOG_ERROR(LOG_APP,
                             "AMCL_WINFILTER degraded: onMouse did not resume "
                             "after dropping mouse-derived touch; the touch-mirror "
                             "look channel no longer exists, so held-button drag "
                             "look has NO producer in this state");
            }
        } else {
            g_consecutiveBlindGestures.store(0, std::memory_order_relaxed);
        }
        g_gestureMoves.store(0, std::memory_order_relaxed);
        g_gestureSawArkts.store(false, std::memory_order_relaxed);
    } else {
        g_gestureMoves.fetch_add(1, std::memory_order_relaxed);
        if (ohos_arkts_relative_channel_live() != 0) {
            g_gestureSawArkts.store(true, std::memory_order_relaxed);
        }
    }

    amcl::input::census::Bump(
        amcl::input::census::Channel::WindowFilterDropped);
    return true;
}

// 鼠标过滤回调 —— **纯观测，永远返回 false**。
//
// 它只回答一个问题：鼠标事件有没有到过窗口层？真机已用它给出决定性证据：按住左键期间
// 该回调以 110~127 次/秒被调用，而同期 ArkUI `onMouse` 的 Move 与 XComponent 的
// native mouse MOVE 双双为 0 —— 即鼠标事件确实以全速到达窗口层，事件是丢在
// Window → ArkUI 分发之间的，不是平台没采集。这条计数是提交给华为的最小复现证据的核心。
//
// ⚠️ 这里曾经做过两件"接管"，**都已删除，不要再加回来**：
//
//   1. **取走左键 DOWN/UP**（想让 ArkUI 不知道左键被按下，从而不触发鼠标转触摸）。
//      真机结论：转换确实被阻止了（`mirrorMove` 归零），但 `lookArkts` 在按住期间
//      依然缺席 ⇒ ArkUI 的转换门控读的是**每个 MOVE 自带的 `pressedButtons`**，
//      不是它自己累积的按键状态。所以这条路收益为零。
//      而代价是实打实的：本模块与合成触摸镜像通道**互相抢** LEFT 的所有权，
//      逐秒交替（`wfLeftTaken` 与 `btnRejected` 同时出现），于是
//      "按下由一方送出、抬起被另一方吞掉" → MC 里左键永久卡在按下态，
//      用户表现为**按住左键失效**；退出到菜单时所有权不交还，又让**菜单点不动**。
//      左键的通道选择现在由 input_channel_policy 统一决定，本模块不参与。
//
//   2. **取走轴事件（滚轮）**。真机结论：`wfAxisTaken` 在两台设备上都是 0，
//      即窗口层根本没有 `AXIS_BEGIN/UPDATE/END` 可取（本模块的 action 探针会给出
//      窗口层实际收到过哪些 action 取值）。收益为零，却多出一条会与 native AXIS
//      抢符号的滚轮产出通道。滚轮所有者同样交给 input_channel_policy。
//
// 结论：本回调必须保持"零副作用"。任何"顺手在这里处理一下"的改动都会重演上面两次故障。
bool MouseEventFilter(Input_MouseEvent* event) {
    if (event == nullptr) return false;
    amcl::input::census::Bump(
        amcl::input::census::Channel::WindowFilterMouseSeen);
    // 同一个"鼠标事件到过窗口层"的事实也是光标锁钉住模式看门狗的第二条判据：
    // 只有确实有鼠标活动、却一个相对样本都没有，才说明钉住模式在本设备上取不到
    // rawDelta。缺了这一条会把"玩家静止不动"误判成能力缺失（真机已复现）。
    amcl_cursor_lock_note_pointer_activity();

    const GetMouseActionFn actionFn = g_resolver.mouseAction;
    if (actionFn == nullptr) return false;

    // ---- 常开取证：窗口层到底收到哪些 action，每个取值只打一条 ----
    // 这是目前唯一能回答"窗口层有没有轴事件"的证据：若这里从未出现 4/5/6，
    // 就说明 AXIS_* 根本没抵达窗口层，而不是我们漏读了。
    // action 取值域只有 0..6，位图成本可忽略。
    {
        const int32_t probeAction = actionFn(event);
        static std::atomic<uint32_t> s_seenActions{0};
        const uint32_t bit =
            1u << static_cast<uint32_t>((probeAction >= 0 && probeAction <= 30)
                                            ? probeAction : 31);
        uint32_t seen = s_seenActions.load(std::memory_order_relaxed);
        if ((seen & bit) == 0u &&
            s_seenActions.compare_exchange_strong(seen, seen | bit,
                                                  std::memory_order_acq_rel,
                                                  std::memory_order_relaxed)) {
            OH_LOG_INFO(LOG_APP,
                        "AMCL_WINFILTER mouse action=%{public}d "
                        "(1=MOVE 2=DOWN 3=UP 4=AXIS_BEGIN 5=AXIS_UPDATE "
                        "6=AXIS_END)",
                        probeAction);
        }
    }

    // 纯观测：不改变任何事件的去向。
    return false;
}

const Resolver& ResolveLocked() {
    if (g_resolver.attempted) return g_resolver;
    g_resolver.attempted = true;

    // RTLD_DEFAULT 优先：库已在进程映像里就不必再增加引用计数。
    auto sym = [](const char* name) -> void* {
        return dlsym(RTLD_DEFAULT, name);
    };
    g_resolver.registerTouch = reinterpret_cast<RegisterTouchFilterFn>(
        sym("OH_NativeWindowManager_RegisterTouchEventFilter"));
    g_resolver.unregisterTouch = reinterpret_cast<UnregisterTouchFilterFn>(
        sym("OH_NativeWindowManager_UnregisterTouchEventFilter"));
    g_resolver.registerMouse = reinterpret_cast<RegisterMouseFilterFn>(
        sym("OH_NativeWindowManager_RegisterMouseEventFilter"));
    g_resolver.unregisterMouse = reinterpret_cast<UnregisterMouseFilterFn>(
        sym("OH_NativeWindowManager_UnregisterMouseEventFilter"));
    if (g_resolver.registerTouch == nullptr ||
        g_resolver.unregisterTouch == nullptr) {
        void* handle = dlopen("libnative_window_manager.so", RTLD_NOW);
        if (handle != nullptr) {
            g_resolver.registerTouch = reinterpret_cast<RegisterTouchFilterFn>(
                dlsym(handle, "OH_NativeWindowManager_RegisterTouchEventFilter"));
            g_resolver.unregisterTouch = reinterpret_cast<UnregisterTouchFilterFn>(
                dlsym(handle, "OH_NativeWindowManager_UnregisterTouchEventFilter"));
            g_resolver.registerMouse = reinterpret_cast<RegisterMouseFilterFn>(
                dlsym(handle, "OH_NativeWindowManager_RegisterMouseEventFilter"));
            g_resolver.unregisterMouse = reinterpret_cast<UnregisterMouseFilterFn>(
                dlsym(handle, "OH_NativeWindowManager_UnregisterMouseEventFilter"));
            // handle 故意不 close：解析出的指针必须在进程生命周期内有效。
        }
    }

    g_resolver.touchToolType = reinterpret_cast<GetTouchToolTypeFn>(
        sym("OH_Input_GetTouchEventToolType"));
    g_resolver.touchAction = reinterpret_cast<GetTouchActionFn>(
        sym("OH_Input_GetTouchEventAction"));
    g_resolver.mouseAction = reinterpret_cast<GetMouseActionFn>(
        sym("OH_Input_GetMouseEventAction"));
    g_resolver.mouseButton = reinterpret_cast<GetMouseButtonFn>(
        sym("OH_Input_GetMouseEventButton"));
    g_resolver.mouseAxisType = reinterpret_cast<GetMouseAxisTypeFn>(
        sym("OH_Input_GetMouseEventAxisType"));
    g_resolver.mouseAxisValue = reinterpret_cast<GetMouseAxisValueFn>(
        sym("OH_Input_GetMouseEventAxisValue"));
    if (g_resolver.touchToolType == nullptr ||
        g_resolver.mouseButton == nullptr ||
        g_resolver.mouseAxisValue == nullptr) {
        void* handle = dlopen("libohinput.so", RTLD_NOW);
        if (handle != nullptr) {
            g_resolver.touchToolType = reinterpret_cast<GetTouchToolTypeFn>(
                dlsym(handle, "OH_Input_GetTouchEventToolType"));
            g_resolver.touchAction = reinterpret_cast<GetTouchActionFn>(
                dlsym(handle, "OH_Input_GetTouchEventAction"));
            g_resolver.mouseAction = reinterpret_cast<GetMouseActionFn>(
                dlsym(handle, "OH_Input_GetMouseEventAction"));
            g_resolver.mouseButton = reinterpret_cast<GetMouseButtonFn>(
                dlsym(handle, "OH_Input_GetMouseEventButton"));
            g_resolver.mouseAxisType = reinterpret_cast<GetMouseAxisTypeFn>(
                dlsym(handle, "OH_Input_GetMouseEventAxisType"));
            g_resolver.mouseAxisValue = reinterpret_cast<GetMouseAxisValueFn>(
                dlsym(handle, "OH_Input_GetMouseEventAxisValue"));
        }
    }

    // axisType/axisValue 也必须打：`wfAxisTaken=0` 有两种完全不同的原因 ——
    // (a) 窗口层根本没收到 AXIS_* action（轴事件在到达窗口过滤器之前就被消化了），
    // (b) axisValue getter 没解析到，回调里直接 return false 了。
    // 少了这两位，两台真机上的 `wfAxisTaken=0` 就是一条无法判读的证据。
    OH_LOG_INFO(LOG_APP,
                "AMCL_WINFILTER resolved touchFilter=%{public}d "
                "mouseFilter=%{public}d toolType=%{public}d "
                "mouseAction=%{public}d mouseButton=%{public}d "
                "mouseAxisType=%{public}d mouseAxisValue=%{public}d",
                g_resolver.registerTouch != nullptr ? 1 : 0,
                g_resolver.registerMouse != nullptr ? 1 : 0,
                g_resolver.touchToolType != nullptr ? 1 : 0,
                g_resolver.mouseAction != nullptr ? 1 : 0,
                g_resolver.mouseButton != nullptr ? 1 : 0,
                g_resolver.mouseAxisType != nullptr ? 1 : 0,
                g_resolver.mouseAxisValue != nullptr ? 1 : 0);
    return g_resolver;
}

}  // namespace

extern "C" AmclWindowInputFilterResult amcl_window_input_filter_install(
        int32_t windowId) {
    std::lock_guard<std::mutex> guard(g_mutex);
    const Resolver& resolver = ResolveLocked();
    // 注册与注销必须成对可用。只有注册而无法注销，会让回调在窗口销毁后仍被系统持有。
    if (resolver.registerTouch == nullptr || resolver.unregisterTouch == nullptr) {
        return AMCL_WINDOW_INPUT_FILTER_UNSUPPORTED;
    }
    if (windowId <= 0) {
        OH_LOG_WARN(LOG_APP, "refusing filter install for windowId=%{public}d",
                    windowId);
        return AMCL_WINDOW_INPUT_FILTER_INVALID_ARGUMENT;
    }
    if (g_installed && g_installedWindowId == windowId) {
        return AMCL_WINDOW_INPUT_FILTER_UNCHANGED;
    }
    // 窗口换代：先摘掉旧窗口上的回调，否则系统仍持有指向旧 windowId 的注册。
    if (g_installed && g_installedWindowId != windowId) {
        resolver.unregisterTouch(g_installedWindowId);
        if (resolver.unregisterMouse != nullptr) {
            resolver.unregisterMouse(g_installedWindowId);
        }
        g_installed = false;
        g_installedWindowId = 0;
        g_filterArmed.store(false, std::memory_order_release);
    }

    const int32_t code = resolver.registerTouch(windowId, &TouchEventFilter);
    if (code != kWindowManagerOk) {
        // 1000=INVAILD_WINDOW_ID，2000=SERVICE_ERROR。
        OH_LOG_WARN(LOG_APP,
                    "RegisterTouchEventFilter(%{public}d) failed code=%{public}d "
                    "(1000=invalidWindowId 2000=serviceError)",
                    windowId, code);
        return AMCL_WINDOW_INPUT_FILTER_PLATFORM_ERROR;
    }
    // 鼠标探针是纯观测，失败不影响主功能，因此只记日志不回滚。
    if (resolver.registerMouse != nullptr) {
        const int32_t mouseCode =
            resolver.registerMouse(windowId, &MouseEventFilter);
        if (mouseCode != kWindowManagerOk) {
            OH_LOG_WARN(LOG_APP,
                        "RegisterMouseEventFilter(%{public}d) failed code=%{public}d "
                        "(probe only; touch filter stays installed)",
                        windowId, mouseCode);
        }
    }

    g_installed = true;
    g_installedWindowId = windowId;
    g_degraded.store(false, std::memory_order_relaxed);
    g_consecutiveBlindGestures.store(0, std::memory_order_relaxed);
    g_gestureMoves.store(0, std::memory_order_relaxed);
    g_gestureSawArkts.store(false, std::memory_order_relaxed);

    if (resolver.touchToolType == nullptr) {
        // 注册成功但无法分类。此时保持"只观测"：过滤不了鼠标包总比误吞真手指好。
        g_filterArmed.store(false, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
                    "window filters installed on %{public}d but "
                    "OH_Input_GetTouchEventToolType is missing (API<24); "
                    "observing only, never dropping",
                    windowId);
        return AMCL_WINDOW_INPUT_FILTER_NO_TOOLTYPE;
    }
    g_filterArmed.store(true, std::memory_order_release);
    OH_LOG_INFO(LOG_APP,
                "window input filters installed on %{public}d "
                "(dropping mouse-derived touch while the cursor is locked)",
                windowId);
    return AMCL_WINDOW_INPUT_FILTER_OK;
}

extern "C" AmclWindowInputFilterResult amcl_window_input_filter_uninstall(
        int32_t windowId) {
    std::lock_guard<std::mutex> guard(g_mutex);
    const Resolver& resolver = ResolveLocked();
    if (resolver.unregisterTouch == nullptr) {
        return AMCL_WINDOW_INPUT_FILTER_UNSUPPORTED;
    }
    if (!g_installed) return AMCL_WINDOW_INPUT_FILTER_UNCHANGED;

    // 先停止过滤，再摘回调：这样"已经进入回调的那一个包"也不会被掐断。
    g_filterArmed.store(false, std::memory_order_release);
    const int32_t target =
        g_installedWindowId != 0 ? g_installedWindowId : windowId;
    const int32_t code = resolver.unregisterTouch(target);
    if (resolver.unregisterMouse != nullptr) {
        resolver.unregisterMouse(target);
    }
    // 无论平台是否报错都清本地状态：系统也会在窗口销毁时丢掉注册，
    // 本进程不能停留在"以为还装着、但无法再摘"的状态。
    g_installed = false;
    g_installedWindowId = 0;
    g_degraded.store(false, std::memory_order_relaxed);
    g_consecutiveBlindGestures.store(0, std::memory_order_relaxed);
    if (code != kWindowManagerOk) {
        OH_LOG_WARN(LOG_APP,
                    "UnregisterTouchEventFilter(%{public}d) failed code=%{public}d",
                    target, code);
        return AMCL_WINDOW_INPUT_FILTER_PLATFORM_ERROR;
    }
    OH_LOG_INFO(LOG_APP, "window input filters removed from %{public}d", target);
    return AMCL_WINDOW_INPUT_FILTER_OK;
}

extern "C" bool amcl_window_input_filter_supported(void) {
    std::lock_guard<std::mutex> guard(g_mutex);
    const Resolver& resolver = ResolveLocked();
    return resolver.registerTouch != nullptr &&
           resolver.unregisterTouch != nullptr;
}

extern "C" bool amcl_window_filter_left_held(void) {
    // 左键按住状态的唯一来源已经收敛到策略层：它按 press/release 配对维护，
    // 不依赖某条具体通道，因此换设备也不会失真。本函数保留只为兼容既有分桶取证的
    // 调用点（native mouse MOVE 按"左键按住/未按住"分两桶）。
    return amcl_input_policy_left_held();
}

extern "C" bool amcl_window_input_filter_active(void) {
    return g_filterArmed.load(std::memory_order_acquire) &&
           !g_degraded.load(std::memory_order_relaxed);
}

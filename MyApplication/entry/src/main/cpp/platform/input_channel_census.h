// input_channel_census.h — 常开输入通道普查（production build 也生效）
//
// 存在理由（不是调试残留，请不要顺手删）：
// 本机（MatePad Pro / API 24）上"某个物理输入到底走哪条平台通道"无法从 SDK 文档推断，
// 已经有四条被真机推翻的推断：
//   1) GetTouchEventSourceType 能区分鼠标 —— 假（618/618 全 TOUCHSCREEN）
//   2) 滚轮走 native UIInputEvent(AXIS) —— 假（注册成功但 0 样本）
//   3) 左键会出现在 ArkUI onMouse —— 假（28/28 边沿全是右键掩码）
//   4) 平台没有指针锁能力 —— 假（OH_WindowManager_LockCursor 存在）
// 每次靠"编译期开关的遥测构建"重新取证都要占用一整轮真机时间，而遥测构建本身还会压低帧率，
// 于是又引入"这次的现象是不是遥测造成的"这类噪声。
//
// 因此这里保留一份**恒定开启**的聚合普查：每个通道只做一次 relaxed 原子自增，
// 并且**仅在计数发生变化时**每 1s 打印一行汇总。稳态成本 = 每事件一次原子加 +
// 一次 CLOCK_MONOTONIC_COARSE 读取，与逐事件打点相差几个数量级，可长期留在产品构建里。
//
// 输出形如：
//   AMCL_CENSUS 1s fingerDown=2 fingerMove=41 mirrorMove=88 look=88 scrollOut=0 ...
// 只列出本窗口内非零的通道，零通道被省略 —— "该通道一次都没来"本身就是最重要的证据。

#ifndef AMCL_PLATFORM_INPUT_CHANNEL_CENSUS_H
#define AMCL_PLATFORM_INPUT_CHANNEL_CENSUS_H

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <hilog/log.h>

namespace amcl {
namespace input {
namespace census {

enum class Channel : int {
    // ---- native XComponent 触摸 ingress ----
    TouchFingerDown = 0,   // tool=FINGER：真实手指
    TouchFingerMove,
    TouchFingerUp,
    TouchMirrorDown,       // tool=UNKNOWN 且光标锁生效：平台把鼠标镜像成触摸
    TouchMirrorMove,
    TouchMirrorUp,
    TouchToolMouseDropped, // tool=MOUSE/LENS：显式鼠标包，被触摸层拒收

    // ---- 视角（look）----
    LookApplied,           // applyLookDelta 唯一漏斗：任何来源产生了视角增量
    LookFromSchemaTouch,   // 来源：schema 空白/拖拽 look（真实手指）
    LookFromArktsMotion,   // 来源：ArkTS onMouse Move 事务（不按键移动鼠标）
    // ⚠️ 曾有 LookFromTouchMirror / "lookMirror"：按住左键拖动时由镜像 MOVE 的坐标差分
    // 产出的视角。整条通道已在 §30.2 按用户实测删除（它有界 —— 坐标被窗口夹取，
    // 且与 rawDelta 不同量纲，切换瞬间手感突变）。计数器随之移除。
    // 依据就是本文件下方那条自己定的规则：**不留永远为零的名字**，否则下一轮判读会把
    // "这个通道一次都没来"误当成线索。真机已确认它零 Bump（`lookMirror` 全日志 0 次）。
    LookFromGamepad,

    // ---- 滚轮 / hotbar ----
    NativeAxisCallback,    // native RegisterUIInputEventCallback(AXIS) 被调用
    NativeAxisScroll,      // 上述回调真的产生了一格 scroll
    ArktsAxisCallback,     // ArkTS onAxisEvent 被调用（本机滚轮的关键未知项）
    ArktsAxisYielded,      // ArkTS 让位给 native 通道
    ArktsAxisScroll,       // ArkTS onAxisEvent 产生了一格 scroll
    TouchWheelScroll,      // 合成触摸流被运动学指纹认定为滚轮后产生的一格 scroll
    SchemaTouchScroll,     // 虚拟滚轮区（手指）产生的 scroll
    ScrollDelivered,       // 进入 bridge ring 的 scroll 总数

    // ---- 指针派生的合成触摸包（tool=FINGER 但其实是鼠标）----
    TouchPointerDerivedDown,  // DOWN 被判为指针派生 → 不进虚拟控件层
    TouchPointerDerivedPromoted,  // 判错了：后续样本证明它是真手指，已放行

    // ---- 鼠标按键 ----
    ButtonFromArkui,       // ArkTS onMouse Press/Release 事务
    ButtonFromNativeMouse, // native DispatchMouseEvent
    ButtonFromTouchMirror, // 触摸镜像推导出的左键
    ButtonRejectedByClaim, // 被 source 仲裁丢弃（另一通道正持有该按钮）

    // ---- 窗口级事件过滤器（window_event_filter.cpp，在 ArkUI 分发之前）----
    WindowFilterTouchSeen,   // 触摸过滤回调被调用的总包数
    WindowFilterMouseDerived,// 其中 Input_TouchEvent 报 tool=TOOL_TYPE_MOUSE 的包
    WindowFilterDropped,     // 真的被掐断、没有进入 ArkUI 的包
    WindowFilterMouseSeen,   // 鼠标过滤探针被调用（证明鼠标事件到过窗口层）
    // ⚠️ 曾有 wfLeftTaken / btnWinFilter / wfAxisTaken / wfAxisScroll 四个通道，
    // 对应窗口级过滤器的左键接管与轴事件接管。两项接管均已按真机证据删除
    // （左键接管与镜像通道互抢所有权导致左键卡死；轴事件在两台设备上都是 0 样本），
    // 计数器随之移除，避免留下永远为零的名字让下一轮判读误以为"通道没来"。

    // ---- 物理键盘（此前整条链**零计数器**，是 ESC/修饰键问题查不下去的根因）----
    //
    // 判读方式：
    //   · 正常单次按键 ⇒ keyDown 与 keyUp 成对出现；
    //   · 按住不放     ⇒ 一个 keyDown 之后 keyRepeat 持续上升，最后一个 keyUp；
    //   · **keyRepeat 上升而 keyDown 不动，且 keyOwnerless 同步上升 ⇒ ArkTS 的 held 缓存
    //     与 native 的 owner 状态失步**，该键已经"失灵"。这正是 ESC 快按后失效的判据。
    KeyDown,               // 首次按下（ArkTS 判为 FirstDown）
    KeyRepeat,             // 平台自动重复（ArkTS 判为 Repeat）
    KeyUp,                 // 抬起
    KeyRepeatSelfHealed,   // Repeat 到达但已超出重复窗口 ⇒ 判定为陈旧 held，已改判首次按下
    KeyOwnerlessEdge,      // native 侧收到一个没有 owner 的边沿（REPEAT/UP），已丢弃

    // ---- 单一所有者策略层（input_channel_policy）的让位计数 ----
    // 让位是**正常**行为，不是错误：它证明策略层真的在起作用。判读要点是
    // "同一秒里 btnYield 与某条 btnXxx 成对出现" ⇒ 竞争存在且已被收敛到一条通道。
    LeftEdgeYielded,         // 左键边沿被拒（**总数**；下面四个细分之和必须等于它）
    // ⚠️ 总数保留原语义 —— 规范 §6.3 的判读规则建立在它上面。四个细分的排查方向完全不同，
    // 拆开的理由、判读方式与"恒零桶为何不违反本文件规则"见计划 §107.4。
    LeftEdgeYieldedNotOwner,   // DOWN：本通道不是优先级所有者
    LeftEdgeYieldedDupDown,    // DOWN：是所有者但已有按下在飞行（平台重发 / 合成流重复）
    LeftEdgeYieldedNoPress,    // UP：当前没有按下在飞行（抬起多于按下）
    LeftEdgeYieldedOtherOwner, // UP：持有者是另一条通道 —— **按设计不可达**，非零即真信号
    WheelYielded,            // 滚轮样本被策略层拒绝（非所有者）

    // ---- native XComponent mouse 回调（与 ArkUI onMouse 并列的另一条鼠标通道）----
    // 分成两桶是工单级证据：若"按住左键"那一桶恒为 0 而窗口层 wfMouse≈110~120/s，
    // 则应用层已无任何可用写法，问题只能是平台在 Window→ArkUI 之间截断了鼠标 MOVE。
    NativeMouseMove,             // 未按住左键时的 native mouse MOVE
    NativeMouseMoveWhileLeftHeld,// 按住左键时的 native mouse MOVE

    Count
};

inline const char* ChannelName(Channel ch) {
    switch (ch) {
        case Channel::TouchFingerDown:       return "fingerDown";
        case Channel::TouchFingerMove:       return "fingerMove";
        case Channel::TouchFingerUp:         return "fingerUp";
        case Channel::TouchMirrorDown:       return "mirrorDown";
        case Channel::TouchMirrorMove:       return "mirrorMove";
        case Channel::TouchMirrorUp:         return "mirrorUp";
        case Channel::TouchToolMouseDropped: return "toolMouseDropped";
        case Channel::LookApplied:           return "look";
        case Channel::LookFromSchemaTouch:   return "lookSchema";
        case Channel::LookFromArktsMotion:   return "lookArkts";
        case Channel::LookFromGamepad:       return "lookPad";
        case Channel::NativeAxisCallback:    return "nativeAxisCb";
        case Channel::NativeAxisScroll:      return "nativeAxisScroll";
        case Channel::ArktsAxisCallback:     return "arktsAxisCb";
        case Channel::ArktsAxisYielded:      return "arktsAxisYield";
        case Channel::ArktsAxisScroll:       return "arktsAxisScroll";
        case Channel::TouchWheelScroll:      return "touchWheelScroll";
        case Channel::SchemaTouchScroll:     return "schemaScroll";
        case Channel::ScrollDelivered:       return "scrollOut";
        case Channel::TouchPointerDerivedDown:     return "ptrDerivedDown";
        case Channel::TouchPointerDerivedPromoted: return "ptrDerivedPromoted";
        case Channel::ButtonFromArkui:       return "btnArkui";
        case Channel::ButtonFromNativeMouse: return "btnNative";
        case Channel::ButtonFromTouchMirror: return "btnMirror";
        case Channel::ButtonRejectedByClaim: return "btnRejected";
        case Channel::WindowFilterTouchSeen:    return "wfTouch";
        case Channel::WindowFilterMouseDerived: return "wfMouseDerived";
        case Channel::WindowFilterDropped:      return "wfDropped";
        case Channel::WindowFilterMouseSeen:    return "wfMouse";
        case Channel::KeyDown:                  return "keyDown";
        case Channel::KeyRepeat:                return "keyRepeat";
        case Channel::KeyUp:                    return "keyUp";
        case Channel::KeyRepeatSelfHealed:      return "keyHealed";
        case Channel::KeyOwnerlessEdge:         return "keyOwnerless";
        case Channel::LeftEdgeYielded:          return "btnYield";
        case Channel::LeftEdgeYieldedNotOwner:  return "btnYieldNotOwner";
        case Channel::LeftEdgeYieldedDupDown:   return "btnYieldDupDown";
        case Channel::LeftEdgeYieldedNoPress:   return "btnYieldNoPress";
        case Channel::LeftEdgeYieldedOtherOwner:return "btnYieldOtherOwner";
        case Channel::WheelYielded:             return "wheelYield";
        case Channel::NativeMouseMove:              return "nativeMouseMove";
        case Channel::NativeMouseMoveWhileLeftHeld: return "nativeMouseMoveHeld";
        case Channel::Count:                 break;
    }
    return "?";
}

// 计数器与"上次汇总时的快照"。inline 变量（C++17）保证跨 TU 单实例。
inline std::atomic<uint32_t> g_counters[static_cast<int>(Channel::Count)];
inline uint32_t g_reported[static_cast<int>(Channel::Count)];
inline std::atomic<int64_t> g_nextFlushMs{0};
// 汇总打印只允许一个线程进入；输入回调分布在 ArkUI 线程、MC 线程与 worker 上。
inline std::atomic<bool> g_flushBusy{false};

inline int64_t CoarseMonotonicMs() {
    struct timespec ts = {};
    // COARSE 时钟不进入内核、精度约 1~4ms，对 1s 节流足够，且比 CLOCK_MONOTONIC 更便宜。
    if (clock_gettime(CLOCK_MONOTONIC_COARSE, &ts) != 0) {
        if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    }
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

inline void Flush(int64_t nowMs) {
    bool expected = false;
    if (!g_flushBusy.compare_exchange_strong(expected, true,
                                             std::memory_order_acq_rel)) {
        return;
    }
    char line[1024];
    int used = 0;
    bool any = false;
    for (int i = 0; i < static_cast<int>(Channel::Count); ++i) {
        const uint32_t total = g_counters[i].load(std::memory_order_relaxed);
        const uint32_t delta = total - g_reported[i];  // 无符号回绕天然正确
        if (delta == 0u) continue;
        g_reported[i] = total;
        any = true;
        const int written = snprintf(line + used, sizeof(line) - used,
                                     " %s=%u", ChannelName(static_cast<Channel>(i)),
                                     delta);
        if (written <= 0 || static_cast<size_t>(used + written) >= sizeof(line)) {
            used = static_cast<int>(sizeof(line)) - 1;
            break;
        }
        used += written;
    }
    if (any) {
        line[used] = '\0';
        // domain 必须落在 0x0–0xFFFF（hilog/log.h 的契约）。上一版传 0xA0000 越界，
        // 结果整批汇总行一条都没进 hilog —— 取证工具自己先失效了，比没有工具更糟。
        // 这里与 app 其余日志一致用 domain 0x0，只靠 tag 区分。
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0, "AMCL_CENSUS",
                     "AMCL_CENSUS 1s%{public}s", line);
    }
    g_nextFlushMs.store(nowMs + 1000, std::memory_order_relaxed);
    g_flushBusy.store(false, std::memory_order_release);
}

inline void Bump(Channel ch, uint32_t n = 1u) {
    const int idx = static_cast<int>(ch);
    if (idx < 0 || idx >= static_cast<int>(Channel::Count)) return;
    g_counters[idx].fetch_add(n, std::memory_order_relaxed);
    const int64_t nowMs = CoarseMonotonicMs();
    const int64_t due = g_nextFlushMs.load(std::memory_order_relaxed);
    if (due == 0) {
        // 首次自增打一条"已武装"，这样"日志通道坏了"与"这些通道一次都没被调用"
        // 在下一轮日志里可以直接区分开，不必再猜。
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0, "AMCL_CENSUS",
                     "AMCL_CENSUS armed first=%{public}s", ChannelName(ch));
        g_nextFlushMs.store(nowMs + 1000, std::memory_order_relaxed);
        return;
    }
    if (nowMs >= due) Flush(nowMs);
}

}  // namespace census
}  // namespace input
}  // namespace amcl

#endif  // AMCL_PLATFORM_INPUT_CHANNEL_CENSUS_H

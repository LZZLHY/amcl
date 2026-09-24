// input_channel_policy.cpp — 单一所有者策略层实现。契约与理由见 .h。
#include "input_channel_policy.h"

#include "../utils/amcl_log.h"

#include <atomic>
// `size_t` 用在下方的模板参数上。本 TU 从 2026-08-20 起也进主机侧 `-pedantic -Werror`
// 构建（input_channel_policy_test），不能再依赖 <atomic> 间接引入它。
#include <cstddef>

#undef LOG_TAG
#define LOG_TAG "AMCL_INPOLICY"

namespace {

// 位图：某条通道是否被观测到送来过样本。通道编号 1..7，一个 uint32 足够。
// 两个 aspect 各一份，理由见 .h（native 可能报右键但从不报左键）。
std::atomic<uint32_t> g_leftSeen{0};
std::atomic<uint32_t> g_wheelSeen{0};

// in-flight 的左键按下持有者。0 = 当前没有按下。
std::atomic<uint8_t> g_leftPressOwner{
    static_cast<uint8_t>(AMCL_INPUT_CHANNEL_NONE)};

// 上一次打印过的所有者，用于"只在变化时打一行"。
std::atomic<uint8_t> g_loggedLeftOwner{255u};
std::atomic<uint8_t> g_loggedWheelOwner{255u};

constexpr uint32_t ChannelBit(AmclInputChannel ch) {
    return (ch == AMCL_INPUT_CHANNEL_NONE)
               ? 0u
               : (1u << static_cast<uint32_t>(ch));
}

// 静态优先级表。**顺序即优先级**，越靠前越优先。
// 这两张表是本模块的全部策略；改行为只应改这里，不应在调用点加特例。
constexpr AmclInputChannel kLeftPriority[] = {
    // ArkUI onMouse 优先：与 windowX/windowY、rawDelta 同源，菜单坐标语义正确。
    // API 26 实测它确实报左键，API 24 实测它从不报 —— 靠能力发现自动分流，
    // 不做版本判断（版本号与实际能力已经被证明不是一回事）。
    AMCL_INPUT_CHANNEL_ARKUI_MOUSE,
    AMCL_INPUT_CHANNEL_NATIVE_MOUSE,
    // 兜底合成触摸放最后：API 24 上它是唯一载体，所以必须保留；
    // 但只要有真正的鼠标通道可用，就绝不让它参与，否则菜单点击会被它吃掉。
    AMCL_INPUT_CHANNEL_TOUCH_MIRROR,
};

constexpr AmclInputChannel kWheelPriority[] = {
    AMCL_INPUT_CHANNEL_NATIVE_AXIS,
    AMCL_INPUT_CHANNEL_ARKTS_AXIS,
    AMCL_INPUT_CHANNEL_AXIS_PAN,
    AMCL_INPUT_CHANNEL_TOUCH_WHEEL,
};

const char* ChannelName(AmclInputChannel ch) {
    switch (ch) {
        case AMCL_INPUT_CHANNEL_NONE:         return "none";
        case AMCL_INPUT_CHANNEL_ARKUI_MOUSE:  return "arkuiMouse";
        case AMCL_INPUT_CHANNEL_NATIVE_MOUSE: return "nativeMouse";
        case AMCL_INPUT_CHANNEL_TOUCH_MIRROR: return "touchMirror";
        case AMCL_INPUT_CHANNEL_NATIVE_AXIS:  return "nativeAxis";
        case AMCL_INPUT_CHANNEL_ARKTS_AXIS:   return "arktsAxis";
        case AMCL_INPUT_CHANNEL_AXIS_PAN:     return "axisPan";
        case AMCL_INPUT_CHANNEL_TOUCH_WHEEL:  return "touchWheel";
    }
    return "?";
}

template <size_t N>
AmclInputChannel PickOwner(const AmclInputChannel (&priority)[N],
                           uint32_t seen) {
    for (size_t i = 0; i < N; ++i) {
        if (seen & ChannelBit(priority[i])) return priority[i];
    }
    return AMCL_INPUT_CHANNEL_NONE;
}

AmclInputChannel LeftOwnerLocked() {
    return PickOwner(kLeftPriority, g_leftSeen.load(std::memory_order_acquire));
}

// 所有者变化时打一行。热路径上只做一次原子比较，稳态零日志。
void LogOwnerChange(bool left, AmclInputChannel owner) {
    std::atomic<uint8_t>& slot = left ? g_loggedLeftOwner : g_loggedWheelOwner;
    const uint8_t now = static_cast<uint8_t>(owner);
    uint8_t prev = slot.load(std::memory_order_relaxed);
    if (prev == now) return;
    if (!slot.compare_exchange_strong(prev, now, std::memory_order_acq_rel,
                                      std::memory_order_relaxed)) {
        return;
    }
    AMCL_LOG_I(LOG_TAG,
                "AMCL_INPOLICY %{public}s owner=%{public}s",
                left ? "left" : "wheel", ChannelName(owner));
}

}  // namespace

extern "C" void amcl_input_policy_note_left_channel(AmclInputChannel channel) {
    const uint32_t bit = ChannelBit(channel);
    if (bit == 0u) return;
    // fetch_or 幂等；只有首次会真正改变位图。
    const uint32_t before = g_leftSeen.fetch_or(bit, std::memory_order_acq_rel);
    if ((before & bit) == 0u) {
        // 新发现一条通道。可能抬高所有者，打一行便于真机判读。
        LogOwnerChange(true, PickOwner(kLeftPriority, before | bit));
    }
}

extern "C" void amcl_input_policy_note_wheel_channel(AmclInputChannel channel) {
    const uint32_t bit = ChannelBit(channel);
    if (bit == 0u) return;
    const uint32_t before = g_wheelSeen.fetch_or(bit, std::memory_order_acq_rel);
    if ((before & bit) == 0u) {
        LogOwnerChange(false, PickOwner(kWheelPriority, before | bit));
    }
}

extern "C" AmclInputChannel amcl_input_policy_wheel_owner(void) {
    return PickOwner(kWheelPriority, g_wheelSeen.load(std::memory_order_acquire));
}

extern "C" AmclInputChannel amcl_input_policy_left_owner(void) {
    // 与内部的 `LeftOwnerLocked()` 逐字相同 —— 刻意不让后者变成本函数的转调，
    // 而是让本函数复用它：内部调用点在热路径上，多一层 extern "C" 调用没有意义。
    return LeftOwnerLocked();
}

extern "C" bool amcl_input_policy_wheel_accepts(AmclInputChannel channel) {
    if (channel == AMCL_INPUT_CHANNEL_NONE) return false;
    return amcl_input_policy_wheel_owner() == channel;
}

extern "C" bool amcl_input_policy_left_begin(AmclInputChannel channel) {
    if (channel == AMCL_INPUT_CHANNEL_NONE) return false;

    const AmclInputChannel owner = LeftOwnerLocked();
    if (owner != channel) return false;

    // 已经有一次按下在飞行中：这是**同一条通道**的重复 DOWN（平台重发或合成流的
    // DOWN/MOVE/DOWN 序列），不能再发一个 PRESS，否则 MC 侧的按下计数会失衡。
    // 不同通道的重复 DOWN 上面那一行已经挡掉了。
    uint8_t expected = static_cast<uint8_t>(AMCL_INPUT_CHANNEL_NONE);
    if (!g_leftPressOwner.compare_exchange_strong(
            expected, static_cast<uint8_t>(channel),
            std::memory_order_acq_rel, std::memory_order_acquire)) {
        return false;
    }
    return true;
}

extern "C" bool amcl_input_policy_left_end(AmclInputChannel channel) {
    if (channel == AMCL_INPUT_CHANNEL_NONE) return false;
    // 只认按下时的持有者，**刻意不看当前优先级**：一对 press/release 必须由同一条
    // 通道送完。这正是旧的"500ms 空窗交接"做不到、从而导致左键卡在按下态的地方。
    uint8_t expected = static_cast<uint8_t>(channel);
    return g_leftPressOwner.compare_exchange_strong(
        expected, static_cast<uint8_t>(AMCL_INPUT_CHANNEL_NONE),
        std::memory_order_acq_rel, std::memory_order_acquire);
}

extern "C" bool amcl_input_policy_left_held(void) {
    return g_leftPressOwner.load(std::memory_order_acquire) !=
           static_cast<uint8_t>(AMCL_INPUT_CHANNEL_NONE);
}

extern "C" void amcl_input_policy_reset_pairing(void) {
    // 只清 in-flight 的配对，保留能力位图（理由见 .h）。
    g_leftPressOwner.store(static_cast<uint8_t>(AMCL_INPUT_CHANNEL_NONE),
                           std::memory_order_release);
}

extern "C" void amcl_input_policy_log_state(void) {
    AMCL_LOG_I(LOG_TAG,
                "AMCL_INPOLICY left=%{public}s wheel=%{public}s leftHeld=%{public}d",
                ChannelName(LeftOwnerLocked()),
                ChannelName(amcl_input_policy_wheel_owner()),
                amcl_input_policy_left_held() ? 1 : 0);
}

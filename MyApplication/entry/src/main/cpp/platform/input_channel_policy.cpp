// input_channel_policy.cpp — 单一所有者策略层实现。契约与理由见 .h。
#include "input_channel_policy.h"

#include "../utils/amcl_log.h"

#include <atomic>
// `size_t` 用在下方的模板参数上。本 TU 从 2026-08-20 起也进主机侧 `-pedantic -Werror`
// 构建（input_channel_policy_test），不能再依赖 <atomic> 间接引入它。
#include <cstddef>
#include <map>
#include <mutex>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "AMCL_INPOLICY"

namespace {

// 位图：某条通道是否被观测到送来过样本。通道编号 1..7，一个 uint32 足够。
// 两个 aspect 各一份，理由见 .h（native 可能报右键但从不报左键）。
std::atomic<uint32_t> g_leftSeen{0};
std::atomic<uint32_t> g_wheelSeen{0};

// 能力选择按按钮，持有记录按设备。不能把同通道的第二台设备当成重复 DOWN，
// 更不能让它的 UP 清掉第一台设备的配对。surface gate 负责跨下游事务串行；
// 本锁保护策略自身，测试/诊断访问不依赖平台锁。
std::mutex g_buttonMutex;
std::map<uint32_t, uint32_t> g_buttonSeen;
using ButtonIdentity = std::pair<uint32_t, uint64_t>;
std::map<ButtonIdentity, AmclInputChannel> g_buttonPressOwners;

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

// 平台按钮位掩码是 ABI，组合位和未知新位必须拒绝，不能误造左键。
bool ValidButton(uint32_t button) {
    return button == 1u || button == 2u || button == 4u ||
           button == 8u || button == 16u;
}

bool ValidButtonChannel(AmclInputChannel channel, uint32_t button) {
    return channel == AMCL_INPUT_CHANNEL_ARKUI_MOUSE ||
           channel == AMCL_INPUT_CHANNEL_NATIVE_MOUSE ||
           (button == 1u && channel == AMCL_INPUT_CHANNEL_TOUCH_MIRROR);
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
    // 兼容旧调用/host 契约：它们先显式 note，身份只能表达未知桶。新生产者应使用
    // button_begin；该入口不可再承担有 deviceId 的物理事件。
    if (LeftOwnerLocked() != channel) return false;
    return amcl_input_policy_button_begin(channel, 0u, 1u);
}

extern "C" bool amcl_input_policy_left_end(AmclInputChannel channel) {
    return amcl_input_policy_button_end(channel, 0u, 1u);
}

extern "C" bool amcl_input_policy_left_held(void) {
    std::lock_guard<std::mutex> lock(g_buttonMutex);
    for (const auto& held : g_buttonPressOwners) {
        if (held.first.first == 1u) return true;
    }
    return false;
}

extern "C" void amcl_input_policy_reset_pairing(void) {
    // 只清在途配对，保留每个按钮已经证明的通道能力。
    std::lock_guard<std::mutex> lock(g_buttonMutex);
    g_buttonPressOwners.clear();
}

extern "C" bool amcl_input_policy_button_begin(
        AmclInputChannel channel, uint64_t deviceId, uint32_t nativeButton) {
    if (!ValidButton(nativeButton) || !ValidButtonChannel(channel, nativeButton)) return false;
    if (nativeButton == 1u) amcl_input_policy_note_left_channel(channel);
    std::lock_guard<std::mutex> lock(g_buttonMutex);
    uint32_t& seen = g_buttonSeen[nativeButton];
    seen |= ChannelBit(channel);
    // 左键旧诊断入口仍可登记能力；其位图与新协议使用同一事实。
    if (nativeButton == 1u) seen |= g_leftSeen.load(std::memory_order_acquire);
    if (PickOwner(kLeftPriority, seen) != channel) return false;
    const ButtonIdentity identity{nativeButton, deviceId};
    if (g_buttonPressOwners.find(identity) != g_buttonPressOwners.end()) return false;
    for (const auto& held : g_buttonPressOwners) {
        if (held.first.first != nativeButton) continue;
        // native/mirror 没有共享设备标识，不能猜测它与 ArkUI 是不同的硬件，
        // 也不能在一次按住中迁移身份。已接受的通道完成 UP 后新优先级才生效。
        if (held.second != channel) return false;
    }
    g_buttonPressOwners.emplace(identity, channel);
    return true;
}

extern "C" bool amcl_input_policy_button_end(
        AmclInputChannel channel, uint64_t deviceId, uint32_t nativeButton) {
    std::lock_guard<std::mutex> lock(g_buttonMutex);
    const auto found = g_buttonPressOwners.find({nativeButton, deviceId});
    if (found == g_buttonPressOwners.end() || found->second != channel) return false;
    g_buttonPressOwners.erase(found);
    return true;
}

extern "C" void amcl_input_policy_button_abort(
        AmclInputChannel channel, uint64_t deviceId, uint32_t nativeButton) {
    // 下游拒绝 DOWN 时只撤销该生产者刚取得的预留，不影响其它设备或按钮。
    (void)amcl_input_policy_button_end(channel, deviceId, nativeButton);
}

extern "C" void amcl_input_policy_release_pointer_device(
        uint64_t deviceId, bool includeUnknown,
        AmclPhysicalButtonReleaseFn release, void* context) {
    std::vector<ButtonIdentity> retired;
    {
        std::lock_guard<std::mutex> lock(g_buttonMutex);
        for (auto it = g_buttonPressOwners.begin(); it != g_buttonPressOwners.end();) {
            if (it->first.second == deviceId || (includeUnknown && it->first.second == 0u)) {
                retired.push_back(it->first);
                it = g_buttonPressOwners.erase(it);
            } else {
                ++it;
            }
        }
    }
    // 摘表先于回调，且不持策略锁进入 ingress/ledger，避免下游同步重入形成锁反转。
    if (release) for (const auto& identity : retired) release(identity.second, identity.first, context);
}

extern "C" void amcl_input_policy_log_state(void) {
    AMCL_LOG_I(LOG_TAG,
                "AMCL_INPOLICY left=%{public}s wheel=%{public}s leftHeld=%{public}d",
                ChannelName(LeftOwnerLocked()),
                ChannelName(amcl_input_policy_wheel_owner()),
                amcl_input_policy_left_held() ? 1 : 0);
}

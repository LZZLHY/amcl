// ohos_frame_rate_hint.h - HarmonyOS XComponent frame-rate policy.
#ifndef AMCL_OHOS_FRAME_RATE_HINT_H
#define AMCL_OHOS_FRAME_RATE_HINT_H

#include <cstdint>
#include <optional>

struct OH_NativeXComponent;

namespace amcl::ohos {

constexpr int32_t kMinimumUsefulFrameRate = 30;
constexpr int32_t kMaximumUsefulFrameRate = 240;
// NativeVSync API 20固定请求范围上限，XComponent旧调度上限另有契约。
constexpr int32_t kMaximumFixedRefreshRate = 144;
constexpr int32_t kFallbackDisplayFrameRate = 60;

struct FrameRatePolicy {
    int32_t min;
    int32_t max;
    int32_t expected;
};

struct FrameRateLifecycleState {
    uint32_t foregroundSources;
    bool focused;
    bool surfaceReady;
};

struct FrameRateSurfaceTransition {
    FrameRateLifecycleState next;
    bool applyInactiveBeforeDetach;
};

constexpr bool IsFrameRateLifecycleActive(
    const FrameRateLifecycleState &state) {
    return state.surfaceReady && state.focused &&
           state.foregroundSources != 0;
}

constexpr FrameRateLifecycleState WithFrameRateForegroundSource(
    FrameRateLifecycleState state, uint32_t sourceBit, bool foreground) {
    state.foregroundSources = foreground
                                  ? (state.foregroundSources | sourceBit)
                                  : (state.foregroundSources & ~sourceBit);
    return state;
}

constexpr FrameRateLifecycleState WithFrameRateFocus(
    FrameRateLifecycleState state, bool focused) {
    state.focused = focused;
    return state;
}

constexpr FrameRateSurfaceTransition TransitionFrameRateSurface(
    FrameRateLifecycleState state, bool ready) {
    const bool detachWhileReady = state.surfaceReady && !ready;
    state.surfaceReady = ready;
    return {state, detachWhileReady};
}

constexpr int32_t ClampFrameRate(int32_t value) {
    return value < kMinimumUsefulFrameRate
               ? kMinimumUsefulFrameRate
               : (value > kMaximumUsefulFrameRate ? kMaximumUsefulFrameRate
                                                  : value);
}

// A non-positive display rate means that DisplayManager could not provide one.
constexpr int32_t SanitizeDisplayFrameRate(int32_t displayRate) {
    return displayRate <= 0 ? kFallbackDisplayFrameRate
                            : ClampFrameRate(displayRate);
}

// 旧选项和环境变量以0表示未指定。正值是调度硬上限；最低值与上限冲突时降低最低值。
// 不活跃时保留30 Hz提示。纯函数供编译期和宿主回归测试复用。
constexpr FrameRatePolicy MakeFrameRatePolicy(int32_t displayRate,
                                              int32_t overrideMin = 0,
                                              int32_t overrideMax = 0,
                                              int32_t overrideExpected = 0,
                                              int32_t fpsCap = 0,
                                              bool active = true) {
    if (!active) {
        return {kMinimumUsefulFrameRate, kMinimumUsefulFrameRate,
                kMinimumUsefulFrameRate};
    }

    const int32_t display = SanitizeDisplayFrameRate(displayRate);
    int32_t min =
        overrideMin > 0 ? ClampFrameRate(overrideMin) : kMinimumUsefulFrameRate;
    int32_t max = overrideMax > 0 ? ClampFrameRate(overrideMax) : display;
    if (fpsCap > 0) {
        const int32_t cap = ClampFrameRate(fpsCap);
        if (max > cap) {
            max = cap;
        }
    }
    if (min > max) {
        min = max;
    }

    int32_t expected =
        overrideExpected > 0 ? ClampFrameRate(overrideExpected) : max;
    if (expected < min) {
        expected = min;
    } else if (expected > max) {
        expected = max;
    }
    return {min, max, expected};
}

constexpr bool FrameRatePolicyEqual(const FrameRatePolicy &lhs,
                                    const FrameRatePolicy &rhs) {
    return lhs.min == rhs.min && lhs.max == rhs.max &&
           lhs.expected == rhs.expected;
}

// The lifecycle controller owns the XComponent handle plus, while a rate is
// pinned, one dedicated VSync source. It never owns a render callback:
// Surface/focus/Ability events only update the scheduler hint, and Minecraft's
// existing loop stays the only producer of frames.
void RegisterFrameRateComponent(OH_NativeXComponent *component);
void SetFrameRateSurfaceReady(OH_NativeXComponent *component, bool ready,
                              const char *lifecycleStage);
void SetFrameRateFocused(OH_NativeXComponent *component, bool focused,
                         const char *lifecycleStage);

// sourceBit is a single caller-owned bit. EntryAbility and GameAbility use
// different bits so out-of-order lifecycle callbacks cannot overwrite each
// other. The component is foreground-active while at least one source is set.
bool SetFrameRateForegroundSource(uint32_t sourceBit, bool foreground,
                                  const char *lifecycleStage);

// 0清除运行期上限。正值只约束调度最大帧率，保持现有持久设置含义。
bool SetRuntimeFrameRateCap(int32_t fpsCap, const char *lifecycleStage);

// Re-applies the current state, for example after a size change. This remains a
// scheduler hint only and does not create a second render/VSync loop.
bool ApplyExpectedFrameRateHint(OH_NativeXComponent *component,
                                const char *lifecycleStage);

// Re-queries the default display refresh rate and re-applies the current
// component policy. The ArkTS display-change listener calls this on its normal
// event thread; no NativeDisplayManager callback thread touches XComponent.
// Returns false while no live surface is registered.
bool RefreshExpectedFrameRateHint(const char *lifecycleStage);

// 当前游戏窗口传入实测刷新率和已通过该屏支持档位核对的固定请求。
// 省略固定值保持现有调用兼容；0撤回投票。Surface解绑后丢弃此窗口请求。
// 活跃状态的同一成功策略可去重；启动和续约失败仍会由现有维护刷新重试。
bool RefreshExpectedFrameRateHintForDisplayRate(
    int32_t displayRate, const char *lifecycleStage,
    std::optional<int32_t> supportedFixedRate = std::nullopt);

} // namespace amcl::ohos

#endif // AMCL_OHOS_FRAME_RATE_HINT_H

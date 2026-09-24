// ohos_frame_rate_hint.h - HarmonyOS XComponent frame-rate policy.
#ifndef AMCL_OHOS_FRAME_RATE_HINT_H
#define AMCL_OHOS_FRAME_RATE_HINT_H

#include <cstdint>

struct OH_NativeXComponent;

namespace amcl::ohos {

constexpr int32_t kMinimumUsefulFrameRate = 30;
constexpr int32_t kMaximumUsefulFrameRate = 240;
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

// Overrides and fpsCap use zero to mean "not specified". The effective cap is
// always a hard ceiling: if min exceeds it, min is lowered instead of silently
// raising the cap. Inactive components use one conservative 30 Hz hint.
// This function deliberately has no OHOS dependencies so policy edge cases can
// be compile-time tested and reused by host-side tests.
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

// The lifecycle controller stores only the XComponent handle. It never owns a
// render callback or a VSync source. Surface/focus/Ability events merely update
// the scheduler hint used by Minecraft's existing loop.
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

// Zero clears the runtime cap. Positive values must be in the supported range.
// This is an explicit input for a cap known by the launcher/game; AMCL never
// guesses a cap from short-term measured FPS.
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

// Re-applies using a refresh rate resolved from the current Window display by
// ArkTS.  This avoids treating the default display as the game display after a
// desktop window moves across screens. Non-positive values retain the native
// default-display compatibility query.
bool RefreshExpectedFrameRateHintForDisplayRate(
    int32_t displayRate, const char *lifecycleStage);

} // namespace amcl::ohos

#endif // AMCL_OHOS_FRAME_RATE_HINT_H

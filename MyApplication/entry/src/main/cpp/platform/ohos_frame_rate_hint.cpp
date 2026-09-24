// ohos_frame_rate_hint.cpp - HarmonyOS display-aware XComponent frame-rate
// hint.

#include "ohos_frame_rate_hint.h"
#include "input_foreground_gate.h"
#include "graphics_observation_abi.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <window_manager/oh_display_manager.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <strings.h>

#undef LOG_TAG
#define LOG_TAG "AMCL_FRAME_RATE"

namespace amcl::ohos {
namespace {

static_assert(SanitizeDisplayFrameRate(0) == 60,
              "display query failure must have a stable fallback");
static_assert(SanitizeDisplayFrameRate(360) == 240,
              "display rates must stay inside the OHOS policy range");
static_assert(MakeFrameRatePolicy(120).min == 30 &&
                  MakeFrameRatePolicy(120).max == 120 &&
                  MakeFrameRatePolicy(120).expected == 120,
              "default policy must prefer the physical display refresh rate");
static_assert(MakeFrameRatePolicy(120, 144, 60, 90).min == 60 &&
                  MakeFrameRatePolicy(120, 144, 60, 90).expected == 60,
              "contradictory overrides must normalize to a valid range");
static_assert(MakeFrameRatePolicy(120, 0, 0, 0, 75).max == 75 &&
                  MakeFrameRatePolicy(120, 0, 0, 0, 75).expected == 75,
              "a known game cap must be the effective scheduler ceiling");
static_assert(MakeFrameRatePolicy(120, 0, 0, 0, 0, false).min == 30 &&
                  MakeFrameRatePolicy(120, 0, 0, 0, 0, false).max == 30,
              "inactive components must use the conservative policy");

enum class OverrideState {
    Unset,
    Valid,
    Invalid,
};

struct FrameRateOverride {
    OverrideState state = OverrideState::Unset;
    int32_t value = 0;
};

struct FrameRateController {
    OH_NativeXComponent *component = nullptr;
    FrameRateLifecycleState lifecycle = {0, true, false};
    int32_t runtimeCap = 0;
    bool haveAppliedPolicy = false;
    FrameRatePolicy appliedPolicy = {0, 0, 0};
};

std::mutex g_frameRateMutex;
FrameRateController g_frameRateController;

FrameRateOverride ReadFrameRateOverride(const char *name) {
    const char *raw = std::getenv(name);
    if (raw == nullptr || raw[0] == '\0') {
        return {};
    }

    errno = 0;
    char *end = nullptr;
    const long parsed = std::strtol(raw, &end, 10);
    if (errno != 0 || end == raw || end == nullptr || end[0] != '\0' ||
        parsed < kMinimumUsefulFrameRate || parsed > kMaximumUsefulFrameRate) {
        OH_LOG_WARN(LOG_APP,
                    "%{public}s=%{public}s ignored; expected an integer in "
                    "[%{public}d, %{public}d]",
                    name, raw, kMinimumUsefulFrameRate,
                    kMaximumUsefulFrameRate);
        return {OverrideState::Invalid, 0};
    }
    return {OverrideState::Valid, static_cast<int32_t>(parsed)};
}

bool FrameRateHintDisabled() {
    const char *value = std::getenv("AMCL_OHOS_FRAME_RATE_HINT");
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    return std::strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0 ||
           strcasecmp(value, "false") == 0 || strcasecmp(value, "no") == 0 ||
           strcasecmp(value, "disabled") == 0;
}

int32_t QueryDisplayFrameRate() {
    uint32_t refreshRate = 0;
    const NativeDisplayManager_ErrorCode result =
        OH_NativeDisplayManager_GetDefaultDisplayRefreshRate(&refreshRate);
    if (result != DISPLAY_MANAGER_OK || refreshRate == 0) {
        OH_LOG_WARN(
            LOG_APP,
            "DisplayManager refresh-rate query failed (result=%{public}d, "
            "rate=%{public}u); "
            "using %{public}d Hz fallback",
            static_cast<int>(result), refreshRate, kFallbackDisplayFrameRate);
        return kFallbackDisplayFrameRate;
    }

    const int32_t sanitized =
        refreshRate > static_cast<uint32_t>(kMaximumUsefulFrameRate)
            ? kMaximumUsefulFrameRate
            : SanitizeDisplayFrameRate(static_cast<int32_t>(refreshRate));
    if (static_cast<uint32_t>(sanitized) != refreshRate) {
        OH_LOG_WARN(
            LOG_APP,
            "Display refresh rate %{public}u Hz normalized to %{public}d Hz",
            refreshRate, sanitized);
    }
    return sanitized;
}

int32_t ValueOrUnset(const FrameRateOverride &value) {
    return value.state == OverrideState::Valid ? value.value : 0;
}

const char *SafeStage(const char *lifecycleStage) {
    return lifecycleStage != nullptr ? lifecycleStage : "unknown";
}

bool IsSingleSourceBit(uint32_t sourceBit) {
    return sourceBit != 0 && (sourceBit & (sourceBit - 1U)) == 0;
}

bool ApplyControllerLocked(const char *lifecycleStage, bool force,
                           bool forceInactive = false,
                           int32_t displayRateOverride = 0) {
    FrameRateController &state = g_frameRateController;
    if (state.component == nullptr || !state.lifecycle.surfaceReady) {
        // 这条早退此前**完全不可观测**，于是"提示为什么一直停在 30"少了一环证据：
        // 分不出"没调到本函数"与"调到了但因为 surface 还没就绪而没下发"。见计划 §79.3。
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-hint-deferred stage=%{public}s "
                    "component=%{public}d surfaceReady=%{public}d "
                    "foregroundMask=%{public}u focused=%{public}d",
                    SafeStage(lifecycleStage),
                    state.component != nullptr ? 1 : 0,
                    state.lifecycle.surfaceReady ? 1 : 0,
                    state.lifecycle.foregroundSources,
                    state.lifecycle.focused ? 1 : 0);
        return false;
    }
    if (FrameRateHintDisabled()) {
        state.haveAppliedPolicy = false;
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-hint-disabled stage=%{public}s "
                    "foregroundMask=%{public}u focused=%{public}d",
                    SafeStage(lifecycleStage),
                    state.lifecycle.foregroundSources,
                    state.lifecycle.focused ? 1 : 0);
        return false;
    }

    const int32_t displayRate = displayRateOverride > 0
        ? SanitizeDisplayFrameRate(displayRateOverride)
        : QueryDisplayFrameRate();
    const FrameRateOverride overrideMin =
        ReadFrameRateOverride("AMCL_OHOS_FRAME_RATE_MIN");
    const FrameRateOverride overrideMax =
        ReadFrameRateOverride("AMCL_OHOS_FRAME_RATE_MAX");
    const FrameRateOverride overrideExpected =
        ReadFrameRateOverride("AMCL_OHOS_FRAME_RATE_EXPECTED");
    const FrameRateOverride environmentCap =
        ReadFrameRateOverride("AMCL_OHOS_FRAME_RATE_CAP");
    const int32_t effectiveCap =
        state.runtimeCap > 0 ? state.runtimeCap : ValueOrUnset(environmentCap);
    const bool active =
        !forceInactive && IsFrameRateLifecycleActive(state.lifecycle);
    const FrameRatePolicy policy = MakeFrameRatePolicy(
        displayRate, ValueOrUnset(overrideMin), ValueOrUnset(overrideMax),
        ValueOrUnset(overrideExpected), effectiveCap, active);

    if (!force && state.haveAppliedPolicy &&
        FrameRatePolicyEqual(state.appliedPolicy, policy)) {
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-hint-unchanged stage=%{public}s "
                    "active=%{public}d cap=%{public}d expected=%{public}d",
                    SafeStage(lifecycleStage), active ? 1 : 0, effectiveCap,
                    policy.expected);
        return true;
    }

    OH_NativeXComponent_ExpectedRateRange range = {
        .min = policy.min,
        .max = policy.max,
        .expected = policy.expected,
    };
    const int32_t result =
        OH_NativeXComponent_SetExpectedFrameRateRange(state.component, &range);
    if (result != 0) {
        // A later lifecycle event retries because failed policies are never
        // recorded as applied.
        state.haveAppliedPolicy = false;
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-hint-failed stage=%{public}s "
                    "result=%{public}d display=%{public}d active=%{public}d "
                    "foregroundMask=%{public}u focused=%{public}d "
                    "cap=%{public}d range=%{public}d..%{public}d "
                    "expected=%{public}d",
                    SafeStage(lifecycleStage), result, displayRate,
                    active ? 1 : 0, state.lifecycle.foregroundSources,
                    state.lifecycle.focused ? 1 : 0, effectiveCap, policy.min,
                    policy.max, policy.expected);
        return false;
    }

    state.appliedPolicy = policy;
    state.haveAppliedPolicy = true;
    OH_LOG_INFO(LOG_APP,
                "event=frame-rate-hint-applied stage=%{public}s "
                "display=%{public}d active=%{public}d "
                "foregroundMask=%{public}u focused=%{public}d "
                "cap=%{public}d capSource=%{public}s "
                "range=%{public}d..%{public}d expected=%{public}d",
                SafeStage(lifecycleStage), displayRate, active ? 1 : 0,
                state.lifecycle.foregroundSources,
                state.lifecycle.focused ? 1 : 0, effectiveCap,
                state.runtimeCap > 0
                    ? "runtime"
                    : (environmentCap.state == OverrideState::Valid ? "env"
                                                                     : "display"),
                policy.min, policy.max, policy.expected);
    return true;
}

} // namespace

void RegisterFrameRateComponent(OH_NativeXComponent *component) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    if (g_frameRateController.component != component) {
        if (g_frameRateController.component != nullptr &&
            g_frameRateController.lifecycle.surfaceReady) {
            (void)ApplyControllerLocked("component-replaced", true, true);
        }
        g_frameRateController.component = component;
        // Ability foreground may have arrived before XComponent registration;
        // preserve those source bits while resetting component-owned state.
        g_frameRateController.lifecycle = {
            g_frameRateController.lifecycle.foregroundSources, true, false};
        g_frameRateController.haveAppliedPolicy = false;
    }
}

void SetFrameRateSurfaceReady(OH_NativeXComponent *component, bool ready,
                              const char *lifecycleStage) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    if (component == nullptr) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-surface-ignored stage=%{public}s "
                    "reason=null-component",
                    SafeStage(lifecycleStage));
        return;
    }
    if (g_frameRateController.component != component) {
        if (!ready) {
            OH_LOG_WARN(LOG_APP,
                        "event=frame-rate-surface-ignored stage=%{public}s "
                        "reason=stale-component",
                        SafeStage(lifecycleStage));
            return;
        }
        if (g_frameRateController.component != nullptr &&
            g_frameRateController.lifecycle.surfaceReady) {
            (void)ApplyControllerLocked("surface-replaced", true, true);
        }
        g_frameRateController.component = component;
        g_frameRateController.lifecycle.focused = true;
        g_frameRateController.lifecycle.surfaceReady = false;
        g_frameRateController.haveAppliedPolicy = false;
    }
    const FrameRateSurfaceTransition transition = TransitionFrameRateSurface(
        g_frameRateController.lifecycle, ready);
    if (transition.applyInactiveBeforeDetach) {
        // The XComponent and its surface are still valid in this callback.
        // Replace any prior high-rate request before making the controller
        // unable to address the component. Failure is logged and remains
        // non-fatal; teardown must never wait for a scheduler hint.
        (void)ApplyControllerLocked(lifecycleStage, true, true);
    }
    g_frameRateController.lifecycle = transition.next;
    g_frameRateController.haveAppliedPolicy = false;
    if (ready) {
        (void)ApplyControllerLocked(lifecycleStage, true);
    }
}

void SetFrameRateFocused(OH_NativeXComponent *component, bool focused,
                         const char *lifecycleStage) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    if (component == nullptr || component != g_frameRateController.component) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-focus-ignored stage=%{public}s "
                    "reason=%{public}s",
                    SafeStage(lifecycleStage),
                    component == nullptr ? "null-component" : "stale-component");
        return;
    }
    g_frameRateController.lifecycle = WithFrameRateFocus(
        g_frameRateController.lifecycle, focused);
    (void)ApplyControllerLocked(lifecycleStage, false);
}

bool SetFrameRateForegroundSource(uint32_t sourceBit, bool foreground,
                                  const char *lifecycleStage) {
    if (!IsSingleSourceBit(sourceBit)) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-foreground-ignored stage=%{public}s "
                    "invalidSource=%{public}u",
                    SafeStage(lifecycleStage), sourceBit);
        return false;
    }

    uint32_t foregroundMask = 0u;
    {
        std::lock_guard<std::mutex> lock(g_frameRateMutex);
        g_frameRateController.lifecycle = WithFrameRateForegroundSource(
            g_frameRateController.lifecycle, sourceBit, foreground);
        foregroundMask = g_frameRateController.lifecycle.foregroundSources;
        // 唯一还没被观测的一环：本函数有没有被调到、调完 mask 是几。真机上 surface-created
        // 一直报 foregroundMask=0，排除过程见计划 §79.3。频率 = 生命周期边沿。
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-foreground stage=%{public}s bit=%{public}u "
                    "foreground=%{public}d maskNow=%{public}u surfaceReady=%{public}d "
                    "component=%{public}d",
                    SafeStage(lifecycleStage), sourceBit, foreground ? 1 : 0,
                    foregroundMask,
                    g_frameRateController.lifecycle.surfaceReady ? 1 : 0,
                    g_frameRateController.component != nullptr ? 1 : 0);
        (void)ApplyControllerLocked(lifecycleStage, false);

        // Keep this call under the frame lock so an older mask cannot publish
        // after a newer update. XComponent never holds the publisher mutex while
        // entering SetFrameRate*, so this order has no reverse nested edge.
        PublishInputForegroundGateForAbility(foregroundMask, lifecycleStage);
        amclGraphicsForegroundV1(foregroundMask != 0u ? 1 : 0);
    }
    return true;
}

bool SetRuntimeFrameRateCap(int32_t fpsCap, const char *lifecycleStage) {
    if (fpsCap != 0 &&
        (fpsCap < kMinimumUsefulFrameRate || fpsCap > kMaximumUsefulFrameRate)) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-cap-ignored stage=%{public}s "
                    "cap=%{public}d expected=0-or-%{public}d..%{public}d",
                    SafeStage(lifecycleStage), fpsCap,
                    kMinimumUsefulFrameRate, kMaximumUsefulFrameRate);
        return false;
    }

    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    g_frameRateController.runtimeCap = fpsCap;
    (void)ApplyControllerLocked(lifecycleStage, false);
    return true;
}

bool ApplyExpectedFrameRateHint(OH_NativeXComponent *component,
                                const char *lifecycleStage) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    if (component == nullptr || component != g_frameRateController.component) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-refresh-ignored stage=%{public}s "
                    "reason=%{public}s",
                    SafeStage(lifecycleStage),
                    component == nullptr ? "null-component" : "stale-component");
        return false;
    }
    return ApplyControllerLocked(lifecycleStage, true);
}

bool RefreshExpectedFrameRateHint(const char *lifecycleStage) {
    return RefreshExpectedFrameRateHintForDisplayRate(0, lifecycleStage);
}

bool RefreshExpectedFrameRateHintForDisplayRate(
    int32_t displayRate, const char *lifecycleStage) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    if (g_frameRateController.component == nullptr ||
        !g_frameRateController.lifecycle.surfaceReady) {
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-refresh-deferred stage=%{public}s "
                    "reason=no-live-surface",
                    SafeStage(lifecycleStage));
        return false;
    }
    return ApplyControllerLocked(lifecycleStage, true, false, displayRate);
}

} // namespace amcl::ohos

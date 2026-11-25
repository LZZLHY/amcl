// ohos_frame_rate_hint.cpp - HarmonyOS display-aware XComponent frame-rate
// hint plus a VSync-based panel-rate pinner.

#include "ohos_frame_rate_hint.h"
#include "input_foreground_gate.h"
#include "graphics_observation_abi.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <native_vsync/native_vsync.h>
#include <window_manager/oh_display_manager.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <memory>
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
static_assert(MakeFrameRatePolicy(120, 0, 0, 0, 75).min == 30 &&
                  MakeFrameRatePolicy(120, 0, 0, 0, 75).max == 75 &&
                  MakeFrameRatePolicy(120, 0, 0, 0, 75).expected == 75,
              "the legacy cap only restricts the scheduler ceiling");
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
    // 专用VSync只续约用户主动选择的面板投票，游戏帧仍由原有渲染循环生产。
    int32_t supportedFixedRate = 0;
    OH_NativeVSync *pinner = nullptr;
    int32_t pinnerRate = 0;
    uintptr_t pinnerGeneration = 0;
    uint64_t pinnerFrames = 0;
    bool pinnerRearmFailed = false;
};

std::mutex g_frameRateMutex;
FrameRateController g_frameRateController;

struct DestroyFrameRatePinner {
    void operator()(OH_NativeVSync *vsync) const {
        OH_NativeVSync_Destroy(vsync);
    }
};

using RetiredFrameRatePinner = std::unique_ptr<OH_NativeVSync, DestroyFrameRatePinner>;

// 一次控制器事务可各自移交一个旧投票和一个启动失败的投票。按成员逆序析构，
// 先释放锁再销毁VSync；SDK销毁可能等待一个同样需要该锁的回调。
struct FrameRateUpdate {
    RetiredFrameRatePinner previous;
    RetiredFrameRatePinner failedStart;
    std::lock_guard<std::mutex> lock{g_frameRateMutex};
};

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

// 零区间撤回固定档位请求，解除旧投票后再释放其Native句柄。
void ClearFrameRatePinnerVoteLocked(OH_NativeVSync *vsync) {
    OH_NativeVSync_ExpectedRateRange reset = {0, 0, 0};
    (void)OH_NativeVSync_SetExpectedFrameRateRange(vsync, &reset);
}

void OnFrameRatePinnerFrame(long long, void *token) {
    std::lock_guard<std::mutex> lock(g_frameRateMutex);
    FrameRateController &state = g_frameRateController;
    if (state.pinner == nullptr || state.pinnerRearmFailed ||
        reinterpret_cast<uintptr_t>(token) != state.pinnerGeneration) {
        return;
    }
    ++state.pinnerFrames;
    if (OH_NativeVSync_RequestFrame(state.pinner, OnFrameRatePinnerFrame, token) != 0) {
        // 回调内立即撤回投票，下一次控制器事务接管句柄回收和重试。
        ClearFrameRatePinnerVoteLocked(state.pinner);
        state.pinnerRearmFailed = true;
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-pinner-rearm-failed frames=%{public}llu",
                    static_cast<unsigned long long>(state.pinnerFrames));
    }
}

void StopFrameRatePinnerLocked(FrameRateUpdate &update, const char *reason) {
    FrameRateController &state = g_frameRateController;
    if (state.pinner == nullptr) {
        return;
    }
    if (!state.pinnerRearmFailed) {
        ClearFrameRatePinnerVoteLocked(state.pinner);
    }
    update.previous.reset(state.pinner);
    state.pinner = nullptr;
    state.pinnerRate = 0;
    OH_LOG_INFO(LOG_APP,
                "event=frame-rate-pinner-stopped reason=%{public}s frames=%{public}llu",
                SafeStage(reason), static_cast<unsigned long long>(state.pinnerFrames));
}

bool EnsureFrameRatePinnerLocked(FrameRateUpdate &update, int32_t pinnedRate) {
    FrameRateController &state = g_frameRateController;
    if (state.pinner != nullptr && state.pinnerRate == pinnedRate && !state.pinnerRearmFailed) {
        return true;
    }
    StopFrameRatePinnerLocked(update, "pinner-replaced");
    constexpr char name[] = "AMCLFrameRatePinner";
    OH_NativeVSync *created = OH_NativeVSync_Create(name, sizeof(name) - 1);
    if (created == nullptr) {
        OH_LOG_WARN(LOG_APP, "event=frame-rate-pinner-create-failed");
        return false;
    }
    // 创建成功即登记本次事务的所有权。任何启动步骤失败都在解锁后回收。
    update.failedStart.reset(created);
    OH_NativeVSync_ExpectedRateRange range = {pinnedRate, pinnedRate, pinnedRate};
    int32_t result = OH_NativeVSync_SetExpectedFrameRateRange(created, &range);
    if (result == 0) {
        ++state.pinnerGeneration;
        result = OH_NativeVSync_RequestFrame(created, OnFrameRatePinnerFrame,
            reinterpret_cast<void *>(state.pinnerGeneration));
        if (result != 0) {
            ClearFrameRatePinnerVoteLocked(created);
        }
    }
    if (result != 0) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-pinner-start-failed result=%{public}d rate=%{public}d",
                    result, pinnedRate);
        return false;
    }
    state.pinner = update.failedStart.release();
    state.pinnerRate = pinnedRate;
    state.pinnerFrames = 0;
    state.pinnerRearmFailed = false;
    OH_LOG_INFO(LOG_APP, "event=frame-rate-pinner-started rate=%{public}d", pinnedRate);
    return true;
}

bool ApplyControllerLocked(FrameRateUpdate &update, const char *lifecycleStage,
                           bool force, bool forceInactive = false,
                           int32_t displayRateOverride = 0) {
    FrameRateController &state = g_frameRateController;
    if (state.component == nullptr || !state.lifecycle.surfaceReady) {
        // surface 未就绪时无法下发；留痕才能区分"没调到"与"调到了但没下发"。
        StopFrameRatePinnerLocked(update, "no-live-surface");
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
        StopFrameRatePinnerLocked(update, "hint-disabled");
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
    FrameRatePolicy policy = MakeFrameRatePolicy(
        displayRate, ValueOrUnset(overrideMin), ValueOrUnset(overrideMax),
        ValueOrUnset(overrideExpected), effectiveCap, active);

    // 当前瞬时Hz可能因LTPO下降，屏幕真实支持档位由窗口侧核对。旧上限仍优先；
    // 固定请求启动失败时先下发原调度策略，稳定去重前仍尝试恢复投票。
    const int32_t fixedRate = state.supportedFixedRate;
    // MAX 是显式上限。未设置时允许面板从 LTPO 当前低档提升到已验证的固定档。
    const bool withinMaximum = overrideMax.state != OverrideState::Valid || fixedRate <= overrideMax.value;
    if (active && fixedRate > 0 && withinMaximum && (effectiveCap == 0 || fixedRate <= effectiveCap)) {
        if (EnsureFrameRatePinnerLocked(update, fixedRate)) {
            policy = {fixedRate, fixedRate, fixedRate};
        }
    } else {
        StopFrameRatePinnerLocked(update, "inactive-or-auto");
    }

    if (!force && state.haveAppliedPolicy &&
        FrameRatePolicyEqual(state.appliedPolicy, policy)) {
        // 相同且已成功应用的政策无需重复SDK调用或每次心跳写相同日志。
        // 此分支不接管生命周期：显式force仍经过实际SDK，失败不缓存成功事实，
        // 真实Hz/cap/focus/foreground变化仍由同一owner计算后应用并记原日志。
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
                "range=%{public}d..%{public}d expected=%{public}d "
                "pinner=%{public}d",
                SafeStage(lifecycleStage), displayRate, active ? 1 : 0,
                state.lifecycle.foregroundSources,
                state.lifecycle.focused ? 1 : 0, effectiveCap,
                state.runtimeCap > 0
                    ? "runtime"
                    : (environmentCap.state == OverrideState::Valid ? "env"
                                                                     : "display"),
                policy.min, policy.max, policy.expected,
                g_frameRateController.pinner != nullptr ? 1 : 0);
    return true;
}

} // namespace

void RegisterFrameRateComponent(OH_NativeXComponent *component) {
    FrameRateUpdate update;
    if (g_frameRateController.component != component) {
        if (g_frameRateController.component != nullptr &&
            g_frameRateController.lifecycle.surfaceReady) {
            (void)ApplyControllerLocked(update, "component-replaced", true, true);
        }
        g_frameRateController.component = component;
        g_frameRateController.supportedFixedRate = 0;
        // Ability foreground may have arrived before XComponent registration;
        // preserve those source bits while resetting component-owned state.
        g_frameRateController.lifecycle = {
            g_frameRateController.lifecycle.foregroundSources, true, false};
        g_frameRateController.haveAppliedPolicy = false;
    }
}

void SetFrameRateSurfaceReady(OH_NativeXComponent *component, bool ready,
                              const char *lifecycleStage) {
    FrameRateUpdate update;
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
            (void)ApplyControllerLocked(update, "surface-replaced", true, true);
        }
        g_frameRateController.component = component;
        g_frameRateController.supportedFixedRate = 0;
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
        (void)ApplyControllerLocked(update, lifecycleStage, true, true);
    }
    g_frameRateController.lifecycle = transition.next;
    if (!ready) {
        g_frameRateController.supportedFixedRate = 0;
    }
    g_frameRateController.haveAppliedPolicy = false;
    if (ready) {
        (void)ApplyControllerLocked(update, lifecycleStage, true);
    }
}

void SetFrameRateFocused(OH_NativeXComponent *component, bool focused,
                         const char *lifecycleStage) {
    FrameRateUpdate update;
    if (component == nullptr || component != g_frameRateController.component) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-focus-ignored stage=%{public}s "
                    "reason=%{public}s",
                    SafeStage(lifecycleStage),
                    component == nullptr ? "null-component"
                                         : "stale-component");
        return;
    }
    g_frameRateController.lifecycle = WithFrameRateFocus(
        g_frameRateController.lifecycle, focused);
    (void)ApplyControllerLocked(update, lifecycleStage, false);
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

    FrameRateUpdate update;
    g_frameRateController.lifecycle = WithFrameRateForegroundSource(
        g_frameRateController.lifecycle, sourceBit, foreground);
    const uint32_t foregroundMask = g_frameRateController.lifecycle.foregroundSources;
    // 生命周期边沿：记录本次置位后的 mask，便于核对 surface-created 报的 foregroundMask。
    OH_LOG_INFO(LOG_APP,
                "event=frame-rate-foreground stage=%{public}s bit=%{public}u "
                "foreground=%{public}d maskNow=%{public}u surfaceReady=%{public}d "
                "component=%{public}d",
                SafeStage(lifecycleStage), sourceBit, foreground ? 1 : 0,
                foregroundMask,
                g_frameRateController.lifecycle.surfaceReady ? 1 : 0,
                g_frameRateController.component != nullptr ? 1 : 0);
    (void)ApplyControllerLocked(update, lifecycleStage, false);

    // Keep this call under the frame lock so an older mask cannot publish
    // after a newer update. XComponent never holds the publisher mutex while
    // entering SetFrameRate*, so this order has no reverse nested edge.
    PublishInputForegroundGateForAbility(foregroundMask, lifecycleStage);
    amclGraphicsForegroundV1(foregroundMask != 0u ? 1 : 0);
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

    FrameRateUpdate update;
    g_frameRateController.runtimeCap = fpsCap;
    (void)ApplyControllerLocked(update, lifecycleStage, false);
    return true;
}

bool ApplyExpectedFrameRateHint(OH_NativeXComponent *component,
                                const char *lifecycleStage) {
    FrameRateUpdate update;
    if (component == nullptr || component != g_frameRateController.component) {
        OH_LOG_WARN(LOG_APP,
                    "event=frame-rate-refresh-ignored stage=%{public}s "
                    "reason=%{public}s",
                    SafeStage(lifecycleStage),
                    component == nullptr ? "null-component"
                                         : "stale-component");
        return false;
    }
    return ApplyControllerLocked(update, lifecycleStage, true);
}

bool RefreshExpectedFrameRateHint(const char *lifecycleStage) {
    return RefreshExpectedFrameRateHintForDisplayRate(0, lifecycleStage);
}

bool RefreshExpectedFrameRateHintForDisplayRate(
    int32_t displayRate, const char *lifecycleStage, std::optional<int32_t> supportedFixedRate) {
    if (supportedFixedRate && *supportedFixedRate != 0 &&
        (*supportedFixedRate < kMinimumUsefulFrameRate || *supportedFixedRate > kMaximumFixedRefreshRate)) {
        return false;
    }
    FrameRateUpdate update;
    if (g_frameRateController.component == nullptr ||
        !g_frameRateController.lifecycle.surfaceReady) {
        OH_LOG_INFO(LOG_APP,
                    "event=frame-rate-refresh-deferred stage=%{public}s "
                    "reason=no-live-surface",
                    SafeStage(lifecycleStage));
        return false;
    }
    if (supportedFixedRate) {
        g_frameRateController.supportedFixedRate = *supportedFixedRate;
    }
    // 普通显示元数据刷新可由250ms维护重复进入，既有成功政策就是去重事实。
    // 不绕过本次Native计算/失败重试，也不改真正component/surface边界的force调用。
    return ApplyControllerLocked(update, lifecycleStage, false, false, displayRate);
}

} // namespace amcl::ohos

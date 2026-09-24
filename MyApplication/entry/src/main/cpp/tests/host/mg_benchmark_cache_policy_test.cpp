#include "mg_benchmark_cache_policy.h"
#include "ohos_frame_rate_hint.h"

#include <iostream>

using amcl::mgbench::CacheDecision;
using amcl::mgbench::CacheProbeState;
using amcl::mgbench::GateDecision;

static_assert(amcl::mgbench::DecideGate(false, false, true) ==
                  GateDecision::Disabled,
              "benchmark must be disabled by default");
static_assert(amcl::mgbench::DecideGate(true, false, true) ==
                  GateDecision::Rejected,
              "a disposable context acknowledgement is mandatory");
static_assert(amcl::mgbench::DecideCache(CacheProbeState::Malformed, false) ==
                  CacheDecision::Run,
              "bad cache data must never be treated as a hit");
static_assert(
    amcl::mgbench::DecideCache(CacheProbeState::IdentityMismatch, false) ==
        CacheDecision::Run,
    "identity mismatch must invalidate and re-measure after explicit opt-in");
static_assert(
    amcl::mgbench::DecideCache(CacheProbeState::ValidIdentity, true) ==
        CacheDecision::Run,
    "force must re-run even with a valid cache entry");
static_assert(
    amcl::mgbench::DecideCache(CacheProbeState::ValidIdentity, false) ==
        CacheDecision::Hit,
    "a matching cache may satisfy an explicit non-force request");

constexpr amcl::ohos::FrameRateLifecycleState kActiveLifecycle = {
    1U, true, true};
constexpr amcl::ohos::FrameRateSurfaceTransition kDestroyedFirst =
    amcl::ohos::TransitionFrameRateSurface(kActiveLifecycle, false);
static_assert(kDestroyedFirst.applyInactiveBeforeDetach,
              "surface destroy must request inactive policy before detach");
static_assert(!amcl::ohos::IsFrameRateLifecycleActive(kDestroyedFirst.next),
              "destroyed surface cannot remain lifecycle-active");
constexpr amcl::ohos::FrameRateSurfaceTransition kRecreated =
    amcl::ohos::TransitionFrameRateSurface(kDestroyedFirst.next, true);
static_assert(!kRecreated.applyInactiveBeforeDetach &&
                  amcl::ohos::IsFrameRateLifecycleActive(kRecreated.next),
              "surface recreation must restore current foreground/focus state");

constexpr amcl::ohos::FrameRateLifecycleState kBlurThenBackground =
    amcl::ohos::WithFrameRateForegroundSource(
        amcl::ohos::WithFrameRateFocus(kActiveLifecycle, false), 1U, false);
constexpr amcl::ohos::FrameRateLifecycleState kBackgroundThenBlur =
    amcl::ohos::WithFrameRateFocus(
        amcl::ohos::WithFrameRateForegroundSource(kActiveLifecycle, 1U, false),
        false);
static_assert(kBlurThenBackground.foregroundSources ==
                      kBackgroundThenBlur.foregroundSources &&
                  kBlurThenBackground.focused == kBackgroundThenBlur.focused &&
                  !amcl::ohos::IsFrameRateLifecycleActive(kBlurThenBackground) &&
                  !amcl::ohos::IsFrameRateLifecycleActive(kBackgroundThenBlur),
              "focus/background callback order must converge to inactive");

constexpr amcl::ohos::FrameRateLifecycleState kForegroundWhileBlurred =
    amcl::ohos::WithFrameRateForegroundSource(
        amcl::ohos::WithFrameRateFocus(kDestroyedFirst.next, false), 1U, true);
static_assert(!amcl::ohos::IsFrameRateLifecycleActive(kForegroundWhileBlurred),
              "foreground before focus must stay inactive");
constexpr amcl::ohos::FrameRateLifecycleState kFocusAfterForeground =
    amcl::ohos::WithFrameRateFocus(
        amcl::ohos::TransitionFrameRateSurface(kForegroundWhileBlurred, true)
            .next,
        true);
static_assert(amcl::ohos::IsFrameRateLifecycleActive(kFocusAfterForeground),
              "focus after foreground and recreation must reactivate");

constexpr amcl::ohos::FrameRatePolicy kAuto120 =
    amcl::ohos::MakeFrameRatePolicy(120, 0, 0, 0, 0, true);
static_assert(kAuto120.min == 30 && kAuto120.max == 120 &&
                  kAuto120.expected == 120,
              "Auto must track the current display refresh rate");
constexpr amcl::ohos::FrameRatePolicy kCapped60 =
    amcl::ohos::MakeFrameRatePolicy(120, 0, 0, 0, 60, true);
static_assert(kCapped60.min == 30 && kCapped60.max == 60 &&
                  kCapped60.expected == 60,
              "an explicit cap must be a hard scheduler ceiling");
constexpr amcl::ohos::FrameRatePolicy kCapAboveDisplay =
    amcl::ohos::MakeFrameRatePolicy(90, 0, 0, 0, 120, true);
static_assert(kCapAboveDisplay.max == 90 && kCapAboveDisplay.expected == 90,
              "a cap must never request more than the current display rate");
constexpr amcl::ohos::FrameRatePolicy kInactiveCapped =
    amcl::ohos::MakeFrameRatePolicy(120, 0, 0, 0, 60, false);
static_assert(kInactiveCapped.min == 30 && kInactiveCapped.max == 30 &&
                  kInactiveCapped.expected == 30,
              "background/focus loss must override a foreground cap");

constexpr amcl::ohos::FrameRateLifecycleState kTwoForegroundSources =
    amcl::ohos::WithFrameRateForegroundSource(kActiveLifecycle, 2U, true);
constexpr amcl::ohos::FrameRateLifecycleState kOneForegroundSourceRemains =
    amcl::ohos::WithFrameRateForegroundSource(kTwoForegroundSources, 1U,
                                               false);
static_assert(kOneForegroundSourceRemains.foregroundSources == 2U &&
                  amcl::ohos::IsFrameRateLifecycleActive(
                      kOneForegroundSourceRemains),
              "out-of-order Ability background must preserve another owner");

int main() {
    amcl::mgbench::IdentityFields first;
    first.cacheSchema = 1;
    first.benchmarkReportVersion = 3;
    first.renderer = "fixture-renderer";
    first.driver = "fixture-driver";
    first.frontendVersion = "fixture-frontend";
    first.mobileGluesVersion = "2.0.0.0:type=10:suffix=";
    first.mobileGluesCommit =
        "1111111111111111111111111111111111111111";
    first.mobileGluesBuildIdentity =
        "schema=1:source=1111111111111111111111111111111111111111:"
        "worktree=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:"
        "state=dirty:options=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    first.hostBuildIdentity =
        "source=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:state=clean:compiler=fixture";
    first.hostAbi = "glfw-amcl-mg-benchmark-v3";

    amcl::mgbench::IdentityFields second = first;
    second.mobileGluesCommit =
        "2222222222222222222222222222222222222222";

    const std::string firstKey = amcl::mgbench::IdentityCacheKey(first);
    const std::string secondKey = amcl::mgbench::IdentityCacheKey(second);
    if (firstKey.size() != 16 || secondKey.size() != 16 ||
        firstKey == secondKey) {
        std::cerr << "identity key did not invalidate across MG commits\n";
        return 1;
    }

    second = first;
    second.mobileGluesBuildIdentity =
        "schema=1:source=1111111111111111111111111111111111111111:"
        "worktree=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:"
        "state=dirty:options=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    if (firstKey == amcl::mgbench::IdentityCacheKey(second)) {
        std::cerr << "identity key did not invalidate across dirty MG content\n";
        return 1;
    }

    second = first;
    second.hostBuildIdentity =
        "source=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:state=clean:compiler=fixture";
    if (firstKey == amcl::mgbench::IdentityCacheKey(second)) {
        std::cerr << "identity key did not invalidate across host builds\n";
        return 1;
    }

    second = first;
    second.hostAbi = "glfw-amcl-mg-benchmark-v4";
    if (firstKey == amcl::mgbench::IdentityCacheKey(second)) {
        std::cerr << "identity key did not invalidate across host ABI\n";
        return 1;
    }

    std::cout << "mg_benchmark_cache_policy_test: PASS\n";
    return 0;
}

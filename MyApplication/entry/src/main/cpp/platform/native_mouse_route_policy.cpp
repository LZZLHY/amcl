#include "native_mouse_route_policy.h"

#include <cmath>

namespace amcl::input {

NativeMouseDispatchRoute DecideNativeMouseDispatchRoute(
        bool verifiedNativeAbsolute, bool grabStateKnown, bool grabbed,
        NativeMouseSampleKind sampleKind) {
    const bool normalAbsoluteRoute = verifiedNativeAbsolute &&
        grabStateKnown && !grabbed;
    if (sampleKind == NativeMouseSampleKind::Move) {
        return normalAbsoluteRoute
            ? NativeMouseDispatchRoute::MenuAbsoluteMove
            : NativeMouseDispatchRoute::RelativeMoveOwner;
    }
    return normalAbsoluteRoute
        ? NativeMouseDispatchRoute::MenuAbsoluteButtonBatch
        : NativeMouseDispatchRoute::ButtonOnly;
}

// SuppressNormalMouseSynthTouch 已删除（理由见 .h）。

void ArktsPhysicalMotionState::Reset() {
    surfaceGeneration_ = 0;
    resetEpoch_ = 0;
    modeKnown_ = false;
    grabbed_ = false;
    windowBaselineValid_ = false;
    windowX_ = 0.0;
    windowY_ = 0.0;
}

ArktsPhysicalMotionDecision ArktsPhysicalMotionState::Consume(
        const ArktsPhysicalMotionSample& sample) {
    if (sample.surfaceGeneration == 0 || sample.resetEpoch == 0 ||
        !sample.grabStateKnown) {
        Reset();
        return {};
    }

    const bool provenanceChanged =
        !modeKnown_ || surfaceGeneration_ != sample.surfaceGeneration ||
        resetEpoch_ != sample.resetEpoch || grabbed_ != sample.grabbed;
    if (provenanceChanged) windowBaselineValid_ = false;
    surfaceGeneration_ = sample.surfaceGeneration;
    resetEpoch_ = sample.resetEpoch;
    modeKnown_ = true;
    grabbed_ = sample.grabbed;

    if (!sample.grabbed) {
        windowBaselineValid_ = false;
        return {
            sample.verifiedNativeAbsolute
                ? ArktsPhysicalMotionRoute::NativeMenuAbsoluteOwner
                : ArktsPhysicalMotionRoute::LegacyMenuAbsolute,
            sample.windowX,
            sample.windowY,
        };
    }

    const bool finiteWindow =
        std::isfinite(sample.windowX) && std::isfinite(sample.windowY);
    if (sample.rawDeltaPresent) {
        if (finiteWindow) {
            windowX_ = sample.windowX;
            windowY_ = sample.windowY;
            windowBaselineValid_ = true;
        } else {
            windowBaselineValid_ = false;
        }
        // Preserve malformed raw values for ingress's observable finite gate;
        // policy selects an owner but never silently sanitizes its payload.
        return {ArktsPhysicalMotionRoute::RawRelative,
                sample.rawDx, sample.rawDy};
    }

    if (!finiteWindow) {
        windowBaselineValid_ = false;
        // As above, forward the malformed pair to the unverified-fallback gate
        // so diagnostics distinguish invalid input from a missing baseline.
        return {ArktsPhysicalMotionRoute::UnverifiedRelativeFallback,
                sample.windowX, sample.windowY};
    }

    if (!windowBaselineValid_) {
        windowX_ = sample.windowX;
        windowY_ = sample.windowY;
        windowBaselineValid_ = true;
        return {};
    }

    const double dx = sample.windowX - windowX_;
    const double dy = sample.windowY - windowY_;
    windowX_ = sample.windowX;
    windowY_ = sample.windowY;
    return {ArktsPhysicalMotionRoute::UnverifiedRelativeFallback, dx, dy};
}

}  // namespace amcl::input

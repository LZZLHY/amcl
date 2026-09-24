#include "look_delta_math.h"

#include <cmath>

namespace amcl::input {
namespace {
constexpr double kReferenceFrameMs = 16.7;
constexpr double kAccelSpeedLo = 1200.0;
constexpr double kAccelSpeedHi = 6000.0;
constexpr double kAccelMaxExtra = 1.5;

bool FinitePair(double x, double y) {
    return std::isfinite(x) && std::isfinite(y);
}
}  // namespace

bool ComputeLookDeltaMath(const LookDeltaMathInput& input,
                          LookDeltaMathOutput* output) {
    if (!output || !FinitePair(input.dx, input.dy) ||
        !FinitePair(input.pendingDx, input.pendingDy) ||
        !std::isfinite(input.sensitivity) || input.sensitivity <= 0.0 ||
        !std::isfinite(input.smoothAlpha) || input.smoothAlpha <= 0.0 ||
        input.smoothAlpha > 1.0 || !std::isfinite(input.acceleration) ||
        input.acceleration < 0.0 || input.acceleration > 1.0 ||
        input.nowTimeNs < 0 || input.lastTimeNs < 0 ||
        (input.lastTimeNs != 0 && input.nowTimeNs < input.lastTimeNs)) {
        return false;
    }

    double dtMs = input.lastTimeNs == 0
        ? kReferenceFrameMs
        : static_cast<double>(input.nowTimeNs - input.lastTimeNs) / 1e6;
    if (dtMs < 1.0) dtMs = 1.0;
    if (dtMs > 100.0) dtMs = 100.0;
    if (!std::isfinite(dtMs)) return false;

    // Calculate speed even when acceleration is disabled. This supplies numeric
    // headroom: a finite DBL_MAX sample otherwise survives identity scaling and
    // can leave an enormous persistent remainder or overflow on the next sample.
    const double speed = std::hypot(input.dx, input.dy) / (dtMs / 1000.0);
    if (!std::isfinite(speed)) return false;

    double scaledDx = input.dx * input.sensitivity;
    double scaledDy = input.dy * input.sensitivity;
    if (input.acceleration > 0.0001) {
        double factor =
            (speed - kAccelSpeedLo) / (kAccelSpeedHi - kAccelSpeedLo);
        if (factor < 0.0) factor = 0.0;
        if (factor > 1.0) factor = 1.0;
        const double gain =
            1.0 + input.acceleration * kAccelMaxExtra * factor;
        scaledDx *= gain;
        scaledDy *= gain;
    }
    if (input.invertY) scaledDy = -scaledDy;
    if (!FinitePair(scaledDx, scaledDy)) return false;

    double alpha = 1.0;
    if (input.smoothAlpha < 0.999) {
        const double tau =
            -kReferenceFrameMs / std::log(1.0 - input.smoothAlpha);
        alpha = 1.0 - std::exp(-dtMs / tau);
        if (alpha < 0.0) alpha = 0.0;
        if (alpha > 1.0) alpha = 1.0;
    }

    const double pendingDx = input.pendingDx + scaledDx;
    const double pendingDy = input.pendingDy + scaledDy;
    const double emitDx = alpha * pendingDx;
    const double emitDy = alpha * pendingDy;
    const double remainingDx = pendingDx - emitDx;
    const double remainingDy = pendingDy - emitDy;
    if (!std::isfinite(alpha) || !FinitePair(pendingDx, pendingDy) ||
        !FinitePair(emitDx, emitDy) ||
        !FinitePair(remainingDx, remainingDy)) {
        return false;
    }

    LookDeltaMathOutput candidate{};
    candidate.emitDx = emitDx;
    candidate.emitDy = emitDy;
    candidate.pendingDx = remainingDx;
    candidate.pendingDy = remainingDy;
    candidate.lastTimeNs = input.nowTimeNs;
    *output = candidate;
    return true;
}

}  // namespace amcl::input

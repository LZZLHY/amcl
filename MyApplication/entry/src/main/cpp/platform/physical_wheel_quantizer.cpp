#include "physical_wheel_quantizer.h"

// 量纲位取自类型化事件契约本体，刻意不在这里镜像一份数字。
#include "../input/amcl_input_event.h"

#include <cmath>
#include <climits>

namespace amcl::input {

bool IsFinitePhysicalWheelSample(double value) {
    if (!std::isfinite(value)) return false;
    const float narrowed = static_cast<float>(value);
    return std::isfinite(narrowed);
}

PhysicalWheelQuantizeStatus QuantizePhysicalWheelSample(
        double currentRemainder, double value, double step,
        uint32_t maxDetents, PhysicalWheelQuantizeResult* output) {
    if (!output || !std::isfinite(currentRemainder) ||
        !IsFinitePhysicalWheelSample(value) || !std::isfinite(step) ||
        step <= 0.0 || maxDetents > static_cast<uint32_t>(INT32_MAX)) {
        return PhysicalWheelQuantizeStatus::InvalidNumeric;
    }

    const double accumulated = currentRemainder + value;
    if (!std::isfinite(accumulated)) {
        return PhysicalWheelQuantizeStatus::InvalidNumeric;
    }
    const double detentValue = std::trunc(accumulated / step);
    if (!std::isfinite(detentValue)) {
        return PhysicalWheelQuantizeStatus::InvalidNumeric;
    }
    if (std::fabs(detentValue) > static_cast<double>(maxDetents)) {
        return PhysicalWheelQuantizeStatus::ResourceLimit;
    }

    const int32_t detents = static_cast<int32_t>(detentValue);
    const double remainder = accumulated -
        static_cast<double>(detents) * step;
    if (!std::isfinite(remainder)) {
        return PhysicalWheelQuantizeStatus::InvalidNumeric;
    }

    PhysicalWheelQuantizeResult candidate{};
    candidate.remainder = remainder;
    candidate.detents = detents;
    *output = candidate;
    return PhysicalWheelQuantizeStatus::Accepted;
}

PhysicalWheelQuantizeStatus GlfwScrollFromWheelPx(
        double currentRemainder, double valuePx,
        const GlfwScrollPolicy& policy, GlfwScrollFromPxResult* output) {
    if (!output || policy.maxDetentsPerEvent == 0u) {
        return PhysicalWheelQuantizeStatus::InvalidNumeric;
    }
    PhysicalWheelQuantizeResult quantized{};
    const PhysicalWheelQuantizeStatus status = QuantizePhysicalWheelSample(
        currentRemainder, valuePx, policy.stepPx, policy.detentLimit,
        &quantized);
    if (status != PhysicalWheelQuantizeStatus::Accepted) return status;

    int32_t detents = quantized.detents;
    double remainder = quantized.remainder;
    if (detents != 0) {
        const int32_t cap =
            policy.maxDetentsPerEvent > static_cast<uint32_t>(INT32_MAX)
                ? INT32_MAX
                : static_cast<int32_t>(policy.maxDetentsPerEvent);
        int32_t capped = detents;
        if (capped > cap) capped = cap;
        if (capped < -cap) capped = -cap;
        if (policy.remainder == WheelRemainderPolicy::DropOnCrossing) {
            // 被截断的格连同零头一起丢，见头文件 WheelRemainderPolicy 的通道契约。
            remainder = 0.0;
        } else if (capped != detents) {
            // Carry 下被截断的格必须退回残量，否则位移凭空消失（计划 §86.4）。
            remainder += static_cast<double>(detents - capped) * policy.stepPx;
            if (!std::isfinite(remainder)) {
                return PhysicalWheelQuantizeStatus::InvalidNumeric;
            }
        }
        detents = capped;
    }

    GlfwScrollFromPxResult candidate{};
    candidate.remainder = remainder;
    candidate.glfwY = -detents;
    *output = candidate;
    return PhysicalWheelQuantizeStatus::Accepted;
}

void StepPhysicalWheel(double currentRemainder, double x, double y,
                       const GlfwScrollPolicy& policy,
                       PhysicalWheelStepOutcome* output) {
    if (!output) return;
    PhysicalWheelStepOutcome result{};
    // 拒绝一律把余量归零：可疑状态不得影响后续分格（计划 §91.2）。
    if (x != 0.0) {
        result.status = PhysicalWheelStepStatus::kRejectedAxis;
        *output = result;
        return;
    }
    if (!IsFinitePhysicalWheelSample(y) || !std::isfinite(currentRemainder)) {
        result.status = PhysicalWheelStepStatus::kRejectedValue;
        *output = result;
        return;
    }
    if (y == 0.0) {
        result.remainder = currentRemainder;
        result.status = PhysicalWheelStepStatus::kZeroSample;
        *output = result;
        return;
    }
    GlfwScrollFromPxResult scroll{};
    if (GlfwScrollFromWheelPx(currentRemainder, y, policy, &scroll) !=
        PhysicalWheelQuantizeStatus::Accepted) {
        result.status = PhysicalWheelStepStatus::kRejectedValue;
        *output = result;
        return;
    }
    result.remainder = scroll.remainder;
    result.glfwY = scroll.glfwY;
    result.status = scroll.glfwY == 0 ? PhysicalWheelStepStatus::kAccumulated
                                      : PhysicalWheelStepStatus::kEmit;
    *output = result;
}

double PlatformSampleFromGlfwScrollContinuous(double glfwYOffset,
                                              const GlfwScrollPolicy& policy) {
    // 取反是 GlfwScrollFromWheelPx 的逆：那里平台样本 > 0 = 向下滚 ⇒ glfwY 取负。
    return -glfwYOffset * policy.stepPx;
}

double PlatformSampleFromGlfwScroll(int32_t glfwYOffset,
                                    const GlfwScrollPolicy& policy) {
    return PlatformSampleFromGlfwScrollContinuous(
        static_cast<double>(glfwYOffset), policy);
}

bool WheelSamplePxFromUnit(double x, double y, uint32_t unit,
                           const GlfwScrollPolicy& policy,
                           double* outXPx, double* outYPx) {
    if (!outXPx || !outYPx) return false;
    if (!std::isfinite(policy.stepPx) || policy.stepPx <= 0.0) return false;
    if (unit == AMCL_INPUT_WHEEL_UNIT_PIXEL) {
        *outXPx = x;
        *outYPx = y;
        return true;
    }
    if (unit == AMCL_INPUT_WHEEL_UNIT_DEGREE) {
        // 常见 OHOS 鼠标一格 15 度 ⇒ 一度 = stepPx/15。
        const double pxPerDegree = policy.stepPx / 15.0;
        *outXPx = x * pxPerDegree;
        *outYPx = y * pxPerDegree;
        return true;
    }
    return false;
}

bool GlfwScrollDetentsFromWheelPx(double xPx, double yPx,
                                  const GlfwScrollPolicy& policy,
                                  double* outX, double* outY) {
    if (!outX || !outY) return false;
    if (!std::isfinite(policy.stepPx) || policy.stepPx <= 0.0) return false;
    if (!IsFinitePhysicalWheelSample(xPx) ||
        !IsFinitePhysicalWheelSample(yPx)) {
        return false;
    }
    // 取反与 PlatformSampleFromGlfwScroll / GlfwScrollFromWheelPx 逐字同源。
    const double x = -xPx / policy.stepPx;
    const double y = -yPx / policy.stepPx;
    if (!IsFinitePhysicalWheelSample(x) || !IsFinitePhysicalWheelSample(y)) {
        return false;
    }
    *outX = x;
    *outY = y;
    return true;
}

}  // namespace amcl::input

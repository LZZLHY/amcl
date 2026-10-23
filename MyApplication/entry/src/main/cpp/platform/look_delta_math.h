#ifndef AMCL_LOOK_DELTA_MATH_H
#define AMCL_LOOK_DELTA_MATH_H

#include <cstdint>

namespace amcl::input {

struct LookDeltaMathInput {
    double dx = 0.0;
    double dy = 0.0;
    double sensitivity = 1.0;
    double smoothAlpha = 1.0;
    double acceleration = 0.0;
    double pendingDx = 0.0;
    double pendingDy = 0.0;
    int64_t lastTimeNs = 0;
    int64_t nowTimeNs = 0;
    bool invertY = false;
};

struct LookDeltaMathOutput {
    double emitDx = 0.0;
    double emitDy = 0.0;
    double pendingDx = 0.0;
    double pendingDy = 0.0;
    int64_t lastTimeNs = 0;
    // 中立look owner分摊同family设备时沿用本次总量运算系数，禁止逐设备重算加速/alpha。
    // appliedGain包含灵敏度和加速，Y倒置仍由原输入声明；appliedAlpha只改变到达时间。
    double appliedGain = 1.0;
    double appliedAlpha = 1.0;
};

// Pure numeric transaction used by the shipping look processor. Output remains
// byte-for-byte untouched unless every input and intermediate is finite.
bool ComputeLookDeltaMath(const LookDeltaMathInput& input,
                          LookDeltaMathOutput* output);

}  // namespace amcl::input

#endif

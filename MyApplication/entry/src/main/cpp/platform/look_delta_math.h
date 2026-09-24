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
};

// Pure numeric transaction used by the shipping look processor. Output remains
// byte-for-byte untouched unless every input and intermediate is finite.
bool ComputeLookDeltaMath(const LookDeltaMathInput& input,
                          LookDeltaMathOutput* output);

}  // namespace amcl::input

#endif

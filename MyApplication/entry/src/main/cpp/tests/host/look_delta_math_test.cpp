#include "../../platform/look_delta_math.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

using namespace amcl::input;

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LOOK DELTA MATH FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

void CheckUnchanged(const LookDeltaMathOutput& actual,
                    const LookDeltaMathOutput& expected) {
    CHECK(actual.emitDx == expected.emitDx);
    CHECK(actual.emitDy == expected.emitDy);
    CHECK(actual.pendingDx == expected.pendingDx);
    CHECK(actual.pendingDy == expected.pendingDy);
    CHECK(actual.lastTimeNs == expected.lastTimeNs);
}
}  // namespace

int main() {
    LookDeltaMathInput input{};
    input.dx = 4.0;
    input.dy = -2.0;
    input.sensitivity = 1.5;
    input.smoothAlpha = 0.6;
    input.acceleration = 0.2;
    input.nowTimeNs = 1000000000LL;

    LookDeltaMathOutput output{};
    CHECK(ComputeLookDeltaMath(input, &output));
    CHECK(std::isfinite(output.emitDx));
    CHECK(std::isfinite(output.emitDy));
    CHECK(std::isfinite(output.pendingDx));
    CHECK(std::isfinite(output.pendingDy));
    CHECK(output.lastTimeNs == input.nowTimeNs);

    const double invalid[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
        std::numeric_limits<double>::max(),
    };
    for (double value : invalid) {
        LookDeltaMathInput rejected = input;
        rejected.dx = value;
        LookDeltaMathOutput sentinel{91.0, 92.0, 93.0, 94.0, 95};
        const LookDeltaMathOutput before = sentinel;
        CHECK(!ComputeLookDeltaMath(rejected, &sentinel));
        CheckUnchanged(sentinel, before);
    }

    LookDeltaMathInput overflow = input;
    // The sample itself and speed calculation remain finite, but adding it to
    // the existing backlog overflows. The transaction must leave output alone.
    overflow.dx = std::numeric_limits<double>::max() * 0.01;
    overflow.pendingDx = std::numeric_limits<double>::max() * 0.995;
    LookDeltaMathOutput sentinel{81.0, 82.0, 83.0, 84.0, 85};
    const LookDeltaMathOutput beforeOverflow = sentinel;
    CHECK(!ComputeLookDeltaMath(overflow, &sentinel));
    CheckUnchanged(sentinel, beforeOverflow);

    // Reusing the unchanged pre-rejection state with an ordinary next sample
    // succeeds, proving a rejected value cannot poison backlog or timestamp.
    LookDeltaMathInput recovered = input;
    recovered.dx = 1.0;
    recovered.dy = 2.0;
    CHECK(ComputeLookDeltaMath(recovered, &sentinel));
    CHECK(std::isfinite(sentinel.emitDx));
    CHECK(std::isfinite(sentinel.emitDy));
    CHECK(sentinel.lastTimeNs == recovered.nowTimeNs);

    // alpha=1.0（物理键鼠端恒取此值）：余量恒 0 ⇒ 无相位滞后、idle worker 的 20ms
    // 尾量永不发送、总位移守恒。三条的因果见计划 §78.2。
    {
        LookDeltaMathInput immediate{};
        immediate.dx = 4.0;
        immediate.dy = -2.0;
        immediate.sensitivity = 1.5;
        immediate.smoothAlpha = 1.0;
        immediate.acceleration = 0.0;   // 与产品默认一致（加速默认关闭）
        immediate.nowTimeNs = 2000000000LL;

        LookDeltaMathOutput out{};
        CHECK(ComputeLookDeltaMath(immediate, &out));
        CHECK(out.emitDx == 4.0 * 1.5);
        CHECK(out.emitDy == -2.0 * 1.5);
        CHECK(out.pendingDx == 0.0);
        CHECK(out.pendingDy == 0.0);

        // 非零余量会被 alpha=1.0 一起冲出去（input_source.h 记的"共享 backlog 交互"）。
        // 这里断言它安全：Σoutput == 余量 + 本次输入，不重复不丢失。
        LookDeltaMathInput withPending = immediate;
        withPending.pendingDx = 7.0;
        withPending.pendingDy = -3.0;
        LookDeltaMathOutput flushed{};
        CHECK(ComputeLookDeltaMath(withPending, &flushed));
        CHECK(flushed.emitDx == 7.0 + 4.0 * 1.5);
        CHECK(flushed.emitDy == -3.0 + -2.0 * 1.5);
        CHECK(flushed.pendingDx == 0.0);
        CHECK(flushed.pendingDy == 0.0);
    }

    // 对照组 alpha=0.6（触控端默认）：证明上面三条是 alpha=1.0 特有的。按端解析被改回
    // 共享一份 alpha 时，KBM 端就会退回这里的行为。
    {
        LookDeltaMathInput smoothed{};
        smoothed.dx = 10.0;
        smoothed.dy = 0.0;
        smoothed.sensitivity = 1.0;
        smoothed.smoothAlpha = 0.6;
        smoothed.acceleration = 0.0;
        smoothed.lastTimeNs = 3000000000LL;
        smoothed.nowTimeNs = smoothed.lastTimeNs + 16700000LL;

        LookDeltaMathOutput out{};
        CHECK(ComputeLookDeltaMath(smoothed, &out));
        // 有余量 ⇒ 有相位滞后；dt 恰为参考帧长时有效 alpha 精确回到滑条值 0.6。
        CHECK(out.pendingDx > 0.0);
        CHECK(out.emitDx < 10.0);
        CHECK(std::fabs(out.emitDx - 6.0) < 1e-6);
        CHECK(std::fabs(out.pendingDx - 4.0) < 1e-6);
        CHECK(std::fabs((out.emitDx + out.pendingDx) - 10.0) < 1e-9);
    }

    std::cout << "look_delta_math_test: PASS\n";
    return 0;
}

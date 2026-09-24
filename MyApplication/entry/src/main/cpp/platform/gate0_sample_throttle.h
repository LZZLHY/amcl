#ifndef AMCL_GATE0_SAMPLE_THROTTLE_H
#define AMCL_GATE0_SAMPLE_THROTTLE_H

#include <stdint.h>

namespace amcl::gate0 {

// Gate 0 遥测的采样限流策略。
//
// 为什么单独成一个 header-only 纯策略：这段判断决定了真机取证时**看得到哪些样本**。
// 如果它错了（比如把窗口写成 `<` 而不是 `<=`，或者尾部步长算成 sequence % stride == 1），
// 后果不是崩溃，而是证据里悄悄缺一部分数据 —— 而 Gate 0 的结论恰恰依赖这些数据的
// 完整性。把它从 gate0_input_telemetry.cpp 的匿名命名空间里提出来，才能在不牵入
// hilog / XComponent 的情况下用 host 测试逐个边界钉住。
//
// 策略本身：前 kFullRateSampleLimit 条全量输出（覆盖启动瞬间的密集样本，
// 这段是判断坐标原点/单位最有用的部分），之后每 kTailSampleStride 条留一条
// （长时间移动只需要抽样确认没有漂移，不需要淹没 hilog）。
//
// 契约：sequence 由调用方以 1 为起点单调递增（fetch_add 后 +1）。0 不是合法样本号，
// 但仍定义为 true —— 宁可多输出一条也不要在计数器意外从 0 开始时静默丢样本。
inline constexpr uint64_t kFullRateSampleLimit = 1024u;
inline constexpr uint64_t kTailSampleStride = 128u;

constexpr bool ShouldEmitSample(uint64_t sequence) {
    return sequence <= kFullRateSampleLimit ||
        (sequence % kTailSampleStride) == 0u;
}

}  // namespace amcl::gate0

#endif

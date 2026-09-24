// Gate 0 遥测采样限流策略的边界测试。
//
// 为什么值得单独测：这条策略决定真机取证时**看得到哪些样本**。它错了不会崩溃，只会让
// 证据里静默缺一段数据，而 Gate 0 的结论正建立在这些数据上。尾部步长相位错误
// （`% stride == 1`）、窗口整体缺失、阈值被改动都属于"看起来还在输出、其实丢了大部分"
// 的失败，本文件逐条钉住。
//
// 明确不覆盖：窗口比较的 `<=` / `<` 之差。理由见下方 static_assert 群的说明 ——
// 当前两个常量对齐，导致该差异没有行为差，不是漏测。

#include "gate0_sample_throttle.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

using amcl::gate0::kFullRateSampleLimit;
using amcl::gate0::kTailSampleStride;
using amcl::gate0::ShouldEmitSample;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GATE0 THROTTLE FAIL line " << line << ": " << expression
              << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// 策略必须是编译期可求值的：它出现在每条样本的热路径上，运行时不应有函数调用开销，
// 也不应因为链接顺序产生第二份实现。
static_assert(ShouldEmitSample(1u), "first sample must always emit");
static_assert(!ShouldEmitSample(kFullRateSampleLimit + 1u),
              "the sample right after the window must be throttled");
static_assert(kFullRateSampleLimit % kTailSampleStride == 0u,
              "window end must align to the stride so the tail phase is stable");

// 诚实说明本测试**不能**覆盖什么：因为 kFullRateSampleLimit 恰好是 kTailSampleStride
// 的整数倍（上面那条断言正是这个事实），序号 == limit 这一点同时满足窗口子句和尾部
// 子句。于是把窗口比较从 `<=` 改成 `<` 在当前常量下**不可观测**，本文件也就无法把这个
// off-by-one 钉死 —— 不是漏了断言，而是该差异在这组常量下没有行为差。
// 真正被钉住的是：窗口内每一条都出、窗口后只有 stride 倍数出、尾部相位从
// limit+stride 开始、以及两个阈值的具体取值。若将来改成不对齐的常量，上面那条
// static_assert 会先失败，提醒同时补上边界断言。
static_assert(ShouldEmitSample(kFullRateSampleLimit),
              "sequence == limit emits; note it is also a stride multiple, so "
              "this does not discriminate <= from <");
static_assert(ShouldEmitSample(kFullRateSampleLimit - 1u),
              "a non-stride-multiple inside the window must rely on the window "
              "clause alone");

}  // namespace

int main() {
    // 1. 全量窗口：1..limit 每条都出。这段是判断坐标原点/单位最有用的部分，
    //    少一条都会让"启动瞬间的密集样本"不完整。
    for (uint64_t sequence = 1u; sequence <= kFullRateSampleLimit; ++sequence) {
        CHECK(ShouldEmitSample(sequence));
    }

    // 2. 窗口边界：limit 出、limit+1 不出。
    //    注意 limit 同时是 stride 倍数，所以这两条证明的是"窗口结束后立刻收紧"，
    //    并不能区分 `<=` 与 `<`（见文件上方说明）。
    CHECK(ShouldEmitSample(kFullRateSampleLimit));
    CHECK(!ShouldEmitSample(kFullRateSampleLimit + 1u));

    // 3. 尾部相位：只有 stride 的整数倍才出，且恰好每 stride 条出一条。
    uint64_t emitted = 0u;
    const uint64_t tailBegin = kFullRateSampleLimit + 1u;
    const uint64_t tailEnd = kFullRateSampleLimit + kTailSampleStride * 10u;
    for (uint64_t sequence = tailBegin; sequence <= tailEnd; ++sequence) {
        const bool expected = (sequence % kTailSampleStride) == 0u;
        CHECK(ShouldEmitSample(sequence) == expected);
        if (expected) ++emitted;
    }
    CHECK(emitted == 10u);

    // 4. 尾部第一条被放行的样本号必须是窗口之后的第一个 stride 倍数，而不是
    //    tailBegin 本身。相位算错会让抽样点整体偏移。
    CHECK(!ShouldEmitSample(tailBegin));
    CHECK(ShouldEmitSample(kFullRateSampleLimit + kTailSampleStride));

    // 5. 0 不是合法样本号（调用方 fetch_add 后 +1，最小为 1），但仍必须放行：
    //    计数器若意外从 0 开始，宁可多一条也不要静默丢样本。
    CHECK(ShouldEmitSample(0u));

    // 6. 极大样本号不得因取模/溢出而失效。UINT64_MAX 是奇数，不是 stride 倍数。
    CHECK(!ShouldEmitSample(UINT64_MAX));
    const uint64_t alignedNearMax = UINT64_MAX - (UINT64_MAX % kTailSampleStride);
    CHECK(alignedNearMax % kTailSampleStride == 0u);
    CHECK(ShouldEmitSample(alignedNearMax));

    // 7. 阈值本身必须与 probe-ready 日志报告的值一致。probe 日志直接引用这两个常量，
    //    因此这里锁定它们的具体取值：改动限流就必须同时更新证据文档里的采样说明。
    CHECK(kFullRateSampleLimit == 1024u);
    CHECK(kTailSampleStride == 128u);

    std::cout << "gate0_sample_throttle_test: PASS\n";
    return 0;
}

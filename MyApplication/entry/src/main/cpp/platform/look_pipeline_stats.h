#ifndef AMCL_LOOK_PIPELINE_STATS_H
#define AMCL_LOOK_PIPELINE_STATS_H

#include <cstdint>

namespace amcl::input {

// 视角管线的观测面。规范 §九 把"look 管线零时延埋点"列为独立观测缺口：没有 backlog 深度、
// 没有 emit 计数、census 全在 `applyLookDelta` 的**入口侧** ⇒ 日志结构上测不出视角行为。
//
// ⚠️ 为什么它必须单独做：视角**结构上不进** channel aggregate 也不进 ledger（规范 §〇），
// 所以任何建立在那两者上的观测手段对它天然盲。
//
// ⭐ 它同时把 Σ守恒变成可判定的：`applyLookDelta` 的契约是"任意手势的总输出严格等于
// 灵敏度/加速后的总输入"，而在此之前那句话**没有任何断言钉住**（计划 §84.7-4）。
// 恒等式：`Σemit + backlog == Σscaled`（逐轴）。
struct LookPipelineSnapshot {
    // 进入漏斗并通过 finite/归一的样本数（被拒的不计入，另见 rejected）。
    uint64_t accepted = 0u;
    // 被 math 事务拒绝、或被本类自己的 finite 守卫拒绝的样本数。
    // ⚠️ **入口侧**的 finite 拒绝不在这里：那两处发生在取锁**之前**，由
    // `recordInvalidLookDelta` 单独计数。混在一起会违反本类的锁契约。
    uint64_t rejected = 0u;
    // 产出过非零边沿的次数（emit 恒零的样本仍计入 accepted）。
    uint64_t emitted = 0u;
    // 边界补齐（正常 UP / idle 尾量）与边界丢弃（grab flip / 失焦 / surface lost）。
    uint64_t flushEmit = 0u;
    uint64_t flushDiscard = 0u;
    // 归一化+灵敏度+加速之后进入 backlog 的累计量（逐轴带符号）。
    // ⚠️ **带符号是恒等式需要的，但它不是"动了多少"** —— 来回扫会互相抵消。
    // 拿它跨包对比手势会得到任意倍数的差异（2026-08-24 实测：两个包 3069 vs 115，
    // 而链路上一处缩放都没有，差的全是净位移方向）。要比行程请用下面的 travel。
    double scaledDx = 0.0;
    double scaledDy = 0.0;
    // ⭐ 逐轴**行程**累计（Σ|scaled|）。它与手势方向无关，是双包对比里唯一可比的量
    // （计划 §90.4）。刻意与带符号的 scaled 并存而不是替换：恒等式要带符号的那份。
    double travelDx = 0.0;
    double travelDy = 0.0;
    // 已经交给 bridge 的累计量（逐轴带符号）。
    double emitDx = 0.0;
    double emitDy = 0.0;
    // 当前 backlog（逐轴带符号）。恒等式需要它带符号，日志里再取模长。
    double backlogDx = 0.0;
    double backlogDy = 0.0;
    // 历史最大 backlog 模长。它是"平滑到底攒了多少"的唯一可见量。
    double maxBacklog = 0.0;
    // 被边界丢弃掉的累计量（逐轴带符号）。它是**唯一**能把"位移被丢弃"与"通道没来"
    // 区分开的量 —— 两者在今天的日志里长得完全一样。
    double discardedDx = 0.0;
    double discardedDy = 0.0;
};

// ⚠️ 线程契约：全部方法必须在调用方的 look 互斥量内调用（`applyLookDelta` /
// `flushLookPending` / idle worker 都持 `s_lookMutex`）。因此刻意不用 atomic ——
// 让它正确的是那把锁提供的 happens-before，不是"没有并发写者"。
class LookPipelineStats final {
public:
    void NoteRejected();
    // `scaled*` 是归一/灵敏度/加速之后、进入 backlog 之前的量；`emit*` 是本次交给 bridge
    // 的量；`pending*` 是本次之后剩下的 backlog。
    void NoteAccepted(double scaledDx, double scaledDy,
                      double emitDx, double emitDy,
                      double pendingDx, double pendingDy);
    // 边界收尾。`emit` 为真表示补齐（计入 emitted 总量），为假表示丢弃。
    void NoteFlush(bool emit, double pendingDx, double pendingDy);
    void Reset();

    const LookPipelineSnapshot& Snapshot() const { return s_; }

    // Σemit + backlog == Σscaled（逐轴）。丢弃过的量会打破它，所以把 discarded 一并计入。
    bool ConservationHolds(double tolerance) const;

private:
    LookPipelineSnapshot s_{};
};

}  // namespace amcl::input

#endif

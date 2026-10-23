// legacy_ring_discontinuity.cpp — legacy ring 不连续 epoch 的判定与 legacy-only 复位顺序
//
// 契约与锁序见头文件。这里只有三件事：步骤表完整性、固定的执行顺序、已消费 epoch 的登记。
// 不持锁、不打日志、不调用任何平台 API，因此 touch_input.cpp（产品）与 host 测试链接的是
// 同一份实现；日志与锁由 touch_input.cpp 在调用点负责。
#include "legacy_ring_discontinuity.h"

namespace amcl::input {

bool LegacyRingResetStepsComplete(const LegacyRingResetSteps& steps) {
    return steps.clearExternalHeld && steps.releaseLedgerOwners &&
           steps.resetSchemaTransient && steps.cancelMenuTransaction &&
           steps.retireFingersStillDown && steps.completeResetBoundary;
}

void RunLegacyRingReset(const LegacyRingResetSteps& steps) {
    if (!LegacyRingResetStepsComplete(steps)) return;
    // 1. 先清按端持有表，再清 ledger：顺序与完整 cancel 相同。反过来会留下 registry 里有记录、
    //    ledger 里已没有 owner 的幽灵条目，端下一次 PRESS 就会叠在它上面（规范 §3.3）。
    steps.clearExternalHeld(steps.context);
    // 2. ledger 一次性释放全部 owner。RELEASE 经 ring 下发；已经 fail-safe 释放过的消费者把它们
    //    当成无主 RELEASE 忽略，没有溢出的兄弟消费者则靠它们与 ledger 回到同一零状态。
    steps.releaseLedgerOwners(steps.context);
    // 3. schema 解释器的瞬时状态（按钮 owner、WASD、carried owner、finger 绑定）。
    //    它们的 owner 在第 2 步已从 ledger 消失，这一步只清运行态并投影 UI 松开。
    steps.resetSchemaTransient(steps.context);
    // 4. 菜单指针事务以原 token 撤销；ring 丢历史后 bridge 那侧的 token 早已作废。
    steps.cancelMenuTransaction(steps.context);
    // 5. 仍按下的手指作废直到 UP，避免它们在清空后的绑定上被重新解释成 look 或点击。
    steps.retireFingersStillDown(steps.context);
    // 6. 最后推进前端复位边界：ArkTS 见到 epoch 变化后按 native 先归零的方向丢缓存。
    steps.completeResetBoundary(steps.context);
}

void MarkFingersDeadUntilUp(const bool* fingerDown, bool* fingerDead,
                            size_t count) {
    if (!fingerDown || !fingerDead) return;
    for (size_t i = 0; i < count; ++i) {
        if (fingerDown[i]) fingerDead[i] = true;
    }
}

bool LegacyRingDiscontinuityTracker::Changed(uint64_t observedEpoch) const {
    return observedEpoch != consumed_.load(std::memory_order_acquire);
}

bool LegacyRingDiscontinuityTracker::ReconcileLocked(
        uint64_t observedEpoch, const LegacyRingResetSteps& steps) {
    if (observedEpoch == consumed_.load(std::memory_order_relaxed)) return false;
    // 步骤表不完整是装配错误：不登记，保留下一次入口重试的机会，而不是把丢历史当成已处理。
    if (!LegacyRingResetStepsComplete(steps)) return false;
    RunLegacyRingReset(steps);
    // 复位完成之后才登记：并发入口的无锁快速路径若在此之前看到“已变化”，会在锁上等待，
    // 拿到锁后重新读取 epoch 再比较，不会重复执行复位。
    consumed_.store(observedEpoch, std::memory_order_release);
    resets_.fetch_add(1u, std::memory_order_relaxed);
    return true;
}

void LegacyRingDiscontinuityTracker::AbsorbLocked(uint64_t observedEpoch) {
    if (observedEpoch == consumed_.load(std::memory_order_relaxed)) return;
    consumed_.store(observedEpoch, std::memory_order_release);
    absorbed_.fetch_add(1u, std::memory_order_relaxed);
}

uint64_t LegacyRingDiscontinuityTracker::ConsumedEpoch() const {
    return consumed_.load(std::memory_order_acquire);
}

uint64_t LegacyRingDiscontinuityTracker::ResetCount() const {
    return resets_.load(std::memory_order_relaxed);
}

uint64_t LegacyRingDiscontinuityTracker::AbsorbCount() const {
    return absorbed_.load(std::memory_order_relaxed);
}

}  // namespace amcl::input

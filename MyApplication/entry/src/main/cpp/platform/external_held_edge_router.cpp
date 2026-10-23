// external_held_edge_router.cpp — 按端持有边沿组合事务的实现。契约、锁序与因果见 .h。
//
// 本 TU 刻意不含 hilog 与自有锁：它必须能在主机侧被原样链接进 host 测试，
// 使“NAPI 返回值是否如实”由产品代码本身证明，而不是由测试里的复刻证明。
#include "external_held_edge_router.h"

namespace amcl::input {

namespace {

// ledger 的三态转换结果映射到“本端变更已生效”的两档。Rejected 不在这里处理：
// 它对 Press/Repeat/Release 的含义不同（回滚、拒绝、已摘除），由各分支自行决定。
ExternalHeldEdgeResult AppliedFrom(LedgerTransitionResult transition) {
    return transition == LedgerTransitionResult::Emitted
               ? ExternalHeldEdgeResult::AppliedEmitted
               : ExternalHeldEdgeResult::AppliedNoFinalEdge;
}

}  // namespace

ExternalHeldEdgeRouter::ExternalHeldEdgeRouter(ExternalHeldRegistry& registry,
                                               std::mutex& registryMutex,
                                               InputLedger& ledger)
    : registry_(registry), registryMutex_(registryMutex), ledger_(ledger) {}

OwnerToken ExternalHeldEdgeRouter::AcquireControl(const ExternalControlIdentity& identity,
        const std::vector<Output>& outputs, OwnerToken newOwner) {
    ExternalControlAcquire acquired{};
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        acquired = registry_.AcquireControl(identity, outputs, newOwner);
    }
    if (!acquired.created) return acquired.owner;
    for (const auto& output : outputs) {
        bool live = false;
        {
            std::lock_guard<std::mutex> lock(registryMutex_);
            live = registry_.HasControl(acquired.owner);
        }
        if (!live || ledger_.acquireTransition(acquired.owner, output) ==
                         LedgerTransitionResult::Rejected) {
            ReleaseControl(acquired.owner);
            ledger_.releaseOwner(acquired.owner);
            return 0u;
        }
    }
    // 最后一个 emit 也能同步复位；不能把已经撤销的 token 当成成功交回前端。
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        if (registry_.HasControl(acquired.owner)) return acquired.owner;
    }
    ledger_.releaseOwner(acquired.owner);
    return 0u;
}

bool ExternalHeldEdgeRouter::ReleaseControl(OwnerToken owner) {
    if (owner == 0u) return false;
    std::vector<Output> outputs;
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        outputs = registry_.TakeControl(owner);
    }
    // 先摘旧租约，再倒序释放：末松修饰键，且回调创建的新控件不会被旧 UP 命中。
    for (auto it = outputs.rbegin(); it != outputs.rend(); ++it) {
        (void)ledger_.releaseTransition(owner, *it);
    }
    return true;
}

ExternalHeldEdgeResult ExternalHeldEdgeRouter::Route(AmclInputSource source,
                                                     const Output& output,
                                                     ExternalHeldAction action,
                                                     OwnerToken pressOwner) {
    switch (action) {
        case ExternalHeldAction::Press:
            return Press(source, output, pressOwner);
        case ExternalHeldAction::Repeat:
            return Repeat(source, output);
        case ExternalHeldAction::Release:
            return Release(source, output);
    }
    // 枚举之外的值只可能来自内存破坏或错误的强制转换；按“未改变任何记录”处理。
    return ExternalHeldEdgeResult::Rejected;
}

ExternalHeldEdgeResult ExternalHeldEdgeRouter::Press(AmclInputSource source,
                                                     const Output& output,
                                                     OwnerToken owner) {
    // 第一步只登记本端记录；owner==0 或越界端身份由 registry 拒绝，此时 ledger 完全不被触碰。
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        if (!registry_.Acquire(output, source, owner)) {
            return ExternalHeldEdgeResult::Rejected;
        }
    }
    // 第二步在 registry 锁外交给 ledger：首个 owner 发 PRESS，其余只加入引用计数。
    const LedgerTransitionResult transition = ledger_.acquireTransition(owner, output);
    if (transition != LedgerTransitionResult::Rejected) {
        return AppliedFrom(transition);
    }
    // ledger 拒绝只在“该 owner 已持有此输出”时发生，新 token 下不可达。仍按 owner 精确回滚，
    // 保证返回 Rejected 时 registry 里没有残留记录，否则会重新制造本类要消除的幽灵 owner。
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        (void)registry_.Forget(output, source, owner);
    }
    return ExternalHeldEdgeResult::Rejected;
}

ExternalHeldEdgeResult ExternalHeldEdgeRouter::Repeat(AmclInputSource source,
                                                      const Output& output) {
    // REPEAT 只读同端最近一条记录、不消费；别端的记录不能延长本端的持有。
    OwnerToken owner = 0;
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        owner = registry_.PeekSameSource(output, source);
    }
    if (owner == 0) return ExternalHeldEdgeResult::Rejected;
    // ledger 不认该 owner 时拒绝：registry 未被修改，调用方的记录保持原状。
    const LedgerTransitionResult transition = ledger_.repeatTransition(owner, output);
    return transition == LedgerTransitionResult::Rejected
               ? ExternalHeldEdgeResult::Rejected
               : AppliedFrom(transition);
}

ExternalHeldEdgeResult ExternalHeldEdgeRouter::Release(AmclInputSource source,
                                                       const Output& output) {
    // 先摘除同端最近一条记录（LIFO，跳过别端记录）；无配对记录即拒绝，ledger 不被触碰。
    OwnerToken owner = 0;
    {
        std::lock_guard<std::mutex> lock(registryMutex_);
        owner = registry_.TakeSameSource(output, source);
    }
    if (owner == 0) return ExternalHeldEdgeResult::Rejected;
    // 记录已经摘除，本端不再持有该输出，因此无论 ledger 结果如何都算生效：
    // 末位 owner 发 RELEASE；仍有其它 owner 时不发；ledger 早已不持有该 owner 时也不补发边沿。
    const LedgerTransitionResult transition = ledger_.releaseTransition(owner, output);
    return transition == LedgerTransitionResult::Emitted
               ? ExternalHeldEdgeResult::AppliedEmitted
               : ExternalHeldEdgeResult::AppliedNoFinalEdge;
}

}  // namespace amcl::input

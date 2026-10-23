#ifndef AMCL_LEGACY_OUTPUT_RUNTIME_H
#define AMCL_LEGACY_OUTPUT_RUNTIME_H

#include "external_held_edge_router.h"
#include "legacy_physical_edge_router.h"
#include <atomic>

namespace amcl::input {
/** 所有兼容来源共用的输出运行时。只拥有事务锁、来源/控件持有、最终输出聚合和物理
 * 身份路由，不认识触控schema、ArkUI、NAPI或窗口。触控解释器只是一个调用者。
 *
 * 对组合操作，先持 TransactionMutex，再取 RegistryMutex，ledger的emit发生在注册表锁外。
 * getter借出的对象与运行时等寿命；局部测试可以实例化独立运行时并注入记录型出口。
 */
class LegacyOutputRuntime final {
public:
    explicit LegacyOutputRuntime(EmitFn emit);
    LegacyOutputRuntime(const LegacyOutputRuntime&) = delete;
    LegacyOutputRuntime& operator=(const LegacyOutputRuntime&) = delete;
    std::recursive_mutex& TransactionMutex() { return transactionMutex_; }
    std::mutex& RegistryMutex() { return registryMutex_; }
    ExternalHeldRegistry& Registry() { return registry_; }
    InputLedger& Ledger() { return ledger_; }
    LegacyPhysicalEdgeRouter& Physical() { return physical_; }
    ExternalHeldEdgeRouter& External() { return external_; }
    // 全局token域只在此分配。耗尽时返回0供入口拒绝，不回绕到另一活跃owner。
    OwnerToken NextOwner();
    // 对普通新来源提供完整事务入口，调用者不必认识registry/ledger的组合锁序。
    OwnerToken AcquireControl(const ExternalControlIdentity& identity, const std::vector<Output>& outputs);
    bool ReleaseControl(OwnerToken token);
    size_t ReleaseSource(AmclInputSource source);
    /** 仅 neutral source facade 在自己的递归事务锁中使用。候选复用原 registry/router/
     * ledger 算法并将 emit 收到值向量；正式提交只交换数据节点，不调用消费者或分配。
     * token 分配器保持原实例单调，不从候选拷贝，拒绝的尝试可耗掉编号而不复用。 */
    void CopyStateFrom(LegacyOutputRuntime& prior);
    void SwapState(LegacyOutputRuntime& candidate) noexcept;

private:
    std::recursive_mutex transactionMutex_;
    std::mutex registryMutex_;
    ExternalHeldRegistry registry_;
    InputLedger ledger_;
    LegacyPhysicalEdgeRouter physical_;
    ExternalHeldEdgeRouter external_;
    std::atomic<OwnerToken> nextOwner_{0x400000000ULL};
};

// neutral 内的唯一公共输出 owner；平台不得直接链接此 C++ 符号或借其容器/锁。
// 初始化不调用平台服务，不产生事件；第一次实际输出仍须由调用者通过自己的准入门禁。
LegacyOutputRuntime& ProcessLegacyOutputRuntime();
/** neutral 初始化的可失败入口；分配/构造失败返回空，不把容量问题变成进程 abort。
 * PID 前置核验由 source facade 完成，平台不能直接调用此 C++ 函数。 */
LegacyOutputRuntime* TryProcessLegacyOutputRuntime() noexcept;
}
#endif

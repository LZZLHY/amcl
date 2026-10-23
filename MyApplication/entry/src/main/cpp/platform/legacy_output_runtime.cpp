#include "legacy_output_runtime.h"
#include <utility>
#include <new>
#include <cstdlib>

#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
void inputBridge_pushEvent(int type,int i1,int i2,int i3,int i4);
#else
extern "C" void inputBridge_pushEvent(int type, int i1, int i2, int i3, int i4);
#endif

namespace amcl::input {
LegacyOutputRuntime::LegacyOutputRuntime(EmitFn emit)
    : ledger_(std::move(emit)), physical_(ledger_, transactionMutex_),
      external_(registry_, registryMutex_, ledger_) {}

void LegacyOutputRuntime::CopyStateFrom(LegacyOutputRuntime& prior) {
    if (this == &prior) return;
    std::scoped_lock transaction(transactionMutex_, prior.transactionMutex_);
    {
        std::scoped_lock registry(registryMutex_, prior.registryMutex_);
        registry_ = prior.registry_;
    }
    ledger_.CopyStateFrom(prior.ledger_);
    physical_.CopyStateFrom(prior.physical_);
}

void LegacyOutputRuntime::SwapState(LegacyOutputRuntime& candidate) noexcept {
    if (this == &candidate) return;
    std::scoped_lock transaction(transactionMutex_, candidate.transactionMutex_);
    {
        std::scoped_lock registry(registryMutex_, candidate.registryMutex_);
        registry_.SwapState(candidate.registry_);
    }
    ledger_.SwapState(candidate.ledger_);
    physical_.SwapState(candidate.physical_);
}

OwnerToken LegacyOutputRuntime::NextOwner() {
    OwnerToken current = nextOwner_.load(std::memory_order_relaxed);
    while (current != UINT64_MAX) {
        if (nextOwner_.compare_exchange_weak(current, current + 1u, std::memory_order_relaxed)) return current;
    }
    return 0u;
}

OwnerToken LegacyOutputRuntime::AcquireControl(const ExternalControlIdentity& identity,
                                               const std::vector<Output>& outputs) {
    std::lock_guard<std::recursive_mutex> transaction(transactionMutex_);
    if (physical_.ResetInProgress()) return 0u;
    return external_.AcquireControl(identity, outputs, NextOwner());
}

bool LegacyOutputRuntime::ReleaseControl(OwnerToken token) {
    std::lock_guard<std::recursive_mutex> transaction(transactionMutex_);
    return external_.ReleaseControl(token);
}

size_t LegacyOutputRuntime::ReleaseSource(AmclInputSource source) {
    std::lock_guard<std::recursive_mutex> transaction(transactionMutex_);
    std::vector<std::pair<Output, OwnerToken>> retired;
    {
        std::lock_guard<std::mutex> registry(registryMutex_);
        retired = registry_.DrainSource(source);
    }
    // 先摘完整集合，再发释放；同步回调取得的新owner不属于本次退休集合。
    for (const auto& item : retired) (void)ledger_.releaseTransition(item.second, item.first);
    return retired.size();
}

LegacyOutputRuntime* TryProcessLegacyOutputRuntime() noexcept {
    // 仅 neutral TU 构建这一进程实例；平台通过版本化 POD facade 借用，不能链接此符号。
    // owner 是进程 pin：退出期平台 facade 的析构/清理仍可能查询它，不在静态析构中销毁。
    // C 边界可报告冷 NotReady；nothrow 本身不吞构造异常，因此同时捕获 bad_alloc。
    // 失败后的槽位保留空，不能在另一 namespace 构造 fallback 或借出空引用。
    static LegacyOutputRuntime* runtime = []() noexcept -> LegacyOutputRuntime* {
        try {return new(std::nothrow) LegacyOutputRuntime([](const Output& output, int action) {
        // 既有五int游戏ABI在唯一出口编码一次；所有source共享同一最终首按/末松规则。
        if (output.kind == OutputKind::Key) inputBridge_pushEvent(1005, output.code, 0, action, 0);
        else inputBridge_pushEvent(1006, output.code, action, 0, 0);
        });}catch(const std::bad_alloc&){return nullptr;}
    }();
    return runtime;
}
LegacyOutputRuntime& ProcessLegacyOutputRuntime() {
    // 仅旧 C++ 宿主/内部调用的引用形式；生产 POD facade 只使用可失败指针形式。
    auto* runtime=TryProcessLegacyOutputRuntime();if(!runtime)throw std::bad_alloc();return *runtime;
}
}

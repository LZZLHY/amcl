#include "input_ledger.h"

#include <utility>
#include <vector>

namespace amcl::input {

// Ledger 维护双向索引而不是单纯的“已按下键集合”：byOwner_ 用于在 finger/schema/lifecycle
// 边界按因果来源整体撤销，byOutput_ 用于多个按钮共享同一键时做引用计数。第一个 owner 获取
// output 才向 Minecraft 发 PRESS，最后一个 owner 消失才发 RELEASE。
//
// emit_ 一律在 mutex_ 外调用。bridge 回调可能同步触发 grab、窗口或上层状态迁移；若持 ledger
// 锁调用，任何回入 releaseAll/releaseOwner 都会自锁。锁内只计算边沿并保存待发 Output，锁外
// 再提交事件，因此 mutex_ 只保护索引，不承担跨模块回调的锁顺序。
InputLedger::InputLedger(EmitFn emit) : emit_(std::move(emit)) {}

LedgerTransitionResult InputLedger::acquireTransition(
        OwnerToken owner, const Output& output) {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    bool emitPress = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& outputs = byOwner_[owner];
        if (!outputs.insert(output).second) {
            return LedgerTransitionResult::Rejected;
        }
        auto& owners = byOutput_[output];
        emitPress = owners.empty();
        owners.insert(owner);
    }
    if (emitPress) {
        emit_(output, 1);
    }
    return emitPress ? LedgerTransitionResult::Emitted
                     : LedgerTransitionResult::HandledNoFinalEdge;
}

bool InputLedger::acquire(OwnerToken owner, const Output& output) {
    return acquireTransition(owner, output) == LedgerTransitionResult::Emitted;
}

LedgerTransitionResult InputLedger::repeatTransition(
        OwnerToken owner, const Output& output) {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto oit = byOwner_.find(owner);
        if (oit == byOwner_.end() || oit->second.count(output) == 0) {
            return LedgerTransitionResult::Rejected;
        }
    }
    // Repeat is a delivered edge but never changes owner cardinality. As with
    // every emit, callback execution is outside the ledger state mutex.
    emit_(output, 2);
    return LedgerTransitionResult::Emitted;
}

bool InputLedger::repeat(OwnerToken owner, const Output& output) {
    return repeatTransition(owner, output) == LedgerTransitionResult::Emitted;
}

LedgerTransitionResult InputLedger::releaseTransition(
        OwnerToken owner, const Output& output) {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    bool emitRelease = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto oit = byOwner_.find(owner);
        if (oit == byOwner_.end() || !oit->second.erase(output)) {
            return LedgerTransitionResult::Rejected;
        }
        if (oit->second.empty()) byOwner_.erase(oit);
        auto vit = byOutput_.find(output);
        if (vit == byOutput_.end() || vit->second.erase(owner) == 0) {
            return LedgerTransitionResult::Rejected;
        }
        if (vit->second.empty()) {
            byOutput_.erase(vit);
            emitRelease = true;
        }
    }
    if (emitRelease) {
        emit_(output, 0);
    }
    return emitRelease ? LedgerTransitionResult::Emitted
                       : LedgerTransitionResult::HandledNoFinalEdge;
}

bool InputLedger::release(OwnerToken owner, const Output& output) {
    return releaseTransition(owner, output) == LedgerTransitionResult::Emitted;
}

void InputLedger::releaseOwnerLocked(OwnerToken owner, std::vector<Output>& releases) {
    auto oit = byOwner_.find(owner);
    if (oit == byOwner_.end()) return;
    for (const Output& output : oit->second) {
        auto vit = byOutput_.find(output);
        if (vit == byOutput_.end()) continue;
        vit->second.erase(owner);
        if (vit->second.empty()) {
            byOutput_.erase(vit);
            releases.push_back(output);
        }
    }
    byOwner_.erase(oit);
}

void InputLedger::releaseOwner(OwnerToken owner) {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    std::vector<Output> releases;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        releaseOwnerLocked(owner, releases);
    }
    for (const Output& output : releases) emit_(output, 0);
}

void InputLedger::releaseAll() {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    std::vector<Output> releases;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& item : byOutput_) releases.push_back(item.first);
        byOwner_.clear();
        byOutput_.clear();
    }
    for (const Output& output : releases) emit_(output, 0);
}

void InputLedger::releaseAllExcept(const std::set<OwnerToken>& keepOwners) {
    std::lock_guard<std::recursive_mutex> submitLock(emitMutex_);
    std::vector<Output> releases;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<OwnerToken> remove;
        for (const auto& item : byOwner_) {
            if (!keepOwners.count(item.first)) remove.push_back(item.first);
        }
        for (OwnerToken owner : remove) releaseOwnerLocked(owner, releases);
    }
    for (const Output& output : releases) emit_(output, 0);
}

bool InputLedger::owns(OwnerToken owner, const Output& output) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = byOwner_.find(owner);
    return it != byOwner_.end() && it->second.count(output) != 0;
}

// 只取 mutex_（索引锁），**不取 emitMutex_**：这两个 getter 不产生边沿，而在提交事务
// 内部同步查询它们是合法用法（emit 回调里读一次当前账目）。取 emitMutex_ 反而会把
// 一个纯读操作拉进提交序。
std::size_t InputLedger::ownerCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return byOwner_.size();
}

std::size_t InputLedger::outputCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return byOutput_.size();
}

} // namespace amcl::input

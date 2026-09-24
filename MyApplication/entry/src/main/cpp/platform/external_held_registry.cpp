// external_held_registry.cpp — 按端持有记账的实现。契约与理由见 .h。
//
// 刻意不含 mutex、不含 hilog：本 TU 必须能在主机侧被完整测试。
#include "external_held_registry.h"

#include <iterator>

namespace amcl::input {

bool ExternalHeldRegistry::InRange(AmclInputSource source) {
    // 先转 int 再比较：枚举的底层类型由实现选择，若它是无符号的，
    // `source >= AMCL_INPUT_SOURCE_NONE` 就是恒真比较，clang/gcc 在
    // `-Wextra -Werror` 下会直接拒绝编译（本地 host test 走 MSVC，底层类型是 int，
    // 不会暴露这一点 —— 所以这里不能依赖本地构建通过）。
    const int value = static_cast<int>(source);
    return value >= static_cast<int>(AMCL_INPUT_SOURCE_NONE) &&
           value < AMCL_INPUT_SOURCE_COUNT;
}

bool ExternalHeldRegistry::Acquire(const Output& output, AmclInputSource source,
                                  OwnerToken owner) {
    // owner==0 是"无 owner"哨兵。存进表里会让 TakeSameSource 返回 0 却已经摘掉一条
    // 记录 —— 调用方看到 0 会判为"无配对"并丢弃边沿，而记录已经没了，账就永久失衡。
    if (owner == 0 || !InRange(source)) return false;
    byOutput_[output].push_back(ExternalHeldRecord{source, owner});
    acquired_[static_cast<int>(source)] += 1u;
    return true;
}

OwnerToken ExternalHeldRegistry::PeekSameSource(const Output& output,
                                                AmclInputSource source) const {
    if (!InRange(source)) return 0;
    const auto it = byOutput_.find(output);
    if (it == byOutput_.end()) return 0;
    const std::vector<ExternalHeldRecord>& records = it->second;
    for (auto rit = records.rbegin(); rit != records.rend(); ++rit) {
        if (rit->source == source) return rit->owner;
    }
    return 0;
}

OwnerToken ExternalHeldRegistry::TakeSameSource(const Output& output,
                                               AmclInputSource source) {
    if (!InRange(source)) return 0;
    auto it = byOutput_.find(output);
    if (it == byOutput_.end()) return 0;
    std::vector<ExternalHeldRecord>& records = it->second;
    for (auto rit = records.rbegin(); rit != records.rend(); ++rit) {
        if (rit->source != source) continue;
        const OwnerToken owner = rit->owner;
        // 反向迭代器与正向迭代器的标准恒等式：&*rit == &*(rit.base() - 1)，
        // 所以 std::next(rit).base() 正好指向 rit 所指元素。
        records.erase(std::next(rit).base());
        released_[static_cast<int>(source)] += 1u;
        if (records.empty()) byOutput_.erase(it);
        return owner;
    }
    return 0;
}

std::vector<std::pair<Output, OwnerToken>>
ExternalHeldRegistry::DrainSource(AmclInputSource source) {
    std::vector<std::pair<Output, OwnerToken>> drained;
    if (!InRange(source)) return drained;
    for (auto it = byOutput_.begin(); it != byOutput_.end();) {
        std::vector<ExternalHeldRecord>& records = it->second;
        for (auto rit = records.begin(); rit != records.end();) {
            if (rit->source == source) {
                drained.emplace_back(it->first, rit->owner);
                rit = records.erase(rit);
            } else {
                ++rit;
            }
        }
        // 条件先求值，随后只执行一个分支；erase(it) 之后 records 悬垂但不再被使用。
        it = records.empty() ? byOutput_.erase(it) : std::next(it);
    }
    released_[static_cast<int>(source)] +=
        static_cast<std::uint32_t>(drained.size());
    return drained;
}

void ExternalHeldRegistry::Clear() {
    for (const auto& entry : byOutput_) {
        for (const ExternalHeldRecord& record : entry.second) {
            if (InRange(record.source)) {
                released_[static_cast<int>(record.source)] += 1u;
            }
        }
    }
    byOutput_.clear();
}

std::size_t ExternalHeldRegistry::LiveCountForSource(
        AmclInputSource source) const {
    if (!InRange(source)) return 0u;
    std::size_t live = 0u;
    for (const auto& entry : byOutput_) {
        for (const ExternalHeldRecord& record : entry.second) {
            if (record.source == source) ++live;
        }
    }
    return live;
}

std::size_t ExternalHeldRegistry::LiveTotal() const {
    std::size_t live = 0u;
    for (const auto& entry : byOutput_) live += entry.second.size();
    return live;
}

std::size_t ExternalHeldRegistry::MaxRecordsForSameSource() const {
    std::size_t worst = 0u;
    for (const auto& entry : byOutput_) {
        // 按端分桶数，而不是数整个 vector：同一个 output 被**不同**端同时持有是**正确**的
        // （规范 §二 的核心推论 —— 跨端共享键，ledger 引用计数聚合成一对边沿）。
        // 只有**同一端**在同一个 output 上堆了多于一条才是异常。
        std::size_t perSource[AMCL_INPUT_SOURCE_COUNT] = {};
        for (const ExternalHeldRecord& record : entry.second) {
            if (!InRange(record.source)) continue;
            perSource[static_cast<int>(record.source)] += 1u;
        }
        for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
            if (perSource[i] > worst) worst = perSource[i];
        }
    }
    return worst;
}

std::uint32_t ExternalHeldRegistry::AcquiredForSource(
        AmclInputSource source) const {
    return InRange(source) ? acquired_[static_cast<int>(source)] : 0u;
}

std::uint32_t ExternalHeldRegistry::ReleasedForSource(
        AmclInputSource source) const {
    return InRange(source) ? released_[static_cast<int>(source)] : 0u;
}

}  // namespace amcl::input

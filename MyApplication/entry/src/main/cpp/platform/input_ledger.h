#ifndef AMCL_INPUT_LEDGER_H
#define AMCL_INPUT_LEDGER_H

#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <set>
#include <vector>

namespace amcl::input {

using OwnerToken = uint64_t;

enum class OutputKind : uint8_t { Key, Mouse };

struct Output {
    OutputKind kind;
    int code;
    bool operator<(const Output& other) const {
        if (kind != other.kind) return kind < other.kind;
        return code < other.code;
    }
};

using EmitFn = std::function<void(const Output&, int action)>;

enum class LedgerTransitionResult : uint8_t {
    Rejected = 0,
    HandledNoFinalEdge = 1,
    Emitted = 2,
};

class InputLedger final {
public:
    explicit InputLedger(EmitFn emit);
    // Return true only when this transition emitted a final aggregate edge.
    // Existing callers may ignore the result; physical routing uses it to
    // preserve its historical bool convenience API.
    bool acquire(OwnerToken owner, const Output& output);
    bool repeat(OwnerToken owner, const Output& output);
    bool release(OwnerToken owner, const Output& output);
    // Rich results distinguish a valid shared-output transition from a stale
    // or duplicate owner. Physical routing uses these methods so an ownerless
    // UP cannot be reported as a correctly aggregated release.
    LedgerTransitionResult acquireTransition(OwnerToken owner,
                                             const Output& output);
    LedgerTransitionResult repeatTransition(OwnerToken owner,
                                            const Output& output);
    LedgerTransitionResult releaseTransition(OwnerToken owner,
                                             const Output& output);
    void releaseOwner(OwnerToken owner);
    void releaseAll();
    void releaseAllExcept(const std::set<OwnerToken>& keepOwners);
    bool owns(OwnerToken owner, const Output& output) const;

    // 诊断读取口（不变量自检 + `AMCL_HELDLAYERS`）。⚠️ 两个数语义不同，不可互相替代：
    // `ownerCount` = 至少持有一个输出的 owner 数；`outputCount` = MC 侧当前按下的控件数。
    // 因果（第 2 层此前一个数都读不出来）见计划 §107.1–§107.2。
    std::size_t ownerCount() const;
    std::size_t outputCount() const;

private:
    void releaseOwnerLocked(OwnerToken owner, std::vector<Output>& releases);

    EmitFn emit_;
    mutable std::mutex mutex_;
    // State transitions are submitted in call order, outside mutex_. Recursive
    // locking permits an emit callback to synchronously enter the ledger.
    std::recursive_mutex emitMutex_;
    std::map<OwnerToken, std::set<Output>> byOwner_;
    std::map<Output, std::set<OwnerToken>> byOutput_;
};

} // namespace amcl::input

#endif

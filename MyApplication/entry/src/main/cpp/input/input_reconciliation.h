#ifndef AMCL_INPUT_RECONCILIATION_H
#define AMCL_INPUT_RECONCILIATION_H

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <set>

namespace amcl::input::reconciliation {

enum class Kind : uint8_t { Key, Relative, Button, Wheel };
enum class LegacyResult : uint8_t {
    Exact,
    Unmapped,
    Quantized,
    BridgeUnavailable,
    LegacyFallback,
    GateRejected,
    UnknownButton,
    InvalidInput,
};

// Finalization normally compares the mapping captured when the observation
// began. A physical UP/REPEAT may, however, arrive after the platform mapper
// disappeared or drifted. The shipping legacy identity router then returns the
// immutable mapping captured by DOWN; this sentinel lets callers supply that
// mapping without changing existing call sites.
constexpr int32_t kNoLegacyMappedOverride = INT32_MIN;

struct Summary {
    uint64_t begun = 0;
    uint64_t droppedBegin = 0;
    uint64_t finalized = 0;
    uint64_t unresolved = 0;
    uint64_t duplicateFinalize = 0;
    uint64_t unknownFinalize = 0;
    uint64_t orderMismatch = 0;
    uint64_t unexpectedMismatch = 0;
    uint64_t exact = 0;
    uint64_t unmapped = 0;
    uint64_t quantized = 0;
    uint64_t bridgeUnavailable = 0;
    uint64_t legacyFallback = 0;
    uint64_t gateRejected = 0;
    uint64_t unknownButton = 0;
    uint64_t invalidInput = 0;
    uint64_t typedHeldKeys = 0;
    uint64_t legacyHeldKeys = 0;
    uint64_t typedHeldButtons = 0;
    uint64_t legacyHeldButtons = 0;
    uint64_t mappedKeySymmetricDifference = 0;
    uint64_t mappedButtonSymmetricDifference = 0;
};

class Reconciler {
public:
    explicit Reconciler(std::size_t capacity = 256) : capacity_(capacity ? capacity : 1) {}

    uint64_t BeginKey(uint64_t deviceId, uint64_t raw, uint32_t typedAction,
                      int32_t mapped, bool typedAccepted) {
        std::lock_guard<std::mutex> lock(mutex_);
        Pending value{Kind::Key, {deviceId, raw}, mapped, typedAction, typedAccepted};
        return BeginLocked(value);
    }

    uint64_t BeginRelative(bool typedAccepted) {
        std::lock_guard<std::mutex> lock(mutex_);
        return BeginLocked({Kind::Relative, {}, 0, 0, typedAccepted});
    }

    uint64_t BeginButton(uint64_t deviceId, uint32_t nativeButton,
                         uint32_t typedAction, int32_t mapped,
                         bool typedAccepted) {
        std::lock_guard<std::mutex> lock(mutex_);
        Pending value{Kind::Button, {deviceId, nativeButton}, mapped,
                      typedAction, typedAccepted};
        return BeginLocked(value);
    }

    uint64_t BeginWheel(bool typedAccepted) {
        std::lock_guard<std::mutex> lock(mutex_);
        return BeginLocked({Kind::Wheel, {}, 0, 0, typedAccepted});
    }

    bool Finalize(uint64_t token, LegacyResult result, int32_t legacyAction = -1,
                  uint32_t legacyCount = 0,
                  int32_t legacyMappedOverride = kNoLegacyMappedOverride) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto found = pending_.find(token);
        if (found == pending_.end()) {
            if (token != 0 && finalized_.count(token) != 0)
                ++summary_.duplicateFinalize;
            else
                ++summary_.unknownFinalize;
            return false;
        }

        // Compare against the pending frontier, not the numerically previous
        // completion: concurrent consumers may finalize later observations first.
        if (found != pending_.begin()) ++summary_.orderMismatch;
        const Pending value = found->second;
        pending_.erase(found);
        ++summary_.finalized;
        finalized_.insert(token);
        finalizedOrder_.push_back(token);
        if (finalizedOrder_.size() > capacity_) {
            finalized_.erase(finalizedOrder_.front());
            finalizedOrder_.pop_front();
        }
        CountResultLocked(result);
        Pending legacyValue = value;
        if ((value.kind == Kind::Key || value.kind == Kind::Button) &&
            legacyMappedOverride != kNoLegacyMappedOverride) {
            legacyValue.mapped = legacyMappedOverride;
        }
        UpdateLegacyLocked(legacyValue, result, legacyAction, legacyCount);
        return true;
    }

    void RecordGateRejected() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++summary_.gateRejected;
    }

    void RecordLegacyFallback() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++summary_.legacyFallback;
    }

    void ResetHeld() {
        std::lock_guard<std::mutex> lock(mutex_);
        summary_.unresolved += pending_.size();
        pending_.clear();
        typedKeys_.clear();
        legacyKeys_.clear();
        typedButtons_.clear();
        legacyButtons_.clear();
    }

    void BeginSession() {
        std::lock_guard<std::mutex> lock(mutex_);
        summary_ = {};
        pending_.clear();
        finalized_.clear();
        finalizedOrder_.clear();
        typedKeys_.clear();
        legacyKeys_.clear();
        typedButtons_.clear();
        legacyButtons_.clear();
        // Observation tokens are process-lifetime identities, not session-local
        // ordinals. Keeping the allocator monotonic makes a delayed Finalize
        // from an old route provably unable to settle a new session's pending
        // observation. Exhaustion therefore remains fail-closed across sessions.
    }

    Summary Snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        Summary result = summary_;
        result.unresolved += pending_.size();
        result.typedHeldKeys = typedKeys_.size();
        result.legacyHeldKeys = legacyKeys_.size();
        result.typedHeldButtons = typedButtons_.size();
        result.legacyHeldButtons = legacyButtons_.size();
        result.mappedKeySymmetricDifference =
            MappedSymmetricDifferenceLocked(typedKeys_, legacyKeys_);
        result.mappedButtonSymmetricDifference =
            MappedSymmetricDifferenceLocked(typedButtons_, legacyButtons_);
        return result;
    }

#ifdef AMCL_INPUT_HOST_TESTING
    void TestSetNextOrdinal(uint64_t value) {
        std::lock_guard<std::mutex> lock(mutex_);
        // Tests need a deterministic exhaustion edge; production has no API
        // that can move the monotonic allocator or manufacture token reuse.
        nextOrdinal_ = value;
    }
#endif

private:
    struct ControlIdentity {
        uint64_t deviceId = 0;
        uint64_t raw = 0;

        bool operator<(const ControlIdentity& other) const {
            return deviceId < other.deviceId ||
                   (deviceId == other.deviceId && raw < other.raw);
        }
    };

    struct Pending {
        Kind kind;
        ControlIdentity identity;
        int32_t mapped;
        uint32_t typedAction;
        bool typedAccepted;
    };

    using HeldLedger = std::map<ControlIdentity, int32_t>;
    using LegacyLedger = std::set<int32_t>;

    bool HasLegacyCapacityLocked(Kind kind, int32_t mapped) const {
        if (mapped < 0) return true;
        const LegacyLedger& legacy =
            kind == Kind::Key ? legacyKeys_ : legacyButtons_;
        if (legacy.count(mapped) != 0) return true;

        // A pending mapped DOWN can still finalize as Exact. Reserve by mapped
        // backend control—not by physical identity—because GLFW polling state
        // has one bit per mapped key/button and cannot represent contributors.
        std::set<int32_t> reserved = legacy;
        for (const auto& entry : pending_) {
            const Pending& value = entry.second;
            if (value.kind == kind && value.typedAction == 1 && value.mapped >= 0)
                reserved.insert(value.mapped);
        }
        return reserved.count(mapped) != 0 || reserved.size() < capacity_;
    }

    bool CanBeginLocked(const Pending& value) const {
        if (pending_.size() >= capacity_ || nextOrdinal_ == UINT64_MAX) return false;
        if (value.kind != Kind::Key && value.kind != Kind::Button) return true;

        const HeldLedger& typed = value.kind == Kind::Key ? typedKeys_ : typedButtons_;
        if (value.typedAccepted && value.typedAction == 1 &&
            typed.count(value.identity) == 0 && typed.size() >= capacity_) {
            return false;
        }
        if (value.typedAction == 1 &&
            !HasLegacyCapacityLocked(value.kind, value.mapped)) {
            return false;
        }
        return true;
    }

    uint64_t BeginLocked(const Pending& value) {
        // Admission and typed mutation share one lock and all logical capacity
        // checks run first, so a racing finalize sees one indivisible Begin.
        if (!CanBeginLocked(value)) {
            // Dropping preserves every older observation and held edge; eviction
            // would silently turn backpressure into an invented reconciliation.
            ++summary_.droppedBegin;
            return 0;
        }

        HeldLedger stagedTyped;
        HeldLedger* typed = nullptr;
        uint64_t stagedMismatch = 0;
        if (value.typedAccepted &&
            (value.kind == Kind::Key || value.kind == Kind::Button)) {
            typed = value.kind == Kind::Key ? &typedKeys_ : &typedButtons_;
            // Build the held mutation off to the side before reserving a token.
            // If allocation fails, neither pending nor typed state has changed;
            // after pending emplace succeeds, map::swap is a no-fail commit.
            stagedTyped = *typed;
            if (value.typedAction == 1) {
                stagedTyped[value.identity] = value.mapped;
            } else if (value.kind == Kind::Key && value.typedAction == 2) {
                if (stagedTyped.count(value.identity) == 0) ++stagedMismatch;
            } else if (value.typedAction == 3) {
                if (stagedTyped.erase(value.identity) == 0) ++stagedMismatch;
            }
        }

        const uint64_t token = nextOrdinal_ + 1;
        // Commit pending before typed held. This ordering is why a failed
        // allocation cannot leave a typed DOWN without its finalizable token.
        pending_.emplace(token, value);
        if (typed) typed->swap(stagedTyped);
        nextOrdinal_ = token;
        summary_.unexpectedMismatch += stagedMismatch;
        ++summary_.begun;
        return token;
    }

    void UpdateLegacyLocked(const Pending& value, LegacyResult result,
                            int32_t legacyAction, uint32_t legacyCount) {
        if (result != LegacyResult::Exact && result != LegacyResult::Quantized) return;
        if (!value.typedAccepted) {
            // A stale/error/overflow ordinary event was not committed to the
            // typed stream. Its legacy route is still counted as a divergence,
            // but must not repopulate reconciliation after the RESET/baseline
            // that rejected it; a later lifecycle reset is not guaranteed.
            ++summary_.unexpectedMismatch;
            return;
        }
        if ((value.kind == Kind::Key || value.kind == Kind::Button) &&
            value.mapped >= 0) {
            LegacyLedger& ledger =
                value.kind == Kind::Key ? legacyKeys_ : legacyButtons_;
            if (legacyAction == 1) {
                if (ledger.size() < capacity_ || ledger.count(value.mapped) != 0)
                    ledger.insert(value.mapped);
                else
                    ++summary_.unexpectedMismatch;
            } else if (legacyAction == 0 && ledger.erase(value.mapped) == 0) {
                ++summary_.unexpectedMismatch;
            }

            // Compare after every exact edge. This intentionally catches the
            // legacy aggregate-state bug where device A releases mapped W while
            // device B still owns the same physical-to-GLFW mapping.
            const HeldLedger& typed =
                value.kind == Kind::Key ? typedKeys_ : typedButtons_;
            if (MappedSymmetricDifferenceLocked(typed, ledger) != 0)
                ++summary_.unexpectedMismatch;
        } else if (value.kind == Kind::Wheel && result == LegacyResult::Quantized) {
            (void)legacyCount; // 0/N detents are an explicitly known difference.
        }
    }

    static uint64_t MappedSymmetricDifferenceLocked(const HeldLedger& typed,
                                                     const LegacyLedger& legacy) {
        // Typed state keeps every physical contributor. Legacy GLFW state is
        // already aggregated to one bit per mapped control, so only the typed
        // side is collapsed before taking the symmetric difference.
        std::set<int32_t> typedMapped;
        for (const auto& value : typed) {
            if (value.second >= 0) typedMapped.insert(value.second);
        }
        uint64_t total = 0;
        for (int32_t mapped : typedMapped) {
            if (legacy.count(mapped) == 0) ++total;
        }
        for (int32_t mapped : legacy) {
            if (typedMapped.count(mapped) == 0) ++total;
        }
        return total;
    }

    void CountResultLocked(LegacyResult result) {
        switch (result) {
            case LegacyResult::Exact: ++summary_.exact; break;
            case LegacyResult::Unmapped: ++summary_.unmapped; break;
            case LegacyResult::Quantized: ++summary_.quantized; break;
            case LegacyResult::BridgeUnavailable: ++summary_.bridgeUnavailable; break;
            case LegacyResult::LegacyFallback: ++summary_.legacyFallback; break;
            case LegacyResult::GateRejected: ++summary_.gateRejected; break;
            case LegacyResult::UnknownButton: ++summary_.unknownButton; break;
            case LegacyResult::InvalidInput: ++summary_.invalidInput; break;
        }
    }

    const std::size_t capacity_;
    mutable std::mutex mutex_;
    Summary summary_{};
    std::map<uint64_t, Pending> pending_;
    std::set<uint64_t> finalized_;
    std::deque<uint64_t> finalizedOrder_;
    HeldLedger typedKeys_;
    LegacyLedger legacyKeys_;
    HeldLedger typedButtons_;
    LegacyLedger legacyButtons_;
    uint64_t nextOrdinal_ = 0;
};

}  // namespace amcl::input::reconciliation

#endif

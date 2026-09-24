#include "legacy_physical_edge_router.h"

#include <vector>

namespace amcl::input {

LegacyPhysicalEdgeRouter::LegacyPhysicalEdgeRouter(
        InputLedger& ledger, std::recursive_mutex& transactionMutex)
    : ledger_(ledger), transactionMutex_(transactionMutex) {}

AmclLegacyPhysicalOutcome LegacyPhysicalEdgeRouter::Route(
        bool bridgeAvailable, const LegacyPhysicalIdentity& identity,
        const Output* mappedOutput, LegacyPhysicalAction action,
        OwnerToken newOwner, int* routedMappedCode) {
    std::lock_guard<std::recursive_mutex> lock(transactionMutex_);
    if (routedMappedCode) *routedMappedCode = -1;
    if (resetting_) return AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS;
    if (!bridgeAvailable) return AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    auto found = held_.find(identity);

    if (action == LegacyPhysicalAction::Down) {
        if (found != held_.end()) {
            return AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN;
        }
        if (!mappedOutput || mappedOutput->kind != identity.kind ||
            mappedOutput->code < 0 || newOwner == 0) {
            return AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL;
        }
        const HeldEdge edge{newOwner, *mappedOutput};
        // Publish identity before acquire: an emit callback may synchronously
        // re-enter Repeat/Up, and it must observe the accepted Down.
        held_.emplace(identity, edge);
        if (routedMappedCode) *routedMappedCode = edge.output.code;
        const LedgerTransitionResult result =
            ledger_.acquireTransition(edge.owner, edge.output);
        if (result == LedgerTransitionResult::Rejected) {
            // No callback runs for a rejected acquire, so this is still the
            // exact entry inserted above. Retire it rather than creating an
            // identity whose owner never reached the ledger.
            held_.erase(identity);
            if (routedMappedCode) *routedMappedCode = -1;
            return AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN;
        }
        return result == LedgerTransitionResult::Emitted
            ? AMCL_LEGACY_PHYSICAL_EMITTED
            : AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    }

    if (action == LegacyPhysicalAction::Repeat) {
        if (found == held_.end()) {
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT;
        }
        const HeldEdge edge = found->second;
        // The mapping captured by Down is authoritative for this identity.
        // A missing/drifting mapper on Repeat cannot borrow another owner's
        // key or inject a different key. Copy it before emit: the callback can
        // synchronously route UP/Reset and invalidate every held_ iterator.
        if (ledger_.repeatTransition(edge.owner, edge.output) ==
            LedgerTransitionResult::Emitted) {
            if (routedMappedCode) {
                *routedMappedCode = edge.output.code;
            }
            return AMCL_LEGACY_PHYSICAL_EMITTED;
        }
        // A domain boundary must normally reset identity and ledger together.
        // If a defensive ledger check still finds a stale identity, retire it
        // now so the next real Down can recover instead of remaining Duplicate.
        held_.erase(found);
        return AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT;
    }

    if (action == LegacyPhysicalAction::Up) {
        if (found == held_.end()) {
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_UP;
        }
        const HeldEdge edge = found->second;
        // Erase first for the same re-entry guarantee as Reset().
        held_.erase(found);
        if (routedMappedCode) *routedMappedCode = edge.output.code;
        const LedgerTransitionResult result =
            ledger_.releaseTransition(edge.owner, edge.output);
        if (result == LedgerTransitionResult::Rejected) {
            if (routedMappedCode) *routedMappedCode = -1;
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_UP;
        }
        return result == LedgerTransitionResult::Emitted
            ? AMCL_LEGACY_PHYSICAL_EMITTED
            : AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    }

    return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
}

void LegacyPhysicalEdgeRouter::Reset(const ResetWork& whileFenced) {
    std::lock_guard<std::recursive_mutex> lock(transactionMutex_);
    if (resetting_) return;
    resetting_ = true;
    struct ResetFence final {
        bool& flag;
        ~ResetFence() { flag = false; }
    } resetFence{resetting_};
    std::vector<HeldEdge> releases;
    releases.reserve(held_.size());
    for (const auto& item : held_) releases.push_back(item.second);
    held_.clear();
    for (const HeldEdge& edge : releases) {
        ledger_.release(edge.owner, edge.output);
    }
    if (whileFenced) whileFenced();
}

bool LegacyPhysicalEdgeRouter::ResetInProgress() const {
    std::lock_guard<std::recursive_mutex> lock(transactionMutex_);
    return resetting_;
}

size_t LegacyPhysicalEdgeRouter::HeldIdentityCount() const {
    std::lock_guard<std::recursive_mutex> lock(transactionMutex_);
    return held_.size();
}

}  // namespace amcl::input

#ifndef AMCL_LEGACY_PHYSICAL_EDGE_ROUTER_H
#define AMCL_LEGACY_PHYSICAL_EDGE_ROUTER_H

#include "../input/legacy_physical_outcome.h"
#include "input_ledger.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>

namespace amcl::input {

enum class LegacyPhysicalAction : uint8_t {
    Down = 0,
    Repeat = 1,
    Up = 2,
};

struct LegacyPhysicalIdentity {
    OutputKind kind = OutputKind::Key;
    uint64_t deviceId = 0;
    uint32_t rawControl = 0;

    bool operator<(const LegacyPhysicalIdentity& other) const {
        if (kind != other.kind) return kind < other.kind;
        if (deviceId != other.deviceId) return deviceId < other.deviceId;
        return rawControl < other.rawControl;
    }
};

// Shipping physical-key/button lifecycle state machine. The caller supplies
// the same recursive transaction mutex used by every other legacy producer, so
// synchronous bridge re-entry cannot invert physical-router and InputLedger
// ordering. InputLedger still owns final-output aggregation.
class LegacyPhysicalEdgeRouter final {
public:
    LegacyPhysicalEdgeRouter(InputLedger& ledger,
                             std::recursive_mutex& transactionMutex);

    AmclLegacyPhysicalOutcome Route(bool bridgeAvailable,
                                    const LegacyPhysicalIdentity& identity,
                                    const Output* mappedOutput,
                                    LegacyPhysicalAction action,
                                    OwnerToken newOwner,
                                    int* routedMappedCode = nullptr);

    // Full lifecycle reset: erase identities before releasing their owners and
    // reject every synchronously re-entered physical edge until `whileFenced`
    // completes. This lets the product put ledger/schema/finger cleanup inside
    // the same zero-held boundary without a release callback repopulating the
    // physical identity table.
    using ResetWork = std::function<void()>;
    void Reset(const ResetWork& whileFenced = ResetWork{});
    // The full legacy cancel transaction reuses this fence for schema/external
    // producers. Callers holding transactionMutex may query it recursively;
    // other threads wait until the reset boundary has completed.
    bool ResetInProgress() const;
    size_t HeldIdentityCount() const;

private:
    struct HeldEdge {
        OwnerToken owner = 0;
        Output output{OutputKind::Key, 0};
    };

    InputLedger& ledger_;
    std::recursive_mutex& transactionMutex_;
    std::map<LegacyPhysicalIdentity, HeldEdge> held_;
    bool resetting_ = false;
};

}  // namespace amcl::input

#endif

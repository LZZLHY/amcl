#include "../../platform/input_ledger.h"
#include "../../platform/legacy_physical_edge_router.h"

#include <cstdlib>
#include <iostream>
#include <mutex>
#include <vector>

using amcl::input::InputLedger;
using amcl::input::LegacyPhysicalAction;
using amcl::input::LegacyPhysicalEdgeRouter;
using amcl::input::LegacyPhysicalIdentity;
using amcl::input::Output;
using amcl::input::OutputKind;

namespace {

struct EmittedEdge {
    Output output;
    int action;
};

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LEGACY PHYSICAL ROUTER FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

bool IsEdge(const EmittedEdge& edge, OutputKind kind, int code, int action) {
    return edge.output.kind == kind && edge.output.code == code &&
           edge.action == action;
}

void TestDownRepeatUnknownMappingUpUsesCapturedOutput() {
    std::vector<EmittedEdge> emitted;
    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
    });
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);

    const LegacyPhysicalIdentity identity{OutputKind::Key, 71u, 4001u};
    const Output mappedDown{OutputKind::Key, 65};
    const Output driftingRepeatMap{OutputKind::Key, 66};
    int routed = -1;

    CHECK(router.Route(true, identity, &mappedDown,
                       LegacyPhysicalAction::Down, 101u, &routed) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(routed == 65);
    CHECK(router.HeldIdentityCount() == 1u);
    CHECK(ledger.owns(101u, mappedDown));

    routed = -1;
    CHECK(router.Route(true, identity, &driftingRepeatMap,
                       LegacyPhysicalAction::Repeat, 0u, &routed) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(routed == 65);

    // The current mapper may lose the key before UP. The raw identity still
    // releases the immutable mapping captured by the accepted DOWN.
    routed = -1;
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up,
                       0u, &routed) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(routed == 65);
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(!ledger.owns(101u, mappedDown));

    CHECK(emitted.size() == 3u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 65, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Key, 65, 2));
    CHECK(IsEdge(emitted[2], OutputKind::Key, 65, 0));
}

void TestIdentityTupleAndAggregateEdges() {
    std::vector<EmittedEdge> emitted;
    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
    });
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);

    const Output key{OutputKind::Key, 70};
    const Output mouse{OutputKind::Mouse, 0};
    const LegacyPhysicalIdentity first{OutputKind::Key, 10u, 9u};
    const LegacyPhysicalIdentity differentDevice{OutputKind::Key, 11u, 9u};
    const LegacyPhysicalIdentity differentRaw{OutputKind::Key, 10u, 10u};
    const LegacyPhysicalIdentity differentKind{OutputKind::Mouse, 10u, 9u};
    const LegacyPhysicalIdentity ownerCollision{OutputKind::Key, 10u, 99u};

    CHECK(router.Route(true, first, &key, LegacyPhysicalAction::Down, 201u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.Route(true, differentDevice, &key,
                       LegacyPhysicalAction::Down, 202u) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(router.Route(true, differentRaw, &key,
                       LegacyPhysicalAction::Down, 203u) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(router.Route(true, differentKind, &mouse,
                       LegacyPhysicalAction::Down, 204u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.HeldIdentityCount() == 4u);

    int routed = 123;
    CHECK(router.Route(true, ownerCollision, &key,
                       LegacyPhysicalAction::Down, 201u, &routed) ==
          AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN);
    CHECK(routed == -1);
    CHECK(router.HeldIdentityCount() == 4u);

    const Output remapped{OutputKind::Key, 71};
    CHECK(router.Route(true, first, &remapped,
                       LegacyPhysicalAction::Down, 205u) ==
          AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN);
    CHECK(router.HeldIdentityCount() == 4u);

    CHECK(router.Route(true, first, nullptr, LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(router.Route(true, differentDevice, nullptr,
                       LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(router.Route(true, differentRaw, nullptr,
                       LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.Route(true, differentKind, nullptr,
                       LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);

    CHECK(emitted.size() == 4u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 70, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Mouse, 0, 1));
    CHECK(IsEdge(emitted[2], OutputKind::Key, 70, 0));
    CHECK(IsEdge(emitted[3], OutputKind::Mouse, 0, 0));
}

void TestRejectedOutcomesAndBridgeRecovery() {
    std::vector<EmittedEdge> emitted;
    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
    });
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);

    const LegacyPhysicalIdentity identity{OutputKind::Key, 1u, 30u};
    const Output key{OutputKind::Key, 88};
    const Output wrongKind{OutputKind::Mouse, 1};
    int routed = 123;

    CHECK(router.Route(false, identity, &key, LegacyPhysicalAction::Down,
                       301u, &routed) ==
          AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE);
    CHECK(routed == -1);
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Repeat,
                       0u) == AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_UP);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Down,
                       302u) == AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL);
    CHECK(router.Route(true, identity, &wrongKind, LegacyPhysicalAction::Down,
                       303u) == AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL);
    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down, 0u) ==
          AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL);
    CHECK(router.Route(true, identity, &key,
                       static_cast<LegacyPhysicalAction>(99), 304u) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);

    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       305u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    // A transient bridge failure must not discard the identity; a later UP can
    // still close the exact accepted DOWN.
    CHECK(router.Route(false, identity, nullptr, LegacyPhysicalAction::Up,
                       0u) == AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE);
    CHECK(router.HeldIdentityCount() == 1u);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(emitted.size() == 2u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 88, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Key, 88, 0));
}

void TestStaleLedgerStateRetiresIdentity() {
    std::vector<EmittedEdge> emitted;
    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
    });
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);

    const LegacyPhysicalIdentity identity{OutputKind::Key, 5u, 55u};
    const Output key{OutputKind::Key, 90};
    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       401u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    ledger.releaseOwner(401u);
    CHECK(router.HeldIdentityCount() == 1u);

    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Repeat,
                       0u) == AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT);
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       402u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    ledger.releaseOwner(402u);
    int routed = 123;
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up, 0u,
                       &routed) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_UP);
    CHECK(routed == -1);
    CHECK(router.HeldIdentityCount() == 0u);

    CHECK(emitted.size() == 4u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 90, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Key, 90, 0));
    CHECK(IsEdge(emitted[2], OutputKind::Key, 90, 1));
    CHECK(IsEdge(emitted[3], OutputKind::Key, 90, 0));
}

void TestRepeatEmitSynchronouslyRoutesUp() {
    std::vector<EmittedEdge> emitted;
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter* routerPtr = nullptr;
    bool reenterOnRepeat = false;
    AmclLegacyPhysicalOutcome reenteredUp =
        AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    const LegacyPhysicalIdentity identity{OutputKind::Key, 6u, 61u};
    const Output key{OutputKind::Key, 76};

    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
        if (action == 2 && reenterOnRepeat) {
            reenterOnRepeat = false;
            reenteredUp = routerPtr->Route(
                true, identity, nullptr, LegacyPhysicalAction::Up, 0u);
        }
    });
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);
    routerPtr = &router;

    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       451u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    reenterOnRepeat = true;
    int routed = -1;
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Repeat,
                       0u, &routed) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(routed == 76);
    CHECK(reenteredUp == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(!ledger.owns(451u, key));

    // The callback erased the iterator observed by the outer Repeat. A fresh
    // DOWN proves that Repeat used its pre-emit snapshot and left no ghost.
    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       452u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up,
                       0u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.HeldIdentityCount() == 0u);

    CHECK(emitted.size() == 5u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 76, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Key, 76, 2));
    CHECK(IsEdge(emitted[2], OutputKind::Key, 76, 0));
    CHECK(IsEdge(emitted[3], OutputKind::Key, 76, 1));
    CHECK(IsEdge(emitted[4], OutputKind::Key, 76, 0));
}

void TestRepeatEmitSynchronouslyResets() {
    std::vector<EmittedEdge> emitted;
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter* routerPtr = nullptr;
    bool resetOnRepeat = false;
    bool resetRan = false;
    const LegacyPhysicalIdentity identity{OutputKind::Key, 7u, 71u};
    const Output key{OutputKind::Key, 77};

    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
        if (action == 2 && resetOnRepeat) {
            resetOnRepeat = false;
            routerPtr->Reset([&]() {
                resetRan = true;
                CHECK(routerPtr->ResetInProgress());
            });
        }
    });
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);
    routerPtr = &router;

    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       461u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    resetOnRepeat = true;
    int routed = -1;
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Repeat,
                       0u, &routed) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(routed == 77);
    CHECK(resetRan);
    CHECK(!router.ResetInProgress());
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(!ledger.owns(461u, key));

    // Reset cleared the identity during the Repeat callback. The outer call
    // must not resurrect it, and the next physical lifecycle starts normally.
    CHECK(router.Route(true, identity, &key, LegacyPhysicalAction::Down,
                       462u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.Route(true, identity, nullptr, LegacyPhysicalAction::Up,
                       0u) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(router.HeldIdentityCount() == 0u);

    CHECK(emitted.size() == 5u);
    CHECK(IsEdge(emitted[0], OutputKind::Key, 77, 1));
    CHECK(IsEdge(emitted[1], OutputKind::Key, 77, 2));
    CHECK(IsEdge(emitted[2], OutputKind::Key, 77, 0));
    CHECK(IsEdge(emitted[3], OutputKind::Key, 77, 1));
    CHECK(IsEdge(emitted[4], OutputKind::Key, 77, 0));
}

void TestResetFenceRejectsSynchronousReentry() {
    std::vector<EmittedEdge> emitted;
    std::vector<AmclLegacyPhysicalOutcome> reentry;
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter* routerPtr = nullptr;
    bool probeReleaseCallback = false;
    const LegacyPhysicalIdentity heldIdentity{OutputKind::Key, 8u, 80u};
    const LegacyPhysicalIdentity newIdentity{OutputKind::Key, 8u, 81u};
    const Output heldKey{OutputKind::Key, 81};
    const Output newKey{OutputKind::Key, 82};

    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
        if (action == 0 && probeReleaseCallback) {
            CHECK(routerPtr->ResetInProgress());
            reentry.push_back(routerPtr->Route(
                true, heldIdentity, nullptr, LegacyPhysicalAction::Repeat, 0u));
            reentry.push_back(routerPtr->Route(
                true, heldIdentity, nullptr, LegacyPhysicalAction::Up, 0u));
            reentry.push_back(routerPtr->Route(
                true, newIdentity, &newKey, LegacyPhysicalAction::Down, 502u));
        }
    });
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);
    routerPtr = &router;

    CHECK(router.Route(true, heldIdentity, &heldKey,
                       LegacyPhysicalAction::Down, 501u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    probeReleaseCallback = true;
    bool resetWorkRan = false;
    router.Reset([&]() {
        resetWorkRan = true;
        CHECK(router.ResetInProgress());
        reentry.push_back(router.Route(
            false, newIdentity, &newKey, LegacyPhysicalAction::Down, 503u));
        // Nested lifecycle reset is idempotent and cannot shorten the outer
        // fence or release a newly re-entered edge.
        router.Reset();
    });
    probeReleaseCallback = false;

    CHECK(resetWorkRan);
    CHECK(!router.ResetInProgress());
    CHECK(reentry.size() == 4u);
    for (AmclLegacyPhysicalOutcome outcome : reentry) {
        CHECK(outcome == AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS);
    }
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(!ledger.owns(501u, heldKey));
    CHECK(router.Route(true, heldIdentity, nullptr,
                       LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_UP);
    CHECK(router.Route(true, newIdentity, &newKey,
                       LegacyPhysicalAction::Down, 504u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
}

void TestSchemaResetIsolationAndFullCancelFence() {
    std::vector<EmittedEdge> emitted;
    std::vector<AmclLegacyPhysicalOutcome> cancelReentry;
    std::recursive_mutex transactionMutex;
    LegacyPhysicalEdgeRouter* routerPtr = nullptr;
    bool probeFullCancelRelease = false;
    bool probed = false;
    const LegacyPhysicalIdentity physicalIdentity{
        OutputKind::Key, 9u, 900u};
    const LegacyPhysicalIdentity reenteredIdentity{
        OutputKind::Mouse, 9u, 901u};
    const Output sharedKey{OutputKind::Key, 65};
    const Output externalMouse{OutputKind::Mouse, 1};
    const Output reenteredMouse{OutputKind::Mouse, 2};
    constexpr uint64_t kPhysicalOwner = 601u;
    constexpr uint64_t kSchemaOwner = 602u;
    constexpr uint64_t kExternalOwner = 603u;

    InputLedger ledger([&](const Output& output, int action) {
        emitted.push_back({output, action});
        if (action == 0 && probeFullCancelRelease && !probed) {
            probed = true;
            CHECK(routerPtr->ResetInProgress());
            cancelReentry.push_back(routerPtr->Route(
                true, reenteredIdentity, &reenteredMouse,
                LegacyPhysicalAction::Down, 604u));
        }
    });
    LegacyPhysicalEdgeRouter router(ledger, transactionMutex);
    routerPtr = &router;

    CHECK(router.Route(true, physicalIdentity, &sharedKey,
                       LegacyPhysicalAction::Down, kPhysicalOwner) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(!ledger.acquire(kSchemaOwner, sharedKey));
    CHECK(ledger.acquire(kExternalOwner, externalMouse));

    // Schema replacement/grab cleanup releases only known schema owners. It
    // must preserve both the physical identity and unrelated external owner.
    ledger.releaseOwner(kSchemaOwner);
    CHECK(router.HeldIdentityCount() == 1u);
    CHECK(ledger.owns(kPhysicalOwner, sharedKey));
    CHECK(ledger.owns(kExternalOwner, externalMouse));
    CHECK(router.Route(true, physicalIdentity, nullptr,
                       LegacyPhysicalAction::Repeat, 0u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);

    // Re-add a schema owner so the full cancel exercises an aggregated physical
    // release followed by releaseAll. The router fence must cover both stages.
    CHECK(!ledger.acquire(kSchemaOwner, sharedKey));
    probeFullCancelRelease = true;
    router.Reset([&]() {
        ledger.releaseAll();
    });
    probeFullCancelRelease = false;

    CHECK(probed);
    CHECK(cancelReentry.size() == 1u);
    CHECK(cancelReentry[0] == AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS);
    CHECK(router.HeldIdentityCount() == 0u);
    CHECK(!ledger.owns(kPhysicalOwner, sharedKey));
    CHECK(!ledger.owns(kSchemaOwner, sharedKey));
    CHECK(!ledger.owns(kExternalOwner, externalMouse));
    CHECK(router.Route(true, physicalIdentity, nullptr,
                       LegacyPhysicalAction::Up, 0u) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_UP);
    CHECK(router.Route(true, reenteredIdentity, &reenteredMouse,
                       LegacyPhysicalAction::Down, 605u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
}

}  // namespace

int main() {
    TestDownRepeatUnknownMappingUpUsesCapturedOutput();
    TestIdentityTupleAndAggregateEdges();
    TestRejectedOutcomesAndBridgeRecovery();
    TestStaleLedgerStateRetiresIdentity();
    TestRepeatEmitSynchronouslyRoutesUp();
    TestRepeatEmitSynchronouslyResets();
    TestResetFenceRejectsSynchronousReentry();
    TestSchemaResetIsolationAndFullCancelFence();
    std::cout << "legacy physical edge router: PASS\n";
    return 0;
}

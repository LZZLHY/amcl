#include "input_reconciliation.h"
#include "surface_input_gate_state.h"

#include <cstdlib>
#include <iostream>

namespace {
using amcl::input::reconciliation::LegacyResult;
using amcl::input::reconciliation::Reconciler;

[[noreturn]] void ReconciliationFail(const char* expression, int line) {
    std::cerr << "RECONCILIATION FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define RCHECK(e) do { if (!(e)) ReconciliationFail(#e, __LINE__); } while (0)

uint64_t FailingSurfaceClear(void* context, uint64_t expectedGeneration) {
    auto* called = static_cast<bool*>(context);
    *called = true;
    RCHECK(expectedGeneration == 7u);
    return 0;
}

uint64_t FailingSurfaceUpdate(void* context, uint64_t expectedGeneration) {
    auto* called = static_cast<bool*>(context);
    *called = true;
    RCHECK(expectedGeneration == 7u);
    return 0;
}
}

void RunInputReconciliationTests() {
    // Surface identities are one-shot. Once a pair retires, a future callback
    // using the exact addresses cannot borrow a new publication generation.
    // Event timestamps must also be strictly after the generation's
    // publication boundary before the optional native-absolute route may
    // accept them; equality is ambiguous at coarse clock resolution.
    amcl::input::surface_gate::State timestampGate;
    void* componentA = reinterpret_cast<void*>(101);
    void* windowA = reinterpret_cast<void*>(102);
    void* componentB = reinterpret_cast<void*>(103);
    void* windowB = reinterpret_cast<void*>(104);
    RCHECK(amcl::input::surface_gate::CanActivate(
        timestampGate, componentA, windowA));
    RCHECK(amcl::input::surface_gate::Activate(
        timestampGate, componentA, windowA, 7u, 100u));
    RCHECK(amcl::input::surface_gate::AcceptComponentOnlyGeneration(
        timestampGate, 7u));
    RCHECK(!amcl::input::surface_gate::CanActivate(
        timestampGate, componentA, windowA));
    RCHECK(!amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 7u, 99));
    RCHECK(!amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 7u, 100));
    RCHECK(amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 7u, 101));
    RCHECK(!amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 8u, 100));
    RCHECK(amcl::input::surface_gate::CommitCurrentUpdate(
        timestampGate, componentA, windowA, 7u, 8u, 200u) == 8u);
    RCHECK(!amcl::input::surface_gate::AcceptComponentOnlyGeneration(
        timestampGate, 8u));
    RCHECK(!amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 8u, 199));
    RCHECK(!amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 8u, 200));
    RCHECK(amcl::input::surface_gate::AcceptEventTimestamp(
        timestampGate, 8u, 201));
    amcl::input::surface_gate::Invalidate(timestampGate);
    RCHECK(amcl::input::surface_gate::IsRetired(
        timestampGate, componentA, windowA));
    RCHECK(!amcl::input::surface_gate::CanActivate(
        timestampGate, componentA, windowA));
    RCHECK(amcl::input::surface_gate::CanActivate(
        timestampGate, componentB, windowB));
    RCHECK(amcl::input::surface_gate::Activate(
        timestampGate, componentB, windowB, 9u, 300u));
    RCHECK(amcl::input::surface_gate::AcceptComponentOnlyGeneration(
        timestampGate, 9u));
    RCHECK(amcl::input::surface_gate::Accept(
        timestampGate, componentA, windowA, true) == 0u);

    // Reusing a component with a different window is valid for callbacks that
    // carry both identities, but component-only hover/axis provenance remains
    // ambiguous and must not be re-authorized without a verified timestamp.
    amcl::input::surface_gate::Invalidate(timestampGate);
    void* windowC = reinterpret_cast<void*>(105);
    RCHECK(amcl::input::surface_gate::Activate(
        timestampGate, componentB, windowC, 10u, 400u));
    RCHECK(!amcl::input::surface_gate::AcceptComponentOnlyGeneration(
        timestampGate, 10u));

    // Tombstones are bounded. Exhaustion disables all future activations
    // instead of allowing memory growth or evicting an identity that could
    // later be reused by a stale callback.
    amcl::input::surface_gate::State boundedGate;
    // 2026-09-01：`RetiredCapacityRemaining` 是这个"永久死亡"状态**唯一**的可观测量
    // （在它之前池耗尽既无计数也无日志，用户只会看到输入突然全部失灵）。
    // 在这个已经存在的耗尽场景上验证它，而不是另造一个样本 —— AGENTS.md §二.8：
    // 判定某样东西在不在的工具，本身要先在一个已知含有它的样本上验证过。
    RCHECK(amcl::input::surface_gate::RetiredCapacityRemaining(boundedGate) ==
           amcl::input::surface_gate::State::kRetiredIdentityCapacity);
    for (std::size_t i = 0u;
         i < amcl::input::surface_gate::State::kRetiredIdentityCapacity;
         ++i) {
        void* component = reinterpret_cast<void*>(1000u + i * 2u);
        void* window = reinterpret_cast<void*>(1001u + i * 2u);
        RCHECK(amcl::input::surface_gate::Activate(
            boundedGate, component, window,
            static_cast<uint64_t>(i + 1u),
            static_cast<uint64_t>(i + 1u)));
        amcl::input::surface_gate::Invalidate(boundedGate);
        // 每次身份更替恰好消耗一个墓碑 —— 这条让"256 次更替就会死"这个可达性判断
        // 变成可验证的，而不是靠读代码推断。
        RCHECK(amcl::input::surface_gate::RetiredCapacityRemaining(
                   boundedGate) ==
               amcl::input::surface_gate::State::kRetiredIdentityCapacity -
                   (i + 1u));
    }
    // ⭐ 因果闭环：剩余为 0 与"任何身份都激活不了"必须同时成立。
    // 产品侧的 error 日志判据（`noteSurfaceGateRetiredCapacityLocked`）就建立在这一条上。
    RCHECK(amcl::input::surface_gate::RetiredCapacityRemaining(boundedGate) ==
           0u);
    RCHECK(!amcl::input::surface_gate::CanActivate(
        boundedGate, reinterpret_cast<void*>(9001),
        reinterpret_cast<void*>(9002)));

    // A matching destroy invalidates the full identity before publication
    // mutation. Even when the real mutation returns zero, callbacks cannot
    // re-enter through the old component/window pair. A stale identity never
    // invokes the mutation and leaves the current gate untouched.
    amcl::input::surface_gate::State surfaceGate{
        reinterpret_cast<void*>(1), reinterpret_cast<void*>(2), 7u, true};
    bool clearCalled = false;
    RCHECK(amcl::input::surface_gate::ClearCurrent(
               surfaceGate, reinterpret_cast<void*>(1),
               reinterpret_cast<void*>(2), FailingSurfaceClear,
               &clearCalled) == 0u);
    RCHECK(clearCalled);
    RCHECK(amcl::input::surface_gate::Accept(
               surfaceGate, reinterpret_cast<void*>(1),
               reinterpret_cast<void*>(2), true) == 0u);
    RCHECK(surfaceGate.component == nullptr);
    RCHECK(surfaceGate.window == nullptr);
    RCHECK(surfaceGate.publicationGeneration == 0u);
    RCHECK(!surfaceGate.active);

    surfaceGate = {reinterpret_cast<void*>(3), reinterpret_cast<void*>(4),
                   7u, true};
    clearCalled = false;
    RCHECK(amcl::input::surface_gate::ClearCurrent(
               surfaceGate, reinterpret_cast<void*>(1),
               reinterpret_cast<void*>(2), FailingSurfaceClear,
               &clearCalled) == 0u);
    RCHECK(!clearCalled);
    RCHECK(amcl::input::surface_gate::Accept(
               surfaceGate, reinterpret_cast<void*>(3),
               reinterpret_cast<void*>(4), true) == 7u);

    // A conditional update failure preserves the current identity only until
    // the already-accepted OS SurfaceChanged handler performs its mandatory
    // fail-closed clear. Even a failing cleanup mutation leaves no live gate.
    bool updateCalled = false;
    RCHECK(amcl::input::surface_gate::UpdateCurrent(
               surfaceGate, reinterpret_cast<void*>(3),
               reinterpret_cast<void*>(4), FailingSurfaceUpdate,
               &updateCalled, 123u) == 0u);
    RCHECK(updateCalled);
    RCHECK(amcl::input::surface_gate::Accept(
               surfaceGate, reinterpret_cast<void*>(3),
               reinterpret_cast<void*>(4), true) == 7u);
    clearCalled = false;
    RCHECK(amcl::input::surface_gate::ClearCurrent(
               surfaceGate, reinterpret_cast<void*>(3),
               reinterpret_cast<void*>(4), FailingSurfaceClear,
               &clearCalled) == 0u);
    RCHECK(clearCalled);
    RCHECK(amcl::input::surface_gate::Accept(
               surfaceGate, reinterpret_cast<void*>(3),
               reinterpret_cast<void*>(4), true) == 0u);

    // A replacement/create failure has no trustworthy incoming identity to
    // match. ClearActive is restricted to that lifecycle lock and must still
    // retire the previous gate before a fallible broker cleanup.
    surfaceGate = {reinterpret_cast<void*>(5), reinterpret_cast<void*>(6),
                   7u, true};
    clearCalled = false;
    uint64_t expectedGeneration = 99u;
    RCHECK(amcl::input::surface_gate::ClearActive(
               surfaceGate, FailingSurfaceClear, &clearCalled,
               &expectedGeneration) == 0u);
    RCHECK(clearCalled);
    RCHECK(expectedGeneration == 7u);
    RCHECK(amcl::input::surface_gate::Accept(
               surfaceGate, reinterpret_cast<void*>(5),
               reinterpret_cast<void*>(6), true) == 0u);

    Reconciler state(8);
    state.BeginSession();

    const uint64_t down = state.BeginKey(1, 10, 1, 65, true);
    RCHECK(state.Finalize(down, LegacyResult::Exact, 1));
    const uint64_t repeat = state.BeginKey(1, 10, 2, 65, true);
    RCHECK(state.Finalize(repeat, LegacyResult::Exact, 1));
    auto summary = state.Snapshot();
    RCHECK(summary.typedHeldKeys == 1);
    RCHECK(summary.legacyHeldKeys == 1);
    RCHECK(summary.mappedKeySymmetricDifference == 0);
    RCHECK(summary.unexpectedMismatch == 0);

    // The legacy physical router keys held state by raw identity and returns
    // the immutable DOWN mapping on UP. A mapper that disappears or drifts in
    // between must therefore release that captured mapping, not retain a ghost
    // in reconciliation or release the newly reported key.
    Reconciler routedMapping(8);
    const uint64_t capturedDown = routedMapping.BeginKey(4, 40, 1, 65, true);
    RCHECK(routedMapping.Finalize(capturedDown, LegacyResult::Exact, 1));
    const uint64_t mappingMissingUp =
        routedMapping.BeginKey(4, 40, 3, -1, true);
    RCHECK(routedMapping.Finalize(
        mappingMissingUp, LegacyResult::Exact, 0, 0, 65));
    summary = routedMapping.Snapshot();
    RCHECK(summary.typedHeldKeys == 0);
    RCHECK(summary.legacyHeldKeys == 0);
    RCHECK(summary.mappedKeySymmetricDifference == 0);

    const uint64_t driftDown = routedMapping.BeginKey(5, 41, 1, 70, true);
    RCHECK(routedMapping.Finalize(driftDown, LegacyResult::Exact, 1));
    const uint64_t mappingDriftUp =
        routedMapping.BeginKey(5, 41, 3, 71, true);
    RCHECK(routedMapping.Finalize(
        mappingDriftUp, LegacyResult::Exact, 0, 0, 70));
    summary = routedMapping.Snapshot();
    RCHECK(summary.typedHeldKeys == 0);
    RCHECK(summary.legacyHeldKeys == 0);
    RCHECK(summary.mappedKeySymmetricDifference == 0);

    const uint64_t unknownDown = state.BeginKey(1, 99, 1, -1, true);
    RCHECK(state.Finalize(unknownDown, LegacyResult::Unmapped));
    const uint64_t unknownUp = state.BeginKey(1, 99, 3, -1, true);
    RCHECK(state.Finalize(unknownUp, LegacyResult::Unmapped));
    const uint64_t wheel = state.BeginWheel(true);
    RCHECK(state.Finalize(wheel, LegacyResult::Quantized, -1, 0));
    summary = state.Snapshot();
    RCHECK(summary.unmapped == 2);
    RCHECK(summary.quantized == 1);

    const uint64_t first = state.BeginRelative(true);
    const uint64_t second = state.BeginRelative(true);
    RCHECK(state.Finalize(second, LegacyResult::Exact));
    RCHECK(state.Finalize(first, LegacyResult::Exact));
    RCHECK(!state.Finalize(first, LegacyResult::Exact));
    RCHECK(!state.Finalize(777, LegacyResult::Exact));
    RCHECK(!state.Finalize(0, LegacyResult::Exact));
    summary = state.Snapshot();
    RCHECK(summary.orderMismatch == 1);
    RCHECK(summary.duplicateFinalize == 1);
    RCHECK(summary.unknownFinalize == 2);

    Reconciler pendingCapacity(2);
    const uint64_t pending1 = pendingCapacity.BeginRelative(true);
    const uint64_t pending2 = pendingCapacity.BeginRelative(true);
    RCHECK(pending1 != 0 && pending2 != 0);
    RCHECK(pendingCapacity.BeginKey(9, 90, 1, 90, true) == 0);
    summary = pendingCapacity.Snapshot();
    RCHECK(summary.begun == 2);
    RCHECK(summary.droppedBegin == 1);
    RCHECK(summary.unresolved == 2);
    RCHECK(summary.typedHeldKeys == 0);
    RCHECK(pendingCapacity.Finalize(pending1, LegacyResult::Exact));
    RCHECK(pendingCapacity.Finalize(pending2, LegacyResult::Exact));

    Reconciler heldCapacity(1);
    const uint64_t held = heldCapacity.BeginKey(1, 1, 1, 65, true);
    RCHECK(heldCapacity.Finalize(held, LegacyResult::Exact, 1));
    RCHECK(heldCapacity.BeginKey(2, 2, 1, 66, true) == 0);
    summary = heldCapacity.Snapshot();
    RCHECK(summary.droppedBegin == 1);
    RCHECK(summary.typedHeldKeys == 1);
    RCHECK(summary.legacyHeldKeys == 1);

    Reconciler exhausted(2);
    exhausted.TestSetNextOrdinal(UINT64_MAX - 1);
    const uint64_t finalOrdinal = exhausted.BeginRelative(true);
    RCHECK(finalOrdinal == UINT64_MAX);
    RCHECK(exhausted.BeginKey(4, 40, 1, 80, true) == 0);
    summary = exhausted.Snapshot();
    RCHECK(summary.begun == 1);
    RCHECK(summary.droppedBegin == 1);
    RCHECK(summary.unresolved == 1);
    RCHECK(summary.typedHeldKeys == 0);
    RCHECK(exhausted.Finalize(finalOrdinal, LegacyResult::Exact));
    exhausted.BeginSession();
    // Exhaustion is process-wide and fail-closed; starting a new session must
    // never recycle an identity that an old asynchronous route may still hold.
    RCHECK(exhausted.BeginRelative(true) == 0);

    Reconciler sessionTokens(4);
    const uint64_t oldSessionToken = sessionTokens.BeginRelative(true);
    RCHECK(oldSessionToken != 0);
    sessionTokens.BeginSession();
    const uint64_t newSessionToken = sessionTokens.BeginRelative(true);
    RCHECK(newSessionToken != 0);
    RCHECK(newSessionToken != oldSessionToken);
    RCHECK(!sessionTokens.Finalize(oldSessionToken, LegacyResult::Exact));
    RCHECK(sessionTokens.Snapshot().unresolved == 1);
    RCHECK(sessionTokens.Finalize(newSessionToken, LegacyResult::Exact));
    RCHECK(sessionTokens.Snapshot().unresolved == 0);

    Reconciler identities(8);
    const uint64_t device1 = identities.BeginKey(10, 7, 1, 65, true);
    const uint64_t device2 = identities.BeginKey(11, 7, 1, 65, true);
    RCHECK(identities.Finalize(device1, LegacyResult::Exact, 1));
    RCHECK(identities.Finalize(device2, LegacyResult::Exact, 1));
    summary = identities.Snapshot();
    RCHECK(summary.typedHeldKeys == 2);
    RCHECK(summary.legacyHeldKeys == 1);
    RCHECK(summary.mappedKeySymmetricDifference == 0);

    const uint64_t releaseDevice1 = identities.BeginKey(10, 7, 3, 65, true);
    RCHECK(identities.Finalize(releaseDevice1, LegacyResult::Exact, 0));
    summary = identities.Snapshot();
    RCHECK(summary.typedHeldKeys == 1);
    RCHECK(summary.legacyHeldKeys == 0);
    RCHECK(summary.mappedKeySymmetricDifference == 1);

    const uint64_t secondRaw = identities.BeginKey(11, 8, 1, 65, true);
    RCHECK(identities.Finalize(secondRaw, LegacyResult::Exact, 1));
    const uint64_t releaseFirstRaw = identities.BeginKey(11, 7, 3, 65, true);
    RCHECK(identities.Finalize(releaseFirstRaw, LegacyResult::Exact, 0));
    summary = identities.Snapshot();
    RCHECK(summary.typedHeldKeys == 1);
    RCHECK(summary.legacyHeldKeys == 0);
    RCHECK(summary.mappedKeySymmetricDifference == 1);

    Reconciler mappedAggregation(8);
    const uint64_t mappedExact = mappedAggregation.BeginKey(1, 10, 1, 65, true);
    const uint64_t mappedTypedOnly = mappedAggregation.BeginKey(2, 11, 1, 65, true);
    RCHECK(mappedAggregation.Finalize(mappedExact, LegacyResult::Exact, 1));
    RCHECK(mappedAggregation.Finalize(mappedTypedOnly,
                                      LegacyResult::BridgeUnavailable));
    // Two physical contributors collapse to one mapped held control. Even
    // though one legacy route failed, both sides still hold mapped key 65.
    RCHECK(mappedAggregation.Snapshot().mappedKeySymmetricDifference == 0);

    const uint64_t button1 = identities.BeginButton(20, 1, 1, 0, true);
    const uint64_t button2 = identities.BeginButton(21, 1, 1, 0, true);
    RCHECK(identities.Finalize(button1, LegacyResult::Exact, 1));
    RCHECK(identities.Finalize(button2, LegacyResult::Exact, 1));
    summary = identities.Snapshot();
    RCHECK(summary.typedHeldButtons == 2);
    RCHECK(summary.legacyHeldButtons == 1);
    RCHECK(summary.mappedButtonSymmetricDifference == 0);
    const uint64_t releaseButton1 = identities.BeginButton(20, 1, 3, 0, true);
    RCHECK(identities.Finalize(releaseButton1, LegacyResult::Exact, 0));
    summary = identities.Snapshot();
    RCHECK(summary.typedHeldButtons == 1);
    RCHECK(summary.legacyHeldButtons == 0);
    RCHECK(summary.mappedButtonSymmetricDifference == 1);

    Reconciler finalDifference(8);
    const uint64_t typedOnly = finalDifference.BeginKey(1, 20, 1, 70, true);
    RCHECK(finalDifference.Finalize(typedOnly, LegacyResult::Unmapped));
    const uint64_t legacyOnly = finalDifference.BeginButton(2, 1, 1, 0, false);
    RCHECK(finalDifference.Finalize(legacyOnly, LegacyResult::Exact, 1));
    const uint64_t pending = finalDifference.BeginRelative(true);
    RCHECK(pending != 0);
    summary = finalDifference.Snapshot();
    RCHECK(summary.mappedKeySymmetricDifference == 1);
    // typedAccepted=false means the ordinary event was rejected at a reset or
    // stale boundary. Count the successful legacy route as divergence without
    // letting it rebuild post-reset reconciliation held state.
    RCHECK(summary.legacyHeldButtons == 0);
    RCHECK(summary.mappedButtonSymmetricDifference == 0);
    RCHECK(summary.unexpectedMismatch == 1);
    RCHECK(summary.unresolved == 1);

    finalDifference.ResetHeld();
    summary = finalDifference.Snapshot();
    RCHECK(summary.unresolved == 1);
    RCHECK(summary.typedHeldKeys == 0);
    RCHECK(summary.legacyHeldKeys == 0);
    RCHECK(summary.typedHeldButtons == 0);
    RCHECK(summary.legacyHeldButtons == 0);
    RCHECK(summary.mappedKeySymmetricDifference == 0);
    RCHECK(summary.mappedButtonSymmetricDifference == 0);

    finalDifference.BeginSession();
    summary = finalDifference.Snapshot();
    RCHECK(summary.begun == 0);
    RCHECK(summary.droppedBegin == 0);
    RCHECK(summary.unresolved == 0);
    RCHECK(summary.unknownFinalize == 0);
}

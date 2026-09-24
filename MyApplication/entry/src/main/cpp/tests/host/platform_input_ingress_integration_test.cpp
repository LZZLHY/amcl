#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {
const AmclInputHostApiV1* gApi = nullptr;
uint32_t gFallbackEnqueueCalls = 0;
uint32_t gPhysicalEnqueueCalls = 0;
uint32_t gKeyRouteCalls = 0;
uint32_t gButtonRouteCalls = 0;
uint32_t gWheelRouteCalls = 0;
bool gKeyHeld = false;
bool gButtonHeld = false;
uint64_t gHeldKeyDevice = 0;
uint64_t gHeldButtonDevice = 0;
uint32_t gHeldRawKey = 0;
uint32_t gHeldRawButton = 0;
int32_t gCapturedKey = -1;
int32_t gCapturedButton = -1;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

bool AcceptRelativeFallback(double dx, double dy) {
    CHECK(dx == 6.0);
    CHECK(dy == -7.0);
    ++gFallbackEnqueueCalls;
    return true;
}

AmclLegacyPhysicalOutcome AcceptPhysicalRelative(double dx, double dy) {
    CHECK(dx == 2.0);
    CHECK(dy == -3.0);
    ++gPhysicalEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome RouteKey(
        uint64_t deviceId, uint32_t rawKey, int32_t mappedKey,
        int32_t, int32_t action, int32_t, int32_t* routedMappedKey) {
    ++gKeyRouteCalls;
    if (routedMappedKey) *routedMappedKey = -1;
    if (action == 1) {
        if (gKeyHeld) return AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN;
        if (mappedKey < 0) return AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL;
        gKeyHeld = true;
        gHeldKeyDevice = deviceId;
        gHeldRawKey = rawKey;
        gCapturedKey = mappedKey;
        if (routedMappedKey) *routedMappedKey = gCapturedKey;
        return AMCL_LEGACY_PHYSICAL_EMITTED;
    }
    if (action == 2) {
        if (!gKeyHeld || gHeldKeyDevice != deviceId ||
            gHeldRawKey != rawKey) {
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT;
        }
        if (routedMappedKey) *routedMappedKey = gCapturedKey;
        return AMCL_LEGACY_PHYSICAL_EMITTED;
    }
    if (action == 0) {
        if (!gKeyHeld || gHeldKeyDevice != deviceId ||
            gHeldRawKey != rawKey) {
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_UP;
        }
        if (routedMappedKey) *routedMappedKey = gCapturedKey;
        gKeyHeld = false;
        gCapturedKey = -1;
        return AMCL_LEGACY_PHYSICAL_EMITTED;
    }
    return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
}

AmclLegacyPhysicalOutcome RouteButton(
        uint64_t deviceId, uint32_t rawButton, int32_t mappedButton,
        int32_t action, int32_t* routedMappedButton) {
    ++gButtonRouteCalls;
    if (routedMappedButton) *routedMappedButton = -1;
    if (action == 1) {
        if (gButtonHeld) return AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN;
        if (mappedButton < 0) return AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL;
        gButtonHeld = true;
        gHeldButtonDevice = deviceId;
        gHeldRawButton = rawButton;
        gCapturedButton = mappedButton;
        if (routedMappedButton) *routedMappedButton = gCapturedButton;
        return AMCL_LEGACY_PHYSICAL_EMITTED;
    }
    if (action == 0) {
        if (!gButtonHeld || gHeldButtonDevice != deviceId ||
            gHeldRawButton != rawButton) {
            return AMCL_LEGACY_PHYSICAL_OWNERLESS_UP;
        }
        if (routedMappedButton) *routedMappedButton = gCapturedButton;
        gButtonHeld = false;
        gCapturedButton = -1;
        return AMCL_LEGACY_PHYSICAL_EMITTED;
    }
    return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
}

AmclLegacyPhysicalOutcome RouteWheel(
        double x, double y, uint32_t* routedDetentCount) {
    CHECK(x == 0.0);
    ++gWheelRouteCalls;
    if (routedDetentCount) *routedDetentCount = 0u;
    if (y < 8.0) return AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    if (routedDetentCount) *routedDetentCount = 1u;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

void ClearShadowOverride() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "") == 0);
#else
    CHECK(unsetenv("AMCL_INPUT_SHADOW") == 0);
    CHECK(unsetenv("AMCL_GLFW_INPUT_BACKEND") == 0);
#endif
}

AmclInputSnapshotV1 Snapshot() {
    AmclInputSnapshotV1 value{};
    value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    value.structSize = static_cast<uint16_t>(sizeof(value));
    CHECK(gApi->getSnapshot(&value) == AMCL_INPUT_OK);
    return value;
}

std::vector<AmclInputEvent> Drain(AmclInputConsumerHandle consumer) {
    std::vector<AmclInputEvent> events;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = gApi->nextEvent(consumer, &event);
        if (result == AMCL_INPUT_EMPTY) return events;
        CHECK(result == AMCL_INPUT_OK);
        events.push_back(event);
    }
}

bool HasKey(const std::vector<AmclInputEvent>& events, uint32_t key,
            uint32_t action) {
    for (const auto& event : events) {
        if (event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY &&
            event.payload.physicalKey.physicalKey == key &&
            event.payload.physicalKey.action == action) return true;
    }
    return false;
}

bool HasInactiveSurface(const std::vector<AmclInputEvent>& events) {
    for (const auto& event : events) {
        if (event.header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED &&
            event.payload.surface.active == 0u) return true;
    }
    return false;
}

std::vector<AmclInputEvent> DrainUntilBoundary(
        AmclInputConsumerHandle consumer) {
    std::vector<AmclInputEvent> events;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = gApi->nextEvent(consumer, &event);
        if (result == AMCL_INPUT_EMPTY || result == AMCL_INPUT_ERROR_STALE) {
            return events;
        }
        CHECK(result == AMCL_INPUT_OK);
        events.push_back(event);
    }
}

void EndCurrentHostSessionDuringRecovery() {
    const auto snapshot = Snapshot();
    CHECK(snapshot.sessionActive != 0u);
    CHECK(gApi->endSession(snapshot.sessionEpoch) == AMCL_INPUT_OK);
}
}  // namespace

int main() {
    ClearShadowOverride();
    CHECK(amcl::input::PlatformInputShadowEnabled());
    gApi = amclInputGetHostApiV1();

    amcl::input::PlatformInputSurfaceCreated(800u, 600u);
    const auto initial = Snapshot();
    CHECK(initial.sessionActive != 0u);
    CHECK(initial.consumerCount == 1u);
    CHECK(initial.heldControlCount == 0u);
    AmclInputConsumerHandle pointerObserver = 0u;
    CHECK(gApi->openConsumer(&pointerObserver) == AMCL_INPUT_OK);
    CHECK(Drain(pointerObserver).size() == 2u);  // baseline + current surface
    const amcl::input::PlatformInputPointerIdentity mouseIdentity{
        501u, AMCL_INPUT_DEVICE_CLASS_MOUSE, 1u};
    const amcl::input::PlatformInputPointerIdentity touchpadIdentity{
        502u, AMCL_INPUT_DEVICE_CLASS_TOUCHPAD, 2u};
    std::vector<AmclInputEvent> pointerEvents;
    const auto drainPointerObserver = [&]() {
        const auto batch = Drain(pointerObserver);
        pointerEvents.insert(pointerEvents.end(), batch.begin(), batch.end());
    };

    // Shadow legacy routing uses the same shipping transaction seam as NAPI.
    // Selection alone is insufficient evidence: the checked enqueue completion
    // must be counted independently while the callback runs exactly once.
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              6.0, -7.0, true, AcceptRelativeFallback) ==
          amcl::input::PlatformInputRelativeFallbackResult::Enqueued);
    CHECK(gFallbackEnqueueCalls == 1u);
    auto fallback = amcl::input::trace::TestRelativeFallbackSnapshot();
    CHECK(fallback.selected == 1u);
    CHECK(fallback.enqueued == 1u);
    CHECK(fallback.enqueueFailed == 0u);
    CHECK(fallback.zeroDelta == 0u);
    CHECK(fallback.typedRouteRejected == 0u);
    CHECK(fallback.gateRejected == 0u);
    CHECK(amcl::input::trace::TestReconciliationSnapshot().legacyFallback == 1u);

    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              std::numeric_limits<double>::quiet_NaN(), 1.0, true,
              AcceptPhysicalRelative, mouseIdentity) ==
          AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
    CHECK(gPhysicalEnqueueCalls == 0u);
    auto relativeReconciliation =
        amcl::input::trace::TestReconciliationSnapshot();
    CHECK(relativeReconciliation.invalidInput == 1u);
    CHECK(relativeReconciliation.unresolved == 0u);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              2.0, -3.0, true, AcceptPhysicalRelative, mouseIdentity) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(gPhysicalEnqueueCalls == 1u);
    relativeReconciliation =
        amcl::input::trace::TestReconciliationSnapshot();
    CHECK(relativeReconciliation.exact == 1u);
    CHECK(relativeReconciliation.invalidInput == 1u);
    CHECK(relativeReconciliation.unresolved == 0u);
    drainPointerObserver();

    // The transaction owns one operational outcome independently of shadow.
    // Unknown/drifted UP still reaches the raw-identity helper and finalizes
    // against the immutable DOWN mapping returned through routedMappedKey.
    using amcl::input::trace::PhysicalIngressKind;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              70u, 170u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 17u,
              65, 1, true, RouteKey) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              70u, 170u, 0u, AMCL_INPUT_ACTION_UP, 0u, 0u, 17u,
              0, 0, true, RouteKey) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(!gKeyHeld);
    CHECK(gKeyRouteCalls == 2u);
    CHECK(amcl::input::trace::TestPhysicalMappingUnavailableCount(
              PhysicalIngressKind::Key) == 1u);
    auto routedReconciliation =
        amcl::input::trace::TestReconciliationSnapshot();
    CHECK(routedReconciliation.typedHeldKeys == 0u);
    CHECK(routedReconciliation.legacyHeldKeys == 0u);
    CHECK(routedReconciliation.mappedKeySymmetricDifference == 0u);

    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              71u, 171u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 18u,
              66, 1, true, RouteKey) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              71u, 171u, 0u, AMCL_INPUT_ACTION_UP, 0u, 0u, 18u,
              67, 0, true, RouteKey) == AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(!gKeyHeld);
    routedReconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(routedReconciliation.typedHeldKeys == 0u);
    CHECK(routedReconciliation.legacyHeldKeys == 0u);
    CHECK(routedReconciliation.mappedKeySymmetricDifference == 0u);

    const uint32_t beforeRejectedRoutes = gKeyRouteCalls;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              72u, 172u, 0u, AMCL_INPUT_ACTION_REPEAT, 0u, 0u, 19u,
              68, 2, true, RouteKey) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              73u, 173u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 20u,
              69, 0, true, RouteKey) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              74u, 174u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 21u,
              70, 1, false, RouteKey) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gKeyRouteCalls == beforeRejectedRoutes + 1u);
    // This test core has an intentionally tiny queue. Do not let unrelated key
    // coverage overflow and erase the pointer identity records under test.
    drainPointerObserver();

    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              22u, 1u, AMCL_INPUT_ACTION_DOWN, 0, 1, true,
              RouteButton, AMCL_INPUT_DEVICE_CLASS_TOUCHPAD, 3u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              22u, 1u, AMCL_INPUT_ACTION_UP, -1, 0, true,
              RouteButton, AMCL_INPUT_DEVICE_CLASS_UNKNOWN, 4u) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(!gButtonHeld);
    CHECK(gButtonRouteCalls == 2u);
    CHECK(amcl::input::trace::TestPhysicalMappingUnavailableCount(
              PhysicalIngressKind::Button) == 1u);
    routedReconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(routedReconciliation.typedHeldButtons == 0u);
    CHECK(routedReconciliation.legacyHeldButtons == 0u);
    CHECK(routedReconciliation.mappedButtonSymmetricDifference == 0u);
    drainPointerObserver();

    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 4.0, true, true, RouteWheel, touchpadIdentity) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 9.0, true, true, RouteWheel, touchpadIdentity) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(gWheelRouteCalls == 2u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_EMITTED) == 1u);

    drainPointerObserver();
    bool sawMouseRelative = false;
    bool sawTouchpadDown = false;
    bool sawTouchpadUp = false;
    bool sawTouchpadWheel = false;
    for (const auto& event : pointerEvents) {
        if (event.header.eventType == AMCL_INPUT_EVENT_POINTER_RELATIVE &&
            event.header.deviceId == mouseIdentity.deviceId &&
            event.header.deviceClass == AMCL_INPUT_DEVICE_CLASS_MOUSE) {
            sawMouseRelative = true;
            CHECK((event.header.flags &
                   AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u);
        }
        if (event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON &&
            event.header.deviceId == 22u &&
            event.header.deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD) {
            sawTouchpadDown |= event.payload.pointerButton.action ==
                AMCL_INPUT_ACTION_DOWN;
            sawTouchpadUp |= event.payload.pointerButton.action ==
                AMCL_INPUT_ACTION_UP;
        }
        if (event.header.eventType == AMCL_INPUT_EVENT_POINTER_WHEEL &&
            event.header.deviceId == touchpadIdentity.deviceId &&
            event.header.deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD) {
            sawTouchpadWheel = true;
        }
    }
    if (!sawMouseRelative || !sawTouchpadDown || !sawTouchpadUp ||
        !sawTouchpadWheel) {
        for (const auto& event : pointerEvents) {
            std::cerr << "pointer event type=" << event.header.eventType
                      << " device=" << event.header.deviceId
                      << " class=" << event.header.deviceClass
                      << " flags=" << event.header.flags << '\n';
        }
    }
    CHECK(sawMouseRelative);
    CHECK(sawTouchpadDown);
    CHECK(sawTouchpadUp);
    CHECK(sawTouchpadWheel);
    CHECK(gApi->closeConsumer(pointerObserver) == AMCL_INPUT_OK);

    AmclInputConsumerHandle oldObserver = 0;
    CHECK(gApi->openConsumer(&oldObserver) == AMCL_INPUT_OK);
    const auto oldBaseline = Drain(oldObserver);
    CHECK(oldBaseline.size() == 2u);
    CHECK(oldBaseline[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(oldBaseline[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);

    // Seed finalized reconciliation state before rolling the real host. The
    // fresh-consumer baseline below must clear both typed and legacy held state.
    const uint64_t preRollover = amcl::input::PlatformInputPhysicalKey(
        40u, 140u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 7u, 40);
    amcl::input::trace::FinalizeObservation(
        preRollover, amcl::input::trace::LegacyResult::Exact, 1);
    auto reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 1u);
    CHECK(reconciliation.legacyHeldKeys == 1u);
    CHECK(HasKey(Drain(oldObserver), 40u, AMCL_INPUT_ACTION_DOWN));

    // Roll the real host behind ingress. Its cached epoch and shadow consumer
    // are now stale, exactly as they can become across an external lifecycle.
    uint64_t rolloverEpoch = 0;
    CHECK(gApi->beginSession(&rolloverEpoch) == AMCL_INPUT_OK);
    CHECK(rolloverEpoch != initial.sessionEpoch);

    AmclInputConsumerHandle observer = 0;
    CHECK(gApi->openConsumer(&observer) == AMCL_INPUT_OK);
    const auto baseline = Drain(observer);
    // beginSession is an authoritative surface boundary. The previous native
    // publication must not be replayed into the new epoch until a fresh
    // lifecycle callback binds its publicationGeneration again.
    CHECK(baseline.size() == 1u);
    CHECK(baseline[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);

    // This event carries the old ingress epoch. Recovery must replace and
    // baseline the shadow consumer, but must never replay this failed event.
    //
    // Recovery is a reset boundary for the frontend too. Its baseline drain is
    // required to observe RESET (recovery fails closed otherwise), so the
    // process-lifetime epoch that ArkTS reconciles against must advance exactly
    // as it does for the focus and overflow boundaries asserted further down.
    // Until 2026-08-21 it did not: recovery drains the fresh consumer directly
    // instead of through RecordAndDrainLocked, and only half of that helper's
    // ResetReconciliation/AdvanceFrontendResetEpoch pair had been written out by
    // hand. Neither this boundary nor the fail-closed one below asserted the
    // epoch, which is why the omission survived.
    const uint64_t beforeRecoveryEpoch = amcl::input::PlatformInputResetEpoch();
    const auto beforeRecoveryCounters =
        amcl::input::trace::TestEpochRecoverySnapshot();
    const uint64_t stale = amcl::input::PlatformInputPhysicalKey(
        41u, 141u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 7u, 41);
    amcl::input::trace::FinalizeObservation(
        stale, amcl::input::trace::LegacyResult::BridgeUnavailable);
    const auto recovered = Snapshot();
    CHECK(recovered.sessionActive != 0u);
    CHECK(recovered.sessionEpoch == rolloverEpoch);
    CHECK(recovered.heldControlCount == 0u);
    CHECK(Drain(observer).empty());
    CHECK(amcl::input::PlatformInputResetEpoch() > beforeRecoveryEpoch);
    // Recovery had no observable counter at all before this; `errors`/`stale`
    // cannot answer "did recovery run", because recovery's own host calls land
    // in the same bucket as the failure that triggered it.
    const auto afterRecoveryCounters =
        amcl::input::trace::TestEpochRecoverySnapshot();
    CHECK(afterRecoveryCounters.recovered ==
          beforeRecoveryCounters.recovered + 1u);
    CHECK(afterRecoveryCounters.failedClosed ==
          beforeRecoveryCounters.failedClosed);
    reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 0u);
    CHECK(reconciliation.legacyHeldKeys == 0u);
    CHECK(gApi->closeConsumer(oldObserver) == AMCL_INPUT_OK);

    const uint64_t accepted = amcl::input::PlatformInputPhysicalKey(
        42u, 142u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 7u, 42);
    amcl::input::trace::FinalizeObservation(
        accepted, amcl::input::trace::LegacyResult::Exact, 1);
    CHECK(Snapshot().heldControlCount == 1u);
    const auto next = Drain(observer);
    CHECK(next.size() == 1u);
    CHECK(!HasKey(next, 41u, AMCL_INPUT_ACTION_DOWN));
    CHECK(HasKey(next, 42u, AMCL_INPUT_ACTION_DOWN));

    const uint64_t beforeFocusReset =
        amcl::input::PlatformInputResetEpoch();
    amcl::input::PlatformInputFocusChanged(false);
    CHECK(amcl::input::PlatformInputResetEpoch() > beforeFocusReset);
    const auto unfocused = Snapshot();
    CHECK(unfocused.focused == 0u);
    CHECK(unfocused.heldControlCount == 0u);
    const auto reset = Drain(observer);
    CHECK(HasKey(reset, 42u, AMCL_INPUT_ACTION_UP));
    reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 0u);
    CHECK(reconciliation.legacyHeldKeys == 0u);
    CHECK(reconciliation.unresolved == 0u);

    // Keep one consumer from draining so the shared bounded queue overflows.
    // The triggering key is dropped: only RESET is committed, therefore its
    // observation must be typedAccepted=false even if legacy routing succeeds.
    amcl::input::PlatformInputFocusChanged(true);
    (void)Drain(observer);
    AmclInputConsumerHandle blocker = 0;
    CHECK(gApi->openConsumer(&blocker) == AMCL_INPUT_OK);
    CHECK(Drain(blocker).size() == 1u);
    const auto queueEpoch = Snapshot();
    CHECK(queueEpoch.queuedEventCount < queueEpoch.queueCapacity);
    const uint64_t fillCount =
        queueEpoch.queueCapacity - queueEpoch.queuedEventCount;
    for (uint64_t i = 0; i < fillCount; i++) {
        AmclInputEvent move{};
        move.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
        move.header.structSize = static_cast<uint16_t>(sizeof(move));
        move.header.eventType = AMCL_INPUT_EVENT_POINTER_RELATIVE;
        move.header.source = AMCL_INPUT_SOURCE_MOUSE;
        move.header.sessionEpoch = queueEpoch.sessionEpoch;
        move.header.focusEpoch = queueEpoch.focusEpoch;
        move.header.surfaceEpoch = queueEpoch.surfaceEpoch;
        move.payload.pointerRelative.rawDx = static_cast<double>(i + 1u);
        CHECK(gApi->submitEvent(&move) == AMCL_INPUT_OK);
    }
    const uint64_t beforeOverflowReset =
        amcl::input::PlatformInputResetEpoch();
    const uint64_t overflowed = amcl::input::PlatformInputPhysicalKey(
        50u, 150u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 9u, 50);
    CHECK(amcl::input::PlatformInputResetEpoch() > beforeOverflowReset);
    amcl::input::trace::FinalizeObservation(
        overflowed, amcl::input::trace::LegacyResult::Exact, 1);
    reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 0u);
    CHECK(reconciliation.legacyHeldKeys == 0u);
    CHECK(reconciliation.unexpectedMismatch != 0u);
    const auto overflowOutput = Drain(observer);
    CHECK(!HasKey(overflowOutput, 50u, AMCL_INPUT_ACTION_DOWN));
    // Duplicate lifecycle reset remains idempotent after the dropped legacy
    // route and cannot be required to repair reconciliation.
    amcl::input::PlatformInputRequestReset(AMCL_INPUT_RESET_EXPLICIT);
    reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 0u);
    CHECK(reconciliation.legacyHeldKeys == 0u);

    CHECK(gApi->closeConsumer(blocker) == AMCL_INPUT_OK);
    CHECK(gApi->closeConsumer(observer) == AMCL_INPUT_OK);
    amcl::input::PlatformInputSurfaceDestroyed();
    const auto ended = Snapshot();
    CHECK(ended.sessionActive == 0u);
    CHECK(ended.consumerCount == 0u);
    CHECK(ended.heldControlCount == 0u);

    // Dimensions validity is not surface ownership. A zero-sized publication
    // must still emit active=0 before endSession when destroyed.
    amcl::input::PlatformInputSurfaceCreated(0u, 0u);
    CHECK(Snapshot().sessionActive != 0u);
    AmclInputConsumerHandle zeroSurfaceObserver = 0;
    CHECK(gApi->openConsumer(&zeroSurfaceObserver) == AMCL_INPUT_OK);
    // Invalid zero geometry is not replayed as an active backend target. The
    // already-open observer still receives the explicit inactive publication
    // during destroy below.
    CHECK(Drain(zeroSurfaceObserver).size() == 1u);
    amcl::input::PlatformInputSurfaceDestroyed();
    CHECK(HasInactiveSurface(DrainUntilBoundary(zeroSurfaceObserver)));
    CHECK(gApi->closeConsumer(zeroSurfaceObserver) == AMCL_INPUT_OK);
    CHECK(Snapshot().sessionActive == 0u);

    // Race the recovery snapshot with host endSession. OpenConsumer then has no
    // required baseline RESET, so ingress must fail closed instead of accepting
    // an unproven epoch. Finalizing the failed legacy DOWN cannot repopulate held.
    amcl::input::PlatformInputSurfaceCreated(640u, 480u);
    const auto beforeRace = Snapshot();
    uint64_t racedEpoch = 0;
    CHECK(gApi->beginSession(&racedEpoch) == AMCL_INPUT_OK);
    CHECK(racedEpoch != beforeRace.sessionEpoch);
    amcl::input::PlatformInputTestSetBeforeRecoveryOpenHook(
        EndCurrentHostSessionDuringRecovery);
    const uint64_t beforeRaceEpoch = amcl::input::PlatformInputResetEpoch();
    const auto beforeRaceCounters =
        amcl::input::trace::TestEpochRecoverySnapshot();
    const uint64_t raced = amcl::input::PlatformInputPhysicalKey(
        60u, 160u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 10u, 60);
    amcl::input::trace::FinalizeObservation(
        raced, amcl::input::trace::LegacyResult::Exact, 1);
    const auto afterRace = Snapshot();
    CHECK(afterRace.sessionActive == 0u);
    CHECK(afterRace.consumerCount == 0u);
    // Failing closed is counted but deliberately does NOT advance the frontend
    // epoch: it proves nothing about the host, and advancing would tell ArkTS to
    // drop held state across an unproven boundary. This equality pins that
    // choice, so a future edit that "makes recovery consistent" by advancing on
    // both paths has to come here and argue with it first.
    const auto afterRaceCounters =
        amcl::input::trace::TestEpochRecoverySnapshot();
    CHECK(afterRaceCounters.failedClosed > beforeRaceCounters.failedClosed);
    CHECK(afterRaceCounters.recovered == beforeRaceCounters.recovered);
    // `+ 1u` 而不是 `== beforeRaceEpoch`：上面那次 `beginSession` 真的开了新 host 会话，
    // 所以 `SubmitLocked` 里先跑的 `RecordAndDrainLocked` 真的观测到一个 core RESET，
    // 而契约就是"观测到 core RESET 时推进 frontend epoch" ⇒ 这 +1 必须发生。
    // 恰好是 1：`SubmitLocked` 只排空一次，`observedReset` 是单个 bool；recovery 自己那次
    // 排空只在成功分支推进，而本场景刻意 fail closed（`recovered` 不变即其证据）。
    //
    // 两个方向都被封住：fail-closed 若也推进 → +2 失败；那次合法推进若被弄丢 → +0 也失败。
    // ⚠️ 原文写的 `== beforeRaceEpoch` 会**接受**后一种缺陷，且它是 29 个目标第一次真正执行
    // 时唯一红掉的一条 —— 定案（产品正确、断言过严）与负向验证见计划 §82.3。
    CHECK(amcl::input::PlatformInputResetEpoch() == beforeRaceEpoch + 1u);
    reconciliation = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(reconciliation.typedHeldKeys == 0u);
    CHECK(reconciliation.legacyHeldKeys == 0u);
    amcl::input::PlatformInputSurfaceDestroyed();

    // Window/display context is allowed to arrive before XComponent creates a
    // native session. The first surface must consume the same density/transform
    // and late-consumer baseline order is RESET -> SURFACE -> CONTEXT.
    AmclInputSurfaceContextPayload context{};
    context.windowId = 31;
    context.displayId = 6;
    context.leftPx = -120;
    context.topPx = 24;
    context.widthPx = 700u;
    context.heightPx = 500u;
    context.density = 2.5f;
    context.refreshRateHz = 120.0f;
    context.transform = 2u;
    context.validFields = AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    context.generation = 100u;
    CHECK(amcl::input::PlatformInputSurfaceContextChanged(context));
    CHECK(Snapshot().sessionActive == 0u);
    amcl::input::PlatformInputSurfaceCreated(700u, 500u, 99u);
    const auto contextSession = Snapshot();
    CHECK(contextSession.sessionActive != 0u);
    AmclInputConsumerHandle contextObserver = 0u;
    CHECK(gApi->openConsumer(&contextObserver) == AMCL_INPUT_OK);
    auto contextBaseline = Drain(contextObserver);
    CHECK(contextBaseline.size() == 3u);
    CHECK(contextBaseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(contextBaseline[1].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(contextBaseline[1].payload.surface.density == 2.5f);
    CHECK(contextBaseline[1].payload.surface.transform == 2u);
    CHECK((contextBaseline[1].payload.surface.validFields &
           AMCL_INPUT_SURFACE_FIELD_DENSITY) != 0u);
    CHECK((contextBaseline[1].payload.surface.validFields &
           AMCL_INPUT_SURFACE_FIELD_TRANSFORM) != 0u);
    CHECK(contextBaseline[2].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    CHECK(contextBaseline[2].payload.surfaceContext.generation == 100u);
    AmclInputEvent backendReady{};
    backendReady.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    backendReady.header.structSize = sizeof(backendReady);
    backendReady.header.eventType =
        AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    backendReady.header.sessionEpoch = contextSession.sessionEpoch;
    backendReady.payload.backendConsumerState.state =
        AMCL_INPUT_BACKEND_CONSUMER_READY;
    backendReady.payload.backendConsumerState.backend =
        AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    backendReady.payload.backendConsumerState.consumer = contextObserver;
    backendReady.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    backendReady.payload.backendConsumerState.baselineSequence =
        contextBaseline[0].header.sequence;
    CHECK(gApi->submitEvent(&backendReady) == AMCL_INPUT_OK);

    // Position/refresh only advances context generation, not surfaceEpoch.
    context.leftPx = 20;
    context.refreshRateHz = 90.0f;
    context.generation = 101u;
    CHECK(amcl::input::PlatformInputSurfaceContextChanged(context));
    CHECK(Snapshot().surfaceEpoch == contextSession.surfaceEpoch);
    auto movedContext = Drain(contextObserver);
    CHECK(movedContext.size() == 1u);
    CHECK(movedContext[0].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);

    // Density changes coordinate semantics: ingress republishes the existing
    // native surface first, which advances the epoch, then the new context.
    context.density = 3.0f;
    context.generation = 102u;
    CHECK(amcl::input::PlatformInputSurfaceContextChanged(context));
    CHECK(Snapshot().surfaceEpoch > contextSession.surfaceEpoch);
    const auto densityBoundary = Drain(contextObserver);
    CHECK(densityBoundary.size() == 3u);
    CHECK(densityBoundary[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(densityBoundary[1].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(densityBoundary[1].payload.surface.density == 3.0f);
    CHECK(densityBoundary[2].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);

    AmclInputSurfaceContextPayload staleContext = context;
    staleContext.generation = 101u;
    CHECK(!amcl::input::PlatformInputSurfaceContextChanged(staleContext));
    CHECK(Drain(contextObserver).empty());

    // Product typed-text ingress owns one token and one packet per callback.
    // It never falls back to the legacy per-character bridge.
    CHECK(amcl::input::PlatformInputTextSessionSupported());
    constexpr uint64_t textId = 77u;
    CHECK(amcl::input::PlatformInputTextSessionBegin(textId));
    const uint8_t committed[] = {
        0xe4u, 0xb8u, 0xadu, 0xf0u, 0x9fu, 0x98u, 0x80u, 0x40u};
    CHECK(amcl::input::PlatformInputTextCommit(
        textId, committed, static_cast<uint32_t>(sizeof(committed))));
    auto textEvents = Drain(contextObserver);
    CHECK(textEvents.size() == 2u);
    CHECK(textEvents[0].header.eventType ==
          AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    CHECK(textEvents[1].header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
    uint32_t copiedBytes = 0u;
    std::vector<uint8_t> copied(sizeof(committed));
    CHECK(gApi->readPacketBlob(
              contextObserver, &textEvents[1].payload.textCommit.utf8Blob,
              copied.data(), static_cast<uint32_t>(copied.size()),
              &copiedBytes) == AMCL_INPUT_OK);
    CHECK(copiedBytes == sizeof(committed));
    CHECK(copied == std::vector<uint8_t>(
        committed, committed + sizeof(committed)));
    CHECK(gApi->releasePacket(
              contextObserver,
              textEvents[1].payload.textCommit.utf8Blob.packetId) ==
          AMCL_INPUT_OK);
    CHECK(!amcl::input::PlatformInputTextSessionEnd(textId + 1u));
    CHECK(amcl::input::PlatformInputTextSessionEnd(textId));
    textEvents = Drain(contextObserver);
    CHECK(textEvents.size() == 1u);
    CHECK(textEvents[0].payload.textSession.change ==
          AMCL_INPUT_TEXT_SESSION_ENDED);

    const uint64_t unsupportedBefore =
        amcl::input::PlatformInputCandidatesUnsupportedCount();
    amcl::input::PlatformInputNoteCandidatesUnsupported();
    CHECK(amcl::input::PlatformInputCandidatesUnsupportedCount() ==
          unsupportedBefore + 1u);

    CHECK(amcl::input::PlatformInputTextSessionBegin(textId + 1u));
    Drain(contextObserver);
    amcl::input::PlatformInputFocusChanged(false);
    CHECK(!amcl::input::PlatformInputTextCommit(
        textId + 1u, committed, static_cast<uint32_t>(sizeof(committed))));
    Drain(contextObserver);
    amcl::input::PlatformInputFocusChanged(true);
    Drain(contextObserver);
    CHECK(gApi->closeConsumer(contextObserver) == AMCL_INPUT_DRAIN_REQUIRED);
    Drain(contextObserver);
    CHECK(gApi->closeConsumer(contextObserver) == AMCL_INPUT_OK);
    amcl::input::PlatformInputSurfaceDestroyed(99u);
    CHECK(Snapshot().sessionActive == 0u);

    const uint64_t beforeCompletedBoundary =
        amcl::input::PlatformInputResetEpoch();
    amcl::input::PlatformInputCompleteResetBoundary();
    CHECK(amcl::input::PlatformInputResetEpoch() > beforeCompletedBoundary);

    std::cout << "platform ingress integration test passed\n";
    return 0;
}

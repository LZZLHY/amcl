#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {
uint32_t gUnexpectedEnqueueCalls = 0;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TYPED ROUTE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclLegacyPhysicalOutcome UnexpectedPhysicalRelativeEnqueue(double, double) {
    ++gUnexpectedEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

bool UnexpectedRelativeFallbackEnqueue(double, double) {
    ++gUnexpectedEnqueueCalls;
    return true;
}

AmclLegacyPhysicalOutcome UnexpectedKeyRoute(
        uint64_t, uint32_t, int32_t, int32_t, int32_t, int32_t,
        int32_t*) {
    ++gUnexpectedEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome UnexpectedButtonRoute(
        uint64_t, uint32_t, int32_t, int32_t, int32_t*) {
    ++gUnexpectedEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome UnexpectedWheelRoute(
        double, double, uint32_t*) {
    ++gUnexpectedEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

void SelectTypedBeforeHostConstruction() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
#endif
}

std::vector<AmclInputEvent> Drain(AmclInputConsumerHandle consumer,
                                  const AmclInputHostApiV1* api) {
    std::vector<AmclInputEvent> events;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = api->nextEvent(consumer, &event);
        if (result == AMCL_INPUT_EMPTY) return events;
        CHECK(result == AMCL_INPUT_OK);
        events.push_back(event);
    }
}

bool HasType(const std::vector<AmclInputEvent>& events, uint32_t type) {
    for (const auto& event : events) {
        if (event.header.eventType == type) return true;
    }
    return false;
}

const AmclInputEvent* FindType(const std::vector<AmclInputEvent>& events,
                               uint32_t type) {
    for (const auto& event : events) {
        if (event.header.eventType == type) return &event;
    }
    return nullptr;
}

AmclInputEvent BackendConsumerState(
        uint32_t state, AmclInputConsumerHandle consumer,
        uint64_t sessionEpoch, uint64_t baselineSequence = 0u) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    event.header.sessionEpoch = sessionEpoch;
    event.payload.backendConsumerState.state = state;
    event.payload.backendConsumerState.backend =
        AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baselineSequence;
    return event;
}

bool HasResetReason(const std::vector<AmclInputEvent>& events,
                    uint32_t reason) {
    for (const auto& event : events) {
        if (event.header.eventType == AMCL_INPUT_EVENT_RESET &&
            event.payload.reset.reason == reason) {
            return true;
        }
    }
    return false;
}
}  // namespace
int main() {
    SelectTypedBeforeHostConstruction();
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u);
#if AMCL_EXPECT_API26_RAW
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION) != 0u);
#else
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION) == 0u);
#endif
    CHECK(!amcl::input::PlatformInputShadowEnabled());
    CHECK(amcl::input::PlatformInputPhysicalRouteUsesTyped());
    CHECK(amcl::input::PlatformInputCoreEnabled());

    amcl::input::PlatformInputSurfaceCreated(800u, 600u);
    AmclInputConsumerHandle observer = 0u;
    CHECK(api->openConsumer(&observer) == AMCL_INPUT_OK);
    const auto baselineEvents = Drain(observer, api);
    CHECK(baselineEvents.size() == 2u);
    const AmclInputEvent baseline = baselineEvents.front();
    CHECK(baseline.header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline.payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(baselineEvents[1].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CHANGED);

    // Selecting typed+shadow0 is not permission to accept physical packets.
    // Until this exact consumer acknowledges its fresh baseline, every typed
    // transaction must surface a delivery failure and must not call legacy.
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2001u, 20u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 11u, 65, 1, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              0.5, -0.25, true, UnexpectedPhysicalRelativeEnqueue) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              11u, 1u, AMCL_INPUT_ACTION_DOWN, 0, 1, true,
              UnexpectedButtonRoute) == AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 15.0, false, true, UnexpectedWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    CHECK(Drain(observer, api).empty());
    AmclInputSnapshotV1 preReadySnapshot{};
    preReadySnapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    preReadySnapshot.structSize = sizeof(preReadySnapshot);
    CHECK(api->getSnapshot(&preReadySnapshot) == AMCL_INPUT_OK);
    CHECK(preReadySnapshot.heldControlCount == 0u);

    AmclInputEvent ready = BackendConsumerState(
        AMCL_INPUT_BACKEND_CONSUMER_READY, observer,
        baseline.header.sessionEpoch, baseline.header.sequence);
    CHECK(api->submitEvent(&ready) == AMCL_INPUT_OK);

    // Lifecycle must remain live even though reconciliation shadowing is off.
    amcl::input::PlatformInputSurfaceChanged(801u, 601u);
    auto lifecycle = Drain(observer, api);
    CHECK(HasType(lifecycle, AMCL_INPUT_EVENT_SURFACE_CHANGED));
    CHECK(HasType(lifecycle, AMCL_INPUT_EVENT_RESET));
    amcl::input::PlatformInputFocusChanged(false);
    lifecycle = Drain(observer, api);
    CHECK(HasType(lifecycle, AMCL_INPUT_EVENT_FOCUS_CHANGED));
    CHECK(HasType(lifecycle, AMCL_INPUT_EVENT_RESET));
    amcl::input::PlatformInputFocusChanged(true);
    amcl::input::PlatformInputCaptureRequested(true);
    amcl::input::PlatformInputCaptureChanged(
        true, true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    amcl::input::PlatformInputPointerEnter(true);

    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2017u, 30u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 11u, 65, 1, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    // Compatibility mapping is irrelevant on typed delivery, but the action
    // pair is still validated before core mutation.
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2018u, 31u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 11u, 0, 0, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2018u, 31u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 11u, 0, 1, false, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    const auto beforeInvalid =
        amcl::input::trace::TestCoreSubmissionSnapshot();
    const double invalid[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
    };
    for (double value : invalid) {
        CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
                  value, 1.0, true, UnexpectedPhysicalRelativeEnqueue) ==
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
        CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
                  1.0, value, true, UnexpectedPhysicalRelativeEnqueue) ==
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
    }
    CHECK(gUnexpectedEnqueueCalls == 0u);
    auto submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == beforeInvalid.submitted + 6u);
    CHECK(submissions.errors == beforeInvalid.errors + 6u);
    CHECK(amcl::input::trace::TestPhysicalRelativeIngressSnapshot()
              .invalidDelta == 6u);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              1.25, -2.5, true, UnexpectedPhysicalRelativeEnqueue) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == beforeInvalid.submitted + 7u);
    CHECK(submissions.errors == beforeInvalid.errors + 6u);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              12u, 1u, AMCL_INPUT_ACTION_DOWN, 0, 1, true,
              UnexpectedButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 7.5, true, true, UnexpectedWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              12u, 1u, AMCL_INPUT_ACTION_UP, 0, 0, false,
              UnexpectedButtonRoute) == AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 7.5, true, false, UnexpectedWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    // A window-coordinate difference cannot escape onto the legacy source
    // plane once the process host has selected typed physical input.
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              std::numeric_limits<double>::quiet_NaN(), -4.0, true,
              UnexpectedRelativeFallbackEnqueue) ==
          amcl::input::PlatformInputRelativeFallbackResult::InvalidDelta);
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              9.0, -4.0, true, UnexpectedRelativeFallbackEnqueue) ==
          amcl::input::PlatformInputRelativeFallbackResult::TypedRouteRejected);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    const auto fallback = amcl::input::trace::TestRelativeFallbackSnapshot();
    CHECK(fallback.selected == 0u);
    CHECK(fallback.enqueued == 0u);
    CHECK(fallback.enqueueFailed == 0u);
    CHECK(fallback.zeroDelta == 0u);
    CHECK(fallback.typedRouteRejected == 1u);
    CHECK(fallback.gateRejected == 0u);
    CHECK(fallback.invalidDelta == 1u);

    const auto events = Drain(observer, api);
    CHECK(HasType(events, AMCL_INPUT_EVENT_FOCUS_CHANGED));
    CHECK(HasType(events, AMCL_INPUT_EVENT_CAPTURE_CHANGED));
    CHECK(HasType(events, AMCL_INPUT_EVENT_POINTER_ENTER));
    CHECK(HasType(events, AMCL_INPUT_EVENT_PHYSICAL_KEY));
    CHECK(HasType(events, AMCL_INPUT_EVENT_POINTER_RELATIVE));
    CHECK(HasType(events, AMCL_INPUT_EVENT_POINTER_BUTTON));
    CHECK(HasType(events, AMCL_INPUT_EVENT_POINTER_WHEEL));
    const AmclInputEvent* relativeEvent =
        FindType(events, AMCL_INPUT_EVENT_POINTER_RELATIVE);
    CHECK(relativeEvent != nullptr);
#if AMCL_EXPECT_API26_RAW
    CHECK((relativeEvent->header.flags &
           AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW) != 0u);
#else
    CHECK((relativeEvent->header.flags &
           AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW) == 0u);
#endif
    AmclInputSnapshotV1 capturedSnapshot{};
    capturedSnapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    capturedSnapshot.structSize = sizeof(capturedSnapshot);
    CHECK(api->getSnapshot(&capturedSnapshot) == AMCL_INPUT_OK);
    CHECK(capturedSnapshot.captureRequested == 1u);
    CHECK(capturedSnapshot.captureActive == 1u);
    CHECK(capturedSnapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_GRANTED);
    const auto routed = amcl::input::trace::TestReconciliationSnapshot();
    CHECK(routed.begun == 0u && routed.finalized == 0u);
    CHECK(routed.unresolved == 0u);
    CHECK(routed.legacyHeldKeys == 0u && routed.legacyHeldButtons == 0u);
    using amcl::input::trace::PhysicalIngressKind;
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Button,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalMappingUnavailableCount(
              PhysicalIngressKind::Key) == 0u);

    // §11 producer-side per-action counts. Measured as deltas around two known
    // edges rather than as absolute totals, so the assertion keeps its meaning
    // when earlier parts of this test add or remove transactions.
    using amcl::input::trace::TestPhysicalActionCount;
    const uint64_t keyDownBefore =
        TestPhysicalActionCount(PhysicalIngressKind::Key,
                                AMCL_INPUT_ACTION_DOWN);
    const uint64_t keyUpBefore =
        TestPhysicalActionCount(PhysicalIngressKind::Key, AMCL_INPUT_ACTION_UP);
    const uint64_t buttonDownBefore =
        TestPhysicalActionCount(PhysicalIngressKind::Button,
                                AMCL_INPUT_ACTION_DOWN);
    const uint64_t buttonUpBefore =
        TestPhysicalActionCount(PhysicalIngressKind::Button,
                                AMCL_INPUT_ACTION_UP);

    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2017u, 30u, 4u, AMCL_INPUT_ACTION_UP,
              0u, 0u, 11u, 65, 0, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              12u, 1u, AMCL_INPUT_ACTION_UP, 0, 0, true,
              UnexpectedButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(gUnexpectedEnqueueCalls == 0u);

    // Exactly one UP per kind, and the DOWN buckets must not move.
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Key,
                                  AMCL_INPUT_ACTION_UP) == keyUpBefore + 1u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Key,
                                  AMCL_INPUT_ACTION_DOWN) == keyDownBefore);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Button,
                                  AMCL_INPUT_ACTION_UP) == buttonUpBefore + 1u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Button,
                                  AMCL_INPUT_ACTION_DOWN) == buttonDownBefore);
    // Slot 0 collects actions outside DOWN/REPEAT/UP. It is reachable in
    // production: ingress reports INVALID_ACTION for an action that does not pair
    // with its mapped control and still forwards the producer's raw action to the
    // recorder. Drive that path so the bucket has real coverage instead of an
    // assertion that only passes because nothing ever exercises it.
    const uint64_t keySlot0Before =
        TestPhysicalActionCount(PhysicalIngressKind::Key, 0u);
    const uint64_t buttonSlot0Before =
        TestPhysicalActionCount(PhysicalIngressKind::Button, 0u);
    const uint64_t keyInvalidBefore =
        amcl::input::trace::TestPhysicalIngressOutcomeCount(
            PhysicalIngressKind::Key, AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2019u, 33u, 4u, 99u,
              0u, 0u, 11u, 66, 0, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              13u, 1u, 99u, 0, 0, true, UnexpectedButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Key, 0u) ==
          keySlot0Before + 1u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Button, 0u) ==
          buttonSlot0Before + 1u);
    // The invalid edge is an INVALID_ACTION outcome, never a DOWN/REPEAT/UP.
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_INVALID_ACTION) == keyInvalidBefore + 1u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Key,
                                  AMCL_INPUT_ACTION_DOWN) == keyDownBefore);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Key,
                                  AMCL_INPUT_ACTION_UP) == keyUpBefore + 1u);

    // Relative and wheel have no action, so they must not be bucketed at all --
    // not even into slot 0, where their total would masquerade as "no action".
    // These are regression guards, not behaviour verification: the recorder skips
    // those kinds unconditionally, so no input can make them non-zero. They exist
    // to fail if someone drops the kind check.
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Relative, 0u) == 0u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Relative,
                                  AMCL_INPUT_ACTION_DOWN) == 0u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Wheel, 0u) == 0u);
    CHECK(TestPhysicalActionCount(PhysicalIngressKind::Wheel,
                                  AMCL_INPUT_ACTION_UP) == 0u);
    // Both matrices are updated from one call site, so equality here is a
    // structural identity rather than an independent cross-check: it fails only
    // if one of the two fetch_add calls is removed or an early return is added
    // between them. That is a narrow but real regression, and it is the reason
    // the two counters can be summed against each other elsewhere.
    for (const auto kind : {PhysicalIngressKind::Key,
                            PhysicalIngressKind::Button}) {
        uint64_t byAction = 0;
        for (uint32_t action = 0; action <= AMCL_INPUT_ACTION_UP; ++action) {
            byAction += TestPhysicalActionCount(kind, action);
        }
        uint64_t byOutcome = 0;
        for (int outcome = AMCL_LEGACY_PHYSICAL_EMITTED;
             outcome <= AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED; ++outcome) {
            byOutcome += amcl::input::trace::TestPhysicalIngressOutcomeCount(
                kind, static_cast<AmclLegacyPhysicalOutcome>(outcome));
        }
        CHECK(byAction == byOutcome);
        CHECK(byAction != 0u);
    }
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = sizeof(snapshot);
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    CHECK(snapshot.heldControlCount == 0u);

    const auto finalUps = Drain(observer, api);
    CHECK(HasType(finalUps, AMCL_INPUT_EVENT_PHYSICAL_KEY));
    CHECK(HasType(finalUps, AMCL_INPUT_EVENT_POINTER_BUTTON));

    AmclInputEvent retire = BackendConsumerState(
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE, observer,
        baseline.header.sessionEpoch);
    CHECK(api->submitEvent(&retire) == AMCL_INPUT_OK);
    const auto retired = Drain(observer, api);
    CHECK(HasResetReason(retired, AMCL_INPUT_RESET_BACKEND_RETIRED));

    // RETIRE closes admission before cleanup is drained. The startup-latched
    // typed route must report failure and must never silently invoke legacy.
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              2020u, 32u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 11u, 67, 1, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(gUnexpectedEnqueueCalls == 0u);
    CHECK(Drain(observer, api).empty());
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 2u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Button,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 1u);

    CHECK(api->closeConsumer(observer) == AMCL_INPUT_OK);
    amcl::input::PlatformInputSurfaceDestroyed();
    std::cout << "platform typed route test passed\n";
    return 0;
}

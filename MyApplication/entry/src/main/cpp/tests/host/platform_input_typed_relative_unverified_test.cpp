#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {
uint32_t gUnexpectedLegacyCalls = 0u;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TYPED RELATIVE EVIDENCE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclLegacyPhysicalOutcome UnexpectedRelativeEnqueue(double, double) {
    ++gUnexpectedLegacyCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome UnexpectedKeyRoute(
        uint64_t, uint32_t, int32_t, int32_t, int32_t, int32_t,
        int32_t*) {
    ++gUnexpectedLegacyCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome UnexpectedButtonRoute(
        uint64_t, uint32_t, int32_t, int32_t, int32_t*) {
    ++gUnexpectedLegacyCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome UnexpectedWheelRoute(double, double, uint32_t*) {
    ++gUnexpectedLegacyCalls;
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

AmclInputEvent BackendReady(AmclInputConsumerHandle consumer,
                            uint64_t sessionEpoch,
                            uint64_t baselineSequence) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    event.header.sessionEpoch = sessionEpoch;
    event.payload.backendConsumerState.state =
        AMCL_INPUT_BACKEND_CONSUMER_READY;
    event.payload.backendConsumerState.backend =
        AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baselineSequence;
    return event;
}

bool HasType(const std::vector<AmclInputEvent>& events, uint32_t type) {
    for (const auto& event : events) {
        if (event.header.eventType == type) return true;
    }
    return false;
}
}  // namespace

int main() {
    SelectTypedBeforeHostConstruction();
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u);
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE) == 0u);
    CHECK(amcl::input::PlatformInputPhysicalRouteUsesTyped());
    CHECK(!amcl::input::PlatformInputRawRelativeVerified());

    amcl::input::PlatformInputSurfaceCreated(800u, 600u);
    AmclInputConsumerHandle observer = 0u;
    CHECK(api->openConsumer(&observer) == AMCL_INPUT_OK);
    const auto baseline = Drain(observer, api);
    CHECK(baseline.size() == 2u);
    CHECK(baseline.front().header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline.front().payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(baseline[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    AmclInputEvent ready = BackendReady(
        observer, baseline.front().header.sessionEpoch,
        baseline.front().header.sequence);
    CHECK(api->submitEvent(&ready) == AMCL_INPUT_OK);
    (void)Drain(observer, api);

    const auto before = amcl::input::trace::TestCoreSubmissionSnapshot();
    const auto diagnosticsBefore =
        amcl::input::trace::TestCoreDiagnosticSnapshot();
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              1.25, -2.5, true, UnexpectedRelativeEnqueue) ==
          AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED);
    CHECK(gUnexpectedLegacyCalls == 0u);
    auto submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == before.submitted);
    CHECK(submissions.errors == before.errors);
    auto diagnostics = amcl::input::trace::TestCoreDiagnosticSnapshot();
    CHECK(diagnostics.unsupported == diagnosticsBefore.unsupported + 1u);
    CHECK(diagnostics.diagnosticDrops == diagnosticsBefore.diagnosticDrops);
    using amcl::input::trace::PhysicalIngressKind;
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) == 1u);
    CHECK(Drain(observer, api).empty());

    const auto relativeBefore =
        amcl::input::trace::TestPhysicalRelativeIngressSnapshot();
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              std::numeric_limits<double>::quiet_NaN(), 1.0, true,
              UnexpectedRelativeEnqueue) ==
          AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
    submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == before.submitted);
    CHECK(submissions.errors == before.errors);
    diagnostics = amcl::input::trace::TestCoreDiagnosticSnapshot();
    CHECK(diagnostics.unsupported == diagnosticsBefore.unsupported + 1u);
    CHECK(amcl::input::trace::TestPhysicalRelativeIngressSnapshot()
              .invalidDelta == relativeBefore.invalidDelta + 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE) == 1u);

    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              3.0, 4.0, false, UnexpectedRelativeEnqueue) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(amcl::input::trace::TestCoreDiagnosticSnapshot().unsupported ==
          diagnosticsBefore.unsupported + 1u);
    CHECK(gUnexpectedLegacyCalls == 0u);

    // The direct core-submission seam must reach the same classification as the
    // transaction. It has no product caller, so without this assertion its
    // capability rejection would only bump the generic `unsupported` counter and
    // "Gate 0 evidence missing" would be indistinguishable from an unsupported
    // platform getter in operational summaries.
    const auto seamUnsupportedBefore =
        amcl::input::trace::TestCoreDiagnosticSnapshot().unsupported;
    CHECK(amcl::input::PlatformInputPointerRelative(5.0, -6.0) == 0u);
    CHECK(amcl::input::trace::TestCoreDiagnosticSnapshot().unsupported ==
          seamUnsupportedBefore + 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) == 2u);
    submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == before.submitted);
    CHECK(submissions.errors == before.errors);
    CHECK(Drain(observer, api).empty());

    // A malformed value must not be re-labelled as a capability problem just
    // because it arrived through the seam: finiteness is checked before the
    // evidence latch on both entry points. Without this case the ordering has no
    // regression protection, and the same NaN could silently start reporting
    // CAPABILITY_REJECTED on one path and INVALID_VALUE on the other.
    const auto seamInvalidBefore =
        amcl::input::trace::TestPhysicalRelativeIngressSnapshot();
    const auto seamCapabilityUnsupported =
        amcl::input::trace::TestCoreDiagnosticSnapshot().unsupported;
    const uint64_t seamInvalidOutcomeBefore =
        amcl::input::trace::TestPhysicalIngressOutcomeCount(
            PhysicalIngressKind::Relative, AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
    CHECK(amcl::input::PlatformInputPointerRelative(
              std::numeric_limits<double>::quiet_NaN(), 1.0) == 0u);
    CHECK(amcl::input::trace::TestPhysicalRelativeIngressSnapshot()
              .invalidDelta == seamInvalidBefore.invalidDelta + 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE) ==
          seamInvalidOutcomeBefore + 1u);
    // Still no capability diagnosis and no core submission: without evidence
    // there is no authority to hand even an invalid sample to the typed core.
    CHECK(amcl::input::trace::TestCoreDiagnosticSnapshot().unsupported ==
          seamCapabilityUnsupported);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) == 2u);
    submissions = amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submissions.submitted == before.submitted);
    CHECK(submissions.errors == before.errors);
    CHECK(Drain(observer, api).empty());

    // The evidence bit is event-specific. Its absence must not silently disable
    // the already baselined typed key path or divert that path to legacy.
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              30u, 4u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, 91u, 65, 1, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              30u, 4u, 4u, AMCL_INPUT_ACTION_UP,
              0u, 0u, 91u, 65, 0, true, UnexpectedKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(gUnexpectedLegacyCalls == 0u);
    CHECK(HasType(Drain(observer, api), AMCL_INPUT_EVENT_PHYSICAL_KEY));

    // Same requirement for button and wheel, asserted in this same process.
    // The relative evidence latch is scoped to POINTER_RELATIVE only; if it ever
    // leaked into the other physical kinds the whole typed plane would go dark on
    // a device that merely lacks raw-delta evidence.
    const auto buttonWheelBefore =
        amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              92u, 1u, AMCL_INPUT_ACTION_DOWN, 0, 1, true,
              UnexpectedButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              92u, 1u, AMCL_INPUT_ACTION_UP, 0, 0, true,
              UnexpectedButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 15.0, true, true, UnexpectedWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(gUnexpectedLegacyCalls == 0u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Button,
              AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) == 0u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) == 0u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Button,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 2u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Wheel,
              AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) == 1u);
    // Button/wheel really reached the core, unlike the rejected relative sample.
    CHECK(amcl::input::trace::TestCoreSubmissionSnapshot().submitted >
          buttonWheelBefore.submitted);
    const auto buttonWheelEvents = Drain(observer, api);
    CHECK(HasType(buttonWheelEvents, AMCL_INPUT_EVENT_POINTER_BUTTON));
    CHECK(HasType(buttonWheelEvents, AMCL_INPUT_EVENT_POINTER_WHEEL));

    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = sizeof(snapshot);
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    CHECK(snapshot.heldControlCount == 0u);

    AmclInputEvent retire = ready;
    retire.payload.backendConsumerState.state =
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE;
    retire.payload.backendConsumerState.baselineSequence = 0u;
    CHECK(api->submitEvent(&retire) == AMCL_INPUT_OK);
    (void)Drain(observer, api);
    CHECK(api->closeConsumer(observer) == AMCL_INPUT_OK);
    amcl::input::PlatformInputSurfaceDestroyed();
    std::cout << "typed relative evidence gate test passed\n";
    return 0;
}

#include "amcl_input_api.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TYPED NATIVE ABSOLUTE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

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

AmclInputSnapshotV1 Snapshot(const AmclInputHostApiV1* api) {
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    return snapshot;
}

const AmclInputEvent& Find(const std::vector<AmclInputEvent>& events,
                           uint32_t type) {
    for (const auto& event : events) {
        if (event.header.eventType == type) return event;
    }
    Fail("event type present", __LINE__);
}

}  // namespace

int main() {
    using amcl::input::PlatformInputNativeMouseResult;

    SelectTypedBeforeHostConstruction();
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) != 0u);
    CHECK(amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped());

    constexpr uint64_t kPublication1 = 41u;
    constexpr uint64_t kPublication2 = 42u;
    constexpr uint64_t kPublication3 = 43u;
    amcl::input::PlatformInputSurfaceCreated(800u, 600u, kPublication1);

    AmclInputConsumerHandle backend = 0u;
    CHECK(api->openConsumer(&backend) == AMCL_INPUT_OK);
    const auto baseline = Drain(backend, api);
    CHECK(baseline.size() == 2u);
    CHECK(baseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(baseline[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(baseline[1].header.surfaceEpoch ==
          baseline[0].header.surfaceEpoch);
    CHECK((baseline[1].payload.surface.validFields &
           AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION) != 0u);
    CHECK(baseline[1].payload.surface.publicationGeneration == kPublication1);

    // Backend readiness gates both the single MOVE and atomic click batch.
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 10.0, 11.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::SubmitFailed);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 10.0, 11.0, 0u, 1u,
              AMCL_INPUT_ACTION_DOWN, true) ==
          PlatformInputNativeMouseResult::SubmitFailed);
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(Drain(backend, api).empty());

    AmclInputEvent ready = BackendReady(
        backend, baseline[0].header.sessionEpoch,
        baseline[0].header.sequence);
    CHECK(api->submitEvent(&ready) == AMCL_INPUT_OK);

    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              0u, 1.0, 1.0, 0u, 0u, 0u, false) ==
          PlatformInputNativeMouseResult::GateRejected);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1 + 100u, 1.0, 1.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::StaleSurface);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, -1.0, 1.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::InvalidSample);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 800.0, 1.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::InvalidSample);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1,
              std::numeric_limits<double>::quiet_NaN(), 1.0,
              0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::InvalidSample);
    CHECK(Drain(backend, api).empty());

    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 12.5, 13.5, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::Submitted);
    auto routed = Drain(backend, api);
    CHECK(routed.size() == 1u);
    CHECK(routed[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(routed[0].header.surfaceEpoch == baseline[1].header.surfaceEpoch);
    CHECK(routed[0].payload.pointerAbsolute.localPxX == 12.5);
    CHECK(routed[0].payload.pointerAbsolute.localPxY == 13.5);

    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 20.0, 21.0, 0u, 1u,
              AMCL_INPUT_ACTION_DOWN, true) ==
          PlatformInputNativeMouseResult::Submitted);
    routed = Drain(backend, api);
    CHECK(routed.size() == 2u);
    CHECK(routed[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(routed[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(routed[1].header.sequence == routed[0].header.sequence + 1u);
    CHECK(routed[0].header.monotonicTimeNs ==
          routed[1].header.monotonicTimeNs);
    CHECK(routed[0].header.surfaceEpoch == routed[1].header.surfaceEpoch);
    CHECK((routed[1].header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u);
    CHECK(routed[1].payload.pointerButton.nativeButton == 1u);
    CHECK(routed[1].payload.pointerButton.action == AMCL_INPUT_ACTION_DOWN);
    CHECK(Snapshot(api).heldControlCount == 1u);

    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 22.0, 23.0, 0u, 1u,
              AMCL_INPUT_ACTION_UP, true) ==
          PlatformInputNativeMouseResult::Submitted);
    routed = Drain(backend, api);
    CHECK(routed.size() == 2u);
    CHECK(routed[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(routed[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK((routed[1].header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u);
    CHECK(routed[1].payload.pointerButton.action == AMCL_INPUT_ACTION_UP);
    CHECK(Snapshot(api).heldControlCount == 0u);

    // A later lifecycle reset releases a held menu button without a matching
    // absolute sample. Core must clear the position-bound flag so the adapter
    // cannot discard this fail-safe synthetic release.
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 24.0, 25.0, 0u, 1u,
              AMCL_INPUT_ACTION_DOWN, true) ==
          PlatformInputNativeMouseResult::Submitted);
    routed = Drain(backend, api);
    CHECK(routed.size() == 2u);
    CHECK((routed[1].header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u);
    CHECK(Snapshot(api).heldControlCount == 1u);

    // Same-size native republication still advances core surfaceEpoch because
    // publicationGeneration participates in SameSurface.
    const uint64_t oldSurfaceEpoch = Snapshot(api).surfaceEpoch;
    amcl::input::PlatformInputSurfaceChanged(
        800u, 600u, kPublication2);
    const auto changed = Drain(backend, api);
    const AmclInputEvent& changedSurface =
        Find(changed, AMCL_INPUT_EVENT_SURFACE_CHANGED);
    const AmclInputEvent& syntheticRelease =
        Find(changed, AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(syntheticRelease.payload.pointerButton.action ==
          AMCL_INPUT_ACTION_UP);
    CHECK((syntheticRelease.header.flags &
           AMCL_INPUT_EVENT_FLAG_SYNTHETIC) != 0u);
    CHECK((syntheticRelease.header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) == 0u);
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(changedSurface.header.surfaceEpoch != oldSurfaceEpoch);
    CHECK(changedSurface.payload.surface.publicationGeneration ==
          kPublication2);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication1, 30.0, 31.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::StaleSurface);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication2, 30.0, 31.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::Submitted);
    routed = Drain(backend, api);
    CHECK(routed.size() == 1u);
    CHECK(routed[0].header.surfaceEpoch == changedSurface.header.surfaceEpoch);

    // Force an out-of-band host surface epoch change. The first old-binding
    // sample reaches core with its sampled epoch and is rejected STALE; ingress
    // recovery must invalidate the binding, not attach generation 42 to the
    // refreshed current epoch. Only a real lifecycle publication may restore it.
    AmclInputSurfacePayload externalSurface{};
    externalSurface.widthPx = 800u;
    externalSurface.heightPx = 600u;
    externalSurface.active = 1u;
    externalSurface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
        AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    externalSurface.publicationGeneration = 900u;
    CHECK(api->publishSurface(&externalSurface) == AMCL_INPUT_OK);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication2, 32.0, 33.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::SubmitFailed);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication2, 32.0, 33.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::StaleSurface);
    (void)Drain(backend, api);
    amcl::input::PlatformInputSurfaceChanged(
        800u, 600u, kPublication3);
    (void)Drain(backend, api);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication3, 32.0, 33.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::Submitted);
    (void)Drain(backend, api);

    // Fill the observer queue to prove the two-event click never partially
    // commits: batch overflow replaces all prior records with one RESET.
    for (uint32_t i = 0u; i < 7u; ++i) {
        CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
                  kPublication3, static_cast<double>(i), 1.0,
                  0u, 0u, 0u, true) ==
              PlatformInputNativeMouseResult::Submitted);
    }
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication3, 40.0, 41.0, 0u, 1u,
              AMCL_INPUT_ACTION_DOWN, true) ==
          PlatformInputNativeMouseResult::SubmitFailed);
    routed = Drain(backend, api);
    CHECK(routed.size() == 1u);
    CHECK(routed[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(routed[0].payload.reset.reason == AMCL_INPUT_RESET_QUEUE_OVERFLOW);
    CHECK(Snapshot(api).heldControlCount == 0u);

    amcl::input::PlatformInputSurfaceChanged(0u, 0u, kPublication3 + 1u);
    (void)Drain(backend, api);
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              kPublication3 + 1u, 0.0, 0.0, 0u, 0u, 0u, true) ==
          PlatformInputNativeMouseResult::StaleSurface);

    amcl::input::PlatformInputSurfaceDestroyed(kPublication3 + 1u);
    std::cout << "platform typed native absolute test passed\n";
    return 0;
}

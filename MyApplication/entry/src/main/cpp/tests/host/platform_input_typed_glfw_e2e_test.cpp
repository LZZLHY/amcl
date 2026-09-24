#include "adapters/glfw_input_adapter.h"
#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
using namespace amcl::input;

constexpr uint32_t kKnownOhosKey = 2017u;  // OHOS KEYCODE_A
constexpr uint32_t kUnknownOhosKey = 0x00f0f0f0u;
constexpr uint32_t kKnownNativeButton = 4u;
constexpr uint32_t kUnknownNativeButton = 32u;
constexpr uint64_t kKeyboardDevice = 101u;
constexpr uint64_t kMouseDevice = 202u;
uint32_t gUnexpectedLegacyKeyCalls = 0u;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TYPED GLFW E2E FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclLegacyPhysicalOutcome UnexpectedLegacyKeyRoute(
        uint64_t, uint32_t, int32_t, int32_t, int32_t, int32_t,
        int32_t*) {
    ++gUnexpectedLegacyKeyCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

void SelectTypedWithoutShadow() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
#endif
}

AmclInputEvent NextEvent(AmclInputConsumerHandle consumer,
                         const AmclInputHostApiV1* api,
                         bool allowBaselineSurfaceReplay = false) {
    AmclInputEvent event{};
    CHECK(api->nextEvent(consumer, &event) == AMCL_INPUT_OK);
    AmclInputEvent extra{};
    const int32_t extraStatus = api->nextEvent(consumer, &extra);
    if (allowBaselineSurfaceReplay) {
        CHECK(extraStatus == AMCL_INPUT_OK);
        CHECK(extra.header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
        AmclInputEvent empty{};
        CHECK(api->nextEvent(consumer, &empty) == AMCL_INPUT_EMPTY);
    } else {
        CHECK(extraStatus == AMCL_INPUT_EMPTY);
    }
    return event;
}

std::vector<AmclInputEvent> DrainAll(
        AmclInputConsumerHandle consumer, const AmclInputHostApiV1* api) {
    std::vector<AmclInputEvent> events;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = api->nextEvent(consumer, &event);
        if (result == AMCL_INPUT_EMPTY) return events;
        CHECK(result == AMCL_INPUT_OK);
        events.push_back(event);
    }
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

AmclInputSnapshotV1 Snapshot(const AmclInputHostApiV1* api) {
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    return snapshot;
}

void CheckRawKey(const AmclInputEvent& event, uint32_t raw,
                 uint32_t action, uint32_t scanCode, uint32_t hidUsage,
                 uint32_t modifiers, uint32_t locks) {
    CHECK(event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
    CHECK(event.header.source == AMCL_INPUT_SOURCE_KEYBOARD);
    CHECK(event.header.deviceId == kKeyboardDevice);
    CHECK(event.payload.physicalKey.physicalKey == raw);
    CHECK(event.payload.physicalKey.hardwareScanCode == scanCode);
    CHECK(event.payload.physicalKey.hidUsage == hidUsage);
    CHECK(event.payload.physicalKey.action == action);
    CHECK(event.payload.physicalKey.modifiersSnapshot == modifiers);
    CHECK(event.payload.physicalKey.lockState == locks);
}

void CheckRawButton(const AmclInputEvent& event, uint32_t raw,
                    uint32_t action) {
    CHECK(event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(event.header.source == AMCL_INPUT_SOURCE_UNKNOWN);
    CHECK(event.header.deviceClass == AMCL_INPUT_DEVICE_CLASS_UNKNOWN);
    CHECK(event.header.deviceId == kMouseDevice);
    CHECK(event.payload.pointerButton.nativeButton == raw);
    CHECK(event.payload.pointerButton.action == action);
}

void CheckRawDiagnosticDrop(const AmclInputEvent& event, uint32_t reason,
                            uint32_t originalType, uint32_t raw,
                            uint32_t action) {
    CHECK(event.header.eventType == AMCL_INPUT_EVENT_DIAGNOSTIC_DROP);
    CHECK(event.payload.diagnosticDrop.reason == reason);
    CHECK(event.payload.diagnosticDrop.originalEventType == originalType);
    CHECK(event.payload.diagnosticDrop.rawControl == raw);
    CHECK(event.payload.diagnosticDrop.action == action);
}

void CheckReconciliationDisabled() {
    const reconciliation::Summary value =
        trace::TestReconciliationSnapshot();
    CHECK(value.begun == 0u);
    CHECK(value.droppedBegin == 0u);
    CHECK(value.finalized == 0u);
    CHECK(value.unresolved == 0u);
    CHECK(value.duplicateFinalize == 0u);
    CHECK(value.unknownFinalize == 0u);
    CHECK(value.orderMismatch == 0u);
    CHECK(value.unexpectedMismatch == 0u);
    CHECK(value.exact == 0u);
    CHECK(value.unmapped == 0u);
    CHECK(value.quantized == 0u);
    CHECK(value.bridgeUnavailable == 0u);
    CHECK(value.legacyFallback == 0u);
    CHECK(value.gateRejected == 0u);
    CHECK(value.unknownButton == 0u);
    CHECK(value.typedHeldKeys == 0u);
    CHECK(value.legacyHeldKeys == 0u);
    CHECK(value.typedHeldButtons == 0u);
    CHECK(value.legacyHeldButtons == 0u);
    CHECK(value.mappedKeySymmetricDifference == 0u);
    CHECK(value.mappedButtonSymmetricDifference == 0u);
}

struct Recorder {
    GlfwInputAdapter* adapter = nullptr;
    std::vector<GlfwKeySinkEvent> keys;
    std::vector<GlfwButtonSinkEvent> buttons;
    std::vector<GlfwAbsoluteSinkEvent> absolutes;
    std::vector<GlfwSurfaceSinkEvent> surfaces;
    std::vector<uint32_t> pointerDispatchOrder;
    std::vector<GlfwUnsupportedMappingSinkEvent> unsupported;
    std::vector<GlfwDiagnosticDropSinkEvent> drops;
    bool callbackStateConsistent = true;

    static void Key(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.callbackStateConsistent &=
            self.adapter->IsKeyPressed(event.key) ==
                (event.action != GlfwInputAction::kRelease);
        self.keys.push_back(event);
    }

    static void Button(void* context, const GlfwButtonSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.callbackStateConsistent &=
            self.adapter->IsButtonPressed(event.button) ==
                (event.action != GlfwInputAction::kRelease);
        self.buttons.push_back(event);
        self.pointerDispatchOrder.push_back(AMCL_INPUT_EVENT_POINTER_BUTTON);
    }

    static void Absolute(void* context, const GlfwAbsoluteSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.absolutes.push_back(event);
        self.pointerDispatchOrder.push_back(AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    }

    static void Surface(void* context, const GlfwSurfaceSinkEvent& event) {
        static_cast<Recorder*>(context)->surfaces.push_back(event);
    }

    static void Unsupported(
            void* context, const GlfwUnsupportedMappingSinkEvent& event) {
        static_cast<Recorder*>(context)->unsupported.push_back(event);
    }

    static void Drop(void* context,
                     const GlfwDiagnosticDropSinkEvent& event) {
        static_cast<Recorder*>(context)->drops.push_back(event);
    }

    GlfwInputSink Sink() {
        GlfwInputSink sink{};
        sink.context = this;
        sink.key = Key;
        sink.button = Button;
        sink.absolute = Absolute;
        sink.surface = Surface;
        sink.unsupportedMapping = Unsupported;
        sink.diagnosticDrop = Drop;
        return sink;
    }
};

void CheckUnsupported(const GlfwUnsupportedMappingSinkEvent& event,
                      GlfwUnsupportedMappingKind kind, uint32_t raw,
                      uint32_t action, uint32_t scanCode = 0u,
                      uint32_t hidUsage = 0u) {
    CHECK(event.kind == kind);
    CHECK(event.rawControl == raw);
    CHECK(event.action == action);
    CHECK(event.deviceId ==
          (kind == GlfwUnsupportedMappingKind::kKey
               ? kKeyboardDevice : kMouseDevice));
    CHECK(event.hardwareScanCode == scanCode);
    CHECK(event.hidUsage == hidUsage);
    CHECK(event.sequence != 0u);
}

void CheckDrop(const GlfwDiagnosticDropSinkEvent& event, uint32_t reason,
               uint32_t originalType, uint32_t raw, uint32_t action,
               uint32_t scanCode = 0u, uint32_t hidUsage = 0u) {
    CHECK(event.reason == reason);
    CHECK(event.originalEventType == originalType);
    CHECK(event.rawControl == raw);
    CHECK(event.action == action);
    CHECK(event.deviceId ==
          (originalType == AMCL_INPUT_EVENT_PHYSICAL_KEY
               ? kKeyboardDevice : kMouseDevice));
    CHECK(event.hardwareScanCode == scanCode);
    CHECK(event.hidUsage == hidUsage);
    CHECK(event.sequence != 0u);
}

// A device change can commit a variable number of events (one release per owner
// of that device, or none at all), so its pump cannot assert a fixed count.
// Drain to empty and return how many events the adapter actually consumed.
uint64_t DrainPumpAll(GlfwInputAdapter& adapter) {
    uint64_t total = 0;
    for (;;) {
        const GlfwPumpResult result = adapter.Pump();
        CHECK(result.status == GlfwAdapterStatus::kOk);
        if (result.eventsDrained == 0u) return total;
        total += result.eventsDrained;
    }
}

void CheckPumpOne(GlfwInputAdapter& adapter) {
    const GlfwPumpResult result = adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kOk);
    CHECK(result.eventsDrained == 1u);
}

void TestTypedIngressThroughShippingGlfwMapper() {
    SelectTypedWithoutShadow();
    CHECK(!PlatformInputShadowEnabled());
    CHECK(PlatformInputPhysicalRouteUsesTyped());
    CHECK(PlatformInputCoreEnabled());

    PlatformInputSurfaceCreated(800u, 600u);
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);

    // This independent consumer observes the same shipping-core events that
    // feed the adapter. It proves ingress preserves OHOS identity rather than
    // inferring raw fields from the eventual GLFW callback.
    AmclInputConsumerHandle rawObserver = 0u;
    CHECK(api->openConsumer(&rawObserver) == AMCL_INPUT_OK);
    const AmclInputEvent rawBaseline = NextEvent(rawObserver, api, true);
    CHECK(rawBaseline.header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(rawBaseline.payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);

    // A selected typed route remains closed until the real GLFW adapter has
    // consumed its own baseline and submitted READY.  The ingress outcome is
    // explicit and the legacy callback is forbidden in shadow0 mode.
    CHECK(PlatformInputPhysicalKeyTransaction(
              kKnownOhosKey, 30u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, kKeyboardDevice, 65, 1, true,
              UnexpectedLegacyKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(gUnexpectedLegacyKeyCalls == 0u);
    CHECK(DrainAll(rawObserver, api).empty());
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(trace::TestPhysicalIngressOutcomeCount(
              trace::PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 1u);

    GlfwInputAdapter adapter;
    Recorder recorder;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(api, GlfwOhosInputMapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);

    // Pass deliberately wrong legacy mapped values. Typed+shadow0 must ignore
    // them and let the shipping backend map the preserved OHOS identities.
    CHECK(PlatformInputPhysicalKey(
              kKnownOhosKey, 30u, 4u, AMCL_INPUT_ACTION_DOWN,
              5u, 2u, kKeyboardDevice, 9999) == 0u);
    CheckPumpOne(adapter);
    CheckRawKey(NextEvent(rawObserver, api), kKnownOhosKey,
                AMCL_INPUT_ACTION_DOWN, 30u, 4u, 5u, 2u);
    CHECK(recorder.keys.size() == 1u);
    CHECK(recorder.keys[0].key == 65);
    CHECK(recorder.keys[0].scanCode == 30);
    CHECK(recorder.keys[0].action == GlfwInputAction::kPress);
    CHECK(recorder.keys[0].modifiers == 5u);
    CHECK(recorder.keys[0].lockState == 2u);
    CHECK(recorder.keys[0].deviceId == kKeyboardDevice);
    CHECK(adapter.IsKeyPressed(65));
    CHECK(Snapshot(api).heldControlCount == 1u);

    CHECK(PlatformInputPhysicalKey(
              kKnownOhosKey, 30u, 4u, AMCL_INPUT_ACTION_UP,
              0u, 2u, kKeyboardDevice, 9999) == 0u);
    CheckPumpOne(adapter);
    CheckRawKey(NextEvent(rawObserver, api), kKnownOhosKey,
                AMCL_INPUT_ACTION_UP, 30u, 4u, 0u, 2u);
    CHECK(recorder.keys.size() == 2u);
    CHECK(recorder.keys[1].key == 65);
    CHECK(recorder.keys[1].scanCode == 30);
    CHECK(recorder.keys[1].action == GlfwInputAction::kRelease);
    CHECK(!adapter.IsKeyPressed(65));
    CHECK(Snapshot(api).heldControlCount == 0u);

    CHECK(PlatformInputPointerButton(
              kMouseDevice, kKnownNativeButton,
              AMCL_INPUT_ACTION_DOWN, 9999) == 0u);
    CheckPumpOne(adapter);
    CheckRawButton(NextEvent(rawObserver, api), kKnownNativeButton,
                   AMCL_INPUT_ACTION_DOWN);
    CHECK(recorder.buttons.size() == 1u);
    CHECK(recorder.buttons[0].button == 2);
    CHECK(recorder.buttons[0].action == GlfwInputAction::kPress);
    CHECK(recorder.buttons[0].deviceId == kMouseDevice);
    CHECK(adapter.IsButtonPressed(2));
    CHECK(Snapshot(api).heldControlCount == 1u);

    CHECK(PlatformInputPointerButton(
              kMouseDevice, kKnownNativeButton,
              AMCL_INPUT_ACTION_UP, 9999) == 0u);
    CheckPumpOne(adapter);
    CheckRawButton(NextEvent(rawObserver, api), kKnownNativeButton,
                   AMCL_INPUT_ACTION_UP);
    CHECK(recorder.buttons.size() == 2u);
    CHECK(recorder.buttons[1].button == 2);
    CHECK(recorder.buttons[1].action == GlfwInputAction::kRelease);
    CHECK(!adapter.IsButtonPressed(2));
    CHECK(Snapshot(api).heldControlCount == 0u);

    const size_t ordinaryKeyCount = recorder.keys.size();
    const size_t ordinaryButtonCount = recorder.buttons.size();

    CHECK(PlatformInputPhysicalKey(
              kUnknownOhosKey, 333u, 444u, AMCL_INPUT_ACTION_DOWN,
              7u, 3u, kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    CheckRawKey(NextEvent(rawObserver, api), kUnknownOhosKey,
                AMCL_INPUT_ACTION_DOWN, 333u, 444u, 7u, 3u);
    CHECK(recorder.unsupported.size() == 1u);
    CheckUnsupported(recorder.unsupported[0],
                     GlfwUnsupportedMappingKind::kKey,
                     kUnknownOhosKey, AMCL_INPUT_ACTION_DOWN, 333u, 444u);
    CHECK(recorder.drops.empty());
    CHECK(recorder.keys.size() == ordinaryKeyCount);
    CHECK(Snapshot(api).heldControlCount == 1u);

    CHECK(PlatformInputPhysicalKey(
              kUnknownOhosKey, 333u, 444u, AMCL_INPUT_ACTION_UP,
              0u, 3u, kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    CheckRawKey(NextEvent(rawObserver, api), kUnknownOhosKey,
                AMCL_INPUT_ACTION_UP, 333u, 444u, 0u, 3u);
    CHECK(recorder.unsupported.size() == 2u);
    CheckUnsupported(recorder.unsupported[1],
                     GlfwUnsupportedMappingKind::kKey,
                     kUnknownOhosKey, AMCL_INPUT_ACTION_UP, 333u, 444u);
    CHECK(recorder.drops.size() == 1u);
    CheckDrop(recorder.drops[0],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, kUnknownOhosKey,
              AMCL_INPUT_ACTION_UP, 333u, 444u);
    CHECK(recorder.keys.size() == ordinaryKeyCount);
    CHECK(Snapshot(api).heldControlCount == 0u);

    CHECK(PlatformInputPointerButton(
              kMouseDevice, kUnknownNativeButton,
              AMCL_INPUT_ACTION_DOWN, 0) == 0u);
    CheckPumpOne(adapter);
    CheckRawButton(NextEvent(rawObserver, api), kUnknownNativeButton,
                   AMCL_INPUT_ACTION_DOWN);
    CHECK(recorder.unsupported.size() == 3u);
    CheckUnsupported(recorder.unsupported[2],
                     GlfwUnsupportedMappingKind::kButton,
                     kUnknownNativeButton, AMCL_INPUT_ACTION_DOWN);
    CHECK(recorder.drops.size() == 1u);
    CHECK(recorder.buttons.size() == ordinaryButtonCount);
    CHECK(Snapshot(api).heldControlCount == 1u);

    CHECK(PlatformInputPointerButton(
              kMouseDevice, kUnknownNativeButton,
              AMCL_INPUT_ACTION_UP, 0) == 0u);
    CheckPumpOne(adapter);
    CheckRawButton(NextEvent(rawObserver, api), kUnknownNativeButton,
                   AMCL_INPUT_ACTION_UP);
    CHECK(recorder.unsupported.size() == 4u);
    CheckUnsupported(recorder.unsupported[3],
                     GlfwUnsupportedMappingKind::kButton,
                     kUnknownNativeButton, AMCL_INPUT_ACTION_UP);
    CHECK(recorder.drops.size() == 2u);
    CheckDrop(recorder.drops[1],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP,
              AMCL_INPUT_EVENT_POINTER_BUTTON, kUnknownNativeButton,
              AMCL_INPUT_ACTION_UP);
    CHECK(recorder.buttons.size() == ordinaryButtonCount);
    CHECK(Snapshot(api).heldControlCount == 0u);

    // A second UP for the already released known key is ownerless in the core
    // itself. Unlike the two mapper-local drops above, this produces the
    // backend-neutral diagnostic event observed by every real consumer.
    CHECK(PlatformInputPhysicalKey(
              kKnownOhosKey, 30u, 4u, AMCL_INPUT_ACTION_UP,
              0u, 2u, kKeyboardDevice, 9999) == 0u);
    CheckPumpOne(adapter);
    CheckRawDiagnosticDrop(
        NextEvent(rawObserver, api),
        AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
        AMCL_INPUT_EVENT_PHYSICAL_KEY, kKnownOhosKey,
        AMCL_INPUT_ACTION_UP);
    CHECK(recorder.drops.size() == 3u);
    CheckDrop(recorder.drops[2],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, kKnownOhosKey,
              AMCL_INPUT_ACTION_UP, 30u, 4u);
    CHECK(recorder.keys.size() == ordinaryKeyCount);
    CHECK(Snapshot(api).heldControlCount == 0u);

    const trace::CoreDiagnosticSummary diagnostics =
        trace::TestCoreDiagnosticSnapshot();
    // Surface creation is currently explicit about its unverified transform;
    // mapper-local drops are reported only by the GLFW sink, while the final
    // core-authored ownerless UP is counted by the maintenance consumer.
    CHECK(diagnostics.unsupported == 1u);
    CHECK(diagnostics.diagnosticDrops == 1u);

    CHECK(recorder.callbackStateConsistent);
    CheckReconciliationDisabled();

    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(!adapter.HasConsumer());
    const auto retired = DrainAll(rawObserver, api);
    CHECK(HasResetReason(retired, AMCL_INPUT_RESET_BACKEND_RETIRED));

    // RETIRE removes admission before the consumer handle is released. A
    // later physical edge is rejected, remains invisible to the observer, and
    // cannot escape through the legacy callback.
    CHECK(PlatformInputPhysicalKeyTransaction(
              kKnownOhosKey, 30u, 4u, AMCL_INPUT_ACTION_DOWN,
              0u, 0u, kKeyboardDevice, 65, 1, true,
              UnexpectedLegacyKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(gUnexpectedLegacyKeyCalls == 0u);
    CHECK(DrainAll(rawObserver, api).empty());
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(trace::TestPhysicalIngressOutcomeCount(
              trace::PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 2u);

    CHECK(api->closeConsumer(rawObserver) == AMCL_INPUT_OK);
    PlatformInputSurfaceDestroyed();
    CheckReconciliationDisabled();
}

// Phase 3.3: the platform producer now publishes a real deviceId and a real
// platform latch snapshot. Two facts have to hold simultaneously and neither is
// provable by the pass-through assertions above:
//
//   1. Field-gap accounting must be driven by the VALID bit, not by "locks==0".
//      A correctly reporting device with all three latches off sends
//      VALID|0|0|0; counting that as missing would make the diagnostic
//      permanently non-zero and hide a genuine regression.
//   2. Two physical keyboards holding the same raw key must own two independent
//      core owners, and the GLFW aggregate must stay pressed until the last one
//      releases. This is the exact §10.1 case that a deviceId-less producer
//      could not express.
//
// Reading conventions for this function:
//   - Trace counters are process-global and accumulate across test functions,
//     so every counter check below is a delta against a baseline captured in
//     this scope, never an absolute value.
//   - `PlatformInputPhysicalKey(...) == 0u` is NOT a submission-accepted check.
//     On the typed route that function returns no reconciliation observation
//     token by contract, so 0 is the required value and carries no information
//     about core acceptance. Acceptance is proved by heldControlCount, by the
//     recorder contents and by the missing-field deltas.
void TestPlatformIdentityAndLatchAccounting() {
    SelectTypedWithoutShadow();
    CHECK(PlatformInputPhysicalRouteUsesTyped());

    PlatformInputSurfaceCreated(800u, 600u);
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);

    GlfwInputAdapter adapter;
    Recorder recorder;
    recorder.adapter = &adapter;
    // Open consumes the adapter's own fresh baseline RESET; the first Pump
    // below therefore drains exactly the physical edge submitted after it.
    CHECK(adapter.Open(api, GlfwOhosInputMapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);

    constexpr uint32_t kLatchValid = AMCL_INPUT_LOCK_STATE_VALID;
    constexpr uint32_t kLatchCapsOn =
        AMCL_INPUT_LOCK_STATE_VALID | AMCL_INPUT_LOCK_STATE_CAPS;
    constexpr uint64_t kSecondKeyboard = 303u;

    // (1a) Real identity + VALID latch snapshot with every latch off: neither
    // the device nor the latch gap counter may move.
    trace::MissingFieldSummary before = trace::TestMissingFieldSnapshot();
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, kLatchValid,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    trace::MissingFieldSummary after = trace::TestMissingFieldSnapshot();
    CHECK(after.device == before.device);
    CHECK(after.lockState == before.lockState);
    // hardwareScanCode/hidUsage are still unavailable from ArkUI KeyEvent, so
    // this counter is expected to keep moving until P0-7 is fully resolved.
    CHECK(after.scanCode == before.scanCode + 1u);
    CHECK(adapter.IsKeyPressed(65));

    // (1b) A VALID snapshot that reports Caps latched reaches the backend
    // verbatim; the adapter must not re-derive it from held keys.
    before = after;
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_UP, 0u, kLatchCapsOn,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    after = trace::TestMissingFieldSnapshot();
    CHECK(after.lockState == before.lockState);
    CHECK(!adapter.IsKeyPressed(65));
    CHECK(recorder.keys.back().lockState == kLatchCapsOn);

    // (1c) An absent latch snapshot is still counted, and an absent deviceId is
    // still counted, so a producer regression stays observable.
    before = after;
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, 0u,
                                   0u, 65) == 0u);
    CheckPumpOne(adapter);
    after = trace::TestMissingFieldSnapshot();
    CHECK(after.lockState == before.lockState + 1u);
    CHECK(after.device == before.device + 1u);
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_UP, 0u, 0u,
                                   0u, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(!adapter.IsKeyPressed(65));
    CHECK(Snapshot(api).heldControlCount == 0u);

    // (1d) A latch value carrying bits outside the ABI mask is the realistic
    // "modifiers reached the adjacent locks parameter" mistake. It must be
    // downgraded to unknown (counted as missing) and reported as unsupported,
    // never partially trusted: the payload the backend sees has to be 0 so no
    // adapter can read a fabricated Caps/Num latch out of a modifier value.
    before = trace::TestMissingFieldSnapshot();
    const trace::CoreDiagnosticSummary diagBefore =
        trace::TestCoreDiagnosticSnapshot();
    constexpr uint32_t kGlfwModCapsLockValue = 0x0010u;  // outside the mask
    CHECK((kGlfwModCapsLockValue & ~AMCL_INPUT_LOCK_STATE_MASK) != 0u);
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u,
                                   kGlfwModCapsLockValue,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    after = trace::TestMissingFieldSnapshot();
    CHECK(after.lockState == before.lockState + 1u);
    CHECK(trace::TestCoreDiagnosticSnapshot().unsupported ==
          diagBefore.unsupported + 1u);
    CHECK(recorder.keys.back().lockState == 0u);
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_UP, 0u, kLatchValid,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(Snapshot(api).heldControlCount == 0u);

    // (2) Two keyboards, same raw key, same mapped GLFW key.
    const size_t keysBeforeAggregate = recorder.keys.size();
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, kLatchValid,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, kLatchValid,
                                   kSecondKeyboard, 65) == 0u);
    CheckPumpOne(adapter);
    // Core keeps one owner per (deviceId, control): the second DOWN is a real
    // acquisition, not a repeat.
    CHECK(Snapshot(api).heldControlCount == 2u);
    // The GLFW plane is a binary aggregate: exactly one PRESS is emitted for
    // the first contributor and the second must not produce another PRESS edge.
    CHECK(recorder.keys.size() == keysBeforeAggregate + 1u);
    CHECK(recorder.keys.back().action == GlfwInputAction::kPress);
    CHECK(adapter.IsKeyPressed(65));

    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_UP, 0u, kLatchValid,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    // First release must not end the aggregate while the other keyboard holds.
    CHECK(Snapshot(api).heldControlCount == 1u);
    CHECK(recorder.keys.size() == keysBeforeAggregate + 1u);
    CHECK(adapter.IsKeyPressed(65));

    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_UP, 0u, kLatchValid,
                                   kSecondKeyboard, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(recorder.keys.size() == keysBeforeAggregate + 2u);
    CHECK(recorder.keys.back().action == GlfwInputAction::kRelease);
    CHECK(!adapter.IsKeyPressed(65));

    // (3) Device removal releases only that device's owners (§6.4 / §10.1).
    // Both keyboards hold the same mapped key again; removing one must leave the
    // other pressed on every plane, and removing the second must end it.
    const size_t keysBeforeRemoval = recorder.keys.size();
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, kLatchValid,
                                   kKeyboardDevice, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(PlatformInputPhysicalKey(kKnownOhosKey, 0u, 0u,
                                   AMCL_INPUT_ACTION_DOWN, 0u, kLatchValid,
                                   kSecondKeyboard, 65) == 0u);
    CheckPumpOne(adapter);
    CHECK(Snapshot(api).heldControlCount == 2u);
    CHECK(recorder.keys.size() == keysBeforeRemoval + 1u);

    // A removal for deviceId 0 must be rejected outright: 0 is the bucket every
    // identity-less edge shares, so releasing it would cancel unrelated owners.
    const trace::MissingFieldSummary beforeBadRemoval =
        trace::TestMissingFieldSnapshot();
    PlatformInputDeviceChanged(0u, false, 0u);
    CHECK(trace::TestMissingFieldSnapshot().device ==
          beforeBadRemoval.device + 1u);
    CHECK(Snapshot(api).heldControlCount == 2u);
    CHECK(DrainPumpAll(adapter) == 0u);

    // Unknown capability bits are dropped, not forwarded. ADDED must never
    // touch held state either.
    PlatformInputDeviceChanged(kSecondKeyboard, true, 0x8000u);
    (void)DrainPumpAll(adapter);
    CHECK(Snapshot(api).heldControlCount == 2u);

    PlatformInputDeviceChanged(kKeyboardDevice, false, 0u);
    (void)DrainPumpAll(adapter);
    // Only the removed device's owner is gone; the other keyboard still holds,
    // so the GLFW aggregate must not have emitted a RELEASE yet.
    CHECK(Snapshot(api).heldControlCount == 1u);
    CHECK(adapter.IsKeyPressed(65));
    CHECK(recorder.keys.size() == keysBeforeRemoval + 1u);

    PlatformInputDeviceChanged(kSecondKeyboard, false, 0u);
    (void)DrainPumpAll(adapter);
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(!adapter.IsKeyPressed(65));
    CHECK(recorder.keys.size() == keysBeforeRemoval + 2u);
    CHECK(recorder.keys.back().action == GlfwInputAction::kRelease);

    // Repeating the removal is idempotent: no owners, no new edges.
    PlatformInputDeviceChanged(kSecondKeyboard, false, 0u);
    (void)DrainPumpAll(adapter);
    CHECK(Snapshot(api).heldControlCount == 0u);
    CHECK(recorder.keys.size() == keysBeforeRemoval + 2u);

    CHECK(recorder.callbackStateConsistent);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
    PlatformInputSurfaceDestroyed();
}

void TestNativeAbsoluteBatchThroughCoreAndAdapter() {
    SelectTypedWithoutShadow();
    CHECK(PlatformInputNativeAbsoluteRouteUsesTyped());

    constexpr uint64_t kPublicationGeneration = 77u;
    PlatformInputSurfaceCreated(800u, 600u, kPublicationGeneration);
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) != 0u);

    AmclInputConsumerHandle rawObserver = 0u;
    CHECK(api->openConsumer(&rawObserver) == AMCL_INPUT_OK);
    const auto baseline = DrainAll(rawObserver, api);
    CHECK(baseline.size() == 2u);
    CHECK(baseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(baseline[1].payload.surface.publicationGeneration ==
          kPublicationGeneration);
    const uint64_t surfaceEpoch = baseline[1].header.surfaceEpoch;
    CHECK(surfaceEpoch != 0u);

    GlfwInputAdapter adapter;
    Recorder recorder;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(api, GlfwOhosInputMapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    // Open records the replay before READY but deliberately defers sink code
    // until the first Pump leaves its non-reentrant startup path.
    CHECK(recorder.surfaces.empty());
    recorder.pointerDispatchOrder.clear();

    CHECK(PlatformInputNativeSurfaceMouseTransaction(
              kPublicationGeneration, 12.5, 13.5, kMouseDevice, 1u,
              AMCL_INPUT_ACTION_DOWN, true) ==
          PlatformInputNativeMouseResult::Submitted);
    GlfwPumpResult pump = adapter.Pump();
    CHECK(pump.status == GlfwAdapterStatus::kOk);
    CHECK(pump.eventsDrained == 2u);
    CHECK(recorder.surfaces.size() == 1u);
    CHECK(recorder.surfaces[0].surface.publicationGeneration ==
          kPublicationGeneration);

    const auto rawDown = DrainAll(rawObserver, api);
    CHECK(rawDown.size() == 2u);
    CHECK(rawDown[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(rawDown[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(rawDown[1].header.sequence == rawDown[0].header.sequence + 1u);
    CHECK(rawDown[0].header.deviceId == kMouseDevice);
    CHECK(rawDown[1].header.deviceId == kMouseDevice);
    CHECK(rawDown[0].header.surfaceEpoch == surfaceEpoch);
    CHECK(rawDown[1].header.surfaceEpoch == surfaceEpoch);
    CHECK((rawDown[1].header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u);

    CHECK(recorder.pointerDispatchOrder.size() == 2u);
    CHECK(recorder.pointerDispatchOrder[0] ==
          AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(recorder.pointerDispatchOrder[1] ==
          AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(recorder.absolutes.size() == 1u);
    CHECK(recorder.absolutes[0].x == 12.5);
    CHECK(recorder.absolutes[0].y == 13.5);
    CHECK(recorder.absolutes[0].publicationGeneration ==
          kPublicationGeneration);
    CHECK(recorder.absolutes[0].surfaceEpoch == surfaceEpoch);
    CHECK(recorder.buttons.size() == 1u);
    CHECK(recorder.buttons[0].button == 0);
    CHECK(recorder.buttons[0].requiresAbsoluteAuthorization);
    CHECK(recorder.buttons[0].sequence ==
          recorder.absolutes[0].sequence + 1u);
    CHECK(recorder.buttons[0].surfaceEpoch == surfaceEpoch);
    CHECK(adapter.IsButtonPressed(0));

    CHECK(PlatformInputNativeSurfaceMouseTransaction(
              kPublicationGeneration, 15.0, 16.0, kMouseDevice, 1u,
              AMCL_INPUT_ACTION_UP, true) ==
          PlatformInputNativeMouseResult::Submitted);
    pump = adapter.Pump();
    CHECK(pump.status == GlfwAdapterStatus::kOk);
    CHECK(pump.eventsDrained == 2u);
    const auto rawUp = DrainAll(rawObserver, api);
    CHECK(rawUp.size() == 2u);
    CHECK(rawUp[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(rawUp[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(rawUp[1].header.sequence == rawUp[0].header.sequence + 1u);
    CHECK(recorder.pointerDispatchOrder.size() == 4u);
    CHECK(recorder.pointerDispatchOrder[2] ==
          AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(recorder.pointerDispatchOrder[3] ==
          AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(recorder.buttons.size() == 2u);
    CHECK(recorder.buttons[1].action == GlfwInputAction::kRelease);
    CHECK(recorder.buttons[1].requiresAbsoluteAuthorization);
    CHECK(!adapter.IsButtonPressed(0));
    CHECK(recorder.callbackStateConsistent);

    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(HasResetReason(DrainAll(rawObserver, api),
                         AMCL_INPUT_RESET_BACKEND_RETIRED));
    CHECK(api->closeConsumer(rawObserver) == AMCL_INPUT_OK);
    PlatformInputSurfaceDestroyed(kPublicationGeneration);
}

}  // namespace

int main() {
    TestTypedIngressThroughShippingGlfwMapper();
    TestPlatformIdentityAndLatchAccounting();
    TestNativeAbsoluteBatchThroughCoreAndAdapter();
    std::cout << "platform_input_typed_glfw_e2e_test: PASS\n";
    return 0;
}

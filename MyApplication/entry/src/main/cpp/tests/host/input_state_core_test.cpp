#include "input_state_core.h"
#include "text_utf8_codec.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <thread>
#include <vector>

extern "C" int amcl_input_c_abi_smoke(void);
void RunInputReconciliationTests();

static_assert(sizeof(AmclInputEventHeader) == 72, "header ABI");
static_assert(offsetof(AmclInputEventHeader, deviceClass) == 44,
              "device class ABI");
static_assert(sizeof(AmclInputSurfacePayload) == 32, "surface ABI");
static_assert(offsetof(AmclInputSurfacePayload, validFields) == 20,
              "surface validity ABI");
static_assert(sizeof(AmclInputDiagnosticDropPayload) == 48,
              "diagnostic drop ABI");
static_assert(sizeof(AmclInputBackendConsumerStatePayload) == 48,
              "backend consumer state ABI");
static_assert(sizeof(AmclInputSurfaceContextPayload) == 48,
              "surface context ABI");
static_assert(sizeof(AmclInputTextSessionPayload) == 48,
              "text session ABI");
static_assert(offsetof(AmclInputTextCommitPayload, textSessionId) == 16,
              "text session id ABI");
static_assert(offsetof(AmclInputSurfaceContextPayload, generation) == 40,
              "surface context generation ABI");
static_assert(offsetof(AmclInputDiagnosticDropPayload, rawControl) == 8,
              "diagnostic raw-control ABI");
static_assert(sizeof(AmclInputEvent) == 120, "event ABI");
static_assert(sizeof(AmclInputHostApiV1) == 144, "table ABI");
static_assert(offsetof(AmclInputHostApiV1, beginSession) == 24, "table prefix ABI");

namespace {
const AmclInputHostApiV1* gApi = nullptr;
constexpr uint64_t kTextSessionId = 0x54455854u;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclInputEvent Event(uint32_t type, uint64_t epoch = 0) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = type;
    event.header.sessionEpoch = epoch;
    if (type == AMCL_INPUT_EVENT_TEXT_COMMIT) {
        event.header.source = AMCL_INPUT_SOURCE_IME;
        event.payload.textCommit.textSessionId = kTextSessionId;
    } else if (type == AMCL_INPUT_EVENT_TEXT_EDITING) {
        event.header.source = AMCL_INPUT_SOURCE_IME;
        event.payload.textEditing.textSessionId = kTextSessionId;
    } else if (type == AMCL_INPUT_EVENT_TEXT_CANDIDATES) {
        event.header.source = AMCL_INPUT_SOURCE_IME;
        event.payload.textCandidates.textSessionId = kTextSessionId;
    } else if (type == AMCL_INPUT_EVENT_TEXT_SELECTION) {
        event.header.source = AMCL_INPUT_SOURCE_IME;
        event.payload.textSelection.textSessionId = kTextSessionId;
    }
    return event;
}

AmclInputEvent TextSession(uint32_t change,
                           uint64_t id = kTextSessionId,
                           uint64_t epoch = 0u) {
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED, epoch);
    event.header.source = AMCL_INPUT_SOURCE_IME;
    event.payload.textSession.textSessionId = id;
    event.payload.textSession.change = change;
    event.payload.textSession.reason =
        AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    return event;
}

AmclInputEvent Key(uint64_t device, uint32_t key, uint32_t action,
                   uint64_t epoch = 0) {
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, epoch);
    event.header.deviceId = device;
    event.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
    event.payload.physicalKey.physicalKey = key;
    event.payload.physicalKey.hardwareScanCode = key + 100u;
    event.payload.physicalKey.action = action;
    return event;
}

AmclInputEvent Button(uint64_t device, uint32_t button, uint32_t action,
                      uint64_t epoch = 0,
                      uint32_t deviceClass =
                          AMCL_INPUT_DEVICE_CLASS_UNKNOWN) {
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_BUTTON, epoch);
    event.header.deviceId = device;
    event.header.source = AMCL_INPUT_SOURCE_MOUSE;
    event.header.deviceClass = deviceClass;
    event.payload.pointerButton.nativeButton = button;
    event.payload.pointerButton.action = action;
    return event;
}

AmclInputEvent BackendControl(uint32_t state,
                              AmclInputConsumerHandle consumer,
                              uint64_t epoch,
                              uint64_t baselineSequence = 0u,
                              uint32_t backend =
                                  AMCL_INPUT_BACKEND_GLFW_PHYSICAL) {
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE, epoch);
    event.payload.backendConsumerState.state = state;
    event.payload.backendConsumerState.backend = backend;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baselineSequence;
    return event;
}

AmclInputEvent CoreBaseline(amcl::input::InputStateCore& core,
                            AmclInputConsumerHandle consumer) {
    AmclInputEvent baseline{};
    CHECK(core.NextEvent(consumer, &baseline) == AMCL_INPUT_OK);
    CHECK(baseline.header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline.payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    return baseline;
}

void CheckDrop(const AmclInputEvent& event, uint32_t reason,
               uint32_t originalEventType, uint64_t device,
               uint32_t rawControl, uint32_t action,
               uint32_t hardwareScanCode, uint32_t hidUsage) {
    CHECK(event.header.eventType == AMCL_INPUT_EVENT_DIAGNOSTIC_DROP);
    CHECK(event.header.deviceId == device);
    CHECK(event.payload.diagnosticDrop.reason == reason);
    CHECK(event.payload.diagnosticDrop.originalEventType == originalEventType);
    CHECK(event.payload.diagnosticDrop.rawControl == rawControl);
    CHECK(event.payload.diagnosticDrop.action == action);
    CHECK(event.payload.diagnosticDrop.hardwareScanCode == hardwareScanCode);
    CHECK(event.payload.diagnosticDrop.hidUsage == hidUsage);
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
    AmclInputEvent event{};
    while (gApi->nextEvent(consumer, &event) == AMCL_INPUT_OK) {
        events.push_back(event);
    }
    return events;
}

AmclInputSnapshotV1 CoreSnapshot(amcl::input::InputStateCore& core) {
    AmclInputSnapshotV1 value{};
    value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    value.structSize = static_cast<uint16_t>(sizeof(value));
    CHECK(core.GetSnapshot(&value) == AMCL_INPUT_OK);
    return value;
}

std::vector<AmclInputEvent> CoreDrain(amcl::input::InputStateCore& core,
                                      AmclInputConsumerHandle consumer) {
    std::vector<AmclInputEvent> events;
    AmclInputEvent event{};
    while (core.NextEvent(consumer, &event) == AMCL_INPUT_OK) {
        events.push_back(event);
    }
    return events;
}

amcl::input::CoreObservabilityV1 CoreObs(amcl::input::InputStateCore& core) {
    amcl::input::CoreObservabilityV1 value{};
    CHECK(core.GetObservability(&value) == AMCL_INPUT_OK);
    return value;
}

void CheckSnapshotStateEqual(const AmclInputSnapshotV1& actual,
                             const AmclInputSnapshotV1& expected) {
    CHECK(actual.captureRequested == expected.captureRequested);
    CHECK(actual.sessionEpoch == expected.sessionEpoch);
    CHECK(actual.focusEpoch == expected.focusEpoch);
    CHECK(actual.surfaceEpoch == expected.surfaceEpoch);
    CHECK(actual.heldControlCount == expected.heldControlCount);
    CHECK(actual.consumerCount == expected.consumerCount);
    CHECK(actual.queuedEventCount == expected.queuedEventCount);
    CHECK(actual.overflowResetCount == expected.overflowResetCount);
    CHECK(actual.blobBytes == expected.blobBytes);
    CHECK(actual.focused == expected.focused);
    CHECK(actual.captureActive == expected.captureActive);
    CHECK(actual.captureReason == expected.captureReason);
    CHECK(actual.sessionActive == expected.sessionActive);
}

struct Session {
    AmclInputConsumerHandle consumer = 0;
    uint64_t epoch = 0;
    Session() {
        CHECK(gApi->openConsumer(&consumer) == AMCL_INPUT_OK);
        CHECK(gApi->beginSession(&epoch) == AMCL_INPUT_OK);
        CHECK(Drain(consumer).empty());
    }
    ~Session() {
        if (Snapshot().sessionActive != 0u) {
            const uint64_t active = Snapshot().sessionEpoch;
            const int32_t status = gApi->endSession(active);
            CHECK(status == AMCL_INPUT_OK || status == AMCL_INPUT_OVERFLOW_RESET);
            Drain(consumer);
        }
        CHECK(gApi->closeConsumer(consumer) == AMCL_INPUT_OK);
    }
};

void TestAbiAndFirstBegin() {
    CHECK(amcl_input_c_abi_smoke() == 0);
    CHECK(gApi == amclInputGetHostApiV1());
    CHECK(gApi->magic == AMCL_INPUT_HOST_API_MAGIC);
    CHECK(gApi->abiVersion == AMCL_INPUT_HOST_API_VERSION);
    CHECK(gApi->generation == AMCL_INPUT_HOST_API_GENERATION);
    CHECK(gApi->structSize == sizeof(*gApi));
    const uint32_t requiredCapabilities =
        AMCL_INPUT_CAP_TYPED_EVENTS | AMCL_INPUT_CAP_MULTI_CONSUMER |
        AMCL_INPUT_CAP_OVERFLOW_RESET | AMCL_INPUT_CAP_OWNED_TEXT_PACKETS |
        AMCL_INPUT_CAP_SESSION_EPOCHS | AMCL_INPUT_CAP_HOST_GENERATION |
        AMCL_INPUT_CAP_EXPECTED_EPOCHS | AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS |
        AMCL_INPUT_CAP_CONSUMER_BASELINE |
        AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY |
        AMCL_INPUT_CAP_DIAGNOSTIC_DROP |
        AMCL_INPUT_CAP_BACKEND_CONSUMER_READY |
        AMCL_INPUT_CAP_DEVICE_CLASS |
        AMCL_INPUT_CAP_SURFACE_CONTEXT |
        AMCL_INPUT_CAP_TEXT_INPUT_SESSION;
    CHECK((gApi->capabilityBits & requiredCapabilities) == requiredCapabilities);
    CHECK((gApi->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) == 0u);
    CHECK(gApi->beginSession && gApi->endSession && gApi->submitEvent &&
          gApi->submitBatch && gApi->submitTextPacket &&
          gApi->publishSurface && gApi->publishFocus &&
          gApi->publishDeviceChange && gApi->requestReset &&
          gApi->openConsumer && gApi->nextEvent &&
          gApi->readPacketBlob && gApi->releasePacket &&
          gApi->closeConsumer && gApi->getSnapshot);
    AmclInputSnapshotV1 bad{};
    CHECK(gApi->getSnapshot(&bad) == AMCL_INPUT_ERROR_ABI_MISMATCH);
    AmclInputEvent futureWithoutSession = Event(0x80000000u);
    CHECK(gApi->submitEvent(&futureWithoutSession) == AMCL_INPUT_OK);
    AmclInputEvent invalidType = Event(0u);
    CHECK(gApi->submitEvent(&invalidType) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    AmclInputConsumerHandle consumer = 0;
    CHECK(gApi->openConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(gApi->beginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(epoch != 0u);
    CHECK(Drain(consumer).empty());  // no epoch-0 reset on first Begin
    CHECK(gApi->endSession(epoch) == AMCL_INPUT_OK);
    const auto ending = Drain(consumer);
    CHECK(ending.size() == 1u);
    CHECK(ending[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(ending[0].payload.reset.closingEpoch == epoch);
    AmclInputEvent unused{};
    CHECK(gApi->nextEvent(consumer, &unused) == AMCL_INPUT_ERROR_STALE);
    CHECK(gApi->closeConsumer(consumer) == AMCL_INPUT_OK);
}

void TestTwoDevicesAndTime() {
    Session session;
    AmclInputEvent events[] = {
        Key(11, 87, AMCL_INPUT_ACTION_DOWN),
        Key(22, 87, AMCL_INPUT_ACTION_DOWN),
        Key(11, 87, AMCL_INPUT_ACTION_UP),
        Key(22, 87, AMCL_INPUT_ACTION_UP),
    };
    for (const auto& event : events) CHECK(gApi->submitEvent(&event) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 0u);
    const auto output = Drain(session.consumer);
    CHECK(output.size() == 4u);
    CHECK(output[0].header.deviceId == 11u && output[1].header.deviceId == 22u);
    CHECK(output[2].header.deviceId == 11u && output[3].header.deviceId == 22u);
    for (size_t i = 1; i < output.size(); ++i) {
        CHECK(output[i].header.sequence > output[i - 1].header.sequence);
        CHECK(output[i].header.monotonicTimeNs >= output[i - 1].header.monotonicTimeNs);
    }
}

void TestRepeat() {
    Session session;
    const AmclInputEvent down = Key(31, 87, AMCL_INPUT_ACTION_DOWN);
    const AmclInputEvent repeat = Key(31, 87, AMCL_INPUT_ACTION_REPEAT);
    const AmclInputEvent up = Key(31, 87, AMCL_INPUT_ACTION_UP);
    // A late repeat after reset/device loss has no owner. It must remain
    // observable as a diagnostic without resurrecting held state.
    CHECK(gApi->submitEvent(&repeat) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 0u);
    const auto dropped = Drain(session.consumer);
    CHECK(dropped.size() == 1u);
    CheckDrop(dropped[0],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, 31u, 87u,
              AMCL_INPUT_ACTION_REPEAT, 187u, 0u);
    CHECK(dropped[0].header.source == AMCL_INPUT_SOURCE_KEYBOARD);
    CHECK(gApi->submitEvent(&down) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&down) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&repeat) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 1u);
    CHECK(gApi->submitEvent(&up) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 0u);
    const auto output = Drain(session.consumer);
    CHECK(output.size() == 4u);
    CHECK(output[0].payload.physicalKey.action == AMCL_INPUT_ACTION_DOWN);
    CHECK(output[1].payload.physicalKey.action == AMCL_INPUT_ACTION_REPEAT);
    CHECK(output[2].payload.physicalKey.action == AMCL_INPUT_ACTION_REPEAT);
    CHECK(output[3].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
}

void TestOwnerlessAndDuplicateDiagnostics() {
    Session session;
    const AmclInputEvent keyUp = Key(41u, 91u, AMCL_INPUT_ACTION_UP);
    const AmclInputEvent buttonUp =
        Button(42u, 8u, AMCL_INPUT_ACTION_UP);
    const AmclInputEvent buttonDown =
        Button(42u, 8u, AMCL_INPUT_ACTION_DOWN);

    CHECK(gApi->submitEvent(&keyUp) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&buttonUp) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&buttonDown) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 1u);
    CHECK(gApi->submitEvent(&buttonDown) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 1u);
    CHECK(gApi->submitEvent(&buttonUp) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 0u);

    const auto output = Drain(session.consumer);
    CHECK(output.size() == 5u);
    CheckDrop(output[0], AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, 41u, 91u,
              AMCL_INPUT_ACTION_UP, 191u, 0u);
    CheckDrop(output[1], AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP,
              AMCL_INPUT_EVENT_POINTER_BUTTON, 42u, 8u,
              AMCL_INPUT_ACTION_UP, 0u, 0u);
    CHECK(output[2].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(output[2].payload.pointerButton.action == AMCL_INPUT_ACTION_DOWN);
    CheckDrop(output[3],
              AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN,
              AMCL_INPUT_EVENT_POINTER_BUTTON, 42u, 8u,
              AMCL_INPUT_ACTION_DOWN, 0u, 0u);
    CHECK(output[4].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(output[4].payload.pointerButton.action == AMCL_INPUT_ACTION_UP);
    for (size_t i = 1; i < output.size(); ++i) {
        CHECK(output[i].header.sequence > output[i - 1].header.sequence);
    }

    // Producers cannot spoof authoritative core evidence.
    AmclInputEvent spoof = Event(AMCL_INPUT_EVENT_DIAGNOSTIC_DROP);
    spoof.payload.diagnosticDrop.reason =
        AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP;
    CHECK(gApi->submitEvent(&spoof) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CHECK(Drain(session.consumer).empty());
}

void TestEpochFocusAndUnknown() {
    Session session;
    AmclInputEvent stale = Key(1, 1, AMCL_INPUT_ACTION_DOWN,
                               session.epoch + 1u);
    CHECK(gApi->submitEvent(&stale) == AMCL_INPUT_ERROR_STALE);
    CHECK(Snapshot().heldControlCount == 0u);
    AmclInputEvent staleFocus = Key(1, 1, AMCL_INPUT_ACTION_DOWN);
    staleFocus.header.focusEpoch = Snapshot().focusEpoch + 1u;
    CHECK(gApi->submitEvent(&staleFocus) == AMCL_INPUT_ERROR_STALE);
    AmclInputEvent staleSurface = Key(1, 1, AMCL_INPUT_ACTION_DOWN);
    staleSurface.header.surfaceEpoch = Snapshot().surfaceEpoch + 1u;
    CHECK(gApi->submitEvent(&staleSurface) == AMCL_INPUT_ERROR_STALE);
    CHECK(Snapshot().heldControlCount == 0u);

    CHECK(gApi->publishFocus(0) == AMCL_INPUT_OK);
    const uint64_t focusEpoch = Snapshot().focusEpoch;
    CHECK(gApi->publishFocus(0) == AMCL_INPUT_OK);
    CHECK(Snapshot().focusEpoch == focusEpoch);
    AmclInputEvent key = Key(1, 2, AMCL_INPUT_ACTION_DOWN);
    CHECK(gApi->submitEvent(&key) == AMCL_INPUT_ERROR_UNFOCUSED);
    AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
    CHECK(gApi->submitEvent(&move) == AMCL_INPUT_ERROR_UNFOCUSED);
    AmclInputEvent enter = Event(AMCL_INPUT_EVENT_POINTER_ENTER);
    enter.payload.pointerEnter.entered = 1;
    CHECK(gApi->submitEvent(&enter) == AMCL_INPUT_ERROR_UNFOCUSED);
    AmclInputEvent text = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(gApi->submitEvent(&text) ==
          AMCL_INPUT_ERROR_UNFOCUSED);
    CHECK(gApi->publishFocus(1) == AMCL_INPUT_OK);

    AmclInputEvent future = Event(0x7fffffffu);
    future.header.structSize =
        static_cast<uint16_t>(sizeof(AmclInputEvent) + 16u);
    CHECK(gApi->submitEvent(&future) == AMCL_INPUT_OK);
    AmclInputEvent tooSmall = Key(1, 3, AMCL_INPUT_ACTION_DOWN);
    tooSmall.header.structSize =
        static_cast<uint16_t>(sizeof(AmclInputEvent) - 1u);
    CHECK(gApi->submitEvent(&tooSmall) == AMCL_INPUT_ERROR_ABI_MISMATCH);
    const auto output = Drain(session.consumer);
    CHECK(output.size() == 3u);  // reset, focus lost, focus gained
}

void TestLifecycleOrderingAndIdempotence() {
    Session session;
    AmclInputEvent down = Key(5, 9, AMCL_INPUT_ACTION_DOWN);
    CHECK(gApi->submitEvent(&down) == AMCL_INPUT_OK);
    const auto initial = Drain(session.consumer);
    CHECK(initial.size() == 1u);
    const uint64_t downTime = initial[0].header.monotonicTimeNs;
    const uint64_t oldFocus = Snapshot().focusEpoch;
    CHECK(gApi->publishFocus(0) == AMCL_INPUT_OK);
    auto output = Drain(session.consumer);
    CHECK(output.size() == 3u);
    CHECK(output[0].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(output[0].header.focusEpoch == oldFocus);
    CHECK(output[1].header.focusEpoch == oldFocus);
    CHECK(output[2].header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED);
    CHECK(output[2].header.focusEpoch == oldFocus + 1u);
    CHECK(output[0].header.monotonicTimeNs >= downTime);
    CHECK(output[0].header.monotonicTimeNs == output[1].header.monotonicTimeNs);
    CHECK(output[1].header.monotonicTimeNs == output[2].header.monotonicTimeNs);
    CHECK(gApi->publishFocus(1) == AMCL_INPUT_OK);
    Drain(session.consumer);

    AmclInputSurfacePayload surface{};
    surface.widthPx = 800;
    surface.heightPx = 600;
    surface.active = 1;
    surface.density = 2.0f;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                          AMCL_INPUT_SURFACE_FIELD_DENSITY;
    const uint64_t oldSurfaceEpoch = Snapshot().surfaceEpoch;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(output[0].header.surfaceEpoch == oldSurfaceEpoch);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(output[1].header.surfaceEpoch == oldSurfaceEpoch + 1u);
    const uint64_t surfaceEpoch = Snapshot().surfaceEpoch;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).empty());
    CHECK(Snapshot().surfaceEpoch == surfaceEpoch);
    ++surface.widthPx;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.surfaceEpoch == surfaceEpoch);
    CHECK(output[1].header.surfaceEpoch == surfaceEpoch + 1u);

    CHECK(gApi->publishDeviceChange(77, AMCL_INPUT_DEVICE_ADDED, 3) == AMCL_INPUT_OK);
    CHECK(gApi->publishDeviceChange(77, AMCL_INPUT_DEVICE_ADDED, 3) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 1u);
    CHECK(gApi->publishDeviceChange(77, AMCL_INPUT_DEVICE_REMOVED, 0) == AMCL_INPUT_OK);
    CHECK(gApi->publishDeviceChange(77, AMCL_INPUT_DEVICE_REMOVED, 0) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 1u);

    AmclInputEvent unregistered = Key(88, 6, AMCL_INPUT_ACTION_DOWN);
    CHECK(gApi->submitEvent(&unregistered) == AMCL_INPUT_OK);
    Drain(session.consumer);
    CHECK(gApi->publishDeviceChange(88, AMCL_INPUT_DEVICE_REMOVED, 0) == AMCL_INPUT_OK);
    const auto removed = Drain(session.consumer);
    CHECK(removed.size() == 2u);
    CHECK(removed[0].header.deviceId == 88u &&
          removed[0].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
}

void FillSharedQueue() {
    while (Snapshot().queuedEventCount < Snapshot().queueCapacity) {
        AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        move.payload.pointerRelative.rawDx =
            static_cast<double>(Snapshot().queuedEventCount + 1u);
        CHECK(gApi->submitEvent(&move) == AMCL_INPUT_OK);
    }
}

void TestLifecycleOverflowTransitions() {
    {
        Session session;
        const AmclInputEvent held = Key(55u, 13u, AMCL_INPUT_ACTION_DOWN);
        CHECK(gApi->submitEvent(&held) == AMCL_INPUT_OK);
        FillSharedQueue();
        CHECK(Snapshot().heldControlCount == 1u);
        const uint64_t oldFocus = Snapshot().focusEpoch;
        CHECK(gApi->publishFocus(0) == AMCL_INPUT_OVERFLOW_RESET);
        const auto snapshot = Snapshot();
        CHECK(snapshot.focused == 0u);
        CHECK(snapshot.focusEpoch == oldFocus + 1u);
        CHECK(snapshot.heldControlCount == 0u);
        const auto output = Drain(session.consumer);
        CHECK(output.size() == 2u);
        CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(output[0].payload.reset.reason == AMCL_INPUT_RESET_FOCUS_LOST);
        CHECK(output[0].header.focusEpoch == oldFocus);
        CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED);
        CHECK(output[1].payload.focus.focused == 0u);
        CHECK(output[1].header.focusEpoch == oldFocus + 1u);
    }
    {
        Session session;
        AmclInputEvent capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
        capture.payload.capture.requested = 1u;
        capture.payload.capture.active = 1u;
        capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
        CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OK);
        Drain(session.consumer);
        FillSharedQueue();
        capture.payload.capture.active = 0u;
        capture.payload.capture.reason =
            AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST;
        CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OVERFLOW_RESET);
        CHECK(Snapshot().captureActive == 0u);
        const auto output = Drain(session.consumer);
        CHECK(output.size() == 2u);
        CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(output[0].payload.reset.reason ==
              AMCL_INPUT_RESET_CAPTURE_LOST);
        CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_CAPTURE_CHANGED);
        CHECK(output[1].payload.capture.active == 0u);
        CHECK(output[1].payload.capture.reason ==
              AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    }
    {
        Session session;
        AmclInputSurfacePayload surface{};
        surface.widthPx = 640u;
        surface.heightPx = 480u;
        surface.active = 1u;
        surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
        CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
        Drain(session.consumer);
        FillSharedQueue();
        const uint64_t oldSurface = Snapshot().surfaceEpoch;
        surface.widthPx = 800u;
        CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OVERFLOW_RESET);
        CHECK(Snapshot().surfaceEpoch == oldSurface + 1u);
        const auto output = Drain(session.consumer);
        CHECK(output.size() == 2u);
        CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(output[0].payload.reset.reason ==
              AMCL_INPUT_RESET_SURFACE_CHANGED);
        CHECK(output[0].header.surfaceEpoch == oldSurface);
        CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
        CHECK(output[1].payload.surface.widthPx == 800u);
        CHECK(output[1].header.surfaceEpoch == oldSurface + 1u);
    }
    {
        Session session;
        AmclInputEvent capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
        capture.payload.capture.requested = 1u;
        capture.payload.capture.active = 1u;
        capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
        CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OK);
        Drain(session.consumer);
        FillSharedQueue();
        const uint64_t oldFocus = Snapshot().focusEpoch;
        CHECK(gApi->publishFocus(0u) == AMCL_INPUT_OVERFLOW_RESET);
        const auto output = Drain(session.consumer);
        CHECK(output.size() == 3u);
        CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(output[0].payload.reset.reason == AMCL_INPUT_RESET_FOCUS_LOST);
        CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_CAPTURE_CHANGED);
        CHECK(output[1].payload.capture.requested == 1u);
        CHECK(output[1].payload.capture.active == 0u);
        CHECK(output[1].payload.capture.reason ==
              AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);
        CHECK(output[1].header.focusEpoch == oldFocus);
        CHECK(output[2].header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED);
        CHECK(output[2].header.focusEpoch == oldFocus + 1u);
        const auto snapshot = Snapshot();
        CHECK(snapshot.captureRequested == 1u);
        CHECK(snapshot.captureActive == 0u);
        CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);
    }
}

void TestPointerDeviceClassTimestampAndRemovalOrdering() {
    Session session;
    constexpr uint64_t kMouse = 301u;
    constexpr uint64_t kTouchpad = 302u;
    constexpr uint32_t kPointerCaps =
        AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE |
        AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS |
        AMCL_INPUT_DEVICE_CAP_WHEEL;

    auto addDevice = [&](uint64_t id, uint32_t deviceClass) {
        AmclInputEvent add = Event(AMCL_INPUT_EVENT_DEVICE_CHANGED);
        add.header.deviceId = id;
        add.header.deviceClass = deviceClass;
        add.payload.device.change = AMCL_INPUT_DEVICE_ADDED;
        add.payload.device.capabilities = kPointerCaps;
        CHECK(gApi->submitEvent(&add) == AMCL_INPUT_OK);
    };
    addDevice(kMouse, AMCL_INPUT_DEVICE_CLASS_MOUSE);
    addDevice(kTouchpad, AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);
    auto output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_MOUSE);
    CHECK(output[1].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);

    AmclInputEvent mouseDown =
        Button(kMouse, 1u, AMCL_INPUT_ACTION_DOWN, 0u,
               AMCL_INPUT_DEVICE_CLASS_MOUSE);
    mouseDown.header.flags |= AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
    mouseDown.header.monotonicTimeNs = 1u;
    AmclInputEvent padDown =
        Button(kTouchpad, 1u, AMCL_INPUT_ACTION_DOWN, 0u,
               AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);
    padDown.header.flags |= AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
    padDown.header.monotonicTimeNs = 2u;
    CHECK(gApi->submitEvent(&mouseDown) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&padDown) == AMCL_INPUT_OK);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    // Two DEVICE_ADDED records were stamped immediately before these samples.
    // Old platform times are clamped to that last delivered time so the public
    // monotonic stream never goes backwards, while the provenance flag remains.
    CHECK(output[0].header.monotonicTimeNs >= 2u);
    CHECK(output[1].header.monotonicTimeNs >=
          output[0].header.monotonicTimeNs);
    CHECK((output[0].header.flags &
           AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u);
    CHECK(Snapshot().heldControlCount == 2u);

    // Removal arrives after platform device details have disappeared, so the
    // producer can only say Unknown/0. Core must restore ADD-time class/caps and
    // order the synthetic UP before DEVICE_REMOVED.
    AmclInputEvent removeMouse = Event(AMCL_INPUT_EVENT_DEVICE_CHANGED);
    removeMouse.header.deviceId = kMouse;
    removeMouse.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    removeMouse.payload.device.change = AMCL_INPUT_DEVICE_REMOVED;
    CHECK(gApi->submitEvent(&removeMouse) == AMCL_INPUT_OK);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(output[0].payload.pointerButton.action == AMCL_INPUT_ACTION_UP);
    CHECK(output[0].header.deviceId == kMouse);
    CHECK(output[0].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_MOUSE);
    CHECK((output[0].header.flags &
           AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) == 0u);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED);
    CHECK(output[1].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_MOUSE);
    CHECK(output[1].payload.device.capabilities == kPointerCaps);
    CHECK(Snapshot().heldControlCount == 1u);

    AmclInputEvent removePad = Event(AMCL_INPUT_EVENT_DEVICE_CHANGED);
    removePad.header.deviceId = kTouchpad;
    removePad.payload.device.change = AMCL_INPUT_DEVICE_REMOVED;
    CHECK(gApi->submitEvent(&removePad) == AMCL_INPUT_OK);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.deviceId == kTouchpad);
    CHECK(output[0].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);
    CHECK(output[1].header.deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);
    CHECK(Snapshot().heldControlCount == 0u);

    AmclInputEvent invalidClass =
        Button(303u, 1u, AMCL_INPUT_ACTION_DOWN, 0u,
               AMCL_INPUT_DEVICE_CLASS_COUNT);
    CHECK(gApi->submitEvent(&invalidClass) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
}

void TestSessionScopeAndActiveRollover() {
    AmclInputConsumerHandle oldConsumer = 0;
    CHECK(gApi->openConsumer(&oldConsumer) == AMCL_INPUT_OK);
    uint64_t firstEpoch = 0;
    CHECK(gApi->beginSession(&firstEpoch) == AMCL_INPUT_OK);

    AmclInputSurfacePayload surface{};
    surface.widthPx = 1280u;
    surface.heightPx = 720u;
    surface.active = 1u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(gApi->publishDeviceChange(91u, AMCL_INPUT_DEVICE_ADDED,
                                    AMCL_INPUT_DEVICE_CAP_KEYBOARD) ==
          AMCL_INPUT_OK);
    AmclInputEvent capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    capture.payload.capture.requested = 1u;
    capture.payload.capture.active = 1u;
    capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OK);
    const AmclInputEvent heldKey = Key(91u, 7u, AMCL_INPUT_ACTION_DOWN);
    CHECK(gApi->submitEvent(&heldKey) == AMCL_INPUT_OK);
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    AmclInputEvent text = Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    const uint8_t byte = static_cast<uint8_t>('s');
    CHECK(gApi->submitTextPacket(&text, &byte, 1u) == AMCL_INPUT_OK);

    CHECK(gApi->endSession(firstEpoch) == AMCL_INPUT_OK);
    const auto ended = Snapshot();
    CHECK(ended.sessionActive == 0u);
    CHECK(ended.focused == 0u);
    CHECK(ended.captureActive == 0u);
    CHECK(ended.heldControlCount == 0u);
    CHECK(ended.blobBytes == 0u);
    const auto oldEvents = Drain(oldConsumer);
    CHECK(!oldEvents.empty());
    CHECK(oldEvents.back().header.eventType == AMCL_INPUT_EVENT_RESET);
    AmclInputEvent unused{};
    CHECK(gApi->nextEvent(oldConsumer, &unused) == AMCL_INPUT_ERROR_STALE);

    AmclInputConsumerHandle recoveryConsumer = 0;
    CHECK(gApi->openConsumer(&recoveryConsumer) == AMCL_INPUT_OK);
    uint64_t recoveryEpoch = 0;
    CHECK(gApi->beginSession(&recoveryEpoch) == AMCL_INPUT_OK);
    CHECK(recoveryEpoch != firstEpoch);
    CHECK(Drain(recoveryConsumer).empty());
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    auto recoveryEvents = Drain(recoveryConsumer);
    CHECK(recoveryEvents.size() == 2u);
    CHECK(recoveryEvents[1].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(gApi->publishDeviceChange(91u, AMCL_INPUT_DEVICE_ADDED,
                                    AMCL_INPUT_DEVICE_CAP_KEYBOARD) ==
          AMCL_INPUT_OK);
    recoveryEvents = Drain(recoveryConsumer);
    CHECK(recoveryEvents.size() == 1u);
    CHECK(recoveryEvents[0].header.eventType ==
          AMCL_INPUT_EVENT_DEVICE_CHANGED);

    uint64_t rolloverEpoch = 0;
    CHECK(gApi->beginSession(&rolloverEpoch) == AMCL_INPUT_OK);
    CHECK(rolloverEpoch != recoveryEpoch);
    recoveryEvents = Drain(recoveryConsumer);
    CHECK(recoveryEvents.size() == 1u);
    CHECK(recoveryEvents[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(recoveryEvents[0].payload.reset.closingEpoch == recoveryEpoch);
    CHECK(gApi->nextEvent(recoveryConsumer, &unused) ==
          AMCL_INPUT_ERROR_STALE);

    AmclInputConsumerHandle rolloverConsumer = 0;
    CHECK(gApi->openConsumer(&rolloverConsumer) == AMCL_INPUT_OK);
    const auto baseline = Drain(rolloverConsumer);
    CHECK(baseline.size() == 1u);
    CHECK(baseline[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(gApi->endSession(rolloverEpoch) == AMCL_INPUT_OK);
    Drain(rolloverConsumer);
    CHECK(gApi->closeConsumer(rolloverConsumer) == AMCL_INPUT_OK);
    CHECK(gApi->closeConsumer(recoveryConsumer) == AMCL_INPUT_OK);
    CHECK(gApi->closeConsumer(oldConsumer) == AMCL_INPUT_OK);
}

void TestSurfaceValidityAndInactiveBaseline() {
    Session session;
    AmclInputSurfacePayload surface{};
    surface.widthPx = 320u;
    surface.heightPx = 240u;
    surface.transform = 9u;
    surface.active = 1u;
    surface.density = 3.0f;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    Drain(session.consumer);
    const uint64_t dimensionsEpoch = Snapshot().surfaceEpoch;

    surface.transform = 11u;
    surface.density = 4.0f;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).empty());
    CHECK(Snapshot().surfaceEpoch == dimensionsEpoch);

    surface.validFields |= AMCL_INPUT_SURFACE_FIELD_TRANSFORM;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 2u);

    surface.active = 0u;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 2u);
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 2u);

    surface = AmclInputSurfacePayload{};
    surface.active = 1u;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 2u);
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 2u);
}

AmclInputBlobRef BlobOf(const AmclInputEvent& event) {
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) {
        return event.payload.textCommit.utf8Blob;
    }
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
        return event.payload.textEditing.utf8Blob;
    }
    return event.payload.textCandidates.itemsBlob;
}

void CheckBlob(AmclInputConsumerHandle consumer, const AmclInputBlobRef& blob,
               const std::vector<uint8_t>& expected) {
    uint32_t size = 0;
    CHECK(gApi->readPacketBlob(consumer, &blob, nullptr, 0, &size) ==
          (expected.empty() ? AMCL_INPUT_OK : AMCL_INPUT_ERROR_BUFFER_TOO_SMALL));
    CHECK(size == expected.size());
    std::vector<uint8_t> actual(size);
    CHECK(gApi->readPacketBlob(consumer, &blob, actual.data(), size, &size) == AMCL_INPUT_OK);
    CHECK(actual == expected);
}

void TestTypedEventsAndOwnedBlobs() {
    AmclInputConsumerHandle first = 0;
    AmclInputConsumerHandle second = 0;
    CHECK(gApi->openConsumer(&first) == AMCL_INPUT_OK);
    CHECK(gApi->openConsumer(&second) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(gApi->beginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(Drain(first).empty() && Drain(second).empty());
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(Drain(first).size() == 1u && Drain(second).size() == 1u);

    // U+4E2D (中文字符“中”) followed by U+1F600 (emoji).
    const std::vector<uint8_t> utf8 = {
        0xE4u, 0xB8u, 0xADu, 0xF0u, 0x9Fu, 0x98u, 0x80u};
    const uint32_t types[] = {AMCL_INPUT_EVENT_TEXT_COMMIT,
                              AMCL_INPUT_EVENT_TEXT_EDITING,
                              AMCL_INPUT_EVENT_TEXT_CANDIDATES};
    for (uint32_t type : types) {
        AmclInputEvent text = Event(type);
        std::vector<uint8_t> packetBytes = utf8;
        if (type == AMCL_INPUT_EVENT_TEXT_EDITING) {
            text.payload.textEditing.selectionStart = 1u;
            text.payload.textEditing.selectionLength = 1u;
        } else if (type == AMCL_INPUT_EVENT_TEXT_CANDIDATES) {
            // Empty candidate list: the 4-byte LE item-count header is still a
            // binary blob, never an arbitrary UTF-8 string.
            packetBytes = {0u, 0u, 0u, 0u};
        }
        CHECK(gApi->submitTextPacket(
                  &text, packetBytes.data(),
                  static_cast<uint32_t>(packetBytes.size())) == AMCL_INPUT_OK);
        AmclInputEvent a{};
        AmclInputEvent b{};
        CHECK(gApi->nextEvent(first, &a) == AMCL_INPUT_OK);
        CHECK(gApi->nextEvent(second, &b) == AMCL_INPUT_OK);
        CHECK(a.header.eventType == type && b.header.eventType == type);
        const AmclInputBlobRef blob = BlobOf(a);
        CHECK(blob.packetId == BlobOf(b).packetId);
        CHECK(blob.offset == 0u &&
              blob.length == static_cast<uint32_t>(packetBytes.size()));
        if (type == AMCL_INPUT_EVENT_TEXT_EDITING) {
            CHECK(a.payload.textEditing.selectionStart == 1u);
            CHECK(a.payload.textEditing.selectionLength == 1u);
        } else if (type == AMCL_INPUT_EVENT_TEXT_CANDIDATES) {
            CHECK(a.payload.textCandidates.selected == 0u);
            CHECK(a.payload.textCandidates.pageStart == 0u);
            CHECK(a.payload.textCandidates.pageSize == 0u);
            CHECK(a.payload.textCandidates.itemCount == 0u);
        }
        CheckBlob(first, blob, packetBytes);
        CheckBlob(second, blob, packetBytes);
        CHECK(gApi->releasePacket(first, blob.packetId) == AMCL_INPUT_OK);
        CheckBlob(second, blob, packetBytes);  // survives every owner release
        CHECK(gApi->releasePacket(second, blob.packetId) == AMCL_INPUT_OK);
    }

    // A legal 128-byte candidate begins with a binary 0x80 length byte. The
    // core must route CANDIDATES through the length-prefixed codec instead of
    // applying whole-blob UTF-8 validation.
    std::vector<uint8_t> candidate128(4u + 4u + 128u,
                                      static_cast<uint8_t>('c'));
    candidate128[0] = 1u;
    candidate128[1] = 0u;
    candidate128[2] = 0u;
    candidate128[3] = 0u;
    candidate128[4] = 0x80u;
    candidate128[5] = 0u;
    candidate128[6] = 0u;
    candidate128[7] = 0u;
    AmclInputEvent candidate = Event(AMCL_INPUT_EVENT_TEXT_CANDIDATES);
    candidate.payload.textCandidates.pageSize = 1u;
    candidate.payload.textCandidates.itemCount = 1u;
    CHECK(gApi->submitTextPacket(
              &candidate, candidate128.data(),
              static_cast<uint32_t>(candidate128.size())) == AMCL_INPUT_OK);
    AmclInputEvent candidateFirst{};
    AmclInputEvent candidateSecond{};
    CHECK(gApi->nextEvent(first, &candidateFirst) == AMCL_INPUT_OK);
    CHECK(gApi->nextEvent(second, &candidateSecond) == AMCL_INPUT_OK);
    const AmclInputBlobRef candidateBlob = BlobOf(candidateFirst);
    CheckBlob(first, candidateBlob, candidate128);
    CHECK(gApi->releasePacket(first, candidateBlob.packetId) == AMCL_INPUT_OK);
    CHECK(gApi->releasePacket(second, candidateBlob.packetId) == AMCL_INPUT_OK);

    AmclInputEvent enter = Event(AMCL_INPUT_EVENT_POINTER_ENTER);
    enter.payload.pointerEnter.entered = 1;
    AmclInputEvent selection = Event(AMCL_INPUT_EVENT_TEXT_SELECTION);
    selection.payload.textSelection.selectionStart = 2;
    selection.payload.textSelection.selectionLength = 3;
    CHECK(gApi->submitEvent(&enter) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&selection) == AMCL_INPUT_OK);
    const auto firstTyped = Drain(first);
    const auto secondTyped = Drain(second);
    CHECK(firstTyped.size() == 2u && secondTyped.size() == 2u);
    CHECK(firstTyped[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ENTER);
    CHECK(firstTyped[0].payload.pointerEnter.entered == 1u);
    CHECK(firstTyped[1].header.eventType == AMCL_INPUT_EVENT_TEXT_SELECTION);
    CHECK(firstTyped[1].payload.textSelection.selectionStart == 2u);
    CHECK(firstTyped[1].payload.textSelection.selectionLength == 3u);

    CHECK(gApi->endSession(epoch) == AMCL_INPUT_OK);
    Drain(first); Drain(second);
    CHECK(gApi->closeConsumer(first) == AMCL_INPUT_OK);
    CHECK(gApi->closeConsumer(second) == AMCL_INPUT_OK);
}

void TestBlobReclamationAndExhaustion() {
    Session session;
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 1u);
    AmclInputEvent text = Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    const std::vector<uint8_t> oversized(257u, static_cast<uint8_t>('z'));
    CHECK(gApi->submitTextPacket(&text, oversized.data(),
                                 static_cast<uint32_t>(oversized.size())) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(Snapshot().blobBytes == 0u);
    auto output = Drain(session.consumer);
    CHECK(output.size() == 1u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(output[0].payload.reset.reason ==
          AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED);

    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 1u);
    const std::vector<uint8_t> full(256u, static_cast<uint8_t>('x'));
    CHECK(gApi->submitTextPacket(&text, full.data(),
                                 static_cast<uint32_t>(full.size())) == AMCL_INPUT_OK);
    CHECK(Snapshot().blobBytes == full.size());
    const uint8_t extra = static_cast<uint8_t>('y');
    CHECK(gApi->submitTextPacket(&text, &extra, 1) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(Snapshot().blobBytes == 0u);
    output = Drain(session.consumer);
    CHECK(output.size() == 1u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(output[0].payload.reset.reason ==
          AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED);

    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).size() == 1u);
    CHECK(gApi->submitTextPacket(&text, &extra, 1) == AMCL_INPUT_OK);
    CHECK(Snapshot().blobBytes == 1u);
    CHECK(gApi->requestReset(AMCL_INPUT_RESET_EXPLICIT) == AMCL_INPUT_OK);
    CHECK(Snapshot().blobBytes == 0u);
    output = Drain(session.consumer);
    CHECK(std::none_of(output.begin(), output.end(), [](const auto& event) {
        return event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT;
    }));
}

void TestBatchRollbackAndOverflow() {
    Session session;
    std::vector<AmclInputEvent> batch;
    batch.push_back(Key(3, 4, AMCL_INPUT_ACTION_DOWN));
    for (int i = 0; i < 8; ++i) {
        AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        move.payload.pointerRelative.rawDx = static_cast<double>(i);
        batch.push_back(move);
    }
    CHECK(gApi->submitBatch(batch.data(), static_cast<uint32_t>(batch.size())) ==
          AMCL_INPUT_OVERFLOW_RESET);
    CHECK(Snapshot().heldControlCount == 0u);
    const auto output = Drain(session.consumer);
    CHECK(output.size() == 1u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);

    AmclInputEvent invalid[] = {
        Key(3, 5, AMCL_INPUT_ACTION_DOWN),
        Key(3, 6, 999u),
    };
    const AmclInputSnapshotV1 beforeInvalid = Snapshot();
    CHECK(gApi->submitBatch(invalid, 2) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    const AmclInputSnapshotV1 afterInvalid = Snapshot();
    CHECK(afterInvalid.heldControlCount == beforeInvalid.heldControlCount);
    CHECK(afterInvalid.queuedEventCount == beforeInvalid.queuedEventCount);
    CHECK(afterInvalid.focusEpoch == beforeInvalid.focusEpoch);
    CHECK(afterInvalid.surfaceEpoch == beforeInvalid.surfaceEpoch);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent invalidTypeBatch[] = {
        Key(3, 7, AMCL_INPUT_ACTION_DOWN),
        Event(0u),
    };
    CHECK(gApi->submitBatch(invalidTypeBatch, 2) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CHECK(Snapshot().heldControlCount == 0u);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent badAbi[] = {
        Key(3, 7, AMCL_INPUT_ACTION_DOWN),
        Key(3, 8, AMCL_INPUT_ACTION_UP),
    };
    badAbi[1].header.structSize =
        static_cast<uint16_t>(sizeof(AmclInputEvent) - 1u);
    CHECK(gApi->submitBatch(badAbi, 2) == AMCL_INPUT_ERROR_ABI_MISMATCH);
    CHECK(Snapshot().heldControlCount == 0u);
    CHECK(Drain(session.consumer).empty());

    const AmclInputEvent recovered[] = {
        Key(3, 9, AMCL_INPUT_ACTION_DOWN),
        Key(3, 9, AMCL_INPUT_ACTION_UP),
    };
    CHECK(gApi->submitBatch(recovered, 2) == AMCL_INPUT_OK);
    const auto recoveredOutput = Drain(session.consumer);
    CHECK(recoveredOutput.size() == 2u);
    CHECK(recoveredOutput[0].payload.physicalKey.action == AMCL_INPUT_ACTION_DOWN);
    CHECK(recoveredOutput[1].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
}

void TestAbsolutePositionBoundBatchContract() {
    Session session;
    const auto absoluteFor = [](uint64_t device, double x, double y) {
        AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
        event.header.source = AMCL_INPUT_SOURCE_MOUSE;
        event.header.deviceId = device;
        event.payload.pointerAbsolute.localPxX = x;
        event.payload.pointerAbsolute.localPxY = y;
        return event;
    };
    const auto boundButton = [](uint64_t device, uint32_t action) {
        AmclInputEvent event = Button(device, 1u, action);
        event.header.flags |=
            AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
        return event;
    };

    AmclInputEvent standalone = boundButton(40u, AMCL_INPUT_ACTION_DOWN);
    const AmclInputSnapshotV1 beforeStandalone = Snapshot();
    CHECK(gApi->submitEvent(&standalone) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CHECK(gApi->submitBatch(&standalone, 1u) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(Snapshot(), beforeStandalone);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent wrongPredecessor[] = {
        Event(AMCL_INPUT_EVENT_POINTER_RELATIVE),
        boundButton(40u, AMCL_INPUT_ACTION_DOWN),
    };
    wrongPredecessor[0].header.source = AMCL_INPUT_SOURCE_MOUSE;
    wrongPredecessor[0].header.deviceId = 40u;
    CHECK(gApi->submitBatch(wrongPredecessor, 2u) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(Snapshot(), beforeStandalone);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent mismatchedDevice[] = {
        absoluteFor(40u, 10.0, 20.0),
        boundButton(41u, AMCL_INPUT_ACTION_DOWN),
    };
    CHECK(gApi->submitBatch(mismatchedDevice, 2u) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(Snapshot(), beforeStandalone);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent down[] = {
        absoluteFor(40u, 10.0, 20.0),
        boundButton(40u, AMCL_INPUT_ACTION_DOWN),
    };
    CHECK(gApi->submitBatch(down, 2u) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 1u);
    auto output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(output[1].header.sequence == output[0].header.sequence + 1u);
    CHECK((output[1].header.flags &
           AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u);

    AmclInputEvent mismatchedRelease[] = {
        absoluteFor(41u, 11.0, 21.0),
        boundButton(40u, AMCL_INPUT_ACTION_UP),
    };
    const AmclInputSnapshotV1 beforeBadRelease = Snapshot();
    CHECK(gApi->submitBatch(mismatchedRelease, 2u) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(Snapshot(), beforeBadRelease);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent up[] = {
        absoluteFor(40u, 11.0, 21.0),
        boundButton(40u, AMCL_INPUT_ACTION_UP),
    };
    CHECK(gApi->submitBatch(up, 2u) == AMCL_INPUT_OK);
    CHECK(Snapshot().heldControlCount == 0u);
    output = Drain(session.consumer);
    CHECK(output.size() == 2u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
}

void TestNonFinitePayloadsAndAtomicRollback() {
    Session session;
    CHECK(gApi->publishFocus(1u) == AMCL_INPUT_OK);
    Drain(session.consumer);

    const double invalidDouble[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
    };
    const float invalidFloat[] = {
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
    };

    const auto expectRejected = [&](const AmclInputEvent& event) {
        const AmclInputSnapshotV1 before = Snapshot();
        CHECK(gApi->submitEvent(&event) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
        CheckSnapshotStateEqual(Snapshot(), before);
        CHECK(Drain(session.consumer).empty());
    };

    for (double value : invalidDouble) {
        AmclInputEvent absolute = Event(AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
        absolute.payload.pointerAbsolute.localPxX = value;
        absolute.payload.pointerAbsolute.localPxY = 2.0;
        expectRejected(absolute);
        absolute.payload.pointerAbsolute.localPxX = 1.0;
        absolute.payload.pointerAbsolute.localPxY = value;
        expectRejected(absolute);

        AmclInputEvent relative = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        relative.payload.pointerRelative.rawDx = value;
        relative.payload.pointerRelative.rawDy = -2.0;
        expectRejected(relative);
        relative.payload.pointerRelative.rawDx = 1.0;
        relative.payload.pointerRelative.rawDy = value;
        expectRejected(relative);
    }

    for (float value : invalidFloat) {
        AmclInputEvent wheel = Event(AMCL_INPUT_EVENT_POINTER_WHEEL);
        wheel.payload.pointerWheel.x = value;
        wheel.payload.pointerWheel.y = -0.5f;
        wheel.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_PIXEL;
        expectRejected(wheel);
        wheel.payload.pointerWheel.x = 0.25f;
        wheel.payload.pointerWheel.y = value;
        expectRejected(wheel);
    }

    // An undeclared density is deliberately ignored, even when its storage is
    // non-finite. Once the validity bit asserts that density is meaningful, the
    // exact same values fail closed before surface state/epoch mutation.
    AmclInputSurfacePayload surface{};
    surface.widthPx = 640u;
    surface.heightPx = 480u;
    surface.active = 1u;
    surface.density = std::numeric_limits<float>::quiet_NaN();
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    Drain(session.consumer);
    for (float value : invalidFloat) {
        surface.density = value;
        surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                              AMCL_INPUT_SURFACE_FIELD_DENSITY;
        const AmclInputSnapshotV1 before = Snapshot();
        CHECK(gApi->publishSurface(&surface) ==
              AMCL_INPUT_ERROR_INVALID_ARGUMENT);
        CheckSnapshotStateEqual(Snapshot(), before);
        CHECK(Drain(session.consumer).empty());
    }
    for (float value : {0.0f, -1.0f}) {
        surface.density = value;
        const AmclInputSnapshotV1 before = Snapshot();
        CHECK(gApi->publishSurface(&surface) ==
              AMCL_INPUT_ERROR_INVALID_ARGUMENT);
        CheckSnapshotStateEqual(Snapshot(), before);
        CHECK(Drain(session.consumer).empty());
    }

    surface = AmclInputSurfacePayload{};
    surface.widthPx = 0u;
    surface.heightPx = 480u;
    surface.active = 1u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    surface.widthPx = 640u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS | (1u << 31u);
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    CHECK(Drain(session.consumer).empty());

    // Transform is an opaque uint32 platform token. Validate its declaration,
    // not a guessed platform enum range.
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                          AMCL_INPUT_SURFACE_FIELD_TRANSFORM;
    surface.transform = UINT32_MAX;
    CHECK(gApi->publishSurface(&surface) == AMCL_INPUT_OK);
    Drain(session.consumer);

    AmclInputEvent invalidBatch[] = {
        Key(77u, 9u, AMCL_INPUT_ACTION_DOWN),
        Event(AMCL_INPUT_EVENT_POINTER_RELATIVE),
    };
    invalidBatch[1].payload.pointerRelative.rawDx = 3.0;
    invalidBatch[1].payload.pointerRelative.rawDy =
        std::numeric_limits<double>::quiet_NaN();
    const AmclInputSnapshotV1 beforeBatch = Snapshot();
    CHECK(gApi->submitBatch(invalidBatch, 2u) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(Snapshot(), beforeBatch);
    CHECK(Drain(session.consumer).empty());

    AmclInputEvent recovered = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
    recovered.payload.pointerRelative.rawDx = 1.25;
    recovered.payload.pointerRelative.rawDy = -2.5;
    CHECK(gApi->submitEvent(&recovered) == AMCL_INPUT_OK);
    const auto output = Drain(session.consumer);
    CHECK(output.size() == 1u);
    CHECK(std::isfinite(output[0].payload.pointerRelative.rawDx));
    CHECK(std::isfinite(output[0].payload.pointerRelative.rawDy));
}

void TestDiagnosticBatchRollbackAndOverflow() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());

    AmclInputEvent ownerlessRepeat =
        Key(501u, 77u, AMCL_INPUT_ACTION_REPEAT);
    core.TestSetNextSequence(UINT64_MAX);
    const auto beforeExhaustedDrop = CoreSnapshot(core);
    CHECK(core.SubmitEvent(&ownerlessRepeat) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeExhaustedDrop);
    CHECK(CoreDrain(core, consumer).empty());

    core.TestSetNextSequence(500u);
    AmclInputEvent staleMove =
        Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch + 1u);
    const AmclInputEvent rollbackBatch[] = {ownerlessRepeat, staleMove};
    const auto beforeRollback = CoreSnapshot(core);
    CHECK(core.SubmitBatch(rollbackBatch, 2u) == AMCL_INPUT_ERROR_STALE);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeRollback);
    CHECK(CoreDrain(core, consumer).empty());

    const AmclInputEvent ownerlessUp =
        Key(501u, 77u, AMCL_INPUT_ACTION_UP);
    CHECK(core.SubmitEvent(&ownerlessUp) == AMCL_INPUT_OK);
    auto output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u);
    CHECK(output[0].header.sequence == 500u);
    CheckDrop(output[0], AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, 501u, 77u,
              AMCL_INPUT_ACTION_UP, 177u, 0u);

    // A diagnostic obeys the same bounded-queue contract. If it cannot fit,
    // the caller gets the existing observable overflow RESET, never a silent
    // OK, and no held owner survives.
    for (uint32_t i = 0; i < 8u; ++i) {
        AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        move.payload.pointerRelative.rawDx = static_cast<double>(i + 1u);
        CHECK(core.SubmitEvent(&move) == AMCL_INPUT_OK);
    }
    CHECK(core.SubmitEvent(&ownerlessRepeat) == AMCL_INPUT_OVERFLOW_RESET);
    CHECK(CoreSnapshot(core).heldControlCount == 0u);
    output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u);
    CHECK(output[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(output[0].payload.reset.reason == AMCL_INPUT_RESET_QUEUE_OVERFLOW);

    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
}

void TestLateConsumerBaselineAndGeneration() {
    Session session;
    const AmclInputEvent down = Key(42, 12, AMCL_INPUT_ACTION_DOWN);
    CHECK(gApi->submitEvent(&down) == AMCL_INPUT_OK);
    FillSharedQueue();
    const AmclInputSnapshotV1 beforeOpen = Snapshot();

    AmclInputConsumerHandle late = 0;
    CHECK(gApi->openConsumer(&late) == AMCL_INPUT_OK);
    const AmclInputSnapshotV1 afterOpen = Snapshot();
    CHECK(afterOpen.queuedEventCount == beforeOpen.queuedEventCount);
    CHECK(afterOpen.overflowResetCount == beforeOpen.overflowResetCount);
    CHECK((late >> 48u) == AMCL_INPUT_HOST_API_GENERATION);
    const auto lateEvents = Drain(late);
    CHECK(lateEvents.size() == 1u);
    CHECK(lateEvents[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(lateEvents[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK((lateEvents[0].header.flags & AMCL_INPUT_EVENT_FLAG_SYNTHETIC) != 0u);
    CHECK(lateEvents[0].header.source == AMCL_INPUT_SOURCE_SYNTHETIC);

    const auto originalEvents = Drain(session.consumer);
    CHECK(originalEvents.size() == beforeOpen.queueCapacity);
    CHECK(originalEvents[0].header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
    AmclInputEvent unused{};
    const AmclInputConsumerHandle wrongGeneration =
        late ^ (UINT64_C(1) << 48u);
    CHECK(gApi->nextEvent(wrongGeneration, &unused) == AMCL_INPUT_ERROR_STALE);
    CHECK(gApi->closeConsumer(wrongGeneration) == AMCL_INPUT_ERROR_STALE);
    CHECK(gApi->closeConsumer(late) == AMCL_INPUT_OK);
}

void TestLateConsumerReplaysCurrentSurfaceBeforeReady() {
    amcl::input::InputStateCore core(true);
    uint64_t epoch = 0u;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    AmclInputSurfacePayload surface{};
    surface.active = 1u;
    surface.widthPx = 1280u;
    surface.heightPx = 720u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
        AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    surface.publicationGeneration = 55u;
    CHECK(core.PublishSurface(&surface) == AMCL_INPUT_OK);
    const uint64_t expectedSurfaceEpoch = CoreSnapshot(core).surfaceEpoch;

    AmclInputConsumerHandle consumer = 0u;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    AmclInputEvent baseline{};
    CHECK(core.NextEvent(consumer, &baseline) == AMCL_INPUT_OK);
    CHECK(baseline.header.eventType == AMCL_INPUT_EVENT_RESET);
    AmclInputEvent ready = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, consumer, epoch,
        baseline.header.sequence);
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_ERROR_STALE);

    AmclInputEvent replay{};
    CHECK(core.NextEvent(consumer, &replay) == AMCL_INPUT_OK);
    CHECK(replay.header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(replay.header.sequence == baseline.header.sequence + 1u);
    CHECK(replay.header.surfaceEpoch == expectedSurfaceEpoch);
    CHECK(replay.payload.surface.widthPx == surface.widthPx);
    CHECK(replay.payload.surface.heightPx == surface.heightPx);
    CHECK(replay.payload.surface.publicationGeneration == 55u);
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);
    AmclInputEvent retire = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE, consumer, epoch);
    CHECK(core.SubmitEvent(&retire) == AMCL_INPUT_OK);
    const auto retirement = CoreDrain(core, consumer);
    CHECK(retirement.size() == 1u);
    CHECK(retirement[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(retirement[0].payload.reset.reason ==
          AMCL_INPUT_RESET_BACKEND_RETIRED);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
}

void TestCaptureAndCloseReclaim() {
    AmclInputConsumerHandle first = 0;
    AmclInputConsumerHandle second = 0;
    CHECK(gApi->openConsumer(&first) == AMCL_INPUT_OK);
    CHECK(gApi->openConsumer(&second) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(gApi->beginSession(&epoch) == AMCL_INPUT_OK);
    AmclInputEvent capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    capture.payload.capture.requested = 1;
    capture.payload.capture.active = 1;
    capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OK);
    CHECK(gApi->submitEvent(&capture) == AMCL_INPUT_OK);
    CHECK(Drain(first).size() == 1u && Drain(second).size() == 1u);
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(gApi->submitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(Drain(first).size() == 1u && Drain(second).size() == 1u);

    const uint8_t bytes[] = {'a', 'b', 'c'};
    AmclInputEvent text = Event(AMCL_INPUT_EVENT_TEXT_EDITING);
    CHECK(gApi->submitTextPacket(&text, bytes, 3) == AMCL_INPUT_OK);
    AmclInputEvent firstText{};
    AmclInputEvent secondText{};
    CHECK(gApi->nextEvent(first, &firstText) == AMCL_INPUT_OK);
    CHECK(gApi->nextEvent(second, &secondText) == AMCL_INPUT_OK);
    const uint64_t packet = BlobOf(firstText).packetId;
    CHECK(gApi->releasePacket(first, packet) == AMCL_INPUT_OK);
    CHECK(Snapshot().blobBytes == 3u);
    CHECK(gApi->closeConsumer(second) == AMCL_INPUT_OK);
    CHECK(Snapshot().blobBytes == 0u);

    CHECK(gApi->requestReset(AMCL_INPUT_RESET_EXPLICIT) == AMCL_INPUT_OK);
    CHECK(Snapshot().captureActive == 0u);
    Drain(first);
    CHECK(gApi->endSession(epoch) == AMCL_INPUT_OK);
    Drain(first);
    CHECK(gApi->closeConsumer(first) == AMCL_INPUT_OK);
}

void TestCaptureResultFocusAndSurfaceLifecycle() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0u;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0u;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());

    AmclInputSurfacePayload surface{};
    surface.widthPx = 1280u;
    surface.heightPx = 720u;
    surface.active = 1u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(core.PublishSurface(&surface) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);

    // Capture intent is not proof of capture.  The pending publication keeps
    // requested=true while active remains false until the window-manager result
    // is reported separately.
    AmclInputEvent pending = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    pending.payload.capture.requested = 1u;
    pending.payload.capture.active = 0u;
    pending.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_NONE;
    CHECK(core.SubmitEvent(&pending) == AMCL_INPUT_OK);
    auto snapshot = CoreSnapshot(core);
    CHECK(snapshot.captureRequested == 1u);
    CHECK(snapshot.captureActive == 0u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_NONE);

    AmclInputEvent granted = pending;
    granted.payload.capture.active = 1u;
    granted.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(core.SubmitEvent(&granted) == AMCL_INPUT_OK);
    snapshot = CoreSnapshot(core);
    CHECK(snapshot.captureRequested == 1u);
    CHECK(snapshot.captureActive == 1u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_GRANTED);
    CoreDrain(core, consumer);

    const AmclInputEvent held = Key(900u, 17u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&held) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    const uint64_t oldFocusEpoch = CoreSnapshot(core).focusEpoch;
    CHECK(core.PublishFocus(0u) == AMCL_INPUT_OK);
    const auto blurred = CoreDrain(core, consumer);
    CHECK(blurred.size() == 4u);
    CHECK(blurred[0].header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
    CHECK(blurred[0].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
    CHECK(blurred[1].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(blurred[1].payload.reset.reason == AMCL_INPUT_RESET_FOCUS_LOST);
    CHECK(blurred[2].header.eventType == AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    CHECK(blurred[2].payload.capture.requested == 1u);
    CHECK(blurred[2].payload.capture.active == 0u);
    CHECK(blurred[2].payload.capture.reason ==
          AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);
    CHECK(blurred[2].header.focusEpoch == oldFocusEpoch);
    CHECK(blurred[3].header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED);
    CHECK(blurred[3].payload.focus.focused == 0u);
    CHECK(blurred[3].header.focusEpoch == oldFocusEpoch + 1u);
    snapshot = CoreSnapshot(core);
    CHECK(snapshot.focused == 0u);
    CHECK(snapshot.captureRequested == 1u);
    CHECK(snapshot.captureActive == 0u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);

    // Focus regain never grants capture by itself.  A fresh successful platform
    // result is required while the original request remains live.
    CHECK(core.PublishFocus(1u) == AMCL_INPUT_OK);
    auto regained = CoreDrain(core, consumer);
    CHECK(regained.size() == 1u);
    CHECK(regained[0].header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED);
    CHECK(CoreSnapshot(core).captureActive == 0u);
    CHECK(core.SubmitEvent(&granted) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(CoreSnapshot(core).captureActive == 1u);

    const uint64_t oldSurfaceEpoch = CoreSnapshot(core).surfaceEpoch;
    surface.active = 0u;
    CHECK(core.PublishSurface(&surface) == AMCL_INPUT_OK);
    const auto lostSurface = CoreDrain(core, consumer);
    CHECK(lostSurface.size() == 3u);
    CHECK(lostSurface[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(lostSurface[0].payload.reset.reason ==
          AMCL_INPUT_RESET_SURFACE_CHANGED);
    CHECK(lostSurface[1].header.eventType == AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    CHECK(lostSurface[1].payload.capture.requested == 1u);
    CHECK(lostSurface[1].payload.capture.active == 0u);
    CHECK(lostSurface[1].payload.capture.reason ==
          AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);
    CHECK(lostSurface[1].header.surfaceEpoch == oldSurfaceEpoch);
    CHECK(lostSurface[2].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(lostSurface[2].header.surfaceEpoch == oldSurfaceEpoch + 1u);
    snapshot = CoreSnapshot(core);
    CHECK(snapshot.captureRequested == 1u);
    CHECK(snapshot.captureActive == 0u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);

    // Impossible result tuples must fail before changing the authoritative
    // capture state.
    AmclInputEvent malformed = pending;
    malformed.payload.capture.requested = 0u;
    malformed.payload.capture.active = 1u;
    malformed.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(core.SubmitEvent(&malformed) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    malformed = pending;
    malformed.payload.capture.active = 1u;
    malformed.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_NONE;
    CHECK(core.SubmitEvent(&malformed) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    malformed = pending;
    malformed.payload.capture.active = 0u;
    malformed.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(core.SubmitEvent(&malformed) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    snapshot = CoreSnapshot(core);
    CHECK(snapshot.captureRequested == 1u);
    CHECK(snapshot.captureActive == 0u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);

    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
}

void TestSequenceExhaustionAtomicity() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());

    const AmclInputEvent down = Key(201u, 17u, AMCL_INPUT_ACTION_DOWN);
    core.TestSetNextSequence(UINT64_MAX);
    const auto beforeDown = CoreSnapshot(core);
    CHECK(core.SubmitEvent(&down) == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(core.SubmitEvent(&down) == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeDown);
    CHECK(CoreDrain(core, consumer).empty());

    core.TestSetNextSequence(100u);
    CHECK(core.SubmitEvent(&down) == AMCL_INPUT_OK);
    auto output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u && output[0].header.sequence == 100u);
    CHECK(CoreSnapshot(core).heldControlCount == 1u);

    core.TestSetNextSequence(UINT64_MAX - 1u);
    const auto beforeLifecycle = CoreSnapshot(core);
    CHECK(core.PublishFocus(0u) == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(core.PublishFocus(0u) == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeLifecycle);
    CHECK(CoreDrain(core, consumer).empty());

    core.TestSetNextSequence(UINT64_MAX - 3u);
    CHECK(core.PublishFocus(0u) == AMCL_INPUT_OK);
    output = CoreDrain(core, consumer);
    CHECK(output.size() == 3u);
    CHECK(output.front().header.sequence == UINT64_MAX - 3u);
    CHECK(output.back().header.sequence == UINT64_MAX - 1u);
    const auto exhausted = CoreSnapshot(core);
    CHECK(core.RequestReset(AMCL_INPUT_RESET_EXPLICIT) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(core.RequestReset(AMCL_INPUT_RESET_EXPLICIT) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), exhausted);

    core.TestSetNextSequence(200u);
    CHECK(core.PublishFocus(1u) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
}

void TestTextAndBaselineExhaustionAtomicity() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(core.SubmitEvent(&textStart) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).size() == 1u);
    const uint8_t byte = static_cast<uint8_t>('q');
    AmclInputEvent text = Event(AMCL_INPUT_EVENT_TEXT_COMMIT);

    core.TestSetNextSequence(300u);
    core.TestSetNextPacket(UINT64_MAX);
    const auto beforePacket = CoreSnapshot(core);
    CHECK(core.SubmitTextPacket(&text, &byte, 1u) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(core.SubmitTextPacket(&text, &byte, 1u) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforePacket);
    CHECK(CoreDrain(core, consumer).empty());

    core.TestSetNextPacket(77u);
    CHECK(core.SubmitTextPacket(&text, &byte, 1u) == AMCL_INPUT_OK);
    auto output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u && output[0].header.sequence == 300u);
    CHECK(BlobOf(output[0]).packetId == 77u);
    CHECK(core.ReleasePacket(consumer, 77u) == AMCL_INPUT_OK);

    core.TestSetNextSequence(UINT64_MAX);
    core.TestSetNextPacket(78u);
    const auto beforeSequence = CoreSnapshot(core);
    CHECK(core.SubmitTextPacket(&text, &byte, 1u) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeSequence);
    CHECK(CoreDrain(core, consumer).empty());
    core.TestSetNextSequence(400u);
    CHECK(core.SubmitTextPacket(&text, &byte, 1u) == AMCL_INPUT_OK);
    output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u && output[0].header.sequence == 400u);
    CHECK(BlobOf(output[0]).packetId == 78u);
    CHECK(core.ReleasePacket(consumer, 78u) == AMCL_INPUT_OK);

    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);

    amcl::input::InputStateCore baselineCore;
    uint64_t baselineEpoch = 0;
    CHECK(baselineCore.BeginSession(&baselineEpoch) == AMCL_INPUT_OK);
    AmclInputSurfacePayload baselineSurface{};
    baselineSurface.active = 1u;
    baselineSurface.widthPx = 640u;
    baselineSurface.heightPx = 480u;
    baselineSurface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
        AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    baselineSurface.publicationGeneration = 91u;
    CHECK(baselineCore.PublishSurface(&baselineSurface) == AMCL_INPUT_OK);
    const uint64_t baselineSurfaceEpoch =
        CoreSnapshot(baselineCore).surfaceEpoch;
    // Exactly one sequence remains, but an active session with a current
    // surface must atomically reserve both RESET and SURFACE replay controls.
    baselineCore.TestSetNextSequence(UINT64_MAX - 1u);
    AmclInputConsumerHandle late = UINT64_C(0x1234);
    const auto beforeOpen = CoreSnapshot(baselineCore);
    CHECK(baselineCore.OpenConsumer(&late) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(late == UINT64_C(0x1234));
    CHECK(baselineCore.OpenConsumer(&late) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(late == UINT64_C(0x1234));
    CheckSnapshotStateEqual(CoreSnapshot(baselineCore), beforeOpen);
    baselineCore.TestSetNextSequence(500u);
    CHECK(baselineCore.OpenConsumer(&late) == AMCL_INPUT_OK);
    output = CoreDrain(baselineCore, late);
    CHECK(output.size() == 2u && output[0].header.sequence == 500u);
    CHECK(output[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    CHECK(output[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(output[1].header.sequence == 501u);
    CHECK(output[1].header.surfaceEpoch == baselineSurfaceEpoch);
    CHECK(output[1].payload.surface.publicationGeneration == 91u);
    CHECK(baselineCore.EndSession(baselineEpoch) == AMCL_INPUT_OK);
    CoreDrain(baselineCore, late);
    CHECK(baselineCore.CloseConsumer(late) == AMCL_INPUT_OK);
}

void TestBatchAndSessionCounterBoundaries() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    AmclInputEvent moves[] = {
        Event(AMCL_INPUT_EVENT_POINTER_RELATIVE),
        Event(AMCL_INPUT_EVENT_POINTER_RELATIVE),
    };
    core.TestSetNextSequence(UINT64_MAX - 1u);
    const auto beforeBatch = CoreSnapshot(core);
    CHECK(core.SubmitBatch(moves, 2u) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeBatch);
    CHECK(CoreDrain(core, consumer).empty());
    CHECK(core.SubmitEvent(&moves[0]) == AMCL_INPUT_OK);
    auto output = CoreDrain(core, consumer);
    CHECK(output.size() == 1u &&
          output[0].header.sequence == UINT64_MAX - 1u);

    uint64_t rollover = UINT64_C(0xfeed);
    const auto beforeBegin = CoreSnapshot(core);
    CHECK(core.BeginSession(&rollover) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(rollover == UINT64_C(0xfeed));
    CHECK(core.BeginSession(&rollover) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeBegin);

    core.TestSetNextSequence(600u);
    CHECK(core.BeginSession(&rollover) == AMCL_INPUT_OK);
    CHECK(rollover != epoch);
    CoreDrain(core, consumer);
    core.TestSetNextSequence(UINT64_MAX);
    const auto beforeEnd = CoreSnapshot(core);
    CHECK(core.EndSession(rollover) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(core.EndSession(rollover) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeEnd);
    core.TestSetNextSequence(700u);
    CHECK(core.EndSession(rollover) == AMCL_INPUT_OK);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);

    amcl::input::InputStateCore epochCore;
    epochCore.TestSetEpochs(UINT64_MAX, 0u, 0u);
    uint64_t failedEpoch = UINT64_C(0xbeef);
    const auto maxSession = CoreSnapshot(epochCore);
    CHECK(epochCore.BeginSession(&failedEpoch) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(failedEpoch == UINT64_C(0xbeef));
    CHECK(epochCore.BeginSession(&failedEpoch) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(epochCore), maxSession);

    epochCore.TestSetEpochs(0u, 0u, 0u);
    CHECK(epochCore.BeginSession(&failedEpoch) == AMCL_INPUT_OK);
    const auto active = CoreSnapshot(epochCore);
    epochCore.TestSetEpochs(active.sessionEpoch, UINT64_MAX,
                            active.surfaceEpoch);
    const auto maxFocus = CoreSnapshot(epochCore);
    CHECK(epochCore.EndSession(active.sessionEpoch) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(epochCore.EndSession(active.sessionEpoch) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CheckSnapshotStateEqual(CoreSnapshot(epochCore), maxFocus);
    epochCore.TestSetEpochs(active.sessionEpoch, active.focusEpoch,
                            active.surfaceEpoch);
    CHECK(epochCore.EndSession(active.sessionEpoch) == AMCL_INPUT_OK);
}

// ⭐ 多后端 READY 槽（计划 §97）。此前结构上不成立：READY 是**单槽**，第二个后端申领
// 拿到 RESOURCE_EXHAUSTED —— 那个返回码看起来像"资源不够"，实际含义是"这里只能有一个"。
void TestMultipleBackendReadySlots() {
    amcl::input::InputStateCore core(true);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);

    AmclInputConsumerHandle glfw = 0;
    AmclInputConsumerHandle sdl3 = 0;
    AmclInputConsumerHandle lwjgl2 = 0;
    CHECK(core.OpenConsumer(&glfw) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&sdl3) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&lwjgl2) == AMCL_INPUT_OK);
    const AmclInputEvent glfwBase = CoreBaseline(core, glfw);
    const AmclInputEvent sdlBase = CoreBaseline(core, sdl3);
    const AmclInputEvent l2Base = CoreBaseline(core, lwjgl2);

    // 三个后端各自 READY，互不排斥。
    const AmclInputEvent glfwReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, glfw, epoch,
        glfwBase.header.sequence, AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    const AmclInputEvent sdlReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, sdl3, epoch,
        sdlBase.header.sequence, AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    const AmclInputEvent l2Ready = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, lwjgl2, epoch,
        l2Base.header.sequence, AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL);
    CHECK(core.SubmitEvent(&glfwReady) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&sdlReady) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&l2Ready) == AMCL_INPUT_OK);

    // 同一个后端第二个消费者仍必须被拒 —— 隔离是**按后端**的，不是取消了唯一性。
    AmclInputConsumerHandle intruder = 0;
    CHECK(core.OpenConsumer(&intruder) == AMCL_INPUT_OK);
    const AmclInputEvent intruderBase = CoreBaseline(core, intruder);
    const AmclInputEvent intruderReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, intruder, epoch,
        intruderBase.header.sequence, AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    CHECK(core.SubmitEvent(&intruderReady) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);

    // 未知 backend id 一律 fail closed（槽按 backend-1 索引，放过去就是越界写）。
    AmclInputEvent unknown = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, intruder, epoch,
        intruderBase.header.sequence, AMCL_INPUT_BACKEND_COUNT);
    CHECK(core.SubmitEvent(&unknown) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    unknown.payload.backendConsumerState.backend = 0u;
    CHECK(core.SubmitEvent(&unknown) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    // ⭐ 退休一个后端**不得**关掉别的后端：生产者闸门是"任一 READY"。
    const AmclInputEvent sdlRetire = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE, sdl3, epoch, 0u,
        AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    CHECK(core.SubmitEvent(&sdlRetire) == AMCL_INPUT_OK);
    const AmclInputEvent key = Key(31u, 2017u, AMCL_INPUT_ACTION_DOWN, epoch);
    CHECK(core.SubmitEvent(&key) == AMCL_INPUT_OK);

    // 一个消费者不得改换后端：它的退休屏障会留在旧槽里再也不会被清。
    const AmclInputEvent switched = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, glfw, epoch,
        glfwBase.header.sequence, AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL);
    CHECK(core.SubmitEvent(&switched) == AMCL_INPUT_ERROR_STALE);

    // 全部后端退出之后闸门才重新关上。
    const AmclInputEvent glfwAbandon = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_ABANDON, glfw, epoch, 0u,
        AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    const AmclInputEvent l2Abandon = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_ABANDON, lwjgl2, epoch, 0u,
        AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL);
    const AmclInputEvent sdlAbandon = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_ABANDON, sdl3, epoch, 0u,
        AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    CHECK(core.SubmitEvent(&glfwAbandon) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&key) == AMCL_INPUT_OK);  // LWJGL2 仍 READY
    CHECK(core.SubmitEvent(&l2Abandon) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&sdlAbandon) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&key) == AMCL_INPUT_ERROR_BACKEND_NOT_READY);
}

void TestTypedBackendReadyBarrier() {
    amcl::input::InputStateCore core(true);
    AmclInputConsumerHandle consumer = 0;
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    const AmclInputEvent baseline = CoreBaseline(core, consumer);

    AmclInputEvent key = Key(11u, 2017u, AMCL_INPUT_ACTION_DOWN, epoch);
    AmclInputEvent relative = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch);
    relative.header.source = AMCL_INPUT_SOURCE_MOUSE;
    relative.payload.pointerRelative.rawDx = 1.25;
    relative.payload.pointerRelative.rawDy = -2.5;
    AmclInputEvent button = Button(12u, 4u, AMCL_INPUT_ACTION_DOWN, epoch);
    AmclInputEvent wheel = Event(AMCL_INPUT_EVENT_POINTER_WHEEL, epoch);
    wheel.header.source = AMCL_INPUT_SOURCE_MOUSE;
    wheel.payload.pointerWheel.x = 0.5f;
    wheel.payload.pointerWheel.y = 15.0f;
    wheel.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_DEGREE;
    wheel.payload.pointerWheel.precise = 1u;
    AmclInputEvent enter = Event(AMCL_INPUT_EVENT_POINTER_ENTER, epoch);
    enter.header.source = AMCL_INPUT_SOURCE_MOUSE;
    enter.payload.pointerEnter.entered = 1u;
    AmclInputEvent absolute = Event(
        AMCL_INPUT_EVENT_POINTER_ABSOLUTE, epoch);
    absolute.header.source = AMCL_INPUT_SOURCE_MOUSE;
    absolute.payload.pointerAbsolute.localPxX = 10.0;
    absolute.payload.pointerAbsolute.localPxY = 20.0;
    AmclInputEvent physical[] = {
        key, absolute, relative, button, wheel, enter};

    const auto beforeReady = CoreSnapshot(core);
    for (const auto& event : physical) {
        CHECK(core.SubmitEvent(&event) ==
              AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    }
    AmclInputEvent producerFlagged = relative;
    producerFlagged.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
    CHECK(core.SubmitEvent(&producerFlagged) ==
          AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeReady);

    AmclInputEvent ready = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, consumer, epoch,
        baseline.header.sequence + 1u);
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_ERROR_STALE);
    ready.payload.backendConsumerState.baselineSequence =
        baseline.header.sequence;
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);
    constexpr size_t kAcceptedBeforeRetire = 5u;
    for (size_t i = 0; i < kAcceptedBeforeRetire; ++i) {
        CHECK(core.SubmitEvent(&physical[i]) == AMCL_INPUT_OK);
    }

    // READY and pre-ready rejections consume no sequence. Five accepted
    // physical packets (including absolute) plus two held releases and RESET
    // exactly fit the bounded queue and remain pending until RETIRE.
    AmclInputEvent retire = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE, consumer, epoch);
    CHECK(core.SubmitEvent(&retire) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&relative) ==
          AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_DRAIN_REQUIRED);

    const auto drained = CoreDrain(core, consumer);
    CHECK(drained.size() == 8u);
    for (size_t i = 0; i < kAcceptedBeforeRetire; ++i) {
        CHECK(drained[i].header.eventType == physical[i].header.eventType);
        CHECK(drained[i].header.sequence == baseline.header.sequence + 1u + i);
    }
    CHECK(drained[5].header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
    CHECK(drained[5].payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
    CHECK(drained[6].header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(drained[6].payload.pointerButton.action == AMCL_INPUT_ACTION_UP);
    CHECK(drained[7].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(drained[7].payload.reset.reason ==
          AMCL_INPUT_RESET_BACKEND_RETIRED);
    CHECK(CoreSnapshot(core).heldControlCount == 0u);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
}

void TestTypedBackendOwnerRolloverAndBlobDrain() {
    amcl::input::InputStateCore core(true);
    AmclInputConsumerHandle first = 0;
    AmclInputConsumerHandle waiting = 0;
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&first) == AMCL_INPUT_OK);
    const auto firstBaseline = CoreBaseline(core, first);
    CHECK(core.OpenConsumer(&waiting) == AMCL_INPUT_OK);
    const auto waitingBaseline = CoreBaseline(core, waiting);
    AmclInputEvent firstReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, first, epoch,
        firstBaseline.header.sequence);
    CHECK(core.SubmitEvent(&firstReady) == AMCL_INPUT_OK);

    AmclInputEvent waitingReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, waiting, epoch,
        waitingBaseline.header.sequence);
    CHECK(core.SubmitEvent(&waitingReady) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);

    AmclInputEvent textStart = TextSession(
        AMCL_INPUT_TEXT_SESSION_STARTED, kTextSessionId, epoch);
    CHECK(core.SubmitEvent(&textStart) == AMCL_INPUT_OK);
    AmclInputEvent started{};
    CHECK(core.NextEvent(first, &started) == AMCL_INPUT_OK);
    CHECK(started.header.eventType ==
          AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    AmclInputEvent text = Event(AMCL_INPUT_EVENT_TEXT_COMMIT, epoch);
    const uint8_t bytes[] = {'o', 'k'};
    CHECK(core.SubmitTextPacket(&text, bytes, sizeof(bytes)) == AMCL_INPUT_OK);
    CHECK(core.CloseConsumer(first) == AMCL_INPUT_DRAIN_REQUIRED);

    AmclInputEvent packet{};
    CHECK(core.NextEvent(first, &packet) == AMCL_INPUT_OK);
    CHECK(packet.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
    CHECK(core.CloseConsumer(first) == AMCL_INPUT_DRAIN_REQUIRED);
    CHECK(core.ReleasePacket(first,
                             packet.payload.textCommit.utf8Blob.packetId) ==
          AMCL_INPUT_OK);
    // The implicit RETIRE reset remains after the blob event.
    const auto tail = CoreDrain(core, first);
    CHECK(tail.size() == 1u);
    CHECK(tail[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(tail[0].payload.reset.reason == AMCL_INPUT_RESET_BACKEND_RETIRED);
    CHECK(core.CloseConsumer(first) == AMCL_INPUT_OK);

    // A consumer that waited beside the prior owner accumulated that owner's
    // traffic and cannot be promoted with a stale baseline. It must reopen.
    CHECK(core.SubmitEvent(&waitingReady) == AMCL_INPUT_ERROR_STALE);
    CHECK(core.CloseConsumer(waiting) == AMCL_INPUT_OK);
    AmclInputConsumerHandle fresh = 0;
    CHECK(core.OpenConsumer(&fresh) == AMCL_INPUT_OK);
    const auto freshBaseline = CoreBaseline(core, fresh);
    AmclInputEvent freshReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, fresh, epoch,
        freshBaseline.header.sequence);
    CHECK(core.SubmitEvent(&freshReady) == AMCL_INPUT_OK);

    AmclInputEvent batch[] = {freshReady, Event(AMCL_INPUT_EVENT_POINTER_ENTER,
                                                epoch)};
    batch[1].payload.pointerEnter.entered = 1u;
    const auto beforeBatch = CoreSnapshot(core);
    CHECK(core.SubmitBatch(batch, 2u) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CheckSnapshotStateEqual(CoreSnapshot(core), beforeBatch);

    const uint64_t oldEpoch = epoch;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(epoch != oldEpoch);
    AmclInputEvent relative = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch);
    relative.payload.pointerRelative.rawDx = 1.0;
    relative.payload.pointerRelative.rawDy = 1.0;
    CHECK(core.SubmitEvent(&relative) ==
          AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    CoreDrain(core, fresh);
    CHECK(core.CloseConsumer(fresh) == AMCL_INPUT_OK);
}

void TestTypedBackendSequenceExhaustionAndAbandon() {
    amcl::input::InputStateCore core(true);
    AmclInputConsumerHandle maintenance = 0;
    AmclInputConsumerHandle backend = 0;
    CHECK(core.OpenConsumer(&maintenance) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&backend) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, maintenance).empty());
    // Consumers opened before BeginSession have no baseline and cannot claim
    // backend readiness; open the actual backend in the active epoch.
    CHECK(core.CloseConsumer(backend) == AMCL_INPUT_OK);
    CHECK(core.OpenConsumer(&backend) == AMCL_INPUT_OK);
    const auto baseline = CoreBaseline(core, backend);
    AmclInputEvent ready = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, backend, epoch,
        baseline.header.sequence);
    CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);

    AmclInputEvent key = Key(22u, 90u, AMCL_INPUT_ACTION_DOWN, epoch);
    CHECK(core.SubmitEvent(&key) == AMCL_INPUT_OK);
    core.TestSetNextSequence(UINT64_MAX);
    AmclInputEvent retire = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_RETIRE, backend, epoch);
    CHECK(core.SubmitEvent(&retire) ==
          AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(CoreSnapshot(core).heldControlCount == 0u);
    CHECK(core.SubmitEvent(&key) == AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    CoreDrain(core, backend);
    CHECK(core.CloseConsumer(backend) == AMCL_INPUT_OK);

    // A second core proves explicit ABANDON removes only the failed backend's
    // recipients and leaves an observable reset for maintenance.
    amcl::input::InputStateCore abandonCore(true);
    AmclInputConsumerHandle observer = 0;
    AmclInputConsumerHandle failed = 0;
    CHECK(abandonCore.OpenConsumer(&observer) == AMCL_INPUT_OK);
    uint64_t abandonEpoch = 0;
    CHECK(abandonCore.BeginSession(&abandonEpoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(abandonCore, observer).empty());
    CHECK(abandonCore.OpenConsumer(&failed) == AMCL_INPUT_OK);
    const auto failedBaseline = CoreBaseline(abandonCore, failed);
    AmclInputEvent failedReady = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, failed, abandonEpoch,
        failedBaseline.header.sequence);
    CHECK(abandonCore.SubmitEvent(&failedReady) == AMCL_INPUT_OK);
    AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE,
                                abandonEpoch);
    move.payload.pointerRelative.rawDx = 3.0;
    CHECK(abandonCore.SubmitEvent(&move) == AMCL_INPUT_OK);
    AmclInputEvent abandon = BackendControl(
        AMCL_INPUT_BACKEND_CONSUMER_ABANDON, failed, abandonEpoch);
    CHECK(abandonCore.SubmitEvent(&abandon) == AMCL_INPUT_OK);
    CHECK(abandonCore.CloseConsumer(failed) == AMCL_INPUT_ERROR_NOT_FOUND);
    const auto observed = CoreDrain(abandonCore, observer);
    CHECK(observed.size() == 2u);
    CHECK(observed[0].header.eventType ==
          AMCL_INPUT_EVENT_POINTER_RELATIVE);
    CHECK(observed[1].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(observed[1].payload.reset.reason ==
          AMCL_INPUT_RESET_BACKEND_ABANDONED);
}

void TestTypedBackendSubmitRetireLinearization() {
    constexpr size_t kRounds = 64u;
    // Host tests deliberately use an eight-record queue. Keep one prefix, all
    // racing events, and the retire RESET below capacity so this test isolates
    // the ownership barrier rather than exercising the separately-covered
    // overflow replacement contract.
    constexpr size_t kRacingEvents = 4u;
    for (size_t round = 0; round < kRounds; ++round) {
        amcl::input::InputStateCore core(true);
        uint64_t epoch = 0u;
        CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
        AmclInputConsumerHandle backend = 0u;
        CHECK(core.OpenConsumer(&backend) == AMCL_INPUT_OK);
        const auto baseline = CoreBaseline(core, backend);
        AmclInputEvent ready = BackendControl(
            AMCL_INPUT_BACKEND_CONSUMER_READY, backend, epoch,
            baseline.header.sequence);
        CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);

        AmclInputEvent prefix = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch);
        prefix.payload.pointerRelative.rawDx = -1.0;
        prefix.payload.pointerRelative.rawDy = static_cast<double>(round);
        CHECK(core.SubmitEvent(&prefix) == AMCL_INPUT_OK);

        std::vector<int32_t> results(kRacingEvents,
                                     AMCL_INPUT_ERROR_INVALID_ARGUMENT);
        std::atomic<uint32_t> atBarrier{0u};
        std::atomic<bool> start{false};
        int32_t retireResult = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        std::thread submitter([&]() {
            atBarrier.fetch_add(1u, std::memory_order_release);
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            for (size_t index = 0; index < kRacingEvents; ++index) {
                AmclInputEvent event = Event(
                    AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch);
                event.payload.pointerRelative.rawDx =
                    static_cast<double>(index + 1u);
                event.payload.pointerRelative.rawDy =
                    static_cast<double>(round);
                results[index] = core.SubmitEvent(&event);
            }
        });
        std::thread retirer([&]() {
            atBarrier.fetch_add(1u, std::memory_order_release);
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            AmclInputEvent retire = BackendControl(
                AMCL_INPUT_BACKEND_CONSUMER_RETIRE, backend, epoch);
            retireResult = core.SubmitEvent(&retire);
        });
        while (atBarrier.load(std::memory_order_acquire) != 2u) {
            std::this_thread::yield();
        }
        start.store(true, std::memory_order_release);
        submitter.join();
        retirer.join();
        CHECK(retireResult == AMCL_INPUT_OK);

        std::vector<bool> expected(kRacingEvents, false);
        size_t accepted = 0u;
        for (size_t index = 0; index < results.size(); ++index) {
            if (results[index] == AMCL_INPUT_OK) {
                expected[index] = true;
                ++accepted;
            } else {
                if (results[index] != AMCL_INPUT_ERROR_BACKEND_NOT_READY) {
                    std::cerr << "unexpected race result round=" << round
                              << " index=" << index
                              << " status=" << results[index] << '\n';
                }
                CHECK(results[index] == AMCL_INPUT_ERROR_BACKEND_NOT_READY);
            }
        }
        const auto drained = CoreDrain(core, backend);
        CHECK(drained.size() == accepted + 2u);
        CHECK(drained.front().header.eventType ==
              AMCL_INPUT_EVENT_POINTER_RELATIVE);
        CHECK(drained.front().payload.pointerRelative.rawDx == -1.0);
        std::vector<bool> observed(kRacingEvents, false);
        for (size_t index = 1u; index + 1u < drained.size(); ++index) {
            const auto& event = drained[index];
            CHECK(event.header.eventType == AMCL_INPUT_EVENT_POINTER_RELATIVE);
            CHECK(event.payload.pointerRelative.rawDy ==
                  static_cast<double>(round));
            const double raw = event.payload.pointerRelative.rawDx;
            CHECK(raw >= 1.0 && raw <= static_cast<double>(kRacingEvents));
            const size_t slot = static_cast<size_t>(raw - 1.0);
            CHECK(!observed[slot]);
            observed[slot] = true;
        }
        CHECK(observed == expected);
        CHECK(drained.back().header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(drained.back().payload.reset.reason ==
              AMCL_INPUT_RESET_BACKEND_RETIRED);
        CHECK(core.CloseConsumer(backend) == AMCL_INPUT_OK);
    }
}

}  // namespace

// §11 observability. Uses a private core rather than the exported singleton so
// the accumulators start from a known zero without depending on which tests ran
// before, and so the no-consumer case is reachable at all.
void TestObservabilityMetrics() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());

    CHECK(core.GetObservability(nullptr) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    amcl::input::CoreObservabilityV1 m = CoreObs(core);
    // BeginSession clears the accumulators; the epochs it advanced are visible.
    CHECK(m.physicalDown == 0u && m.physicalRepeat == 0u && m.physicalUp == 0u);
    CHECK(m.accepted == 0u && m.queueWrites == 0u && m.queueReads == 0u);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    CHECK(m.sessionEpoch == epoch && m.focusEpoch != 0u && m.surfaceEpoch != 0u);

    // Two devices holding one key each: §11 wants the owner count keyed by
    // device, which an aggregate control count cannot express.
    const AmclInputEvent downA = Key(701u, 30u, AMCL_INPUT_ACTION_DOWN);
    const AmclInputEvent downB = Key(702u, 30u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&downA) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&downB) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == 2u);
    CHECK(m.heldControlCount == 2u && m.heldOwnerDeviceCount == 2u);
    CHECK(m.maxHeldControlCount == 2u && m.maxHeldOwnerDeviceCount == 2u);
    // Two controls on one device must not inflate the owner count.
    const AmclInputEvent downA2 = Key(701u, 31u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&downA2) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == 3u);
    CHECK(m.heldControlCount == 3u && m.heldOwnerDeviceCount == 2u);
    CHECK(m.maxHeldControlCount == 3u && m.maxHeldOwnerDeviceCount == 2u);

    // A duplicate DOWN leaves core as REPEAT, so it must be counted as a repeat.
    // Counting it as a second DOWN would make down/up look unbalanced forever.
    CHECK(core.SubmitEvent(&downA) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == 3u && m.physicalRepeat == 1u);
    CHECK(m.heldControlCount == 3u);

    // A rejected edge is a diagnostic drop, never a physical action.
    const AmclInputEvent ownerlessUp = Key(799u, 30u, AMCL_INPUT_ACTION_UP);
    CHECK(core.SubmitEvent(&ownerlessUp) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.diagnosticDrops == 1u);
    CHECK(m.physicalUp == 0u);

    const AmclInputEvent upA = Key(701u, 30u, AMCL_INPUT_ACTION_UP);
    CHECK(core.SubmitEvent(&upA) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalUp == 1u && m.physicalUpSynthetic == 0u);
    CHECK(m.heldControlCount == 2u && m.heldOwnerDeviceCount == 2u);

    // Host builds run with AMCL_INPUT_QUEUE_CAPACITY=8. Drain here so the
    // capture-loss reset below (which needs held.size()+2 free slots) exercises
    // the ordinary lifecycle path instead of the overflow path; the overflow
    // path has its own coverage in TestLifecycleOverflowTransitions.
    CoreDrain(core, consumer);

    // Capture accounting: requested+active is an activation, not a loss.
    AmclInputEvent capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    capture.payload.capture.requested = 1u;
    capture.payload.capture.active = 1u;
    capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(core.SubmitEvent(&capture) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.captureRequested == 1u && m.captureActivated == 1u);
    CHECK(m.captureLost == 0u);

    // Losing capture must land in the matching reason bucket and nowhere else.
    AmclInputEvent captureLost = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    captureLost.payload.capture.requested = 0u;
    captureLost.payload.capture.active = 0u;
    captureLost.payload.capture.reason =
        AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST;
    const uint64_t resetsBeforeLoss = m.resetsEmitted;
    CHECK(core.SubmitEvent(&captureLost) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.captureLost == 1u);
    CHECK(m.captureLostByReason[AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST] == 1u);
    CHECK(m.captureLostByReason[AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST] == 0u);
    CHECK(m.captureLostByReason[AMCL_INPUT_CAPTURE_REASON_NONE] == 0u);
    CHECK(m.captureLostUnknownReason == 0u);
    // Capture loss clears held state through a reset, so §11's post-reset
    // invariant must hold and the synthetic releases must be attributed.
    CHECK(m.resetsEmitted == resetsBeforeLoss + 1u);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    CHECK(m.physicalUpSynthetic == 2u);
    // Down/up balance only closes when synthetic releases are inside the total.
    CHECK(m.physicalDown == 3u && m.physicalUp == 3u);

    CoreDrain(core, consumer);

    // Text: selection travels as an ordinary event, commit/edit as a packet.
    AmclInputEvent textStart = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED);
    CHECK(core.SubmitEvent(&textStart) == AMCL_INPUT_OK);
    AmclInputEvent selection = Event(AMCL_INPUT_EVENT_TEXT_SELECTION);
    CHECK(core.SubmitEvent(&selection) == AMCL_INPUT_OK);
    const uint8_t bytes[] = {'x', 'y'};
    AmclInputEvent commit = Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    CHECK(core.SubmitTextPacket(&commit, bytes, 2u) == AMCL_INPUT_OK);
    AmclInputEvent editing = Event(AMCL_INPUT_EVENT_TEXT_EDITING);
    CHECK(core.SubmitTextPacket(&editing, bytes, 2u) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.textSelections == 1u && m.textCommits == 1u && m.textEdits == 1u);
    CHECK(m.textCandidates == 0u);
    CHECK(m.textSessionStarts == 1u);

    // Queue reads: draining must move queueReads by exactly the event count,
    // and lastSequence must match the last event a consumer actually saw.
    const uint64_t readsBeforeDrain = CoreObs(core).queueReads;
    const auto drained = CoreDrain(core, consumer);
    CHECK(!drained.empty());
    m = CoreObs(core);
    CHECK(m.queueReads == readsBeforeDrain + drained.size());
    CHECK(m.lastSequence == drained.back().header.sequence);
    CHECK(m.lastMonotonicTimeNs == drained.back().header.monotonicTimeNs);
    // Everything accepted reached this one consumer, so nothing was recipientless.
    CHECK(m.accepted == m.queueWrites);
    CHECK(m.acceptedWithoutRecipient == 0u);

    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
    const uint64_t sessionEpochBeforeEnd = CoreObs(core).sessionEpoch;
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    // EndSession emits the summary and must not clear the accumulators: a
    // teardown record that reads all-zero would be worse than none.
    m = CoreObs(core);
    CHECK(m.physicalDown == 3u);
    CHECK(m.sessionEpoch == sessionEpochBeforeEnd + 1u);
    // BeginSession is what clears them.
    uint64_t nextEpoch = 0;
    CHECK(core.BeginSession(&nextEpoch) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == 0u && m.physicalUp == 0u && m.accepted == 0u);
    CHECK(m.captureLost == 0u && m.textCommits == 0u && m.queueReads == 0u);
    CHECK(m.maxHeldControlCount == 0u && m.maxHeldOwnerDeviceCount == 0u);
    CHECK(core.EndSession(nextEpoch) == AMCL_INPUT_OK);
}

// A session with no consumer still moves held state and still spends sequences.
// §11 forbids silent drops, so that case must be countable and must not be
// reported as a queue write.
void TestObservabilityWithoutConsumer() {
    amcl::input::InputStateCore core;
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    const AmclInputEvent down = Key(801u, 44u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&down) == AMCL_INPUT_OK);
    amcl::input::CoreObservabilityV1 m = CoreObs(core);
    CHECK(m.physicalDown == 1u);
    CHECK(m.heldControlCount == 1u && m.heldOwnerDeviceCount == 1u);
    CHECK(m.accepted == 1u);
    CHECK(m.queueWrites == 0u);
    CHECK(m.acceptedWithoutRecipient == 1u);
    CHECK(m.queueReads == 0u);
    CHECK(m.lastSequence != 0u);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    // The end-of-session reset releases the held key even with nobody listening.
    m = CoreObs(core);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    CHECK(m.physicalUp == 1u && m.physicalUpSynthetic == 1u);
    // Logging must be safe to call outside a session and must not deadlock
    // against the mutex GetObservability takes.
    core.LogObservabilitySummary("host-test");
    core.LogObservabilitySummary(nullptr);
}

// A batch that fails partway is rolled back. The §11 accumulators are part of
// that rollback: leaving increments from the discarded prefix behind would make
// the metrics describe a state the core does not have.
void TestObservabilityBatchRollback() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());
    const amcl::input::CoreObservabilityV1 before = CoreObs(core);

    // An invalid payload is caught by the pre-loop sweep, before any event is
    // applied. Nothing to roll back, so this only proves nothing was counted.
    AmclInputEvent batch[2];
    batch[0] = Key(901u, 51u, AMCL_INPUT_ACTION_DOWN);
    batch[1] = Key(901u, 52u, AMCL_INPUT_ACTION_DOWN);
    batch[1].payload.physicalKey.action = 99u;
    CHECK(core.SubmitBatch(batch, 2u) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    amcl::input::CoreObservabilityV1 m = CoreObs(core);
    CHECK(m.physicalDown == before.physicalDown);
    CHECK(m.accepted == before.accepted);
    CHECK(m.queueWrites == before.queueWrites);
    CHECK(m.heldControlCount == 0u);

    // The real rollback path: a stale sessionEpoch passes ValidatePayload but is
    // rejected by Validate *inside* the per-event loop, so entry 0 has already
    // been applied and counted when the failure happens. Without restoring the
    // accumulators the batch would leave one phantom DOWN behind.
    batch[1].payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
    batch[1].header.sessionEpoch = epoch + 100u;
    CHECK(core.SubmitBatch(batch, 2u) == AMCL_INPUT_ERROR_STALE);
    m = CoreObs(core);
    CHECK(m.physicalDown == before.physicalDown);
    CHECK(m.accepted == before.accepted);
    CHECK(m.queueWrites == before.queueWrites);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    CHECK(CoreDrain(core, consumer).empty());

    // Same seam via overflow: the prefix applies, capacity runs out mid-batch,
    // the prefix is rolled back and one OverflowReset replaces it. So the
    // physical counts must be untouched while exactly one reset is recorded.
    const amcl::input::CoreObservabilityV1 beforeOverflow = CoreObs(core);
    std::vector<AmclInputEvent> big;
    big.push_back(Key(902u, 60u, AMCL_INPUT_ACTION_DOWN));
    for (int i = 0; i < 9; ++i) {
        AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        move.payload.pointerRelative.rawDx = static_cast<double>(i);
        big.push_back(move);
    }
    CHECK(core.SubmitBatch(big.data(), static_cast<uint32_t>(big.size())) ==
          AMCL_INPUT_OVERFLOW_RESET);
    m = CoreObs(core);
    CHECK(m.physicalDown == beforeOverflow.physicalDown);
    CHECK(m.queueOverflowResets == beforeOverflow.queueOverflowResets + 1u);
    CHECK(m.resetsEmitted == beforeOverflow.resetsEmitted + 1u);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    CoreDrain(core, consumer);

    // A fully valid batch is counted in full.
    batch[1].header.sessionEpoch = 0u;
    CHECK(core.SubmitBatch(batch, 2u) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == beforeOverflow.physicalDown + 2u);
    CHECK(m.heldControlCount == 2u && m.heldOwnerDeviceCount == 1u);
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
}

// The §11 ledgers must close on the lossy paths too, otherwise the counters only
// describe the happy path. Covers: OpenConsumer's control-channel stamping,
// release-less held discards, undelivered-delivery discards, and the capture
// reason bucket that ValidatePayload deliberately does not constrain.
void TestObservabilityLedgersAndDiscards() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle first = 0;
    CHECK(core.OpenConsumer(&first) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, first).empty());

    // Opening a consumer inside a live session stamps a CONSUMER_BASELINE reset
    // into that consumer's private channel. It consumes a sequence and will be
    // delivered, so it has to be counted on the write side as well -- otherwise
    // queueReads outgrows queueDeliveries forever.
    const amcl::input::CoreObservabilityV1 beforeOpen = CoreObs(core);
    AmclInputConsumerHandle late = 0;
    CHECK(core.OpenConsumer(&late) == AMCL_INPUT_OK);
    amcl::input::CoreObservabilityV1 m = CoreObs(core);
    CHECK(m.lastSequence > beforeOpen.lastSequence);
    CHECK(m.accepted == beforeOpen.accepted + 1u);
    CHECK(m.queueWrites == beforeOpen.queueWrites + 1u);
    CHECK(m.queueDeliveries == beforeOpen.queueDeliveries + 1u);
    CHECK(m.resetsEmitted == beforeOpen.resetsEmitted + 1u);
    CHECK(m.queuePending == beforeOpen.queuePending + 1u);
    const auto baseline = CoreDrain(core, late);
    CHECK(baseline.size() == 1u);
    CHECK(baseline[0].payload.reset.reason ==
          AMCL_INPUT_RESET_CONSUMER_BASELINE);
    m = CoreObs(core);
    CHECK(m.queueReads == beforeOpen.queueReads + 1u);
    CHECK(m.queueDeliveries >= m.queueReads);
    CHECK(m.queueDeliveries ==
          m.queueReads + m.queueDiscarded + m.queuePending);

    // Closing a consumer with events still owed to it discards those deliveries.
    const AmclInputEvent downClose = Key(1101u, 70u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&downClose) == AMCL_INPUT_OK);
    const amcl::input::CoreObservabilityV1 beforeClose = CoreObs(core);
    CHECK(beforeClose.queuePending >= 2u);  // owed to both consumers
    CHECK(core.CloseConsumer(late) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.queueDiscarded == beforeClose.queueDiscarded + 1u);
    CHECK(m.queueDeliveries ==
          m.queueReads + m.queueDiscarded + m.queuePending);
    CoreDrain(core, first);

    // Overflow with held controls: no sequence budget remains for per-control
    // releases, so the whole held set is dropped without UP edges. §11 forbids
    // that being silent, and the down/up ledger only closes with the new counter.
    const AmclInputEvent downA = Key(1102u, 71u, AMCL_INPUT_ACTION_DOWN);
    const AmclInputEvent downB = Key(1102u, 72u, AMCL_INPUT_ACTION_DOWN);
    const AmclInputEvent downC = Key(1103u, 71u, AMCL_INPUT_ACTION_DOWN);
    CHECK(core.SubmitEvent(&downA) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&downB) == AMCL_INPUT_OK);
    CHECK(core.SubmitEvent(&downC) == AMCL_INPUT_OK);
    m = CoreObs(core);
    // `downClose` above is still held, so read the real count instead of assuming
    // three: the assertion below must be about what gets discarded, not about how
    // many downs this block happened to submit.
    const uint64_t heldBeforeOverflow = m.heldControlCount;
    CHECK(heldBeforeOverflow >= 3u);
    CHECK(m.heldOwnerDeviceCount >= 2u);
    CHECK(m.heldDroppedWithoutRelease == 0u);
    // Fill the queue so the focus-lost reset cannot fit held.size()+2 records.
    for (int i = 0; i < 5; ++i) {
        AmclInputEvent move = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE);
        move.payload.pointerRelative.rawDx = static_cast<double>(i + 1);
        CHECK(core.SubmitEvent(&move) == AMCL_INPUT_OK);
    }
    const amcl::input::CoreObservabilityV1 beforeOverflow = CoreObs(core);
    const int32_t blurStatus = core.PublishFocus(0u);
    CHECK(blurStatus == AMCL_INPUT_OK ||
          blurStatus == AMCL_INPUT_OVERFLOW_RESET);
    m = CoreObs(core);
    CHECK(m.heldDroppedWithoutRelease == heldBeforeOverflow);
    CHECK(m.heldControlCount == 0u && m.heldOwnerDeviceCount == 0u);
    // No synthetic UP was emitted for those three, so plain down==up is false
    // here. This is the assertion that would have hidden the loss.
    CHECK(m.physicalUp != m.physicalDown);
    CHECK(m.physicalDown == m.physicalUp + m.heldDroppedWithoutRelease);
    // The discarded queue records must be accounted for, not merely gone.
    CHECK(m.queueDiscarded > beforeOverflow.queueDiscarded);
    CoreDrain(core, first);
    m = CoreObs(core);
    CHECK(m.queueDeliveries ==
          m.queueReads + m.queueDiscarded + m.queuePending);

    CHECK(core.CloseConsumer(first) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
    m = CoreObs(core);
    CHECK(m.physicalDown == m.physicalUp + m.heldDroppedWithoutRelease);
    CHECK(m.queueDeliveries ==
          m.queueReads + m.queueDiscarded + m.queuePending);
}

// ValidatePayload constrains capture `requested`/`active` but deliberately not
// `reason`, so a producer built against a newer reason list still reaches core.
// That branch must bucket into the unknown slot instead of aliasing a known one.
void TestObservabilityUnknownCaptureReason() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());

    AmclInputEvent granted = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    granted.payload.capture.requested = 1u;
    granted.payload.capture.active = 1u;
    granted.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(core.SubmitEvent(&granted) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);

    AmclInputEvent lostUnknown = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    lostUnknown.payload.capture.requested = 0u;
    lostUnknown.payload.capture.active = 0u;
    lostUnknown.payload.capture.reason = 200u;  // beyond the defined list
    CHECK(core.SubmitEvent(&lostUnknown) == AMCL_INPUT_OK);
    const amcl::input::CoreObservabilityV1 m = CoreObs(core);
    CHECK(m.captureLost == 1u);
    CHECK(m.captureLostUnknownReason == 1u);
    // It must not have been folded into any defined bucket.
    for (size_t i = 0; i < AMCL_INPUT_CAPTURE_REASON_COUNT; ++i) {
        CHECK(m.captureLostByReason[i] == 0u);
    }
    CoreDrain(core, consumer);
    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
}

void TestSurfaceContextValidationDedupeAndLateBaseline() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle first = 0;
    CHECK(core.OpenConsumer(&first) == AMCL_INPUT_OK);
    uint64_t epoch = 0;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, first).empty());

    AmclInputSurfacePayload surface{};
    surface.widthPx = 1200u;
    surface.heightPx = 800u;
    surface.active = 1u;
    surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    CHECK(core.PublishSurface(&surface) == AMCL_INPUT_OK);
    const uint64_t surfaceEpoch = CoreSnapshot(core).surfaceEpoch;
    CHECK(CoreDrain(core, first).size() == 2u);

    AmclInputEvent context = Event(
        AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED, epoch);
    context.payload.surfaceContext.windowId = 21;
    context.payload.surfaceContext.displayId = 4;
    context.payload.surfaceContext.leftPx = -80;
    context.payload.surfaceContext.topPx = 30;
    context.payload.surfaceContext.widthPx = 1200u;
    context.payload.surfaceContext.heightPx = 800u;
    context.payload.surfaceContext.density = 2.0f;
    context.payload.surfaceContext.refreshRateHz = 144.0f;
    context.payload.surfaceContext.transform = 1u;
    context.payload.surfaceContext.validFields =
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    context.payload.surfaceContext.generation = 10u;
    CHECK(core.SubmitEvent(&context) == AMCL_INPUT_OK);
    auto delivered = CoreDrain(core, first);
    CHECK(delivered.size() == 1u);
    CHECK(delivered[0].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    CHECK(delivered[0].header.surfaceEpoch == surfaceEpoch);

    // Exact retry is idempotent. Same generation with different semantics and
    // an older generation are stale rather than silently rewriting the cache.
    CHECK(core.SubmitEvent(&context) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, first).empty());
    AmclInputEvent conflicting = context;
    conflicting.payload.surfaceContext.leftPx = -79;
    CHECK(core.SubmitEvent(&conflicting) == AMCL_INPUT_ERROR_STALE);
    AmclInputEvent older = context;
    older.payload.surfaceContext.generation = 9u;
    CHECK(core.SubmitEvent(&older) == AMCL_INPUT_ERROR_STALE);

    // A position/refresh-only context generation does not itself advance the
    // native surface epoch.
    AmclInputEvent moved = context;
    moved.payload.surfaceContext.leftPx = 40;
    moved.payload.surfaceContext.refreshRateHz = 120.0f;
    moved.payload.surfaceContext.generation = 11u;
    CHECK(core.SubmitEvent(&moved) == AMCL_INPUT_OK);
    CHECK(CoreSnapshot(core).surfaceEpoch == surfaceEpoch);
    CoreDrain(core, first);

    AmclInputEvent malformed = moved;
    malformed.payload.surfaceContext.generation = 12u;
    malformed.payload.surfaceContext.transform = 4u;
    CHECK(core.SubmitEvent(&malformed) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    CHECK(core.PublishDeviceChange(
              77u, AMCL_INPUT_DEVICE_ADDED,
              AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE) == AMCL_INPUT_OK);
    CoreDrain(core, first);
    AmclInputConsumerHandle late = 0;
    CHECK(core.OpenConsumer(&late) == AMCL_INPUT_OK);
    const auto baseline = CoreDrain(core, late);
    CHECK(baseline.size() == 4u);
    CHECK(baseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(baseline[1].header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(baseline[2].header.eventType ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    CHECK(baseline[2].payload.surfaceContext.generation == 11u);
    CHECK(baseline[3].header.eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED);
    CHECK(baseline[3].header.deviceId == 77u);

    CHECK(core.CloseConsumer(late) == AMCL_INPUT_OK);
    CHECK(core.CloseConsumer(first) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
}

void TestTypedTextSessionOwnershipAndValidation() {
    amcl::input::InputStateCore core;
    AmclInputConsumerHandle consumer = 0u;
    CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
    uint64_t epoch = 0u;
    CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);

    constexpr uint64_t firstId = 11u;
    constexpr uint64_t secondId = 22u;
    AmclInputEvent start = TextSession(
        AMCL_INPUT_TEXT_SESSION_STARTED, firstId, epoch);
    CHECK(core.SubmitEvent(&start) == AMCL_INPUT_OK);
    auto events = CoreDrain(core, consumer);
    CHECK(events.size() == 1u);
    CHECK(events[0].header.eventType ==
          AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    CHECK(events[0].payload.textSession.textSessionId == firstId);

    // Same-token begin is idempotent; a competing owner cannot replace it.
    CHECK(core.SubmitEvent(&start) == AMCL_INPUT_OK);
    CHECK(CoreDrain(core, consumer).empty());
    AmclInputEvent competing = TextSession(
        AMCL_INPUT_TEXT_SESSION_STARTED, secondId, epoch);
    CHECK(core.SubmitEvent(&competing) == AMCL_INPUT_ERROR_SESSION);

    // Chinese + emoji + an AltGr-produced printable result are one owned
    // packet, independent from the physical modifier edges that produced '@'.
    const uint8_t committed[] = {
        0xe4u, 0xb8u, 0xadu, 0xf0u, 0x9fu, 0x98u, 0x80u, 0x40u};
    AmclInputEvent commit = Event(AMCL_INPUT_EVENT_TEXT_COMMIT, epoch);
    commit.payload.textCommit.textSessionId = firstId;
    CHECK(core.SubmitTextPacket(
              &commit, committed,
              static_cast<uint32_t>(sizeof(committed))) == AMCL_INPUT_OK);
    AmclInputEvent delivered{};
    CHECK(core.NextEvent(consumer, &delivered) == AMCL_INPUT_OK);
    CHECK(delivered.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
    CHECK(delivered.payload.textCommit.textSessionId == firstId);
    std::vector<uint8_t> copied(sizeof(committed));
    uint32_t copiedBytes = 0u;
    CHECK(core.ReadPacketBlob(
              consumer, &delivered.payload.textCommit.utf8Blob,
              copied.data(), static_cast<uint32_t>(copied.size()),
              &copiedBytes) == AMCL_INPUT_OK);
    CHECK(copiedBytes == sizeof(committed));
    CHECK(std::equal(copied.begin(), copied.end(), committed));
    CHECK(core.ReleasePacket(
              consumer,
              delivered.payload.textCommit.utf8Blob.packetId) ==
          AMCL_INPUT_OK);
    CHECK(CoreSnapshot(core).blobBytes == 0u);

    // U+D800 encoded in UTF-8 is never a Unicode scalar.
    const uint8_t surrogate[] = {0xedu, 0xa0u, 0x80u};
    AmclInputEvent editing = Event(AMCL_INPUT_EVENT_TEXT_EDITING, epoch);
    editing.payload.textEditing.textSessionId = firstId;
    CHECK(core.SubmitTextPacket(
              &editing, surrogate,
              static_cast<uint32_t>(sizeof(surrogate))) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    // Editing selection is Unicode-scalar indexed: one emoji has length one.
    const uint8_t emoji[] = {0xf0u, 0x9fu, 0x98u, 0x80u};
    editing.payload.textEditing.selectionLength = 1u;
    CHECK(core.SubmitTextPacket(
              &editing, emoji, static_cast<uint32_t>(sizeof(emoji))) ==
          AMCL_INPUT_OK);
    CHECK(core.NextEvent(consumer, &delivered) == AMCL_INPUT_OK);
    CHECK(core.ReleasePacket(
              consumer,
              delivered.payload.textEditing.utf8Blob.packetId) ==
          AMCL_INPUT_OK);
    editing.payload.textEditing.selectionStart = 1u;
    editing.payload.textEditing.selectionLength = 1u;
    CHECK(core.SubmitTextPacket(
              &editing, emoji, static_cast<uint32_t>(sizeof(emoji))) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    const uint8_t oneCandidate[] = {
        1u, 0u, 0u, 0u, 1u, 0u, 0u, 0u, static_cast<uint8_t>('x')};
    AmclInputEvent candidates = Event(
        AMCL_INPUT_EVENT_TEXT_CANDIDATES, epoch);
    candidates.payload.textCandidates.textSessionId = firstId;
    candidates.payload.textCandidates.selected = 1u;
    candidates.payload.textCandidates.pageSize = 1u;
    candidates.payload.textCandidates.itemCount = 1u;
    CHECK(core.SubmitTextPacket(
              &candidates, oneCandidate,
              static_cast<uint32_t>(sizeof(oneCandidate))) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    candidates.payload.textCandidates.selected = 0u;
    candidates.payload.textCandidates.itemCount = 2u;
    CHECK(core.SubmitTextPacket(
              &candidates, oneCandidate,
              static_cast<uint32_t>(sizeof(oneCandidate))) ==
          AMCL_INPUT_ERROR_INVALID_ARGUMENT);

    AmclInputConsumerHandle late = 0u;
    CHECK(core.OpenConsumer(&late) == AMCL_INPUT_OK);
    const auto lateBaseline = CoreDrain(core, late);
    CHECK(lateBaseline.size() == 2u);
    CHECK(lateBaseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(lateBaseline[1].header.eventType ==
          AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    CHECK(lateBaseline[1].payload.textSession.textSessionId == firstId);
    CHECK(core.CloseConsumer(late) == AMCL_INPUT_OK);

    AmclInputEvent wrongEnd = TextSession(
        AMCL_INPUT_TEXT_SESSION_ENDED, secondId, epoch);
    CHECK(core.SubmitEvent(&wrongEnd) == AMCL_INPUT_ERROR_STALE);
    AmclInputEvent end = TextSession(
        AMCL_INPUT_TEXT_SESSION_ENDED, firstId, epoch);
    CHECK(core.SubmitEvent(&end) == AMCL_INPUT_OK);
    events = CoreDrain(core, consumer);
    CHECK(!events.empty());
    CHECK(events.back().payload.textSession.change ==
          AMCL_INPUT_TEXT_SESSION_ENDED);
    CHECK(core.SubmitTextPacket(
              &commit, committed,
              static_cast<uint32_t>(sizeof(committed))) ==
          AMCL_INPUT_ERROR_STALE);

    // If END is rejected, the owner remains until an explicit ABORT fence.
    start = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED, secondId, epoch);
    CHECK(core.SubmitEvent(&start) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    wrongEnd = TextSession(
        AMCL_INPUT_TEXT_SESSION_ENDED, firstId, epoch);
    CHECK(core.SubmitEvent(&wrongEnd) == AMCL_INPUT_ERROR_STALE);
    AmclInputEvent abort = TextSession(
        AMCL_INPUT_TEXT_SESSION_ABORTED, secondId, epoch);
    CHECK(core.SubmitEvent(&abort) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    AmclInputEvent lateSelection = Event(
        AMCL_INPUT_EVENT_TEXT_SELECTION, epoch);
    lateSelection.payload.textSelection.textSessionId = secondId;
    CHECK(core.SubmitEvent(&lateSelection) == AMCL_INPUT_ERROR_STALE);

    start = TextSession(AMCL_INPUT_TEXT_SESSION_STARTED, firstId, epoch);
    CHECK(core.SubmitEvent(&start) == AMCL_INPUT_OK);
    CoreDrain(core, consumer);
    CHECK(core.PublishFocus(0u) == AMCL_INPUT_OK);
    CHECK(core.SubmitTextPacket(
              &commit, committed,
              static_cast<uint32_t>(sizeof(committed))) ==
          AMCL_INPUT_ERROR_STALE);
    CoreDrain(core, consumer);

    CHECK(core.CloseConsumer(consumer) == AMCL_INPUT_OK);
    CHECK(core.EndSession(epoch) == AMCL_INPUT_OK);
}

int main() {
    gApi = amclInputGetHostApiV1();
    TestAbiAndFirstBegin();
    TestTwoDevicesAndTime();
    TestPointerDeviceClassTimestampAndRemovalOrdering();
    TestRepeat();
    TestOwnerlessAndDuplicateDiagnostics();
    TestEpochFocusAndUnknown();
    TestLifecycleOrderingAndIdempotence();
    TestLifecycleOverflowTransitions();
    TestSessionScopeAndActiveRollover();
    TestSurfaceValidityAndInactiveBaseline();
    TestNonFinitePayloadsAndAtomicRollback();
    TestTypedEventsAndOwnedBlobs();
    TestBlobReclamationAndExhaustion();
    TestBatchRollbackAndOverflow();
    TestAbsolutePositionBoundBatchContract();
    TestDiagnosticBatchRollbackAndOverflow();
    TestLateConsumerBaselineAndGeneration();
    TestLateConsumerReplaysCurrentSurfaceBeforeReady();
    TestCaptureAndCloseReclaim();
    TestCaptureResultFocusAndSurfaceLifecycle();
    TestSequenceExhaustionAtomicity();
    TestTextAndBaselineExhaustionAtomicity();
    TestBatchAndSessionCounterBoundaries();
    TestTypedBackendReadyBarrier();
    TestMultipleBackendReadySlots();
    TestTypedBackendOwnerRolloverAndBlobDrain();
    TestTypedBackendSequenceExhaustionAndAbandon();
    TestTypedBackendSubmitRetireLinearization();
    TestObservabilityMetrics();
    TestObservabilityWithoutConsumer();
    TestObservabilityBatchRollback();
    TestObservabilityLedgersAndDiscards();
    TestObservabilityUnknownCaptureReason();
    TestSurfaceContextValidationDedupeAndLateBaseline();
    TestTypedTextSessionOwnershipAndValidation();
    RunInputReconciliationTests();
    std::cout << "amcl_input_host_tests: PASS\n";
    return 0;
}

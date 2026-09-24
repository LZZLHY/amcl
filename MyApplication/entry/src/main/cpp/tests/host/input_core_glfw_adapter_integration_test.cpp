#include "adapters/glfw_input_adapter.h"
#include "input_state_core.h"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
using namespace amcl::input;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclInputEvent Event(uint32_t type, uint64_t epoch) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = type;
    event.header.sessionEpoch = epoch;
    return event;
}

AmclInputEvent Key(uint64_t epoch, uint64_t deviceId, uint32_t raw,
                   uint32_t action) {
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, epoch);
    event.header.deviceId = deviceId;
    event.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
    event.payload.physicalKey.physicalKey = raw;
    event.payload.physicalKey.hardwareScanCode = raw + 100u;
    event.payload.physicalKey.hidUsage = raw + 200u;
    event.payload.physicalKey.action = action;
    event.payload.physicalKey.modifiersSnapshot = 4u;
    event.payload.physicalKey.lockState = 2u;
    return event;
}

AmclInputEvent Button(uint64_t epoch, uint64_t deviceId, uint32_t raw,
                      uint32_t action) {
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_BUTTON, epoch);
    event.header.deviceId = deviceId;
    event.header.source = AMCL_INPUT_SOURCE_MOUSE;
    event.payload.pointerButton.nativeButton = raw;
    event.payload.pointerButton.action = action;
    event.payload.pointerButton.modifiersSnapshot = 8u;
    return event;
}

struct MapperState {
    uint32_t keyCalls = 0u;
    uint32_t buttonCalls = 0u;
};

bool MapKey(void* context, uint64_t, uint32_t raw, uint32_t scanCode,
            uint32_t, GlfwMappedKey* output) {
    auto& state = *static_cast<MapperState*>(context);
    ++state.keyCalls;
    output->key = static_cast<int32_t>(raw + 1000u);
    output->scanCode = static_cast<int32_t>(scanCode);
    return true;
}

bool MapButton(void* context, uint64_t, uint32_t raw, int32_t* output) {
    auto& state = *static_cast<MapperState*>(context);
    ++state.buttonCalls;
    *output = static_cast<int32_t>(raw - 2u);
    return true;
}

struct Recorder {
    const AmclInputHostApiV1* api = nullptr;
    GlfwInputAdapter* adapter = nullptr;
    std::vector<GlfwKeySinkEvent> keys;
    std::vector<GlfwButtonSinkEvent> buttons;
    std::vector<GlfwDiagnosticDropSinkEvent> drops;
    uint32_t unsupportedMappings = 0u;
    bool callbackStateConsistent = true;
    bool diagnosticReentrySafe = true;

    static void KeySink(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.callbackStateConsistent &= self.adapter->IsKeyPressed(event.key) ==
            (event.action != GlfwInputAction::kRelease);
        self.keys.push_back(event);
    }

    static void ButtonSink(void* context, const GlfwButtonSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.callbackStateConsistent &=
            self.adapter->IsButtonPressed(event.button) ==
            (event.action != GlfwInputAction::kRelease);
        self.buttons.push_back(event);
    }

    static void UnsupportedMappingSink(
            void* context, const GlfwUnsupportedMappingSinkEvent&) {
        ++static_cast<Recorder*>(context)->unsupportedMappings;
    }

    static void DiagnosticDropSink(
            void* context, const GlfwDiagnosticDropSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);

        // Pump still owns its operation mutex, but both core::NextEvent and the
        // adapter state mutex must be gone before this synchronous callback.
        // Querying both layers here is the integration proof for that lock
        // boundary; the callback deliberately does not reenter Pump/Open/Close.
        AmclInputSnapshotV1 snapshot{};
        snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
        snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
        self.diagnosticReentrySafe &=
            self.api->getSnapshot(&snapshot) == AMCL_INPUT_OK;
        self.diagnosticReentrySafe &= snapshot.heldControlCount == 0u;
        self.diagnosticReentrySafe &= self.adapter->IsReady();
        self.diagnosticReentrySafe &= self.adapter->SessionEpoch() != 0u;
        self.diagnosticReentrySafe &=
            !self.adapter->IsKeyPressed(static_cast<int32_t>(42u + 1000u));
        if (event.reason ==
                AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN) {
            self.diagnosticReentrySafe &= self.adapter->IsButtonPressed(2);
        }
        self.drops.push_back(event);
    }

    GlfwInputSink Sink() {
        GlfwInputSink sink{};
        sink.context = this;
        sink.key = KeySink;
        sink.button = ButtonSink;
        sink.unsupportedMapping = UnsupportedMappingSink;
        sink.diagnosticDrop = DiagnosticDropSink;
        return sink;
    }
};

void CheckDrop(const GlfwDiagnosticDropSinkEvent& event, uint32_t reason,
               uint32_t originalEventType, uint64_t deviceId,
               uint32_t rawControl, uint32_t action,
               uint32_t scanCode, uint32_t hidUsage) {
    CHECK(event.reason == reason);
    CHECK(event.originalEventType == originalEventType);
    CHECK(event.deviceId == deviceId);
    CHECK(event.rawControl == rawControl);
    CHECK(event.action == action);
    CHECK(event.hardwareScanCode == scanCode);
    CHECK(event.hidUsage == hidUsage);
    CHECK(event.sequence != 0u);
}

void TestShippingCoreToAdapterDiagnostics() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
#else
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
#endif
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);
    uint64_t epoch = 0u;
    CHECK(api->beginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(epoch != 0u);

    MapperState mapperState;
    GlfwInputAdapter adapter;
    Recorder recorder;
    recorder.api = api;
    recorder.adapter = &adapter;
    const GlfwInputMapper mapper{&mapperState, MapKey, MapButton};
    CHECK(adapter.Open(api, mapper, recorder.Sink()) ==
          GlfwAdapterStatus::kOk);

    const AmclInputEvent keyRepeat =
        Key(epoch, 7u, 42u, AMCL_INPUT_ACTION_REPEAT);
    const AmclInputEvent keyUp =
        Key(epoch, 7u, 42u, AMCL_INPUT_ACTION_UP);
    const AmclInputEvent buttonUp =
        Button(epoch, 8u, 4u, AMCL_INPUT_ACTION_UP);
    const AmclInputEvent buttonDown =
        Button(epoch, 8u, 4u, AMCL_INPUT_ACTION_DOWN);
    CHECK(api->submitEvent(&keyRepeat) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&keyUp) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&buttonUp) == AMCL_INPUT_OK);

    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    CHECK(snapshot.heldControlCount == 0u);

    const GlfwPumpResult ownerless = adapter.Pump();
    CHECK(ownerless.status == GlfwAdapterStatus::kOk);
    CHECK(ownerless.eventsDrained == 3u);
    CHECK(recorder.keys.empty());
    CHECK(recorder.buttons.empty());
    CHECK(recorder.drops.size() == 3u);
    CheckDrop(recorder.drops[0],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, 7u, 42u,
              AMCL_INPUT_ACTION_REPEAT, 142u, 242u);
    CheckDrop(recorder.drops[1],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
              AMCL_INPUT_EVENT_PHYSICAL_KEY, 7u, 42u,
              AMCL_INPUT_ACTION_UP, 142u, 242u);
    CheckDrop(recorder.drops[2],
              AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP,
              AMCL_INPUT_EVENT_POINTER_BUTTON, 8u, 4u,
              AMCL_INPUT_ACTION_UP, 0u, 0u);
    CHECK(mapperState.keyCalls == 0u);
    CHECK(mapperState.buttonCalls == 0u);

    CHECK(api->submitEvent(&buttonDown) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&buttonDown) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&buttonUp) == AMCL_INPUT_OK);
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    CHECK(snapshot.heldControlCount == 0u);
    const GlfwPumpResult duplicate = adapter.Pump();
    CHECK(duplicate.status == GlfwAdapterStatus::kOk);
    CHECK(duplicate.eventsDrained == 3u);
    CHECK(recorder.buttons.size() == 2u);
    CHECK(recorder.buttons[0].action == GlfwInputAction::kPress);
    CHECK(recorder.buttons[1].action == GlfwInputAction::kRelease);
    CHECK(recorder.drops.size() == 4u);
    CheckDrop(recorder.drops[3],
              AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN,
              AMCL_INPUT_EVENT_POINTER_BUTTON, 8u, 4u,
              AMCL_INPUT_ACTION_DOWN, 0u, 0u);
    CHECK(mapperState.keyCalls == 0u);
    CHECK(mapperState.buttonCalls == 1u);
    CHECK(recorder.unsupportedMappings == 0u);
    CHECK(recorder.callbackStateConsistent);
    CHECK(recorder.diagnosticReentrySafe);
    CHECK(!adapter.IsKeyPressed(1042));
    CHECK(!adapter.IsButtonPressed(2));

    // The diagnostic route must not disturb ordinary held/repeat semantics.
    const AmclInputEvent keyDown =
        Key(epoch, 7u, 42u, AMCL_INPUT_ACTION_DOWN);
    CHECK(api->submitEvent(&keyDown) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&keyDown) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&keyRepeat) == AMCL_INPUT_OK);
    CHECK(api->submitEvent(&keyUp) == AMCL_INPUT_OK);
    const GlfwPumpResult ordinary = adapter.Pump();
    CHECK(ordinary.status == GlfwAdapterStatus::kOk);
    CHECK(ordinary.eventsDrained == 4u);
    CHECK(recorder.keys.size() == 4u);
    CHECK(recorder.keys[0].action == GlfwInputAction::kPress);
    CHECK(recorder.keys[1].action == GlfwInputAction::kRepeat);
    CHECK(recorder.keys[2].action == GlfwInputAction::kRepeat);
    CHECK(recorder.keys[3].action == GlfwInputAction::kRelease);
    CHECK(mapperState.keyCalls == 1u);
    CHECK(recorder.drops.size() == 4u);
    CHECK(!adapter.IsKeyPressed(1042));
    CHECK(recorder.callbackStateConsistent);

    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(api->endSession(epoch) == AMCL_INPUT_OK);
}

}  // namespace

int main() {
    TestShippingCoreToAdapterDiagnostics();
    std::cout << "input_core_glfw_adapter_integration_test: PASS\n";
    return 0;
}

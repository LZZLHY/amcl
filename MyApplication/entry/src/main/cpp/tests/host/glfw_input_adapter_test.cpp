#include "../../input/adapters/glfw_input_adapter.h"
#include "../../input/adapters/glfw_input_mode.h"

#include <algorithm>
#include <cstdlib>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <future>
#include <iostream>
#include <limits>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

struct FakeHost;
FakeHost* gHost = nullptr;

struct FakeHost {
    AmclInputHostApiV1 api{};
    std::deque<AmclInputEvent> events;
    std::map<uint64_t, std::vector<uint8_t>> blobs;
    uint64_t sessionEpoch = 41u;
    uint64_t nextSequence = 10u;
    int32_t nextStatus = AMCL_INPUT_EMPTY;
    int32_t closeStatus = AMCL_INPUT_OK;
    uint32_t baselineReason = AMCL_INPUT_RESET_CONSUMER_BASELINE;
    uint32_t snapshotAbiVersion = AMCL_INPUT_HOST_API_VERSION;
    int32_t readyStatus = AMCL_INPUT_OK;
    int32_t abandonStatus = AMCL_INPUT_OK;
    int32_t releaseStatus = AMCL_INPUT_OK;
    int forcedDrainResponses = 0;
    int closeCalls = 0;
    int releaseCalls = 0;
    int readyCalls = 0;
    int retireCalls = 0;
    int abandonCalls = 0;
    uint64_t baselineSequence = 0u;
    bool consumerOpen = false;
    bool backendReady = false;
    bool backendRetiring = false;
    bool enqueueRetireReset = true;
    bool replaySurface = false;
    bool replaySurfaceContext = false;
    uint32_t expectedBackend = AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    uint32_t snapshotFocused = 1u;
    uint32_t snapshotCaptureRequested = 0u;
    uint32_t snapshotCaptureActive = 0u;
    uint32_t snapshotCaptureReason = AMCL_INPUT_CAPTURE_REASON_NONE;
    uint64_t replaySurfaceEpoch = 3u;
    uint64_t replayPublicationGeneration = 20u;
    uint32_t replaySurfaceWidth = 800u;
    uint32_t replaySurfaceHeight = 600u;
    bool pauseNextAfterPop = false;
    bool nextEventPopped = false;
    bool allowNextReturn = false;
    std::mutex nextBarrierMutex;
    std::condition_variable nextBarrierCondition;
    bool pauseRelease = false;
    bool releaseEntered = false;
    bool allowRelease = false;
    std::mutex releaseBarrierMutex;
    std::condition_variable releaseBarrierCondition;

    FakeHost() {
        gHost = this;
        api.magic = AMCL_INPUT_HOST_API_MAGIC;
        api.abiVersion = AMCL_INPUT_HOST_API_VERSION;
        api.structSize = sizeof(api);
        api.capabilityBits = AMCL_INPUT_CAP_TYPED_EVENTS |
            AMCL_INPUT_CAP_MULTI_CONSUMER |
            AMCL_INPUT_CAP_OVERFLOW_RESET |
            AMCL_INPUT_CAP_OWNED_TEXT_PACKETS |
            AMCL_INPUT_CAP_SESSION_EPOCHS |
            AMCL_INPUT_CAP_HOST_GENERATION |
            AMCL_INPUT_CAP_EXPECTED_EPOCHS |
            AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS |
            AMCL_INPUT_CAP_CONSUMER_BASELINE |
            AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY |
            AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE |
            AMCL_INPUT_CAP_DIAGNOSTIC_DROP |
            AMCL_INPUT_CAP_BACKEND_CONSUMER_READY |
            AMCL_INPUT_CAP_DEVICE_CLASS |
            AMCL_INPUT_CAP_SURFACE_CONTEXT |
            AMCL_INPUT_CAP_TEXT_INPUT_SESSION;
        api.generation = AMCL_INPUT_HOST_API_GENERATION;
        api.beginSession = BeginSession;
        api.endSession = EndSession;
        api.submitEvent = SubmitEvent;
        api.submitBatch = SubmitBatch;
        api.submitTextPacket = SubmitTextPacket;
        api.publishSurface = PublishSurface;
        api.publishFocus = PublishFocus;
        api.publishDeviceChange = PublishDevice;
        api.requestReset = RequestReset;
        api.openConsumer = OpenConsumer;
        api.nextEvent = NextEvent;
        api.readPacketBlob = ReadBlob;
        api.releasePacket = ReleasePacket;
        api.closeConsumer = CloseConsumer;
        api.getSnapshot = GetSnapshot;
    }
    static int32_t BeginSession(uint64_t* epoch) {
        if (epoch) *epoch = gHost->sessionEpoch;
        return AMCL_INPUT_OK;
    }
    static int32_t EndSession(uint64_t) { return AMCL_INPUT_OK; }
    static int32_t SubmitEvent(const AmclInputEvent* event) {
        if (!event || event->header.eventType !=
                          AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE) {
            return AMCL_INPUT_OK;
        }
        const auto& control = event->payload.backendConsumerState;
        if (control.backend != gHost->expectedBackend ||
            control.consumer != 7u ||
            control.generation != AMCL_INPUT_HOST_API_GENERATION) {
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
        if (control.state == AMCL_INPUT_BACKEND_CONSUMER_READY) {
            ++gHost->readyCalls;
            if (gHost->readyStatus != AMCL_INPUT_OK) {
                return gHost->readyStatus;
            }
            if (!gHost->consumerOpen ||
                control.baselineSequence != gHost->baselineSequence ||
                event->header.sessionEpoch != gHost->sessionEpoch) {
                return AMCL_INPUT_ERROR_STALE;
            }
            gHost->backendReady = true;
            return AMCL_INPUT_OK;
        }
        if (control.state == AMCL_INPUT_BACKEND_CONSUMER_RETIRE) {
            ++gHost->retireCalls;
            if (!gHost->backendReady && !gHost->backendRetiring) {
                return AMCL_INPUT_ERROR_NOT_FOUND;
            }
            gHost->backendReady = false;
            gHost->backendRetiring = true;
            if (gHost->enqueueRetireReset) {
                AmclInputEvent reset = Event(AMCL_INPUT_EVENT_RESET);
                reset.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
                reset.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
                reset.payload.reset.reason = AMCL_INPUT_RESET_BACKEND_RETIRED;
                reset.payload.reset.closingEpoch = gHost->sessionEpoch;
                gHost->events.push_back(reset);
            }
            return AMCL_INPUT_OK;
        }
        if (control.state == AMCL_INPUT_BACKEND_CONSUMER_ABANDON) {
            ++gHost->abandonCalls;
            if (gHost->abandonStatus != AMCL_INPUT_OK) {
                return gHost->abandonStatus;
            }
            gHost->backendReady = false;
            gHost->backendRetiring = false;
            gHost->consumerOpen = false;
            gHost->events.clear();
            return AMCL_INPUT_OK;
        }
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }
    static int32_t SubmitBatch(const AmclInputEvent*, uint32_t) {
        return AMCL_INPUT_OK;
    }
    static int32_t SubmitTextPacket(const AmclInputEvent*, const uint8_t*,
                                    uint32_t) { return AMCL_INPUT_OK; }
    static int32_t PublishSurface(const AmclInputSurfacePayload*) {
        return AMCL_INPUT_OK;
    }
    static int32_t PublishFocus(uint32_t) { return AMCL_INPUT_OK; }
    static int32_t PublishDevice(uint64_t, uint32_t, uint32_t) {
        return AMCL_INPUT_OK;
    }
    static int32_t RequestReset(uint32_t) { return AMCL_INPUT_OK; }
    static int32_t OpenConsumer(AmclInputConsumerHandle* output) {
        *output = 7u;
        gHost->consumerOpen = true;
        gHost->backendReady = false;
        gHost->backendRetiring = false;
        AmclInputEvent baseline = Event(AMCL_INPUT_EVENT_RESET);
        baseline.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
        baseline.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
        baseline.payload.reset.reason = gHost->baselineReason;
        baseline.payload.reset.closingEpoch = gHost->sessionEpoch;
        gHost->baselineSequence = baseline.header.sequence;
        gHost->events.push_back(baseline);
        if (gHost->replaySurface) {
            AmclInputEvent surface = Event(AMCL_INPUT_EVENT_SURFACE_CHANGED);
            surface.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
            surface.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
            surface.header.surfaceEpoch = gHost->replaySurfaceEpoch;
            surface.payload.surface.active = 1u;
            surface.payload.surface.widthPx = gHost->replaySurfaceWidth;
            surface.payload.surface.heightPx = gHost->replaySurfaceHeight;
            surface.payload.surface.validFields =
                AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
            surface.payload.surface.publicationGeneration =
                gHost->replayPublicationGeneration;
            gHost->events.push_back(surface);
        }
        if (gHost->replaySurfaceContext) {
            AmclInputEvent context = Event(
                AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
            context.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
            context.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
            context.header.surfaceEpoch = gHost->replaySurfaceEpoch;
            context.payload.surfaceContext.windowId = 9;
            context.payload.surfaceContext.displayId = 2;
            context.payload.surfaceContext.leftPx = 10;
            context.payload.surfaceContext.topPx = 20;
            context.payload.surfaceContext.widthPx =
                gHost->replaySurfaceWidth;
            context.payload.surfaceContext.heightPx =
                gHost->replaySurfaceHeight;
            context.payload.surfaceContext.density = 2.0f;
            context.payload.surfaceContext.refreshRateHz = 120.0f;
            context.payload.surfaceContext.transform = 1u;
            context.payload.surfaceContext.validFields =
                AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
            context.payload.surfaceContext.generation = 33u;
            gHost->events.push_back(context);
        }
        return AMCL_INPUT_OK;
    }
    static int32_t NextEvent(AmclInputConsumerHandle, AmclInputEvent* output) {
        if (!gHost->events.empty()) {
            *output = gHost->events.front();
            gHost->events.pop_front();
            if (gHost->pauseNextAfterPop) {
                std::unique_lock<std::mutex> lock(gHost->nextBarrierMutex);
                gHost->nextEventPopped = true;
                gHost->nextBarrierCondition.notify_all();
                gHost->nextBarrierCondition.wait(lock, []() {
                    return gHost->allowNextReturn;
                });
            }
            return AMCL_INPUT_OK;
        }
        const int32_t result = gHost->nextStatus;
        gHost->nextStatus = AMCL_INPUT_EMPTY;
        return result;
    }
    static int32_t ReadBlob(AmclInputConsumerHandle,
                            const AmclInputBlobRef* blob,
                            uint8_t* output, uint32_t capacity,
                            uint32_t* outputCount) {
        if (!blob || !outputCount) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        const auto found = gHost->blobs.find(blob->packetId);
        if (found == gHost->blobs.end() ||
            blob->offset > found->second.size() ||
            blob->length > found->second.size() - blob->offset) {
            return AMCL_INPUT_ERROR_NOT_FOUND;
        }
        *outputCount = blob->length;
        if (capacity < blob->length || (!output && blob->length != 0u)) {
            return AMCL_INPUT_ERROR_BUFFER_TOO_SMALL;
        }
        if (blob->length != 0u) {
            std::copy_n(found->second.data() + blob->offset,
                        blob->length, output);
        }
        return AMCL_INPUT_OK;
    }
    static int32_t ReleasePacket(AmclInputConsumerHandle, uint64_t packetId) {
        ++gHost->releaseCalls;
        if (gHost->pauseRelease) {
            std::unique_lock<std::mutex> lock(gHost->releaseBarrierMutex);
            gHost->releaseEntered = true;
            gHost->releaseBarrierCondition.notify_all();
            gHost->releaseBarrierCondition.wait(lock, []() {
                return gHost->allowRelease;
            });
        }
        const int32_t status = gHost->releaseStatus;
        if (status == AMCL_INPUT_OK) gHost->blobs.erase(packetId);
        return status;
    }
    static int32_t CloseConsumer(AmclInputConsumerHandle) {
        ++gHost->closeCalls;
        if (gHost->backendRetiring && !gHost->events.empty()) {
            return AMCL_INPUT_DRAIN_REQUIRED;
        }
        if (gHost->forcedDrainResponses > 0) {
            --gHost->forcedDrainResponses;
            return AMCL_INPUT_DRAIN_REQUIRED;
        }
        gHost->consumerOpen = false;
        gHost->backendReady = false;
        gHost->backendRetiring = false;
        return gHost->closeStatus;
    }
    static int32_t GetSnapshot(AmclInputSnapshotV1* output) {
        output->abiVersion =
            static_cast<uint16_t>(gHost->snapshotAbiVersion);
        output->structSize = sizeof(*output);
        output->sessionEpoch = gHost->sessionEpoch;
        output->focusEpoch = 2u;
        output->surfaceEpoch = 3u;
        output->focused = gHost->snapshotFocused;
        output->captureRequested = gHost->snapshotCaptureRequested;
        output->captureActive = gHost->snapshotCaptureActive;
        output->captureReason = gHost->snapshotCaptureReason;
        output->sessionActive = 1u;
        return AMCL_INPUT_OK;
    }

    static AmclInputEvent Event(uint32_t type, uint64_t device = 0u) {
        AmclInputEvent event{};
        event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
        event.header.structSize = sizeof(event);
        event.header.eventType = type;
        event.header.sequence = gHost->nextSequence++;
        event.header.deviceId = device;
        event.header.sessionEpoch = gHost->sessionEpoch;
        event.header.focusEpoch = 2u;
        event.header.surfaceEpoch = 3u;
        // 从 sequence 派生一个**可辨认**的时间戳。常数会让"透传"与"恰好也是那个常数"
        // 分不开，而 0 会让整条断言恒真（那正是 §103.1 要挡的形状）。
        event.header.monotonicTimeNs = event.header.sequence * 1000u + 7u;
        return event;
    }

    void Push(AmclInputEvent event) { events.push_back(event); }
};
struct Recorder {
    GlfwInputAdapter* adapter = nullptr;
    std::vector<GlfwKeySinkEvent> keys;
    std::vector<GlfwButtonSinkEvent> buttons;
    std::vector<GlfwAbsoluteSinkEvent> absolutes;
    std::vector<GlfwRelativeSinkEvent> relatives;
    std::vector<GlfwFocusSinkEvent> focuses;
    std::vector<GlfwCaptureSinkEvent> captures;
    std::vector<GlfwSurfaceSinkEvent> surfaces;
    std::vector<GlfwDeviceSinkEvent> devices;
    std::vector<uint32_t> dispatchOrder;
    std::vector<GlfwUnsupportedMappingSinkEvent> unsupportedMappings;
    std::vector<GlfwDiagnosticDropSinkEvent> diagnosticDrops;
    std::vector<GlfwSurfaceContextSinkEvent> surfaceContexts;
    std::vector<GlfwTextSessionSinkEvent> textSessions;
    std::vector<GlfwTextCommitSinkEvent> textCommits;
    std::vector<GlfwTextEditingSinkEvent> textEditing;
    std::vector<GlfwTextCandidatesSinkEvent> textCandidates;
    std::vector<GlfwTextSelectionSinkEvent> textSelections;
    int absolute = 0;
    int relative = 0;
    int wheel = 0;
    int focus = 0;
    int enter = 0;
    int capture = 0;
    int surface = 0;
    int reset = 0;
    bool pollingConsistent = true;
    bool diagnosticReentrySafe = true;

    static void Key(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        const bool expected = event.action != GlfwInputAction::kRelease;
        self.pollingConsistent &=
            self.adapter->IsKeyPressed(event.key) == expected;
        self.keys.push_back(event);
    }
    static void Button(void* context, const GlfwButtonSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        const bool expected = event.action != GlfwInputAction::kRelease;
        self.pollingConsistent &=
            self.adapter->IsButtonPressed(event.button) == expected;
        self.buttons.push_back(event);
        self.dispatchOrder.push_back(AMCL_INPUT_EVENT_POINTER_BUTTON);
    }
    static void Absolute(void* context, const GlfwAbsoluteSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        ++self.absolute;
        self.absolutes.push_back(event);
        self.dispatchOrder.push_back(AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    }
    static void Relative(void* context, const GlfwRelativeSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        ++self.relative;
        self.relatives.push_back(event);
    }
    static void Wheel(void* context, const GlfwWheelSinkEvent&) {
        ++static_cast<Recorder*>(context)->wheel;
    }
    static void Focus(void* context, const GlfwFocusSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        ++self.focus;
        self.focuses.push_back(event);
    }
    static void Enter(void* context, const GlfwEnterSinkEvent&) {
        ++static_cast<Recorder*>(context)->enter;
    }
    static void Capture(void* context, const GlfwCaptureSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        ++self.capture;
        self.captures.push_back(event);
    }
    static void Surface(void* context, const GlfwSurfaceSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        ++self.surface;
        self.surfaces.push_back(event);
        self.dispatchOrder.push_back(AMCL_INPUT_EVENT_SURFACE_CHANGED);
    }
    static void Device(void* context, const GlfwDeviceSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.devices.push_back(event);
        self.dispatchOrder.push_back(AMCL_INPUT_EVENT_DEVICE_CHANGED);
    }
    static void SurfaceContext(
            void* context, const GlfwSurfaceContextSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        self.surfaceContexts.push_back(event);
        self.dispatchOrder.push_back(
            AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    }
    static void Reset(void* context, const GlfwResetSinkEvent&) {
        ++static_cast<Recorder*>(context)->reset;
    }
    static void TextSession(
            void* context, const GlfwTextSessionSinkEvent& event) {
        static_cast<Recorder*>(context)->textSessions.push_back(event);
    }
    static void TextCommit(
            void* context, const GlfwTextCommitSinkEvent& event) {
        static_cast<Recorder*>(context)->textCommits.push_back(event);
    }
    static void TextEditing(
            void* context, const GlfwTextEditingSinkEvent& event) {
        static_cast<Recorder*>(context)->textEditing.push_back(event);
    }
    static void TextCandidates(
            void* context, const GlfwTextCandidatesSinkEvent& event) {
        static_cast<Recorder*>(context)->textCandidates.push_back(event);
    }
    static void TextSelection(
            void* context, const GlfwTextSelectionSinkEvent& event) {
        static_cast<Recorder*>(context)->textSelections.push_back(event);
    }
    static void UnsupportedMapping(
            void* context, const GlfwUnsupportedMappingSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        // These synchronous queries would deadlock if diagnostic dispatch still
        // held the adapter state mutex. Values are checked by the caller after
        // proving the rejected raw controls never entered either polling map.
        self.diagnosticReentrySafe &= self.adapter->IsReady();
        self.diagnosticReentrySafe &= self.adapter->SessionEpoch() != 0u;
        (void)self.adapter->IsKeyPressed(65);
        (void)self.adapter->IsButtonPressed(0);
        self.unsupportedMappings.push_back(event);
    }
    static void DiagnosticDrop(
            void* context, const GlfwDiagnosticDropSinkEvent& event) {
        auto& self = *static_cast<Recorder*>(context);
        // Diagnostic dispatch must share the ordinary lock-outside-callback
        // contract; these synchronous polling queries would otherwise deadlock.
        self.diagnosticReentrySafe &= self.adapter->IsReady();
        self.diagnosticReentrySafe &= self.adapter->SessionEpoch() != 0u;
        (void)self.adapter->IsKeyPressed(65);
        (void)self.adapter->IsButtonPressed(0);
        self.diagnosticDrops.push_back(event);
    }

    GlfwInputSink Sink() {
        GlfwInputSink sink{
            this, Key, Button, Absolute, Relative, Wheel, Focus, Enter,
            Capture, Surface, Reset, UnsupportedMapping, DiagnosticDrop};
        sink.device = Device;
        sink.surfaceContext = SurfaceContext;
        sink.textSession = TextSession;
        sink.textCommit = TextCommit;
        sink.textEditing = TextEditing;
        sink.textCandidates = TextCandidates;
        sink.textSelection = TextSelection;
        return sink;
    }
};

bool MapKey(void*, uint64_t, uint32_t physical, uint32_t, uint32_t,
            GlfwMappedKey* output) {
    output->key = (physical == 10u || physical == 11u)
                      ? 65 : static_cast<int32_t>(physical + 1000u);
    output->scanCode = static_cast<int32_t>(physical + 500u);
    return true;
}

bool MapButton(void*, uint64_t, uint32_t nativeButton, int32_t* output) {
    *output = (nativeButton == 1u || nativeButton == 2u)
                  ? 0 : static_cast<int32_t>(nativeButton);
    return true;
}

GlfwInputMapper Mapper() { return {nullptr, MapKey, MapButton}; }

constexpr uint32_t kUnsupportedRawKey = 9001u;
constexpr uint32_t kUnsupportedRawButton = 9002u;

bool RejectUnsupportedKey(void* context, uint64_t deviceId, uint32_t physical,
                          uint32_t scanCode, uint32_t hidUsage,
                          GlfwMappedKey* output) {
    if (physical == kUnsupportedRawKey) return false;
    return MapKey(context, deviceId, physical, scanCode, hidUsage, output);
}

bool RejectUnsupportedButton(void* context, uint64_t deviceId,
                             uint32_t nativeButton, int32_t* output) {
    if (nativeButton == kUnsupportedRawButton) return false;
    return MapButton(context, deviceId, nativeButton, output);
}

GlfwInputMapper RejectingMapper() {
    return {nullptr, RejectUnsupportedKey, RejectUnsupportedButton};
}

struct Fixture {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;

    explicit Fixture(
            GlfwInputMapper mapper = Mapper(),
            uint32_t backend = AMCL_INPUT_BACKEND_GLFW_PHYSICAL) {
        recorder.adapter = &adapter;
        host.expectedBackend = backend;
        CHECK(adapter.Open(&host.api, mapper, recorder.Sink(), backend) ==
              GlfwAdapterStatus::kOk);
        CHECK(adapter.IsReady());
        CHECK(adapter.SessionEpoch() == host.sessionEpoch);
        CHECK(host.events.empty());
    }
};

AmclInputEvent Key(uint64_t device, uint32_t raw, uint32_t action) {
    AmclInputEvent event = FakeHost::Event(AMCL_INPUT_EVENT_PHYSICAL_KEY,
                                           device);
    event.payload.physicalKey.physicalKey = raw;
    event.payload.physicalKey.hardwareScanCode = raw + 100u;
    event.payload.physicalKey.hidUsage = raw + 200u;
    event.payload.physicalKey.action = action;
    event.payload.physicalKey.modifiersSnapshot = 4u;
    return event;
}

AmclInputEvent Button(
        uint64_t device, uint32_t raw, uint32_t action,
        uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN) {
    AmclInputEvent event = FakeHost::Event(AMCL_INPUT_EVENT_POINTER_BUTTON,
                                           device);
    event.payload.pointerButton.nativeButton = raw;
    event.payload.pointerButton.action = action;
    event.payload.pointerButton.modifiersSnapshot = 8u;
    event.header.deviceClass = deviceClass;
    return event;
}

void TestBaselineAndStrictTable() {
    CHECK(!IsGlfwTypedInputRequested(nullptr));
    CHECK(!IsGlfwTypedInputRequested("legacy"));
    CHECK(IsGlfwTypedInputRequested("typed"));
    CHECK(IsGlfwTypedInputRequested("1"));
    CHECK(!ResolveGlfwInputRouteConfig(nullptr, false).typedPhysical);
    CHECK(ResolveGlfwInputRouteConfig(nullptr, true).typedPhysical);
    CHECK(ResolveGlfwInputRouteConfig("typed", false).typedPhysical);
    CHECK(!ResolveGlfwInputRouteConfig("legacy", true).typedPhysical);

    const GlfwInputMapper ohos = GlfwOhosInputMapper();
    GlfwMappedKey mapped{};
    CHECK(ohos.mapKey(ohos.context, 0u, 2017u, 30u, 0u, &mapped));
    CHECK(mapped.key == 65 && mapped.scanCode == 30);
    CHECK(ohos.mapKey(ohos.context, 0u, 2070u, 0u, 0u, &mapped));
    CHECK(mapped.key == 256 && mapped.scanCode == 2070);
    CHECK(!ohos.mapKey(ohos.context, 0u, 9999u, 0u, 0u, &mapped));
    int32_t button = -1;
    CHECK(ohos.mapButton(ohos.context, 0u, 16u, &button));
    CHECK(button == 4);
    CHECK(!ohos.mapButton(ohos.context, 0u, 3u, &button));

    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    AmclInputHostApiV1 incomplete = host.api;
    incomplete.releasePacket = nullptr;
    CHECK(adapter.Open(&incomplete, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kInvalidConfiguration);
    CHECK(!adapter.IsReady());

    // Same table/event ABI is insufficient: an older core may silently swallow
    // ownerless edges before the adapter can apply its defensive diagnostics.
    AmclInputHostApiV1 silentDropHost = host.api;
    silentDropHost.capabilityBits &= ~AMCL_INPUT_CAP_DIAGNOSTIC_DROP;
    CHECK(adapter.Open(&silentDropHost, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kInvalidConfiguration);
    CHECK(!adapter.IsReady());

    AmclInputHostApiV1 noTypedRoute = host.api;
    noTypedRoute.capabilityBits &=
        ~AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE;
    CHECK(adapter.Open(&noTypedRoute, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kInvalidConfiguration);
    AmclInputHostApiV1 noReadyProtocol = host.api;
    noReadyProtocol.capabilityBits &=
        ~AMCL_INPUT_CAP_BACKEND_CONSUMER_READY;
    CHECK(adapter.Open(&noReadyProtocol, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kInvalidConfiguration);

    AmclInputHostApiV1 absoluteRoute = host.api;
    absoluteRoute.capabilityBits |=
        AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE;
    GlfwInputSink missingAbsolute = recorder.Sink();
    missingAbsolute.absolute = nullptr;
    CHECK(adapter.Open(&absoluteRoute, Mapper(), missingAbsolute) ==
          GlfwAdapterStatus::kInvalidConfiguration);
    GlfwInputSink missingSurface = recorder.Sink();
    missingSurface.surface = nullptr;
    CHECK(adapter.Open(&absoluteRoute, Mapper(), missingSurface) ==
          GlfwAdapterStatus::kInvalidConfiguration);
    CHECK(!adapter.IsReady());

    host.baselineReason = AMCL_INPUT_RESET_EXPLICIT;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kBaselineRejected);
    CHECK(!adapter.IsReady());
    CHECK(host.closeCalls == 1);

    FakeHost malformedCaptureSnapshot;
    malformedCaptureSnapshot.snapshotCaptureRequested = 0u;
    malformedCaptureSnapshot.snapshotCaptureActive = 1u;
    malformedCaptureSnapshot.snapshotCaptureReason =
        AMCL_INPUT_CAPTURE_REASON_GRANTED;
    GlfwInputAdapter malformedCaptureAdapter;
    CHECK(malformedCaptureAdapter.Open(
              &malformedCaptureSnapshot.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kBaselineRejected);
    CHECK(malformedCaptureAdapter.LastOpenRejectSite() ==
          GlfwOpenRejectSite::kSnapshot);
    CHECK((malformedCaptureAdapter.LastOpenRejectDetail() & 64) != 0);

    FakeHost readyFailure;
    readyFailure.readyStatus = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    CHECK(adapter.Open(&readyFailure.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kHostError);
    CHECK(!adapter.HasConsumer());
    CHECK(readyFailure.readyCalls == 1);
    CHECK(readyFailure.closeCalls == 1);

    FakeHost badSnapshot;
    badSnapshot.snapshotAbiVersion = AMCL_INPUT_HOST_API_VERSION + 1u;
    CHECK(adapter.Open(&badSnapshot.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kBaselineRejected);
    CHECK(!adapter.HasConsumer());
}

void TestTextOnlyCompatibilityConsumer() {
    FakeHost host;
    host.api.capabilityBits &=
        ~AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    GlfwInputSink sink{};
    sink.context = &recorder;
    sink.reset = Recorder::Reset;
    sink.textSession = Recorder::TextSession;
    sink.textCommit = Recorder::TextCommit;
    sink.textEditing = Recorder::TextEditing;
    sink.textCandidates = Recorder::TextCandidates;
    sink.textSelection = Recorder::TextSelection;

    // Mobile compatibility builds may intentionally retain the legacy
    // physical route while using the additive typed text-session capability.
    // That consumer needs no key/button mapper and must still baseline/READY.
    CHECK(adapter.Open(&host.api, GlfwInputMapper{}, sink) ==
          GlfwAdapterStatus::kOk);
    CHECK(adapter.IsReady());
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);

    FakeHost missingTextHost;
    missingTextHost.api.capabilityBits &=
        ~(AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE |
          AMCL_INPUT_CAP_TEXT_INPUT_SESSION);
    CHECK(adapter.Open(&missingTextHost.api, GlfwInputMapper{}, sink) ==
          GlfwAdapterStatus::kInvalidConfiguration);
}

void TestRepeatAndPolling() {
    Fixture f;
    // Adapter independently diagnoses ownerless edges even if a nonconforming
    // host delivers known, mappable controls after RESET. They must not acquire
    // contributors or emit ordinary key/button callbacks.
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_REPEAT));
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_UP));
    f.host.Push(Button(1u, 1u, AMCL_INPUT_ACTION_UP));
    const GlfwPumpResult ownerless = f.adapter.Pump();
    CHECK(ownerless.status == GlfwAdapterStatus::kOk);
    CHECK(ownerless.eventsDrained == 3u);
    CHECK(f.recorder.keys.empty());
    CHECK(f.recorder.buttons.empty());
    CHECK(!f.adapter.IsKeyPressed(65));
    CHECK(!f.adapter.IsButtonPressed(0));
    CHECK(f.recorder.unsupportedMappings.empty());
    CHECK(f.recorder.diagnosticDrops.size() == 3u);
    CHECK(f.recorder.diagnosticDrops[0].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT);
    CHECK(f.recorder.diagnosticDrops[0].originalEventType ==
          AMCL_INPUT_EVENT_PHYSICAL_KEY);
    CHECK(f.recorder.diagnosticDrops[0].rawControl == 10u);
    CHECK(f.recorder.diagnosticDrops[0].action == AMCL_INPUT_ACTION_REPEAT);
    CHECK(f.recorder.diagnosticDrops[0].hardwareScanCode == 110u);
    CHECK(f.recorder.diagnosticDrops[0].hidUsage == 210u);
    CHECK(f.recorder.diagnosticDrops[1].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP);
    CHECK(f.recorder.diagnosticDrops[1].action == AMCL_INPUT_ACTION_UP);
    CHECK(f.recorder.diagnosticDrops[2].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP);
    CHECK(f.recorder.diagnosticDrops[2].rawControl == 1u);
    CHECK(f.recorder.diagnosticDrops[2].action == AMCL_INPUT_ACTION_UP);

    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_REPEAT));
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_UP));
    const auto result = f.adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kOk);
    CHECK(result.eventsDrained == 4u);
    CHECK(f.recorder.keys.size() == 4u);
    CHECK(f.recorder.keys[0].action == GlfwInputAction::kPress);
    CHECK(f.recorder.keys[1].action == GlfwInputAction::kRepeat);
    CHECK(f.recorder.keys[2].action == GlfwInputAction::kRepeat);
    CHECK(f.recorder.keys[3].action == GlfwInputAction::kRelease);
    CHECK(!f.adapter.IsKeyPressed(65));
    CHECK(f.recorder.pollingConsistent);
}
void TestTwoDevicesOneMappedKey() {
    Fixture f;
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Key(2u, 11u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_UP));
    f.host.Push(Key(2u, 11u, AMCL_INPUT_ACTION_UP));
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.keys.size() == 2u);
    CHECK(f.recorder.keys.front().action == GlfwInputAction::kPress);
    CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
    CHECK(f.recorder.keys.front().scanCode == 510);
    CHECK(f.recorder.keys.back().scanCode == 510);
    CHECK(f.recorder.pollingConsistent);
}

void TestButtonAggregation() {
    Fixture f;
    f.host.Push(Button(1u, 1u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Button(2u, 2u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Button(1u, 1u, AMCL_INPUT_ACTION_UP));
    f.host.Push(Button(2u, 2u, AMCL_INPUT_ACTION_UP));
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.buttons.size() == 2u);
    CHECK(f.recorder.buttons[0].action == GlfwInputAction::kPress);
    CHECK(f.recorder.buttons[1].action == GlfwInputAction::kRelease);
    CHECK(!f.adapter.IsButtonPressed(0));

    f.host.Push(Button(3u, 1u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Button(3u, 1u, AMCL_INPUT_ACTION_DOWN));
    f.host.Push(Button(3u, 1u, AMCL_INPUT_ACTION_UP));
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.buttons.size() == 4u);
    CHECK(f.recorder.buttons[2].action == GlfwInputAction::kPress);
    CHECK(f.recorder.buttons[3].action == GlfwInputAction::kRelease);
    CHECK(f.recorder.diagnosticDrops.size() == 1u);
    CHECK(f.recorder.diagnosticDrops[0].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN);
    CHECK(f.recorder.diagnosticDrops[0].rawControl == 1u);
    CHECK(f.recorder.diagnosticDrops[0].deviceId == 3u);
    CHECK(!f.adapter.IsButtonPressed(0));
    CHECK(f.recorder.pollingConsistent);
    CHECK(f.recorder.diagnosticReentrySafe);
}

void TestSdlPointerEdgesStayPerDeviceAndRemovalFollowsRelease() {
    Fixture f(Mapper(), AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    f.host.Push(Button(1u, 1u, AMCL_INPUT_ACTION_DOWN,
                       AMCL_INPUT_DEVICE_CLASS_MOUSE));
    f.host.Push(Button(2u, 2u, AMCL_INPUT_ACTION_DOWN,
                       AMCL_INPUT_DEVICE_CLASS_TOUCHPAD));
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    // GLFW/LWJGL aggregate this pair to one global button. SDL must receive one
    // edge per SDL_MouseID, otherwise removing the first device loses the
    // second device's still-held owner.
    CHECK(f.recorder.buttons.size() == 2u);
    CHECK(f.recorder.buttons[0].deviceId == 1u);
    CHECK(f.recorder.buttons[0].deviceClass ==
          AMCL_INPUT_DEVICE_CLASS_MOUSE);
    CHECK(f.recorder.buttons[1].deviceId == 2u);
    CHECK(f.recorder.buttons[1].deviceClass ==
          AMCL_INPUT_DEVICE_CLASS_TOUCHPAD);
    CHECK(f.adapter.IsButtonPressed(0));

    AmclInputEvent removeMouse =
        FakeHost::Event(AMCL_INPUT_EVENT_DEVICE_CHANGED, 1u);
    removeMouse.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_MOUSE;
    removeMouse.payload.device.change = AMCL_INPUT_DEVICE_REMOVED;
    removeMouse.payload.device.capabilities =
        AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS;
    f.host.Push(removeMouse);
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.buttons.size() == 3u);
    CHECK(f.recorder.buttons.back().action == GlfwInputAction::kRelease);
    CHECK(f.recorder.buttons.back().deviceId == 1u);
    CHECK(f.recorder.devices.size() == 1u);
    CHECK(f.recorder.devices[0].deviceId == 1u);
    CHECK(f.recorder.dispatchOrder.size() >= 2u);
    CHECK(f.recorder.dispatchOrder[f.recorder.dispatchOrder.size() - 2u] ==
          AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(f.recorder.dispatchOrder.back() ==
          AMCL_INPUT_EVENT_DEVICE_CHANGED);
    CHECK(f.adapter.IsButtonPressed(0));

    AmclInputEvent removePad =
        FakeHost::Event(AMCL_INPUT_EVENT_DEVICE_CHANGED, 2u);
    removePad.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_TOUCHPAD;
    removePad.payload.device.change = AMCL_INPUT_DEVICE_REMOVED;
    removePad.payload.device.capabilities =
        AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS;
    f.host.Push(removePad);
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.buttons.size() == 4u);
    CHECK(f.recorder.buttons.back().deviceId == 2u);
    CHECK(f.recorder.devices.size() == 2u);
    CHECK(!f.adapter.IsButtonPressed(0));
}

void TestUnsupportedMappingsAreDiagnosed() {
    Fixture f(RejectingMapper());

    AmclInputEvent key = Key(77u, kUnsupportedRawKey,
                             AMCL_INPUT_ACTION_DOWN);
    key.payload.physicalKey.hardwareScanCode = 0x1234u;
    key.payload.physicalKey.hidUsage = 0x5678u;
    const uint64_t keySequence = key.header.sequence;
    f.host.Push(key);

    AmclInputEvent button = Button(88u, kUnsupportedRawButton,
                                   AMCL_INPUT_ACTION_DOWN);
    const uint64_t buttonSequence = button.header.sequence;
    f.host.Push(button);

    const GlfwPumpResult result = f.adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kOk);
    CHECK(result.eventsDrained == 2u);
    CHECK(f.adapter.IsReady());
    CHECK(f.recorder.keys.empty());
    CHECK(f.recorder.buttons.empty());
    CHECK(f.recorder.unsupportedMappings.size() == 2u);

    const GlfwUnsupportedMappingSinkEvent& keyDiagnostic =
        f.recorder.unsupportedMappings[0];
    CHECK(keyDiagnostic.kind == GlfwUnsupportedMappingKind::kKey);
    CHECK(keyDiagnostic.rawControl == kUnsupportedRawKey);
    CHECK(keyDiagnostic.action == AMCL_INPUT_ACTION_DOWN);
    CHECK(keyDiagnostic.deviceId == 77u);
    CHECK(keyDiagnostic.hardwareScanCode == 0x1234u);
    CHECK(keyDiagnostic.hidUsage == 0x5678u);
    CHECK(keyDiagnostic.sequence == keySequence);

    const GlfwUnsupportedMappingSinkEvent& buttonDiagnostic =
        f.recorder.unsupportedMappings[1];
    CHECK(buttonDiagnostic.kind == GlfwUnsupportedMappingKind::kButton);
    CHECK(buttonDiagnostic.rawControl == kUnsupportedRawButton);
    CHECK(buttonDiagnostic.action == AMCL_INPUT_ACTION_DOWN);
    CHECK(buttonDiagnostic.deviceId == 88u);
    CHECK(buttonDiagnostic.hardwareScanCode == 0u);
    CHECK(buttonDiagnostic.hidUsage == 0u);
    CHECK(buttonDiagnostic.sequence == buttonSequence);

    AmclInputEvent keyRepeat = Key(77u, kUnsupportedRawKey,
                                   AMCL_INPUT_ACTION_REPEAT);
    keyRepeat.payload.physicalKey.hardwareScanCode = 0x1234u;
    keyRepeat.payload.physicalKey.hidUsage = 0x5678u;
    f.host.Push(keyRepeat);
    f.host.Push(Key(77u, kUnsupportedRawKey, AMCL_INPUT_ACTION_UP));
    f.host.Push(Button(88u, kUnsupportedRawButton, AMCL_INPUT_ACTION_UP));
    const GlfwPumpResult ownerlessResult = f.adapter.Pump();
    CHECK(ownerlessResult.status == GlfwAdapterStatus::kOk);
    CHECK(ownerlessResult.eventsDrained == 3u);
    CHECK(f.recorder.unsupportedMappings.size() == 5u);
    CHECK(f.recorder.unsupportedMappings[2].kind ==
          GlfwUnsupportedMappingKind::kKey);
    CHECK(f.recorder.unsupportedMappings[2].action ==
          AMCL_INPUT_ACTION_REPEAT);
    CHECK(f.recorder.unsupportedMappings[3].kind ==
          GlfwUnsupportedMappingKind::kKey);
    CHECK(f.recorder.unsupportedMappings[3].action == AMCL_INPUT_ACTION_UP);
    CHECK(f.recorder.unsupportedMappings[4].kind ==
          GlfwUnsupportedMappingKind::kButton);
    CHECK(f.recorder.unsupportedMappings[4].action == AMCL_INPUT_ACTION_UP);
    CHECK(f.recorder.diagnosticDrops.size() == 3u);
    CHECK(f.recorder.diagnosticDrops[0].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT);
    CHECK(f.recorder.diagnosticDrops[1].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP);
    CHECK(f.recorder.diagnosticDrops[2].reason ==
          AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP);

    // A diagnostic is observability only: neither ordinary callback nor held
    // contributor may be manufactured, and querying from the callback itself
    // must be safe because Dispatch runs outside the adapter lock.
    CHECK(!f.adapter.IsKeyPressed(
        static_cast<int32_t>(kUnsupportedRawKey + 1000u)));
    CHECK(!f.adapter.IsButtonPressed(
        static_cast<int32_t>(kUnsupportedRawButton)));
    CHECK(f.recorder.diagnosticReentrySafe);
}

void TestResetAndFocusRelease() {
    {
        Fixture f;
        f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
        AmclInputEvent reset = FakeHost::Event(AMCL_INPUT_EVENT_RESET);
        reset.payload.reset.reason = AMCL_INPUT_RESET_QUEUE_OVERFLOW;
        reset.payload.reset.closingEpoch = f.host.sessionEpoch + 1u;
        f.host.Push(reset);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(!f.adapter.IsKeyPressed(65));
        CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
        CHECK(f.recorder.reset == 0);
    }
    {
        Fixture f;
        f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
        AmclInputEvent reset = FakeHost::Event(AMCL_INPUT_EVENT_RESET);
        reset.payload.reset.reason = AMCL_INPUT_RESET_QUEUE_OVERFLOW;
        reset.payload.reset.closingEpoch = f.host.sessionEpoch;
        f.host.Push(reset);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        CHECK(f.recorder.keys.size() == 2u);
        CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
        CHECK(f.recorder.reset == 1);
        CHECK(!f.adapter.IsKeyPressed(65));
    }
    {
        Fixture f;
        f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
        AmclInputEvent focus = FakeHost::Event(AMCL_INPUT_EVENT_FOCUS_CHANGED);
        focus.payload.focus.focused = 0u;
        f.host.Push(focus);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        CHECK(f.recorder.keys.size() == 2u);
        CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
        CHECK(f.recorder.focus == 1);
        CHECK(!f.adapter.IsKeyPressed(65));
        CHECK(f.recorder.pollingConsistent);
    }
    {
        Fixture f;
        AmclInputEvent reset = FakeHost::Event(AMCL_INPUT_EVENT_RESET);
        reset.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
        reset.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
        reset.payload.reset.reason = AMCL_INPUT_RESET_BACKEND_ABANDONED;
        reset.payload.reset.closingEpoch = f.host.sessionEpoch;
        f.host.Push(reset);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        CHECK(f.recorder.reset == 1);
    }
}
void TestStaleAndOverflowRelease() {
    {
        Fixture f;
        f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        f.host.nextStatus = AMCL_INPUT_ERROR_STALE;
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kStale);
        CHECK(!f.adapter.IsReady());
        CHECK(!f.adapter.IsKeyPressed(65));
        CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
    }
    {
        Fixture f;
        f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        f.host.nextStatus = AMCL_INPUT_OVERFLOW_RESET;
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOverflowReset);
        CHECK(f.adapter.IsReady());
        CHECK(!f.adapter.IsKeyPressed(65));
        CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
    }
}

void TestEventSinkShapes() {
    Fixture f;
    AmclInputEvent absolute = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_ABSOLUTE, 1u);
    absolute.payload.pointerAbsolute.localPxX = 3.0;
    absolute.payload.pointerAbsolute.localPxY = 4.0;
    f.host.Push(absolute);
    AmclInputEvent relative = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_RELATIVE, 1u);
    relative.payload.pointerRelative.rawDx = 1.5;
    relative.payload.pointerRelative.rawDy = -2.5;
    relative.header.flags = AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW;
    f.host.Push(relative);
    AmclInputEvent wheel = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_WHEEL, 1u);
    wheel.payload.pointerWheel.x = 0.25f;
    wheel.payload.pointerWheel.y = -0.5f;
    wheel.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_PIXEL;
    wheel.payload.pointerWheel.precise = 1u;
    f.host.Push(wheel);
    AmclInputEvent enter = FakeHost::Event(AMCL_INPUT_EVENT_POINTER_ENTER);
    enter.payload.pointerEnter.entered = 1u;
    f.host.Push(enter);
    AmclInputEvent capture = FakeHost::Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
    capture.payload.capture.requested = 1u;
    capture.payload.capture.active = 1u;
    capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    f.host.Push(capture);
    AmclInputEvent surface = FakeHost::Event(AMCL_INPUT_EVENT_SURFACE_CHANGED);
    surface.payload.surface.active = 1u;
    surface.payload.surface.widthPx = 800u;
    surface.payload.surface.heightPx = 600u;
    surface.payload.surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    f.host.Push(surface);
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(f.recorder.absolute == 0 && f.recorder.relative == 1);
    CHECK(f.recorder.wheel == 1 && f.recorder.enter == 1);
    CHECK(f.recorder.capture == 1 && f.recorder.surface == 1);
    CHECK(f.recorder.relatives.size() == 1u);
    CHECK(f.recorder.relatives[0].hardwareRaw);
    CHECK(f.recorder.relatives[0].monotonicTimeNs ==
          relative.header.monotonicTimeNs);
    CHECK(!f.recorder.captures[0].baseline);
}

void TestSurfaceContextStartupAllowlistAndSink() {
    FakeHost host;
    host.replaySurface = true;
    host.replaySurfaceContext = true;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(recorder.surfaceContexts.empty());
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.surface == 1);
    CHECK(recorder.surfaceContexts.size() == 1u);
    CHECK(recorder.surfaceContexts[0].surfaceContext.generation == 33u);
    CHECK(recorder.surfaceContexts[0].surfaceContext.windowId == 9);
    CHECK(recorder.dispatchOrder.size() == 2u);
    CHECK(recorder.dispatchOrder[0] == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(recorder.dispatchOrder[1] ==
          AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);

    Fixture malformed;
    AmclInputEvent invalid = FakeHost::Event(
        AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
    invalid.payload.surfaceContext.generation = 1u;
    invalid.payload.surfaceContext.validFields =
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM;
    invalid.payload.surfaceContext.transform = 4u;
    malformed.host.Push(invalid);
    const GlfwPumpResult result = malformed.adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kMalformedEvent);
    CHECK(result.abandoned);
    CHECK(malformed.recorder.surfaceContexts.empty());
}

void TestSnapshotSeedsLostFocusAndActiveCapture() {
    FakeHost host;
    host.snapshotFocused = 0u;
    host.snapshotCaptureRequested = 1u;
    host.snapshotCaptureActive = 1u;
    host.snapshotCaptureReason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(recorder.focus == 0);
    CHECK(recorder.capture == 0);

    const GlfwPumpResult pump = adapter.Pump();
    CHECK(pump.status == GlfwAdapterStatus::kOk);
    CHECK(pump.eventsDrained == 0u);
    CHECK(recorder.focuses.size() == 1u);
    CHECK(!recorder.focuses[0].focused);
    CHECK(recorder.focuses[0].baseline);
    CHECK(recorder.captures.size() == 1u);
    CHECK(recorder.captures[0].requested);
    CHECK(recorder.captures[0].active);
    CHECK(recorder.captures[0].reason == AMCL_INPUT_CAPTURE_REASON_GRANTED);
    CHECK(recorder.captures[0].baseline);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

void TestNonGlfwBackendSeedsFocusedBaseline() {
    FakeHost host;
    host.expectedBackend = AMCL_INPUT_BACKEND_SDL3_PHYSICAL;
    host.snapshotFocused = 1u;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink(),
                       AMCL_INPUT_BACKEND_SDL3_PHYSICAL) ==
          GlfwAdapterStatus::kOk);
    CHECK(recorder.focuses.empty());
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.focuses.size() == 1u);
    CHECK(recorder.focuses[0].focused);
    CHECK(recorder.focuses[0].baseline);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

void TestNonGlfwBackendAbandonUsesClaimedSlot() {
    FakeHost host;
    host.expectedBackend = AMCL_INPUT_BACKEND_SDL3_PHYSICAL;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink(),
                       AMCL_INPUT_BACKEND_SDL3_PHYSICAL) ==
          GlfwAdapterStatus::kOk);
    AmclInputEvent malformed = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_RELATIVE, 1u);
    malformed.header.flags = 1u << 31u;
    host.Push(malformed);
    const GlfwPumpResult result = adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kMalformedEvent);
    CHECK(result.abandoned);
    CHECK(host.abandonCalls == 1);
    CHECK(!adapter.HasConsumer());
}

void TestTypedAbsoluteSurfaceBindingAndButtonOrder() {
    FakeHost host;
    host.api.capabilityBits |=
        AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE;
    host.replaySurface = true;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(host.backendReady);
    CHECK(host.events.empty());
    CHECK(recorder.surface == 0);

    AmclInputEvent absolute = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_ABSOLUTE, 7u);
    absolute.header.surfaceEpoch = host.replaySurfaceEpoch;
    absolute.payload.pointerAbsolute.localPxX = 12.5;
    absolute.payload.pointerAbsolute.localPxY = 13.5;
    host.Push(absolute);
    AmclInputEvent button = Button(7u, 1u, AMCL_INPUT_ACTION_DOWN);
    button.header.surfaceEpoch = host.replaySurfaceEpoch;
    button.header.flags |= AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
    host.Push(button);
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.surface == 1);
    CHECK(recorder.absolute == 1);
    CHECK(recorder.buttons.size() == 1u);
    CHECK(recorder.dispatchOrder.size() == 3u);
    CHECK(recorder.dispatchOrder[0] == AMCL_INPUT_EVENT_SURFACE_CHANGED);
    CHECK(recorder.dispatchOrder[1] == AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    CHECK(recorder.dispatchOrder[2] == AMCL_INPUT_EVENT_POINTER_BUTTON);
    CHECK(recorder.absolutes[0].surfaceEpoch == host.replaySurfaceEpoch);
    CHECK(recorder.absolutes[0].publicationGeneration ==
          host.replayPublicationGeneration);
    CHECK(recorder.buttons[0].surfaceEpoch == host.replaySurfaceEpoch);
    CHECK(recorder.buttons[0].requiresAbsoluteAuthorization);

    AmclInputEvent surface = FakeHost::Event(
        AMCL_INPUT_EVENT_SURFACE_CHANGED);
    surface.header.surfaceEpoch = 4u;
    surface.payload.surface.active = 1u;
    surface.payload.surface.widthPx = 800u;
    surface.payload.surface.heightPx = 600u;
    surface.payload.surface.validFields =
        AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
        AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    surface.payload.surface.publicationGeneration = 21u;
    host.Push(surface);

    AmclInputEvent staleAbsolute = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_ABSOLUTE, 8u);
    staleAbsolute.header.surfaceEpoch = 3u;
    staleAbsolute.payload.pointerAbsolute.localPxX = 1.0;
    staleAbsolute.payload.pointerAbsolute.localPxY = 2.0;
    host.Push(staleAbsolute);
    AmclInputEvent staleButton = Button(8u, 1u, AMCL_INPUT_ACTION_DOWN);
    staleButton.header.surfaceEpoch = 3u;
    staleButton.header.flags |=
        AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
    host.Push(staleButton);

    AmclInputEvent freshAbsolute = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_ABSOLUTE, 9u);
    freshAbsolute.header.surfaceEpoch = 4u;
    freshAbsolute.payload.pointerAbsolute.localPxX = 3.0;
    freshAbsolute.payload.pointerAbsolute.localPxY = 4.0;
    host.Push(freshAbsolute);
    // Use a distinct mapped button. raw 1 and 2 intentionally aggregate to
    // GLFW button 0, which would suppress a second PRESS even when the absolute
    // authorization itself is valid.
    AmclInputEvent freshButton = Button(9u, 3u, AMCL_INPUT_ACTION_DOWN);
    freshButton.header.surfaceEpoch = 4u;
    freshButton.header.flags |=
        AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
    host.Push(freshButton);

    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.surface == 2);
    CHECK(recorder.absolute == 2);
    CHECK(recorder.absolutes.back().surfaceEpoch == 4u);
    CHECK(recorder.absolutes.back().publicationGeneration == 21u);
    CHECK(recorder.buttons.size() == 2u);
    CHECK(recorder.buttons.back().deviceId == 9u);
    CHECK(adapter.AbsoluteRouteDropCount() >= 2u);

    // Grabbed/captured mode intentionally produces button-only edges. Only a
    // producer-marked position-bound edge participates in the transaction.
    AmclInputEvent grabbedButton = Button(10u, 4u, AMCL_INPUT_ACTION_DOWN);
    grabbedButton.header.surfaceEpoch = 4u;
    host.Push(grabbedButton);
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.buttons.size() == 3u);
    CHECK(!recorder.buttons.back().requiresAbsoluteAuthorization);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

void TestNonFinitePayloadsFailClosedBeforeSinks() {
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_POINTER_WHEEL, 1u);
        event.header.flags = 1u << 31u;
        event.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_LINE;
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(f.recorder.wheel == 0);
    }
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_POINTER_ABSOLUTE, 1u);
        event.payload.pointerAbsolute.localPxX =
            std::numeric_limits<double>::quiet_NaN();
        event.payload.pointerAbsolute.localPxY = 1.0;
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(f.recorder.absolute == 0);
    }
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_POINTER_RELATIVE, 1u);
        event.payload.pointerRelative.rawDx = 1.0;
        event.payload.pointerRelative.rawDy =
            std::numeric_limits<double>::infinity();
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(f.recorder.relative == 0);
    }
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_POINTER_WHEEL, 1u);
        event.payload.pointerWheel.x =
            -std::numeric_limits<float>::infinity();
        event.payload.pointerWheel.y = 1.0f;
        event.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_LINE;
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(f.recorder.wheel == 0);
    }
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_SURFACE_CHANGED);
        event.payload.surface.active = 1u;
        event.payload.surface.widthPx = 800u;
        event.payload.surface.heightPx = 600u;
        event.payload.surface.density =
            std::numeric_limits<float>::quiet_NaN();
        event.payload.surface.validFields =
            AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
            AMCL_INPUT_SURFACE_FIELD_DENSITY;
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kMalformedEvent);
        CHECK(!f.adapter.IsReady());
        CHECK(f.recorder.surface == 0);
    }
    {
        Fixture f;
        AmclInputEvent event = FakeHost::Event(
            AMCL_INPUT_EVENT_SURFACE_CHANGED);
        event.payload.surface.active = 1u;
        event.payload.surface.widthPx = 800u;
        event.payload.surface.heightPx = 600u;
        event.payload.surface.density =
            std::numeric_limits<float>::quiet_NaN();
        event.payload.surface.validFields =
            AMCL_INPUT_SURFACE_FIELD_DIMENSIONS | (1u << 31u);
        f.host.Push(event);
        CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
        CHECK(f.adapter.IsReady());
        CHECK(f.recorder.surface == 1);
    }
}
void TestTextReleaseAndFailClosed() {
    Fixture f;
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
    AmclInputEvent start = FakeHost::Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    start.header.source = AMCL_INPUT_SOURCE_IME;
    start.payload.textSession.textSessionId = 77u;
    start.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
    start.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    f.host.Push(start);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.header.source = AMCL_INPUT_SOURCE_IME;
    text.payload.textCommit.utf8Blob.packetId = 99u;
    text.payload.textCommit.utf8Blob.length = 3u;
    text.payload.textCommit.textSessionId = 77u;
    f.host.blobs[99u] = {'a', 'b', 'c'};
    f.host.Push(text);
    const auto result = f.adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kOk);
    CHECK(f.host.releaseCalls == 1);
    CHECK(f.adapter.IsReady());
    CHECK(f.adapter.IsKeyPressed(65));
    CHECK(f.recorder.textSessions.size() == 1u);
    CHECK(f.recorder.textCommits.size() == 1u);
    CHECK(f.recorder.textCommits[0].utf8 ==
          std::vector<uint8_t>({'a', 'b', 'c'}));
    CHECK(f.adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(!f.adapter.IsKeyPressed(65));
    CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
}

void TestCloseReleasesBlobAndCompletesDrainRequired() {
    Fixture f;
    AmclInputEvent start = FakeHost::Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
    start.header.source = AMCL_INPUT_SOURCE_IME;
    start.payload.textSession.textSessionId = 88u;
    start.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
    start.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    f.host.Push(start);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.header.source = AMCL_INPUT_SOURCE_IME;
    text.payload.textCommit.utf8Blob.packetId = 199u;
    text.payload.textCommit.utf8Blob.length = 4u;
    text.payload.textCommit.textSessionId = 88u;
    f.host.blobs[199u] = {'t', 'e', 'x', 't'};
    f.host.Push(text);
    f.host.forcedDrainResponses = 1;
    CHECK(f.adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(f.host.releaseCalls == 1);
    CHECK(f.host.closeCalls == 2);
    CHECK(!f.adapter.HasConsumer());
}

void TestFailedAbandonRetainsHandleAndOpenRetriesCleanup() {
    Fixture f;
    f.host.abandonStatus = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    AmclInputEvent malformed = FakeHost::Event(
        AMCL_INPUT_EVENT_POINTER_RELATIVE, 1u);
    malformed.payload.pointerRelative.rawDx =
        std::numeric_limits<double>::quiet_NaN();
    malformed.payload.pointerRelative.rawDy = 1.0;
    f.host.Push(malformed);
    const GlfwPumpResult failed = f.adapter.Pump();
    CHECK(failed.status == GlfwAdapterStatus::kMalformedEvent);
    CHECK(!failed.abandoned);
    CHECK(f.adapter.HasConsumer());
    CHECK(f.host.abandonCalls == 1);

    f.host.abandonStatus = AMCL_INPUT_OK;
    CHECK(f.adapter.Open(&f.host.api, Mapper(), f.recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(f.host.abandonCalls == 2);
    CHECK(f.adapter.Close() == GlfwAdapterStatus::kOk);
}

void TestCloseIdempotentAndUnconditional() {
    Fixture f;
    f.host.Push(Key(1u, 10u, AMCL_INPUT_ACTION_DOWN));
    CHECK(f.adapter.Pump().status == GlfwAdapterStatus::kOk);
    f.host.closeStatus = AMCL_INPUT_ERROR_STALE;
    // A stale result after the retirement queue is drained proves that the
    // remote handle is already terminal; retaining it would block reopen.
    CHECK(f.adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(!f.adapter.IsReady());
    CHECK(!f.adapter.IsKeyPressed(65));
    CHECK(f.recorder.keys.back().action == GlfwInputAction::kRelease);
    const int calls = f.host.closeCalls;
    CHECK(f.adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(f.host.closeCalls == calls);
}

struct ClosingMapperContext {
    GlfwInputAdapter* adapter = nullptr;
    GlfwAdapterStatus closeStatus = GlfwAdapterStatus::kHostError;
    uint32_t calls = 0u;
};

bool MapKeyAndClose(void* context, uint64_t, uint32_t physical,
                    uint32_t scanCode, uint32_t,
                    GlfwMappedKey* output) {
    auto& self = *static_cast<ClosingMapperContext*>(context);
    ++self.calls;
    self.closeStatus = self.adapter->Close();
    output->key = static_cast<int32_t>(physical + 1000u);
    output->scanCode = static_cast<int32_t>(scanCode);
    return true;
}

void TestMapperCanSynchronouslyCloseAndReopen() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    ClosingMapperContext mapperContext{&adapter};
    const GlfwInputMapper mapper{&mapperContext, MapKeyAndClose, MapButton};
    CHECK(adapter.Open(&host.api, mapper, recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(9u, 20u, AMCL_INPUT_ACTION_DOWN));

    auto future = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    CHECK(future.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = future.get();
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDrained == 1u);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(mapperContext.calls == 1u);
    CHECK(mapperContext.closeStatus == GlfwAdapterStatus::kOk);
    CHECK(host.retireCalls == 1);
    CHECK(!adapter.HasConsumer());
    CHECK(adapter.DiscardedFetchedEventCount() == 1u);
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

struct ClosingSinkContext {
    GlfwInputAdapter* adapter = nullptr;
    GlfwAdapterStatus closeStatus = GlfwAdapterStatus::kHostError;
    std::vector<GlfwInputAction> actions;

    static void Key(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<ClosingSinkContext*>(context);
        self.actions.push_back(event.action);
        if (event.action == GlfwInputAction::kPress) {
            self.closeStatus = self.adapter->Close();
        }
    }

    GlfwInputSink Sink() {
        GlfwInputSink value{};
        value.context = this;
        value.key = Key;
        return value;
    }
};

void TestSinkCanSynchronouslyCloseAndReopen() {
    FakeHost host;
    GlfwInputAdapter adapter;
    ClosingSinkContext sink{&adapter};
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(10u, 30u, AMCL_INPUT_ACTION_DOWN));

    auto future = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    CHECK(future.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = future.get();
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDrained == 1u);
    CHECK(result.eventsDiscarded == 0u);
    CHECK(sink.closeStatus == GlfwAdapterStatus::kOk);
    CHECK(sink.actions.size() == 2u);
    CHECK(sink.actions[0] == GlfwInputAction::kPress);
    CHECK(sink.actions[1] == GlfwInputAction::kRelease);
    CHECK(!adapter.HasConsumer());
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

struct ClosingMultiReleaseSink {
    GlfwInputAdapter* adapter = nullptr;
    GlfwAdapterStatus closeStatus = GlfwAdapterStatus::kHostError;
    std::vector<int32_t> pressedKeys;
    std::vector<int32_t> releasedKeys;
    std::vector<int32_t> pressedButtons;
    std::vector<int32_t> releasedButtons;

    static void Key(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<ClosingMultiReleaseSink*>(context);
        if (event.action == GlfwInputAction::kRelease) {
            self.releasedKeys.push_back(event.key);
            if (self.releasedKeys.size() == 1u) {
                self.closeStatus = self.adapter->Close();
            }
        } else if (event.action == GlfwInputAction::kPress) {
            self.pressedKeys.push_back(event.key);
        }
    }

    static void Button(void* context, const GlfwButtonSinkEvent& event) {
        auto& self = *static_cast<ClosingMultiReleaseSink*>(context);
        if (event.action == GlfwInputAction::kRelease) {
            self.releasedButtons.push_back(event.button);
        } else if (event.action == GlfwInputAction::kPress) {
            self.pressedButtons.push_back(event.button);
        }
    }

    GlfwInputSink Sink() {
        GlfwInputSink value{};
        value.context = this;
        value.key = Key;
        value.button = Button;
        return value;
    }
};

void TestSynchronousCloseFinishesMultiReleaseTransaction() {
    FakeHost host;
    GlfwInputAdapter adapter;
    ClosingMultiReleaseSink sink{&adapter};
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(93u, 10u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Key(94u, 11u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Key(95u, 60u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Button(93u, 7u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(sink.pressedKeys.size() == 2u);
    CHECK(sink.pressedButtons.size() == 1u);

    AmclInputEvent focus = FakeHost::Event(AMCL_INPUT_EVENT_FOCUS_CHANGED);
    focus.payload.focus.focused = 0u;
    host.Push(focus);
    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(sink.closeStatus == GlfwAdapterStatus::kOk);
    CHECK(sink.releasedKeys.size() == 2u);
    CHECK(sink.releasedKeys[0] == 65);
    CHECK(sink.releasedKeys[1] == 1060);
    CHECK(sink.releasedButtons.size() == 1u);
    CHECK(sink.releasedButtons[0] == 7);
    CHECK(!adapter.IsKeyPressed(65));
    CHECK(!adapter.IsKeyPressed(1060));
    CHECK(!adapter.HasConsumer());
}

void TestSynchronousCloseFinishesOverflowMultiRelease() {
    FakeHost host;
    GlfwInputAdapter adapter;
    ClosingMultiReleaseSink sink{&adapter};
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(95u, 62u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Key(96u, 63u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    host.nextStatus = AMCL_INPUT_OVERFLOW_RESET;

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(sink.closeStatus == GlfwAdapterStatus::kOk);
    CHECK(sink.releasedKeys.size() == 2u);
    CHECK(sink.releasedKeys[0] == 1062);
    CHECK(sink.releasedKeys[1] == 1063);
    CHECK(!adapter.IsKeyPressed(1062));
    CHECK(!adapter.IsKeyPressed(1063));
    CHECK(!adapter.HasConsumer());
}

void TestTerminalCloseBatchRejectsReentryUntilBalanced() {
    FakeHost host;
    GlfwInputAdapter adapter;
    ClosingMultiReleaseSink sink{&adapter};
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(97u, 64u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Key(98u, 65u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    host.enqueueRetireReset = false;

    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
    CHECK(sink.closeStatus == GlfwAdapterStatus::kNotReady);
    CHECK(sink.releasedKeys.size() == 2u);
    CHECK(sink.releasedKeys[0] == 1064);
    CHECK(sink.releasedKeys[1] == 1065);
    CHECK(!adapter.HasConsumer());
}

void TestTerminalAbandonBatchRejectsReentryUntilBalanced() {
    FakeHost host;
    GlfwInputAdapter adapter;
    ClosingMultiReleaseSink sink{&adapter};
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(99u, 66u, AMCL_INPUT_ACTION_DOWN));
    host.Push(Key(100u, 67u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    host.nextStatus = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;

    const GlfwPumpResult result = adapter.Pump();
    CHECK(result.status == GlfwAdapterStatus::kHostError);
    CHECK(result.abandoned);
    CHECK(sink.closeStatus == GlfwAdapterStatus::kNotReady);
    CHECK(sink.releasedKeys.size() == 2u);
    CHECK(sink.releasedKeys[0] == 1066);
    CHECK(sink.releasedKeys[1] == 1067);
    CHECK(!adapter.HasConsumer());
}

struct BlockingMapperContext {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false;
    bool proceed = false;
    bool exited = false;

    static bool MapKey(void* context, uint64_t, uint32_t physical,
                       uint32_t scanCode, uint32_t,
                       GlfwMappedKey* output) {
        auto& self = *static_cast<BlockingMapperContext*>(context);
        std::unique_lock<std::mutex> lock(self.mutex);
        self.entered = true;
        self.condition.notify_all();
        self.condition.wait(lock, [&self]() { return self.proceed; });
        output->key = static_cast<int32_t>(physical + 1000u);
        output->scanCode = static_cast<int32_t>(scanCode);
        self.exited = true;
        self.condition.notify_all();
        return true;
    }
};

void TestConcurrentCloseWaitsForMapperCallback() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    BlockingMapperContext mapperContext;
    const GlfwInputMapper mapper{
        &mapperContext, BlockingMapperContext::MapKey, MapButton};
    CHECK(adapter.Open(&host.api, mapper, recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(91u, 50u, AMCL_INPUT_ACTION_DOWN));

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(mapperContext.mutex);
        CHECK(mapperContext.condition.wait_for(
            lock, std::chrono::seconds(2), [&mapperContext]() {
                return mapperContext.entered;
            }));
    }
    std::promise<void> closeStarted;
    std::future<void> closeStartedFuture = closeStarted.get_future();
    auto close = std::async(std::launch::async, [&adapter, &closeStarted]() {
        closeStarted.set_value();
        return adapter.Close();
    });
    CHECK(closeStartedFuture.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::milliseconds(100)) ==
          std::future_status::timeout);
    {
        std::lock_guard<std::mutex> lock(mapperContext.mutex);
        mapperContext.proceed = true;
    }
    mapperContext.condition.notify_all();

    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    const GlfwPumpResult result = pump.get();
    // Once the mapper returns, either the event commit or Close may win the
    // callback lease. Both linearizations are valid; Close must not return
    // while the mapper still owns the old context.
    CHECK(result.status == GlfwAdapterStatus::kNotReady ||
          result.status == GlfwAdapterStatus::kOk);
    {
        std::lock_guard<std::mutex> lock(mapperContext.mutex);
        CHECK(mapperContext.exited);
    }
    CHECK(recorder.keys.empty() || recorder.keys.size() == 2u);
    if (!recorder.keys.empty()) {
        CHECK(recorder.keys.front().action == GlfwInputAction::kPress);
        CHECK(recorder.keys.back().action == GlfwInputAction::kRelease);
    }
    CHECK(!adapter.HasConsumer());
}

struct BlockingReleaseSink {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false;
    bool proceed = false;
    bool exited = false;
    uint32_t presses = 0u;
    uint32_t releases = 0u;

    static void Key(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<BlockingReleaseSink*>(context);
        if (event.action != GlfwInputAction::kRelease) {
            ++self.presses;
            return;
        }
        std::unique_lock<std::mutex> lock(self.mutex);
        ++self.releases;
        self.entered = true;
        self.condition.notify_all();
        self.condition.wait(lock, [&self]() { return self.proceed; });
        self.exited = true;
        self.condition.notify_all();
    }

    GlfwInputSink Sink() {
        GlfwInputSink value{};
        value.context = this;
        value.key = Key;
        return value;
    }
};

void TestConcurrentCloseWaitsForOverflowReleaseCallback() {
    FakeHost host;
    GlfwInputAdapter adapter;
    BlockingReleaseSink sink;
    CHECK(adapter.Open(&host.api, Mapper(), sink.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(92u, 51u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(sink.presses == 1u);
    host.nextStatus = AMCL_INPUT_OVERFLOW_RESET;

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(sink.mutex);
        CHECK(sink.condition.wait_for(
            lock, std::chrono::seconds(2), [&sink]() {
                return sink.entered;
            }));
    }
    std::promise<void> closeStarted;
    std::future<void> closeStartedFuture = closeStarted.get_future();
    auto close = std::async(std::launch::async, [&adapter, &closeStarted]() {
        closeStarted.set_value();
        return adapter.Close();
    });
    CHECK(closeStartedFuture.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::milliseconds(100)) ==
          std::future_status::timeout);
    {
        std::lock_guard<std::mutex> lock(sink.mutex);
        sink.proceed = true;
    }
    sink.condition.notify_all();

    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(pump.get().status == GlfwAdapterStatus::kOverflowReset);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    {
        std::lock_guard<std::mutex> lock(sink.mutex);
        CHECK(sink.exited);
    }
    CHECK(sink.releases == 1u);
    CHECK(!adapter.HasConsumer());
}

struct AdapterFetchRegisteredBarrier {
    std::mutex mutex;
    std::condition_variable condition;
    bool reached = false;
    bool proceed = false;

    static void Hook(void* context, GlfwInputAdapterTestSeam seam) {
        if (seam != GlfwInputAdapterTestSeam::kAfterFetchRegistered) return;
        auto& self = *static_cast<AdapterFetchRegisteredBarrier*>(context);
        std::unique_lock<std::mutex> lock(self.mutex);
        self.reached = true;
        self.condition.notify_all();
        self.condition.wait(lock, [&self]() { return self.proceed; });
    }
};

void TestCloseOwnsRegisteredBlobWhenItWinsReleaseLease() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.payload.textCommit.utf8Blob.packetId = 249u;
    text.payload.textCommit.utf8Blob.length = 2u;
    host.Push(text);
    AdapterFetchRegisteredBarrier barrier;
    GlfwInputAdapterSetTestHook(AdapterFetchRegisteredBarrier::Hook, &barrier);

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        CHECK(barrier.condition.wait_for(
            lock, std::chrono::seconds(2), [&barrier]() {
                return barrier.reached;
            }));
    }
    auto close = std::async(std::launch::async, [&adapter]() {
        return adapter.Close();
    });
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.proceed = true;
    }
    barrier.condition.notify_all();
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    GlfwInputAdapterSetTestHook(nullptr, nullptr);
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(host.releaseCalls == 1);
    CHECK(host.abandonCalls == 0);
    CHECK(!adapter.HasConsumer());
}

void TestPumpOwnsRegisteredBlobUntilReleaseReturns() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.payload.textCommit.utf8Blob.packetId = 259u;
    text.payload.textCommit.utf8Blob.length = 2u;
    host.Push(text);
    host.pauseRelease = true;

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(host.releaseBarrierMutex);
        CHECK(host.releaseBarrierCondition.wait_for(
            lock, std::chrono::seconds(2), [&host]() {
                return host.releaseEntered;
            }));
    }
    std::promise<void> closeStarted;
    std::future<void> closeStartedFuture = closeStarted.get_future();
    auto close = std::async(std::launch::async, [&adapter, &closeStarted]() {
        closeStarted.set_value();
        return adapter.Close();
    });
    CHECK(closeStartedFuture.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::milliseconds(100)) ==
          std::future_status::timeout);
    {
        std::lock_guard<std::mutex> lock(host.releaseBarrierMutex);
        host.allowRelease = true;
    }
    host.releaseBarrierCondition.notify_all();

    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    CHECK(result.status == GlfwAdapterStatus::kOk);
    CHECK(!result.abandoned);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    CHECK(host.releaseCalls == 1);
    CHECK(host.abandonCalls == 0);
    CHECK(!adapter.HasConsumer());
}

void TestFetchedBlobIsReleasedWhenCloseWinsRegistrationFence() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.payload.textCommit.utf8Blob.packetId = 299u;
    text.payload.textCommit.utf8Blob.length = 2u;
    host.Push(text);
    host.pauseNextAfterPop = true;

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(host.nextBarrierMutex);
        CHECK(host.nextBarrierCondition.wait_for(
            lock, std::chrono::seconds(2), [&host]() {
                return host.nextEventPopped;
            }));
    }
    auto close = std::async(std::launch::async, [&adapter]() {
        return adapter.Close();
    });
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(2);
    while (adapter.IsReady() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    CHECK(!adapter.IsReady());
    {
        std::lock_guard<std::mutex> lock(host.nextBarrierMutex);
        host.allowNextReturn = true;
    }
    host.nextBarrierCondition.notify_all();

    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult pumpResult = pump.get();
    CHECK(pumpResult.status == GlfwAdapterStatus::kNotReady);
    CHECK(pumpResult.eventsDiscarded == 1u);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    CHECK(host.releaseCalls == 1);
    CHECK(host.abandonCalls == 0);
    CHECK(!adapter.HasConsumer());

    host.pauseNextAfterPop = false;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

void TestFetchedBlobReleaseFailureIsReportedWhenCloseWinsFence() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    AmclInputEvent text = FakeHost::Event(AMCL_INPUT_EVENT_TEXT_COMMIT);
    text.payload.textCommit.utf8Blob.packetId = 399u;
    text.payload.textCommit.utf8Blob.length = 2u;
    host.Push(text);
    host.releaseStatus = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    host.pauseNextAfterPop = true;

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(host.nextBarrierMutex);
        CHECK(host.nextBarrierCondition.wait_for(
            lock, std::chrono::seconds(2), [&host]() {
                return host.nextEventPopped;
            }));
    }
    auto close = std::async(std::launch::async, [&adapter]() {
        return adapter.Close();
    });
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(2);
    while (adapter.IsReady() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    CHECK(!adapter.IsReady());
    {
        std::lock_guard<std::mutex> lock(host.nextBarrierMutex);
        host.allowNextReturn = true;
    }
    host.nextBarrierCondition.notify_all();

    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    const GlfwPumpResult result = pump.get();
    CHECK(result.status == GlfwAdapterStatus::kHostError);
    CHECK(result.recoveryHostStatus == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
    CHECK(host.releaseCalls == 1);
    CHECK(!adapter.HasConsumer());
}

struct AdapterCommitBarrier {
    std::mutex mutex;
    std::condition_variable condition;
    bool reached = false;
    bool proceed = false;

    static void Hook(void* context, GlfwInputAdapterTestSeam seam) {
        if (seam !=
            GlfwInputAdapterTestSeam::kAfterCommitBeforeDispatch) {
            return;
        }
        auto& self = *static_cast<AdapterCommitBarrier*>(context);
        std::unique_lock<std::mutex> lock(self.mutex);
        self.reached = true;
        self.condition.notify_all();
        self.condition.wait(lock, [&self]() { return self.proceed; });
    }
};

void TestCommittedKeyRollsBackWhenCloseWinsDispatchFence() {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(19u, 40u, AMCL_INPUT_ACTION_DOWN));
    AdapterCommitBarrier barrier;
    GlfwInputAdapterSetTestHook(AdapterCommitBarrier::Hook, &barrier);

    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        CHECK(barrier.condition.wait_for(
            lock, std::chrono::seconds(2), [&barrier]() {
                return barrier.reached;
            }));
    }
    auto close = std::async(std::launch::async, [&adapter]() {
        return adapter.Close();
    });
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.proceed = true;
    }
    barrier.condition.notify_all();
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    GlfwInputAdapterSetTestHook(nullptr, nullptr);
    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(recorder.keys.empty());
    CHECK(!adapter.IsKeyPressed(1040));
    CHECK(!adapter.HasConsumer());
    CHECK(adapter.DiscardedFetchedEventCount() == 1u);

    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    CHECK(adapter.Close() == GlfwAdapterStatus::kOk);
}

void RunCommittedClearEventRollbackCase(uint32_t eventType) {
    FakeHost host;
    Recorder recorder;
    GlfwInputAdapter adapter;
    recorder.adapter = &adapter;
    CHECK(adapter.Open(&host.api, Mapper(), recorder.Sink()) ==
          GlfwAdapterStatus::kOk);
    host.Push(Key(19u, 40u, AMCL_INPUT_ACTION_DOWN));
    CHECK(adapter.Pump().status == GlfwAdapterStatus::kOk);
    CHECK(recorder.keys.size() == 1u);
    CHECK(adapter.IsKeyPressed(1040));

    AmclInputEvent event = FakeHost::Event(
        eventType, eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED ? 19u : 0u);
    if (eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED) {
        event.payload.focus.focused = 0u;
    } else if (eventType == AMCL_INPUT_EVENT_RESET) {
        event.payload.reset.reason = AMCL_INPUT_RESET_QUEUE_OVERFLOW;
        event.payload.reset.closingEpoch = host.sessionEpoch;
    } else {
        CHECK(eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED);
        event.payload.device.change = AMCL_INPUT_DEVICE_REMOVED;
        event.payload.device.capabilities = AMCL_INPUT_DEVICE_CAP_KEYBOARD;
    }
    host.Push(event);

    AdapterCommitBarrier barrier;
    GlfwInputAdapterSetTestHook(AdapterCommitBarrier::Hook, &barrier);
    auto pump = std::async(std::launch::async, [&adapter]() {
        return adapter.Pump();
    });
    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        CHECK(barrier.condition.wait_for(
            lock, std::chrono::seconds(2), [&barrier]() {
                return barrier.reached;
            }));
    }
    auto close = std::async(std::launch::async, [&adapter]() {
        return adapter.Close();
    });
    CHECK(close.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    CHECK(close.get() == GlfwAdapterStatus::kOk);
    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.proceed = true;
    }
    barrier.condition.notify_all();
    CHECK(pump.wait_for(std::chrono::seconds(2)) ==
          std::future_status::ready);
    const GlfwPumpResult result = pump.get();
    GlfwInputAdapterSetTestHook(nullptr, nullptr);

    CHECK(result.status == GlfwAdapterStatus::kNotReady);
    CHECK(result.eventsDiscarded == 1u);
    CHECK(recorder.keys.size() == 2u);
    CHECK(recorder.keys.front().action == GlfwInputAction::kPress);
    CHECK(recorder.keys.back().action == GlfwInputAction::kRelease);
    CHECK(!adapter.IsKeyPressed(1040));
    CHECK(!adapter.HasConsumer());
}

void TestCommittedClearsRollBackWhenCloseWinsDispatchFence() {
    RunCommittedClearEventRollbackCase(AMCL_INPUT_EVENT_FOCUS_CHANGED);
    RunCommittedClearEventRollbackCase(AMCL_INPUT_EVENT_RESET);
    RunCommittedClearEventRollbackCase(AMCL_INPUT_EVENT_DEVICE_CHANGED);
}

}  // namespace

int main() {
    TestBaselineAndStrictTable();
    TestTextOnlyCompatibilityConsumer();
    TestRepeatAndPolling();
    TestTwoDevicesOneMappedKey();
    TestButtonAggregation();
    TestSdlPointerEdgesStayPerDeviceAndRemovalFollowsRelease();
    TestUnsupportedMappingsAreDiagnosed();
    TestResetAndFocusRelease();
    TestStaleAndOverflowRelease();
    TestEventSinkShapes();
    TestSurfaceContextStartupAllowlistAndSink();
    TestSnapshotSeedsLostFocusAndActiveCapture();
    TestNonGlfwBackendSeedsFocusedBaseline();
    TestNonGlfwBackendAbandonUsesClaimedSlot();
    TestTypedAbsoluteSurfaceBindingAndButtonOrder();
    TestNonFinitePayloadsFailClosedBeforeSinks();
    TestTextReleaseAndFailClosed();
    TestCloseReleasesBlobAndCompletesDrainRequired();
    TestFailedAbandonRetainsHandleAndOpenRetriesCleanup();
    TestCloseIdempotentAndUnconditional();
    TestMapperCanSynchronouslyCloseAndReopen();
    TestSinkCanSynchronouslyCloseAndReopen();
    TestSynchronousCloseFinishesMultiReleaseTransaction();
    TestSynchronousCloseFinishesOverflowMultiRelease();
    TestTerminalCloseBatchRejectsReentryUntilBalanced();
    TestTerminalAbandonBatchRejectsReentryUntilBalanced();
    TestConcurrentCloseWaitsForMapperCallback();
    TestConcurrentCloseWaitsForOverflowReleaseCallback();
    TestCloseOwnsRegisteredBlobWhenItWinsReleaseLease();
    TestPumpOwnsRegisteredBlobUntilReleaseReturns();
    TestFetchedBlobIsReleasedWhenCloseWinsRegistrationFence();
    TestFetchedBlobReleaseFailureIsReportedWhenCloseWinsFence();
    TestCommittedKeyRollsBackWhenCloseWinsDispatchFence();
    TestCommittedClearsRollBackWhenCloseWinsDispatchFence();
    std::cout << "glfw_input_adapter_test: PASS\n";
    return 0;
}

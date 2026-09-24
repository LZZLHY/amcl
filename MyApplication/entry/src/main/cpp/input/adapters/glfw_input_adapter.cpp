#include "glfw_input_adapter.h"
#include "../text_utf8_codec.h"

#include <climits>
#include <cmath>
#include <condition_variable>
#include <map>
#include <mutex>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace amcl::input {
namespace {

constexpr uint32_t kRequiredCapabilities =
    AMCL_INPUT_CAP_TYPED_EVENTS | AMCL_INPUT_CAP_MULTI_CONSUMER |
    AMCL_INPUT_CAP_OVERFLOW_RESET | AMCL_INPUT_CAP_OWNED_TEXT_PACKETS |
    AMCL_INPUT_CAP_SESSION_EPOCHS | AMCL_INPUT_CAP_HOST_GENERATION |
    AMCL_INPUT_CAP_EXPECTED_EPOCHS | AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS |
    AMCL_INPUT_CAP_CONSUMER_BASELINE |
    AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY |
    AMCL_INPUT_CAP_DIAGNOSTIC_DROP |
    AMCL_INPUT_CAP_BACKEND_CONSUMER_READY;

bool IsCompleteApi(const AmclInputHostApiV1* api,
                   bool requiresPhysicalRoute,
                   bool requiresTextSession) {
    // Partial-table fallback would create a consumer that cannot reclaim text
    // packets or recover an epoch. Reject the whole descriptor instead. The
    // physical-route and text-session capability bits are checked separately
    // below so a text-only compatibility consumer can remain valid when the
    // physical route is intentionally legacy.
    return api && api->magic == AMCL_INPUT_HOST_API_MAGIC &&
           api->abiVersion == AMCL_INPUT_HOST_API_VERSION &&
           api->structSize >= sizeof(AmclInputHostApiV1) &&
           api->generation == AMCL_INPUT_HOST_API_GENERATION &&
           (api->capabilityBits & kRequiredCapabilities) ==
               kRequiredCapabilities &&
           (!requiresPhysicalRoute ||
            (api->capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u) &&
           (!requiresTextSession ||
            (api->capabilityBits & AMCL_INPUT_CAP_TEXT_INPUT_SESSION) != 0u) &&
           api->beginSession && api->endSession && api->submitEvent &&
           api->submitBatch && api->submitTextPacket && api->publishSurface &&
           api->publishFocus && api->publishDeviceChange && api->requestReset &&
           api->openConsumer && api->nextEvent && api->readPacketBlob &&
           api->releasePacket && api->closeConsumer && api->getSnapshot;
}

bool IsBlobText(uint32_t type) {
    return type == AMCL_INPUT_EVENT_TEXT_COMMIT ||
           type == AMCL_INPUT_EVENT_TEXT_EDITING ||
           type == AMCL_INPUT_EVENT_TEXT_CANDIDATES;
}

uint64_t TextPacketId(const AmclInputEvent& event) {
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) {
        return event.payload.textCommit.utf8Blob.packetId;
    }
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
        return event.payload.textEditing.utf8Blob.packetId;
    }
    return event.payload.textCandidates.itemsBlob.packetId;
}

const AmclInputBlobRef& TextBlob(const AmclInputEvent& event) {
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) {
        return event.payload.textCommit.utf8Blob;
    }
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
        return event.payload.textEditing.utf8Blob;
    }
    return event.payload.textCandidates.itemsBlob;
}

enum class TextBlobCopyStatus : uint8_t {
    kOk = 0u,
    kCancelled,
    kMalformed,
    kHostError,
};

struct TextBlobCopyResult {
    TextBlobCopyStatus status = TextBlobCopyStatus::kHostError;
    int32_t hostStatus = AMCL_INPUT_ERROR_NOT_FOUND;
    std::vector<uint8_t> bytes;
};

// Caller holds hostCallMutex. The host packet is released exactly once on every
// path where packetId is non-zero, including malformed foreign-host metadata.
TextBlobCopyResult CopyAndReleaseTextBlob(
        const AmclInputHostApiV1* api, AmclInputConsumerHandle consumer,
        const AmclInputEvent& event) {
    TextBlobCopyResult out;
    const AmclInputBlobRef& blob = TextBlob(event);
    const size_t maximum =
        event.header.eventType == AMCL_INPUT_EVENT_TEXT_CANDIDATES
            ? kTextCandidateMaxBlobBytes : kTextCandidateMaxUtf8Bytes;
    const bool malformedRef = blob.packetId == 0u || blob.offset != 0u ||
        static_cast<size_t>(blob.length) > maximum;
    uint32_t byteCount = 0u;
    int32_t readStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if (!malformedRef) {
        readStatus = api->readPacketBlob(
            consumer, &blob, nullptr, 0u, &byteCount);
        const int32_t expected = blob.length == 0u
            ? AMCL_INPUT_OK : AMCL_INPUT_ERROR_BUFFER_TOO_SMALL;
        if (readStatus == expected && byteCount == blob.length) {
            out.bytes.resize(byteCount);
            if (byteCount != 0u) {
                readStatus = api->readPacketBlob(
                    consumer, &blob, out.bytes.data(), byteCount,
                    &byteCount);
            }
            if (readStatus == AMCL_INPUT_OK && byteCount == blob.length) {
                out.status = TextBlobCopyStatus::kOk;
            } else if (readStatus == AMCL_INPUT_ERROR_NOT_FOUND) {
                out.status = TextBlobCopyStatus::kCancelled;
            } else {
                out.status = TextBlobCopyStatus::kHostError;
                out.hostStatus = readStatus;
            }
        } else if (readStatus == AMCL_INPUT_ERROR_NOT_FOUND) {
            out.status = TextBlobCopyStatus::kCancelled;
        } else {
            out.status = TextBlobCopyStatus::kHostError;
            out.hostStatus = readStatus;
        }
    } else {
        out.status = TextBlobCopyStatus::kMalformed;
        out.hostStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }

    if (blob.packetId != 0u) {
        const int32_t releaseStatus =
            api->releasePacket(consumer, blob.packetId);
        if (releaseStatus != AMCL_INPUT_OK &&
            releaseStatus != AMCL_INPUT_ERROR_NOT_FOUND) {
            out.status = TextBlobCopyStatus::kHostError;
            out.hostStatus = releaseStatus;
        }
    }
    return out;
}
using Emission = std::variant<GlfwKeySinkEvent, GlfwButtonSinkEvent,
                               GlfwAbsoluteSinkEvent, GlfwRelativeSinkEvent,
                               GlfwWheelSinkEvent, GlfwFocusSinkEvent,
                               GlfwEnterSinkEvent, GlfwCaptureSinkEvent,
                               GlfwSurfaceSinkEvent,
                               GlfwSurfaceContextSinkEvent,
                               GlfwDeviceSinkEvent,
                               GlfwResetSinkEvent,
                               GlfwTextSessionSinkEvent,
                               GlfwTextCommitSinkEvent,
                               GlfwTextEditingSinkEvent,
                               GlfwTextCandidatesSinkEvent,
                               GlfwTextSelectionSinkEvent,
                                GlfwUnsupportedMappingSinkEvent,
                                GlfwDiagnosticDropSinkEvent>;

void DispatchOne(const GlfwInputSink& sink, const Emission& emission) {
    std::visit([&sink](const auto& value) {
            using T = std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<T, GlfwKeySinkEvent>) {
                if (sink.key) sink.key(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwButtonSinkEvent>) {
                if (sink.button) sink.button(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwAbsoluteSinkEvent>) {
                if (sink.absolute) sink.absolute(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwRelativeSinkEvent>) {
                if (sink.relative) sink.relative(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwWheelSinkEvent>) {
                if (sink.wheel) sink.wheel(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwFocusSinkEvent>) {
                if (sink.focus) sink.focus(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwEnterSinkEvent>) {
                if (sink.enter) sink.enter(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwCaptureSinkEvent>) {
                if (sink.capture) sink.capture(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwSurfaceSinkEvent>) {
                if (sink.surface) sink.surface(sink.context, value);
            } else if constexpr (
                    std::is_same_v<T, GlfwSurfaceContextSinkEvent>) {
                if (sink.surfaceContext) {
                    sink.surfaceContext(sink.context, value);
                }
            } else if constexpr (std::is_same_v<T, GlfwDeviceSinkEvent>) {
                if (sink.device) sink.device(sink.context, value);
            } else if constexpr (std::is_same_v<T, GlfwResetSinkEvent>) {
                if (sink.reset) sink.reset(sink.context, value);
            } else if constexpr (
                    std::is_same_v<T, GlfwTextSessionSinkEvent>) {
                if (sink.textSession) sink.textSession(sink.context, value);
            } else if constexpr (
                    std::is_same_v<T, GlfwTextCommitSinkEvent>) {
                if (sink.textCommit) sink.textCommit(sink.context, value);
            } else if constexpr (
                    std::is_same_v<T, GlfwTextEditingSinkEvent>) {
                if (sink.textEditing) sink.textEditing(sink.context, value);
            } else if constexpr (
                    std::is_same_v<T, GlfwTextCandidatesSinkEvent>) {
                if (sink.textCandidates) {
                    sink.textCandidates(sink.context, value);
                }
            } else if constexpr (
                    std::is_same_v<T, GlfwTextSelectionSinkEvent>) {
                if (sink.textSelection) {
                    sink.textSelection(sink.context, value);
                }
            } else if constexpr (
                    std::is_same_v<T, GlfwUnsupportedMappingSinkEvent>) {
                if (sink.unsupportedMapping) {
                    sink.unsupportedMapping(sink.context, value);
                }
            } else if constexpr (
                    std::is_same_v<T, GlfwDiagnosticDropSinkEvent>) {
                if (sink.diagnosticDrop) {
                    sink.diagnosticDrop(sink.context, value);
                }
            }
        }, emission);
}

void Dispatch(const GlfwInputSink& sink,
              const std::vector<Emission>& emissions) {
    for (const Emission& emission : emissions) DispatchOne(sink, emission);
}

// Does processing this event clear held aggregates, i.e. can its emissions
// contain RELEASE edges for controls that were held **before** it?
//
// That question decides `InFlight::restoreDuringDispatch`, and therefore whether
// an interrupted dispatch has to restore the pre-event aggregates so the
// teardown backstop can still emit the remaining releases. (`Close`'s
// `finishClosed` is that backstop: it emits whatever is *still* in the
// aggregates. Clearing them without a restorable checkpoint is exactly what
// defeats it, which is why this predicate is load-bearing rather than cosmetic.)
//
// The answer is exhaustively enumerable, and that is the only reason a predicate
// is safe here: `ProcessEventLocked` clears held aggregates in exactly three
// places -- `ClearAggregatesLocked` for FOCUS_CHANGED with focused == 0 and for
// RESET, and `ClearDeviceLocked` for DEVICE_CHANGED with REMOVED. There is no
// fourth. ⚠️ If you add a clearing path to `ProcessEventLocked`, it must be added
// here in the same change; nothing enforces that mechanically.
//
// ⚠️ 2026-08-21: this used to be written out **twice**, token-for-token
// identical, in `Pump` and in `Close`'s drain loop, with no declaration on
// either side that they were mirrors. They had not drifted -- but the duplication
// hid something worse than drift: `Close`'s drain has a *third* site that clears
// the same aggregates (its OVERFLOW_RESET branch) and that one builds no
// checkpoint at all. Two identical copies read as "this is handled everywhere",
// which is precisely how a missing third copy stays invisible. Spec §4.0:
// prefer eliminating a mirror over documenting it.
bool ClearsHeldControlsDuringDispatch(const AmclInputEvent& event) {
    return event.header.eventType == AMCL_INPUT_EVENT_RESET ||
        (event.header.eventType == AMCL_INPUT_EVENT_FOCUS_CHANGED &&
         event.payload.focus.focused == 0u) ||
        (event.header.eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED &&
         event.payload.device.change == AMCL_INPUT_DEVICE_REMOVED);
}

struct Contributor {
    uint64_t deviceId;
    uint32_t raw;
    bool operator<(const Contributor& other) const {
        return deviceId < other.deviceId ||
               (deviceId == other.deviceId && raw < other.raw);
    }
};

struct KeyAggregate {
    int32_t scanCode = 0;
    // 与 `scanCode` 一起存：释放与重复边沿要报告**建立这个聚合的那次按下**用的编码空间，
    // 而不是 kNone —— 同一个物理键的三条边沿属于同一个来源。
    GlfwScanCodeSource scanCodeSource = GlfwScanCodeSource::kNone;
    size_t contributorCount = 0;
};

struct ButtonAggregate {
    size_t contributorCount = 0;
};

struct ButtonContributor {
    int32_t mapped = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
};

enum class MappingKind : uint32_t {
    kNone = 0u,
    kKey = 1u,
    kButton = 2u,
};

struct PreparedMapping {
    MappingKind kind = MappingKind::kNone;
    bool accepted = false;
    GlfwMappedKey key{};
    int32_t button = 0;
};

#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
GlfwInputAdapterTestHook gAdapterTestHook = nullptr;
void* gAdapterTestHookContext = nullptr;

void RunAdapterTestHook(GlfwInputAdapterTestSeam seam) {
    if (gAdapterTestHook) gAdapterTestHook(gAdapterTestHookContext, seam);
}
#endif

bool MapOhosKey(void*, uint64_t, uint32_t physicalKey,
                uint32_t hardwareScanCode, uint32_t hidUsage,
                GlfwMappedKey* outKey) {
    if (!outKey) return false;
    int32_t mapped = 0;

    // OHOS keycode ranges are verified against the SDK SSOT used by ArkTS.
    // The translation belongs here—not in Platform Ingress—so LWJGL2 and SDL3
    // can later map the same raw identity directly to their own ABIs.
    if (physicalKey >= 2017u && physicalKey <= 2042u) {
        mapped = 65 + static_cast<int32_t>(physicalKey - 2017u); // A..Z
    } else if (physicalKey >= 2000u && physicalKey <= 2009u) {
        mapped = 48 + static_cast<int32_t>(physicalKey - 2000u); // 0..9
    } else if (physicalKey >= 2090u && physicalKey <= 2101u) {
        mapped = 290 + static_cast<int32_t>(physicalKey - 2090u); // F1..F12
    } else if (physicalKey >= 2103u && physicalKey <= 2112u) {
        mapped = 320 + static_cast<int32_t>(physicalKey - 2103u); // KP 0..9
    } else {
        switch (physicalKey) {
            case 2012u: mapped = 265; break; // up
            case 2013u: mapped = 264; break; // down
            case 2014u: mapped = 263; break; // left
            case 2015u: mapped = 262; break; // right
            case 2016u: mapped = 257; break; // dpad center -> enter
            case 2043u: mapped = 44; break;
            case 2044u: mapped = 46; break;
            case 2045u: mapped = 342; break;
            case 2046u: mapped = 346; break;
            case 2047u: mapped = 340; break;
            case 2048u: mapped = 344; break;
            case 2049u: mapped = 258; break;
            case 2050u: mapped = 32; break;
            case 2054u: mapped = 257; break;
            case 2055u: mapped = 259; break;
            case 2056u: mapped = 96; break;
            case 2057u: mapped = 45; break;
            case 2058u: mapped = 61; break;
            case 2059u: mapped = 91; break;
            case 2060u: mapped = 93; break;
            case 2061u: mapped = 92; break;
            case 2062u: mapped = 59; break;
            case 2063u: mapped = 39; break;
            case 2064u: mapped = 47; break;
            case 2067u: mapped = 348; break;
            case 2068u: mapped = 266; break;
            case 2069u: mapped = 267; break;
            case 2070u: mapped = 256; break;
            case 2071u: mapped = 261; break;
            case 2072u: mapped = 341; break;
            case 2073u: mapped = 345; break;
            case 2074u: mapped = 280; break;
            case 2075u: mapped = 281; break;
            case 2076u: mapped = 343; break;
            case 2077u: mapped = 347; break;
            case 2079u: mapped = 283; break;
            case 2080u: mapped = 284; break;
            case 2081u: mapped = 268; break;
            case 2082u: mapped = 269; break;
            case 2083u: mapped = 260; break;
            case 2102u: mapped = 282; break;
            case 2113u: mapped = 331; break;
            case 2114u: mapped = 332; break;
            case 2115u: mapped = 333; break;
            case 2116u: mapped = 334; break;
            case 2117u: mapped = 330; break;
            case 2119u: mapped = 335; break;
            case 2120u: mapped = 336; break;
            default: return false;
        }
    }

    outKey->key = mapped;
    outKey->scanCode = ScanCodeFromOhosIdentity(
        physicalKey, hardwareScanCode, hidUsage, &outKey->scanCodeSource);
    return true;
}

bool MapOhosButton(void*, uint64_t, uint32_t nativeButton,
                   int32_t* outButton) {
    if (!outButton) return false;
    // OH_NativeXComponent button values are bit identities, unlike ArkUI's
    // sequential MouseButton enum. Unknown/combined masks stay diagnosable and
    // are never guessed as left click.
    switch (nativeButton) {
        case 1u: *outButton = 0; return true;
        case 2u: *outButton = 1; return true;
        case 4u: *outButton = 2; return true;
        case 8u: *outButton = 3; return true;
        case 16u: *outButton = 4; return true;
        default: return false;
    }
}

}  // namespace

GlfwInputMapper GlfwOhosInputMapper() {
    return {nullptr, MapOhosKey, MapOhosButton};
}

#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
void GlfwInputAdapterSetTestHook(GlfwInputAdapterTestHook hook,
                                 void* context) {
    gAdapterTestHook = hook;
    gAdapterTestHookContext = context;
}
#endif

struct GlfwInputAdapter::Impl {
    enum class Lifecycle : uint32_t {
        kClosed = 0u,
        kOpening,
        kReady,
        kRetiring,
        kAbandoning,
    };

    struct AbsoluteAuthorization {
        uint64_t sequence = 0u;
        uint64_t deviceId = 0u;
        uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
        uint64_t surfaceEpoch = 0u;
        bool valid = false;
    };

    struct InFlight {
        enum class Stage : uint32_t {
            kFetched = 0u,
            kCommitted,
            kDispatching,
        };
        bool active = false;
        uint64_t ticket = 0u;
        uint64_t incarnation = 0u;
        AmclInputEvent event{};
        bool ownsHostBlob = false;
        Stage stage = Stage::kFetched;
        bool hasAggregateRollback = false;
        bool restoreDuringDispatch = false;
        uint64_t previousLastSequence = 0u;
        std::map<Contributor, int32_t> previousKeyContributors;
        std::map<int32_t, KeyAggregate> previousKeys;
        std::map<Contributor, ButtonContributor> previousButtonContributors;
        std::map<int32_t, ButtonAggregate> previousButtons;
        bool previousHasSurfacePublication = false;
        AmclInputSurfacePayload previousSurfacePublication{};
        uint64_t previousSurfacePublicationEpoch = 0u;
        AbsoluteAuthorization previousAbsoluteAuthorization{};
        bool previousTextSessionActive = false;
        uint64_t previousTextSessionId = 0u;
    };

    // openMutex only serializes lifecycle entry. hostCallMutex serializes V1
    // calls for one borrowed consumer. Neither may be held across mapper/sink
    // callbacks. If hostCallMutex and stateMutex are briefly nested, the order
    // is always hostCallMutex -> stateMutex.
    mutable std::mutex openMutex;
    mutable std::mutex hostCallMutex;
    mutable std::mutex stateMutex;
    // Serializes every external mapper/sink callback with Close(). Recursive
    // acquisition is required because a callback may synchronously close the
    // adapter. No host/state/open mutex is held while invoking user code.
    mutable std::recursive_mutex callbackMutex;
    std::condition_variable callbackCondition;
    const AmclInputHostApiV1* api = nullptr;
    AmclInputConsumerHandle consumer = 0;
    GlfwInputMapper mapper{};
    GlfwInputSink sink{};
    uint64_t sessionEpoch = 0;
    uint64_t lastSequence = 0;
    uint64_t incarnation = 0u;
    uint64_t callbackFence = 0u;
    uint64_t nextFetchTicket = 1u;
    uint64_t lastDiscardedTicket = 0u;
    uint64_t discardedFetchedEvents = 0u;
    uint64_t abandonCount = 0u;
    Lifecycle lifecycle = Lifecycle::kClosed;
    bool pumpActive = false;
    bool cleanupActive = false;
    bool suppressCleanupCallbacks = false;
    bool backendRegistered = false;
    GlfwOpenRejectSite lastOpenRejectSite = GlfwOpenRejectSite::kNone;
    int32_t lastOpenRejectDetail = 0;
    bool callbackActive = false;
    std::thread::id callbackThread{};
    bool terminalCallbackBatchActive = false;
    std::thread::id terminalCallbackThread{};
    InFlight inFlight{};
    bool absoluteRouteEnabled = false;
    bool hasSurfacePublication = false;
    AmclInputSurfacePayload surfacePublication{};
    uint64_t surfacePublicationEpoch = 0u;
    AbsoluteAuthorization absoluteAuthorization{};
    uint64_t absoluteRouteDrops = 0u;
    bool textSessionActive = false;
    uint64_t textSessionId = 0u;
    std::vector<Emission> deferredStartupEmissions;
    // 本实例代表哪个后端。整个类是**后端参数化**的：mapper 决定 raw identity 翻成哪套
    // 编码，backend 决定它在 core 里占哪个 READY/RETIRE 槽。默认 GLFW3 让既有调用点
    // 与全部 host 测试不受影响（它们本来就是 GLFW3 那一个）。
    uint32_t backend = AMCL_INPUT_BACKEND_GLFW_PHYSICAL;

    // The adapter, not GLFW runtime globals, owns these aggregate polling
    // ledgers. This lets the typed and legacy paths coexist behind a session
    // switch without both mutating the same state during Phase 3.1.
    std::map<Contributor, int32_t> keyContributors;
    std::map<int32_t, KeyAggregate> keys;
    std::map<Contributor, ButtonContributor> buttonContributors;
    std::map<int32_t, ButtonAggregate> buttons;

    void ClearAbsoluteRouteLocked() {
        hasSurfacePublication = false;
        surfacePublication = {};
        surfacePublicationEpoch = 0u;
        absoluteAuthorization = {};
    }

    void DropAbsoluteRouteLocked() {
        absoluteAuthorization = {};
        if (absoluteRouteDrops != UINT64_MAX) ++absoluteRouteDrops;
    }

    bool HasUsableSurfacePublicationLocked() const {
        constexpr uint32_t kRequired =
            AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
            AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
        return hasSurfacePublication && surfacePublicationEpoch != 0u &&
            surfacePublication.active != 0u &&
            (surfacePublication.validFields & kRequired) == kRequired &&
            surfacePublication.widthPx != 0u &&
            surfacePublication.heightPx != 0u &&
            surfacePublication.publicationGeneration != 0u;
    }

    void RecordUnsupportedKeyLocked(const AmclInputEvent& event,
                                    std::vector<Emission>& emissions) const {
        // This is queued under stateMutex with the event being processed, then
        // dispatched only after that mutex and the host's nextEvent lock are
        // gone. A rejected mapping therefore stays ordered and observable
        // without acquiring a contributor or risking callback reentrancy.
        emissions.emplace_back(GlfwUnsupportedMappingSinkEvent{
            GlfwUnsupportedMappingKind::kKey,
            event.payload.physicalKey.physicalKey,
            event.payload.physicalKey.action,
            event.header.deviceId,
            event.payload.physicalKey.hardwareScanCode,
            event.payload.physicalKey.hidUsage,
            event.header.sequence});
    }

    void RecordUnsupportedButtonLocked(
            const AmclInputEvent& event,
            std::vector<Emission>& emissions) const {
        emissions.emplace_back(GlfwUnsupportedMappingSinkEvent{
            GlfwUnsupportedMappingKind::kButton,
            event.payload.pointerButton.nativeButton,
            event.payload.pointerButton.action,
            event.header.deviceId,
            0u,
            0u,
            event.header.sequence});
    }

    void RecordDroppedEdgeLocked(const AmclInputEvent& event,
                                 uint32_t reason,
                                 std::vector<Emission>& emissions) const {
        const bool key =
            event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY;
        emissions.emplace_back(GlfwDiagnosticDropSinkEvent{
            reason,
            event.header.eventType,
            key ? event.payload.physicalKey.physicalKey
                : event.payload.pointerButton.nativeButton,
            key ? event.payload.physicalKey.action
                : event.payload.pointerButton.action,
            key ? event.payload.physicalKey.hardwareScanCode : 0u,
            key ? event.payload.physicalKey.hidUsage : 0u,
            event.header.deviceId,
            event.header.sequence});
    }

    void RecordCoreDropLocked(const AmclInputEvent& event,
                              std::vector<Emission>& emissions) const {
        const AmclInputDiagnosticDropPayload& drop =
            event.payload.diagnosticDrop;
        emissions.emplace_back(GlfwDiagnosticDropSinkEvent{
            drop.reason,
            drop.originalEventType,
            drop.rawControl,
            drop.action,
            drop.hardwareScanCode,
            drop.hidUsage,
            event.header.deviceId,
            event.header.sequence});
    }

    // `monotonicTimeNs` 没有默认值是刻意的：合成的 fail-safe 释放该用 0（没有平台事件），
    // 由真实事件触发的清理该透传那个事件的时间戳，而这两者不能靠"忘了传"来区分。
    void ClearAggregatesLocked(uint64_t sequence, uint64_t monotonicTimeNs,
                               std::vector<Emission>& emissions) {
        // std::map order makes reset/stale/overflow releases reproducible,
        // which is important when several physical controls collapse to one
        // mapped GLFW control.
        for (const auto& entry : keys) {
            emissions.emplace_back(GlfwKeySinkEvent{
                entry.first, entry.second.scanCode,
                GlfwInputAction::kRelease, 0u, 0u, 0u, sequence,
                monotonicTimeNs});
        }
        if (backend == AMCL_INPUT_BACKEND_SDL3_PHYSICAL) {
            // SDL owns per-device mouse state. Release every contributor with
            // the identity that acquired it; one aggregate release on the
            // default mouse would strand the other SDL_MouseID sources.
            for (const auto& entry : buttonContributors) {
                emissions.emplace_back(GlfwButtonSinkEvent{
                    entry.second.mapped, GlfwInputAction::kRelease, 0u,
                    entry.first.deviceId, sequence, surfacePublicationEpoch,
                    false, monotonicTimeNs, entry.second.deviceClass});
            }
        } else {
            for (const auto& entry : buttons) {
                emissions.emplace_back(GlfwButtonSinkEvent{
                    entry.first, GlfwInputAction::kRelease, 0u, 0u,
                    sequence, surfacePublicationEpoch, false, monotonicTimeNs,
                    AMCL_INPUT_DEVICE_CLASS_UNKNOWN});
            }
        }
        keyContributors.clear();
        keys.clear();
        buttonContributors.clear();
        buttons.clear();
    }

    void ClearDeviceLocked(uint64_t deviceId, uint32_t deviceClass,
                           uint64_t sequence,
                           uint64_t monotonicTimeNs,
                           std::vector<Emission>& emissions) {
        for (auto it = keyContributors.begin(); it != keyContributors.end();) {
            if (it->first.deviceId != deviceId) {
                ++it;
                continue;
            }
            const int32_t mapped = it->second;
            it = keyContributors.erase(it);
            auto aggregate = keys.find(mapped);
            if (aggregate != keys.end() && --aggregate->second.contributorCount == 0u) {
                emissions.emplace_back(GlfwKeySinkEvent{
                    mapped, aggregate->second.scanCode,
                    GlfwInputAction::kRelease, 0u, 0u, deviceId, sequence,
                    monotonicTimeNs});
                keys.erase(aggregate);
            }
        }
        for (auto it = buttonContributors.begin();
             it != buttonContributors.end();) {
            if (it->first.deviceId != deviceId) {
                ++it;
                continue;
            }
            const ButtonContributor owner = it->second;
            const int32_t mapped = owner.mapped;
            it = buttonContributors.erase(it);
            auto aggregate = buttons.find(mapped);
            if (aggregate == buttons.end() ||
                aggregate->second.contributorCount == 0u) {
                continue;
            }
            const bool finalAggregate =
                --aggregate->second.contributorCount == 0u;
            if (backend == AMCL_INPUT_BACKEND_SDL3_PHYSICAL ||
                finalAggregate) {
                emissions.emplace_back(GlfwButtonSinkEvent{
                    mapped, GlfwInputAction::kRelease, 0u, deviceId,
                    sequence, surfacePublicationEpoch, false, monotonicTimeNs,
                    owner.deviceClass != AMCL_INPUT_DEVICE_CLASS_UNKNOWN
                        ? owner.deviceClass : deviceClass});
            }
            if (finalAggregate) {
                buttons.erase(aggregate);
            }
        }
    }

    // Snapshot everything `DiscardInFlightLocked` is able to restore, for the
    // in-flight record the caller has just registered.
    //
    // Preconditions (caller-enforced, not asserted here): `stateMutex` is held,
    // and `inFlight.active` / `ticket` / `incarnation` / `event` are already set.
    // This runs **before** `ProcessEventLocked`, because that call is what
    // mutates the state being snapshotted.
    //
    // ⚠️ 2026-08-21: these assignments used to be written out twice --
    // token-for-token identical -- in `Pump` and in `Close`'s drain loop.
    // See `ClearsHeldControlsDuringDispatch` above for why the duplication was
    // worse than it looked.
    //
    // Deliberately NOT used by the OVERFLOW_RESET checkpoint in `Pump`: that one
    // registers a **blank** event (there is no host record behind an overflow
    // notification), so the predicate would answer "does not clear held
    // controls" for a transition that clears all of them. It therefore sets
    // `restoreDuringDispatch = true` unconditionally, which is correct and must
    // stay hand-written. It also snapshots only the four ledger maps, not the
    // surface/authorization fields -- see the comment at that site.
    void BeginRollbackCheckpointLocked(const AmclInputEvent& event) {
        InFlight& flight = inFlight;
        flight.previousLastSequence = lastSequence;
        flight.hasAggregateRollback = true;
        flight.restoreDuringDispatch =
            ClearsHeldControlsDuringDispatch(event);
        flight.previousKeyContributors = keyContributors;
        flight.previousKeys = keys;
        flight.previousButtonContributors = buttonContributors;
        flight.previousButtons = buttons;
        flight.previousHasSurfacePublication = hasSurfacePublication;
        flight.previousSurfacePublication = surfacePublication;
        flight.previousSurfacePublicationEpoch = surfacePublicationEpoch;
        flight.previousAbsoluteAuthorization = absoluteAuthorization;
        flight.previousTextSessionActive = textSessionActive;
        flight.previousTextSessionId = textSessionId;
    }

    // True when a discard of the current in-flight record must go through
    // `DiscardInFlightLocked` (which counts it and applies the checkpoint),
    // false when the record may simply be dropped with `inFlight = {}`.
    //
    // A record already in `kDispatching` without `restoreDuringDispatch` has had
    // its emissions delivered to the sink and its aggregate mutation is the
    // current truth -- restoring a checkpoint over it would resurrect state the
    // backend has already been told to forget, and counting it as discarded
    // would overstate `eventsDiscarded`.
    //
    // ⚠️ This one predicate was spelled three different ways (once affirmative,
    // twice as complements of each other) in three places. They were equivalent,
    // but "equivalent after you work out the double negative" is not a property
    // anyone should have to re-derive at a teardown fence.
    bool InFlightNeedsAccountedDiscardLocked() const {
        return inFlight.stage != InFlight::Stage::kDispatching ||
            inFlight.restoreDuringDispatch;
    }

    void DiscardInFlightLocked() {
        if (!inFlight.active) return;
        const bool restoreCommitted =
            inFlight.stage == InFlight::Stage::kCommitted;
        const bool restorePartialDispatch =
            inFlight.stage == InFlight::Stage::kDispatching &&
            inFlight.restoreDuringDispatch;
        if ((restoreCommitted || restorePartialDispatch) &&
            inFlight.hasAggregateRollback) {
            lastSequence = inFlight.previousLastSequence;
            keyContributors = std::move(inFlight.previousKeyContributors);
            keys = std::move(inFlight.previousKeys);
            buttonContributors =
                std::move(inFlight.previousButtonContributors);
            buttons = std::move(inFlight.previousButtons);
            hasSurfacePublication =
                inFlight.previousHasSurfacePublication;
            surfacePublication = inFlight.previousSurfacePublication;
            surfacePublicationEpoch =
                inFlight.previousSurfacePublicationEpoch;
            absoluteAuthorization =
                inFlight.previousAbsoluteAuthorization;
            textSessionActive = inFlight.previousTextSessionActive;
            textSessionId = inFlight.previousTextSessionId;
        }
        lastDiscardedTicket = inFlight.ticket;
        ++discardedFetchedEvents;
        inFlight = {};
    }

    void MarkEmissionDeliveredForRollbackLocked(const Emission& emission) {
        if (!inFlight.active || !inFlight.restoreDuringDispatch) return;
        if (const auto* key = std::get_if<GlfwKeySinkEvent>(&emission);
            key && key->action == GlfwInputAction::kRelease) {
            for (auto it = inFlight.previousKeyContributors.begin();
                 it != inFlight.previousKeyContributors.end();) {
                if (it->second == key->key) {
                    it = inFlight.previousKeyContributors.erase(it);
                } else {
                    ++it;
                }
            }
            inFlight.previousKeys.erase(key->key);
        } else if (const auto* button =
                       std::get_if<GlfwButtonSinkEvent>(&emission);
                   button && button->action == GlfwInputAction::kRelease) {
            if (backend == AMCL_INPUT_BACKEND_SDL3_PHYSICAL &&
                button->deviceId != 0u) {
                for (auto it = inFlight.previousButtonContributors.begin();
                     it != inFlight.previousButtonContributors.end(); ++it) {
                    if (it->first.deviceId == button->deviceId &&
                        it->second.mapped == button->button) {
                        inFlight.previousButtonContributors.erase(it);
                        auto aggregate =
                            inFlight.previousButtons.find(button->button);
                        if (aggregate != inFlight.previousButtons.end() &&
                            aggregate->second.contributorCount != 0u &&
                            --aggregate->second.contributorCount == 0u) {
                            inFlight.previousButtons.erase(aggregate);
                        }
                        break;
                    }
                }
            } else {
                for (auto it = inFlight.previousButtonContributors.begin();
                     it != inFlight.previousButtonContributors.end();) {
                    if (it->second.mapped == button->button) {
                        it = inFlight.previousButtonContributors.erase(it);
                    } else {
                        ++it;
                    }
                }
                inFlight.previousButtons.erase(button->button);
            }
        }
    }

    void DispatchTerminalCallbacks(const GlfwInputSink& targetSink,
                                   const std::vector<Emission>& emissions) {
        {
            std::lock_guard<std::mutex> state(stateMutex);
            terminalCallbackBatchActive = true;
            terminalCallbackThread = std::this_thread::get_id();
        }
        Dispatch(targetSink, emissions);
        {
            std::lock_guard<std::mutex> state(stateMutex);
            if (terminalCallbackBatchActive &&
                terminalCallbackThread == std::this_thread::get_id()) {
                terminalCallbackBatchActive = false;
                terminalCallbackThread = {};
            }
        }
        callbackCondition.notify_all();
    }

    MappingKind MappingRequiredLocked(const AmclInputEvent& event) const;
    GlfwAdapterStatus ProcessEventLocked(const AmclInputEvent& event,
                                         const PreparedMapping& mapping,
                                         std::vector<Emission>& emissions,
                                         const std::vector<uint8_t>* textBytes =
                                             nullptr);
    int32_t AbandonIncarnation(uint64_t expectedIncarnation,
                               uint32_t* discardedByCall,
                               std::vector<Emission>* releases,
                               GlfwInputSink* releaseSink);
};

MappingKind GlfwInputAdapter::Impl::MappingRequiredLocked(
        const AmclInputEvent& event) const {
    if (event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY) {
        const Contributor contributor{event.header.deviceId,
                                      event.payload.physicalKey.physicalKey};
        const bool owned = keyContributors.find(contributor) !=
                           keyContributors.end();
        if ((event.payload.physicalKey.action == AMCL_INPUT_ACTION_UP &&
             !owned) ||
            (event.payload.physicalKey.action == AMCL_INPUT_ACTION_REPEAT &&
             !owned) ||
            (event.payload.physicalKey.action == AMCL_INPUT_ACTION_DOWN &&
             !owned)) {
            return MappingKind::kKey;
        }
    } else if (event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON) {
        const Contributor contributor{event.header.deviceId,
                                      event.payload.pointerButton.nativeButton};
        const bool owned = buttonContributors.find(contributor) !=
                           buttonContributors.end();
        if ((event.payload.pointerButton.action == AMCL_INPUT_ACTION_UP &&
             !owned) ||
            (event.payload.pointerButton.action == AMCL_INPUT_ACTION_DOWN &&
             !owned)) {
            return MappingKind::kButton;
        }
    }

    return MappingKind::kNone;
}

GlfwAdapterStatus GlfwInputAdapter::Impl::ProcessEventLocked(
        const AmclInputEvent& event, const PreparedMapping& mapping,
        std::vector<Emission>& emissions,
        const std::vector<uint8_t>* textBytes) {
    if (event.header.abiVersion != AMCL_INPUT_EVENT_ABI_VERSION ||
        event.header.structSize < sizeof(AmclInputEvent) ||
        event.header.sequence == 0u || event.header.sequence <= lastSequence) {
        return GlfwAdapterStatus::kMalformedEvent;
    }
    constexpr uint32_t kKnownEventFlags =
        AMCL_INPUT_EVENT_FLAG_SYNTHETIC |
        AMCL_INPUT_EVENT_FLAG_PRECISE |
        AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND |
        AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW |
        AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
    const bool pointerSample =
        event.header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE ||
        event.header.eventType == AMCL_INPUT_EVENT_POINTER_RELATIVE ||
        event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON ||
        event.header.eventType == AMCL_INPUT_EVENT_POINTER_WHEEL;
    if ((event.header.flags & ~kKnownEventFlags) != 0u ||
        ((event.header.flags & AMCL_INPUT_EVENT_FLAG_PRECISE) != 0u &&
         event.header.eventType != AMCL_INPUT_EVENT_POINTER_WHEEL) ||
        ((event.header.flags &
          AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u &&
         event.header.eventType != AMCL_INPUT_EVENT_POINTER_BUTTON) ||
        ((event.header.flags & AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW) != 0u &&
         event.header.eventType != AMCL_INPUT_EVENT_POINTER_RELATIVE) ||
        ((event.header.flags &
          AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u &&
         (!pointerSample || event.header.monotonicTimeNs == 0u)) ||
        event.header.deviceClass >= AMCL_INPUT_DEVICE_CLASS_COUNT) {
        return GlfwAdapterStatus::kMalformedEvent;
    }
    const bool textEvent = IsBlobText(event.header.eventType) ||
        event.header.eventType == AMCL_INPUT_EVENT_TEXT_SELECTION ||
        event.header.eventType == AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
    if (textEvent &&
        (event.header.source != AMCL_INPUT_SOURCE_IME ||
         event.header.deviceId != 0u ||
         event.header.deviceClass != AMCL_INPUT_DEVICE_CLASS_UNKNOWN)) {
        return GlfwAdapterStatus::kMalformedEvent;
    }
    if (event.header.sessionEpoch != sessionEpoch) {
        return GlfwAdapterStatus::kStale;
    }
    lastSequence = event.header.sequence;
    if (absoluteRouteEnabled && absoluteAuthorization.valid &&
        event.header.eventType != AMCL_INPUT_EVENT_POINTER_ABSOLUTE &&
        event.header.eventType != AMCL_INPUT_EVENT_POINTER_BUTTON) {
        absoluteAuthorization = {};
    }

    switch (event.header.eventType) {
        case AMCL_INPUT_EVENT_PHYSICAL_KEY: {
            const uint32_t action = event.payload.physicalKey.action;
            if (action < AMCL_INPUT_ACTION_DOWN ||
                action > AMCL_INPUT_ACTION_UP) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            const Contributor contributor{event.header.deviceId,
                event.payload.physicalKey.physicalKey};
            auto owner = keyContributors.find(contributor);
            if (action == AMCL_INPUT_ACTION_UP) {
                if (owner == keyContributors.end()) {
                    RecordDroppedEdgeLocked(
                        event, AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
                        emissions);
                    if (mapping.kind != MappingKind::kKey ||
                        !mapping.accepted) {
                        RecordUnsupportedKeyLocked(event, emissions);
                    }
                    return GlfwAdapterStatus::kOk;
                }
                const int32_t mapped = owner->second;
                keyContributors.erase(owner);
                auto aggregate = keys.find(mapped);
                if (aggregate == keys.end() ||
                    aggregate->second.contributorCount == 0u) {
                    return GlfwAdapterStatus::kMalformedEvent;
                }
                if (--aggregate->second.contributorCount == 0u) {
                    emissions.emplace_back(GlfwKeySinkEvent{
                        mapped, aggregate->second.scanCode,
                        GlfwInputAction::kRelease,
                        event.payload.physicalKey.modifiersSnapshot,
                        event.payload.physicalKey.lockState,
                        event.header.deviceId, event.header.sequence,
                        event.header.monotonicTimeNs,
                        aggregate->second.scanCodeSource});
                    keys.erase(aggregate);
                }
                return GlfwAdapterStatus::kOk;
            }
            if (owner != keyContributors.end()) {
                const auto aggregate = keys.find(owner->second);
                if (aggregate == keys.end()) {
                    return GlfwAdapterStatus::kMalformedEvent;
                }
                emissions.emplace_back(GlfwKeySinkEvent{
                    owner->second, aggregate->second.scanCode,
                    GlfwInputAction::kRepeat,
                    event.payload.physicalKey.modifiersSnapshot,
                    event.payload.physicalKey.lockState,
                    event.header.deviceId, event.header.sequence,
                    event.header.monotonicTimeNs,
                    aggregate->second.scanCodeSource});
                return GlfwAdapterStatus::kOk;
            }
            if (action == AMCL_INPUT_ACTION_REPEAT) {
                // The host core normally replaces this edge with a diagnostic.
                // Keep the adapter independently fail-closed for a foreign or
                // newer host, and make that defensive drop observable too.
                RecordDroppedEdgeLocked(
                    event,
                    AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT,
                    emissions);
                if (mapping.kind != MappingKind::kKey ||
                    !mapping.accepted) {
                    RecordUnsupportedKeyLocked(event, emissions);
                }
                return GlfwAdapterStatus::kOk;
            }
            if (mapping.kind != MappingKind::kKey || !mapping.accepted) {
                RecordUnsupportedKeyLocked(event, emissions);
                return GlfwAdapterStatus::kOk;
            }
            const GlfwMappedKey& mapped = mapping.key;
            keyContributors.emplace(contributor, mapped.key);
            auto [aggregate, inserted] = keys.emplace(
                mapped.key,
                KeyAggregate{mapped.scanCode, mapped.scanCodeSource, 0u});
            ++aggregate->second.contributorCount;
            if (inserted) {
                emissions.emplace_back(GlfwKeySinkEvent{
                    mapped.key, mapped.scanCode, GlfwInputAction::kPress,
                    event.payload.physicalKey.modifiersSnapshot,
                    event.payload.physicalKey.lockState,
                    event.header.deviceId, event.header.sequence,
                    event.header.monotonicTimeNs, mapped.scanCodeSource});
            }
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_POINTER_BUTTON: {
            const uint32_t action = event.payload.pointerButton.action;
            if (action != AMCL_INPUT_ACTION_DOWN &&
                action != AMCL_INPUT_ACTION_UP) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            const bool requiresAbsoluteAuthorization =
                absoluteRouteEnabled &&
                (event.header.flags &
                 AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u &&
                (event.header.flags & AMCL_INPUT_EVENT_FLAG_SYNTHETIC) == 0u;
            if (requiresAbsoluteAuthorization) {
                // ⚠️ `GlfwTypedAbsoluteRoute::AcceptButton` runs a check that
                // looks like a copy of this one (same `consecutive` clause,
                // same deviceId/surfaceEpoch comparison). The two are
                // **deliberately independent and must not be merged**:
                // this one validates the pair against what **core** published,
                // that one additionally validates it against the live
                // NativeWindow publication generation and its width/height.
                // Merging them would make one layer's guarantee depend on the
                // other's -- exactly what spec §八.8 forbids -- and the ArkTS/GLFW
                // side would silently lose the narrower of the two checks.
                // This is the §4.0 exception: it is a narrowing check, not a
                // mirror, so it is declared rather than eliminated.
                const AbsoluteAuthorization authorization =
                    absoluteAuthorization;
                absoluteAuthorization = {};
                const bool consecutive = authorization.valid &&
                    authorization.sequence != UINT64_MAX &&
                    event.header.sequence == authorization.sequence + 1u;
                if (!consecutive ||
                    event.header.deviceId != authorization.deviceId ||
                    event.header.deviceClass != authorization.deviceClass ||
                    event.header.surfaceEpoch !=
                        authorization.surfaceEpoch ||
                    !HasUsableSurfacePublicationLocked() ||
                    event.header.surfaceEpoch != surfacePublicationEpoch) {
                    DropAbsoluteRouteLocked();
                    return GlfwAdapterStatus::kOk;
                }
            } else {
                absoluteAuthorization = {};
            }
            const Contributor contributor{event.header.deviceId,
                event.payload.pointerButton.nativeButton};
            auto owner = buttonContributors.find(contributor);
            if (action == AMCL_INPUT_ACTION_UP) {
                if (owner == buttonContributors.end()) {
                    RecordDroppedEdgeLocked(
                        event, AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP,
                        emissions);
                    if (mapping.kind != MappingKind::kButton ||
                        !mapping.accepted) {
                        RecordUnsupportedButtonLocked(event, emissions);
                    }
                    return GlfwAdapterStatus::kOk;
                }
                const ButtonContributor contributorOwner = owner->second;
                const int32_t mapped = contributorOwner.mapped;
                buttonContributors.erase(owner);
                auto aggregate = buttons.find(mapped);
                if (aggregate == buttons.end() ||
                    aggregate->second.contributorCount == 0u) {
                    return GlfwAdapterStatus::kMalformedEvent;
                }
                const bool finalAggregate =
                    --aggregate->second.contributorCount == 0u;
                if (backend == AMCL_INPUT_BACKEND_SDL3_PHYSICAL ||
                    finalAggregate) {
                    emissions.emplace_back(GlfwButtonSinkEvent{
                        mapped, GlfwInputAction::kRelease,
                        event.payload.pointerButton.modifiersSnapshot,
                        event.header.deviceId, event.header.sequence,
                        event.header.surfaceEpoch,
                        requiresAbsoluteAuthorization,
                        event.header.monotonicTimeNs,
                        contributorOwner.deviceClass});
                }
                if (finalAggregate) buttons.erase(aggregate);
                return GlfwAdapterStatus::kOk;
            }
            if (owner != buttonContributors.end()) {
                RecordDroppedEdgeLocked(
                    event,
                    AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN,
                    emissions);
                return GlfwAdapterStatus::kOk;
            }
            if (mapping.kind != MappingKind::kButton || !mapping.accepted) {
                RecordUnsupportedButtonLocked(event, emissions);
                return GlfwAdapterStatus::kOk;
            }
            const int32_t mapped = mapping.button;
            buttonContributors.emplace(
                contributor,
                ButtonContributor{mapped, event.header.deviceClass});
            auto [aggregate, inserted] = buttons.emplace(
                mapped, ButtonAggregate{0u});
            ++aggregate->second.contributorCount;
            if (backend == AMCL_INPUT_BACKEND_SDL3_PHYSICAL || inserted) {
                emissions.emplace_back(GlfwButtonSinkEvent{
                    mapped, GlfwInputAction::kPress,
                    event.payload.pointerButton.modifiersSnapshot,
                    event.header.deviceId, event.header.sequence,
                    event.header.surfaceEpoch,
                    requiresAbsoluteAuthorization,
                    event.header.monotonicTimeNs,
                    event.header.deviceClass});
            }
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_POINTER_ABSOLUTE:
            if (!std::isfinite(event.payload.pointerAbsolute.localPxX) ||
                !std::isfinite(event.payload.pointerAbsolute.localPxY)) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            if (!absoluteRouteEnabled ||
                !HasUsableSurfacePublicationLocked() ||
                event.header.surfaceEpoch != surfacePublicationEpoch) {
                DropAbsoluteRouteLocked();
                return GlfwAdapterStatus::kOk;
            }
            absoluteAuthorization = {event.header.sequence,
                                     event.header.deviceId,
                                     event.header.deviceClass,
                                     event.header.surfaceEpoch, true};
            emissions.emplace_back(GlfwAbsoluteSinkEvent{
                event.payload.pointerAbsolute.localPxX,
                event.payload.pointerAbsolute.localPxY,
                event.header.deviceId, event.header.sequence,
                event.header.surfaceEpoch,
                surfacePublication.publicationGeneration,
                event.header.deviceClass});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_POINTER_RELATIVE:
            if (!std::isfinite(event.payload.pointerRelative.rawDx) ||
                !std::isfinite(event.payload.pointerRelative.rawDy)) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwRelativeSinkEvent{
                event.payload.pointerRelative.rawDx,
                event.payload.pointerRelative.rawDy,
                event.header.deviceId, event.header.sequence,
                event.header.monotonicTimeNs,
                (event.header.flags &
                 AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW) != 0u,
                event.header.deviceClass});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_POINTER_WHEEL:
            if (!std::isfinite(event.payload.pointerWheel.x) ||
                !std::isfinite(event.payload.pointerWheel.y) ||
                event.payload.pointerWheel.unit < AMCL_INPUT_WHEEL_UNIT_PIXEL ||
                event.payload.pointerWheel.unit > AMCL_INPUT_WHEEL_UNIT_DEGREE ||
                event.payload.pointerWheel.precise > 1u) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwWheelSinkEvent{
                event.payload.pointerWheel.x, event.payload.pointerWheel.y,
                event.payload.pointerWheel.unit,
                event.payload.pointerWheel.precise != 0u,
                event.header.deviceId, event.header.sequence,
                event.header.monotonicTimeNs, event.header.deviceClass});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_FOCUS_CHANGED:
            if (event.payload.focus.focused > 1u) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            if (event.payload.focus.focused == 0u) {
                ClearAggregatesLocked(event.header.sequence,
                                      event.header.monotonicTimeNs, emissions);
                textSessionActive = false;
                textSessionId = 0u;
            }
            emissions.emplace_back(GlfwFocusSinkEvent{
                event.payload.focus.focused != 0u,
                event.header.focusEpoch, event.header.sequence,
                event.header.monotonicTimeNs, false});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_POINTER_ENTER:
            if (event.payload.pointerEnter.entered > 1u) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwEnterSinkEvent{
                event.payload.pointerEnter.entered != 0u,
                event.header.deviceId, event.header.sequence});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_CAPTURE_CHANGED:
            if (event.payload.capture.requested > 1u ||
                event.payload.capture.active > 1u ||
                (event.payload.capture.active != 0u &&
                 (event.payload.capture.requested == 0u ||
                  event.payload.capture.reason !=
                      AMCL_INPUT_CAPTURE_REASON_GRANTED)) ||
                (event.payload.capture.active == 0u &&
                 event.payload.capture.reason ==
                     AMCL_INPUT_CAPTURE_REASON_GRANTED)) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwCaptureSinkEvent{
                event.payload.capture.requested != 0u,
                event.payload.capture.active != 0u,
                event.payload.capture.reason, event.header.sequence,
                event.header.monotonicTimeNs, false});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_SURFACE_CHANGED: {
            if (event.payload.surface.active > 1u ||
                ((event.payload.surface.validFields &
                  AMCL_INPUT_SURFACE_FIELD_DIMENSIONS) != 0u &&
                 (event.payload.surface.widthPx == 0u ||
                  event.payload.surface.heightPx == 0u)) ||
                ((event.payload.surface.validFields &
                  AMCL_INPUT_SURFACE_FIELD_DENSITY) != 0u &&
                 (!std::isfinite(event.payload.surface.density) ||
                  event.payload.surface.density <= 0.0f)) ||
                ((event.payload.surface.validFields &
                  AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION) != 0u &&
                 event.payload.surface.publicationGeneration == 0u)) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            surfacePublication = event.payload.surface;
            textSessionActive = false;
            textSessionId = 0u;
            surfacePublicationEpoch = event.header.surfaceEpoch;
            constexpr uint32_t kAbsoluteSurfaceFields =
                AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
            hasSurfacePublication =
                event.payload.surface.active != 0u &&
                event.header.surfaceEpoch != 0u &&
                (event.payload.surface.validFields &
                 kAbsoluteSurfaceFields) == kAbsoluteSurfaceFields;
            absoluteAuthorization = {};
            emissions.emplace_back(GlfwSurfaceSinkEvent{
                event.payload.surface, event.header.surfaceEpoch,
                event.header.sequence});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED: {
            const auto& context = event.payload.surfaceContext;
            if ((context.validFields &
                 ~AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL) != 0u ||
                context.generation == 0u ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW) != 0u &&
                 context.windowId <= 0) ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY) != 0u &&
                 context.displayId < 0) ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u &&
                 (context.widthPx == 0u || context.heightPx == 0u)) ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
                 (!std::isfinite(context.density) ||
                  context.density <= 0.0f)) ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u &&
                 context.transform > 3u) ||
                ((context.validFields &
                  AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) != 0u &&
                 (!std::isfinite(context.refreshRateHz) ||
                  context.refreshRateHz <= 0.0f ||
                  context.refreshRateHz > 1000.0f))) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwSurfaceContextSinkEvent{
                context, event.header.surfaceEpoch, event.header.sequence,
                event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_RESET:
            if (event.payload.reset.reason < AMCL_INPUT_RESET_EXPLICIT ||
                event.payload.reset.reason >
                    AMCL_INPUT_RESET_BACKEND_ABANDONED ||
                event.payload.reset.closingEpoch != sessionEpoch) {
                // Every ordinary RESET closes state in its own session. A
                // mismatched closing epoch is not a harmless future field: it
                // could release the new session for a delayed old-session edge.
                return GlfwAdapterStatus::kMalformedEvent;
            }
            ClearAggregatesLocked(event.header.sequence,
                                  event.header.monotonicTimeNs, emissions);
            ClearAbsoluteRouteLocked();
            textSessionActive = false;
            textSessionId = 0u;
            emissions.emplace_back(GlfwResetSinkEvent{
                event.payload.reset.reason,
                event.payload.reset.closingEpoch, event.header.sequence,
                event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_DEVICE_CHANGED:
            if (event.payload.device.change != AMCL_INPUT_DEVICE_ADDED &&
                event.payload.device.change != AMCL_INPUT_DEVICE_REMOVED) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            if (event.payload.device.change == AMCL_INPUT_DEVICE_REMOVED) {
                ClearDeviceLocked(event.header.deviceId,
                                  event.header.deviceClass,
                                  event.header.sequence,
                                  event.header.monotonicTimeNs, emissions);
            }
            // Ordering is deliberate: ClearDeviceLocked appends all final
            // release callbacks first; only then may a backend remove the
            // physical device object that owns those controls.
            emissions.emplace_back(GlfwDeviceSinkEvent{
                event.header.deviceId, event.header.deviceClass,
                event.payload.device.change,
                event.payload.device.capabilities, event.header.sequence,
                event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        case AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED: {
            const auto& text = event.payload.textSession;
            if (text.textSessionId == 0u ||
                text.change < AMCL_INPUT_TEXT_SESSION_STARTED ||
                text.change > AMCL_INPUT_TEXT_SESSION_ABORTED ||
                text.reason >
                    AMCL_INPUT_TEXT_SESSION_REASON_INPUT_SESSION_ENDED) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            if (text.change == AMCL_INPUT_TEXT_SESSION_STARTED) {
                if (textSessionActive &&
                    textSessionId != text.textSessionId) {
                    return GlfwAdapterStatus::kMalformedEvent;
                }
                textSessionActive = true;
                textSessionId = text.textSessionId;
            } else {
                if (!textSessionActive ||
                    textSessionId != text.textSessionId) {
                    return GlfwAdapterStatus::kMalformedEvent;
                }
                textSessionActive = false;
                textSessionId = 0u;
            }
            emissions.emplace_back(GlfwTextSessionSinkEvent{
                text.textSessionId, text.change, text.reason,
                event.header.sequence, event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_TEXT_COMMIT: {
            if (!textBytes || !textSessionActive ||
                event.payload.textCommit.textSessionId != textSessionId) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            size_t scalarCount = 0u;
            if (CountTextUtf8Scalars(
                    textBytes->data(), textBytes->size(), &scalarCount) !=
                    TextUtf8CodecStatus::kOk || scalarCount == 0u ||
                scalarCount > kTextCandidateMaxScalars) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwTextCommitSinkEvent{
                textSessionId, *textBytes, event.header.sequence,
                event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_TEXT_EDITING: {
            if (!textBytes || !textSessionActive ||
                event.payload.textEditing.textSessionId != textSessionId) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            size_t scalarCount = 0u;
            if (CountTextUtf8Scalars(
                    textBytes->data(), textBytes->size(), &scalarCount) !=
                    TextUtf8CodecStatus::kOk ||
                scalarCount > kTextCandidateMaxScalars ||
                event.payload.textEditing.selectionStart > scalarCount ||
                event.payload.textEditing.selectionLength >
                    scalarCount -
                    event.payload.textEditing.selectionStart) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwTextEditingSinkEvent{
                textSessionId, *textBytes,
                event.payload.textEditing.selectionStart,
                event.payload.textEditing.selectionLength,
                event.header.sequence, event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_TEXT_CANDIDATES: {
            if (!textBytes || !textSessionActive ||
                event.payload.textCandidates.textSessionId != textSessionId) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            TextUtf8CandidateView views[kTextCandidateMaxItems]{};
            size_t itemCount = 0u;
            size_t scalarCount = 0u;
            if (DecodeTextCandidateBlob(
                    textBytes->data(), textBytes->size(), views,
                    kTextCandidateMaxItems, &itemCount, &scalarCount) !=
                    TextUtf8CodecStatus::kOk ||
                itemCount != event.payload.textCandidates.itemCount) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            const auto& candidates = event.payload.textCandidates;
            const bool empty = itemCount == 0u && candidates.selected == 0u &&
                candidates.pageStart == 0u && candidates.pageSize == 0u;
            const bool populated = itemCount != 0u &&
                candidates.selected < itemCount &&
                candidates.pageStart < itemCount &&
                candidates.pageSize != 0u &&
                candidates.pageSize <= itemCount - candidates.pageStart &&
                candidates.selected >= candidates.pageStart &&
                candidates.selected <
                    candidates.pageStart + candidates.pageSize;
            if (!empty && !populated) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            std::vector<std::string> items;
            items.reserve(itemCount);
            for (size_t index = 0u; index < itemCount; ++index) {
                items.emplace_back(
                    reinterpret_cast<const char*>(views[index].utf8.data),
                    views[index].utf8.byteCount);
            }
            emissions.emplace_back(GlfwTextCandidatesSinkEvent{
                textSessionId, std::move(items), candidates.selected,
                candidates.pageStart, candidates.pageSize,
                event.header.sequence, event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_TEXT_SELECTION: {
            const auto& selection = event.payload.textSelection;
            if (!textSessionActive ||
                selection.textSessionId != textSessionId ||
                selection.selectionStart > kTextCandidateMaxScalars ||
                selection.selectionLength >
                    kTextCandidateMaxScalars - selection.selectionStart) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            emissions.emplace_back(GlfwTextSelectionSinkEvent{
                textSessionId, selection.selectionStart,
                selection.selectionLength, event.header.sequence,
                event.header.monotonicTimeNs});
            return GlfwAdapterStatus::kOk;
        }
        case AMCL_INPUT_EVENT_DIAGNOSTIC_DROP: {
            const AmclInputDiagnosticDropPayload& drop =
                event.payload.diagnosticDrop;
            const bool ownerlessKeyRepeat =
                drop.reason ==
                    AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT &&
                drop.originalEventType == AMCL_INPUT_EVENT_PHYSICAL_KEY &&
                drop.action == AMCL_INPUT_ACTION_REPEAT;
            const bool ownerlessKeyUp =
                drop.reason == AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP &&
                drop.originalEventType == AMCL_INPUT_EVENT_PHYSICAL_KEY &&
                drop.action == AMCL_INPUT_ACTION_UP;
            const bool ownerlessButtonUp =
                drop.reason ==
                    AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP &&
                drop.originalEventType == AMCL_INPUT_EVENT_POINTER_BUTTON &&
                drop.action == AMCL_INPUT_ACTION_UP;
            const bool duplicateButtonDown =
                drop.reason ==
                    AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN &&
                drop.originalEventType == AMCL_INPUT_EVENT_POINTER_BUTTON &&
                drop.action == AMCL_INPUT_ACTION_DOWN;
            if (!ownerlessKeyRepeat && !ownerlessKeyUp &&
                !ownerlessButtonUp && !duplicateButtonDown) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            if ((ownerlessButtonUp || duplicateButtonDown) &&
                (drop.hardwareScanCode != 0u || drop.hidUsage != 0u)) {
                return GlfwAdapterStatus::kMalformedEvent;
            }
            RecordCoreDropLocked(event, emissions);
            return GlfwAdapterStatus::kOk;
        }
        default:
            // A future typed event with a valid common header is safe to skip.
            return GlfwAdapterStatus::kOk;
    }
}

int32_t GlfwInputAdapter::Impl::AbandonIncarnation(
        uint64_t expectedIncarnation, uint32_t* discardedByCall,
        std::vector<Emission>* releases, GlfwInputSink* releaseSink) {
    if (discardedByCall) *discardedByCall = 0u;
    const AmclInputHostApiV1* targetApi = nullptr;
    AmclInputConsumerHandle targetConsumer = 0u;
    uint64_t targetEpoch = 0u;
    uint32_t targetBackend = AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    {
        std::lock_guard<std::mutex> state(stateMutex);
        if (incarnation != expectedIncarnation || !api || consumer == 0u ||
            lifecycle == Lifecycle::kClosed) {
            return AMCL_INPUT_ERROR_NOT_FOUND;
        }
        lifecycle = Lifecycle::kAbandoning;
        cleanupActive = true;
        suppressCleanupCallbacks = true;
        ++callbackFence;
        if (inFlight.active &&
            inFlight.incarnation == expectedIncarnation) {
            if (InFlightNeedsAccountedDiscardLocked()) {
                DiscardInFlightLocked();
                if (discardedByCall) ++*discardedByCall;
            } else {
                inFlight = {};
            }
        }
        if (releaseSink) *releaseSink = sink;
        if (releases) ClearAggregatesLocked(0u, 0u, *releases);
        ClearAbsoluteRouteLocked();
        textSessionActive = false;
        textSessionId = 0u;
        deferredStartupEmissions.clear();
        targetApi = api;
        targetConsumer = consumer;
        targetEpoch = sessionEpoch;
        targetBackend = backend;
        ++abandonCount;
        pumpActive = false;
    }

    AmclInputEvent control{};
    control.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    control.header.structSize = static_cast<uint16_t>(sizeof(control));
    control.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    control.header.sessionEpoch = targetEpoch;
    control.payload.backendConsumerState.state =
        AMCL_INPUT_BACKEND_CONSUMER_ABANDON;
    control.payload.backendConsumerState.backend = targetBackend;
    control.payload.backendConsumerState.consumer = targetConsumer;
    control.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;

    int32_t result = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    {
        std::lock_guard<std::mutex> host(hostCallMutex);
        result = targetApi->submitEvent(&control);
    }
    const bool terminal = result == AMCL_INPUT_OK ||
        result == AMCL_INPUT_OVERFLOW_RESET ||
        result == AMCL_INPUT_ERROR_NOT_FOUND;
    {
        std::lock_guard<std::mutex> state(stateMutex);
        if (incarnation == expectedIncarnation) {
            if (terminal) {
                api = nullptr;
                consumer = 0u;
                mapper = {};
                sink = {};
                sessionEpoch = 0u;
                lastSequence = 0u;
                absoluteRouteEnabled = false;
                lifecycle = Lifecycle::kClosed;
                backendRegistered = false;
                suppressCleanupCallbacks = false;
            }
            cleanupActive = false;
        }
    }
    return result;
}
namespace {

bool IsFreshBaseline(const AmclInputEvent& event) {
    return event.header.abiVersion == AMCL_INPUT_EVENT_ABI_VERSION &&
           event.header.structSize >= sizeof(AmclInputEvent) &&
           event.header.eventType == AMCL_INPUT_EVENT_RESET &&
           event.header.sequence != 0u && event.header.sessionEpoch != 0u &&
           event.header.source == AMCL_INPUT_SOURCE_SYNTHETIC &&
           (event.header.flags & AMCL_INPUT_EVENT_FLAG_SYNTHETIC) != 0u &&
           event.payload.reset.reason == AMCL_INPUT_RESET_CONSUMER_BASELINE &&
           event.payload.reset.closingEpoch == event.header.sessionEpoch;
}

AmclInputEvent BackendConsumerControl(uint32_t state, uint64_t epoch,
                                      AmclInputConsumerHandle consumer,
                                      uint32_t backend,
                                      uint64_t baselineSequence = 0u) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    event.header.sessionEpoch = epoch;
    event.payload.backendConsumerState.state = state;
    // ⚠️ 此前这里写死 `GLFW_PHYSICAL`。写死的后果不是编译错，是**第二个后端申领 READY
    // 时会顶掉第一个后端的槽**（同一个 backend id ⇒ 同一个槽）—— 而两边都会各自认为
    // 自己是当前后端。本适配器是后端参数化的：backend 由 Open 的调用方指定。
    event.payload.backendConsumerState.backend = backend;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baselineSequence;
    return event;
}

PreparedMapping InvokeMapper(const GlfwInputMapper& mapper,
                             MappingKind kind,
                             const AmclInputEvent& event) {
    PreparedMapping result{};
    result.kind = kind;
    if (kind == MappingKind::kKey) {
        result.accepted = mapper.mapKey(
            mapper.context, event.header.deviceId,
            event.payload.physicalKey.physicalKey,
            event.payload.physicalKey.hardwareScanCode,
            event.payload.physicalKey.hidUsage, &result.key);
    } else if (kind == MappingKind::kButton) {
        result.accepted = mapper.mapButton(
            mapper.context, event.header.deviceId,
            event.payload.pointerButton.nativeButton, &result.button);
    }
    return result;
}

bool IsTerminalConsumerStatus(int32_t status) {
    return status == AMCL_INPUT_OK ||
           status == AMCL_INPUT_ERROR_NOT_FOUND ||
           status == AMCL_INPUT_ERROR_STALE;
}

}  // namespace

GlfwInputAdapter::GlfwInputAdapter() : impl_(std::make_unique<Impl>()) {}

GlfwInputAdapter::~GlfwInputAdapter() {
    (void)Close();
}

GlfwAdapterStatus GlfwInputAdapter::Open(
        const AmclInputHostApiV1* api, const GlfwInputMapper& mapper,
        const GlfwInputSink& sink, uint32_t backend) {
    const GlfwAdapterStatus prior = Close();
    if (prior != GlfwAdapterStatus::kOk) {
        return GlfwAdapterStatus::kHostError;
    }
    const bool requiresPhysicalRoute = sink.key != nullptr ||
        sink.button != nullptr || sink.absolute != nullptr ||
        sink.relative != nullptr || sink.wheel != nullptr ||
        sink.focus != nullptr || sink.enter != nullptr ||
        sink.capture != nullptr || sink.surface != nullptr ||
        sink.surfaceContext != nullptr || sink.device != nullptr;
    const bool requiresTextSession = sink.textSession != nullptr ||
        sink.textCommit != nullptr || sink.textEditing != nullptr ||
        sink.textCandidates != nullptr || sink.textSelection != nullptr;
    if (!IsCompleteApi(api, requiresPhysicalRoute, requiresTextSession) ||
        (requiresPhysicalRoute && (!mapper.mapKey || !mapper.mapButton))) {
        return GlfwAdapterStatus::kInvalidConfiguration;
    }
    // 未知 backend fail closed。放过去的后果是 core 的 ValidatePayload 拒掉 READY 控制包，
    // 而那一步在 Open 的后半段，届时消费者已经建好 ⇒ 一个永远拿不到事件的半开状态。
    if (backend < AMCL_INPUT_BACKEND_GLFW_PHYSICAL ||
        backend >= AMCL_INPUT_BACKEND_COUNT) {
        return GlfwAdapterStatus::kInvalidConfiguration;
    }
    impl_->backend = backend;
    const bool absoluteRouteEnabled =
        (api->capabilityBits &
         AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) != 0u;
    if (requiresPhysicalRoute && absoluteRouteEnabled &&
        (!sink.absolute || !sink.surface)) {
        // The host bit is build evidence, not permission to claim backend
        // readiness with a partial runtime route.  In particular, a null sink
        // must leave the producer behind the BACKEND_NOT_READY barrier.
        return GlfwAdapterStatus::kInvalidConfiguration;
    }

    std::lock_guard<std::mutex> opening(impl_->openMutex);
    uint64_t openingIncarnation = 0u;
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        if (impl_->lifecycle != Impl::Lifecycle::kClosed ||
            impl_->consumer != 0u || impl_->incarnation == UINT64_MAX ||
            impl_->callbackFence == UINT64_MAX) {
            return GlfwAdapterStatus::kHostError;
        }
        openingIncarnation = ++impl_->incarnation;
        ++impl_->callbackFence;
        impl_->lifecycle = Impl::Lifecycle::kOpening;
        impl_->api = api;
        impl_->mapper = mapper;
        impl_->sink = sink;
        impl_->absoluteRouteEnabled = absoluteRouteEnabled;
        impl_->ClearAbsoluteRouteLocked();
        impl_->textSessionActive = false;
        impl_->textSessionId = 0u;
        impl_->deferredStartupEmissions.clear();
        impl_->backendRegistered = false;
        impl_->suppressCleanupCallbacks = false;
    }

    // ⚠️ `site` / `detail` 只进诊断，**不参与任何判定**。它们存在的理由是一次真机排查
    // 卡住：`kBaselineRejected` 把六个互不相同的成因 collapse 成一个值，日志里只有
    // `status=4`，于是"到底哪一步拒的"在设备上不可判定（计划 §105）。
    auto finishRejectedOpen = [&](GlfwAdapterStatus status,
                                  AmclInputConsumerHandle opened,
                                  GlfwOpenRejectSite site =
                                      GlfwOpenRejectSite::kNone,
                                  int32_t detail = 0) {
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            impl_->lastOpenRejectSite = site;
            impl_->lastOpenRejectDetail = detail;
        }
        int32_t closeStatus = AMCL_INPUT_OK;
        if (opened != 0u) {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            closeStatus = api->closeConsumer(opened);
        }
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        if (impl_->incarnation == openingIncarnation) {
            impl_->absoluteRouteEnabled = false;
            impl_->ClearAbsoluteRouteLocked();
            impl_->textSessionActive = false;
            impl_->textSessionId = 0u;
            impl_->deferredStartupEmissions.clear();
            if (opened != 0u && !IsTerminalConsumerStatus(closeStatus)) {
                // Keep the borrowed table/handle reachable. A later Close/Open
                // retries cleanup instead of orphaning a remote consumer.
                impl_->consumer = opened;
                impl_->lifecycle = Impl::Lifecycle::kAbandoning;
            } else {
                impl_->api = nullptr;
                impl_->consumer = 0u;
                impl_->mapper = {};
                impl_->sink = {};
                impl_->sessionEpoch = 0u;
                impl_->lastSequence = 0u;
                impl_->absoluteRouteEnabled = false;
                impl_->ClearAbsoluteRouteLocked();
                impl_->textSessionActive = false;
                impl_->textSessionId = 0u;
                impl_->deferredStartupEmissions.clear();
                impl_->lifecycle = Impl::Lifecycle::kClosed;
            }
            impl_->cleanupActive = false;
            impl_->pumpActive = false;
            impl_->inFlight = {};
        }
        return status;
    };

    AmclInputConsumerHandle consumer = 0;
    int32_t openStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    {
        std::lock_guard<std::mutex> host(impl_->hostCallMutex);
        openStatus = api->openConsumer(&consumer);
    }
    if (openStatus != AMCL_INPUT_OK || consumer == 0u) {
        return finishRejectedOpen(GlfwAdapterStatus::kOpenFailed, consumer,
                                  GlfwOpenRejectSite::kOpenConsumer,
                                  openStatus);
    }
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        impl_->consumer = consumer;
    }

    AmclInputEvent baseline{};
    int32_t baselineStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    {
        std::lock_guard<std::mutex> host(impl_->hostCallMutex);
        baselineStatus = api->nextEvent(consumer, &baseline);
    }
    if (baselineStatus != AMCL_INPUT_OK || !IsFreshBaseline(baseline)) {
        // ⭐ EMPTY 是"**还没有**基线"，不是"基线被拒"：core 只在会话活跃时播种基线，而
        // 会话可能稍后才开始（`OpenConsumer` 在无会话时仍返回 OK，见计划 §105.6 那条待评估）。
        // 报 `kNotReady` 让调用方按"下一帧再来"处置 —— 这里此前一律报 kBaselineRejected，
        // 而那个词会让读日志的人去查"是什么不合格"，实际什么都没不合格。
        const GlfwAdapterStatus status =
            baselineStatus == AMCL_INPUT_EMPTY
                ? GlfwAdapterStatus::kNotReady
                : GlfwAdapterStatus::kBaselineRejected;
        // detail 分两段：host 状态非 OK 时给状态码，OK 但基线不新鲜时给事件类型 ——
        // 两者是不同的成因，共用一个 detail 会重现本次要修的那个"分不出来"。
        return finishRejectedOpen(
            status, consumer, GlfwOpenRejectSite::kBaselineEvent,
            baselineStatus != AMCL_INPUT_OK
                ? baselineStatus
                : -static_cast<int32_t>(baseline.header.eventType));
    }

    bool openingValid = false;
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        openingValid = impl_->incarnation == openingIncarnation &&
            impl_->lifecycle == Impl::Lifecycle::kOpening;
        if (openingValid) {
            impl_->sessionEpoch = baseline.header.sessionEpoch;
            impl_->lastSequence = baseline.header.sequence;
        }
    }
    if (!openingValid) {
        return finishRejectedOpen(GlfwAdapterStatus::kBaselineRejected,
                                  consumer,
                                  GlfwOpenRejectSite::kBaselineIncarnation);
    }

    // OpenConsumer may replay the current surface and device registry
    // immediately after the baseline. READY requires every pending control
    // record to be consumed: absolute input needs its surface first, while a
    // device-scoped backend must see DEVICE_ADDED before later physical edges.
    // Keep sink callbacks deferred until Open has left its non-reentrant mutex.
    std::vector<Emission> startupEmissions;
    constexpr uint32_t kMaximumStartupControlRecords = 256u;
    uint32_t startupControlRecords = 0u;
    for (;;) {
        AmclInputEvent startup{};
        int32_t startupStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            startupStatus = api->nextEvent(consumer, &startup);
        }
        if (startupStatus == AMCL_INPUT_EMPTY) break;
        const bool knownStartupControl =
            startup.header.eventType == AMCL_INPUT_EVENT_SURFACE_CHANGED ||
            startup.header.eventType ==
                AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED ||
            startup.header.eventType == AMCL_INPUT_EVENT_DEVICE_CHANGED ||
            startup.header.eventType ==
                AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
        if (startupStatus != AMCL_INPUT_OK ||
            !knownStartupControl ||
            ++startupControlRecords > kMaximumStartupControlRecords) {
            // ⭐ 这一站是**晚到的消费者**最可能撞上的：契约假设 Open 之后队列里只有
            // surface 重放，而一个在会话开始十几秒后才第一次拉的消费者（SDL3 那条链正是
            // 如此）会看到别的类型。detail 给事件类型，好把"到底看到了什么"钉死。
            return finishRejectedOpen(
                GlfwAdapterStatus::kBaselineRejected, consumer,
                GlfwOpenRejectSite::kStartupRecordKind,
                startupStatus != AMCL_INPUT_OK
                    ? startupStatus
                    : -static_cast<int32_t>(startup.header.eventType));
        }
        GlfwAdapterStatus processed = GlfwAdapterStatus::kNotReady;
        bool startupOpeningValid = false;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            startupOpeningValid =
                impl_->incarnation == openingIncarnation &&
                impl_->lifecycle == Impl::Lifecycle::kOpening;
            if (startupOpeningValid) {
                processed = impl_->ProcessEventLocked(
                    startup, PreparedMapping{}, startupEmissions);
            }
        }
        if (!startupOpeningValid || processed != GlfwAdapterStatus::kOk) {
            return finishRejectedOpen(
                GlfwAdapterStatus::kBaselineRejected, consumer,
                GlfwOpenRejectSite::kStartupProcess,
                static_cast<int32_t>(processed));
        }
    }

    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    int32_t snapshotStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    {
        std::lock_guard<std::mutex> host(impl_->hostCallMutex);
        snapshotStatus = api->getSnapshot(&snapshot);
    }
    const bool validCaptureSnapshot =
        snapshot.captureRequested <= 1u && snapshot.captureActive <= 1u &&
        !(snapshot.captureActive != 0u &&
          (snapshot.captureRequested == 0u ||
           snapshot.captureReason != AMCL_INPUT_CAPTURE_REASON_GRANTED)) &&
        !(snapshot.captureActive == 0u &&
          snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_GRANTED);
    if (snapshotStatus != AMCL_INPUT_OK ||
        snapshot.abiVersion != AMCL_INPUT_HOST_API_VERSION ||
        snapshot.structSize < sizeof(snapshot) || snapshot.sessionActive == 0u ||
        snapshot.sessionEpoch != baseline.header.sessionEpoch ||
        snapshot.focused > 1u || !validCaptureSnapshot) {
        // detail 编码成位图而不是只给第一个不满足的条件：几条同时不满足是有信息的，
        // 而"只报第一个"会让第二轮排查又缺一半（本仓 §八 那条"分母可归属"的同族）。
        const int32_t bits =
            (snapshotStatus != AMCL_INPUT_OK ? 1 : 0) |
            (snapshot.abiVersion != AMCL_INPUT_HOST_API_VERSION ? 2 : 0) |
            (snapshot.structSize < sizeof(snapshot) ? 4 : 0) |
            (snapshot.sessionActive == 0u ? 8 : 0) |
            (snapshot.sessionEpoch != baseline.header.sessionEpoch ? 16 : 0) |
            (snapshot.focused > 1u ? 32 : 0) |
            (!validCaptureSnapshot ? 64 : 0);
        return finishRejectedOpen(GlfwAdapterStatus::kBaselineRejected,
                                  consumer, GlfwOpenRejectSite::kSnapshot,
                                  bits);
    }

    // Surface records are replayed through the consumer queue. Focus/capture
    // live in the fixed snapshot tail so a late backend can seed exact runtime
    // state even when their transition happened before Open. Baselines update
    // polling state but must not manufacture a user focus callback.
    if (snapshot.focused == 0u ||
        backend != AMCL_INPUT_BACKEND_GLFW_PHYSICAL) {
        startupEmissions.emplace_back(GlfwFocusSinkEvent{
            snapshot.focused != 0u, snapshot.focusEpoch, 0u, 0u, true});
    }
    if (snapshot.captureRequested != 0u || snapshot.captureActive != 0u ||
        snapshot.captureReason != AMCL_INPUT_CAPTURE_REASON_NONE) {
        startupEmissions.emplace_back(GlfwCaptureSinkEvent{
            snapshot.captureRequested != 0u,
            snapshot.captureActive != 0u,
            snapshot.captureReason, 0u, 0u, true});
    }

    const AmclInputEvent ready = BackendConsumerControl(
        AMCL_INPUT_BACKEND_CONSUMER_READY, baseline.header.sessionEpoch,
        consumer, impl_->backend, baseline.header.sequence);
    int32_t readyStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    {
        std::lock_guard<std::mutex> host(impl_->hostCallMutex);
        readyStatus = api->submitEvent(&ready);
    }
    if (readyStatus != AMCL_INPUT_OK) {
        const GlfwAdapterStatus status =
            readyStatus == AMCL_INPUT_ERROR_STALE ||
                    readyStatus == AMCL_INPUT_ERROR_SESSION
                ? GlfwAdapterStatus::kBaselineRejected
                : GlfwAdapterStatus::kHostError;
        return finishRejectedOpen(status, consumer,
                                  GlfwOpenRejectSite::kReadySubmit,
                                  readyStatus);
    }

    bool readyOpeningValid = false;
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        readyOpeningValid = impl_->incarnation == openingIncarnation &&
            impl_->lifecycle == Impl::Lifecycle::kOpening;
        if (readyOpeningValid) {
            impl_->deferredStartupEmissions = std::move(startupEmissions);
            impl_->backendRegistered = true;
            impl_->lifecycle = Impl::Lifecycle::kReady;
        }
    }
    if (!readyOpeningValid) {
        return finishRejectedOpen(GlfwAdapterStatus::kBaselineRejected,
                                  consumer,
                                  GlfwOpenRejectSite::kReadyIncarnation);
    }
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        impl_->lastOpenRejectSite = GlfwOpenRejectSite::kNone;
        impl_->lastOpenRejectDetail = 0;
    }
    return GlfwAdapterStatus::kOk;
}

GlfwOpenRejectSite GlfwInputAdapter::LastOpenRejectSite() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->lastOpenRejectSite;
}

int32_t GlfwInputAdapter::LastOpenRejectDetail() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->lastOpenRejectDetail;
}

GlfwPumpResult GlfwInputAdapter::Pump() {
    const AmclInputHostApiV1* api = nullptr;
    AmclInputConsumerHandle consumer = 0u;
    GlfwInputMapper mapper{};
    GlfwInputSink startupSink{};
    std::vector<Emission> startupEmissions;
    uint64_t incarnation = 0u;
    uint64_t fence = 0u;
    {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        if (impl_->lifecycle != Impl::Lifecycle::kReady || !impl_->api ||
            impl_->consumer == 0u || impl_->pumpActive) {
            return {GlfwAdapterStatus::kNotReady, 0u};
        }
        impl_->pumpActive = true;
        api = impl_->api;
        consumer = impl_->consumer;
        mapper = impl_->mapper;
        startupSink = impl_->sink;
        startupEmissions = std::move(impl_->deferredStartupEmissions);
        incarnation = impl_->incarnation;
        fence = impl_->callbackFence;
    }

    uint32_t drained = 0u;
    auto releasePump = [&]() {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        if (impl_->incarnation == incarnation) impl_->pumpActive = false;
    };
    auto cancelled = [&](uint64_t ticket = 0u) {
        uint32_t discarded = 0u;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            if (ticket != 0u && impl_->lastDiscardedTicket == ticket) {
                discarded = 1u;
            }
            if (impl_->incarnation == incarnation) impl_->pumpActive = false;
        }
        return GlfwPumpResult{GlfwAdapterStatus::kNotReady, drained,
                              discarded, false, AMCL_INPUT_OK};
    };
    auto abandon = [&](GlfwAdapterStatus status, int32_t originalHostStatus) {
        std::lock_guard<std::recursive_mutex> callbackLease(
            impl_->callbackMutex);
        std::vector<Emission> releases;
        GlfwInputSink releaseSink{};
        uint32_t discarded = 0u;
        const int32_t recovery = impl_->AbandonIncarnation(
            incarnation, &discarded, &releases, &releaseSink);
        impl_->DispatchTerminalCallbacks(releaseSink, releases);
        const bool completed = recovery == AMCL_INPUT_OK ||
            recovery == AMCL_INPUT_OVERFLOW_RESET ||
            recovery == AMCL_INPUT_ERROR_NOT_FOUND;
        return GlfwPumpResult{status, drained, discarded, completed,
                              completed ? originalHostStatus : recovery};
    };

    if (!startupEmissions.empty()) {
        std::lock_guard<std::recursive_mutex> callbackLease(
            impl_->callbackMutex);
        for (const Emission& emission : startupEmissions) {
            bool valid = false;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady;
                if (valid) {
                    impl_->callbackActive = true;
                    impl_->callbackThread = std::this_thread::get_id();
                }
            }
            if (!valid) return cancelled();
            DispatchOne(startupSink, emission);
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->callbackActive &&
                    impl_->callbackThread == std::this_thread::get_id()) {
                    impl_->callbackActive = false;
                    impl_->callbackThread = {};
                }
            }
            impl_->callbackCondition.notify_all();
        }
    }

    for (;;) {
        AmclInputEvent event{};
        int32_t result = AMCL_INPUT_ERROR_NOT_FOUND;
        uint64_t ticket = 0u;
        bool cancelledAfterFetch = false;
        bool releaseCancelledBlob = false;
        int32_t cancelledBlobReleaseStatus = AMCL_INPUT_OK;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            bool valid = false;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady;
            }
            if (!valid) return cancelled();
            result = api->nextEvent(consumer, &event);
            if (result == AMCL_INPUT_OK) {
#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
                RunAdapterTestHook(
                    GlfwInputAdapterTestSeam::kAfterNextEvent);
#endif
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady;
                if (impl_->nextFetchTicket == 0u) {
                    impl_->nextFetchTicket = 1u;
                }
                ticket = impl_->nextFetchTicket++;
                if (valid) {
                    impl_->inFlight = {true, ticket, incarnation, event};
                    impl_->inFlight.ownsHostBlob =
                        IsBlobText(event.header.eventType);
                } else {
                    impl_->lastDiscardedTicket = ticket;
                    ++impl_->discardedFetchedEvents;
                    cancelledAfterFetch = true;
                    releaseCancelledBlob =
                        IsBlobText(event.header.eventType);
                }
            }
            if (releaseCancelledBlob) {
                cancelledBlobReleaseStatus =
                    api->releasePacket(consumer, TextPacketId(event));
            }
        }
        if (cancelledAfterFetch) {
            if (releaseCancelledBlob &&
                cancelledBlobReleaseStatus != AMCL_INPUT_OK &&
                cancelledBlobReleaseStatus != AMCL_INPUT_ERROR_NOT_FOUND) {
                return abandon(GlfwAdapterStatus::kHostError,
                               cancelledBlobReleaseStatus);
            }
            return cancelled(ticket);
        }
#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
        if (result == AMCL_INPUT_OK && ticket != 0u) {
            RunAdapterTestHook(
                GlfwInputAdapterTestSeam::kAfterFetchRegistered);
        }
#endif

        if (result == AMCL_INPUT_EMPTY) {
            releasePump();
            return {GlfwAdapterStatus::kOk, drained};
        }
        if (result == AMCL_INPUT_OVERFLOW_RESET) {
            std::lock_guard<std::recursive_mutex> callbackLease(
                impl_->callbackMutex);
            std::vector<Emission> releases;
            GlfwInputSink sink{};
            bool valid = false;
            uint64_t overflowTicket = 0u;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady;
                if (valid) {
                    sink = impl_->sink;
                    if (!impl_->keys.empty() || !impl_->buttons.empty()) {
                        if (impl_->nextFetchTicket == 0u) {
                            impl_->nextFetchTicket = 1u;
                        }
                        overflowTicket = impl_->nextFetchTicket++;
                        impl_->inFlight =
                            {true, overflowTicket, incarnation, {}};
                        // Third checkpoint form, hand-written on purpose ——
                        // it cannot call BeginRollbackCheckpointLocked:
                        //   · the registered event is **blank** (an overflow
                        //     notification has no host record behind it), so the
                        //     shared predicate would answer "does not clear held
                        //     controls" for a transition that clears all of them.
                        //     `restoreDuringDispatch` is therefore unconditional;
                        //   · only the four ledger maps are snapshotted. Surface
                        //     publication and absolute authorization are **not**,
                        //     because the clear below does not touch the former
                        //     and deliberately drops the latter for good (an
                        //     overflow breaks the ABSOLUTE→BUTTON sequence
                        //     adjacency that authorization encodes, so restoring
                        //     it would re-authorize a broken pair).
                        //
                        // ⚠️ There is a **fourth** site that clears these same
                        // aggregates and builds no checkpoint at all: the
                        // OVERFLOW_RESET branch of `Close`'s drain loop. It is
                        // reachable only during teardown and its `Dispatch` is
                        // all-or-nothing (no per-emission fence), so it cannot
                        // half-deliver -- but if its dispatch is skipped entirely
                        // the aggregates are already empty and `finishClosed`
                        // has nothing left to emit. Recorded in the plan document
                        // §59 rather than fixed here: the fix is a teardown-path
                        // behaviour change and this environment cannot execute
                        // the assertion that would prove it.
                        Impl::InFlight& flight = impl_->inFlight;
                        flight.stage = Impl::InFlight::Stage::kCommitted;
                        flight.hasAggregateRollback = true;
                        flight.restoreDuringDispatch = true;
                        flight.previousLastSequence = impl_->lastSequence;
                        flight.previousKeyContributors =
                            impl_->keyContributors;
                        flight.previousKeys = impl_->keys;
                        flight.previousButtonContributors =
                            impl_->buttonContributors;
                        flight.previousButtons = impl_->buttons;
                    }
                    impl_->ClearAggregatesLocked(0u, 0u, releases);
                    impl_->absoluteAuthorization = {};
                    impl_->pumpActive = false;
                }
            }
            if (!valid) return cancelled();
            for (const Emission& emission : releases) {
                valid = false;
                {
                    std::lock_guard<std::mutex> state(impl_->stateMutex);
                    valid = impl_->incarnation == incarnation &&
                        impl_->callbackFence == fence &&
                        impl_->lifecycle == Impl::Lifecycle::kReady;
                    if (valid && overflowTicket != 0u) {
                        valid = impl_->inFlight.active &&
                            impl_->inFlight.ticket == overflowTicket;
                        if (valid) {
                            impl_->MarkEmissionDeliveredForRollbackLocked(
                                emission);
                            impl_->inFlight.stage =
                                Impl::InFlight::Stage::kDispatching;
                            impl_->callbackActive = true;
                            impl_->callbackThread =
                                std::this_thread::get_id();
                        }
                    }
                }
                if (!valid) return cancelled(overflowTicket);
                DispatchOne(sink, emission);
                if (overflowTicket != 0u) {
                    {
                        std::lock_guard<std::mutex> state(impl_->stateMutex);
                        if (impl_->callbackActive &&
                            impl_->callbackThread ==
                                std::this_thread::get_id()) {
                            impl_->callbackActive = false;
                            impl_->callbackThread = {};
                        }
                    }
                    impl_->callbackCondition.notify_all();
                }
            }
            if (overflowTicket != 0u) {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->incarnation == incarnation &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == overflowTicket) {
                    impl_->inFlight = {};
                }
            }
            return {GlfwAdapterStatus::kOverflowReset, drained};
        }
        if (result == AMCL_INPUT_ERROR_STALE ||
            result == AMCL_INPUT_ERROR_SESSION) {
            releasePump();
            const GlfwAdapterStatus cleanup = Close();
            return {GlfwAdapterStatus::kStale, drained, 0u, false,
                    cleanup == GlfwAdapterStatus::kOk
                        ? result : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED};
        }
        if (result != AMCL_INPUT_OK) {
            return abandon(GlfwAdapterStatus::kHostError, result);
        }
        ++drained;

        std::vector<uint8_t> textBytes;
        if (IsBlobText(event.header.eventType)) {
            std::lock_guard<std::recursive_mutex> callbackLease(
                impl_->callbackMutex);
            bool ownsBlob = false;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                ownsBlob = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket;
            }
            if (!ownsBlob) return cancelled(ticket);
            TextBlobCopyResult copied;
            {
                std::lock_guard<std::mutex> host(impl_->hostCallMutex);
                copied = CopyAndReleaseTextBlob(api, consumer, event);
            }
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->incarnation == incarnation &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket) {
                    impl_->inFlight.ownsHostBlob = false;
                }
            }
            if (copied.status == TextBlobCopyStatus::kCancelled) {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket) {
                    impl_->DiscardInFlightLocked();
                }
                continue;
            }
            if (copied.status == TextBlobCopyStatus::kMalformed) {
                return abandon(GlfwAdapterStatus::kMalformedEvent,
                               copied.hostStatus);
            }
            if (copied.status != TextBlobCopyStatus::kOk) {
                return abandon(GlfwAdapterStatus::kHostError,
                               copied.hostStatus);
            }
            textBytes = std::move(copied.bytes);
        }

        MappingKind mappingKind = MappingKind::kNone;
        PreparedMapping mapping{};
        bool valid = false;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            valid = impl_->incarnation == incarnation &&
                impl_->callbackFence == fence &&
                impl_->lifecycle == Impl::Lifecycle::kReady &&
                impl_->inFlight.active &&
                impl_->inFlight.ticket == ticket;
            if (valid) mappingKind = impl_->MappingRequiredLocked(event);
        }
        if (!valid) return cancelled(ticket);
        {
            std::lock_guard<std::recursive_mutex> callbackLease(
                impl_->callbackMutex);
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket;
            }
            if (!valid) return cancelled(ticket);
            mapping = InvokeMapper(mapper, mappingKind, event);
        }

        std::vector<Emission> emissions;
        GlfwInputSink sink{};
        GlfwAdapterStatus eventStatus = GlfwAdapterStatus::kOk;
        valid = false;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            valid = impl_->incarnation == incarnation &&
                impl_->callbackFence == fence &&
                impl_->lifecycle == Impl::Lifecycle::kReady &&
                impl_->inFlight.active &&
                impl_->inFlight.ticket == ticket;
            if (valid) {
                sink = impl_->sink;
                impl_->BeginRollbackCheckpointLocked(event);
                eventStatus = impl_->ProcessEventLocked(
                    event, mapping, emissions,
                    IsBlobText(event.header.eventType) ? &textBytes : nullptr);
                if (eventStatus == GlfwAdapterStatus::kOk) {
                    if (emissions.empty()) {
                        impl_->inFlight = {};
                    } else {
                        impl_->inFlight.stage =
                            Impl::InFlight::Stage::kCommitted;
                    }
                }
            }
        }
        if (!valid) return cancelled(ticket);
        if (eventStatus != GlfwAdapterStatus::kOk) {
            return abandon(eventStatus, AMCL_INPUT_ERROR_INVALID_ARGUMENT);
        }

#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
        if (!emissions.empty()) {
            RunAdapterTestHook(
                GlfwInputAdapterTestSeam::kAfterCommitBeforeDispatch);
        }
#endif

        std::lock_guard<std::recursive_mutex> emissionLease(
            impl_->callbackMutex);
        for (const Emission& emission : emissions) {
            valid = false;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                valid = impl_->incarnation == incarnation &&
                    impl_->callbackFence == fence &&
                    impl_->lifecycle == Impl::Lifecycle::kReady &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket;
                if (valid) {
                    impl_->MarkEmissionDeliveredForRollbackLocked(emission);
                    impl_->inFlight.stage =
                        Impl::InFlight::Stage::kDispatching;
                    impl_->callbackActive = true;
                    impl_->callbackThread = std::this_thread::get_id();
                }
            }
            if (!valid) return cancelled(ticket);
            DispatchOne(sink, emission);
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->callbackActive &&
                    impl_->callbackThread == std::this_thread::get_id()) {
                    impl_->callbackActive = false;
                    impl_->callbackThread = {};
                }
            }
            impl_->callbackCondition.notify_all();
        }
        if (!emissions.empty()) {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            if (impl_->incarnation == incarnation &&
                impl_->inFlight.active &&
                impl_->inFlight.ticket == ticket) {
                impl_->inFlight = {};
            }
        }
    }
}

GlfwAdapterStatus GlfwInputAdapter::Close() {
    std::lock_guard<std::recursive_mutex> callbackLease(
        impl_->callbackMutex);
    std::unique_lock<std::mutex> lifecycleEntry(impl_->openMutex);
    const AmclInputHostApiV1* api = nullptr;
    AmclInputConsumerHandle consumer = 0u;
    GlfwInputMapper mapper{};
    GlfwInputSink sink{};
    uint64_t incarnation = 0u;
    uint64_t fence = 0u;
    uint64_t epoch = 0u;
    bool registered = false;
    bool retryAbandon = false;
    AmclInputEvent displaced{};
    bool hasDisplaced = false;
    {
        std::unique_lock<std::mutex> state(impl_->stateMutex);
        if (impl_->terminalCallbackBatchActive &&
            impl_->terminalCallbackThread == std::this_thread::get_id()) {
            // The outer terminal path has already detached the host handle but
            // still owns balanced releases. It is not closed to this callback
            // until that batch returns.
            return GlfwAdapterStatus::kNotReady;
        }
        if (impl_->callbackActive &&
            impl_->callbackThread != std::this_thread::get_id()) {
            state.unlock();
            lifecycleEntry.unlock();
            std::unique_lock<std::mutex> callbackWait(impl_->stateMutex);
            impl_->callbackCondition.wait(callbackWait, [&]() {
                return !impl_->callbackActive;
            });
            callbackWait.unlock();
            return Close();
        }
        if (impl_->lifecycle == Impl::Lifecycle::kClosed ||
            !impl_->api || impl_->consumer == 0u) {
            return GlfwAdapterStatus::kOk;
        }
        if (impl_->cleanupActive) {
            // The outer Close owns this retirement. A synchronous callback may
            // observe kNotReady, but it must not cancel the remaining balanced
            // release callbacks or mutate their rollback checkpoint.
            return GlfwAdapterStatus::kNotReady;
        }
        impl_->cleanupActive = true;
        retryAbandon = impl_->lifecycle == Impl::Lifecycle::kAbandoning;
        if (!retryAbandon) impl_->lifecycle = Impl::Lifecycle::kRetiring;
        ++impl_->callbackFence;
        fence = impl_->callbackFence;
        impl_->suppressCleanupCallbacks = false;
        if (impl_->inFlight.active) {
            displaced = impl_->inFlight.event;
            // Only a not-yet-dispatching record still owns its host blob; a
            // dispatching one has already been handed to the sink. This is a
            // narrower question than the discard predicate below, so the two
            // stay separate even though they agree on the kDispatching case.
            hasDisplaced = impl_->inFlight.ownsHostBlob;
            if (impl_->InFlightNeedsAccountedDiscardLocked()) {
                impl_->DiscardInFlightLocked();
            } else {
                impl_->inFlight = {};
            }
        }
        api = impl_->api;
        consumer = impl_->consumer;
        mapper = impl_->mapper;
        sink = impl_->sink;
        incarnation = impl_->incarnation;
        epoch = impl_->sessionEpoch;
        registered = impl_->backendRegistered;
        impl_->pumpActive = false;
    }
    lifecycleEntry.unlock();

    auto dispatchAllowed = [&]() {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        return impl_->incarnation == incarnation &&
            impl_->lifecycle == Impl::Lifecycle::kRetiring &&
            impl_->cleanupActive && !impl_->suppressCleanupCallbacks &&
            impl_->callbackFence == fence;
    };
    auto retainFailure = [&]() {
        std::lock_guard<std::mutex> state(impl_->stateMutex);
        if (impl_->incarnation == incarnation) impl_->cleanupActive = false;
        return GlfwAdapterStatus::kHostError;
    };
    auto finishClosed = [&](bool reportHostError) {
        std::vector<Emission> releases;
        GlfwInputSink releaseSink{};
        bool emit = false;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            if (impl_->incarnation != incarnation) {
                return GlfwAdapterStatus::kNotReady;
            }
            releaseSink = impl_->sink;
            emit = !impl_->suppressCleanupCallbacks;
            impl_->ClearAggregatesLocked(0u, 0u, releases);
            impl_->ClearAbsoluteRouteLocked();
            impl_->textSessionActive = false;
            impl_->textSessionId = 0u;
            impl_->deferredStartupEmissions.clear();
            impl_->api = nullptr;
            impl_->consumer = 0u;
            impl_->mapper = {};
            impl_->sink = {};
            impl_->sessionEpoch = 0u;
            impl_->lastSequence = 0u;
            impl_->absoluteRouteEnabled = false;
            impl_->lifecycle = Impl::Lifecycle::kClosed;
            impl_->backendRegistered = false;
            impl_->cleanupActive = false;
            impl_->suppressCleanupCallbacks = false;
            impl_->inFlight = {};
        }
        if (emit) impl_->DispatchTerminalCallbacks(releaseSink, releases);
        return reportHostError ? GlfwAdapterStatus::kHostError
                               : GlfwAdapterStatus::kOk;
    };
    auto abandonCleanup = [&](bool successfulRetryIsOk = false) {
        std::vector<Emission> releases;
        GlfwInputSink releaseSink{};
        uint32_t discarded = 0u;
        const int32_t result = impl_->AbandonIncarnation(
            incarnation, &discarded, &releases, &releaseSink);
        (void)discarded;
        impl_->DispatchTerminalCallbacks(releaseSink, releases);
        const bool completed = result == AMCL_INPUT_OK ||
            result == AMCL_INPUT_OVERFLOW_RESET ||
            result == AMCL_INPUT_ERROR_NOT_FOUND;
        return completed && successfulRetryIsOk
                   ? GlfwAdapterStatus::kOk
                   : GlfwAdapterStatus::kHostError;
    };

    if (retryAbandon) return abandonCleanup(true);

    if (hasDisplaced && IsBlobText(displaced.header.eventType)) {
        int32_t releaseStatus = AMCL_INPUT_ERROR_NOT_FOUND;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            releaseStatus = api->releasePacket(consumer,
                                                TextPacketId(displaced));
        }
        if (releaseStatus != AMCL_INPUT_OK &&
            releaseStatus != AMCL_INPUT_ERROR_NOT_FOUND) {
            return abandonCleanup();
        }
    }

    bool reportHostError = false;
    if (registered) {
        const AmclInputEvent retire = BackendConsumerControl(
            AMCL_INPUT_BACKEND_CONSUMER_RETIRE, epoch, consumer,
            impl_->backend);
        int32_t retireStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            retireStatus = api->submitEvent(&retire);
        }
        const bool drainable = retireStatus == AMCL_INPUT_OK ||
            retireStatus == AMCL_INPUT_OVERFLOW_RESET ||
            retireStatus == AMCL_INPUT_DRAIN_REQUIRED ||
            retireStatus == AMCL_INPUT_ERROR_STALE ||
            retireStatus == AMCL_INPUT_ERROR_SESSION ||
            retireStatus == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED ||
            retireStatus == AMCL_INPUT_ERROR_NOT_FOUND;
        if (!drainable) return abandonCleanup();
        reportHostError = retireStatus < AMCL_INPUT_OK &&
                          retireStatus != AMCL_INPUT_ERROR_STALE &&
                          retireStatus != AMCL_INPUT_ERROR_SESSION &&
                          retireStatus != AMCL_INPUT_ERROR_NOT_FOUND;
    } else {
        int32_t closeStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            closeStatus = api->closeConsumer(consumer);
        }
        if (IsTerminalConsumerStatus(closeStatus)) {
            return finishClosed(false);
        }
        if (closeStatus != AMCL_INPUT_DRAIN_REQUIRED) {
            return retainFailure();
        }
    }

    constexpr uint32_t kMaximumCleanupRecords = 4096u;
    uint32_t cleanupRecords = 0u;
    for (;;) {
        if (cleanupRecords > kMaximumCleanupRecords) {
            return abandonCleanup();
        }

        AmclInputEvent event{};
        int32_t nextStatus = AMCL_INPUT_ERROR_NOT_FOUND;
        uint64_t ticket = 0u;
        bool abandonedAfterFetch = false;
        int32_t abandonedBlobReleaseStatus = AMCL_INPUT_OK;
        {
            std::lock_guard<std::mutex> host(impl_->hostCallMutex);
            nextStatus = api->nextEvent(consumer, &event);
            if (nextStatus == AMCL_INPUT_OK) {
                // ⚠️ 刻意不叫 `registered`：本函数上方已有一个同名局部量,含义是
                // **后端是否已注册**(`impl_->backendRegistered`)。两者同名会让
                // 两处 `if (…)` 看起来在问同一件事,而它们问的是完全不同的事。
                // MSVC /W4 的 C4456 在 2026-08-23 第一次真正执行 host 断言时抓到了它。
                bool cleanupRecordTracked = false;
                {
                    std::lock_guard<std::mutex> state(impl_->stateMutex);
                    cleanupRecordTracked = impl_->incarnation == incarnation &&
                        impl_->lifecycle == Impl::Lifecycle::kRetiring &&
                        impl_->cleanupActive;
                    if (impl_->nextFetchTicket == 0u) {
                        impl_->nextFetchTicket = 1u;
                    }
                    ticket = impl_->nextFetchTicket++;
                    if (cleanupRecordTracked) {
                        impl_->inFlight =
                            {true, ticket, incarnation, event};
                        impl_->inFlight.ownsHostBlob =
                            IsBlobText(event.header.eventType);
                    } else {
                        // ⚠️ 2026-08-21: this branch used to be a bare
                        // `return kNotReady` taken **before** the record was
                        // registered, which made it the one fail-open exit in an
                        // otherwise uniformly fail-closed function: the record
                        // was already off the host queue, so its text blob was
                        // never released (a permanent host-side packet leak) and
                        // `discardedFetchedEvents` never moved, making the loss
                        // invisible. `Pump` has always handled the identical race
                        // correctly; the asymmetry survived because "Close holds
                        // callbackMutex for its whole body" made it unreachable
                        // in practice -- i.e. this layer's guarantee depended on
                        // another layer's, which spec §八.8 forbids relying on.
                        // Now it accounts for the discard and releases the blob
                        // exactly as `Pump` does. Unreachable today means this is
                        // a no-op today; it stops being a landmine tomorrow.
                        impl_->lastDiscardedTicket = ticket;
                        ++impl_->discardedFetchedEvents;
                        abandonedAfterFetch = true;
                    }
                }
                if (abandonedAfterFetch && IsBlobText(event.header.eventType)) {
                    // Still inside hostCallMutex, matching every other
                    // releasePacket call site in this function.
                    abandonedBlobReleaseStatus =
                        api->releasePacket(consumer, TextPacketId(event));
                }
            }
        }
        if (abandonedAfterFetch) {
            // The blob release status is intentionally not escalated to
            // kHostError: the caller is already tearing this incarnation down and
            // NOT_FOUND is the expected answer when the host retired the packet
            // with the consumer. It is recorded for the same reason `Pump`
            // records it -- so a genuine leak is distinguishable from a race.
            (void)abandonedBlobReleaseStatus;
            return GlfwAdapterStatus::kNotReady;
        }

        if (nextStatus == AMCL_INPUT_EMPTY ||
            nextStatus == AMCL_INPUT_ERROR_STALE ||
            nextStatus == AMCL_INPUT_ERROR_SESSION) {
            int32_t closeStatus = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            {
                std::lock_guard<std::mutex> host(impl_->hostCallMutex);
                closeStatus = api->closeConsumer(consumer);
            }
            if (IsTerminalConsumerStatus(closeStatus)) {
                return finishClosed(reportHostError);
            }
            if (closeStatus == AMCL_INPUT_DRAIN_REQUIRED) {
                ++cleanupRecords;
                continue;
            }
            return retainFailure();
        }
        if (nextStatus == AMCL_INPUT_ERROR_NOT_FOUND) {
            return finishClosed(reportHostError);
        }
        if (nextStatus == AMCL_INPUT_OVERFLOW_RESET) {
            std::vector<Emission> releases;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                impl_->ClearAggregatesLocked(0u, 0u, releases);
                impl_->absoluteAuthorization = {};
            }
            if (dispatchAllowed()) Dispatch(sink, releases);
            ++cleanupRecords;
            continue;
        }
        if (nextStatus != AMCL_INPUT_OK) return abandonCleanup();
        ++cleanupRecords;

        std::vector<uint8_t> textBytes;
        if (IsBlobText(event.header.eventType)) {
            TextBlobCopyResult copied;
            {
                std::lock_guard<std::mutex> host(impl_->hostCallMutex);
                copied = CopyAndReleaseTextBlob(api, consumer, event);
            }
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket) {
                    impl_->inFlight.ownsHostBlob = false;
                }
            }
            if (copied.status == TextBlobCopyStatus::kCancelled) {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket) {
                    impl_->DiscardInFlightLocked();
                }
                continue;
            }
            if (copied.status != TextBlobCopyStatus::kOk) {
                return abandonCleanup();
            }
            textBytes = std::move(copied.bytes);
        }

        bool suppress = false;
        MappingKind mappingKind = MappingKind::kNone;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            suppress = impl_->suppressCleanupCallbacks ||
                impl_->callbackFence != fence;
            if (!suppress) mappingKind = impl_->MappingRequiredLocked(event);
            if (suppress && impl_->inFlight.active &&
                impl_->inFlight.ticket == ticket) {
                impl_->DiscardInFlightLocked();
            }
        }
        if (suppress) continue;

        const PreparedMapping mapping = InvokeMapper(mapper, mappingKind, event);
        std::vector<Emission> emissions;
        GlfwAdapterStatus eventStatus = GlfwAdapterStatus::kOk;
        {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            if (impl_->suppressCleanupCallbacks ||
                impl_->callbackFence != fence ||
                !impl_->inFlight.active ||
                impl_->inFlight.ticket != ticket) {
                if (impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket) {
                    impl_->DiscardInFlightLocked();
                }
                continue;
            }
            impl_->BeginRollbackCheckpointLocked(event);
            eventStatus = impl_->ProcessEventLocked(
                event, mapping, emissions,
                IsBlobText(event.header.eventType) ? &textBytes : nullptr);
            if (eventStatus == GlfwAdapterStatus::kOk) {
                if (emissions.empty()) {
                    impl_->inFlight = {};
                } else {
                    impl_->inFlight.stage =
                        Impl::InFlight::Stage::kCommitted;
                }
            }
        }
        if (eventStatus != GlfwAdapterStatus::kOk) return abandonCleanup();

        for (const Emission& emission : emissions) {
            bool allowed = false;
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                allowed = impl_->incarnation == incarnation &&
                    impl_->lifecycle == Impl::Lifecycle::kRetiring &&
                    impl_->cleanupActive &&
                    !impl_->suppressCleanupCallbacks &&
                    impl_->callbackFence == fence &&
                    impl_->inFlight.active &&
                    impl_->inFlight.ticket == ticket;
                if (allowed) {
                    impl_->MarkEmissionDeliveredForRollbackLocked(emission);
                    impl_->inFlight.stage =
                        Impl::InFlight::Stage::kDispatching;
                    impl_->callbackActive = true;
                    impl_->callbackThread = std::this_thread::get_id();
                }
            }
            if (!allowed) break;
            DispatchOne(sink, emission);
            {
                std::lock_guard<std::mutex> state(impl_->stateMutex);
                if (impl_->callbackActive &&
                    impl_->callbackThread == std::this_thread::get_id()) {
                    impl_->callbackActive = false;
                    impl_->callbackThread = {};
                }
            }
            impl_->callbackCondition.notify_all();
        }
        if (!emissions.empty()) {
            std::lock_guard<std::mutex> state(impl_->stateMutex);
            if (impl_->inFlight.active &&
                impl_->inFlight.ticket == ticket) {
                impl_->inFlight = {};
            }
        }
    }
}

bool GlfwInputAdapter::IsReady() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->lifecycle == Impl::Lifecycle::kReady;
}

bool GlfwInputAdapter::IsKeyPressed(int32_t mappedKey) const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->keys.find(mappedKey) != impl_->keys.end();
}

bool GlfwInputAdapter::IsButtonPressed(int32_t mappedButton) const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->buttons.find(mappedButton) != impl_->buttons.end();
}

uint64_t GlfwInputAdapter::SessionEpoch() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->sessionEpoch;
}

bool GlfwInputAdapter::HasConsumer() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->consumer != 0u;
}

uint64_t GlfwInputAdapter::DiscardedFetchedEventCount() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->discardedFetchedEvents;
}

uint64_t GlfwInputAdapter::AbandonCount() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->abandonCount;
}

uint64_t GlfwInputAdapter::AbsoluteRouteDropCount() const {
    std::lock_guard<std::mutex> state(impl_->stateMutex);
    return impl_->absoluteRouteDrops;
}

}  // namespace amcl::input

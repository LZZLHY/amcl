#if AMCL_DESKTOP_EVENT_BRIDGE
extern "C" void amclDesktopNotifyInput();
#else
static void amclDesktopNotifyInput() {}
#endif
#include "input_state_core.h"
#include "adapters/glfw_input_mode.h"
#include "text_utf8_codec.h"
#include "runtime_desktop_capability.h"

#include <hilog/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <unordered_map>
#include <utility>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "INPUT_CORE"

#ifndef AMCL_INPUT_QUEUE_CAPACITY
#define AMCL_INPUT_QUEUE_CAPACITY 256u
#endif
#ifndef AMCL_INPUT_BLOB_POOL_CAPACITY
#define AMCL_INPUT_BLOB_POOL_CAPACITY 65536u
#endif

namespace amcl::input {
namespace {

constexpr size_t kQueueCapacity = AMCL_INPUT_QUEUE_CAPACITY;
constexpr size_t kBlobCapacity = AMCL_INPUT_BLOB_POOL_CAPACITY;
constexpr size_t kBlobPacketCapacity = kQueueCapacity;
constexpr uint32_t kTextMaxScalars =
    static_cast<uint32_t>(kTextCandidateMaxScalars);
constexpr uint64_t kConsumerGenerationShift = 48u;
constexpr uint64_t kConsumerIdMask = (UINT64_C(1) << kConsumerGenerationShift) - 1u;
constexpr uint64_t kConsumerGenerationMask = ~kConsumerIdMask;
// Internal-only sentinel. Public status 3 is AMCL_INPUT_DRAIN_REQUIRED, so an
// overlapping value would make SubmitEvent run a second overflow reset after a
// backend-retire close barrier.
constexpr int32_t kLifecycleOverflowHandled = 1001;
static_assert(kQueueCapacity >= 2, "input queue must hold reset+lifecycle");
static_assert(kBlobCapacity > 0, "input blob pool must have storage");
static_assert((AMCL_INPUT_HOST_API_GENERATION & ~UINT64_C(0xffff)) == 0,
              "host generation must fit consumer handles");

bool AdvanceNonZero(uint64_t& value) {
    if (value == UINT64_MAX) return false;
    ++value;
    return value != 0;
}

bool TakeNextNonZero(uint64_t& next, uint64_t* value) {
    if (!value || next == 0 || next == UINT64_MAX) return false;
    *value = next;
    ++next;
    return true;
}

uint64_t MakeConsumerHandle(uint64_t id) {
    return (AMCL_INPUT_HOST_API_GENERATION << kConsumerGenerationShift) |
           (id & kConsumerIdMask);
}

bool HasCurrentConsumerGeneration(AmclInputConsumerHandle handle) {
    const uint64_t expected =
        AMCL_INPUT_HOST_API_GENERATION << kConsumerGenerationShift;
    return (handle & kConsumerGenerationMask) == expected;
}

uint64_t NowNs() {
    const auto value = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(value).count());
}

bool IsTextBlobType(uint32_t type) {
    return type == AMCL_INPUT_EVENT_TEXT_COMMIT ||
           type == AMCL_INPUT_EVENT_TEXT_EDITING ||
           type == AMCL_INPUT_EVENT_TEXT_CANDIDATES;
}

bool IsTextSessionType(uint32_t type) {
    return type == AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
}

bool IsTextType(uint32_t type) {
    return IsTextBlobType(type) || type == AMCL_INPUT_EVENT_TEXT_SELECTION ||
           IsTextSessionType(type);
}

bool IsOrdinaryInput(uint32_t type) {
    return type == AMCL_INPUT_EVENT_PHYSICAL_KEY ||
           type == AMCL_INPUT_EVENT_POINTER_ABSOLUTE ||
           type == AMCL_INPUT_EVENT_POINTER_RELATIVE ||
           type == AMCL_INPUT_EVENT_POINTER_BUTTON ||
           type == AMCL_INPUT_EVENT_POINTER_WHEEL ||
           type == AMCL_INPUT_EVENT_POINTER_ENTER || IsTextType(type);
}

bool IsGlfwPhysicalInput(uint32_t type) {
    return type == AMCL_INPUT_EVENT_PHYSICAL_KEY ||
           type == AMCL_INPUT_EVENT_POINTER_ABSOLUTE ||
           type == AMCL_INPUT_EVENT_POINTER_RELATIVE ||
           type == AMCL_INPUT_EVENT_POINTER_BUTTON ||
           type == AMCL_INPUT_EVENT_POINTER_WHEEL ||
           type == AMCL_INPUT_EVENT_POINTER_ENTER;
}

bool TextEventNeedsReadyBackend(const AmclInputEvent& event) {
    if (IsTextBlobType(event.header.eventType) ||
        event.header.eventType == AMCL_INPUT_EVENT_TEXT_SELECTION) {
        return true;
    }
    return event.header.eventType == AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED &&
           event.payload.textSession.change == AMCL_INPUT_TEXT_SESSION_STARTED;
}

uint64_t TextSessionId(const AmclInputEvent& event) {
    switch (event.header.eventType) {
        case AMCL_INPUT_EVENT_TEXT_COMMIT:
            return event.payload.textCommit.textSessionId;
        case AMCL_INPUT_EVENT_TEXT_EDITING:
            return event.payload.textEditing.textSessionId;
        case AMCL_INPUT_EVENT_TEXT_CANDIDATES:
            return event.payload.textCandidates.textSessionId;
        case AMCL_INPUT_EVENT_TEXT_SELECTION:
            return event.payload.textSelection.textSessionId;
        case AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED:
            return event.payload.textSession.textSessionId;
        default:
            return 0u;
    }
}

bool IsZeroBlobRef(const AmclInputBlobRef& blob) {
    return blob.packetId == 0u && blob.offset == 0u && blob.length == 0u;
}

bool IsPointerSample(uint32_t type) {
    return type == AMCL_INPUT_EVENT_POINTER_ABSOLUTE ||
           type == AMCL_INPUT_EVENT_POINTER_RELATIVE ||
           type == AMCL_INPUT_EVENT_POINTER_BUTTON ||
           type == AMCL_INPUT_EVENT_POINTER_WHEEL;
}

bool IsKnownDeviceClass(uint32_t deviceClass) {
    return deviceClass < AMCL_INPUT_DEVICE_CLASS_COUNT;
}

bool IsResetReason(uint32_t reason) {
    return reason >= AMCL_INPUT_RESET_EXPLICIT &&
           reason <= AMCL_INPUT_RESET_BACKEND_ABANDONED;
}

int32_t CopyKnownEvent(const AmclInputEvent* input, AmclInputEvent* output) {
    if (!input || !output) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if (input->header.abiVersion != AMCL_INPUT_EVENT_ABI_VERSION ||
        input->header.structSize < sizeof(AmclInputEvent)) {
        return AMCL_INPUT_ERROR_ABI_MISMATCH;
    }
    std::memcpy(output, input, sizeof(*output));
    output->header.structSize = static_cast<uint16_t>(sizeof(*output));
    return AMCL_INPUT_OK;
}

bool IsAbsolutePositionBoundButton(const AmclInputEvent& event) {
    return event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON &&
        (event.header.flags &
         AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u;
}

bool HasMatchingAbsolutePredecessor(
        const std::vector<AmclInputEvent>& events, uint32_t index) {
    if (index == 0u || !IsAbsolutePositionBoundButton(events[index])) {
        return false;
    }
    const AmclInputEvent& absolute = events[index - 1u];
    const AmclInputEvent& button = events[index];
    return absolute.header.eventType == AMCL_INPUT_EVENT_POINTER_ABSOLUTE &&
        absolute.header.source == button.header.source &&
        absolute.header.deviceId == button.header.deviceId &&
        absolute.header.deviceClass == button.header.deviceClass &&
        absolute.header.sessionEpoch == button.header.sessionEpoch &&
        absolute.header.focusEpoch == button.header.focusEpoch &&
        absolute.header.surfaceEpoch == button.header.surfaceEpoch;
}

struct HeldId {
    uint64_t deviceId;
    uint32_t kind;
    uint32_t code;
    bool operator<(const HeldId& other) const {
        if (deviceId != other.deviceId) return deviceId < other.deviceId;
        if (kind != other.kind) return kind < other.kind;
        return code < other.code;
    }
};

struct HeldControl { AmclInputEvent downEvent; };
struct DeviceRecord {
    uint32_t capabilities = 0u;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;

    bool operator==(const DeviceRecord& other) const {
        return capabilities == other.capabilities &&
               deviceClass == other.deviceClass;
    }
};
// ⚠️ 枚举名里的 Glfw 字样是历史的：这两个角色对**每一个后端**都成立（LWJGL2 / GLFW3 /
// SDL3 各有自己的 READY/RETIRING 槽）。刻意不改名，因为它出现在四十余处并被多个 host
// 测试按名断言；真正承重的是 `ConsumerState::backend`，它说明这个角色属于哪个后端。
enum class ConsumerBackendRole : uint8_t {
    None = 0,
    GlfwReady = 1,
    GlfwRetiring = 2,
};

struct ConsumerState {
    uint64_t sessionEpoch;
    uint64_t generation;
    std::deque<AmclInputEvent> pendingControl;
    uint64_t baselineSequence = 0;
    bool baselineConsumed = false;
    bool acceptingEvents = true;
    ConsumerBackendRole backendRole = ConsumerBackendRole::None;
    // 0 = 还没申领任何后端角色。非 0 时必须是 AMCL_INPUT_BACKEND_* 之一，
    // 且与 `backendSlots[backend - 1]` 互为唯一：槽记 handle，这里记 backend。
    uint32_t backend = 0;
};

// 一个后端的 READY/RETIRING 两个槽。**每个后端一份**是这次重构的核心：
// 三个后端不是三种实现选择，而是三个 MC 世代各自的 ABI 契约，它们会在不同的进程里
// 同时是"当前那一个"，所以退休屏障必须按后端隔离 —— 用一个共享槽的后果是第二个后端
// 申领 READY 时拿到 RESOURCE_EXHAUSTED，而那看起来像"资源不够"，实际是"这里只能有一个"。
struct BackendSlot {
    uint64_t ready = 0;
    uint64_t retiring = 0;
};

bool IsKnownBackend(uint32_t backend) {
    return backend >= AMCL_INPUT_BACKEND_GLFW_PHYSICAL &&
           backend < AMCL_INPUT_BACKEND_COUNT;
}
struct EventRecord { AmclInputEvent event; std::set<uint64_t> recipients; };
struct PacketRecord { std::vector<uint8_t> data; std::set<uint64_t> owners; };

AmclInputEvent BlankEvent(uint32_t type) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = type;
    return event;
}

bool HasValidActiveDimensions(const AmclInputSurfacePayload& surface) {
    return surface.active != 0u &&
           (surface.validFields & AMCL_INPUT_SURFACE_FIELD_DIMENSIONS) != 0u &&
           surface.widthPx != 0u && surface.heightPx != 0u;
}

bool SameSurface(const AmclInputSurfacePayload& a,
                 const AmclInputSurfacePayload& b) {
    const uint32_t aValid = a.validFields & AMCL_INPUT_SURFACE_FIELD_ALL;
    const uint32_t bValid = b.validFields & AMCL_INPUT_SURFACE_FIELD_ALL;
    if (a.active != b.active || aValid != bValid) return false;
    if ((aValid & AMCL_INPUT_SURFACE_FIELD_DIMENSIONS) != 0u &&
        (a.widthPx != b.widthPx || a.heightPx != b.heightPx)) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_FIELD_TRANSFORM) != 0u &&
        a.transform != b.transform) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_FIELD_DENSITY) != 0u &&
        a.density != b.density) {
        return false;
    }
    return (aValid & AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION) == 0u ||
           a.publicationGeneration == b.publicationGeneration;
}

bool SameSurfaceContext(const AmclInputSurfaceContextPayload& a,
                        const AmclInputSurfaceContextPayload& b) {
    const uint32_t aValid =
        a.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    const uint32_t bValid =
        b.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    if (aValid != bValid || a.generation != b.generation) return false;
    if ((aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW) != 0u &&
        a.windowId != b.windowId) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY) != 0u &&
        a.displayId != b.displayId) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u &&
        (a.leftPx != b.leftPx || a.topPx != b.topPx ||
         a.widthPx != b.widthPx || a.heightPx != b.heightPx)) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
        a.density != b.density) {
        return false;
    }
    if ((aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u &&
        a.transform != b.transform) {
        return false;
    }
    return (aValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) == 0u ||
           a.refreshRateHz == b.refreshRateHz;
}

}  // namespace

struct InputStateCore::Impl {
    explicit Impl(bool requireReady, bool requireText)
        : requireGlfwReady(requireReady), requireTextReady(requireText) {}

    std::mutex mutex;
    std::deque<EventRecord> queue;
    std::map<HeldId, HeldControl> held;
    std::unordered_map<uint64_t, ConsumerState> consumers;
    std::unordered_map<uint64_t, PacketRecord> packets;
    // Ordered so late-consumer DEVICE_ADDED baseline replay is deterministic.
    std::map<uint64_t, DeviceRecord> devices;
    uint64_t nextSequence = 1;
    uint64_t nextConsumer = 1;
    uint64_t nextPacket = 1;
    uint64_t sessionEpoch = 0;
    uint64_t focusEpoch = 0;
    uint64_t surfaceEpoch = 0;
    uint64_t overflowResetCount = 0;
    // 索引 = backend - 1。槽 0 是 GLFW3，1 是 LWJGL2，2 是 SDL3。
    BackendSlot backendSlots[AMCL_INPUT_BACKEND_COUNT - 1u]{};
    uint64_t lastTimeNs = 0;
    size_t blobBytes = 0;
    bool focused = false;
    bool captureActive = false;
    bool sessionActive = false;
    bool hasSurface = false;
    bool hasSurfaceContext = false;
    bool textSessionActive = false;
    const bool requireGlfwReady;
    const bool requireTextReady;
    uint64_t textSessionId = 0;
    AmclInputSurfacePayload surface{};
    AmclInputSurfaceContextPayload surfaceContext{};
    AmclInputCapturePayload capture{};

    // §11 accumulators. Only values that must be summed over time live here;
    // anything derivable from authoritative state (held counts, epochs, last
    // sequence) is computed in GetObservability so this can never drift into
    // being a second owner of that state. All mutation happens under `mutex`,
    // which every Impl method already holds, so these are plain integers.
    //
    // Session scope: BeginSession clears these. `overflowResetCount` above is
    // deliberately NOT one of them -- it is process-lifetime because
    // AmclInputSnapshotV1 has always exported it that way and the batch rollback
    // path saves/restores it. The two scopes are reported as separate fields
    // rather than merged into one ambiguous number.
    struct Observability {
        uint64_t physicalDown = 0;
        uint64_t physicalRepeat = 0;
        uint64_t physicalUp = 0;
        uint64_t physicalUpSynthetic = 0;
        uint64_t diagnosticDrops = 0;
        uint64_t maxHeldControlCount = 0;
        uint64_t maxHeldOwnerDeviceCount = 0;
        uint64_t heldDroppedWithoutRelease = 0;
        uint64_t accepted = 0;
        uint64_t queueWrites = 0;
        uint64_t acceptedWithoutRecipient = 0;
        uint64_t queueDeliveries = 0;
        uint64_t queueReads = 0;
        uint64_t queueDiscarded = 0;
        uint64_t overflowResets = 0;
        uint64_t resetsEmitted = 0;
        uint64_t captureRequested = 0;
        uint64_t captureActivated = 0;
        uint64_t captureLost = 0;
        uint64_t captureLostByReason[AMCL_INPUT_CAPTURE_REASON_COUNT] = {};
        uint64_t captureLostUnknownReason = 0;
        uint64_t textCommits = 0;
        uint64_t textEdits = 0;
        uint64_t textCandidates = 0;
        uint64_t textSelections = 0;
        uint64_t textSessionStarts = 0;
        uint64_t textSessionEnds = 0;
        uint64_t textSessionAborts = 0;
    };
    Observability obs;

    size_t HeldOwnerDeviceCount() const {
        // `held` is keyed by HeldId, which orders by deviceId first, so entries
        // of one device are contiguous and a single pass suffices. This depends
        // on that ordering; switching `held` to an unordered container must
        // replace this with a set-based count.
        size_t owners = 0;
        uint64_t previous = 0;
        bool seen = false;
        for (const auto& entry : held) {
            if (!seen || entry.first.deviceId != previous) {
                ++owners;
                previous = entry.first.deviceId;
                seen = true;
            }
        }
        return owners;
    }

    void CountPhysicalActionLocked(uint32_t action, bool synthetic) {
        switch (action) {
            case AMCL_INPUT_ACTION_DOWN: ++obs.physicalDown; break;
            case AMCL_INPUT_ACTION_REPEAT: ++obs.physicalRepeat; break;
            case AMCL_INPUT_ACTION_UP:
                ++obs.physicalUp;
                if (synthetic) ++obs.physicalUpSynthetic;
                break;
            default:
                // Unreachable: ValidatePayload rejects other actions before an
                // event can reach Append. Counting nothing is the safe branch --
                // inventing a bucket would make a validation regression look
                // like ordinary traffic.
                break;
        }
    }

    // Drops every held control WITHOUT emitting the synthetic UP that
    // AppendReleases would. Capacity- and sequence-exhaustion paths have to do
    // this: they have no budget left to emit anything per control. §11 forbids
    // silent drops, so the loss is counted instead of being invisible -- and it
    // is what makes the down/up ledger close (see CoreObservabilityV1).
    //
    // Safe to call on paths that already released: `held` is empty there, so the
    // counter takes zero. Do NOT use it inside AppendReleases, whose clear()
    // follows real releases.
    void DiscardHeldWithoutReleaseLocked() {
        obs.heldDroppedWithoutRelease += static_cast<uint64_t>(held.size());
        held.clear();
    }

    // Deliveries that were promised at enqueue time and will never happen.
    // Counted in the same unit as queueReads (one recipient slot = one read), so
    // the §11 queue ledger closes. See CoreObservabilityV1 for the identity.
    void CountDiscardedDeliveriesLocked(size_t deliveries) {
        obs.queueDiscarded += static_cast<uint64_t>(deliveries);
    }

    size_t PendingDeliveriesLocked() const {
        size_t pending = 0;
        for (const auto& record : queue) pending += record.recipients.size();
        for (const auto& entry : consumers) {
            pending += entry.second.pendingControl.size();
        }
        return pending;
    }

    // Drops the whole shared queue (overflow paths). Everything still owed to a
    // recipient becomes a counted discard.
    void DiscardQueuedRecordsLocked() {
        size_t owed = 0;
        for (const auto& record : queue) owed += record.recipients.size();
        CountDiscardedDeliveriesLocked(owed);
        queue.clear();
    }

    // Removes one consumer from every queued record. Each erase is one delivery
    // that was owed and will not happen -- distinct from Prune(), which also
    // removes records whose recipients were emptied by real reads.
    void DropConsumerFromQueueLocked(uint64_t consumer) {
        size_t owed = 0;
        for (auto& record : queue) {
            owed += record.recipients.erase(consumer);
        }
        CountDiscardedDeliveriesLocked(owed);
    }

    void CountCaptureLocked(const AmclInputCapturePayload& payload) {
        if (payload.requested != 0u) ++obs.captureRequested;
        if (payload.active != 0u) {
            ++obs.captureActivated;
            return;
        }
        // active == 0 with reason NONE is a neutral/never-granted publication,
        // not a loss. Counting it would make "capture was never granted"
        // indistinguishable from "capture was taken away", which is precisely
        // the distinction §11 asks the reason bucket to preserve.
        if (payload.reason == AMCL_INPUT_CAPTURE_REASON_NONE) return;
        ++obs.captureLost;
        if (payload.reason < AMCL_INPUT_CAPTURE_REASON_COUNT) {
            ++obs.captureLostByReason[payload.reason];
        } else {
            ++obs.captureLostUnknownReason;
        }
    }

    // Called once per event core stamped with a sequence, from the single Append
    // seam. `event` is the post-Stamp copy, so the action counted is the one a
    // consumer will observe (a duplicate DOWN has already become REPEAT).
    void CountAcceptedLocked(const AmclInputEvent& event, bool synthetic) {
        ++obs.accepted;
        // Held mutation already happened for ordinary edges (emplace/erase both
        // precede Append), so this observes the post-edge counts. AppendReleases
        // clears `held` only after its loop, but a release can never set a new
        // high-water mark: the matching DOWN already did.
        const uint64_t controls = static_cast<uint64_t>(held.size());
        const uint64_t owners = static_cast<uint64_t>(HeldOwnerDeviceCount());
        if (controls > obs.maxHeldControlCount) {
            obs.maxHeldControlCount = controls;
        }
        if (owners > obs.maxHeldOwnerDeviceCount) {
            obs.maxHeldOwnerDeviceCount = owners;
        }
        switch (event.header.eventType) {
            case AMCL_INPUT_EVENT_PHYSICAL_KEY:
                CountPhysicalActionLocked(event.payload.physicalKey.action,
                                          synthetic);
                break;
            case AMCL_INPUT_EVENT_POINTER_BUTTON:
                CountPhysicalActionLocked(event.payload.pointerButton.action,
                                          synthetic);
                break;
            case AMCL_INPUT_EVENT_DIAGNOSTIC_DROP:
                ++obs.diagnosticDrops;
                break;
            case AMCL_INPUT_EVENT_RESET:
                ++obs.resetsEmitted;
                break;
            case AMCL_INPUT_EVENT_CAPTURE_CHANGED:
                CountCaptureLocked(event.payload.capture);
                break;
            case AMCL_INPUT_EVENT_TEXT_COMMIT: ++obs.textCommits; break;
            case AMCL_INPUT_EVENT_TEXT_EDITING: ++obs.textEdits; break;
            case AMCL_INPUT_EVENT_TEXT_CANDIDATES: ++obs.textCandidates; break;
            case AMCL_INPUT_EVENT_TEXT_SELECTION: ++obs.textSelections; break;
            case AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED:
                if (event.payload.textSession.reason ==
                    AMCL_INPUT_TEXT_SESSION_REASON_NONE) {
                    break;
                }
                if (event.payload.textSession.change ==
                    AMCL_INPUT_TEXT_SESSION_STARTED) {
                    ++obs.textSessionStarts;
                } else if (event.payload.textSession.change ==
                           AMCL_INPUT_TEXT_SESSION_ENDED) {
                    ++obs.textSessionEnds;
                } else {
                    ++obs.textSessionAborts;
                }
                break;
            default: break;
        }
    }

    // Derived fields are computed here rather than stored, so `obs` can never
    // become a second owner of held/epoch/sequence state.
    CoreObservabilityV1 SnapshotObservabilityLocked() const {
        CoreObservabilityV1 out{};
        out.sessionEpoch = sessionEpoch;
        out.focusEpoch = focusEpoch;
        out.surfaceEpoch = surfaceEpoch;
        // `nextSequence` is what the next Stamp will take, so the last one
        // actually issued is one below it. Sequences are always non-zero
        // (TakeNextNonZero), so reporting 0 unambiguously means "nothing
        // stamped yet" rather than "sequence 0".
        out.lastSequence = nextSequence > 1u ? nextSequence - 1u : 0u;
        out.lastMonotonicTimeNs = lastTimeNs;
        // ⚠️ 这两个字段是**单值**，而后端角色已经按后端分槽（三个）。刻意保留它们的
        // 语义为"**GLFW3 那一槽**"而不是"任意一个"：观测面 ABI 有 static_assert 钉住
        // 布局，而"任意一个"会让同一个字段在不同 MC 世代指向不同后端 —— 那正是
        // "一个计数器只对它实际采样到的那个状态成立"（规范 §八 推论 f）要防的形状。
        // 需要看另外两个后端时读日志里的 backendReadyMask。
        const BackendSlot& glfw =
            backendSlots[AMCL_INPUT_BACKEND_GLFW_PHYSICAL - 1u];
        out.backendConsumer = glfw.ready;
        out.backendRetiringConsumer = glfw.retiring;

        out.physicalDown = obs.physicalDown;
        out.physicalRepeat = obs.physicalRepeat;
        out.physicalUp = obs.physicalUp;
        out.physicalUpSynthetic = obs.physicalUpSynthetic;
        out.heldDroppedWithoutRelease = obs.heldDroppedWithoutRelease;
        out.diagnosticDrops = obs.diagnosticDrops;

        out.heldControlCount = static_cast<uint64_t>(held.size());
        out.heldOwnerDeviceCount =
            static_cast<uint64_t>(HeldOwnerDeviceCount());
        out.maxHeldControlCount = obs.maxHeldControlCount;
        out.maxHeldOwnerDeviceCount = obs.maxHeldOwnerDeviceCount;

        out.accepted = obs.accepted;
        out.queueWrites = obs.queueWrites;
        out.acceptedWithoutRecipient = obs.acceptedWithoutRecipient;
        out.queueDeliveries = obs.queueDeliveries;
        out.queueReads = obs.queueReads;
        out.queueDiscarded = obs.queueDiscarded;
        out.queuePending = static_cast<uint64_t>(PendingDeliveriesLocked());
        out.queueOverflowResets = obs.overflowResets;
        out.resetsEmitted = obs.resetsEmitted;

        out.captureRequested = obs.captureRequested;
        out.captureActivated = obs.captureActivated;
        out.captureLost = obs.captureLost;
        for (size_t i = 0; i < AMCL_INPUT_CAPTURE_REASON_COUNT; ++i) {
            out.captureLostByReason[i] = obs.captureLostByReason[i];
        }
        out.captureLostUnknownReason = obs.captureLostUnknownReason;

        out.textCommits = obs.textCommits;
        out.textEdits = obs.textEdits;
        out.textCandidates = obs.textCandidates;
        out.textSelections = obs.textSelections;
        out.textSessionStarts = obs.textSessionStarts;
        out.textSessionEnds = obs.textSessionEnds;
        out.textSessionAborts = obs.textSessionAborts;
        return out;
    }

    // Callers must already hold `mutex`. EndSession needs this because it emits
    // the summary inside its own critical section; taking the mutex again there
    // would self-deadlock on a non-recursive std::mutex.
    void LogObservabilityLocked(const char* reason);

    std::set<uint64_t> CurrentRecipients() const {
        std::set<uint64_t> result;
        for (const auto& entry : consumers) {
            if (entry.second.generation == AMCL_INPUT_HOST_API_GENERATION &&
                entry.second.sessionEpoch == sessionEpoch && sessionActive &&
                entry.second.acceptingEvents) {
                result.insert(entry.first);
            }
        }
        return result;
    }

    bool HasSequenceBudget(size_t required) const {
        if (required == 0u) return true;
        return nextSequence != 0u && nextSequence != UINT64_MAX &&
               static_cast<uint64_t>(required) <= UINT64_MAX - nextSequence;
    }

    bool Stamp(AmclInputEvent& event, uint64_t transactionTime,
               bool synthetic) {
        uint64_t sequence = 0;
        if (!TakeNextNonZero(nextSequence, &sequence)) return false;
        event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
        event.header.structSize = static_cast<uint16_t>(sizeof(event));
        event.header.sequence = sequence;
        uint64_t eventTime = transactionTime;
        if (!synthetic &&
            (event.header.flags &
             AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u) {
            eventTime = event.header.monotonicTimeNs;
        } else {
            // Recovery releases/resets have no platform sample of their own.
            // In particular, do not reuse the DOWN timestamp copied from a held
            // record when synthesizing its UP.
            event.header.flags &= ~AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
        }
        lastTimeNs = std::max(lastTimeNs, eventTime);
        event.header.monotonicTimeNs = lastTimeNs;
        event.header.sessionEpoch = sessionEpoch;
        event.header.focusEpoch = focusEpoch;
        event.header.surfaceEpoch = surfaceEpoch;
        if (synthetic) {
            event.header.flags |= AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
            event.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
        }
        return true;
    }

    bool Append(AmclInputEvent event, uint64_t transactionTime,
                bool synthetic) {
        if (!Stamp(event, transactionTime, synthetic)) return false;
        // §11 accounting for every event that reaches the shared queue through
        // Append. There are exactly three stamping paths, and each accounts for
        // itself because there is no automatic hook:
        //   1. Append (here)
        //   2. SubmitTextPacket  -- interleaves blob allocation with the sequence
        //   3. OpenConsumer      -- stamps into the per-consumer control channel
        // A future direct Stamp caller must call CountAcceptedLocked too; grep
        // for it when adding one, and grep for `Stamp(` when auditing.
        //
        // Counting after Stamp (not before) means a sequence-exhausted event is
        // not reported as accepted, matching the false return the caller turns
        // into AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED.
        CountAcceptedLocked(event, synthetic);
        std::set<uint64_t> recipients = CurrentRecipients();
        if (!recipients.empty()) {
            ++obs.queueWrites;
            obs.queueDeliveries += static_cast<uint64_t>(recipients.size());
            queue.push_back(EventRecord{event, std::move(recipients)});
        } else {
            // Not a drop: held state already moved and the sequence was spent.
            // It is tracked apart from queueWrites so "nobody was listening"
            // cannot be mistaken for "the queue lost an event".
            ++obs.acceptedWithoutRecipient;
        }
        return true;
    }

    void Prune() {
        queue.erase(std::remove_if(queue.begin(), queue.end(),
                    [](const EventRecord& record) {
                        return record.recipients.empty();
                    }), queue.end());
        for (auto it = packets.begin(); it != packets.end();) {
            if (it->second.owners.empty()) {
                blobBytes -= it->second.data.size();
                it = packets.erase(it);
            } else {
                ++it;
            }
        }
    }

    void DropTextPackets() {
        packets.clear();
        blobBytes = 0;
        // Undelivered text records die here on every reset. They were counted as
        // queue writes, so §11's no-silent-drop rule needs the loss recorded.
        size_t owed = 0;
        for (const auto& record : queue) {
            if (IsTextType(record.event.header.eventType)) {
                owed += record.recipients.size();
            }
        }
        CountDiscardedDeliveriesLocked(owed);
        queue.erase(std::remove_if(queue.begin(), queue.end(),
                    [](const EventRecord& record) {
                        return IsTextType(record.event.header.eventType);
                    }), queue.end());
        textSessionActive = false;
        textSessionId = 0u;
    }

    bool EnsureSpace(size_t required) {
        Prune();
        if (CurrentRecipients().empty()) return true;
        return required <= kQueueCapacity &&
               queue.size() + required <= kQueueCapacity;
    }

    bool HasSpaceAfterDroppingText(size_t required) const {
        if (CurrentRecipients().empty()) return true;
        const size_t retained = static_cast<size_t>(std::count_if(
            queue.begin(), queue.end(), [](const EventRecord& record) {
                return !record.recipients.empty() &&
                       !IsTextType(record.event.header.eventType);
            }));
        return required <= kQueueCapacity &&
               retained + required <= kQueueCapacity;
    }

    bool OverflowReset(uint64_t transactionTime,
                       uint32_t reason = AMCL_INPUT_RESET_QUEUE_OVERFLOW) {
        if (!HasSequenceBudget(1u)) return false;
        DiscardHeldWithoutReleaseLocked();
        captureActive = false;
        capture = AmclInputCapturePayload{};
        packets.clear();
        blobBytes = 0;
        textSessionActive = false;
        textSessionId = 0u;
        DiscardQueuedRecordsLocked();
        ++overflowResetCount;
        ++obs.overflowResets;
        AmclInputEvent reset = BlankEvent(AMCL_INPUT_EVENT_RESET);
        reset.payload.reset.reason = reason;
        reset.payload.reset.closingEpoch = sessionEpoch;
        return Append(reset, transactionTime, true);
    }

    size_t ReleaseCount(uint64_t onlyDevice, bool filterDevice) const {
        if (!filterDevice) return held.size();
        return HeldForDevice(onlyDevice);
    }

    bool AppendReleases(uint64_t onlyDevice, bool filterDevice,
                        uint64_t transactionTime) {
        if (!HasSequenceBudget(ReleaseCount(onlyDevice, filterDevice))) {
            return false;
        }
        for (const auto& entry : held) {
            if (filterDevice && entry.first.deviceId != onlyDevice) continue;
            AmclInputEvent release = entry.second.downEvent;
            // A lifecycle-generated release has no immediately preceding
            // surface-local absolute sample. Retaining the producer's
            // position-bound flag would make a fail-closed adapter discard
            // the very release intended to clear downstream held state.
            release.header.flags &=
                ~AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
            release.header.flags |= AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
            if (entry.first.kind == AMCL_INPUT_EVENT_PHYSICAL_KEY) {
                release.payload.physicalKey.action = AMCL_INPUT_ACTION_UP;
            } else {
                release.payload.pointerButton.action = AMCL_INPUT_ACTION_UP;
            }
            if (!Append(release, transactionTime, true)) return false;
        }
        if (filterDevice) {
            for (auto it = held.begin(); it != held.end();) {
                if (it->first.deviceId == onlyDevice) it = held.erase(it);
                else ++it;
            }
        } else {
            held.clear();
        }
        return true;
    }

    size_t HeldForDevice(uint64_t deviceId) const {
        return static_cast<size_t>(std::count_if(
            held.begin(), held.end(), [deviceId](const auto& entry) {
                return entry.first.deviceId == deviceId;
            }));
    }

    void ClearSessionState() {
        held.clear();
        packets.clear();
        blobBytes = 0;
        devices.clear();
        focused = false;
        captureActive = false;
        capture = AmclInputCapturePayload{};
        hasSurface = false;
        surface = AmclInputSurfacePayload{};
        hasSurfaceContext = false;
        surfaceContext = AmclInputSurfaceContextPayload{};
        textSessionActive = false;
        textSessionId = 0u;
    }

    bool HasPendingForConsumer(uint64_t consumer) const {
        const auto state = consumers.find(consumer);
        if (state == consumers.end()) return false;
        if (!state->second.pendingControl.empty()) return true;
        for (const auto& record : queue) {
            if (record.recipients.count(consumer) != 0u) return true;
        }
        for (const auto& packet : packets) {
            if (packet.second.owners.count(consumer) != 0u) return true;
        }
        return false;
    }

    // 槽访问器。`backend` 越界一律返回 nullptr，调用方必须判空 —— 越界写会把一个
    // 后端的退休屏障挂到另一个后端上，而那种错误在真机上表现为"另一条后端莫名收不到事件"。
    BackendSlot* SlotFor(uint32_t backend) {
        if (!IsKnownBackend(backend)) return nullptr;
        return &backendSlots[backend - 1u];
    }
    const BackendSlot* SlotFor(uint32_t backend) const {
        if (!IsKnownBackend(backend)) return nullptr;
        return &backendSlots[backend - 1u];
    }
    BackendSlot* SlotForConsumer(uint64_t consumer) {
        const auto state = consumers.find(consumer);
        if (state == consumers.end()) return nullptr;
        return SlotFor(state->second.backend);
    }
    // 生产者闸门用"**任一**后端已 READY"。刻意不是"全部 READY"：三个后端里只有当前
    // MC 世代那一个会存在消费者，要求全部就等于永远不放行。闸门原本要挡的是
    // "事件在任何消费者建立基线之前就被接收然后丢掉"，"任一"完整保留了这条保护。
    bool AnyBackendReady() const {
        for (const auto& slot : backendSlots) {
            if (slot.ready != 0u) return true;
        }
        return false;
    }

    uint32_t BackendReadyMask() const {
        uint32_t mask = 0u;
        for (uint32_t i = 0; i < AMCL_INPUT_BACKEND_COUNT - 1u; ++i) {
            if (backendSlots[i].ready != 0u) mask |= (1u << i);
        }
        return mask;
    }

    // 会话边界要退休**全部**已 READY 的后端，不只是 GLFW3 那一个。单槽时代这里是
    // `if (glfwReadyConsumer) Mark(...)`，直接照搬会让另外两个后端跨会话保持 READY，
    // 而它们的 held 已经在 ClearSessionState 里被清掉 ⇒ 一个没有 DOWN 的 UP。
    void RetireAllReadyBackends() {
        for (uint32_t i = 0; i < AMCL_INPUT_BACKEND_COUNT - 1u; ++i) {
            const uint64_t ready = backendSlots[i].ready;
            if (ready != 0u) MarkGlfwRetiring(ready);
        }
    }

    void MarkGlfwRetiring(uint64_t consumer) {
        const auto state = consumers.find(consumer);
        if (state == consumers.end()) return;
        BackendSlot* slot = SlotFor(state->second.backend);
        state->second.acceptingEvents = false;
        state->second.backendRole = ConsumerBackendRole::GlfwRetiring;
        if (!slot) return;
        if (slot->ready == consumer) slot->ready = 0;
        slot->retiring = consumer;
    }

    // Linearization barrier for a live typed backend. Existing records retain
    // their recipient set. Synthetic releases plus RESET are appended while the
    // consumer is still accepting; only then is it excluded from every future
    // CurrentRecipients() snapshot. Thus Submit-before-retire remains drainable,
    // while Submit-after-retire observes BACKEND_NOT_READY before state mutation.
    int32_t BeginGlfwRetire(uint64_t consumer, uint64_t transactionTime,
                            uint32_t reason) {
        const auto state = consumers.find(consumer);
        if (state == consumers.end()) return MissingConsumerStatus(consumer);
        const BackendSlot* slot = SlotFor(state->second.backend);
        if (!slot) return AMCL_INPUT_ERROR_NOT_FOUND;
        if (state->second.backendRole == ConsumerBackendRole::GlfwRetiring &&
            slot->retiring == consumer) {
            return HasPendingForConsumer(consumer) ? AMCL_INPUT_DRAIN_REQUIRED
                                                   : AMCL_INPUT_OK;
        }
        // 三个判据全部按**本后端的槽**算：另一个后端正在退休不该阻塞本后端。
        if (state->second.backendRole != ConsumerBackendRole::GlfwReady ||
            slot->ready != consumer || slot->retiring != 0u) {
            return AMCL_INPUT_ERROR_NOT_FOUND;
        }

        // The retirement RESET is ordered after packets already accepted for
        // this consumer, so those owned blobs remain drainable. Ownership is
        // fenced immediately; the adapter clears composition when it reaches
        // the RESET after the drain.
        textSessionActive = false;
        textSessionId = 0u;
        int32_t result = AMCL_INPUT_OK;
        const size_t required = held.size() + 1u;
        if (HasSequenceBudget(required) && EnsureSpace(required)) {
            if (!AppendReleases(0u, false, transactionTime)) {
                result = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            } else {
                AmclInputEvent reset = BlankEvent(AMCL_INPUT_EVENT_RESET);
                reset.payload.reset.reason = reason;
                reset.payload.reset.closingEpoch = sessionEpoch;
                if (!Append(reset, transactionTime, true)) {
                    result = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
            }
        } else if (HasSequenceBudget(1u) &&
                   OverflowReset(transactionTime, reason)) {
            // OverflowReset explicitly replaces every previously accepted
            // record with one observable RESET for all current recipients.
            result = kLifecycleOverflowHandled;
        } else {
            // Sequence exhaustion must still close the acceptance gate. The
            // caller receives a hard error and clears its local aggregate after
            // draining any older records; leaving ready=true would be worse
            // because later producers could continue receiving false success.
            // No sequence budget remains, so the held controls go without a
            // release edge -- counted, not silent.
            DiscardHeldWithoutReleaseLocked();
            captureActive = false;
            capture = AmclInputCapturePayload{};
            result = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        MarkGlfwRetiring(consumer);
        return result;
    }

    int32_t AbandonGlfwConsumer(uint64_t consumer,
                                uint64_t transactionTime) {
        const auto state = consumers.find(consumer);
        if (state == consumers.end()) return MissingConsumerStatus(consumer);
        BackendSlot* slot = SlotFor(state->second.backend);
        if (!slot ||
            (slot->ready != consumer && slot->retiring != consumer) ||
            state->second.backendRole == ConsumerBackendRole::None) {
            return AMCL_INPUT_ERROR_NOT_FOUND;
        }

        state->second.acceptingEvents = false;
        if (slot->ready == consumer) slot->ready = 0;
        if (slot->retiring == consumer) slot->retiring = 0;
        // An abandoned backend gets no release edges: it is gone, so per-control
        // UPs would have no recipient. Counted so the down/up ledger closes.
        DiscardHeldWithoutReleaseLocked();
        captureActive = false;
        capture = AmclInputCapturePayload{};
        DropTextPackets();
        DropConsumerFromQueueLocked(consumer);
        for (auto& packet : packets) packet.second.owners.erase(consumer);
        // These were stamped (they consumed sequences) and will never be read.
        CountDiscardedDeliveriesLocked(state->second.pendingControl.size());
        state->second.pendingControl.clear();
        Prune();

        int32_t result = AMCL_INPUT_OK;
        AmclInputEvent reset = BlankEvent(AMCL_INPUT_EVENT_RESET);
        reset.payload.reset.reason = AMCL_INPUT_RESET_BACKEND_ABANDONED;
        reset.payload.reset.closingEpoch = sessionEpoch;
        if (HasSequenceBudget(1u) && EnsureSpace(1u)) {
            if (!Append(reset, transactionTime, true)) {
                result = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
        } else if (HasSequenceBudget(1u) &&
                   OverflowReset(transactionTime,
                                 AMCL_INPUT_RESET_BACKEND_ABANDONED)) {
            result = kLifecycleOverflowHandled;
        } else {
            result = AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        consumers.erase(consumer);
        Prune();
        return result;
    }

    bool ApplyLifecycleState(const AmclInputEvent& lifecycle,
                             bool incrementFocus, bool incrementSurface) {
        if ((incrementFocus && !AdvanceNonZero(focusEpoch)) ||
            (incrementSurface && !AdvanceNonZero(surfaceEpoch))) {
            return false;
        }
        switch (lifecycle.header.eventType) {
            case AMCL_INPUT_EVENT_FOCUS_CHANGED:
                focused = lifecycle.payload.focus.focused != 0u;
                break;
            case AMCL_INPUT_EVENT_CAPTURE_CHANGED:
                captureActive = lifecycle.payload.capture.active != 0u;
                capture = lifecycle.payload.capture;
                break;
            case AMCL_INPUT_EVENT_SURFACE_CHANGED:
                surface = lifecycle.payload.surface;
                hasSurface = HasValidActiveDimensions(surface);
                break;
            default:
                break;
        }
        return true;
    }

    int32_t ResetOnly(uint32_t reason, uint64_t transactionTime) {
        const size_t normalRequired = held.size() + 1u;
        const bool overflowed = !HasSpaceAfterDroppingText(normalRequired);
        const size_t sequenceRequired = overflowed ? 1u : normalRequired;
        if (!HasSequenceBudget(sequenceRequired)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        DropTextPackets();
        Prune();
        if (overflowed) return AMCL_INPUT_OVERFLOW_RESET;
        if (!AppendReleases(0, false, transactionTime)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        captureActive = false;
        capture = AmclInputCapturePayload{};
        AmclInputEvent reset = BlankEvent(AMCL_INPUT_EVENT_RESET);
        reset.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
        reset.payload.reset.reason = reason;
        reset.payload.reset.closingEpoch = sessionEpoch;
        return Append(reset, transactionTime, true)
                   ? AMCL_INPUT_OK
                   : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }

    int32_t ResetThenLifecycle(uint32_t reason, AmclInputEvent lifecycle,
                               uint64_t transactionTime,
                               bool incrementFocus, bool incrementSurface,
                               uint32_t captureLossReason =
                                   AMCL_INPUT_CAPTURE_REASON_NONE) {
        if ((incrementFocus && focusEpoch == UINT64_MAX) ||
            (incrementSurface && surfaceEpoch == UINT64_MAX)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        const bool publishCaptureLoss =
            captureLossReason != AMCL_INPUT_CAPTURE_REASON_NONE &&
            capture.requested != 0u;
        const size_t lifecycleRecords = publishCaptureLoss ? 3u : 2u;
        const size_t normalRequired = held.size() + lifecycleRecords;
        const bool overflowed = !HasSpaceAfterDroppingText(normalRequired);
        const size_t sequenceRequired = overflowed
            ? lifecycleRecords : normalRequired;
        if (!HasSequenceBudget(sequenceRequired)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }

        DropTextPackets();
        Prune();
        const AmclInputCapturePayload previousCapture = capture;
        if (overflowed) {
            DiscardHeldWithoutReleaseLocked();
            captureActive = false;
            capture = AmclInputCapturePayload{};
            packets.clear();
            blobBytes = 0;
            DiscardQueuedRecordsLocked();
            ++overflowResetCount;
            ++obs.overflowResets;
        } else {
            if (!AppendReleases(0, false, transactionTime)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            captureActive = false;
            capture = AmclInputCapturePayload{};
        }

        AmclInputEvent reset = BlankEvent(AMCL_INPUT_EVENT_RESET);
        reset.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
        reset.payload.reset.reason = reason;
        reset.payload.reset.closingEpoch = sessionEpoch;
        if (!Append(reset, transactionTime, true)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (publishCaptureLoss) {
            AmclInputEvent captureLoss =
                BlankEvent(AMCL_INPUT_EVENT_CAPTURE_CHANGED);
            captureLoss.payload.capture.requested = previousCapture.requested;
            captureLoss.payload.capture.active = 0u;
            captureLoss.payload.capture.reason = captureLossReason;
            capture = captureLoss.payload.capture;
            captureActive = false;
            if (!Append(captureLoss, transactionTime, false)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
        }
        if (!ApplyLifecycleState(lifecycle, incrementFocus, incrementSurface)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (!Append(lifecycle, transactionTime, false)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        return overflowed ? kLifecycleOverflowHandled : AMCL_INPUT_OK;
    }

    int32_t ValidateTextOwnership(const AmclInputEvent& input) const {
        if (!IsTextType(input.header.eventType)) return AMCL_INPUT_OK;
        const uint64_t id = TextSessionId(input);
        if (input.header.eventType ==
            AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED) {
            if (input.payload.textSession.change ==
                AMCL_INPUT_TEXT_SESSION_STARTED) {
                if (!textSessionActive) return AMCL_INPUT_OK;
                return textSessionId == id ? AMCL_INPUT_OK
                                           : AMCL_INPUT_ERROR_SESSION;
            }
        }
        if (!textSessionActive || textSessionId != id) {
            return AMCL_INPUT_ERROR_STALE;
        }
        return AMCL_INPUT_OK;
    }

    int32_t Validate(const AmclInputEvent& input) const {
        if (input.header.abiVersion != AMCL_INPUT_EVENT_ABI_VERSION ||
            input.header.structSize < sizeof(AmclInputEvent)) {
            return AMCL_INPUT_ERROR_ABI_MISMATCH;
        }
        if (!sessionActive) return AMCL_INPUT_ERROR_SESSION;
        if (input.header.sessionEpoch != 0 &&
            input.header.sessionEpoch != sessionEpoch) {
            return AMCL_INPUT_ERROR_STALE;
        }
        if (input.header.focusEpoch != 0 &&
            input.header.focusEpoch != focusEpoch) {
            return AMCL_INPUT_ERROR_STALE;
        }
        if (input.header.surfaceEpoch != 0 &&
            input.header.surfaceEpoch != surfaceEpoch) {
            return AMCL_INPUT_ERROR_STALE;
        }
        const int32_t textOwnership = ValidateTextOwnership(input);
        if (textOwnership != AMCL_INPUT_OK) return textOwnership;
        if (!focused && IsOrdinaryInput(input.header.eventType)) {
            return AMCL_INPUT_ERROR_UNFOCUSED;
        }
        return AMCL_INPUT_OK;
    }

    int32_t ValidatePayload(const AmclInputEvent& input) const {
        constexpr uint32_t kKnownEventFlags =
            AMCL_INPUT_EVENT_FLAG_SYNTHETIC |
            AMCL_INPUT_EVENT_FLAG_PRECISE |
            AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND |
            AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW |
            AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
        if ((input.header.flags & ~kKnownEventFlags) != 0u ||
            ((input.header.flags & AMCL_INPUT_EVENT_FLAG_PRECISE) != 0u &&
             input.header.eventType != AMCL_INPUT_EVENT_POINTER_WHEEL) ||
            ((input.header.flags &
              AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND) != 0u &&
             input.header.eventType != AMCL_INPUT_EVENT_POINTER_BUTTON) ||
            ((input.header.flags & AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW) != 0u &&
             input.header.eventType != AMCL_INPUT_EVENT_POINTER_RELATIVE) ||
            ((input.header.flags &
              AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u &&
             (!IsPointerSample(input.header.eventType) ||
              input.header.monotonicTimeNs == 0u)) ||
            !IsKnownDeviceClass(input.header.deviceClass) ||
            (IsTextType(input.header.eventType) &&
             (input.header.source != AMCL_INPUT_SOURCE_IME ||
              input.header.deviceId != 0u ||
              input.header.deviceClass != AMCL_INPUT_DEVICE_CLASS_UNKNOWN ||
              (input.header.flags & AMCL_INPUT_EVENT_FLAG_SYNTHETIC) != 0u))) {
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
        switch (input.header.eventType) {
            case 0u:
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            case AMCL_INPUT_EVENT_PHYSICAL_KEY:
                if (input.payload.physicalKey.action < AMCL_INPUT_ACTION_DOWN ||
                    input.payload.physicalKey.action > AMCL_INPUT_ACTION_UP) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_POINTER_BUTTON:
                if (input.payload.pointerButton.action != AMCL_INPUT_ACTION_DOWN &&
                    input.payload.pointerButton.action != AMCL_INPUT_ACTION_UP) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_POINTER_ABSOLUTE:
                if (!std::isfinite(input.payload.pointerAbsolute.localPxX) ||
                    !std::isfinite(input.payload.pointerAbsolute.localPxY)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_POINTER_RELATIVE:
                if (!std::isfinite(input.payload.pointerRelative.rawDx) ||
                    !std::isfinite(input.payload.pointerRelative.rawDy)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_POINTER_WHEEL:
                if (!std::isfinite(input.payload.pointerWheel.x) ||
                    !std::isfinite(input.payload.pointerWheel.y) ||
                    input.payload.pointerWheel.unit < AMCL_INPUT_WHEEL_UNIT_PIXEL ||
                    input.payload.pointerWheel.unit > AMCL_INPUT_WHEEL_UNIT_DEGREE ||
                    input.payload.pointerWheel.precise > 1u) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_FOCUS_CHANGED:
                if (input.payload.focus.focused > 1u) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_POINTER_ENTER:
                if (input.payload.pointerEnter.entered > 1u) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_DEVICE_CHANGED:
                if (input.payload.device.change != AMCL_INPUT_DEVICE_ADDED &&
                    input.payload.device.change != AMCL_INPUT_DEVICE_REMOVED) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_CAPTURE_CHANGED:
                if (input.payload.capture.requested > 1u ||
                    input.payload.capture.active > 1u ||
                    (input.payload.capture.active != 0u &&
                     (input.payload.capture.requested == 0u ||
                      input.payload.capture.reason !=
                          AMCL_INPUT_CAPTURE_REASON_GRANTED)) ||
                    (input.payload.capture.active == 0u &&
                     input.payload.capture.reason ==
                         AMCL_INPUT_CAPTURE_REASON_GRANTED)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_SURFACE_CHANGED:
                if (input.payload.surface.active > 1u) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                if ((input.payload.surface.validFields &
                     AMCL_INPUT_SURFACE_FIELD_DIMENSIONS) != 0u &&
                    (input.payload.surface.widthPx == 0u ||
                     input.payload.surface.heightPx == 0u)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                if ((input.payload.surface.validFields &
                     AMCL_INPUT_SURFACE_FIELD_DENSITY) != 0u &&
                    (!std::isfinite(input.payload.surface.density) ||
                     input.payload.surface.density <= 0.0f)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                if ((input.payload.surface.validFields &
                     AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION) != 0u &&
                    input.payload.surface.publicationGeneration == 0u) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                // `transform` is an opaque platform value in V1. The validity
                // bit is its protocol boundary; inventing an enum ceiling here
                // would reject future platform transforms without ABI evidence.
                break;
            case AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED: {
                const auto& context = input.payload.surfaceContext;
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
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            }
            case AMCL_INPUT_EVENT_RESET:
                if (!IsResetReason(input.payload.reset.reason)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_TEXT_COMMIT:
                if (input.payload.textCommit.textSessionId == 0u ||
                    !IsZeroBlobRef(input.payload.textCommit.utf8Blob)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_TEXT_EDITING:
                if (input.payload.textEditing.textSessionId == 0u ||
                    !IsZeroBlobRef(input.payload.textEditing.utf8Blob) ||
                    input.payload.textEditing.selectionStart >
                        kTextMaxScalars ||
                    input.payload.textEditing.selectionLength >
                        kTextMaxScalars -
                        input.payload.textEditing.selectionStart) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_TEXT_CANDIDATES:
                if (input.payload.textCandidates.textSessionId == 0u ||
                    !IsZeroBlobRef(input.payload.textCandidates.itemsBlob) ||
                    input.payload.textCandidates.itemCount >
                        kTextCandidateMaxItems) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_TEXT_SELECTION:
                if (input.payload.textSelection.textSessionId == 0u ||
                    input.payload.textSelection.selectionStart >
                        kTextMaxScalars ||
                    input.payload.textSelection.selectionLength >
                        kTextMaxScalars -
                        input.payload.textSelection.selectionStart) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            case AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED: {
                const auto& text = input.payload.textSession;
                if (text.textSessionId == 0u ||
                    text.change < AMCL_INPUT_TEXT_SESSION_STARTED ||
                    text.change > AMCL_INPUT_TEXT_SESSION_ABORTED ||
                    text.reason == AMCL_INPUT_TEXT_SESSION_REASON_NONE ||
                    text.reason >
                        AMCL_INPUT_TEXT_SESSION_REASON_INPUT_SESSION_ENDED) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            }
            case AMCL_INPUT_EVENT_DIAGNOSTIC_DROP:
                // Diagnostic drops are authoritative core output. Accepting a
                // producer-authored packet would let ingress spoof recovery
                // evidence without traversing the held-owner checks below.
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            case AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE: {
                const auto& control = input.payload.backendConsumerState;
                // 未知 backend 一律拒：槽是按 `backend - 1` 索引的，放进来就是越界写。
                if (!IsKnownBackend(control.backend) ||
                    control.consumer == 0u ||
                    control.generation != AMCL_INPUT_HOST_API_GENERATION ||
                    control.state < AMCL_INPUT_BACKEND_CONSUMER_READY ||
                    control.state > AMCL_INPUT_BACKEND_CONSUMER_ABANDON) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                if ((control.state == AMCL_INPUT_BACKEND_CONSUMER_READY) !=
                    (control.baselineSequence != 0u)) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                break;
            }
            default:
                break;
        }
        return AMCL_INPUT_OK;
    }

    int32_t SubmitTextSession(AmclInputEvent event,
                              uint64_t transactionTime) {
        const auto& text = event.payload.textSession;
        if (text.change == AMCL_INPUT_TEXT_SESSION_STARTED &&
            textSessionActive && textSessionId == text.textSessionId) {
            return AMCL_INPUT_OK;
        }
        if (!HasSequenceBudget(1u)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (!EnsureSpace(1u)) return AMCL_INPUT_OVERFLOW_RESET;
        if (!Append(event, transactionTime, false)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (text.change == AMCL_INPUT_TEXT_SESSION_STARTED) {
            textSessionActive = true;
            textSessionId = text.textSessionId;
        } else {
            // Outstanding owned packets remain readable until their consumer
            // releases them.  The ordered END/ABORT clears composition state in
            // adapters without invalidating a COMMIT already handed out.
            textSessionActive = false;
            textSessionId = 0u;
        }
        return AMCL_INPUT_OK;
    }

    int32_t MissingConsumerStatus(AmclInputConsumerHandle handle) const {
        return HasCurrentConsumerGeneration(handle)
                   ? AMCL_INPUT_ERROR_NOT_FOUND
                   : AMCL_INPUT_ERROR_STALE;
    }

    int32_t AppendDropDiagnostic(const AmclInputEvent& original,
                                 uint32_t reason,
                                 uint64_t transactionTime) {
        if (!HasSequenceBudget(1u)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (!EnsureSpace(1u)) return AMCL_INPUT_OVERFLOW_RESET;

        // The rejected edge is replaced atomically by a backend-neutral
        // diagnostic. Keeping the original raw identity (not a guessed mapped
        // key/button) makes the drop observable without creating an owner or a
        // normal backend callback. Append participates in SubmitBatch's normal
        // queue/sequence rollback and in overflow reset exactly like any event.
        AmclInputEvent diagnostic = BlankEvent(AMCL_INPUT_EVENT_DIAGNOSTIC_DROP);
        diagnostic.header.deviceId = original.header.deviceId;
        diagnostic.header.source = original.header.source;
        diagnostic.header.deviceClass = original.header.deviceClass;
        diagnostic.payload.diagnosticDrop.reason = reason;
        diagnostic.payload.diagnosticDrop.originalEventType =
            original.header.eventType;
        if (original.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY) {
            diagnostic.payload.diagnosticDrop.rawControl =
                original.payload.physicalKey.physicalKey;
            diagnostic.payload.diagnosticDrop.action =
                original.payload.physicalKey.action;
            diagnostic.payload.diagnosticDrop.hardwareScanCode =
                original.payload.physicalKey.hardwareScanCode;
            diagnostic.payload.diagnosticDrop.hidUsage =
                original.payload.physicalKey.hidUsage;
        } else {
            diagnostic.payload.diagnosticDrop.rawControl =
                original.payload.pointerButton.nativeButton;
            diagnostic.payload.diagnosticDrop.action =
                original.payload.pointerButton.action;
        }
        return Append(diagnostic, transactionTime, false)
                   ? AMCL_INPUT_OK
                   : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }

    int32_t SubmitKey(AmclInputEvent event, uint64_t transactionTime) {
        const uint32_t action = event.payload.physicalKey.action;
        const HeldId id{event.header.deviceId, AMCL_INPUT_EVENT_PHYSICAL_KEY,
                        event.payload.physicalKey.physicalKey};
        auto found = held.find(id);
        if (action == AMCL_INPUT_ACTION_DOWN) {
            if (!HasSequenceBudget(1u)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
            if (found != held.end()) {
                event.payload.physicalKey.action = AMCL_INPUT_ACTION_REPEAT;
            } else {
                held.emplace(id, HeldControl{event});
            }
            return Append(event, transactionTime, false)
                       ? AMCL_INPUT_OK
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (action == AMCL_INPUT_ACTION_REPEAT) {
            // Repeat is an edge of an existing physical owner, never an
            // acquisition. A delayed platform repeat may arrive after
            // blur/device/session reset; promoting it to DOWN would resurrect
            // old-epoch state and could leave the key stuck without a later UP.
            // Replace an ownerless edge with a diagnostic rather than silently
            // accepting it; no held owner or ordinary event is manufactured.
            if (found == held.end()) {
                return AppendDropDiagnostic(
                    event, AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT,
                    transactionTime);
            }
            if (!HasSequenceBudget(1u)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
            return Append(event, transactionTime, false)
                       ? AMCL_INPUT_OK
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (action == AMCL_INPUT_ACTION_UP) {
            if (found == held.end()) {
                return AppendDropDiagnostic(
                    event, AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP,
                    transactionTime);
            }
            if (!HasSequenceBudget(1u)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
            held.erase(found);
            return Append(event, transactionTime, false)
                       ? AMCL_INPUT_OK
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }

    int32_t SubmitButton(AmclInputEvent event, uint64_t transactionTime) {
        const HeldId id{event.header.deviceId, AMCL_INPUT_EVENT_POINTER_BUTTON,
                        event.payload.pointerButton.nativeButton};
        auto found = held.find(id);
        const uint32_t action = event.payload.pointerButton.action;
        if (action == AMCL_INPUT_ACTION_DOWN) {
            if (found != held.end()) {
                return AppendDropDiagnostic(
                    event, AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN,
                    transactionTime);
            }
            if (!HasSequenceBudget(1u)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
            held.emplace(id, HeldControl{event});
            return Append(event, transactionTime, false)
                       ? AMCL_INPUT_OK
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        if (action == AMCL_INPUT_ACTION_UP) {
            if (found == held.end()) {
                return AppendDropDiagnostic(
                    event, AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP,
                    transactionTime);
            }
            if (!HasSequenceBudget(1u)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
            // Device class is an owner property established by DOWN. A stale or
            // degraded UP must release that same pointer class rather than
            // relabeling the final edge as UNKNOWN/a different device type.
            event.header.deviceClass =
                found->second.downEvent.header.deviceClass;
            event.header.source = found->second.downEvent.header.source;
            held.erase(found);
            return Append(event, transactionTime, false)
                       ? AMCL_INPUT_OK
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }

    int32_t SubmitBackendConsumerState(const AmclInputEvent& input,
                                        uint64_t transactionTime) {
        if ((!requireGlfwReady && !requireTextReady
#ifdef AMCL_INPUT_HOST_TESTING
             && false
#endif
             ) || !sessionActive ||
            input.header.sessionEpoch != sessionEpoch) {
            return AMCL_INPUT_ERROR_SESSION;
        }
        const auto& control = input.payload.backendConsumerState;
        const auto state = consumers.find(control.consumer);
        if (state == consumers.end()) {
            return MissingConsumerStatus(control.consumer);
        }
        if (state->second.generation != AMCL_INPUT_HOST_API_GENERATION ||
            state->second.sessionEpoch != sessionEpoch) {
            return AMCL_INPUT_ERROR_STALE;
        }

        // 角色一旦申领就与那个后端绑定：同一个消费者不得改换后端，否则它的退休屏障
        // 会留在旧槽里，而旧槽此后永远不会被清（表现为该后端再也无法申领 READY）。
        if (state->second.backend != 0u &&
            state->second.backend != control.backend) {
            return AMCL_INPUT_ERROR_STALE;
        }
        BackendSlot* slot = SlotFor(control.backend);
        if (!slot) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;

        if (control.state == AMCL_INPUT_BACKEND_CONSUMER_READY) {
            if (!state->second.baselineConsumed ||
                state->second.baselineSequence != control.baselineSequence ||
                !state->second.pendingControl.empty() ||
                !state->second.acceptingEvents ||
                HasPendingForConsumer(control.consumer)) {
                return AMCL_INPUT_ERROR_STALE;
            }
            if (slot->retiring != 0u) {
                return AMCL_INPUT_DRAIN_REQUIRED;
            }
            if (slot->ready == control.consumer &&
                state->second.backendRole == ConsumerBackendRole::GlfwReady) {
                return AMCL_INPUT_OK;
            }
            if (slot->ready != 0u ||
                state->second.backendRole != ConsumerBackendRole::None) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            state->second.backendRole = ConsumerBackendRole::GlfwReady;
            state->second.backend = control.backend;
            slot->ready = control.consumer;
            return AMCL_INPUT_OK;
        }
        if (control.state == AMCL_INPUT_BACKEND_CONSUMER_RETIRE) {
            return BeginGlfwRetire(control.consumer, transactionTime,
                                   AMCL_INPUT_RESET_BACKEND_RETIRED);
        }
        return AbandonGlfwConsumer(control.consumer, transactionTime);
    }

    int32_t SubmitLocked(const AmclInputEvent& input,
                         uint64_t transactionTime) {
        if (input.header.eventType >
            AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED) {
            return AMCL_INPUT_OK;
        }
        const int32_t payloadValidation = ValidatePayload(input);
        if (payloadValidation != AMCL_INPUT_OK) return payloadValidation;
        const int32_t validation = Validate(input);
        if (validation != AMCL_INPUT_OK) return validation;
        if ((input.header.flags &
             AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP) != 0u &&
            input.header.monotonicTimeNs > transactionTime) {
            // ArkUI documents the same system-monotonic nanosecond domain as
            // steady_clock. A future value would poison the non-decreasing
            // backend clock, so fail closed rather than relabel it as current.
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
        if (input.header.eventType ==
            AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE) {
            return SubmitBackendConsumerState(input, transactionTime);
        }
        // Producer-authored flags are not authority to bypass backend
        // readiness. Synthetic releases/resets are created internally and do
        // not traverse SubmitLocked; accepting a submitted SYNTHETIC flag here
        // would reopen the exact pre-consumer loss window this gate closes.
        if (((requireGlfwReady &&
              IsGlfwPhysicalInput(input.header.eventType)) ||
             (requireTextReady && TextEventNeedsReadyBackend(input))) &&
            !AnyBackendReady()) {
            return AMCL_INPUT_ERROR_BACKEND_NOT_READY;
        }
        AmclInputEvent event = input;
        event.header.flags &= ~AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
        switch (event.header.eventType) {
            case AMCL_INPUT_EVENT_PHYSICAL_KEY:
                return SubmitKey(event, transactionTime);
            case AMCL_INPUT_EVENT_POINTER_BUTTON:
                return SubmitButton(event, transactionTime);
            case AMCL_INPUT_EVENT_DEVICE_CHANGED: {
                const uint64_t id = event.header.deviceId;
                const auto found = devices.find(id);
                if (event.payload.device.change == AMCL_INPUT_DEVICE_ADDED) {
                    const DeviceRecord next{event.payload.device.capabilities,
                                            event.header.deviceClass};
                    if (found != devices.end() &&
                        found->second == next) {
                        return AMCL_INPUT_OK;
                    }
                    if (!HasSequenceBudget(1u)) {
                        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                    }
                    if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
                    devices[id] = next;
                    return Append(event, transactionTime, false)
                               ? AMCL_INPUT_OK
                               : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (event.payload.device.change != AMCL_INPUT_DEVICE_REMOVED) {
                    return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
                }
                const size_t count = HeldForDevice(id);
                if (found == devices.end() && count == 0u) {
                    return AMCL_INPUT_OK;
                }
                if (!HasSequenceBudget(count + 1u)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (!EnsureSpace(count + 1u)) return AMCL_INPUT_OVERFLOW_RESET;
                if (!AppendReleases(id, true, transactionTime)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (found != devices.end()) {
                    // Removal frequently arrives after getDeviceInfoSync has
                    // stopped serving the device. Preserve the class/capability
                    // accepted on ADD so backends can retire the right pointer
                    // after all synthesized releases for that owner were queued.
                    event.header.deviceClass = found->second.deviceClass;
                    event.payload.device.capabilities =
                        found->second.capabilities;
                    devices.erase(found);
                }
                return Append(event, transactionTime, false)
                           ? AMCL_INPUT_OK
                           : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            case AMCL_INPUT_EVENT_FOCUS_CHANGED: {
                const bool nextFocused = event.payload.focus.focused != 0;
                if (nextFocused == focused) return AMCL_INPUT_OK;
                if (!nextFocused) {
                    return ResetThenLifecycle(
                        AMCL_INPUT_RESET_FOCUS_LOST, event, transactionTime,
                        true, false, AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);
                }
                if (focusEpoch == UINT64_MAX || !HasSequenceBudget(1u)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
                if (!AdvanceNonZero(focusEpoch)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                focused = true;
                return Append(event, transactionTime, false)
                           ? AMCL_INPUT_OK
                           : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            case AMCL_INPUT_EVENT_CAPTURE_CHANGED: {
                const bool active = event.payload.capture.active != 0;
                if (active == captureActive &&
                    event.payload.capture.requested == capture.requested &&
                    event.payload.capture.reason == capture.reason) {
                    return AMCL_INPUT_OK;
                }
                if (!active && captureActive) {
                    return ResetThenLifecycle(
                        AMCL_INPUT_RESET_CAPTURE_LOST, event, transactionTime,
                        false, false);
                }
                if (!HasSequenceBudget(1u)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
                captureActive = active;
                capture = event.payload.capture;
                return Append(event, transactionTime, false)
                           ? AMCL_INPUT_OK
                           : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            case AMCL_INPUT_EVENT_SURFACE_CHANGED:
                if (hasSurface &&
                    HasValidActiveDimensions(event.payload.surface) &&
                    SameSurface(surface, event.payload.surface)) {
                    return AMCL_INPUT_OK;
                }
                return ResetThenLifecycle(
                    AMCL_INPUT_RESET_SURFACE_CHANGED, event,
                    transactionTime, false, true,
                    AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);
            case AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED:
                if (hasSurfaceContext) {
                    if (event.payload.surfaceContext.generation <
                        surfaceContext.generation) {
                        return AMCL_INPUT_ERROR_STALE;
                    }
                    if (event.payload.surfaceContext.generation ==
                        surfaceContext.generation) {
                        return SameSurfaceContext(
                            surfaceContext, event.payload.surfaceContext)
                            ? AMCL_INPUT_OK
                            : AMCL_INPUT_ERROR_STALE;
                    }
                }
                if (!HasSequenceBudget(1u)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (!EnsureSpace(1u)) return AMCL_INPUT_OVERFLOW_RESET;
                surfaceContext = event.payload.surfaceContext;
                hasSurfaceContext = true;
                return Append(event, transactionTime, false)
                           ? AMCL_INPUT_OK
                           : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            case AMCL_INPUT_EVENT_RESET:
                return ResetOnly(event.payload.reset.reason, transactionTime);
            case AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED:
                return SubmitTextSession(event, transactionTime);
            case AMCL_INPUT_EVENT_POINTER_ABSOLUTE:
            case AMCL_INPUT_EVENT_POINTER_RELATIVE:
            case AMCL_INPUT_EVENT_POINTER_WHEEL:
            case AMCL_INPUT_EVENT_POINTER_ENTER:
            case AMCL_INPUT_EVENT_TEXT_SELECTION:
                if (!HasSequenceBudget(1u)) {
                    return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                }
                if (!EnsureSpace(1)) return AMCL_INPUT_OVERFLOW_RESET;
                return Append(event, transactionTime, false)
                           ? AMCL_INPUT_OK
                           : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            case AMCL_INPUT_EVENT_TEXT_COMMIT:
            case AMCL_INPUT_EVENT_TEXT_EDITING:
            case AMCL_INPUT_EVENT_TEXT_CANDIDATES:
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            default:
                return AMCL_INPUT_OK;
        }
    }
};

InputStateCore::InputStateCore(bool requireGlfwReady, bool requireTextReady)
    : impl_(new Impl(requireGlfwReady, requireTextReady)) {}
InputStateCore::~InputStateCore() = default;

int32_t InputStateCore::BeginSession(uint64_t* outSessionEpoch) {
    if (!outSessionEpoch) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->sessionEpoch == UINT64_MAX ||
        impl_->focusEpoch == UINT64_MAX ||
        impl_->surfaceEpoch == UINT64_MAX) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    const uint64_t now = NowNs();
    const bool hadActiveSession = impl_->sessionActive;
    int32_t result = AMCL_INPUT_OK;
    if (impl_->sessionActive) {
        result = impl_->ResetOnly(AMCL_INPUT_RESET_SESSION_CHANGED, now);
        if (result == AMCL_INPUT_OVERFLOW_RESET &&
            !impl_->OverflowReset(now, AMCL_INPUT_RESET_SESSION_CHANGED)) {
            impl_->RetireAllReadyBackends();
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        impl_->RetireAllReadyBackends();
        if (result < AMCL_INPUT_OK) return result;
    }
    impl_->ClearSessionState();
    // §11 accumulators are session-scoped. Cleared on begin rather than on end so
    // a teardown summary can still be read after EndSession returns; the
    // alternative (clearing in ClearSessionState) would zero the numbers before
    // anything had a chance to report them.
    //
    // BeginSession-over-an-active-session is a session boundary too, so the
    // outgoing session's metrics are emitted here before the reset. Without this
    // a producer that renews its session without calling EndSession would lose a
    // whole session's §11 block silently.
    if (hadActiveSession) impl_->LogObservabilityLocked("session-replaced");
    impl_->obs = Impl::Observability{};
    ++impl_->sessionEpoch;
    ++impl_->focusEpoch;
    ++impl_->surfaceEpoch;
    impl_->sessionActive = true;
    impl_->focused = true;
    for (auto& entry : impl_->consumers) {
        if (entry.second.sessionEpoch == 0) {
            entry.second.sessionEpoch = impl_->sessionEpoch;
        }
    }
    *outSessionEpoch = impl_->sessionEpoch;
    return result;
}

int32_t InputStateCore::EndSession(uint64_t sessionEpoch) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->sessionActive || sessionEpoch != impl_->sessionEpoch) {
        return AMCL_INPUT_ERROR_STALE;
    }
    if (impl_->sessionEpoch == UINT64_MAX ||
        impl_->focusEpoch == UINT64_MAX ||
        impl_->surfaceEpoch == UINT64_MAX) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    const uint64_t now = NowNs();
    int32_t result = impl_->ResetOnly(AMCL_INPUT_RESET_SESSION_CHANGED, now);
    if (result == AMCL_INPUT_OVERFLOW_RESET &&
        !impl_->OverflowReset(now, AMCL_INPUT_RESET_SESSION_CHANGED)) {
        impl_->RetireAllReadyBackends();
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    impl_->RetireAllReadyBackends();
    if (result < AMCL_INPUT_OK) return result;
    // §11 requires these metrics to be emitted, not merely collectable. Every
    // session closes through exactly one of two seams -- here, or the
    // "session-replaced" emit in BeginSession -- and both run only once the
    // session really is over. The earlier returns in this function all leave the
    // session ACTIVE (stale epoch, epoch space exhausted, reset could not be
    // emitted), so staying silent there is correct: nothing ended, and a summary
    // would imply otherwise. It also runs after ResetOnly has released held
    // state, so a non-zero heldControlCount in this record is itself the §11
    // reset-invariant failure rather than a snapshot taken too early.
    impl_->LogObservabilityLocked("session-end");
    impl_->ClearSessionState();
    impl_->sessionActive = false;
    ++impl_->sessionEpoch;
    ++impl_->focusEpoch;
    ++impl_->surfaceEpoch;
    return result;
}

int32_t InputStateCore::SubmitEvent(const AmclInputEvent* event) {
    AmclInputEvent known{};
    const int32_t copyResult = CopyKnownEvent(event, &known);
    if (copyResult != AMCL_INPUT_OK) return copyResult;
    // A position-bound edge is meaningful only as the second member of one
    // atomic [absolute, button] batch. Accepting it through submitEvent would
    // let core held state advance while every conforming adapter drops the
    // unauthorised callback.
    if (IsAbsolutePositionBoundButton(known)) {
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const uint64_t now = NowNs();
    const int32_t result = impl_->SubmitLocked(known, now);
    if (result == kLifecycleOverflowHandled) {
        return AMCL_INPUT_OVERFLOW_RESET;
    }
    if (result == AMCL_INPUT_OVERFLOW_RESET && !impl_->OverflowReset(now)) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    return result;
}

int32_t InputStateCore::SubmitBatch(const AmclInputEvent* events,
                                    uint32_t count) {
    if (!events || count == 0) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::vector<AmclInputEvent> known(count);
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t copyResult = CopyKnownEvent(&events[i], &known[i]);
        if (copyResult != AMCL_INPUT_OK) return copyResult;
        // Backend readiness changes consumer ownership rather than queued input
        // state. The existing batch rollback snapshot intentionally excludes
        // consumers, so accepting this command in a batch would make rollback
        // partial and could leave a ghost ready/retiring owner.
        if (known[i].header.eventType ==
            AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE) {
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
        if (IsAbsolutePositionBoundButton(known[i]) &&
            !HasMatchingAbsolutePredecessor(known, i)) {
            // The binding is a batch-level promise, not producer authority.
            // Validate its exact predecessor before taking the core lock or
            // mutating held/queue state.
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    for (const auto& event : known) {
        const int32_t payloadValidation = impl_->ValidatePayload(event);
        if (payloadValidation != AMCL_INPUT_OK) return payloadValidation;
    }
    const auto queue = impl_->queue;
    const auto held = impl_->held;
    const auto packets = impl_->packets;
    const auto devices = impl_->devices;
    const uint64_t nextSequence = impl_->nextSequence;
    const uint64_t nextPacket = impl_->nextPacket;
    const uint64_t focusEpoch = impl_->focusEpoch;
    const uint64_t surfaceEpoch = impl_->surfaceEpoch;
    const uint64_t lastTimeNs = impl_->lastTimeNs;
    const uint64_t overflowResetCount = impl_->overflowResetCount;
    // The §11 accumulators are part of the rolled-back state. A partially applied
    // batch is undone down to `held`/`queue`/`nextSequence`, so leaving its
    // increments behind would report edges that no consumer ever saw and whose
    // held mutations were reverted -- the metric would contradict the state it
    // is supposed to describe.
    const auto observability = impl_->obs;
    const size_t blobBytes = impl_->blobBytes;
    const bool focused = impl_->focused;
    const bool captureActive = impl_->captureActive;
    const bool hasSurface = impl_->hasSurface;
    const bool hasSurfaceContext = impl_->hasSurfaceContext;
    const bool textSessionActive = impl_->textSessionActive;
    const uint64_t textSessionId = impl_->textSessionId;
    const auto surface = impl_->surface;
    const auto surfaceContext = impl_->surfaceContext;
    const auto capture = impl_->capture;
    const uint64_t now = NowNs();
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t result = impl_->SubmitLocked(known[i], now);
        if (result == AMCL_INPUT_OK) continue;

        impl_->queue = queue;
        impl_->held = held;
        impl_->packets = packets;
        impl_->devices = devices;
        impl_->nextSequence = nextSequence;
        impl_->nextPacket = nextPacket;
        impl_->focusEpoch = focusEpoch;
        impl_->surfaceEpoch = surfaceEpoch;
        impl_->lastTimeNs = lastTimeNs;
        impl_->overflowResetCount = overflowResetCount;
        impl_->obs = observability;
        impl_->blobBytes = blobBytes;
        impl_->focused = focused;
        impl_->captureActive = captureActive;
        impl_->hasSurface = hasSurface;
        impl_->hasSurfaceContext = hasSurfaceContext;
        impl_->textSessionActive = textSessionActive;
        impl_->textSessionId = textSessionId;
        impl_->surface = surface;
        impl_->surfaceContext = surfaceContext;
        impl_->capture = capture;

        if (result == AMCL_INPUT_OVERFLOW_RESET ||
            result == kLifecycleOverflowHandled) {
            return impl_->OverflowReset(now)
                       ? AMCL_INPUT_OVERFLOW_RESET
                       : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        return result;
    }
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::SubmitTextPacket(const AmclInputEvent* input,
                                         const uint8_t* bytes,
                                         uint32_t byteCount) {
    AmclInputEvent known{};
    const int32_t copyResult = CopyKnownEvent(input, &known);
    if (copyResult != AMCL_INPUT_OK) return copyResult;
    if ((byteCount != 0 && !bytes) ||
        !IsTextBlobType(known.header.eventType)) {
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }
    const int32_t payloadValidation = impl_->ValidatePayload(known);
    if (payloadValidation != AMCL_INPUT_OK) return payloadValidation;
    if (known.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT ||
        known.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
        size_t scalarCount = 0u;
        if (byteCount > kTextCandidateMaxUtf8Bytes ||
            CountTextUtf8Scalars(bytes, static_cast<size_t>(byteCount),
                                 &scalarCount) !=
                TextUtf8CodecStatus::kOk ||
            scalarCount > kTextCandidateMaxScalars ||
            (known.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT &&
             scalarCount == 0u)) {
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
        if (known.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
            const auto& editing = known.payload.textEditing;
            if (editing.selectionStart > scalarCount ||
                editing.selectionLength >
                    scalarCount - editing.selectionStart) {
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            }
        }
    } else {
        size_t candidateCount = 0u;
        size_t scalarCount = 0u;
        const TextUtf8CodecStatus codecStatus = DecodeTextCandidateBlob(
            bytes, static_cast<size_t>(byteCount), nullptr, 0u,
            &candidateCount, &scalarCount);
        (void)scalarCount;
        const auto& payload = known.payload.textCandidates;
        const bool emptyMetadata = candidateCount == 0u &&
            payload.selected == 0u && payload.pageStart == 0u &&
            payload.pageSize == 0u;
        const bool populatedMetadata = candidateCount != 0u &&
            payload.selected < candidateCount &&
            payload.pageStart < candidateCount && payload.pageSize != 0u &&
            payload.pageSize <= candidateCount - payload.pageStart &&
            payload.selected >= payload.pageStart &&
            payload.selected < payload.pageStart + payload.pageSize;
        if (codecStatus != TextUtf8CodecStatus::kOk ||
            candidateCount != payload.itemCount ||
            (!emptyMetadata && !populatedMetadata)) {
            return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
        }
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const uint64_t now = NowNs();
    const int32_t validation = impl_->Validate(known);
    if (validation != AMCL_INPUT_OK) return validation;
    if (impl_->requireTextReady && !impl_->AnyBackendReady()) {
        return AMCL_INPUT_ERROR_BACKEND_NOT_READY;
    }
    if (!impl_->HasSequenceBudget(1u) || impl_->nextPacket == 0u ||
        impl_->nextPacket == UINT64_MAX) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    if (!impl_->EnsureSpace(1)) {
        return impl_->OverflowReset(now)
                   ? AMCL_INPUT_OVERFLOW_RESET
                   : AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    if (impl_->packets.size() >= kBlobPacketCapacity ||
        static_cast<size_t>(byteCount) > kBlobCapacity - impl_->blobBytes) {
        if (!impl_->OverflowReset(
                now, AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }

    AmclInputEvent event = known;
    event.header.flags &= ~AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
    const std::set<uint64_t> owners = impl_->CurrentRecipients();
    PacketRecord packet;
    if (byteCount != 0u) packet.data.assign(bytes, bytes + byteCount);
    packet.owners = owners;

    const uint64_t sequenceBefore = impl_->nextSequence;
    const uint64_t lastTimeBefore = impl_->lastTimeNs;
    if (!impl_->Stamp(event, now, false)) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    uint64_t packetId = 0;
    if (!TakeNextNonZero(impl_->nextPacket, &packetId)) {
        impl_->nextSequence = sequenceBefore;
        impl_->lastTimeNs = lastTimeBefore;
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    const AmclInputBlobRef blob{packetId, 0, byteCount};
    if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) {
        event.payload.textCommit.utf8Blob = blob;
    } else if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) {
        event.payload.textEditing.utf8Blob = blob;
    } else {
        event.payload.textCandidates.itemsBlob = blob;
    }

    // §11 accounting. This path stamps and enqueues directly instead of going
    // through Append -- it has to interleave blob-pool allocation with the
    // sequence -- so it accounts for itself. Counting sits past every early
    // return, so a rejected packet is never reported as accepted.
    impl_->CountAcceptedLocked(event, false);
    if (owners.empty()) {
        ++impl_->obs.acceptedWithoutRecipient;
    } else {
        ++impl_->obs.queueWrites;
        impl_->obs.queueDeliveries += static_cast<uint64_t>(owners.size());
        impl_->blobBytes += packet.data.size();
        impl_->packets.emplace(packetId, std::move(packet));
        impl_->queue.push_back(EventRecord{event, owners});
    }
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::PublishSurface(
        const AmclInputSurfacePayload* surface) {
    if (!surface) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    AmclInputEvent event = BlankEvent(AMCL_INPUT_EVENT_SURFACE_CHANGED);
    event.payload.surface = *surface;
    return SubmitEvent(&event);
}

int32_t InputStateCore::PublishFocus(uint32_t focused) {
    AmclInputEvent event = BlankEvent(AMCL_INPUT_EVENT_FOCUS_CHANGED);
    event.payload.focus.focused = focused != 0 ? 1u : 0u;
    return SubmitEvent(&event);
}

int32_t InputStateCore::PublishDeviceChange(uint64_t deviceId,
                                            uint32_t change,
                                            uint32_t capabilities) {
    AmclInputEvent event = BlankEvent(AMCL_INPUT_EVENT_DEVICE_CHANGED);
    event.header.deviceId = deviceId;
    event.payload.device.change = change;
    event.payload.device.capabilities = capabilities;
    return SubmitEvent(&event);
}

int32_t InputStateCore::RequestReset(uint32_t reason) {
    if (!IsResetReason(reason)) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->sessionActive) return AMCL_INPUT_ERROR_SESSION;
    const uint64_t now = NowNs();
    const int32_t result = impl_->ResetOnly(reason, now);
    if (result == AMCL_INPUT_OVERFLOW_RESET && !impl_->OverflowReset(now)) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    return result;
}

int32_t InputStateCore::OpenConsumer(
        AmclInputConsumerHandle* outConsumer) {
    if (!outConsumer) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->nextConsumer == 0 || impl_->nextConsumer > kConsumerIdMask) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    const size_t controlCount = impl_->sessionActive
        ? 1u + (impl_->hasSurface ? 1u : 0u) +
              (impl_->hasSurfaceContext ? 1u : 0u) +
              (impl_->textSessionActive ? 1u : 0u) + impl_->devices.size()
        : 0u;
    if (impl_->sessionActive && !impl_->HasSequenceBudget(controlCount)) {
        return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
    }
    const uint64_t handle = MakeConsumerHandle(impl_->nextConsumer);
    const uint64_t epoch = impl_->sessionActive ? impl_->sessionEpoch : 0;
    ConsumerState state{epoch, AMCL_INPUT_HOST_API_GENERATION, {}};
    if (impl_->sessionActive) {
        AmclInputEvent baseline = BlankEvent(AMCL_INPUT_EVENT_RESET);
        baseline.payload.reset.reason = AMCL_INPUT_RESET_CONSUMER_BASELINE;
        baseline.payload.reset.closingEpoch = impl_->sessionEpoch;
        if (!impl_->Stamp(baseline, NowNs(), true)) {
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        }
        state.baselineSequence = baseline.header.sequence;
        // §11 accounting. The per-consumer control channel is a third stamping
        // path alongside Append and SubmitTextPacket. It has to be counted here:
        // NextEvent counts every pendingControl delivery as a queueRead, so
        // skipping the write side would make queueReads exceed queueWrites for
        // the lifetime of the process and would drop the CONSUMER_BASELINE reset
        // out of resetsEmitted, which claims to cover all reasons.
        // The new consumer is by definition the recipient, so this is a write.
        impl_->CountAcceptedLocked(baseline, true);
        ++impl_->obs.queueWrites;
        ++impl_->obs.queueDeliveries;
        state.pendingControl.push_back(baseline);
        if (impl_->hasSurface) {
            // A late backend must consume the exact current surface before it
            // can claim READY.  Otherwise the first absolute packet would have
            // an epoch but no publication to bind it to.  This replay is local
            // to the new consumer and begins RESET -> SURFACE.
            AmclInputEvent surface = BlankEvent(
                AMCL_INPUT_EVENT_SURFACE_CHANGED);
            surface.payload.surface = impl_->surface;
            if (!impl_->Stamp(surface, NowNs(), true)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            impl_->CountAcceptedLocked(surface, true);
            ++impl_->obs.queueWrites;
            ++impl_->obs.queueDeliveries;
            state.pendingControl.push_back(surface);
        }
        if (impl_->hasSurfaceContext) {
            // SurfaceContext is a separate Window/display fact snapshot.  A
            // late consumer observes it after the native render surface and
            // before device inventory: RESET -> SURFACE -> SURFACE_CONTEXT ->
            // DEVICE(id ascending).
            AmclInputEvent context = BlankEvent(
                AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED);
            context.payload.surfaceContext = impl_->surfaceContext;
            if (!impl_->Stamp(context, NowNs(), true)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            impl_->CountAcceptedLocked(context, true);
            ++impl_->obs.queueWrites;
            ++impl_->obs.queueDeliveries;
            state.pendingControl.push_back(context);
        }
        if (impl_->textSessionActive) {
            // Text ownership is process-global. A late consumer must observe
            // the active token before any following text payload can be
            // accepted by its adapter. This synthetic baseline is local to the
            // consumer and does not create a second core owner.
            AmclInputEvent text = BlankEvent(
                AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED);
            text.header.source = AMCL_INPUT_SOURCE_IME;
            text.payload.textSession.textSessionId = impl_->textSessionId;
            text.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
            text.payload.textSession.reason =
                AMCL_INPUT_TEXT_SESSION_REASON_NONE;
            if (!impl_->Stamp(text, NowNs(), true)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            impl_->CountAcceptedLocked(text, true);
            ++impl_->obs.queueWrites;
            ++impl_->obs.queueDeliveries;
            state.pendingControl.push_back(text);
        }
        // A backend commonly opens after ArkTS published the startup inventory.
        // Replaying the registry is therefore part of the same baseline
        // transaction; otherwise SDL would receive device-scoped motion/button
        // events for MouseIDs it was never told to add. Stable map order makes
        // RESET -> SURFACE -> SURFACE_CONTEXT -> DEVICE(id ascending)
        // deterministic.
        for (const auto& entry : impl_->devices) {
            AmclInputEvent device = BlankEvent(
                AMCL_INPUT_EVENT_DEVICE_CHANGED);
            device.header.deviceId = entry.first;
            device.header.deviceClass = entry.second.deviceClass;
            device.payload.device.change = AMCL_INPUT_DEVICE_ADDED;
            device.payload.device.capabilities = entry.second.capabilities;
            if (!impl_->Stamp(device, NowNs(), true)) {
                return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
            }
            impl_->CountAcceptedLocked(device, true);
            ++impl_->obs.queueWrites;
            ++impl_->obs.queueDeliveries;
            state.pendingControl.push_back(device);
        }
    }
    impl_->consumers.emplace(handle, std::move(state));
    ++impl_->nextConsumer;
    *outConsumer = handle;
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::NextEvent(AmclInputConsumerHandle consumer,
                                  AmclInputEvent* outEvent) {
    if (!outEvent) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto state = impl_->consumers.find(consumer);
    if (state == impl_->consumers.end()) {
        return impl_->MissingConsumerStatus(consumer);
    }
    if (!state->second.pendingControl.empty()) {
        *outEvent = state->second.pendingControl.front();
        state->second.pendingControl.pop_front();
        // §11 queue read. The baseline/control channel is counted alongside the
        // shared queue: a consumer that only ever drains control events is still
        // reading, and splitting the two would hide a stalled ordinary drain
        // behind a healthy-looking total.
        ++impl_->obs.queueReads;
        if (outEvent->header.eventType == AMCL_INPUT_EVENT_RESET &&
            outEvent->payload.reset.reason ==
                AMCL_INPUT_RESET_CONSUMER_BASELINE &&
            outEvent->header.sequence == state->second.baselineSequence) {
            state->second.baselineConsumed = true;
        }
        return AMCL_INPUT_OK;
    }
    for (auto& record : impl_->queue) {
        const auto recipient = record.recipients.find(consumer);
        if (recipient != record.recipients.end()) {
            *outEvent = record.event;
            record.recipients.erase(recipient);
            ++impl_->obs.queueReads;
            impl_->Prune();
            return AMCL_INPUT_OK;
        }
    }
    if (state->second.generation != AMCL_INPUT_HOST_API_GENERATION ||
        (state->second.sessionEpoch != 0 &&
         state->second.sessionEpoch != impl_->sessionEpoch)) {
        return AMCL_INPUT_ERROR_STALE;
    }
    return AMCL_INPUT_EMPTY;
}

int32_t InputStateCore::ReadPacketBlob(AmclInputConsumerHandle consumer,
                                       const AmclInputBlobRef* blob,
                                       uint8_t* outBytes,
                                       uint32_t outCapacity,
                                       uint32_t* outByteCount) {
    if (!blob || !outByteCount) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto state = impl_->consumers.find(consumer);
    if (state == impl_->consumers.end()) {
        return impl_->MissingConsumerStatus(consumer);
    }
    if (state->second.generation != AMCL_INPUT_HOST_API_GENERATION ||
        state->second.sessionEpoch != impl_->sessionEpoch) {
        return AMCL_INPUT_ERROR_STALE;
    }
    const auto packet = impl_->packets.find(blob->packetId);
    if (packet == impl_->packets.end() ||
        packet->second.owners.count(consumer) == 0) {
        return AMCL_INPUT_ERROR_NOT_FOUND;
    }
    const size_t offset = blob->offset;
    const size_t length = blob->length;
    if (offset > packet->second.data.size() ||
        length > packet->second.data.size() - offset) {
        return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    }
    *outByteCount = blob->length;
    if (outCapacity < blob->length) return AMCL_INPUT_ERROR_BUFFER_TOO_SMALL;
    if (blob->length != 0 && !outBytes) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if (blob->length != 0) {
        std::memcpy(outBytes, packet->second.data.data() + offset, length);
    }
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::ReleasePacket(AmclInputConsumerHandle consumer,
                                      uint64_t packetId) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto state = impl_->consumers.find(consumer);
    if (state == impl_->consumers.end()) {
        return impl_->MissingConsumerStatus(consumer);
    }
    if (state->second.generation != AMCL_INPUT_HOST_API_GENERATION ||
        state->second.sessionEpoch != impl_->sessionEpoch) {
        return AMCL_INPUT_ERROR_STALE;
    }
    const auto packet = impl_->packets.find(packetId);
    if (packet == impl_->packets.end() ||
        packet->second.owners.erase(consumer) == 0) {
        return AMCL_INPUT_ERROR_NOT_FOUND;
    }
    impl_->Prune();
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::CloseConsumer(AmclInputConsumerHandle consumer) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    auto state = impl_->consumers.find(consumer);
    if (state == impl_->consumers.end()) {
        return impl_->MissingConsumerStatus(consumer);
    }
    int32_t retireResult = AMCL_INPUT_OK;
    if (state->second.backendRole == ConsumerBackendRole::GlfwReady) {
        // A caller cannot bypass the remote retire barrier by directly closing
        // its handle. BeginGlfwRetire keeps every old recipient intact and
        // closes the producer gate before this function decides whether erase
        // is safe.
        retireResult = impl_->BeginGlfwRetire(
            consumer, NowNs(), AMCL_INPUT_RESET_BACKEND_RETIRED);
        state = impl_->consumers.find(consumer);
    }
    if (retireResult < AMCL_INPUT_OK) {
        // The acceptance gate is already closed, but keep the handle and all
        // older recipients intact so the caller may drain or explicitly
        // ABANDON. Returning the hard error makes sequence exhaustion visible.
        return retireResult;
    }
    if (state != impl_->consumers.end() &&
        state->second.backendRole == ConsumerBackendRole::GlfwRetiring &&
        impl_->HasPendingForConsumer(consumer)) {
        return AMCL_INPUT_DRAIN_REQUIRED;
    }
    // 只清**这个消费者所属后端**的槽。此前是两个全局字段，直接照搬会在多后端下把
    // 另一个后端的 ready/retiring 一起清成 0 —— 那个后端此后既不 READY 也不在退休，
    // 生产者闸门却仍以为有人在，是"事件被接收然后无人可送"的形状。
    if (BackendSlot* slot = impl_->SlotForConsumer(consumer)) {
        if (slot->ready == consumer) slot->ready = 0u;
        if (slot->retiring == consumer) slot->retiring = 0u;
    }
    // Anything still owed to this consumer -- both its private control channel
    // and its slots in the shared queue -- becomes a counted discard.
    impl_->CountDiscardedDeliveriesLocked(state->second.pendingControl.size());
    impl_->consumers.erase(state);
    impl_->DropConsumerFromQueueLocked(consumer);
    for (auto& packet : impl_->packets) packet.second.owners.erase(consumer);
    impl_->Prune();
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::GetSnapshot(AmclInputSnapshotV1* outSnapshot) {
    if (!outSnapshot) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if (outSnapshot->abiVersion != AMCL_INPUT_HOST_API_VERSION ||
        outSnapshot->structSize < sizeof(AmclInputSnapshotV1)) {
        return AMCL_INPUT_ERROR_ABI_MISMATCH;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    snapshot.captureRequested = impl_->capture.requested;
    snapshot.sessionEpoch = impl_->sessionEpoch;
    snapshot.focusEpoch = impl_->focusEpoch;
    snapshot.surfaceEpoch = impl_->surfaceEpoch;
    snapshot.heldControlCount = impl_->held.size();
    snapshot.consumerCount = impl_->consumers.size();
    snapshot.queuedEventCount = impl_->queue.size();
    snapshot.queueCapacity = kQueueCapacity;
    snapshot.overflowResetCount = impl_->overflowResetCount;
    snapshot.blobBytes = impl_->blobBytes;
    snapshot.blobCapacity = kBlobCapacity;
    snapshot.focused = impl_->focused ? 1u : 0u;
    snapshot.captureActive = impl_->captureActive ? 1u : 0u;
    snapshot.sessionActive = impl_->sessionActive ? 1u : 0u;
    snapshot.captureReason = impl_->capture.reason;
    *outSnapshot = snapshot;
    return AMCL_INPUT_OK;
}

int32_t InputStateCore::GetObservability(CoreObservabilityV1* outObservability) {
    if (!outObservability) return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    *outObservability = impl_->SnapshotObservabilityLocked();
    return AMCL_INPUT_OK;
}

void InputStateCore::LogObservabilitySummary(const char* reason) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->LogObservabilityLocked(reason);
}

void InputStateCore::Impl::LogObservabilityLocked(const char* reason) {
    const CoreObservabilityV1 m = SnapshotObservabilityLocked();
    const char* tag = reason ? reason : "unknown";
    // Split across three records on purpose. hilog truncates long lines, and a
    // truncated §11 block silently loses whichever metric happens to sit at the
    // tail -- which is exactly the "silent drop" this section exists to forbid.
    OH_LOG_INFO(LOG_APP,
        "input core observability reason=%{public}s "
        "epoch(session/focus/surface)=%{public}llu/%{public}llu/%{public}llu "
        "lastSequence=%{public}llu lastMonotonicTimeNs=%{public}llu "
        "backend(ready/retiring)=%{public}llu/%{public}llu",
        tag,
        (unsigned long long)m.sessionEpoch,
        (unsigned long long)m.focusEpoch,
        (unsigned long long)m.surfaceEpoch,
        (unsigned long long)m.lastSequence,
        (unsigned long long)m.lastMonotonicTimeNs,
        (unsigned long long)m.backendConsumer,
        (unsigned long long)m.backendRetiringConsumer);
    OH_LOG_INFO(LOG_APP,
        "input core observability reason=%{public}s "
        "physical(down/repeat/up/syntheticUp/droppedNoRelease)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu "
        "diagnosticDrops=%{public}llu "
        "held(controls/devices/maxControls/maxDevices)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu",
        tag,
        (unsigned long long)m.physicalDown,
        (unsigned long long)m.physicalRepeat,
        (unsigned long long)m.physicalUp,
        (unsigned long long)m.physicalUpSynthetic,
        (unsigned long long)m.heldDroppedWithoutRelease,
        (unsigned long long)m.diagnosticDrops,
        (unsigned long long)m.heldControlCount,
        (unsigned long long)m.heldOwnerDeviceCount,
        (unsigned long long)m.maxHeldControlCount,
        (unsigned long long)m.maxHeldOwnerDeviceCount);
    // The `none` capture bucket is structurally always zero: CountCaptureLocked
    // returns before bucketing when reason == NONE. It is printed anyway so a
    // non-zero value reads as a counting bug instead of hiding behind an index
    // nobody logs.
    OH_LOG_INFO(LOG_APP,
        "input core observability reason=%{public}s "
        "queue(accepted/write/noRecipient/deliveries/read/discard/pending/"
        "overflow/reset)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu "
        "capture(requested/active/lost)=%{public}llu/%{public}llu/%{public}llu "
        "captureLostBy(none/granted/platform/focus/surface/unsupported/unknown)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu/%{public}llu "
        "text(sessionStart/sessionEnd/sessionAbort/commit/edit/candidates/selection)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu/%{public}llu",
        tag,
        (unsigned long long)m.accepted,
        (unsigned long long)m.queueWrites,
        (unsigned long long)m.acceptedWithoutRecipient,
        (unsigned long long)m.queueDeliveries,
        (unsigned long long)m.queueReads,
        (unsigned long long)m.queueDiscarded,
        (unsigned long long)m.queuePending,
        (unsigned long long)m.queueOverflowResets,
        (unsigned long long)m.resetsEmitted,
        (unsigned long long)m.captureRequested,
        (unsigned long long)m.captureActivated,
        (unsigned long long)m.captureLost,
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_NONE],
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_GRANTED],
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST],
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST],
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST],
        (unsigned long long)m.captureLostByReason[
            AMCL_INPUT_CAPTURE_REASON_UNSUPPORTED],
        (unsigned long long)m.captureLostUnknownReason,
        (unsigned long long)m.textSessionStarts,
        (unsigned long long)m.textSessionEnds,
        (unsigned long long)m.textSessionAborts,
        (unsigned long long)m.textCommits,
        (unsigned long long)m.textEdits,
        (unsigned long long)m.textCandidates,
        (unsigned long long)m.textSelections);
}

#ifdef AMCL_INPUT_HOST_TESTING
void InputStateCore::TestSetNextSequence(uint64_t value) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->nextSequence = value;
}

void InputStateCore::TestSetNextPacket(uint64_t value) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->nextPacket = value;
}

void InputStateCore::TestSetEpochs(uint64_t session, uint64_t focus,
                                   uint64_t surface) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->sessionEpoch = session;
    impl_->focusEpoch = focus;
    impl_->surfaceEpoch = surface;
}
#endif

InputStateCore& HostInputStateCore() {
#ifdef AMCL_INPUT_HOST_TESTING
    // Existing host API tests intentionally exercise text packets without
    // constructing a backend consumer. Product builds keep the readiness gate
    // enabled; dedicated ingress/adapter tests register a backend explicitly.
    static InputStateCore core(
        LatchedGlfwInputRouteConfig().typedPhysical, false);
#else
    static InputStateCore core(
        LatchedGlfwInputRouteConfig().typedPhysical, true);
#endif
    return core;
}

}  // namespace amcl::input

namespace {
using amcl::input::HostInputStateCore;
int32_t Begin(uint64_t* value) { return HostInputStateCore().BeginSession(value); }
int32_t End(uint64_t value) { return HostInputStateCore().EndSession(value); }
int32_t Submit(const AmclInputEvent* event) { const int32_t result = HostInputStateCore().SubmitEvent(event); amclDesktopNotifyInput(); return result; }
int32_t SubmitMany(const AmclInputEvent* events, uint32_t count) { const int32_t result = HostInputStateCore().SubmitBatch(events, count); amclDesktopNotifyInput(); return result; }
int32_t SubmitText(const AmclInputEvent* event, const uint8_t* bytes, uint32_t count) { const int32_t result = HostInputStateCore().SubmitTextPacket(event, bytes, count); amclDesktopNotifyInput(); return result; }
int32_t Surface(const AmclInputSurfacePayload* value) { const int32_t result = HostInputStateCore().PublishSurface(value); amclDesktopNotifyInput(); return result; }
int32_t Focus(uint32_t value) { const int32_t result = HostInputStateCore().PublishFocus(value); amclDesktopNotifyInput(); return result; }
int32_t Device(uint64_t id, uint32_t change, uint32_t caps) { const int32_t result = HostInputStateCore().PublishDeviceChange(id, change, caps); amclDesktopNotifyInput(); return result; }
int32_t Reset(uint32_t reason) { const int32_t result = HostInputStateCore().RequestReset(reason); amclDesktopNotifyInput(); return result; }
int32_t Open(AmclInputConsumerHandle* value) { return HostInputStateCore().OpenConsumer(value); }
int32_t Next(AmclInputConsumerHandle value, AmclInputEvent* event) { return HostInputStateCore().NextEvent(value, event); }
int32_t ReadBlob(AmclInputConsumerHandle value, const AmclInputBlobRef* blob, uint8_t* bytes, uint32_t capacity, uint32_t* count) { return HostInputStateCore().ReadPacketBlob(value, blob, bytes, capacity, count); }
int32_t Release(AmclInputConsumerHandle value, uint64_t packet) { return HostInputStateCore().ReleasePacket(value, packet); }
int32_t Close(AmclInputConsumerHandle value) { return HostInputStateCore().CloseConsumer(value); }
int32_t Snapshot(AmclInputSnapshotV1* value) { return HostInputStateCore().GetSnapshot(value); }
}  // namespace

extern "C" AMCL_INPUT_PUBLIC const AmclInputHostApiV1*
amclInputGetHostApiV1(void) {
    // The rollout selector is latched by the one published host table. Reading
    // getenv independently in libentry and a namespace-duplicated libglfw can
    // split DOWN/UP across source planes if their first calls race an edit.
    // Once this static is built, neither environment changes nor another DSO's
    // private core can alter the process-owner decision.
    static const bool typedPhysicalRoute =
        amcl::input::LatchedGlfwInputRouteConfig().typedPhysical;
    static constexpr bool verifiedRelative =
        amcl::input::kGlfwRelativeVerifiedByBuild;
    static const bool api26RawMouseMotion = amcl::input::RuntimeDesktopRawCapability(
        amcl::input::kGlfwApi26RawMouseMotionByBuild);
    static constexpr bool verifiedNativeAbsolute =
        amcl::input::kGlfwNativeAbsoluteVerifiedByBuild;
    static const AmclInputHostApiV1 api = {
        AMCL_INPUT_HOST_API_MAGIC,
        AMCL_INPUT_HOST_API_VERSION,
        sizeof(AmclInputHostApiV1),
        AMCL_INPUT_CAP_TYPED_EVENTS | AMCL_INPUT_CAP_MULTI_CONSUMER |
            AMCL_INPUT_CAP_OVERFLOW_RESET |
            AMCL_INPUT_CAP_OWNED_TEXT_PACKETS |
            AMCL_INPUT_CAP_SESSION_EPOCHS |
            AMCL_INPUT_CAP_HOST_GENERATION |
            AMCL_INPUT_CAP_EXPECTED_EPOCHS |
            AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS |
            AMCL_INPUT_CAP_CONSUMER_BASELINE |
            AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY |
            AMCL_INPUT_CAP_DIAGNOSTIC_DROP |
            AMCL_INPUT_CAP_BACKEND_CONSUMER_READY |
            AMCL_INPUT_CAP_DEVICE_CLASS |
            AMCL_INPUT_CAP_SURFACE_CONTEXT |
            AMCL_INPUT_CAP_TEXT_INPUT_SESSION |
             (typedPhysicalRoute
                ? AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE : 0u) |
             (verifiedRelative
                ? AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE : 0u) |
             (typedPhysicalRoute && verifiedNativeAbsolute
                ? AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE : 0u) |
             (typedPhysicalRoute && verifiedRelative && api26RawMouseMotion
                ? AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION : 0u),
        AMCL_INPUT_HOST_API_GENERATION,
        Begin,
        End,
        Submit,
        SubmitMany,
        SubmitText,
        Surface,
        Focus,
        Device,
        Reset,
        Open,
        Next,
        ReadBlob,
        Release,
        Close,
        Snapshot,
    };
    return &api;
}

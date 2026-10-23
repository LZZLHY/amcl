#include "input_shadow_consumer.h"

#include "input_trace.h"
#include <cstdint>
#include <map>
#include <mutex>
#include <tuple>
#include <utility>
#include <vector>

namespace amcl::input::shadow {
namespace {
struct LedgerKey {
    uint64_t device;
    uint32_t code;
    bool operator<(const LedgerKey& other) const {
        return std::tie(device, code) < std::tie(other.device, other.code);
    }
};

struct State {
    std::mutex mutex;
    AmclInputConsumerHandle consumer = 0;
    uint64_t sequence = 0;
    uint64_t timeNs = 0;
    uint64_t sessionEpoch = 0;
    uint64_t focusEpoch = 0;
    uint64_t surfaceEpoch = 0;
    std::map<LedgerKey, uint32_t> keys;
    std::map<LedgerKey, uint32_t> buttons;
    // core 文本会话的队列序镜像：只由本消费者读到的 RESET/TEXT_SESSION 记录改写，
    // 供 ingress 在恢复与 BEGIN 冲突时认出无人持有的孤儿会话（ingress 锁序在外）。
    bool textSessionActive = false;
    uint64_t textSessionId = 0;
};
State g;

void ClearLocalLocked() {
    g.consumer = 0;
    g.sequence = 0;
    g.timeNs = 0;
    g.sessionEpoch = 0;
    g.focusEpoch = 0;
    g.surfaceEpoch = 0;
    g.keys.clear();
    g.buttons.clear();
    // 句柄作废后文本镜像也无从证明；重新 Open 时 core 基线会补发尚存的 STARTED。
    g.textSessionActive = false;
    g.textSessionId = 0;
    trace::SetHeld(0, 0);
}

// 按队列顺序维护文本会话镜像。调用者持有本文件锁，且只对顺序合法的记录调用。
void TrackTextSessionLocked(const AmclInputEvent& event) {
    if (event.header.eventType == AMCL_INPUT_EVENT_RESET) {
        g.textSessionActive = false;
        g.textSessionId = 0;
        return;
    }
    if (event.header.eventType != AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED) return;
    // STARTED 覆盖为新号；END/ABORT 无论号是否一致都表示 core 已无活动会话。
    g.textSessionActive =
        event.payload.textSession.change == AMCL_INPUT_TEXT_SESSION_STARTED;
    g.textSessionId =
        g.textSessionActive ? event.payload.textSession.textSessionId : 0u;
}

void CloseBestEffortLocked(const AmclInputHostApiV1* api) {
    if (g.consumer != 0 && api) {
        const int32_t result = api->closeConsumer(g.consumer);
        trace::RecordSubmitted(result);
    }
    // STALE means this opaque consumer handle belongs to a retired session or
    // consumer incarnation. It is still a completed close from the shadow's
    // point of view; it says nothing about function-table ABI generation.
    ClearLocalLocked();
}

bool IsTextBlob(uint32_t type) {
    return type == AMCL_INPUT_EVENT_TEXT_COMMIT ||
           type == AMCL_INPUT_EVENT_TEXT_EDITING ||
           type == AMCL_INPUT_EVENT_TEXT_CANDIDATES;
}

bool IsOrdinaryInput(uint32_t type) {
    return type == AMCL_INPUT_EVENT_PHYSICAL_KEY ||
           type == AMCL_INPUT_EVENT_POINTER_ABSOLUTE ||
           type == AMCL_INPUT_EVENT_POINTER_RELATIVE ||
           type == AMCL_INPUT_EVENT_POINTER_BUTTON ||
           type == AMCL_INPUT_EVENT_POINTER_WHEEL ||
           type == AMCL_INPUT_EVENT_POINTER_ENTER ||
           type == AMCL_INPUT_EVENT_TEXT_COMMIT ||
           type == AMCL_INPUT_EVENT_TEXT_EDITING ||
           type == AMCL_INPUT_EVENT_TEXT_CANDIDATES ||
           type == AMCL_INPUT_EVENT_TEXT_SELECTION;
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

void Difference() {
    trace::RecordConsumerError(false);
}
void ConsumeText(const AmclInputHostApiV1* api, const AmclInputEvent& event) {
    const AmclInputBlobRef blob = BlobOf(event);
    uint32_t byteCount = 0;
    const int32_t sizeResult = api->readPacketBlob(
        g.consumer, &blob, nullptr, 0, &byteCount);
    if (sizeResult != AMCL_INPUT_OK &&
        sizeResult != AMCL_INPUT_ERROR_BUFFER_TOO_SMALL) {
        Difference();
    } else {
        std::vector<uint8_t> bytes(byteCount);
        uint32_t actual = 0;
        const int32_t readResult = api->readPacketBlob(
            g.consumer, &blob, bytes.empty() ? nullptr : bytes.data(),
            byteCount, &actual);
        if (readResult != AMCL_INPUT_OK || actual != byteCount) Difference();
    }
    if (api->releasePacket(g.consumer, blob.packetId) != AMCL_INPUT_OK) {
        Difference();
    }
}

void Consume(const AmclInputHostApiV1* api, const AmclInputEvent& event) {
    const bool invalidOrder =
        (g.sequence != 0 && event.header.sequence <= g.sequence) ||
        event.header.monotonicTimeNs < g.timeNs ||
        (g.sessionEpoch != 0 && event.header.sessionEpoch != g.sessionEpoch) ||
        event.header.focusEpoch < g.focusEpoch ||
        event.header.surfaceEpoch < g.surfaceEpoch;
    if (invalidOrder) {
        Difference();
        // Owned packets must be released even when their ordering metadata is
        // bad. Do not lower high-water marks or mutate the held ledger.
        if (IsTextBlob(event.header.eventType)) ConsumeText(api, event);
        trace::RecordConsumed();
        return;
    }
    g.sequence = event.header.sequence;
    g.timeNs = event.header.monotonicTimeNs;
    g.sessionEpoch = event.header.sessionEpoch;
    g.focusEpoch = event.header.focusEpoch;
    g.surfaceEpoch = event.header.surfaceEpoch;

    if (event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY) {
        const LedgerKey key{event.header.deviceId,
                            event.payload.physicalKey.physicalKey};
        const uint32_t action = event.payload.physicalKey.action;
        if (action == AMCL_INPUT_ACTION_DOWN) {
            if (!g.keys.emplace(key, action).second) Difference();
        } else if (action == AMCL_INPUT_ACTION_REPEAT) {
            if (g.keys.find(key) == g.keys.end()) Difference();
        } else if (action == AMCL_INPUT_ACTION_UP) {
            if (g.keys.erase(key) == 0u) Difference();
        }
    } else if (event.header.eventType == AMCL_INPUT_EVENT_POINTER_BUTTON) {
        const LedgerKey key{event.header.deviceId,
                            event.payload.pointerButton.nativeButton};
        if (event.payload.pointerButton.action == AMCL_INPUT_ACTION_DOWN) {
            if (!g.buttons.emplace(key, AMCL_INPUT_ACTION_DOWN).second) Difference();
        } else if (g.buttons.erase(key) == 0u) {
            Difference();
        }
    } else if (event.header.eventType == AMCL_INPUT_EVENT_DIAGNOSTIC_DROP) {
        // A core drop is already the authoritative, backend-neutral evidence
        // for an edge that did not mutate held state. Count it without treating
        // it as a reconciliation mismatch or synthesizing an owner.
        trace::RecordDiagnosticDrop();
    } else if (event.header.eventType == AMCL_INPUT_EVENT_RESET) {
        g.keys.clear();
        g.buttons.clear();
    }
    TrackTextSessionLocked(event);
    if (IsTextBlob(event.header.eventType)) ConsumeText(api, event);
    trace::SetHeld(g.keys.size(), g.buttons.size());
    trace::RecordConsumed();
}
}  // namespace
bool Open(const AmclInputHostApiV1* api, bool forceReopen) {
    if (!api) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (g.consumer != 0) {
        bool current = false;
        if (!forceReopen && g.sessionEpoch != 0) {
            AmclInputSnapshotV1 snapshot{};
            snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
            snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
            const int32_t result = api->getSnapshot(&snapshot);
            trace::RecordSubmitted(result);
            current = result == AMCL_INPUT_OK && snapshot.sessionActive != 0u &&
                      snapshot.sessionEpoch == g.sessionEpoch;
        }
        if (current) return true;
        CloseBestEffortLocked(api);
    }
    const int32_t result = api->openConsumer(&g.consumer);
    trace::RecordSubmitted(result);
    if (result != AMCL_INPUT_OK) {
        ClearLocalLocked();
        return false;
    }
    return true;
}

DrainResult Drain(const AmclInputHostApiV1* api, bool terminal) {
    DrainResult drained{false, false, false, false, false};
    if (!api) return drained;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (g.consumer == 0) return drained;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = api->nextEvent(g.consumer, &event);
        if (result == AMCL_INPUT_EMPTY) {
            drained.completed = true;
            return drained;
        }
        if (result != AMCL_INPUT_OK) {
            if (result == AMCL_INPUT_ERROR_STALE) drained.staleConsumer = true;
            if (!(terminal && result == AMCL_INPUT_ERROR_STALE)) {
                trace::RecordConsumerError(result == AMCL_INPUT_ERROR_STALE);
            }
            return drained;
        }
        if (IsOrdinaryInput(event.header.eventType)) {
            drained.observedResetState = true;
            drained.resetLatched = false;
        }
        if (event.header.eventType == AMCL_INPUT_EVENT_RESET) {
            // This edge is intentionally distinct from resetLatched: a later
            // ordinary event may clear the latch, but reconciliation still has
            // to learn that this drain crossed a reset boundary exactly once.
            drained.observedResetState = true;
            drained.observedReset = true;
            drained.resetAuthorityEpoch =
                (api->capabilityBits & AMCL_INPUT_CAP_RESET_AUTHORITY_EPOCH) != 0u
                    ? event.payload.reset.authorityEpoch : 0u;
            drained.resetLatched = true;
        }
        Consume(api, event);
    }
}

void CloseBestEffort(const AmclInputHostApiV1* api) {
    std::lock_guard<std::mutex> lock(g.mutex);
    CloseBestEffortLocked(api);
}

void Abandon() {
    std::lock_guard<std::mutex> lock(g.mutex);
    ClearLocalLocked();
}

// 只读快照；没有消费者句柄时镜像已在 ClearLocalLocked 清空，因而返回 false。
bool ObservedTextSession(uint64_t* textSessionId) {
    std::lock_guard<std::mutex> lock(g.mutex);
    if (textSessionId) *textSessionId = g.textSessionActive ? g.textSessionId : 0u;
    return g.consumer != 0 && g.textSessionActive;
}

}  // namespace amcl::input::shadow

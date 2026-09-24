#ifndef AMCL_INPUT_STATE_CORE_H
#define AMCL_INPUT_STATE_CORE_H

#include "amcl_input_api.h"

#include <memory>

namespace amcl::input {

// §11 requires every phase to emit identity/ordering, per-action physical,
// held-owner, queue, capture and text metrics. `AmclInputSnapshotV1` is frozen
// at 104 bytes and the V1 function table at 144 (both static_asserted in
// amcl_input_api.h), so these counters are exposed as a C++-level struct rather
// than by growing either. That is deliberate: a cross-DSO ABI generation bump
// would force every out-of-tree V1 consumer to be recompiled to buy diagnostics
// it never reads. If a libentry.so-side reader ever appears, this has to become
// a versioned table entry instead of being marshalled ad hoc.
//
// ⚠️ Reader inventory, corrected 2026-08-20. The previous wording claimed "the
// only readers are inside libglfw.so (**the typed adapter** and the host
// tests)". The typed adapter is NOT a reader -- `GetObservability`,
// `LogObservabilitySummary` and `CoreObservabilityV1` appear nowhere in
// `glfw_input_adapter.cpp` or `glfw_compat.cpp`. The actual inventory is:
//   * `Impl::LogObservabilityLocked` -- private, called by BeginSession
//     ("session-replaced") and EndSession ("session-end");
//   * `input_state_core_test.cpp` -- the only caller of the public accessors.
// So the honest statement is "no non-test reader outside this file". That is a
// weaker fact than the old sentence, and it is the one that matters: the whole
// argument for not making this a versioned table entry rested on a reader that
// does not exist. The DSO half of the old sentence was right (CMakeLists assigns
// both this TU and the adapter to libglfw.so only).
//
// Every field is a plain uint64_t read under the core mutex, so a snapshot is
// internally consistent. Counters are session-scoped: BeginSession clears them.
struct CoreObservabilityV1 {
    // ---- identity / ordering -------------------------------------------
    // `lastSequence` / `lastMonotonicTimeNs` are the values stamped onto the
    // most recently accepted event, not a live clock read. A summary that
    // printed a fresh clock read could not be correlated with the last event a
    // consumer actually saw, which is the whole point of §11's ordering pair.
    uint64_t sessionEpoch = 0;
    uint64_t focusEpoch = 0;
    uint64_t surfaceEpoch = 0;
    uint64_t lastSequence = 0;
    uint64_t lastMonotonicTimeNs = 0;
    // §11's `backend` identity: the consumer handle currently holding the typed
    // backend role, plus whether one is retiring. Zero means no backend has been
    // baselined, which is the normal state for a legacy-routed build.
    //
    // §11 also lists `source`. That is deliberately absent: source is a
    // per-event field (AmclInputEventHeader.source) and there is no meaningful
    // session aggregate of it. Adding a "last source" or a per-source histogram
    // here would invent a number the architecture does not own. Per-event source
    // stays observable on the event itself and in the trace-side plane.
    uint64_t backendConsumer = 0;
    uint64_t backendRetiringConsumer = 0;

    // ---- physical edges, post-arbitration ------------------------------
    // Counted as the action the event carries once core is done with it. Edges
    // that core replaced with DIAGNOSTIC_DROP are counted in `diagnosticDrops`
    // only, never here, so "applied" and "rejected" stay disjoint.
    //
    // ⚠️ The repeat promotion is KEY-ONLY, and the previous wording got this
    // wrong by saying "a DOWN on an already-held *control*":
    //   * PHYSICAL_KEY   -- a DOWN on an already-held key is rewritten to
    //                       REPEAT and lands in `physicalRepeat`.
    //   * POINTER_BUTTON -- a duplicate DOWN is NOT promoted. It becomes
    //                       DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN and lands in
    //                       `diagnosticDrops`, never in `physicalRepeat`.
    // GLFW has no button-repeat semantics, so the asymmetry is deliberate; only
    // the description was wrong. Saying "control" made this block contradict its
    // own next sentence for buttons. `input_trace.h` states the same thing
    // correctly ("core rewrote ... or replaced with a diagnostic") -- use that
    // phrasing as the model.
    //
    // Scope, stated precisely because it is easy to overclaim: these count edges
    // core ACCEPTED. Submissions rejected before acceptance — STALE epoch,
    // UNFOCUSED, BACKEND_NOT_READY, invalid payload, sequence or capacity
    // exhaustion — are returned to the producer as error codes and appear in no
    // field here. The producer-side plane (input_trace.h) counts those, so the
    // two planes must be read together; neither alone equals "submissions".
    uint64_t physicalDown = 0;
    uint64_t physicalRepeat = 0;
    uint64_t physicalUp = 0;
    // Subset of `physicalUp` that core synthesised while clearing held state on
    // the ordinary paths (reset, blur, device removal, ordinary backend retire).
    uint64_t physicalUpSynthetic = 0;
    // Held controls discarded WITHOUT any release edge. The capacity- and
    // sequence-exhaustion paths have no budget to emit one edge per control:
    // OverflowReset, the ResetThenLifecycle overflow branch, the BeginGlfwRetire
    // sequence-exhaustion branch, and AbandonGlfwConsumer. Without this field
    // those losses are invisible, which §11 forbids.
    //
    // The auditable ledger is therefore
    //
    //     physicalDown == physicalUp + heldDroppedWithoutRelease
    //
    // and NOT `physicalDown == physicalUp`, which holds only when no overflow or
    // exhaustion occurred. A non-zero value here is not corruption; it is a
    // truthful record that downstream held state was dropped en bloc and that
    // consumers were told to rebuild from a RESET instead of from per-control
    // UPs.
    uint64_t heldDroppedWithoutRelease = 0;
    uint64_t diagnosticDrops = 0;

    // ---- held ownership -------------------------------------------------
    // `heldOwnerDeviceCount` is the distinct-device count §11 asks for. The
    // post-reset invariant is `heldControlCount == 0 && heldOwnerDeviceCount
    // == 0`; the high-water marks make a slow leak visible in a single summary
    // line even when the instantaneous counts happen to be zero at teardown.
    uint64_t heldControlCount = 0;
    uint64_t heldOwnerDeviceCount = 0;
    uint64_t maxHeldControlCount = 0;
    uint64_t maxHeldOwnerDeviceCount = 0;

    // ---- queue ----------------------------------------------------------
    // `accepted` counts every event core stamped with a sequence. `queueWrites`
    // counts the subset that reached a queue. The difference is
    // `acceptedWithoutRecipient`: no consumer was a recipient at that instant.
    // That is not a drop — held state still moved and the sequence was spent —
    // but it must not be indistinguishable from one, which is exactly what a
    // single "submitted" counter would do.
    //
    // Units differ on purpose and must not be compared directly:
    //   queueWrites      counts RECORDS enqueued
    //   queueDeliveries  counts RECIPIENT SLOTS created (one record fanned out
    //                    to N consumers is N deliveries)
    //   queueReads       counts deliveries handed to a consumer
    //   queueDiscarded   counts deliveries that will never be handed over
    //                    (consumer closed or abandoned, text dropped on reset,
    //                    whole queue cleared by an overflow reset)
    //
    // so the §11 queue ledger closes as
    //
    //     queueDeliveries == queueReads + queueDiscarded + <still pending>
    //
    // Comparing queueWrites against queueReads is meaningless with more than one
    // consumer; use queueDeliveries.
    uint64_t accepted = 0;
    uint64_t queueWrites = 0;
    uint64_t acceptedWithoutRecipient = 0;
    uint64_t queueDeliveries = 0;
    uint64_t queueReads = 0;
    uint64_t queueDiscarded = 0;
    uint64_t queuePending = 0;
    uint64_t queueOverflowResets = 0;
    // RESET events core actually emitted, all reasons — including the
    // per-consumer CONSUMER_BASELINE emitted by OpenConsumer. Distinct from
    // `queueOverflowResets`, which counts only the capacity-driven subset.
    uint64_t resetsEmitted = 0;

    // ---- capture --------------------------------------------------------
    // `captureLostByReason` is indexed by AMCL_INPUT_CAPTURE_REASON_*. A reason outside
    // the array lands in `captureLostUnknownReason` instead of being silently
    // folded into NONE. That branch is reachable from an ordinary submitEvent:
    // ValidatePayload checks `requested`/`active` but deliberately does not
    // constrain `reason`, so a producer built against a newer reason list still
    // gets its capture loss recorded rather than dropped.
    //
    // Index AMCL_INPUT_CAPTURE_REASON_NONE is structurally always zero: a
    // publication with active==0 and reason==NONE is a neutral/never-granted
    // state, not a loss, and returns before bucketing. The slot is kept so the
    // array stays index-aligned with the ABI reason values.
    uint64_t captureRequested = 0;
    uint64_t captureActivated = 0;
    uint64_t captureLost = 0;
    uint64_t captureLostByReason[AMCL_INPUT_CAPTURE_REASON_COUNT] = {};
    uint64_t captureLostUnknownReason = 0;

    // ---- text -----------------------------------------------------------
    // Typed text lifecycle and payload edges are counted independently.  END
    // and ABORT are deliberately separate: a rejected END must not be reported
    // as a clean stop when the producer subsequently fences with ABORT.
    uint64_t textSessionStarts = 0;
    uint64_t textSessionEnds = 0;
    uint64_t textSessionAborts = 0;
    uint64_t textCommits = 0;
    uint64_t textEdits = 0;
    uint64_t textCandidates = 0;
    uint64_t textSelections = 0;
};

class InputStateCore final {
public:
    // Generic/test cores default to legacy/shadow behavior. The shipping owner
    // passes the same startup-latched route decision that it publishes through
    // the immutable host table, so capability and gate cannot diverge.
    explicit InputStateCore(bool requireGlfwReady = false,
                            bool requireTextReady = false);
    ~InputStateCore();
    InputStateCore(const InputStateCore&) = delete;
    InputStateCore& operator=(const InputStateCore&) = delete;

    int32_t BeginSession(uint64_t* outSessionEpoch);
    int32_t EndSession(uint64_t sessionEpoch);
    int32_t SubmitEvent(const AmclInputEvent* event);
    int32_t SubmitBatch(const AmclInputEvent* events, uint32_t count);
    int32_t SubmitTextPacket(const AmclInputEvent* event,
                             const uint8_t* bytes, uint32_t byteCount);
    int32_t PublishSurface(const AmclInputSurfacePayload* surface);
    int32_t PublishFocus(uint32_t focused);
    int32_t PublishDeviceChange(uint64_t deviceId, uint32_t change,
                                uint32_t capabilities);
    int32_t RequestReset(uint32_t reason);
    int32_t OpenConsumer(AmclInputConsumerHandle* outConsumer);
    int32_t NextEvent(AmclInputConsumerHandle consumer,
                      AmclInputEvent* outEvent);
    int32_t ReadPacketBlob(AmclInputConsumerHandle consumer,
                           const AmclInputBlobRef* blob, uint8_t* outBytes,
                           uint32_t outCapacity, uint32_t* outByteCount);
    int32_t ReleasePacket(AmclInputConsumerHandle consumer,
                          uint64_t packetId);
    int32_t CloseConsumer(AmclInputConsumerHandle consumer);
    int32_t GetSnapshot(AmclInputSnapshotV1* outSnapshot);
    // §11 metrics. Not reachable through the frozen C function table by design
    // (see CoreObservabilityV1). Takes the core mutex, so a caller must not
    // hold it.
    //
    // ⚠️ "in practice only teardown paths and tests call this" was wrong: the
    // only caller is `input_state_core_test.cpp`. Product teardown does not go
    // through this accessor -- it uses the private `Impl::LogObservabilityLocked`
    // (already holding the mutex) from BeginSession/EndSession. Same correction
    // applies to LogObservabilitySummary below, which also has zero product
    // callers.
    int32_t GetObservability(CoreObservabilityV1* outObservability);
    // Emits the §11 metric block to hilog. Separate from GetObservability so the
    // numbers stay assertable in host tests where hilog is a no-op stub and the
    // formatted text is unobservable.
    //
    // Cost: three hilog records written while holding the core mutex, so every
    // producer blocks for the duration. That is acceptable at a session boundary
    // and is NOT acceptable on a periodic path. If this ever needs to run
    // periodically, snapshot with GetObservability first and format outside the
    // lock.
    //
    // ⚠️ "(which is where core calls it)" referred to the session boundary, but
    // core reaches that boundary through the private `LogObservabilityLocked`,
    // not through this public entry. This one has zero product callers.
    void LogObservabilitySummary(const char* reason);

#ifdef AMCL_INPUT_HOST_TESTING
    void TestSetNextSequence(uint64_t value);
    void TestSetNextPacket(uint64_t value);
    void TestSetEpochs(uint64_t session, uint64_t focus, uint64_t surface);
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

InputStateCore& HostInputStateCore();

}  // namespace amcl::input

#endif

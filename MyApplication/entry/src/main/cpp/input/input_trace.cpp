#include "input_trace.h"

#include "amcl_input_api.h"
#include <atomic>
#include <cstddef>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "INPUT_TRACE"

namespace amcl::input::trace {
namespace {
constexpr size_t kPhysicalIngressKindCount = 4u;
constexpr size_t kPhysicalOutcomeCount =
    static_cast<size_t>(AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED) + 1u;
// Slots 1..3 are the ABI action values themselves, so the action doubles as its
// own index and a renumbering in amcl_input_event.h cannot silently shift a
// bucket.
//
// Slot 0 is "outside DOWN/REPEAT/UP". It is reachable in production, not a
// defensive dead slot: ingress records AMCL_LEGACY_PHYSICAL_INVALID_ACTION for a
// key/button whose action does not pair with its mapped GLFW action (see
// platform_input_ingress.cpp IsKeyActionPair / IsButtonActionPair) and passes the
// producer's raw, unvalidated action through to this recorder. Bucketing it here
// is the point: an out-of-range action is exactly the kind of producer bug §11
// wants visible rather than folded into a DOWN/UP total.
constexpr size_t kPhysicalActionSlotCount =
    static_cast<size_t>(AMCL_INPUT_ACTION_UP) + 1u;
static_assert(AMCL_INPUT_ACTION_DOWN == 1u && AMCL_INPUT_ACTION_REPEAT == 2u &&
                  AMCL_INPUT_ACTION_UP == 3u,
              "physical action buckets index by raw ABI action value");

// Periodic sample line rate. Every ingress record calls MaybeSample(), so this
// runs on the platform input callback and the interval is the only thing keeping
// hilog from being flooded at input rate. It was a hardcoded 256 with no way to
// change or silence it; a build that needs quiet logs (or needs every sample for
// a bug hunt) should not have to patch the expression.
//
//   -DAMCL_INPUT_TRACE_SAMPLE_INTERVAL=0   disables the periodic line entirely.
//   Session summaries and anomaly logs are unaffected: those are not sampled,
//   so turning this off cannot hide a failure, only routine traffic.
//
// Power-of-two only, because the check is a mask rather than a modulo -- this is
// on the input callback path. A non-power-of-two would silently sample at the
// wrong rate, so it is a build error instead.
#ifndef AMCL_INPUT_TRACE_SAMPLE_INTERVAL
#define AMCL_INPUT_TRACE_SAMPLE_INTERVAL 256u
#endif
constexpr uint64_t kSampleInterval = AMCL_INPUT_TRACE_SAMPLE_INTERVAL;
constexpr uint64_t kSampleMask =
    kSampleInterval == 0u ? 0u : kSampleInterval - 1u;
static_assert(kSampleInterval == 0u ||
                  (kSampleInterval & (kSampleInterval - 1u)) == 0u,
              "AMCL_INPUT_TRACE_SAMPLE_INTERVAL must be 0 or a power of two");

struct Counters {
    std::atomic<uint64_t> submitted{0};
    std::atomic<uint64_t> consumed{0};
    std::atomic<uint64_t> errors{0};
    std::atomic<uint64_t> stale{0};
    std::atomic<uint64_t> unsupported{0};
    std::atomic<uint64_t> diagnosticDrops{0};
    std::atomic<uint64_t> missingDevice{0};
    std::atomic<uint64_t> missingScanCode{0};
    std::atomic<uint64_t> missingLockState{0};
    std::atomic<uint64_t> missingRawDelta{0};
    std::atomic<uint64_t> missingCursorTransform{0};
    std::atomic<uint64_t> relativeFallbackSelected{0};
    std::atomic<uint64_t> relativeFallbackEnqueued{0};
    std::atomic<uint64_t> relativeFallbackEnqueueFailed{0};
    std::atomic<uint64_t> relativeFallbackZeroDelta{0};
    std::atomic<uint64_t> relativeFallbackTypedRejected{0};
    std::atomic<uint64_t> relativeFallbackGateRejected{0};
    std::atomic<uint64_t> relativeFallbackInvalidDelta{0};
    std::atomic<uint64_t> physicalRelativeInvalidDelta{0};
    std::atomic<uint64_t> physicalRelativeEnqueueFailed{0};
    std::atomic<uint64_t>
        physicalIngressOutcomes[kPhysicalIngressKindCount][kPhysicalOutcomeCount]{};
    std::atomic<uint64_t>
        physicalMappingUnavailable[kPhysicalIngressKindCount]{};
    // §11 "physical down/repeat/up counts", producer side. Indexed by
    // [kind][action] where the action index is the raw AMCL_INPUT_ACTION_* value
    // (1/2/3) and 0 collects values outside that range. These are the actions the
    // *platform reported at the ingress seam*, before core arbitration; the
    // post-arbitration counts live in InputStateCore's CoreObservabilityV1. Both
    // exist on purpose -- their difference is exactly the set of edges core
    // rewrote (duplicate DOWN to REPEAT) or replaced with a diagnostic, and a
    // single number could not show that.
    std::atomic<uint64_t>
        physicalActions[kPhysicalIngressKindCount][kPhysicalActionSlotCount]{};
    std::atomic<uint64_t> heldKeys{0};
    std::atomic<uint64_t> heldButtons{0};
    std::atomic<uint64_t> sampleTick{0};
    std::atomic<uint64_t> generation{0};
    std::atomic<uint64_t> sessionEpoch{0};
    // ⚠️ Process-lifetime. `BeginSession()` below zeroes every counter declared
    // above and must NOT zero these two. The contract and the reason are in
    // input_trace.h: a fail-closed session never reaches LogSessionSummary, so a
    // per-session recovery counter would be wiped before it could be read.
    std::atomic<uint64_t> epochRecovered{0};
    std::atomic<uint64_t> sessionFailedClosed{0};
};
Counters g;
reconciliation::Reconciler gReconciliation;

uint64_t Load(const std::atomic<uint64_t>& value) {
    return value.load(std::memory_order_relaxed);
}

bool IsFirstOrPowerOfTwo(uint64_t count) {
    return count == 1u || (count & (count - 1u)) == 0u;
}

bool PhysicalKindIndex(PhysicalIngressKind kind, size_t* index) {
    const size_t candidate = static_cast<size_t>(kind);
    if (candidate >= kPhysicalIngressKindCount || !index) return false;
    *index = candidate;
    return true;
}

bool PhysicalOutcomeIndex(AmclLegacyPhysicalOutcome outcome, size_t* index) {
    const int candidate = static_cast<int>(outcome);
    if (candidate < 0 || static_cast<size_t>(candidate) >= kPhysicalOutcomeCount ||
        !index) {
        return false;
    }
    *index = static_cast<size_t>(candidate);
    return true;
}

const char* PhysicalKindName(PhysicalIngressKind kind) {
    switch (kind) {
        case PhysicalIngressKind::Key: return "key";
        case PhysicalIngressKind::Button: return "button";
        case PhysicalIngressKind::Wheel: return "wheel";
        case PhysicalIngressKind::Relative: return "relative";
    }
    return "invalid-kind";
}

const char* PhysicalOutcomeName(AmclLegacyPhysicalOutcome outcome) {
    switch (outcome) {
        case AMCL_LEGACY_PHYSICAL_EMITTED: return "emitted";
        case AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE:
            return "handled-no-final-edge";
        case AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE:
            return "bridge-unavailable";
        case AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED: return "enqueue-failed";
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT:
            return "ownerless-repeat";
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_UP: return "ownerless-up";
        case AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN: return "duplicate-down";
        case AMCL_LEGACY_PHYSICAL_INVALID_ACTION: return "invalid-action";
        case AMCL_LEGACY_PHYSICAL_INVALID_VALUE: return "invalid-value";
        case AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL: return "unknown-control";
        case AMCL_LEGACY_PHYSICAL_GATE_REJECTED: return "gate-rejected";
        case AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED:
            return "typed-route-handled";
        case AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS:
            return "reset-in-progress";
        case AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED:
            return "capability-rejected";
    }
    return "invalid-outcome";
}

bool IsOperationalFailure(AmclLegacyPhysicalOutcome outcome) {
    return outcome != AMCL_LEGACY_PHYSICAL_EMITTED &&
           outcome != AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE &&
           outcome != AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED;
}

void MaybeSample() {
    // `if constexpr` rather than a plain `if`: the condition is a compile-time
    // constant, and MSVC /W4 raises C4127 ("conditional expression is constant")
    // for that, which /WX turns into a build error in the host test targets. It is
    // load-bearing here, not stylistic. The early return is also required for
    // correctness -- with the interval at 0 the mask is 0, so `tick & mask` would
    // be true every call and the sample line would fire on every event.
    if constexpr (kSampleInterval == 0u) return;
    const uint64_t tick = g.sampleTick.fetch_add(1, std::memory_order_relaxed) + 1;
    if ((tick & kSampleMask) != 0u) return;
    OH_LOG_INFO(LOG_APP,
        "neutral input sample submitted=%{public}llu consumed=%{public}llu errors=%{public}llu "
        "stale=%{public}llu held=%{public}llu/%{public}llu "
        "relativeFallback(selected/enqueued/failed/invalid)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu",
        (unsigned long long)Load(g.submitted), (unsigned long long)Load(g.consumed),
        (unsigned long long)Load(g.errors), (unsigned long long)Load(g.stale),
        (unsigned long long)Load(g.heldKeys), (unsigned long long)Load(g.heldButtons),
        (unsigned long long)Load(g.relativeFallbackSelected),
        (unsigned long long)Load(g.relativeFallbackEnqueued),
        (unsigned long long)Load(g.relativeFallbackEnqueueFailed),
        (unsigned long long)Load(g.relativeFallbackInvalidDelta));
}
}  // namespace
void BeginSession(uint64_t generation, uint64_t sessionEpoch) {
    gReconciliation.BeginSession();
    g.submitted.store(0, std::memory_order_relaxed);
    g.consumed.store(0, std::memory_order_relaxed);
    g.errors.store(0, std::memory_order_relaxed);
    g.stale.store(0, std::memory_order_relaxed);
    g.unsupported.store(0, std::memory_order_relaxed);
    g.diagnosticDrops.store(0, std::memory_order_relaxed);
    g.missingDevice.store(0, std::memory_order_relaxed);
    g.missingScanCode.store(0, std::memory_order_relaxed);
    g.missingLockState.store(0, std::memory_order_relaxed);
    g.missingRawDelta.store(0, std::memory_order_relaxed);
    g.missingCursorTransform.store(0, std::memory_order_relaxed);
    g.relativeFallbackSelected.store(0, std::memory_order_relaxed);
    g.relativeFallbackEnqueued.store(0, std::memory_order_relaxed);
    g.relativeFallbackEnqueueFailed.store(0, std::memory_order_relaxed);
    g.relativeFallbackZeroDelta.store(0, std::memory_order_relaxed);
    g.relativeFallbackTypedRejected.store(0, std::memory_order_relaxed);
    g.relativeFallbackGateRejected.store(0, std::memory_order_relaxed);
    g.relativeFallbackInvalidDelta.store(0, std::memory_order_relaxed);
    g.physicalRelativeInvalidDelta.store(0, std::memory_order_relaxed);
    g.physicalRelativeEnqueueFailed.store(0, std::memory_order_relaxed);
    for (size_t kind = 0; kind < kPhysicalIngressKindCount; ++kind) {
        g.physicalMappingUnavailable[kind].store(0, std::memory_order_relaxed);
        for (size_t slot = 0; slot < kPhysicalActionSlotCount; ++slot) {
            g.physicalActions[kind][slot].store(0, std::memory_order_relaxed);
        }
        for (size_t outcome = 0; outcome < kPhysicalOutcomeCount; ++outcome) {
            g.physicalIngressOutcomes[kind][outcome].store(
                0, std::memory_order_relaxed);
        }
    }
    g.heldKeys.store(0, std::memory_order_relaxed);
    g.heldButtons.store(0, std::memory_order_relaxed);
    g.sampleTick.store(0, std::memory_order_relaxed);
    g.generation.store(generation, std::memory_order_relaxed);
    g.sessionEpoch.store(sessionEpoch, std::memory_order_relaxed);
}

void RecordSubmitted(int32_t result) {
    g.submitted.fetch_add(1, std::memory_order_relaxed);
    if (result != AMCL_INPUT_OK) {
        g.errors.fetch_add(1, std::memory_order_relaxed);
        if (result == AMCL_INPUT_ERROR_STALE || result == AMCL_INPUT_ERROR_SESSION) {
            g.stale.fetch_add(1, std::memory_order_relaxed);
        }
    }
    MaybeSample();
}

void RecordConsumed() {
    g.consumed.fetch_add(1, std::memory_order_relaxed);
    MaybeSample();
}

void RecordConsumerError(bool stale) {
    g.errors.fetch_add(1, std::memory_order_relaxed);
    if (stale) g.stale.fetch_add(1, std::memory_order_relaxed);
    MaybeSample();
}

void RecordEpochRecovered() {
    const uint64_t count =
        g.epochRecovered.fetch_add(1, std::memory_order_relaxed) + 1u;
    // Deliberately not routed through MaybeSample(): that path compiles out
    // entirely under -DAMCL_INPUT_TRACE_SAMPLE_INTERVAL=0, and this is an
    // abnormal lifecycle transition that must stay visible in a quiet build.
    if (IsFirstOrPowerOfTwo(count)) {
        OH_LOG_WARN(LOG_APP,
            "neutral input typed-core epoch recovery completed "
            "recovered=%{public}llu failedClosed=%{public}llu; the failed event "
            "was never replayed and the frontend reset epoch advanced",
            (unsigned long long)count,
            (unsigned long long)Load(g.sessionFailedClosed));
    }
}

void RecordSessionFailedClosed() {
    const uint64_t count =
        g.sessionFailedClosed.fetch_add(1, std::memory_order_relaxed) + 1u;
    if (IsFirstOrPowerOfTwo(count)) {
        OH_LOG_WARN(LOG_APP,
            "neutral input session failed closed "
            "failedClosed=%{public}llu recovered=%{public}llu; typed submission "
            "returns ERROR_SESSION until the next surface-created",
            (unsigned long long)count,
            (unsigned long long)Load(g.epochRecovered));
    }
}

void RecordUnsupported() {
    g.unsupported.fetch_add(1, std::memory_order_relaxed);
}

void RecordDiagnosticDrop() {
    g.diagnosticDrops.fetch_add(1, std::memory_order_relaxed);
}

void RecordMissing(MissingField field) {
    switch (field) {
        case MissingField::Device: g.missingDevice.fetch_add(1, std::memory_order_relaxed); break;
        case MissingField::ScanCode: g.missingScanCode.fetch_add(1, std::memory_order_relaxed); break;
        case MissingField::LockState: g.missingLockState.fetch_add(1, std::memory_order_relaxed); break;
        case MissingField::RawDelta: g.missingRawDelta.fetch_add(1, std::memory_order_relaxed); break;
        case MissingField::CursorTransform:
            g.missingCursorTransform.fetch_add(1, std::memory_order_relaxed);
            break;
    }
}

void RecordRelativeFallbackSelected(bool reconcile) {
    g.relativeFallbackSelected.fetch_add(1, std::memory_order_relaxed);
    if (reconcile) gReconciliation.RecordLegacyFallback();
}

void RecordRelativeFallbackDisposition(RelativeFallbackDisposition disposition) {
    switch (disposition) {
        case RelativeFallbackDisposition::Enqueued:
            g.relativeFallbackEnqueued.fetch_add(1, std::memory_order_relaxed);
            break;
        case RelativeFallbackDisposition::EnqueueFailed: {
            const uint64_t count = g.relativeFallbackEnqueueFailed.fetch_add(
                1, std::memory_order_relaxed) + 1u;
            // Shadow can be disabled in production. First/power-of-two logging
            // keeps bridge loss diagnosable even when no neutral session exists
            // to emit a teardown summary, without flooding the input callback.
            if (IsFirstOrPowerOfTwo(count)) {
                OH_LOG_ERROR(LOG_APP,
                    "physical relative fallback enqueue failed count=%{public}llu",
                    (unsigned long long)count);
            }
            break;
        }
        case RelativeFallbackDisposition::ZeroDelta:
            g.relativeFallbackZeroDelta.fetch_add(1, std::memory_order_relaxed);
            break;
        case RelativeFallbackDisposition::TypedRouteRejected:
            g.relativeFallbackTypedRejected.fetch_add(1, std::memory_order_relaxed);
            break;
        case RelativeFallbackDisposition::GateRejected: {
            const uint64_t count = g.relativeFallbackGateRejected.fetch_add(
                1, std::memory_order_relaxed) + 1u;
            if (IsFirstOrPowerOfTwo(count)) {
                OH_LOG_WARN(LOG_APP,
                    "physical relative fallback gate rejected count=%{public}llu",
                    (unsigned long long)count);
            }
            break;
        }
        case RelativeFallbackDisposition::InvalidDelta: {
            const uint64_t count = g.relativeFallbackInvalidDelta.fetch_add(
                1, std::memory_order_relaxed) + 1u;
            if (IsFirstOrPowerOfTwo(count)) {
                OH_LOG_ERROR(LOG_APP,
                    "physical relative fallback rejected non-finite delta count=%{public}llu",
                    (unsigned long long)count);
            }
            break;
        }
    }
    MaybeSample();
}

void RecordPhysicalRelativeInvalidDelta() {
    const uint64_t count = g.physicalRelativeInvalidDelta.fetch_add(
        1, std::memory_order_relaxed) + 1u;
    if (IsFirstOrPowerOfTwo(count)) {
        OH_LOG_ERROR(LOG_APP,
            "physical relative ingress rejected non-finite delta count=%{public}llu",
            (unsigned long long)count);
    }
    MaybeSample();
}

void RecordPhysicalRelativeEnqueueFailed() {
    const uint64_t count = g.physicalRelativeEnqueueFailed.fetch_add(
        1, std::memory_order_relaxed) + 1u;
    if (IsFirstOrPowerOfTwo(count)) {
        OH_LOG_ERROR(LOG_APP,
            "physical relative legacy enqueue failed count=%{public}llu",
            (unsigned long long)count);
    }
    MaybeSample();
}

void RecordPhysicalIngressOutcome(PhysicalIngressKind kind,
                                  AmclLegacyPhysicalOutcome outcome,
                                  uint64_t deviceId, uint32_t rawControl,
                                  uint32_t action) {
    size_t kindIndex = 0;
    size_t outcomeIndex = 0;
    if (!PhysicalKindIndex(kind, &kindIndex) ||
        !PhysicalOutcomeIndex(outcome, &outcomeIndex)) {
        return;
    }
    // Only key/button carry an action. Relative and wheel pass the default 0,
    // and bucketing those would produce a "no action" column whose value is just
    // their outcome-matrix total restated -- so they are deliberately skipped
    // rather than counted into slot 0.
    if (kind == PhysicalIngressKind::Key || kind == PhysicalIngressKind::Button) {
        const size_t actionIndex =
            action < kPhysicalActionSlotCount ? static_cast<size_t>(action) : 0u;
        g.physicalActions[kindIndex][actionIndex].fetch_add(
            1u, std::memory_order_relaxed);
    }
    const uint64_t count = g.physicalIngressOutcomes[kindIndex][outcomeIndex]
        .fetch_add(1u, std::memory_order_relaxed) + 1u;
    // Successful/aggregated delivery is still counted but not logged per edge.
    // Every anomalous cell logs at the first and power-of-two occurrences, so
    // shadow-off deployments remain diagnosable without callback-rate flooding.
    if (IsOperationalFailure(outcome) && IsFirstOrPowerOfTwo(count)) {
        OH_LOG_WARN(LOG_APP,
            "physical ingress outcome kind=%{public}s outcome=%{public}s "
            "count=%{public}llu device=%{public}llu raw=%{public}u action=%{public}u",
            PhysicalKindName(kind), PhysicalOutcomeName(outcome),
            (unsigned long long)count, (unsigned long long)deviceId,
            rawControl, action);
    }
    MaybeSample();
}

void RecordPhysicalMappingUnavailable(PhysicalIngressKind kind,
                                      uint64_t deviceId,
                                      uint32_t rawControl,
                                      uint32_t action) {
    size_t kindIndex = 0;
    if (!PhysicalKindIndex(kind, &kindIndex)) return;
    const uint64_t count = g.physicalMappingUnavailable[kindIndex].fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (IsFirstOrPowerOfTwo(count)) {
        OH_LOG_WARN(LOG_APP,
            "physical mapping unavailable kind=%{public}s count=%{public}llu "
            "device=%{public}llu raw=%{public}u action=%{public}u",
            PhysicalKindName(kind), (unsigned long long)count,
            (unsigned long long)deviceId, rawControl, action);
    }
    MaybeSample();
}

void SetHeld(uint64_t keys, uint64_t buttons) {
    g.heldKeys.store(keys, std::memory_order_relaxed);
    g.heldButtons.store(buttons, std::memory_order_relaxed);
}

ObservationToken BeginKeyObservation(uint64_t deviceId, uint64_t rawKey,
                                     uint32_t typedAction, int32_t mappedKey,
                                     bool typedAccepted) {
    return gReconciliation.BeginKey(deviceId, rawKey, typedAction, mappedKey,
                                    typedAccepted);
}

ObservationToken BeginRelativeObservation(bool typedAccepted) {
    return gReconciliation.BeginRelative(typedAccepted);
}

ObservationToken BeginButtonObservation(uint64_t deviceId, uint32_t nativeButton,
                                        uint32_t typedAction, int32_t mappedButton,
                                        bool typedAccepted) {
    return gReconciliation.BeginButton(deviceId, nativeButton, typedAction,
                                       mappedButton, typedAccepted);
}

ObservationToken BeginWheelObservation(bool typedAccepted) {
    return gReconciliation.BeginWheel(typedAccepted);
}

void FinalizeObservation(ObservationToken token, LegacyResult result,
                         int32_t legacyAction, uint32_t legacyCount,
                         int32_t legacyMappedOverride) {
    if (token != 0) {
        gReconciliation.Finalize(token, result, legacyAction, legacyCount,
                                 legacyMappedOverride);
    }
}

void RecordGateRejected() {
    gReconciliation.RecordGateRejected();
}

void ResetReconciliation() {
    gReconciliation.ResetHeld();
}

#ifdef AMCL_INPUT_HOST_TESTING
reconciliation::Summary TestReconciliationSnapshot() {
    return gReconciliation.Snapshot();
}

RelativeFallbackSummary TestRelativeFallbackSnapshot() {
    RelativeFallbackSummary result{};
    result.selected = Load(g.relativeFallbackSelected);
    result.enqueued = Load(g.relativeFallbackEnqueued);
    result.enqueueFailed = Load(g.relativeFallbackEnqueueFailed);
    result.zeroDelta = Load(g.relativeFallbackZeroDelta);
    result.typedRouteRejected = Load(g.relativeFallbackTypedRejected);
    result.gateRejected = Load(g.relativeFallbackGateRejected);
    result.invalidDelta = Load(g.relativeFallbackInvalidDelta);
    return result;
}

PhysicalRelativeIngressSummary TestPhysicalRelativeIngressSnapshot() {
    PhysicalRelativeIngressSummary result{};
    result.invalidDelta = Load(g.physicalRelativeInvalidDelta);
    result.enqueueFailed = Load(g.physicalRelativeEnqueueFailed);
    return result;
}

CoreSubmissionSummary TestCoreSubmissionSnapshot() {
    CoreSubmissionSummary result{};
    result.submitted = Load(g.submitted);
    result.errors = Load(g.errors);
    return result;
}

EpochRecoverySummary TestEpochRecoverySnapshot() {
    EpochRecoverySummary result{};
    result.recovered = Load(g.epochRecovered);
    result.failedClosed = Load(g.sessionFailedClosed);
    return result;
}

CoreDiagnosticSummary TestCoreDiagnosticSnapshot() {
    CoreDiagnosticSummary result{};
    result.unsupported = Load(g.unsupported);
    result.diagnosticDrops = Load(g.diagnosticDrops);
    return result;
}

MissingFieldSummary TestMissingFieldSnapshot() {
    MissingFieldSummary result{};
    result.device = Load(g.missingDevice);
    result.scanCode = Load(g.missingScanCode);
    result.lockState = Load(g.missingLockState);
    result.rawDelta = Load(g.missingRawDelta);
    result.cursorTransform = Load(g.missingCursorTransform);
    return result;
}

uint64_t TestPhysicalIngressOutcomeCount(
        PhysicalIngressKind kind, AmclLegacyPhysicalOutcome outcome) {
    size_t kindIndex = 0;
    size_t outcomeIndex = 0;
    if (!PhysicalKindIndex(kind, &kindIndex) ||
        !PhysicalOutcomeIndex(outcome, &outcomeIndex)) {
        return 0u;
    }
    return Load(g.physicalIngressOutcomes[kindIndex][outcomeIndex]);
}

uint64_t TestPhysicalMappingUnavailableCount(PhysicalIngressKind kind) {
    size_t kindIndex = 0;
    if (!PhysicalKindIndex(kind, &kindIndex)) return 0u;
    return Load(g.physicalMappingUnavailable[kindIndex]);
}

uint64_t TestPhysicalActionCount(PhysicalIngressKind kind, uint32_t action) {
    size_t kindIndex = 0;
    if (!PhysicalKindIndex(kind, &kindIndex)) return 0u;
    if (action >= kPhysicalActionSlotCount) return 0u;
    return Load(g.physicalActions[kindIndex][action]);
}

#endif

void LogSessionSummary(const char* reason) {
    const reconciliation::Summary reconciliation = gReconciliation.Snapshot();
    OH_LOG_INFO(LOG_APP,
        "neutral input session summary reason=%{public}s generation=%{public}llu epoch=%{public}llu "
        "submitted=%{public}llu consumed=%{public}llu errors=%{public}llu stale=%{public}llu "
        "unsupported=%{public}llu diagnosticDrops=%{public}llu "
        "missing(device/scan/lock/raw/transform)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu "
        "physicalRelative(invalid/enqueueFailed)=%{public}llu/%{public}llu "
        "relativeFallback(selected/enqueued/failed/zero/typedReject/gateReject/invalid)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu "
        "consumerHeld(keys/buttons)=%{public}llu/%{public}llu "
        "reconcile(begun/dropped/finalized/unresolved/duplicate/unknown/order/unexpected)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu/%{public}llu "
        "result(exact/unmapped/quantized/bridge/fallback/gate/unknown/invalid)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu/%{public}llu "
        "finalHeld(typedKey/legacyKey/typedButton/legacyButton/mappedKeyDiff/mappedButtonDiff)="
        "%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu/%{public}llu",
        reason ? reason : "unknown", (unsigned long long)Load(g.generation),
        (unsigned long long)Load(g.sessionEpoch),
        (unsigned long long)Load(g.submitted), (unsigned long long)Load(g.consumed),
        (unsigned long long)Load(g.errors), (unsigned long long)Load(g.stale),
        (unsigned long long)Load(g.unsupported),
        (unsigned long long)Load(g.diagnosticDrops),
        (unsigned long long)Load(g.missingDevice),
        (unsigned long long)Load(g.missingScanCode),
        (unsigned long long)Load(g.missingLockState),
        (unsigned long long)Load(g.missingRawDelta),
        (unsigned long long)Load(g.missingCursorTransform),
        (unsigned long long)Load(g.physicalRelativeInvalidDelta),
        (unsigned long long)Load(g.physicalRelativeEnqueueFailed),
        (unsigned long long)Load(g.relativeFallbackSelected),
        (unsigned long long)Load(g.relativeFallbackEnqueued),
        (unsigned long long)Load(g.relativeFallbackEnqueueFailed),
        (unsigned long long)Load(g.relativeFallbackZeroDelta),
        (unsigned long long)Load(g.relativeFallbackTypedRejected),
        (unsigned long long)Load(g.relativeFallbackGateRejected),
        (unsigned long long)Load(g.relativeFallbackInvalidDelta),
        (unsigned long long)Load(g.heldKeys),
        (unsigned long long)Load(g.heldButtons),
        (unsigned long long)reconciliation.begun,
        (unsigned long long)reconciliation.droppedBegin,
        (unsigned long long)reconciliation.finalized,
        (unsigned long long)reconciliation.unresolved,
        (unsigned long long)reconciliation.duplicateFinalize,
        (unsigned long long)reconciliation.unknownFinalize,
        (unsigned long long)reconciliation.orderMismatch,
        (unsigned long long)reconciliation.unexpectedMismatch,
        (unsigned long long)reconciliation.exact,
        (unsigned long long)reconciliation.unmapped,
        (unsigned long long)reconciliation.quantized,
        (unsigned long long)reconciliation.bridgeUnavailable,
        (unsigned long long)reconciliation.legacyFallback,
        (unsigned long long)reconciliation.gateRejected,
        (unsigned long long)reconciliation.unknownButton,
        (unsigned long long)reconciliation.invalidInput,
        (unsigned long long)reconciliation.typedHeldKeys,
        (unsigned long long)reconciliation.legacyHeldKeys,
        (unsigned long long)reconciliation.typedHeldButtons,
        (unsigned long long)reconciliation.legacyHeldButtons,
        (unsigned long long)reconciliation.mappedKeySymmetricDifference,
        (unsigned long long)reconciliation.mappedButtonSymmetricDifference);

    uint64_t totals[kPhysicalIngressKindCount]{};
    uint64_t failures[kPhysicalIngressKindCount]{};
    for (size_t kind = 0; kind < kPhysicalIngressKindCount; ++kind) {
        for (size_t outcome = 0; outcome < kPhysicalOutcomeCount; ++outcome) {
            const uint64_t count = Load(g.physicalIngressOutcomes[kind][outcome]);
            totals[kind] += count;
            if (IsOperationalFailure(
                    static_cast<AmclLegacyPhysicalOutcome>(outcome))) {
                failures[kind] += count;
            }
        }
    }
    OH_LOG_INFO(LOG_APP,
        "physical ingress session outcomes total/failure "
        "key=%{public}llu/%{public}llu button=%{public}llu/%{public}llu "
        "wheel=%{public}llu/%{public}llu relative=%{public}llu/%{public}llu "
        "mappingUnavailable(key/button)=%{public}llu/%{public}llu",
        (unsigned long long)totals[0], (unsigned long long)failures[0],
        (unsigned long long)totals[1], (unsigned long long)failures[1],
        (unsigned long long)totals[2], (unsigned long long)failures[2],
        (unsigned long long)totals[3], (unsigned long long)failures[3],
        (unsigned long long)Load(g.physicalMappingUnavailable[0]),
        (unsigned long long)Load(g.physicalMappingUnavailable[1]));
    // §11 per-action counts, producer side. Emitted as its own record so a hilog
    // line-length truncation cannot eat it.
    //
    // `other` is the **out-of-range action** slot: it collects samples whose
    // action value is not in {DOWN, REPEAT, UP} (slot index 0 via
    // `action < 4 ? action : 0`).
    //
    // ⚠️ It is NOT "the action did not pair with its mapped control" slot.
    // The old wording said that, and the reverse inference it invites is wrong:
    // the common mismatch (e.g. action=DOWN paired with mappedAction=RELEASE)
    // has an action still inside 1..3, so it lands in down/repeat/up like any
    // other sample. `other == 0` therefore does NOT mean "no producer ever
    // submitted a mismatched pair" -- for that, read the
    // `AMCL_LEGACY_PHYSICAL_INVALID_ACTION` outcome counter instead.
    const size_t keyIndex = static_cast<size_t>(PhysicalIngressKind::Key);
    const size_t buttonIndex = static_cast<size_t>(PhysicalIngressKind::Button);
    OH_LOG_INFO(LOG_APP,
        "physical ingress session actions "
        "key(down/repeat/up/other)=%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu "
        "button(down/repeat/up/other)=%{public}llu/%{public}llu/%{public}llu/"
        "%{public}llu",
        (unsigned long long)Load(g.physicalActions[keyIndex]
                                                 [AMCL_INPUT_ACTION_DOWN]),
        (unsigned long long)Load(g.physicalActions[keyIndex]
                                                 [AMCL_INPUT_ACTION_REPEAT]),
        (unsigned long long)Load(g.physicalActions[keyIndex]
                                                 [AMCL_INPUT_ACTION_UP]),
        (unsigned long long)Load(g.physicalActions[keyIndex][0]),
        (unsigned long long)Load(g.physicalActions[buttonIndex]
                                                 [AMCL_INPUT_ACTION_DOWN]),
        (unsigned long long)Load(g.physicalActions[buttonIndex]
                                                 [AMCL_INPUT_ACTION_REPEAT]),
        (unsigned long long)Load(g.physicalActions[buttonIndex]
                                                 [AMCL_INPUT_ACTION_UP]),
        (unsigned long long)Load(g.physicalActions[buttonIndex][0]));
}

}  // namespace amcl::input::trace

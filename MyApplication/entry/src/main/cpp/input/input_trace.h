#ifndef AMCL_INPUT_TRACE_H
#define AMCL_INPUT_TRACE_H

#include <cstdint>

#include "input_reconciliation.h"
#include "legacy_physical_outcome.h"

namespace amcl::input::trace {

using ObservationToken = uint64_t;
using LegacyResult = reconciliation::LegacyResult;

enum class MissingField : uint32_t {
    Device = 0,
    ScanCode = 1,
    LockState = 2,
    RawDelta = 3,
    CursorTransform = 4,
};

enum class RelativeFallbackDisposition : uint8_t {
    Enqueued = 0,
    EnqueueFailed = 1,
    ZeroDelta = 2,
    TypedRouteRejected = 3,
    GateRejected = 4,
    InvalidDelta = 5,
};

// Operational delivery is independent of the optional reconciliation plane.
// Every physical transaction records exactly one final outcome in this matrix;
// mapping availability is an orthogonal fact because an unknown UP may still
// release the immutable mapping captured by its DOWN.
enum class PhysicalIngressKind : uint8_t {
    Key = 0,
    Button = 1,
    Wheel = 2,
    Relative = 3,
};

void BeginSession(uint64_t generation, uint64_t sessionEpoch);
void RecordSubmitted(int32_t result);
void RecordConsumed();
void RecordConsumerError(bool stale);
void RecordUnsupported();
// Records an authoritative core diagnostic event for an input edge that was
// intentionally rejected without mutating held state. Keep this distinct from
// unsupported platform capabilities/mappings in operational summaries.
void RecordDiagnosticDrop();
void RecordMissing(MissingField field);
// Selection and completion are separate observations: selecting the legacy
// route does not prove that the checked bridge enqueue accepted the delta.
// `reconcile` is false when AMCL_INPUT_SHADOW disables the comparison plane;
// diagnostics still count the outcome without mutating reconciliation state.
void RecordRelativeFallbackSelected(bool reconcile);
void RecordRelativeFallbackDisposition(RelativeFallbackDisposition disposition);
// Ordinary rawDelta-present physical-relative ingress has its own invalid-delta
// diagnostic. Field presence/finite values do not claim Gate 0 has approved the
// delta semantics (R1/R2/R3, plan section 83.8). Keep this separate from
// rawDelta-missing fallback counters:
// legacy+shadow0 has no reconciliation/session summary to expose that loss.
void RecordPhysicalRelativeInvalidDelta();
void RecordPhysicalRelativeEnqueueFailed();
void RecordPhysicalIngressOutcome(PhysicalIngressKind kind,
                                  AmclLegacyPhysicalOutcome outcome,
                                  uint64_t deviceId = 0,
                                  uint32_t rawControl = 0,
                                  uint32_t action = 0);
void RecordPhysicalMappingUnavailable(PhysicalIngressKind kind,
                                      uint64_t deviceId,
                                      uint32_t rawControl,
                                      uint32_t action);
void SetHeld(uint64_t keys, uint64_t buttons);

ObservationToken BeginKeyObservation(uint64_t deviceId, uint64_t rawKey,
                                     uint32_t typedAction, int32_t mappedKey,
                                     bool typedAccepted);
ObservationToken BeginRelativeObservation(bool typedAccepted);
ObservationToken BeginButtonObservation(uint64_t deviceId, uint32_t nativeButton,
                                        uint32_t typedAction, int32_t mappedButton,
                                        bool typedAccepted);
ObservationToken BeginWheelObservation(bool typedAccepted);
void FinalizeObservation(ObservationToken token, LegacyResult result,
                         int32_t legacyAction = -1, uint32_t legacyCount = 0,
                         int32_t legacyMappedOverride =
                             reconciliation::kNoLegacyMappedOverride);
void RecordGateRejected();
void ResetReconciliation();

// ============================================================================
// Typed-core epoch recovery, and fail-closed teardown of the local session
// mirror. Both are recorded at the single funnel that performs the effect
// (`RecoverEpochFailureLocked`'s success tail and `FailClosedLocked`
// respectively) rather than at their callers -- deliberately, so that adding a
// new caller cannot forget to count, and so that no comment here has to carry a
// call-site count that would rot.
//
// These two counters are **process-lifetime**: `BeginSession()` resets every
// other counter in this file and must not reset these. That exclusion is
// load-bearing, not tidiness:
//
//   * `LogSessionSummary` has exactly one *product* caller,
//     `PlatformInputSurfaceDestroyed`, and it is reached only after that
//     function's `g.sessionActive` check. Failing closed sets sessionActive = 0,
//     so the very next destroy early-returns *before* the summary. The session
//     with the most diagnostic value is the one that would print nothing.
//   * The next `PlatformInputSurfaceCreated` calls `BeginSession()`. A
//     per-session counter would therefore be zeroed before anyone could read it.
//
// Each occurrence also logs one line at the moment it happens (first occurrence
// and powers of two thereafter), for the same reason spec §七.1 gives: an
// observation point whose only firing time is an idle boundary is not an
// observation point. Before these existed, "did recovery ever run on a real
// device?" had no answer -- `errors`/`stale` cannot answer it, because recovery's
// own getSnapshot/openConsumer/closeConsumer calls land in the same bucket as
// the failure that triggered it, and because every input event submitted after a
// fail-closed teardown bumps them again via the session guard.
void RecordEpochRecovered();
void RecordSessionFailedClosed();
#ifdef AMCL_INPUT_HOST_TESTING
// Test-only visibility into shadow reconciliation; production exposes only
// sampled logs so backend code cannot acquire a second state owner.
reconciliation::Summary TestReconciliationSnapshot();

struct RelativeFallbackSummary {
    uint64_t selected = 0;
    uint64_t enqueued = 0;
    uint64_t enqueueFailed = 0;
    uint64_t zeroDelta = 0;
    uint64_t typedRouteRejected = 0;
    uint64_t gateRejected = 0;
    uint64_t invalidDelta = 0;
};

// Read-only atomic diagnostics for the shipping fallback transaction seam.
RelativeFallbackSummary TestRelativeFallbackSnapshot();

struct PhysicalRelativeIngressSummary {
    uint64_t invalidDelta = 0;
    uint64_t enqueueFailed = 0;
};

PhysicalRelativeIngressSummary TestPhysicalRelativeIngressSnapshot();

struct CoreSubmissionSummary {
    uint64_t submitted = 0;
    uint64_t errors = 0;
};

CoreSubmissionSummary TestCoreSubmissionSnapshot();

struct EpochRecoverySummary {
    uint64_t recovered = 0;
    uint64_t failedClosed = 0;
};

// Read-back for the two process-lifetime recovery counters. They are cumulative
// across sessions on purpose, so a test may only assert monotonic growth against
// a value it sampled itself -- never equality with an absolute number.
EpochRecoverySummary TestEpochRecoverySnapshot();

struct CoreDiagnosticSummary {
    uint64_t unsupported = 0;
    uint64_t diagnosticDrops = 0;
};

// Verifies that capability/field gaps and intentional edge drops remain
// independently observable; neither counter owns input state.
CoreDiagnosticSummary TestCoreDiagnosticSnapshot();

struct MissingFieldSummary {
    uint64_t device = 0;
    uint64_t scanCode = 0;
    uint64_t lockState = 0;
    uint64_t rawDelta = 0;
    uint64_t cursorTransform = 0;
};

// Read-back for the per-field platform-gap counters. This exists so the
// producer-side contract can be asserted instead of only logged: a real
// deviceId/latch snapshot must stop incrementing these, and a VALID latch
// snapshot with all latches off must NOT be counted as missing (otherwise the
// counter can never reach zero on a correctly reporting device).
MissingFieldSummary TestMissingFieldSnapshot();

uint64_t TestPhysicalIngressOutcomeCount(
    PhysicalIngressKind kind, AmclLegacyPhysicalOutcome outcome);
uint64_t TestPhysicalMappingUnavailableCount(PhysicalIngressKind kind);
// §11 producer-side per-action count. `action` is a raw AMCL_INPUT_ACTION_*
// value; 0 reads the "outside DOWN/REPEAT/UP" slot. Only Key and Button are
// tracked -- Relative/Wheel have no action and always read 0. These are the
// actions the platform reported at ingress, not the post-arbitration counts
// InputStateCore reports, so a duplicate DOWN appears here as DOWN.
uint64_t TestPhysicalActionCount(PhysicalIngressKind kind, uint32_t action);
#endif
void LogSessionSummary(const char* reason);

}  // namespace amcl::input::trace

#endif

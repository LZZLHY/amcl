#ifndef AMCL_PLATFORM_INPUT_INGRESS_H
#define AMCL_PLATFORM_INPUT_INGRESS_H

#include <cstdint>

#include "amcl_input_event.h"
#include "legacy_physical_outcome.h"

namespace amcl::input {

// Pointer identity observed on the same platform packet as motion/button/wheel.
// Zero/UNKNOWN are explicit and safe: the legacy XComponent mouse callback has
// neither deviceId nor tool class, while ArkUI MouseEvent and native AXIS do.
// `monotonicTimeNs` is accepted only with a known non-zero platform timestamp;
// core otherwise stamps its transaction time.
struct PlatformInputPointerIdentity {
    uint64_t deviceId = 0u;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    uint64_t monotonicTimeNs = 0u;
};

// `publicationGeneration` is the process-local generation returned by the
// retained OHNativeWindow publication. It is deliberately independent from the
// core surfaceEpoch. Native pointer samples must present the same generation;
// ingress then uses the surfaceEpoch that was atomically bound when this
// lifecycle publication succeeded. Zero preserves the pre-Phase-3.3 lifecycle
// path but can never authorize verified native absolute input.
void PlatformInputSurfaceCreated(uint32_t widthPx, uint32_t heightPx,
                                 uint64_t publicationGeneration = 0u);
void PlatformInputSurfaceChanged(uint32_t widthPx, uint32_t heightPx,
                                 uint64_t publicationGeneration = 0u);
void PlatformInputSurfaceDestroyed(uint64_t publicationGeneration = 0u);
void PlatformInputFocusChanged(bool focused);

// Publishes the current game Window/display facts. The latest valid payload is
// cached even before a native surface/session exists and is replayed after the
// next accepted SURFACE_CHANGED. Returns true when the payload was cached (and,
// when a session is live, delivered or deliberately degraded for an older V1
// host); false means invalid/stale or a host delivery failure.
bool PlatformInputSurfaceContextChanged(
    const AmclInputSurfaceContextPayload& context);

// Physical device add/remove from the platform's inputDevice listener.
//
// REMOVED is the only mechanism that releases held owners for exactly one
// device (§6.4): core emits a deterministic UP per owner of that deviceId and
// leaves every other device untouched. It is safe to call after the producer has
// already synthesized UP edges for the legacy compatibility plane — the
// core-side release is idempotent once no owner remains.
//
// `deviceId == 0` is rejected as a countable field gap: 0 is the bucket shared by
// every edge whose identity was unavailable, so releasing it would cancel
// unrelated owners. `capabilities` is masked to AMCL_INPUT_DEVICE_CAP_MASK;
// unknown bits are dropped and counted rather than forwarded, so a producer bug
// can never advertise POINTER_RELATIVE/CAPTURE that Gate 0 has not proven.
void PlatformInputDeviceChanged(uint64_t deviceId, bool added,
                                 uint32_t capabilities,
                                 uint32_t deviceClass =
                                     AMCL_INPUT_DEVICE_CLASS_UNKNOWN);

void PlatformInputCaptureRequested(bool requested);
// Publishes the authoritative platform result for the current capture request.
// Request intent alone must use PlatformInputCaptureRequested and never set
// active=true; only a successful WindowManager operation may call this entry
// with active=true/reason=GRANTED.
void PlatformInputCaptureChanged(bool requested, bool active, uint32_t reason);
void PlatformInputRequestReset(uint32_t reason);

// Typed text is an additive V1 capability carried through the existing
// submitEvent/submitTextPacket table entries. Every payload is fenced by the
// non-zero coordinator generation used as textSessionId. COMMIT/EDITING bytes
// are strict UTF-8; CANDIDATES is the deterministic length-prefixed binary blob
// defined by text_utf8_codec.h. Selection offsets are Unicode-scalar indices.
bool PlatformInputTextSessionSupported();
bool PlatformInputTextSessionBegin(uint64_t textSessionId);
bool PlatformInputTextSessionEnd(uint64_t textSessionId);
bool PlatformInputTextSessionAbort(uint64_t textSessionId);
bool PlatformInputTextCommit(uint64_t textSessionId,
                             const uint8_t* utf8, uint32_t byteCount);
bool PlatformInputTextEditing(uint64_t textSessionId,
                              const uint8_t* utf8, uint32_t byteCount,
                              uint32_t selectionStart,
                              uint32_t selectionLength);
bool PlatformInputTextSelection(uint64_t textSessionId,
                                uint32_t selectionStart,
                                uint32_t selectionLength);
bool PlatformInputTextCandidates(uint64_t textSessionId,
                                 const uint8_t* encoded,
                                 uint32_t encodedByteCount,
                                 uint32_t selected, uint32_t pageStart,
                                 uint32_t pageSize, uint32_t itemCount);

// HarmonyOS InputMethodController currently exposes no candidate-list callback.
// The Entry producer records that named degradation once per attempted text
// session instead of fabricating candidates from preview/commit callbacks.
void PlatformInputNoteCandidatesUnsupported();
uint64_t PlatformInputCandidatesUnsupportedCount();

// Process-lifetime UI reconciliation epoch. Core RESET advances it when
// observed; the legacy cancel transaction advances it again only after all
// touch/schema/ledger owners are empty. ArkTS compares the value but never owns
// or mutates it. The counter saturates rather than wrapping into an old epoch.
uint64_t PlatformInputResetEpoch();
void PlatformInputCompleteResetBoundary();

#ifdef AMCL_INPUT_HOST_TESTING
// ============================================================================
// Host-test-only seams: each submits one sample straight to the neutral core,
// skipping the surface gate, the action-pair validation and the legacy enqueue
// that the shipping `*Transaction` variants own. Use the `*Transaction` variant
// in shipping code.
//
// They are excluded from product translation units so that "no product caller"
// is enforced by the **compiler** rather than promised by a comment. A public
// entry point that skips those guards is a standing invitation for a future
// caller to bypass them.
//
// ⚠️ 2026-08-20: only `PlatformInputPointerRelative` used to carry this
// protection, even though its three siblings are the same shape, have the same
// bypass properties and also had zero product callers. That is the discipline in
// §八.4 of the spec ("the reason for deleting something must also constrain your
// own new code") applied to a guard instead of a deletion: a rule written for
// one of four identical functions is a rule that will be forgotten. All four are
// now inside the same guard, and the product build is the proof that no product
// caller exists -- if one appears, it fails to compile instead of silently
// bypassing the gate.
// ============================================================================
uint64_t PlatformInputPhysicalKey(uint32_t ohosKeyCode, uint32_t hardwareScanCode,
                                  uint32_t hidUsage, uint32_t action,
                                  uint32_t modifiers, uint32_t locks,
                                  uint64_t deviceId, int32_t mappedGlfwKey);
uint64_t PlatformInputPointerRelative(
    double rawDx, double rawDy,
    const PlatformInputPointerIdentity& identity = {});
uint64_t PlatformInputPointerButton(uint64_t deviceId, uint32_t nativeButton,
                                    uint32_t action, int32_t mappedGlfwButton,
                                    uint32_t deviceClass =
                                        AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
                                    uint64_t monotonicTimeNs = 0u);
uint64_t PlatformInputPointerWheel(
    float x, float y, bool precise,
    const PlatformInputPointerIdentity& identity = {});
#endif

void PlatformInputPointerEnter(bool entered);

// Host-table-latched physical source-plane selection. `false` preserves the
// current phone/tablet/desktop legacy route. `true` means physical producers
// submit only typed events; virtual touch/gamepad controls remain on the legacy
// compatibility ring until their own migration phase. The optional capability
// is immutable for the process-owner host and shared across linker namespaces.
bool PlatformInputPhysicalRouteUsesTyped();

// Immutable host-table evidence bit for platform raw/relative semantics.
// Absence is authoritative: a typed relative producer must reject the sample
// without submitting to core and without falling back to the legacy plane.
bool PlatformInputRawRelativeVerified();

// Stronger API 26 contract.  A compatibility API 22-25 build may return true
// from PlatformInputRawRelativeVerified() (legacy name, relative semantics) but
// must return false here and must not mark events as hardware raw.
bool PlatformInputApi26RawMouseMotionSupported();

// Stronger than the general typed-physical selector: this optional immutable
// host capability is present only when native XComponent x/y semantics and the
// GLFW surface sink were enabled by the build evidence gate. When absent, the
// native mouse callback retains its established button/relative behavior.
bool PlatformInputNativeAbsoluteRouteUsesTyped();

// The neutral core must be live whenever either reconciliation or the typed
// physical route needs it. This is deliberately distinct from ShadowEnabled:
// disabling legacy reconciliation must not silently change a latched typed
// producer back to the legacy source plane.
bool PlatformInputCoreEnabled();

void PlatformInputTraceUnverifiedAbsolute();

enum class PlatformInputNativeMouseResult : uint8_t {
    // The optional route bit is absent; caller must preserve the established
    // pre-absolute behavior rather than partially switching source planes.
    RouteInactive = 0,
    GateRejected = 1,
    InvalidSample = 2,
    StaleSurface = 3,
    Submitted = 4,
    SubmitFailed = 5,
};

// Complete verified native XComponent mouse transaction. `typedButtonAction`
// is zero for MOVE, otherwise AMCL_INPUT_ACTION_DOWN/UP. A successful MOVE is
// one POINTER_ABSOLUTE event. DOWN/UP is one submitBatch transaction ordered
// [POINTER_ABSOLUTE, POINTER_BUTTON], so a click can never observe an older
// cursor position. The caller passes the publication generation accepted by
// the surface gate at sample time; this function compares it to the binding
// captured when the core accepted the active dimensions and stamps that bound
// surfaceEpoch explicitly. It never refreshes/replays into a later epoch.
PlatformInputNativeMouseResult PlatformInputNativeSurfaceMouseTransaction(
    uint64_t sampledPublicationGeneration, double localPxX, double localPxY,
    uint64_t deviceId, uint32_t nativeButton, uint32_t typedButtonAction,
    bool gateAccepted,
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
    uint64_t monotonicTimeNs = 0u);

// The shipping compatibility helper owns physical legacy state by raw identity,
// not by mapped GLFW control. `routedMappedKey` receives the DOWN-time mapping
// actually used for an emitted/aggregated edge; this lets an UP whose current
// mapping disappeared still release and reconcile the immutable DOWN snapshot.
// The callback is a host-test seam as well as the NAPI adapter boundary.
using PlatformInputPhysicalKeyRoute = AmclLegacyPhysicalOutcome (*)(
    uint64_t deviceId, uint32_t ohosKeyCode, int32_t mappedGlfwKey,
    int32_t scanCode, int32_t action, int32_t modifiers,
    int32_t* routedMappedKey);

// Complete physical-key transaction used by NAPI and by the host tests. The
// caller must retain its SurfaceInputGateTransaction for this whole call.
//
// ⚠️ Which of the legacy `mapped*` arguments each route actually needs, stated
// precisely because the previous wording was wrong in a way that fails silently:
//
//   * `mappedGlfwAction` is required on BOTH routes. `IsKeyActionPair(action,
//     mappedGlfwAction)` runs before the route fork and before core submission,
//     and a mismatch is a hard `AMCL_LEGACY_PHYSICAL_INVALID_ACTION` return. A typed-route caller
//     that passes a placeholder here has every physical key edge dropped before
//     core ever sees it -- no compile error, no exception, only a bump on the
//     `AMCL_LEGACY_PHYSICAL_INVALID_ACTION` counter.
//   * `mappedGlfwKey` is legacy-only. It is first read after the typed branch
//     has already returned, and `0` (no mapping) is explicitly allowed there.
//   * The checked legacy `route` callback is legacy-only: invoked at most once,
//     never on the typed route.
//
// The wording this replaces was "GLFW mapping and the checked legacy callback
// are consulted only on the legacy route", which lumps the action mapping in
// with the other two. `PlatformInputPhysicalButtonTransaction` below has the
// same `IsButtonActionPair` pre-fork gate, so the same rule applies to it.
//
// (The clause "Core submission always precedes the immutable source-plane
// decision" is about ordering of *effects*: the route bit is read first, but
// core submission happens before anything branches on it.)
AmclLegacyPhysicalOutcome PlatformInputPhysicalKeyTransaction(
    uint32_t ohosKeyCode, uint32_t hardwareScanCode, uint32_t hidUsage,
    uint32_t action, uint32_t modifiers, uint32_t locks, uint64_t deviceId,
    int32_t mappedGlfwKey, int32_t mappedGlfwAction, bool gateAccepted,
    PlatformInputPhysicalKeyRoute route);

using PlatformInputPhysicalButtonRoute = AmclLegacyPhysicalOutcome (*)(
    uint64_t deviceId, uint32_t nativeButton, int32_t mappedGlfwButton,
    int32_t action, int32_t* routedMappedButton);

// Same argument-scope rule as PlatformInputPhysicalKeyTransaction above:
// `mappedGlfwAction` gates BOTH routes through `IsButtonActionPair` before the
// fork, while `mappedGlfwButton` and `route` are legacy-only. This declaration
// previously carried no description at all, which is how the key variant's
// wrong one went unnoticed -- silence and a wrong sentence fail the same way
// once someone has to guess.
AmclLegacyPhysicalOutcome PlatformInputPhysicalButtonTransaction(
    uint64_t deviceId, uint32_t nativeButton, uint32_t typedAction,
    int32_t mappedGlfwButton, int32_t mappedGlfwAction, bool gateAccepted,
    PlatformInputPhysicalButtonRoute route,
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
    uint64_t monotonicTimeNs = 0u);

using PlatformInputRelativeEnqueue = AmclLegacyPhysicalOutcome (*)(
    double dx, double dy);

// Complete NAPI transaction for a rawDelta-present physical-relative sample.
// Field presence and finiteness do not claim Gate 0 has approved the delta
// semantics (R1/R2/R3, plan section 83.8). A typed route requires
// PlatformInputRawRelativeVerified(); when absent, finite input is rejected
// before core mutation and cannot fall back to legacy. Non-finite stays INVALID.
AmclLegacyPhysicalOutcome PlatformInputPhysicalRelativeTransaction(
    double dx, double dy, bool gateAccepted,
    PlatformInputRelativeEnqueue enqueue,
    const PlatformInputPointerIdentity& identity = {});

// Wheel quantization remains in the platform adapter because it owns the
// persistent remainder. The callback reports one operational outcome and the
// exact 0/N detent count; ingress owns gate/route/core selection and optional
// reconciliation. It is invoked at most once and never on the typed route.
using PlatformInputPhysicalWheelRoute = AmclLegacyPhysicalOutcome (*)(
    double x, double y, uint32_t* routedDetentCount);

AmclLegacyPhysicalOutcome PlatformInputPhysicalWheelTransaction(
    double x, double y, bool precise, bool gateAccepted,
    PlatformInputPhysicalWheelRoute route,
    const PlatformInputPointerIdentity& identity = {});

enum class PlatformInputRelativeFallbackResult : uint8_t {
    GateRejected = 0,
    TypedRouteRejected = 1,
    ZeroDelta = 2,
    Enqueued = 3,
    EnqueueFailed = 4,
    InvalidDelta = 5,
};

// The older rawDelta-missing fallback bridge predates the rich physical
// outcome contract. Keep its checked boolean seam separate so it cannot be
// passed accidentally to an ordinary physical-relative transaction.
using PlatformInputRelativeFallbackEnqueue = bool (*)(double dx, double dy);

// Executes the complete rawDelta-missing compatibility decision. The caller
// must keep its SurfaceInputGateTransaction alive until this function returns;
// route selection and the injected checked enqueue then remain in the same
// teardown-excluding transaction. The injected callback is also the host-test
// seam: shipping passes ohos_send_cursor_delta_checked, so tests execute the
// exact route/zero/failure accounting rather than a NAPI-shaped approximation.
// A false callback result is observable EnqueueFailed and is never retried,
// preventing both silent loss and duplicate legacy injection.
PlatformInputRelativeFallbackResult
PlatformInputUnverifiedRelativeFallbackTransaction(
    double dx, double dy, bool gateAccepted,
    PlatformInputRelativeFallbackEnqueue enqueue);

// Process-wide effective state after the one-time AMCL_INPUT_SHADOW override.
bool PlatformInputShadowEnabled();

#ifdef AMCL_INPUT_HOST_TESTING
// One-shot race seam used to prove recovery fails closed if the host session
// changes between snapshot and fresh consumer open. Production has no hook.
using PlatformInputHostTestHook = void (*)();
void PlatformInputTestSetBeforeRecoveryOpenHook(
    PlatformInputHostTestHook hook);
#endif

}  // namespace amcl::input

#endif

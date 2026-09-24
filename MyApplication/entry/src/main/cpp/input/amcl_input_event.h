#ifndef AMCL_INPUT_EVENT_H
#define AMCL_INPUT_EVENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AMCL_INPUT_EVENT_ABI_VERSION 1u
#define AMCL_INPUT_EVENT_FLAG_SYNTHETIC (1u << 0)
#define AMCL_INPUT_EVENT_FLAG_PRECISE (1u << 1)
// A physical button edge carrying this flag is position-bound: its producer
// submitted the edge immediately after a POINTER_ABSOLUTE event in the same
// atomic batch. Consumers must authorize it with that exact preceding sample.
// Button-only routes (notably grabbed-mode input) deliberately leave it clear;
// the process-wide absolute capability is not evidence that every button edge
// belongs to an absolute transaction.
#define AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND (1u << 2)
// POINTER_RELATIVE carries complete hardware movement counts as defined by the
// API 26 rawDelta contract.  Absence means only "relative movement": API 22-25
// values are display-size scaled and must never be advertised as GLFW Raw Input.
#define AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW (1u << 3)
// The producer supplied a platform event timestamp in the same monotonic
// nanosecond domain documented by ArkUI BaseEvent/UIInputEvent.  Core preserves
// it while enforcing non-decreasing delivery order.  When absent, core stamps
// the transaction time as before.  Synthetic recovery records always clear this
// flag because they do not correspond to the original hardware sample.
#define AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP (1u << 4)

#define AMCL_INPUT_SURFACE_FIELD_DIMENSIONS (1u << 0)
#define AMCL_INPUT_SURFACE_FIELD_TRANSFORM (1u << 1)
#define AMCL_INPUT_SURFACE_FIELD_DENSITY (1u << 2)
#define AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION (1u << 3)
#define AMCL_INPUT_SURFACE_FIELD_ALL \
    (AMCL_INPUT_SURFACE_FIELD_DIMENSIONS | \
     AMCL_INPUT_SURFACE_FIELD_TRANSFORM | \
     AMCL_INPUT_SURFACE_FIELD_DENSITY | \
     AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION)

#define AMCL_INPUT_SOURCE_UNKNOWN 0u
#define AMCL_INPUT_SOURCE_KEYBOARD 1u
#define AMCL_INPUT_SOURCE_MOUSE 2u
#define AMCL_INPUT_SOURCE_TOUCHPAD 3u
#define AMCL_INPUT_SOURCE_TOUCH 4u
#define AMCL_INPUT_SOURCE_PEN 5u
#define AMCL_INPUT_SOURCE_IME 6u
#define AMCL_INPUT_SOURCE_VIRTUAL 7u
#define AMCL_INPUT_SOURCE_SYNTHETIC 8u

// Physical pointer device class. This is deliberately independent from
// `source`: source says which neutral event source produced a packet, while
// deviceClass says whether a physical pointer is a mouse or touchpad. Values are
// append-only wire ABI. Unknown is the safe value for older producers and for
// XComponent's legacy mouse callback, whose public structure exposes no device
// identity or tool class.
#define AMCL_INPUT_DEVICE_CLASS_UNKNOWN 0u
#define AMCL_INPUT_DEVICE_CLASS_MOUSE 1u
#define AMCL_INPUT_DEVICE_CLASS_TOUCHPAD 2u
#define AMCL_INPUT_DEVICE_CLASS_COUNT 3u

#define AMCL_INPUT_EVENT_PHYSICAL_KEY 1u
#define AMCL_INPUT_EVENT_POINTER_ABSOLUTE 2u
#define AMCL_INPUT_EVENT_POINTER_RELATIVE 3u
#define AMCL_INPUT_EVENT_POINTER_BUTTON 4u
#define AMCL_INPUT_EVENT_POINTER_WHEEL 5u
#define AMCL_INPUT_EVENT_FOCUS_CHANGED 6u
#define AMCL_INPUT_EVENT_DEVICE_CHANGED 7u
#define AMCL_INPUT_EVENT_CAPTURE_CHANGED 8u
#define AMCL_INPUT_EVENT_SURFACE_CHANGED 9u
#define AMCL_INPUT_EVENT_RESET 10u
#define AMCL_INPUT_EVENT_POINTER_ENTER 11u
#define AMCL_INPUT_EVENT_TEXT_COMMIT 12u
#define AMCL_INPUT_EVENT_TEXT_EDITING 13u
#define AMCL_INPUT_EVENT_TEXT_CANDIDATES 14u
#define AMCL_INPUT_EVENT_TEXT_SELECTION 15u
// Core-generated observability for a physical edge that is intentionally not
// applied. This is an additive V1 event: older consumers safely ignore its
// unknown eventType, while the fixed 120-byte event layout remains unchanged.
#define AMCL_INPUT_EVENT_DIAGNOSTIC_DROP 16u
// Submit-only control packet.  It is consumed by the host core and is never
// assigned a sequence or delivered to ordinary consumers.  Keeping lifecycle
// control in the fixed event envelope avoids growing the V1 function table.
#define AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE 17u
// Current game-window facts published independently from the native render
// surface.  This is an additive V1 event: the fixed event envelope remains
// 120 bytes and older consumers safely ignore eventType 18.
#define AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED 18u
// Additive V1 lifecycle for the single process-wide typed text owner.  The
// fixed 120-byte event envelope is unchanged; older consumers safely ignore
// eventType 19 and the capability bit advertises the new semantics.
#define AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED 19u

#define AMCL_INPUT_TEXT_SESSION_STARTED 1u
#define AMCL_INPUT_TEXT_SESSION_ENDED 2u
#define AMCL_INPUT_TEXT_SESSION_ABORTED 3u

#define AMCL_INPUT_TEXT_SESSION_REASON_NONE 0u
#define AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT 1u
#define AMCL_INPUT_TEXT_SESSION_REASON_FOCUS_LOST 2u
#define AMCL_INPUT_TEXT_SESSION_REASON_SURFACE_LOST 3u
#define AMCL_INPUT_TEXT_SESSION_REASON_RESET 4u
#define AMCL_INPUT_TEXT_SESSION_REASON_INPUT_SESSION_ENDED 5u

// AmclInputSurfaceContextPayload.validFields.  These bits mirror
// gamecontrol/InputSurfaceContext.ets and are append-only wire ABI.
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW (1u << 0)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY (1u << 1)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT (1u << 2)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY (1u << 3)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM (1u << 4)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE (1u << 5)
#define AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL                            \
    (AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW |                         \
     AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY |                        \
     AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT |                           \
     AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY |                        \
     AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM |                      \
     AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE)

#define AMCL_INPUT_ACTION_DOWN 1u
#define AMCL_INPUT_ACTION_REPEAT 2u
#define AMCL_INPUT_ACTION_UP 3u

#define AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_REPEAT 1u
#define AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_KEY_UP 2u
#define AMCL_INPUT_DIAGNOSTIC_DROP_OWNERLESS_BUTTON_UP 3u
#define AMCL_INPUT_DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN 4u

// Platform lock-latch snapshot carried by AmclInputPhysicalKeyPayload.lockState.
//
// Why an explicit VALID bit: a plain zero cannot distinguish "platform reported
// all three latches off" from "this SDK/build did not report latch state at
// all". Without that distinction a consumer would have to guess, and the only
// available guess is "is the lock key currently held" — which the architecture
// forbids (Caps/Num/Scroll are latches, not momentary modifiers; see the
// refactor plan §5.2 and §10.1). Producers therefore set VALID only when the
// platform actually answered, and consumers that see VALID==0 must treat latch
// state as unknown instead of inferring it.
//
// Why VALID lives at bit 16 instead of bit 0: `modifiersSnapshot` and
// `lockState` are adjacent uint32 parameters of the same NAPI/ingress
// signature, so a future argument-order mistake is a realistic failure mode.
// GLFW modifier bits only occupy bits 0..5 (SHIFT 0x01 … NUM_LOCK 0x20), so
// placing VALID above them means a misplaced modifier value can never assert
// "the platform answered". Ingress additionally rejects any bit outside
// AMCL_INPUT_LOCK_STATE_MASK, which catches the CAPS_LOCK/NUM_LOCK modifier
// values. Core never repairs lockState: it stores whatever survived the gate.
//
// ABI: these are stable wire bits. The ArkTS mirror lives in
// gamecontrol/src/main/ets/KeyMap.ets (AMCL_LOCK_STATE_*) and the two must be
// changed together; adding a latch means appending a new bit inside the mask,
// never renumbering an existing one.
#define AMCL_INPUT_LOCK_STATE_CAPS (1u << 0)
#define AMCL_INPUT_LOCK_STATE_NUM (1u << 1)
#define AMCL_INPUT_LOCK_STATE_SCROLL (1u << 2)
#define AMCL_INPUT_LOCK_STATE_VALID (1u << 16)
#define AMCL_INPUT_LOCK_STATE_MASK                                       \
    (AMCL_INPUT_LOCK_STATE_VALID | AMCL_INPUT_LOCK_STATE_CAPS |          \
     AMCL_INPUT_LOCK_STATE_NUM | AMCL_INPUT_LOCK_STATE_SCROLL)

#define AMCL_INPUT_DEVICE_ADDED 1u
#define AMCL_INPUT_DEVICE_REMOVED 2u

#define AMCL_INPUT_DEVICE_CAP_KEYBOARD (1u << 0)
#define AMCL_INPUT_DEVICE_CAP_POINTER_ABSOLUTE (1u << 1)
#define AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE (1u << 2)
#define AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS (1u << 3)
#define AMCL_INPUT_DEVICE_CAP_WHEEL (1u << 4)
#define AMCL_INPUT_DEVICE_CAP_TEXT (1u << 5)
#define AMCL_INPUT_DEVICE_CAP_HOVER (1u << 6)
#define AMCL_INPUT_DEVICE_CAP_CAPTURE (1u << 7)
// Every currently defined capability bit. Ingress rejects anything outside this
// mask so an out-of-date producer cannot advertise a capability this ABI has no
// meaning for. The ArkTS mirror lives in
// gamecontrol/src/main/ets/InputDeviceAbi.ets (AMCL_DEVICE_CAP_*).
#define AMCL_INPUT_DEVICE_CAP_MASK                                       \
    (AMCL_INPUT_DEVICE_CAP_KEYBOARD | AMCL_INPUT_DEVICE_CAP_POINTER_ABSOLUTE | \
     AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE |                            \
     AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS | AMCL_INPUT_DEVICE_CAP_WHEEL | \
     AMCL_INPUT_DEVICE_CAP_TEXT | AMCL_INPUT_DEVICE_CAP_HOVER |          \
     AMCL_INPUT_DEVICE_CAP_CAPTURE)

#define AMCL_INPUT_WHEEL_UNIT_PIXEL 1u
#define AMCL_INPUT_WHEEL_UNIT_LINE 2u
#define AMCL_INPUT_WHEEL_UNIT_PAGE 3u
#define AMCL_INPUT_WHEEL_UNIT_DEGREE 4u

#define AMCL_INPUT_CAPTURE_REASON_NONE 0u
#define AMCL_INPUT_CAPTURE_REASON_GRANTED 1u
#define AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST 2u
#define AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST 3u
#define AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST 4u
#define AMCL_INPUT_CAPTURE_REASON_UNSUPPORTED 5u
#define AMCL_INPUT_CAPTURE_REASON_PERMISSION_DENIED 6u
#define AMCL_INPUT_CAPTURE_REASON_INVALID_ARGUMENT 7u
#define AMCL_INPUT_CAPTURE_REASON_PLATFORM_ERROR 8u
// One past the highest defined capture reason. This is a diagnostics array bound
// (§11 requires capture losses to be reported per reason), not a wire value, so
// it must never be transmitted in a payload. Adding a reason means appending it
// above and bumping this by one; the per-reason counters are then sized from
// this constant and a stale bound becomes a bucketing bug rather than an OOB
// write, because the recorder range-checks the reason against it.
#define AMCL_INPUT_CAPTURE_REASON_COUNT 9u

#define AMCL_INPUT_RESET_EXPLICIT 1u
#define AMCL_INPUT_RESET_FOCUS_LOST 2u
#define AMCL_INPUT_RESET_CAPTURE_LOST 3u
#define AMCL_INPUT_RESET_SURFACE_CHANGED 4u
#define AMCL_INPUT_RESET_SESSION_CHANGED 5u
#define AMCL_INPUT_RESET_QUEUE_OVERFLOW 6u
#define AMCL_INPUT_RESET_DEVICE_REMOVED 7u
#define AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED 8u
#define AMCL_INPUT_RESET_CONSUMER_BASELINE 9u
#define AMCL_INPUT_RESET_APPLICATION_BACKGROUND 10u
#define AMCL_INPUT_RESET_BACKEND_RETIRED 11u
#define AMCL_INPUT_RESET_BACKEND_ABANDONED 12u

#define AMCL_INPUT_BACKEND_CONSUMER_READY 1u
#define AMCL_INPUT_BACKEND_CONSUMER_RETIRE 2u
#define AMCL_INPUT_BACKEND_CONSUMER_ABANDON 3u
// Backend identities. Each MC era binds a different窗口/输入 ABI, so these are
// not implementation choices: LWJGL2 (<=1.12) polls DirectInput scan codes,
// GLFW3 (1.13-26.2) uses callbacks + GLFW key codes, SDL3 (26.3+) wants USB HID
// scancodes. Every one of them translates the SAME raw OHOS identity exactly
// once; the neutral core never learns any of their encodings.
//
// ⚠️ Values are wire-stable and must only be appended. The READY/RETIRE slots in
// the host core are keyed by `backend - 1`, so renumbering silently reassigns a
// live backend's retire barrier to a different consumer.
#define AMCL_INPUT_BACKEND_GLFW_PHYSICAL 1u
#define AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL 2u
#define AMCL_INPUT_BACKEND_SDL3_PHYSICAL 3u
// One past the highest defined backend. This is a slot-array bound, not a wire
// value, so it must never be transmitted. Adding a backend means appending above
// and bumping this by one; a stale bound then becomes a rejected control packet
// rather than an out-of-bounds slot write, because the core range-checks first.
#define AMCL_INPUT_BACKEND_COUNT 4u

typedef struct AmclInputBlobRef {
    uint64_t packetId;
    uint32_t offset;
    uint32_t length;
} AmclInputBlobRef;
typedef struct AmclInputEventHeader {
    uint16_t abiVersion;
    uint16_t structSize;
    uint32_t eventType;
    uint32_t flags;
    uint32_t reserved0;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
    uint64_t deviceId;
    uint32_t source;
    // Additive V1 reuse of the former `reserved1` slot. The offset and the
    // 72-byte header layout are unchanged: old consumers ignore it and new
    // consumers read zero/UNKNOWN from old zero-initialized producers.
    uint32_t deviceClass;
    uint64_t sessionEpoch;
    uint64_t focusEpoch;
    uint64_t surfaceEpoch;
} AmclInputEventHeader;

typedef struct AmclInputPhysicalKeyPayload {
    uint32_t physicalKey;
    uint32_t hardwareScanCode;
    uint32_t hidUsage;
    uint32_t action;
    uint32_t modifiersSnapshot;
    uint32_t lockState;
    uint32_t reserved[2];
} AmclInputPhysicalKeyPayload;

typedef struct AmclInputPointerAbsolutePayload { double localPxX; double localPxY; } AmclInputPointerAbsolutePayload;
// Field names are frozen by event ABI V1.  `rawDx/rawDy` contain relative
// movement in both compatibility and API 26 products; only
// AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW asserts hardware-raw semantics.
typedef struct AmclInputPointerRelativePayload { double rawDx; double rawDy; } AmclInputPointerRelativePayload;
typedef struct AmclInputPointerButtonPayload {
    uint32_t nativeButton;
    uint32_t action;
    uint32_t modifiersSnapshot;
    uint32_t reserved;
} AmclInputPointerButtonPayload;
typedef struct AmclInputPointerWheelPayload { float x; float y; uint32_t unit; uint32_t precise; } AmclInputPointerWheelPayload;
typedef struct AmclInputFocusPayload { uint32_t focused; uint32_t reserved[3]; } AmclInputFocusPayload;
typedef struct AmclInputPointerEnterPayload { uint32_t entered; uint32_t reserved[3]; } AmclInputPointerEnterPayload;
typedef struct AmclInputDevicePayload { uint32_t change; uint32_t capabilities; uint32_t reserved[2]; } AmclInputDevicePayload;
typedef struct AmclInputCapturePayload { uint32_t requested; uint32_t active; uint32_t reason; uint32_t reserved; } AmclInputCapturePayload;
typedef struct AmclInputSurfacePayload {
    uint32_t widthPx;
    uint32_t heightPx;
    uint32_t transform;
    uint32_t active;
    float density;
    uint32_t validFields;
    // Process-local generation of the retained OHNativeWindow publication.
    // This is meaningful only when PUBLICATION_GENERATION is set. It is not a
    // core surfaceEpoch and the two values must never be compared or relabelled:
    // the producer binds them when it publishes this surface, while a backend
    // checks the generation against the native window it will actually target.
    // Reusing the former reserved tail keeps the fixed V1 payload layout.
    uint64_t publicationGeneration;
} AmclInputSurfacePayload;
typedef struct AmclInputResetPayload { uint32_t reason; uint32_t reserved; uint64_t closingEpoch; } AmclInputResetPayload;
// A drop reports the original backend-neutral identity. No mapped backend
// control is present by design, so observing this packet cannot acquire held
// state or manufacture a GLFW/SDL/LWJGL callback.
typedef struct AmclInputDiagnosticDropPayload {
    uint32_t reason;
    uint32_t originalEventType;
    uint32_t rawControl;
    uint32_t action;
    uint32_t hardwareScanCode;
    uint32_t hidUsage;
    uint32_t reserved[6];
} AmclInputDiagnosticDropPayload;

// READY proves that the named consumer has consumed the exact baseline issued
// by this host and has snapshotted the epochs carried in the common header.
// RETIRE and ABANDON use the same identity fields; baselineSequence is zero for
// those operations.  generation is the function-table ABI generation, while
// the opaque handle also embeds that generation and is validated separately.
typedef struct AmclInputBackendConsumerStatePayload {
    uint32_t state;
    uint32_t backend;
    uint64_t consumer;
    uint64_t generation;
    uint64_t baselineSequence;
    uint64_t reserved[2];
} AmclInputBackendConsumerStatePayload;

// Current Window/display context.  `generation` is owned by the ArkTS
// InputSurfaceContext publisher lease and advances only when those semantics
// change.  It is distinct from both core surfaceEpoch and the retained
// OHNativeWindow publicationGeneration carried by AmclInputSurfacePayload.
typedef struct AmclInputSurfaceContextPayload {
    int32_t windowId;
    int32_t displayId;
    int32_t leftPx;
    int32_t topPx;
    uint32_t widthPx;
    uint32_t heightPx;
    float density;
    float refreshRateHz;
    uint32_t transform;
    uint32_t validFields;
    uint64_t generation;
} AmclInputSurfaceContextPayload;

typedef struct AmclInputTextCommitPayload {
    AmclInputBlobRef utf8Blob;
    // Reuses the leading bytes of the old zeroed tail.  Zero means an old V1
    // producer and is rejected when TEXT_INPUT_SESSION is advertised.
    uint64_t textSessionId;
    uint8_t reserved[24];
} AmclInputTextCommitPayload;
typedef struct AmclInputTextEditingPayload {
    AmclInputBlobRef utf8Blob;
    uint32_t selectionStart;
    uint32_t selectionLength;
    uint64_t textSessionId;
    uint8_t reserved[16];
} AmclInputTextEditingPayload;
typedef struct AmclInputTextCandidatesPayload {
    AmclInputBlobRef itemsBlob;
    uint32_t selected;
    uint32_t pageStart;
    uint32_t pageSize;
    uint32_t itemCount;
    uint64_t textSessionId;
    uint8_t reserved[8];
} AmclInputTextCandidatesPayload;
typedef struct AmclInputTextSelectionPayload {
    uint32_t selectionStart;
    uint32_t selectionLength;
    uint64_t textSessionId;
    uint8_t reserved[32];
} AmclInputTextSelectionPayload;
typedef struct AmclInputTextSessionPayload {
    uint64_t textSessionId;
    uint32_t change;
    uint32_t reason;
    uint64_t reserved[4];
} AmclInputTextSessionPayload;

typedef union AmclInputEventPayload {
    AmclInputPhysicalKeyPayload physicalKey;
    AmclInputPointerAbsolutePayload pointerAbsolute;
    AmclInputPointerRelativePayload pointerRelative;
    AmclInputPointerButtonPayload pointerButton;
    AmclInputPointerWheelPayload pointerWheel;
    AmclInputFocusPayload focus;
    AmclInputPointerEnterPayload pointerEnter;
    AmclInputDevicePayload device;
    AmclInputCapturePayload capture;
    AmclInputSurfacePayload surface;
    AmclInputResetPayload reset;
    AmclInputTextCommitPayload textCommit;
    AmclInputTextEditingPayload textEditing;
    AmclInputTextCandidatesPayload textCandidates;
    AmclInputTextSelectionPayload textSelection;
    AmclInputDiagnosticDropPayload diagnosticDrop;
    AmclInputBackendConsumerStatePayload backendConsumerState;
    AmclInputSurfaceContextPayload surfaceContext;
    AmclInputTextSessionPayload textSession;
    uint8_t reserved[48];
} AmclInputEventPayload;

typedef struct AmclInputEvent { AmclInputEventHeader header; AmclInputEventPayload payload; } AmclInputEvent;

#ifdef __cplusplus
}  // extern "C"
#define AMCL_INPUT_STATIC_ASSERT(c, m) static_assert((c), m)
#else
#define AMCL_INPUT_JOIN_INNER(a, b) a##b
#define AMCL_INPUT_JOIN(a, b) AMCL_INPUT_JOIN_INNER(a, b)
#define AMCL_INPUT_STATIC_ASSERT(c, m) \
    typedef char AMCL_INPUT_JOIN(amcl_input_static_assert_, __LINE__)[(c) ? 1 : -1]
#endif

AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputBlobRef) == 16, "blob ref ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputBlobRef, offset) == 8, "blob ref offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputBlobRef, length) == 12, "blob length offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputEventHeader) == 72, "event header ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputEventHeader, deviceClass) == 44,
                         "device class offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputSurfacePayload) == 32, "surface payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputDiagnosticDropPayload) == 48,
                         "diagnostic drop payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputBackendConsumerStatePayload) == 48,
                         "backend consumer state payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputSurfaceContextPayload) == 48,
                         "surface context payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputSurfaceContextPayload, widthPx) == 16,
    "surface context dimensions offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputSurfaceContextPayload, density) == 24,
    "surface context density offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputSurfaceContextPayload, transform) == 32,
    "surface context transform offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputSurfaceContextPayload, generation) == 40,
    "surface context generation offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputBackendConsumerStatePayload, consumer) == 8,
    "backend consumer handle offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputBackendConsumerStatePayload, baselineSequence) == 24,
    "backend baseline sequence offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputDiagnosticDropPayload, rawControl) == 8,
                         "diagnostic raw-control offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputDiagnosticDropPayload, hardwareScanCode) == 16,
                         "diagnostic scan-code offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputSurfacePayload, validFields) == 20,
                         "surface validity offset changed");
AMCL_INPUT_STATIC_ASSERT(
    offsetof(AmclInputSurfacePayload, publicationGeneration) == 24,
    "surface publication generation offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputTextCommitPayload, utf8Blob) == 0, "text blob offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputTextCommitPayload, textSessionId) == 16,
                         "text session offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputTextCandidatesPayload, itemsBlob) == 0, "candidate blob offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputTextCandidatesPayload, textSessionId) == 32,
                         "candidate session offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputTextSessionPayload) == 48,
                         "text session payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputEventHeader, sequence) == 16, "sequence offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputEventHeader, sessionEpoch) == 48, "epoch offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputEventPayload) == 48, "payload ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputEvent, payload) == 72, "payload offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputEvent) == 120, "event ABI changed");
#undef AMCL_INPUT_STATIC_ASSERT
#ifndef __cplusplus
#undef AMCL_INPUT_JOIN
#undef AMCL_INPUT_JOIN_INNER
#endif

#endif

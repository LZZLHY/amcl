#ifndef AMCL_INPUT_API_H
#define AMCL_INPUT_API_H

#include "amcl_input_event.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AMCL_INPUT_HOST_API_MAGIC 0x414D434Cu
#define AMCL_INPUT_HOST_API_VERSION 1u
// This is the ABI generation of the complete function-table layout, not a
// host-instance counter. Session epochs and opaque consumer handles fence core
// state; descriptor table-address identity detects owner rollover. Accepting
// another table generation would let a V1 consumer call unknown offsets.
#define AMCL_INPUT_HOST_API_GENERATION 1ull
#define AMCL_INPUT_CAP_TYPED_EVENTS (1u << 0)
#define AMCL_INPUT_CAP_MULTI_CONSUMER (1u << 1)
#define AMCL_INPUT_CAP_OVERFLOW_RESET (1u << 2)
#define AMCL_INPUT_CAP_OWNED_TEXT_PACKETS (1u << 3)
#define AMCL_INPUT_CAP_SESSION_EPOCHS (1u << 4)
#define AMCL_INPUT_CAP_HOST_GENERATION (1u << 5)
#define AMCL_INPUT_CAP_EXPECTED_EPOCHS (1u << 6)
#define AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS (1u << 7)
#define AMCL_INPUT_CAP_CONSUMER_BASELINE (1u << 8)
#define AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY (1u << 9)
// Transitional Phase 3 source-plane selection. The XComponent-owning host
// latches the startup request once into its table, so platform producers and a
// GLFW consumer in another linker namespace read one immutable decision.
#define AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE (1u << 10)
// The host replaces ownerless/duplicate physical edges with
// AMCL_INPUT_EVENT_DIAGNOSTIC_DROP. A new consumer must require this bit:
// EVENT_ABI_VERSION alone cannot distinguish an older core that silently
// accepted and discarded the same edge before it ever reached a consumer.
#define AMCL_INPUT_CAP_DIAGNOSTIC_DROP (1u << 11)
// The host gates startup-latched typed physical packets on an explicitly
// baselined backend consumer and supports READY/RETIRE/ABANDON through the
// submit-only BACKEND_CONSUMER_STATE control event.
#define AMCL_INPUT_CAP_BACKEND_CONSUMER_READY (1u << 12)
// Build-time evidence gate for usable pointer-relative movement.  This bit does
// NOT assert hardware-raw semantics: API 22-25 rawDelta values are still scaled
// by the system display-size ratio.  The old public name is retained as an ABI
// source alias, but new code must use VERIFIED_POINTER_RELATIVE.
#define AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE (1u << 13)
#define AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE \
    AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE
// Build-time evidence gate for native XComponent absolute coordinates bound to
// one retained NativeWindow publication and one core surface epoch.  The bit is
// published only when the typed physical route is selected and the verified
// absolute consumer is compiled in.  Its absence must leave key/button/wheel
// support unchanged while POINTER_ABSOLUTE remains fail-closed.
#define AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE (1u << 14)
// Independent API 26 declaration for complete hardware rawDelta semantics and
// the GLFW_RAW_MOUSE_MOTION public contract.  It is valid only together with
// the typed route and VERIFIED_POINTER_RELATIVE; consumers must check all three.
#define AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION (1u << 15)
// Optional additive V1 field semantics: AmclInputEventHeader.deviceClass uses
// the former reserved1 slot. This bit is intentionally not part of
// AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1; a new producer can degrade to
// UNKNOWN against an older host without rejecting the entire V1 table.
#define AMCL_INPUT_CAP_DEVICE_CLASS (1u << 16)
// Optional additive V1 event semantics for
// AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED.  It is intentionally not required
// by AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1 so older V1 hosts remain usable.
#define AMCL_INPUT_CAP_SURFACE_CONTEXT (1u << 17)
// Optional additive V1 typed text-session ownership.  Text payloads reuse their
// former reserved tails for textSessionId and eventType 19 carries begin/end/
// abort without growing the frozen function table.
#define AMCL_INPUT_CAP_TEXT_INPUT_SESSION (1u << 18)

#define AMCL_INPUT_OK 0
#define AMCL_INPUT_EMPTY 1
#define AMCL_INPUT_OVERFLOW_RESET 2
#define AMCL_INPUT_DRAIN_REQUIRED 3
#define AMCL_INPUT_ERROR_INVALID_ARGUMENT (-1)
#define AMCL_INPUT_ERROR_ABI_MISMATCH (-2)
#define AMCL_INPUT_ERROR_NOT_FOUND (-3)
#define AMCL_INPUT_ERROR_SESSION (-4)
#define AMCL_INPUT_ERROR_STALE (-5)
#define AMCL_INPUT_ERROR_BUFFER_TOO_SMALL (-6)
#define AMCL_INPUT_ERROR_UNFOCUSED (-7)
#define AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED (-8)
#define AMCL_INPUT_ERROR_BACKEND_NOT_READY (-9)

typedef uint64_t AmclInputConsumerHandle;

typedef struct AmclInputSnapshotV1 {
    uint16_t abiVersion;
    uint16_t structSize;
    // Reuses the V1 reserved prefix without changing the 104-byte ABI.  A late
    // backend consumer needs the complete capture tuple, not only active, or an
    // already-granted capture can remain invisible forever after baseline.
    uint32_t captureRequested;
    uint64_t sessionEpoch;
    uint64_t focusEpoch;
    uint64_t surfaceEpoch;
    uint64_t heldControlCount;
    uint64_t consumerCount;
    uint64_t queuedEventCount;
    uint64_t queueCapacity;
    uint64_t overflowResetCount;
    uint64_t blobBytes;
    uint64_t blobCapacity;
    uint32_t focused;
    uint32_t captureActive;
    uint32_t sessionActive;
    uint32_t captureReason;
} AmclInputSnapshotV1;
typedef struct AmclInputHostApiV1 {
    uint32_t magic;
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t capabilityBits;
    uint64_t generation;

    int32_t (*beginSession)(uint64_t* outSessionEpoch);
    int32_t (*endSession)(uint64_t sessionEpoch);
    int32_t (*submitEvent)(const AmclInputEvent* event);
    int32_t (*submitBatch)(const AmclInputEvent* events, uint32_t count);
    int32_t (*submitTextPacket)(const AmclInputEvent* event,
                                const uint8_t* bytes, uint32_t byteCount);
    int32_t (*publishSurface)(const AmclInputSurfacePayload* surface);
    int32_t (*publishFocus)(uint32_t focused);
    int32_t (*publishDeviceChange)(uint64_t deviceId, uint32_t change,
                                   uint32_t capabilities);
    int32_t (*requestReset)(uint32_t reason);
    int32_t (*openConsumer)(AmclInputConsumerHandle* outConsumer);
    int32_t (*nextEvent)(AmclInputConsumerHandle consumer,
                         AmclInputEvent* outEvent);
    int32_t (*readPacketBlob)(AmclInputConsumerHandle consumer,
                              const AmclInputBlobRef* blob,
                              uint8_t* outBytes, uint32_t outCapacity,
                              uint32_t* outByteCount);
    int32_t (*releasePacket)(AmclInputConsumerHandle consumer,
                             uint64_t packetId);
    int32_t (*closeConsumer)(AmclInputConsumerHandle consumer);
    int32_t (*getSnapshot)(AmclInputSnapshotV1* outSnapshot);
} AmclInputHostApiV1;

#if defined(_WIN32)
#  if defined(AMCL_INPUT_HOST_EXPORTS)
#    define AMCL_INPUT_PUBLIC __declspec(dllexport)
#  else
#    define AMCL_INPUT_PUBLIC
#  endif
#elif defined(__GNUC__)
#  define AMCL_INPUT_PUBLIC __attribute__((visibility("default")))
#else
#  define AMCL_INPUT_PUBLIC
#endif

AMCL_INPUT_PUBLIC const AmclInputHostApiV1* amclInputGetHostApiV1(void);

#ifdef __cplusplus
}  // extern "C"
#define AMCL_INPUT_STATIC_ASSERT(c, m) static_assert((c), m)
#else
#define AMCL_INPUT_JOIN_INNER(a, b) a##b
#define AMCL_INPUT_JOIN(a, b) AMCL_INPUT_JOIN_INNER(a, b)
#define AMCL_INPUT_STATIC_ASSERT(c, m) \
    typedef char AMCL_INPUT_JOIN(amcl_input_static_assert_, __LINE__)[(c) ? 1 : -1]
#endif

AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputSnapshotV1, sessionEpoch) == 8, "snapshot prefix changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputSnapshotV1, captureRequested) == 4,
                         "snapshot capture request offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputSnapshotV1, captureReason) == 100,
                         "snapshot capture reason offset changed");
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputSnapshotV1) == 104, "snapshot ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputHostApiV1, generation) == 16, "generation offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputHostApiV1, beginSession) == 24, "function table prefix changed");
#if UINTPTR_MAX == UINT64_MAX
AMCL_INPUT_STATIC_ASSERT(sizeof(AmclInputHostApiV1) == 144, "64-bit API table ABI changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputHostApiV1, submitTextPacket) == 56, "text API offset changed");
AMCL_INPUT_STATIC_ASSERT(offsetof(AmclInputHostApiV1, readPacketBlob) == 112, "blob API offset changed");
#endif
#undef AMCL_INPUT_STATIC_ASSERT
#ifndef __cplusplus
#undef AMCL_INPUT_JOIN
#undef AMCL_INPUT_JOIN_INNER
#endif

#endif

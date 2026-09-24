#ifndef AMCL_INPUT_HOST_DESCRIPTOR_H
#define AMCL_INPUT_HOST_DESCRIPTOR_H

#include "amcl_input_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// Windows transport key. OHOS/POSIX stores descriptor text in the single
// PID-scoped flock file because libc environment mutation has no portable
// cross-DSO snapshot primitive.
#define AMCL_INPUT_HOST_DESCRIPTOR_ENV "AMCL_INPUT_HOST_DESCRIPTOR"
#define AMCL_INPUT_HOST_DESCRIPTOR_VERSION 1u

#define AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1 \
    (AMCL_INPUT_CAP_TYPED_EVENTS | AMCL_INPUT_CAP_MULTI_CONSUMER | \
     AMCL_INPUT_CAP_OVERFLOW_RESET | AMCL_INPUT_CAP_OWNED_TEXT_PACKETS | \
     AMCL_INPUT_CAP_SESSION_EPOCHS | AMCL_INPUT_CAP_HOST_GENERATION | \
     AMCL_INPUT_CAP_EXPECTED_EPOCHS | AMCL_INPUT_CAP_ATOMIC_TEXT_PACKETS | \
     AMCL_INPUT_CAP_CONSUMER_BASELINE | \
     AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY | \
     AMCL_INPUT_CAP_DIAGNOSTIC_DROP)

typedef enum AmclInputHostDescriptorResult {
    AMCL_INPUT_HOST_DESCRIPTOR_OK = 0,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT = -1,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ENVIRONMENT = -2,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING = -3,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED = -4,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH = -5,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES = -6,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION = -7,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE = -8,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER = -9,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT = -10,
    AMCL_INPUT_HOST_DESCRIPTOR_ERROR_SYNCHRONIZATION = -11
} AmclInputHostDescriptorResult;

/* Publishes exactly one table address; no individual callback address is
 * exposed. Publication is serialized across linker namespaces: the first
 * valid process-lifetime owner wins and a different table receives
 * OWNER_CONFLICT. The pointed table is immutable and both it and its DSO must
 * remain alive for the process; synchronization cannot make an unloaded table
 * safe to call. */
AMCL_INPUT_PUBLIC int32_t amclInputHostDescriptorPublishV1(
    const AmclInputHostApiV1* api);

/* Resolves afresh on every call under the same cross-DSO lock used by publish
 * and clear. A missing/invalid descriptor is recoverable. Generation identifies
 * only the function-table ABI; session epochs, opaque consumer handles and
 * descriptor table-address identity fence runtime state rollover. The returned
 * borrowed pointer remains valid only under the immutable/process-pinned owner
 * contract above. */
AMCL_INPUT_PUBLIC int32_t amclInputHostDescriptorResolveV1(
    const AmclInputHostApiV1** outApi);

/* Test/quiescent-teardown hook only. It is serialized with publish/resolve but
 * does not revoke pointers already borrowed by consumers and must never be used
 * to justify unloading a live owner DSO. */
AMCL_INPUT_PUBLIC int32_t amclInputHostDescriptorClearV1(void);

#ifdef AMCL_INPUT_HOST_TESTING
/* Injects unvalidated descriptor text through the platform transport. Host
 * tests use this to cover malformed input without bypassing synchronization. */
AMCL_INPUT_PUBLIC int32_t amclInputHostDescriptorTestSetRawV1(
    const char* value);
#endif

#ifdef __cplusplus
}  // extern "C"
#endif

#endif

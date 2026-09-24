#ifndef AMCL_LEGACY_PHYSICAL_OUTCOME_H
#define AMCL_LEGACY_PHYSICAL_OUTCOME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Internal compatibility-plane result. This is deliberately separate from the
// fixed AmclInputEvent ABI and from GLFW's public API: callers need to know
// whether a physical transition was actually delivered, merely aggregated, or
// rejected without manufacturing an owner/edge.
typedef enum AmclLegacyPhysicalOutcome {
    AMCL_LEGACY_PHYSICAL_EMITTED = 0,
    AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE = 1,
    AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE = 2,
    AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED = 3,
    AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT = 4,
    AMCL_LEGACY_PHYSICAL_OWNERLESS_UP = 5,
    AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN = 6,
    AMCL_LEGACY_PHYSICAL_INVALID_ACTION = 7,
    AMCL_LEGACY_PHYSICAL_INVALID_VALUE = 8,
    AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL = 9,
    AMCL_LEGACY_PHYSICAL_GATE_REJECTED = 10,
    AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED = 11,
    AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS = 12,
    // The selected source plane lacks a separately certified platform
    // capability. No typed mutation and no legacy fallback occurred.
    AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED = 13
} AmclLegacyPhysicalOutcome;

#ifdef __cplusplus
}
#endif

#endif

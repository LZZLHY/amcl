#ifndef AMCL_GLFW_TYPED_RUNTIME_DISPATCH_H
#define AMCL_GLFW_TYPED_RUNTIME_DISPATCH_H

#include "glfw_source_plane_aggregate.h"
#include "glfw_typed_absolute_route.h"

#include <cstdint>

namespace amcl::input {

// A callback-free view of the GLFW polling state protected by the caller's
// window-binding lease. The opaque identity is returned with a deferred
// notification; this component never invokes external/user code.
struct GlfwTypedRuntimeTarget {
    void* identity = nullptr;
    double* cursorX = nullptr;
    double* cursorY = nullptr;
    int* mouseButtons = nullptr;
    uint32_t mouseButtonCount = 0u;
    uint64_t publicationGeneration = 0u;
    uint32_t widthPx = 0u;
    uint32_t heightPx = 0u;
    bool active = false;
};

// Snapshot obtained while the NativeWindow publication read lease is held.
struct GlfwTypedRuntimePublication {
    uint64_t generation = 0u;
    uint32_t widthPx = 0u;
    uint32_t heightPx = 0u;
    bool active = false;
};

enum class GlfwTypedRuntimeCommitStatus : uint32_t {
    kCommitted = 0u,
    kTargetPublicationMismatch = 1u,
    kRouteRejected = 2u,
    kTargetUnavailable = 3u,
};

struct GlfwTypedRuntimeAbsoluteCommit {
    void* target = nullptr;
    double x = 0.0;
    double y = 0.0;
    bool notify = false;
};

struct GlfwTypedRuntimeButtonCommit {
    void* target = nullptr;
    GlfwAggregateButtonEvent event{};
    bool notify = false;
};

// The caller holds both the target-binding and publication guards for the
// entire call. Success is the linearization point for route authorization and
// GLFW polling state. Notification must happen only after those guards leave.
GlfwTypedRuntimeCommitStatus GlfwTypedRuntimeCommitAbsolute(
    GlfwTypedAbsoluteRoute& route, const GlfwAbsoluteSinkEvent& event,
    const GlfwTypedRuntimeTarget& target,
    const GlfwTypedRuntimePublication& publication,
    GlfwTypedRuntimeAbsoluteCommit& commit);

// Position-bound edges require the same exact target/publication tuple as the
// preceding absolute sample. Unflagged fail-safe/grabbed edges deliberately
// bypass that tuple check, but still clear any stale absolute authorization and
// commit through the same typed/legacy aggregate. With no callback target only
// RELEASE is accepted, so teardown can clear an existing owner but cannot
// create a new invisible press.
GlfwTypedRuntimeCommitStatus GlfwTypedRuntimeCommitButton(
    GlfwTypedAbsoluteRoute& route, GlfwSourcePlaneAggregate& aggregate,
    const GlfwButtonSinkEvent& event,
    const GlfwTypedRuntimeTarget& target,
    const GlfwTypedRuntimePublication& publication,
    GlfwTypedRuntimeButtonCommit& commit);

}  // namespace amcl::input

#endif

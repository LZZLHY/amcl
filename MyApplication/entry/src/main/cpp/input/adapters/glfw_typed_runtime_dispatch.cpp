#include "glfw_typed_runtime_dispatch.h"

namespace amcl::input {
namespace {

bool ExactTargetPublicationMatches(
        const GlfwTypedRuntimeTarget& target,
        const GlfwTypedRuntimePublication& publication) {
    return target.active && target.identity && publication.active &&
           target.publicationGeneration != 0u &&
           publication.generation != 0u && target.widthPx != 0u &&
           target.heightPx != 0u && publication.widthPx != 0u &&
           publication.heightPx != 0u &&
           target.publicationGeneration == publication.generation &&
           target.widthPx == publication.widthPx &&
           target.heightPx == publication.heightPx;
}

bool ButtonTargetCanReceive(const GlfwTypedRuntimeTarget& target,
                            int32_t button) {
    return target.identity && target.mouseButtons && button >= 0 &&
           static_cast<uint32_t>(button) < target.mouseButtonCount;
}

}  // namespace

GlfwTypedRuntimeCommitStatus GlfwTypedRuntimeCommitAbsolute(
        GlfwTypedAbsoluteRoute& route,
        const GlfwAbsoluteSinkEvent& event,
        const GlfwTypedRuntimeTarget& target,
        const GlfwTypedRuntimePublication& publication,
        GlfwTypedRuntimeAbsoluteCommit& commit) {
    commit = {};
    if (!ExactTargetPublicationMatches(target, publication) ||
        !target.cursorX || !target.cursorY) {
        // A pre-route mismatch must consume/clear any prior authorization just
        // like a route-level rejection; otherwise an older absolute could lend
        // authority to a later button after the publication changes.
        (void)route.AcceptAbsolute(event, 0u, 0u, 0u);
        return GlfwTypedRuntimeCommitStatus::kTargetPublicationMismatch;
    }
    if (!route.AcceptAbsolute(event, publication.generation,
                              publication.widthPx, publication.heightPx)) {
        return GlfwTypedRuntimeCommitStatus::kRouteRejected;
    }

    *target.cursorX = event.x;
    *target.cursorY = event.y;
    commit = {target.identity, event.x, event.y, true};
    return GlfwTypedRuntimeCommitStatus::kCommitted;
}

GlfwTypedRuntimeCommitStatus GlfwTypedRuntimeCommitButton(
        GlfwTypedAbsoluteRoute& route,
        GlfwSourcePlaneAggregate& aggregate,
        const GlfwButtonSinkEvent& event,
        const GlfwTypedRuntimeTarget& target,
        const GlfwTypedRuntimePublication& publication,
        GlfwTypedRuntimeButtonCommit& commit) {
    commit = {};
    if (event.requiresAbsoluteAuthorization &&
        (!ExactTargetPublicationMatches(target, publication) ||
         !ButtonTargetCanReceive(target, event.button))) {
        (void)route.AcceptButton(event, 0u, 0u, 0u);
        return GlfwTypedRuntimeCommitStatus::kTargetPublicationMismatch;
    }
    if (!event.requiresAbsoluteAuthorization &&
        event.action != GlfwInputAction::kRelease &&
        !ButtonTargetCanReceive(target, event.button)) {
        // AcceptButton's unflagged path is the canonical authorization cancel;
        // do it even though there is no safe target on which to commit a press.
        (void)route.AcceptButton(event, 0u, 0u, 0u);
        return GlfwTypedRuntimeCommitStatus::kTargetUnavailable;
    }

    const uint64_t generation = event.requiresAbsoluteAuthorization
        ? publication.generation : 0u;
    const uint32_t widthPx = event.requiresAbsoluteAuthorization
        ? publication.widthPx : 0u;
    const uint32_t heightPx = event.requiresAbsoluteAuthorization
        ? publication.heightPx : 0u;
    if (!route.AcceptButton(event, generation, widthPx, heightPx)) {
        return GlfwTypedRuntimeCommitStatus::kRouteRejected;
    }

    GlfwAggregateButtonEvent emission{};
    const bool notify = aggregate.CommitButton(
        GlfwSourcePlane::kTyped, event.button,
        static_cast<GlfwAggregateAction>(event.action),
        static_cast<int32_t>(event.modifiers), &emission);
    if (notify && target.mouseButtons && emission.button >= 0 &&
        static_cast<uint32_t>(emission.button) < target.mouseButtonCount) {
        target.mouseButtons[emission.button] =
            emission.action == GlfwAggregateAction::kRelease ? 0 : 1;
    }
    commit = {target.identity, emission, notify && target.identity != nullptr};
    return GlfwTypedRuntimeCommitStatus::kCommitted;
}

}  // namespace amcl::input

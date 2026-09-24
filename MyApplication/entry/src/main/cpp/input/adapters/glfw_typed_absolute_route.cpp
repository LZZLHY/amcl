#include "glfw_typed_absolute_route.h"

#include <limits>

namespace amcl::input {

void GlfwTypedAbsoluteRoute::Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    surface_ = {};
    authorization_ = {};
}

void GlfwTypedAbsoluteRoute::CancelAuthorization() {
    std::lock_guard<std::mutex> lock(mutex_);
    authorization_ = {};
}

void GlfwTypedAbsoluteRoute::ConsumeSurface(
        const GlfwSurfaceSinkEvent& event) {
    std::lock_guard<std::mutex> lock(mutex_);
    authorization_ = {};
    const uint32_t required = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
                              AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    if (event.surfaceEpoch == 0u || event.surface.active == 0u ||
        (event.surface.validFields & required) != required ||
        event.surface.widthPx == 0u || event.surface.heightPx == 0u ||
        event.surface.publicationGeneration == 0u) {
        surface_ = {};
        return;
    }
    surface_ = {event.surfaceEpoch, event.surface.publicationGeneration,
                event.surface.widthPx, event.surface.heightPx, true};
}

bool GlfwTypedAbsoluteRoute::CurrentPublicationMatchesLocked(
        uint64_t generation, uint32_t widthPx, uint32_t heightPx) const {
    return surface_.active && generation != 0u &&
           generation == surface_.publicationGeneration &&
           widthPx == surface_.widthPx && heightPx == surface_.heightPx;
}

void GlfwTypedAbsoluteRoute::DropLocked() {
    authorization_ = {};
    if (drops_ != std::numeric_limits<uint64_t>::max()) ++drops_;
}

bool GlfwTypedAbsoluteRoute::AcceptAbsolute(
        const GlfwAbsoluteSinkEvent& event,
        uint64_t currentPublicationGeneration,
        uint32_t currentWidthPx, uint32_t currentHeightPx) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (event.sequence == 0u || event.surfaceEpoch == 0u ||
        event.surfaceEpoch != surface_.surfaceEpoch ||
        event.publicationGeneration != surface_.publicationGeneration ||
        !CurrentPublicationMatchesLocked(currentPublicationGeneration,
                                         currentWidthPx, currentHeightPx)) {
        DropLocked();
        return false;
    }
    authorization_ = {event.sequence, event.deviceId, event.deviceClass,
                      event.surfaceEpoch, event.publicationGeneration, true};
    return true;
}

bool GlfwTypedAbsoluteRoute::AcceptButton(
        const GlfwButtonSinkEvent& event,
        uint64_t currentPublicationGeneration,
        uint32_t currentWidthPx, uint32_t currentHeightPx) {
    // ⚠️ The `consecutive` clause and the deviceId/surfaceEpoch comparison below
    // also exist in `GlfwInputAdapter`'s ProcessEventLocked. They are
    // **deliberately independent and must not be merged**: that one validates
    // the ABSOLUTE→BUTTON pair against what core published, this one adds the two
    // checks core cannot make -- that the authorization was granted under the
    // same NativeWindow publication generation, and that the generation plus
    // width/height still match the live surface. Merging would make one layer's
    // guarantee depend on the other's (spec §八.8). This is a narrowing check,
    // not a mirror, so §4.0's "eliminate mirrors" does not apply.
    std::lock_guard<std::mutex> lock(mutex_);
    if (!event.requiresAbsoluteAuthorization) {
        authorization_ = {};
        return true;
    }
    const AbsoluteAuthorization authorization = authorization_;
    authorization_ = {};
    const bool consecutive = authorization.valid &&
        authorization.sequence != std::numeric_limits<uint64_t>::max() &&
        event.sequence == authorization.sequence + 1u;
    if (!consecutive || event.deviceId != authorization.deviceId ||
        event.deviceClass != authorization.deviceClass ||
        event.surfaceEpoch != authorization.surfaceEpoch ||
        authorization.publicationGeneration !=
            surface_.publicationGeneration ||
        !CurrentPublicationMatchesLocked(currentPublicationGeneration,
                                         currentWidthPx, currentHeightPx)) {
        if (drops_ != std::numeric_limits<uint64_t>::max()) ++drops_;
        return false;
    }
    return true;
}

uint64_t GlfwTypedAbsoluteRoute::DropCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return drops_;
}

}  // namespace amcl::input

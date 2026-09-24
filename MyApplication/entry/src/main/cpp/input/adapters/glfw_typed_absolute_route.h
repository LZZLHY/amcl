#ifndef AMCL_GLFW_TYPED_ABSOLUTE_ROUTE_H
#define AMCL_GLFW_TYPED_ABSOLUTE_ROUTE_H

#include "glfw_input_adapter.h"

#include <cstdint>
#include <mutex>

namespace amcl::input {

// GLFW receives core surface publications on its polling thread, while the
// XComponent owner may already have published a newer NativeWindow generation.
// This gate joins both identities immediately before the public cursor/button
// callbacks.  It never transforms coordinates and never guesses a replacement
// generation.
class GlfwTypedAbsoluteRoute final {
public:
    void Reset();
    // Preserve the consumed surface binding while breaking absolute->button
    // adjacency when any other dispatched event intervenes.
    void CancelAuthorization();
    void ConsumeSurface(const GlfwSurfaceSinkEvent& event);

    // `current*` is the latest atomically published NativeWindow snapshot, not
    // an environment-derived size guess.  Success authorizes at most the next
    // consecutive physical button edge from the same device/surface epoch.
    bool AcceptAbsolute(const GlfwAbsoluteSinkEvent& event,
                        uint64_t currentPublicationGeneration,
                        uint32_t currentWidthPx, uint32_t currentHeightPx);
    bool AcceptButton(const GlfwButtonSinkEvent& event,
                      uint64_t currentPublicationGeneration,
                      uint32_t currentWidthPx, uint32_t currentHeightPx);

    uint64_t DropCount() const;

private:
    struct SurfaceBinding {
        uint64_t surfaceEpoch = 0u;
        uint64_t publicationGeneration = 0u;
        uint32_t widthPx = 0u;
        uint32_t heightPx = 0u;
        bool active = false;
    };

    struct AbsoluteAuthorization {
        uint64_t sequence = 0u;
        uint64_t deviceId = 0u;
        uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
        uint64_t surfaceEpoch = 0u;
        uint64_t publicationGeneration = 0u;
        bool valid = false;
    };

    bool CurrentPublicationMatchesLocked(
        uint64_t generation, uint32_t widthPx, uint32_t heightPx) const;
    void DropLocked();

    mutable std::mutex mutex_;
    SurfaceBinding surface_{};
    AbsoluteAuthorization authorization_{};
    uint64_t drops_ = 0u;
};

}  // namespace amcl::input

#endif

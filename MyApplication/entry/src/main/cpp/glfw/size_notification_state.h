#pragma once
#include <cstdint>

namespace amcl::glfw {
struct SizeNotificationBatch {
    uint64_t sequence;
    int width, height;
    bool window, framebuffer;
};

// Render/event-owner thread only. POD storage also permits GLFWwindow zero initialization.
struct SizeNotificationState {
    uint64_t lifetime;
    uint64_t observed, windowDispatched, framebufferDispatched, coalesced, cancelled;
    int width, height;
    bool dispatching, closed;

    void Prime(uint64_t id, int w, int h) {
        *this = {};
        lifetime = id;
        width = w;
        height = h;
    }
    void Observe(int w, int h) {
        if (closed || w < 0 || h < 0 || (width == w && height == h)) return;
        if (observed > windowDispatched || observed > framebufferDispatched) ++coalesced;
        width = w;
        height = h;
        ++observed;
    }
    SizeNotificationBatch Begin(bool hasWindowCallback, bool hasFramebufferCallback) {
        if (closed || dispatching) return {};
        const bool w = hasWindowCallback && observed > windowDispatched;
        const bool f = hasFramebufferCallback && observed > framebufferDispatched;
        if (!w && !f) return {};
        dispatching = true;
        return {observed, width, height, w, f};
    }
    void Cancel() {
        if (!closed && (observed > windowDispatched || observed > framebufferDispatched)) ++cancelled;
        closed = true;
    }
};

// Snapshot one coherent pair. Callbacks may replace/destroy the window or publish a
// newer size: validate lifetime before every subsequent access, acknowledge only
// the captured sequence, and leave reentrant observations for the next event pump.
template<class Window, class IsCurrent>
bool DispatchSizeNotifications(Window* window, IsCurrent isCurrent) {
    const uint64_t lifetime = window->sizeNotifications.lifetime;
    if (window->sizeNotifications.closed || window->sizeNotifications.dispatching) return false;
    const auto batch = window->sizeNotifications.Begin(window->windowSizeCb != nullptr,
                                                       window->framebufferSizeCb != nullptr);
    if (!batch.window && !batch.framebuffer) return true;
    if (batch.framebuffer) {
        window->framebufferSizeCb(window, batch.width, batch.height);
        if (!isCurrent(window, lifetime)) return false;
        window->sizeNotifications.framebufferDispatched = batch.sequence;
    }
    if (batch.window && window->windowSizeCb) {
        window->windowSizeCb(window, batch.width, batch.height);
        if (!isCurrent(window, lifetime)) return false;
        window->sizeNotifications.windowDispatched = batch.sequence;
    }
    window->sizeNotifications.dispatching = false;
    return true;
}
}

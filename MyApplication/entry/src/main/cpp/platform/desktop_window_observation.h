#pragma once
#include "desktop_host_api.h"
#include <cmath>

namespace amcl::desktop {
enum WindowChange : unsigned {
    WindowMoved = 1, WindowIconified = 2, WindowMaximized = 4,
    WindowScaleChanged = 8, WindowRefresh = 16
};
// POD: GLFWwindow is zero-initialized and the event thread owns this observation.
struct WindowObservation {
    bool initialized;
    uint64_t generation, transitions;
    int32_t windowId, x, y, width, height, status;
    float scale;
};
inline float WindowScale(const AmclDesktopSnapshot& facts) {
    for (int i = 0; i < facts.displayCount && i < AMCL_DESKTOP_MAX_DISPLAYS; ++i) {
        const auto& display = facts.displays[i];
        if (display.id == facts.displayId && std::isfinite(display.scale) && display.scale > 0)
            return display.scale;
    }
    return 0;
}
inline unsigned ObserveWindow(WindowObservation& old, const AmclDesktopSnapshot& facts) {
    if (!facts.active || facts.width <= 0 || facts.height <= 0 ||
        (old.initialized && facts.generation < old.generation)) return 0;
    const float scale = WindowScale(facts);
    unsigned changes = 0;
    if (old.initialized) {
        if (old.x != facts.x || old.y != facts.y) changes |= WindowMoved;
        if ((old.status == 3) != (facts.status == 3)) changes |= WindowIconified;
        if ((old.status == 2) != (facts.status == 2)) changes |= WindowMaximized;
        if (scale > 0 && scale != old.scale) changes |= WindowScaleChanged;
        if ((old.status == 3 && facts.status != 3) || old.windowId != facts.windowId ||
            old.width != facts.width || old.height != facts.height)
            changes |= WindowRefresh;
    }
    const uint64_t transitions = old.transitions + (changes != 0 ? 1 : 0);
    old = {true, facts.generation, transitions, facts.windowId, facts.x, facts.y,
        facts.width, facts.height, facts.status, scale > 0 ? scale : old.scale};
    return changes;
}
}

#ifndef AMCL_GLFW_BACKEND_LIFECYCLE_H
#define AMCL_GLFW_BACKEND_LIFECYCLE_H

#include <cstdint>

namespace amcl::input {

// POD by design: GLFWwindow is currently zero-initialized as raw storage.  Do
// not add constructors or non-trivial members without first removing that
// allocation contract from glfwCreateWindow.
struct GlfwBackendCaptureState {
    bool requested;
    bool active;
    bool rawMouseMotion;
};

inline void GlfwApplyCaptureState(GlfwBackendCaptureState* state,
                                  bool requested, bool active) {
    if (!state) return;
    state->requested = requested;
    // A malformed active-without-request tuple is rejected by core and adapter,
    // but keep this final runtime seam fail-closed as well.
    state->active = requested && active;
}

// ⚠️ 第二个参数**必须是后端中立的 grab 权威**，不是任何单一后端的模式量。
// 它 2026-09-05 之前叫 `cursorDisabled` 并由调用点传 `g_cursorMode == GLFW_CURSOR_DISABLED`
// —— 那个量只有 `glfwSetInputMode` 写，于是 LWJGL2（grab 走 `inputBridge_setGrabState`）
// 世代的物理鼠标视角结构上永远拿不到准入。真机证据与更正见
// docs/reports/2026-09-05_WHEEL_OVERSHOOT_AND_LWJGL2_TYPED_CHANNEL_REGRESSION.md §8.3/§8.4。
// ⇒ 现在产品调用点传 `inputBridge_isGrabbing()`（三条链共同的 grab 权威）。
inline bool GlfwShouldDispatchRelative(
        const GlfwBackendCaptureState& state, bool grabActive,
        bool hardwareRaw) {
    return grabActive && state.requested && state.active &&
        (!state.rawMouseMotion || hardwareRaw);
}

// Returns whether a user focus callback should be emitted.  Baseline state must
// initialize polling without manufacturing a change callback.
inline bool GlfwApplyFocusState(int32_t* current, bool focused,
                                bool baseline) {
    if (!current) return false;
    const int32_t next = focused ? 1 : 0;
    const bool changed = *current != next;
    *current = next;
    return changed && !baseline;
}

// Disabling is always legal.  Enabling is accepted only when the immutable host
// table advertises the API 26 raw contract.
inline bool GlfwSetRawMouseMotion(GlfwBackendCaptureState* state,
                                  bool enabled, bool supported) {
    if (!state || (enabled && !supported)) return false;
    state->rawMouseMotion = enabled;
    return true;
}

}  // namespace amcl::input

#endif  // AMCL_GLFW_BACKEND_LIFECYCLE_H

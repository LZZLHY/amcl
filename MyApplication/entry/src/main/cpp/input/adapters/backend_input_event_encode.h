#ifndef AMCL_BACKEND_INPUT_EVENT_ENCODE_H
#define AMCL_BACKEND_INPUT_EVENT_ENCODE_H

#include "backend_input_bridge.h"
#include "glfw_input_adapter.h"

#include <cmath>
#include <limits>

namespace amcl::input {

inline AmclBackendInputEvent BackendInputBlankEvent(uint32_t type) {
    AmclBackendInputEvent out{};
    out.abiVersion = static_cast<uint16_t>(AMCL_BACKEND_INPUT_ABI_VERSION);
    out.structSize = static_cast<uint16_t>(sizeof(out));
    out.eventType = type;
    return out;
}

inline AmclBackendInputEvent EncodeBackendFocus(
        const GlfwFocusSinkEvent& event) {
    AmclBackendInputEvent out =
        BackendInputBlankEvent(AMCL_BACKEND_INPUT_EVENT_FOCUS);
    out.action = event.focused ? 1u : 0u;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    return out;
}

inline AmclBackendInputEvent EncodeBackendCapture(
        const GlfwCaptureSinkEvent& event) {
    AmclBackendInputEvent out =
        BackendInputBlankEvent(AMCL_BACKEND_INPUT_EVENT_CAPTURE);
    out.code = event.requested ? 1 : 0;
    out.action = event.active ? 1u : 0u;
    out.resetReason = event.reason;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    return out;
}

inline bool EncodeBackendRelative(const GlfwRelativeSinkEvent& event,
                                  AmclBackendInputEvent* outEvent) {
    if (!outEvent) return false;
    constexpr double kFloatMax =
        static_cast<double>(std::numeric_limits<float>::max());
    if (!std::isfinite(event.dx) || !std::isfinite(event.dy) ||
        event.dx < -kFloatMax || event.dx > kFloatMax ||
        event.dy < -kFloatMax || event.dy > kFloatMax) {
        return false;
    }
    AmclBackendInputEvent out =
        BackendInputBlankEvent(AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    out.wheelX = static_cast<float>(event.dx);
    out.wheelY = static_cast<float>(event.dy);
    out.modifiers = event.hardwareRaw
        ? AMCL_BACKEND_INPUT_RELATIVE_FLAG_HARDWARE_RAW : 0u;
    out.resetReason = event.deviceClass;
    out.deviceId = event.deviceId;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    *outEvent = out;
    return true;
}

inline AmclBackendInputEvent EncodeBackendDevice(
        const GlfwDeviceSinkEvent& event) {
    AmclBackendInputEvent out =
        BackendInputBlankEvent(AMCL_BACKEND_INPUT_EVENT_DEVICE);
    out.code = event.change == AMCL_INPUT_DEVICE_ADDED
        ? AMCL_BACKEND_INPUT_DEVICE_ADDED
        : AMCL_BACKEND_INPUT_DEVICE_REMOVED;
    out.modifiers = event.capabilities;
    out.resetReason = event.deviceClass;
    out.deviceId = event.deviceId;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    return out;
}

inline AmclBackendInputEvent EncodeBackendSurfaceContext(
        const GlfwSurfaceContextSinkEvent& event) {
    const auto& value = event.surfaceContext;
    AmclBackendInputEvent out = BackendInputBlankEvent(
        AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT);
    out.code = value.windowId;
    out.rawCode = value.displayId;
    out.action = static_cast<uint32_t>(value.leftPx);
    out.modifiers = static_cast<uint32_t>(value.topPx);
    out.lockState = value.widthPx;
    out.resetReason = value.heightPx;
    out.wheelX = value.density;
    out.wheelY = value.refreshRateHz;
    out.deviceId = value.generation;
    out.monotonicTimeNs =
        (static_cast<uint64_t>(value.transform) << 32u) |
        static_cast<uint64_t>(value.validFields);
    out.sequence = event.sequence;
    return out;
}

}  // namespace amcl::input

#endif  // AMCL_BACKEND_INPUT_EVENT_ENCODE_H

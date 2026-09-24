#include "../../input/adapters/backend_input_event_encode.h"

#include <cstdlib>
#include <cstddef>
#include <iostream>
#include <limits>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "BACKEND INPUT ENCODE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

}  // namespace

int main() {
    const amcl::input::GlfwFocusSinkEvent focus{
        false, 4u, 9u, 101u, true};
    const AmclBackendInputEvent focusOut =
        amcl::input::EncodeBackendFocus(focus);
    CHECK(focusOut.eventType == AMCL_BACKEND_INPUT_EVENT_FOCUS);
    CHECK(focusOut.action == 0u);
    CHECK(focusOut.sequence == 9u);
    CHECK(focusOut.monotonicTimeNs == 101u);

    const amcl::input::GlfwCaptureSinkEvent pending{
        true, false, AMCL_INPUT_CAPTURE_REASON_NONE, 10u, 102u, false};
    const AmclBackendInputEvent pendingOut =
        amcl::input::EncodeBackendCapture(pending);
    CHECK(pendingOut.eventType == AMCL_BACKEND_INPUT_EVENT_CAPTURE);
    CHECK(pendingOut.code == 1);
    CHECK(pendingOut.action == 0u);
    CHECK(pendingOut.resetReason == AMCL_INPUT_CAPTURE_REASON_NONE);

    const amcl::input::GlfwCaptureSinkEvent lost{
        true, false, AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST, 11u, 103u, false};
    const AmclBackendInputEvent lostOut =
        amcl::input::EncodeBackendCapture(lost);
    CHECK(lostOut.code == 1);
    CHECK(lostOut.action == 0u);
    CHECK(lostOut.resetReason == AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);

    const amcl::input::GlfwRelativeSinkEvent relative{
        1.25, -2.5, 88u, 12u, 104u, true,
        AMCL_INPUT_DEVICE_CLASS_TOUCHPAD};
    AmclBackendInputEvent relativeOut{};
    CHECK(amcl::input::EncodeBackendRelative(relative, &relativeOut));
    CHECK(relativeOut.eventType == AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    CHECK(relativeOut.wheelX == 1.25f && relativeOut.wheelY == -2.5f);
    CHECK(relativeOut.modifiers ==
          AMCL_BACKEND_INPUT_RELATIVE_FLAG_HARDWARE_RAW);
    CHECK(relativeOut.deviceId == 88u);
    CHECK(relativeOut.resetReason ==
          AMCL_BACKEND_INPUT_DEVICE_CLASS_TOUCHPAD);
    CHECK(relativeOut.sequence == 12u);
    CHECK(relativeOut.monotonicTimeNs == 104u);

    amcl::input::GlfwRelativeSinkEvent tooLarge = relative;
    volatile double huge = std::numeric_limits<double>::max();
    tooLarge.dx = huge;
    CHECK(!amcl::input::EncodeBackendRelative(tooLarge, &relativeOut));
    CHECK(!amcl::input::EncodeBackendRelative(relative, nullptr));

    const amcl::input::GlfwDeviceSinkEvent removed{
        88u, AMCL_INPUT_DEVICE_CLASS_TOUCHPAD, AMCL_INPUT_DEVICE_REMOVED,
        AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS |
            AMCL_INPUT_DEVICE_CAP_WHEEL,
        13u, 105u};
    const AmclBackendInputEvent deviceOut =
        amcl::input::EncodeBackendDevice(removed);
    CHECK(deviceOut.eventType == AMCL_BACKEND_INPUT_EVENT_DEVICE);
    CHECK(deviceOut.code == AMCL_BACKEND_INPUT_DEVICE_REMOVED);
    CHECK(deviceOut.modifiers ==
          (AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS |
           AMCL_INPUT_DEVICE_CAP_WHEEL));
    CHECK(deviceOut.resetReason ==
          AMCL_BACKEND_INPUT_DEVICE_CLASS_TOUCHPAD);
    CHECK(deviceOut.deviceId == 88u);
    CHECK(deviceOut.sequence == 13u);
    CHECK(deviceOut.monotonicTimeNs == 105u);

    amcl::input::GlfwSurfaceContextSinkEvent surfaceContext{};
    surfaceContext.surfaceContext.windowId = 12;
    surfaceContext.surfaceContext.displayId = 3;
    surfaceContext.surfaceContext.leftPx = -120;
    surfaceContext.surfaceContext.topPx = 44;
    surfaceContext.surfaceContext.widthPx = 1600u;
    surfaceContext.surfaceContext.heightPx = 900u;
    surfaceContext.surfaceContext.density = 2.25f;
    surfaceContext.surfaceContext.refreshRateHz = 144.0f;
    surfaceContext.surfaceContext.transform = 2u;
    surfaceContext.surfaceContext.validFields =
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    surfaceContext.surfaceContext.generation = 41u;
    surfaceContext.surfaceEpoch = 7u;
    surfaceContext.sequence = 14u;
    const AmclBackendInputEvent contextOut =
        amcl::input::EncodeBackendSurfaceContext(surfaceContext);
    CHECK(contextOut.eventType ==
          AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT);
    CHECK(contextOut.code == 12 && contextOut.rawCode == 3);
    CHECK(static_cast<int32_t>(contextOut.action) == -120);
    CHECK(static_cast<int32_t>(contextOut.modifiers) == 44);
    CHECK(contextOut.lockState == 1600u && contextOut.resetReason == 900u);
    CHECK(contextOut.wheelX == 2.25f && contextOut.wheelY == 144.0f);
    CHECK(contextOut.deviceId == 41u && contextOut.sequence == 14u);
    CHECK(static_cast<uint32_t>(contextOut.monotonicTimeNs) ==
          AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL);
    CHECK(static_cast<uint32_t>(contextOut.monotonicTimeNs >> 32u) == 2u);

    CHECK(sizeof(AmclBackendInputEvent) == 64u);
    CHECK(offsetof(AmclBackendInputEvent, resetReason) == 28u);
    std::cout << "backend_input_event_encode_test: PASS\n";
    return 0;
}

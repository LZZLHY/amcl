#include "../../input/adapters/glfw_backend_lifecycle.h"
#include "../../input/adapters/glfw_input_mode.h"

#include <cstdlib>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW BACKEND LIFECYCLE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

}  // namespace

int main() {
    amcl::input::GlfwBackendCaptureState capture{};
    amcl::input::GlfwApplyCaptureState(&capture, true, false);
    CHECK(capture.requested);
    CHECK(!capture.active);
    CHECK(!amcl::input::GlfwShouldDispatchRelative(capture, true, false));

    amcl::input::GlfwApplyCaptureState(&capture, true, true);
    CHECK(amcl::input::GlfwShouldDispatchRelative(capture, true, false));
    CHECK(!amcl::input::GlfwShouldDispatchRelative(capture, false, false));
    amcl::input::GlfwApplyCaptureState(&capture, true, false);
    CHECK(!amcl::input::GlfwShouldDispatchRelative(capture, true, false));

    int32_t focused = 1;
    CHECK(!amcl::input::GlfwApplyFocusState(&focused, false, true));
    CHECK(focused == 0);
    CHECK(amcl::input::GlfwApplyFocusState(&focused, true, false));
    CHECK(focused == 1);
    CHECK(!amcl::input::GlfwApplyFocusState(&focused, true, false));

    CHECK(!amcl::input::GlfwSetRawMouseMotion(&capture, true, false));
    CHECK(!capture.rawMouseMotion);
    CHECK(amcl::input::GlfwSetRawMouseMotion(&capture, true, true));
    CHECK(capture.rawMouseMotion);
    amcl::input::GlfwApplyCaptureState(&capture, true, true);
    CHECK(!amcl::input::GlfwShouldDispatchRelative(capture, true, false));
    CHECK(amcl::input::GlfwShouldDispatchRelative(capture, true, true));
    CHECK(amcl::input::GlfwSetRawMouseMotion(&capture, false, false));
    CHECK(!capture.rawMouseMotion);

    AmclInputHostApiV1 api{};
    api.capabilityBits = AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION;
    CHECK(!amcl::input::GlfwApi26RawMouseMotionSupported(&api));
    api.capabilityBits |= AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE;
    CHECK(!amcl::input::GlfwApi26RawMouseMotionSupported(&api));
    api.capabilityBits |= AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE;
    CHECK(amcl::input::GlfwApi26RawMouseMotionSupported(&api));

    std::cout << "glfw_backend_lifecycle_test: PASS\n";
    return 0;
}

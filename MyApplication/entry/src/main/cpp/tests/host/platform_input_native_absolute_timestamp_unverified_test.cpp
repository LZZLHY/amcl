#include "adapters/glfw_input_mode.h"
#include "amcl_input_api.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "NATIVE ABSOLUTE TIMESTAMP EVIDENCE FAIL line " << line
              << ": " << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

void SelectTypedBeforeHostConstruction() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
#endif
}

}  // namespace

int main() {
    static_assert(AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED != 0,
                  "this target must assert coordinate provenance");
    static_assert(AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED == 0,
                  "this target must omit timestamp provenance");
    static_assert(!amcl::input::kGlfwNativeAbsoluteVerifiedByBuild,
                  "coordinate-only evidence must not authorize bit14");

    SelectTypedBeforeHostConstruction();
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u);
    CHECK((api->capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) == 0u);
    CHECK(!amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped());
    CHECK(amcl::input::PlatformInputNativeSurfaceMouseTransaction(
              1u, 1.0, 1.0, 0u, 0u, 0u, true) ==
          amcl::input::PlatformInputNativeMouseResult::RouteInactive);

    std::cout << "native absolute timestamp evidence gate passed\n";
    return 0;
}

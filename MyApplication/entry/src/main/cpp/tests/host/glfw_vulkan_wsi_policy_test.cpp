#include "../../glfw/glfw_vulkan_wsi.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {
void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << "\n";
        std::exit(1);
    }
}
}

int main() {
    using amcl::glfw::vulkan::LeaseGenerationCurrent;
    using amcl::glfw::vulkan::LoaderProbe;
    using amcl::glfw::vulkan::MinimalLoaderReady;
    using amcl::glfw::vulkan::RequiredInstanceExtensionsReady;

    require(!MinimalLoaderReady({false, false, false, false}),
            "loader absent must fail closed");
    require(!MinimalLoaderReady({true, false, true, true}),
            "missing vkGetInstanceProcAddr must fail closed");
    require(!RequiredInstanceExtensionsReady({true, true, false, true}),
            "missing VK_KHR_surface must fail closed");
    require(!RequiredInstanceExtensionsReady({true, true, true, false}),
            "missing VK_OHOS_surface must fail closed");
    require(RequiredInstanceExtensionsReady({true, true, true, true}),
            "loader and both WSI extensions should pass");

    void* window = reinterpret_cast<void*>(0x1);
    void* broker = reinterpret_cast<void*>(0x2);
    require(LeaseGenerationCurrent(window, broker, 7, 7),
            "current generation with owned lease should pass");
    require(!LeaseGenerationCurrent(window, broker, 7, 8),
            "stale generation must fail closed");
    require(!LeaseGenerationCurrent(nullptr, broker, 7, 7),
            "missing NativeWindow must fail closed");
    require(!LeaseGenerationCurrent(window, nullptr, 7, 7),
            "missing lease owner must fail closed");
    require(!LeaseGenerationCurrent(window, broker, 0, 0),
            "zero generation must fail closed");

    std::cout << "glfw Vulkan WSI policy PASS\n";
    return 0;
}

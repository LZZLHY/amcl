#include "../../platform/vulkan_wsi.h"
#include <windows.h>
#include <cstdlib>
#include <iostream>

void require(bool condition, const char* why) {
    if (!condition) { std::cerr << why << '\n'; std::exit(1); }
}
template <typename T> T proc(HMODULE module, const char* name) {
    auto fn = reinterpret_cast<T>(GetProcAddress(module, name));
    require(fn != nullptr, name); return fn;
}
int main(int argc, char** argv) {
    require(argc == 3, "two DLL paths required");
    HMODULE a = LoadLibraryA(argv[1]), b = LoadLibraryA(argv[2]);
    require(a && b && a != b, "two physical runtime copies loaded");
    auto activate = proc<decltype(&amclVulkanSetAdmission)>(a, "amclVulkanSetAdmission");
    auto aAdmitted = proc<decltype(&amclVulkanAdmissionGranted)>(a, "amclVulkanAdmissionGranted");
    auto bAdmitted = proc<decltype(&amclVulkanAdmissionGranted)>(b, "amclVulkanAdmissionGranted");
    auto get = proc<decltype(&amclVulkanGetInstanceProcAddr)>(b, "amclVulkanGetInstanceProcAddr");
    auto setLoader = proc<decltype(&amclVulkanSetLoader)>(a, "amclVulkanSetLoader");
    require(!aAdmitted() && !bAdmitted(), "cold copies are not admitted");
    require(activate(1, "minecraft-vulkan", "minecraft-26.2-conservative-v1"), "owner grants candidate");
    require(aAdmitted() && bAdmitted(), "second runtime delegates admission to owner");
    require(get(nullptr, "vkGetInstanceProcAddr") == reinterpret_cast<void*>(GetProcAddress(a, "vkGetInstanceProcAddr")),
        "instance function lookup returns owner dispatch");
    require(setLoader(reinterpret_cast<void*>(GetProcAddress(b, "vkGetInstanceProcAddr"))),
        "injecting alias loader must not recursively retain a proxy");
    require(get(nullptr, "vkGetInstanceProcAddr") != nullptr, "alias lookup remains nonrecursive");
    require(activate(0, "", "") && !bAdmitted(), "revocation visible across copies");
    std::cout << "Vulkan cross-DSO authority and loader-alias test passed\n";
    // Runtime pointers have process lifetime by contract, like the linked HAP.
}

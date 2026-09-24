#include <cstdio>
#include <cstdlib>
#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, #condition); std::abort(); } } while (0)
#include <iostream>
#include "../../../../../../prebuilt/mobilegl/src/MobileGL/MG_Backend/DirectVulkan/Renderer/SwapchainGeometry.h"

using namespace MobileGL::MG_Backend::DirectVulkan;
int main() {
    VkSurfaceCapabilitiesKHR caps{};
    caps.currentExtent = {2688, 1216};
    caps.currentTransform = VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    caps.supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR | VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    caps.minImageExtent = {1, 1};
    caps.maxImageExtent = {4096, 4096};
    auto natural = caps;
    natural.currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    const auto naturalOhos = ChooseSwapchainGeometry(natural, {2688, 1216}, true);
    const auto naturalLegacy = ChooseSwapchainGeometry(natural, {2688, 1216}, false);
    CHECK(naturalOhos.imageExtent.width == naturalLegacy.imageExtent.width &&
           naturalOhos.imageExtent.height == naturalLegacy.imageExtent.height &&
           naturalOhos.preTransform == naturalLegacy.preTransform);
    const auto stable = ChooseSwapchainGeometry(caps, {2688, 1216}, true);
    CHECK(stable.preTransform == VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR);
    CHECK(stable.imageExtent.width == 2688 && stable.imageExtent.height == 1216);
    // Model the measured OHOS feedback: currentExtent follows allocated image extent.
    caps.currentExtent = stable.imageExtent;
    for (int frame = 0; frame < 100; ++frame) {
        CHECK(!SwapchainSurfaceChanged(caps, stable.surfaceExtent, VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR));
        const auto next = ChooseSwapchainGeometry(caps, {2688, 1216}, true);
        CHECK(next.imageExtent.width == stable.imageExtent.width && next.imageExtent.height == stable.imageExtent.height);
        caps.currentExtent = next.imageExtent;
    }
    caps.currentTransform = VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    CHECK(SwapchainSurfaceChanged(caps, stable.surfaceExtent, VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR));
    const auto legacy = ChooseSwapchainGeometry(caps, {2688, 1216}, false);
    CHECK(legacy.preTransform == VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR);
    CHECK(legacy.imageExtent.width == 1216 && legacy.imageExtent.height == 2688);
    caps.supportedTransforms = VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    CHECK(ChooseSwapchainGeometry(caps, {2688, 1216}, true).preTransform == caps.currentTransform);
    caps.currentExtent = {UINT32_MAX, UINT32_MAX};
    const auto clamped = ChooseSwapchainGeometry(caps, {8000, 0}, true);
    CHECK(clamped.surfaceExtent.width == 4096 && clamped.surfaceExtent.height == 1);
    std::cout << "OHOS orientation feedback, native transform tracking, legacy rotation and bounds: PASS\n";
}

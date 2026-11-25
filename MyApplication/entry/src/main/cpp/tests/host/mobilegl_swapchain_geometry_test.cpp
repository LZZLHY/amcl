#include <cstdio>
#include <cstdlib>
#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, #condition); std::abort(); } } while (0)
#include <iostream>
#include "../../../../../../prebuilt/mobilegl/src/MobileGL/MG_Backend/DirectVulkan/Renderer/SwapchainGeometry.h"

using namespace MobileGL::MG_Backend::DirectVulkan;
int main() {
    constexpr auto ohos = SurfaceExtentSource::AllocatedBuffer;
    constexpr auto window = SurfaceExtentSource::Window;
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
    CHECK(!SwapchainSurfaceChanged(caps, stable.surfaceExtent, caps.currentTransform, stable.preTransform, ohos));

    caps.supportedTransforms |= VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    const auto rotated = ChooseSwapchainGeometry(caps, {2688, 1216}, false, ohos);
    const auto selected = rotated.preTransform;
    CHECK(selected == caps.currentTransform && (selected & caps.supportedTransforms));
    CHECK(rotated.imageExtent.width == 1216 && rotated.imageExtent.height == 2688);
    caps.currentExtent = rotated.imageExtent;
    CHECK(SwapchainSurfaceChanged(caps, stable.surfaceExtent, caps.currentTransform, stable.preTransform, ohos));
    // OHOS 回报的是已经分配的物理缓冲尺寸，同一次旋转下维持游戏逻辑宽高。
    for (int frame = 0; frame < 100; ++frame) {
        CHECK(!SwapchainSurfaceChanged(caps, rotated.surfaceExtent, caps.currentTransform, selected, ohos));
        const auto next = ChooseSwapchainGeometry(caps, {2688, 1216}, false, ohos);
        CHECK(next.surfaceExtent.width == 2688 && next.surfaceExtent.height == 1216);
        CHECK(next.imageExtent.width == 1216 && next.imageExtent.height == 2688);
        caps.currentExtent = next.imageExtent;
    }
    caps.currentExtent = {1280, 720};
    CHECK(SwapchainSurfaceChanged(caps, rotated.surfaceExtent, caps.currentTransform, selected, ohos));
    CHECK(ChooseSwapchainGeometry(caps, {2688, 1216}, false).surfaceExtent.width == 1280);

    caps.currentExtent = rotated.imageExtent;
    caps.currentTransform = VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    CHECK(SwapchainSurfaceChanged(caps, rotated.surfaceExtent, VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR, selected));
    CHECK(ChooseSwapchainGeometry(caps, {2688, 1216}, false, ohos).preTransform == caps.currentTransform);
    // 非 OHOS 平台回报的相同宽高互换是真实窗口变化，不能当成设备缓冲回显。
    CHECK(SwapchainSurfaceChanged(caps, rotated.surfaceExtent, caps.currentTransform, selected, window));
    CHECK(ChooseSwapchainGeometry(caps, {2688, 1216}, false, window).surfaceExtent.width == 1216);
    caps.supportedTransforms = VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    CHECK(ChooseSwapchainGeometry(caps, {2688, 1216}, true, ohos).preTransform == caps.currentTransform);
    caps.currentExtent = {UINT32_MAX, UINT32_MAX};
    CHECK(SwapchainSurfaceChanged(caps, rotated.surfaceExtent, VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR, selected, ohos));
    CHECK(!SwapchainSurfaceChanged(caps, rotated.surfaceExtent, caps.currentTransform, selected, ohos));
    const auto clamped = ChooseSwapchainGeometry(caps, {8000, 0}, true);
    CHECK(clamped.surfaceExtent.width == 4096 && clamped.surfaceExtent.height == 1);
    std::cout << "OHOS orientation feedback, supported transforms, native resize and bounds: PASS\n";
}

#include "../../platform/vulkan_surface_policy.h"
#include <cstdlib>
#include <iostream>

// 始终执行检查；纯策略只证明准入与参数选择，不代表驱动真正呈现或手机画面正确。
static void require(bool value, const char* message) { if (!value) { std::cerr << message << '\n'; std::exit(1); } }

int main() {
    using namespace amcl::graphics;
    const auto inherit = EvaluateMinecraftSdlSurface({1, 4, 2, 8, 1, 1, true, true});
    require(inherit.ready() && inherit.requestedImages == 3 && inherit.selectedAlpha == 8, "inherit alpha negotiation");
    const auto opaque = EvaluateMinecraftSdlSurface({2, 3, 2, 1, 1, 1, true, true});
    require(opaque.ready() && opaque.selectedAlpha == 1, "opaque alpha preservation");
    const auto badUsage = EvaluateMinecraftSdlSurface({1, 3, 16, 8, 1, 1, true, true});
    require(!badUsage.ready() && !badUsage.usage, "transfer-dst usage gate");
    const auto badTransform = EvaluateMinecraftSdlSurface({1, 3, 2, 8, 1, 2, true, true});
    require(!badTransform.ready() && !badTransform.transform, "current transform gate");
    // 设备自然方向、90/180/270及镜像均使用真实IDENTITY，方向不足不能回退到current。
    for (uint32_t current = 1; current <= 0x100u; current <<= 1) {
        const auto choice = SelectMinecraftPresentationTransform(0x1ffu, current);
        require(choice.ready() && choice.preTransform == 1u, "window-oriented identity for every legal transform");
        const auto admitted = EvaluateMinecraftSdlSurface({2, 4, 2, 8, 0x1ffu, current, true, true});
        require(admitted.ready() && admitted.selectedPreTransform == choice.preTransform, "admission consumes selected transform");
        if (current != 1u) {
            const auto unsupported = SelectMinecraftPresentationTransform(current, current);
            require(!unsupported.ready(), "pre-rotation-only driver rejected");
        }
    }
    for (uint32_t invalid : {0u, 3u, 0x200u, 0xffffffffu})
        require(!SelectMinecraftPresentationTransform(0xffffffffu, invalid).ready(), "invalid transform rejected");
    require(!SelectMinecraftPresentationTransform(1u, 2u).ready(), "unsupported current transform rejected");
    std::cout << "Vulkan surface policy PASS: alpha, legal transforms, identity-only image contract, fail-closed admission\n";
}

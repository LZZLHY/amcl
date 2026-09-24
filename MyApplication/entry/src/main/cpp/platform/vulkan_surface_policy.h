#pragma once
#include <cstdint>
#include <initializer_list>

namespace amcl::graphics {
/** 原生Minecraft surface的纯策略：输入均为本次驱动查询的原始能力，输出仅用于
 * 实际swapchain请求和准入；不修改对游戏公开的VkSurfaceCapabilitiesKHR。
 * 游戏仍持有图像、尺寸及交换链寿命，策略不分配资源或推断窗口横竖屏。
 */

// 游戏请求OPAQUE、OHOS仅支持其他合成模式时选择真实支持的位，不伪造驱动能力。
inline uint32_t SelectSwapchainCompositeAlpha(uint32_t requested, uint32_t supported) {
    constexpr uint32_t opaque = 1u, premultiplied = 2u, postmultiplied = 4u, inherit = 8u;
    if (requested != 0u && (requested & (requested - 1u)) == 0u &&
        (requested & (opaque | premultiplied | postmultiplied | inherit) & supported) != 0u) return requested;
    if (requested != opaque) return 0u;
    for (const uint32_t mode : {inherit, premultiplied, postmultiplied}) {
        if ((supported & mode) != 0u) return mode;
    }
    return 0u;
}

/** 已审计26.2及26.3上屏只翻转Y轴，像素保持游戏窗口方向，没有按surface预旋转。
 * preTransform描述像素已经完成的变换，因此必须用IDENTITY，让呈现引擎处理剩余方向。
 * 显示旋转与请求尺寸是独立事实：这里不能交换宽高、改viewport或旋转输入坐标。
 * 非法/未查询的currentTransform以及不支持IDENTITY均明确拒绝，不能落回currentTransform。
 */
struct VulkanPresentationTransform {
    uint32_t preTransform = 0;
    const char* reason = "native_vulkan_surface_transform_unqueried";
    bool ready() const { return preTransform != 0u; }
};
inline VulkanPresentationTransform SelectMinecraftPresentationTransform(uint32_t supported, uint32_t current) {
    constexpr uint32_t identity = 1u;
    constexpr uint32_t knownTransforms = 0x1ffu;
    if (current == 0u || (current & (current - 1u)) != 0u || (current & knownTransforms) == 0u ||
        (supported & current) != current) {
        return {0u, "native_vulkan_surface_transform_invalid"};
    }
    if ((supported & identity) == 0u) return {0u, "native_vulkan_identity_transform_unavailable"};
    return {identity, "native_vulkan_window_oriented_identity"};
}

// 两前端共享方向规则；以下其余字段描述26.3 SDL上屏特有的格式/usage/图像数要求。
struct VulkanSurfaceFacts {
    uint32_t minImages = 0, maxImages = 0, usage = 0, alpha = 0;
    uint32_t transforms = 0, currentTransform = 0;
    bool format = false;
    bool presentModes = false;
};
struct VulkanSurfaceAdmission {
    bool imageCount, usage, alpha, transform, format, presentModes;
    uint32_t requestedImages, selectedAlpha, selectedPreTransform;
    bool ready() const { return imageCount && usage && alpha && transform && format && presentModes; }
};
inline VulkanSurfaceAdmission EvaluateMinecraftSdlSurface(const VulkanSurfaceFacts& f) {
    const uint32_t requestedImages = f.minImages > 3u ? f.minImages : 3u;
    const uint32_t selectedAlpha = SelectSwapchainCompositeAlpha(1u, f.alpha);
    const auto orientation = SelectMinecraftPresentationTransform(f.transforms, f.currentTransform);
    // RenderPearl按窗口方向blit到TRANSFER_DST图像。WSI提交IDENTITY而非游戏原先照抄的
    // currentTransform；准入消费同一选择，避免“能创建”再次被当作“方向已经正确”。
    return {f.minImages > 0u && (f.maxImages == 0u || f.maxImages >= requestedImages),
        (f.usage & 2u) != 0u, selectedAlpha != 0u, orientation.ready(),
        f.format, f.presentModes, requestedImages, selectedAlpha, orientation.preTransform};
}
}

#include "vulkan_requirement_policy.h"

namespace amcl::graphics {
namespace {

constexpr uint32_t kVulkanApi12 = (1u << 22) | (2u << 12);

// 游戏世代只在这里声明特性差异；扩展阶段与具体特性位分别保留查询状态。
bool minecraft262Features(const VulkanRequirementFacts& facts) {
    return facts.multiDrawIndirect && facts.fillModeNonSolid && facts.samplerAnisotropy &&
        facts.shaderDrawParameters && facts.timelineSemaphore && facts.hostQueryReset &&
        facts.synchronization2 && facts.dynamicRendering &&
        facts.vertexAttributeInstanceRateDivisor;
}

bool minecraft263Features(const VulkanRequirementFacts& facts) {
    // 26.3 不继承 26.2 的 fillModeNonSolid 要求，但增加 drawIndirectFirstInstance。
    // 不能把某一世代的成功或失败直接借给另一个 requirement。
    return facts.multiDrawIndirect && facts.drawIndirectFirstInstance && facts.samplerAnisotropy &&
        facts.shaderDrawParameters && facts.timelineSemaphore && facts.hostQueryReset &&
        facts.synchronization2 && facts.dynamicRendering &&
        facts.vertexAttributeInstanceRateDivisor;
}

// 26.4 Snapshot 1 已在官方客户端中移除 dynamicRendering。单列这一代的特性表，
// 不借修改 26.3 公共条件放宽旧版；divisor、sync2 等剩余特性仍须实查为真。
bool minecraft264Features(const VulkanRequirementFacts& facts) {
    return facts.multiDrawIndirect && facts.drawIndirectFirstInstance && facts.samplerAnisotropy &&
        facts.shaderDrawParameters && facts.timelineSemaphore && facts.hostQueryReset &&
        facts.synchronization2 && facts.vertexAttributeInstanceRateDivisor;
}

} // namespace

VulkanRequirementAssessment AssessMinecraftVulkanRequirement(const VulkanRequirementFacts& facts,
    const std::string& requirementId) {
    VulkanRequirementAssessment result;
    const bool mc262 = requirementId == "minecraft-26.2-conservative-v1";
    const bool mc263 = requirementId == "minecraft-26.3-pre1-vulkan-conservative-v1" ||
        requirementId == "minecraft-26.3-sdl-vulkan-conservative-v1";
    const bool mc264 = requirementId == "minecraft-26.4-snapshot1-sdl-vulkan-v1";
    if (!mc262 && !mc263 && !mc264) {
        result.deviceExtensions = result.featureBits = CapabilityEvidence::No;
        result.reasonCode = "unknown_minecraft_vulkan_requirement";
        return result;
    }
    const bool version = facts.loaderApiRaw >= kVulkanApi12 && facts.deviceApiRaw >= kVulkanApi12;
    // 只有经 26.4 Snapshot 1 身份审计的调用可省去 dynamic rendering / push descriptor。
    // 未知身份在上方拒绝；26.2 和 26.3 保持原来五项扩展要求及查询状态语义。
    const bool extensions = facts.hasSwapchain && facts.hasSynchronization2 && facts.hasVertexAttributeDivisor &&
        (mc264 || (facts.hasDynamicRendering && facts.hasPushDescriptor));
    result.deviceExtensions = !version ? CapabilityEvidence::No : !facts.deviceExtensionsQueried
        ? CapabilityEvidence::Unknown : extensions ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    const bool features = mc262 ? minecraft262Features(facts) :
        mc263 ? minecraft263Features(facts) : minecraft264Features(facts);
    result.featureBits = !facts.featuresQueried ? CapabilityEvidence::Unknown :
        features ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    result.admitted = result.deviceExtensions == CapabilityEvidence::Yes && result.featureBits == CapabilityEvidence::Yes;
    // 固定优先级保留最早的失败阶段；诊断码永远不能覆盖或反转上面的结构化结论。
    if (facts.loaderApiRaw < kVulkanApi12) result.reasonCode = "vulkan_loader_api_below_1_2";
    else if (facts.deviceApiRaw < kVulkanApi12) result.reasonCode = "vulkan_api_below_1_2";
    else if (!facts.deviceExtensionsQueried) result.reasonCode = "device_extensions_not_queried";
    else if (!extensions) result.reasonCode = "minecraft_required_device_extension_missing";
    else if (!facts.featuresQueried) result.reasonCode = "feature_bits_not_queried";
    else if (!features) result.reasonCode = mc262 ? "minecraft_26_2_required_feature_missing" :
        mc263 ? "minecraft_26_3_required_feature_missing" : "minecraft_26_4_required_feature_missing";
    return result;
}

bool EvaluateMinecraftVulkanRequirement(const VulkanRequirementFacts& facts,
    const std::string& requirementId, std::string& reason) {
    const auto result = AssessMinecraftVulkanRequirement(facts, requirementId);
    reason = result.reasonCode;
    return result.admitted;
}

} // namespace amcl::graphics

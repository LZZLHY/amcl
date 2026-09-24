#include "../../platform/vulkan_requirement_policy.h"

#include <iostream>
#include <string>

namespace {
int failures = 0;
void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "vulkan_requirement_policy_test: FAIL: " << message << '\n'; ++failures; }
}

amcl::graphics::VulkanRequirementFacts complete() {
    amcl::graphics::VulkanRequirementFacts facts;
    facts.deviceApiRaw = (1u << 22) | (3u << 12);
    facts.loaderApiRaw = facts.deviceApiRaw;
    facts.deviceExtensionsQueried = true;
    facts.hasSwapchain = facts.hasDynamicRendering = facts.hasPushDescriptor = true;
    facts.hasSynchronization2 = facts.hasVertexAttributeDivisor = true;
    facts.featuresQueried = true;
    facts.multiDrawIndirect = facts.drawIndirectFirstInstance = true;
    facts.fillModeNonSolid = facts.samplerAnisotropy = true;
    facts.shaderDrawParameters = facts.timelineSemaphore = true;
    facts.hostQueryReset = facts.synchronization2 = true;
    facts.dynamicRendering = facts.vertexAttributeInstanceRateDivisor = true;
    return facts;
}
}

int main() {
    using namespace amcl::graphics;
    std::string reason;
    VulkanRequirementFacts facts = complete();
    require(EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reason),
        "complete 26.2 facts admit");
    require(EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.3-pre1-vulkan-conservative-v1", reason),
        "complete 26.3 facts admit");

    facts = complete();
    facts.hasPushDescriptor = false;
    require(!EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reason) &&
        reason == "minecraft_required_device_extension_missing", "missing push descriptor rejects");
    facts = complete();
    facts.hasVertexAttributeDivisor = false;
    require(!EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reason) &&
        reason == "minecraft_required_device_extension_missing", "missing vertex divisor rejects");
    facts = complete();
    facts.timelineSemaphore = false;
    require(!EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reason) &&
        reason == "minecraft_26_2_required_feature_missing", "missing timeline semaphore rejects");
    facts = complete();
    facts.drawIndirectFirstInstance = false;
    require(EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reason),
        "26.2 does not inherit 26.3-only feature");
    require(!EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.3-pre1-vulkan-conservative-v1", reason) &&
        reason == "minecraft_26_3_required_feature_missing", "26.3 extra feature rejects");
    facts = complete();
    facts.fillModeNonSolid = false;
    require(EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.3-pre1-vulkan-conservative-v1", reason),
        "26.3 does not inherit 26.2 fill mode requirement");
    require(!EvaluateMinecraftVulkanRequirement(complete(), "unknown", reason) &&
        reason == "unknown_minecraft_vulkan_requirement", "unknown requirement rejects");
    // 每次只移除一个能力，验证 26.4 放宽的两项不会泄漏给旧代。同时检查结构化字段，
    // 防止 reason 虽拒绝、上层却从 YES 字段得到错误准入。
    const char* generations[] = {"minecraft-26.2-conservative-v1", "minecraft-26.3-pre1-vulkan-conservative-v1",
        "minecraft-26.3-sdl-vulkan-conservative-v1", "minecraft-26.4-snapshot1-sdl-vulkan-v1"};
    for (const char* generation : generations) {
        const bool is264 = std::string(generation) == "minecraft-26.4-snapshot1-sdl-vulkan-v1";
        for (auto field : {&VulkanRequirementFacts::hasPushDescriptor, &VulkanRequirementFacts::hasDynamicRendering,
                           &VulkanRequirementFacts::dynamicRendering}) {
            facts = complete(); facts.*field = false;
            require(AssessMinecraftVulkanRequirement(facts, generation).admitted == is264,
                "only 26.4 may omit removed requirements");
        }
        for (auto field : {&VulkanRequirementFacts::hasSwapchain, &VulkanRequirementFacts::hasSynchronization2,
                           &VulkanRequirementFacts::hasVertexAttributeDivisor}) {
            facts = complete(); facts.*field = false;
            const auto assessment = AssessMinecraftVulkanRequirement(facts, generation);
            require(!assessment.admitted && assessment.deviceExtensions == CapabilityEvidence::No,
                "remaining extensions reject in every generation");
        }
        for (auto field : {&VulkanRequirementFacts::multiDrawIndirect, &VulkanRequirementFacts::samplerAnisotropy,
                           &VulkanRequirementFacts::shaderDrawParameters, &VulkanRequirementFacts::timelineSemaphore,
                           &VulkanRequirementFacts::hostQueryReset, &VulkanRequirementFacts::synchronization2,
                           &VulkanRequirementFacts::vertexAttributeInstanceRateDivisor}) {
            facts = complete(); facts.*field = false;
            const auto assessment = AssessMinecraftVulkanRequirement(facts, generation);
            require(!assessment.admitted && assessment.featureBits == CapabilityEvidence::No,
                "remaining features reject in every generation");
        }
        facts = complete(); facts.deviceExtensionsQueried = false;
        require(AssessMinecraftVulkanRequirement(facts, generation).deviceExtensions == CapabilityEvidence::Unknown,
            "unqueried extensions stay unknown");
        facts = complete(); facts.featuresQueried = false;
        require(!AssessMinecraftVulkanRequirement(facts, generation).admitted,
            "unqueried features never admit");
        facts = complete(); facts.deviceApiRaw = (1u << 22) | (1u << 12);
        require(!AssessMinecraftVulkanRequirement(facts, generation).admitted, "Vulkan 1.1 remains too old");
    }
    // 9020 类设备缺 push descriptor，26.4 可通过；910 类还缺 divisor，仍必须拒绝。
    facts = complete(); facts.hasPushDescriptor = false;
    require(AssessMinecraftVulkanRequirement(facts, generations[3]).admitted, "9020 extension gate opened for 26.4");
    facts.hasDynamicRendering = facts.dynamicRendering = facts.hasVertexAttributeDivisor = false;
    facts.vertexAttributeInstanceRateDivisor = false;
    require(!AssessMinecraftVulkanRequirement(facts, generations[3]).admitted, "910 divisor gate remains closed");
    facts = complete(); facts.drawIndirectFirstInstance = false;
    require(!AssessMinecraftVulkanRequirement(facts, generations[3]).admitted, "26.4 still requires indirect first instance");
    if (failures == 0) std::cout << "vulkan_requirement_policy_test: OK\n";
    return failures == 0 ? 0 : 1;
}

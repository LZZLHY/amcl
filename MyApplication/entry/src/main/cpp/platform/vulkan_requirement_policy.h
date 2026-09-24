#ifndef AMCL_VULKAN_REQUIREMENT_POLICY_H
#define AMCL_VULKAN_REQUIREMENT_POLICY_H

#include <cstdint>
#include <string>
#include "graphics_capability.h"

namespace amcl::graphics {

// 同一次 loader/物理设备扫描的原始事实，不依赖 Vulkan SDK 类型。只由扫描器填值，
// 准入消费者必须使用下方统一评估，不得重新拼接一份更宽松的特性布尔表达式。
struct VulkanRequirementFacts {
    uint32_t loaderApiRaw = 0;
    uint32_t deviceApiRaw = 0;
    bool deviceExtensionsQueried = false;
    bool hasSwapchain = false;
    bool hasDynamicRendering = false;
    bool hasPushDescriptor = false;
    bool hasSynchronization2 = false;
    bool hasVertexAttributeDivisor = false;
    bool featuresQueried = false;
    bool multiDrawIndirect = false;
    bool drawIndirectFirstInstance = false;
    bool fillModeNonSolid = false;
    bool samplerAnisotropy = false;
    bool shaderDrawParameters = false;
    bool timelineSemaphore = false;
    bool hostQueryReset = false;
    bool synchronization2 = false;
    bool dynamicRendering = false;
    bool vertexAttributeInstanceRateDivisor = false;
};

// 一次要求评估的分阶段证据。admitted 与两个证据字段从相同规则派生；未知查询不会
// 变成支持。reasonCode 仅解释结论，不是另一条需要调用方自行解析的授权信道。
struct VulkanRequirementAssessment {
    CapabilityEvidence deviceExtensions = CapabilityEvidence::NotRun;
    CapabilityEvidence featureBits = CapabilityEvidence::NotRun;
    bool admitted = false;
    std::string reasonCode;
};

// requirement 是已审计的版本身份。此入口同时服务旧布尔查询与新的结构化准入，
// 窗口呈现、shader 和运行库仍由各自后续阶段验证，不由设备能力制造阳性。
VulkanRequirementAssessment AssessMinecraftVulkanRequirement(const VulkanRequirementFacts& facts,
    const std::string& requirementId);

// 旧调用者的兼容视图：只转交统一评估，不维护独立判定。
bool EvaluateMinecraftVulkanRequirement(const VulkanRequirementFacts& facts,
    const std::string& requirementId, std::string& reason);

} // namespace amcl::graphics

#endif

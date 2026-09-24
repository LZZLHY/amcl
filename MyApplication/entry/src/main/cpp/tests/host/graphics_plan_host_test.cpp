#include "../../platform/graphics_plan.h"
#include <cstdlib>
#include <iostream>
#ifdef _WIN32
#include <process.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {
int failures = 0;
void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "graphics_plan_host_test: FAIL: " << message << '\n'; ++failures; }
}
int currentPid() {
#ifdef _WIN32
    return _getpid();
#else
    return static_cast<int>(getpid());
#endif
}
std::string replace(std::string text, const char* from, const char* to) {
    const size_t position = text.find(from);
    if (position != std::string::npos) text.replace(position, std::char_traits<char>::length(from), to);
    return text;
}
}

int main() {
    using namespace amcl::graphics;
    GraphicsPlan parsed;
    std::string error;
    const std::string vulkan = "v=v2;profile=minecraft-vulkan;api=VULKAN;window=GLFW;route=minecraft-vulkan;transport=YES;strict=0;policy=ALLOW;game=DUAL;slot=LWJGL3;admission=VALIDATION;requirement=minecraft-26.2-conservative-v1";
    const std::string legacyGl = "v=v1;profile=mobileglues;api=OPENGL;window=GLFW;route=mobileglues;transport=UNKNOWN;strict=0";
    require(ParseGraphicsPlan(legacyGl, parsed, error), "valid legacy OpenGL schema");
    require(!ParseGraphicsPlan(replace(legacyGl, "v=v1", "v=v2"), parsed, error), "v2 cannot use v1 field count");
    require(!ParseGraphicsPlan(replace(vulkan, "v=v2", "v=v1"), parsed, error), "v1 cannot use v2 field count");
    require(!ParseGraphicsPlan(vulkan + ";", parsed, error), "trailing delimiter rejected");
    require(!ParseGraphicsPlan(vulkan + ";profile=minecraft-vulkan", parsed, error), "duplicate field rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "window=GLFW", "window=DESKTOP"), parsed, error), "desktop is not a window API");
    require(!ParseGraphicsPlan(replace(vulkan, "route=minecraft-vulkan", "route=mobileglues"), parsed, error), "profile route mismatch rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "requirement=minecraft-26.2-conservative-v1", "requirement=unknown"), parsed, error), "unrecognized audit rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "admission=VALIDATION", "admission=VERIFIED"), parsed, error), "self-promoted admission rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "policy=ALLOW", "policy=DISABLE_VULKAN"), parsed, error), "disabled Vulkan rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "game=DUAL", "game=UNKNOWN"), parsed, error), "unknown game capability rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "slot=LWJGL3", "slot=LWJGL322"), parsed, error), "incompatible native slot rejected");
    require(!ParseGraphicsPlan(replace(vulkan, "transport=YES", "transport=NO"), parsed, error), "transport cannot contradict profile");
    require(!LegacyGraphicsPlan("minecraft-vulkan", parsed, error), "legacy marker cannot admit native Vulkan");
    require(!LegacyGraphicsPlan("mobilegl", parsed, error), "legacy marker cannot admit Vulkan transport candidate");
    require(!LegacyGraphicsPlan("zink", parsed, error), "retired legacy route rejected");
    require(LegacyGraphicsPlan("system-opengl", parsed, error) && parsed.profile == "nativegl", "legacy spelling normalized");

    require(ParseGraphicsPlan(vulkan, parsed, error), "Vulkan plan parses");
    GraphicsCapability evidence;
    evidence.profileId = "minecraft-vulkan";
    evidence.requirementId = "minecraft-26.2-conservative-v1";
    evidence.windowProvider = "GLFW";
    evidence.processId = currentPid();
    evidence.nativeLibraryDir = "/app/libs/arm64";
    evidence.nativeWindowGeneration = 7;
    require(!GrantNativeVulkan(parsed, evidence, error), "no grant before activation");
    require(ActivateGraphicsPlan(parsed, error), "first activation");
    require(!GrantNativeVulkan(parsed, evidence, error), "NOT_RUN observations cannot grant");
    evidence.loader = evidence.instance = evidence.windowSurface = evidence.physicalDevice = CapabilityEvidence::Yes;
    evidence.deviceExtensions = evidence.featureBits = evidence.queuePresentation = CapabilityEvidence::Yes;
    evidence.shaderToolchain = evidence.nativeArtifacts = CapabilityEvidence::Yes;
    require(evidence.lifecycleSmoke == CapabilityEvidence::NotRun, "launch prerequisite admission does not invent lifecycle result");
    GraphicsCapability wrongScope = evidence;
    wrongScope.profileId = "mobilegl";
    require(!GrantNativeVulkan(parsed, wrongScope, error), "another profile's evidence cannot grant");
    wrongScope = evidence;
    wrongScope.processId = currentPid() + 1;
    require(!GrantNativeVulkan(parsed, wrongScope, error), "another process's evidence cannot grant");
    wrongScope = evidence;
    wrongScope.nativeArtifacts = CapabilityEvidence::No;
    require(!GrantNativeVulkan(parsed, wrongScope, error), "missing native artifact cannot grant");
    require(GrantNativeVulkan(parsed, evidence, error) && NativeVulkanGranted(), "all scoped launch prerequisites grant");
    require(ActivateGraphicsPlan(parsed, error) && !NativeVulkanGranted(), "new launch revalidates previous grant");
    GraphicsPlan otherPlan;
    require(LegacyGraphicsPlan("mobileglues", otherPlan, error), "legacy baseline resolves");
    require(!ActivateGraphicsPlan(otherPlan, error) && error == "graphics_profile_change_requires_process_restart", "same process cannot switch graphics providers");
    require(ActiveGraphicsPlan() && ActiveGraphicsPlan()->profile == "minecraft-vulkan", "rejected change retains active plan");
#ifndef _WIN32
    const pid_t child = fork();
    if (child == 0) {
        const bool reset = ActiveGraphicsPlan() == nullptr && !NativeVulkanGranted();
        const bool activated = ActivateGraphicsPlan(otherPlan, error);
        _exit(reset && activated ? 0 : 1);
    }
    int childStatus = 0;
    require(child > 0 && waitpid(child, &childStatus, 0) == child && WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0,
        "fork clears inherited graphics plan and grant before child activation");
#endif
    if (failures == 0) std::cout << "graphics_plan_host_test: OK\n";
    return failures == 0 ? 0 : 1;
}

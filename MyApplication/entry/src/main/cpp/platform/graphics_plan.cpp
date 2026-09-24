#include "graphics_plan.h"
#include "graphics_profile_mirror.generated.h"

#include <cstdlib>
#include <cstring>
#include <vector>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

namespace amcl::graphics {
namespace {
GraphicsPlan activePlan;
bool hasActivePlan = false;
bool nativeVulkanGranted = false;
int activeProcessId = 0;

int processId() {
#ifdef _WIN32
    return _getpid();
#else
    return static_cast<int>(getpid());
#endif
}

void writeEnvironment(const char* name, const char* value) {
#ifdef _WIN32
    _putenv_s(name, value);
#else
    setenv(name, value, 1);
#endif
}

void resetAfterFork() {
    const int current = processId();
    if (activeProcessId == current) return;
    activeProcessId = current;
    activePlan = GraphicsPlan{};
    hasActivePlan = false;
    nativeVulkanGranted = false;
    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", "0");
    static const char* inheritedFields[] = {"AMCL_GRAPHICS_PROFILE", "AMCL_GRAPHICS_API", "AMCL_GRAPHICS_ROUTE",
        "AMCL_GRAPHICS_WINDOW", "AMCL_GRAPHICS_POLICY", "AMCL_GRAPHICS_GAME", "AMCL_GRAPHICS_SLOT",
        "AMCL_GRAPHICS_ADMISSION", "AMCL_GRAPHICS_REQUIREMENT"};
    for (const char* field : inheritedFields) writeEnvironment(field, "");
    writeEnvironment("AMCL_GRAPHICS_TRANSPORT", "UNKNOWN");
    writeEnvironment("AMCL_GRAPHICS_ACTUAL_PROVIDER", "UNKNOWN");
    writeEnvironment("AMCL_GRAPHICS_ACTUAL_VULKAN", "UNKNOWN");
    writeEnvironment("AMCL_GRAPHICS_STRICT", "0");
}

bool samePlan(const GraphicsPlan& left, const GraphicsPlan& right) {
    return left.profile == right.profile && left.api == right.api && left.window == right.window &&
        left.route == right.route && left.transport == right.transport && left.policy == right.policy &&
        left.game == right.game && left.slot == right.slot && left.admission == right.admission &&
        left.requirement == right.requirement && left.strict == right.strict;
}

bool validToken(const std::string& value) {
    if (value.empty() || value.size() > 128) return false;
    for (const unsigned char character : value) {
        if ((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' || character == '_' || character == '.') continue;
        return false;
    }
    return true;
}

bool fail(std::string& error, const char* reason) {
    error = reason;
    return false;
}

bool validate(const GraphicsPlan& plan, std::string& error) {
    if (plan.version != "v1" && plan.version != "v2") return fail(error, "unsupported_plan_version");
    const auto* profile = FindGraphicsProfile(plan.profile.c_str());
    if (!profile) return fail(error, "unknown_graphics_profile");
    if (plan.api != profile->api || plan.route != profile->nativeRoute) return fail(error, "profile_api_or_route_mismatch");
    if (plan.window != "GLFW" && plan.window != "SDL3") return fail(error, "unknown_window_provider");
    if (!GraphicsProfileSupportsProvider(*profile, plan.window.c_str())) return fail(error, "unsupported_profile_window_provider");
    if (plan.transport != profile->transport) return fail(error, "profile_transport_declaration_mismatch");
    if (plan.policy != "ALLOW" && plan.policy != "DISABLE_VULKAN" && plan.policy != "FORBID_VULKAN_TRANSPORT") {
        return fail(error, "unknown_vulkan_policy");
    }
    if (plan.game != "OPENGL" && plan.game != "VULKAN" && plan.game != "DUAL" && plan.game != "UNKNOWN") {
        return fail(error, "unknown_game_api");
    }
    if (plan.slot != "LWJGL2" && plan.slot != "LWJGL322" && plan.slot != "LWJGL3") return fail(error, "unknown_lwjgl_slot");
    if (plan.admission != "LEGACY" && plan.admission != "VALIDATION" && plan.admission != "VERIFIED") {
        return fail(error, "unknown_admission_level");
    }
    if (plan.version == "v1") {
        if (plan.profile != "mobileglues" && plan.profile != "gl4es" && plan.profile != "nativegl") {
            return fail(error, "legacy_schema_cannot_admit_candidate");
        }
        if (plan.admission != "LEGACY" || plan.requirement != "unknown") return fail(error, "legacy_schema_evidence_mismatch");
    } else {
        if (!GraphicsProfileSupportsRequirement(*profile, plan.requirement.c_str()) ||
            plan.admission != profile->admission) {
            return fail(error, "profile_requirement_or_admission_mismatch");
        }
    }
    if (plan.strict != (plan.policy == "FORBID_VULKAN_TRANSPORT")) return fail(error, "strict_policy_mismatch");
    if (plan.policy == "FORBID_VULKAN_TRANSPORT" && plan.transport != "NO") {
        return fail(error, "non_vulkan_transport_not_proven");
    }
    if (plan.api == "VULKAN") {
        if (plan.policy != "ALLOW") return fail(error, "vulkan_disabled_by_policy");
        if (plan.game != "VULKAN" && plan.game != "DUAL") return fail(error, "game_vulkan_api_not_declared");
        if (plan.slot != "LWJGL3") return fail(error, "vulkan_requires_modern_lwjgl_slot");
    } else if (plan.game == "VULKAN") {
        return fail(error, "vulkan_only_game_cannot_use_opengl_profile");
    }
    if (plan.slot == "LWJGL2" && (plan.profile != "gl4es" || plan.window != "GLFW")) {
        return fail(error, "lwjgl2_requires_gl4es_glfw");
    }
    return true;
}

void publishPlan(const GraphicsPlan& plan) {
    writeEnvironment("AMCL_GRAPHICS_PROFILE", plan.profile.c_str());
    writeEnvironment("AMCL_GRAPHICS_API", plan.api.c_str());
    writeEnvironment("AMCL_GRAPHICS_ROUTE", plan.route.c_str());
    writeEnvironment("AMCL_GRAPHICS_WINDOW", plan.window.c_str());
    writeEnvironment("AMCL_GRAPHICS_TRANSPORT", plan.transport.c_str());
    writeEnvironment("AMCL_GRAPHICS_POLICY", plan.policy.c_str());
    writeEnvironment("AMCL_GRAPHICS_GAME", plan.game.c_str());
    writeEnvironment("AMCL_GRAPHICS_SLOT", plan.slot.c_str());
    writeEnvironment("AMCL_GRAPHICS_ADMISSION", plan.admission.c_str());
    writeEnvironment("AMCL_GRAPHICS_REQUIREMENT", plan.requirement.c_str());
    writeEnvironment("AMCL_GRAPHICS_ACTUAL_PROVIDER", "UNKNOWN");
    writeEnvironment("AMCL_GRAPHICS_ACTUAL_VULKAN", "UNKNOWN");
    writeEnvironment("AMCL_GRAPHICS_STRICT", plan.strict ? "1" : "0");
    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", nativeVulkanGranted ? "1" : "0");
}
} // namespace

bool ParseGraphicsPlan(const std::string& wire, GraphicsPlan& plan, std::string& error) {
    plan = GraphicsPlan{};
    error.clear();
    if (wire.empty() || wire.size() > 2048 || wire.back() == ';') return fail(error, "invalid_graphics_plan_length_or_terminator");
    static const char* keys[] = {"v", "profile", "api", "window", "route", "transport", "strict", "policy", "game", "slot", "admission", "requirement"};
    std::vector<std::string> values;
    size_t position = 0;
    while (position < wire.size()) {
        const size_t end = wire.find(';', position);
        const std::string field = wire.substr(position, end == std::string::npos ? std::string::npos : end - position);
        const size_t equals = field.find('=');
        if (values.size() >= 12 || equals == std::string::npos || equals == 0 ||
            field.substr(0, equals) != keys[values.size()] || field.find('=', equals + 1) != std::string::npos) {
            return fail(error, "unknown_duplicate_or_out_of_order_plan_field");
        }
        const std::string value = field.substr(equals + 1);
        if (!validToken(value)) return fail(error, "invalid_plan_field_value");
        values.push_back(value);
        if (end == std::string::npos) break;
        position = end + 1;
    }
    if (values.empty() || (values[0] == "v1" ? values.size() != 7 : values[0] == "v2" ? values.size() != 12 : true)) {
        return fail(error, "schema_version_field_count_mismatch");
    }
    plan.version = values[0]; plan.profile = values[1]; plan.api = values[2];
    plan.window = values[3]; plan.route = values[4]; plan.transport = values[5];
    if (values[6] != "0" && values[6] != "1") return fail(error, "invalid_strict_value");
    plan.strict = values[6] == "1";
    if (values.size() == 12) {
        plan.policy = values[7]; plan.game = values[8]; plan.slot = values[9];
        plan.admission = values[10]; plan.requirement = values[11];
    } else {
        plan.policy = plan.strict ? "FORBID_VULKAN_TRANSPORT" : "ALLOW";
        plan.game = plan.api;
    }
    return validate(plan, error);
}

bool LegacyGraphicsPlan(const std::string& backend, GraphicsPlan& plan, std::string& error) {
    plan = GraphicsPlan{};
    error.clear();
    plan.version = "v1";
    plan.profile = backend.empty() ? "mobileglues" : backend == "system-opengl" ? "nativegl" : backend;
    plan.api = "OPENGL";
    plan.window = "GLFW";
    plan.route = plan.profile;
    plan.transport = "UNKNOWN";
    plan.game = "OPENGL";
    return validate(plan, error);
}

bool ActivateGraphicsPlan(const GraphicsPlan& plan, std::string& error) {
    resetAfterFork();
    error.clear();
    if (!validate(plan, error)) return false;
    if (hasActivePlan && !samePlan(activePlan, plan)) return fail(error, "graphics_profile_change_requires_process_restart");
    activePlan = plan;
    hasActivePlan = true;
    nativeVulkanGranted = false;
    publishPlan(plan);
    return true;
}

bool ValidateGraphicsCapability(const GraphicsPlan& plan, const GraphicsCapability& capability, std::string& error) {
    resetAfterFork();
    error.clear();
    if (!hasActivePlan || !samePlan(activePlan, plan)) return fail(error, "native_grant_does_not_match_active_plan");
    if (!validate(plan, error)) return false;
    if (capability.profileId != plan.profile || capability.requirementId != plan.requirement ||
        capability.windowProvider != plan.window || capability.processId != processId() ||
        capability.nativeLibraryDir.empty() || capability.nativeWindowGeneration == 0) {
        return fail(error, "native_capability_scope_mismatch");
    }
    const CapabilityEvidence required[] = {capability.loader, capability.instance, capability.windowSurface,
        capability.physicalDevice, capability.deviceExtensions, capability.featureBits, capability.queuePresentation,
        capability.shaderToolchain, capability.nativeArtifacts};
    for (const CapabilityEvidence observation : required) {
        if (observation != CapabilityEvidence::Yes) {
            error = "native_capability_not_admitted: " + capability.reasonCode;
            return false;
        }
    }
    return true;
}

bool GrantNativeVulkan(const GraphicsPlan& plan, const GraphicsCapability& capability, std::string& error) {
    resetAfterFork();
    nativeVulkanGranted = false;
    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", "0");
    if (!ValidateGraphicsCapability(plan, capability, error)) return false;
    if (plan.version != "v2" || plan.profile != "minecraft-vulkan" || plan.api != "VULKAN" || plan.policy != "ALLOW") {
        return fail(error, "native_grant_requires_admitted_vulkan_plan");
    }
    nativeVulkanGranted = true;
    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", "1");
    return true;
}

const GraphicsPlan* ActiveGraphicsPlan() {
    resetAfterFork();
    return hasActivePlan ? &activePlan : nullptr;
}

bool NativeVulkanGranted() {
    resetAfterFork();
    return nativeVulkanGranted;
}

extern "C" int amclParseGraphicsPlan(const char* wire, char* error, int capacity) {
    GraphicsPlan plan;
    std::string reason;
    const bool accepted = wire && ParseGraphicsPlan(wire, plan, reason);
    if (!wire) reason = "null_graphics_plan";
    if (error && capacity > 0) {
        std::strncpy(error, reason.c_str(), static_cast<size_t>(capacity) - 1);
        error[capacity - 1] = '\0';
    }
    return accepted ? 1 : 0;
}
} // namespace amcl::graphics

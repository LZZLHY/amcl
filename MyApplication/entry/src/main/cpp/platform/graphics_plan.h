#ifndef AMCL_GRAPHICS_PLAN_H
#define AMCL_GRAPHICS_PLAN_H

#include "graphics_capability.h"
#include <string>

namespace amcl::graphics {

struct GraphicsPlan {
    std::string version;
    std::string profile;
    std::string api;
    std::string window;
    std::string route;
    std::string transport;
    std::string actualProvider = "UNKNOWN";
    std::string actualVulkan = "UNKNOWN";
    std::string policy = "ALLOW";
    std::string game = "UNKNOWN";
    std::string slot = "LWJGL3";
    std::string admission = "LEGACY";
    std::string requirement = "unknown";
    bool strict = false;
};

bool ParseGraphicsPlan(const std::string& wire, GraphicsPlan& plan, std::string& error);
bool LegacyGraphicsPlan(const std::string& backend, GraphicsPlan& plan, std::string& error);
// Once activated, provider-affecting fields are immutable for the process.
// A fork resets this latch by PID before any new plan can be used.
bool ActivateGraphicsPlan(const GraphicsPlan& plan, std::string& error);
bool ValidateGraphicsCapability(const GraphicsPlan& plan, const GraphicsCapability& capability, std::string& error);
bool GrantNativeVulkan(const GraphicsPlan& plan, const GraphicsCapability& capability, std::string& error);
const GraphicsPlan* ActiveGraphicsPlan();
bool NativeVulkanGranted();
extern "C" int amclParseGraphicsPlan(const char* wire, char* error, int errorCapacity);

} // namespace amcl::graphics
#endif

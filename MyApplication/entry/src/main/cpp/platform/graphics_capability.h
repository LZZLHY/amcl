#ifndef AMCL_GRAPHICS_CAPABILITY_H
#define AMCL_GRAPHICS_CAPABILITY_H

#include <cstdint>
#include <string>

namespace amcl::graphics {

enum class CapabilityEvidence { Yes, No, Unknown, NotRun };

// A native observation is scoped to one requirement, window provider and process.
// No aggregate "available" flag is allowed to manufacture an unrun observation.
struct GraphicsCapability {
    CapabilityEvidence loader = CapabilityEvidence::NotRun;
    CapabilityEvidence instance = CapabilityEvidence::NotRun;
    CapabilityEvidence windowSurface = CapabilityEvidence::NotRun;
    CapabilityEvidence physicalDevice = CapabilityEvidence::NotRun;
    CapabilityEvidence deviceExtensions = CapabilityEvidence::NotRun;
    CapabilityEvidence featureBits = CapabilityEvidence::NotRun;
    CapabilityEvidence queuePresentation = CapabilityEvidence::NotRun;
    CapabilityEvidence shaderToolchain = CapabilityEvidence::NotRun;
    CapabilityEvidence nativeArtifacts = CapabilityEvidence::NotRun;
    CapabilityEvidence lifecycleSmoke = CapabilityEvidence::NotRun;
    std::string apiVersion;
    std::string profileId;
    std::string requirementId;
    std::string windowProvider;
    std::string reasonCode;
    std::string observedProvider;
    std::string driverIdentity;
    std::string nativeLibraryDir;
    uint64_t nativeWindowGeneration = 0;
    int processId = 0;
};

GraphicsCapability ProbeGraphicsCapability(const std::string& profileId,
    const std::string& requirementId, const std::string& windowProvider,
    const std::string& nativeLibraryDir, bool availabilityOnly = false);

} // namespace amcl::graphics
#endif

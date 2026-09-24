// Pure WSI checks shared by the GLFW Vulkan adapter and host tests.
//
// This header deliberately contains no profile selection or Minecraft feature
// requirements.  Those belong to the platform CapabilityProvider
// (amclVulkanUsableForMc).  The GLFW adapter only proves that the loader and
// OHOS WSI seam are present before asking that provider for admission.
#ifndef AMCL_GLFW_VULKAN_WSI_H
#define AMCL_GLFW_VULKAN_WSI_H

#include <cstdint>

namespace amcl::glfw::vulkan {

struct LoaderProbe {
    bool loader = false;
    bool getInstanceProcAddr = false;
    bool khrSurface = false;
    bool ohosSurface = false;
};

inline bool MinimalLoaderReady(const LoaderProbe& p) {
    return p.loader && p.getInstanceProcAddr;
}

inline bool RequiredInstanceExtensionsReady(const LoaderProbe& p) {
    return MinimalLoaderReady(p) && p.khrSurface && p.ohosSurface;
}

// A lease is valid only while its publication generation is still current.
// The broker acquire operation validates ownership and obtains the lease; this
// check closes the race between acquire and vkCreateSurfaceOHOS.
inline bool LeaseGenerationCurrent(void* nativeWindow,
                                   void* leaseBroker,
                                   std::uint64_t acquiredGeneration,
                                   std::uint64_t currentGeneration) {
    return nativeWindow != nullptr && leaseBroker != nullptr &&
           acquiredGeneration != 0 && acquiredGeneration == currentGeneration;
}

} // namespace amcl::glfw::vulkan

#endif // AMCL_GLFW_VULKAN_WSI_H

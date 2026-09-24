#pragma once
#include "../glfw/amcl_native_window_lease_broker_abi.h"
#include <stdint.h>

#if defined(_WIN32) && defined(AMCL_VK_BUILD_DLL)
#define AMCL_VK_EXPORT __declspec(dllexport)
#elif defined(_WIN32)
#define AMCL_VK_EXPORT
#else
#define AMCL_VK_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// The loader/session DSO has no dependency on GLFW, EGL or MobileGlues. Handles
// cross this ABI as pointer/uint64_t values; Vulkan resource owners retain their
// original allocation callbacks. Admission is set only by the native launcher.
AMCL_VK_EXPORT int amclVulkanSetAdmission(int admitted, const char* profile, const char* requirement);
AMCL_VK_EXPORT int amclVulkanAdmissionGranted(void);
AMCL_VK_EXPORT int amclVulkanSetLoader(void* getInstanceProcAddr);
AMCL_VK_EXPORT void* amclVulkanGetInstanceProcAddr(void* instance, const char* name);
AMCL_VK_EXPORT void* amclVulkanGetDeviceProcAddr(void* device, const char* name);
AMCL_VK_EXPORT const char* const* amclVulkanRequiredExtensions(uint32_t* count);
AMCL_VK_EXPORT int amclVulkanCreateSurface(void* instance, uint64_t windowId,
    const AmclNativeWindowLeaseBrokerV2* broker, const void* allocator, uint64_t* surface);
AMCL_VK_EXPORT int amclVulkanWindowHasLiveSurface(uint64_t windowId);

typedef struct AmclVulkanWsiStats {
    uint32_t structSize;
    uint64_t created;
    uint64_t destroyed;
    uint64_t live;
    uint64_t rejected;
} AmclVulkanWsiStats;
AMCL_VK_EXPORT int amclVulkanGetStats(AmclVulkanWsiStats* stats);

#ifdef __cplusplus
}
#endif

// GLFW exports are a thin facade. The independent WSI DSO owns loader dispatch
// and VkSurface/native-window leases and has no EGL/MobileGlues dependency.
#include "glfw_internal.h"
#include "../platform/vulkan_wsi.h"
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_core.h>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "GLFW_VK"

extern "C" {
void glfwInitVulkanLoader(PFN_vkGetInstanceProcAddr loader) {
    if (!amclVulkanSetLoader(reinterpret_cast<void*>(loader))) {
        OH_LOG_ERROR(LOG_APP, "GLFW: Vulkan loader cannot change while surfaces are live");
    }
}

int glfwVulkanSupported(void) {
    uint32_t count = 0;
    return amclVulkanAdmissionGranted() && amclVulkanRequiredExtensions(&count) && count == 2
        ? GLFW_TRUE : GLFW_FALSE;
}

const char** glfwGetRequiredInstanceExtensions(uint32_t* count) {
    return const_cast<const char**>(amclVulkanRequiredExtensions(count));
}

PFN_vkVoidFunction glfwGetInstanceProcAddress(VkInstance instance, const char* name) {
    return reinterpret_cast<PFN_vkVoidFunction>(amclVulkanGetInstanceProcAddr(instance, name));
}

int glfwGetPhysicalDevicePresentationSupport(VkInstance instance, VkPhysicalDevice device,
                                              uint32_t queueFamily) {
    // OHOS has no platform-only presentation-support query. The game's query
    // against its concrete VkSurface is authoritative; reject invalid families.
    auto getQueues = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        amclVulkanGetInstanceProcAddr(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    if (!getQueues || !amclVulkanAdmissionGranted()) return GLFW_FALSE;
    uint32_t count = 0;
    getQueues(device, &count, nullptr);
    return queueFamily < count ? GLFW_TRUE : GLFW_FALSE;
}

VkResult glfwCreateWindowSurface(VkInstance instance, GLFWwindow* window,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* surface) {
    if (!surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = VK_NULL_HANDLE;
    if (!window || glfwOHOS_GetWindowClientAPI(window) != GLFW_NO_API) {
        if (g_errorCallback) g_errorCallback(GLFW_INVALID_VALUE, "Vulkan requires a GLFW_NO_API window");
        return VK_ERROR_NATIVE_WINDOW_IN_USE_KHR;
    }
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(window->nativeWindowLeaseBroker);
    uint64_t resultSurface = 0;
    const auto result = static_cast<VkResult>(amclVulkanCreateSurface(instance,
        glfwOHOS_GetWindowId(window), broker, allocator, &resultSurface));
    if (result == VK_SUCCESS) *surface = reinterpret_cast<VkSurfaceKHR>(static_cast<uintptr_t>(resultSurface));
    return result;
}
}
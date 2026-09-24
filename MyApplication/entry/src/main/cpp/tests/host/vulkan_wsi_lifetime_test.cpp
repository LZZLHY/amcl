#include "../../platform/vulkan_wsi.h"
#include "../../glfw/amcl_presentation_owner.h"
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_core.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
int references = 0;
uint64_t generation = 1;
AmclPresentationOwner owner;
void* nativeWindow = reinterpret_cast<void*>(0x1000);
VkInstance instance = reinterpret_cast<VkInstance>(0x2000);
uint64_t nextSurface = 0x3000;
int driverCreates = 0, driverDestroys = 0;
bool staleDuringCreate = false, failCreate = false, omitDestroy = false;
bool failTokenRelease = false;
bool destroyEntered = false;
std::vector<std::string> operations;
const VkAllocationCallbacks* expectedAllocator = nullptr;
int acquire(void*, uint64_t, void** p, int* width, int* height, uint64_t* g) {
    ++references; *p = nativeWindow; *width = 1024; *height = 768; *g = generation;
    operations.push_back("retain"); return 1;
}
void release(void* p) {
    require(p == nativeWindow && references > 0, "balanced NativeWindow release");
    --references; operations.push_back("release");
}
uint64_t peek() { return generation; }
AmclNativeWindowPublicationState peekState() { return AMCL_NATIVE_WINDOW_PUBLICATION_READY; }
int claim(void* p, uint64_t g, uint32_t api, uint64_t* token) {
    require(api == 2, "Vulkan presentation API tag");
    if (p != nativeWindow || g != generation) return 0;
    return owner.claim(p, g, api, *token);
}
int move(uint64_t token, void* p, uint64_t g) { return owner.move(token, p, g); }
int releaseToken(uint64_t token) {
    operations.push_back("release-token");
    return failTokenRelease ? 0 : owner.release(token);
}
AmclNativeWindowLeaseBrokerV2 broker{2, sizeof(AmclNativeWindowLeaseBrokerV2), acquire, release,
    nullptr, nullptr, peek, peekState, claim, move, releaseToken};

struct SurfaceInfo { VkStructureType sType; const void* next; VkFlags flags; void* window; };
VKAPI_ATTR VkResult VKAPI_CALL driverCreate(VkInstance, const SurfaceInfo* info,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* surface) {
    require(references == 1 && owner.token() != 0, "claim and retain before driver create");
    require(info->window == nativeWindow, "coherent surface window");
    require(allocator == expectedAllocator, "same allocator on create");
    ++driverCreates; operations.push_back("create");
    if (failCreate) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = reinterpret_cast<VkSurfaceKHR>(static_cast<uintptr_t>(++nextSurface));
    if (staleDuringCreate) ++generation;
    return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL driverDestroy(VkInstance, VkSurfaceKHR, const VkAllocationCallbacks* allocator) {
    require(references == 1 && owner.token() != 0, "retain and exclusive ownership through driver destruction");
    require(allocator == expectedAllocator, "preserve allocator on rollback/destroy");
    ++driverDestroys; destroyEntered = true; operations.push_back("destroy");
}
VKAPI_ATTR VkResult VKAPI_CALL enumerate(const char*, uint32_t* count, VkExtensionProperties* out) {
    if (!out) { *count = 2; return VK_SUCCESS; }
    std::strcpy(out[0].extensionName, "VK_KHR_surface");
    std::strcpy(out[1].extensionName, "VK_OHOS_surface"); *count = 2; return VK_SUCCESS;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL loader(VkInstance, const char* name) {
    if (std::strcmp(name, "vkCreateSurfaceOHOS") == 0) return reinterpret_cast<PFN_vkVoidFunction>(&driverCreate);
    if (std::strcmp(name, "vkDestroySurfaceKHR") == 0) return omitDestroy ? nullptr : reinterpret_cast<PFN_vkVoidFunction>(&driverDestroy);
    if (std::strcmp(name, "vkEnumerateInstanceExtensionProperties") == 0) return reinterpret_cast<PFN_vkVoidFunction>(&enumerate);
    return nullptr;
}
}
int main() {
    require(amclVulkanSetLoader(reinterpret_cast<void*>(&loader)), "inject host Vulkan driver");
    uint64_t surface = 0;
    require(amclVulkanCreateSurface(instance, 12, &broker, nullptr, &surface) != VK_SUCCESS, "no admission cannot create");
    require(amclVulkanSetAdmission(1, "minecraft-vulkan", "minecraft-26.2-conservative-v1"), "explicit admission");
    uint32_t count = 0;
    require(amclVulkanRequiredExtensions(&count) != nullptr && count == 2, "real loader WSI extension query");
    require(amclVulkanCreateSurface(instance, 12, &broker, nullptr, &surface) == VK_SUCCESS && surface, "create tracked Vulkan surface");
    require(references == 1 && owner.token() != 0 && amclVulkanWindowHasLiveSurface(12), "lease persists after return");
    require(!amclVulkanSetAdmission(0, "", ""), "cannot change admission during active session");
    uint64_t competitor = 0;
    require(amclVulkanCreateSurface(instance, 13, &broker, nullptr, &competitor) == VK_ERROR_NATIVE_WINDOW_IN_USE_KHR, "another window cannot take presenter");
    require(references == 1 && driverCreates == 1, "contender balanced and did not call driver");
    auto wrappedDestroy = reinterpret_cast<PFN_vkDestroySurfaceKHR>(amclVulkanGetInstanceProcAddr(instance, "vkDestroySurfaceKHR"));
    require(wrappedDestroy && wrappedDestroy != &driverDestroy, "destroy dispatch must be intercepted");
    wrappedDestroy(instance, reinterpret_cast<VkSurfaceKHR>(static_cast<uintptr_t>(surface)), nullptr);
    require(destroyEntered && references == 0 && owner.token() == 0 && !amclVulkanWindowHasLiveSurface(12), "real destruction precedes lease retirement");
    require(operations[operations.size()-3] == "destroy" && operations[operations.size()-2] == "release-token" && operations.back() == "release", "destruction order");

    expectedAllocator = reinterpret_cast<const VkAllocationCallbacks*>(0x4000);
    staleDuringCreate = true;
    require(amclVulkanCreateSurface(instance, 14, &broker, expectedAllocator, &surface) == VK_ERROR_SURFACE_LOST_KHR, "generation race rollback");
    require(surface == 0 && references == 0 && owner.token() == 0 && driverDestroys == 2, "raced handle destroyed, never leaked");
    staleDuringCreate = false; failCreate = true;
    require(amclVulkanCreateSurface(instance, 15, &broker, expectedAllocator, &surface) != VK_SUCCESS, "driver failure");
    require(references == 0 && owner.token() == 0 && driverDestroys == 2, "failure returns all ownership without destroy null");
    failCreate = false; omitDestroy = true;
    require(amclVulkanCreateSurface(instance, 16, &broker, expectedAllocator, &surface) == VK_ERROR_EXTENSION_NOT_PRESENT, "no teardown entry cannot allocate");
    omitDestroy = false;
    auto oldBroker = broker; oldBroker.structSize = AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE;
    require(amclVulkanCreateSurface(instance, 17, &oldBroker, expectedAllocator, &surface) != VK_SUCCESS, "short ABI must not read presentation tail");
    AmclVulkanWsiStats stats{sizeof(AmclVulkanWsiStats), 0, 0, 0, 0};
    require(amclVulkanGetStats(&stats) && stats.created == 1 && stats.destroyed == 1 && stats.live == 0, "monotonic published surface evidence");
    char brokerText[64];
    std::snprintf(brokerText, sizeof(brokerText), "2:%p", static_cast<void*>(&broker));
#ifdef _WIN32
    _putenv_s(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, brokerText);
#else
    setenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, brokerText, 1);
#endif
    using CreateOhosFn = VkResult(VKAPI_PTR*)(VkInstance, const SurfaceInfo*, const VkAllocationCallbacks*, VkSurfaceKHR*);
    auto sdlCreate = reinterpret_cast<CreateOhosFn>(amclVulkanGetInstanceProcAddr(instance, "vkCreateSurfaceOHOS"));
    SurfaceInfo sdlInfo{static_cast<VkStructureType>(1000685000), nullptr, 0, nativeWindow};
    VkSurfaceKHR sdlSurface = VK_NULL_HANDLE;
    require(sdlCreate && sdlCreate(instance, &sdlInfo, expectedAllocator, &sdlSurface) == VK_SUCCESS, "SDL loader entry consumes real versioned broker descriptor");
    require(references == 1 && owner.token() != 0, "SDL surface owns independent reference and token");
    wrappedDestroy(instance, sdlSurface, expectedAllocator);
    require(references == 0 && owner.token() == 0, "SDL destruction returns exact lifetime ownership");
    require(amclVulkanSetAdmission(0, "", "") && !amclVulkanAdmissionGranted(), "revoke after retirement");
    require(amclVulkanSetAdmission(1, "minecraft-vulkan", "minecraft-26.2-conservative-v1"), "new clean session");
    require(amclVulkanCreateSurface(instance, 18, &broker, expectedAllocator, &surface) == VK_SUCCESS, "release-failure fixture create");
    failTokenRelease = true;
    wrappedDestroy(instance, reinterpret_cast<VkSurfaceKHR>(static_cast<uintptr_t>(surface)), expectedAllocator);
    require(references == 1 && owner.token() != 0 && amclVulkanWindowHasLiveSurface(18), "uncertain token retained with its native lease");
    require(!amclVulkanAdmissionGranted() && !amclVulkanSetAdmission(1, "minecraft-vulkan", "minecraft-26.2-conservative-v1"), "quarantine requires a new process");
    std::cout << "Vulkan WSI production lifetime and rollback tests passed\n";
}

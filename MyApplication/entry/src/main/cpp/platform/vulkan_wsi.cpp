#include "vulkan_wsi.h"
#include "graphics_profile_mirror.generated.h"
#include "graphics_observation_abi.h"
#include "vulkan_surface_policy.h"
#include "vulkan_wsi_diagnostics.h"
#include "../utils/product_diagnostics.h"
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_core.h>
#include <hilog/log.h>
#include <cstdlib>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <atomic>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

#undef LOG_TAG
#define LOG_TAG "AMCL_VULKAN_WSI"

/**
 * 将已获准输出的 WSI 记录同时写入 hilog 和游戏日志。游戏在载入 Vulkan backend 前
 * 已把 stderr 重定向到 mc_output.log，远程排查只有游戏日志时也必须保留错误、设备/
 * surface/swapchain 生命周期与低频 present 计数。该 DSO 可能处于独立链接命名空间，
 * 不借用 libentry 的 logger；资源成功 trace 必须先经过下方门控，再进入格式化和 IO。
 */
void emitWsiLog(bool error, const char* format, ...) {
    char line[1024] = {0};
    va_list args;
    va_start(args, format);
    std::vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (error) OH_LOG_ERROR(LOG_APP, "%{public}s", line);
    else OH_LOG_INFO(LOG_APP, "%{public}s", line);
    std::fprintf(stderr, "[AMCL_VULKAN_WSI] %s\n", line);
    std::fflush(stderr);
}

/**
 * 在格式化、两个输出通道及 fflush 之前控制逐资源诊断。宏只计算一次错误判据，关闭
 * 成功 trace 时连日志参数也不求值；失败仍走同一常规输出，不能被产品诊断开关吞掉。
 * 生产 mask 由 amcl_apply_diagnostic_policy 注入，独立/宿主编译未声明时按 0 关闭。
 */
#define AMCL_WSI_TRACE(error, ...) do { \
    const bool amclWsiTraceError = (error); \
    if (::amcl::graphics::VulkanWsiTraceAllowed(AMCL_DIAGNOSTICS_MASK, amclWsiTraceError)) { \
        emitWsiLog(amclWsiTraceError, __VA_ARGS__); \
    } \
} while (false)

extern "C" AMCL_VK_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char* name);
extern "C" AMCL_VK_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(VkDevice device, const char* name);

namespace {
VKAPI_ATTR VkResult VKAPI_CALL enumeratePhysicalDevices(VkInstance, uint32_t*, VkPhysicalDevice*);
VKAPI_ATTR VkResult VKAPI_CALL createDevice(VkPhysicalDevice, const VkDeviceCreateInfo*, const VkAllocationCallbacks*, VkDevice*);
VKAPI_ATTR void VKAPI_CALL destroyDevice(VkDevice, const VkAllocationCallbacks*);
VKAPI_ATTR void VKAPI_CALL getDeviceQueue(VkDevice, uint32_t, uint32_t, VkQueue*);
VKAPI_ATTR VkResult VKAPI_CALL createSemaphore(VkDevice, const VkSemaphoreCreateInfo*, const VkAllocationCallbacks*, VkSemaphore*);
VKAPI_ATTR void VKAPI_CALL destroySemaphore(VkDevice, VkSemaphore, const VkAllocationCallbacks*);
VKAPI_ATTR VkResult VKAPI_CALL createCommandPool(VkDevice, const VkCommandPoolCreateInfo*, const VkAllocationCallbacks*, VkCommandPool*);
VKAPI_ATTR void VKAPI_CALL destroyCommandPool(VkDevice, VkCommandPool, const VkAllocationCallbacks*);
VKAPI_ATTR VkResult VKAPI_CALL allocateCommandBuffers(VkDevice, const VkCommandBufferAllocateInfo*, VkCommandBuffer*);
VKAPI_ATTR VkResult VKAPI_CALL createBuffer(VkDevice, const VkBufferCreateInfo*, const VkAllocationCallbacks*, VkBuffer*);
VKAPI_ATTR void VKAPI_CALL destroyBuffer(VkDevice, VkBuffer, const VkAllocationCallbacks*);
VKAPI_ATTR void VKAPI_CALL getBufferMemoryRequirements(VkDevice, VkBuffer, VkMemoryRequirements*);
VKAPI_ATTR void VKAPI_CALL getBufferMemoryRequirements2(VkDevice, const VkBufferMemoryRequirementsInfo2*, VkMemoryRequirements2*);
VKAPI_ATTR VkResult VKAPI_CALL allocateMemory(VkDevice, const VkMemoryAllocateInfo*, const VkAllocationCallbacks*, VkDeviceMemory*);
VKAPI_ATTR void VKAPI_CALL freeMemory(VkDevice, VkDeviceMemory, const VkAllocationCallbacks*);
VKAPI_ATTR VkResult VKAPI_CALL bindBufferMemory(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
VKAPI_ATTR VkResult VKAPI_CALL bindBufferMemory2(VkDevice, uint32_t, const VkBindBufferMemoryInfo*);
VKAPI_ATTR VkResult VKAPI_CALL bindImageMemory(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
VKAPI_ATTR VkResult VKAPI_CALL bindImageMemory2(VkDevice, uint32_t, const VkBindImageMemoryInfo*);
VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceProperties(VkPhysicalDevice, VkPhysicalDeviceProperties*);
VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceMemoryProperties(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceProperties2(VkPhysicalDevice, VkPhysicalDeviceProperties2*);
VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceMemoryProperties2(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties2*);
VKAPI_ATTR VkResult VKAPI_CALL createSwapchain(VkDevice, const VkSwapchainCreateInfoKHR*, const VkAllocationCallbacks*, VkSwapchainKHR*);
VKAPI_ATTR void VKAPI_CALL destroySwapchain(VkDevice, VkSwapchainKHR, const VkAllocationCallbacks*);
VKAPI_ATTR VkResult VKAPI_CALL queuePresent(VkQueue, const VkPresentInfoKHR*);
// The OHOS extension has the same wire layout in the SDK and the platform
// loader. Keep this private so host failure tests need only Vulkan core headers.
struct SurfaceCreateInfo {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    void* window;
};
using CreateSurfaceFn = VkResult(VKAPI_PTR*)(VkInstance, const SurfaceCreateInfo*,
    const VkAllocationCallbacks*, VkSurfaceKHR*);
constexpr VkStructureType kSurfaceType = static_cast<VkStructureType>(1000685000);

uint64_t pid() {
#ifdef _WIN32
    return static_cast<uint64_t>(_getpid());
#else
    return static_cast<uint64_t>(getpid());
#endif
}
void publishEnv(const char* name, const char* value) {
#ifdef _WIN32
    _putenv_s(name, value);
#else
    setenv(name, value, 1);
#endif
}
template <typename T> uint64_t bits(T handle) { return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle)); }
template <typename T> T handle(uint64_t value) { return reinterpret_cast<T>(static_cast<uintptr_t>(value)); }

struct SurfaceRecord {
    VkInstance instance;
    VkSurfaceKHR surface;
    uint64_t windowId;
    void* nativeWindow;
    uint64_t generation;
    uint64_t token;
    const AmclNativeWindowLeaseBrokerV2* broker;
    PFN_vkDestroySurfaceKHR destroy;
    bool destroying = false;
    const char* provider = "GLFW"; // 创建入口确定身份，不从当前可变环境猜测。
};
// 只保存呈现归属，不持有游戏swapchain；销毁仍完全由Minecraft调用驱动完成。
struct SwapchainRecord {
    VkDevice device;
    uint64_t windowId, generation;
    const char* provider;
};
struct DeviceRecord {
    VkPhysicalDevice physical;
    VkInstance instance;
    PFN_vkGetDeviceProcAddr getProc;
};
struct Runtime {
    std::mutex mutex;
    bool admitted = false;
    uint64_t processId = pid();
    PFN_vkGetInstanceProcAddr injected = nullptr;
    PFN_vkGetInstanceProcAddr system = nullptr;
    std::map<uint64_t, SurfaceRecord> surfaces;
    std::map<uint64_t, VkInstance> physicalDevices;
    std::map<uint64_t, DeviceRecord> devices;
    std::map<uint64_t, VkDevice> queues;
    std::map<uint64_t, SwapchainRecord> swapchains;
    PFN_vkCreateDevice createDevice = nullptr;
    PFN_vkGetDeviceProcAddr deviceProc = nullptr;
    uint64_t swapchainsCreated = 0, swapchainsDestroyed = 0, presents = 0;
    uint64_t deviceProcLookups = 0;
    std::vector<SurfaceRecord> quarantined;
    uint64_t creating = 0;
    std::map<uint64_t, unsigned> pendingWindows;
    uint64_t created = 0;
    uint64_t destroyed = 0;
    uint64_t rejected = 0;
};
Runtime& runtime() {
    // A fork child gets fresh synchronization and counters; inherited native
    // handles are never destroyed or reused in the child.
    static std::atomic<Runtime*> state{new Runtime};
    auto* current = state.load(std::memory_order_acquire);
    if (current->processId != pid()) {
        auto* replacement = new Runtime;
        if (!state.compare_exchange_strong(current, replacement)) delete replacement;
        else current = replacement;
    }
    return *current;
}

// LWJGL's Vulkan backend compares its loader function pointer with SDL's
// SDL_Vulkan_GetVkGetInstanceProcAddr() result.  The Java class-loader and SDL
// video DSO may map this shim in different linker namespaces, so keep the
// address of the most recently loaded shim image observable.  The value is a
// diagnostic identity for the next SDL load; it does not grant admission or
// replace the owner table below.
#if defined(__GNUC__) && !defined(_WIN32)
__attribute__((constructor)) static void publishLoaderFunctionIdentity() {
    char value[64] = {0};
    std::snprintf(value, sizeof(value), "%llu",
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&vkGetInstanceProcAddr)));
    publishEnv("AMCL_VULKAN_WSI_GIPA", value);
}
#endif

// A JVM linker namespace can map this DSO twice. Publish one process-owner
// dispatch table, so every wrapper resolves back to the admitted host image.
struct OwnerApi {
    uint32_t version;
    uint32_t size;
    uint64_t processId;
    decltype(&amclVulkanAdmissionGranted) admitted;
    decltype(&amclVulkanSetLoader) loader;
    decltype(&amclVulkanGetInstanceProcAddr) getProc;
    decltype(&amclVulkanRequiredExtensions) extensions;
    decltype(&amclVulkanCreateSurface) create;
    decltype(&amclVulkanWindowHasLiveSurface) hasSurface;
    decltype(&amclVulkanGetStats) stats;
    decltype(&amclVulkanGetDeviceProcAddr) getDeviceProc;
};
OwnerApi& localApi() {
    static std::atomic<OwnerApi*> slot{new OwnerApi{2, sizeof(OwnerApi), pid(), &amclVulkanAdmissionGranted,
        &amclVulkanSetLoader, &amclVulkanGetInstanceProcAddr, &amclVulkanRequiredExtensions,
        &amclVulkanCreateSurface, &amclVulkanWindowHasLiveSurface, &amclVulkanGetStats,
        &amclVulkanGetDeviceProcAddr}};
    auto* api = slot.load(std::memory_order_acquire);
    if (api->processId != pid()) {
        auto* replacement = new OwnerApi(*api);
        replacement->processId = pid();
        if (!slot.compare_exchange_strong(api, replacement)) delete replacement;
        else api = replacement;
    }
    return *api;
}
const OwnerApi* remoteApi() {
    const char* value = std::getenv("AMCL_VULKAN_WSI_OWNER");
    if (!value || !*value) return nullptr;
    char* end = nullptr;
    const auto address = std::strtoull(value, &end, 10);
    if (!end || *end || !address) return nullptr;
    const auto* api = reinterpret_cast<const OwnerApi*>(static_cast<uintptr_t>(address));
    if (api == &localApi() || api->version != 2 || api->size < sizeof(OwnerApi) || api->processId != pid()) return nullptr;
    return api;
}
PFN_vkGetInstanceProcAddr systemLoader() {
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    if (r.injected) return r.injected;
    if (r.system) return r.system;
#ifdef _WIN32
    const auto library = LoadLibraryA("vulkan-1.dll");
    if (library) r.system = reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(library, "vkGetInstanceProcAddr"));
#else
    void* library = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) library = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (library) r.system = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(library, "vkGetInstanceProcAddr"));
#endif
    return r.system;
}

PFN_vkGetDeviceProcAddr deviceProcFor(VkDevice device) {
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    const auto found = r.devices.find(bits(device));
    return found == r.devices.end() ? r.deviceProc : found->second.getProc;
}

// WSI不再解析GLFW/SDL输入符号。成功呈现交给同PID的中立owner，由其先记录图形事实，
// 再向实际前端的输入订阅者分发。描述符只缓存进程期不可变表，fork拒绝父PID。
void notifyFramePresented(const char* provider, uint64_t window, uint64_t generation) {
    static std::atomic<const AmclGraphicsObserverV1*> cached{nullptr};
    const uint64_t currentPid = pid();
    const auto* observer = cached.load(std::memory_order_acquire);
    if (observer && observer->processId != currentPid) return;
    if (!observer) {
        const char* encoded = std::getenv(AMCL_GRAPHICS_OBSERVER_ENV);
        unsigned long long ownerPid = 0; void* address = nullptr; int consumed = 0;
        if (!encoded || std::sscanf(encoded, "1:%llu:%p%n", &ownerPid, &address, &consumed) != 2 ||
            encoded[consumed] || ownerPid != currentPid || !address) return;
        observer = static_cast<const AmclGraphicsObserverV1*>(address);
        if (observer->structSize < sizeof(*observer) || observer->abiVersion != 1 ||
            observer->processId != currentPid || !observer->dispatchPresent) return;
        cached.store(observer, std::memory_order_release);
    }
    observer->dispatchPresent(provider, window, generation);
}

VkInstance instanceForPhysical(VkPhysicalDevice physical) {
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    const auto found = r.physicalDevices.find(bits(physical));
    return found == r.physicalDevices.end() ? VK_NULL_HANDLE : found->second;
}

void rememberPhysicalDevices(VkInstance instance, uint32_t count, const VkPhysicalDevice* devices) {
    if (!devices) return;
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    for (uint32_t i = 0; i < count; ++i) r.physicalDevices[bits(devices[i])] = instance;
}

VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceProperties(VkPhysicalDevice physical,
    VkPhysicalDeviceProperties* properties) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_physical_properties begin physical=%llu",
        static_cast<unsigned long long>(bits(physical)));
    const VkInstance instance = instanceForPhysical(physical);
    auto gipa = systemLoader();
    auto raw = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
        gipa(instance, "vkGetPhysicalDeviceProperties")) : nullptr;
    if (raw) raw(physical, properties);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_physical_properties end physical=%llu proc=%p",
        static_cast<unsigned long long>(bits(physical)), reinterpret_cast<void*>(raw));
}

VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceMemoryProperties(VkPhysicalDevice physical,
    VkPhysicalDeviceMemoryProperties* properties) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_physical_memory begin physical=%llu",
        static_cast<unsigned long long>(bits(physical)));
    const VkInstance instance = instanceForPhysical(physical);
    auto gipa = systemLoader();
    auto raw = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        gipa(instance, "vkGetPhysicalDeviceMemoryProperties")) : nullptr;
    if (raw) raw(physical, properties);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_physical_memory end physical=%llu proc=%p",
        static_cast<unsigned long long>(bits(physical)), reinterpret_cast<void*>(raw));
}

VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceProperties2(VkPhysicalDevice physical,
    VkPhysicalDeviceProperties2* properties) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_physical_properties2 begin physical=%llu",
        static_cast<unsigned long long>(bits(physical)));
    const VkInstance instance = instanceForPhysical(physical);
    auto gipa = systemLoader();
    auto raw = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
        gipa(instance, "vkGetPhysicalDeviceProperties2")) : nullptr;
    if (raw) raw(physical, properties);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_physical_properties2 end physical=%llu proc=%p",
        static_cast<unsigned long long>(bits(physical)), reinterpret_cast<void*>(raw));
}

VKAPI_ATTR void VKAPI_CALL getPhysicalDeviceMemoryProperties2(VkPhysicalDevice physical,
    VkPhysicalDeviceMemoryProperties2* properties) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_physical_memory2 begin physical=%llu",
        static_cast<unsigned long long>(bits(physical)));
    const VkInstance instance = instanceForPhysical(physical);
    auto gipa = systemLoader();
    auto raw = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties2>(
        gipa(instance, "vkGetPhysicalDeviceMemoryProperties2")) : nullptr;
    if (raw) raw(physical, properties);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_physical_memory2 end physical=%llu proc=%p",
        static_cast<unsigned long long>(bits(physical)), reinterpret_cast<void*>(raw));
}

bool trackedSurfaceForDevice(VkDevice device, VkSurfaceKHR surface, VkPhysicalDevice& physical,
    VkInstance& instance) {
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    const auto deviceIt = r.devices.find(bits(device));
    if (deviceIt == r.devices.end()) return false;
    const auto surfaceIt = r.surfaces.find(bits(surface));
    if (surfaceIt == r.surfaces.end() || surfaceIt->second.instance != deviceIt->second.instance) return false;
    physical = deviceIt->second.physical;
    instance = deviceIt->second.instance;
    return true;
}

/** 创建前复制游戏请求并应用受管surface契约。输入请求始终只读，驱动查询失败原样返回；
 * adjusted只供本次vkCreateSwapchainKHR调用，pNext/oldSwapchain仍由游戏持有。
 * 本函数不创建或销毁GPU对象；方向不能成立时在驱动分配前拒绝，不影响旧交换链寿命。
 */
VkResult queryAndAdaptSwapchain(VkDevice device, const VkSwapchainCreateInfoKHR* requested,
    VkSwapchainCreateInfoKHR& adjusted, uint32_t& selectedAlpha, uint32_t& supportedAlpha) {
    if (!requested) return VK_ERROR_INITIALIZATION_FAILED;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkInstance instance = VK_NULL_HANDLE;
    if (!trackedSurfaceForDevice(device, requested->surface, physical, instance)) {
        // 非受管surface不具有Minecraft的窗口方向图像契约，其预旋转、尺寸和合成都透明转发。
        adjusted = *requested;
        selectedAlpha = requested->compositeAlpha;
        supportedAlpha = requested->compositeAlpha;
        return VK_SUCCESS;
    }
    auto gipa = systemLoader();
    auto getCaps = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        gipa(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) : nullptr;
    auto getFormats = gipa ? reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        gipa(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR")) : nullptr;
    if (!getCaps || !getFormats) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkSurfaceCapabilitiesKHR caps{};
    const VkResult capsResult = getCaps(physical, requested->surface, &caps);
    if (capsResult != VK_SUCCESS) return capsResult;
    // 受管surface只能由已准入的Minecraft requirement创建。26.2/26.3的实际上屏链提交
    // 未预旋转的窗口方向图像；每次重建都从新查询选择IDENTITY，不缓存显示旋转状态。
    const auto orientation = amcl::graphics::SelectMinecraftPresentationTransform(
        caps.supportedTransforms, caps.currentTransform);
    if (!orientation.ready()) {
        emitWsiLog(true, "graphics_swapchain_orientation_rejected reason=%s current=0x%X supported=0x%X requested=0x%X extent=%ux%u",
            orientation.reason, static_cast<unsigned>(caps.currentTransform), caps.supportedTransforms,
            static_cast<unsigned>(requested->preTransform), requested->imageExtent.width, requested->imageExtent.height);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    supportedAlpha = caps.supportedCompositeAlpha;
    selectedAlpha = amcl::graphics::SelectSwapchainCompositeAlpha(
        static_cast<uint32_t>(requested->compositeAlpha), supportedAlpha);
    if (selectedAlpha == 0u) return VK_ERROR_INITIALIZATION_FAILED;
    adjusted = *requested;
    adjusted.compositeAlpha = static_cast<VkCompositeAlphaFlagBitsKHR>(selectedAlpha);
    adjusted.preTransform = static_cast<VkSurfaceTransformFlagBitsKHR>(orientation.preTransform);
    // 只纠正图像的方向声明，不交换extent。游戏的离屏目标、blit区域、viewport和输入
    // 都使用同一窗口方向尺寸；单独转置分配尺寸会重新引入裁切、拉伸或尺寸反馈振荡。
    // 这是低频生命周期证据，release也保留，便于远程同时核对驱动事实与真正提交参数。
    emitWsiLog(false, "graphics_swapchain_orientation policy=window-oriented-identity current=0x%X supported=0x%X requested=0x%X selected=0x%X image=%ux%u surface=%ux%u",
        static_cast<unsigned>(caps.currentTransform), caps.supportedTransforms,
        static_cast<unsigned>(requested->preTransform), static_cast<unsigned>(adjusted.preTransform),
        adjusted.imageExtent.width, adjusted.imageExtent.height, caps.currentExtent.width, caps.currentExtent.height);
    if (selectedAlpha != static_cast<uint32_t>(requested->compositeAlpha)) {
        emitWsiLog(false, "graphics_swapchain_alpha_adapt requested=0x%X selected=0x%X supported=0x%X",
            static_cast<unsigned>(requested->compositeAlpha), selectedAlpha, supportedAlpha);
    }
    // 游戏仍负责最终格式和色彩空间选择；这里仅保留既有格式准入检查，不借方向修复改格式。
    uint32_t formatCount = 0;
    if (getFormats(physical, requested->surface, &formatCount, nullptr) != VK_SUCCESS || formatCount == 0) {
        return VK_ERROR_FORMAT_NOT_SUPPORTED;
    }
    std::vector<VkSurfaceFormatKHR> formats(formatCount);
    const VkResult formatResult = getFormats(physical, requested->surface, &formatCount, formats.data());
    bool formatFound = false;
    if (formatResult == VK_SUCCESS || formatResult == VK_INCOMPLETE) {
        for (uint32_t i = 0; i < formatCount; ++i) {
            if ((formats[i].format == VK_FORMAT_R8G8B8A8_UNORM || formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) &&
                formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) { formatFound = true; break; }
        }
    }
    return formatFound ? VK_SUCCESS : VK_ERROR_FORMAT_NOT_SUPPORTED;
}
bool validBroker(const AmclNativeWindowLeaseBrokerV2* b) {
    return b && b->abiVersion == AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION &&
        b->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE &&
        b->acquire && b->release && b->peekGeneration && b->claimPresentation && b->releasePresentation;
}
const AmclNativeWindowLeaseBrokerV2* publishedBroker() {
    const char* text = std::getenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
    if (!text || !*text) return nullptr;
    unsigned version = 0;
    void* address = nullptr;
    int consumed = 0;
    if (std::sscanf(text, "%u:%p%n", &version, &address, &consumed) != 2 ||
        text[consumed] != '\0' || version != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION || !address) return nullptr;
    return static_cast<const AmclNativeWindowLeaseBrokerV2*>(address);
}

void release(const SurfaceRecord& record) {
    if (record.broker->releasePresentation(record.token) != 1) {
        auto& r = runtime();
        std::lock_guard<std::mutex> lock(r.mutex);
        r.quarantined.push_back(record);
        publishEnv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1");
        emitWsiLog(true, "graphics_surface_retirement_quarantined window=%llu token=%llu",
            static_cast<unsigned long long>(record.windowId), static_cast<unsigned long long>(record.token));
        return;
    }
    record.broker->release(record.nativeWindow);
}

VKAPI_ATTR VkResult VKAPI_CALL enumeratePhysicalDevices(VkInstance instance, uint32_t* count,
    VkPhysicalDevice* devices) {
    emitWsiLog(false, "graphics_vk_enumerate_physical begin instance=%llu query=%d",
        static_cast<unsigned long long>(bits(instance)), devices ? 0 : 1);
    auto gipa = systemLoader();
    auto raw = gipa ? reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(gipa(instance, "vkEnumeratePhysicalDevices")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_enumerate_physical missing_proc instance=%llu",
            static_cast<unsigned long long>(bits(instance)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(instance, count, devices);
    if (result == VK_SUCCESS && count && devices) rememberPhysicalDevices(instance, *count, devices);
    emitWsiLog(result == VK_SUCCESS ? false : true,
        "graphics_vk_enumerate_physical end result=%d count=%u",
        static_cast<int>(result), count ? *count : 0u);
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL createDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkDevice* device) {
    auto& r = runtime();
    VkInstance instance = VK_NULL_HANDLE;
    PFN_vkCreateDevice raw = nullptr;
    {
        std::lock_guard<std::mutex> lock(r.mutex);
        const auto it = r.physicalDevices.find(bits(physical));
        if (it != r.physicalDevices.end()) instance = it->second;
        raw = r.createDevice;
    }
    auto gipa = systemLoader();
    if (!raw && gipa && instance) raw = reinterpret_cast<PFN_vkCreateDevice>(gipa(instance, "vkCreateDevice"));
    emitWsiLog(false, "graphics_vk_create_device begin physical=%llu instance=%llu proc=%p queues=%u extensions=%u",
        static_cast<unsigned long long>(bits(physical)), static_cast<unsigned long long>(bits(instance)),
        reinterpret_cast<void*>(raw), info ? info->queueCreateInfoCount : 0u,
        info ? info->enabledExtensionCount : 0u);
    if (!raw) {
        emitWsiLog(true, "graphics_vk_create_device missing_proc physical=%llu",
            static_cast<unsigned long long>(bits(physical)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(physical, info, allocator, device);
    if (result == VK_SUCCESS && device && *device) {
        PFN_vkGetDeviceProcAddr gdpa = instance && gipa
            ? reinterpret_cast<PFN_vkGetDeviceProcAddr>(gipa(instance, "vkGetDeviceProcAddr")) : nullptr;
        std::lock_guard<std::mutex> lock(r.mutex);
        r.devices[bits(*device)] = DeviceRecord{physical, instance, gdpa};
    }
    emitWsiLog(result == VK_SUCCESS ? false : true,
        "graphics_vk_create_device end result=%d device=%llu",
        // 创建失败时输出句柄未定义；日志不读取残留值，也不改写API输出或错误码。
        static_cast<int>(result), static_cast<unsigned long long>(result == VK_SUCCESS && device && *device ? bits(*device) : 0));
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroyDevice(VkDevice device, const VkAllocationCallbacks* allocator) {
    auto& r = runtime();
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkDestroyDevice>(gdpa(device, "vkDestroyDevice")) : nullptr;
    if (raw) raw(device, allocator);
    std::lock_guard<std::mutex> lock(r.mutex);
    for (auto it = r.queues.begin(); it != r.queues.end();) {
        if (bits(it->second) == bits(device)) it = r.queues.erase(it); else ++it;
    }
    for (auto it = r.swapchains.begin(); it != r.swapchains.end();) {
        if (it->second.device == device) it = r.swapchains.erase(it); else ++it;
    }
    r.devices.erase(bits(device));
}

VKAPI_ATTR void VKAPI_CALL getDeviceQueue(VkDevice device, uint32_t family, uint32_t index, VkQueue* queue) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_device_queue begin device=%llu family=%u index=%u",
        static_cast<unsigned long long>(bits(device)), family, index);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkGetDeviceQueue>(gdpa(device, "vkGetDeviceQueue")) : nullptr;
    if (!raw) {
        if (queue) *queue = VK_NULL_HANDLE;
        emitWsiLog(true, "graphics_vk_get_device_queue missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return;
    }
    raw(device, family, index, queue);
    if (queue && *queue) { auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex); r.queues[bits(*queue)] = device; }
    AMCL_WSI_TRACE(false, "graphics_vk_get_device_queue end device=%llu queue=%llu",
        static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(queue && *queue ? bits(*queue) : 0));
}

VKAPI_ATTR VkResult VKAPI_CALL createSemaphore(VkDevice device, const VkSemaphoreCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkSemaphore* semaphore) {
    AMCL_WSI_TRACE(false, "graphics_vk_create_semaphore begin device=%llu",
        static_cast<unsigned long long>(bits(device)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkCreateSemaphore>(gdpa(device, "vkCreateSemaphore")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_create_semaphore missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, info, allocator, semaphore);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_create_semaphore end result=%d device=%llu semaphore=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(result == VK_SUCCESS && semaphore && *semaphore ? bits(*semaphore) : 0));
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroySemaphore(VkDevice device, VkSemaphore semaphore,
    const VkAllocationCallbacks* allocator) {
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkDestroySemaphore>(gdpa(device, "vkDestroySemaphore")) : nullptr;
    if (raw) raw(device, semaphore, allocator);
}

VKAPI_ATTR VkResult VKAPI_CALL createCommandPool(VkDevice device, const VkCommandPoolCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkCommandPool* pool) {
    AMCL_WSI_TRACE(false, "graphics_vk_create_command_pool begin device=%llu family=%u",
        static_cast<unsigned long long>(bits(device)), info ? info->queueFamilyIndex : 0u);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkCreateCommandPool>(gdpa(device, "vkCreateCommandPool")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_create_command_pool missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, info, allocator, pool);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_create_command_pool end result=%d device=%llu pool=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(result == VK_SUCCESS && pool && *pool ? bits(*pool) : 0));
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroyCommandPool(VkDevice device, VkCommandPool pool,
    const VkAllocationCallbacks* allocator) {
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkDestroyCommandPool>(gdpa(device, "vkDestroyCommandPool")) : nullptr;
    if (raw) raw(device, pool, allocator);
}

VKAPI_ATTR VkResult VKAPI_CALL allocateCommandBuffers(VkDevice device,
    const VkCommandBufferAllocateInfo* info, VkCommandBuffer* buffers) {
    AMCL_WSI_TRACE(false, "graphics_vk_allocate_command_buffers begin device=%llu count=%u",
        static_cast<unsigned long long>(bits(device)), info ? info->commandBufferCount : 0u);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkAllocateCommandBuffers>(gdpa(device, "vkAllocateCommandBuffers")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_allocate_command_buffers missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, info, buffers);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_allocate_command_buffers end result=%d device=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)));
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL createBuffer(VkDevice device, const VkBufferCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkBuffer* buffer) {
    AMCL_WSI_TRACE(false, "graphics_vk_create_buffer begin device=%llu size=%llu usage=0x%X",
        static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(info ? info->size : 0), info ? info->usage : 0u);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkCreateBuffer>(gdpa(device, "vkCreateBuffer")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_create_buffer missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, info, allocator, buffer);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_create_buffer end result=%d device=%llu buffer=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(result == VK_SUCCESS && buffer && *buffer ? bits(*buffer) : 0));
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroyBuffer(VkDevice device, VkBuffer buffer,
    const VkAllocationCallbacks* allocator) {
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkDestroyBuffer>(gdpa(device, "vkDestroyBuffer")) : nullptr;
    if (raw) raw(device, buffer, allocator);
}

VKAPI_ATTR void VKAPI_CALL getBufferMemoryRequirements(VkDevice device, VkBuffer buffer,
    VkMemoryRequirements* requirements) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_buffer_memory begin device=%llu buffer=%llu",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(buffer)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkGetBufferMemoryRequirements>(gdpa(device, "vkGetBufferMemoryRequirements")) : nullptr;
    if (raw) raw(device, buffer, requirements);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_buffer_memory end device=%llu buffer=%llu proc=%p",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(buffer)),
        reinterpret_cast<void*>(raw));
}

VKAPI_ATTR void VKAPI_CALL getBufferMemoryRequirements2(VkDevice device,
    const VkBufferMemoryRequirementsInfo2* info, VkMemoryRequirements2* requirements) {
    AMCL_WSI_TRACE(false, "graphics_vk_get_buffer_memory2 begin device=%llu",
        static_cast<unsigned long long>(bits(device)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkGetBufferMemoryRequirements2>(
        gdpa(device, "vkGetBufferMemoryRequirements2")) : nullptr;
    if (raw) raw(device, info, requirements);
    AMCL_WSI_TRACE(!raw, "graphics_vk_get_buffer_memory2 end device=%llu proc=%p",
        static_cast<unsigned long long>(bits(device)), reinterpret_cast<void*>(raw));
}

VKAPI_ATTR VkResult VKAPI_CALL allocateMemory(VkDevice device, const VkMemoryAllocateInfo* info,
    const VkAllocationCallbacks* allocator, VkDeviceMemory* memory) {
    AMCL_WSI_TRACE(false, "graphics_vk_allocate_memory begin device=%llu size=%llu type=%u",
        static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(info ? info->allocationSize : 0), info ? info->memoryTypeIndex : 0u);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkAllocateMemory>(gdpa(device, "vkAllocateMemory")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_allocate_memory missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, info, allocator, memory);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_allocate_memory end result=%d device=%llu memory=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(result == VK_SUCCESS && memory && *memory ? bits(*memory) : 0));
    return result;
}

VKAPI_ATTR void VKAPI_CALL freeMemory(VkDevice device, VkDeviceMemory memory,
    const VkAllocationCallbacks* allocator) {
    AMCL_WSI_TRACE(false, "graphics_vk_free_memory begin device=%llu memory=%llu",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(memory)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkFreeMemory>(gdpa(device, "vkFreeMemory")) : nullptr;
    if (raw) raw(device, memory, allocator);
    AMCL_WSI_TRACE(!raw, "graphics_vk_free_memory end device=%llu memory=%llu proc=%p",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(memory)),
        reinterpret_cast<void*>(raw));
}

VKAPI_ATTR VkResult VKAPI_CALL bindBufferMemory(VkDevice device, VkBuffer buffer,
    VkDeviceMemory memory, VkDeviceSize offset) {
    AMCL_WSI_TRACE(false, "graphics_vk_bind_buffer_memory begin device=%llu buffer=%llu memory=%llu",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(buffer)),
        static_cast<unsigned long long>(bits(memory)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkBindBufferMemory>(gdpa(device, "vkBindBufferMemory")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_bind_buffer_memory missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, buffer, memory, offset);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_bind_buffer_memory end result=%d device=%llu buffer=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(bits(buffer)));
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL bindBufferMemory2(VkDevice device, uint32_t bindInfoCount,
    const VkBindBufferMemoryInfo* bindInfos) {
    AMCL_WSI_TRACE(false, "graphics_vk_bind_buffer_memory2 begin device=%llu count=%u",
        static_cast<unsigned long long>(bits(device)), bindInfoCount);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkBindBufferMemory2>(gdpa(device, "vkBindBufferMemory2")) : nullptr;
    if (!raw && gdpa) {
        raw = reinterpret_cast<PFN_vkBindBufferMemory2>(gdpa(device, "vkBindBufferMemory2KHR"));
    }
    if (!raw) {
        emitWsiLog(true, "graphics_vk_bind_buffer_memory2 missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, bindInfoCount, bindInfos);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_bind_buffer_memory2 end result=%d device=%llu count=%u",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)), bindInfoCount);
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL bindImageMemory(VkDevice device, VkImage image,
    VkDeviceMemory memory, VkDeviceSize offset) {
    AMCL_WSI_TRACE(false, "graphics_vk_bind_image_memory begin device=%llu image=%llu memory=%llu",
        static_cast<unsigned long long>(bits(device)), static_cast<unsigned long long>(bits(image)),
        static_cast<unsigned long long>(bits(memory)));
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkBindImageMemory>(gdpa(device, "vkBindImageMemory")) : nullptr;
    if (!raw) {
        emitWsiLog(true, "graphics_vk_bind_image_memory missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, image, memory, offset);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_bind_image_memory end result=%d device=%llu image=%llu",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)),
        static_cast<unsigned long long>(bits(image)));
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL bindImageMemory2(VkDevice device, uint32_t bindInfoCount,
    const VkBindImageMemoryInfo* bindInfos) {
    AMCL_WSI_TRACE(false, "graphics_vk_bind_image_memory2 begin device=%llu count=%u",
        static_cast<unsigned long long>(bits(device)), bindInfoCount);
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkBindImageMemory2>(gdpa(device, "vkBindImageMemory2")) : nullptr;
    if (!raw && gdpa) {
        raw = reinterpret_cast<PFN_vkBindImageMemory2>(gdpa(device, "vkBindImageMemory2KHR"));
    }
    if (!raw) {
        emitWsiLog(true, "graphics_vk_bind_image_memory2 missing_proc device=%llu",
            static_cast<unsigned long long>(bits(device)));
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = raw(device, bindInfoCount, bindInfos);
    AMCL_WSI_TRACE(result != VK_SUCCESS,
        "graphics_vk_bind_image_memory2 end result=%d device=%llu count=%u",
        static_cast<int>(result), static_cast<unsigned long long>(bits(device)), bindInfoCount);
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL createSwapchain(VkDevice device, const VkSwapchainCreateInfoKHR* requested,
    const VkAllocationCallbacks* allocator, VkSwapchainKHR* swapchain) {
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkCreateSwapchainKHR>(gdpa(device, "vkCreateSwapchainKHR")) : nullptr;
    if (!raw) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkSwapchainCreateInfoKHR adjusted{};
    uint32_t selectedAlpha = 0, supportedAlpha = 0;
    const VkResult adaptation = queryAndAdaptSwapchain(device, requested, adjusted, selectedAlpha, supportedAlpha);
    if (adaptation != VK_SUCCESS) {
        emitWsiLog(true, "graphics_swapchain_rejected result=%d supportedAlpha=0x%X",
            static_cast<int>(adaptation), supportedAlpha);
        return adaptation;
    }
    const VkResult result = raw(device, requested ? &adjusted : requested, allocator, swapchain);
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    if (result == VK_SUCCESS) {
        ++r.swapchainsCreated;
        // 只有真实受管surface的swapchain才能形成宿主呈现事件；其他用户的Vulkan对象透明转发。
        const auto surface = requested ? r.surfaces.find(bits(requested->surface)) : r.surfaces.end();
        if (swapchain && *swapchain && surface != r.surfaces.end()) {
            const auto& owner = surface->second;
            r.swapchains[bits(*swapchain)] = {device, owner.windowId, owner.generation, owner.provider};
        }
    }
    emitWsiLog(result == VK_SUCCESS ? false : true,
        "graphics_swapchain_create result=%d swapchains=%llu alpha=0x%X supportedAlpha=0x%X",
        static_cast<int>(result), static_cast<unsigned long long>(r.swapchainsCreated), selectedAlpha, supportedAlpha);
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroySwapchain(VkDevice device, VkSwapchainKHR swapchain,
    const VkAllocationCallbacks* allocator) {
    auto gdpa = deviceProcFor(device);
    auto raw = gdpa ? reinterpret_cast<PFN_vkDestroySwapchainKHR>(gdpa(device, "vkDestroySwapchainKHR")) : nullptr;
    if (raw) raw(device, swapchain, allocator);
    auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
    r.swapchains.erase(bits(swapchain));
    ++r.swapchainsDestroyed;
}

VKAPI_ATTR VkResult VKAPI_CALL queuePresent(VkQueue queue, const VkPresentInfoKHR* info) {
    auto& r = runtime();
    VkDevice device = VK_NULL_HANDLE;
    { std::lock_guard<std::mutex> lock(r.mutex); const auto it = r.queues.find(bits(queue)); if (it != r.queues.end()) device = it->second; }
    auto gdpa = device ? deviceProcFor(device) : nullptr;
    auto raw = gdpa ? reinterpret_cast<PFN_vkQueuePresentKHR>(gdpa(device, "vkQueuePresentKHR")) : nullptr;
    if (!raw) return VK_ERROR_DEVICE_LOST;
    const VkResult result = raw(queue, info);
    uint64_t presentCount = 0;
    const bool presented = result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR;
    if (presented) {
        {
            std::lock_guard<std::mutex> lock(r.mutex);
            presentCount = ++r.presents;
        }
    }
    // 全局result可能描述多个swapchain中最严重的错误；pResults存在时逐项核实。
    // 本宿主只允许一个活动呈现窗口，一次调用对该窗口只发布一帧，不把失败项或未知对象计入。
    SwapchainRecord frame{};
    bool haveFrame = false;
    if (info && info->pSwapchains) {
        std::lock_guard<std::mutex> lock(r.mutex);
        for (uint32_t i = 0; i < info->swapchainCount; ++i) {
            const VkResult itemResult = info->pResults ? info->pResults[i] : result;
            if (itemResult != VK_SUCCESS && itemResult != VK_SUBOPTIMAL_KHR) continue;
            const auto found = r.swapchains.find(bits(info->pSwapchains[i]));
            if (found != r.swapchains.end() && found->second.device == device) {
                frame = found->second; haveFrame = true; break;
            }
        }
    }
    if (haveFrame) notifyFramePresented(frame.provider, frame.windowId, frame.generation);

    if (result != VK_SUCCESS || (presentCount != 0 && (presentCount % 300u) == 0u)) {
        emitWsiLog(result == VK_SUCCESS ? false : true, "graphics_queue_present result=%d presents=%llu",
            static_cast<int>(result), static_cast<unsigned long long>(presentCount));
    }
    return result;
}

VKAPI_ATTR void VKAPI_CALL destroySurface(VkInstance instance, VkSurfaceKHR surface,
                                          const VkAllocationCallbacks* allocator) {
    auto& r = runtime();
    SurfaceRecord record{};
    bool tracked = false;
    {
        std::lock_guard<std::mutex> lock(r.mutex);
        auto found = r.surfaces.find(bits(surface));
        if (found != r.surfaces.end()) {
            if (found->second.instance != instance || found->second.destroying) {
                ++r.rejected;
                emitWsiLog(true, "graphics_surface_destroy_rejected surface=%llu",
                    static_cast<unsigned long long>(bits(surface)));
                return;
            }
            found->second.destroying = true;
            record = found->second;
            tracked = true;
        }
    }
    if (!tracked) {
        // Surfaces created outside AMCL still obey the loader's normal ABI.
        auto gipa = systemLoader();
        auto destroy = gipa ? reinterpret_cast<PFN_vkDestroySurfaceKHR>(gipa(instance, "vkDestroySurfaceKHR")) : nullptr;
        if (destroy) destroy(instance, surface, allocator);
        return;
    }
    // Vulkan requires the caller to destroy its swapchains before this call.
    // No AMCL code destroys a device/swapchain, nor releases the native lease
    // while the driver is still tearing down the VkSurface.
    record.destroy(instance, surface, allocator);
    {
        std::lock_guard<std::mutex> lock(r.mutex);
        r.surfaces.erase(bits(surface));
        ++r.destroyed;
        emitWsiLog(false, "graphics_surface_retired window=%llu generation=%llu destroyed=%llu live=%zu",
            static_cast<unsigned long long>(record.windowId), static_cast<unsigned long long>(record.generation),
            static_cast<unsigned long long>(r.destroyed), r.surfaces.size());
    }
    release(record);
}

VkResult createSurface(VkInstance instance, uint64_t windowId,
    const AmclNativeWindowLeaseBrokerV2* broker, const SurfaceCreateInfo* requested,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* surface) {
    if (!surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = VK_NULL_HANDLE;
    auto& r = runtime();
    {
        std::lock_guard<std::mutex> lock(r.mutex);
        if (!r.admitted || !r.quarantined.empty() || !windowId || !validBroker(broker)) {
            ++r.rejected; return VK_ERROR_INITIALIZATION_FAILED;
        }
        ++r.creating;
        ++r.pendingWindows[windowId];
    }
    struct CreatingGuard {
        Runtime& r;
        uint64_t windowId;
        ~CreatingGuard() {
            std::lock_guard<std::mutex> lock(r.mutex);
            --r.creating;
            if (--r.pendingWindows[windowId] == 0) r.pendingWindows.erase(windowId);
        }
    } creating{r, windowId};
    auto gipa = systemLoader();
    auto create = gipa ? reinterpret_cast<CreateSurfaceFn>(gipa(instance, "vkCreateSurfaceOHOS")) : nullptr;
    auto destroy = gipa ? reinterpret_cast<PFN_vkDestroySurfaceKHR>(gipa(instance, "vkDestroySurfaceKHR")) : nullptr;
    if (!create || !destroy) return VK_ERROR_EXTENSION_NOT_PRESENT;
    void* nativeWindow = nullptr;
    int width = 0, height = 0;
    uint64_t generation = 0;
    const int acquired = broker->acquire(nullptr, 0, &nativeWindow, &width, &height, &generation);
    if (acquired != 1 || !nativeWindow || !generation || width <= 0 || height <= 0) {
        if (acquired == 1 && nativeWindow) broker->release(nativeWindow);
        return VK_ERROR_SURFACE_LOST_KHR;
    }
    uint64_t token = 0;
    if ((requested && requested->window != nativeWindow) ||
        !broker->claimPresentation(nativeWindow, generation, 2, &token)) {
        broker->release(nativeWindow);
        return VK_ERROR_NATIVE_WINDOW_IN_USE_KHR;
    }
    SurfaceRecord record{instance, VK_NULL_HANDLE, windowId, nativeWindow, generation, token, broker, destroy};
    record.provider = requested ? "SDL3" : "GLFW";
    SurfaceCreateInfo info{kSurfaceType, nullptr, 0, nativeWindow};
    if (requested) info = *requested;
    VkResult result = create(instance, &info, allocator, surface);
    if (result != VK_SUCCESS) {
        release(record);
        *surface = VK_NULL_HANDLE;
        return result;
    }
    record.surface = *surface;
    if (!*surface || broker->peekGeneration() != generation) {
        // The newly created handle has not escaped to the game. Roll it back
        // with the same allocator before returning SURFACE_LOST.
        if (*surface) destroy(instance, *surface, allocator);
        release(record);
        *surface = VK_NULL_HANDLE;
        return VK_ERROR_SURFACE_LOST_KHR;
    }
    {
        std::lock_guard<std::mutex> lock(r.mutex);
        r.surfaces.emplace(bits(*surface), record);
        ++r.created;
        emitWsiLog(false, "graphics_surface_created window=%llu generation=%llu created=%llu live=%zu",
            static_cast<unsigned long long>(windowId), static_cast<unsigned long long>(generation),
            static_cast<unsigned long long>(r.created), r.surfaces.size());
    }
    publishEnv("AMCL_GRAPHICS_ACTUAL_VULKAN", "YES");
#ifndef _WIN32
    Dl_info provider{};
    if (dladdr(reinterpret_cast<void*>(create), &provider) && provider.dli_fname) {
        publishEnv("AMCL_GRAPHICS_ACTUAL_PROVIDER", provider.dli_fname);
        emitWsiLog(false, "graphics_surface_provider path=%s api=VULKAN", provider.dli_fname);
    }
#endif
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL createOhosSurface(VkInstance instance, const SurfaceCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* surface) {
    if (!info || !info->window) return VK_ERROR_INITIALIZATION_FAILED;
    // SDL provides a native window, while GLFW supplies a stable window id.
    // A separate high-bit id domain avoids aliasing the GLFW lifetime counter.
    const uint64_t windowId = bits(info->window) | (uint64_t{1} << 63);
    return createSurface(instance, windowId, publishedBroker(), info, allocator, surface);
}
} // namespace

extern "C" AMCL_VK_EXPORT int amclVulkanSetAdmission(int admitted, const char* profile, const char* requirement) {
    auto& r = runtime();
    std::lock_guard<std::mutex> lock(r.mutex);
    if (r.creating || !r.surfaces.empty() || !r.quarantined.empty()) return 0;
    // WSI 只消费 canonical 注册表生成的审计身份；设备和窗口准入由上游实际探针完成。
    // 同源白名单避免新增世代只接通计划却被另一份手写列表挡住，未知身份仍不授权。
    const auto* metadata = amcl::graphics::FindGraphicsProfile("minecraft-vulkan");
    const bool auditedRequirement = metadata && requirement &&
        amcl::graphics::GraphicsProfileSupportsRequirement(*metadata, requirement);
    r.admitted = admitted && profile && std::strcmp(profile, "minecraft-vulkan") == 0 && auditedRequirement;
    const auto ownerAddress = std::to_string(reinterpret_cast<uintptr_t>(&localApi()));
    publishEnv("AMCL_VULKAN_WSI_OWNER", ownerAddress.c_str());
    emitWsiLog(false, "graphics_loader_admission admitted=%d profile=%s requirement=%s owner=%s gipa=%s",
        r.admitted ? 1 : 0, profile ? profile : "", requirement ? requirement : "",
        ownerAddress.c_str(), std::getenv("AMCL_VULKAN_WSI_GIPA") ? std::getenv("AMCL_VULKAN_WSI_GIPA") : "");
    return admitted ? (r.admitted ? 1 : 0) : 1;
}
extern "C" AMCL_VK_EXPORT int amclVulkanAdmissionGranted() {
    if (auto* api = remoteApi()) return api->admitted();
    auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
    return r.admitted && r.quarantined.empty() ? 1 : 0;
}
extern "C" AMCL_VK_EXPORT int amclVulkanSetLoader(void* loader) {
    auto fn = reinterpret_cast<PFN_vkGetInstanceProcAddr>(loader);
    if (fn == &vkGetInstanceProcAddr || loader == reinterpret_cast<void*>(&amclVulkanGetInstanceProcAddr)) return 1;
    if (auto* api = remoteApi()) return api->loader(loader);
    // A copy in another linker namespace resolves its own GIPA through our
    // owner table. Recognize that alias before accepting an injected driver;
    // retaining it as the underlying loader would create recursive dispatch.
    if (fn && fn(VK_NULL_HANDLE, "vkGetInstanceProcAddr") ==
        reinterpret_cast<PFN_vkVoidFunction>(&vkGetInstanceProcAddr)) return 1;
    auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
    if (r.creating || !r.surfaces.empty() || !r.quarantined.empty()) return fn == r.injected ? 1 : 0;
    r.injected = fn;
    return 1;
}
extern "C" AMCL_VK_EXPORT void* amclVulkanGetInstanceProcAddr(void* instance, const char* name) {
    if (auto* api = remoteApi()) return api->getProc(instance, name);
    if (!name) return nullptr;
    const bool traceResolution = std::strcmp(name, "vkCreateInstance") == 0
        || std::strcmp(name, "vkEnumeratePhysicalDevices") == 0
        || std::strcmp(name, "vkCreateDevice") == 0
        || std::strcmp(name, "vkGetDeviceProcAddr") == 0
        || std::strcmp(name, "vkCreateSurfaceOHOS") == 0;
    if (std::strcmp(name, "vkGetInstanceProcAddr") == 0) return reinterpret_cast<void*>(&vkGetInstanceProcAddr);
    auto gipa = systemLoader();
    auto address = gipa ? gipa(reinterpret_cast<VkInstance>(instance), name) : nullptr;
    if (traceResolution) {
        AMCL_WSI_TRACE(!address, "graphics_vk_resolve name=%s instance=%llu address=%p",
            name, static_cast<unsigned long long>(bits(reinterpret_cast<VkInstance>(instance))),
            address);
    }
    if (!address) return nullptr;
    if (std::strcmp(name, "vkEnumeratePhysicalDevices") == 0) return reinterpret_cast<void*>(&enumeratePhysicalDevices);
    if (std::strcmp(name, "vkCreateDevice") == 0) {
        auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
        r.createDevice = reinterpret_cast<PFN_vkCreateDevice>(address);
        return reinterpret_cast<void*>(&createDevice);
    }
    if (std::strcmp(name, "vkGetDeviceProcAddr") == 0) {
        auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
        r.deviceProc = reinterpret_cast<PFN_vkGetDeviceProcAddr>(address);
        return reinterpret_cast<void*>(&vkGetDeviceProcAddr);
    }
    if (std::strcmp(name, "vkGetPhysicalDeviceProperties") == 0)
        return reinterpret_cast<void*>(&getPhysicalDeviceProperties);
    if (std::strcmp(name, "vkGetPhysicalDeviceMemoryProperties") == 0)
        return reinterpret_cast<void*>(&getPhysicalDeviceMemoryProperties);
    if (std::strcmp(name, "vkGetPhysicalDeviceProperties2") == 0)
        return reinterpret_cast<void*>(&getPhysicalDeviceProperties2);
    if (std::strcmp(name, "vkGetPhysicalDeviceMemoryProperties2") == 0)
        return reinterpret_cast<void*>(&getPhysicalDeviceMemoryProperties2);
    if (std::strcmp(name, "vkDestroySurfaceKHR") == 0) return reinterpret_cast<void*>(&destroySurface);
    if (std::strcmp(name, "vkCreateSurfaceOHOS") == 0) return reinterpret_cast<void*>(&createOhosSurface);
    return reinterpret_cast<void*>(address);
}
extern "C" AMCL_VK_EXPORT void* amclVulkanGetDeviceProcAddr(void* device, const char* name) {
    if (auto* api = remoteApi()) return api->getDeviceProc(device, name);
    if (!name) return nullptr;
    const bool traceResolution = std::strcmp(name, "vkGetDeviceQueue") == 0
        || std::strcmp(name, "vkCreateSwapchainKHR") == 0
        || std::strcmp(name, "vkQueuePresentKHR") == 0
        || std::strcmp(name, "vkDestroyDevice") == 0;
    uint64_t lookup = 0;
    {
        auto& r = runtime();
        std::lock_guard<std::mutex> lock(r.mutex);
        lookup = ++r.deviceProcLookups;
    }
    const bool traceMilestone = lookup <= 32u || (lookup % 64u) == 0u;
    if (traceMilestone) {
        AMCL_WSI_TRACE(false, "graphics_vk_resolve_device begin seq=%llu name=%s device=%llu",
            static_cast<unsigned long long>(lookup), name,
            static_cast<unsigned long long>(bits(reinterpret_cast<VkDevice>(device))));
    }
    auto gdpa = deviceProcFor(reinterpret_cast<VkDevice>(device));
    auto address = gdpa ? gdpa(reinterpret_cast<VkDevice>(device), name) : nullptr;
    if (traceResolution || traceMilestone) {
        AMCL_WSI_TRACE(!address, "graphics_vk_resolve_device name=%s device=%llu address=%p",
            name, static_cast<unsigned long long>(bits(reinterpret_cast<VkDevice>(device))), address);
    }
    if (!address) return nullptr;
    if (std::strcmp(name, "vkDestroyDevice") == 0) return reinterpret_cast<void*>(&destroyDevice);
    if (std::strcmp(name, "vkGetDeviceQueue") == 0) return reinterpret_cast<void*>(&getDeviceQueue);
    if (std::strcmp(name, "vkCreateSemaphore") == 0) return reinterpret_cast<void*>(&createSemaphore);
    if (std::strcmp(name, "vkDestroySemaphore") == 0) return reinterpret_cast<void*>(&destroySemaphore);
    if (std::strcmp(name, "vkCreateCommandPool") == 0) return reinterpret_cast<void*>(&createCommandPool);
    if (std::strcmp(name, "vkDestroyCommandPool") == 0) return reinterpret_cast<void*>(&destroyCommandPool);
    if (std::strcmp(name, "vkAllocateCommandBuffers") == 0) return reinterpret_cast<void*>(&allocateCommandBuffers);
    if (std::strcmp(name, "vkCreateBuffer") == 0) return reinterpret_cast<void*>(&createBuffer);
    if (std::strcmp(name, "vkDestroyBuffer") == 0) return reinterpret_cast<void*>(&destroyBuffer);
    if (std::strcmp(name, "vkGetBufferMemoryRequirements") == 0) return reinterpret_cast<void*>(&getBufferMemoryRequirements);
    if (std::strcmp(name, "vkGetBufferMemoryRequirements2") == 0)
        return reinterpret_cast<void*>(&getBufferMemoryRequirements2);
    if (std::strcmp(name, "vkGetBufferMemoryRequirements2KHR") == 0)
        return reinterpret_cast<void*>(&getBufferMemoryRequirements2);
    if (std::strcmp(name, "vkAllocateMemory") == 0) return reinterpret_cast<void*>(&allocateMemory);
    if (std::strcmp(name, "vkFreeMemory") == 0) return reinterpret_cast<void*>(&freeMemory);
    if (std::strcmp(name, "vkBindBufferMemory") == 0) return reinterpret_cast<void*>(&bindBufferMemory);
    if (std::strcmp(name, "vkBindBufferMemory2") == 0 ||
        std::strcmp(name, "vkBindBufferMemory2KHR") == 0) {
        return reinterpret_cast<void*>(&bindBufferMemory2);
    }
    if (std::strcmp(name, "vkBindImageMemory") == 0) return reinterpret_cast<void*>(&bindImageMemory);
    if (std::strcmp(name, "vkBindImageMemory2") == 0 ||
        std::strcmp(name, "vkBindImageMemory2KHR") == 0) {
        return reinterpret_cast<void*>(&bindImageMemory2);
    }
    if (std::strcmp(name, "vkCreateSwapchainKHR") == 0) return reinterpret_cast<void*>(&createSwapchain);
    if (std::strcmp(name, "vkDestroySwapchainKHR") == 0) return reinterpret_cast<void*>(&destroySwapchain);
    if (std::strcmp(name, "vkQueuePresentKHR") == 0) return reinterpret_cast<void*>(&queuePresent);
    return reinterpret_cast<void*>(address);
}
extern "C" AMCL_VK_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char* name) {
    return reinterpret_cast<PFN_vkVoidFunction>(amclVulkanGetInstanceProcAddr(instance, name));
}
extern "C" AMCL_VK_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(VkDevice device, const char* name) {
    return reinterpret_cast<PFN_vkVoidFunction>(amclVulkanGetDeviceProcAddr(device, name));
}
extern "C" AMCL_VK_EXPORT const char* const* amclVulkanRequiredExtensions(uint32_t* count) {
    if (auto* api = remoteApi()) return api->extensions(count);
    if (count) *count = 0;
    auto gipa = systemLoader();
    auto enumerate = gipa ? reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(gipa(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties")) : nullptr;
    if (!enumerate) return nullptr;
    for (int attempt = 0; attempt < 3; ++attempt) {
        uint32_t size = 0;
        if (enumerate(nullptr, &size, nullptr) != VK_SUCCESS || size > 4096) return nullptr;
        std::vector<VkExtensionProperties> properties(size);
        auto result = enumerate(nullptr, &size, properties.data());
        if (result == VK_INCOMPLETE) continue;
        if (result != VK_SUCCESS) return nullptr;
        bool khr = false, ohos = false;
        for (uint32_t i = 0; i < size; ++i) {
            khr |= std::strcmp(properties[i].extensionName, "VK_KHR_surface") == 0;
            ohos |= std::strcmp(properties[i].extensionName, "VK_OHOS_surface") == 0;
        }
        if (!khr || !ohos) return nullptr;
        static const char* const extensions[]{"VK_KHR_surface", "VK_OHOS_surface"};
        if (count) *count = 2;
        return extensions;
    }
    return nullptr;
}
extern "C" AMCL_VK_EXPORT int amclVulkanCreateSurface(void* instance, uint64_t windowId,
    const AmclNativeWindowLeaseBrokerV2* broker, const void* allocator, uint64_t* surface) {
    if (auto* api = remoteApi()) return api->create(instance, windowId, broker, allocator, surface);
    if (!surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = 0;
    VkSurfaceKHR created = VK_NULL_HANDLE;
    const auto result = createSurface(reinterpret_cast<VkInstance>(instance), windowId, broker, nullptr,
        static_cast<const VkAllocationCallbacks*>(allocator), &created);
    if (result == VK_SUCCESS) *surface = bits(created);
    return result;
}
extern "C" AMCL_VK_EXPORT int amclVulkanWindowHasLiveSurface(uint64_t windowId) {
    if (auto* api = remoteApi()) return api->hasSurface(windowId);
    auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
    if (r.pendingWindows.count(windowId)) return 1;
    for (const auto& pair : r.surfaces) if (pair.second.windowId == windowId) return 1;
    for (const auto& record : r.quarantined) if (record.windowId == windowId) return 1;
    return 0;
}
extern "C" AMCL_VK_EXPORT int amclVulkanGetStats(AmclVulkanWsiStats* stats) {
    if (auto* api = remoteApi()) return api->stats(stats);
    if (!stats || stats->structSize < sizeof(AmclVulkanWsiStats)) return 0;
    auto& r = runtime(); std::lock_guard<std::mutex> lock(r.mutex);
    stats->created = r.created; stats->destroyed = r.destroyed;
    stats->live = r.surfaces.size(); stats->rejected = r.rejected;
    return 1;
}

// vulkan_probe.cpp — Vulkan 能力探针实现（VULKAN_ADAPTATION_PLAN.md Phase 0 + §十 能力门控）
//
// 全程 dlopen + vkGetInstanceProcAddr，libentry.so 不 NEEDED 链接 libvulkan.so。
// 只读：建最小 instance 查询后立即销毁，无全局副作用。
//
// 两个出口共享同一次扫描（scanVulkan）：
//   - getVulkanInfo()           → 人类可读报告（DevTools 展示 / hilog）
//   - getVulkanCapabilityJson() → 机器可读 JSON（ArkTS 选 26.2+ 时静默门控）
//
// 编译期防御：用 __has_include 守卫 OHOS NDK 的 vulkan 头。若 SDK 缺这两个头
// （理论上 API 10+ 都有），探针降级为返回 "unavailable"，不影响整个 libentry.so 编译。
//
// ─────────────────────────────────────────────────────────────────────────────
// 「更真实」的关键（2026-05 增强）：
//   旧版只检查 *扩展名是否出现在 vkEnumerateDeviceExtensionProperties 列表里*。
//   但扩展被「列出」≠ 对应 feature 真正「可用」。MC 官方 Vulkan 后端
//   （Vibrant Visuals）启用的是 dynamicRendering / synchronization2 这些 *feature
//   bit*，而非仅仅声明扩展。一个设备可能列出 VK_KHR_dynamic_rendering 却把
//   dynamicRendering 特性位报成 0（或反过来：core 1.3 设备根本不再单列该扩展，
//   但特性必然为真）。所以本版新增：
//     · vkGetPhysicalDeviceFeatures2 链式查询真实 feature bit（dynamicRendering /
//       synchronization2），门控以「特性位」为准；查不到按 UNKNOWN 拒绝。
//     · vkGetPhysicalDeviceProperties2 抓真实驱动信息（driverName / driverInfo /
//       conformanceVersion）与 push_descriptor 上限（maxPushDescriptors）。
//     · 设备本地显存、厂商名解码、十六进制 vendor/device ID、按评分挑「最佳」GPU。
//   这让报告接近桌面 vulkaninfo 的可信度，门控也不再「说能跑、实际一启用就崩」。
// ─────────────────────────────────────────────────────────────────────────────

#include "vulkan_probe.h"
#include "../utils/amcl_log.h"
#include "graphics_capability.h"
#include "vulkan_requirement_policy.h"
#include "mobilegl_capability.h"
#include "vulkan_surface_policy.h"
#include "glfw/glfw_compat.h"
#include "glfw/amcl_native_window_lease_broker_abi.h"

#include <hilog/log.h>
#include <dlfcn.h>
#include <string>
#include <sstream>
#include <vector>
#include <utility>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <unistd.h>
#include <thread>
#include <sys/stat.h>

#undef LOG_TAG
#define LOG_TAG "VK_PROBE"

#if defined(__has_include)
#  if __has_include(<vulkan/vulkan.h>)
#    define AMCL_HAVE_VULKAN_HEADERS 1
#  endif
#endif

#ifdef AMCL_HAVE_VULKAN_HEADERS
// 关键：VK_NO_PROTOTYPES 让头文件只给类型/枚举/struct，不声明全局函数符号。
// 所有 vk* 函数都通过 vkGetInstanceProcAddr 动态解析，因此 libentry.so 不会
// 产生对 libvulkan.so 的链接期依赖。
#  define VK_NO_PROTOTYPES 1
#  include <vulkan/vulkan.h>
#  if __has_include(<vulkan/vulkan_ohos.h>)
#    include <vulkan/vulkan_ohos.h>
#    define AMCL_HAVE_VULKAN_OHOS 1
// VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS 的数值常量。DevEco SDK 的 vulkan_ohos.h 有
// VkSurfaceCreateInfoOHOS 结构体，但其 vulkan_core.h 可能偏旧、缺该枚举常量 → 直接用符号会
// 编译报错。枚举无法 #ifdef 探测，故用数值字面量 cast（Khronos 注册表固定 1000685000，跨版本稳定）。
// 与 glfw/glfw_vulkan.cpp 同源处理。
static constexpr VkStructureType kStypeSurfaceCreateInfoOHOS =
    static_cast<VkStructureType>(1000685000);
#  endif
#endif

namespace {

// ============================================================
//  扫描结果（人类报告 + JSON 共享的单一事实源）
// ============================================================
struct VkScanResult {
    bool libLoaded = false;
    std::string loaderVersion;          // "1.3.275" / ""
    uint32_t loaderApiRaw = 0;
    bool hasKhrSurface = false;
    bool hasOhosSurface = false;
    bool hasGetPhysDevProps2 = false;   // 实例扩展，使 features2 在 1.0/1.1 loader 上也能用
    bool instanceCreated = false;

    bool hasDevice = false;
    uint32_t gpuCount = 0;
    std::string deviceName;
    std::string deviceType;             // "Integrated GPU" 等
    std::string deviceApiVersion;       // "1.2.275"
    uint32_t deviceApiRaw = 0;
    uint32_t driverVersionRaw = 0;
    uint32_t vendorID = 0;
    uint32_t deviceID = 0;
    std::string driverIdentity;
    std::string vendorName;             // 厂商 ID 解码（"Qualcomm" / "Huawei" ...）
    int graphicsFamily = -1;
    uint32_t queueFamilyCount = 0;
    uint32_t deviceExtCount = 0;
    bool deviceExtensionsQueried = false;
    uint64_t deviceLocalMemoryBytes = 0;
    uint32_t maxImageDimension2D = 0;

    // 真实驱动信息（VK_KHR_driver_properties / core 1.2）
    bool hasDriverProps = false;
    std::string driverName;             // 如 "Mali-G..." / "Turnip" / 华为闭源驱动名
    std::string driverInfo;
    std::string conformanceVersion;     // CTS 版本，如 "1.3.6.0"

    // ── 扩展「是否被列出」（字符串级别）──
    bool extSwapchain = false;
    bool extDynamicRendering = false;
    bool extSynchronization2 = false;
    bool extCreateRenderpass2 = false;
    bool extDescriptorIndexing = false;
    bool extMaintenance1 = false;
    bool extMaintenance2 = false;
    bool extPushDescriptor = false;
    bool extVertexAttributeDivisor = false; // MC 26.3 SDL3 Vulkan requirement

    // ── 能力「是否具备」（扩展被列出 OR 已晋升进 core）──
    bool hasSwapchain = false;
    bool hasDynamicRendering = false;
    bool hasSynchronization2 = false;
    bool hasCreateRenderpass2 = false;
    bool hasDescriptorIndexing = false;
    bool hasMaintenance1 = false;
    bool hasMaintenance2 = false;
    bool hasPushDescriptor = false;     // VK_KHR_push_descriptor（1.4 进 core）— MC 26.2 硬需求
    bool hasVertexAttributeDivisor = false;

    // ── 真实 feature bit（vkGetPhysicalDeviceFeatures2 查询，最可信）──
    bool featuresQueried = false;       // 能否成功调用 features2（决定门控是否采信特性位）
    bool featDynamicRendering = false;  // VkPhysicalDeviceDynamicRenderingFeatures.dynamicRendering
    bool featSynchronization2 = false;  // VkPhysicalDeviceSynchronization2Features.synchronization2
    uint32_t maxPushDescriptors = 0;    // VkPhysicalDevicePushDescriptorProperties.maxPushDescriptors
    bool featShaderDrawParameters = false;
    bool featTimelineSemaphore = false;
    bool featHostQueryReset = false;
    bool featVertexAttributeInstanceRateDivisor = false;

    // ── Zink (GL-on-Vulkan) / Voxy 可行性相关：核心 VkPhysicalDeviceFeatures 位 ──
    // Mesa Zink 暴露的 GL 版本取决于这些 feature 是否齐备；Voxy 又额外吃 compute/SSBO/indirect。
    // 移动 GPU 常缺 geometryShader / tessellationShader / logicOp / 64 位浮点等 → 决定 Zink 能否到 GL 4.6。
    bool baseFeaturesQueried = false;
    bool fGeometryShader = false;            // GL 3.2 几何着色器（Zink GL 等级关键）
    bool fTessellationShader = false;        // GL 4.0 曲面细分（Zink GL 等级关键）
    bool fMultiDrawIndirect = false;         // GL 4.x 多重间接绘制（Voxy 用）
    bool fDrawIndirectFirstInstance = false; // 间接绘制 baseInstance（Voxy 用）
    bool fFragmentStoresAndAtomics = false;  // 片段着色器 SSBO 写/原子（Zink GL 4.2+ / Voxy）
    bool fVertexPipelineStoresAndAtomics = false;
    bool fShaderStorageImageExtendedFormats = false;
    bool fShaderInt64 = false;
    bool fShaderFloat64 = false;             // GL 4.x double（Zink 报 4.x 常需）
    bool fFillModeNonSolid = false;          // glPolygonMode 线框（桌面 GL 必备，Zink 需要）
    bool fLogicOp = false;                   // glLogicOp（桌面 GL；GLES 无 → 区分桌面/移动）
    bool fImageCubeArray = false;
    bool fIndependentBlend = false;
    bool fDualSrcBlend = false;
    bool fSampleRateShading = false;
    bool fShaderClipDistance = false;
    bool fShaderCullDistance = false;
    bool fSamplerAnisotropy = false;
    bool fTextureCompressionBC = false;      // 桌面 BC/DXT 压缩纹理（很多 GL 内容用）
    bool fTextureCompressionETC2 = false;    // 移动常见
    bool fWideLines = false;
    bool fDepthClamp = false;
    bool fOcclusionQueryPrecise = false;
    bool fShaderStorageImageReadWithoutFormat = false;
    bool fShaderStorageImageWriteWithoutFormat = false;
    // 计算/SSBO 相关 limits（Voxy 的体素化/LOD 走 compute）
    uint32_t maxComputeSharedMemorySize = 0;
    uint32_t maxComputeWorkGroupInvocations = 0;
    uint32_t maxPerStageDescriptorStorageBuffers = 0;
    uint32_t maxStorageBufferRangeMB = 0;

    std::string error;                  // 致命错误时填（loader/instance 失败）
    amcl::graphics::CapabilityEvidence surfaceEvidence = amcl::graphics::CapabilityEvidence::NotRun;
    amcl::graphics::CapabilityEvidence presentEvidence = amcl::graphics::CapabilityEvidence::NotRun;
    // 方向准入独立于queue-present和SDL格式契约，两代客户端都必须真实查询后才能通过。
    amcl::graphics::CapabilityEvidence surfaceOrientationEvidence = amcl::graphics::CapabilityEvidence::NotRun;
    uint64_t surfaceGeneration = 0;
    std::string surfaceReason;
    std::string surfaceContractDetail;
    bool surfaceContractQueried = false;
    bool sdlSurfaceContract = false;
};

#ifdef AMCL_HAVE_VULKAN_HEADERS

// MC 官方 Vulkan 后端（Vibrant Visuals）目标 core 版本下限。详见
// docs/adaptation/VULKAN_ADAPTATION_PLAN.md §2.1 / §六待核实事实清单第 3 条。
constexpr uint32_t kMcTargetApi = VK_API_VERSION_1_2;

std::string apiVersionToString(uint32_t v) {
    std::ostringstream ss;
    ss << VK_API_VERSION_MAJOR(v) << "." << VK_API_VERSION_MINOR(v) << "."
       << VK_API_VERSION_PATCH(v);
    return ss.str();
}

const char* deviceTypeToString(VkPhysicalDeviceType t) {
    switch (t) {
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "Integrated GPU";
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "Discrete GPU";
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "Virtual GPU";
        case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "CPU";
        default:                                     return "Other";
    }
}

// PCI / Khronos 注册的厂商 ID 解码（移动端常见项 + 桌面）。未知则回退十六进制。
std::string vendorIdToName(uint32_t id) {
    switch (id) {
        case 0x1002: return "AMD";
        case 0x10DE: return "NVIDIA";
        case 0x8086: return "Intel";
        case 0x13B5: return "ARM";        // Mali
        case 0x5143: return "Qualcomm";   // Adreno
        case 0x1010: return "ImgTec";     // PowerVR
        case 0x19E5: return "Huawei";     // HiSilicon / Maleoon
        case 0x14E4: return "Broadcom";
        case 0x1AEE: return "Imagination";
        default: {
            char buf[16];
            std::snprintf(buf, sizeof(buf), "0x%04X", id);
            return std::string(buf);
        }
    }
}

std::string toHex(uint32_t v) {
    char buf[16];
    std::snprintf(buf, sizeof(buf), "0x%X", v);
    return std::string(buf);
}

// driverVersion 是厂商私有编码；这里给出常见两种解读以辅助人读（不参与门控）。
std::string driverVersionToString(uint32_t v, uint32_t vendorID) {
    std::ostringstream ss;
    ss << "raw=" << v << " (" << toHex(v) << ")";
    // NVIDIA 专有打包
    if (vendorID == 0x10DE) {
        ss << "  ≈ " << ((v >> 22) & 0x3FF) << "." << ((v >> 14) & 0xFF)
           << "." << ((v >> 6) & 0xFF);
    } else {
        // 其它厂商多数沿用 Vulkan 版本三段式打包
        ss << "  ≈ " << VK_API_VERSION_MAJOR(v) << "." << VK_API_VERSION_MINOR(v)
           << "." << VK_API_VERSION_PATCH(v);
    }
    return ss.str();
}

// 在临时呈现token内查询真实surface/queue/方向能力，结果仅属于当前窗口代际。
// 不借用游戏grant，游戏占用窗口时拒绝；任何查询失败都经过末尾surface/token/租约清理。
void probeQueuePresentation(VkInstance instance, VkPhysicalDevice gpu,
    PFN_vkGetInstanceProcAddr getProc, VkScanResult& result) {
    using amcl::graphics::CapabilityEvidence;
#ifdef AMCL_HAVE_VULKAN_OHOS
    void* window = nullptr;
    void* brokerPointer = nullptr;
    int width = 0;
    int height = 0;
    uint64_t generation = 0;
    if (glfwOHOS_AcquireNativeWindowSnapshot(nullptr, 0, nullptr, &window,
            &width, &height, &generation, &brokerPointer) != 1 || !window || !brokerPointer) {
        result.surfaceReason = "native_window_not_ready";
        return;
    }
    auto* broker = static_cast<AmclNativeWindowLeaseBrokerV2*>(brokerPointer);
    uint64_t presentationToken = 0;
    const bool brokerReady = broker->abiVersion == AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION &&
        broker->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE &&
        broker->claimPresentation && broker->releasePresentation && broker->peekGeneration;
    if (!brokerReady || broker->claimPresentation(window, generation, 2, &presentationToken) != 1) {
        glfwOHOS_ReleaseNativeWindowLease(window, brokerPointer);
        result.surfaceReason = "native_window_presentation_owner_busy_or_abi_missing";
        return;
    }
    auto createSurface = reinterpret_cast<PFN_vkCreateSurfaceOHOS>(getProc(instance, "vkCreateSurfaceOHOS"));
    auto destroySurface = reinterpret_cast<PFN_vkDestroySurfaceKHR>(getProc(instance, "vkDestroySurfaceKHR"));
    auto getSupport = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(getProc(instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    auto getQueues = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(getProc(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    if (!createSurface || !destroySurface || !getSupport || !getQueues) {
        result.surfaceEvidence = CapabilityEvidence::No;
        result.surfaceReason = "surface_entrypoint_missing";
    } else {
        VkSurfaceCreateInfoOHOS info{};
        info.sType = kStypeSurfaceCreateInfoOHOS;
        info.window = static_cast<OHNativeWindow*>(window);
        const VkResult status = createSurface(instance, &info, nullptr, &surface);
        if (status == VK_SUCCESS && surface != VK_NULL_HANDLE) {
            result.surfaceEvidence = CapabilityEvidence::Yes;
            result.surfaceGeneration = generation;
            result.presentEvidence = CapabilityEvidence::No;
            uint32_t count = 0;
            getQueues(gpu, &count, nullptr);
            std::vector<VkQueueFamilyProperties> families(count);
            if (count > 0) getQueues(gpu, &count, families.data());
            for (uint32_t index = 0; index < count; ++index) {
                VkBool32 supported = VK_FALSE;
                if (families[index].queueCount > 0 && (families[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
                    getSupport(gpu, index, surface, &supported) == VK_SUCCESS && supported == VK_TRUE) {
                    result.presentEvidence = CapabilityEvidence::Yes;
                    break;
                }
            }
            // 26.2 GLFW和26.3 SDL都提交窗口方向图像。先单独核对方向能力，再检查
            // SDL特有的格式/usage/图像数；queue可呈现不等于像素方向正确。
            auto getFormats = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
                getProc(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
            auto getCapabilities = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
                getProc(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
            auto getPresentModes = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
                getProc(instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));
            VkSurfaceCapabilitiesKHR capabilities{};
            const VkResult capabilityStatus = getCapabilities ? getCapabilities(gpu, surface, &capabilities)
                : VK_ERROR_EXTENSION_NOT_PRESENT;
            if (capabilityStatus == VK_SUCCESS) {
                const auto orientation = amcl::graphics::SelectMinecraftPresentationTransform(
                    capabilities.supportedTransforms, capabilities.currentTransform);
                result.surfaceOrientationEvidence = orientation.ready() ? CapabilityEvidence::Yes : CapabilityEvidence::No;
                if (!orientation.ready()) result.surfaceReason = orientation.reason;
            } else {
                // 查询缺失/失败不得借queue阳性补齐方向证据；仍走末尾既有surface/token清理。
                result.surfaceOrientationEvidence = CapabilityEvidence::Unknown;
                result.surfaceReason = getCapabilities ? "native_vulkan_surface_capabilities_query_failed_" +
                    std::to_string(static_cast<int>(capabilityStatus)) : "native_vulkan_surface_capabilities_missing";
            }
            if (getFormats && capabilityStatus == VK_SUCCESS && getPresentModes) {
                uint32_t formatCount = 0;
                uint32_t modeCount = 0;
                const VkResult formatStatus = getFormats(gpu, surface, &formatCount, nullptr);
                const VkResult modeStatus = getPresentModes(gpu, surface, &modeCount, nullptr);
                std::vector<VkSurfaceFormatKHR> formats(formatCount);
                VkResult formatsReadStatus = formatStatus;
                if (formatStatus == VK_SUCCESS && formatCount > 0) {
                    formatsReadStatus = getFormats(gpu, surface, &formatCount, formats.data());
                }
                if ((formatsReadStatus == VK_SUCCESS || formatsReadStatus == VK_INCOMPLETE) &&
                    (modeStatus == VK_SUCCESS || modeStatus == VK_INCOMPLETE)
                    && modeCount > 0u) {
                    bool acceptedFormat = false;
                    for (uint32_t formatIndex = 0; formatIndex < formatCount && formatIndex < formats.size(); ++formatIndex) {
                        const int rawFormat = static_cast<int>(formats[formatIndex].format);
                        const int rawColorSpace = static_cast<int>(formats[formatIndex].colorSpace);
                        if ((rawFormat == 37 || rawFormat == 44) && rawColorSpace == 0) {
                            acceptedFormat = true;
                            break;
                        }
                    }
                    // 只传入实际查询值，surface策略同时约束方向、alpha及SDL请求。
                    // 与swapchain适配共用IDENTITY选择，不再复制另一份transform布尔表达式。
                    result.surfaceContractQueried = true;
                    const auto contract = amcl::graphics::EvaluateMinecraftSdlSurface({capabilities.minImageCount,
                        capabilities.maxImageCount, capabilities.supportedUsageFlags, capabilities.supportedCompositeAlpha,
                        capabilities.supportedTransforms, static_cast<uint32_t>(capabilities.currentTransform), acceptedFormat, true});
                    result.surfaceContractDetail = "format=" + std::string(contract.format ? "YES" : "NO")
                        + ",imageCount=" + std::string(contract.imageCount ? "YES" : "NO")
                        + ",usage=" + std::string(contract.usage ? "YES" : "NO")
                        + ",alpha=" + std::string(contract.alpha ? "YES" : "NO")
                        + ",transform=" + std::string(contract.transform ? "YES" : "NO")
                        + ",min=" + std::to_string(capabilities.minImageCount)
                        + ",max=" + std::to_string(capabilities.maxImageCount)
                        + ",requested=" + std::to_string(contract.requestedImages)
                        + ",alphaMask=" + toHex(capabilities.supportedCompositeAlpha)
                        + ",selectedAlpha=" + toHex(contract.selectedAlpha)
                        + ",usageMask=" + toHex(capabilities.supportedUsageFlags)
                        + ",currentTransform=" + toHex(capabilities.currentTransform)
                        + ",transformMask=" + toHex(capabilities.supportedTransforms)
                        + ",selectedPreTransform=" + toHex(contract.selectedPreTransform);
                    result.sdlSurfaceContract = contract.ready();
                    if (!result.sdlSurfaceContract && result.surfaceReason.empty()) {
                        result.surfaceReason = "sdl_surface_contract_mismatch:" + result.surfaceContractDetail;
                    }
                }
            }
            if (result.surfaceReason.empty()) {
                result.surfaceReason = result.presentEvidence == CapabilityEvidence::Yes ? "surface_queue_verified" : "graphics_present_queue_missing";
            }
        } else {
            result.surfaceEvidence = CapabilityEvidence::No;
            result.surfaceReason = "surface_create_failed_" + std::to_string(static_cast<int>(status));
        }
    }
    if (surface != VK_NULL_HANDLE && destroySurface) destroySurface(instance, surface, nullptr);
    if (broker->peekGeneration() != generation) {
        result.surfaceEvidence = CapabilityEvidence::Unknown;
        result.presentEvidence = CapabilityEvidence::Unknown;
        result.surfaceOrientationEvidence = CapabilityEvidence::Unknown;
        result.surfaceReason = "native_window_generation_changed_during_probe";
    }
    broker->releasePresentation(presentationToken);
    glfwOHOS_ReleaseNativeWindowLease(window, brokerPointer);
#else
    result.surfaceReason = "ohos_surface_headers_unavailable";
#endif
}

// Ordinary diagnostics only query an instance. Explicit admission also creates
// a temporary surface and retires it before returning the evidence.
VkScanResult scanVulkan(std::ostringstream* humanLog, bool probePresentation = false,
    uint32_t minimumApi = kMcTargetApi, const std::string& providerRenderer = "") {
    VkScanResult r;
    auto log = [&](const std::string& s) { if (humanLog) (*humanLog) << s; };

    // 1) 加载系统 libvulkan.so（OHOS 系统库名无 .1 后缀，与 LWJGL 默认的
    //    libvulkan.so.1 不同——这正是 mc_output.log 那条 WARN 的根因）。
    void* lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        r.error = "dlopen(libvulkan.so) 失败：本机无 Vulkan loader";
        log("❌ " + r.error + "\n");
        return r;
    }
    r.libLoaded = true;
    log("✅ libvulkan.so 已加载\n");

    auto pfnGetInstanceProcAddr =
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(lib, "vkGetInstanceProcAddr"));
    if (!pfnGetInstanceProcAddr) {
        r.error = "dlsym(vkGetInstanceProcAddr) 失败";
        log("❌ " + r.error + "\n");
        dlclose(lib);
        return r;
    }

    auto pfnEnumerateInstanceVersion = reinterpret_cast<PFN_vkEnumerateInstanceVersion>(
        pfnGetInstanceProcAddr(VK_NULL_HANDLE, "vkEnumerateInstanceVersion"));
    auto pfnEnumerateInstanceExtensionProperties =
        reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
            pfnGetInstanceProcAddr(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
    auto pfnCreateInstance = reinterpret_cast<PFN_vkCreateInstance>(
        pfnGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance"));

    // 2) loader 版本
    uint32_t loaderApi = VK_API_VERSION_1_0;
    if (pfnEnumerateInstanceVersion && pfnEnumerateInstanceVersion(&loaderApi) == VK_SUCCESS) {
        r.loaderVersion = apiVersionToString(loaderApi);
    } else {
        r.loaderVersion = "1.0";
    }
    r.loaderApiRaw = loaderApi;
    log("Loader instance 版本: " + r.loaderVersion + "\n");

    // 3) 实例扩展
    std::vector<VkExtensionProperties> instExts;
    if (pfnEnumerateInstanceExtensionProperties) {
        uint32_t n = 0;
        pfnEnumerateInstanceExtensionProperties(nullptr, &n, nullptr);
        instExts.resize(n);
        if (n) pfnEnumerateInstanceExtensionProperties(nullptr, &n, instExts.data());
    }
    auto hasInstExt = [&](const char* name) {
        for (auto& e : instExts)
            if (std::strcmp(e.extensionName, name) == 0) return true;
        return false;
    };
    r.hasKhrSurface = hasInstExt("VK_KHR_surface");
#ifdef AMCL_HAVE_VULKAN_OHOS
    r.hasOhosSurface = hasInstExt(VK_OHOS_SURFACE_EXTENSION_NAME);
#else
    r.hasOhosSurface = hasInstExt("VK_OHOS_surface");
#endif
    r.hasGetPhysDevProps2 = hasInstExt("VK_KHR_get_physical_device_properties2");
    log("\n--- 实例扩展（共 " + std::to_string(instExts.size()) + "）---\n");
    log(std::string(r.hasKhrSurface ? "  ✅ " : "  ❌ ") + "VK_KHR_surface\n");
    log(std::string(r.hasOhosSurface ? "  ✅ " : "  ❌ ") + "VK_OHOS_surface\n");
    log(std::string(r.hasGetPhysDevProps2 ? "  ✅ " : "  — ")
        + "VK_KHR_get_physical_device_properties2\n");

    if (!pfnCreateInstance) {
        r.error = "dlsym(vkCreateInstance) 失败";
        log("\n❌ " + r.error + "\n");
        dlclose(lib);
        return r;
    }

    // 4) 创建最小 instance
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "AMCL Vulkan Probe";
    app.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    app.pEngineName = "AMCL";
    app.engineVersion = VK_MAKE_VERSION(1, 0, 0);
    app.apiVersion = (loaderApi >= minimumApi) ? minimumApi : loaderApi;

    std::vector<const char*> enableExts;
    if (r.hasKhrSurface) enableExts.push_back("VK_KHR_surface");
#ifdef AMCL_HAVE_VULKAN_OHOS
    if (r.hasOhosSurface) enableExts.push_back(VK_OHOS_SURFACE_EXTENSION_NAME);
#else
    if (r.hasOhosSurface) enableExts.push_back("VK_OHOS_surface");
#endif
    // 在 1.0/1.1 loader 上启用该实例扩展，才能用 vkGetPhysicalDeviceFeatures2KHR
    // 查真实 feature bit（1.2+ instance 该函数已进 core，可不依赖此扩展）。
    if (r.hasGetPhysDevProps2 && app.apiVersion < VK_API_VERSION_1_1)
        enableExts.push_back("VK_KHR_get_physical_device_properties2");

    VkInstanceCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = static_cast<uint32_t>(enableExts.size());
    ici.ppEnabledExtensionNames = enableExts.empty() ? nullptr : enableExts.data();

    VkInstance instance = VK_NULL_HANDLE;
    VkResult cr = pfnCreateInstance(&ici, nullptr, &instance);
    if (cr != VK_SUCCESS || instance == VK_NULL_HANDLE) {
        r.error = "vkCreateInstance 失败 (VkResult=" + std::to_string((int)cr) + ")";
        log("\n❌ " + r.error + "\n");
        dlclose(lib);
        return r;
    }
    r.instanceCreated = true;
    log("\n✅ vkCreateInstance OK (apiVersion=" + apiVersionToString(app.apiVersion) + ")\n");

    auto pfnDestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(
        pfnGetInstanceProcAddr(instance, "vkDestroyInstance"));
    auto pfnEnumeratePhysicalDevices = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
        pfnGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices"));
    auto pfnGetPhysicalDeviceProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
        pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties"));
    auto pfnEnumerateDeviceExtensionProperties =
        reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
            pfnGetInstanceProcAddr(instance, "vkEnumerateDeviceExtensionProperties"));
    auto pfnGetPhysicalDeviceQueueFamilyProperties =
        reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
            pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto pfnGetPhysicalDeviceMemoryProperties =
        reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
            pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties"));

    auto cleanup = [&]() {
        if (pfnDestroyInstance) pfnDestroyInstance(instance, nullptr);
        dlclose(lib);
    };

    if (!pfnEnumeratePhysicalDevices || !pfnGetPhysicalDeviceProperties) {
        r.error = "无法解析物理设备查询函数";
        log("❌ " + r.error + "\n");
        cleanup();
        return r;
    }

    // 5) 物理设备
    uint32_t gpuCount = 0;
    VkResult enumerateStatus = pfnEnumeratePhysicalDevices(instance, &gpuCount, nullptr);
    if (enumerateStatus != VK_SUCCESS || gpuCount == 0) {
        r.error = "无 Vulkan 物理设备";
        log("❌ " + r.error + "\n");
        cleanup();
        return r;
    }
    r.gpuCount = gpuCount;
    std::vector<VkPhysicalDevice> gpus(gpuCount);
    enumerateStatus = pfnEnumeratePhysicalDevices(instance, &gpuCount, gpus.data());
    if ((enumerateStatus != VK_SUCCESS && enumerateStatus != VK_INCOMPLETE) || gpuCount == 0) {
        r.error = "枚举 Vulkan 物理设备失败";
        cleanup();
        return r;
    }
    log("\n--- 物理设备（共 " + std::to_string(gpuCount) + "）---\n");

    // 选设备：按评分挑「最佳」——core>=1.2 优先，独显 > 集显 > 其它。
    // （旧实现取「最后一个 >=1.2 的索引」，多 GPU 下不稳定。）
    int bestIdx = -1;
    int bestScore = -1;
    for (uint32_t i = 0; i < gpuCount; ++i) {
        VkPhysicalDeviceProperties props{};
        pfnGetPhysicalDeviceProperties(gpus[i], &props);
        if (!providerRenderer.empty() &&
            providerRenderer.find(std::string(props.deviceName) + ", Vulkan ") == std::string::npos) continue;
        int score = 0;
        if (props.apiVersion >= minimumApi) score += 100;
        switch (props.deviceType) {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   score += 30; break;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: score += 20; break;
            case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    score += 10; break;
            default: break;
        }
        if (score > bestScore) { bestScore = score; bestIdx = (int)i; }

        log("\n[GPU " + std::to_string(i) + "] " + props.deviceName + "\n");
        log(std::string("  类型: ") + deviceTypeToString(props.deviceType) + "\n");
        log("  apiVersion: " + apiVersionToString(props.apiVersion) +
            (props.apiVersion >= kMcTargetApi ? "  ✅ >= 1.2"
                                              : "  ❌ < 1.2（不满足 MC 官方 Vulkan）") + "\n");
    }

    if (bestIdx < 0) {
        r.error = "Vulkan device does not match the initialized MobileGL renderer";
        cleanup();
        return r;
    }

    // 对选中的设备做详细盘点
    VkPhysicalDevice gpu = gpus[bestIdx];
    VkPhysicalDeviceProperties props{};
    pfnGetPhysicalDeviceProperties(gpu, &props);
    r.hasDevice = true;
    r.deviceName = props.deviceName;
    r.deviceType = deviceTypeToString(props.deviceType);
    r.deviceApiRaw = props.apiVersion;
    r.deviceApiVersion = apiVersionToString(props.apiVersion);
    r.driverVersionRaw = props.driverVersion;
    r.vendorID = props.vendorID;
    // 历史策略只缓存窗口无关的设备事实。UUID与原始驱动版本一起保留，不把人类可读版本
    // 的厂商解码当成唯一身份；驱动/硬件替换后旧记录自然失效。
    r.driverIdentity = std::to_string(props.vendorID) + ":" + std::to_string(props.deviceID) + ":" + std::to_string(props.driverVersion) + ":";
    for (const auto byte : props.pipelineCacheUUID) {
        static constexpr char digits[] = "0123456789abcdef";
        r.driverIdentity.push_back(digits[byte >> 4]); r.driverIdentity.push_back(digits[byte & 15]);
    }
    r.deviceID = props.deviceID;
    r.vendorName = vendorIdToName(props.vendorID);
    r.maxImageDimension2D = props.limits.maxImageDimension2D;
    log("\n>>> 选中: [GPU " + std::to_string(bestIdx) + "] " + r.deviceName +
        " （" + r.vendorName + "）\n");
    log("  vendorID="  + toHex(r.vendorID) + "  deviceID=" + toHex(r.deviceID) + "\n");
    log("  driverVersion: " + driverVersionToString(r.driverVersionRaw, r.vendorID) + "\n");
    log("  maxImageDimension2D: " + std::to_string(r.maxImageDimension2D) + "\n");

    // 5a) 设备本地显存（汇总 DEVICE_LOCAL 堆）
    if (pfnGetPhysicalDeviceMemoryProperties) {
        VkPhysicalDeviceMemoryProperties mem{};
        pfnGetPhysicalDeviceMemoryProperties(gpu, &mem);
        for (uint32_t h = 0; h < mem.memoryHeapCount; ++h) {
            if (mem.memoryHeaps[h].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT)
                r.deviceLocalMemoryBytes += mem.memoryHeaps[h].size;
        }
        log("  设备本地显存: " +
            std::to_string(r.deviceLocalMemoryBytes / (1024ull * 1024ull)) + " MB\n");
    }

    // 5b) 核心 feature bits + compute/SSBO limits（Zink/Voxy 可行性判定用）。
    //     用基础 vkGetPhysicalDeviceFeatures（core 1.0，最稳），一次拿全部布尔位。
    {
        auto pfnGetFeatures = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures>(
            pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures"));
        if (pfnGetFeatures) {
            VkPhysicalDeviceFeatures f{};
            pfnGetFeatures(gpu, &f);
            r.baseFeaturesQueried = true;
            r.fGeometryShader = f.geometryShader;
            r.fTessellationShader = f.tessellationShader;
            r.fMultiDrawIndirect = f.multiDrawIndirect;
            r.fDrawIndirectFirstInstance = f.drawIndirectFirstInstance;
            r.fFragmentStoresAndAtomics = f.fragmentStoresAndAtomics;
            r.fVertexPipelineStoresAndAtomics = f.vertexPipelineStoresAndAtomics;
            r.fShaderStorageImageExtendedFormats = f.shaderStorageImageExtendedFormats;
            r.fShaderInt64 = f.shaderInt64;
            r.fShaderFloat64 = f.shaderFloat64;
            r.fFillModeNonSolid = f.fillModeNonSolid;
            r.fLogicOp = f.logicOp;
            r.fImageCubeArray = f.imageCubeArray;
            r.fIndependentBlend = f.independentBlend;
            r.fDualSrcBlend = f.dualSrcBlend;
            r.fSampleRateShading = f.sampleRateShading;
            r.fShaderClipDistance = f.shaderClipDistance;
            r.fShaderCullDistance = f.shaderCullDistance;
            r.fSamplerAnisotropy = f.samplerAnisotropy;
            r.fTextureCompressionBC = f.textureCompressionBC;
            r.fTextureCompressionETC2 = f.textureCompressionETC2;
            r.fWideLines = f.wideLines;
            r.fDepthClamp = f.depthClamp;
            r.fOcclusionQueryPrecise = f.occlusionQueryPrecise;
            r.fShaderStorageImageReadWithoutFormat = f.shaderStorageImageReadWithoutFormat;
            r.fShaderStorageImageWriteWithoutFormat = f.shaderStorageImageWriteWithoutFormat;
            r.maxComputeSharedMemorySize = props.limits.maxComputeSharedMemorySize;
            r.maxComputeWorkGroupInvocations = props.limits.maxComputeWorkGroupInvocations;
            r.maxPerStageDescriptorStorageBuffers = props.limits.maxPerStageDescriptorStorageBuffers;
            r.maxStorageBufferRangeMB = (uint32_t)(props.limits.maxStorageBufferRange / (1024u * 1024u));

            log("\n  Zink/Voxy 相关 feature（vkGetPhysicalDeviceFeatures）:\n");
            auto fl = [&](const char* name, bool v) {
                log(std::string("    ") + (v ? "✅" : "❌") + "  " + name + "\n");
            };
            fl("geometryShader (GL3.2/Zink等级)", r.fGeometryShader);
            fl("tessellationShader (GL4.0/Zink等级)", r.fTessellationShader);
            fl("fillModeNonSolid (glPolygonMode·桌面GL必备)", r.fFillModeNonSolid);
            fl("logicOp (桌面GL·GLES无)", r.fLogicOp);
            fl("multiDrawIndirect (Voxy)", r.fMultiDrawIndirect);
            fl("drawIndirectFirstInstance (Voxy)", r.fDrawIndirectFirstInstance);
            fl("fragmentStoresAndAtomics (SSBO写/Voxy)", r.fFragmentStoresAndAtomics);
            fl("shaderStorageImageExtendedFormats", r.fShaderStorageImageExtendedFormats);
            fl("shaderFloat64 (GL4.x double)", r.fShaderFloat64);
            fl("shaderInt64", r.fShaderInt64);
            fl("imageCubeArray", r.fImageCubeArray);
            fl("independentBlend", r.fIndependentBlend);
            fl("dualSrcBlend", r.fDualSrcBlend);
            fl("sampleRateShading", r.fSampleRateShading);
            fl("shaderClipDistance", r.fShaderClipDistance);
            fl("shaderCullDistance", r.fShaderCullDistance);
            fl("textureCompressionBC (桌面DXT)", r.fTextureCompressionBC);
            fl("textureCompressionETC2", r.fTextureCompressionETC2);
            log("    compute: sharedMem=" + std::to_string(r.maxComputeSharedMemorySize) +
                "B  maxInvocations=" + std::to_string(r.maxComputeWorkGroupInvocations) +
                "  perStageStorageBuffers=" + std::to_string(r.maxPerStageDescriptorStorageBuffers) +
                "  storageBufRange=" + std::to_string(r.maxStorageBufferRangeMB) + "MB\n");
        }
    }

    // 6) 设备扩展（字符串级别）
    if (pfnEnumerateDeviceExtensionProperties) {
        uint32_t n = 0;
        VkResult extensionStatus = pfnEnumerateDeviceExtensionProperties(gpu, nullptr, &n, nullptr);
        std::vector<VkExtensionProperties> devExts(n);
        if (extensionStatus == VK_SUCCESS && n > 0) {
            extensionStatus = pfnEnumerateDeviceExtensionProperties(gpu, nullptr, &n, devExts.data());
        }
        r.deviceExtensionsQueried = extensionStatus == VK_SUCCESS || extensionStatus == VK_INCOMPLETE;
        if (!r.deviceExtensionsQueried) {
            n = 0;
            devExts.clear();
        } else {
            devExts.resize(n);
        }
        r.deviceExtCount = n;
        auto hasDevExt = [&](const char* name) {
            for (auto& e : devExts)
                if (std::strcmp(e.extensionName, name) == 0) return true;
            return false;
        };
        r.extSwapchain          = hasDevExt("VK_KHR_swapchain");
        r.extDynamicRendering   = hasDevExt("VK_KHR_dynamic_rendering");
        r.extSynchronization2   = hasDevExt("VK_KHR_synchronization2");
        r.extCreateRenderpass2  = hasDevExt("VK_KHR_create_renderpass2");
        r.extDescriptorIndexing = hasDevExt("VK_EXT_descriptor_indexing");
        r.extMaintenance1       = hasDevExt("VK_KHR_maintenance1");
        r.extMaintenance2       = hasDevExt("VK_KHR_maintenance2");
        r.extPushDescriptor     = hasDevExt("VK_KHR_push_descriptor");
        r.extVertexAttributeDivisor = hasDevExt("VK_EXT_vertex_attribute_divisor");

        // 能力 = 扩展被列出 OR 已晋升进 core：
        //   · dynamic_rendering / synchronization2 / create_renderpass2 → core 1.3
        //   · descriptor_indexing → core 1.2
        //   · push_descriptor → core 1.4（仍可能以扩展形式存在于 <1.4 设备）
        r.hasSwapchain          = r.extSwapchain;   // swapchain 永远是扩展，不进 core
        r.hasDynamicRendering   = r.extDynamicRendering   || r.deviceApiRaw >= VK_API_VERSION_1_3;
        r.hasSynchronization2   = r.extSynchronization2   || r.deviceApiRaw >= VK_API_VERSION_1_3;
        r.hasCreateRenderpass2  = r.extCreateRenderpass2  || r.deviceApiRaw >= VK_API_VERSION_1_3;
        r.hasDescriptorIndexing = r.extDescriptorIndexing || r.deviceApiRaw >= VK_API_VERSION_1_2;
        r.hasMaintenance1       = r.extMaintenance1       || r.deviceApiRaw >= VK_API_VERSION_1_1;
        r.hasMaintenance2       = r.extMaintenance2       || r.deviceApiRaw >= VK_API_VERSION_1_1;
#ifdef VK_API_VERSION_1_4
        r.hasPushDescriptor     = r.extPushDescriptor     || r.deviceApiRaw >= VK_API_VERSION_1_4;
#else
        r.hasPushDescriptor     = r.extPushDescriptor;
#endif
        r.hasVertexAttributeDivisor = r.extVertexAttributeDivisor;

        log("\n  设备扩展（共 " + std::to_string(n) + "）关键项 [扩展列出?]:\n");
        auto line = [&](const char* name, bool listed, bool capable) {
            std::string mark = listed ? "✅扩展" : (capable ? "✅core" : "—   ");
            log("    " + mark + "  " + name + "\n");
        };
        line("VK_KHR_swapchain",            r.extSwapchain,          r.hasSwapchain);
        line("VK_KHR_dynamic_rendering",    r.extDynamicRendering,   r.hasDynamicRendering);
        line("VK_KHR_synchronization2",     r.extSynchronization2,   r.hasSynchronization2);
        line("VK_KHR_create_renderpass2",   r.extCreateRenderpass2,  r.hasCreateRenderpass2);
        line("VK_EXT_descriptor_indexing",  r.extDescriptorIndexing, r.hasDescriptorIndexing);
        line("VK_KHR_maintenance1",         r.extMaintenance1,       r.hasMaintenance1);
        line("VK_KHR_maintenance2",         r.extMaintenance2,       r.hasMaintenance2);
        line("VK_KHR_push_descriptor",      r.extPushDescriptor,     r.hasPushDescriptor);
        line("VK_EXT_vertex_attribute_divisor", r.extVertexAttributeDivisor, r.hasVertexAttributeDivisor);
    }

    // 7) 真实 feature bit + 驱动信息（vkGetPhysicalDeviceFeatures2 / Properties2）。
    //    这是「更真实」的核心：扩展被列出不代表 feature 真能用。
#ifdef VK_VERSION_1_1
    {
        // instance >= 1.1 时 features2/properties2 进 core；否则尝试 KHR 变体。
        auto pfnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
        if (!pfnFeatures2)
            pfnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
                pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
        auto pfnProperties2 = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
            pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties2"));
        if (!pfnProperties2)
            pfnProperties2 = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
                pfnGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties2KHR"));

        if (pfnFeatures2) {
            VkPhysicalDeviceFeatures2 f2{};
            f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
            void** tail = &f2.pNext;

#ifdef VK_KHR_dynamic_rendering
            VkPhysicalDeviceDynamicRenderingFeaturesKHR dynFeat{};
            dynFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR;
            if (r.hasDynamicRendering) { *tail = &dynFeat; tail = &dynFeat.pNext; }
#endif
#ifdef VK_KHR_synchronization2
            VkPhysicalDeviceSynchronization2FeaturesKHR syncFeat{};
            syncFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR;
            if (r.hasSynchronization2) { *tail = &syncFeat; tail = &syncFeat.pNext; }
#endif
#ifdef VK_KHR_shader_draw_parameters
            VkPhysicalDeviceShaderDrawParametersFeatures drawFeat{};
            drawFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES;
            if (r.deviceApiRaw >= VK_API_VERSION_1_1 || r.hasDevice) { *tail = &drawFeat; tail = &drawFeat.pNext; }
#endif
#ifdef VK_KHR_timeline_semaphore
            VkPhysicalDeviceTimelineSemaphoreFeatures timelineFeat{};
            timelineFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
            if (r.deviceApiRaw >= VK_API_VERSION_1_2 || r.extSynchronization2) { *tail = &timelineFeat; tail = &timelineFeat.pNext; }
#endif
#ifdef VK_EXT_host_query_reset
            VkPhysicalDeviceHostQueryResetFeatures hostQueryFeat{};
            hostQueryFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_QUERY_RESET_FEATURES;
            if (r.extSynchronization2 || r.deviceApiRaw >= VK_API_VERSION_1_2) { *tail = &hostQueryFeat; tail = &hostQueryFeat.pNext; }
#endif
#ifdef VK_EXT_vertex_attribute_divisor
            VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT divisorFeat{};
            divisorFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT;
            if (r.extVertexAttributeDivisor) { *tail = &divisorFeat; tail = &divisorFeat.pNext; }
#endif
            pfnFeatures2(gpu, &f2);
            r.featuresQueried = true;
#ifdef VK_KHR_dynamic_rendering
            r.featDynamicRendering = (dynFeat.dynamicRendering == VK_TRUE);
#endif
#ifdef VK_KHR_synchronization2
            r.featSynchronization2 = (syncFeat.synchronization2 == VK_TRUE);
#endif
#ifdef VK_KHR_shader_draw_parameters
            r.featShaderDrawParameters = (drawFeat.shaderDrawParameters == VK_TRUE);
#endif
#ifdef VK_KHR_timeline_semaphore
            r.featTimelineSemaphore = (timelineFeat.timelineSemaphore == VK_TRUE);
#endif
#ifdef VK_EXT_host_query_reset
            r.featHostQueryReset = (hostQueryFeat.hostQueryReset == VK_TRUE);
#endif
#ifdef VK_EXT_vertex_attribute_divisor
            r.featVertexAttributeInstanceRateDivisor = (divisorFeat.vertexAttributeInstanceRateDivisor == VK_TRUE);
#endif
            log("\n  feature bit 实查 (vkGetPhysicalDeviceFeatures2):\n");
            log(std::string("    dynamicRendering 特性位: ")
                + (r.featDynamicRendering ? "✅ true" : "❌ false") + "\n");
            log(std::string("    synchronization2 特性位: ")
                + (r.featSynchronization2 ? "✅ true" : "❌ false") + "\n");
        } else {
            log("\n  ⚠️ 无法解析 vkGetPhysicalDeviceFeatures2 —— feature 能力记为 UNKNOWN，门控拒绝\n");
        }

        if (pfnProperties2) {
            VkPhysicalDeviceProperties2 p2{};
            p2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            void** ptail = &p2.pNext;

#ifdef VK_KHR_driver_properties
            VkPhysicalDeviceDriverPropertiesKHR drvProps{};
            drvProps.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES_KHR;
            *ptail = &drvProps; ptail = &drvProps.pNext;
#endif
#ifdef VK_KHR_push_descriptor
            VkPhysicalDevicePushDescriptorPropertiesKHR pushProps{};
            pushProps.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PUSH_DESCRIPTOR_PROPERTIES_KHR;
            if (r.hasPushDescriptor) { *ptail = &pushProps; ptail = &pushProps.pNext; }
#endif
            pfnProperties2(gpu, &p2);
#ifdef VK_KHR_driver_properties
            if (drvProps.driverName[0] != '\0') {
                r.hasDriverProps = true;
                r.driverName = drvProps.driverName;
                r.driverInfo = drvProps.driverInfo;
                char cv[32];
                std::snprintf(cv, sizeof(cv), "%u.%u.%u.%u",
                              drvProps.conformanceVersion.major,
                              drvProps.conformanceVersion.minor,
                              drvProps.conformanceVersion.subminor,
                              drvProps.conformanceVersion.patch);
                r.conformanceVersion = cv;
                log("\n  驱动信息 (VK_KHR_driver_properties):\n");
                log("    driverName: " + r.driverName + "\n");
                log("    driverInfo: " + r.driverInfo + "\n");
                log("    CTS 一致性版本: " + r.conformanceVersion + "\n");
            }
#endif
#ifdef VK_KHR_push_descriptor
            r.maxPushDescriptors = pushProps.maxPushDescriptors;
            if (r.hasPushDescriptor)
                log("    maxPushDescriptors: " + std::to_string(r.maxPushDescriptors) + "\n");
#endif
        }
    }
#endif // VK_VERSION_1_1

    if (pfnGetPhysicalDeviceQueueFamilyProperties) {
        uint32_t qn = 0;
        pfnGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, nullptr);
        std::vector<VkQueueFamilyProperties> qf(qn);
        if (qn) pfnGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, qf.data());
        r.queueFamilyCount = qn;
        for (uint32_t q = 0; q < qn; ++q) {
            if (qf[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) { r.graphicsFamily = (int)q; break; }
        }
        log("\n  队列族总数: " + std::to_string(qn) + "\n");
        log("  graphics 队列族: " +
            (r.graphicsFamily >= 0 ? std::to_string(r.graphicsFamily) : std::string("无")) + "\n");
    }

    if (probePresentation && r.hasKhrSurface && r.hasOhosSurface) {
        probeQueuePresentation(instance, gpu, pfnGetInstanceProcAddr, r);
    }
    cleanup();
    return r;
}

// 某能力是否「真正可用」：扩展名仅是准入输入，不能替代真实 feature bit。
// 未成功查询 feature2 时返回 false（UNKNOWN 按保守策略拒绝）。
bool dynamicRenderingUsable(const VkScanResult& r) {
    return r.featuresQueried && r.featDynamicRendering;
}
bool synchronization2Usable(const VkScanResult& r) {
    return r.featuresQueried && r.featSynchronization2;
}

// 将同一次扫描转换成版本要求的原始事实，保留所有扩展/特性，不在采集层决定游戏准入。
// 26.2/26.3 仍要求 dynamic rendering 和 push descriptor；26.4 Snapshot 1 已移除这两项。
// 差异只在 vulkan_requirement_policy 中按审计身份解释。兼容旧查询继续使用 26.2 身份，
// 不能用新版较宽的规则改写旧版结论，也不能因扩展缺失而停止采集其他有效特性。
amcl::graphics::VulkanRequirementFacts minecraftRequirementFacts(const VkScanResult& r) {
    amcl::graphics::VulkanRequirementFacts facts;
    facts.loaderApiRaw = r.loaderApiRaw;
    facts.deviceApiRaw = r.deviceApiRaw;
    facts.deviceExtensionsQueried = r.deviceExtensionsQueried;
    facts.hasSwapchain = r.hasSwapchain;
    facts.hasDynamicRendering = r.hasDynamicRendering;
    facts.hasPushDescriptor = r.hasPushDescriptor && r.maxPushDescriptors > 0;
    facts.hasSynchronization2 = r.hasSynchronization2;
    facts.hasVertexAttributeDivisor = r.hasVertexAttributeDivisor;
    facts.featuresQueried = r.featuresQueried;
    facts.multiDrawIndirect = r.fMultiDrawIndirect;
    facts.drawIndirectFirstInstance = r.fDrawIndirectFirstInstance;
    facts.fillModeNonSolid = r.fFillModeNonSolid;
    facts.samplerAnisotropy = r.fSamplerAnisotropy;
    facts.shaderDrawParameters = r.featShaderDrawParameters;
    facts.timelineSemaphore = r.featTimelineSemaphore;
    facts.hostQueryReset = r.featHostQueryReset;
    facts.synchronization2 = r.featSynchronization2;
    facts.dynamicRendering = r.featDynamicRendering;
    facts.vertexAttributeInstanceRateDivisor = r.featVertexAttributeInstanceRateDivisor;
    return facts;
}

bool capabilityAvailable(const VkScanResult& r, std::string& reasonOut, std::string& warnOut) {
    reasonOut.clear();
    warnOut.clear();
    if (!r.libLoaded)            { reasonOut = "本机无 Vulkan loader (libvulkan.so)"; return false; }
    if (!r.instanceCreated)      { reasonOut = r.error.empty() ? "Vulkan 实例创建失败" : r.error; return false; }
    if (!r.hasDevice)            { reasonOut = "无可用 Vulkan 物理设备"; return false; }
    if (!(r.hasKhrSurface && r.hasOhosSurface))
                                 { reasonOut = "缺少 surface 扩展 (VK_KHR_surface / VK_OHOS_surface)"; return false; }
    const auto facts = minecraftRequirementFacts(r);
    if (!amcl::graphics::EvaluateMinecraftVulkanRequirement(facts, "minecraft-26.2-conservative-v1", reasonOut)) return false;

    // 所有硬性扩展与特性已由唯一要求表校验；兼容输出不另设更宽松的警告路径。
    return true;
}

// 兼容旧两参签名（amclVulkanUsableForMc 等内部仅关心布尔结论）。
bool capabilityAvailable(const VkScanResult& r, std::string& reasonOut) {
    std::string warn;
    return capabilityAvailable(r, reasonOut, warn);
}

// SDL3 路线复用同一窗口与呈现契约，设备要求按调用方传来的精确审计身份逐代评估。
// 26.4 的扩展放宽不跳过真实 surface、queue、方向检查；设置页未执行的阶段仍不算通过。
bool capabilityAvailableSdl(const VkScanResult& r, std::string& reasonOut, const char* requirementId) {
    reasonOut.clear();
    if (!r.libLoaded) { reasonOut = "vulkan_loader_unavailable"; return false; }
    if (!r.instanceCreated) { reasonOut = "vulkan_instance_unavailable"; return false; }
    if (!r.hasDevice) { reasonOut = "vulkan_physical_device_unavailable"; return false; }
    if (!(r.hasKhrSurface && r.hasOhosSurface)) { reasonOut = "ohos_surface_extension_missing"; return false; }
    const auto facts = minecraftRequirementFacts(r);
    if (!amcl::graphics::EvaluateMinecraftVulkanRequirement(facts, requirementId, reasonOut)) return false;
    using amcl::graphics::CapabilityEvidence;
    if (r.surfaceContractQueried && !r.sdlSurfaceContract) {
        reasonOut = r.surfaceReason.empty() ? "sdl_surface_contract_mismatch" : r.surfaceReason;
        return false;
    }
    if (!r.surfaceContractQueried) { reasonOut = "sdl_surface_contract_not_queried"; return false; }
    if (r.surfaceEvidence != CapabilityEvidence::Yes || r.presentEvidence != CapabilityEvidence::Yes) {
        reasonOut = "sdl_surface_or_present_not_verified";
        return false;
    }
    return true;
}

// Zink (GL-on-Vulkan) 在本设备上「可达 GL 版本」的启发式估算。Mesa Zink 暴露的 GL 等级
// 受底层 Vulkan feature 门控：无 geometryShader → 上不了 GL 3.2；无 tessellation → 上不了 4.0；
// 缺 SSBO/indirect 关键位 → 卡在 ~4.1；齐备才可能到 4.6。Voxy 需 GL 4.6（compute+SSBO+indirect）。
// 返回 (估算等级字符串, 是否够 Voxy)。仅供 Phase-0 决策，不是 Zink 真实跑出来的结果。
std::pair<std::string, bool> estimateZinkGl(const VkScanResult& r) {
    if (!r.baseFeaturesQueried) return {"未知（feature 未查到）", false};
    if (!r.fGeometryShader)
        return {"≤ GL 3.1（缺 geometryShader → Zink 上不了 3.2，Voxy 无望）", false};
    if (!r.fTessellationShader)
        return {"~ GL 3.3（缺 tessellationShader → 上不了 4.0）", false};
    bool ssboIndirect = r.fFragmentStoresAndAtomics && r.fMultiDrawIndirect &&
                        r.fDrawIndirectFirstInstance && r.fFillModeNonSolid &&
                        r.fShaderStorageImageExtendedFormats;
    if (!ssboIndirect)
        return {"~ GL 4.1（缺 SSBO/indirect/polygonMode 关键位 → Voxy 多半不过）", false};
    if (!r.fShaderFloat64)
        return {"~ GL 4.2–4.5（缺 shaderFloat64，标准 4.6 难达；Voxy 视其检查方式而定）", true};
    return {"GL 4.6 可达（核心特性齐备，Voxy 有戏）", true};
}

std::string jsonBool(bool b) { return b ? "true" : "false"; }
std::string jsonEscape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else o += c;
    }
    return o;
}

bool artifactExists(const std::string& directory, const char* name) {
    if (directory.empty()) return false;
    struct stat info{};
    const std::string path = directory + "/" + name;
    return stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0;
}

// Exercise both runtime C APIs with one shader; symbol presence alone is not a
// successful toolchain observation. The signatures mirror the shipped LWJGL
// shaderc bindings and SPIRV-Cross C header.
bool probeShaderToolchain(const std::string& directory, std::string& reason) {
    void* shaderLibrary = dlopen((directory + "/libshaderc.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    void* reflectLibrary = dlopen((directory + "/libspirv-cross.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!shaderLibrary || !reflectLibrary) {
        reason = "shader_toolchain_library_load_failed";
        if (reflectLibrary) dlclose(reflectLibrary);
        if (shaderLibrary) dlclose(shaderLibrary);
        return false;
    }
    auto compilerInit = reinterpret_cast<void* (*)()>(dlsym(shaderLibrary, "shaderc_compiler_initialize"));
    auto compilerRelease = reinterpret_cast<void (*)(void*)>(dlsym(shaderLibrary, "shaderc_compiler_release"));
    auto compile = reinterpret_cast<void* (*)(void*, const char*, size_t, int, const char*, const char*, const void*)>(dlsym(shaderLibrary, "shaderc_compile_into_spv"));
    auto resultStatus = reinterpret_cast<int (*)(const void*)>(dlsym(shaderLibrary, "shaderc_result_get_compilation_status"));
    auto resultLength = reinterpret_cast<size_t (*)(const void*)>(dlsym(shaderLibrary, "shaderc_result_get_length"));
    auto resultBytes = reinterpret_cast<const char* (*)(const void*)>(dlsym(shaderLibrary, "shaderc_result_get_bytes"));
    auto resultRelease = reinterpret_cast<void (*)(void*)>(dlsym(shaderLibrary, "shaderc_result_release"));
    auto contextCreate = reinterpret_cast<int (*)(void**)>(dlsym(reflectLibrary, "spvc_context_create"));
    auto contextDestroy = reinterpret_cast<void (*)(void*)>(dlsym(reflectLibrary, "spvc_context_destroy"));
    auto parseSpirv = reinterpret_cast<int (*)(void*, const uint32_t*, size_t, void**)>(dlsym(reflectLibrary, "spvc_context_parse_spirv"));
    auto createCompiler = reinterpret_cast<int (*)(void*, int, void*, int, void**)>(dlsym(reflectLibrary, "spvc_context_create_compiler"));
    auto createResources = reinterpret_cast<int (*)(void*, void**)>(dlsym(reflectLibrary, "spvc_compiler_create_shader_resources"));
    bool passed = false;
    reason = "shader_toolchain_entrypoint_missing";
    if (compilerInit && compilerRelease && compile && resultStatus && resultLength && resultBytes &&
        resultRelease && contextCreate && contextDestroy && parseSpirv && createCompiler && createResources) {
        void* compiler = compilerInit();
        void* result = nullptr;
        void* context = nullptr;
        if (compiler) {
            static constexpr char source[] = "#version 450\nvoid main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }\n";
            result = compile(compiler, source, sizeof(source) - 1, 0, "amcl-admission.vert", "main", nullptr);
            reason = "shader_compile_failed";
            if (result && resultStatus(result) == 0 && resultLength(result) >= 20 && resultLength(result) % 4 == 0 && resultBytes(result)) {
                const size_t wordCount = resultLength(result) / sizeof(uint32_t);
                std::vector<uint32_t> words(wordCount);
                std::memcpy(words.data(), resultBytes(result), resultLength(result));
                void* ir = nullptr;
                void* reflectCompiler = nullptr;
                void* resources = nullptr;
                reason = "spirv_reflection_failed";
                passed = words[0] == 0x07230203 && contextCreate(&context) == 0 && context &&
                    parseSpirv(context, words.data(), wordCount, &ir) == 0 && ir &&
                    createCompiler(context, 0, ir, 1, &reflectCompiler) == 0 && reflectCompiler &&
                    createResources(reflectCompiler, &resources) == 0 && resources;
            }
        } else {
            reason = "shader_compiler_initialize_failed";
        }
        if (context) contextDestroy(context);
        if (result) resultRelease(result);
        if (compiler) compilerRelease(compiler);
    }
    dlclose(reflectLibrary);
    dlclose(shaderLibrary);
    if (passed) reason = "shader_compile_and_reflection_verified";
    return passed;
}

#endif // AMCL_HAVE_VULKAN_HEADERS

} // namespace

namespace amcl::graphics {

namespace {
GraphicsCapability queryMobileGlDevice(const std::string& renderer) {
    GraphicsCapability result;
#ifdef AMCL_HAVE_VULKAN_HEADERS
    // MobileGL's pinned DirectVulkan implementation requests Vulkan 1.1 and
    // VK_KHR_swapchain. Optional core features are enabled only when present.
    // Audit the GPU named by its initialized GL_RENDERER, not an unrelated GPU
    // selected by the Minecraft requirement's ranking.
    const VkScanResult scan = scanVulkan(nullptr, false, VK_API_VERSION_1_1, renderer);
    result.loader = scan.libLoaded ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    result.instance = !scan.libLoaded ? CapabilityEvidence::NotRun :
        (scan.instanceCreated ? CapabilityEvidence::Yes : CapabilityEvidence::No);
    result.physicalDevice = !scan.instanceCreated ? CapabilityEvidence::NotRun :
        (scan.hasDevice ? CapabilityEvidence::Yes : CapabilityEvidence::No);
    result.apiVersion = scan.deviceApiVersion;
    result.driverIdentity = scan.driverIdentity;
    if (scan.hasDevice) {
        result.deviceExtensions = !scan.deviceExtensionsQueried ? CapabilityEvidence::Unknown :
            scan.loaderApiRaw >= VK_API_VERSION_1_1 && scan.deviceApiRaw >= VK_API_VERSION_1_1 &&
            scan.hasKhrSurface && scan.hasOhosSurface && scan.hasSwapchain ? CapabilityEvidence::Yes : CapabilityEvidence::No;
        result.featureBits = scan.baseFeaturesQueried ? CapabilityEvidence::Yes : CapabilityEvidence::Unknown;
    }
    result.reasonCode = scan.error.empty() ? "mobilegl_vulkan_1_1_swapchain_requirement" : scan.error;
#else
    result.reasonCode = "vulkan_headers_unavailable";
#endif
    return result;
}

std::string nativeProbeLibraryDirectory() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<void*>(&getGraphicsCapabilityJson), &info) == 0 || !info.dli_fname) return "";
    const std::string path = info.dli_fname;
    const size_t slash = path.rfind('/');
    return slash == std::string::npos ? "" : path.substr(0, slash);
}
} // namespace

GraphicsCapability ProbeGraphicsCapability(const std::string& profileId,
    const std::string& requirementId, const std::string& windowProvider,
    const std::string& nativeLibraryDir, bool availabilityOnly) {
    GraphicsCapability result;
    result.profileId = profileId;
    result.requirementId = requirementId;
    result.windowProvider = windowProvider;
    result.nativeLibraryDir = nativeLibraryDir;
    result.processId = static_cast<int>(getpid());
    // 新契约的设备要求不依赖窗口库；旧 SDL requirement 只允许原 provider，不能借名放开 GLFW。
    const bool mobileGlRequirement =
        (requirementId == "mobilegl-direct-vulkan-v1" && (windowProvider == "GLFW" || windowProvider == "SDL3")) ||
        (requirementId == "mobilegl-sdl3-validation-v1" && windowProvider == "SDL3");
    if (profileId == "mobilegl" && mobileGlRequirement) {
        if (availabilityOnly) {
            result = queryMobileGlDevice("");
            result.profileId = profileId; result.requirementId = requirementId;
            result.windowProvider = windowProvider;
            result.nativeArtifacts = artifactExists(nativeLibraryDir, "libmobilegl.so") &&
                artifactExists(nativeLibraryDir, windowProvider == "SDL3" ? "libSDL3.so" : "libglfw.so") && artifactExists(nativeLibraryDir, "liblwjgl.so")
                ? CapabilityEvidence::Yes : CapabilityEvidence::No;
            return result;
        }
        return ProbeMobileGlCapability(nativeLibraryDir, queryMobileGlDevice, windowProvider, requirementId).capability;
    }
    const bool isMinecraft262 = profileId == "minecraft-vulkan" &&
        requirementId == "minecraft-26.2-conservative-v1" && windowProvider == "GLFW";
    const bool isMinecraft263 = profileId == "minecraft-vulkan" && windowProvider == "SDL3" &&
        (requirementId == "minecraft-26.3-pre1-vulkan-conservative-v1" ||
         requirementId == "minecraft-26.3-sdl-vulkan-conservative-v1");
    const bool isMinecraft264 = profileId == "minecraft-vulkan" && windowProvider == "SDL3" &&
        requirementId == "minecraft-26.4-snapshot1-sdl-vulkan-v1";
    const bool isMinecraftSdl = isMinecraft263 || isMinecraft264;
    if (!isMinecraft262 && !isMinecraftSdl) {
        result.reasonCode = "profile_requirement_probe_not_implemented";
        return result;
    }
#ifdef AMCL_HAVE_VULKAN_HEADERS
    const VkScanResult scan = scanVulkan(nullptr, !availabilityOnly);
    // 这是启动准入所选物理设备的探测事实，不冒充游戏已成功创建交换链。
    if (scan.hasDevice) {
        amclLogWriteFor(amclLedgerGetLaunchActivity(), AMCL_LOG_LEVEL_INFO, "SessionEnvironment",
            "AMCL_ENV_V1\tgpu.probeModel\t%s\tVulkan.admission-probe", scan.deviceName.c_str());
        amclLogWriteFor(amclLedgerGetLaunchActivity(), AMCL_LOG_LEVEL_INFO, "SessionEnvironment",
            "AMCL_ENV_V1\tgpu.driver\t%s\tVulkan.admission-probe", scan.driverName.c_str());
    }
    result.loader = scan.libLoaded ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    result.instance = !scan.libLoaded ? CapabilityEvidence::NotRun :
        (scan.instanceCreated ? CapabilityEvidence::Yes : CapabilityEvidence::No);
    result.physicalDevice = !scan.instanceCreated ? CapabilityEvidence::NotRun :
        (scan.hasDevice ? CapabilityEvidence::Yes : CapabilityEvidence::No);
    result.apiVersion = scan.deviceApiVersion;
    result.driverIdentity = scan.driverIdentity;
    result.observedProvider = scan.driverName.empty() ? scan.deviceName : scan.driverName;
    result.windowSurface = scan.surfaceEvidence;
    result.queuePresentation = scan.presentEvidence;
    result.nativeWindowGeneration = scan.surfaceGeneration;
    // 只投影统一评估的结果，不再次维护 feature/extension 表达式。
    // 未找到设备时保留 NOT_RUN；缺失平台 surface 扩展即使尚未建窗口也明确拒绝。
    const auto requirement = AssessMinecraftVulkanRequirement(minecraftRequirementFacts(scan), requirementId);
    if (scan.hasDevice) {
        result.deviceExtensions = requirement.deviceExtensions;
        result.featureBits = requirement.featureBits;
    }
    if (scan.instanceCreated && (!scan.hasKhrSurface || !scan.hasOhosSurface)) {
        result.windowSurface = CapabilityEvidence::No;
    }
    const bool artifacts = artifactExists(nativeLibraryDir, "liblwjgl.so") &&
        artifactExists(nativeLibraryDir, "libamcl_vulkan_wsi.so") &&
        artifactExists(nativeLibraryDir, "libshaderc.so") && artifactExists(nativeLibraryDir, "libspirv-cross.so") &&
        artifactExists(nativeLibraryDir, windowProvider == "SDL3" ? "libSDL3.so" : "libglfw.so") &&
        (!isMinecraftSdl || artifactExists(nativeLibraryDir, "liblwjgl_vma.so"));
    result.nativeArtifacts = artifacts ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    std::string shaderReason;
    if (!availabilityOnly && artifactExists(nativeLibraryDir, "libshaderc.so") && artifactExists(nativeLibraryDir, "libspirv-cross.so")) {
        result.shaderToolchain = probeShaderToolchain(nativeLibraryDir, shaderReason) ? CapabilityEvidence::Yes : CapabilityEvidence::No;
    }
    std::string deviceReason;
    const bool deviceReady = isMinecraftSdl ? capabilityAvailableSdl(scan, deviceReason, requirementId.c_str())
        : capabilityAvailable(scan, deviceReason) && synchronization2Usable(scan);
    // 各代必须共同消费方向证据。仅SDL承担它自己的其余surface要求，不能让GLFW
    // 因未走SDL条件而越过方向门，也不能把窗口尚未查询的设置页误写成实机失败。
    if (!availabilityOnly && (scan.surfaceOrientationEvidence != CapabilityEvidence::Yes ||
        (isMinecraftSdl && (!scan.surfaceContractQueried || !scan.sdlSurfaceContract)))) {
        result.windowSurface = CapabilityEvidence::No;
    }
    result.reasonCode = !deviceReady ? (deviceReason.empty() ? "synchronization2_feature_missing" : deviceReason) :
        (result.windowSurface != CapabilityEvidence::Yes || result.queuePresentation != CapabilityEvidence::Yes) ? scan.surfaceReason :
        !artifacts ? "native_artifact_missing" : result.shaderToolchain != CapabilityEvidence::Yes ? shaderReason : "launch_prerequisites_verified";
#else
    result.reasonCode = "vulkan_headers_unavailable";
#endif
    return result;
}

std::string MobileGlCapabilityDiagnosticReport() {
    return ProbeMobileGlCapability(nativeProbeLibraryDirectory(), queryMobileGlDevice).text();
}

} // namespace amcl::graphics

extern "C" const char* getGraphicsCapabilityJson(const char* profileId,
    const char* requirementId, const char* windowProvider, bool availabilityOnly) {
    static thread_local std::string json;
    const std::string directory = amcl::graphics::nativeProbeLibraryDirectory();
    const amcl::graphics::GraphicsCapability result = amcl::graphics::ProbeGraphicsCapability(
        profileId ? profileId : "", requirementId ? requirementId : "", windowProvider ? windowProvider : "", directory, availabilityOnly);
#ifdef AMCL_HAVE_VULKAN_HEADERS
    using amcl::graphics::CapabilityEvidence;
    auto evidenceName = [](CapabilityEvidence evidence) {
        switch (evidence) {
            case CapabilityEvidence::Yes: return "YES";
            case CapabilityEvidence::No: return "NO";
            case CapabilityEvidence::Unknown: return "UNKNOWN";
            default: return "NOT_RUN";
        }
    };
    std::ostringstream stream;
    stream << "{\"evidenceProfileId\":\"" << jsonEscape(result.profileId)
        << "\",\"requirementId\":\"" << jsonEscape(result.requirementId)
        << "\",\"windowProvider\":\"" << jsonEscape(result.windowProvider) << "\"";
    auto field = [&](const char* name, CapabilityEvidence evidence) {
        stream << ",\"" << name << "\":\"" << evidenceName(evidence) << "\"";
    };
    field("loader", result.loader); field("instance", result.instance);
    field("physicalDevice", result.physicalDevice); field("windowSurface", result.windowSurface);
    field("deviceExtensions", result.deviceExtensions); field("featureBits", result.featureBits);
    field("queuePresentation", result.queuePresentation); field("shaderToolchain", result.shaderToolchain);
    field("nativeArtifacts", result.nativeArtifacts); field("lifecycleSmoke", result.lifecycleSmoke);
    stream << ",\"apiVersion\":\"" << jsonEscape(result.apiVersion)
        << "\",\"reasonCode\":\"" << jsonEscape(result.reasonCode)
        << "\",\"observedProvider\":\"" << jsonEscape(result.observedProvider)
        << "\",\"driverIdentity\":\"" << jsonEscape(result.driverIdentity)
        << "\",\"observedUnderlyingVulkan\":\"UNKNOWN\"}";
    json = stream.str();
#else
    json = "{\"reasonCode\":\"vulkan_headers_unavailable\"}";
#endif
    return json.c_str();
}

extern "C" const char* getVulkanInfo() {
    static std::string info;
#ifdef AMCL_HAVE_VULKAN_HEADERS
    std::ostringstream ss;
    ss << "===== Vulkan 能力探针（Phase 0）=====\n\n";
    VkScanResult r = scanVulkan(&ss);

    std::string reason;
    std::string warn;
    bool ok = capabilityAvailable(r, reason, warn);
    ss << "\n===== 26.2 兼容设备检查（非所有版本结论）=====\n";
    if (ok) {
        ss << "✅ 设备枚举满足 26.2 Vulkan 门槛\n";
        if (!warn.empty()) ss << "⚠️ 注意: " << warn << "\n";
    } else {
        ss << "❌ 未满足 26.2 要求：" << reason << "\n";
    }
    if (r.hasDevice) {
        ss << "\n--- 摘要 ---\n";
        ss << "设备: " << r.deviceName << "（" << r.vendorName << "）\n";
        ss << "Vulkan: " << r.deviceApiVersion
           << (r.deviceApiRaw >= VK_API_VERSION_1_3 ? "（core 1.3+）" : "") << "\n";
        if (r.hasDriverProps) ss << "驱动: " << r.driverName << " · CTS " << r.conformanceVersion << "\n";
        ss << "dynamicRendering: "
           << (dynamicRenderingUsable(r) ? "可用" : "不可用")
           << (r.featuresQueried ? "（实查 feature bit）" : "（按扩展/ core 推断）") << "\n";
        ss << "synchronization2: " << (synchronization2Usable(r) ? "可用" : "不可用") << "\n";
        ss << "pushDescriptor: " << (r.hasPushDescriptor ? "可用" : "不可用")
           << (r.maxPushDescriptors ? "（max=" + std::to_string(r.maxPushDescriptors) + "）" : "") << "\n";
    }

    // Zink (GL-on-Vulkan) 可行性估算（Phase 0 决策门）
    {
        auto z = estimateZinkGl(r);
        ss << "\n===== Zink / Voxy 可行性（Phase 0）=====\n";
        ss << "Zink 可达 GL 估算: " << z.first << "\n";
        ss << "够 Voxy 吗: " << (z.second ? "✅ 有戏（值得投入 Mesa+Zink 移植）"
                                          : "❌ 不够（即便移植 Zink，Voxy 仍多半不可用）") << "\n";
        if (r.baseFeaturesQueried) {
            ss << "关键缺失项: ";
            std::string miss;
            auto add = [&](const char* n, bool ok){ if(!ok){ if(!miss.empty()) miss+=", "; miss+=n; } };
            add("geometryShader", r.fGeometryShader);
            add("tessellationShader", r.fTessellationShader);
            add("multiDrawIndirect", r.fMultiDrawIndirect);
            add("drawIndirectFirstInstance", r.fDrawIndirectFirstInstance);
            add("fragmentStoresAndAtomics", r.fFragmentStoresAndAtomics);
            add("fillModeNonSolid", r.fFillModeNonSolid);
            add("shaderFloat64", r.fShaderFloat64);
            add("logicOp", r.fLogicOp);
            ss << (miss.empty() ? "（无，核心齐备）" : miss) << "\n";
        }
    }
    ss << "\n注：此报告只盘点设备能力；实际启动另查窗口呈现、运行库和着色器工具链。\n"
          "    26.2/26.3 仍要求 push_descriptor；26.4 Snapshot 1 已移除它与 dynamic rendering 的要求。\n"
          "    请在渲染器设置中按已安装版本核对准入，不能把上述 26.2 结论套用到 26.4。\n"
          "    未执行的生命周期测试保持 NOT_RUN，不能据此声称游戏已经运行。\n";
    info = ss.str();
#else
    info = "Vulkan 探针不可用：编译期未找到 <vulkan/vulkan.h>（OHOS NDK 头缺失）。\n"
           "确认 SDK API >= 10 并提供 vulkan 头后重编。";
#endif
    // 诊断：把完整报告按行打到 hilog（hilog 单行会截断，故逐行输出），便于 hdc 直接拉取。
    {
        size_t start = 0;
        int lineNo = 0;
        const std::string& s = info;
        while (start <= s.size()) {
            size_t nl = s.find('\n', start);
            std::string line = (nl == std::string::npos) ? s.substr(start) : s.substr(start, nl - start);
            OH_LOG_INFO(LOG_APP, "VKREPORT|%{public}03d|%{public}s", lineNo++, line.c_str());
            if (nl == std::string::npos) break;
            start = nl + 1;
        }
    }
    return info.c_str();
}

extern "C" const char* getVulkanCapabilityJson() {
    static std::string json;
#ifdef AMCL_HAVE_VULKAN_HEADERS
    VkScanResult r = scanVulkan(nullptr);
    std::string reason;
    std::string warn;
    bool ok = capabilityAvailable(r, reason, warn);

    std::ostringstream ss;
    ss << "{"
       << "\"available\":" << jsonBool(ok)
       << ",\"reason\":\"" << jsonEscape(reason) << "\""
       << ",\"warning\":\"" << jsonEscape(warn) << "\""
       << ",\"loaderVersion\":\"" << jsonEscape(r.loaderVersion) << "\""
       << ",\"deviceName\":\"" << jsonEscape(r.deviceName) << "\""
       << ",\"deviceType\":\"" << jsonEscape(r.deviceType) << "\""
       << ",\"vendorName\":\"" << jsonEscape(r.vendorName) << "\""
       << ",\"vendorId\":" << r.vendorID
       << ",\"deviceId\":" << r.deviceID
       << ",\"deviceApiVersion\":\"" << jsonEscape(r.deviceApiVersion) << "\""
       << ",\"deviceLocalMemoryMB\":" << (r.deviceLocalMemoryBytes / (1024ull * 1024ull))
       << ",\"driverName\":\"" << jsonEscape(r.driverName) << "\""
       << ",\"driverInfo\":\"" << jsonEscape(r.driverInfo) << "\""
       << ",\"conformanceVersion\":\"" << jsonEscape(r.conformanceVersion) << "\""
       << ",\"hasOhosSurface\":" << jsonBool(r.hasOhosSurface)
       << ",\"hasSwapchain\":" << jsonBool(r.hasSwapchain)
       << ",\"hasDynamicRendering\":" << jsonBool(r.hasDynamicRendering)
       << ",\"hasPushDescriptor\":" << jsonBool(r.hasPushDescriptor)
       << ",\"hasSynchronization2\":" << jsonBool(r.hasSynchronization2)
       << ",\"featuresQueried\":" << jsonBool(r.featuresQueried)
       << ",\"dynamicRenderingFeature\":" << jsonBool(r.featDynamicRendering)
       << ",\"synchronization2Feature\":" << jsonBool(r.featSynchronization2)
       << ",\"maxPushDescriptors\":" << r.maxPushDescriptors
       << ",\"zinkGlEstimate\":\"" << jsonEscape(estimateZinkGl(r).first) << "\""
       << ",\"zinkEnoughForVoxy\":" << jsonBool(estimateZinkGl(r).second)
       << ",\"baseFeaturesQueried\":" << jsonBool(r.baseFeaturesQueried)
       << ",\"geometryShader\":" << jsonBool(r.fGeometryShader)
       << ",\"tessellationShader\":" << jsonBool(r.fTessellationShader)
       << ",\"multiDrawIndirect\":" << jsonBool(r.fMultiDrawIndirect)
       << ",\"drawIndirectFirstInstance\":" << jsonBool(r.fDrawIndirectFirstInstance)
       << ",\"fragmentStoresAndAtomics\":" << jsonBool(r.fFragmentStoresAndAtomics)
       << ",\"shaderStorageImageExtendedFormats\":" << jsonBool(r.fShaderStorageImageExtendedFormats)
       << ",\"fillModeNonSolid\":" << jsonBool(r.fFillModeNonSolid)
       << ",\"logicOp\":" << jsonBool(r.fLogicOp)
       << ",\"shaderFloat64\":" << jsonBool(r.fShaderFloat64)
       << ",\"shaderInt64\":" << jsonBool(r.fShaderInt64)
       << ",\"imageCubeArray\":" << jsonBool(r.fImageCubeArray)
       << ",\"textureCompressionBC\":" << jsonBool(r.fTextureCompressionBC)
       << ",\"maxComputeSharedMemorySize\":" << r.maxComputeSharedMemorySize
       << ",\"maxComputeWorkGroupInvocations\":" << r.maxComputeWorkGroupInvocations
       << ",\"maxPerStageDescriptorStorageBuffers\":" << r.maxPerStageDescriptorStorageBuffers
       << ",\"maxStorageBufferRangeMB\":" << r.maxStorageBufferRangeMB
       << "}";
    json = ss.str();
    OH_LOG_INFO(LOG_APP, "getVulkanCapabilityJson() available=%{public}d reason=%{public}s",
                ok ? 1 : 0, reason.c_str());
#else
    json = "{\"available\":false,\"reason\":\"Vulkan headers unavailable at compile time\","
           "\"warning\":\"\","
           "\"loaderVersion\":\"\",\"deviceName\":\"\",\"deviceType\":\"\",\"vendorName\":\"\","
           "\"vendorId\":0,\"deviceId\":0,\"deviceApiVersion\":\"\",\"deviceLocalMemoryMB\":0,"
           "\"driverName\":\"\",\"driverInfo\":\"\",\"conformanceVersion\":\"\","
           "\"hasOhosSurface\":false,\"hasSwapchain\":false,\"hasDynamicRendering\":false,"
           "\"hasPushDescriptor\":false,\"hasSynchronization2\":false,\"featuresQueried\":false,"
           "\"dynamicRenderingFeature\":false,\"synchronization2Feature\":false,\"maxPushDescriptors\":0}";
#endif
    return json.c_str();
}

extern "C" int amclVulkanUsableForMc(void) {
#ifdef AMCL_HAVE_VULKAN_HEADERS
    VkScanResult r = scanVulkan(nullptr);
    std::string reason;
    bool ok = capabilityAvailable(r, reason);
    OH_LOG_INFO(LOG_APP, "amclVulkanUsableForMc() = %{public}d (%{public}s)",
                ok ? 1 : 0, ok ? "usable" : reason.c_str());
    return ok ? 1 : 0;
#else
    return 0;
#endif
}

#ifdef MC_OHOS_BUILD_TESTS
// ============================================================================
//  Vulkan 实战自检（Phase B）：真的建 surface + swapchain + 渲染一帧 + present
// ============================================================================
//
// 设计哲学：每一步打印 ✅/❌ + VkResult，任何一步失败立即停止并返回到目前为止的报告，
// 这样华为驱动在哪一环断一目了然。全程 vkGetInstanceProcAddr / vkGetDeviceProcAddr 动态解析，
// 不在链接期依赖 libvulkan。结束时严格逆序销毁所有已创建对象。

#ifdef AMCL_HAVE_VULKAN_HEADERS
namespace {

// 解析系统 libvulkan.so 的 vkGetInstanceProcAddr（与 scanVulkan 同源，但本函数需要持有 lib 句柄
// 直到自检结束，故不复用 scanVulkan 的局部 dlopen）。
PFN_vkGetInstanceProcAddr selfTestLoadGipa(void** outLib, std::ostringstream& log) {
    void* lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        log << "❌ [1] dlopen(libvulkan.so) 失败：本机无 Vulkan loader\n";
        return nullptr;
    }
    auto gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(lib, "vkGetInstanceProcAddr"));
    if (!gipa) {
        log << "❌ [1] dlsym(vkGetInstanceProcAddr) 失败\n";
        dlclose(lib);
        return nullptr;
    }
    log << "✅ [1] libvulkan.so + vkGetInstanceProcAddr 就绪\n";
    *outLib = lib;
    return gipa;
}

std::string vkResultName(VkResult r) {
    switch (r) {
        case VK_SUCCESS: return "VK_SUCCESS";
        case VK_NOT_READY: return "VK_NOT_READY";
        case VK_TIMEOUT: return "VK_TIMEOUT";
        case VK_SUBOPTIMAL_KHR: return "VK_SUBOPTIMAL_KHR";
        case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
        case VK_ERROR_EXTENSION_NOT_PRESENT: return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT: return "VK_ERROR_FEATURE_NOT_PRESENT";
        case VK_ERROR_SURFACE_LOST_KHR: return "VK_ERROR_SURFACE_LOST_KHR";
        case VK_ERROR_OUT_OF_DATE_KHR: return "VK_ERROR_OUT_OF_DATE_KHR";
        case VK_ERROR_NATIVE_WINDOW_IN_USE_KHR: return "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR";
        default: return "VkResult(" + std::to_string((int)r) + ")";
    }
}

// 自检主体。把所有 Vulkan 句柄放局部变量，用 goto-free 的「步骤 + 提前 return cleanup」结构。
void runSelfTestImpl(unsigned long long nativeWindowPtr, std::ostringstream& log) {
    void* lib = nullptr;
    PFN_vkGetInstanceProcAddr gipa = selfTestLoadGipa(&lib, log);
    if (!gipa) return;

    // ---- 解析全局/实例级函数 ----
    auto pfnCreateInstance = reinterpret_cast<PFN_vkCreateInstance>(
        gipa(VK_NULL_HANDLE, "vkCreateInstance"));
    auto pfnEnumInstExt = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
        gipa(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
    if (!pfnCreateInstance) {
        log << "❌ [2] 解析 vkCreateInstance 失败\n";
        dlclose(lib);
        return;
    }

    // ---- 2) 查实例扩展并创建带 surface 扩展的 instance ----
    bool hasKhrSurface = false, hasOhosSurface = false;
    if (pfnEnumInstExt) {
        uint32_t n = 0;
        pfnEnumInstExt(nullptr, &n, nullptr);
        std::vector<VkExtensionProperties> exts(n);
        if (n) pfnEnumInstExt(nullptr, &n, exts.data());
        for (auto& e : exts) {
            if (std::strcmp(e.extensionName, "VK_KHR_surface") == 0) hasKhrSurface = true;
            else if (std::strcmp(e.extensionName, "VK_OHOS_surface") == 0) hasOhosSurface = true;
        }
    }
    std::vector<const char*> instExts;
    if (hasKhrSurface) instExts.push_back("VK_KHR_surface");
#ifdef AMCL_HAVE_VULKAN_OHOS
    if (hasOhosSurface) instExts.push_back(VK_OHOS_SURFACE_EXTENSION_NAME);
#endif

    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "AMCL Vulkan SelfTest";
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = static_cast<uint32_t>(instExts.size());
    ici.ppEnabledExtensionNames = instExts.empty() ? nullptr : instExts.data();

    VkInstance instance = VK_NULL_HANDLE;
    VkResult rc = pfnCreateInstance(&ici, nullptr, &instance);
    if (rc != VK_SUCCESS) {
        log << "❌ [2] vkCreateInstance 失败: " << vkResultName(rc) << "\n";
        dlclose(lib);
        return;
    }
    log << "✅ [2] vkCreateInstance OK（surface 扩展: KHR=" << (hasKhrSurface ? "✓" : "✗")
        << " OHOS=" << (hasOhosSurface ? "✓" : "✗") << "）\n";

    // ---- 解析实例函数 ----
    auto I = [&](const char* n) { return gipa(instance, n); };
    auto pfnDestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(I("vkDestroyInstance"));
    auto pfnEnumPhys = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(I("vkEnumeratePhysicalDevices"));
    auto pfnGetProps = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(I("vkGetPhysicalDeviceProperties"));
    auto pfnGetQF = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        I("vkGetPhysicalDeviceQueueFamilyProperties"));
    auto pfnEnumDevExt = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
        I("vkEnumerateDeviceExtensionProperties"));
    auto pfnCreateDevice = reinterpret_cast<PFN_vkCreateDevice>(I("vkCreateDevice"));
    auto pfnGetDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(I("vkGetDeviceProcAddr"));
    auto pfnGetSurfaceSupport = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        I("vkGetPhysicalDeviceSurfaceSupportKHR"));
    auto pfnGetSurfaceCaps = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        I("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    auto pfnGetSurfaceFormats = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        I("vkGetPhysicalDeviceSurfaceFormatsKHR"));
    auto pfnGetSurfacePresentModes = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
        I("vkGetPhysicalDeviceSurfacePresentModesKHR"));
    auto pfnDestroySurface = reinterpret_cast<PFN_vkDestroySurfaceKHR>(I("vkDestroySurfaceKHR"));

    // 统一清理（逆序）。surface/device 句柄随步骤填充。
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    PFN_vkDestroyDevice pfnDestroyDevice = nullptr;
    void* leasedNativeWindow = nullptr;
    void* nativeWindowLeaseBroker = nullptr;
    auto releaseNativeWindowLease = [&]() {
        if (leasedNativeWindow && nativeWindowLeaseBroker) {
            glfwOHOS_ReleaseNativeWindowLease(leasedNativeWindow,
                                              nativeWindowLeaseBroker);
        }
        leasedNativeWindow = nullptr;
        nativeWindowLeaseBroker = nullptr;
    };
    auto cleanup = [&]() {
        if (device && pfnDestroyDevice) pfnDestroyDevice(device, nullptr);
        if (surface && pfnDestroySurface) pfnDestroySurface(instance, surface, nullptr);
        releaseNativeWindowLease();
        if (instance && pfnDestroyInstance) pfnDestroyInstance(instance, nullptr);
        dlclose(lib);
    };

    if (!pfnEnumPhys || !pfnGetProps || !pfnGetQF || !pfnCreateDevice || !pfnGetDeviceProcAddr) {
        log << "❌ [3] 解析物理设备/逻辑设备函数失败\n";
        cleanup();
        return;
    }

    // ---- 3) 选物理设备（优先 core>=1.2）----
    uint32_t gpuCount = 0;
    pfnEnumPhys(instance, &gpuCount, nullptr);
    if (gpuCount == 0) {
        log << "❌ [3] 无 Vulkan 物理设备\n";
        cleanup();
        return;
    }
    std::vector<VkPhysicalDevice> gpus(gpuCount);
    pfnEnumPhys(instance, &gpuCount, gpus.data());
    VkPhysicalDevice gpu = gpus[0];
    for (uint32_t i = 0; i < gpuCount; ++i) {
        VkPhysicalDeviceProperties p{};
        pfnGetProps(gpus[i], &p);
        if (p.apiVersion >= VK_API_VERSION_1_2) { gpu = gpus[i]; break; }
    }
    VkPhysicalDeviceProperties gprops{};
    pfnGetProps(gpu, &gprops);
    log << "✅ [3] 选中物理设备: " << gprops.deviceName << "（Vulkan "
        << apiVersionToString(gprops.apiVersion) << "）\n";

    // ---- 4) 取 NativeWindow + 创建 OHOS surface ----
    int leasedWidth = 0;
    int leasedHeight = 0;
    uint64_t leasedGeneration = 0;
    glfwOHOS_AcquireNativeWindowSnapshot(
        nullptr, 0, nullptr, &leasedNativeWindow, &leasedWidth, &leasedHeight,
        &leasedGeneration, &nativeWindowLeaseBroker);
    unsigned long long nw =
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(leasedNativeWindow));
    if (nativeWindowPtr && nativeWindowPtr != nw) {
        log << "⚠️ [4] 调用方 NativeWindow 已不是当前受租约保护的 surface → 拒绝 raw ptr\n";
        releaseNativeWindowLease();
        nw = 0;
    }
    bool doPresent = false;
#ifdef AMCL_HAVE_VULKAN_OHOS
    if (nw) {
        auto pfnCreateSurfaceOHOS = reinterpret_cast<PFN_vkCreateSurfaceOHOS>(I("vkCreateSurfaceOHOS"));
        if (!pfnCreateSurfaceOHOS) {
            log << "⚠️ [4] vkCreateSurfaceOHOS 未找到（VK_OHOS_surface 未启用）→ 跳过 surface/swapchain\n";
        } else {
            VkSurfaceCreateInfoOHOS sinfo{};
            sinfo.sType = kStypeSurfaceCreateInfoOHOS;
            sinfo.window = reinterpret_cast<OHNativeWindow*>(static_cast<uintptr_t>(nw));
            rc = pfnCreateSurfaceOHOS(instance, &sinfo, nullptr, &surface);
            if (rc != VK_SUCCESS) {
                log << "❌ [4] vkCreateSurfaceOHOS 失败: " << vkResultName(rc) << "\n";
            } else {
                log << "✅ [4] vkCreateSurfaceOHOS OK（NativeWindow=0x" << std::hex << nw << std::dec << "）\n";
                doPresent = true;
            }
        }
    } else {
        log << "⚠️ [4] 无可租用的当前 NativeWindow → 仅做到设备+队列层面\n";
    }
#else
    log << "⚠️ [4] 编译期无 vulkan_ohos.h → 无法建 OHOS surface\n";
#endif

    // ---- 5) 选队列族（图形 + 呈现）----
    uint32_t qn = 0;
    pfnGetQF(gpu, &qn, nullptr);
    std::vector<VkQueueFamilyProperties> qf(qn);
    if (qn) pfnGetQF(gpu, &qn, qf.data());
    int graphicsFam = -1, presentFam = -1;
    for (uint32_t q = 0; q < qn; ++q) {
        if ((qf[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) && graphicsFam < 0) graphicsFam = (int)q;
        if (surface && pfnGetSurfaceSupport) {
            VkBool32 sup = VK_FALSE;
            pfnGetSurfaceSupport(gpu, q, surface, &sup);
            if (sup && presentFam < 0) presentFam = (int)q;
        }
    }
    if (graphicsFam < 0) {
        log << "❌ [5] 无图形队列族\n";
        cleanup();
        return;
    }
    if (surface && presentFam < 0) presentFam = graphicsFam;  // 多数移动 GPU 图形=呈现同族
    log << "✅ [5] 队列族: graphics=" << graphicsFam
        << (surface ? (" present=" + std::to_string(presentFam)) : std::string("（无 surface，不查 present）")) << "\n";

    // ---- 6) 创建逻辑设备（带 swapchain 扩展，若要 present）----
    float prio = 1.0f;
    std::vector<VkDeviceQueueCreateInfo> qcis;
    {
        VkDeviceQueueCreateInfo q{};
        q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        q.queueFamilyIndex = (uint32_t)graphicsFam;
        q.queueCount = 1;
        q.pQueuePriorities = &prio;
        qcis.push_back(q);
        if (surface && presentFam != graphicsFam) {
            q.queueFamilyIndex = (uint32_t)presentFam;
            qcis.push_back(q);
        }
    }
    std::vector<const char*> devExts;
    if (doPresent) devExts.push_back("VK_KHR_swapchain");
    VkDeviceCreateInfo dci{};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = (uint32_t)qcis.size();
    dci.pQueueCreateInfos = qcis.data();
    dci.enabledExtensionCount = (uint32_t)devExts.size();
    dci.ppEnabledExtensionNames = devExts.empty() ? nullptr : devExts.data();

    rc = pfnCreateDevice(gpu, &dci, nullptr, &device);
    if (rc != VK_SUCCESS) {
        log << "❌ [6] vkCreateDevice 失败: " << vkResultName(rc) << "\n";
        cleanup();
        return;
    }
    pfnDestroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(I("vkDestroyDevice"));
    log << "✅ [6] vkCreateDevice OK（"
        << (doPresent ? "含 VK_KHR_swapchain" : "无 swapchain，仅设备层") << "）\n";

    // 设备级函数
    auto D = [&](const char* n) { return pfnGetDeviceProcAddr(device, n); };
    auto pfnGetDeviceQueue = reinterpret_cast<PFN_vkGetDeviceQueue>(D("vkGetDeviceQueue"));
    VkQueue gfxQueue = VK_NULL_HANDLE, presQueue = VK_NULL_HANDLE;
    if (pfnGetDeviceQueue) {
        pfnGetDeviceQueue(device, (uint32_t)graphicsFam, 0, &gfxQueue);
        pfnGetDeviceQueue(device, (uint32_t)presentFam, 0, &presQueue);
    }

    // ---- 没有 surface：到此为止（设备+队列已验证）----
    if (!doPresent) {
        log << "✅ [7] 设备 + 队列就绪。无 surface，跳过 swapchain/present。\n";
        log << "\n小结：实例/物理设备/逻辑设备/队列链路通。\n"
               "在 XComponent 页面（带 NativeWindow）再跑一次即可验证 surface→present 全链路。\n";
        cleanup();
        return;
    }

#ifdef AMCL_HAVE_VULKAN_OHOS
    // ---- 7) 查 surface 能力 / 格式 / 呈现模式 ----
    VkSurfaceCapabilitiesKHR caps{};
    if (pfnGetSurfaceCaps) pfnGetSurfaceCaps(gpu, surface, &caps);
    uint32_t fmtN = 0;
    if (pfnGetSurfaceFormats) pfnGetSurfaceFormats(gpu, surface, &fmtN, nullptr);
    std::vector<VkSurfaceFormatKHR> fmts(fmtN);
    if (fmtN && pfnGetSurfaceFormats) pfnGetSurfaceFormats(gpu, surface, &fmtN, fmts.data());
    uint32_t pmN = 0;
    if (pfnGetSurfacePresentModes) pfnGetSurfacePresentModes(gpu, surface, &pmN, nullptr);
    if (fmtN == 0 || pmN == 0) {
        log << "❌ [7] surface 无可用格式(" << fmtN << ")或呈现模式(" << pmN << ")\n";
        cleanup();
        return;
    }
    VkSurfaceFormatKHR chosenFmt = fmts[0];
    for (auto& f : fmts) {
        if (f.format == VK_FORMAT_B8G8R8A8_UNORM || f.format == VK_FORMAT_R8G8B8A8_UNORM) { chosenFmt = f; break; }
    }
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == 0xFFFFFFFFu) { extent.width = 640; extent.height = 480; }
    log << "✅ [7] surface 能力 OK（格式数=" << fmtN << " 呈现模式数=" << pmN
        << " 选定格式=" << (int)chosenFmt.format << " 尺寸=" << extent.width << "x" << extent.height << "）\n";

    // ---- 8) 创建 swapchain ----
    auto pfnCreateSwapchain = reinterpret_cast<PFN_vkCreateSwapchainKHR>(D("vkCreateSwapchainKHR"));
    auto pfnDestroySwapchain = reinterpret_cast<PFN_vkDestroySwapchainKHR>(D("vkDestroySwapchainKHR"));
    auto pfnGetSwapchainImages = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(D("vkGetSwapchainImagesKHR"));
    auto pfnAcquireNext = reinterpret_cast<PFN_vkAcquireNextImageKHR>(D("vkAcquireNextImageKHR"));
    auto pfnQueuePresent = reinterpret_cast<PFN_vkQueuePresentKHR>(D("vkQueuePresentKHR"));
    if (!pfnCreateSwapchain || !pfnGetSwapchainImages || !pfnAcquireNext || !pfnQueuePresent) {
        log << "❌ [8] 解析 swapchain 设备函数失败\n";
        cleanup();
        return;
    }
    uint32_t minImg = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && minImg > caps.maxImageCount) minImg = caps.maxImageCount;

    // TRANSFER_DST 让我们能用 vkCmdClearColorImage 直接清屏（不必建 render pass/pipeline）。
    // 但必须确认 surface 支持该 usage，否则回退到只用 COLOR_ATTACHMENT（届时跳过 clear）。
    bool canTransferDst =
        (caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0;
    VkImageUsageFlags imgUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (canTransferDst) imgUsage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;

    // compositeAlpha 取 surface 支持的第一个可用位（OPAQUE 优先）。
    VkCompositeAlphaFlagBitsKHR compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)) {
        const VkCompositeAlphaFlagBitsKHR candidates[] = {
            VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
            VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
            VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        };
        for (auto c : candidates) {
            if (caps.supportedCompositeAlpha & c) { compositeAlpha = c; break; }
        }
    }

    VkSwapchainCreateInfoKHR sci{};
    sci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    sci.surface = surface;
    sci.minImageCount = minImg;
    sci.imageFormat = chosenFmt.format;
    sci.imageColorSpace = chosenFmt.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = imgUsage;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform = (caps.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
                       ? VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR : caps.currentTransform;
    sci.compositeAlpha = compositeAlpha;
    sci.presentMode = VK_PRESENT_MODE_FIFO_KHR;   // FIFO 必然支持
    sci.clipped = VK_TRUE;

    uint32_t qfIdx[2] = { (uint32_t)graphicsFam, (uint32_t)presentFam };
    if (graphicsFam != presentFam) {
        sci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
        sci.queueFamilyIndexCount = 2;
        sci.pQueueFamilyIndices = qfIdx;
    }

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    rc = pfnCreateSwapchain(device, &sci, nullptr, &swapchain);
    if (rc != VK_SUCCESS) {
        log << "❌ [8] vkCreateSwapchainKHR 失败: " << vkResultName(rc) << "\n";
        cleanup();
        return;
    }
    log << "✅ [8] vkCreateSwapchainKHR OK（imageCount>=" << minImg
        << " presentMode=FIFO）\n";

    // 重新定义 cleanup 以包含 swapchain（之前的 cleanup 不含）。这里手动按逆序销毁。
    auto fullCleanup = [&]() {
        if (swapchain && pfnDestroySwapchain) pfnDestroySwapchain(device, swapchain, nullptr);
        if (device && pfnDestroyDevice) pfnDestroyDevice(device, nullptr);
        if (surface && pfnDestroySurface) pfnDestroySurface(instance, surface, nullptr);
        releaseNativeWindowLease();
        if (instance && pfnDestroyInstance) pfnDestroyInstance(instance, nullptr);
        dlclose(lib);
    };

    // ---- 9) 取 swapchain images ----
    uint32_t imgN = 0;
    pfnGetSwapchainImages(device, swapchain, &imgN, nullptr);
    std::vector<VkImage> images(imgN);
    if (imgN) pfnGetSwapchainImages(device, swapchain, &imgN, images.data());
    if (imgN == 0) {
        log << "❌ [9] swapchain 无 image\n";
        fullCleanup();
        return;
    }
    log << "✅ [9] 取得 " << imgN << " 张 swapchain image\n";

    // ---- 10) command pool + buffer，录制 clear ----
    auto pfnCreateCmdPool = reinterpret_cast<PFN_vkCreateCommandPool>(D("vkCreateCommandPool"));
    auto pfnDestroyCmdPool = reinterpret_cast<PFN_vkDestroyCommandPool>(D("vkDestroyCommandPool"));
    auto pfnAllocCmd = reinterpret_cast<PFN_vkAllocateCommandBuffers>(D("vkAllocateCommandBuffers"));
    auto pfnBeginCmd = reinterpret_cast<PFN_vkBeginCommandBuffer>(D("vkBeginCommandBuffer"));
    auto pfnEndCmd = reinterpret_cast<PFN_vkEndCommandBuffer>(D("vkEndCommandBuffer"));
    auto pfnCmdPipelineBarrier = reinterpret_cast<PFN_vkCmdPipelineBarrier>(D("vkCmdPipelineBarrier"));
    auto pfnCmdClear = reinterpret_cast<PFN_vkCmdClearColorImage>(D("vkCmdClearColorImage"));
    auto pfnCreateSemaphore = reinterpret_cast<PFN_vkCreateSemaphore>(D("vkCreateSemaphore"));
    auto pfnDestroySemaphore = reinterpret_cast<PFN_vkDestroySemaphore>(D("vkDestroySemaphore"));
    auto pfnCreateFence = reinterpret_cast<PFN_vkCreateFence>(D("vkCreateFence"));
    auto pfnDestroyFence = reinterpret_cast<PFN_vkDestroyFence>(D("vkDestroyFence"));
    auto pfnWaitFences = reinterpret_cast<PFN_vkWaitForFences>(D("vkWaitForFences"));
    auto pfnQueueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(D("vkQueueSubmit"));
    auto pfnDeviceWaitIdle = reinterpret_cast<PFN_vkDeviceWaitIdle>(D("vkDeviceWaitIdle"));

    if (!pfnCreateCmdPool || !pfnAllocCmd || !pfnBeginCmd || !pfnEndCmd ||
        !pfnCmdPipelineBarrier || !pfnCmdClear || !pfnCreateSemaphore || !pfnCreateFence ||
        !pfnWaitFences || !pfnQueueSubmit) {
        log << "❌ [10] 解析命令/同步设备函数失败\n";
        fullCleanup();
        return;
    }

    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandPoolCreateInfo pci{};
    pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex = (uint32_t)graphicsFam;
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    rc = pfnCreateCmdPool(device, &pci, nullptr, &pool);
    if (rc != VK_SUCCESS) {
        log << "❌ [10] vkCreateCommandPool 失败: " << vkResultName(rc) << "\n";
        fullCleanup();
        return;
    }
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo cai{};
    cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    pfnAllocCmd(device, &cai, &cmd);

    VkSemaphore semAcquire = VK_NULL_HANDLE, semRender = VK_NULL_HANDLE;
    VkSemaphoreCreateInfo semci{}; semci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    pfnCreateSemaphore(device, &semci, nullptr, &semAcquire);
    pfnCreateSemaphore(device, &semci, nullptr, &semRender);
    VkFence fence = VK_NULL_HANDLE;
    VkFenceCreateInfo fci{}; fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    pfnCreateFence(device, &fci, nullptr, &fence);

    auto frameCleanup = [&]() {
        if (pfnDeviceWaitIdle) pfnDeviceWaitIdle(device);
        if (fence && pfnDestroyFence) pfnDestroyFence(device, fence, nullptr);
        if (semAcquire && pfnDestroySemaphore) pfnDestroySemaphore(device, semAcquire, nullptr);
        if (semRender && pfnDestroySemaphore) pfnDestroySemaphore(device, semRender, nullptr);
        if (pool && pfnDestroyCmdPool) pfnDestroyCmdPool(device, pool, nullptr);
        fullCleanup();
    };
    log << "✅ [10] command pool / buffer / 同步对象就绪\n";

    // ---- 11~15) 持续 present 天蓝色 ~3 秒（180 帧）——步骤 A 决定性测试 ----
    // 纯 Vulkan（不经 zink/Mesa）：每帧 acquire→UNDEFINED→TRANSFER_DST→clear 天蓝→PRESENT_SRC
    // →submit→present→waitFence。肉眼看屏幕是否变蓝，确认本机 OHOS Vulkan WSI 能否给 ArkUI 的
    // XComponent surface 真正上屏（surfaceId 已证与 RS 一致）。
    auto pfnResetFences = reinterpret_cast<PFN_vkResetFences>(D("vkResetFences"));
    const int kFrames = 180;
    int presented = 0;
    for (int f = 0; f < kFrames; f++) {
        uint32_t imgIdx = 0;
        rc = pfnAcquireNext(device, swapchain, UINT64_MAX, semAcquire, VK_NULL_HANDLE, &imgIdx);
        if (rc != VK_SUCCESS && rc != VK_SUBOPTIMAL_KHR) {
            log << "❌ [11] acquire f=" << f << " 失败: " << vkResultName(rc) << "\n";
            break;
        }

        VkCommandBufferBeginInfo bi{};
        bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        pfnBeginCmd(cmd, &bi);

        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = 1; range.layerCount = 1;

        VkImageMemoryBarrier toDst{};
        toDst.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toDst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        toDst.newLayout = canTransferDst ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        toDst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toDst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toDst.image = images[imgIdx];
        toDst.subresourceRange = range;
        toDst.srcAccessMask = 0;
        toDst.dstAccessMask = canTransferDst ? VK_ACCESS_TRANSFER_WRITE_BIT : 0;
        pfnCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                              canTransferDst ? VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                              0, 0, nullptr, 0, nullptr, 1, &toDst);

        if (canTransferDst) {
            VkClearColorValue clearColor{};
            clearColor.float32[0] = 0.1f; clearColor.float32[1] = 0.5f;
            clearColor.float32[2] = 0.8f; clearColor.float32[3] = 1.0f;  // 天蓝
            pfnCmdClear(cmd, images[imgIdx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clearColor, 1, &range);

            VkImageMemoryBarrier toPresent{};
            toPresent.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
            toPresent.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            toPresent.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            toPresent.image = images[imgIdx];
            toPresent.subresourceRange = range;
            toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            toPresent.dstAccessMask = 0;
            pfnCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                                  0, 0, nullptr, 0, nullptr, 1, &toPresent);
        }
        pfnEndCmd(cmd);

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo si{};
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.waitSemaphoreCount = 1; si.pWaitSemaphores = &semAcquire; si.pWaitDstStageMask = &waitStage;
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        si.signalSemaphoreCount = 1; si.pSignalSemaphores = &semRender;
        if (pfnResetFences) pfnResetFences(device, 1, &fence);
        rc = pfnQueueSubmit(gfxQueue, 1, &si, fence);
        if (rc != VK_SUCCESS) { log << "❌ [13] submit f=" << f << " 失败: " << vkResultName(rc) << "\n"; break; }

        VkPresentInfoKHR pi{};
        pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &semRender;
        pi.swapchainCount = 1; pi.pSwapchains = &swapchain; pi.pImageIndices = &imgIdx;
        rc = pfnQueuePresent(presQueue, &pi);
        if (rc != VK_SUCCESS && rc != VK_SUBOPTIMAL_KHR) { log << "❌ [14] present f=" << f << " 失败: " << vkResultName(rc) << "\n"; break; }
        presented++;

        if (pfnWaitFences) pfnWaitFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
        usleep(16000);  // ~60fps 节奏
        if (f == 0 || f == 60 || f == 120 || f == 179)
            OH_LOG_INFO(LOG_APP, "VKTEST: presented sky-blue frame %{public}d (持续 present 中，看屏幕是否变蓝)", f);
    }
    log << "✅ [11~15] 持续 present 天蓝色 " << presented << " 帧完成（canTransferDst=" << (canTransferDst?1:0) << "）\n";
    log << "\n🎉 步骤 A：若屏幕在自检期间变天蓝色 → OHOS Vulkan WSI 能给 XComponent 上屏（问题在 zink 侧）；\n"
           "    若仍黑 → 本机 Vulkan WSI 无法给 ArkUI XComponent 上屏（平台限制，需改走系统 GLES 上屏）。\n";
    frameCleanup();
#endif // AMCL_HAVE_VULKAN_OHOS
}

} // namespace
#endif // AMCL_HAVE_VULKAN_HEADERS

extern "C" const char* runVulkanSelfTest(unsigned long long nativeWindowPtr) {
    static std::string report;
#ifdef AMCL_HAVE_VULKAN_HEADERS
    std::ostringstream ss;
    ss << "===== Vulkan 实战自检（Phase B · 端到端呈现链）=====\n\n";
    // 在【独立工作线程】跑整套 surface→swapchain→present（模拟 zink 在 MC 渲染线程而非 UI 线程
    // present）。决定性区分：若仍变蓝→present 线程无关；若变黑→ArkUI XComponent 要求在 UI 线程
    // present，正是 zink（渲染线程 present）黑屏之因。join 等其跑完再取报告。
    OH_LOG_INFO(LOG_APP, "VKTEST: 在独立工作线程运行自检（模拟 zink 非 UI 线程 present）");
    std::thread th([&]() {
        runSelfTestImpl(nativeWindowPtr, ss);
    });
    th.join();
    report = ss.str();
#else
    report = "Vulkan 自检不可用：编译期未找到 <vulkan/vulkan.h>（OHOS NDK 头缺失）。";
#endif
    OH_LOG_INFO(LOG_APP, "runVulkanSelfTest() 返回 %{public}zu 字节报告", report.size());
    return report.c_str();
}

#endif

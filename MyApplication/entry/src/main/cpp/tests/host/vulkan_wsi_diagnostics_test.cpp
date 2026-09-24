/**
 * 直接编译生产 WSI，通过公开 proc-address 入口调用假驱动，验证诊断门不会改变分发、
 * 返回值或 present 计数。仅替换 hilog/驱动边界，不复制 WSI 的资源包装函数或日志策略；
 * stderr 由外层脚本捕获，hilog 在本测试内计数，两个输出通道分别检查。
 */
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#include "stubs/hilog/log.h"

namespace {
std::vector<std::string> wsiHilogLines;
/** 替换宿主 hilog 空桩，保留生产 emitWsiLog 真正提交的格式化正文。 */
void recordWsiHilog(const char* line) { wsiHilogLines.emplace_back(line); }
void requireWsi(bool condition, const char* why) {
    if (!condition) { std::cerr << "FAIL " << why << '\n'; std::exit(1); }
}
}
#undef OH_LOG_INFO
#undef OH_LOG_ERROR
#define OH_LOG_INFO(type, format, line) recordWsiHilog(line)
#define OH_LOG_ERROR(type, format, line) recordWsiHilog(line)
#include "../../platform/vulkan_wsi.cpp"

namespace {
const auto testInstance = reinterpret_cast<VkInstance>(0x2100);
const auto testPhysical = reinterpret_cast<VkPhysicalDevice>(0x2200);
const auto testDevice = reinterpret_cast<VkDevice>(0x2300);
const auto testQueue = reinterpret_cast<VkQueue>(0x2400);
unsigned bufferCalls = 0, memoryCalls = 0, bindCalls = 0, freeCalls = 0, presentCalls = 0;
bool failBuffer = false, omitRequirements = false, failPresent = false;

/** 假驱动仅提供可计数结果；失败注入发生在 WSI 完成函数查找之后，验证真实错误路径。 */
VKAPI_ATTR VkResult VKAPI_CALL fakeEnumerate(VkInstance, uint32_t* count, VkPhysicalDevice* devices) {
    *count = 1;
    if (devices) devices[0] = testPhysical;
    return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL fakeCreateDevice(VkPhysicalDevice, const VkDeviceCreateInfo*,
    const VkAllocationCallbacks*, VkDevice* device) { *device = testDevice; return VK_SUCCESS; }
VKAPI_ATTR void VKAPI_CALL fakeQueue(VkDevice, uint32_t, uint32_t, VkQueue* queue) { *queue = testQueue; }
VKAPI_ATTR VkResult VKAPI_CALL fakeBuffer(VkDevice, const VkBufferCreateInfo*,
    const VkAllocationCallbacks*, VkBuffer* buffer) {
    ++bufferCalls;
    // Vulkan失败不保证写输出参数，保留调用方哨兵以捕获日志错误读取失败句柄。
    if (failBuffer) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    *buffer = reinterpret_cast<VkBuffer>(0x3100); return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL fakeAllocateMemory(VkDevice, const VkMemoryAllocateInfo*,
    const VkAllocationCallbacks*, VkDeviceMemory* memory) {
    ++memoryCalls; *memory = reinterpret_cast<VkDeviceMemory>(0x3200); return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL fakeBind(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize) {
    ++bindCalls; return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL fakeFree(VkDevice, VkDeviceMemory, const VkAllocationCallbacks*) { ++freeCalls; }
VKAPI_ATTR void VKAPI_CALL fakeRequirements(VkDevice, VkBuffer, VkMemoryRequirements* requirements) {
    requirements->size = 4096;
}
VKAPI_ATTR VkResult VKAPI_CALL fakePresent(VkQueue, const VkPresentInfoKHR*) {
    ++presentCalls; return failPresent ? VK_ERROR_DEVICE_LOST : VK_SUCCESS;
}
/** 函数地址均指向真实签名的假驱动，不能让测试依赖宿主 Vulkan 安装或 GPU。 */
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fakeDeviceProc(VkDevice, const char* name) {
    if (std::strcmp(name, "vkGetDeviceQueue") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeQueue);
    if (std::strcmp(name, "vkCreateBuffer") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeBuffer);
    if (std::strcmp(name, "vkAllocateMemory") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeAllocateMemory);
    if (std::strcmp(name, "vkBindBufferMemory") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeBind);
    if (std::strcmp(name, "vkFreeMemory") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeFree);
    if (std::strcmp(name, "vkGetBufferMemoryRequirements") == 0 && !omitRequirements)
        return reinterpret_cast<PFN_vkVoidFunction>(fakeRequirements);
    if (std::strcmp(name, "vkQueuePresentKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakePresent);
    return nullptr;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fakeInstanceProc(VkInstance, const char* name) {
    if (std::strcmp(name, "vkGetInstanceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeInstanceProc);
    if (std::strcmp(name, "vkEnumeratePhysicalDevices") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeEnumerate);
    if (std::strcmp(name, "vkCreateDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeCreateDevice);
    if (std::strcmp(name, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(fakeDeviceProc);
    return nullptr;
}
template <typename Fn> Fn deviceFunction(const char* name) {
    auto pointer = amclVulkanGetDeviceProcAddr(testDevice, name);
    requireWsi(pointer != nullptr, name);
    return reinterpret_cast<Fn>(pointer);
}
/** 在格式化后的 sink 记录上断言，避免只检查源码里存在 if 就误报门控成功。 */
bool hilogContains(const char* fragment) {
    for (const auto& line : wsiHilogLines) if (line.find(fragment) != std::string::npos) return true;
    return false;
}
}

int main() {
    using amcl::graphics::VulkanWsiTraceAllowed;
    // 纯策略检查防止只有可选诊断位、没有开发产品位时意外放行。
    for (unsigned mask : {0u, 1u, 511u, 512u, 1024u}) {
        requireWsi(!VulkanWsiTraceAllowed(mask, false), "unselected trace must stay disabled");
        requireWsi(VulkanWsiTraceAllowed(mask, true), "failures always survive");
    }
    requireWsi(VulkanWsiTraceAllowed(513u, false), "explicit developer trace");
    requireWsi(VulkanWsiTraceAllowed(1023u, false), "other selected diagnostics coexist");
    const bool trace = VulkanWsiTraceAllowed(AMCL_DIAGNOSTICS_MASK, false);
    int traceArguments = 0, errorArguments = 0;
    AMCL_WSI_TRACE(false, "fixture_trace_argument=%d", ++traceArguments);
    AMCL_WSI_TRACE(true, "fixture_error_argument=%d", ++errorArguments);
    requireWsi(traceArguments == (trace ? 1 : 0) && errorArguments == 1, "disabled log arguments remain unevaluated");

    // 真实 WSI 消费生成的审计白名单，所有已支持世代可授权，未知身份及错误 profile 不可。
    for (const char* requirement : {"minecraft-26.2-conservative-v1", "minecraft-26.3-pre1-vulkan-conservative-v1",
                                   "minecraft-26.3-sdl-vulkan-conservative-v1", "minecraft-26.4-snapshot1-sdl-vulkan-v1"}) {
        requireWsi(amclVulkanSetAdmission(1, "minecraft-vulkan", requirement) == 1, "audited WSI admission");
    }
    requireWsi(amclVulkanSetAdmission(1, "minecraft-vulkan", "unknown") == 0, "unknown WSI requirement rejected");
    requireWsi(amclVulkanSetAdmission(1, "mobilegl", "minecraft-26.4-snapshot1-sdl-vulkan-v1") == 0, "wrong WSI profile rejected");
    requireWsi(amclVulkanSetAdmission(1, "minecraft-vulkan", "minecraft-26.2-conservative-v1") == 1, "admission");
    requireWsi(amclVulkanSetLoader(reinterpret_cast<void*>(fakeInstanceProc)) == 1, "fake loader selected");
    auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
        amclVulkanGetInstanceProcAddr(testInstance, "vkEnumeratePhysicalDevices"));
    uint32_t count = 1; VkPhysicalDevice physical = VK_NULL_HANDLE;
    requireWsi(enumerate && enumerate(testInstance, &count, &physical) == VK_SUCCESS && physical == testPhysical,
        "physical device identity crosses production wrapper");
    auto create = reinterpret_cast<PFN_vkCreateDevice>(amclVulkanGetInstanceProcAddr(testInstance, "vkCreateDevice"));
    VkDevice device = VK_NULL_HANDLE;
    requireWsi(create && create(physical, nullptr, nullptr, &device) == VK_SUCCESS && device == testDevice, "device dispatch");
    VkQueue queue = VK_NULL_HANDLE;
    deviceFunction<PFN_vkGetDeviceQueue>("vkGetDeviceQueue")(device, 0, 0, &queue);
    requireWsi(queue == testQueue, "queue mapping preserved");

    const auto createBufferFn = deviceFunction<PFN_vkCreateBuffer>("vkCreateBuffer");
    const auto allocateFn = deviceFunction<PFN_vkAllocateMemory>("vkAllocateMemory");
    const auto bindFn = deviceFunction<PFN_vkBindBufferMemory>("vkBindBufferMemory");
    const auto freeFn = deviceFunction<PFN_vkFreeMemory>("vkFreeMemory");
    const auto requirementsFn = deviceFunction<PFN_vkGetBufferMemoryRequirements>("vkGetBufferMemoryRequirements");
    // 多次成功调用代表游戏资源热路径，普通产品不能为每次分配刷两个同步日志通道。
    for (unsigned i = 0; i < 64; ++i) {
        VkBuffer buffer = VK_NULL_HANDLE; VkDeviceMemory memory = VK_NULL_HANDLE;
        requireWsi(createBufferFn(device, nullptr, nullptr, &buffer) == VK_SUCCESS, "buffer result");
        requireWsi(allocateFn(device, nullptr, nullptr, &memory) == VK_SUCCESS, "allocation result");
        requireWsi(bindFn(device, buffer, memory, 0) == VK_SUCCESS, "bind result");
        VkMemoryRequirements requirements{}; requirementsFn(device, buffer, &requirements);
        requireWsi(requirements.size == 4096, "memory requirements returned");
        freeFn(device, memory, nullptr);
    }
    failBuffer = true; VkBuffer failed = reinterpret_cast<VkBuffer>(0xBAD1);
    requireWsi(createBufferFn(device, nullptr, nullptr, &failed) == VK_ERROR_OUT_OF_DEVICE_MEMORY, "allocation failure unchanged");
    requireWsi(failed == reinterpret_cast<VkBuffer>(0xBAD1), "failed output remains untouched by wrapper");
    omitRequirements = true; VkMemoryRequirements untouched{};
    requirementsFn(device, VK_NULL_HANDLE, &untouched);
    requireWsi(untouched.size == 0, "missing proc leaves output unchanged");

    const auto presentFn = deviceFunction<PFN_vkQueuePresentKHR>("vkQueuePresentKHR");
    for (unsigned i = 0; i < 300; ++i) requireWsi(presentFn(queue, nullptr) == VK_SUCCESS, "present result");
    failPresent = true;
    requireWsi(presentFn(queue, nullptr) == VK_ERROR_DEVICE_LOST, "present failure unchanged");
    requireWsi(runtime().presents == 300 && presentCalls == 301, "present count independent of trace");
    requireWsi(bufferCalls == 65 && memoryCalls == 64 && bindCalls == 64 && freeCalls == 64, "driver dispatch counts unchanged");
    requireWsi(hilogContains("graphics_vk_create_buffer begin") == trace, "hilog resource begin obeys gate");
    requireWsi(hilogContains("graphics_vk_create_buffer end result=0") == trace, "hilog resource success obeys gate");
    requireWsi(hilogContains("graphics_vk_create_buffer end result=-2 device=8960 buffer=0"),
        "failed allocation log never treats undefined output as a handle");
    requireWsi(hilogContains("graphics_vk_get_buffer_memory end device=8960 buffer=0"), "hilog missing proc retained");
    requireWsi(hilogContains("graphics_loader_admission") && hilogContains("graphics_vk_create_device end result=0"),
        "hilog critical lifecycle retained");
    requireWsi(hilogContains("graphics_queue_present result=0 presents=300") &&
        hilogContains("graphics_queue_present result=-4"), "hilog present milestone and failure retained");
    std::cout << "PASS WSI trace mask=" << AMCL_DIAGNOSTICS_MASK
        << " buffers=65 memory=64 bind=64 free=64 presents=300 failedPresent=1\n";
}

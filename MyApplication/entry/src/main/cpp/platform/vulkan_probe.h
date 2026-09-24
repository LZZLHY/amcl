// vulkan_probe.h — Vulkan 能力探针（VULKAN_ADAPTATION_PLAN.md Phase 0）
//
// 在写任何 Vulkan 渲染代码前，先用这个探针在真机上盘点 Maleoon 910（或其它华为
// GPU）的 Vulkan 能力，确认是否满足 MC 官方 Vulkan 后端（Vibrant Visuals, 26.2+）
// 的硬性要求：core 版本 >= 1.2、VK_KHR_surface + VK_OHOS_surface 实例扩展、
// VK_KHR_swapchain 设备扩展等。
//
// 设计要点（"最稳"）：
//   - 全程 dlopen("libvulkan.so") + vkGetInstanceProcAddr 解析函数指针，
//     libentry.so **不** NEEDED 链接 libvulkan.so。设备若缺该库，探针返回
//     "unavailable" 字符串而不是让整个 native 模块加载失败。
//   - 只读不写：创建一个最小 VkInstance 做查询，立即销毁，无任何全局副作用。

#ifndef MC_OHOS_VULKAN_PROBE_H
#define MC_OHOS_VULKAN_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

// 返回一份人类可读的 Vulkan 能力报告（供 ArkTS DevTools 展示 / hilog 打印）。
// 返回的指针指向函数内 static std::string，调用方无需释放；非线程安全（与
// getGpuInfo 同款约定，仅 UI 线程按需调用）。
const char* getVulkanInfo();

// 返回机器可读的能力门控结果（JSON 字符串），供 ArkTS 在用户选 MC 26.2+ 时静默调用，
// 据此显示"Vulkan 可用 / 不可用"。字段（见 VULKAN_ADAPTATION_PLAN.md §十）：
//   {
//     "available": bool,          // 设备枚举门槛；不代表窗口、工具链或游戏验证已通过
//     "reason": string,           // available=false 时的简短原因（给 UI 直接显示）
//     "warning": string,          // available=true 但有非致命提示（如缺 push_descriptor）
//     "loaderVersion": string,    // 如 "1.3.275"；libvulkan 不可用时为 ""
//     "deviceName": string,       // 选中的 GPU 名；无则 ""
//     "deviceType": string,       // "Integrated GPU" / "Discrete GPU" ...
//     "vendorName": string,       // 厂商名解码，如 "Huawei" / "Qualcomm" / "ARM"
//     "vendorId": number,         // 原始厂商 ID
//     "deviceId": number,         // 原始设备 ID
//     "deviceApiVersion": string, // 如 "1.2.275"
//     "deviceLocalMemoryMB": number, // 设备本地显存（MB）
//     "driverName": string,       // VK_KHR_driver_properties.driverName（可能为空）
//     "driverInfo": string,       // driverInfo（可能为空）
//     "conformanceVersion": string,  // CTS 一致性版本，如 "1.3.6.0"
//     "hasOhosSurface": bool,
//     "hasSwapchain": bool,
//     "hasDynamicRendering": bool,// 能力（扩展列出 OR 进 core）；门控以 feature bit 优先
//     "hasPushDescriptor": bool,  // MC 硬性必需，缺则 available=false
//     "hasSynchronization2": bool,
//     "featuresQueried": bool,    // 是否成功用 vkGetPhysicalDeviceFeatures2 查到特性位
//     "dynamicRenderingFeature": bool, // 真实特性位（featuresQueried=true 时门控采信）
//     "synchronization2Feature": bool,
//     "maxPushDescriptors": number     // push_descriptor 上限（0 = 不支持/未查到）
//   }
// 同样指向函数内 static std::string，非线程安全。
const char* getVulkanCapabilityJson();

// Explicit launch admission probe. Creates and destroys a temporary surface,
// checks a graphics/present queue, compiles and reflects a shader, and verifies
// the packaged native files. Unperformed observations remain NOT_RUN.
const char* getGraphicsCapabilityJson(const char* profileId,
    const char* requirementId, const char* windowProvider, bool availabilityOnly = false);

// Vulkan 实战自检（VULKAN_ADAPTATION_PLAN.md Phase B — 端到端链路验证）。
//
// 与 getVulkanInfo()（只读盘点能力）不同：本函数**真的把整条 Vulkan 呈现链跑一遍**——
//   instance(带 surface 扩展) → 物理设备 → 逻辑设备+图形/呈现队列 →
//   vkCreateSurfaceOHOS(吃 XComponent 的 OHNativeWindow) → 查 surface 支持/格式/呈现模式 →
//   创建 swapchain → 取 image + imageView → command pool/buffer →
//   录制一次 clear（vkCmdClearColorImage）→ 提交 → vkQueuePresentKHR → 等待 → 全部销毁。
// 这样能在**不启动 MC** 的前提下，精确定位华为驱动在哪一步断（surface? swapchain? present?），
// 把"扩展能力"层面的判断升级为"整条链能不能真的出一帧"的实证。
//
// 参数 nativeWindowPtr：XComponent 的 OHNativeWindow 指针（uintptr_t 数值）。传 0 时函数
// 内部回退到环境变量 AMCL_NATIVE_WINDOW（xcomponent.cpp OnSurfaceCreated 设的，跨 .so 可见）。
// 无窗口则跳过 surface/swapchain/present 部分，仅做到设备+队列层面（仍有诊断价值）。
//
// 返回人类可读的逐步报告（每步 ✅/❌ + VkResult），指向函数内 static std::string，非线程安全，
// 仅 UI 线程按需调用。只读语义之外它会短暂建 device/swapchain，但结束时全部销毁、无持久副作用；
// ⚠️ 不要在 MC 已经持有该 NativeWindow 时调用（会与 MC 的 surface 抢占窗口）。
const char* runVulkanSelfTest(unsigned long long nativeWindowPtr);

// 兼容的设备枚举摘要（= getVulkanCapabilityJson 的 "available"）。
// 启动准入使用 ProbeGraphicsCapability 的分级事实，不以本布尔值替代未运行的探针。
int amclVulkanUsableForMc(void);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_VULKAN_PROBE_H

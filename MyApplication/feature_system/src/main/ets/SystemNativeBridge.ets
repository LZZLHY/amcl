/**
 * SystemNativeBridge.ets — system 域 native 桥（三层架构 · D1=方案 a / 控制反转）。
 *
 * feature_system 抽成 HAR 后不直接依赖 libentry.so；由持有 native 的 entry(HAP) 在启动时注入
 * testNapi 实现。涉及：Vulkan 能力探针 / 存储路径 native 探针。
 * 未注入时调用方各自兜底（VulkanCapability / StorageProbe 都有 try/catch 降级）。
 */
export interface SystemNativeBridge {
  /** 返回 native Vulkan 能力 JSON（vulkan_probe.cpp getVulkanCapabilityJson）。 */
  getVulkanCapabilityJson(): string;
  /**
   * 使用现有版本化图形探针查询 Minecraft Vulkan 的设备入口能力。实现必须固定为
   * availabilityOnly=true，下载页不创建窗口/surface，也不取得游戏 Vulkan 授权。
   */
  getMinecraftVulkanDeviceCapabilityJson(requirementId: string, windowProvider: string): string;
  /** native 侧文件读写探针，返回可读报告。 */
  probeNativePath(probeDir: string): string;
}

let g_sysNative: SystemNativeBridge | null = null;

/** 由 entry（持 libentry.so 的 HAP）在启动时注入 system native 实现；传 null 卸载。 */
export function setSystemNativeBridge(b: SystemNativeBridge | null): void {
  g_sysNative = b;
}

/** 取已注入的 system native 桥；未注入即抛（调用方各自 try/catch 兜底）。 */
export function systemNative(): SystemNativeBridge {
  if (!g_sysNative) {
    throw new Error('SystemNativeBridge 未注入 — 须在启动期调用 setSystemNativeBridge()');
  }
  return g_sysNative;
}

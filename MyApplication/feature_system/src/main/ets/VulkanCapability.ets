/**
 * 下载前 Vulkan 设备可行性报告。26.2/26.3 保留兼容摘要；26.4 起复用启动链已有的
 * 版本化 native 探针及其设备要求评估器，不在 ArkTS 再列一套扩展或特性条件。
 * 未审计的后续版本给出明确标注的设备参考结果；报告不授予启动资格，不替代安装后的
 * 客户端摘要、窗口/工具链和实际呈现检查，也不修改偏好、参数或窗口状态。
 */
import { systemNative } from './SystemNativeBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LogTags } from 'commons';
import { LOG_DOMAIN_NATIVE, VULKAN_MIN_MC_VERSION, VULKAN_264_REFERENCE_VERSION,
  VULKAN_264_REQUIREMENT_ID } from 'commons';
import { isMcVersionAtLeast } from 'commons';

/** native 探针返回的能力结构（与 vulkan_probe.cpp getVulkanCapabilityJson 字段对齐）。 */
export interface VulkanCapability {
  available: boolean;          // 设备枚举满足保守门槛；窗口、工具链和生命周期另行取证
  reason: string;              // available=false 时的简短原因（可直接显示）
  warning: string;             // available=true 但有非致命提示时的警告（如缺 push_descriptor）
  loaderVersion: string;       // 如 "1.3.275"
  deviceName: string;          // GPU 名，如 "Maleoon 920"
  deviceType: string;          // "Integrated GPU" / "Discrete GPU" ...
  vendorName: string;          // 厂商名解码，如 "Huawei" / "Qualcomm" / "ARM"
  vendorId: number;            // PCI/Khronos 厂商 ID（原始数值）
  deviceId: number;            // 设备 ID（原始数值）
  deviceApiVersion: string;    // 如 "1.2.275"
  deviceLocalMemoryMB: number; // 设备本地显存（MB）
  driverName: string;          // VK_KHR_driver_properties.driverName（可能为空）
  driverInfo: string;          // driverInfo（可能为空）
  conformanceVersion: string;  // CTS 一致性版本，如 "1.3.6.0"（可能为空）
  hasOhosSurface: boolean;
  hasSwapchain: boolean;
  hasDynamicRendering: boolean;  // 能力：扩展列出 OR 已进 core
  hasPushDescriptor: boolean;
  hasSynchronization2: boolean;
  // 「更真实」新增：vkGetPhysicalDeviceFeatures2 实查到的 feature bit。
  // featuresQueried=false 表示未获得特性位，不能从扩展名补成 YES。
  featuresQueried: boolean;
  dynamicRenderingFeature: boolean;  // 真实特性位（最可信）
  synchronization2Feature: boolean;
  maxPushDescriptors: number;        // push_descriptor 上限（0 = 不支持/未查到）
}

function fallbackCapability(reason: string): VulkanCapability {
  return {
    available: false, reason, warning: '',
    loaderVersion: '', deviceName: '', deviceType: '', vendorName: '',
    vendorId: 0, deviceId: 0, deviceApiVersion: '', deviceLocalMemoryMB: 0,
    driverName: '', driverInfo: '', conformanceVersion: '',
    hasOhosSurface: false, hasSwapchain: false,
    hasDynamicRendering: false, hasPushDescriptor: false, hasSynchronization2: false,
    featuresQueried: false, dynamicRenderingFeature: false,
    synchronization2Feature: false, maxPushDescriptors: 0,
  };
}

let s_cache: VulkanCapability | null = null;

/**
 * 该 MC 版本是否走 MC 官方 Vulkan 渲染路径（即 ≥ 26.2，可切 Graphics API）。
 * 低于此版本只有 OpenGL，无需探测 Vulkan。
 */
export function mcVersionSupportsVulkan(mcVersion: string): boolean {
  return isMcVersionAtLeast(mcVersion, VULKAN_MIN_MC_VERSION);
}

/**
 * 跑一次 native Vulkan 能力探针（进程内缓存）。同步、几毫秒级。
 * 任何异常都降级为"不可用 + 原因"，不抛。
 */
export function probeVulkanCapability(forceRefresh: boolean = false): VulkanCapability {
  if (s_cache !== null && !forceRefresh) {
    return s_cache;
  }
  let result: VulkanCapability;
  try {
    const json: string = systemNative().getVulkanCapabilityJson();
    const parsed = JSON.parse(json) as VulkanCapability;
    // 防御：JSON.parse 出来的字段可能缺，逐项兜底为安全默认。
    result = {
      available: parsed.available === true,
      reason: typeof parsed.reason === 'string' ? parsed.reason : '',
      warning: typeof parsed.warning === 'string' ? parsed.warning : '',
      loaderVersion: typeof parsed.loaderVersion === 'string' ? parsed.loaderVersion : '',
      deviceName: typeof parsed.deviceName === 'string' ? parsed.deviceName : '',
      deviceType: typeof parsed.deviceType === 'string' ? parsed.deviceType : '',
      vendorName: typeof parsed.vendorName === 'string' ? parsed.vendorName : '',
      vendorId: typeof parsed.vendorId === 'number' ? parsed.vendorId : 0,
      deviceId: typeof parsed.deviceId === 'number' ? parsed.deviceId : 0,
      deviceApiVersion: typeof parsed.deviceApiVersion === 'string' ? parsed.deviceApiVersion : '',
      deviceLocalMemoryMB: typeof parsed.deviceLocalMemoryMB === 'number' ? parsed.deviceLocalMemoryMB : 0,
      driverName: typeof parsed.driverName === 'string' ? parsed.driverName : '',
      driverInfo: typeof parsed.driverInfo === 'string' ? parsed.driverInfo : '',
      conformanceVersion: typeof parsed.conformanceVersion === 'string' ? parsed.conformanceVersion : '',
      hasOhosSurface: parsed.hasOhosSurface === true,
      hasSwapchain: parsed.hasSwapchain === true,
      hasDynamicRendering: parsed.hasDynamicRendering === true,
      hasPushDescriptor: parsed.hasPushDescriptor === true,
      hasSynchronization2: parsed.hasSynchronization2 === true,
      featuresQueried: parsed.featuresQueried === true,
      dynamicRenderingFeature: parsed.dynamicRenderingFeature === true,
      synchronization2Feature: parsed.synchronization2Feature === true,
      maxPushDescriptors: typeof parsed.maxPushDescriptors === 'number' ? parsed.maxPushDescriptors : 0,
    };
    hilog.info(LOG_DOMAIN_NATIVE, LogTags.SVC_VULKAN_CAP,
      'probe: available=%{public}s device=%{public}s api=%{public}s dynRender=%{public}s featQueried=%{public}s',
      String(result.available), result.deviceName, result.deviceApiVersion,
      String(result.hasDynamicRendering), String(result.featuresQueried));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    hilog.error(LOG_DOMAIN_NATIVE, LogTags.SVC_VULKAN_CAP, 'probe failed: %{public}s', msg);
    result = fallbackCapability('Vulkan 探针执行失败: ' + msg);
  }
  s_cache = result;
  return result;
}

/** UNKNOWN 表示证据缺失或查询失败，不能当成设备确实不支持，也不能显示为通过。 */
export enum VulkanFeasibilityState { FEASIBLE = 'feasible', UNAVAILABLE = 'unavailable', UNKNOWN = 'unknown' }

/** 下载页只展示设备可行性。available 保留旧消费者兼容，统一由报告状态生成。 */
export interface VulkanStatusHint {
  available: boolean;
  message: string;
  status: VulkanFeasibilityState;
  statusLabel: string;
  defaultNotice: string;
}

/** 现有 native 结构化输出中供设备报告消费的字段；不含任何新的硬件能力判断。 */
interface VulkanDevicePreview {
  evidenceProfileId: string;
  requirementId: string;
  windowProvider: string;
  loader: string;
  instance: string;
  physicalDevice: string;
  apiVersion: string;
  deviceExtensions: string;
  featureBits: string;
  windowSurface: string;
  queuePresentation: string;
  shaderToolchain: string;
  nativeArtifacts: string;
  observedProvider: string;
}

interface VulkanPreviewCheck {
  evidence: string;
  requiredAtPreview: boolean;
  failureMessage: string;
}

/** 始终展示的操作提示；这是自动模式的默认策略，已有用户显式选择仍被尊重。 */
const VULKAN_DEFAULT_NOTICE: string = '26.4 起，自动模式默认优先使用 Vulkan。需要更换，请自行在 AMCL「设置 → 图形后端」中选择；Vulkan 不可用时会采用 OpenGL 及其翻译层。';

/**
 * 将查询结果转换为下载页文案。只有已审计的参考客户端可使用确定的设备检查标题；
 * 后续版本明确注明参考基线，不把同一台设备的通过结果外推为未来客户端已获准运行。
 */
function modernVulkanHint(mcVersion: string, status: VulkanFeasibilityState, detail: string): VulkanStatusHint {
  const reference: boolean = mcVersion !== VULKAN_264_REFERENCE_VERSION;
  const prefix: string = reference ? '按 26.4 Snapshot 1 的已知要求进行设备参考检查：' : '';
  const label: string = status === VulkanFeasibilityState.UNKNOWN ? '尚未确认'
    : status === VulkanFeasibilityState.FEASIBLE ? (reference ? '参考通过' : '检查通过')
    : (reference ? '参考未通过' : '未通过');
  return {
    available: status === VulkanFeasibilityState.FEASIBLE,
    status: status, statusLabel: label, defaultNotice: VULKAN_DEFAULT_NOTICE,
    message: prefix + detail + '。安装后仍会核对该版本、运行库和窗口呈现能力。',
  };
}

/**
 * 每次打开 26.4+ 详情时读取一份设备入口证据，不复用旧版 available 缓存。
 * 桥固定调用 availabilityOnly 探针：必需设备阶段须为 YES；窗口/呈现/着色器尚未
 * 执行可以留 NOT_RUN，但明确 NO 必须拒绝。此处只解释现有证据，不复制 native 要求表。
 * 异常、身份错配、字段缺失均报告 UNKNOWN，下次打开可重新检查，不缓存暂时失败。
 */
function modernVulkanStatusForVersion(mcVersion: string): VulkanStatusHint {
  try {
    const json: string = systemNative().getMinecraftVulkanDeviceCapabilityJson(VULKAN_264_REQUIREMENT_ID, 'SDL3');
    const cap: VulkanDevicePreview = JSON.parse(json) as VulkanDevicePreview;
    if (cap === null || cap.evidenceProfileId !== 'minecraft-vulkan'
        || cap.requirementId !== VULKAN_264_REQUIREMENT_ID || cap.windowProvider !== 'SDL3') {
      return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNKNOWN, '设备检查结果身份不匹配，请重新打开详情页重试');
    }
    const checks: VulkanPreviewCheck[] = [
      { evidence: cap.loader, requiredAtPreview: true, failureMessage: '系统未提供可用的 Vulkan 驱动入口' },
      { evidence: cap.instance, requiredAtPreview: true, failureMessage: '无法建立 Vulkan 设备查询实例' },
      { evidence: cap.physicalDevice, requiredAtPreview: true, failureMessage: '未找到符合要求的 Vulkan 图形设备' },
      { evidence: cap.deviceExtensions, requiredAtPreview: true, failureMessage: 'Vulkan 版本或必需设备扩展未满足要求' },
      { evidence: cap.featureBits, requiredAtPreview: true, failureMessage: 'GPU 未提供全部必需的 Vulkan 特性' },
      { evidence: cap.windowSurface, requiredAtPreview: false, failureMessage: '系统未提供所需的 Vulkan 窗口接口' },
      { evidence: cap.queuePresentation, requiredAtPreview: false, failureMessage: '设备未通过 Vulkan 呈现能力检查' },
      { evidence: cap.shaderToolchain, requiredAtPreview: false, failureMessage: 'Vulkan 着色器工具链检查未通过' },
      { evidence: cap.nativeArtifacts, requiredAtPreview: true, failureMessage: '当前启动器缺少所需的 Vulkan 运行库' },
    ];
    for (const check of checks) {
      if (check.evidence !== 'YES' && check.evidence !== 'NO'
          && check.evidence !== 'UNKNOWN' && check.evidence !== 'NOT_RUN') {
        return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNKNOWN, '设备检查结果不完整，请重新打开详情页重试');
      }
    }
    for (const check of checks) {
      if (check.evidence === 'NO') return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNAVAILABLE, check.failureMessage);
    }
    for (const check of checks) {
      if (check.requiredAtPreview && check.evidence !== 'YES') {
        return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNKNOWN, '尚未取得完整的 Vulkan 设备检查结果');
      }
    }
    if (typeof cap.apiVersion !== 'string' || cap.apiVersion.length === 0) {
      return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNKNOWN, '尚未确认设备的 Vulkan API 版本');
    }
    const device: string = typeof cap.observedProvider === 'string' && cap.observedProvider.length > 0
      ? cap.observedProvider : 'GPU';
    return modernVulkanHint(mcVersion, VulkanFeasibilityState.FEASIBLE,
      '设备条件满足（' + device + ' · Vulkan ' + cap.apiVersion + '）');
  } catch (error) {
    hilog.warn(LOG_DOMAIN_NATIVE, LogTags.SVC_VULKAN_CAP, 'download device preview failed: %{public}s', String(error));
    return modernVulkanHint(mcVersion, VulkanFeasibilityState.UNKNOWN, '暂时无法完成 Vulkan 设备检查，请重新打开详情页重试');
  }
}

/** 低于26.2不显示；旧版摘要保持；26.4及以后始终给报告和默认Vulkan提示，未知证据不报通过。 */
export function getVulkanStatusForVersion(mcVersion: string): VulkanStatusHint | null {
  if (!mcVersionSupportsVulkan(mcVersion)) {
    return null;
  }
  if (isMcVersionAtLeast(mcVersion, '26.4')) return modernVulkanStatusForVersion(mcVersion);
  const cap = probeVulkanCapability();
  if (cap.available) {
    const dev = cap.deviceName ? cap.deviceName : 'GPU';
    const drv = cap.driverName ? ' · 驱动 ' + cap.driverName : '';
    const feat = cap.featuresQueried ? '（已实测特性位）' : '';
    const warn = cap.warning ? ' ⚠️ ' + cap.warning : '';
    return {
      available: true,
      status: VulkanFeasibilityState.FEASIBLE, statusLabel: '可用', defaultNotice: '',
      message: 'Vulkan 设备能力满足当前检查（' + dev + ' · Vulkan ' + cap.deviceApiVersion + drv +
               '）' + feat + '。启动时还会检查窗口呈现和运行库。' + warn,
    };
  }
  const reason = cap.reason ? cap.reason : '设备不支持';
  return {
    available: false,
    status: VulkanFeasibilityState.UNAVAILABLE, statusLabel: '不可用', defaultNotice: '',
    message: '当前设备未通过 Vulkan 能力检查：' + reason + '。',
  };
}

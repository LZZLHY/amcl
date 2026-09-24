/**
 * Minecraft 图形偏好与启动参数的纯逻辑桥。
 *
 * 游戏能力、实例名称和用户请求是不同数据：版本判断只读已经解析的
 * GraphicsProfileInput.realMcVersion；profile 对应的 API 只读 canonical 注册表。
 * 本模块不访问 options.txt，不运行探针，也不创建 context，方便设置/启动链共用和行为测试。
 */
import { isMcVersionAtLeast } from 'commons';
import { VulkanPolicy } from './GraphicsSelectionTypes';
import { GraphicsProfileInput } from './GraphicsProfileResolver';
import { GraphicsGameApi, GraphicsProfileSpec, GraphicsSelectionRole,
  graphicsProfileById, graphicsProfileByRole } from './GraphicsProfileRegistry';

/** 已读取的偏好快照。optionsText 由持有文件系统的产品层提供，读取失败可传空串。 */
export interface MinecraftGraphicsPreferenceInput {
  launcherProfile: string;
  launcherExplicit: boolean;
  developerOverride: string;
  optionsText: string;
}

/** 请求结果仍需经过 resolver 的版本、provider、资产和能力准入，不能据此宣称运行成功。 */
export interface MinecraftGraphicsRequest {
  requestedProfile: string;
  preferenceExplicit: boolean;
  requireVulkan: boolean;
  /** 游戏明确偏好 OpenGL 时排除原生 Vulkan，仍允许 MobileGL 等以 Vulkan 实现的 GL 翻译器。 */
  vulkanPolicy: VulkanPolicy;
}

/**
 * 解析本次请求：开发覆盖 > 启动器显式 profile > 自动模式下的游戏内 Vulkan 偏好。
 *
 * 参数 game 必须是由实际安装清单得到的事实；禁止用可重命名的实例 ID 代替真实版本。
 * requireVulkan 保留既有“请求 Vulkan 后失败即终止”的政策，调用方不能在失败时静默切 GL。
 */
export function resolveMinecraftGraphicsRequest(game: GraphicsProfileInput,
  preference: MinecraftGraphicsPreferenceInput): MinecraftGraphicsRequest {
  const canFollowGame: boolean = !preference.launcherExplicit || preference.launcherProfile === 'auto';
  let gameRequestsVulkan: boolean = false;
  let gameRequestsOpenGl: boolean = false;
  if (canFollowGame && isMcVersionAtLeast(game.realMcVersion, '26.2')) {
    for (const line of preference.optionsText.split(new RegExp('\\r?\\n'))) {
      // 按完整配置项匹配，注释/其他字符串里出现相同片段不构成游戏偏好。
      if (line.trim() === 'preferredGraphicsBackend:"vulkan"') gameRequestsVulkan = true;
      if (line.trim() === 'preferredGraphicsBackend:"opengl"') gameRequestsOpenGl = true;
    }
  }
  const vulkanProfile: string = graphicsProfileByRole(GraphicsSelectionRole.GameVulkan).id;
  const vulkanDefaultFrom: string = graphicsProfileByRole(GraphicsSelectionRole.GameVulkan).autoPreferredFrom;
  let policy: VulkanPolicy = game.vulkanPolicy ?? VulkanPolicy.ALLOW;
  // 新版开始默认 Vulkan 后，游戏里的明确 OpenGL 偏好应继续有效。只约束自动请求，
  // 不覆盖启动器/开发者显式 profile；保留更严格的禁止 Vulkan transport 策略。
  // 旧版没有新的默认 Vulkan 候选，因此保持原有请求结果和严格 Vulkan 语义。
  if (policy === VulkanPolicy.ALLOW && canFollowGame && preference.developerOverride.length === 0
      && gameRequestsOpenGl && !gameRequestsVulkan && vulkanDefaultFrom.length > 0
      && isMcVersionAtLeast(game.realMcVersion, vulkanDefaultFrom)) policy = VulkanPolicy.DISABLE_VULKAN;
  const requestedProfile: string = preference.developerOverride.length > 0
    ? preference.developerOverride : (gameRequestsVulkan ? vulkanProfile : preference.launcherProfile);
  return {
    requestedProfile: requestedProfile,
    // “明确保存自动选择”仍授权 resolver 选择候选；持久化 explicit 标记不等于锁定某个后端。
    // 只有具体启动器 profile、游戏明确请求 Vulkan 或开发覆盖才形成不可静默替换的请求。
    preferenceExplicit: (preference.launcherExplicit && preference.launcherProfile !== 'auto')
      || gameRequestsVulkan || preference.developerOverride.length > 0,
    requireVulkan: requestedProfile === vulkanProfile,
    vulkanPolicy: policy,
  };
}

/**
 * 将已选计划的 API 转为 Minecraft 自身的启动参数值。
 * 26.2 以前不支持这个参数；UNKNOWN/DUAL 是能力集合，不能当成已选择 API 写入游戏。
 */
export function minecraftGraphicsBackendForApi(realMcVersion: string, api: string): string {
  if (!isMcVersionAtLeast(realMcVersion, '26.2')) return '';
  if (api === GraphicsGameApi.OPENGL || api === GraphicsGameApi.VULKAN) return api;
  return '';
}

/** options 持久化只查询注册表，不在页面维护第二份 profile → API 名单。 */
export function minecraftGraphicsBackendForProfile(realMcVersion: string, profileId: string): string {
  const profile: GraphicsProfileSpec | undefined = graphicsProfileById(profileId);
  return profile === undefined ? '' : minecraftGraphicsBackendForApi(realMcVersion, profile.api);
}

/**
 * 返回包含唯一 graphicsBackend 的新参数数组，原数组保持不变。
 * 同时移除两个 token 和等号形式的旧值；backend 为空时用于旧版本，完整保留原参数。
 */
export function withMinecraftGraphicsBackend(args: string[], backend: string): string[] {
  if (backend.length === 0) return args.slice();
  const kept: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg: string = args[i];
    if (arg === '--graphicsBackend') {
      if (i + 1 < args.length) i++;
      continue;
    }
    if (arg.indexOf('--graphicsBackend=') === 0) continue;
    kept.push(arg);
  }
  kept.push('--graphicsBackend', backend);
  return kept;
}

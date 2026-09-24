import { CapabilityResult } from './GraphicsCapabilityContract';
import { DeviceGraphicsFacts } from './DeviceGraphicsFacts';
import { GraphicsPlatformFamily } from './GraphicsProfileRegistry';

export enum VulkanPolicy {
  ALLOW = 'ALLOW',
  DISABLE_VULKAN = 'DISABLE_VULKAN',
  FORBID_VULKAN_TRANSPORT = 'FORBID_VULKAN_TRANSPORT',
}
/** 仅调整自动候选的排序提示；完整scope必须匹配，不能作为设备/窗口能力证据。 */
export interface GraphicsHistoryHint { profile: string; scopeHash: string; priority: number; reason: string; }

/** Legacy names remain source compatible, but the canonical resolver owns their meaning. */
export interface RendererResolveInput {
  realMcVersion: string;
  lwjglVersion: number;
  needsLwjgl322Slot: boolean;
  userPreferredBackendId: string;
  devOverrideBackendId?: string;
  usesSdl3?: boolean;
  manifestProviderVerified?: boolean;
  nativeGlAvailable?: boolean;
  platformFamily?: GraphicsPlatformFamily;
  /** Runtime device facts. Product family must never be used as a capability proxy. */
  deviceFacts?: DeviceGraphicsFacts;
  capabilityResult?: CapabilityResult;
  /** New canonical preference. Values may be auto, MG, MobileGL, nativegl, minecraft-vulkan or gl4es. */
  graphicsProfilePreference?: string;
  /** False distinguishes the historical stored MobileGlues default from a user choice. */
  graphicsProfileExplicit?: boolean;
  /** Per-profile probe evidence. The resolver scopes each lookup by profile, requirement and provider. */
  capabilityResults?: CapabilityResult[];
  /** Product/artifact preflight allow-list. When present, profiles absent from it are unavailable. */
  availableProfileIds?: string[];
  /** UI availability checks may leave window/shader probes NOT_RUN; launch checks remain strict. */
  availabilityOnly?: boolean;
  /** Native repeats context/present admission after latching the process provider. */
  nativePreflightPending?: boolean;
  /** Enables experimental profiles (for example Minecraft native Vulkan) on supported products. */
  allowExperimentalProfiles?: boolean;
  /** Candidate-specific audit identity and transport policy forwarded to the canonical resolver. */
  requirementId?: string;
  vulkanPolicy?: VulkanPolicy;
  graphicsHistoryScope?: string;
  graphicsHistory?: GraphicsHistoryHint[];
}

export enum RendererDecisionReason {
  RequiredByDesktop = 'required-by-desktop',
  RequiredByGameApi = 'required-by-game-api',
  /** 经准入采用该游戏版本的默认 API；失败仍允许自动 OpenGL 候选。 */
  PreferredByGameDefault = 'preferred-by-game-default',
  ForcedByLwjgl2 = 'forced-by-lwjgl2',
  ForcedByFixedFunctionEra = 'forced-by-fixed-function-era',
  UserPreference = 'user-preference',
  UserPreferenceRejectedByVersion = 'user-preference-rejected-by-version',
  UserPreferenceUnknown = 'user-preference-unknown',
  Default = 'default',
  DevOverride = 'dev-override',
  DevOverrideInvalid = 'dev-override-invalid',
  DevOverrideRejectedByVersion = 'dev-override-rejected-by-version',
  DevOverrideUnsupportedWindowSystem = 'dev-override-unsupported-window-system',
}

export interface RendererDecision {
  backendId: string;
  reason: RendererDecisionReason;
  userPreferenceHonored: boolean;
  logLine: string;
}

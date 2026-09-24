import { RendererDecision, RendererResolveInput, RendererDecisionReason, VulkanPolicy } from './GraphicsSelectionTypes';
import { CapabilityEvidence, CapabilityResult } from './GraphicsCapabilityContract';
import { GraphicsCapabilityKind, GraphicsGameApi, GraphicsPlatformFamily, GraphicsProfileSpec,
  GraphicsProviderVariant, GraphicsSelectionRole, GraphicsTransport, GraphicsWindowProvider, RendererBackendLifecycle,
  graphicsProfileById, graphicsProfileByRole, graphicsProviderForManifest, graphicsRequirementSupported,
  graphicsVersionAtLeast, GRAPHICS_PROFILES } from './GraphicsProfileRegistry';

// GAME_DEFAULT 表示游戏版本默认偏好，可在能力不足时继续选择 OpenGL；GAME_API 仍是
// 显式/仅 Vulkan 请求。两者分开也避免旧 OpenGL 成功历史覆盖新版游戏的默认 API。
export enum GraphicsRequestSource { FORCED = 'FORCED', DEV = 'DEV', GAME_API = 'GAME_API', GAME_DEFAULT = 'GAME_DEFAULT', PREFERENCE = 'PREFERENCE', USER = 'USER', DEFAULT = 'DEFAULT' }
export interface GraphicsCandidate {
  id: string;
  provider: GraphicsWindowProvider;
  platformFamily: GraphicsPlatformFamily;
  source: GraphicsRequestSource;
  admitted: boolean;
  selected: boolean;
  reasonCode: string;
  reason: string;
  decisionReason: RendererDecisionReason;
  profile?: GraphicsProfileSpec;
  providerVariant?: GraphicsProviderVariant;
}
export interface GraphicsProfileResolution {
  requestedProfile: string;
  decision?: RendererDecision;
  selectedCandidate?: GraphicsCandidate;
  candidates: GraphicsCandidate[];
  exclusions: string[];
}
export interface GraphicsProfileInput extends RendererResolveInput {
  /** 仅父进程恢复票据指定的单次候选；不持久化为用户偏好，不允许再次选回失败路线。 */
  graphicsRecoveryProfile?: string;
  gameApi?: GraphicsGameApi;
  requirementId?: string;
  vulkanPolicy?: VulkanPolicy;
}
interface GraphicsRequest {
  id: string;
  source: GraphicsRequestSource;
  decisionReason: RendererDecisionReason;
}
interface AdmissionCheck {
  code: string;
  detail: string;
  legacyReason: RendererDecisionReason;
}

/** Select evidence only when its identity is scoped to the candidate being checked. */
export function capabilityResultFor(input: GraphicsProfileInput, spec: GraphicsProfileSpec,
                                    requirementId: string, provider: GraphicsWindowProvider): CapabilityResult | undefined {
  const results: CapabilityResult[] | undefined = input.capabilityResults;
  if (results !== undefined) {
    for (let i = 0; i < results.length; i++) {
      const result: CapabilityResult = results[i];
      if (result.evidenceProfileId === spec.id && result.requirementId === requirementId
          && String(result.windowProvider) === String(provider)
          && (result.gameVersion === input.realMcVersion || (input.deviceFacts === undefined && result.gameVersion === undefined))) return result;
    }
  }
  const legacy: CapabilityResult | undefined = input.capabilityResult;
  if (legacy !== undefined && legacy.evidenceProfileId === spec.id && legacy.requirementId === requirementId
      && String(legacy.windowProvider) === String(provider)
      && (legacy.gameVersion === input.realMcVersion || (input.deviceFacts === undefined && legacy.gameVersion === undefined))) return legacy;
  return undefined;
}

function preferenceProfileId(value: string): string {
  const normalized: string = value.trim().toLowerCase();
  if (normalized === '' || normalized === 'auto') return '';
  if (normalized === 'mg' || normalized === 'mobileglues') return 'mobileglues';
  if (normalized === 'mobilegl') return 'mobilegl';
  if (normalized === 'nativegl' || normalized === 'opengl' || normalized === 'open-gl') return 'nativegl';
  if (normalized === 'minecraft-vulkan' || normalized === 'vulkan' || normalized === 'minecraftvulkan') return 'minecraft-vulkan';
  if (normalized === 'gl4es') return 'gl4es';
  return value;
}

function reject(code: string, detail: string,
                legacyReason: RendererDecisionReason = RendererDecisionReason.DevOverrideInvalid): AdmissionCheck {
  return { code: code, detail: detail, legacyReason: legacyReason };
}

function platformForInput(input: GraphicsProfileInput): GraphicsPlatformFamily {
  if (input.deviceFacts !== undefined) {
    const devicePlatform: GraphicsPlatformFamily = input.deviceFacts.platformFamily;
    return devicePlatform;
  }
  return input.platformFamily ?? GraphicsPlatformFamily.MOBILE;
}

function fixedFunctionReason(input: GraphicsProfileInput): RendererDecisionReason | undefined {
  if (input.lwjglVersion === 2) return RendererDecisionReason.ForcedByLwjgl2;
  const modern: GraphicsProfileSpec = graphicsProfileByRole(GraphicsSelectionRole.Default);
  if (input.needsLwjgl322Slot && !graphicsVersionAtLeast(input.realMcVersion, modern.gameMinimum)) {
    return RendererDecisionReason.ForcedByFixedFunctionEra;
  }
  return undefined;
}

function nativeGlProbeFailure(spec: GraphicsProfileSpec, provider: GraphicsWindowProvider,
                              input: GraphicsProfileInput): string {
  const result: CapabilityResult | undefined = capabilityResultFor(input, spec, spec.requirementId, provider);
  if (result === undefined) {
    return input.deviceFacts === undefined && input.nativeGlAvailable === true ? '' : 'system OpenGL capability probe has not run';
  }
  if (result.systemLibrary !== CapabilityEvidence.YES) return 'systemLibrary=' + result.systemLibrary;
  if (result.queryGl !== CapabilityEvidence.YES) return 'queryGL=' + result.queryGl;
  if ((input.availabilityOnly || input.nativePreflightPending) && result.evidenceScope === 'device-entry'
      && result.eglContext === CapabilityEvidence.NOT_RUN) return '';
  if (result.eglContext !== CapabilityEvidence.YES) return 'eglContext=' + result.eglContext;
  if (result.glVersion !== CapabilityEvidence.YES || result.apiVersion.length === 0) {
    return 'glVersion=' + result.glVersion;
  }
  if (result.pixelReadback !== CapabilityEvidence.YES) return 'pixelReadback=' + result.pixelReadback;
  if (!input.availabilityOnly && result.windowPresent === CapabilityEvidence.NO) {
    return 'windowPresent=' + result.windowPresent;
  }
  return '';
}

function addRequest(requests: GraphicsRequest[], id: string, source: GraphicsRequestSource,
                    reason: RendererDecisionReason): void {
  if (id.length === 0) return;
  for (let i = 0; i < requests.length; i++) {
    // 同一 profile 可能先作为 DEV 覆盖被拒绝，再作为 DEFAULT/平台默认候选
    // 重新评估；按 id 去重会把合法 fallback 一起吞掉，最终错误地抛出无候选。
    if (requests[i].id === id && requests[i].source === source) return;
  }
  const request: GraphicsRequest = { id: id, source: source, decisionReason: reason };
  requests.push(request);
}

function probeFailure(spec: GraphicsProfileSpec, requirementId: string, provider: GraphicsWindowProvider,
                      result: CapabilityResult | undefined, availabilityOnly: boolean): string {
  if (result === undefined) return 'capability probe has not run';
  if (result.evidenceProfileId !== spec.id || result.requirementId !== requirementId
      || String(result.windowProvider) !== String(provider)) return 'capability probe identity does not match profile, requirement and window provider';
  if (result.loader !== CapabilityEvidence.YES) return 'capability probe loader=' + result.loader;
  if (result.instance !== CapabilityEvidence.YES) return 'capability probe instance=' + result.instance;
  if (result.windowSurface === CapabilityEvidence.NO) return 'capability probe windowSurface=' + result.windowSurface;
  if (!availabilityOnly && result.windowSurface !== CapabilityEvidence.YES) return 'capability probe windowSurface=' + result.windowSurface;
  if (result.physicalDevice !== CapabilityEvidence.YES || result.apiVersion.length === 0) return 'capability probe physical device/API version is unverified';
  if (result.deviceExtensions !== CapabilityEvidence.YES) return 'capability probe deviceExtensions=' + result.deviceExtensions;
  if (result.featureBits !== CapabilityEvidence.YES) return 'capability probe featureBits=' + result.featureBits;
  if (result.queuePresentation === CapabilityEvidence.NO
      || (!availabilityOnly && result.queuePresentation !== CapabilityEvidence.YES)) return 'capability probe queuePresentation=' + result.queuePresentation;
  if (result.shaderToolchain === CapabilityEvidence.NO) return 'capability probe shaderToolchain=' + result.shaderToolchain;
  if (!availabilityOnly && result.shaderToolchain !== CapabilityEvidence.YES) return 'capability probe shaderToolchain=' + result.shaderToolchain;
  if (result.nativeArtifacts !== CapabilityEvidence.YES) return 'capability probe nativeArtifacts=' + result.nativeArtifacts;
  // Lifecycle smoke remains independent evidence; pre-launch admission never invents a successful game lifecycle.
  return '';
}

function admissionFor(input: GraphicsProfileInput, request: GraphicsRequest, spec: GraphicsProfileSpec,
                      provider: GraphicsWindowProvider, platform: GraphicsPlatformFamily): AdmissionCheck {
  if (spec.lifecycle === RendererBackendLifecycle.Retired) return reject('profile-retired', 'profile is retired');
  if (input.manifestProviderVerified === false) return reject('manifest-provider-conflict', 'game manifest declares conflicting window providers');
  if (spec.requiredCapabilities.indexOf('GLES_CONTEXT') >= 0
      && input.deviceFacts?.glesContext === CapabilityEvidence.NO) return reject('capability-unverified', 'GLES context is unavailable');
  if (input.availableProfileIds !== undefined && input.availableProfileIds.indexOf(spec.id) < 0) {
    return reject('artifact-missing', 'profile is absent from installed artifact manifest');
  }
  const gameApi: GraphicsGameApi = input.gameApi ?? GraphicsGameApi.UNKNOWN;
  if (gameApi === GraphicsGameApi.VULKAN && spec.api !== GraphicsGameApi.VULKAN) {
    return reject('game-api-incompatible', 'Vulkan-only game cannot fall back to an OpenGL profile');
  }
  if (spec.api === GraphicsGameApi.VULKAN && gameApi !== GraphicsGameApi.VULKAN && gameApi !== GraphicsGameApi.DUAL) {
    return reject('game-api-unverified', 'game API evidence is UNKNOWN/OPENGL');
  }
  const fixed: RendererDecisionReason | undefined = fixedFunctionReason(input);
  if (fixed !== undefined && spec.selectionRole !== GraphicsSelectionRole.FixedFunction) {
    return reject('fixed-function-required', 'LWJGL slot requires the fixed-function profile', fixed);
  }
  // A stale canonical preference must not turn gl4es into a modern peer
  // backend. It is selected only by the version/LWJGL forced rule above.
  if (request.source === GraphicsRequestSource.PREFERENCE
      && spec.selectionRole === GraphicsSelectionRole.FixedFunction && fixed === undefined) {
    return reject('fixed-function-not-required', 'fixed-function profile is only valid for its forced LWJGL/version route');
  }
  if (request.source === GraphicsRequestSource.DEV
      && spec.lifecycle !== RendererBackendLifecycle.Candidate && spec.lifecycle !== RendererBackendLifecycle.Experimental
      && spec.lifecycle !== RendererBackendLifecycle.Optional
      && spec.capabilityKind !== GraphicsCapabilityKind.NativeGl) {
    return reject('dev-profile-not-candidate', 'development override is not an optional/candidate/experimental profile');
  }
  if (request.source === GraphicsRequestSource.USER && !spec.userSelectable) {
    return reject('profile-not-user-selectable', 'stored preference is not user-selectable', RendererDecisionReason.UserPreferenceUnknown);
  }
  if (spec.windowProviders.indexOf(provider) < 0) {
    return reject('window-provider-unsupported', 'manifest window provider ' + provider + ' is unsupported',
      RendererDecisionReason.DevOverrideUnsupportedWindowSystem);
  }
  const policy: VulkanPolicy = input.vulkanPolicy ?? VulkanPolicy.ALLOW;
  if (policy === VulkanPolicy.DISABLE_VULKAN && spec.api === GraphicsGameApi.VULKAN) {
    return reject('vulkan-api-disabled', 'DISABLE_VULKAN excludes the Minecraft Vulkan API');
  }
  if (policy === VulkanPolicy.FORBID_VULKAN_TRANSPORT && spec.transport !== GraphicsTransport.NO) {
    return reject('vulkan-transport-unproven', 'FORBID_VULKAN_TRANSPORT requires proven non-Vulkan implementation');
  }
  if (spec.capabilityKind === GraphicsCapabilityKind.NativeGl) {
    if (input.lwjglVersion === 2) return reject('desktop-lwjgl2-unsupported', '电脑原生 OpenGL 暂不支持 LWJGL2');
    const failure: string = nativeGlProbeFailure(spec, provider, input);
    if (failure.length > 0) return reject('capability-unverified', failure);
  }
  if (request.source !== GraphicsRequestSource.DEFAULT && request.source !== GraphicsRequestSource.FORCED
      && !graphicsVersionAtLeast(input.realMcVersion, spec.gameMinimum)) {
    return reject('game-version-unsupported', 'profile requires MC >= ' + spec.gameMinimum,
      request.source === GraphicsRequestSource.USER
        ? RendererDecisionReason.UserPreferenceRejectedByVersion : RendererDecisionReason.DevOverrideRejectedByVersion);
  }
  if (spec.api === GraphicsGameApi.VULKAN) {
    // Validation builds and desktop expose experimental native Vulkan by default;
    // callers can explicitly disable it (for example a production mobile build).
    const experimentalAllowed: boolean = input.allowExperimentalProfiles !== false;
    if (spec.lifecycle === RendererBackendLifecycle.Experimental && !experimentalAllowed) {
      return reject('experimental-profile-disabled', 'experimental profile requires explicit opt-in on mobile');
    }
    if (input.lwjglVersion === 2) return reject('vulkan-lwjgl2-unsupported', 'native Vulkan requires a LWJGL3 game');
    if (input.usesSdl3 === undefined) return reject('manifest-provider-unknown', 'Vulkan requires an explicit manifest window provider');
    const requestedRequirement: string = input.requirementId ?? spec.requirementId;
    if (!graphicsRequirementSupported(spec, requestedRequirement)) {
      return reject('requirement-unverified', 'unrecognised game requirement audit id');
    }
  }
  if (spec.capabilityKind === GraphicsCapabilityKind.Vulkan) {
    const requestedRequirement: string = spec.api === GraphicsGameApi.VULKAN
      ? (input.requirementId || spec.requirementId) : spec.requirementId;
    const failure: string = probeFailure(spec, requestedRequirement, provider,
      capabilityResultFor(input, spec, requestedRequirement, provider),
      input.availabilityOnly === true || input.nativePreflightPending === true);
    if (failure.length > 0) return reject('capability-unverified', failure);
  }
  return { code: 'admitted', detail: 'profile, provider and required capability gates passed', legacyReason: request.decisionReason };
}

/** Ordered candidate resolution. Failed candidates remain visible, and only the first admitted candidate is selected. */
export function resolveGraphicsProfile(input: GraphicsProfileInput): GraphicsProfileResolution {
  const platform: GraphicsPlatformFamily = platformForInput(input);
  const provider: GraphicsWindowProvider = input.usesSdl3 === true ? GraphicsWindowProvider.SDL3 : GraphicsWindowProvider.GLFW;
  const dev: string = input.devOverrideBackendId ?? '';
  const hasCanonicalPreference: boolean = input.graphicsProfilePreference !== undefined;
  const savedPreference: string = preferenceProfileId(input.graphicsProfilePreference ?? '');
  const canonicalPreference: string = input.graphicsProfileExplicit === false
      && savedPreference === graphicsProfileByRole(GraphicsSelectionRole.Default).id ? '' : savedPreference;
  const requested: string = dev.length > 0 ? dev : (canonicalPreference.length > 0
    ? canonicalPreference : (input.userPreferredBackendId || 'auto'));
  const requests: GraphicsRequest[] = [];
  const candidates: GraphicsCandidate[] = [];
  const exclusions: string[] = [];
  const fixed: RendererDecisionReason | undefined = fixedFunctionReason(input);
  const recoveryProfile: string = input.graphicsRecoveryProfile ?? '';
  const requiredProfile: string = recoveryProfile.length > 0 ? recoveryProfile :
    (dev.length === 0 && input.graphicsProfileExplicit === true && graphicsProfileById(canonicalPreference) !== undefined
      ? canonicalPreference : '');
  if (fixed !== undefined) addRequest(requests, graphicsProfileByRole(GraphicsSelectionRole.FixedFunction).id, GraphicsRequestSource.FORCED, fixed);
  if (recoveryProfile.length > 0) addRequest(requests, recoveryProfile, GraphicsRequestSource.DEFAULT, RendererDecisionReason.Default);
  addRequest(requests, dev, GraphicsRequestSource.DEV, RendererDecisionReason.DevOverride);
  if (input.gameApi === GraphicsGameApi.VULKAN) {
    addRequest(requests, graphicsProfileByRole(GraphicsSelectionRole.GameVulkan).id, GraphicsRequestSource.GAME_API, RendererDecisionReason.RequiredByGameApi);
  }
  if (dev.length === 0 && canonicalPreference.length > 0) {
    addRequest(requests, canonicalPreference, GraphicsRequestSource.PREFERENCE, RendererDecisionReason.UserPreference);
  }
  const fallback: GraphicsProfileSpec = graphicsProfileByRole(platform === GraphicsPlatformFamily.DESKTOP
    ? GraphicsSelectionRole.DesktopDefault : GraphicsSelectionRole.Default);
  if (!hasCanonicalPreference && input.userPreferredBackendId !== fallback.id) {
    addRequest(requests, input.userPreferredBackendId, GraphicsRequestSource.USER, RendererDecisionReason.UserPreference);
  }
  // 游戏版本默认的 Vulkan 排在各平台 OpenGL 默认之前，显式偏好仍先评估。保持 DUAL
  // 能力集合，不制造严格 Vulkan 请求；设备/窗口/资产拒绝后继续原 OpenGL 候选顺序。
  // 单独的 GAME_DEFAULT 来源不参与 OpenGL 历史重排，旧版没有此自动推荐元数据。
  if (fixed === undefined) {
    for (const spec of GRAPHICS_PROFILES) {
      if (spec.api === GraphicsGameApi.VULKAN && spec.autoPreferredFrom.length > 0
          && graphicsVersionAtLeast(input.realMcVersion, spec.autoPreferredFrom)) {
        addRequest(requests, spec.id, GraphicsRequestSource.GAME_DEFAULT, RendererDecisionReason.PreferredByGameDefault);
      }
    }
  }
  // Vulkan 未准入时继续既有 OpenGL 排序：电脑优先系统 GL，然后按版本推荐翻译器。
  if (platform === GraphicsPlatformFamily.DESKTOP) {
    addRequest(requests, fallback.id, GraphicsRequestSource.DEFAULT, RendererDecisionReason.RequiredByDesktop);
  }
  if (fixed === undefined) {
    for (const spec of GRAPHICS_PROFILES) {
      if (spec.api === GraphicsGameApi.OPENGL && spec.autoPreferredFrom.length > 0
          && graphicsVersionAtLeast(input.realMcVersion, spec.autoPreferredFrom)) {
        addRequest(requests, spec.id, GraphicsRequestSource.DEFAULT, RendererDecisionReason.Default);
      }
    }
  }
  addRequest(requests, fallback.id, GraphicsRequestSource.DEFAULT, platform === GraphicsPlatformFamily.DESKTOP
    ? RendererDecisionReason.RequiredByDesktop : RendererDecisionReason.Default);
  const secondaryFallback: GraphicsProfileSpec = graphicsProfileByRole(platform === GraphicsPlatformFamily.DESKTOP
    ? GraphicsSelectionRole.Default : GraphicsSelectionRole.DesktopDefault);
  addRequest(requests, secondaryFallback.id, GraphicsRequestSource.DEFAULT, RendererDecisionReason.Default);

  // 历史只在已有DEFAULT位置之间稳定重排；forced/user/API请求以及锁定候选保持原位，
  // 后续每项仍执行完整admission。scope不同/非法优先级不是可消费证据。
  const priority = (id: string): number => {
    if (!input.graphicsHistoryScope || !new RegExp('^[0-9a-f]{64}$').test(input.graphicsHistoryScope)) return 0;
    for (const hint of input.graphicsHistory ?? []) if (hint.profile === id && hint.scopeHash === input.graphicsHistoryScope
      && (hint.priority === 1 || hint.priority === -1)) return hint.priority;
    return 0;
  };
  if (requiredProfile.length === 0 && dev.length === 0 && fixed === undefined) {
    const positions: number[] = [];
    const defaults: GraphicsRequest[] = [];
    for (let i: number = 0; i < requests.length; ++i) if (requests[i].source === GraphicsRequestSource.DEFAULT) {
      positions.push(i); defaults.push(requests[i]);
    }
    defaults.sort((left: GraphicsRequest, right: GraphicsRequest): number => priority(right.id) - priority(left.id));
    for (let i: number = 0; i < positions.length; ++i) requests[positions[i]] = defaults[i];
  }

  let selected: GraphicsCandidate | undefined = undefined;
  let firstPreferenceFailure: RendererDecisionReason | undefined = undefined;
  for (let i = 0; i < requests.length; i++) {
    const request: GraphicsRequest = requests[i];
    const spec: GraphicsProfileSpec | undefined = graphicsProfileById(request.id);
    const check: AdmissionCheck = spec === undefined
      ? reject('profile-unknown', 'profile is absent from the canonical registry', request.source === GraphicsRequestSource.USER
        ? RendererDecisionReason.UserPreferenceUnknown : RendererDecisionReason.DevOverrideInvalid)
      : requiredProfile.length > 0 && request.id !== requiredProfile
        ? reject('selection-locked', 'explicit preference or bounded recovery requires ' + requiredProfile)
        : admissionFor(input, request, spec, provider, platform);
    const admitted: boolean = check.code === 'admitted';
    const variant: GraphicsProviderVariant | undefined = spec === undefined
      ? undefined : graphicsProviderForManifest(spec, input.usesSdl3 === true, platform);
    const candidate: GraphicsCandidate = {
      id: request.id, provider: provider, platformFamily: platform, source: request.source,
      admitted: admitted, selected: admitted && selected === undefined,
      reasonCode: check.code, reason: check.detail, decisionReason: request.decisionReason,
      profile: spec, providerVariant: variant,
    };
    candidates.push(candidate);
    if (!admitted) {
      exclusions.push(candidate.id + '[' + provider + ']: ' + check.code + ': ' + check.detail);
      if (firstPreferenceFailure === undefined
          && (request.source === GraphicsRequestSource.DEV || request.source === GraphicsRequestSource.USER
            || request.source === GraphicsRequestSource.PREFERENCE)) {
        firstPreferenceFailure = (request.source === GraphicsRequestSource.USER
          || request.source === GraphicsRequestSource.PREFERENCE)
          && check.legacyReason !== RendererDecisionReason.UserPreferenceRejectedByVersion
          ? RendererDecisionReason.UserPreferenceUnknown : check.legacyReason;
      }
    }
    if (candidate.selected) selected = candidate;
  }

  let decision: RendererDecision | undefined = undefined;
  if (selected !== undefined) {
    const reason: RendererDecisionReason = selected.source === GraphicsRequestSource.DEFAULT
      && selected.decisionReason === RendererDecisionReason.Default && firstPreferenceFailure !== undefined
      ? firstPreferenceFailure : selected.decisionReason;
    decision = {
      backendId: selected.id, reason: reason,
      userPreferenceHonored: reason === RendererDecisionReason.UserPreference,
      logLine: 'Renderer route: ' + selected.id + ' via ' + selected.provider + ' (' + selected.platformFamily + ') — '
        + reason + (exclusions.length > 0 ? '; excluded: ' + exclusions.join(' | ') : ''),
    };
  }
  return { requestedProfile: requested, decision: decision, selectedCandidate: selected, candidates: candidates, exclusions: exclusions };
}

/** Enumerate every non-retired profile for UI rows. This is an availability report,
 * never a priority list and never marks a row selected. */
export function listGraphicsProfileAvailability(input: GraphicsProfileInput): GraphicsCandidate[] {
  const platform: GraphicsPlatformFamily = platformForInput(input);
  const provider: GraphicsWindowProvider = input.usesSdl3 === true ? GraphicsWindowProvider.SDL3 : GraphicsWindowProvider.GLFW;
  const rows: GraphicsCandidate[] = [];
  for (let i = 0; i < GRAPHICS_PROFILES.length; i++) {
    const spec: GraphicsProfileSpec = GRAPHICS_PROFILES[i];
    if (spec.lifecycle === RendererBackendLifecycle.Retired) continue;
    const request: GraphicsRequest = { id: spec.id, source: GraphicsRequestSource.PREFERENCE,
      decisionReason: RendererDecisionReason.UserPreference };
    const check: AdmissionCheck = admissionFor(input, request, spec, provider, platform);
    rows.push({ id: spec.id, provider: provider, platformFamily: platform, source: request.source,
      admitted: check.code === 'admitted', selected: false, reasonCode: check.code, reason: check.detail,
      decisionReason: request.decisionReason, profile: spec,
      providerVariant: graphicsProviderForManifest(spec, input.usesSdl3 === true, platform) });
  }
  return rows;
}

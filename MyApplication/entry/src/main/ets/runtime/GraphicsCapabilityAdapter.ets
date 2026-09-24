import { VersionParser, ParsedVersion } from 'feature_core';
import { CapabilityEvidence, CapabilityResult, GraphicsGameApi, VulkanEvidence, GraphicsProfileInput,
  createDeviceGraphicsFacts, GraphicsGameFacts, graphicsGameFacts } from 'launch';
import deviceInfo from '@ohos.deviceInfo';
import { resolveInstalledMcVersion } from 'mods';
import { AppLogger, VULKAN_264_REFERENCE_VERSION, VULKAN_264_REQUIREMENT_ID } from 'commons';
import { computeFileSha1 } from 'feature_core';
import testNapi from 'libentry.so';
import { NativeGlCapability } from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { attachGraphicsHistory } from './GraphicsHistoryScope';

interface GraphicsArtifactProfile {
  id: string;
  artifactIds: string[];
}
interface GraphicsArtifactManifest {
  schemaVersion: number;
  abi: string;
  availableProfileIds: string[];
  profiles: GraphicsArtifactProfile[];
}

export class GraphicsLaunchCapability {
  gameApi: GraphicsGameApi = GraphicsGameApi.UNKNOWN;
  requirementId: string = '';
  windowProvider: string = '';
  capability: CapabilityResult | undefined = undefined;
}

function normalizeEvidence(value: CapabilityEvidence): CapabilityEvidence {
  if (value === CapabilityEvidence.YES || value === CapabilityEvidence.NO || value === CapabilityEvidence.UNKNOWN) {
    return value;
  }
  return CapabilityEvidence.NOT_RUN;
}

/**
 * 可选 native 探针异常只使本候选证据不可用，不证明设备“不支持”，也不能拖垮其他后端。
 * 身份仍绑定本次实际请求，避免后续诊断把异常证据归到另一个 profile/provider。
 */
function failedGraphicsCapability(profileId: string, requirementId: string, provider: string): CapabilityResult {
  return {
    evidenceProfileId: profileId, requirementId: requirementId, windowProvider: provider,
    evidenceScope: 'device-entry', loader: CapabilityEvidence.UNKNOWN,
    instance: CapabilityEvidence.NOT_RUN, windowSurface: CapabilityEvidence.NOT_RUN,
    physicalDevice: CapabilityEvidence.NOT_RUN, apiVersion: '', deviceExtensions: CapabilityEvidence.NOT_RUN,
    featureBits: CapabilityEvidence.NOT_RUN, queuePresentation: CapabilityEvidence.NOT_RUN,
    shaderToolchain: CapabilityEvidence.NOT_RUN, nativeArtifacts: CapabilityEvidence.NOT_RUN,
    lifecycleSmoke: CapabilityEvidence.NOT_RUN, reasonCode: 'native-probe-failed',
    observedProvider: 'UNKNOWN', observedUnderlyingVulkan: VulkanEvidence.UNKNOWN,
  };
}

/** 调用并归一化一个 profile 的设备探针；NAPI/JSON 异常降为 scoped UNKNOWN，由 resolver 拒绝该候选。 */
export function consumeGraphicsCapability(profileId: string, requirementId: string, provider: string): CapabilityResult {
  try {
    const json: string = testNapi.getGraphicsCapabilityJson(profileId, requirementId, provider, true);
    return normalizeGraphicsCapability(json);
  } catch (error) {
    AppLogger.warn('GraphicsCapability', 'optional graphics probe failed: profile=' + profileId
      + ' requirement=' + requirementId + ' provider=' + provider, error);
    return failedGraphicsCapability(profileId, requirementId, provider);
  }
}

/** 只复制 native 实际报告的身份和观测值，不把调用参数补成一次成功的探针身份。 */
function normalizeGraphicsCapability(json: string): CapabilityResult {
  const parsed: CapabilityResult = JSON.parse(json) as CapabilityResult;
  const result: CapabilityResult = {
    loader: normalizeEvidence(parsed.loader),
    instance: normalizeEvidence(parsed.instance),
    windowSurface: normalizeEvidence(parsed.windowSurface),
    physicalDevice: normalizeEvidence(parsed.physicalDevice),
    apiVersion: typeof parsed.apiVersion === 'string' ? parsed.apiVersion : '',
    deviceExtensions: normalizeEvidence(parsed.deviceExtensions),
    featureBits: normalizeEvidence(parsed.featureBits),
    queuePresentation: normalizeEvidence(parsed.queuePresentation),
    shaderToolchain: normalizeEvidence(parsed.shaderToolchain),
    nativeArtifacts: normalizeEvidence(parsed.nativeArtifacts),
    lifecycleSmoke: normalizeEvidence(parsed.lifecycleSmoke),
    reasonCode: typeof parsed.reasonCode === 'string' ? parsed.reasonCode : 'native_probe_result_missing',
    observedProvider: typeof parsed.observedProvider === 'string' ? parsed.observedProvider : '',
    driverIdentity: typeof parsed.driverIdentity === 'string' ? parsed.driverIdentity : '',
    observedUnderlyingVulkan: VulkanEvidence.UNKNOWN,
    evidenceProfileId: parsed.evidenceProfileId,
    requirementId: parsed.requirementId,
    windowProvider: parsed.windowProvider,
    evidenceScope: 'device-entry',
  };
  return result;
}

function booleanEvidence(value: boolean): CapabilityEvidence {
  return value ? CapabilityEvidence.YES : CapabilityEvidence.NO;
}

/** Preserve the requested probe scope even when an entry query fails before context creation. */
export function nativeGlCapabilityResult(capability: NativeGlCapability, provider: string,
  gameVersion: string = '', availabilityOnly: boolean = false): CapabilityResult {
  const observed: string = capability.vendor + (capability.renderer.length > 0 ? '/' + capability.renderer : '');
  const library: CapabilityEvidence = booleanEvidence(capability.systemLibrary);
  const query: CapabilityEvidence = booleanEvidence(capability.querySupported);
  const entryOnly: boolean = availabilityOnly;
  const context: CapabilityEvidence = entryOnly ? CapabilityEvidence.NOT_RUN : booleanEvidence(capability.contextCreated);
  const version: CapabilityEvidence = entryOnly ? CapabilityEvidence.NOT_RUN : booleanEvidence(capability.version.length > 0);
  const pixels: CapabilityEvidence = entryOnly ? CapabilityEvidence.NOT_RUN : booleanEvidence(capability.pixelVerified && capability.ready);
  return {
    evidenceProfileId: 'nativegl',
    requirementId: 'desktop-system-gl-validation-v1',
    windowProvider: provider,
    gameVersion: gameVersion,
    evidenceScope: entryOnly ? 'device-entry' : 'isolated-context',
    loader: library,
    instance: context,
    windowSurface: CapabilityEvidence.NOT_RUN,
    physicalDevice: query,
    apiVersion: capability.version,
    deviceExtensions: CapabilityEvidence.NOT_RUN,
    featureBits: CapabilityEvidence.NOT_RUN,
    queuePresentation: CapabilityEvidence.NOT_RUN,
    shaderToolchain: CapabilityEvidence.NOT_RUN,
    nativeArtifacts: library,
    lifecycleSmoke: CapabilityEvidence.NOT_RUN,
    reasonCode: capability.ready ? 'system-gl-availability-ready' : capability.stage,
    observedProvider: observed.length > 0 ? observed : 'UNKNOWN',
    observedUnderlyingVulkan: VulkanEvidence.UNKNOWN,
    systemLibrary: library,
    queryGl: query,
    eglContext: context,
    glVersion: version,
    pixelReadback: pixels,
    windowPresent: CapabilityEvidence.NOT_RUN,
  };
}

/** 本层不建立renderer context；系统入口查询仍可能初始化EGL，其能力开关已由AppScope
 * 在进程启动时提供。完整context/呈现准入继续由native在计划激活后执行。
 */
export async function prepareGraphicsProfileInput(context: common.UIAbilityContext, mcDir: string,
  versionId: string, preference: string, availabilityOnly: boolean = false,
  preferenceExplicit: boolean = true): Promise<GraphicsProfileInput> {
  const manifestPath: string = mcDir + '/versions/' + versionId + '/' + versionId + '.json';
  const manifest: ParsedVersion | null = VersionParser.parse(manifestPath);
  const game: GraphicsGameFacts = graphicsGameFacts(manifest === null ? [] : manifest.libraries,
    manifest === null ? '' : resolveInstalledMcVersion(mcDir, versionId));
  const input: GraphicsProfileInput = {
    realMcVersion: game.realMcVersion, lwjglVersion: game.lwjglVersion,
    needsLwjgl322Slot: game.needsLwjgl322Slot, usesSdl3: game.usesSdl3,
    manifestProviderVerified: !game.providerConflict,
    gameApi: manifest === null || manifest.inheritsFrom.length > 0 || game.providerConflict
      ? GraphicsGameApi.UNKNOWN : game.gameApi,
    userPreferredBackendId: preference, graphicsProfilePreference: preference,
    graphicsProfileExplicit: preferenceExplicit,
    deviceFacts: createDeviceGraphicsFacts(deviceInfo.deviceType, deviceInfo.sdkApiVersion),
    availableProfileIds: await availableGraphicsProfileIds(context),
    capabilityResults: [], availabilityOnly: availabilityOnly, nativePreflightPending: !availabilityOnly,
  };
  const results: CapabilityResult[] = [];
  const provider: string = game.usesSdl3 ? 'SDL3' : 'GLFW';
  try {
    const native: NativeGlCapability = await testNapi.getNativeGlCapability(false, true);
    results.push(nativeGlCapabilityResult(native, provider, game.realMcVersion, true));
  } catch (error) {
    AppLogger.warn('GraphicsCapability', 'system GL entry query failed', error);
  }
  if (manifest !== null && manifest.inheritsFrom.length === 0 && !game.providerConflict) {
    for (const id of ['mobilegl', 'minecraft-vulkan']) {
      if (input.availableProfileIds === undefined || input.availableProfileIds.indexOf(id) < 0) continue;
      try {
        const evidence: GraphicsLaunchCapability = await prepareGraphicsLaunchCapability(mcDir, versionId, id);
        if (evidence.capability !== undefined) {
          evidence.capability.gameVersion = game.realMcVersion;
          results.push(evidence.capability);
          if (id === 'minecraft-vulkan') input.requirementId = evidence.requirementId;
        }
      } catch (error) {
        // 这里覆盖审计/文件准备等非 native 的意外失败。未得到审计身份就不制造证据，
        // resolver 会将本候选判为未运行；继续其他候选，尤其不能使默认 MobileGlues 失效。
        AppLogger.warn('GraphicsCapability', 'optional graphics candidate preparation failed: profile=' + id, error);
      }
    }
  }
  input.capabilityResults = results;
  attachGraphicsHistory(context, input, manifestPath, versionId);
  return input;
}

function bundledLibraryExists(bundleCodeDir: string, name: string): boolean {
  try {
    return fs.accessSync(bundleCodeDir + '/libs/arm64/' + name);
  } catch (_) {
    return false;
  }
}

/** Artifact allow-list derived from the installed HAP, never from product identity. */
export async function availableGraphicsProfileIds(context: common.UIAbilityContext): Promise<string[]> {
  const bytes: Uint8Array = await context.resourceManager.getRawFileContent('graphics-manifest.json');
  const manifest: GraphicsArtifactManifest = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(bytes)) as GraphicsArtifactManifest;
  if (manifest.schemaVersion !== 1 || manifest.abi !== 'arm64-v8a'
      || !Array.isArray(manifest.availableProfileIds) || !Array.isArray(manifest.profiles)) {
    throw new Error('Invalid packaged graphics manifest');
  }
  const ids: string[] = [];
  for (const profile of manifest.profiles) {
    if (manifest.availableProfileIds.indexOf(profile.id) < 0 || !Array.isArray(profile.artifactIds)) continue;
    let present: boolean = true;
    for (const library of profile.artifactIds) {
      if (!bundledLibraryExists(context.bundleCodeDir, library)) present = false;
    }
    if (present) ids.push(profile.id);
  }
  return ids;
}

/** A user preference requests a profile. Manifest facts describe supported APIs;
 * neither claims which API the game has actually initialized. */
const MC_263_MANIFEST_ID: string = '26.3-pre-1';
const MC_263_CLIENT_SHA1: string = '32cf188ffc8c6a4143e74b1dcc689267566d73fb';
const MC_263_REQUIREMENT_ID: string = 'minecraft-26.3-pre1-vulkan-conservative-v1';
const MC_263_SDL_REQUIREMENT_ID: string = 'minecraft-26.3-sdl-vulkan-conservative-v1';
// 26.4 首个快照的实际客户端已审计。以基础版本和原始客户端摘要绑定，允许实例改名和
// 使用保留原版客户端的合并模组清单；未审计的后续快照/修改过的客户端不能借用此规则。
const MC_264_CLIENT_SHA1: string = '99dea8ec5ae3c5adc7d246061a90960e7d8441c3';

export async function prepareGraphicsLaunchCapability(mcDir: string, versionId: string,
  profileId: string): Promise<GraphicsLaunchCapability> {
  const result: GraphicsLaunchCapability = new GraphicsLaunchCapability();
  if (profileId !== 'minecraft-vulkan' && profileId !== 'mobilegl') return result;
  const manifestPath: string = mcDir + '/versions/' + versionId + '/' + versionId + '.json';
  const manifest: ParsedVersion | null = VersionParser.parse(manifestPath);
  const realVersion: string | null = VersionParser.detectVanillaVersion(manifestPath);
  if (manifest === null || realVersion === null || manifest.inheritsFrom.length > 0) return result;
  let declaresVulkan: boolean = false;
  let declaresOpenGl: boolean = false;
  let declaresGlfw: boolean = false;
  let declaresSdl: boolean = false;
  for (const library of manifest.libraries) {
    const normalized: string = library.split('\\').join('/');
    if (normalized.indexOf('org/lwjgl/lwjgl-vulkan/') >= 0) declaresVulkan = true;
    if (normalized.indexOf('org/lwjgl/lwjgl-opengl/') >= 0) declaresOpenGl = true;
    if (normalized.indexOf('org/lwjgl/lwjgl-glfw/') >= 0) declaresGlfw = true;
    if (normalized.indexOf('org/lwjgl/lwjgl-sdl/') >= 0) declaresSdl = true;
  }
  if (profileId === 'mobilegl') {
    // 只接受清单明确且唯一的窗口模块；MobileGL 的内部 Vulkan 不要求游戏使用 Vulkan API。
    if (!declaresOpenGl || declaresSdl === declaresGlfw) return result;
    result.gameApi = declaresVulkan ? GraphicsGameApi.DUAL : GraphicsGameApi.OPENGL;
    result.requirementId = 'mobilegl-direct-vulkan-v1';
    result.windowProvider = declaresSdl ? 'SDL3' : 'GLFW';
    result.capability = consumeGraphicsCapability(profileId, result.requirementId, result.windowProvider);
    return result;
  }
  // 只给已经核实的 26.4 客户端生成准入身份。元数据和实际 JAR 双重校验，任何读取失败
  // 都保持未准入；默认策略可以继续评估 OpenGL，而显式 Vulkan 请求会按原契约拒绝。
  if (realVersion === VULKAN_264_REFERENCE_VERSION) {
    if (!declaresVulkan || !declaresSdl || declaresGlfw || manifest.clientSha1.toLowerCase() !== MC_264_CLIENT_SHA1) return result;
    let actualClientSha1: string = '';
    try {
      actualClientSha1 = (await computeFileSha1(mcDir + '/versions/' + versionId + '/' + versionId + '.jar')).toLowerCase();
    } catch (e) {
      return result;
    }
    if (actualClientSha1 !== MC_264_CLIENT_SHA1) return result;
    result.gameApi = GraphicsGameApi.DUAL;
    result.requirementId = VULKAN_264_REQUIREMENT_ID;
    result.windowProvider = 'SDL3';
    result.capability = consumeGraphicsCapability(profileId, result.requirementId, result.windowProvider);
    return result;
  }
  // 26.3-pre-1 is the first SDL3 Vulkan candidate. The requirement is bound
  // to the exact manifest id and the actual client.jar bytes; a renamed or
  // later preview must stay outside this admission path until audited.
  if (manifest.id === MC_263_MANIFEST_ID && versionId === MC_263_MANIFEST_ID) {
    if (!declaresVulkan || !declaresSdl || declaresGlfw || manifest.clientSha1.toLowerCase() !== MC_263_CLIENT_SHA1) return result;
    let actualClientSha1: string = '';
    try {
      actualClientSha1 = (await computeFileSha1(mcDir + '/versions/' + versionId + '/' + versionId + '.jar')).toLowerCase();
    } catch (e) {
      return result;
    }
    if (actualClientSha1 !== MC_263_CLIENT_SHA1) return result;
    result.gameApi = GraphicsGameApi.DUAL;
    result.requirementId = MC_263_REQUIREMENT_ID;
    result.windowProvider = 'SDL3';
    result.capability = consumeGraphicsCapability(profileId, result.requirementId, result.windowProvider);
    return result;
  }
  // Later 26.3 SDL builds keep the same audited Vulkan feature contract but
  // have different client bytes. The manifest still has to declare SDL3 +
  // Vulkan and must not expose the GLFW provider; the native probe remains
  // authoritative for the device and surface gates.
  if (new RegExp('^26\\.3(?:-(?:snapshot|pre|rc)-[0-9]+)?$').test(realVersion)
      && declaresVulkan && declaresSdl && !declaresGlfw) {
    result.gameApi = GraphicsGameApi.DUAL;
    result.requirementId = MC_263_SDL_REQUIREMENT_ID;
    result.windowProvider = 'SDL3';
    result.capability = consumeGraphicsCapability(profileId, result.requirementId, result.windowProvider);
    return result;
  }
  // This audit covers the 26.2 GLFW family. Exact manifest metadata is required;
  // renamed folders, arbitrary suffixes and later releases cannot extend it.
  if (!new RegExp('^26\\.2(?:\\.[0-9]+)?(?:-(?:snapshot|pre|rc)-[0-9]+)?$').test(realVersion)) return result;
  if (!declaresVulkan || !declaresGlfw || declaresSdl) return result;
  result.gameApi = GraphicsGameApi.DUAL;
  result.requirementId = 'minecraft-26.2-conservative-v1';
  result.windowProvider = 'GLFW';
  result.capability = consumeGraphicsCapability(profileId, result.requirementId, result.windowProvider);
  return result;
}

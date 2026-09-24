/** Canonical profile metadata. Legacy views and native mirrors are derived from this table. */
export enum RendererBackendLifecycle {
  Default = 'default',
  PlatformDefault = 'platform-default',
  ForcedByVersion = 'forced-by-version',
  Optional = 'optional',
  Experimental = 'experimental',
  Candidate = 'candidate',
  Retired = 'retired',
}
export enum RendererWindowAcquisition {
  None = 'none',
  CurrentContext = 'current-context',
  NativeWindowLease = 'native-window-lease',
}
export enum GraphicsGameApi { OPENGL = 'OPENGL', VULKAN = 'VULKAN', DUAL = 'DUAL', UNKNOWN = 'UNKNOWN' }
export enum GraphicsTransport { YES = 'YES', NO = 'NO', UNKNOWN = 'UNKNOWN' }
export enum GraphicsAdmission { LEGACY = 'LEGACY', VALIDATION = 'VALIDATION', VERIFIED = 'VERIFIED' }
export enum GraphicsWindowProvider { GLFW = 'GLFW', SDL3 = 'SDL3', UNKNOWN = 'UNKNOWN' }
export enum GraphicsPlatformFamily { MOBILE = 'MOBILE', DESKTOP = 'DESKTOP', UNKNOWN = 'UNKNOWN' }
export enum GraphicsSelectionRole {
  Default = 'default',
  FixedFunction = 'fixed-function',
  DesktopDefault = 'desktop-default',
  Explicit = 'explicit',
  GameVulkan = 'game-vulkan',
  Retired = 'retired',
}
export enum GraphicsCapabilityKind { Legacy = 'legacy', NativeGl = 'native-gl', Vulkan = 'vulkan' }
/** 上下文协议描述宿主应调用的 API；MobileGL 内部 Vulkan 不改变其桌面 GL 语义。 */
export enum GraphicsContextApi { DESKTOP_GL = 'desktop-gl', GLES = 'gles', NONE = 'none' }
/** 描述适配器实现的能力，实际设备仍须创建/呈现探针成功，不能由声明制造阳性证据。 */
export enum GraphicsFeatureSupport {
  SUPPORTED = 'supported', UNSUPPORTED = 'unsupported',
  /** 适配器有实现，但须通过本进程的对象读回/状态隔离实测后才允许额外context。 */
  PROBE_REQUIRED = 'probe-required'
}

export interface GraphicsProviderVariant {
  provider: GraphicsWindowProvider;
  platformFamily: GraphicsPlatformFamily;
  startupDomain: string;
  resourceOwner: string;
}

export interface GraphicsProfileSpec {
  id: string;
  displayName: string;
  api: GraphicsGameApi;
  nativeRoute: string;
  implementationChain: string;
  windowProviders: GraphicsWindowProvider[];
  platforms: GraphicsPlatformFamily[];
  /** Capability identities are the actual admission contract. */
  requiredCapabilities: string[];
  artifactIds: string[];
  license: string;
  startupDomain: string;
  resourceOwner: string;
  transport: GraphicsTransport;
  lifecycle: RendererBackendLifecycle;
  selectionRole: GraphicsSelectionRole;
  gameMinimum: string;
  requirementId: string;
  /** Additional audited requirement identities for this profile. The primary
   * requirementId remains the default/legacy identity used by old callers. */
  requirementIds?: string[];
  capabilityKind: GraphicsCapabilityKind;
  /** 自动优先的最低真实游戏版本；空值不增加候选，旧默认与固定管线语义保持独立。 */
  autoPreferredFrom: string;
  contextApi: GraphicsContextApi;
  glfwSharedContext: GraphicsFeatureSupport;
  glfwAuxiliaryWindow: GraphicsFeatureSupport;
  /** SDL辅助窗口提供同context可切换的surface；额外独立/共享context仍须公共运行时实测准入。 */
  sdlAuxiliaryWindow: GraphicsFeatureSupport;
  parkingContext: GraphicsFeatureSupport;
  admission: GraphicsAdmission;
  glLibName: string;
  systemLibrary: boolean;
  ownsEgl: boolean;
  ownsPresent: boolean;
  windowAcquisition: RendererWindowAcquisition;
  userSelectable: boolean;
  restartRequired: boolean;
  rationale: string;
}

// Keep this declarative: the build gate parses this array without executing ArkTS.
export const GRAPHICS_PROFILES: GraphicsProfileSpec[] = [
  {
    id: 'mobileglues', displayName: 'MobileGlues', api: GraphicsGameApi.OPENGL,
    nativeRoute: 'mobileglues', implementationChain: 'mobileglues->gles',
    windowProviders: [GraphicsWindowProvider.GLFW, GraphicsWindowProvider.SDL3],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    requiredCapabilities: ['TRANSLATOR_DSO', 'GLES_CONTEXT'], startupDomain: 'process-init', resourceOwner: 'MOBILEGLUES_SESSION',
    artifactIds: ['libamcl_graphics_runtime.so', 'libamcl_gl_host.so', 'libglfw.so'], license: 'LGPL-2.1',
    transport: GraphicsTransport.UNKNOWN, lifecycle: RendererBackendLifecycle.Default,
    selectionRole: GraphicsSelectionRole.Default, gameMinimum: '1.17', requirementId: 'legacy-gl',
    capabilityKind: GraphicsCapabilityKind.Legacy, admission: GraphicsAdmission.LEGACY,
    autoPreferredFrom: '', contextApi: GraphicsContextApi.GLES,
    glfwSharedContext: GraphicsFeatureSupport.PROBE_REQUIRED, glfwAuxiliaryWindow: GraphicsFeatureSupport.PROBE_REQUIRED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.SUPPORTED, parkingContext: GraphicsFeatureSupport.SUPPORTED,
    glLibName: 'libamcl_gl_host.so', systemLibrary: false, ownsEgl: true, ownsPresent: false,
    windowAcquisition: RendererWindowAcquisition.None, userSelectable: true, restartRequired: false,
    rationale: 'Default modern OpenGL translation provider; its underlying system driver transport is not inferred.',
  },
  {
    id: 'gl4es', displayName: 'gl4es (Holy-GL4ES)', api: GraphicsGameApi.OPENGL,
    nativeRoute: 'gl4es', implementationChain: 'gl4es->gles',
    windowProviders: [GraphicsWindowProvider.GLFW, GraphicsWindowProvider.SDL3],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    requiredCapabilities: ['TRANSLATOR_DSO', 'GLES_CONTEXT'], startupDomain: 'process-init', resourceOwner: 'GL4ES_SESSION',
    artifactIds: ['libamcl_graphics_runtime.so', 'libgl4es.so', 'libglfw.so'], license: 'MIT',
    transport: GraphicsTransport.UNKNOWN, lifecycle: RendererBackendLifecycle.ForcedByVersion,
    selectionRole: GraphicsSelectionRole.FixedFunction, gameMinimum: '0', requirementId: 'legacy-gl4es',
    capabilityKind: GraphicsCapabilityKind.Legacy, admission: GraphicsAdmission.LEGACY,
    autoPreferredFrom: '', contextApi: GraphicsContextApi.GLES,
    glfwSharedContext: GraphicsFeatureSupport.PROBE_REQUIRED, glfwAuxiliaryWindow: GraphicsFeatureSupport.PROBE_REQUIRED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.SUPPORTED, parkingContext: GraphicsFeatureSupport.SUPPORTED,
    glLibName: 'libgl4es.so', systemLibrary: false, ownsEgl: false, ownsPresent: false,
    windowAcquisition: RendererWindowAcquisition.CurrentContext, userSelectable: false, restartRequired: false,
    rationale: 'Required by LWJGL2 and the existing LWJGL322 fixed-function route; compiled with NOEGL.',
  },
  {
    id: 'mobilegl', displayName: 'MobileGL (DirectVulkan)', api: GraphicsGameApi.OPENGL,
    nativeRoute: 'mobilegl', implementationChain: 'mobilegl->vulkan',
    windowProviders: [GraphicsWindowProvider.GLFW, GraphicsWindowProvider.SDL3],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    // 翻译器能力与窗口入口正交；证据仍绑定实际 GLFW/SDL3，不能跨 provider 借用。
    requiredCapabilities: ['TRANSLATOR_DSO', 'WINDOW_PROVIDER', 'SURFACE_PRESENT'],
    artifactIds: ['libamcl_graphics_runtime.so', 'libmobilegl.so', 'libglfw.so', 'libSDL3.so', 'liblwjgl.so'], license: 'LGPL-3.0',
    startupDomain: 'process-init', resourceOwner: 'MOBILEGL_SESSION', transport: GraphicsTransport.YES,
    // 与 MobileGlues 同属 OpenGL 翻译器。Optional 表示包内资产和实际 GLFW/SDL3
    // 设备准入通过后可显式选择；默认策略仍独立，不能借另一窗口 provider 的证据。
    lifecycle: RendererBackendLifecycle.Optional, selectionRole: GraphicsSelectionRole.Explicit,
    gameMinimum: '1.17', requirementId: 'mobilegl-direct-vulkan-v1',
    requirementIds: ['mobilegl-sdl3-validation-v1'],
    capabilityKind: GraphicsCapabilityKind.Vulkan, admission: GraphicsAdmission.VALIDATION,
    autoPreferredFrom: '26.2', contextApi: GraphicsContextApi.DESKTOP_GL,
    glfwSharedContext: GraphicsFeatureSupport.PROBE_REQUIRED, glfwAuxiliaryWindow: GraphicsFeatureSupport.PROBE_REQUIRED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.SUPPORTED, parkingContext: GraphicsFeatureSupport.SUPPORTED,
    glLibName: 'libmobilegl.so', systemLibrary: false, ownsEgl: false, ownsPresent: true,
    windowAcquisition: RendererWindowAcquisition.NativeWindowLease, userSelectable: true, restartRequired: true,
    rationale: 'OpenGL peer with DirectGLES/DirectVulkan implementation; version, provider and artifact evidence remain required.',
  },
  {
    id: 'zink', displayName: 'Zink (OpenGL on Vulkan)', api: GraphicsGameApi.OPENGL,
    nativeRoute: 'zink', implementationChain: 'zink->vulkan',
    windowProviders: [GraphicsWindowProvider.GLFW],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    requiredCapabilities: ['RETIRED'],
    artifactIds: [], license: 'retired',
    startupDomain: 'process-init', resourceOwner: 'ZINK_SESSION', transport: GraphicsTransport.YES,
    lifecycle: RendererBackendLifecycle.Retired, selectionRole: GraphicsSelectionRole.Retired,
    gameMinimum: '1.17', requirementId: 'retired', capabilityKind: GraphicsCapabilityKind.Vulkan,
    admission: GraphicsAdmission.VALIDATION, glLibName: 'libOSMesa.so', systemLibrary: false,
    autoPreferredFrom: '', contextApi: GraphicsContextApi.NONE,
    glfwSharedContext: GraphicsFeatureSupport.UNSUPPORTED, glfwAuxiliaryWindow: GraphicsFeatureSupport.UNSUPPORTED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.UNSUPPORTED, parkingContext: GraphicsFeatureSupport.UNSUPPORTED,
    ownsEgl: false, ownsPresent: true, windowAcquisition: RendererWindowAcquisition.NativeWindowLease,
    userSelectable: false, restartRequired: true,
    rationale: 'Retired preference tombstone. Native OSMesa host hooks and runtime route were removed.',
  },
  {
    id: 'nativegl', displayName: 'HarmonyOS OpenGL', api: GraphicsGameApi.OPENGL,
    nativeRoute: 'nativegl', implementationChain: 'system-egl->opengl',
    windowProviders: [GraphicsWindowProvider.GLFW, GraphicsWindowProvider.SDL3],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    requiredCapabilities: ['SYSTEM_GL_CONTEXT'], startupDomain: 'process-init', resourceOwner: 'SYSTEM_GL_SESSION',
    artifactIds: ['libamcl_graphics_runtime.so', 'libglfw.so'], license: 'system-provided',
    transport: GraphicsTransport.UNKNOWN, lifecycle: RendererBackendLifecycle.PlatformDefault,
    selectionRole: GraphicsSelectionRole.DesktopDefault, gameMinimum: '0',
    requirementId: 'desktop-system-gl-validation-v1', capabilityKind: GraphicsCapabilityKind.NativeGl,
    admission: GraphicsAdmission.VALIDATION, glLibName: 'libGLv4.so', systemLibrary: true,
    autoPreferredFrom: '', contextApi: GraphicsContextApi.DESKTOP_GL,
    glfwSharedContext: GraphicsFeatureSupport.PROBE_REQUIRED, glfwAuxiliaryWindow: GraphicsFeatureSupport.PROBE_REQUIRED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.SUPPORTED, parkingContext: GraphicsFeatureSupport.SUPPORTED,
    ownsEgl: false, ownsPresent: false, windowAcquisition: RendererWindowAcquisition.CurrentContext,
    userSelectable: true, restartRequired: false,
    rationale: 'System OpenGL requires a verified context; device form only affects candidate ordering.',
  },
  {
    id: 'minecraft-vulkan', displayName: 'Minecraft Vulkan', api: GraphicsGameApi.VULKAN,
    nativeRoute: 'minecraft-vulkan', implementationChain: 'minecraft->vulkan',
    windowProviders: [GraphicsWindowProvider.GLFW, GraphicsWindowProvider.SDL3],
    platforms: [GraphicsPlatformFamily.MOBILE, GraphicsPlatformFamily.DESKTOP],
    requiredCapabilities: ['VULKAN_1_2', 'SURFACE_PRESENT', 'SHADER_TOOLCHAIN'],
    artifactIds: ['libamcl_graphics_runtime.so', 'libamcl_vulkan_wsi.so', 'libamcl_window_host.so', 'liblwjgl.so',
      'libshaderc.so', 'libspirv-cross.so', 'liblwjgl_vma.so', 'libglfw.so', 'libSDL3.so'],
    license: 'component-notices:docs/CREDITS.md',
    startupDomain: 'game-init', resourceOwner: 'MINECRAFT', transport: GraphicsTransport.YES,
    lifecycle: RendererBackendLifecycle.Experimental, selectionRole: GraphicsSelectionRole.GameVulkan,
    gameMinimum: '26.2', requirementId: 'minecraft-26.2-conservative-v1',
    // 各代使用独立审计身份；26.4 的放宽不能反向影响 26.2/26.3 的探针要求。
    requirementIds: ['minecraft-26.3-pre1-vulkan-conservative-v1', 'minecraft-26.3-sdl-vulkan-conservative-v1',
      'minecraft-26.4-snapshot1-sdl-vulkan-v1'],
    capabilityKind: GraphicsCapabilityKind.Vulkan, admission: GraphicsAdmission.VALIDATION,
    // 与游戏 26.4 的默认 API 同步；仍需版本审计、实际能力与资产均通过才进入 Vulkan。
    // 未审计的新快照不会产生有效 requirement/evidence，因此依旧回到 OpenGL 候选。
    autoPreferredFrom: '26.4', contextApi: GraphicsContextApi.NONE,
    glfwSharedContext: GraphicsFeatureSupport.UNSUPPORTED, glfwAuxiliaryWindow: GraphicsFeatureSupport.UNSUPPORTED,
    sdlAuxiliaryWindow: GraphicsFeatureSupport.UNSUPPORTED, parkingContext: GraphicsFeatureSupport.UNSUPPORTED,
    glLibName: '', systemLibrary: false, ownsEgl: false, ownsPresent: true,
    windowAcquisition: RendererWindowAcquisition.NativeWindowLease, userSelectable: true, restartRequired: true,
    rationale: 'Game API, manifest window provider, audited requirement and matching native probe must all admit the candidate.',
  },
];

export function graphicsProfileById(id: string): GraphicsProfileSpec | undefined {
  for (let i = 0; i < GRAPHICS_PROFILES.length; i++) {
    if (GRAPHICS_PROFILES[i].id === id) return GRAPHICS_PROFILES[i];
  }
  return undefined;
}

export function graphicsProfileByRole(role: GraphicsSelectionRole): GraphicsProfileSpec {
  for (let i = 0; i < GRAPHICS_PROFILES.length; i++) {
    if (GRAPHICS_PROFILES[i].selectionRole === role) return GRAPHICS_PROFILES[i];
  }
  throw new Error('Canonical graphics profile role is absent: ' + role);
}

export const GRAPHICS_DEFAULT_PROFILE_ID: string = graphicsProfileByRole(GraphicsSelectionRole.Default).id;

/** Return true only for a requirement identity explicitly audited for this profile. */
export function graphicsRequirementSupported(spec: GraphicsProfileSpec, requirementId: string): boolean {
  if (requirementId === spec.requirementId) return true;
  if (spec.requirementIds === undefined) return false;
  return spec.requirementIds.indexOf(requirementId) >= 0;
}

/** The version manifest declares the window API. Platform identity never replaces it. */
export function graphicsProviderForManifest(spec: GraphicsProfileSpec, usesSdl3: boolean,
                                           platform: GraphicsPlatformFamily): GraphicsProviderVariant | undefined {
  const provider: GraphicsWindowProvider = usesSdl3 ? GraphicsWindowProvider.SDL3 : GraphicsWindowProvider.GLFW;
  if (spec.windowProviders.indexOf(provider) < 0) return undefined;
  return { provider: provider, platformFamily: platform, startupDomain: spec.startupDomain, resourceOwner: spec.resourceOwner };
}

/** Preserve the old leading-numeric segment semantics, including 1.17-pre1. */
export function graphicsVersionAtLeast(version: string, minimum: string): boolean {
  if (version.length === 0) return false;
  const a: string[] = version.split('.');
  const b: string[] = minimum.split('.');
  const n: number = a.length > b.length ? a.length : b.length;
  for (let i = 0; i < n; i++) {
    const av: number = i < a.length ? numericVersionSegment(a[i]) : 0;
    const bv: number = i < b.length ? numericVersionSegment(b[i]) : 0;
    if (av !== bv) return av > bv;
  }
  return true;
}

function numericVersionSegment(segment: string): number {
  let digits: string = '';
  for (let i = 0; i < segment.length; i++) {
    const value: string = segment.charAt(i);
    if (value < '0' || value > '9') break;
    digits += value;
  }
  return digits.length === 0 ? 0 : Number.parseInt(digits, 10);
}

/** Structured graphics probe facts shared by profile planning and resolution. */
export enum VulkanEvidence { YES = 'YES', NO = 'NO', UNKNOWN = 'UNKNOWN' }

export enum CapabilityEvidence { YES = 'YES', NO = 'NO', UNKNOWN = 'UNKNOWN', NOT_RUN = 'NOT_RUN' }

export interface CapabilityResult {
  /** Evidence is scoped to one profile, requirement and manifest window provider. */
  evidenceProfileId?: string;
  requirementId?: string;
  windowProvider?: string;
  gameVersion?: string;
  evidenceScope?: string;
  loader: CapabilityEvidence;
  instance: CapabilityEvidence;
  windowSurface: CapabilityEvidence;
  physicalDevice: CapabilityEvidence;
  apiVersion: string;
  deviceExtensions: CapabilityEvidence;
  featureBits: CapabilityEvidence;
  queuePresentation: CapabilityEvidence;
  shaderToolchain: CapabilityEvidence;
  nativeArtifacts: CapabilityEvidence;
  lifecycleSmoke: CapabilityEvidence;
  reasonCode: string;
  observedProvider: string;
  driverIdentity?: string;
  observedUnderlyingVulkan: VulkanEvidence;
  /** Profile-scoped OpenGL admission facts. Optional for Vulkan/legacy fixtures. */
  systemLibrary?: CapabilityEvidence;
  queryGl?: CapabilityEvidence;
  eglContext?: CapabilityEvidence;
  glVersion?: CapabilityEvidence;
  pixelReadback?: CapabilityEvidence;
  windowPresent?: CapabilityEvidence;
}

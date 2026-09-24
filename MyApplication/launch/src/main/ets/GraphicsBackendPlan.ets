/** Versioned graphics selection plan shared by ArkTS launch and native runtime. */
import { RendererDecision, VulkanPolicy } from './GraphicsSelectionTypes';
import { resolveGraphicsProfile, GraphicsCandidate, GraphicsProfileResolution, GraphicsProfileInput, capabilityResultFor } from './GraphicsProfileResolver';
import { GraphicsGameApi, GraphicsProfileSpec, GraphicsProviderVariant, GraphicsAdmission, GraphicsTransport,
  graphicsRequirementSupported } from './GraphicsProfileRegistry';
import { CapabilityEvidence, CapabilityResult, VulkanEvidence } from './GraphicsCapabilityContract';
export { CapabilityEvidence, CapabilityResult, VulkanEvidence } from './GraphicsCapabilityContract';
export { GraphicsGameApi } from './GraphicsProfileRegistry';
export { VulkanPolicy } from './GraphicsSelectionTypes';

export enum GraphicsApiFamily { OPENGL = 'OPENGL', VULKAN = 'VULKAN' }

export interface GraphicsPlanInput extends GraphicsProfileInput {}

export interface ResolvedGraphicsPlan {
  schemaVersion: string;
  profile: string;
  apiFamily: GraphicsApiFamily;
  gameApi: GraphicsGameApi;
  nativeRoute: string;
  windowProvider: string;
  platformFamily: string;
  startupDomain: string;
  resourceOwner: string;
  underlyingVulkan: VulkanEvidence;
  vulkanPolicy: VulkanPolicy;
  requestedProfile: string;
  implementationChain: string;
  actualProvider: string;
  actualVulkanUse: VulkanEvidence;
  restartRequired: boolean;
  decisionReason: string;
  minecraftSelectedApi: string;
  capabilityResult: CapabilityResult;
  candidates: string[];
  candidateReasons: string[];
  candidateDetails: GraphicsCandidate[];
  exclusions: string[];
  decision: RendererDecision;
  lwjglSlot: string;
  admission: GraphicsAdmission;
  requirementId: string;
  legacyGlBackendMarker: string;
}

function emptyCapabilityResult(): CapabilityResult {
  return {
    loader: CapabilityEvidence.NOT_RUN, instance: CapabilityEvidence.NOT_RUN,
    windowSurface: CapabilityEvidence.NOT_RUN, physicalDevice: CapabilityEvidence.NOT_RUN,
    apiVersion: '', deviceExtensions: CapabilityEvidence.NOT_RUN,
    featureBits: CapabilityEvidence.NOT_RUN, queuePresentation: CapabilityEvidence.NOT_RUN,
    shaderToolchain: CapabilityEvidence.NOT_RUN, nativeArtifacts: CapabilityEvidence.NOT_RUN,
    lifecycleSmoke: CapabilityEvidence.NOT_RUN, reasonCode: 'not-run',
    observedProvider: 'UNKNOWN', observedUnderlyingVulkan: VulkanEvidence.UNKNOWN,
  };
}

function declaredTransport(transport: GraphicsTransport): VulkanEvidence {
  if (transport === GraphicsTransport.YES) return VulkanEvidence.YES;
  if (transport === GraphicsTransport.NO) return VulkanEvidence.NO;
  return VulkanEvidence.UNKNOWN;
}

/** Resolve once, then copy the admitted candidate's metadata. No second route table or provider decision exists here. */
export function resolveGraphicsPlan(input: GraphicsPlanInput): ResolvedGraphicsPlan {
  const resolution: GraphicsProfileResolution = resolveGraphicsProfile(input);
  const selected: GraphicsCandidate | undefined = resolution.selectedCandidate;
  const decision: RendererDecision | undefined = resolution.decision;
  if (selected === undefined || selected.profile === undefined || selected.providerVariant === undefined || decision === undefined) {
    throw new Error('No compatible graphics profile: ' + resolution.exclusions.join(' | '));
  }
  const spec: GraphicsProfileSpec = selected.profile;
  const provider: GraphicsProviderVariant = selected.providerVariant;
  const requestedRequirement: string = input.requirementId ?? '';
  const planRequirementId: string = requestedRequirement.length > 0 && graphicsRequirementSupported(spec, requestedRequirement)
    ? requestedRequirement : spec.requirementId;
  const api: GraphicsApiFamily = spec.api === GraphicsGameApi.VULKAN ? GraphicsApiFamily.VULKAN : GraphicsApiFamily.OPENGL;
  return {
    schemaVersion: 'v2', profile: spec.id, apiFamily: api, gameApi: input.gameApi ?? GraphicsGameApi.UNKNOWN,
    nativeRoute: spec.nativeRoute, windowProvider: provider.provider, platformFamily: provider.platformFamily,
    startupDomain: provider.startupDomain, resourceOwner: provider.resourceOwner,
    underlyingVulkan: declaredTransport(spec.transport), vulkanPolicy: input.vulkanPolicy ?? VulkanPolicy.ALLOW,
    requestedProfile: resolution.requestedProfile, implementationChain: spec.implementationChain,
    actualProvider: 'UNKNOWN', actualVulkanUse: VulkanEvidence.UNKNOWN,
    restartRequired: spec.restartRequired, decisionReason: decision.reason, minecraftSelectedApi: 'UNKNOWN',
    capabilityResult: capabilityResultFor(input, spec, planRequirementId, provider.provider) ?? emptyCapabilityResult(),
    candidates: resolution.candidates.map((candidate: GraphicsCandidate): string => candidate.id),
    candidateReasons: resolution.candidates.map((candidate: GraphicsCandidate): string =>
      candidate.id + '[' + candidate.provider + ']:' + candidate.reasonCode + ':' + candidate.reason),
    candidateDetails: resolution.candidates, exclusions: resolution.exclusions, decision: decision,
    lwjglSlot: input.lwjglVersion === 2 ? 'LWJGL2' : (input.needsLwjgl322Slot ? 'LWJGL322' : 'LWJGL3'),
    admission: spec.admission, requirementId: planRequirementId,
    legacyGlBackendMarker: spec.api === GraphicsGameApi.OPENGL ? spec.id : '',
  };
}

/** Compact fixed-order wire format. All values already belong to the admitted immutable selection. */
export function serializeGraphicsPlan(plan: ResolvedGraphicsPlan): string {
  const strict: string = plan.vulkanPolicy === VulkanPolicy.FORBID_VULKAN_TRANSPORT ? '1' : '0';
  return 'v=v2;profile=' + plan.profile + ';api=' + plan.apiFamily
    + ';window=' + plan.windowProvider + ';route=' + plan.nativeRoute
    + ';transport=' + plan.underlyingVulkan + ';strict=' + strict
    + ';policy=' + plan.vulkanPolicy + ';game=' + plan.gameApi + ';slot=' + plan.lwjglSlot
    + ';admission=' + plan.admission + ';requirement=' + plan.requirementId;
}

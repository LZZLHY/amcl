/** Compatibility entry point. The canonical resolver is the only selection implementation. */
import { GraphicsGameApi } from './GraphicsProfileRegistry';
import { GraphicsProfileInput, GraphicsProfileResolution, resolveGraphicsProfile } from './GraphicsProfileResolver';
import { RendererDecision, RendererResolveInput } from './GraphicsSelectionTypes';
export { RendererResolveInput, RendererDecision, RendererDecisionReason } from './GraphicsSelectionTypes';

export function resolveRendererBackend(input: RendererResolveInput): RendererDecision {
  const canonicalInput: GraphicsProfileInput = {
    realMcVersion: input.realMcVersion, lwjglVersion: input.lwjglVersion,
    needsLwjgl322Slot: input.needsLwjgl322Slot, userPreferredBackendId: input.userPreferredBackendId,
    devOverrideBackendId: input.devOverrideBackendId, usesSdl3: input.usesSdl3,
    manifestProviderVerified: input.manifestProviderVerified,
    nativeGlAvailable: input.nativeGlAvailable,
    platformFamily: input.platformFamily, deviceFacts: input.deviceFacts,
    capabilityResult: input.capabilityResult,
    capabilityResults: input.capabilityResults, requirementId: input.requirementId,
    graphicsProfilePreference: input.graphicsProfilePreference,
    graphicsProfileExplicit: input.graphicsProfileExplicit,
    availableProfileIds: input.availableProfileIds, availabilityOnly: input.availabilityOnly,
    nativePreflightPending: input.nativePreflightPending,
    allowExperimentalProfiles: input.allowExperimentalProfiles, vulkanPolicy: input.vulkanPolicy,
    gameApi: GraphicsGameApi.OPENGL,
  };
  const result: GraphicsProfileResolution = resolveGraphicsProfile(canonicalInput);
  if (result.decision === undefined) throw new Error('No compatible graphics profile: ' + result.exclusions.join(' | '));
  return result.decision;
}

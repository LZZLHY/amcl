#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { parseGraphicsRegistry } from './lib/graphics-profile-registry.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const load = makePureEtsLoader();
const registry = load('launch/src/main/ets/GraphicsProfileRegistry.ets');
const legacy = load('launch/src/main/ets/RendererBackendRegistry.ets');
const oldResolver = load('launch/src/main/ets/RendererBackendResolver.ets');
const { resolveGraphicsProfile, listGraphicsProfileAvailability } = load('launch/src/main/ets/GraphicsProfileResolver.ets');
const { resolveGraphicsPlan, serializeGraphicsPlan, VulkanPolicy } = load('launch/src/main/ets/GraphicsBackendPlan.ets');
const profiles = registry.GRAPHICS_PROFILES;
assert.deepEqual(parseGraphicsRegistry(fs.readFileSync(path.join(root, 'launch/src/main/ets/GraphicsProfileRegistry.ets'), 'utf8')), profiles);
assert.equal(legacy.RENDERER_BACKEND_DEFAULT_ID, registry.GRAPHICS_DEFAULT_PROFILE_ID);
assert.equal(legacy.RendererBackendLifecycle, registry.RendererBackendLifecycle);
assert.equal(legacy.RendererWindowAcquisition, registry.RendererWindowAcquisition);
assert.deepEqual(legacy.RENDERER_BACKENDS, profiles.filter((profile) => profile.api === 'OPENGL'));
for (const profile of legacy.RENDERER_BACKENDS) assert.equal(profile, registry.graphicsProfileById(profile.id));
assert.equal(legacy.rendererBackendById('minecraft-vulkan'), undefined);
assert.deepEqual(legacy.userSelectableRendererBackends().map(p => p.id), ['mobileglues']);
assert.deepEqual(profiles.map((profile) => profile.id), ['mobileglues', 'gl4es', 'mobilegl', 'zink', 'nativegl', 'minecraft-vulkan']);
assert.equal(registry.graphicsProfileById('mobilegl').lifecycle, 'optional');
assert.equal(registry.graphicsProfileById('mobilegl').userSelectable, true);
assert.equal(registry.graphicsProfileById('minecraft-vulkan').userSelectable, true);

const base = { realMcVersion: '1.20.1', lwjglVersion: 3, needsLwjgl322Slot: false, userPreferredBackendId: 'mobileglues' };
const defaultPlan = resolveGraphicsPlan(base);
assert.equal(defaultPlan.profile, 'mobileglues');
assert.equal(defaultPlan.gameApi, 'UNKNOWN');
assert.equal(defaultPlan.minecraftSelectedApi, 'UNKNOWN');
assert.equal(defaultPlan.actualProvider, 'UNKNOWN');
assert.equal(defaultPlan.actualVulkanUse, 'UNKNOWN');
assert.equal(defaultPlan.underlyingVulkan, 'UNKNOWN');
assert.equal(defaultPlan.candidateDetails.filter((candidate) => candidate.selected).length, 1);
assert.equal(serializeGraphicsPlan(defaultPlan), 'v=v2;profile=mobileglues;api=OPENGL;window=GLFW;route=mobileglues;transport=UNKNOWN;strict=0;policy=ALLOW;game=UNKNOWN;slot=LWJGL3;admission=LEGACY;requirement=legacy-gl');
assert.equal(resolveGraphicsPlan({ ...base, usesSdl3: true }).windowProvider, 'SDL3');
const { createDeviceGraphicsFacts } = load('launch/src/main/ets/DeviceGraphicsFacts.ets');
for (const usesSdl3 of [false, true]) {
  const desktop = resolveGraphicsPlan({ ...base, usesSdl3, graphicsProfilePreference: 'auto', platformFamily: 'DESKTOP', nativeGlAvailable: true });
  assert.equal(desktop.profile, 'nativegl');
  assert.equal(desktop.windowProvider, usesSdl3 ? 'SDL3' : 'GLFW');
  assert.equal(desktop.platformFamily, 'DESKTOP');
}
assert.equal(resolveGraphicsPlan({ ...base, requiresNativeGl: true }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...base, lwjglVersion: 2, platformFamily: 'DESKTOP' }).profile, 'gl4es');
assert.equal(resolveGraphicsPlan({ ...base, platformFamily: 'DESKTOP' }).profile, 'mobileglues');

// Forced fixed-function rules and the old userSelectable policy remain unchanged.
let legacyCases = 0;
for (const [realMcVersion, modern] of [['1.12.2', false], ['1.16.5', false], ['1.17', true], ['1.17-pre1', true], ['26.2', true], ['', false]]) {
  for (const lwjglVersion of [2, 3]) for (const needsLwjgl322Slot of [false, true]) {
    for (const userPreferredBackendId of ['', 'mobileglues', 'gl4es', 'zink', 'does-not-exist']) {
      const input = { realMcVersion, lwjglVersion, needsLwjgl322Slot, userPreferredBackendId, devOverrideBackendId: '' };
      const expected = lwjglVersion === 2 || (needsLwjgl322Slot && !modern) ? 'gl4es' : 'mobileglues';
      const canonical = resolveGraphicsPlan(input);
      assert.equal(canonical.profile, expected);
      assert.equal(canonical.decision.userPreferenceHonored, false);
      assert.deepEqual(oldResolver.resolveRendererBackend(input), resolveGraphicsProfile({ ...input, gameApi: 'OPENGL' }).decision);
      legacyCases++;
    }
  }
}
const emptyDev = resolveGraphicsPlan({ ...base, devOverrideBackendId: '', userPreferredBackendId: 'zink' });
assert.equal(emptyDev.requestedProfile, 'zink');
assert.equal(emptyDev.candidateDetails[0].id, 'zink');
assert.match(emptyDev.exclusions[0], /profile-retired/);
assert.equal(emptyDev.decision.reason, 'user-preference-unknown');
assert.equal(resolveGraphicsPlan({ ...base, userPreferredBackendId: 'gl4es' }).profile, 'mobileglues');

function evidence(id, windowProvider) {
  const profile = registry.graphicsProfileById(id);
  return { evidenceProfileId: id, requirementId: profile.requirementId, windowProvider,
    loader: 'YES', instance: 'YES', windowSurface: 'YES', physicalDevice: 'YES', apiVersion: '1.3',
    deviceExtensions: 'YES', featureBits: 'YES', queuePresentation: 'YES', shaderToolchain: 'YES',
    nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN', reasonCode: 'prelaunch-probe',
    observedProvider: 'UNKNOWN', observedUnderlyingVulkan: 'UNKNOWN' };
}

function scopedEvidence(id, requirementId, windowProvider) {
  const result = evidence(id, windowProvider);
  result.requirementId = requirementId;
  return result;
}
const mobilegl = { ...base, devOverrideBackendId: 'mobilegl', usesSdl3: true, capabilityResult: evidence('mobilegl', 'SDL3') };
const mobileglPlan = resolveGraphicsPlan(mobilegl);
assert.equal(mobileglPlan.profile, 'mobilegl');
assert.equal(mobileglPlan.requestedProfile, 'mobilegl');
assert.equal(mobileglPlan.underlyingVulkan, 'YES');
assert.deepEqual(mobileglPlan.candidates, ['mobilegl', 'mobileglues', 'nativegl']);
assert.equal(mobileglPlan.candidateDetails[1].admitted, true);
assert.equal(mobileglPlan.candidateDetails[1].selected, false);
assert.equal(resolveGraphicsPlan({ ...mobilegl, usesSdl3: false }).profile, 'mobileglues');
// GLFW 需要本 provider 的证据，不能借 SDL3 成功记录；匹配证据后直接选择 MobileGL。
const mobileglGlfw = resolveGraphicsPlan({ ...mobilegl, realMcVersion: '26.2', usesSdl3: false,
  capabilityResult: evidence('mobilegl', 'GLFW') });
assert.equal(mobileglGlfw.profile, 'mobilegl');
assert.equal(mobileglGlfw.windowProvider, 'GLFW');
assert.match(serializeGraphicsPlan(mobileglGlfw), /requirement=mobilegl-direct-vulkan-v1/);
assert.equal(resolveGraphicsPlan({ ...mobilegl, capabilityResult: evidence('minecraft-vulkan', 'SDL3') }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...mobilegl, lwjglVersion: 2 }).profile, 'gl4es');
assert.equal(resolveGraphicsPlan({ ...mobilegl, vulkanPolicy: VulkanPolicy.DISABLE_VULKAN }).profile, 'mobilegl');

const nativeVk = { ...base, realMcVersion: '26.2', gameApi: 'DUAL', usesSdl3: false,
  devOverrideBackendId: 'minecraft-vulkan', requirementId: 'minecraft-26.2-conservative-v1',
  capabilityResult: evidence('minecraft-vulkan', 'GLFW') };
const nativePlan = resolveGraphicsPlan(nativeVk);
assert.equal(nativePlan.profile, 'minecraft-vulkan');
assert.equal(nativePlan.gameApi, 'DUAL');
assert.equal(nativePlan.minecraftSelectedApi, 'UNKNOWN');
assert.equal(nativePlan.legacyGlBackendMarker, '');
assert.equal(nativePlan.admission, 'VALIDATION');
assert.equal(nativePlan.capabilityResult.lifecycleSmoke, 'NOT_RUN');
assert.match(serializeGraphicsPlan(nativePlan), /;game=DUAL;/);
for (const realMcVersion of ['26.2', '26.3', '27.0', '28.1']) {
  for (const usesSdl3 of [false, true]) {
    const windowProvider = usesSdl3 ? 'SDL3' : 'GLFW';
    const plan = resolveGraphicsPlan({ ...nativeVk, realMcVersion, usesSdl3, capabilityResult: evidence('minecraft-vulkan', windowProvider) });
    assert.equal(plan.windowProvider, windowProvider, 'provider must follow the manifest, never a guessed future version');
    assert.equal(plan.profile, 'minecraft-vulkan');
  }
}
assert.equal(resolveGraphicsPlan({ ...nativeVk, requiresNativeGl: true }).profile, 'minecraft-vulkan');
assert.equal(resolveGraphicsPlan({ ...nativeVk, gameApi: 'OPENGL' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...nativeVk, gameApi: 'UNKNOWN' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...nativeVk, requirementId: 'unknown' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...nativeVk, realMcVersion: '1.20.1' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...nativeVk, usesSdl3: true }).profile, 'mobileglues', 'probe identity must match selected provider');
assert.equal(resolveGraphicsPlan({ ...nativeVk, devOverrideBackendId: '', userPreferredBackendId: 'minecraft-vulkan' }).profile, 'minecraft-vulkan', 'canonical Vulkan profile may be selected when capability evidence is present');
assert.equal(resolveGraphicsPlan({ ...nativeVk, gameApi: 'VULKAN', devOverrideBackendId: '' }).profile, 'minecraft-vulkan', 'Vulkan-only manifest requires the native game API profile');

// 26.3-pre1 is an independently audited SDL3 identity. It shares the
// minecraft-vulkan profile, but must carry the exact requirement through the
// plan and capability scope; a 26.2 probe must never satisfy it.
const nativeVk263Requirement = 'minecraft-26.3-pre1-vulkan-conservative-v1';
const nativeVk263 = { ...base, realMcVersion: '26.3-pre-1', gameApi: 'DUAL', usesSdl3: true,
  devOverrideBackendId: 'minecraft-vulkan', requirementId: nativeVk263Requirement,
  capabilityResult: scopedEvidence('minecraft-vulkan', nativeVk263Requirement, 'SDL3') };
const nativePlan263 = resolveGraphicsPlan(nativeVk263);
assert.equal(nativePlan263.profile, 'minecraft-vulkan');
assert.equal(nativePlan263.windowProvider, 'SDL3');
assert.equal(nativePlan263.requirementId, nativeVk263Requirement);
assert.match(serializeGraphicsPlan(nativePlan263), /window=SDL3/);
assert.match(serializeGraphicsPlan(nativePlan263), /requirement=minecraft-26\.3-pre1-vulkan-conservative-v1/);
assert.equal(resolveGraphicsPlan({ ...nativeVk263, capabilityResult: evidence('minecraft-vulkan', 'SDL3') }).profile, 'mobileglues',
  '26.2 evidence must not satisfy the 26.3 requirement');
assert.equal(resolveGraphicsPlan({ ...nativeVk263, requirementId: 'minecraft-26.3-pre2-vulkan-conservative-v1' }).profile, 'mobileglues',
  'an unaudited SDL3 requirement must be rejected');
const nativeVk263Sdl = { ...nativeVk263, realMcVersion: '26.3-rc-2',
  requirementId: 'minecraft-26.3-sdl-vulkan-conservative-v1',
  capabilityResult: scopedEvidence('minecraft-vulkan', 'minecraft-26.3-sdl-vulkan-conservative-v1', 'SDL3') };
assert.equal(resolveGraphicsPlan(nativeVk263Sdl).profile, 'minecraft-vulkan',
  'audited 26.3 SDL Vulkan preference must select the native profile');

for (const field of ['loader', 'instance', 'windowSurface', 'physicalDevice', 'deviceExtensions', 'featureBits', 'queuePresentation', 'shaderToolchain', 'nativeArtifacts']) {
  for (const missing of ['NO', 'UNKNOWN', 'NOT_RUN']) {
    const capabilityResult = { ...nativeVk.capabilityResult, [field]: missing };
    const dual = resolveGraphicsPlan({ ...nativeVk, capabilityResult });
    assert.equal(dual.profile, 'mobileglues');
    assert.equal(dual.candidateDetails[0].admitted, false);
    assert.match(dual.exclusions[0], /capability-unverified/);
    const onlyVk = { ...nativeVk, gameApi: 'VULKAN', capabilityResult };
    const resolution = resolveGraphicsProfile(onlyVk);
    assert.equal(resolution.decision, undefined);
    assert.equal(resolution.selectedCandidate, undefined);
    assert.ok(resolution.candidates.every((candidate) => !candidate.selected));
    assert.throws(() => resolveGraphicsPlan(onlyVk), /No compatible graphics profile/);
  }
}
for (const field of ['evidenceProfileId', 'requirementId', 'windowProvider']) {
  assert.equal(resolveGraphicsPlan({ ...nativeVk, capabilityResult: { ...nativeVk.capabilityResult, [field]: undefined } }).profile, 'mobileglues');
}
assert.equal(resolveGraphicsPlan({ ...nativeVk, vulkanPolicy: VulkanPolicy.DISABLE_VULKAN }).profile, 'mobileglues');
assert.throws(() => resolveGraphicsPlan({ ...nativeVk, gameApi: 'VULKAN', vulkanPolicy: VulkanPolicy.DISABLE_VULKAN }), /DISABLE_VULKAN/);
assert.throws(() => resolveGraphicsPlan({ ...base, vulkanPolicy: VulkanPolicy.FORBID_VULKAN_TRANSPORT }), /FORBID_VULKAN_TRANSPORT/);
assert.throws(() => resolveGraphicsPlan({ ...mobilegl, vulkanPolicy: VulkanPolicy.FORBID_VULKAN_TRANSPORT }), /FORBID_VULKAN_TRANSPORT/);
const badOverride = resolveGraphicsPlan({ ...base, devOverrideBackendId: 'unknown-id' });
assert.equal(badOverride.profile, 'mobileglues');
assert.equal(badOverride.candidateDetails[0].reasonCode, 'profile-unknown');

// New peer preference aliases use the same admission gates as launch planning.
assert.equal(resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'MG' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'auto' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'auto', userPreferredBackendId: 'gl4es' }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'MobileGL', usesSdl3: true,
  capabilityResults: [evidence('mobilegl', 'SDL3')] }).profile, 'mobilegl');
assert.equal(resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'MobileGL', usesSdl3: true,
  capabilityResults: [evidence('mobilegl', 'SDL3')], availableProfileIds: ['mobileglues'] }).profile, 'mobileglues');
const rejectedCapabilityPlan = resolveGraphicsPlan({ ...base, graphicsProfilePreference: 'MobileGL', usesSdl3: true,
  capabilityResults: [{ ...evidence('mobilegl', 'SDL3'), nativeArtifacts: 'NO' }] });
assert.equal(rejectedCapabilityPlan.profile, 'mobileglues');
assert.equal(rejectedCapabilityPlan.capabilityResult.evidenceProfileId, undefined,
  'fallback plan must not copy rejected MobileGL evidence');

// UI availability is a flat report: every non-retired profile appears, with no
// implicit selection and with NOT_RUN window/shader checks tolerated.
const uiRows = listGraphicsProfileAvailability({ ...base, usesSdl3: true, availabilityOnly: true,
  capabilityResults: [{ ...evidence('mobilegl', 'SDL3'), windowSurface: 'NOT_RUN', shaderToolchain: 'NOT_RUN' }] });
assert.deepEqual(uiRows.map((row) => row.id), ['mobileglues', 'gl4es', 'mobilegl', 'nativegl', 'minecraft-vulkan']);
assert.equal(uiRows.every((row) => !row.selected), true);
assert.equal(uiRows.find((row) => row.id === 'mobilegl').admitted, true);
const uiNoRows = listGraphicsProfileAvailability({ ...base, usesSdl3: true, availabilityOnly: true,
  capabilityResults: [{ ...evidence('mobilegl', 'SDL3'), windowSurface: 'NO' }] });
assert.equal(uiNoRows.find((row) => row.id === 'mobilegl').admitted, false);
assert.equal(uiNoRows.find((row) => row.id === 'mobilegl').reasonCode, 'capability-unverified');
console.log('Graphics profiles, candidate admission, manifest providers, wire and ' + legacyCases + ' legacy combinations PASS');

const systemGl = { ...evidence('nativegl', 'GLFW'), apiVersion: '4.2',
  systemLibrary: 'YES', queryGl: 'YES', eglContext: 'YES', glVersion: 'YES', pixelReadback: 'YES',
  windowPresent: 'NOT_RUN', gameVersion: '1.20.1' };
for (const type of ['phone', 'tablet', '2in1', 'unknown']) for (const api of [20, 21, 22, 26]) {
  const input = { ...base, deviceFacts: createDeviceGraphicsFacts(type, api),
    graphicsProfilePreference: 'nativegl', capabilityResults: [systemGl],
    availableProfileIds: ['nativegl', 'mobileglues', 'gl4es'] };
  const row = listGraphicsProfileAvailability(input).find(row => row.id === 'nativegl');
  assert.equal(row.admitted, true, type + '/' + api);
  assert.equal(resolveGraphicsPlan(input).profile, 'nativegl');
  for (const field of ['systemLibrary', 'queryGl', 'eglContext', 'glVersion', 'pixelReadback']) {
    const rejected = { ...input, capabilityResults: [{ ...systemGl, [field]: 'NO' }] };
    assert.equal(listGraphicsProfileAvailability(rejected).find(row => row.id === 'nativegl').admitted, false);
    assert.equal(resolveGraphicsPlan(rejected).profile, 'mobileglues');
  }
  const absent = { ...input, availableProfileIds: ['mobileglues'] };
  assert.equal(listGraphicsProfileAvailability(absent).find(row => row.id === 'nativegl').reasonCode, 'artifact-missing');
  assert.equal(resolveGraphicsPlan({ ...input, capabilityResults: [{ ...systemGl, windowProvider: 'SDL3' }] }).profile, 'mobileglues');
  assert.equal(resolveGraphicsPlan({ ...input, capabilityResults: [{ ...systemGl, gameVersion: '1.21.1' }] }).profile, 'mobileglues');
}
const pc = { ...base, deviceFacts: createDeviceGraphicsFacts('2in1', 26), graphicsProfilePreference: 'auto',
  availableProfileIds: ['nativegl', 'mobileglues', 'gl4es'], capabilityResults: [systemGl] };
assert.equal(resolveGraphicsPlan(pc).profile, 'nativegl');
assert.equal(resolveGraphicsPlan({ ...pc, graphicsProfilePreference: 'mobileglues', graphicsProfileExplicit: false }).profile, 'nativegl');
assert.equal(resolveGraphicsPlan({ ...pc, graphicsProfilePreference: 'mobileglues', graphicsProfileExplicit: true }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...pc, capabilityResults: [] }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...pc, lwjglVersion: 2 }).profile, 'gl4es');
const entryOnly = { ...systemGl, evidenceScope: 'device-entry', eglContext: 'NOT_RUN', glVersion: 'NOT_RUN',
  pixelReadback: 'NOT_RUN', apiVersion: '' };
assert.equal(resolveGraphicsPlan({ ...pc, capabilityResults: [entryOnly] }).profile, 'mobileglues');
assert.equal(resolveGraphicsPlan({ ...pc, capabilityResults: [entryOnly], nativePreflightPending: true }).profile, 'nativegl');
assert.equal(listGraphicsProfileAvailability({ ...pc, capabilityResults: [entryOnly], availabilityOnly: true })
  .find(row => row.id === 'nativegl').admitted, true);
console.log('Unified device/product independence, capability scope, availability/launch parity and fallback PASS');
const { graphicsGameFacts } = load('launch/src/main/ets/GraphicsGameFacts.ets');
assert.equal(graphicsGameFacts(['org/lwjgl/lwjgl-vulkan/3.4.2/x.jar'], '26.3').gameApi, 'VULKAN');
assert.equal(graphicsGameFacts(['org/lwjgl/lwjgl-vulkan/3.4.2/x.jar', 'org/lwjgl/lwjgl-opengl/3.4.2/x.jar'], '26.3').gameApi, 'DUAL');
assert.equal(graphicsGameFacts(['org/lwjgl/lwjgl/lwjgl/2.9.4/lwjgl-2.9.4.jar'], '1.12.2').gameApi, 'OPENGL');
assert.equal(graphicsGameFacts([], '').gameApi, 'UNKNOWN');
assert.throws(() => resolveGraphicsPlan({ ...base, manifestProviderVerified: false }), /manifest-provider-conflict/);
assert.throws(() => resolveGraphicsPlan({ ...pc, deviceFacts: { ...pc.deviceFacts, glesContext: 'NO' }, capabilityResults: [] }), /No compatible/);

// Execute the production native adapter: an early failed entry query must never
// manufacture a context/readback result or borrow unrelated Vulkan evidence.
const loadAdapter = makePureEtsLoader({
  launch: { ...registry, ...load('launch/src/main/ets/GraphicsCapabilityContract.ets') },
  feature_core: {}, mods: {}, commons: {}, 'libentry.so': {},
  '@ohos.deviceInfo': {}, '@kit.CoreFileKit': {}, '@kit.ArkTS': {},
  '@kit.CryptoArchitectureKit': {}, feature_system: {},
});
const { nativeGlCapabilityResult } = loadAdapter('entry/src/main/ets/runtime/GraphicsCapabilityAdapter.ets');
const rejectedEntry = nativeGlCapabilityResult({
  systemLibrary: true, querySupported: false, ready: false, stage: 'query',
  contextCreated: false, pixelVerified: false, version: '', vendor: '', renderer: '',
}, 'GLFW', base.realMcVersion, true);
assert.equal(rejectedEntry.evidenceScope, 'device-entry');
assert.equal(rejectedEntry.queryGl, 'NO');
assert.equal(rejectedEntry.observedProvider, 'UNKNOWN');
for (const field of ['eglContext', 'glVersion', 'pixelReadback', 'deviceExtensions', 'featureBits']) {
  assert.equal(rejectedEntry[field], 'NOT_RUN', field);
}
assert.equal(listGraphicsProfileAvailability({ ...pc, capabilityResults: [rejectedEntry], availabilityOnly: true })
  .find(row => row.id === 'nativegl').admitted, false);
assert.equal(resolveGraphicsPlan({ ...pc, capabilityResults: [rejectedEntry], nativePreflightPending: true }).profile, 'mobileglues');
const verifiedContext = nativeGlCapabilityResult({
  systemLibrary: true, querySupported: true, ready: true, stage: 'complete',
  contextCreated: true, pixelVerified: true, version: '4.2', vendor: 'TEST', renderer: 'GL',
}, 'GLFW', base.realMcVersion, false);
assert.equal(verifiedContext.evidenceScope, 'isolated-context');
assert.equal(verifiedContext.pixelReadback, 'YES');
assert.equal(verifiedContext.deviceExtensions, 'NOT_RUN');
assert.equal(verifiedContext.featureBits, 'NOT_RUN');
assert.equal(resolveGraphicsPlan({ ...pc, capabilityResults: [verifiedContext] }).profile, 'nativegl');
console.log('Native GL adapter preserves entry-only failures, unknown provider and independent evidence PASS');

// 新默认只改变具备本组合证据的自动排序；显式 MG、固定管线和不兼容证据仍保持原语义。
for (const usesSdl3 of [false, true]) {
  const provider = usesSdl3 ? 'SDL3' : 'GLFW';
  for (const version of ['26.1.2', '26.2', '26.2-pre-1', '26.3', '27.1']) {
    const capability = { ...evidence('mobilegl', provider), gameVersion: version };
    const input = { ...base, realMcVersion: version, usesSdl3,
      graphicsProfilePreference: 'auto', graphicsProfileExplicit: false,
      deviceFacts: createDeviceGraphicsFacts('tablet', 26), gameApi: 'OPENGL',
      availableProfileIds: ['mobileglues', 'mobilegl', 'nativegl', 'gl4es'], capabilityResults: [capability] };
    const expected = version === '26.1.2' ? 'mobileglues' : 'mobilegl';
    assert.equal(resolveGraphicsPlan(input).profile, expected);
    assert.equal(resolveGraphicsPlan({ ...input, graphicsProfilePreference: 'mobileglues', graphicsProfileExplicit: false }).profile, expected);
    assert.equal(resolveGraphicsPlan({ ...input, graphicsProfilePreference: 'mobileglues', graphicsProfileExplicit: true }).profile, 'mobileglues');
    assert.equal(resolveGraphicsPlan({ ...input, availableProfileIds: ['mobileglues'] }).profile, 'mobileglues');
    assert.equal(resolveGraphicsPlan({ ...input, capabilityResults: [] }).profile, 'mobileglues');
    assert.equal(resolveGraphicsPlan({ ...input, capabilityResults: [{ ...capability, gameVersion: '1.20.1' }] }).profile, 'mobileglues');
    assert.equal(resolveGraphicsPlan({ ...input, lwjglVersion: 2 }).profile, 'gl4es');
    // MG 的底层 transport 仍为 UNKNOWN，严格禁 Vulkan 不能把未知假装为非 Vulkan。
    assert.throws(() => resolveGraphicsPlan({ ...input, vulkanPolicy: VulkanPolicy.FORBID_VULKAN_TRANSPORT }), /No compatible/);
    const pcInput = { ...input, deviceFacts: createDeviceGraphicsFacts('2in1', 26),
      capabilityResults: [capability, { ...systemGl, windowProvider: provider, gameVersion: version }] };
    assert.equal(resolveGraphicsPlan(pcInput).profile, 'nativegl');
    assert.equal(resolveGraphicsPlan({ ...pcInput, capabilityResults: [capability] }).profile, expected);
  }
}
assert.equal(registry.graphicsProfileById('mobilegl').contextApi, 'desktop-gl');
assert.equal(registry.graphicsProfileById('mobilegl').glfwSharedContext, 'probe-required');
assert.equal(registry.graphicsProfileById('mobilegl').sdlAuxiliaryWindow, 'supported');
console.log('Version-aware automatic recommendation, explicit preference and provider-scoped capabilities PASS');

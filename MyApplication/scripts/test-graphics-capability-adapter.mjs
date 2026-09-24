/** 执行真实 Adapter，故障注入证明一个可选 profile 的失败不会终止其他候选的准备。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const pure = makePureEtsLoader();
const constants = pure('commons/src/main/ets/common/Constants.ets');
const launch = {};
for (const module of ['GraphicsProfileRegistry', 'GraphicsCapabilityContract', 'DeviceGraphicsFacts', 'GraphicsGameFacts']) {
  Object.assign(launch, pure('launch/src/main/ets/' + module + '.ets'));
}
const { resolveGraphicsPlan } = pure('launch/src/main/ets/GraphicsBackendPlan.ets');
const versions = pure('commons/src/main/ets/utils/McVersionUtils.ets');
const preferenceLoader = makePureEtsLoader({ commons: versions });
const { resolveMinecraftGraphicsRequest, minecraftGraphicsBackendForApi, withMinecraftGraphicsBackend } =
  preferenceLoader('launch/src/main/ets/MinecraftGraphicsPreference.ets');
const manifest = { id: '26.3', inheritsFrom: '', clientSha1: '', libraries: [
  'org/lwjgl/lwjgl/3.4.2/lwjgl.jar', 'org/lwjgl/lwjgl-sdl/3.4.2/sdl.jar',
  'org/lwjgl/lwjgl-opengl/3.4.2/opengl.jar', 'org/lwjgl/lwjgl-vulkan/3.4.2/vulkan.jar',
] };
const artifactManifest = { schemaVersion: 1, abi: 'arm64-v8a',
  availableProfileIds: ['mobileglues', 'mobilegl', 'minecraft-vulkan'],
  profiles: ['mobileglues', 'mobilegl', 'minecraft-vulkan'].map(id => ({ id, artifactIds: ['fixture.so'] })) };
const context = { bundleCodeDir: '/bundle', resourceManager: {
  getRawFileContent: async () => new TextEncoder().encode(JSON.stringify(artifactManifest)),
} };

function goodEvidence(profileId, requirementId, provider) {
  return JSON.stringify({ evidenceProfileId: profileId, requirementId, windowProvider: provider,
    loader: 'YES', instance: 'YES', windowSurface: 'NOT_RUN', physicalDevice: 'YES', apiVersion: '1.3',
    deviceExtensions: 'YES', featureBits: 'YES', queuePresentation: 'NOT_RUN', shaderToolchain: 'NOT_RUN',
    nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN', reasonCode: 'fixture', observedProvider: 'UNKNOWN' });
}

/** 每组独立加载生产模块，避免模块缓存或上组假证据影响当前故障。 */
function adapter(probe, failOptionalManifest = false, options = {}) {
  let parses = 0;
  const calls = [];
  const manifestPaths = [];
  const warnings = [];
  const hashPaths = [];
  const realVersion = options.realVersion ?? '26.3';
  const native = {
    getNativeGlCapability: async () => ({ systemLibrary: false, querySupported: false,
      ready: false, stage: 'query', contextCreated: false, pixelVerified: false, version: '', vendor: '', renderer: '' }),
    getGraphicsCapabilityJson: (id, requirement, provider, availability) => {
      calls.push({ id, requirement, provider, availability });
      return probe(id, requirement, provider);
    },
  };
  const load = makePureEtsLoader({ launch,
    feature_core: { VersionParser: { parse: manifestPath => {
      manifestPaths.push(manifestPath);
      if (++parses === 2 && failOptionalManifest) throw new Error('optional manifest query failed');
      return manifest;
    }, detectVanillaVersion: () => realVersion }, computeFileSha1: async path => {
      hashPaths.push(path);
      if (options.hashFails) throw Error('unreadable client');
      return options.clientSha1 ?? '';
    } },
    mods: { resolveInstalledMcVersion: () => realVersion },
    commons: { ...constants, AppLogger: { warn: (...args) => warnings.push(args) } },
    'libentry.so': { default: native }, '@ohos.deviceInfo': { default: { deviceType: 'tablet', sdkApiVersion: 24 } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => true } },
    // 本用例的设备边界没有driverIdentity，因此生产历史作用域明确跳过；真实身份/字节链另测。
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} }, feature_system: { PreferenceManager: class {} },
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) } } },
  });
  return { api: load('entry/src/main/ets/runtime/GraphicsCapabilityAdapter.ets'), calls, manifestPaths, warnings, hashPaths };
}

// 实例 ID 确实进入生产 Adapter 的 manifest 路径；返回的真实版本事实再进入请求/计划/参数链。
// 这不是把三个实例名称仅作为断言标签，错误地从文件夹名判断版本将无法通过此测试。
for (const instanceId of ['26.3', 'MyVulkanInstance', '中文整合包']) {
  const fixture = adapter(goodEvidence);
  const facts = await fixture.api.prepareGraphicsProfileInput(context, '/mc', instanceId, 'auto', false, true);
  assert.equal(fixture.manifestPaths[0], '/mc/versions/' + instanceId + '/' + instanceId + '.json');
  const preference = resolveMinecraftGraphicsRequest(facts, { launcherProfile: 'auto', launcherExplicit: true,
    developerOverride: '', optionsText: 'preferredGraphicsBackend:"vulkan"\n' });
  assert.equal(facts.realMcVersion, '26.3');
  assert.equal(preference.requestedProfile, 'minecraft-vulkan');
  const plan = resolveGraphicsPlan({ ...facts, graphicsProfilePreference: preference.requestedProfile,
    graphicsProfileExplicit: preference.preferenceExplicit, gameApi: preference.requireVulkan ? 'VULKAN' : facts.gameApi });
  assert.equal(plan.profile, 'minecraft-vulkan');
  assert.deepEqual(withMinecraftGraphicsBackend([], minecraftGraphicsBackendForApi(facts.realMcVersion, plan.apiFamily)),
    ['--graphicsBackend', 'VULKAN']);
  assert.equal(fixture.calls.length, 2, '整条启动准备链只执行一轮候选探针');
}

for (const failure of ['throw', 'invalid-json', 'null']) {
  const fixture = adapter((id, requirement, provider) => {
    if (id !== 'mobilegl') return goodEvidence(id, requirement, provider);
    if (failure === 'throw') throw new Error('native probe unavailable');
    return failure === 'null' ? 'null' : '{invalid-json';
  });
  const input = await fixture.api.prepareGraphicsProfileInput(context, '/mc', '中文整合包', 'mobilegl', false, true);
  assert.equal(input.realMcVersion, '26.3');
  assert.deepEqual(fixture.calls.map(call => call.id), ['mobilegl', 'minecraft-vulkan'], '每个候选只探测一次');
  assert.ok(fixture.calls.every(call => call.availability));
  const failed = input.capabilityResults.find(result => result.evidenceProfileId === 'mobilegl');
  assert.equal(failed.loader, 'UNKNOWN');
  assert.equal(failed.reasonCode, 'native-probe-failed');
  assert.equal(failed.requirementId, 'mobilegl-direct-vulkan-v1');
  assert.equal(failed.windowProvider, 'SDL3');
  assert.equal(failed.gameVersion, '26.3');
  assert.equal(failed.lifecycleSmoke, 'NOT_RUN');
  assert.equal(input.capabilityResults.find(result => result.evidenceProfileId === 'minecraft-vulkan').loader, 'YES');
  assert.throws(() => resolveGraphicsPlan(input), /selection-locked/, '明确选择 MobileGL 的实例不能静默换后端');
  assert.equal(resolveGraphicsPlan({ ...input, graphicsProfilePreference: 'auto', graphicsProfileExplicit: false }).profile,
    'mobileglues', '自动策略仍可在可选后端异常时使用已准入的默认候选');
  assert.equal(fixture.warnings.length, 1);
}

const both = adapter(() => { throw new Error('optional probes unavailable'); });
const input = await both.api.prepareGraphicsProfileInput(context, '/mc', 'Renamed', 'mobileglues', false, true);
assert.equal(resolveGraphicsPlan(input).profile, 'mobileglues');
assert.throws(() => resolveGraphicsPlan({ ...input, graphicsProfilePreference: 'minecraft-vulkan', gameApi: 'VULKAN' }),
  /No compatible graphics profile/, '容错不能把严格 Vulkan 请求变成 GL');

const preparation = adapter(goodEvidence, true);
const prepared = await preparation.api.prepareGraphicsProfileInput(context, '/mc', 'Renamed', 'mobileglues', false, true);
assert.equal(prepared.capabilityResults.some(result => result.evidenceProfileId === 'mobilegl'), false);
assert.equal(prepared.capabilityResults.find(result => result.evidenceProfileId === 'minecraft-vulkan').loader, 'YES');
assert.equal(resolveGraphicsPlan(prepared).profile, 'mobileglues');
assert.equal(preparation.warnings.length, 1);
console.log('Graphics capability adapter behavior PASS: candidate-scoped NAPI/JSON/preparation failures and strict Vulkan admission');

// 实际清单仅改窗口模块，执行完整 Adapter→resolver；新 profile 不依赖 SDL 名称。
manifest.libraries = manifest.libraries.map(name => name.replace('lwjgl-sdl/', 'lwjgl-glfw/'));
const glfwFixture = adapter(goodEvidence);
const glfwFacts = await glfwFixture.api.prepareGraphicsProfileInput(context, '/mc', 'RenamedGLFW', 'mobilegl', false, true);
assert.equal(glfwFacts.usesSdl3, false);
assert.equal(resolveGraphicsPlan(glfwFacts).profile, 'mobilegl');
assert.equal(glfwFacts.capabilityResults.find(item => item.evidenceProfileId === 'mobilegl').windowProvider, 'GLFW');
console.log('MobileGL GLFW manifest, provider-scoped capability and explicit selection PASS');

// 用实际读取路径和双摘要边界证明 26.4 的放宽只绑定被审计的客户端。重命名实例及
// 合并后的加载器清单保留原版 JAR 时可准入，不能凭文件夹名或单独篡改 manifest 放行。
const sha264 = '99dea8ec5ae3c5adc7d246061a90960e7d8441c3';
manifest.libraries = manifest.libraries.map(name => name.replace('lwjgl-glfw/', 'lwjgl-sdl/'));
manifest.clientSha1 = sha264;
for (const instanceId of ['26.4-snapshot-1', 'Renamed264', 'fabric-loader-26.4-snapshot-1']) {
  manifest.id = instanceId;
  const fixture = adapter(goodEvidence, false, { realVersion: '26.4-snapshot-1', clientSha1: sha264 });
  const input = await fixture.api.prepareGraphicsProfileInput(context, '/mc', instanceId, 'auto', false, true);
  assert.equal(input.requirementId, 'minecraft-26.4-snapshot1-sdl-vulkan-v1');
  assert.deepEqual(fixture.hashPaths, ['/mc/versions/' + instanceId + '/' + instanceId + '.jar']);
  const plan = resolveGraphicsPlan(input);
  assert.equal(plan.profile, 'minecraft-vulkan');
  assert.equal(plan.gameApi, 'DUAL');
}
for (const variant of [
  { clientSha1: '0'.repeat(40) }, { hashFails: true }, { manifestSha1: '0'.repeat(40) },
  { realVersion: '26.4-snapshot-2' }, { realVersion: '26.4' }, { realVersion: '26.5-snapshot-1' },
  { glfw: true }, { conflict: true }, { inheritsFrom: '26.4-snapshot-1' },
]) {
  const saved = { ...manifest, libraries: manifest.libraries.slice() };
  try {
    manifest.clientSha1 = variant.manifestSha1 ?? sha264;
    manifest.inheritsFrom = variant.inheritsFrom ?? '';
    if (variant.glfw) manifest.libraries = manifest.libraries.map(name => name.replace('lwjgl-sdl/', 'lwjgl-glfw/'));
    if (variant.conflict) manifest.libraries.push('org/lwjgl/lwjgl-glfw/3.4.3/glfw.jar');
    const fixture = adapter(goodEvidence, false, { realVersion: '26.4-snapshot-1', clientSha1: sha264, ...variant });
    const input = await fixture.api.prepareGraphicsProfileInput(context, '/mc', 'Renamed264', 'auto', false, true);
    assert.equal(input.capabilityResults.some(item => item.evidenceProfileId === 'minecraft-vulkan'), false, JSON.stringify(variant));
    assert.equal(fixture.calls.some(call => call.id === 'minecraft-vulkan'), false);
    if (!variant.conflict) assert.equal(resolveGraphicsPlan(input).apiFamily, 'OPENGL');
  } finally { Object.assign(manifest, saved); }
}
console.log('Minecraft 26.4 adapter PASS: exact client audit, renamed/modded instances and unaudited version rejection');

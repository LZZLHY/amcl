/**
 * 执行生产 ArkTS 的偏好/计划/参数函数，覆盖曾被源码 includes 断言漏掉的接线语义。
 * 不把“包含一段 native 源码字符串”当成运行验证；native 准入由对应宿主测试负责。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const versions = makePureEtsLoader()('commons/src/main/ets/utils/McVersionUtils.ets');
const load = makePureEtsLoader({ commons: versions });
const registry = load('launch/src/main/ets/GraphicsProfileRegistry.ets');
const { resolveGraphicsPlan } = load('launch/src/main/ets/GraphicsBackendPlan.ets');
const { resolveMinecraftGraphicsRequest, minecraftGraphicsBackendForApi,
  minecraftGraphicsBackendForProfile, withMinecraftGraphicsBackend } =
  load('launch/src/main/ets/MinecraftGraphicsPreference.ets');

const options = 'renderDistance:12\r\npreferredGraphicsBackend:"vulkan"\r\nstartedCleanly:false\r\n';
const evidence = {
  evidenceProfileId: 'minecraft-vulkan', requirementId: 'minecraft-26.3-sdl-vulkan-conservative-v1',
  windowProvider: 'SDL3', gameVersion: '26.3', loader: 'YES', instance: 'YES', windowSurface: 'YES',
  physicalDevice: 'YES', apiVersion: '1.3', deviceExtensions: 'YES', featureBits: 'YES',
  queuePresentation: 'YES', shaderToolchain: 'YES', nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN',
  reasonCode: 'fixture', observedProvider: 'UNKNOWN', observedUnderlyingVulkan: 'UNKNOWN',
};
const game = {
  realMcVersion: '26.3', lwjglVersion: 3, needsLwjgl322Slot: false,
  usesSdl3: true, gameApi: 'DUAL', userPreferredBackendId: 'auto',
  requirementId: evidence.requirementId, capabilityResults: [evidence],
  availableProfileIds: ['mobileglues', 'minecraft-vulkan'],
};

/** 按产品层的输入边界运行真实请求函数，再把其返回的显式约束交给生产 resolver。 */
function launch(preference, facts = game) {
  const request = resolveMinecraftGraphicsRequest(facts, preference);
  const plan = resolveGraphicsPlan({ ...facts, userPreferredBackendId: request.requestedProfile,
    graphicsProfilePreference: request.requestedProfile, graphicsProfileExplicit: request.preferenceExplicit,
    devOverrideBackendId: preference.developerOverride,
    vulkanPolicy: request.vulkanPolicy,
    gameApi: request.requireVulkan ? 'VULKAN' : facts.gameApi });
  return { request, plan, args: withMinecraftGraphicsBackend(['--username', 'Player'],
    minecraftGraphicsBackendForApi(facts.realMcVersion, plan.apiFamily)) };
}

// auto 与历史未显式选择的 MobileGlues 默认值都跟随游戏；重命名完整链另在 Adapter 测试执行。
for (const [launcherProfile, launcherExplicit] of [['auto', true], ['mobileglues', false]]) {
  const result = launch({ launcherProfile, launcherExplicit, developerOverride: '', optionsText: options });
  assert.equal(result.request.requestedProfile, 'minecraft-vulkan');
  assert.equal(result.plan.apiFamily, 'VULKAN');
  assert.deepEqual(result.args, ['--username', 'Player', '--graphicsBackend', 'VULKAN']);
}

// 显式启动器选择压过游戏内选项；auto 则继续跟随，开发覆盖拥有最高请求优先级。
const explicitGl = launch({ launcherProfile: 'mobileglues', launcherExplicit: true,
  developerOverride: '', optionsText: options });
assert.equal(explicitGl.plan.profile, 'mobileglues');
assert.equal(explicitGl.request.requireVulkan, false);
assert.equal(explicitGl.request.preferenceExplicit, true, '具体 profile 仍锁定用户选择');
assert.deepEqual(explicitGl.args.slice(-2), ['--graphicsBackend', 'OPENGL']);
const dev = resolveMinecraftGraphicsRequest(game, { launcherProfile: 'minecraft-vulkan',
  launcherExplicit: true, developerOverride: 'mobilegl', optionsText: options });
assert.equal(dev.requestedProfile, 'mobilegl');
assert.equal(dev.requireVulkan, false);

// 原有严格 Vulkan 政策必须保留；证据缺失不能返回触发 native options guard 的错误 GL 计划。
assert.throws(() => launch({ launcherProfile: 'auto', launcherExplicit: true,
  developerOverride: '', optionsText: options }, { ...game, capabilityResults: [] }), /No compatible graphics profile/);
assert.throws(() => launch({ launcherProfile: 'minecraft-vulkan', launcherExplicit: true,
  developerOverride: '', optionsText: '' }, { ...game, capabilityResults: [] }), /No compatible graphics profile/);

for (const optionsText of ['', 'preferredGraphicsBackend:"opengl"', '# preferredGraphicsBackend:"vulkan"']) {
  const request = resolveMinecraftGraphicsRequest(game,
    { launcherProfile: 'auto', launcherExplicit: true, developerOverride: '', optionsText });
  assert.equal(request.requestedProfile, 'auto');
  assert.equal(request.preferenceExplicit, false, '保存过的 auto 仍允许自动候选恢复，不等于锁定具体 profile');
}
const old = resolveMinecraftGraphicsRequest({ ...game, realMcVersion: '1.21.1' },
  { launcherProfile: 'auto', launcherExplicit: true, developerOverride: '', optionsText: options });
assert.equal(old.requestedProfile, 'auto');
assert.equal(minecraftGraphicsBackendForApi('1.21.1', 'OPENGL'), '');
assert.equal(minecraftGraphicsBackendForApi('26.3', 'DUAL'), '');
assert.equal(minecraftGraphicsBackendForProfile('26.3', 'auto'), '');
assert.equal(minecraftGraphicsBackendForProfile('26.3', 'unknown-profile'), '');
assert.equal(minecraftGraphicsBackendForProfile('26.3', 'minecraft-vulkan'), 'VULKAN');

// API 名称取自注册表：临时添加一个新 OpenGL peer 后，不修改页面/Builder 也能正确生成参数。
const peer = { ...registry.graphicsProfileById('mobileglues'), id: 'test-new-opengl-peer' };
registry.GRAPHICS_PROFILES.push(peer);
try {
  assert.equal(minecraftGraphicsBackendForProfile('26.3', peer.id), 'OPENGL');
} finally { registry.GRAPHICS_PROFILES.pop(); }

const args = ['--graphicsBackend', 'OPENGL', '--width', '1280', '--graphicsBackend=OPENGL', '--height', '720'];
assert.deepEqual(withMinecraftGraphicsBackend(args, 'VULKAN'),
  ['--width', '1280', '--height', '720', '--graphicsBackend', 'VULKAN']);
assert.equal(args[1], 'OPENGL', '参数处理不能修改上游清单数组');
assert.deepEqual(withMinecraftGraphicsBackend(args, ''), args);
assert.deepEqual(withMinecraftGraphicsBackend(['--graphicsBackend'], 'OPENGL'), ['--graphicsBackend', 'OPENGL']);
console.log('Minecraft graphics preference behavior PASS: real version, auto/explicit, strict Vulkan, canonical API and unique arguments');

// 26.4 的默认 API 是一个可回退候选；运行真实请求→resolver→参数链，不能把它变成
// requireVulkan。覆盖手机/电脑排序、OpenGL 历史、明确偏好和未知能力，防止只测正例。
const requirement264 = 'minecraft-26.4-snapshot1-sdl-vulkan-v1';
const game264 = { ...game, realMcVersion: '26.4-snapshot-1', requirementId: requirement264,
  availableProfileIds: ['mobileglues', 'mobilegl', 'nativegl', 'minecraft-vulkan'],
  capabilityResults: [{ ...evidence, gameVersion: '26.4-snapshot-1', requirementId: requirement264 },
    { ...evidence, evidenceProfileId: 'mobilegl', gameVersion: '26.4-snapshot-1', requirementId: 'mobilegl-direct-vulkan-v1' }]
};
const auto264 = { launcherProfile: 'auto', launcherExplicit: true, developerOverride: '', optionsText: '' };
for (const optionsText of ['', 'preferredGraphicsBackend:"default"', '# preferredGraphicsBackend:"opengl"']) {
  for (const platformFamily of ['MOBILE', 'DESKTOP']) {
    const scope = 'b'.repeat(64);
    const { request, plan, args } = launch({ ...auto264, optionsText }, { ...game264, platformFamily,
      nativeGlAvailable: true, graphicsHistoryScope: scope,
      graphicsHistory: [{ profile: 'mobilegl', scopeHash: scope, priority: 1, reason: 'verified-presentation' }] });
    assert.equal(request.requireVulkan, false);
    assert.equal(request.preferenceExplicit, false);
    assert.equal(plan.gameApi, 'DUAL');
    assert.equal(plan.profile, 'minecraft-vulkan');
    assert.equal(plan.candidateDetails.find(c => c.selected).source, 'GAME_DEFAULT');
    assert.deepEqual(args.slice(-2), ['--graphicsBackend', 'VULKAN']);
  }
}
for (const change of [{ deviceExtensions: 'NO' }, { featureBits: 'NO' }, { loader: 'UNKNOWN' },
  { requirementId: evidence.requirementId }, { gameVersion: '26.3' }, { windowProvider: 'GLFW' },
  { windowSurface: 'NO' }, { nativeArtifacts: 'NO' }, { shaderToolchain: 'NO' }]) {
  const facts = { ...game264, capabilityResults: [{ ...game264.capabilityResults[0], ...change }, game264.capabilityResults[1]] };
  const { plan, args } = launch(auto264, facts);
  assert.equal(plan.profile, 'mobilegl', JSON.stringify(change));
  assert.deepEqual(args.slice(-2), ['--graphicsBackend', 'OPENGL']);
  assert.equal(launch(auto264, { ...facts, platformFamily: 'DESKTOP', nativeGlAvailable: true }).plan.profile, 'nativegl');
}
assert.equal(launch(auto264, { ...game264, capabilityResults: [] }).plan.profile, 'mobileglues');
assert.equal(launch(auto264, { ...game264, availableProfileIds: ['mobilegl', 'mobileglues'] }).plan.profile, 'mobilegl');
assert.equal(launch({ ...auto264, optionsText: 'preferredGraphicsBackend:"opengl"' }, game264).plan.profile, 'mobilegl');
assert.equal(launch({ ...auto264, launcherProfile: 'mobileglues', launcherExplicit: false }, game264).plan.profile, 'minecraft-vulkan');
assert.equal(launch({ ...auto264, launcherProfile: 'mobileglues' }, game264).plan.profile, 'mobileglues');
assert.equal(launch({ ...auto264, developerOverride: 'mobilegl' }, game264).plan.profile, 'mobilegl');
assert.equal(launch({ ...auto264, launcherProfile: 'minecraft-vulkan', optionsText: 'preferredGraphicsBackend:"opengl"' }, game264).plan.profile, 'minecraft-vulkan');
assert.throws(() => launch({ ...auto264, optionsText: options }, { ...game264, capabilityResults: [] }), /No compatible graphics profile/);
// 禁用游戏 Vulkan API 仍允许 DirectVulkan 翻译层；禁止所有 Vulkan transport 继续更严格。
assert.equal(launch(auto264, { ...game264, vulkanPolicy: 'DISABLE_VULKAN' }).plan.profile, 'mobilegl');
assert.throws(() => launch(auto264, { ...game264, vulkanPolicy: 'FORBID_VULKAN_TRANSPORT' }), /No compatible graphics profile/);
// 相同完整能力不会让旧版开始自动 Vulkan；旧显式 Vulkan 行为由上方原有断言覆盖。
assert.equal(launch(auto264, game).plan.profile, 'mobileglues');
const game262 = { ...game, realMcVersion: '26.2', usesSdl3: false, requirementId: 'minecraft-26.2-conservative-v1',
  capabilityResults: [{ ...evidence, gameVersion: '26.2', windowProvider: 'GLFW', requirementId: 'minecraft-26.2-conservative-v1' }] };
assert.equal(launch(auto264, game262).plan.profile, 'mobileglues');
console.log('Minecraft 26.4 defaults PASS: Vulkan admission, GL fallback, explicit preference, history and old generations');

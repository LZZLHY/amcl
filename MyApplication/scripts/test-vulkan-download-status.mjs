/**
 * 运行真实下载页报告、注入桥方法和状态刷新方法。只替换设备查询边界，设备扩展/特性
 * 判断仍由生产 native 要求表负责；此测试证明结果解释、版本隔离和 UI 接线，不冒充 GPU 验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';

const pure = makePureEtsLoader();
const constants = pure('commons/src/main/ets/common/Constants.ets');
const versions = pure('commons/src/main/ets/utils/McVersionUtils.ets');
const { listGraphicsProfileAvailability } = pure('launch/src/main/ets/GraphicsProfileResolver.ets');
const reference = constants.VULKAN_264_REFERENCE_VERSION;
const requirement = constants.VULKAN_264_REQUIREMENT_ID;

/** 从生产文件提取简单桥/刷新方法，锚点缺失即失败，避免测试复制旧实现后继续假绿。 */
function methodClass(file, signature, dependencyNames, dependencies) {
  const source = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  const start = source.indexOf(signature);
  const end = source.indexOf('\n  }', start) + 4;
  assert.ok(start >= 0 && end > start, file + ': production method anchor missing');
  const code = 'class Fixture {\n' + source.slice(start, end) + '\n}\nreturn Fixture;';
  const js = compiler.transpileModule(code, { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  return new Function(...dependencyNames, js)(...dependencies);
}

const good = {
  evidenceProfileId: 'minecraft-vulkan', requirementId: requirement, windowProvider: 'SDL3',
  loader: 'YES', instance: 'YES', physicalDevice: 'YES', apiVersion: '1.3.309',
  deviceExtensions: 'YES', featureBits: 'YES', windowSurface: 'NOT_RUN', queuePresentation: 'NOT_RUN',
  shaderToolchain: 'NOT_RUN', nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN', observedProvider: 'Maleoon 920',
  reasonCode: 'sdl_surface_contract_not_queried',
};

/** 各案例使用独立模块缓存；实际 bridge 固定 native 的 profile 与 availabilityOnly。 */
function fixture(deviceQuery = () => JSON.stringify(good), legacyAvailable = false) {
  const calls = [];
  const native = { getGraphicsCapabilityJson: (...args) => { calls.push(args); return deviceQuery(); } };
  const Bridge = methodClass('entry/src/main/ets/runtime/ProcessRuntime.ets',
    '  getMinecraftVulkanDeviceCapabilityJson(', ['testNapi'], [native]);
  const bridge = new Bridge();
  let legacyCalls = 0;
  bridge.getVulkanCapabilityJson = () => {
    legacyCalls++;
    return JSON.stringify({ available: legacyAvailable, reason: 'missing push descriptor',
      deviceName: 'Maleoon 920', deviceApiVersion: '1.3.309', featuresQueried: true });
  };
  const load = makePureEtsLoader({
    commons: { ...constants, ...versions, LogTags: { SVC_VULKAN_CAP: 'VulkanCapability' } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  });
  load('feature_system/src/main/ets/SystemNativeBridge.ets').setSystemNativeBridge(bridge);
  const api = load('feature_system/src/main/ets/VulkanCapability.ets');
  return { ...api, calls, legacyCalls: () => legacyCalls };
}

// 26.4 及后续始终展示报告和切换提醒；后续未审计版本明确使用参考基线。
for (const version of [reference, '26.4-snapshot-2', '26.4', '26.4.1', '26.5', '27.1']) {
  const f = fixture();
  const hint = f.getVulkanStatusForVersion(version);
  assert.equal(hint.status, 'feasible', version);
  assert.equal(hint.available, true);
  assert.match(hint.message, /Maleoon 920/);
  assert.match(hint.message, /安装后仍会核对该版本/);
  assert.match(hint.defaultNotice, /26\.4.*默认优先使用 Vulkan/);
  assert.match(hint.defaultNotice, /需要更换，请自行.*设置 → 图形后端/);
  assert.match(hint.defaultNotice, /Vulkan 不可用时.*OpenGL/);
  assert.equal(hint.statusLabel, version === reference ? '检查通过' : '参考通过');
  assert.equal(hint.message.includes('设备参考检查'), version !== reference);
  assert.deepEqual(f.calls, [['minecraft-vulkan', requirement, 'SDL3', true]], '只能设备查询，不能占用窗口');
  assert.equal(f.legacyCalls(), 0, '不得复用按26.2判断的全局 available');
}

// 新版报告与现有 resolver 的 availabilityOnly 语义逐字段对照，不重列 GPU 特性要求。
const requiredFields = ['loader', 'instance', 'physicalDevice', 'deviceExtensions', 'featureBits', 'nativeArtifacts'];
const laterFields = ['windowSurface', 'queuePresentation', 'shaderToolchain'];
for (const field of [...requiredFields, ...laterFields]) {
  for (const state of ['YES', 'NO', 'UNKNOWN', 'NOT_RUN']) {
    const cap = { ...good, [field]: state };
    const f = fixture(() => JSON.stringify(cap));
    const hint = f.getVulkanStatusForVersion(reference);
    const candidate = listGraphicsProfileAvailability({
      realMcVersion: reference, lwjglVersion: 3, needsLwjgl322Slot: false,
      userPreferredBackendId: 'auto', usesSdl3: true, gameApi: 'DUAL', requirementId: requirement,
      availabilityOnly: true, availableProfileIds: ['minecraft-vulkan'],
      capabilityResults: [{ ...cap, gameVersion: reference, evidenceScope: 'device-entry' }],
    }).find(c => c.id === 'minecraft-vulkan');
    assert.equal(hint.available, candidate.admitted, field + '=' + state);
    assert.equal(hint.status, state === 'NO' ? 'unavailable'
      : requiredFields.includes(field) && state !== 'YES' ? 'unknown' : 'feasible');
    assert.ok(hint.defaultNotice.length > 0, '失败/未确认状态也必须保留默认 Vulkan 提醒');
  }
}

for (const change of [{ evidenceProfileId: 'mobilegl' }, { requirementId: 'minecraft-26.2-conservative-v1' },
  { windowProvider: 'GLFW' }, { featureBits: undefined }, { loader: true }, { apiVersion: '' }]) {
  const hint = fixture(() => JSON.stringify({ ...good, ...change })).getVulkanStatusForVersion(reference);
  assert.equal(hint.available, false, JSON.stringify(change));
  assert.equal(hint.status, 'unknown');
  assert.equal(hint.statusLabel, '尚未确认');
}
for (const json of ['null', '{bad', '[]', 'true']) {
  assert.equal(fixture(() => json).getVulkanStatusForVersion(reference).status, 'unknown');
}
let attempt = 0;
const recover = fixture(() => { if (++attempt === 1) throw Error('temporary probe failure'); return JSON.stringify(good); });
assert.equal(recover.getVulkanStatusForVersion(reference).status, 'unknown');
assert.equal(recover.getVulkanStatusForVersion(reference).status, 'feasible', '暂时失败不能缓存为设备不支持');

// 旧版保守缓存、版本边界保持；新报告不会让缺 push descriptor 的旧版设备错误变成可用。
const f = fixture();
assert.equal(f.getVulkanStatusForVersion('1.21.11'), null);
assert.equal(f.calls.length, 0);
assert.equal(f.getVulkanStatusForVersion('26.2').available, false);
assert.equal(f.getVulkanStatusForVersion(reference).available, true);
const old = f.getVulkanStatusForVersion('26.3');
assert.equal(old.available, false);
assert.equal(old.defaultNotice, '');
assert.equal(old.statusLabel, '不可用');
assert.equal(f.legacyCalls(), 1);
assert.equal(fixture(undefined, true).getVulkanStatusForVersion('26.3').available, true);

// 实际页面刷新函数按当前 prop 取报告；版本变动不能残留上一版的绿色结果。
const Panel = methodClass('entry/src/main/ets/components/VersionConfigPanel.ets',
  '  private refreshVulkanStatus(', ['getVulkanStatusForVersion'], [f.getVulkanStatusForVersion]);
const panel = new Panel();
panel.gameVersion = reference; panel.refreshVulkanStatus();
assert.equal(panel.vulkanHint.available, true);
panel.gameVersion = '26.3'; panel.refreshVulkanStatus();
assert.equal(panel.vulkanHint.available, false);
panel.gameVersion = '1.21.11'; panel.refreshVulkanStatus();
assert.equal(panel.vulkanHint, null);
console.log('Vulkan download report PASS: actual bridge/report/page refresh, existing resolver parity, future reference and old-version isolation');

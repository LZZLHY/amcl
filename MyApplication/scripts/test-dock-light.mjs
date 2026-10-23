/**
 * 底部栏光感宿主回归：执行真实 ETS 策略、修饰器及偏好保存方法。
 * 这里只模拟平台能力、Preferences 和属性接收器；真实视觉与旧机运行仍由 SDK／设备验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const outputIndex = process.argv.indexOf('--output');
if (outputIndex < 0) throw new Error('请通过 --output 指定仓库外的证据目录');
const output = assertExternalOutputPath(process.argv[outputIndex + 1]);
fs.mkdirSync(output, { recursive: true });
const startedAt = new Date().toISOString();
const groups = [];
const pass = name => { groups.push(name); console.log('PASS ' + name); };
const pure = makePureEtsLoader()('commons/src/main/ets/common/DockLight.ets');
const { DockLightMode: M, normalizeDockLightMode: normalize, resolveDockLightMode: resolve } = pure;

// 损坏值与未来值不能被误解为一个可直接使用的 SDK 档位。
for (const value of ['', 'future', false, 0, null]) assert.equal(normalize(value), M.AUTO);
for (const mode of Object.values(M)) assert.equal(normalize(mode), mode);
for (const mode of [M.EXQUISITE, M.GENTLE]) {
  assert.equal(resolve(mode, true, true), mode);
  assert.equal(resolve(mode, true, false), M.SMOOTH);
  assert.equal(resolve(mode, false, false), M.AUTO);
}
assert.equal(resolve(M.OFF, false, false), M.OFF);
assert.equal(resolve(M.AUTO, true, false), M.AUTO);
pass('偏好归一、能力降级与旧系统关闭');

// 同一属性接收器依次关闭／开启／换主题，专门捕获残留背景和旧模糊。
globalThis.Color = { Transparent: 'transparent' };
globalThis.BlurStyle = { NONE: 0, COMPONENT_THICK: 5 };
globalThis.TabsCacheMode = { CACHE_BOTH_SIDE: 1 };
function materialFixture(available, immersive = true, failure = false) {
  let queries = 0;
  const hdsMaterial = {
    getSystemMaterialTypes() { queries++; if (failure) throw new Error('capability query failed'); return immersive ? [101] : [100]; },
    get MaterialType() { assert.ok(available, '旧系统访问了 HDS 枚举'); return { NONE: 0, ADAPTIVE: 100, IMMERSIVE: 101 }; },
    get MaterialLevel() { assert.ok(available, '旧系统访问了 HDS 档位'); return { ADAPTIVE: 10, EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 }; }
  };
  const load = makePureEtsLoader({ commons: pure,
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: version => { assert.equal(version, '6.1.0'); return available; } } },
    '@kit.UIDesignKit': { hdsMaterial } });
  const capability = load('entry/src/main/ets/components/DockLightMaterial.ets');
  return { ...capability, Style: load('entry/src/main/ets/components/LauncherTabsStyle.ets').LauncherTabsStyle,
    queries: () => queries };
}
function receiver(allowFloating) {
  const state = {};
  const api = {};
  for (const method of ['barBackgroundColor', 'barBackgroundBlurStyle', 'barOverlap', 'cachedMaxCount', 'barFloatingStyle']) {
    api[method] = (...args) => { if (method === 'barFloatingStyle' || method === 'cachedMaxCount') assert.ok(allowFloating);
      state[method] = args[0]; return api; };
  }
  return { state, api };
}
const modern = materialFixture(true);
const current = receiver(true);
for (const [mode, expectedLevel] of [[M.AUTO, 10], [M.EXQUISITE, 0], [M.GENTLE, 1], [M.SMOOTH, 2]]) {
  new modern.Style(12, M.OFF, '#fff').applyNormalAttribute(current.api);
  assert.equal(current.state.barFloatingStyle.systemMaterialEffect.materialType, 0);
  assert.equal(current.state.barBackgroundBlurStyle, BlurStyle.NONE);
  assert.equal(current.state.barBackgroundColor, '#fff');
  new modern.Style(12, mode, '#111').applyNormalAttribute(current.api);
  assert.equal(current.state.barBackgroundColor, Color.Transparent);
  assert.equal(current.state.barBackgroundBlurStyle, BlurStyle.NONE);
  assert.deepEqual(current.state.barFloatingStyle.systemMaterialEffect, { materialType: 100, materialLevel: expectedLevel });
  assert.equal(current.state.barFloatingStyle.barBottomMargin, 24);
}
new modern.Style(28, M.OFF, '#111').applyNormalAttribute(current.api);
assert.equal(current.state.barBackgroundColor, '#111');
assert.equal(current.state.barFloatingStyle.barBottomMargin, 36);
const legacy = materialFixture(false), old = receiver(false);
const oldCapabilities = legacy.readDockLightCapabilities();
assert.equal(oldCapabilities.floatingSupported, false);
assert.equal(legacy.queries(), 0);
new legacy.Style(12, M.AUTO, '#fff').applyNormalAttribute(old.api);
assert.equal(old.state.barBackgroundBlurStyle, BlurStyle.COMPONENT_THICK);
new legacy.Style(12, M.OFF, '#fff').applyNormalAttribute(old.api);
assert.equal(old.state.barBackgroundBlurStyle, BlurStyle.NONE);
assert.equal(old.state.barOverlap, true);
const unavailable = materialFixture(true, false), caps = unavailable.readDockLightCapabilities();
assert.equal(caps.immersiveSupported, false);
assert.match(unavailable.dockLightStatus(M.EXQUISITE, caps), /使用流畅/);
const broken = materialFixture(true, false, true), brokenCaps = broken.readDockLightCapabilities();
assert.equal(brokenCaps.queryFailed, true);
assert.match(broken.dockLightStatus(M.GENTLE, brokenCaps), /无法确认/);
pass('新旧系统属性切换、主题背景复位和能力查询失败');

// 模拟磁盘与缓存分离：只有 flush 确认才算保存；失败时验证单键回滚与重启读取。
const cache = new Map(), disk = new Map();
let nextFlush, failPut = false, gameProcess = false;
const store = {
  getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
  async put(key, value) { cache.set(key, value); if (failPut) { failPut = false; throw new Error('put failed'); } },
  putSync: (key, value) => cache.set(key, value),
  async flush() { const pending = nextFlush; nextFlush = undefined; if (pending) await pending;
    for (const [key, value] of cache) disk.set(key, value); }
};
const dependencies = { ...pure, ProcessPreferences: { open: () => store, isGameProcess: () => gameProcess }, formatError: String };
const PreferenceManager = makePureEtsLoader({ commons: dependencies,
  '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } })('feature_system/src/main/ets/PreferenceManager.ets').PreferenceManager;
const manager = new PreferenceManager({ preferencesDir: '/light-test' });
assert.equal(manager.dockLightMode, M.AUTO);
let confirm;
nextFlush = new Promise(resolve => { confirm = resolve; });
let saved = false;
const writing = manager.saveDockLightMode(M.EXQUISITE).then(() => { saved = true; });
await Promise.resolve(); await Promise.resolve();
assert.equal(saved, false);
assert.equal(manager.dockLightMode, M.AUTO, '页面在保存途中重读，不得发布尚未确认的缓存');
assert.equal(disk.has('dockLightMode'), false);
confirm(); await writing;
assert.equal(disk.get('dockLightMode'), M.EXQUISITE);
assert.equal(new PreferenceManager({ preferencesDir: '/light-test' }).dockLightMode, M.EXQUISITE);
nextFlush = Promise.reject(new Error('flush failed'));
await assert.rejects(manager.saveDockLightMode(M.OFF), /flush failed/);
assert.equal(cache.get('dockLightMode'), M.EXQUISITE);
assert.equal(disk.get('dockLightMode'), M.EXQUISITE);
failPut = true;
await assert.rejects(manager.saveDockLightMode(M.GENTLE), /put failed/);
assert.equal(cache.get('dockLightMode'), M.EXQUISITE);
gameProcess = true;
await assert.rejects(manager.saveDockLightMode(M.OFF), /不可保存/);
gameProcess = false;
await assert.rejects(manager.saveDockLightMode('future'), /无效/);
manager.saveAll({ themeMode: 2, mcVersion: '1.20.4', useNewWindow: false, versionIsolation: true, mcXmx: 2048, jdkVersion: '17' });
await Promise.resolve();
assert.equal(disk.get('dockLightMode'), M.EXQUISITE, '旧批量快照覆盖了新独立偏好');
cache.set('dockLightMode', 'future');
assert.equal(manager.dockLightMode, M.AUTO);
pass('持久化确认、失败回滚、进程边界与批量保存隔离');

fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify({ status: 'passed', startedAt,
  finishedAt: new Date().toISOString(), groups }, null, 2) + '\n');

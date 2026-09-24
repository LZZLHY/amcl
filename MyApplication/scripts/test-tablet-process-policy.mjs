// 生产平板策略、持久偏好和冷启动锁存回归；系统进程创建/真实触控仍须设备验证。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const load = makePureEtsLoader();
const { ProductRuntimePolicy } = load('gamecontrol/src/main/ets/ProductRuntimePolicy.ets');
const { InputProductKind } = load('gamecontrol/src/main/ets/ProductInputPolicy.ets');
for (const api of [14, 20, 25, 26]) {
  const off = ProductRuntimePolicy.resolve('universal', 'tablet', api, 'auto', true, false);
  const on = ProductRuntimePolicy.resolve('universal', 'tablet', api, 'auto', true, true);
  assert.equal(on.isolatedGameProcess, true);
  assert.equal(off.isolatedGameProcess, false);
  assert.equal(on.desktopWindow, false);
  assert.equal(on.input.productKind, InputProductKind.Mobile);
  assert.deepEqual(on.input, off.input);
}
for (const device of ['phone', 'unknown', 'tv']) {
  assert.equal(ProductRuntimePolicy.resolve('universal', device, 26, 'auto', true, true).isolatedGameProcess, false);
}
assert.equal(ProductRuntimePolicy.resolve('universal', 'tablet', 13, 'auto', false, true).isolatedGameProcess, false);
assert.equal(ProductRuntimePolicy.resolve('desktop', 'tablet', 26, 'auto', true, true).isolatedGameProcess, false);
for (const enabled of [true, false]) {
  assert.equal(ProductRuntimePolicy.resolve('desktop', '2in1', 26, 'auto', true, enabled).isolatedGameProcess, true);
}

// 每个loader对应一个冷启动进程；保存值可变，但实际路线在第一次initialize后不可变。
function runtimeProfile({ product = 'default', device = 'tablet', saved = true, game = false, lock = 1 } = {}) {
  let choice = saved;
  let reads = 0;
  const runtimeLoad = makePureEtsLoader({
    '@ohos.deviceInfo': { default: { deviceType: device, sdkApiVersion: 26 } },
    'libentry.so': { default: { hardwareRawMouseAvailable: () => false, desktopGameProcessState: () => lock } },
    'gamecontrol': { ProductRuntimePolicy },
    'feature_system': { PreferenceManager: class {
      desktopInteraction = 'auto';
      get tabletIndependentGameProcess() { reads++; return choice; }
    } },
    'entry/ProductBuildProfile': { ProductBuildProfile: {
      family: product === 'desktop' ? 'desktop' : 'universal', runtimeRawMouse: false,
      developerDiagnostics: product === 'default', touchControls: true,
    } },
    // 旧marker不再有权限：若仍尝试读取文件，此边界会直接令测试失败。
    '@kit.CoreFileKit': { fileIo: new Proxy({}, { get() { throw new Error('retired marker accessed'); } }) },
    'commons': { AppLogger: { info() {} }, LOG_DOMAIN_LAUNCH: 1, ProcessPreferences: { isGameProcess: () => game } },
  });
  const profile = runtimeLoad('entry/src/main/ets/product/RuntimeProductProfile.ets').RuntimeProductProfile;
  profile.initialize({ filesDir: '/sandbox' });
  return { profile, setSaved: value => { choice = value; }, reads: () => reads };
}
for (const product of ['default', 'store', 'sideload']) {
  const run = runtimeProfile({ product });
  assert.equal(run.profile.selection().isolatedGameProcess, true);
  run.setSaved(false);
  run.profile.initialize({ filesDir: '/sandbox' });
  assert.equal(run.profile.selection().isolatedGameProcess, true, '同PID重新初始化不能提前应用关闭');
  assert.equal(run.reads(), 1);
}
const off = runtimeProfile({ saved: false });
off.setSaved(true);
off.profile.initialize({ filesDir: '/sandbox' });
assert.equal(off.profile.selection().isolatedGameProcess, false);
assert.equal(runtimeProfile({ saved: false }).profile.selection().isolatedGameProcess, false, '新进程读取保存的关闭');
assert.equal(runtimeProfile({ saved: false, game: true }).profile.selection().isolatedGameProcess, true,
  '已验证子进程实际路线不能被下次启动器的关闭偏好推翻');
for (const lock of [0, -1, -2]) assert.throws(() => runtimeProfile({ game: true, lock }), /身份/);
for (const device of ['phone', 'unknown']) {
  const run = runtimeProfile({ device });
  assert.equal(run.profile.selection().isolatedGameProcess, false);
  assert.equal(run.reads(), 0);
}
assert.equal(runtimeProfile({ product: 'desktop' }).profile.selection().isolatedGameProcess, false);
console.log('PASS tablet process: persistent choice, same-PID latch, child actual identity, device/product boundaries');

// 使用真实PreferenceManager，系统边界只提供内存Preferences及可控写盘失败。
function preferencesFixture(initial, game = false) {
  const data = new Map(initial === undefined ? [] : [['tabletIndependentGameProcess', initial]]);
  let failFlush = false;
  const store = { getSync: (key, fallback) => data.has(key) ? data.get(key) : fallback,
    putSync: (key, value) => data.set(key, value), put: async (key, value) => data.set(key, value),
    flush: async () => { if (failFlush) { failFlush = false; throw new Error('disk failure'); } } };
  const prefLoad = makePureEtsLoader({
    commons: { ProcessPreferences: { open: () => store, isGameProcess: () => game }, formatError: String },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
  });
  const PreferenceManager = prefLoad('feature_system/src/main/ets/PreferenceManager.ets').PreferenceManager;
  return { manager: new PreferenceManager({}), data, fail: () => { failFlush = true; } };
}
assert.equal(preferencesFixture().manager.tabletIndependentGameProcess, true);
for (const value of [false, 'false', 'true', 1, null]) {
  assert.equal(preferencesFixture(value).manager.tabletIndependentGameProcess, false);
}
const pref = preferencesFixture(true);
await pref.manager.saveTabletIndependentGameProcess(false);
assert.equal(pref.data.get('tabletIndependentGameProcess'), false);
pref.fail();
await assert.rejects(pref.manager.saveTabletIndependentGameProcess(true), /disk failure/);
assert.equal(pref.data.get('tabletIndependentGameProcess'), false, '写盘失败必须回滚显示来源');
await assert.rejects(preferencesFixture(true, true).manager.saveTabletIndependentGameProcess(false), /启动器/);
console.log('PASS tablet preference: default true, strict boolean, awaited persistence, rollback and owner-only writes');

// 执行生产首页部署方法，不能把活跃/未知游戏锁当成空闲后覆盖JAR。
const indexSource = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = indexSource.indexOf('  private deployRuntimeIfIdle_(): void {');
const end = indexSource.indexOf('\n  /** 真正执行切换。', start);
assert.ok(start >= 0 && end > start);
const compiled = compiler.transpileModule('class Probe {\n' + indexSource.slice(start, end)
  + '\n}\nmodule.exports = Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
for (const state of [0, 1, -1, -2, -3, 'throw']) {
  let deployments = 0;
  const module = { exports: {} };
  new Function('module', 'testNapi', 'RuntimeDeployer', 'AppLogger', 'TAG', 'LOG_DOMAIN_LAUNCH', compiled)(
    module, { desktopGameProcessState() { if (state === 'throw') throw new Error('unavailable'); return state; } },
    class { deployAll() { deployments++; } }, { warn() {} }, 'test', 1);
  const subject = new module.exports();
  subject.context = { filesDir: '/sandbox' };
  subject.mcRoot = () => '/minecraft';
  subject.deployRuntimeIfIdle_();
  assert.equal(deployments, state === 0 ? 1 : 0);
}
console.log('PASS production Index deployment guard');

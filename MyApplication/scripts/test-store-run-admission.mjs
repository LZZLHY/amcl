/** 执行真实偏好事务及跨进程准入类；文件/Preferences仅替换为同一共享内存边界，不操作用户数据。 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';

const disk = new Map(), values = new Map();
let uuid = 0, failFlush = 0, failWrite = false;
const context = { filesDir: '/app', preferencesDir: '/prefs' };
const pref = {
  getSync(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
  async get(key, fallback) { return this.getSync(key, fallback); },
  putSync(key, value) { values.set(key, value); },
  async put(key, value) { values.set(key, value); },
  async flush() { if (failFlush > 0) { failFlush--; throw new Error('fixture flush failed'); } },
};
const files = {
  mkdirSync() {}, statSync() { return { isDirectory: () => true }; },
  lstatSync(path) { if (!disk.has(path)) throw new Error('missing state'); return { isFile: () => true, isSymbolicLink: () => false, size: disk.get(path).length }; },
  readTextSync(path) { if (!disk.has(path)) throw new Error('missing state'); return disk.get(path); },
  unlinkSync(path) { if (!disk.delete(path)) throw new Error('missing state'); },
};
function process(store = true, game = false) {
  const common = {
    ProcessPreferences: { open: () => pref, isGameProcess: () => game },
    ThemeMode: { SYSTEM: 0 }, formatError: error => error.message,
    AtomicFileWriter: { write(path, body) { if (failWrite) throw new Error('fixture atomic failure'); disk.set(path, body); } },
  };
  const load = loader({
    commons: common,
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
    '@kit.CoreFileKit': { fileIo: files }, '@kit.AbilityKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'fixture-epoch-' + (++uuid) } },
    'entry/ProductBuildProfile': { ProductBuildProfile: { storeChannel: store } },
  });
  const preference = load('feature_system/src/main/ets/PreferenceManager.ets');
  // 新游戏准入同时引用进程预约；装配本 fixture 进程中的真实纯协调器，不用空类或
  // 默认放行函数绕过依赖。每次 process() 独立 loader，对应各自模块/进程身份。
  const processActivities = load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets');
  const gate = loader({
    commons: common, feature_system: preference, feature_core: processActivities,
    '@kit.CoreFileKit': { fileIo: files }, '@kit.AbilityKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'fixture-epoch-' + (++uuid) } },
    'entry/ProductBuildProfile': { ProductBuildProfile: { storeChannel: store } },
  })('entry/src/main/ets/runtime/GameRunAdmission.ets').GameRunAdmission;
  return { gate, PreferenceManager: preference.PreferenceManager };
}

const defaultProcess = process(false);
assert.equal(defaultProcess.gate.isAllowed(), true);
assert.equal(defaultProcess.gate.capture(context), '');
defaultProcess.gate.assertToken(context, '');
const parent = process(); parent.gate.initialize(context);
assert.equal(parent.gate.isAllowed(), false);
assert.throws(() => parent.gate.capture(context));
await parent.gate.saveChoice(context, true);
const first = parent.gate.capture(context);
const child = process(true, true); child.gate.installTicket(context, first);
assert.equal(child.gate.captureDispatch(context), first);
child.gate.assertNewLaunch(context);
await assert.rejects(new child.PreferenceManager(context).saveStoreAllowDebug(false));

const disabling = parent.gate.saveChoice(context, false);
assert.throws(() => child.gate.assertNewLaunch(context), '关闭先发布，不等child旧偏好刷新');
await disabling;
await parent.gate.saveChoice(context, true);
assert.throws(() => parent.gate.assertToken(context, first), '关闭再开启不恢复旧异步请求');
assert.throws(() => child.gate.assertNewLaunch(context), 'child必须用父侧原票据');
const second = parent.gate.capture(context); child.gate.installTicket(context, second);
const restarted = process(); restarted.gate.initialize(context);
assert.throws(() => child.gate.assertNewLaunch(context), '新owner epoch撤销旧票据');
assert.equal(restarted.gate.isAllowed(), true, '明确保存的选择跨启动器重建保留');

await restarted.gate.saveChoice(context, false);
failFlush = 1;
await assert.rejects(restarted.gate.saveChoice(context, true));
assert.equal(restarted.gate.isAllowed(), false);
assert.equal(new restarted.PreferenceManager(context).storeAllowDebug, false);
assert.throws(() => restarted.gate.capture(context));
const olderEnable = restarted.gate.saveChoice(context, true);
const newerDisable = restarted.gate.saveChoice(context, false);
await Promise.all([olderEnable, newerDisable]);
assert.equal(restarted.gate.isAllowed(), false);
assert.equal(values.get('storeAllowDebug'), false);
failWrite = true;
await assert.rejects(restarted.gate.saveChoice(context, true));
assert.equal(restarted.gate.isAllowed(), false);
failWrite = false;
await restarted.gate.saveChoice(context, true);
const openBeforeFailure = restarted.gate.capture(context);
child.gate.installTicket(context, openBeforeFailure);
failWrite = true;
await assert.rejects(restarted.gate.saveChoice(context, false));
assert.equal(restarted.gate.isAllowed(), false);
assert.throws(() => restarted.gate.capture(context), '旧磁盘开放也不能绕过owner失败关闭');
assert.throws(() => restarted.gate.assertToken(context, openBeforeFailure));
assert.throws(() => child.gate.assertNewLaunch(context), '发布失败撤销旧文件，child不能使用旧授权');
failWrite = false;
disk.set('/app/game-run-admission/state.json', '{"schema":1,"epoch":"x","revision":1,"allowed":"true"}');
assert.throws(() => restarted.gate.capture(context));
values.set('storeAllowDebug', true);
disk.delete('/app/game-run-admission/state.json');
const afterIncompleteEnable = process(); afterIncompleteEnable.gate.initialize(context);
assert.equal(afterIncompleteEnable.gate.isAllowed(), false, '偏好true但没有发布成功记录不能重启后误开');
assert.throws(() => afterIncompleteEnable.gate.capture(context));
console.log('PASS store运行准入：默认关闭、确认保存、跨进程撤销、旧票据失效、保存失败、并发选择、默认产品兼容');

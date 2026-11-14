/**
 * 运行真实 ArkTS 权限协调器与原 Preferences 提交代码；只替换系统授权/存储/Native端口。
 * 覆盖异步授权退休、关闭优先和保存回滚，不把模拟授权当作设备麦克风验收。
 */
import assert from 'node:assert/strict';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import fs from 'node:fs';
import path from 'node:path';

const outputRoot = process.env.AMCL_RUN_DIR;
if (!outputRoot || !path.isAbsolute(outputRoot)) throw new Error('Set an explicit external AMCL_RUN_DIR');
let fixtureId = 0;

/** 可人工控制完成时机的系统 Promise，用来重放视图销毁与后续设置操作的交错。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

/** 每例独立加载生产模块，防止静态 owner/权限回调从另一夹具泄漏；Preferences仍由生产类管理。 */
function fixture({enabled = false, granted = false} = {}) {
  const values = new Map([['modMicrophoneEnabled', enabled]]), storage = new Map(), policies = [], pending = [];
  const state = {granted, prompts: 0, failedFlushes: 0, flushGate: undefined, policyResult: 0, listener: undefined,
    throwPolicy: false, warnings: []};
  const filesDir = path.join(outputRoot, 'policy-files', String(++fixtureId)); fs.mkdirSync(filesDir, {recursive: true});
  const context = {filesDir, preferencesDir: filesDir, applicationInfo: {accessTokenId: 7}};
  const store = {
    getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
    put: async (key, value) => { values.set(key, value); },
    putSync: (key, value) => { values.set(key, value); },
    flush: async () => {
      if (state.failedFlushes > 0) { state.failedFlushes--; throw new Error('disk failure'); }
      if (state.flushGate) await state.flushGate.promise;
    },
  };
  const processPreferences = {open: () => store, isGameProcess: () => false,
    captureOwner: async (_context, name) => { await store.flush(); return {name, values: Object.fromEntries(values)}; }};
  const commons = {ProcessPreferences: processPreferences,
    AppLogger: {warn: (...args) => state.warnings.push(args)}, LOG_DOMAIN_LAUNCH: 1};
  const loadPreferences = makePureEtsLoader({commons, '@kit.PerformanceAnalysisKit': {hilog: {warn() {}}}});
  const {PreferenceManager} = loadPreferences('feature_system/src/main/ets/PreferenceManager.ets');
  const manager = {
    on: (_event, _permissions, callback) => { state.listener = callback; },
    off: (_event, _permissions, callback) => { assert.equal(callback, state.listener); state.listener = undefined; },
    checkAccessTokenSync: () => state.granted ? 0 : -1,
    requestPermissionsFromUser: () => { state.prompts++; const next = deferred(); pending.push(next); return next.promise; },
  };
  const native = {audioConfigurePolicyRoot: () => true,
    audioSetPolicy: (allow, foreground) => {
      policies.push([allow, foreground]);
      if (state.throwPolicy) throw new Error('injected bridge failure');
      return Promise.resolve(state.policyResult);
    }};
  const fileIo = {OpenMode: {CREATE: 1, WRITE_ONLY: 2, TRUNC: 4},
    readTextSync: file => fs.readFileSync(file, 'utf8'),
    openSync: file => ({fd: fs.openSync(file, 'w')}),
    writeSync: (fd, value) => fs.writeSync(fd, value),
    fsyncSync: fd => fs.fsyncSync(fd), closeSync: file => fs.closeSync(file.fd),
    renameSync: (from, to) => fs.renameSync(from, to)};
  globalThis.AppStorage = {setOrCreate: (key, value) => storage.set(key, value)};
  const load = makePureEtsLoader({commons, feature_system: {PreferenceManager},
    '@kit.CoreFileKit': {fileIo},
    '@kit.AbilityKit': {abilityAccessCtrl: {createAtManager: () => manager, GrantStatus: {PERMISSION_GRANTED: 0}}},
    'libentry.so': {__esModule: true, default: native}});
  const {ModAudioRuntime: runtime} = load('entry/src/main/ets/runtime/ModAudioRuntime.ets');
  runtime.attach(context);
  return {runtime, context, state, storage, values, policies, pending, preferences: new PreferenceManager(context), PreferenceManager,
    policy: () => fs.readFileSync(path.join(filesDir, 'mod-audio-policy.v1'), 'utf8')};
}

/** 刷新生产 Promise 续体，不使用定时 sleep 或把等待时间当作用户授权。 */
async function settle() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

{
  const f = fixture();
  assert.equal(f.state.prompts, 0, '装配和枚举不请求权限');
  assert.deepEqual(f.policies.at(-1), [false, false]);
  f.runtime.setForeground(true);
  const task = f.runtime.setEnabled(true);
  assert.equal(f.state.prompts, 1);
  assert.equal(f.preferences.modMicrophoneEnabled, false);
  f.state.granted = true; f.pending[0].resolve({authResults: [0]}); await task;
  assert.equal(f.preferences.modMicrophoneEnabled, true);
  assert.deepEqual(f.policies.at(-1), [true, true]);
  f.runtime.setForeground(false);
  assert.deepEqual(f.policies.at(-1), [true, false]);
  f.runtime.detach(); assert.deepEqual(f.policies.at(-1), [false, false]);
}
{
  const f = fixture(); f.runtime.setForeground(true);
  const task = f.runtime.setEnabled(true); f.runtime.detach();
  f.state.granted = true; f.pending[0].resolve({authResults: [0]});
  await assert.rejects(task, /已过期/);
  assert.equal(f.values.get('modMicrophoneEnabled'), false, '旧权限回包不能写入新局选择');
  assert.deepEqual(f.policies.at(-1), [false, false]);
}
{
  const f = fixture(); f.runtime.setForeground(true);
  const first = f.runtime.setEnabled(true);
  await f.runtime.setEnabled(false);
  f.state.granted = true; f.pending[0].resolve({authResults: [0]});
  await assert.rejects(first, /已过期/);
  assert.equal(f.preferences.modMicrophoneEnabled, false, '后来的关闭退休旧开启请求');
  assert.equal(f.policies.some(pair => pair[0]), false);
}
{
  const f = fixture({granted: true}); f.runtime.setForeground(true); f.state.failedFlushes = 1;
  await assert.rejects(f.runtime.setEnabled(true), /disk failure/);
  assert.equal(f.preferences.modMicrophoneEnabled, false, '保存失败回滚已确认偏好');
  assert.equal(f.policies.some(pair => pair[0]), false, '未提交开启不得授权采集');
}
{
  const f = fixture({enabled: true, granted: true}); f.runtime.setForeground(true);
  const gate = deferred(); f.state.flushGate = gate;
  const off = f.runtime.setEnabled(false); await settle();
  f.runtime.refresh();
  assert.deepEqual(f.policies.at(-1), [false, true], '关闭保存尚未完成也保持Native拒绝');
  assert.equal(f.preferences.modMicrophoneEnabled, true, '提交期间getter保留确认值');
  gate.resolve(); await off;
  assert.equal(f.preferences.modMicrophoneEnabled, false);
}
{
  const f = fixture(); const task = f.runtime.setEnabled(true);
  f.pending[0].resolve({authResults: [-1]}); await assert.rejects(task, /未授予/);
  assert.equal(f.preferences.modMicrophoneEnabled, false);
}
{
  const f = fixture({enabled: true, granted: false});
  assert.equal(f.storage.get('modAudioUserEnabled'), true);
  assert.equal(f.storage.get('modAudioPermissionGranted'), false, '用户意图不伪装系统授权');
  f.state.granted = true; f.state.listener({});
  assert.equal(f.storage.get('modAudioPermissionGranted'), true);
}
{
  const f = fixture({enabled: true, granted: true});
  const first = f.policy(); f.runtime.detach(); f.runtime.attach(f.context);
  assert.equal(f.policy(), first, '相同确认选择的Ability重建不撤销独立游戏');
  await f.runtime.setEnabled(false); const revoked = f.policy();
  await f.runtime.setEnabled(true); const enabled = f.policy();
  assert.notEqual(revoked.split(' ')[1], first.split(' ')[1]);
  assert.notEqual(enabled.split(' ')[1], first.split(' ')[1], '关闭再开启不复活旧局epoch');
  assert.ok(enabled.endsWith(' 1\n'));
}
{
  const f = fixture({granted: true}); const gate = deferred(); f.state.flushGate = gate;
  // 真实flush挂起时快照必须排在完整事务之后，不能读取put已经改变的缓存。
  const original = f.preferences.setModMicrophoneEnabled.bind(f.preferences);
  const task = original(true); await settle();
  const snapshot = f.PreferenceManager.captureConfirmedSettings(f.context);
  let captured = false; snapshot.then(() => { captured = true; }); await settle();
  assert.equal(captured, false, '真实captureOwner不能越过在途提交队列');
  gate.resolve(); await task; const view = await snapshot;
  assert.equal(view.values.modMicrophoneEnabled, true);
}
{
  const f = fixture({granted: true}); f.state.failedFlushes = 1;
  const task = f.preferences.setModMicrophoneEnabled(true);
  const snapshot = f.PreferenceManager.captureConfirmedSettings(f.context);
  await assert.rejects(task, /disk failure/);
  const view = await snapshot;
  assert.equal(view.values.modMicrophoneEnabled, false, '失败提交回滚后捕获真实owner确认态');
}
{
  const f = fixture({granted: true}); const gate = deferred(); f.state.flushGate = gate;
  const task = f.runtime.setEnabled(true); await settle();
  f.runtime.detach(); f.runtime.attach({...f.context});
  gate.resolve(); await task;
  assert.equal(f.preferences.modMicrophoneEnabled, true);
  assert.equal(f.storage.get('modAudioUserEnabled'), true, '旧事务提交后新owner发布确认态');
  assert.ok(f.policy().endsWith(' 1\n'), 'Ability重建不遗失已确认开启的共享政策');
}
{
  const f = fixture({enabled: true, granted: true});
  f.state.throwPolicy = true;
  f.runtime.detach();
  assert.deepEqual(f.policies.at(-1), [false, false]);
  assert.equal(f.state.listener, undefined, '同步桥接异常不能阻断监听和Context退役');
  assert.equal(f.runtime.permissionGranted(), false);
  assert.equal(f.runtime.enabled(), false);
  assert.equal(f.state.warnings.filter(args => args[1] === '退役音频政策桥不可用').length, 1);
  await assert.rejects(f.runtime.setEnabled(true), /上下文/);
}
delete globalThis.AppStorage;
console.log('PASS mod audio real ArkTS authorization/lifecycle, stale replies, latest close, persistence rollback, shared epoch and serialized owner snapshots');

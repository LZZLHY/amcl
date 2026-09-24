/**
 * 执行生产GameAbility及ProcessRuntime，系统服务以可控制完成顺序的边界替身提供。
 * 验证快照/初始化/页面加载失败在进程退出前可见，且失败状态不会继续加载游戏页。
 * --before仅重放本次归档的修复前正文，记录旧缺陷；默认始终测试当前生产源文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(import.meta.dirname, '..');
const before = process.argv.includes('--before');
// 修复前正文位于版本化证据树；这里只迁移读取路径，不改旧正文以免污染负向回放。
const archive = 'docs/testing/evidence/nativegl-startup-audit-20260922';
const noop = () => {};

/** 完整转译实际模块，不抽取方法或重写生产try/catch；未知依赖必须显式给出。 */
function load(file, dependencies, storage) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const compiled = compiler.transpileModule(source, { fileName: file.replace(/\.(ets|txt)$/, '.ts'),
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'AppStorage', compiled)(name => {
    if (!Object.hasOwn(dependencies, name)) throw new Error('Unexpected dependency: ' + name);
    return dependencies[name];
  }, module, module.exports, storage);
  return module.exports;
}

/** 每例创建全新模块状态；通知保持pending，用于证明terminateSelf未抢先结束进程。 */
function scenario(failure = '') {
  const events = [], disk = [], notices = [], values = new Map();
  let persistent = false, monitors = 0, loads = 0, resolveReport, rejectReport;
  const report = new Promise((resolve, reject) => { resolveReport = resolve; rejectReport = reject; });
  const record = (...args) => { if (persistent) disk.push(args.map(String).join(' ')); };
  const logger = { info: record, error: record, warn: record, debug: record,
    flush: () => events.push('flush'), setNativeLogSink: () => { persistent = true; } };
  const storage = { setOrCreate: (key, value) => values.set(key, value), get: key => values.get(key) };
  const context = { filesDir: '/private/files', applicationInfo: { name: 'com.amcl.launcher' }, config: { colorMode: 1 },
    getApplicationContext: () => context,
    startAbility: want => { events.push('report'); notices.push(want); return report; },
    terminateSelf: async () => { events.push('terminate'); } };
  const native = { desktopGameProcessState: () => {
    if (failure === 'isolation-throw') throw new Error('isolation boundary failed');
    return failure === 'isolation' ? -2 : 1;
  }, desktopProcessId: () => 200, amclLogInit: () => {
    events.push('log-init'); if (failure === 'log') throw new Error('disk unavailable');
  }, getDiagnosticCapabilities: () => 0, amclLedgerSetLaunchActivity: noop,
    desktopSetGamepadNativeMode: () => true, desktopGamepadFocus: noop, cancelAllInput: noop,
    setOhosFrameRateForeground: noop, mcForceExit: () => events.push('exit') };
  const monitor = { ensureStarted: () => {
    events.push('input'); monitors++;
    if (failure === 'page-params' && monitors === 2) throw new Error('late input setup failed');
  } };
  const commons = { AppLogger: logger, LOG_DOMAIN_LAUNCH: 1, LogTags: { GAME_ABILITY: 'GameAbility' },
    DiagnosticPolicy: { configure: () => events.push('runtime') },
    DistributionPolicy: { configure: noop }, DistributionChannel: {}, setLedgerScopeSink: noop,
    ledgerBegin: () => events.push('ledger') };
  const core = { ActivityCategory: { LAUNCH: 'launch' },
    DownloadManager: { instance: () => ({ initializeCaBundle: () => events.push('ca') }) },
    setDownloadNativeEngine: noop, setRelayNativeBridge: noop, setForgeNativeBridge: noop };
  const gamecontrol = { setControlNativeSink: noop, getInputDeviceMonitor: () => monitor,
    getInputSourceRegistry: () => ({ releaseAllEnds: noop }) };
  class UIAbility { constructor() { this.context = context; } }
  class Preferences { phoneExternalDir = ''; desktopNativeGamepad = false; }
  const dependencies = { 'libentry.so': { default: native }, 'commons': commons, 'feature_core': core,
    'gamecontrol': gamecontrol, '@kit.AbilityKit': { UIAbility }, '@kit.ArkUI': {}, '@kit.CoreFileKit': {},
    'entry/ProductBuildProfile': { ProductBuildProfile: {} }, 'entry/ProductLauncherWindowChrome': {},
    'entry/ProductInputProfile': { ProductInputProfile: { initialize: () => {
      if (failure === 'runtime') throw new Error('runtime setup failed');
    } } }, 'launch': { setLaunchNativeBridge: noop, setRuntimeSlotNativeOps: noop },
    'feature_system': { PreferenceManager: Preferences, GameStorage: { setPhoneExternalDir: noop }, setSystemNativeBridge: noop } };
  const runtime = load(before ? `${archive}/ProcessRuntime-before.txt` : 'entry/src/main/ets/runtime/ProcessRuntime.ets', dependencies, storage);
  Object.assign(dependencies, { '../runtime/ProcessRuntime': runtime,
    '../window/DesktopSystemBridge': { getDesktopSystemBridge: () => ({ stop: noop }) },
    '../runtime/PlatformDfxWatcher': { PlatformDfxWatcher: { start: () => events.push('watcher') } },
    '../runtime/DesktopLaunchSnapshot': { DesktopLaunchSnapshot: { consume: () => {
      events.push('snapshot'); if (failure === 'snapshot') throw new Error('snapshot invalid');
    } } }, '../runtime/GraphicsRecoveryStore': { GraphicsRecoveryStore: { ticket: () => undefined } } });
  const Ability = load(before ? `${archive}/GameAbility-before.txt` : 'entry/src/main/ets/gameability/GameAbility.ets', dependencies, storage).default;
  const ability = new Ability();
  const want = { parameters: { parentPid: 100, activityId: 123, snapshotId: 'ticket', accountSnapshot: 'private-credential',
    filesDir: context.filesDir, mcDir: '/minecraft', gameDir: '/minecraft/versions/test', mcVersion: '26.3', jdkVersion: '25' } };
  const stage = { loadContent: (_page, callback) => {
    loads++; if (failure === 'load-throw') throw new Error('loadContent threw');
    callback({ code: failure === 'load-callback' ? 7 : 0 });
  } };
  return { ability, want, stage, events, disk, notices, values, get loads() { return loads; },
    resolveReport, rejectReport };
}

const settle = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
if (before) {
  const failed = scenario('snapshot'); failed.ability.onCreate(failed.want, {});
  const lostLogs = failed.disk.length === 0;
  const prematureExit = failed.events.includes('terminate');
  failed.ability.onWindowStageCreate(failed.stage);
  assert.ok(lostLogs && prematureExit && failed.loads === 1);
  failed.resolveReport(); await settle();
  console.log(JSON.stringify({ snapshotFailure: { lostLogs, prematureExit, loadedPageAfterFailure: failed.loads } }, null, 2));
} else {
  const normal = scenario(); normal.ability.onCreate(normal.want, {});
  assert.ok(normal.events.indexOf('log-init') < normal.events.indexOf('snapshot'));
  assert.ok(normal.events.indexOf('snapshot') < normal.events.indexOf('runtime'));
  normal.ability.onWindowStageCreate(normal.stage); assert.equal(normal.loads, 1);
  assert.equal(normal.values.get('mcGameDir'), '/minecraft/versions/test');
  assert.ok(normal.disk.some(line => line.includes('stage=page-loaded')));
  assert.ok(!normal.disk.join('\n').includes('private-credential'));
  assert.ok(!normal.events.includes('report') && !normal.events.includes('terminate'));

  for (const failure of ['snapshot', 'runtime', 'page-params', 'load-throw', 'load-callback']) {
    const test = scenario(failure); test.ability.onCreate(test.want, {});
    test.ability.onWindowStageCreate(test.stage);
    assert.equal(test.notices.length, 1, failure);
    assert.equal(test.events.includes('terminate'), false, failure + ': await report');
    assert.ok(test.disk.some(line => line.includes('startup failed stage=')), failure + ': persistent cause');
    if (!failure.startsWith('load-')) assert.equal(test.loads, 0, failure + ': must not load partial state');
    if (failure === 'snapshot') assert.ok(!test.events.includes('runtime'));
    const previousLoads = test.loads; test.ability.onWindowStageCreate(test.stage);
    assert.equal(test.loads, previousLoads, failure + ': repeat window callback rejected');
    test.resolveReport(); await settle();
    assert.equal(test.events.filter(item => item === 'terminate').length, 1, failure + ': closes after delivery');
  }
  for (const failure of ['isolation', 'isolation-throw']) {
    const test = scenario(failure); test.ability.onCreate(test.want, {});
    test.ability.onWindowStageCreate(test.stage); test.ability.onDestroy();
    assert.equal(test.loads, 0); assert.ok(!test.events.includes('log-init') && !test.events.includes('exit'));
    assert.equal(test.notices.length, 1); assert.ok(!test.events.includes('terminate'));
    test.rejectReport(new Error('host unavailable')); await settle();
    assert.ok(test.events.includes('terminate'), failure + ': failed report still closes');
  }
  const failedReport = scenario('snapshot'); failedReport.ability.onCreate(failedReport.want, {});
  failedReport.rejectReport(new Error('host unavailable')); await settle();
  assert.ok(failedReport.disk.some(line => line.includes('Cannot report game startup failure')));
  assert.ok(failedReport.events.includes('terminate'));
  const noDisk = scenario('log'); noDisk.ability.onCreate(noDisk.want, {}); noDisk.ability.onWindowStageCreate(noDisk.stage);
  assert.equal(noDisk.loads, 1); assert.ok(noDisk.events.includes('ca'));
  console.log('Game startup lifecycle PASS: early logs, snapshot ownership, serial failure handoff, failed-page gate, load errors, logging fallback');
}

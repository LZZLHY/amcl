/**
 * 执行生产GameAbility及ProcessRuntime，系统服务以可控制完成顺序的边界替身提供。
 * 验证快照/初始化/页面加载失败在进程退出前可见，且失败状态不会继续加载游戏页。
 * --before仅重放本次归档的修复前正文，记录旧缺陷；默认始终测试当前生产源文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

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
function scenario(failure = '', pendingLedger = false) {
  const events = [], disk = [], notices = [], values = new Map();
  let persistent = false, monitors = 0, loads = 0, resolveReport, rejectReport;
  const report = new Promise((resolve, reject) => { resolveReport = resolve; rejectReport = reject; });
  let resolveLedger, rejectLedger;
  const ledger = pendingLedger ? new Promise((resolve, reject) => { resolveLedger = resolve; rejectLedger = reject; }) : undefined;
  const loadCallbacks = [];
  const record = (...args) => { if (persistent) disk.push(args.map(String).join(' ')); };
  const logger = { info: record, error: record, warn: (...args) => {
    events.push('warn'); record(...args);
  }, debug: record,
    flush: () => events.push('flush'), setNativeLogSink: () => { persistent = true; } };
  const storage = { setOrCreate: (key, value) => values.set(key, value), get: key => values.get(key) };
  const context = { filesDir: '/private/files', applicationInfo: { name: 'com.amcl.launcher' }, config: { colorMode: 1 },
    getApplicationContext: () => context,
    startAbility: want => { events.push('report'); notices.push(want); return report; },
    terminateSelf: async () => { events.push('terminate'); } };
  const native = { configureSideloadInstallRoot: () => true, desktopGameProcessState: () => {
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
    ledgerBegin: () => { throw Error('game production path must not call synchronous begin'); },
    ledgerBeginAsync: () => {
      events.push('ledger');
      if (pendingLedger) return ledger;
      if (failure === 'ledger-reject') return Promise.reject(Error('controlled ledger IO failure'));
      return Promise.resolve(failure !== 'ledger-false');
    },
    configureLedgerMaintenanceOwner: owner => { assert.equal(owner, false); events.push('ledger-owner-disabled'); } };
  const core = { ActivityCategory: { LAUNCH: 'launch' },
    DownloadManager: { instance: () => ({ initializeCaBundle: () => events.push('ca') }) },
    setDownloadNativeEngine: noop, setRelayNativeBridge: noop, setForgeNativeBridge: noop };
  const gamecontrol = { setControlNativeSink: noop, getInputDeviceMonitor: () => monitor,
    getInputSourceRegistry: () => ({ releaseAllEnds: noop, setNativeSink: noop, notifyAbilityForeground: noop }) };
  class UIAbility { constructor() { this.context = context; } }
  class Preferences { phoneExternalDir = ''; desktopNativeGamepad = false; }
  const dependencies = { 'libentry.so': { default: native }, 'commons': commons, 'feature_core': core,
    'gamecontrol': gamecontrol, '@kit.AbilityKit': { UIAbility }, '@kit.ArkUI': {}, '@kit.CoreFileKit': {},
    'entry/ProductBuildProfile': { ProductBuildProfile: {} }, 'entry/ProductLauncherWindowChrome': {},
    // 普通启动没有测试会话，实际空适配器也不会绑定局内观测。
    'entry/ProductQaGame': makePureEtsLoader()('entry/src/main/ets/runtime/UnavailableQaGame.ets'),
    'entry/ProductInputProfile': { ProductInputProfile: { initialize: () => {
      if (failure === 'runtime') throw new Error('runtime setup failed');
    } } }, 'launch': { setLaunchNativeBridge: noop, setRuntimeSlotNativeOps: noop,
      setJdkInstallNativeOps: ops => {
        for (const name of ['operation', 'extract', 'seal']) assert.equal(typeof ops[name], 'function');
        events.push('jdk-install-port');
      } },
    'feature_system': { PreferenceManager: Preferences, GameStorage: { setPhoneExternalDir: noop }, setSystemNativeBridge: noop } };
  // 初始化只发布用户请求与平台采集事实；策略模块仍使用真实输入计划解析器。
  dependencies['./NativeGamepadRoutePolicy'] = makePureEtsLoader({
    launch: makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets')
  })('entry/src/main/ets/runtime/NativeGamepadRoutePolicy.ets');
  dependencies['./ModAudioRuntime'] = { ModAudioRuntime: {
    attach: () => events.push('audio-attach'), detach: () => events.push('audio-detach'),
    setForeground: active => events.push('audio-foreground-' + active) } };
  const runtime = load(before ? `${archive}/ProcessRuntime-before.txt` : 'entry/src/main/ets/runtime/ProcessRuntime.ets', dependencies, storage);
  Object.assign(dependencies, { '../runtime/ProcessRuntime': runtime,
    // 页面退出会同步解绑游戏对话框，使用真实运行时并沿用本用例的 Native 边界。
    '../runtime/GameDialogRuntime': load('entry/src/main/ets/runtime/GameDialogRuntime.ets', dependencies, storage),
    // 本测试验证Ability准备失败的因果链；已装配宿主的真实停止协议由完整宿主测试执行。
    '../runtime/GameSessionHost': { stopGameSession: () => false,
      requestExistingGameSessionExit: () => { events.push('exit-request'); return undefined; } },
    '../runtime/ModAudioRuntime': dependencies['./ModAudioRuntime'],
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
    if (failure === 'load-deferred') { loadCallbacks.push(callback); return; }
    callback({ code: failure === 'load-callback' ? 7 : 0 });
  } };
  return { ability, want, stage, events, disk, notices, values, get loads() { return loads; },
    resolveReport, rejectReport, resolveLedger, rejectLedger, loadCallbacks };
}

const settle = async () => { for (let index = 0; index < 12; index++) await Promise.resolve(); };
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
  normal.ability.onWindowStageCreate(normal.stage); assert.equal(normal.loads, 0, 'window waits async ledger baseline');
  await settle(); assert.equal(normal.loads, 1, '启动检查点：' + JSON.stringify(normal.events) + '\n' + normal.disk.slice(-4).join('\n'));
  assert.equal(normal.values.get('mcGameDir'), '/minecraft/versions/test');
  assert.ok(normal.disk.some(line => line.includes('stage=page-loaded')));
  assert.ok(!normal.disk.join('\n').includes('private-credential'));
  assert.ok(!normal.events.includes('report') && !normal.events.includes('terminate'));

  for (const failure of ['snapshot', 'runtime', 'page-params', 'load-throw', 'load-callback']) {
    const test = scenario(failure); test.ability.onCreate(test.want, {});
    test.ability.onWindowStageCreate(test.stage);
    await settle();
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
  const noDisk = scenario('log'); noDisk.ability.onCreate(noDisk.want, {}); noDisk.ability.onWindowStageCreate(noDisk.stage); await settle();
  assert.equal(noDisk.loads, 1); assert.ok(noDisk.events.includes('ca'));
  // 游戏日志是诊断增强；明确await false/reject后告警降级，不能把磁盘故障变成游戏不可用。
  for (const failure of ['ledger-false', 'ledger-reject']) {
    const degraded = scenario(failure); degraded.ability.onCreate(degraded.want, {});
    degraded.ability.onWindowStageCreate(degraded.stage); await settle();
    assert.equal(degraded.loads, 1); assert.equal(degraded.notices.length, 0);
    assert.equal(degraded.values.get('gameLedgerCaptureIssueActivityId'), 123);
    assert.match(degraded.values.get('gameLedgerCaptureIssue'), /日志/);
    assert.ok(degraded.disk.some(line => line.includes('捕获完整性降级')));
    assert.ok(degraded.events.includes('ca') && degraded.events.includes('audio-attach'));
  }
  // 真正的begin保持pending时，窗口不能加载，CA/音频/输入等producer装配也不能抢跑。
  const pending = scenario('', true); pending.ability.onCreate(pending.want, {});
  pending.ability.onWindowStageCreate(pending.stage); await settle();
  assert.equal(pending.loads, 0);
  assert.ok(!pending.events.some(event => ['input', 'ca', 'audio-attach'].includes(event)));
  pending.resolveLedger(true); await settle();
  assert.equal(pending.loads, 1); assert.equal(pending.events.filter(event => event === 'ledger').length, 1);
  assert.ok(pending.events.indexOf('ledger') < pending.events.indexOf('input'));

  // attach内部会重置音频前台事实；开账期间到达的真实foreground必须在attach后补发，后台则不能复活。
  for (const background of [false, true]) {
    const foreground = scenario('', true); foreground.ability.onCreate(foreground.want, {});
    foreground.ability.onForeground(); if (background) foreground.ability.onBackground();
    foreground.resolveLedger(true); await settle();
    const attachIndex = foreground.events.indexOf('audio-attach');
    assert.ok(attachIndex >= 0);
    const postAttach = foreground.events.slice(attachIndex + 1).filter(event => event.startsWith('audio-foreground-'));
    assert.deepEqual(postAttach, background ? [] : ['audio-foreground-true']);
  }

  // 销毁Ability后迟到的开账结果只保留磁盘事实，不允许复活运行时、页面或错误回传。
  for (const outcome of ['true', 'false', 'reject']) {
    const retired = scenario('', true); retired.ability.onCreate(retired.want, {});
    retired.ability.onWindowStageCreate(retired.stage); retired.ability.onDestroy();
    if (outcome === 'reject') retired.rejectLedger(Error('late cancelled IO')); else retired.resolveLedger(outcome === 'true');
    await settle(); assert.equal(retired.loads, 0); assert.equal(retired.notices.length, 0);
    assert.ok(!retired.events.some(event => ['input', 'ca', 'audio-attach'].includes(event)));
    assert.equal(retired.values.has('mcLaunchActivityId'), false);
    assert.equal(retired.values.has('gameLedgerCaptureIssue'), false, '取消不能被诊断降级catch吞掉并继续发布');
  }

  // WindowStage替换只退休旧窗口续体，新窗口仍可等待同一初始化任务，不重复开账。
  const replaced = scenario('', true); replaced.ability.onCreate(replaced.want, {});
  replaced.ability.onWindowStageCreate(replaced.stage); replaced.ability.onWindowStageDestroy();
  let replacementLoads = 0;
  replaced.ability.onWindowStageCreate({ loadContent: (_page, callback) => { replacementLoads++; callback({ code: 0 }); } });
  replaced.resolveLedger(true); await settle();
  assert.equal(replaced.loads, 0); assert.equal(replacementLoads, 1);
  assert.equal(replaced.events.filter(event => event === 'ledger').length, 1);

  const lateLoad = scenario('load-deferred'); lateLoad.ability.onCreate(lateLoad.want, {});
  lateLoad.ability.onWindowStageCreate(lateLoad.stage); await settle(); assert.equal(lateLoad.loads, 1);
  lateLoad.ability.onWindowStageDestroy(); lateLoad.loadCallbacks[0]({ code: 7 }); await settle();
  assert.equal(lateLoad.notices.length, 0, 'retired window load callback cannot fail a later lifecycle');

  /** 完整执行页面早期开账方法，系统/IO端口只控制兑现顺序，不复制页面世代或归属规则。 */
  const pagePath = 'entry/src/main/ets/pages/McGamePage.ets';
  const pageSource = fs.readFileSync(path.join(root, pagePath), 'utf8');
  const ast = compiler.createSourceFile(pagePath, pageSource, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'beginLaunchLedgerEarly_'));
  const method = component.members.find(member => member.name?.getText(ast) === 'beginLaunchLedgerEarly_').getText(ast);
  const compiled = compiler.transpileModule('class Page {\n' + method + '\n}\nreturn Page;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  for (const retire of [false, true]) {
    let complete; const gate = new Promise(resolve => { complete = resolve; });
    const identities = [], warnings = []; let requests = 0, current = true;
    const Page = new Function('ledgerHas', 'ledgerBeginAsync', 'enrichSessionEnvironment', 'ActivityCategory',
      'AppStorage', 'testNapi', 'TAG', 'LOG_DOMAIN_LAUNCH', compiled)(
      () => false, () => { requests++; return gate; }, (_context, _id, meta) => meta,
      { LAUNCH: 'launch' }, { get: () => '' }, { amclLedgerSetLaunchActivity: id => identities.push(id) }, 'test', 1);
    const page = new Page(); Object.assign(page, { context: { filesDir: '/sandbox' }, launchStartedAt_: 123,
      inputLifecycleEpoch: 1, launchFrontendLease: {}, navigatedAway: false, sessionHost: { accepts: () => current },
      getUIContext: () => ({ getRouter: () => ({ getParams: () => ({ mcVersion: 'test', mcDir: '/minecraft' }) }) }),
      applicationFilesDir_: () => '/sandbox', launchLogger_: () => ({ warn: (...values) => warnings.push(values) }) });
    const task = page.beginLaunchLedgerEarly_(); await settle();
    assert.equal(requests, 1); assert.deepEqual(identities, []);
    if (retire) { current = false; page.inputLifecycleEpoch++; }
    complete(true); await task;
    assert.deepEqual(identities, retire ? [] : [123]); assert.deepEqual(warnings, []);
  }
  assert.doesNotMatch(pageSource, /\bledgerBegin\(/, 'all game page ledger begins must await the asynchronous API');
  console.log('Game startup lifecycle PASS: async baseline, shared window wait, destroy/window generations, serial failure handoff, load errors, logging fallback');
}

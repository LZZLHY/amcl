/**
 * 执行Index真实可见性/加速状态方法，验证订阅和timer的owner生命周期；不渲染ArkUI。
 * AST仅选择原始方法正文，业务判据不复制；平台/其他首页业务边界用显式no-op隔离。
 * 内存计时器不等待真实3秒，所有输出需显式仓外路径，不操作设备或用户偏好。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

assert.equal(process.argv[2], '--output'); assert.ok(path.isAbsolute(process.argv[3]));
const output = assertExternalOutputPath(process.argv[3], { root: PROJECT_ROOT });
const pagePath = path.join(PROJECT_ROOT, 'entry/src/main/ets/pages/Index.ets');
const clientPath = path.join(PROJECT_ROOT, 'feature_core/src/main/ets/download/RelayClient.ets');
const source = fs.readFileSync(pagePath, 'utf8'), clientSource = fs.readFileSync(clientPath, 'utf8');
const ast = compiler.createSourceFile('Index.ets', source, compiler.ScriptTarget.Latest, true);
const component = ast.statements.find(node => node.name?.getText(ast) === 'Index');
const names = ['relayPageVisible_', 'applyRelayStatus_', 'syncRelayObservation_', 'stopRelayObservation_',
  'onHomeTabVisibilityChanged_', 'onPageShow', 'onPageHide', 'aboutToDisappear'];
const methods = names.map(name => { const node = component.members.find(item => item.name?.getText(ast) === name);
  assert.ok(node, '必须执行真实组件方法：' + name); return node.getText(ast); });
const clientAst = compiler.createSourceFile('RelayClient.ets', clientSource, compiler.ScriptTarget.Latest, true);
const projection = clientAst.statements.find(node => node.name?.getText(clientAst) === 'relayStatusText');
assert.ok(projection);
const code = compiler.transpileModule(projection.getText(clientAst).replace(/^export\s+/, '') +
  '\nclass Harness {\n' + methods.join('\n') + '\n}', {
  compilerOptions: { target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true });
assert.equal((code.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
const passed = [];

function fixture() {
  const storage = new Map([['amclHostPageVisible', true]]), timers = new Map(), listeners = new Set();
  let timerId = 0, samples = 0, subscriptions = 0, cancellations = 0;
  let status = { enabled: true, active: true, sessionReady: true, usable: true, tripped: false,
    connecting: false, lastError: '', expiresAt: Date.now() + 1000000,
    native: { requests: 1, failures: 0, fallbacks: 0, authRejects: 0, usable: true, tripped: false } };
  const client = { subscribeStatus(listener) { subscriptions++; listeners.add(listener); listener(status);
    return () => { cancellations++; listeners.delete(listener); }; },
    refreshStatus() { samples++; for (const listener of [...listeners]) listener(status); } };
  const globals = { getRelayClient: () => client,
    AppStorage: { get: name => storage.get(name), setOrCreate: (name, value) => storage.set(name, value) },
    setInterval: (callback, delay) => { assert.equal(delay, 3000); const id = ++timerId; timers.set(id, callback); return id; },
    clearInterval: id => timers.delete(id), setTimeout: () => 1, clearTimeout() {},
    UpdateChecker: { hasCachedUpdate: () => false, currentVersionCode: () => 1000910, currentVersionName: () => '1.0.6' },
    ProductBuildProfile: { product: 'default' }, DistributionPolicy: { isStore: () => false },
    getAccountManager: () => ({ isReady: () => false }), UpdatePromptPresenter: { owns: () => false, forget() {} } };
  const Harness = new Function(...Object.keys(globals), code.outputText + '\nreturn Harness;')(...Object.values(globals));
  const page = new Harness();
  Object.assign(page, { startupAlive_: true, startupRouteVisible_: true, launcherInitializationComplete_: true,
    startupFinished_: true, startupInitialPageShow_: true, launcherInitialized_: true, currentTab: 2,
    accelDownload: true, accelStatus: '', relayStatusUnsubscribe_: null, relayStatusTimer_: -1,
    shownAppUpdateChannel: 'stable', storeExportUnsubscribe_: null, launcherWindow_: null,
    rootViewportUpdateTimer_: -1, registry: { removeListener() {} }, landscapeListener: null,
    getPrefManager_: () => ({ appUpdateChannel: 'stable', appUpdateLatestSeen: () => 0, appUpdateLatestName: () => '' }) });
  // 这些方法的业务与网关状态无关；仅作为真实生命周期方法调用的外部边界存在。
  for (const name of ['onLauncherWorkVisibilityChanged_', 'onSideloadTestRequest_', 'markRuntimeAppVerified_',
    'consumeLastSession', 'onUpdateRecoveryRequested_', 'refreshStoreManager_', 'updateJdkReadyState',
    'refreshRecentActivities_', 'tryConsumeLayoutImport', 'onGraphicsRecoverySignal_', 'drainUpdateDialogs_',
    'showUpdateRecovery_', 'onOpenErrorSheetReq', 'onPendingToast', 'onOpenNetDiagReq', 'onDesktopLaunchError',
    'onGameLayoutSyncNotice', 'finishErrorSheetWait_', 'exitUpdateForRoute_', 'closeUpdateDialog_']) page[name] = () => {};
  return { page, storage, timers, listeners, client,
    get counts() { return { samples, subscriptions, cancellations }; },
    setStatus(value) { status = { ...status, ...value }; } };
}

function test(name, action) { const f = fixture(); action(f); passed.push(name); console.log('PASS ' + name); }
try {
  test('页面show订阅并只创建一个设置页timer，Native熔断/恢复更新当前提示', f => {
    f.page.onPageShow(); assert.equal(f.listeners.size, 1); assert.equal(f.timers.size, 1); assert.equal(f.page.accelStatus, 'ok');
    f.page.syncRelayObservation_(); assert.equal(f.counts.subscriptions, 1); assert.equal(f.timers.size, 1);
    f.setStatus({ active: false, usable: false, tripped: true }); [...f.timers.values()][0]();
    assert.match(f.page.accelStatus, /熔断/);
    f.setStatus({ active: true, usable: true, tripped: false }); [...f.timers.values()][0](); assert.equal(f.page.accelStatus, 'ok');
    f.page.stopRelayObservation_(); assert.equal(f.listeners.size, 0); assert.equal(f.timers.size, 0);
  });
  test('切换下载或首页停止Native轮询，保留会话事件订阅，不重建重复owner', f => {
    f.page.syncRelayObservation_(); f.page.currentTab = 1; f.page.onHomeTabVisibilityChanged_();
    assert.equal(f.timers.size, 0); assert.equal(f.listeners.size, 1);
    f.setStatus({ usable: false, active: false, lastError: '续签失败' }); f.client.refreshStatus();
    assert.equal(f.page.accelStatus, '续签失败');
    f.page.currentTab = 2; f.page.onHomeTabVisibilityChanged_(); assert.equal(f.timers.size, 1); assert.equal(f.counts.subscriptions, 1);
    f.page.stopRelayObservation_();
  });
  test('路由hide与初始化前提前return均撤销owner，迟到callback不写旧页面', f => {
    f.page.syncRelayObservation_(); const late = [...f.listeners][0]; f.page.launcherInitialized_ = false;
    f.page.onPageHide(); assert.equal(f.timers.size, 0); assert.equal(f.listeners.size, 0);
    const old = f.page.accelStatus; late({ usable: false, enabled: true, lastError: 'late' }); assert.equal(f.page.accelStatus, old);
  });
  test('应用后台Storage可见性与组件disappear都释放timer/订阅，回前台重新取快照', f => {
    f.page.syncRelayObservation_(); f.storage.set('amclHostPageVisible', false); f.page.onHomeTabVisibilityChanged_();
    assert.equal(f.timers.size, 0); assert.equal(f.listeners.size, 0);
    f.setStatus({ usable: false, active: false, tripped: true }); f.storage.set('amclHostPageVisible', true);
    f.page.onHomeTabVisibilityChanged_(); assert.equal(f.listeners.size, 1); assert.match(f.page.accelStatus, /熔断/);
    f.page.aboutToDisappear(); assert.equal(f.timers.size, 0); assert.equal(f.listeners.size, 0);
    assert.equal(f.counts.subscriptions, f.counts.cancellations);
  });
  test('开关关闭保持零timer，未初始化页面show不能建立状态owner', f => {
    f.page.accelDownload = false; f.page.syncRelayObservation_(); assert.equal(f.timers.size, 0);
    f.page.stopRelayObservation_(); f.page.launcherInitializationComplete_ = false; f.page.onPageShow();
    assert.equal(f.listeners.size, 0); assert.equal(f.timers.size, 0);
  });
} finally {
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify({ passed, expected: 5, complete: passed.length === 5,
    sources: [pagePath, clientPath].map(file => ({ file, sha256: crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') })),
    scope: 'Index真实方法与状态文本；平台/其他页面业务边界替换；非ArkUI渲染或真机验证' }, null, 2) + '\n');
}

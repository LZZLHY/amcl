/** 执行真实Index生命周期/观察方法，验证隐藏页静默与必要业务处理分离。
 * 只控制平台定时器、网络Promise和其它无关服务；不在夹具中重写可见性或请求算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

function fixture() {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('Index.ets', source, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(value => value.name?.getText(ast) === 'onPageShow'));
  const names = ['getPrefManager_', 'finishErrorSheetWait_', 'registryListener', 'onRegistryChanged_', 'onLauncherWorkVisibilityChanged_', 'onPageShow',
    'onPageHide', 'aboutToDisappear', 'observeExportActivities_', 'refreshStoreManager_', 'onNetBannerChange',
    'startNetRecheck_', 'stopNetRecheck_', 'runNetCheck_', 'initNetworkCheck'];
  const members = names.map(name => {
    const member = component.members.find(value => value.name?.getText(ast) === name);
    assert.ok(member, '缺少真实方法：' + name);
    return source.slice(member.getStart(ast), member.end);
  });
  const code = compiler.transpileModule('class Page {\n' + members.join('\n') + '\n}\nmodule.exports=Page;',
    {compilerOptions: {target: compiler.ScriptTarget.ES2022}}).outputText;
  const timers = new Map(), requests = [], storage = new Map();
  let sequence = 0, businessCalls = 0, historyRefreshCalls = 0;
  /**
   * 共用导出监听已进入所有产品的可见生命周期。夹具提供真实subscribe解除契约，
   * 不用空observe方法回退业务，也不让default因缺边界而误做store源盘点。
   * 本测试只检查何时请求历史投影；耐久add后的真实LRU更新由导出生命周期专项覆盖。
   */
  const exportListeners = new Set();
  const exportState = { task: null, subscriptions: 0, unsubscriptions: 0, sourceInspections: 0 };
  const exportCoordinator = {
    subscribe(listener) {
      exportListeners.add(listener); exportState.subscriptions++;
      return () => { exportListeners.delete(listener); exportState.unsubscriptions++; };
    },
    getTask() { return exportState.task; },
    inspectSource() { exportState.sourceInspections++; assert.fail('default idle observer must not inspect a store source'); },
  };
  const module = {exports: {}};
  new Function('module', 'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout', 'quickConnectivityCheck',
    'AppStorage', 'getAccountManager', 'UpdatePromptPresenter', 'DistributionPolicy', 'UpdateChecker', 'ProductBuildProfile',
    'getGameExportCoordinator', code)(module,
    callback => { const id = ++sequence; timers.set(id, callback); return id; }, id => timers.delete(id),
    () => 1000, () => {}, () => new Promise((resolve, reject) => requests.push({resolve, reject})),
    {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)},
    () => ({isReady: () => false}), {owns: () => false, forget() {}},
    {isStore:()=>false},{currentVersionCode:()=>1,currentVersionName:()=> '1.0.5',hasCachedUpdate:()=>false},{product:'default'},
    () => exportCoordinator);
  const page = new module.exports();
  Object.assign(page, {launcherWorkVisible_: false, launcherWorkForeground_: false, tasksProjectionDirty_: false,
    // 本组测试模拟已经完成开屏的首页。显式提供真实生命周期前提，不能让新增初始化
    // guard 提前返回，导致下面的网络/订阅断言没有执行原先需要核验的生产分支。
    launcherInitialized_: true, launcherInitializationComplete_: true, startupFinished_: true,
    startupAlive_: true, startupInitialPageShow_: false, versionScanEpoch_: 0,
    errorSheetWaitTimer_: -1, errorSheetWait_: null, errorSheetWaitTask_: null,
    // 真实refresh先挂共用内存订阅，default随后在store guard返回；生命周期负责解除它。
    storeCheckGeneration_: 0, storeCheckSignature_: '', storeExportUnsubscribe_: null,
    // 本测试只隔离网络可见性；App通道的真实策略/请求代次另有专用行为回归。
    shownAppUpdateChannel:'stable',prefManager_:{appUpdateChannel:'stable',appUpdateLatestSeen:()=>0,appUpdateLatestName:()=>''},
    tasksRev: 0, netBannerVisible: false, netBannerText: 'original', netRecheckTimer: -1, netCheckBusy_: false,
    netCheckEpoch_: 0, netInitialCheckPending_: false, recoveryPresentationEpoch_: 0, launcherStartupAttempt_: 0,
    launcherWindow_: null, rootViewportUpdateTimer_: -1, registry: {removeListener() {}},
    syncStatusFromRegistry_() { businessCalls++; }});
  // 生命周期照常执行；本测试不替代这些业务服务自己的生产回归。
  for (const name of ['onSideloadTestRequest_', 'onHomeTabVisibilityChanged_', 'consumeLastSession',
    'onUpdateRecoveryRequested_', 'scanVersions', 'loadPreferences', 'updateJdkReadyState',
    'refreshRecentActivities_', 'tryConsumeLayoutImport', 'onGraphicsRecoverySignal_', 'drainUpdateDialogs_',
    'showUpdateRecovery_', 'exitUpdateForRoute_', 'closeUpdateDialog_',
    // 返回首页补消费通知是独立业务边界；其呈现回执由恢复专项验证，本组仍执行真实
    // onPageShow 可见性/订阅/网络分支，不把这些新通知当作虚构的网络成功。
    'onOpenErrorSheetReq', 'onPendingToast', 'onOpenNetDiagReq', 'onDesktopLaunchError', 'onGameLayoutSyncNotice']) page[name] = () => {};
  page.refreshRecentActivities_ = () => { historyRefreshCalls++; };
  return {page, timers, requests, exportListeners, exportState,
    businessCalls: () => businessCalls, historyRefreshCalls: () => historyRefreshCalls,
    emitExport(task) { exportState.task = task; for (const listener of [...exportListeners]) listener(); }};
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('真实页面/Ability可见性共同控制复检，隐藏事件保留业务且返回只投影一次', () => {
  const f = fixture(), p = f.page;
  p.netBannerVisible = true; p.onNetBannerChange(); assert.equal(f.timers.size, 0);
  p.onPageShow(); assert.equal(f.timers.size, 0, '仅显示页面不能替代Ability前台');
  assert.equal(f.exportListeners.size, 1, 'default显示页也取得共用导出内存订阅');
  p.refreshStoreManager_(); assert.equal(f.exportState.subscriptions, 1, '重复刷新不能新增订阅');
  const historyBeforeProgress = f.historyRefreshCalls();
  for (let index = 0; index < 8; index++) f.emitExport({ state: 'running' });
  assert.equal(f.historyRefreshCalls(), historyBeforeProgress, '导出字节进度不请求最近活动投影');
  f.emitExport({ state: 'succeeded' });
  assert.equal(f.historyRefreshCalls(), historyBeforeProgress + 1, '真实observer在终态请求活动投影');
  p.launcherWorkForeground_ = true; p.onLauncherWorkVisibilityChanged_(); assert.equal(f.timers.size, 1);
  p.registryListener(); assert.equal(p.tasksRev, 1);
  p.onPageHide(); assert.equal(f.timers.size, 0);
  assert.equal(f.exportListeners.size, 0); assert.equal(p.storeExportUnsubscribe_, null);
  const historyWhenHidden = f.historyRefreshCalls(); f.emitExport({ state: 'cancelled' });
  assert.equal(f.historyRefreshCalls(), historyWhenHidden, '隐藏页已解除导出观察，不接收迟到终态');
  for (let i = 0; i < 100; i++) p.registryListener();
  assert.equal(p.tasksRev, 1); assert.equal(f.businessCalls(), 101, '不能以停止UI投影吞掉封账/安装结果');
  p.onNetBannerChange(); assert.equal(f.timers.size, 0);
  p.onPageShow(); assert.equal(p.tasksRev, 2); assert.equal(f.timers.size, 1);
  assert.equal(f.exportListeners.size, 1); assert.equal(f.exportState.subscriptions, 2, '返回只注册新的单一订阅');
  p.onLauncherWorkVisibilityChanged_(); assert.equal(p.tasksRev, 2);
  p.launcherWorkForeground_ = false; p.onLauncherWorkVisibilityChanged_(); assert.equal(f.timers.size, 0);
  p.launcherWorkForeground_ = true; p.onLauncherWorkVisibilityChanged_(); assert.equal(f.timers.size, 1);
  p.aboutToDisappear(); assert.equal(f.timers.size, 0); assert.equal(p.launcherWorkVisible_, false);
  assert.equal(f.exportListeners.size, 0); assert.equal(f.exportState.unsubscriptions, 2);
  assert.equal(f.exportState.sourceInspections, 0, '全程default不盘点store源');
});

test('慢网络请求不重叠，离页后旧成功不能隐藏当前横幅', async () => {
  const f = fixture(), p = f.page;
  p.launcherWorkForeground_ = true; p.netBannerVisible = true; p.onPageShow();
  const tick = [...f.timers.values()][0]; tick(); tick(); assert.equal(f.requests.length, 1);
  p.onPageHide(); p.onPageShow();
  [...f.timers.values()][0](); assert.equal(f.requests.length, 1, '返回期间旧请求尚未结束仍不可重叠');
  f.requests[0].resolve(true); await settle(); assert.equal(p.netBannerVisible, true);
  [...f.timers.values()][0](); assert.equal(f.requests.length, 2);
  f.requests[1].resolve(true); await settle(); assert.equal(p.netBannerVisible, false);
  p.onNetBannerChange(); assert.equal(f.timers.size, 0);
  p.aboutToDisappear(); assert.equal(f.exportListeners.size, 0);
});

test('冷检查等可见后执行；失效的初次结果在返回后重试，异常不循环重试', async () => {
  const f = fixture(), p = f.page;
  p.initNetworkCheck(); assert.equal(f.requests.length, 0);
  p.launcherWorkForeground_ = true; p.onPageShow(); assert.equal(f.requests.length, 1);
  p.onPageHide(); f.requests[0].resolve(false); await settle();
  assert.equal(p.netBannerVisible, false); assert.equal(p.netBannerText, 'original');
  p.onPageShow(); assert.equal(f.requests.length, 2);
  f.requests[1].reject(new Error('offline')); await settle();
  assert.equal(f.requests.length, 2); assert.equal(p.netCheckBusy_, false);
  p.aboutToDisappear(); assert.equal(f.exportListeners.size, 0);
});

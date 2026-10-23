/** 执行首页真实纯投影，覆盖新装、多版本、写入撤销与导出重入，不用源码字符串代替行为。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';
const file = path.resolve(import.meta.dirname, '../entry/src/main/ets/components/StoreManagerUiPolicy.ets');
const compiled = compiler.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;
const production = {};
new Function('exports', compiled)(production);
const baseline = { checking: false, currentReady: false, otherReady: false, hasCandidates: false,
  busy: false, failed: false, exporting: false };
const cases = [
  ['新装', {}, 'download'],
  ['扫描期间', { checking: true }, 'checking'],
  ['未核验候选', { hasCandidates: true }, 'check'],
  ['缺失明确', { hasCandidates: true, failed: true }, 'repair'],
  ['当前完整', { hasCandidates: true, currentReady: true }, 'export'],
  ['其余候选还在检查不妨碍当前导出', { checking: true, currentReady: true }, 'export'],
  ['其他完整优先于当前损坏', { otherReady: true, failed: true }, 'choose'],
  ['写入撤销旧绿色结果', { busy: true, currentReady: true, otherReady: true }, 'downloads'],
  ['下载未完成', { hasCandidates: true, busy: true }, 'downloads'],
  ['任务重入优先', { exporting: true, busy: true, checking: true }, 'progress'],
];
for (const [name, input, expected] of cases) {
  const actual = production.storeManagerAction({ ...baseline, ...input });
  assert.equal(actual, expected, name);
  assert(production.storeManagerActionLabel(actual).length > 0, name + ': visible label');
}
console.log('PASS store manager UI: ' + cases.length + ' production action scenarios');

// 执行Index的真实恢复续体；模拟等旧child退出时用户关闭再开启，不能用新token复活旧恢复。
const indexSource = fs.readFileSync(path.resolve(import.meta.dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const match = /^  private async recoverGraphics_\(/m.exec(indexSource);
assert(match);
const parsed = compiler.createSourceFile('page.ts', 'class Page {\n' + indexSource.slice(match.index), compiler.ScriptTarget.Latest, true, compiler.ScriptKind.TS);
const method = parsed.statements.find(compiler.isClassDeclaration).members[0].getText(parsed);
const recoveryJs = compiler.transpileModule('class Page {\n' + method + '\n}\nexports.Page=Page;', {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;
for (const revokeDuringWait of [false, true]) {
  const state = { token: 'original', waiting: revokeDuringWait, captured: 0, claims: 0, launched: 0 };
  const exported = {};
  vm.runInNewContext(recoveryJs, {
    exports: exported, Date,
    GameRunAdmission: {
      isAllowed: () => true,
      assertToken(_context, token) { assert.equal(token, state.token, '旧恢复必须持有原用户token'); },
      capture() { state.captured++; return state.token; },
    },
    GraphicsRecoveryStore: { ticket: () => ({ gameDir: '/mc/v', jdk: '17', xmx: 1024, rootActivityId: 1, activityId: 1 }),
      failure: () => ({ childPid: 2, profile: 'old', nextProfile: 'safe' }), claim: () => { state.claims++; return true; } },
    GraphicsHistoryStore: { outcome: () => undefined },
    testNapi: { desktopGameProcessState: () => state.waiting ? 1 : 0, desktopProcessAlive: () => state.waiting ? 1 : 0, desktopProcessId: () => 1 },
    graphicsRecoveryPermitted: () => true,
    DesktopLaunchSnapshot: { discard() {} },
    AppLogger: { warn() {}, info() {} }, TAG: 'Index', LOG_DOMAIN_LAUNCH: 1,
    setTimeout(callback) { state.waiting = false; state.token = 'reopened'; callback(); },
  });
  const page = new exported.Page();
  Object.assign(page, { context: { filesDir: '/app' }, pendingRunAdmission_: 'original', pendingGraphicsRecoveryId_: 'ticket',
    graphicsRecoveryPolling_: false, mcVersion: 'v', pendingDesktopSnapshot: 'snapshot',
    mcRoot: () => '/mc', graphicsPreferenceStamp_: () => 'stamp', safeToast_() {},
    async performLaunch(_retry, token) { assert.equal(token, 'original'); state.launched++; } });
  if (revokeDuringWait) await assert.rejects(page.recoverGraphics_(), /旧恢复必须持有原用户token/);
  else await page.recoverGraphics_();
  assert.equal(state.captured, 0, '恢复不得重新capture');
  assert.equal(state.launched, revokeDuringWait ? 0 : 1);
  assert.equal(state.claims, revokeDuringWait ? 0 : 1);
  assert.equal(page.graphicsRecoveryPolling_, false);
}
console.log('PASS store graphics recovery: original admission survives only without revoke/reopen');

// 首页只取得支撑当前行动的最小证据，不在首个就绪后继续哈希其它实例。
const readinessMatch = /^  private async checkStoreVersions_\(/m.exec(indexSource);
assert(readinessMatch);
const readinessParsed = compiler.createSourceFile('page.ts', 'class Page {\n' + indexSource.slice(readinessMatch.index), compiler.ScriptTarget.Latest, true, compiler.ScriptKind.TS);
const readinessMethod = readinessParsed.statements.find(compiler.isClassDeclaration).members[0].getText(readinessParsed);
const readinessJs = compiler.transpileModule('class Page {\n' + readinessMethod + '\n}\nexports.Page=Page;', {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;
for (const currentReady of [true, false]) {
  const calls = [], exported = {};
  vm.runInNewContext(readinessJs, { exports: exported, storeManagerAction: production.storeManagerAction,
    getGameExportCoordinator: () => ({
      async inspectSource(_root, versionId) { calls.push(versionId); return { request: { versionId } }; },
      async checkPlan(request, retainPreview) {
        assert.equal(retainPreview, false, '后台资格检查不持有或清除向导预览');
        return { issues: request.versionId === 'selected' && !currentReady ?
          [{ code: 'SOURCE_FILE_INVALID', severity: 'error', message: 'missing' }] : [] };
      },
    }),
  });
  const page = new exported.Page();
  Object.assign(page, { storeCheckGeneration_: 1, versionIsolation: true, mcVersion: 'selected', mcRoot: () => '/mc' });
  await page.checkStoreVersions_('/mc', 'selected', ['selected', 'ready', 'never-hash'], 1);
  assert.deepEqual(calls, currentReady ? ['selected'] : ['selected', 'ready']);
  assert.equal(page.storeManagerAction_, currentReady ? 'export' : 'choose');
}
console.log('PASS store source readiness: stops at current or first other ready instance');

// 执行实际事件接线与处理方法，不能只测试一个无人调用的新helper。
const indexAst = compiler.createSourceFile('Index.ets', indexSource, compiler.ScriptTarget.Latest, true);
const indexComponent = indexAst.statements.find(node => node.members?.some(member => member.name?.getText(indexAst) === 'refreshStoreManager_'));
const eventNames = ['onResourcesChanged', 'onSelectVersion', 'onVersionIsolationChange'];
const events = [];
function collectEvents(node) {
  if (compiler.isPropertyAssignment(node) && eventNames.includes(node.name?.getText(indexAst))
    && compiler.isArrowFunction(node.initializer)) events.push({ name: node.name.getText(indexAst), body: node.initializer.getText(indexAst) });
  compiler.forEachChild(node, collectEvents);
}
collectEvents(indexComponent);
assert.equal(events.filter(event => event.name === 'onResourcesChanged').length, 1);
assert.equal(events.filter(event => event.name === 'onSelectVersion').length, 2, '首页与版本Sheet均使用实际接线');
assert.equal(events.filter(event => event.name === 'onVersionIsolationChange').length, 1);
const sourceMethods = ['forceStoreSourceRecheck_', 'onVersionFilesChanged_', 'selectManagedVersion_',
  'changeManagedIsolation_', 'observeExportActivities_', 'refreshStoreManager_', 'checkStoreVersions_'].map(name => {
  const member = indexComponent.members.find(value => value.name?.getText(indexAst) === name);
  assert(member, name); return member.getText(indexAst);
});
const callbackMethods = events.map((event, index) => `invokeEvent${index}(value: Object): void { const callback = ${event.body}; callback(value); }`);
const eventJs = compiler.transpileModule('class Page {\n' + sourceMethods.concat(callbackMethods).join('\n') + '\n}\nexports.Page=Page;', {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;
const settleSource = async () => { for (let index = 0; index < 12; index++) await Promise.resolve(); };
function sourceChangeFixture(store = true) {
  const reads = [], plans = [], exported = {}, observations = { stats: 0, preferences: 0, root: '/mc' };
  vm.runInNewContext(eventJs, { exports: exported, storeManagerAction: production.storeManagerAction,
    DistributionPolicy: { isStore: () => store }, isTerminalState: () => true,
    testNapi: { mcIsRunning: () => false, desktopGameProcessState: () => 0 },
    // 回调只能刷新投影与已有统计。若新增直接文件I/O，本fixture拒绝而不写任何游戏资料。
    fs: new Proxy({}, { get() { assert.fail('source-change callback must not perform source filesystem I/O'); } }),
    getGameExportCoordinator: () => ({ getTask: () => null,
      async inspectSource(root, versionId, isolation) {
        reads.push({ root, versionId, isolation }); return { request: { root, versionId, isolation } };
      },
      checkPlan(request, retainPreview) {
        assert.equal(retainPreview, false);
        return new Promise(resolve => plans.push({ request, resolve }));
      },
    }),
  });
  const page = new exported.Page();
  Object.assign(page, { launcherWorkVisible_: true, storeExportUnsubscribe_: () => {}, storeCheckGeneration_: 20,
    storeCheckSignature_: '/mc\nselected\ntrue\nselected\n', storeReadyVersions_: ['selected'],
    storeManagerAction_: 'export', storeScanError_: '', mcVersion: 'selected', versionIsolation: true,
    availableVersions: ['selected'], orphanVersionDirs: [], context: { filesDir: '/app' },
    registry: { listAll: () => [] }, mcRoot: () => observations.root,
    scanInstalledModsCount() { observations.stats++; }, savePreferences() { observations.preferences++; },
  });
  return { page, reads, plans, observations };
}
const resourceEvent = events.findIndex(event => event.name === 'onResourcesChanged');
for (const wasReady of [true, false]) {
  const f = sourceChangeFixture();
  if (!wasReady) { f.page.storeReadyVersions_ = []; f.page.storeManagerAction_ = 'repair'; }
  f.page[`invokeEvent${resourceEvent}`]();
  assert.equal(f.observations.stats, 1, '原模组统计恰好刷新一次');
  assert.equal(f.page.storeCheckGeneration_, 21, '版本ID未变也创建新核验代次');
  assert.equal(f.page.storeReadyVersions_.length, 0, '撤销旧ready');
  assert.equal(f.page.storeManagerAction_, 'checking');
  assert.deepEqual(f.page.availableVersions, ['selected'], '没有重复扫描或改写版本库存');
  await settleSource(); assert.equal(f.plans.length, 1);
  f.plans[0].resolve({ issues: wasReady ? [{ code: 'SOURCE_FILE_INVALID', severity: 'error', message: '文件已删除' }] : [] });
  await settleSource(); assert.equal(f.page.storeManagerAction_, wasReady ? 'repair' : 'export');
  assert.equal(f.observations.preferences, 0, '文件变动回调不写源或偏好');
}
for (let eventIndex = 0; eventIndex < events.length; eventIndex++) {
  const event = events[eventIndex];
  const f = sourceChangeFixture();
  if (event.name === 'onSelectVersion') f.page.availableVersions.push('other');
  f.page.refreshStoreManager_(true); await settleSource();
  assert.equal(f.plans.length, 1);
  if (event.name === 'onSelectVersion') f.page[`invokeEvent${eventIndex}`]('other');
  else if (event.name === 'onVersionIsolationChange') f.page[`invokeEvent${eventIndex}`](false);
  else { f.observations.root = '/moved'; f.page[`invokeEvent${eventIndex}`](); }
  await settleSource(); assert.equal(f.plans.length, 2);
  f.plans[0].resolve({ issues: [] }); await settleSource();
  assert.equal(f.page.storeManagerAction_, 'checking', event.name + ':旧root/version/isolation结果不能复活ready');
  assert.equal(f.page.storeReadyVersions_.length, 0);
  f.plans[1].resolve({ issues: [] }); await settleSource();
  assert.equal(f.page.storeManagerAction_, 'export');
  assert.equal(f.plans[1].request.root, f.observations.root);
  assert.equal(f.plans[1].request.versionId, f.page.mcVersion);
  assert.equal(f.plans[1].request.isolation, f.page.versionIsolation);
  const normal = sourceChangeFixture(false);
  normal.page[`invokeEvent${eventIndex}`](event.name === 'onVersionIsolationChange' ? false : 'other');
  await settleSource(); assert.equal(normal.reads.length, 0, 'default不引入导出源扫描');
  assert.equal(normal.page.storeCheckGeneration_, 20, 'default不改变store核验状态');
}
{
  const hidden = sourceChangeFixture(); hidden.page.launcherWorkVisible_ = false;
  hidden.page[`invokeEvent${resourceEvent}`](); await settleSource();
  assert.equal(hidden.page.storeCheckGeneration_, 21, '隐藏页仍撤销旧异步代次');
  assert.equal(hidden.page.storeReadyVersions_.length, 0);
  assert.equal(hidden.page.storeCheckSignature_, '');
  assert.equal(hidden.reads.length, 0, '隐藏页文件变动只失效，不启动额外盘点');
}
console.log('PASS store source changes: unchanged IDs revoke cache; real file/version/isolation callbacks reject late inputs without source writes or default scans');

/**
 * 执行真实Index的导出订阅/终态LRU投影/隐藏生命周期。只替换协调器内存端口及已耐久
 * 历史读取边界，不用假refreshRecentActivities或空refreshStoreManager掩盖接线缺失。
 */
const activityMethodNames = ['observeExportActivities_', 'refreshStoreManager_', 'checkStoreVersions_',
  'refreshRecentActivities_', 'finishErrorSheetWait_', 'onPageHide'];
const activityMethods = activityMethodNames.map(name => {
  const member = indexComponent.members.find(value => value.name?.getText(indexAst) === name);
  assert(member?.body, name); return member.getText(indexAst);
});
const activityJs = compiler.transpileModule('class Page {\n' + activityMethods.join('\n') + '\n}\nexports.Page=Page;', {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;
function exportActivityFixture(store) {
  const listeners = new Set(), exported = {};
  const state = { task: { id: 'export-1', state: 'running', stage: '打包' }, persisted: [], reads: 0,
    readsDuringActiveProgress: 0, inspected: [], subscriptions: 0, unsubscriptions: 0 };
  const coordinator = {
    getTask: () => state.task,
    subscribe(callback) { listeners.add(callback); state.subscriptions++; return () => { listeners.delete(callback); state.unsubscriptions++; }; },
    async inspectSource(root, versionId, isolation) {
      state.inspected.push({ root, versionId, isolation }); return { request: { versionId } };
    },
    async checkPlan(_request, retainPreview) { assert.equal(retainPreview, false); return { issues: [] }; },
  };
  vm.runInNewContext(activityJs, { exports: exported, DistributionPolicy: { isStore: () => store },
    getGameExportCoordinator: () => coordinator, storeManagerAction: production.storeManagerAction, isTerminalState: () => true,
    testNapi: { mcIsRunning: () => false, desktopGameProcessState: () => 0 },
    getDownloadHistoryStore: () => ({ async waitReady() {
      if (state.task?.state === 'running' || state.task?.state === 'cancelling') state.readsDuringActiveProgress++;
    }, listStored() { state.reads++; return state.persisted.slice(); } }),
    AppStorage: { setOrCreate() {} }, setTimeout(callback) { callback(); }, clearTimeout,
    AppLogger: { warn() {} }, TAG: 'Index', LOG_DOMAIN_DOWNLOAD: 1,
  });
  const page = new exported.Page();
  Object.assign(page, { launcherWorkVisible_: true, storeExportUnsubscribe_: null, storeCheckGeneration_: 0,
    storeCheckSignature_: '', storeScanError_: '', storeReadyVersions_: [], mcVersion: 'selected', versionIsolation: true,
    availableVersions: ['selected'], orphanVersionDirs: [], context: { filesDir: '/app' },
    registry: { listAll: () => [] }, mcRoot: () => '/mc', recentActivities: [], recoveryPresentationEpoch_: 0,
    // 导出订阅只存在于已经初始化的首页。生产onPageHide会先收口Sheet等待，再判断首页是否挂载。
    // 同时执行AST提取的真实收口方法与生产初值，确保隐藏断言确实覆盖解除订阅分支。
    launcherInitialized_: true, errorSheetWaitTimer_: -1, errorSheetWait_: null, errorSheetWaitTask_: null,
    onLauncherWorkVisibilityChanged_() {}, exitUpdateForRoute_() {},
  });
  return { page, state, listeners, emit() { for (const callback of [...listeners]) callback(); } };
}
for (const store of [false, true]) {
  const f = exportActivityFixture(store);
  // 从原有管理刷新入口挂载，default guard必须在创建轻量订阅之后返回，而非绕过订阅。
  f.page.refreshStoreManager_(true); f.page.refreshStoreManager_();
  assert.equal(f.listeners.size, 1); assert.equal(f.state.subscriptions, 1, '重复刷新不新增监听');
  for (let index = 0; index < 8; index++) f.emit();
  await settleSource();
  assert.equal(f.state.reads, 0, '活动字节进度不能读取LRU');
  assert.equal(f.state.inspected.length, 0, '活动期间不能为首页盘点源');
  if (store) assert.equal(f.page.storeManagerAction_, 'progress', 'store原进行中行动保留');

  f.state.task = { id: 'export-1', state: 'succeeded', stage: '导出完成' };
  f.emit(); await settleSource();
  assert.equal(f.page.recentActivities.length, 0, '终态先发但活动尚未耐久提交');
  // 同一个终态在add成功后再次通知；不能按相同taskId/state去重而丢掉这次稳定刷新。
  f.state.persisted = [{ category: 'game_export', exportTaskId: 'export-1' }];
  f.emit(); await settleSource();
  assert.equal(f.page.recentActivities[0].exportTaskId, 'export-1');
  assert.equal(f.state.readsDuringActiveProgress, 0);
  assert.equal(f.state.inspected.length, store ? 1 : 0, 'default零源扫描；store稳定通知沿原签名缓存不重复扫描');
  if (store) assert.equal(f.page.storeManagerAction_, 'export', 'store原源就绪行动保留');

  const readBeforeHide = f.state.reads;
  f.page.onPageHide();
  assert.equal(f.page.launcherWorkVisible_, false); assert.equal(f.page.storeExportUnsubscribe_, null);
  assert.equal(f.listeners.size, 0); assert.equal(f.state.unsubscriptions, 1);
  f.emit(); await settleSource();
  assert.equal(f.state.reads, readBeforeHide, '隐藏后稳定通知不再访问首页历史');
}
console.log('PASS shared export activity projection: late durable LRU refresh, no byte reads/default scans, store cache preserved, hidden unsubscribe');

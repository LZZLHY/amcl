/** 执行版本/JDK真实退让宿主与父页接线，只隔离原生绘制和动画调度，不冒充真机布局验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const at = process.argv.indexOf('--output');
assert.ok(at >= 0, '必须显式指定外置结果目录');
const output = assertExternalOutputPath(process.argv[at + 1]);
fs.mkdirSync(output, { recursive: true });
const policy = makePureEtsLoader()('entry/src/main/ets/components/LayerRetreatPolicy.ets');
const deps = { './LayerRetreatPolicy': policy, './UiMotion': { UiMotion: { reduced: () => false } } };
const globals = { ScrollState: { Scroll: 1, Fling: 2 }, TouchType: { Down: 1, Up: 2, Cancel: 3 },
  Curve: { EaseOut: 'ease' } };
const methods = ['resetInteraction_', 'reset_', 'layers_', 'total_', 'inset_', 'preceding_', 'overlayHeight_', 'freeze_', 'enabled_',
  'indexOverflow_', 'index_', 'measure_', 'restoreAtStart_', 'frame_', 'animate_', 'touch_', 'didScroll_', 'stop_', 'aboutToDisappear'];
const Pane = loadActionComponent('entry/src/main/ets/components/DownloadAuxiliaryList.ets', 'DownloadAuxiliaryList', {
  methods, dependencies: deps, globals });
let nativeOffset = 300;
const finishes = [], groups = [];
const pane = new Pane();
Object.assign(pane, { active: true, alive_: true, blocked: false, hasResults: true, itemCount: 50,
  firstEnabled: true, secondEnabled: true, firstHeight_: 80, secondHeight_: 30,
  anchor_: -1, hidden_: 0, hitHeight_: 0, animating_: false, epoch_: 0, scrollable_: true,
  firstVisible_: -1, lastVisible_: -1, dragging_: false, returning_: false, policy_: new policy.LayerRetreatPolicy(),
  scroller_: { currentOffset: () => ({ xOffset: 0, yOffset: nativeOffset }) },
  getUIContext: () => ({ animateTo(options, update) { update(); finishes.push(options.onFinish); } }) });

// 同一持续手势的真实位移串接完整层，不修改正文收到的位移，也不插入滚动补偿。
pane.touch_({ type: 1 });
assert.deepEqual(pane.frame_(18, 1), { offsetRemain: 18 });
assert.equal(pane.hidden_, 30); assert.equal(pane.inset_(), 110);
assert.deepEqual(pane.frame_(36, 1), { offsetRemain: 36 });
assert.equal(pane.hidden_, 30); finishes.at(-1)(); assert.equal(pane.hidden_, 110);
finishes.at(-1)(); assert.equal(pane.hidden_, 110);
pane.frame_(-6, 1); assert.equal(pane.hidden_, 30);
pane.frame_(-6, 1); finishes.at(-1)(); assert.equal(pane.hidden_, 0);
assert.equal(pane.inset_(), 110);
groups.push('two-layer-continuation-reverse-and-pass-through');

// 回到真实起点时即使没有新frame也一次补全，首个从0向正文滚的帧不会取消收起。
pane.reset_(); pane.scrollable_ = true; nativeOffset = 0;
pane.touch_({ type: 1 }); pane.frame_(18, 1); assert.equal(pane.hidden_, 30);
assert.equal(pane.restoreAtStart_(), false);
pane.didScroll_(-5, 1); assert.equal(pane.hidden_, 0);
pane.hidden_ = 110; pane.returning_ = false; pane.dragging_ = false;
assert.equal(pane.restoreAtStart_(true), true); assert.equal(pane.hidden_, 0);
groups.push('true-top-complete-restore-without-new-frame');

// 身份/焦点/尺寸复位与卸载会废弃旧完成回调，缓存自然高继续可用。
nativeOffset = 300; pane.reset_(); pane.scrollable_ = true; pane.frame_(18, 1);
const obsolete = finishes.at(-1); pane.reset_(); obsolete();
assert.equal(pane.hidden_, 0); assert.equal(pane.animating_, false);
assert.equal(pane.firstHeight_, 80); assert.equal(pane.secondHeight_, 30);
pane.scrollable_ = true; pane.frame_(18, 1); pane.measure_(true, { height: 8 });
assert.equal(pane.firstHeight_, 80);
pane.aboutToDisappear(); finishes.at(-1)(); assert.equal(pane.alive_, false);
groups.push('stale-animation-and-natural-height-protection');

// JDK只有目录一层；即使缓存过另一个插槽高度，也不能多出一个退让端点。
pane.alive_ = true; pane.reset_(); pane.secondEnabled = false; pane.scrollable_ = true;
assert.deepEqual(pane.layers_(), [0, 80]); pane.frame_(18, 1); assert.equal(pane.hidden_, 80);
assert.equal(pane.overlayHeight_(), 0); assert.equal(pane.inset_(), 80);
pane.reset_(); pane.frame_(100, 1); assert.equal(pane.hidden_, 0, '短内容不能自动收起');
pane.scrollable_ = true; pane.active = false;
assert.deepEqual(pane.frame_(100, 1), { offsetRemain: 100 }); assert.equal(pane.hidden_, 0);
groups.push('jdk-single-layer-short-content-and-hidden-host');

// 可见性/焦点切换没有新index回调时，复用已核实几何仍能继续退让。
pane.active = true; pane.scrollable_ = true; pane.anchor_ = 80; pane.resetInteraction_();
assert.equal(pane.anchor_, 80); assert.equal(pane.scrollable_, true);
pane.frame_(18, 1); assert.equal(pane.hidden_, 80);
pane.blocked = true; pane.resetInteraction_(); pane.frame_(18, 1); assert.equal(pane.hidden_, 0);
pane.blocked = false; pane.resetInteraction_(); pane.frame_(18, 1); assert.equal(pane.hidden_, 80);
groups.push('visibility-and-focus-reset-retains-confirmed-scrollability');

// 新查询/视口重排后若可见索引保持一致，原生不会再通知；按当前条数重新使用最近事实。
pane.itemCount = 50; pane.index_(0, 10); pane.reset_();
assert.equal(pane.scrollable_, false); pane.frame_(18, 1); assert.equal(pane.hidden_, 80);
pane.reset_(); pane.itemCount = 3; pane.frame_(18, 1);
assert.equal(pane.hidden_, 0, '缓存索引越界时不能把新短目录当成长内容');
pane.itemCount = 50; pane.index_(0, 50); pane.reset_(); pane.frame_(18, 1);
assert.equal(pane.hidden_, 0, '最近范围覆盖全部目录时仍保持辅助层可见');
groups.push('identity-and-viewport-reset-recheck-cached-native-range');

// 运行真实DSL，核对固定视口/首项、全部回调接线与完全退场后的命中释放。
const ui = actionUiReceiver();
for (const name of ['List', 'ListItem']) ui.globals[name] = (...args) => ui.globals.Column(...args);
ui.globals.id = value => ui.globals.Column().id(value);
const layoutGlobals = { ...globals, ...ui.globals, EdgeEffect: { Spring: 'spring' },
  RenderFit: { TOP_LEFT: 'top-left' }, LayoutPolicy: { fixAtIdealSize: 'ideal' },
  HitTestMode: { None: 'none', Default: 'default', Block: 'block' } };
const RenderPane = loadActionComponent('entry/src/main/ets/components/DownloadAuxiliaryList.ets', 'DownloadAuxiliaryList', {
  methods: ['build', ...methods], render: true, dependencies: deps, globals: layoutGlobals });
const renderPane = new RenderPane();
Object.assign(renderPane, pane, { active: true, firstEnabled: true, secondEnabled: true,
  theme: {}, firstLayer: () => {}, secondLayer: () => {}, items: () => {}, empty: () => {},
  anchor_: 110, firstHeight_: 80, secondHeight_: 30, animating_: false, hidden_: 110,
  itemCount: 50, rowSpacing: 8, bottomInset: 90 });
renderPane.build();
const record = id => ui.records.find(row => row.modifiers.id?.[0] === id);
assert.equal(record('download-auxiliary-results').modifiers.height[0], '100%');
const insetRecord = record('download-auxiliary-inset');
assert.equal(insetRecord.modifiers.height?.[0] ?? insetRecord.args[0], 102);
assert.equal(record('download-auxiliary-overlay').modifiers.hitTestBehavior[0], 'none');
const list = record('download-auxiliary-results');
for (const event of ['onScrollFrameBegin', 'onTouch', 'onReachStart', 'onDidScroll', 'onScrollStop', 'onScrollIndex']) {
  assert.equal(typeof list.modifiers[event][0], 'function', event);
}
renderPane.hidden_ = 0; list.modifiers.onScrollIndex[0](0, 50); assert.equal(renderPane.scrollable_, false);
list.modifiers.onScrollIndex[0](0, 10); assert.equal(renderPane.scrollable_, true);
groups.push('real-builder-fixed-viewport-event-wiring-and-hit-release');

// 父页面真实Builder传入目录/查询身份和业务插槽；焦点与主Tab可见性均到达同一宿主。
const parentUi = actionUiReceiver(), calls = [], searchCalls = [];
parentUi.globals.TextInput = parentUi.globals.Text;
parentUi.globals.LazyForEach = (source, build, key) => {
  for (let i = 0; i < source.totalCount(); i++) {
    const value = source.getData(i);
    assert.ok(key(value)); build(value);
  }
};
for (const name of ['Blank', 'Scroll', 'LoadingProgress', 'ListItem']) parentUi.globals[name] = parentUi.globals.Column;
parentUi.globals.alignItems = (...args) => parentUi.globals.Column().alignItems(...args);
parentUi.globals.TextAlign = { Center: 'center' }; parentUi.globals.Color = { Transparent: 'transparent' };
parentUi.globals.ScrollDirection = { Horizontal: 'horizontal' }; parentUi.globals.BarState = { Off: 'off' };
const Tab = loadActionComponent('entry/src/main/ets/pages/tabs/DownloadTab.ets', 'DownloadTab', {
  methods: ['DlVersionTab', 'DlJdkTab', 'versionRetreatKey_', 'jdkRetreatKey_',
    'VersionFilters_', 'VersionItems_', 'VersionEmpty_', 'JdkCatalog_', 'JdkItems_', 'EmptyAuxiliary_'], render: true, globals: parentUi.globals,
  dependencies: { '../../components/VersionDownloadRows': makePureEtsLoader({
    '@kit.ArkUI': { FrameCallback: class {} },
  })('entry/src/main/ets/components/VersionDownloadRows.ets'),
    '../../components/DownloadAuxiliaryList': { DownloadAuxiliaryList(options) {
    calls.push(options); return parentUi.globals.Column();
  } }, '../../components/DownloadSearchField': { DownloadSearchField(options) {
    searchCalls.push(options); return parentUi.globals.Column();
  } } } });
const tab = new Tab();
Object.assign(tab, { theme: {}, hostVisible: true, dlSubTab: 0, versionSearch: '', versionSearchFocused_: false,
  filterRelease: true, filterSnapshot: false, filterOld: false, filterAprilFools: false,
  mcVersionList: [{ id: '1.21' }], versionRowCount_: 1, versionRows_: { totalCount: () => 1, getData: () => ({ id: '1.21' }) },
  mcVersionsLoading: false, mcVersionsError: '',
  versionActionEpoch_: 0, jdkActionEpoch_: 0, jdkVersions: [{ version: '17', stateText: '', available: true }, { version: '21', stateText: '', available: true }], jdkChannel: 'stable', jdkCatalogStatus: 'ready',
  jdkChecking: false, jdkImporting: false, jdkDownloadMsg: '', isJdkDownloading: () => false, getFilteredVersions: () => [{ id: '1.21' }], dlContentBottomPad: () => 90 });
tab.VersionItem = version => { assert.equal(version.id, '1.21'); };
// 版本页只显示筛选层，恢复区域不占用列表视口；JDK 仍独立使用目录层。
tab.DlVersionTab(); assert.equal(calls.at(-1).firstEnabled, false); assert.equal(calls.at(-1).secondEnabled, true);
const childReceiver = { unrelatedChildState: true };
// 按原生BuilderParam调用约定以子实例调用，箭头必须继续读取父页；不预bind方法掩盖错误。
for (const slot of ['firstLayer', 'secondLayer', 'items', 'empty']) calls.at(-1)[slot].call(childReceiver);
const oldKey = calls.at(-1).resetKey;
// 有可见版本时，后台校验和网络错误都不能把原滚动宿主换成空页，也不应重置阅读位置。
for (const stage of [{ mcVersionsLoading: true, mcVersionsError: '' }, { mcVersionsLoading: false, mcVersionsError: 'offline' }]) {
  Object.assign(tab, stage);
  tab.DlVersionTab();
  assert.equal(calls.at(-1).hasResults, true); assert.equal(calls.at(-1).blocked, false);
  assert.equal(calls.at(-1).resetKey, oldKey);
}
Object.assign(tab, { mcVersionsLoading: false, mcVersionsError: '' });
// 版本输入/清除即时更新本地查询，焦点继续阻塞原退让宿主；箭头闭包保留父页身份。
assert.equal(searchCalls.at(-1).controlId, 'version-browser-search');
assert.notEqual(searchCalls.at(-1).showFilterToggle, true);
searchCalls.at(-1).onTextChange.call(childReceiver, '26'); assert.equal(tab.versionSearch, '26');
searchCalls.at(-1).onInputFocus.call(childReceiver); assert.equal(tab.versionSearchFocused_, true);
searchCalls.at(-1).onInputBlur.call(childReceiver); assert.equal(tab.versionSearchFocused_, false);
searchCalls.at(-1).onClear.call(childReceiver); assert.equal(tab.versionSearch, '');

tab.versionSearch = '26'; tab.versionSearchFocused_ = true; tab.DlVersionTab();
assert.notEqual(calls.at(-1).resetKey, oldKey); assert.equal(calls.at(-1).blocked, true);
tab.hostVisible = false; tab.DlVersionTab(); assert.equal(calls.at(-1).active, false);
tab.hostVisible = true; tab.dlSubTab = 5; tab.DlJdkTab();
assert.equal(calls.at(-1).active, true); assert.equal(calls.at(-1).firstEnabled, true);
assert.equal(calls.at(-1).secondEnabled, false); assert.equal(calls.at(-1).itemCount, 3);
for (const slot of ['firstLayer', 'secondLayer', 'items', 'empty']) calls.at(-1)[slot].call(childReceiver);
groups.push('version-jdk-parent-state-focus-and-host-wiring');

// 页面本身负责展示旧清单、比较新行与丢弃过期回调。替身只控制清单服务的完成顺序和原生绘制。
const VersionPage = loadActionComponent('entry/src/main/ets/pages/tabs/DownloadTab.ets', 'DownloadTab', {
  methods: ['aboutToAppear', 'aboutToDisappear', 'onNavCommand', 'syncVersionVisibility_', 'loadVersionList',
    'applyVersionList_', 'sameVersionRow_'],
  dependencies: { '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
    '../../launcherskill/LauncherSkillBus': { LauncherSkillBus: { bind() {}, unbind() {} } } },
});
const sample = (id, date) => ({ id, type: 'release', url: 'https://example.invalid/' + id,
  releaseTime: date + 'T00:00:00Z', displayDate: date });
const older = sample('1.21.6', '2025-06-17'), current = sample('1.21.7', '2025-06-30');
const latest = sample('1.21.8', '2025-07-17');
const manifest = versions => ({ latest: { release: versions[0].id, snapshot: versions[0].id }, versions });
function pageSession(cache) {
  const page = new VersionPage(), pending = [], paints = [];
  Object.assign(page, { mcVersionList: [], mcVersionsLoading: false, mcVersionsError: '', versionSyncText_: '',
    hostVisible: true, dlSubTab: 0, navCommand: -1, consumedNavCommand_: -1,
    versionMounted_: false, versionVisible_: false, versionRequest_: 0,
    mcVersionService: {
      peekVersionList: () => cache,
      refreshVersionList: () => new Promise((resolve, reject) => pending.push({ resolve, reject })),
    },
    publishVersionRows_(rows, entering) { this.mcVersionList = rows; paints.push({ rows, entering }); },
    cancelVersionMotion_() {},
  });
  page.aboutToAppear();
  return { page, pending, paints, cache(next) { cache = next; } };
}
// pending 只提供服务返回值。等待当前微任务链落定后，断言真实页面最终状态。
const settle = () => new Promise(resolve => setImmediate(resolve));
const cached = manifest([current, older]);
const warm = pageSession(cached);
assert.equal(warm.pending.length, 1);
assert.deepEqual(warm.page.mcVersionList, cached.versions, '首次进入先展示旧清单，网络保持未完成');
const initialRows = warm.page.mcVersionList, initialPaints = warm.paints.length;
warm.page.syncVersionVisibility_();
assert.equal(warm.pending.length, 1, '相同可见状态的 Watch 与挂载回调应合并');
warm.pending[0].resolve(structuredClone(cached));
await settle();
assert.strictEqual(warm.page.mcVersionList, initialRows, '清单相同应保留列表实例');
assert.equal(warm.paints.length, initialPaints, '静默校验结果不能重播旧行');
assert.equal(warm.page.mcVersionsLoading, false);
assert.equal(warm.page.versionSyncText_, '已同步');
groups.push('visible-entry-renders-cache-while-checking-and-retains-unchanged-array');

warm.page.dlSubTab = 1; warm.page.syncVersionVisibility_();
warm.page.dlSubTab = 0; warm.page.syncVersionVisibility_();
assert.equal(warm.pending.length, 2, '返回已加载版本子页仍校验');
warm.page.hostVisible = false; warm.page.syncVersionVisibility_();
warm.page.hostVisible = true; warm.page.syncVersionVisibility_();
assert.equal(warm.pending.length, 3, '主 Tab 再次可见也发起校验');
warm.pending[2].resolve(manifest([latest, { ...current }, { ...older }]));
await settle();
const updated = warm.page.mcVersionList;
assert.deepEqual(updated.map(row => row.id), [latest.id, current.id, older.id]);
assert.strictEqual(updated[1], initialRows[0], '仅顶部增加版本时保留旧行身份');
assert.match(warm.page.versionSyncText_, /新增.*1/);
warm.pending[1].reject(new Error('obsolete-error'));
await settle();
assert.strictEqual(warm.page.mcVersionList, updated);
assert.equal(warm.page.mcVersionsError, '', '前次进入的迟到失败不能覆盖当前成功结果');
groups.push('reenter-subtab-and-main-tab-ignore-late-failure-and-prepend-only-new-entry');

warm.cache(manifest(updated));
const staleSuccess = warm.page.loadVersionList();
warm.page.hostVisible = false; warm.page.syncVersionVisibility_();
warm.page.hostVisible = true; warm.page.syncVersionVisibility_();
warm.pending.at(-1).reject(new Error('offline-now'));
await settle();
const readable = warm.page.mcVersionList;
assert.deepEqual(readable.map(row => row.id), [latest.id, current.id, older.id]);
assert.match(warm.page.mcVersionsError, /offline-now/);
warm.pending.at(-2).resolve(manifest([older]));
await staleSuccess;
assert.strictEqual(warm.page.mcVersionList, readable, '旧请求迟到成功也不能撤销当前缓存');
assert.match(warm.page.mcVersionsError, /offline-now/);
// 真实筛选栏仍能发起重试；保留读者已经看到的列表，直到服务给出新结果。
parentUi.clear(); warm.page.theme = {};
Tab.prototype.VersionFilters_.call(warm.page);
const retryCached = parentUi.records.find(row => row.type === 'Text' && row.args[0] === '重试');
assert.equal(retryCached.modifiers.enabled[0], true);
retryCached.modifiers.onClick[0]();
assert.strictEqual(warm.page.mcVersionList, readable);
warm.pending.at(-1).resolve(manifest(readable));
await settle();
assert.equal(warm.page.mcVersionsError, '');
groups.push('offline-with-cache-remains-readable-and-late-success-cannot-rollback');

// 清单同 ID 的字段会修订，来源许可也可能在请求途中改变。只保留仍然合法且内容相同的行。
const changed = pageSession(cached), revised = { ...current, url: current.url + '-revised' };
const oldObjects = changed.page.mcVersionList;
changed.pending[0].resolve(manifest([revised, { ...older }]));
await settle();
assert.equal(changed.page.mcVersionList[0].url, revised.url);
assert.notStrictEqual(changed.page.mcVersionList[0], oldObjects[0]);
assert.strictEqual(changed.page.mcVersionList[1], oldObjects[1]);
changed.cache(manifest(changed.page.mcVersionList));
const disallowed = changed.page.loadVersionList();
changed.cache(null);
changed.pending.at(-1).reject(new Error('source-changed'));
await disallowed;
assert.deepEqual(changed.page.mcVersionList, [], '刷新失败也必须移除现行来源已拒绝的旧清单');
groups.push('metadata-revision-and-source-revocation-during-refresh');

const cold = pageSession(null);
assert.equal(cold.pending.length, 1); assert.equal(cold.page.mcVersionList.length, 0);
assert.equal(cold.page.mcVersionsLoading, true);
cold.pending[0].reject(new Error('no-connection'));
await settle();
assert.equal(cold.page.mcVersionsLoading, false);
assert.match(cold.page.mcVersionsError, /no-connection/);
parentUi.clear(); cold.page.theme = {};
Tab.prototype.VersionEmpty_.call(cold.page);
const retryCold = parentUi.records.find(row => row.type === 'Button' && row.args[0] === '重试');
retryCold.modifiers.onClick[0]();
assert.equal(cold.pending.length, 2);
cold.pending[1].resolve(cached);
await settle();
assert.deepEqual(cold.page.mcVersionList, cached.versions);
assert.equal(cold.page.mcVersionsError, '');
groups.push('cold-entry-failure-and-retry-delivers-first-list');

const result = { status: 'passed', groups, limitations: ['宿主不证明ArkUI像素/命中几何或真机手感；SDK由组合候选另验。'] };
fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result));

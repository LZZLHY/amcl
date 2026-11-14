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
for (const name of ['Blank', 'Scroll', 'LoadingProgress', 'ListItem']) parentUi.globals[name] = parentUi.globals.Column;
parentUi.globals.alignItems = (...args) => parentUi.globals.Column().alignItems(...args);
parentUi.globals.ScrollDirection = { Horizontal: 'horizontal' }; parentUi.globals.BarState = { Off: 'off' };
const Tab = loadActionComponent('entry/src/main/ets/pages/tabs/DownloadTab.ets', 'DownloadTab', {
  methods: ['DlVersionTab', 'DlJdkTab', 'versionRetreatKey_', 'jdkRetreatKey_',
    'VersionFilters_', 'VersionItems_', 'VersionEmpty_', 'JdkCatalog_', 'JdkItems_', 'EmptyAuxiliary_'], render: true, globals: parentUi.globals,
  dependencies: { '../../components/DownloadAuxiliaryList': { DownloadAuxiliaryList(options) {
    calls.push(options); return parentUi.globals.Column();
  } }, '../../components/DownloadSearchField': { DownloadSearchField(options) {
    searchCalls.push(options); return parentUi.globals.Column();
  } } } });
const tab = new Tab();
Object.assign(tab, { theme: {}, hostVisible: true, dlSubTab: 0, versionSearch: '', versionSearchFocused_: false,
  filterRelease: true, filterSnapshot: false, filterOld: false, filterAprilFools: false,
  mcVersionList: [{ id: '1.21' }], mcVersionsLoading: false, mcVersionsError: '',
  versionActionEpoch_: 0, jdkActionEpoch_: 0, jdkVersions: [{ version: '17', stateText: '', available: true }, { version: '21', stateText: '', available: true }], jdkChannel: 'stable', jdkCatalogStatus: 'ready',
  jdkChecking: false, jdkImporting: false, jdkDownloadMsg: '', isJdkDownloading: () => false, getFilteredVersions: () => [{ id: '1.21' }], dlContentBottomPad: () => 90 });
tab.VersionItem = version => { assert.equal(version.id, '1.21'); };
// 版本页只显示筛选层，恢复区域不占用列表视口；JDK 仍独立使用目录层。
tab.DlVersionTab(); assert.equal(calls.at(-1).firstEnabled, false); assert.equal(calls.at(-1).secondEnabled, true);
const childReceiver = { unrelatedChildState: true };
// 按原生BuilderParam调用约定以子实例调用，箭头必须继续读取父页；不预bind方法掩盖错误。
for (const slot of ['firstLayer', 'secondLayer', 'items', 'empty']) calls.at(-1)[slot].call(childReceiver);
const oldKey = calls.at(-1).resetKey;
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

const result = { status: 'passed', groups, limitations: ['宿主不证明ArkUI像素/命中几何或真机手感；SDK由组合候选另验。'] };
fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result));

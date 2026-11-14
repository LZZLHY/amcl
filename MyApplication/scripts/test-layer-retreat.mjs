/** 整层退让的代码层检查，执行生产策略和页面回调，不模拟真机布局或手感。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';
const at = process.argv.indexOf('--output');
assert.ok(at >= 0, '需要显式外部输出目录');
const out = assertExternalOutputPath(process.argv[at + 1]); fs.mkdirSync(out, { recursive: true });
const file = 'entry/src/main/ets/components/LayerRetreatPolicy.ets';
const production = makePureEtsLoader()(file);
const { LayerRetreatPolicy, retreatLayerHeight, retreatLayerOffset, retreatStableInset,
  retreatLeadItemHeight, retreatNeedsTopRestore } = production;
const groups = [], heights = [30, 40, 80], policy = new LayerRetreatPolicy();

// 每段同向手势只触发一个端点，微反向不解锁；所有触发帧仍原量放行。
assert.deepEqual(policy.step(4, 0, heights, true, true), { hidden: 0, offsetRemain: 4 });
assert.deepEqual(policy.step(14, 0, heights, true, true), { hidden: 30, offsetRemain: 14 });
assert.equal(policy.step(500, 30, heights, true, true).hidden, 30);
assert.equal(policy.step(-2, 30, heights, true, true).hidden, 30);
assert.equal(policy.step(30, 30, heights, true, true).hidden, 30);
assert.equal(policy.step(-6, 30, heights, true, true).hidden, 0);
let hidden = 0;
for (const expected of [30, 70, 150]) {
  policy.reset(); const frame = policy.step(200, hidden, heights, true, true);
  assert.equal(frame.hidden, expected); assert.equal(frame.offsetRemain, 200); hidden = frame.hidden;
}
for (const expected of [70, 30, 0]) {
  policy.reset(); const frame = policy.step(-200, hidden, heights, true, true);
  assert.equal(frame.hidden, expected); assert.equal(frame.offsetRemain, -200); hidden = frame.hidden;
}
assert.equal(policy.step(50, 30, heights, false, true).hidden, 30);
assert.equal(policy.step(50, 30, heights, true, false).hidden, 30);
assert.equal(new LayerRetreatPolicy().step(18, 0, [0, NaN, -1, 40], true, true).hidden, 40);
groups.push('whole-layer-endpoints-latch-and-pass-through');

// 检查端点集合与完整内容平移关系，不复写生产决策算法。
let seed = 1729; hidden = 0; policy.reset();
for (let i = 0; i < 1000; i++) {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  const delta = (seed % 121) - 60;
  if (i % 17 === 0) policy.reset();
  const frame = policy.step(delta, hidden, heights, true, true);
  assert.equal(frame.offsetRemain, delta); assert.ok([0, 30, 70, 150].includes(frame.hidden)); hidden = frame.hidden;
  for (const [height, preceding] of [[30, 0], [40, 30], [80, 70]]) {
    assert.equal(retreatLayerHeight(height, hidden, preceding), height + retreatLayerOffset(height, hidden, preceding));
  }
}
groups.push('endpoint-property-and-rigid-translation');

// animateTo只隔离平台调度：执行真实状态闭包，保存完成回调以投递旧世代负例。
const finishes = [], context = { animateTo: (options, update) => { update(); finishes.push(options.onFinish); } };
const dependencies = { '../components/LayerRetreatPolicy': production,
  mods: { ResourceKind: { MOD: 'mod', RESOURCE_PACK: 'resourcepack', SHADER: 'shader', MODPACK: 'modpack' } },
  '../services/ModFileSave': { supportsCustomResourceSave: kind => ['mod', 'resourcepack', 'shader'].includes(kind) },
  '../components/UiMotion': { UiMotion: { reduced: () => false } } };
const globals = { ScrollState: { Scroll: 1, Fling: 2 }, Curve: { EaseOut: 'ease-out' },
  TouchType: { Down: 'down', Up: 'up', Cancel: 'cancel' } };
const Page = loadActionComponent('entry/src/main/ets/pages/ModBrowsePage.ets', 'ModBrowsePage', {
  methods: ['consumeRetreatFrame_', 'animateRetreatTo_', 'resetRetreat_', 'retreatTargetVisible_', 'measureRetreatHeight_',
    'filtersCollapsedForDisplay_', 'toggleBrowseFilters_', 'setHeaderCollapsed',
    'retreatListInset_', 'freezeRetreatAnchor_', 'retreatOverlayHeight_',
    'restoreRetreatAtStart_', 'observeRetreatPosition_', 'observeRetreatTouch_', 'observeRetreatStop_',
    'retreatLayers_', 'retreatInputEnabled_', 'retreatContentOverflows_', 'resetRetreatGeometry_', 'onRetreatHostVisible_',
    'usesCustomResourceSave_', 'currentBrowseKind_'], dependencies, globals });
const page = new Page();
Object.assign(page, { kindIdx_: 0, retreatPolicy_: new LayerRetreatPolicy(), retreatHidden_: 0,
  customSaveKindIndices_: [],
  retreatAnimating_: false, retreatAnimationEpoch_: 0, retreatTargetHeight_: 80,
  retreatAnchorInset_: -1, retreatHitHeight_: 0,
  retreatLoaderHeight_: 40, retreatSortHeight_: 30, retreatScrollable_: true,
  retreatSearchFocused_: false, showDetailSheet_: false, showVersionPicker_: false,
  headerCollapsed_: false, view_: { hits: [{}] } });
let nativeOffset = 100;
page.retreatScroller_ = { currentOffset: () => ({ xOffset: 0, yOffset: nativeOffset }) };
page.retreatHostActive_ = true; page.retreatReturning_ = false; page.retreatTouchActive_ = false;
page.hasValidCurrentVersion = () => true; page.getUIContext = () => context;
// 三类无有效实例时自动采用另存，仍保留同一个可退让目标层。整合包没有目标层。
page.hasValidCurrentVersion = () => false;
assert.deepEqual(page.retreatLayers_(), [30, 40, 80]);
page.retreatLoaderHeight_ = 0;
for (const kind of [1, 2]) { page.kindIdx_ = kind; assert.deepEqual(page.retreatLayers_(), [30, 0, 80]); }
page.kindIdx_ = 3; assert.deepEqual(page.retreatLayers_(), [30, 0]);
page.kindIdx_ = 0; page.retreatLoaderHeight_ = 40; page.hasValidCurrentVersion = () => true;
assert.equal(page.consumeRetreatFrame_(18, 1).offsetRemain, 18);
assert.equal(page.retreatHidden_, 30); assert.equal(page.retreatAnimating_, true);
page.consumeRetreatFrame_(-6, 1); assert.equal(page.retreatHidden_, 0);
page.measureRetreatHeight_(1, { height: 8 }); assert.equal(page.retreatLoaderHeight_, 40);
finishes[0](); assert.equal(page.retreatAnimating_, true, '旧动画不能解除新测量锁');
finishes[1](); assert.equal(page.retreatAnimating_, false);
page.measureRetreatHeight_(1, { height: 45 }); assert.equal(page.retreatLoaderHeight_, 45);
// 光影/资源包只有排序与目标，整合包没有目标；实际生产方法按层集合工作。
for (const kind of [1, 2, 3]) {
  page.kindIdx_ = kind; page.browseWidth_ = 400; page.resetRetreatGeometry_();
  page.retreatSortHeight_ = 30; page.retreatLoaderHeight_ = kind === 3 ? 40 : 0;
  page.retreatTargetHeight_ = kind === 3 ? 0 : 80;
  page.retreatGridScroller_ = { currentOffset: () => ({ yOffset: 1000 }) };
  page.retreatScrollable_ = true;
  assert.equal(page.consumeRetreatFrame_(80, 1).offsetRemain, 80);
  assert.equal(page.retreatHidden_, 30);
}
page.retreatTargetHeight_ = 80; page.retreatLoaderHeight_ = 40;
page.kindIdx_ = 0; page.resetRetreat_(); page.headerCollapsed_ = true;
page.consumeRetreatFrame_(18, 1); assert.equal(page.retreatHidden_, 80); assert.equal(page.headerCollapsed_, true);
groups.push('production-mod-animation-generation-and-scope');

// 不制造新的onScrollStart：一层结束后必须由新用户帧继续推进，不再被同向锁永久挡住。
page.resetRetreat_(); page.headerCollapsed_ = false; page.retreatLoaderHeight_ = 40; finishes.length = 0;
assert.equal(page.filtersCollapsedForDisplay_(), false);
for (const [index, expected] of [30, 70, 150].entries()) {
  page.consumeRetreatFrame_(18, 1); assert.equal(page.retreatHidden_, expected);
  assert.equal(page.filtersCollapsedForDisplay_(), index >= 1);
  page.consumeRetreatFrame_(500, 1); assert.equal(page.retreatHidden_, expected, '动画期间的距离不得提前推进下一层');
  const count = finishes.length; finishes.at(-1)();
  assert.equal(finishes.length, count, '完成回调不能自行补播下一层');
  page.consumeRetreatFrame_(500, 2); assert.equal(page.retreatHidden_, expected, '惯性帧不推进');
}
page.toggleBrowseFilters_();
assert.equal(page.retreatHidden_, 0); assert.equal(page.headerCollapsed_, false, '自动隐藏后展开不应变成手动关闭');
finishes.at(-1)();
page.toggleBrowseFilters_(); assert.equal(page.headerCollapsed_, true);
page.consumeRetreatFrame_(18, 1); finishes.at(-1)(); page.consumeRetreatFrame_(-6, 1);
assert.equal(page.headerCollapsed_, true, '反向恢复不打开用户手动关闭的筛选');
groups.push('continuous-layer-pacing-and-effective-filter-state');

// 实际运行搜索Builder，核对箭头、文案、颜色和点击事件共用同一有效状态。
const receiver = actionUiReceiver(), arrows = [];
receiver.globals.TextInput = receiver.globals.Text;
// 共享组件执行真实Builder，系统绘制仍隔离；箭头与输入事件通过真实父回调连接。
const searchGlobals = { ...receiver.globals, Color: { Transparent: 'transparent' } };
const SearchField = loadActionComponent('entry/src/main/ets/components/DownloadSearchField.ets', 'DownloadSearchField', {
  methods: ['build'], render: true, globals: searchGlobals,
  dependencies: { commons: { AppIconName: { Search: 'search', Close: 'close', ChevronUp: 'up', ChevronDown: 'down' } },
    './AppIcon': { AppIcon: receiver.globals.AppIcon },
    './AppRoundIconButton': { AppRoundIconButton: options => { arrows.push(options); return receiver.globals.Button(); } } },
});
const searchCalls = [];
function renderSearch(options) {
  searchCalls.push(options);
  const field = new SearchField();
  Object.assign(field, { text: '', showFilterToggle: false, filtersCollapsed: false }, options);
  field.build();
  return receiver.globals.Column();
}
const ButtonPage = loadActionComponent('entry/src/main/ets/pages/ModBrowsePage.ets', 'ModBrowsePage', {
  methods: ['SearchBox', 'filtersCollapsedForDisplay_', 'toggleBrowseFilters_', 'animateRetreatTo_',
    'resetRetreat_', 'setHeaderCollapsed', 'retreatListInset_', 'freezeRetreatAnchor_', 'retreatOverlayHeight_',
    'restoreRetreatAtStart_', 'retreatLayers_', 'retreatInputEnabled_', 'retreatContentOverflows_',
    'usesCustomResourceSave_', 'currentBrowseKind_'], render: true,
  globals: { ...receiver.globals, Color: { Transparent: 'transparent' }, Curve: { EaseOut: 'ease', FastOutSlowIn: 'ease' } },
  dependencies: { ...dependencies, commons: { AppIconName: { Search: 'search', ChevronUp: 'up', ChevronDown: 'down' } },
    '../components/AppIcon': { AppIcon: receiver.globals.AppIcon },
    '../components/DownloadSearchField': { DownloadSearchField: renderSearch } },
});
const buttonPage = new ButtonPage();
Object.assign(buttonPage, { kindIdx_: 0, queryInput_: '', headerCollapsed_: false, retreatHidden_: 70,
  customSaveKindIndices_: [],
  retreatSortHeight_: 30, retreatLoaderHeight_: 40, retreatPolicy_: new LayerRetreatPolicy(),
  retreatTargetHeight_: 80, retreatAnchorInset_: -1, retreatHitHeight_: 0,
  retreatAnimationEpoch_: 0, retreatAnimating_: false,
  retreatHostActive_: false,
  theme: { actionText: 'act', textSecondary: 'sec', primaryLight: 'pl', bgInput: 'input' } });
buttonPage.searchPlaceholder = () => '搜索模组'; buttonPage.getUIContext = () => context;
buttonPage.hasValidCurrentVersion = () => true;
buttonPage.SearchBox();
assert.equal(arrows.at(-1).name, 'down'); assert.equal(arrows.at(-1).accessibilityLabel, '展开筛选');
assert.equal(arrows.at(-1).color, 'sec'); assert.equal(arrows.at(-1).containerBg, 'input');
arrows.at(-1).onAction(); assert.equal(buttonPage.retreatHidden_, 0); assert.equal(buttonPage.headerCollapsed_, false);
buttonPage.SearchBox(); assert.equal(arrows.at(-1).name, 'up'); assert.equal(arrows.at(-1).accessibilityLabel, '收起筛选');
for (const kind of [1, 2, 3]) {
  buttonPage.kindIdx_ = kind; buttonPage.retreatHidden_ = 150; buttonPage.SearchBox();
  assert.equal(arrows.at(-1).name, 'down', '其他分类的箭头也跟随自动隐藏端点');
}
// 受控文本与焦点仍归资源页；onChange去抖一次，清除沿原入口立即提交一次查询。
let debounced = 0, appliedSearch = 0, immediateSearch = 0;
buttonPage.debouncedSearch = () => debounced++;
buttonPage.applyFiltersToController = () => appliedSearch++;
buttonPage.triggerSearch = first => { assert.equal(first, true); immediateSearch++; };
searchCalls.at(-1).onTextChange('sodium'); assert.equal(buttonPage.queryInput_, 'sodium'); assert.equal(debounced, 1);
searchCalls.at(-1).onInputFocus(); assert.equal(buttonPage.retreatSearchFocused_, true);
searchCalls.at(-1).onInputBlur(); assert.equal(buttonPage.retreatSearchFocused_, false);
receiver.records.length = 0; buttonPage.SearchBox();
const input = receiver.records.find(r => r.modifiers.id?.[0] === 'resource-browser-search');
assert.equal(input.args[0].text, 'sodium');
const clear = arrows.findLast(option => option.accessibilityLabel === '清除搜索');
assert.ok(clear); clear.onAction();
assert.equal(buttonPage.queryInput_, ''); assert.equal(appliedSearch, 1); assert.equal(immediateSearch, 1);
groups.push('production-search-arrow-display-and-click');

const Ledger = loadActionComponent('entry/src/main/ets/pages/DownloadHistoryPage.ets', 'DownloadHistoryPage', {
  methods: ['retreatScrollFrame_', 'animateRetreatTo_', 'resetRetreat_', 'retreatTotalHeight_', 'measureRetreatLayer_',
    'retreatListInset_', 'freezeRetreatAnchor_', 'retreatOverlayHeight_',
    'restoreRetreatAtStart_', 'observeRetreatPosition_', 'observeRetreatTouch_', 'observeRetreatStop_',
    'retreatInputEnabled_', 'retreatContentOverflows_'], dependencies, globals });
const ledger = new Ledger();
Object.assign(ledger, { retreatPolicy_: new LayerRetreatPolicy(), retreatHidden_: 0, retreatAnimating_: false,
  retreatAnimationEpoch_: 0, retreatFilterHeight_: 40, retreatOverviewHeight_: 70, retreatScrollable_: true,
  retreatAnchorInset_: -1, retreatHitHeight_: 0,
  retreatSearchFocused_: false, hostVisible: true, loaded: true, groups: [{}], refreshing: false,
  selectionBusy: false, showQuickShare: false, showStorage: false, readerFocused: false, viewportWidth: 1000 });
ledger.retreatScroller_ = { currentOffset: () => ({ xOffset: 0, yOffset: nativeOffset }) };
ledger.retreatReturning_ = false; ledger.retreatTouchActive_ = false;
ledger.getUIContext = () => context;
ledger.retreatScrollFrame_(18, 1); assert.equal(ledger.retreatHidden_, 40);
ledger.retreatScrollFrame_(-6, 1); assert.equal(ledger.retreatHidden_, 0);
ledger.measureRetreatLayer_(false, { height: 8 }); assert.equal(ledger.retreatOverviewHeight_, 70);
finishes.at(-1)(); ledger.retreatScrollFrame_(18, 1); finishes.at(-1)(); ledger.retreatScrollFrame_(18, 1);
assert.equal(ledger.retreatHidden_, 110, '账本也应在动画完成后接受同向新输入继续退让');
groups.push('production-ledger-whole-layer-and-measurement-lock');

// 内容坐标由固定视口+冻结首项-实际滚动组成，隐藏量不能进入该坐标式。
page.resetRetreat_(); page.headerCollapsed_ = false; page.retreatAnchorInset_ = -1;
page.retreatLoaderHeight_ = 40; page.freezeRetreatAnchor_();
assert.equal(page.retreatAnchorInset_, 150);
const itemY = 500, viewportY = 100, userScroll = 90;
const beforeY = viewportY + page.retreatListInset_() + itemY - userScroll;
for (const h of [0, 30, 70, 150, 70, 30, 0]) {
  page.retreatHidden_ = h;
  assert.equal(viewportY + page.retreatListInset_() + itemY - userScroll, beforeY);
}
page.headerCollapsed_ = true; assert.equal(page.retreatListInset_(), 150);
page.headerCollapsed_ = false; assert.equal(page.retreatListInset_(), 150);
assert.equal(retreatLeadItemHeight(retreatStableInset(150, 30), 8) + 8, 150);
ledger.resetRetreat_(true); ledger.freezeRetreatAnchor_();
assert.equal(ledger.retreatListInset_(), 110);
for (const h of [0, 40, 110, 40, 0]) {
  ledger.retreatHidden_ = h; assert.equal(ledger.retreatListInset_(), 110);
}
groups.push('frozen-content-anchor-through-hide-restore-and-manual-toggle');

// 执行真实结果Builder，核对固定List尺寸、内容首项与覆盖层命中，不模拟实际像素。
const viewUi = actionUiReceiver();
for (const name of ['List', 'ListItem', 'Grid', 'GridItem', 'Blank', 'Divider', 'Scroll', 'LoadingProgress']) {
  viewUi.globals[name] = viewUi.globals.Column;
}
viewUi.globals.LazyForEach = (data, build) => data.rows.forEach(build);
// SDK打印器可能把容器尾部属性打印为独立链；只接收属性声明，不模拟原生父子布局。
viewUi.globals.id = value => viewUi.globals.Column().id(value);
const viewGlobals = { ...viewUi.globals, BarState: { Auto: 'auto', Off: 'off' },
  // SDK打印器将Grid私有属性输出成独立链；只接收声明，不模拟原生网格布局。
  columnsTemplate: value => viewUi.globals.Column().columnsTemplate(value),
  TextAlign: { Center: 'center' },
  EdgeEffect: { Spring: 'spring' }, HitTestMode: { Default: 'default', Block: 'block', None: 'none' },
  LayoutPolicy: { fixAtIdealSize: 'ideal' } };
const viewDeps = { ...dependencies, mods: { describeSearchFailureForUser: () => 'error' },
  commons: { AppIconName: { History: 'history' }, activityClock: () => '' },
  '../components/ModCard': { ModCard: viewUi.globals.Column },
  '../components/ModpackCard': { ModpackCard: viewUi.globals.Column },
  '../components/AppIcon': { AppIcon: viewUi.globals.AppIcon },
  '../components/MotionSection': { MotionSection: viewUi.globals.Column },
  '../components/ActivityTimelineItem': { ActivityTimelineItem: viewUi.globals.Column } };
viewDeps['../components/ActivityUiModel'] = { activityClock: () => '', ActivityFilter: { ALL: 'all' } };
viewDeps.commons.floatingDockReserveHeight = () => 80;
viewDeps.commons.DeviceForm = { PHONE: 'phone' };
const ModView = loadActionComponent('entry/src/main/ets/pages/ModBrowsePage.ets', 'ModBrowsePage', {
  methods: ['BrowseResults_', 'retreatListInset_', 'retreatOverlayHeight_', 'ModpackResultsGrid',
    'modpackColumnCount_', 'modpackColumnsTemplate_'], render: true,
  dependencies: viewDeps, globals: viewGlobals });
const mv = new ModView();
Object.assign(mv, { kindIdx_: 0, headerCollapsed_: false, retreatAnchorInset_: 150, retreatAnimating_: false,
  retreatHitHeight_: 150, retreatTargetHeight_: 80, retreatSortHeight_: 30, retreatLoaderHeight_: 40,
  theme: {}, view_: { hits: [{ id: 'project', source: 'mr' }], loading: false, errorMessage: null, hasMore: false, totalHits: 1 } });
mv.RetreatTarget_ = () => {}; mv.ModRetreatFilters_ = () => {}; mv.EmptyBlock = () => {};
const record = id => viewUi.records.find(r => r.modifiers.id?.[0] === id);
const attribute = (id, name) => {
  const r = record(id);
  return r.modifiers[name]?.[0] ?? (r.type === 'detached-' + name ? r.args[0] : undefined);
};
for (const h of [0, 30, 70, 150, 70, 0]) {
  viewUi.records.length = 0; mv.retreatHidden_ = h; mv.BrowseResults_();
  assert.equal(record('resource-browser-results').modifiers.height[0], '100%');
  assert.equal(attribute('mod-retreat-content-inset', 'height'), 142);
  assert.equal(record('resource-browser-viewport').modifiers.layoutWeight[0], 1);
  assert.equal(record('mod-retreat-overlay').modifiers.hitTestBehavior[0], h === 150 ? 'none' : 'default');
}
mv.retreatAnimating_ = true; mv.retreatHidden_ = 150; viewUi.records.length = 0; mv.BrowseResults_();
assert.equal(record('mod-retreat-overlay').modifiers.hitTestBehavior[0], 'default');
assert.equal(record('mod-retreat-overlay').modifiers.height[0], 150);
mv.view_.hits = []; viewUi.records.length = 0; mv.BrowseResults_();
assert.equal(record('mod-empty-state-viewport').modifiers.height[0], '100%');
assert.equal(record('mod-empty-state-viewport').modifiers.padding[0].top, 150);

const LedgerView = loadActionComponent('entry/src/main/ets/pages/DownloadHistoryPage.ets', 'DownloadHistoryPage', {
  methods: ['RetreatLedgerResults_', 'retreatListInset_', 'retreatTotalHeight_', 'retreatOverlayHeight_'], render: true,
  dependencies: viewDeps, globals: viewGlobals });
const lv = new LedgerView();
Object.assign(lv, { groups: [{}], retreatAnchorInset_: 110, retreatAnimating_: false, retreatHitHeight_: 110,
  retreatFilterHeight_: 40, retreatOverviewHeight_: 70, theme: {},
  activityRows_: { rows: [{ key: 'date', header: true, groupLabel: '今天', groupCount: 1 }] } });
lv.RetreatOverview_ = () => {}; lv.RetreatFilters_ = () => {};
for (const h of [0, 40, 110, 40, 0]) {
  lv.retreatHidden_ = h; viewUi.records.length = 0; lv.RetreatLedgerResults_();
  assert.equal(record('activity-records-scroll').modifiers.height[0], '100%');
  assert.equal(attribute('activity-retreat-content-inset', 'height'), 102);
  assert.equal(record('activity-retreat-viewport').modifiers.layoutWeight[0], 1);
  assert.equal(record('activity-retreat-overlay').modifiers.hitTestBehavior[0], h === 110 ? 'none' : 'default');
}
groups.push('production-fixed-viewport-overlay-inset-and-empty-state');

// 回顶完整恢复独立于逐层阈值；首占位还露出一部分不等于真实offset到0。
assert.equal(retreatNeedsTopRestore(70, 0, true, false), true);
assert.equal(retreatNeedsTopRestore(70, -8, true, false), true);
assert.equal(retreatNeedsTopRestore(70, 12, true, false), false);
assert.equal(retreatNeedsTopRestore(70, 0, false, false), false, '新正向预计帧仍在0不能被当返顶');
assert.equal(retreatNeedsTopRestore(70, 0, false, true), true);
assert.equal(retreatNeedsTopRestore(0, 0, true, true), false);
assert.equal(retreatNeedsTopRestore(70, NaN, true, true), false);

page.kindIdx_ = 0; page.headerCollapsed_ = false; page.resetRetreat_();
page.retreatAnchorInset_ = 150; page.retreatHidden_ = 150; nativeOffset = 80;
page.consumeRetreatFrame_(-6, 1); assert.equal(page.retreatHidden_, 70);
const partialFinish = finishes.at(-1);
nativeOffset = 0;
assert.equal(page.restoreRetreatAtStart_(), true, '已到顶且无新Scroll帧时直接补全剩余Loader/排序');
assert.equal(page.retreatHidden_, 0); assert.equal(page.headerCollapsed_, false); assert.equal(page.retreatAnchorInset_, 150);
partialFinish(); assert.equal(page.retreatAnimating_, true, '旧逐层完成不能取消新的完整恢复');
finishes.at(-1)(); assert.equal(page.retreatAnimating_, false);
const completedCount = finishes.length;
assert.equal(page.restoreRetreatAtStart_(true), false); assert.equal(finishes.length, completedCount, '重复回弹幂等');

page.resetRetreat_(); nativeOffset = 0; page.observeRetreatTouch_({ type: 'down' });
page.consumeRetreatFrame_(18, 1); assert.equal(page.retreatHidden_, 30);
assert.equal(page.restoreRetreatAtStart_(true), false, '新正向触摸尚在顶部时旧stop不能重新展开');
finishes.at(-1)(); assert.equal(page.retreatHidden_, 30, '动画完成不能把从顶部开始的上滑抵消');
page.observeRetreatTouch_({ type: 'up' });
assert.equal(page.restoreRetreatAtStart_(true), true, '真正停止且仍在起点则完整恢复');

page.resetRetreat_(); page.retreatHidden_ = 70; nativeOffset = 0;
page.observeRetreatPosition_(-80, 2); assert.equal(page.retreatHidden_, 0, 'Fling/实际位移已回顶也应恢复');
page.resetRetreat_(); page.retreatHidden_ = 150; nativeOffset = 80;
page.consumeRetreatFrame_(-6, 1); const oldReturnFinish = finishes.at(-1);
nativeOffset = 0; page.observeRetreatTouch_({ type: 'down' }); page.consumeRetreatFrame_(18, 1);
const newTarget = page.retreatHidden_;
oldReturnFinish(); assert.equal(page.retreatHidden_, newTarget);
assert.equal(page.restoreRetreatAtStart_(), false, '新正向已撤销返顶意图');

page.resetRetreat_(); page.retreatHidden_ = 80; page.headerCollapsed_ = true; page.retreatReturning_ = true; nativeOffset = 0;
assert.equal(page.restoreRetreatAtStart_(), true); assert.equal(page.headerCollapsed_, true, '不打开用户手动关闭的筛选');
page.retreatHidden_ = 70; page.retreatReturning_ = true;
page.retreatScroller_ = { currentOffset: () => undefined };
assert.equal(page.restoreRetreatAtStart_(true), false, '未绑定不能默认0');
page.retreatScroller_ = { currentOffset: () => { throw new Error('not attached'); } };
assert.equal(page.restoreRetreatAtStart_(true), false);
page.retreatScroller_ = { currentOffset: () => ({ xOffset: 0, yOffset: 0 }) };
page.kindIdx_ = 1; assert.equal(page.restoreRetreatAtStart_(true), true);
page.retreatHidden_ = 30;
page.kindIdx_ = 0; page.retreatHostActive_ = false; assert.equal(page.restoreRetreatAtStart_(true), false);

ledger.resetRetreat_(); ledger.retreatHidden_ = 110; ledger.retreatReturning_ = true;
ledger.retreatAnchorInset_ = 110; ledger.overviewExpanded = true; nativeOffset = 0;
assert.equal(ledger.restoreRetreatAtStart_(), true); assert.equal(ledger.retreatHidden_, 0);
assert.equal(ledger.retreatAnchorInset_, 110); assert.equal(ledger.overviewExpanded, true);
groups.push('true-list-start-completes-automatic-restore-without-more-frames');

// 两个真实List都持续绑定同一控制器，并登记到顶、实际滚动和静止入口。
mv.view_.hits = [{ id: 'project', source: 'mr' }]; mv.retreatScroller_ = { marker: 'mod-list' };
mv.retreatAnimating_ = false; mv.retreatHidden_ = 70; viewUi.records.length = 0; mv.BrowseResults_();
assert.ok(viewUi.records.some(r => r.args[0]?.scroller === mv.retreatScroller_));
for (const name of ['onReachStart', 'onDidScroll', 'onScrollStop', 'onTouch']) {
  assert.equal(typeof record('resource-browser-results').modifiers[name][0], 'function');
}
lv.retreatScroller_ = { marker: 'ledger-list' }; lv.retreatHidden_ = 40; viewUi.records.length = 0; lv.RetreatLedgerResults_();
assert.ok(viewUi.records.some(r => r.args[0]?.scroller === lv.retreatScroller_));
for (const name of ['onReachStart', 'onDidScroll', 'onScrollStop', 'onTouch']) {
  assert.equal(typeof record('activity-records-scroll').modifiers[name][0], 'function');
}
groups.push('stable-controller-and-native-start-observation-wiring');

// 同一Down里的动画期输入不能丢掉：保持手指按下后，完成回调可逐层消费真实余额。
page.retreatHostActive_ = true; page.kindIdx_ = 0; page.headerCollapsed_ = false;
page.retreatScroller_ = { currentOffset: () => ({ xOffset: 0, yOffset: nativeOffset }) };
nativeOffset = 1000; page.resetRetreat_(); page.retreatAnchorInset_ = 150; finishes.length = 0;
page.observeRetreatTouch_({ type: 'down' });
page.consumeRetreatFrame_(18, 1); assert.equal(page.retreatHidden_, 30);
page.consumeRetreatFrame_(200, 1); assert.equal(page.retreatHidden_, 30, '动画期只计预算，不重启');
finishes[0](); assert.equal(page.retreatHidden_, 70);
finishes[1](); assert.equal(page.retreatHidden_, 150);
finishes[2](); assert.equal(finishes.length, 3); assert.equal(page.retreatAnimating_, false);
const reverseStart = finishes.length;
page.consumeRetreatFrame_(-30, 1); assert.equal(page.retreatHidden_, 70);
finishes[reverseStart](); assert.equal(page.retreatHidden_, 30);
finishes[reverseStart + 1](); assert.equal(page.retreatHidden_, 0);
finishes[reverseStart + 2](); assert.equal(finishes.length, reverseStart + 3);
assert.equal(page.retreatAnchorInset_, 150);

page.resetRetreat_(); page.observeRetreatTouch_({ type: 'down' }); finishes.length = 0;
page.consumeRetreatFrame_(18, 1); page.consumeRetreatFrame_(200, 1);
page.observeRetreatTouch_({ type: 'up' }); finishes[0]();
assert.equal(page.retreatHidden_, 30); assert.equal(finishes.length, 1);
assert.equal(page.retreatAnimating_, false); assert.equal(page.retreatHitHeight_, 0);
page.consumeRetreatFrame_(500, 2); assert.equal(finishes.length, 1, '松手后的惯性不续播');

page.resetRetreat_(); page.observeRetreatTouch_({ type: 'down' }); finishes.length = 0;
page.consumeRetreatFrame_(18, 1); page.consumeRetreatFrame_(200, 1);
page.consumeRetreatFrame_(-1, 1); finishes[0]();
assert.equal(page.retreatHidden_, 30); assert.equal(finishes.length, 1, '小反向也立即取消旧向预算');
page.consumeRetreatFrame_(-5, 1); assert.equal(page.retreatHidden_, 0);
finishes.at(-1)();

page.resetRetreat_(); page.observeRetreatTouch_({ type: 'down' }); finishes.length = 0;
page.consumeRetreatFrame_(18, 1); page.consumeRetreatFrame_(200, 1);
page.observeRetreatStop_(); finishes[0]();
assert.equal(page.retreatHidden_, 70, '活动触点期间旧stop不丢新预算');
page.observeRetreatTouch_({ type: 'cancel' }); finishes.at(-1)();
assert.equal(page.retreatAnimating_, false);

page.resetRetreat_(); page.observeRetreatTouch_({ type: 'down' }); finishes.length = 0;
page.consumeRetreatFrame_(200, 1); const queuedOldFinish = finishes[0];
nativeOffset = 0; page.consumeRetreatFrame_(-1, 1);
assert.equal(page.retreatHidden_, 0, '真到顶优先清队列并完整恢复');
queuedOldFinish(); finishes.at(-1)(); assert.equal(page.retreatHidden_, 0);
assert.equal(finishes.length, 2, '到顶恢复后不能继续旧向排队');

// 平台立即完成动画也必须有限推进，不能在同一端点无限递归。
nativeOffset = 1000; page.resetRetreat_(); page.observeRetreatTouch_({ type: 'down' });
let immediateCount = 0;
page.getUIContext = () => ({ animateTo: (options, update) => {
  assert.ok(++immediateCount <= 3); update(); options.onFinish();
} });
page.consumeRetreatFrame_(1e9, 1);
assert.equal(immediateCount, 3); assert.equal(page.retreatHidden_, 150); assert.equal(page.retreatAnimating_, false);
page.getUIContext = () => context;

ledger.resetRetreat_(); ledger.retreatScrollable_ = true; ledger.retreatAnchorInset_ = 110;
ledger.observeRetreatTouch_({ type: 'down' }); finishes.length = 0;
ledger.retreatScrollFrame_(100, 1); assert.equal(ledger.retreatHidden_, 40);
finishes[0](); assert.equal(ledger.retreatHidden_, 110);
finishes[1](); assert.equal(finishes.length, 2);
groups.push('same-gesture-queued-serial-hide-restore-up-cancel-top-and-immediate-finish');

const remainder = new LayerRetreatPolicy();
let remainderFrame = remainder.step(20, 0, heights, true, true);
assert.equal(remainderFrame.hidden, 30);
remainder.step(1000, 30, heights, true, false);
assert.equal(remainder.finishTransition(30, heights, true, true).hidden, 30, '惯性不增加不足一档的余额');
assert.equal(remainder.step(16, 30, heights, true, true).hidden, 70, '后续同向真实帧可补足余额');
groups.push('partial-input-budget-survives-transition-without-fling-credit');

// 推广后的类别差异：同几何切换不依赖新area通知，短内容与旧页面世代均不能推进。
page.getUIContext = () => context; page.kindIdx_ = 1; page.headerCollapsed_ = false;
page.retreatTargetHeight_ = 80; page.retreatLoaderHeight_ = 40; page.retreatSortHeight_ = 30;
page.retreatHostActive_ = true; page.resetRetreatGeometry_();
assert.equal(page.retreatLoaderHeight_, 0); assert.equal(page.retreatTargetHeight_, 80);
assert.equal(page.retreatSortHeight_, 30); page.freezeRetreatAnchor_();
assert.equal(page.retreatAnchorInset_, 110);
page.kindIdx_ = 2; page.resetRetreatGeometry_(); page.freezeRetreatAnchor_();
assert.equal(page.retreatAnchorInset_, 110, '相同几何切换没有新area事件仍可冻结');
page.retreatScrollable_ = false; page.consumeRetreatFrame_(100, 1);
assert.equal(page.retreatHidden_, 0, '短列表不因回弹上滑自动收起');
page.retreatScrollable_ = true; page.consumeRetreatFrame_(18, 1);
assert.equal(page.retreatHidden_, 30); const retiredFinish = finishes.at(-1);
page.hostVisible = false; page.onRetreatHostVisible_(); retiredFinish();
assert.equal(page.retreatHidden_, 0); assert.equal(page.retreatAnimating_, false);
page.consumeRetreatFrame_(100, 1); assert.equal(page.retreatHidden_, 0, '隐藏主Tab不响应旧帧');
page.hostVisible = true; page.onRetreatHostVisible_();
page.kindIdx_ = 3; page.browseWidth_ = 900; page.resetRetreatGeometry_();
assert.equal(page.retreatTargetHeight_, 0); assert.equal(page.retreatLoaderHeight_, 0);
page.measureRetreatHeight_(0, { height: 90 }); page.measureRetreatHeight_(1, { height: 40 });
assert.equal(page.retreatTargetHeight_, 0); assert.equal(page.retreatLoaderHeight_, 0, '旧测量不能复活缺失层');
assert.deepEqual(page.retreatLayers_(), [30, 0]); page.retreatScrollable_ = true;
page.retreatGridScroller_ = { currentOffset: () => ({ yOffset: 0 }) };
page.retreatScroller_ = { currentOffset: () => { throw Error('Grid不能读取List控制器'); } };
page.retreatHidden_ = 30; page.retreatReturning_ = true;
assert.equal(page.restoreRetreatAtStart_(), true); assert.equal(page.retreatHidden_, 0);
// 复位只清瞬时资格后，未变化的原生可见范围仍能证明长内容；数据缩短则重新判短。
page.kindIdx_ = 2; page.retreatListFirst_ = 0; page.retreatListLast_ = 3;
page.view_.hits = Array.from({ length: 10 }, () => ({})); page.resetRetreatGeometry_();
assert.equal(page.retreatScrollable_, false); assert.equal(page.retreatContentOverflows_(), true);
page.view_.hits = [{}]; assert.equal(page.retreatContentOverflows_(), false);
groups.push('all-resource-kind-measurement-short-content-lifecycle-and-controller-isolation');

// 执行真实Grid声明与回调，验证独占Scroller、完整跨列占位、固定视口和长内容资格。
mv.kindIdx_ = 3; mv.browseWidth_ = 1000; mv.headerCollapsed_ = false;
mv.retreatTargetHeight_ = 0; mv.retreatLoaderHeight_ = 0; mv.retreatSortHeight_ = 40;
mv.retreatAnchorInset_ = 40; mv.retreatGridScroller_ = { marker: 'exclusive-grid' };
mv.deviceForm = 'tablet'; mv.bottomSafeHeight = 0;
for (const h of [0, 40, 0]) {
  mv.retreatHidden_ = h; mv.retreatAnimating_ = false; viewUi.records.length = 0; mv.BrowseResults_();
  const grid = record('modpack-browser-results');
  const nativeGrid = viewUi.records.find(r => r.args[0] === mv.retreatGridScroller_);
  assert.ok(nativeGrid);
  assert.deepEqual(nativeGrid.args[1].irregularIndexes, [0, mv.view_.hits.length + 1]);
  assert.equal(grid.modifiers.height[0], '100%');
  assert.equal(attribute('modpack-retreat-content-inset', 'height'), 28);
  for (const event of ['onScrollStart', 'onScrollFrameBegin', 'onTouch', 'onReachStart', 'onDidScroll', 'onScrollStop', 'onScrollIndex']) {
    assert.equal(typeof grid.modifiers[event][0], 'function', event);
  }
  if (h === 0) {
    grid.modifiers.onScrollIndex[0](0, mv.view_.hits.length); assert.equal(mv.retreatScrollable_, false);
    grid.modifiers.onScrollIndex[0](0, 0); assert.equal(mv.retreatScrollable_, true);
  }
}
mv.retreatAnchorInset_ = 0; mv.retreatHidden_ = 0; viewUi.records.length = 0; mv.BrowseResults_();
assert.equal(record('modpack-retreat-content-inset'), undefined, '初始无辅助层不制造空网格行');
assert.deepEqual(viewUi.records.find(r => r.args[0] === mv.retreatGridScroller_).args[1].irregularIndexes,
  [mv.view_.hits.length]);
groups.push('production-grid-full-row-inset-controller-and-events');

const source = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const broken = source.replace('return { hidden: next, offsetRemain: offset };', 'return { hidden: next, offsetRemain: 0 };');
assert.notEqual(source, broken);
const Bad = makePureEtsLoader({}, { [file]: broken })(file).LayerRetreatPolicy;
assert.notEqual(new Bad().step(18, 0, heights, true, true).offsetRemain, 18);
groups.push('pass-through-negative-control');
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify({ status: 'passed', groups,
  scope: 'code checks only; no device interaction or visual acceptance' }, null, 2));
console.log('PASS whole-layer code checks: ' + groups.join(', '));

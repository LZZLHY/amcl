/** 执行真实版本视图数据源及页面拖拽方法，验证SDK交换通知、业务插入顺序和监听生命周期。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { actionUiReceiver, loadActionComponent } from './lib/unified-actions-fixture.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionListDataSource.ets', import.meta.url), 'utf8');
const compiled = compiler.transpileModule(source, { compilerOptions: {
  target: compiler.ScriptTarget.ES2022, module: compiler.ModuleKind.CommonJS,
} }).outputText;
const exported = {}; new Function('exports', compiled)(exported);
const DataSource = exported.VersionListDataSource;
/** 仅读取生产视图主键，用于核对每次SDK通知后的真正索引顺序。 */
const read = value => Array.from({ length: value.totalCount() }, (_, index) => value.getData(index));

test('完整替换保留主键，复制输入并通知已注册的真实视图监听者', () => {
  const data = new DataSource(); let reloads = 0;
  const listener = { onDataReloaded() { reloads++; }, onDataMove() { assert.fail('替换不能伪造移动'); } };
  data.registerDataChangeListener(listener); const ids = ['26.3', '1.12.2-forge']; data.replace(ids);
  ids.reverse(); assert.deepEqual(read(data), ['26.3', '1.12.2-forge']); assert.equal(reloads, 1);
  data.unregisterDataChangeListener(listener); data.replace(['26.3']); assert.equal(reloads, 1);
});

test('非相邻业务插入以相邻交换通知SDK，每次通知与实际getData一致且主键不变', () => {
  const data = new DataSource(); const initial = ['a', 'b', 'c', 'd', 'e']; data.replace(initial);
  let mirrored = initial.slice(), moves = 0;
  data.registerDataChangeListener({ onDataReloaded() { assert.fail('拖拽不能重建整个数据集'); },
    onDataMove(from, to) {
      assert.equal(Math.abs(from-to), 1, 'SDK交换两点，非相邻插入必须分解');
      [mirrored[from], mirrored[to]] = [mirrored[to], mirrored[from]]; moves++;
      assert.deepEqual(read(data), mirrored, '通知抵达时Native索引镜像与实际数据一致');
    } });
  assert.equal(data.relocate(0, 4), true); assert.deepEqual(read(data), ['b', 'c', 'd', 'e', 'a']);
  assert.equal(data.relocate(4, 1), true); assert.deepEqual(read(data), ['b', 'a', 'c', 'd', 'e']);
  assert.equal(moves, 7); assert.deepEqual([...read(data)].sort(), initial);
});

test('越界或小数移动不改变任何主键，越界读取不制造空版本', () => {
  const data = new DataSource(); data.replace(['a', 'b']);
  for (const pair of [[-1, 1], [0, 2], [0.5, 1], [0, Number.NaN]]) assert.equal(data.relocate(...pair), false);
  assert.deepEqual(read(data), ['a', 'b']); assert.throws(() => data.getData(2), /索引越界/);
});

test('真实页面移除插入与视图交换通知同步，最终顺序可由原持久化入口继续消费', () => {
  const view = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionManagerSheet.ets', import.meta.url), 'utf8');
  const start = view.indexOf('  private relocateVersionRow_('), end = view.indexOf('\n  /**', start);
  assert.ok(start > 0 && end > start);
  const code = compiler.transpileModule('class Probe {\n' + view.slice(start, end)
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} }; new Function('module', code)(module);
  const subject = new module.exports(); const data = new DataSource();
  subject.orderVersions = ['a', 'b', 'c', 'd']; data.replace(subject.orderVersions);
  subject.versionRowsDataSource_ = data;
  subject.refreshVersionRows_ = () => data.replace(subject.orderVersions);
  subject.relocateVersionRow_(0, 3); assert.deepEqual(subject.orderVersions, ['b', 'c', 'd', 'a']);
  assert.deepEqual(read(data), subject.orderVersions);
  subject.relocateVersionRow_(3, 1); assert.deepEqual(read(data), subject.orderVersions);
});

test('切换同名实例所在根时重新按真实加载器筛选，无须重新选择实例', () => {
  const view = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionManagerSheet.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('VersionManagerSheet.ets', view, compiler.ScriptTarget.Latest, true);
  const manager = ast.statements.find(node => node.name?.getText(ast) === 'VersionManagerSheet');
  const methods = ['onDetailSourceChanged_', 'refreshVersionRows_', 'filteredVersions'].map(name => {
    const member = manager.members.find(node => node.name?.getText(ast) === name);
    assert.ok(member?.body, name);
    return member.getText(ast);
  });
  const code = compiler.transpileModule('class Manager {\n' + methods.join('\n') + '\n}\nmodule.exports=Manager;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} };
  const loaders = new Map([['/external/same', 'fabric'], ['/sandbox/same', 'neoforge']]);
  new Function('module', 'resolveInstalledLoaderKey', code)(module, (root, name) => loaders.get(root + '/' + name));
  const subject = new module.exports();
  subject.detailVersion = '';
  subject.filterLoader = 'fabric';
  subject.orderVersions = ['same'];
  subject.versionRowsDataSource_ = new DataSource();
  subject.mcDir = '/external';
  subject.onDetailSourceChanged_('mcDir');
  assert.deepEqual(read(subject.versionRowsDataSource_), ['same']);
  subject.mcDir = '/sandbox';
  subject.onDetailSourceChanged_('mcDir');
  assert.deepEqual(read(subject.versionRowsDataSource_), []);
  subject.filterLoader = 'neoforge';
  subject.refreshVersionRows_();
  assert.deepEqual(read(subject.versionRowsDataSource_), ['same']);
});

// 下载清单仅隔离 ArkUI 的变更枚举和滚动几何；通知、视口选择和实际动效参数来自生产代码。
const downloadModule = {};
const downloadCode = compiler.transpileModule(fs.readFileSync(
  new URL('../entry/src/main/ets/components/VersionDownloadRows.ets', import.meta.url), 'utf8'),
  { compilerOptions: { target: compiler.ScriptTarget.ES2022, module: compiler.ModuleKind.CommonJS } }).outputText;
new Function('exports', 'DataOperationType', 'require', downloadCode)(downloadModule,
  { RELOAD: 'reload', ADD: 'add', DELETE: 'delete', CHANGE: 'change' }, name => {
    assert.equal(name, '@kit.ArkUI'); return { FrameCallback: class {} };
  });
const version = id => ({ id, type: 'release', url: id, releaseTime: '', displayDate: '2025-01-01' });

test('下载清单批量精确前插，对不相邻的新增使用原索引，同 ID 的显示修正单独按最终索引通知', () => {
  const rows = new downloadModule.VersionDownloadRowSource(), calls = [];
  const listener = { onDatasetChange(ops) { calls.push(ops); } };
  rows.registerDataChangeListener(listener);
  const [a, b, c] = ['a', 'b', 'c'].map(version);
  rows.replace([a, b, c]); assert.deepEqual(calls.pop(), [{ type: 'reload' }]);
  rows.replace([a, { ...b, url: 'new' }, c]); assert.deepEqual(calls, []);
  const changed = { ...b, displayDate: '2025-01-02' };
  rows.replace([version('w'), version('x'), a, changed, version('y'), c]);
  assert.deepEqual(calls.splice(0), [[{ type: 'add', index: 0, count: 2 }, { type: 'add', index: 2, count: 1 }],
    [{ type: 'change', index: 3 }]]);
  assert.equal(rows.getData(3), changed);
  assert.notEqual(downloadModule.downloadRowKey(changed), downloadModule.downloadRowKey(b));
  rows.replace([changed, a]); assert.deepEqual(calls.pop(), [{ type: 'reload' }]);
  rows.unregisterDataChangeListener(listener);
  rows.replace([]); assert.deepEqual(calls, []);
});

test('分类缩窄时分段通知删除，保留阅读位置所需的行身份和原数组索引', () => {
  const rows = new downloadModule.VersionDownloadRowSource(), calls = [];
  const [a,b,c,d,e] = ['a','b','c','d','e'].map(version);
  rows.replace([a,b,c,d,e]);
  rows.registerDataChangeListener({ onDatasetChange(ops) { calls.push(ops); } });
  rows.replace([b,e]);
  assert.deepEqual(calls, [[{ type: 'delete', index: 0, count: 1 }, { type: 'delete', index: 2, count: 2 }]]);
  assert.strictEqual(rows.getData(0), b);
  assert.strictEqual(rows.getData(1), e);
});

// 装载完整非 UI 成员，真实分类、过滤、视图发布和帧逻辑一同执行。仅提供原生几何、帧和状态监听端口。
const era = environment().load('commons/src/main/ets/utils/McVersionUtils.ets');
const ids = environment({ commons: era }).load('mods/src/main/ets/VersionIdUtils.ets');
const downloadPagePath = 'entry/src/main/ets/pages/tabs/DownloadTab.ets';
const pageFile = new URL('../' + downloadPagePath, import.meta.url);
const pageAst = compiler.createSourceFile(downloadPagePath, fs.readFileSync(pageFile, 'utf8'), compiler.ScriptTarget.Latest, true);
const pageStruct = pageAst.statements.find(node => node.members && node.name?.getText(pageAst) === 'DownloadTab');
function watchProperty(page, key) {
  // 宿主没有 ArkUI 装饰器。取实际声明的 @Watch 方法，按 V1 相同值不派发的约定交付属性名。
  const field = pageStruct.members.find(member => member.name?.getText(pageAst) === key);
  const watcher = compiler.getDecorators(field)?.find(decorator => decorator.expression.expression?.getText(pageAst) === 'Watch');
  const method = watcher?.expression.arguments[0].text;
  assert.equal(typeof page[method], 'function', key + ' 已接到组件监听方法');
  let value = page[key];
  Object.defineProperty(page, key, { get: () => value, set(next) {
    if (value === next) return;
    value = next;
    page[method](key);
  } });
}
function motionPage() {
  let reduced = false, first = -1, last = -1, offset = 0;
  let height = 0, rectanglesReady = true;
  const scheduled = [], finishes = [];
  const rect = index => {
    const visible = rectanglesReady && index >= first && index <= last && first >= 0;
    return { x: 0, y: visible ? index * 72 - offset : 0, width: visible ? 400 : 0, height: visible ? 64 : 0 };
  };
  const Tab = loadActionComponent(downloadPagePath, 'DownloadTab', {
    dependencies: { '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } }, '@kit.ArkUI': {},
      commons: { AppIconName: {}, floatingDockReserveHeight: () => 0 }, feature_core: { McVersionService: class {} }, mods: ids,
      '../../launcherskill/LauncherSkillBus': { LauncherSkillBus: { bind() {}, unbind() {} } },
      '../../launcherskill/SettingsSkillValues': {}, '../../components/VersionDownloadRows': downloadModule,
      '../../components/UiMotion': { UiMotion: { reduced: () => reduced } } },
    globals: { Scroller: class {}, Curve: { EaseOut: 'ease' } }
  });
  const page = new Tab();
  page.versionMounted_ = true;
  page.versionVisible_ = true;
  page.getUIContext = () => ({ postFrameCallback: frame => scheduled.push(frame),
    animateTo(options, transition) { transition(); if (options.onFinish) finishes.push(options.onFinish); } });
  // 不提供 scrollTo，避免测试掩盖靠强制滚动修补阅读位置的行为。
  page.versionScroller_ = { currentOffset: () => ({ yOffset: offset }), getItemRect: rect };
  for (const prop of ['filterRelease', 'filterSnapshot', 'filterOld', 'filterAprilFools', 'versionSearch']) watchProperty(page, prop);
  const paneUi = actionUiReceiver();
  let onRange, onScroll;
  const Browser = loadActionComponent(downloadPagePath, 'DownloadTab', {
    methods: ['DlVersionTab'], render: true, globals: paneUi.globals,
    dependencies: { '../../components/DownloadSearchField': { DownloadSearchField() {} },
      '../../components/DownloadAuxiliaryList': { DownloadAuxiliaryList(options) {
        onRange = options.onVisibleRows; onScroll = options.onRowsScroll; return paneUi.globals.Column();
      } } }
  });
  Browser.prototype.DlVersionTab.call(page);
  const onArea = paneUi.records.find(record => record.modifiers.onAreaChange)?.modifiers.onAreaChange[0];
  assert.equal(typeof onRange, 'function');
  page.VersionCard_ = RowView.prototype.VersionCard_;
  return { page, scheduled, finishes, scroll: () => onScroll(), reduced: value => { reduced = value; },
    rectangles(value) { rectanglesReady = value; },
    range(a, b, y = 0, paneHeight = (b-a+1)*72) {
      const moved = a !== first || b !== last;
      first = a; last = b; offset = y;
      if (moved) onRange(a,b);
      if (height !== paneHeight) { height = paneHeight; onArea?.({}, { height }); }
    },
    frame() {
      for (const callback of scheduled.splice(0)) { callback.onFrame?.(0); callback.onIdle?.(5_000_000); }
    },
    flush() { for (let i = 0; scheduled.length && i < 32; i++) this.frame(); }
  };
}
const pairedVersions = count => Array.from({ length: count }, (_, i) => [
  version('1.21.' + i), { ...version('26.2-snapshot-' + i), type: 'snapshot' }
]).flat();
const rowUi = actionUiReceiver();
rowUi.globals.alignItems = (...args) => rowUi.globals.Column().alignItems(...args);
const RowView = loadActionComponent(downloadPagePath, 'DownloadTab', {
  methods: ['VersionItem', 'VersionCard_'], render: true, globals: rowUi.globals,
  dependencies: { commons: { AppIconName: {} }, '../../components/AppIcon': { AppIcon() {} },
    '../../components/VersionBlockIcon': { VersionBlockIcon() {} },
    '../../components/VersionScrollEntrance': { VersionScrollEntrance(props) {
      props.content();
      return rowUi.globals.Column(props);
    } } }
});
function renderVersion(page,row) {
  rowUi.clear();
  RowView.prototype.VersionItem.call(page,row);
  return rowUi.records.find(record => record.modifiers.animation);
}
const assertStagger = (page, items) => {
  const delays = items.map(row => {
    const cue = page.versionCues_.get(row.id);
    assert.ok(cue && cue.alpha < 1, '应有入场动效 ' + row.id);
    const modifiers = renderVersion(page,row)?.modifiers;
    assert.ok(modifiers?.animation[0].duration > 0, row.id + ' 的真实行修饰器应启用动画');
    assert.equal(modifiers.opacity[0], 1);
    assert.equal(modifiers.translate[0].y, 0);
    return modifiers.animation[0].delay;
  });
  assert.ok(delays.slice(1).every((delay, i) => delay > delays[i]), '可见新行逐项错峰 ' + delays.join(','));
};

test('初次提交没有布局，收到迟到的原生范围后整个可见区都依次出现', () => {
  const ui = motionPage(), { page } = ui;
  const releases = Array.from({ length: 1200 }, (_, i) => version('1.21.' + i));
  page.applyVersionList_(releases, true);
  assert.equal(page.versionRows_.totalCount(), releases.length, '不等布局即可读取清单');
  ui.frame(); // 首个渲染机会已经过去，再提供真实几何。
  ui.range(0, 18); ui.flush();
  assertStagger(page, releases.slice(0,18));
  assert.ok(!page.versionCues_.has(releases[18].id), '屏幕外一千多行不排入首屏动效');
});

test('同一窗口先布局 6 行再扩到 18 行，初始部分矩形不能耗尽整轮动效', () => {
  const ui = motionPage(), { page } = ui;
  const rows = Array.from({ length: 60 }, (_, i) => version('1.21.' + i));
  const paneHeight = 19 * 72; // 一个辅助区占位、十八个真实版本行，窗口高度始终相同。
  ui.range(0,6,0,paneHeight); page.applyVersionList_(rows,true);
  ui.frame(); ui.frame();
  ui.range(0,18,0,paneHeight); ui.flush();
  assertStagger(page,rows.slice(0,18));
  assert.ok(!page.versionCues_.has(rows[18].id));
});

test('长期没有行矩形时撤掉预备姿态和重影，后到的真实可见事件可在同尺寸同索引下恢复', () => {
  const ui = motionPage(), { page } = ui, catalog = pairedVersions(36);
  ui.range(0,16); page.applyVersionList_(catalog,true); ui.flush();
  page.toggleFilter('snapshot');
  assert.ok(page.departingVersions_.length > 0, '已采样旧布局的卡片');
  ui.rectangles(false);
  ui.flush(); // 模拟没有新的范围、尺寸和可见事件，宿主只投递已排队的原生帧。
  assert.equal(ui.scheduled.length,0, '几何缺失不能永久请求 VSync');
  assert.equal(page.departingVersions_.length,0, '不让等待几何的旧卡片挡住当前行');
  for (const row of catalog.slice(0,2)) {
    const modifiers = renderVersion(page,row).modifiers;
    assert.equal(modifiers.opacity[0],1);
    assert.equal(modifiers.translate[0].y,0);
  }
  ui.rectangles(true); // 实际窗口大小与首尾索引均不变，此处不人工重发两个回调。
  renderVersion(page,catalog[1]).args[0].onFirstVisible();
  assert.equal(renderVersion(page,catalog[0]).modifiers.opacity[0],1,
    '延后重测的第一帧仍能读到没有旧卡片副本覆盖的正式版');
  ui.flush();
  assertStagger(page,catalog.slice(0,16).filter(row => row.type === 'snapshot'));
});

test('多选快照使交错新行依次出现，旧行逐项让位；取消筛选时保留行回到原位置', () => {
  const ui = motionPage(), { page } = ui;
  const catalog = pairedVersions(30);
  ui.range(0, 16); page.applyVersionList_(catalog, true); ui.flush();
  const retained = page.versionRows_.getData(2);
  page.toggleFilter('snapshot'); ui.range(0, 16); ui.flush();
  assert.deepEqual(read(page.versionRows_).map(row => row.id), catalog.map(row => row.id));
  assert.strictEqual(page.versionRows_.getData(4), retained);
  assertStagger(page, catalog.slice(0,16).filter(row => row.type === 'snapshot'));
  assert.equal(page.versionCues_.get('1.21.1')?.y, -72);
  assert.equal(page.versionCues_.get('1.21.2')?.y, -144);
  assert.deepEqual([...page.newVersionIds_], [], '显示一组已知快照不计入清单新增版本');
  assert.ok(page.departingVersions_.some(row => row.ver.id === '1.21.15'), '被挤出原生窗口的旧行要接续退场');
  assert.ok(page.versionExitOffsets_.get('1.21.15') > 0, '向窗口下方退场');
  const finishPrevious = ui.finishes.shift();
  page.toggleFilter('snapshot'); ui.range(0, 16); ui.flush();
  assert.ok(read(page.versionRows_).every(row => row.type === 'release'));
  assert.equal(page.versionCues_.get('1.21.2')?.y, 144);
  const departing = page.departingVersions_;
  assert.ok(departing.some(row => row.ver.type === 'snapshot'));
  finishPrevious(); assert.strictEqual(page.departingVersions_, departing, '旧动画完成回调不得清掉新一轮退场');
  ui.finishes.shift()(); assert.equal(page.departingVersions_.length, 0);
});

test('连续切换类别和搜索时迟到帧不能复活旧行，筛选不生成新版标记', () => {
  const ui = motionPage(), { page } = ui, catalog = pairedVersions(30);
  ui.range(0, 16); page.applyVersionList_(catalog, true); ui.flush();
  page.toggleFilter('snapshot');
  const stale = ui.scheduled.splice(0);
  page.toggleFilter('snapshot');
  page.versionSearch = '1.21.2';
  for (const frame of stale) { frame.onFrame?.(0); frame.onIdle?.(5_000_000); }
  ui.range(0, 11); ui.flush();
  assert.ok(page.versionRows_.totalCount() > 0);
  assert.ok(read(page.versionRows_).every(row => row.id.includes('1.21.2') && row.type === 'release'));
  assert.ok([...page.versionCues_.keys()].every(key => page.versionRows_.has(key)));
  assert.deepEqual([...page.newVersionIds_], []);
  ui.reduced(true);
  page.versionSearch = ''; page.toggleFilter('snapshot');
  ui.range(0,16); ui.flush();
  assert.equal(page.versionRows_.totalCount(), catalog.length);
  assert.equal(page.versionCues_.size, 0);
});

test('阅读中段时前插沿用 List 的原生锚点，后台真实新增依然有自己的标记', () => {
  const ui = motionPage(), { page } = ui;
  const catalog = Array.from({ length: 150 }, (_, i) => version('1.21.' + i));
  ui.range(0, 16); page.applyVersionList_(catalog, true); ui.flush();
  // 第 0 项是辅助层。原生保锚将首行的索引和偏移同步后移一项，但其屏幕 y 不动。
  ui.range(20, 35, 20 * 72);
  const first = page.versionRows_.getData(19), added = version('26.2');
  page.applyVersionList_([added, ...catalog], false);
  ui.range(21, 36, 21 * 72); ui.flush();
  assert.strictEqual(page.versionRows_.getData(20), first);
  assert.ok(!page.versionCues_.has(first.id), '已由原生保锚的同一行不能再用动画补偿一次');
  assert.ok(!page.versionCues_.has(added.id), '视口上方的新增不会跳到当前阅读窗口');
  assert.deepEqual([...page.newVersionIds_], [added.id]);
});

test('浏览期间已看过的行不重播，预取不会提前消耗滚动首次入场，分类与搜索不会叠加滚动动效', () => {
  const ui = motionPage(), { page } = ui, catalog = pairedVersions(40);
  ui.range(0, 16); page.applyVersionList_(catalog, true); ui.flush();
  const initial = renderVersion(page,catalog[0]).args[0];
  const next = renderVersion(page,catalog[32]).args[0];
  assert.equal(next.shouldStage(), false, '系统预取第 17 个正式版时用户尚未滑动');
  ui.scroll();
  assert.equal(initial.shouldStage(), false);
  assert.equal(initial.onFirstVisible(), false, '初屏已成组入场，不重复消费单行动效');
  assert.equal(next.shouldStage(), true);
  ui.range(2,17,72);
  assert.equal(next.onFirstVisible(), true);
  ui.range(20,35,20*72); ui.range(2,17,72);
  assert.equal(next.shouldStage(), false);
  assert.equal(next.onFirstVisible(), false);
  page.toggleFilter('snapshot');
  const snapshot = renderVersion(page,catalog[1]).args[0];
  assert.equal(snapshot.shouldStage(), false, '分类请求仅播放成组错峰');
  assert.equal(snapshot.onFirstVisible(), false);
  ui.scroll(); page.versionSearch = '26.2-snapshot-2';
  const previouslyUnseen = renderVersion(page,catalog[41]).args[0];
  assert.equal(previouslyUnseen.shouldStage(), false, '搜索后的列表直接可读');
  assert.equal(previouslyUnseen.onFirstVisible(), false);
});

test('首帧繁忙时第二帧放行，空闲先到仅执行一次，取消阻止所有滞后帧', () => {
  const scheduled = [];
  let played = 0;
  const context = { postFrameCallback(frame) { scheduled.push(frame); } };
  const first = new downloadModule.VersionRowsInitialFrame(context, () => played++);
  first.onFrame(0); assert.equal(played, 0); assert.equal(scheduled.length, 1);
  scheduled.shift().onFrame(16_670_000); assert.equal(played, 1);
  first.onIdle(3); assert.equal(played, 1);
  const idle = new downloadModule.VersionRowsInitialFrame(context, () => played++);
  idle.onFrame(0); idle.onIdle(3); assert.equal(played, 2);
  scheduled.shift().onFrame(16_670_000); assert.equal(played, 2);
  const cancelled = new downloadModule.VersionRowsInitialFrame(context, () => played++);
  cancelled.onFrame(0); cancelled.cancel(); scheduled.shift().onFrame(16_670_000);
  cancelled.onIdle(3); assert.equal(played, 2);
});

/**
 * 导出Sheet的真实选择/草稿/扫描状态回归。保留生产组件的字段及全部非Builder方法，
 * 只替换ArkUI宿主与Coordinator端口；选择算法直接载入feature_core真实实现。
 * 不启动网络、设备或归档，不在测试侧重写父子包含/排除算法。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT } from './lib/workspace-paths.mjs';

const sheetPath = 'entry/src/main/ets/components/GameExportSheet.ets';
const sheetSource = fs.readFileSync(path.join(PROJECT_ROOT, sheetPath), 'utf8');
const sheetAst = compiler.createSourceFile(sheetPath, sheetSource, compiler.ScriptTarget.Latest, true);
const sheetNode = sheetAst.statements.find(node => node.name?.text === 'GameExportSheet');
assert(sheetNode?.members, '必须测试真实GameExportSheet');

/** 只提取真实安全路径函数，避免加载无关安装/网络模块；不改其函数体。 */
function selectedSource(relative, names) {
  const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
  const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
  return ast.statements.filter(node => names.includes(node.name?.text) ||
    node.declarationList?.declarations.some(item => names.includes(item.name.text)))
    .map(node => node.getFullText(ast)).join('\n');
}

const modules = new Map();
function load(relative, override) {
  if (modules.has(relative)) return modules.get(relative);
  const source = override ?? fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
  const output = compiler.transpileModule(source, {
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  }).outputText;
  const exports = {}; modules.set(relative, exports);
  const require = name => {
    if (name.startsWith('.')) {
      const resolved = path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/');
      if (resolved.endsWith('/MavenUtils.ets')) return load(resolved, selectedSource(resolved,
        ['MAX_SAFE_SEGMENT_LENGTH', 'MAX_SAFE_RELATIVE_PATH_LENGTH', 'containsControlCharacter', 'safeBaseName', 'safeRelPath']));
      return load(resolved);
    }
    throw new Error('unexpected selection module ' + name);
  };
  new Function('exports', 'require', output)(exports, require); return exports;
}
const core = { ...load('feature_core/src/main/ets/export/ExportTypes.ets'),
  ...load('feature_core/src/main/ets/export/ExportContentSelection.ets') };
const projection = load('entry/src/main/ets/export/ExportTaskProjection.ets');

/** 装饰器/Builder属于SDK；其余字段初始化、异步方法及选择处理均为原组件正文。 */
const members = sheetNode.members.filter(node => node.name?.getText(sheetAst) !== 'build' &&
  !node.getText(sheetAst).trimStart().startsWith('@Builder')).map(node => node.getText(sheetAst)
  .replace(/@(?:Prop|State|StorageProp|StorageLink)(?:\([^)]*\))?\s*/g, '')).join('\n');
const dataSource = sheetAst.statements.find(node => node.name?.text === 'ExportContentRowsDataSource').getText(sheetAst);
const sizeFunction = sheetAst.statements.find(node => node.name?.text === 'exportSize').getText(sheetAst);
const labelFunction = sheetAst.statements.find(node => node.name?.text === 'contentLabel').getText(sheetAst);
const script = compiler.transpileModule(`${dataSource}\n${sizeFunction}\n${labelFunction}\nexport class Sheet { ${members} }`, {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
}).outputText;

function contentTree(withError = false) {
  const item = (relative, kind = 'file', defaultSelected = false, available = true) => ({
    id: 'item:' + relative, path: relative, label: path.posix.basename(relative), kind, defaultSelected,
    available, reason: available ? '' : '读取失败：Permission denied', ...(kind === 'file' ? { size: 123 } : {}),
  });
  const group = (id, items = [], children = [], availability) => ({ id: 'group:' + id, label: id,
    description: '实际内容分类', items, children,
    availability: availability ?? (items.length || children.length ? 'available' : 'empty'), reason: '' });
  const groups = [group('resourcepacks', [item('resourcepacks/A.zip', 'file', true), item('resourcepacks/B.zip', 'file', true)]),
    group('maps', [], [group('schematics', [item('schematics/a.litematic')])]),
    group('worlds', [item('saves/World One', 'world')]), group('media')];
  if (withError) groups.push(group('other', [item('unreadable', 'directory', false, false)], [], 'error'));
  return { groups, issues: [], directories: ['resourcepacks', 'schematics'], files: [], worlds: ['World One'] };
}

function fixture({ shared = false, draft = null, tree = contentTree(), loader = 'vanilla' } = {}) {
  const state = { checks: [], saved: [], backs: 0, closes: 0, scans: 0, task: null, scanGate: null, checkGate: null,
    scanError: null, saveGate: null, saveError: null };
  const base = { mcRoot: '/mc', versionId: '1.20.1', gameDir: shared ? '/mc' : '/mc/versions/1.20.1',
    exportId: 'portable', displayName: 'Portable', format: 'full', launcher: 'pcl',
    platform: { os: 'windows', arch: 'x64', version: '' }, includeDirectories: [], includeFiles: [], selectedWorlds: [], sharedGameDir: shared };
  const source = { request: base, contentTree: tree, directories: tree.directories, files: tree.files,
    worlds: tree.worlds, sharedGameDir: shared, summary: '当前实例', loaderKind: loader, issues: [] };
  const coordinator = {
    async inspectSource() { state.scans++; if (state.scanGate) await state.scanGate; if (state.scanError) throw state.scanError; return source; },
    async loadDraft() { return draft; }, subscribe() { return () => {}; }, getTask() { return state.task; },
    async saveDraft(request) { state.saved.push(request); if (state.saveGate) await state.saveGate; if (state.saveError) throw state.saveError; },
    async checkPlan(request) { state.checks.push(request); if (state.checkGate) await state.checkGate; return { id: 'preview', issues: core.exportContentSelectionIssues(request, tree),
      summary: [], files: 7, totalBytes: 123, tempBytes: 456, downloads: 0, downloadBytes: 0 }; },
  };
  class Motion { moving = false; viewport = 0; reset() {} dispose() {} offset() { return 0; } }
  const exports = {};
  const names = Object.keys(core);
  new Function('exports', 'ThemeColors', 'SheetPageMotion', 'getGameExportCoordinator', 'shouldProjectExportTask',
    'AppStorage', ...names, script)(exports, class {}, Motion, () => coordinator, projection.shouldProjectExportTask,
      { get() { return { filesDir: '/private' }; } }, ...names.map(name => core[name]));
  const sheet = new exports.Sheet();
  Object.assign(sheet, { mcRoot: '/mc', versionId: '1.20.1', versionIsolation: !shared, alive_: true,
    context_: { filesDir: '/private' }, onBack() { state.backs++; }, onClose() { state.closes++; } });
  return { sheet, state, base, source, tree, async initialize() { await sheet.initialize_(); return sheet; } };
}

test('full defaults include all current content including shared-world scope without hiding launcher adaptation', async () => {
  const f = fixture({ shared: true }); await f.initialize();
  assert.equal(f.sheet.scanState_, 'ready'); assert.equal(f.sheet.launcher_, 'pcl');
  assert.deepEqual(f.sheet.request_().selectedWorlds, ['World One']);
  assert(core.isExportContentAllSelected(f.sheet.request_(), f.tree));
  assert.match(f.sheet.contentPurpose_(), /全部可导出/);
});

test('full and standard preserve independent custom choices while MR and CF share the standard purpose', async () => {
  const f = fixture(); await f.initialize();
  f.sheet.selectNode_('item:resourcepacks/A.zip', false);
  f.sheet.chooseFormat_('modrinth');
  assert.deepEqual(f.sheet.request_().selectedWorlds, []);
  assert.equal(core.isExportContentItemSelected(f.sheet.request_(), f.tree.groups[0].items[0]), true);
  f.sheet.selectNode_('item:resourcepacks/B.zip', false);
  f.sheet.chooseFormat_('curseforge');
  assert.equal(core.isExportContentItemSelected(f.sheet.request_(), f.tree.groups[0].items[1]), false);
  f.sheet.chooseFormat_('full');
  assert.equal(core.isExportContentItemSelected(f.sheet.request_(), f.tree.groups[0].items[0]), false);
  assert.deepEqual(f.sheet.request_().selectedWorlds, ['World One']);
  assert.match(f.sheet.contentPurpose_(), /自定义/);
});

test('v1 draft is reconciled without applying new full defaults or losing nested package choices', async () => {
  const f = fixture(); const draft = { ...f.base, includeDirectories: ['resourcepacks'], includeFiles: [], selectedWorlds: [] };
  const g = fixture({ draft }); await g.initialize();
  assert.deepEqual(g.sheet.selectedWorlds_, []);
  g.sheet.selectNode_('item:resourcepacks/A.zip', false);
  assert.equal(core.isExportContentItemSelected(g.sheet.request_(), g.tree.groups[0].items[0]), false);
  assert.equal(core.isExportContentItemSelected(g.sheet.request_(), g.tree.groups[0].items[1]), true);
});

/** 真机回归：明确恢复默认之后，旧范围已不在请求里，界面也必须同步撤销该范围提示。 */
test('restoring defaults clears obsolete draft warnings while preserving discovery findings', async () => {
  const base = fixture().base;
  const f = fixture({ draft: { ...base, includeFiles: ['shaderpacks/retired.zip'] } });
  f.source.issues = [
    { code: 'shared-directory', severity: 'warning', message: '共享目录需确认', path: '' },
    { code: 'unreadable-source', severity: 'error', message: '另一范围权限失败', path: 'unreadable' },
  ];
  await f.initialize();
  assert(f.sheet.sourceIssues_.some(message => message.includes('shaderpacks/retired.zip')));
  f.sheet.resetContentSelection_();
  assert(!f.sheet.request_().includeFiles.includes('shaderpacks/retired.zip'));
  assert(!f.sheet.sourceIssues_.some(message => message.includes('shaderpacks/retired.zip')));
  assert.deepEqual(f.sheet.sourceIssues_, ['提示：共享目录需确认', '需要处理：另一范围权限失败（unreadable）']);
  assert.equal(f.sheet.previewReady_, false);
});

/** 格式族仍保留用户旧意图，但其提示仅在对应族可见；重置一个族不会复活该族旧提示。 */
test('format changes project only current selection findings and restore retained unknown intent', async () => {
  const base = fixture().base;
  const f = fixture({ draft: { ...base, includeFiles: ['shaderpacks/retired.zip'] } });
  f.source.issues = [{ code: 'shared-directory', severity: 'warning', message: '共享目录需确认', path: '' }];
  await f.initialize();
  f.sheet.chooseFormat_('modrinth');
  assert.deepEqual(f.sheet.sourceIssues_, ['提示：共享目录需确认']);
  assert(!f.sheet.request_().includeFiles.includes('shaderpacks/retired.zip'));
  f.sheet.chooseFormat_('full');
  assert(f.sheet.request_().includeFiles.includes('shaderpacks/retired.zip'));
  assert(f.sheet.sourceIssues_.some(message => message.includes('shaderpacks/retired.zip')));
  f.sheet.resetContentSelection_();
  f.sheet.chooseFormat_('modrinth'); f.sheet.chooseFormat_('full');
  assert.deepEqual(f.sheet.sourceIssues_, ['提示：共享目录需确认']);
  assert(!f.sheet.request_().includeFiles.includes('shaderpacks/retired.zip'));
});

test('overlapping config exclusion survives UI request copies and does not mutate the stored selection', async () => {
  const tree = contentTree();
  tree.groups.push({ id: 'group:config', label: '配置', description: '', availability: 'available', reason: '', children: [], items: [
    { id: 'item:config', path: 'config', label: '配置', kind: 'directory', defaultSelected: true, available: true, reason: '' },
    { id: 'item:config/jei/world/a.json', path: 'config/jei/world/a.json', label: '个人记录', kind: 'file', defaultSelected: false, available: true, reason: '', size: 9 },
  ] });
  const g = fixture({ tree }); await g.initialize();
  g.sheet.selectNode_('item:config/jei/world/a.json', false);
  assert(g.sheet.request_().excludePaths.includes('config/jei/world/a.json'));
  const request = g.sheet.request_(); request.excludePaths.length = 0; request.includeDirectories.length = 0;
  assert(g.sheet.request_().excludePaths.includes('config/jei/world/a.json'));
  assert(g.sheet.request_().includeDirectories.includes('config'));
});

/** C独立审查复现：非当前格式族的缓存同样必须随当前树对账，删除世界不能成为隐藏选择。 */
test('switching back reconciles the other format family after source content disappears', async () => {
  const f = fixture(); await f.initialize(); assert.deepEqual(f.sheet.request_().selectedWorlds, ['World One']);
  f.sheet.chooseFormat_('modrinth');
  const refreshed = contentTree(); refreshed.worlds = [];
  const worlds = refreshed.groups.find(group => group.id === 'group:worlds'); worlds.items = []; worlds.availability = 'empty';
  f.source.contentTree = refreshed; f.source.worlds = [];
  await f.sheet.initialize_(true); f.sheet.chooseFormat_('full');
  assert.deepEqual(f.sheet.request_().selectedWorlds, ['World One'], '未知旧意图保守保留，不能因一次发现未见就丢资料');
  assert(f.sheet.notice_.length > 0, '恢复旧格式族必须说明当前未发现的范围');
  f.sheet.resetContentSelection_();
  assert.deepEqual(f.sheet.request_().selectedWorlds, [], '用户明确恢复当前默认后才清除旧未知范围');
  assert.equal(f.sheet.previewReady_, false); assert.equal(f.sheet.dirty_, true);
});

test('parent all/some/none follows real helper and each edit revokes the previous executable preview', async () => {
  const f = fixture(); await f.initialize(); const group = f.tree.groups[0];
  assert.equal(f.sheet.contentGroupState_(group), 'all');
  f.sheet.previewReady_ = true; f.sheet.preview_ = { id: 'old' };
  f.sheet.selectNode_('item:resourcepacks/A.zip', false);
  assert.equal(f.sheet.contentGroupState_(group), 'some'); assert.equal(f.sheet.preview_, null); assert.equal(f.sheet.previewReady_, false);
  f.sheet.selectNode_(group.id, false); assert.equal(f.sheet.contentGroupState_(group), 'none');
  f.sheet.selectNode_(group.id, true); assert.equal(f.sheet.contentGroupState_(group), 'all');
});

test('expand arrows only expose lazy rows and never alter selection, preview or draft revision', async () => {
  const f = fixture(); await f.initialize(); const before = JSON.stringify(f.sheet.request_());
  const revision = f.sheet.editRevision_; f.sheet.preview_ = { id: 'same' }; f.sheet.previewReady_ = true;
  assert.equal(f.sheet.contentRows_.totalCount(), f.tree.groups.length);
  f.sheet.toggleContentGroup_('group:resourcepacks');
  assert.equal(f.sheet.contentRows_.totalCount(), f.tree.groups.length + 2);
  assert.equal(JSON.stringify(f.sheet.request_()), before); assert.equal(f.sheet.editRevision_, revision);
  assert.equal(f.sheet.preview_.id, 'same'); assert.equal(f.sheet.previewReady_, true);
});

test('unreadable selected range blocks full preview yet remains explicitly deselectable', async () => {
  const f = fixture({ tree: contentTree(true) }); await f.initialize();
  await f.sheet.check_(); assert.equal(f.sheet.previewReady_, false);
  f.sheet.step_ = 0; f.sheet.selectNode_('item:unreadable', false);
  await f.sheet.check_(); assert.equal(f.sheet.previewReady_, true);
  assert.equal(f.sheet.scanState_, 'ready', 'partial error is not an empty tree or a global scan failure');
});

test('scan failures stay errors with retry rather than fake empty groups or stale check eligibility', async () => {
  const f = fixture(); f.state.scanError = new Error('EACCES'); await f.initialize();
  assert.equal(f.sheet.scanState_, 'error'); assert.equal(f.sheet.loaded_, false);
  assert.equal(f.sheet.primaryEnabled_(), false); assert.match(f.sheet.error_, /EACCES/);
  f.state.scanError = null; await f.sheet.initialize_(true); assert.equal(f.sheet.scanState_, 'ready');
  f.sheet.selectNode_('item:resourcepacks/A.zip', false); const previous = JSON.stringify(f.sheet.request_());
  f.state.scanError = new Error('storage unavailable'); await f.sheet.initialize_(true);
  assert.equal(JSON.stringify(f.sheet.request_()), previous); assert.equal(f.sheet.primaryEnabled_(), false);
  await f.sheet.check_(); assert.equal(f.state.checks.length, 0);
});

test('destroyed component cannot accept the result of an older asynchronous content scan', async () => {
  const f = fixture(); let release; f.state.scanGate = new Promise(resolve => { release = resolve; });
  const pending = f.sheet.initialize_(); f.sheet.aboutToDisappear(); release(); await pending;
  assert.equal(f.sheet.loaded_, false); assert.equal(f.sheet.source_, null);
});

test('remount starts a new scan instead of inheriting the destroyed view busy state', async () => {
  const f = fixture(); let release; f.state.scanGate = new Promise(resolve => { release = resolve; });
  const first = f.sheet.initialize_(); f.sheet.aboutToDisappear(); f.state.scanGate = null;
  f.sheet.aboutToAppear(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.scans, 2); assert.equal(f.sheet.loaded_, true); assert.equal(f.sheet.busy_, false);
  release(); await first; assert.equal(f.sheet.scanState_, 'ready');
});

test('late check result from an old view cannot grant preview eligibility after remount', async () => {
  const f = fixture(); await f.initialize(); let release;
  f.state.checkGate = new Promise(resolve => { release = resolve; }); const pending = f.sheet.check_();
  f.sheet.aboutToDisappear(); f.sheet.aboutToAppear(); await new Promise(resolve => setImmediate(resolve));
  release(); await pending;
  assert.equal(f.sheet.preview_, null); assert.equal(f.sheet.previewReady_, false); assert.equal(f.sheet.busy_, false);
  assert.equal(f.state.saved.length, 0, 'old check must not save a new view draft');
});

test('refresh retains the in-memory choice instead of restoring an older disk draft', async () => {
  const f = fixture(); await f.initialize(); f.sheet.selectNode_('item:resourcepacks/A.zip', false);
  const before = JSON.stringify(f.sheet.request_()); f.sheet.preview_ = { id: 'stale' }; f.sheet.previewReady_ = true;
  await f.sheet.initialize_(true);
  assert.equal(JSON.stringify(f.sheet.request_()), before); assert.equal(f.state.scans, 2);
  assert.equal(f.sheet.preview_, null); assert.equal(f.sheet.previewReady_, false);
});

/** 重挂会作废旧检查，配置页必须重新可达，不能留下没有执行资格也无法检查的step1。 */
test('remount invalidating an approved preview returns from check and details to configuration', async () => {
  const f = fixture(); await f.initialize(); await f.sheet.check_();
  assert.equal(f.sheet.step_, 1); assert.equal(f.sheet.previewReady_, true);
  f.sheet.layer_ = 'details';
  f.sheet.aboutToDisappear(); f.sheet.aboutToAppear(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.sheet.preview_, null); assert.equal(f.sheet.previewReady_, false);
  assert.equal(f.sheet.step_, 0); assert.equal(f.sheet.layer_, 'main'); assert.equal(f.sheet.navPage_, 'settings');
  assert.equal(f.sheet.primaryEnabled_(), true, '重新读取成功后仍可重新检查');
});

/** step2是进程任务的展示，扫描与preview清理不能夺走运行中任务或已保存结果。 */
test('refresh preserves running and saved task step while invalidating only the old preview', async () => {
  for (const taskState of ['running', 'saved']) {
    const f = fixture(); await f.initialize();
    f.sheet.step_ = 2; f.sheet.taskState_ = taskState; f.sheet.taskFilename_ = 'Portable.zip';
    f.sheet.taskVerified_ = true; f.sheet.preview_ = { id: 'obsolete' }; f.sheet.previewReady_ = true;
    f.state.scanError = new Error('source no longer readable');
    await f.sheet.initialize_(true);
    assert.equal(f.sheet.step_, 2); assert.equal(f.sheet.taskState_, taskState);
    assert.equal(f.sheet.taskFilename_, 'Portable.zip'); assert.equal(f.sheet.taskVerified_, true);
    assert.equal(f.sheet.preview_, null); assert.equal(f.sheet.previewReady_, false);
    assert.equal(f.sheet.navigationKey_(), taskState === 'running' ? 'progress' : 'result');
  }
});

/**
 * 规模反例直接运行组件的真实投影和所有行getter，统计原生Set构造及request复制次数。
 * 5000项仅在请求变更时建一次四Set索引；重复显示统计/遍历行不得重建索引或复制请求。
 */
test('5000 visible content rows share one request projection and rebuild only after request changes', async () => {
  const count = 5000;
  const items = Array.from({ length: count }, (_, index) => ({ id: 'item:loose' + index + '.txt',
    path: 'loose' + index + '.txt', label: 'Loose ' + index, kind: 'file', defaultSelected: true,
    available: true, reason: '', size: 1 }));
  const group = { id: 'group:other', label: '其他', description: '', items, children: [], availability: 'available', reason: '' };
  const tree = { groups: [group], issues: [], directories: [], files: items.map(item => item.path), worlds: [] };
  const f = fixture({ tree }); await f.initialize();
  const request = f.sheet.request_.bind(f.sheet); let requestCopies = 0;
  f.sheet.request_ = () => { requestCopies++; return request(); };
  const OriginalSet = globalThis.Set; let inputs = 0; let constructions = 0;
  globalThis.Set = class extends OriginalSet {
    constructor(input) { if (Array.isArray(input)) inputs += input.length; constructions++; super(input); }
  };
  try {
    f.sheet.rebuildContentProjection_();
    assert.equal(requestCopies, 1); assert.equal(constructions, 4); assert.equal(inputs, count);
    const previous = { requestCopies, constructions, inputs };
    for (let repeat = 0; repeat < 3; repeat++) {
      assert.equal(f.sheet.contentGroupCount_(group), count);
      assert.equal(f.sheet.contentGroupSelectedCount_(group), count);
      assert.equal(f.sheet.contentGroupState_(group), 'all');
      assert.equal(f.sheet.selectedEntryCount_(), count);
      assert.match(f.sheet.selectionCount_(), /5000 \/ 5000/);
      assert.match(f.sheet.contentPurpose_(), /全部可导出/);
      for (const item of items) assert.equal(f.sheet.contentItemSelected_(item), true);
    }
    assert.deepEqual({ requestCopies, constructions, inputs }, previous, '显示getter不得复制请求/重建选择索引');
  } finally { globalThis.Set = OriginalSet; }
  const oldProjection = f.sheet.contentProjection_;
  f.sheet.selectNode_(items[0].id, false);
  assert.notEqual(f.sheet.contentProjection_, oldProjection);
  assert.equal(f.sheet.contentItemSelected_(items[0]), false); assert.equal(f.sheet.selectedEntryCount_(), count - 1);
  assert.equal(oldProjection.items.get(items[0].id), true, '旧投影不得被新请求原地改写');
  f.sheet.resetContentSelection_(); assert.equal(f.sheet.selectedEntryCount_(), count);
  const beforeRefresh = f.sheet.contentProjection_;
  await f.sheet.initialize_(true); assert.notEqual(f.sheet.contentProjection_, beforeRefresh, '每轮扫描重新发布投影');
});

/** 分类层可重复引用来源，计数按path去重；关联光影设置必须与包同时有效选中。 */
test('nested group projection agrees with helper deduplication and associated shader selection', async () => {
  const pack = { id: 'item:shaderpacks/A.zip', path: 'shaderpacks/A.zip', label: 'A', kind: 'file', defaultSelected: true, available: true, reason: '' };
  const settings = { ...pack, id: 'item:shaderpacks/A.zip.txt', path: 'shaderpacks/A.zip.txt', associatedPath: pack.path };
  const child = { id: 'group:shader-settings', label: '光影设置', description: '', items: [settings], children: [], availability: 'available', reason: '' };
  const group = { ...child, id: 'group:shaders', items: [pack, settings], children: [child] };
  const tree = { groups: [group], issues: [], directories: ['shaderpacks'], files: [], worlds: [] };
  const f = fixture({ tree }); await f.initialize();
  assert.equal(f.sheet.contentGroupCount_(group), 2); assert.equal(f.sheet.selectedEntryCount_(), 2);
  assert.equal(f.sheet.contentGroupState_(group), core.exportContentSelectionState(f.sheet.request_(), group));
  f.sheet.selectNode_(pack.id, false);
  assert.equal(f.sheet.contentItemSelected_(settings), core.isExportContentItemSelected(f.sheet.request_(), settings));
  assert.equal(f.sheet.contentGroupState_(child), core.exportContentSelectionState(f.sheet.request_(), child));
});

test('draft write revision prevents an old save from clearing a newer modification', async () => {
  const f = fixture(); await f.initialize(); f.sheet.selectNode_('item:resourcepacks/A.zip', false);
  let release; f.state.saveGate = new Promise(resolve => { release = resolve; });
  const pending = f.sheet.saveDraft_(); f.sheet.changed_(); release();
  assert.equal(await pending, false); assert.equal(f.sheet.dirty_, true); assert.match(f.sheet.notice_, /尚未保存/);
});

test('receiver restrictions remain PCL/HMCL adaptation and never introduce a neutral or bundled launcher', async () => {
  const f = fixture({ loader: 'neoforge' }); await f.initialize(); assert.equal(f.sheet.pclAllowed_(), true);
  f.sheet.chooseFormat_('modrinth'); assert.equal(f.sheet.launcher_, 'hmcl'); assert.equal(f.sheet.pclAllowed_(), false);
  assert.equal(f.sheet.request_().platform.os, 'windows'); assert.equal(f.sheet.request_().platform.arch, 'x64');
  assert(!('bundledLauncher' in f.sheet.request_()));
});

test('dirty close remains protected and failed draft save does not dismiss the sheet', async () => {
  const f = fixture(); await f.initialize(); f.sheet.selectNode_('item:resourcepacks/A.zip', false);
  f.sheet.requestClose_(); assert.equal(f.sheet.showLeaveConfirm_, true); assert.equal(f.state.closes, 0);
  f.state.saveError = new Error('ENOSPC'); await f.sheet.saveAndLeave_();
  assert.equal(f.state.closes, 0); assert.equal(f.sheet.showLeaveConfirm_, true); assert.match(f.sheet.error_, /ENOSPC/);
});

test('settings use a single virtualized scroll owner and preserve separate expand and select actions', () => {
  const member = name => sheetNode.members.find(node => node.name?.getText(sheetAst) === name)?.getText(sheetAst) ?? '';
  const configuration = member('Configuration'), navigation = member('NavigationPage');
  assert.match(configuration, /List\(\{ space:/); assert.match(configuration, /LazyForEach/); assert.doesNotMatch(configuration, /Scroll\(/);
  assert.equal((navigation.match(/this\.Configuration\(\)/g) ?? []).length, 1);
  assert(navigation.indexOf('this.Configuration()') < navigation.indexOf('Scroll()'));
  assert.match(member('ContentGroupRow'), /this\.selectNode_/); assert.match(member('ContentGroupRow'), /this\.toggleContentGroup_/);
  assert.match(member('ContentGroupRow'), /availability !== 'empty'/);
  assert.doesNotMatch(member('ContentItemRow'), /enabled\([^)]*available/);
});

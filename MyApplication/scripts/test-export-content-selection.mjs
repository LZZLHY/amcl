/**
 * 内容树与v2选择的实盘回归。生产SourceInspector/纯选择模块完整执行，FileIO映射外置
 * 真实文件；仅把摘要计算端口换成Node真实SHA，避免复制盘点/包含/排除算法。
 * 不访问用户游戏目录，所有读取量、错误注入及句柄释放可对账。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, resolveWorkspacePath } from './lib/workspace-paths.mjs';
import { productionPathPolicy } from './mod-install-test-runtime.mjs';

const idle = () => false;
const hex = (bytes, kind) => crypto.createHash(kind).update(bytes).digest('hex');

/** 每个fixture独占真实目录；权限故障只在指定SDK端口发生，不在测试侧预先决定选择结果。 */
function fixture() {
  const base = resolveWorkspacePath('run', 'export-content-selection-tests'); fs.mkdirSync(base, { recursive: true });
  const directory = fs.mkdtempSync(path.join(base, 'selection-'));
  const state = { hashes: [], stats: [], lists: [], failStat: new Set(), failList: new Set(), beforeList: null, beforeStat: null, listExtras: new Map() };
  const physical = virtual => {
    assert(virtual.startsWith('/'));
    const actual = path.resolve(directory, '.' + virtual);
    assert(actual === directory || actual.startsWith(directory + path.sep)); return actual;
  };
  const put = (virtual, bytes) => { fs.mkdirSync(path.dirname(physical(virtual)), { recursive: true }); fs.writeFileSync(physical(virtual), bytes); };
  const mkdir = virtual => fs.mkdirSync(physical(virtual), { recursive: true });
  const io = {
    async lstat(virtual) {
      state.stats.push(virtual);
      if (state.beforeStat) await state.beforeStat(virtual);
      if (state.failStat.has(virtual)) throw Object.assign(new Error('denied fixture path'), { code: 13900012 });
      try { const stat = fs.lstatSync(physical(virtual), { bigint: true }); return { ino: stat.ino, size: Number(stat.size),
        mtime: Number(stat.mtimeMs), ctime: Number(stat.ctimeMs), mtimeNs: stat.mtimeNs, ctimeNs: stat.ctimeNs,
        isFile: () => stat.isFile(), isDirectory: () => stat.isDirectory(), isSymbolicLink: () => stat.isSymbolicLink() }; }
      catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
    },
    async listFile(virtual) {
      state.lists.push(virtual); if (state.beforeList) await state.beforeList(virtual);
      if (state.failList.has(virtual)) throw Object.assign(new Error('denied fixture listing'), { code: 13900012 });
      if (state.listExtras.has(virtual)) return fs.readdirSync(physical(virtual)).concat(state.listExtras.get(virtual));
      return fs.readdirSync(physical(virtual));
    },
  };
  // 摘要端口仍打开真实文件且不跟末端链接，返回真实正文的两种摘要，不伪造“已核验”。
  const archive = { async hashExportFile(virtual, cancelled) {
    if (cancelled()) throw new Error('cancelled hash'); assert(!fs.lstatSync(physical(virtual)).isSymbolicLink());
    state.hashes.push(virtual); const fd = fs.openSync(physical(virtual), 'r');
    try { const bytes = fs.readFileSync(fd); return { size: bytes.length, sha1: hex(bytes, 'sha1'), sha256: hex(bytes, 'sha256') }; }
    finally { fs.closeSync(fd); }
  } };
  const modules = new Map();
  const load = relative => {
    if (modules.has(relative)) return modules.get(relative);
    const text = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const js = compiler.transpileModule(text, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo: io };
      if (name === '@kit.BasicServicesKit') return {};
      if (name === 'commons') return { resolveInstanceGameDir: (root, id, isolation) => isolation ? root + '/versions/' + id : root };
      if (name === './ExportArchiveIO') return archive;
      if (name === 'feature_core') return { ...load('feature_core/src/main/ets/export/ExportTypes.ets'),
        ...load('feature_core/src/main/ets/export/ExportPath.ets'), ...load('feature_core/src/main/ets/export/ExportContentSelection.ets'), ...productionPathPolicy() };
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('unexpected selection import ' + name);
    };
    new Function('exports', 'require', js)(exports, require); return exports;
  };
  const selection = load('feature_core/src/main/ets/export/ExportContentSelection.ets');
  const inspector = load('entry/src/main/ets/export/ExportSourceInspector.ets');
  const game = '/mc/versions/v'; mkdir(game);
  const request = (format = 'full') => ({ mcRoot: '/mc', versionId: 'v', gameDir: game, exportId: 'copy', displayName: 'copy', format,
    launcher: 'pcl', platform: { os: 'windows', arch: 'x64', version: '' }, includeDirectories: [], includeFiles: [], selectedWorlds: [], sharedGameDir: false });
  const selectedRequest = (files = [], directories = [], worlds = [], exclusions = []) => ({ ...request(), selectionVersion: 2,
    includeFiles: files, includeDirectories: directories, selectedWorlds: worlds, excludePaths: exclusions });
  const entries = tree => { const result = []; const visit = group => { result.push(...group.items); group.children.forEach(visit); }; tree.groups.forEach(visit); return result; };
  return { state, game, physical, put, mkdir, request, selectedRequest, selection, inspector, entries,
    close() { const actual = fs.realpathSync(directory); assert.equal(path.dirname(actual), fs.realpathSync(base));
      assert(path.basename(actual).startsWith('selection-')); fs.rmSync(actual, { recursive: true, force: true }); } };
}

test('discovery uses metadata only and exposes packages worlds unknown data and true empty groups', async () => {
  const f = fixture(); try {
    for (const name of ['mods/a.jar', 'mods/b.jar.disabled', 'resourcepacks/A.zip', 'resourcepacks/B/pack.mcmeta',
      'shaderpacks/S.zip', 'shaderpacks/S.zip.txt', 'saves/世界/level.dat', 'custom_mod/data.bin', 'options.txt']) f.put(f.game + '/' + name, name);
    f.mkdir(f.game + '/schematics');
    const tree = await f.inspector.discoverExportContentTree(f.request());
    assert.equal(tree.groups.length, 9); assert.equal(f.state.hashes.length, 0);
    const items = f.entries(tree); assert(items.some(item => item.path === 'resourcepacks/B' && item.kind === 'directory'));
    assert(items.some(item => item.path === 'saves/世界' && item.kind === 'world'));
    assert.equal(items.find(item => item.path === 'shaderpacks/S.zip.txt').associatedPath, 'shaderpacks/S.zip');
    assert.equal(tree.groups.find(group => group.id === 'group:maps').availability, 'empty');
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    assert(full.includeDirectories.includes('mods')); assert(full.includeDirectories.includes('custom_mod'));
    assert.deepEqual(full.selectedWorlds, ['世界']);
    const standard = f.selection.defaultExportContentSelection(f.request('modrinth'), tree);
    assert.equal(standard.selectedWorlds.length, 0); assert(!f.selection.isExportPathSelected(standard, 'mods/b.jar.disabled'));
  } finally { f.close(); }
});

/** 安装工作产物仅按已证实根级名称过滤；同名嵌套用户文件和未证实的伴随日志保留。 */
test('known root installer control paths are excluded without swallowing nested content or silently rewriting old drafts', async () => {
  const f = fixture(); try {
    const controlled = ['forge-install-temp', 'neoforge-installer.jar', 'forge-install-bootstrapper.jar'];
    f.put(f.game + '/forge-install-temp/maven/tool.jar', 'tool');
    for (const name of controlled.slice(1)) f.put(f.game + '/' + name, 'installer');
    for (const name of ['config/user.toml', 'config/neoforge-installer.jar', 'mods/forge-install-bootstrapper.jar',
      'config/forge-install-temp/user.txt', 'neoforge-installer.jar.log']) f.put(f.game + '/' + name, 'user');
    const request = f.request(), tree = await f.inspector.discoverExportContentTree(request);
    assert(controlled.every(name => !tree.directories.includes(name) && !tree.files.includes(name)));
    for (const name of controlled) {
      assert(f.inspector.isExportControlPath(name, request)); assert(f.inspector.isExportControlPath(name + '/child', request));
      assert(!f.inspector.isExportControlPath('config/' + name, request));
    }
    assert(tree.files.includes('neoforge-installer.jar.log'));
    const defaults = f.selection.defaultExportContentSelection(request, tree);
    const inventory = await f.inspector.inventoryExportContent(defaults, idle);
    const paths = inventory.map(item => item.path);
    assert(paths.includes('config/neoforge-installer.jar')); assert(paths.includes('mods/forge-install-bootstrapper.jar'));
    assert(paths.includes('config/forge-install-temp/user.txt')); assert(paths.includes('neoforge-installer.jar.log'));
    assert(!paths.some(item => controlled.some(name => item === name || item.startsWith(name + '/'))));

    for (const name of controlled) for (const selectionVersion of [undefined, 2]) {
      const old = f.selectedRequest(name.endsWith('.jar') ? [name] : [], name.endsWith('.jar') ? [] : [name]);
      if (selectionVersion === undefined) { delete old.selectionVersion; delete old.excludePaths; }
      const before = structuredClone(old), restored = f.selection.reconcileExportContentSelection(old, tree);
      assert.deepEqual(restored.request, before, '恢复草稿不得悄悄删掉历史选择意图');
      assert(restored.issues.some(issue => issue.code === 'CONTENT_SELECTION_CHANGED' && issue.path === name));
      await assert.rejects(f.inspector.inventoryExportContent(restored.request, idle), /控制目录/);
      // 只有显式恢复默认才移除当前不可导出控制项，并继续保留安全普通资料。
      const reset = f.selection.defaultExportContentSelection(restored.request, tree);
      assert(!reset.includeFiles.includes(name) && !reset.includeDirectories.includes(name));
    }
  } finally { f.close(); }
});

test('one selected ZIP or unpacked package is atomic and never exports its sibling', async () => {
  const f = fixture(); try {
    f.put(f.game + '/resourcepacks/A.zip', 'A'); f.put(f.game + '/resourcepacks/B/pack.mcmeta', 'B');
    const request = f.selectedRequest(['resourcepacks/A.zip']); const files = await f.inspector.inventoryExportContent(request, idle);
    assert.deepEqual(files.map(file => file.path), ['resourcepacks/A.zip']); assert.equal(files[0].sha256, hex(Buffer.from('A'), 'sha256'));
    const unpacked = await f.inspector.inventoryExportContent(f.selectedRequest([], ['resourcepacks/B']), idle);
    assert(unpacked.some(file => file.path === 'resourcepacks/B/pack.mcmeta')); assert(!unpacked.some(file => file.path.endsWith('A.zip')));
  } finally { f.close(); }
});

test('world selection exports the whole chosen directory and rejects partial world exclusions', async () => {
  const f = fixture(); try {
    f.put(f.game + '/saves/A/level.dat', 'level'); f.put(f.game + '/saves/A/region/r.mca', 'region'); f.put(f.game + '/saves/B/level.dat', 'other');
    const files = await f.inspector.inventoryExportContent(f.selectedRequest([], [], ['A']), idle);
    assert(files.some(file => file.path === 'saves/A/region/r.mca')); assert(!files.some(file => file.path.startsWith('saves/B')));
    await assert.rejects(f.inspector.inventoryExportContent(f.selectedRequest([], [], ['A'], ['saves/A/level.dat']), idle), /原子单元/);
  } finally { f.close(); }
});

test('standard config selection excludes unreadable JEI data before any read while full preserves the error', async () => {
  const f = fixture(); try {
    f.put(f.game + '/config/general.json', 'ordinary'); f.put(f.game + '/config/jei/world/personal.json', 'personal');
    const denied = f.game + '/config/jei/world'; f.state.failStat.add(denied);
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const broken = f.entries(tree).find(item => item.path === 'config/jei/world'); assert(broken && !broken.available);
    const standard = f.selection.defaultExportContentSelection(f.request('modrinth'), tree);
    assert(standard.excludePaths.includes('config/jei/world')); assert(!f.selection.hasUnresolvedSelectedErrors(standard, tree));
    f.state.stats = []; const files = await f.inspector.inventoryExportContent(standard, idle);
    assert(files.some(file => file.path === 'config/general.json')); assert(!f.state.stats.includes(denied));
    const full = f.selection.defaultExportContentSelection(f.request(), tree); assert(f.selection.hasUnresolvedSelectedErrors(full, tree));
    await assert.rejects(f.inspector.inventoryExportContent(full, idle), /denied/);
    const custom = f.selection.setExportContentSelection(full, tree, broken.id, false);
    assert(!f.selection.hasUnresolvedSelectedErrors(custom, tree)); assert(!f.selection.isExportContentAllSelected(custom, tree));
    assert((await f.inspector.inventoryExportContent(custom, idle)).some(file => file.path === 'config/general.json'));
  } finally { f.close(); }
});

test('optional unreadable screenshot category is an error rather than empty and does not block unselected standard content', async () => {
  const f = fixture(); try {
    f.put(f.game + '/screenshots/p.png', 'photo'); f.state.failList.add(f.game + '/screenshots');
    const tree = await f.inspector.discoverExportContentTree(f.request()); const media = tree.groups.find(group => group.id === 'group:media');
    assert.equal(media.availability, 'error'); assert(tree.issues.some(issue => issue.path === 'screenshots'));
    assert(!f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request('curseforge'), tree), tree));
    assert(f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request(), tree), tree));
    f.state.failList.clear(); const retried = await f.inspector.discoverExportContentTree(f.request());
    assert.equal(retried.groups.find(group => group.id === 'group:media').availability, 'available'); assert.equal(retried.issues.length, 0);
  } finally { f.close(); }
});

test('unreadable saves root keeps the full unresolved scope without inventing a world or allowing whole-tree execution', async () => {
  const f = fixture(); try {
    f.put(f.game + '/saves/A/level.dat', 'world'); f.state.failStat.add(f.game + '/saves');
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const error = f.entries(tree).find(item => item.path === 'saves'); assert(error && !error.available);
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    assert.equal(f.selection.validateExportSelection(full).length, 0);
    assert(f.selection.isExportContentItemSelected(full, error)); assert(f.selection.isExportContentAllSelected(full, tree));
    assert(f.selection.hasUnresolvedSelectedErrors(full, tree)); assert.equal(full.selectedWorlds.length, 0);
    assert(!f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request('modrinth'), tree), tree));
    const excluded = f.selection.setExportContentSelection(full, tree, error.id, false);
    assert(!f.selection.hasUnresolvedSelectedErrors(excluded, tree)); assert(!f.selection.isExportContentAllSelected(excluded, tree));
    f.state.failStat.clear();
    await assert.rejects(f.inspector.inventoryExportContent(full, idle), /控制目录或无效名称/);
    assert.equal(f.state.hashes.length, 0, '错误范围标记绝不成为可执行的全部世界授权');
  } finally { f.close(); }
});

test('full parent intent detects added files in the same inventory rather than freezing an old filename whitelist', async () => {
  const f = fixture(); try {
    f.put(f.game + '/mods/a.jar', 'a'); const tree = await f.inspector.discoverExportContentTree(f.request());
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    const before = await f.inspector.inventoryExportContent(full, idle);
    f.put(f.game + '/mods/new.jar', 'new'); const after = await f.inspector.inventoryExportContent(full, idle);
    assert.notDeepEqual(after, before); assert(after.some(file => file.path === 'mods/new.jar'));
    const exact = await f.inspector.inventoryExportContent(f.selectedRequest(['mods/a.jar']), idle);
    assert.deepEqual(exact.map(file => file.path), ['mods/a.jar']);
  } finally { f.close(); }
});

test('overlapping selected parent and child inventory each real file once and exclusions retain narrow semantics', async () => {
  const f = fixture(); try {
    f.put(f.game + '/config/a.json', 'a'); f.put(f.game + '/config/jei/world/p.json', 'p');
    const request = f.selectedRequest([], ['config', 'config/jei/world']); const files = await f.inspector.inventoryExportContent(request, idle);
    assert.equal(new Set(files.map(file => file.path)).size, files.length); assert.equal(f.state.hashes.filter(p => p.endsWith('/p.json')).length, 1);
    request.excludePaths = ['config/jei/world']; const narrow = await f.inspector.inventoryExportContent(request, idle);
    assert(!narrow.some(file => file.path.includes('/jei/world'))); assert(narrow.some(file => file.path === 'config/a.json'));
  } finally { f.close(); }
});

for (const kind of ['leaf', 'ancestor']) test(`selected ${kind} junction never reaches outside data or hashing`, async () => {
  const f = fixture(); try {
    f.put('/outside/secret', 'secret');
    if (kind === 'leaf') { f.mkdir(f.game + '/mods'); fs.symlinkSync(f.physical('/outside'), f.physical(f.game + '/mods/linked'), 'junction'); }
    else { fs.symlinkSync(f.physical('/outside'), f.physical(f.game + '/config'), 'junction'); }
    const request = kind === 'leaf' ? f.selectedRequest([], ['mods/linked']) : f.selectedRequest([], ['config']);
    await assert.rejects(f.inspector.inventoryExportContent(request, idle), /链接/); assert.equal(f.state.hashes.length, 0);
  } finally { f.close(); }
});

test('explicitly excluded linked subtree is not traversed and cannot leak through a broad parent', async () => {
  const f = fixture(); try {
    f.put(f.game + '/mods/a.jar', 'a'); f.put('/outside/secret', 'secret');
    fs.symlinkSync(f.physical('/outside'), f.physical(f.game + '/mods/linked'), 'junction');
    const files = await f.inspector.inventoryExportContent(f.selectedRequest([], ['mods'], [], ['mods/linked']), idle);
    assert(files.some(file => file.path === 'mods/a.jar')); assert(!files.some(file => file.path.includes('linked')));
    assert(f.state.hashes.every(source => !source.includes('linked')));
  } finally { f.close(); }
});

test('known account materials stay excluded even when full defaults select adjacent unknown mod data', async () => {
  const f = fixture(); try {
    f.put(f.game + '/essential/microsoft_accounts.json', 'private'); f.put(f.game + '/essential/general.json', 'ordinary');
    const tree = await f.inspector.discoverExportContentTree(f.request()); const full = f.selection.defaultExportContentSelection(f.request(), tree);
    const files = await f.inspector.inventoryExportContent(full, idle);
    assert(files.some(file => file.path === 'essential/general.json')); assert(!files.some(file => file.path.includes('accounts')));
    assert(!f.state.hashes.some(source => source.includes('accounts')));
  } finally { f.close(); }
});

test('v1 root scope remains legal but deep choices require v2 and root types are rechecked', async () => {
  const f = fixture(); try {
    f.put(f.game + '/mods/a.jar', 'a'); const old = f.request(); old.includeDirectories = ['mods'];
    assert((await f.inspector.inventoryExportContent(old, idle)).some(file => file.path === 'mods/a.jar'));
    old.includeDirectories = []; old.includeFiles = ['mods/a.jar']; await assert.rejects(f.inspector.inventoryExportContent(old, idle));
    await assert.rejects(f.inspector.inventoryExportContent(f.selectedRequest(['mods']), idle), /类型/);
    await assert.rejects(f.inspector.inventoryExportContent(f.selectedRequest(['mods/a.jar'], ['mods/a.jar']), idle), /同时/);
  } finally { f.close(); }
});

for (const unsafe of ['../escape', 'config/../../secret', '/outside/secret', 'mods\\a.jar', 'mods//a.jar', 'resourcepacks/A/inside.txt']) {
  test(`unsafe or partial atomic path rejects before payload reads: ${unsafe}`, async () => {
    const f = fixture(); try {
      await assert.rejects(f.inspector.inventoryExportContent(f.selectedRequest([unsafe]), idle)); assert.equal(f.state.hashes.length, 0);
    } finally { f.close(); }
  });
}

test('cancellation during directory SDK work rejects discovery instead of returning an empty tree', async () => {
  const f = fixture(); try {
    f.put(f.game + '/mods/a.jar', 'a'); let cancelled = false;
    f.state.beforeList = target => { if (target === f.game + '/mods') cancelled = true; };
    await assert.rejects(f.inspector.discoverExportContentTree(f.request(), () => cancelled), /取消/); assert.equal(f.state.hashes.length, 0);
  } finally { f.close(); }
});

/** 已在listFile枚举的来源消失是竞态，不能退化成“从未存在”而静默漏选。 */
test('an enumerated root file disappearing during unit stat remains an unresolved full scope', async () => {
  const f = fixture(); try {
    const file = f.game + '/options.txt'; f.put(file, 'selected content'); let visits = 0;
    f.state.beforeStat = target => { if (target === file && ++visits === 3) fs.unlinkSync(f.physical(file)); };
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const error = f.entries(tree).find(item => item.path === 'options.txt'); assert(error && !error.available);
    assert.equal(error.kind, 'file');
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    assert(full.includeFiles.includes('options.txt')); assert(f.selection.hasUnresolvedSelectedErrors(full, tree));
    f.state.beforeStat = null; f.put(file, 'selected content');
    assert((await f.inspector.inventoryExportContent(full, idle)).some(item => item.path === 'options.txt'));
    const custom = f.selection.setExportContentSelection(full, tree, error.id, false);
    assert(!f.selection.hasUnresolvedSelectedErrors(custom, tree)); assert(!f.selection.isExportContentAllSelected(custom, tree));
  } finally { f.close(); }
});

test('an enumerated package disappearing before its first unit stat is an error rather than empty', async () => {
  const f = fixture(); try {
    const file = f.game + '/resourcepacks/A.zip'; f.put(file, 'pack'); let removed = false;
    f.state.beforeStat = target => { if (target === file && !removed) { removed = true; fs.unlinkSync(f.physical(file)); } };
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const error = f.entries(tree).find(item => item.path === 'resourcepacks/A.zip'); assert(error && !error.available);
    assert(f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request(), tree), tree));
  } finally { f.close(); }
});

test('absent optional partitions stay absent but an observed partition disappearing during traversal stays unresolved', async () => {
  const f = fixture(); try {
    assert.equal((await f.inspector.discoverExportContentTree(f.request())).issues.length, 0);
    const folder = f.game + '/config/jei/world'; f.put(folder + '/history.json', 'personal'); let visits = 0;
    f.state.beforeStat = target => { if (target === folder && ++visits === 2) {
      fs.unlinkSync(f.physical(folder + '/history.json')); fs.rmdirSync(f.physical(folder));
    } };
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const error = f.entries(tree).find(item => item.path === 'config/jei/world'); assert(error && !error.available);
    assert(f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request(), tree), tree));
    assert(!f.selection.hasUnresolvedSelectedErrors(f.selection.defaultExportContentSelection(f.request('modrinth'), tree), tree));
  } finally { f.close(); }
});

/** 机械计数而非计时阈值，避免把机器快慢当成算法复杂度的证明。 */
test('many distinct roots compile and preserve unknown exclusions with path-depth bounded work', () => {
  const f = fixture(), original = String.prototype.startsWith; let comparisons = 0;
  try {
    const count = 1500, tree = f.selection.createExportContentTree(), items = [];
    for (let index = 0; index < count; index++) {
      const name = 'benchmark_dir_' + index; tree.directories.push(name);
      items.push({ id: 'item:' + name, path: name, label: name, kind: 'directory', defaultSelected: true, available: true, reason: '' });
    }
    tree.groups[tree.groups.length - 1].items = items;
    String.prototype.startsWith = function (prefix, ...rest) {
      if (typeof prefix === 'string' && original.call(prefix, 'benchmark_dir_')) comparisons++;
      return original.call(this, prefix, ...rest);
    };
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    assert.equal(full.includeDirectories.length, count);
    full.excludePaths = tree.directories.map(name => name + '/missing.json');
    const custom = f.selection.setExportContentSelection(full, tree, items[0].id, false);
    assert.equal(custom.includeDirectories.length, count - 1); assert.equal(custom.excludePaths.length, count - 1);
    assert(comparisons < count * 40, 'root与排除的分量比较必须随路径深度有界，实际=' + comparisons);
  } finally { String.prototype.startsWith = original; f.close(); }
});

test('reconciliation indexes a large current inventory once and keeps valid unknown historical intent', () => {
  const f = fixture(); try {
    const count = 1500, tree = f.selection.createExportContentTree(), files = [], items = []; let indexedReads = 0;
    for (let index = 0; index < count; index++) {
      const name = 'benchmark_file_' + index + '.json'; files.push(name);
      items.push({ id: 'item:' + name, path: name, label: name, kind: 'file', defaultSelected: true, available: true, reason: '', size: 1 });
    }
    tree.groups[tree.groups.length - 1].items = items;
    tree.files = new Proxy(files, { get(target, key, receiver) {
      if (typeof key === 'string' && /^\d+$/.test(key)) indexedReads++; return Reflect.get(target, key, receiver);
    } });
    const request = f.request(); request.includeFiles = files.concat(['missing.json']);
    const result = f.selection.reconcileExportContentSelection(request, tree);
    assert.equal(result.request.includeFiles.length, count + 1);
    assert(result.issues.some(issue => issue.path === 'missing.json' && issue.severity === 'warning'));
    assert(indexedReads < count * 40, '历史选择不能为每项重扫当前库存，实际=' + indexedReads);
  } finally { f.close(); }
});

test('one evaluator projects many package items and their associated settings without rebuilding request indexes', () => {
  const f = fixture(), OriginalSet = globalThis.Set; let inputs = 0;
  try {
    const count = 1500, request = f.selectedRequest(), items = [];
    for (let index = 0; index < count; index++) {
      const pack = 'shaderpacks/S' + index + '.zip'; request.includeFiles.push(pack, pack + '.txt');
      items.push({ id: 'item:' + pack + '.txt', path: pack + '.txt', associatedPath: pack, kind: 'file' });
    }
    globalThis.Set = class extends OriginalSet { constructor(values) { if (Array.isArray(values)) inputs += values.length; super(values); } };
    const evaluator = new f.selection.ExportContentSelectionEvaluator(request);
    assert(items.every(item => evaluator.isItemSelected(item)));
    assert(inputs <= count * 4, '批量行投影只能建立一次索引，实际=' + inputs);
  } finally { globalThis.Set = OriginalSet; f.close(); }
});

test('many shader sidecars bind exact packages through a single discovered-path index', async () => {
  const f = fixture(), original = Array.prototype.some; let scanned = 0;
  try {
    const count = 200;
    for (let index = 0; index < count; index++) {
      f.put(f.game + '/shaderpacks/S' + index + '.zip', 'pack'); f.put(f.game + '/shaderpacks/S' + index + '.zip.txt', 'setting');
    }
    Array.prototype.some = function (predicate, receiver) {
      const shaderItems = this.length > 0 && this[0]?.path?.startsWith('shaderpacks/');
      return original.call(this, (item, index, values) => { if (shaderItems) scanned++; return predicate.call(receiver, item, index, values); });
    };
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const settings = f.entries(tree).filter(item => item.path.endsWith('.txt'));
    assert.equal(settings.length, count); assert(settings.every(item => item.associatedPath === item.path.slice(0, -4)));
    assert(scanned < count * 40, '不能为每个设置遍历全部光影包，实际=' + scanned);
  } finally { Array.prototype.some = original; f.close(); }
});

/** 根级发现错误与正常子单元可以共存；取消未决根后只授权已确认的包/世界。 */
for (const kind of ['resourcepacks', 'saves']) test(`explicit ${kind} root error exclusion keeps confirmed children without reselecting the unresolved root`, async () => {
  const f = fixture(); try {
    const world = kind === 'saves', tree = f.selection.createExportContentTree(); tree.directories = [kind];
    const childPath = world ? 'saves/A' : 'resourcepacks/A.zip';
    f.put(f.game + '/' + (world ? childPath + '/level.dat' : childPath), 'confirmed');
    if (world) tree.worlds = ['A'];
    const group = tree.groups.find(group => group.id === (world ? 'group:worlds' : 'group:resourcepacks'));
    const good = { id: 'item:' + childPath, path: childPath, label: 'A', kind: world ? 'world' : 'file',
      defaultSelected: !world, available: true, reason: '' };
    const error = { id: 'item:' + kind, path: kind, label: kind, kind: 'directory',
      defaultSelected: !world, available: false, reason: 'partly unreadable category' };
    group.items = [error, good]; group.availability = 'error';
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    assert(f.selection.hasUnresolvedSelectedErrors(full, tree));
    const custom = f.selection.setExportContentSelection(full, tree, error.id, false);
    assert(!f.selection.isExportContentItemSelected(custom, error)); assert(f.selection.isExportContentItemSelected(custom, good));
    assert(!f.selection.hasUnresolvedSelectedErrors(custom, tree)); assert(!f.selection.isExportContentAllSelected(custom, tree));
    assert(!custom.includeDirectories.includes(kind), '不能重新扩展为未决根，也不能用根排除吞掉正常子项');
    const inventory = await f.inspector.inventoryExportContent(custom, idle);
    assert(inventory.some(file => file.path === childPath));
    const later = world ? 'saves/B/level.dat' : 'resourcepacks/B.zip'; f.put(f.game + '/' + later, 'not authorized');
    assert(!(await f.inspector.inventoryExportContent(custom, idle)).some(file => file.path === later), '排除错误根后仅保留已确认子范围');
  } finally { f.close(); }
});

test('real discovery partial root error can be excluded without discarding its known normal package', async () => {
  const f = fixture(); try {
    f.put(f.game + '/resourcepacks/A.zip', 'confirmed');
    // Harmony可出现而Windows宿主不能创建的名称仅在真实listFile端口追加，禁止预判选择结果。
    f.state.listExtras.set(f.game + '/resourcepacks', ['C:ghost']);
    const tree = await f.inspector.discoverExportContentTree(f.request());
    const error = f.entries(tree).find(item => item.path === 'resourcepacks' && !item.available); assert(error);
    const full = f.selection.defaultExportContentSelection(f.request(), tree);
    await assert.rejects(f.inspector.inventoryExportContent(full, idle), /不安全名称/, '宽选真实盘点必须拒绝错误，不依赖UI发现问题的替身');
    const custom = f.selection.setExportContentSelection(full, tree, error.id, false);
    assert(!f.selection.hasUnresolvedSelectedErrors(custom, tree));
    const inventory = await f.inspector.inventoryExportContent(custom, idle);
    assert(inventory.some(file => file.path === 'resourcepacks/A.zip')); assert(!inventory.some(file => file.path.includes('ghost')));
  } finally { f.close(); }
});

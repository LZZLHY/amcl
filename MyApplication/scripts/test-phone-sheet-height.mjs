/**
 * 手机 Sheet 高度的定向宿主回归。
 *
 * 执行真实尺寸函数和 PreferenceManager 单键事务，平台存储/设备查询是受控边缘。
 * 不访问用户数据，不替代 ArkTS 编译和设备布局验收；唯一输出是仓库外的小型收据。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

let sourceRoot = PROJECT_ROOT, requestedOutput;
for (let i = 2; i < process.argv.length; i++) {
  const option = process.argv[i++], value = process.argv[i];
  if (!['--source', '--output'].includes(option) || !value || !path.isAbsolute(value)) {
    throw new Error('仅接受 --source <绝对目录> 与 --output <仓外绝对目录>');
  }
  if (option === '--source') sourceRoot = path.resolve(value); else requestedOutput = value;
}
const S = 'commons/src/main/ets/common/SheetSizes.ets';
const P = 'feature_system/src/main/ets/PreferenceManager.ets';
const D = 'commons/src/main/ets/common/device/DeviceProfile.ets';
const U = 'entry/src/main/ets/components/PhoneSheetHeightSettings.ets';
const I = 'entry/src/main/ets/pages/Index.ets';
const T = 'entry/src/main/ets/pages/tabs/SettingsTab.ets';
const C = 'entry/src/main/ets/pages/tabs/SettingsCatalog.ets';
const sourceTexts = Object.fromEntries([S, P, D, U, I, T, C].map(file => [file, fs.readFileSync(path.join(sourceRoot, file), 'utf8')]));
const sha = value => createHash('sha256').update(value).digest('hex');
const initialHashes = Object.fromEntries(Object.entries(sourceTexts).map(([file, source]) => [file, sha(source)]));
const startedAt = new Date().toISOString(), groups = [];
const outputBase = assertExternalOutputPath(requestedOutput ?? resolveWorkspacePath('run', 'phone-sheet-height', { root: sourceRoot }), { root: sourceRoot });
const output = path.join(outputBase, 'run-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(output, { recursive: true });
const previousAppStorage = globalThis.AppStorage;
const appStorage = new Map([['screenHeightVp', 1000]]);
globalThis.AppStorage = { get: key => appStorage.get(key) };
const log = { warn() {}, info() {} };
const load = makePureEtsLoader({ '@ohos.deviceInfo': {}, '@ohos.display': {}, '@kit.PerformanceAnalysisKit': { hilog: log } }, sourceTexts);
const sizes = load(S), { DeviceForm: F, Breakpoint: B } = load(D);
const KEY = sizes.PHONE_SHEET_HEIGHT_STORAGE_KEY;
const settle = async () => { for (let i = 0; i < 28; i++) await Promise.resolve(); };

/** 暂停实际 flush 边缘，确认 getter 不泄露已 put 尚未确认的 Preferences 缓存。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/** 每组重建真实模块；同目录 manager 共用实际静态 owner，不同目录使用独立存储。 */
function fixture(initial = 80) {
  const stores = new Map(); let game = false;
  const context = owner => ({ preferencesDir: '/preferences/' + owner });
  const main = context('main');
  function storage(ctx = main) {
    if (stores.has(ctx.preferencesDir)) return stores.get(ctx.preferencesDir);
    const cache = new Map([['unrelated', 'keep']]);
    if (initial !== undefined) cache.set(KEY, initial);
    const disk = new Map(cache), flushes = [], calls = [];
    let rejectRollback = false;
    const store = {
      getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
      get: async (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
      put: async (key, value) => { calls.push(['put', key, value]); cache.set(key, value); },
      putSync: (key, value) => {
        calls.push(['putSync', key, value]);
        if (rejectRollback) { rejectRollback = false; throw new Error('rollback rejected'); }
        cache.set(key, value);
      },
      deleteSync: key => { calls.push(['deleteSync', key]); cache.delete(key); },
      flush: async () => {
        calls.push(['flush']); const values = new Map(cache), gate = flushes.shift();
        if (gate) await gate.promise;
        disk.clear(); for (const [key, value] of values) disk.set(key, value);
      },
    };
    const state = { store, cache, disk, flushes, calls, rejectNextRollback: () => { rejectRollback = true; } };
    stores.set(ctx.preferencesDir, state); return state;
  }
  const commons = { ...sizes, formatError: String,
    ProcessPreferences: { open: ctx => storage(ctx).store, isGameProcess: () => game } };
  const module = makePureEtsLoader({ commons, '@kit.PerformanceAnalysisKit': { hilog: log } }, sourceTexts)(P);
  return { manager: (ctx = main) => new module.PreferenceManager(ctx), storage, context, setGame: value => { game = value; } };
}

/**
 * 只抽取真实组件的非 Builder 成员，方法正文原样交给 SDK 宿主编译器执行。
 * SliderChangeMode 是原生事件枚举的受控边缘；测试不另写拖动阶段或保存决议。
 */
function editor(onSave = async () => {}) {
  const source = sourceTexts[U], ast = compiler.createSourceFile(U, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'change_'));
  assert.ok(owner, '真实手机 Sheet 编辑器必须可解析');
  const names = ['aboutToAppear', 'aboutToDisappear', 'onValue_', 'onActive_', 'change_', 'save_'];
  const body = names.map(name => {
    const member = owner.members.find(item => item.name?.getText(ast) === name);
    assert.ok(member, '真实组件方法：' + name); return member.getText(ast);
  }).join('\n');
  const modes = { Begin: 0, Moving: 1, End: 2, Click: 3 };
  const compiled = compiler.transpileModule('export class ActualEditor {\n' + body + '\n}', {
    fileName: U, reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const exports = {};
  new Function('exports', 'normalizePhoneSheetHeightPercent', 'SliderChangeMode', 'formatError', compiled.outputText)(
    exports, sizes.normalizePhoneSheetHeightPercent, modes, String);
  const view = new exports.ActualEditor();
  Object.assign(view, { value: 80, active: true, hostVisible: true, percent: 80, saving: false, saveError: '',
    mounted_: false, generation_: 0, onSave });
  view.aboutToAppear(); return { view, modes };
}

/** 执行生产类中指定方法；只注入平台及已有公共函数，不复制保存和布局判定。 */
function methods(file, names, globals = {}) {
  const ast = compiler.createSourceFile(file, sourceTexts[file], compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === names[0]));
  assert.ok(owner, '真实宿主方法所属类型：' + file);
  const body = names.map(name => {
    const member = owner.members.find(item => item.name?.getText(ast) === name);
    assert.ok(member, '真实宿主方法：' + name); return member.getText(ast);
  }).join('\n');
  const compiled = compiler.transpileModule('export class ActualHost {\n' + body + '\n}', {
    fileName: file, reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const exports = {};
  new Function('exports', ...Object.keys(globals), compiled.outputText)(exports, ...Object.values(globals));
  return exports.ActualHost;
}

/** 从设置页真实 Builder AST 取得组件 onSave；不运行布局 DSL 或另写一条替代接线。 */
function settingSaveCallback(view) {
  const ast = compiler.createSourceFile(T, sourceTexts[T], compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'PhoneSheetHeightContent_'));
  const member = owner.members.find(item => item.name?.getText(ast) === 'PhoneSheetHeightContent_');
  let callback;
  function visit(node) {
    if (node.kind === compiler.SyntaxKind.CallExpression && node.expression?.getText(ast) === 'PhoneSheetHeightSettings') {
      callback = node.arguments[0]?.properties?.find(property => property.name?.getText(ast) === 'onSave')?.initializer;
    }
    compiler.forEachChild(node, visit);
  }
  visit(member); assert.ok(callback, '真实手机高度组件 onSave 事件');
  const compiled = compiler.transpileModule('return (' + callback.getText(ast) + ');', {
    fileName: T, reportDiagnostics: true, compilerOptions: { target: compiler.ScriptTarget.ES2020 },
  });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  return new Function(compiled.outputText).call(view);
}

/** Index 用实际 PreferenceManager 提交，AppStorage spy 只记录真正的确认发布边缘。 */
function indexHost(f) {
  const publications = [], values = new Map([[KEY, 80]]);
  const AppStorage = { get: key => values.get(key), setOrCreate: (key, value) => { values.set(key, value); publications.push([key, value]); } };
  const Class = methods(I, ['savePhoneSheetHeight_'], { AppStorage, PHONE_SHEET_HEIGHT_STORAGE_KEY: KEY });
  const view = new Class(); view.getPrefManager_ = () => f.manager();
  return { view, publications, values };
}

async function group(name, run) { await run(); groups.push(name); console.log('PASS ' + name); }
let failure;
try {
  await group('比例读取规范与端点保持有效', () => {
    assert.equal(sizes.DEFAULT_PHONE_SHEET_HEIGHT_PERCENT, 80);
    for (const [raw, expected] of [[0, 50], [50, 50], [72, 70], [73, 75], [100, 100], [200, 100], [NaN, 80], [Infinity, 80]]) {
      assert.equal(sizes.normalizePhoneSheetHeightPercent(raw), expected);
    }
  });
  await group('手机横竖屏采用用户比例，非手机保留详情和登录策略', () => {
    for (const bp of [B.SM, B.MD, B.LG]) {
      assert.equal(sizes.detailSheetHeightForLayout(F.PHONE, bp, 20, 30, 50), 475);
      assert.equal(sizes.largeSheetHeightForLayout(F.PHONE, bp, 20, 30, 100), 950);
    }
    for (const form of [F.TABLET, F.PC]) {
      assert.equal(sizes.detailSheetHeightForLayout(form, B.SM, 20, 30, 50), 760);
      assert.equal(sizes.largeSheetHeightForLayout(form, B.SM, 20, 30, 50), 874);
      assert.equal(sizes.detailSheetHeightForLayout(form, B.LG, 20, 30, 100), 640);
      assert.equal(sizes.largeSheetHeightForLayout(form, B.LG, 20, 30, 100), 720);
    }
    appStorage.set(KEY, 65);
    assert.equal(sizes.detailSheetHeightForLayout(F.PHONE, B.SM, 20, 30), 618);
    appStorage.delete(KEY);
    assert.equal(sizes.largeSheetHeightForLayout(F.PHONE, B.SM, 20, 30), 760);
    appStorage.set('screenHeightVp', NaN);
    assert.equal(sizes.detailSheetHeightForLayout(F.PHONE, B.SM, 0, 0, 50), 400);
    appStorage.set('screenHeightVp', 1000);
  });
  await group('保存等待真实flush并向同目录新manager发布确认值', async () => {
    const f = fixture(), first = f.manager(), second = f.manager(), store = f.storage(), gate = deferred();
    store.flushes.push(gate); let completed = false;
    const task = first.savePhoneSheetHeightPercent(95).then(() => { completed = true; });
    await settle(); assert.equal(completed, false); assert.equal(store.cache.get(KEY), 95);
    assert.equal(first.phoneSheetHeightPercent, 80); assert.equal(second.phoneSheetHeightPercent, 80);
    gate.resolve(); await task;
    assert.equal(store.disk.get(KEY), 95); assert.equal(f.manager().phoneSheetHeightPercent, 95);
    assert.equal(store.disk.get('unrelated'), 'keep');
  });
  await group('连续同目录请求串行且不同owner互不阻塞', async () => {
    const f = fixture(), gate = deferred(), store = f.storage(); store.flushes.push(gate);
    const first = f.manager().savePhoneSheetHeightPercent(60);
    const last = f.manager().savePhoneSheetHeightPercent(100);
    await settle(); assert.deepEqual(store.calls.filter(call => call[0] === 'put').map(call => call[2]), [60]);
    const other = f.context('other'); await f.manager(other).savePhoneSheetHeightPercent(70);
    assert.equal(f.storage(other).disk.get(KEY), 70);
    gate.resolve(); await Promise.all([first, last]); assert.equal(store.disk.get(KEY), 100);
  });
  await group('flush失败恢复原确认值，首次失败恢复键缺失', async () => {
    for (const initial of [80, undefined]) {
      const f = fixture(initial), store = f.storage(), gate = deferred(); store.flushes.push(gate);
      if (initial === undefined) { store.cache.delete(KEY); store.disk.delete(KEY); }
      const failed = assert.rejects(f.manager().savePhoneSheetHeightPercent(90), /disk rejected/);
      await settle(); gate.reject(new Error('disk rejected')); await failed;
      assert.equal(f.manager().phoneSheetHeightPercent, 80);
      assert.equal(store.disk.has(KEY), initial !== undefined);
      assert.equal(store.disk.get('unrelated'), 'keep');
    }
  });
  await group('回滚失败继续保留屏障，同值重试实际写盘而不虚报成功', async () => {
    const f = fixture(), store = f.storage(), gate = deferred(); store.flushes.push(gate); store.rejectNextRollback();
    const failed = assert.rejects(f.manager().savePhoneSheetHeightPercent(90), /回滚尚未确认/);
    await settle(); gate.reject(new Error('disk rejected')); await failed;
    assert.equal(store.cache.get(KEY), 90); assert.equal(f.manager().phoneSheetHeightPercent, 80);
    await f.manager().savePhoneSheetHeightPercent(90);
    assert.equal(store.calls.filter(call => call[0] === 'put').length, 2);
    assert.equal(f.manager().phoneSheetHeightPercent, 90); assert.equal(store.disk.get(KEY), 90);
  });
  await group('无效输入与游戏快照拒绝写入，损坏读取安全回退', async () => {
    const f = fixture(), manager = f.manager();
    for (const value of [NaN, Infinity, 49, 101, 81]) await assert.rejects(manager.savePhoneSheetHeightPercent(value));
    f.setGame(true); await assert.rejects(manager.savePhoneSheetHeightPercent(90));
    assert.equal(f.storage().calls.length, 0);
    const malformed = fixture('wrong'); assert.equal(malformed.manager().phoneSheetHeightPercent, 80);
    const missingOwner = fixture(); await assert.rejects(missingOwner.manager({ preferencesDir: '' }).savePhoneSheetHeightPercent(90));
  });
  await group('滑块拖动不写盘，End与Click在同一提交中去重', async () => {
    const saves = [], gate = deferred();
    const { view, modes } = editor(value => { saves.push(value); return gate.promise; });
    view.change_(65, modes.Begin); view.change_(70, modes.Moving);
    assert.equal(view.percent, 70); assert.equal(saves.length, 0);
    view.change_(75, modes.End); view.change_(75, modes.Click); view.change_(95, modes.Moving);
    assert.deepEqual(saves, [75]); assert.equal(view.percent, 75); assert.equal(view.saving, true);
    view.value = 75; gate.resolve(); await settle();
    assert.equal(view.saving, false); assert.equal(view.percent, 75); assert.equal(view.saveError, '');
    view.change_(75, modes.Click); assert.equal(saves.length, 1);
  });
  await group('轨道点击独立保存，失败回到父层确认值并允许重试', async () => {
    const saves = []; let rejectSave = true;
    const { view, modes } = editor(async value => {
      saves.push(value); if (rejectSave) throw new Error('disk rejected'); view.value = value;
    });
    view.change_(90, modes.Click); await settle();
    assert.deepEqual(saves, [90]); assert.equal(view.saving, false); assert.equal(view.percent, 80);
    assert.match(view.saveError, /保存失败/);
    rejectSave = false; view.change_(90, modes.Click); await settle();
    assert.deepEqual(saves, [90, 90]); assert.equal(view.percent, 90); assert.equal(view.value, 90); assert.equal(view.saveError, '');
  });
  await group('隐藏丢弃未提交拖动，已交付保存继续且迟到结果不抢占新确认值', async () => {
    const gate = deferred(), saves = [];
    const { view, modes } = editor(value => { saves.push(value); return gate.promise; });
    view.change_(65, modes.Moving); view.active = false; view.onActive_();
    assert.equal(view.percent, 80); assert.equal(saves.length, 0);
    view.active = true; view.onActive_(); view.change_(90, modes.End);
    assert.deepEqual(saves, [90]);
    view.active = false; view.onActive_(); view.value = 70;
    gate.reject(new Error('late disk rejected')); await settle();
    assert.equal(view.saving, false); assert.equal(view.percent, 70); assert.equal(view.saveError, '');
    view.active = true; view.onActive_(); assert.equal(view.percent, 70);
  });
  await group('路由覆盖即使active仍true也丢弃移动草稿并拒绝迟到End或Click', async () => {
    const saves = [], { view, modes } = editor(async value => { saves.push(value); });
    view.change_(65, modes.Moving); assert.equal(view.percent, 65);
    view.hostVisible = false; view.onActive_();
    assert.equal(view.active, true); assert.equal(view.percent, 80);
    view.change_(65, modes.End); view.change_(65, modes.Click); await settle();
    assert.deepEqual(saves, []); assert.equal(view.percent, 80); assert.equal(view.saveError, '');
    view.hostVisible = true; view.onActive_(); view.change_(65, modes.Click); await settle();
    assert.deepEqual(saves, [65]);
  });
  await group('卸载不取消已派发保存，迟到成功或失败不改旧组件显示', async () => {
    for (const outcome of ['resolve', 'reject']) {
      const gate = deferred(), saves = [];
      const { view, modes } = editor(value => { saves.push(value); return gate.promise; });
      view.change_(100, modes.End); view.aboutToDisappear();
      const before = { percent: view.percent, saving: view.saving, error: view.saveError };
      if (outcome === 'resolve') gate.resolve(); else gate.reject(new Error('late disk rejected'));
      await settle(); assert.deepEqual(saves, [100]);
      assert.deepEqual({ percent: view.percent, saving: view.saving, error: view.saveError }, before);
      assert.equal(view.mounted_, false);
    }
  });
  await group('Index等待真实flush才发布手机高度，保存失败不发布', async () => {
    for (const succeeds of [true, false]) {
      const f = fixture(), host = indexHost(f), gate = deferred(); f.storage().flushes.push(gate);
      const task = host.view.savePhoneSheetHeight_(95);
      const completed = succeeds ? task : assert.rejects(task, /disk rejected/);
      await settle(); assert.equal(f.storage().cache.get(KEY), 95);
      assert.deepEqual(host.publications, []); assert.equal(host.values.get(KEY), 80);
      if (succeeds) gate.resolve(); else gate.reject(new Error('disk rejected'));
      await completed;
      assert.deepEqual(host.publications, succeeds ? [[KEY, 95]] : []);
      assert.equal(host.values.get(KEY), succeeds ? 95 : 80);
    }
  });
  await group('设置页真实onSave闭包串起编辑器、Index和耐久偏好', async () => {
    const f = fixture(), host = indexHost(f), gate = deferred(); f.storage().flushes.push(gate);
    const setting = { onPhoneSheetHeightSave: percent => host.view.savePhoneSheetHeight_(percent) };
    const { view, modes } = editor(settingSaveCallback(setting));
    view.change_(65, modes.Moving); assert.equal(f.storage().calls.length, 0);
    view.change_(65, modes.End); await settle();
    assert.equal(view.saving, true); assert.deepEqual(host.publications, []);
    gate.resolve(); await settle();
    assert.equal(view.saving, false); assert.equal(f.storage().disk.get(KEY), 65);
    assert.deepEqual(host.publications, [[KEY, 65]]); assert.equal(view.percent, 65);
  });
  await group('设置页真实SheetOptions采用手机高度并保留非手机呈现和关闭接线', () => {
    const catalog = makePureEtsLoader({}, sourceTexts)(C);
    const SheetType = { CENTER: 'center', BOTTOM: 'bottom' };
    const Class = methods(T, ['sheetOptions_'], { DeviceForm: F, Breakpoint: B, SheetType,
      SETTINGS_WIDE_WIDTH: catalog.SETTINGS_WIDE_WIDTH, detailSheetHeightForLayout: sizes.detailSheetHeightForLayout });
    const view = new Class(); let cancelled = 0, disappeared = 0, dismissed = 0;
    Object.assign(view, { deviceForm: F.PHONE, viewportWidth: 1000, bottomSafeHeight: 20, topSafeHeight: 30,
      phoneSheetHeightPercent: 95, theme: { bgPrimary: 'background' },
      cancelSheet_: () => { cancelled++; }, sheetDisappeared_: () => { disappeared++; } });
    const phone = view.sheetOptions_(); assert.equal(phone.height, 903); assert.equal(phone.preferType, SheetType.BOTTOM);
    assert.equal(phone.width, undefined); phone.onWillDismiss({ dismiss: () => { dismissed++; } }); phone.onDisappear();
    assert.deepEqual([cancelled, disappeared, dismissed], [1, 1, 1]);
    view.phoneSheetHeightPercent = 50; assert.equal(view.sheetOptions_().height, 475);
    view.deviceForm = F.TABLET;
    const tablet = view.sheetOptions_(); assert.equal(tablet.height, '80%'); assert.equal(tablet.preferType, SheetType.CENTER);
    assert.equal(tablet.width, 480);
  });
} catch (error) { failure = error; }
finally { if (previousAppStorage === undefined) delete globalThis.AppStorage; else globalThis.AppStorage = previousAppStorage; }

const finalHashes = Object.fromEntries(Object.keys(sourceTexts).map(file => [file, sha(fs.readFileSync(path.join(sourceRoot, file), 'utf8'))]));
const sourceStable = JSON.stringify(initialHashes) === JSON.stringify(finalHashes);
if (!sourceStable && !failure) failure = new Error('测试期间生产源变化，本轮结果不绑定新版本');
const receipt = { schemaVersion: 1, kind: 'source-bound-phone-sheet-height-host-tests', sourceRoot, startedAt,
  finishedAt: new Date().toISOString(), state: failure ? 'FAIL' : 'PASS', groups, sourceStable,
  sourceHashes: initialHashes, finalSourceHashes: finalHashes, failure: failure ? String(failure.stack ?? failure) : undefined,
  limitations: ['No ArkUI rendering or real Preferences IO', 'SDK build and real device layout require separate verification'] };
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
if (failure) { console.error(failure.stack ?? failure); process.exitCode = 1; }
console.log(JSON.stringify({ state: receipt.state, groups: groups.length, sourceStable, receipt: path.join(output, 'receipt.json') }));

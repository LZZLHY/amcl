/**
 * 全应用主题的定向宿主回归。
 *
 * 转译并执行真实 Theme、PreferenceManager、原生主题适配函数，以及 Index/ThemeSettings
 * 的非 Builder 方法。仅替换平台 Preferences、ThemeControl、AppStorage 与显示边缘；
 * 不执行 ArkUI DSL，不访问真实用户偏好，不代表 SDK、材质像素或设备验收通过。
 * --source 可绑定独占源码树；测试结束复核生产源摘要，变化时拒绝沿用中间结果。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const args = process.argv.slice(2);
let sourceRoot = PROJECT_ROOT, requestedOutput;
for (let i = 0; i < args.length; i++) {
  if (!['--source', '--output'].includes(args[i]) || !args[i + 1]) throw new Error('仅接受 --source <目录> 与 --output <仓外目录>');
  const flag = args[i++], value = args[i];
  if (!path.isAbsolute(value)) throw new Error(flag + ' 必须是绝对路径');
  if (flag === '--source') sourceRoot = path.resolve(value); else requestedOutput = value;
}
const T = 'commons/src/main/ets/common/Theme.ets';
const P = 'feature_system/src/main/ets/PreferenceManager.ets';
const N = 'entry/src/main/ets/components/AppTheme.ets';
const U = 'entry/src/main/ets/components/ThemeSettings.ets';
const I = 'entry/src/main/ets/pages/Index.ets';
const H = 'entry/src/main/ets/pages/tabs/HomeTab.ets';
const D = 'feature_core/src/main/ets/download/DownloadHistory.ets';
const S = 'entry/src/main/ets/components/ThemeScrollStyle.ets';
const G = 'entry/src/main/ets/components/GameResolutionGuard.ets';
const E = 'entry/src/main/ets/components/TouchEditorTheme.ets';
const production = [T, P, N, U, I, H, D, S, G, E];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const read = name => fs.readFileSync(path.join(sourceRoot, name), 'utf8');
const sourceTexts = Object.fromEntries(production.map(name => [name, read(name)]));
const sourceHashes = () => Object.fromEntries(production.map(name => [name, sha(fs.readFileSync(path.join(sourceRoot, name)))]));
const initialHashes = sourceHashes(), startedAt = new Date().toISOString(), groups = [], contrasts = [];
const base = assertExternalOutputPath(requestedOutput ?? resolveWorkspacePath('run', 'app-theme', { root: sourceRoot }), { root: sourceRoot });
const output = path.join(base, 'run-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(output, { recursive: true });
const plain = value => JSON.parse(JSON.stringify(value));
const selection = value => ({ mode: value.mode, accent: value.accent });
const settle = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };

/** 每组必须实际结束才计入通过；失败会由顶层保留原错误和已完成组。 */
async function group(name, action) { await action(); groups.push(name); console.log('PASS ' + name); }

/** 手动暂停某一次平台调用，模拟 flush 部分落盘/拒绝而不运行真实磁盘 IO。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/** 正常源和内存撤回负控都必须可转译，语法错误不能充当行为回归被识别。 */
function compile(source, fileName) {
  const result = compiler.transpileModule(source, { fileName, reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0, fileName);
  return result.outputText;
}

const theme = makePureEtsLoader({}, { [T]: sourceTexts[T] })(T);
const { ThemeMode: M, ThemeAccent: A, ThemeSelection, THEME_SELECTION_KEY: KEY } = theme;
assert.ok(A && ThemeSelection && KEY, '请选择包含本轮生产主题实现的 --source');
const options = theme.themeAccentOptions(), accents = options.map(option => option.id);

/** 颜色合同只检查真实可读角色对；禁用文字不伪报普通正文 AA，系统材质另行验收。 */
function rgb(color) {
  assert.match(color, /^#[0-9a-f]{6}$/i, '需要不透明成对角色：' + color);
  return [1, 3, 5].map(start => parseInt(color.slice(start, start + 2), 16) / 255);
}
function luminance(color) {
  const [r, g, b] = rgb(color).map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a, b) { const x = luminance(a), y = luminance(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }

/** 每个 fixture 都是独立进程模块；相同 preferencesDir 的 manager 使用真实静态 owner。 */
function fixture({ overrides = {}, absent = false, legacy = M.LIGHT } = {}) {
  for (const [name, text] of Object.entries(overrides)) compile(text, name);
  const stores = new Map(); let game = false;
  const context = owner => ({ filesDir: '/sandbox/' + owner, preferencesDir: '/preferences/' + owner });
  const main = context('main');
  const initial = new ThemeSelection(M.DARK, A.ROSE), encoded = theme.encodeThemeSelection(initial);
  function storage(ctx = main) {
    const directory = ctx.preferencesDir;
    if (stores.has(directory)) return stores.get(directory);
    const cache = new Map([['themeMode', legacy], ['unrelated', 'keep']]);
    if (!absent) cache.set(KEY, encoded);
    const disk = new Map(cache), calls = [], flushes = [], reads = [];
    let rejectPut = false, rejectRollback = false;
    const store = {
      getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
      get: async (key, fallback) => { const step = reads.shift(); if (step) await step.promise; return cache.has(key) ? cache.get(key) : fallback; },
      put: async (key, value) => { calls.push(['put', key, value]); cache.set(key, value);
        if (rejectPut) { rejectPut = false; throw new Error('put rejected'); } },
      putSync: (key, value) => { calls.push(['putSync', key, value]);
        if (key === KEY && rejectRollback) { rejectRollback = false; throw new Error('rollback put rejected'); }
        cache.set(key, value); },
      flush: async () => { calls.push(['flush']); const values = new Map(cache), step = flushes.shift();
        try { if (step) await step.promise; }
        catch (error) { if (step.partial) for (const [key, value] of values) disk.set(key, value); throw error; }
        for (const [key, value] of values) disk.set(key, value); },
    };
    const state = { store, cache, disk, calls, flushes, reads,
      rejectNextPut: () => { rejectPut = true; }, rejectNextRollback: () => { rejectRollback = true; } };
    stores.set(directory, state); return state;
  }
  const commons = { ...theme, ProcessPreferences: { open: ctx => storage(ctx).store, isGameProcess: () => game }, formatError: String };
  const load = makePureEtsLoader({ commons, '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } }, { ...sourceTexts, ...overrides });
  const PreferenceManager = load(P).PreferenceManager;
  return { manager: (ctx = main) => new PreferenceManager(ctx), storage, context, main, initial, encoded,
    setGame: value => { game = value; }, commons };
}

/** 只取得实际类成员，保留方法正文；宿主没有另一份主题预览/保存业务实现。 */
function members(file, names, globals = {}, text = sourceTexts[file]) {
  const ast = compiler.createSourceFile(file, text, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === names[0]));
  assert.ok(owner, '真实成员所属类型：' + file);
  const body = names.map(name => { const m = owner.members.find(member => member.name?.getText(ast) === name);
    assert.ok(m, '真实成员：' + name); return m.getText(ast); }).join('\n');
  const exports = {};
  new Function('exports', ...Object.keys(globals), compile('export class ActualMethods {\n' + body + '\n}', file))(exports, ...Object.values(globals));
  return exports.ActualMethods;
}

/** Index 的显示调用和进程通知是平台边缘；偏好仍由真实 manager 决定。 */
function indexView(f) {
  const revisions = new Map([['appThemeRevision', 0]]), paints = [];
  const Class = members(I, ['previewTheme_', 'saveThemeSelection_', 'onThemeRevision_'], {
    AppStorage: { get: key => revisions.get(key), setOrCreate: (key, value) => revisions.set(key, value) },
  });
  const page = new Class(); Object.assign(page, { startupAlive_: true, themeInitialized: true, themeSaving_: false,
    themeSaveCount_: 0, themeSaveSequence_: 0,
    themePreview_: undefined, confirmedThemeSelection: f.manager().themeSelection,
    themeMode: f.initial.mode, themeAccent: f.initial.accent, getPrefManager_: () => f.manager(),
    applyTheme: () => { paints.push({ mode: page.themeMode, accent: page.themeAccent }); } });
  return { page, revisions, paints };
}

/** 选择器只运行真实非Builder方法；即时显示与耐久保存由每个用例绑定到明确宿主。 */
function editorView(onPreview = () => {}, onSave = async () => {}) {
  const Class = members(U, ['aboutToAppear', 'aboutToDisappear', 'onConfirmed_', 'onActive_', 'requestSelection_',
    'selectMode_', 'selectAccent_', 'resetDraft_', 'saveSelection_', 'swatch_'], { ThemeSelection, ThemeMode: M, getTheme: theme.getTheme, formatError: String });
  const view = new Class(); Object.assign(view, { selection: new ThemeSelection(M.DARK, A.ROSE),
    theme: theme.getTheme(true, A.ROSE), active: true, hostVisible: true, saving: false, mounted_: false,
    generation_: 0, pendingRequests_: 0, saveError: '', onPreview, onSave });
  view.aboutToAppear(); return view;
}

/** 内存撤回仅替换指定成员里的一个语义边缘，不写生产文件或改变绑定的源摘要。 */
function mutateMember(file, memberName, transform) {
  const text = sourceTexts[file], ast = compiler.createSourceFile(file, text, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === memberName));
  const member = owner.members.find(node => node.name?.getText(ast) === memberName), before = member.getText(ast), after = transform(before);
  assert.notEqual(before, after, '撤回必须命中真实成员');
  const changed = text.slice(0, member.getStart(ast)) + after + text.slice(member.end); compile(changed, file); return changed;
}

let failed;
try {
  await group('四方案八套真实角色及正文/按钮/状态/分类对比度', () => {
    assert.deepEqual(new Set(accents), new Set(['rose', 'blue', 'teal', 'violet']));
    for (const dark of [false, true]) {
      const fills = new Set();
      for (const accent of accents) {
        const t = theme.getTheme(dark, accent); fills.add(t.actionPrimary);
        assert.equal(t.isDark, dark); assert.equal(t.accentId, accent);
        assert.equal(t.primary, t.actionPrimary); assert.equal(t.accent, t.actionText); assert.equal(t.tabActive, t.actionText);
        const pairs = [];
        for (const ink of ['textPrimary', 'textSecondary', 'textHint']) for (const bg of ['bgPrimary', 'bgCard', 'bgInput', 'bgElevated']) pairs.push([ink, bg, 4.5]);
        for (const bg of ['bgPrimary', 'bgCard', 'primaryLight']) pairs.push(['actionText', bg, 4.5]);
        pairs.push(['textOnPrimary', 'actionPrimary', 4.5], ['textOnPrimary', 'actionPressed', 4.5]);
        for (const state of ['success', 'warning', 'error']) pairs.push([state + 'Text', state + 'Bg', 4.5]);
        for (const [ink, bg] of [['taskMcBlue', 'taskMcBg'], ['taskModPurple', 'taskModBg'], ['taskShaderIndigo', 'taskShaderBg'],
          ['taskRpackPink', 'taskRpackBg'], ['taskDatapackTeal', 'taskDatapackBg'], ['taskModpackOrange', 'taskModpackBg'], ['taskJdkRedOrange', 'taskJdkBg']]) pairs.push([ink, bg, 4.5]);
        for (const bg of ['bgCard', 'bgInput']) pairs.push(['controlBorder', bg, 3]);
        for (const [ink, bg, minimum] of pairs) {
          const ratio = contrast(t[ink], t[bg]); contrasts.push({ accent, dark, ink, bg, foreground: t[ink], background: t[bg], ratio, minimum });
          assert.ok(ratio >= minimum, `${accent}/${dark ? 'dark' : 'light'} ${ink}/${bg}=${ratio.toFixed(3)} < ${minimum}`);
        }
      }
      assert.equal(fills.size, 4, '四个方案不是同色别名');
    }
    const reference = theme.getTheme(false, A.ROSE);
    for (const accent of accents) for (const role of ['successText', 'warningText', 'errorText', 'taskMcBlue', 'taskModPurple', 'taskRpackPink']) {
      assert.equal(theme.getTheme(false, accent)[role], reference[role], '换强调色不改状态/类别语义');
    }
  });

  await group('真实首页状态徽章前景与容器成对，不用ARGB尾部拼接污染色相', () => {
    const ActivityStatus = members(D, ['SUCCESS', 'FAILED', 'ABORTED', 'CRASHED']);
    const Home = members(H, ['activityStatusColor_', 'activityStatusBackground_'], { ActivityStatus });
    const home = new Home();
    for (const accent of accents) for (const dark of [false, true]) {
      home.theme = theme.getTheme(dark, accent);
      for (const status of ['running', 'interrupted', ActivityStatus.SUCCESS, ActivityStatus.FAILED,
        ActivityStatus.ABORTED, ActivityStatus.CRASHED]) {
        const foreground = home.activityStatusColor_(status), background = home.activityStatusBackground_(status);
        const ratio = contrast(foreground, background);
        contrasts.push({ accent, dark, ink: 'home-status/' + status, bg: 'paired-status-container',
          foreground, background, ratio, minimum: 4.5 });
        assert.ok(ratio >= 4.5, status + '/' + accent + '/' + dark);
      }
      assert.equal(home.activityStatusBackground_(ActivityStatus.SUCCESS), home.theme.successBg);
      assert.equal(home.activityStatusBackground_(ActivityStatus.FAILED), home.theme.errorBg);
      assert.equal(home.activityStatusBackground_(ActivityStatus.CRASHED), home.theme.errorBg);
    }
    assert.equal(sourceTexts[H].includes("activityStatusColor_(rec.status) + '1A'"), false);
  });

  await group('工具滚动条只在API22以上着色，旧系统保留原生行为', () => {
    for (const api of [20, 21, 22, 26]) {
      const load = makePureEtsLoader({ '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: api } } }, sourceTexts);
      const Style = load(S).ThemeScrollStyle, colors = [];
      new Style('#858B96').applyNormalAttribute({ scrollBarColor: color => colors.push(color) });
      assert.deepEqual(colors, api >= 22 ? ['#858B96'] : []);
    }
  });

  await group('新分辨率故障出口逐方案同步palette，不触碰轮询或输入状态', () => {
    const { editorPalette } = makePureEtsLoader({ commons: theme }, sourceTexts)(E);
    const Guard = members(G, ['syncPalette_'], { editorPalette });
    for (const accent of accents) for (const dark of [false, true]) {
      const guard = new Guard(); Object.assign(guard, { toolTheme: theme.getTheme(dark, accent),
        active: true, fatal: false, timer: 99, widthVp: 400, heightVp: 600 });
      guard.syncPalette_();
      assert.equal(guard.palette.accent, guard.toolTheme.actionText);
      assert.equal(guard.palette.accentFill, guard.toolTheme.actionPrimary);
      assert.equal(guard.palette.panel, guard.toolTheme.bgElevated);
      assert.deepEqual([guard.active, guard.fatal, guard.timer, guard.widthVp, guard.heightVp], [true, false, 99, 400, 600]);
    }
    assert.match(sourceTexts[G], /GameResolutionPanel\(\{ palette: this\.palette/);
  });

  await group('未知JSON/版本/字段安全解码与旧明暗迁移只读', () => {
    assert.equal(KEY, 'themeSelectionV1');
    for (const raw of ['', '{bad', 'null', '[]', '1', '"text"', '{}', '{"version":2,"mode":1,"accent":"blue"}']) {
      assert.deepEqual(selection(theme.decodeThemeSelection(raw, M.LIGHT)), { mode: M.LIGHT, accent: A.ROSE });
    }
    assert.deepEqual(selection(theme.decodeThemeSelection('{"version":1,"mode":99,"accent":"#ffffff"}', M.DARK)), { mode: M.SYSTEM, accent: A.ROSE });
    assert.deepEqual(selection(theme.decodeThemeSelection('{"version":1,"mode":"bad","accent":"teal"}', M.DARK)), { mode: M.DARK, accent: A.TEAL });
    for (const accent of accents) for (const mode of [M.LIGHT, M.DARK, M.SYSTEM]) {
      const value = new ThemeSelection(mode, accent); assert.deepEqual(selection(theme.decodeThemeSelection(theme.encodeThemeSelection(value))), selection(value));
    }
    const f = fixture({ absent: true, legacy: M.LIGHT });
    assert.deepEqual(selection(f.manager().themeSelection), { mode: M.LIGHT, accent: A.ROSE }); assert.equal(f.storage().calls.length, 0);
    assert.equal(f.storage().cache.has(KEY), false, '读取迁移不能偷偷落盘');
  });

  await group('显示模式优先级及独立主题/选择/预设快照', () => {
    for (const accent of accents) for (const system of [false, true]) {
      assert.equal(theme.resolveTheme(M.LIGHT, system, accent).isDark, false);
      assert.equal(theme.resolveTheme(M.DARK, system, accent).isDark, true);
      assert.equal(theme.resolveTheme(M.SYSTEM, system, accent).isDark, system);
    }
    const a = theme.getTheme(false, A.ROSE), b = theme.getTheme(false, A.ROSE); assert.notEqual(a, b);
    a.actionText = '#000000'; assert.notEqual(theme.getTheme(false, A.ROSE).actionText, '#000000');
    const decoded = theme.decodeThemeSelection(''); decoded.accent = A.BLUE;
    assert.equal(theme.decodeThemeSelection('').accent, A.ROSE);
    const first = theme.themeAccentOptions(); first[0].label = 'poison'; first.reverse();
    assert.equal(theme.themeAccentOptions()[0].id, A.ROSE); assert.notEqual(theme.themeAccentOptions()[0].label, 'poison');
  });

  await group('同owner等待flush并用确认getter屏蔽在途缓存', async () => {
    const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate); let completed = false;
    const requested = new ThemeSelection(M.LIGHT, A.BLUE), task = f.manager().saveThemeSelection(requested).then(() => { completed = true; });
    requested.accent = A.TEAL; await settle();
    assert.equal(completed, false); assert.deepEqual(selection(f.manager({ ...f.main }).themeSelection), selection(f.initial));
    assert.equal(JSON.parse(s.cache.get(KEY)).accent, A.BLUE, '入队请求已冻结，不引用后续改变的调用参数');
    assert.equal(s.disk.get(KEY), f.encoded); gate.resolve(); await task;
    assert.deepEqual(selection(f.manager().themeSelection), { mode: M.LIGHT, accent: A.BLUE });
    assert.equal(f.manager().themeMode, M.LIGHT); assert.equal(f.manager().themeAccent, A.BLUE);
    assert.equal(s.disk.get('themeMode'), M.LIGHT, '兼容旧键保持原值');
    const confirmed = f.manager().themeSelection; confirmed.accent = A.VIOLET; assert.equal(f.manager().themeAccent, A.BLUE);
  });

  await group('同目录跨manager串行与确认后同值幂等', async () => {
    const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
    const a = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
    const same = f.manager({ ...f.main }).saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
    const b = f.manager().saveThemeSelection(new ThemeSelection(M.DARK, A.TEAL)); await settle();
    assert.equal(s.calls.filter(c => c[0] === 'put').length, 1); gate.resolve(); await Promise.all([a, same, b]);
    assert.equal(s.calls.filter(c => c[0] === 'put').length, 2); assert.equal(JSON.parse(s.disk.get(KEY)).accent, A.TEAL);
    assert.ok(s.calls.filter(c => c[0] === 'put').every(c => c[1] === KEY), '两维选择只能写一个确认键');
  });

  await group('put与flush失败仅回滚本键并保留其他设置', async () => {
    for (const kind of ['put', 'flush']) {
      const f = fixture(), s = f.storage();
      if (kind === 'put') s.rejectNextPut(); else { const gate = deferred(); s.flushes.push(gate); queueMicrotask(() => gate.reject(new Error('flush rejected'))); }
      await assert.rejects(f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)), /rejected/);
      assert.equal(s.disk.get(KEY), f.encoded); assert.equal(s.cache.get(KEY), f.encoded);
      assert.deepEqual(s.calls.filter(c => c[0] === 'putSync'), [['putSync', KEY, f.encoded]]);
      assert.equal(s.disk.get('unrelated'), 'keep'); await f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
      assert.equal(f.manager().themeAccent, A.BLUE);
    }
  });

  await group('回滚put或flush未知保确认屏障，同值重试必须实际写盘', async () => {
    for (const kind of ['put', 'flush']) {
      const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); first.partial = true; s.flushes.push(first);
      if (kind === 'put') s.rejectNextRollback(); else s.flushes.push(rollback);
      const saving = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
      const rejected = assert.rejects(saving, /回滚尚未确认/); await settle(); first.reject(new Error('partial failure')); await settle();
      if (kind === 'flush') rollback.reject(new Error('rollback rejected')); await rejected;
      assert.equal(JSON.parse(s.disk.get(KEY)).accent, A.BLUE, '模拟真实部分落盘，getter不代表磁盘已恢复');
      assert.equal(f.manager({ ...f.main }).themeAccent, A.ROSE);
      const puts = s.calls.filter(c => c[0] === 'put').length;
      await f.manager().saveThemeSelection(new ThemeSelection(f.initial.mode, f.initial.accent));
      assert.equal(s.calls.filter(c => c[0] === 'put').length, puts + 1); assert.equal(s.disk.get(KEY), f.encoded);
    }
  });

  await group('后继事务等待原owner回滚，不同目录owner互不阻塞', async () => {
    const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); s.flushes.push(first, rollback);
    const a = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)), rejected = assert.rejects(a, /first rejected/);
    const b = f.manager().saveThemeSelection(new ThemeSelection(M.DARK, A.TEAL)); await settle(); first.reject(new Error('first rejected')); await settle();
    assert.equal(s.calls.filter(c => c[0] === 'put').length, 1); rollback.resolve(); await rejected; await b;
    assert.equal(f.manager().themeAccent, A.TEAL);
    const other = f.context('other'), sb = f.storage(other), ga = deferred(), gb = deferred(); s.flushes.push(ga); sb.flushes.push(gb);
    const ca = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.VIOLET)), cb = f.manager(other).saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)); await settle();
    assert.equal(sb.calls.filter(c => c[0] === 'put').length, 1); ga.resolve(); await ca;
    assert.equal(f.manager(other).themeAccent, A.ROSE); gb.resolve(); await cb; assert.equal(f.manager(other).themeAccent, A.BLUE);
  });

  await group('游戏只读、缺owner与非法选择在写入前拒绝，异步后再次核身份', async () => {
    const f = fixture(), manager = f.manager(), s = f.storage(); f.setGame(true);
    await assert.rejects(manager.saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)), /启动器/); assert.equal(s.calls.length, 0);
    f.setGame(false); await assert.rejects(f.manager({}).saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)), /启动器/);
    for (const value of [null, undefined, 7, { mode: 99, accent: A.BLUE }, { mode: M.DARK, accent: '#ffffff' }]) {
      await assert.rejects(manager.saveThemeSelection(value), /有效预设/);
    }
    const readGate = deferred(); s.reads.push(readGate); const task = manager.saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
    const rejected = assert.rejects(task, /身份已改变/); await settle(); f.setGame(true); readGate.resolve(); await rejected;
    assert.equal(s.calls.length, 0);
  });

  await group('saveAll保存游戏设置不覆盖主题新键或旧明暗键', async () => {
    const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
    const task = f.manager().saveThemeSelection(new ThemeSelection(M.SYSTEM, A.TEAL)); await settle();
    const pending = s.cache.get(KEY);
    f.manager().saveAll({ themeMode: M.DARK, mcVersion: 'fixture', useNewWindow: false, versionIsolation: true, mcXmx: 4096, jdkVersion: 'auto' });
    assert.equal(s.cache.get(KEY), pending); assert.equal(s.cache.get('themeMode'), M.LIGHT);
    assert.ok(s.calls.filter(c => c[0] === 'putSync').every(c => ![KEY, 'themeMode'].includes(c[1])));
    assert.equal(f.manager().themeAccent, A.ROSE); gate.resolve(); await task; assert.equal(f.manager().themeAccent, A.TEAL);
  });

  await group('原生适配传入成对明暗角色，去重不吞首次失败', () => {
    const calls = []; let fail = true;
    const load = makePureEtsLoader({ commons: theme, '@kit.ArkUI': { ThemeControl: { setDefaultTheme: value => {
      if (fail) { fail = false; throw new Error('platform rejected'); } calls.push(plain(value));
    } } } }, sourceTexts);
    const apply = load(N).applyNativeTheme; apply(theme.getTheme(false, A.ROSE)); assert.equal(calls.length, 0);
    apply(theme.getTheme(false, A.ROSE)); apply(theme.getTheme(true, A.ROSE)); assert.equal(calls.length, 1);
    for (const accent of accents.slice(1)) apply(theme.getTheme(false, accent)); assert.equal(calls.length, 4);
    const mapping = { brand: 'actionText', fontPrimary: 'textPrimary', fontSecondary: 'textSecondary',
      fontTertiary: 'textHint', fontFourth: 'disabledText', fontEmphasize: 'actionText', fontOnPrimary: 'textOnPrimary',
      iconPrimary: 'textPrimary', iconSecondary: 'textSecondary', iconEmphasize: 'actionText', iconOnPrimary: 'textOnPrimary',
      backgroundPrimary: 'bgPrimary', backgroundSecondary: 'bgSecondary', backgroundTertiary: 'bgElevated',
      backgroundEmphasize: 'actionPrimary', compBackgroundPrimary: 'bgCard', compBackgroundSecondary: 'bgInput',
      compBackgroundEmphasize: 'actionPrimary', compEmphasizeSecondary: 'primaryLight', compEmphasizeTertiary: 'primaryLight',
      interactiveFocus: 'actionText', interactiveSelect: 'primaryLight', warning: 'error', alert: 'warning', confirm: 'success' };
    calls.forEach((value, i) => { for (const [key, dark] of [['colors', false], ['darkColors', true]]) {
      const t = theme.getTheme(dark, accents[i]);
      for (const [nativeRole, appRole] of Object.entries(mapping)) assert.equal(value[key][nativeRole], t[appRole], key + '/' + nativeRole);
      for (const unsupported of ['primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer', 'secondaryContainer', 'onSecondaryContainer']) {
        assert.equal(Object.hasOwn(value[key], unsupported), false, '最低API20不能输出API26新增同名角色');
      }
    } });
  });

  await group('同进程Index重建首帧使用确认getter，不读取在途Preferences缓存', async () => {
    const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
    const pending = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE));
    await settle();
    assert.equal(JSON.parse(s.cache.get(KEY)).accent, A.BLUE, '反例必须已进入put后的缓存');
    const native = [];
    const Class = members(I, ['aboutToAppear'], { ThemeSelection, ThemeMode: M,
      ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0 } }, resolveTheme: theme.resolveTheme,
      applyNativeTheme: value => native.push(value.accentId), UiMotion: { reduced: () => false },
      ProductQa: {bindSurface(){},bind(){}} });
    const page = new Class(); Object.assign(page, { currentColorMode: 1, getPrefManager_: () => f.manager(),
      // 首帧用例只读取真实偏好确认态；挂载时注册的独立业务宿主不触发主题读取。
      bindShellSkills_(){}, bindSettingsSkill_(){}, bindLibrarySkill_(){}, onHomeTabVisibilityChanged_: () => {} });
    page.aboutToAppear();
    assert.equal(page.themeAccent, f.initial.accent);
    assert.equal(page.themeMode, f.initial.mode);
    assert.deepEqual(native, [f.initial.accent]);
    gate.resolve(); await pending;
  });

  await group('实际Index预览不写偏好，取消恢复确认主题', () => {
    const f = fixture(), { page, paints, revisions } = indexView(f);
    page.previewTheme_(new ThemeSelection(M.LIGHT, A.TEAL)); assert.equal(page.themeAccent, A.TEAL);
    assert.equal(page.confirmedThemeSelection.accent, A.ROSE); assert.equal(f.storage().calls.length, 0); assert.equal(revisions.get('appThemeRevision'), 0);
    page.previewTheme_(undefined); assert.equal(page.themeAccent, A.ROSE); assert.equal(paints.length, 2);
  });

  await group('预览期间外部确认的revision延后处理，取消恢复最新确认而非旧缓存', async () => {
    const f = fixture(), { page, paints } = indexView(f);
    page.previewTheme_(new ThemeSelection(M.LIGHT, A.TEAL));
    const before = paints.length;
    await f.manager().saveThemeSelection(new ThemeSelection(M.DARK, A.BLUE));
    page.onThemeRevision_();
    assert.equal(paints.length, before, '其他窗口确认不能抢占当前预览');
    assert.equal(page.themeRevisionPending_, true);
    page.previewTheme_(undefined);
    assert.equal(page.confirmedThemeSelection.accent, A.BLUE);
    assert.equal(page.themeAccent, A.BLUE);
    assert.equal(page.themeMode, M.DARK);
    assert.equal(page.themeRevisionPending_, false);
  });

  await group('实际Index应用等待真实flush后才更新确认值和revision，失败回退', async () => {
    const f = fixture(), s = f.storage(), { page, revisions } = indexView(f), gate = deferred(); s.flushes.push(gate);
    page.previewTheme_(new ThemeSelection(M.LIGHT, A.BLUE)); const task = page.saveThemeSelection_(new ThemeSelection(M.LIGHT, A.BLUE)); await settle();
    assert.equal(page.confirmedThemeSelection.accent, A.ROSE); assert.equal(revisions.get('appThemeRevision'), 0); assert.equal(page.themeSaving_, true);
    gate.resolve(); await task; assert.equal(page.confirmedThemeSelection.accent, A.BLUE); assert.equal(revisions.get('appThemeRevision'), 1);
    s.rejectNextPut(); page.previewTheme_(new ThemeSelection(M.DARK, A.VIOLET));
    await assert.rejects(page.saveThemeSelection_(new ThemeSelection(M.DARK, A.VIOLET)), /rejected/);
    assert.equal(page.themeAccent, A.BLUE); assert.equal(revisions.get('appThemeRevision'), 1); assert.equal(page.themeSaving_, false);
  });

  await group('实际Index外部revision不抢预览/保存；退役宿主不接受迟到显示写入', async () => {
    const f = fixture(), { page, paints, revisions } = indexView(f);
    page.previewTheme_(new ThemeSelection(M.LIGHT, A.TEAL)); const count = paints.length; page.onThemeRevision_(); assert.equal(paints.length, count);
    page.previewTheme_(undefined); page.themeSaving_ = true; page.onThemeRevision_(); assert.equal(paints.length, count + 1); page.themeSaving_ = false;
    await f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)); page.onThemeRevision_(); assert.equal(page.themeAccent, A.BLUE);
    const gate = deferred(); f.storage().flushes.push(gate); const pending = page.saveThemeSelection_(new ThemeSelection(M.DARK, A.VIOLET)); await settle();
    page.startupAlive_ = false; const old = plain(page.confirmedThemeSelection), oldPaints = paints.length; gate.resolve(); await pending;
    assert.deepEqual(plain(page.confirmedThemeSelection), old); assert.equal(paints.length, oldPaints); assert.equal(f.manager().themeAccent, A.VIOLET);
    assert.equal(revisions.get('appThemeRevision'), 1, '耐久owner仍可通知其他活跃页面');
  });

  await group('真实选择事件立即显示并等待真实flush保存，不再需要应用动作', async () => {
    const f = fixture(), gate = deferred(), { page } = indexView(f); f.storage().flushes.push(gate);
    const view = editorView(value => page.previewTheme_(value), value => page.saveThemeSelection_(value));
    view.selectAccent_(A.TEAL); await settle();
    assert.equal(page.themeAccent, A.TEAL); assert.equal(view.draftAccent, A.TEAL);
    assert.equal(f.manager().themeAccent, A.ROSE); assert.equal(view.pendingRequests_, 1);
    gate.resolve(); await settle();
    assert.equal(f.manager().themeAccent, A.TEAL); assert.equal(view.pendingRequests_, 0);
    assert.equal(page.themePreview_, undefined); assert.equal(view.saveError, '');
  });

  await group('快速连续换色/切模式在保存中全接受，早期确认不能抢占最后选择', async () => {
    const f = fixture(), first = deferred(), second = deferred(), { page, paints } = indexView(f);
    f.storage().flushes.push(first, second);
    const view = editorView(value => page.previewTheme_(value), value => page.saveThemeSelection_(value));
    view.selectAccent_(A.BLUE); view.saving = true; view.selectMode_(0); view.selectAccent_(A.VIOLET); await settle();
    assert.equal(view.pendingRequests_, 3); assert.equal(page.themeAccent, A.VIOLET); assert.equal(page.themeMode, M.LIGHT);
    assert.equal(view.draftAccent, A.VIOLET); assert.equal(view.draftMode, M.LIGHT);
    const afterLatestChoice = paints.length;
    first.resolve(); await settle();
    assert.equal(f.manager().themeAccent, A.BLUE); assert.equal(page.themeAccent, A.VIOLET);
    assert.equal(page.themeSaving_, true); assert.equal(paints.length, afterLatestChoice, '较早保存不重画旧颜色');
    second.resolve(); await settle();
    assert.equal(view.pendingRequests_, 0); assert.equal(page.themeSaving_, false);
    assert.deepEqual(selection(f.manager().themeSelection), { mode: M.LIGHT, accent: A.VIOLET });
    assert.equal(view.draftAccent, A.VIOLET); assert.equal(page.themePreview_, undefined);
  });

  await group('最新保存失败回到最近成功主题，再次选择可重试且旧失败不覆盖新选择', async () => {
    const f = fixture(), first = deferred(), second = deferred(), { page } = indexView(f);
    f.storage().flushes.push(first, second);
    const view = editorView(value => page.previewTheme_(value), value => page.saveThemeSelection_(value));
    view.selectAccent_(A.BLUE); view.selectAccent_(A.TEAL); await settle();
    first.resolve(); await settle(); second.reject(new Error('latest flush rejected')); await settle();
    assert.equal(f.manager().themeAccent, A.BLUE); assert.equal(page.themeAccent, A.BLUE);
    assert.equal(view.draftAccent, A.BLUE); assert.match(view.saveError, /latest flush rejected/);
    view.selectAccent_(A.TEAL); await settle();
    assert.equal(f.manager().themeAccent, A.TEAL); assert.equal(view.saveError, '');
    const old = deferred(), latest = deferred(), secondView = editorView(() => {}, value => value.accent === A.BLUE ? old.promise : latest.promise);
    secondView.selectAccent_(A.BLUE); secondView.selectAccent_(A.VIOLET);
    old.reject(new Error('old request rejected')); await settle();
    assert.equal(secondView.draftAccent, A.VIOLET); assert.equal(secondView.saveError, '');
    latest.resolve(); await settle(); assert.equal(secondView.draftAccent, A.VIOLET);
  });

  await group('Tab隐藏/宿主隐藏/卸载不撤销已选择主题或丢弃已派发保存', async () => {
    for (const exit of ['tab', 'host', 'unmount']) {
      const f = fixture(), gate = deferred(), { page } = indexView(f), calls = []; f.storage().flushes.push(gate);
      const view = editorView(value => { calls.push(value); page.previewTheme_(value); }, value => page.saveThemeSelection_(value));
      view.selectAccent_(A.TEAL); await settle();
      if (exit === 'unmount') view.aboutToDisappear();
      else { if (exit === 'tab') view.active = false; else view.hostVisible = false; view.onActive_(); }
      assert.equal(page.themeAccent, A.TEAL); assert.equal(calls.length, 1); assert.equal(calls[0].accent, A.TEAL);
      view.saveError = 'new-visible-generation'; gate.resolve(); await settle();
      assert.equal(f.manager().themeAccent, A.TEAL); assert.equal(page.themeAccent, A.TEAL);
      assert.equal(view.saveError, 'new-visible-generation', '离开后旧完成不能改写局部状态');
    }
  });

  await group('新选择器实例可在旧实例保存期间继续选择，最终按点击顺序持久化', async () => {
    const f = fixture(), gate = deferred(), { page } = indexView(f); f.storage().flushes.push(gate);
    const makeView = () => editorView(value => page.previewTheme_(value), value => page.saveThemeSelection_(value));
    const old = makeView(); old.selectAccent_(A.BLUE); old.aboutToDisappear();
    const fresh = makeView(); fresh.saving = true; fresh.selectAccent_(A.VIOLET); await settle();
    assert.equal(page.themeAccent, A.VIOLET); assert.equal(fresh.pendingRequests_, 1);
    gate.resolve(); await settle();
    assert.equal(f.manager().themeAccent, A.VIOLET); assert.equal(page.themeAccent, A.VIOLET);
    assert.equal(fresh.draftAccent, A.VIOLET); assert.equal(page.themeSaving_, false);
  });

  await group('真实模式/颜色事件仅拒绝隐藏资格，重复同值不写入，重进同步确认态', async () => {
    for (const blocked of ['active', 'hostVisible', 'mounted_']) {
      const previews = [], saves = [], view = editorView(value => previews.push(value), async value => saves.push(value));
      view[blocked] = false;
      const before = { mode: view.draftMode, accent: view.draftAccent };
      view.selectMode_(0); view.selectAccent_(A.TEAL);
      assert.deepEqual({ mode: view.draftMode, accent: view.draftAccent }, before, blocked);
      assert.equal(previews.length, 0, blocked); assert.equal(saves.length, 0, blocked);
    }
    const previews = [], saves = [], view = editorView(value => previews.push(value), async value => saves.push(value));
    view.selectAccent_(A.ROSE); view.selectMode_(1); assert.equal(saves.length, 0);
    view.saving = true; view.selectAccent_(A.TEAL); view.selectAccent_(A.TEAL); view.selectMode_(0); view.selectMode_(0);
    assert.equal(saves.length, 2); assert.equal(previews.length, 2); await settle();
    view.active = false; view.onActive_(); view.selection = new ThemeSelection(M.SYSTEM, A.BLUE); view.onConfirmed_();
    view.active = true; view.onActive_(); assert.equal(view.draftMode, M.SYSTEM); assert.equal(view.draftAccent, A.BLUE);
  });

  await group('撤回flush等待或确认getter屏障的负控必须被行为识别', async () => {
    const noAwait = mutateMember(P, 'saveThemeSelection', text => text.replace('await this.pref.flush();', 'this.pref.flush();'));
    const noBarrier = mutateMember(P, 'themeSelection', text => text.replace(/state !== undefined && state.original !== undefined\s*\? state.original : /, ''));
    for (const variant of [noAwait, noBarrier]) {
      const f = fixture({ overrides: { [P]: variant } }), gate = deferred(); f.storage().flushes.push(gate); let completed = false;
      const task = f.manager().saveThemeSelection(new ThemeSelection(M.LIGHT, A.BLUE)).then(() => { completed = true; }); await settle();
      const correct = !completed && f.manager().themeAccent === A.ROSE; gate.resolve(); await task;
      assert.equal(correct, false, '撤回关键机制必须破坏已证明的确认合同');
    }
  });
} catch (error) { failed = error; }

const finalHashes = sourceHashes(), sourceStable = JSON.stringify(initialHashes) === JSON.stringify(finalHashes);
if (!sourceStable && !failed) failed = new Error('测试期间生产源变化；本次结果不可用于新的冻结版本');
const receipt = { schemaVersion: 1, kind: 'source-bound-host-theme-tests', sourceRoot, startedAt, finishedAt: new Date().toISOString(),
  state: failed ? 'FAIL' : 'PASS', groups, groupCount: groups.length, paletteCount: 8, contrastChecks: contrasts,
  minimumTextContrast: Math.min(...contrasts.filter(v => v.minimum === 4.5).map(v => v.ratio)),
  sourceStable, sourceHashes: initialHashes, finalSourceHashes: finalHashes,
  harnessSha256: sha(fs.readFileSync(fileURLToPath(import.meta.url))), compilerVersion: compiler.version,
  compilerLoaderSha256: sha(fs.readFileSync(new URL('./lib/ets-compiler.mjs', import.meta.url))),
  failure: failed ? String(failed.stack ?? failed) : undefined,
  limitations: ['No ArkUI Builder or pixel rendering executed', 'No real preferences, SDK build, material capability or device interaction',
    'ThemeControl and AppStorage verified only at the invocation boundary; actual system appearance requires SDK/device evidence'] };
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
if (failed) { console.error(failed.stack ?? failed); process.exitCode = 1; }
console.log(JSON.stringify({ state: receipt.state, groups: groups.length, contrastChecks: contrasts.length,
  minimumTextContrast: receipt.minimumTextContrast, sourceStable, receipt: path.join(output, 'receipt.json') }));

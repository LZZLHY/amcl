/**
 * 执行固定作用域编辑器、版本详情接线和真实PreferenceManager。
 * 只替换Preferences与UIContext边界；保存队列、继承、确认屏障和旧续体判定均来自生产源码。
 * 所有故障与延迟注入都在存储边界，不以字符串匹配或另一套模型代替业务执行。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const EDITOR = 'entry/src/main/ets/components/GameResolutionSettings.ets';
const VERSION = 'entry/src/main/ets/components/VersionManagerSheet.ets';
const INDEX = 'entry/src/main/ets/pages/Index.ets';
const SETTINGS = 'entry/src/main/ets/pages/tabs/SettingsTab.ets';
const source = relative => fs.readFileSync(new URL('../' + relative, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
const ast = relative => compiler.createSourceFile(relative, source(relative), compiler.ScriptTarget.Latest, true);
const plain = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

/** 夹具只控制flush何时完成/拒绝，内存缓存与确认值屏障仍由原PreferenceManager维护。 */
class Store {
  values = new Map();
  gates = [];
  failures = 0;
  flushes = 0;
  getSync(key, fallback) { return this.values.has(key) ? this.values.get(key) : fallback; }
  putSync(key, value) { this.values.set(key, value); }
  async put(key, value) { this.putSync(key, value); }
  async get(key, fallback) { return this.getSync(key, fallback); }
  deleteSync(key) { this.values.delete(key); }
  async flush() {
    this.flushes++;
    if (this.failures > 0) { this.failures--; throw new Error('injected disk rejection'); }
    const gate = this.gates.shift();
    if (gate) await gate.promise;
  }
}
function deferred() {
  let release;
  const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}

/** 删除绘制Builder和装饰器后编译完整生产编辑器；数据快照类也直接取生产正文。 */
function editorTypes(PreferenceManager, helpers) {
  const tree = ast(EDITOR);
  const snapshot = tree.statements.find(n => n.name?.text === 'GameResolutionPreferenceSnapshot');
  const owner = tree.statements.find(n => n.name?.text === 'GameResolutionSettings');
  assert.ok(snapshot && owner);
  const members = owner.members.filter(n => n.name?.text !== 'build' && !n.getText(tree).includes('@Builder'))
    .map(n => n.getText(tree).replace(/@(Prop|State|Watch)(\([^\n]*?\))?\s*/g, '')).join('\n');
  const text = snapshot.getText(tree) + '\nexport class GameResolutionSettings {\n' + members + '\n}';
  const compiled = compiler.transpileModule(text, { compilerOptions: { target: compiler.ScriptTarget.ES2022, module: compiler.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
  const exports = {};
  new Function('exports', 'PreferenceManager', ...Object.keys(helpers), compiled.outputText)(exports, PreferenceManager, ...Object.values(helpers));
  return exports;
}

/** 从真实Builder提取组件参数表达式，执行实际父层箭头闭包，保留this绑定。 */
function props(relative, method, component, owner, bindings = {}, selected = undefined) {
  const tree = ast(relative);
  const container = tree.statements.find(n => n.members?.some(m => m.name?.text === method));
  const member = container?.members.find(n => n.name?.text === method);
  let call;
  const visit = node => {
    if (!call && node.kind === compiler.SyntaxKind.CallExpression && node.expression.getText(tree) === component) call = node;
    compiler.forEachChild(node, visit);
  };
  assert.ok(member, relative + ':' + method); visit(member); assert.ok(call, component);
  // 版本管理父层还会构造磁盘/下载等无关参数；定向回归只求值被测原属性，闭包正文不改写。
  const expression = selected === undefined ? call.arguments[0].getText(tree)
    : '{' + call.arguments[0].properties.filter(p => selected.includes(p.name?.getText(tree))).map(p => p.getText(tree)).join(',') + '}';
  const code = compiler.transpileModule('return (' + expression + ');', { compilerOptions: { target: compiler.ScriptTarget.ES2022 }, reportDiagnostics: true });
  assert.equal((code.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
  return new Function(...Object.keys(bindings), code.outputText).call(owner, ...Object.values(bindings));
}

/** 版本面板只执行被修改的真实方法；导航/磁盘扫描等相邻模块不在本用例中运行。 */
function versionView(load, write) {
  const tree = ast(VERSION), owner = tree.statements.find(n => n.name?.text === 'VersionManagerSheet');
  const names = ['loadVersionJvmArgsState', 'refreshVersionResolution_', 'versionResolutionLabel_', 'openDetailEditor_'];
  const members = names.map(name => { const member = owner.members.find(n => n.name?.text === name); assert.ok(member); return member.getText(tree); });
  const code = compiler.transpileModule('return class VersionProbe {' + members.join('\n') + '}', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const Type = new Function(code)();
  const view = Object.assign(new Type(), { detailVersion: 'A', currentVersion: 'HOME', currentStep: 'detail', mcDir: '/game-root', canRunGame: true,
    // 位移动效在独立导航回归执行；本夹具只桩UIContext边缘，真实入口仍决定当前步骤与编辑身份。
    pageMotion_: { moving: false, move() {} }, getUIContext: () => ({}), bottomSafeHeight: 24,
    loadVersionJvmArgs: () => '', loadVersionJdk: () => '17', loadVersionGameLang: () => '', loadVersionResolution: load, onSaveVersionResolution: write });
  view.loadVersionJvmArgsState('A');
  return view;
}

/** 每组重新加载生产类的静态owner表，防止上组未决写入或模拟进程角色串入本组。 */
async function fixture() {
  const pure = makePureEtsLoader();
  const policy = pure('commons/src/main/ets/common/GameResolutionPolicy.ets');
  const tokens = pure('commons/src/main/ets/utils/JvmArgumentTokens.ets');
  const languages = pure('commons/src/main/ets/common/GameLanguages.ets');
  const store = new Store();
  const load = makePureEtsLoader({ commons: { ...policy, ...languages, ProcessPreferences: { open: () => store, isGameProcess: () => false }, formatError: String },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } });
  const { PreferenceManager } = load('feature_system/src/main/ets/PreferenceManager.ets');
  const helpers = { ...policy, ...tokens, ...pure('entry/src/main/ets/launcherskill/LauncherSkillBus.ets'), formatError: String };
  const types = editorTypes(PreferenceManager, helpers);
  const manager = new PreferenceManager({ preferencesDir: '/editor-fixture' });
  await manager.saveResolutionScalePercent(75);
  manager.setVersionOverride('A', { xmx: 2048, jdkVersion: '17', customJvmArgs: '', gameLanguage: 'en_us' });
  manager.setVersionOverride('B', { xmx: 3072, jdkVersion: '21', customJvmArgs: '', gameLanguage: 'zh_cn', renderScalePercent: 83 });
  const parent = props(INDEX, 'VersionManagerBuilder', 'VersionManagerSheet', { getPrefManager_: () => manager },
    { ...helpers, GameResolutionPreferenceSnapshot: types.GameResolutionPreferenceSnapshot }, ['loadVersionResolution', 'onSaveVersionResolution']);
  const view = versionView(parent.loadVersionResolution, parent.onSaveVersionResolution);
  const makeEditor = (version = undefined) => {
    const editor = new types.GameResolutionSettings();
    editor.getUIContext = () => ({ getHostContext: () => ({ preferencesDir: '/editor-fixture' }) });
    if (version !== undefined) {
      view.detailVersion = version;
      view.openDetailEditor_('resolution');
      assert.equal(view.currentStep, 'resolution', '真实详情入口必须进入固定分辨率编辑步');
      Object.assign(editor, props(VERSION, 'DetailEditorStep_', 'GameResolutionSettings', view, types));
    }
    editor.aboutToAppear();
    return editor;
  };
  return { ...types, manager, store, view, parent, makeEditor };
}

let groups = 0;
async function group(name, run) { await run(); groups++; console.log('PASS ' + name); }

/** 执行真实Button链上的事件，节点身份来自生产id，不在测试中另写微调算法。 */
function editorButton(view, controlId) {
  const tree = ast(EDITOR), owner = tree.statements.find(n => n.name?.text === 'GameResolutionSettings');
  const builder = owner.members.find(n => n.name?.text === 'ResolutionCard_');
  const hasId = call => {
    let cursor = call;
    while (cursor?.kind === compiler.SyntaxKind.CallExpression && cursor.expression.kind === compiler.SyntaxKind.PropertyAccessExpression) {
      if (cursor.expression.name.text === 'id' && cursor.arguments[0]?.text === controlId) return true;
      cursor = cursor.expression.expression;
    }
    return false;
  };
  let callback;
  const visit = node => {
    if (node.kind === compiler.SyntaxKind.CallExpression && node.expression.kind === compiler.SyntaxKind.PropertyAccessExpression
      && node.expression.name.text === 'onClick' && hasId(node)) callback = node.arguments[0];
    compiler.forEachChild(node, visit);
  };
  visit(builder); assert.ok(callback, controlId);
  const code = compiler.transpileModule('return (' + callback.getText(tree) + ');', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  return new Function(code).call(view);
}

await group('全局页固定全局，草稿不写入，保存等待flush且重复点击只提交一次', async () => {
  const f = await fixture(), e = f.makeEditor();
  const globalProps = props(SETTINGS, 'ImmersiveTitleContent1_', 'GameResolutionSettings', { theme: {}, visible: true });
  assert.equal(globalProps.versionScope, undefined); assert.equal(globalProps.versionId, undefined);
  e.versionId = 'HOME'; e.reload(); e.selectDraft_(61);
  assert.equal(f.manager.resolutionScalePercent, 75); assert.equal(e.savedPreference, 75);
  const gate = deferred(); f.store.gates.push(gate); const before = f.store.flushes;
  const pending = e.save(61); await settle(); await e.save(50);
  assert.equal(e.saving, true); assert.equal(f.store.flushes, before + 1); assert.equal(f.manager.resolutionScalePercent, 75);
  gate.release(); await pending;
  assert.equal(f.manager.resolutionScalePercent, 61); assert.equal(e.savedPreference, 61);
  assert.equal(f.manager.getVersionOverride('HOME').renderScalePercent || 0, 0);
});

await group('管理非当前版本时只写detailVersion，继承与显式100%独立', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  assert.equal(e.versionId, 'A'); assert.equal(f.view.currentVersion, 'HOME');
  assert.equal(f.view.versionResolutionLabel_(), '跟随全局（75%）');
  e.selectDraft_(67); await e.save(67);
  assert.equal(f.manager.getVersionOverride('A').renderScalePercent, 67); assert.equal(f.manager.resolutionScalePercent, 75);
  assert.equal(f.manager.getVersionOverride('B').renderScalePercent, 83); assert.equal(f.view.versionResolutionLabel_(), '67%');
  await e.save(100); assert.equal(e.savedPreference, 100); assert.equal(e.confirmedEffective, 100);
  await e.save(0); assert.equal(e.savedPreference, 0); assert.equal(e.confirmedEffective, 75);
  assert.equal(f.manager.getVersionOverride('A').jdkVersion, '17'); assert.equal(f.manager.getVersionOverride('A').gameLanguage, 'en_us');
  await assert.rejects(f.parent.onSaveVersionResolution('', 50)); assert.equal(f.manager.resolutionScalePercent, 75);
});

await group('真实详情接线仅在resolution步可见，离开后编辑器撤销显示权且不接收迟到草稿', async () => {
  const f = await fixture();
  const detailProps = props(VERSION, 'DetailEditorStep_', 'GameResolutionSettings', f.view, f);
  assert.equal(detailProps.visible, false);
  const e = f.makeEditor('A');
  assert.equal(f.view.currentStep, 'resolution'); assert.equal(e.visible, true); assert.equal(e.ready, true);
  const draft = e.draft;
  for (const step of ['detail', 'list', 'jdk', 'language', 'jvm', 'resources']) {
    f.view.currentStep = step;
    const next = props(VERSION, 'DetailEditorStep_', 'GameResolutionSettings', f.view, f, ['visible']);
    assert.equal(next.visible, false, '分辨率显示不能借用其它详情子步：' + step);
    e.visible = next.visible; e.onVisibilityChanged_(); e.selectDraft_(50);
    assert.equal(e.ready, false); assert.equal(e.draft, draft);
  }
  assert.equal(f.manager.getVersionOverride('A').renderScalePercent || 0, 0);
});

await group('保存失败保留草稿/旧确认态，重试仍走原偏好owner', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  e.selectDraft_(73); f.store.failures = 1; await e.save(73);
  assert.equal(e.draft, 73); assert.equal(e.savedPreference, 0); assert.match(e.error, /保存失败/);
  assert.equal(f.manager.getVersionOverride('A').renderScalePercent || 0, 0);
  await e.save(73); assert.equal(e.savedPreference, 73); assert.equal(e.error, '');
});

await group('A保存未决时切B，新B保存不被A续体或finally覆盖', async () => {
  const f = await fixture(), e = f.makeEditor('A'), a = deferred(), b = deferred();
  f.store.gates.push(a, b); const first = e.save(59); await settle();
  f.view.detailVersion = 'B'; e.versionId = 'B'; e.reload(); e.selectDraft_(82); const second = e.save(82);
  a.release(); await first; await settle();
  assert.equal(e.versionId, 'B'); assert.equal(e.saving, true); assert.equal(e.savedPreference, 83);
  assert.doesNotMatch(e.message, /59%/); assert.equal(f.manager.getVersionOverride('A').renderScalePercent, 59);
  b.release(); await second; assert.equal(e.savedPreference, 82); assert.equal(e.saving, false);
  assert.equal(f.manager.getVersionOverride('B').renderScalePercent, 82);
});

await group('隐藏/换根/卸载撤销显示权，已授权保存仍可完成', async () => {
  for (const action of ['hide', 'root', 'unmount']) {
    const f = await fixture(), e = f.makeEditor('A'), gate = deferred();
    let callbacks = 0; e.onSaved = () => callbacks++;
    f.store.gates.push(gate); const pending = e.save(52); await settle();
    if (action === 'hide') { e.visible = false; e.onVisibilityChanged_(); }
    if (action === 'root') { e.ownerKey = '/other-root'; e.reload(); }
    if (action === 'unmount') e.aboutToDisappear();
    gate.release(); await pending;
    assert.equal(callbacks, 0); assert.equal(f.manager.getVersionOverride('A').renderScalePercent, 52);
    assert.doesNotMatch(e.message, /已保存 52%/);
  }
});

await group('空版本不回退为全局，A成功提示不会残留到B读取失败', async () => {
  const f = await fixture(), e = f.makeEditor('A'); await e.save(64);
  e.versionId = 'B'; e.loadPreference = () => { throw new Error('read rejected'); }; e.reload();
  assert.equal(e.ready, false); assert.equal(e.message, ''); assert.equal(e.confirmedLabel_(), '暂不可用');
  e.versionId = ''; e.reload(); await e.save(50);
  assert.equal(e.ready, false); assert.equal(f.manager.resolutionScalePercent, 75);
});

await group('读取失败或隐藏时的Slider/快捷档位迟到事件不能写草稿', async () => {
  const f = await fixture(), e = f.makeEditor('A'); const before = e.draft;
  e.visible = false; e.onVisibilityChanged_(); e.selectDraft_(50); assert.equal(e.draft, before);
  e.visible = true; e.reload(); e.selectDraft_(49); assert.equal(e.draft, before);
  e.selectDraft_(67.5); assert.equal(e.draft, before); e.selectDraft_(67); assert.equal(e.draft, 67);
});

await group('真实±1%按钮可精确到67%，边界不越界且不隐式保存', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  const increase = editorButton(e, 'resolution-increase'), decrease = editorButton(e, 'resolution-decrease');
  e.selectDraft_(66); increase(); assert.equal(e.draft, 67); decrease(); assert.equal(e.draft, 66);
  e.selectDraft_(100); increase(); assert.equal(e.draft, 100); e.selectDraft_(50); decrease(); assert.equal(e.draft, 50);
  assert.equal(f.manager.getVersionOverride('A').renderScalePercent || 0, 0);
  e.visible = false; e.onVisibilityChanged_(); increase(); assert.equal(e.draft, 50);
});

await group('游戏内apply只提交当局NAPI请求，不修改持久比例', async () => {
  const f = await fixture(), tree = ast('entry/src/main/ets/components/GameResolutionPanel.ets');
  const owner = tree.statements.find(n => n.name?.text === 'GameResolutionPanel');
  const methods = owner.members.filter(n => ['apply', 'requiresRestart'].includes(n.name?.text));
  const code = compiler.transpileModule('return class PanelProbe {' + methods.map(method => method.getText(tree)).join('\n') + '}', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const calls = []; const Type = new Function('testNapi', code)({ mcRequestResolutionScale: percent => { calls.push(percent); return true; } });
  const panel = Object.assign(new Type(), { active: true, draft: 50, refresh() {}, error: '',
    snapshot: { phase: 'confirmed', canRequest: true } });
  const before = plain([...f.store.values]); panel.apply();
  assert.deepEqual(calls, [50]); assert.deepEqual(plain([...f.store.values]), before);
  // 点击形成后资格变化或宿主离开，迟到回调不能向当前游戏提交。
  panel.snapshot.canRequest = false; panel.apply();
  panel.active = false; panel.snapshot.canRequest = true; panel.apply();
  assert.deepEqual(calls, [50]); assert.deepEqual(plain([...f.store.values]), before);
});

/**
 * 投影真实Builder链的属性和原事件。这里只替换UI枚举边缘；选中颜色、禁用条件、
 * 文案与保存回调均直接执行生产表达式，不在宿主重写一份渲染/保存规则。
 */
function controlProjection(view, method, controlId, bindings = {}) {
  const tree = ast(EDITOR), owner = tree.statements.find(n => n.name?.text === 'GameResolutionSettings');
  const member = owner.members.find(n => n.name?.text === method);
  const globals = { Color: { Transparent: 'transparent' }, VerticalAlign: { Center: 'center' },
    HorizontalAlign: { Start: 'start' }, TextAlign: { Center: 'center' }, BarState: { Auto: 'auto' },
    FlexWrap: { Wrap: 'wrap' }, ItemAlign: { Center: 'center' }, FlexAlign: { Start: 'start' },
    WordBreak: { BREAK_ALL: 'break-all' }, ...bindings };
  const evaluate = node => {
    if (!node) return undefined;
    const js = compiler.transpileModule('return (' + node.getText(tree) + ');',
      { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
    return new Function(...Object.keys(globals), js).call(view, ...Object.values(globals));
  };
  let found;
  const visit = node => {
    if (node.kind === compiler.SyntaxKind.CallExpression && node.expression.kind === compiler.SyntaxKind.PropertyAccessExpression
      && node.expression.name.text === 'id') {
      let id;
      try { id = evaluate(node.arguments[0]); } catch (error) { if (!(error instanceof ReferenceError)) throw error; }
      if (id === controlId) {
        assert.equal(found, undefined, '控件id必须唯一：' + controlId);
        let outer = node;
        while (outer.parent?.kind === compiler.SyntaxKind.PropertyAccessExpression
          && outer.parent.expression === outer && outer.parent.parent?.kind === compiler.SyntaxKind.CallExpression) outer = outer.parent.parent;
        const attrs = new Map(); let base = outer;
        while (base.kind === compiler.SyntaxKind.CallExpression && base.expression.kind === compiler.SyntaxKind.PropertyAccessExpression) {
          if (!attrs.has(base.expression.name.text)) attrs.set(base.expression.name.text, base.arguments);
          base = base.expression.expression;
        }
        found = { attrs, base, idNode: node };
      }
    }
    compiler.forEachChild(node, visit);
  };
  assert.ok(member, method); visit(member); assert.ok(found, controlId);
  return { attr: name => evaluate(found.attrs.get(name)?.[0]), has: name => found.attrs.has(name),
    argument: index => evaluate(found.base.arguments?.[index]), node: found.idNode };
}

await group('V14嵌入式只让正文滚动并固定安全区footer，全局默认内联不强占高度', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  const wiring = props(VERSION, 'DetailEditorStep_', 'GameResolutionSettings', f.view, f);
  assert.equal(wiring.embedded, true); assert.equal(wiring.bottomSafeHeight, 24);
  const inline = f.makeEditor();
  assert.equal(inline.embedded, false); assert.equal(inline.bottomSafeHeight, 0);
  const tree = ast(EDITOR), owner = tree.statements.find(n => n.name?.text === 'GameResolutionSettings');
  const build = owner.members.find(n => n.name?.text === 'build');
  const branch = build.body.statements.find(n => n.kind === compiler.SyntaxKind.IfStatement);
  const condition = compiler.transpileModule('return (' + branch.expression.getText(tree) + ');',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  assert.equal(new Function(condition).call(e), true);
  assert.equal(new Function(condition).call(inline), false);
  assert.equal(controlProjection(e, 'build', 'resolution-editor-embedded').attr('height'), '100%');
  assert.equal(controlProjection(inline, 'build', 'resolution-editor-inline').has('height'), false);
  const scroll = controlProjection(e, 'build', 'resolution-editor-scroll');
  const footer = controlProjection(e, 'build', 'resolution-editor-footer');
  assert.equal(scroll.attr('layoutWeight'), 1);
  assert.ok(footer.node.pos > scroll.node.end, '动作区必须在Scroll之后的独立兄弟节点');
  assert.deepEqual(footer.attr('padding'), { left: 16, right: 16, top: 12, bottom: 36 });
});

await group('真实主卡尺寸与选中态符合V14/V15，Slider原事件仍只修改草稿', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  e.theme = makePureEtsLoader()('commons/src/main/ets/common/Theme.ets').getTheme(false);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-main-card').attr('padding'), 20);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-draft-value').attr('fontSize'), 32);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-draft-state').argument(0), '拖动后保存生效');
  const slider = controlProjection(e, 'ResolutionCard_', 'resolution-preference-slider');
  assert.deepEqual(slider.argument(0), { value: 75, min: 50, max: 100, step: 1 });
  assert.equal(slider.attr('height'), 48); slider.attr('onChange')(67);
  assert.equal(e.draft, 67); assert.equal(e.savedPreference, 0); assert.equal(f.manager.resolutionScalePercent, 75);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-draft-state').argument(0), '调整中 · 尚未保存');
  e.saving = true;
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-draft-state').argument(0), '保存中…');
  e.saving = false;
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-range-min').argument(0), '50%');
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-range-max').argument(0), '100%');
  e.selectDraft_(75);
  const selected = controlProjection(e, 'ResolutionCard_', 'resolution-preset-75', { percent: 75 });
  const unselected = controlProjection(e, 'ResolutionCard_', 'resolution-preset-50', { percent: 50 });
  assert.equal(selected.attr('height'), 48); assert.equal(selected.attr('backgroundColor'), e.theme.primaryLight);
  assert.equal(unselected.attr('backgroundColor'), e.theme.bgInput);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-stepper').attr('height'), 56);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-decrease').attr('width'), 48);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-increase').attr('height'), 48);
  assert.equal(controlProjection(e, 'ResolutionCard_', 'resolution-stepper-description').attr('fontSize'), 14);
});

await group('最小72高确认卡按真实Flex换行投影，草稿不伪确认，状态/error保留14字号与原id', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  e.theme = makePureEtsLoader()('commons/src/main/ets/common/Theme.ets').getTheme(true);
  e.selectDraft_(51);
  const card = controlProjection(e, 'ConfirmedCard_', 'resolution-confirmed-card');
  assert.deepEqual(card.attr('constraintSize'), { minHeight: 72 });
  assert.equal(card.has('height'), false); assert.equal(card.has('onClick'), false);
  assert.deepEqual(card.attr('padding'), { left: 20, right: 20, top: 12, bottom: 12 });
  // SDK裸AST将组件尾部属性链与声明块分开；构造参数取真实Flex调用，不猜测尾链基节点。
  assert.equal(props(EDITOR, 'ConfirmedCard_', 'Flex', e,
    { FlexWrap: { Wrap: 'wrap' }, ItemAlign: { Center: 'center' }, FlexAlign: { Start: 'start' } }).wrap, 'wrap');
  const value = controlProjection(e, 'ConfirmedCard_', 'resolution-confirmed-value');
  assert.equal(value.argument(0), '跟随全局 · 75%');
  assert.equal(value.attr('fontSize'), 14); assert.equal(value.attr('flexShrink'), 0);
  assert.deepEqual(value.attr('constraintSize'), { maxWidth: '100%' });
  assert.equal(value.attr('wordBreak'), 'break-all');
  assert.equal(props(EDITOR, 'ResolutionContent_', 'SettingsHint', e).text, '仅调整此版本，下次启动生效。');
  assert.equal(controlProjection(e, 'ResolutionContent_', 'resolution-preference-status').attr('fontSize'), 14);
  e.ready = false; e.error = '读取失败';
  assert.equal(controlProjection(e, 'ConfirmedCard_', 'resolution-confirmed-value').argument(0), '暂不可用');
  const error = controlProjection(e, 'ResolutionContent_', 'resolution-preference-error');
  assert.equal(error.argument(0), '读取失败'); assert.equal(error.attr('fontSize'), 14);
});

await group('真实双按钮投影守住全局/版本文案和禁用态，原闭包仍保存比例或继承0', async () => {
  const f = await fixture(), e = f.makeEditor('A');
  e.theme = makePureEtsLoader()('commons/src/main/ets/common/Theme.ets').getTheme(false);
  const inherit = controlProjection(e, 'FooterActions_', 'resolution-preference-inherit');
  const save = controlProjection(e, 'FooterActions_', 'resolution-preference-save');
  assert.equal(inherit.argument(0), '跟随全局'); assert.equal(save.argument(0), '保存比例');
  assert.equal(inherit.attr('height'), 48); assert.equal(save.attr('height'), 48);
  e.selectDraft_(68); await save.attr('onClick')(); await settle();
  assert.equal(e.savedPreference, 68); assert.equal(f.manager.resolutionScalePercent, 75);
  await inherit.attr('onClick')(); await settle();
  assert.equal(e.savedPreference, 0); assert.equal(e.confirmedEffective, 75);
  e.saving = true;
  assert.equal(save.argument(0), '保存中…'); assert.equal(save.attr('enabled'), false); assert.equal(inherit.attr('enabled'), false);
  const global = f.makeEditor(); global.theme = e.theme;
  assert.equal(controlProjection(global, 'FooterActions_', 'resolution-preference-inherit').argument(0), '恢复默认');
});

console.log('game-resolution-editor: ' + groups + ' production groups passed');

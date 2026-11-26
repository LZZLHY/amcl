/**
 * 原生设置域的宿主行为回归：执行生产目录、组件非绘制方法和实际 UI 事件闭包。
 *
 * 默认读取本脚本所在仓库；AMCL_SETTINGS_TEST_ROOT 可将被测源码指定为另一续作树。
 * 平台策略、UIContext、原生 Scroller 和父层耐久回调是显式受控边缘，业务决议不复制。
 * 不执行 ArkUI Builder 或真实 Preferences/文件迁移，不代替 SDK 编译、HAP 与真机验证。
 * 本机运行请显式 --output 指向当前工作区任务目录；每次执行独占子目录，失败现场不会覆盖。
 */
import assert from 'node:assert/strict';
import { verifySkillCases } from './lib/skill-business-check.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const COMPONENT = 'entry/src/main/ets/pages/tabs/SettingsTab.ets';
const CATALOG = 'entry/src/main/ets/pages/tabs/SettingsCatalog.ets';
const PREFERENCES = 'feature_system/src/main/ets/PreferenceManager.ets';
const THEME = 'commons/src/main/ets/common/Theme.ets';
const SHEET_SIZES = 'commons/src/main/ets/common/SheetSizes.ets';
const DEVICE_PROFILE = 'commons/src/main/ets/common/device/DeviceProfile.ets';
const sourceRoot = path.resolve(process.env.AMCL_SETTINGS_TEST_ROOT || PROJECT_ROOT);
const outputIndex = process.argv.indexOf('--output');
if (outputIndex >= 0 && !process.argv[outputIndex + 1]) throw new Error('--output requires an external directory');
const outputBase = assertExternalOutputPath(outputIndex < 0
  ? resolveWorkspacePath('run', 'settings-ui', { root: sourceRoot }) : process.argv[outputIndex + 1], { root: sourceRoot });
const startedAt = new Date().toISOString();
const output = path.join(outputBase, 'run-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(path.join(output, 'sources'), { recursive: true });
const groups = [];
const snapshots = new Map();
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };

/** 保存每次受控异步边缘；宿主可以分别释放成功或失败，而生产方法仍执行真实 await。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/** 每组独立记录失败并继续其它组，最后统一返回非零；失败源码与错误栈完整落在外置目录。 */
async function group(name, run) {
  try { await run(); groups.push({ name, status: 'PASS' }); console.log('PASS ' + name); }
  catch (error) {
    groups.push({ name, status: 'FAIL', error: error.stack || String(error) });
    console.error('FAIL ' + name + '\n' + (error.stack || error));
  }
}

/** SDK 编译器读取生产类，不运行其 Builder；节点定位只用于抽取原有事件，未重写闭包正文。 */
function componentAst(source) {
  const ast = compiler.createSourceFile(COMPONENT, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'aboutToAppear'));
  assert.ok(owner, 'actual SettingsTab owner must be parsed');
  return { ast, owner };
}

/** 事件和控件 ID 的生产表达式都由同一编译器执行；宿主仅提供 ForEach 捕获的候选。 */
function expression(view, node, ast, scope = {}) {
  const compiled = compiler.transpileModule('return (function(){ return (' + node.getText(ast) + '); }).call(this);', {
    compilerOptions: { target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true,
  });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
  return new Function(...Object.keys(scope), compiled.outputText).call(view, ...Object.values(scope));
}

/** 遍历原方法 AST，返回满足条件的第一个节点；找不到事件属于测试失败，不能降级为假的回调。 */
function findInMethod(source, method, predicate) {
  const { ast, owner } = componentAst(source);
  const member = owner.members.find(item => item.name?.getText(ast) === method);
  assert.ok(member, 'actual method: ' + method);
  let match;
  const visit = node => {
    if (!match && predicate(node, ast)) match = node;
    compiler.forEachChild(node, visit);
  };
  visit(member);
  assert.ok(match, 'actual event in ' + method);
  return { node: match, ast };
}

/** 在 ArkUI 链式调用中读取真实 .id()，因此不依赖 Builder 中按钮排列顺序。 */
function chainHasId(view, call, ast, wanted, scope) {
  let node = call;
  while (node?.kind === compiler.SyntaxKind.CallExpression) {
    const callee = node.expression;
    if (callee?.kind !== compiler.SyntaxKind.PropertyAccessExpression) break;
    if (callee.name?.getText(ast) === 'id') {
      try { if (expression(view, node.arguments[0], ast, scope) === wanted) return true; }
      catch (_) { /* 其它 ForEach 项的局部变量不在本次捕获域中，不能冒充目标。 */ }
    }
    node = callee.expression;
  }
  return false;
}

/** 执行真实 .onClick/.onChange/.onAreaChange 闭包，可通过原控件 ID 精确选择目标。 */
function uiEvent(view, source, method, event, controlId, scope = {}) {
  const found = findInMethod(source, method, (node, ast) => node.kind === compiler.SyntaxKind.CallExpression
    && node.expression?.name?.getText(ast) === event
    && (!controlId || chainHasId(view, node, ast, controlId, scope)));
  const callback = found.node.arguments.find(arg => arg.kind === compiler.SyntaxKind.ArrowFunction);
  assert.ok(callback, 'actual ' + event + ' callback');
  return expression(view, callback, found.ast, scope);
}

/** 组件参数中的回调同样来自实际生产 AST，覆盖统一设置行和图形紧凑入口的真实 wiring。 */
function componentEvent(view, source, method, component, event, controlId) {
  const found = findInMethod(source, method, (node, ast) => {
    if (node.kind !== compiler.SyntaxKind.CallExpression || node.expression?.getText(ast) !== component) return false;
    const options = node.arguments[0];
    if (options?.kind !== compiler.SyntaxKind.ObjectLiteralExpression) return false;
    const property = name => options.properties.find(p => p.name?.getText(ast) === name);
    if (!property(event)) return false;
    return !controlId || (property('controlId') && expression(view, property('controlId').initializer, ast) === controlId);
  });
  const property = found.node.arguments[0].properties.find(p => p.name?.getText(found.ast) === event);
  return expression(view, property.initializer, found.ast);
}

/**
 * 只在平台边缘造数：生产目录函数由 load-pure-ets 执行，SettingsTab 则由既有组件宿主执行。
 * 跨树时 sourceOverrides 只替换为目标树的完整原文；同字节时不冒充负向 mutation。
 */
const developerModules = new Map();
function developerModule(product) {
  if (developerModules.has(product)) return developerModules.get(product);
  const relative = 'entry/src/' + (product === 'default' ? 'main' : product) + '/ProductDeveloperSettings.ets';
  const text = fs.readFileSync(path.join(sourceRoot, relative), 'utf8');
  // 运行真实产品模块的声明和重导出；只去掉不在宿主渲染的 ArkUI struct。
  const ast = compiler.createSourceFile(relative, text, compiler.ScriptTarget.Latest, true);
  const declarations = ast.statements.filter(node => !node.members).map(node => node.getText(ast)).join('\n');
  const imports = { commons: {} };
  if (product === 'store') imports['../sideload/ProductDeveloperSettings'] = developerModule('sideload');
  const module = makePureEtsLoader(imports, { [relative]: declarations })(relative);
  developerModules.set(product, module);
  return module;
}

function fixture(catalog, source, changes = {}, themeExports = {}, sheetExports = {}) {
  const capability = { run: true, store: false, publisher: true, touch: true, chooseInteraction: false, mobileInput:true,
    tabletProcess: false, nativeGamepad: false, developer: false, fixedRefreshRate: true, ...changes };
  const calls = { jvm: [], committedJvm: [], choices: [], storage: [], routes: [], back: [], pixels: [], rects: [], focusClears: 0 };
  let jvmGate, jvmFailure;
  let density = 2;
  let rectangle = id => ({ size: { width: 380, height: id === 'settings-content-scroll' ? 500 : 64 },
    windowOffset: { x: 0, y: id === 'settings-content-scroll' ? 200 : 800 },
    localOffset: { x: 0, y: id === 'settings-content-scroll' ? 99 : 7 } });
  class HostScroller {
    constructor() { this.calls = []; this.offset = { xOffset: 0, yOffset: 0 }; }
    currentOffset() { return { ...this.offset }; }
    scrollTo(options) { this.calls.push({ ...options }); this.offset = { xOffset: Number(options.xOffset), yOffset: Number(options.yOffset) }; }
  }
  const noop = () => {};
  const commons = {
    ...themeExports, ...sheetExports, ImmersiveLightPreferences: class {}, JDK_AUTO: 'auto',
    GAME_LANGUAGES: [{ code: 'zh_cn', label: '简体中文' }, { code: 'en_us', label: 'English' }],
    AppIconName: new Proxy({}, { get: (_, key) => key }),
    DiagnosticPolicy: { hasTestHooks: () => capability.developer },
    DistributionPolicy: { isStore: () => capability.store, allowPublisherServices: () => capability.publisher },
    dockLightModeLabel: String, gameLanguageLabel: String, floatingDockReserveHeight: () => 88,
  };
  const imports = {
    '@kit.BasicServicesKit': { deviceInfo: { get sdkApiVersion() { return capability.fixedRefreshRate ? 20 : 19; } } },
    './SettingsCatalog': catalog, 'launch': {},
    'entry/ProductDeveloperSettings': developerModule(changes.product ?? 'default'), 'entry/ProductTouchSettings': {},
    'entry/ProductInputProfile': { ProductInputProfile: { supportsTouchLayouts: () => capability.touch,
      canChooseInteraction: () => capability.chooseInteraction, canChooseMobileInput: () => capability.mobileInput, canChooseTabletProcess: () => capability.tabletProcess,
      canChooseNativeGamepad: () => capability.nativeGamepad } },
    '../../components/TouchLearningStore': { TouchLearningStore: class { request() { return true; } } },
  };
  for (const name of ['DesktopGamepadSettings', 'MobileglRendererSettings', 'AppIcon', 'LogRetentionSettings',
    'AnimatedPillBar', 'ThemeSettings', 'PhoneSheetHeightSettings', 'ImmersiveLightSettings', 'ImmersiveTitleScaffold', 'SettingsPrimitives']) imports['../../components/' + name] = {};
  const canonical = fs.readFileSync(path.join(PROJECT_ROOT, COMPONENT), 'utf8').replaceAll('\r\n', '\n');
  const normalized = source.replaceAll('\r\n', '\n');
  const host = environment({ commons, imports, sourceOverrides: canonical === normalized ? {} : { [COMPONENT]: () => normalized },
    globals: { Scroller: HostScroller, SheetType: { BOTTOM: 0, CENTER: 1 },
      SliderChangeMode: { Moving: 0, End: 1, Click: 2 }, Color: { White: '#fff', Transparent: 'transparent' } } });
  const { SettingsTab } = host.load(COMPONENT, true);
  const view = new SettingsTab();
  view.canRunGame = capability.run; view.visible = true; view.mcXmx = 4096;
  view.customJvmArgs = '-Doriginal=true'; view.jdkVersions = [{ version: '17' }, { version: '25', updateAvailable: true }];
  view.externalAvailable = true; view.selectedJdkVersion = '17';
  view.theme = { bgPrimary: '#f1f3f5', actionPrimary: '#006fe6', errorText: '#c34232' };
  const context = { getHostContext: () => ({ filesDir: '/host/files' }),
    getFocusController: () => ({ clearFocus: () => { calls.focusClears++; } }),
    getRouter: () => ({ pushUrl: value => { calls.routes.push(plain(value)); return Promise.resolve(); },
      getState: () => ({ name: calls.routes.at(-1)?.url ?? '' }) }),
    getPromptAction: () => ({ showToast: noop, showDialog: async () => ({ index: 0 }) }),
    getComponentUtils: () => ({ getRectangleById: id => { calls.rects.push(id); return rectangle(id); } }),
    px2vp: value => { calls.pixels.push(value); return value / density; } };
  const savedSettings = {java:'17',confirmed:true};
  view.readCommittedSettings=()=>({...savedSettings});
  view.getUIContext = () => context;
  view.onSectionBackReady = value => calls.back.push(value);
  view.onCustomJvmArgsChange = async value => {
    calls.jvm.push(value); if (jvmGate) await jvmGate.promise; if (jvmFailure) throw jvmFailure;
    calls.committedJvm.push(value); view.customJvmArgs = value;
  };
  for (const [property, name] of [['onJdkVersionChange', 'java'], ['onOhosFrameRateCapChange', 'frame'],
    ['onOhosFixedRefreshRateChange', 'fixed-refresh-rate'],
    ['onGameLanguageChange', 'language'], ['onMcSourceChange', 'mc-source'], ['onJdkSourceChange', 'jdk-source'],
    ['onModSourceChange', 'mod-source'], ['onJdkChannelChange', 'jdk-channel']]) view[property] = async value => { calls.choices.push([name, value]); savedSettings[name==='frame'?'frame-rate':name]=String(value); return true; };
  view.onStorageLocationChange = (...args) => calls.storage.push(args);
  view.aboutToAppear();
  return { view, calls, capability, host,
    gate: value => { jvmGate = value; }, fail: value => { jvmFailure = value; },
    rect: value => { rectangle = value; }, density: value => { density = value; } };
}

/** 主测试使用启动时源码快照；末尾复核文件身份，开发者同时修改生产方法会明确失败要求重跑。 */
async function main() {
  for (const relative of [CATALOG, COMPONENT, PREFERENCES, THEME, SHEET_SIZES, DEVICE_PROFILE]) {
    const source = fs.readFileSync(path.join(sourceRoot, relative), 'utf8');
    snapshots.set(relative, source);
    fs.writeFileSync(path.join(output, 'sources', path.basename(relative)), source);
  }
  const source = snapshots.get(COMPONENT);
  // 使用生产尺寸与设备枚举；只隔离硬件查询和屏幕缓存，不复制高度计算规则。
  globalThis.AppStorage = { get: key => key === 'screenHeightVp' ? 1000 : undefined };
  const pure = makePureEtsLoader({ '@ohos.deviceInfo': {}, '@ohos.display': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } } }, Object.fromEntries(snapshots));
  const catalog = pure(CATALOG);
  const sheetExports = { ...pure(SHEET_SIZES), ...pure(DEVICE_PROFILE) };
  const make = changes => fixture(catalog, source, changes, pure(THEME), sheetExports);

  await group('Skill 诊断导航只可到达当前产品装配的页面，运行权限仍须成立', async () => {
    const expected = { tools: 'DevToolsPage', gles: 'RenderPage', vulkan: 'VulkanPage', input: 'InputProbePage', desktop: 'DesktopDeveloperToolsPage' };
    for (const product of ['default', 'store', 'sideload', 'desktop']) {
      const { view, calls } = make({ product, developer: true });
      view.skillInteractive = () => true;
      for (const [tool, page] of Object.entries(expected)) {
        const allowed = product === 'default' ? tool !== 'desktop' : product === 'desktop' && tool === 'desktop';
        const before = calls.routes.length;
        const result = await view.runSettingsSkill_('openLauncherDiagnostic', {tool});
        assert.equal(result.state, allowed ? 'needsUser' : 'failed', product + '/' + tool);
        assert.equal(calls.routes.length, before + Number(allowed));
        if (allowed) assert.equal(calls.routes.at(-1).url, 'pages/' + page);
      }
    }
    const { view, calls } = make({ product: 'desktop', developer: false });
    view.skillInteractive = () => true;
    assert.equal((await view.runSettingsSkill_('openLauncherDiagnostic', {tool:'desktop'})).state,'failed');
    assert.equal(calls.routes.length,0);
  });

  await group('系统 Skill 从真实设置目录选择，拒绝无效档位、越权产品和非活动页面', async () => {
    const {view,calls,host,capability}=make();
    const bus=host.load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus;
    const owner={};
    view.skillInteractive=()=>true;
    bus.attach(owner,()=>true);
    view.aboutToAppear();
    const call=(name,args={})=>bus.call('settings',name,args);
    const sections=await call('findLauncherSettings',{query:'下载源'});
    assert.equal(sections.state,'ready');assert.ok(sections.items.some(i=>i.item==='mc-source'));assert.equal(calls.choices.length,0);
    view.ohosFrameRateCap=60;
    assert.equal((await call('setLauncherChoice',{item:'fixed-refresh-rate',value:'120'})).state,'failed');
    assert.equal((await call('setLauncherChoice',{item:'mc-source',value:'https://other.invalid'})).state,'failed');
    assert.equal((await call('setLauncherChoice',{item:'java',value:'25',extra:'x'})).state,'failed');
    assert.equal((await call('setLauncherChoice',{item:'java',value:'25'})).state,'ready');
    assert.deepEqual(calls.choices,[['java','25']]);
    capability.publisher=false;
    assert.equal((await call('setLauncherSwitch',{item:'acceleration',enabled:true})).state,'failed');
    view.skillInteractive=()=>false;
    assert.equal((await call('setLauncherChoice',{item:'mc-source',value:'official'})).state,'unavailable');
    assert.equal(calls.choices.length,1);
    bus.detach(owner);
  });
  await group('玩家与系统关闭隔离须确认；取消保持原值，重新开启使用原偏好所有者', async () => {
    const { view, host } = make();
    view.skillInteractive = () => true;
    let committed = true;
    const writes = [], dialogs = [];
    view.readCommittedSettings = () => ({ confirmed: true, isolation: committed });
    view.onVersionIsolationChange = async enabled => {
      writes.push(enabled);
      view.versionIsolation = committed = enabled;
      return true;
    };
    view.getUIContext().getPromptAction = () => ({
      showDialog(options) {
        const answer = deferred();
        dialogs.push({ options, answer });
        return answer.promise;
      },
    });
    const row = property => componentEvent(view, source, 'IsolationContent_', 'SettingsToggleRow', property, 'settings-item-isolation');
    const tap = row('onChange');
    tap(false);
    assert.equal(row('saving'), true, '等待决定时替换原生 Toggle，避免取消后显示未确认值');
    assert.deepEqual(writes, []);
    assert.match(dialogs[0].options.title, /关闭版本隔离/);
    for (const word of ['共用', '存档', '模组', '重新开启']) assert.ok(dialogs[0].options.message.includes(word));
    tap(false);
    assert.equal(dialogs.length, 1, '重复事件只弹一次');
    dialogs[0].answer.resolve({ index: 0 });
    await settle();
    assert.deepEqual(writes, []);
    assert.equal(row('saving'), false);
    assert.equal(row('value'), true);

    const bus = host.load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus;
    bus.attach(view, () => true);
    view.aboutToAppear();
    const call = enabled => bus.call('settings', 'setLauncherSwitch', { item: 'isolation', enabled });
    const rejected = call(false);
    await settle();
    assert.equal(dialogs[1].options.message, dialogs[0].options.message);
    dialogs[1].answer.reject(new Error('系统返回'));
    const cancelled = await rejected;
    assert.equal(cancelled.state, 'cancelled');
    assert.deepEqual(writes, []);

    const saved = call(false);
    await settle();
    dialogs[2].answer.resolve({ index: 1 });
    const result = await saved;
    assert.equal(result.enabled, false);
    assert.deepEqual(writes, [false]);
    verifySkillCases('setLauncherSwitch', result, cancelled, 'L060');
    tap(true);
    await settle();
    assert.equal(row('value'), true);
    assert.deepEqual(writes, [false, true]);
    assert.equal(dialogs.length, 3);

    tap(false);
    view.visible = false;
    view.syncSectionBack_();
    view.visible = true;
    dialogs[3].answer.resolve({ index: 1 });
    await settle();
    assert.deepEqual(writes, [false, true], '旧页面的确认不能提交到重新显示的设置页');

    tap(false);
    dialogs[4].answer.resolve({ index: 1 });
    await settle();
    assert.deepEqual(writes, [false, true, false]);
    assert.equal(row('value'), false);
    bus.detach(view);
  });
  await group('JVM 人工接力只回报该编辑的提交；存储拒绝、取消、过期引用可分辨',async()=>{
    const {view,host,calls}=make();
    view.skillInteractive=()=>true;
    const bus=host.load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus;
    bus.attach(view,()=>true);
    view.aboutToAppear();
    const call=(name,args={})=>bus.call('settings',name,args);
    const first=await call('openLauncherSetting',{item:'jvm'});
    assert.equal(first.state,'needsUser');assert.ok(first.reference);
    view.jvmArgsDraft='-Dtest=true';
    await view.saveCustomJvmArgs();
    assert.deepEqual(calls.committedJvm,['-Dtest=true']);
    const original=await call('readSettingHandoff',{reference:first.reference});
    assert.equal(original.outcome,'saved');
    assert.ok(!JSON.stringify(original).includes('-Dtest'));
    view.sheetDisappeared_();
    const second=await call('prepareStorageChange',{target:'external'});
    assert.equal(second.state,'needsUser');
    const expired=await call('readSettingHandoff',{reference:first.reference});
    assert.equal(expired.state,'failed');
    await call('navigateLauncherSettings',{section:'back'});
    view.sheetDisappeared_();
    assert.equal(calls.storage.length,0);
    assert.equal((await call('readSettingHandoff',{reference:second.reference})).outcome,'cancelled');
    const third=await call('prepareStorageChange',{target:'external'});
    view.confirmStorage_(true);view.sheetDisappeared_();
    assert.equal(calls.storage.length,1);const [location,migrate,complete]=calls.storage[0];
    assert.equal(location,'external');assert.equal(migrate,true);complete('permissionDenied');
    const denied=await call('readSettingHandoff',{reference:third.reference});
    assert.equal(denied.outcome,'permissionDenied');assert.equal(denied.selectedTarget,'external');
    const changed=await call('prepareStorageChange',{target:'external'});
    view.choiceDraft='sandbox';view.confirmStorage_(false);view.sheetDisappeared_();
    assert.equal(calls.storage[1][0],'sandbox');calls.storage[1][2]('saved');
    const revised=await call('readSettingHandoff',{reference:changed.reference});
    assert.equal(revised.requestedTarget,'external');assert.equal(revised.selectedTarget,'sandbox');
    assert.equal(revised.outcome,'changedTarget');verifySkillCases('readSettingHandoff',revised,expired);
    const same=await call('prepareStorageChange',{target:'external'});
    view.confirmStorage_(false);view.sheetDisappeared_();calls.storage[2][2]('saved');
    const saved=await call('readSettingHandoff',{reference:same.reference});
    assert.equal(saved.outcome,'saved');assert.equal(saved.requestedTarget,saved.selectedTarget);
    // 无指定目标的普通编辑不应沿用上一个请求的位置。
    const manual=await call('openLauncherSetting',{item:'storage'});
    const draft=await call('readSettingHandoff',{reference:manual.reference});
    assert.equal(draft.requestedTarget,undefined);assert.equal(draft.selectedTarget,undefined);
    bus.detach(view);
  });

  await group('目录能力矩阵、unique ids与管理态边界', () => {
    const keys = ['run', 'store', 'publisher', 'touch', 'chooseInteraction', 'mobileInput', 'tabletProcess', 'nativeGamepad', 'developer', 'fixedRefreshRate'];
    for (let mask = 0; mask < (1 << keys.length); mask++) {
      const c = Object.fromEntries(keys.map((key, bit) => [key, Boolean(mask & (1 << bit))]));
      const sections = catalog.settingsSections(c), items = catalog.settingsItems(c);
      const ids = new Set(items.map(item => item.id));
      assert.equal(ids.size, items.length); assert.equal(new Set(sections.map(section => section.id)).size, sections.length);
      const sectionsAllowed = new Set([...sections.map(section => section.id), 'ledger', 'about', 'software-update']);
      assert.ok(items.every(item => sectionsAllowed.has(item.section)));
      for (const id of ['memory', 'virtual-memory', 'java', 'jvm', 'frame-rate', 'language', 'graphics', 'resolution', 'jdk-source', 'jdk-update']) assert.equal(ids.has(id), c.run, id);
      for (const id of ['input', 'layouts', 'touch-help']) assert.equal(ids.has(id), c.run && c.touch, id);
      assert.equal(ids.has('interaction'), c.run && c.chooseInteraction);
      assert.equal(ids.has('mobile-input'), c.run && c.touch && c.mobileInput);
      assert.equal(ids.has('fixed-refresh-rate'), c.run && c.fixedRefreshRate);
      assert.equal(ids.has('gamepad'), c.run && c.nativeGamepad); assert.equal(ids.has('developer'), c.run && c.developer);
      assert.equal(ids.has('process'), c.run && c.tabletProcess); assert.equal(ids.has('window'), c.run && !c.tabletProcess);
      assert.equal(ids.has('acceleration'), c.publisher);
      for (const id of ['install-help', 'jit-help', 'feedback', 'sponsor']) assert.equal(ids.has(id), !c.store, id);
      assert.equal(items.find(item => item.id === 'isolation').section, c.run ? 'performance' : 'files');
    }
    assert.equal(catalog.SETTINGS_WIDE_WIDTH, 840);
  });

  await group('具体搜索只消费可见库存并响应实时渠道/运行变化', () => {
    const f = make(); f.view.changeSearch_('  JdK  ');
    assert.ok(f.view.searchResults_().some(item => item.id === 'java'));
    assert.ok(f.view.searchResults_().every(item => f.view.availableItems_().some(visible => visible.id === item.id)));
    f.view.canRunGame = false; f.capability.store = true; f.capability.publisher = false;
    assert.deepEqual(f.view.searchResults_(), []);
    f.view.changeSearch_('JIT'); assert.deepEqual(f.view.searchResults_(), []);
    f.view.changeSearch_('内存'); assert.deepEqual(f.view.searchResults_(), []);
    f.view.changeSearch_('主题'); assert.deepEqual(f.view.searchResults_().map(item => item.id), ['theme']);
    assert.deepEqual(catalog.searchSettings(f.view.availableItems_().filter(item => item.id === 'theme'), '日志'), []);
    assert.deepEqual(catalog.searchSettings(f.view.availableItems_(), '   '), []);
    assert.equal(f.calls.jvm.length + f.calls.choices.length + f.calls.storage.length, 0);
    const before = f.view.activeSection; f.view.openSearchItem_('java'); assert.equal(f.view.activeSection, before);
    f.view.openSearchItem_('about'); assert.equal(f.calls.routes.at(-1).url, 'pages/AboutPage');
  });

  await group('软件更新常驻入口与华为账号搜索直达，商店不宣传不可用登录', () => {
    const f = make(), v = f.view;
    assert(catalog.searchSettings(catalog.settingsItems(f.capability), '华为').some(item => item.id === 'software-update'));
    v.openSearchItem_('software-update'); assert.equal(f.calls.routes.at(-1).url, 'pages/SoftwareUpdatePage');
    componentEvent(v, source, 'OverviewSupport_', 'SettingsValueRow', 'onAction', 'settings-software-update')();
    assert.equal(f.calls.routes.at(-1).url, 'pages/SoftwareUpdatePage');
    assert.equal(catalog.searchSettings(catalog.settingsItems({ ...f.capability, store: true }), '华为').length, 0);
  });

  await group('分辨率搜索和入口直达同一详情，返回操控且管理态不可绕过能力门', () => {
    // 目录、导航方法和真实入口闭包共同执行；不借尚未稳定的卡片坐标推进滚动。
    const f = make(), v = f.view;
    v.changeSearch_('分辨率');
    assert.deepEqual(v.searchResults_().map(item => item.id), ['resolution']);
    v.openSearchItem_('resolution');
    assert.equal(v.activeSection, 'resolution'); assert.equal(v.highlightedItem, '');
    assert.equal(v.sectionTitle_(), '游戏分辨率');
    assert.equal(f.calls.back.at(-1)(), true); assert.equal(v.activeSection, 'controls');
    componentEvent(v, source, 'Controls_', 'SettingsValueRow', 'onAction', 'settings-item-resolution')();
    assert.equal(v.activeSection, 'resolution');
    assert.equal(f.calls.jvm.length + f.calls.choices.length + f.calls.storage.length, 0);
    v.canRunGame = false; v.changeSearch_('分辨率');
    assert.deepEqual(v.searchResults_(), []);
    v.selectSection_('resolution'); assert.equal(v.activeSection, 'overview');
  });

  await group('JVM打开、输入、取消、返回、切分区、切Tab均不隐式保存', () => {
    for (const close of ['cancel', 'back', 'section', 'tab', 'dismiss']) {
      const f = make(), v = f.view;
      componentEvent(v, source, 'RuntimeContent_', 'SettingsValueRow', 'onAction', 'settings-item-jvm')();
      assert.equal(v.showSettingsSheet, true); assert.equal(v.jvmArgsDraft, '-Doriginal=true');
      uiEvent(v, source, 'SheetContent_', 'onChange', 'settings-jvm-draft')('  -Ddraft=' + close + '  ');
      if (close === 'cancel') uiEvent(v, source, 'SheetContent_', 'onClick', 'settings-sheet-cancel')();
      else if (close === 'back') { assert.equal(f.calls.back.at(-1)(), true); }
      else if (close === 'section') v.selectSection_('download');
      else if (close === 'tab') { v.visible = false; v.syncSectionBack_(); assert.equal(f.calls.back.at(-1), undefined); }
      else { let dismiss = 0; v.sheetOptions_().onWillDismiss({ dismiss: () => dismiss++ }); assert.equal(dismiss, 1); }
      assert.deepEqual(f.calls.jvm, []); assert.equal(v.customJvmArgs, '-Doriginal=true');
      assert.equal(v.showSettingsSheet, false); v.sheetDisappeared_(); assert.deepEqual(f.calls.jvm, []);
    }
  });

  await group('JVM显式保存等待父层完成且重复点击只提交一次', async () => {
    const f = make(), v = f.view, gate = deferred(); f.gate(gate);
    v.openSheet_('jvm'); v.jvmArgsDraft = '  -Dexplicit=true  ';
    let finished = false; const saving = v.saveCustomJvmArgs().then(() => { finished = true; });
    uiEvent(v, source, 'SheetContent_', 'onClick', 'settings-jvm-save')(); await settle();
    assert.deepEqual(f.calls.jvm, ['-Dexplicit=true']); assert.equal(finished, false);
    assert.equal(v.jvmSaving, true); assert.equal(v.showSettingsSheet, true); assert.deepEqual(f.calls.committedJvm, []);
    gate.resolve(); await saving; assert.equal(finished, true); assert.equal(v.showSettingsSheet, false);
    assert.deepEqual(f.calls.committedJvm, ['-Dexplicit=true']);
  });

  await group('JVM失败保留草稿和面板，重试仍等待真实Promise', async () => {
    const f = make(), v = f.view; f.fail(new Error('settings disk rejected'));
    v.openSheet_('jvm'); v.jvmArgsDraft = '  -Dretry=true  '; await v.saveCustomJvmArgs();
    assert.equal(v.showSettingsSheet, true); assert.equal(v.jvmSaving, false);
    assert.equal(v.jvmArgsDraft, '  -Dretry=true  '); assert.match(v.sheetError, /settings disk rejected/);
    assert.deepEqual(f.calls.committedJvm, []); f.fail(undefined); await v.saveCustomJvmArgs();
    assert.equal(v.showSettingsSheet, false); assert.deepEqual(f.calls.committedJvm, ['-Dretry=true']);
  });

  await group('旧JVM成功或失败续体不得覆盖新面板owner', async () => {
    for (const reject of [false, true]) {
      const f = make(), v = f.view, gate = deferred(); f.gate(gate);
      v.openSheet_('jvm'); v.jvmArgsDraft = '-Dold=true'; const old = v.saveCustomJvmArgs();
      v.cancelSheet_(); v.sheetDisappeared_(); v.openSheet_('jvm');
      v.jvmArgsDraft = '-Dnew-owner=true'; v.sheetError = 'new owner status';
      if (reject) gate.reject(new Error('late old failure')); else gate.resolve();
      await old; assert.equal(v.showSettingsSheet, true); assert.equal(v.sheetKind, 'jvm');
      assert.equal(v.jvmArgsDraft, '-Dnew-owner=true'); assert.equal(v.sheetError, 'new owner status');
      assert.equal(v.jvmSaving, false);
    }
  });

  await group('切Tab后的旧关闭动画先退役，不能提前覆盖新owner', () => {
    const f = make(), v = f.view; v.openSheet_('jvm'); v.jvmArgsDraft = '-Ddiscard=true';
    v.visible = false; v.syncSectionBack_(); v.visible = true; v.syncSectionBack_();
    v.openSheet_('java'); assert.equal(v.showSettingsSheet, false, '关闭动画未结束前拒绝新owner');
    assert.equal(v.sheetKind, 'jvm'); v.sheetDisappeared_(); v.openSheet_('java');
    assert.equal(v.showSettingsSheet, true); assert.equal(v.sheetKind, 'java'); assert.deepEqual(f.calls.jvm, []);
  });

  await group('单选真实事件只改草稿，确定一次并重验动态目录', () => {
    const f = make(), v = f.view; v.openSheet_('java');
    const choice = v.choiceOptions_().find(item => item.value === '25'); assert.ok(choice);
    uiEvent(v, source, 'SheetContent_', 'onClick', 'settings-choice-25', { choice })();
    assert.equal(v.choiceDraft, '25'); assert.deepEqual(f.calls.choices, []);
    v.jdkVersions = [{ version: '17' }]; v.confirmChoice_();
    assert.equal(v.showSettingsSheet, true); assert.match(v.sheetError, /不可用/); assert.deepEqual(f.calls.choices, []);
    v.jdkVersions = [{ version: '17' }, { version: '25' }];
    uiEvent(v, source, 'SheetContent_', 'onClick', 'settings-choice-confirm')(); v.confirmChoice_();
    assert.deepEqual(f.calls.choices, [['java', '25']]); assert.equal(v.showSettingsSheet, false);
  });

  await group('固定刷新率独立确认，并且服从原调度上限', () => {
    const f = make(), v = f.view;
    v.ohosFrameRateCap = 60;
    v.openSheet_('frame');
    assert.equal(v.choiceDraft, '60');
    assert.ok(v.choiceOptions_().some(item => item.value === '240'));
    v.cancelSheet_(); v.sheetDisappeared_();
    componentEvent(v, source, 'DisplayContent_', 'SettingsValueRow', 'onAction', 'settings-item-fixed-refresh-rate')();
    assert.equal(v.choiceDraft, '0');
    assert.equal(v.choiceOptions_().find(item => item.value === '120').enabled, false);
    v.choiceDraft = '120'; v.confirmChoice_();
    assert.deepEqual(f.calls.choices, []);
    v.choiceDraft = '60'; v.confirmChoice_();
    assert.deepEqual(f.calls.choices, [['fixed-refresh-rate', 60]]);
    assert.equal(v.ohosFrameRateCap, 60);
    const old = make({ fixedRefreshRate: false });
    old.view.openSheet_('fixed-refresh-rate');
    assert.equal(old.view.showSettingsSheet, false);
  });

  await group('旧版调度上限和新的固定档位分别保存在实际偏好键', () => {
    const stored = new Map([['ohosFrameRateCap', 240]]);
    const store = { getSync: (key, fallback) => stored.has(key) ? stored.get(key) : fallback,
      putSync: (key, value) => stored.set(key, value), flush: () => Promise.resolve() };
    const load = makePureEtsLoader({ commons: { ProcessPreferences: { open: () => store, isGameProcess: () => false } },
      '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } }, Object.fromEntries(snapshots));
    const { PreferenceManager } = load(PREFERENCES);
    const settings = new PreferenceManager({ preferencesDir: '/fixture' });
    assert.equal(settings.ohosFrameRateCap, 240);
    assert.equal(settings.ohosFixedRefreshRate, 0);
    settings.ohosFixedRefreshRate = 144;
    const nextGame = new PreferenceManager({ preferencesDir: '/fixture' });
    assert.equal(nextGame.ohosFixedRefreshRate, 144);
    assert.equal(nextGame.ohosFrameRateCap, 240);
    nextGame.ohosFixedRefreshRate = 165;
    assert.equal(nextGame.ohosFixedRefreshRate, 0);
    assert.equal(nextGame.ohosFrameRateCap, 240);
  });

  await group('JDK服务器候选撤回与运行准入撤回不会提交旧选择', () => {
    const f = make(), v = f.view; v.jdkWebEnabled = true; v.openSheet_('jdk-source'); v.choiceDraft = 'web';
    v.jdkWebEnabled = false; v.confirmChoice_(); assert.equal(v.showSettingsSheet, true);
    assert.match(v.sheetError, /不可用/); assert.deepEqual(f.calls.choices, []);
    v.jdkWebEnabled = true; f.capability.publisher = false; v.confirmChoice_();
    assert.equal(v.showSettingsSheet, true); assert.match(v.sheetError, /不可用/);
    assert.deepEqual(f.calls.choices, [], '发布者服务能力撤回后不能提交已缓存的服务器候选');
    v.cancelSheet_(); v.sheetDisappeared_(); v.openSheet_('java'); v.choiceDraft = '25';
    v.canRunGame = false; v.onRunCapabilityChanged_(); v.confirmChoice_();
    assert.equal(v.showSettingsSheet, false); assert.deepEqual(f.calls.choices, []);
    assert.ok(!v.availableItems_().some(item => item.id === 'java'));
  });

  await group('存储显式false意图只在面板消失后派发一次', () => {
    for (const migrate of [false, true]) {
      const f = make(), v = f.view; v.openSheet_('storage'); v.choiceDraft = 'external';
      uiEvent(v, source, 'SheetContent_', 'onClick', migrate ? 'settings-storage-copy' : 'settings-storage-switch')();
      assert.equal(v.showSettingsSheet, false); assert.deepEqual(f.calls.storage, []);
      v.confirmStorage_(!migrate); v.sheetOptions_().onDisappear(); v.sheetOptions_().onDisappear();
      assert.deepEqual(f.calls.storage, [['external', migrate]]); assert.equal(typeof f.calls.storage[0][1], 'boolean');
    }
  });

  await group('存储关闭/隐藏/卸载撤回待派发意图并拒绝失效外部位置', () => {
    for (const withdraw of ['cancel', 'tab', 'unmount']) {
      const f = make(), v = f.view; v.openSheet_('storage'); const ticket=v.beginSkillEditor_('storage');
      v.choiceDraft = 'external'; v.confirmStorage_(false);
      if (withdraw === 'cancel') v.cancelSheet_();
      else if (withdraw === 'tab') { v.visible = false; v.syncSectionBack_(); }
      else v.aboutToDisappear();
      v.sheetDisappeared_(); assert.deepEqual(f.calls.storage, []);
      assert.equal(v.skillEditorRef_,ticket.reference); assert.equal(v.skillEditorState_,'cancelled');
    }
    const f = make(), v = f.view; v.openSheet_('storage'); v.choiceDraft = 'external'; v.externalAvailable = false;
    v.confirmStorage_(false); assert.equal(v.showSettingsSheet, true); assert.match(v.sheetError, /不可用/);
    assert.equal(v.pendingStorage_, ''); assert.deepEqual(f.calls.storage, []);
  });

  // 内存处理从游戏结果进入；隐藏期间保持请求，显示时复用真实目录定位且只消费一次。
  await group('崩溃弹窗的内存处理只在设置可见时定位性能分区的内存项', () => {
    const { view, calls } = make();
    view.visible = false; view.openMemoryRequested = true;
    view.syncSectionBack_();
    assert.equal(view.openMemoryRequested, true);
    view.visible = true; view.syncSectionBack_();
    assert.equal(view.openMemoryRequested, false);
    assert.equal(view.activeSection, 'performance'); assert.equal(view.highlightedItem, 'memory');
    const moves = calls.focusClears;
    view.syncSectionBack_(); assert.equal(calls.focusClears, moves);
  });

  await group('搜索定位使用窗口px差值并转换vp，忽略局部Area坐标', () => {
    const f = make(), v = f.view; v.openSearchItem_('memory');
    assert.equal(v.activeSection, 'performance'); assert.equal(v.highlightedItem, 'memory');
    v.contentScroller.calls.length = 0; v.contentScroller.offset.yOffset = 120;
    v.locateItem_('memory'); assert.deepEqual(f.calls.rects, ['settings-item-memory', 'settings-content-scroll']);
    assert.deepEqual(f.calls.pixels, [600]); assert.equal(v.contentScroller.calls.at(-1).yOffset, 408);
    assert.equal(v.contentScroller.calls.at(-1).animation, false);
    const count = v.contentScroller.calls.length; v.visible = false; v.locateItem_('memory'); assert.equal(v.contentScroller.calls.length, count);
    v.visible = true; v.highlightedItem = 'java'; v.locateItem_('memory'); assert.equal(v.contentScroller.calls.length, count);
  });

  await group('未布局目标不滚动，后续视口布局回调可重新定位', () => {
    const f = make(), v = f.view; v.openSearchItem_('java'); v.contentScroller.calls.length = 0;
    f.rect(id => ({ size: { width: 0, height: 0 }, windowOffset: { x: 0, y: 0 }, localOffset: { x: 0, y: 9999 } }));
    v.locateItem_('java'); assert.equal(v.contentScroller.calls.length, 0); assert.equal(v.highlightedItem, 'java');
    f.rect(id => ({ size: { width: 380, height: 64 }, windowOffset: { x: 0, y: id === 'settings-content-scroll' ? 100 : 500 }, localOffset: { x: 0, y: 8888 } }));
    v.locatePending_(); assert.equal(v.contentScroller.calls.at(-1).yOffset, 188);
  });

  await group('真实宽度事件与原生面板选型在840vp双向切换', () => {
    const f = make(), v = f.view; const area = uiEvent(v, source, 'build', 'onAreaChange');
    v.deviceForm = sheetExports.DeviceForm.TABLET;
    for (const [width, type, expectedWidth] of [[839, 0, undefined], [840, 1, 480], [1200, 1, 480], [600, 0, undefined]]) {
      area({}, { width: String(width) }); assert.equal(v.viewportWidth, width);
      const options = v.sheetOptions_(); assert.equal(options.preferType, type); assert.equal(options.width, expectedWidth);
    }
  });

  await group('手机横屏仍使用底部面板且高度搜索直达耐久回调', async () => {
    const f = make(), v = f.view;
    v.deviceForm = sheetExports.DeviceForm.PHONE;
    v.viewportWidth = 1200; v.phoneSheetHeightPercent = 95;
    const options = v.sheetOptions_();
    assert.equal(options.preferType, 0); assert.equal(options.width, undefined); assert.equal(options.height, 950);
    assert.ok(catalog.searchSettings(catalog.settingsItems(f.capability), 'sheet').some(item => item.id === 'phone-sheet-height'));
    const saves = []; const gate = deferred();
    v.onPhoneSheetHeightSave = async value => { saves.push(value); await gate.promise; };
    let completed = false;
    const save = componentEvent(v, source, 'PhoneSheetHeightContent_', 'PhoneSheetHeightSettings', 'onSave')(90)
      .then(() => { completed = true; });
    await settle(); assert.deepEqual(saves, [90]); assert.equal(completed, false);
    gate.resolve(); await save; assert.equal(completed, true);
  });

  await group('真实图形入口进入详情，返回先回操控且准入撤回后不可进入', () => {
    const f = make(), v = f.view; v.selectSection_('controls');
    componentEvent(v, source, 'Controls_', 'MobileglRendererSettings', 'onOpen')();
    assert.equal(v.activeSection, 'graphics'); assert.equal(v.sectionTitle_(), '图形后端');
    assert.equal(v.sectionBackHandler_(), true); assert.equal(v.activeSection, 'controls');
    v.canRunGame = false; v.selectSection_('graphics'); assert.equal(v.activeSection, 'overview');
  });

  await group('搜索结果结束输入法焦点，同值清空回送不撤销刚建立的定位', () => {
    const f = make(), v = f.view;
    const input = uiEvent(v, source, 'SettingsHeaderAccessory_', 'onChange');
    input('内存'); v.openSearchItem_('memory');
    assert.equal(f.calls.focusClears, 1);
    assert.equal(v.settingsQuery, ''); assert.equal(v.highlightedItem, 'memory');
    const scrolls = v.contentScroller.calls.length;
    input('');
    assert.equal(v.highlightedItem, 'memory', '原生TextInput回送父层清空值不能清掉高亮');
    assert.equal(v.contentScroller.calls.length, scrolls, '同值回送不能再滚回顶部');
    v.openPage_('pages/AboutPage'); assert.equal(f.calls.focusClears, 2);
    assert.equal(f.calls.routes.at(-1).url, 'pages/AboutPage');
  });

  await group('真实主题的操作文字在深浅底可读，按钮底色保持白字对比', () => {
    const { getTheme } = pure(THEME);
    const luminance = hex => {
      const rgb = hex.slice(1).match(/../g).map(value => parseInt(value, 16) / 255)
        .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
      return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
    };
    const ratio = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
    for (const dark of [false, true]) {
      const theme = getTheme(dark);
      for (const bg of [theme.bgPrimary, theme.bgCard, theme.primaryLight]) {
        assert.ok(ratio(theme.actionText, bg) >= 4.5, '操作文字必须达到正常字号对比度');
      }
      assert.ok(ratio('#FFFFFF', theme.actionPrimary) >= 4.5, '按钮白字不能沿用提亮后的文字色作为底色');
    }
  });

  const sourceAfter = Object.fromEntries([...snapshots].map(([relative]) => [relative, digest(fs.readFileSync(path.join(sourceRoot, relative)))]));
  const sourceBefore = Object.fromEntries([...snapshots].map(([relative, value]) => [relative, digest(value)]));
  await group('本次执行源码身份稳定', () => assert.deepEqual(sourceAfter, sourceBefore, '生产源执行期间发生变化，请保留现场并重跑'));
  const status = groups.every(item => item.status === 'PASS') ? 'PASS' : 'FAIL';
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ startedAt, finishedAt: new Date().toISOString(),
    status, sourceRoot, groups, sourceBefore, sourceAfter,
    testSha256: digest(fs.readFileSync(new URL(import.meta.url))),
    scope: 'Actual SettingsCatalog exports, SettingsTab lifecycle/non-UI methods and production UI event closures; controlled policy/UIContext/Scroller/parent persistence edges.',
    notAttested: ['ArkUI layout rendering', 'real Preferences put/flush', 'real storage migration', 'HAP/APP identity', 'device verification'] }, null, 2));
  console.log(status + ' settings UI ' + groups.filter(item => item.status === 'PASS').length + '/' + groups.length + '; receipt ' + path.join(output, 'receipt.json'));
  if (status !== 'PASS') process.exitCode = 1;
}

main().catch(error => {
  fs.writeFileSync(path.join(output, 'fatal.json'), JSON.stringify({ startedAt, failedAt: new Date().toISOString(),
    status: 'FAIL', sourceRoot, groups, error: error.stack || String(error) }, null, 2));
  console.error(error.stack || error); process.exitCode = 1;
});

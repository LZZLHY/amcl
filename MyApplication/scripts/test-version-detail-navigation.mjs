#!/usr/bin/env node
/**
 * 版本详情内部导航的宿主行为回归。通过SDK AST提取真实组件字段、方法及Builder事件，
 * 执行生产SheetPageMotion；只替换帧/动画完成、磁盘扫描和父层保存等平台边界。
 * 不复制导航算法，不依赖已删除的旧menu，不执行ArkUI布局或访问用户偏好/设备。
 * 每次运行将固定源码、哈希、失败栈及结果写入独立外置目录，失败现场不覆盖。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const COMPONENT = 'entry/src/main/ets/components/VersionManagerSheet.ets';
const MOTION = 'entry/src/main/ets/components/SheetPageMotion.ets';
const LANGUAGES = 'commons/src/main/ets/common/GameLanguages.ets';
const INDEX = 'entry/src/main/ets/pages/Index.ets';
const sourceRoot = path.resolve(process.env.AMCL_VERSION_DETAIL_TEST_ROOT || PROJECT_ROOT);
const at = process.argv.indexOf('--output');
if (at >= 0 && !process.argv[at + 1]) throw new Error('--output requires an external directory');
const outputBase = assertExternalOutputPath(at < 0
  ? resolveWorkspacePath('run', 'version-detail-ui', { root: sourceRoot }) : process.argv[at + 1], { root: sourceRoot });
const startedAt = new Date().toISOString();
const output = path.join(outputBase, 'navigation-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(path.join(output, 'sources'), { recursive: true });
const sources = new Map([COMPONENT, MOTION, LANGUAGES, INDEX].map(file => [file, fs.readFileSync(path.join(sourceRoot, file), 'utf8')]));
const hash = text => createHash('sha256').update(text).digest('hex');
const inputHashes = Object.fromEntries([...sources].map(([file, text]) => [file, hash(text)]));
for (const [file, text] of sources) {
  const target = path.join(output, 'sources', file); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text);
}
const groups = [];
async function group(name, run) {
  try { await run(); groups.push({ name, status: 'PASS' }); console.log('PASS ' + name); }
  catch (error) { groups.push({ name, status: 'FAIL', error: error.stack || String(error) }); console.error('FAIL ' + name + '\n' + (error.stack || error)); }
}

/** 转译仍是生产正文；错误不能被算成负控或行为通过。 */
function transpile(text, name) {
  const result = compiler.transpileModule(text, { fileName: name.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } });
  assert.equal((result.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0, name);
  return result.outputText;
}

const source = sources.get(COMPONENT);
const ast = compiler.createSourceFile(COMPONENT, source, compiler.ScriptTarget.Latest, true);
const owner = ast.statements.find(node => node.name?.getText(ast) === 'VersionManagerSheet');
assert.ok(owner?.members, 'actual VersionManagerSheet must parse');
const member = name => { const found = owner.members.find(node => node.name?.getText(ast) === name); assert.ok(found, 'actual member: ' + name); return found; };
const methods = ['aboutToAppear', 'aboutToDisappear', 'mountStep_', 'managerNavigationBlocked_', 'requestManagerBack_',
  'requestManagerClose_', 'openDetailEditor_', 'applyJdkChoice_', 'applyLanguageChoice_', 'filteredLanguages_',
  'backToDetail', 'backToList', 'openGameExport_', 'managerTitle_', 'managerContext_', 'handleSelectVersion', 'flashSwitched'];
const fields = ['canRunGame', 'currentVersion', 'availableVersions', 'initialStep', 'initialResourceVersion', 'initialResourceKind',
  'orderVersions', 'currentStep', 'listMounted_', 'detailMounted_', 'resourcesMounted_', 'savesMounted_', 'filesMounted_',
  'detailVersion', 'resourceKind', 'detailEditorMounted_', 'detailEditorKind_', 'languageSearch_', 'editorNavigationBlocked_',
  'editorDismissHandler_', 'versionJdk', 'versionGameLang', 'pageMotion_', 'exportMounted_', 'exportDismissHandler_',
  'resourcesNavigationBlocked_', 'savesNavigationBlocked_', 'filesNavigationBlocked_', 'exportTaskUnsubscribe_',
  'exportTitle_', 'exportMcRoot_', 'exportVersionId_', 'exportVersionIsolation_', 'mcDir', 'versionIsolation', 'supportedJdkVersions'];
const cleanDecorators = text => text.replace(/@(Prop|State|Watch|StorageProp|Link|ObjectLink|BuilderParam)(\([^\n]*?\))?\s*/g, '');
const subjectCode = transpile('class Subject {\n' + fields.map(name => cleanDecorators(member(name).getText(ast))).join('\n') +
  '\n' + methods.map(name => member(name).getText(ast)).join('\n') + '\n}\nmodule.exports = Subject;', COMPONENT);

/** 生产位移类只替换UIContext/FrameCallback宿主边缘，真正的moving/revision/dispose仍照常执行。 */
function loadMotion() {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'Observed', 'Curve', transpile(sources.get(MOTION), MOTION))(
    name => { assert.equal(name, '@kit.ArkUI'); return { FrameCallback: class {} }; }, module, module.exports,
    value => value, { FastOutSlowIn: 'curve' });
  return module.exports.SheetPageMotion;
}
const SheetPageMotion = loadMotion();
const { GAME_LANGUAGES } = makePureEtsLoader() (path.join(sourceRoot, LANGUAGES));

/** 系统关闭也执行Index真实SheetOptions与注册回调，不能只在测试里直调内容分发器。 */
const indexAst = compiler.createSourceFile(INDEX, sources.get(INDEX), compiler.ScriptTarget.Latest, true);
const indexOwner = indexAst.statements.find(node => node.members?.some(item => item.name?.getText(indexAst) === 'versionManagerSheetOptions_'));
assert.ok(indexOwner, 'actual Index sheet owner');
const indexOptionsMethod = indexOwner.members.find(item => item.name?.getText(indexAst) === 'versionManagerSheetOptions_');
const indexBuilder = indexOwner.members.find(item => item.name?.getText(indexAst) === 'VersionManagerBuilder');
let indexRegister;
const findIndexRegister = node => {
  if (node.kind === compiler.SyntaxKind.PropertyAssignment && node.name?.getText(indexAst) === 'onRegisterExportDismiss') indexRegister = node.initializer;
  compiler.forEachChild(node, findIndexRegister);
};
findIndexRegister(indexBuilder); assert.ok(indexRegister, 'actual Index manager dismiss registration');
const indexCode = transpile('class IndexProbe { ' + indexOptionsMethod.getText(indexAst) + ' }\nmodule.exports = IndexProbe;', INDEX);
const indexRegisterCode = transpile('module.exports = function() { return (' + indexRegister.getText(indexAst) + '); };', INDEX);
function indexBoundary(events) {
  const reasons = { PRESS_BACK: 'press-back', TOUCH_OUTSIDE: 'touch-outside' }, module = { exports: {} };
  new Function('module', 'DismissReason', indexCode)(module, reasons);
  const view = Object.assign(new module.exports(), { theme: { bgCard: 'card' }, adaptiveSheetOptions: () => ({ height: '80%' }) });
  const registration = { exports: {} }; new Function('module', indexRegisterCode)(registration);
  const register = registration.exports.call(view);
  return { register, dismiss: back => view.versionManagerSheetOptions_().onWillDismiss({
    reason: back ? reasons.PRESS_BACK : reasons.TOUCH_OUTSIDE, dismiss: () => events.push(['native-dismiss']) }) };
}

/** 生产Builder只提取目标组件参数表达式，不以文字正则推断接线正确。 */
function componentObjects(methodName, componentName) {
  const result = [];
  const visit = node => {
    if (node.kind === compiler.SyntaxKind.CallExpression && node.expression?.getText(ast) === componentName) {
      const object = node.arguments.find(arg => arg.kind === compiler.SyntaxKind.ObjectLiteralExpression);
      if (object) result.push(object);
    }
    compiler.forEachChild(node, visit);
  }; visit(member(methodName)); assert.ok(result.length > 0, methodName + ':' + componentName); return result;
}
function property(object, name) { const result = object.properties.find(node => node.name?.getText(ast) === name); assert.ok(result?.initializer, 'actual property: ' + name); return result.initializer; }
function expression(view, node, scope = {}) {
  const js = transpile('module.exports = function() { return (' + node.getText(ast) + '); };', COMPONENT);
  const module = { exports: {} }; new Function('module', ...Object.keys(scope), js)(module, ...Object.values(scope));
  return module.exports.call(view);
}
function componentEvent(view, methodName, componentName, event) {
  return expression(view, property(componentObjects(methodName, componentName)[0], event));
}

/** 每个fixture有独立帧队列、保存边缘和关闭注册；磁盘扫描仅记下实际传入身份。 */
function fixture(overrides = {}) {
  const events = [], frames = [], animations = [], registered = [];
  const index = indexBoundary(events);
  const context = { postFrameCallback: callback => frames.push(callback),
    animateTo: (options, update) => { animations.push(options); update(); },
    // 仅替换平台Toast边缘，执行真实handleSelectVersion/flashSwitched，不能恢复旧副标题定时器。
    getPromptAction: () => ({ showToast: options => events.push(['prompt-toast', options.message]) }) };
  const coordinator = { subscribe: callback => { events.push(['subscribe']); return () => events.push(['unsubscribe']); } };
  const module = { exports: {} };
  new Function('module', 'SheetPageMotion', 'ResourceKind', 'GAME_LANGUAGES', 'getGameExportCoordinator', subjectCode)(
    module, SheetPageMotion, { MOD: 'mod' }, GAME_LANGUAGES, () => coordinator);
  const view = new module.exports();
  Object.assign(view, {
    initialStep: 'detail', initialResourceVersion: 'managed-instance', currentVersion: 'home-selected',
    availableVersions: ['home-selected', 'managed-instance'], mcDir: '/root/one', supportedJdkVersions: ['17', '21'],
    getUIContext: () => context, refreshVersionRows_: () => events.push(['rows']), resetDetailCounts: () => events.push(['counts']),
    refreshDetailResStat: version => events.push(['resources', version]), loadVersionJvmArgsState: version => events.push(['load-jvm', version]),
    loadModpackSnapshot_: version => events.push(['modpack', version]), refreshDetailExportTask_: () => events.push(['export-state']),
    onRegisterExportDismiss: callback => { registered.push(callback); index.register(callback); }, onClose: () => events.push(['close']),
    onSaveVersionJdk: (version, value) => events.push(['save-jdk', version, value]),
    onSaveVersionGameLang: (version, value) => events.push(['save-language', version, value]),
    onSelectVersion: version => events.push(['select-version', version]),
    safeToast: (...args) => events.push(['toast', ...args]), ...overrides,
  });
  view.aboutToAppear();
  const finishMotion = () => {
    assert.equal(frames.length, 1, 'production move must await one initial frame');
    frames.shift().onIdle(0); assert.equal(animations.length, 1, 'production initial frame starts animation');
    animations.shift().onFinish();
  };
  return { view, events, frames, animations, registered, finishMotion,
    system: (back = false) => { assert.equal(typeof registered.at(-1), 'function'); index.dismiss(back); },
    topBack: () => componentEvent(view, 'build', 'ImmersiveTitleScaffold', 'onBack')(),
    topClose: () => componentEvent(view, 'build', 'ImmersiveTitleScaffold', 'onClose')(),
    saves: () => events.filter(event => event[0].startsWith('save-')) };
}
const enter = (f, kind) => { f.view.openDetailEditor_(kind); f.finishMotion(); assert.equal(f.view.currentStep, kind); };

await group('新版编辑页保留主线紧凑标题与固定实例，列表计数及导出实时标题均不回退', () => {
  const titleObject = componentObjects('build', 'ImmersiveTitleScaffold')[0];
  // 检查生产宿主的实际参数，不用测试自己制造标题或对象身份，也不恢复被删除的副标题API。
  for (const [kind, title] of [['jdk', 'Java 运行时'], ['language', '游戏语言'], ['jvm', 'JVM 参数'], ['resolution', '游戏分辨率']]) {
    const f = fixture(); enter(f, kind); f.view.currentVersion = 'changed-home';
    assert.equal(expression(f.view, property(titleObject, 'title')), title);
    assert.equal(expression(f.view, property(titleObject, 'contextLabel')), 'managed-instance');
    assert.equal(expression(f.view, property(titleObject, 'contextTitle')), '当前实例');
  }
  const f = fixture();
  for (const step of ['resources', 'saves', 'files']) {
    f.view.currentStep = step;
    assert.equal(expression(f.view, property(titleObject, 'contextLabel')), 'managed-instance');
  }
  for (const [step, title] of [['list', '版本管理 · 2'], ['detail', '版本详情']]) {
    f.view.currentStep = step;
    assert.equal(expression(f.view, property(titleObject, 'title')), title);
    assert.equal(expression(f.view, property(titleObject, 'contextLabel')), '', '已有身份卡或计数不重复增加标题标签');
  }
  f.view.exportTitle_ = '上一个导出层'; f.view.openGameExport_(); f.finishMotion();
  assert.equal(expression(f.view, property(titleObject, 'title')), '导出游戏包', '新导出必须复位旧层标题');
  componentEvent(f.view, 'ImmersiveTitleContent1_', 'GameExportSheet', 'onTitleChange')('选择导出内容');
  assert.equal(expression(f.view, property(titleObject, 'title')), '选择导出内容', '保留主线导出步骤标题投影');
  for (const name of ['subtitle', 'subtitleInTitle', 'subtitleId']) {
    assert.equal(titleObject.properties.some(node => node.name?.getText(ast) === name), false, '不能接回已退役标题参数：' + name);
  }
});

await group('切换版本执行真实Toast反馈，不以旧副标题计时器代替选择事件', () => {
  const f = fixture(); f.view.handleSelectVersion('home-selected');
  assert.deepEqual(f.events.filter(event => event[0] === 'select-version'), []);
  assert.deepEqual(f.events.filter(event => event[0] === 'prompt-toast'), [['prompt-toast', '已是当前版本']]);
  f.view.handleSelectVersion('managed-instance');
  assert.deepEqual(f.events.filter(event => event[0] === 'select-version'), [['select-version', 'managed-instance']]);
  assert.deepEqual(f.events.filter(event => event[0] === 'prompt-toast'),
    [['prompt-toast', '已是当前版本'], ['prompt-toast', '已切换到 managed-instance ✓']]);
  assert.equal(f.view.currentVersion, 'home-selected', '确认选中态仍由父层回传，Toast不冒充完成选择');
});

await group('固定详情身份进入四类编辑槽，不改首页选版、不提前保存，入场帧及动画均拒重复进入', () => {
  for (const kind of ['jdk', 'language', 'jvm', 'resolution']) {
    const f = fixture(); f.view.languageSearch_ = 'old'; f.view.openDetailEditor_(kind);
    assert.equal(f.view.detailVersion, 'managed-instance'); assert.equal(f.view.currentVersion, 'home-selected');
    assert.equal(f.view.currentStep, kind); assert.equal(f.view.detailEditorKind_, kind); assert.equal(f.view.detailEditorMounted_, true);
    assert.equal(f.view.detailMounted_, true); assert.equal(f.view.languageSearch_, ''); assert.equal(f.view.pageMotion_.moving, true);
    f.view.openDetailEditor_('language'); assert.equal(f.frames.length, 1); assert.equal(f.view.detailEditorKind_, kind);
    f.frames.shift().onIdle(0); f.view.openDetailEditor_('language'); assert.equal(f.animations.length, 1);
    f.animations.shift().onFinish(); f.view.openDetailEditor_('language'); assert.equal(f.view.detailEditorKind_, kind);
    assert.deepEqual(f.saves(), []); assert.equal(f.events.some(event => event[0] === 'close'), false);
  }
});

await group('无运行权限、空详情、非详情、已有转场及未知kind均不创建临时槽', () => {
  for (const [key, value] of [['canRunGame', false], ['detailVersion', ''], ['currentStep', 'list']]) {
    const f = fixture(); f.view[key] = value; f.view.openDetailEditor_('jdk');
    assert.equal(f.view.detailEditorMounted_, false); assert.equal(f.frames.length, 0); assert.deepEqual(f.saves(), []);
  }
  const f = fixture(); f.view.pageMotion_.move(f.view.getUIContext(), 0); f.view.openDetailEditor_('jdk');
  assert.equal(f.view.detailEditorMounted_, false);
  const unknown = fixture(); unknown.view.openDetailEditor_('unsupported');
  assert.equal(unknown.view.detailEditorMounted_, false); assert.equal(unknown.view.currentStep, 'detail');
});

for (const [kind, methodName, field, valid] of [['jdk', 'applyJdkChoice_', 'versionJdk', '21'], ['language', 'applyLanguageChoice_', 'versionGameLang', 'en_us']]) {
  await group(kind + '选择真实详情owner立即保存一次后返回；动画结束才卸载临时槽并保留详情', () => {
    const f = fixture(); enter(f, kind); f.view.currentVersion = 'changed-home'; f.view[methodName](valid);
    assert.deepEqual(f.saves(), [['save-' + (kind === 'jdk' ? 'jdk' : 'language'), 'managed-instance', valid]]);
    assert.equal(f.view[field], valid); assert.equal(f.view.currentStep, 'detail');
    assert.equal(f.view.detailEditorMounted_, true); assert.equal(f.view.detailEditorKind_, kind);
    assert.equal(f.view.detailVersion, 'managed-instance'); assert.equal(f.view.detailMounted_, true);
    f.view[methodName](valid); assert.equal(f.saves().length, 1); f.view.openDetailEditor_('jvm'); assert.equal(f.view.detailEditorKind_, kind);
    f.finishMotion(); assert.equal(f.view.detailEditorMounted_, false); assert.equal(f.view.detailEditorKind_, '');
    assert.equal(f.view.detailMounted_, true); assert.equal(f.view.detailVersion, 'managed-instance');
    f.view.openDetailEditor_('jvm'); assert.equal(f.view.detailEditorKind_, 'jvm');
  });
  await group(kind + '无效候选、错误页与动画中迟到选择不写；同值返回不重复保存', () => {
    const f = fixture(); f.view[methodName](valid); assert.deepEqual(f.saves(), []);
    f.view.openDetailEditor_(kind); f.view[methodName](valid); assert.deepEqual(f.saves(), []); f.finishMotion();
    f.view[methodName]('unknown-value'); assert.equal(f.view.currentStep, kind); assert.deepEqual(f.saves(), []);
    f.view[field] = valid; f.view[methodName](valid); assert.deepEqual(f.saves(), []); assert.equal(f.view.currentStep, 'detail');
  });
  await group(kind + '同步保存失败保留原确认值与子页，不误报返回', () => {
    const callback = kind === 'jdk' ? 'onSaveVersionJdk' : 'onSaveVersionGameLang';
    const f = fixture({ [callback]: () => { throw new Error('save failed'); } }); enter(f, kind); const old = f.view[field];
    f.view[methodName](valid); assert.equal(f.view[field], old); assert.equal(f.view.currentStep, kind);
    assert.equal(f.view.pageMotion_.moving, false); assert.equal(f.events.filter(event => event[0] === 'toast').length, 1);
  });
}

await group('JDK跟随全局/自动与语言跟随全局保持真实哨兵语义', () => {
  for (const value of ['', 'auto']) {
    const f = fixture(); f.view.versionJdk = '17'; enter(f, 'jdk'); f.view.applyJdkChoice_(value);
    assert.deepEqual(f.saves(), [['save-jdk', 'managed-instance', value]]);
  }
  const f = fixture(); f.view.versionGameLang = 'en_us'; enter(f, 'language'); f.view.applyLanguageChoice_('');
  assert.deepEqual(f.saves(), [['save-language', 'managed-instance', '']]);
});

await group('顶部与系统返回/关闭都经过JVM注册guard；忙态及处理器未就绪均不旁路', () => {
  const f = fixture(); enter(f, 'jvm'); const requests = [];
  const register = componentEvent(f.view, 'DetailEditorStep_', 'VersionJvmArgsEditor', 'onRegisterDismiss');
  const busy = componentEvent(f.view, 'DetailEditorStep_', 'VersionJvmArgsEditor', 'onNavigationBlocked');
  const invokeAll = () => { f.topBack(); f.topClose(); f.system(true); f.system(false); };
  invokeAll(); assert.deepEqual(requests, []); assert.equal(f.view.currentStep, 'jvm');
  register(back => requests.push(back)); busy(true); invokeAll(); assert.deepEqual(requests, []);
  busy(false); invokeAll(); assert.deepEqual(requests, [true, false, true, false]);
  assert.equal(f.view.currentStep, 'jvm'); assert.equal(f.events.some(event => event[0] === 'close'), false);
  register(undefined); invokeAll(); assert.equal(requests.length, 4); assert.equal(f.view.currentStep, 'jvm');
});

await group('导出顶部和系统关闭只派发子guard，未注册不关闭，入场中不绕过', () => {
  const f = fixture(); const requests = []; f.view.openGameExport_();
  assert.equal(f.view.exportVersionId_, 'managed-instance'); assert.equal(f.view.exportMcRoot_, '/root/one');
  f.topBack(); f.topClose(); f.system(true); f.system(false); assert.equal(f.events.some(event => event[0] === 'close'), false);
  f.finishMotion(); f.topBack(); f.topClose(); assert.equal(f.view.currentStep, 'export');
  const register = componentEvent(f.view, 'ImmersiveTitleContent1_', 'GameExportSheet', 'onRegisterDismiss');
  register(back => requests.push(back)); f.topBack(); f.topClose(); f.system(true); f.system(false);
  assert.deepEqual(requests, [true, false, true, false]); assert.equal(f.view.currentStep, 'export');
  assert.equal(f.events.some(event => event[0] === 'close'), false);
});

await group('子JVM确认返回后按真实动画完成退役编辑槽，资源页与详情保留', () => {
  const f = fixture(); f.view.resourcesMounted_ = true; enter(f, 'jvm');
  const register = componentEvent(f.view, 'DetailEditorStep_', 'VersionJvmArgsEditor', 'onRegisterDismiss'); register(() => {});
  componentEvent(f.view, 'DetailEditorStep_', 'VersionJvmArgsEditor', 'onBack')();
  assert.equal(f.view.detailEditorMounted_, true); assert.equal(typeof f.view.editorDismissHandler_, 'function');
  f.finishMotion(); assert.equal(f.view.detailEditorMounted_, false); assert.equal(f.view.editorDismissHandler_, undefined);
  assert.equal(f.view.editorNavigationBlocked_, false); assert.equal(f.view.resourcesMounted_, true); assert.equal(f.view.detailMounted_, true);
});

await group('子导出确认返回后才退役导出槽；关闭不错误返回详情', () => {
  const f = fixture(); f.view.openGameExport_(); f.finishMotion();
  componentEvent(f.view, 'ImmersiveTitleContent1_', 'GameExportSheet', 'onBack')(); assert.equal(f.view.exportMounted_, true);
  f.finishMotion(); assert.equal(f.view.exportMounted_, false); assert.equal(f.view.detailMounted_, true);
  const close = fixture(); close.view.openGameExport_(); close.finishMotion();
  componentEvent(close.view, 'ImmersiveTitleContent1_', 'GameExportSheet', 'onClose')();
  assert.equal(close.events.filter(event => event[0] === 'close').length, 1); assert.equal(close.view.currentStep, 'export');
});

await group('资源/存档/文件忙态同时保护顶部与系统入口，列表/详情返回层级一致', () => {
  for (const step of ['resources', 'saves', 'files']) {
    const f = fixture(); f.view.currentStep = step; f.view[step + 'NavigationBlocked_'] = true;
    f.topBack(); f.topClose(); f.system(true); f.system(false); assert.equal(f.view.currentStep, step);
    assert.equal(f.events.some(event => event[0] === 'close'), false);
  }
  for (const channel of ['top', 'system']) {
    const f = fixture(); if (channel === 'top') f.topBack(); else f.system(true);
    assert.equal(f.view.currentStep, 'list'); assert.equal(f.view.detailMounted_, true); f.finishMotion();
    f.system(true); assert.equal(f.events.filter(event => event[0] === 'close').length, 1);
  }
});

await group('销毁撤销帧/完成资格并注销系统分发，不让旧动画卸载新显示状态', () => {
  const f = fixture(); enter(f, 'jdk'); f.view.backToDetail();
  const oldFrame = f.frames.shift(); f.view.aboutToDisappear(); oldFrame.onIdle(0);
  assert.equal(f.animations.length, 0); assert.equal(f.view.detailEditorMounted_, true);
  assert.equal(f.registered.at(-1), undefined); assert.equal(f.events.filter(event => event[0] === 'unsubscribe').length, 1);
});

await group('语言过滤执行真实目录，按名称/代码忽略大小写与首尾空格，不改变确认值', () => {
  const f = fixture(); f.view.versionGameLang = 'ja_jp'; const before = JSON.stringify(GAME_LANGUAGES);
  f.view.languageSearch_ = ' ENGLISH '; assert.deepEqual(f.view.filteredLanguages_().map(item => item.code), ['en_us', 'en_gb']);
  f.view.languageSearch_ = 'EN_US'; assert.deepEqual(f.view.filteredLanguages_().map(item => item.code), ['en_us']);
  f.view.languageSearch_ = '繁體'; assert.deepEqual(f.view.filteredLanguages_().map(item => item.code), ['zh_tw', 'zh_hk']);
  f.view.languageSearch_ = 'not-a-language'; assert.deepEqual(f.view.filteredLanguages_(), []);
  f.view.languageSearch_ = '   '; assert.equal(f.view.filteredLanguages_(), GAME_LANGUAGES);
  assert.equal(f.view.versionGameLang, 'ja_jp'); assert.equal(f.view.detailVersion, 'managed-instance');
  assert.equal(JSON.stringify(GAME_LANGUAGES), before); assert.deepEqual(f.saves(), []);
});

await group('单选group由实际Builder按根目录/详情owner与类别隔离，重读同owner保持稳定', () => {
  const objects = componentObjects('DetailEditorStep_', 'VersionDetailChoiceRow');
  const values = f => objects.map(object => expression(f.view, property(object, 'group'), { version: '21', option: GAME_LANGUAGES[0] }));
  const a = fixture(), b = fixture({ initialResourceVersion: 'other-instance' }), c = fixture({ mcDir: '/root/two' });
  const ga = values(a); assert.equal(new Set(ga).size, 2); assert.deepEqual(values(a), ga);
  assert.ok(ga.every((value, index) => typeof value === 'string' && value.length > 0 && value !== values(b)[index] && value !== values(c)[index]));
});

const drift = [...sources.keys()].filter(file => hash(fs.readFileSync(path.join(sourceRoot, file), 'utf8')) !== inputHashes[file]);
if (drift.length > 0) groups.push({ name: 'source snapshot remains current', status: 'FAIL', error: 'Source changed during run: ' + drift.join(', ') });
const failed = groups.filter(item => item.status !== 'PASS');
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ startedAt, finishedAt: new Date().toISOString(), sourceRoot,
  inputHashes, groups, passed: groups.length - failed.length, failed: failed.length,
  boundary: 'Production methods/Builder callbacks and real motion state only. No ArkUI rendering, Preferences, SDK build or device validation.' }, null, 2));
console.log('[version-detail-navigation] ' + (failed.length ? 'FAIL' : 'PASS') + ' ' + (groups.length - failed.length) + '/' + groups.length + ' groups; evidence ' + output);
if (failed.length) process.exitCode = 1;

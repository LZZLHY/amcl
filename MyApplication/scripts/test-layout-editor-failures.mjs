#!/usr/bin/env node
/**
 * 布局编辑 UI 的失败/生命周期回归。抽取真实生产方法转译执行，只桩掉 ArkUI、native
 * 与存储提交边界；不复制 UI 控制流，不构建 HAP，不触碰用户布局、Preferences 或设备。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const copy = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
let passed = 0;
function check(name) { passed++; console.log('PASS ' + name); }

/** 匹配单个真实方法，跳过字符串和注释中的花括号；UI build 不进入宿主解析器。 */
function method(source, name) {
  const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\s*\\(', 'm').exec(source);
  assert.ok(match, '生产方法缺失：' + name);
  const start = match.index;
  let index = source.indexOf('{', start), depth = 0, quote = '', lineComment = false, blockComment = false;
  for (; index < source.length; index++) {
    const ch = source[index], next = source[index + 1];
    if (lineComment) { if (ch === '\n') lineComment = false; continue; }
    if (blockComment) { if (ch === '*' && next === '/') { blockComment = false; index++; } continue; }
    if (quote) { if (ch === '\\') index++; else if (ch === quote) quote = ''; continue; }
    if (ch === '/' && next === '/') { lineComment = true; index++; continue; }
    if (ch === '/' && next === '*') { blockComment = true; index++; continue; }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue; }
    if (ch === '{') depth++;
    if (ch === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error('生产方法花括号不完整：' + name);
}

/** 同时带入生产字段默认值，防止测试自己设置的初始 busy/lease 状态掩盖接线缺陷。 */
function subject(relative, methods, fieldNames, bindings) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const fields = source.split(/\r?\n/).filter(line => fieldNames.some(name =>
    new RegExp('^  (?:@State )?(?:private )?' + name + '\\s*:').test(line))).map(line => line.replace('@State ', ''));
  assert.equal(fields.length, fieldNames.length, '生产字段提取不完整：' + relative);
  const input = 'class Subject {\n' + fields.join('\n') + '\n' + methods.map(name => method(source, name)).join('\n')
    + '\n}\nmodule.exports=Subject;';
  const compiled = compiler.transpileModule(input, { compilerOptions: {
    target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', ...Object.keys(bindings), compiled.outputText)(module, ...Object.values(bindings));
  return new module.exports();
}

/** 存储是外部确认边界；成功才改变已确认方案，reject/false/null 为明确不同的故障输入。 */
function makeStore(preset = false) {
  const original = { name: '原方案', isPreset: preset, controls: [{ id: 'jump', xPct: 0.1 }], targetDevice: 'phone' };
  const other = { name: '其他方案', isPreset: false, controls: [{ id: 'other', xPct: 0.8 }] };
  const store = {
    profiles: [copy(original), copy(other)], active: copy(original), snapshot: undefined,
    leases: 0, permitLease: true, events: [], failures: new Map(), blocks: new Map(),
    async invoke(name, effect) {
      store.events.push(name);
      const wait = store.blocks.get(name); if (wait) await wait.promise;
      if (store.failures.get(name) === 'reject') throw new Error(name + ' flush rejected');
      if (store.failures.has(name)) return store.failures.get(name);
      return effect();
    },
    beginEditorSession() { store.events.push('lease+'); if (!store.permitLease) return false; store.leases++; return true; },
    endEditorSession() { assert.ok(store.leases > 0, '不能重复归还租约'); store.leases--; store.events.push('lease-'); },
    beginEditorTransaction() { if (!store.snapshot) store.snapshot = { active: copy(store.active), profiles: copy(store.profiles) }; },
    commitEditorTransaction() { store.events.push('commit'); store.snapshot = undefined; },
    restoreEditorTransaction() { return store.invoke('restore', () => { if (store.snapshot) {
      store.active = copy(store.snapshot.active); store.profiles = copy(store.snapshot.profiles); store.snapshot = undefined;
    } return true; }); },
    waitReady() { return store.invoke('ready', () => undefined); },
    init() { return store.invoke('init', () => undefined); },
    getActiveProfile() { return store.active; }, getAllProfiles() { return store.profiles; },
    getProfileNames() { return store.profiles.map(profile => profile.name); }, getCurrentDeviceType() { return 'tablet'; },
    cloneAsUser(name) { return store.invoke('clone', () => {
      const profile = { ...copy(store.active), name: name + ' 副本', isPreset: false };
      store.active = profile; store.profiles.push(profile); return profile;
    }); },
    saveProfile(profile) { return store.invoke('save', () => { store.active = copy(profile); return true; }); },
    resetProfile(name) { return store.invoke('reset', () => {
      store.active = { ...copy(original), name, isPreset: false }; return store.active;
    }); },
    setActiveProfile(name) { return store.invoke('switch', () => { store.active = copy(store.profiles.find(profile => profile.name === name)); }); },
    deleteProfile(name) { return store.invoke('delete', () => {
      store.profiles = store.profiles.filter(profile => profile.name !== name);
      if (store.active.name === name) store.active = copy(store.profiles[0]); return true;
    }); },
    createProfile(name) { return store.invoke('create', () => {
      store.active = { ...copy(original), name, isPreset: false }; store.profiles.push(store.active); return store.active;
    }); },
  };
  return store;
}

function commonBindings(store) {
  const errors = [];
  return { errors, values: { getLayoutStore: () => store, cloneLayout: copy,
    validateAndNormalizeLayout: profile => profile?.invalid ? null : copy(profile),
    hilog: { error: (...args) => errors.push(args), warn() {} }, GAME_CONTROLS_TAG: 'GameControls',
  } };
}

function gameControls(store) {
  const shared = commonBindings(store), pause = [], notices = [], changes = [];
  const instance = subject('entry/src/main/ets/components/GameControls.ets', [
    'openEditor', 'releaseEditorLease_', 'restoreDisposedEditor_', 'resumeEditorInput_', 'showEditorError_',
    'finishEditor_', 'editorInitializationFailed_', 'aboutToDisappear',
  ], ['editing', 'editorOpening', 'editorLeaseHeld', 'editorInputPaused', 'editorDisposeTask', 'mounted', 'appearanceGeneration'], {
    ...shared.values, testNapi: { setTouchPaused: value => { pause.push(value); if (instance.pauseFails && value) throw new Error('pause failed'); } },
    getInputSourceRegistry: () => ({ unregister() {} }), getInputDeviceMonitor: () => ({ removeCapabilityListener() {} }),
    releaseEntryControlFeedback() {},
  });
  Object.assign(instance, { mounted: true, appearanceGeneration: 1, profile: copy(store.active), profileVer: 0,
    releaseAllDirections() {}, buttonReleaseAllFingers() {}, resetTransientInputState() {}, schemaActive: false,
    onLayoutChanged() { changes.push(instance.profile.name); },
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => notices.push(value.message) }) }),
  });
  return { instance, pause, notices, changes, errors: shared.errors };
}

function editor(store) {
  const shared = commonBindings(store), done = [], failed = [];
  const instance = subject('entry/src/main/ets/components/LayoutEditor.ets', [
    'aboutToAppear', 'aboutToDisappear', 'cleanupDestroyedEditor_', 'restoreUnfinishedEditor_',
    'restoreUnfinishedEditorOnce_', 'releaseEditorLease_', 'reportPersistenceError_', 'runPersistence_',
    'performPersistence_', 'loadConfirmedProfile_', 'completeEditor_', 'saveEditor_', 'cancelEditor_',
    'resetEditorProfile_', 'switchEditorProfile_', 'deleteEditorProfile_', 'createEditorProfile_',
  ], ['persistenceBusy', 'editorMounted', 'editorReady', 'editorClosed', 'editorGeneration', 'editorLeaseHeld',
    'editorTransactionOwned', 'persistenceTask', 'editorCleanupTask', 'restorationTask', 'profileName', 'profileNames', 'statusMsg', 'baselineSig'], shared.values);
  Object.assign(instance, { screenWidth: 720, screenHeight: 360, draft: copy(store.active), undoCount: 0,
    panelWidth: () => 300, panelMaxTop: () => 300,
    loadProfile(profile) { instance.draft = copy(profile); instance.profileName = profile.name; },
    contentSignature: () => JSON.stringify(instance.draft), buildProfile: () => instance.invalidDraft ? null : copy(instance.draft),
    pushUndo() { instance.undoCount++; }, onDone: value => done.push(value), onInitializationFailed: message => failed.push(message),
  });
  return { instance, done, failed, errors: shared.errors };
}

function editorPage(store) {
  const shared = commonBindings(store), windowCalls = [], navigations = [], windowFault = { operation: '' };
  // 真 SDK 的窗口 API 返回 Promise；以异步拒绝替代同步 throw，才能检测遗漏的 rejection handler。
  const windowOperation = async operation => {
    if (windowFault.operation === operation) throw new Error('window ' + operation + ' rejected');
  };
  const instance = subject('entry/src/main/ets/pages/LayoutEditorPage.ets', [
    'aboutToAppear', 'prepareEditorPage_', 'restorePageTransaction_', 'releaseEditorLease_',
    'reportEditorPageError_', 'finishEditorPage_', 'cleanupEditorPage_', 'applyEditorWindowStyle_', 'aboutToDisappear',
  ], ['ready', 'loadError', 'targetProfileName', 'editorLeaseHeld', 'pageMounted', 'pageGeneration', 'pageCompleted',
    'preparationTask', 'cleanupTask'], {
    ...shared.values, ProductInputProfile: { supportsTouchLayouts: () => true, selection: () => ({ desktopWindow: false }) },
    window: { Orientation: { LANDSCAPE: 'landscape', UNSPECIFIED: 'unspecified' }, getLastWindow: async () => {
      await windowOperation('get');
      return { setPreferredOrientation: async value => { windowCalls.push(value); await windowOperation('orientation'); },
        setWindowLayoutFullScreen: async () => { await windowOperation('fullscreen'); },
        setWindowSystemBarEnable: async () => { await windowOperation('bars'); } };
    } },
  });
  Object.assign(instance, { getAbilityContext: () => ({}), getUIContext: () => ({ getRouter: () => ({
    getParams: () => ({ profileName: store.active.name }), back: () => navigations.push('back'),
  }) }) });
  return { instance, windowCalls, navigations, windowFault, errors: shared.errors };
}

// 打开阶段：拒绝、null、副本持久化失败和 native pause 抛错都必须恢复触控与租约。
for (const failure of ['reject', null]) {
  const store = makeStore(true); store.failures.set('clone', failure);
  const test = gameControls(store);
  await test.instance.openEditor();
  assert.equal(test.instance.editing, false); assert.deepEqual(test.pause, [true, false]);
  assert.equal(store.leases, 0); assert.equal(store.active.name, '原方案'); assert.ok(test.notices.length > 0);
  check('GameControls clone ' + String(failure) + ' 不留下暂停/编辑器/租约');
}
{
  const store = makeStore(); store.permitLease = false; const test = gameControls(store);
  await test.instance.openEditor(); assert.deepEqual(test.pause, []); assert.equal(store.leases, 0); assert.ok(test.notices[0].includes('同步'));
  check('同步期间打开被拒绝，不取得 pause/lease');
}
{
  const store = makeStore(), test = gameControls(store); test.instance.pauseFails = true;
  await test.instance.openEditor(); assert.deepEqual(test.pause, [true, false]); assert.equal(store.leases, 0);
  check('native pause 抛错仍尝试恢复触控');
}
{
  const store = makeStore(true), wait = deferred(); store.blocks.set('clone', wait);
  const test = gameControls(store), first = test.instance.openEditor();
  await test.instance.openEditor(); assert.equal(store.events.filter(name => name === 'clone').length, 1);
  test.instance.aboutToDisappear(); assert.deepEqual(test.pause, [true, false]);
  wait.resolve(); await first;
  assert.equal(test.instance.editing, false); assert.equal(store.active.name, '原方案'); assert.equal(store.leases, 0); assert.deepEqual(test.changes, []);
  check('clone await 期间销毁，迟到结果只回滚、不重开 editor');
}
{
  const store = makeStore(true), test = gameControls(store); await test.instance.openEditor();
  assert.equal(test.instance.editing, true); assert.equal(store.leases, 1);
  test.instance.aboutToDisappear(); await test.instance.editorDisposeTask;
  assert.equal(store.active.name, '原方案'); assert.equal(store.leases, 0); assert.deepEqual(test.pause, [true, false]);
  check('overlay 尚未 mount 即父组件销毁仍恢复预设克隆事务');
}
{
  const store = makeStore(true), test = gameControls(store); await test.instance.openEditor();
  await store.restoreEditorTransaction(); test.instance.finishEditor_(null); test.instance.finishEditor_(null);
  assert.equal(test.instance.profile.name, '原方案'); assert.equal(store.leases, 0); assert.deepEqual(test.pause, [true, false]);
  check('取消回到恢复后的原方案/schema，重复完成不重复释放');
}

// 保存及各 mutation 的拒绝/false 保留本地草稿，不 commit、不 onDone；同按钮可重试。
for (const [operation, action, argument] of [
  ['save', 'saveEditor_'], ['reset', 'resetEditorProfile_'], ['switch', 'switchEditorProfile_', '其他方案'],
  ['delete', 'deleteEditorProfile_', '原方案'], ['create', 'createEditorProfile_'],
]) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.45; const draft = copy(test.instance.draft);
  store.failures.set(operation, 'reject'); test.instance[action](argument); await test.instance.persistenceTask;
  assert.deepEqual(test.instance.draft, draft); assert.equal(test.instance.persistenceBusy, false);
  assert.equal(store.leases, 1); assert.deepEqual(test.done, []); assert.ok(!store.events.includes('commit')); assert.match(test.instance.statusMsg, /失败/);
  if (operation === 'reset') assert.equal(test.instance.undoCount, 0);
  test.instance.aboutToDisappear(); await test.instance.editorCleanupTask; assert.equal(store.leases, 0);
  check('LayoutEditor ' + operation + ' reject 保留草稿并可取消/销毁');
}
for (const [operation, action, argument] of [
  ['reset', 'resetEditorProfile_'], ['switch', 'switchEditorProfile_', '其他方案'],
  ['delete', 'deleteEditorProfile_', '原方案'], ['create', 'createEditorProfile_'],
]) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.45;
  test.instance[action](argument); await test.instance.persistenceTask;
  assert.equal(test.instance.profileName, store.active.name); assert.equal(test.instance.persistenceBusy, false);
  assert.equal(test.done.length, 0); assert.equal(store.leases, 1);
  if (operation === 'reset') assert.equal(test.instance.undoCount, 1);
  test.instance.cancelEditor_(); await test.instance.persistenceTask;
  assert.equal(store.active.name, '原方案'); assert.equal(store.active.controls[0].xPct, 0.1);
  check('LayoutEditor ' + operation + ' 正常确认更新草稿，取消仍恢复最初事务');
}
for (const failure of [false, 'reject']) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  const draft = copy(test.instance.draft); store.failures.set('restore', failure);
  test.instance.cancelEditor_(); await test.instance.persistenceTask;
  assert.deepEqual(test.done, []); assert.deepEqual(test.instance.draft, draft); assert.equal(test.instance.editorClosed, false); assert.equal(store.leases, 1);
  store.failures.delete('restore'); test.instance.cancelEditor_(); await test.instance.persistenceTask;
  assert.deepEqual(test.done, [null]); assert.equal(store.leases, 0);
  test.instance.cancelEditor_(); assert.deepEqual(test.done, [null]);
  check('cancel ' + String(failure) + ' 不伪成功，重试确认后只通知一次');
}
{
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  store.failures.set('save', false); test.instance.saveEditor_(); await test.instance.persistenceTask;
  assert.equal(test.done.length, 0); assert.equal(store.events.includes('commit'), false);
  store.failures.delete('save'); const wait = deferred(); store.blocks.set('save', wait);
  test.instance.saveEditor_(); test.instance.saveEditor_(); test.instance.cancelEditor_();
  assert.equal(store.events.filter(name => name === 'save').length, 2); assert.equal(test.done.length, 0);
  wait.resolve(); await test.instance.persistenceTask;
  assert.equal(test.done.length, 1); assert.equal(store.events.filter(name => name === 'commit').length, 1); assert.equal(store.leases, 0);
  check('save false不提交；并发保存/取消只执行一次，持久确认后commit/onDone');
}
{
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.8;
  const wait = deferred(); store.blocks.set('save', wait); test.instance.saveEditor_();
  test.instance.aboutToDisappear(); test.instance.aboutToDisappear(); wait.resolve(); await test.instance.editorCleanupTask;
  assert.deepEqual(test.done, []); assert.equal(store.events.includes('commit'), false); assert.equal(store.active.controls[0].xPct, 0.1); assert.equal(store.leases, 0);
  check('保存等待中销毁：等操作落定后恢复事务，无迟到onDone/双重cleanup');
}
// 同一组件实例重新出现时 mounted 会恢复为 true，不能让上一代的异步保存因此重新取得提交权。
{
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.8;
  const wait = deferred(); store.blocks.set('save', wait); test.instance.saveEditor_();
  test.instance.aboutToDisappear(); const reopening = test.instance.aboutToAppear();
  wait.resolve(); await reopening;
  assert.deepEqual(test.done, [], '上一代迟到保存不能关闭重新出现的编辑器');
  assert.equal(store.events.includes('commit'), false, '已放弃的上一代事务不能重新提交');
  assert.equal(test.instance.draft.controls[0].xPct, 0.1); assert.equal(store.leases, 1);
  assert.equal(test.instance.editorReady, true); assert.equal(test.instance.editorClosed, false);
  test.instance.cancelEditor_(); await test.instance.persistenceTask; assert.equal(store.leases, 0);
  check('同实例重新出现：旧保存只回滚，新编辑器拥有独立的完成通知与租约');
}
for (const [operation, action, argument] of [
  ['restore', 'cancelEditor_'], ['reset', 'resetEditorProfile_'], ['switch', 'switchEditorProfile_', '其他方案'],
  ['delete', 'deleteEditorProfile_', '原方案'], ['create', 'createEditorProfile_'],
]) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.8;
  const wait = deferred(); store.blocks.set(operation, wait); test.instance[action](argument);
  test.instance.aboutToDisappear(); const reopening = test.instance.aboutToAppear();
  wait.resolve(); await reopening;
  assert.deepEqual(test.done, []); assert.equal(test.instance.draft.controls[0].xPct, 0.1);
  assert.equal(test.instance.profileName, '原方案'); assert.equal(store.leases, 1);
  assert.equal(test.instance.editorReady, true); assert.equal(test.instance.editorClosed, false);
  test.instance.cancelEditor_(); await test.instance.persistenceTask; assert.equal(store.leases, 0);
  check('同实例重新出现：旧 ' + operation + ' 不通知完成或污染新草稿');
}
{
  const store = makeStore(true), controls = gameControls(store); await controls.instance.openEditor();
  const child = editor(store); child.instance.onDone = value => { child.done.push(value); controls.instance.finishEditor_(value); };
  await child.instance.aboutToAppear(); assert.equal(store.leases, 2);
  child.instance.cancelEditor_(); await child.instance.persistenceTask;
  child.instance.aboutToDisappear(); await child.instance.editorCleanupTask;
  assert.equal(store.leases, 0); assert.equal(controls.instance.profile.name, '原方案');
  assert.deepEqual(controls.pause, [true, false]); assert.deepEqual(child.done, [null]);
  check('真实父子方法组合：preset clone前基线跨nested lease保留，取消恢复touch/schema');
}
{
  const store = makeStore(), controls = gameControls(store); await controls.instance.openEditor();
  const child = editor(store); child.instance.onDone = value => { child.done.push(value); controls.instance.finishEditor_(value); };
  await child.instance.aboutToAppear(); child.instance.draft.controls[0].xPct = 0.6;
  child.instance.saveEditor_(); await child.instance.persistenceTask;
  child.instance.aboutToDisappear(); await child.instance.editorCleanupTask;
  assert.equal(store.leases, 0); assert.equal(controls.instance.profile.controls[0].xPct, 0.6);
  assert.deepEqual(controls.pause, [true, false]); assert.equal(store.events.filter(name => name === 'commit').length, 1);
  check('真实父子方法组合：保存确认后仅commit一次、安装新schema再恢复touch');
}
{
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear(); test.instance.invalidDraft = true;
  test.instance.saveEditor_(); await test.instance.persistenceTask;
  assert.equal(store.events.includes('save'), false); assert.equal(test.done.length, 0); assert.match(test.instance.statusMsg, /非法/);
  test.instance.cancelEditor_(); await test.instance.persistenceTask;
  check('非法草稿不进入存储，也不误报保存完成');
}
{
  const store = makeStore(), test = editor(store), wait = deferred(); store.blocks.set('ready', wait);
  const opening = test.instance.aboutToAppear(); test.instance.aboutToDisappear(); wait.resolve(); await opening; await test.instance.editorCleanupTask;
  assert.equal(store.leases, 0); assert.equal(store.events.includes('lease+'), false); assert.deepEqual(test.done, []);
  check('Editor未ready即销毁，不注册幽灵lease或回调');
}
for (const reason of ['ready-failed', 'sync-busy', 'invalid-profile']) {
  const store = makeStore(), test = editor(store);
  if (reason === 'ready-failed') store.failures.set('ready', 'reject');
  if (reason === 'sync-busy') store.permitLease = false;
  if (reason === 'invalid-profile') store.active.invalid = true;
  await test.instance.aboutToAppear(); assert.equal(test.instance.editorReady, false); assert.equal(store.leases, 0);
  assert.equal(test.failed.length, 1); assert.deepEqual(test.done, []); assert.match(test.instance.statusMsg, /失败/);
  check('Editor初始化 ' + reason + ' 明确失败且归还lease');
}

// 父页在 child 尚未 mount 时也拥有事务；初始化失败、离开期间续体都不能越界写UI。
for (const operation of ['init', 'clone', 'switch']) {
  const store = makeStore(operation === 'clone'), test = editorPage(store); store.failures.set(operation, 'reject');
  await test.instance.aboutToAppear(); assert.equal(test.instance.ready, false); assert.match(test.instance.loadError, /失败|无法/);
  assert.equal(store.leases, 0); assert.equal(store.active.name, '原方案');
  check('LayoutEditorPage ' + operation + ' 失败不渲染假成功编辑器');
}
{
  const store = makeStore(true), wait = deferred(), test = editorPage(store); store.blocks.set('clone', wait);
  const opening = test.instance.aboutToAppear(); await Promise.resolve(); await Promise.resolve();
  test.instance.aboutToDisappear(); wait.resolve(); await opening; await test.instance.cleanupTask;
  assert.equal(test.instance.ready, false); assert.equal(store.leases, 0); assert.equal(store.active.name, '原方案');
  assert.equal(test.windowCalls.includes('landscape'), false);
  check('父页clone尚未结束即离开，恢复基线且不迟到进入横屏');
}
{
  const store = makeStore(), test = editorPage(store); await test.instance.aboutToAppear();
  assert.equal(test.instance.ready, true); assert.equal(store.leases, 1);
  test.instance.aboutToDisappear(); await test.instance.cleanupTask; assert.equal(store.leases, 0);
  check('父页ready但child未mount即退出，仍恢复并释放租约');
}
{
  const store = makeStore(), test = editorPage(store); await test.instance.aboutToAppear();
  store.commitEditorTransaction(); test.instance.finishEditorPage_(); test.instance.finishEditorPage_();
  test.instance.aboutToDisappear(); await test.instance.cleanupTask;
  assert.deepEqual(test.navigations, ['back']); assert.equal(store.leases, 0);
  check('父页完成/销毁只返回一次，不回滚已确认保存');
}
for (const operation of ['get', 'orientation', 'fullscreen', 'bars']) {
  const unhandled = [], observe = error => unhandled.push(error);
  process.on('unhandledRejection', observe);
  try {
    const store = makeStore(), test = editorPage(store); await test.instance.aboutToAppear();
    test.windowFault.operation = operation; test.instance.aboutToDisappear(); await test.instance.cleanupTask;
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(unhandled, [], '窗口恢复的异步失败必须收口：' + operation);
    assert.equal(store.leases, 0);
    check('父页窗口恢复 ' + operation + ' 异步拒绝不泄漏 Promise、不影响事务释放');
  } finally { process.off('unhandledRejection', observe); }
}
// 进入窗口样式设置同样使用 Promise，不应把系统样式失败扩大成存储失败或拒绝泄漏。
for (const operation of ['get', 'orientation', 'fullscreen', 'bars']) {
  const unhandled = [], observe = error => unhandled.push(error);
  process.on('unhandledRejection', observe);
  try {
    const store = makeStore(), test = editorPage(store); test.windowFault.operation = operation;
    await test.instance.aboutToAppear(); await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(unhandled, []); assert.equal(test.instance.ready, true); assert.equal(store.leases, 1);
    test.windowFault.operation = ''; test.instance.aboutToDisappear(); await test.instance.cleanupTask;
    check('父页窗口进入 ' + operation + ' 异步拒绝不影响编辑事务初始化');
  } finally { process.off('unhandledRejection', observe); }
}

// 模板接线也是契约：所有存储按钮落到被执行测试的方法，busy期间禁止草稿继续变化。
const editorSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/LayoutEditor.ets'), 'utf8');
for (const name of ['saveEditor_', 'cancelEditor_', 'resetEditorProfile_', 'switchEditorProfile_', 'deleteEditorProfile_', 'createEditorProfile_']) {
  assert.ok(editorSource.includes('this.' + name + '('), 'UI 未接入 ' + name);
}
assert.ok(editorSource.includes('.enabled(!this.persistenceBusy)'));
assert.equal(/\.onClick\(async/.test(editorSource), false, '持久化按钮不可重新引入未收口的 async 回调');
console.log('[layout-editor-failures] PASS ' + passed + ' production-method scenarios; host UI/storage boundaries only');

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
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
const {LayoutEditSession}=makePureEtsLoader()('gamecontrol/src/main/ets/LayoutEditSession.ets');
const {TouchGuide}=makePureEtsLoader()('gamecontrol/src/main/ets/TouchGuide.ets');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const copy = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
let passed = 0;
function check(name) { passed++; console.log('PASS ' + name); }

/** 匹配单个真实方法，跳过字符串和注释中的花括号；复杂ArkUI布局不在宿主执行，纯产品包装build保留真实调用。 */
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
    new RegExp('^  (?:@State )?(?:@Watch\\([^\\n]*?\\) )?(?:private )?' + name + '\\s*:').test(line)))
    .map(line => line.replace(/@State\s*|@Watch\([^\n]*?\)\s*/g, ''));
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
    removeInputConfigurationListener() {},
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
    getProfile(name) { return copy(store.profiles.find(profile => profile.name === name) ?? null); },
    getProfileNames() { return store.profiles.map(profile => profile.name); }, getCurrentDeviceType() { return 'tablet'; },
    cloneAsUser(name) { return store.invoke('clone', () => {
      // Store 是外部确认边界，但返回对象仍须属于传入目标；复制当前 active 会让预设切换误测成成功。
      const target = store.profiles.find(profile => profile.name === name);
      assert.ok(target, 'cloneAsUser 必须收到目录中真实存在的方案名');
      const profile = { ...copy(target), name: name + ' 副本', isPreset: false };
      store.active = profile; store.profiles.push(profile); return profile;
    }); },
    saveEditedProfile(profile) { return store.invoke('save', () => { store.active = copy(profile); return copy(profile); }); },
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
  // Native边界只管理具名token；pause记录模态集合从空到非空及归还，不再伪造全域取消。
  const shared = commonBindings(store), pause = [], order = [], notices = [], changes = [], nativeModals=new Map();let nextModal=1;
  const napi={acquireTouchModal:owner=>{
    order.push('modal+');if(instance.pauseFails)throw Error('modal acquire failed');
    const token=String(nextModal++);nativeModals.set(token,owner);pause.push(true);return token;
  },releaseTouchModal:token=>{
    assert.ok(nativeModals.has(token),'只归还自己的Native模态token');nativeModals.delete(token);pause.push(false);order.push('modal-');return true;
  }};
  const modal=environment({imports:{'libentry.so':{default:napi}}}).load('entry/src/main/ets/components/EntryTouchModalBroker.ets');
  // 直接装载当前只读观察登记端口；销毁执行真实解绑，不能补一个空函数隐藏资源清理遗漏。
  const observation=makePureEtsLoader()('entry/src/main/ets/components/EntryInputObservationPort.ets');
  const instance = subject('entry/src/main/ets/components/GameControls.ets', [
    'openEditor', 'closeEditorChoice_', 'releaseEditorLease_', 'restoreDisposedEditor_', 'resumeEditorInput_', 'showEditorError_',
    // 游戏内引导不再占有暂停；抽取保存反馈接线，销毁只停止进度观察。
    'finishEditor_', 'editorInitializationFailed_', 'aboutToDisappear', 'syncGuideBounds', 'guideToolbarX',
    // 生产销毁新增只读配置订阅回收；装载真实 helper/原字段，不能用 noop 绕过生产清理。
    'retireConfigurationStatus_',
  ], ['editing', 'editorOpening', 'editorLeaseHeld', 'editorInputPaused', 'editorDisposeTask', 'mounted', 'appearanceGeneration',
    'configurationStatusSubscription', 'configurationStatusStore', 'observationRegistration', 'groupRegistration', 'pendingGroupCommands'], {
    ...shared.values, ...modal, ...observation,testNapi:napi,
    getInputSourceRegistry: () => ({ unregister() {} }), getInputDeviceMonitor: () => ({ removeCapabilityListener() {} }),
    releaseEntryControlFeedback() {},
  });
  Object.assign(instance, { mounted: true, appearanceGeneration: 1, profile: copy(store.active), profileVer: 0,
    // 与其余平台边界一样隔离视觉会话；这里验证编辑器失败不漏掉输入/租约的释放。
    touchSession: { stop() {} }, touchGuide:new TouchGuide(),tutorialOpen:false,
    touchSurface:{dispose(){}},imeModal:undefined,editorModal:undefined,layoutObserverRegistered:false,
    runtimeLayout:{context:{key:''}},uiPublicationToken:'',
    onInputPause() {},
    releaseAllDirections() {}, buttonReleaseAllFingers() {}, resetTransientInputState() { order.push('self-release'); },
    schemaActive: false,
    onLayoutChanged() { changes.push(instance.profile.name); },
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => notices.push(value.message) }) }),
  });
  return { instance, pause, order, notices, changes,nativeModals, errors: shared.errors };
}

function editor(store) {
  const shared = commonBindings(store), done = [], failed = [];
  const instance = subject('entry/src/main/ets/components/LayoutEditor.ets', [
    'aboutToAppear', 'aboutToDisappear', 'cleanupDestroyedEditor_', 'restoreUnfinishedEditor_',
    'restoreUnfinishedEditorOnce_', 'releaseEditorLease_', 'reportPersistenceError_', 'runPersistence_',
    'performPersistence_', 'loadConfirmedProfile_', 'completeEditor_', 'saveEditor_', 'cancelEditor_',

  ], ['persistenceBusy', 'editorMounted', 'editorReady', 'editorClosed', 'editorGeneration', 'editorLeaseHeld',
    'editorTransactionOwned', 'persistenceTask', 'editorCleanupTask', 'restorationTask', 'profileName', 'statusMsg', 'baselineSig',
    'sessionCatalogChanged'], shared.values);
  Object.assign(instance, { targetProfileName:'',editSession:new LayoutEditSession(),screenWidth: 720, screenHeight: 360, draft: copy(store.active), undoCount: 0,
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

// 选择页没有子编辑器，直接关闭仍必须结束Store快照；失败保持原租约可重试。
{
  const store=makeStore(),test=gameControls(store);await test.instance.openEditor();
  assert.ok(store.snapshot);store.failures.set('restore',false);await test.instance.closeEditorChoice_();
  assert.equal(test.instance.editing,true);assert.equal(store.leases,1);assert.ok(store.snapshot);
  store.failures.delete('restore');await test.instance.closeEditorChoice_();
  assert.equal(test.instance.editing,false);assert.equal(store.leases,0);assert.equal(store.snapshot,undefined);
  check('选择页直接关闭先确认取消事务，失败不释放最后租约');
}
{
  const store=makeStore(),test=editor(store);test.instance.targetProfileName='其他方案';
  await test.instance.aboutToAppear();assert.equal(test.instance.draft.name,'其他方案');
  assert.equal(store.active.name,'原方案');assert.equal(store.events.includes('switch'),false);
  test.instance.cancelEditor_();await test.instance.persistenceTask;assert.equal(store.active.name,'原方案');
  check('显式编辑非活跃方案只读取目标，取消不改变活动方案');
}

// 进入预设无写入；副本只在最终保存时原子生成。
{
  const store=makeStore(true),test=gameControls(store);await test.instance.openEditor();
  assert.equal(test.instance.editing,true);assert.equal(store.events.includes('clone'),false);
  assert.equal(store.active.name,'原方案');assert.equal(store.profiles.length,2);
  await store.restoreEditorTransaction();test.instance.finishEditor_(null);assert.equal(store.leases,0);
  check('打开预设只读，取消不创建副本');
}
{
  const store = makeStore(); store.permitLease = false; const test = gameControls(store);
  await test.instance.openEditor(); assert.deepEqual(test.pause, []); assert.equal(store.leases, 0); assert.ok(test.notices[0].includes('同步'));
  assert.deepEqual(test.order, [], '被拒绝打开时不释放任何输入');
  check('同步期间打开被拒绝，不取得 pause/lease');
}
{
  // Native触控模态独立于页面其它输入routing，取得前先按记录退休ArkTS输出。
  const store = makeStore(), test = gameControls(store);
  await test.instance.openEditor();
  assert.deepEqual(test.order.slice(0, 2), ['self-release', 'modal+']);
  assert.equal(test.order.filter(item => item === 'self-release').length, 1, '打开流程只自释放一次');
  assert.equal(test.instance.editing, true);
  assert.equal(test.nativeModals.size,1);
  check('openEditor先由ArkTS自释放，再取得自己具名touch模态');
}
{
  const store = makeStore(), test = gameControls(store); test.instance.pauseFails = true;
  await test.instance.openEditor(); assert.deepEqual(test.pause, []); assert.equal(store.leases, 0);assert.equal(test.nativeModals.size,0);
  check('Native模态取得失败不伪造租约或解封，Store编辑租约仍收回');
}
{
  // 真实游戏引导仅观察进度；销毁不得凭空归还一个从未取得的输入暂停。
  const store=makeStore(), test=gameControls(store);
  test.instance.touchGuide.active=true;
  test.instance.aboutToDisappear();test.instance.aboutToDisappear();
  assert.deepEqual(test.pause,[]);assert.equal(test.instance.touchGuide.active,false);
  assert.equal(store.leases,0);
  check('真实引导销毁不改变输入暂停，编辑器未取得的租约不释放');
}
{
  const store = makeStore(true), test = gameControls(store); await test.instance.openEditor();
  assert.equal(test.instance.editing, true); assert.equal(store.leases, 1);
  test.instance.aboutToDisappear(); await test.instance.editorDisposeTask;
  assert.equal(store.active.name, '原方案'); assert.equal(store.leases, 0); assert.deepEqual(test.pause, [true, false]);
  check('overlay 尚未 mount 即父组件销毁仍恢复只读编辑事务');
}
{
  const store = makeStore(true), test = gameControls(store); await test.instance.openEditor();
  await store.restoreEditorTransaction(); test.instance.finishEditor_(null); test.instance.finishEditor_(null);
  assert.equal(test.instance.profile.name, '原方案'); assert.equal(store.leases, 0); assert.deepEqual(test.pause, [true, false]);
  check('取消回到恢复后的原方案/schema，重复完成不重复释放');
}

// 保存及各 mutation 的拒绝/false 保留本地草稿，不 commit、不 onDone；同按钮可重试。
for (const [operation, action, argument] of [
  ['save', 'saveEditor_'],
]) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.45; const draft = copy(test.instance.draft);
  store.failures.set(operation, 'reject'); test.instance[action](argument); await test.instance.persistenceTask;
  assert.deepEqual(test.instance.draft, draft); assert.equal(test.instance.persistenceBusy, false);
  assert.equal(store.leases, 1); assert.deepEqual(test.done, []); assert.ok(!store.events.includes('commit')); assert.match(test.instance.statusMsg, /失败/);
  assert.equal(test.instance.sessionCatalogChanged, false, '拒绝不能把未确认目录操作记成需要退出确认');
  if (operation === 'reset') assert.equal(test.instance.undoCount, 0);
  test.instance.aboutToDisappear(); await test.instance.editorCleanupTask; assert.equal(store.leases, 0);
  check('LayoutEditor ' + operation + ' reject 保留草稿并可取消/销毁');
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
  store.failures.set('save', null); test.instance.saveEditor_(); await test.instance.persistenceTask;
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
  ['restore', 'cancelEditor_'],
]) {
  const store = makeStore(), test = editor(store); await test.instance.aboutToAppear();
  test.instance.draft.controls[0].xPct = 0.8;
  const wait = deferred(); store.blocks.set(operation, wait); test.instance[action](argument);
  test.instance.aboutToDisappear(); const reopening = test.instance.aboutToAppear();
  wait.resolve(); await reopening;
  assert.deepEqual(test.done, []); assert.equal(test.instance.draft.controls[0].xPct, 0.1);
  assert.equal(test.instance.sessionCatalogChanged, false, '上一代迟到确认不得污染重新打开的目录变化标记');
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
  check('真实父子方法组合：预设只读基线跨nested lease保留，取消恢复touch/schema');
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
for (const operation of ['init']) {
  const store = makeStore(operation === 'clone'), test = editorPage(store); store.failures.set(operation, 'reject');
  await test.instance.aboutToAppear(); assert.equal(test.instance.ready, false); assert.match(test.instance.loadError, /失败|无法/);
  assert.equal(store.leases, 0); assert.equal(store.active.name, '原方案');
  check('LayoutEditorPage ' + operation + ' 失败不渲染假成功编辑器');
}
{
  const store = makeStore(true), wait = deferred(), test = editorPage(store); store.blocks.set('init', wait);
  const opening = test.instance.aboutToAppear(); await Promise.resolve(); await Promise.resolve();
  test.instance.aboutToDisappear(); wait.resolve(); await opening; await test.instance.cleanupTask;
  assert.equal(test.instance.ready, false); assert.equal(store.leases, 0); assert.equal(store.active.name, '原方案');
  assert.equal(test.windowCalls.includes('landscape'), false);
  check('父页初始化尚未结束即离开，恢复基线且不迟到进入横屏');
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

/** 从真实页面AST取唯一产品控制面入参，保留真实暂停箭头函数；不重写或复制其控制流。 */
function pageSurfaceProps() {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/McGamePage.ets'), 'utf8');
  const tree = compiler.createSourceFile('McGamePage.ets', source, compiler.ScriptTarget.Latest, true);
  const calls = [];
  function visit(node) {
    if (compiler.isCallExpression(node) && node.expression.getText(tree) === 'ProductGameControlSurface') calls.push(node);
    compiler.forEachChild(node, visit);
  }
  visit(tree);
  assert.equal(calls.length, 1, '必须读取真实页面中唯一的产品控制面');
  assert.ok(compiler.isObjectLiteralExpression(calls[0].arguments[0]));
  const input = 'module.exports=function(){return ' + calls[0].arguments[0].getText(tree) + ';};';
  const result = compiler.transpileModule(input, {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((result.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const module = {exports:{}};
  new Function('module', result.outputText)(module);
  return module.exports;
}

/** 执行真实产品包装build。平台绘制只作为边界，收到的props直接交给现有真实GameControls方法夹具。 */
async function exerciseProductSurface(source, loseFocus = false) {
  const store = makeStore(), controls = gameControls(store), frontendStates = [];
  const page = subject('entry/src/main/ets/pages/McGamePage.ets', ['updatePageInputActive', 'syncCursorLock'], [], {});
  Object.assign(page, {pageVisible:true, surfaceFocused:true, gameWindowReady:true, inputOverlayPaused:false,
    pageInputActive:true, gameWindowId:9, frontendLease:{id:'actual-page-lease'}, gameDir:'/game', realGameVersion:'26.4',
    isInGame:false, surfaceContextGeneration:3,
    sessionHost:{setFrontendState(lease, active, windowId) {
      assert.equal(lease, page.frontendLease); assert.equal(windowId, 9); frontendStates.push(active);
    }}});
  const props = pageSurfaceProps();
  const compiled = compiler.transpileModule('class Surface {\n' + method(source, 'build') + '\n}\nmodule.exports=Surface;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const module = {exports:{}}, received = [];
  new Function('module','ProductInputProfile','GameControls','DesktopGameControlSurface',compiled.outputText)(module,
    {current:()=>({acceptDirectTouchInGame:true})}, value => { received.push(value); Object.assign(controls.instance,value); },
    () => { throw Error('手机产品不能走桌面控制面'); });
  const surface = new module.exports();
  // 前端投影为false也必须穿过真实两层组件，不能被子组件默认true掩盖。
  page.pageInputActive=false; Object.assign(surface,props.call(page)); surface.build();
  assert.equal(received.at(-1).pageActive,false,'产品包装必须透传页面停用投影');
  page.pageInputActive=true; Object.assign(surface,props.call(page)); surface.build();
  await controls.instance.openEditor();
  assert.deepEqual(frontendStates,[false],'编辑暂停必须抵达页面Host资格');
  assert.equal(page.inputOverlayPaused,true);
  if (loseFocus) page.surfaceFocused=false;
  await controls.instance.closeEditorChoice_();
  assert.deepEqual(frontendStates,[false,!loseFocus],'取消必须沿真实页面事实恢复资格');
  assert.equal(page.inputOverlayPaused,false); assert.equal(store.leases,0);
  assert.deepEqual(controls.pause,[true,false],'页面暂停和Native touch模态分别成对收口');
}

const productSurfaceSource = fs.readFileSync(path.join(root,'entry/src/main/ProductGameControlSurface.ets'),'utf8');
await exerciseProductSurface(productSurfaceSource);
check('真实McGamePage→产品包装→GameControls：页面停用、编辑暂停与取消恢复贯通');
await exerciseProductSurface(productSurfaceSource,true);
check('真实产品包装：编辑期间失焦，取消不误恢复页面Host资格');
// 对真实包装源码各撤去一个必要端口，必须因对应行为断言失败；负控不改磁盘源。
for (const [pattern,message] of [
  [/pageActive:\s*this\.pageActive\s*,/, '产品包装必须透传页面停用投影'],
  [/onInputPause:\s*this\.onInputPause\s*,?/, '编辑暂停必须抵达页面Host资格'],
]) {
  const withdrawn = productSurfaceSource.replace(pattern,'');
  assert.notEqual(withdrawn,productSurfaceSource,'负控必须真实撤掉包装端口');
  await assert.rejects(exerciseProductSurface(withdrawn), error => error.code==='ERR_ASSERTION' && error.message.includes(message));
  check('产品包装端口撤回反控：'+message);
}

// 模板接线也是契约：所有存储按钮落到被执行测试的方法，busy期间禁止草稿继续变化。
const editorSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/LayoutEditor.ets'), 'utf8');
for (const name of ['saveEditor_', 'cancelEditor_']) {
  assert.ok(editorSource.includes('this.' + name + '('), 'UI 未接入 ' + name);
}
assert.ok(editorSource.includes('.enabled(!this.persistenceBusy)'));
assert.equal(/\.onClick\(async/.test(editorSource), false, '持久化按钮不可重新引入未收口的 async 回调');
console.log('[layout-editor-failures] PASS ' + passed + ' production-method scenarios; host UI/storage boundaries only');

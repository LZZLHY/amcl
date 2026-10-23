#!/usr/bin/env node
/** 配置HUD的真实订阅/分类/迟到通知回归；从退役试用测试迁出，覆盖独立保留。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const relative = 'entry/src/main/ets/components/GameControls.ets';
const source = fs.readFileSync(path.join(root, relative), 'utf8');
const load = makePureEtsLoader();
const layouts = load('gamecontrol/src/main/ets/ControlLayout.ets');
const geometry = load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const surfaces = load('gamecontrol/src/main/ets/InputSurfaceContext.ets');
const gui = load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const { layoutCapabilityIssue } = load('gamecontrol/src/main/ets/LayoutCandidate.ets');
const { TouchGuide } = load('gamecontrol/src/main/ets/TouchGuide.ets');
const copy = value => JSON.parse(JSON.stringify(value));
let passed = 0;
const check = name => { passed++; console.log('PASS ' + name); };

/** 提取生产方法时跳过字符串/注释的括号；UI Builder由单独接线断言覆盖。 */
function method(name) {
  const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\s*\\(', 'm').exec(source);
  assert.ok(match, '生产方法缺失：' + name);
  let index = source.indexOf('{', match.index), depth = 0, quote = '', line = false, block = false;
  for (; index < source.length; index++) {
    const ch = source[index], next = source[index + 1];
    if (line) { if (ch === '\n') line = false; continue; }
    if (block) { if (ch === '*' && next === '/') { block = false; index++; } continue; }
    if (quote) { if (ch === '\\') index++; else if (ch === quote) quote = ''; continue; }
    if (ch === '/' && next === '/') { line = true; index++; continue; }
    if (ch === '/' && next === '*') { block = true; index++; continue; }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue; }
    if (ch === '{') depth++;
    if (ch === '}' && --depth === 0) return source.slice(match.index, index + 1);
  }
  throw Error('生产方法不完整：' + name);
}

/** 连生产字段默认值一起转译，防止fixture预置trialing/lease掩盖真实初始状态。 */
function subject(methods, fields, bindings, extraFields = '') {
  const declarations = source.split(/\r?\n/).filter(line => fields.some(name =>
    new RegExp('^  (?:@State )?(?:private )?' + name + '\\s*:').test(line)))
    .map(line => line.replace(/@State\s*/g, ''));
  assert.equal(declarations.length, fields.length, '生产字段提取不完整');
  const input = 'class Subject {\n' + declarations.join('\n') + '\n' + extraFields + '\n' +
    methods.map(method).join('\n') + '\n}\nmodule.exports=Subject;';
  const compiled = compiler.transpileModule(input, { compilerOptions: {
    target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', ...Object.keys(bindings), compiled.outputText)(module, ...Object.values(bindings));
  return new module.exports();
}

/** Store是确认边界：试用调用任何写方法都会被记录，lease及事务始终由真实宿主方法持有。 */
function makeStore() {
  const active = layouts.getDefaultLayout(); active.name = '原用户方案'; active.isPreset = false;
  const store = { active, leases: 0, events: [], snapshot: undefined,
    beginEditorSession() { store.events.push('lease+'); store.leases++; return true; },
    endEditorSession() { assert.ok(store.leases > 0); store.leases--; store.events.push('lease-'); },
    beginEditorTransaction() { store.snapshot ??= copy(store.active); store.events.push('begin'); },
    getActiveProfile() { return store.active; }, isReady() { return true; },
    refreshDeviceDerivedLayout() { store.events.push('derive'); },
    removeInputConfigurationListener() {},
    async restoreEditorTransaction() { store.events.push('restore'); if (store.snapshot) store.active = copy(store.snapshot); store.snapshot = undefined; return true; },
    saveProfile() { throw Error('试用不允许调用saveProfile'); },
    commitEditorTransaction() { throw Error('试用不允许提交Store事务'); },
  };
  return store;
}

/**
 * HUD过滤执行真实订阅和真实展示方法，输入使用原模型快照与原格式化函数。
 * 观察报告不会因隐藏而变成Applied，也不以listener累计false次数猜测错误。
 */
const policyModel = makePureEtsLoader({ commons: { AppLogger: { warn() {}, error() {} } } })
  ('gamecontrol/src/main/ets/InputConfiguration.ets');
function policySnapshot(domains) {
  const snapshot = new policyModel.InputPolicyActivationSnapshot();
  Object.assign(snapshot, { sessionId: 21, generation: 7, profileId: 'confirmed-policy', profileRevision: 3,
    identityStage: 'Bound', definitionState: 'Saved', activationState: 'Pending' });
  snapshot.domains = domains.map(values => Object.assign(new policyModel.InputConfigurationStatus(), values));
  return snapshot;
}
function policyHudFixture() {
  let callback, removed = 0;
  const store = { addInputPolicyStatusListener(value) { callback = value; return {}; },
    removeInputPolicyStatusListener() { removed++; } };
  const view = subject(['subscribeConfigurationStatus_', 'retireConfigurationStatus_', 'configurationHudMessage_'],
    ['configurationStatusMessage', 'configurationStatusSnapshot', 'configurationStatusEditorPauseWait', 'configurationStatusSubscription',
      'configurationStatusStore'], { inputPolicyStatusMessage: policyModel.inputPolicyStatusMessage });
  Object.assign(view, { mounted: true, appearanceGeneration: 7, editing: true,
    editorInputPaused: true, editorModal: {} });
  view.subscribeConfigurationStatus_(store);
  return { view, emit: value => callback(value), store, removed: () => removed };
}
const editorWait = { name: 'touch-controls', pending: true, stage: 'Waiting', reason: 'FrontendInactive' };
{
  const test = policyHudFixture(), snapshot = policySnapshot([editorWait,
    { name: 'look-touch', stage: 'Applied', pending: false, failures: 19 }]);
  snapshot.domains[0].failures = 33;
  const original = JSON.stringify(snapshot); test.emit(snapshot);
  assert.equal(test.view.configurationHudMessage_(), '');
  assert.equal(test.view.configurationStatusMessage, policyModel.inputPolicyStatusMessage(snapshot));
  assert.equal(test.view.configurationStatusSnapshot, snapshot); assert.equal(JSON.stringify(snapshot), original);
  assert.equal(snapshot.domains[0].stage, 'Waiting'); assert.equal(snapshot.domains[0].pending, true);
  check('仅展示层隐藏本编辑器暂停等待，保留原消息、原快照与累计false次数');
}
{
  const test = policyHudFixture(), snapshot = policySnapshot([editorWait]); test.emit(snapshot);
  const message = test.view.configurationStatusMessage;
  for (const change of [{ editing: false }, { editorInputPaused: false }, { editorModal: undefined }]) {
    Object.assign(test.view, { editing: true,  editorInputPaused: true, editorModal: {} }, change);
    assert.equal(test.view.configurationHudMessage_(), message);
  }
  check('正常游戏或不再持有编辑暂停/模态时立即返回原报告');
}
{
  const test = policyHudFixture();
  for (const reason of ['SourceInactive', 'InputNotAdmitted']) {
    const gyro = { name: 'touch-gyro', pending: true, stage: 'Waiting', reason };
    test.emit(policySnapshot([editorWait, gyro])); assert.equal(test.view.configurationHudMessage_(), '');
    test.emit(policySnapshot([gyro])); assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  }
  check('陀螺仪准入等待仅可附随真实触控FrontendInactive，不能单独归因于编辑暂停');
}
{
  const test = policyHudFixture();
  for (const reason of ['ContactsEnding', 'NativeInstall', 'UiConfirmation', 'PreviousPublication',
    'CandidateInvalid', 'NativeUnavailable', 'PortUnavailable', 'StatusUnavailable', 'OutcomeUnknown',
    'FrontendRetired', 'ResourceChanged', 'ResourceUnavailable', 'NoCandidate', 'NotApplied', 'future-reason']) {
    test.emit(policySnapshot([editorWait, { name: 'touch-controls', pending: true, stage: 'Waiting', reason }]));
    assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage, reason);
  }
  for (const reason of ['unavailable', 'NativeVisualUnavailable', 'pending', 'retired',
    'unsubscribe-pending', 'retirement-pending', 'OutcomeUnknown']) {
    test.emit(policySnapshot([editorWait, { name: 'touch-gyro', pending: true, stage: 'Waiting', reason }]));
    assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage, 'gyro/' + reason);
  }
  check('实际发布过程、不可用与未知原因任一混入时保留整条原报告');
}
{
  const test = policyHudFixture();
  for (const change of [{ stage: 'Rejected' }, { terminalRejection: true },
    { capabilityIssue: 'UnsupportedFeature:drawer' }, { stage: 'Unknown' }, { pending: false }]) {
    test.emit(policySnapshot([{ ...editorWait, ...change }]));
    assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  }
  test.emit(policySnapshot([editorWait, { name: 'look-touch', stage: 'Applied', pending: false,
    capabilityIssue: 'capability unavailable' }]));
  assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  check('拒绝、能力问题及异常阶段优先保留，已应用标签不能掩盖能力错误');
}
{
  const test = policyHudFixture();
  for (const change of [{ identityStage: 'Preparing' }, { identityStage: 'Retired' },
    { identityStage: 'Unbound' }, { identityStage: 'Future' }, { activationState: 'OutcomeUnknown' }, { domains: [] }]) {
    test.emit(Object.assign(policySnapshot([editorWait]), change));
    assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  }
  test.emit(policySnapshot([{ name: 'touch-controls', stage: 'Applied', pending: false }]));
  assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  check('未绑定/结束/未知身份、空域和已生效报告不作为编辑暂停过滤对象');
}
{
  const test = policyHudFixture(), snapshot = policySnapshot([editorWait]); test.emit(snapshot);
  test.view.appearanceGeneration++; const previous = test.view.configurationStatusSnapshot;
  test.emit(policySnapshot([{ name: 'touch-controls', stage: 'Rejected', reason: 'CandidateInvalid' }]));
  assert.equal(test.view.configurationStatusSnapshot, previous);
  test.view.subscribeConfigurationStatus_(test.store);
  assert.equal(test.removed(), 1); assert.equal(test.view.configurationStatusMessage, '');
  assert.equal(test.view.configurationStatusSnapshot, undefined);
  check('原appearance防迟到和原仓库退订保持有效，新订阅同时清空展示快照');
}
{
  const test = policyHudFixture(); test.view.editing = false;
  test.emit(policySnapshot([editorWait]));
  assert.equal(test.view.configurationStatusEditorPauseWait, true);
  assert.equal(test.view.configurationHudMessage_(), test.view.configurationStatusMessage);
  test.view.editing = true;
  assert.equal(test.view.configurationHudMessage_(), '', '暂停报告可先于editing=true同步到达，无需第二次通知');
  check('进入编辑前的原暂停报告提前分类，离散编辑状态变化后立即正确过滤');
}
{
  const test = policyHudFixture(); let current = test.view.configurationStatusEditorPauseWait, writes = 0;
  // 只观察生产回调对响应字段的实际写次数，不用宿主setter模拟ArkUI渲染或推断帧数。
  Object.defineProperty(test.view, 'configurationStatusEditorPauseWait', {
    get: () => current, set: value => { writes++; current = value; }, configurable: true,
  });
  const applied = { name: 'look-touch', pending: false, stage: 'Applied' };
  test.emit(policySnapshot([editorWait, applied])); assert.equal(writes, 1);
  const message = test.view.configurationStatusMessage;
  const first = test.view.configurationStatusSnapshot;
  for (let i = 0; i < 20; i++) {
    const repeated = policySnapshot([editorWait, applied]); repeated.domains[0].failures = i;
    test.emit(repeated);
  }
  assert.notEqual(test.view.configurationStatusSnapshot, first);
  assert.equal(test.view.configurationStatusMessage, message); assert.equal(writes, 1);
  // 原格式化函数跳过已应用域，故能力字段改变可以保留同一文字，仍必须让分类变化唤醒展示。
  const issue = policySnapshot([editorWait, { ...applied, capabilityIssue: 'capability unavailable' }]);
  assert.equal(policyModel.inputPolicyStatusMessage(issue), message);
  test.emit(issue); assert.equal(writes, 2); assert.equal(test.view.configurationHudMessage_(), message);
  test.emit(issue); assert.equal(writes, 2);
  test.emit(policySnapshot([editorWait, applied])); assert.equal(writes, 3);
  assert.equal(test.view.configurationHudMessage_(), '');
  Object.defineProperty(test.view.configurationStatusSnapshot, 'domains', {
    get() { throw Error('渲染不应重新遍历原快照'); }, configurable: true,
  });
  assert.equal(test.view.configurationHudMessage_(), '');
  test.view.editing = false; assert.equal(test.view.configurationHudMessage_(), message);
  check('相同文字/同类新对象不重复写响应分类，同文字但能力分类变化仍更新可见性');
}
console.log('PASS ' + passed + ' input configuration HUD production groups; no app/device build performed');

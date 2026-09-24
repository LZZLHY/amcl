/** 执行真实页面的父子交接方法；模拟 OS PID/锁观测，策略仍来自生产纯函数。
 * 验证旧进程活着不能派发、仅新进程重试一次，以及异步出帧后故障不触发重启。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const registry = makePureEtsLoader()('launch/src/main/ets/GraphicsProfileRegistry.ets');
const policy = makePureEtsLoader({ launch: registry })('entry/src/main/ets/runtime/GraphicsRecoveryPolicy.ets');
/** 按方法边界抽取原文，任何方法改名或边界缺失均显式失败，避免执行手抄的控制流。 */
function methods(file, names, dependencies) {
  const source = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  const bodies = names.map(name => {
    const match = new RegExp('  private (?:async )?' + name + '\\(').exec(source); assert.ok(match, name);
    const end = source.indexOf('\n  }', match.index); assert.ok(end > match.index);
    return source.slice(match.index, end + 4);
  });
  const js = compiler.transpileModule('class Probe {\n' + bodies.join('\n') + '\n}\nmodule.exports=Probe;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new Function('module', ...Object.keys(dependencies), js)(module, ...Object.values(dependencies));
  return module.exports;
}
const id = '01234567-89ab-cdef-0123-456789abcdef';
const ticket = { id, parentPid: 21, activityId: 100, rootActivityId: 100, attempt: 0, createdAt: 1000,
  version: '26.2', mcDir: '/mc', gameDir: '/mc/world', jdk: '25', xmx: 2048, preferenceStamp: 'auto', retryProfile: '' };
const failure = { id, parentPid: 21, activityId: 100, childPid: 22, createdAt: 1200, profile: 'mobilegl',
  nextProfile: 'mobileglues', stage: 'admission', code: 'vulkan_capability_rejected', presentCount: 0, automatic: true };
for (const scenario of ['dead', 'waiting', 'alive', 'unknown', 'new-selection', 'explicit']) {
  let now = 1500, iterations = 0, claimed = 0; const dispatches = [];
  let subject;
  const Probe = methods('entry/src/main/ets/pages/Index.ets', ['recoverGraphics_'], {
    ...policy, Date: { now: () => now },
    setTimeout: fn => { now += 100; iterations++; if (scenario === 'new-selection') subject.pendingGraphicsRecoveryId_ = 'new'; fn(); },
    testNapi: { desktopProcessId: () => 21,
      desktopGameProcessState: () => scenario === 'unknown' ? -1 : scenario === 'waiting' && iterations < 2 ? 1 : 0,
      desktopProcessAlive: () => ['alive', 'new-selection'].includes(scenario) ? 1 : scenario === 'waiting' && iterations < 2 ? 1 : 0 },
    GraphicsHistoryStore: { outcome: () => undefined },
    GraphicsRecoveryStore: { ticket: () => ticket, failure: () => failure, claim: () => { claimed++; return true; } },
    DesktopLaunchSnapshot: { discard() {} }, AppLogger: { warn() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
  });
  subject = new Probe();
  Object.assign(subject, { graphicsRecoveryPolling_: false, pendingGraphicsRecoveryId_: id, context: { filesDir: '/sandbox' },
    mcVersion: '26.2', mcRoot: () => '/mc', graphicsPreferenceStamp_: () => scenario === 'explicit' ? 'mobilegl' : 'auto',
    safeToast_() {}, performLaunch: async retry => {
      assert.ok(scenario === 'dead' || iterations >= 2); dispatches.push(retry);
    } });
  await subject.recoverGraphics_();
  assert.equal(subject.graphicsRecoveryPolling_, false);
  if (['dead', 'waiting'].includes(scenario)) {
    assert.deepEqual(dispatches, [{ rootActivityId: 100, attempt: 1, profile: 'mobileglues' }]);
    await subject.recoverGraphics_(); assert.equal(claimed, 1, '不能重复消费故障');
    assert.equal(subject.preLaunchGameDir, ticket.gameDir);
  } else { assert.equal(dispatches.length, 0, scenario); assert.equal(claimed, 0, scenario); }
}
for (const frames of [0, 1, 400]) {
  const reports = []; let exits = 0, records = 0;
  const state = { schemaVersion: 1, pid: 22, profile: 'mobilegl', provider: 'GLFW', presentCount: frames,
    failureSequence: 1, failureStage: 'window-create-failed', failureCode: 0x3003, failurePresentCount: frames, surfaceGeneration: 1 };
  const Probe = methods('entry/src/main/ets/pages/McGamePage.ets', ['requestGraphicsRecovery_', 'pollGraphicsFailure_'], {
    ...policy, testNapi: { desktopProcessId: () => 22, mcGetGraphicsRuntimeFailure: () => JSON.stringify(state) },
    GraphicsRecoveryStore: { report: (_files, report) => reports.push(report) },
    AppStorage: { get: () => true }, AppLogger: { flush() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
  });
  const subject = new Probe();
  Object.assign(subject, { graphicsRecoveryTicket_: ticket, graphicsRecoveryAutomatic_: true, graphicsRecoveryNext_: 'mobileglues',
    graphicsCurrentProfile_: 'mobilegl', graphicsCurrentVersion_: '26.2', graphicsFaultHandled_: false, mcStarted: true,
    context: { filesDir: '/sandbox' }, launchLogger_: () => ({ warn() {} }), recordLaunchFailure_: () => records++,
    reportGraphicsHistory_: () => {}, requestExit_: () => exits++ });
  subject.pollGraphicsFailure_(); subject.pollGraphicsFailure_();
  assert.equal(records, 1, '重复心跳只记录一次');
  assert.equal(reports.length, frames === 0 ? 1 : 0); assert.equal(exits, frames === 0 ? 1 : 0);
  if (!frames) assert.equal(reports[0].childPid, 22);
}
console.log('graphics-recovery-handoff PASS: actual parent wait/claim/dispatch and child asynchronous post-frame refusal');

// 调用真实页面采集器，证明5秒节流、倒退时钟、退出强制快照和PID/后端身份拒绝。
// 只替换NAPI与日志系统边界，JSON校验继续执行生产解析器。
{
  let now = 10000, reads = 0;
  const logs = [];
  const state = { schemaVersion: 1, pid: 22, profile: 'mobilegl', provider: 'SDL3', apiFamily: 'OPENGL',
    presentCount: 17, failureSequence: 0, failureStage: '', failureCode: 0, failurePresentCount: 0, surfaceGeneration: 3 };
  const Probe = methods('entry/src/main/ets/pages/McGamePage.ets', ['collectGraphicsMetrics_'], {
    ...policy, Date: { now: () => now }, testNapi: { desktopProcessId: () => 22,
      mcGetGraphicsRuntimeState: () => { reads++; return JSON.stringify(state); } }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
  });
  const subject = new Probe();
  Object.assign(subject, { mcStarted: true, graphicsFirstPresentAt_: 0, reportGraphicsHistory_: () => {}, graphicsCurrentProfile_: 'mobilegl', graphicsMetricsAt_: 0,
    launchLogger_: () => ({ info: (_tag, text) => logs.push(text), warn() {} }) });
  subject.collectGraphicsMetrics_();
  assert.equal(reads, 1); assert.match(logs[1], /present_count=17/);
  now += 4999; subject.collectGraphicsMetrics_(); assert.equal(reads, 1);
  now++; state.presentCount = 18; subject.collectGraphicsMetrics_(); assert.equal(reads, 2);
  subject.collectGraphicsMetrics_(true); assert.equal(reads, 3);
  now = 1; subject.collectGraphicsMetrics_(); assert.equal(reads, 4, '墙钟倒退不能无限停止采集');
  state.pid = 23; subject.collectGraphicsMetrics_(true); assert.equal(logs.length, 8);
  state.pid = 22; state.profile = 'mobileglues'; subject.collectGraphicsMetrics_(true); assert.equal(logs.length, 8);
  subject.mcStarted = false; subject.collectGraphicsMetrics_(true); assert.equal(reads, 6);
}
console.log('graphics-observation collector PASS: production page scheduling, final snapshot, identity guards');

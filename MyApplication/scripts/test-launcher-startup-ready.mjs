/** 首页准入与启动派发回归：执行真实Index方法，核实等待边界和父意图失败交接。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

/** 可控的真实 Promise 边缘；用于模拟本地文件完成回调，绝不重新实现页面就绪判断。 */
function deferred() {
  let resolve;
  const promise = new Promise(value => { resolve = value; });
  return { promise, resolve };
}

/** 仅提取生产等待方法进行宿主执行；ArkUI 的可见/输入绑定另由 SDK 与真机 Trace 验证。 */
function fixture() {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const start = source.indexOf('  private async completeLauncherStartup_(): Promise<void> {');
  const end = source.indexOf('\n  onPageShow()', start);
  assert.ok(start > 0 && end > start, '必须执行实际生产方法');
  const code = compiler.transpileModule('class Probe {\n' + source.slice(start, end)
    + '\n}\nmodule.exports = Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} };
  new Function('module', 'AppLogger', 'TAG', 'LOG_DOMAIN_LAUNCH', code)(
    module, { info() {}, warn() {} }, 'test', 1);
  const subject = new module.exports();
  let homeVisibleCalls = 0;
  Object.assign(subject, { launcherStartupReady_: false, launcherStartupFailed_: false,
    launcherStartupAttempt_: 0, launcherStartupJobs_: [], sessionRecoveryTask_: Promise.resolve(),
    sessionRecoveryError_: null, consumeLastSession() {},
    // 观测引擎边界：实际可见性合成另有生产方法测试；这里核实等待成功后才通知宿主。
    onHomeTabVisibilityChanged_() { homeVisibleCalls++; } });
  return { subject, homeVisibleCalls: () => homeVisibleCalls };
}

/** 给实际等待方法进入下一次事件循环的机会，不以宿主计时推断设备性能。 */
const turn = () => new Promise(resolve => setTimeout(resolve, 1));

test('真实首页等待方法必须等本地初始化与恢复完成，不能只等页面构造', async () => {
  const { subject, homeVisibleCalls } = fixture();
  const local = deferred(), recovery = deferred();
  subject.launcherStartupJobs_ = [local.promise];
  subject.sessionRecoveryTask_ = recovery.promise;
  const operation = subject.completeLauncherStartup_();
  await turn(); assert.equal(subject.launcherStartupReady_, false); assert.equal(homeVisibleCalls(), 0);
  local.resolve(); await turn(); assert.equal(subject.launcherStartupReady_, false); assert.equal(homeVisibleCalls(), 0);
  recovery.resolve(); await operation;
  assert.equal(subject.launcherStartupReady_, true);
  assert.equal(subject.launcherStartupFailed_, false);
  assert.equal(homeVisibleCalls(), 1);
});

test('等待期间追加的真实恢复任务仍阻止首页准入', async () => {
  const { subject, homeVisibleCalls } = fixture();
  const old = deferred(), added = deferred();
  subject.sessionRecoveryTask_ = old.promise;
  const operation = subject.completeLauncherStartup_();
  await turn(); subject.sessionRecoveryTask_ = added.promise; old.resolve();
  await turn(); assert.equal(subject.launcherStartupReady_, false); assert.equal(homeVisibleCalls(), 0);
  added.resolve(); await operation; assert.equal(subject.launcherStartupReady_, true); assert.equal(homeVisibleCalls(), 1);
});

test('恢复失败保留准备状态，重试完成后才开放首页', async () => {
  const { subject, homeVisibleCalls } = fixture();
  subject.sessionRecoveryError_ = new Error('history write unavailable');
  await subject.completeLauncherStartup_();
  assert.equal(subject.launcherStartupReady_, false);
  assert.equal(subject.launcherStartupFailed_, true);
  assert.equal(homeVisibleCalls(), 0, '失败回调不能发布首页可见事实');
  subject.sessionRecoveryError_ = null;
  await subject.completeLauncherStartup_();
  assert.equal(subject.launcherStartupReady_, true);
  assert.equal(subject.launcherStartupFailed_, false);
  assert.equal(homeVisibleCalls(), 1, '只有成功重试才能发布一次首页可见事实');
});

test('组件销毁后的旧异步回调不能发布首页就绪', async () => {
  const { subject, homeVisibleCalls } = fixture();
  const recovery = deferred(); subject.sessionRecoveryTask_ = recovery.promise;
  const operation = subject.completeLauncherStartup_();
  subject.launcherStartupAttempt_++; recovery.resolve(); await operation;
  assert.equal(subject.launcherStartupReady_, false);
  assert.equal(subject.launcherStartupFailed_, false);
  assert.equal(homeVisibleCalls(), 0, '销毁代次失效后不能发布首页可见事实');
});

/**
 * 只替换系统派发、快照准备和owner端口，编译执行生产Index的派发/失败/平板回调方法。
 * 此处核实页面交接顺序；owner真正原件写盘、身份CAS与迟到marker另由恢复owner真实IO测试验证。
 */
function dispatchFixture({ isolated = true, desktop = true, prepareError, dispatchError, trackError, withdrawn = true,
  recordError } = {}) {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('Index.ets', source, compiler.ScriptTarget.Latest, true);
  const struct = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'performLaunch'));
  assert.ok(struct, '必须提取实际生产派发方法');
  // 偏好服务改为惰性建立后，派发必须执行生产 getter。夹具只提供已经建立的偏好端口，
  // 不另写一个返回对象的方法绕过真实缓存判据；否则 getter 丢失也可能被宿主测试掩盖。
  const names = ['getPrefManager_', 'retainLaunchDispatchFailure_', 'performLaunch', 'startTabletGameForResult_', 'onDesktopLaunchError'];
  const members = names.map(name => {
    const member = struct.members.find(value => value.name?.getText(ast) === name);
    assert.ok(member, '生产方法不能消失：' + name);
    return source.slice(member.getStart(ast), member.end);
  });
  const compiled = compiler.transpileModule('class Probe {\n' + members.join('\n')
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const trace = [], failures = [], tracked = [], module = { exports: {} };
  let resultCallback;
  const owner = { async trackLaunch(id, token) {
    trace.push('track'); tracked.push({ id, token }); if (trackError) throw trackError;
  } };
  const runtime = {
    coordinator() { return owner; },
    async reportLaunchDispatchFailure(context, id, token, stage, error) {
      trace.push('retain'); failures.push({ context, id, token, stage, error });
      if (recordError) throw recordError;
      return withdrawn;
    }
  };
  const snapshot = {
    pending() { return false; },
    async prepare() {
      trace.push('prepare'); if (prepareError) throw prepareError;
      return { id: 'prepared-snapshot', account: 'private-account-snapshot' };
    },
    discard() { trace.push('discard'); }
  };
  const profile = { isolatedGameProcess: isolated, desktopWindow: desktop };
  const context = { filesDir: 'private-files', async startAbility() {
    trace.push('dispatch'); if (dispatchError) throw dispatchError;
  }, startAbilityForResult(want, callback) { trace.push('dispatch'); resultCallback = callback; } };
  const appStorage = new Map();
  // 本fixture固定default产品：没有既有游戏，商店准入在非store上严格是no-op。
  // 只注入新增边界，不改变下面对prepare/track/dispatch/失败原文的任何观察。
  const host = { isRunning: () => false };
  const admission = { assertToken() {}, installTicket() {} };
  new Function('module', 'SessionRecoveryRuntime', 'DesktopLaunchSnapshot', 'ProductInputProfile', 'testNapi',
    'GameLayoutJournal', 'GraphicsRecoveryStore', 'AppLogger', 'TAG', 'LOG_DOMAIN_LAUNCH', 'util', 'AppStorage',
    'getGameSessionHost', 'GameRunAdmission', compiled)(
    module, runtime, snapshot, { selection: () => profile, canChooseTabletProcess: () => false },
    { desktopGameProcessState: () => 0, desktopProcessId: () => 101, graphicsRecoveryMaintain() {} },
    { importPending: async () => ({ deferred: false, pending: 0, conflicts: [] }) },
    { create() { trace.push('ticket'); } }, { info() {}, warn() {}, error() {} }, 'test', 1,
    { generateRandomUUID: () => 'ca9e708e-95a8-47e8-b121-047129689112' },
    { setOrCreate: (key, value) => appStorage.set(key, value) }, () => host, admission);
  const subject = new module.exports();
  Object.assign(subject, { context, desktopPreparing: false, pendingDesktopSnapshot: '',
    pendingGraphicsRecoveryId_: '', pendingRunAdmission_: '', mcVersion: 'fixture-version', preLaunchGameDir: 'private-game',
    preLaunchJdkVersion: '21', preLaunchXmx: 512, prefManager_: {}, mcRoot: () => 'private-mc',
    // 本组检查首页已经交还输入后的游戏派发，不模拟冷启动动画未完成的状态。
    startupFinished_: true,
    graphicsPreferenceStamp_: () => 'preference-identity', safeToast_() {}, getUIContext: () => ({
      getRouter: () => ({ async pushUrl() { trace.push('dispatch'); if (dispatchError) throw dispatchError; } }),
      getPromptAction: () => ({ showToast() {} })
    }) });
  return { subject, trace, failures, tracked, appStorage,
    result(error, result = {}) { assert.ok(resultCallback); resultCallback(error, result); } };
}

test('真实快照准备失败不登记缺基线启动意图，成功准备才在派发前耐久track', async () => {
  const error = new Error('snapshot unavailable');
  const failed = dispatchFixture({ prepareError: error });
  await assert.rejects(() => failed.subject.performLaunch(), value => value === error);
  assert.deepEqual(failed.tracked, []); assert.deepEqual(failed.failures, []);
  const successful = dispatchFixture(); await successful.subject.performLaunch();
  assert.deepEqual(successful.trace, ['prepare', 'ticket', 'track', 'dispatch']);
  assert.equal(successful.tracked[0].token, 'ca9e708e-95a8-47e8-b121-047129689112');
});

test('真实Ability派发失败先保存原始异常，只在owner确认撤回时删除快照', async () => {
  const error = Object.assign(new Error('system dispatch rejected'), { code: 16000001 });
  const confirmed = dispatchFixture({ dispatchError: error });
  await assert.rejects(() => confirmed.subject.performLaunch(), value => value === error);
  assert.deepEqual(confirmed.trace, ['prepare', 'ticket', 'track', 'dispatch', 'retain', 'discard']);
  assert.equal(confirmed.failures[0].error, error);
  assert.equal(confirmed.failures[0].token, confirmed.tracked[0].token);
  for (const uncertain of [{ withdrawn: false }, { recordError: new Error('evidence sync uncertain') }]) {
    const protectedPage = dispatchFixture({ dispatchError: error, ...uncertain });
    await assert.rejects(() => protectedPage.subject.performLaunch(), value => value === error);
    assert.equal(protectedPage.trace.includes('discard'), false);
    assert.equal(protectedPage.subject.pendingDesktopSnapshot, 'prepared-snapshot');
    protectedPage.subject.desktopLaunchError = error.message;
    protectedPage.subject.onDesktopLaunchError();
    assert.equal(protectedPage.trace.includes('discard'), false, '后续错误展示也不能绕过owner保护删除快照');
  }
});

test('真实内嵌pushUrl异步拒绝必须交接父意图，不能仅捕获同步throw', async () => {
  const error = new Error('router promise rejected');
  const page = dispatchFixture({ isolated: false, dispatchError: error });
  await assert.rejects(() => page.subject.performLaunch(), value => value === error);
  assert.deepEqual(page.trace, ['track', 'dispatch', 'retain']);
  assert.equal(page.failures[0].stage, 'router.dispatch');
  assert.equal(page.failures[0].error, error);
});

test('真实track耐久确认失败保留注册原文，不能继续派发child或漏掉可见意图', async () => {
  const error = new Error('queue directory sync uncertain');
  for (const isolated of [true, false]) {
    const page = dispatchFixture({ isolated, trackError: error, withdrawn: false });
    await assert.rejects(() => page.subject.performLaunch(), value => value === error);
    assert.equal(page.trace.includes('dispatch'), false);
    assert.equal(page.failures[0].stage, isolated ? 'ability.intent' : 'router.intent');
    assert.equal(page.failures[0].error, error);
    assert.equal(page.failures[0].token, page.tracked[0].token);
  }
});

test('真实平板回调不等待整局结束，错误原文交接完成后才请求父页面恢复', async () => {
  const page = dispatchFixture({ desktop: false });
  await page.subject.performLaunch();
  assert.deepEqual(page.trace, ['prepare', 'ticket', 'track', 'dispatch']);
  const error = Object.assign(new Error('ability result rejected'), { code: 16000001 });
  page.result(error); assert.equal(page.trace.at(-1), 'retain');
  await turn();
  assert.deepEqual(page.trace, ['prepare', 'ticket', 'track', 'dispatch', 'retain', 'discard', 'dispatch']);
  assert.equal(page.failures[0].stage, 'ability.result');
  assert.equal(page.failures[0].error, error);
  assert.match(page.appStorage.get('desktopLaunchError'), /16000001/);
});

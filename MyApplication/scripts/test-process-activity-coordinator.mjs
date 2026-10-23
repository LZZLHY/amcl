/**
 * 执行真实进程预约、Registry 和页面启动入口，控制异步任务/平台边缘的完成顺序。
 * 本测试不创建 JVM，不声称手机进程已隔离；验证的是同进程退出前不能接纳持续文件工作，
 * 以及准备失败不会把进程永久锁死。临时文件不落工程，不复制生产准入算法。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { loader, root, ts } from './mod-install-test-runtime.mjs';
import path from 'node:path';

const noop = () => {};
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const turn = async () => { for (let index = 0; index < 20; index++) await Promise.resolve(); };
const log = { info: noop, warn: noop, error: noop, debug: noop };
let count = 0;
const pass = name => { count++; console.log('PASS: ' + name); };

function fixture() {
  const core = {};
  const load = loader({ commons: { AppLogger: log }, feature_core: core,
    'entry/ProductBuildProfile': { ProductBuildProfile: { storeChannel: false } },
    feature_system: {} });
  Object.assign(core, load('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets'));
  const registry = new (load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry)();
  const U = load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
  const admission = load('entry/src/main/ets/runtime/GameRunAdmission.ets').GameRunAdmission;
  const activities = core.ProcessActivityCoordinator.instance();
  return { registry, U, admission, activities };
}

function adapter(f, id, completion, options = {}) {
  const view = new f.U.UnifiedTaskView(); view.id = id; view.title = id;
  view.canCancel = true;
  return { view, start() { if (options.syncFailure) throw Error('sync task failure');
    return completion.promise.then(() => { view.state = f.U.UnifiedTaskState.DONE; }); },
    cancel: () => options.cancellation?.promise ?? Promise.resolve(),
    resume: () => completion.promise, retry: () => completion.promise,
    purgeNativeOwner: () => true, dispose: noop };
}

{
  const f = fixture(); const a = f.activities.acquireFileTask('导出');
  const b = f.activities.acquireFileTask('下载');
  assert.throws(() => f.admission.reserveProcessLaunch(false), /导出、下载/);
  a(); a(); assert.throws(() => f.activities.acquireSharedGame(), /导出、下载/);
  b(); const game = f.admission.reserveProcessLaunch(false);
  assert.throws(() => f.activities.acquireFileTask('导出'), /游戏正在/);
  game.releasePreparation(); game.releasePreparation();
  assert.throws(() => game.commitNativeDispatch(), /预约已失效/);
  const release = f.activities.acquireFileTask('导出'); release();
  pass('文件预约嵌套且释放幂等；检查与占位原子，失效游戏预约不能复活');
}
{
  const f = fixture(); const game = f.admission.reserveProcessLaunch(false);
  game.commitNativeDispatch(); game.releasePreparation();
  const task = adapter(f, 'denied', deferred());
  await assert.rejects(f.registry.enqueue(task), /游戏正在/);
  assert.equal(f.registry.listAll().length, 0);
  assert.throws(() => f.activities.acquireFileTask('导出'), /游戏正在/);
  pass('Native 已派发后即使返回失败或页面 finally，预约持续到真实进程结束');
}
{
  const f = fixture(); const release = f.activities.acquireFileTask('导出');
  assert.equal(f.admission.reserveProcessLaunch(true), undefined);
  const ready = deferred(); const running = f.registry.enqueue(adapter(f, 'parallel', ready));
  ready.resolve(); await running; release();
  pass('真实独立路线不预约父进程，导出和下载仍可同时运行');
}
{
  const f = fixture(); const gate = deferred(); const task = adapter(f, 'running', gate);
  const running = f.registry.enqueue(task);
  task.view.state = f.U.UnifiedTaskState.DONE;
  assert.throws(() => f.activities.acquireSharedGame(), /导出、下载/);
  gate.resolve(); await running;
  const game = f.activities.acquireSharedGame(); game.releasePreparation();
  pass('展示终态不会提前释放真实 action；Promise 收口后才允许共享游戏');
}
{
  const f = fixture(); f.registry.maxConcurrent = 1;
  const firstGate = deferred(), cleanup = deferred();
  const first = f.registry.enqueue(adapter(f, 'first', firstGate));
  const second = f.registry.enqueue(adapter(f, 'queued', deferred(), { cancellation: cleanup })).catch(error => error);
  const cancellation = f.registry.cancel('queued');
  await second; firstGate.resolve(); await first;
  assert.throws(() => f.activities.acquireSharedGame(), /导出、下载/);
  cleanup.resolve(); await cancellation;
  const game = f.activities.acquireSharedGame(); game.releasePreparation();
  pass('排队取消即使原 enqueue 已拒绝，取消文件清理仍持独立预约直到真正结束');
}
for (const failure of ['sync', 'async']) {
  const f = fixture(); const gate = deferred();
  const running = f.registry.enqueue(adapter(f, failure, gate, { syncFailure: failure === 'sync' }));
  if (failure === 'async') gate.reject(Error('async task failure'));
  await assert.rejects(running, new RegExp(failure + ' task failure'));
  const game = f.activities.acquireSharedGame(); game.releasePreparation();
  pass(failure + ' action 失败保留原错误，并在 Registry 真实 finally 后释放');
}
for (const action of ['resume', 'retry']) {
  const f = fixture(); const gate = deferred(); const task = adapter(f, action, gate);
  task.view.state = f.U.UnifiedTaskState.ERROR; task.view.canResume = true; task.view.canRetry = true;
  f.registry.adapters_.set(action, task); f.registry.orderedIds_.push(action);
  const game = f.activities.acquireSharedGame();
  let invoked = 0;
  const originalAction = task[action];
  task[action] = () => { invoked++; return originalAction(); };
  let notices = 0; f.registry.addListener(() => { notices++; });
  await f.registry[action](action).catch(error => { assert.match(error.message, /游戏正在/); });
  assert.equal(f.registry.runningIds_.length, 0);
  assert.equal(task.view.state, f.U.UnifiedTaskState.ERROR);
  assert.equal(invoked, 0);
  if (action === 'retry') {
    assert.match(task.view.errorMessage, /游戏正在/);
    assert.ok(notices > 0, '无 await 的卡片由真实 registry listener 接收准入原因');
  }
  game.releasePreparation(); const running = f.registry[action](action);
  assert.throws(() => f.activities.acquireSharedGame(), /导出、下载/);
  gate.resolve(); await running;
  const next = f.activities.acquireSharedGame(); next.releasePreparation();
  pass(action + ' 直接调度也经过准入，冲突不改写任务状态且正常执行后释放');
}

{
  const f = fixture(); const gate = deferred(); const task = adapter(f, 'retry-generation', gate);
  task.view.state = f.U.UnifiedTaskState.ERROR; task.view.canRetry = true;
  f.registry.adapters_.set(task.view.id, task); f.registry.orderedIds_.push(task.view.id);
  const game = f.activities.acquireSharedGame();
  const old = f.registry.retry(task.view.id); game.releasePreparation();
  // 前一 Promise 的拒绝 reaction 尚未执行，就在同一真实 adapter 上开始后继尝试。
  const next = f.registry.retry(task.view.id);
  task.view.errorMessage = '后继尝试自己的状态';
  await old; assert.equal(task.view.errorMessage, '后继尝试自己的状态');
  assert.equal(task.view.state, f.U.UnifiedTaskState.PREPARING);
  assert.throws(() => f.activities.acquireSharedGame(), /导出、下载/);
  gate.resolve(); await next;
  f.activities.acquireSharedGame().releasePreparation();
  pass('旧 retry 准入 catch 不覆盖同 adapter 已运行的后继，真实收口后无预约泄漏');
}

/** 提取整个生产 startMCOnce；只把其 JVM/窗口/输入资源端口作为显式控制边缘。 */
const pageSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/McGamePage.ets'), 'utf8');
const ast = ts.createSourceFile('McGamePage.ets', pageSource, ts.ScriptTarget.Latest, true);
const pageOwner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'startMCOnce'));
const startMethod = pageOwner.members.find(member => member.name?.getText(ast) === 'startMCOnce').getText(ast);
const nativeMethod = pageOwner.members.find(member => member.name?.getText(ast) === 'startMCInternal').getText(ast);
assert.match(nativeMethod, /processLaunch\.commitNativeDispatch\(\)[\s\r\n]*let rc = testNapi\.mcLaunchWithProfileV2/);

function pageFixture(f, isolated, work) {
  const code = ts.transpileModule('class Page {\n' + startMethod + '\n}\nreturn Page;',
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
  const Page = new Function('AppStorage', 'ProductInputProfile', 'GameRunAdmission', 'LOG_DOMAIN_LAUNCH', 'TAG', code)(
    { get: () => undefined }, { selection: () => ({ isolatedGameProcess: isolated, desktopWindow: false }) }, f.admission, 1, 'test');
  const page = new Page(); let current = true; let calls = 0;
  const host = { accepts: () => current, isRunning: () => false, waitPrepared: async () => true,
    bindActivity: noop, sessionActivity: () => 1 };
  Object.assign(page, { sessionHost: host, frontendLease: {}, context: {}, inputLifecycleEpoch: 1,
    navigatedAway: false, mcStarted: false, inputProductFailure_: '',
    getUIContext: () => ({ getRouter: () => ({ getParams: () => ({ activityId: 1 }) }) }),
    beginLaunchLedgerEarly_: noop, launchLogger_: () => log, recordLaunchFailure_: async () => {}, restoreGameWindow: async () => {},
    startMCInternal: async lease => { calls++; await work?.(lease); } });
  return { page, retire: () => { current = false; }, calls: () => calls };
}
{
  const f = fixture(); const release = f.activities.acquireFileTask('导出');
  const p = pageFixture(f, false);
  await p.page.startMCOnce(); assert.equal(p.calls(), 0);
  assert.match(p.page.statusText, /导出、下载或文件任务尚未结束/); release();
  const next = f.activities.acquireSharedGame(); next.releasePreparation();
  pass('页面冲突给出真实原因并记录准备失败，不启动 JVM、不取消原导出');
}
for (const committed of [false, true]) {
  const f = fixture(); const gate = deferred();
  const p = pageFixture(f, false, async lease => { if (committed) lease.commitNativeDispatch(); await gate.promise; });
  const running = p.page.startMCOnce(); await turn();
  assert.throws(() => f.activities.acquireFileTask('导出'), /游戏正在/);
  gate.reject(Error('controlled launch failure')); await running;
  if (committed) assert.throws(() => f.activities.acquireFileTask('导出'), /游戏正在/);
  else { const release = f.activities.acquireFileTask('导出'); release(); }
  pass('生产页面 finally 在 ' + (committed ? 'Native 已派发后保留预约' : 'Native 前失败时释放预约'));
}
{
  const f = fixture(); const release = f.activities.acquireFileTask('导出');
  const p = pageFixture(f, true); await p.page.startMCOnce();
  assert.equal(p.calls(), 1); assert.equal(p.page.statusText, undefined); release();
  pass('页面与实际 ProductInputProfile 的隔离路线一致，不误阻止独立游戏');
}
console.log('PASS: ' + count + ' process lifetime regression cases');

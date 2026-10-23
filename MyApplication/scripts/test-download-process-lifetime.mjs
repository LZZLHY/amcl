/**
 * 执行生产 DownloadManager 的进程预约边界。复用已有 Native 会话 fixture，只有 Native
 * executionSettled、回调投递、元数据 Promise 和时间由用例控制；不复制 Manager 算法。
 * 默认命令不需要设备/网络，不把宿主收敛回执表述为真机 JVM/下载验证。
 */
import assert from 'node:assert/strict';
import { harness } from '../tests/download-system/manager-session.mjs';
import { loader } from './mod-install-test-runtime.mjs';
const microtasks = async () => { for (let index = 0; index < 30; index++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
let count = 0; const pass = name => { count++; console.log('PASS: ' + name); };

{
  const { manager, engine, clock, spec, activities } = harness(); engine.finishSettled = false;
  const waiting = manager.createAndWait(spec('failed-body')).catch(error => error);
  engine.finish(1, 'Failed'); await waiting;
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  await clock.advance(1000); assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.records.get(1).executionSettled = true; await clock.advance(500);
  const game = activities.acquireSharedGame();
  assert.equal(manager.getTask(1).state, 'Failed', '失败历史保留，不靠删除卡片才放行');
  assert.throws(() => manager.resume(1), /游戏正在/);
  assert.equal(engine.records.get(1).executionEpoch, 1);
  game.releasePreparation(); assert.equal(manager.resume(1), true);
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.finishSettled = true; engine.finish(1, 'Failed'); await clock.advance(500);
  activities.acquireSharedGame().releasePreparation();
  pass('正文失败回调早于执行收敛仍保护进程；收敛后保留失败卡片，resume 原子重取预约');
}
{
  const { manager, engine, clock, spec, activities } = harness(); engine.finishSettled = false;
  const id = manager.createAndStart(spec('fire-and-forget'));
  engine.finish(id); await clock.advance(500);
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.records.get(id).executionSettled = true;
  assert.equal(manager.purgeTask(id), true);
  activities.acquireSharedGame().releasePreparation();
  await clock.advance(500); activities.acquireSharedGame().releasePreparation();
  pass('createAndStart 也持正文预约，成功 purge 释放；旧查询不能复活或重复释放');
}
{
  const { manager, engine, clock, spec, activities } = harness();
  engine.failProgress = true; engine.blockedPurges = 1000;
  let settled = false;
  const waiting = manager.createAndWait(spec('invisible')).catch(error => { settled = true; return error; });
  await clock.advance(31000);
  assert.equal(settled, false); assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.blockedPurges = 0; await clock.advance(250); assert.match((await waiting).message, /registration failed/);
  activities.acquireSharedGame().releasePreparation();
  pass('注册失败且业务尚未拿到 ID 的隐形 owner 持预约越过旧超时，实际 rollback purge 后释放');
}
{
  const { manager, engine, clock, spec, activities } = harness();
  engine.createTask = () => { throw Error('create failed before owner'); };
  await assert.rejects(manager.createAndWait(spec('create-failed')), /create failed/);
  activities.acquireSharedGame().releasePreparation(); await clock.advance(500);
  pass('Native create 之前失败不会遗留进程预约');
}
{
  const { api, manager, engine, clock, spec, activities } = harness(); engine.finishSettled = false;
  const waiting = manager.createAndWait(spec('rebound')).catch(error => error);
  api.setDownloadNativeEngine(null); engine.finish(1, 'Failed', undefined, false);
  api.setDownloadNativeEngine(engine); await clock.advance(0); await waiting;
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  assert.equal(manager.resume(1), true); await clock.advance(500);
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.finishSettled = true; engine.finish(1, 'Failed'); await clock.advance(500);
  activities.acquireSharedGame().releasePreparation();
  pass('桥解绑/重绑及同 taskId 新 epoch 不释放原执行预约，旧轮查询不放行新轮');
}
{
  const { manager, engine, clock, spec, activities } = harness();
  const waiting = manager.createAndWait(spec('missing-owner')).catch(error => error);
  engine.records.delete(1); await clock.advance(500); await waiting;
  activities.acquireSharedGame().releasePreparation();
  pass('Native 记录实际消失既结算旧等待者，也释放原进程预约');
}
for (const method of ['fetchText', 'fetchTextEx']) for (const success of [true, false]) {
  const { manager, engine, activities } = harness(); const response = deferred();
  engine.fetchText = () => response.promise;
  const waiting = manager[method]('https://fixture.invalid/meta').catch(error => error);
  assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  if (success) response.resolve({ ok: true, body: '{}', statusCode: 200 });
  else response.reject(Error('controlled HTTP failure'));
  const result = await waiting;
  if (!success) assert.match(result.message, /controlled HTTP failure/);
  activities.acquireSharedGame().releasePreparation();
  pass(method + ' 的 Native Promise ' + (success ? '成功' : '拒绝') + '前保护进程，真正结束后释放');
}
{
  const { api, manager, engine, clock, spec, activities } = harness(); engine.finishSettled = false;
  const timers = [];
  const load = loader({ './DownloadManager': api, commons: { AppLogger: { warn() {}, info() {}, error() {} } } },
    { setTimeout(fn) { timers.push(fn); return timers.length; } });
  const { SharedDownloadCoordinator } = load('feature_core/src/main/ets/download/SharedDownloadCoordinator.ets');
  manager.shared_ = new SharedDownloadCoordinator({
    run: (value, progress) => manager.createAndWait(value, progress),
    cancel: id => manager.cancel(id), purge: id => manager.purgeTask(id),
  });
  let settled = false; const request = spec('shared'); request.shareFiles = true;
  const waiting = manager.createAndWait(request).then(value => { settled = true; return value; });
  await microtasks(); engine.finish(1); await microtasks();
  assert.equal(settled, false); assert.throws(() => activities.acquireSharedGame(), /导出、下载/);
  engine.records.get(1).executionSettled = true;
  for (let index = 0; index < 10 && !settled; index++) {
    while (timers.length) timers.shift()();
    await clock.advance(250); await microtasks();
  }
  assert.equal((await waiting).success, true);
  activities.acquireSharedGame().releasePreparation();
  pass('真实共享虚拟 consumer 与正文 owner 共同保护，Native 收敛与消费者结账后才释放');
}
console.log('PASS: ' + count + ' DownloadManager process lifetime cases');

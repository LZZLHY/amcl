/** 运行生产owner补写调度，只控制平台timer和单项IO，不在夹具中重写退避/并发/可见性决策。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const settle = async () => { for (let n = 0; n < 25; n++) await Promise.resolve(); };
function fixture() {
  const timers = new Map(); let next = 0;
  const f = evidenceRuntime({ scheduling: {
    setTimeout(callback, delay) { const id = ++next; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
  }, imports: { './DownloadManager': { formatBytes: String } } });
  const Owner = f.load('feature_core/src/main/ets/download/TaskActivityOwner.ets').TaskActivityOwner;
  const owner = new Owner();
  return { owner, timers, async fire() {
    const [id, timer] = timers.entries().next().value; timers.delete(id); timer.callback(); await settle(); return timer.delay;
  }, close() { owner.setForeground(false); f.close(); } };
}

test('坏盘补写指数退避，后台不唤醒，前台wake重置且共享同一执行事务', async () => {
  const f = fixture(); let calls = 0;
  try {
    f.owner.foreground_ = true;
    f.owner.pending_.set(1, { async retryCommit() { calls++; throw new Error('disk full'); } });
    f.owner.scheduleRetry_(); assert.equal([...f.timers.values()][0].delay, 30000);
    assert.equal(await f.fire(), 30000); assert.equal([...f.timers.values()][0].delay, 60000);
    assert.equal(await f.fire(), 60000); assert.equal([...f.timers.values()][0].delay, 120000);
    f.owner.setForeground(false); assert.equal(f.timers.size, 0); assert.equal(f.owner.pending_.size, 1);
    const before = calls; await settle(); assert.equal(calls, before);
    f.owner.setForeground(true); await settle();
    assert.equal(calls, before + 1); assert.equal([...f.timers.values()][0].delay, 60000);
    let release; const gate = new Promise(resolve => { release = resolve; });
    f.owner.pending_.set(1, { async retryCommit() { calls++; await gate; } });
    f.owner.pending_.set(2, { async retryCommit() { calls++; } });
    const first = f.owner.flushPending(true), second = f.owner.flushPending(true);
    assert.equal(first, second); f.owner.setForeground(false); release(); await first;
    assert.equal(f.owner.pending_.size, 1, '后台边沿后不领取下一项'); assert.equal(f.timers.size, 0);
    f.owner.setForeground(true); await settle();
    assert.equal(f.owner.pending_.size, 0); assert.equal(f.owner.retryDelay_, 30000); assert.equal(f.timers.size, 0);
  } finally { f.close(); }
});

test('积压补写每四项让出真实timer，页面退后台后保留未处理原件', async () => {
  const f = fixture(); let calls = 0;
  try {
    for (let id = 1; id <= 9; id++) f.owner.pending_.set(id, { async retryCommit() { calls++; } });
    f.owner.setForeground(true); await settle();
    assert.equal(calls, 4); assert.equal([...f.timers.values()][0].delay, 0);
    f.owner.setForeground(false); await f.fire();
    assert.equal(calls, 4); assert.equal(f.owner.pending_.size, 5); assert.equal(f.timers.size, 0);
  } finally { f.close(); }
});

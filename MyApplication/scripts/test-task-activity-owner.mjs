/**
 * 用生产Registry、活动owner、历史store、账本及EvidenceIO验证完整接线；只替换SDK边界和
 * 业务producer，禁止复制attempt分配/终态/重试算法。成功后关闭所有timer和本轮独占夹具。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const turn = () => new Promise(resolve => setImmediate(resolve));

async function fixture() {
  const pref = { value: '', fail: false };
  const storage = new Map();
  const runtime = evidenceRuntime({ appStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) }, imports: {
    './DownloadManager': { formatBytes: String },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      get: async () => pref.value,
      async put(_key, value) { if (pref.fail) throw new Error('history fixture IO'); pref.value = value; },
      async flush() {},
    }) } },
  } });
  const root = runtime.directory.replaceAll('\\', '/');
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  const scope = { beginMode: 'ok', closeFails: false };
  ledger.setLedgerScopeSink({ begin: () => { throw new Error('sync scope must not run'); },
    async beginAsync() { if (scope.beginMode === 'reject') throw new Error('native scope rejected'); return scope.beginMode !== 'false'; },
    end() {}, async endAsync() { if (scope.closeFails) throw new Error('native close fixture IO'); }, endAll() {} });
  ledger.setLedgerProcessRunNonce('task-owner-fixture');
  ledger.configureLedgerMaintenanceOwner(true); ledger.ledgerBeginMaintenanceBatch(root);
  const history = runtime.load('feature_core/src/main/ets/download/DownloadHistory.ets').getDownloadHistoryStore();
  await history.init(runtime.context);
  const owner = runtime.load('feature_core/src/main/ets/download/TaskActivityOwner.ets').getTaskActivityOwner();
  owner.configure(root, root);
  owner.setForeground(true);
  const model = runtime.load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
  const Registry = runtime.load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry;
  const registry = new Registry();
  return { runtime, root, ledger, history, owner, model, registry, pref, scope,
    manifest: id => ledger.ledgerManifest(root, id),
    async close() {
      if (owner.retryTimer_ >= 0) { clearTimeout(owner.retryTimer_); owner.retryTimer_ = -1; }
      await ledger.ledgerEndMaintenanceBatchAsync(root); runtime.close();
    },
    task(id, run = async () => {}) {
      const view = new model.UnifiedTaskView();
      view.id = id; view.title = id; view.category = model.TaskCategory.MOD; view.canCancel = true;
      let attempts = 0;
      const task = { view, async start() { attempts++; await run(view, attempts); view.state = model.UnifiedTaskState.DONE; },
        async retry() { return task.start(); }, async cancel() { view.state = model.UnifiedTaskState.ABORTED; },
        dispose() {}, purgeNativeOwner: () => true,
      };
      return task;
    },
  };
}

test('无页面listener时也在producer前开账，同一ID进入Native输入、历史和固定终态', async () => {
  const f = await fixture();
  try {
    let nativeId = 0;
    const task = f.task('mod-install', async view => {
      nativeId = view.startedAtMs;
      assert.equal(f.manifest(nativeId).state, f.ledger.LedgerState.RUNNING);
    });
    await f.registry.enqueue(task);
    assert.equal(nativeId, task.view.startedAtMs);
    assert.equal(f.manifest(nativeId).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.history.listStored()[0].startedAt, nativeId);
    const receipt = JSON.parse(fs.readFileSync(f.ledger.ledgerDirOf(f.root, nativeId) + '/task-terminal.json'));
    assert.equal(receipt.schema, 2); assert.equal(receipt.producerPid, f.manifest(nativeId).ownerPid);
    assert.equal(receipt.outcome.source, 'task.owner'); assert.equal(receipt.runNonce, 'task-owner-fixture');
    assert.equal(f.owner.attempts_.size, 0); assert.equal(f.owner.pending_.size, 0);
  } finally { await f.close(); }
});

test('通用长业务保留返回值及异常，轻摘要使用真实开始时刻且不创建证据目录', async () => {
  const f = await fixture();
  try {
    const value = await f.owner.run({ category: 'jdk', title: '本地导入' }, async activity => {
      assert.equal(f.manifest(activity.id).state, f.ledger.LedgerState.RUNNING);
      return { ok: false, message: 'invalid archive' };
    }, result => ({ state: result.ok ? f.ledger.LedgerState.SUCCESS : f.ledger.LedgerState.FAILED, summary: result.message }));
    assert.equal(value.ok, false); assert.equal(f.history.listStored()[0].status, 'failed');
    await assert.rejects(f.owner.run({ category: 'diagnostic', title: '诊断' }, async () => { throw new Error('probe IO'); },
      () => ({ state: f.ledger.LedgerState.SUCCESS, summary: 'done' })), /probe IO/);
    assert.equal(f.history.listStored()[0].errorMessage, 'probe IO');
    const startedAt = Date.now() - 1234;
    await f.owner.recordSummary('account', '登录', 'aborted', '用户取消', startedAt);
    const summary = f.history.listStored()[0];
    assert.equal(summary.startedAt, startedAt); assert(summary.durationMs >= 1234);
    assert.equal(fs.existsSync(f.ledger.ledgerDirOf(f.root, startedAt)), false);
  } finally { await f.close(); }
});

test('首次业务终态同时冻结record/outcome统计和同活动导出任务id，历史失败原件仍可恢复', async () => {
  const f = await fixture();
  try {
    const activity = await f.owner.begin({ category: 'game_export', title: '导出统计' });
    const exportId = activity.id + '-fixture-export'; activity.setExportTaskId(exportId);
    assert.throws(() => activity.setExportTaskId('123-other'), /身份/);
    f.pref.fail = true;
    assert.equal(await f.owner.finishSafely(activity, f.ledger.LedgerState.SUCCESS, 'saved', 321, 7), false);
    const receipt = JSON.parse(fs.readFileSync(f.ledger.ledgerDirOf(f.root, activity.id) + '/task-terminal.json'));
    assert.deepEqual(receipt.outcome.taskFacts, { totalBytes: 321, fileCount: 7, exportTaskId: exportId });
    assert.equal(receipt.record.totalBytes, 321); assert.equal(receipt.record.fileCount, 7); assert.equal(receipt.record.exportTaskId, exportId);
    f.pref.fail = false; await f.owner.flushPending(true);
    assert.equal(f.history.listStored()[0].exportTaskId, exportId);
  } finally { await f.close(); }
});

test('scope false或reject均禁止producer，并为已创建的RUNNING基线固定FAILED义务', async () => {
  for (const mode of ['false', 'reject']) {
    const f = await fixture();
    try {
      f.scope.beginMode = mode;
      let invoked = false;
      const task = f.task('scope-' + mode, async () => { invoked = true; });
      await assert.rejects(f.registry.enqueue(task), /账本|scope rejected/);
      assert.equal(invoked, false); assert.equal(task.view.state, f.model.UnifiedTaskState.ERROR);
      assert.equal(f.manifest(task.view.startedAtMs).state, f.ledger.LedgerState.FAILED);
      assert.equal(f.history.listStored()[0].status, 'failed');
      assert.equal(f.owner.pending_.size, 0);
    } finally { await f.close(); }
  }
});

test('历史已提交而canonical关闭失败时只补关闭，不重复追加LRU或改结束时刻', async () => {
  const f = await fixture();
  try {
    f.scope.closeFails = true;
    const task = f.task('close-retry'); await f.registry.enqueue(task);
    assert.equal(f.history.listStored().length, 1); assert.equal(f.owner.pending_.size, 1);
    const endedAt = f.history.listStored()[0].endedAt;
    f.scope.closeFails = false; await f.owner.flushPending();
    assert.equal(f.history.listStored().length, 1); assert.equal(f.owner.pending_.size, 0);
    assert.equal(f.manifest(task.view.startedAtMs).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.manifest(task.view.startedAtMs).endedAt, endedAt);
  } finally { await f.close(); }
});

test('卡片重试独立分配attempt并关联失败前次，普通资源和更新入口无需页面记历史', async () => {
  const f = await fixture();
  try {
    const task = f.task('resource-update', async (view, attempt) => {
      if (attempt === 1) { view.state = f.model.UnifiedTaskState.ERROR; view.canRetry = true; throw new Error('business failed'); }
    });
    task.view.activityCategory = 'resource_manage'; task.view.activityMcDir = '/fixed-instance';
    await assert.rejects(f.registry.enqueue(task), /business failed/);
    const first = task.view.startedAtMs;
    await f.registry.retry(task.view.id);
    const second = task.view.startedAtMs;
    assert(second > first); assert.equal(f.manifest(first).state, f.ledger.LedgerState.FAILED);
    assert.equal(f.manifest(second).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.manifest(second).parentActivityId, first); assert.equal(f.manifest(second).relation, 'retry');
    assert.equal(f.manifest(second).mcDir, '/fixed-instance');
    assert.equal(f.history.listStored().length, 2);
  } finally { await f.close(); }
});

test('排队取消建立ABORTED账本但不调用producer，清理后再提交终态', async () => {
  const f = await fixture();
  const gate = deferred();
  try {
    f.registry.maxConcurrent = 1;
    const blocker = f.task('blocker', async () => gate.promise);
    const running = f.registry.enqueue(blocker);
    let invoked = false;
    const queued = f.task('queued-jdk', async () => { invoked = true; }); queued.view.category = f.model.TaskCategory.JDK;
    const queuedResult = f.registry.enqueue(queued).catch(error => error);
    await f.registry.cancel(queued.view.id);
    assert.match((await queuedResult).message, /已取消/);
    assert.equal(invoked, false); assert(queued.view.startedAtMs > 0);
    assert.equal(f.manifest(queued.view.startedAtMs).state, f.ledger.LedgerState.ABORTED);
    assert.equal(f.history.listStored()[0].status, 'aborted');
    gate.resolve(); await running;
  } finally { gate.resolve(); await f.close(); }
});

test('失败任务的重试在队列中取消也分配新身份，不覆写原FAILED或丢retry关系', async () => {
  const f = await fixture(); const gate = deferred(); let running;
  try {
    const task = f.task('retry-cancel', async view => { view.state = f.model.UnifiedTaskState.ERROR; view.canRetry = true; throw new Error('first failure'); });
    await assert.rejects(f.registry.enqueue(task), /first failure/); const original = task.view.startedAtMs;
    f.registry.maxConcurrent = 1; running = f.registry.enqueue(f.task('blocker', async () => gate.promise));
    const retry = f.registry.retry(task.view.id);
    await f.registry.cancel(task.view.id); await retry;
    const cancelled = task.view.startedAtMs;
    assert(cancelled > original); assert.equal(f.manifest(original).state, f.ledger.LedgerState.FAILED);
    assert.equal(f.manifest(cancelled).state, f.ledger.LedgerState.ABORTED);
    assert.equal(f.manifest(cancelled).parentActivityId, original); assert.equal(f.manifest(cancelled).relation, 'retry');
    gate.resolve(); await running;
  } finally { gate.resolve(); if (running) await running; await f.close(); }
});

test('开账期间取消不会被适配器start复位；耐久历史故障只补IO，不改业务SUCCESS', async () => {
  const f = await fixture();
  try {
    const opening = deferred(), began = deferred();
    const realBegin = f.owner.beginTask.bind(f.owner);
    f.owner.beginTask = async view => { await realBegin(view); began.resolve(); await opening.promise; };
    let invoked = false;
    const cancelled = f.task('opening-cancel', async () => { invoked = true; });
    const result = f.registry.enqueue(cancelled).catch(error => error);
    await began.promise; await f.registry.cancel(cancelled.view.id); opening.resolve();
    assert.match((await result).message, /已取消/); assert.equal(invoked, false);
    assert.equal(f.manifest(cancelled.view.startedAtMs).state, f.ledger.LedgerState.ABORTED);
    f.owner.beginTask = realBegin;
    f.pref.fail = true;
    const success = f.task('fixed-success'); await f.registry.enqueue(success);
    assert.equal(success.view.state, f.model.UnifiedTaskState.DONE); assert.equal(f.owner.pending_.size, 1);
    const receiptPath = f.ledger.ledgerDirOf(f.root, success.view.startedAtMs) + '/task-terminal.json';
    const before = JSON.parse(fs.readFileSync(receiptPath));
    assert.equal(before.outcome.state, f.ledger.LedgerState.SUCCESS);
    f.pref.fail = false; await f.owner.flushPending();
    assert.equal(f.owner.pending_.size, 0); assert.equal(f.manifest(success.view.startedAtMs).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.manifest(success.view.startedAtMs).endedAt, before.outcome.endedAt);
    assert.equal(f.history.listStored().find(row => row.startedAt === success.view.startedAtMs).status, 'success');
    await turn();
  } finally { await f.close(); }
});

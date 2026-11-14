/**
 * 执行生产账本的进程轮次、最终删除与真实异步开账契约。
 * SDK 文件接口由既有宿主适配提供；故障注入只改变边界输入，不复制恢复/删除算法。
 * 每个用例持独立维护批次，finally 等待收尾后仅回收本例夹具，不操作共享父目录。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 创建独立生产模块与磁盘，当前轮身份固定，旧轮活动由调用方显式传入 nonce。 */
function fixture() {
  const runtime = evidenceRuntime();
  const root = runtime.directory.replaceAll('\\', '/');
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  ledger.configureLedgerMaintenanceOwner(true, () => true);
  ledger.setLedgerProcessRunNonce('owner-protection-current');
  ledger.ledgerBeginMaintenanceBatch(root);
  return { runtime, root, ledger,
    async close() { ledger.setLedgerScopeSink(null); await ledger.ledgerEndMaintenanceBatchAsync(root); runtime.close(); },
  };
}

test('延后恢复只收尾旧nonce，当前活动原件保持不变且不关闭其scope', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerBegin(f.root, 100, { category: 'download', title: 'old', runNonce: 'owner-protection-old' });
    f.ledger.ledgerBegin(f.root, 200, { category: 'download', title: 'current' });
    const current = f.ledger.ledgerDirOf(f.root, 200) + '/manifest.json';
    const bytes = fs.readFileSync(current); const closed = [];
    f.ledger.setLedgerScopeSink({ begin: () => true, end() {}, endAll() {}, async endAsync(id) { closed.push(id); } });
    assert.equal(await f.ledger.ledgerResolveStaleAsync(f.root), 1);
    assert.equal(f.ledger.ledgerManifest(f.root, 100).state, f.ledger.LedgerState.INTERRUPTED);
    assert.deepEqual(fs.readFileSync(current), bytes); assert.deepEqual(closed, [100]);
  } finally { await f.close(); }
});

test('最终删除在Native等待期间清单损坏必须保留原件，claim阻止新reader', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerBegin(f.root, 100, { category: 'diagnostic', title: 'original' });
    await f.ledger.ledgerEndAsync(f.root, 100, { state: f.ledger.LedgerState.SUCCESS, source: 'test', summary: 'done' });
    const directory = f.ledger.ledgerDirOf(f.root, 100);
    const original = f.runtime.write('logs/ledger/100/unique.log', 'must survive');
    assert.equal(await f.ledger.ledgerRemovalBlockReasonAsync(f.root, 100), '');
    f.ledger.setLedgerScopeSink({ begin: () => true, end() {}, endAll() {}, async endAsync() {
      assert.throws(() => f.runtime.load('commons/src/main/ets/utils/EvidenceIo.ets').acquireEvidenceLease(f.root, 100), /正在删除/);
      fs.writeFileSync(directory + '/manifest.json', '{broken');
    } });
    await assert.rejects(f.ledger.ledgerRemoveAsync(f.root, 100), /清单无法读取/);
    assert.equal(fs.readFileSync(original, 'utf8'), 'must survive');
    assert.match(f.ledger.ledgerRemovalBlockReason(f.root, 100), /清单无法读取/);
    assert.equal(f.runtime.load('commons/src/main/ets/utils/EvidenceIo.ets').isEvidenceDeleting(f.root, 100), false);
  } finally { await f.close(); }
});

test('v2任务终态匹配nonce/PID/category/source才恢复，取消保留真实时间且不接管游戏', async () => {
  const f = fixture();
  try {
    for (const [id, category] of [[100, 'jdk'], [200, 'repair'], [300, 'launch'], [400, 'game_export']]) {
      f.ledger.ledgerBegin(f.root, id, { category, title: category, runNonce: 'task-prior' });
      const manifest = f.ledger.ledgerManifest(f.root, id);
      f.runtime.write('logs/ledger/' + id + '/task-terminal.json', JSON.stringify({ schema: 2,
        activityId: id, category, runNonce: 'task-prior', producerPid: manifest.ownerPid + (id === 200 ? 1 : 0),
        record: { startedAt: id, endedAt: id + 5, category, status: 'aborted', totalBytes: 12345, fileCount: 7,
          exportTaskId: 'export-' + id + '-test' },
        outcome: { state: f.ledger.LedgerState.ABORTED, source: 'task.owner', summary: 'cancelled', endedAt: id + 5 } }));
    }
    assert.equal(await f.ledger.ledgerResolveStaleAsync(f.root), 4);
    const valid = f.ledger.ledgerManifest(f.root, 100);
    assert.equal(valid.state, f.ledger.LedgerState.ABORTED); assert.equal(valid.endedAt, 105);
    assert.equal(valid.outcomeSource, 'task.owner');
    assert.deepEqual(valid.taskFacts, { totalBytes: 12345, fileCount: 7 });
    assert.deepEqual(f.ledger.ledgerManifest(f.root, 400).taskFacts,
      { totalBytes: 12345, fileCount: 7, exportTaskId: 'export-400-test' });
    for (const id of [200, 300]) assert.equal(f.ledger.ledgerManifest(f.root, id).state, f.ledger.LedgerState.INTERRUPTED);
  } finally { await f.close(); }
});

test('清空发现前拒绝尚未建出目录的在途开账，不删除原件也不打断原事务', async () => {
  const f = fixture(); let release; let opening;
  try {
    await f.ledger.ledgerBeginAsync(f.root, 100, { category: 'diagnostic', title: 'old' });
    await f.ledger.ledgerEndAsync(f.root, 100, { state: f.ledger.LedgerState.SUCCESS, source: 'test', summary: 'done' });
    let entered; const reached = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; }); const mkdir = f.runtime.kitFs.mkdir;
    f.runtime.kitFs.mkdir = async (path, recursive) => {
      if (path === f.ledger.ledgerDirOf(f.root, 200)) { entered(); await gate; }
      return mkdir(path, recursive);
    };
    opening = f.ledger.ledgerBeginAsync(f.root, 200, { category: 'download', title: 'admitted before discovery' });
    await reached; assert.equal(fs.existsSync(f.ledger.ledgerDirOf(f.root, 200)), false);
    await assert.rejects(f.ledger.ledgerClearAsync(f.root), /活动清单正在提交/);
    assert.equal(fs.existsSync(f.ledger.ledgerDirOf(f.root, 100)), true);
    release(); assert.equal(await opening, true);
    assert.equal(f.ledger.ledgerManifest(f.root, 200).state, f.ledger.LedgerState.RUNNING);
  } finally { release?.(); await opening?.catch(() => {}); await f.close(); }
});

test('异步开账等待真实Native端口，不调用同步begin；打开失败不得放行producer', async () => {
  const f = fixture();
  try {
    let release; const gate = new Promise(resolve => { release = resolve; });
    let entered; const enteredPromise = new Promise(resolve => { entered = resolve; });
    let settled = false; let syncCalls = 0;
    f.ledger.setLedgerScopeSink({ begin() { syncCalls++; throw new Error('sync forbidden'); }, end() {}, endAll() {},
      async beginAsync() { entered(); await gate; return false; } });
    const opening = f.ledger.ledgerBeginAsync(f.root, 100, { category: 'download', title: 'not admitted' });
    opening.then(() => { settled = true; });
    await enteredPromise; assert.equal(settled, false); assert.equal(syncCalls, 0);
    release(); assert.equal(await opening, false); assert.equal(syncCalls, 0);
    assert.equal(f.ledger.ledgerManifest(f.root, 100).state, f.ledger.LedgerState.RUNNING);
  } finally { await f.close(); }
});

test('独立游戏复用父进程基线只发metadata且真正等待scope，不覆写canonical或pin', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerBegin(f.root, 100, { category: 'launch', title: 'parent', runNonce: 'shared-game-run' });
    f.ledger.ledgerSetPinned(f.root, 100, true);
    const path = f.ledger.ledgerDirOf(f.root, 100) + '/manifest.json';
    const original = fs.readFileSync(path);
    f.ledger.configureLedgerMaintenanceOwner(false);
    let release; const gate = new Promise(resolve => { release = resolve; });
    let entered; const nativeEntered = new Promise(resolve => { entered = resolve; });
    let settled = false;
    f.ledger.setLedgerScopeSink({ begin() { assert.fail('游戏异步路径不能调用同步开账'); }, end() {}, endAll() {},
      async beginAsync(id, directory) {
        assert.equal(id, 100); assert.equal(directory, f.ledger.ledgerDirOf(f.root, 100));
        entered(); await gate; return true;
      } });
    const opening = f.ledger.ledgerBeginAsync(f.root, 100, { category: 'launch', title: 'child metadata' });
    opening.then(() => { settled = true; });
    await nativeEntered; assert.equal(settled, false);
    assert.deepEqual(fs.readFileSync(path), original);
    const patch = JSON.parse(fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/game-metadata.json', 'utf8'));
    assert.equal(patch.runNonce, 'shared-game-run'); assert.equal(patch.meta.title, 'child metadata');
    release(); assert.equal(await opening, true); assert.deepEqual(fs.readFileSync(path), original);
  } finally { await f.close(); }
});

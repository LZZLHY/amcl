/** 执行实际占用读取/实际账本，拒绝同步IO并核验计量复用、unknown和读取租约。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/**
 * 无参数构造独立外置目录和模块缓存，加载生产ActivityLedger/EvidenceIo/ActivityStorage。
 * SDK文件接口由evidenceRuntime映射到真实宿主文件；native writer仍是替身，不证明设备线程行为。
 * 建立launch/download两类已结束活动并等待真实异步索引，返回运行时、生产导出与目录root。
 * owner guard刻意禁止自动保留删除，避免读取用例夹具被维护任务淘汰；它不替代受测的占用/租约算法。
 * 成功返回后调用方在finally执行runtime.close，仅删除经过路径核验的本夹具目录；故障注入只改此模块实例。
 */
async function fixture() {
  const runtime = evidenceRuntime();
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  const io = runtime.load('commons/src/main/ets/utils/EvidenceIo.ets');
  const storage = runtime.load('commons/src/main/ets/utils/ActivityStorage.ets');
  ledger.configureLedgerMaintenanceOwner(true, () => false);
  for (const id of [1, 2]) {
    ledger.ledgerBegin(runtime.directory, id, { category: id === 1 ? 'launch' : 'download', title: 'fixture-' + id,
      gameVersionId: id === 1 ? '26.3' : '', mcDir: id === 1 ? '/fixture-game' : '' });
    ledger.ledgerEnd(runtime.directory, id, { state: ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'done' });
  }
  await ledger.ledgerListAsync(runtime.directory);
  return { runtime, ledger, io, storage, root: runtime.directory };
}

test('可信索引复用只读小清单，不同步重建且不再次递归每局目录，分组字节保持实际值', async () => {
  const f = await fixture();
  try {
    const expected = await f.ledger.ledgerListAsync(f.root); let recursiveLists = 0;
    const list = f.runtime.kitFs.listFile;
    f.runtime.kitFs.listFile = async p => { if (p.startsWith(f.root + '/logs/ledger/')) recursiveLists++; return list(p); };
    for (const name of ['statSync', 'listFileSync', 'readTextSync', 'openSync', 'readSync']) {
      f.runtime.kitFs[name] = () => assert.fail('占用读取不得调用 ' + name);
    }
    const result = await f.storage.readActivityStorage(f.root, () => false);
    assert.equal(recursiveLists, 0); assert.equal(result.bytes, expected.reduce((sum, entry) => sum + entry.bytes, 0));
    assert.equal(result.groups.length, 2); assert.deepEqual(result.issues, []);
    assert.equal(result.groups.flatMap(group => group.items).length, 2);
    assert.equal(f.io.hasEvidenceLease(f.root, 1), false);
  } finally { f.runtime.close(); }
});

test('stat失败保持原件/可用活动且总占用未知，写入中条目不复用旧缓存作为稳定总量', async () => {
  const f = await fixture();
  try {
    const before = fs.readFileSync(f.root + '/logs/ledger/1/manifest.json');
    const stat = f.runtime.kitFs.lstat;
    f.runtime.kitFs.lstat = async p => { if (p.endsWith('/logs/ledger/1/manifest.json')) throw new Error('stat EIO'); return stat(p); };
    f.ledger.ledgerMarkDirty(f.root, 1);
    const result = await f.storage.readActivityStorage(f.root, () => false);
    assert.equal(result.bytes, -1); assert.ok(result.issues.length > 0);
    assert.equal(result.groups.flatMap(group => group.items).find(item => item.activityId === 1).bytes, -1);
    assert.deepEqual(fs.readFileSync(f.root + '/logs/ledger/1/manifest.json'), before);
    f.runtime.kitFs.lstat = stat;
    f.ledger.ledgerBegin(f.root, 3, { category: 'download', title: 'running' });
    const writing = await f.storage.readActivityStorage(f.root, () => false);
    assert.equal(writing.bytes, -1); assert.ok(writing.issues.some(issue => issue.includes('仍在写入')));
  } finally { f.runtime.close(); }
});

test('真实清单读取期间持租约，自动/手动删除不能越过，离页取消释放全部租约', async () => {
  const f = await fixture();
  try {
    let reads = 0, enteredResolve, release, cancelled = false;
    const entered = new Promise(resolve => { enteredResolve = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    const read = f.runtime.kitFs.readText;
    f.runtime.kitFs.readText = async p => {
      if (p.endsWith('/logs/ledger/1/manifest.json') && ++reads === 2) { enteredResolve(); await gate; }
      return read(p);
    };
    const pending = f.storage.readActivityStorage(f.root, () => cancelled); await entered;
    assert.equal(f.io.hasEvidenceLease(f.root, 1), true);
    f.ledger.configureLedgerMaintenanceOwner(true, () => true);
    await assert.rejects(f.ledger.ledgerRemoveAsync(f.root, 1), /读取|导出/);
    cancelled = true; release(); await assert.rejects(pending, /取消/);
    assert.equal(f.io.hasEvidenceLease(f.root, 1), false); assert.ok(fs.existsSync(f.root + '/logs/ledger/1/manifest.json'));
    f.ledger.configureLedgerMaintenanceOwner(true, () => false);
  } finally { f.runtime.close(); }
});

test('真实异步clear按批末维护一次，受保护活动使整批零删除', async () => {
  const f = await fixture();
  try {
    f.ledger.configureLedgerMaintenanceOwner(true, () => true);
    await f.ledger.ledgerFlushMaintenanceAsync(f.root);
    f.io.acquireEvidenceLease(f.root, 1);
    await assert.rejects(f.ledger.ledgerClearAsync(f.root), /读取|导出/);
    assert.ok(fs.existsSync(f.root + '/logs/ledger/1')); assert.ok(fs.existsSync(f.root + '/logs/ledger/2'));
    f.io.releaseEvidenceLease(f.root, 1);
    const before = f.ledger.ledgerMaintenanceCounters();
    await f.ledger.ledgerClearAsync(f.root);
    const after = f.ledger.ledgerMaintenanceCounters();
    assert.equal(fs.existsSync(f.root + '/logs/ledger/1'), false); assert.equal(fs.existsSync(f.root + '/logs/ledger/2'), false);
    assert.equal(after.indexWrites - before.indexWrites, 1, 'clear只在整批末发布一次派生索引');
    f.ledger.configureLedgerMaintenanceOwner(true, () => false);
  } finally { f.runtime.close(); }
});

/** 执行真实生产账本/EvidenceIO，验证幂等、增量维护、故障恢复与owner保护，不复制业务算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/**
 * 无参数创建独立外置磁盘与SDK适配，执行生产账本、原子证据IO和维护owner，不复制提交/淘汰算法。
 * owner表示空闲，真实maintenance batch负责暂停自动维护；不能借未知锁或false掩盖保留工作量。
 * 返回begin/end/manifest/flush便捷端口，其内容仍委托生产函数或读取真实文件，便于对照单调计数与字节。
 * 用例须等已派发事务收尾，并在finally关闭runtime；清理只针对本夹具经验证的目录，不涉及工程原件。
 */
function fixture() {
  const runtime = evidenceRuntime();
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  const io = runtime.load('commons/src/main/ets/utils/EvidenceIo.ets');
  // 夹具通过真实批次hold控制批尾；游戏锁guard仍表示真实空闲，不借false伪装暂停维护。
  ledger.configureLedgerMaintenanceOwner(true);
  const root = runtime.directory.replaceAll('\\', '/');
  ledger.ledgerBeginMaintenanceBatch(root);
  /** 按指定主键/类别建立真实活动；默认诊断类和同版本用于稳定保留分组，本端口不伪造manifest。 */
  const begin = (id, category = 'diagnostic') => ledger.ledgerBegin(root, id, { category, title: 'activity-' + id, gameVersionId: 'same-version' });
  /** 通过生产同步兼容入口提交固定成功结局，异步索引/保留仍在真正的批尾完成。 */
  const end = id => ledger.ledgerEnd(root, id, { state: ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'completed' });
  /** 读取指定主键真实清单字节，避免用夹具内存投影替代已提交产物。 */
  const manifest = id => JSON.parse(fs.readFileSync(ledger.ledgerDirOf(root, id) + '/manifest.json', 'utf8'));
  /** 结束并等待当前真实批次后重新持批；每次返回都可测量完整维护，后续dirty不自行多跑一轮。 */
  const flush = async () => { ledger.configureLedgerMaintenanceOwner(true); await ledger.ledgerEndMaintenanceBatchAsync(root); ledger.ledgerBeginMaintenanceBatch(root); };
  return { runtime, ledger, io, root, begin, end, manifest, flush };
}

test('重复封账不写检查时间/清单/Evidence；同结局新输入仅推进消费身份', async () => {
  const f = fixture();
  try {
    f.begin(100); f.end(100);
    const outcome = { state: f.ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'completed', recoveredAt: 999999 };
    const first = await f.ledger.ledgerEndAsync(f.root, 100, outcome, { inputKey: 'producer-a' });
    assert.equal(first.changed, true);
    const before = fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/manifest.json', 'utf8');
    const evidenceBefore = fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/evidence-manifest.json', 'utf8');
    f.ledger.ledgerEnd(f.root, 100, outcome);
    const result = await f.ledger.ledgerEndAsync(f.root, 100, { ...outcome, recoveredAt: 888888 }, { inputKey: 'producer-a' });
    assert.equal(result.changed, false);
    assert.equal(fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/manifest.json', 'utf8'), before);
    assert.equal(fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/evidence-manifest.json', 'utf8'), evidenceBefore);
    const previousRecovered = f.manifest(100).recoveredAt;
    await f.ledger.ledgerEndAsync(f.root, 100, outcome, { inputKey: 'producer-b' });
    assert.equal(f.manifest(100).recoveryInputKey, 'producer-b');
    assert.equal(f.manifest(100).recoveredAt, previousRecovered);
    await f.flush();
  } finally { f.runtime.close(); }
});

test('批尾只发布一次索引，零dirty不维护；metadata变化仅统计受影响活动', async () => {
  const f = fixture();
  try {
    for (let id = 1; id <= 20; id++) { f.begin(id); f.end(id); }
    const before = f.ledger.ledgerMaintenanceCounters(); await f.flush();
    const initial = f.ledger.ledgerMaintenanceCounters();
    assert.equal(initial.activityScans - before.activityScans, 20);
    assert.equal(initial.fullRebuilds - before.fullRebuilds, 1);
    assert.equal(initial.indexWrites - before.indexWrites, 1);
    assert.equal(initial.retentionBatches - before.retentionBatches, 1);
    await f.flush(); assert.deepEqual(f.ledger.ledgerMaintenanceCounters(), initial);
    await f.ledger.ledgerSetPinnedAsync(f.root, 3, true);
    await f.io.writeEvidenceTextAtomicAsync(f.ledger.ledgerDirOf(f.root, 7) + '/evidence-selection.json', '{"selection":"changed"}');
    await f.flush(); const after = f.ledger.ledgerMaintenanceCounters();
    assert.equal(after.activityScans - initial.activityScans, 2);
    assert.equal(after.fullRebuilds, initial.fullRebuilds);
    assert.equal(after.indexWrites - initial.indexWrites, 1);
    const index = JSON.parse(fs.readFileSync(f.root + '/logs/ledger/index.json', 'utf8'));
    assert.equal(index.schema, 2); assert.equal(index.entries.find(e => e.activityId === 3).pinned, true);
    assert.ok(index.entries.every(e => e.bytesState === 'current'));
  } finally { f.runtime.close(); }
});

test('stat故障保留unknown且不淘汰，正常恢复重新统计不会使用零字节成功缓存', async () => {
  const f = fixture();
  try {
    f.begin(1); f.runtime.write('logs/ledger/1/large.log', 'evidence'); f.end(1);
    const lstat = f.runtime.kitFs.lstat;
    f.runtime.kitFs.lstat = async p => { if (p.endsWith('/large.log')) throw new Error('EIO'); return lstat(p); };
    await f.flush(); const entry = (await f.ledger.ledgerListAsync(f.root))[0];
    assert.equal(entry.bytesState, 'unknown'); assert.ok(fs.existsSync(f.ledger.ledgerDirOf(f.root, 1)));
    f.runtime.kitFs.lstat = lstat; f.ledger.ledgerMarkDirty(f.root, 1); await f.flush();
    assert.equal((await f.ledger.ledgerListAsync(f.root))[0].bytesState, 'current');
  } finally { f.runtime.close(); }
});

test('恢复与pin使用同活动串行写门，异步期间同步旧清单写不能覆盖新状态', async () => {
  const f = fixture();
  try {
    f.begin(100); f.end(100);
    const lstat = f.runtime.kitFs.lstat;
    let release, enteredResolve;
    const entered = new Promise(resolve => { enteredResolve = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    let intercepted = false;
    // 在真实正文的属性IO期间注入用户pin，验证事务不是仅靠进程单例避免交错。
    f.runtime.write('logs/ledger/100/record.log', 'body');
    f.runtime.kitFs.lstat = async p => {
      if (!intercepted && p.endsWith('/record.log')) { intercepted = true; enteredResolve(); await gate; }
      return lstat(p);
    };
    const commit = f.ledger.ledgerEndAsync(f.root, 100, { state: f.ledger.LedgerState.FAILED, source: 'new-input', summary: 'actual failure' }, { inputKey: 'revision-2' });
    await entered;
    assert.throws(() => f.ledger.ledgerSetPinned(f.root, 100, true), /正在提交/);
    const pin = f.ledger.ledgerSetPinnedAsync(f.root, 100, true);
    release(); await commit; await pin;
    assert.equal(f.manifest(100).pinned, true); assert.equal(f.manifest(100).state, f.ledger.LedgerState.FAILED);
    assert.equal(f.manifest(100).recoveryInputKey, 'revision-2'); await f.flush();
  } finally { f.runtime.close(); }
});

test('delete先claim再await，claim期间新reader/直接写入/pin不能进入，原始租约挡删除', async () => {
  const f = fixture();
  try {
    f.begin(1); f.end(1); await f.flush();
    f.io.acquireEvidenceLease(f.root, 1); f.ledger.configureLedgerMaintenanceOwner(true);
    await assert.rejects(f.ledger.ledgerRemoveAsync(f.root, 1), /读取或导出/);
    f.io.releaseEvidenceLease(f.root, 1);
    const listFile = f.runtime.kitFs.listFile;
    let release, enteredResolve;
    const entered = new Promise(resolve => { enteredResolve = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    f.runtime.kitFs.listFile = async p => { if (p.endsWith('/ledger/1')) { enteredResolve(); await gate; } return listFile(p); };
    const removing = f.ledger.ledgerRemoveAsync(f.root, 1); await entered;
    assert.throws(() => f.io.acquireEvidenceLease(f.root, 1), /正在删除/);
    await assert.rejects(f.io.writeEvidenceTextAtomicAsync(f.ledger.ledgerDirOf(f.root, 1) + '/evidence-selection.json', '{}'), /正在删除/);
    assert.throws(() => f.ledger.ledgerSetPinned(f.root, 1, true), /正在删除/);
    release(); await removing; f.ledger.configureLedgerMaintenanceOwner(true, () => false);
    await f.flush(); assert.equal(fs.existsSync(f.ledger.ledgerDirOf(f.root, 1)), false);
  } finally { f.runtime.close(); }
});

test('最终消费key rename后目录同步失败，重试必须真实fsync才可走unchanged成功', async () => {
  const f = fixture();
  try {
    f.begin(100); f.end(100);
    const fsync = f.runtime.kitFs.fsync;
    let armed = true, directorySyncs = 0;
    f.runtime.kitFs.fsync = async fd => {
      if (fd < 0) {
        directorySyncs++;
        // 第一次asyncEnd先刷新Evidence，再保存最终key；按实际manifest内容识别提交边界。
        if (armed && f.manifest(100).recoveryInputKey === 'durability-check') { armed = false; throw new Error('directory fsync EIO'); }
      }
      return fsync(fd);
    };
    const outcome = { state: f.ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'completed' };
    await assert.rejects(f.ledger.ledgerEndAsync(f.root, 100, outcome, { inputKey: 'durability-check' }), error => error.kind === 'durability-unknown');
    assert.equal(f.manifest(100).recoveryInputKey, 'durability-check');
    const before = directorySyncs;
    await f.ledger.ledgerEndAsync(f.root, 100, outcome, { inputKey: 'durability-check' });
    assert.ok(directorySyncs > before, '已发布但未耐久路径必须重新目录同步'); await f.flush();
  } finally { f.runtime.close(); }
});

test('pin发布后耐久未知的相同目标重试必须重同步，不能凭已可见pinned宣告保存成功', async () => {
  const f = fixture();
  try {
    f.begin(1); f.end(1);
    const fsync = f.runtime.kitFs.fsync; let armed = true, syncs = 0;
    f.runtime.kitFs.fsync = async fd => {
      if (fd < 0) { syncs++; if (armed && f.manifest(1).pinned === true) { armed = false; throw new Error('directory EIO'); } }
      return fsync(fd);
    };
    await assert.rejects(f.ledger.ledgerSetPinnedAsync(f.root, 1, true), error => error.kind === 'durability-unknown');
    const before = syncs; await f.ledger.ledgerSetPinnedAsync(f.root, 1, true);
    assert.ok(syncs > before); assert.equal(f.manifest(1).pinned, true); await f.flush();
  } finally { f.runtime.close(); }
});

test('跨进程重建缓存识别selection写后未发布索引，不信旧bytes；批次hold合并所有异步写', async () => {
  const f = fixture();
  let other;
  try {
    for (const id of [1, 2, 3]) { f.begin(id); f.end(id); } await f.flush();
    await f.io.writeEvidenceTextAtomicAsync(f.ledger.ledgerDirOf(f.root, 2) + '/evidence-selection.json', '{"expanded":"metadata write before process exit"}');
    // 新模块实例没有旧进程dirty Set，必须凭持久元数据身份拒绝陈旧索引bytes。
    other = evidenceRuntime(); const otherLedger = other.load('commons/src/main/ets/utils/ActivityLedger.ets');
    otherLedger.configureLedgerMaintenanceOwner(true, () => false);
    const before = otherLedger.ledgerMaintenanceCounters(); const rows = await otherLedger.ledgerListAsync(f.root);
    assert.equal(otherLedger.ledgerMaintenanceCounters().activityScans - before.activityScans, 1);
    assert.equal(rows.find(e => e.activityId === 2).bytesState, 'current');
    await f.flush(); await f.ledger.ledgerEndMaintenanceBatchAsync(f.root);
    const counters = f.ledger.ledgerMaintenanceCounters(); f.ledger.configureLedgerMaintenanceOwner(true);
    f.ledger.ledgerBeginMaintenanceBatch(f.root);
    await f.ledger.ledgerSetPinnedAsync(f.root, 1, true); await f.ledger.ledgerSetPinnedAsync(f.root, 3, true);
    await f.ledger.ledgerFlushMaintenanceAsync(f.root);
    assert.equal(f.ledger.ledgerMaintenanceCounters().indexWrites, counters.indexWrites);
    await f.ledger.ledgerEndMaintenanceBatchAsync(f.root); f.ledger.ledgerBeginMaintenanceBatch(f.root);
    assert.equal(f.ledger.ledgerMaintenanceCounters().indexWrites - counters.indexWrites, 1);
    await f.flush();
  } finally { other?.close(); f.runtime.close(); }
});

test('游戏进程只发布本局结果/元数据，不覆写pin、不执行索引或淘汰', async () => {
  const f = fixture();
  try {
    f.begin(100, 'launch'); await f.ledger.ledgerSetPinnedAsync(f.root, 100, true);
    const before = fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/manifest.json', 'utf8');
    const counters = f.ledger.ledgerMaintenanceCounters(); f.ledger.configureLedgerMaintenanceOwner(false);
    f.ledger.ledgerBegin(f.root, 100, { category: 'launch', title: 'new-profile', gameVersionId: 'same-version' });
    f.ledger.ledgerEnd(f.root, 100, { state: f.ledger.LedgerState.FAILED, source: 'launch-preparation', summary: 'early failure' });
    assert.equal(fs.readFileSync(f.ledger.ledgerDirOf(f.root, 100) + '/manifest.json', 'utf8'), before);
    assert.deepEqual(f.ledger.ledgerMaintenanceCounters(), counters);
    const terminal = await f.ledger.readLedgerGameTerminalAsync(f.root, 100); assert.equal(terminal.outcome.summary, 'early failure');
    f.ledger.configureLedgerMaintenanceOwner(true, () => false); await f.ledger.ledgerMergeGameMetadataAsync(f.root, 100);
    assert.equal(f.manifest(100).pinned, true); assert.equal(f.manifest(100).title, 'new-profile'); await f.flush();
  } finally { f.runtime.close(); }
});

test('async开账与终态队列顺序保持，native关闭真正await，实时任务不误标估算结束时间', async () => {
  const f = fixture();
  try {
    let release, enteredResolve, closed = false;
    const entered = new Promise(resolve => { enteredResolve = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    f.ledger.setLedgerScopeSink({ begin: () => true, end: () => assert.fail('异步封账不能调用同步native wait'), endAll() {},
      async endAsync() { enteredResolve(); await gate; closed = true; } });
    const beginning = f.ledger.ledgerBeginAsync(f.root, 100, { category: 'download', title: 'async task' });
    const ending = f.ledger.ledgerEndAsync(f.root, 100, { state: f.ledger.LedgerState.SUCCESS, source: 'task.completed', summary: 'done' });
    assert.equal(await beginning, true); await entered;
    assert.equal(f.manifest(100).state, f.ledger.LedgerState.RUNNING); assert.equal(closed, false);
    release(); await ending;
    assert.equal(closed, true); assert.equal(f.manifest(100).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.manifest(100).endTimeEstimated, false); assert.ok(f.manifest(100).endedAt >= 100);
    await f.flush();
  } finally { f.runtime.close(); }
});

test('clear全集预检与claim失败零删除；成功整批仅一份索引，无逐条同步目录清理', async () => {
  const f = fixture();
  try {
    for (const id of [1, 2, 3]) { f.begin(id); f.end(id); } await f.flush();
    await f.ledger.ledgerSetPinnedAsync(f.root, 2, true);
    await assert.rejects(f.ledger.ledgerClearAsync(f.root), /设为保留/);
    for (const id of [1, 2, 3]) assert.ok(fs.existsSync(f.ledger.ledgerDirOf(f.root, id)));
    await f.ledger.ledgerSetPinnedAsync(f.root, 2, false);
    const readText = f.runtime.kitFs.readText; let release, enteredResolve, intercepted = false;
    const entered = new Promise(resolve => { enteredResolve = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    f.runtime.kitFs.readText = async p => {
      if (!intercepted && p.endsWith('/ledger/2/manifest.json')) { intercepted = true; enteredResolve(); await gate; }
      return readText(p);
    };
    const pending = f.ledger.ledgerClearAsync(f.root); await entered;
    // ID3已完成预检；随后新租约在整批claim阶段再次阻止清理，证明没有TOCTOU遗漏。
    f.io.acquireEvidenceLease(f.root, 3); release(); await assert.rejects(pending, /读取或删除/);
    for (const id of [1, 2, 3]) assert.ok(fs.existsSync(f.ledger.ledgerDirOf(f.root, id)));
    f.io.releaseEvidenceLease(f.root, 3); f.runtime.kitFs.readText = readText; await f.flush();
    const counters = f.ledger.ledgerMaintenanceCounters();
    await f.ledger.ledgerClearAsync(f.root); await f.flush();
    assert.deepEqual(await f.ledger.ledgerListAsync(f.root), []);
    assert.equal(f.ledger.ledgerMaintenanceCounters().indexWrites - counters.indexWrites, 1);
  } finally { f.runtime.close(); }
});

test('已有100局偏好读取EIO/合法坏JSON绝不回退5局删除；可明确重存偏好恢复维护', async () => {
  const f = fixture();
  try {
    await f.ledger.ledgerSetSessionRetentionAsync(f.root, 100);
    for (let id = 1; id <= 8; id++) {
      f.begin(id, 'launch'); f.runtime.write('logs/ledger/' + id + '/game/mc_output.log', `##AMCL-SESSION-BEGIN {"activityId":${id}}\nbody`); f.end(id);
    }
    const readText = f.runtime.kitFs.readText;
    f.runtime.kitFs.readText = async p => {
      if (p.endsWith('/session-retention.json')) { const error = new Error('quota EIO'); error.code = 13900013; throw error; }
      return readText(p);
    };
    await f.flush(); for (let id = 1; id <= 8; id++) assert.ok(fs.existsSync(f.ledger.ledgerDirOf(f.root, id)));
    await assert.rejects(f.ledger.ledgerSessionRetentionAsync(f.root), /quota EIO/);
    f.runtime.kitFs.readText = readText; f.runtime.write('logs/session-retention.json', '{"invalid":true}');
    f.ledger.ledgerMarkDirty(f.root, 1); await f.flush();
    for (let id = 1; id <= 8; id++) assert.ok(fs.existsSync(f.ledger.ledgerDirOf(f.root, id)));
    await assert.rejects(f.ledger.ledgerSessionRetentionAsync(f.root), /设置损坏/);
    await f.ledger.ledgerSetSessionRetentionAsync(f.root, 100); await f.flush();
    assert.equal(await f.ledger.ledgerSessionRetentionAsync(f.root), 100);
  } finally { f.runtime.close(); }
});

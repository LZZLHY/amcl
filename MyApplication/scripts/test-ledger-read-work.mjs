/**
 * 执行生产账本/历史/占用/关联读取，核验工作量随实际变更增长，而非重复打开全部metadata。
 * 大规模夹具仅扩充合法小清单和原件，生产索引/缓存/恢复算法不在测试复制。
 * SDK边界由既有runtime映射真实宿主文件；只比较调用次数，不把宿主耗时当设备性能。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 创建独占E盘夹具；暂停维护不改变读取语义，防止普通活动保留预算清掉规模样本。 */
function fixture(count = 10) {
  const runtime = evidenceRuntime({ imports: { './DownloadManager': { formatBytes: String }, './DownloadTask': {} } });
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  ledger.configureLedgerMaintenanceOwner(true, () => false); ledger.ledgerBeginMaintenanceBatch(runtime.directory);
  assert.equal(ledger.ledgerBegin(runtime.directory, 1, { category: 'diagnostic', title: 'a' }), true);
  ledger.ledgerEnd(runtime.directory, 1, { state: ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'complete' });
  const seed = JSON.parse(fs.readFileSync(runtime.directory + '/logs/ledger/1/manifest.json', 'utf8'));
  for (let id = 2; id <= count; id++) {
    runtime.write('logs/ledger/' + id + '/manifest.json', JSON.stringify({ ...seed, activityId: id, startedAt: id, endedAt: id + 1 }));
    runtime.write('logs/ledger/' + id + '/record.log', 'bounded original ' + id);
  }
  return { runtime, ledger, root: runtime.directory };
}

/** 每次失败/缺失的SDK操作也计数；所有包装只作用于本runtime，finally关闭后不泄露到其它测试。 */
function countIo(runtime) {
  let counts = {};
  for (const key of ['stat', 'lstat', 'readText', 'listFile', 'write', 'fsync', 'rename']) {
    const original = runtime.kitFs[key];
    runtime.kitFs[key] = (...args) => {
      counts[key] = (counts[key] ?? 0) + 1;
      if (key === 'readText' && String(args[0]).endsWith('/manifest.json')) counts.manifests = (counts.manifests ?? 0) + 1;
      return original(...args);
    };
  }
  return { reset() { counts = {}; }, read() { return { ...counts }; } };
}

/** 拒绝同步文件边界，避免正常异步入口在索引缺失或损坏时偷偷全历史同步重建。 */
function rejectSync(runtime) {
  for (const key of ['statSync', 'lstatSync', 'listFileSync', 'readTextSync', 'openSync', 'readSync',
    'writeSync', 'fsyncSync', 'renameSync', 'mkdirSync']) runtime.kitFs[key] = () => assert.fail('读取不得调用 ' + key);
}

for (const count of [50, 500, 2000]) test('真实' + count + '活动热投影零manifest/metadata读，单局dirty只重测一局', async () => {
  const f = fixture(count);
  try {
    rejectSync(f.runtime); const io = countIo(f.runtime);
    await f.ledger.ledgerReadSnapshotAsync(f.root);
    io.reset(); const before = f.ledger.ledgerMaintenanceCounters();
    const warm = await f.ledger.ledgerReadSnapshotAsync(f.root);
    assert.equal(warm.entries.length, count); assert.equal(warm.manifests.size, count);
    assert.equal(io.read().manifests ?? 0, 0); assert.equal(io.read().stat ?? 0, 0);
    assert.equal(io.read().lstat, count + 1); assert.equal(io.read().listFile, 1);
    assert.equal(f.ledger.ledgerMaintenanceCounters().activityScans, before.activityScans);
    const warmWork = io.read();
    const history = f.runtime.load('feature_core/src/main/ets/download/DownloadHistory.ets');
    const store = new history.DownloadHistoryStore(); await store.init(f.runtime.context);
    io.reset(); assert.equal((await store.readSnapshotAsync(() => false)).records.length, count);
    assert.equal(io.read().manifests ?? 0, 0, '历史视图不能二次打开所有manifest');
    io.reset(); const storage = f.runtime.load('commons/src/main/ets/utils/ActivityStorage.ets');
    assert.equal((await storage.readActivityStorage(f.root, () => false)).groups[0].items.length, count);
    assert.equal(io.read().manifests ?? 0, 0, '占用视图消费同轮原清单');
    await f.ledger.ledgerSetPinnedAsync(f.root, count, true);
    io.reset(); const changed = await f.ledger.ledgerReadSnapshotAsync(f.root);
    assert.equal(changed.manifests.get(count).pinned, true);
    assert.equal(f.ledger.ledgerMaintenanceCounters().activityScans - before.activityScans, 1);
    assert.equal(io.read().manifests, 1); assert.ok(io.read().stat <= 32);
    console.log(JSON.stringify({ count, warmWork, changedWork: io.read() }));
  } finally { f.runtime.close(); }
});

test('独立游戏runtime原子发布terminal/metadata/capture，host旧缓存只重测对应活动', async () => {
  const f = fixture(50), game = evidenceRuntime();
  try {
    const gameLedger = game.load('commons/src/main/ets/utils/ActivityLedger.ets'); gameLedger.configureLedgerMaintenanceOwner(false);
    const gameIo = game.load('commons/src/main/ets/utils/EvidenceIo.ets');
    await f.ledger.ledgerReadSnapshotAsync(f.root); const io = countIo(f.runtime);
    for (const name of ['game-terminal.json', 'game-metadata.json', 'capture-game.json']) {
      const before = f.ledger.ledgerMaintenanceCounters();
      await gameIo.writeEvidenceTextAtomicAsync(f.root + '/logs/ledger/25/' + name,
        JSON.stringify({ schema: 1, activityId: 25, runNonce: 'external-game', payload: name }));
      io.reset(); const snapshot = await f.ledger.ledgerReadSnapshotAsync(f.root);
      assert.equal(snapshot.entries.length, 50);
      assert.equal(f.ledger.ledgerMaintenanceCounters().activityScans - before.activityScans, 1);
      assert.equal(io.read().manifests, 1); assert.ok(io.read().stat <= 32);
    }
  } finally { game.close(); f.runtime.close(); }
});

test('跨进程原清单在读取中原子更换时发布unknown，下轮读取真实新状态，不缓存混合快照', async () => {
  const f = fixture(10), game = evidenceRuntime();
  try {
    await f.ledger.ledgerListAsync(f.root); f.ledger.ledgerMarkDirty(f.root, 5);
    const gameLedger = game.load('commons/src/main/ets/utils/ActivityLedger.ets'); gameLedger.configureLedgerMaintenanceOwner(false);
    const gameIo = game.load('commons/src/main/ets/utils/EvidenceIo.ets');
    let enter, release, intercepted = false;
    const entered = new Promise(resolve => { enter = resolve; }), gate = new Promise(resolve => { release = resolve; });
    const original = f.runtime.kitFs.readText;
    f.runtime.kitFs.readText = async p => {
      const value = await original(p);
      if (!intercepted && p.endsWith('/ledger/5/manifest.json')) { intercepted = true; enter(); await gate; }
      return value;
    };
    const reading = f.ledger.ledgerReadSnapshotAsync(f.root); await entered;
    const path = f.root + '/logs/ledger/5/manifest.json'; const manifest = JSON.parse(fs.readFileSync(path, 'utf8'));
    await gameIo.writeEvidenceTextAtomicAsync(path, JSON.stringify({ ...manifest, title: 'external replacement', revision: manifest.revision + 1 }));
    release(); const first = await reading;
    assert.equal(first.entries.find(entry => entry.activityId === 5).bytesState, 'unknown');
    const next = await f.ledger.ledgerReadSnapshotAsync(f.root);
    assert.equal(next.manifests.get(5).title, 'external replacement');
    assert.equal(next.entries.find(entry => entry.activityId === 5).bytesState, 'current');
  } finally { game.close(); f.runtime.close(); }
});

test('旧SDK无纳秒精度仍核实metadata内容，索引坏/缺和关联读取全程异步恢复', async () => {
  const f = fixture(10);
  try {
    for (const key of ['stat', 'lstat']) {
      const original = f.runtime.kitFs[key];
      f.runtime.kitFs[key] = async p => { const stat = await original(p); delete stat.mtimeNs; delete stat.ctimeNs; return stat; };
    }
    await f.ledger.ledgerReadSnapshotAsync(f.root);
    const path = f.root + '/logs/ledger/5/manifest.json'; const before = fs.readFileSync(path, 'utf8');
    fs.writeFileSync(path, before.replace('"title":"a"', '"title":"b"'));
    rejectSync(f.runtime);
    assert.equal((await f.ledger.ledgerReadSnapshotAsync(f.root)).manifests.get(5).title, 'b');
    f.runtime.write('logs/ledger/index.json', '{broken');
    assert.equal((await f.ledger.ledgerReadSnapshotAsync(f.root)).entries.length, 10);
    fs.unlinkSync(f.root + '/logs/ledger/index.json');
    assert.deepEqual(await f.ledger.ledgerRelatedActivitiesAsync(f.root, 5, () => false), []);
    assert.equal((await f.ledger.ledgerReadSnapshotAsync(f.root)).entries.length, 10);
    fs.mkdirSync(f.root + '/logs/ledger/index.json');
    assert.equal((await f.ledger.ledgerReadSnapshotAsync(f.root)).entries.length, 10, '索引坏路径不阻断原件异步对账');
  } finally { f.runtime.close(); }
});

test('无变化详情轮转核验零写盘且不产生dirty，取消保留现有投影', async () => {
  const f = fixture(1);
  try {
    const capture = f.runtime.load('commons/src/main/ets/utils/SessionCapture.ets');
    capture.beginSessionCapture(f.root, 1, '', '', ''); await f.ledger.ledgerListAsync(f.root);
    const path = f.root + '/logs/ledger/1/capture-sources.json'; const before = fs.readFileSync(path);
    rejectSync(f.runtime); const io = countIo(f.runtime);
    await capture.verifySessionCaptureRotations(f.root, 1); await capture.verifySessionCaptureRotations(f.root, 1);
    assert.deepEqual(fs.readFileSync(path), before); assert.equal(io.read().write ?? 0, 0);
    assert.equal(io.read().fsync ?? 0, 0); assert.equal(f.ledger.ledgerMaintenanceSnapshot(f.root).pendingCount, 0);
    await assert.rejects(f.ledger.ledgerReadSnapshotAsync(f.root, () => true), /取消/);
  } finally { f.runtime.close(); }
});

test('真实详情证据枚举/环境观测/阅读分页无同步文件入口，原白名单与行号语义保持', async () => {
  const f = fixture(1);
  try {
    const environment = f.runtime.load('commons/src/main/ets/utils/SessionEnvironment.ets');
    environment.updateSessionEnvironment(f.root, 1, [environment.sessionEnvironmentFact('host.os', 'HarmonyOS', 'fixture')]);
    f.runtime.write('logs/ledger/1/environment-observed.log', 'AMCL_ENV_V1\tgpu.model\tobserved-gpu\truntime\n');
    const file = f.runtime.write('logs/ledger/1/launcher/launcher-host.log', '[20:00:00] [main/INFO]: first\nsecond\n');
    const expected = environment.readObservedSessionEnvironment(f.root, 1);
    rejectSync(f.runtime);
    assert.deepEqual(await environment.readObservedSessionEnvironmentAsync(f.root, 1), expected);
    const service = f.runtime.load('entry/src/main/ets/components/ActivityEvidenceService.ets');
    const files = await service.loadActivityEvidence(f.root, 1, () => false);
    assert.ok(files.some(item => item.path === 'launcher/launcher-host.log'));
    const { ActivityLogModel } = f.runtime.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const model = new ActivityLogModel();
    try {
      assert.equal(await model.loadEvidence([{ path: file, compressed: false }], 0, ''), true);
      assert.equal(model.getData(0).sourceLineNumber, 1);
    } finally { model.cancel(); }
  } finally { f.runtime.close(); }
});

test('目录发现阶段离页取消在当前8局批次后停止，不继续枚举后续全部活动', async () => {
  const f = fixture(50);
  try {
    let calls = 0, cancelled = false; const lstat = f.runtime.kitFs.lstat;
    f.runtime.kitFs.lstat = async p => { calls++; if (calls === 8) cancelled = true; return lstat(p); };
    await assert.rejects(f.ledger.ledgerReadSnapshotAsync(f.root, () => cancelled), /取消/);
    assert.equal(calls, 8, '取消后不得启动下一批目录lstat');
    assert.equal(f.ledger.ledgerMaintenanceCounters().activityScans, 0);
  } finally { f.runtime.close(); }
});

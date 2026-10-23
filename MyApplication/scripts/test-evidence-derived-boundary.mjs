/**
 * 内部派生文件和事实证据的真实生产边界回归。
 * 宿主只适配SDK文件/摘要端口，分类、归档、封账、读取及计量均执行生产.ets函数。
 * 每个夹具使用外部临时区并关闭调度、等待在途维护后清理；不触碰设备或旧证据原件。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 建立真实单owner和维护hold；测试显式释放批次，避免定时维护与目录清理竞争。 */
function fixture(options = {}) {
  const runtime = evidenceRuntime(options);
  const root = runtime.directory.replaceAll('\\', '/');
  const load = name => runtime.load('commons/src/main/ets/utils/' + name + '.ets');
  const ledger = load('ActivityLedger'), evidence = load('SessionEvidence'), types = load('EvidenceTypes'), io = load('EvidenceIo');
  ledger.configureLedgerMaintenanceOwner(true);
  ledger.ledgerBeginMaintenanceBatch(root);
  return { ...runtime, root, ledger, evidence, types, io, load,
    dir: id => ledger.ledgerDirOf(root, id),
    async close() {
      ledger.configureLedgerMaintenanceOwner(false);
      await ledger.ledgerFlushMaintenanceAsync(root);
      runtime.close();
    } };
}

/** 为真实账本写入一份正文及其采集计数，保证内务条目以外的完整性行为可对照。 */
async function diagnostic(f, id = 100) {
  await f.ledger.ledgerBeginAsync(f.root, id, { category: 'diagnostic', title: 'derived boundary' });
  f.write(`logs/ledger/${id}/launcher/launcher-host.log`, 'unchanged factual body\n');
  f.write(`logs/ledger/${id}/capture-host.json`, JSON.stringify({ dropped: 0, writeFailures: 0, truncated: 0, sealed: true }));
  return { state: f.ledger.LedgerState.SUCCESS, source: 'test.boundary', summary: 'done', endedAt: id + 1 };
}

/** 精确统计当前目录全部实际文件，独立核对生产计量不能借内务过滤减少占用。 */
function physicalBytes(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).reduce((sum, entry) => sum +
    (entry.isDirectory() ? physicalBytes(directory + '/' + entry.name) : fs.statSync(directory + '/' + entry.name).size), 0);
}

test('反控：允许 recovery-state 进入生产分类会重现检查点字节反馈；固定分类阻断反馈但计入实际占用', async () => {
  // 仅移除一个分类条件，所有封账及扫描算法仍是生产实现，证明样本能识别旧缺陷。
  const old = fixture({ transform: (file, source) => file.endsWith('EvidenceTypes.ets')
    ? source.replace("part === 'recovery-state.json' || ", '') : source });
  try {
    const outcome = await diagnostic(old);
    old.write('logs/ledger/100/launcher/recovery-state.json', '{"schema":3}');
    await old.ledger.ledgerEndAsync(old.root, 100, outcome, { capturePrepared: true, repairArtifacts: true });
    assert.ok(old.ledger.ledgerManifest(old.root, 100).files.some(file => file.name === 'launcher/recovery-state.json'));
  } finally { await old.close(); }

  const f = fixture();
  try {
    const outcome = await diagnostic(f);
    const internal = ['launcher/recovery-state.json', 'launcher/recovery-receipt.json', 'launcher/recovery-state/old.json',
      'experience-index.json', 'platform-inputs.json', 'launcher/evidence-selection.json',
      'launcher/x.pending-dir/manifest.json', 'game/test.partial'];
    for (const name of internal) f.write('logs/ledger/100/' + name, '{"internal":true}');
    f.write('logs/ledger/100/environment.json', '{"fact":true}');
    await f.ledger.ledgerEndAsync(f.root, 100, outcome, { capturePrepared: true, repairArtifacts: true });
    const first = fs.readFileSync(f.dir(100) + '/manifest.json');
    const firstEvidence = fs.readFileSync(f.dir(100) + '/evidence-manifest.json');
    const names = f.ledger.ledgerManifest(f.root, 100).files.map(file => file.name);
    assert.ok(names.includes('environment.json')); assert.ok(names.includes('capture-host.json'));
    assert.ok(names.includes('launcher/launcher-host.log'));
    for (const name of internal) assert.ok(!names.includes(name), name);
    f.write('logs/ledger/100/launcher/recovery-state.json', JSON.stringify({ schema: 3, data: 'x'.repeat(4096) }));
    await f.ledger.ledgerEndAsync(f.root, 100, outcome, { capturePrepared: true, repairArtifacts: true });
    assert.deepEqual(fs.readFileSync(f.dir(100) + '/manifest.json'), first);
    assert.deepEqual(fs.readFileSync(f.dir(100) + '/evidence-manifest.json'), firstEvidence);
    await f.ledger.ledgerEndMaintenanceBatchAsync(f.root);
    f.ledger.ledgerBeginMaintenanceBatch(f.root);
    const entry = (await f.ledger.ledgerListAsync(f.root)).find(entry => entry.activityId === 100);
    assert.equal(entry.bytesState, 'current'); assert.equal(entry.bytes, physicalBytes(f.dir(100)));
  } finally { await f.close(); }
});

test('sync/async 枚举、旧存储清单和 capture 插入共用内务边界；读取不改原存储字节或默认外发', async () => {
  const f = fixture();
  try {
    await diagnostic(f);
    const path = 'launcher/recovery-state.json';
    const localPath = f.write('logs/ledger/100/' + path, '{"internal":1}');
    const source = { source: localPath, destination: path, baseline: '', captured: '', state: 'complete', reason: '', attribution: 'exact' };
    f.write('logs/ledger/100/capture-sources.json', JSON.stringify({ schema: 1, activityId: 100, startedAt: 100,
      endedAt: 101, filesDir: f.root, gameDir: '', appFilesDir: '', jdk: '', sources: [source] }));
    const injected = { fileId: 'activity-100/' + path, path, localPath, role: 'launcher', source: 'amcl-launcher',
      state: 'complete', uploadPolicy: 'default', defaultSelected: true, bytes: 14, capturedAt: 0, completedAt: 12,
      digest: '', attribution: 'exact', reason: '', lines: 0 };
    const manifestPath = f.write('logs/ledger/100/evidence-manifest.json', JSON.stringify({ schema: 2, activityId: 100,
      revision: 8, captureState: 'sealed', integrityState: 'complete', files: [injected] }));
    const original = fs.readFileSync(manifestPath);
    for (const files of [f.evidence.listSessionEvidence(f.root, 100), await f.evidence.listSessionEvidenceAsync(f.root, 100),
      f.evidence.readSessionEvidence(f.root, 100).files, (await f.evidence.readSessionEvidenceAsync(f.root, 100)).files]) {
      assert.ok(files.every(file => file.path !== path));
    }
    assert.equal(f.types.isDefaultEvidenceFile(injected), false);
    assert.deepEqual(f.types.normalizeEvidenceSelection([injected], [injected.fileId]), []);
    assert.deepEqual(fs.readFileSync(manifestPath), original); assert.equal(fs.readFileSync(localPath, 'utf8'), '{"internal":1}');
  } finally { await f.close(); }
});

test('真实 Evidence 重建只复用同内容同状态有效旧时间；新文件及未知时间为0，sync/async一致', async () => {
  for (const synchronous of [false, true]) {
    const f = fixture();
    try {
      await diagnostic(f);
      const refresh = () => synchronous ? f.evidence.refreshSessionEvidence(f.root, 100) : f.evidence.refreshSessionEvidenceAsync(f.root, 100);
      const initial = await refresh();
      const body = initial.files.find(file => file.path === 'launcher/launcher-host.log');
      assert.equal(body.completedAt, 0);
      body.capturedAt = 7; body.completedAt = 12;
      f.write('logs/ledger/100/evidence-manifest.json', JSON.stringify(initial));
      f.write('logs/ledger/100/system/crash-report-event-new.json', '{"actualNewEvent":true}');
      const next = await refresh();
      assert.equal(next.revision, initial.revision + 1);
      const unchanged = next.files.find(file => file.path === body.path);
      assert.equal(unchanged.capturedAt, 7); assert.equal(unchanged.completedAt, 12);
      const newFile = next.files.find(file => file.path === 'system/crash-report-event-new.json');
      assert.equal(newFile.completedAt, 0); assert.equal(newFile.capturedAt, 0);
      const bytes = fs.readFileSync(f.dir(100) + '/evidence-manifest.json');
      await refresh(); assert.deepEqual(fs.readFileSync(f.dir(100) + '/evidence-manifest.json'), bytes);
      f.write('logs/ledger/100/launcher/launcher-host.log', 'actually changed factual body\n');
      const changed = await refresh();
      assert.equal(changed.files.find(file => file.path === body.path).completedAt, 0);
    } finally { await f.close(); }
  }
});

/** legacy 无native状态的输出只凭横幅确定身份；结束仍由生产Evidence保留连续性未知。 */
async function legacy(f, id, archivedBody, sourceBody = archivedBody) {
  await f.ledger.ledgerBeginAsync(f.root, id, { category: 'launch', title: 'old stdout',
    mcDir: f.root + '/minecraft', gameDir: f.root + '/minecraft' });
  const banner = `##AMCL-SESSION-BEGIN {"activityId":${id}}\n`;
  const source = f.write('minecraft/mc_output.log', banner + sourceBody);
  const target = f.write(`logs/ledger/${id}/game/mc_output.log`, banner + archivedBody);
  return { source, target, outcome: { state: f.ledger.LedgerState.SUCCESS, source: 'test.legacy', summary: 'done', endedAt: id + 1 } };
}

test('跨进程无缓存 legacy 同正文只读复用 inode；不同来源正文保留旧归档且不重签', async () => {
  for (const synchronous of [false, true]) {
    for (const different of [false, true]) {
      const f = fixture();
      try {
        const value = await legacy(f, 100, 'original archive\n', different ? 'different producer\n' : 'original archive\n');
        const before = fs.readFileSync(value.target), stamp = fs.statSync(value.target, { bigint: true });
        let copies = 0;
        const copy = synchronous ? f.kitFs.copyFileSync : f.kitFs.copyFile;
        if (synchronous) f.kitFs.copyFileSync = (...args) => { copies++; return copy(...args); };
        else f.kitFs.copyFile = async (...args) => { copies++; return copy(...args); };
        if (synchronous) f.ledger.archiveSessionLogs(f.root, { ...f.ledger.ledgerManifest(f.root, 100), ...value.outcome });
        else await f.ledger.ledgerEndAsync(f.root, 100, value.outcome, { capturePrepared: true, repairArtifacts: true });
        assert.equal(copies, 0); assert.deepEqual(fs.readFileSync(value.target), before);
        const after = fs.statSync(value.target, { bigint: true });
        assert.equal(after.ino, stamp.ino); assert.equal(after.mtimeNs, stamp.mtimeNs); assert.equal(after.ctimeNs, stamp.ctimeNs);
        const item = f.load('SessionCapture').readSessionCapture(f.root, 100).sources.find(item => item.destination === 'game/mc_output.log');
        if (different) assert.equal(item, undefined);
        else { assert.equal(item.sealed, true); assert.equal(item.capturedSha256, crypto.createHash('sha256').update(before).digest('hex')); }
      } finally { await f.close(); }
    }
  }
});

test('legacy 固定封账收据的坏 SHA 不能被完整来源覆盖或重签；仍 partial 并保留原期望摘要', async () => {
  for (const synchronous of [false, true]) {
    const f = fixture();
    try {
      const value = await legacy(f, 100, 'original archive\n');
      const capture = f.load('SessionCapture');
      capture.recordArchivedSessionSource(f.root, 100, value.source, 'game/mc_output.log');
      const originalItem = capture.readSessionCapture(f.root, 100).sources.find(item => item.destination === 'game/mc_output.log');
      const bad = Buffer.alloc(fs.statSync(value.target).size, 88); fs.writeFileSync(value.target, bad);
      if (synchronous) f.ledger.archiveSessionLogs(f.root, { ...f.ledger.ledgerManifest(f.root, 100), ...value.outcome });
      else await f.ledger.ledgerEndAsync(f.root, 100, value.outcome, { capturePrepared: true, repairArtifacts: true });
      const files = await f.evidence.listSessionEvidenceAsync(f.root, 100);
      const file = files.find(file => file.path === 'game/mc_output.log');
      assert.equal(file.state, 'partial'); assert.equal(file.verification, 'unverified');
      assert.equal(file.rawSha256, originalItem.capturedSha256); assert.equal(file.completedAt, 0);
      assert.deepEqual(fs.readFileSync(value.target), bad);
      assert.equal(capture.readSessionCapture(f.root, 100).sources.find(item => item.destination === 'game/mc_output.log').capturedSha256,
        originalItem.capturedSha256);
    } finally { await f.close(); }
  }
});

test('真实新来源按原启动前baseline/可信结束正常捕获，仍可核验 complete', async () => {
  const f = fixture();
  try {
    const id = Date.now() - 2000;
    f.write('minecraft/logs/latest.log', 'previous run\n');
    await f.ledger.ledgerBeginAsync(f.root, id, { category: 'launch', title: 'new capture', gameDir: f.root + '/minecraft' });
    f.write('minecraft/logs/latest.log', 'new trusted source\n[INFO] Stopping!\n');
    await f.load('SessionCapture').checkpointSessionCaptureAsync(f.root, id, Date.now(), 0, true, undefined, true);
    const file = (await f.evidence.listSessionEvidenceAsync(f.root, id)).find(file => file.path === 'game/logs/latest.log');
    assert.equal(file.state, 'complete'); assert.equal(file.verification, 'verified'); assert.equal(file.completedAt, 0);
    assert.equal(fs.readFileSync(file.localPath, 'utf8'), 'new trusted source\n[INFO] Stopping!\n');
  } finally { await f.close(); }
});

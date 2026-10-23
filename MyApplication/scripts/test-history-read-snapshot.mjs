/** 执行真实历史owner/账本原件，证明异步列表语义、并发预算与失败/取消保留边界。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { promisify } from 'node:util';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/**
 * runtime是本用例独立SDK适配，rejectSync默认true；原位改为真实Node异步文件操作并可拒绝全部同步入口。
 * stat按SDK字段映射宿主bigint时间/属性，目录句柄沿用负数替身；普通文件仍打开、读写、同步和关闭真实FD。
 * 只改变平台边界，不修改生产历史/索引算法；函数无返回值，替身仅存活于该runtime模块缓存。
 * 用例须等待所有读取/取消收尾并finally关闭runtime，不能让未关闭FD或旧回调跨夹具；不据宿主耗时断言设备性能。
 */
function asyncIoOnly(runtime, rejectSync = true) {
  const kit = runtime.kitFs;
  const info = value => ({ size: Number(value.size), ino: value.ino,
    mtime: Number(value.mtimeMs / 1000n), ctime: Number(value.ctimeMs / 1000n),
    mtimeNs: value.mtimeNs, ctimeNs: value.ctimeNs,
    isFile: () => value.isFile(), isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() });
  kit.stat = async p => info(await (typeof p === 'number'
    ? promisify(fs.fstat)(p, { bigint: true }) : fs.promises.stat(p, { bigint: true })));
  kit.lstat = async p => info(await fs.promises.lstat(p, { bigint: true }));
  kit.listFile = p => fs.promises.readdir(p);
  kit.open = async (p, mode = 0) => {
    // Windows宿主不能用普通Node fd同步目录；沿用现有runtime的目录句柄边界，检查仍异步。
    try { if ((await fs.promises.stat(p)).isDirectory()) return { fd: -100 }; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    return { fd: await promisify(fs.open)(p, mode & 512 ? 'w' : mode === 0 ? 'r' : mode & 64 ? 'a' : 'r+') };
  };
  kit.close = async file => { const fd = typeof file === 'number' ? file : file.fd; if (fd >= 0) await promisify(fs.close)(fd); };
  kit.read = async (fd, buffer, options = {}) => (await promisify(fs.read)(fd, Buffer.from(buffer), 0,
    options.length ?? buffer.byteLength, options.offset ?? null)).bytesRead;
  kit.write = async (fd, content) => (await promisify(fs.write)(fd,
    typeof content === 'string' ? content : Buffer.from(content))).bytesWritten;
  kit.fsync = async fd => { if (fd >= 0) await promisify(fs.fsync)(fd); };
  kit.rename = (from, to) => fs.promises.rename(from, to);
  kit.mkdir = p => fs.promises.mkdir(p, { recursive: true });
  kit.unlink = p => fs.promises.unlink(p);
  kit.access = async p => { try { await fs.promises.access(p); return true; } catch (_) { return false; } };
  if (rejectSync) for (const key of ['statSync', 'lstatSync', 'listFileSync', 'readTextSync', 'openSync', 'readSync', 'writeSync',
    'fsyncSync', 'renameSync', 'mkdirSync']) kit[key] = () => assert.fail('异步投影不能调用 ' + key);
}

/**
 * 无参数构造外置磁盘和真实DownloadHistoryStore/ActivityLedger，Preferences由evidenceRuntime适配。
 * 初始历史含凭据/AI字段；真实账本包含同活动不同结局、账本独有项和故意损坏目录，以检验合并与unknown。
 * owner guard禁止自动淘汰，不干预受测投影；先启用异步IO但保留同步读取供用例取对照，随后用例可强制拒绝Sync。
 * 返回运行时、真实store/ledger及原历史record；成功返回后调用方在finally清理自身受验证目录和模块实例。
 */
async function fixture() {
  const runtime = evidenceRuntime({ imports: { './DownloadManager': { formatBytes: String }, './DownloadTask': {} } });
  const api = runtime.load('feature_core/src/main/ets/download/DownloadHistory.ets');
  const store = new api.DownloadHistoryStore(); await store.init(runtime.context);
  const record = { versionName: '26.3', gameVersion: '26.3', loaderType: 'launch', startedAt: 100, durationMs: 42,
    totalBytes: 0, fileCount: 0, status: 'success', category: 'launch', lsToken: 'fixture-credential', aiPath: '/fixture-ai' };
  await store.add(record);
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  // 本测试只读取列表，不竞争生产owner的后台维护/删除；清单和终态创建仍执行真实入口。
  ledger.configureLedgerMaintenanceOwner(true, () => false);
  ledger.ledgerBegin(runtime.directory, 100, { category: 'launch', title: 'same activity', gameVersionId: '26.3' });
  ledger.ledgerEnd(runtime.directory, 100, { state: ledger.LedgerState.CRASHED, source: 'fixture', summary: 'actual crash' });
  ledger.ledgerBegin(runtime.directory, 200, { category: 'launch', title: 'ledger-only', gameVersionId: '1.21.1' });
  runtime.write('logs/ledger/300/manifest.json', 'broken'); runtime.write('logs/ledger/400', 'not a directory');
  asyncIoOnly(runtime, false);
  return { runtime, store, ledger, record };
}

test('真实异步投影等同同步结局合并，保留凭据/账本独有项/损坏目录且不改原件', async () => {
  const f = await fixture();
  try {
    const expected = f.store.list(), before = fs.readFileSync(f.runtime.directory + '/logs/ledger/100/manifest.json', 'utf8');
    asyncIoOnly(f.runtime);
    const result = await f.store.readSnapshotAsync(() => false);
    assert.deepEqual(result.records, expected); assert.deepEqual(result.ledgerIds, [300, 200, 100]);
    const game = result.records.find(record => record.startedAt === 100);
    assert.equal(game.status, 'crashed'); assert.equal(game.lsToken, f.record.lsToken); assert.equal(game.aiPath, f.record.aiPath);
    assert.equal(result.ledgerBytes, -1, '损坏manifest的目录占用未知，不能用零填补完整总量');
    assert.equal(fs.readFileSync(f.runtime.directory + '/logs/ledger/100/manifest.json', 'utf8'), before);
  } finally { f.runtime.close(); }
});

test('真实stat故障保留历史与原件，将总占用发布为未知而非少算后的成功数字', async () => {
  const f = await fixture();
  try {
    const before = fs.readFileSync(f.runtime.directory + '/logs/ledger/100/manifest.json', 'utf8');
    const original = f.runtime.kitFs.lstat;
    f.runtime.kitFs.lstat = async p => {
      if (p.endsWith('/logs/ledger/100/manifest.json')) throw new Error('synthetic stat EIO');
      return original(p);
    };
    f.ledger.ledgerMarkDirty(f.runtime.directory, 100);
    const result = await f.store.readSnapshotAsync(() => false);
    assert.equal(result.ledgerBytes, -1);
    assert.equal(result.records.find(record => record.startedAt === 100).status, 'crashed');
    assert.ok(result.ledgerIds.includes(100));
    assert.equal(fs.readFileSync(f.runtime.directory + '/logs/ledger/100/manifest.json', 'utf8'), before);
  } finally { f.runtime.close(); }
});

test('读取期间耐久历史提交进入最终投影；取消不发布部分结果或改动历史/原件', async () => {
  const f = await fixture();
  try {
    const original = f.runtime.kitFs.readText; let release, enteredResolve;
    const entered = new Promise(resolve => { enteredResolve = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    f.runtime.kitFs.readText = async p => { enteredResolve(); await gate; return original(p); };
    const pending = f.store.readSnapshotAsync(() => false); await entered;
    await f.store.add({ ...f.record, startedAt: 500 }); release();
    assert.ok((await pending).records.some(record => record.startedAt === 500));
    let cancelled = false, release2, entered2Resolve;
    const entered2 = new Promise(resolve => { entered2Resolve = resolve; }); const gate2 = new Promise(resolve => { release2 = resolve; });
    f.runtime.kitFs.readText = async p => { entered2Resolve(); await gate2; return original(p); };
    const before = f.store.listStored(); const abort = f.store.readSnapshotAsync(() => cancelled);
    await entered2; cancelled = true; release2(); await assert.rejects(abort, /已取消/);
    assert.deepEqual(f.store.listStored(), before);
  } finally { f.runtime.close(); }
});

test('完整清单读取批内并发不超过八份，批次间给事件循环机会，不把日志正文当列表输入', async () => {
  const f = await fixture();
  try {
    const seed = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/ledger/100/manifest.json', 'utf8'));
    for (let id = 1000; id < 1065; id++) f.runtime.write('logs/ledger/' + id + '/manifest.json', JSON.stringify({ ...seed, activityId: id, startedAt: id }));
    // 先建立正常可信派生索引，随后只统计列表的实际manifest读取。
    f.ledger.rebuildIndex(f.runtime.directory);
    const original = f.runtime.kitFs.readText; let active = 0, maximum = 0, manifests = 0, turns = 0;
    const timer = setInterval(() => { turns++; }, 0);
    f.runtime.kitFs.readText = async p => {
      if (!p.endsWith('/manifest.json')) return original(p);
      active++; manifests++; maximum = Math.max(maximum, active);
      try { await new Promise(resolve => setImmediate(resolve)); return await original(p); } finally { active--; }
    };
    try { const result = await f.store.readSnapshotAsync(() => false); assert.ok(result.records.length >= 67); }
    finally { clearInterval(timer); }
    assert.ok(maximum <= 8 && maximum > 0); assert.ok(manifests >= 68); assert.ok(turns > 0);
  } finally { f.runtime.close(); }
});

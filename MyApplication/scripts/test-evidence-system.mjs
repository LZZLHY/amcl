import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import zlib from 'node:zlib';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const common = name => 'commons/src/main/ets/utils/' + name + '.ets';

// 升级后的新旧 stdout 同时存在时，新路径必须胜出；旧恢复时间也不能被默认视作精确。
test('migration prefers new stdout over the legacy alias and old inferred timestamps remain unknown', () => {
  const f = evidenceRuntime();
  try {
    const ledger = f.load(common('ActivityLedger'));
    ledger.ledgerBegin(f.directory, 100, { category: 'launch', title: 'migration' });
    f.write('logs/ledger/100/game.log', 'legacy body without identity');
    const current = f.write('logs/ledger/100/game/mc_output.log', '##AMCL-SESSION-BEGIN {"activityId":100}\nCURRENT');
    const evidence = f.load(common('SessionEvidence')).listSessionEvidence(f.directory, 100);
    assert.equal(evidence.find(file => file.role === 'minecraft-output').localPath.replaceAll('\\', '/'), current.replaceAll('\\', '/'));
    const manifest = ledger.parseLedgerManifest(JSON.stringify({ activityId: 100, category: 'launch', startedAt: 100, endedAt: 999999, state: 1, outcomeSource: 'session.full-evidence' }));
    assert.equal(manifest.endTimeEstimated, true);
  } finally { f.close(); }
});

// 顺序遍历同一文件应只扫描一次；回看最近页不得触发 IO，来源变化必须使缓存失效。
test('reader continues pages, preserves source lines, highlights cross-token matches and invalidates changed files', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel, logSpans } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const model = new ActivityLogModel();
    const text = Array.from({ length: 30000 }, (_, n) => `row-${n + 1} ${'x'.repeat(90)}\n`).join('');
    const file = f.write('reader.log', text);
    let readBytes = 0;
    f.control.afterRead = async (_fd, bytes) => { readBytes += bytes; };
    for (let page = 0; page < 100; page++) {
      await model.loadEvidence([{ path: file, compressed: false }], 0, '', page * 300);
      assert.equal(model.getData(0).sourceLineNumber, page * 300 + 1);
    }
    assert.equal(readBytes, Buffer.byteLength(text), '连续翻页不能重复扫描已读取的字节');
    const beforeCache = readBytes;
    await model.loadEvidence([{ path: file, compressed: false }], 0, '', 29700);
    assert.equal(readBytes, beforeCache, '最近页面直接复用有界缓存');
    f.write('reader.log', 'CHANGED\n');
    await model.loadEvidence([{ path: file, compressed: false }], 0, '', 0);
    assert.equal(model.getData(0).text, 'CHANGED');
    const b = f.write('second.log', '[20:00:00] [main/ERROR]: boom\nB2\n');
    await model.loadEvidence([{ path: file, compressed: false }, { path: b, compressed: false }], 0, '');
    assert.equal(model.getData(1).sourcePath, b);
    assert.equal(model.getData(1).sourceLineNumber, 1);
    await model.loadEvidence([{ path: b, compressed: false }], 0, 'ERROR]: boom');
    assert.equal(logSpans(model.getData(0), 'ERROR]: boom').filter(s => s.color === '#FDE047').map(s => s.text).join(''), 'ERROR]: boom');
    const long = f.write('long.log', 'x'.repeat(2048) + 'boundary');
    await model.loadEvidence([{ path: long, compressed: false }], 0, 'xboundary');
    const marked = Array.from({ length: model.totalCount() }, (_, n) => logSpans(model.getData(n), 'xboundary'))
      .flat().filter(span => span.color === '#FDE047').map(span => span.text).join('');
    assert.equal(marked, 'xboundary');
    // gzip 下一页和取消走同一会话状态，不能漏掉预读的第 301 条命中。
    const gzip = f.write('reader.log.gz', zlib.gzipSync(text));
    await model.loadEvidence([{ path: gzip, compressed: true }], 0, '', 0);
    await model.loadEvidence([{ path: gzip, compressed: true }], 0, '', 300);
    assert.equal(model.getData(0).sourceLineNumber, 301);
    model.cancel();
    await new Promise(resolve => setImmediate(resolve));
  } finally { f.close(); }
});

// 恢复时刻只作观察边界，不能把关闭应用后的整夜累计成游玩时间。
test('unknown recovered end time stays explicit while verified end time and unchanged archives are preserved', async () => {
  const f = evidenceRuntime();
  try {
    const ledger = f.load(common('ActivityLedger'));
    const id = Date.now() - 86400000;
    ledger.ledgerBegin(f.directory, id, { category: 'launch', title: 'test', gameVersionId: 'test', mcDir: f.directory + '/mc' });
    f.write('mc/mc_output.log', `##AMCL-SESSION-BEGIN {"activityId":${id}}\nStopping!\n`);
    let copies = 0;
    f.kitFs.copyFileSync = (from, to) => { copies++; fs.copyFileSync(from, to); };
    ledger.ledgerResolveStale(f.directory);
    const first = copies;
    ledger.ledgerArchiveCompletedSessions(f.directory);
    assert.equal(copies, first, '未变化来源不重复全量复制');
    await f.load('launch/src/main/ets/SessionOutcomeResolver.ets').resolveRecoveredSessionOutcome(f.directory, id);
    const unknown = ledger.ledgerManifest(f.directory, id);
    assert.equal(unknown.endTimeEstimated, true);
    assert(unknown.recoveredAt > id);
    ledger.ledgerEnd(f.directory, id, { state: 1, source: 'session.jvm-exit', summary: 'exact', endedAt: id + 5000, recoveredAt: Date.now() });
    const known = ledger.ledgerManifest(f.directory, id);
    assert.equal(known.endTimeEstimated, false);
    assert.equal(known.endedAt, id + 5000);
  } finally { f.close(); }
});

// 跨归档、清单与裁决执行真实生产链路，覆盖只有 stdout 的会话及别局横幅拒绝。
test('exact archived stdout survives working rotation and remains usable for outcome and diagnosis', async () => {
  for (const [body, expected] of [['---- Minecraft Crash Report ----', 4], ['[INFO] Stopping!', 1]]) {
    const f = evidenceRuntime({ imports: { feature_core: {}, launch: {} } });
    try {
      const ledger = f.load(common('ActivityLedger'));
      const evidence = f.load(common('SessionEvidence'));
      const id = Date.now() - 2000;
      ledger.ledgerBegin(f.directory, id, { category: 'launch', title: 'test', gameVersionId: 'test', mcDir: f.directory + '/mc' });
      f.write('mc/mc_output.log', `##AMCL-SESSION-BEGIN {"activityId":${id},"epochMs":${id}}\n${body}\n`);
      ledger.ledgerResolveStale(f.directory);
      f.write('mc/mc_output.log', `##AMCL-SESSION-BEGIN {"activityId":${id + 1},"epochMs":${id + 1}}\nOTHER`);
      const output = evidence.listSessionEvidence(f.directory, id).find(file => file.role === 'minecraft-output');
      assert.equal(output.attribution, 'exact');
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      assert.equal((await resolver.resolveRecoveredSessionOutcome(f.directory, id)).state, expected);
      const snap = f.load('entry/src/main/ets/components/McSessionSnapshot.ets').resolveSessionSnapshot({ startedAt: id, versionName: 'test', mcDir: f.directory + '/mc', durationMs: 0 }, '');
      assert.equal(snap.logExpired, false);
      assert.match(snap.logPath, /game\/mc_output\.log$/);
      assert.equal(snap.logExact, true);
      f.write(`logs/ledger/${id}/game/mc_output.log`, `##AMCL-SESSION-BEGIN {"activityId":${id + 10}}\nStopping!`);
      const wrong = evidence.listSessionEvidence(f.directory, id).find(file => file.role === 'minecraft-output');
      assert.equal(wrong.attribution, 'previous-session');
      assert.equal(wrong.uploadPolicy, 'never');
    } finally { f.close(); }
  }
});

// 历史读取合并最新账本终态，同时保持已保存的分享和下载统计，且不改写缓存原件。
test('history reads latest ledger outcome without losing share credentials or mutating cached history', async () => {
  const f = evidenceRuntime({ imports: { './DownloadManager': { formatBytes: String }, './DownloadTask': {} } });
  try {
    const ledger = f.load(common('ActivityLedger'));
    const { DownloadHistoryStore } = f.load('feature_core/src/main/ets/download/DownloadHistory.ets');
    const store = new DownloadHistoryStore();
    await store.init(f.context);
    ledger.ledgerBegin(f.directory, 101, { category: 'launch', title: 'test' });
    const record = { versionName: 'test', gameVersion: 'test', loaderType: 'launch', category: 'launch', startedAt: 101, durationMs: 10, totalBytes: 777, fileCount: 3, status: 'aborted', lsId: 'saved-share', lsToken: 'saved-token' };
    await store.add(record);
    ledger.ledgerEnd(f.directory, 101, { state: ledger.LedgerState.CRASHED, source: 'platform.APP_CRASH', summary: 'new crash' });
    for (const current of [store.list()[0], store.findByStartedAt(101)]) {
      assert.equal(current.status, 'crashed');
      assert.equal(current.lsId, 'saved-share');
      assert.equal(current.lsToken, 'saved-token');
      assert.equal(current.totalBytes, 777);
    }
    assert.equal(record.status, 'aborted');
  } finally { f.close(); }
});

test('native capture failures stay visible; rotations classified; saved selection uses current revision', () => {
  const f = evidenceRuntime();
  try {
    const s = f.load(common('SessionEvidence'));
    f.write('logs/ledger/1/launcher/launcher-host.log', 'launcher');
    f.write('logs/ledger/1/capture-host.json', JSON.stringify({ sealed: true, dropped: 7, writeFailures: 1, truncated: 0 }));
    f.write('logs/ledger/1/game/logs/2026-09-17-1.log.gz', zlib.gzipSync('main'));
    const manifest = s.refreshSessionEvidence(f.directory, 1);
    assert.equal(manifest.integrityState, 'partial'); assert.equal(manifest.droppedEvents, 7);
    assert.equal(manifest.files.find(file => file.path.includes('launcher-host')).state, 'partial');
    assert.equal(manifest.files.find(file => file.path.endsWith('.gz')).role, 'minecraft-main');
    s.setEvidenceSelection(f.directory, 1, [manifest.files[0].fileId]);
    f.write('logs/ledger/1/game/logs/latest.log', 'new content');
    const updated = s.refreshSessionEvidence(f.directory, 1);
    assert.equal(s.evidenceSelectionOf(f.directory, 1).revision, updated.revision);
    f.control.failWrite = name => name.includes('evidence-selection');
    assert.throws(() => s.setEvidenceSelection(f.directory, 1, []), /保存失败/);
  } finally { f.close(); }
});

test('frozen snapshot rejects lost files and same-size rewrites and does not adopt a changed selection', async () => {
  const f = evidenceRuntime();
  try {
    const s = f.load(common('SessionEvidence')), x = f.load(common('EvidenceExportSnapshot'));
    const path = f.write('logs/ledger/2/game/logs/latest.log', 'A'.repeat(100000));
    f.write('logs/ledger/2/render/renderer.log', 'OPTIONAL_RENDER');
    const selection = s.evidenceSelectionOf(f.directory, 2);
    let changed = false;
    f.control.afterRead = () => { if (!changed) { changed = true; fs.writeFileSync(path, 'B'.repeat(100000)); } };
    await assert.rejects(() => x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, selection, ''), /改写/);
    f.control.afterRead = undefined;
    const all = s.listSessionEvidence(f.directory, 2);
    const fresh = s.evidenceSelectionOf(f.directory, 2);
    f.control.afterRead = () => { fresh.selectedFileIds.push(all.find(file => file.path.includes('renderer')).fileId); };
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, fresh, '');
    assert(!snapshot.files.some(file => file.role === 'renderer'));
    x.disposeEvidenceExportSnapshot(snapshot);
    fs.unlinkSync(path);
    await assert.rejects(() => x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, selection, ''), /消失/);
  } finally { f.close(); }
});

test('gzip exact boundary, Unicode chunk boundaries and streaming export beyond old 16 MiB cap', async () => {
  const f = evidenceRuntime();
  try {
    const io = f.load(common('EvidenceIo'));
    const plain = 'a'.repeat(65535) + '中文😀\n';
    const path = f.write('unicode.log', plain);
    assert.equal((await io.readEvidenceTextBounded(path, false, Buffer.byteLength(plain))).text, plain);
    const exact = f.write('exact.gz', zlib.gzipSync('x'.repeat(16 * 1024 * 1024)));
    assert.equal((await io.readEvidenceTextBounded(exact, true, 16 * 1024 * 1024)).eof, true);
    const s = f.load(common('SessionEvidence')), x = f.load(common('EvidenceExportSnapshot'));
    f.write('logs/ledger/3/game/logs/2026-09-17-1.log.gz', zlib.gzipSync('line\n'.repeat(3600000)));
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, s.evidenceSelectionOf(f.directory, 3), '');
    assert.equal(snapshot.files[0].bytes, 18000000);
    assert.match(snapshot.files[0].name, /decompressed\.log$/);
    x.disposeEvidenceExportSnapshot(snapshot);
  } finally { f.close(); }
});

test('source checkpoints capture early crashes without stdout and update nonempty files', () => {
  const f = evidenceRuntime();
  try {
    const c = f.load(common('SessionCapture'));
    const id = Date.now() - 2000;
    fs.mkdirSync(`${f.directory}/logs/ledger/${id}`, { recursive: true });
    c.beginSessionCapture(f.directory, id, f.directory + '/minecraft', '', '');
    f.write('minecraft/logs/latest.log', 'early failure');
    f.write('jvm_stderr.log', 'JNI failed');
    c.checkpointSessionCapture(f.directory, id, 0, 0);
    assert.equal(fs.readFileSync(`${f.directory}/logs/ledger/${id}/jvm/jvm-stderr.log`, 'utf8'), 'JNI failed');
    f.write('minecraft/logs/latest.log', 'early failure\ncheckpoint two');
    c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
    const saved = `${f.directory}/logs/ledger/${id}/game/logs/latest.log`;
    assert.match(fs.readFileSync(saved, 'utf8'), /checkpoint two/);
    f.write('minecraft/logs/latest.log', 'NEXT SESSION');
    c.checkpointSessionCapture(f.directory, id, Date.now(), Date.now() - 1);
    assert.doesNotMatch(fs.readFileSync(saved, 'utf8'), /NEXT SESSION/);
  } finally { f.close(); }
});

test('redaction preserves SHA-256 and labels while masking short contextual secrets', () => {
  const f = evidenceRuntime();
  try {
    const r = f.load(common('Redact'));
    const hash = '0123456789abcdef'.repeat(4);
    assert.equal(r.redactToken('sha256=' + hash), 'sha256=' + hash);
    assert.doesNotMatch(r.redactToken('password=pwd123 token=abc'), /pwd123|token=abc/);
    assert.doesNotMatch(r.redactToken('password="my tiny secret" Authorization: Bearer abc'), /my tiny secret|Bearer abc/);
    assert.doesNotMatch(r.redactToken('Authorization: Basic dTpw'), /dTpw/);
    const once = r.redactToken('Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234567890');
    assert.match(once, /^Authorization: Bearer /); assert.equal(r.redactToken(once), once);
  } finally { f.close(); }
});

// 执行真实 ArkTS 脱敏模块，覆盖曾使上传回归溢出匹配栈的 6 MiB 连续字段。
// 同时检查大技术摘要不被截断、真实 token 仍被遮蔽，避免用跳过脱敏换取通过。
test('large opaque fields redact without stack overflow while hexadecimal diagnostics remain intact', () => {
  const f = evidenceRuntime();
  try {
    const r = f.load(common('Redact'));
    const hex = 'a'.repeat(6 * 1024 * 1024);
    assert.equal(r.redactToken('sha256=' + hex), 'sha256=' + hex);
    const token = 'G'.repeat(6 * 1024 * 1024) + '==';
    const expected = `begin\nGGGGGG***[${token.length}chars]***GGGG==\nend`;
    const actual = r.redactToken('begin\n' + token + '\nend');
    assert.equal(actual, expected);
    assert.equal(r.redactToken(actual), actual, 'a second export must preserve the existing mask');
    // 明确的凭据上下文优先于长十六进制摘要豁免。
    const contextual = r.redactToken('password=' + hex);
    assert.equal(contextual, `password=aaaaaa***[${hex.length}chars]***aaaaaa`);
  } finally { f.close(); }
});

// 钉住原规则的主体门槛、至多两个 padding 以及中文/URL/换行边界。
test('opaque token scanning preserves threshold, padding and surrounding text', () => {
  const f = evidenceRuntime();
  try {
    const r = f.load(common('Redact'));
    const short = 'Z'.repeat(39) + '==';
    assert.equal(r.redactToken(short), short);
    const body = 'Z'.repeat(40);
    assert.equal(r.redactToken(body), 'ZZZZZZ***[40chars]***ZZZZZZ');
    assert.equal(r.redactToken(body + '==='), 'ZZZZZZ***[42chars]***ZZZZ===');
    const bounded = '中/' + body + '.尾\n' + short;
    assert.equal(r.redactToken(bounded), '中/ZZZZZZ***[40chars]***ZZZZZZ.尾\n' + short);
    assert.equal(r.redactToken('a'.repeat(40) + '='), 'aaaaaa***[41chars]***aaaaa=');
  } finally { f.close(); }
});

test('explicit excerpts allocate budgets per file, preserve crash reports and leave the full snapshot intact', async () => {
  const f = evidenceRuntime();
  try {
    const s = f.load(common('SessionEvidence')), x = f.load(common('EvidenceExportSnapshot'));
    const excerpts = f.load(common('EvidenceExcerpt'));
    f.write('logs/ledger/9/game/logs/latest.log', 'START_MARKER\n' + 'large game line\n'.repeat(60000) + 'END_MARKER\n');
    f.write('logs/ledger/9/crash-reports/crash-report.txt', 'SMALL_CRASH_ROOT_CAUSE\n');
    const selection = s.evidenceSelectionOf(f.directory, 9);
    selection.selectedFileIds = s.listSessionEvidence(f.directory, 9).filter(file => file.bytes > 0).map(file => file.fileId);
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, selection, '');
    const excerpt = await excerpts.createEvidenceExcerptSnapshot(snapshot, 65536, 1000);
    const files = await x.snapshotShareFiles(excerpt, 65536, 1000);
    assert(files.some(file => file.content.includes('SMALL_CRASH_ROOT_CAUSE')));
    const main = files.find(file => file.name === 'game/logs/latest.log');
    assert.match(main.content, /START_MARKER/); assert.match(main.content, /END_MARKER/); assert.match(main.content, /中间内容省略/);
    assert.equal(fs.readFileSync(snapshot.files.find(file => file.role === 'minecraft-main').path, 'utf8').split('\n').length, 60003);
    assert.notEqual(excerpt.digest, snapshot.digest);
    x.disposeEvidenceExportSnapshot(snapshot); x.disposeEvidenceExportSnapshot(excerpt);
  } finally { f.close(); }
});

test('LogShare uses dynamic limits, gzip, matching id and never reposts unknown outcomes', async () => {
  const f = evidenceRuntime();
  try {
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    const result = await client.submitLogFiles([{ name: 'game/logs/latest.log', content: 'message\n'.repeat(60000) }], 'amcl-launcher');
    assert.equal(result.ok, true); assert.equal(result.remoteFilesVerified, true);
    assert.equal(f.control.requests.find(r => r.options.method === 'POST').options.header['Content-Encoding'], 'gzip');
    f.control.urlId = 'sWrong1';
    assert.equal((await client.submitLogFiles([{ name: 'a.log', content: 'x' }], 'amcl-launcher')).ok, false);
    f.control.networkError = true;
    const before = f.control.requests.filter(r => r.options.method === 'POST').length;
    await client.submitLogFiles([{ name: 'a.log', content: 'x' }], 'amcl-launcher');
    assert.equal(f.control.requests.filter(r => r.options.method === 'POST').length - before, 1);
  } finally { f.close(); }
});

test('share credential persistence failure retries storage, not POST; records survive ledger deletion', async () => {
  const f = evidenceRuntime();
  try {
    const s = f.load(common('SessionEvidence')), x = f.load(common('EvidenceExportSnapshot'));
    const service = f.load('entry/src/main/ets/components/EvidenceShareService.ets');
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    f.write('logs/ledger/4/game/logs/latest.log', 'synthetic latest');
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, s.evidenceSelectionOf(f.directory, 4), '');
    const meta = { launcher: 'AMCL', appVersion: 'synthetic', mcVersion: 'test', loader: '', jdk: '', device: '', osVersion: '', outcome: '' };
    f.control.failWrite = name => name.includes('share-records');
    await assert.rejects(() => service.shareEvidenceSnapshot(f.context, snapshot, meta), /保存失败/);
    f.control.failWrite = undefined;
    const record = await service.shareEvidenceSnapshot(f.context, snapshot, meta);
    assert.equal(record.id, 'sAbCdEf');
    assert.equal(f.control.requests.filter(r => r.options.method === 'POST').length, 1);
    fs.rmSync(f.directory + '/logs/ledger/4', { recursive: true });
    assert.equal((await client.loadShareRecords(f.context)).length, 1);
    assert.equal(client.isShareRecordCurrent({ ...record, sharedAt: 1 }), false);
  } finally { f.close(); }
});


test('DFX event type and external_log array are parsed, future sessions and explicit success are protected', () => {
  const f = evidenceRuntime();
  try {
    const l = f.load(common('ActivityLedger')), s = f.load(common('SessionEvidence'));
    l.ledgerBegin(f.directory, 1000, { category: 'launch', title: 'previous' });
    l.ledgerBegin(f.directory, 9000, { category: 'launch', title: 'future' });
    const old = l.ledgerManifest(f.directory, 1000);
    old.endedAt = 8000; old.state = 1; old.outcomeSource = 'game.explicit-exit';
    f.write('logs/ledger/1000/manifest.json', JSON.stringify(old));
    const external = f.write('system/external.log', 'REAL_SYSTEM_CRASH');
    // OHOS 外部路径为 POSIX 绝对路径；Windows 宿主只在文件边界映射到合成文件。
    const originalStat = f.kitFs.statSync;
    f.kitFs.statSync = value => originalStat(value === '/system-test/external.log' ? external : value);
    f.kitFs.copyFileSync = (from, to) => fs.copyFileSync(from === '/system-test/external.log' ? external : from, to);
    f.write('logs/platform-events/event-9900-1.json', JSON.stringify({ name: 'APP_CRASH', eventAt: 7000, params: { pid: 101, external_log: ['/system-test/external.log'] } }));
    l.archivePlatformEventFiles_(f.directory);
    assert.equal(l.ledgerManifest(f.directory, 1000).state, 1);
    assert.equal(l.ledgerManifest(f.directory, 9000).state, 0);
    const reports = s.listSessionEvidence(f.directory, 1000).filter(file => file.role === 'system-crash');
    assert.equal(reports.length, 2); assert(reports.every(file => file.defaultSelected));
    assert(reports.some(file => fs.readFileSync(file.localPath, 'utf8') === 'REAL_SYSTEM_CRASH'));
  } finally { f.close(); }
});

test('startup gzip from prior latest is excluded; same-session slices become eligible', async () => {
  const f = evidenceRuntime();
  try {
    const c = f.load(common('SessionCapture')), s = f.load(common('SessionEvidence'));
    const id = Date.now() - 2000;
    fs.mkdirSync(`${f.directory}/logs/ledger/${id}`, { recursive: true });
    f.write('minecraft/logs/latest.log', 'PREVIOUS_SESSION');
    c.beginSessionCapture(f.directory, id, f.directory + '/minecraft', '', '');
    f.write('minecraft/logs/latest.log', 'CURRENT_SESSION');
    f.write('minecraft/logs/2026-09-18-1.log.gz', zlib.gzipSync('PREVIOUS_SESSION'));
    f.write('minecraft/logs/2026-09-18-2.log.gz', zlib.gzipSync('CURRENT_ROTATION'));
    c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
    await c.verifySessionCaptureRotations(f.directory, id);
    const files = s.listSessionEvidence(f.directory, id);
    const previous = files.find(file => file.path.endsWith('-1.log.gz'));
    const current = files.find(file => file.path.endsWith('-2.log.gz'));
    assert.equal(previous.attribution, 'previous-session'); assert.equal(previous.defaultSelected, false);
    assert.equal(current.attribution, 'source-baseline'); assert.equal(current.defaultSelected, true);
  } finally { f.close(); }
});

test('paged reader searches whole logical Unicode lines, retains bounded rows and cancels stale reads', async () => {
  const f = evidenceRuntime();
  try {
    const Model = f.load('entry/src/main/ets/components/ActivityLogModel.ets').ActivityLogModel;
    const model = new Model();
    const a = f.write('a.log', Array.from({ length: 905 }, (_, index) => `[INFO] 中文行${index}\n`).join(''));
    const b = f.write('b.log', '[ERROR] B_ONLY\n');
    await model.loadEvidence([{ path: a, compressed: false }], 0, '', 300);
    assert.equal(model.matchingLines, 300); assert.equal(model.getData(0).lineNumber, 301); assert.equal(model.hasNextPage, true);
    await model.loadEvidence([{ path: a, compressed: false }], 0, '中文行904');
    assert.equal(model.totalCount(), 1); assert.equal(model.getData(0).lineNumber, 905);
    let changed = false;
    f.control.afterRead = async () => { if (!changed) { changed = true; await model.loadEvidence([{ path: b, compressed: false }], 0, ''); } };
    assert.equal(await model.loadEvidence([{ path: a, compressed: false }], 0, ''), false);
    assert.match(model.getData(0).text, /B_ONLY/);
  } finally { f.close(); }
});

test('full session outcome resolves evidence beyond preview tails without overwriting explicit outcome', async () => {
  const f = evidenceRuntime();
  try {
    const l = f.load(common('ActivityLedger'));
    const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
    const id = Date.now() - 2000;
    l.ledgerBegin(f.directory, id, { category: 'launch', title: 'outcome', gameDir: f.directory + '/minecraft' });
    f.write('minecraft/logs/latest.log', '---- Minecraft Crash Report ----\n' + 'normal line\n'.repeat(18000));
    const capture = f.load(common('SessionCapture'));
    capture.checkpointSessionCapture(f.directory, id, Date.now(), 0);
    const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
    assert.equal(result.state, l.LedgerState.CRASHED);
    const saved = l.ledgerManifest(f.directory, id); saved.state = 1; saved.outcomeSource = 'game.explicit-exit';
    f.write('logs/ledger/' + id + '/manifest.json', JSON.stringify(saved));
    assert.equal((await resolver.resolveRecoveredSessionOutcome(f.directory, id)).state, 1);
  } finally { f.close(); }
});


test('legacy unowned crash files cannot turn a restored session into a fresh crash', async () => {
  const f = evidenceRuntime();
  try {
    const l = f.load(common('ActivityLedger'));
    const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
    l.ledgerBegin(f.directory, 55, { category: 'launch', title: 'legacy' });
    f.write('logs/ledger/55/crash-reports/crash-2026-09-02_03.30.00-client.txt', 'old crash report');
    const result = await resolver.resolveRecoveredSessionOutcome(f.directory, 55);
    assert.equal(result.state, l.LedgerState.INTERRUPTED);
  } finally { f.close(); }
});

test('unchanged old crash baseline remains not-produced and cannot override a normal current exit', async () => {
  const f = evidenceRuntime();
  try {
    const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
    const s = f.load(common('SessionEvidence'));
    const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
    const id = Date.now() - 2000;
    const old = f.write('minecraft/crash-reports/crash-2026-09-18_12.22.19-client.txt', 'YESTERDAY_REAL_CRASH\n');
    const yesterday = new Date(Date.now() - 86400000);
    fs.utimesSync(old, yesterday, yesterday);
    const before = fs.statSync(old).mtimeMs;
    l.ledgerBegin(f.directory, id, { category: 'launch', title: 'normal after old crash', gameDir: f.directory + '/minecraft' });
    f.write('minecraft/logs/latest.log', '[INFO] Current menu\n[INFO] Stopping!\n');
    c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
    const report = s.listSessionEvidence(f.directory, id).find(file => file.role === 'crash-report');
    assert.equal(report.attribution, 'source-baseline');
    assert.equal(report.state, 'not-produced');
    assert.equal(report.bytes, 0);
    assert.equal(fs.existsSync(report.localPath), false);
    const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
    assert.equal(result.state, l.LedgerState.SUCCESS);
    assert.doesNotMatch(result.summary, /崩溃报告/);
    assert.equal(l.ledgerManifest(f.directory, id).state, l.LedgerState.SUCCESS);
    assert.equal(fs.readFileSync(old, 'utf8'), 'YESTERDAY_REAL_CRASH\n');
    assert.equal(fs.statSync(old).mtimeMs, before, '不得删除、改写或touch用户旧报告');
  } finally { f.close(); }
});

test('real current Minecraft and JVM fatal reports still override Stopping when body is readable', async () => {
  for (const reportPath of ['crash-reports/crash-current-client.txt', 'hs_err_pid101.log']) {
    const f = evidenceRuntime();
    try {
      const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      const id = Date.now() - 2000;
      l.ledgerBegin(f.directory, id, { category: 'launch', title: 'real failure', gameDir: f.directory + '/minecraft' });
      f.write('minecraft/logs/latest.log', '[INFO] Stopping!\n');
      f.write('minecraft/' + reportPath, 'A REAL CURRENT CRASH BODY\n');
      c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
      const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
      assert.equal(result.state, l.LedgerState.CRASHED);
      assert.match(result.summary, /本次启动产生了崩溃报告/);
    } finally { f.close(); }
  }
});

test('empty latest placeholder cannot take priority over exact captured stdio', async () => {
  const f = evidenceRuntime();
  try {
    const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
    const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
    const id = Date.now() - 2000;
    l.ledgerBegin(f.directory, id, { category: 'launch', title: 'stdio-only', gameDir: f.directory + '/minecraft' });
    f.write('logs/ledger/' + id + '/game/mc_output.log', '[INFO] Stopping!\n');
    // 明确 scope 的 stdio 独立于未生成的 latest；清单仍使用真实生产合并逻辑。
    const plan = c.readSessionCapture(f.directory, id);
    plan.sources.push({ source: '/native-session-stdio', destination: 'game/mc_output.log', baseline: '',
      captured: 'native-scope', state: 'complete', reason: '', attribution: 'exact', sealed: true,
      capturedBytes: Buffer.byteLength('[INFO] Stopping!\n'),
      capturedSha256: f.load(common('EvidenceIo')).evidenceTextDigest('[INFO] Stopping!\n') });
    f.write('logs/ledger/' + id + '/capture-sources.json', JSON.stringify(plan));
    const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
    assert.equal(result.state, l.LedgerState.SUCCESS);
  } finally { f.close(); }
});

test('report metadata without readable body cannot invent a crash or guarantee success', async () => {
  for (const failure of ['removed', 'empty', 'whitespace', 'unreadable', 'state-unavailable',
    'state-missing', 'state-cleaned', 'state-unreadable', 'state-permission-denied']) {
    const f = evidenceRuntime();
    try {
      const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
      const s = f.load(common('SessionEvidence'));
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      const id = Date.now() - 2000;
      l.ledgerBegin(f.directory, id, { category: 'launch', title: failure, gameDir: f.directory + '/minecraft' });
      f.write('minecraft/logs/latest.log', '[INFO] Stopping!\n');
      f.write('minecraft/crash-reports/crash-current-client.txt', 'CURRENT_CRASH\n');
      c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
      const report = s.listSessionEvidence(f.directory, id).find(file => file.role === 'crash-report');
      if (failure === 'removed') fs.unlinkSync(report.localPath);
      if (failure === 'empty') fs.writeFileSync(report.localPath, '');
      if (failure === 'whitespace') fs.writeFileSync(report.localPath, ' \n\t');
      if (failure === 'unreadable') f.control.failWrite = (path, mode) => path === report.localPath && mode === 0;
      if (failure.startsWith('state-')) {
        const plan = c.readSessionCapture(f.directory, id);
        plan.sources.find(item => item.destination.startsWith('crash-reports/')).state = failure.slice(6);
        f.write('logs/ledger/' + id + '/capture-sources.json', JSON.stringify(plan));
      }
      const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
      assert.equal(result.state, l.LedgerState.INTERRUPTED, failure);
      assert.match(result.summary, /报告正文不可读/);
    } finally { f.close(); }
  }
});

test('state and attribution independently exclude false evidence even with nonempty files', async () => {
  for (const state of ['not-produced', 'missing', 'not-applicable', 'unavailable', 'cleaned', 'future-state']) {
    const f = evidenceRuntime();
    try {
      const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      const id = Date.now() - 2000;
      l.ledgerBegin(f.directory, id, { category: 'launch', title: state, gameDir: f.directory + '/minecraft' });
      f.write('minecraft/logs/latest.log', '[INFO] Stopping!\n');
      c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
      const plan = c.readSessionCapture(f.directory, id);
      plan.sources.find(item => item.destination === 'game/logs/latest.log').state = state;
      f.write('logs/ledger/' + id + '/capture-sources.json', JSON.stringify(plan));
      assert.equal((await resolver.resolveRecoveredSessionOutcome(f.directory, id)).state, l.LedgerState.INTERRUPTED);
    } finally { f.close(); }
  }
  for (const attribution of ['previous-session', 'ambiguous', 'unknown']) {
    const f = evidenceRuntime();
    try {
      const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      const id = Date.now() - 2000;
      l.ledgerBegin(f.directory, id, { category: 'launch', title: attribution, gameDir: f.directory + '/minecraft' });
      f.write('minecraft/crash-reports/crash-current-client.txt', 'UNOWNED_CRASH\n');
      c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
      const plan = c.readSessionCapture(f.directory, id);
      plan.sources.find(item => item.destination.startsWith('crash-reports/')).attribution = attribution;
      f.write('logs/ledger/' + id + '/capture-sources.json', JSON.stringify(plan));
      assert.equal((await resolver.resolveRecoveredSessionOutcome(f.directory, id)).state, l.LedgerState.INTERRUPTED);
    } finally { f.close(); }
  }
});

test('read failure or incomplete capture after a stop marker cannot claim complete normal exit', async () => {
  for (const failure of ['read-error', 'partial', 'writing']) {
    const f = evidenceRuntime();
    try {
      const l = f.load(common('ActivityLedger')), c = f.load(common('SessionCapture'));
      const resolver = f.load('launch/src/main/ets/SessionOutcomeResolver.ets');
      const id = Date.now() - 2000;
      l.ledgerBegin(f.directory, id, { category: 'launch', title: failure, gameDir: f.directory + '/minecraft' });
      f.write('minecraft/logs/latest.log', '[INFO] Stopping!\n' + 'padding\n'.repeat(20000));
      c.checkpointSessionCapture(f.directory, id, Date.now() + 1000, 0);
      if (failure === 'read-error') {
        let reads = 0;
        f.control.afterRead = () => { if (++reads === 2) throw new Error('synthetic read failure after Stopping'); };
      } else {
        const plan = c.readSessionCapture(f.directory, id);
        plan.sources.find(item => item.destination === 'game/logs/latest.log').state = failure;
        f.write('logs/ledger/' + id + '/capture-sources.json', JSON.stringify(plan));
      }
      const result = await resolver.resolveRecoveredSessionOutcome(f.directory, id);
      assert.equal(result.state, l.LedgerState.INTERRUPTED, failure);
    } finally { f.close(); }
  }
});

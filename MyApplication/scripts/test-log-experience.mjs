/** 日志体验回归：执行生产 ETS，替换系统边界；不发送网络、不修改真实用户数据。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import ts from './lib/ets-compiler.mjs';

// Native writer 使用 UTC 消除隐式 TZ 读取；读取器必须同时保留新旧日志事件和各自原始时间。
test('UTC native timestamps and legacy local timestamps keep separate complete events', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const file = f.write('utc.log', '[2026-09-22T12:00:00Z][E][JVM] first\n  continuation\n'
      + '[2026-09-22 20:00:01][I][JVM] legacy\n');
    const model = new ActivityLogModel();
    await model.loadEvidence([{ path: file, compressed: false }], 0, '');
    assert.equal(model.matchingEvents, 2);
    assert.equal(model.getData(0).event.timestamp, '2026-09-22T12:00:00Z');
    assert.equal(model.getData(1).event.startLine, 1);
    assert.equal(model.getData(2).event.timestamp, '2026-09-22 20:00:01');
  } finally { f.close(); }
});

test('official XML severity and complete multiline error events survive filtering and search', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const { hasErrorSignal } = f.load('commons/src/main/ets/utils/LogErrorSignal.ets');
    const xml = '<log4j:Event logger="example" timestamp="1" level="ERROR" thread="main">\n'
      + '<log4j:Message><![CDATA[Unable to initialize graphics]]></log4j:Message>\n</log4j:Event>\n';
    const fabric = '[12:00:00] [main/ERROR]: Incompatible mods found!\n'
      + 'A potential solution has been determined:\n  - Install example-api 2.0 or later.\n'
      + 'java.lang.IllegalStateException: missing dependency\n\tat example.Loader.load(Loader.java:1)\n'
      + '[12:00:01] [main/INFO]: unrelated next event\n';
    const file = f.write('events.log', xml + fabric);
    const model = new ActivityLogModel();
    await model.loadEvidence([{ path: file, compressed: false }], 2, '');
    const rows = () => Array.from({ length: model.totalCount() }, (_, index) => model.getData(index));
    assert.equal(model.matchingEvents, 2);
    assert.equal(model.matchingLines, 8);
    assert(rows().some(row => row.text.includes('Install example-api')));
    assert.equal(rows()[0].event.title, 'Unable to initialize graphics');
    assert.equal(hasErrorSignal(xml), true);
    await model.loadEvidence([{ path: file, compressed: false }], 0, 'Incompatible mods');
    assert.equal(model.matchingEvents, 1);
    assert(rows().some(row => row.text.includes('Loader.java')));
    assert(!rows().some(row => row.text.includes('unrelated')));
    assert.deepEqual(rows().map(row => row.sourceLineNumber), [4, 5, 6, 7, 8]);
    model.setCollapsed(true); assert.equal(model.totalCount(), 1);
    model.toggleEvent(model.getData(0).eventId); assert.equal(model.totalCount(), 5);
  } finally { f.close(); }
});

test('warning stacks inherit warning and incomplete XML stays visible with its source boundary', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const first = f.write('warn.log', '[12:00:00] [main/WARN]: Optional probe\njava.lang.Exception: optional\n\tat example.Probe.run(Probe.java:1)\n');
    const second = f.write('xml.log', '<log4j:Event level="ERROR" thread="main">\n<log4j:Message><![CDATA[incomplete');
    const model = new ActivityLogModel();
    await model.loadEvidence([{ path: first, compressed: false }], 2, '');
    assert.equal(model.totalCount(), 0);
    await model.loadEvidence([{ path: first, compressed: false }, { path: second, compressed: false }], 1, '');
    assert.equal(model.matchingEvents, 2);
    assert.equal(model.getData(0).event.level, 1);
    assert.equal(model.getData(3).sourceLineNumber, 1);
    assert.equal(model.getData(3).event.incomplete, true);
  } finally { f.close(); }
});

test('300-event pages never split a stack and keep gzip sequential state', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const text = Array.from({ length: 605 }, (_, index) => '[12:00:00] [main/ERROR]: event ' + index + '\n\tat example.X.run(X.java:1)\n').join('');
    const file = f.write('events.log.gz', zlib.gzipSync(text));
    const model = new ActivityLogModel();
    for (let page = 0; page < 3; page++) {
      await model.loadEvidence([{ path: file, compressed: true }], 2, '', page * 300);
      assert.equal(model.matchingEvents, page < 2 ? 300 : 5);
      assert.equal(model.matchingLines, page < 2 ? 600 : 10);
      assert.equal(model.getData(0).sourceLineNumber, page * 600 + 1);
      assert.equal(model.hasNextPage, page < 2);
    }
  } finally { f.close(); }
});

/** 缓存只在宿主内存中，失败注入不访问真实 Preferences。 */
function historyFixture(state) {
  return evidenceRuntime({ imports: {
    './DownloadManager': { formatBytes: String }, './DownloadTask': {},
    '@kit.ArkData': { preferences: { async getPreferences() {
      state.reads++;
      if (state.readFailure) { state.readFailure = false; throw new Error('synthetic unavailable'); }
      return { get: async () => state.saved ?? '[]', put: async (_key, value) => {
        if (state.writeFailure) throw new Error('synthetic full disk'); state.pending = value;
      }, flush: async () => { state.saved = state.pending; } };
    } } },
  } });
}
const activity = startedAt => ({ category: 'download', status: 'failed', startedAt, versionName: 'synthetic',
  gameVersion: 'synthetic', loaderType: 'vanilla', durationMs: 1, totalBytes: 0, fileCount: 0 });

test('history read failure rejects and retries; writes publish only after durable serial completion', async () => {
  const state = { reads: 0, readFailure: true, writeFailure: false };
  const f = historyFixture(state);
  try {
    const { DownloadHistoryStore } = f.load('feature_core/src/main/ets/download/DownloadHistory.ets');
    const store = new DownloadHistoryStore();
    await assert.rejects(store.init(f.context), /读取失败/); assert.equal(store.isReady(), false);
    await store.init(f.context); assert.equal(state.reads, 2); assert.equal(store.isReady(), true);
    state.writeFailure = true;
    await assert.rejects(store.add(activity(1)), /保存失败/); assert.equal(store.list().length, 0);
    state.writeFailure = false;
    await Promise.all([store.add(activity(2)), store.add(activity(3))]);
    assert.deepEqual(store.list().map(item => item.startedAt), [3, 2]);
    assert.deepEqual(JSON.parse(state.saved).map(item => item.startedAt), [3, 2]);
    state.writeFailure = true;
    await assert.rejects(store.markUploaded(2, 'synthetic'), /保存失败/);
    assert.equal(store.findByStartedAt(2).uploadedLogId, undefined);
    await assert.rejects(store.clear(), /保存失败/); assert.equal(store.list().length, 2);
    state.writeFailure = false;
    const mutable = activity(4); const queued = store.add(mutable); mutable.versionName = 'changed after enqueue';
    await queued; assert.equal(store.findByStartedAt(4).versionName, 'synthetic', '排队中的保存必须冻结调用时记录');
  } finally { f.close(); }
});

test('evidence presentation separates unsealed uncertainty and known loss; templates are explicit', () => {
  const f = evidenceRuntime();
  try {
    const types = f.load('commons/src/main/ets/utils/EvidenceTypes.ets');
    const view = f.load('commons/src/main/ets/utils/EvidencePresentation.ets');
    const make = (fileId, role, bytes = 10, state = 'complete') => ({ fileId, role, path: fileId,
      bytes, state, uploadPolicy: 'optional', attribution: 'exact', reason: '' });
    const main = make('game/logs/latest.log', types.EvidenceRole.MINECRAFT_MAIN);
    const agent = make('agent/probe.log', types.EvidenceRole.AGENT, 0, 'not-produced');
    const render = make('render/renderer.log', types.EvidenceRole.RENDERER);
    assert.equal(view.sortEvidenceForView([agent, render, main])[0], main);
    assert.equal(view.recommendedEvidenceFile([agent, render, main]), main);
    assert.match(view.evidenceCaptureLabel({ ...main, state: 'partial', reason: '没有有序关闭证明' }, false), /待确认/);
    assert.match(view.evidenceCaptureLabel({ ...main, state: 'partial', reason: '文件长度与归档收据不符' }, false), /校验不符/);
    assert.equal(view.evidenceCaptureLabel({ ...main, state: 'writing' }, false), '退出前未封账');
    assert.deepEqual(view.evidenceScenarioSelection([agent, render, main], view.EvidenceScenario.RECOMMENDED), [main.fileId]);
    assert.deepEqual(view.evidenceScenarioSelection([agent, render, main], view.EvidenceScenario.GRAPHICS), [main.fileId, render.fileId]);
  } finally { f.close(); }
});

test('live reader only consumes appended bytes, preserves split UTF-8 and rejects replacement', async () => {
  const f = evidenceRuntime();
  try {
    const { ActivityLogModel } = f.load('entry/src/main/ets/components/ActivityLogModel.ets');
    const word = Buffer.from('中文');
    const prefix = Buffer.from('[12:00:00] [main/INFO]: ');
    const file = f.write('live.log', Buffer.concat([prefix, word.subarray(0, 1)]));
    const model = new ActivityLogModel(); const source = { path: file, compressed: false };
    await model.loadLive(source, 0, ''); const first = model.liveBytesRead;
    fs.appendFileSync(file, Buffer.concat([word.subarray(1), Buffer.from('\n[12:00:01] [main/ERROR]: failure\n  details\n')]));
    await model.loadLive(source, 0, '');
    const rows = Array.from({ length: model.totalCount() }, (_, index) => model.getData(index));
    assert(rows.some(row => row.text.includes('中文'))); assert(!rows.some(row => row.text.includes('�')));
    assert.equal(model.liveBytesRead, fs.statSync(file).size);
    assert(model.liveBytesRead > first); const read = model.liveBytesRead;
    await model.loadLive(source, 0, ''); assert.equal(model.liveBytesRead, read, '空闲轮询不能重复读取旧正文');
    assert.equal(model.matchingEvents, 2); assert.equal(model.getData(1).event.lines.length, 2);
    fs.writeFileSync(file, 'short');
    await assert.rejects(model.loadLive(source, 0, ''), /替换或截短/);
    model.cancel();
  } finally { f.close(); }
});

test('pinned activities survive retention and explicit clear; actual storage groups remain auditable', async () => {
  const f = evidenceRuntime();
  try {
    const ledger = f.load('commons/src/main/ets/utils/ActivityLedger.ets');
    const storage = f.load('commons/src/main/ets/utils/ActivityStorage.ets');
    for (let id = 1; id <= 7; id++) {
      ledger.ledgerBegin(f.directory, id, { category: 'launch', title: 'one version', gameVersionId: 'v1' });
      const manifest = ledger.ledgerManifest(f.directory, id); manifest.state = ledger.LedgerState.SUCCESS;
      f.write('logs/ledger/' + id + '/manifest.json', JSON.stringify(manifest));
      f.write('logs/ledger/' + id + '/game/logs/latest.log', 'body-' + id);
    }
    ledger.ledgerSetPinned(f.directory, 1, true);
    assert.deepEqual(ledger.ledgerRetentionVictims(f.directory, 5), [2]);
    assert.throws(() => ledger.ledgerRemove(f.directory, 1), /保留/);
    assert.match(ledger.ledgerClearBlockReason(f.directory), /保留/);
    const summary = await storage.readActivityStorage(f.directory, () => false);
    assert.equal(summary.groups.length, 1); assert.equal(summary.groups[0].items.length, 7);
    assert.equal(summary.bytes, ledger.ledgerTotalBytes(f.directory), '管理菜单与占用面板都包含内部清单');
    assert(summary.bytes > 42); assert.equal(summary.groups[0].items.find(item => item.activityId === 1).pinned, true);
    storage.setActivityStorageAlert(f.directory, 256 * 1024 * 1024);
    assert.equal(storage.activityStorageAlert(f.directory), 256 * 1024 * 1024);
    assert.equal(ledger.listActivityIds(f.directory).length, 7, '提醒阈值不执行删除');
  } finally { f.close(); }
});

test('diagnostic index scans full sources, links real stages and deduplicates repeated errors without changing outcome', async () => {
  const f = evidenceRuntime();
  try {
    const { buildActivityDiagnosis } = f.load('entry/src/main/ets/components/ActivityDiagnostics.ets');
    const body = '[12:00:00] [main/INFO]: Loading Minecraft 26.2\n'
      + '[12:00:01] [main/ERROR]: Incompatible mods found!\nA potential solution has been determined:\n - Install example API\n';
    const a = f.write('logs/ledger/7/game/logs/latest.log', body);
    const b = f.write('logs/ledger/7/game/mc_output.log', body);
    const manifest = { activityId: 7, state: 1, outcomeSummary: 'normal exit' };
    const make = (path, name, role) => ({ localPath: path, path: name, fileId: name,
      bytes: Buffer.byteLength(body), role, state: 'complete', attribution: 'exact' });
    const files = [make(a, 'game/logs/latest.log', 'minecraft-main'), make(b, 'game/mc_output.log', 'minecraft-output')];
    const result = await buildActivityDiagnosis(f.directory, manifest, files, () => false, () => {});
    assert.equal(result.complete, true); assert.equal(result.scannedCount, 2);
    assert.equal(result.findings.length, 1); assert.equal(result.findings[0].occurrences, 2);
    assert.equal(result.findings[0].line, 2); assert.equal(result.findings[0].endLine, 4);
    assert.equal(result.phases[0].key, 'loader'); assert.equal(manifest.state, 1);
    const cached = await buildActivityDiagnosis(f.directory, manifest, files, () => false, () => { throw new Error('cache unexpectedly rescanned'); });
    assert.equal(cached.signature, result.signature);
    assert(!f.load('commons/src/main/ets/utils/SessionEvidence.ets').listSessionEvidence(f.directory, 7)
      .some(file => file.path.includes('experience-index')), '派生诊断不得混进默认附件');
  } finally { f.close(); }
});

test('queue retries allocate a new activity with a parent while resume keeps the original identity', async () => {
  const terminal = state => ['done', 'error', 'aborted'].includes(state);
  const f = evidenceRuntime({ imports: { './UnifiedDownloadTask': {
    UnifiedTaskState: { WAITING: 'waiting', PREPARING: 'preparing', PAUSED: 'paused', DONE: 'done', ERROR: 'error', ABORTED: 'aborted' },
    TaskCategory: { MC_VERSION: 'mc' }, isTerminalState: terminal,
    isInProgressState: state => !terminal(state), aggregateProgress: () => 0,
  } } });
  try {
    const { DownloadTaskRegistry } = f.load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets');
    const registry = new DownloadTaskRegistry();
    const view = { id: 'task', title: 'synthetic', category: 'mc', startedAtMs: 0, state: 'waiting',
      parentActivityId: 0, activityRelation: '', canCancel: true, canRetry: false, canResume: false };
    const adapter = { view, purgeNativeOwner: () => true, dispose() {}, start: async () => {
      view.state = 'paused'; view.canResume = true;
    }, resume: async () => { view.state = 'error'; view.canRetry = true; }, retry: async () => { view.state = 'done'; } };
    await registry.enqueue(adapter); await new Promise(resolve => setImmediate(resolve)); const first = view.startedAtMs;
    await registry.resume(view.id); await new Promise(resolve => setImmediate(resolve)); assert.equal(view.startedAtMs, first);
    await registry.retry(view.id); assert(view.startedAtMs > first); assert.equal(view.parentActivityId, first);
    assert.equal(view.activityRelation, 'retry'); registry.purgeFinished();
  } finally { f.close(); }
});

test('legacy settings export waits for clipboard completion and only exports the explicitly named app snapshot', async () => {
  const file = path.resolve(import.meta.dirname, '../entry/src/main/ets/pages/Index.ets');
  const source = fs.readFileSync(file, 'utf8');
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'exportLogToClipboard'));
  const member = component.members.find(item => item.name?.getText(ast) === 'exportLogToClipboard');
  const compiled = ts.transpileModule('export class Page {\n' + member.getText(ast) + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const exports = {}; const notices = []; const outputs = []; let resolve, reject;
  const bindings = { AppLogger: { flush() {} }, testNapi: { amclLogRead: () => 'launcher only' },
    DiagnosticBundle: { buildEnvHeader: env => { assert.equal(env.mcVersion, undefined); return env.note; } },
    sanitizeLogForExport: value => value, LogExportTarget: { CLIPBOARD: 0 }, formatError: error => error.message,
    pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_type, text) => text, getSystemPasteboard: () => ({
      setData: text => { outputs.push(text); return new Promise((yes, no) => { resolve = yes; reject = no; }); },
    }) },
  };
  new Function(...Object.keys(bindings), 'exports', compiled)(...Object.values(bindings), exports);
  const page = new exports.Page(); Object.assign(page, { exportingAppLog: false, statusMsg: '', appVersionLabel: () => 'test',
    safeToast_: value => notices.push(value) });
  const first = page.exportLogToClipboard(); assert.equal(notices.length, 0);
  reject(new Error('denied')); await first; assert.match(notices[0], /复制失败/);
  const second = page.exportLogToClipboard(); assert.equal(notices.length, 1);
  resolve(); await second; assert.equal(notices[1], '应用诊断摘要已复制');
  assert(outputs.every(text => text.includes('当前应用诊断摘要') && text.includes('launcher only')));
});

test('local diagnosis folds registered compatibility noise but preserves fatal causes inside the same event', async () => {
  const f = evidenceRuntime();
  try {
    const { buildActivityDiagnosis } = f.load('entry/src/main/ets/components/ActivityDiagnostics.ets');
    const body = '[12:00:00] [main/ERROR]: Error while loading the narrator\n'
      + 'java.lang.UnsatisfiedLinkError: libflite\n\tat org.spongepowered.asm.mixin.example.Probe(Probe.java:1)\n'
      + '[12:00:01] [main/ERROR]: Failed to fetch Realms feature flags\noptional service unavailable\n'
      + '[12:00:02] [main/ERROR]: Error while loading the narrator\njava.lang.OutOfMemoryError: Java heap space\n';
    const local = f.write('logs/ledger/9/game/logs/latest.log', body);
    const files = [{ localPath: local, path: 'game/logs/latest.log', fileId: 'latest', bytes: Buffer.byteLength(body),
      role: 'minecraft-main', state: 'complete', attribution: 'exact' }];
    const manifest = { activityId: 9, state: 5, outcomeSummary: 'unconfirmed' };
    const result = await buildActivityDiagnosis(f.directory, manifest, files, () => false, () => {});
    assert.equal(result.ignoredEvents, 2); assert.equal(result.findings.length, 1);
    assert.match(result.findings[0].explanation, /内存不足/); assert.equal(result.findings[0].line, 6);
    const cache = JSON.parse(fs.readFileSync(f.directory + '/logs/ledger/9/experience-index.json', 'utf8'));
    cache.findings[0].title = 'corrupted cached explanation';
    f.write('logs/ledger/9/experience-index.json', JSON.stringify(cache));
    let scanned = 0;
    const repaired = await buildActivityDiagnosis(f.directory, manifest, files, () => false, () => { scanned++; });
    assert(scanned > 0); assert.notEqual(repaired.findings[0].title, 'corrupted cached explanation');
  } finally { f.close(); }
});

test('programmatic search clearing keeps the explicit context location and cancels an older debounce', () => {
  const file = path.resolve(import.meta.dirname, '../entry/src/main/ets/pages/ActivityLogPage.ets');
  const source = fs.readFileSync(file, 'utf8'); const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'search_'));
  const members = ['search_', 'resetReaderFilter_'].map(name => component.members.find(item => item.name?.getText(ast) === name).getText(ast)).join('\n');
  const compiled = ts.transpileModule('export class Page {\n' + members + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  let serial = 0, filters = 0; const pending = new Map(); const exports = {};
  new Function('exports', 'LevelFilter', 'setTimeout', 'clearTimeout', compiled)(exports, { ALL: 0 },
    callback => { pending.set(++serial, callback); return serial; }, id => pending.delete(id));
  const page = new exports.Page(); Object.assign(page, { keyword: '', searchTimer: -1, fromLine: 0,
    applyFilter_: () => { page.fromLine = 0; filters++; } });
  page.search_('narrator'); assert.equal(pending.size, 1);
  page.resetReaderFilter_(294); assert.equal(pending.size, 0);
  page.search_(''); assert.equal(pending.size, 0); assert.equal(page.fromLine, 294);
  page.search_('user query'); pending.get(page.searchTimer)(); assert.equal(filters, 1); assert.equal(page.fromLine, 0);
});

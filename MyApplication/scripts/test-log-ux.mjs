// 直接执行页面方法与生产存储/账本逻辑；仅替换 ArkUI、剪贴板和网络边界。
// 对照取消、异步拒绝、保存失败和读取保护，证明“未成功不能提前显示成功”。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import ts from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import { checkCriticalLogging, criticalFiles } from './check-critical-logging.mjs';
const root = path.resolve(import.meta.dirname, '..');
// 从 SDK AST 精确提取指定成员，方法体不改写；组件布局交由 ArkTS 编译与设备验证。
function page(file, names, bindings = {}) {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const declaration = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === names[0]));
  const members = names.map(name => {
    const node = declaration.members.find(member => member.name?.getText(ast) === name);
    assert(node, name); return node.getText(ast);
  }).join('\n');
  const output = ts.transpileModule('export class Page {\n' + members + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const exports = {};
  new Function(...Object.keys(bindings), 'exports', output)(...Object.values(bindings), exports);
  return new exports.Page();
}
const tick = () => new Promise(resolve => setImmediate(resolve));

// JVM 分类包含 stderr、fatal 和 GC；标签大小必须与正文实际选择的文件集合一致。
test('part labels and reader count the same JVM evidence files', async () => {
  const f = evidenceRuntime();
  try {
    const { LedgerPart } = f.load('commons/src/main/ets/utils/ActivityLedger.ets');
    const { EvidenceRole } = f.load('commons/src/main/ets/utils/EvidenceTypes.ets');
    const p = page('pages/ActivityLogPage.ets', ['partFiles_', 'partBytes_', 'loadPart_'], { LedgerPart, EvidenceRole });
    Object.assign(p, { readableFile_: file => file.bytes > 0, loadCurrentPage_: async () => {},
      evidenceFiles: [
        { role: EvidenceRole.JVM_STDERR, bytes: 100, localPath: '/stderr', path: 'jvm/stderr.log' },
        { role: EvidenceRole.JVM_FATAL, bytes: 200, localPath: '/fatal', path: 'jvm/hs_err.log' },
        { role: EvidenceRole.JVM_GC, bytes: 300, localPath: '/gc', path: 'jvm/gc.log' },
        { role: EvidenceRole.MINECRAFT_MAIN, bytes: 999, localPath: '/main', path: 'game/logs/latest.log' },
      ],
    });
    assert.equal(p.partBytes_(LedgerPart.JVM), 600);
    await p.loadPart_(LedgerPart.JVM);
    assert.equal(p.partBytes, 600);
    assert.deepEqual(p.readSources.map(source => source.path), ['/stderr', '/fatal', '/gc']);
  } finally { f.close(); }
});

// 滑块减少保留数量时先确认；确认期间新增淘汰项必须重新预览，不能静默扩大删除范围。
test('retention reduction cancels safely and rechecks the exact deletion scope before saving', async () => {
  let ids = [1, 2], choice = 0, writes = 0, changeDuringDialog = false;
  const p = page('components/LogRetentionSettings.ets', ['save'], {
    ledgerRetentionVictims: () => ids.slice(), ledgerBytesOf: () => 100, formatLogBytes: String,
    ledgerSetSessionRetention: () => { writes++; }, ledgerSessionRetention: () => 10,
  });
  Object.assign(p, { context: { filesDir: '/fixture' }, saving: false, theme: { primary: '#000', error: '#f00' },
    refresh() {}, getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => {
      if (changeDuringDialog) ids.push(3);
      return { index: choice };
    } }) }),
  });
  await p.save(5); assert.equal(writes, 0);
  choice = 1; changeDuringDialog = true;
  await p.save(5); assert.equal(writes, 0); assert.match(p.errorText, /已变化/);
  changeDuringDialog = false;
  await p.save(5); assert.equal(writes, 1); assert.equal(p.saving, false);
});

// 页面销毁不取消已经确认的上传；尚在生成的预览必须在异步完成后释放，避免临时副本泄漏。
test('leaving during preview generation releases the completed snapshot and does not prepare a service', async () => {
  let resolveSnapshot, disposed = 0, prepared = 0;
  const p = page('components/ActivityShareSheet.ets', ['prepare_', 'aboutToDisappear', 'release_'], {
    prepareActivityShare: () => new Promise(resolve => { resolveSnapshot = resolve; }),
    disposeEvidenceExportSnapshot: () => { disposed++; }, unsubscribeEvidenceShare() {},
    prepareLogShare: async () => { prepared++; },
  });
  Object.assign(p, { phase: 'select', alive: true, context: { filesDir: '/fixture', tempDir: '/fixture-temp' },
    activityId: 1, generation: 0, draft: { selectedFileIds: ['one'] },
    previewModel: { cancel() {} }, onBusyChanged() {},
    setPhase_(phase) { this.phase = phase; }, fail_(e) { throw e; },
  });
  const operation = p.prepare_(false);
  await tick(); p.aboutToDisappear();
  resolveSnapshot({ files: [{ name: 'latest.log' }], directory: '/synthetic' });
  await operation;
  assert.equal(disposed, 1); assert.equal(prepared, 0);
  assert.equal(p.snapshot, undefined); assert.equal(p.alive, false);
});

test('clipboard completion, rejection and success reflect the system result', async () => {
  let resolve, reject; const notices = [];
  const p = page('components/McErrorSheet.ets', ['copyText_'], {
    pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_, t) => t,
      getSystemPasteboard: () => ({ setData: () => new Promise((yes, no) => { resolve = yes; reject = no; }) }) },
  });
  p.toast_ = text => notices.push(text);
  const first = p.copyText_('link', 'copied'); assert.deepEqual(notices, []);
  reject(new Error('denied')); await first; assert.match(notices[0], /复制失败/);
  const next = p.copyText_('link', 'copied'); assert.equal(notices.length, 1);
  resolve(); await next; assert.equal(notices[1], 'copied');
});

test('local removal requires confirmation and rechecks running/read protection', async () => {
  let blocked = '', deletions = 0, choice = 0, backs = 0;
  const p = page('pages/ActivityLogPage.ets', ['canDelete_', 'requestRemoveLedger_', 'removeLedger_', 'close_'], {
    ledgerRemovalBlockReason: () => blocked, ledgerBytesOf: () => 42, formatLogBytes: () => '42 B',
    ledgerStateLabel: () => '成功', ledgerRemove: () => { deletions++; },
    hilog: { warn() {} }, TAG: 'test',
  });
  Object.assign(p, { context: { filesDir: '/fixture' }, activityId: 1, manifest: { title: 'session', state: 1 },
    loading: false, reading: false, sharing: false, copying: false, deleting: false, exportingEvidence: false,
    theme: {}, toast_() {}, getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => ({ index: choice }) }),
      getRouter: () => ({ back: () => { backs++; } }) }) });
  p.requestRemoveLedger_(); await tick(); assert.equal(deletions, 0);
  choice = 1; p.requestRemoveLedger_(); blocked = 'busy'; await tick(); assert.equal(deletions, 0);
  blocked = ''; p.reading = true; assert.equal(p.canDelete_(), false);
  p.reading = false; p.requestRemoveLedger_(); await tick(); assert.equal(deletions, 1); assert.equal(backs, 1);
});

test('revoke is single-flight, reports rejection and retains credentials for retry', async () => {
  let calls = 0, reject;
  const p = page('components/McErrorSheet.ets', ['lsRevoke'], {
    revokeShare: () => { calls++; return new Promise((_, no) => { reject = no; }); },
  });
  Object.assign(p, { uiCtx_: () => ({}), lsShareId: 'abcdef', lsShareUrl: 'link', lsShareToken: 'token', session: {},
    revoking: false, toast_() {} });
  p.lsRevoke(); p.lsRevoke(); assert.equal(calls, 1); assert.equal(p.revoking, true);
  reject(new Error('disk failure')); await tick();
  assert.equal(p.revoking, false); assert.equal(p.lsShareToken, 'token'); assert.match(p.lsError, /disk failure/);
});

test('message storage load retries and failed writes do not publish a false empty/read state', async () => {
  let failRead = true, failWrite = false, data = '';
  const f = evidenceRuntime({ imports: { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async () => { if (failRead) throw new Error('read failed'); return data; },
    put: async (_, next) => { data = next; }, flush: async () => { if (failWrite) throw new Error('full'); },
  }) } } } });
  try {
    const m = f.load('entry/src/main/ets/components/AppMessageStore.ets'); const store = new m.AppMessageStore();
    await assert.rejects(store.init({}), /读取失败/); assert.equal(store.isReady(), false);
    failRead = false; await store.init({}); await store.post(m.buildAiDoneMessage(1, 'test'));
    failWrite = true; await assert.rejects(store.clear(), /保存失败/); assert.equal(store.size(), 1);
    await assert.rejects(store.markRead('ai-1'), /保存失败/); assert.equal(store.unreadCount(), 1);
    failWrite = false; await store.clear(); assert.equal(store.size(), 0);
  } finally { f.close(); }
});

test('diagnosis and share-history failures are recoverable and never look like loaded empty data', async () => {
  let fail = true;
  const p = page('components/NetworkDiagnosticsSheet.ets', ['runDiag_'], {
    runNetworkDiagnostics: async () => { throw new Error('offline'); }, NetworkVerdict: {}, AppStorage: {},
  });
  Object.assign(p, { running: false }); p.runDiag_(); await tick();
  assert.equal(p.running, false); assert.match(p.errorText, /offline/); assert.equal(p.report, null);
  const h = page('pages/LogShareHistoryPage.ets', ['refresh_'], {
    flushPendingShareCredentials: async () => {},
    loadShareHistory: async () => { if (fail) throw new Error('read failed'); return { records: [], warnings: [] }; },
  });
  Object.assign(h, { loading: false, loaded: false, records: [] });
  const first = h.refresh_(); assert.equal(h.loading, true); await first; assert.match(h.errorText, /read failed/);
  fail = false; await h.refresh_(); assert.equal(h.errorText, ''); assert.equal(h.loaded, true);
});

test('partial deletion and busy evidence are rejected by the real ledger', () => {
  const f = evidenceRuntime({ imports: { './FileUtils': {
    ensureDirSync: p => fs.mkdirSync(p, { recursive: true }), removeDirRecursive() {},
  } } });
  try {
    const l = f.load('commons/src/main/ets/utils/ActivityLedger.ets');
    f.write('logs/ledger/1/manifest.json', JSON.stringify({ activityId: 1, state: 1 }));
    assert.throws(() => l.ledgerRemove(f.directory, 1), /未能删除/);
    f.write('logs/ledger/1/manifest.json', JSON.stringify({ activityId: 1, state: 0 }));
    assert.throws(() => l.ledgerClear(f.directory), /进行中/);
  } finally { f.close(); }
});

test('the confirmed provider stays fixed at POST; unknown response is not replayed', async () => {
  const f = evidenceRuntime();
  try {
    const c = f.load('entry/src/main/ets/components/LogShareClient.ets');
    const plan = await c.prepareLogShare(); f.control.requests = []; f.control.networkError = true;
    const result = await c.submitLogFiles([{ name: 'game/logs/latest.log', content: 'fixture' }], 'test', undefined, plan);
    assert.equal(result.errorStage, 'unknown-outcome');
    assert.equal(f.control.requests.length, 1); assert(f.control.requests[0].url.startsWith(plan.apiBaseUrl));
  } finally { f.close(); }
});

test('critical source guard rejects new volatile errors, missing files and duplicate GLFW writer coupling', () => {
  assert.deepEqual(checkCriticalLogging(), []);
  const read = file => fs.readFileSync(path.join(root, file), 'utf8');
  assert(checkCriticalLogging(file => read(file) + (file === criticalFiles[0] ? '\nhilog.error(0, TAG, "lost");' : '')).length);
  assert(checkCriticalLogging(file => { if (file === criticalFiles[0]) throw new Error(); return read(file); }).length);
  assert(checkCriticalLogging(file => read(file) + (file.endsWith('glfw_egl.cpp') ? '\nAMCL_LOG_E(LOG_TAG, "bad-link");' : '')).length);
});

test('AI without a current share explains the prerequisite and preserves diagnosis routing', async () => {
  let choice = 0; const routes = []; let closed = 0;
  const p = page('components/McErrorSheet.ets', ['lsSubmit_', 'openShareComposer_'], {
    loadShareRecords: async () => [{ activityId: 8, accepted: true, sharedAt: 1, storageTimeSec: 1 }],
    isShareRecordCurrent: () => false,
  });
  Object.assign(p, { uiCtx_: () => ({}), sessionKey: 8, session: { startedAt: 8, version: '1.21.11' }, theme: {},
    shortVersion: x => x, onClose: () => { closed++; }, toast_() {},
    getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => ({ index: choice }) }),
      getRouter: () => ({ pushUrl: async route => { routes.push(route); } }) }) });
  assert.equal(await p.lsSubmit_(), false); await tick(); assert.equal(closed, 0); assert.equal(routes.length, 0);
  choice = 1; assert.equal(await p.lsSubmit_(), false); await tick();
  assert.equal(routes.length, 1); assert.equal(routes[0].params.requestAi, true);
  assert.equal(routes[0].params.diagnosisTitle, '1.21.11'); assert.equal(routes[0].params.activityId, 8);
});

test('a disabled author destination never silently becomes public sharing', async () => {
  let networkOrStorage = 0;
  const p = page('components/ActivityShareSheet.ets', ['send_'], {
    DistributionPolicy: { allowPublisherServices: () => false },
    submitEvidenceToAuthor: async () => { networkOrStorage++; },
  });
  Object.assign(p, { context: {}, snapshot: {}, alive: true, busy_: () => false, destination: 'author' });
  await p.send_(false); assert.equal(networkOrStorage, 0); assert.equal(p.destination, 'author');
});

test('an unavailable legacy credential store is not presented as an empty share history', async () => {
  const f = evidenceRuntime({ imports: { '@kit.ArkData': { preferences: {
    getPreferences: async () => { throw new Error('credentials unavailable'); },
  } } } });
  try {
    const c = f.load('entry/src/main/ets/components/LogShareClient.ets');
    await assert.rejects(c.loadShareRecords(f.context), /分享记录读取失败/);
  } finally { f.close(); }
});

test('revoking an old share does not remove the current diagnosis link', async () => {
  let cleared = 0;
  const f = evidenceRuntime({ imports: {
    feature_core: { getDownloadHistoryStore: () => ({ findByStartedAt: () => ({ lsId: 'new-share' }), clearSessionShare: async () => { cleared++; } }) },
    launch: {},
  } });
  try {
    const s = f.load('entry/src/main/ets/components/McSessionSnapshot.ets');
    await s.clearSessionShare(1, 'old-share'); assert.equal(cleared, 0);
    await s.clearSessionShare(1, 'new-share'); assert.equal(cleared, 1);
  } finally { f.close(); }
});

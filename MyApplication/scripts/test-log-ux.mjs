// 直接执行页面方法与生产存储/账本逻辑；仅替换 ArkUI、剪贴板和网络边界。
// 对照取消、异步拒绝、保存失败和读取保护，证明“未成功不能提前显示成功”。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import ts from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import { checkCriticalLogging, criticalFiles } from './check-critical-logging.mjs';
import { actionUiReceiver, loadActionComponent } from './lib/unified-actions-fixture.mjs';
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
  const p = page('components/LogRetentionSettings.ets', ['save', 'visible_'], {
    // 使用当前异步账本边界和真实可见性方法；占用必须来自已确认的条目，不能借旧同步API。
    ledgerRetentionVictimsAsync: async () => ids.slice(), formatLogBytes: String,
    ledgerListAsync: async () => ids.map(activityId => ({ activityId, bytes: 100, bytesState: 'current' })),
    ledgerSetSessionRetentionAsync: async () => { writes++; },
  });
  Object.assign(p, { context: { filesDir: '/fixture' }, saving: false, theme: { primary: '#000', error: '#f00' },
    active_: true, settingsVisible_: true, hostVisible_: true, foreground_: true, readGeneration_: 0, saveGeneration_: 0,
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
  let resolve, reject;
  const p = page('pages/LogShareHistoryPage.ets', ['copy_'], {
    pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_, t) => t,
      getSystemPasteboard: () => ({ setData: () => new Promise((yes, no) => { resolve = yes; reject = no; }) }) },
  });
  const record = { url: 'link', accepted: true };
  Object.assign(p, { loaded: true, loading: false, busy: false, records: [record], errorText: '', statusText: '' });
  const first = p.copy_(record); assert.equal(p.statusText, '');
  reject(new Error('denied')); await first; assert.match(p.errorText, /复制失败/);
  const next = p.copy_(record); assert.equal(p.statusText, '');
  resolve(); await next; assert.equal(p.statusText, '链接已复制'); assert.equal(p.errorText, '');
});

test('local removal requires confirmation and rechecks running/read protection', async () => {
  let blocked = '', deletions = 0, choice = 0, backs = 0;
  const p = page('pages/ActivityLogPage.ets', ['canDelete_', 'requestRemoveLedger_', 'removeLedger_', 'close_'], {
    ledgerRemovalBlockReason: () => blocked, ledgerRemovalBlockReasonAsync: async () => blocked,
    ledgerListAsync: async () => [{ activityId: 1, bytes: 42, bytesState: 'current' }], formatLogBytes: () => '42 B',
    ledgerStateLabel: () => '成功', ledgerRemoveAsync: async () => { deletions++; },
    hilog: { warn() {} }, TAG: 'test',
  });
  Object.assign(p, { context: { filesDir: '/fixture' }, activityId: 1, manifest: { title: 'session', state: 1 },
    loading: false, reading: false, sharing: false, copying: false, deleting: false, exportingEvidence: false,
    pageActive: true, pinGeneration_: 0, pinSaving_: false, confirmingRemoval_: false,
    theme: {}, toast_() {}, getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => ({ index: choice }) }),
      getRouter: () => ({ back: () => { backs++; } }) }) });
  await p.requestRemoveLedger_(); assert.equal(deletions, 0);
  choice = 1; const pending = p.requestRemoveLedger_(); blocked = 'busy'; await pending; assert.equal(deletions, 0);
  blocked = ''; p.reading = true; assert.equal(p.canDelete_(), false);
  p.reading = false; await p.requestRemoveLedger_(); assert.equal(deletions, 1); assert.equal(backs, 1);
});

test('revoke is single-flight, reports rejection and retains credentials for retry', async () => {
  let calls = 0, reject;
  const p = page('pages/LogShareHistoryPage.ets', ['revoke_'], {
    revokeShare: () => { calls++; return new Promise((_, no) => { reject = no; }); },
  });
  const record = { id: 'abcdef', url: 'link', token: 'token' };
  Object.assign(p, { context: {}, loaded: true, loading: false, busy: false, records: [record] });
  p.revoke_(record); p.revoke_(record); assert.equal(calls, 1); assert.equal(p.busy, true);
  reject(new Error('disk failure')); await tick();
  assert.equal(p.busy, false); assert.equal(p.records[0].token, 'token'); assert.match(p.errorText, /disk failure/);
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

test('the retired analysis callback in activity details never opens public sharing', async () => {
  const notices = [];
  const workspace = page('pages/ActivityLogPage.ets', ['requestAnalysis_'], { LOGSHARE_AI_UNAVAILABLE: 'AI 服务已下线' });
  Object.assign(workspace, { requestAi: true, showShareOptions: false, toast_: text => notices.push(text) });
  await workspace.requestAnalysis_(); assert.equal(workspace.requestAi, false); assert.equal(workspace.showShareOptions, false);
  assert.deepEqual(notices, ['AI 服务已下线']);
});

/** 当前活动的快照才可生成处理建议；时间近似的轮转文件不得成为本局技术详情。 */
test('the crash opener preserves the session diagnosis and ignores a different session’s approximate log', async context => {
  const ActivityStatus = { CRASHED: 'crashed', FAILED: 'failed', ABORTED: 'aborted', SUCCESS: 'success' };
  const f = evidenceRuntime({ imports: { mods: {} } });
  context.after(() => f.close());
  const { classifyMcError } = f.load('launch/src/main/ets/McErrorClassifier.ets');
  const { SessionMarker } = f.load('launch/src/main/ets/SessionMarker.ets');
  const owner = { startedAt: 32, mcDir: 'old-root', status: ActivityStatus.CRASHED, errorMessage: '' };
  const snap = { sessionKey: 32, version: 'old-instance', logArchiveIndex: 0, logExact: true };
  const log = 'java.lang.OutOfMemoryError: Java heap space';
  let reads = 0;
  const p = page('pages/Index.ets', ['openErrorSheetBySession_'], {
    ActivityStatus, classifyMcError, SessionMarker,
    getDownloadHistoryStore: () => ({ waitReady: async () => {}, findByStartedAt: key => key === 32 ? owner : null }),
    resolveSessionSnapshot: record => { assert.equal(record, owner); snap.outcome = record.status; return snap; },
    readSnapshotLogTail: snapshot => { assert.equal(snapshot, snap); reads++; return log; },
    AppLogger: { info() {}, warn: (_tag, message, error) => assert.fail(message + ': ' + error) },
    TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
  });
  Object.assign(p, { startupFinished_: true, startupRouteVisible_: true, updateDialogCtrl_: null,
    mcRoot: () => 'currently-selected-root', waitForErrorSheet_: async () => true, configureMcErrorMemory_() {} });
  assert.equal(await p.openErrorSheetBySession_(32), true);
  assert.equal(p.mcErrorDiagnosis.category, 'oom'); assert.equal(p.mcErrorLogTail, log);
  assert.equal(p.mcErrorSessionKey, 32); assert.equal(p.mcErrorRoot_, owner.mcDir); assert.equal(p.mcErrorVersion, snap.version);
  for (const archiveIndex of [0, -2]) {
    snap.logExact = false; snap.logArchiveIndex = archiveIndex;
    assert.equal(await p.openErrorSheetBySession_(32), true);
    assert.equal(reads, 1); assert.equal(p.mcErrorLogTail, '');
    assert.equal(p.mcErrorDiagnosis.category, 'unknown');
  }
  // 即使已过期，本次活动持久化的错误摘要仍能展示，不能从后来那一局补取日志。
  snap.logExpired = true;
  owner.errorMessage = 'java.lang.OutOfMemoryError: Direct buffer memory';
  assert.equal(await p.openErrorSheetBySession_(32), true); assert.equal(reads, 1);
  assert.match(p.mcErrorDiagnosis.techDetail, /Direct buffer memory/);
  // 正常结束或中断的“已结束”等活动说明不能当成异常，照样保留同局查看入口。
  for (const status of [ActivityStatus.ABORTED, ActivityStatus.SUCCESS]) {
    owner.status = status; owner.errorMessage = '当前活动已结束';
    assert.equal(await p.openErrorSheetBySession_(32), true);
    assert.equal(p.mcErrorDiagnosis.category, 'not_diagnosable'); assert.equal(p.mcErrorDiagnosis.primaryActionKey, null);
    assert.equal(p.mcErrorDiagnosis.techDetail, owner.errorMessage);
  }
});

/** 尾部缺失时仍保留 Java / Fabric 的版本信息；只有堆内存耗尽才提示调整堆上限。 */
test('the classifier preserves Java version and memory evidence from the saved summary alone', () => {
  const f = evidenceRuntime({ imports: { mods: {} } });
  try {
    const { classifyMcError } = f.load('launch/src/main/ets/McErrorClassifier.ets');
    const jvm = classifyMcError('java.lang.UnsupportedClassVersionError: compiled for class file version 69.0, '
      + 'this runtime only recognizes class file versions up to 65.0', '', '26.1');
    assert.equal(jvm.category, 'jdk_version'); assert.match(jvm.techDetail, /69.*65/);
    const fabric = classifyMcError("requires version 25 or later of 'OpenJDK Server VM' (java), wrong version is present: 17",
      '', 'fabric-loader-0.18-26.1');
    assert.equal(fabric.category, 'jdk_version'); assert.match(fabric.techDetail, /25.*17/);
    for (const [detail, action] of [['Java heap space', 'open_memory_settings'], ['GC overhead limit exceeded', 'open_memory_settings'],
      ['Direct buffer memory', 'copy_log'], ['unable to create native thread', 'copy_log']]) {
      const error = classifyMcError('java.lang.OutOfMemoryError: ' + detail, '', '26.1');
      assert.equal(error.primaryActionKey, action); assert.ok(error.techDetail.includes(detail));
    }
  } finally { f.close(); }
});

/** 非零退出码只描述结局，弹窗技术原因应保留本局 Fabric 给出的模组和缺失依赖。 */
test('the crash sheet diagnosis retains the missing Fabric dependency instead of the generic exit code', () => {
  const f = evidenceRuntime({ imports: { mods: {} } });
  try {
    const { classifyMcError } = f.load('launch/src/main/ets/McErrorClassifier.ets');
    const dependency = "Mod 'AMCL QA Exit 1125' (amcl_qa_exit_1125) 1.0.0 requires any version of amcl_qa_missing_dependency_1125, which is missing!";
    const result = classifyMcError('JVM 已请求以非零代码 1 退出，请查看本局日志', 'Mod resolution failed\n - ' + dependency, '26.2');
    assert.equal(result.category, 'mod_conflict');
    assert.ok(result.techDetail.includes(dependency), result.techDetail);
    assert.equal(result.primaryActionKey, 'open_mod_list');
  } finally { f.close(); }
});

/** 显式 JVM 堆参数和实例覆盖优先于全局设置；其他根目录中的同名实例不能影响该判定。 */
test('the heap action follows this instance’s current JVM settings and distinguishes an explicit maximum', () => {
  const f = evidenceRuntime();
  try {
    const tokens = f.load('commons/src/main/ets/utils/JvmArgumentTokens.ets');
    const p = page('pages/Index.ets', ['configureMcErrorMemory_'], tokens);
    let xmx = 0, args = '', reads = 0;
    const pref = { getVersionOverride: key => { assert.equal(key, 'original'); reads++; return { xmx }; },
      resolveLaunch: key => { assert.equal(key, 'original'); return { customJvmArgs: args }; } };
    Object.assign(p, { mcRoot: () => 'original-root', getPrefManager_: () => pref });
    function action(recordedRoot = 'original-root', key = 'open_memory_settings') {
      const diagnosis = { primaryActionKey: key, description: '内存不足。' };
      p.configureMcErrorMemory_(diagnosis, 'original', recordedRoot);
      return diagnosis;
    }
    assert.equal(action('different-root').primaryActionKey, 'open_memory_settings');
    assert.equal(action('original-root', 'copy_log').primaryActionKey, 'copy_log');
    assert.equal(reads, 0);
    args = '-Dname=-Xmx123m';
    assert.equal(action().primaryActionKey, 'open_memory_settings');
    xmx = 2048;
    const sized = action(); assert.equal(sized.primaryActionKey, 'open_version_jvm'); assert.match(sized.description, /2048/);
    args = '-Xmx512m -Xmx4G';
    const explicit = action(); assert.equal(explicit.primaryActionKey, 'open_version_jvm'); assert.match(explicit.description, /-Xmx4G/);
    assert.doesNotMatch(explicit.description, /2048|-Xmx512m/);
  } finally { f.close(); }
});

/** 处理动作须与当次诊断对应；切换根目录后即使有同名模组包也不能误操作。 */
test('crash treatment targets the diagnosed setting or the same installed instance', () => {
  let allowed = true, activeRoot = 'root-a';
  const p = page('pages/Index.ets', ['handleMcErrorAction_'], {
    GameRunAdmission: { isAllowed: () => allowed }, ResourceKind: { MOD: 'mods' },
  });
  const destinations = [];
  Object.assign(p, { mcErrorRoot_: 'root-a', mcErrorVersion: 'instance', availableVersions: ['instance'], orphanVersionDirs: [],
    mcRoot: () => activeRoot, safeToast_() {}, tabController: { changeIndex: tab => destinations.push(['tab', tab]) },
    jumpToDownloadSub: sub => { destinations.push(['download', sub]); return true; },
    openInstalledResourcesSheet: (...args) => destinations.push(args) });
  function select(key) { p.showMcErrorSheet = true; p.mcErrorDiagnosis = { primaryActionKey: key }; }
  select('open_memory_settings');
  assert.equal(p.handleMcErrorAction_('open_mod_list'), false);
  assert.equal(p.handleMcErrorAction_('open_memory_settings'), true);
  assert.equal(p.openMemoryRequested, true); assert.equal(p.showMcErrorSheet, false);
  select('open_jdk_manager'); allowed = false;
  assert.equal(p.handleMcErrorAction_('open_jdk_manager'), false); assert.equal(p.showMcErrorSheet, true);
  allowed = true; assert.equal(p.handleMcErrorAction_('open_jdk_manager'), true);
  select('open_version_jvm');
  assert.equal(p.handleMcErrorAction_('open_version_jvm'), true);
  assert.equal(p.versionManagerInitialStep, 'jvm'); assert.equal(p.installedResourcesTargetVersion, 'instance');
  select('open_mod_list'); activeRoot = 'root-b';
  assert.equal(p.handleMcErrorAction_('open_mod_list'), false); assert.equal(p.showMcErrorSheet, true);
  activeRoot = 'root-a'; assert.equal(p.handleMcErrorAction_('open_mod_list'), true);
  select('redownload');
  assert.equal(p.handleMcErrorAction_('redownload'), true);
  assert.equal(p.versionManagerInitialStep, 'detail'); assert.equal(p.installedResourcesTargetVersion, 'instance');
  select('redownload'); p.availableVersions = [];
  assert.equal(p.handleMcErrorAction_('redownload'), false); assert.equal(p.showMcErrorSheet, true);
  p.orphanVersionDirs = ['instance']; assert.equal(p.handleMcErrorAction_('redownload'), true);
  assert.equal(p.versionManagerInitialStep, 'list'); assert.equal(p.installedResourcesTargetVersion, 'instance');
  select('open_mod_list');
  assert.equal(p.handleMcErrorAction_('open_mod_list'), false); assert.equal(p.showMcErrorSheet, true);
  assert.deepEqual(destinations, [['tab', 2], ['download', 5], ['instance', 'mods']]);
});

/** 旧弹窗的四张卡在正文中滚动，固定底栏保留处理、上传和关闭；日志卡内两种去向等宽。 */
test('the crash sheet renders this diagnosis and wires treatment, local analysis and developer feedback separately', () => {
  const ui = actionUiReceiver(), actions = [], destinations = [];
  let closed = 0;
  let authorAllowed = true;
  const diagnosis = { category: 'mod_conflict', title: '模组冲突或缺失依赖', description: '本局模组缺少启动依赖',
    techDetail: 'amcl_qa_exit_1125 → amcl_qa_missing_dependency_1125', errorKind: 'ModResolutionException',
    primaryActionKey: 'open_mod_list', primaryActionLabel: '打开模组管理', suggestions: [] };
  let markCategory;
  const Sheet = loadActionComponent('entry/src/main/ets/components/McErrorSheet.ets', 'McErrorSheet', {
    // Button 的内容块在 SDK 宿主转译后将首个修饰器 id 作为单独调用，仍执行原始 onClick。
    render: true, globals: { ...ui.globals, Scroll: ui.globals.Column, BarState: { Auto: 'auto' },
      TextAlign: { Center: 'center', Start: 'start' }, Color: { Transparent: 'transparent' }, CopyOptions: { None: 'none' },
      alignItems: value => ui.globals.Row().alignItems(value), id: value => ui.globals.Button().id(value) },
    dependencies: { commons: { AppIconName: { ChevronRight: 'right' },
      DistributionPolicy: { allowPublisherServices: () => authorAllowed } },
      launch: { classifyMcError: () => diagnosis }, './AppIcon': { AppIcon: ui.globals.AppIcon },
      './McErrorMark': { McErrorMark: props => { markCategory = props.category; } },
      './AppRoundIconButton': { AppRoundIconButton: ui.globals.AppRoundIconButton },
      './ImmersiveTitleScaffold': { ImmersiveTitleScaffold: options => options.content() } },
  });
  const sheet = Object.assign(new Sheet(), { diagnosis, sessionKey: 32, version: 'test-version', logTail: '本局日志末尾',
    onAction: key => { actions.push(key); return true; }, onClose: () => { closed++; },
    openAnalysis_: (author = false) => destinations.push(author) });
  const byId = id => ui.records.find(record => record.modifiers.id?.[0] === id);
  const roundControl = id => ui.records.find(record => record.type === 'AppRoundIconButton' && record.args[0].controlId === id)?.args[0];
  const visibleText = value => ui.records.some(record => record.type === 'Text' && record.args[0] === value);
  const render = () => { ui.clear(); markCategory = undefined; sheet.build(); };
  render();
  assert.equal(byId('mc-error-reason').args[0], diagnosis.description);
  assert.equal(byId('mc-error-tech-detail').args[0], diagnosis.techDetail);
  assert.ok(visibleText(diagnosis.title));
  assert.ok(visibleText(sheet.version));
  assert.equal(markCategory, diagnosis.category);
  assert.ok(visibleText(diagnosis.primaryActionLabel));
  assert.ok(!visibleText(sheet.logTail), '首次打开时应仅展示技术原因，长日志仍可按需展开');
  // 日志卡在原因与技术卡之间，技术卡之后才结束外层滚动，处理和关闭留在固定底栏。
  const heroIndex = ui.records.findIndex(record => record.type === 'Text' && record.args[0] === diagnosis.title);
  const reasonIndex = ui.records.indexOf(byId('mc-error-reason'));
  const shareIndex = ui.records.indexOf(byId('mc-error-analyze-logs'));
  const detailsIndex = ui.records.indexOf(byId('mc-error-toggle-log'));
  const scrollEnd = ui.records.findIndex(record => record.modifiers.scrollBar?.[0] === 'auto' && record.modifiers.layoutWeight?.[0] === 1);
  const footerIndex = ui.records.indexOf(byId('mc-error-treatment'));
  assert.ok(heroIndex >= 0 && heroIndex < reasonIndex && reasonIndex < shareIndex && shareIndex < detailsIndex);
  assert.ok(detailsIndex < scrollEnd && scrollEnd < footerIndex);
  // 外框和按钮裁剪使用同一圆角，避免描边仍为直角。
  for (const id of ['mc-error-analyze-logs', 'mc-error-upload']) {
    const modifiers = byId(id).modifiers;
    assert.deepEqual(modifiers.layoutWeight, [1]);
    assert.equal(modifiers.border[0].radius, 14);
    assert.deepEqual(modifiers.borderRadius, [14]);
  }
  assert.ok(visibleText('分析日志') && visibleText('上传给开发者'));
  // 使用日志卡自身测得的宽度。窄卡仅省略箭头，两种去向和实际点击回调都保留。
  const entryArrows = () => ui.records.filter(record => record.type === 'AppIcon' && record.args[0].name === 'right').length;
  for (const [width, arrows] of [[520, 2], [320, 0]]) {
    const onAreaChange = ui.records.find(record => record.modifiers.onAreaChange).modifiers.onAreaChange[0];
    onAreaChange({}, { width }); render();
    assert.equal(entryArrows(), arrows);
    assert.ok(visibleText('查看本局错误线索') && visibleText('先预览脱敏文件'));
  }
  byId('mc-error-treatment').modifiers.onClick[0]();
  byId('mc-error-analyze-logs').modifiers.onClick[0]();
  byId('mc-error-upload').modifiers.onClick[0]();
  byId('mc-error-detail-upload').modifiers.onClick[0]();
  roundControl('mc-error-footer-upload').onAction();
  roundControl('mc-error-footer-close').onAction();
  assert.equal(closed, 1);
  assert.deepEqual(actions, ['open_mod_list']); assert.deepEqual(destinations, [false, true, true, true]);
  byId('mc-error-toggle-log').modifiers.onClick[0]();
  render();
  assert.ok(visibleText(sheet.logTail));
  assert.ok(visibleText(diagnosis.errorKind));
  byId('mc-error-toggle-log').modifiers.onClick[0]();
  render(); assert.ok(!visibleText(sheet.logTail));
  authorAllowed = false;
  for (const key of ['copy_log', null]) {
    sheet.diagnosis = { ...diagnosis, primaryActionKey: key };
    render();
    assert.equal(byId('mc-error-treatment'), undefined); assert.equal(byId('mc-error-upload'), undefined);
    assert.equal(byId('mc-error-detail-upload'), undefined);
    assert.equal(roundControl('mc-error-footer-upload'), undefined);
    assert.ok(byId('mc-error-analyze-logs'));
    const fallback = byId('mc-error-footer-primary');
    assert.equal(fallback.modifiers.accessibilityText[0], key === null ? '知道了' : '分析日志');
    fallback.modifiers.onClick[0]();
  }
  assert.deepEqual(destinations, [false, true, true, true, false]);
  assert.equal(closed, 2);
});

/** 执行原生 Shape/Path 声明：相同故障族应复用图形，独立类型靠轮廓区分。 */
test('native diagnosis marks draw distinct geometry for each fault family and a neutral end state', () => {
  const ui = actionUiReceiver();
  const Mark = loadActionComponent('entry/src/main/ets/components/McErrorMark.ets', 'McErrorMark', {
    render: true, globals: { ...ui.globals, Shape: ui.globals.Stack, Path: ui.globals.Image,
      id: value => ui.globals.Stack().id(value), Color: { Transparent: 'transparent' },
      LineCapStyle: { Round: 'round' }, LineJoinStyle: { Round: 'round' } },
  });
  const mark = new Mark();
  let density = 1;
  mark.getUIContext = () => ({ vp2px: vp => vp * density, px2vp: px => px / density });
  const families = {
    'split-link': ['mod_conflict', 'mixin_apply'], 'classic-cross': ['unknown'],
    'session-ended': ['not_diagnosable'], 'jvm-runtime': ['jdk_version', 'jdk_runtime'], memory: ['oom'],
    'document-cross': ['missing_file', 'fabric_game_missing', 'forge_boot_classpath'], 'native-crash': ['native_crash'],
    graphics: ['lwjgl_module_missing', 'lwjgl_version'], 'launch-args': ['launch_arg'], network: ['ipv6_unsupported'],
  };
  const shapes = new Set();
  for (const [name, categories] of Object.entries(families)) {
    let first;
    for (const category of categories) {
      ui.clear(); mark.category = category; mark.build();
      assert.ok(ui.records.some(record => record.modifiers.id?.[0] === 'mc-error-mark-' + name), category);
      const paths = ui.records.filter(record => record.modifiers.commands).map(record => record.modifiers.commands[0]);
      assert.ok(paths.length >= 2 && paths.every(value => typeof value === 'string' && value.length > 0), name);
      if (first) assert.deepEqual(paths, first, category);
      else first = paths;
    }
    const drawing = JSON.stringify(first);
    assert.ok(!shapes.has(drawing), name + ' shares its entire geometry with a different fault family');
    shapes.add(drawing);
  }
  // 平板上单改视口只会放大外框。验证真实绘图层对 64px Path 和笔画绕中心应用同一个变换。
  mark.category = 'mod_conflict';
  for (const [size, ratio] of [[80, 1], [80, 2.5], [44, 2.5]]) {
    density = ratio; mark.iconSize = size;
    ui.clear(); mark.build();
    const box = ui.records.find(record => record.modifiers.id?.[0] === 'mc-error-mark-split-link');
    assert.deepEqual(box.modifiers.width, [size]);
    assert.deepEqual(box.modifiers.height, [size]);
    const canvas = ui.records.find(record => record.modifiers.scale);
    assert.ok(canvas, '绘图层必须应用尺寸变换');
    assert.deepEqual(canvas.modifiers.scale[0], {
      x: size * ratio / 64, y: size * ratio / 64, centerX: '50%', centerY: '50%',
    });
    const paths = ui.records.filter(record => record.modifiers.commands);
    assert.ok(paths.length && paths.every(record => record.modifiers.width?.[0] === '64px' && record.modifiers.height?.[0] === '64px'));
  }
});

/** 本地分析与作者反馈共用本次活动号，导航进行中不能同时打开两个不同目的地。 */
test('the crash sheet opens the same local activity once and remains open after navigation failure', async () => {
  let authorAllowed = true;
  const p = page('components/McErrorSheet.ets', ['openAnalysis_'], {
    DistributionPolicy: { allowPublisherServices: () => authorAllowed },
  });
  const routes = [], notices = [];
  let closes = 0, resolve, reject;
  Object.assign(p, { sessionKey: 32, openingLogs: false, onClose: () => { closes++; },
    getUIContext: () => ({ getRouter: () => ({ pushUrl: route => {
      routes.push(route); return new Promise((yes, no) => { resolve = yes; reject = no; });
    } }), getPromptAction: () => ({ showToast: options => notices.push(options.message) }) }) });
  const first = p.openAnalysis_(); await p.openAnalysis_(true);
  assert.deepEqual(routes, [{ url: 'pages/ActivityLogPage', params: { activityId: 32, view: 'overview' } }]);
  reject(new Error('page unavailable')); await first;
  assert.equal(closes, 0); assert.equal(p.openingLogs, false); assert.match(notices[0], /请重试/);
  const retry = p.openAnalysis_(true); resolve(); await retry;
  assert.equal(routes.length, 2); assert.equal(closes, 1);
  assert.equal(routes[1].url, 'pages/ActivityLogPage');
  assert.equal(routes[1].params.activityId, 32);
  assert.equal(routes[1].params.destination, 'author');
  assert.equal(routes[1].params.showShare, true);
  // 渠道禁用后，迟到的作者按钮回调也不能把日志转去公开分享。
  authorAllowed = false;
  await p.openAnalysis_(true);
  assert.equal(routes.length, 2); assert.equal(closes, 1);
});

/** 预览只冻结本次活动，明确确认后使用作者接口，保留其回执且不创建公开分享记录。 */
test('the author preview sends only its reviewed snapshot to the developer after confirmation', async () => {
  const snapshot = { activityId: 32, digest: 'reviewed', files: [{ name: 'game/latest.log' }] };
  const identity = { clientId: 'fixture', device: 'test', osVersion: 'test', appVersion: 'test' };
  const authorCalls = [], outcomes = [], receipts = [];
  const p = page('components/ActivityShareSheet.ets', ['prepare_', 'send_', 'release_', 'busy_', 'setPhase_'], {
    DistributionPolicy: { allowPublisherServices: () => true },
    prepareActivityShare: async (_context, draft) => { assert.equal(draft.activityId, 32); return snapshot; },
    prepareAuthorUploadIdentity: async () => identity,
    submitEvidenceToAuthor: async (...args) => { authorCalls.push(args); return { ok: true, id: 'feedback-id', duplicate: false }; },
    prepareLogShare: () => assert.fail('作者预览不能联系公开分享服务'),
    shareEvidenceSnapshot: () => assert.fail('作者反馈不能创建公开链接'),
    disposeEvidenceExportSnapshot: value => assert.equal(value, snapshot),
  });
  Object.assign(p, { alive: true, context: {}, activityId: 32, destination: 'author', phase: 'select', generation: 0,
    draft: { activityId: 32, selectedFileIds: ['game-log'], manifest: { title: '本局' } },
    onBusyChanged() {}, fail_: error => { throw error; }, onShareOutcome: (...args) => outcomes.push(args),
    onAuthorAccepted: (...args) => receipts.push(args) });
  await p.prepare_(true);
  assert.equal(p.phase, 'review'); assert.equal(authorCalls.length, 0);
  await p.send_(false);
  assert.deepEqual(authorCalls, [[snapshot, '活动日志反馈：本局', 'manual', identity]]);
  assert.deepEqual(outcomes, [['sending', '', ''], ['submittedToAuthor', '', 'feedback-id']]);
  assert.deepEqual(receipts, [['feedback-id', false]]);
  assert.equal(p.phase, 'done'); assert.equal(p.snapshot, undefined);
});

/** 新索引报告与旧版单正文均只从本机读取，不依赖提供方还能创建新任务。 */
test('new and legacy saved AI reports remain readable after the provider is retired', async () => {
  const states = { IDLE: 0, RUNNING: 1, DONE: 2, ERROR: 3 };
  for (const legacy of [false, true]) {
    const p = page('components/ActivityAiCard.ets', ['read_', 'canAnalyze_'], {
      AiTaskState: states, LOGSHARE_API_BASE: 'https://api.logshare.cn', logShareSupportsAi: () => false,
      loadAiReport: () => legacy ? undefined : { summary: '本地摘要', apiBaseUrl: 'https://api.logshare.cn', shareId: 'old', snapshotDigest: 'snapshot' },
      loadAiReportBody: () => '已有完整报告', aiPreviewText: text => text, parseAiStructuredDiagnosis: () => undefined,
      fs: { accessSync: () => true, statSync: () => ({ size: 30 }), readTextSync: () => '旧版本报告正文' },
      loadShareRecords: async () => [{ activityId: 8, accepted: true, id: 'old', apiBaseUrl: 'https://api.logshare.cn', snapshotDigest: 'snapshot' }],
      isShareRecordCurrent: () => true,
    });
    Object.assign(p, { activityId: 8, revision: 0, retryTimer: -1, expanded: true, allowAnalyze: true,
      context_: () => ({ filesDir: '/fixture' }), applyTask_: () => false });
    await p.read_();
    assert.equal(p.canAnalyze_(), false); assert.equal(p.phase, states.DONE); assert.equal(p.localSaved, true);
    assert.equal(p.answer, legacy ? '旧版本报告正文' : '已有完整报告');
    assert.equal(p.failure, '');
  }
});

/** 去重取得的链接没有本机删除凭据时，旧点击回调也不能进入删除确认或网络请求。 */
test('a share without a local deletion token cannot enter revocation from share history', () => {
  const p = page('pages/LogShareHistoryPage.ets', ['confirmRevoke_']);
  const record = { token: '' };
  Object.assign(p, { busy: false, loaded: true, loading: false, records: [record],
    getUIContext() { throw new Error('缺少撤回凭据时不得弹出删除确认'); } });
  p.confirmRevoke_(record); assert.match(p.errorText, /没有撤回凭据/); assert.equal(p.busy, false);
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

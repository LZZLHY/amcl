/** 原生 JVM 退出事实的宿主回归：只用隔离临时目录，不操作设备或真实实例。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const readerPath = 'launch/src/main/ets/JvmExitEvidence.ets';
const resolverPath = 'launch/src/main/ets/SessionOutcomeResolver.ets';
const ledgerPath = 'commons/src/main/ets/utils/ActivityLedger.ets';

/** 真实 ledgerBegin 在游戏进程写 ownerPid；宿主适配的游戏 PID 为 101。 */
function fixture() {
  const runtime = evidenceRuntime();
  const ledger = runtime.load(ledgerPath);
  const id = Date.now() - 3000;
  ledger.ledgerBegin(runtime.directory, id, { category: 'launch', title: 'test-game',
    gameVersionId: '26.3', mcDir: runtime.directory + '/minecraft', gameDir: runtime.directory + '/minecraft' });
  const record = { schema: 1, activityId: id, pid: 101, parentPid: 100,
    exitCode: 0, source: 'jvm-exit', timestamp: Date.now() - 1000 };
  return { runtime, ledger, id, record,
    publish(value = record) { return runtime.write('game-exits/' + id + '.json', JSON.stringify(value)); } };
}

test('reader按activity/PID/时间绑定，归档后保留native原文，缺marker也能恢复会话', () => {
  const f = fixture();
  try {
    const raw = f.publish();
    const reader = f.runtime.load(readerPath);
    assert.deepEqual(reader.readJvmExitEvidence(f.runtime.directory, f.id), f.record);
    const archived = f.runtime.directory + '/logs/ledger/' + f.id + '/jvm/process-exit.json';
    assert.equal(fs.readFileSync(archived, 'utf8'), fs.readFileSync(raw, 'utf8'));
    assert.deepEqual(reader.listJvmExitSessions(f.runtime.directory), [{ startedAt: f.id,
      version: '26.3', mcDir: f.runtime.directory + '/minecraft', endedAt: f.record.timestamp }]);
    assert.ok(fs.existsSync(raw), 'native原文必须保留供失败恢复/后续复核');
  } finally { f.runtime.close(); }
});

test('非法身份/时间/schema/source/退出码，以及目录和超大文件都不能产生退出结论', () => {
  const f = fixture();
  try {
    const reader = f.runtime.load(readerPath);
    for (const change of [{ activityId: f.id + 1 }, { pid: 99 }, { parentPid: 101 },
      { source: 'something-else' }, { timestamp: f.id - 1 }, { timestamp: Date.now() + 60000 },
      { schema: 2 }, { exitCode: '0' }, { exitCode: 1.5 }, { exitCode: 2147483648 }]) {
      f.publish({ ...f.record, ...change });
      assert.equal(reader.readJvmExitEvidence(f.runtime.directory, f.id), undefined, JSON.stringify(change));
    }
    const raw = f.publish();
    fs.writeFileSync(raw, ' '.repeat(5000) + JSON.stringify(f.record));
    assert.equal(reader.readJvmExitEvidence(f.runtime.directory, f.id), undefined);
    fs.unlinkSync(raw);
    fs.mkdirSync(raw);
    assert.equal(reader.readJvmExitEvidence(f.runtime.directory, f.id), undefined);
  } finally { f.runtime.close(); }
});

test('残留tmp不算终态，capture-game存在时必须与退出文件身份一致', () => {
  const f = fixture();
  try {
    const reader = f.runtime.load(readerPath);
    f.runtime.write('game-exits/' + f.id + '.tmp', JSON.stringify(f.record));
    assert.deepEqual(reader.listJvmExitSessions(f.runtime.directory), []);
    f.publish();
    f.runtime.write('logs/ledger/' + f.id + '/capture-game.json', JSON.stringify({ schema: 1, activityId: f.id, pid: 999 }));
    assert.equal(reader.readJvmExitEvidence(f.runtime.directory, f.id), undefined);
    f.runtime.write('logs/ledger/' + f.id + '/capture-game.json', JSON.stringify({ schema: 1, activityId: f.id, pid: 101 }));
    assert.equal(reader.readJvmExitEvidence(f.runtime.directory, f.id).exitCode, 0);
  } finally { f.runtime.close(); }
});

test('JVM退出请求0与非0均可在没有游戏日志时精确分类，但不宣称OS退出码证据', async () => {
  for (const code of [0, -3, 7]) {
    const f = fixture();
    try {
      f.publish({ ...f.record, exitCode: code });
      const result = await f.runtime.load(resolverPath).resolveRecoveredSessionOutcome(f.runtime.directory, f.id);
      assert.equal(result.state, code === 0 ? f.ledger.LedgerState.SUCCESS : f.ledger.LedgerState.FAILED);
      assert.equal(result.source, 'session.jvm-exit');
      assert.match(result.summary, /请求/);
      assert.doesNotMatch(result.summary, /操作系统正常退出|OS.*成功/);
    } finally { f.runtime.close(); }
  }
});

test('精确平台CRASHED不能被Stopping或JVM exit0覆盖', async () => {
  const f = fixture();
  try {
    f.publish();
    f.runtime.write('minecraft/logs/latest.log', '[INFO] Stopping!\n');
    f.runtime.load('commons/src/main/ets/utils/SessionCapture.ets')
      .checkpointSessionCapture(f.runtime.directory, f.id, Date.now(), 0);
    const manifest = f.ledger.ledgerManifest(f.runtime.directory, f.id);
    manifest.state = f.ledger.LedgerState.CRASHED;
    manifest.outcomeSource = 'platform.APP_CRASH';
    manifest.outcomeSummary = '本局SIGABRT';
    f.runtime.write('logs/ledger/' + f.id + '/manifest.json', JSON.stringify(manifest));
    const result = await f.runtime.load(resolverPath).resolveRecoveredSessionOutcome(f.runtime.directory, f.id);
    assert.equal(result.state, f.ledger.LedgerState.CRASHED);
    assert.equal(result.source, 'platform.APP_CRASH');
  } finally { f.runtime.close(); }
});

test('本局真实crash报告继续优先于退出0，已修旧报告归属逻辑不变', async () => {
  const f = fixture();
  try {
    f.publish();
    f.runtime.write('minecraft/crash-reports/crash-current.txt', 'A REAL CURRENT CRASH BODY\n');
    f.runtime.load('commons/src/main/ets/utils/SessionCapture.ets')
      .checkpointSessionCapture(f.runtime.directory, f.id, Date.now(), 0);
    const result = await f.runtime.load(resolverPath).resolveRecoveredSessionOutcome(f.runtime.directory, f.id);
    assert.equal(result.state, f.ledger.LedgerState.CRASHED);
  } finally { f.runtime.close(); }
});

test('晚到平台crash可纠正可重算正常结果，但不覆盖任意任务显式终态', () => {
  const f = fixture();
  try {
    for (const source of ['session.jvm-exit', 'session.full-evidence', 'task.terminalState']) {
      const manifest = f.ledger.ledgerManifest(f.runtime.directory, f.id);
      manifest.state = f.ledger.LedgerState.SUCCESS;
      manifest.outcomeSource = source;
      f.ledger.applyPlatformOutcome_(manifest, JSON.stringify({ name: 'APP_CRASH' }));
      assert.equal(manifest.state, source === 'task.terminalState'
        ? f.ledger.LedgerState.SUCCESS : f.ledger.LedgerState.CRASHED, source);
    }
  } finally { f.runtime.close(); }
});

test('游戏历史upsert只替换同一launch主键并保留分享/AI，普通add仍追加', async () => {
  let failFlush = false;
  const runtime = evidenceRuntime({ imports: {
    './DownloadManager': { formatBytes: value => String(value) }, './DownloadTask': {},
    '@kit.ArkData': { preferences: { getPreferences: async () => ({ get: async () => '', put: async () => {},
      flush: async () => { if (failFlush) throw new Error('disk failure'); } }) } },
  } });
  try {
    const history = runtime.load('feature_core/src/main/ets/download/DownloadHistory.ets');
    const lru = new history.DownloadHistoryLru(50);
    const record = { versionName: '26.3', gameVersion: '26.3', loaderType: 'launch', startedAt: 55,
      durationMs: 100, totalBytes: 0, fileCount: 0, status: 'success', category: 'launch' };
    lru.add({ ...record, lsId: 'share', lsToken: 'delete-token', aiPath: '/ai/result' });
    lru.upsertLaunchSession({ ...record, status: 'crashed' });
    lru.upsertLaunchSession({ ...record, status: 'crashed' });
    assert.equal(lru.size(), 1);
    assert.equal(lru.list()[0].lsToken, 'delete-token');
    assert.equal(lru.list()[0].aiPath, '/ai/result');
    assert.equal(lru.list()[0].status, 'crashed');
    lru.add({ ...record, category: 'download' });
    lru.add({ ...record, category: 'download' });
    assert.equal(lru.size(), 3, '普通下载add语义不改');
    const store = new history.DownloadHistoryStore();
    await store.init(runtime.context);
    failFlush = true;
    await assert.rejects(() => store.upsertLaunchSession(record), /disk failure/);
    failFlush = false;
    await store.upsertLaunchSession(record);
    assert.equal(store.size(), 1, '失败重试仍然只留一条');
  } finally { runtime.close(); }
});

test('真实Index恢复链按id串行/幂等并使用退出时间；晚到crash更新且写失败不记回执', async () => {
  const f = fixture();
  try {
    f.publish();
    const reader = f.runtime.load(readerPath);
    const Coordinator = f.runtime.load('launch/src/main/ets/SessionRecoveryCoordinator.ets').SessionRecoveryCoordinator;
    const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
    const start = source.indexOf('  private consumeLastSession(): void {');
    const end = source.indexOf('\n  onPageShow()', start);
    assert.ok(start > 0 && end > start);
    const compiled = compiler.transpileModule('class Probe {\n' + source.slice(start, end)
      + '\n}\nmodule.exports=Probe;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
    const records = new Map();
    let writes = 0, failWrite = false, sheets = 0;
    const owner = new Coordinator(f.runtime.directory, { isIdle: () => true, applyHistory: async result => {
      if (failWrite) throw new Error('history unavailable'); writes++;
      records.set(result.session.startedAt, { ...result.session, status: result.outcome.state,
        endedAt: result.session.endedAt, durationMs: result.session.endedAt - result.session.startedAt });
    }, changed() {} });
    const module = { exports: {} };
    const values = { testNapi: { desktopGameProcessState: () => 0 },
      SessionRecoveryRuntime: { wake: () => owner.wake(), coordinator: () => owner,
        reportSettled: () => f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory) },
      writeSessionRecoveryReceiptAsync: reader.writeSessionRecoveryReceiptAsync,
      AppStorage: { get: () => true },
      ActivityStatus: { SUCCESS: 'success', FAILED: 'failed', CRASHED: 'crashed', ABORTED: 'aborted' },
      ActivityCategory: { LAUNCH: 'launch' }, LedgerState: f.ledger.LedgerState,
      getDownloadHistoryStore: () => ({ upsertLaunchSession: async record => {
        if (failWrite) throw new Error('history unavailable'); writes++; records.set(record.startedAt, record);
      } }), AppLogger: { warn() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1 };
    new Function('module', ...Object.keys(values), compiled)(module, ...Object.values(values));
    const subject = new module.exports();
    subject.context = f.runtime.context;
    subject.recoveryPresentationEpoch_ = 0;
    // 本例验证正常首页中的历史恢复与错误呈现；开屏期间生产代码只耐久恢复并延迟呈现。
    // 明确提供已经完成退场的事实，避免把未初始化的undefined误当成正常首页状态。
    subject.startupFinished_ = true;
    subject.showPrivacy = false;
    subject.showMcErrorSheet = false;
    subject.currentTab = 2;
    subject.tabController = { changeIndex() { assert.fail('历史恢复不能撤销用户选择的设置页'); } };
    subject.refreshRecentActivities_ = () => {};
    subject.openErrorSheetBySession_ = async () => { sheets++; return true; };
    const sessions = reader.listJvmExitSessions(f.runtime.directory);
    failWrite = true;
    await assert.rejects(() => subject.consumeRecoveredSessions_(0), /history unavailable/);
    const manifestBefore = f.ledger.ledgerManifest(f.runtime.directory, f.id);
    const outcome = { state: manifestBefore.state, source: manifestBefore.outcomeSource, summary: manifestBefore.outcomeSummary };
    assert.equal(reader.hasSessionRecoveryReceipt(f.runtime.directory, f.id, outcome), false);
    failWrite = false;
    await subject.consumeRecoveredSessions_(0);
    await subject.consumeRecoveredSessions_(0);
    assert.equal(writes, 1);
    assert.equal(subject.currentTab, 2, '历史结果仍耐久确认，当前用户导航保持不变');
    assert.equal(records.get(f.id).endedAt, f.record.timestamp);
    assert.equal(records.get(f.id).durationMs, f.record.timestamp - f.id);
    assert.equal(sheets, 0);
    const manifest = f.ledger.ledgerManifest(f.runtime.directory, f.id);
    f.ledger.applyPlatformOutcome_(manifest, JSON.stringify({ name: 'APP_CRASH' }));
    f.runtime.write('logs/ledger/' + f.id + '/manifest.json', JSON.stringify(manifest));
    await owner.enqueue(f.id);
    await subject.consumeRecoveredSessions_(0);
    assert.equal(writes, 2);
    assert.equal(records.size, 1);
    assert.equal(records.get(f.id).status, f.ledger.LedgerState.CRASHED, 'owner端口传递的是已裁决LedgerState；历史字符串转换由runtime完成');
    assert.equal(sheets, 1);
  } finally { f.runtime.close(); }
});

test('真实Entry前台恢复覆盖触控平板，锁活跃/异常时不消费，marker与journal同id合并', () => {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');
  const start = source.indexOf('  onForeground(): void {');
  const end = source.indexOf('\n  onBackground(): void {', start);
  assert.ok(start > 0 && end > start);
  const compiled = compiler.transpileModule('class Probe {\n' + source.slice(start, end)
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  // 正式商店包与侧载包都执行退出恢复；仅侧载包通知真实更新服务的前台状态。
  // 同时覆盖两种产品值，防止缺失产品依赖后用固定true跳过生产分支造成假通过。
  for (const storeChannel of [false, true]) for (const state of [0, 1, -1, -2, -3, 'throw']) {
    const storage = new Map();
    let wakes = 0, foregrounds = 0, updateForegrounds = 0;
    const module = { exports: {} };
    const values = {
      ProductInputProfile: { selection: () => ({ isolatedGameProcess: true, desktopWindow: false }) },
      ProductBuildProfile: { storeChannel },
      // 只替代真实Ability context边界；正文仍执行原产品守卫，并验证上下文及前台实参。
      SideloadUpdateService: { get(context) {
        assert.equal(context.filesDir, '/sandbox');
        return { setAbilityForeground(foreground) { assert.equal(foreground, true); updateForegrounds++; } };
      } },
      // 输入前台恢复与退出账本消费是独立职责；即使游戏进程仍存活也应通知本进程输入端。
      getInputSourceRegistry: () => ({ notifyAbilityForeground() { foregrounds++; } }),
      testNapi: { desktopGameProcessState: () => { if (state === 'throw') throw new Error('lock error'); return state; },
        setOhosFrameRateForeground() {} },
    DesktopGameResults: { importPending: async () => '' },
    GameLayoutJournal: { importPending: async () => ({ imported: 0, pending: 0, deferred: false, conflicts: [] }) },
      SessionRecoveryRuntime: { wake: async () => { wakes++; } },
      AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      AppLogger: { warn() {}, info() {} }, TAG: 'test', LOG_DOMAIN_LAUNCH: 1,
      FRAME_RATE_FOREGROUND_SOURCE_ENTRY: 1,
    };
    new Function('module', ...Object.keys(values), compiled)(module, ...Object.values(values));
    const subject = new module.exports(); subject.context = { filesDir: '/sandbox' };
    subject.onForeground();
    assert.equal(foregrounds, 1, '实际Ability前台必须发布输入恢复事实');
    assert.equal(updateForegrounds, storeChannel ? 0 : 1, '仅侧载产品通知更新服务前台事实');
    assert.equal(wakes, state === 0 ? 1 : 0, String(state));
    assert.equal(storage.has('pendingJvmExitSessions'), false, 'Entry不再向页面发布全部历史候选');
    assert.equal(storage.has('desktopSessionRevision'), false, '无真实提交不能只因前台通知递增结果revision');
  }
});

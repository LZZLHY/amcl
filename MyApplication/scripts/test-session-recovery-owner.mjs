/**
 * 执行生产恢复协调器、resolver、账本和原子FileIO的宿主回归。
 * 只替换SDK文件/进程边界；真实临时目录外置，不连接设备，不复制恢复判定算法。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import compiler from './lib/ets-compiler.mjs';

const coordinatorPath = 'launch/src/main/ets/SessionRecoveryCoordinator.ets';
const ledgerPath = 'commons/src/main/ets/utils/ActivityLedger.ets';
const recoveryStatePath = 'launch/src/main/ets/SessionRecoveryState.ets';

test('旧恢复队列直接递归mkdir在真实既有目录语义下报File exists且不改原队列', async () => {
  const call = "await ensureEvidenceDirectoryAsync(filesDir + '/logs/recovery');";
  const runtime = evidenceRuntime({ transform: (absolute, source) => {
    if (!absolute.endsWith('SessionRecoveryState.ets')) return source;
    assert.equal(source.split(call).length, 2, '只替回本次修改的唯一原生产队列mkdir调用');
    return source.replace(call, "await fs.mkdir(filesDir + '/logs/recovery', true);");
  } });
  try {
    const queue = { schema: 1, activeIds: [], pendingIds: [], resultIds: [], bootstrapIds: [], bootstrapCursor: 0 };
    const path = runtime.write('logs/recovery/queue.json', JSON.stringify(queue)), before = fs.readFileSync(path);
    const State = runtime.load(recoveryStatePath);
    await assert.rejects(() => State.writeRecoveryQueueAsync(runtime.directory, queue), error => error.code === 13900015);
    assert.deepEqual(fs.readFileSync(path), before);
  } finally { runtime.close(); }
});

test('冷恢复真实复用已有recovery/launcher/jvm目录并继续耐久确认，不被EEXIST当作失败', async () => {
  const f = fixture();
  try {
    const base = f.runtime.directory;
    for (const relative of ['logs/recovery', 'logs/recovery/intents', 'logs/recovery/dispatch-failures',
      'logs/ledger/' + f.id + '/launcher', 'logs/ledger/' + f.id + '/jvm']) {
      fs.mkdirSync(base + '/' + relative, { recursive: true });
    }
    const mkdir = f.runtime.kitFs.mkdir, reused = [];
    f.runtime.kitFs.mkdir = async (path, recursive) => {
      try { return await mkdir(path, recursive); }
      catch (error) { if (recursive && error.code === 13900015) reused.push(path); throw error; }
    };
    f.publish(0); const owner = f.makeOwner(); await owner.wake();
    const [result] = await owner.results();
    assert.equal(result.outcome.state, f.ledger.LedgerState.SUCCESS);
    const exitReader = f.runtime.load('launch/src/main/ets/JvmExitEvidence.ets');
    await exitReader.writeSessionRecoveryReceiptAsync(base, f.id, result.outcome);
    await owner.acknowledgePresentation(f.id, result.revision);
    const dispatchId = f.id + 1, token = 'mkdir-cold-reuse';
    await owner.trackLaunch(dispatchId, token);
    await owner.recordLaunchDispatchFailure(dispatchId, token, 'startAbility', 'dispatch rejected before baseline');
    await f.makeOwner().wake();
    assert.ok(reused.includes(base + '/logs/recovery'));
    assert.ok(reused.includes(base + '/logs/ledger/' + f.id + '/launcher'));
    assert.ok(reused.includes(base + '/logs/ledger/' + f.id + '/jvm'));
    assert.ok(reused.includes(base + '/logs/recovery/intents'));
    assert.ok(reused.includes(base + '/logs/recovery/dispatch-failures'));
    assert.equal(f.state().presentationRevision, result.revision);
  } finally { await f.close(); }
});

test('恢复普通目录遇文件、符号链接或lstat权限故障必须拒绝，不以EEXIST吞掉冲突', async () => {
  const queue = { schema: 1, activeIds: [], pendingIds: [], resultIds: [], bootstrapIds: [], bootstrapCursor: 0 };
  for (const kind of ['file', 'link', 'permission']) {
    const runtime = evidenceRuntime();
    try {
      const State = runtime.load(recoveryStatePath), path = runtime.directory + '/logs/recovery';
      if (kind === 'file') runtime.write('logs/recovery', 'preserve conflicting file');
      else {
        fs.mkdirSync(runtime.directory + '/logs', { recursive: true });
        if (kind === 'link') {
          const target = runtime.directory + '/retained-target'; fs.mkdirSync(target);
          fs.symlinkSync(target, path, 'junction');
        } else {
          fs.mkdirSync(path); const lstat = runtime.kitFs.lstat;
          runtime.kitFs.lstat = async value => {
            if (value === path) throw Object.assign(new Error('directory permission denied'), { code: 13900012 });
            return lstat(value);
          };
        }
      }
      await assert.rejects(() => State.writeRecoveryQueueAsync(runtime.directory, queue));
      if (kind === 'file') assert.equal(fs.readFileSync(path, 'utf8'), 'preserve conflicting file');
      else assert.equal(fs.existsSync(path + '/queue.json'), false, '冲突/不可核验目录不得发布新的消费队列');
    } finally { runtime.close(); }
  }
});

/** 反控直接移除生产函数本次新增的空字节守卫，不另写一套摘要算法。 */
test('旧恢复摘要无条件update在严格CryptoFramework边界遇空输入确实失败', async () => {
  const guard = 'if (bytes.byteLength > 0) await digest.update({ data: bytes });';
  const runtime = evidenceRuntime({ transform: (absolute, source) => {
    if (!absolute.endsWith('SessionRecoveryState.ets')) return source;
    assert.equal(source.split(guard).length, 2, '只反控唯一真实生产调用');
    return source.replace(guard, 'await digest.update({ data: bytes });');
  } });
  try {
    const State = runtime.load(recoveryStatePath);
    await assert.rejects(() => State.recoveryTextDigestAsync(''), /update failed/);
    assert.deepEqual(runtime.control.cryptoUpdates.map(({ bytes }) => bytes), [0]);
    assert.equal(await State.recoveryTextDigestAsync('abc'), createHash('sha256').update('abc').digest('hex'));
  } finally { runtime.close(); }
});

test('恢复摘要空串省略update但真实digest仍返回标准SHA256，非空UTF8输入保持同一语义', async () => {
  const runtime = evidenceRuntime();
  try {
    const State = runtime.load(recoveryStatePath);
    assert.equal(await State.recoveryTextDigestAsync(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    assert.equal(runtime.control.cryptoUpdates.length, 0, '缺失发布原文不能调用零长度DataBlob更新');
    for (const value of ['abc', '恢复输入🙂', '\0']) {
      assert.equal(await State.recoveryTextDigestAsync(value), createHash('sha256').update(value, 'utf8').digest('hex'));
    }
    assert.ok(runtime.control.cryptoUpdates.every(({ bytes, synchronous }) => bytes > 0 && synchronous === false));
  } finally { runtime.close(); }
});

test('恢复摘要非空update失败和空输入digest失败仍抛原始错误，不能返回占位key', async () => {
  for (const stage of ['update', 'digest']) {
    const failure = new Error('synthetic ' + stage + ' failure'); let updates = 0, digests = 0;
    const runtime = evidenceRuntime({ imports: { '@kit.CryptoArchitectureKit': { cryptoFramework: {
      createMd: () => ({ update: async () => { updates++; if (stage === 'update') throw failure; },
        digest: async () => { digests++; throw failure; } })
    } } } });
    try {
      const State = runtime.load(recoveryStatePath);
      await assert.rejects(() => State.recoveryTextDigestAsync(stage === 'update' ? 'valid producer input' : ''), error => error === failure);
      assert.equal(updates, stage === 'update' ? 1 : 0); assert.equal(digests, stage === 'update' ? 0 : 1);
    } finally { runtime.close(); }
  }
});

/**
 * options.imports只注入需要的SDK系统边界；每次调用创建独立外置目录、模块缓存和生产Coordinator/账本。
 * ledgerEndAsync及平台归档端口只增加到达计数并可挂起，最终仍委托真实生产函数、resolver和原子文件IO。
 * 历史端口使用Map替代Preferences，changed只计数，isIdle由用例控制；这两类结果不冒充设备或UI验收。
 * 返回原件发布/状态读取、可控故障hooks和makeOwner：新owner实例从同一真实目录恢复检查点，非真实进程重启。
 * 用例在finally等待close；调用方仍须先等待owner、挂起提交和历史回调，close再禁止新增维护
 * 并等待真实在途维护任务结束，最后只清理本夹具的受验证目录，不能与异步rename/fsync竞跑。
 */
function fixture(options = {}) {
  let ledger, commitHook;
  const counts = { end: 0, platform: 0, history: 0, changed: 0 };
  const runtime = evidenceRuntime({ imports: options.imports, transform: options.transform, commons: {
    ...options.commons,
    ledgerEndAsync: async (...args) => { counts.end++; await commitHook?.(...args); return ledger.ledgerEndAsync(...args); },
    archivePlatformEventFilesAsync: async (...args) => { counts.platform++; return ledger.archivePlatformEventFilesAsync(...args); },
  } });
  // 保留底层SDK适配故障码，避免原子写TypedError把宿主路径/操作证据完全折叠。
  for (const operation of ['mkdir', 'open', 'rename', 'write', 'fsync', 'close']) {
    const original = runtime.kitFs[operation];
    runtime.kitFs[operation] = async (...args) => {
      try { return await original(...args); }
      catch (error) {
        if (operation === 'rename') console.error(JSON.stringify({ operation, target: args[0], code: error.code ?? '', message: error.message }));
        throw error;
      }
    };
  }
  ledger = runtime.load(ledgerPath);
  ledger.configureLedgerMaintenanceOwner(true, () => idle);
  let idle = true, failHistory = false, historyHook;
  const records = new Map();
  const hooks = { isIdle: () => idle, applyHistory: async result => {
    if (failHistory) throw new Error('history disk failure');
    await historyHook?.(result); counts.history++; records.set(result.session.startedAt, result);
  }, changed: () => { counts.changed++; } };
  const Coordinator = runtime.load(coordinatorPath).SessionRecoveryCoordinator;
  /** 使用共享磁盘原件和独立owner实例重新装配；生产initialize决定如何恢复，夹具不预填消费游标。 */
  const makeOwner = () => new Coordinator(runtime.directory, hooks);
  const id = Date.now() - 10000;
  ledger.setLedgerProcessRunNonce('recovery-owner-test');
  ledger.ledgerBegin(runtime.directory, id, { category: 'launch', title: '26.3', gameVersionId: '26.3',
    mcDir: runtime.directory + '/minecraft', gameDir: runtime.directory + '/minecraft' });
  const exit = { schema: 1, activityId: id, pid: 101, parentPid: 100, exitCode: 0,
    source: 'jvm-exit', timestamp: Date.now() - 5000 };
  /** 按指定退出码覆盖本局真实journal输入，其余身份固定，供验证迟到事实与同输入幂等。 */
  const publish = code => runtime.write('game-exits/' + id + '.json', JSON.stringify({ ...exit, exitCode: code }));
  /** 读取owner耐久写出的真实恢复检查点；不以hooks的记录Map作为消费证明。 */
  const state = () => JSON.parse(fs.readFileSync(runtime.directory + '/logs/ledger/' + id + '/launcher/recovery-state.json', 'utf8'));
  let closing;
  /**
   * teardown不启动额外维护：先取消尚未执行的timer并hold，再撤销此临时module的维护owner。
   * Flush入口优先返回已经在途的真实job，所以此处等待其rename/fsync/close完成后才删除目录。
   * 不释放hold，不固定sleep、不重试删除；维护异常仍使测试失败。相同夹具close只执行一次。
   */
  const close = () => {
    if (closing !== undefined) return closing;
    ledger.ledgerBeginMaintenanceBatch(runtime.directory);
    ledger.configureLedgerMaintenanceOwner(false);
    closing = (async () => {
      try { await ledger.ledgerFlushMaintenanceAsync(runtime.directory); }
      finally { runtime.close(); }
    })();
    return closing;
  };
  return { runtime, ledger, counts, records, id, exit, publish, state, makeOwner,
    setIdle(value) { idle = value; }, failHistory(value) { failHistory = value; }, setHistoryHook(value) { historyHook = value; },
    setCommitHook(value) { commitHook = value; },
    close: close };
}

test('恢复夹具teardown等待真实index提交及目录同步结束，不能先删在途维护目录', async () => {
  const f = fixture();
  let entered, release;
  const enteredPromise = new Promise(resolve => { entered = resolve; });
  const releasePromise = new Promise(resolve => { release = resolve; });
  const rename = f.runtime.kitFs.rename;
  let cleanupCalls = 0;
  const remove = f.runtime.close;
  f.runtime.close = () => { cleanupCalls++; return remove(); };
  f.runtime.kitFs.rename = async (from, to) => {
    if (to.endsWith('/index.json')) { entered(); await releasePromise; }
    return rename(from, to);
  };
  const maintenance = f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory);
  try {
    await enteredPromise;
    const closing = f.close();
    assert.equal(f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory), maintenance,
      'hold/非owner之后仍应返回已经在途的真实维护job');
    assert.equal(cleanupCalls, 0); assert.ok(fs.existsSync(f.runtime.directory), '真实rename尚未完成时夹具目录必须存在');
    release(); await closing; await maintenance;
    assert.equal(cleanupCalls, 1); assert.equal(fs.existsSync(f.runtime.directory), false);
    await f.close(); assert.equal(cleanupCalls, 1, 'teardown不重试删除');
  } finally {
    release(); await f.close();
  }
});

test('旧journal实际核验迁移一次；无新义务的普通亮屏不裁决、不封账、不全局发现', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.wake();
    assert.equal(f.counts.end, 1); assert.equal(f.counts.history, 1);
    const [result] = await owner.results(); assert.equal(result.outcome.state, f.ledger.LedgerState.SUCCESS);
    await owner.acknowledgePresentation(f.id, result.revision);
    const manifestPath = f.runtime.directory + '/logs/ledger/' + f.id + '/manifest.json';
    const before = fs.readFileSync(manifestPath);
    const counts = { ...f.counts };
    let fullDiscovery = 0;
    const list = f.runtime.kitFs.listFile;
    f.runtime.kitFs.listFile = async (path, ...args) => {
      if (path.endsWith('/game-exits') || path.endsWith('/logs/ledger')) fullDiscovery++;
      return list(path, ...args);
    };
    for (let i = 0; i < 5; i++) await owner.wake();
    assert.equal(f.counts.end, counts.end); assert.equal(f.counts.platform, counts.platform);
    assert.equal(f.counts.history, counts.history); assert.equal(fullDiscovery, 0);
    assert.deepEqual(fs.readFileSync(manifestPath), before, '亮屏不得刷新旧recoveredAt/终态正文');
    assert.deepEqual(await owner.results(), []);
  } finally { await f.close(); }
});

test('平台Watcher真实发布70份原件，异步队列不归档全账本且不因旧64上限删除', async () => {
  const f = fixture({ imports: {
    '@kit.PerformanceAnalysisKit': { hiAppEvent: { domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH', APP_KILLED: 'APP_KILLED' }, addWatcher() {} } },
    '@kit.AbilityKit': { AbilityConstant: { LastExitReason: { UNKNOWN: 0 } } },
  } });
  try {
    const Watcher = f.runtime.load('entry/src/main/ets/runtime/PlatformDfxWatcher.ets').PlatformDfxWatcher;
    Watcher.start(f.runtime.directory);
    let wakes = 0; Watcher.setRecoveryWake(() => { wakes++; });
    const infos = Array.from({ length: 70 }, (_, index) => ({ params: { time: f.id + index, pid: 101, original: index } }));
    Watcher.persist_('OS', [{ name: 'APP_CRASH', appEventInfos: infos }]);
    await Watcher.flushPending();
    const directory = f.runtime.directory + '/logs/platform-events';
    const events = fs.readdirSync(directory).filter(name => name.startsWith('event-') && name.endsWith('.json'));
    assert.equal(events.length, 70); assert.equal(wakes, 70); assert.equal(f.counts.platform, 0);
    assert.deepEqual(events.map(name => JSON.parse(fs.readFileSync(directory + '/' + name)).params.original).sort((a, b) => a - b),
      Array.from({ length: 70 }, (_, i) => i));
    assert.equal(JSON.parse(fs.readFileSync(directory + '/publication.json')).schema, 1);
  } finally { await f.close(); }
});

test('Index首页真实可见发布同时约束页签、开屏退场和页面hide', () => {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('Index.ets', source, compiler.ScriptTarget.Latest, true);
  const struct = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'onHomeTabVisibilityChanged_'));
  assert.ok(struct);
  const member = struct.members.find(member => member.name?.getText(ast) === 'onHomeTabVisibilityChanged_');
  const compiled = compiler.transpileModule('class Probe {\n' + source.slice(member.getStart(ast), member.end)
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const storage = new Map([['amclHostPageVisible', true]]), module = { exports: {} };
  new Function('module', 'AppStorage', compiled)(module, { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) });
  // 必要准备就绪与开屏视觉退场是两个独立事实；主页的周期性动画只能在退场后恢复。
  // 显式构造ready已成立但动画尚未结束的窗口，防止夹具默认值掩盖提前发布可见的问题。
  const page = new module.exports(); page.currentTab = 0;
  page.launcherStartupReady_ = false; page.startupFinished_ = false;
  page.onHomeTabVisibilityChanged_(); assert.equal(storage.get('amclHomeTabVisible'), false);
  page.launcherStartupReady_ = true; page.onHomeTabVisibilityChanged_();
  assert.equal(storage.get('amclHomeTabVisible'), false, '准备ready不能越过开屏退场门控');
  page.startupFinished_ = true; page.onHomeTabVisibilityChanged_(); assert.equal(storage.get('amclHomeTabVisible'), true);
  page.currentTab = 1; page.onHomeTabVisibilityChanged_(); assert.equal(storage.get('amclHomeTabVisible'), false);
  page.currentTab = 0; storage.set('amclHostPageVisible', false); page.onHomeTabVisibilityChanged_();
  assert.equal(storage.get('amclHomeTabVisible'), false);
  assert.match(source, /@Watch\('onHomeTabVisibilityChanged_'\) currentTab/);
});

test('合法JSON坏结局/游标/队列ID保留原件并抛可见损坏，不能静默消费为空', async () => {
  const f = fixture();
  try {
    f.publish(0); await f.makeOwner().wake();
    const State = f.runtime.load('launch/src/main/ets/SessionRecoveryState.ets');
    const state = f.state(); const session = state.session;
    for (const invalid of [{ outcome: null }, { policy: -1 }, { committedEvidenceRevision: '1' },
      { outcome: { ...state.outcome, source: 12 } }]) {
      const path = f.runtime.write('logs/ledger/' + f.id + '/launcher/recovery-state.json', JSON.stringify({ ...state, ...invalid }));
      const before = fs.readFileSync(path);
      await assert.rejects(() => State.readRecoveryStateAsync(f.runtime.directory, session), /无效/);
      assert.deepEqual(fs.readFileSync(path), before);
    }
    const queuePath = f.runtime.directory + '/logs/recovery/queue.json';
    const queue = JSON.parse(fs.readFileSync(queuePath));
    fs.writeFileSync(queuePath, JSON.stringify({ ...queue, pendingIds: [String(f.id)] }));
    await assert.rejects(() => State.readRecoveryQueueAsync(f.runtime.directory), /身份损坏/);
  } finally { await f.close(); }
});

test('rename后目录同步未知的检查点必须重确认耐久，不能只读可见新字节便消费', async () => {
  const f = fixture();
  try {
    const State = f.runtime.load('launch/src/main/ets/SessionRecoveryState.ets');
    const queue = { schema: 1, activeIds: [], pendingIds: [f.id], resultIds: [], bootstrapIds: [], bootstrapCursor: 0 };
    const sync = f.runtime.kitFs.fsync; let fail = true, directorySyncs = 0;
    f.runtime.kitFs.fsync = async fd => {
      if (fd < 0) { directorySyncs++; if (fail) throw new Error('directory sync failure'); }
      return sync(fd);
    };
    await assert.rejects(() => State.writeRecoveryQueueAsync(f.runtime.directory, queue), /持久化尚未确认/);
    await assert.rejects(() => State.readRecoveryQueueAsync(f.runtime.directory), /directory sync failure/);
    fail = false; assert.deepEqual((await State.readRecoveryQueueAsync(f.runtime.directory)).pendingIds, [f.id]);
    assert.ok(directorySyncs >= 3, '消费可见新字节前必须确实重同步目录');
  } finally { await f.close(); }
});

test('提交await期间新增journal只确认冻结输入，并立即继续裁决新输入', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); let once = true;
    f.setCommitHook(async () => { if (once) { once = false; f.publish(7); } });
    await owner.wake();
    assert.equal(f.counts.end, 2); assert.equal(owner.stats().resolverCalls, 2);
    assert.equal(f.records.get(f.id).outcome.state, f.ledger.LedgerState.FAILED);
    assert.equal(f.state().outcomeRevision, 2);
    const calls = f.counts.end; await owner.wake(); assert.equal(f.counts.end, calls);
  } finally { await f.close(); }
});

test('game-terminal旧成功仍接受迟到精确平台crash，更正不能被生产者终态覆盖', async () => {
  const f = fixture();
  try {
    f.publish(0);
    f.runtime.write('logs/ledger/' + f.id + '/game-terminal.json', JSON.stringify({ schema: 1,
      activityId: f.id, runNonce: 'recovery-owner-test', pid: 101,
      outcome: { state: f.ledger.LedgerState.SUCCESS, source: 'session.jvm-exit', summary: '退出请求0', endedAt: f.exit.timestamp } }));
    const owner = f.makeOwner(); await owner.wake();
    const first = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, first.revision);
    f.runtime.write('logs/platform-events/event-terminal-late.json', JSON.stringify({ name: 'APP_CRASH',
      activityId: f.id, runNonce: 'recovery-owner-test', eventAt: f.exit.timestamp }));
    owner.notifyPlatformPublication(); await owner.wake();
    assert.equal((await owner.results())[0].outcome.state, f.ledger.LedgerState.CRASHED);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.id).outcomeSource, 'platform.APP_CRASH');
  } finally { await f.close(); }
});

test('提交产物Evidence损坏重新打开义务修复；pin变动不触发完整resolver', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.wake();
    const first = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, first.revision);
    const before = f.counts.end;
    const manifestPath = f.runtime.directory + '/logs/ledger/' + f.id + '/manifest.json';
    const manifest = JSON.parse(fs.readFileSync(manifestPath)); manifest.pinned = true;
    fs.writeFileSync(manifestPath, JSON.stringify(manifest));
    await f.makeOwner().wake(); assert.equal(f.counts.end, before, '独立pin元数据不改变业务结果身份');
    f.runtime.write('logs/ledger/' + f.id + '/evidence-manifest.json', '{invalid');
    await f.makeOwner().wake(); assert.equal(f.counts.end, before + 1);
    assert.ok(JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/ledger/' + f.id + '/evidence-manifest.json')).revision > 0);
  } finally { await f.close(); }
});

test('已知待办清单丢失/损坏不得移除pending，也不得宣布恢复为空', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.initialize(); await owner.enqueue(f.id);
    f.runtime.write('logs/ledger/' + f.id + '/manifest.json', '{invalid');
    await assert.rejects(() => owner.wake(), /清单丢失或损坏/);
    const queue = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json'));
    assert.ok(queue.pendingIds.includes(f.id)); assert.equal(owner.stats().retries, 1);
  } finally { await f.close(); }
});

test('旧平台事件未归属后补元信息，无新平台publication仍按真实新输入重试', async () => {
  const f = fixture();
  try {
    f.publish(0);
    const eventPath = f.runtime.write('logs/platform-events/event-unassigned.json', JSON.stringify({ name: 'APP_CRASH',
      activityId: f.id, runNonce: 'corrected-nonce', eventAt: f.exit.timestamp }));
    const owner = f.makeOwner(); await owner.wake(); assert.ok(fs.existsSync(eventPath));
    const manifestPath = f.runtime.directory + '/logs/ledger/' + f.id + '/manifest.json';
    const manifest = JSON.parse(fs.readFileSync(manifestPath)); manifest.runNonce = 'corrected-nonce';
    fs.writeFileSync(manifestPath, JSON.stringify(manifest));
    await owner.enqueue(f.id); await owner.wake();
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.id).state, f.ledger.LedgerState.CRASHED);
    assert.equal(fs.existsSync(eventPath), false);
  } finally { await f.close(); }
});

test('小型输入元数据权限故障不解释为不存在，也不确认消费', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.initialize();
    const stat = f.runtime.kitFs.stat;
    f.runtime.kitFs.stat = async path => {
      if (typeof path === 'string' && path.endsWith('/native-io.json')) throw Object.assign(new Error('access denied'), { code: 13900013 });
      return stat(path);
    };
    await assert.rejects(() => owner.wake(), /access denied/); assert.equal(f.counts.end, 0);
    f.runtime.kitFs.stat = stat; await owner.wake(); assert.equal(f.counts.end, 1);
  } finally { await f.close(); }
});

test('同一owner初始化失败在存储修复后重试；不永久缓存拒绝的bootstrap Promise', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner();
    f.runtime.control.failWrite = path => path.includes('/queue.json.');
    await assert.rejects(() => owner.initialize(), error => error.kind === 'not-committed' && error.published === false);
    f.runtime.control.failWrite = undefined;
    await owner.initialize(); await owner.wake();
    assert.equal(f.state().outcome.state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.counts.end, 1);
  } finally { await f.close(); }
});

/** 外部绝对路径只在SDK IO边界映射到隔离原件，归属、补采和提交均执行生产函数。 */
function delayedReport(f) {
  const source = '/qa-delayed-platform-report', actual = f.runtime.directory + '/delayed-report.log';
  let ready = false;
  const stat = f.runtime.kitFs.stat, open = f.runtime.kitFs.open, copy = f.runtime.kitFs.copyFile;
  f.runtime.kitFs.stat = async path => {
    if (path === source) {
      if (!ready) throw Object.assign(new Error('report not yet produced'), { code: 13900002 });
      return stat(actual);
    }
    return stat(path);
  };
  f.runtime.kitFs.open = async (path, ...args) => open(path === source ? actual : path, ...args);
  f.runtime.kitFs.copyFile = async (path, ...args) => copy(path === source ? actual : path, ...args);
  const path = f.runtime.write('logs/platform-events/event-report-delay.json', JSON.stringify({ name: 'APP_CRASH',
    activityId: f.id, runNonce: 'recovery-owner-test', eventAt: f.exit.timestamp, params: { external_log: [source] } }));
  return { path, ready() { fs.writeFileSync(actual, 'PLATFORM-REPORT-CONTENT'); ready = true; },
    archived: f.runtime.directory + '/logs/ledger/' + f.id + '/system/crash-report-event-report-delay.json-external-0.log' };
}

test('迟到平台外部报告按耐久精确集合补采，普通wake不全局发现且同结局证据更新', async () => {
  const f = fixture();
  try {
    f.publish(0); const report = delayedReport(f), owner = f.makeOwner(); await owner.wake();
    const retryPath = f.runtime.directory + '/logs/platform-events/report-retries.json';
    assert.equal(JSON.parse(fs.readFileSync(retryPath)).entries[0].activityId, f.id);
    await assert.rejects(() => f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id), /读取或导出/);
    const fullCalls = f.counts.platform, original = f.runtime.kitFs.listFile;
    let globalPlatformLists = 0;
    f.runtime.kitFs.listFile = async path => {
      if (path === f.runtime.directory + '/logs/platform-events') globalPlatformLists++;
      return original(path);
    };
    await owner.wake(); await owner.wake();
    assert.equal(f.counts.platform, fullCalls); assert.equal(globalPlatformLists, 0);
    const stateBefore = f.state(), historyBefore = f.counts.history;
    report.ready(); await owner.wake();
    assert.equal(fs.readFileSync(report.archived, 'utf8'), 'PLATFORM-REPORT-CONTENT');
    assert.equal(fs.existsSync(report.path), false);
    assert.equal(JSON.parse(fs.readFileSync(retryPath)).entries.length, 0);
    // 补采保护完成后，实际待展示队列仍有自己的lease；确认本次真实结果后才要求所有lease解除。
    const shown = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, shown.revision);
    assert.equal(f.runtime.load('commons/src/main/ets/utils/EvidenceIo.ets').hasEvidenceLease(f.runtime.directory, f.id), false);
    assert.equal(f.counts.platform, fullCalls); assert.equal(globalPlatformLists, 0);
    assert.equal(f.state().outcomeRevision, stateBefore.outcomeRevision);
    assert.equal(f.counts.history, historyBefore);
    assert.ok(f.state().committedEvidenceRevision > stateBefore.committedEvidenceRevision);
  } finally { await f.close(); }
});

test('平台补采义务可冷boot重建，耐久未知或损坏索引不能被读成空并消费原件', async () => {
  const f = fixture();
  try {
    f.publish(0); const report = delayedReport(f); await f.makeOwner().wake();
    const retryPath = f.runtime.directory + '/logs/platform-events/report-retries.json';
    fs.unlinkSync(retryPath); const owner = f.makeOwner(); await owner.wake();
    assert.equal(JSON.parse(fs.readFileSync(retryPath)).entries.length, 1);
    const original = fs.readFileSync(retryPath);
    fs.writeFileSync(retryPath, JSON.stringify({ schema: 1, entries: [{ name: '../other', activityId: f.id, runNonce: '' }] }));
    await assert.rejects(() => owner.wake(), /平台补采身份无效/);
    assert.equal(fs.existsSync(report.path), true);
    fs.writeFileSync(retryPath, original); report.ready(); await owner.wake();
    assert.equal(fs.existsSync(report.archived), true);
  } finally { await f.close(); }
});

test('平台补采索引发布后目录同步未知须先重同步，修复后同owner继续补采', async () => {
  const f = fixture();
  try {
    f.publish(0); const report = delayedReport(f), owner = f.makeOwner();
    const rename = f.runtime.kitFs.rename, sync = f.runtime.kitFs.fsync;
    let retryPublished = false, failSync = true, resyncs = 0;
    f.runtime.kitFs.rename = async (from, to) => {
      await rename(from, to); if (to.endsWith('/report-retries.json')) retryPublished = true;
    };
    f.runtime.kitFs.fsync = async fd => {
      if (fd < 0 && retryPublished) { resyncs++; if (failSync) throw new Error('retry directory sync failed'); }
      return sync(fd);
    };
    await assert.rejects(() => owner.wake(), error => error.kind === 'durability-unknown');
    await assert.rejects(() => f.ledger.retryPlatformEventFilesAsync(f.runtime.directory), /retry directory sync failed/);
    assert.equal(fs.existsSync(report.path), true);
    failSync = false; report.ready(); await owner.wake();
    assert.equal(fs.existsSync(report.archived), true); assert.ok(resyncs >= 3);
  } finally { await f.close(); }
});

test('cold显式恢复平台补采租约只读小索引，缺失正常、EIO/坏身份失败关闭且保护原件', async () => {
  const f = fixture(), cold = evidenceRuntime();
  try {
    const ledger = cold.load(ledgerPath), io = cold.load('commons/src/main/ets/utils/EvidenceIo.ets');
    ledger.configureLedgerMaintenanceOwner(true, () => true);
    cold.kitFs.listFile = async () => { throw new Error('restore不得枚举平台事件或全部账本'); };
    await ledger.restorePlatformReportProtectionAsync(f.runtime.directory);
    assert.equal(io.hasEvidenceLease(f.runtime.directory, f.id), false);
    f.publish(0); const report = delayedReport(f); await f.makeOwner().wake();
    const retryPath = f.runtime.directory + '/logs/platform-events/report-retries.json';
    const original = fs.readFileSync(retryPath);
    const stat = cold.kitFs.stat;
    cold.kitFs.stat = async path => {
      if (path === retryPath) throw Object.assign(new Error('restore EIO'), { code: 13900005 });
      return stat(path);
    };
    await assert.rejects(() => ledger.restorePlatformReportProtectionAsync(f.runtime.directory), /restore EIO/);
    assert.deepEqual(fs.readFileSync(retryPath), original);
    cold.kitFs.stat = stat;
    fs.writeFileSync(retryPath, JSON.stringify({ schema: 1, entries: [{ name: 'event-bad.json', activityId: String(f.id), runNonce: '' }] }));
    await assert.rejects(() => ledger.restorePlatformReportProtectionAsync(f.runtime.directory), /平台补采身份无效/);
    fs.writeFileSync(retryPath, original);
    await ledger.restorePlatformReportProtectionAsync(f.runtime.directory);
    await ledger.restorePlatformReportProtectionAsync(f.runtime.directory);
    assert.equal(io.hasEvidenceLease(f.runtime.directory, f.id), true);
    await assert.rejects(() => ledger.ledgerRemoveAsync(f.runtime.directory, f.id), /读取或导出/);
    assert.equal(fs.existsSync(report.path), true);
  } finally { cold.close(); await f.close(); }
});

test('父派发失败先耐久保留原文，仅撤回匹配token且无canonical/producer的空闲意图', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(), id = f.id + 1, token = 'dispatch-test-token';
    await owner.trackLaunch(id, token);
    f.runtime.control.failWrite = path => path.includes('/dispatch-failures/');
    await assert.rejects(() => owner.recordLaunchDispatchFailure(id, token, 'startAbility', 'permission denied'),
      error => error.kind === 'not-committed' && error.published === false);
    assert.ok(JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json')).activeIds.includes(id));
    f.runtime.control.failWrite = undefined;
    assert.equal(await owner.recordLaunchDispatchFailure(id, 'another-token', 'startAbility', 'wrong receipt'), false);
    f.setIdle(false);
    assert.equal(await owner.recordLaunchDispatchFailure(id, token, 'startAbility', 'permission denied'), false);
    f.setIdle(true);
    assert.equal(await owner.recordLaunchDispatchFailure(id, token, 'startAbility', 'permission denied'), true);
    assert.ok(!JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json')).activeIds.includes(id));
    assert.equal(fs.existsSync(f.runtime.directory + '/logs/ledger/' + id + '/manifest.json'), false);
    const receipt = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/dispatch-failures/' + id + '-' + token + '.json'));
    assert.equal(receipt.rawError, 'permission denied');
    await assert.rejects(() => owner.recordLaunchDispatchFailure(id, token, 'startAbility', 'another failure'), /双方原文已保留/);
    const failures = fs.readdirSync(f.runtime.directory + '/logs/recovery/dispatch-failures')
      .filter(name => name.startsWith(id + '-' + token));
    assert.equal(failures.length, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/dispatch-failures/' + id + '-' + token + '.json')).rawError,
      'permission denied'); await owner.wake();
    // 已有账本即使内容损坏也不能通过null读取被认作“从未建立”。
    await owner.trackLaunch(f.id, token);
    assert.equal(await owner.recordLaunchDispatchFailure(f.id, token, 'pushUrl', 'route failure'), false);
    await owner.wake(); // 真实退出journal补完同owner已登记的旧会话准入，下一新ID不能跨未结束的reservations。
    const emptyId = id + 1; await owner.trackLaunch(emptyId, token);
    f.runtime.write('logs/ledger/' + emptyId + '/manifest.json', '');
    await assert.rejects(() => owner.recordLaunchDispatchFailure(emptyId, token, 'pushUrl', 'empty baseline'), /恢复协调记录损坏/);
    assert.ok(JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json')).activeIds.includes(emptyId));
  } finally { await f.close(); }
});

test('父错误已保存但队列撤回失败，下次同owner wake只补撤回；迟到marker可重新恢复', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(), id = f.id + 1, token = 'dispatch-retry-token';
    await owner.trackLaunch(id, token);
    f.runtime.control.failWrite = path => path.includes('/queue.json.');
    await assert.rejects(() => owner.recordLaunchDispatchFailure(id, token, 'pushUrl', 'route rejected'),
      error => error.kind === 'not-committed');
    f.runtime.control.failWrite = undefined; await owner.wake();
    assert.ok(!JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json')).activeIds.includes(id));
    // marker协议真实文件名由生产SessionMarker决定，直接调用其写入口形成迟到事实。
    const Marker = f.runtime.load('launch/src/main/ets/SessionMarker.ets').SessionMarker;
    assert.equal(Marker.writeStart(f.runtime.directory, 'late-child', f.runtime.directory + '/minecraft', id), id);
    await owner.wake(); assert.notEqual(f.ledger.ledgerManifest(f.runtime.directory, id), null);
  } finally { await f.close(); }
});

test('同大小退出发布改写重新消费输入；新进程复用耐久检查点不重复恢复', async () => {
  const f = fixture();
  try {
    const raw = f.publish(0), owner = f.makeOwner(); await owner.wake();
    const originalBytes = fs.statSync(raw).size;
    const first = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, first.revision);
    f.publish(7); assert.equal(fs.statSync(raw).size, originalBytes);
    await owner.enqueue(f.id); await owner.wake();
    assert.equal(f.counts.end, 2); assert.equal(f.records.get(f.id).outcome.state, f.ledger.LedgerState.FAILED);
    const second = (await owner.results())[0]; assert.equal(second.revision, first.revision + 1);
    await owner.acknowledgePresentation(f.id, second.revision);
    const endCalls = f.counts.end; await f.makeOwner().wake();
    assert.equal(f.counts.end, endCalls, '冷启动输入一致时只复核小型发布记录');
  } finally { await f.close(); }
});

test('历史持久失败不确认历史/展示；重启只补投影且原生原件保留', async () => {
  const f = fixture();
  try {
    const raw = f.publish(0); f.failHistory(true);
    await assert.rejects(() => f.makeOwner().wake(), /history disk failure/);
    assert.equal(f.state().outcomeRevision, 1); assert.equal(f.state().historyRevision, 0);
    assert.equal(f.state().presentationRevision, 0); assert.ok(fs.existsSync(raw));
    const before = f.counts.end; f.failHistory(false); const restarted = f.makeOwner(); await restarted.wake();
    assert.equal(f.counts.end, before); assert.equal(f.state().historyRevision, 1);
    assert.equal((await restarted.results()).length, 1);
  } finally { await f.close(); }
});

test('恢复期间同ID新增发布不会被旧singleflight清走；旧展示确认不能覆盖新失败结果', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner();
    let entered, release;
    const enteredPromise = new Promise(resolve => { entered = resolve; });
    const releasePromise = new Promise(resolve => { release = resolve; });
    let once = true;
    f.setHistoryHook(async () => { if (once) { once = false; entered(); await releasePromise; } });
    const running = owner.wake(); await enteredPromise;
    f.publish(7); await owner.enqueue(f.id); release(); await running;
    const [result] = await owner.results();
    assert.equal(result.outcome.state, f.ledger.LedgerState.FAILED); assert.equal(result.revision, 2);
    await owner.acknowledgePresentation(f.id, 1);
    assert.equal((await owner.results())[0].revision, 2); assert.equal(f.state().presentationRevision, 1);
    await owner.acknowledgePresentation(f.id, 2); assert.deepEqual(await owner.results(), []);
  } finally { await f.close(); }
});

test('marker必须先耐久入队；队列写失败保留原marker，成功后只清同身份', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.initialize();
    const marker = f.runtime.write('mc_running.flag', JSON.stringify({ startedAt: f.id, version: '26.3', mcDir: '/mc' }));
    f.runtime.control.failWrite = (path, mode) => path.includes('/queue.json') && (mode & 64) !== 0;
    await assert.rejects(() => owner.wake()); assert.ok(fs.existsSync(marker));
    f.runtime.control.failWrite = undefined; await owner.wake(); assert.equal(fs.existsSync(marker), false);
    const Marker = f.runtime.load('launch/src/main/ets/SessionMarker.ets').SessionMarker;
    f.runtime.write('mc_running.flag', JSON.stringify({ startedAt: f.id + 1, version: 'next', mcDir: '/next' }));
    await Marker.clearMatchingAsync(f.runtime.directory, { startedAt: f.id, version: '26.3', mcDir: '/mc' });
    assert.ok(fs.existsSync(marker));
  } finally { await f.close(); }
});

test('迟到平台crash更正已展示成功；新系统证据不能被旧成功回执遮蔽', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.wake();
    const first = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, first.revision);
    const event = { schema: 1, name: 'APP_CRASH', activityId: f.id, runNonce: 'recovery-owner-test',
      eventAt: f.exit.timestamp, params: { pid: 101 } };
    f.runtime.write('logs/platform-events/event-late.json', JSON.stringify(event));
    f.runtime.write('logs/platform-events/publication.json', JSON.stringify({ schema: 1, publication: 'late' }));
    await owner.wake();
    const [crash] = await owner.results(); assert.equal(crash.outcome.state, f.ledger.LedgerState.CRASHED);
    assert.equal(crash.outcome.source, 'platform.APP_CRASH'); assert.equal(crash.revision, 2);
    assert.equal(f.records.get(f.id).outcome.state, f.ledger.LedgerState.CRASHED);
  } finally { await f.close(); }
});

test('本局全文准备后游戏锁重新活跃则拒绝提交，下一次明确空闲可恢复原待办', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.initialize();
    const read = f.runtime.kitFs.readText; let exitReads = 0;
    f.runtime.kitFs.readText = async path => {
      const value = await read(path);
      // 第一遍冻结inputKey，第二遍由真实resolver读取退出事实；此时模拟新游戏取得锁。
      if (path.endsWith('/game-exits/' + f.id + '.json') && ++exitReads === 2) f.setIdle(false);
      return value;
    };
    await assert.rejects(() => owner.wake(), /重新活跃或状态未知/);
    assert.equal(f.counts.end, 0); assert.equal(owner.stats().staleRejected, 1);
    f.setIdle(true); f.runtime.kitFs.readText = read; await owner.wake(); assert.equal(f.counts.end, 1);
  } finally { await f.close(); }
});

test('同一crash结局的新平台原件仍消费并提交证据，但不重复历史或展示', async () => {
  const f = fixture();
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.wake();
    const success = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, success.revision);
    const payload = JSON.stringify({ name: 'APP_CRASH', activityId: f.id, runNonce: 'recovery-owner-test', eventAt: f.exit.timestamp });
    f.runtime.write('logs/platform-events/event-first-crash.json', payload);
    owner.notifyPlatformPublication(); await owner.wake();
    const crash = (await owner.results())[0]; await owner.acknowledgePresentation(f.id, crash.revision);
    const before = f.state(), counts = { ...f.counts };
    f.runtime.write('logs/platform-events/event-second-crash.json', payload);
    owner.notifyPlatformPublication(); await owner.wake();
    const after = f.state();
    assert.notEqual(after.inputKey, before.inputKey); assert.ok(after.committedEvidenceRevision > before.committedEvidenceRevision);
    assert.ok(f.counts.end > counts.end); assert.equal(f.counts.history, counts.history);
    assert.equal(after.outcomeRevision, before.outcomeRevision); assert.deepEqual(await owner.results(), []);
  } finally { await f.close(); }
});

test('仅有旧marker没有账本时先建立legacy身份再清marker，结局保持证据不足', async () => {
  const f = fixture();
  try {
    const oldId = f.id + 1;
    const marker = f.runtime.write('mc_running.flag', JSON.stringify({ startedAt: oldId, version: 'legacy', mcDir: '/old-root' }));
    const owner = f.makeOwner(); await owner.wake();
    assert.equal(fs.existsSync(marker), false);
    const manifest = f.ledger.ledgerManifest(f.runtime.directory, oldId);
    assert.equal(manifest.category, 'launch'); assert.equal(manifest.gameVersionId, 'legacy');
    assert.equal(manifest.state, f.ledger.LedgerState.INTERRUPTED);
    assert.match(manifest.outcomeSummary, /不可用|不完整|无法/);
    assert.equal(f.records.get(oldId).session.version, 'legacy');
  } finally { await f.close(); }
});

test('既有游戏失败队列先耐久交接，历史写失败保留原件，重试后canonical/历史同ID完成', async () => {
  let failHistory = true; const records = new Map(); const imports = {
    feature_core: { ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { FAILED: 'failed', CRASHED: 'crashed' },
      getDownloadHistoryStore: () => ({ init: async () => {}, upsertLaunchSession: async record => {
        if (failHistory) throw new Error('history failed'); records.set(record.startedAt, record);
      } }) }
  };
  const f = fixture({ imports });
  try {
    imports.launch = f.runtime.load('launch/src/main/ets/SessionRecoveryState.ets');
    const Results = f.runtime.load('entry/src/main/ets/runtime/DesktopGameResults.ets').DesktopGameResults;
    const record = { startedAt: f.id, versionName: '26.3', gameVersion: '26.3', category: 'launch', status: 'failed',
      durationMs: 1000, endedAt: f.id + 1000, totalBytes: 0, fileCount: 0, loaderType: 'launch', errorMessage: '准备失败' };
    await Results.queue(f.runtime.context, record);
    const raw = f.runtime.directory + '/desktop-results/' + f.id + '.json';
    assert.equal(JSON.parse(fs.readFileSync(raw)).producerPid, 101);
    await assert.rejects(() => Results.importPending(f.runtime.context), /history failed/);
    assert.ok(fs.existsSync(raw)); assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.id).state, f.ledger.LedgerState.FAILED);
    failHistory = false; await Results.importPending(f.runtime.context);
    assert.equal(fs.existsSync(raw), false); assert.equal(records.size, 1); assert.deepEqual(Results.takeCommittedIds(), [f.id]);
  } finally { await f.close(); }
});

test('游戏失败队列错误PID/nonce原文保留，不能把别局失败写入本局', async () => {
  const imports = { feature_core: { ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { FAILED: 'failed' },
    getDownloadHistoryStore: () => ({ init: async () => {}, upsertLaunchSession: async () => assert.fail('错误身份不能写历史') }) } };
  const f = fixture({ imports });
  try {
    imports.launch = f.runtime.load('launch/src/main/ets/SessionRecoveryState.ets');
    const Results = f.runtime.load('entry/src/main/ets/runtime/DesktopGameResults.ets').DesktopGameResults;
    const raw = f.runtime.write('desktop-results/' + f.id + '.json', JSON.stringify({ schema: 2,
      activityId: f.id, producerPid: 999, runNonce: 'other', record: { startedAt: f.id,
        versionName: '26.3', gameVersion: '26.3', category: 'launch', status: 'failed' } }));
    await assert.rejects(() => Results.importPending(f.runtime.context), /PID\/nonce/);
    assert.ok(fs.existsSync(raw)); assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.id).state, f.ledger.LedgerState.RUNNING);
  } finally { await f.close(); }
});

test('McGamePage失败保存未完成不置recorded，原始交接保留且相同事实可以retry', async () => {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/McGamePage.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('McGamePage.ets', source, compiler.ScriptTarget.Latest, true);
  const struct = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'recordLaunchFailure_'));
  const method = struct.members.find(member => member.name?.getText(ast) === 'recordLaunchFailure_');
  const compiled = compiler.transpileModule('class Probe {\n' + source.slice(method.getStart(ast), method.end)
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const f = fixture();
  try {
    let journalWrites = 0, historyWrites = 0, failCommit = true;
    const module = { exports: {} }, values = { ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { FAILED: 'failed' },
      LedgerState: f.ledger.LedgerState, DesktopGameResults: { queue: async () => { journalWrites++; } },
      ledgerManifestAsync: f.ledger.ledgerManifestAsync, ledgerBeginAsync: f.ledger.ledgerBeginAsync,
      ledgerEndAsync: async (...args) => { if (failCommit) throw new Error('owner busy/storage failure'); return f.ledger.ledgerEndAsync(...args); },
      enrichSessionEnvironment: (_context, _id, meta) => meta,
      ActivityLogger: class { error() {} }, LOG_DOMAIN_LAUNCH: 0, TAG: 'test', AppStorage: { get: () => false },
      getDownloadHistoryStore: () => ({ init: async () => {}, upsertLaunchSession: async () => { historyWrites++; } }) };
    new Function('module', ...Object.keys(values), compiled)(module, ...Object.values(values));
    const page = new module.exports(); page.context = f.runtime.context; page.launchStartedAt_ = f.id; page.mcDir = '/mc';
    page.launchRecorded_ = false; page.launchLogger_ = () => ({ warn() {} }); page.applicationFilesDir_ = () => f.runtime.directory;
    assert.equal(await page.recordLaunchFailure_('26.3', '真实准备失败'), false);
    assert.equal(page.launchRecorded_, false); assert.equal(journalWrites, 1); assert.equal(historyWrites, 0);
    failCommit = false; assert.equal(await page.recordLaunchFailure_('26.3', '真实准备失败'), true);
    assert.equal(page.launchRecorded_, true); assert.equal(historyWrites, 1);
    assert.equal(await page.recordLaunchFailure_('26.3', '真实准备失败'), true); assert.equal(journalWrites, 2);
  } finally { await f.close(); }
});

/** 以正式完整旧recover方法作反控；AST只确定替换边界，不重写旧业务或缩减其原件检查。 */
function legacyRecover(absolute, source) {
  if (!absolute.endsWith('SessionRecoveryCoordinator.ets')) return source;
  const saved = JSON.parse(fs.readFileSync(new URL('./fixtures/session-recovery-scheduling-legacy.json', import.meta.url), 'utf8'));
  const method = saved.methods.find(value => value.name === 'recover_');
  assert.equal(createHash('sha256').update(method.originalMethod).digest('hex'), method.sha256);
  const ast = compiler.createSourceFile(coordinatorPath, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.name?.text === 'SessionRecoveryCoordinator');
  const member = owner.members.find(node => node.name?.text === 'recover_');
  return "import { ledgerNextLaunchAtAsync } from 'commons';\n" + source.slice(0, member.getStart(ast))
    + method.originalMethod + source.slice(member.end);
}

test('来源发现期间真实新身份及同大小latest改写推进边界，旧完整recover反控会归入新游戏正文', async () => {
  for (const old of [false, true]) {
    const f = fixture({ transform: old ? legacyRecover : undefined });
    try {
      f.exit.timestamp = Date.now() - 100; f.publish(0);
      f.runtime.write('minecraft/logs/latest.log', 'OLD GAME BODY\nStopping!\n');
      const owner = f.makeOwner(); await owner.initialize();
      const list = f.runtime.kitFs.listFile; let injected = false;
      const newId = Date.now(), foreign = 'NEW GAME BODY\nStopping!\n';
      f.runtime.kitFs.listFile = async path => {
        if (!injected && path === f.runtime.directory + '/minecraft/logs') {
          injected = true;
          // 非admitted发布模拟外部来源/身份到达；两次锁都为空，只有持久身份世代可拒绝旧准备。
          f.ledger.ledgerBegin(f.runtime.directory, newId, { category: 'launch', title: 'new-game',
            mcDir: f.runtime.directory + '/minecraft', gameDir: f.runtime.directory + '/minecraft' });
          f.runtime.write('minecraft/logs/latest.log', foreign);
          await owner.enqueue(newId);
        }
        return list(path);
      };
      await owner.wake(); assert.equal(injected, true);
      const target = f.runtime.directory + '/logs/ledger/' + f.id + '/game/logs/latest.log';
      if (old) assert.equal(fs.readFileSync(target, 'utf8'), foreign, '旧生产方法必须实际触发错误归属，反控不能假造失败');
      else {
        assert.equal(fs.existsSync(target), false, '新世代在任何mutable目标发布前拒绝旧候选');
        assert.ok(owner.stats().staleRejected > 0);
        assert.equal(f.records.get(f.id).outcome.state, f.ledger.LedgerState.SUCCESS, '精确旧JVM事实仍可独立裁决');
      }
    } finally { await f.close(); }
  }
});

test('真实native rename在途时新启动意图先失效旧准备但准入Promise不兑现，全部发布settled后才能新写源', async () => {
  const f = fixture(); let release;
  const released = new Promise(resolve => { release = resolve; });
  let entered; const atRename = new Promise(resolve => { entered = resolve; });
  let running, admission;
  try {
    f.publish(0); const owner = f.makeOwner(); await owner.prepareColdAdmission();
    const rename = f.runtime.kitFs.rename; let once = true;
    f.runtime.kitFs.rename = async (from, to) => {
      if (once && to === f.runtime.directory + '/logs/ledger/' + f.id + '/manifest.json') {
        once = false; entered(); await released;
      }
      return rename(from, to);
    };
    running = owner.wake(); await atRename;
    let boundaryPublished; const published = new Promise(resolve => { boundaryPublished = resolve; });
    const observe = owner.observeIntent_;
    owner.observeIntent_ = (...args) => { const result = observe.apply(owner, args); boundaryPublished(); return result; };
    let admitted = false;
    const newId = Date.now();
    admission = owner.trackLaunch(newId, 'rename-admission').then(() => { admitted = true; });
    await published;
    // 再等真实queue持久门结束；这里不是时间猜测，track已经把新边界发布到owner。
    await owner.gate_;
    assert.equal(admitted, false); assert.equal(owner.stats().transactionActive, true);
    release();
    await assert.rejects(() => running, error => error.published === true && error.kind === 'durability-unknown');
    await assert.rejects(() => admission, error => error.published === true && error.kind === 'durability-unknown');
    assert.equal(admitted, false, '必要wake发布失败不能被准入屏障吞成成功');
    assert.ok(JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json')).pendingIds.includes(f.id));
    assert.equal(fs.existsSync(f.runtime.directory + '/logs/ledger/' + f.id + '/launcher/recovery-state.json'), false,
      'rename已发布的未知候选保留，但旧输入不得签消费检查点');
    await owner.trackLaunch(newId, 'rename-admission');
    assert.equal(owner.grantedLaunches_.has(newId), true, '同token显式重试完成新的边界/持久保护后才允许新writer');
    f.runtime.write('minecraft/logs/latest.log', 'new writer begins only after actual admission');
  } finally {
    release(); await running?.catch(() => {}); await admission?.catch(() => {}); await f.close();
  }
});

test('既有ended无exit的sealed采集边界不随迁移时间移动，真实JVM终点可升级但损坏原件不重签', async () => {
  const f = fixture();
  try {
    const endedAt = f.id + 1000;
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'old ended', endedAt });
    const scoped = f.runtime.write('logs/ledger/' + f.id + '/game/logs/latest.log', 'owned old\nStopping!\n');
    const capturePath = f.runtime.directory + '/logs/ledger/' + f.id + '/capture-sources.json';
    const plan = JSON.parse(fs.readFileSync(capturePath));
    plan.endedAt = endedAt;
    plan.sources = plan.sources.filter(item => item.destination !== 'game/logs/latest.log');
    plan.sources.push({ source: scoped, destination: 'game/logs/latest.log', baseline: '', captured: '',
      state: 'complete', reason: '', attribution: 'exact', mode: 'owned', sealed: true,
      capturedBytes: fs.statSync(scoped).size, capturedSha256: createHash('sha256').update(fs.readFileSync(scoped)).digest('hex') });
    fs.writeFileSync(capturePath, JSON.stringify(plan));
    const Resolver = f.runtime.load('launch/src/main/ets/SessionOutcomeResolver.ets');
    const before = fs.readFileSync(capturePath);
    for (let i = 0; i < 2; i++) {
      const result = await Resolver.prepareRecoveredSessionOutcome(f.runtime.directory, f.id, 0);
      assert.equal(result.endedAt, endedAt); assert.deepEqual(fs.readFileSync(capturePath), before);
    }
    f.publish(0); await Resolver.prepareRecoveredSessionOutcome(f.runtime.directory, f.id, 0);
    let next = JSON.parse(fs.readFileSync(capturePath)); assert.equal(next.endedAt, f.exit.timestamp);
    const expected = next.sources.find(item => item.destination === 'game/logs/latest.log').capturedSha256;
    fs.writeFileSync(scoped, 'owned bad\nStopping!\n');
    await Resolver.prepareRecoveredSessionOutcome(f.runtime.directory, f.id, 0);
    next = JSON.parse(fs.readFileSync(capturePath)); const saved = next.sources.find(item => item.destination === 'game/logs/latest.log');
    assert.equal(saved.capturedSha256, expected); assert.equal(saved.state, 'partial'); assert.match(saved.reason, /归档收据/);
  } finally { await f.close(); }
});

test('bootstrap第二批真实读取故障不推进16项游标，重建owner只续作末批且不重写前批确认', async () => {
  const f = fixture();
  try {
    for (let index = 0; index < 32; index++) {
      const id = f.id + index;
      if (index > 0) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'batch-' + index });
      f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'done' });
    }
    const stat = f.runtime.kitFs.stat; let failed = false;
    f.runtime.kitFs.stat = async path => {
      if (!failed && path.endsWith('/' + (f.id + 16) + '/launcher/recovery-state.json')) {
        failed = true; throw Object.assign(new Error('second batch IO failure'), { code: 13900005 });
      }
      return stat(path);
    };
    await assert.rejects(() => f.makeOwner().initialize(), /second batch IO failure/);
    const queuePath = f.runtime.directory + '/logs/recovery/queue.json';
    const queue = JSON.parse(fs.readFileSync(queuePath)); assert.equal(queue.bootstrapCursor, 16); assert.equal(queue.pendingIds.length, 16);
    const rename = f.runtime.kitFs.rename; let publishes = 0;
    f.runtime.kitFs.rename = async (from, to) => { const value = await rename(from, to); if (to === queuePath) publishes++; return value; };
    await f.makeOwner().initialize(); assert.equal(publishes, 2, '只提交未完成的第二批和最终清游标，不重新确认首批');
    const resumed = JSON.parse(fs.readFileSync(queuePath)); assert.equal(resumed.pendingIds.length, 32); assert.equal(resumed.bootstrapCursor, 0);
  } finally { await f.close(); }
});

test('真实128局首次ended迁移的浏览准入零resolver与原件提交，后台完整消费128局且不伪写shown/自动Sheet', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerBeginMaintenanceBatch(f.runtime.directory);
    const ids = Array.from({ length: 128 }, (_, index) => f.id + index * 10);
    for (const id of ids) {
      if (id !== f.id) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'history-' + id });
      f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.INTERRUPTED,
        source: 'session.full-evidence', summary: 'legacy unknown', endedAt: id + 1 });
      f.runtime.write('game-exits/' + id + '.json', JSON.stringify({ ...f.exit, activityId: id, timestamp: id + 1 }));
    }
    let rootLists = 0, queueWrites = 0;
    const list = f.runtime.kitFs.listFile, rename = f.runtime.kitFs.rename;
    f.runtime.kitFs.listFile = async path => { if (path === f.runtime.directory + '/logs/ledger') rootLists++; return list(path); };
    f.runtime.kitFs.rename = async (from, to) => { const value = await rename(from, to);
      if (to === f.runtime.directory + '/logs/recovery/queue.json') queueWrites++; return value; };
    f.runtime.control.cryptoUpdates.length = 0;
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
    assert.equal(owner.stats().resolverCalls, 0); assert.equal(owner.stats().consumed, 0); assert.equal(f.counts.end, 0);
    assert.equal(rootLists, 1, '只做一次身份发现；无平台原件时不展开候选库，不逐历史展开全文');
    assert.equal(f.runtime.control.cryptoUpdates.length, 0, '浏览准入不SHA所有ended原件/producer');
    assert.equal(queueWrites, 10); assert.equal(owner.stats().historyPending, 128); assert.deepEqual(await owner.results(), []);
    await owner.backgroundMigration();
    assert.equal(owner.stats().historyPending, 0); assert.equal(owner.stats().consumed, 128); assert.equal(f.records.size, 128);
    assert.deepEqual(await owner.results(), []);
    for (const id of ids) {
      const state = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/ledger/' + id + '/launcher/recovery-state.json'));
      assert.equal(state.presentationMode, 'history'); assert.equal(state.presentationRevision, 0); assert.equal(state.historyRevision, 1);
      assert.equal(fs.existsSync(f.runtime.directory + '/logs/ledger/' + id + '/jvm/recovery.json'), false);
      assert.ok(fs.existsSync(f.runtime.directory + '/game-exits/' + id + '.json'));
    }
    console.info(JSON.stringify({ scenario: 'production-first128-split', recovery: owner.stats(), rootLists, queueWrites }));
    // 真实新producer必须升级自动义务；旧history标记不能永久遮蔽新失败。
    f.publish(7); await owner.enqueue(f.id); await owner.wake();
    const [result] = await owner.results(); assert.equal(result.session.startedAt, f.id); assert.equal(result.outcome.state, f.ledger.LedgerState.FAILED);
    assert.equal(f.state().presentationMode, 'auto');
  } finally { await f.close(); }
});

test('历史迁移已提交结局但投影故障保留history义务，下一cold浏览仍准入且只补真实投影', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); f.failHistory(true);
    await assert.rejects(() => owner.backgroundMigration(), /history disk failure/);
    const committed = f.state(), calls = f.counts.end;
    assert.equal(committed.presentationMode, 'history'); assert.equal(committed.historyRevision, 0);
    const resumed = f.makeOwner(); await resumed.prepareColdAdmission(); await resumed.wake();
    assert.equal(resumed.stats().pending, 0); assert.equal(resumed.stats().historyPending, 1); assert.equal(f.counts.end, calls);
    f.failHistory(false); await resumed.backgroundMigration();
    assert.equal(f.counts.end, calls); assert.equal(f.records.size, 1); assert.deepEqual(await resumed.results(), []);
  } finally { await f.close(); }
});

test('浏览已准入的三局历史不阻游戏，track只保护最近mutable来源并在游戏准入/未知期间暂停其余后台事务', async () => {
  const f = fixture();
  try {
    for (let index = 0; index < 3; index++) {
      const id = f.id + index;
      if (index > 0) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'history-' + index });
      f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'ended' });
    }
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
    assert.equal(owner.stats().historyPending, 3); assert.equal(f.counts.end, 0);
    const newId = Date.now(), token = 'separate-game-admission';
    await owner.trackLaunch(newId, token);
    assert.equal(owner.stats().consumed, 1); assert.equal(owner.stats().historyPending, 2); assert.ok(f.records.has(f.id + 2));
    assert.equal(f.records.has(f.id), false); assert.deepEqual(await owner.results(), []);
    await owner.backgroundMigration(); assert.equal(owner.stats().consumed, 1, '准入游戏从未释放时不能开始下一历史事务');
    assert.equal(await owner.recordLaunchDispatchFailure(newId, token, 'startAbility', 'fixture rejected before baseline'), true);
    f.setIdle(false); await owner.backgroundMigration(); assert.equal(owner.stats().historyPending, 2);
    f.setIdle(true); await owner.backgroundMigration(); assert.equal(owner.stats().historyPending, 0); assert.equal(f.records.size, 3);
  } finally { await f.close(); }
});

test('仅有未派发intent的实际准入互斥允许旧mutable日志保护，移除传参反控会在开始新游戏前漏原件', async () => {
  for (const old of [false, true]) {
    const f = fixture({ transform: (absolute, source) => {
      if (!old || !absolute.endsWith('SessionOutcomeResolver.ets')) return source;
      const call = 'platformEnd || initialExit !== undefined || exactManifestEnd, protectedIntentBoundary);';
      assert.equal(source.split(call).length, 2);
      return source.replace(call, 'platformEnd || initialExit !== undefined || exactManifestEnd, false);');
    } });
    try {
      f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
        source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
      const original = 'last mutable game body\nStopping!\n'; f.runtime.write('minecraft/logs/latest.log', original);
      const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
      await owner.trackLaunch(Date.now(), 'protected-mutable-intent');
      const target = f.runtime.directory + '/logs/ledger/' + f.id + '/game/logs/latest.log';
      if (old) assert.equal(fs.existsSync(target), false, '旧墙钟条件实际漏掉尚未被新游戏覆盖的最新原件');
      else assert.equal(fs.readFileSync(target, 'utf8'), original, '派发前保护必须真实保存旧来源，不能只成功写结局');
    } finally { await f.close(); }
  }
});

test('真实Runtime浏览返回时history仍在途且维护hold保留，背景完成后才实际flush并输出idle计量', async () => {
  let resolveEntered, release;
  const entered = new Promise(resolve => { resolveEntered = resolve; }), released = new Promise(resolve => { release = resolve; });
  const history = new Map(), logs = [], imports = {
    'libentry.so': { default: { mcIsRunning: () => false, desktopGameProcessState: () => 0 } },
    feature_core: { ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { SUCCESS: 'success', FAILED: 'failed', CRASHED: 'crashed', ABORTED: 'aborted' },
      getDownloadHistoryStore: () => ({ init: async () => {}, upsertLaunchSession: async record => { history.set(record.startedAt, record); } }) },
    '@kit.PerformanceAnalysisKit': { hiAppEvent: { domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH', APP_KILLED: 'APP_KILLED' }, addWatcher() {} } },
  };
  const f = fixture({ imports, commons: { AppLogger: { info: (...args) => logs.push(args), warn() {}, error() {} } } });
  let migration;
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    imports.launch = { ...f.runtime.load(recoveryStatePath), ...f.runtime.load(coordinatorPath) };
    const Runtime = f.runtime.load('entry/src/main/ets/runtime/SessionRecoveryRuntime.ets').SessionRecoveryRuntime;
    const owner = Runtime.coordinator(f.runtime.context);
    owner.hooks_.changed = () => {}; // 仅替ArkUI AppStorage观测引擎边界，实际Runtime历史/IO路径保持生产。
    f.setCommitHook(async () => { resolveEntered(); await released; });
    await Runtime.wake(f.runtime.context, [], false); await entered;
    migration = Runtime.migration_;
    assert.ok(migration); assert.equal(owner.stats().historyPending, 1); assert.equal(owner.stats().transactionActive, true);
    const held = f.ledger.ledgerMaintenanceSnapshot(f.runtime.directory);
    assert.equal(held.holds, 2); assert.equal(held.active, false); assert.equal(held.timer, false); assert.equal(history.size, 0);
    release(); await migration;
    assert.equal(history.size, 1); assert.equal(owner.stats().historyPending, 0);
    assert.equal(f.ledger.ledgerMaintenanceSnapshot(f.runtime.directory).holds, 0);
    assert.equal(f.ledger.ledgerMaintenanceSnapshot(f.runtime.directory).pendingCount, 0);
    assert.equal(f.ledger.ledgerMaintenanceSnapshot(f.runtime.directory).active, false);
    const report = logs.find(args => args[1]?.startsWith('SESSION_RECOVERY_STATS ')); assert.ok(report);
    const snapshot = JSON.parse(report[1].substring('SESSION_RECOVERY_STATS '.length));
    assert.equal(snapshot.recovery.historyPending, 0); assert.equal(snapshot.maintenance.pendingCount, 0);
    assert.equal(snapshot.maintenance.timer, false); assert.equal(snapshot.maintenance.holds, 0);
    assert.equal(snapshot.ledger.indexWrites, 1, '历史batch最后真正flush一次才报告');
  } finally { release(); await migration?.catch(() => {}); await f.close(); }
});

test('已消费cold只核小型输入产物但不把所有ended重排历史，不产生每局queue/fsync或原件提交', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const first = f.makeOwner(); await first.prepareColdAdmission(); await first.wake(); await first.backgroundMigration();
    const calls = f.counts.end, queuePath = f.runtime.directory + '/logs/recovery/queue.json';
    let writes = 0; const rename = f.runtime.kitFs.rename;
    f.runtime.kitFs.rename = async (from, to) => { const value = await rename(from, to); if (to === queuePath) writes++; return value; };
    const cold = f.makeOwner(); await cold.prepareColdAdmission(); await cold.wake();
    assert.equal(cold.stats().historyPending, 0); assert.equal(cold.stats().resolverCalls, 0); assert.equal(f.counts.end, calls);
    assert.equal(writes, 3, '只确认一批metadata和首尾游标，不为已消费活动新增单局queue写');
    assert.deepEqual(await cold.results(), []);
  } finally { await f.close(); }
});

test('owner准入在首次IO之前原子占位，并发不同ID被拒，同token失败reserved不能冒充已成功grant', async () => {
  const f = fixture(); let release, entered;
  const released = new Promise(resolve => { release = resolve; }), atDirectory = new Promise(resolve => { entered = resolve; });
  let first;
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
    const mkdir = f.runtime.kitFs.mkdir; let once = true;
    f.runtime.kitFs.mkdir = async (...args) => {
      if (once && args[0].endsWith('/logs/recovery/intents')) { once = false; entered(); await released; }
      return mkdir(...args);
    };
    let fail = true; f.setCommitHook(async () => { if (fail) throw new Error('first admission protection failed'); });
    const id = Date.now(), token = 'atomic-game-reservation';
    first = owner.trackLaunch(id, token); await atDirectory;
    await assert.rejects(() => owner.trackLaunch(id + 1, 'other-reservation'), /另一启动准入/);
    assert.equal(fs.existsSync(f.runtime.directory + '/logs/recovery/intents/' + (id + 1) + '.json'), false);
    release(); await assert.rejects(() => first, /first admission protection failed/);
    assert.equal(owner.stats().gameReservations, 1); assert.equal(owner.grantedLaunches_.has(id), false);
    assert.equal(f.counts.end, 1); fail = false;
    await owner.trackLaunch(id, token);
    assert.equal(f.counts.end, 2, '同token失败重试实际重新完成保护，不直接返回成功');
    assert.equal(owner.grantedLaunches_.has(id), true); assert.equal(f.state().historyRevision, 1);
  } finally { release(); await first?.catch(() => {}); await f.close(); }
});

test('准入末批队列rename期间已知新producer请求仍被必要drain处理，不能在最后await后漏掉失败输入', async () => {
  const f = fixture(); let release, entered;
  const released = new Promise(resolve => { release = resolve; }), atQueue = new Promise(resolve => { entered = resolve; });
  let admission, incoming;
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
    const rename = f.runtime.kitFs.rename; let once = true;
    f.runtime.kitFs.rename = async (from, to) => {
      if (once && to.endsWith('/logs/recovery/queue.json')) {
        const value = JSON.parse(fs.readFileSync(from));
        if (value.activeIds.length === 1 && (value.historyIds ?? []).length === 0) { once = false; entered(); await released; }
      }
      return rename(from, to);
    };
    admission = owner.trackLaunch(Date.now(), 'last-queue-window'); await atQueue;
    f.publish(7); incoming = owner.enqueue(f.id); release(); await incoming; await admission;
    assert.equal(f.state().outcome.state, f.ledger.LedgerState.FAILED); assert.equal(f.state().presentationMode, 'auto');
    assert.equal(owner.stats().pending, 0); assert.equal(owner.stats().consumed, 2);
  } finally { release(); await incoming?.catch(() => {}); await admission?.catch(() => {}); await f.close(); }
});

test('历史仅列表结果遇同input真实marker义务也耐久升级auto，不能留下resultId却被盘上history过滤', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); await owner.backgroundMigration();
    const calls = f.counts.end; assert.equal(f.state().presentationMode, 'history');
    f.runtime.load('launch/src/main/ets/SessionMarker.ets').SessionMarker.writeStart(f.runtime.directory, 'same-session', '/mc', f.id);
    await owner.wake();
    assert.equal(f.counts.end, calls); assert.equal(f.state().presentationMode, 'auto');
    assert.equal((await owner.results())[0].session.startedAt, f.id);
  } finally { await f.close(); }
});

test('后台排队与整局prepare均持真实EvidenceLease，浏览删除/清空拒绝，完成历史义务后解除', async () => {
  const f = fixture(); let release, entered;
  const released = new Promise(resolve => { release = resolve; }), atPrepare = new Promise(resolve => { entered = resolve; });
  let migration;
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake();
    await assert.rejects(() => f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id), /读取或导出/);
    await assert.rejects(() => f.ledger.ledgerClearAsync(f.runtime.directory), /读取或导出/);
    const read = f.runtime.kitFs.readText; let once = true;
    f.runtime.kitFs.readText = async path => {
      if (once && path.endsWith('/capture-sources.json')) { once = false; entered(); await released; }
      return read(path);
    };
    migration = owner.backgroundMigration(); await atPrepare;
    await assert.rejects(() => f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id), /读取或导出/);
    release(); await migration;
    const Io = f.runtime.load('commons/src/main/ets/utils/EvidenceIo.ets');
    assert.equal(Io.hasEvidenceLease(f.runtime.directory, f.id), false);
    assert.equal(await f.ledger.ledgerRemovalBlockReasonAsync(f.runtime.directory, f.id), '');
  } finally { release(); await migration?.catch(() => {}); await f.close(); }
});

test('sole marker Ensure的Evidence rename在途时存在分支也等同per-ID事务，旧回调不能晚覆盖sealed Evidence', async () => {
  for (const old of [false, true]) {
    const f = fixture({ transform: (absolute, source) => {
      if (!old || !absolute.endsWith('ActivityLedger.ets')) return source;
      const start = source.indexOf('export async function ledgerEnsureLegacyLaunchAsync('), end = source.indexOf('/** 下一局界限', start);
      let body = source.slice(start, end);
      const begin = 'try { return await serializeCanonicalAsync_(filesDir, activityId, async (): Promise<LedgerManifest> => {';
      const finish = '}); } finally { releaseEvidenceLease(filesDir, activityId); }';
      assert.equal(body.split(begin).length, 2); assert.equal(body.split(finish).length, 2);
      body = body.replace(begin, 'try {').replace(finish, '} finally { releaseEvidenceLease(filesDir, activityId); }');
      return source.slice(0, start) + body + source.slice(end);
    } });
    let release, entered; const released = new Promise(resolve => { release = resolve; }), atEvidence = new Promise(resolve => { entered = resolve; });
    let first, second;
    try {
      const id = f.id + 1, meta = { category: 'launch', title: 'sole-marker', mcDir: '/legacy' };
      const rename = f.runtime.kitFs.rename; let once = true;
      f.runtime.kitFs.rename = async (from, to) => {
        if (once && to.endsWith('/' + id + '/evidence-manifest.json')) { once = false; entered(); await released; }
        return rename(from, to);
      };
      first = f.ledger.ledgerEnsureLegacyLaunchAsync(f.runtime.directory, id, meta); await atEvidence;
      let returned = false;
      second = f.ledger.ledgerEnsureLegacyLaunchAsync(f.runtime.directory, id, meta).then(value => { returned = true; return value; });
      if (old) {
        await second; assert.equal(returned, true, '旧存在分支真实提前返回');
        // 直接生产Evidence端口模拟已完成的下游sealed产物，原旧回调会晚覆盖它。
        const Evidence = f.runtime.load('commons/src/main/ets/utils/SessionEvidence.ets');
        await Evidence.refreshSessionEvidenceAsync(f.runtime.directory, id, 'sealed', 'complete');
      } else {
        const queue = f.ledger.ledgerBeginAsync(f.runtime.directory, id, meta); // 真实同key第三笔进一步证明per-ID仍占用。
        assert.equal(returned, false); release(); await first; await second; await queue;
        await f.ledger.ledgerEndAsync(f.runtime.directory, id, { state: f.ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'done' });
      }
      release(); await first; await second;
      const evidence = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/ledger/' + id + '/evidence-manifest.json'));
      assert.equal(evidence.captureState, old ? 'running' : 'sealed');
    } finally { release(); await first?.catch(() => {}); await second?.catch(() => {}); await f.close(); }
  }
});

test('实际Runtime既有Desktop失败原件导入在途也阻game准入，旧RUNNING先分类critical且不误当ended历史', async () => {
  let release, entered; const released = new Promise(resolve => { release = resolve; }), atHistory = new Promise(resolve => { entered = resolve; });
  const history = new Map(), storage = new Map([['appInForeground', true]]);
  const imports = {
    'libentry.so': { default: { mcIsRunning: () => false, desktopGameProcessState: () => 0 } },
    'test-storage': { storage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) } },
    feature_core: { ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { SUCCESS: 'success', FAILED: 'failed', CRASHED: 'crashed', ABORTED: 'aborted' },
      getDownloadHistoryStore: () => ({ init: async () => {}, upsertLaunchSession: async record => {
        if (history.size === 0) { entered(); await released; } history.set(record.startedAt, record);
      } }) },
    '@kit.PerformanceAnalysisKit': { hiAppEvent: { domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH', APP_KILLED: 'APP_KILLED' }, addWatcher() {} } },
  };
  const f = fixture({ imports, transform: (absolute, source) => absolute.endsWith('SessionRecoveryRuntime.ets')
    ? "import { storage as AppStorage } from 'test-storage';\n" + source : source });
  let waking, admission;
  try {
    imports.launch = { ...f.runtime.load(recoveryStatePath), ...f.runtime.load(coordinatorPath) };
    const Results = f.runtime.load('entry/src/main/ets/runtime/DesktopGameResults.ets').DesktopGameResults;
    await Results.queue(f.runtime.context, { startedAt: f.id, versionName: '26.3', gameVersion: '26.3', category: 'launch', status: 'failed',
      durationMs: 1000, endedAt: f.id + 1000, totalBytes: 0, fileCount: 0, loaderType: 'launch', errorMessage: '真实准备失败' });
    const Runtime = f.runtime.load('entry/src/main/ets/runtime/SessionRecoveryRuntime.ets').SessionRecoveryRuntime;
    const owner = Runtime.coordinator(f.runtime.context); waking = Runtime.wake(f.runtime.context, [], false); await atHistory;
    assert.equal(owner.stats().historyPending, 0); assert.equal(owner.stats().pending, 1,
      '原RUNNING在真实stale修改之前耐久分类，不因INTERRUPTED变化掉入低优先历史');
    assert.ok(Runtime.preparation_);
    let observed; const boundary = new Promise(resolve => { observed = resolve; }); const observe = owner.observeIntent_;
    owner.observeIntent_ = (...args) => { const value = observe.apply(owner, args); observed(); return value; };
    let granted = false; admission = owner.trackLaunch(Date.now(), 'runtime-import-barrier').then(() => { granted = true; });
    await boundary; assert.equal(granted, false); assert.equal(fs.existsSync(f.runtime.directory + '/desktop-results/' + f.id + '.json'), true);
    release(); await waking; await admission;
    assert.equal(granted, true); assert.equal(owner.stats().pending, 0);
    assert.equal(fs.existsSync(f.runtime.directory + '/desktop-results/' + f.id + '.json'), false);
    assert.equal(history.get(f.id).status, 'failed'); assert.equal((await owner.results())[0].outcome.state, f.ledger.LedgerState.FAILED);
  } finally { release(); await waking?.catch(() => {}); await admission?.catch(() => {}); await f.close(); }
});

test('32局历史补迁存在未归属平台原件时只批末补匹配一次，机械撤去合并条件反控真实逐局全候选扫描', async () => {
  const measured = [];
  for (const withoutMerge of [false, true]) {
    const f = fixture({ transform: (absolute, source) => {
      if (!withoutMerge || !absolute.endsWith('SessionRecoveryCoordinator.ets')) return source;
      const condition = '(!this.deferHistoricalCandidates_ || this.criticalCandidatesChanged_ || gameAdmission)';
      assert.equal(source.split(condition).length, 2, '仅机械撤回本次新增的history候选合并条件，不复制匹配算法');
      return source.replace(condition, 'true');
    } });
    try {
      f.ledger.ledgerBeginMaintenanceBatch(f.runtime.directory);
      for (let index = 0; index < 32; index++) {
        const id = f.id + index;
        if (index > 0) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'unassigned-' + index });
        f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.INTERRUPTED,
          source: 'session.full-evidence', summary: 'legacy ended', endedAt: id + 1 });
        f.runtime.write('game-exits/' + id + '.json', JSON.stringify({ ...f.exit, activityId: id, timestamp: id + 1 }));
      }
      const raw = f.runtime.write('logs/platform-events/event-unassigned-count.json', JSON.stringify({ name: 'APP_CRASH',
        eventAt: f.id + 1, params: { pid: 999999 } }));
      let roots = 0, reads = 0; const list = f.runtime.kitFs.listFile, read = f.runtime.kitFs.readText;
      f.runtime.kitFs.listFile = async path => { if (path === f.runtime.directory + '/logs/ledger') roots++; return list(path); };
      f.runtime.kitFs.readText = async path => { if (path.endsWith('/manifest.json')) reads++; return read(path); };
      const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); await owner.backgroundMigration();
      assert.equal(owner.stats().consumed, 32); assert.equal(f.records.size, 32); assert.equal(owner.stats().historyPending, 0);
      assert.equal(fs.existsSync(raw), true, '未归属原件始终保留，性能合并不能消费它');
      assert.equal(f.counts.platform, withoutMerge ? 33 : 2, '真实archive入口只有cold初次+历史批末一次，撤去合并则32次');
      assert.equal(roots, withoutMerge ? 34 : 3, '枚举来自生产平台候选读取和一次cold身份发现');
      if (withoutMerge) assert.equal(reads - measured[0].reads, 31 * 32, '额外31轮每轮真实读取全部32份候选manifest');
      measured.push({ withoutMerge, roots, reads, platformCalls: f.counts.platform, consumed: owner.stats().consumed });
    } finally { await f.close(); }
  }
  console.info(JSON.stringify({ scenario: 'production-history-unassigned-batch', measured }));
});

test('历史批次合并候选期间真实critical producer补归属仍优先匹配旧平台原件，不等下一历史事务或新publication', async () => {
  const f = fixture(); let release, entered;
  const released = new Promise(resolve => { release = resolve; }), atHistory = new Promise(resolve => { entered = resolve; });
  let migration, critical;
  try {
    for (const id of [f.id, f.id + 2]) {
      if (id !== f.id) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'next-history' });
      f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.INTERRUPTED,
        source: 'session.full-evidence', summary: 'legacy ended', endedAt: id + 1 });
      f.runtime.write('game-exits/' + id + '.json', JSON.stringify({ ...f.exit, activityId: id, timestamp: id + 1 }));
    }
    const event = f.runtime.write('logs/platform-events/event-priority-unassigned.json', JSON.stringify({ name: 'APP_CRASH',
      eventAt: f.id + 1, params: { pid: 202 } }));
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); assert.ok(fs.existsSync(event));
    let once = true, priorityProved = false;
    f.setHistoryHook(async result => {
      if (result.session.startedAt === f.id && once) { once = false; entered(); await released; }
      else if (result.session.startedAt === f.id && result.outcome.state === f.ledger.LedgerState.CRASHED) {
        assert.equal(f.records.has(f.id + 2), false, 'critical更正必须在下一历史投影之前完成'); priorityProved = true;
      }
    });
    migration = owner.backgroundMigration(); await atHistory;
    f.runtime.write('logs/ledger/' + f.id + '/capture-game.json', JSON.stringify({ schema: 1, activityId: f.id, pid: 202 }));
    await owner.enqueue(f.id); critical = owner.wake(); release(); await critical; await migration;
    assert.equal(priorityProved, true); assert.equal(fs.existsSync(event), false);
    assert.equal(f.state().outcome.source, 'platform.APP_CRASH'); assert.equal(f.records.size, 2);
    assert.equal(owner.stats().historyPending, 0); assert.equal(owner.stats().pending, 0);
  } finally { release(); await critical?.catch(() => {}); await migration?.catch(() => {}); await f.close(); }
});

test('已消费最新活动真正删除后同owner新游戏可准入，删除时间界限仍保留且无旧manifest重读', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); await owner.backgroundMigration();
    let notified = 0; f.ledger.setLedgerRemovalObserver((directory, id) => {
      assert.equal(directory, f.runtime.directory); notified++; owner.observeDeletedActivity(id);
    });
    await f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id);
    assert.equal(notified, 1); assert.equal(owner.removedLaunches_.has(f.id), true);
    assert.ok(owner.launchOrder_.includes(f.id), '用户删除活动不抹掉已经发生的后继时间界限');
    let oldReads = 0; const read = f.runtime.kitFs.readText;
    f.runtime.kitFs.readText = async path => { if (path.endsWith('/' + f.id + '/manifest.json')) oldReads++; return read(path); };
    const newId = Date.now(); await owner.trackLaunch(newId, 'deleted-latest-admission');
    assert.equal(owner.grantedLaunches_.has(newId), true); assert.equal(oldReads, 0);
    assert.equal(owner.nextLaunchById_.get(f.id), newId);
  } finally { await f.close(); }
});

test('删中间及最新活动后旧局late输入仍以已删真实时间cutoff拒绝mutable正文，错误移除边界反控会跨局', async () => {
  for (const wrongRemoval of [false, true]) {
    const f = fixture({ transform: (absolute, source) => {
      if (!wrongRemoval || !absolute.endsWith('SessionRecoveryCoordinator.ets')) return source;
      const line = 'this.removedLaunches_.add(activityId); this.boundaryGeneration_++;';
      assert.equal(source.split(line).length, 2);
      // 反控错误方案直接复用生产withdraw算法删除时间边界，而不是复制另一套capture/归属算法。
      return source.replace(line, "this.launchIdentities_.set(activityId, 'intent:deleted-boundary'); this.withdrawIntentBoundary_(activityId);");
    } });
    try {
      for (const id of [f.id, f.id + 1, f.id + 2]) {
        if (id !== f.id) f.ledger.ledgerBegin(f.runtime.directory, id, { category: 'launch', title: 'deleted-boundary' });
        f.ledger.ledgerEnd(f.runtime.directory, id, { state: f.ledger.LedgerState.INTERRUPTED,
          source: 'session.full-evidence', summary: 'legacy ended', endedAt: id + 1 });
        f.runtime.write('game-exits/' + id + '.json', JSON.stringify({ ...f.exit, activityId: id, timestamp: id + 1 }));
      }
      const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); await owner.backgroundMigration();
      f.ledger.setLedgerRemovalObserver((_directory, id) => owner.observeDeletedActivity(id));
      await f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id + 1); await f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id + 2);
      const foreign = 'DELETED LATER GAME BODY\nStopping!\n'; const source = f.runtime.write('minecraft/logs/latest.log', foreign);
      fs.utimesSync(source, new Date(f.exit.timestamp), new Date(f.exit.timestamp));
      f.publish(7); await owner.enqueue(f.id); await owner.wake();
      const target = f.runtime.directory + '/logs/ledger/' + f.id + '/game/logs/latest.log';
      if (wrongRemoval) assert.equal(fs.readFileSync(target, 'utf8'), foreign, '抹掉真实时间边界的错误方案实际跨局复制');
      else {
        assert.equal(owner.nextLaunchById_.get(f.id), f.id + 1); assert.equal(fs.existsSync(target), false);
        assert.equal(f.state().outcome.state, f.ledger.LedgerState.FAILED, '真实late退出事实仍消费，不靠漏恢复来通过反控');
      }
    } finally { await f.close(); }
  }
});

test('删除父目录fsync未知不通知准入已删除，不能把未知absence判成成功失效', async () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.id, { state: f.ledger.LedgerState.INTERRUPTED,
      source: 'session.full-evidence', summary: 'legacy ended', endedAt: f.id + 1 }); f.publish(0);
    const owner = f.makeOwner(); await owner.prepareColdAdmission(); await owner.wake(); await owner.backgroundMigration();
    let notified = 0; f.ledger.setLedgerRemovalObserver((_directory, id) => { notified++; owner.observeDeletedActivity(id); });
    const open = f.runtime.kitFs.open, sync = f.runtime.kitFs.fsync;
    f.runtime.kitFs.open = async (path, mode) => {
      if (path === f.runtime.directory + '/logs/ledger') return { fd: -2345 };
      return open(path, mode);
    };
    f.runtime.kitFs.fsync = async fd => { if (fd === -2345) throw new Error('removed namespace durability unknown'); return sync(fd); };
    await assert.rejects(() => f.ledger.ledgerRemoveAsync(f.runtime.directory, f.id), /durability unknown/);
    assert.equal(notified, 0); assert.equal(owner.removedLaunches_.has(f.id), false);
    f.runtime.kitFs.open = open; f.runtime.kitFs.fsync = sync;
    await assert.rejects(() => owner.trackLaunch(Date.now(), 'unknown-removal-admission'), /保护清单|末门/);
  } finally { await f.close(); }
});

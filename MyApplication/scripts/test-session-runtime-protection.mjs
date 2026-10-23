/**
 * 执行真实SessionRecoveryRuntime与真实账本batch/retention，观察磁盘是否实际删除原件。
 * 只替换Native锁、平台回调、历史Preferences和协调器完成边界，不重写维护hold算法。
 * 每份夹具使用独立SDK文件系统与模块静态状态，所有输出由workspace路径路由外置。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 可控Promise表示协调器已经进入但还没有耐久收尾；不用宿主耗时冒充设备性能。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/**
 * 无参数建立独立磁盘、SDK适配和Runtime静态状态，实际执行生产cold hold、stale恢复、batch与retention。
 * CoordinatorBoundary只控制initialize/wake完成与到达计数；Native锁、历史Preferences和系统Watcher注册是替身。
 * 平台Watcher自身的原件队列/写盘仍执行生产类，publish经保存的系统回调进入，不能从夹具直接改owner私有字段。
 * 返回seed/exists/wake/publish及控制hooks：seed制造超过保留窗口的实际文件，exists核对物理清单是否还在。
 * 每个用例finally await close，先等待真实维护后清理该夹具目录；已持保护不被夹具强行释放，异步任务须先收尾。
 */
function fixture() {
  let ledger;
  const control = { idle: true, staleCalls: 0, initialized: 0, wakes: 0, publications: 0,
    onWake: undefined, platformWatcher: undefined, removed: [] };
  /** 只冻结协调器完成边界；Runtime准备、保护和维护全部执行生产实现。 */
  class CoordinatorBoundary {
    async initialize() { control.initialized++; }
    async prepareColdAdmission() { await this.initialize(); }
    hasHistoricalMigration() { return false; }
    observeDeletedActivity(id) { control.removed.push(id); }
    async wake() { const ordinal = ++control.wakes; await control.onWake?.(ordinal); }
    async enqueue() {}
    notifyPlatformPublication() { control.publications++; }
    stats() { return {}; }
  }
  const runtime = evidenceRuntime({
    imports: {
      'libentry.so': { default: { mcIsRunning: () => !control.idle,
        desktopGameProcessState: () => control.idle ? 0 : 1 } },
      launch: { SessionRecoveryCoordinator: CoordinatorBoundary },
      feature_core: { getDownloadHistoryStore: () => ({ async init() {}, async upsertLaunchSession() {} }),
        ActivityCategory: { LAUNCH: 'launch' }, ActivityStatus: { SUCCESS: 'success', FAILED: 'failed', CRASHED: 'crashed', ABORTED: 'aborted' } },
      '@kit.PerformanceAnalysisKit': { hiAppEvent: { domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH', APP_KILLED: 'APP_KILLED' },
        addWatcher(watcher) { control.platformWatcher = watcher; } } },
    },
    commons: {
      // 此端口只计数真实stale调用，算法与磁盘副作用继续来自当前生产导出。
      ledgerResolveStaleAsync: async (...args) => { control.staleCalls++; return ledger.ledgerResolveStaleAsync(...args); },
    },
  });
  ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  ledger.setLedgerProcessRunNonce('runtime-protection-test');
  const Runtime = runtime.load('entry/src/main/ets/runtime/SessionRecoveryRuntime.ets').SessionRecoveryRuntime;
  // 原平台采集/持久队列同样执行生产类；只由SDK替身保存系统回调，测试经它产生真实publication。
  runtime.load('entry/src/main/ets/runtime/PlatformDfxWatcher.ets').PlatformDfxWatcher.start(runtime.directory);
  // 创建owner必须在首个持久写之前建立持续cold保护，不额外给夹具手工加hold。
  Runtime.coordinator(runtime.context);
  const ids = Array.from({ length: 52 }, (_, index) => 100 + index);
  /** 通过真实开账/封账建立固定诊断集合；其数量仅是保留边界输入，不写入规范或伪造删除结果。 */
  const seed = () => {
    for (const id of ids) {
      assert.equal(ledger.ledgerBegin(runtime.directory, id, { category: 'diagnostic', title: 'record-' + id }), true);
      ledger.ledgerEnd(runtime.directory, id, { state: ledger.LedgerState.SUCCESS, source: 'fixture', summary: 'completed', endedAt: id + 1 });
    }
  };
  /** 按活动主键读取真实宿主文件存在性，以物理原件而非计数声明证明保留/删除。 */
  const exists = id => fs.existsSync(ledger.ledgerDirOf(runtime.directory, id) + '/manifest.json');
  return { runtime, ledger, Runtime, control, ids, seed, exists,
    wake: () => Runtime.wake(runtime.context, [], false),
    publish: () => control.platformWatcher.onReceive('OS', [{ name: 'APP_CRASH', appEventInfos: [{ params: { time: 120, pid: 101 } }] }]),
    async close() { await ledger.ledgerFlushMaintenanceAsync(runtime.directory); runtime.close(); },
  };
}

const turn = () => new Promise(resolve => setImmediate(resolve));

test('cold补采索引错误后普通hold结束仍零自动删除，修复后同Runtime成功释放并执行真实保留', async () => {
  const f = fixture();
  try {
    f.seed(); const retry = f.runtime.write('logs/platform-events/report-retries.json', '{invalid');
    const original = fs.readFileSync(retry);
    await assert.rejects(() => f.wake(), SyntaxError);
    await f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory); await turn();
    assert.ok(f.ids.every(f.exists)); assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 0);
    assert.equal(f.control.staleCalls, 0); assert.deepEqual(fs.readFileSync(retry), original);
    // 持续hold也必须阻止失败后的新dirty timer，无需依赖调用方不再写元数据。
    f.ledger.ledgerMarkDirty(f.runtime.directory, f.ids[0]); await turn();
    assert.ok(f.ids.every(f.exists)); assert.equal(f.ledger.ledgerMaintenanceCounters().indexWrites, 0);
    fs.writeFileSync(retry, JSON.stringify({ schema: 1, entries: [] }));
    // restore/stale已经成功仍不足以开放删除，整轮协调器wake失败必须继续保留初始保护。
    f.control.onWake = async () => { throw new Error('owner durable finish failed'); };
    await assert.rejects(() => f.wake(), /owner durable finish failed/);
    await f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory); await turn();
    assert.ok(f.ids.every(f.exists)); assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 0);
    f.control.onWake = undefined;
    await f.wake();
    assert.equal(f.control.staleCalls, 1); assert.equal(f.control.initialized, 1); assert.equal(f.control.wakes, 2);
    assert.equal(f.ids.filter(f.exists).length, 50, '只有成功释放保护后才真正应用50条保留窗口');
    assert.equal(f.exists(f.ids[0]), false); assert.equal(f.exists(f.ids[1]), false);
    assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 1);
  } finally { await f.close(); }
});

test('游戏活跃的首次成功初始化不消费stale义务，真正空闲后补一次并释放原件保护', async () => {
  const f = fixture();
  try {
    f.control.idle = false; f.seed();
    const activeId = 1000;
    assert.equal(f.ledger.ledgerBegin(f.runtime.directory, activeId, { category: 'diagnostic', title: 'unfinished' }), true);
    await f.wake();
    assert.equal(f.control.staleCalls, 0); assert.equal(f.control.initialized, 1);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, activeId).state, f.ledger.LedgerState.RUNNING);
    assert.ok(f.ids.every(f.exists)); assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 0);
    f.control.idle = true; await f.wake();
    assert.equal(f.control.staleCalls, 1);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, activeId).state, f.ledger.LedgerState.INTERRUPTED);
    const stale = fs.readFileSync(f.ledger.ledgerDirOf(f.runtime.directory, activeId) + '/manifest.json');
    await f.wake();
    assert.equal(f.control.staleCalls, 1, 'fulfilled start不能漏stale，也不应每次亮屏重复stale');
    assert.deepEqual(fs.readFileSync(f.ledger.ledgerDirOf(f.runtime.directory, activeId) + '/manifest.json'), stale);
    assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 1);
  } finally { await f.close(); }
});

test('活跃cold初始化后的并发idle唤醒共享同一真实stale补办，不能重复全账本发现', async () => {
  const f = fixture();
  try {
    f.control.idle = false; f.seed(); await f.wake();
    assert.equal(f.control.staleCalls, 0);
    f.control.idle = true;
    await Promise.all([f.wake(), f.wake()]);
    assert.equal(f.control.staleCalls, 1, 'staleApplied在await后推进仍需singleflight，两个idle wake不能同时补办');
    assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 1);
    assert.equal(f.ids.filter(f.exists).length, 50);
  } finally { await f.close(); }
});

test('嵌套平台wake未收尾前保护移交仍阻止删除，最后一个真实批次结束才维护一次', async () => {
  const f = fixture();
  const first = deferred(), nested = deferred(), firstEntered = deferred(), nestedEntered = deferred();
  try {
    f.seed(); f.control.onWake = async ordinal => {
      if (ordinal === 1) { firstEntered.resolve(); await first.promise; }
      else if (ordinal === 2) { nestedEntered.resolve(); await nested.promise; }
      else throw new Error('测试不应自行产生重复wake');
    };
    const firstJob = f.wake(); await firstEntered.promise;
    assert.equal(f.control.staleCalls, 1);
    f.publish(); await nestedEntered.promise;
    first.resolve(); await firstJob;
    await f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory); await turn();
    assert.equal(f.control.publications, 1); assert.ok(f.ids.every(f.exists));
    assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 0);
    // notifyPlatformPublication返回void；下一轮普通wake与其共享真实模块批次保护，
    // 通过实际索引发布Promise观察已派发的平台wake finally，而不手工释放任何hold。
    const originalWrite = f.runtime.kitFs.rename, maintained = deferred();
    f.runtime.kitFs.rename = async (from, to) => {
      await originalWrite(from, to); if (to.endsWith('/logs/ledger/index.json')) maintained.resolve();
    };
    nested.resolve(); await maintained.promise; await turn();
    await f.ledger.ledgerFlushMaintenanceAsync(f.runtime.directory);
    assert.equal(f.ids.filter(f.exists).length, 50);
    assert.equal(f.ledger.ledgerMaintenanceCounters().retentionBatches, 1);
    assert.equal(f.control.staleCalls, 1); assert.equal(f.control.initialized, 1);
  } finally { first.resolve(); nested.resolve(); await f.close(); }
});

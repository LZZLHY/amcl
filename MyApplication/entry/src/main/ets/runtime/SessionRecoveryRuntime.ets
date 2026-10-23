/**
 * 启动器恢复装配：唯一进程owner持有协调器和历史Preferences，Index只消费已提交结果。
 * 新冷启动先核实更新豁免并恢复旧RUNNING，再启动迁移；平台回调不会抢先跨过此启动边界。
 */
import { common } from '@kit.AbilityKit';
import testNapi from 'libentry.so';
import { AppLogger, LOG_DOMAIN_LAUNCH, LedgerState, ledgerResolveStaleAsync,
  configureLedgerMaintenanceOwner, ledgerMaintenanceCounters, ledgerMaintenanceSnapshot, ledgerFlushMaintenanceAsync,
  ledgerBeginMaintenanceBatch, ledgerEndMaintenanceBatchAsync, setLedgerRemovalObserver } from 'commons';
import { restorePlatformReportProtectionAsync } from 'commons';
import { SessionRecoveryCoordinator, SessionRecoveryResult } from 'launch';
import { getDownloadHistoryStore, ActivityRecord, ActivityCategory, ActivityStatus } from 'feature_core';
import { PlatformDfxWatcher } from './PlatformDfxWatcher';
import { DesktopGameResults } from './DesktopGameResults';

export class SessionRecoveryRuntime {
  private static coordinator_: SessionRecoveryCoordinator | undefined = undefined;
  private static context_: common.Context | undefined = undefined;
  private static start_: Promise<void> | undefined = undefined;
  /** 初次恢复还没有核实补采保护前持一份持续维护hold；失败不能由finally提前释放淘汰。 */
  private static initializationHold_: boolean = false;
  /** 游戏活跃时冷启动不做stale；下一次确实空闲仍须补这一义务，不能因start已完成而漏掉。 */
  private static staleApplied_: boolean = false;
  private static staleTask_: Promise<void> | undefined = undefined;
  private static migration_: Promise<void> | undefined = undefined;
  /** 必要stale/旧失败原件导入是game准入的一部分；不与历史后台Promise合并。 */
  private static preparation_: Promise<void> | undefined = undefined;

  /** 初次和游戏结束后的stale补办共用singleflight，失败保留资格供下一次明确唤醒重试。 */
  private static ensureStale_(context: common.Context, pendingUpdateIds: number[]): Promise<void> {
    if (SessionRecoveryRuntime.staleApplied_ || !SessionRecoveryRuntime.isIdle_()) return Promise.resolve();
    if (SessionRecoveryRuntime.staleTask_ !== undefined) return SessionRecoveryRuntime.staleTask_;
    const job: Promise<void> = ledgerResolveStaleAsync(context.filesDir, pendingUpdateIds).then((): void => {
      // IO等待期间游戏可能变为活跃；保持补办资格，不能把一个已延后的阶段宣布完成。
      if (SessionRecoveryRuntime.isIdle_()) SessionRecoveryRuntime.staleApplied_ = true;
    });
    SessionRecoveryRuntime.staleTask_ = job;
    const clear = (): void => { if (SessionRecoveryRuntime.staleTask_ === job) SessionRecoveryRuntime.staleTask_ = undefined; };
    job.then(clear, clear);
    return job;
  }

  /** 锁错误也属于未知，绝不能按空闲提交恢复或执行淘汰。 */
  private static isIdle_(): boolean {
    try { return SessionRecoveryRuntime.context_ !== undefined && !testNapi.mcIsRunning()
      && testNapi.desktopGameProcessState(SessionRecoveryRuntime.context_.filesDir, 0) === 0; }
    catch (_) { return false; }
  }

  static coordinator(context: common.Context): SessionRecoveryCoordinator {
    if (SessionRecoveryRuntime.coordinator_ !== undefined) return SessionRecoveryRuntime.coordinator_;
    SessionRecoveryRuntime.context_ = context;
    configureLedgerMaintenanceOwner(true, (): boolean => SessionRecoveryRuntime.isIdle_());
    // 创建owner时同步建立保护，早于任何读取await/脏条目timer；首次完整成功才移交普通维护。
    ledgerBeginMaintenanceBatch(context.filesDir);
    SessionRecoveryRuntime.initializationHold_ = true;
    const coordinator = new SessionRecoveryCoordinator(context.filesDir, {
      isIdle: (): boolean => SessionRecoveryRuntime.isIdle_(),
      canMigrate: (): boolean => AppStorage.get<boolean>('appInForeground') !== false,
      beforeGameAdmission: (): Promise<void> => SessionRecoveryRuntime.prepareRequired_(context, []),
      admissionBarrierCurrent: (): boolean => SessionRecoveryRuntime.preparation_ === undefined,
      applyHistory: (result: SessionRecoveryResult): Promise<void> => SessionRecoveryRuntime.applyHistory_(context, result),
      changed: (): void => {
        const revision: number = AppStorage.get<number>('desktopSessionRevision') ?? 0;
        AppStorage.setOrCreate<number>('desktopSessionRevision', revision + 1);
      }
    });
    SessionRecoveryRuntime.coordinator_ = coordinator;
    setLedgerRemovalObserver((filesDir: string, activityId: number): void => {
      if (filesDir === context.filesDir) coordinator.observeDeletedActivity(activityId);
    });
    PlatformDfxWatcher.setRecoveryWake((): void => SessionRecoveryRuntime.notifyPlatformPublication());
    return coordinator;
  }

  /** 冷启动恢复幂等singleflight；失败保留原件和待办，用户重试可重新执行未完成阶段。 */
  static async wake(context: common.Context, pendingUpdateIds: number[] = [], report: boolean = true): Promise<void> {
    const coordinator = SessionRecoveryRuntime.coordinator(context);
    // 从stale/迁移到逐局裁决共同持批；dirty定时器不能在批中为每局重新执行保留维护。
    ledgerBeginMaintenanceBatch(context.filesDir);
    try {
      await SessionRecoveryRuntime.prepareRequired_(context, pendingUpdateIds);
      await coordinator.wake();
      if (SessionRecoveryRuntime.initializationHold_ && SessionRecoveryRuntime.staleApplied_
        && SessionRecoveryRuntime.isIdle_() && !coordinator.hasHistoricalMigration()) {
        // 此时wake本身的批hold仍在；先释放初次保护不会在补采/入队/提交间隙触发timer。
        SessionRecoveryRuntime.initializationHold_ = false;
        await ledgerEndMaintenanceBatchAsync(context.filesDir);
      }
    } finally { await ledgerEndMaintenanceBatchAsync(context.filesDir); }
    // 首页只等待必要队列。历史后台独立持hold，任何失败/暂停都保留队列与保留保护。
    SessionRecoveryRuntime.startHistoricalMigration_(context);
    if (report) await SessionRecoveryRuntime.reportSettled(context);
  }

  private static prepareRequired_(context: common.Context, pendingUpdateIds: number[]): Promise<void> {
    if (SessionRecoveryRuntime.preparation_ !== undefined) return SessionRecoveryRuntime.preparation_;
    const coordinator = SessionRecoveryRuntime.coordinator(context);
    const preparation: Promise<void> = (async (): Promise<void> => {
    if (SessionRecoveryRuntime.start_ === undefined) {
      const job: Promise<void> = (async (): Promise<void> => {
        // 包含onCreate记录的上次退出事实，保存失败不能将准备页发布为恢复成功。
        await PlatformDfxWatcher.flushPending();
        // 先重建已归属未完成报告的租约；索引损坏/IO失败保留持续hold，禁止误淘汰原件。
        await restorePlatformReportProtectionAsync(context.filesDir);
        // 先记录原始RUNNING身份为必要义务，再做stale收尾，避免其变成INTERRUPTED后被误归历史迁移。
        // 这里只分类，不提交结局/淘汰；更新豁免仍在后续真实stale步骤优先核实。
        await coordinator.prepareColdAdmission();
        await SessionRecoveryRuntime.ensureStale_(context, pendingUpdateIds);
      })();
      SessionRecoveryRuntime.start_ = job;
      job.catch((): void => { if (SessionRecoveryRuntime.start_ === job) SessionRecoveryRuntime.start_ = undefined; });
    }
    await SessionRecoveryRuntime.start_;
    if (SessionRecoveryRuntime.isIdle_()) {
      await SessionRecoveryRuntime.ensureStale_(context, pendingUpdateIds);
      const failureMessage = await DesktopGameResults.importPending(context);
      if (failureMessage.length > 0) AppStorage.setOrCreate<string>('desktopLaunchError', failureMessage);
      for (const id of DesktopGameResults.takeCommittedIds()) await coordinator.enqueue(id);
    }
    })();
    SessionRecoveryRuntime.preparation_ = preparation;
    const clear = (): void => { if (SessionRecoveryRuntime.preparation_ === preparation) SessionRecoveryRuntime.preparation_ = undefined; };
    preparation.then(clear, clear); return preparation;
  }

  private static startHistoricalMigration_(context: common.Context): void {
    const coordinator = SessionRecoveryRuntime.coordinator(context);
    if (SessionRecoveryRuntime.migration_ !== undefined || !coordinator.hasHistoricalMigration()
      || !SessionRecoveryRuntime.isIdle_() || AppStorage.get<boolean>('appInForeground') === false) return;
    ledgerBeginMaintenanceBatch(context.filesDir);
    const job: Promise<void> = (async (): Promise<void> => {
      try {
        await coordinator.backgroundMigration();
        if (!coordinator.hasHistoricalMigration() && SessionRecoveryRuntime.initializationHold_
          && SessionRecoveryRuntime.staleApplied_ && SessionRecoveryRuntime.isIdle_()) {
          SessionRecoveryRuntime.initializationHold_ = false;
          await ledgerEndMaintenanceBatchAsync(context.filesDir);
        }
      } finally { await ledgerEndMaintenanceBatchAsync(context.filesDir); }
      await SessionRecoveryRuntime.reportSettled(context);
    })();
    SessionRecoveryRuntime.migration_ = job;
    job.then((): void => { if (SessionRecoveryRuntime.migration_ === job) SessionRecoveryRuntime.migration_ = undefined; },
      (error: Error): void => {
        if (SessionRecoveryRuntime.migration_ === job) SessionRecoveryRuntime.migration_ = undefined;
        AppLogger.warn('SessionRecovery', '历史迁移已延后，原件及未完成队列保留', error, LOG_DOMAIN_LAUNCH);
      });
  }

  /** 在真实Sheet回执/展示ack之后调用；等待已在途维护，并显式记录持续保护与后台状态。 */
  static async reportSettled(context: common.Context): Promise<void> {
    await ledgerFlushMaintenanceAsync(context.filesDir);
    AppLogger.info('SessionRecovery', 'SESSION_RECOVERY_STATS ' + JSON.stringify({
      recovery: SessionRecoveryRuntime.coordinator(context).stats(), ledger: ledgerMaintenanceCounters(),
      maintenance: ledgerMaintenanceSnapshot(context.filesDir) }), LOG_DOMAIN_LAUNCH);
  }

  /** 原始平台记录保存成功后只发布唤醒；初始化尚未完成时原件由随后冷启动对账处理。 */
  static notifyPlatformPublication(): void {
    const coordinator = SessionRecoveryRuntime.coordinator_;
    if (coordinator === undefined) return;
    coordinator.notifyPlatformPublication();
    if (SessionRecoveryRuntime.start_ !== undefined && SessionRecoveryRuntime.context_ !== undefined) {
      SessionRecoveryRuntime.wake(SessionRecoveryRuntime.context_, [], false).catch((error: Error): void => {
        AppLogger.warn('SessionRecovery', '平台恢复已延后，原始记录保留', error, LOG_DOMAIN_LAUNCH);
      });
    }
  }

  /**
   * 派发端只提交本次父意图身份与原始错误，不把系统派发异常裁成游戏终态。
   * 协调器先耐久保留原文，再核验同token、真实无基线且没有活跃游戏/生产者事实；
   * 只有明确撤回父意图时返回true。false或写盘异常都保留原义务，供迟到child继续发布。
   * 冻结字段包含堆栈、message和可枚举错误详情，绝不把账户或完整Want快照混入原件。
   */
  static async reportLaunchDispatchFailure(context: common.Context, activityId: number, intentToken: string,
    stage: string, error: Error): Promise<boolean> {
    let details: string = '';
    try { details = JSON.stringify(error); } catch (_) { /* 非标准错误详情不可序列化时仍保存原消息和堆栈。 */ }
    const rawError: string = JSON.stringify({ name: error.name, message: error.message,
      stack: error.stack ?? '', details: details });
    return SessionRecoveryRuntime.coordinator(context).recordLaunchDispatchFailure(activityId, intentToken, stage, rawError);
  }

  /** 历史只消费经裁决且已提交的结果，使用专用upsert保留同活动已有分享/AI字段。 */
  private static async applyHistory_(context: common.Context, result: SessionRecoveryResult): Promise<void> {
    const session = result.session; const outcome = result.outcome;
    const exact = session.endedAt !== undefined && session.endedAt >= session.startedAt && session.endedAt <= Date.now();
    const record: ActivityRecord = {
      versionName: session.version, gameVersion: session.version, loaderType: 'launch',
      startedAt: session.startedAt, endedAt: exact ? session.endedAt : undefined,
      durationMs: exact ? Math.max(0, session.endedAt! - session.startedAt) : 0,
      durationEstimated: !exact, totalBytes: 0, fileCount: 0, category: ActivityCategory.LAUNCH,
      title: session.version, subtitle: '游戏会话', mcDir: session.mcDir,
      status: outcome.state === LedgerState.SUCCESS ? ActivityStatus.SUCCESS
        : outcome.state === LedgerState.CRASHED ? ActivityStatus.CRASHED
          : outcome.state === LedgerState.FAILED ? ActivityStatus.FAILED : ActivityStatus.ABORTED,
      errorMessage: outcome.summary, errorKind: outcome.errorKind ?? ''
    };
    const store = getDownloadHistoryStore(); await store.init(context); await store.upsertLaunchSession(record);
  }
}

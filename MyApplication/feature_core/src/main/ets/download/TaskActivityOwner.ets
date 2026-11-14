/**
 * 持续业务的活动事实所有者。页面仅展示任务，不负责决定尝试身份或在销毁时封账。
 * Registry 在调用 producer 前等待 begin，在真实 action/清理收敛后提交固定终态；
 * 本地导入、导出和诊断也复用同一事务。失败的日志提交保留原业务结局及耐久原件，
 * 不把已经成功的安装变成失败，也不为补写记录重新执行业务。
 */
import { AppLogger, LOG_DOMAIN_DOWNLOAD, LedgerBeginMeta, LedgerState, LedgerOutcome,
  ledgerBeginAsync, ledgerManifestAsync, ledgerEndAsync, ledgerDirOf,
  writeEvidenceTextAtomicAsync } from 'commons';
import { process } from '@kit.ArkTS';
import { ActivityCategory, ActivityRecord, getDownloadHistoryStore } from './DownloadHistory';
import { UnifiedTaskView, UnifiedTaskState, TaskCategory, isTerminalState } from './UnifiedDownloadTask';
import { ProcessActivityCoordinator } from './ProcessActivityCoordinator';

/** 通用操作将业务返回值映射为明确结果；部分失败由领域调用方裁决，不凭Promise成功猜结局。 */
export interface BusinessActivityResult {
  state: LedgerState;
  summary: string;
  totalBytes?: number;
  fileCount?: number;
}

/** 进程内的唯一毫秒分配器；同毫秒并行任务及重试也不复用前次活动身份。 */
let lastActivityId: number = 0;
export function reserveTaskActivityId(minimum: number = 0): number {
  lastActivityId = Math.max(Date.now(), lastActivityId + 1, minimum);
  return lastActivityId;
}

/** schema2用于所有普通业务；id/category/nonce必须由恢复消费者再次核对。 */
export interface TaskActivityTerminal {
  schema: number;
  activityId: number;
  category: string;
  runNonce: string;
  producerPid: number;
  record: ActivityRecord;
  outcome: LedgerOutcome;
}

/**
 * 已开账的一次业务。finish只接纳首个明确终态，IO重试复用原结束时间和记录；
 * 尚未落盘的事实保留在owner中，同时尽早写入task-terminal供下次进程恢复。
 */
export class BusinessActivity {
  readonly id: number;
  private readonly filesDir_: string;
  private readonly meta_: LedgerBeginMeta;
  private terminal_: TaskActivityTerminal | undefined = undefined;
  private commit_: Promise<void> | undefined = undefined;
  private completed_: boolean = false;
  /** 历史提交成功后只补canonical，避免关闭IO重试重复向普通LRU追加同一主键。 */
  private historySaved_: boolean = false;
  private exportTaskId_: string = '';

  constructor(filesDir: string, id: number, meta: LedgerBeginMeta) {
    this.filesDir_ = filesDir; this.id = id; this.meta_ = meta;
  }

  /** 小型阶段行显式携带id；不会借用异步交错下不可靠的“当前活动”。 */
  event(message: string): void {
    AppLogger.info('ActivityOwner', message, LOG_DOMAIN_DOWNLOAD, this.id);
  }

  /** 导出入口只公开任务身份；目标URI和授权仍留在领域私有记录中。 */
  setExportTaskId(taskId: string): void {
    if (!taskId.startsWith(this.id.toString() + '-') || !new RegExp('^[0-9]+-[a-zA-Z0-9-]+$').test(taskId)) {
      throw new Error('导出任务身份与本次活动不匹配');
    }
    this.exportTaskId_ = taskId;
  }

  /**
   * 冻结首次业务结局，先写耐久原件，再提交历史与canonical；重复调用仅补办IO。
   * 调用方在业务finally使用finishSafely，避免记录故障改变已确认的业务成功/取消。
   */
  finish(state: LedgerState, summary: string, bytes: number = 0, files: number = 0): Promise<void> {
    if (this.completed_) return Promise.resolve();
    if (this.terminal_ === undefined) {
      if (![LedgerState.SUCCESS, LedgerState.FAILED, LedgerState.ABORTED].includes(state)) {
        return Promise.reject(new Error('普通活动必须提交明确的成功、失败或取消结局'));
      }
      const endedAt = Math.max(this.id, Date.now());
      // 恢复只承认有限的非负整数统计；与历史快照和canonical taskFacts共用这一份固定值。
      const totalBytes = Number.isSafeInteger(bytes) && bytes >= 0 ? bytes : 0;
      const fileCount = Number.isSafeInteger(files) && files >= 0 ? files : 0;
      const record: ActivityRecord = {
        category: this.meta_.category, title: this.meta_.title, versionName: this.meta_.title,
        gameVersion: this.meta_.gameVersionId || '-', loaderType: this.meta_.loaderType || this.meta_.category,
        loaderVersion: this.meta_.loaderVersion, mcDir: this.meta_.mcDir,
        startedAt: this.id, endedAt: endedAt, durationMs: Math.max(0, endedAt - this.id),
        status: state === LedgerState.SUCCESS ? 'success' : state === LedgerState.ABORTED ? 'aborted' : 'failed',
        totalBytes: totalBytes, fileCount: fileCount, parentActivityId: this.meta_.parentActivityId, relation: this.meta_.relation,
        subtitle: summary,
      };
      if (state !== LedgerState.SUCCESS) record.errorMessage = summary;
      if (this.exportTaskId_.length > 0) record.exportTaskId = this.exportTaskId_;
      this.terminal_ = { schema: 2, activityId: this.id, category: this.meta_.category, runNonce: '', producerPid: process.pid, record: record,
        outcome: { state: state, source: 'task.owner', summary: summary, endedAt: endedAt,
          taskFacts: { totalBytes: totalBytes, fileCount: fileCount, exportTaskId: this.exportTaskId_ || undefined } } };
    }
    if (this.commit_ !== undefined) return this.commit_;
    const terminal = this.terminal_;
    const job: Promise<void> = (async (): Promise<void> => {
      const manifest = await ledgerManifestAsync(this.filesDir_, this.id);
      if (manifest === null || manifest.category !== terminal.category || manifest.ownerPid !== terminal.producerPid || (manifest.runNonce ?? '').length === 0
        || terminal.runNonce.length > 0 && terminal.runNonce !== manifest.runNonce) {
        throw new Error('活动身份无法核实，原业务结局保留等待重试');
      }
      terminal.runNonce = manifest.runNonce ?? '';
      await writeEvidenceTextAtomicAsync(ledgerDirOf(this.filesDir_, this.id) + '/task-terminal.json', JSON.stringify(terminal));
      if (!this.historySaved_) { await getDownloadHistoryStore().add(terminal.record); this.historySaved_ = true; }
      await ledgerEndAsync(this.filesDir_, this.id, terminal.outcome);
      this.completed_ = true;
      notifyTaskActivityChanged();
    })();
    this.commit_ = job;
    return job.finally((): void => { if (this.commit_ === job) this.commit_ = undefined; });
  }

  /** 供owner的有限IO重试使用；不会重新确定业务状态或读取已经变化的view。 */
  retryCommit(): Promise<void> {
    const terminal = this.terminal_;
    return terminal === undefined ? Promise.resolve() : this.finish(terminal.outcome.state, terminal.outcome.summary);
  }
}

/** 每次耐久边沿只发一次通知，页面无需在高频进度中全量扫描历史。 */
function notifyTaskActivityChanged(): void {
  const revision: number = AppStorage.get<number>('amclTaskActivityRevision') ?? 0;
  AppStorage.setOrCreate<number>('amclTaskActivityRevision', revision + 1);
}

/**
 * 应用级所有者：持有未完成attempt与待提交事实，与页面生命周期独立。
 * 更新下载和导出准备已由各自领域owner开账，Registry不重复接管它们。
 */
export class TaskActivityOwner {
  private filesDir_: string = '';
  private appFilesDir_: string = '';
  private attempts_: Map<number, BusinessActivity> = new Map<number, BusinessActivity>();
  private pending_: Map<number, BusinessActivity> = new Map<number, BusinessActivity>();
  private retryTimer_: number = -1;
  private retryBusy_: boolean = false;
  private retryJob_: Promise<void> | undefined = undefined;
  /** 后台不主动唤醒；坏盘退避从30秒指数增长到5分钟，前台显式wake重新尝试。 */
  private foreground_: boolean = false;
  private retryDelay_: number = 30000;

  /** 主启动器初始化时绑定沙箱；同进程不能在有活动时改绑其他目录。 */
  configure(filesDir: string, appFilesDir: string = ''): void {
    if (this.filesDir_.length > 0 && this.filesDir_ !== filesDir) throw new Error('活动所有者不能跨沙箱改绑');
    this.filesDir_ = filesDir;
    if (appFilesDir.length > 0) this.appFilesDir_ = appFilesDir;
  }

  owns(view: UnifiedTaskView): boolean {
    return view.category !== TaskCategory.APP_UPDATE && view.category !== TaskCategory.GAME_EXPORT;
  }

  /** 普通任务的元信息来自构造时固定的业务输入，不按task id字符串猜类别或实例。 */
  async beginTask(view: UnifiedTaskView): Promise<void> {
    if (!this.owns(view)) return;
    if (this.attempts_.has(view.startedAtMs)) return;
    const category: string = view.activityCategory || (view.category === TaskCategory.MC_VERSION ? ActivityCategory.DOWNLOAD
      : view.category === TaskCategory.JDK ? ActivityCategory.JDK
      : view.category === TaskCategory.MODPACK ? ActivityCategory.MODPACK : ActivityCategory.MOD_INSTALL);
    const meta: LedgerBeginMeta = { category: category, title: view.title,
      gameVersionId: view.activityGameVersion, mcDir: view.activityMcDir,
      loaderType: view.activityLoaderType, loaderVersion: view.activityLoaderVersion,
      parentActivityId: view.parentActivityId, relation: view.activityRelation };
    const activity = await this.begin(meta, view.startedAtMs);
    this.attempts_.set(view.startedAtMs, activity);
  }

  /** 只在真实action收口或排队取消清理完成后调用；暂停保持RUNNING及原scope。 */
  async finishTask(view: UnifiedTaskView): Promise<void> {
    if (!this.owns(view) || !isTerminalState(view.state)) return;
    const activity = this.attempts_.get(view.startedAtMs);
    if (activity === undefined) return;
    const state = view.state === UnifiedTaskState.DONE ? LedgerState.SUCCESS
      : view.state === UnifiedTaskState.ABORTED ? LedgerState.ABORTED : LedgerState.FAILED;
    await this.finishSafely(activity, state, view.errorMessage || view.currentLabel || view.subtitle,
      view.bytesDone, view.filesDone);
    this.attempts_.delete(view.startedAtMs);
  }

  /** 非队列的持续业务同样在第一个producer前显式建立scope，返回本次固定id。 */
  async begin(meta: LedgerBeginMeta, id: number = 0): Promise<BusinessActivity> {
    if (this.filesDir_.length === 0) throw new Error('活动服务尚未初始化');
    if (id <= 0) id = reserveTaskActivityId();
    meta.appFilesDir = this.appFilesDir_;
    // 只有本次首次创建的基线才属于这个owner。撞到旧账本时停止准入，不把别人的
    // RUNNING/终态活动误当作本次scope失败，再由catch封成FAILED。
    if (await ledgerManifestAsync(this.filesDir_, id) !== null) throw new Error('活动主键已存在，请重新发起任务');
    const activity = new BusinessActivity(this.filesDir_, id, meta);
    try {
      if (!await ledgerBeginAsync(this.filesDir_, id, meta)) throw new Error('无法建立活动账本，请检查可用存储后重试');
    } catch (error) {
      // Native scope可能在canonical RUNNING已写入后拒绝/抛错。producer尚未获准，
      // 但这个基线已经是持久义务：立即固定FAILED，IO仍失败则交同一pending队列补办。
      const baseline = await ledgerManifestAsync(this.filesDir_, id);
      if (baseline !== null && baseline.category === meta.category && baseline.ownerPid === process.pid
        && baseline.state === LedgerState.RUNNING && (baseline.runNonce ?? '').length > 0) {
        await this.finishSafely(activity, LedgerState.FAILED, '活动准入失败：' + (error as Error).message);
      }
      throw error as Error;
    }
    activity.event('开始：' + meta.title);
    notifyTaskActivityChanged();
    return activity;
  }

  /**
   * 导入、导出、校验与诊断的领域入口。预约覆盖producer和finally，原业务返回值/异常
   * 完整透传；活动IO失败只保留补写义务，不覆盖业务结局，也不会再执行业务函数。
   */
  async run<T>(meta: LedgerBeginMeta, action: (activity: BusinessActivity) => Promise<T>,
    classify: (value: T) => BusinessActivityResult): Promise<T> {
    const release = ProcessActivityCoordinator.instance().acquireFileTask(meta.title);
    let activity: BusinessActivity | undefined = undefined;
    try {
      activity = await this.begin(meta);
      const value = await action(activity);
      const result = classify(value);
      await this.finishSafely(activity, result.state, result.summary, result.totalBytes ?? 0, result.fileCount ?? 0);
      return value;
    } catch (error) {
      if (activity !== undefined) await this.finishSafely(activity, LedgerState.FAILED, (error as Error).message);
      throw error as Error;
    } finally { release(); }
  }

  /**
   * 轻操作只保存小型历史摘要，不为账户/启停/删除创建证据目录和Native scope。
   * 上层已完成的业务结果不因Preferences错误回滚，失败仍通过全局日志明确保留。
   */
  async recordSummary(category: string, title: string, status: string, summary: string, startedAt: number = 0): Promise<void> {
    const id = startedAt > 0 ? startedAt : reserveTaskActivityId();
    const endedAt = Math.max(id, Date.now());
    const record: ActivityRecord = { category: category, title: title, versionName: title,
      gameVersion: '-', loaderType: category, startedAt: id, endedAt: endedAt, durationMs: endedAt - id,
      totalBytes: 0, fileCount: 0, status: status, subtitle: summary };
    if (status !== 'success') record.errorMessage = summary;
    try { await getDownloadHistoryStore().add(record); notifyTaskActivityChanged(); }
    catch (error) { AppLogger.warn('ActivityOwner', '轻操作摘要尚未保存：' + title, error, LOG_DOMAIN_DOWNLOAD); }
  }

  /** 业务事实与IO结果分离；失败进入有限退避队列，保留原件，绝不重跑producer。 */
  async finishSafely(activity: BusinessActivity, state: LedgerState, summary: string,
    bytes: number = 0, files: number = 0): Promise<boolean> {
    activity.event('结果：' + summary);
    try {
      await activity.finish(state, summary, bytes, files); this.pending_.delete(activity.id);
      if (this.pending_.size === 0) {
        this.retryDelay_ = 30000;
        if (this.retryTimer_ >= 0) { clearTimeout(this.retryTimer_); this.retryTimer_ = -1; }
      }
      return true;
    }
    catch (error) {
      this.pending_.set(activity.id, activity);
      AppLogger.warn('ActivityOwner', '业务已结束，活动结果待保存：' + activity.id, error, LOG_DOMAIN_DOWNLOAD);
      this.scheduleRetry_();
      return false;
    }
  }

  /** 每批串行补写；最多一个timer和一个执行批次，不在下载进度tick反复写磁盘。 */
  private scheduleRetry_(): void {
    if (!this.foreground_ || this.retryTimer_ >= 0 || this.retryBusy_ || this.pending_.size === 0) return;
    this.retryTimer_ = setTimeout((): void => {
      this.retryTimer_ = -1;
      this.flushPending().catch((error: Error): void => AppLogger.warn('ActivityOwner', '活动IO重试失败', error, LOG_DOMAIN_DOWNLOAD));
    }, this.retryDelay_);
  }

  /** Ability前后台只改变补写资格；后台撤销timer，正在执行的一项结束后保留剩余义务。 */
  setForeground(foreground: boolean): void {
    this.foreground_ = foreground;
    if (!foreground) {
      if (this.retryTimer_ >= 0) { clearTimeout(this.retryTimer_); this.retryTimer_ = -1; }
      return;
    }
    this.flushPending(true).catch((error: Error): void => AppLogger.warn('ActivityOwner', '前台活动补写失败', error, LOG_DOMAIN_DOWNLOAD));
  }

  /**
   * 前台恢复和timer共享singleflight；每四项真正让出事件循环，后台边沿停止领取新项。
   * IO失败不丢原始终态，下轮指数退避；explicitWake只重置等待，不允许并发重入。
   */
  flushPending(explicitWake: boolean = false): Promise<void> {
    if (explicitWake) {
      this.retryDelay_ = 30000;
      if (this.retryTimer_ >= 0) { clearTimeout(this.retryTimer_); this.retryTimer_ = -1; }
    }
    if (this.retryJob_ !== undefined) return this.retryJob_;
    if (this.pending_.size === 0) return Promise.resolve();
    this.retryBusy_ = true;
    const job: Promise<void> = (async (): Promise<void> => {
      const ids = Array.from(this.pending_.keys());
      let processed: number = 0;
      for (const id of ids) {
        if (!this.foreground_) break;
        const activity = this.pending_.get(id);
        if (activity === undefined) continue;
        try { await activity.retryCommit(); this.pending_.delete(id); }
        catch (error) { AppLogger.warn('ActivityOwner', '原活动结果仍待保存：' + id, error, LOG_DOMAIN_DOWNLOAD); }
        if (++processed % 4 === 0) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
      }
      this.retryDelay_ = this.pending_.size === 0 ? 30000 : Math.min(300000, this.retryDelay_ * 2);
    })();
    this.retryJob_ = job.finally((): void => {
      this.retryJob_ = undefined; this.retryBusy_ = false; this.scheduleRetry_();
    });
    return this.retryJob_;
  }
}

const taskActivityOwner: TaskActivityOwner = new TaskActivityOwner();
export function getTaskActivityOwner(): TaskActivityOwner { return taskActivityOwner; }

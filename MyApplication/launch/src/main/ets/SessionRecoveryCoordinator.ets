/**
 * 启动器进程拥有的退出恢复协调器。前台只唤醒新增义务，完整历史发现只在冷启动执行一次。
 * 游戏进程保留自己的原生journal；本服务串行提交终态、历史和展示游标，页面仅消费结果。
 */
import { ledgerManifestAsync, ledgerLaunchManifestsAsync, ledgerEnsureLegacyLaunchAsync, ledgerDirOf,
  ledgerEndAsync, ledgerFlushMaintenanceAsync, ledgerMergeGameMetadataAsync, readLedgerGameTerminalAsync,
  archivePlatformEventFilesAsync, retryPlatformEventFilesAsync, evidenceFileDigestAsync, readSessionEvidenceAsync,
  LedgerOutcome, LedgerState, LedgerManifest, LedgerCommitResult, EvidencePreparationStaleError } from 'commons';
import { acquireEvidenceLease, releaseEvidenceLease } from 'commons';
import { McSessionInfo, SessionMarker } from './SessionMarker';
import { util } from '@kit.ArkTS';
import { writeEvidenceTextAtomicAsync, utf8ByteLength, ensureEvidenceDirectoryAsync } from 'commons';
import { prepareRecoveredSessionOutcome } from './SessionOutcomeResolver';
import { hasSessionRecoveryReceiptAsync } from './JvmExitEvidence';
import { SessionRecoveryState, SessionRecoveryQueue, readRecoveryTextAsync, readRecoveryStateAsync,
  writeRecoveryStateAsync, readRecoveryQueueAsync, writeRecoveryQueueAsync, recoveryIds, recoveryTextDigestAsync } from './SessionRecoveryState';

/** 当前规则改变时强制旧检查点重新核验一次；结果证据revision不能替代本规则和生产者输入。 */
const RECOVERY_POLICY: number = 3;
/** 小型迁移元数据每16条耐久确认一批；失败不推进该批游标，原始日志和单局检查点独立保留。 */
const BOOTSTRAP_BATCH: number = 16;

interface RecoveryInputSnapshot { producerKey: string; inputKey: string; }
interface LaunchBoundarySnapshot { generation: number; nextLaunchAt: number; }
interface BootstrapDecision { id: number; pending: boolean; active: boolean; result: boolean; history?: boolean; }

/** 只传冻结结果到owner端口；历史Preferences和UI状态不跨worker共享。 */
export interface SessionRecoveryResult { session: McSessionInfo; outcome: LedgerOutcome; revision: number; }
export interface SessionRecoveryHooks {
  isIdle: () => boolean;
  applyHistory: (result: SessionRecoveryResult) => Promise<void>;
  changed: () => void;
  /** 前台浏览期间才继续历史补迁；游戏活跃/锁未知仍由isIdle严格阻止。 */
  canMigrate?: () => boolean;
  /** Runtime既有失败交接/stale前置小批也参与game准入屏障，不等待历史后台Promise。 */
  beforeGameAdmission?: () => Promise<void>;
  admissionBarrierCurrent?: () => boolean;
}

/** 进程内单调事实计数，真机前后快照可证明无新义务时没有调用完整resolver。 */
export interface SessionRecoveryStats {
  requests: number; merged: number; resolverCalls: number; consumed: number;
  retries: number; staleRejected: number; pending: number; active: number;
  bootstrapCommits: number; boundaryLookups: number; boundaryGeneration: number;
  historyPending?: number; migrationActive?: boolean; transactionActive?: boolean; gameReservations?: number;
  presentationPending?: number; queuedProtection?: number;
}

/** 复制小型队列后才持久提交，磁盘失败不会把内存状态提前推进成“已经消费”。 */
function copyQueue(queue: SessionRecoveryQueue): SessionRecoveryQueue {
  return { schema: 1, activeIds: queue.activeIds.slice(), pendingIds: queue.pendingIds.slice(),
    resultIds: queue.resultIds.slice(), bootstrapIds: queue.bootstrapIds.slice(), bootstrapCursor: queue.bootstrapCursor,
    historyIds: (queue.historyIds ?? []).slice() };
}

/** 业务结局比较忽略发现时刻；同结局的新证据仍提交证据，只是不重弹同一个结果。 */
function outcomeKey(outcome: LedgerOutcome | undefined): string {
  if (outcome === undefined) return '';
  return JSON.stringify({ state: outcome.state, source: outcome.source, summary: outcome.summary,
    errorKind: outcome.errorKind ?? '', endedAt: outcome.endedAt ?? 0 });
}

/** 轻量canonical业务产物身份，不含recoveredAt/pin/索引等独立派生状态。 */
function manifestOutcomeKey(manifest: LedgerManifest): string {
  return JSON.stringify({ activityId: manifest.activityId, state: manifest.state, source: manifest.outcomeSource,
    summary: manifest.outcomeSummary, errorKind: manifest.errorKind ?? '', endedAt: manifest.endedAt,
    estimated: manifest.endTimeEstimated === true });
}

export class SessionRecoveryCoordinator {
  private filesDir_: string;
  private hooks_: SessionRecoveryHooks;
  private queue_: SessionRecoveryQueue = { schema: 1, activeIds: [], pendingIds: [], resultIds: [], bootstrapIds: [], bootstrapCursor: 0 };
  private initialized_: Promise<void> | undefined = undefined;
  private gate_: Promise<void> = Promise.resolve();
  private draining_: Promise<void> | undefined = undefined;
  private requests_: Map<number, number> = new Map<number, number>();
  private platformEpoch_: number = 1;
  private platformApplied_: number = 0;
  /** 明确wake才推进补采世代；补采失败本身不推进，避免同一wake不断重试不可读报告。 */
  private platformRetryEpoch_: number = 0;
  private platformRetryApplied_: number = 0;
  /** 可覆盖的小型跨进程发布提示只负责唤醒；退出/crash原件与唯一归属仍是权威。 */
  private platformPublicationKey_: string = '';
  /** 本批真实生产者/身份变化只合并一次未归属平台重试，不随普通pin或无变化亮屏增加。 */
  private candidateInputsChanged_: boolean = false;
  /** 首次仅历史补迁的候选变化到整批末合并重试；真实critical输入与game准入不受此延后。 */
  private deferHistoricalCandidates_: boolean = false;
  private criticalCandidatesChanged_: boolean = false;
  private stats_: SessionRecoveryStats = { requests: 0, merged: 0, resolverCalls: 0, consumed: 0,
    retries: 0, staleRejected: 0, pending: 0, active: 0, bootstrapCommits: 0, boundaryLookups: 0, boundaryGeneration: 0 };
  /** 冷启动已核验的launch身份构成有序边界；新意图/本局身份变化只更新受影响相邻项，不读全库。 */
  private launchOrder_: number[] = [];
  private launchIdentities_: Map<number, string> = new Map<number, string>();
  private nextLaunchById_: Map<number, number> = new Map<number, number>();
  private boundaryGeneration_: number = 0;
  /** 合法删除只终止当前来源保护资格，仍保留该次启动的时间界限，不能让更早局越过它补采global日志。 */
  private removedLaunches_: Set<number> = new Set<number>();
  /** 已经实际计算成功的空输入SHA是纯常量；每个缺省文件仍独立做真实缺失核验。 */
  private emptyPublicationDigest_: string | undefined = undefined;
  /** 真正新游戏派发等待整个恢复事务（含legacy/Evidence/canonical在途rename）结束，guard不能替代这份互斥。 */
  private activeRecovery_: Promise<void> | undefined = undefined;
  private admittedLaunches_: Set<number> = new Set<number>();
  /** 浏览准入与历史补迁是不同完成边界；默认initialize仍保留完整兼容入口。 */
  private splitAdmission_: boolean = false;
  private migration_: Promise<void> | undefined = undefined;
  private admissionJobs_: Map<number, Promise<void>> = new Map<number, Promise<void>>();
  private admissionTokens_: Map<number, string> = new Map<number, string>();
  private grantedLaunches_: Set<number> = new Set<number>();
  /** 待办/历史/展示集合本身持轻量保护；用户浏览期间删除API也不能移走尚未处理的原件。 */
  private queuedLeases_: Set<number> = new Set<number>();
  /** enqueue调用开始即递增，不能让尚在读小型manifest的已知新请求从准入末门旁边漏过。 */
  private inputRequestGeneration_: number = 0;
  private waking_: Promise<void> | undefined = undefined;
  private wakeGeneration_: number = 0;
  private wakeRequested_: boolean = false;

  constructor(filesDir: string, hooks: SessionRecoveryHooks) { this.filesDir_ = filesDir; this.hooks_ = hooks; }

  /** 返回值只复制有界计数，不枚举文件、不触发恢复。 */
  stats(): SessionRecoveryStats {
    return { requests: this.stats_.requests, merged: this.stats_.merged, resolverCalls: this.stats_.resolverCalls,
      consumed: this.stats_.consumed, retries: this.stats_.retries, staleRejected: this.stats_.staleRejected,
      pending: this.queue_.pendingIds.length, active: this.queue_.activeIds.length,
      bootstrapCommits: this.stats_.bootstrapCommits, boundaryLookups: this.stats_.boundaryLookups,
      boundaryGeneration: this.boundaryGeneration_, historyPending: (this.queue_.historyIds ?? []).length,
      migrationActive: this.migration_ !== undefined, transactionActive: this.activeRecovery_ !== undefined,
      gameReservations: this.admittedLaunches_.size, presentationPending: this.queue_.resultIds.length,
      queuedProtection: this.queuedLeases_.size };
  }

  /** 只在首次初始化前选择生产分阶段准入；不把已执行的完整初始化回溯改称快速准入。 */
  prepareColdAdmission(): Promise<void> {
    if (this.initialized_ === undefined) this.splitAdmission_ = true;
    return this.initialize();
  }

  hasHistoricalMigration(): boolean { return (this.queue_.historyIds ?? []).length > 0; }

  /** 仅由Ledger实际删除+父目录同步成功后调用；IO未知/null读取不能冒充此owner事实。 */
  observeDeletedActivity(activityId: number): void {
    if (this.queuedLeases_.has(activityId)) throw new Error('已保护恢复义务不能确认删除');
    if (!this.launchIdentities_.has(activityId)) return;
    this.removedLaunches_.add(activityId); this.boundaryGeneration_++;
  }

  /** 只建立一个冷启动任务；失败撤销promise供明确重试，已经耐久的活动检查点继续复用。 */
  initialize(): Promise<void> {
    if (this.initialized_ !== undefined) return this.initialized_;
    const job = this.bootstrap_(); this.initialized_ = job;
    job.catch((): void => { if (this.initialized_ === job) this.initialized_ = undefined; });
    return job;
  }

  /** 队列所有修改经同一owner门；不在裁决全文读取期间锁住门，新事件可以正常入队。 */
  private mutate_(change: (queue: SessionRecoveryQueue) => void): Promise<void> {
    const job = this.gate_.then(async (): Promise<void> => {
      const next = copyQueue(this.queue_); change(next);
      next.activeIds = recoveryIds(next.activeIds); next.pendingIds = recoveryIds(next.pendingIds);
      next.resultIds = recoveryIds(next.resultIds);
      next.historyIds = recoveryIds(next.historyIds ?? []);
      await writeRecoveryQueueAsync(this.filesDir_, next); this.queue_ = next;
      this.syncQueuedLeases_();
    });
    this.gate_ = job.catch((): void => {}); return job;
  }

  private protectQueued_(id: number): void {
    if (this.queuedLeases_.has(id)) return;
    acquireEvidenceLease(this.filesDir_, id); this.queuedLeases_.add(id);
  }

  private syncQueuedLeases_(): void {
    const pending = new Set<number>(this.queue_.activeIds.concat(this.queue_.pendingIds,
      this.queue_.resultIds, this.queue_.historyIds ?? [], this.queue_.bootstrapIds.slice(this.queue_.bootstrapCursor)));
    for (const id of pending) this.protectQueued_(id);
    for (const id of Array.from(this.queuedLeases_)) if (!pending.has(id)) {
      this.queuedLeases_.delete(id); releaseEvidenceLease(this.filesDir_, id);
    }
  }

  /**
   * 结果检查点也复用owner写门。全文准备不占门，但写入时合并已确认展示游标，
   * 避免页面在准备期间确认旧结果后被旧内存副本倒退，或旧UI回调覆盖迟到crash新版本。
   */
  private saveState_(state: SessionRecoveryState): Promise<void> {
    const job = this.gate_.then(async (): Promise<void> => {
      const latest = await readRecoveryStateAsync(this.filesDir_, state.session);
      if (latest.outcomeRevision > state.outcomeRevision) throw new Error('恢复检查点版本变化，旧结果不能提交');
      state.presentationRevision = Math.max(state.presentationRevision,
        Math.min(latest.presentationRevision, state.outcomeRevision));
      state.historyRevision = Math.max(state.historyRevision, Math.min(latest.historyRevision, state.outcomeRevision));
      if (latest.presentationMode === 'auto') state.presentationMode = 'auto';
      await writeRecoveryStateAsync(this.filesDir_, state);
    });
    this.gate_ = job.catch((): void => {}); return job;
  }

  /** 冷启动只读小型身份/发布文件。旧展示回执没有输入收据，必须实际核验后迁移。 */
  private async bootstrap_(): Promise<void> {
    this.queue_ = await readRecoveryQueueAsync(this.filesDir_);
    this.syncQueuedLeases_();
    // 一次真实metadata发现既供迁移，也供后继界限；不能为每个旧局再list/lstat全部目录。
    const entries: LedgerManifest[] = (await ledgerLaunchManifestsAsync(this.filesDir_))
      .sort((left: LedgerManifest, right: LedgerManifest): number => left.startedAt - right.startedAt);
    const manifests: Map<number, LedgerManifest> = new Map<number, LedgerManifest>();
    this.launchOrder_ = []; this.launchIdentities_.clear(); this.nextLaunchById_.clear();
    this.removedLaunches_.clear();
    for (const manifest of entries) { this.protectQueued_(manifest.activityId);
      manifests.set(manifest.activityId, manifest); this.observeLaunch_(manifest); }
    // 上次进程已登记但game baseline尚未出现的意图也是保守边界；只有明确同token撤回才移除。
    for (const id of this.queue_.activeIds) if (!manifests.has(id)) this.observeIntent_(id, '');
    if (this.queue_.bootstrapIds.length === 0) {
      const ids: number[] = entries.map((entry: LedgerManifest): number => entry.activityId)
        .sort((a: number, b: number): number => a - b);
      await this.mutate_((queue): void => { queue.bootstrapIds = ids; queue.bootstrapCursor = 0; });
      this.stats_.bootstrapCommits++;
    }
    while (this.queue_.bootstrapCursor < this.queue_.bootstrapIds.length) {
      const start: number = this.queue_.bootstrapCursor;
      const end: number = Math.min(start + BOOTSTRAP_BATCH, this.queue_.bootstrapIds.length);
      const decisions: BootstrapDecision[] = [];
      for (let cursor = start; cursor < end; cursor++) {
        const id = this.queue_.bootstrapIds[cursor];
        const manifest = manifests.get(id);
        if (manifest === undefined) throw new Error('迁移活动清单丢失或损坏，未处理批次游标保留');
        const session = this.session_(manifest);
        const state = await readRecoveryStateAsync(this.filesDir_, session);
        const active = manifest.state === LedgerState.RUNNING || this.queue_.activeIds.includes(id);
        const result = state.presentationMode !== 'history' && state.outcome !== undefined
          && state.presentationRevision < state.outcomeRevision;
        if (this.splitAdmission_) {
          // ended的完整SHA/补采属于后台迁移；旧队列未完成提交和实际待展示仍保守保留前台资格。
          let critical = active || result || this.queue_.pendingIds.includes(id)
            || state.presentationMode !== 'history' && state.historyRevision < state.outcomeRevision;
          let needsHistory = state.policy !== RECOVERY_POLICY || state.inputKey.length === 0
            || state.outcome === undefined || state.historyRevision < state.outcomeRevision;
          if (!critical && !needsHistory) {
            // 已迁移cold仍核验受管小发布与提交产物，避免每次启动把128个已消费局重新排队/fsync。
            // 真正新输入升级必要义务；仅派生产物修复仍后台处理。缺旧消费key的首次迁移不SHA原件。
            const key = await this.inputKey_(manifest);
            critical = key !== state.inputKey;
            needsHistory = !critical && !await this.artifactsMatch_(manifest, state);
          }
          decisions.push({ id: id, pending: critical, active: active, result: result, history: !critical && needsHistory });
        } else {
          const key = await this.inputKey_(manifest);
          const artifactsMatch = await this.artifactsMatch_(manifest, state);
          decisions.push({ id: id, pending: state.inputKey !== key || state.policy !== RECOVERY_POLICY
            || !artifactsMatch || state.historyRevision < state.outcomeRevision, active: active, result: result });
        }
      }
      // 全批核验结束后只写一次队列；途中读取或同步失败，既有cursor仍指向整批起点。
      await this.mutate_((queue): void => {
        for (const decision of decisions) {
          if (decision.pending) queue.pendingIds.push(decision.id);
          if (decision.history) (queue.historyIds ?? (queue.historyIds = [])).push(decision.id);
          else queue.historyIds = (queue.historyIds ?? []).filter((id): boolean => id !== decision.id);
          if (decision.active) queue.activeIds.push(decision.id);
          if (decision.result) queue.resultIds.push(decision.id);
          else queue.resultIds = queue.resultIds.filter((id): boolean => id !== decision.id);
        }
        queue.bootstrapCursor = end;
      });
      this.stats_.bootstrapCommits++;
    }
    await this.mutate_((queue): void => { queue.bootstrapIds = []; queue.bootstrapCursor = 0; });
    this.stats_.bootstrapCommits++;
  }

  /** 活动ID本来就是启动时间；身份损坏不能参与边界推断或让未来游戏落到旧局。 */
  private observeLaunch_(manifest: LedgerManifest): void {
    if (manifest.category !== 'launch' || !Number.isSafeInteger(manifest.activityId) || manifest.activityId <= 0
      || manifest.startedAt !== manifest.activityId) throw new Error('launch边界身份无效，恢复已停止');
    this.removedLaunches_.delete(manifest.activityId);
    this.observeBoundary_(manifest.activityId, JSON.stringify({ activityId: manifest.activityId,
      startedAt: manifest.startedAt, runNonce: manifest.runNonce ?? '', ownerPid: manifest.ownerPid ?? 0 }));
  }

  /** 有序插入只更新前一局与当前局的后继项；整库排序/metadata读取只发生在cold发现。 */
  private observeBoundary_(id: number, identity: string): void {
    if (this.launchIdentities_.get(id) === identity) return;
    if (!this.launchIdentities_.has(id)) {
      let left = 0, right = this.launchOrder_.length;
      while (left < right) { const middle = Math.floor((left + right) / 2);
        if (this.launchOrder_[middle] < id) left = middle + 1; else right = middle; }
      const next = this.launchOrder_[left] ?? 0;
      if (left > 0) this.nextLaunchById_.set(this.launchOrder_[left - 1], id);
      this.launchOrder_.splice(left, 0, id); this.nextLaunchById_.set(id, next);
    }
    this.launchIdentities_.set(id, identity); this.boundaryGeneration_++;
  }

  private observeIntent_(id: number, token: string): void {
    // canonical身份优先，焦点/同ID重试意图不能用一个空PID覆盖已有真实会话身份。
    const existing = this.launchIdentities_.get(id);
    if (existing !== undefined && !existing.startsWith('intent:')) return;
    this.observeBoundary_(id, 'intent:' + token);
  }

  private withdrawIntentBoundary_(id: number): void {
    if (!this.launchIdentities_.get(id)?.startsWith('intent:')) return;
    const position = this.launchOrder_.indexOf(id); const next = this.nextLaunchById_.get(id) ?? 0;
    if (position > 0) this.nextLaunchById_.set(this.launchOrder_[position - 1], next);
    if (position >= 0) this.launchOrder_.splice(position, 1);
    this.launchIdentities_.delete(id); this.nextLaunchById_.delete(id); this.boundaryGeneration_++;
  }

  /** 当前与提交前都从同一owner索引取值；不把未知0永久缓存，不以锁两次空闲替代世代复核。 */
  private boundary_(id: number): LaunchBoundarySnapshot {
    this.stats_.boundaryLookups++;
    return { generation: this.boundaryGeneration_, nextLaunchAt: this.nextLaunchById_.get(id) ?? 0 };
  }

  private boundaryCurrent_(id: number, expected: LaunchBoundarySnapshot): boolean {
    return expected.generation === this.boundaryGeneration_ && expected.nextLaunchAt === (this.nextLaunchById_.get(id) ?? 0);
  }

  private session_(manifest: LedgerManifest): McSessionInfo {
    return { startedAt: manifest.activityId, version: manifest.gameVersionId || manifest.title,
      mcDir: manifest.mcDir, endedAt: manifest.endedAt > 0 && manifest.endTimeEstimated !== true ? manifest.endedAt : undefined };
  }

  /** 只检查小型提交产物，不读取日志正文；损坏/缺少Evidence重新打开义务，不能信旧state结果。 */
  private async artifactsMatch_(manifest: LedgerManifest, state: SessionRecoveryState): Promise<boolean> {
    if (state.committedOutcomeKey !== manifestOutcomeKey(manifest)) return false;
    const evidence = await readSessionEvidenceAsync(this.filesDir_, manifest.activityId);
    if (evidence === undefined || evidence.revision !== state.committedEvidenceRevision) return false;
    return state.committedEvidenceKey === await evidenceFileDigestAsync(ledgerDirOf(this.filesDir_, manifest.activityId) + '/evidence-manifest.json');
  }

  /**
   * 只有受管小型发布原文和精确平台终态参与快路径。字段原文变化可识别同大小producer改写。
   * 未公告的外部日志改写无法凭mtime证明，仍由冷启动/补采、阅读和外发完整核验入口检查。
   */
  private async producerInputKey_(manifest: LedgerManifest): Promise<string> {
    const directory = ledgerDirOf(this.filesDir_, manifest.activityId);
    const paths: string[] = [this.filesDir_ + '/game-exits/' + manifest.activityId + '.json',
      directory + '/native-io.json', directory + '/capture-game.json',
      directory + '/game-terminal.json', directory + '/game-metadata.json'];
    const publications: string[] = [];
    for (const path of paths) {
      const text = await readRecoveryTextAsync(path, 65536);
      if (text.length === 0 && this.emptyPublicationDigest_ !== undefined) publications.push(this.emptyPublicationDigest_);
      else {
        const digest = await recoveryTextDigestAsync(text); publications.push(digest);
        if (text.length === 0) this.emptyPublicationDigest_ = digest;
      }
    }
    return recoveryTextDigestAsync(JSON.stringify({ activityId: manifest.activityId, runNonce: manifest.runNonce ?? '',
      ownerPid: manifest.ownerPid ?? 0, publications: publications }));
  }

  /** 平台附件与业务终态参与消费身份；生产者身份单独比较，避免补齐报告触发全量发现。 */
  private async inputKey_(manifest: LedgerManifest): Promise<string> {
    return (await this.inputSnapshot_(manifest)).inputKey;
  }

  /** 准备阶段一次冻结producer/input两个key；CAS前/后仍重新独立读取，不把这份快照复用于提交核验。 */
  private async inputSnapshot_(manifest: LedgerManifest): Promise<RecoveryInputSnapshot> {
    const platform: string = manifest.outcomeSource.startsWith('platform.')
      ? JSON.stringify({ state: manifest.state, source: manifest.outcomeSource, summary: manifest.outcomeSummary,
        endedAt: manifest.endedAt, estimated: manifest.endTimeEstimated }) : '';
    const producerKey = await this.producerInputKey_(manifest);
    const inputKey = await recoveryTextDigestAsync(JSON.stringify({ producer: producerKey, platform: platform,
      platformInputKey: manifest.platformInputKey ?? '' }));
    return { producerKey: producerKey, inputKey: inputKey };
  }

  /** 派发游戏之前调用并等待耐久完成，退出后可直接按ID发现journal，不扫描全部历史。 */
  async trackLaunch(activityId: number, intentToken: string = ''): Promise<void> {
    await this.initialize();
    if (!Number.isSafeInteger(activityId) || activityId <= 0) throw new Error('启动意图活动身份无效');
    if (intentToken.length > 0 && !new RegExp('^[a-zA-Z0-9-]{1,128}$').test(intentToken)) throw new Error('启动意图token无效');
    const existingJob = this.admissionJobs_.get(activityId);
    if (existingJob !== undefined && this.admissionTokens_.get(activityId) === intentToken) return existingJob;
    if (this.admittedLaunches_.size > 0 && !this.admittedLaunches_.has(activityId)) {
      throw new Error('已有另一启动准入意图，等待其派发或同身份撤回');
    }
    if (this.admittedLaunches_.has(activityId)) {
      if (this.admissionTokens_.get(activityId) !== intentToken) throw new Error('同活动已有不同启动准入token，原意图保留');
      if (this.grantedLaunches_.has(activityId)) return;
      // 只有成功返回的grant才可复用。失败保留的reserved同token必须重新完成全部保护事务。
    }
    // JS owner中从初检到占位没有任何await；两个不同ID即使同时进入也不能跨过同一准入门。
    this.admittedLaunches_.add(activityId); this.admissionTokens_.set(activityId, intentToken);
    const job = this.admitLaunch_(activityId, intentToken); this.admissionJobs_.set(activityId, job);
    try { await job; this.grantedLaunches_.add(activityId); }
    catch (error) {
      // 只有明确从未发布意图/active队列才能释放纯内存占位；可见或耐久未知字节都交同token失败原件撤回。
      if (!this.queue_.activeIds.includes(activityId)
        && (await readRecoveryTextAsync(this.filesDir_ + '/logs/recovery/intents/' + activityId + '.json', 4096)).length === 0) {
        this.admittedLaunches_.delete(activityId); this.admissionTokens_.delete(activityId); this.withdrawIntentBoundary_(activityId);
        this.grantedLaunches_.delete(activityId);
      }
      throw error as Error;
    } finally { if (this.admissionJobs_.get(activityId) === job) this.admissionJobs_.delete(activityId); }
  }

  private async admitLaunch_(activityId: number, intentToken: string): Promise<void> {
    if (intentToken.length > 0) {
      if (!new RegExp('^[a-zA-Z0-9-]{1,128}$').test(intentToken)) throw new Error('启动意图token无效');
      const directory: string = this.filesDir_ + '/logs/recovery/intents';
      await ensureEvidenceDirectoryAsync(directory);
      const path: string = directory + '/' + activityId + '.json';
      const text: string = JSON.stringify({ schema: 1, activityId: activityId, intentToken: intentToken });
      const existing: string = await readRecoveryTextAsync(path, 4096);
      if (existing.length > 0 && existing !== text) throw new Error('同活动已有不同启动意图，原件保留');
      if (existing.length === 0) await writeEvidenceTextAtomicAsync(path, text);
    }
    await this.mutate_((queue): void => { queue.activeIds.push(activityId); });
    this.observeIntent_(activityId, intentToken);
    // 先推进边界使旧准备失效，再等待其全部发布IO真实settled，调用方此后才能触碰新局mutable源。
    const active = this.activeRecovery_;
    if (active !== undefined) await active.catch((): void => { /* 原错误仍由原恢复Promise及持久待办报告。 */ });
    const draining = this.draining_;
    if (draining !== undefined) await draining.catch((): void => {});
    const waking = this.waking_;
    if (waking !== undefined) await waking;
    if (this.hooks_.beforeGameAdmission !== undefined) await this.hooks_.beforeGameAdmission();
    if (!this.hooks_.isIdle()) throw new Error('游戏启动准入时进程活跃或状态未知，意图保留');
    if (this.splitAdmission_) await this.drainInternal_(true);
    // 只保护即将被新游戏覆盖的最近一局mutable来源。更早局的独立归档迁移继续后台排队，
    // 这一完整事务同样包括copy/Evidence/canonical/native rename，结束之后才返回派发端。
    const lastBoundary = this.launchOrder_.filter((id: number): boolean => id < activityId).pop();
    // 最近来源owner已被用户/保留策略明确删除时，不读取其不存在的manifest，也不倒退选择更早局。
    // 更早局的nextLaunch界限仍包含这份已删除启动事实，后来的global日志不得重新归给它。
    const previous = lastBoundary !== undefined && !this.removedLaunches_.has(lastBoundary) ? lastBoundary : undefined;
    if (this.splitAdmission_ && previous !== undefined && (this.queue_.historyIds ?? []).includes(previous)) {
      const manifest = await ledgerManifestAsync(this.filesDir_, previous);
      if (manifest === null) throw new Error('新游戏覆盖来源保护清单不可读，启动意图保留');
      const recovery = this.recover_(manifest, true, true); this.activeRecovery_ = recovery;
      try { await recovery; }
      finally { if (this.activeRecovery_ === recovery) this.activeRecovery_ = undefined; }
      if (this.queue_.pendingIds.includes(previous)) throw new Error('游戏启动前来源保护出现新输入，需再次恢复');
      await this.mutate_((queue): void => { queue.historyIds = (queue.historyIds ?? []).filter((id): boolean => id !== previous); });
    }
    while (this.splitAdmission_) {
      if (!this.hooks_.isIdle()) throw new Error('游戏启动准入期间进程状态变化，意图保留');
      // 再读marker/平台publication及已知active，随后专属必要drain；新消息不要求等待所有旧历史。
      await this.wake(); await this.drainInternal_(true);
      if (this.hooks_.beforeGameAdmission !== undefined) await this.hooks_.beforeGameAdmission();
      const requestGeneration = this.inputRequestGeneration_;
      const wakeGeneration = this.wakeGeneration_;
      const boundary = this.boundary_(activityId);
      if (previous !== undefined) {
        const manifest = await ledgerManifestAsync(this.filesDir_, previous);
        if (manifest === null) throw new Error('游戏准入末门无法读取上局保护清单');
        const state = await readRecoveryStateAsync(this.filesDir_, this.session_(manifest));
        if (state.inputKey !== await this.inputKey_(manifest)) { await this.enqueue(previous); continue; }
      }
      // 最后一段异步producer核验之后，经同owner门廉价复核已知输入世代/义务/边界/锁。
      // 这一回调成功到Promise返回之间没有文件IO；dispatch之后的新事实仍由自身journal义务恢复。
      let admitted = false;
      const check = this.gate_.then((): void => {
        admitted = requestGeneration === this.inputRequestGeneration_ && this.queue_.pendingIds.length === 0
          && wakeGeneration === this.wakeGeneration_ && this.waking_ === undefined
          && this.platformApplied_ === this.platformEpoch_ && this.platformRetryApplied_ === this.platformRetryEpoch_
          && this.boundaryCurrent_(activityId, boundary) && this.hooks_.isIdle()
          && (this.hooks_.admissionBarrierCurrent === undefined || this.hooks_.admissionBarrierCurrent());
      });
      this.gate_ = check.catch((): void => {}); await check;
      if (admitted) break;
    }
  }

  /**
   * 父派发失败先保存原始错误，再在owner门内撤回确实未建账的同token意图。
   * 锁未知/已活跃、已有canonical或producer事实都不授权撤回，不能把丢失账本当未启动。
   * 意图和错误原件留存；迟到marker仍可按既有入队入口重新建立恢复义务。
   */
  async recordLaunchDispatchFailure(activityId: number, intentToken: string, stage: string, rawError: string): Promise<boolean> {
    if (!Number.isSafeInteger(activityId) || activityId <= 0 || !new RegExp('^[a-zA-Z0-9-]{1,128}$').test(intentToken)
      || stage.length === 0 || stage.length > 128 || rawError.length > 65536) throw new Error('启动派发失败原件身份或大小无效');
    const directory: string = this.filesDir_ + '/logs/recovery/dispatch-failures';
    await ensureEvidenceDirectoryAsync(directory);
    const path: string = directory + '/' + activityId + '-' + intentToken + '.json';
    const text: string = JSON.stringify({ schema: 1, activityId: activityId, intentToken: intentToken, stage: stage, rawError: rawError });
    if (utf8ByteLength(text) > 131072) throw new Error('启动派发失败原件超过持久读取上限，意图保留');
    const existing: string = await readRecoveryTextAsync(path, 131072);
    if (existing.length > 0 && existing !== text) {
      // 重复回调带不同事实时保存另一份原文，固定交接原件保持首个发布；不静默最后写者覆盖。
      await writeEvidenceTextAtomicAsync(directory + '/' + activityId + '-' + intentToken + '-' + util.generateRandomUUID() + '.json', text);
      throw new Error('同启动意图已有不同派发失败原件，双方原文已保留等待核实');
    }
    if (existing.length === 0) await writeEvidenceTextAtomicAsync(path, text);
    // 独立错误原文不依赖bootstrap成功；队列初始化失败仍可留下本次未派发的可信事实。
    await this.initialize();
    let withdrawn: boolean = false;
    const job = this.gate_.then(async (): Promise<void> => {
      if (!this.hooks_.isIdle()) return;
      const intentText = await readRecoveryTextAsync(this.filesDir_ + '/logs/recovery/intents/' + activityId + '.json', 4096);
      if (intentText.length === 0) return;
      const intent = JSON.parse(intentText) as Record<string, Object>;
      if (intent['schema'] !== 1 || intent['activityId'] !== activityId || intent['intentToken'] !== intentToken) return;
      for (const path of [ledgerDirOf(this.filesDir_, activityId) + '/manifest.json',
        this.filesDir_ + '/game-exits/' + activityId + '.json', ledgerDirOf(this.filesDir_, activityId) + '/game-terminal.json']) {
        if ((await readRecoveryTextAsync(path)).length > 0) return;
      }
      const marker = await SessionMarker.readPendingAsync(this.filesDir_);
      if (marker?.startedAt === activityId || !this.hooks_.isIdle()) return;
      const next = copyQueue(this.queue_);
      next.activeIds = next.activeIds.filter((id): boolean => id !== activityId);
      next.pendingIds = next.pendingIds.filter((id): boolean => id !== activityId);
      next.historyIds = (next.historyIds ?? []).filter((id): boolean => id !== activityId);
      await writeRecoveryQueueAsync(this.filesDir_, next); this.queue_ = next; withdrawn = true;
      this.syncQueuedLeases_();
      this.withdrawIntentBoundary_(activityId);
      this.admittedLaunches_.delete(activityId);
      this.admissionTokens_.delete(activityId);
      this.grantedLaunches_.delete(activityId);
    });
    this.gate_ = job.catch((): void => {}); await job; return withdrawn;
  }

  /** 已耐久保存错误但撤回队列失败时，下一wake按同ID原件补完；不枚举整个错误归档。 */
  private async reconcileLaunchDispatchFailure_(activityId: number): Promise<boolean> {
    const text = await readRecoveryTextAsync(this.filesDir_ + '/logs/recovery/intents/' + activityId + '.json', 4096);
    if (text.length === 0) return false;
    const intent = JSON.parse(text) as Record<string, Object>;
    const token = intent['intentToken'];
    if (intent['schema'] !== 1 || intent['activityId'] !== activityId || typeof token !== 'string'
      || !new RegExp('^[a-zA-Z0-9-]{1,128}$').test(token)) throw new Error('启动意图身份无效，原件保留');
    const failureText = await readRecoveryTextAsync(this.filesDir_ + '/logs/recovery/dispatch-failures/' + activityId + '-' + token + '.json', 131072);
    if (failureText.length === 0) return false;
    const failure = JSON.parse(failureText) as Record<string, Object>;
    if (failure['schema'] !== 1 || failure['activityId'] !== activityId || failure['intentToken'] !== token
      || typeof failure['stage'] !== 'string' || typeof failure['rawError'] !== 'string') throw new Error('启动派发失败原件身份无效，原件保留');
    return this.recordLaunchDispatchFailure(activityId, token, failure['stage'] as string, failure['rawError'] as string);
  }

  /** 新原件/平台证据请求合并为一份待办；运行中追加同ID会推进世代，旧回调不能清走它。 */
  async enqueue(activityId: number): Promise<void> {
    this.inputRequestGeneration_++;
    await this.initialize();
    const manifest = await ledgerManifestAsync(this.filesDir_, activityId);
    if (manifest?.category === 'launch') this.observeLaunch_(manifest);
    this.stats_.requests++;
    if (this.queue_.pendingIds.includes(activityId)) this.stats_.merged++;
    this.requests_.set(activityId, (this.requests_.get(activityId) ?? 0) + 1);
    await this.mutate_((queue): void => { queue.pendingIds.push(activityId);
      queue.historyIds = (queue.historyIds ?? []).filter((id): boolean => id !== activityId); });
  }

  /** 平台系统回调仅在原文耐久后调用此方法；不在回调中匹配活动或复制外部大报告。 */
  notifyPlatformPublication(): void { this.platformEpoch_++; }

  /**
   * 前台仅检查已知active/pending ID及marker；无变化时不枚举game-exits或全部账本。
   * marker入队和同身份清除占用短owner门，新游戏trackLaunch完成后才能派发，避免旧清理跨局。
   */
  wake(): Promise<void> {
    if (this.waking_ !== undefined) { this.wakeRequested_ = true; return this.waking_; }
    this.wakeGeneration_++;
    const job = (async (): Promise<void> => {
      do { this.wakeRequested_ = false; await this.wakeInternal_(); } while (this.wakeRequested_);
    })(); this.waking_ = job;
    const clear = (): void => { if (this.waking_ === job) this.waking_ = undefined; };
    job.then(clear, clear); return job;
  }

  /** marker建legacy/Evidence和clear也纳入singleflight，存在manifest不代表前一个Ensure已经完整收尾。 */
  private async wakeInternal_(): Promise<void> {
    await this.initialize();
    if (!this.hooks_.isIdle()) return;
    const platformKey = await readRecoveryTextAsync(this.filesDir_ + '/logs/platform-events/publication.json', 4096);
    if (platformKey !== this.platformPublicationKey_) { this.platformPublicationKey_ = platformKey; this.platformEpoch_++; }
    const marker = await SessionMarker.readPendingAsync(this.filesDir_);
    if (marker !== null) {
      // sole旧marker没有账本时先耐久保留会话身份；只建legacy最小清单，不伪造capture/完整性。
      await ledgerEnsureLegacyLaunchAsync(this.filesDir_, marker.startedAt, { category: 'launch',
        title: marker.version, gameVersionId: marker.version, mcDir: marker.mcDir });
      await this.enqueue(marker.startedAt);
      const clearJob = this.gate_.then(async (): Promise<void> => {
        if (this.hooks_.isIdle()) await SessionMarker.clearMatchingAsync(this.filesDir_, marker);
      });
      this.gate_ = clearJob.catch((): void => {}); await clearJob;
    }
    // 已知在运行的一局可能没有marker（JVM更早退出）；按ID检查并加入待办即可。
    for (const id of this.queue_.activeIds.slice()) {
      if (await this.reconcileLaunchDispatchFailure_(id)) continue;
      if (this.admittedLaunches_.has(id)) {
        const manifest = await ledgerManifestAsync(this.filesDir_, id);
        if (manifest === null) continue; // 本进程已经准入但尚未建baseline，不能把正常派发窗口当清单丢失。
        if (!this.hooks_.isIdle()) return;
        if (marker?.startedAt !== id && (await readRecoveryTextAsync(this.filesDir_ + '/game-exits/' + id + '.json', 65536)).length === 0
          && (await readRecoveryTextAsync(ledgerDirOf(this.filesDir_, id) + '/game-terminal.json', 65536)).length === 0) continue;
        this.observeLaunch_(manifest); this.admittedLaunches_.delete(id);
        this.admissionTokens_.delete(id);
        this.grantedLaunches_.delete(id);
      }
      await this.enqueue(id);
    }
    this.platformRetryEpoch_++;
    await this.drain_();
  }

  /** singleflight只合并唤醒；循环持续看到新的待办/平台世代，不能返回旧promise后丢新增工作。 */
  private drain_(): Promise<void> {
    if (this.draining_ !== undefined) return this.draining_;
    const job = this.drainInternal_().catch((error: Error): never => { this.stats_.retries++; throw error; });
    this.draining_ = job;
    job.then((): void => { if (this.draining_ === job) this.draining_ = undefined; },
      (): void => { if (this.draining_ === job) this.draining_ = undefined; });
    return job;
  }

  private async drainInternal_(gameAdmission: boolean = false): Promise<void> {
    while (this.hooks_.isIdle()) {
      if (this.admittedLaunches_.size > 0 && !gameAdmission) break;
      // 背景完整事务最多一局。必要义务只等这一局在途发布settled，然后立即获得优先权；
      // 不等待整条历史Promise，因此首页和新增平台事实不会被128局历史队列串行挡住。
      const active = this.activeRecovery_;
      if (active !== undefined) { await active.catch((): void => {}); continue; }
      if (this.platformRetryApplied_ !== this.platformRetryEpoch_) {
        const epoch: number = this.platformRetryEpoch_;
        // 已归属未完成报告只按耐久小集合补采；没有新发布时不会再次发现全部平台原件。
        for (const id of await retryPlatformEventFilesAsync(this.filesDir_)) await this.enqueue(id);
        this.platformRetryApplied_ = epoch;
      }
      if (this.platformApplied_ !== this.platformEpoch_) {
        const epoch = this.platformEpoch_;
        const affected = await archivePlatformEventFilesAsync(this.filesDir_);
        for (const id of affected) await this.enqueue(id);
        this.platformApplied_ = epoch;
      }
      const id: number | undefined = this.queue_.pendingIds[0];
      if (id === undefined) {
        await this.gate_;
        if (this.queue_.pendingIds.length === 0 && this.candidateInputsChanged_
          && (!this.deferHistoricalCandidates_ || this.criticalCandidatesChanged_ || gameAdmission)) {
          this.candidateInputsChanged_ = false; this.criticalCandidatesChanged_ = false; this.platformEpoch_++; continue;
        }
        if (this.queue_.pendingIds.length === 0 && this.platformApplied_ === this.platformEpoch_) break;
        continue;
      }
      const request = this.requests_.get(id) ?? 0;
      const manifest = await ledgerManifestAsync(this.filesDir_, id);
      if (manifest === null) throw new Error('待恢复活动清单丢失或损坏，原件和待办保留等待重试');
      const recovery = this.recover_(manifest, false, gameAdmission); this.activeRecovery_ = recovery;
      try { await recovery; }
      finally { if (this.activeRecovery_ === recovery) this.activeRecovery_ = undefined; }
      await this.mutate_((queue): void => {
        if ((this.requests_.get(id) ?? 0) === request) queue.pendingIds = queue.pendingIds.filter((value): boolean => value !== id);
        if (manifest !== null) queue.activeIds = queue.activeIds.filter((value): boolean => value !== id);
      });
    }
    if (this.hooks_.isIdle()) await ledgerFlushMaintenanceAsync(this.filesDir_);
  }

  /** 低优先补迁只在前台空闲逐局执行；每局真实异步IO让步，必要队列始终先处理。 */
  backgroundMigration(): Promise<void> {
    if (this.migration_ !== undefined) return this.migration_;
    const job = this.migrateHistory_(); this.migration_ = job;
    const clear = (): void => { if (this.migration_ === job) this.migration_ = undefined; };
    job.then(clear, clear); return job;
  }

  private async migrateHistory_(): Promise<void> {
    await this.initialize();
    this.deferHistoricalCandidates_ = true;
    try {
    while (this.hooks_.isIdle() && (this.hooks_.canMigrate === undefined || this.hooks_.canMigrate())
      && this.admittedLaunches_.size === 0) {
      await this.drain_();
      if (!this.hooks_.isIdle() || this.admittedLaunches_.size > 0
        || this.hooks_.canMigrate !== undefined && !this.hooks_.canMigrate()) break;
      const id = (this.queue_.historyIds ?? [])[0]; if (id === undefined) break;
      const manifest = await ledgerManifestAsync(this.filesDir_, id);
      if (manifest === null) throw new Error('历史迁移活动清单不可读，未完成义务保留');
      // await读取期间critical drain可能开始。复核并让其先完成，不并发两条发布事务。
      if (this.activeRecovery_ !== undefined || this.queue_.pendingIds.length > 0) continue;
      if (this.admittedLaunches_.size > 0 || !this.hooks_.isIdle()) break;
      const recovery = this.recover_(manifest, true); this.activeRecovery_ = recovery;
      try { await recovery; }
      finally { if (this.activeRecovery_ === recovery) this.activeRecovery_ = undefined; }
      await this.mutate_((queue): void => { queue.historyIds = (queue.historyIds ?? []).filter((value): boolean => value !== id); });
    }
    } finally { this.deferHistoricalCandidates_ = false; }
    // 多个旧终点/元信息补齐后统一匹配未归属平台原件，不能为每局再读全候选库。
    // 游戏已经准入时drain保留旗标；下一明确空闲wake或专属准入drain会续办。
    await this.drain_();
    this.hooks_.changed();
  }

  /** 完整裁决只有输入变化时执行；同结局新证据仍走单局提交，而历史/展示按结果版本去重。 */
  private async recover_(manifest: LedgerManifest, historyOnly: boolean = false, gameAdmission: boolean = false): Promise<void> {
    acquireEvidenceLease(this.filesDir_, manifest.activityId);
    try {
    const id = manifest.activityId; const session = this.session_(manifest);
    const state = await readRecoveryStateAsync(this.filesDir_, session);
    await ledgerMergeGameMetadataAsync(this.filesDir_, id);
    const current = await ledgerManifestAsync(this.filesDir_, id);
    if (current === null) throw new Error('恢复活动清单在准备期间不可读，原件保留');
    this.observeLaunch_(current);
    const input = await this.inputSnapshot_(current);
    const key = input.inputKey; const producerKey = input.producerKey;
    // 本次仅补迁不能伪称已经展示。存在旧消费key后真的新producer/platform输入可升级自动义务；
    // 单纯第一次建立policy/检查点或修复派生产物仍只进入历史，保留原展示与用户选择。
    const newlyPublished = state.inputKey.length > 0 && key !== state.inputKey;
    const previousMode = state.presentationMode;
    state.presentationMode = !historyOnly || newlyPublished || state.presentationMode === 'auto' ? 'auto' : 'history';
    let modeSaved = false;
    if (producerKey !== state.producerInputKey) {
      this.candidateInputsChanged_ = true;
      if (!historyOnly) this.criticalCandidatesChanged_ = true;
    }
    const artifactsMatch = await this.artifactsMatch_(current, state);
    if (key !== state.inputKey || state.policy !== RECOVERY_POLICY || !artifactsMatch) {
      const boundary = this.boundary_(id); const nextLaunchAt = boundary.nextLaunchAt;
      // intent已经耐久建立但还没有获准碰新局来源。仅这份真正的派发互斥允许旧来源
      // 在intent时间已到之后补采；已有canonical后继或非owner新输入继续沿旧保守边界拒绝。
      const protectedIntentBoundary = gameAdmission && this.admittedLaunches_.has(nextLaunchAt)
        && this.launchIdentities_.get(nextLaunchAt)?.startsWith('intent:') === true;
      const terminal = await readLedgerGameTerminalAsync(this.filesDir_, id);
      // game-terminal是生产者事实，不是免于平台/真实报告复核的最终判决。
      this.stats_.resolverCalls++;
      let outcome: LedgerOutcome;
      try {
        outcome = await prepareRecoveredSessionOutcome(this.filesDir_, id, nextLaunchAt, terminal?.outcome,
          (): boolean => this.boundaryCurrent_(id, boundary) && this.hooks_.isIdle(), protectedIntentBoundary);
      } catch (error) {
        if (error instanceof EvidencePreparationStaleError && !this.boundaryCurrent_(id, boundary)) {
          this.stats_.staleRejected++; await this.enqueue(id); return;
        }
        if (error instanceof EvidencePreparationStaleError && !this.hooks_.isIdle()) {
          this.stats_.staleRejected++; throw new Error('游戏进程重新活跃或状态未知，恢复提交已延后');
        }
        throw error as Error;
      }
      if (!this.hooks_.isIdle()) { this.stats_.staleRejected++; throw new Error('游戏进程重新活跃或状态未知，恢复提交已延后'); }
      const latest = await ledgerManifestAsync(this.filesDir_, id);
      const latestKey = latest === null ? '' : await this.inputKey_(latest);
      if (latest === null || latest.runNonce !== current.runNonce
        || latestKey !== key || !this.boundaryCurrent_(id, boundary)) {
        this.stats_.staleRejected++;
        await this.enqueue(id); return;
      }
      let commit: LedgerCommitResult;
      try {
        commit = await ledgerEndAsync(this.filesDir_, id, outcome, { nextLaunchAt: nextLaunchAt, inputKey: key,
          expectedManifestRevision: latest.revision, capturePrepared: true, repairArtifacts: !artifactsMatch,
          commitGuard: (): boolean => this.boundaryCurrent_(id, boundary) && this.hooks_.isIdle() });
      } catch (error) {
        if (error instanceof EvidencePreparationStaleError && !this.boundaryCurrent_(id, boundary)) {
          this.stats_.staleRejected++; await this.enqueue(id); return;
        }
        throw error as Error;
      }
      const legacy = state.outcome === undefined;
      if (outcomeKey(state.outcome) !== outcomeKey(outcome)) state.outcomeRevision++;
      // 旧回执只确认已经展示过相同业务结局；迁移仍实际核验本次输入，并独立补历史投影。
      if (legacy && await hasSessionRecoveryReceiptAsync(this.filesDir_, id, outcome)) {
        state.presentationRevision = state.outcomeRevision;
      }
      state.outcome = outcome;
      const committed = await ledgerManifestAsync(this.filesDir_, id);
      if (committed === null) throw new Error('终态提交后无法重新确认活动，保留待办');
      state.session = this.session_(committed);
      // 只确认本次冻结输入。提交await期间出现的新journal不能被事后读取的key顺手消费。
      state.inputKey = key; state.producerInputKey = producerKey; state.policy = RECOVERY_POLICY;
      state.committedManifestRevision = commit.outcomeRevision;
      state.committedEvidenceRevision = commit.evidenceRevision;
      state.committedOutcomeKey = manifestOutcomeKey(committed);
      state.committedEvidenceKey = await evidenceFileDigestAsync(ledgerDirOf(this.filesDir_, id) + '/evidence-manifest.json');
      await this.saveState_(state);
      modeSaved = true;
      this.stats_.consumed++;
      if (await this.inputKey_(committed) !== key) await this.enqueue(id);
    }
    if (state.outcome === undefined) return;
    const result: SessionRecoveryResult = { session: state.session, outcome: state.outcome, revision: state.outcomeRevision };
    if (state.historyRevision < state.outcomeRevision) {
      await this.hooks_.applyHistory(result);
      state.historyRevision = state.outcomeRevision;
      await this.saveState_(state);
      modeSaved = true;
    }
    if (!modeSaved && previousMode !== state.presentationMode) await this.saveState_(state);
    if (state.presentationMode !== 'history' && state.presentationRevision < state.outcomeRevision) {
      await this.mutate_((queue): void => { queue.resultIds.push(id); });
      this.hooks_.changed();
    }
    } finally { releaseEvidenceLease(this.filesDir_, manifest.activityId); }
  }

  /** UI只读已提交且历史已落盘的结果，离页保留义务，返回页后继续消费。 */
  async results(): Promise<SessionRecoveryResult[]> {
    await this.initialize(); await this.gate_;
    const results: SessionRecoveryResult[] = [];
    for (const id of this.queue_.resultIds.slice()) {
      const manifest = await ledgerManifestAsync(this.filesDir_, id);
      if (manifest === null) throw new Error('已提交待展示活动清单不可读，结果确认已延后');
      const state = await readRecoveryStateAsync(this.filesDir_, this.session_(manifest));
      if (state.presentationMode !== 'history' && state.outcome !== undefined && state.historyRevision === state.outcomeRevision
        && state.presentationRevision < state.outcomeRevision) results.push({ session: state.session,
          outcome: state.outcome, revision: state.outcomeRevision });
    }
    return results;
  }

  /** UI实际应用结果后确认指定版本；迟到crash推进的新版本不受旧回调确认影响。 */
  async acknowledgePresentation(activityId: number, revision: number): Promise<void> {
    const job = this.gate_.then(async (): Promise<void> => {
      const manifest = await ledgerManifestAsync(this.filesDir_, activityId); if (manifest === null) return;
      const state = await readRecoveryStateAsync(this.filesDir_, this.session_(manifest));
      if (revision > state.outcomeRevision) return;
      if (revision > state.presentationRevision) {
        state.presentationRevision = revision; await writeRecoveryStateAsync(this.filesDir_, state);
      }
      if (revision === state.outcomeRevision) {
        const next = copyQueue(this.queue_); next.resultIds = next.resultIds.filter((id): boolean => id !== activityId);
        await writeRecoveryQueueAsync(this.filesDir_, next); this.queue_ = next;
        this.syncQueuedLeases_();
      }
    });
    this.gate_ = job.catch((): void => {}); await job;
  }
}

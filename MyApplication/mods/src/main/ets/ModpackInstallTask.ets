/**
 * 整合包统一任务：名称在入队前的下载详情确定；准备清单后仅为可选内容暂停选择。
 * 无可选内容连续安装，暂停/取消/补齐共享持久计划，页面销毁不能改变名称或来源。
 * 请求只保存值与独立仓库回调，任务 ID 为安装实例身份，标题更改或重复安装不会冲突。
 */
import { AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
  DownloadTaskRegistry, newVersionInstallOwner, isTerminalState, TaskRetryStrategy,
  ProcessActivityCoordinator } from 'feature_core';
import { ModpackInstaller, ModpackInstallRequest, ModpackInstallResult, ModpackProgress,
  sanitizeVersionName, commitModpackRecoveryAbandonment, claimCommittedModpackRepair } from './ModpackInstaller';
import { ModpackInstallSession, ModpackRecoveryKind, assertModpackRecoveryAvailable,
  claimModpackRecoveryDismissal, readModpackRecoveryDismissal, clearModpackRepairDismissal,
  loadModpackSession } from './ModpackInstallSession';
import { readModpackRecoveryKind, cleanupModpackRecoveryWork } from './ModpackRecoveryTasks';
import { ModpackFile, ModpackEnv, modpackFileKey } from './ModpackManifest';
import { ModpackPackageCandidate } from './ModpackPackage';

/** UI 构造时提供展示字段；安装来源和恢复身份继承完整请求契约。 */
export interface ModpackInstallTaskInit extends ModpackInstallRequest {
  id?: string;
  title: string;
  subtitle?: string;
  requireConfirmation?: boolean;
}

export class ModpackInstallTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private installer_: ModpackInstaller = new ModpackInstaller();
  private req_: ModpackInstallRequest;
  private confirmation_: boolean;
  private result_: ModpackInstallResult | null = null;
  private active_: Promise<void> | undefined = undefined;
  private pauseRequested_: boolean = false;
  private recoveryDismissed_: boolean = false;
  /** 未确认的单选只存于任务内存；确认动作才刷盘，避免 ArkUI 切换控件执行同步 I/O。 */
  private pendingPackageId_: string | undefined = undefined;

  constructor(init: ModpackInstallTaskInit) {
    let sessionId = init.sessionId ?? newVersionInstallOwner();
    this.req_ = {
      sessionId: sessionId, archivePath: init.archivePath, archiveUrl: init.archiveUrl,
      officialFilesOnly: init.officialFilesOnly,
      displayName: init.title,
      archiveMirrors: init.archiveMirrors?.slice(), archiveFilename: init.archiveFilename,
      archiveSha1: init.archiveSha1, archiveSha512: init.archiveSha512, archiveSize: init.archiveSize,
      mcDir: init.mcDir, filesDir: init.filesDir, existingVersions: init.existingVersions.slice(),
      versionName: init.versionName, projectId: init.projectId, sourceVersionId: init.sourceVersionId,
      iconUrl: init.iconUrl, resolveCfFile: init.resolveCfFile, selectedOptional: init.selectedOptional?.slice(),
      onPhase: (progress: ModpackProgress): void => { this.onPhase_(progress); },
    };
    this.confirmation_ = init.requireConfirmation ?? true;
    this.view.id = init.id ?? ('modpack:' + sessionId);
    this.view.category = TaskCategory.MODPACK;
    // 整合包内部基础游戏及文件步骤继承本attempt，外层owner只开一本账。
    this.view.activityMcDir = init.mcDir;
    this.view.activityGameVersion = init.versionName ?? '';
    this.view.title = init.title;
    this.view.subtitle = init.subtitle ?? '整合包';
    this.view.iconUrl = init.iconUrl ?? '';
    this.view.state = UnifiedTaskState.WAITING;
    this.view.canCancel = true;
    this.view.canViewDetail = true;
    this.view.progressEstimated = true;
  }

  getResult(): ModpackInstallResult | null { return this.result_; }
  getSession(): ModpackInstallSession | undefined { return this.installer_.getSession(); }
  getInstallRoot(): string { return this.req_.mcDir; }
  /** Registry 开账晚于取消时仍按这个策略收尾，不能再次开放已经放弃的重试入口。 */
  get retryStrategy(): TaskRetryStrategy {
    return this.recoveryDismissed_ ? TaskRetryStrategy.NONE : TaskRetryStrategy.INTERNAL;
  }

  matchesRecovery(filesDir: string, id: string): boolean {
    return this.req_.filesDir === filesDir && this.req_.sessionId === id;
  }

  /** 取消和运行的完成时机有别；回收暂存前再次确认真实执行及 native owner 均已结束。 */
  async awaitRecoveryStop(): Promise<void> {
    try { await this.active_; } catch (_) { /* 任务终态已由 Registry 保存。 */ }
    await this.installer_.settleNativeOwners();
  }

  /** 只收起这份旧会话的恢复能力，已完成安装的真实 DONE 状态继续保留。 */
  markRecoveryDismissed(kind: ModpackRecoveryKind): void {
    this.recoveryDismissed_ = true;
    this.view.requiresConfirmation = false;
    this.view.canCancel = false;
    this.view.canPause = false;
    this.view.canResume = false;
    this.view.canRetry = false;
    this.view.retryStrategy = TaskRetryStrategy.NONE;
    this.view.currentLabel = kind === 'repair' ? '已停止补齐' : '已放弃安装';
    this.notify_();
  }
  /** 多内包、多实例或共享/隔离数据根由同一任务保存选择，不在页面临时猜选来源。 */
  packageCandidates(): ModpackPackageCandidate[] { return this.installer_.getSession()?.packageCandidates ?? []; }
  requiresPackageSelection(): boolean { return this.installer_.getSession()?.packageReady === false; }
  packageSelected(id: string): boolean { return (this.pendingPackageId_ ?? this.installer_.getSession()?.selectedPackageId) === id; }
  selectPackage(id: string): void {
    if (!this.view.requiresConfirmation) return;
    if (!this.packageCandidates().some((candidate: ModpackPackageCandidate): boolean => candidate.id === id))
      throw new Error('请选择原归档中的客户端或实例');
    this.pendingPackageId_ = id;
    this.notify_();
  }
  canChooseOtherPackage(): boolean {
    const session = this.installer_.getSession();
    return !this.recoveryDismissed_ && session !== undefined && session.versionName.length === 0 && (session.packageOrigins ?? []).length > 1
      && (this.view.requiresConfirmation || this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.PAUSED);
  }
  /** 错选或下钻后返回初始候选；该动作不执行解压、不写实例，也不绕过 Registry 的运行资格。 */
  chooseOtherPackage(): void {
    assertModpackRecoveryAvailable(this.req_.filesDir, this.req_.sessionId!);
    if (!this.canChooseOtherPackage()) throw new Error('当前安装不能更换来源');
    this.installer_.restartPackageSelection(this.req_);
    this.pendingPackageId_ = undefined;
    this.view.requiresConfirmation = true;
    this.view.state = UnifiedTaskState.PAUSED;
    this.view.errorMessage = '';
    this.view.canResume = false;
    this.view.canRetry = false;
    this.view.canCancel = true;
    this.notify_();
  }
  /** 任务详情只读展示名称：已预约目录优先，其次持久名称意图，最后兼容旧计划的包名。 */
  getInstallName(): string {
    const session = this.installer_.getSession();
    return session !== undefined && session.versionName.length > 0 ? session.versionName
      : (session?.requestedVersionName ?? this.req_.versionName ?? sanitizeVersionName(session?.plan.name ?? this.view.title));
  }

  /** 列表以稳定 key 保存用户选择；CF 元数据重试改变文件名时也不丢选择。 */
  optionalFiles(): ModpackFile[] {
    return this.installer_.getSession()?.plan.files.filter((file: ModpackFile): boolean => file.env === ModpackEnv.OPTIONAL) ?? [];
  }
  optionalSelected(file: ModpackFile): boolean {
    return (this.installer_.getSession()?.selectedOptional.indexOf(modpackFileKey(file)) ?? -1) >= 0;
  }
  setOptionalSelected(file: ModpackFile, selected: boolean): void {
    let session = this.installer_.getSession();
    if (session === undefined || !this.view.requiresConfirmation) return;
    let key = modpackFileKey(file);
    session.selectedOptional = session.selectedOptional.filter((value: string): boolean => value !== key);
    if (selected) session.selectedOptional.push(key);
    this.notify_();
  }

  /** 只确认计划，执行必须再经 Registry.resume 获取调度槽。 */
  confirmSelection(): void {
    assertModpackRecoveryAvailable(this.req_.filesDir, this.req_.sessionId!);
    let session = this.installer_.getSession();
    if (session === undefined || !this.view.requiresConfirmation) throw new Error('当前任务无需安装确认');
    if (session.packageReady === false) {
      const selected = this.pendingPackageId_ ?? session.selectedPackageId ?? '';
      if (selected.length === 0) throw new Error('请选择要安装的客户端或实例');
      this.installer_.selectPackage(this.req_, selected);
      // 下一轮取得 Registry 运行资格后再解释该候选，可能继续进入可选文件确认。
      this.view.requiresConfirmation = false;
      this.view.canResume = true;
      this.notify_();
      return;
    }
    // 可选项阶段只确认内容，继续沿用下载详情或恢复记录中的名称；不在任务中二次改名。
    this.installer_.confirm(this.req_, this.getInstallName(), session.selectedOptional);
    this.view.requiresConfirmation = false;
    this.view.canResume = true;
    this.notify_();
  }

  start(): Promise<void> {
    if (this.active_ !== undefined) return this.active_;
    // Registry 开账后才启动执行，不能依赖确认按钮置灰防止迟到的继续/重试。
    try { assertModpackRecoveryAvailable(this.req_.filesDir, this.req_.sessionId!); }
    catch (e) { return Promise.reject(e as Error); }
    this.pauseRequested_ = false;
    this.installer_.beginAttempt();
    let promise = this.run_();
    this.active_ = promise;
    return promise.finally((): void => { if (this.active_ === promise) this.active_ = undefined; });
  }

  private async run_(): Promise<void> {
    this.result_ = null;
    this.view.progress = 0;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.errorMessage = '';
    this.view.errorKind = '';
    this.view.canRetry = false;
    this.view.canResume = false;
    this.view.canCancel = true;
    this.view.canPause = true;
    this.installer_.activityId = this.view.startedAtMs;
    this.notify_();
    try {
      await this.installer_.settleNativeOwners();
      if (this.installer_.isCancelled()) throw new Error('整合包安装已取消');
      let session = await this.installer_.prepare(this.req_);
      if (session.packageReady === false) {
        this.view.requiresConfirmation = true;
        this.view.state = UnifiedTaskState.PAUSED;
        this.view.currentLabel = '归档包含多个客户端或实例，请选择后继续';
        this.view.canPause = false;
        this.view.canResume = false;
        this.notify_();
        return;
      }
      if (!session.confirmed) {
        if (this.confirmation_ && this.optionalFiles().length > 0) {
          // 释放运行槽，任务仍在面板中等待确认；页面退出不会丢失这份持久计划。
          this.view.requiresConfirmation = true;
          this.view.state = UnifiedTaskState.PAUSED;
          this.view.currentLabel = '请选择可选内容后继续安装';
          this.view.canPause = false;
          this.view.canResume = false;
          this.notify_();
          return;
        }
        this.installer_.confirm(this.req_, this.getInstallName(), this.req_.selectedOptional ?? []);
      }
      let result = await this.installer_.execute(this.req_);
      this.result_ = result;
      this.view.title = result.versionName;
      this.view.state = UnifiedTaskState.DONE;
      this.view.progress = 100;
      this.view.requiresConfirmation = false;
      this.view.canCancel = false;
      this.view.canPause = false;
      this.view.canRetry = result.missing.length > 0;
      this.view.currentLabel = result.missing.length > 0
        ? '已安装，' + result.missing.length + ' 项待补齐'
        : (result.warnings.length > 0 ? '安装完成，请查看提示' : '安装完成');
      this.view.subtitle = result.missing.length > 0 ? '整合包 · 可在原实例补齐' : '整合包';
      this.clearTransfer_();
      this.notify_();
    } catch (e) {
      // 无论是下载、解压还是基础安装出错，都先等待 owner；未释放不允许清理或覆盖。
      try { await this.installer_.settleNativeOwners(); } catch (settleError) { e = settleError; }
      this.view.canPause = false;
      this.view.canCancel = false;
      this.view.canResume = false;
      this.view.canRetry = true;
      if (this.installer_.isCancelled()) {
        this.view.state = this.pauseRequested_ ? UnifiedTaskState.PAUSED : UnifiedTaskState.ABORTED;
        this.view.currentLabel = this.pauseRequested_ ? '已暂停，安装材料已保留' : '已取消，安装材料已保留';
        this.view.canResume = !this.view.requiresConfirmation;
        this.view.canCancel = this.pauseRequested_;
      } else {
        this.view.state = UnifiedTaskState.ERROR;
        this.view.errorKind = 'ModpackInstall';
        this.view.errorMessage = (e as Error).message;
        // 候选解析失败时仍保留其他原始候选，允许用户改选而不必重下整个外壳。
        this.view.requiresConfirmation = this.installer_.getSession()?.packageReady === false;
        AppLogger.warn('ModpackInstallTask', '整合包安装失败，保留恢复计划', e as Error, LOG_DOMAIN_DOWNLOAD);
      }
      this.clearTransfer_();
      this.notify_();
      // 暂停是一次调度动作的正常收敛；不能 reject 后被 Registry 当作无终态异常强制改 ERROR。
      if (!this.pauseRequested_) throw e as Error;
    }
  }

  async cancel(cleanupFiles: boolean): Promise<void> {
    if (this.recoveryDismissed_) return;
    this.pauseRequested_ = false;
    this.installer_.requestCancel();
    this.view.currentLabel = '正在取消，等待当前步骤安全结束';
    this.view.canCancel = false;
    this.notify_();
    try { await this.active_; } catch (e) { /* 原运行的错误已经投影到视图 */ }
    await this.installer_.settleNativeOwners();
    // Registry 可能先发布排队取消，再于放弃完成后收到旧取消回调。旧回调不得重新打开恢复。
    if (this.recoveryDismissed_) return;
    // 取消抵达提交边界之后时，真实安装已经完成，保留 DONE 和提交结果。
    if (!cleanupFiles && this.view.state === UnifiedTaskState.DONE && this.result_ !== null) return;
    if (cleanupFiles) await this.installer_.discard(this.req_);
    if (cleanupFiles) this.view.requiresConfirmation = false;
    this.view.state = UnifiedTaskState.ABORTED;
    this.view.canPause = false;
    this.view.canResume = !cleanupFiles;
    this.view.canRetry = !cleanupFiles;
    this.view.currentLabel = cleanupFiles ? '已取消并清理本次安装材料' : '已取消，可继续原安装';
    this.notify_();
  }
  async pause(): Promise<void> {
    this.pauseRequested_ = true;
    this.installer_.requestCancel();
    this.view.currentLabel = '正在暂停，等待当前步骤安全结束';
    this.view.canPause = false;
    this.notify_();
    try { await this.active_; } catch (e) { /* 等待收敛 */ }
  }
  resume(): Promise<void> { return this.start(); }
  retry(): Promise<void> { return this.start(); }
  purgeNativeOwner(): boolean { return this.installer_.purgeNativeOwners(); }
  dispose(): void { /* 持久计划留给恢复入口；清理任务卡片不等于删除用户实例。 */ }

  private onPhase_(progress: ModpackProgress): void {
    this.view.currentLabel = this.installer_.isCancelled() ? '等待当前步骤安全结束后取消' : progress.message;
    this.view.bytesDone = progress.bytesDone; this.view.bytesTotal = progress.bytesTotal;
    this.view.speedBps = progress.speedBps; this.view.etaSeconds = progress.etaSeconds;
    this.view.filesDone = progress.current; this.view.filesTotal = progress.total;
    let inner = Math.max(0, Math.min(1, progress.innerProgress));
    if (progress.phase === 'pack') { this.view.state = UnifiedTaskState.DOWNLOADING; this.view.progress = Math.round(inner * 4); }
    else if (progress.phase === 'extracting' || progress.phase === 'overrides') {
      this.view.state = UnifiedTaskState.EXTRACTING; this.view.progress = progress.phase === 'extracting' ? 4 : 97;
    } else if (progress.phase === 'base') { this.view.state = UnifiedTaskState.DOWNLOADING; this.view.progress = 5 + Math.round(inner * 50); }
    else if (progress.phase === 'files') { this.view.state = UnifiedTaskState.DOWNLOADING; this.view.progress = 55 + Math.round(inner * 41); }
    else if (progress.phase === 'done') this.view.progress = 100;
    else { this.view.state = UnifiedTaskState.PREPARING; this.view.progress = 5; }
    this.notify_();
  }
  private clearTransfer_(): void { this.view.speedBps = 0; this.view.etaSeconds = -1; }
  private notify_(): void { DownloadTaskRegistry.instance().notifyChange(); }
}

/** 用户确认的持久停止操作。true 表示缓存清理完成，false 表示停止已生效但保留了残留。 */
export async function abandonModpackRecovery(filesDir: string, id: string, expected: ModpackRecoveryKind): Promise<boolean> {
  // 先在工作线程检查确认信息。取消锁在实际发起取消前才领取，预检失败不会打断正常安装。
  if (await readModpackRecoveryKind(filesDir, id) !== expected) throw new Error('安装状态已变化，请刷新后重新确认');
  const releaseProcess = ProcessActivityCoordinator.instance().acquireFileTask('整合包恢复清理');
  try {
    const releaseRecovery = claimModpackRecoveryDismissal(filesDir, id);
    try {
      const registry = DownloadTaskRegistry.instance();
      const taskId = 'modpack:' + id;
      const task = registry.getAdapter(taskId);
      if (task !== null && (!(task instanceof ModpackInstallTask) || !task.matchesRecovery(filesDir, id))) {
        throw new Error('当前任务与整合包恢复记录不一致');
      }
      if (readModpackRecoveryDismissal(filesDir, id) === undefined && task instanceof ModpackInstallTask) {
        if (!isTerminalState(task.view.state)) await registry.cancel(taskId, false);
        await task.awaitRecoveryStop();
      }
      // 取消可能和写入正式收据交错。必须按停止后的事实确认，而非按弹窗打开时的记录清理。
      commitModpackRecoveryAbandonment(filesDir, id, expected);
      if (task instanceof ModpackInstallTask) task.markRecoveryDismissed(expected);
      try { return await cleanupModpackRecoveryWork(filesDir, id); }
      catch (e) {
        AppLogger.warn('ModpackInstallTask', '已放弃整合包恢复，暂存清理未完成', e as Error, LOG_DOMAIN_DOWNLOAD);
        return false;
      }
    } finally { releaseRecovery(); }
  } finally { releaseProcess(); }
}

/** 仅供版本管理的显式「补齐缺失项」调用。普通继续、重试和扫描均无法撤销用户放弃。 */
export function reopenModpackRepair(filesDir: string, id: string, mcDir: string, versionName: string): void {
  const dismissed = readModpackRecoveryDismissal(filesDir, id);
  if (dismissed === undefined) return;
  if (dismissed !== 'repair') throw new Error('这项整合包安装已放弃，请从整合包详情重新开始');
  const releaseProcess = ProcessActivityCoordinator.instance().acquireFileTask('整合包补齐');
  try {
    const releaseRecovery = claimModpackRecoveryDismissal(filesDir, id);
    try {
      // 同名或复制到另一根的版本不能替原会话撤销用户选择。
      if (loadModpackSession(filesDir, id).mcDir !== mcDir) throw new Error('整合包实例与原安装根不一致');
      const releaseInstance = claimCommittedModpackRepair(mcDir, versionName, id);
      try {
        const registry = DownloadTaskRegistry.instance();
        const taskId = 'modpack:' + id;
        const task = registry.getAdapter(taskId);
        if (task !== null) {
          if (!(task instanceof ModpackInstallTask) || !task.matchesRecovery(filesDir, id) || !isTerminalState(task.view.state))
            throw new Error('旧整合包任务仍未结束，请稍后重试');
          registry.remove(taskId);
          if (registry.getAdapter(taskId) !== null) throw new Error('旧整合包任务仍在收尾，请稍后重试');
        }
        clearModpackRepairDismissal(filesDir, id);
      } finally { releaseInstance(); }
    } finally { releaseRecovery(); }
  } finally { releaseProcess(); }
}

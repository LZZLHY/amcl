/**
 * 整合包统一任务：名称在入队前的下载详情确定；准备清单后仅为可选内容暂停选择。
 * 无可选内容连续安装，暂停/取消/补齐共享持久计划，页面销毁不能改变名称或来源。
 * 请求只保存值与独立仓库回调，任务 ID 为安装实例身份，标题更改或重复安装不会冲突。
 */
import { AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
  DownloadTaskRegistry, newVersionInstallOwner } from 'feature_core';
import { ModpackInstaller, ModpackInstallRequest, ModpackInstallResult, ModpackProgress,
  sanitizeVersionName } from './ModpackInstaller';
import { ModpackInstallSession } from './ModpackInstallSession';
import { ModpackFile, ModpackEnv, modpackFileKey } from './ModpackManifest';

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

  constructor(init: ModpackInstallTaskInit) {
    let sessionId = init.sessionId ?? newVersionInstallOwner();
    this.req_ = {
      sessionId: sessionId, archivePath: init.archivePath, archiveUrl: init.archiveUrl,
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
    let session = this.installer_.getSession();
    if (session === undefined || !this.view.requiresConfirmation) throw new Error('当前任务无需安装确认');
    // 可选项阶段只确认内容，继续沿用下载详情或恢复记录中的名称；不在任务中二次改名。
    this.installer_.confirm(this.req_, this.getInstallName(), session.selectedOptional);
    this.view.requiresConfirmation = false;
    this.view.canResume = true;
    this.notify_();
  }

  start(): Promise<void> {
    if (this.active_ !== undefined) return this.active_;
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
        AppLogger.warn('ModpackInstallTask', '整合包安装失败，保留恢复计划', e as Error, LOG_DOMAIN_DOWNLOAD);
      }
      this.clearTransfer_();
      this.notify_();
      // 暂停是一次调度动作的正常收敛；不能 reject 后被 Registry 当作无终态异常强制改 ERROR。
      if (!this.pauseRequested_) throw e as Error;
    }
  }

  async cancel(cleanupFiles: boolean): Promise<void> {
    this.pauseRequested_ = false;
    this.installer_.requestCancel();
    this.view.currentLabel = '正在取消，等待当前步骤安全结束';
    this.view.canCancel = false;
    this.notify_();
    try { await this.active_; } catch (e) { /* 原运行的错误已经投影到视图 */ }
    await this.installer_.settleNativeOwners();
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

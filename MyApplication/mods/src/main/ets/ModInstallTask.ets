/**
 * 模组组合安装的调度 owner，以及各前置文件的独立任务卡片。
 * 整组只占一个注册表槽位、持有一个目录事务；每个文件使用自己的 native 下载进度。
 * 取消／重试成员会操作完整组合，提交前不把“已下载”的文件误标成“安装完成”。
 */
import { DownloadManager, DownloadTaskView, UnifiedTaskView, UnifiedTaskState, UnifiedDownloadAdapter,
  TaskCategory, getDownloadTaskRegistry } from 'feature_core';
import { ModInstallRequest, ModInstallObserver, ModInstallService, ModInstallFile, MOD_INSTALL_COMMIT_PHASE } from './ModInstallService';
import { RemoteVersion, resourceKindToInstallDir, ResourceKind } from './ModTypes';
import { ResourceFileProvider, ResourceFileEntry } from './ResourceInstallTask';

/** 将单文件原生进度投影到卡片。下载终态仍需等待整组文件就绪及事务提交。 */
function updateModFileProgress(view: UnifiedTaskView, native: DownloadTaskView): void {
  view.progress = native.progress * 95;
  view.bytesDone = native.bytesDone;
  view.bytesTotal = native.bytesTotal;
  view.filesDone = native.filesDone;
  view.filesTotal = native.filesTotal;
  view.speedBps = native.finished ? 0 : native.speedBps;
  view.etaSeconds = native.finished ? -1 : native.etaSeconds;
  view.state = native.finished ? UnifiedTaskState.VERIFYING : UnifiedTaskState.DOWNLOADING;
  view.currentLabel = native.finished ? '下载已结束，等待安装提交' : native.currentFile;
  view.errorKind = native.errorKind;
  view.errorMessage = native.errorMessage;
}

export class ModInstallTask implements UnifiedDownloadAdapter, ResourceFileProvider {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private request_: ModInstallRequest;
  private cancelled_: boolean = false;
  /** 所有文件的 native owner，包含失败后尚未收敛的任务；purge 成功前不丢弃身份。 */
  private nativeIds_: number[] = [];
  private currentDm_: DownloadTaskView | null = null;
  private files_: ResourceFileEntry[] = [];
  private dependencies_: ModInstallFileTask[] = [];

  /** 固定本次用户选择，避免页面切换版本或编辑可选依赖影响排队中的任务。 */
  constructor(request: ModInstallRequest) {
    this.request_ = { mcDir: request.mcDir, versionId: request.versionId, versionIsolation: request.versionIsolation,
      root: JSON.parse(JSON.stringify(request.root)) as RemoteVersion, title: request.title, router: request.router,
      optionalIds: request.optionalIds.slice(), oldPath: request.oldPath, wasEnabled: request.wasEnabled };
    const dir = resourceKindToInstallDir(ResourceKind.MOD, request.mcDir, request.versionId, request.versionIsolation);
    this.view.id = 'mod-plan:' + dir + ':' + request.root.source + ':' + request.root.projectId;
    this.view.title = request.title;
    this.view.subtitle = request.root.versionNumber;
    this.view.category = TaskCategory.MOD;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canCancel = true;
    this.view.canViewDetail = true;
    this.view.progressEstimated = true;
  }

  /** 每次尝试重新生成文件计划。原 native owner 必须先释放，旧依赖卡片才可替换。 */
  async start(): Promise<void> {
    if (!this.purgeNativeOwner()) throw new Error('旧下载任务仍在结束，请稍后重试');
    getDownloadTaskRegistry().clearAttachedTasks(this.view.id);
    this.dependencies_ = [];
    this.currentDm_ = null;
    this.files_ = [];
    this.cancelled_ = false;
    this.view.canCancel = true;
    this.view.canRetry = false;
    this.view.errorKind = '';
    this.view.errorMessage = '';
    this.view.progress = 0;
    this.view.bytesDone = 0;
    this.view.bytesTotal = 0;
    this.view.filesDone = 0;
    this.view.filesTotal = 0;
    this.view.speedBps = 0;
    this.view.etaSeconds = -1;
    this.view.state = UnifiedTaskState.PREPARING;
    const observer: ModInstallObserver = {
      phase: (label: string): void => {
        this.view.currentLabel = label;
        // 提交是不可中断的原子阶段；一旦进入就关闭取消，避免 UI 承诺无法兑现的中途撤回。
        if (label === MOD_INSTALL_COMMIT_PHASE) {
          this.view.canCancel = false;
          for (const dependency of this.dependencies_) dependency.view.canCancel = false;
        }
        if (label.indexOf('下载') < 0) {
          this.view.state = UnifiedTaskState.VERIFYING;
          for (const dependency of this.dependencies_) {
            dependency.view.currentLabel = label;
            dependency.view.state = UnifiedTaskState.VERIFYING;
          }
        }
        getDownloadTaskRegistry().notifyChange();
      },
      fileProgress: (index: number, native: DownloadTaskView): void => {
        if (native.taskId > 0 && this.nativeIds_.indexOf(native.taskId) < 0) this.nativeIds_.push(native.taskId);
        if (index === 0) {
          this.currentDm_ = native;
          updateModFileProgress(this.view, native);
        } else if (index - 1 < this.dependencies_.length) this.dependencies_[index - 1].update(native);
        if (this.cancelled_ && native.taskId > 0 && !native.finished) DownloadManager.instance().cancel(native.taskId);
        getDownloadTaskRegistry().notifyChange();
      },
      cancelled: (): boolean => this.cancelled_,
      files: (files: ModInstallFile[]): void => this.installFileViews(files),
    };
    try {
      await new ModInstallService().install(this.request_, observer, this.view.startedAtMs);
      this.finish(UnifiedTaskState.DONE, '');
    } catch (e) {
      this.finish(this.cancelled_ ? UnifiedTaskState.ABORTED : UnifiedTaskState.ERROR, (e as Error).message);
      throw e as Error;
    }
  }

  /** 根文件复用 owner 卡片，前置各自登记，所有字节只出现在所属文件卡片一次。 */
  private installFileViews(files: ModInstallFile[]): void {
    for (let index = 0; index < files.length; index++) {
      const file = files[index];
      if (index === 0) {
        this.files_ = [{ filename: file.file.filename, sizeBytes: file.file.size }];
        this.view.filesTotal = 1;
        this.view.bytesTotal = file.file.size;
        this.view.subtitle = this.request_.root.versionNumber + (files.length > 1 ? ' · 含 ' + (files.length - 1) + ' 个前置任务' : '');
      } else {
        const dependency = new ModInstallFileTask(this, file);
        this.dependencies_.push(dependency);
        getDownloadTaskRegistry().attachTask(this.view.id, dependency);
      }
    }
  }

  /** 组合提交后统一落终态；任何校验／下载失败均保留旧文件，所有成员都可通过 owner 重试。 */
  private finish(state: string, message: string): void {
    const views: UnifiedTaskView[] = [this.view];
    for (const dependency of this.dependencies_) views.push(dependency.view);
    for (const view of views) {
      view.state = state;
      view.canCancel = false;
      view.canRetry = state !== UnifiedTaskState.DONE;
      view.speedBps = 0;
      view.etaSeconds = -1;
      view.durationMs = Math.max(0, Date.now() - this.view.startedAtMs);
      if (state === UnifiedTaskState.DONE) {
        view.progress = 100;
        view.currentLabel = '已安装';
        view.errorMessage = '';
      } else {
        view.currentLabel = state === UnifiedTaskState.ABORTED ? '已取消安装组合' : '组合安装失败，原文件已保留';
        if (view.errorMessage.length === 0) view.errorMessage = message;
      }
    }
    getDownloadTaskRegistry().notifyChangeImmediate();
  }

  /** 取消任一成员时停止整个事务，防止其余文件提交成缺少必需前置的组合。 */
  async cancel(_cleanupFiles: boolean): Promise<void> {
    if (!this.view.canCancel && !this.cancelled_) return;
    this.cancelled_ = true;
    this.view.canCancel = false;
    for (const dependency of this.dependencies_) dependency.view.canCancel = false;
    for (const id of this.nativeIds_) DownloadManager.instance().cancel(id);
  }
  /** 事务安装不提供暂停，操作能力标志始终为 false。 */
  async pause(): Promise<void> {}
  async resume(): Promise<void> {}
  /** 注册表负责重试排队，进入新尝试时再核对安装现场及全部依赖。 */
  async retry(): Promise<void> { await this.start(); }
  /** 逐个确认 native 已停止写入，失败的 owner 留待下一次回收。 */
  purgeNativeOwner(): boolean {
    const retained: number[] = [];
    for (const id of this.nativeIds_) if (!DownloadManager.instance().purgeTask(id)) retained.push(id);
    this.nativeIds_ = retained;
    return retained.length === 0;
  }
  /** 卡片对象不拥有额外计时器，native 的释放由注册表先调用 purgeNativeOwner。 */
  dispose(): void {}
  getCurrentDmView(): DownloadTaskView | null { return this.currentDm_; }
  getFileEntries(): ResourceFileEntry[] { return this.files_.slice(); }
}

/**
 * 单个前置任务的显示／详情适配器。native 由父事务持有，不能单独启动或提交；
 * 注册表将取消／重试路由回 owner，成员自身保留委托以保证接口被直接调用时语义一致。
 */
class ModInstallFileTask implements UnifiedDownloadAdapter, ResourceFileProvider {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private owner_: ModInstallTask;
  private file_: ResourceFileEntry;
  private currentDm_: DownloadTaskView | null = null;

  constructor(owner: ModInstallTask, file: ModInstallFile) {
    this.owner_ = owner;
    this.file_ = { filename: file.file.filename, sizeBytes: file.file.size };
    this.view.id = owner.view.id + ':dependency:' + file.source + ':' + file.projectId + ':' + file.versionId;
    this.view.title = file.title;
    this.view.subtitle = '前置模组 · 与 ' + owner.view.title + ' 一同安装';
    this.view.category = TaskCategory.MOD;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.currentLabel = '等待下载（取消或重试将作用于整个安装组合）';
    this.view.bytesTotal = file.file.size;
    this.view.filesTotal = 1;
    this.view.startedAtMs = owner.view.startedAtMs;
    this.view.parentActivityId = owner.view.startedAtMs;
    this.view.activityRelation = 'dependency';
    this.view.canCancel = true;
    this.view.canViewDetail = true;
    this.view.progressEstimated = true;
  }
  /** 详情和卡片都消费该文件自己的 native 快照，不读取整组累计值。 */
  update(native: DownloadTaskView): void {
    this.currentDm_ = native;
    updateModFileProgress(this.view, native);
  }
  async start(): Promise<void> { throw new Error('前置任务必须由模组安装组合启动'); }
  async cancel(cleanupFiles: boolean): Promise<void> { await this.owner_.cancel(cleanupFiles); }
  async retry(): Promise<void> { await getDownloadTaskRegistry().retry(this.owner_.view.id); }
  async pause(): Promise<void> {}
  async resume(): Promise<void> {}
  dispose(): void {}
  getCurrentDmView(): DownloadTaskView | null { return this.currentDm_; }
  getFileEntries(): ResourceFileEntry[] { return [this.file_]; }
}

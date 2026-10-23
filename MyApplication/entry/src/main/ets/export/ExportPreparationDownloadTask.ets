/**
 * 导出准备的真实统一下载任务。Registry持有整个准备阶段（含元数据、下载、校验和processor），
 * Native传输仍由GameExportCoordinator唯一持有，页面销毁不影响执行。这里只投影真实事实，
 * DONE仅表示电脑依赖准备完成，绝不表示游戏包已保存；最终结果继续归原导出活动。
 */
import { DownloadTaskRegistry, DownloadTaskView, UnifiedDownloadAdapter, UnifiedTaskView,
  UnifiedTaskState, TaskCategory, TaskRetryStrategy } from 'feature_core';

export class ExportPreparationDownloadTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  readonly retryStrategy: TaskRetryStrategy = TaskRetryStrategy.EXTERNAL_EXPORT;
  private cancelled_: boolean = false;
  private bytes_: number = 0;
  private files_: number = 0;
  private run_: () => Promise<void>;
  private stop_: () => void;
  private settled_: () => boolean;

  /** 回调只捕获原导出owner；不保留目标URI，也不另建下载或安装配置。 */
  constructor(exportId: string, version: string, mcRoot: string, isolation: boolean,
    run: () => Promise<void>, stop: () => void, settled: () => boolean) {
    this.run_ = run; this.stop_ = stop; this.settled_ = settled;
    this.view.id = 'export-prepare:' + exportId;
    this.view.exportTaskId = exportId;
    this.view.exportMcRoot = mcRoot; this.view.exportVersionId = version; this.view.exportVersionIsolation = isolation;
    this.view.title = '导出电脑依赖 · ' + version;
    this.view.subtitle = '只准备电脑文件；归档保存结果请查看导出活动';
    this.view.category = TaskCategory.GAME_EXPORT;
    this.view.parentActivityId = Number(exportId.split('-')[0]);
    this.view.activityRelation = 'export-preparation';
    this.view.canCancel = true; this.view.canViewDetail = true;
    this.view.progressEstimated = true;
  }

  /** 只有run返回且Native已收敛才能成功；取消/失败向Registry及原导出流水线同时传播。 */
  async start(): Promise<void> {
    try {
      if (this.cancelled_) throw new Error('已取消导出准备');
      this.message('正在准备电脑文件');
      await this.run_();
      if (this.cancelled_) throw new Error('已取消导出准备');
      if (!this.settled_()) throw new Error('电脑依赖下载owner尚未释放');
      this.view.state = UnifiedTaskState.DONE; this.view.progress = 100;
      this.view.currentLabel = '电脑依赖已校验，游戏包仍由导出任务继续生成';
    } catch (error) {
      this.view.state = this.cancelled_ ? UnifiedTaskState.ABORTED : UnifiedTaskState.ERROR;
      this.view.errorMessage = (error as Error).message;
      this.view.currentLabel = this.cancelled_ ? '导出准备已取消' : '准备失败，请重新检查导出';
      throw error as Error;
    } finally {
      // 终态卡片可能长期留在列表；释放执行/取消闭包，避免持有大版本计划和库存。
      this.releaseCallbacks_();
      this.view.canCancel = false; this.view.canRetry = false;
      this.view.canRecoverExternally = this.view.state !== UnifiedTaskState.DONE;
      this.view.speedBps = 0; this.notify_();
    }
  }

  /** 不伪造可暂停/内置重试；恢复回原导出任务，重新验证源并由用户取得新另存授权。 */
  async retry(): Promise<void> { throw new Error('请重新检查导出并选择保存位置'); }
  async pause(): Promise<void> { /* 未声明暂停能力。 */ }
  async resume(): Promise<void> { /* 不重用旧导出授权。 */ }
  async cancel(_cleanupFiles: boolean): Promise<void> {
    this.cancelled_ = true; this.view.canCancel = false;
    this.view.currentLabel = '正在取消，等待下载或处理器安全结束';
    this.stop_(); this.notify_();
    this.releaseCallbacks_();
  }
  purgeNativeOwner(): boolean { return this.settled_(); }
  dispose(): void { this.releaseCallbacks_(); this.settled_ = (): boolean => true; }

  /** Native收敛前仅保留最小barrier查询；不保留可重新执行旧计划的闭包。 */
  private releaseCallbacks_(): void {
    this.run_ = async (): Promise<void> => {};
    this.stop_ = (): void => {};
  }

  /** 元数据/processor没有可证总量，仅显示阶段；不能按耗时补百分比。 */
  message(label: string): void {
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.currentLabel = this.cancelled_ ? '正在取消，等待下载或处理器安全结束' : label;
    this.view.speedBps = 0; this.notify_();
  }
  /** 当前文件的Native进度，累计字节仅来自真实下载；总闭包动态发现，因此不编造总字节。 */
  progress(view: DownloadTaskView, label: string): void {
    this.view.state = UnifiedTaskState.DOWNLOADING;
    // 迟到Native帧仍统计真实字节，但不得把取消收敛提示覆盖成普通下载文案。
    this.view.currentLabel = this.cancelled_ ? '正在取消，等待下载或处理器安全结束' : label;
    this.view.bytesDone = this.bytes_ + view.bytesDone; this.view.bytesTotal = 0;
    this.view.progress = Math.max(0, Math.min(100, view.progress * 100));
    this.view.speedBps = view.speedBps; this.view.filesDone = this.files_;
    this.notify_();
  }
  /** 下载后再校验成功才计入已完成；Native终态本身不提前标准备DONE。 */
  fileVerified(size: number): void {
    this.bytes_ += size; this.files_++;
    this.view.bytesDone = this.bytes_; this.view.filesDone = this.files_; this.notify_();
  }
  /** 一个独立阶段整批校验完后只累加一次，不把Native总字节按每个文件重复累计。 */
  batchVerified(files: number, bytes: number): void {
    this.bytes_ += bytes; this.files_ += files;
    this.view.bytesDone = this.bytes_; this.view.filesDone = this.files_; this.view.speedBps = 0;
    this.notify_();
  }
  private notify_(): void { DownloadTaskRegistry.instance().notifyChange(); }
}

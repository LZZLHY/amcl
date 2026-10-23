/** 安装包下载的统一任务适配器。队列、取消、进度和下载账本均独立于更新弹窗生命周期。 */
import { DownloadTaskRegistry, UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory, TaskRetryStrategy } from 'feature_core';
import { LedgerState, AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { SideloadUpdateActivity } from './SideloadUpdateActivity';

export class SideloadDownloadTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  /** 更新恢复必须经过Coordinator的整轮检查；此声明不随取消/队列终态改变。 */
  readonly retryStrategy: TaskRetryStrategy = TaskRetryStrategy.EXTERNAL_UPDATE;
  private activity: SideloadUpdateActivity;
  private run: (activityId: number) => Promise<void>;
  private stop: () => void;
  private changed: () => void;
  private cancelled: boolean = false;
  private started: boolean = false;

  /** run 仍调用产品下载服务；此处不复制镜像授权、摘要核验或 Native 下载实现。 */
  constructor(filesDir: string, key: string, title: string, parent: number,
    run: (activityId: number) => Promise<void>, stop: () => void, changed: () => void) {
    this.activity = new SideloadUpdateActivity(filesDir, '', 'app_update_download');
    this.run = run; this.stop = stop; this.changed = changed;
    this.view.id = 'app-update:' + key; this.view.title = title;
    this.view.category = TaskCategory.APP_UPDATE; this.view.subtitle = '安装包下载与 SHA-256 校验';
    this.view.parentActivityId = parent; this.view.activityRelation = 'download';
    this.view.canCancel = true; this.view.canViewDetail = true;
  }

  /** 排队完成才绑定执行身份；结束 Promise 之前已经保存终态，列表和弹窗读取同一个 view。 */
  async start(): Promise<void> {
    this.started = true; this.cancelled = false;
    this.view.startedAtMs = this.activity.begin(this.view.title, this.view.parentActivityId, this.view.startedAtMs);
    this.view.canCancel = true; this.view.canRetry = false;
    try {
      await this.run(this.view.startedAtMs);
      if (this.cancelled) throw new Error('更新包下载已取消');
      this.view.state = UnifiedTaskState.DONE; this.view.progress = 100;
      this.view.currentLabel = '安装包已校验；安装结果请查看应用更新活动';
      // 已校验原件的业务SUCCESS不因日志IO失败变为下载失败；原终态留存并等待真实异步关闭。
      try { await this.activity.finishAsync(LedgerState.SUCCESS, this.view.currentLabel); }
      catch (error) { AppLogger.warn('SideloadUpdate', '已校验下载终态待保存，保留原件与SUCCESS', error, LOG_DOMAIN_DOWNLOAD); }
    } catch (error) {
      this.view.state = this.cancelled ? UnifiedTaskState.ABORTED : UnifiedTaskState.ERROR;
      this.view.errorMessage = (error as Error).message;
      try { await this.activity.finishAsync(this.cancelled ? LedgerState.ABORTED : LedgerState.FAILED, this.view.errorMessage); }
      catch (closeError) { AppLogger.warn('SideloadUpdate', '下载异常终态待保存，保留最初失败事实', closeError, LOG_DOMAIN_DOWNLOAD); }
      throw error as Error;
    } finally {
      this.view.canCancel = false; this.view.speedBps = 0;
      this.view.canRecoverExternally = this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED;
      this.view.durationMs = Math.max(0, Date.now() - this.view.startedAtMs);
      this.notify();
    }
  }

  /** 排队时取消也有独立账本；运行时交给服务中断底层下载，待实际 I/O 收敛后封账。 */
  async cancel(_cleanupFiles: boolean): Promise<void> {
    this.cancelled = true; this.stop();
    if (!this.started) {
      this.view.startedAtMs = this.activity.begin(this.view.title, this.view.parentActivityId);
      this.view.state = UnifiedTaskState.ABORTED; this.view.canCancel = false;
      try { await this.activity.finishAsync(LedgerState.ABORTED, '等待下载队列时取消'); }
      catch (error) { AppLogger.warn('SideloadUpdate', '排队取消终态待保存，执行资格保持关闭', error, LOG_DOMAIN_DOWNLOAD); }
      this.notify();
    }
  }

  /** 下载重试需重新核实更新目标与授权，统一卡片明确指向更新入口，不能单独触发安装。 */
  async retry(): Promise<void> { throw new Error('请在检查更新中重试完整更新流程'); }
  async pause(): Promise<void> { /* 短时镜像授权不支持暂停后沿用；保留断点由整轮重试取得新令牌。 */ }
  async resume(): Promise<void> { /* 未开放暂停能力，Registry 不会调用恢复。 */ }
  dispose(): void { /* 终态清理仅移除卡片，持久活动记录和可复用数据由更新服务管理。 */ }

  /** 镜像切换允许实际字节回退；100% 只表示本文件字节，不冒充签名/安装进度。 */
  progress(bytes: number, total: number, speed: number, label: string, verifying: boolean = false): void {
    if (this.cancelled) return;
    this.view.state = verifying ? UnifiedTaskState.VERIFYING : UnifiedTaskState.DOWNLOADING;
    this.view.bytesDone = bytes; this.view.bytesTotal = total; this.view.speedBps = verifying ? 0 : speed;
    this.view.progress = total > 0 ? Math.max(0, Math.min(100, bytes * 100 / total)) : 0;
    this.view.currentLabel = label; this.activity.event(verifying ? '校验' : '来源', label); this.notify();
  }
  private notify(): void { DownloadTaskRegistry.instance().notifyChange(); this.changed(); }
}

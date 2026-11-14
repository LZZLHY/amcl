/**
 * 模组、光影和资源包单文件另存。UI 只在当前详情点击确认后调用系统 Picker；系统返回的文件 URI
 * 仅由本次队列任务使用。下载引擎只接触独占沙箱暂存路径，保存完成才封为成功。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { ActivityCategory, DownloadFileSpec, DownloadManager, DownloadTaskRegistry, DownloadTaskView,
  TaskCategory, TaskRetryStrategy, UnifiedDownloadAdapter, UnifiedTaskState, UnifiedTaskView, categoryLabel } from 'feature_core';
import { buildDownloadSpec, RemoteFile, RemoteProject, RemoteVersion, ResourceFileEntry, ResourceFileProvider,
  ResourceKind } from 'mods';
import { copyExportArchiveToUri } from '../export/ExportArchiveIO';

const TAG = 'ModFileSave';
// 只在启动器进程存活。避免重复拉起系统窗口，同一文件或目标在上一任务收口前不可再次提交。
let pickerPending: boolean = false;
const activeFiles: Set<string> = new Set<string>();
const activeDestinations: Set<string> = new Set<string>();

/** 只有可作为普通单文件交付的三个资源分类开放另存，其他资源保留原有安装流程。 */
function customSaveCategory(kind: ResourceKind): TaskCategory | undefined {
  switch (kind) {
    case ResourceKind.MOD: return TaskCategory.MOD;
    case ResourceKind.SHADER: return TaskCategory.SHADER;
    case ResourceKind.RESOURCE_PACK: return TaskCategory.RESOURCE_PACK;
    default: return undefined;
  }
}

/** 页面与任务共用类别判据，确保显示另存入口的类别可以通过队列准入。 */
export function supportsCustomResourceSave(kind: ResourceKind): boolean {
  return customSaveCategory(kind) !== undefined;
}

/**
 * 在等待系统窗口前固定文件身份、来源和校验规格。调用方以详情代次判定 isCurrent；
 * 系统窗口返回空结果、详情已退休时返回空串。成功入队后立即返回可打开的任务 ID。
 * 入口沿用首版模组另存的命名，光影和资源包共用相同授权和写入契约。
 */
export async function pickAndStartModFileSave(context: common.UIAbilityContext, project: RemoteProject,
  version: RemoteVersion, file: RemoteFile, isCurrent: () => boolean): Promise<string> {
  if (!isCurrent()) return '';
  if (pickerPending) throw new Error('系统保存窗口已经打开');
  const category = customSaveCategory(project.kind);
  if (category === undefined || version.isServerPack === true || context.cacheDir.length === 0) {
    throw new Error('该资源文件暂不可另存');
  }
  // 复用现有下载规格的安全文件名、镜像、大小和 SHA-1 判据；此函数不产生 IO。
  const cacheDir = context.cacheDir;
  const spec = buildDownloadSpec(file, cacheDir);
  const filename = file.filename;
  const title = project.title;
  const iconUrl = project.iconUrl;
  const fileKey = JSON.stringify([version.source, version.projectId, version.id, filename]);
  if (activeFiles.has(fileKey)) throw new Error('此' + categoryLabel(category) + '文件正在保存');

  pickerPending = true;
  try {
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [filename];
    // DEFAULT 模式让用户确认位置。兼容 API 20 的预建空文件按已有 URI 交付约束处理。
    const destinations = await new picker.DocumentViewPicker(context).save(options);
    if (destinations.length === 0 || destinations[0].length === 0 || !isCurrent()) return '';
    const uri = destinations[0];
    if (activeDestinations.has(uri)) throw new Error('该保存位置已有正在进行的任务');

    const registry = DownloadTaskRegistry.instance();
    const task = new ResourceFileSaveTask(category, title, iconUrl, filename, cacheDir, uri, spec);
    activeFiles.add(fileKey);
    activeDestinations.add(uri);
    const settled = (): void => {
      task.dispose();
      activeDestinations.delete(uri);
      activeFiles.delete(fileKey);
    };
    const completion = registry.enqueue(task);
    completion.then(settled, (): void => {
      AppLogger.warn(TAG, `保存任务已结束 id=${task.view.id} activity=${task.view.startedAtMs} state=${task.view.state}`,
        null, LOG_DOMAIN_DOWNLOAD);
      settled();
    });
    // 唯一 ID 入队是同步登记。若 Registry 拒绝准入，等待原 Promise 传播原因。
    if (registry.getAdapter(task.view.id) !== task) await completion;
    AppLogger.info(TAG, `系统保存已确认 id=${task.view.id} file=${fileKey}`, LOG_DOMAIN_DOWNLOAD);
    return task.view.id;
  } finally {
    pickerPending = false;
  }
}

/** 单次保存适配器。重试需回到资源详情重新取得系统授权，无法从任务历史恢复 URI。 */
class ResourceFileSaveTask implements UnifiedDownloadAdapter, ResourceFileProvider {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  readonly retryStrategy: TaskRetryStrategy = TaskRetryStrategy.NONE;
  private filename_: string;
  private cacheDir_: string;
  private uri_: string;
  private spec_: DownloadFileSpec;
  private nativeId_: number = 0;
  private downloadView_: DownloadTaskView | null = null;
  private cancelled_: boolean = false;
  private saving_: boolean = false;

  constructor(category: TaskCategory, title: string, iconUrl: string, filename: string, cacheDir: string, uri: string,
    spec: DownloadFileSpec) {
    this.filename_ = filename;
    this.cacheDir_ = cacheDir;
    this.uri_ = uri;
    this.spec_ = spec;
    // 任务身份、日志和暂存模板沿用首版的另存约定；展示与账本使用真实资源类别和另存活动。
    this.view.id = 'mod-file-save:' + util.generateRandomUUID();
    this.view.category = category;
    this.view.activityCategory = ActivityCategory.RESOURCE_MANAGE;
    this.view.title = '保存' + categoryLabel(category) + ' · ' + title;
    this.view.iconUrl = iconUrl;
    this.view.subtitle = filename;
    this.view.filesTotal = 1;
    this.view.bytesTotal = spec.check?.size ?? 0;
    this.view.canCancel = true;
    this.view.canViewDetail = true;
  }

  /** 预检目的地后才下载。所有错误、取消及成功都经同一 Native owner 和暂存清理屏障。 */
  async start(): Promise<void> {
    const uri = this.uri_;
    this.uri_ = '';
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.currentLabel = '正在检查保存位置';
    let failure = '无法写入系统保存位置，请回到详情重新选择';
    let stage = '';
    try {
      try {
        this.assertActive_();
        if (uri.length === 0) throw new Error('保存授权已失效');
        // 既有非空文件先于网络被拒绝；写入时复用 URI 助手的同一项检查，防止期间目标变化。
        const target = await fs.open(uri, fs.OpenMode.READ_WRITE);
        try {
          const info = await fs.stat(target.fd);
          if (!info.isFile() || info.size !== 0) {
            failure = '目标不是空文件，请回到详情另选新文件';
            throw new Error(failure);
          }
        } finally {
          await fs.close(target);
        }
        this.assertActive_();
        failure = '无法准备应用缓存，请检查可用空间后重试';
        // FileIO 用末尾六个 X 生成唯一目录名；只在成功创建后记录可回收路径。
        stage = await fs.mkdtemp(this.cacheDir_ + '/amcl-mod-save-XXXXXX');
        this.assertActive_();
        this.spec_.allowedRoot = stage;
        this.spec_.localPath = stage + '/' + this.filename_;
        this.view.state = UnifiedTaskState.DOWNLOADING;
        this.view.currentLabel = '正在下载文件';
        failure = categoryLabel(this.view.category) + '下载失败，请检查网络或下载来源后重试';
        await this.download_();
        this.assertActive_();
        const payload = await fs.lstat(this.spec_.localPath);
        if (!payload.isFile() || payload.size <= 0) throw new Error('下载文件为空或不完整');

        // 系统提供方不保证中断写入后原子回滚。写入阶段暂时隐藏取消，避免主动留下半成品。
        this.saving_ = true;
        this.view.canCancel = false;
        this.view.state = UnifiedTaskState.VERIFYING;
        this.view.progress = 99;
        this.view.speedBps = 0;
        this.view.etaSeconds = -1;
        this.view.currentLabel = '正在写入系统保存位置';
        this.view.bytesDone = payload.size;
        this.view.bytesTotal = payload.size;
        DownloadTaskRegistry.instance().notifyChange();
        failure = '写入或核对目标文件失败，请检查系统文件管理器后重新另存';
        const receipt = await copyExportArchiveToUri(this.spec_.localPath, uri, (): boolean => false,
          (_bytes: number): void => {});
        this.view.currentLabel = receipt.readbackVerified ? '文件已保存并核对' : '文件已保存';
        AppLogger.info(TAG, `保存完成 id=${this.view.id} activity=${this.view.startedAtMs} bytes=${receipt.size} `
          + `readback=${receipt.readbackVerified} sha256=${receipt.sha256}`, LOG_DOMAIN_DOWNLOAD);
      } finally {
        // 不接触用户 URI 的清理操作。沙箱目录为本轮 mkdtemp 创建，Native 已退出后才递归移除。
        if (stage.length > 0) {
          try { await fs.rmdir(stage); }
          catch (error) {
            AppLogger.warn(TAG, `暂存回收失败 id=${this.view.id} code=${(error as BusinessError).code ?? 0}`,
              null, LOG_DOMAIN_DOWNLOAD);
          }
        }
      }
      this.view.state = UnifiedTaskState.DONE;
      this.view.progress = 100;
      this.view.filesDone = 1;
    } catch (error) {
      this.view.state = this.cancelled_ ? UnifiedTaskState.ABORTED : UnifiedTaskState.ERROR;
      this.view.errorMessage = this.cancelled_ ? '已取消保存' : failure;
      this.view.currentLabel = this.view.errorMessage;
      // 系统异常原文可能包含目标 URI 或下载授权地址，只记录错误编号及业务阶段。
      AppLogger.warn(TAG, `保存未完成 id=${this.view.id} activity=${this.view.startedAtMs} `
        + `code=${(error as BusinessError).code ?? 0} state=${this.view.state}`, null, LOG_DOMAIN_DOWNLOAD);
      throw new Error(this.view.errorMessage);
    } finally {
      this.saving_ = false;
      this.view.canCancel = false;
    }
  }

  /** Native 的逻辑完成回调早于所有工作者释放；等待所有权退出后才打开暂存文件。 */
  private async download_(): Promise<void> {
    const manager = DownloadManager.instance();
    try {
      const result = await manager.createAndWait({ name: this.view.id, files: [this.spec_],
        activityId: this.view.startedAtMs }, (view: DownloadTaskView): void => {
        this.nativeId_ = view.taskId;
        this.downloadView_ = view;
        this.view.bytesDone = view.bytesDone;
        this.view.bytesTotal = view.bytesTotal;
        this.view.speedBps = view.speedBps;
        this.view.etaSeconds = view.etaSeconds;
        this.view.progress = view.bytesTotal > 0 ? Math.min(98, 100 * view.bytesDone / view.bytesTotal) : 0;
        DownloadTaskRegistry.instance().notifyChange();
      });
      this.nativeId_ = result.taskId;
    } finally {
      if (this.nativeId_ > 0) await manager.awaitTaskReleased(this.nativeId_, true);
      this.nativeId_ = 0;
      this.downloadView_ = null;
    }
  }

  /** 排队取消也撤销临时授权；运行中 Native 取消由同一个 start Promise 收尾。 */
  async cancel(_cleanupFiles: boolean): Promise<void> {
    if (this.saving_) return;
    this.cancelled_ = true;
    this.uri_ = '';
    this.view.canCancel = false;
    if (this.nativeId_ > 0) DownloadManager.instance().cancel(this.nativeId_);
  }

  /** 当前公开下载流程没有可独立暂停或复用的保存授权。 */
  pause(): Promise<void> { return Promise.resolve(); }
  resume(): Promise<void> { return Promise.resolve(); }
  retry(): Promise<void> {
    return Promise.reject(new Error('请回到' + categoryLabel(this.view.category) + '详情重新选择保存位置'));
  }

  /** 移除任务或准入失败时释放尚未开始使用的 URI；正在运行的调用栈负责自己的所有权。 */
  dispose(): void { this.uri_ = ''; }

  /** 复用任务详情的单文件显示。正文下完后要等系统文件写入成功才计为完成。 */
  getCurrentDmView(): DownloadTaskView | null { return this.downloadView_; }
  getFileEntries(): ResourceFileEntry[] { return [{ filename: this.filename_, sizeBytes: this.view.bytesTotal }]; }

  private assertActive_(): void {
    if (this.cancelled_) throw new Error('已取消保存');
  }
}

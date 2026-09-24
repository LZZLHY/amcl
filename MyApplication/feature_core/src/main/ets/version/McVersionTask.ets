/**
 * McVersionTask.ets — 把 DownloadTask（MC 整版下载）包装为 UnifiedDownloadAdapter
 *
 * 设计要点：
 *   - 持有底层 `DownloadTask` + 它的 `DownloadStateModel`（@Observed）
 *   - 在 `task.onStateChange` 里同步刷 `view` + `dlState`（dlState 给详情子视图复用）
 *   - 终态映射（DONE/ERROR/ABORTED/PAUSED）转 UnifiedTaskState
 *
 * 详情视图（Screen 10b）直接复用现有 `components/DownloadSheet.ets`，
 * 通过 `getDlState()` 拿到原始 `DownloadStateModel`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
} from '../download/UnifiedDownloadTask';
import {
  DownloadTask, DownloadPhase, DownloadStateModel, PhaseDetailModel, FailedFileBrief,
} from '../download/DownloadTask';
import { ModLoaderType } from '../modloader/ModLoaderTypes';
import { DownloadTaskRegistry } from '../download/DownloadTaskRegistry';

const TAG = 'McVersionTask';

/** 阶段标签 -> 中文映射 */
function phaseLabel(p: string): string {
  switch (p) {
    case DownloadPhase.PREPARE:   return '准备版本信息';
    case DownloadPhase.CLIENT:    return '主程序 jar';
    case DownloadPhase.LIBRARIES: return '依赖库';
    case DownloadPhase.ASSETS:    return '游戏资源';
    case DownloadPhase.MODLOADER: return '安装 ModLoader';
    case DownloadPhase.MERGE:     return '合并版本';
    default:                       return p;
  }
}

/** loader 子标题文本 */
function loaderSubtitle(loaderType: ModLoaderType | null, loaderVersion: string): string {
  if (!loaderType) return '原版';
  let name = loaderType === ModLoaderType.FABRIC ? 'Fabric' : 'Forge';
  if (loaderVersion.length > 0) return name + ' ' + loaderVersion;
  return name;
}

/** DownloadPhase -> UnifiedTaskState */
function mapPhase(p: string): string {
  switch (p) {
    case DownloadPhase.PREPARE:   return UnifiedTaskState.PREPARING;
    case DownloadPhase.CLIENT:
    case DownloadPhase.LIBRARIES:
    case DownloadPhase.ASSETS:
    case DownloadPhase.MODLOADER:
    case DownloadPhase.MERGE:     return UnifiedTaskState.DOWNLOADING;
    case DownloadPhase.DONE:      return UnifiedTaskState.DONE;
    case DownloadPhase.ERROR:     return UnifiedTaskState.ERROR;
    case DownloadPhase.ABORTED:   return UnifiedTaskState.ABORTED;
    case DownloadPhase.PAUSED:    return UnifiedTaskState.PAUSED;
    default:                       return UnifiedTaskState.DOWNLOADING;
  }
}

export class McVersionTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  /** 底层 task，详情子视图通过 getter 暴露 */
  private task_: DownloadTask;
  /**
   * @Observed DownloadStateModel —— 公开字段，供 DownloadTasksSheet 里的
   * DownloadSheet `@ObjectLink dlState` 直接绑定（ArkTS 要求 ObjectLink 绑定必须
   * 是字段访问，不能是方法调用返回值）。
   */
  readonly dlState: DownloadStateModel = new DownloadStateModel();
  /** 跨阶段最大字节数（写历史时取这个，而非当前 phase 的字节）。 */
  private maxBytesEver_: number = 0;
  /** 出队时确定的活动身份；与 view、底层 logger、账本和重试父身份共用，排队前为 0。 */
  get startedAtMs(): number { return this.view.startedAtMs; }
  /** 可选：每次状态变化后回调（供整合包安装转发基础版本下载的细粒度进度）。 */
  onProgress: ((v: UnifiedTaskView) => void) | null = null;

  constructor(
    gameVersion: string,
    loaderType: ModLoaderType | null,
    loaderVersion: string,
    versionName: string,
    mcDir: string,
    filesDir: string,
  ) {
    this.view.id = 'mc:' + versionName;
    this.view.category = TaskCategory.MC_VERSION;
    this.view.title = versionName;
    this.view.subtitle = loaderSubtitle(loaderType, loaderVersion);
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canViewDetail = true;
    this.view.canCancel = true;
    this.view.canPause = true;

    this.task_ = new DownloadTask(gameVersion, loaderType, loaderVersion, versionName, mcDir, filesDir);
    // 身份在实际开始/重试前绑定，不能使用构造时间把排队和多次重试写入同一本账本。
    this.dlState.versionName = versionName;
    this.dlState.phase = DownloadPhase.PREPARE;
    this.dlState.phaseDetails = this.task_.phaseDetails;

    this.task_.onStateChange = (t: DownloadTask) => this.handleStateChange_(t);
  }

  /** 暴露底层 task —— 仅 sheet "重试失败文件" / "查看错误" 等高级操作用 */
  getTask(): DownloadTask {
    return this.task_;
  }

  /** 跨阶段最大字节（写历史用，调用方：Index.recordHistoryFromAdapter_） */
  getMaxBytesEver(): number {
    return this.maxBytesEver_;
  }

  start(): Promise<void> {
    // 兼容直接调用适配器的宿主；生产队列已在通知开账之前设置 startedAtMs。
    if (this.view.startedAtMs <= 0) this.view.startedAtMs = Date.now();
    this.task_.setActivityId(this.startedAtMs);
    return this.task_.start().catch((e: Error) => {
      // DownloadTask 在 catch 内部已经把 phase 设为 ERROR + 填了 errorMessage，
      // 这里只是把异常透传给 registry（让 enqueue 的 Promise reject）
      throw e;
    });
  }

  cancel(cleanupFiles: boolean): Promise<void> {
    return this.task_.cancelAndAwait(cleanupFiles);
  }

  pause(): Promise<void> {
    return this.task_.pause();
  }

  resume(): Promise<void> {
    return this.task_.resume();
  }

  retry(): Promise<void> {
    this.task_.setActivityId(this.startedAtMs);
    return this.task_.retry();
  }

  purgeNativeOwner(): boolean {
    return this.task_.purgeNativeOwners();
  }

  dispose(): void {
    // task 自身没有 dispose；GC 处理。这里把回调断开避免循环引用
    this.task_.onStateChange = null;
  }

  // ============================================================
  //  内部：DownloadTask 状态 -> UnifiedTaskView + DownloadStateModel
  // ============================================================

  private handleStateChange_(t: DownloadTask): void {
    // 跨阶段最大字节追踪（写历史用）
    if (t.bytesTotal > this.maxBytesEver_) this.maxBytesEver_ = t.bytesTotal;

    // ---- 同步 dlState（DownloadSheet 用） ----
    this.dlState.phase = t.phase;
    this.dlState.progress = t.progress;
    this.dlState.speed = t.speed;
    this.dlState.phaseDetails = t.phaseDetails;
    this.dlState.etaSeconds = t.etaSeconds;
    this.dlState.durationMs = t.durationMs;
    this.dlState.bytesDone = t.bytesDone;
    this.dlState.bytesTotal = t.bytesTotal;
    this.dlState.errorKind = '';
    this.dlState.errorMessage = t.errorMessage || '';
    let failed: FailedFileBrief[] = [];
    for (let f of t.failedFileDetails) failed.push(f);
    this.dlState.failedFiles = failed;

    // ---- 同步 view（TaskCard 用） ----
    this.view.state = mapPhase(t.phase);
    this.view.progress = t.progress;
    this.view.bytesDone = t.bytesDone;
    this.view.bytesTotal = t.bytesTotal;
    this.view.etaSeconds = t.etaSeconds;
    this.view.durationMs = t.durationMs;
    this.view.speedBps = parseSpeedBps_(t.speed);
    this.view.errorKind = '';
    this.view.errorMessage = t.errorMessage || '';

    // currentLabel：找当前 running 的阶段
    let active = this.findActivePhase_(t.phaseDetails);
    if (active) {
      this.view.currentLabel = phaseLabel(active.phase);
      if (active.total > 0) {
        this.view.currentLabel += ' (' + active.current + ' / ' + active.total + ')';
      }
      this.view.filesDone = active.current;
      this.view.filesTotal = active.total;
    } else {
      this.view.currentLabel = phaseLabel(t.phase);
    }

    // 操作可用性
    let phase = t.phase;
    let active2 = phase !== DownloadPhase.DONE && phase !== DownloadPhase.ERROR
              && phase !== DownloadPhase.ABORTED && phase !== DownloadPhase.PAUSED;
    this.view.canPause = active2;
    this.view.canResume = phase === DownloadPhase.PAUSED || phase === DownloadPhase.ABORTED;
    this.view.canCancel = active2 || phase === DownloadPhase.PAUSED;
    this.view.canRetry = phase === DownloadPhase.ERROR || phase === DownloadPhase.ABORTED
                     || phase === DownloadPhase.PAUSED;
    this.view.canViewDetail = true;

    // 通知 registry（让 stats bar / FAB 跟着刷新）
    try {
      DownloadTaskRegistry.instance().notifyChange();
    } catch (e) {
      let err = e as Error;
      hilog.warn(0x0000, TAG, 'notifyChange threw: %{public}s', err.message);
    }

    // 转发细粒度进度（整合包安装的 base 阶段订阅此回调）
    if (this.onProgress !== null) {
      try { this.onProgress(this.view); } catch (e) { /* ignore */ }
    }
  }

  private findActivePhase_(details: PhaseDetailModel[]): PhaseDetailModel | null {
    for (let d of details) {
      if (d.status === 'running') return d;
    }
    return null;
  }
}

/**
 * 把 "5.1 MB/s" 这样的字符串反解成字节/秒。
 * 简化实现：单位字母匹配 + 浮点解析；失败则返回 0。
 * 仅给 UI 显示用，不要求精确。
 */
function parseSpeedBps_(speed: string): number {
  if (!speed || speed.length === 0) return 0;
  // 形如 "5.1 MB/s" / "356 KB/s" / "1.2 GB/s"
  let m = speed.match(/^([\d.]+)\s*([KMGTP]?)B\/s$/i);
  if (!m) return 0;
  let n = parseFloat(m[1]);
  if (isNaN(n)) return 0;
  let unit = m[2].toUpperCase();
  switch (unit) {
    case 'K': return n * 1024;
    case 'M': return n * 1024 * 1024;
    case 'G': return n * 1024 * 1024 * 1024;
    case 'T': return n * 1024 * 1024 * 1024 * 1024;
    case 'P': return n * 1024 * 1024 * 1024 * 1024 * 1024;
    default:  return n;
  }
}

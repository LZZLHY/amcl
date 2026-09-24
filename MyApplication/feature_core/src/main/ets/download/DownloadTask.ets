/**
 * DownloadTask.ets — 一体化下载任务编排
 *
 * 编排 MC 版本下载的完整流程：
 *   获取版本信息 → 下载 client.jar → 下载 libraries → 下载 assets
 *   → [可选] 安装模组加载器 → 合并 JSON → 完成
 *
 * 参考 PCL2 McInstallLoader 的合并安装机制。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { McDownloader } from '../download/McDownloader';
import { ModLoaderType } from '../modloader/ModLoaderTypes';
import { removeDirRecursive, isVersionInstalled, writeVersionInstallCommit,
  removeVersionInstallCommit } from 'commons';
import { ModLoaderManager } from '../modloader/ModLoaderManager';
import { DownloadManager, DownloadFailedFile } from './DownloadManager';
import { ensureRanking } from './SourceProber';
import { formatSpeed } from 'commons';
// Phase 6.3 (S3-2): PhaseRunner 抽象 + 6 个 phase 类
import {
  PhaseRunner, IDownloadPhase, PhaseContext, PhaseProgress,
} from './PhaseRunner';
import { DownloadFlowState } from './phases/DownloadFlowState';
import { CancelledError } from 'commons';
import { ActivityLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { PreparePhase } from './phases/PreparePhase';
import { ClientPhase } from './phases/ClientPhase';
import { LibrariesPhase } from './phases/LibrariesPhase';
import { AssetsPhase } from './phases/AssetsPhase';
import { ModloaderPhase } from './phases/ModloaderPhase';
import { MergePhase } from './phases/MergePhase';
import { safeBaseName } from '../modloader/MavenUtils';

const TAG = LogTags.SVC_DOWNLOAD_TASK;

/**
 * v5: UI 展示用的简版失败文件信息（从 DownloadFailedFile 精简，避免 UI 层直接依赖 Manager 类型）
 */
export interface FailedFileBrief {
  basename: string;
  errorKind: string;
  errorMessage: string;
  httpStatus: number;
  triedUrls: string[];
}

export enum DownloadPhase {
  PREPARE = 'prepare',
  CLIENT = 'client',
  LIBRARIES = 'libraries',
  ASSETS = 'assets',
  MODLOADER = 'modloader',
  MERGE = 'merge',
  DONE = 'done',
  ERROR = 'error',
  // v5 新增：用户取消 / 暂停态
  ABORTED = 'aborted',
  PAUSED = 'paused',
}

export interface PhaseDetail {
  phase: DownloadPhase;
  label: string;
  status: 'pending' | 'running' | 'done' | 'error';
  current: number;
  total: number;
  message: string;
}

@Observed
export class PhaseDetailModel {
  phase: string;
  label: string;
  status: string;
  current: number;
  total: number;
  message: string;

  constructor(phase: string, label: string, status: string = 'pending',
              current: number = 0, total: number = 0, message: string = '') {
    this.phase = phase;
    this.label = label;
    this.status = status;
    this.current = current;
    this.total = total;
    this.message = message;
  }
}

@Observed
export class DownloadStateModel {
  versionName: string = '';
  phase: string = '';
  progress: number = 0;
  speed: string = '';
  bytesDone: number = 0;
  bytesTotal: number = 0;
  etaSeconds: number = -1;
  durationMs: number = 0;
  phaseDetails: PhaseDetailModel[] = [];
  currentFiles: string[] = [];
  failedFiles: FailedFileBrief[] = [];
  errorKind: string = '';
  errorMessage: string = '';

  reset(): void {
    this.versionName = '';
    this.phase = '';
    this.progress = 0;
    this.speed = '';
    this.bytesDone = 0;
    this.bytesTotal = 0;
    this.etaSeconds = -1;
    this.durationMs = 0;
    this.phaseDetails = [];
    this.currentFiles = [];
    this.failedFiles = [];
    this.errorKind = '';
    this.errorMessage = '';
  }
}

export type DownloadTaskCallback = (task: DownloadTask) => void;

// v5: 阶段权重（字节级加权进度，按 MC 1.20.4 ~230 MB 实测校准）
// PREPARE/MERGE 权重小，CLIENT~15MB/LIBRARIES~35MB/ASSETS~170MB 占大头，MODLOADER 视为"安装耗时"
const PHASE_WEIGHTS_MC: Record<string, number> = {
  'prepare':   2,
  'client':   15,
  'libraries': 25,
  'assets':   45,
  'modloader': 10,
  'merge':     3,
};
const PHASE_WEIGHTS_MC_NO_LOADER: Record<string, number> = {
  'prepare':   2,
  'client':   16,
  'libraries': 28,
  'assets':   51,
  'merge':     3,
};

export class DownloadTask {
  // 输入
  gameVersion: string;
  loaderType: ModLoaderType | null;
  loaderVersion: string;
  versionName: string;
  mcDir: string;
  filesDir: string;

  // 状态
  phase: DownloadPhase = DownloadPhase.PREPARE;
  progress: number = 0;
  speed: string = '';
  phaseDetails: PhaseDetailModel[] = [];
  cancelled: boolean = false;
  errorMessage: string = '';
  // v5: 附加字段供 UI 展示
  etaSeconds: number = -1;       // 剩余秒数，-1 未知
  durationMs: number = 0;        // 任务已用时（从 start 到现在或终态）
  bytesDone: number = 0;         // 当前阶段已下载字节数（来自 NAPI 引擎）
  bytesTotal: number = 0;        // 当前阶段总字节数（来自 NAPI 引擎）
  // 失败文件列表（完成回调里从 view.failedFiles 填）
  failedFilePaths: string[] = [];
  failedFileDetails: FailedFileBrief[] = [];
  // 顶层 error 的试过源列表
  lastTriedUrls: string[] = [];

  // 回调
  onStateChange: DownloadTaskCallback | null = null;

  /**
   * 绑定活动账本（活动账本 · L2-b）。
   *
   * 必须在 start 之前调 —— 引擎一开跑就会写 native 日志，绑定晚了那些行归属不上。
   */
  setActivityId(activityId: number): void {
    this.downloader.activityId = activityId;
    // 本类自己的编排日志（阶段推进 / 清理 / 失败原因）也要归属进同一本账本，
    // 否则账本里只有 native 下载行、看不到「卡在哪个阶段」。（缺陷 1 修复）
    this.alog_ = new ActivityLogger(activityId);
  }

  /**
   * 绑定当前活动的 logger（活动账本 · 缺陷 1 修复）。
   *
   * 构造时还不知道 activityId（由 McVersionTask 构造后调 setActivityId 传入），
   * 而 ActivityLogger 的 activityId 是 readonly，因此这里先给个不归属的 0，
   * setActivityId 时整体替换。
   */
  private alog_: ActivityLogger = new ActivityLogger(0);

  // 内部
  private downloader: McDownloader;
  private modLoaderManager: ModLoaderManager = new ModLoaderManager();
  private tempDir: string = '';
  // v5: 记录当前活跃的 NAPI engine 任务 id，供 deleteResidualFiles 和外部 purge 用
  private currentEngineTaskId: number = 0;
  // v5: 当前 awaited Promise — cancelAndAwait 等它 settle 再 resolve
  private activeTaskPromise: Promise<void> | null = null;
  // v5: 记录启动时间 — 用于 UI 显示"已用 0:35"
  private startTimeMs: number = 0;
  // v5: 用户显式选"清理"时才删 tempDir（否则保留让重试复用 version.json）
  private cleanupRequested: boolean = false;
  // v5.2 L2: 区分 pause 和 cancel
  private _pauseRequested: boolean = false;
  // v6: retry 时保留 tempDir，避免重新下载 client.jar
  private _isRetry: boolean = false;
  // v5: 上次失败时从哪个阶段开始（retry 从这里继续）
  private lastFailedPhase: DownloadPhase = DownloadPhase.ERROR;
  // Phase 6.5: 当前活跃的 PhaseRunner / 共享状态（cancel/pause/resume 透传给它）
  private runner_: PhaseRunner | null = null;
  private flowState_: DownloadFlowState | null = null;

  constructor(
    gameVersion: string,
    loaderType: ModLoaderType | null,
    loaderVersion: string,
    versionName: string,
    mcDir: string,
    filesDir: string
  ) {
    if (safeBaseName(gameVersion) !== gameVersion) {
      throw new Error('gameVersion 不是安全文件名');
    }
    if (safeBaseName(versionName) !== versionName) {
      throw new Error('versionName 不是安全文件名');
    }
    this.gameVersion = gameVersion;
    this.loaderType = loaderType;
    this.loaderVersion = loaderVersion;
    this.versionName = versionName;
    this.mcDir = mcDir;
    this.filesDir = filesDir;
    this.downloader = new McDownloader(mcDir);
    // 活动账本（L2-b）：activityId 由外部（McVersionTask）在构造后赋值，
    // 见 setActivityId。这里先留 0（不归属）。
    this.tempDir = mcDir + '/download-temp';
    this.initPhaseDetails();
  }

  private initPhaseDetails(): void {
    let details: PhaseDetailModel[] = [
      new PhaseDetailModel(DownloadPhase.PREPARE, '获取版本信息'),
      new PhaseDetailModel(DownloadPhase.CLIENT, '下载 client.jar'),
      new PhaseDetailModel(DownloadPhase.LIBRARIES, '下载 libraries'),
      new PhaseDetailModel(DownloadPhase.ASSETS, '下载 assets'),
    ];
    if (this.loaderType) {
      let loaderLabel = this.loaderType === ModLoaderType.FABRIC ? 'Fabric 安装' : 'Forge 安装';
      details.push(new PhaseDetailModel(DownloadPhase.MODLOADER, loaderLabel));
    }
    details.push(new PhaseDetailModel(DownloadPhase.MERGE, '合并版本'));
    this.phaseDetails = details;
  }

  /**
   * 同步取消（兼容旧调用方）。UI 标志位立即翻黑，但 C++ 任务可能还在收敛。
   * v5 强烈推荐用 `cancelAndAwait(cleanupFiles)` 替代。
   */
  cancel(): void {
    this.cancelled = true;
    if (this.flowState_) this.flowState_.cancelled = true;
    this.downloader.cancel();
    if (this.runner_) this.runner_.cancel(false);
  }

  /**
   * v5: 取消并等待真正收敛（NAPI 报 aborted）。
   * UI 层调此方法后可安全开启新任务，无资源冲突。
   * 若 cleanupFiles=true，额外对引擎做 deleteTaskFiles + 清掉 tempDir。
   */
  async cancelAndAwait(cleanupFiles: boolean = false): Promise<void> {
    this.cancelled = true;
    if (this.flowState_) this.flowState_.cancelled = true;
    this.cleanupRequested = cleanupFiles;
    this.downloader.cancel();
    if (this.runner_) this.runner_.cancel(cleanupFiles);
    // 等 start() 的 Promise settle（reject '已取消' 或 resolve）
    if (this.activeTaskPromise) {
      try {
        await this.activeTaskPromise;
      } catch (e) {
        // expected: Error '已取消' 或其他失败；全部吞掉，调用方通过 this.phase 判断结果
      }
    }
    // 清理磁盘
    if (cleanupFiles) {
      await this.deleteResidualFiles();
    }
  }

  /**
   * v5: 从上次失败的阶段重新跑。利用引擎的 sha1 预检跳过已完成文件。
   * 注意：不重新 fetchVersionInfo（tempDir 里的 version.json 会被复用）。
   */
  async retry(): Promise<void> {
    if (this.phase !== DownloadPhase.ERROR && this.phase !== DownloadPhase.ABORTED
        && this.phase !== DownloadPhase.PAUSED) {
      this.alog_.warn(TAG, `retry() called in phase=${this.phase}, ignoring`, null, LOG_DOMAIN_DOWNLOAD)
      return;
    }
    // retry 会创建新的 native task；旧失败/取消 task 若仍占有 canonical path，
    // 新 task 会被 Engine ownership 表拒绝。必须先确认旧 execution 已 purge。
    if (!this.purgeNativeOwners()) {
      throw new Error('旧下载任务仍在收敛，请稍后重试');
    }
    this._pauseRequested = false;
    this._isRetry = true;
    let startIdx = this.phaseDetails.findIndex(d => d.status === 'error' || d.status === 'running');
    if (startIdx < 0) startIdx = 0;
    // 重置失败阶段及之后所有阶段为 pending
    for (let i = startIdx; i < this.phaseDetails.length; i++) {
      this.phaseDetails[i].status = 'pending';
      this.phaseDetails[i].current = 0;
      this.phaseDetails[i].message = '';
    }
    this.errorMessage = '';
    this.failedFilePaths = [];
    this.failedFileDetails = [];
    this.lastTriedUrls = [];
    this.cancelled = false;
    this.cleanupRequested = false;
    this.lastFailedPhase = DownloadPhase.ERROR;
    // BUG-4 fix: 在 notify 前将 phase 从 ERROR 改为 PREPARE，
    // 避免 onStateChange 回调误判为终态 ERROR 而把 mcDownloading 置 false → FAB 消失
    this.phase = DownloadPhase.PREPARE;
    this.updateOverallProgress();
    this.notify();

    // 清理残留的目标版本目录（Forge installer 可能留下不完整的 json/jar）
    // doStart 开头会用统一标准检查，但这里先清一遍避免任何残留干扰
    let targetDir = this.mcDir + '/versions/' + this.versionName;
    try {
      let st = fs.statSync(targetDir);
      if (st.isDirectory()) {
        removeDirRecursive(targetDir);
        this.alog_.info(TAG, `retry: cleaned target dir: ${targetDir}`, LOG_DOMAIN_DOWNLOAD)
      }
    } catch (e) { /* not exists, OK */ }

    return this.start();
  }

  /**
   * v5.2 L2: 暂停 — 内部仍调 cancelAndAwait(false) 中止传输，
   * 但在 ArkTS 层标记 phase=PAUSED 而非 ABORTED，让 UI 和日志能区分。
   */
  async pause(): Promise<void> {
    this._pauseRequested = true;
    await this.cancelAndAwait(false);
    if (this.phase === DownloadPhase.ABORTED) {
      this.phase = DownloadPhase.PAUSED;
      this.notify();
    }
  }

  /**
   * v5: 继续（调用方必须在 pause/PAUSED/ERROR/ABORTED 后调用）。
   * 实现上等同 retry — 引擎会走断点续传跳过已下好的文件。
   */
  async resume(): Promise<void> {
    return this.retry();
  }

  /** Registry owner barrier：释放本 DownloadTask 历次阶段创建的全部 native task。 */
  purgeNativeOwners(): boolean {
    let allPurged = this.downloader.purgeNativeOwners();
    if (this.currentEngineTaskId > 0) {
      let currentPurged = false;
      try { currentPurged = DownloadManager.instance().purgeTask(this.currentEngineTaskId); }
      catch (e) { currentPurged = false; }
      if (currentPurged) this.currentEngineTaskId = 0;
      else allPurged = false;
    }
    return allPurged;
  }

  /**
   * v5: 清理磁盘残留。
   *   1. 对当前引擎任务做 deleteTaskFiles（清 libraries/assets 等半下文件+meta）
   *   2. 清 tempDir
   *   3. 清目标版本目录（无论 versionName 是否等于 gameVersion）
   * 返回释放的字节数（仅第 1 步统计）。
   */
  async deleteResidualFiles(): Promise<number> {
    let freed = 0;
    if (this.currentEngineTaskId > 0) {
      try {
        freed = DownloadManager.instance().deleteTaskFiles(this.currentEngineTaskId);
      } catch (e) { /* ignore */ }
      // v5 Bug-3: 清完磁盘后顺手 purge native 注册表里的 LoaderDownload 记录。
      // purge 只在终态允许 —— 此处调用方应已通过 cancelAndAwait 让任务进入 Aborted/Failed；
      // 若不是终态 native 会拒绝，这里 best-effort 忽略。
      try {
        if (DownloadManager.instance().purgeTask(this.currentEngineTaskId)) {
          this.currentEngineTaskId = 0;
        }
      } catch (e) { /* ignore; retain id so cleanup can be retried */ }
    }
    // 清 tempDir（fetchVersionInfo 缓存）
    this.cleanTempDir();
    // 清目标版本目录（v5 S0-2 修复：无条件删，之前"versionName===gameVersion"时不清理的 bug）
    let targetDir = this.mcDir + '/versions/' + this.versionName;
    try { removeDirRecursive(targetDir); } catch (e) { /* ignore */ }
    this.alog_.info(TAG, `deleteResidualFiles: freed=${freed} bytes`, LOG_DOMAIN_DOWNLOAD)
    return freed;
  }

  private notify(): void {
    if (this.onStateChange) {
      this.onStateChange(this);
    }
  }

  private setPhase(phase: DownloadPhase): void {
    this.phase = phase;
    // 更新 phaseDetails 中对应项的 status
    for (let detail of this.phaseDetails) {
      if (detail.phase === phase) {
        detail.status = 'running';
      }
    }
    this.notify();
  }

  private completePhase(phase: DownloadPhase, message: string): void {
    for (let detail of this.phaseDetails) {
      if (detail.phase === phase) {
        detail.status = 'done';
        detail.message = message;
      }
    }
    this.updateOverallProgress();
    this.notify();
  }

  private failPhase(phase: DownloadPhase, message: string): void {
    for (let detail of this.phaseDetails) {
      if (detail.phase === phase) {
        detail.status = 'error';
        detail.message = message;
      }
    }
    this.notify();
  }

  private updatePhaseProgress(phase: DownloadPhase, current: number, total: number, message: string): void {
    for (let detail of this.phaseDetails) {
      if (detail.phase === phase) {
        detail.current = current;
        detail.total = total;
        detail.message = message;
      }
    }
    this.updateOverallProgress();
    this.notify();
  }

  /**
   * v5 S1-1: 字节级加权进度。
   * 各阶段按 MC 1.20.4 ~230MB 实测校准权重（见 PHASE_WEIGHTS_MC）：
   *   - done 阶段贡献完整权重
   *   - running 阶段按 current/total 比例贡献
   *   - pending 阶段贡献 0
   * 对比旧版"donePhases/totalPhases"：平滑得多，不会出现 client.jar 下完只动 16% 的假象。
   */
  private updateOverallProgress(): void {
    const weights = this.loaderType ? PHASE_WEIGHTS_MC : PHASE_WEIGHTS_MC_NO_LOADER;
    let total = 0;
    for (let detail of this.phaseDetails) {
      const w = weights[detail.phase] || 0;
      if (detail.status === 'done') {
        total += w;
      } else if (detail.status === 'running' && detail.total > 0) {
        total += w * (detail.current / detail.total);
      }
    }
    // clamp to [0, 100]
    this.progress = Math.max(0, Math.min(100, Math.round(total)));
  }

  // ============================================================
  //  主执行流程
  // ============================================================

  async start(): Promise<void> {
    // v5: 一次只允许一个 active task。如果已有 activeTaskPromise，等它完成再重新开始。
    if (this.activeTaskPromise) {
      this.alog_.warn(TAG, 'start() called while task already running, awaiting old one...', null, LOG_DOMAIN_DOWNLOAD)
      try { await this.activeTaskPromise; } catch (e) { /* ignore */ }
    }
    const p = this.doStart();
    this.activeTaskPromise = p;
    try {
      await p;
    } catch (e) {
      // ⚠️ 2026-08-04：doStart 的**前置检查**（"版本 X 已存在"、ensureRanking 之前的
      //   目录清理等）抛在 phase try/catch 之外，那条路径一次 notify 都不发，phase 会
      //   一直停在 PREPARE。上层 McVersionTask.mapPhase(PREPARE) = PREPARING，于是
      //   view 永久卡"准备中"：isInProgressState 恒真 → Registry.remove() 拒绝清理，
      //   enqueue 同 id 又被"已在进行中"顶掉 → 这个版本在杀进程前再也装不了。
      //   这里补一次终态 + notify，保证任何抛出路径都能被 UI 观察到。
      if (this.phase !== DownloadPhase.ERROR && this.phase !== DownloadPhase.ABORTED) {
        this.phase = this.cancelled ? DownloadPhase.ABORTED : DownloadPhase.ERROR;
        if (this.errorMessage.length === 0) {
          let err = e as Error;
          this.errorMessage = err.message !== undefined ? err.message : String(e);
        }
        this.notify();
      }
      throw e as Error;
    } finally {
      // 注意：不把 activeTaskPromise 置 null 在这里 — 外层 cancelAndAwait 可能正在 await 它。
      // 下一次 start() 开头会处理。
      if (this.activeTaskPromise === p) this.activeTaskPromise = null;
    }
  }

  /**
   * v5 / Phase 6.5: 内部实际执行体。外层 start() 包装让 cancelAndAwait 能 await。
   *
   * 2026-05-06 重构 (Phase 6.5)：原 ~180 行硬编码的 6 阶段 try/catch 替换为：
   *   1. 构造 DownloadFlowState 共享状态容器
   *   2. 构造 6 个 IDownloadPhase 实例（loaderType=null 时跳过 ModloaderPhase）
   *   3. PhaseRunner 顺序调度，进度回调走 handlePhaseProgress 翻译成老 phaseDetails 模型
   * 公开 API（start/cancel/cancelAndAwait/retry/pause/resume/onStateChange）签名零改动。
   */
  private async doStart(): Promise<void> {
    this.cancelled = false;
    this.errorMessage = '';
    this.startTimeMs = Date.now();
    this.alog_.info(TAG, `Start: game=${this.gameVersion} loader=${this.loaderType || 'none'} ver=${this.loaderVersion} name=${this.versionName}`, LOG_DOMAIN_DOWNLOAD)

    try {
      let ranking = await ensureRanking();
      this.alog_.info(TAG, `Source ranking: bmclapiFirst=${ranking.bmclapiFirst ? 'true' : 'false'}`, LOG_DOMAIN_DOWNLOAD)
    } catch (e) {
      this.alog_.warn(TAG, 'Source probe failed, using defaults', e, LOG_DOMAIN_DOWNLOAD)
    }

    // 检查目标版本是否已安装（统一标准：jar > 1MB）
    let targetDir = this.mcDir + '/versions/' + this.versionName;
    if (isVersionInstalled(this.mcDir, this.versionName)) {
      throw new Error('版本 ' + this.versionName + ' 已存在');
    }
    removeVersionInstallCommit(this.mcDir, this.versionName);
    // 如果目录存在但不完整（残留），自动清理后继续
    try {
      let stat = fs.statSync(targetDir);
      if (stat.isDirectory()) {
        this.alog_.info(TAG, `Cleaning incomplete version dir: ${targetDir}`, LOG_DOMAIN_DOWNLOAD)
        removeDirRecursive(targetDir);
      }
    } catch (e) { /* dir not exists, OK */ }

    if (this._isRetry) {
      this.alog_.info(TAG, 'Retry mode: preserving tempDir to reuse client.jar / version.json', LOG_DOMAIN_DOWNLOAD)
    } else {
      this.cleanTempDir();
    }
    this._isRetry = false;
    try { fs.mkdirSync(this.mcDir, true); } catch (e) { /* exists */ }
    try { fs.mkdirSync(this.mcDir + '/versions', true); } catch (e) { /* exists */ }
    try { fs.mkdirSync(this.mcDir + '/libraries', true); } catch (e) { /* exists */ }
    try { fs.mkdirSync(this.tempDir, true); } catch (e) { /* exists */ }
    let tempVersionDir = this.tempDir + '/versions/' + this.gameVersion;
    try { fs.mkdirSync(tempVersionDir, true); } catch (e) { /* exists */ }

    // ----------------------------------------
    // Phase 6.5: 构造 PhaseRunner + phase 序列
    // ----------------------------------------
    let state = new DownloadFlowState(
      this.gameVersion,
      this.loaderType,
      this.loaderVersion,
      this.versionName,
      this.mcDir,
      this.filesDir,
    );

    // 选用合适的权重表（与现有 PHASE_WEIGHTS_MC* 字典一一对应）
    let weights: Record<string, number> = this.loaderType ? PHASE_WEIGHTS_MC : PHASE_WEIGHTS_MC_NO_LOADER;

    let mcDl = this.downloader;
    let phases: IDownloadPhase[] = [
      new PreparePhase(state, mcDl, weights['prepare']),
      new ClientPhase(state, mcDl, weights['client']),
      new LibrariesPhase(state, mcDl, weights['libraries']),
      new AssetsPhase(state, mcDl, weights['assets']),
    ];
    if (this.loaderType !== null) {
      phases.push(new ModloaderPhase(state, this.modLoaderManager, weights['modloader']));
    }
    phases.push(new MergePhase(state, weights['merge']));

    let ctx: PhaseContext = {
      taskId: 'dl-' + this.startTimeMs.toString(),
      versionName: this.versionName,
      gameVersion: this.gameVersion,
      loaderType: this.loaderType ? String(this.loaderType) : 'vanilla',
      mcDir: this.mcDir,
      filesDir: this.filesDir,
    };

    let runner = new PhaseRunner(phases, ctx);
    this.runner_ = runner;
    this.flowState_ = state;

    try {
      await runner.run((p: PhaseProgress): void => {
        this.handlePhaseProgress(p);
      });

      // 只有全部 phase 成功后才发布 durable commit marker。marker 写入失败必须让安装失败，
      // 防止半安装目录被后续扫描识别为可启动版本。
      writeVersionInstallCommit(this.mcDir, this.versionName);
      for (let d of this.phaseDetails) {
        if (d.status === 'running' || d.status === 'pending') {
          d.status = 'done';
        }
      }
      this.phase = DownloadPhase.DONE;
      this.progress = 100;
      this.durationMs = Date.now() - this.startTimeMs;
      this.alog_.info(TAG, `Download complete: ${this.versionName} (dur=${this.durationMs}ms)`, LOG_DOMAIN_DOWNLOAD)
      this.notify();

    } catch (e) {
      let msg = (e as Error).message || String(e);
      this.durationMs = Date.now() - this.startTimeMs;

      // v5: 区分用户取消 vs 真失败
      // L-7 修复：用 CancelledError 类型 + instanceof 判定，替代脆弱的中文字符串匹配。
      // CancelledError.is() 内部保留字符串后备，兼容历史代码 / NAPI 抛 'cancelled' 字面量。
      let isAborted = CancelledError.is(e as Object);
      this.phase = isAborted ? DownloadPhase.ABORTED : DownloadPhase.ERROR;
      this.errorMessage = isAborted ? CancelledError.DEFAULT_MESSAGE : msg;
      // v5: 记下失败阶段供 retry 定位（以当前 running 的 phase 为准）
      for (let d of this.phaseDetails) {
        if (d.status === 'running') {
          this.lastFailedPhase = d.phase as DownloadPhase;
          break;
        }
      }

      if (isAborted) {
        this.alog_.info(TAG, `Download aborted by user at phase=${this.lastFailedPhase}`, LOG_DOMAIN_DOWNLOAD)
      } else {
        this.alog_.error(TAG, `Download failed at phase=${this.lastFailedPhase}: ${msg}`, null, LOG_DOMAIN_DOWNLOAD)
        this.failPhase(this.lastFailedPhase, msg);

        // v5: 从 DownloadManager 拉最近的任务视图，提取 failedFiles/triedUrls 给 UI
        try {
          if (this.currentEngineTaskId > 0) {
            let mgr = DownloadManager.instance();
            let view = mgr.getTask(this.currentEngineTaskId);
            if (view) {
              this.lastTriedUrls = view.triedUrls || [];
              this.failedFilePaths = [];
              this.failedFileDetails = [];
              for (let ff of (view.failedFiles || [])) {
                this.failedFilePaths.push(ff.localPath);
                let brief: FailedFileBrief = {
                  basename: ff.basename,
                  errorKind: ff.lastError ? ff.lastError.kind : '',
                  errorMessage: ff.lastError ? ff.lastError.message : '',
                  httpStatus: ff.lastError ? ff.lastError.httpStatus : 0,
                  triedUrls: ff.triedUrls || [],
                };
                this.failedFileDetails.push(brief);
              }
            }
          }
        } catch (fe) { /* best-effort */ }
      }

      // 失败或取消时目标目录一定是不完整安装，必须清理；不能再以
      // versionName !== gameVersion 为条件，否则原版同名安装失败会留下残目录。
      // tempDir（client.jar / version.json）仍保留供 retry 复用。
      try {
        removeDirRecursive(targetDir);
        this.alog_.info(TAG, `Cleaned up incomplete target dir: ${targetDir}`, LOG_DOMAIN_DOWNLOAD)
      } catch (e2) { /* ignore */ }

      this.notify();
      throw new Error(this.errorMessage);
    } finally {
      // v5 S0-2: 条件化清理 tempDir —
      //   - DONE：安装完了，temp 已无用，清
      //   - cleanupRequested（用户选了"取消+清理"或手动 deleteResidualFiles）：清
      //   - 其他失败/ABORTED：保留 tempDir（里面有 version.json），retry 时复用
      if (this.phase === DownloadPhase.DONE || this.cleanupRequested) {
        this.cleanTempDir();
      }
      // 2026-05-05 沙箱化: 无论成功失败都清理 installSandboxDir。
      // Phase 6.5: 由 ModloaderPhase 写入 state.installSandboxDir，从这里读出来清理。
      let sandbox = state.installSandboxDir;
      if (sandbox.length > 0) {
        try { removeDirRecursive(sandbox); } catch (e) { /* */ }
        this.alog_.info(TAG, `Sandbox cleaned: ${sandbox}`, LOG_DOMAIN_DOWNLOAD)
      }
      this.runner_ = null;
      this.flowState_ = null;
    }
  }

  /**
   * Phase 6.5: 把 PhaseRunner 的 PhaseProgress 翻译成老的 phaseDetails 模型 + 任务级状态字段。
   *
   * 状态过渡：见到 status='pending' 的 phase → 同步把所有其他 'running' 的 phase 翻 'done'，
   *           把当前 phase 翻 'running'（self.phase 也跟着变）。
   *
   * 字段更新：
   *   - p.speedBps / p.etaSeconds / p.bytesDone / p.bytesTotal → 任务级字段
   *   - p.current / p.total / p.message → 当前 phase detail
   *   - currentEngineTaskId 从 McDownloader 拉（download phase 才有）
   */
  private handlePhaseProgress(p: PhaseProgress): void {
    let phaseDetail: PhaseDetailModel | null = null;
    for (let d of this.phaseDetails) {
      if (d.phase === p.phase) { phaseDetail = d; break; }
    }
    if (phaseDetail === null) return;

    // 阶段切换
    if (phaseDetail.status === 'pending') {
      for (let d of this.phaseDetails) {
        if (d.status === 'running' && d.phase !== p.phase) {
          d.status = 'done';
        }
      }
      phaseDetail.status = 'running';
      this.phase = p.phase as DownloadPhase;
    }

    // 任务级速度/ETA/字节
    if (p.speedBps !== undefined && p.speedBps > 0) {
      this.speed = formatSpeed(p.speedBps);
    }
    if (p.etaSeconds !== undefined && p.etaSeconds >= 0) {
      this.etaSeconds = p.etaSeconds;
    }
    if (p.bytesDone !== undefined) this.bytesDone = p.bytesDone;
    if (p.bytesTotal !== undefined) this.bytesTotal = p.bytesTotal;
    if (this.startTimeMs > 0) this.durationMs = Date.now() - this.startTimeMs;

    let curId = this.downloader.getActiveTaskId();
    if (curId > 0) this.currentEngineTaskId = curId;

    // phase detail 内字节 / 文件数 / 当前文件名
    if (p.current !== undefined) phaseDetail.current = p.current;
    if (p.total !== undefined) phaseDetail.total = p.total;
    if (p.message !== undefined && p.message.length > 0) phaseDetail.message = p.message;

    this.updateOverallProgress();
    this.notify();
  }

  // ============================================================
  //  工具方法
  // ============================================================
  // Phase 6.5 重构后，installModLoader / findLoaderJson 移到 ModloaderPhase；
  // migrateSandboxLibraries / migrateLibrariesRecursive 移到 MergePhase；
  // writeTextFile / fileExists 移到对应 phase 的 static helper。

  private cleanTempDir(): void {
    try { removeDirRecursive(this.tempDir); } catch (e) { /* ignore */ }
  }
}

/**
 * DownloadManager.ets — ArkTS 侧下载任务单例（P1-3 v3 Stage 3）
 *
 * 职责：
 *   - 包装 libentry.so 暴露的 downloadXxx NAPI 方法
 *   - 维护任务列表（DownloadTaskView[]）
 *   - 把 native 的 progress/complete 回调扇出给多个 UI 监听者
 *
 * 设计：
 *   - 单例：DownloadManager.instance()
 *   - 任务对象：DownloadTaskView（持有 taskId + 实时状态）
 *   - 监听器：addListener(cb) / removeListener(cb)
 *       UI 层（DownloadFloatingCircle / DownloadPanel）注册监听刷新展示
 *
 * 注意事项：
 *   1. NAPI 回调在 JS 主线程（通过 threadsafe_function）—— 所以在回调里直接
 *      改 view 属性是安全的
 *   2. DownloadTaskView 不是 @Observed（为了保持纯服务层），UI 层自己用 @State
 *      快照 + 手动 trigger refresh
 *   3. 真机首次 HTTPS 下载可能因为 CA 校验失败，若 onComplete 的 error.kind
 *      是 "SslError"，需要后续 Stage 1c 处理（打包 ca-bundle 或关闭校验）
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppLogger } from 'commons';
import { formatError } from 'commons';

const TAG = 'DownloadManager';
const DEFAULT_FETCH_RESPONSE_LIMIT_BYTES: number = 16 * 1024 * 1024;
const TERMINAL_QUERY_INTERVAL_MS: number = 500;
const ROLLBACK_PURGE_INTERVAL_MS: number = 250;
const ROLLBACK_PURGE_MAX_ATTEMPTS: number = 120;

// ============================================================================
// 类型定义（和 libentry/index.d.ts 保持一致）
//
// ArkTS 严格模式不允许内嵌 object literal 做类型，所有嵌套对象都得单独 interface
// ============================================================================

/** 文件完整性校验配置 */
export interface DownloadCheck {
  sha1?: string;
  size?: number;
}

/**
 * Phase 2.3 (P2-2): `fetchTextEx` 的成功结果。
 * 200-299 / 304 都会进入此结构；其他 HTTP / 网络错误则 reject。
 */
export interface FetchTextRichResult {
  /** HTTP 响应码：200-299 = 实体；304 = 条件请求未变更（body 可能为空） */
  statusCode: number;
  /** 响应正文。304 时调用方应使用本地缓存而非 body 内容。 */
  body: string;
  /** 响应头（key 已小写）。`etag` / `last-modified` / `content-type` 等。 */
  headers: Record<string, string>;
}

/** 下载文件规格 */
export interface DownloadFileSpec {
  localPath: string;
  urls: string[];
  /** native 打开文件前必须再次校验 localPath 位于该可信根目录内。 */
  allowedRoot: string;
  check?: DownloadCheck;
  /**
   * 单文件连接上限（可选，范围 1..16）。
   *
   * - 不传：使用引擎按文件大小决定的自适应目标；>=8MiB 的默认文件可能增长到 16 连接。
   * - 1..4：纯上限模式，保留默认 2MiB 分段、连接复用和动态选最快源；适合明确限制并发的
   *   client.jar，或用 1 禁用 Range、执行单连接全量 GET。
   * - 5..16：高并发模式，使用更细分段、HTTP/1.1 调优和多源轮询；仅用于已验证可从多连接
   *   获益的慢速镜像内容，例如 Forge installer 或 Modrinth 文件。
   *
   * 完整性仍由 check 与 native Range 响应校验兜底。
   */
  maxConnections?: number;
}

/** 任务规格（创建任务时传入） */
export interface DownloadTaskSpec {
  name: string;
  files: DownloadFileSpec[];
  /**
   * 归属的活动主键（活动账本 · L2-b）；缺省 = 不归属。
   *
   * 传了它，本次下载在 native 侧产生的日志（`DL_MULTI` 等）会被分流进
   * `ledger/<activityId>/launcher.log`。下载引擎用共享 worker 池 + 单事件循环，
   * 靠 `task_id → activityId` 关联表逐个任务定位归属，详见 `amcl_log.h`。
   */
  activityId?: number;
}

/** 进度事件（来自 native） */
export interface DownloadProgressEvent {
  taskId: number;
  executionEpoch: number;
  overallProgress: number;
  speedBps: number;
  activeThreads: number;
  currentFile: string;
  filesDone: number;
  filesTotal: number;
  bytesDone: number;
  bytesTotal: number;
  // v5: 剩余秒数 / 当前活跃下载文件 basename 列表
  etaSeconds: number;
  currentFiles: string[];
}

/** 错误详情（完成事件里的 error 字段） */
export interface DownloadError {
  kind: string;
  message: string;
  nativeCode: number;
  httpStatus: number;
  url: string;
  // v5: 该错误涉及的所有试过的源 URL（去重后）
  triedUrls: string[];
}

/** v5: 失败文件详情（仅在 Complete 事件里成组给出） */
export interface DownloadFailedFileError {
  kind: string;
  message: string;
  httpStatus: number;
  nativeCode: number;
}
export interface DownloadFailedFile {
  localPath: string;
  basename: string;
  lastError?: DownloadFailedFileError;
  triedUrls: string[];
}

/** 最终进度快照（终态时由 Engine 带在 complete 事件里） */
export interface DownloadFinalProgress {
  overallProgress: number;
  speedBps: number;
  currentFile: string;
  filesDone: number;
  filesTotal: number;
  bytesDone: number;
  bytesTotal: number;
  // v5: 剩余秒数 / 当前活跃下载文件 basename 列表
  etaSeconds: number;
  currentFiles: string[];
}

/** 完成事件（来自 native） */
export interface DownloadCompleteEvent {
  taskId: number;
  executionEpoch: number;
  success: boolean;
  // v5: 用户主动取消 vs 失败的区分标志
  aborted: boolean;
  // v5: 任务总耗时（毫秒）
  durationMs: number;
  error?: DownloadError;
  // v5: 失败文件列表
  failedFiles: DownloadFailedFile[];
  finalProgress: DownloadFinalProgress;
}

/**
 * UI 展示的任务视图。生命周期：
 *   created → (progress events 反复刷新) → finished (success 或 fail)
 *
 * 不用 @Observed 保持纯数据。UI 层通过监听 DownloadManager 的事件刷新。
 */
export class DownloadTaskView {
  taskId: number = 0;
  executionEpoch: number = 0;
  name: string = '';
  state: string = 'Waiting';          // Waiting/Loading/Finished/Failed/Aborted
  progress: number = 0;               // 0.0 ~ 1.0
  speedBps: number = 0;
  activeThreads: number = 0;
  currentFile: string = '';
  filesDone: number = 0;
  filesTotal: number = 0;
  bytesDone: number = 0;
  bytesTotal: number = 0;
  errorKind: string = '';
  errorMessage: string = '';
  finished: boolean = false;
  success: boolean = false;
  createdAt: number = Date.now();
  finishedAt: number = 0;
  // v5 新增：UI 展示需要的详细字段
  aborted: boolean = false;            // 是否被用户主动取消
  etaSeconds: number = -1;             // 剩余秒数，-1 未知
  durationMs: number = 0;              // 终态时由 complete 事件填
  currentFiles: string[] = [];         // 当前活跃文件 basename 列表
  triedUrls: string[] = [];            // 顶层 error 的试过源（仅失败时填）
  failedFiles: DownloadFailedFile[] = [];  // 失败文件详情（仅失败时填）
}

/** 监听器签名：任一 task 状态变化时被调用 */
export type DownloadListener = (view: DownloadTaskView) => void;

type InternalCompleteListener = (view: DownloadTaskView, ev: DownloadCompleteEvent) => void;

interface TaskRegistration {
  taskId: number;
  view: DownloadTaskView;
  generation: number;
}

/**
 * journal 条目 —— **只存摘要，绝不存 files 数组**。
 *
 * ⚠️ 2026-08-04 重构（原实现把整个 `DownloadTaskSpec` 序列化进来，两个致命后果）：
 *
 *  1. 体积炸。单条 asset 的 spec 片段约 460 字节（localPath + 两个绝对 URL + allowedRoot
 *     + check），4750 个对象就是 **2.1 MB**。真机实测 `download-tasks-v1.json` 已经
 *     2,192,854 字节，而 `persistJournal_` 有 4 MiB 硬上限且**抛点在 createRegisterStart_
 *     的事务 try 之外** —— 再留存一条 assets 级条目就会让**每一个下载入口**在发出第一个
 *     字节前直接抛异常。这是一颗只差一步就引爆的地雷。
 *  2. 主线程 I/O。每次建任务都要 JSON.stringify + 同步写 2 MB，全发生在 UI 线程。
 *
 * 现在只留诊断必需的字段。真正的断点续传能力**从来不依赖 journal** —— native 侧的
 * `.download-meta` + `.amcl.part` 才是续传载体，用户重新点下载时 `NetFile::start()`
 * 会自动 restoreFromMeta 接着下。
 */
interface DownloadJournalEntry {
  journalId: string;
  createdAt: number;
  /** 任务名（= DownloadTaskSpec.name）。refreshFromNative 用它把 native 任务重绑回条目。 */
  name: string;
  /** 文件数，仅用于日志/诊断。 */
  fileCount: number;
}

interface DownloadJournalDocument {
  version: number;
  entries: DownloadJournalEntry[];
}

// ============================================================================
// 工具函数 (re-export)
// ============================================================================
//
// 工程注意：原本 DownloadManager 内部维护一份 formatBytes / formatSpeed，
// 与 utils/PathUtils.ets 内的同名函数行为一致但实现独立（D26-1，self-inspection 报告）。
// 2026-05-06 收敛：DownloadManager 从 utils/PathUtils 重新导出，所有调用方
// （JdkManager / DownloadHistory / DownloadTab）的 import 路径无需变更。

export { formatBytes, formatSpeed } from 'commons';

// ============================================================================
// 下载引擎 native 抽象（三层架构 · D1=方案 a / 控制反转）
//
// download 域抽成 HAR 后**不能直接依赖 libentry.so**（HAR 反向依赖 HAP 的 .so 非法）。
// 改为：定义 DownloadNativeEngine 接口，由持有 native 的 entry(HAP) 在启动时注入
// testNapi 适配实现（见 EntryAbility.EntryDownloadEngine）。未注入时调用会抛错
// （native 是下载的硬依赖，缺失属编程错误，不静默降级）。
// ============================================================================

/** native fetchText 结果（与 libentry DownloadFetchTextResult 对齐，本地声明以脱离 .so 类型依赖）。 */
export interface NativeFetchTextResult {
  ok: boolean;
  body?: string;
  statusCode?: number;
  headers?: Record<string, string>;
  errorKind?: string;
  errorMessage?: string;
}

/** native list/query 返回的任务快照。 */
export interface NativeTaskInfo {
  taskId: number;
  /** Native 快照协议必填；Waiting 可为 0，启动后的 execution 必须为正整数。 */
  executionEpoch: number;
  name: string;
  state: string;
  progress: number;
  filesDone: number;
  filesTotal: number;
  overallProgress?: number;
  speedBps?: number;
  activeThreads?: number;
  currentFile?: string;
  bytesDone?: number;
  bytesTotal?: number;
  etaSeconds?: number;
  currentFiles?: string[];
  durationMs?: number;
  terminal?: boolean;
  error?: DownloadError;
  errorKind?: string;
  errorMessage?: string;
  failedFiles?: DownloadFailedFile[];
}

/** 下载引擎 native 抽象：方法集与 testNapi.download* 一一对应。 */
export interface DownloadNativeEngine {
  setCaBundle(path: string): void;
  computeFileSha1(path: string): string;
  publishNoReplace(sourcePath: string, destinationPath: string): boolean;
  fetchText(primaryUrl: string, mirrors: string[], timeoutSeconds: number,
            requestHeaders?: Record<string, string>, maxResponseBytes?: number): Promise<NativeFetchTextResult>;
  createTask(spec: DownloadTaskSpec): number;
  /** 关联 native 下载任务与活动账本（活动账本 · L2-b）；activityId 传 0 解除。 */
  bindActivity(taskId: number, activityId: number): void;
  /** 任务终态时解绑，避免 native 的 32 槽关联表被占满。 */
  unbindActivity(taskId: number): void;
  onProgress(taskId: number, cb: (ev: DownloadProgressEvent) => void): boolean;
  onComplete(taskId: number, cb: (ev: DownloadCompleteEvent) => void): boolean;
  start(taskId: number): boolean;
  cancel(taskId: number): boolean;
  pause(taskId: number): boolean;
  resume(taskId: number): boolean;
  deleteTaskFiles(taskId: number): number;
  retryFailed(taskId: number, localPaths: string[]): boolean;
  purgeTask(taskId: number): boolean;
  listActive(): NativeTaskInfo[];
  queryTask(taskId: number): NativeTaskInfo | null;
  /** 停止全部 native 下载并释放引擎全局资源；Ability 销毁时调用。 */
  shutdown(): void;
}

let g_downloadEngine: DownloadNativeEngine | null = null;

/** 由 entry（持 libentry.so 的 HAP）在启动时注入下载引擎实现；传 null 安全解绑。 */
export function setDownloadNativeEngine(e: DownloadNativeEngine | null): void {
  if (g_downloadEngine === e) return;
  g_downloadEngine = e;
  DownloadManager.handleNativeEngineChanged();
}

/** 取已注入的下载引擎；未注入即编程错误（直接抛）。 */
function dlEngine(): DownloadNativeEngine {
  if (!g_downloadEngine) {
    throw new Error('DownloadNativeEngine 未注入 — 须在启动期调用 setDownloadNativeEngine()');
  }
  return g_downloadEngine;
}

export function downloadComputeFileSha1(path: string): string {
  return dlEngine().computeFileSha1(path);
}

export function downloadPublishNoReplace(sourcePath: string, destinationPath: string): boolean {
  return dlEngine().publishNoReplace(sourcePath, destinationPath);
}

// ============================================================================
// DownloadManager 单例
// ============================================================================

export class DownloadManager {
  private static _instance: DownloadManager | null = null;

  private tasks_: Map<number, DownloadTaskView> = new Map();
  /** 每次 callback owner 绑定均分配新 generation，旧 ArkTS closure 只能被动丢弃。 */
  private taskGenerations_: Map<number, number> = new Map();
  private nextGeneration_: number = 1;
  private listeners_: DownloadListener[] = [];
  private caBundleInitialized_: boolean = false;
  private journalPath_: string = '';
  private journalEntries_: Map<string, DownloadJournalEntry> = new Map();
  private taskJournalIds_: Map<number, string> = new Map();
  private journalSequence_: number = 1;
  private journalLoaded_: boolean = false;

  /** bridge detach/re-attach 时使旧 env callback 失效，并强制新引擎重新注入 CA。 */
  static handleNativeEngineChanged(): void {
    if (DownloadManager._instance) {
      DownloadManager._instance.tasks_.clear();
      DownloadManager._instance.taskGenerations_.clear();
      DownloadManager._instance.taskJournalIds_.clear();
      // 2026-08-04：taskId→journalId 的映射清了，就必须连 journalEntries_ 一起清。
      // 否则那些条目再也没有 taskId 能对上，removeJournalForTask_ 永远找不到它们，
      // 变成"永远删不掉"的残条，只能等下次冷启动的 drainStaleJournal_ 收尾。
      DownloadManager._instance.journalEntries_.clear();
      DownloadManager._instance.caBundleInitialized_ = false;
    }
  }

  static instance(): DownloadManager {
    if (!DownloadManager._instance) {
      DownloadManager._instance = new DownloadManager();
    }
    return DownloadManager._instance;
  }

  /**
   * 抽 rawfile/cacert.pem 到 filesDir/cacert.pem，并调用 NAPI 设置全局
   * CA path。幂等：只在首次调用时真正做文件抽取。
   *
   * 必须在任何下载任务发起之前调一次。建议：
   *   - EntryAbility.onWindowStageCreate 里
   *   - 或 DevToolsPage.runDownloadSmokeTest 开头（兜底）
   *
   * 原因：OHOS 没有标准 /etc/ssl/certs/ 根证书路径，libcurl 默认 CA 查找
   * 全部落空 → HTTPS 握手失败，报 "self-signed certificate in certificate
   * chain"（OpenSSL 在空信任库下对正常链的误导性错误）。
   */
  initializeCaBundle(context: common.UIAbilityContext | common.Context): void {
    if (this.caBundleInitialized_) return;
    try {
      let caDest: string = context.filesDir + '/cacert.pem';
      // 总是覆盖写（文件小 ~220KB，保证 update HAP 后 CA bundle 跟随更新）
      let data: Uint8Array = context.resourceManager.getRawFileContentSync('cacert.pem');
      let f = fs.openSync(caDest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, data.buffer);
      } finally {
        fs.closeSync(f);
      }
      let stat = fs.statSync(caDest);
      AppLogger.info(TAG, `CA bundle extracted: ${caDest} (${stat.size} bytes)`);

      dlEngine().setCaBundle(caDest);
      this.journalPath_ = context.filesDir + '/download-tasks-v1.json';
      this.loadJournal_();
      this.caBundleInitialized_ = true;
    } catch (e) {
      AppLogger.error(TAG, 'initializeCaBundle FAILED', e as Object);
    }
  }

  isCaBundleInitialized(): boolean {
    return this.caBundleInitialized_;
  }

  private loadJournal_(): void {
    if (this.journalLoaded_ || this.journalPath_.length === 0) return;
    this.journalLoaded_ = true;
    try {
      let text = fs.readTextSync(this.journalPath_);
      if (text.length > 4 * 1024 * 1024) throw new Error('download journal exceeds 4 MiB');
      let document = JSON.parse(text) as DownloadJournalDocument;
      if (document.version !== 1 || document.entries.length > 256) {
        throw new Error('unsupported or oversized download journal');
      }
      for (let entry of document.entries) {
        // 兼容旧格式（v1 里 name/fileCount 曾嵌在 entry.spec 内）：字段缺失就整条丢弃。
        // 旧格式条目本身就是问题来源（体积 + 自动重放），没有保留价值。
        if (entry.journalId === undefined || entry.journalId.length === 0) continue;
        if (entry.name === undefined || entry.name.length === 0) continue;
        this.journalEntries_.set(entry.journalId, entry);
      }
    } catch (e) {
      try { fs.unlinkSync(this.journalPath_); } catch (cleanupError) { /* absent/corrupt */ }
      this.journalEntries_.clear();
    }
  }

  private persistJournal_(): void {
    if (this.journalPath_.length === 0) return;
    let entries: DownloadJournalEntry[] = [];
    this.journalEntries_.forEach((entry: DownloadJournalEntry): void => { entries.push(entry); });
    let document: DownloadJournalDocument = { version: 1, entries: entries };
    let payload = JSON.stringify(document);
    if (payload.length > 4 * 1024 * 1024) throw new Error('download journal exceeds 4 MiB');
    // 唯一 tmp：避免与崩溃残留的 .tmp 或并发写互踩固定文件名。
    let tempPath = this.journalPath_ + '.' + Date.now().toString() + '-'
      + (this.journalSequence_++).toString() + '.tmp';
    let file: fs.File | null = null;
    try {
      file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, payload);
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = null;
      fs.renameSync(tempPath, this.journalPath_);
      // rename 后 fsync 父目录，确保断电后目录项也已持久化到最新 journal。
      let slash = this.journalPath_.lastIndexOf('/');
      if (slash > 0) {
        let parentDir = this.journalPath_.substring(0, slash);
        let parent: fs.File | null = null;
        try {
          parent = fs.openSync(parentDir, fs.OpenMode.READ_ONLY);
          fs.fsyncSync(parent.fd);
        } catch (dirError) {
          /* 父目录 fsync 不被所有文件系统支持；journal 已 rename，忽略。 */
        } finally {
          if (parent) { try { fs.closeSync(parent); } catch (closeError) { /* */ } }
        }
      }
    } catch (e) {
      if (file) { try { fs.closeSync(file); } catch (closeError) { /* */ } }
      try { fs.unlinkSync(tempPath); } catch (cleanupError) { /* */ }
      throw e as Error;
    }
  }

  /**
   * 登记一条 journal 摘要。
   *
   * ⚠️ 2026-08-04：**绝不 rethrow**。原实现会把 persist 失败抛回
   * `createRegisterStart_`，而调用点在事务 `try` 之外 —— journal 写盘失败就等于
   * 「所有下载入口在发出第一个字节前直接失败」。journal 只是诊断辅助，它坏了
   * 顶多影响日志可读性，绝不能成为下载的前置条件。
   */
  private addJournalEntry_(spec: DownloadTaskSpec): string {
    let journalId = Date.now().toString() + '-' + (this.journalSequence_++).toString();
    let entry: DownloadJournalEntry = {
      journalId: journalId,
      createdAt: Date.now(),
      name: spec.name,
      fileCount: spec.files.length,
    };
    this.journalEntries_.set(journalId, entry);
    try {
      this.persistJournal_();
    } catch (e) {
      this.journalEntries_.delete(journalId);
      AppLogger.warn(TAG, 'download journal persist failed (download continues)', e as Object);
    }
    return journalId;
  }

  private removeJournalForTask_(taskId: number): void {
    let journalId = this.taskJournalIds_.get(taskId);
    if (journalId === undefined) return;
    this.taskJournalIds_.delete(taskId);
    this.journalEntries_.delete(journalId);
    try { this.persistJournal_(); }
    catch (e) { AppLogger.warn(TAG, 'download journal removal failed', e as Object); }
  }

  /**
   * 把 progress / complete 回调注册到 native 任务上。native 侧是**覆盖**语义
   * （setOnProgressChanged / setOnComplete），因此既用于首次 create，也用于
   * refreshFromNative 在 Ability 重建后把事件重新接回 UI。
   *
   * 两个回调里的 generation + executionEpoch + finished 三重门是必须的：
   * 防止上一代 registration 的迟到事件把当前 view 的终态拉回 Loading。
   */
  private registerCallbacks_(
    engine: DownloadNativeEngine,
    taskId: number,
    view: DownloadTaskView,
    generation: number,
    onProgress?: DownloadListener,
    onComplete?: InternalCompleteListener,
  ): boolean {
    let progressRegistered = engine.onProgress(taskId, (ev: DownloadProgressEvent): void => {
      if (ev.taskId !== taskId || !this.isCurrentGeneration_(taskId, generation, view) ||
          ev.executionEpoch <= 0 || !this.acceptExecutionEpoch_(view, ev.executionEpoch)) return;
      // 同 epoch 的 complete 已收敛后，迟到的 progress 不得把终态重新拉回 Loading。
      if (view.finished) return;
      this.applyProgress_(view, ev);
      this.notifyAll(view);
      if (onProgress) {
        try { onProgress(view); } catch (e) {
          AppLogger.error(TAG, `onProgress threw: ${formatError(e)}`);
        }
      }
    });
    if (!progressRegistered) return false;

    let completeRegistered = engine.onComplete(taskId, (ev: DownloadCompleteEvent): void => {
      if (ev.taskId !== taskId || !this.isCurrentGeneration_(taskId, generation, view) ||
          ev.executionEpoch <= 0 || !this.acceptExecutionEpoch_(view, ev.executionEpoch)) return;
      // 同一 registration + execution epoch 的重复 complete 只能收敛一次。
      if (view.finished) return;
      this.applyComplete_(view, ev);
      this.notifyAll(view);
      if (onProgress) {
        try { onProgress(view); } catch (e) { /* UI 回调不影响终态 */ }
      }
      if (onComplete) onComplete(view, ev);
      // 活动账本：任务进终态 → 解绑 task→activity 关联，避免 native 那张 32 槽的表
      // 只增不减。一次 MC 版本下载会创建 3+ 个 native 任务（client.jar / libraries /
      // assets），只绑不解十来次下载就填满，之后新关联被静默丢弃、DL_MULTI 日志再也
      // 归属不上。（2026-08-01 自审发现的缺陷 2）
      //
      // 放在这里而不是各处 delete()：这是所有终态（成功/失败/取消）的统一收口。
      try { engine.unbindActivity(taskId); } catch (e) { /* 解绑失败只影响后续账本 */ }
    });
    return completeRegistered;
  }

  /**
   * 冷启动时收尾上一次进程留下的 journal 条目。
   *
   * ⚠️ 2026-08-04 重写：**不再自动重建/自动启动任何任务**。
   *
   * 原实现（d80ef35 / 2026-07-16）会在 native 注册表为空时把每条 journal 条目
   * 用 `onProgress/onComplete=undefined` 重新 createRegisterStart_ 起来。这套"自动恢复"
   * 是一连串故障的总开关，真机日志（_devicelog/20260804）完整复现：
   *
   *   1. 它绕过 DownloadTaskRegistry：不受并发上限约束、不出现在任务面板、用户无法取消。
   *   2. 它占住 `spec.name` 与 native 的全部 localPath 所有权，于是用户自己点下载会被
   *      `isTaskActiveByName` 或 native 的 `final path is already owned by task N` 顶掉，
   *      表现为「点一下就报错 / 重试永远 0%」。
   *   3. 最致命的一条：被复活的 `assets 30 (4750 files)` 一上来就对 4750 个文件调
   *      `NetFile::start()`，把进程 fd 水位推过 FD_SETSIZE(1024)。随包 libcurl 未启用
   *      poll（Curl_poll 走 select 分支），fd>=1024 直接让**整个 libcurl 永久瘫痪**：
   *      所有传输 + 所有元数据请求（版本清单 / version.json / 源探测）全部秒失败且不
   *      自愈。用户视角就是「什么都下不了、点多少次重试都一样、必须杀进程」。
   *      详见 entry/src/main/cpp/download/net_file.cpp 顶部的 fd 治理注释。
   *   4. 用户从未确认过要恢复这些下载。
   *
   * 断点续传**不需要**它：续传载体是 native 的 `.download-meta` + `.amcl.part`，
   * 用户重新点下载时 `NetFile::start()` 自己会 restoreFromMeta 接着下，一个字节都不浪费。
   * 所以这里只做一件事：清干净残留条目，并把清掉了什么记进日志。
   */
  private drainStaleJournal_(): void {
    if (this.journalEntries_.size === 0) return;
    let dropped: string[] = [];
    this.journalEntries_.forEach((entry: DownloadJournalEntry): void => {
      dropped.push(entry.name + ' (' + entry.fileCount + ' files)');
    });
    this.journalEntries_.clear();
    this.taskJournalIds_.clear();
    try { this.persistJournal_(); }
    catch (e) { AppLogger.warn(TAG, 'download journal cleanup persist failed', e as Object); }
    AppLogger.info(TAG,
      'download journal: dropped ' + dropped.length + ' stale entry(ies) from a previous run '
      + 'without auto-restarting them (resume happens via .download-meta when the user retries): '
      + dropped.join(', '));
  }

  /**
   * Phase 3 (S2-2): 元数据走 NAPI 引擎。同步拉一个 URL 到字符串。
   *
   * 多镜像 fallback：mirrors[0] 失败 → 自动尝试 mirrors[1]，依次类推。
   * 与 NetThread 共享同一套 curl 配置（CA bundle / UA / 超时 / follow redirect /
   * gzip 解压 / 坏主机黑名单）— 但**不**走 task 队列，不写磁盘，不分段，不 sha1。
   *
   * 适用场景：
   *   - version_manifest_v2.json
   *   - asset_index.json
   *   - Forge file_list.json / installer 元信息
   *   - Maven metadata.xml（小，纯文本）
   *
   * @param primaryUrl 首选 URL
   * @param mirrors 次源 URL 列表（默认空）
   * @param timeoutSeconds 单次尝试总超时（默认 30 秒）
   * @returns Promise — 成功 resolve body 字符串，失败 reject Error（含 errorKind + message）
   *
   * @throws Error('CA bundle not initialized') 如果 EntryAbility 没初始化 CA
   */
  async fetchText(
    primaryUrl: string,
    mirrors?: string[],
    timeoutSeconds?: number,
    maxResponseBytes?: number,
  ): Promise<string> {
    if (!this.caBundleInitialized_) {
      throw new Error('CA bundle not initialized — call initializeCaBundle(context) first');
    }
    let mirrorList: string[] = mirrors !== undefined ? mirrors : [];
    let timeout: number = timeoutSeconds !== undefined ? timeoutSeconds : 30;
    let responseLimit: number = maxResponseBytes !== undefined ? maxResponseBytes : DEFAULT_FETCH_RESPONSE_LIMIT_BYTES;

    let result = await dlEngine().fetchText(primaryUrl, mirrorList, timeout, undefined, responseLimit);
    if (result.ok && result.body !== undefined) {
      if (result.body.length > responseLimit) {
        throw new Error('[ResponseTooLarge] fetchText response exceeded maxResponseBytes');
      }
      return result.body;
    }
    let kind: string = result.errorKind !== undefined ? result.errorKind : 'Unknown';
    let msg: string = result.errorMessage !== undefined ? result.errorMessage : 'fetchText failed';
    throw new Error('[' + kind + '] ' + msg + ' (urls: ' + (1 + mirrorList.length) + ')');
  }

  /**
   * Phase 2.3 (P2-2): fetchText 的扩展版，返回完整响应（status / headers / body）。
   *
   * 比 `fetchText` 多两个能力：
   *   - 接受 `requestHeaders`（如 If-None-Match / If-Modified-Since），用于条件请求
   *   - 返回 `statusCode` + `headers`，让调用方做 304 短路判定 + 提取 ETag/Last-Modified
   *
   * 200-299 / 304 都视为成功（`ok=true`），调用方按 `statusCode` 区分；其他 HTTP 失败 reject。
   *
   * @returns FetchTextRichResult — 含 statusCode / headers (lowercase keys) / body
   */
  async fetchTextEx(
    primaryUrl: string,
    mirrors?: string[],
    timeoutSeconds?: number,
    requestHeaders?: Record<string, string>,
    maxResponseBytes?: number,
  ): Promise<FetchTextRichResult> {
    if (!this.caBundleInitialized_) {
      throw new Error('CA bundle not initialized — call initializeCaBundle(context) first');
    }
    let mirrorList: string[] = mirrors !== undefined ? mirrors : [];
    let timeout: number = timeoutSeconds !== undefined ? timeoutSeconds : 30;
    let responseLimit: number = maxResponseBytes !== undefined ? maxResponseBytes : DEFAULT_FETCH_RESPONSE_LIMIT_BYTES;

    let result = await dlEngine().fetchText(primaryUrl, mirrorList, timeout, requestHeaders, responseLimit);
    if (result.ok) {
      let body: string = result.body !== undefined ? result.body : '';
      if (body.length > responseLimit) {
        throw new Error('[ResponseTooLarge] fetchTextEx response exceeded maxResponseBytes');
      }
      let rich: FetchTextRichResult = {
        statusCode: result.statusCode !== undefined ? result.statusCode : 0,
        body: body,
        headers: result.headers !== undefined ? result.headers : {} as Record<string, string>,
      };
      return rich;
    }
    let kind: string = result.errorKind !== undefined ? result.errorKind : 'Unknown';
    let msg: string = result.errorMessage !== undefined ? result.errorMessage : 'fetchTextEx failed';
    throw new Error('[' + kind + '] ' + msg + ' (urls: ' + (1 + mirrorList.length) + ')');
  }

  /** 获取所有任务的快照（新数组，调用方可安全迭代） */
  getTasks(): DownloadTaskView[] {
    let arr: DownloadTaskView[] = [];
    this.tasks_.forEach((view: DownloadTaskView) => arr.push(view));
    return arr;
  }

  /** 获取单个任务（可能为 null） */
  getTask(taskId: number): DownloadTaskView | null {
    let v = this.tasks_.get(taskId);
    return v ? v : null;
  }

  /** 获取活跃任务数（非 Finished / Failed / Aborted） */
  getActiveCount(): number {
    let n = 0;
    this.tasks_.forEach((v: DownloadTaskView) => {
      // 对齐 native loadStateToString 的枚举（LoadState::Waiting/Loading/Finished/Failed/Aborted）
      // 只有 Waiting / Loading 算活跃；finished 无论成功失败都不算
      if (v.state === 'Loading' || v.state === 'Waiting') n++;
    });
    return n;
  }

  /** 注册监听器（不去重，调用方自己保证不重复） */
  addListener(l: DownloadListener): void {
    this.listeners_.push(l);
  }

  removeListener(l: DownloadListener): void {
    let idx = this.listeners_.indexOf(l);
    if (idx >= 0) this.listeners_.splice(idx, 1);
  }

  private notifyAll(view: DownloadTaskView): void {
    for (let l of this.listeners_) {
      try {
        l(view);
      } catch (e) {
        AppLogger.error(TAG, `listener error: ${formatError(e)}`);
      }
    }
  }

  private isCurrentGeneration_(taskId: number, generation: number, view: DownloadTaskView): boolean {
    return this.taskGenerations_.get(taskId) === generation && this.tasks_.get(taskId) === view;
  }

  /**
   * 接受不小于当前 view 的 native execution epoch。epoch 前进时同步清空上一轮终态，
   * 防止 resume/retry 的首个回调早于命令后的 query 而继承旧 success/error。
   */
  private acceptExecutionEpoch_(view: DownloadTaskView, executionEpoch: number): boolean {
    if (executionEpoch < 0 || executionEpoch !== Math.floor(executionEpoch) ||
        executionEpoch < view.executionEpoch) {
      return false;
    }
    if (executionEpoch > view.executionEpoch) {
      view.executionEpoch = executionEpoch;
      view.finished = false;
      view.success = false;
      view.aborted = false;
      view.finishedAt = 0;
      view.durationMs = 0;
      view.errorKind = '';
      view.errorMessage = '';
      view.triedUrls = [];
      view.failedFiles = [];
    }
    return true;
  }

  private applyProgress_(view: DownloadTaskView, ev: DownloadProgressEvent): void {
    view.state = 'Loading';
    view.finished = false;
    view.progress = ev.overallProgress;
    view.speedBps = ev.speedBps;
    view.activeThreads = ev.activeThreads;
    view.currentFile = ev.currentFile;
    view.filesDone = ev.filesDone;
    view.filesTotal = ev.filesTotal;
    view.bytesDone = ev.bytesDone;
    view.bytesTotal = ev.bytesTotal;
    view.etaSeconds = ev.etaSeconds;
    view.currentFiles = ev.currentFiles || [];
  }

  private scheduleSuccessfulPurge_(taskId: number, view: DownloadTaskView): void {
    setTimeout((): void => {
      // taskId 可能被 native 重用；只有当前 Map 仍指向同一 view 时才允许 purge。
      if (this.tasks_.get(taskId) !== view || !view.success) return;
      try {
        this.purgeTask(taskId);
      } catch (e) {
        AppLogger.warn(TAG, `successful task auto-purge failed; retained for retry: id=${taskId}`, e as Object);
      }
    }, 0);
  }

  private applyComplete_(view: DownloadTaskView, ev: DownloadCompleteEvent): void {
    view.finished = true;
    view.success = ev.success;
    view.aborted = ev.aborted;
    view.state = ev.aborted ? 'Aborted' : (ev.success ? 'Finished' : 'Failed');
    view.finishedAt = Date.now();
    view.durationMs = ev.durationMs;
    view.activeThreads = 0;

    let fp = ev.finalProgress;
    if (fp) {
      view.progress = fp.overallProgress;
      view.speedBps = fp.speedBps;
      view.currentFile = fp.currentFile;
      view.filesDone = fp.filesDone;
      view.filesTotal = fp.filesTotal;
      view.bytesDone = fp.bytesDone;
      view.bytesTotal = fp.bytesTotal;
      view.etaSeconds = fp.etaSeconds;
      view.currentFiles = fp.currentFiles || [];
    }
    // 终态先清空上一次失败信息，再按本次事件回填，避免 retry/resume 成功后残留旧错误。
    view.errorKind = '';
    view.errorMessage = '';
    view.triedUrls = [];
    view.failedFiles = ev.failedFiles || [];
    if (ev.error) {
      view.errorKind = ev.error.kind;
      view.errorMessage = `${ev.error.kind}${ev.error.httpStatus ? ` http=${ev.error.httpStatus}` : ''}: ${ev.error.message}`;
      view.triedUrls = ev.error.triedUrls || [];
    }
    // 成功终态必须规范成 100%，且只有成功允许自动 purge；失败/取消保留供 resume/retry。
    if (ev.success) {
      view.progress = 1;
      view.filesDone = view.filesTotal;
      view.etaSeconds = 0;
      this.removeJournalForTask_(ev.taskId);
      this.scheduleSuccessfulPurge_(ev.taskId, view);
    } else {
      // ⚠️ 2026-08-04：**所有**终态都清 journal，不再区分落点类型。
      //   原实现只在成功时清（以及一次性 staging 的失败），于是失败/取消的条目会永久
      //   留在盘上，条目数与体积单调增长，直到撞上 4 MiB 上限把所有下载入口打死。
      //   journal 现在只是诊断辅助（摘要），保留失败条目没有任何价值 —— 续传靠的是
      //   native 的 .download-meta + .amcl.part，与 journal 无关。
      this.removeJournalForTask_(ev.taskId);
    }
  }

  private completeEventFromSnapshot_(info: NativeTaskInfo): DownloadCompleteEvent {
    let overallProgress: number = info.overallProgress !== undefined ? info.overallProgress : info.progress;
    let finalProgress: DownloadFinalProgress = {
      overallProgress: overallProgress,
      speedBps: info.speedBps !== undefined ? info.speedBps : 0,
      currentFile: info.currentFile !== undefined ? info.currentFile : '',
      filesDone: info.filesDone,
      filesTotal: info.filesTotal,
      bytesDone: info.bytesDone !== undefined ? info.bytesDone : 0,
      bytesTotal: info.bytesTotal !== undefined ? info.bytesTotal : -1,
      etaSeconds: info.etaSeconds !== undefined ? info.etaSeconds : -1,
      currentFiles: info.currentFiles !== undefined ? info.currentFiles : [],
    };
    let event: DownloadCompleteEvent = {
      taskId: info.taskId,
      executionEpoch: info.executionEpoch,
      success: info.state === 'Finished',
      aborted: info.state === 'Aborted',
      durationMs: info.durationMs !== undefined ? info.durationMs : 0,
      failedFiles: info.failedFiles !== undefined ? info.failedFiles : [],
      finalProgress: finalProgress,
    };
    if (info.error !== undefined) {
      event.error = info.error;
    } else if (info.errorKind !== undefined || info.errorMessage !== undefined) {
      let fallbackError: DownloadError = {
        kind: info.errorKind !== undefined ? info.errorKind : 'Unknown',
        message: info.errorMessage !== undefined ? info.errorMessage : 'download failed',
        nativeCode: 0,
        httpStatus: 0,
        url: '',
        triedUrls: [],
      };
      event.error = fallbackError;
    }
    return event;
  }

  private scheduleTerminalQuery_(
    engine: DownloadNativeEngine,
    taskId: number,
    generation: number,
    view: DownloadTaskView,
    onProgress?: DownloadListener,
    onComplete?: InternalCompleteListener,
  ): void {
    setTimeout((): void => {
      if (view.finished || !this.isCurrentGeneration_(taskId, generation, view)) return;
      let snapshot: NativeTaskInfo | null = null;
      try {
        snapshot = engine.queryTask(taskId);
      } catch (e) {
        AppLogger.warn(TAG, `terminal query failed; retrying: id=${taskId}`, e as Object);
        this.scheduleTerminalQuery_(engine, taskId, generation, view, onProgress, onComplete);
        return;
      }

      if (snapshot === null) {
        let missing: NativeTaskInfo = {
          taskId: taskId,
          executionEpoch: view.executionEpoch,
          name: view.name,
          state: 'Failed',
          progress: view.progress,
          filesDone: view.filesDone,
          filesTotal: view.filesTotal,
          errorKind: 'TaskMissing',
          errorMessage: 'native task disappeared before a terminal callback was observed',
        };
        let missingEvent: DownloadCompleteEvent = this.completeEventFromSnapshot_(missing);
        this.applyComplete_(view, missingEvent);
        this.notifyAll(view);
        if (onProgress) onProgress(view);
        if (onComplete) onComplete(view, missingEvent);
        return;
      }

      if (!this.acceptExecutionEpoch_(view, snapshot.executionEpoch)) {
        this.scheduleTerminalQuery_(engine, taskId, generation, view, onProgress, onComplete);
        return;
      }

      let terminal: boolean = snapshot.terminal === true || snapshot.state === 'Finished' ||
        snapshot.state === 'Failed' || snapshot.state === 'Aborted';
      if (terminal) {
        let event: DownloadCompleteEvent = this.completeEventFromSnapshot_(snapshot);
        this.applyComplete_(view, event);
        this.notifyAll(view);
        if (onProgress) {
          try { onProgress(view); } catch (e) { /* UI callback 不影响终态 */ }
        }
        if (onComplete) onComplete(view, event);
        return;
      }
      this.scheduleTerminalQuery_(engine, taskId, generation, view, onProgress, onComplete);
    }, TERMINAL_QUERY_INTERVAL_MS);
  }

  private retryRollbackPurge_(engine: DownloadNativeEngine, taskId: number, attempt: number): void {
    try {
      if (engine.purgeTask(taskId) || engine.queryTask(taskId) === null) return;
    } catch (e) {
      AppLogger.warn(TAG, `transaction rollback purge attempt failed: id=${taskId}`, e as Object);
    }
    if (attempt >= ROLLBACK_PURGE_MAX_ATTEMPTS) {
      AppLogger.error(TAG, `transaction rollback timed out: native task retained id=${taskId}`);
      return;
    }
    setTimeout((): void => {
      this.retryRollbackPurge_(engine, taskId, attempt + 1);
    }, ROLLBACK_PURGE_INTERVAL_MS);
  }

  private rollbackCreatedTask_(engine: DownloadNativeEngine, taskId: number, startCommitted: boolean): void {
    try { engine.cancel(taskId); } catch (e) { /* best effort before convergence */ }
    if (!startCommitted) {
      // Engine 当前只允许 purge 终态任务；让已置 abort flag 的 Waiting task 进入
      // start 收敛路径，再次 cancel，随后异步等待终态并 purge。
      try { engine.start(taskId); } catch (e) { /* retryRollbackPurge_ 会记录残留 */ }
      try { engine.cancel(taskId); } catch (e) { /* ignore */ }
    }
    this.retryRollbackPurge_(engine, taskId, 0);
  }

  /**
   * 唯一的 create → register(progress+complete) → start 事务。
   * 任一步失败都会先让本 generation 失效，再 native purge，最后删除本地快照。
   */
  private createRegisterStart_(
    spec: DownloadTaskSpec,
    onProgress?: DownloadListener,
    onComplete?: InternalCompleteListener,
  ): TaskRegistration {
    if (!this.caBundleInitialized_) {
      throw new Error(
        'CA bundle not initialized — call DownloadManager.instance().initializeCaBundle(context) ' +
        'before any HTTPS download (normally done in EntryAbility.onCreate).');
    }
    if (this.isTaskActiveByName(spec.name)) {
      throw new Error(`任务 "${spec.name}" 已在下载中，请等待其完成或取消后再试`);
    }

    let engine = dlEngine();
    let taskId = 0;
    let generation = 0;
    let startCommitted = false;
    let view: DownloadTaskView | null = null;
    let journalId = this.addJournalEntry_(spec);
    try {
      taskId = engine.createTask(spec);
      if (taskId <= 0) {
        throw new Error(`downloadCreateTask returned invalid id: ${taskId}`);
      }
      // 活动账本（L2-b）：拿到 native task_id 后立刻建立关联，必须早于 start —— 
      // 引擎一开跑就会写 DL_MULTI 日志，关联晚了那些行就归属不上。
      if (spec.activityId !== undefined && spec.activityId > 0) {
        try { engine.bindActivity(taskId, spec.activityId); } catch (e) { /* 关联失败只影响账本 */ }
      }

      view = new DownloadTaskView();
      view.taskId = taskId;
      view.name = spec.name;
      view.state = 'Waiting';
      view.filesTotal = spec.files.length;
      generation = this.nextGeneration_++;
      this.taskGenerations_.set(taskId, generation);
      this.tasks_.set(taskId, view);
      this.taskJournalIds_.set(taskId, journalId);

      if (!this.registerCallbacks_(engine, taskId, view, generation, onProgress, onComplete)) {
        throw new Error('downloadOnProgress/downloadOnComplete registration failed');
      }

      if (!engine.start(taskId)) throw new Error('downloadStart returned false');
      startCommitted = true;
      let startedSnapshot = engine.queryTask(taskId);
      if (startedSnapshot !== null) {
        this.acceptExecutionEpoch_(view, startedSnapshot.executionEpoch);
      }
      this.scheduleTerminalQuery_(engine, taskId, generation, view, onProgress, onComplete);
      AppLogger.info(TAG, `create-register-start committed: id=${taskId} name=${spec.name} files=${spec.files.length}`);

      // 事务提交后再暴露首帧，调用方可立即获得 taskId 并安全 cancel。
      if (onProgress) {
        try { onProgress(view); } catch (e) { /* ignore */ }
      }
      let registration: TaskRegistration = { taskId: taskId, view: view, generation: generation };
      return registration;
    } catch (e) {
      if (taskId > 0) {
        this.taskJournalIds_.delete(taskId);
        if (this.taskGenerations_.get(taskId) === generation) this.taskGenerations_.delete(taskId);
        if (view === null || this.tasks_.get(taskId) === view) this.tasks_.delete(taskId);
        this.rollbackCreatedTask_(engine, taskId, startCommitted);
      }
      // 事务失败 → 回滚本次登记的 journal 摘要，别让永远不会跑的条目堆在盘上。
      this.journalEntries_.delete(journalId);
      try { this.persistJournal_(); }
      catch (persistError) { AppLogger.warn(TAG, 'journal rollback persist failed', persistError as Object); }
      throw new Error(`download create/register/start failed: ${formatError(e)}`);
    }
  }

  /** 创建任务并立即启动；与 createAndWait 共用严格事务。 */
  createAndStart(spec: DownloadTaskSpec): number {
    let registration = this.createRegisterStart_(spec, undefined,
      (view: DownloadTaskView, ev: DownloadCompleteEvent): void => {
        let summary = `task ${view.taskId} (${spec.name}) done: success=${ev.success} `
          + `files=${view.filesDone}/${view.filesTotal} bytes=${view.bytesDone}/${view.bytesTotal}`;
        if (ev.success || ev.aborted) AppLogger.info(TAG, summary);
        else AppLogger.error(TAG, summary + ' ' + (view.errorMessage || '(no error detail)'));
      });
    return registration.taskId;
  }

  /**
   * 创建任务 + 启动 + 等待终态，返回 Promise。Stage 3b 的 McDownloader 核心 API：
   * 调用方 `await mgr.createAndWait(spec, onProgress)` 就能像同步一样拿到结果。
   *
   *   - 终态 Finished → resolve(view)
   *   - 终态 Failed/Aborted → reject(Error)（Error.message 里带 kind/http/message）
   *   - onProgress（可选）：每次 progress tick + 终态前的最后一帧都会被调
   *
   * 注意：onProgress 是 **view 级** 回调，不走 DownloadManager.listeners_ 扇出，
   * 从而避免「多个 wait 互相干扰」的诡异问题。
   */
  createAndWait(spec: DownloadTaskSpec, onProgress?: DownloadListener): Promise<DownloadTaskView> {
    return new Promise<DownloadTaskView>((resolve, reject): void => {
      try {
        // 2026-08-04：这里原本还有一层 adoptOrphanTask_（接管 journal 自动复活出来的
        // 无主任务）。journal 自动恢复已整体移除（见 drainStaleJournal_），无主任务不
        // 再存在，那层接管逻辑连同它的路径集合比对一起删掉了 —— 少一个只在特定时序下
        // 才会被踩到的状态机分支。
        this.createRegisterStart_(spec, onProgress,
          (view: DownloadTaskView, ev: DownloadCompleteEvent): void => {
            let taskId = view.taskId;
            let summary = `createAndWait done: id=${taskId} (${spec.name}) success=${ev.success} aborted=${ev.aborted} `
              + `files=${view.filesDone}/${view.filesTotal} bytes=${view.bytesDone}/${view.bytesTotal} dur=${view.durationMs}ms`;
            if (ev.success) {
              AppLogger.info(TAG, summary);
              resolve(view);
            } else if (ev.aborted) {
              AppLogger.info(TAG, summary + ' [user cancelled; retained for resume/delete]');
              reject(new Error('已取消'));
            } else {
              AppLogger.error(TAG, summary + ' ' + (view.errorMessage || '(no error detail)'));
              AppLogger.flush();
              reject(new Error(view.errorMessage || 'download failed (no error detail)'));
            }
          });
      } catch (e) {
        reject(e as Error);
      }
    });
  }

  /** 取消任务；保留 meta 下次可续传 */
  cancel(taskId: number): boolean {
    return dlEngine().cancel(taskId);
  }

  // ============================================================================
  // v5: 扩展 API
  // ============================================================================

  /**
   * v5: 暂停任务（语义=cancel，保留 meta 供 resume 续传）。
   * 和 cancel 的区别仅在语义：cancel 后调用方通常会 deleteTaskFiles，
   * pause 后通常会 resume（UI 展示"已暂停"按钮）。
   */
  pause(taskId: number): boolean {
    return dlEngine().pause(taskId);
  }

  /**
   * v5: 恢复 Aborted / Failed 的任务。
   * 引擎会对非 Finished 文件做 resetForRetry + 重新 start()，断点续传自动生效。
   */
  resume(taskId: number): boolean {
    let engine = dlEngine();
    let ok = engine.resume(taskId);
    let view = this.tasks_.get(taskId);
    if (ok && view) {
      let snapshot = engine.queryTask(taskId);
      if (snapshot !== null) {
        this.acceptExecutionEpoch_(view, snapshot.executionEpoch);
      }
      view.finished = false;
      view.success = false;
      view.aborted = false;
      view.state = 'Waiting';
      view.errorKind = '';
      view.errorMessage = '';
      view.triedUrls = [];
      view.failedFiles = [];
      let generation = this.taskGenerations_.get(taskId);
      if (generation !== undefined) {
        this.scheduleTerminalQuery_(engine, taskId, generation, view);
      }
    }
    return ok;
  }

  /**
   * v5: 清理任务磁盘残留（local + .download-meta）。
   * 返回释放的字节数。仅 Aborted / Failed 状态允许。
   */
  deleteTaskFiles(taskId: number): number {
    return dlEngine().deleteTaskFiles(taskId);
  }

  /**
   * v5: 只重试指定路径的失败文件；空数组=重试所有 Failed 文件。
   * 任务必须处于 Failed / Aborted 状态。
   */
  retryFailed(taskId: number, localPaths: string[]): boolean {
    let engine = dlEngine();
    let ok = engine.retryFailed(taskId, localPaths || []);
    let view = this.tasks_.get(taskId);
    if (ok && view) {
      let snapshot = engine.queryTask(taskId);
      if (snapshot !== null) {
        this.acceptExecutionEpoch_(view, snapshot.executionEpoch);
      }
      view.finished = false;
      view.success = false;
      view.aborted = false;
      view.state = 'Waiting';
      view.errorKind = '';
      view.errorMessage = '';
      view.triedUrls = [];
      view.failedFiles = [];
      let generation = this.taskGenerations_.get(taskId);
      if (generation !== undefined) {
        this.scheduleTerminalQuery_(engine, taskId, generation, view);
      }
    }
    return ok;
  }

  /**
   * v5: 从 native 注册表移除单个终态任务（Finished / Failed / Aborted 才允许）。
   * 用于用户放弃任务、或已清完磁盘后释放引擎侧的 LoaderDownload 记录。
   * 同时会清掉本地 tasks_ 视图 —— 调用方需确保 UI 里不再持有该 taskId。
   */
  purgeTask(taskId: number): boolean {
    // purge 是 owner 释放协议，必须幂等：成功任务可能已被自动 purge；native 已不存在
    // 等价于 owner 已释放。真正仍存在但 execution 未收敛时继续返回 false。
    let engine = dlEngine();
    let ok = engine.purgeTask(taskId);
    if (!ok) {
      try { ok = engine.queryTask(taskId) === null; } catch (e) { ok = false; }
    }
    if (ok) {
      this.removeJournalForTask_(taskId);
      this.taskGenerations_.delete(taskId);
      this.tasks_.delete(taskId);
    }
    return ok;
  }

  /**
   * P1-MODS §3.3: 按名称前缀（category）筛选活跃任务。
   * UI 分组用：传 'mod:' 只拿模组任务，传 'MC ' 只拿 MC 任务。
   * 空前缀返回所有活跃任务。
   */
  getActiveTasksByCategory(category: string): DownloadTaskView[] {
    let arr: DownloadTaskView[] = [];
    this.tasks_.forEach((v: DownloadTaskView) => {
      if (v.finished) return;
      if (category.length === 0 || v.name.startsWith(category)) {
        arr.push(v);
      }
    });
    return arr;
  }

  /**
   * v5: 是否已有同名活跃任务（防止重复启动）。
   * 用于 UI 发起下载前快速自检。
   */
  isTaskActiveByName(name: string): boolean {
    let active = false;
    this.tasks_.forEach((v: DownloadTaskView) => {
      if (v.name === name && !v.finished) active = true;
    });
    return active;
  }

  /** 清理终态任务；只有 native owner purge 成功后才删除本地 snapshot。 */
  purgeFinished(): number {
    let removed = 0;
    let terminalIds: number[] = [];
    this.tasks_.forEach((v: DownloadTaskView, taskId: number): void => {
      if (v.state === 'Finished' || v.state === 'Failed' || v.state === 'Aborted') {
        terminalIds.push(taskId);
      }
    });
    for (let taskId of terminalIds) {
      try {
        if (this.purgeTask(taskId)) removed++;
      } catch (e) {
        AppLogger.warn(TAG, `purgeFinished retained task after native purge error: id=${taskId}`, e as Object);
      }
    }
    return removed;
  }

  /** 从 native 做完整 reconcile：覆盖 listActive 可提供的全部字段，并删除 native 已不存在的 stale view。 */
  refreshFromNative(): void {
    let engine = dlEngine();
    let nativeTasks: NativeTaskInfo[] = engine.listActive();
    let nativeIds: Map<number, boolean> = new Map();

    for (let info of nativeTasks) {
      nativeIds.set(info.taskId, true);
      if (!this.taskJournalIds_.has(info.taskId)) {
        let matchedJournalId = '';
        this.journalEntries_.forEach((entry: DownloadJournalEntry, journalId: string): void => {
          if (matchedJournalId.length === 0 && entry.name === info.name) matchedJournalId = journalId;
        });
        if (matchedJournalId.length > 0) this.taskJournalIds_.set(info.taskId, matchedJournalId);
      }
      let existing = this.tasks_.get(info.taskId);
      let isNew = existing === undefined;
      let view: DownloadTaskView;
      if (existing === undefined) {
        view = new DownloadTaskView();
        view.taskId = info.taskId;
        this.tasks_.set(info.taskId, view);
      } else {
        view = existing;
      }

      // list/query 是 authoritative snapshot；旧 epoch 只能被忽略，不能覆盖当前 view。
      if (!this.acceptExecutionEpoch_(view, info.executionEpoch)) continue;
      view.name = info.name;
      let terminal: boolean = info.terminal === true || info.state === 'Finished' ||
        info.state === 'Failed' || info.state === 'Aborted';
      if (terminal) {
        this.taskGenerations_.delete(info.taskId);
        this.applyComplete_(view, this.completeEventFromSnapshot_(info));
      } else {
        view.state = info.state;
        view.finished = false;
        view.success = false;
        view.aborted = false;
        view.finishedAt = 0;
        view.progress = info.overallProgress !== undefined ? info.overallProgress : info.progress;
        view.speedBps = info.speedBps !== undefined ? info.speedBps : 0;
        view.activeThreads = info.activeThreads !== undefined ? info.activeThreads : 0;
        view.currentFile = info.currentFile !== undefined ? info.currentFile : '';
        view.filesDone = info.filesDone;
        view.filesTotal = info.filesTotal;
        view.bytesDone = info.bytesDone !== undefined ? info.bytesDone : 0;
        view.bytesTotal = info.bytesTotal !== undefined ? info.bytesTotal : -1;
        view.etaSeconds = info.etaSeconds !== undefined ? info.etaSeconds : -1;
        view.currentFiles = info.currentFiles !== undefined ? info.currentFiles : [];
        view.durationMs = info.durationMs !== undefined ? info.durationMs : 0;
        view.errorKind = '';
        view.errorMessage = '';
        view.triedUrls = [];
        view.failedFiles = [];
      }

      // 冷/热恢复或失去 generation 的活跃任务重新订阅；任一注册失败都让本 generation 失效。
      if ((isNew || !this.taskGenerations_.has(info.taskId)) && !terminal) {
        let generation = this.nextGeneration_++;
        this.taskGenerations_.set(info.taskId, generation);
        let recoveredView = view;
        let recoveredTaskId = info.taskId;
        let progressOk = engine.onProgress(recoveredTaskId, (ev: DownloadProgressEvent): void => {
          if (ev.taskId !== recoveredTaskId ||
              !this.isCurrentGeneration_(recoveredTaskId, generation, recoveredView) ||
              ev.executionEpoch <= 0 || !this.acceptExecutionEpoch_(recoveredView, ev.executionEpoch)) return;
          if (recoveredView.finished) return;
          this.applyProgress_(recoveredView, ev);
          this.notifyAll(recoveredView);
        });
        let completeOk = engine.onComplete(recoveredTaskId, (ev: DownloadCompleteEvent): void => {
          if (ev.taskId !== recoveredTaskId ||
              !this.isCurrentGeneration_(recoveredTaskId, generation, recoveredView) ||
              ev.executionEpoch <= 0 || !this.acceptExecutionEpoch_(recoveredView, ev.executionEpoch)) return;
          if (recoveredView.finished) return;
          this.applyComplete_(recoveredView, ev);
          this.notifyAll(recoveredView);
        });
        if (!progressOk || !completeOk) {
          AppLogger.warn(TAG, `refreshFromNative callback restore incomplete: id=${recoveredTaskId} progress=${progressOk} complete=${completeOk}; terminal query fallback enabled`);
        }
        // Query reconciliation is independent of bridge registration. This guarantees a
        // recovered task can still observe exactly one terminal snapshot when either TSFN
        // registration fails during env recreation.
        this.scheduleTerminalQuery_(engine, recoveredTaskId, generation, recoveredView);
      }
      this.notifyAll(view);
    }

    let staleIds: number[] = [];
    this.tasks_.forEach((view: DownloadTaskView, taskId: number): void => {
      if (!nativeIds.has(taskId)) staleIds.push(taskId);
    });
    for (let taskId of staleIds) {
      this.taskGenerations_.delete(taskId);
      this.tasks_.delete(taskId);
    }
    // native 注册表为空说明这是进程冷启动（或所有任务都已 purge）：把上一次运行留下的
    // journal 残条清掉即可，**不再自动重建任何下载**（原因见 drainStaleJournal_）。
    // 用户重新点下载时，native 会用磁盘上的 .download-meta / .amcl.part 自动续传。
    if (nativeTasks.length === 0) this.drainStaleJournal_();
  }

  // ============================================================================
  // Smoke Test（P1-3 Stage 2 端到端验证用）
  // ============================================================================

  /**
   * 下载一个已知的小 JSON 文件，端到端验证下载引擎在真机可跑。
   * 成功后文件位于 filesDir/download_smoke_test.json（可人工打开检查内容）。
   *
   * 使用的 URL：Mojang 官方 version manifest（不要 sha1 校验，文件内容在变）。
   * 约 50KB，秒下，验证链路 OK。
   */
  runSmokeTestSmall(filesDir: string): number {
    let localPath: string = filesDir + '/download_smoke_test.json';
    let file: DownloadFileSpec = {
      localPath: localPath,
      allowedRoot: filesDir,
      urls: ['https://launchermeta.mojang.com/mc/game/version_manifest_v2.json'],
    };
    let spec: DownloadTaskSpec = {
      name: 'Smoke: version_manifest_v2.json',
      files: [file],
    };
    return this.createAndStart(spec);
  }

  /**
   * 中等文件测试：下载 1.20.4 的 client.jar（约 25MB），含 sha1 校验。
   * 验证多线程分段 + Range 请求 + 断点机制 + sha1 校验完整通路。
   */
  runSmokeTestMedium(filesDir: string): number {
    let localPath: string = filesDir + '/download_smoke_1.20.4.jar';
    // Mojang 官方 1.20.4 client.jar 的下载地址 + sha1 + size
    // size 来自实际 curl HEAD 验证（从 version_manifest 里的 size 字段不是文件大小，
    // 而是元数据字段，不可信赖）
    let check: DownloadCheck = {
      sha1: 'fd19469fed4a4b4c15b2d5133985f0e3e7816a8a',
      size: 24445539,
    };
    let file: DownloadFileSpec = {
      localPath: localPath,
      allowedRoot: filesDir,
      urls: [
        'https://piston-data.mojang.com/v1/objects/fd19469fed4a4b4c15b2d5133985f0e3e7816a8a/client.jar',
        // BMCLAPI 备用源
        'https://bmclapi2.bangbang93.com/mc/game/1.20.4/client/fd19469fed4a4b4c15b2d5133985f0e3e7816a8a/client.jar',
      ],
      check: check,
    };
    let spec: DownloadTaskSpec = {
      name: 'Smoke: MC 1.20.4 client.jar (~25MB)',
      files: [file],
    };
    return this.createAndStart(spec);
  }
}

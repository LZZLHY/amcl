/**
 * ActivityLedger.ets — 通用活动账本（活动账本 · L1-c）
 *
 * 让每条活动（下载 / 模组安装 / 修复 / JDK / 整合包 / 一局游戏）都拥有一份**只属于
 * 它自己**的完整日志，而不是事后从全局日志里按时间窗去猜哪几行属于它。
 *
 * 为什么必须换掉时间窗切片（四个结构性缺陷，实测依据见设计文档 §1.2）：
 *   1. 并发混线 —— `maxConcurrent=3`，时间窗里必然掺着另外两个活动的行，而日志行
 *      本身没有归属标记，**原理上做不到**精确归属；
 *   2. `amclLogRead` 读不到轮转后的 `.1~.5.log`（已在 L1-b 修）；
 *   3. 尾读 256 KiB 只覆盖约 3.5 天，而活动记录保留 50 条能跨几个月；
 *   4. 过滤正则与时间戳格式强耦合（P1-8）。
 *
 * 本模块负责账本的**目录、清单与读取**；日志行的归属与分流由 native 在 writer 线程
 * 完成（见 `amcl_log.h` 的活动账本段）。两者的分工边界：
 *   native  ——「把行写进哪个文件」
 *   本模块  ——「有哪些活动、各自有哪些文件、怎么读、什么时候淘汰」
 *
 * 关联：docs/guides/activity-ledger.md
 * 创建日期：2026-07-30
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util, process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from './AppLogger';
import { LOG_DOMAIN } from '../common/Constants';
import { ensureDirSync, removeDirRecursive } from './FileUtils';
import { sanitizeLogForExport, LogExportTarget, exportLimitOf, utf8ByteLength,
  truncateUtf8HeadTail } from './LogExport';
import { allocateExportBudget, ExportPartDemand, ExportPartGrant } from './LogExportBudget';
import { DiagnosticBundle, DiagnosticEnv } from './DiagnosticBundle';
import { findSessionLog, readLogFileHead } from './GameLogPaths';
import { normalizeSessionRetention, SESSION_RETENTION_DEFAULT, RetentionCandidate, sessionRetentionVictims } from './SessionRetention';
import { refreshSessionEvidence, refreshSessionEvidenceAsync, readSessionEvidence } from './SessionEvidence';
import { isInternalEvidencePath } from './EvidenceTypes';
import { beginSessionCapture, beginSessionCaptureAsync, checkpointSessionCapture, checkpointSessionCaptureAsync, nativeSessionIo,
  nativeSessionIoAsync, readSessionCapture, readSessionCaptureAsync, CaptureSource, recordArchivedSessionSource } from './SessionCapture';
import { writeEvidenceTextAtomic, writeEvidenceTextAtomicAsync, hasEvidenceLease, evidenceFileStamp,
  evidenceFileStampAsync, evidenceFileDigestAsync, evidenceFileDigestSync, setEvidenceMutationObserver, assertEvidenceWritable,
  tryClaimEvidenceDeletion, releaseEvidenceDeletion, isEvidenceDeleting, acquireEvidenceLease, releaseEvidenceLease,
  evidenceTextDigest, ensureEvidenceTextDurableAsync, ensureEvidenceTextDurable, setEvidenceLeaseReleaseObserver, ensureEvidenceDirectoryAsync,
  assertEvidencePreparationCurrent, noteEvidencePublicationUnknown } from './EvidenceIo';
import { AtomicWriteError } from './AtomicFileWriter';

const TAG = 'ActivityLedger';

// ============================================================================
//  常量
// ============================================================================

/** 账本根目录名（挂在 filesDir/logs/ 下）。 */
export const LEDGER_DIR_NAME: string = 'ledger';
/** 账本索引文件名。 */
export const LEDGER_INDEX_NAME: string = 'index.json';
/** 单条账本的清单文件名。 */
export const LEDGER_MANIFEST_NAME: string = 'manifest.json';

/**
 * 账本条目数上限。与 `ActivityRecord` 的 LRU 容量（50）对齐 ——
 * 活动记录看不到的条目，账本留着也没有入口。
 */
export const LEDGER_MAX_ENTRIES: number = 50;
/** 账本总体积预算：64 MiB。 */
export const LEDGER_MAX_TOTAL_BYTES: number = 64 * 1024 * 1024;

/** 用户设置独立持久化，清空账本不重置偏好。 */
export function ledgerSessionRetention(filesDir: string): number {
  const path: string = filesDir + '/logs/session-retention.json';
  if (!fs.accessSync(path)) return SESSION_RETENTION_DEFAULT;
  return parseSessionRetention_(fs.readTextSync(path));
}
/** 已存在偏好必须是有限数字；损坏/读失败不是用户授权把100局缩回5局。 */
function parseSessionRetention_(text: string): number {
  const value = JSON.parse(text) as Object;
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('日志保留设置损坏，自动清理已停止；请重新保存设置');
  return normalizeSessionRetention(value);
}
/** 小型偏好异步读取，不借读取设置触发维护或目录统计。 */
export async function ledgerSessionRetentionAsync(filesDir: string): Promise<number> {
  try { return parseSessionRetention_(await fs.readText(filesDir + '/logs/session-retention.json')); }
  catch (error) { if ((error as BusinessError).code === 13900002) return SESSION_RETENTION_DEFAULT; throw error as Error; }
}

export function ledgerSetSessionRetention(filesDir: string, value: number): void {
  if (!maintenanceOwner) throw new Error('保留策略必须由启动器保存');
  ensureDirSync(filesDir + '/logs');
  if (!writeTextFile(filesDir + '/logs/session-retention.json', JSON.stringify(normalizeSessionRetention(value)))) {
    throw new Error('保存日志保留设置失败');
  }
  deferredMaintenance.add(filesDir);
  scheduleMaintenance_(filesDir);
}
/** 用户偏好与自动清理分开提交；game活跃时保存偏好并保留维护义务，不阻塞UI做目录递归。 */
export async function ledgerSetSessionRetentionAsync(filesDir: string, value: number): Promise<void> {
  if (!maintenanceOwner) throw new Error('保留策略必须由启动器保存');
  await ensureEvidenceDirectoryAsync(filesDir + '/logs');
  const path: string = filesDir + '/logs/session-retention.json';
  const text: string = JSON.stringify(normalizeSessionRetention(value));
  let previous: string = '';
  try { previous = await fs.readText(path); }
  catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
  if (previous !== text) await writeEvidenceTextAtomicAsync(path, text);
  else await ensureEvidenceTextDurableAsync(path);
  deferredMaintenance.add(filesDir);
  await ledgerFlushMaintenanceAsync(filesDir);
}

/** 账本内的日志分段（part）。 */
export enum LedgerPart {
  /** 启动器侧日志（native 分流写入；含 launcher.log + tail + tail.1 三片）。 */
  LAUNCHER = 0,
  /** MC 进程输出（仅游戏会话）。 */
  GAME = 1,
  /** MC log4j 本局日志（仅游戏会话）。 */
  MC_LATEST = 2,
  /** JVM 启动窗口输出（仅游戏会话）。 */
  JVM = 3,
  /** MC 自己的崩溃报告。 */
  CRASH_REPORT = 4,
  /** 系统崩溃栈（HiAppEvent external_log 副本）。 */
  SYSTEM_CRASH = 5,
}

/** part → 主文件名。 */
function partFileName(part: LedgerPart): string {
  if (part === LedgerPart.GAME) return 'game.log';
  if (part === LedgerPart.MC_LATEST) return 'mc-latest.log';
  if (part === LedgerPart.JVM) return 'jvm.log';
  if (part === LedgerPart.CRASH_REPORT) return 'crash-report.txt';
  if (part === LedgerPart.SYSTEM_CRASH) return 'system-crash.log';
  return 'launcher.log';
}

/** part 的中文名（UI 分段切换用）。 */
export function ledgerPartLabel(part: LedgerPart): string {
  if (part === LedgerPart.GAME) return '游戏输出';
  if (part === LedgerPart.MC_LATEST) return 'MC 日志';
  if (part === LedgerPart.JVM) return 'JVM';
  if (part === LedgerPart.CRASH_REPORT) return '崩溃报告';
  if (part === LedgerPart.SYSTEM_CRASH) return '系统崩溃';
  return '启动器';
}

/** 活动结局。数值持久化，只能追加。 */
export enum LedgerState {
  /** 进行中。进程被杀在活动中途时会留在这个状态。 */
  RUNNING = 0,
  SUCCESS = 1,
  FAILED = 2,
  ABORTED = 3,
  CRASHED = 4,
  /**
   * 中断：上次进程退出时该活动还是 RUNNING，冷启动时由 `resolveStale` 标定。
   * 这是现在完全没有的能力 —— 进程中途被杀，活动记录里什么都不会留下。
   */
  INTERRUPTED = 5,
}

/** 结局是否属于「异常」（淘汰时优先保留）。 */
export function isAbnormalState(state: LedgerState): boolean {
  return state === LedgerState.FAILED || state === LedgerState.CRASHED
    || state === LedgerState.INTERRUPTED;
}

export function ledgerStateLabel(state: LedgerState): string {
  if (state === LedgerState.RUNNING) return '进行中';
  if (state === LedgerState.SUCCESS) return '成功';
  if (state === LedgerState.FAILED) return '失败';
  if (state === LedgerState.ABORTED) return '已取消';
  if (state === LedgerState.CRASHED) return '崩溃';
  if (state === LedgerState.INTERRUPTED) return '被中断';
  return '未知';
}

// ============================================================================
//  数据结构
// ============================================================================

/** 开账本时提供的元信息。 */
export interface LedgerBeginMeta {
  /** 明确由调用方传入的父尝试/父任务；未提供时不按时间猜测关联。 */
  parentActivityId?: number;
  relation?: string;
  /** 活动类别（对齐 ActivityCategory：download / mod_install / launch / …）。 */
  category: string;
  /** 展示标题（版本名 / 模组名 / JDK 版本…）。 */
  title: string;
  /** 环境头（可选，缺省时 manifest 里留空）。 */
  appVersion?: string;
  deviceModel?: string;
  osVersion?: string;
  /** 游戏会话专用。 */
  gameVersionId?: string;
  loaderType?: string;
  loaderVersion?: string;
  jdk?: string;
  /** 游戏会话：.minecraft 根目录（读 GAME 段时反查游戏日志用）。 */
  mcDir?: string;
  /** 应用级 filesDir；电脑/渲染器等跨 HAP 组件的日志可能位于此处。 */
  appFilesDir?: string;
  /** 实际运行目录，不能从版本名猜测隔离状态。 */
  gameDir?: string;
  ownerPid?: number;
  runNonce?: string;
}

/** 结束账本时的结论。 */
export interface LedgerOutcome {
  state: LedgerState;
  /** 结论来源（如 'task.terminalState' / 'platform.lastExitReason'）。 */
  source: string;
  /** 一句话摘要。 */
  summary: string;
  /** 分类器 errorKind（如有）。 */
  errorKind?: string;
  /** 恢复裁决可提供已验证的结束时间；显式 0 表示未知，不能用恢复时间计算游戏时长。 */
  endedAt?: number;
  recoveredAt?: number;
}

/** 账本里的一个文件。 */
export interface LedgerFile {
  name: string;
  bytes: number;
}

/** 一条账本的完整清单。 */
export interface LedgerManifest {
  /** canonical清单只有owner提交时前进；旧schema缺字段按0读取。 */
  revision?: number;
  /** 已耐久应用的恢复输入，不与展示回执或证据派生revision混用。 */
  recoveryInputKey?: string;
  /** 精确归属平台事件及附件的输入集合身份；结局未变化的新附件也触发恢复消费。 */
  platformInputKey?: string;
  /** 用户主动保留的活动不参与自动淘汰；明确删除前需先取消保留。 */
  pinned?: boolean;
  parentActivityId?: number;
  relation?: string;
  schema: number;
  activityId: number;
  category: string;
  title: string;
  appVersion: string;
  deviceModel: string;
  osVersion: string;
  startedAt: number;
  endedAt: number;
  /** endedAt 仅作恢复采集边界时为 true，UI 不将它展示成真实游戏时长。 */
  endTimeEstimated?: boolean;
  recoveredAt?: number;
  state: LedgerState;
  outcomeSource: string;
  outcomeSummary: string;
  errorKind: string;
  /** 游戏会话专用（非游戏活动为空串）。 */
  gameVersionId: string;
  loaderType: string;
  loaderVersion: string;
  jdk: string;
  /**
   * 该次会话的 .minecraft 根目录（游戏会话才有）。
   *
   * 封账与冷启动恢复时将完整游戏输出复制到 game.log，读时优先用快照。
   * 旧日志只在精确匹配会话时补归档；不将近似匹配当作完整快照。
   */
  mcDir: string;
  /** 应用级 filesDir（仅本地归档使用，不进入公开摘要）。 */
  appFilesDir: string;
  gameDir?: string;
  ownerPid?: number;
  runNonce?: string;
  files: LedgerFile[];
}

/** 索引里的一条（UI 列表直接用，不必逐个读 manifest）。 */
export interface LedgerEntry {
  activityId: number;
  category: string;
  title: string;
  state: LedgerState;
  startedAt: number;
  endedAt: number;
  bytes: number;
  hasGame: boolean;
  /** V2派生统计的身份与新鲜度；旧消费者继续使用原字段。 */
  manifestRevision?: number;
  evidenceRevision?: number;
  versionKey?: string;
  pinned?: boolean;
  bytesState?: string;
  manifestDigest?: string;
  /** 受控元数据发布集合的身份，进程重启也能识别selection/receipt等落盘后索引未刷新。 */
  metadataFingerprint?: string;
}

/** 游戏生产者只发布本局结果；global index/retention始终归启动器owner。 */
export interface LedgerGameTerminal { schema: number; activityId: number; runNonce: string; pid: number; outcome: LedgerOutcome; }
export interface LedgerEndOptions { nextLaunchAt?: number; inputKey?: string; expectedManifestRevision?: number;
  capturePrepared?: boolean; repairArtifacts?: boolean;
  /** 仅恢复owner传入，等待native/IO后复核边界与锁；真正新游戏准入另由owner fence覆盖在途发布。 */
  commitGuard?: () => boolean; }
export interface LedgerCommitResult { changed: boolean; outcomeRevision: number; evidenceRevision: number; indexDirty: boolean; }
/** 累计实取计数只在真实生产操作边界递增；不按文件刷日志，也不改变用户日志范围。 */
export interface LedgerMaintenanceCounters { changedCommits: number; unchangedCommits: number; activityScans: number;
  fullRebuilds: number; indexWrites: number; retentionBatches: number; staleCommits: number; leaseProtected: number; }
const maintenanceCounters: LedgerMaintenanceCounters = { changedCommits: 0, unchangedCommits: 0, activityScans: 0,
  fullRebuilds: 0, indexWrites: 0, retentionBatches: 0, staleCommits: 0, leaseProtected: 0 };
/** 返回独立只读快照，调用方可比较批次前后，不取得内部可写计数对象。 */
export function ledgerMaintenanceCounters(): LedgerMaintenanceCounters {
  return { changedCommits: maintenanceCounters.changedCommits, unchangedCommits: maintenanceCounters.unchangedCommits,
    activityScans: maintenanceCounters.activityScans, fullRebuilds: maintenanceCounters.fullRebuilds,
    indexWrites: maintenanceCounters.indexWrites, retentionBatches: maintenanceCounters.retentionBatches,
    staleCommits: maintenanceCounters.staleCommits, leaseProtected: maintenanceCounters.leaseProtected };
}

/** 由进程装配显式设置；SDK消费者和宿主测试缺装配时保持原单进程兼容。 */
let maintenanceOwner: boolean = true;
let maintenanceAllowed: (() => boolean) | undefined = undefined;
/** root按filesDir隔离，防止验证夹具/多个应用根共享派生缓存。 */
const indexCaches: Map<string, LedgerEntry[]> = new Map<string, LedgerEntry[]>();
const dirtyLedgers: Map<string, Set<number>> = new Map<string, Set<number>>();
const dirtyGenerations: Map<string, number> = new Map<string, number>();
const maintenanceJobs: Map<string, Promise<void>> = new Map<string, Promise<void>>();
const maintenanceTimers: Map<string, number> = new Map<string, number>();
const maintenanceHolds: Map<string, number> = new Map<string, number>();
/** 只通知本进程owner已经耐久完成的目录移除，用于失效launch准入缓存；游戏进程不消费此端口。 */
let removalObserver: ((filesDir: string, activityId: number) => void) | undefined = undefined;
export function setLedgerRemovalObserver(observer: (filesDir: string, activityId: number) => void): void { removalObserver = observer; }
/** 有界只读计量：resolver无待办不等于索引/淘汰任务空闲，真机批次收尾同时记录这份事实。 */
export interface LedgerMaintenanceSnapshot { pendingCount: number; active: boolean; timer: boolean;
  holds: number; deferred: boolean; indexKnown: boolean; }
export function ledgerMaintenanceSnapshot(filesDir: string): LedgerMaintenanceSnapshot {
  return { pendingCount: dirtyLedgers.get(filesDir)?.size ?? 0, active: maintenanceJobs.has(filesDir),
    timer: maintenanceTimers.has(filesDir), holds: maintenanceHolds.get(filesDir) ?? 0,
    deferred: deferredMaintenance.has(filesDir), indexKnown: indexCaches.has(filesDir) };
}
let deferredMaintenance: Set<string> = new Set<string>();
/** canonical清单每活动串行；同owner中的await仍允许其他事件回调，不能只靠进程单例。 */
const canonicalMutations: Set<string> = new Set<string>();
const canonicalQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();
/** 清空预检期间阻止canonical变化；reader在claim前仍可读，但会让整批预检失败而零删除。 */
const clearingRoots: Set<string> = new Set<string>();

/** 同步兼容API无法等待进行中的异步事务，显式失败由原调用方报告，不盲写旧清单。 */
function assertCanonicalIdle_(filesDir: string, activityId: number): void {
  assertEvidenceWritable(filesDir, activityId);
  if (clearingRoots.has(filesDir)) throw new Error('账本正在清理，请稍后重试');
  if (canonicalMutations.has(filesDir + '/' + activityId) || canonicalQueues.has(filesDir + '/' + activityId)) throw new Error('活动清单正在提交，请稍后重试');
}
/** 每活动独立队列，前次失败不阻断后续明确重试；操作开始前重新检查delete claim。 */
function serializeCanonicalAsync_<T>(filesDir: string, activityId: number, operation: () => Promise<T>): Promise<T> {
  if (clearingRoots.has(filesDir)) return Promise.reject(new Error('账本正在清理，请稍后重试'));
  const key: string = filesDir + '/' + activityId;
  const previous: Promise<void> = canonicalQueues.get(key) ?? Promise.resolve();
  const job: Promise<T> = previous.then(async (): Promise<T> => {
    if (clearingRoots.has(filesDir)) throw new Error('账本正在清理，请稍后重试');
    assertEvidenceWritable(filesDir, activityId); canonicalMutations.add(key);
    try { return await operation(); } finally { canonicalMutations.delete(key); }
  });
  const completed: Promise<void> = job.then((): void => {}, (): void => {});
  canonicalQueues.set(key, completed);
  // 返回给调用方之前解除本轮空队列，await完成后立即调用同步兼容API不会误报仍忙。
  return job.then((value: T): T => { if (canonicalQueues.get(key) === completed) canonicalQueues.delete(key); return value; },
    (error: Error): T => { if (canonicalQueues.get(key) === completed) canonicalQueues.delete(key); throw error as Error; });
}

/** 游戏进程必须在任何ledger调用前设false；guard未知/活跃时只保留待维护请求。 */
export function configureLedgerMaintenanceOwner(owner: boolean, canMaintain?: () => boolean): void {
  maintenanceOwner = owner; maintenanceAllowed = canMaintain;
}

/** 恢复批次在首个await前持有；所有单局写只加入dirty，避免定时器在批中抢跑维护。 */
export function ledgerBeginMaintenanceBatch(filesDir: string): void {
  maintenanceHolds.set(filesDir, (maintenanceHolds.get(filesDir) ?? 0) + 1);
  const timer = maintenanceTimers.get(filesDir);
  if (timer !== undefined) { clearTimeout(timer); maintenanceTimers.delete(filesDir); }
}
/** 只有最后一个并发唤醒释放批次才维护一次，单局失败仍保留已完成变更和未消费义务。 */
export async function ledgerEndMaintenanceBatchAsync(filesDir: string): Promise<void> {
  const count: number = (maintenanceHolds.get(filesDir) ?? 0) - 1;
  if (count > 0) { maintenanceHolds.set(filesDir, count); return; }
  maintenanceHolds.delete(filesDir);
  await ledgerFlushMaintenanceAsync(filesDir);
}

/** 本局任何耐久元数据变更均使占用失效；不在写入回调中同步扫描历史目录。 */
export function ledgerMarkDirty(filesDir: string, activityId: number): void {
  if (!maintenanceOwner || activityId <= 0) return;
  let dirty = dirtyLedgers.get(filesDir);
  if (dirty === undefined) { dirty = new Set<number>(); dirtyLedgers.set(filesDir, dirty); }
  dirty.add(activityId);
  const key: string = filesDir + '/' + activityId;
  dirtyGenerations.set(key, (dirtyGenerations.get(key) ?? 0) + 1);
  const cache = indexCaches.get(filesDir);
  const entry = cache?.find((item: LedgerEntry): boolean => item.activityId === activityId);
  if (entry !== undefined) entry.bytesState = 'unknown';
  scheduleMaintenance_(filesDir);
}

/** 自动观察Evidence原子写，覆盖选择/回执/诊断等并非由ledgerEnd产生的占用变化。 */
setEvidenceMutationObserver((path: string): void => {
  const marker: string = '/logs/ledger/';
  const position: number = path.indexOf(marker);
  if (position < 0) return;
  const suffix: string = path.substring(position + marker.length);
  const idText: string = suffix.split('/')[0];
  if (!new RegExp('^[1-9][0-9]*$').test(idText)) return;
  ledgerMarkDirty(path.substring(0, position), Number(idText));
});
/** 被reader挡住的维护只在reader实际释放时重试，不靠定时轮询消耗CPU。 */
setEvidenceLeaseReleaseObserver((filesDir: string, _activityId: number): void => {
  if (deferredMaintenance.has(filesDir)) scheduleMaintenance_(filesDir);
});

/** timer只合并工作请求；其回调进入真实异步IO，绝不借timer掩盖同步递归扫描。 */
function scheduleMaintenance_(filesDir: string): void {
  if (!maintenanceOwner || (maintenanceHolds.get(filesDir) ?? 0) > 0 || maintenanceTimers.has(filesDir) || maintenanceJobs.has(filesDir)) return;
  maintenanceTimers.set(filesDir, setTimeout((): void => {
    maintenanceTimers.delete(filesDir);
    ledgerFlushMaintenanceAsync(filesDir).catch((error: Error): void => {
      deferredMaintenance.add(filesDir);
      AppLogger.warn(TAG, '账本维护待重试', error, LOG_DOMAIN);
    });
  }, 0));
}

// ============================================================================
//  native scope 注入（控制反转）
//
//  commons 不能直接依赖 libentry.so —— 否则 commons 抽成 HAR 时会反向依赖持有 .so
//  的 entry HAP。与 AppLogger.NativeLogSink 同一套路：由 entry 在启动时注入。
// ============================================================================

/** native 侧账本 scope 的开关能力。 */
export interface LedgerScopeSink {
  /** 打开 scope；返回是否成功。 */
  begin(activityId: number, dir: string): boolean;
  /** 关闭 scope。 */
  end(activityId: number): void;
  /** 可选真正native async work端口；它必须等待同一writer关闭，不是Promise包同步wait。 */
  endAsync?(activityId: number): Promise<void>;
  /** 关闭全部 scope。 */
  endAll(): void;
}

let g_scopeSink: LedgerScopeSink | null = null;
let processRunNonce: string = String(process.pid) + '-' + Date.now();
/** Ability 进程启动时注入一次身份，异步启动活动各自保存这份不可变归属。 */
export function setLedgerProcessRunNonce(nonce: string): void { processRunNonce = nonce; }

/** 由 entry 注入 native 实现；传 null 卸载（此时账本只有 manifest，没有日志分流）。 */
export function setLedgerScopeSink(sink: LedgerScopeSink | null): void {
  g_scopeSink = sink;
}

// ============================================================================
//  路径
// ============================================================================

function ledgerRoot(filesDir: string): string {
  return filesDir + '/logs/' + LEDGER_DIR_NAME;
}

/** 某条活动的账本目录（不保证存在）。 */
export function ledgerDirOf(filesDir: string, activityId: number): string {
  return ledgerRoot(filesDir) + '/' + activityId;
}

function indexPath(filesDir: string): string {
  return ledgerRoot(filesDir) + '/' + LEDGER_INDEX_NAME;
}

function manifestPath(filesDir: string, activityId: number): string {
  return ledgerDirOf(filesDir, activityId) + '/' + LEDGER_MANIFEST_NAME;
}

// ============================================================================
//  基础 IO
// ============================================================================

function readTextFile(path: string, maxBytes: number = 0): string {
  let f: fs.File | null = null;
  try {
    let total = fs.statSync(path).size;
    if (total <= 0) return '';
    let start = 0;
    let length = total;
    if (maxBytes > 0 && total > maxBytes) {
      start = total - maxBytes;
      length = maxBytes;
    }
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(length);
    let got = fs.readSync(f.fd, buf, { offset: start, length: length });
    if (got <= 0) return '';
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buf, 0, got));
  } catch (e) {
    return '';
  } finally {
    if (f !== null) { try { fs.closeSync(f); } catch (e) { /* ignore */ } }
  }
}

function writeTextFile(path: string, text: string): boolean {
  try {
    writeEvidenceTextAtomic(path, text);
    return true;
  } catch (e) {
    AppLogger.warn(TAG, 'writeTextFile failed: ' + path, e, LOG_DOMAIN);
    return false;
  }
}

function fileBytes(path: string): number {
  try {
    return fs.statSync(path).size;
  } catch (e) {
    return 0;
  }
}

function isDir(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (e) {
    return false;
  }
}

// ============================================================================
//  manifest 序列化
//
//  逐字段校验，脏条目跳过而不是整份丢弃 —— 与 DownloadHistory / AppMessageStore
//  同一取向：宁可少一条，也不要因为一条坏数据让用户所有账本都打不开。
// ============================================================================

function emptyManifest(activityId: number): LedgerManifest {
  let m: LedgerManifest = {
    schema: 1, activityId: activityId, category: '', title: '',
    appVersion: '', deviceModel: '', osVersion: '',
    startedAt: activityId, endedAt: 0,
    state: LedgerState.RUNNING, outcomeSource: '', outcomeSummary: '', errorKind: '',
    gameVersionId: '', loaderType: '', loaderVersion: '', jdk: '', mcDir: '', appFilesDir: '',
    files: [],
  };
  return m;
}

function str_(obj: Record<string, Object>, key: string): string {
  let v = obj[key];
  return (typeof v === 'string') ? v as string : '';
}

function num_(obj: Record<string, Object>, key: string, fallback: number): number {
  let v = obj[key];
  return (typeof v === 'number') ? v as number : fallback;
}

export function parseLedgerManifest(json: string): LedgerManifest | null {
  if (json.length === 0) return null;
  let obj: Record<string, Object> | null = null;
  try {
    let parsed = JSON.parse(json) as Object;
    if (typeof parsed !== 'object' || parsed === null) return null;
    obj = parsed as Record<string, Object>;
  } catch (e) {
    return null;
  }
  let id = num_(obj, 'activityId', 0);
  if (id <= 0) return null;

  let m = emptyManifest(id);
  m.schema = num_(obj, 'schema', 1);
  m.revision = num_(obj, 'revision', 0);
  m.recoveryInputKey = str_(obj, 'recoveryInputKey');
  m.platformInputKey = str_(obj, 'platformInputKey');
  m.category = str_(obj, 'category');
  m.title = str_(obj, 'title');
  m.appVersion = str_(obj, 'appVersion');
  m.deviceModel = str_(obj, 'deviceModel');
  m.osVersion = str_(obj, 'osVersion');
  m.startedAt = num_(obj, 'startedAt', id);
  m.endedAt = num_(obj, 'endedAt', 0);
  m.endTimeEstimated = obj['endTimeEstimated'] === true;
  m.recoveredAt = num_(obj, 'recoveredAt', 0);
  m.pinned = obj['pinned'] === true;
  m.parentActivityId = num_(obj, 'parentActivityId', 0);
  m.relation = str_(obj, 'relation');
  m.state = num_(obj, 'state', LedgerState.RUNNING) as LedgerState;
  m.outcomeSource = str_(obj, 'outcomeSource');
  // 旧版残留收尾把重启时刻写成 endedAt；升级读取时纠正其时间可信度，不篡改原始时间。
  if (obj['endTimeEstimated'] === undefined && (m.outcomeSource === 'ledger.resolveStale'
    || m.outcomeSource === 'session.full-evidence' || m.outcomeSource === 'session.jvm-exit')) m.endTimeEstimated = true;
  m.outcomeSummary = str_(obj, 'outcomeSummary');
  m.errorKind = str_(obj, 'errorKind');
  m.gameVersionId = str_(obj, 'gameVersionId');
  m.loaderType = str_(obj, 'loaderType');
  m.loaderVersion = str_(obj, 'loaderVersion');
  m.jdk = str_(obj, 'jdk');
  m.mcDir = str_(obj, 'mcDir');
  m.appFilesDir = str_(obj, 'appFilesDir');
  m.gameDir = str_(obj, 'gameDir');
  m.ownerPid = num_(obj, 'ownerPid', 0);
  m.runNonce = str_(obj, 'runNonce');

  let fv = obj['files'];
  if (Array.isArray(fv)) {
    let arr = fv as Object[];
    for (let item of arr) {
      if (typeof item !== 'object' || item === null) continue;
      let fo = item as Record<string, Object>;
      let name = str_(fo, 'name');
      if (name.length === 0) continue;
      let lf: LedgerFile = { name: name, bytes: num_(fo, 'bytes', 0) };
      m.files.push(lf);
    }
  }
  return m;
}

// ============================================================================
//  账本目录扫描
// ============================================================================

/** 扫账本根目录，收集每条账本的实际文件与体积。 */
function scanDirRecursive_(dir: string, prefix: string, out: LedgerFile[], depth: number): void {
  if (depth > 8) return;
  let names: string[] = [];
  try { names = fs.listFileSync(dir); } catch (e) { return; }
  for (let n of names) {
    const path: string = dir + '/' + n;
    const name: string = prefix.length > 0 ? prefix + '/' + n : n;
    // 文件表只描述事实原件；恢复状态/回执和可重建索引独立保存，不参与封账反馈。
    if (isInternalEvidencePath(name)) continue;
    if (isDir(path)) {
      scanDirRecursive_(path, name, out, depth + 1);
      continue;
    }
    let b = fileBytes(path);
    if (b <= 0) continue;
    out.push({ name: name, bytes: b });
  }
}

function scanDir(filesDir: string, activityId: number): LedgerFile[] {
  let out: LedgerFile[] = [];
  let dir = ledgerDirOf(filesDir, activityId);
  scanDirRecursive_(dir, '', out, 0);
  return out;
}

/** 某条账本实际占用，包含内部清单和选择记录；与占用面板的目录统计保持一致。 */
export function ledgerBytesOf(filesDir: string, activityId: number): number {
  return directoryBytesStrictSync_(ledgerDirOf(filesDir, activityId), 0);
}

/** 兼容同步调用的严格计量；失败抛错而非静默返回零，正常维护使用异步等价路径。 */
function directoryBytesStrictSync_(directory: string, depth: number): number {
  if (depth > 8) throw new Error('账本目录层级超过统计范围');
  let bytes: number = 0;
  for (const name of fs.listFileSync(directory)) {
    const path: string = directory + '/' + name;
    const stat = fs.lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error('账本存在符号链接，无法确认统计边界');
    bytes += stat.isDirectory() ? directoryBytesStrictSync_(path, depth + 1) : stat.size;
  }
  return bytes;
}

// ============================================================================
//  公共 API
// ============================================================================

/**
 * 开一条账本。
 *
 * 立刻写入 `state=RUNNING` 的 manifest —— 这样即使进程在活动中途被杀，磁盘上也留着
 * 一条「做到一半」的记录和已写入的日志，下次启动由 `resolveStale` 标成 INTERRUPTED。
 *
 * @param activityId 活动主键（= ActivityRecord.startedAt，毫秒）
 * @returns 是否成功（失败时调用方按「本条活动无账本」降级，全局日志里仍有内容）
 */
export function ledgerBegin(filesDir: string, activityId: number,
  meta: LedgerBeginMeta): boolean {
  if (filesDir.length === 0 || activityId <= 0) return false;
  assertCanonicalIdle_(filesDir, activityId);
  // 新开一局不能顺便补采全部历史；旧资料迁移由冷启动恢复owner显式处理。
  let dir = ledgerDirOf(filesDir, activityId);
  try {
    ensureDirSync(dir);
  } catch (e) {
    AppLogger.warn(TAG, 'ledgerBegin mkdir failed: ' + dir, e, LOG_DOMAIN);
    return false;
  }

  const existing = ledgerManifest(filesDir, activityId);
  if (existing === null && fs.accessSync(manifestPath(filesDir, activityId))) throw new Error('活动清单损坏，原件保留等待修复');
  if (existing !== null && existing.state !== LedgerState.RUNNING) return false;
  if (!maintenanceOwner && existing !== null) {
    // RUNNING基线完成后canonical写权已移交启动器；后续游戏profile只发布patch，
    // 不整份覆写启动器可能刚保存的pin/恢复字段。capture基线由原记录保留。
    const patchPath: string = dir + '/game-metadata.json';
    const patchText: string = JSON.stringify({ schema: 1, activityId: activityId,
      runNonce: existing.runNonce ?? '', pid: process.pid, meta: meta });
    if (readTextFile(patchPath) !== patchText) writeEvidenceTextAtomic(patchPath, patchText);
    else ensureEvidenceTextDurable(patchPath);
    if (g_scopeSink !== null) { try { g_scopeSink.begin(activityId, dir); } catch (_) {} }
    return true;
  }
  let m = existing ?? emptyManifest(activityId);
  m.category = meta.category;
  if (meta.parentActivityId !== undefined && meta.parentActivityId > 0 && meta.parentActivityId !== activityId) {
    m.parentActivityId = meta.parentActivityId;
    m.relation = meta.relation ?? 'related';
  }
  m.title = meta.title;
  m.appVersion = meta.appVersion ?? m.appVersion;
  m.deviceModel = meta.deviceModel ?? m.deviceModel;
  m.osVersion = meta.osVersion ?? m.osVersion;
  m.gameVersionId = meta.gameVersionId ?? m.gameVersionId;
  m.loaderType = meta.loaderType ?? m.loaderType;
  m.loaderVersion = meta.loaderVersion ?? m.loaderVersion;
  m.jdk = meta.jdk ?? m.jdk;
  m.mcDir = meta.mcDir ?? m.mcDir;
  m.appFilesDir = meta.appFilesDir ?? m.appFilesDir;
  m.gameDir = meta.gameDir ?? m.gameDir;
  m.ownerPid = meta.ownerPid ?? process.pid;
  m.runNonce = meta.runNonce ?? processRunNonce;
  m.startedAt = activityId;
  m.state = LedgerState.RUNNING;
  m.revision = (m.revision ?? 0) + 1;
  if (!writeTextFile(manifestPath(filesDir, activityId), JSON.stringify(m))) return false;
  if (m.category === 'launch') {
    try { beginSessionCapture(filesDir, activityId, m.gameDir ?? '', m.appFilesDir, m.jdk); }
    catch (e) { AppLogger.error(TAG, 'capture baseline save failed', e, LOG_DOMAIN, activityId); }
  }
  // U02：先建立运行中的证据清单。后续 writer/归档器会在封账时刷新文件和完整性。
  refreshSessionEvidence(filesDir, activityId, 'running', 'partial');

  // 注册 native scope：此后归属该 activityId 的日志行会写进 dir/launcher.log
  let ok = true;
  if (g_scopeSink !== null) {
    try {
      ok = g_scopeSink.begin(activityId, dir);
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      // scope 槽位满（并发活动过多）：manifest 仍然留着，只是没有分流日志。
      // 不抢占别人的 scope —— 那会让另一条活动的日志半途断掉。
      AppLogger.warn(TAG, 'native ledger scope unavailable for ' + activityId
        + ' (slots full); manifest kept without launcher.log', null, LOG_DOMAIN);
    }
  }
  AppLogger.info(TAG, 'ledger begin: id=' + activityId + ' category=' + meta.category
    + ' scope=' + ok, LOG_DOMAIN);
  return true;
}

/**
 * canonical异步开账：任务registry可等待本局基线后再启动producer，终态也等待同一per-ID队列。
 * 游戏进程只一次创建RUNNING基线，后续meta为单局patch；不读取或维护其他局目录。
 */
export function ledgerBeginAsync(filesDir: string, activityId: number, meta: LedgerBeginMeta): Promise<boolean> {
  return serializeCanonicalAsync_(filesDir, activityId, async (): Promise<boolean> => {
    if (filesDir.length === 0 || !Number.isSafeInteger(activityId) || activityId <= 0) return false;
    await ensureEvidenceDirectoryAsync(ledgerDirOf(filesDir, activityId));
    const existing = await ledgerManifestAsync(filesDir, activityId);
    if (existing === null && await fs.access(manifestPath(filesDir, activityId))) throw new Error('活动清单损坏，原件保留等待修复');
    if (existing !== null && existing.state !== LedgerState.RUNNING) return false;
    if (!maintenanceOwner && existing !== null) {
      const path: string = ledgerDirOf(filesDir, activityId) + '/game-metadata.json';
      const text: string = JSON.stringify({ schema: 1, activityId: activityId, runNonce: existing.runNonce ?? '', pid: process.pid, meta: meta });
      let old: string = '';
      try { old = await fs.readText(path); } catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
      if (old !== text) await writeEvidenceTextAtomicAsync(path, text); else await ensureEvidenceTextDurableAsync(path);
      return true;
    }
    const manifest = existing ?? emptyManifest(activityId);
    const previous: string = existing === null ? '' : JSON.stringify(existing);
    manifest.category = meta.category; manifest.title = meta.title;
    if (meta.parentActivityId !== undefined && meta.parentActivityId > 0 && meta.parentActivityId !== activityId) {
      manifest.parentActivityId = meta.parentActivityId; manifest.relation = meta.relation ?? 'related';
    }
    manifest.appVersion = meta.appVersion ?? manifest.appVersion; manifest.deviceModel = meta.deviceModel ?? manifest.deviceModel;
    manifest.osVersion = meta.osVersion ?? manifest.osVersion; manifest.gameVersionId = meta.gameVersionId ?? manifest.gameVersionId;
    manifest.loaderType = meta.loaderType ?? manifest.loaderType; manifest.loaderVersion = meta.loaderVersion ?? manifest.loaderVersion;
    manifest.jdk = meta.jdk ?? manifest.jdk; manifest.mcDir = meta.mcDir ?? manifest.mcDir;
    manifest.appFilesDir = meta.appFilesDir ?? manifest.appFilesDir; manifest.gameDir = meta.gameDir ?? manifest.gameDir;
    manifest.ownerPid = meta.ownerPid ?? process.pid; manifest.runNonce = meta.runNonce ?? manifest.runNonce ?? processRunNonce;
    manifest.startedAt = activityId; manifest.state = LedgerState.RUNNING;
    if (previous !== JSON.stringify(manifest)) {
      manifest.revision = (manifest.revision ?? 0) + 1;
      await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest));
    }
    if (manifest.category === 'launch') await beginSessionCaptureAsync(filesDir, activityId, manifest.gameDir ?? '', manifest.appFilesDir, manifest.jdk);
    await refreshSessionEvidenceAsync(filesDir, activityId, 'running', 'partial');
    // scope创建仍是原native契约（小型建目录/头文件），不存在500ms结束flush等待。
    if (g_scopeSink !== null && !g_scopeSink.begin(activityId, ledgerDirOf(filesDir, activityId))) {
      AppLogger.warn(TAG, 'native ledger scope unavailable，保留可恢复manifest', null, LOG_DOMAIN);
    }
    return true;
  });
}

/**
 * 结束一条账本：关掉 native scope，补齐 manifest 的结局与文件清单，更新索引。
 */
export function ledgerEnd(filesDir: string, activityId: number,
  outcome: LedgerOutcome): void {
  if (filesDir.length === 0 || activityId <= 0) return;
  assertCanonicalIdle_(filesDir, activityId);

  // 先关 scope，确保 native 已 flush 并释放句柄，之后统计的体积才是最终值
  if (g_scopeSink !== null) {
    try { g_scopeSink.end(activityId); } catch (e) { /* ignore */ }
  }

  let m = parseLedgerManifest(readTextFile(manifestPath(filesDir, activityId)));
  if (m === null) {
    if (fs.accessSync(manifestPath(filesDir, activityId))) throw new Error('活动清单损坏，原始证据仍保留');
    m = emptyManifest(activityId);
  }
  assertEvidenceWritable(filesDir, activityId);
  if (!maintenanceOwner) {
    const terminal: LedgerGameTerminal = { schema: 1, activityId: activityId,
      runNonce: m.runNonce ?? '', pid: process.pid, outcome: outcome };
    const path: string = ledgerDirOf(filesDir, activityId) + '/game-terminal.json';
    const text: string = JSON.stringify(terminal);
    if (readTextFile(path) !== text) writeEvidenceTextAtomic(path, text);
    else ensureEvidenceTextDurable(path);
    return;
  }
  // 重复终态调用不能移动endedAt/recoveredAt；确有新证据的恢复使用带inputKey的异步入口。
  if (m.state !== LedgerState.RUNNING && sameOutcome_(m, outcome)) {
    ensureEvidenceTextDurable(manifestPath(filesDir, activityId));
    ensureEvidenceTextDurable(ledgerDirOf(filesDir, activityId) + '/evidence-manifest.json');
    maintenanceCounters.unchangedCommits++; return;
  }
  const observedAt: number = Date.now();
  // 实时任务以收尾时刻作为终点；恢复裁决必须显式提供时间或声明未知。
  if (outcome.endedAt !== undefined) {
    const exact: boolean = Number.isFinite(outcome.endedAt) && outcome.endedAt >= m.startedAt
      && outcome.endedAt <= observedAt;
    if (exact) { m.endedAt = outcome.endedAt; m.endTimeEstimated = false; }
    else if (m.endedAt <= 0 || m.endTimeEstimated !== false) {
      m.endedAt = m.endedAt > 0 ? m.endedAt : observedAt;
      m.endTimeEstimated = true;
    }
  } else {
    m.endedAt = observedAt;
    m.endTimeEstimated = false;
  }
  if (outcome.recoveredAt !== undefined) m.recoveredAt = outcome.recoveredAt;
  m.state = outcome.state;
  m.outcomeSource = outcome.source;
  m.outcomeSummary = outcome.summary;
  m.errorKind = outcome.errorKind ?? '';
  m.revision = (m.revision ?? 0) + 1;
  archiveAuxiliaryFiles_(filesDir, m);
  archiveSessionLogs(filesDir, m);
  m.files = scanDir(filesDir, activityId);
  if (!writeTextFile(manifestPath(filesDir, activityId), JSON.stringify(m))) {
    throw new Error('活动终态未保存，请检查存储空间；原始证据仍保留在本地');
  }
  const hasGameEvidence: boolean = fileBytes(ledgerDirOf(filesDir, activityId) + '/game.log') > 0
    || fileBytes(ledgerDirOf(filesDir, activityId) + '/game/mc_output.log') > 0
    || fileBytes(ledgerDirOf(filesDir, activityId) + '/game/logs/latest.log') > 0
    || fileBytes(ledgerDirOf(filesDir, activityId) + '/mc-latest.log') > 0;
  const integrity: string = m.category === 'launch' && !hasGameEvidence ? 'partial' : 'complete';
  const missing: string[] = integrity === 'partial' ? ['本次会话没有归档到 MC 主日志'] : [];
  refreshSessionEvidence(filesDir, activityId, 'sealed', integrity, missing);

  ledgerMarkDirty(filesDir, activityId);
  maintenanceCounters.changedCommits++;
  AppLogger.info(TAG, 'ledger end: id=' + activityId
    + ' state=' + ledgerStateLabel(outcome.state)
    + ' files=' + m.files.length, LOG_DOMAIN);
}

/** 结局的语义比较排除检查时间；未知结束时间不能覆盖已核实的真实终点。 */
function sameOutcome_(manifest: LedgerManifest, outcome: LedgerOutcome): boolean {
  if (manifest.state !== outcome.state || manifest.outcomeSource !== outcome.source
    || manifest.outcomeSummary !== outcome.summary || manifest.errorKind !== (outcome.errorKind ?? '')) return false;
  return outcome.endedAt === undefined || outcome.endedAt === 0
    || manifest.endedAt === outcome.endedAt && manifest.endTimeEstimated !== true;
}

/** owner和展示投影的异步原清单读取；解析仍复用既有兼容规则。 */
export async function ledgerManifestAsync(filesDir: string, activityId: number): Promise<LedgerManifest | null> {
  try { return parseLedgerManifest(await fs.readText(manifestPath(filesDir, activityId))); }
  catch (error) { if ((error as BusinessError).code === 13900002) return null; throw error as Error; }
}

/** 严格数字目录发现；轻量集合枚举不进入任何日志子目录。 */
async function listActivityIdsAsync_(filesDir: string): Promise<number[]> {
  const root: string = ledgerRoot(filesDir);
  if (!await fs.access(root)) return [];
  const ids: number[] = [];
  for (const name of await fs.listFile(root)) {
    if (!new RegExp('^[1-9][0-9]*$').test(name)) continue;
    const id: number = Number(name);
    if (!Number.isSafeInteger(id) || !(await fs.lstat(root + '/' + name)).isDirectory()) continue;
    ids.push(id);
  }
  return ids.sort((left: number, right: number): number => right - left);
}

/** 只读活动集合给恢复发现使用，绝不借账本占用索引递归扫描日志。 */
export async function ledgerActivityIdsAsync(filesDir: string): Promise<number[]> { return await listActivityIdsAsync_(filesDir); }
/** 冷启动轻量历史身份发现；损坏清单保留目录原件但不猜造launch身份。 */
export async function ledgerLaunchManifestsAsync(filesDir: string): Promise<LedgerManifest[]> {
  const out: LedgerManifest[] = [];
  for (const id of await listActivityIdsAsync_(filesDir)) {
    const manifest = await ledgerManifestAsync(filesDir, id);
    if (manifest?.category === 'launch') out.push(manifest);
  }
  return out;
}

/**
 * sole旧marker的显式迁移入口：只保存marker已提供的身份与路径，capture/owner/nonce保持未知。
 * 不在恢复时以当前全局文件伪造启动前基线；完整性清单因此保留partial说明。
 */
export async function ledgerEnsureLegacyLaunchAsync(filesDir: string, activityId: number, meta: LedgerBeginMeta): Promise<LedgerManifest> {
  if (!maintenanceOwner || !Number.isSafeInteger(activityId) || activityId <= 0) throw new Error('旧会话迁移身份无效');
  // 整个legacy事务进入既有per-ID队列；存在manifest也必须等待前一笔Evidence/native发布settled。
  // 这不是嵌套Begin/End，body只直接发布legacy最小清单与Evidence，不会重入同key造成死锁。
  acquireEvidenceLease(filesDir, activityId);
  try { return await serializeCanonicalAsync_(filesDir, activityId, async (): Promise<LedgerManifest> => {
  const current = await ledgerManifestAsync(filesDir, activityId);
  if (current !== null) return current;
  if (await fs.access(manifestPath(filesDir, activityId))) throw new Error('旧会话清单损坏，原件保留等待修复');
  const manifest = emptyManifest(activityId);
  manifest.category = 'launch'; manifest.title = meta.title; manifest.gameVersionId = meta.gameVersionId ?? meta.title;
  manifest.mcDir = meta.mcDir ?? ''; manifest.gameDir = meta.gameDir ?? ''; manifest.revision = 1;
  await ensureEvidenceDirectoryAsync(ledgerDirOf(filesDir, activityId));
  await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest));
  await refreshSessionEvidenceAsync(filesDir, activityId, 'running', 'partial', ['历史marker没有启动前来源基线，捕获归属及连续性未知']);
  return manifest;
  }); } finally { releaseEvidenceLease(filesDir, activityId); }
}

/** 下一局界限只查小型manifest；调用者可直接传已有值避免一批恢复反复发现。 */
export async function ledgerNextLaunchAtAsync(filesDir: string, activityId: number): Promise<number> {
  let next: number = 0;
  for (const id of await listActivityIdsAsync_(filesDir)) {
    if (id <= activityId || next > 0 && id >= next) continue;
    if ((await ledgerManifestAsync(filesDir, id))?.category === 'launch') next = id;
  }
  return next;
}

/** 游戏结果只有本局身份与PID匹配才可被owner采用；原子JSON上限防止任意正文进入协议。 */
export async function readLedgerGameTerminalAsync(filesDir: string, activityId: number): Promise<LedgerGameTerminal | undefined> {
  const path: string = ledgerDirOf(filesDir, activityId) + '/game-terminal.json';
  try {
    if ((await fs.stat(path)).size > 32768) return undefined;
    const value = JSON.parse(await fs.readText(path)) as LedgerGameTerminal;
    const manifest = await ledgerManifestAsync(filesDir, activityId);
    if (manifest === null || value.schema !== 1 || value.activityId !== activityId
      || value.pid !== manifest.ownerPid || value.runNonce !== (manifest.runNonce ?? '')
      || value.outcome === undefined || !Number.isInteger(value.outcome.state)
      || value.outcome.state < LedgerState.SUCCESS || value.outcome.state > LedgerState.INTERRUPTED
      || typeof value.outcome.source !== 'string' || typeof value.outcome.summary !== 'string') return undefined;
    return value;
  } catch (error) { if ((error as BusinessError).code === 13900002 || error instanceof SyntaxError) return undefined; throw error as Error; }
}

/**
 * 游戏元信息patch的唯一合并入口。只复制已知meta字段，保留pin、终态、runNonce和原开始时间；
 * 两个进程不再用整份manifest最后写者覆盖对方。未匹配patch原件保留供核查。
 */
export function ledgerMergeGameMetadataAsync(filesDir: string, activityId: number): Promise<boolean> {
  return serializeCanonicalAsync_(filesDir, activityId, (): Promise<boolean> => mergeGameMetadataInternalAsync_(filesDir, activityId));
}
async function mergeGameMetadataInternalAsync_(filesDir: string, activityId: number): Promise<boolean> {
  if (!maintenanceOwner) return false;
  assertEvidenceWritable(filesDir, activityId);
  const manifest = await ledgerManifestAsync(filesDir, activityId);
  if (manifest === null) return false;
  try {
    const path: string = ledgerDirOf(filesDir, activityId) + '/game-metadata.json';
    if ((await fs.stat(path)).size > 32768) return false;
    const patch = JSON.parse(await fs.readText(path)) as Record<string, Object>;
    if (patch['schema'] !== 1 || patch['activityId'] !== activityId || patch['pid'] !== manifest.ownerPid
      || patch['runNonce'] !== manifest.runNonce) return false;
    const meta = patch['meta'] as Record<string, Object>;
    if (meta === undefined || meta === null || typeof meta !== 'object') return false;
    const previous: string = JSON.stringify(manifest);
    // 具体字段而不是Object.assign，避免生产者patch取得pin/outcome写权限。
    for (const key of ['title', 'appVersion', 'deviceModel', 'osVersion', 'gameVersionId', 'loaderType', 'loaderVersion', 'jdk', 'mcDir', 'appFilesDir', 'gameDir']) {
      const value = meta[key];
      if (typeof value === 'string' && value.length > 0) {
        if (key === 'title') manifest.title = value;
        else if (key === 'appVersion') manifest.appVersion = value;
        else if (key === 'deviceModel') manifest.deviceModel = value;
        else if (key === 'osVersion') manifest.osVersion = value;
        else if (key === 'gameVersionId') manifest.gameVersionId = value;
        else if (key === 'loaderType') manifest.loaderType = value;
        else if (key === 'loaderVersion') manifest.loaderVersion = value;
        else if (key === 'jdk') manifest.jdk = value;
        else if (key === 'mcDir') manifest.mcDir = value;
        else if (key === 'appFilesDir') manifest.appFilesDir = value;
        else if (key === 'gameDir') manifest.gameDir = value;
      }
    }
    if (typeof meta['parentActivityId'] === 'number' && Number(meta['parentActivityId']) > 0) manifest.parentActivityId = Number(meta['parentActivityId']);
    if (typeof meta['relation'] === 'string') manifest.relation = meta['relation'] as string;
    if (previous === JSON.stringify(manifest)) return false;
    manifest.revision = (manifest.revision ?? 0) + 1;
    assertEvidenceWritable(filesDir, activityId);
    await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest));
    return true;
  } catch (error) {
    // 不存在的patch是正常；读取/保存失败不删除原件，下一轮owner仍可检查。
    if (!await fs.access(ledgerDirOf(filesDir, activityId) + '/game-metadata.json')) return false;
    throw error as Error;
  }
}

/** 单局严格目录扫描：任何枚举/属性失败抛错，不能把未统计内容伪装成零字节。 */
async function scanDirAsync_(directory: string, prefix: string, out: LedgerFile[], depth: number,
  includeMetadata: boolean = false, cancelled?: () => boolean): Promise<void> {
  if (depth > 8) throw new Error('账本目录层级超过统计范围');
  for (const name of await fs.listFile(directory)) {
    if (cancelled !== undefined && cancelled()) throw new Error('账本读取已取消');
    const path: string = directory + '/' + name;
    const relative: string = prefix.length > 0 ? prefix + '/' + name : name;
    // actualbytes 统计显式包含所有物理文件；只有 canonical 文件表使用内务过滤。
    if (!includeMetadata && isInternalEvidencePath(relative)) continue;
    const stat = await fs.lstat(path);
    if (stat.isSymbolicLink()) throw new Error('账本存在符号链接，无法确认统计边界');
    if (stat.isDirectory()) { await scanDirAsync_(path, relative, out, depth + 1, includeMetadata, cancelled); continue; }
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 0) throw new Error('账本文件属性无效');
    out.push({ name: relative, bytes: stat.size });
  }
}

/** 恢复事务只修改本局，索引/保留通过dirty请求在批尾合并；无变化不触碰任何清单。 */
export function ledgerEndAsync(filesDir: string, activityId: number, outcome: LedgerOutcome,
  options: LedgerEndOptions = {}): Promise<LedgerCommitResult> {
  return serializeCanonicalAsync_(filesDir, activityId, (): Promise<LedgerCommitResult> => endInternalAsync_(filesDir, activityId, outcome, options));
}
async function endInternalAsync_(filesDir: string, activityId: number, outcome: LedgerOutcome,
  options: LedgerEndOptions = {}): Promise<LedgerCommitResult> {
  assertEvidenceWritable(filesDir, activityId);
  acquireEvidenceLease(filesDir, activityId);
  try {
    assertEvidencePreparationCurrent(options.commitGuard);
    const manifest = await ledgerManifestAsync(filesDir, activityId);
    if (manifest === null) throw new Error('活动清单不存在或无法读取；原证据仍保留');
    if (!maintenanceOwner) {
      const path: string = ledgerDirOf(filesDir, activityId) + '/game-terminal.json';
      let previous: LedgerGameTerminal | undefined;
      try { previous = JSON.parse(await fs.readText(path)) as LedgerGameTerminal; }
      catch (error) { if ((error as BusinessError).code !== 13900002 && !(error instanceof SyntaxError)) throw error as Error; }
      if (previous !== undefined && previous.activityId === activityId && previous.runNonce === manifest.runNonce
        && previous.outcome.state === outcome.state && previous.outcome.source === outcome.source && previous.outcome.summary === outcome.summary
        && (previous.outcome.errorKind ?? '') === (outcome.errorKind ?? '')) {
        await ensureEvidenceTextDurableAsync(path);
        return { changed: false, outcomeRevision: manifest.revision ?? 0, evidenceRevision: 0, indexDirty: false };
      }
      if (g_scopeSink !== null) {
        if (g_scopeSink.endAsync === undefined) throw new Error('异步账本关闭端口尚未装配，原证据保留等待重试');
        await g_scopeSink.endAsync(activityId);
      }
      const terminalOutcome: LedgerOutcome = { state: outcome.state, source: outcome.source, summary: outcome.summary,
        errorKind: outcome.errorKind, endedAt: outcome.endedAt ?? Date.now(), recoveredAt: outcome.recoveredAt };
      const terminal: LedgerGameTerminal = { schema: 1, activityId: activityId, runNonce: manifest.runNonce ?? '', pid: process.pid, outcome: terminalOutcome };
      await writeEvidenceTextAtomicAsync(path, JSON.stringify(terminal));
      return { changed: true, outcomeRevision: manifest.revision ?? 0, evidenceRevision: 0, indexDirty: false };
    }
    if (options.inputKey !== undefined && maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程活跃或状态未知，恢复提交已延后');
    if (options.expectedManifestRevision !== undefined && (manifest.revision ?? 0) !== options.expectedManifestRevision) throw new Error('活动清单已变化，请重新裁决');
    const previous: string = JSON.stringify(manifest);
    const businessChanged: boolean = !sameOutcome_(manifest, outcome);
    const inputChanged: boolean = options.inputKey !== undefined && options.inputKey !== (manifest.recoveryInputKey ?? '');
    if (!businessChanged && !inputChanged && options.repairArtifacts !== true) {
      await ensureEvidenceTextDurableAsync(manifestPath(filesDir, activityId));
      await ensureEvidenceTextDurableAsync(ledgerDirOf(filesDir, activityId) + '/evidence-manifest.json');
      assertEvidencePreparationCurrent(options.commitGuard);
      maintenanceCounters.unchangedCommits++;
      return { changed: false, outcomeRevision: manifest.revision ?? 0,
        evidenceRevision: (await readSessionEvidenceAsync_(filesDir, activityId))?.revision ?? 0, indexDirty: false };
    }
    // 单局owner事务需要关闭本进程scope时，使用真实native异步桥；旧兼容sink不在此隐式同步等待。
    if (g_scopeSink !== null) {
      if (g_scopeSink.endAsync === undefined) throw new Error('异步账本关闭端口尚未装配，原证据保留等待重试');
      await g_scopeSink.endAsync(activityId);
    }
    assertEvidencePreparationCurrent(options.commitGuard);
    const observedAt: number = Date.now();
    if (outcome.endedAt === undefined && options.inputKey === undefined) {
      // 正在运行任务的实时收尾本身就是结束边界；恢复传入inputKey/显式0时仍保持未知时间。
      manifest.endedAt = observedAt; manifest.endTimeEstimated = false;
    } else if (outcome.endedAt !== undefined && Number.isFinite(outcome.endedAt)
      && outcome.endedAt >= manifest.startedAt && outcome.endedAt <= observedAt) {
      manifest.endedAt = outcome.endedAt; manifest.endTimeEstimated = false;
    } else if (manifest.endedAt <= 0) {
      manifest.endedAt = observedAt; manifest.endTimeEstimated = true;
    }
    if (businessChanged) {
      if (outcome.recoveredAt !== undefined) manifest.recoveredAt = outcome.recoveredAt;
      manifest.state = outcome.state; manifest.outcomeSource = outcome.source;
      manifest.outcomeSummary = outcome.summary; manifest.errorKind = outcome.errorKind ?? '';
    }
    if (!options.capturePrepared && manifest.category === 'launch') {
      const next: number = options.nextLaunchAt ?? await ledgerNextLaunchAtAsync(filesDir, activityId);
      await checkpointSessionCaptureAsync(filesDir, activityId, manifest.endedAt, next, true, options.commitGuard,
        manifest.endTimeEstimated !== true);
    }
    await archiveLegacySessionOutputAsync_(filesDir, manifest, options.commitGuard);
    const files: LedgerFile[] = [];
    await scanDirAsync_(ledgerDirOf(filesDir, activityId), '', files, 0);
    manifest.files = files;
    if (options.inputKey !== undefined && maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程状态已变化，保留原证据等待恢复');
    assertEvidencePreparationCurrent(options.commitGuard);
    // 先保存原件清单，再确认Evidence持久提交；中途失败不允许调用方消费输入。
    if (previous !== JSON.stringify(manifest)) {
      manifest.revision = (manifest.revision ?? 0) + 1;
      await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest), options.commitGuard);
    }
    const evidence = await refreshSessionEvidenceAsync(filesDir, activityId, 'sealed', 'complete', [], options.commitGuard);
    assertEvidencePreparationCurrent(options.commitGuard);
    // 消费标记必须最后耐久发布。Evidence失败后的重试仍看到旧key，不能提前返回unchanged。
    if (options.inputKey !== undefined && manifest.recoveryInputKey !== options.inputKey) {
      manifest.recoveryInputKey = options.inputKey;
      manifest.revision = (manifest.revision ?? 0) + 1;
      await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest), options.commitGuard);
    }
    ledgerMarkDirty(filesDir, activityId);
    maintenanceCounters.changedCommits++;
    return { changed: true, outcomeRevision: manifest.revision ?? 0, evidenceRevision: evidence.revision, indexDirty: true };
  } finally { releaseEvidenceLease(filesDir, activityId); }
}

/** Evidence保存快照只读小型JSON，不能为了取revision再次核验全部原件。 */
async function readSessionEvidenceAsync_(filesDir: string, activityId: number): Promise<LedgerEvidenceRevision | undefined> {
  try { return JSON.parse(await fs.readText(ledgerDirOf(filesDir, activityId) + '/evidence-manifest.json')) as LedgerEvidenceRevision; }
  catch (_) { return undefined; }
}
interface LedgerEvidenceRevision { revision: number; }

/** 旧工作日志只按活动横幅精确补采；有native本局输出时不再次寻找全局轮转文件。 */
async function archiveLegacySessionOutputAsync_(filesDir: string, manifest: LedgerManifest,
  publishGuard: (() => boolean) | undefined = undefined): Promise<void> {
  assertEvidencePreparationCurrent(publishGuard);
  if (manifest.category !== 'launch' || manifest.mcDir.length === 0 || await nativeSessionIoAsync(filesDir, manifest.activityId) !== undefined) return;
  const plan = await readSessionCaptureAsync(filesDir, manifest.activityId);
  const archived = plan?.sources.find((item: CaptureSource): boolean => item.destination === 'game/mc_output.log');
  // 固定收据的原件仅核验，不能先覆盖目标再在record阶段发现sealed后返回。
  if (archived?.sealed === true || archived?.mode === 'owned') return;
  const directories: string[] = [manifest.mcDir];
  if (manifest.gameVersionId.length > 0) directories.unshift(manifest.mcDir + '/versions/' + manifest.gameVersionId);
  for (const directory of directories) {
    for (let index: number = 0; index <= 3; index++) {
      const source: string = directory + '/mc_output' + (index === 0 ? '' : '.' + index) + '.log';
      let file: fs.File | undefined;
      try {
        file = await fs.open(source, fs.OpenMode.READ_ONLY);
        const buffer = new ArrayBuffer(2048);
        const got: number = await fs.read(file.fd, buffer, { offset: 0, length: buffer.byteLength });
        const head: string = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(buffer, 0, got));
        const start: number = head.indexOf('##AMCL-SESSION-BEGIN');
        const end: number = head.indexOf('\n', start);
        const banner: string = start < 0 ? '' : head.substring(start, end < 0 ? head.length : end);
        const match = banner.match(new RegExp('"activityId"\\s*:\\s*(\\d+)'));
        if (match === null || Number(match[1]) !== manifest.activityId) continue;
        const destination: string = ledgerDirOf(filesDir, manifest.activityId) + '/game/mc_output.log';
        if (await fs.access(destination)) {
          // 重启后没有进程内复制缓存。已有 stdout 必须读全文核对：同内容只复用原件，
          // 不以临时文件替换改变 inode/指纹；不同内容也不授权覆盖历史归档或签发新收据。
          const before: string = await evidenceFileStampAsync(source);
          const targetBefore: string = await evidenceFileStampAsync(destination);
          const digest: string = await evidenceFileDigestAsync(source);
          const targetDigest: string = await evidenceFileDigestAsync(destination);
          assertEvidencePreparationCurrent(publishGuard);
          if (before !== await evidenceFileStampAsync(source) || targetBefore !== await evidenceFileStampAsync(destination)) {
            throw new Error('旧游戏输出在核验期间变化，原件保留等待重试');
          }
          if (digest !== targetDigest) return;
        } else {
          await archiveFileAsync_(source, destination, publishGuard);
        }
        await recordArchivedSessionSourceAsync_(filesDir, manifest.activityId, source, publishGuard);
        return;
      } catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; /* 缺失候选不按mtime近似匹配。 */ }
      finally { if (file !== undefined) { try { await fs.close(file); } catch (_) {} } }
    }
  }
}

/** 小型基线文件更新由异步端完成，固定原件SHA与归档SHA一致后才保存legacy收据。 */
async function recordArchivedSessionSourceAsync_(filesDir: string, activityId: number, source: string,
  publishGuard: (() => boolean) | undefined = undefined): Promise<void> {
  assertEvidencePreparationCurrent(publishGuard);
  const path: string = ledgerDirOf(filesDir, activityId) + '/capture-sources.json';
  if (!await fs.access(path)) return;
  const plan = await readSessionCaptureAsync(filesDir, activityId);
  if (plan === undefined) return;
  const existing = plan.sources.find((item: CaptureSource): boolean => item.destination === 'game/mc_output.log');
  if (existing?.sealed === true || existing?.mode === 'owned') return;
  const destination: string = ledgerDirOf(filesDir, activityId) + '/game/mc_output.log';
  const digest: string = await evidenceFileDigestAsync(destination);
  if (digest !== await evidenceFileDigestAsync(source)) throw new Error('游戏输出归档内容校验失败');
  plan.sources = plan.sources.filter((item: CaptureSource): boolean => item.destination !== 'game/mc_output.log');
  plan.sources.push({ source: source, destination: 'game/mc_output.log', baseline: '', captured: await evidenceFileStampAsync(source),
    capturedBytes: (await fs.stat(destination)).size, capturedSha256: digest, sealed: true, mode: 'legacy-archive',
    state: 'complete', reason: '', attribution: 'exact' });
  await writeEvidenceTextAtomicAsync(path, JSON.stringify(plan), publishGuard);
}

/**
 * 冷启动收尾：把上次进程留下的 `RUNNING` 账本标成 `INTERRUPTED`。
 *
 * 只认「进程启动时发现残留 RUNNING」这一个判据，不靠超时猜 —— 一个真正在跑的活动
 * 不可能出现在新进程刚启动的时刻。
 *
 * @returns 被标定的条数
 */
export function ledgerResolveStale(filesDir: string, pendingUpdateIds: number[] = []): number {
  let n = 0;
  for (let id of listActivityIds(filesDir)) {
    let mp = manifestPath(filesDir, id);
    let m = parseLedgerManifest(readTextFile(mp));
    if (m === null || m.state !== LedgerState.RUNNING) continue;
    // 覆盖安装会主动结束旧进程，已经核实事务身份的更新允许等待新版本确认。
    // 仅豁免明确传入且类别匹配的主活动；下载子任务、普通游戏和任意其他 ID 仍正常收尾。
    if (m.category === 'app_update' && pendingUpdateIds.indexOf(id) >= 0) continue;
    m.state = LedgerState.INTERRUPTED;
    m.outcomeSource = 'ledger.resolveStale';
    if (m.outcomeSummary.length === 0) {
      m.outcomeSummary = '上次应用退出时该操作尚未结束（进程被结束或崩溃）';
    }
    // 重启时只能确定发现时间，保留此值供采集时间窗使用，同时标记它不是真实结束时间。
    m.recoveredAt = Date.now();
    if (m.endedAt <= 0) { m.endedAt = m.recoveredAt; m.endTimeEstimated = true; }
    archiveAuxiliaryFiles_(filesDir, m);
    archiveSessionLogs(filesDir, m);
    m.files = scanDir(filesDir, id);
    if (!writeTextFile(mp, JSON.stringify(m))) {
      AppLogger.error(TAG, 'stale recovery manifest save failed', null, LOG_DOMAIN, id);
      continue;
    }
    refreshSessionEvidence(filesDir, id, 'recovered', 'partial', [
      '活动在上次进程结束前没有收到正常终态',
    ]);
    n++;
  }
  if (n > 0) {
    rebuildIndex(filesDir);
    AppLogger.info(TAG, 'resolveStale marked ' + n + ' interrupted activities', LOG_DOMAIN);
  }
  archivePlatformEventFiles_(filesDir);
  ledgerArchiveCompletedSessions(filesDir);
  prune(filesDir);
  return n;
}

/**
 * 把上一次进程收到的 HiAppEvent 文件按接收时刻归入最近的游戏活动。
 *
 * 事件可能在应用重启后才投递，不能要求它在 ledgerEnd 期间到达；
 * 找不到可信时间窗时保留 pending 文件，下一次启动继续尝试。
 */
export function archivePlatformEventFiles_(filesDir: string): void {
  const root: string = filesDir + '/logs/platform-events';
  if (!isDir(root)) return;
  let names: string[] = [];
  try { names = fs.listFileSync(root); } catch (e) { return; }
  const ids: number[] = listActivityIds(filesDir).sort((a: number, b: number): number => a - b);
  for (const name of names) {
    if (!name.startsWith('event-') || !name.endsWith('.json')) continue;
    const path: string = root + '/' + name;
    const text: string = readTextFile(path);
    let event: Record<string, Object>;
    try { event = JSON.parse(text) as Record<string, Object>; } catch (e) { continue; }
    let params: Record<string, Object> = {};
    try {
      const raw = event['params'];
      if (typeof raw === 'string') params = JSON.parse(raw as string) as Record<string, Object>;
      else if (raw !== undefined && typeof raw === 'object') params = raw as Record<string, Object>;
    } catch (e) { continue; }
    const eventAt: number = num_(event, 'eventAt', num_(params, 'time', 0));
    const pid: number = num_(params, 'pid', 0);
    const explicitId: number = num_(event, 'activityId', 0);
    // 没有活动主键时，原归属规则必须同时具有事件时间和进程 PID；缺少任一项，
    // 后面的逐活动匹配必然没有候选。先保留原事件并跳过这轮磁盘扫描，避免冷启动/
    // 前台恢复为每个旧退出通知反复同步读取全部 manifest，挤占首页的 UI 线程。
    // 这不是永久缓存：下次调用仍重新读取事件；带主键/nonce 或完整时间/PID 的
    // 迟到事件继续走原匹配、归档和终态裁决，不能用 receivedAt 猜测缺失事件时间。
    if (explicitId <= 0 && (eventAt <= 0 || pid <= 0)) continue;
    const candidates: LedgerManifest[] = [];
    for (let index = 0; index < ids.length; index++) {
      const manifest = ledgerManifest(filesDir, ids[index]);
      if (manifest === null || manifest.category !== 'launch') continue;
      if (explicitId > 0) {
        if (manifest.activityId === explicitId && str_(event, 'runNonce') === manifest.runNonce) candidates.push(manifest);
        continue;
      }
      // 不以接收时间猜测事件时间，也不把事件归到未来启动。
      if (eventAt <= 0 || pid <= 0) continue;
      let ownsPid: boolean = manifest.ownerPid === pid;
      for (const filename of ['capture-host.json', 'capture-game.json']) {
        try {
          const capture = JSON.parse(readTextFile(ledgerDirOf(filesDir, manifest.activityId) + '/' + filename)) as Record<string, Object>;
          if (num_(capture, 'pid', 0) === pid) ownsPid = true;
        } catch (e) { /* 旧记录缺进程状态 */ }
      }
      if (!ownsPid) continue;
      let upper: number = manifest.endedAt > 0 ? manifest.endedAt : Number.MAX_SAFE_INTEGER;
      for (const nextId of ids) {
        const next = ledgerManifest(filesDir, nextId);
        if (nextId > manifest.startedAt && next?.category === 'launch') { upper = Math.min(upper, nextId); break; }
      }
      if (eventAt >= manifest.startedAt && eventAt <= upper) candidates.push(manifest);
    }
    if (candidates.length !== 1) continue; // 无法唯一归属的原始事件保留在 pending。
    const manifest = candidates[0];
    const eventName: string = str_(event, 'name');
    const crash: boolean = eventName === 'APP_CRASH';
    const targetDir: string = ledgerDirOf(filesDir, manifest.activityId) + '/system';
    const targetName: string = (crash ? 'crash-report-' : 'exit-event-') + name;
    let externalComplete: boolean = true;
    const external = params['external_log'];
    if (crash && Array.isArray(external)) {
      let index: number = 0;
      for (const value of external as Object[]) {
        if (typeof value !== 'string') continue;
        const source: string = value as string;
        if (!source.startsWith('/') || source.indexOf('/../') >= 0) continue;
        const destination: string = targetDir + '/crash-report-' + name + '-external-' + index++ + '.log';
        archiveFile(source, destination);
        if (fileBytes(destination) === 0) externalComplete = false;
      }
    }
    archiveFile(path, targetDir + '/' + targetName);
    if (fileBytes(targetDir + '/' + targetName) === 0) continue;
    applyPlatformOutcome_(manifest, text);
    manifest.files = scanDir(filesDir, manifest.activityId);
    if (!writeTextFile(manifestPath(filesDir, manifest.activityId), JSON.stringify(manifest))) continue;
    refreshSessionEvidence(filesDir, manifest.activityId, 'recovered', 'partial',
      externalComplete ? [] : ['平台外部报告尚未完整复制，等待重试']);
    if (externalComplete) { try { fs.unlinkSync(path); } catch (e) { /* 重试幂等 */ } }
  }
}

/** 平台仅补足没有显式游戏终态的活动，正文中的关键字不参与判定。 */
function applyPlatformOutcome_(manifest: LedgerManifest, eventText: string): void {
  let event: Record<string, Object>;
  try { event = JSON.parse(eventText) as Record<string, Object>; } catch (e) { return; }
  const name: string = str_(event, 'name');
  const reason: string = str_(event, 'reason');
  const platformCrash: boolean = name === 'APP_CRASH' || (name === 'LAST_EXIT_REASON'
    && ['CPP_CRASH', 'JS_ERROR', 'APP_FREEZE'].indexOf(reason) >= 0);
  // 本函数只接收上方已经精确归属的事件。晚到真实崩溃可纠正日志/退出请求推导结果，
  // 但不能覆盖下载等任务自己的显式终态；普通 NORMAL/KILLED 也不降级已有游戏结论。
  const recomputable: boolean = manifest.category === 'launch'
    && (manifest.outcomeSource === 'session.jvm-exit' || manifest.outcomeSource === 'session.full-evidence');
  if (manifest.state !== LedgerState.RUNNING && manifest.state !== LedgerState.INTERRUPTED
    && !(platformCrash && recomputable)) return;
  const eventAt: number = num_(event, 'eventAt', 0);
  if (eventAt >= manifest.startedAt && eventAt <= Date.now()) {
    manifest.endedAt = eventAt;
    manifest.endTimeEstimated = false;
  }
  if (platformCrash) {
    manifest.state = LedgerState.CRASHED;
    manifest.outcomeSource = 'platform.' + name;
    manifest.outcomeSummary = '系统报告应用崩溃，详见本次活动的平台证据';
  } else if (name === 'LAST_EXIT_REASON' && ['NORMAL', 'UPGRADE', 'USER_REQUEST'].indexOf(reason) >= 0) {
    manifest.state = LedgerState.ABORTED;
    manifest.outcomeSource = 'platform.lastExitReason';
    manifest.outcomeSummary = '应用结束，本次活动没有报告游戏终态（' + reason + '）';
  } else if (name === 'APP_KILLED' || name === 'LAST_EXIT_REASON') {
    manifest.state = LedgerState.INTERRUPTED;
    manifest.outcomeSource = 'platform.' + name;
    manifest.outcomeSummary = '应用由系统结束，游戏终态未知';
  }
}

/** 本进程已核验的复制指纹；源或目标替换/增长即失效，重启后重新核验一次。 */
const archivedFingerprints: Map<string, string> = new Map<string, string>();

/** 文件复制到临时路径后原子改名；未变化的高精度来源跳过重复复制，失败保留旧副本。 */
function archiveFile(source: string, destination: string): void {
  if (fileBytes(source) <= 0) return;
  const temporary = destination + '.partial';
  try {
    const before: string = evidenceFileStamp(source);
    const stat = fs.statSync(source);
    // 老 SDK 只有秒级时间时不缓存，避免同秒等长改写被误当成未变化。
    const precise: boolean = stat.mtimeNs !== undefined && stat.ctimeNs !== undefined;
    if (precise && fileBytes(destination) > 0
      && archivedFingerprints.get(destination) === before + '|' + evidenceFileStamp(destination)) return;
    const slash: number = destination.lastIndexOf('/');
    if (slash > 0) ensureDirSync(destination.substring(0, slash));
    fs.copyFileSync(source, temporary);
    if (before !== evidenceFileStamp(source) || fileBytes(source) !== fileBytes(temporary)) {
      throw new Error('日志复制期间来源变化，等待下次重试');
    }
    fs.renameSync(temporary, destination);
    if (precise) {
      if (archivedFingerprints.size >= 4096) archivedFingerprints.clear();
      archivedFingerprints.set(destination, before + '|' + evidenceFileStamp(destination));
    }
  } catch (e) {
    try { fs.unlinkSync(temporary); } catch (ignored) { /* 临时文件可能尚未创建 */ }
    AppLogger.warn(TAG, 'archive failed: ' + source, e, LOG_DOMAIN);
  }
}

function archiveSessionLogs(filesDir: string, manifest: LedgerManifest): void {
  if (manifest.category !== 'launch') return;
  const dir = ledgerDirOf(filesDir, manifest.activityId);
  const nextLaunchAt: number = listActivityIds(filesDir).filter((id: number): boolean =>
    id > manifest.startedAt && ledgerManifest(filesDir, id)?.category === 'launch')
    .sort((a: number, b: number): number => a - b)[0] ?? 0;
  // 辅助日志不依赖 stdout 横幅，JNI 初始化前崩溃也能留下 latest/JVM/hs_err。
  try { checkpointSessionCapture(filesDir, manifest.activityId, manifest.endedAt, nextLaunchAt,
    manifest.state !== LedgerState.RUNNING); }
  catch (e) { AppLogger.error(TAG, 'capture checkpoint failed', e, LOG_DOMAIN, manifest.activityId); }
  if (nativeSessionIo(filesDir, manifest.activityId) !== undefined) return;
  if (manifest.mcDir.length === 0) return;
  const archived = readSessionCapture(filesDir, manifest.activityId)?.sources.find(
    (item: CaptureSource): boolean => item.destination === 'game/mc_output.log');
  // 同步兼容入口同样保护固定封账收据，不能在 record 阶段才发现原件已被覆盖。
  if (archived?.sealed === true || archived?.mode === 'owned') return;
  const location = findSessionLog(manifest.mcDir, manifest.gameVersionId, manifest.startedAt);
  if (location.exact && location.path.length > 0) {
    const destination: string = dir + '/game/mc_output.log';
    if (fs.accessSync(destination)) {
      // 与异步封账一致：已有同内容副本只读复用，不同正文保留旧归档且不重新签收。
      try {
        const before: string = evidenceFileStamp(location.path);
        const targetBefore: string = evidenceFileStamp(destination);
        const digest: string = evidenceFileDigestSync(location.path);
        const targetDigest: string = evidenceFileDigestSync(destination);
        if (before !== evidenceFileStamp(location.path) || targetBefore !== evidenceFileStamp(destination)
          || digest !== targetDigest) return;
      } catch (e) { AppLogger.warn(TAG, 'legacy output verify failed', e, LOG_DOMAIN, manifest.activityId); return; }
    } else {
      archiveFile(location.path, destination);
    }
    recordArchivedSessionSource(filesDir, manifest.activityId, location.path, 'game/mc_output.log');
  }
  // 无基线的旧记录只恢复有精确横幅的 stdout，不靠全局文件修改时间拼接别局证据。

}

/** 非 launch 活动也可能产生 installer/agent 等独立文件，统一在终态归档。 */
function archiveAuxiliaryFiles_(filesDir: string, manifest: LedgerManifest): void {
  // launch 附属文件已纳入来源基线；安装任务应由各任务按 activityId 直接落盘。
  // 禁止把任意全局 agent/MG/installer 的最新文件拼进一条旧活动。
}

/** 升级后补齐仍在轮转窗口内的已结束会话，不读取运行中的文件作为终态快照。 */
export function ledgerArchiveCompletedSessions(filesDir: string): void {
  for (const id of listActivityIds(filesDir)) {
    const manifest = ledgerManifest(filesDir, id);
    if (manifest === null || manifest.state === LedgerState.RUNNING) continue;
    archiveSessionLogs(filesDir, manifest);
  }
}

/** 列出账本根目录下所有活动 id（按时间倒序，最新在前）。 */
export function listActivityIds(filesDir: string): number[] {
  let out: number[] = [];
  let root = ledgerRoot(filesDir);
  if (!isDir(root)) return out;
  try {
    for (let name of fs.listFileSync(root)) {
      if (name === LEDGER_INDEX_NAME) continue;
      let id = Number.parseInt(name, 10);
      if (Number.isNaN(id) || id <= 0) continue;
      if (!isDir(root + '/' + name)) continue;
      out.push(id);
    }
  } catch (e) { /* ignore */ }
  out.sort((a: number, b: number): number => b - a);
  return out;
}

/** 该活动是否有账本（实探目录，不信任索引）。 */
export function ledgerHas(filesDir: string, activityId: number): boolean {
  if (filesDir.length === 0 || activityId <= 0) return false;
  return isDir(ledgerDirOf(filesDir, activityId));
}

/** 读一条账本的清单。 */
export function ledgerManifest(filesDir: string, activityId: number): LedgerManifest | null {
  return parseLedgerManifest(readTextFile(manifestPath(filesDir, activityId)));
}

/** 该账本实际有哪些 part（UI 分段切换据此生成，不显示空段）。 */
export function ledgerParts(filesDir: string, activityId: number): LedgerPart[] {
  let out: LedgerPart[] = [];
  let dir = ledgerDirOf(filesDir, activityId);
  let all: LedgerPart[] = [
    LedgerPart.LAUNCHER, LedgerPart.GAME, LedgerPart.MC_LATEST,
    LedgerPart.JVM, LedgerPart.CRASH_REPORT, LedgerPart.SYSTEM_CRASH,
  ];
  for (let p of all) {
    if (p === LedgerPart.LAUNCHER) {
      // 启动器段有三片，任一片非空即算存在
      if (fileBytes(dir + '/launcher/launcher-host.log') > 0
        || fileBytes(dir + '/launcher/launcher-game.log') > 0
        || fileBytes(dir + '/launcher.log') > 0
        || fileBytes(dir + '/launcher.tail.log') > 0
        || fileBytes(dir + '/launcher.tail.1.log') > 0) {
        out.push(p);
      }
      continue;
    }
    if (p === LedgerPart.GAME) {
      // 游戏输出可能不在账本目录里，而是按会话横幅反查到的 mc_output.log
      if (fileBytes(dir + '/' + partFileName(p)) > 0
        || fileBytes(dir + '/game/mc_output.log') > 0
        || resolveGameLogForLedger_(filesDir, activityId).length > 0) {
        out.push(p);
      }
      continue;
    }
    if (fileBytes(dir + '/' + partFileName(p)) > 0
      || (p === LedgerPart.MC_LATEST && fileBytes(dir + '/game/logs/latest.log') > 0)
      || (p === LedgerPart.JVM && fileBytes(dir + '/jvm/jvm-stderr.log') > 0)
      || (p === LedgerPart.CRASH_REPORT && isDir(dir + '/crash-reports'))
      || (p === LedgerPart.SYSTEM_CRASH && isDir(dir + '/system'))) out.push(p);
  }
  return out;
}

/**
 * 按会话反查该活动对应的游戏日志落点。
 *
 * 依赖 manifest 里存的 `mcDir` + `gameVersionId`，交给 `findSessionLog` 用 native 写的
 * 会话横幅（`##AMCL-SESSION-BEGIN`）精确匹配。找不到返回空串。
 */
function resolveGameLogForLedger_(filesDir: string, activityId: number): string {
  let m = ledgerManifest(filesDir, activityId);
  if (m === null || m.mcDir.length === 0) return '';
  return findSessionLog(m.mcDir, m.gameVersionId, activityId).path;
}

/**
 * 读某个 part 的正文。
 *
 * 启动器段按 **head + tail.1 + tail** 拼回来（native 的头尾双文件方案，见
 * `amcl_log.cpp` 的 writeToScopeLocked 注释）。这样活动开始阶段与最近发生的事
 * 两头都在 —— 只留尾会丢启动期根因（P1-4），只留头会丢失败瞬间的现场。
 *
 * @param maxBytes 0 = 不限（读全量）
 */
export function ledgerRead(filesDir: string, activityId: number,
  part: LedgerPart, maxBytes: number = 0): string {
  let dir = ledgerDirOf(filesDir, activityId);
  if (part === LedgerPart.GAME) {
    // 优先读完整会话快照，运行中与升级前记录回退到原始输出。
    let inLedger = readTextFile(dir + '/' + partFileName(part), maxBytes);
    if (inLedger.length === 0) inLedger = readTextFile(dir + '/game/mc_output.log', maxBytes);
    if (inLedger.length > 0) return inLedger;
    let loc = resolveGameLogForLedger_(filesDir, activityId);
    if (loc.length === 0) return '';
    return readTextFile(loc, maxBytes);
  }
  if (part !== LedgerPart.LAUNCHER) {
    let direct = readTextFile(dir + '/' + partFileName(part), maxBytes);
    if (direct.length > 0) return direct;
    if (part === LedgerPart.MC_LATEST) return readTextFile(dir + '/game/logs/latest.log', maxBytes);
    if (part === LedgerPart.JVM) return readTextFile(dir + '/jvm/jvm-stderr.log', maxBytes);
    if (part === LedgerPart.SYSTEM_CRASH) return readTextFile(dir + '/system/crash-tail.log', maxBytes);
    if (part === LedgerPart.CRASH_REPORT) {
      let reports: string[] = [];
      try { reports = fs.listFileSync(dir + '/crash-reports'); } catch (e) { reports = []; }
      for (const report of reports) {
        const text = readTextFile(dir + '/crash-reports/' + report, maxBytes);
        if (text.length > 0) return text;
      }
    }
    return '';
  }
  let head = readTextFile(dir + '/launcher/launcher-host.log')
    + readTextFile(dir + '/launcher/launcher-game.log') + readTextFile(dir + '/launcher.log');
  let tail1 = readTextFile(dir + '/launcher.tail.1.log');
  let tail = readTextFile(dir + '/launcher.tail.log');
  let s = head;
  if (tail1.length > 0) s += tail1;
  if (tail.length > 0) s += tail;
  if (maxBytes > 0 && s.length > maxBytes) {
    // 超限时保尾（用户最关心「最后发生了什么」），头部已在 head 片里单独可读
    s = s.slice(s.length - maxBytes);
  }
  return s;
}

/** 某个 part 的字节数（启动器段为三片之和）。 */
export function ledgerPartBytes(filesDir: string, activityId: number, part: LedgerPart): number {
  let dir = ledgerDirOf(filesDir, activityId);
  if (part === LedgerPart.GAME && fileBytes(dir + '/game.log') === 0) {
    if (fileBytes(dir + '/game/mc_output.log') > 0) return fileBytes(dir + '/game/mc_output.log');
    return fileBytes(resolveGameLogForLedger_(filesDir, activityId));
  }
  if (part !== LedgerPart.LAUNCHER) {
    const direct = fileBytes(dir + '/' + partFileName(part));
    if (direct > 0) return direct;
    if (part === LedgerPart.MC_LATEST) return fileBytes(dir + '/game/logs/latest.log');
    if (part === LedgerPart.JVM) return fileBytes(dir + '/jvm/jvm-stderr.log');
    if (part === LedgerPart.SYSTEM_CRASH) return fileBytes(dir + '/system/crash-tail.log');
    if (part === LedgerPart.CRASH_REPORT) {
      let total = 0;
      try {
        for (const report of fs.listFileSync(dir + '/crash-reports')) total += fileBytes(dir + '/crash-reports/' + report);
      } catch (e) { /* 无报告 */ }
      return total;
    }
    return 0;
  }
  return fileBytes(dir + '/launcher/launcher-host.log')
    + fileBytes(dir + '/launcher/launcher-game.log') + fileBytes(dir + '/launcher.log')
    + fileBytes(dir + '/launcher.tail.1.log')
    + fileBytes(dir + '/launcher.tail.log');
}

/**
 * 导出一条账本为可外发文本。
 *
 * **所有离开设备的路径（剪贴板 / 系统分享 / 上传 AMCL-web / 上传 LogShare）必须走这里**
 * —— 由它统一补环境头并过 `sanitizeLogForExport` 脱敏。绕过它就等于绕过脱敏。
 */
export function ledgerExport(filesDir: string, activityId: number,
  target: LogExportTarget, maxBytes: number = 0): string {
  let m = ledgerManifest(filesDir, activityId);
  // 环境头统一由 DiagnosticBundle 生成（设备 / 系统自动取），manifest 里存的环境字段
  // 只作为「当时」的快照补充 —— 避免同一份信息两处维护、两处口径。
  let env: DiagnosticEnv = {
    appVersion: m !== null && m.appVersion.length > 0 ? m.appVersion : undefined,
    mcVersion: m !== null && m.gameVersionId.length > 0 ? m.gameVersionId : undefined,
    note: '活动日志导出 · ' + (m !== null ? m.category : '') ,
  };
  let s = DiagnosticBundle.buildEnvHeader(env) + '\n\n===== 活动 =====\n';
  if (m !== null) {
    s += '类别: ' + m.category + '\n';
    s += '对象: ' + m.title + '\n';
    s += '结局: ' + ledgerStateLabel(m.state)
      + (m.outcomeSource.length > 0 ? '（来源 ' + m.outcomeSource + '）' : '') + '\n';
    if (m.outcomeSummary.length > 0) s += '摘要: ' + m.outcomeSummary + '\n';
    if (m.errorKind.length > 0) s += '错误类型: ' + m.errorKind + '\n';
    s += '开始: ' + new Date(m.startedAt).toISOString() + '\n';
    if (m.endedAt > 0) s += '结束: ' + new Date(m.endedAt).toISOString() + '\n';
    if (m.gameVersionId.length > 0) {
      s += '游戏版本: ' + m.gameVersionId + '\n';
      if (m.loaderType.length > 0) s += '加载器: ' + m.loaderType + ' ' + m.loaderVersion + '\n';
      if (m.jdk.length > 0) s += 'JDK: ' + m.jdk + '\n';
    }
  } else {
    s += '(清单缺失，仅导出日志正文)\n';
  }

  // ⭐ 2026-09-06（日志系统重构 · P5）：各 part **先分配配额再读**，不再「拼完保尾」。
  //
  // 旧做法把所有 part 拼成一整段再交给 truncateUtf8Tail 保尾截断，而拼装顺序是
  // 环境头 → 活动摘要 → LAUNCHER → GAME → …，且 ledgerRead(GAME) 不传上限会读到 16 MB。
  // ⇒ 游戏日志一大，环境头、活动摘要、启动器日志**全部落在被丢掉的头部**，
  //   上传出去的正文可能一行启动器日志都没有 —— 而那正是「AMCL 自己做了什么决定」
  //   （classpath / JDK / 渲染后端）的唯一记录（调研 N-7）。
  //
  // 现在：谁大谁被截，而不是谁靠前谁活下来。头部（环境头 + 活动摘要）永远完整保留 ——
  // 它只有几百字节，却是判断「这份日志属于哪个包、哪个版本」的唯一依据。
  let parts: LedgerPart[] = ledgerParts(filesDir, activityId);
  let budget = maxBytes > 0 ? maxBytes : exportLimitOf(target);
  let headerBytes = utf8ByteLength(s);
  // 给每个 part 的段标题也留出余量，否则标题会把正文挤出配额。
  let partBudget = budget - headerBytes - parts.length * 64;
  if (partBudget < 0) partBudget = 0;

  let demands: ExportPartDemand[] = [];
  for (let p of parts) {
    demands.push({
      id: ledgerPartLabel(p),
      bytes: ledgerExportPartBytes_(filesDir, activityId, p),
      priority: ledgerPartExportPriority_(p),
      floorBytes: ledgerPartExportFloor_(p),
    });
  }
  let grants: ExportPartGrant[] = allocateExportBudget(demands, partBudget);

  for (let i = 0; i < parts.length; i++) {
    let p = parts[i];
    let g = grants[i];
    s += '\n===== ' + ledgerPartLabel(p) + ' =====\n';
    if (g.granted <= 0) {
      s += '(配额不足，本段未包含；请用「导出完整日志」单独获取)\n';
      continue;
    }
    // 超配额的段保**头 + 尾**：启动期根因在头部，失败现场在尾部，只保一端必丢一半。
    let body = ledgerReadForExport_(filesDir, activityId, p, g.granted);
    // 兜底钳制：上面按**文件字节**分预算，解码后理应一致，但不赌它。
    if (utf8ByteLength(body) > g.granted) {
      body = truncateUtf8HeadTail(body, g.granted);
    }
    s += body;
  }
  // 仍然过统一漏斗：脱敏是它的主职责，截断在这里只是兜底（正常不该再触发）。
  return sanitizeLogForExport(s, target, maxBytes);
}

/**
 * 导出用的 part 读取：**保头 + 保尾**，且读取量不超过配额。
 *
 * ⚠️ **为什么不能直接用 `ledgerRead(part, maxBytes)`**（2026-09-06 自审抓出的缺陷）：
 * `ledgerRead` 的三条路径**全是保尾读** ——
 *   · `readTextFile` 的 `start = total - maxBytes`；
 *   · `readLogFileTail` 顾名思义；
 *   · LAUNCHER 分支的 `s.slice(s.length - maxBytes)`。
 * 于是它返回的内容**已经把头部丢掉了**，再对它调 `truncateUtf8HeadTail` 是死代码 ——
 * 那时候「头」已经是原文的中段。
 *
 * 这个缺陷在孤立单测里看不见：`allocateExportBudget` 与 `truncateUtf8HeadTail` 各自都对，
 * **错的是组合**。⇒ 判据：分配 + 截断 + 读取三者是一条链，只测两端证明不了中间。
 *
 * 现在按配额拆成头尾两次有界读，总读取量仍然不超过 `maxBytes`。
 */
function ledgerReadForExport_(filesDir: string, activityId: number,
  part: LedgerPart, maxBytes: number): string {
  let total = ledgerExportPartBytes_(filesDir, activityId, part);
  if (total <= 0) return '';
  // 装得下就整段读，不必拆
  if (total <= maxBytes) return ledgerRead(filesDir, activityId, part, maxBytes);

  const MARKER_RESERVE = 96;
  let usable = maxBytes - MARKER_RESERVE;
  if (usable <= 0) return ledgerRead(filesDir, activityId, part, maxBytes);
  // 头 30%：根因通常比现场短，但完全不留头就等于把一整类问题排除在证据之外（P1-4）。
  let headBudget = Math.floor(usable * 0.3);
  let tailBudget = usable - headBudget;
  if (headBudget <= 0) return ledgerRead(filesDir, activityId, part, maxBytes);

  let dir = ledgerDirOf(filesDir, activityId);
  let headPath = '';
  if (part === LedgerPart.LAUNCHER) {
    // 账本的启动器段本来就是「头文件 + 尾文件」两片，头片就是 launcher.log ——
    // 那正是 native 侧 writeToScopeLocked 刻意留下的活动早期内容。
    headPath = dir + '/launcher.log';
  } else if (part === LedgerPart.GAME) {
    headPath = fileBytes(dir + '/' + partFileName(part)) > 0
      ? dir + '/' + partFileName(part)
      : fileBytes(dir + '/game/mc_output.log') > 0
        ? dir + '/game/mc_output.log' : resolveGameLogForLedger_(filesDir, activityId);
  } else if (part === LedgerPart.MC_LATEST) {
    headPath = fileBytes(dir + '/' + partFileName(part)) > 0
      ? dir + '/' + partFileName(part) : dir + '/game/logs/latest.log';
  } else if (part === LedgerPart.JVM) {
    headPath = fileBytes(dir + '/' + partFileName(part)) > 0
      ? dir + '/' + partFileName(part) : dir + '/jvm/jvm-stderr.log';
  } else {
    headPath = dir + '/' + partFileName(part);
  }

  let headText = headPath.length > 0 ? readLogFileHead(headPath, headBudget) : '';
  let tailText = ledgerRead(filesDir, activityId, part, tailBudget);
  if (headText.length === 0) return tailText;
  if (tailText.length === 0) return headText;

  let omitted = total - utf8ByteLength(headText) - utf8ByteLength(tailText);
  if (omitted < 0) omitted = 0;
  return headText + '\n...[中间省略 ' + omitted + ' 字节；保留头 '
    + utf8ByteLength(headText) + ' + 尾 ' + utf8ByteLength(tailText) + ' 字节]...\n' + tailText;
}

/**
 * 导出时该 part 的字节数。
 * ⚠️ 与 `ledgerPartBytes` 的区别：GAME 段的正文不在账本目录里，而是按会话横幅
 * 反查到的 `mc_output.log`，所以要额外问一次文件大小，否则配额会按 0 分配。
 */
function ledgerExportPartBytes_(filesDir: string, activityId: number, p: LedgerPart): number {
  let n = ledgerPartBytes(filesDir, activityId, p);
  if (n > 0) return n;
  if (p === LedgerPart.GAME) {
    let loc = resolveGameLogForLedger_(filesDir, activityId);
    if (loc.length > 0) return fileBytes(loc);
  }
  return 0;
}

/**
 * 导出优先级（越小越先拿到保底配额）。**与拼装顺序无关** —— 拼装按阅读顺序，
 * 配额按信息密度。
 *
 * 崩溃报告通常只有几 KB，但它往往**就是答案**；游戏日志可达 16 MB，
 * 而其中绝大部分是与故障无关的正常输出。按体积分配等于按噪声分配。
 */
function ledgerPartExportPriority_(p: LedgerPart): number {
  if (p === LedgerPart.CRASH_REPORT) return 1;
  if (p === LedgerPart.SYSTEM_CRASH) return 1;
  if (p === LedgerPart.LAUNCHER) return 2;
  if (p === LedgerPart.GAME) return 3;
  if (p === LedgerPart.MC_LATEST) return 4;
  return 5;
}

/** 该 part 的保底配额：只要总预算够，它至少能拿到这么多。 */
function ledgerPartExportFloor_(p: LedgerPart): number {
  if (p === LedgerPart.CRASH_REPORT) return 32 * 1024;
  if (p === LedgerPart.SYSTEM_CRASH) return 32 * 1024;
  if (p === LedgerPart.LAUNCHER) return 48 * 1024;
  if (p === LedgerPart.GAME) return 64 * 1024;
  if (p === LedgerPart.MC_LATEST) return 16 * 1024;
  return 8 * 1024;
}

/** 页面禁用与实际删除共用同一保护判据；确认后仍须重新检查。 */
export function ledgerRemovalBlockReason(filesDir: string, activityId: number): string {
  if (isEvidenceDeleting(filesDir, activityId)) return '活动日志正在删除，请稍后重试';
  if (hasEvidenceLease(filesDir, activityId)) return '日志正在读取或导出，请稍后删除';
  if (ledgerManifest(filesDir, activityId)?.state === LedgerState.RUNNING) {
    return '活动仍在进行中，请结束后再删除日志';
  }
  if (ledgerManifest(filesDir, activityId)?.pinned === true) return '这条活动已设为保留，请先取消保留后再删除';
  return '';
}

export function ledgerClearBlockReason(filesDir: string): string {
  for (const id of listActivityIds(filesDir)) {
    const reason: string = ledgerRemovalBlockReason(filesDir, id);
    if (reason.length > 0) return reason;
  }
  return '';
}

/** 删除一条账本。 */
export function ledgerRemove(filesDir: string, activityId: number): void {
  assertCanonicalIdle_(filesDir, activityId);
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程仍活跃或状态未知，暂时无法清理日志');
  const reason: string = ledgerRemovalBlockReason(filesDir, activityId);
  if (reason.length > 0) throw new Error(reason);
  if (g_scopeSink !== null) {
    try { g_scopeSink.end(activityId); } catch (e) { /* ignore */ }
  }
  const directory: string = ledgerDirOf(filesDir, activityId);
  if (!tryClaimEvidenceDeletion(filesDir, activityId)) throw new Error('日志正在读取或删除，请稍后重试');
  try {
    removeDirRecursive(directory);
    if (fs.accessSync(directory)) throw new Error('部分日志未能删除，请重试；在线分享未受影响');
    // 兼容同步删除也必须确认父目录命名空间，才能向准入owner发布“确实已经移除”的事实。
    const parent = fs.openSync(ledgerRoot(filesDir), fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
    removeCachedEntry_(filesDir, activityId);
    ledgerMarkDirty(filesDir, activityId);
  } finally { releaseEvidenceDeletion(filesDir, activityId); }
}

/** 清空全部账本。 */
export function ledgerClear(filesDir: string): void {
  const ids: number[] = listActivityIds(filesDir);
  const reason: string = ledgerClearBlockReason(filesDir);
  if (reason.length > 0) throw new Error(reason);
  for (let id of ids) {
    ledgerRemove(filesDir, id);
  }
  scheduleMaintenance_(filesDir);
}

// ============================================================================
//  索引与淘汰
// ============================================================================

/** 扫目录重建索引。目录是唯一事实源，索引只是给 UI 的快照。 */
export function rebuildIndex(filesDir: string): LedgerEntry[] {
  maintenanceCounters.fullRebuilds++;
  let entries: LedgerEntry[] = [];
  for (let id of listActivityIds(filesDir)) {
    let m = ledgerManifest(filesDir, id);
    let e: LedgerEntry = {
      activityId: id,
      category: m !== null ? m.category : '',
      title: m !== null ? m.title : '',
      state: m !== null ? m.state : LedgerState.RUNNING,
      startedAt: m !== null ? m.startedAt : id,
      endedAt: m !== null ? m.endedAt : 0,
      bytes: 0,
      hasGame: fileBytes(ledgerDirOf(filesDir, id) + '/game.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/mc_output.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/logs/latest.log') > 0,
    };
    e.manifestRevision = m?.revision ?? 0;
    e.evidenceRevision = readSessionEvidence(filesDir, id)?.revision ?? 0;
    e.versionKey = (m?.mcDir ?? '') + '\n' + (m?.gameVersionId ?? '');
    e.pinned = m?.pinned === true;
    e.manifestDigest = m === null ? '' : JSON.stringify(m);
    e.bytesState = 'unknown';
    try { maintenanceCounters.activityScans++; e.bytes = ledgerBytesOf(filesDir, id); if (m !== null) e.bytesState = m.state === LedgerState.RUNNING ? 'writing' : 'current'; } catch (_) { /* 原件无法统计不解释为可信零字节。 */ }
    entries.push(e);
  }
  try {
    ensureDirSync(ledgerRoot(filesDir));
    const snapshot: LedgerIndexSnapshot = { schema: 2, entries: entries, bytesIncludeMetadata: true };
    if (maintenanceOwner && writeTextFile(indexPath(filesDir), JSON.stringify(snapshot))) maintenanceCounters.indexWrites++;
  } catch (e) { /* 索引写失败不影响读取（list 会退回扫目录） */ }
  indexCaches.set(filesDir, entries);
  return entries;
}

/**
 * 列出全部账本（最新在前）。
 *
 * 游戏按每版本保留，账本总数不受普通活动数量限制。优先读可重建索引，
 * 目录集合或格式变化时重建；结局读取仍以对应 manifest 为准。
 */
export function ledgerList(filesDir: string): LedgerEntry[] {
  // 索引是派生快照，正常列表无需递归遍历每局文件；目录集合变化或格式不符时重建。
  // 各活动的最新结局仍由消费者读取 manifest 合并，迟到的平台结局不会被旧索引遮蔽。
  try {
    const saved = JSON.parse(readTextFile(indexPath(filesDir))) as LedgerIndexSnapshot;
    const ids: number[] = listActivityIds(filesDir);
    if ((saved.schema === 1 || saved.schema === 2) && saved.bytesIncludeMetadata === true && Array.isArray(saved.entries) && saved.entries.length === ids.length
      && saved.entries.every((entry: LedgerEntry): boolean => Number.isSafeInteger(entry.activityId)
        && ids.includes(entry.activityId) && Number.isFinite(entry.bytes) && entry.bytes >= 0)
      && new Set<number>(saved.entries.map((entry: LedgerEntry): number => entry.activityId)).size === ids.length) {
      return saved.entries.slice().sort((left: LedgerEntry, right: LedgerEntry): number => right.activityId - left.activityId);
    }
  } catch (e) { /* 首次使用、旧索引或损坏时从原件重建，不返回假空列表。 */ }
  return rebuildIndex(filesDir);
}

/** 只读索引的具名结构，不将外部任意对象视为已核验账本。 */
interface LedgerIndexSnapshot { schema: number; entries: LedgerEntry[]; bytesIncludeMetadata: boolean; }

/** 被删除条目立即从内存投影移除，磁盘索引由同批维护最后发布一次。 */
function removeCachedEntry_(filesDir: string, activityId: number): void {
  const cache = indexCaches.get(filesDir);
  if (cache !== undefined) indexCaches.set(filesDir, cache.filter((entry: LedgerEntry): boolean => entry.activityId !== activityId));
  if (removalObserver !== undefined) removalObserver(filesDir, activityId);
}

/**
 * 单局统计返回unknown而不是成功的零字节。raw日志与内部清单使用同一目录口径；
 * failed/dirty统计不进入保留预算，不能依据旧bytes分类后删除活动。
 */
async function measureEntryAsync_(filesDir: string, activityId: number, cancelled?: () => boolean): Promise<LedgerEntry> {
  maintenanceCounters.activityScans++;
  const manifest = await ledgerManifestAsync(filesDir, activityId);
  const entry: LedgerEntry = {
    activityId: activityId, category: manifest?.category ?? '', title: manifest?.title ?? '',
    state: manifest?.state ?? LedgerState.RUNNING, startedAt: manifest?.startedAt ?? activityId,
    endedAt: manifest?.endedAt ?? 0, bytes: 0, hasGame: false,
    manifestRevision: manifest?.revision ?? 0, evidenceRevision: (await readSessionEvidenceAsync_(filesDir, activityId))?.revision ?? 0,
    versionKey: (manifest?.mcDir ?? '') + '\n' + (manifest?.gameVersionId ?? ''), pinned: manifest?.pinned === true,
    bytesState: 'unknown', manifestDigest: manifest === null ? '' : JSON.stringify(manifest),
  };
  if (manifest === null) return entry;
  try {
    const before: string = await metadataFingerprintAsync_(filesDir, activityId);
    const files: LedgerFile[] = [];
    await scanDirAsync_(ledgerDirOf(filesDir, activityId), '', files, 0, true, cancelled);
    for (const file of files) {
      entry.bytes += file.bytes;
      if (file.bytes > 0 && ['game.log', 'game/mc_output.log', 'game/logs/latest.log', 'mc-latest.log'].includes(file.name)) entry.hasGame = true;
    }
    const after: string = await metadataFingerprintAsync_(filesDir, activityId);
    entry.metadataFingerprint = after;
    entry.bytesState = before !== after ? 'unknown' : manifest.state === LedgerState.RUNNING ? 'writing' : 'current';
  } catch (error) {
    if (cancelled !== undefined && cancelled()) throw error as Error;
    entry.bytesState = 'unknown';
    AppLogger.warn(TAG, '活动占用无法核实: ' + activityId, error, LOG_DOMAIN);
  }
  return entry;
}

/**
 * 固定受控发布文件的有界变化身份，不递归日志目录。metadata缺失是可表示状态，EIO必须失败。
 * 有纳秒mtime/ctime时使用stamp快速验证；旧SDK读取有界元数据SHA，绝不凭秒级时间+长度认未变。
 */
async function metadataFingerprintAsync_(filesDir: string, activityId: number): Promise<string> {
  const directory: string = ledgerDirOf(filesDir, activityId);
  const identity: string[] = [];
  for (const name of ['manifest.json', 'evidence-manifest.json', 'evidence-selection.json', 'capture-sources.json',
    'capture-host.json', 'capture-game.json', 'native-io.json', 'game-terminal.json', 'game-metadata.json',
    'platform-inputs.json', 'environment.json', 'experience-index.json', 'launcher/recovery-receipt.json', 'launcher/recovery-state.json']) {
    try {
      const stat = await fs.stat(directory + '/' + name);
      if (!stat.isFile()) throw new Error('元数据不是普通文件，无法可靠核实');
      if (stat.mtimeNs !== undefined && stat.ctimeNs !== undefined) {
        identity.push(name + ':' + String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs) + ':' + String(stat.ctimeNs));
      } else {
        if (stat.size > 1024 * 1024) throw new Error('元数据超过有界验证范围');
        identity.push(name + ':sha256:' + evidenceTextDigest(await fs.readText(directory + '/' + name)));
      }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) throw error as Error;
      identity.push(name + ':missing');
    }
  }
  return identity.join('|');
}

/** V2索引解析只接受完整字段；旧schema继续显示但不成为可信保留输入。 */
function validIndex_(snapshot: LedgerIndexSnapshot, ids: number[]): boolean {
  return snapshot.schema === 2 && snapshot.bytesIncludeMetadata === true && Array.isArray(snapshot.entries)
    && snapshot.entries.length === ids.length && new Set<number>(snapshot.entries.map((entry: LedgerEntry): number => entry.activityId)).size === ids.length
    && snapshot.entries.every((entry: LedgerEntry): boolean => ids.includes(entry.activityId) && Number.isSafeInteger(entry.activityId)
      && Number.isSafeInteger(entry.bytes) && entry.bytes >= 0 && typeof entry.versionKey === 'string'
      && typeof entry.manifestDigest === 'string' && ['current', 'writing', 'unknown'].includes(entry.bytesState ?? ''));
}

/**
 * 显示与维护共用的异步索引入口。集合/schema失效时只用真实异步IO修复；
 * 有效索引仅验证小型manifest身份，dirty活动才递归统计。取消抛错，不发布假空列表。
 */
export async function ledgerListAsync(filesDir: string, cancelled?: () => boolean, publish: boolean = false): Promise<LedgerEntry[]> {
  if (cancelled !== undefined && cancelled()) throw new Error('账本读取已取消');
  const ids: number[] = await listActivityIdsAsync_(filesDir);
  let entries = indexCaches.get(filesDir);
  if (entries === undefined) {
    try {
      const snapshot = JSON.parse(await fs.readText(indexPath(filesDir))) as LedgerIndexSnapshot;
      if (validIndex_(snapshot, ids)) entries = snapshot.entries;
    } catch (_) { /* 首次/旧schema/损坏明确走异步重建。 */ }
  }
  let changed: boolean = false;
  if (entries === undefined) { entries = []; changed = true; maintenanceCounters.fullRebuilds++; }
  const result: LedgerEntry[] = [];
  const dirty = dirtyLedgers.get(filesDir);
  for (const id of ids) {
    if (cancelled !== undefined && cancelled()) throw new Error('账本读取已取消');
    const previous = entries.find((entry: LedgerEntry): boolean => entry.activityId === id);
    const manifest = await ledgerManifestAsync(filesDir, id);
    let fingerprint: string = '';
    if (previous !== undefined && !dirty?.has(id)) {
      try { fingerprint = await metadataFingerprintAsync_(filesDir, id); } catch (_) { /* 无法核实就只重查该局，并保护unknown。 */ }
    }
    if (previous !== undefined && !dirty?.has(id) && previous.manifestDigest === JSON.stringify(manifest)
      && fingerprint.length > 0 && previous.metadataFingerprint === fingerprint) {
      result.push(previous); continue;
    }
    const generation: number = dirtyGenerations.get(filesDir + '/' + id) ?? 0;
    result.push(await measureEntryAsync_(filesDir, id, cancelled)); changed = true;
    if (generation === (dirtyGenerations.get(filesDir + '/' + id) ?? 0)) dirty?.delete(id);
  }
  if (result.length !== entries.length) changed = true;
  if (cancelled !== undefined && cancelled()) throw new Error('账本读取已取消');
  indexCaches.set(filesDir, result);
  if (changed && maintenanceOwner && publish) await publishIndexAsync_(filesDir, result);
  return result.slice().sort((left: LedgerEntry, right: LedgerEntry): number => right.activityId - left.activityId);
}

/** 单个JSON快照发布仍有O(N)序列化，但没有递归全账本IO；属于可重建派生缓存。 */
async function publishIndexAsync_(filesDir: string, entries: LedgerEntry[]): Promise<void> {
  await ensureEvidenceDirectoryAsync(ledgerRoot(filesDir));
  const snapshot: LedgerIndexSnapshot = { schema: 2, bytesIncludeMetadata: true, entries: entries };
  await writeEvidenceTextAtomicAsync(indexPath(filesDir), JSON.stringify(snapshot));
  maintenanceCounters.indexWrites++;
}

/** 异步删除不跟随symlink；每次IO由owner执行，worker候选没有任何删除权限。 */
async function removeDirectoryAsync_(directory: string): Promise<void> {
  for (const name of await fs.listFile(directory)) {
    const path: string = directory + '/' + name;
    const stat = await fs.lstat(path);
    if (!stat.isSymbolicLink() && stat.isDirectory()) await removeDirectoryAsync_(path);
    else await fs.unlink(path);
  }
  await fs.rmdir(directory);
}

/** 复核和claim之前没有await间隙；pin/lease/提交共用同一owner保护门。 */
export async function ledgerRemoveAsync(filesDir: string, activityId: number): Promise<void> {
  return await serializeCanonicalAsync_(filesDir, activityId, (): Promise<void> => removeInternalAsync_(filesDir, activityId));
}
async function removeInternalAsync_(filesDir: string, activityId: number): Promise<void> {
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程仍活跃或状态未知，暂时无法清理日志');
  // manifest读取虽小仍可能await，因此读完后必须再用当前owner事实同步复核一次并claim。
  const reason: string = ledgerRemovalBlockReason(filesDir, activityId);
  if (reason.length > 0) throw new Error(reason);
  if (g_scopeSink !== null) {
    if (g_scopeSink.endAsync === undefined) throw new Error('异步账本关闭端口尚未装配，日志未删除');
    await g_scopeSink.endAsync(activityId);
  }
  // 上面的真实异步关闭允许新reader进来，必须再复核并原子claim，不能沿用旧检查结果。
  const latestReason: string = ledgerRemovalBlockReason(filesDir, activityId);
  if (latestReason.length > 0) throw new Error(latestReason);
  if (maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程状态已变化，日志未删除');
  if (!tryClaimEvidenceDeletion(filesDir, activityId)) throw new Error('日志正在读取或删除，请稍后重试');
  try {
    const directory: string = ledgerDirOf(filesDir, activityId);
    await removeDirectoryAsync_(directory);
    if (await fs.access(directory)) throw new Error('部分日志未能删除，请重试');
    await syncLedgerDirectoryAsync_(filesDir);
    removeCachedEntry_(filesDir, activityId);
    ledgerMarkDirty(filesDir, activityId);
  } finally { releaseEvidenceDeletion(filesDir, activityId); }
}

/** 删除后的根目录命名空间必须耐久，再更新派生索引/向UI报告成功。 */
async function syncLedgerDirectoryAsync_(filesDir: string): Promise<void> {
  const parent = await fs.open(ledgerRoot(filesDir), fs.OpenMode.READ_ONLY);
  try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
}

/** 异步保护原因读取；损坏/缺失manifest不能猜成“已结束且未保留”。 */
export async function ledgerRemovalBlockReasonAsync(filesDir: string, activityId: number): Promise<string> {
  if (isEvidenceDeleting(filesDir, activityId)) return '活动日志正在删除，请稍后重试';
  if (hasEvidenceLease(filesDir, activityId)) return '日志正在读取或导出，请稍后删除';
  const manifest = await ledgerManifestAsync(filesDir, activityId);
  if (manifest === null) return '活动清单无法读取，原始日志保留等待修复';
  if (manifest.state === LedgerState.RUNNING) return '活动仍在进行中，请结束后再删除日志';
  if (manifest.pinned === true) return '这条活动已设为保留，请先取消保留后再删除';
  return '';
}
export async function ledgerClearBlockReasonAsync(filesDir: string): Promise<string> {
  for (const id of await listActivityIdsAsync_(filesDir)) {
    const reason: string = await ledgerRemovalBlockReasonAsync(filesDir, id);
    if (reason.length > 0) return reason;
  }
  return '';
}

/**
 * 清空先完整异步预检，再在同owner事件循环内认领全部ID；任一claim失败时零删除。
 * 认领后拒绝新reader和canonical提交，游戏锁再次复核；失败保留未删原件并真实报告partial。
 * 与逐条ledgerRemove不同，整批只在释放后发布一次索引，不做N次全量重建。
 */
export async function ledgerClearAsync(filesDir: string): Promise<void> {
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程仍活跃或状态未知，暂时无法清理日志');
  const ids = await listActivityIdsAsync_(filesDir);
  if (clearingRoots.has(filesDir) || ids.some((id: number): boolean => canonicalQueues.has(filesDir + '/' + id))) throw new Error('活动清单正在提交，请稍后重试');
  clearingRoots.add(filesDir); ledgerBeginMaintenanceBatch(filesDir);
  const claims: number[] = [];
  try {
    for (const id of ids) {
      const reason: string = await ledgerRemovalBlockReasonAsync(filesDir, id);
      if (reason.length > 0) throw new Error(reason);
      if (g_scopeSink !== null) {
        if (g_scopeSink.endAsync === undefined) throw new Error('异步账本关闭端口尚未装配，日志未删除');
        await g_scopeSink.endAsync(id);
      }
    }
    if (maintenanceAllowed !== undefined && !maintenanceAllowed()) throw new Error('游戏进程状态已变化，清理已延后');
    for (const id of ids) {
      if (!tryClaimEvidenceDeletion(filesDir, id)) throw new Error('日志正在读取或删除，请稍后重试');
      claims.push(id);
    }
    for (const id of ids) {
      await removeDirectoryAsync_(ledgerDirOf(filesDir, id));
      if (await fs.access(ledgerDirOf(filesDir, id))) throw new Error('部分日志未能删除，请重试；未删除原件仍保留');
      await syncLedgerDirectoryAsync_(filesDir);
      removeCachedEntry_(filesDir, id); ledgerMarkDirty(filesDir, id);
    }
  } finally {
    for (const id of claims) { releaseEvidenceDeletion(filesDir, id); ledgerMarkDirty(filesDir, id); }
    clearingRoots.delete(filesDir);
    await ledgerEndMaintenanceBatchAsync(filesDir);
  }
}

/**
 * 同一files根的维护singleflight：dirty集合合并，game活跃/未知时保留义务不强行执行。
 * 每轮只统计变化活动，保留算法只读可信内存元数据；删除前再次owner复核。
 */
export function ledgerFlushMaintenanceAsync(filesDir: string): Promise<void> {
  const current = maintenanceJobs.get(filesDir);
  if (current !== undefined) return current;
  if ((maintenanceHolds.get(filesDir) ?? 0) > 0) return Promise.resolve();
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) { deferredMaintenance.add(filesDir); return Promise.resolve(); }
  if ((dirtyLedgers.get(filesDir)?.size ?? 0) === 0 && !deferredMaintenance.has(filesDir)) return Promise.resolve();
  const timer = maintenanceTimers.get(filesDir);
  if (timer !== undefined) { clearTimeout(timer); maintenanceTimers.delete(filesDir); }
  const job: Promise<void> = maintainAsync_(filesDir);
  maintenanceJobs.set(filesDir, job);
  job.then((): void => { maintenanceJobs.delete(filesDir); }, (): void => { maintenanceJobs.delete(filesDir); });
  return job;
}

async function maintainAsync_(filesDir: string): Promise<void> {
  let blocked: boolean = false;
  let entries = await ledgerListAsync(filesDir, undefined, false);
  const dirty = dirtyLedgers.get(filesDir);
  const ids: number[] = dirty === undefined ? [] : Array.from(dirty);
  for (const id of ids) {
    if (maintenanceAllowed !== undefined && !maintenanceAllowed()) { deferredMaintenance.add(filesDir); return; }
    const key: string = filesDir + '/' + id;
    const generation: number = dirtyGenerations.get(key) ?? 0;
    if (await fs.access(ledgerDirOf(filesDir, id))) {
      const next = await measureEntryAsync_(filesDir, id);
      entries = entries.filter((entry: LedgerEntry): boolean => entry.activityId !== id); entries.push(next);
    } else entries = entries.filter((entry: LedgerEntry): boolean => entry.activityId !== id);
    if (generation === (dirtyGenerations.get(key) ?? 0)) dirty?.delete(id);
  }
  indexCaches.set(filesDir, entries);
  let limit: number;
  try { limit = await ledgerSessionRetentionAsync(filesDir); }
  catch (error) {
    // 派生索引仍可发布；缺少可信配额只暂停自动删除，不缩短既有保留承诺，也不阻止读取原件。
    await publishIndexAsync_(filesDir, entries);
    deferredMaintenance.add(filesDir);
    AppLogger.warn(TAG, '日志保留设置无法核实，自动清理已停止', error, LOG_DOMAIN);
    return;
  }
  const candidates: RetentionCandidate[] = entries.map((entry: LedgerEntry): RetentionCandidate => ({
    activityId: entry.activityId, category: entry.category, versionKey: entry.versionKey ?? '',
    running: entry.state === LedgerState.RUNNING || entry.pinned === true || entry.bytesState !== 'current',
    abnormal: isAbnormalState(entry.state), bytes: entry.bytes, hasGame: entry.hasGame,
  }));
  maintenanceCounters.retentionBatches++;
  for (const id of sessionRetentionVictims(candidates, limit, LEDGER_MAX_ENTRIES, LEDGER_MAX_TOTAL_BYTES)) {
    if (maintenanceAllowed !== undefined && !maintenanceAllowed()) { deferredMaintenance.add(filesDir); return; }
    if (hasEvidenceLease(filesDir, id)) { maintenanceCounters.leaseProtected++; blocked = true; continue; }
    try { await ledgerRemoveAsync(filesDir, id); }
    catch (error) { AppLogger.warn(TAG, '账本淘汰未完成: ' + id, error, LOG_DOMAIN); }
  }
  entries = indexCaches.get(filesDir) ?? entries;
  await publishIndexAsync_(filesDir, entries);
  if (blocked) deferredMaintenance.add(filesDir); else deferredMaintenance.delete(filesDir);
  // 删除操作使ID dirty；已删除的义务无需再次递归，其他并发新增变更继续下一轮。
  if (dirty !== undefined) for (const id of Array.from(dirty)) {
    if (!await fs.access(ledgerDirOf(filesDir, id))) { dirty.delete(id); dirtyGenerations.delete(filesDir + '/' + id); }
  }
  if ((dirty?.size ?? 0) > 0) {
    setTimeout((): void => { scheduleMaintenance_(filesDir); }, 0);
  }
}

/** 用户主动保留/取消保留；先原子保存 manifest，再发布索引，不改变日志与结局。 */
export function ledgerSetPinned(filesDir: string, activityId: number, pinned: boolean): void {
  if (!maintenanceOwner) throw new Error('保留设置必须由启动器保存');
  assertCanonicalIdle_(filesDir, activityId);
  const manifest: LedgerManifest | null = ledgerManifest(filesDir, activityId);
  if (manifest === null) throw new Error('活动不存在或无法读取');
  if (manifest.pinned === pinned) { ensureEvidenceTextDurable(manifestPath(filesDir, activityId)); return; }
  manifest.pinned = pinned;
  manifest.revision = (manifest.revision ?? 0) + 1;
  if (!writeTextFile(manifestPath(filesDir, activityId), JSON.stringify(manifest))) throw new Error('保留设置未保存');
}

/** UI保留操作等待同活动恢复事务，随后读取最新清单；不会把旧m写回而丢失终态或pin。 */
export function ledgerSetPinnedAsync(filesDir: string, activityId: number, pinned: boolean): Promise<void> {
  acquireEvidenceLease(filesDir, activityId);
  const job = serializeCanonicalAsync_(filesDir, activityId, async (): Promise<void> => {
    if (!maintenanceOwner) throw new Error('保留设置必须由启动器保存');
    const manifest = await ledgerManifestAsync(filesDir, activityId);
    if (manifest === null) throw new Error('活动不存在或无法读取');
    if (manifest.pinned === pinned) { await ensureEvidenceTextDurableAsync(manifestPath(filesDir, activityId)); return; }
    manifest.pinned = pinned; manifest.revision = (manifest.revision ?? 0) + 1;
    await writeEvidenceTextAtomicAsync(manifestPath(filesDir, activityId), JSON.stringify(manifest));
  });
  return job.then((): void => { releaseEvidenceLease(filesDir, activityId); }, (error: Error): void => {
    releaseEvidenceLease(filesDir, activityId); throw error as Error;
  });
}

export interface LedgerRelatedActivity {
  activityId: number; title: string; startedAt: number; state: LedgerState; relation: string;
}

/**
 * 显式父子关系与同实例历史分开标注，绝不把时间相近当成因果。父记录被清理时不造记录；
 * 子局仍保留原 parentActivityId 供排障。只返回少量导航摘要，不读取任何日志正文。
 */
export function ledgerRelatedActivities(filesDir: string, activityId: number): LedgerRelatedActivity[] {
  const current: LedgerManifest | null = ledgerManifest(filesDir, activityId);
  if (current === null) return [];
  const related: LedgerRelatedActivity[] = []; const sameInstance: LedgerRelatedActivity[] = [];
  for (const entry of ledgerList(filesDir)) {
    if (entry.activityId === activityId) continue;
    const candidate: LedgerManifest | null = ledgerManifest(filesDir, entry.activityId);
    if (candidate === null) continue;
    appendRelatedCandidate_(current, activityId, candidate, related, sameInstance);
  }
  return related.concat(sameInstance);
}

/** 同步与异步导航投影共用原关系规则及8/4条上限，读取方式不取得终态或历史写权限。 */
function appendRelatedCandidate_(current: LedgerManifest, activityId: number, candidate: LedgerManifest,
  related: LedgerRelatedActivity[], sameInstance: LedgerRelatedActivity[]): void {
  let relation: string = '';
  if (candidate.activityId === current.parentActivityId) relation = '来源活动';
  else if (candidate.parentActivityId === activityId) relation = candidate.relation === 'retry' ? '后续重试' : candidate.relation === 'graphics-recovery' ? '图形恢复尝试' : '后续子任务';
  else if (current.gameVersionId.length > 0 && candidate.gameVersionId === current.gameVersionId
    && candidate.mcDir === current.mcDir && candidate.category === current.category) relation = '同版本其他尝试';
  if (relation.length === 0) return;
  const item: LedgerRelatedActivity = { activityId: candidate.activityId, title: candidate.title,
    startedAt: candidate.startedAt, state: candidate.state, relation: relation };
  if (relation === '同版本其他尝试') { if (sameInstance.length < 4) sameInstance.push(item); }
  else if (related.length < 8) related.push(item);
}

/** 使用SDK异步文本IO和同一个manifest解析器；缺失/损坏与原同步读取一样返回null。 */
async function relatedManifestAsync_(filesDir: string, activityId: number): Promise<LedgerManifest | null> {
  try { return parseLedgerManifest(await fs.readText(manifestPath(filesDir, activityId))); }
  catch (_) { return null; }
}

/**
 * 阅读页的关联导航异步投影：只读少量索引后以8份一批异步读取manifest，避免在首次
 * layout中同步打开全部活动文件。批内Promise.all保持原倒序，关系规则与8/4条上限
 * 仍共用原实现。离页/换活动时在下一批前停止，不把取消结果发布成“没有关联”。
 */
export async function ledgerRelatedActivitiesAsync(filesDir: string, activityId: number,
  cancelled: () => boolean): Promise<LedgerRelatedActivity[]> {
  if (cancelled()) throw new Error('关联活动读取已取消');
  const current: LedgerManifest | null = await relatedManifestAsync_(filesDir, activityId);
  if (current === null) return [];
  const related: LedgerRelatedActivity[] = []; const sameInstance: LedgerRelatedActivity[] = [];
  const entries: LedgerEntry[] = ledgerList(filesDir).filter((entry: LedgerEntry): boolean => entry.activityId !== activityId);
  for (let start: number = 0; start < entries.length; start += 8) {
    if (cancelled()) throw new Error('关联活动读取已取消');
    const batch: LedgerEntry[] = entries.slice(start, start + 8);
    const candidates: (LedgerManifest | null)[] = await Promise.all(batch.map((entry: LedgerEntry): Promise<LedgerManifest | null> =>
      relatedManifestAsync_(filesDir, entry.activityId)));
    if (cancelled()) throw new Error('关联活动读取已取消');
    for (const candidate of candidates) {
      if (candidate !== null) appendRelatedCandidate_(current, activityId, candidate, related, sameInstance);
    }
    if (related.length >= 8 && sameInstance.length >= 4) break;
  }
  return related.concat(sameInstance);
}

/** 账本总占用字节数。 */
export function ledgerTotalBytes(filesDir: string): number {
  let total = 0;
  for (let id of listActivityIds(filesDir)) total += ledgerBytesOf(filesDir, id);
  return total;
}

/**
 * 执行保留策略。
 *
 * 游戏按每版本最近 N 局保留；普通活动维持数量与体积预算。运行中条目不淘汰。
 *
 * @returns 被删除的条数
 */
export function ledgerRetentionVictims(filesDir: string, limit: number): number[] {
  const cached = indexCaches.get(filesDir) ?? ledgerList(filesDir);
  const entries: RetentionCandidate[] = cached.map((entry: LedgerEntry): RetentionCandidate => ({
    activityId: entry.activityId, category: entry.category, versionKey: entry.versionKey ?? '',
    running: entry.state === LedgerState.RUNNING || entry.pinned === true || entry.bytesState !== 'current'
      || dirtyLedgers.get(filesDir)?.has(entry.activityId) === true,
    abnormal: isAbnormalState(entry.state), bytes: entry.bytes, hasGame: entry.hasGame,
  }));
  return sessionRetentionVictims(entries, limit, LEDGER_MAX_ENTRIES, LEDGER_MAX_TOTAL_BYTES)
    .filter((id: number): boolean => !hasEvidenceLease(filesDir, id));
}

/** 设置面板异步预览共用同一可信行与纯保留算法，不随slider每帧重新同步递归全部日志。 */
export async function ledgerRetentionVictimsAsync(filesDir: string, limit: number): Promise<number[]> {
  // 同一页面连续slider预览复用已核验快照；真实删除仍逐活动重核pin/running/lease。
  if (!indexCaches.has(filesDir) || (dirtyLedgers.get(filesDir)?.size ?? 0) > 0) await ledgerListAsync(filesDir);
  return ledgerRetentionVictims(filesDir, limit);
}

/** 预览与删除使用同一策略；执行前仍复查租约和运行状态，避免确认期间误清理。 */
export function prune(filesDir: string): number {
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) { deferredMaintenance.add(filesDir); return 0; }
  const victims = ledgerRetentionVictims(filesDir, ledgerSessionRetention(filesDir));
  let removed = 0;
  for (const id of victims) {
    if (canonicalMutations.has(filesDir + '/' + id) || canonicalQueues.has(filesDir + '/' + id)) continue;
    if (ledgerRemovalBlockReason(filesDir, id).length > 0) continue;
    try {
      removeDirRecursive(ledgerDirOf(filesDir, id));
      if (ledgerHas(filesDir, id)) throw new Error('日志目录未完全清理');
      removed++;
    } catch (e) {
      AppLogger.warn(TAG, 'prune remove failed: ' + id, e, LOG_DOMAIN);
    }
  }
  if (removed > 0) {
    AppLogger.info(TAG, 'prune removed ' + removed + ' ledgers', LOG_DOMAIN);
    scheduleMaintenance_(filesDir);
  }
  return removed;
}

/** SDK异步复制/校验/文件与目录同步；仅未变化的已核验高精度指纹允许省略复制。 */
async function archiveFileAsync_(source: string, destination: string,
  publishGuard: (() => boolean) | undefined = undefined): Promise<boolean> {
  assertEvidencePreparationCurrent(publishGuard);
  let before: string;
  try {
    const stat = await fs.stat(source);
    if (!stat.isFile() || stat.size <= 0) return false;
    before = await evidenceFileStampAsync(source);
    if (stat.mtimeNs !== undefined && stat.ctimeNs !== undefined && await fs.access(destination)
      && archivedFingerprints.get(destination) === before + '|' + await evidenceFileStampAsync(destination)) return true;
  } catch (error) { if ((error as BusinessError).code === 13900002) return false; throw error as Error; }
  const temporary: string = destination + '.' + util.generateRandomUUID() + '.partial';
  let published: boolean = false;
  try {
    const parentPath: string = destination.substring(0, destination.lastIndexOf('/'));
    await ensureEvidenceDirectoryAsync(parentPath);
    assertEvidencePreparationCurrent(publishGuard);
    await fs.copyFile(source, temporary);
    if (before !== await evidenceFileStampAsync(source) || (await fs.stat(source)).size !== (await fs.stat(temporary)).size) throw new Error('来源在复制期间变化');
    const digest: string = await evidenceFileDigestAsync(temporary);
    if (digest !== await evidenceFileDigestAsync(source)) throw new Error('来源内容核验失败');
    const file = await fs.open(temporary, fs.OpenMode.READ_WRITE);
    try { await fs.fsync(file.fd); } finally { await fs.close(file); }
    assertEvidencePreparationCurrent(publishGuard);
    await fs.rename(temporary, destination); published = true;
    assertEvidencePreparationCurrent(publishGuard);
    const parent = await fs.open(parentPath, fs.OpenMode.READ_ONLY);
    try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
    const stat = await fs.stat(source);
    if (stat.mtimeNs !== undefined && stat.ctimeNs !== undefined) {
      if (archivedFingerprints.size >= 4096) archivedFingerprints.clear();
      archivedFingerprints.set(destination, before + '|' + await evidenceFileStampAsync(destination));
    }
    return true;
  } catch (error) {
    try { await fs.unlink(temporary); } catch (_) {}
    if (published) { noteEvidencePublicationUnknown(destination); throw new AtomicWriteError(true); }
    AppLogger.warn(TAG, '异步归档未完成，保留原件', error, LOG_DOMAIN);
    throw error as Error;
  }
}

/**
 * 一批平台事件只发现一次小型活动元数据，按原PID/真实时间/nonce规则唯一归属。
 * 没有身份的事件保留pending；新附件或同正文修订推进platformInputKey，原文不改写。
 * 归档、Evidence和canonical提交全部由同一恢复owner串行调用，changed IDs均失效统计。
 */
export async function archivePlatformEventFilesAsync(filesDir: string): Promise<number[]> {
  return await archivePlatformEventBatchAsync_(filesDir);
}

/**
 * 已唯一归属但报告尚未复制完成的耐久义务。只有启动器写此索引；原始event仍是权威，
 * 索引只是后续普通wake定位单局的入口，不参与结局裁决，也不允许扩大到全部历史扫描。
 */
interface PlatformReportRetry { name: string; activityId: number; runNonce: string; eventKey: string; }
interface PlatformReportRetryIndex { schema: number; entries: PlatformReportRetry[]; }
/** 一活动一份长期补采租约；耐久retry索引在新进程重建，不让清理丢失唯一归属基线。 */
const platformReportLeases: Map<string, Set<number>> = new Map<string, Set<number>>();
function holdPlatformReportLease_(filesDir: string, activityId: number): void {
  let ids = platformReportLeases.get(filesDir);
  if (ids === undefined) { ids = new Set<number>(); platformReportLeases.set(filesDir, ids); }
  if (ids.has(activityId)) return;
  acquireEvidenceLease(filesDir, activityId); ids.add(activityId);
}
/** 仅完成原件提交或确认原event已删除后释放，不在读取空索引时撤销未知发布的保护。 */
function releaseCompletedPlatformReportLease_(filesDir: string, activityId: number, entries: PlatformReportRetry[]): void {
  const ids = platformReportLeases.get(filesDir);
  if (ids?.has(activityId) !== true || entries.some((entry): boolean => entry.activityId === activityId)) return;
  ids.delete(activityId); releaseEvidenceLease(filesDir, activityId);
  if (ids.size === 0) platformReportLeases.delete(filesDir);
}

/** 损坏/权限错误保留原件并抛出；只有确实不存在才表示尚无已归属补采义务。 */
async function readPlatformReportRetriesAsync_(root: string): Promise<PlatformReportRetry[]> {
  const path: string = root + '/report-retries.json';
  try {
    const stat = await fs.stat(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 1024 * 1024) throw new Error('平台补采索引损坏，原件保留');
    await ensureEvidenceTextDurableAsync(path);
    const value = JSON.parse(await fs.readText(path)) as PlatformReportRetryIndex;
    if (value === null || value.schema !== 1 || !Array.isArray(value.entries)) throw new Error('平台补采索引格式无效，原件保留');
    const names: Set<string> = new Set<string>();
    for (const entry of value.entries) {
      if (entry === null || typeof entry !== 'object' || typeof entry.name !== 'string'
        || !new RegExp('^event-[^/\\\\]+[.]json$').test(entry.name)
        || !Number.isSafeInteger(entry.activityId) || entry.activityId <= 0 || typeof entry.runNonce !== 'string'
        || typeof entry.eventKey !== 'string' || !new RegExp('^[a-f0-9]{64}$').test(entry.eventKey)
        || names.has(entry.name)) throw new Error('平台补采身份无效，原件保留');
      names.add(entry.name);
    }
    const filesDir: string = root.substring(0, root.length - '/logs/platform-events'.length);
    for (const entry of value.entries) holdPlatformReportLease_(filesDir, entry.activityId);
    return value.entries;
  } catch (error) { if ((error as BusinessError).code === 13900002) return []; throw error as Error; }
}

/** 相同未完成义务不重复写盘；发布后耐久未知的相同正文仍须真实重同步才能返回。 */
async function savePlatformReportRetriesAsync_(root: string, entries: PlatformReportRetry[]): Promise<void> {
  const path: string = root + '/report-retries.json';
  const ordered = entries.slice().sort((left: PlatformReportRetry, right: PlatformReportRetry): number => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  const text: string = JSON.stringify({ schema: 1, entries: ordered });
  if (utf8ByteLength(text) > 1024 * 1024) throw new Error('平台补采索引超过读取上限，原件与义务保留');
  let previous: string = '';
  try { previous = await fs.readText(path); }
  catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
  if (previous !== text) await writeEvidenceTextAtomicAsync(path, text);
  else await ensureEvidenceTextDurableAsync(path);
}

/**
 * 每次明确空闲wake最多调用一次；只读耐久索引列出的event和对应manifest。
 * 失败仍保留同一义务，不自行发起定时轮询或把同一次wake变成无限补采循环。
 */
export async function retryPlatformEventFilesAsync(filesDir: string): Promise<number[]> {
  if (!maintenanceOwner) return [];
  const root: string = filesDir + '/logs/platform-events';
  const retries = await readPlatformReportRetriesAsync_(root);
  if (retries.length === 0) return [];
  return await archivePlatformEventBatchAsync_(filesDir, retries);
}

/**
 * 启动器cold初始化在stale与自动维护之前显式调用。只读既有小型耐久retry索引，
 * 重建未完成补采活动的租约；ENOENT表示没有该索引，权限/存储/格式错误原样抛出。
 * 本入口不归档event、不枚举账本，也不自行解除初始化维护hold，调用方只有整轮恢复
 * 成功后才可开放自动删除，失败时仍须保留该保护边界。
 */
export async function restorePlatformReportProtectionAsync(filesDir: string): Promise<void> {
  await readPlatformReportRetriesAsync_(filesDir + '/logs/platform-events');
}

/** 完整发布批用于首次/新事件发现，retry批只核实已冻结的单局归属，二者共用原采集算法。 */
async function archivePlatformEventBatchAsync_(filesDir: string, retryBatch?: PlatformReportRetry[]): Promise<number[]> {
  if (!maintenanceOwner) return [];
  const root: string = filesDir + '/logs/platform-events';
  if (!await fs.access(root)) return [];
  let retries: PlatformReportRetry[] = retryBatch ?? await readPlatformReportRetriesAsync_(root);
  const events: string[] = retryBatch === undefined ? await fs.listFile(root) : retryBatch.map((entry): string => entry.name);
  if (events.length === 0) return [];
  const ids: number[] = retryBatch === undefined ? await listActivityIdsAsync_(filesDir)
    : Array.from(new Set<number>(retryBatch.map((entry): number => entry.activityId)));
  ids.sort((left: number, right: number): number => left - right);
  const manifests: LedgerManifest[] = [];
  for (const id of ids) { const manifest = await ledgerManifestAsync(filesDir, id); if (manifest?.category === 'launch') manifests.push(manifest); }
  const changed: Set<number> = new Set<number>();
  for (const name of events) {
    if (!name.startsWith('event-') || !name.endsWith('.json')) continue;
    const path: string = root + '/' + name;
    let event: Record<string, Object>;
    let params: Record<string, Object> = {};
    let text: string;
    try {
      if ((await fs.stat(path)).size > 1024 * 1024) continue;
      text = await fs.readText(path); event = JSON.parse(text) as Record<string, Object>;
      const raw = event['params'];
      if (typeof raw === 'string') params = JSON.parse(raw) as Record<string, Object>;
      else if (raw !== undefined && raw !== null && typeof raw === 'object') params = raw as Record<string, Object>;
    } catch (error) {
      if ((error as BusinessError).code === 13900002) {
        // 原event只在全部收据耐久后删除；unlink后保存索引前被杀的遗留项可安全清除。
        const next = retries.filter((entry): boolean => entry.name !== name);
        if (next.length !== retries.length) {
          const removed = retries.find((entry): boolean => entry.name === name);
          retries = next; await savePlatformReportRetriesAsync_(root, retries);
          if (removed !== undefined) releaseCompletedPlatformReportLease_(filesDir, removed.activityId, retries);
        }
        continue;
      }
      if (error instanceof SyntaxError) continue;
      throw error as Error;
    }
    const explicitId: number = num_(event, 'activityId', 0);
    const eventAt: number = num_(event, 'eventAt', num_(params, 'time', 0));
    const pid: number = num_(params, 'pid', 0);
    if (retryBatch !== undefined) {
      const expected = retryBatch.find((entry): boolean => entry.name === name);
      if (expected === undefined || expected.eventKey !== evidenceTextDigest(text)) throw new Error('平台补采原件身份已变化，保留双方事实等待重新归属');
    }
    if (explicitId <= 0 && (eventAt <= 0 || pid <= 0)) continue;
    const candidates: LedgerManifest[] = [];
    for (let index: number = 0; index < manifests.length; index++) {
      const manifest = manifests[index];
      if (retryBatch !== undefined) {
        // 归属已经在完整批核实；不能用局部候选的“下一局”重新扩大时间窗或改绑活动。
        const expected = retryBatch.find((entry): boolean => entry.name === name);
        if (expected !== undefined && manifest.activityId === expected.activityId && manifest.runNonce === expected.runNonce) candidates.push(manifest);
        continue;
      }
      if (explicitId > 0) { if (manifest.activityId === explicitId && str_(event, 'runNonce') === manifest.runNonce) candidates.push(manifest); continue; }
      let ownsPid: boolean = manifest.ownerPid === pid;
      for (const file of ['capture-host.json', 'capture-game.json']) {
        try { if (num_(JSON.parse(await fs.readText(ledgerDirOf(filesDir, manifest.activityId) + '/' + file)) as Record<string, Object>, 'pid', 0) === pid) ownsPid = true; }
        catch (error) { if ((error as BusinessError).code !== 13900002 && !(error instanceof SyntaxError)) throw error as Error; }
      }
      const upper: number = Math.min(manifest.endedAt > 0 ? manifest.endedAt : Number.MAX_SAFE_INTEGER, manifests[index + 1]?.startedAt ?? Number.MAX_SAFE_INTEGER);
      if (ownsPid && eventAt >= manifest.startedAt && eventAt <= upper) candidates.push(manifest);
    }
    if (candidates.length !== 1) continue;
    await serializeCanonicalAsync_(filesDir, candidates[0].activityId, async (): Promise<void> => {
    const manifest = await ledgerManifestAsync(filesDir, candidates[0].activityId);
    if (manifest === null) return;
    assertEvidenceWritable(filesDir, manifest.activityId);
    acquireEvidenceLease(filesDir, manifest.activityId);
    try {
      const targetDir: string = ledgerDirOf(filesDir, manifest.activityId) + '/system';
      const crash: boolean = str_(event, 'name') === 'APP_CRASH';
      const destination: string = targetDir + '/' + (crash ? 'crash-report-' : 'exit-event-') + name;
      let externalComplete: boolean = true;
      const identities: string[] = [text];
      const external = params['external_log'];
      if (crash && Array.isArray(external)) {
        let index: number = 0;
        for (const value of external as Object[]) {
          if (typeof value !== 'string' || !value.startsWith('/') || value.indexOf('/../') >= 0) continue;
          const target: string = targetDir + '/crash-report-' + name + '-external-' + index++ + '.log';
          const copied: boolean = await archiveFileAsync_(value, target);
          if (!copied) externalComplete = false;
          try { identities.push(value + ':' + await evidenceFileStampAsync(target)); } catch (_) { identities.push(value + ':unavailable'); }
        }
      }
      const eventCopied: boolean = await archiveFileAsync_(path, destination);
      if (!externalComplete || !eventCopied) {
        const entry: PlatformReportRetry = { name: name, activityId: manifest.activityId, runNonce: manifest.runNonce ?? '', eventKey: evidenceTextDigest(text) };
        retries = retries.filter((value): boolean => value.name !== name); retries.push(entry);
        // 索引发布失败仍保留本进程已知义务的保护，finally维护不能抢先删掉canonical基线。
        holdPlatformReportLease_(filesDir, manifest.activityId);
        await savePlatformReportRetriesAsync_(root, retries);
      }
      if (!eventCopied) return;
      const inputsPath: string = ledgerDirOf(filesDir, manifest.activityId) + '/platform-inputs.json';
      let inputs: Record<string, string> = {};
      try { inputs = JSON.parse(await fs.readText(inputsPath)) as Record<string, string>; }
      catch (error) { if ((error as BusinessError).code !== 13900002 && !(error instanceof SyntaxError)) throw error as Error; }
      inputs[name] = evidenceTextDigest(JSON.stringify(identities));
      const ordered: Record<string, string> = {};
      for (const key of Object.keys(inputs).sort()) ordered[key] = inputs[key];
      const inputText: string = JSON.stringify(ordered);
      const nextKey: string = evidenceTextDigest(inputText);
      const previous: string = JSON.stringify(manifest);
      applyPlatformOutcome_(manifest, text);
      const files: LedgerFile[] = [];
      await scanDirAsync_(ledgerDirOf(filesDir, manifest.activityId), '', files, 0);
      manifest.files = files;
      if (manifest.platformInputKey !== nextKey || previous !== JSON.stringify(manifest)) {
        manifest.platformInputKey = nextKey; manifest.revision = (manifest.revision ?? 0) + 1;
        await writeEvidenceTextAtomicAsync(manifestPath(filesDir, manifest.activityId), JSON.stringify(manifest));
        await refreshSessionEvidenceAsync(filesDir, manifest.activityId, 'recovered', 'partial', externalComplete ? [] : ['平台外部报告尚未完整复制，等待重试']);
        await writeEvidenceTextAtomicAsync(inputsPath, inputText);
        ledgerMarkDirty(filesDir, manifest.activityId); changed.add(manifest.activityId);
      }
      if (externalComplete) {
        await fs.unlink(path);
        const parent = await fs.open(root, fs.OpenMode.READ_ONLY);
        try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
        const next = retries.filter((entry): boolean => entry.name !== name);
        if (next.length !== retries.length) { retries = next; await savePlatformReportRetriesAsync_(root, retries); }
        releaseCompletedPlatformReportLease_(filesDir, manifest.activityId, retries);
      }
    } finally { releaseEvidenceLease(filesDir, manifest.activityId); }
    });
  }
  return Array.from(changed);
}

/**
 * 仅接入已明确发布业务终态收据的两种caller。原文绑定ID/category/非空nonce及真实完成时刻；
 * 完成后的canonical重试失败不能把实际SUCCESS重新认作进程中断。record正文不参与签发完整性，
 * 其他业务仍由自己的权威恢复链处理，不把任意JSON都当作通用“完成”声明。
 */
async function readStaleProducerOutcomeAsync_(filesDir: string, manifest: LedgerManifest): Promise<LedgerOutcome | undefined> {
  const mod: boolean = manifest.category === 'mod_install';
  const updateDownload: boolean = manifest.category === 'app_update_download';
  if (!mod && !updateDownload || (manifest.runNonce ?? '').length === 0) return undefined;
  const path: string = ledgerDirOf(filesDir, manifest.activityId) + (mod ? '/task-terminal.json' : '/update-terminal.json');
  try {
    const stat = await fs.stat(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 512 * 1024) return undefined;
    await ensureEvidenceTextDurableAsync(path);
    const value = JSON.parse(await fs.readText(path)) as Record<string, Object>;
    if (value === null || value['schema'] !== 1 || value['activityId'] !== manifest.activityId
      || value['category'] !== manifest.category || value['runNonce'] !== manifest.runNonce) return undefined;
    const raw = mod ? value['outcome'] as Record<string, Object> : value;
    if (raw === undefined || raw === null || typeof raw !== 'object') return undefined;
    const state = raw['state']; const endedAt = raw['endedAt']; const summary = raw['summary'];
    if (state !== LedgerState.SUCCESS && state !== LedgerState.FAILED && (!updateDownload || state !== LedgerState.ABORTED)
      || typeof summary !== 'string' || typeof endedAt !== 'number' || !Number.isSafeInteger(endedAt)
      || endedAt < manifest.activityId || endedAt > Date.now()
      || mod && raw['source'] !== 'modInstall.terminal') return undefined;
    return { state: state as LedgerState, source: mod ? 'modInstall.terminal' : 'sideload.update',
      summary: summary, endedAt: endedAt };
  } catch (error) {
    if ((error as BusinessError).code === 13900002 || error instanceof SyntaxError) return undefined;
    throw error as Error;
  }
}

/** 冷启动仅收尾确实残留RUNNING，保留已授权更新事务；已结束历史不在此重新归档。 */
export async function ledgerResolveStaleAsync(filesDir: string, pendingUpdateIds: number[] = []): Promise<number> {
  if (!maintenanceOwner || maintenanceAllowed !== undefined && !maintenanceAllowed()) return 0;
  let count: number = 0;
  for (const id of await listActivityIdsAsync_(filesDir)) {
    const manifest = await ledgerManifestAsync(filesDir, id);
    if (manifest === null || manifest.state !== LedgerState.RUNNING || manifest.category === 'app_update' && pendingUpdateIds.includes(id)) continue;
    if (maintenanceAllowed !== undefined && !maintenanceAllowed()) break;
    const terminal = await readStaleProducerOutcomeAsync_(filesDir, manifest);
    await ledgerEndAsync(filesDir, id, terminal ?? { state: LedgerState.INTERRUPTED, source: 'ledger.resolveStale',
      summary: '上次应用退出时该操作尚未结束（进程被结束或崩溃）', endedAt: 0, recoveredAt: Date.now() },
      { inputKey: 'stale:' + (manifest.runNonce ?? '') });
    count++;
    maintenanceCounters.staleCommits++;
  }
  return count;
}

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
import { AppLogger } from './AppLogger';
import { LOG_DOMAIN } from '../common/Constants';
import { ensureDirSync, removeDirRecursive } from './FileUtils';
import { sanitizeLogForExport, LogExportTarget, exportLimitOf, utf8ByteLength,
  truncateUtf8HeadTail } from './LogExport';
import { allocateExportBudget, ExportPartDemand, ExportPartGrant } from './LogExportBudget';
import { DiagnosticBundle, DiagnosticEnv } from './DiagnosticBundle';
import { findSessionLog, readLogFileHead } from './GameLogPaths';
import { normalizeSessionRetention, SESSION_RETENTION_DEFAULT, RetentionCandidate, sessionRetentionVictims } from './SessionRetention';
import { refreshSessionEvidence } from './SessionEvidence';
import { beginSessionCapture, checkpointSessionCapture, nativeSessionIo, recordArchivedSessionSource } from './SessionCapture';
import { writeEvidenceTextAtomic, hasEvidenceLease, evidenceFileStamp } from './EvidenceIo';

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
  const raw = readTextFile(filesDir + '/logs/session-retention.json');
  if (raw.length === 0) return SESSION_RETENTION_DEFAULT;
  try { return normalizeSessionRetention(Number(JSON.parse(raw))); }
  catch (e) { return SESSION_RETENTION_DEFAULT; }
}

export function ledgerSetSessionRetention(filesDir: string, value: number): void {
  ensureDirSync(filesDir + '/logs');
  if (!writeTextFile(filesDir + '/logs/session-retention.json', JSON.stringify(normalizeSessionRetention(value)))) {
    throw new Error('保存日志保留设置失败');
  }
  prune(filesDir);
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
    if (n === LEDGER_MANIFEST_NAME || n === 'evidence-manifest.json'
      || n === 'evidence-selection.json') continue;
    const path: string = dir + '/' + n;
    const name: string = prefix.length > 0 ? prefix + '/' + n : n;
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
  const dir: string = ledgerDirOf(filesDir, activityId);
  let total = fileBytes(manifestPath(filesDir, activityId))
    + fileBytes(dir + '/evidence-manifest.json') + fileBytes(dir + '/evidence-selection.json');
  for (let f of scanDir(filesDir, activityId)) total += f.bytes;
  return total;
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
  if (meta.category === 'launch') ledgerArchiveCompletedSessions(filesDir);
  let dir = ledgerDirOf(filesDir, activityId);
  try {
    ensureDirSync(dir);
  } catch (e) {
    AppLogger.warn(TAG, 'ledgerBegin mkdir failed: ' + dir, e, LOG_DOMAIN);
    return false;
  }

  const existing = ledgerManifest(filesDir, activityId);
  if (existing !== null && existing.state !== LedgerState.RUNNING) return false;
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
 * 结束一条账本：关掉 native scope，补齐 manifest 的结局与文件清单，更新索引。
 */
export function ledgerEnd(filesDir: string, activityId: number,
  outcome: LedgerOutcome): void {
  if (filesDir.length === 0 || activityId <= 0) return;

  // 先关 scope，确保 native 已 flush 并释放句柄，之后统计的体积才是最终值
  if (g_scopeSink !== null) {
    try { g_scopeSink.end(activityId); } catch (e) { /* ignore */ }
  }

  let m = parseLedgerManifest(readTextFile(manifestPath(filesDir, activityId)));
  if (m === null) m = emptyManifest(activityId);
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

  rebuildIndex(filesDir);
  prune(filesDir);
  AppLogger.info(TAG, 'ledger end: id=' + activityId
    + ' state=' + ledgerStateLabel(outcome.state)
    + ' files=' + m.files.length, LOG_DOMAIN);
}

/**
 * 冷启动收尾：把上次进程留下的 `RUNNING` 账本标成 `INTERRUPTED`。
 *
 * 只认「进程启动时发现残留 RUNNING」这一个判据，不靠超时猜 —— 一个真正在跑的活动
 * 不可能出现在新进程刚启动的时刻。
 *
 * @returns 被标定的条数
 */
export function ledgerResolveStale(filesDir: string): number {
  let n = 0;
  for (let id of listActivityIds(filesDir)) {
    let mp = manifestPath(filesDir, id);
    let m = parseLedgerManifest(readTextFile(mp));
    if (m === null || m.state !== LedgerState.RUNNING) continue;
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
  const location = findSessionLog(manifest.mcDir, manifest.gameVersionId, manifest.startedAt);
  if (location.exact && location.path.length > 0) {
    archiveFile(location.path, dir + '/game/mc_output.log');
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
  const reason: string = ledgerRemovalBlockReason(filesDir, activityId);
  if (reason.length > 0) throw new Error(reason);
  if (g_scopeSink !== null) {
    try { g_scopeSink.end(activityId); } catch (e) { /* ignore */ }
  }
  const directory: string = ledgerDirOf(filesDir, activityId);
  removeDirRecursive(directory);
  if (fs.accessSync(directory)) throw new Error('部分日志未能删除，请重试；在线分享未受影响');
  rebuildIndex(filesDir);
}

/** 清空全部账本。 */
export function ledgerClear(filesDir: string): void {
  const ids: number[] = listActivityIds(filesDir);
  const reason: string = ledgerClearBlockReason(filesDir);
  if (reason.length > 0) throw new Error(reason);
  for (let id of ids) {
    ledgerRemove(filesDir, id);
  }
  rebuildIndex(filesDir);
}

// ============================================================================
//  索引与淘汰
// ============================================================================

/** 扫目录重建索引。目录是唯一事实源，索引只是给 UI 的快照。 */
export function rebuildIndex(filesDir: string): LedgerEntry[] {
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
      bytes: ledgerBytesOf(filesDir, id),
      hasGame: fileBytes(ledgerDirOf(filesDir, id) + '/game.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/mc_output.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/logs/latest.log') > 0,
    };
    entries.push(e);
  }
  try {
    ensureDirSync(ledgerRoot(filesDir));
    const snapshot: LedgerIndexSnapshot = { schema: 1, entries: entries, bytesIncludeMetadata: true };
    writeTextFile(indexPath(filesDir), JSON.stringify(snapshot));
  } catch (e) { /* 索引写失败不影响读取（list 会退回扫目录） */ }
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
    if (saved.schema === 1 && saved.bytesIncludeMetadata === true && Array.isArray(saved.entries) && saved.entries.length === ids.length
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

/** 用户主动保留/取消保留；先原子保存 manifest，再发布索引，不改变日志与结局。 */
export function ledgerSetPinned(filesDir: string, activityId: number, pinned: boolean): void {
  const manifest: LedgerManifest | null = ledgerManifest(filesDir, activityId);
  if (manifest === null) throw new Error('活动不存在或无法读取');
  manifest.pinned = pinned;
  if (!writeTextFile(manifestPath(filesDir, activityId), JSON.stringify(manifest))) throw new Error('保留设置未保存');
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
    let relation: string = '';
    if (candidate.activityId === current.parentActivityId) relation = '来源活动';
    else if (candidate.parentActivityId === activityId) relation = candidate.relation === 'retry' ? '后续重试' : candidate.relation === 'graphics-recovery' ? '图形恢复尝试' : '后续子任务';
    else if (current.gameVersionId.length > 0 && candidate.gameVersionId === current.gameVersionId
      && candidate.mcDir === current.mcDir && candidate.category === current.category) relation = '同版本其他尝试';
    if (relation.length === 0) continue;
    const item: LedgerRelatedActivity = { activityId: candidate.activityId, title: candidate.title,
      startedAt: candidate.startedAt, state: candidate.state, relation: relation };
    if (relation === '同版本其他尝试') { if (sameInstance.length < 4) sameInstance.push(item); }
    else if (related.length < 8) related.push(item);
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
  let ids = listActivityIds(filesDir);   // 已按时间倒序
  if (ids.length === 0) return [];

  const entries: RetentionCandidate[] = [];
  for (let id of ids) {
    let m = ledgerManifest(filesDir, id);
    let st = m !== null ? m.state : LedgerState.RUNNING;
    const entry: RetentionCandidate = {
      activityId: id, category: m?.category ?? '',
      versionKey: (m?.mcDir ?? '') + '\n' + (m?.gameVersionId ?? ''),
      running: st === LedgerState.RUNNING || m?.pinned === true, abnormal: isAbnormalState(st),
      bytes: ledgerBytesOf(filesDir, id),
      hasGame: fileBytes(ledgerDirOf(filesDir, id) + '/game.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/mc_output.log') > 0
        || fileBytes(ledgerDirOf(filesDir, id) + '/game/logs/latest.log') > 0,
    };
    entries.push(entry);
  }
  return sessionRetentionVictims(entries, limit, LEDGER_MAX_ENTRIES, LEDGER_MAX_TOTAL_BYTES)
    .filter((id: number): boolean => !hasEvidenceLease(filesDir, id));
}

/** 预览与删除使用同一策略；执行前仍复查租约和运行状态，避免确认期间误清理。 */
export function prune(filesDir: string): number {
  const victims = ledgerRetentionVictims(filesDir, ledgerSessionRetention(filesDir));
  let removed = 0;
  for (const id of victims) {
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
    rebuildIndex(filesDir);
  }
  return removed;
}

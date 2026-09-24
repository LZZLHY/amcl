/**
 * McSessionSnapshot.ets — 会话快照与错误 Sheet 重入（消息中心与诊断体验 · M3）
 *
 * 要解决的问题：`McErrorSheet` 原本只能靠 `AppStorage` 里的 `lastMcSession` 打开，
 * 那是**进程级、一次性**的 —— 用户关掉 Sheet 就再也回不去了。而 LogShare 的 AI 分析
 * 实测要半分钟，用户很可能等不及就先关掉，回来却发现没有任何入口。
 *
 * 做法：把「打开这个 Sheet 所需的一切」持久化成快照。按设计文档 §4.1 **不新引入
 * 一套存储**，快照字段直接挂在 `ActivityRecord` 上跟着同一份 LRU（容量 50）走；
 * 只有 AI 正文因为可能上千字，单独落盘到 `filesDir/logs/ai/<sessionKey>.md`，
 * 记录里只存路径。
 *
 * 主键 `sessionKey` = `startedAt`，与 `ActivityRecord.startedAt` 对齐 —— 不另造 id，
 * 避免两套主键对不上。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §3.2、§4
 * 创建日期：2026-07-30
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AppLogger, LOG_DOMAIN_UI } from 'commons';
import {
  findSessionLog, SessionLogLocation, readLogFileTail, formatLogBytes,
  GAME_LOG_PREVIEW_BYTES,
  ledgerDirOf, SESSION_RETENTION_DEFAULT,
  listSessionEvidence, EvidenceRole, EvidenceFileState, EvidenceFileRecord,
} from 'commons';
import {
  ActivityRecord, ActivityCategory, ActivityStatus, getDownloadHistoryStore,
} from 'feature_core';
import { McSessionInfo } from 'launch';

const TAG = 'McSessionSnapshot';

/**
 * 一次游戏会话的完整快照 —— 重新打开 `McErrorSheet` 所需的全部信息。
 */
export interface McSessionSnapshot {
  /** 稳定主键 = startedAt（与 ActivityRecord.startedAt 对齐）。 */
  sessionKey: number;
  version: string;
  mcDir: string;
  startedAt: number;
  endedAt: number;
  /** 'crashed' / 'aborted' / 'success'。 */
  outcome: string;
  /** 反查到的日志落点；找不到时为空串。 */
  logPath: string;
  /** -2 = 账本完整快照，0 = 当前局，1~3 = 工作日志归档，-1 = 找不到。 */
  logArchiveIndex: number;
  logBytes: number;
  /** 是否由会话横幅精确命中（false = 靠 mtime 猜的，或没找到）。 */
  logExact: boolean;
  /** 日志已超出保留窗口 / 找不到文件。true 时不该让用户点进空白页。 */
  logExpired: boolean;
  /** 已分享过才非空。 */
  lsId: string;
  lsUrl: string;
  lsToken: string;
  lsSharedAt: number;
  /** AI 正文落盘路径；空串 = 没有已保存的 AI 结果。 */
  aiPath: string;
}

/**
 * 默认游戏会话保留数量；实际配置由 ledgerSessionRetention 读取。
 */
export const SESSION_LOG_RETENTION: number = SESSION_RETENTION_DEFAULT;

/** 这条活动记录是不是「可以点进错误 Sheet」的启动类记录。 */
export function isReopenableRecord(rec: ActivityRecord): boolean {
  let cat = (rec.category && rec.category.length > 0) ? rec.category : '';
  if (cat !== ActivityCategory.LAUNCH) return false;
  // crashed 是真故障；aborted 是「会话被结束但没查出原因」。
  // 按 §4.3，用户主动点开时即使 not_diagnosable 也应允许 —— 他明确想看日志。
  return rec.status === ActivityStatus.CRASHED || rec.status === ActivityStatus.ABORTED;
}

/**
 * 由活动记录解析出完整快照。
 *
 * 日志落点**每次读取时重新反查**而不是信任记录里存的 `logPath` —— 归档会让文件改名
 * （mc_output.log → mc_output.1.log → …），写记录时存的路径过一局就失效了。
 * 反查靠 S2 在每局日志开头写的会话横幅精确匹配，详见 `findSessionLog`。
 *
 * @param rec           活动记录
 * @param fallbackMcDir 记录里没有 mcDir（M3 之前的旧记录）时的兜底根目录
 */
export function resolveSessionSnapshot(rec: ActivityRecord, fallbackMcDir: string): McSessionSnapshot {
  let mcDir = (rec.mcDir && rec.mcDir.length > 0) ? rec.mcDir : fallbackMcDir;
  let loc: SessionLogLocation = findSessionLog(mcDir, rec.versionName, rec.startedAt);
  const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  if (context !== undefined) {
    // 从现行证据清单定位本局正文；新路径、来源基线和旧版横幅归属共用采集层判断。
    // 尚无可信证据时保留下面旧 game.log 兼容，再回退工作日志，避免轮转误报过期。
    const files: EvidenceFileRecord[] = listSessionEvidence(context.filesDir, rec.startedAt);
    const available = files.filter((file: EvidenceFileRecord): boolean => file.bytes > 0
      && (file.attribution === 'exact' || file.attribution === 'source-baseline')
      && !file.path.endsWith('.gz')
      && (file.state === EvidenceFileState.AVAILABLE || file.state === EvidenceFileState.COMPLETE
        || file.state === EvidenceFileState.PARTIAL || file.state === EvidenceFileState.WRITING));
    const archived = available.find((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.MINECRAFT_OUTPUT)
      ?? available.find((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.MINECRAFT_MAIN);
    if (archived !== undefined) {
      loc = { path: archived.localPath, bytes: archived.bytes, exact: true, expired: false, archiveIndex: -2 };
    }
    const path = ledgerDirOf(context.filesDir, rec.startedAt) + '/game.log';
    try {
      const bytes = fs.statSync(path).size;
      if (archived === undefined && bytes > 0) loc = { path: path, bytes: bytes, exact: false, expired: false, archiveIndex: -2 };
    } catch (e) { /* 老记录或正在运行的会话由原始日志反查 */ }
  }
  let snap: McSessionSnapshot = {
    sessionKey: rec.startedAt,
    version: rec.versionName,
    mcDir: mcDir,
    startedAt: rec.startedAt,
    endedAt: (rec.endedAt !== undefined && rec.endedAt > 0) ? rec.endedAt : (rec.startedAt + rec.durationMs),
    outcome: rec.status,
    logPath: loc.path,
    logArchiveIndex: loc.archiveIndex,
    logBytes: loc.bytes,
    logExact: loc.exact,
    // 快照与工作日志均不可用，可能已清理或早于完整归档机制。
    logExpired: loc.path.length === 0,
    lsId: rec.lsId ?? '',
    lsUrl: rec.lsUrl ?? '',
    lsToken: rec.lsToken ?? '',
    lsSharedAt: rec.lsSharedAt ?? 0,
    aiPath: rec.aiPath ?? '',
  };
  return snap;
}

/** 快照 → McErrorSheet 需要的 McSessionInfo。 */
export function snapshotToSessionInfo(snap: McSessionSnapshot): McSessionInfo {
  let info: McSessionInfo = {
    startedAt: snap.startedAt,
    version: snap.version,
    mcDir: snap.mcDir,
  };
  return info;
}

/** 读该快照对应的日志尾部（重入时给 Sheet 用）。 */
export function readSnapshotLogTail(snap: McSessionSnapshot,
  maxBytes: number = GAME_LOG_PREVIEW_BYTES): string {
  if (snap.logPath.length === 0) return '';
  return readLogFileTail(snap.logPath, maxBytes).text;
}

/** 日志落点的人类可读说明（活动记录卡片与技术详情用）。 */
export function describeSnapshotLog(snap: McSessionSnapshot): string {
  if (snap.logExpired) return '日志已过期';
  let where = snap.logArchiveIndex === -2 ? '完整会话归档'
    : (snap.logArchiveIndex === 0 ? '最近一局' : ('第 ' + snap.logArchiveIndex + ' 局前的归档'));
  let size = formatLogBytes(snap.logBytes);
  return snap.logExact ? (where + ' · ' + size) : (where + ' · ' + size + '（近似匹配）');
}

// ============================================================================
//  AI 正文落盘
//
//  AI 输出实测 2000 字以上，塞进 ActivityRecord 会让整份 LRU 的 JSON 膨胀到几十倍，
//  每次写活动记录都要重新序列化全部 50 条 —— 不划算。故正文单独落盘，记录里只存路径。
// ============================================================================

/** AI 结果目录：filesDir/logs/ai/ */
function aiDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/logs/ai';
}

/** 确保目录存在（逐级建，已存在不报错）。 */
function ensureAiDir(ctx: common.UIAbilityContext): string {
  let logsDir = ctx.filesDir + '/logs';
  let dir = aiDir(ctx);
  try { fs.mkdirSync(logsDir); } catch (e) { /* 已存在 */ }
  try { fs.mkdirSync(dir); } catch (e) { /* 已存在 */ }
  return dir;
}

/** 某个 sessionKey 的 AI 正文路径。 */
export function aiTextPathOf(ctx: common.UIAbilityContext, sessionKey: number): string {
  return aiDir(ctx) + '/' + sessionKey + '.md';
}

/**
 * 保存 AI 正文并把路径写回活动记录。
 *
 * @returns 落盘路径；失败返回空串（失败只警告，不影响用户当下看到的结果）
 */
export async function saveSessionAiText(ctx: common.UIAbilityContext,
  sessionKey: number, text: string): Promise<string> {
  if (sessionKey <= 0 || text.length === 0) return '';
  let path = '';
  try {
    ensureAiDir(ctx);
    path = aiTextPathOf(ctx, sessionKey);
    let f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, text);
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    AppLogger.warn(TAG, 'saveSessionAiText failed', e, LOG_DOMAIN_UI);
    return '';
  }
  try {
    await getDownloadHistoryStore().patchSessionSnapshot(sessionKey, '', '', '', 0, path);
  } catch (e) {
    AppLogger.warn(TAG, 'patch aiPath failed', e, LOG_DOMAIN_UI);
  }
  return path;
}

/** 读回已保存的 AI 正文；没有 / 读失败返回空串。 */
export function loadSessionAiText(path: string): string {
  if (path.length === 0) return '';
  let f: fs.File | null = null;
  try {
    let total = fs.statSync(path).size;
    if (total <= 0) return '';
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(total);
    let got = fs.readSync(f.fd, buf, { offset: 0, length: total });
    if (got <= 0) return '';
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buf, 0, got));
  } catch (e) {
    return '';
  } finally {
    if (f !== null) { try { fs.closeSync(f); } catch (e) { /* ignore */ } }
  }
}

/** 把分享结果写回会话记录（分享成功后调用）。 */
export async function saveSessionShare(sessionKey: number, id: string, url: string,
  token: string, sharedAt: number): Promise<void> {
  if (sessionKey <= 0) return;
  try {
    await getDownloadHistoryStore().patchSessionSnapshot(sessionKey, id, url, token, sharedAt, '');
  } catch (e) {
    AppLogger.warn(TAG, 'saveSessionShare failed', e, LOG_DOMAIN_UI);
  }
}

/** 清掉会话记录里的分享信息（撤回成功后调用）。 */
export async function clearSessionShare(sessionKey: number, expectedShareId: string = ''): Promise<void> {
  if (sessionKey <= 0) return;
  try {
    const store = getDownloadHistoryStore();
    // 一次活动可能有多份分享；撤回旧链接时不能清掉当前诊断所引用的新链接。
    if (expectedShareId.length > 0 && store.findByStartedAt(sessionKey)?.lsId !== expectedShareId) return;
    await store.clearSessionShare(sessionKey);
  } catch (e) {
    AppLogger.warn(TAG, 'clearSessionShare failed', e, LOG_DOMAIN_UI);
  }
}

/**
 * GameLogPaths.ets — 游戏日志路径的单一解析入口（日志系统 v3 · S0）
 *
 * 背景（2026-07-30 核验）：项目里有两个读游戏日志的入口，各自只覆盖一半场景：
 *   - native `mcReadLog(mcDir)`            读 `<mcDir>/mc_output.log`
 *       → 版本隔离**开启**时真实路径在 versions/<id>/ 下，恒读不到
 *         （真机确认 `.minecraft/` 根目录下无此文件，
 *          导致 Index.exportLogToClipboard 的游戏日志段落恒为「日志文件不存在」）
 *   - ArkTS `SessionMarker.readMcLogTail`  读 `<mcDir>/versions/<id>/mc_output.log`
 *       → 版本隔离**关闭**时游戏目录退化为 mcDir 本身，恒读不到
 *
 * 本模块把「一次启动到底把日志写到哪」收敛成唯一事实源：先按候选顺序探测，
 * 取实际存在且最新的那个，两种隔离模式都能命中。
 *
 * 同时提供 MC 自带 log4j 日志（logs/latest.log、logs/debug.log）的路径 —— 2026-07-30
 * 实测确认它与 mc_output.log **内容不等价**（LWJGL 直接写 stderr 的告警只出现在
 * mc_output.log，latest.log 为 0 处），排障与上传都需要两者兼取。
 *
 * 关联：docs/guides/logging-system.md §1.1、§2 P1-3
 * 创建日期：2026-07-30
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** 进程输出日志文件名（stdout + stderr 重定向目标）。 */
export const MC_OUTPUT_LOG_NAME: string = 'mc_output.log';
/**
 * 历史局归档份数（与 native `mc_launcher.cpp` 的 MC_LOG_MAX_BACKUPS 保持一致）。
 * 归档命名：mc_output.1.log（上一局）… mc_output.3.log（最旧）。
 */
export const MC_OUTPUT_LOG_BACKUPS: number = 3;
/** MC 自带 log4j 当前局日志。 */
export const MC_LATEST_LOG_NAME: string = 'latest.log';
/** MC 自带 log4j DEBUG 级日志。 */
export const MC_DEBUG_LOG_NAME: string = 'debug.log';

/** 一次会话的日志落点解析结果。 */
export interface GameLogLocation {
  /** 本局的游戏运行目录（版本隔离开启时为 versions/<id>/，否则为 mcRoot）。 */
  gameDir: string;
  /** 进程输出日志绝对路径；解析不到时为空串。 */
  outputLogPath: string;
  /** MC log4j 当前局日志绝对路径；不存在时为空串。 */
  latestLogPath: string;
  /** MC log4j DEBUG 日志绝对路径；不存在时为空串。 */
  debugLogPath: string;
  /** true = 命中的是版本隔离布局（versions/<id>/）。 */
  isolated: boolean;
}

/** 文件是否存在且非空。 */
function existsNonEmpty(path: string): boolean {
  if (path.length === 0) return false;
  try {
    let st = fs.statSync(path);
    return st.size > 0;
  } catch (e) {
    return false;
  }
}

/** 取文件 mtime（秒）；失败返回 -1。 */
function mtimeOf(path: string): number {
  try {
    let st = fs.statSync(path);
    return st.mtime;
  } catch (e) {
    return -1;
  }
}

/** 文件存在（允许空文件）。 */
function exists(path: string): boolean {
  if (path.length === 0) return false;
  try {
    fs.statSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 解析本局游戏日志的落点。
 *
 * 候选顺序（两种隔离模式都覆盖）：
 *   1. `<mcRoot>/versions/<versionId>/mc_output.log`   —— 版本隔离布局
 *   2. `<mcRoot>/mc_output.log`                        —— 非隔离布局
 * 两个都存在时取 mtime 更新的那个（用户可能中途切过隔离开关）。
 *
 * @param mcRoot    当前激活的 .minecraft 根（由 GameStorage.resolveMcDir 解析）
 * @param versionId 版本 ID；为空时只探非隔离布局
 */
export function resolveGameLogLocation(mcRoot: string, versionId: string): GameLogLocation {
  let empty: GameLogLocation = {
    gameDir: '', outputLogPath: '', latestLogPath: '', debugLogPath: '', isolated: false,
  };
  if (!mcRoot || mcRoot.length === 0) return empty;

  let isolatedDir = (versionId && versionId.length > 0)
    ? (mcRoot + '/versions/' + versionId)
    : '';
  let isolatedLog = isolatedDir.length > 0 ? (isolatedDir + '/' + MC_OUTPUT_LOG_NAME) : '';
  let flatLog = mcRoot + '/' + MC_OUTPUT_LOG_NAME;

  let hasIsolated = existsNonEmpty(isolatedLog);
  let hasFlat = existsNonEmpty(flatLog);

  let pickIsolated = false;
  if (hasIsolated && hasFlat) {
    // 都在：取更新的那个（切过隔离开关的历史残留场景）
    pickIsolated = mtimeOf(isolatedLog) >= mtimeOf(flatLog);
  } else if (hasIsolated) {
    pickIsolated = true;
  } else if (hasFlat) {
    pickIsolated = false;
  } else {
    // 两个都没有：仍按「有 versionId 就认为是隔离布局」给出期望路径，
    // 便于调用方展示「日志尚未生成」而不是路径为空。
    let fallbackDir = isolatedDir.length > 0 ? isolatedDir : mcRoot;
    let fallback: GameLogLocation = {
      gameDir: fallbackDir,
      outputLogPath: '',
      latestLogPath: '',
      debugLogPath: '',
      isolated: isolatedDir.length > 0,
    };
    return fallback;
  }

  let gameDir = pickIsolated ? isolatedDir : mcRoot;
  let latest = gameDir + '/logs/' + MC_LATEST_LOG_NAME;
  let debug = gameDir + '/logs/' + MC_DEBUG_LOG_NAME;

  let loc: GameLogLocation = {
    gameDir: gameDir,
    outputLogPath: pickIsolated ? isolatedLog : flatLog,
    latestLogPath: exists(latest) ? latest : '',
    debugLogPath: exists(debug) ? debug : '',
    isolated: pickIsolated,
  };
  return loc;
}

/**
 * 只要进程输出日志路径（最常用的便捷封装）。
 * @returns 绝对路径；解析不到返回空串
 */
export function resolveGameOutputLogPath(mcRoot: string, versionId: string): string {
  return resolveGameLogLocation(mcRoot, versionId).outputLogPath;
}

/**
 * 本局游戏运行目录（crash-reports / options.txt 等也在这一级）。
 * 与 resolveGameLogLocation().gameDir 一致，日志不存在时也能给出期望目录。
 */
export function resolveGameDir(mcRoot: string, versionId: string): string {
  return resolveGameLogLocation(mcRoot, versionId).gameDir;
}

/** 一份历史局日志。 */
export interface ArchivedGameLog {
  /** 归档序号：1 = 上一局，数字越大越旧。 */
  index: number;
  /** 绝对路径。 */
  path: string;
  /** 字节数。 */
  bytes: number;
  /** 最后修改时间（秒）。 */
  mtime: number;
}

/**
 * 列出已归档的历史局日志（日志系统 v3 · S2）。
 *
 * native 侧每局开始前会把上一局 `mc_output.log` 归档为 `mc_output.1.log`，
 * 并依次后移，最多保留 `MC_OUTPUT_LOG_BACKUPS` 局。此函数供 UI 展示
 * 「上一局 / 上上局」的日志，让用户复现一次问题后仍能取回原始现场。
 *
 * @returns 按 index 升序（上一局在前）；无归档时返回空数组
 */
export function listArchivedGameLogs(mcRoot: string, versionId: string): ArchivedGameLog[] {
  let out: ArchivedGameLog[] = [];
  let gameDir = resolveGameDir(mcRoot, versionId);
  if (gameDir.length === 0) return out;
  for (let i = 1; i <= MC_OUTPUT_LOG_BACKUPS; i++) {
    let p = gameDir + '/mc_output.' + i + '.log';
    try {
      let st = fs.statSync(p);
      if (st.size <= 0) continue;
      let item: ArchivedGameLog = { index: i, path: p, bytes: st.size, mtime: st.mtime };
      out.push(item);
    } catch (e) {
      // 该序号没有归档，继续看下一个
    }
  }
  return out;
}
// ============================================================================
//  统一日志读取入口（日志系统 v3 · M2）
//
//  背景：此前读游戏日志有三套互不相同的口径 ——
//    - McErrorSheet 技术详情    走 SessionMarker.readMcLogTail 默认值 = 32 KB
//    - McErrorSheet 上传正文    同一函数但显式传 240 KB
//    - Index.exportLogToClipboard  走 native mcReadLog，又是另一套
//  同一份文件在同一个页面里被截成两种长度，用户看到的和上传出去的不是一份东西，
//  排障时无法判断「他看到的日志」到底缺了什么。这里收敛为唯一读取入口。
//
//  另一个必须换掉的实现细节：readMcLogTail 手写了逐字节 UTF-8 解码 + 字符串
//  累加（`s += String.fromCharCode(...)`）。那是在「ArkTS 没有 TextDecoder」的
//  错误认知下写的 —— util.TextDecoder 是有的（LogShareClient 的 SSE 一直在用）。
//  逐字符累加在 32 KB 时勉强能用，放到 M2 要求的全量读取（可达数 MB）上会产生
//  O(n) 次字符串重分配，直接卡住 UI 线程。新入口一律走 util.TextDecoder。
// ============================================================================

/** 全量读取的防御性上限：16 MB。超过只读尾部这么多，避免 OOM。 */
export const GAME_LOG_FULL_MAX_BYTES: number = 16 * 1024 * 1024;
/** 技术详情首屏默认读取的尾部字节数：64 KB（打开即可见，不卡 UI）。 */
export const GAME_LOG_PREVIEW_BYTES: number = 64 * 1024;

/** 日志文件的体积信息（算「上方还有多少没显示」用）。 */
export interface GameLogStat {
  /** 解析到的日志绝对路径；不存在时为空串。 */
  path: string;
  /** 文件总字节数；不存在时为 0。 */
  bytes: number;
  /** 最后修改时间（秒）；不存在时为 0。 */
  mtime: number;
  /** 是否存在且非空。 */
  exists: boolean;
}

/** 一次读取的结果（带够不够完整的元信息，UI 要据此决定是否显示「加载全部」）。 */
export interface GameLogRead {
  /** 日志正文。 */
  text: string;
  /** 文件总字节数。 */
  totalBytes: number;
  /** 本次实际读取的字节数。 */
  readBytes: number;
  /** true = 本次已经是全量（没有被截断）。 */
  complete: boolean;
}

/**
 * 取日志文件体积信息。
 *
 * @param mcRoot    .minecraft 根
 * @param versionId 版本 ID（为空只探非隔离布局）
 */
export function statGameLog(mcRoot: string, versionId: string): GameLogStat {
  let miss: GameLogStat = { path: '', bytes: 0, mtime: 0, exists: false };
  let path = resolveGameOutputLogPath(mcRoot, versionId);
  if (path.length === 0) return miss;
  try {
    let st = fs.statSync(path);
    let out: GameLogStat = {
      path: path,
      bytes: st.size,
      mtime: st.mtime,
      exists: st.size > 0,
    };
    return out;
  } catch (e) {
    return miss;
  }
}

/**
 * 按路径读取文件尾部若干字节并解码为 UTF-8 文本。
 *
 * 从中间切进去时首行大概率是半个字符 / 半行，故 offset > 0 时丢掉第一个换行
 * 之前的内容（只在前 512 字节内找，找不到就不丢，避免整段被吃掉）。
 *
 * @param path     绝对路径
 * @param maxBytes 最多读取的尾部字节数
 */
export function readLogFileTail(path: string, maxBytes: number): GameLogRead {
  let empty: GameLogRead = { text: '', totalBytes: 0, readBytes: 0, complete: true };
  if (path.length === 0 || maxBytes <= 0) return empty;

  let total = 0;
  try {
    total = fs.statSync(path).size;
  } catch (e) {
    return empty;
  }
  if (total <= 0) return empty;

  let offset = total > maxBytes ? total - maxBytes : 0;
  let length = total - offset;
  let f: fs.File | null = null;
  try {
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(length);
    let got = fs.readSync(f.fd, buf, { offset: offset, length: length });
    let bytes = new Uint8Array(buf, 0, got > 0 ? got : 0);
    // util.TextDecoder 走原生解码，不做逐字符字符串累加（详见本节顶部注释）。
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let text = decoder.decodeToString(bytes);
    if (offset > 0) {
      let nl = text.indexOf('\n');
      if (nl >= 0 && nl < 512) text = text.substring(nl + 1);
    }
    let out: GameLogRead = {
      text: text,
      totalBytes: total,
      readBytes: got > 0 ? got : 0,
      complete: offset === 0,
    };
    return out;
  } catch (e) {
    return empty;
  } finally {
    if (f !== null) { try { fs.closeSync(f); } catch (e) { /* ignore */ } }
  }
}

/**
 * 读本局游戏日志的尾部（技术详情首屏 / 诊断用）。
 *
 * @param maxBytes 默认 GAME_LOG_PREVIEW_BYTES（64 KB）
 */
export function readGameLogTail(
  mcRoot: string, versionId: string, maxBytes: number = GAME_LOG_PREVIEW_BYTES
): GameLogRead {
  let path = resolveGameOutputLogPath(mcRoot, versionId);
  return readLogFileTail(path, maxBytes);
}

/**
 * 读本局游戏日志全量（技术详情「加载全部」/ 上传正文用）。
 *
 * 带 16 MB 防御性上限：真实日志远小于此，但模组疯狂刷日志时文件可以涨到很大，
 * 一次性全读进字符串会 OOM。超限时退化为读尾部 16 MB 并把 `complete` 置 false，
 * 让 UI 能诚实地告诉用户「只显示了尾部」。
 */
export function readGameLogFull(
  mcRoot: string, versionId: string, maxBytes: number = GAME_LOG_FULL_MAX_BYTES
): GameLogRead {
  let path = resolveGameOutputLogPath(mcRoot, versionId);
  return readLogFileTail(path, maxBytes);
}

/** 把字节数格式化成人类可读（日志体积提示用）。 */
export function formatLogBytes(bytes: number): string {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
}

// ============================================================================
//  按会话反查日志文件（M3：错误 Sheet 可重入的前提）
//
//  问题：活动记录里只有 startedAt，而磁盘上同时存在当前局 mc_output.log 与最多 3 份
//  归档 mc_output.1~3.log。要让用户从活动记录点回某一次崩溃，必须能回答
//  「这条记录对应哪个文件」。
//
//  靠 mtime 猜是不可靠的（归档时 mtime 会被复制/改名影响，且两局间隔可能很短）。
//  好在 S2 已经让 native 在每局日志开头写了机器可解析的会话横幅：
//      ##AMCL-SESSION-BEGIN {"startedAt":"2026-07-30 19:12:03","epochMs":1785...,"gameDir":"..."}
//  于是直接读每个候选文件的头部、解析 epochMs、取与目标 startedAt 最接近的那个即可。
//
//  时间差容忍度：native 的横幅写在 phase_redirectIO（JVM 起来之前），而
//  `SessionMarker.writeStart` 的 startedAt 是 ArkTS 侧在启动成功后取的 Date.now()，
//  两者天然相差若干秒，因此不能要求相等。
// ============================================================================

/** 会话与日志文件的匹配容忍度：5 分钟。超过这个差值视为不是同一局。 */
const SESSION_MATCH_TOLERANCE_MS: number = 5 * 60 * 1000;
/** 解析会话横幅时读取的文件头字节数。 */
const SESSION_BANNER_PROBE_BYTES: number = 2048;

/** 一局日志在磁盘上的落点。 */
export interface SessionLogLocation {
  /** 绝对路径；没找到时为空串。 */
  path: string;
  /** 0 = 当前局 mc_output.log；1~3 = 归档 mc_output.N.log；-1 = 未找到。 */
  archiveIndex: number;
  /** 文件字节数。 */
  bytes: number;
  /** 是否通过会话横幅精确匹配到（false = 猜的 / 没找到）。 */
  exact: boolean;
  /** 该局日志是否已被后续会话挤出保留窗口。 */
  expired: boolean;
}

/** 读取文件头部若干字节（解析会话横幅用）。 */
export function readLogFileHead(path: string, maxBytes: number): string {
  if (path.length === 0 || maxBytes <= 0) return '';
  let f: fs.File | null = null;
  try {
    let total = fs.statSync(path).size;
    if (total <= 0) return '';
    let length = total < maxBytes ? total : maxBytes;
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(length);
    let got = fs.readSync(f.fd, buf, { offset: 0, length: length });
    if (got <= 0) return '';
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buf, 0, got));
  } catch (e) {
    return '';
  } finally {
    if (f !== null) { try { fs.closeSync(f); } catch (e) { /* ignore */ } }
  }
}

/**
 * 从日志头部解析 native 写的会话横幅时间戳。
 *
 * 只用正则抓 `"epochMs":<数字>`，不整体 JSON.parse —— 横幅后面紧跟游戏输出，
 * 整行未必是合法 JSON（且将来横幅加字段也不该让解析失败）。
 *
 * @returns epochMs；解析不到返回 0
 */
export function parseSessionBannerEpoch(headText: string): number {
  if (headText.length === 0) return 0;
  let at = headText.indexOf('##AMCL-SESSION-BEGIN');
  if (at < 0) return 0;
  let seg = headText.substring(at, at + 300);
  let m = seg.match(/"epochMs"\s*:\s*(\d+)/);
  if (m === null) return 0;
  let v = Number.parseInt(m[1], 10);
  return Number.isNaN(v) ? 0 : v;
}

/** 只读取会话横幅本行里的活动 ID；正文中出现别局 ID 不能改变文件归属。 */
export function readSessionBannerActivityId(path: string): number {
  const head: string = readLogFileHead(path, SESSION_BANNER_PROBE_BYTES);
  const start: number = head.indexOf('##AMCL-SESSION-BEGIN');
  if (start < 0) return 0;
  const end: number = head.indexOf('\n', start);
  const banner: string = head.substring(start, end >= 0 ? end : head.length);
  const match = banner.match(new RegExp('"activityId"\\s*:\\s*(\\d+)'));
  const id: number = match === null ? 0 : Number(match[1]);
  return Number.isSafeInteger(id) && id > 0 ? id : 0;
}

/**
 * 在当前局 + 归档里找出 `startedAt` 这一局的日志文件。
 *
 * 匹配策略：读每个候选的头部横幅，取 |epochMs - startedAt| 最小且在容忍度内的那个。
 * 全都没有横幅（S2 之前产生的旧日志）时退化为 mtime 最接近的候选，并把 `exact`
 * 置 false，让 UI 能区分「精确命中」与「大概是这个」。
 *
 * @param startedAt 活动记录里的会话开始时间（ms）
 */
export function findSessionLog(mcRoot: string, versionId: string, startedAt: number): SessionLogLocation {
  let miss: SessionLogLocation = {
    path: '', archiveIndex: -1, bytes: 0, exact: false, expired: true,
  };
  if (!mcRoot || mcRoot.length === 0 || startedAt <= 0) return miss;

  // 候选：当前局 + 归档
  let paths: string[] = [];
  let indices: number[] = [];
  const directories: string[] = [mcRoot];
  if (versionId.length > 0) directories.unshift(mcRoot + '/versions/' + versionId);
  for (const directory of directories) {
    for (let i = 0; i <= MC_OUTPUT_LOG_BACKUPS; i++) {
      const path = directory + '/mc_output' + (i === 0 ? '' : '.' + i) + '.log';
      if (existsNonEmpty(path)) { paths.push(path); indices.push(i); }
    }
  }
  if (paths.length === 0) return miss;

  let bestIdx = -1;
  let bestDiff = -1;
  let bestExact = false;

  // 第一轮：按会话横幅精确匹配
  for (let i = 0; i < paths.length; i++) {
    const head = readLogFileHead(paths[i], SESSION_BANNER_PROBE_BYTES);
    const identity: number = readSessionBannerActivityId(paths[i]);
    if (identity > 0) {
      if (identity === startedAt) { bestIdx = i; bestExact = true; break; }
      continue;
    }
    let epoch = parseSessionBannerEpoch(head);
    if (epoch <= 0) continue;
    let diff = Math.abs(epoch - startedAt);
    if (diff > SESSION_MATCH_TOLERANCE_MS) continue;
    // 旧格式只有 native 重定向时刻，五分钟窗口内可能有多局，不能标为精确归档。
    if (bestDiff < 0 || diff < bestDiff) { bestDiff = diff; bestIdx = i; bestExact = false; }
  }

  // 第二轮：旧日志没有横幅 → 退化为 mtime 最接近
  if (bestIdx < 0) {
    let startedSec = Math.floor(startedAt / 1000);
    for (let i = 0; i < paths.length; i++) {
      // 带横幅却不匹配的日志属于别局，不能用 mtime 强行归属。
      if (readSessionBannerActivityId(paths[i]) > 0
        || parseSessionBannerEpoch(readLogFileHead(paths[i], SESSION_BANNER_PROBE_BYTES)) > 0) continue;
      let mt = mtimeOf(paths[i]);
      if (mt < 0) continue;
      let diff = Math.abs(mt - startedSec) * 1000;
      if (diff > SESSION_MATCH_TOLERANCE_MS) continue;
      if (bestDiff < 0 || diff < bestDiff) { bestDiff = diff; bestIdx = i; bestExact = false; }
    }
  }

  if (bestIdx < 0) return miss;

  let bytes = 0;
  try { bytes = fs.statSync(paths[bestIdx]).size; } catch (e) { bytes = 0; }
  let found: SessionLogLocation = {
    path: paths[bestIdx],
    archiveIndex: indices[bestIdx],
    bytes: bytes,
    exact: bestExact,
    expired: false,
  };
  return found;
}

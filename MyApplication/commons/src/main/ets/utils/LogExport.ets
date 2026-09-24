/**
 * LogExport.ets — 日志外发的唯一出口（日志系统 v3 · S0）
 *
 * 背景（2026-07-30 核验）：历史上不同页面各自拼接日志并直接外发，
 * 现在活动页、错误页、电脑诊断和作者提交都必须先经过统一快照脱敏。
 * 且 `redactToken` 的规则只覆盖 token 形态（JWT / OAuth JSON / Bearer / ≥40 长 base64），
 * 玩家名、带连字符 UUID（36 字符 < 40 阈值）、XUID、服务器地址、聊天内容全都漏。
 *
 * LogShare 的服务端过滤链由实例动态配置决定，不能把某一次 `/v1/filters` 响应
 * 当成永久契约。2026-09-23 的官方实例已经启用 IPv4 / IPv6 / IPv6Short / UUID /
 * XUID / SessionToken / ClientId / Coordinate / Username / AccessToken 等规则；
 * 客户端仍必须先脱敏，因为备用实例、历史部署和后续配置可能不同，且服务端过滤
 * 可能在上传后的异步审核阶段再次改写正文。
 *
 * 本模块提供**唯一漏斗** `sanitizeLogForExport()`：脱敏 + 按 UTF-8 字节截断。
 * 规则：任何离开设备或进入剪贴板的日志文本都必须过这里。
 *
 * 关联：docs/guides/logging-system.md §3.9、logshare-api-reference.md §3
 * 创建日期：2026-07-30
 */

import { redactToken } from './Redact';

// ============================================================
//  UTF-8 字节长度与截断
// ============================================================

/**
 * 计算字符串的 UTF-8 字节长度。
 *
 * 为什么需要：ArkTS 的 `string.length` 是 UTF-16 码元数，中文字符占 1 但 UTF-8 是 3 字节。
 * 旧单正文路径曾用 `string.length` 判断，中文日志会按 UTF-16 码元计数而低估真实字节。
 */
export function utf8ByteLength(s: string): number {
  if (!s || s.length === 0) return 0;
  let bytes = 0;
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) {
      bytes += 1;
    } else if (c < 0x800) {
      bytes += 2;
    } else if (c >= 0xD800 && c <= 0xDBFF) {
      // 高位代理：与后面的低位代理合成一个 4 字节字符
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/**
 * 按 UTF-8 字节数截断，保留**尾部**（最新内容更相关）。
 * 不会切出半个字符：从截断点向后推进到一个完整字符边界。
 *
 * @param s        原文
 * @param maxBytes 上限（UTF-8 字节）
 * @returns        截断后的文本；被截断时前置一行说明
 */
export function truncateUtf8Tail(s: string, maxBytes: number): string {
  if (!s || maxBytes <= 0) return '';
  if (utf8ByteLength(s) <= maxBytes) return s;

  // 从尾部往前累加字节，直到接近上限
  let bytes = 0;
  let startIdx = s.length;
  for (let i = s.length - 1; i >= 0; i--) {
    let c = s.charCodeAt(i);
    let add = 0;
    if (c >= 0xDC00 && c <= 0xDFFF) {
      // 低位代理：与前一个高位代理一起算 4 字节
      add = 4;
      i--;
    } else if (c < 0x80) {
      add = 1;
    } else if (c < 0x800) {
      add = 2;
    } else {
      add = 3;
    }
    if (bytes + add > maxBytes) break;
    bytes += add;
    startIdx = i;
  }
  let tail = s.substring(startIdx);
  // 尽量从一个完整行开始，避免半截行
  let nl = tail.indexOf('\n');
  if (nl >= 0 && nl < 400) tail = tail.substring(nl + 1);
  return '...[头部已截断，仅保留最近 ' + maxBytes + ' 字节]...\n' + tail;
}

/**
 * 按 UTF-8 字节数截断，**同时保留头部与尾部**，中间写省略标记。
 *
 * 为什么需要这个（P1-4，日志系统重构 · P5）：只保尾会丢**启动期根因**
 * —— 类加载失败、Mixin apply 失败、依赖冲突都发生在日志头部；
 * 只保头会丢**失败现场**。两端都要。
 * `logging-system.md` §3.8 早就写明了这个策略（「头 4 MiB + 尾 12 MiB」），
 * 只是导出路径一直没用上。
 *
 * @param s         原文
 * @param maxBytes  上限（UTF-8 字节）
 * @param headRatio 头部占比（0~1）。默认 0.3：根因通常比现场更短，
 *                  但完全不留头就等于把一整类问题排除在证据之外。
 */
export function truncateUtf8HeadTail(s: string, maxBytes: number,
  headRatio: number = 0.3): string {
  if (!s || maxBytes <= 0) return '';
  let total = utf8ByteLength(s);
  if (total <= maxBytes) return s;

  let r = headRatio;
  if (r < 0) r = 0;
  if (r > 1) r = 1;
  // 省略标记本身要占字节，从预算里先扣掉，否则结果会超过 maxBytes。
  const MARKER_RESERVE = 96;
  let usable = maxBytes - MARKER_RESERVE;
  if (usable <= 0) return truncateUtf8Tail(s, maxBytes);

  let headBudget = Math.floor(usable * r);
  let tailBudget = usable - headBudget;
  if (headBudget <= 0) return truncateUtf8Tail(s, maxBytes);
  if (tailBudget <= 0) return truncateUtf8Head_(s, usable);

  let head = truncateUtf8Head_(s, headBudget);
  let tailPart = truncateUtf8Tail(s, tailBudget);
  // truncateUtf8Tail 会自带一行头部截断说明，这里换成更准确的省略说明。
  let nl = tailPart.indexOf('\n');
  if (nl >= 0 && tailPart.startsWith('...[头部已截断')) tailPart = tailPart.substring(nl + 1);

  let omitted = total - utf8ByteLength(head) - utf8ByteLength(tailPart);
  if (omitted < 0) omitted = 0;
  return head + '\n...[中间省略 ' + omitted + ' 字节；保留头 '
    + utf8ByteLength(head) + ' + 尾 ' + utf8ByteLength(tailPart) + ' 字节]...\n' + tailPart;
}

/** 按 UTF-8 字节截断保留**头部**，不切出半个字符。内部用。 */
function truncateUtf8Head_(s: string, maxBytes: number): string {
  if (!s || maxBytes <= 0) return '';
  let bytes = 0;
  let endIdx = 0;
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    let add = 0;
    let step = 1;
    if (c >= 0xD800 && c <= 0xDBFF) {
      add = 4;
      step = 2;
    } else if (c < 0x80) {
      add = 1;
    } else if (c < 0x800) {
      add = 2;
    } else {
      add = 3;
    }
    if (bytes + add > maxBytes) break;
    bytes += add;
    i += step - 1;
    endIdx = i + 1;
  }
  let head = s.substring(0, endIdx);
  // 尽量停在完整行边界
  let nl = head.lastIndexOf('\n');
  if (nl > 0 && head.length - nl < 400) head = head.substring(0, nl);
  return head;
}

// ============================================================
//  游戏日志专项脱敏规则
// ============================================================

/** 标准连字符 UUID（36 字符，长度低于 redactToken 的 40 阈值，故必须单独处理）。 */
const UUID_HYPHEN = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;
/** 带上下文的无连字符 UUID（避免误伤 MD5 资产哈希，必须有 uuid 字样才处理）。 */
const UUID_LABELED = /(uuid["'\s]*[:=]["'\s]*)([0-9a-fA-F]{32})/gi;
/** Xbox User ID。 */
const XUID_LABELED = /(xuid["'\s]*[:=]["'\s]*)(\d{8,})/gi;
/** MC 启动参数里的玩家名。 */
const ARG_USERNAME = /(--username\s+)(\S+)/g;
/** MC 客户端启动时打印的登录用户名。 */
const SETTING_USER = /(Setting user:\s*)(\S+)/g;
/** "UUID of player X is Y" —— 玩家名与 UUID 同时出现。 */
const PLAYER_UUID_LINE = /(UUID of player\s+)(\S+)(\s+is\s+)(\S+)/gi;
/** 聊天内容整行打码（保留标记，便于知道"这里有过聊天"）。 */
const CHAT_LINE = /(\[CHAT\]\s*).*/g;
/** 连接的服务器地址与端口。 */
const CONNECTING_TO = /(Connecting to\s+)([^\s,]+)(,\s*\d+)?/gi;
/** 公共存储路径里的用户序号目录。 */
const EMULATED_USER = /(\/storage\/emulated\/)(\d+)/g;
/** 类 Unix / Windows 的用户主目录段。 */
const HOME_USER_DIR = /((?:\/home\/|\/Users\/|\\Users\\))([^\/\\\s]+)/g;

/** 统一的打码占位符（与 LogShare 服务端风格保持一致，便于用户理解）。 */
const MASK = '********';
const MASK_UUID = '********-****-****-****-************';

/**
 * 在 `redactToken` 之上叠加游戏日志专项脱敏。
 *
 * 只处理**可识别的身份/位置信息**，不动版本号、路径中的技术目录名、异常堆栈 ——
 * 这些是排障必需的。特别注意不要模仿 LogShare 的 IPv4 过滤器：它把 NeoForge 的
 * 四段式版本号（26.1.2.87）也打码了，实测毁掉了 5 处关键版本信息。
 */
export function redactGameLog(s: string | null | undefined): string {
  if (s === null || s === undefined) return '';
  if (s.length === 0) return s;

  // 第一层：既有的 token 脱敏（JWT / OAuth JSON / Bearer / 长 base64）
  let out = redactToken(s);

  // 第二层：身份信息
  out = out.replace(PLAYER_UUID_LINE, (m: string, p1: string, p2: string, p3: string, p4: string) => {
    return p1 + MASK + p3 + MASK_UUID;
  });
  out = out.replace(UUID_LABELED, (m: string, p1: string, p2: string) => {
    return p1 + MASK_UUID;
  });
  out = out.replace(UUID_HYPHEN, MASK_UUID);
  out = out.replace(XUID_LABELED, (m: string, p1: string, p2: string) => {
    return p1 + MASK;
  });
  out = out.replace(ARG_USERNAME, (m: string, p1: string, p2: string) => {
    return p1 + MASK;
  });
  out = out.replace(SETTING_USER, (m: string, p1: string, p2: string) => {
    return p1 + MASK;
  });

  // 第三层：位置 / 社交内容
  out = out.replace(CHAT_LINE, (m: string, p1: string) => {
    return p1 + '[已移除聊天内容]';
  });
  out = out.replace(CONNECTING_TO, (m: string, p1: string, p2: string, p3: string) => {
    return p1 + MASK + (p3 !== undefined && p3 !== null ? p3 : '');
  });
  out = out.replace(EMULATED_USER, (m: string, p1: string, p2: string) => {
    return p1 + '*';
  });
  out = out.replace(HOME_USER_DIR, (m: string, p1: string, p2: string) => {
    return p1 + MASK;
  });

  return out;
}

// ============================================================
//  统一出口
// ============================================================

/** 外发用途，决定默认体积上限。 */
export enum LogExportTarget {
  /** 剪贴板：给的是人看，放宽一点。 */
  CLIPBOARD = 0,
  /** AMCL-web /api/logs：服务端单条上限 256 KB，留余量。 */
  AMCL_WEB = 1,
  /** 旧单文本 LogShare 导出的本地默认预算；多文件分享由本次实例 limits 和快照预算决定。 */
  LOGSHARE = 2,
}

/**
 * 各外发目标的默认字节上限。
 * 导出为公开 API 是因为 `ledgerExport` 要**先按这个预算给各 part 分配配额**，
 * 而不能等拼完再截（那会把环境头与启动器日志挤掉，见 LogExportBudget.ets 头注释）。
 */
export function exportLimitOf(target: LogExportTarget): number {
  return defaultLimitOf(target);
}

function defaultLimitOf(target: LogExportTarget): number {
  if (target === LogExportTarget.AMCL_WEB) return 240 * 1024;
  if (target === LogExportTarget.LOGSHARE) return 10 * 1024 * 1024;
  return 512 * 1024;
}

/**
 * **所有日志外发路径的唯一入口。**
 *
 * 做两件事，顺序不可颠倒：
 *   1. 脱敏（`redactGameLog`，含 token 层）
 *   2. 按 UTF-8 字节截断到目标上限，保留尾部
 *
 * @param text     原始日志文本（会话摘要 + 各段日志拼好后传进来）
 * @param target   外发目标，决定默认上限
 * @param maxBytes 显式上限（可选，覆盖默认值）
 */
export function sanitizeLogForExport(text: string, target: LogExportTarget,
  maxBytes: number = 0): string {
  let limit = maxBytes > 0 ? maxBytes : defaultLimitOf(target);
  let redacted = redactGameLog(text);
  return truncateUtf8Tail(redacted, limit);
}

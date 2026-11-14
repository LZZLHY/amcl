/**
 * LogShareClient.ets — LogShare.CN 客户端（日志系统 v3 · S7）
 *
 * 新分享优先使用官方 LogShare，服务故障时使用 AMCL 备用实例。
 *
 * 接口以当前 https://logshare.cn/api-docs 为准；历史实测偏差仅作排查记录。
 * 新旧实例统一使用 JSON files[]；metadata 显式声明显示名称和公开范围。
 * 上传结果字段在顶层，DELETE 使用 Bearer token；去重响应不授予新的删除权。
 * 网络异常保留 NetworkKit code，HTTP 与 API code 分别返回，不能混成一句 message。
 *
 * 隐私约定：
 *   1. 上传前必须过 `sanitizeLogForExport(text, LogExportTarget.LOGSHARE)`。
 *   2. `token` 必须持久化，否则用户无法撤回已分享的日志。
 *   3. 留存期必须来自本次实例 limits；官网示例默认值不能覆盖线上配置。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common, bundleManager } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_UI } from 'commons';
import { sanitizeLogForExport, LogExportTarget, utf8ByteLength, isSafeEvidencePath, stringToUtf8, ensureDirSync, writeEvidenceTextAtomic,
  evidenceTextDigest } from 'commons';
import { LogShareErrorResult, LogShareRequestError, logShareTransportError, setLogShareError } from './LogShareErrors';
import { LogShareSseSink } from './LogShareSse';

const TAG = 'LogShareClient';

/** API 基址。实测 /v1 与 /1 等价，统一用文档主推的 /v1。 */
export const LOGSHARE_API_BASE = 'https://api.logshare.cn';
export const LOGSHARE_WEB_BASE = 'https://logshare.cn';
export const LOGSHARE_BACKUP_API_BASE = 'https://amcl.lovedhy.cn/logshare-api';
export const LOGSHARE_BACKUP_WEB_BASE = 'https://amcl.lovedhy.cn/logshare';
export const LOGSHARE_UNAVAILABLE = '日志分享暂不可用';
const BASE = LOGSHARE_API_BASE;

/** 分享链接保留实际实例身份，读取和撤回不得跨实例发送凭据。 */
export function logShareInstanceForUrl(url: string): string {
  if (url.startsWith(LOGSHARE_WEB_BASE + '/')) return BASE;
  if (url.startsWith('https://www.logshare.cn/')) return BASE;
  if (url.startsWith(LOGSHARE_BACKUP_WEB_BASE + '/')) return LOGSHARE_BACKUP_API_BASE;
  return '';
}
/** 官方已移除生成式 AI，备用实例也不提供；历史报告读取不受此开关影响。 */
export const LOGSHARE_AI_UNAVAILABLE: string = 'LogShare AI 分析已下线，日志分享和规则分析仍可使用';
export function logShareSupportsAi(_url: string): boolean { return false; }
export function canonicalLogShareUrl(apiBase: string, id: string): string {
  if (!isAllowedInstance(apiBase) || !isValidLogShareId(id)) throw new Error('分享身份无效');
  return (apiBase === BASE ? LOGSHARE_WEB_BASE : LOGSHARE_BACKUP_WEB_BASE) + '/' + id;
}
export function logShareSourceLabel(url: string): string {
  return logShareInstanceForUrl(url) === BASE ? 'LogShare 官方' : 'AMCL 备用服务';
}
function isAllowedInstance(base: string): boolean { return base === BASE || base === LOGSHARE_BACKUP_API_BASE; }
export interface LogShareAttempt extends LogShareErrorResult { apiBaseUrl: string; }
export function canRetryLogShare(result: LogShareErrorResult): boolean {
  // 这个函数只供“只读预检”使用。POST 一旦发出，即使收到 5xx/断连，
  // 服务端也可能已经落库；不能把它当成安全的自动重试授权。
  if (result.errorStage !== 'transport' && result.errorStage !== 'response') return false;
  return (result.httpStatus ?? 0) === 0;
}
/** 保留大文件上传的既有长读超时；停用 AI 不改变上传容错窗口。 */
export const LOGSHARE_READ_TIMEOUT_MS: number = 300000;
/**
 * 客户端安全预算与服务端 `/v1/limits` 是两套不同的概念：
 *
 * - 新实例返回文件数、展开总量和请求体限制，旧实例返回逐文件大小和行数；
 * - 下列常量只限制本地快照、JSON 解压和读回时的内存/CPU 风险，不能冒充服务端限额。
 *
 * 新实例最多使用 20 MiB 正文/32 MiB JSON 的本地预算；旧实例沿用 12/20 MiB，
 * 缺少新字段不能被解释为旧服务自动获得更大容量。
 */
export const LOGSHARE_MULTIFILE_EXPANSION_BUDGET_BYTES: number = 20 * 1024 * 1024;
const LOGSHARE_LEGACY_TOTAL_BYTES: number = 12 * 1024 * 1024;
const LOGSHARE_LEGACY_REQUEST_BYTES: number = 20 * 1024 * 1024;
export const LOGSHARE_LOCAL_JSON_SAFE_CAP_BYTES: number = 32 * 1024 * 1024;
export const LOGSHARE_LOCAL_READBACK_FILE_SAFE_CAP_BYTES: number = 20 * 1024 * 1024;
export const LOGSHARE_LOCAL_READBACK_TOTAL_SAFE_CAP_BYTES: number = 24 * 1024 * 1024;
export const LOGSHARE_LOCAL_RESPONSE_SAFE_CAP_BYTES: number = 24 * 1024 * 1024;

/** limits 请求失败时的占位值；ok=false 时禁止据此上传。 */
const DEFAULT_LIMIT_BYTES_PLACEHOLDER = LOGSHARE_LOCAL_JSON_SAFE_CAP_BYTES;
/** limits 请求失败时的占位行数；ok=false 时禁止据此上传。 */
const MAX_UPLOAD_LINES = 200000;
/** 多文件上限（官方 API 文档；备用实例也以更小者为准）。 */
const MAX_UPLOAD_FILES = 200;
/** 当前官方文档的留存天数；可通过 limits 查询。 */
export const LOGSHARE_STORAGE_DAYS = 7;

/** files[] 的主文件顺序：latest → 真正崩溃报告 → 启动器 → 其他可选文件。 */
function logShareFilePriority_(name: string): number {
  if (name === 'game/logs/latest.log') return 0;
  if (name.startsWith('crash-reports/') || name.startsWith('jvm/hs_err')
    || name.startsWith('system/crash-report-')) return 1;
  if (name.startsWith('launcher/')) return 2;
  if (name.startsWith('_amcl/')) return 4;
  return 3;
}

// ============================================================
//  返回类型
// ============================================================

/** POST /v1/log 结果。 */
export interface LogShareSubmitResult extends LogShareErrorResult {
  /** 命中已有日志时返回的临时 token 无删除权，必须丢弃。 */
  deduplicated?: boolean;
  apiBaseUrl?: string;
  usedFallback?: boolean;
  storageTimeSec?: number;
  attempts?: LogShareAttempt[];
  remoteFilesVerified?: boolean;
  verificationError?: string;
  /** 实际发送顺序，远端将 files[0] 表示为 main 时仍能精确核对。 */
  uploadedPaths?: string[];
  uploadedReceipts?: LogShareContentReceipt[];
  ok: boolean;
  /** 日志 ID（如 "RqRNLim"）。 */
  id: string;
  /** 分享页面地址（给用户复制）。 */
  url: string;
  /** 原文地址。 */
  rawUrl: string;
  /** 删除凭据 —— **必须持久化**，否则无法撤回。 */
  token: string;
  /** ok=false 时的原因（已本地化，可直接提示）。 */
  error: string;
}

/** 分享编排在任何额外网络读取之前保存接收凭据；不改变没有持久化上下文的底层调用方。 */
export interface LogShareDeliveryHooks {
  onAccepted: (result: LogShareSubmitResult) => Promise<void>;
  deferVerification: boolean;
}

/** 核对结果与接收成功分开；不能把核对失败变成另一次 POST 的理由。 */
export interface LogShareVerification {
  verified: boolean;
  warning: string;
  /** names-only / content-verified / server-changed / missing / unavailable。 */
  contentStatus?: string;
  received?: LogShareContentReceipt[];
}
/** 已实际发送的脱敏正文收据；不存正文或本地路径，重启后仍可重新核对原链接。 */
export interface LogShareContentReceipt {
  name: string; bytes: number; sha256: string; main?: boolean;
  boundaryNewlineSha256?: string;
}

/** 仅规范化首尾 CR/LF，不忽略空格、不改写中间行；用单独摘要描述已知服务端边界处理。 */
function boundaryNewlineDigest_(text: string): string {
  return evidenceTextDigest(text.replace(new RegExp('^[\\r\\n]+|[\\r\\n]+$', 'g'), ''));
}

/** analysis.problems / analysis.information 里的一项。 */
export interface LogShareInsight {
  message: string;
  label: string;
  value: string;
  counter: number;
}

/** 已存储文件的 GET /v1/insights 规则分析结果，区别于已下线的生成式 AI。 */
export interface LogShareAnalysis extends LogShareErrorResult {
  /** 多文件响应要求调用方选择明确文件，不能伪装成空分析成功。 */
  requiresFileSelection?: boolean;
  files?: string[];
  ok: boolean;
  /** 识别到的日志类型标识，如 "neoforge/server"。 */
  id: string;
  /** 服务端名，如 "NeoForge"。 */
  name: string;
  /** 实测：AMCL 的**客户端**日志也会被判成 "Server Log"。 */
  type: string;
  version: string;
  title: string;
  problems: LogShareInsight[];
  information: LogShareInsight[];
  error: string;
}

/** DELETE /v1/log/{id} 结果。 */
export interface LogShareDeleteResult extends LogShareErrorResult {
  ok: boolean;
  deleted: string[];
  failed: string[];
  error: string;
}

/** GET /v1/limits 结果。 */
export interface LogShareLimits extends LogShareErrorResult {
  ok: boolean;
  storageTimeSec: number;
  maxBytes: number;
  maxLines: number;
  /** 统一后的文件数、展开正文总量和原始/解压 JSON 请求体限额。 */
  maxFiles: number;
  maxTotalBytes: number;
  maxRequestBodyBytes: number;
  error: string;
}

/**
 * 总量使用实例配额与客户端安全预算的较小者；旧实例的逐文件限额另行核对。
 * 预检失败时返回零，调用方不能用占位值取得上传资格。
 */
export function logShareExportBudgetBytes(limits: LogShareLimits): number {
  return limits.ok ? Math.min(limits.maxTotalBytes, LOGSHARE_MULTIFILE_EXPANSION_BUDGET_BYTES) : 0;
}

/** 预览时确认的服务与保留期；确认上传不能静默改投另一实例。 */
export interface LogSharePreflight {
  apiBaseUrl: string;
  limits: LogShareLimits;
  checkedAt: number;
  attempts: LogShareAttempt[];
}

export async function prepareLogShare(): Promise<LogSharePreflight> {
  const attempts: LogShareAttempt[] = [];
  for (const base of [BASE, LOGSHARE_BACKUP_API_BASE]) {
    const limits = await getLimits(base);
    if (limits.ok) return { apiBaseUrl: base, limits: limits, checkedAt: Date.now(), attempts: attempts };
    attempts.push({ apiBaseUrl: base, error: limits.error, errorStage: limits.errorStage,
      networkCode: limits.networkCode, httpStatus: limits.httpStatus, apiCode: limits.apiCode });
  }
  throw new Error(LOGSHARE_UNAVAILABLE + '，可导出本地 ZIP 后稍后重试');
}

/** 上传时附带的元信息（会 JSON 序列化进 metadata 字段）。 */
export interface LogShareMetadata {
  launcher: string;
  appVersion: string;
  mcVersion: string;
  loader: string;
  jdk: string;
  device: string;
  osVersion: string;
  outcome: string;
  /** 公开摘要之外的稳定活动标识；不包含本地绝对路径。 */
  activityId?: number;
  snapshot?: string;
  uploaderVersion?: string;
  hostOs?: string;
  hostApi?: string;
  cpu?: string;
  gpu?: string;
  gpuProbe?: string;
  graphicsProfile?: string;
  graphicsProvider?: string;
  javaBuild?: string;
  environmentSchema?: string;
  /** 已记录的整合包标识；未知时不上传猜测值。 */
  modpack?: string;
}

// ============================================================
//  请求体（显式类型，规避 arkts-no-untyped-obj-literals）
// ============================================================

interface LogSubmitBody {
  content?: string;
  source: string;
  metadata?: LogShareMetadataItem[];
  files?: LogShareFile[];
}

/** 官方 JSON metadata 数组：值已脱敏，显示名称和可见性由客户端明确声明。 */
export interface LogShareMetadataItem {
  key: string;
  value: string;
  label?: string;
  visible?: boolean;
}

/** LogShare 多文件上传中的一个纯文本文件。 */
export interface LogShareFile {
  /** 安全相对路径；不能是绝对路径或含 .. 的路径。 */
  name: string;
  /** 已在客户端脱敏的正文。 */
  content: string;
}

export function logShareMetadataItems(meta: LogShareMetadata): LogShareMetadataItem[] {
  const items: LogShareMetadataItem[] = [
    { key: 'launcher', value: meta.launcher, label: '启动器', visible: true },
    { key: 'appVersion', value: meta.appVersion, label: '问题发生时的应用版本', visible: true },
    { key: 'version', value: meta.mcVersion, label: 'Minecraft 版本', visible: true },
    { key: 'loader', value: meta.loader, label: '模组加载器', visible: true },
    { key: 'jdk', value: meta.jdk, label: 'Java 运行时', visible: true },
    { key: 'device', value: meta.device, label: '设备型号', visible: true },
    { key: 'osVersion', value: meta.osVersion, label: '系统版本', visible: true },
    { key: 'outcome', value: meta.outcome, label: '会话结果', visible: true },
    { key: 'modpack', value: meta.modpack ?? '', label: '整合包', visible: true },
  ];
  if (meta.activityId !== undefined && meta.activityId > 0) {
    items.push({ key: 'activityId', value: String(meta.activityId), label: '活动关联标识', visible: false });
  }
  if (meta.snapshot !== undefined && meta.snapshot.length > 0) {
    items.push({ key: 'snapshot', value: meta.snapshot, label: '快照校验摘要', visible: false });
  }
  const extra: LogShareMetadataItem[] = [
    { key: 'uploaderVersion', value: meta.uploaderVersion ?? '' }, { key: 'hostOs', value: meta.hostOs ?? '' },
    { key: 'hostApi', value: meta.hostApi ?? '' }, { key: 'cpu', value: meta.cpu ?? '' },
    { key: 'gpu', value: meta.gpu ?? '' }, { key: 'gpuProbe', value: meta.gpuProbe ?? '' },
    { key: 'graphicsProfile', value: meta.graphicsProfile ?? '' }, { key: 'graphicsProvider', value: meta.graphicsProvider ?? '' },
    { key: 'javaBuild', value: meta.javaBuild ?? '' }, { key: 'environmentSchema', value: meta.environmentSchema ?? '' },
  ];
  // 扩展字段沿用已记录事实，不从当前设备补造历史环境。隐藏仅影响公开元信息，
  // 不能作为保存秘密的手段；所有 value 仍先经过统一脱敏。
  const labels: string[] = ['上传客户端版本', '主机系统', '主机 API', 'CPU', 'GPU', 'GPU 探测结果',
    '图形方案', '图形提供者', 'Java 构建', '环境格式版本'];
  for (let index = 0; index < extra.length; index++) {
    const item = extra[index]; item.label = labels[index]; item.visible = item.key !== 'environmentSchema'; items.push(item);
  }
  for (const item of items) item.value = Array.from(sanitizeLogForExport(item.value, LogExportTarget.LOGSHARE, 4096)).slice(0, 1024).join('');
  return items.filter((item: LogShareMetadataItem): boolean => item.value.trim().length > 0).slice(0, 100);
}

/** 产品调用补上安装包的实际版本；诊断工具自定义 source 原样保留。 */
export function resolveLogShareSource(source: string): string {
  if (source !== 'amcl-launcher') return source.substring(0, 64);
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return ('amcl/' + info.versionName).substring(0, 64);
  } catch (e) {
    return 'amcl/unknown';
  }
}

/** /v1/log 响应：当前文档规定字段平铺在顶层。 */
interface RemoteLogFile { name: string; size?: number; }
interface RemoteLogFiles { id?: string; files?: RemoteLogFile[]; }

interface SubmitResp {
  deduplicated?: boolean;
  code?: number | string;
  success?: boolean;
  message?: string;
  id?: string;
  url?: string;
  raw?: string;
  token?: string;
  error?: string;
}

interface AnalyseRespAnalysis {
  problems?: LogShareInsight[];
  information?: LogShareInsight[];
}

/** 规则分析响应与多文件选择响应共用此网络边界，解析时必须区分。 */
interface AnalyseResp {
  requiresFileSelection?: boolean;
  files?: RemoteLogFile[];
  id?: string;
  name?: string;
  type?: string;
  version?: string;
  title?: string;
  analysis?: AnalyseRespAnalysis;
  success?: boolean;
  error?: string;
}

interface LogShareDeleteFailure {
  id: string;
  message: string;
  code: number;
}
interface DeleteResp {
  success?: boolean;
  deleted?: string[];
  failed?: Array<string | LogShareDeleteFailure>;
  errors?: LogShareDeleteFailure[];
  error?: string;
}

interface LimitsResp {
  storageTime?: number;
  maxLength?: number;
  maxLines?: number;
  maxFiles?: number;
  maxTotalBytes?: number;
  maxRequestBodyBytes?: number;
  error?: string;
}

// ============================================================
//  工具
// ============================================================

/** 把 HTTP 状态码与响应体归一成可直接提示用户的中文原因。 */
function normalizeError(code: number, body: string): string {
  let serverMsg = '';
  try {
    // 实测错误字段名是 `error`（不是文档写的 message）
    let parsed = JSON.parse(body) as SubmitResp;
    serverMsg = parsed.error ?? parsed.message ?? '';
  } catch (e) { /* 非 JSON 响应，忽略 */ }

  if (code === 400) return serverMsg.length > 0 ? ('请求参数错误：' + serverMsg) : '请求参数错误';
  if (code === 403) return '凭据无效或权限不足';
  if (code === 404) return serverMsg.toLowerCase().indexOf('ai analysis is disabled') >= 0 ? 'AI 服务暂未开启' : '日志不存在或已过期';
  if (code === 413) return '日志过大，已超过服务端上限';
  if (code === 415) return '服务端不接受该内容类型';
  if (code === 429) return '请求过于频繁，请稍后再试';
  if (code >= 500) return '服务端内部错误，请稍后再试';
  return serverMsg.length > 0 ? serverMsg : ('请求失败 (' + code + ')');
}

function httpFailure(code: number, body: string): LogShareRequestError {
  let apiCode = '';
  let serverMessage = '';
  try {
    const parsed = JSON.parse(body) as SubmitResp;
    if (parsed.code !== undefined) apiCode = String(parsed.code);
    serverMessage = parsed.error ?? parsed.message ?? '';
  } catch (e) { /* HTML/空响应仍保留 HTTP 状态 */ }
  const detail = sanitizeLogForExport(serverMessage, LogExportTarget.LOGSHARE, 1024);
  const message = '[HTTP ' + code + (apiCode.length > 0 ? ' / API ' + apiCode : '') + '] '
    + normalizeError(code, body) + (detail.length > 0 && code !== 400 ? '；' + detail : '');
  return new LogShareRequestError(message, 'http', 0, code, apiCode);
}

/** 本地校验日志 ID（借鉴官方 SDK 的正则，避免把明显非法的 id 发出去）。 */
export function isValidLogShareId(id: string): boolean {
  if (!id || id.length < 6) return false;
  return /^[a-zA-Z0-9]+$/.test(id);
}

/** 大 JSON 在发送前 gzip；传输结果不明时不改编码重投。 */
async function gzipShareJson_(text: string): Promise<ArrayBuffer | undefined> {
  if (utf8ByteLength(text) < 32 * 1024) return undefined;
  const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  if (context === undefined) return undefined;
  const path: string = context.tempDir + '/logshare-' + util.generateRandomUUID(true) + '.gz';
  const gzip = zlib.createGZipSync();
  let closed: boolean = false;
  try {
    await gzip.gzopen(path, 'wb');
    const input: Uint8Array = stringToUtf8(text);
    if (await gzip.gzwrite(input.buffer as ArrayBuffer, input.byteLength) !== input.byteLength) throw new Error('gzip 请求短写');
    if (await gzip.gzclosew() !== 0) throw new Error('gzip 请求封装失败');
    closed = true;
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = (await fs.stat(file.fd)).size;
      const output = new ArrayBuffer(size);
      if (await fs.read(file.fd, output) !== size) throw new Error('gzip 请求读取不完整');
      return output;
    } finally { await fs.close(file); }
  } finally {
    if (!closed) { try { await gzip.gzclosew(); } catch (ignored) { /* 保留主错误 */ } }
    try { fs.unlinkSync(path); } catch (ignored) { /* 尚未创建 */ }
  }
}

/** 统一的 JSON 请求。 */
async function postJson(path: string, bodyJson: string, apiBase: string = BASE,
  requestLimit: number = LOGSHARE_LOCAL_JSON_SAFE_CAP_BYTES): Promise<string> {
  if (!isAllowedInstance(apiBase)) throw new Error('日志分享实例无效');
  let compressed: ArrayBuffer | undefined = undefined;
  try {
    // 完整 JSON 的转义开销也计入实例请求体限额，压缩不能绕过解压后上限。
    // 引号、反斜杠和控制字符转义会膨胀，必须在 gzip 和发送之前核对真实字节数。
    const budget: number = Math.min(requestLimit, LOGSHARE_LOCAL_JSON_SAFE_CAP_BYTES);
    if (utf8ByteLength(bodyJson) > budget) {
      throw new Error('JSON 请求超过本次请求体安全预算（' + budget + ' 字节），请减少所选文件或导出 ZIP');
    }
    compressed = await gzipShareJson_(bodyJson);
    if (compressed !== undefined && compressed.byteLength > requestLimit) {
      throw new Error('压缩后的请求体超过本次实例限额');
    }
  } catch (e) {
    // 此时尚未创建网络请求，不能告诉用户“已上传但结果未知”。
    throw new LogShareRequestError('本地分享准备失败：' + (e as Error).message, 'local-prepare');
  }
  const req = http.createHttp();
  try {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
    if (compressed !== undefined) headers['Content-Encoding'] = 'gzip';
    const res = await req.request(apiBase + path, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: compressed ?? bodyJson,
      connectTimeout: 10000,
      readTimeout: LOGSHARE_READ_TIMEOUT_MS,
      // NetworkKit maxLimit 是本地响应读取预算，不是服务端 maxLength。
      maxLimit: LOGSHARE_LOCAL_RESPONSE_SAFE_CAP_BYTES,
    });
    let body = typeof res.result === 'string' ? res.result : '';
    if (res.responseCode !== 200 && res.responseCode !== 201) {
      throw httpFailure(res.responseCode, body);
    }
    return body;
  } catch (e) {
    throw logShareTransportError(e as Error);
  } finally {
    req.destroy();
  }
}

/** 统一的 GET 请求。 */
async function getText(path: string, apiBase: string = BASE, timeoutMs: number = LOGSHARE_READ_TIMEOUT_MS,
  maxBytes: number = LOGSHARE_LOCAL_RESPONSE_SAFE_CAP_BYTES): Promise<string> {
  if (!isAllowedInstance(apiBase)) throw new Error('日志分享实例无效');
  const req = http.createHttp();
  try {
    const res = await req.request(apiBase + path, {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'application/json' },
      connectTimeout: Math.min(10000, timeoutMs),
      readTimeout: timeoutMs,
      maxLimit: maxBytes,
    });
    let body = typeof res.result === 'string' ? res.result : '';
    if (res.responseCode !== 200) {
      throw httpFailure(res.responseCode, body);
    }
    return body;
  } catch (e) {
    throw logShareTransportError(e as Error);
  } finally {
    req.destroy();
  }
}

// ============================================================
//  端点封装
// ============================================================

/**
 * 提交并存储日志，返回分享链接与删除凭据。
 *
 * @param rawContent 原始日志文本（**本函数内部会做脱敏**，调用方不必先处理）
 * @param source     来源标识（最长 64 字符）
 * @param meta       元信息，可选
 */
export async function submitLog(rawContent: string, source: string,
  meta?: LogShareMetadata): Promise<LogShareSubmitResult> {
  return submitLogFiles([{ name: 'launcher/launcher-host.log', content: rawContent }], source, meta);
}

/**
 * 上传一次会话的多个独立文件。
 *
 * 这是 U08 的主路径。调用方必须先根据活动页复选结果冻结文件内容；
 * 本函数只负责逐文件脱敏、路径校验、限额预检和请求，不会读取未选择的文件。
 */
export async function submitLogFiles(rawFiles: LogShareFile[], source: string,
  meta?: LogShareMetadata, preflight?: LogSharePreflight, hooks?: LogShareDeliveryHooks): Promise<LogShareSubmitResult> {
  const files: LogShareFile[] = [];
  let totalBytes = 0;
  // 纯文件模型每份正文只计一次；旧实例额外保留逐文件大小和行数检查。
  let maxFileBytes = 0;
  let maxFileLines = 0;
  for (const raw of rawFiles) {
    if (!isSafeEvidencePath(raw.name)) {
      return { ok: false, id: '', url: '', rawUrl: '', token: '',
        error: '日志文件名不是安全相对路径：' + raw.name };
    }
    if (files.some((file: LogShareFile): boolean => file.name === raw.name)) {
      return { ok: false, id: '', url: '', rawUrl: '', token: '',
        error: '日志文件名重复，无法生成明确的远端文件集合：' + raw.name };
    }
    const content: string = sanitizeLogForExport(
      raw.content, LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER);
    if (content.trim().length === 0) continue;
    const file: LogShareFile = { name: raw.name, content: content };
    files.push(file);
    const fileBytes: number = utf8ByteLength(content);
    const fileLines: number = content.split('\n').length;
    totalBytes += fileBytes;
    maxFileBytes = Math.max(maxFileBytes, fileBytes);
    maxFileLines = Math.max(maxFileLines, fileLines);
  }
  if (files.length === 0) {
    return { ok: false, id: '', url: '', rawUrl: '', token: '', error: '没有可上传的日志文件' };
  }
  if (files.length > MAX_UPLOAD_FILES) {
    return { ok: false, id: '', url: '', rawUrl: '', token: '', error: '日志文件数量超过 200 个上限' };
  }
  // 发送顺序方便旧实例将 files[0] 作为主日志。新实例不保证该顺序，读取必须使用文件名。
  files.sort((a: LogShareFile, b: LogShareFile): number => {
    const ap: number = logShareFilePriority_(a.name);
    const bp: number = logShareFilePriority_(b.name);
    if (ap !== bp) return ap - bp;
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  });
  const body: LogSubmitBody = { source: resolveLogShareSource(source), files: files };
  // 诊断概览已是具名文件，不再作为 content 重复上传；避免生成额外 latest.log，
  // 也避免把概览当成游戏主日志交给规则分析。
  if (meta !== undefined) body.metadata = logShareMetadataItems(meta);
  return submitPayload_(body, totalBytes, maxFileBytes, maxFileLines, preflight, hooks);
}

async function submitPayload_(body: LogSubmitBody, bytes: number,
  maxFileBytes: number, maxFileLines: number, preflight?: LogSharePreflight,
  hooks?: LogShareDeliveryHooks): Promise<LogShareSubmitResult> {
  const out: LogShareSubmitResult = { ok: false, id: '', url: '', rawUrl: '', token: '', error: '' };
  if (bytes <= 0 || maxFileBytes <= 0 || maxFileLines <= 0) { out.error = '没有可上传的日志内容'; return out; }
  const attempts: LogShareAttempt[] = [];
  // 先访问官方和备用的 limits。只有主站“只读预检”失败，才允许选择备用实例；
  // 这样不会因为一次未知 POST 结果而跨实例盲目重投。
  let instance: string = preflight?.apiBaseUrl ?? BASE;
  if (!isAllowedInstance(instance)) { out.error = '分享服务无效，请重新预览'; return out; }
  let limits = preflight?.limits ?? await getLimits(BASE);
  if (!limits.ok && preflight === undefined) {
    attempts.push({ apiBaseUrl: BASE, error: limits.error, errorStage: limits.errorStage,
      networkCode: limits.networkCode, httpStatus: limits.httpStatus, apiCode: limits.apiCode });
    limits = await getLimits(LOGSHARE_BACKUP_API_BASE);
    instance = LOGSHARE_BACKUP_API_BASE;
  }
  if (!limits.ok) {
    attempts.push({ apiBaseUrl: LOGSHARE_BACKUP_API_BASE, error: limits.error, errorStage: limits.errorStage,
      networkCode: limits.networkCode, httpStatus: limits.httpStatus, apiCode: limits.apiCode });
    out.error = LOGSHARE_UNAVAILABLE;
    out.errorStage = 'unavailable';
    out.attempts = attempts;
    for (const attempt of attempts) AppLogger.warn(TAG, 'share preflight unavailable: ' + attempt.apiBaseUrl + ' ' + attempt.error, null, LOG_DOMAIN_UI);
    return out;
  }
  const exportBudget: number = logShareExportBudgetBytes(limits);
  // 旧实例没有公开可见性保证；隐藏字段直接不发送，不能仅依赖旧服务尊重 visible。
  if (limits.maxBytes !== Number.MAX_SAFE_INTEGER && body.metadata !== undefined) {
    body.metadata = body.metadata.filter((item: LogShareMetadataItem): boolean => item.visible !== false);
  }
  if ((body.files?.length ?? 0) > Math.min(limits.maxFiles, MAX_UPLOAD_FILES)) {
    out.error = '所选文件数量超过本次实例上限（' + Math.min(limits.maxFiles, MAX_UPLOAD_FILES) + ' 个）';
    out.errorStage = 'validation'; return out;
  }
  if (maxFileBytes > limits.maxBytes || bytes > exportBudget || maxFileLines > limits.maxLines) {
    if (maxFileBytes > limits.maxBytes) {
      out.error = '单个日志文件超过本次实例服务端 maxLength（' + limits.maxBytes
        + ' 字节）；请减少该文件或导出完整 ZIP';
    } else if (bytes > exportBudget) {
      out.error = '所选多文件正文超过本次展开安全预算（' + exportBudget
        + ' 字节）；请减少所选文件或导出完整 ZIP';
    } else {
      out.error = '所选日志超过本次实例服务端 maxLines（' + limits.maxLines
        + ' 行）；请减少超限文件或导出完整 ZIP';
    }
    out.errorStage = 'validation'; return out;
  }

  const result = await submitToInstance(instance, body, limits, hooks);
  result.storageTimeSec = limits.storageTimeSec;
  result.usedFallback = instance === LOGSHARE_BACKUP_API_BASE;
  result.attempts = attempts;
  if (result.ok) return result;

  // POST 已经尝试过。无论是网络断连、响应解析失败还是 HTTP 5xx，都不再自动
  // 向另一实例发同一份内容；调用方仍可保留本地 ZIP 并让用户显式再次操作。
  if (result.errorStage === 'transport' || result.errorStage === 'response'
    || (result.httpStatus ?? 0) >= 500 || result.httpStatus === 408) {
    result.error += '；上传结果未知，请勿自动重试，保留本地完整证据后再手动确认。';
    result.errorStage = 'unknown-outcome';
  }
  return result;
}

async function submitToInstance(apiBase: string, body: LogSubmitBody, limits: LogShareLimits,
  hooks?: LogShareDeliveryHooks): Promise<LogShareSubmitResult> {
  const out: LogShareSubmitResult = { ok: false, id: '', url: '', rawUrl: '', token: '', error: '', apiBaseUrl: apiBase,
    storageTimeSec: limits.storageTimeSec };
  try {
    const text = await postJson('/v1/log', JSON.stringify(body), apiBase, limits.maxRequestBodyBytes);
    const resp = JSON.parse(text) as SubmitResp;
    out.id = resp.id ?? ''; out.url = resp.url ?? ''; out.rawUrl = resp.raw ?? '';
    out.deduplicated = resp.deduplicated === true;
    // 去重响应签发的 token 未存储，不能发送给 DELETE，更不能覆盖首次上传的有效凭据。
    out.token = out.deduplicated ? '' : resp.token ?? '';
    out.uploadedPaths = (body.files ?? []).map((file: LogShareFile): string => file.name);
    out.uploadedReceipts = (body.files ?? []).map((file: LogShareFile): LogShareContentReceipt => {
      return { name: file.name, bytes: utf8ByteLength(file.content), sha256: evidenceTextDigest(file.content),
        boundaryNewlineSha256: boundaryNewlineDigest_(file.content) };
    });
    if (body.content !== undefined && body.content.length > 0) {
      out.uploadedReceipts.push({ name: 'main', main: true, bytes: utf8ByteLength(body.content), sha256: evidenceTextDigest(body.content),
        boundaryNewlineSha256: boundaryNewlineDigest_(body.content) });
    }
    out.ok = resp.success !== false && isValidLogShareId(out.id)
      && logShareInstanceForUrl(out.url) === apiBase && (out.token.length > 0 || out.deduplicated === true)
      && (out.url === canonicalLogShareUrl(apiBase, out.id)
        || apiBase === BASE && out.url === 'https://www.logshare.cn/' + out.id);
    if (!out.ok) {
      out.error = resp.error ?? resp.message ?? '服务端未返回完整的分享链接和撤回凭据';
      out.errorStage = 'api';
      if (resp.code !== undefined) { out.apiCode = String(resp.code); out.error = '[API ' + out.apiCode + '] ' + out.error; }
    }
    // id/token 已知后，先交给上层原子落盘。无效 URL 的已知凭据也要保存供撤回。
    if (hooks !== undefined && isValidLogShareId(out.id) && (out.token.length > 0 || out.ok && out.deduplicated === true)) {
      try { await hooks.onAccepted(out); }
      catch (e) {
        out.ok = false; out.errorStage = 'persist';
        out.error = '服务端已返回接收凭据，但本地保存失败；请重试保存，不要重新上传';
        return out;
      }
    }
    if (out.ok) {
      if (hooks?.deferVerification) {
        out.remoteFilesVerified = false; out.verificationError = '分享已保存，正在核对远端文件清单';
      } else {
        const verification = await verifyLogShareFiles(out.id, (body.files ?? []).map((file: LogShareFile): string => file.name), apiBase);
        out.remoteFilesVerified = verification.verified; out.verificationError = verification.warning;
      }
      AppLogger.info(TAG, 'submitLog ok provider=' + apiBase + ' id=' + out.id, LOG_DOMAIN_UI);
    }
  } catch (e) { setLogShareError(out, e as Error); }
  return out;
}

/** 只读核对独立于上传；超时更短，失败仍保留已生成链接和可撤回凭据。 */
const LOGSHARE_READBACK_ATTEMPTS: number = 3;
const LOGSHARE_READBACK_DELAYS_MS: number[] = [0, 200, 500];

interface LogShareFileCheck {
  verification: LogShareVerification;
  retryable: boolean;
}

async function waitForReadback_(attempt: number): Promise<void> {
  const delay: number = LOGSHARE_READBACK_DELAYS_MS[attempt] ?? 0;
  if (delay <= 0) return;
  await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, delay); });
}

function retryableReadbackError_(error: Error): boolean {
  // 解析失败/本地校验错误不是网络暂态，重试相同响应没有依据。
  if (!(error instanceof LogShareRequestError)) return false;
  // 429 已经携带服务端限流语义。当前读回重试只有 0/200/500ms 三个短窗口，
  // 不足以安全遵守 Retry-After；立即结束核对并保留凭据，避免后台核对本身制造限流。
  if (error.httpStatus === 429) return false;
  // 官方契约把 404/其他 4xx 作为不存在或请求错误；异步审核只会在已持久化
  // 后处理或删除，不定义“先返回空文件清单、稍后补齐”的 GET 状态。
  return error.stage === 'transport' || error.httpStatus >= 500;
}

async function verifyLogShareFilesOnce_(id: string, expected: string[], apiBase: string): Promise<LogShareFileCheck> {
  try {
    const remote = JSON.parse(await getText('/v1/log/' + id, apiBase, 10000)) as RemoteLogFiles;
    if (remote === null || !Array.isArray(remote.files) || remote.files.length > MAX_UPLOAD_FILES) {
      return { verification: { verified: false, warning: '远端文件清单格式无效，链接与撤回凭据已保存' }, retryable: false };
    }
    const names: string[] = [];
    for (const file of remote.files) {
      if (file === null || typeof file.name !== 'string' || !isSafeEvidencePath(file.name) || names.includes(file.name)) {
        return { verification: { verified: false, warning: '远端文件清单含无效或重复名称' }, retryable: false };
      }
      names.push(file.name);
    }
    // 新上传仅使用具名 files，完整清单应与实际发送集合一致。旧历史主 raw 收据另行读取。
    // 严格按名称集合核对，
    // 不能用“数量少一个”猜测主文件，否则清单为空时会把缺失文件误报为已收到。
    const verified: boolean = remote.id === id && names.length === expected.length
      && expected.every((name: string): boolean => names.indexOf(name) >= 0);
    return {
      verification: { verified: verified, warning: verified ? '' : '远端文件清单尚未核对通过，可在分享页核对' },
      // HTTP 200 的清单不一致是缺失/已变更事实，不按猜测重试；只有网络或 5xx
      // 可能是传输层暂态，才由外层做有限 GET 重试。
      retryable: false,
    };
  } catch (e) {
    return {
      verification: { verified: false, warning: '远端文件清单暂不可读，链接和撤回凭据已保存' },
      retryable: retryableReadbackError_(e as Error),
    };
  }
}

export async function verifyLogShareFiles(id: string, expected: string[], apiBase: string): Promise<LogShareVerification> {
  if (!isAllowedInstance(apiBase) || !isValidLogShareId(id) || expected.length > MAX_UPLOAD_FILES
    || expected.some((name: string): boolean => !isSafeEvidencePath(name)) || new Set<string>(expected).size !== expected.length) {
    return { verified: false, warning: '没有有效的文件清单可核对', contentStatus: 'unavailable' };
  }
  let last: LogShareVerification = { verified: false, warning: '远端文件清单暂不可读，链接和撤回凭据已保存' };
  for (let attempt: number = 0; attempt < LOGSHARE_READBACK_ATTEMPTS; attempt++) {
    await waitForReadback_(attempt);
    const check = await verifyLogShareFilesOnce_(id, expected, apiBase);
    last = check.verification;
    if (check.verification.verified || !check.retryable) return check.verification;
  }
  return last;
}

/**
 * 凭据落盘后逐文件读回实际正文；名称相同不等于完整。只比较实际出站脱敏版本，
 * 服务端再次过滤/反混淆导致不一致时明确记录 server-changed，绝不宣称已字节核验。
 * GET 失败不重投 POST；总文件数/字节受已保存上传收据和客户端上限约束。
 */
export async function verifyLogShareContents(id: string, expected: LogShareContentReceipt[],
  apiBase: string): Promise<LogShareVerification> {
  if (!isAllowedInstance(apiBase) || !isValidLogShareId(id) || expected.length === 0 || expected.length > MAX_UPLOAD_FILES + 1) {
    return { verified: false, warning: '没有可核对的正文收据', contentStatus: 'unavailable' };
  }
  const names = await verifyLogShareFiles(id, expected.filter((item: LogShareContentReceipt): boolean => !item.main)
    .map((item: LogShareContentReceipt): string => item.name), apiBase);
  if (!names.verified) return { verified: false, warning: names.warning, contentStatus: 'missing' };
  const received: LogShareContentReceipt[] = [];
  let total: number = 0;
  let changed: boolean = false;
  let normalized: boolean = false;
  try {
    for (const item of expected) {
      if ((!item.main && !isSafeEvidencePath(item.name)) || item.bytes < 0
        || item.bytes > LOGSHARE_LOCAL_READBACK_FILE_SAFE_CAP_BYTES) throw new Error('正文收据超出本地读回安全预算');
      total += item.bytes;
      if (total > LOGSHARE_LOCAL_READBACK_TOTAL_SAFE_CAP_BYTES) throw new Error('正文核对超出本地总预算');
      const suffix: string = item.main ? '' : '/' + item.name.split('/').map((part: string): string => encodeURIComponent(part)).join('/');
      const content: string = await readBackRawWithRetry_('/v1/raw/' + id + suffix, apiBase, item.bytes);
      const receipt: LogShareContentReceipt = { name: item.name, main: item.main,
        bytes: utf8ByteLength(content), sha256: evidenceTextDigest(content), boundaryNewlineSha256: boundaryNewlineDigest_(content) };
      received.push(receipt);
      if (receipt.bytes !== item.bytes || receipt.sha256 !== item.sha256) {
        if (item.boundaryNewlineSha256 && receipt.boundaryNewlineSha256 === item.boundaryNewlineSha256) normalized = true;
        else changed = true;
      }
    }
    return { verified: !changed, contentStatus: changed ? 'server-changed' : normalized ? 'boundary-newlines-normalized' : 'content-verified', received: received,
      warning: changed ? '文件可读取，但服务端内容与客户端脱敏快照不同（可能再次过滤或反混淆），尚未确认内容等价。'
        : normalized ? '正文已读回核对一致；服务端调整了首尾换行，本地完整副本保持不变。'
          : '所有已发送文件及主概览已按字节数与摘要读回核对。' };
  } catch (e) {
    return { verified: false, warning: '远端正文核对未完成：' + (e as Error).message,
      contentStatus: 'unavailable', received: received };
  }
}

/** 仅网络/5xx 允许有限 GET 重试；异步审核删除或正文改写不构成重传依据。 */
async function readBackRawWithRetry_(path: string, apiBase: string, expectedBytes: number): Promise<string> {
  let lastError: Error = new Error('远端正文暂不可读');
  const maxReadBytes: number = Math.min(LOGSHARE_LOCAL_RESPONSE_SAFE_CAP_BYTES,
    Math.max(65536, expectedBytes * 2 + 4096));
  for (let attempt: number = 0; attempt < LOGSHARE_READBACK_ATTEMPTS; attempt++) {
    await waitForReadback_(attempt);
    try {
      return await getText(path, apiBase, 15000, maxReadBytes);
    } catch (e) {
      lastError = e as Error;
      if (!retryableReadbackError_(lastError)) break;
    }
  }
  throw lastError;
}

/** 规则分析只接受真实 analysis；200 文件列表必须交还调用方选择文件。 */
function parseAnalysis(text: string): LogShareAnalysis {
  const out: LogShareAnalysis = {
    ok: false, id: '', name: '', type: '', version: '', title: '',
    problems: [], information: [], error: '',
  };
  let resp = JSON.parse(text) as AnalyseResp;
  if (resp.error && resp.error.length > 0) {
    out.error = resp.error;
    return out;
  }
  if (Array.isArray(resp.files)) {
    if (resp.files.length === 0 || resp.files.length > MAX_UPLOAD_FILES
      || resp.files.some((file: RemoteLogFile): boolean => file === null || typeof file.name !== 'string' || !isSafeEvidencePath(file.name))) {
      out.error = '规则分析返回的文件清单无效'; return out;
    }
    out.files = resp.files.map((file: RemoteLogFile): string => file.name);
    out.requiresFileSelection = true; out.error = '这条日志包含多个文件，请先选择要分析的文件'; return out;
  }
  if (resp.success === false || resp.analysis === undefined || resp.analysis === null) {
    out.error = '服务端未返回有效的规则分析结果'; return out;
  }
  out.id = resp.id ?? '';
  out.name = resp.name ?? '';
  out.type = resp.type ?? '';
  out.version = resp.version ?? '';
  out.title = resp.title ?? '';
  if (resp.analysis !== undefined) {
    out.problems = resp.analysis.problems ?? [];
    out.information = resp.analysis.information ?? [];
  }
  out.ok = true;
  return out;
}

export async function getInsights(id: string, apiBase: string = BASE, filename?: string): Promise<LogShareAnalysis> {
  const result: LogShareAnalysis = { ok: false, id: '', name: '', type: '', version: '', title: '', problems: [], information: [], error: '备用分享不支持分析' };
  if (apiBase !== BASE) return result;
  if (!isValidLogShareId(id)) { result.error = '日志 ID 无效'; return result; }
  if (filename !== undefined && !isSafeEvidencePath(filename)) { result.error = '日志文件名无效'; return result; }
  const suffix: string = filename === undefined ? '' : '/' + filename.split('/').map((part: string): string => encodeURIComponent(part)).join('/');
  try { return parseAnalysis(await getText('/v1/insights/' + id + suffix, apiBase)); }
  catch (e) { setLogShareError(result, e as Error); return result; }
}

/**
 * 删除（撤回）已分享的日志。
 *
 * 当前文档路径为 `/v1/log/{id}`，Authorization 使用 Bearer token。
 */
export async function deleteLogs(ids: string[], token: string, apiBase: string = BASE): Promise<LogShareDeleteResult> {
  const out: LogShareDeleteResult = { ok: false, deleted: [], failed: [], error: '' };
  if (ids.length === 0) { out.error = '没有要删除的日志'; return out; }
  if (ids.length > 256 || ids.some((id: string): boolean => !isValidLogShareId(id))) {
    out.error = '日志 ID 无效或超过单次删除上限'; return out;
  }
  if (!token || token.length === 0) { out.error = '缺少删除凭据（token）'; return out; }
  if (!isAllowedInstance(apiBase)) { out.error = '分享实例无效，未发送撤回凭据'; return out; }

  const req = http.createHttp();
  try {
    const res = await req.request(apiBase + '/v1/log/' + ids.join(','), {
      method: http.RequestMethod.DELETE,
      header: { 'Authorization': 'Bearer ' + token },
      connectTimeout: 10000,
      readTimeout: LOGSHARE_READ_TIMEOUT_MS,
    });
    let body = typeof res.result === 'string' ? res.result : '';
    if (res.responseCode !== 200) {
      // 新旧实例均可能用 HTTP 400 包装全部不存在的结果，逐项确认 404 后才视为已撤回。
      try {
        const payload = JSON.parse(body) as DeleteResp;
        const missing = payload.errors ?? payload.failed;
        if (missing !== undefined && missing.length === ids.length
          && missing.every((item: string | LogShareDeleteFailure): boolean => typeof item !== 'string' && item.code === 404 && ids.includes(item.id))) {
          out.ok = true;
          return out;
        }
      } catch (e) { /* 其他失败保留 HTTP 原因与凭据，供用户重试。 */ }
      setLogShareError(out, httpFailure(res.responseCode, body));
      return out;
    }
    let resp = JSON.parse(body) as DeleteResp;
    out.deleted = resp.deleted ?? [];
    out.failed = (resp.failed ?? []).map((item: string | LogShareDeleteFailure): string => typeof item === 'string' ? item : item.id);
    out.ok = resp.success === true && out.failed.length === 0;
    if (!out.ok) out.error = resp.error ?? '删除失败';
    else AppLogger.info(TAG, 'deleteLogs ok count=' + out.deleted.length, LOG_DOMAIN_UI);
  } catch (e) {
    setLogShareError(out, logShareTransportError(e as Error));
    AppLogger.warn(TAG, 'deleteLogs failed', e, LOG_DOMAIN_UI);
  } finally {
    req.destroy();
  }
  return out;
}

/** 只接受完整、正整数的限额；出现任意新版字段时必须完整采用新版模型。 */
function validLimit_(value: number | undefined): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

/** 查询所选实例的真实限额；新模型不再施加旧版逐文件大小、行数约束。 */
export async function getLimits(apiBase: string = BASE): Promise<LogShareLimits> {
  const out: LogShareLimits = {
    ok: false, storageTimeSec: LOGSHARE_STORAGE_DAYS * 86400,
    maxBytes: DEFAULT_LIMIT_BYTES_PLACEHOLDER, maxLines: MAX_UPLOAD_LINES,
    maxFiles: MAX_UPLOAD_FILES, maxTotalBytes: 0, maxRequestBodyBytes: 0, error: '',
  };
  try {
    const resp = JSON.parse(await getText('/v1/limits', apiBase, 6000)) as LimitsResp;
    if (resp === null || resp.error || !validLimit_(resp.storageTime)) throw new Error('服务端限制格式无效');
    const modern: boolean = resp.maxFiles !== undefined || resp.maxTotalBytes !== undefined || resp.maxRequestBodyBytes !== undefined;
    if (modern) {
      if (!validLimit_(resp.maxFiles) || !validLimit_(resp.maxTotalBytes) || !validLimit_(resp.maxRequestBodyBytes)) {
        throw new Error('服务端新版限制字段不完整或无效');
      }
      out.maxFiles = resp.maxFiles ?? 0;
      out.maxTotalBytes = resp.maxTotalBytes ?? 0;
      out.maxRequestBodyBytes = resp.maxRequestBodyBytes ?? 0;
      // 这两个内部值表示“服务端未设逐文件限制”，本地读回安全预算仍单独生效。
      out.maxBytes = Number.MAX_SAFE_INTEGER; out.maxLines = Number.MAX_SAFE_INTEGER;
    } else {
      if (!validLimit_(resp.maxLength) || !validLimit_(resp.maxLines)) throw new Error('服务端旧版限制格式无效');
      out.maxBytes = resp.maxLength ?? 0; out.maxLines = resp.maxLines ?? 0;
      out.maxTotalBytes = LOGSHARE_LEGACY_TOTAL_BYTES; out.maxRequestBodyBytes = LOGSHARE_LEGACY_REQUEST_BYTES;
    }
    out.storageTimeSec = resp.storageTime ?? 0; out.ok = true;
  } catch (e) { setLogShareError(out, e as Error); }
  return out;
}

// ============================================================
//  AI 分析（SSE 流式）
// ============================================================

/** streamAiAnalysis 的回调集合。 */
export interface AiStreamCallbacks extends LogShareSseSink {
  /** 秒数只用于限制重试，不能作为分析完成倒计时。 */
  onRetryAfter?: (seconds: number) => void;
  /** 每拿到一段正文增量就回调一次（已剔除思维链）。 */
  onDelta: (text: string) => void;
  /** 流正常结束。 */
  onDone: (fullText: string) => void;
  /** 失败。 */
  onError: (message: string) => void;
}

/** 可用于中途取消的句柄。 */
export interface AiStreamHandle {
  cancel: () => void;
}

/**
 * 旧调用方的兼容边界：官方已移除 AI 服务，立即返回明确原因，不创建 HTTP 请求。
 * 历史 SSE 解析器和报告格式保留给本地历史读取；恢复其他提供方须另行建立契约。
 */
export function streamAiAnalysis(_id: string, cb: AiStreamCallbacks, _apiBase: string = BASE): AiStreamHandle {
  cb.onError(LOGSHARE_AI_UNAVAILABLE);
  return { cancel: (): void => {} };
}

// ============================================================
//  分享记录持久化（撤回功能的前提）
// ============================================================

/** 一条已分享记录。 */
export interface LogShareRecord {
  /** 去重只复用链接，不授予新删除凭据。 */
  deduplicated?: boolean;
  /** 有凭据但未通过响应校验的记录只供核对/撤回，不能显示成分享成功。 */
  accepted?: boolean;
  /** Exact desktop probe snapshot included in this immutable share; absent for ordinary logs. */
  desktopDiagnosticId?: string;
  apiBaseUrl?: string;
  storageTimeSec?: number;
  /** 活动账本主键；旧分享记录可以没有。 */
  activityId?: number;
  id: string;
  url: string;
  /** 删除凭据。 */
  token: string;
  /** 分享时间戳（ms）。 */
  sharedAt: number;
  /** 关联的 MC 版本，便于用户辨认。 */
  versionId: string;
  /** 本次不可变分享实际选择的公开相对路径（旧记录可缺省）。 */
  selectedPaths?: string[];
  /** 生成分享时使用的会话证据 revision。 */
  snapshotRevision?: number;
  /** 证据选择内容摘要；后续多快照复用判定使用。 */
  snapshotDigest?: string;
  /** 脱敏规则版本。 */
  redactionVersion?: string;
  remoteFilesVerified?: boolean;
  verificationError?: string;
  contentReceipts?: LogShareContentReceipt[];
  receivedReceipts?: LogShareContentReceipt[];
  contentVerification?: string;
}

const PREF_STORE = 'amcl_logshare';
const PREF_KEY_RECORDS = 'records';
let shareWriteQueue: Promise<void> = Promise.resolve();

async function readStoredShareRecords(store: preferences.Preferences): Promise<LogShareRecord[]> {
  const raw = await store.get(PREF_KEY_RECORDS, '') as string;
  if (raw.length === 0) return [];
  const records = JSON.parse(raw) as LogShareRecord[];
  if (!Array.isArray(records)) throw new Error('分享凭据记录格式无效');
  return records;
}

/**
 * 读取已分享记录（最新在前）。
 *
 * 为什么必须持久化：`token` 是 DELETE 的唯一凭据，丢了用户就再也撤不回自己
 * 分享出去的日志。按记录内实例实际保留期提供撤回入口，不硬编码官网示例天数。
 */
interface ShareJournalEntry { record: LogShareRecord; revoked: boolean; }
function shareJournalPath_(ctx: common.UIAbilityContext, id: string, apiBase: string): string {
  if (!isValidLogShareId(id) || !isAllowedInstance(apiBase)) throw new Error('分享记录身份无效');
  return ctx.filesDir + '/logs/share-records/' + (apiBase === BASE ? 'official-' : 'backup-') + id + '.json';
}
function writeShareJournal_(ctx: common.UIAbilityContext, rec: LogShareRecord, revoked: boolean): void {
  ensureDirSync(ctx.filesDir + '/logs/share-records');
  const entry: ShareJournalEntry = { record: rec, revoked: revoked };
  writeEvidenceTextAtomic(shareJournalPath_(ctx, rec.id, logShareInstanceForUrl(rec.url)), JSON.stringify(entry));
}

export function isShareRecordCurrent(rec: LogShareRecord, time: number = Date.now()): boolean {
  return rec.storageTimeSec !== undefined && rec.storageTimeSec > 0
    && rec.sharedAt + rec.storageTimeSec * 1000 > time && logShareInstanceForUrl(rec.url).length > 0;
}

/** 管理页可显示完整可读项与逐项错误；损坏原件绝不自动删除。 */
export interface LogShareHistoryResult { records: LogShareRecord[]; warnings: string[]; }

/** 上传复用要求完整历史；损坏记录存在时不能盲目再生成同一份公开分享。 */
export async function loadShareRecords(ctx: common.UIAbilityContext): Promise<LogShareRecord[]> {
  const result = await loadShareHistory(ctx);
  if (result.warnings.length > 0) throw new Error('部分分享凭据暂不可读，请在分享记录中检查；可读记录仍可撤回');
  return result.records;
}

/** 独立日志凭据目录不随活动账本删除；单条损坏不能挡住其他有效记录的撤回。 */
export async function loadShareHistory(ctx: common.UIAbilityContext): Promise<LogShareHistoryResult> {
  const records: Map<string, LogShareRecord> = new Map<string, LogShareRecord>();
  const warnings: string[] = [];
  let legacyError: string = '';
  try {
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    for (const record of await readStoredShareRecords(store)) {
      records.set(logShareInstanceForUrl(record.url) + '/' + record.id, record);
    }
  } catch (e) {
    legacyError = (e as Error).message;
    AppLogger.warn(TAG, 'legacy share records unavailable', e, LOG_DOMAIN_UI);
  }
  const directory: string = ctx.filesDir + '/logs/share-records';
  let names: string[] = [];
  try { names = fs.listFileSync(directory); }
  catch (e) {
    // 新凭据目录尚未创建是正常空态；权限/IO 失败或旧存储读取失败不能伪装成没有分享。
    if (fs.accessSync(directory) || legacyError.length > 0) throw new Error('分享记录读取失败，请重试：' + (legacyError || (e as Error).message));
    return { records: Array.from(records.values()), warnings: [] };
  }
  if (legacyError.length > 0) warnings.push('旧版分享记录暂不可读，现有可读凭据仍可操作');
  for (const name of names) {
    if (!name.endsWith('.json')) continue;
    try {
      const entry = JSON.parse(fs.readTextSync(directory + '/' + name)) as ShareJournalEntry;
      const record = entry.record;
      if (record === undefined || typeof record.url !== 'string' || typeof record.id !== 'string'
        || typeof record.token !== 'string' || !isValidLogShareId(record.id)
        || logShareInstanceForUrl(record.url).length === 0) throw new Error('invalid record');
      const key: string = logShareInstanceForUrl(record.url) + '/' + record.id;
      if (entry.revoked) records.delete(key); else records.set(key, record);
    } catch (e) {
      // JSON 异常可能带原文片段，不能把其中的 token 放进界面或日志。
      warnings.push('一条分享凭据损坏或无法读取，原文件已保留');
    }
  }
  return { records: Array.from(records.values()).sort((a: LogShareRecord, b: LogShareRecord): number => b.sharedAt - a.sharedAt),
    warnings: warnings };
}

/** 后台核对只更新仍存在的同一分享，不能用迟到结果覆盖撤回墓碑或新的凭据。 */
export async function updateShareVerification(ctx: common.UIAbilityContext, record: LogShareRecord,
  verification: LogShareVerification): Promise<boolean> {
  const pending = shareWriteQueue.then(async (): Promise<boolean> => {
    const history = await loadShareHistory(ctx);
    const current = history.records.find((item: LogShareRecord): boolean => item.id === record.id
      && item.url === record.url && item.token === record.token && item.sharedAt === record.sharedAt
      && item.snapshotDigest === record.snapshotDigest && item.activityId === record.activityId);
    if (current === undefined) return false;
    current.remoteFilesVerified = verification.verified; current.verificationError = verification.warning;
    current.contentVerification = verification.contentStatus ?? 'names-only';
    current.receivedReceipts = verification.received;
    writeShareJournal_(ctx, current, false);
    return true;
  });
  shareWriteQueue = pending.then((): void => {}).catch((): void => {});
  return pending;
}

/** 追加一条分享记录。 */
export async function addShareRecord(ctx: common.UIAbilityContext,
  rec: LogShareRecord): Promise<void> {
  const pending = shareWriteQueue.then((): Promise<void> => addShareRecordNow(ctx, rec));
  shareWriteQueue = pending.catch((): void => {});
  return pending;
}

async function addShareRecordNow(ctx: common.UIAbilityContext, rec: LogShareRecord): Promise<void> {
  const instance = logShareInstanceForUrl(rec.url);
  if (instance.length === 0 || (rec.apiBaseUrl !== undefined && rec.apiBaseUrl !== instance)) {
    throw new Error('分享实例与链接不一致，无法保存撤回凭据');
  }
  rec.apiBaseUrl = instance;
  if (rec.deduplicated === true) {
    const history = await loadShareHistory(ctx);
    // 只继承同实例同 ID 的有效旧凭据；不同实例的同名 ID 不构成所有权证据。
    const previous = history.records.find((item: LogShareRecord): boolean => item.id === rec.id
      && logShareInstanceForUrl(item.url) === instance && item.token.length > 0);
    rec.token = previous?.token ?? '';
  }
  // 先提交可独立恢复的原子日志，UI 只有在凭据真正持久化后才展示成功。
  writeShareJournal_(ctx, rec, false);

}

/** 移除一条分享记录（撤回成功后调用）。 */
export async function removeShareRecord(ctx: common.UIAbilityContext, id: string, apiBase: string = BASE): Promise<void> {
  const pending = shareWriteQueue.then((): Promise<void> => removeShareRecordNow(ctx, id, apiBase));
  shareWriteQueue = pending.catch((): void => {});
  return pending;
}

async function removeShareRecordNow(ctx: common.UIAbilityContext, id: string, apiBase: string): Promise<void> {
  const records = (await loadShareHistory(ctx)).records;
  const record = records.find((item: LogShareRecord): boolean => item.id === id && logShareInstanceForUrl(item.url) === apiBase);
  if (record !== undefined) writeShareJournal_(ctx, record, true);

}

/**
 * 撤回一条已分享日志：调 DELETE 并清除本地记录。
 * 服务端已过期（404）时也视为撤回成功并清本地记录，避免用户卡在"删不掉"。
 */
export async function revokeShare(ctx: common.UIAbilityContext,
  rec: LogShareRecord): Promise<LogShareDeleteResult> {
  let idList: string[] = [rec.id];
  const instance = logShareInstanceForUrl(rec.url);
  if (!instance || (rec.apiBaseUrl !== undefined && rec.apiBaseUrl !== instance)) {
    return { ok: false, deleted: [], failed: [rec.id], error: '分享实例与链接不一致，未发送撤回凭据' };
  }
  if (rec.token.length === 0) {
    return { ok: false, deleted: [], failed: [rec.id], error: '该链接命中已有日志，本机没有有效撤回凭据' };
  }
  let r = await deleteLogs(idList, rec.token, instance);
  if (r.ok || r.error.indexOf('不存在') >= 0 || r.error.indexOf('已过期') >= 0) {
    await removeShareRecord(ctx, rec.id, instance);
    r.ok = true;
  }
  return r;
}

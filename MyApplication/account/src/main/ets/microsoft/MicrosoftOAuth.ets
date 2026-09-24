/**
 * MicrosoftOAuth.ets — Microsoft Identity Platform v2.0 OAuth 流程
 *
 * 涵盖 §5（Auth Code + PKCE，主流程）和 §6（Device Code，备选）：
 *   - PKCE：generateCodeVerifier / sha256Base64Url / generateState
 *   - Auth Code：buildAuthorizeUrl + exchangeCodeForToken
 *   - Refresh：refreshAccessToken
 *   - Device Code：requestDeviceCode + pollDeviceCodeOnce
 *
 * 不在本模块范围：
 *   - WebView 弹窗（在 AddMicrosoftAccountSheet UI 层）
 *   - 轮询 sleep 循环（调用方按 interval 自己 setTimeout，便于 UI 可中断）
 *   - Xbox/Minecraft 后续 4 步（在 XboxLiveAuth.ets / MinecraftProfileApi.ets）
 *
 * 依赖：
 *   - HttpClient（注入），单测用 FakeHttpClient
 *   - cryptoFramework（PKCE 的 SHA256 + 随机数 — 真机才有；CLI 测试 skip）
 *   - 纯 JS base64 编码（@ohos util 在 hvigorw test 环境下不可用）
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { HttpClient, HttpResponse, buildFormBody } from './HttpClient';
import { redactToken } from 'commons';
import { AppLogger } from 'commons';
import {
  MSA_CLIENT_ID,
  MSA_REDIRECT_URI,
  MSA_SCOPE,
  MSA_AUTHORIZE_URL,
  MSA_TOKEN_URL,
  MSA_DEVICE_CODE_URL,
  LOG_DOMAIN_ACCOUNT,
} from 'commons';

const TAG = 'MicrosoftOAuth';

// ============================================================
//  返回类型
// ============================================================

/** OAuth token 三件套 + 过期时间。 */
export interface MsaTokenSet {
  accessToken: string;   // MS access_token
  refreshToken: string;  // MS refresh_token（offline_access scope 下下发）
  expiresAt: number;     // ms epoch（now + expires_in*1000 - safety margin）
}

/** PKCE 三件套（一次会话用完即弃）。 */
export interface PkceChallenge {
  verifier: string;   // 43~128 字符 base64url-no-pad
  challenge: string;  // base64url-no-pad(SHA256(verifier))
  state: string;      // 32B 随机 → base64url，CSRF 校验
}

/** Device Code 请求返回，UI 用 userCode 显示给用户。 */
export interface DeviceCodeRequest {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  verificationUriComplete: string; // 含 code，可直接跳浏览器
  interval: number;                // 秒，轮询间隔
  expiresAt: number;               // ms epoch
}

/** 单次轮询结果。 */
export enum DeviceCodePollKind {
  PENDING = 'pending',          // 用户尚未授权，按 interval 继续轮询
  SLOW_DOWN = 'slow_down',      // 服务端要求 +5s 间隔
  TOKEN = 'token',              // 成功，token 字段有值
  DECLINED = 'declined',        // 用户在浏览器拒绝授权，终止
  EXPIRED = 'expired',          // device_code 过期，重新申请
}

export interface DeviceCodePollResult {
  kind: DeviceCodePollKind;
  token: MsaTokenSet | null;
}

/** OAuth 错误。code 字段对应 RFC 6749 + MSA 扩展。 */
export class OAuthError extends Error {
  readonly code: string;
  readonly httpStatus: number;
  constructor(code: string, message: string, httpStatus: number) {
    super(message);
    this.name = 'OAuthError';
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

// ============================================================
//  PKCE
// ============================================================

/** 生成 PKCE code_verifier + code_challenge + state。 */
export async function generatePkce(): Promise<PkceChallenge> {
  // RFC 7636: verifier 43~128 chars from [A-Za-z0-9-._~]
  // 64 字节随机 → base64url ≈ 86 字符（落在 43-128）
  let verifierBytes = await randomBytes(64);
  let verifier = base64UrlNoPad(verifierBytes);

  // challenge = base64url(SHA256(verifier))
  let challenge = await sha256Base64Url(verifier);

  // state: 32 字节 → base64url ≈ 43 字符
  let stateBytes = await randomBytes(32);
  let state = base64UrlNoPad(stateBytes);

  return { verifier: verifier, challenge: challenge, state: state };
}

/**
 * 构造 Authorization Code 流的授权 URL（GET），UI 把这个 URL 喂给 WebView。
 * 用户登录并同意后，浏览器跳到 `MSA_REDIRECT_URI?code=...&state=...`，
 * 由 WebView.onLoadIntercept 拿走 code。
 */
export function buildAuthorizeUrl(challenge: PkceChallenge): string {
  let params = new Map<string, string>();
  params.set('client_id', MSA_CLIENT_ID);
  params.set('response_type', 'code');
  params.set('redirect_uri', MSA_REDIRECT_URI);
  params.set('response_mode', 'query');
  params.set('scope', MSA_SCOPE);
  params.set('code_challenge', challenge.challenge);
  params.set('code_challenge_method', 'S256');
  params.set('state', challenge.state);
  params.set('prompt', 'select_account');
  return MSA_AUTHORIZE_URL + '?' + buildFormBody(params);
}

// ============================================================
//  Authorization Code 流：换 token
// ============================================================

export class MicrosoftOAuth {
  private http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /**
   * 用 code（来自 redirect 拦截）+ verifier 换 access_token / refresh_token。
   * 失败抛 OAuthError，UI 上层翻译。
   */
  async exchangeCodeForToken(code: string, verifier: string): Promise<MsaTokenSet> {
    let fields = new Map<string, string>();
    fields.set('client_id', MSA_CLIENT_ID);
    fields.set('grant_type', 'authorization_code');
    fields.set('code', code);
    fields.set('redirect_uri', MSA_REDIRECT_URI);
    fields.set('code_verifier', verifier);
    let resp = await this.http.postForm(MSA_TOKEN_URL, buildFormBody(fields));
    return this.parseTokenResponse(resp, 'exchangeCodeForToken');
  }

  /**
   * 用 refresh_token 换新的 access_token。MSA 通常会同时下发新 refresh_token，
   * 调用方必须无条件写回（旧 refresh_token 在某些场景下立刻失效）。
   */
  async refreshAccessToken(refreshToken: string): Promise<MsaTokenSet> {
    let fields = new Map<string, string>();
    fields.set('client_id', MSA_CLIENT_ID);
    fields.set('grant_type', 'refresh_token');
    fields.set('refresh_token', refreshToken);
    fields.set('scope', MSA_SCOPE);
    let resp = await this.http.postForm(MSA_TOKEN_URL, buildFormBody(fields));
    return this.parseTokenResponse(resp, 'refreshAccessToken');
  }

  // ============================================================
  //  Device Code 流（备选）
  // ============================================================

  /** 申请 device_code + user_code。 */
  async requestDeviceCode(): Promise<DeviceCodeRequest> {
    let fields = new Map<string, string>();
    fields.set('client_id', MSA_CLIENT_ID);
    fields.set('scope', MSA_SCOPE);
    let resp = await this.http.postForm(MSA_DEVICE_CODE_URL, buildFormBody(fields));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.parseErrorResponse(resp, 'requestDeviceCode');
    }
    let json = parseJsonSafe(resp.body);
    let deviceCode = strOr(json.device_code, '');
    let userCode = strOr(json.user_code, '');
    let verificationUri = strOr(json.verification_uri, '');
    let verificationUriComplete = strOr(json.verification_uri_complete, '');
    let interval = numOr(json.interval, 5);
    let expiresIn = numOr(json.expires_in, 900);
    if (deviceCode.length === 0 || userCode.length === 0) {
      throw new OAuthError('invalid_response', 'Device code response missing fields', resp.statusCode);
    }
    if (verificationUriComplete.length === 0) {
      // 服务端没下发 _complete，自己拼一个
      verificationUriComplete = verificationUri + '?otc=' + encodeURIComponent(userCode);
    }
    return {
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      verificationUriComplete: verificationUriComplete,
      interval: interval,
      expiresAt: Date.now() + expiresIn * 1000,
    };
  }

  /**
   * 单次轮询 /token。调用方按 interval 自行 sleep + 重试。
   * 这样设计便于 UI 能取消 / 显示倒计时。
   */
  async pollDeviceCodeOnce(deviceCode: string): Promise<DeviceCodePollResult> {
    let fields = new Map<string, string>();
    fields.set('client_id', MSA_CLIENT_ID);
    fields.set('grant_type', 'urn:ietf:params:oauth:grant-type:device_code');
    fields.set('device_code', deviceCode);
    let resp = await this.http.postForm(MSA_TOKEN_URL, buildFormBody(fields));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      let token = this.parseTokenResponse(resp, 'pollDeviceCodeOnce');
      return { kind: DeviceCodePollKind.TOKEN, token: token };
    }
    // 4xx：根据 error 字段分类
    let json = parseJsonSafe(resp.body);
    let errCode = strOr(json.error, '');
    if (errCode === 'authorization_pending') {
      return { kind: DeviceCodePollKind.PENDING, token: null };
    }
    if (errCode === 'slow_down') {
      return { kind: DeviceCodePollKind.SLOW_DOWN, token: null };
    }
    if (errCode === 'authorization_declined' || errCode === 'access_denied') {
      return { kind: DeviceCodePollKind.DECLINED, token: null };
    }
    if (errCode === 'expired_token' || errCode === 'code_expired') {
      return { kind: DeviceCodePollKind.EXPIRED, token: null };
    }
    // 未知错误码 → 抛
    throw this.parseErrorResponse(resp, 'pollDeviceCodeOnce');
  }

  // ============================================================
  //  内部解析
  // ============================================================

  private parseTokenResponse(resp: HttpResponse, op: string): MsaTokenSet {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.parseErrorResponse(resp, op);
    }
    let json = parseJsonSafe(resp.body);
    let access = strOr(json.access_token, '');
    let refresh = strOr(json.refresh_token, '');
    let expiresIn = numOr(json.expires_in, 3600);
    if (access.length === 0) {
      throw new OAuthError('invalid_response', 'Token response missing access_token', resp.statusCode);
    }
    return {
      accessToken: access,
      refreshToken: refresh,  // 部分流程不下发 refresh_token；调用方用旧的
      // 提前 60 秒过期，避免边界请求踩中真过期
      expiresAt: Date.now() + (expiresIn - 60) * 1000,
    };
  }

  private parseErrorResponse(resp: HttpResponse, op: string): OAuthError {
    let json = parseJsonSafe(resp.body);
    let code = strOr(json.error, '');
    let desc = strOr(json.error_description, '');
    if (code.length === 0) code = 'http_' + resp.statusCode;
    if (desc.length === 0) desc = resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
    // 2026-05-10 (LOG-P0-2)：error_description / body fallback 可能未来含 token，
    // 强制 redactToken 兜底。当前 OAuth 标准错误体不含 token，但属于深度防御。
    let safeDesc = redactToken(desc);
    AppLogger.warn(TAG, `${op} failed: ${code} - ${safeDesc}`, null, LOG_DOMAIN_ACCOUNT);
    return new OAuthError(code, desc, resp.statusCode);
  }
}

// ============================================================
//  内部工具
// ============================================================

/** 加密强度随机字节（依赖 cryptoFramework，真机才有）。
 *
 * 2026-05-23 ArkTS 严格模式：createRandom / generateRandom 都会报
 * 'Function may throw'。包 try-catch + rethrow 保留语义。
 * 详见 docs/guides/api-migration-2026-05.md。
 */
async function randomBytes(len: number): Promise<Uint8Array> {
  let rand: cryptoFramework.Random;
  let blob: cryptoFramework.DataBlob;
  try {
    rand = cryptoFramework.createRandom();
    blob = await rand.generateRandom(len);
  } catch (e) {
    throw e as Error;  // OAuth 启动流程会上报错误 sheet
  }
  // hvigorw test (Node v8) 下 cryptoFramework 可能 stub 化返回空 Uint8Array；
  // 显式抛错让 UI / 测试明确知道 native 不可用而非静默降级到弱熵。
  if (!blob || !blob.data || blob.data.length !== len) {
    throw new Error('cryptoFramework.generateRandom unavailable or returned ' +
      (blob && blob.data ? blob.data.length : 'null') + ' bytes (expected ' + len + ')');
  }
  return blob.data;
}

/** SHA256(verifier ASCII) → base64url-no-pad。verifier 总是 base64url 字母表（ASCII）。
 *
 * 2026-05-23 ArkTS 严格模式：createMd / md.update / md.digest 都报
 * 'Function may throw'。包一层 try-catch + rethrow。
 */
async function sha256Base64Url(input: string): Promise<string> {
  // verifier 是 base64url-no-pad 字符（[A-Za-z0-9_-]，全 ASCII），可直接 charCodeAt 转字节
  let bytes = new Uint8Array(input.length);
  for (let i = 0; i < input.length; i++) {
    bytes[i] = input.charCodeAt(i) & 0xff;
  }
  let chunk: cryptoFramework.DataBlob = { data: bytes };
  let digest: cryptoFramework.DataBlob;
  try {
    let md = cryptoFramework.createMd('SHA256');
    await md.update(chunk);
    digest = await md.digest();
  } catch (e) {
    throw e as Error;  // OAuth 启动会上报错误 sheet
  }
  return base64UrlNoPad(digest.data);
}

const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 纯 JS RFC 4648 标准 base64 编码。 */
function encodeStandardBase64(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  let n = bytes.length;
  // 完整 3 字节组
  while (i + 3 <= n) {
    let b0 = bytes[i];
    let b1 = bytes[i + 1];
    let b2 = bytes[i + 2];
    out += B64_ALPHABET.charAt(b0 >> 2);
    out += B64_ALPHABET.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += B64_ALPHABET.charAt(((b1 & 0x0f) << 2) | (b2 >> 6));
    out += B64_ALPHABET.charAt(b2 & 0x3f);
    i += 3;
  }
  let rem = n - i;
  if (rem === 1) {
    let b0 = bytes[i];
    out += B64_ALPHABET.charAt(b0 >> 2);
    out += B64_ALPHABET.charAt((b0 & 0x03) << 4);
    out += '==';
  } else if (rem === 2) {
    let b0 = bytes[i];
    let b1 = bytes[i + 1];
    out += B64_ALPHABET.charAt(b0 >> 2);
    out += B64_ALPHABET.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += B64_ALPHABET.charAt((b1 & 0x0f) << 2);
    out += '=';
  }
  return out;
}

/** RFC 7515 base64url（去 padding）：base64 → +/= 替换为 -_，去 =。 */
export function base64UrlNoPad(bytes: Uint8Array): string {
  let b64 = encodeStandardBase64(bytes);
  // ArkTS strict 不允许链式 replace 调用 RegExp，用循环替换
  let out = '';
  for (let i = 0; i < b64.length; i++) {
    let c = b64.charAt(i);
    if (c === '+') { out += '-'; }
    else if (c === '/') { out += '_'; }
    else if (c === '=') { /* drop */ }
    else { out += c; }
  }
  return out;
}

// ---- JSON 响应类型（覆盖本模块需要读的所有字段） ----
// 单一 JsonResponse 类型同时承接 token / device_code / error 三种响应，
// 字段全部可选；调用方用 strOr/numOr 安全访问。
interface JsonResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  token_type?: string;
  device_code?: string;
  user_code?: string;
  verification_uri?: string;
  verification_uri_complete?: string;
  interval?: number;
  error?: string;
  error_description?: string;
}

/** 安全 JSON.parse，失败返回空对象。 */
function parseJsonSafe(body: string): JsonResponse {
  if (!body || body.length === 0) return {} as JsonResponse;
  try {
    let v = JSON.parse(body) as JsonResponse;
    return v ? v : {} as JsonResponse;
  } catch (e) {
    return {} as JsonResponse;
  }
}

function strOr(v: string | undefined, fallback: string): string {
  return (typeof v === 'string') ? v : fallback;
}

function numOr(v: number | undefined, fallback: number): number {
  return (typeof v === 'number' && isFinite(v)) ? v : fallback;
}

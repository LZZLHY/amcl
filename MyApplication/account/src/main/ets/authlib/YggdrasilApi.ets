/**
 * YggdrasilApi.ets — 第三方皮肤站（authlib-injector / Yggdrasil）认证网络层
 *
 * 职责（M4）：
 *   - authenticate(root, username, password, clientToken)  账密登录 → token + 角色列表
 *   - refresh(root, accessToken, clientToken, selectedProfile) 刷新/绑定角色 → 新 token
 *   - validate(root, accessToken, clientToken)             校验 token 是否仍有效
 *   - invalidate(root, accessToken, clientToken)           登出（失效 token）
 *   - resolveMetadata(root)                                拉元数据（服务器名 + ALI 解析 + prefetch 原文）
 *   - fetchProfileTextures(root, uuid)                     皮肤/披风纹理（sessionserver）
 *
 * 与 microsoft/* 层同构：复用 HttpClient 抽象；单测注入 FakeHttpClient，严禁连真实网。
 * 不做 retry / UI 翻译；错误统一抛 YggdrasilError，由上层（AuthlibInjectorAccount）翻译成
 * AccountError。
 *
 * 协议参考：https://github.com/yushijinhun/authlib-injector/wiki/Yggdrasil-服务端技术规范
 *
 * TODO（待做）复用点：统一通行证 Nide8 也是 Yggdrasil 服务器
 *   （BaseUrl = https://auth.mc-user.com:233/<serverId>/authserver），本文件的
 *   authenticate/refresh/validate/纹理 全部可直接复用，无需改动。Nide8 支持仅需在
 *   账户模型（AuthlibInjectorAccount 加 flavor/serverId）+ 启动注入（nide8auth.jar=<serverId>）
 *   处扩展，并放入官方 nide8auth.jar。详见 LaunchProfileBuilder.injectAuthlibArgs 的 TODO 框
 *   与 CHANGELOG 1000349 备注。
 *
 * 创建日期：2026-07-02（M4 Phase A）
 */

import { HttpClient, HttpResponse } from '../microsoft/HttpClient';
import { formatCanonicalUuid } from '../microsoft/MinecraftProfileApi';
import { util } from '@kit.ArkTS';
import { redactToken } from 'commons';
import { decodeStandardBase64 } from 'commons';
import {
  YGGDRASIL_AUTHSERVER_PATH,
  YGGDRASIL_SESSIONSERVER_PROFILE_PATH,
  YGGDRASIL_ALI_HEADER,
  YGGDRASIL_AGENT_NAME,
  YGGDRASIL_AGENT_VERSION,
  LOG_DOMAIN_ACCOUNT,
} from 'commons';
import { AppLogger } from 'commons';

const TAG = 'YggdrasilApi';

// ============================================================
//  返回类型
// ============================================================

/** Yggdrasil 角色（一个账号可拥有多个角色）。 */
export interface YggProfile {
  /** 角色 UUID（Yggdrasil 通常返回无连字符 32 hex；本层统一转 canonical 8-4-4-4-12）。 */
  id: string;
  /** 角色名（游戏内显示名 = MC 玩家名）。 */
  name: string;
}

/** authenticate 结果。 */
export interface YggAuthResult {
  accessToken: string;
  clientToken: string;
  /** 账号下全部角色。可能为空（用户还没创建角色）。 */
  availableProfiles: YggProfile[];
  /** 服务端已选中的角色；未选中（多角色未定）→ null。 */
  selectedProfile: YggProfile | null;
}

/** refresh 结果。 */
export interface YggRefreshResult {
  accessToken: string;
  clientToken: string;
  selectedProfile: YggProfile | null;
}

/** 皮肤站元数据（GET apiRoot 的解析结果）。 */
export interface YggMetadata {
  /** ALI 解析后的最终 apiRoot（可能与传入不同）。 */
  resolvedRoot: string;
  /** meta.serverName；缺省时为空串。 */
  serverName: string;
  /** GET 响应原文（UTF-8）。启动时 base64 编码后作为 -Dauthlibinjector.yggdrasil.prefetched。 */
  raw: string;
}

/** 皮肤/披风纹理快照（sessionserver profile 解码结果）。 */
export interface YggTextures {
  skinUrl: string | null;
  /** 'SLIM' | 'CLASSIC'；未知 → 'CLASSIC'。 */
  skinVariant: string | null;
  capeUrl: string | null;
}

/**
 * Yggdrasil 认证错误。code：
 *   - 'invalid_credentials' : 账号/密码错误（403 ForbiddenOperationException）
 *   - 'invalid_token'       : accessToken/clientToken 失效（403，需重新登录）
 *   - 'no_profile'          : 账号下没有角色
 *   - 'invalid_response'    : 响应缺字段 / JSON 非法
 *   - 'http_error'          : 其他 HTTP 错误
 *   - 'network'             : 底层网络异常（HttpClient 抛出）
 */
export class YggdrasilError extends Error {
  readonly stage: string;   // 'authenticate' | 'refresh' | 'validate' | 'metadata' | 'textures'
  readonly code: string;
  readonly httpStatus: number;
  /** 服务端返回的原始 errorMessage（可直接展示给用户，如「密码错误」）。 */
  readonly serverMessage: string;
  constructor(stage: string, code: string, httpStatus: number, message: string, serverMessage: string) {
    super('[' + stage + '] ' + code + ' (HTTP ' + httpStatus + '): ' + message);
    this.name = 'YggdrasilError';
    this.stage = stage;
    this.code = code;
    this.httpStatus = httpStatus;
    this.serverMessage = serverMessage;
  }
}

// ============================================================
//  请求 / 响应 shape（仅本模块构造，不外泄）
// ============================================================

interface AgentBody {
  name: string;
  version: number;
}

interface ProfileBody {
  id?: string;
  name?: string;
}

interface AuthenticateRequest {
  agent: AgentBody;
  username: string;
  password: string;
  clientToken: string;
  requestUser: boolean;
}

interface RefreshRequest {
  accessToken: string;
  clientToken: string;
  selectedProfile?: ProfileBody;
  requestUser: boolean;
}

interface ValidateRequest {
  accessToken: string;
  clientToken: string;
}

interface AuthResponseBody {
  accessToken?: string;
  clientToken?: string;
  availableProfiles?: ProfileBody[];
  selectedProfile?: ProfileBody;
  error?: string;
  errorMessage?: string;
}

interface MetaBody {
  serverName?: string;
}

interface MetadataResponseBody {
  meta?: MetaBody;
}

interface TexturePropertyBody {
  name?: string;
  value?: string;
}

interface ProfileTexturesResponseBody {
  id?: string;
  name?: string;
  properties?: TexturePropertyBody[];
}

// texture blob（base64 解码后的 JSON）
interface TextureEntry {
  url?: string;
  metadata?: Record<string, string>;
}

interface TexturesBlob {
  textures?: Record<string, TextureEntry>;
}

// ============================================================
//  主类
// ============================================================

export class YggdrasilApi {
  private http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /**
   * 账密登录。clientToken 由调用方生成并固定（后续 refresh/validate 必须复用同一个）。
   *   - 200 → YggAuthResult
   *   - 403 → invalid_credentials（错误信息透传给用户）
   *   - 其他 → http_error
   */
  async authenticate(root: string, username: string, password: string, clientToken: string): Promise<YggAuthResult> {
    let body: AuthenticateRequest = {
      agent: { name: YGGDRASIL_AGENT_NAME, version: YGGDRASIL_AGENT_VERSION },
      username: username,
      password: password,
      clientToken: clientToken,
      requestUser: true,
    };
    let resp = await this.postJsonSafe(authserver(root) + '/authenticate', JSON.stringify(body), 'authenticate');
    if (resp.statusCode === 403) {
      throw this.make403('authenticate', resp);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('authenticate', resp);
    }
    let json = parseAuthJson(resp.body);
    let accessToken = strOr(json.accessToken, '');
    if (accessToken.length === 0) {
      throw new YggdrasilError('authenticate', 'invalid_response', resp.statusCode,
        'authenticate response missing accessToken', '');
    }
    return {
      accessToken: accessToken,
      // 服务端可能回传自己的 clientToken；无则用我们发出去的
      clientToken: strOr(json.clientToken, clientToken),
      availableProfiles: mapProfiles(json.availableProfiles),
      selectedProfile: mapProfile(json.selectedProfile),
    };
  }

  /**
   * 刷新 token。可带 selectedProfile 绑定角色（切换角色时用）。
   *   - 200 → YggRefreshResult
   *   - 403 → invalid_token（token 失效，需重新账密登录）
   *   - 其他 → http_error
   */
  async refresh(root: string, accessToken: string, clientToken: string, selectedProfile: YggProfile | null): Promise<YggRefreshResult> {
    let body: RefreshRequest = {
      accessToken: accessToken,
      clientToken: clientToken,
      requestUser: true,
    };
    if (selectedProfile !== null) {
      // 注意：Yggdrasil 要求 selectedProfile.id 为无连字符 32 hex（与 availableProfiles 回传一致）
      body.selectedProfile = { id: stripDashes(selectedProfile.id), name: selectedProfile.name };
    }
    let resp = await this.postJsonSafe(authserver(root) + '/refresh', JSON.stringify(body), 'refresh');
    if (resp.statusCode === 403) {
      throw this.make403('refresh', resp);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('refresh', resp);
    }
    let json = parseAuthJson(resp.body);
    let newAccess = strOr(json.accessToken, '');
    if (newAccess.length === 0) {
      throw new YggdrasilError('refresh', 'invalid_response', resp.statusCode,
        'refresh response missing accessToken', '');
    }
    return {
      accessToken: newAccess,
      clientToken: strOr(json.clientToken, clientToken),
      selectedProfile: mapProfile(json.selectedProfile),
    };
  }

  /**
   * 校验 token。204 → true（有效）；403 → false（失效）；其他异常 → 抛。
   * 无副作用，最快路径（PCL2 启动前先 validate）。
   */
  async validate(root: string, accessToken: string, clientToken: string): Promise<boolean> {
    let body: ValidateRequest = { accessToken: accessToken, clientToken: clientToken };
    let resp = await this.postJsonSafe(authserver(root) + '/validate', JSON.stringify(body), 'validate');
    if (resp.statusCode === 204 || (resp.statusCode >= 200 && resp.statusCode < 300)) {
      return true;
    }
    if (resp.statusCode === 403) {
      return false;
    }
    throw this.makeHttpError('validate', resp);
  }

  /**
   * 登出：使 accessToken 失效。失败不抛（best-effort）。
   */
  async invalidate(root: string, accessToken: string, clientToken: string): Promise<void> {
    let body: ValidateRequest = { accessToken: accessToken, clientToken: clientToken };
    try {
      await this.postJsonSafe(authserver(root) + '/invalidate', JSON.stringify(body), 'invalidate');
    } catch (e) {
      AppLogger.warn(TAG, 'invalidate failed (non-fatal)', e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  /**
   * 拉元数据：GET apiRoot。
   *   - 处理 ALI（API Location Indication）：若响应头含 x-authlib-injector-api-location，
   *     以该地址为最终 apiRoot 再 GET 一次（最多跳 1 次，防环）。
   *   - 返回 { resolvedRoot, serverName, raw }。raw 供启动时 prefetch base64。
   *
   * 失败抛 YggdrasilError('metadata', ...)。
   */
  async resolveMetadata(root: string): Promise<YggMetadata> {
    let normalized = normalizeRoot(root);
    let resp = await this.getSafe(normalized, 'metadata');
    // ALI 重定向（仅解析一次）
    let ali = readAliHeader(resp);
    if (ali.length > 0) {
      let redirected = normalizeRoot(ali);
      if (redirected !== normalized) {
        AppLogger.info(TAG, `ALI redirect: ${normalized} -> ${redirected}`, LOG_DOMAIN_ACCOUNT);
        normalized = redirected;
        resp = await this.getSafe(normalized, 'metadata');
      }
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('metadata', resp);
    }
    let serverName = '';
    let json = parseMetadataJson(resp.body);
    if (json.meta && typeof json.meta.serverName === 'string') {
      serverName = json.meta.serverName;
    }
    return { resolvedRoot: normalized, serverName: serverName, raw: resp.body };
  }

  /**
   * 拉角色纹理（皮肤/披风）。unsigned=false 时属性含签名，我们只需 url，取 base64 解码即可。
   *   - 200 → YggTextures（skin/cape url + variant）
   *   - 204 / 无 textures 属性 → 全 null（合法：该角色没设皮肤）
   *   - 404 → 全 null（角色不存在，容错）
   *   - 其他 → 抛
   */
  async fetchProfileTextures(root: string, uuid: string): Promise<YggTextures> {
    let id = stripDashes(uuid);
    let url = normalizeRoot(root) + YGGDRASIL_SESSIONSERVER_PROFILE_PATH + id;
    let resp = await this.getSafe(url, 'textures');
    if (resp.statusCode === 204 || resp.statusCode === 404) {
      return { skinUrl: null, skinVariant: null, capeUrl: null };
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('textures', resp);
    }
    let profile = parseProfileTexturesJson(resp.body);
    let texProp: TexturePropertyBody | null = null;
    if (profile.properties) {
      for (let p of profile.properties) {
        if (p && p.name === 'textures' && typeof p.value === 'string' && p.value.length > 0) {
          texProp = p;
          break;
        }
      }
    }
    if (texProp === null || !texProp.value) {
      return { skinUrl: null, skinVariant: null, capeUrl: null };
    }
    let blob = decodeTexturesBlob(texProp.value);
    if (blob === null || !blob.textures) {
      return { skinUrl: null, skinVariant: null, capeUrl: null };
    }
    let skin = blob.textures['SKIN'];
    let cape = blob.textures['CAPE'];
    let skinUrl: string | null = (skin && typeof skin.url === 'string' && skin.url.length > 0) ? skin.url : null;
    let capeUrl: string | null = (cape && typeof cape.url === 'string' && cape.url.length > 0) ? cape.url : null;
    let skinVariant: string | null = null;
    if (skinUrl !== null) {
      let model = (skin && skin.metadata && typeof skin.metadata['model'] === 'string') ? skin.metadata['model'] : '';
      skinVariant = (model === 'slim') ? 'SLIM' : 'CLASSIC';
    }
    return { skinUrl: skinUrl, skinVariant: skinVariant, capeUrl: capeUrl };
  }

  // ============================================================
  //  内部：HTTP 包装（把底层网络异常统一转成 YggdrasilError('network')）
  // ============================================================

  private async postJsonSafe(url: string, body: string, stage: string): Promise<HttpResponse> {
    try {
      return await this.http.postJson(url, body);
    } catch (e) {
      throw this.makeNetworkError(stage, e as Error);
    }
  }

  private async getSafe(url: string, stage: string): Promise<HttpResponse> {
    try {
      return await this.http.get(url, '');
    } catch (e) {
      throw this.makeNetworkError(stage, e as Error);
    }
  }

  private makeNetworkError(stage: string, e: Error): YggdrasilError {
    let msg = (e && e.message) ? e.message : '网络请求失败';
    AppLogger.warn(TAG, `${stage} network error: ${msg}`, null, LOG_DOMAIN_ACCOUNT);
    return new YggdrasilError(stage, 'network', 0, msg, '');
  }

  /** 403：区分「账密错误」与「token 失效」。Yggdrasil 两者都用 ForbiddenOperationException。 */
  private make403(stage: string, resp: HttpResponse): YggdrasilError {
    let json = parseAuthJson(resp.body);
    let serverMsg = strOr(json.errorMessage, '');
    // authenticate 阶段的 403 → 账密错误；refresh/validate 阶段的 403 → token 失效
    let code = (stage === 'authenticate') ? 'invalid_credentials' : 'invalid_token';
    AppLogger.warn(TAG, `${stage} 403: ${redactToken(serverMsg)}`, null, LOG_DOMAIN_ACCOUNT);
    return new YggdrasilError(stage, code, 403,
      serverMsg.length > 0 ? serverMsg : 'Forbidden', serverMsg);
  }

  private makeHttpError(stage: string, resp: HttpResponse): YggdrasilError {
    let json = parseAuthJson(resp.body);
    let serverMsg = strOr(json.errorMessage, '');
    let preview = serverMsg.length > 0 ? serverMsg
      : (resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body);
    let safePreview = redactToken(preview);
    AppLogger.warn(TAG, `${stage} HTTP ${resp.statusCode}: ${safePreview}`, null, LOG_DOMAIN_ACCOUNT);
    return new YggdrasilError(stage, 'http_error', resp.statusCode,
      'HTTP ' + resp.statusCode + (preview.length > 0 ? '：' + preview : ''), serverMsg);
  }
}

// ============================================================
//  内部工具（模块级纯函数，便于单测）
// ============================================================

/** 去 apiRoot 末尾斜杠。 */
export function normalizeRoot(root: string): string {
  let s = (root || '').trim();
  while (s.length > 0 && s.charAt(s.length - 1) === '/') {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

function authserver(root: string): string {
  return normalizeRoot(root) + YGGDRASIL_AUTHSERVER_PATH;
}

/** 去 UUID 连字符。 */
export function stripDashes(uuid: string): string {
  if (!uuid) return '';
  let out = '';
  for (let i = 0; i < uuid.length; i++) {
    let c = uuid.charAt(i);
    if (c !== '-') out += c;
  }
  return out;
}

function readAliHeader(resp: HttpResponse): string {
  if (!resp.headers) return '';
  let v = resp.headers.get(YGGDRASIL_ALI_HEADER);
  return (typeof v === 'string') ? v.trim() : '';
}

function mapProfile(p: ProfileBody | undefined): YggProfile | null {
  if (!p) return null;
  let id = strOr(p.id, '');
  let name = strOr(p.name, '');
  if (id.length === 0 || name.length === 0) return null;
  return { id: formatCanonicalUuid(id), name: name };
}

function mapProfiles(arr: ProfileBody[] | undefined): YggProfile[] {
  let out: YggProfile[] = [];
  if (!arr) return out;
  for (let p of arr) {
    let mapped = mapProfile(p);
    if (mapped !== null) out.push(mapped);
  }
  return out;
}

function parseAuthJson(body: string): AuthResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as AuthResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}

function parseMetadataJson(body: string): MetadataResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as MetadataResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}

function parseProfileTexturesJson(body: string): ProfileTexturesResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as ProfileTexturesResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}

/** base64 → UTF-8 JSON → TexturesBlob；失败返 null。 */
function decodeTexturesBlob(base64Value: string): TexturesBlob | null {
  try {
    let bytes = decodeStandardBase64(base64Value);
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let json = decoder.decodeToString(bytes);
    let v = JSON.parse(json) as TexturesBlob;
    return v ? v : null;
  } catch (e) {
    AppLogger.warn(TAG, 'decodeTexturesBlob failed', e as Object, LOG_DOMAIN_ACCOUNT);
    return null;
  }
}

function strOr(v: string | undefined, fallback: string): string {
  return (typeof v === 'string') ? v : fallback;
}

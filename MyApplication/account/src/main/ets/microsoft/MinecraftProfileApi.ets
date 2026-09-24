/**
 * MinecraftProfileApi.ets — Minecraft Services 端点（链路最后两步）
 *
 * 职责（规划文档 §7 步骤 5-6）：
 *   - loginWithXbox(uhs, xstsToken)  → MC bearer { accessToken, expiresAt }
 *   - getProfile(mcAccessToken)      → McProfile { uuid, username }
 *   - 404 → NOT_PREMIUM 标记（用户尚未购买 MC Java）
 *   - 32 hex UUID → 8-4-4-4-12 canonical 格式（MC 启动 args 兼容）
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { HttpClient, HttpResponse } from './HttpClient';
import { redactToken } from 'commons';
import { MC_BEARER_URL, MC_PROFILE_URL, MC_ACTIVE_CAPE_URL, LOG_DOMAIN_ACCOUNT } from 'commons';
import { AppLogger } from 'commons';

const TAG = 'MinecraftProfileApi';

// ============================================================
//  返回类型
// ============================================================

/** MC bearer 五件套：access_token + 过期时间。 */
export interface McBearerToken {
  accessToken: string;
  expiresAt: number;  // ms epoch
}

/**
 * 玩家皮肤 (active)。Mojang 返回的皮肤是 64x64 PNG，顶部 8x8 块是头部。
 * UI 需要头像时可以调 Crafatar（以 uuid 为键，都不需要这个 url）或自己 crop。
 * 序列化到账户记录中仅作为"快照"，下次 refresh 会被覆盖。
 */
export interface SkinInfo {
  url: string;        // textures.minecraft.net/texture/<hash>
  variant: string;    // 'CLASSIC' | 'SLIM'。未知变体不崩，原样存入
}

/**
 * 玩家披风 (active)。代表玩家在都可能拥有多个披风但仅 1 个是 ACTIVE 。
 * 只有购买 / 获赠过披风的玩家才会有，多数玩家这个是 null。
 */
export interface CapeInfo {
  url: string;        // PNG URL
  alias: string;      // 'Migrator' | 'Vanilla' | 'Mojang Office' | ...
}

/**
 * 玩家**拥有**的披风（不一定 active）。Mojang 的 profile 接口里 capes[] 数组
 * 包含玩家曾经获得过的所有披风，每个 entry 有 state=ACTIVE/INACTIVE 标记。
 *
 * UI 用：在 SkinCapeDetailSheet 里显示「我的披风」列表 + 切换按钮（PCL 同款交互）。
 *
 * 切换披风的接口：PUT /minecraft/profile/capes/active 带 {"capeId": id}。
 */
export interface OwnedCape {
  /** 服务端 cape id（uuid 格式）。切换披风时 PUT body 里要传这个。 */
  id: string;
  /** PNG URL（textures.minecraft.net 域）。 */
  url: string;
  /** 披风别名。 */
  alias: string;
  /** 是否当前 active。整个 capes 列表里至多 1 个 isActive=true。 */
  isActive: boolean;
}

/** MC 玩家档案。 */
export interface McProfile {
  uuid: string;       // canonical 8-4-4-4-12
  username: string;
  /** 当前选中的皮肤。购买 MC Java 后默认会有，极少数 case 为 null。 */
  skin: SkinInfo | null;
  /** 当前佩戴的披风。大多玩家没有 → null。 */
  cape: CapeInfo | null;
  /** 玩家拥有的所有披风（含 active 那个）。无披风的玩家 → 空数组。 */
  ownedCapes: OwnedCape[];
}

/**
 * MC 服务调用错误。code 字段：
 *   - 'not_premium'      : 用户未购买 Minecraft Java（profile 404）
 *   - 'invalid_response' : 字段缺失 / JSON 不合法
 *   - 'http_error'       : 其他 HTTP 错误
 *   - 'token_expired'    : MC bearer 401（rare in profile 调用）
 */
export class MinecraftAuthError extends Error {
  readonly stage: string;       // 'bearer' | 'profile'
  readonly code: string;
  readonly httpStatus: number;
  constructor(stage: string, code: string, httpStatus: number, message: string) {
    super('[' + stage + '] ' + code + ': ' + message);
    this.name = 'MinecraftAuthError';
    this.stage = stage;
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

// ============================================================
//  Request / Response shapes
// ============================================================

interface BearerRequestBody {
  identityToken: string;
}

interface BearerResponseBody {
  access_token?: string;
  token_type?: string;
  expires_in?: number;
  username?: string;
}

/**
 * Profile API 字段。注意 Mojang 返回的 skin/cape 数组里只有 1 个 state=ACTIVE。
 * 下面的子接口与返回体完全对齐，剩下的逻辑在 pickActive() 里封装。
 */
interface ProfileSkinEntry {
  id?: string;
  state?: string;
  url?: string;
  variant?: string;
}

interface ProfileCapeEntry {
  id?: string;
  state?: string;
  url?: string;
  alias?: string;
}

interface ProfileResponseBody {
  id?: string;       // 32 hex chars 无连字符
  name?: string;
  skins?: ProfileSkinEntry[];
  capes?: ProfileCapeEntry[];
  errorMessage?: string;
}

// ============================================================
//  主类
// ============================================================

export class MinecraftProfileApi {
  private http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /**
   * 步骤 5：用 XSTS uhs + token 换 MC bearer。
   * 格式：identityToken = "XBL3.0 x=<uhs>;<xstsToken>"
   */
  async loginWithXbox(uhs: string, xstsToken: string): Promise<McBearerToken> {
    let body: BearerRequestBody = {
      identityToken: 'XBL3.0 x=' + uhs + ';' + xstsToken,
    };
    let resp = await this.http.postJson(MC_BEARER_URL, JSON.stringify(body));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('bearer', resp);
    }
    let json = parseBearerJson(resp.body);
    let access = (typeof json.access_token === 'string') ? json.access_token : '';
    let expiresIn = (typeof json.expires_in === 'number' && isFinite(json.expires_in))
      ? json.expires_in : 86400;
    if (access.length === 0) {
      throw new MinecraftAuthError('bearer', 'invalid_response', resp.statusCode,
        'login_with_xbox response missing access_token');
    }
    return {
      accessToken: access,
      // 提前 60 秒过期，避免边界请求踩中真过期
      expiresAt: Date.now() + (expiresIn - 60) * 1000,
    };
  }

  /**
   * 步骤 6：用 MC bearer 拉玩家档案（uuid + username）。
   *   - 200 → McProfile（id 转 canonical UUID）
   *   - 404 → 抛 MinecraftAuthError code='not_premium'
   *   - 401 → token_expired
   *   - 其他 → http_error
   */
  async getProfile(mcAccessToken: string): Promise<McProfile> {
    let resp = await this.http.get(MC_PROFILE_URL, mcAccessToken);
    if (resp.statusCode === 404) {
      throw new MinecraftAuthError('profile', 'not_premium', 404,
        '该 Microsoft 账户尚未购买 Minecraft Java 版');
    }
    if (resp.statusCode === 401) {
      throw new MinecraftAuthError('profile', 'token_expired', 401,
        'MC bearer 已过期，需要重新登录或刷新');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('profile', resp);
    }
    let json = parseProfileJson(resp.body);
    let id = (typeof json.id === 'string') ? json.id : '';
    let name = (typeof json.name === 'string') ? json.name : '';
    if (id.length === 0 || name.length === 0) {
      throw new MinecraftAuthError('profile', 'invalid_response', resp.statusCode,
        'profile response missing id/name');
    }
    return {
      uuid: formatCanonicalUuid(id),
      username: name,
      skin: pickActiveSkin(json.skins),
      cape: pickActiveCape(json.capes),
      ownedCapes: collectOwnedCapes(json.capes),
    };
  }

  /**
   * 切换 active cape：`PUT /minecraft/profile/capes/active` body `{"capeId": "<id>"}`。
   * Mojang 返回完整的更新后 profile JSON（同 getProfile schema），这里直接解析返回。
   *
   *   - 200 → 解析 body 为 McProfile（active cape 已是新值）
   *   - 401 → token_expired（调用方先 refresh 再重试）
   *   - 400 → invalid_response（capeId 不属于该用户 / 格式错误）
   *   - 其他 → http_error
   */
  async setActiveCape(mcAccessToken: string, capeId: string): Promise<McProfile> {
    let body = JSON.stringify({ capeId: capeId });
    let resp = await this.http.putJson(MC_ACTIVE_CAPE_URL, mcAccessToken, body);
    if (resp.statusCode === 401) {
      throw new MinecraftAuthError('cape', 'token_expired', 401, 'MC bearer 已过期');
    }
    if (resp.statusCode === 400) {
      throw new MinecraftAuthError('cape', 'invalid_response', 400,
        '不能设置该披风为 active（id 不属于本账户 / 格式错误）');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('cape', resp);
    }
    return parseProfileFromBody(resp.body, resp.statusCode);
  }

  /**
   * 取消 active cape：`DELETE /minecraft/profile/capes/active`。Mojang 返回新 profile。
   * 用法：UI 点「无披风」tile / 想切回光膀子的状态。
   */
  async removeActiveCape(mcAccessToken: string): Promise<McProfile> {
    let resp = await this.http.delete(MC_ACTIVE_CAPE_URL, mcAccessToken);
    if (resp.statusCode === 401) {
      throw new MinecraftAuthError('cape', 'token_expired', 401, 'MC bearer 已过期');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw this.makeHttpError('cape', resp);
    }
    return parseProfileFromBody(resp.body, resp.statusCode);
  }

  // ============================================================
  //  内部
  // ============================================================

  private makeHttpError(stage: string, resp: HttpResponse): MinecraftAuthError {
    let preview = resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
    // 2026-05-10 (LOG-P0-2)：MC bearer 接口的成功 body 含 access_token，万一上游
    // 把它误返回到 4xx/5xx（代理中间人 / 协议变化），强制 redactToken 兜底。
    let safePreview = redactToken(preview);
    AppLogger.warn(TAG, `${stage} HTTP ${resp.statusCode}: ${safePreview}`, null, LOG_DOMAIN_ACCOUNT);
    return new MinecraftAuthError(stage, 'http_error', resp.statusCode,
      'HTTP ' + resp.statusCode + ': ' + preview);
  }
}

// ============================================================
//  内部工具
// ============================================================

function parseBearerJson(body: string): BearerResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as BearerResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}

function parseProfileJson(body: string): ProfileResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as ProfileResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}

/**
 * 从 skins[] 中拽出 state=ACTIVE 的项；Url/variant 不合法时返 null。
 *
 * Mojang 保证最多 1 个 ACTIVE，但防御性处理：多个 ACTIVE 取首个，零个 ACTIVE 返 null。
 */
function pickActiveSkin(skins?: ProfileSkinEntry[]): SkinInfo | null {
  if (!skins || skins.length === 0) return null;
  for (let entry of skins) {
    if (entry && entry.state === 'ACTIVE'
      && typeof entry.url === 'string' && entry.url.length > 0) {
      return {
        url: entry.url,
        variant: typeof entry.variant === 'string' ? entry.variant : 'CLASSIC',
      };
    }
  }
  return null;
}

/**
 * 从 capes[] 中拽出 state=ACTIVE 的项。大多玩家没披风 → null。
 */
function pickActiveCape(capes?: ProfileCapeEntry[]): CapeInfo | null {
  if (!capes || capes.length === 0) return null;
  for (let entry of capes) {
    if (entry && entry.state === 'ACTIVE'
      && typeof entry.url === 'string' && entry.url.length > 0) {
      return {
        url: entry.url,
        alias: typeof entry.alias === 'string' ? entry.alias : '',
      };
    }
  }
  return null;
}

/**
 * 收集所有 capes[]（含 active 和 inactive）。无披风 → 空数组。
 *
 * 防御：跳过缺少 id / url 的非法 entry（实际场景没遇到过，但 schema 允许）。
 */
function collectOwnedCapes(capes?: ProfileCapeEntry[]): OwnedCape[] {
  let out: OwnedCape[] = [];
  if (!capes || capes.length === 0) return out;
  for (let entry of capes) {
    if (!entry) continue;
    let id = typeof entry.id === 'string' ? entry.id : '';
    let url = typeof entry.url === 'string' ? entry.url : '';
    if (id.length === 0 || url.length === 0) continue;
    out.push({
      id: id,
      url: url,
      alias: typeof entry.alias === 'string' ? entry.alias : '',
      isActive: entry.state === 'ACTIVE',
    });
  }
  return out;
}

/**
 * 解析 setActiveCape / removeActiveCape 返回的 profile body 为 McProfile。
 * Mojang 保证 200 响应 body 与 GET /minecraft/profile 同 schema。
 */
function parseProfileFromBody(body: string, httpStatus: number): McProfile {
  let json = parseProfileJson(body);
  let id = (typeof json.id === 'string') ? json.id : '';
  let name = (typeof json.name === 'string') ? json.name : '';
  if (id.length === 0 || name.length === 0) {
    throw new MinecraftAuthError('cape', 'invalid_response', httpStatus,
      'cape api response missing id/name');
  }
  return {
    uuid: formatCanonicalUuid(id),
    username: name,
    skin: pickActiveSkin(json.skins),
    cape: pickActiveCape(json.capes),
    ownedCapes: collectOwnedCapes(json.capes),
  };
}

/**
 * 把 32 位 hex（无分隔符）格式化为 canonical UUID 8-4-4-4-12。
 * MC 服务返回 "069a79f444e94726a5befca90e38aaf5" → "069a79f4-44e9-4726-a5be-fca90e38aaf5"
 *
 * 公开 export 便于其他模块（如 MicrosoftAccount.serialize/deserialize）复用。
 */
export function formatCanonicalUuid(raw: string): string {
  if (!raw) return '';
  let s = raw.toLowerCase();
  // 已经是 canonical 格式（含 4 个连字符），直接回
  if (s.length === 36 && s.charAt(8) === '-' && s.charAt(13) === '-'
    && s.charAt(18) === '-' && s.charAt(23) === '-') {
    return s;
  }
  // 32 位 hex → 8-4-4-4-12
  if (s.length === 32) {
    return s.substring(0, 8) + '-' +
      s.substring(8, 12) + '-' +
      s.substring(12, 16) + '-' +
      s.substring(16, 20) + '-' +
      s.substring(20, 32);
  }
  // 其他情况：原样返回（让 MC 自己拒绝），但记录警告
  AppLogger.warn(TAG, `formatCanonicalUuid: unexpected raw len=${s.length}`, null, LOG_DOMAIN_ACCOUNT);
  return s;
}

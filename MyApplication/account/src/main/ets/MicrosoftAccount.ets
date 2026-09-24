/**
 * MicrosoftAccount.ets — 微软正版账户实现
 *
 * 实现 Account 接口，串起 5 步链路（OAuth refresh → XBL → XSTS → MC bearer → profile）。
 * 持有 refreshToken / mcAccessToken / mcExpiresAt。启动前 refresh() 是幂等无副作用
 * （token 未到刷新阈值时直接返回）。
 *
 * 持久化：
 *   - M2 Phase A：encrypted.ciphertext 存的是**明文 JSON**（M1 stub 风格，与
 *     AccountStorage.encrypt/decrypt 的占位实现一致）
 *   - M2 Phase B：替换为 HUKS AES-GCM-256 加密的 base64
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import {
  Account,
  AccountType,
  AccountRecord,
  AccountCape,
  AccountCapeRecord,
  AccountError,
  ACCOUNT_ERR_NETWORK,
  ACCOUNT_ERR_TOKEN_EXPIRED,
  ACCOUNT_ERR_INVALID_CAPE,
  ACCOUNT_ERR_NOT_PREMIUM,
  ACCOUNT_ERR_UNKNOWN,
  EncryptedBlob,
  ProfileFieldSink,
} from './Account';
import { HttpClient, RealHttpClient } from './microsoft/HttpClient';
import { MicrosoftOAuth, MsaTokenSet } from './microsoft/MicrosoftOAuth';
import { XboxLiveAuth, XblTokenResult } from './microsoft/XboxLiveAuth';
import {
  MinecraftProfileApi,
  McBearerToken,
  McProfile,
  OwnedCape,
  MinecraftAuthError,
} from './microsoft/MinecraftProfileApi';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'MicrosoftAccount';

// 提前 60s 过期，避免在边界请求时刚好踩到真过期
const REFRESH_MARGIN_MS = 60 * 1000;

// ============================================================
//  依赖注入
// ============================================================

/** MicrosoftAccount 用到的三个网络层服务。测试时可注入 fake，生产用 default。 */
export interface MicrosoftAccountDeps {
  oauth: MicrosoftOAuth;
  xbl: XboxLiveAuth;
  mc: MinecraftProfileApi;
}

/** 用 RealHttpClient 构造一组默认 deps（生产路径）。 */
export function defaultMicrosoftDeps(): MicrosoftAccountDeps {
  let http: HttpClient = new RealHttpClient();
  return {
    oauth: new MicrosoftOAuth(http),
    xbl: new XboxLiveAuth(http),
    mc: new MinecraftProfileApi(http),
  };
}

// ============================================================
//  序列化 schema（packed into AccountRecord.encrypted.ciphertext）
// ============================================================

/**
 * 解密后存的敏感字段。注意：skin/cape 不在此负载中——他们是
 * Mojang CDN 上的公开 URL，加密仅浪费 CPU，以明文在 AccountRecord 上存。
 */
interface MsaSensitivePayload {
  refreshToken: string;
  mcAccessToken: string;
  mcExpiresAt: number;
}

// ============================================================
//  MicrosoftAccount
// ============================================================

export class MicrosoftAccount implements Account {
  readonly id: string;
  readonly type: AccountType = AccountType.MICROSOFT;
  readonly username: string;
  readonly uuid: string;
  readonly createdAt: number;

  private deps: MicrosoftAccountDeps;
  private refreshToken: string;
  private mcAccessToken: string;
  private mcExpiresAt: number;

  // M2.5 皮肤 / 披风快照。仅 UI 展示用，不影响 launchProfile 注入。
  // refresh() 末尾会顺手拉 profile 同步这几个字段。
  private skinUrl: string | null = null;
  private skinVariant: string | null = null;
  private capeUrl: string | null = null;
  private capeAlias: string | null = null;
  /**
   * M2.6：玩家拥有的披风快照（含 active）。在 refresh() / setActiveCape() 时同步。
   * 没有披风的玩家永远 [].
   */
  private ownedCapes: AccountCape[] = [];

  private constructor(
    id: string,
    username: string,
    uuid: string,
    createdAt: number,
    refreshToken: string,
    mcAccessToken: string,
    mcExpiresAt: number,
    deps: MicrosoftAccountDeps,
    skinUrl: string | null,
    skinVariant: string | null,
    capeUrl: string | null,
    capeAlias: string | null,
    ownedCapes: AccountCape[],
  ) {
    this.id = id;
    this.username = username;
    this.uuid = uuid;
    this.createdAt = createdAt;
    this.refreshToken = refreshToken;
    this.mcAccessToken = mcAccessToken;
    this.mcExpiresAt = mcExpiresAt;
    this.deps = deps;
    this.skinUrl = skinUrl;
    this.skinVariant = skinVariant;
    this.capeUrl = capeUrl;
    this.capeAlias = capeAlias;
    this.ownedCapes = ownedCapes;
  }

  /**
   * 互动登录完成时调用（OAuth → XBL → XSTS → MC bearer → profile 全部跑完）。
   * UI 在完成 5 步链路后用本方法构造 MicrosoftAccount 并交给 AccountManager.add。
   */
  static fromInteractiveLogin(args: InteractiveLoginArgs, deps?: MicrosoftAccountDeps): MicrosoftAccount {
    let d: MicrosoftAccountDeps = deps !== undefined ? deps : defaultMicrosoftDeps();
    return new MicrosoftAccount(
      args.id,
      args.username,
      args.uuid,
      args.createdAt,
      args.refreshToken,
      args.mcAccessToken,
      args.mcExpiresAt,
      d,
      args.skinUrl !== undefined ? args.skinUrl : null,
      args.skinVariant !== undefined ? args.skinVariant : null,
      args.capeUrl !== undefined ? args.capeUrl : null,
      args.capeAlias !== undefined ? args.capeAlias : null,
      args.ownedCapes !== undefined ? args.ownedCapes.slice() : [],
    );
  }

  /**
   * 从持久化记录恢复。AccountManager.deserialize 调用。
   * 解析 `record.encrypted.ciphertext` 为 MsaSensitivePayload JSON。
   *
   * Phase A（明文 JSON）：直接 JSON.parse。
   * Phase B：会先 await AccountStorage.decrypt(record.encrypted)，再 JSON.parse。
   */
  static fromRecord(record: AccountRecord, deps?: MicrosoftAccountDeps): MicrosoftAccount | null {
    if (record.type !== AccountType.MICROSOFT) {
      AppLogger.warn(TAG, `fromRecord: type mismatch (got ${record.type})`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    if (!record.encrypted || !record.encrypted.ciphertext) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} missing encrypted payload`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    let payload: MsaSensitivePayload | null = null;
    try {
      payload = JSON.parse(record.encrypted.ciphertext) as MsaSensitivePayload;
    } catch (e) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} payload parse failed`, e as Object, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    if (!payload || typeof payload.refreshToken !== 'string' || payload.refreshToken.length === 0) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} payload missing refreshToken`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    let d: MicrosoftAccountDeps = deps !== undefined ? deps : defaultMicrosoftDeps();
    return new MicrosoftAccount(
      record.id,
      record.username,
      record.uuid,
      record.createdAt,
      payload.refreshToken,
      typeof payload.mcAccessToken === 'string' ? payload.mcAccessToken : '',
      typeof payload.mcExpiresAt === 'number' ? payload.mcExpiresAt : 0,
      d,
      typeof record.skinUrl === 'string' ? record.skinUrl : null,
      typeof record.skinVariant === 'string' ? record.skinVariant : null,
      typeof record.capeUrl === 'string' ? record.capeUrl : null,
      typeof record.capeAlias === 'string' ? record.capeAlias : null,
      // 老记录（< M2.6）没 ownedCapes 字段 → 默认 []，下次 refresh() 会重新拉
      Array.isArray(record.ownedCapes) ? record.ownedCapes.slice() : [],
    );
  }

  // ===== Account 接口实现 =====

  async getAccessToken(): Promise<string> {
    if (this.isMcTokenFresh()) {
      return this.mcAccessToken;
    }
    await this.refresh();
    return this.mcAccessToken;
  }

  /**
   * 完整刷新链路：refresh MS → XBL → XSTS → MC bearer。
   * 不重新拉 profile（uuid/username 在 fromInteractiveLogin 时就固定）。
   * 失败抛错（OAuthError / XboxAuthError / MinecraftAuthError），调用方按 code 翻译 UI。
   */
  async refresh(): Promise<void> {
    if (this.isMcTokenFresh()) {
      // 还在有效期内，跳过；M3 阶段会加 forceRefresh 选项
      return;
    }
    if (this.refreshToken.length === 0) {
      throw new Error('MicrosoftAccount.refresh: no refreshToken (account needs re-login)');
    }
    AppLogger.info(TAG, `refresh start: id=${this.id}`, LOG_DOMAIN_ACCOUNT);

    // 1. refresh MS access_token
    let msa: MsaTokenSet = await this.deps.oauth.refreshAccessToken(this.refreshToken);
    // MSA 通常下发新 refresh_token，无条件写回（旧的可能立即失效）
    if (msa.refreshToken && msa.refreshToken.length > 0) {
      this.refreshToken = msa.refreshToken;
    }

    // 2. XBL
    let xbl: XblTokenResult = await this.deps.xbl.authenticateXbl(msa.accessToken);

    // 3. XSTS
    let xsts: XblTokenResult = await this.deps.xbl.authorizeXsts(xbl.token);

    // 4. MC bearer
    let mc: McBearerToken = await this.deps.mc.loginWithXbox(xsts.uhs, xsts.token);

    this.mcAccessToken = mc.accessToken;
    this.mcExpiresAt = mc.expiresAt;
    AppLogger.info(TAG, `refresh done: id=${this.id}, expiresAt=${this.mcExpiresAt}`, LOG_DOMAIN_ACCOUNT);

    // 5. 顺手拉 profile 同步皮肤 / 披风。这是轻量请求，但**失败不阻断登录**
    //   —— token 已拿到，MC 启动不需要 skin/cape。
    try {
      let profile = await this.deps.mc.getProfile(this.mcAccessToken);
      this.applyProfile(profile);
    } catch (e) {
      AppLogger.warn(TAG, 'refresh: profile sync failed (non-fatal)', e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  /**
   * 用一份新的 McProfile 覆盖本地皮肤/披风快照。refresh / setActiveCape /
   * removeActiveCape 都共用这个 helper，避免散落的 5 行 setter 重复。
   *
   * 不持久化 —— 持久化由 AccountManager 在调用方 setActiveCape 完成时统一触发。
   */
  private applyProfile(profile: McProfile): void {
    this.skinUrl = profile.skin ? profile.skin.url : null;
    this.skinVariant = profile.skin ? profile.skin.variant : null;
    this.capeUrl = profile.cape ? profile.cape.url : null;
    this.capeAlias = profile.cape ? profile.cape.alias : null;
    // OwnedCape 与 AccountCape 字段同构 —— 直接 cast，避免无意义的 map 拷贝
    this.ownedCapes = profile.ownedCapes.slice() as AccountCape[];
  }

  fillProfile(sink: ProfileFieldSink): void {
    sink.setUsername(this.username);
    sink.setUuid(this.uuid);
    sink.setAccessToken(this.mcAccessToken);
    sink.setUserType('msa');
  }

  serialize(): AccountRecord {
    let payload: MsaSensitivePayload = {
      refreshToken: this.refreshToken,
      mcAccessToken: this.mcAccessToken,
      mcExpiresAt: this.mcExpiresAt,
    };
    let payloadJson = JSON.stringify(payload);
    // Phase A：明文 JSON 塞进 ciphertext 字段（与 AccountStorage M1 stub 语义一致）。
    // Phase B：会改成 await storage.encrypt(payloadJson) → 真 EncryptedBlob。
    let encrypted: EncryptedBlob = {
      iv: '',
      ciphertext: payloadJson,
      tag: '',
    };
    let rec: AccountRecord = {
      version: 1,
      id: this.id,
      type: this.type,
      username: this.username,
      uuid: this.uuid,
      createdAt: this.createdAt,
      encrypted: encrypted,
    };
    // 皮肤 / 披风：明文存（公开 URL）。不设空字段避免 JSON 隐式序列化为 null。
    if (this.skinUrl) rec.skinUrl = this.skinUrl;
    if (this.skinVariant) rec.skinVariant = this.skinVariant;
    if (this.capeUrl) rec.capeUrl = this.capeUrl;
    if (this.capeAlias) rec.capeAlias = this.capeAlias;
    // ownedCapes 同构于 AccountCapeRecord，slice 一次防止外部拿到内部数组改坏
    if (this.ownedCapes.length > 0) {
      rec.ownedCapes = this.ownedCapes.slice() as AccountCapeRecord[];
    }
    return rec;
  }

  async isUsable(): Promise<boolean> {
    // refresh_token 非空就视为可用：即使 mcAccessToken 过期，refresh() 能恢复
    return this.refreshToken.length > 0;
  }

  getDisplayName(): string {
    return this.username;
  }

  getSkinUrl(): string | null { return this.skinUrl; }
  getSkinVariant(): string | null { return this.skinVariant; }
  getCapeUrl(): string | null { return this.capeUrl; }
  getCapeAlias(): string | null { return this.capeAlias; }

  getOwnedCapes(): AccountCape[] {
    // slice 防止 UI 直接改这份内部状态（@State 持有时尤其要紧）
    return this.ownedCapes.slice();
  }

  /**
   * 切换 active cape。capeId === null → 取消佩戴。
   *
   * 流程：
   *   1. 确保 token 新鲜（自动 refresh，避免 401 单步重试）
   *   2. 调 PUT /capes/active 或 DELETE /capes/active
   *   3. Mojang 返回新 profile → applyProfile 把 active cape + ownedCapes 同步本地
   *
   * 错误转义：
   *   - 401 token_expired → AccountError(TOKEN_EXPIRED)
   *   - 400 invalid_response → AccountError(INVALID_CAPE)
   *   - 网络 → AccountError(NETWORK)
   *   - 其他 → AccountError(UNKNOWN)
   *
   * 持久化由调用方（AccountManager.persistOne）在成功后统一触发，本方法只刷内存。
   */
  async setActiveCape(capeId: string | null): Promise<void> {
    // 触发自动 refresh（getAccessToken 内部判断 expired），保证 PUT 用的是新鲜 token
    let token = await this.getAccessToken();
    AppLogger.info(TAG,
      `setActiveCape: id=${this.id} capeId=${capeId === null ? '<null>' : capeId}`,
      LOG_DOMAIN_ACCOUNT);
    try {
      let newProfile: McProfile;
      if (capeId === null) {
        newProfile = await this.deps.mc.removeActiveCape(token);
      } else {
        newProfile = await this.deps.mc.setActiveCape(token, capeId);
      }
      this.applyProfile(newProfile);
      AppLogger.info(TAG,
        `setActiveCape ok: active=${this.capeAlias === null ? '<none>' : this.capeAlias}`,
        LOG_DOMAIN_ACCOUNT);
    } catch (e) {
      throw this.translateProfileError(e as Error, 'cape');
    }
  }

  /**
   * 主动重新拉 Mojang profile（皮肤 / 披风 / ownedCapes），用于"用户在 minecraft.net
   * 新获得披风后 AMCL 本地缓存没更新"的场景。
   *
   * 与 refresh() 的本质区别：
   *   - refresh() token 未过期就 short-circuit，**不会**重新拉 profile
   *   - syncProfile() 永远会发一次 GET /minecraft/profile（先 getAccessToken 自动
   *     做必要的 token 刷新，再发请求）
   *
   * 持久化由调用方触发（一般在 UI 层 await syncProfile() 后调
   * `accountManager.persistOne(acc)`）。本方法只刷内存。
   */
  async syncProfile(): Promise<void> {
    // 自动 refresh，确保 token 新鲜后再发 profile GET
    let token = await this.getAccessToken();
    AppLogger.info(TAG, `syncProfile: id=${this.id}`, LOG_DOMAIN_ACCOUNT);
    try {
      let profile = await this.deps.mc.getProfile(token);
      this.applyProfile(profile);
      AppLogger.info(TAG,
        `syncProfile ok: skin=${this.skinUrl !== null ? 'yes' : 'no'} `
          + `cape=${this.capeAlias === null ? '<none>' : this.capeAlias} `
          + `owned=${this.ownedCapes.length}`,
        LOG_DOMAIN_ACCOUNT);
    } catch (e) {
      throw this.translateProfileError(e as Error, 'sync');
    }
  }

  /**
   * 把 MinecraftAuthError / 网络异常翻译成 AccountError，方便 UI 弹同语义错误。
   *
   * @param e 底层异常
   * @param origin 区分调用语境（'cape' / 'sync'）。invalid_response 在 cape 操作
   *   下应翻译为 INVALID_CAPE（"该披风不属于本账户"），而在 sync 操作下没有 cape
   *   语义，应保持 UNKNOWN。
   */
  private translateProfileError(e: Error, origin: string): AccountError {
    if (e instanceof MinecraftAuthError) {
      let mae = e as MinecraftAuthError;
      if (mae.code === 'token_expired') {
        return new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED, '登录令牌已过期，请刷新后重试');
      }
      if (mae.code === 'not_premium') {
        return new AccountError(ACCOUNT_ERR_NOT_PREMIUM,
          '该账户尚未购买 Minecraft Java 版，无法获取披风信息');
      }
      if (mae.code === 'invalid_response' && origin === 'cape') {
        return new AccountError(ACCOUNT_ERR_INVALID_CAPE, '该披风不属于本账户或参数错误');
      }
      // http_error / sync 下的 invalid_response / 其他 → 透传 message
      return new AccountError(ACCOUNT_ERR_UNKNOWN, mae.message);
    }
    // 网络层异常（Networkkit 抛的 BusinessError 等）一律视为网络错
    let msg = (e && e.message) ? e.message : '未知错误';
    if (msg.indexOf('TIMEOUT') >= 0 || msg.indexOf('NETWORK') >= 0
      || msg.indexOf('timed out') >= 0 || msg.indexOf('connect') >= 0) {
      return new AccountError(ACCOUNT_ERR_NETWORK, '网络异常，请检查连接后重试');
    }
    return new AccountError(ACCOUNT_ERR_UNKNOWN, msg);
  }

  // ===== 私有 helpers =====

  /** mcAccessToken 是否仍在有效期（含 60s 安全边际）。 */
  private isMcTokenFresh(): boolean {
    if (this.mcAccessToken.length === 0) return false;
    return Date.now() < this.mcExpiresAt - REFRESH_MARGIN_MS;
  }
}

// ============================================================
//  互动登录入参
// ============================================================

/** UI 调用 fromInteractiveLogin 时的入参（5 步链路结果集中入口）。 */
export interface InteractiveLoginArgs {
  id: string;
  username: string;       // MC profile.name
  uuid: string;           // MC profile.uuid（canonical 格式）
  createdAt: number;
  refreshToken: string;   // MSA refresh_token（offline_access scope）
  mcAccessToken: string;  // MC bearer
  mcExpiresAt: number;
  // 皮肤 / 披风快照（从 profile 透传）。未获取时 undefined。
  skinUrl?: string;
  skinVariant?: string;
  capeUrl?: string;
  capeAlias?: string;
  /** M2.6：玩家拥有的全部披风（含 active）。空数组 / undefined 都视为无披风。 */
  ownedCapes?: AccountCape[];
}

// ============================================================
//  Helper：跑完整 5 步链路，返回 InteractiveLoginArgs
// ============================================================

/**
 * 给 UI 用的"一气呵成"工具：拿到 MS code/verifier 后跑完整链路，
 * 直接得到 InteractiveLoginArgs，UI 不用关心中间 4 个 token。
 *
 * Auth Code 流和 Device Code 流共用此工具（前置取 token 不同，
 * 但 UI 拿到 MsaTokenSet 后一律调它）。
 */
export async function completeMicrosoftLogin(
  msTokens: MsaTokenSet,
  newAccountId: string,
  deps?: MicrosoftAccountDeps,
): Promise<InteractiveLoginArgs> {
  let d: MicrosoftAccountDeps = deps !== undefined ? deps : defaultMicrosoftDeps();
  let xbl = await d.xbl.authenticateXbl(msTokens.accessToken);
  let xsts = await d.xbl.authorizeXsts(xbl.token);
  let mc = await d.mc.loginWithXbox(xsts.uhs, xsts.token);
  let profile: McProfile = await d.mc.getProfile(mc.accessToken);
  let args: InteractiveLoginArgs = {
    id: newAccountId,
    username: profile.username,
    uuid: profile.uuid,
    createdAt: Date.now(),
    refreshToken: msTokens.refreshToken,
    mcAccessToken: mc.accessToken,
    mcExpiresAt: mc.expiresAt,
  };
  if (profile.skin) {
    args.skinUrl = profile.skin.url;
    args.skinVariant = profile.skin.variant;
  }
  if (profile.cape) {
    args.capeUrl = profile.cape.url;
    args.capeAlias = profile.cape.alias;
  }
  // OwnedCape 与 AccountCape 字段同构，slice() 出来的拷贝塞进去就行
  args.ownedCapes = profile.ownedCapes.slice() as AccountCape[];
  return args;
}

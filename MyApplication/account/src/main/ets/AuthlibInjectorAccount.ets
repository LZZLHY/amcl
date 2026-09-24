/**
 * AuthlibInjectorAccount.ets — 第三方皮肤站（authlib-injector / Yggdrasil）账户实现
 *
 * 实现 Account 接口。相较 MicrosoftAccount 的差异：
 *   - 认证走 Yggdrasil 账密流（authenticate → refresh → validate），非 OAuth
 *   - **缓存账号密码**（产品决策：对齐 PCL2，token 失效时静默重登，长期免手动登录）
 *   - 一个账号可有多个角色（availableProfiles），支持运行时切换（switchProfile）
 *   - 启动时需要额外注入 -javaagent:authlib-injector.jar=<apiRoot>（由 launch 层处理，
 *     本类通过 getApiRoot() 暴露地址）
 *
 * 认证链路（refresh）对齐 PCL2 ModLaunch.McLoginServerStart：
 *   validate（最快，token 未变直接用）→ refresh（token 失效但可续）→ 账密重登（兜底）
 *
 * 持久化：
 *   - 敏感字段（clientToken / accessToken / 登录账密）进 encrypted blob（HUKS AES-GCM）
 *   - apiRoot / serverName / 角色列表 / 皮肤披风 URL 明文（公开信息）
 *
 * 创建日期：2026-07-02（M4 Phase A）
 */

import {
  Account,
  AccountType,
  AccountRecord,
  AccountProfile,
  AccountCape,
  AccountError,
  ACCOUNT_ERR_NETWORK,
  ACCOUNT_ERR_TOKEN_EXPIRED,
  ACCOUNT_ERR_NOT_PREMIUM,
  ACCOUNT_ERR_UNAVAILABLE,
  ACCOUNT_ERR_UNKNOWN,
  EncryptedBlob,
  ProfileFieldSink,
} from './Account';
import { RealHttpClient } from './microsoft/HttpClient';
import { YggdrasilApi, YggProfile, YggAuthResult, YggdrasilError, normalizeRoot, stripDashes } from './authlib/YggdrasilApi';
import { randomAccountId } from './OfflineAccount';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'AuthlibInjectorAccount';

// ============================================================
//  依赖注入
// ============================================================

/** AuthlibInjectorAccount 的网络依赖。测试注入 fake，生产用 default。 */
export interface AuthlibAccountDeps {
  ygg: YggdrasilApi;
}

export function defaultAuthlibDeps(): AuthlibAccountDeps {
  return { ygg: new YggdrasilApi(new RealHttpClient()) };
}

// ============================================================
//  序列化 schema（packed into AccountRecord.encrypted.ciphertext）
// ============================================================

interface AuthlibSensitivePayload {
  clientToken: string;
  accessToken: string;
  /** 登录账号（邮箱 / 用户名）。缓存以便 token 失效时静默重登。 */
  loginUsername: string;
  /** 登录密码。产品决策：缓存（对齐 PCL2）。 */
  loginPassword: string;
}

// ============================================================
//  互动登录入参（UI 完成 authenticate + 选角后构造账户）
// ============================================================

export interface AuthlibLoginArgs {
  id: string;
  createdAt: number;
  apiRoot: string;
  serverName: string;
  loginUsername: string;
  loginPassword: string;
  clientToken: string;
  accessToken: string;
  /** 当前选中角色（决定 username/uuid）。 */
  selectedProfile: AccountProfile;
  /** 账号下全部角色。 */
  availableProfiles: AccountProfile[];
  skinUrl?: string;
  skinVariant?: string;
  capeUrl?: string;
}

// ============================================================
//  AuthlibInjectorAccount
// ============================================================

export class AuthlibInjectorAccount implements Account {
  readonly id: string;
  readonly type: AccountType = AccountType.AUTHLIB_INJECTOR;
  readonly createdAt: number;

  // username / uuid 随「切换角色」变化，故用 getter 背后的可变字段实现 Account 的 readonly 契约。
  private _username: string;
  private _uuid: string;

  private apiRoot: string;
  private serverName: string;
  private clientToken: string;
  private accessToken: string;
  private loginUsername: string;
  private loginPassword: string;
  private availableProfiles: AccountProfile[];

  // 皮肤 / 披风快照（仅展示用）。Yggdrasil 无 ownedCapes 概念，只有当前 active cape。
  private skinUrl: string | null = null;
  private skinVariant: string | null = null;
  private capeUrl: string | null = null;

  private deps: AuthlibAccountDeps;

  private constructor(
    id: string,
    createdAt: number,
    username: string,
    uuid: string,
    apiRoot: string,
    serverName: string,
    clientToken: string,
    accessToken: string,
    loginUsername: string,
    loginPassword: string,
    availableProfiles: AccountProfile[],
    skinUrl: string | null,
    skinVariant: string | null,
    capeUrl: string | null,
    deps: AuthlibAccountDeps,
  ) {
    this.id = id;
    this.createdAt = createdAt;
    this._username = username;
    this._uuid = uuid;
    this.apiRoot = apiRoot;
    this.serverName = serverName;
    this.clientToken = clientToken;
    this.accessToken = accessToken;
    this.loginUsername = loginUsername;
    this.loginPassword = loginPassword;
    this.availableProfiles = availableProfiles;
    this.skinUrl = skinUrl;
    this.skinVariant = skinVariant;
    this.capeUrl = capeUrl;
    this.deps = deps;
  }

  // getter 满足 Account 的 readonly username/uuid 契约（可随切换角色变化）
  get username(): string { return this._username; }
  get uuid(): string { return this._uuid; }

  /** UI 完成账密登录 + 选角后调用，构造账户交给 AccountManager.add。 */
  static fromInteractiveLogin(args: AuthlibLoginArgs, deps?: AuthlibAccountDeps): AuthlibInjectorAccount {
    let d: AuthlibAccountDeps = deps !== undefined ? deps : defaultAuthlibDeps();
    return new AuthlibInjectorAccount(
      args.id,
      args.createdAt,
      args.selectedProfile.name,
      args.selectedProfile.id,
      normalizeRoot(args.apiRoot),
      args.serverName,
      args.clientToken,
      args.accessToken,
      args.loginUsername,
      args.loginPassword,
      args.availableProfiles.slice(),
      args.skinUrl !== undefined ? args.skinUrl : null,
      args.skinVariant !== undefined ? args.skinVariant : null,
      args.capeUrl !== undefined ? args.capeUrl : null,
      d,
    );
  }

  /** 从持久化记录恢复。AccountManager.deserialize 调用。 */
  static fromRecord(record: AccountRecord, deps?: AuthlibAccountDeps): AuthlibInjectorAccount | null {
    if (record.type !== AccountType.AUTHLIB_INJECTOR) {
      AppLogger.warn(TAG, `fromRecord: type mismatch (got ${record.type})`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    if (!record.encrypted || !record.encrypted.ciphertext) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} missing encrypted payload`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    let payload: AuthlibSensitivePayload | null = null;
    try {
      payload = JSON.parse(record.encrypted.ciphertext) as AuthlibSensitivePayload;
    } catch (e) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} payload parse failed`, e as Object, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    if (!payload) {
      return null;
    }
    let apiRoot = typeof record.authApiRoot === 'string' ? record.authApiRoot : '';
    if (apiRoot.length === 0) {
      AppLogger.warn(TAG, `fromRecord: id=${record.id} missing authApiRoot`, null, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    let d: AuthlibAccountDeps = deps !== undefined ? deps : defaultAuthlibDeps();
    return new AuthlibInjectorAccount(
      record.id,
      record.createdAt > 0 ? record.createdAt : Date.now(),
      record.username,
      record.uuid,
      normalizeRoot(apiRoot),
      typeof record.authServerName === 'string' ? record.authServerName : '',
      typeof payload.clientToken === 'string' ? payload.clientToken : '',
      typeof payload.accessToken === 'string' ? payload.accessToken : '',
      typeof payload.loginUsername === 'string' ? payload.loginUsername : '',
      typeof payload.loginPassword === 'string' ? payload.loginPassword : '',
      Array.isArray(record.authProfiles) ? record.authProfiles.slice() : [],
      typeof record.skinUrl === 'string' ? record.skinUrl : null,
      typeof record.skinVariant === 'string' ? record.skinVariant : null,
      typeof record.capeUrl === 'string' ? record.capeUrl : null,
      d,
    );
  }

  // ===== Account 接口实现 =====

  async getAccessToken(): Promise<string> {
    if (this.accessToken.length > 0) {
      return this.accessToken;
    }
    await this.refresh();
    return this.accessToken;
  }

  /**
   * 刷新链路（对齐 PCL2）：validate → refresh → 账密重登。
   * 成功后 accessToken（及可能的 username/uuid）已更新。
   * 失败抛 AccountError（NETWORK / TOKEN_EXPIRED / NOT_PREMIUM / UNKNOWN）。
   */
  async refresh(): Promise<void> {
    AppLogger.info(TAG, `refresh start: id=${this.id}`, LOG_DOMAIN_ACCOUNT);
    // 1) validate：token 仍有效 → 直接用，只顺手同步纹理
    if (this.accessToken.length > 0 && this.clientToken.length > 0) {
      let stillValid = false;
      try {
        stillValid = await this.deps.ygg.validate(this.apiRoot, this.accessToken, this.clientToken);
      } catch (e) {
        throw this.translate(e as Error);
      }
      if (stillValid) {
        AppLogger.info(TAG, `refresh: token still valid (id=${this.id})`, LOG_DOMAIN_ACCOUNT);
        await this.syncTexturesBestEffort();
        return;
      }
      // 2) refresh：token 失效但 clientToken 仍可续（不动当前角色）
      try {
        let r = await this.deps.ygg.refresh(this.apiRoot, this.accessToken, this.clientToken, null);
        this.accessToken = r.accessToken;
        this.clientToken = r.clientToken;
        if (r.selectedProfile !== null) {
          this._uuid = r.selectedProfile.id;
          this._username = r.selectedProfile.name;
        }
        AppLogger.info(TAG, `refresh: token refreshed (id=${this.id})`, LOG_DOMAIN_ACCOUNT);
        await this.syncTexturesBestEffort();
        return;
      } catch (e) {
        // 网络错直接上抛；其它（token 失效等）落到账密重登兜底。
        // 先转 Error 再交给 typed 方法判定，避免对 catch 变量直接向下转型（ArkTS 限制）。
        let err = e as Error;
        if (this.isNetworkError(err)) {
          throw this.translate(err);
        }
        AppLogger.info(TAG, `refresh: /refresh failed, falling back to re-login (id=${this.id})`, LOG_DOMAIN_ACCOUNT);
        // 落到账密重登
      }
    }
    // 3) 账密重登（兜底）：绑定当前角色
    await this.reloginBind(this._uuid);
    await this.syncTexturesBestEffort();
  }

  fillProfile(sink: ProfileFieldSink): void {
    sink.setUsername(this._username);
    sink.setUuid(this._uuid);
    sink.setAccessToken(this.accessToken);
    // authlib-injector 场景 userType 用 'mojang'（AccountType.AUTHLIB_INJECTOR 的值）
    sink.setUserType(AccountType.AUTHLIB_INJECTOR);
  }

  serialize(): AccountRecord {
    let payload: AuthlibSensitivePayload = {
      clientToken: this.clientToken,
      accessToken: this.accessToken,
      loginUsername: this.loginUsername,
      loginPassword: this.loginPassword,
    };
    // 明文标记：iv/tag 空，AccountManager.add/persistOne 会调 storage.encrypt 真加密
    let encrypted: EncryptedBlob = { iv: '', ciphertext: JSON.stringify(payload), tag: '' };
    let rec: AccountRecord = {
      version: 1,
      id: this.id,
      type: this.type,
      username: this._username,
      uuid: this._uuid,
      createdAt: this.createdAt,
      encrypted: encrypted,
      authApiRoot: this.apiRoot,
    };
    if (this.serverName.length > 0) rec.authServerName = this.serverName;
    if (this.availableProfiles.length > 0) rec.authProfiles = this.availableProfiles.slice();
    if (this.skinUrl) rec.skinUrl = this.skinUrl;
    if (this.skinVariant) rec.skinVariant = this.skinVariant;
    if (this.capeUrl) rec.capeUrl = this.capeUrl;
    return rec;
  }

  async isUsable(): Promise<boolean> {
    // 有 token 可续，或有缓存账密可重登 → 可用
    if (this.accessToken.length > 0) return true;
    return this.loginUsername.length > 0 && this.loginPassword.length > 0;
  }

  getDisplayName(): string { return this._username; }

  getSkinUrl(): string | null { return this.skinUrl; }
  getSkinVariant(): string | null { return this.skinVariant; }
  getCapeUrl(): string | null { return this.capeUrl; }
  // Yggdrasil 纹理不带披风别名；有披风时 UI 显示「已佩戴」。
  getCapeAlias(): string | null { return null; }

  // Yggdrasil 无 ownedCapes 概念（披风由皮肤站网站管理），返回空数组。
  getOwnedCapes(): AccountCape[] { return []; }

  // 皮肤站披风由网站端管理，启动器不支持云端切换 → UNAVAILABLE（UI 按钮应置灰）。
  setActiveCape(_capeId: string | null): Promise<void> {
    return Promise.reject(
      new AccountError(ACCOUNT_ERR_UNAVAILABLE, '第三方皮肤站的披风请在其网站上更换')
    );
  }

  /**
   * 主动拉纹理（皮肤/披风），刷新本地快照。失败抛 AccountError。
   * Yggdrasil 的 sessionserver 纹理接口是公开的（无需 Authorization），故不触发 token 刷新。
   */
  async syncProfile(): Promise<void> {
    try {
      let tex = await this.deps.ygg.fetchProfileTextures(this.apiRoot, this._uuid);
      this.skinUrl = tex.skinUrl;
      this.skinVariant = tex.skinVariant;
      this.capeUrl = tex.capeUrl;
      AppLogger.info(TAG,
        `syncProfile ok: skin=${this.skinUrl !== null ? 'yes' : 'no'} cape=${this.capeUrl !== null ? 'yes' : 'no'}`,
        LOG_DOMAIN_ACCOUNT);
    } catch (e) {
      throw this.translate(e as Error);
    }
  }

  // ===== authlib 专用（UI 向下转型调用） =====

  /** 启动时作为 -javaagent 参数的 API 根。 */
  getApiRoot(): string { return this.apiRoot; }

  /** 皮肤站显示名（可能为空）。 */
  getServerName(): string { return this.serverName; }

  /** 账号下可选角色列表（用于「切换角色」UI）。 */
  getAvailableProfiles(): AccountProfile[] { return this.availableProfiles.slice(); }

  /**
   * 切换当前角色（决策 #3：允许运行时切换）。
   * 流程：账密重登（拿到未绑定的新 token）→ refresh 绑定目标角色 → 更新 username/uuid。
   * 成功后内部状态已更新；持久化由调用方（AccountManager.persistOne）触发。
   *
   * @param profileId 目标角色 UUID（canonical）。必须属于 availableProfiles。
   */
  async switchProfile(profileId: string): Promise<void> {
    let target: AccountProfile | null = null;
    for (let p of this.availableProfiles) {
      if (p.id === profileId) { target = p; break; }
    }
    if (target === null) {
      throw new AccountError(ACCOUNT_ERR_UNKNOWN, '目标角色不属于该账号');
    }
    AppLogger.info(TAG, `switchProfile: id=${this.id} -> ${target.name}`, LOG_DOMAIN_ACCOUNT);
    await this.reloginBind(profileId);
    await this.syncTexturesBestEffort();
  }

  // ===== 私有 helpers =====

  /**
   * 账密重登并绑定到指定角色（preferredId 匹配不到则回退 selectedProfile / 首个）。
   * 需要缓存的账密（决策 #1）；无则抛 TOKEN_EXPIRED 让 UI 引导重新登录。
   */
  private async reloginBind(preferredId: string): Promise<void> {
    if (this.loginUsername.length === 0 || this.loginPassword.length === 0) {
      throw new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED, '登录状态已过期，请重新登录第三方账号');
    }
    let authRes: YggAuthResult;
    try {
      authRes = await this.deps.ygg.authenticate(this.apiRoot, this.loginUsername, this.loginPassword, this.clientToken);
    } catch (e) {
      throw this.translate(e as Error);
    }
    this.clientToken = authRes.clientToken;
    this.availableProfiles = yggProfilesToAccount(authRes.availableProfiles);
    let target = this.chooseProfile(preferredId, authRes);
    if (target === null) {
      throw new AccountError(ACCOUNT_ERR_NOT_PREMIUM, '该账号下没有可用角色，请先在皮肤站创建角色');
    }
    // 已选中且就是目标 → 直接用 authenticate 的 token；否则 refresh 绑定
    let selected = authRes.selectedProfile;
    if (selected !== null && selected.id === target.id) {
      this.accessToken = authRes.accessToken;
    } else {
      try {
        let yp: YggProfile = { id: target.id, name: target.name };
        let r = await this.deps.ygg.refresh(this.apiRoot, authRes.accessToken, this.clientToken, yp);
        this.accessToken = r.accessToken;
        this.clientToken = r.clientToken;
      } catch (e) {
        throw this.translate(e as Error);
      }
    }
    this._uuid = target.id;
    this._username = target.name;
  }

  /** 选角策略：优先 preferredId → selectedProfile → 首个。都没有 → null。 */
  private chooseProfile(preferredId: string, authRes: YggAuthResult): AccountProfile | null {
    if (authRes.availableProfiles.length === 0) return null;
    if (preferredId.length > 0) {
      for (let p of authRes.availableProfiles) {
        if (p.id === preferredId) return { id: p.id, name: p.name };
      }
    }
    if (authRes.selectedProfile !== null) {
      return { id: authRes.selectedProfile.id, name: authRes.selectedProfile.name };
    }
    let first = authRes.availableProfiles[0];
    return { id: first.id, name: first.name };
  }

  /** 拉纹理但吞掉错误（纹理只影响展示，不该阻断登录/启动）。 */
  private async syncTexturesBestEffort(): Promise<void> {
    try {
      let tex = await this.deps.ygg.fetchProfileTextures(this.apiRoot, this._uuid);
      this.skinUrl = tex.skinUrl;
      this.skinVariant = tex.skinVariant;
      this.capeUrl = tex.capeUrl;
    } catch (e) {
      AppLogger.warn(TAG, 'texture sync failed (non-fatal)', e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  /** 是否为网络错（YggdrasilError code='network'）。参数 typed Error 以便安全向下转型。 */
  private isNetworkError(e: Error): boolean {
    if (e instanceof YggdrasilError) {
      let ye = e as YggdrasilError;
      return ye.code === 'network';
    }
    return false;
  }

  /** YggdrasilError / 网络异常 → AccountError（UI 可读）。 */
  private translate(e: Error): AccountError {
    if (e instanceof YggdrasilError) {
      let ye = e as YggdrasilError;
      if (ye.code === 'network') {
        return new AccountError(ACCOUNT_ERR_NETWORK, '网络异常，请检查连接后重试');
      }
      if (ye.code === 'invalid_credentials') {
        return new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED,
          ye.serverMessage.length > 0 ? ye.serverMessage : '账号或密码错误');
      }
      if (ye.code === 'invalid_token') {
        return new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED, '登录状态已过期，请重新登录');
      }
      if (ye.code === 'no_profile') {
        return new AccountError(ACCOUNT_ERR_NOT_PREMIUM, '该账号下没有可用角色');
      }
      return new AccountError(ACCOUNT_ERR_UNKNOWN,
        ye.serverMessage.length > 0 ? ye.serverMessage : ye.message);
    }
    let msg = (e && e.message) ? e.message : '未知错误';
    if (msg.indexOf('TIMEOUT') >= 0 || msg.indexOf('NETWORK') >= 0
      || msg.indexOf('timed out') >= 0 || msg.indexOf('connect') >= 0) {
      return new AccountError(ACCOUNT_ERR_NETWORK, '网络异常，请检查连接后重试');
    }
    return new AccountError(ACCOUNT_ERR_UNKNOWN, msg);
  }
}

// ============================================================
//  登录辅助（供 UI 使用；两阶段以支持多角色选择）
// ============================================================

/** 生成 clientToken（32 hex，无连字符）。一个账户固定一份，refresh/validate 复用。 */
export function generateClientToken(): string {
  return stripDashes(randomAccountId());
}

/**
 * 登录会话（authenticate 完成后的中间态）。UI 据此决定是否需要弹「选择角色」。
 */
export interface AuthlibAuthSession {
  resolvedRoot: string;
  serverName: string;
  loginUsername: string;
  loginPassword: string;
  clientToken: string;
  accessToken: string;
  availableProfiles: AccountProfile[];
  selectedProfile: AccountProfile | null;
}

/**
 * 阶段 1：解析元数据（含 ALI）+ 账密登录。返回会话中间态。
 *   - UI 拿到 availableProfiles：若 >1 且 selectedProfile 为空 → 弹选择框
 *   - 失败抛 AccountError（NETWORK / TOKEN_EXPIRED[账密错] / UNKNOWN）
 */
export async function authlibAuthenticate(
  apiRoot: string,
  username: string,
  password: string,
  deps?: AuthlibAccountDeps,
): Promise<AuthlibAuthSession> {
  let d: AuthlibAccountDeps = deps !== undefined ? deps : defaultAuthlibDeps();
  let clientToken = generateClientToken();
  try {
    let meta = await d.ygg.resolveMetadata(apiRoot);
    let authRes = await d.ygg.authenticate(meta.resolvedRoot, username, password, clientToken);
    let avail: AccountProfile[] = [];
    for (let p of authRes.availableProfiles) {
      avail.push({ id: p.id, name: p.name });
    }
    let selected: AccountProfile | null = authRes.selectedProfile !== null
      ? { id: authRes.selectedProfile.id, name: authRes.selectedProfile.name } : null;
    return {
      resolvedRoot: meta.resolvedRoot,
      serverName: meta.serverName,
      loginUsername: username,
      loginPassword: password,
      clientToken: authRes.clientToken,
      accessToken: authRes.accessToken,
      availableProfiles: avail,
      selectedProfile: selected,
    };
  } catch (e) {
    throw translateStandalone(e as Error);
  }
}

/**
 * 阶段 2：绑定选中角色并构造 AuthlibLoginArgs。
 *   - 若 chosenProfile 已是 session.selectedProfile → 直接用 session.accessToken
 *   - 否则 refresh 绑定该角色
 *   - 顺手拉一次纹理（失败不阻断）
 */
export async function authlibBindProfile(
  session: AuthlibAuthSession,
  chosenProfile: AccountProfile,
  newAccountId: string,
  deps?: AuthlibAccountDeps,
): Promise<AuthlibLoginArgs> {
  let d: AuthlibAccountDeps = deps !== undefined ? deps : defaultAuthlibDeps();
  let accessToken = session.accessToken;
  let clientToken = session.clientToken;
  let needBind = session.selectedProfile === null || session.selectedProfile.id !== chosenProfile.id;
  try {
    if (needBind) {
      let yp: YggProfile = { id: chosenProfile.id, name: chosenProfile.name };
      let r = await d.ygg.refresh(session.resolvedRoot, session.accessToken, session.clientToken, yp);
      accessToken = r.accessToken;
      clientToken = r.clientToken;
    }
  } catch (e) {
    throw translateStandalone(e as Error);
  }
  let args: AuthlibLoginArgs = {
    id: newAccountId,
    createdAt: Date.now(),
    apiRoot: session.resolvedRoot,
    serverName: session.serverName,
    loginUsername: session.loginUsername,
    loginPassword: session.loginPassword,
    clientToken: clientToken,
    accessToken: accessToken,
    selectedProfile: chosenProfile,
    availableProfiles: session.availableProfiles.slice(),
  };
  // 纹理 best-effort
  try {
    let tex = await d.ygg.fetchProfileTextures(session.resolvedRoot, chosenProfile.id);
    if (tex.skinUrl !== null) args.skinUrl = tex.skinUrl;
    if (tex.skinVariant !== null) args.skinVariant = tex.skinVariant;
    if (tex.capeUrl !== null) args.capeUrl = tex.capeUrl;
  } catch (e) {
    // 忽略：纹理仅展示用
  }
  return args;
}

/**
 * YggProfile[] → AccountProfile[]（逐个重建，不用结构化 as 转换 —— ArkTS 禁止
 * arkts-no-structural-typing）。
 */
function yggProfilesToAccount(arr: YggProfile[]): AccountProfile[] {
  let out: AccountProfile[] = [];
  for (let p of arr) {
    out.push({ id: p.id, name: p.name });
  }
  return out;
}

/** 独立函数版错误翻译（与类内 translate 同语义）。 */
function translateStandalone(e: Error): AccountError {
  if (e instanceof YggdrasilError) {
    let ye = e as YggdrasilError;
    if (ye.code === 'network') {
      return new AccountError(ACCOUNT_ERR_NETWORK, '网络异常，请检查连接后重试');
    }
    if (ye.code === 'invalid_credentials') {
      return new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED,
        ye.serverMessage.length > 0 ? ye.serverMessage : '账号或密码错误');
    }
    if (ye.code === 'invalid_token') {
      return new AccountError(ACCOUNT_ERR_TOKEN_EXPIRED, '登录状态已过期，请重新登录');
    }
    if (ye.stage === 'metadata') {
      return new AccountError(ACCOUNT_ERR_UNKNOWN,
        '无法连接到皮肤站（' + (ye.serverMessage.length > 0 ? ye.serverMessage : ye.message) + '）');
    }
    return new AccountError(ACCOUNT_ERR_UNKNOWN,
      ye.serverMessage.length > 0 ? ye.serverMessage : ye.message);
  }
  let msg = (e && e.message) ? e.message : '未知错误';
  return new AccountError(ACCOUNT_ERR_UNKNOWN, msg);
}

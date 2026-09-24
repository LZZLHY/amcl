/**
 * Account.ets — 账户体系核心接口与类型定义
 *
 * 所有账户类型（离线 / 微软正版 / 第三方皮肤站）共用的抽象。
 * 不依赖任何具体实现，只定义契约 —— 便于单元测试 mock。
 *
 * 设计参考：
 *   - HMCL 的 Account 抽象类（logIn / refresh / play）
 *   - Mojang launcher_profiles 的 authenticationDatabase 结构
 *
 * 创建日期：2026-05-09（M1：账户抽象骨架）
 */

// ============================================================
//  账户类型枚举（值与 MC --userType 参数对应）
// ============================================================

export enum AccountType {
  OFFLINE = 'legacy',           // 离线模式
  MICROSOFT = 'msa',            // 微软正版（M2 落地）
  AUTHLIB_INJECTOR = 'mojang',  // 第三方皮肤站（M4 落地，复用 mojang userType 兼容）
}

// ============================================================
//  LaunchProfileBuilder 注入点（最小接口，便于 mock）
// ============================================================

/**
 * 账户字段灌入下游 builder 的最小接口契约。
 * LaunchProfileBuilder 已天然满足此接口（4 个 setter 已存在），无需改动。
 *
 * 测试时可直接 new 一个 fake sink 验证 setter 调用次数与参数。
 */
export interface ProfileFieldSink {
  setUsername(name: string): ProfileFieldSink;
  setUuid(uuid: string): ProfileFieldSink;
  setAccessToken(token: string): ProfileFieldSink;
  setUserType(type: string): ProfileFieldSink;
}

// ============================================================
//  持久化 schema
// ============================================================

/**
 * 加密 blob（仅 MicrosoftAccount 在 M2+ 用到）。
 * M1 阶段 OfflineAccount 不写 encrypted 字段。
 */
export interface EncryptedBlob {
  iv: string;          // Base64
  ciphertext: string;  // Base64
  tag: string;         // Base64 (GCM tag)
}

/**
 * 账户持久化记录（落 preferences 时序列化为 JSON）。
 *
 * version 字段用于将来 schema 升级（M1 = 1）。
 */
export interface AccountRecord {
  version: number;            // schema 版本，M1 = 1
  id: string;                 // 稳定 UUID v4，列表索引
  type: AccountType;
  username: string;           // 明文显示名
  uuid: string;               // MC UUID（36 字符）
  createdAt: number;          // 毫秒时间戳

  // 仅 MicrosoftAccount 有，M1 不使用
  encrypted?: EncryptedBlob;

  // ===== M2.5 扩展：皮肤 / 披风快照（明文 — 它们本就是公开 URL） =====
  // 反序列化时缺失要 graceful（老记录无此字段）。
  /** 皮肤 PNG URL（textures.minecraft.net 域）。Offline / 未拉取时 undefined。 */
  skinUrl?: string;
  /** 'CLASSIC' | 'SLIM'。 */
  skinVariant?: string;
  /** 当前佩戴的披风 PNG URL。无披风的玩家永远 undefined。 */
  capeUrl?: string;
  /** 披风别名（'Migrator' / 'Vanilla' 等）。仅展示用。 */
  capeAlias?: string;
  /**
   * M2.6 扩展：玩家拥有的全部披风快照（含 active 那个）。
   *
   * 缓存这份让"皮肤详情" sheet 离线（无网/未刷新）时也能显示历史披风列表，
   * 不必每次开 sheet 都触发 token 刷新 + Mojang profile 调用。
   *
   * 切披风（setActiveCape）成功后会把这份覆盖更新。
   * 老记录（< M2.6）没这个字段 → 反序列化按 [] 处理。
   */
  ownedCapes?: AccountCapeRecord[];

  // ===== M4 扩展：第三方皮肤站（AUTHLIB_INJECTOR）专用字段（明文） =====
  // 敏感字段（accessToken / clientToken / 登录账密）在 encrypted 里；下面这些是
  // 非敏感的展示/启动元数据，明文存无妨。老记录（非 authlib）无此字段 → undefined。
  /** authlib-injector API 根（ALI 解析后的最终地址）。启动时作为 -javaagent 参数。 */
  authApiRoot?: string;
  /** 皮肤站显示名（GET apiRoot 的 meta.serverName）。UI 徽章展示用。 */
  authServerName?: string;
  /** 账号下可选角色列表（用于「切换角色」）。空/缺失表示只有单角色或未知。 */
  authProfiles?: AccountProfile[];
}

/** Yggdrasil / 皮肤站账号下的一个角色（多角色账号可切换）。 */
export interface AccountProfile {
  /** 角色 UUID（canonical 8-4-4-4-12）。 */
  id: string;
  /** 角色名（= MC 玩家名）。 */
  name: string;
}

/** 持久化的披风条目（与 AccountCape 同构，分开命名只是为了语义区分"接口 vs 落库"）。 */
export interface AccountCapeRecord {
  id: string;
  url: string;
  alias: string;
  isActive: boolean;
}

// ============================================================
//  账户接口
// ============================================================

/**
 * 账户契约。所有具体账户类型（OfflineAccount / MicrosoftAccount / ...）实现此接口。
 *
 * 字段不可变（readonly）—— 状态变更通过返回新实例或内部可变字段（如 token 刷新）完成，
 * 但对外暴露的 username/uuid/id 不变。
 */
export interface Account {
  readonly id: string;
  readonly type: AccountType;
  readonly username: string;
  readonly uuid: string;
  readonly createdAt: number;

  /**
   * 取当前有效的 MC accessToken。
   * - OfflineAccount: 返回稳定占位 token
   * - MicrosoftAccount: 自动判断过期阈值（提前 60s）触发 refresh
   *
   * 失败抛 AccountError（详见 errors）。
   */
  getAccessToken(): Promise<string>;

  /**
   * 强制刷新（不看 expires_at）。
   * - OfflineAccount: no-op，立即 resolve
   * - MicrosoftAccount: 走 refresh_token → XBL → XSTS → MC bearer 链路
   */
  refresh(): Promise<void>;

  /**
   * 把账户字段注入 LaunchProfileBuilder（或任意满足 ProfileFieldSink 的 mock）。
   *
   * **同步**调用：调用前确保 token 已就绪（一般先 await refresh()）。
   */
  fillProfile(sink: ProfileFieldSink): void;

  /**
   * 序列化为持久化 schema。
   */
  serialize(): AccountRecord;

  /**
   * 是否可用于启动（token 有效或可刷新）。
   * - OfflineAccount: 永远 true
   * - MicrosoftAccount: 视 refresh_token 状态而定
   */
  isUsable(): Promise<boolean>;

  /**
   * UI 显示名（一般等于 username，但允许子类追加后缀如 "(未登录)"）。
   */
  getDisplayName(): string;

  // ============================================================
  //  皮肤 / 披风（M2.5 引入）
  //
  //  这些是【可选】信息，不影响 launchProfile 注入。仅 UI 展示用。
  //  Offline / 第三方皮肤站没拉到 profile 时全部返 null。
  //  MicrosoftAccount 在 fromInteractiveLogin / refresh 时同步更新。
  // ============================================================

  /** 当前皮肤 PNG URL；无 → null。 */
  getSkinUrl(): string | null;
  /** 'CLASSIC' | 'SLIM'；无皮肤 → null。 */
  getSkinVariant(): string | null;
  /** 当前披风 PNG URL；未佩戴 → null。 */
  getCapeUrl(): string | null;
  /** 披风别名（'Migrator' 等），未佩戴 → null。 */
  getCapeAlias(): string | null;

  /**
   * 玩家拥有的全部披风快照（含当前 active 那个）。
   *   - MicrosoftAccount: 在 fromInteractiveLogin / refresh 时同步
   *   - OfflineAccount: 永远空数组（离线账户没有 Mojang 服务）
   *
   * 返回的数组里每个 entry 的 isActive 字段标记当前佩戴的披风。
   * UI 在 SkinCapeDetailSheet 用此列表显示「我的披风」+ 切换按钮。
   */
  getOwnedCapes(): AccountCape[];

  /**
   * 切换 active cape。
   *   - capeId !== null → PUT /minecraft/profile/capes/active 设为新 cape
   *   - capeId === null → DELETE /minecraft/profile/capes/active 取消 cape
   *
   * 成功后内部状态（capeUrl / capeAlias / ownedCapes）已同步刷新。
   *
   * - MicrosoftAccount: 真调 Mojang API；失败抛 AccountError（NETWORK / TOKEN_EXPIRED / UNKNOWN）
   * - OfflineAccount: 抛 AccountError('UNAVAILABLE'，离线不支持云端切换披风）
   */
  setActiveCape(capeId: string | null): Promise<void>;

  /**
   * 主动从 Mojang 拉取最新的 profile（皮肤 / 披风 / ownedCapes），用于解决
   * "玩家在 minecraft.net 新获得披风后，AMCL 本地缓存没同步"的场景。
   *
   * 与 refresh() 的区别：
   *   - refresh() 在 token 未过期时**会跳过整套刷新链路**（含 profile 同步），
   *     所以无法用来"强制重新拉披风列表"。
   *   - syncProfile() 不动 token（只会触发 getAccessToken 的自动刷新分支），
   *     永远会发一次 GET /minecraft/profile，把返回结果覆盖到本地快照。
   *
   * 成功后内部状态（skinUrl / capeUrl / capeAlias / ownedCapes）已同步刷新。
   * 持久化由调用方（AccountManager.persistOne）在成功后统一触发，本方法只刷内存。
   *
   * - MicrosoftAccount: 真调 Mojang API；失败抛 AccountError
   *   （NETWORK / TOKEN_EXPIRED / NOT_PREMIUM / UNKNOWN）
   * - OfflineAccount: 立即 resolve（no-op，离线没有 Mojang 服务）
   */
  syncProfile(): Promise<void>;
}

/**
 * Account 层暴露的披风条目（与 MinecraftProfileApi.OwnedCape 等价但住在
 * Account.ets，避免 UI 直接 import microsoft/* 包）。
 */
export interface AccountCape {
  id: string;
  url: string;
  alias: string;
  isActive: boolean;
}

// ============================================================
//  错误类型
// ============================================================

export class AccountError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = 'AccountError';
  }
}

// 通用错误码（M2/M3 还会扩展）
export const ACCOUNT_ERR_NETWORK = 'NETWORK';
export const ACCOUNT_ERR_TOKEN_EXPIRED = 'TOKEN_EXPIRED';
export const ACCOUNT_ERR_NOT_PREMIUM = 'NOT_PREMIUM';
export const ACCOUNT_ERR_INVALID_RECORD = 'INVALID_RECORD';
export const ACCOUNT_ERR_UNKNOWN = 'UNKNOWN';
/** 操作不被该账户类型支持（如离线账户切换披风）。 */
export const ACCOUNT_ERR_UNAVAILABLE = 'UNAVAILABLE';
/** 切换披风时 capeId 不属于该账户（400）。 */
export const ACCOUNT_ERR_INVALID_CAPE = 'INVALID_CAPE';

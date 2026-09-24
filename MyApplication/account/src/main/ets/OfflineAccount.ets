/**
 * OfflineAccount.ets — 离线账户实现
 *
 * 行为：
 *   - username 由用户提供（默认 MCPlayer，等价于现 LaunchProfileBuilder 占位行为）
 *   - uuid 由 username 稳定派生（FNV-1a 64-bit × 2 拼接成 128-bit，格式化为 UUID v4-like）
 *   - accessToken 是固定占位字符串（OFFLINE_ACCESS_TOKEN_PLACEHOLDER）
 *   - userType = 'legacy'
 *
 * 与 Mojang 离线 UUID 兼容性：
 *   Mojang 用 UUID.nameUUIDFromBytes("OfflinePlayer:"+name)（基于 MD5，UUID v3）。
 *   AMCL 用 FNV-1a 64-bit ×2，是 AMCL 内部稳定 UUID，**与 Mojang 不一致**。
 *   理由：避免引入 MD5 实现或异步 cryptoFramework，保持 deriveOfflineUuid 纯同步。
 *   离线模式不联机，UUID 不一致没有实际影响。
 *
 * 创建日期：2026-05-09（M1）
 */

import {
  Account,
  AccountType,
  AccountRecord,
  AccountCape,
  AccountError,
  ACCOUNT_ERR_UNAVAILABLE,
  ProfileFieldSink,
} from './Account';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'OfflineAccount';

// ============================================================
//  常量
// ============================================================

/** 离线模式占位 accessToken（32 字符 hex，与历史值保持一致）。 */
export const OFFLINE_ACCESS_TOKEN_PLACEHOLDER = '00000000000000000000000000000000';

/** 默认用户名（与 LaunchProfileBuilder 历史默认值对齐）。 */
const DEFAULT_USERNAME = 'MCPlayer';

/** UUID 派生 FNV-1a 种子前缀。 */
const FNV_PREFIX_HI = 'OfflinePlayer:';
const FNV_PREFIX_LO = 'AMCL:OfflinePlayer:v1:';

// ============================================================
//  内部工具：FNV-1a 64-bit，纯同步（参考 MetadataCache.fnv1a64Hex 风格）
// ============================================================

/**
 * FNV-1a 64-bit hash，输出 16 hex 字符。
 *
 * 选 FNV 而非 SHA-256：cryptoFramework 是 Promise，纯函数 deriveOfflineUuid 必须同步。
 * 16 hex × 2 = 128 bit，对账户名空间（< 1000 个）碰撞概率可忽略。
 *
 * 实现说明：
 *   - JavaScript number 是 IEEE 754 double，53 位精度，无法精确表示 64-bit 整数
 *   - 拆成 hi32 / lo32 两个 32-bit 模拟，单独 FNV
 *   - 输出按 hi (8 hex) + lo (8 hex) 拼接
 */
function fnv1a64Hex(input: string): string {
  // 64-bit FNV offset basis: 0xcbf29ce484222325 = 0xcbf29ce4_84222325
  let hi = 0xcbf29ce4;
  let lo = 0x84222325;
  // 64-bit FNV prime: 0x100000001b3 = 0x00000100_000001b3
  // 单步 64-bit XOR + multiply 用 JS 32-bit 算术拆解（参考 MurmurHash3 32x4 风格）。
  // 简化策略：在两个 32-bit half 上独立做 FNV-1a 32-bit，输入再 mix 2 次以增加熵。
  // 这是非加密 hash，目标仅为稳定性 + 弱碰撞，足以覆盖账户名场景。
  const FNV_PRIME_32 = 0x01000193;
  for (let i = 0; i < input.length; i++) {
    let code = input.charCodeAt(i) & 0xffff;
    // hi 路：低字节先入
    hi = (hi ^ (code & 0xff)) >>> 0;
    hi = Math.imul(hi, FNV_PRIME_32) >>> 0;
    // lo 路：高字节先入（让 hi/lo 分支差异化）
    lo = (lo ^ ((code >>> 8) & 0xff)) >>> 0;
    lo = Math.imul(lo, FNV_PRIME_32) >>> 0;
    // 混合：再让两路互相 xor 一次
    hi = (hi ^ lo) >>> 0;
    lo = (lo ^ Math.imul(hi, 0x85ebca6b)) >>> 0;
  }
  // 最终再 mix 一轮（diffuse），减少结尾相似输入的 hi 相同
  hi = Math.imul(hi ^ (hi >>> 16), 0x85ebca6b) >>> 0;
  lo = Math.imul(lo ^ (lo >>> 13), 0xc2b2ae35) >>> 0;
  hi = (hi ^ (hi >>> 16)) >>> 0;
  lo = (lo ^ (lo >>> 16)) >>> 0;
  return toHex8(hi) + toHex8(lo);
}

function toHex8(n: number): string {
  let s = (n >>> 0).toString(16);
  while (s.length < 8) s = '0' + s;
  return s;
}

// ============================================================
//  导出：UUID 派生纯函数（独立可测）
// ============================================================

/**
 * 由 username 派生稳定 UUID（36 字符，8-4-4-4-12 格式）。
 *
 * - 同 username 派生结果一致（多次调用稳定）
 * - 不同 username 派生结果不同（碰撞概率 < 2^-64）
 * - 大小写敏感
 * - 支持 Unicode（UTF-16 code unit 直接喂入 FNV）
 *
 * 输出格式（v4-like，第 13 位固定 4 表示版本，第 17 位前 2 bit 固定为 10 表示 RFC 4122 variant）：
 *   xxxxxxxx-xxxx-4xxx-axxx-xxxxxxxxxxxx
 */
export function deriveOfflineUuid(username: string): string {
  let h1 = fnv1a64Hex(FNV_PREFIX_HI + username);
  let h2 = fnv1a64Hex(FNV_PREFIX_LO + username);
  // 32 hex 总位 = h1 (16) + h2 (16)
  let raw = h1 + h2;  // 32 hex
  // 强制 version=4（位 12 固定 '4'）
  let v = '4' + raw.substring(13, 16);  // raw[12..15] → '4xxx'
  // 强制 variant=RFC4122（位 16 高 2 位 10 → hex 字符落在 8/9/a/b 区间）
  // 取原 raw[16] 后强制最高 bit=1 + 第二 bit=0：等价 char & 0x3 | 0x8
  let varHex = raw.charAt(16);
  let varInt = parseInt(varHex, 16);
  let varFixed = ((varInt & 0x3) | 0x8).toString(16);
  let segE = varFixed + raw.substring(17, 20);
  // 拼装 8-4-4-4-12
  return raw.substring(0, 8) + '-'
    + raw.substring(8, 12) + '-'
    + v + '-'
    + segE + '-'
    + raw.substring(20, 32);
}

// ============================================================
//  内部：随机 id（用于 AccountRecord.id，与 uuid 不同）
// ============================================================

/**
 * 生成随机 36 字符 UUID v4 字符串（用于 AccountRecord.id）。
 * 用 Math.random：账户列表索引不要求加密强度。
 *
 * 注：尽管定义在 OfflineAccount.ets 里，本函数与 Offline 类型无关，是账户系统的通用工具。
 * MicrosoftAccount / 第三方皮肤站登录 UI 也复用本函数。
 */
export function randomAccountId(): string {
  let bytes: number[] = [];
  for (let i = 0; i < 16; i++) {
    bytes.push(Math.floor(Math.random() * 256));
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;  // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80;  // variant RFC4122
  let hex = '';
  for (let i = 0; i < 16; i++) {
    let h = bytes[i].toString(16);
    if (h.length < 2) h = '0' + h;
    hex += h;
  }
  return hex.substring(0, 8) + '-'
    + hex.substring(8, 12) + '-'
    + hex.substring(12, 16) + '-'
    + hex.substring(16, 20) + '-'
    + hex.substring(20, 32);
}

// ============================================================
//  OfflineAccount
// ============================================================

export class OfflineAccount implements Account {
  readonly id: string;
  readonly type: AccountType = AccountType.OFFLINE;
  readonly username: string;
  readonly uuid: string;
  readonly createdAt: number;

  private constructor(id: string, username: string, uuid: string, createdAt: number) {
    this.id = id;
    this.username = username;
    this.uuid = uuid;
    this.createdAt = createdAt;
  }

  /**
   * 工厂方法：创建新离线账户。
   * - 空 username 退化为 'MCPlayer'
   * - username 自动 trim（避免前后空格）
   * - 每次 create 生成新 id（即使 username 相同，账户列表里也是独立条目）
   */
  static create(username: string): OfflineAccount {
    let cleanName = (username || '').trim();
    if (cleanName.length === 0) {
      cleanName = DEFAULT_USERNAME;
    }
    let uuid = deriveOfflineUuid(cleanName);
    let id = randomAccountId();
    let createdAt = Date.now();
    AppLogger.info(TAG, `create OfflineAccount: username=${cleanName} id=${id}`, LOG_DOMAIN_ACCOUNT);
    return new OfflineAccount(id, cleanName, uuid, createdAt);
  }

  /**
   * 从持久化记录还原。
   * 容错：username 缺失退化为 MCPlayer，uuid 缺失重新派生。
   */
  static fromRecord(rec: AccountRecord): OfflineAccount {
    let username = (rec.username || '').trim();
    if (username.length === 0) {
      username = DEFAULT_USERNAME;
    }
    let uuid = rec.uuid && rec.uuid.length === 36 ? rec.uuid : deriveOfflineUuid(username);
    let id = rec.id && rec.id.length > 0 ? rec.id : randomAccountId();
    let createdAt = rec.createdAt > 0 ? rec.createdAt : Date.now();
    return new OfflineAccount(id, username, uuid, createdAt);
  }

  // ===== Account 接口实现 =====

  async getAccessToken(): Promise<string> {
    return OFFLINE_ACCESS_TOKEN_PLACEHOLDER;
  }

  async refresh(): Promise<void> {
    // no-op：离线账户没有可刷新的远端凭据
  }

  fillProfile(sink: ProfileFieldSink): void {
    sink.setUsername(this.username);
    sink.setUuid(this.uuid);
    sink.setAccessToken(OFFLINE_ACCESS_TOKEN_PLACEHOLDER);
    sink.setUserType(AccountType.OFFLINE);
  }

  serialize(): AccountRecord {
    return {
      version: 1,
      id: this.id,
      type: AccountType.OFFLINE,
      username: this.username,
      uuid: this.uuid,
      createdAt: this.createdAt,
    };
  }

  async isUsable(): Promise<boolean> {
    return true;
  }

  getDisplayName(): string {
    return this.username;
  }

  // 离线账户没有 Mojang 服务可查的皮肤/披风元数据；UI 应基于 username 派生 fallback。
  getSkinUrl(): string | null { return null; }
  getSkinVariant(): string | null { return null; }
  getCapeUrl(): string | null { return null; }
  getCapeAlias(): string | null { return null; }

  getOwnedCapes(): AccountCape[] { return []; }

  // 离线账户没有 Mojang 服务，不能云端切披风。UI 不该走到这一步（按钮该置灰），
  // 万一走到（开发期 / 未来加入）就抛 UNAVAILABLE 让上层提示。
  setActiveCape(_capeId: string | null): Promise<void> {
    return Promise.reject(
      new AccountError(ACCOUNT_ERR_UNAVAILABLE, '离线账户不支持切换披风（请使用微软账户登录）')
    );
  }

  // 离线账户没有 Mojang profile，syncProfile 是 no-op：直接 resolve，不抛错。
  // UI 在调 syncProfile 前会按 type 决定是否显示"同步"按钮，不应走到这里；但
  // 接口契约要求所有 Account 都实现，no-op 让接口完整性更稳。
  async syncProfile(): Promise<void> {
    // no-op
  }
}

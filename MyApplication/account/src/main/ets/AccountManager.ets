/**
 * AccountManager.ets — 账户列表与选中态管理（单例）
 *
 * 职责：
 *   - 维护账户列表（保留顺序）和选中索引
 *   - 提供 add/remove/select/getSelected API
 *   - 透明委托持久化给 AccountStorage
 *
 * 单例风格参考 LayoutStore.ets：模块级 getAccountManager() 工厂 + init(context)。
 *
 * M1 阶段只支持 OfflineAccount。M2 在 deserialize 分支里加 MicrosoftAccount 即可。
 *
 * 创建日期：2026-05-09（M1）
 */

import {
  Account,
  AccountType,
  AccountRecord,
} from './Account';
import { OfflineAccount } from './OfflineAccount';
import { MicrosoftAccount } from './MicrosoftAccount';
import { AuthlibInjectorAccount } from './AuthlibInjectorAccount';
import { AccountStorage } from './AccountStorage';
import { HuksAesGcm256Provider } from './HuksCryptoProvider';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'AccountManager';

// ============================================================
//  AccountManager
// ============================================================

export class AccountManager {
  private storage: AccountStorage | null = null;
  private accounts: Account[] = [];
  private selectedId: string = '';
  private _ready: boolean = false;
  private _initPromise: Promise<void> | null = null;

  /** 默认 fallback 账户（首次启动 / 列表为空时返回）。永不持久化。 */
  private readonly fallback: OfflineAccount = OfflineAccount.create('MCPlayer');

  isReady(): boolean { return this._ready; }

  async init(context: Context): Promise<void> {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._doInit(context);
    return this._initPromise;
  }

  private async _doInit(context: Context): Promise<void> {
    this.storage = new AccountStorage(context);
    // 探测 HUKS；可用 → 升级 storage.cryptoProvider；不可用 → 保留默认 PlaintextCryptoProvider
    let huksProvider = new HuksAesGcm256Provider();
    if (await huksProvider.isAvailable()) {
      this.storage.setCryptoProvider(huksProvider);
    } else {
      AppLogger.warn(TAG,
        'HUKS unavailable; using PlaintextCryptoProvider (insecure, accounts NOT encrypted at rest)',
        null, LOG_DOMAIN_ACCOUNT);
    }
    await this.reload();
    this._ready = true;
    AppLogger.info(TAG, `init complete: ${this.accounts.length} accounts, selected=${this.selectedId}`,
      LOG_DOMAIN_ACCOUNT);
  }

  async waitReady(): Promise<void> {
    if (this._initPromise) await this._initPromise;
  }

  /**
   * 从持久化重新加载所有账户。
   *
   * 异步：需触发 storage.decrypt() 解密 MicrosoftAccount 敢感字段。
   * 解密失败的账户 → 静默丢弃（款项中有 warn），不阐断其他账户。
   */
  async reload(): Promise<void> {
    if (!this.storage) {
      this.accounts = [];
      this.selectedId = '';
      return;
    }
    let ids = this.storage.getAccountIds();
    let loaded: Account[] = [];
    for (let id of ids) {
      let rec = this.storage.loadRecord(id);
      if (!rec) {
        AppLogger.warn(TAG, `reload: account ${id} record missing, skipping`, null, LOG_DOMAIN_ACCOUNT);
        continue;
      }
      // 若有 encrypted 字段，先解密为明文负载后交给 deserializeAccount
      if (rec.encrypted) {
        try {
          let plaintext = await this.storage.decrypt(rec.encrypted);
          rec.encrypted = { iv: '', ciphertext: plaintext, tag: '' };
        } catch (e) {
          AppLogger.warn(TAG, `reload: account ${id} decrypt failed (record will be dropped)`,
            e as Object, LOG_DOMAIN_ACCOUNT);
          continue;
        }
      }
      let acc = this.deserializeAccount(rec);
      if (acc) {
        loaded.push(acc);
      }
    }
    this.accounts = loaded;
    this.selectedId = this.storage.getSelectedId();
    // 校验 selectedId 仍然有效；若指向已删除账户则回退为空（getSelected 会用 fallback）
    if (this.selectedId.length > 0 && !this.findById(this.selectedId)) {
      AppLogger.warn(TAG, `reload: selectedId ${this.selectedId} no longer exists, clearing`,
        null, LOG_DOMAIN_ACCOUNT);
      this.selectedId = '';
      if (this.storage) this.storage.setSelectedId('');
    }
  }

  /**
   * 反序列化账户记录为具体子类。M1 只支持 OFFLINE；M2 增加 MICROSOFT 分支。
   */
  private deserializeAccount(rec: AccountRecord): Account | null {
    switch (rec.type) {
      case AccountType.OFFLINE:
        return OfflineAccount.fromRecord(rec);
      case AccountType.MICROSOFT:
        // M2 Phase A：明文 JSON ciphertext；Phase B 会改为先 await storage.decrypt(rec.encrypted)
        return MicrosoftAccount.fromRecord(rec);
      case AccountType.AUTHLIB_INJECTOR:
        // M4：第三方皮肤站（authlib-injector / Yggdrasil）。明文 payload（AccountManager
        // 在 reload 时已 decrypt 到 ciphertext），交给 AuthlibInjectorAccount 解析。
        return AuthlibInjectorAccount.fromRecord(rec);
      default:
        AppLogger.warn(TAG, 'deserialize: unknown account type, skipping',
          null, LOG_DOMAIN_ACCOUNT);
        return null;
    }
  }

  // ===== 查询 =====

  list(): Account[] {
    return this.accounts.slice();
  }

  findById(id: string): Account | undefined {
    if (!id || id.length === 0) return undefined;
    for (let acc of this.accounts) {
      if (acc.id === id) return acc;
    }
    return undefined;
  }

  /**
   * 取当前选中账户。永不返回 null：
   *   - 有选中且账户存在 → 返回该账户
   *   - 列表为空或选中无效 → 返回内存 fallback OfflineAccount('MCPlayer')
   */
  getSelected(): Account {
    if (this.selectedId.length > 0) {
      let acc = this.findById(this.selectedId);
      if (acc) return acc;
    }
    // 选中失效或无选中：若列表非空就用第一个，否则用 fallback
    if (this.accounts.length > 0) {
      return this.accounts[0];
    }
    return this.fallback;
  }

  getSelectedId(): string {
    return this.selectedId;
  }

  // ===== 修改 =====

  /**
   * 添加新账户到列表末尾。如果已存在同 id 则覆盖（适用于编辑/刷新）。
   *
   * 异步：MicrosoftAccount.serialize() 返回明文负载（iv/tag 为空的占位），
   * 本方法会调 storage.encrypt() 封装为真实 EncryptedBlob 后才落盘。
   */
  async add(account: Account): Promise<void> {
    if (!this.storage) {
      AppLogger.warn(TAG, 'add: storage not initialized', null, LOG_DOMAIN_ACCOUNT);
      return;
    }
    let existingIdx = -1;
    for (let i = 0; i < this.accounts.length; i++) {
      if (this.accounts[i].id === account.id) {
        existingIdx = i;
        break;
      }
    }
    if (existingIdx >= 0) {
      this.accounts[existingIdx] = account;
    } else {
      this.accounts.push(account);
    }
    let rec = account.serialize();
    // 如果 serialize 返回了明文负载（MicrosoftAccount.serialize 的占位模式），在这里加密
    if (rec.encrypted && rec.encrypted.ciphertext.length > 0
      && rec.encrypted.iv.length === 0 /* 明文标记 */) {
      try {
        rec.encrypted = await this.storage.encrypt(rec.encrypted.ciphertext);
      } catch (e) {
        let msg = (e as Error).message;
        AppLogger.error(TAG, `add: encrypt failed for id=${account.id}`, e as Object, LOG_DOMAIN_ACCOUNT);
        throw new Error('AccountManager.add: encrypt failed: ' + msg);
      }
    }
    this.storage.saveRecord(rec);
    this.persistList();
    AppLogger.info(TAG, `add: id=${account.id} type=${account.type} username=${account.username}`,
      LOG_DOMAIN_ACCOUNT);
  }

  /**
   * 删除账户。如果删的是当前选中，selectedId 清空（getSelected 会回退）。
   */
  remove(id: string): void {
    if (!this.storage) return;
    let next: Account[] = [];
    for (let acc of this.accounts) {
      if (acc.id !== id) next.push(acc);
    }
    this.accounts = next;
    this.storage.removeRecord(id);
    if (this.selectedId === id) {
      this.selectedId = '';
      this.storage.setSelectedId('');
    }
    this.persistList();
    AppLogger.info(TAG, `remove: id=${id}, ${this.accounts.length} remain`, LOG_DOMAIN_ACCOUNT);
  }

  /**
   * 重新写入指定账户的记录（账户内部状态变化后调用，例如 setActiveCape 之后）。
   *
   * 与 `add()` 区别：
   *   - add() 会把账户插入或替换 list 项 + persistList（updates 整个 ids 顺序）
   *   - persistOne() 只做 serialize → encrypt → saveRecord 一条记录，**不动 list 顺序**
   *
   * 适用场景：
   *   - 切换披风后保存最新 capeUrl / capeAlias / ownedCapes
   *   - 刷新令牌后保存最新 mcAccessToken / mcExpiresAt
   *   - 任何"账户已在 list 里、只是内部字段变了"的状态变更
   *
   * 失败抛 Error（encrypt 失败 / 存储 IO 失败），调用方决定是否回滚 UI。
   */
  async persistOne(account: Account): Promise<void> {
    if (!this.storage) return;
    let rec = account.serialize();
    if (rec.encrypted && rec.encrypted.ciphertext.length > 0
      && rec.encrypted.iv.length === 0 /* 明文标记 */) {
      try {
        rec.encrypted = await this.storage.encrypt(rec.encrypted.ciphertext);
      } catch (e) {
        let msg = (e as Error).message;
        AppLogger.error(TAG, `persistOne: encrypt failed for id=${account.id}`, e as Object, LOG_DOMAIN_ACCOUNT);
        throw new Error('AccountManager.persistOne: encrypt failed: ' + msg);
      }
    }
    this.storage.saveRecord(rec);
    AppLogger.info(TAG, `persistOne: id=${account.id} saved`, LOG_DOMAIN_ACCOUNT);
  }

  /**
   * 切换选中账户。id 为空表示"无选中"（getSelected 会用 fallback）。
   */
  select(id: string): void {
    if (!this.storage) return;
    if (id.length > 0 && !this.findById(id)) {
      AppLogger.warn(TAG, `select: id ${id} not found`, null, LOG_DOMAIN_ACCOUNT);
      return;
    }
    this.selectedId = id;
    this.storage.setSelectedId(id);
    AppLogger.info(TAG, `select: id=${id || '<none>'}`, LOG_DOMAIN_ACCOUNT);
  }

  // ===== 内部 =====

  private persistList(): void {
    if (!this.storage) return;
    let ids: string[] = [];
    for (let acc of this.accounts) {
      ids.push(acc.id);
    }
    this.storage.setAccountIds(ids);
  }
}

// ============================================================
//  全局单例
// ============================================================

let _instance: AccountManager | null = null;

export function getAccountManager(): AccountManager {
  if (!_instance) {
    _instance = new AccountManager();
  }
  return _instance;
}

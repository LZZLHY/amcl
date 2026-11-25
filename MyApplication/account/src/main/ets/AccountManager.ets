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
 * 支持离线、微软和第三方账号；离线名称去空格后不分大小写唯一，外观指向应用共享
 * 纹理库。异步新增/编辑串行提交，持久成功后才发布新的不可变离线账号实例。
 *
 * 创建日期：2026-05-09（M1）
 */

import {
  Account,
  AccountType,
  AccountRecord,
  AccountError,
} from './Account';
import { AppearanceAsset, OfflineAppearance, copyOfflineAppearance, offlineAccountNameKey, isAppearanceAssetValid } from './AppearanceTypes';
import { OfflineAccount } from './OfflineAccount';
import { MicrosoftAccount } from './MicrosoftAccount';
import { AuthlibInjectorAccount } from './AuthlibInjectorAccount';
import { AccountStorage } from './AccountStorage';
import { HuksAesGcm256Provider } from './HuksCryptoProvider';

import { AppLogger, ProcessPreferences } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';
import { AppearanceLibrary, getAppearanceLibrary } from './AppearanceLibrary';

const TAG = 'AccountManager';

// ============================================================
//  AccountManager
// ============================================================

export class AccountManager {
  private storage: AccountStorage | null = null;
  /** 仅用于主进程编辑时惰性初始化共享库；独立游戏进程不写库元数据。 */
  private context: Context | null = null;
  private accounts: Account[] = [];
  private selectedId: string = '';
  private _ready: boolean = false;
  private _initPromise: Promise<void> | null = null;
  /** 串行化异步账号写入；一次失败不阻塞下一次重试或另一个账号的编辑。 */
  private mutationTail: Promise<void> = Promise.resolve();
  /** 持久提交期间预留的库引用，防止尚未发布账号实例时条目被另一编辑删除。 */
  private pendingAppearanceIds: Set<string> = new Set<string>();

  /** 默认 fallback 账户（首次启动 / 列表为空时返回）。永不持久化。 */
  private readonly fallback: OfflineAccount = OfflineAccount.create('MCPlayer');

  isReady(): boolean { return this._ready; }

  async init(context: Context): Promise<void> {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._doInit(context);
    return this._initPromise;
  }

  private async _doInit(context: Context): Promise<void> {
    this.context = context;
    this.storage = new AccountStorage(context);
    if (!ProcessPreferences.isGameProcess()) {
      getAppearanceLibrary().setUsageGuard((assetId: string): boolean => this.isAppearanceAssetUsed(assetId));
    }
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
    await this.enqueueMutation(async (): Promise<void> => {
      const storage: AccountStorage = this.requireStorage();
      if (account.type === AccountType.OFFLINE) this.assertOfflineNameAvailable(account.username, account.id);
      const next: Account[] = this.accounts.slice();
      const existingIdx: number = next.findIndex((item: Account): boolean => item.id === account.id);
      if (existingIdx >= 0) next[existingIdx] = account;
      else next.push(account);
      const record: AccountRecord = await this.recordForStorage(account);
      await storage.saveRecordConfirmed(record, next.map((item: Account): string => item.id));
      this.accounts = next;
      AppLogger.info(TAG, `add: id=${account.id} type=${account.type} username=${account.username}`, LOG_DOMAIN_ACCOUNT);
    });
  }

  /**
   * 原子应用离线编辑草稿：名称和皮肤/模型/披风一次保存，避免改名成功而换肤失败。
   * 输入 revision 必须等于编辑开始时的版本；其他编辑已经提交时拒绝覆盖新配置。
   * 名称是去空格、不分大小写的唯一键，ID/UUID 继续代表已有存档身份，不重新派生。
   */
  async editOfflineAccount(id: string, username: string, appearance: OfflineAppearance): Promise<OfflineAccount> {
    let result: OfflineAccount | undefined = undefined;
    const draft: OfflineAppearance = copyOfflineAppearance(appearance);
    const expectedRevision: number = appearance.revision;
    const invalidAsset: boolean = (appearance.skin !== undefined && !isAppearanceAssetValid(appearance.skin, 'skin'))
      || (appearance.cape !== undefined && !isAppearanceAssetValid(appearance.cape, 'cape'));
    const cleanName: string = username.trim();
    await this.enqueueMutation(async (): Promise<void> => {
      const storage: AccountStorage = this.requireStorage();
      if (ProcessPreferences.isGameProcess()) throw new AccountError('READ_ONLY', '请在启动器编辑账号，游戏使用本局只读配置');
      const original: Account | undefined = this.findById(id);
      if (original === undefined || original.type !== AccountType.OFFLINE) {
        throw new AccountError('ACCOUNT_CHANGED', '离线账号已移除或发生变化，请重新打开编辑');
      }
      // 旧版本可能已有同名但 UUID 不同的记录；未真正变更名称时允许各自换肤，
      // 不要求用户先破坏历史身份。只有新增/改到另一个名称才施加重名拒绝。
      this.assertOfflineNameAvailable(cleanName, id,
        offlineAccountNameKey(cleanName) !== offlineAccountNameKey(original.username));
      const offline: OfflineAccount = original as OfflineAccount;
      if (offline.getOfflineAppearance().revision !== expectedRevision) {
        throw new AccountError('ACCOUNT_CHANGED', '账号外观已更新，请重新打开后再修改');
      }
      // 非法输入不能借恢复旧记录的容错逻辑静默清空用户原选择。
      if (invalidAsset) {
        throw new AccountError('INVALID_APPEARANCE', '所选皮肤或披风无效，请重新从库中选择');
      }
      const library: AppearanceLibrary = getAppearanceLibrary();
      if (this.context === null) throw new AccountError('NOT_READY', '账号数据尚未就绪');
      await library.init(this.context);
      if ((draft.skin !== undefined && !library.list('skin').some((asset: AppearanceAsset): boolean =>
        asset.id === draft.skin?.id && asset.sha256 === draft.skin?.sha256))
        || (draft.cape !== undefined && !library.list('cape').some((asset: AppearanceAsset): boolean =>
          asset.id === draft.cape?.id && asset.sha256 === draft.cape?.sha256))) {
        throw new AccountError('INVALID_APPEARANCE', '所选皮肤或披风已从共享库移除，请重新选择');
      }
      draft.revision = offline.getOfflineAppearance().revision + 1;
      const updated: OfflineAccount = offline.withUsername(cleanName).withAppearance(draft);
      if (draft.skin !== undefined) this.pendingAppearanceIds.add(draft.skin.id);
      if (draft.cape !== undefined) this.pendingAppearanceIds.add(draft.cape.id);
      try { await storage.saveRecordConfirmed(updated.serialize()); }
      finally {
        if (draft.skin !== undefined) this.pendingAppearanceIds.delete(draft.skin.id);
        if (draft.cape !== undefined) this.pendingAppearanceIds.delete(draft.cape.id);
      }
      // 所有写入都在同一队列；仍检查原实例，防止外部重载造成跨代发布。
      const index: number = this.accounts.findIndex((item: Account): boolean => item === original);
      if (index < 0) throw new AccountError('ACCOUNT_CHANGED', '账号已移除，本次编辑未应用');
      this.accounts[index] = updated;
      result = updated;
    });
    if (result === undefined) throw new AccountError('ACCOUNT_CHANGED', '无法应用离线账号编辑');
    return result;
  }

  /** 仅改名的便利入口，保留当前外观；编辑器同时修改外观时使用统一 edit 方法。 */
  async renameOffline(id: string, username: string): Promise<OfflineAccount> {
    const account: OfflineAccount = this.requireOffline(id);
    return this.editOfflineAccount(id, username, account.getOfflineAppearance());
  }

  /** 仅更换外观的便利入口；选择相同共享文件不会修改其他账号的模型或选择。 */
  async updateOfflineAppearance(id: string, appearance: OfflineAppearance): Promise<OfflineAccount> {
    return this.editOfflineAccount(id, this.requireOffline(id).username, appearance);
  }

  /** 删除共享库条目前检查所有账号，包含当前未选中的账号，防止留下悬空选择。 */
  isAppearanceAssetUsed(assetId: string): boolean {
    if (this.pendingAppearanceIds.has(assetId)) return true;
    return this.accounts.some((account: Account): boolean => {
      if (account.type !== AccountType.OFFLINE) return false;
      const appearance: OfflineAppearance = (account as OfflineAccount).getOfflineAppearance();
      return appearance.skin?.id === assetId || appearance.cape?.id === assetId;
    });
  }

  /**
   * 删除账户。如果删的是当前选中，selectedId 清空（getSelected 会回退）。
   */
  async remove(id: string, expected?: Account, expectedSelection?: string): Promise<void> {
    await this.enqueueMutation(async (): Promise<void> => {
      // 等待队列时账号可能已被替换；旧确认不能删除新记录。
      if (expected !== undefined && (this.findById(id) !== expected || this.selectedId !== expectedSelection)) {
        throw new Error('账户状态已变化，请重新确认');
      }
      const storage: AccountStorage = this.requireStorage();
      if (this.findById(id) === undefined) return;
      const next: Account[] = this.accounts.filter((account: Account): boolean => account.id !== id);
      const selected: string = this.selectedId === id ? '' : this.selectedId;
      await storage.removeRecordConfirmed(id, next.map((account: Account): string => account.id), selected);
      this.accounts = next;
      this.selectedId = selected;
      AppLogger.info(TAG, `remove: id=${id}, ${this.accounts.length} remain`, LOG_DOMAIN_ACCOUNT);
    });
  }

  /**
   * 重新写入指定账户的记录（账户内部状态变化后调用，例如 setActiveCape 之后）。
   *
   * 与 `add()` 区别：
   *   - add() 会在同次确认提交中插入/替换记录与列表索引
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
    await this.enqueueMutation(async (): Promise<void> => {
      const storage: AccountStorage = this.requireStorage();
      if (this.findById(account.id) !== account) {
        throw new AccountError('ACCOUNT_CHANGED', '账号已移除或更新，旧状态不能覆盖当前记录');
      }
      await storage.saveRecordConfirmed(await this.recordForStorage(account));
      AppLogger.info(TAG, `persistOne: id=${account.id} saved`, LOG_DOMAIN_ACCOUNT);
    });
  }

  /**
   * 切换选中账户。id 为空表示"无选中"（getSelected 会用 fallback）。
   */
  async select(id: string, expected?: Account): Promise<void> {
    await this.enqueueMutation(async (): Promise<void> => {
      const storage: AccountStorage = this.requireStorage();
      const target = this.findById(id);
      // 匿名引用绑定原账号对象。前序编辑可能已提交同 ID 的新对象，需要在实际队列里核查。
      if (id.length > 0 && (!target || (expected !== undefined && target !== expected))) {
        throw new AccountError('ACCOUNT_CHANGED', '账号已移除或替换，请重新选择');
      }
      await storage.setSelectedIdConfirmed(id);
      this.selectedId = id;
      AppLogger.info(TAG, `select: id=${id || '<none>'}`, LOG_DOMAIN_ACCOUNT);
    });
  }

  // ===== 内部 =====

  /** 把失败与后续写入分离；返回给调用方的 Promise 保留本次真实错误。 */
  private enqueueMutation(operation: () => Promise<void>): Promise<void> {
    const pending: Promise<void> = this.mutationTail.then(operation);
    this.mutationTail = pending.catch((): void => {});
    return pending;
  }

  /** 不能在未初始化时假装保存成功；UI 显示错误并保留原配置。 */
  private requireStorage(): AccountStorage {
    if (this.storage === null) throw new AccountError('NOT_READY', '账号数据尚未就绪，请稍后重试');
    return this.storage;
  }

  /** 统一检查离线类型，避免通过离线编辑路径改变正版或第三方账号。 */
  private requireOffline(id: string): OfflineAccount {
    const account: Account | undefined = this.findById(id);
    if (account === undefined || account.type !== AccountType.OFFLINE) {
      throw new AccountError('ACCOUNT_CHANGED', '离线账号不存在，请重新选择');
    }
    return account as OfflineAccount;
  }

  /** 保留旧重复记录的独有 UUID；仅拒绝新创建/改名产生同名，不静默合并存档身份。 */
  private assertOfflineNameAvailable(username: string, exceptId: string, checkDuplicates: boolean = true): void {
    const key: string = offlineAccountNameKey(username);
    if (key.length === 0 || username.length > 64 || new RegExp('[\\x00-\\x1f\\x7f]').test(username)) {
      throw new AccountError('INVALID_NAME', '请输入有效的离线账号名称（1–64 个字符，不含控制字符）');
    }
    if (checkDuplicates && this.accounts.some((account: Account): boolean => account.type === AccountType.OFFLINE
      && account.id !== exceptId && offlineAccountNameKey(account.username) === key)) {
      throw new AccountError('DUPLICATE_NAME', '该名称的离线账号已存在，请选择已有账号或使用其他名称');
    }
  }

  /** 凭据只在本方法中封装，离线记录没有敏感字段，不改变原有加密提供者选择。 */
  private async recordForStorage(account: Account): Promise<AccountRecord> {
    const record: AccountRecord = account.serialize();
    if (record.encrypted && record.encrypted.ciphertext.length > 0 && record.encrypted.iv.length === 0) {
      record.encrypted = await this.requireStorage().encrypt(record.encrypted.ciphertext);
    }
    return record;
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

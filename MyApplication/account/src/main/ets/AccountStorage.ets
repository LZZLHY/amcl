/**
 * AccountStorage.ets — 账户持久化
 *
 * 职责：
 *   - 把 AccountRecord 序列化到 preferences（每个账户一个 key）
 *   - 维护 accounts_list（id 数组）和 selected_account_id
 *   - encrypt / decrypt 委派给注入的 CryptoProvider
 *
 * 加密实现（M2 Phase B）：
 *   - 默认 PlaintextCryptoProvider（构造时）— 允许在 AccountManager 同步调用 storage。
 *   - AccountManager.init() 探测 HUKS 可用 → 调 setCryptoProvider(HuksAesGcm256Provider)。
 *   - HUKS 不可用时（CLI 测试 / 无 SE 模拟器）— 仍用明文 provider 免账户系统瓦解。
 *
 * 详见 docs/guides/genuine-login-and-account-system-plan.md §9
 *
 * 创建日期：2026-05-09（M1）、M2 Phase B 接入 CryptoProvider
 */

import { ProcessPreferences, LaunchPreferenceStore } from 'commons';
import {
  AccountRecord,
  EncryptedBlob,
  AccountError,
  ACCOUNT_ERR_INVALID_RECORD,
} from './Account';
import { CryptoProvider, PlaintextCryptoProvider } from './CryptoProvider';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'AccountStorage';
const PREF_NAME = 'amcl_accounts';

const KEY_LIST = 'accounts_list';
const KEY_SELECTED = 'selected_account_id';
const KEY_RECORD_PREFIX = 'account_';

/** 一次账号事务中的键更新；缺失value表示删除，所有键共用一次确认提交。 */
interface ConfirmedAccountPreferenceChange { key: string; value?: string; }
/** 只用于读取缺失状态，不写入Preferences，区分原来为空与原来不存在。 */
const ABSENT_VALUE: string = '\u0000amcl-account-missing\u0000';

// ============================================================
//  AccountStorage（实例化方式）
// ============================================================

export class AccountStorage {
  private pref: LaunchPreferenceStore;
  private crypto: CryptoProvider;

  constructor(context: Context, crypto?: CryptoProvider) {
    this.pref = ProcessPreferences.open(context, PREF_NAME);
    // 默认 PlaintextCryptoProvider；AccountManager.init() 探测后会换 HUKS
    this.crypto = crypto !== undefined ? crypto : new PlaintextCryptoProvider();
  }

  /** AccountManager 在 init() 探测到 HUKS 可用后调用。 */
  setCryptoProvider(provider: CryptoProvider): void {
    this.crypto = provider;
    AppLogger.info(TAG, `cryptoProvider switched to ${provider.constructor.name}`, LOG_DOMAIN_ACCOUNT);
  }

  /** 测试专用：查看当前 provider 。 */
  getCryptoProvider(): CryptoProvider {
    return this.crypto;
  }

  // ===== 列表 / 选中 =====

  getAccountIds(): string[] {
    let raw = '';
    try {
      raw = this.pref.getSync(KEY_LIST, '') as string;
    } catch (e) {
      AppLogger.warn(TAG, 'getAccountIds: pref.getSync failed', e as Object, LOG_DOMAIN_ACCOUNT);
      return [];
    }
    if (!raw || raw.length === 0) {
      return [];
    }
    try {
      let arr = JSON.parse(raw) as string[];
      if (!Array.isArray(arr)) {
        return [];
      }
      return arr.filter((s: string) => typeof s === 'string' && s.length > 0);
    } catch (e) {
      AppLogger.warn(TAG, 'getAccountIds: parse failed, returning empty', e as Object, LOG_DOMAIN_ACCOUNT);
      return [];
    }
  }

  setAccountIds(ids: string[]): void {
    try {
      this.pref.putSync(KEY_LIST, JSON.stringify(ids));
      this.pref.flush();
    } catch (e) {
      AppLogger.warn(TAG, 'setAccountIds failed', e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  getSelectedId(): string {
    try {
      return this.pref.getSync(KEY_SELECTED, '') as string;
    } catch (e) {
      AppLogger.warn(TAG, 'getSelectedId failed', e as Object, LOG_DOMAIN_ACCOUNT);
      return '';
    }
  }

  setSelectedId(id: string): void {
    try {
      this.pref.putSync(KEY_SELECTED, id);
      this.pref.flush();
    } catch (e) {
      AppLogger.warn(TAG, 'setSelectedId failed', e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  // ===== 单个账户记录 =====

  loadRecord(id: string): AccountRecord | null {
    if (!id || id.length === 0) {
      return null;
    }
    let raw = '';
    try {
      raw = this.pref.getSync(KEY_RECORD_PREFIX + id, '') as string;
    } catch (e) {
      AppLogger.warn(TAG, `loadRecord ${id}: pref.getSync failed`, e as Object, LOG_DOMAIN_ACCOUNT);
      return null;
    }
    if (!raw || raw.length === 0) {
      return null;
    }
    try {
      let rec = JSON.parse(raw) as AccountRecord;
      if (!rec || typeof rec.id !== 'string' || rec.id !== id) {
        AppLogger.warn(TAG, `loadRecord ${id}: id mismatch or invalid`, null, LOG_DOMAIN_ACCOUNT);
        return null;
      }
      return rec;
    } catch (e) {
      AppLogger.warn(TAG, `loadRecord ${id}: parse failed`, e as Object, LOG_DOMAIN_ACCOUNT);
      return null;
    }
  }

  saveRecord(rec: AccountRecord): void {
    if (!rec || !rec.id || rec.id.length === 0) {
      throw new AccountError(ACCOUNT_ERR_INVALID_RECORD, 'AccountRecord 缺少 id');
    }
    try {
      this.pref.putSync(KEY_RECORD_PREFIX + rec.id, JSON.stringify(rec));
      this.pref.flush();
    } catch (e) {
      AppLogger.warn(TAG, `saveRecord ${rec.id} failed`, e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  /**
   * 确认单个账号及可选列表索引已持久提交。
   *
   * 名称/外观编辑必须等 flush 成功后才能发布新内存实例；添加账号将记录和索引放
   * 在同一份 Preferences 提交，避免文件已导入却显示保存成功的假象。失败时恢复
   * 旧缓存，并尽力持久恢复；恢复失败单独记警告，原始失败始终上抛供界面保留草稿。
   * 游戏进程的只读快照会拒绝 put，调用方不得在 child 路径调用此方法。
   */
  async saveRecordConfirmed(rec: AccountRecord, accountIds?: string[]): Promise<void> {
    if (!rec || !rec.id || rec.id.length === 0) {
      throw new AccountError(ACCOUNT_ERR_INVALID_RECORD, 'AccountRecord 缺少 id');
    }
    const changes: ConfirmedAccountPreferenceChange[] = [{ key: KEY_RECORD_PREFIX + rec.id, value: JSON.stringify(rec) }];
    if (accountIds !== undefined) changes.push({ key: KEY_LIST, value: JSON.stringify(accountIds) });
    await this.commitConfirmed(changes);
  }

  /** 删除记录、列表及选中态一次确认，防止新增/删除交错使旧账号复活。 */
  async removeRecordConfirmed(id: string, accountIds: string[], selectedId: string): Promise<void> {
    await this.commitConfirmed([{ key: KEY_RECORD_PREFIX + id },
      { key: KEY_LIST, value: JSON.stringify(accountIds) }, { key: KEY_SELECTED, value: selectedId }]);
  }

  /** 切换账号同样进入Manager写队列，避免失败回滚或删除覆盖用户的新选中态。 */
  async setSelectedIdConfirmed(id: string): Promise<void> {
    await this.commitConfirmed([{ key: KEY_SELECTED, value: id }]);
  }

  /** 确认事务共用的提交/精确缓存回滚；调用者保证同一个Manager内写操作串行。 */
  private async commitConfirmed(changes: ConfirmedAccountPreferenceChange[]): Promise<void> {
    const previous: ConfirmedAccountPreferenceChange[] = changes.map((change: ConfirmedAccountPreferenceChange): ConfirmedAccountPreferenceChange => {
      const value: string = this.pref.getSync(change.key, ABSENT_VALUE) as string;
      return value === ABSENT_VALUE ? { key: change.key } : { key: change.key, value: value };
    });
    try {
      for (const change of changes) {
        if (change.value === undefined) this.pref.deleteSync(change.key);
        else this.pref.putSync(change.key, change.value);
      }
      await this.pref.flush();
    } catch (error) {
      try {
        for (const change of previous) {
          if (change.value === undefined) this.pref.deleteSync(change.key);
          else this.pref.putSync(change.key, change.value);
        }
        await this.pref.flush();
      } catch (rollbackError) {
        AppLogger.warn(TAG, '账号保存失败后恢复原记录失败', rollbackError as Object, LOG_DOMAIN_ACCOUNT);
      }
      AppLogger.warn(TAG, '账号持久提交失败，保留原内存状态', error as Object, LOG_DOMAIN_ACCOUNT);
      throw new AccountError('STORAGE', '账号保存失败，请重试；原账号设置未在界面中替换');
    }
  }

  removeRecord(id: string): void {
    if (!id || id.length === 0) return;
    try {
      this.pref.deleteSync(KEY_RECORD_PREFIX + id);
      this.pref.flush();
    } catch (e) {
      AppLogger.warn(TAG, `removeRecord ${id} failed`, e as Object, LOG_DOMAIN_ACCOUNT);
    }
  }

  // ===== 加解密接口（委派 CryptoProvider） =====

  /** 明文 → EncryptedBlob（包括 iv / ciphertext / tag）。失败招错。 */
  async encrypt(plaintext: string): Promise<EncryptedBlob> {
    return this.crypto.encrypt(plaintext);
  }

  /** EncryptedBlob → 明文。失败（tag 校验不过 / 密钥丢失）招错。 */
  async decrypt(blob: EncryptedBlob): Promise<string> {
    return this.crypto.decrypt(blob);
  }
}

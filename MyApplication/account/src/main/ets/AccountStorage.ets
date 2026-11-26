/**
 * AccountStorage.ets — 账户持久化
 *
 * 职责：
 *   - 把 AccountRecord 序列化到 preferences（每个账户一个 key）
 *   - 维护 accounts_list（id 数组）和 selected_account_id
 *   - encrypt / decrypt 委派给注入的 CryptoProvider
 *
 * 生产凭据始终使用 HUKS。旧版明文只由启动器在确认加密并保存后恢复；游戏进程只读。
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
import { HuksAesGcm256Provider } from './HuksCryptoProvider';

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
    // 服务暂时不可用时让敏感操作失败，离线账号不依赖密钥服务。
    this.crypto = crypto !== undefined ? crypto : new HuksAesGcm256Provider();
  }

  /** 显式注入提供者供宿主测试使用，生产初始化保留同一个 HUKS 实例。 */
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
    // 旧索引中的空项或其他无效项不影响使用可辨认的账号。
    const ids: string[] = [];
    for (const item of this.getAccountIndexEntries()) {
      if (typeof item === 'string' && item.length > 0) ids.push(item);
    }
    return ids;
  }

  /** 增删只改指定 ID，原样带回未识别项，无法读取整份索引时停止写入。 */
  getAccountIndexEntries(): Object[] {
    let raw = '';
    try {
      raw = this.pref.getSync(KEY_LIST, '') as string;
    } catch (e) {
      AppLogger.warn(TAG, 'getAccountIds: pref.getSync failed', e as Object, LOG_DOMAIN_ACCOUNT);
      throw new AccountError('STORAGE', '账号索引暂不可读，请重试');
    }
    if (!raw || raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as Object[];
      if (!Array.isArray(arr)) throw new Error('无效的账号索引');
      return arr;
    } catch (e) {
      AppLogger.warn(TAG, '账号索引格式无效，保留原值', null, LOG_DOMAIN_ACCOUNT);
      throw new AccountError('STORAGE', '账号索引暂不可读，请重试');
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
      throw new AccountError('STORAGE', '当前账号选择暂不可读，请重试');
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
      throw new AccountError('STORAGE', '账号记录暂不可读，请重试');
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
  async saveRecordConfirmed(rec: AccountRecord, accountIds?: Object[]): Promise<void> {
    if (!rec || !rec.id || rec.id.length === 0) {
      throw new AccountError(ACCOUNT_ERR_INVALID_RECORD, 'AccountRecord 缺少 id');
    }
    const changes: ConfirmedAccountPreferenceChange[] = [{ key: KEY_RECORD_PREFIX + rec.id, value: JSON.stringify(rec) }];
    if (accountIds !== undefined) changes.push({ key: KEY_LIST, value: JSON.stringify(accountIds) });
    await this.commitConfirmed(changes);
  }

  /** 删除记录、列表及选中态一次确认，防止新增/删除交错使旧账号复活。 */
  async removeRecordConfirmed(id: string, accountIds: Object[], selectedId: string): Promise<void> {
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

  /** 有历史密文或不可读记录时，只允许使用原密钥。首次保存和仅含旧明文时允许创建。 */
  async encrypt(plaintext: string): Promise<EncryptedBlob> {
    try {
      // 已有密钥时直接使用。仅在可能生成新密钥时核对旧记录，避免每次刷新都遍历所有账号。
      if (this.crypto instanceof HuksAesGcm256Provider && await this.crypto.hasExistingKey()) {
        return await this.crypto.encrypt(plaintext, false);
      }
      const canCreate = this.getAccountIds().every((id: string): boolean => {
        const record = this.loadRecord(id);
        // 旧索引可留有已不存在的记录。缺键没有密文可丢，已有但读不清的字节仍保护旧密钥。
        if (record === null) return this.pref.getSync(KEY_RECORD_PREFIX + id, ABSENT_VALUE) === ABSENT_VALUE;
        return !record.encrypted || this.isLegacyPlaintext(record.encrypted);
      });
      return await this.crypto.encrypt(plaintext, canCreate);
    }
    catch (_) { throw new AccountError('KEY_UNAVAILABLE', '系统密钥暂不可用，账号凭据未保存，请重试'); }
  }

  /** 只识别原明文提供者明确写出的格式；坏密文不能降级为明文解析。 */
  private isLegacyPlaintext(blob: EncryptedBlob): boolean {
    return blob.iv === PlaintextCryptoProvider.MARKER_IV && blob.tag === '';
  }

  /** 旧记录只在启动器确认迁移成功后交付给账号对象。失败由索引持有者保留并重试。 */
  async readCredentials(record: AccountRecord, blob: EncryptedBlob): Promise<string> {
    if (!this.isLegacyPlaintext(blob)) return await this.decrypt(blob);
    if (ProcessPreferences.isGameProcess()) throw new AccountError('READ_ONLY', '请先回启动器恢复旧账号');
    record.encrypted = await this.encrypt(blob.ciphertext);
    await this.saveRecordConfirmed(record);
    return blob.ciphertext;
  }

  /** EncryptedBlob → 明文。失败（tag 校验不过 / 密钥丢失）招错。 */
  async decrypt(blob: EncryptedBlob): Promise<string> {
    return this.crypto.decrypt(blob);
  }
}

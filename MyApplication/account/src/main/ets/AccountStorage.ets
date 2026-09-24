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

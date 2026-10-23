/**
 * HuksCryptoProvider.ets — 真 HUKS AES-GCM-256 实现
 *
 * 算法：AES-256-GCM
 *   - 密钥：HUKS 系统密钥库托管，alias = 'amcl_account_master_v1'，永不出芯片
 *   - IV / NONCE：12 字节随机（每次加密一次），随密文一起持久化
 *   - 认证标签：16 字节，HUKS finishSession 输出 ciphertext || tag
 *   - 失败语义：tag 校验失败 → decrypt 抛错；调用方应丢弃该账户记录
 *
 * 密钥生命周期：查询异常不代表不存在；创建明确禁止覆写同alias，进程内初始化串行。
 * 解密只使用已存在的密钥，不能用新密钥伪装修复旧密文。签名域不采用明文兜底。
 * isAvailable保留旧账户接口，暂态失败返回false但不永久缓存，后续可以重新核实。
 *
 * 创建日期：2026-05-09（M2 Phase B）
 */

import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { EncryptedBlob } from './Account';
import { CryptoProvider } from './CryptoProvider';
import {
  encodeStandardBase64,
  decodeStandardBase64,
  stringToUtf8,
  utf8ToString,
} from 'commons';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'HuksCryptoProvider';

// ============================================================
//  常量
// ============================================================

const KEY_ALIAS = 'amcl_account_master_v1';
const NONCE_BYTES = 12;
const TAG_BYTES = 16;

// ============================================================
//  Provider
// ============================================================

export class HuksAesGcm256Provider implements CryptoProvider {
  /** 相同alias的并发首次初始化共用执行者；系统禁止覆写参数另覆盖跨进程竞态。 */
  private static initializing: Map<string, Promise<boolean>> = new Map<string, Promise<boolean>>();
  private _availableCache: boolean | null = null;
  private keyAlias_: string;

  /** 默认继续使用账户原密钥；同应用其他敏感域可显式采用独立固定alias，避免生命周期耦合。 */
  constructor(keyAlias: string = KEY_ALIAS) {
    if (!new RegExp('^amcl_[a-zA-Z0-9_]{1,64}$').test(keyAlias)) throw new Error('Invalid HUKS namespace');
    this.keyAlias_ = keyAlias;
  }

  /**
   * 探测 HUKS 可用性。
   * 保留账户CryptoProvider的布尔探测接口；只缓存已核实可用，不缓存暂态失败。
   * 新密钥只能在hasKeyItem明确返回false后创建，RPC/权限错误直接终止本次探测。
   */
  async isAvailable(): Promise<boolean> {
    try {
      return await this.ensureKey(true);
    } catch (e) {
      AppLogger.warn(TAG, 'HUKS暂不可用，保留原密钥并等待重新核实', null, LOG_DOMAIN_ACCOUNT);
      this._availableCache = null;
      return false;
    }
  }

  /** 仅查询现有密钥，用于有历史密文的Vault；查询错误仍传播，不能触发生成。 */
  async hasExistingKey(): Promise<boolean> {
    const exists = await this.hasKey();
    this._availableCache = exists ? true : null;
    return exists;
  }

  /** 初始化只在明确许可时创建；调用方可通过allowCreate=false保护已经存在的历史密文。 */
  private async ensureKey(allowCreate: boolean): Promise<boolean> {
    if (this._availableCache === true) return true;
    if (await this.hasKey()) { this._availableCache = true; return true; }
    if (!allowCreate) return false;
    let pending = HuksAesGcm256Provider.initializing.get(this.keyAlias_);
    if (pending === undefined) {
      pending = this.createMissingKey();
      HuksAesGcm256Provider.initializing.set(this.keyAlias_, pending);
    }
    const owner = pending;
    try {
      const available = await owner;
      if (available) this._availableCache = true;
      return available;
    } finally {
      if (HuksAesGcm256Provider.initializing.get(this.keyAlias_) === owner) {
        HuksAesGcm256Provider.initializing.delete(this.keyAlias_);
      }
    }
  }

  /** 二次确认缺失后创建，不覆写选项保证另一个进程先创建也不会破坏它的密钥。 */
  private async createMissingKey(): Promise<boolean> {
    if (await this.hasKey()) return true;
    try { await this.generateKey(); }
    catch (error) {
      // 其他进程可能先完成创建；只有新的真实存在性查询成功才允许使用，不能吞普通生成失败。
      if (await this.hasKey()) return true;
      throw error as Error;
    }
    return await this.hasKey();
  }

  // 2026-05-23 ArkTS 严格模式：huks.initSession / finishSession / generateKeyItem /
  // cryptoFramework.createRandom / generateRandomSync 都会报 'Function may throw'。
  // 本文件在几个必须拋到调用方的点按下面模式包 try-catch + AppLogger
  // + rethrow，保持原有错误传播。详见 docs/guides/api-migration-2026-05.md。
  async encrypt(plaintext: string, allowCreate: boolean = true): Promise<EncryptedBlob> {
    if (!(await this.ensureKey(allowCreate))) {
      throw new Error('HuksAesGcm256Provider.encrypt: HUKS unavailable');
    }
    let nonce = generateNonce();
    let inData = stringToUtf8(plaintext);
    let opts: huks.HuksOptions = {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
        { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      ],
      inData: inData,
    };
    let session: huks.HuksSessionHandle | undefined = undefined;
    let result: huks.HuksReturnResult;
    try {
      session = await huks.initSession(this.keyAlias_, opts);
      result = await huks.finishSession(session.handle, opts);
    } catch (e) {
      this._availableCache = null;
      await this.abortFailedSession(session, opts);
      AppLogger.warn(TAG, 'HUKS加密会话失败，原密钥保留', null, LOG_DOMAIN_ACCOUNT);
      throw e as Error;
    }
    let outData = (result.outData as Uint8Array | undefined);
    if (!outData || outData.length < TAG_BYTES) {
      throw new Error('HuksAesGcm256Provider.encrypt: outData missing or too short');
    }
    // HUKS GCM 输出：ciphertext || tag（tag 长度 16 字节）
    let ct = outData.subarray(0, outData.length - TAG_BYTES);
    let tag = outData.subarray(outData.length - TAG_BYTES);
    return {
      iv: encodeStandardBase64(nonce),
      ciphertext: encodeStandardBase64(ct),
      tag: encodeStandardBase64(tag),
    };
  }

  async decrypt(blob: EncryptedBlob): Promise<string> {
    if (!(await this.hasExistingKey())) {
      throw new Error('加密记录的原密钥不存在，请恢复原配置；不能重新生成密钥解密');
    }
    let nonce = decodeStandardBase64(blob.iv);
    let ct = decodeStandardBase64(blob.ciphertext);
    let tag = decodeStandardBase64(blob.tag);
    if (nonce.length !== NONCE_BYTES) {
      throw new Error('HuksAesGcm256Provider.decrypt: nonce length must be 12, got '
        + nonce.length);
    }
    if (tag.length !== TAG_BYTES) {
      throw new Error('HuksAesGcm256Provider.decrypt: tag length must be 16, got ' + tag.length);
    }
    // HUKS GCM 解密：inData = ciphertext，AE_TAG 单独传
    let opts: huks.HuksOptions = {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
        { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
        { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag },
      ],
      inData: ct,
    };
    let session: huks.HuksSessionHandle | undefined = undefined;
    let result: huks.HuksReturnResult;
    try {
      session = await huks.initSession(this.keyAlias_, opts);
      result = await huks.finishSession(session.handle, opts);
    } catch (e) {
      this._availableCache = null;
      await this.abortFailedSession(session, opts);
      AppLogger.warn(TAG, 'HUKS解密会话失败，保留原密文和密钥', null, LOG_DOMAIN_ACCOUNT);
      throw e as Error;
    }
    let outData = (result.outData as Uint8Array | undefined);
    if (!outData) {
      throw new Error('HuksAesGcm256Provider.decrypt: outData missing');
    }
    return utf8ToString(outData);
  }

  // ============================================================
  //  内部
  // ============================================================

  /**
   * 探测主密钥是否已存在。
   * @throws HUKS查询的RPC/权限错误原样传播，不把失败解释为缺少密钥。
   */
  private async hasKey(): Promise<boolean> {
    let opts: huks.HuksOptions = { properties: [] };
    return await huks.hasKeyItem(this.keyAlias_, opts);
  }

  /** finish失败后尽力回收仍存活的handle；已由系统结束的会话拒绝abort时不覆盖原始错误。 */
  private async abortFailedSession(session: huks.HuksSessionHandle | undefined, opts: huks.HuksOptions): Promise<void> {
    if (session === undefined) return;
    try { await huks.abortSession(session.handle, opts); }
    catch (_) { /* 原失败由encrypt/decrypt传播，不打印含敏感参数的SDK异常对象。 */ }
  }

  /** 生成 AES-256 主密钥，限制只能用于 ENCRYPT/DECRYPT，绑定 GCM。 */
  private async generateKey(): Promise<void> {
    let opts: huks.HuksOptions = {
      properties: [
        // API20起可用，当前通用/desktop最低API覆盖。禁止系统默认覆写同名密钥。
        { tag: huks.HuksTag.HUKS_TAG_KEY_OVERRIDE, value: false },
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT
            | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
        },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
      ],
    };
    try {
      await huks.generateKeyItem(this.keyAlias_, opts);
    } catch (e) {
      AppLogger.error(TAG, 'HUKS新密钥创建失败，未覆盖现有alias', null, LOG_DOMAIN_ACCOUNT);
      throw e as Error;
    }
    AppLogger.info(TAG, `generated master key alias=${this.keyAlias_}`, LOG_DOMAIN_ACCOUNT);
  }
}

// ============================================================
//  辅助：生成 12 字节加密强随机 nonce
// ============================================================

function generateNonce(): Uint8Array {
  // CryptoArchitectureKit 在真机上是真随机；CLI 测试上可能返回空 buffer，
  // 但 CLI 测试不会走到 HUKS path（isAvailable 已先返回 false 兜底）
  // 2026-05-23 ArkTS 严格模式：createRandom / generateRandomSync 会报
  // 'Function may throw'。包 try-catch + rethrow 保留语义（caller .encrypt
  // 一定会感知到失败）。详见 docs/guides/api-migration-2026-05.md。
  let rng: cryptoFramework.Random;
  let blob: cryptoFramework.DataBlob;
  try {
    rng = cryptoFramework.createRandom();
    blob = rng.generateRandomSync(NONCE_BYTES);
  } catch (e) {
    AppLogger.warn(TAG, 'generateNonce: createRandom failed', e as Object, LOG_DOMAIN_ACCOUNT);
    throw e as Error;
  }
  if (!blob || !blob.data || blob.data.length !== NONCE_BYTES) {
    throw new Error('generateNonce: cryptoFramework.createRandom returned invalid buffer');
  }
  return new Uint8Array(blob.data);
}

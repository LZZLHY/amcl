/**
 * HuksCryptoProvider.ets — 真 HUKS AES-GCM-256 实现
 *
 * 算法：AES-256-GCM
 *   - 密钥：HUKS 系统密钥库托管，alias = 'amcl_account_master_v1'，永不出芯片
 *   - IV / NONCE：12 字节随机（每次加密一次），随密文一起持久化
 *   - 认证标签：16 字节，HUKS finishSession 输出 ciphertext || tag
 *   - 失败语义：tag 校验失败 → decrypt 抛错；调用方应丢弃该账户记录
 *
 * 兜底策略：
 *   - isAvailable() 探测一次（生成/查询密钥），失败返回 false
 *   - CLI 测试 / 模拟器无 SE 环境下 isAvailable() 应返回 false，调用方应换 PlaintextCryptoProvider
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
const AES_256_BITS = 256;

// ============================================================
//  Provider
// ============================================================

export class HuksAesGcm256Provider implements CryptoProvider {
  private _availableCache: boolean | null = null;

  /**
   * 探测 HUKS 可用性。
   * 流程：尝试 hasKeyItem(KEY_ALIAS)；若不存在则 generateKeyItem。任何环节抛错即不可用。
   * 结果缓存（同进程内不再探测）。
   */
  async isAvailable(): Promise<boolean> {
    if (this._availableCache !== null) return this._availableCache;
    try {
      let exists = await this.hasKey();
      if (!exists) {
        await this.generateKey();
      }
      this._availableCache = true;
      AppLogger.info(TAG, `HUKS available; key alias=${KEY_ALIAS}`, LOG_DOMAIN_ACCOUNT);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, 'HUKS unavailable', e as Object, LOG_DOMAIN_ACCOUNT);
      this._availableCache = false;
      return false;
    }
  }

  // 2026-05-23 ArkTS 严格模式：huks.initSession / finishSession / generateKeyItem /
  // cryptoFramework.createRandom / generateRandomSync 都会报 'Function may throw'。
  // 本文件在几个必须拋到调用方的点按下面模式包 try-catch + AppLogger
  // + rethrow，保持原有错误传播。详见 docs/guides/api-migration-2026-05.md。
  async encrypt(plaintext: string): Promise<EncryptedBlob> {
    if (!(await this.isAvailable())) {
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
    let session: huks.HuksSessionHandle;
    let result: huks.HuksReturnResult;
    try {
      session = await huks.initSession(KEY_ALIAS, opts);
      result = await huks.finishSession(session.handle, opts);
    } catch (e) {
      AppLogger.warn(TAG, 'encrypt: HUKS session failed', e as Object, LOG_DOMAIN_ACCOUNT);
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
    if (!(await this.isAvailable())) {
      throw new Error('HuksAesGcm256Provider.decrypt: HUKS unavailable');
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
    let session: huks.HuksSessionHandle;
    let result: huks.HuksReturnResult;
    try {
      session = await huks.initSession(KEY_ALIAS, opts);
      result = await huks.finishSession(session.handle, opts);
    } catch (e) {
      AppLogger.warn(TAG, 'decrypt: HUKS session failed', e as Object, LOG_DOMAIN_ACCOUNT);
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

  /** 探测主密钥是否已存在。 */
  private async hasKey(): Promise<boolean> {
    let opts: huks.HuksOptions = { properties: [] };
    try {
      return await huks.hasKeyItem(KEY_ALIAS, opts);
    } catch (e) {
      // hasKeyItem 在某些版本上对不存在的 key 也抛错；视为"不存在"
      return false;
    }
  }

  /** 生成 AES-256 主密钥，限制只能用于 ENCRYPT/DECRYPT，绑定 GCM。 */
  private async generateKey(): Promise<void> {
    let opts: huks.HuksOptions = {
      properties: [
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
      await huks.generateKeyItem(KEY_ALIAS, opts);
    } catch (e) {
      AppLogger.error(TAG, 'generateKeyItem failed', e as Object, LOG_DOMAIN_ACCOUNT);
      throw e as Error;
    }
    AppLogger.info(TAG, `generated master key alias=${KEY_ALIAS}`, LOG_DOMAIN_ACCOUNT);
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

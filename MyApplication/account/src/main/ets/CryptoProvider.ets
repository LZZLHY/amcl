/**
 * CryptoProvider.ets — 账户敏感字段加密抽象
 *
 * 抽象出"明文 → 加密 blob"操作，使 AccountStorage / AccountManager 不直接耦合 HUKS。
 * 注入风格便于测试（PlaintextCryptoProvider）和未来替换算法。
 *
 * 实现：
 *   - PlaintextCryptoProvider : 仅供显式测试，保留旧版明文记录标记用于迁移。
 *   - HuksAesGcm256Provider   : 真 HUKS AES-GCM-256（生产路径，见 HuksCryptoProvider.ets）
 *
 * 创建日期：2026-05-09（M2 Phase B）
 */

import { EncryptedBlob } from './Account';

/**
 * 加密 / 解密提供者契约。
 *
 * 调用约束：
 *   - encrypt(plaintext) 必须返回 iv 非空的 EncryptedBlob（用于解密时识别）
 *   - decrypt(blob) 抛错时调用方保留原记录，稍后可重试。
 */
export interface CryptoProvider {
  /** 是否可用。HUKS provider 在 CLI 测试 / 模拟器无 SE 环境下返回 false。 */
  isAvailable(): Promise<boolean>;

  /** 明文（UTF-8）→ EncryptedBlob。失败抛错。 */
  encrypt(plaintext: string, allowCreate?: boolean): Promise<EncryptedBlob>;

  /** EncryptedBlob → 明文（UTF-8）。失败（密钥失效 / tag 校验失败）抛错。 */
  decrypt(blob: EncryptedBlob): Promise<string>;
}

// ============================================================
//  PlaintextCryptoProvider — 透传实现（仅测试）
// ============================================================

/**
 * 不加密的占位实现。**严禁在生产环境直接使用**。
 *
 * 显式测试可以选择此实现。旧客户端曾用同一格式持久化；
 * 生产读取只认标记和空 tag，确认加密提交后才恢复账号。
 */
export class PlaintextCryptoProvider implements CryptoProvider {
  static readonly MARKER_IV = 'PLAINTEXT_V1';

  async isAvailable(): Promise<boolean> {
    return true;
  }

  async encrypt(plaintext: string): Promise<EncryptedBlob> {
    return {
      iv: PlaintextCryptoProvider.MARKER_IV,
      ciphertext: plaintext,
      tag: '',
    };
  }

  async decrypt(blob: EncryptedBlob): Promise<string> {
    if (blob.iv !== PlaintextCryptoProvider.MARKER_IV) {
      throw new Error('PlaintextCryptoProvider: blob iv marker mismatch (got "' + blob.iv + '")');
    }
    return blob.ciphertext;
  }
}

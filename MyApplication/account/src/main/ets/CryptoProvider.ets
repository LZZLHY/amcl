/**
 * CryptoProvider.ets — 账户敏感字段加密抽象
 *
 * 抽象出"明文 → 加密 blob"操作，使 AccountStorage / AccountManager 不直接耦合 HUKS。
 * 注入风格便于测试（PlaintextCryptoProvider）和未来替换算法。
 *
 * 实现：
 *   - PlaintextCryptoProvider : 透传（仅测试 / HUKS 不可用兜底，**不安全**）
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
 *   - decrypt(blob) 抛错表示密钥失效 / 数据损坏，调用方应丢弃该账户记录
 */
export interface CryptoProvider {
  /** 是否可用。HUKS provider 在 CLI 测试 / 模拟器无 SE 环境下返回 false。 */
  isAvailable(): Promise<boolean>;

  /** 明文（UTF-8）→ EncryptedBlob。失败抛错。 */
  encrypt(plaintext: string): Promise<EncryptedBlob>;

  /** EncryptedBlob → 明文（UTF-8）。失败（密钥失效 / tag 校验失败）抛错。 */
  decrypt(blob: EncryptedBlob): Promise<string>;
}

// ============================================================
//  PlaintextCryptoProvider — 透传实现（**仅测试 / 兜底**）
// ============================================================

/**
 * 不加密的占位实现。**严禁在生产环境直接使用**。
 *
 * 用途：
 *   1. CLI 单元测试（HUKS 不可用）
 *   2. 真 HUKS provider 初始化失败时的最后兜底（避免账户系统完全瘫痪）
 *
 * 标记：iv = "PLAINTEXT_V1"，tag = ""。AccountManager 在加载时若看到此标记，
 * 应立即触发"重新加密"以回到正常 HUKS 路径（M3 任务）。
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

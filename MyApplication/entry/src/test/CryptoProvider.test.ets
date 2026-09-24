/**
 * CryptoProvider.test.ets — PlaintextCryptoProvider 单元测试
 *
 * 覆盖：
 *   - isAvailable() = true
 *   - encrypt + decrypt 往返保留原文
 *   - encrypt 输出含 MARKER_IV 标记（用于 AccountManager 识别明文路径）
 *   - decrypt 拒绝非 MARKER_IV 的 blob（防混淆）
 *
 * HuksAesGcm256Provider 的真功测试要在真机上跑（CLI 测试只能验证 isAvailable() = false）。
 *
 * 创建日期：2026-05-09（M2 Phase B）
 */

import { describe, it, expect } from '@ohos/hypium';
import { EncryptedBlob } from 'account';
import { PlaintextCryptoProvider } from 'account';

export default function cryptoProviderTest() {

  describe('PlaintextCryptoProvider', () => {
    it('isAvailable → true', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let r = await p.isAvailable();
      expect(r).assertTrue();
    });

    it('encrypt 输出 iv = MARKER_IV、ciphertext = plaintext', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let blob = await p.encrypt('hello');
      expect(blob.iv).assertEqual(PlaintextCryptoProvider.MARKER_IV);
      expect(blob.ciphertext).assertEqual('hello');
      expect(blob.tag).assertEqual('');
    });

    it('encrypt → decrypt 往返保留原文', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let original = '{"refreshToken":"M.R3_BAY.xyz","mcAccessToken":"eyJ.A","mcExpiresAt":123}';
      let blob = await p.encrypt(original);
      let back = await p.decrypt(blob);
      expect(back).assertEqual(original);
    });

    it('decrypt 拒绝非 MARKER_IV 的 blob（防与 HUKS 输出混淆）', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let foreign: EncryptedBlob = { iv: 'real_huks_iv', ciphertext: 'cipher', tag: 'tag' };
      let caught: Error | null = null;
      try {
        await p.decrypt(foreign);
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== null).assertTrue();
      expect((caught as Error).message.indexOf('marker mismatch') >= 0).assertTrue();
    });

    it('空串明文 encrypt/decrypt', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let blob = await p.encrypt('');
      let back = await p.decrypt(blob);
      expect(back).assertEqual('');
    });

    it('Unicode/emoji 明文往返', 0, async () => {
      let p = new PlaintextCryptoProvider();
      let original = 'AMCL 🎮 启动器';
      let back = await p.decrypt(await p.encrypt(original));
      expect(back).assertEqual(original);
    });
  });
}

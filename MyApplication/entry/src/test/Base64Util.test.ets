/**
 * Base64Util.test.ets — 共享 base64 / utf8 工具测试
 *
 * 覆盖：
 *   - encodeStandardBase64 / decodeStandardBase64：标准 + URL-safe 容错
 *   - base64UrlNoPad：去 padding、+/_ 替换
 *   - stringToUtf8 / utf8ToString：ASCII / UTF-8 / 代理对（emoji）
 *   - 互逆性：encode → decode 字节级相等
 *
 * 创建日期：2026-05-09（M2 Phase B）
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  encodeStandardBase64,
  decodeStandardBase64,
  base64UrlNoPad,
  stringToUtf8,
  utf8ToString,
} from 'commons';

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

export default function base64UtilTest() {

  describe('Base64Util.encodeStandardBase64', () => {
    it('空数组 → 空串', 0, () => {
      expect(encodeStandardBase64(new Uint8Array(0))).assertEqual('');
    });

    it('"f" → "Zg=="', 0, () => {
      let r = encodeStandardBase64(new Uint8Array([0x66]));
      expect(r).assertEqual('Zg==');
    });

    it('"fo" → "Zm8="', 0, () => {
      let r = encodeStandardBase64(new Uint8Array([0x66, 0x6F]));
      expect(r).assertEqual('Zm8=');
    });

    it('"foo" → "Zm9v"（无 padding）', 0, () => {
      let r = encodeStandardBase64(new Uint8Array([0x66, 0x6F, 0x6F]));
      expect(r).assertEqual('Zm9v');
    });

    it('随机 16 字节 encode→decode 字节级相等', 0, () => {
      let raw = new Uint8Array(16);
      for (let i = 0; i < 16; i++) raw[i] = (i * 37 + 11) & 0xFF;
      let s = encodeStandardBase64(raw);
      let back = decodeStandardBase64(s);
      expect(bytesEqual(raw, back)).assertTrue();
    });

    it('base64url 输入也可解（容错 -_）', 0, () => {
      // "+/" 替换为 "-_" 后仍解出正确字节
      let raw = new Uint8Array([0xFB, 0xFF]);
      let std = encodeStandardBase64(raw);  // "+/8="
      // 手动转 url-safe
      let urlSafe = '';
      for (let i = 0; i < std.length; i++) {
        let c = std.charAt(i);
        if (c === '+') urlSafe += '-';
        else if (c === '/') urlSafe += '_';
        else if (c === '=') break;
        else urlSafe += c;
      }
      let back = decodeStandardBase64(urlSafe);
      expect(bytesEqual(raw, back)).assertTrue();
    });
  });

  describe('Base64Util.base64UrlNoPad', () => {
    it('去 padding + +/ → -_', 0, () => {
      let raw = new Uint8Array([0xFB, 0xFF, 0xBE]);
      let std = encodeStandardBase64(raw);  // "+/++"
      let url = base64UrlNoPad(raw);
      expect(url.indexOf('=')).assertEqual(-1);
      expect(url.indexOf('+')).assertEqual(-1);
      expect(url.indexOf('/')).assertEqual(-1);
      // 字符长度 = 标准长度 - padding
      let stdNoPad = std.replace(/=+$/, '');
      expect(url.length).assertEqual(stdNoPad.length);
    });
  });

  describe('Base64Util.stringToUtf8 / utf8ToString', () => {
    it('ASCII 往返', 0, () => {
      let s = 'Hello, World!';
      let bytes = stringToUtf8(s);
      expect(bytes.length).assertEqual(13);
      expect(utf8ToString(bytes)).assertEqual(s);
    });

    it('中文 UTF-8 3 字节字符', 0, () => {
      let s = '中文';
      let bytes = stringToUtf8(s);
      expect(bytes.length).assertEqual(6);  // 每个汉字 3 字节
      expect(utf8ToString(bytes)).assertEqual(s);
    });

    it('emoji 4 字节字符（代理对）', 0, () => {
      let s = '🎮';  // U+1F3AE，UTF-8 4 字节
      let bytes = stringToUtf8(s);
      expect(bytes.length).assertEqual(4);
      expect(utf8ToString(bytes)).assertEqual(s);
    });

    it('混合字符串往返', 0, () => {
      let s = 'AMCL 启动器 🚀 v1.0';
      let bytes = stringToUtf8(s);
      let back = utf8ToString(bytes);
      expect(back).assertEqual(s);
    });

    it('空串', 0, () => {
      expect(stringToUtf8('').length).assertEqual(0);
      expect(utf8ToString(new Uint8Array(0))).assertEqual('');
    });
  });

  describe('Base64Util.combined：UTF-8 → bytes → base64 → bytes → string', () => {
    it('refresh_token-like JSON 往返', 0, () => {
      let s = '{"refreshToken":"M.R3_BAY.abc","mcAccessToken":"eyJ.token","mcExpiresAt":1234567890}';
      let b1 = stringToUtf8(s);
      let b64 = encodeStandardBase64(b1);
      let b2 = decodeStandardBase64(b64);
      let back = utf8ToString(b2);
      expect(back).assertEqual(s);
    });
  });
}

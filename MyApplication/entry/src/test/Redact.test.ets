/**
 * Redact.test.ets — 日志脱敏工具测试
 *
 * 验证 redactToken() 的两面：
 *   ✅ 命中：JWT / OAuth JSON / Bearer / 长 base64 都能被打码
 *   ✅ 不命中：普通错误消息（短英文、URL）保持原样
 *
 * 创建日期：2026-05-10（LOG-P0-2）
 * 关联：docs/guides/logging-system-review-and-plan.md 问题 5
 */

import { describe, it, expect } from '@ohos/hypium';
import { redactToken } from 'commons';

export default function redactTest() {

  describe('Redact.redactToken null/empty', () => {
    it('null → 空串', 0, () => {
      expect(redactToken(null)).assertEqual('');
    });
    it('undefined → 空串', 0, () => {
      expect(redactToken(undefined)).assertEqual('');
    });
    it('空串保持空', 0, () => {
      expect(redactToken('')).assertEqual('');
    });
  });

  describe('Redact.redactToken JWT 模式', () => {
    it('单段 JWT 完整打码（保留前后 6 字符）', 0, () => {
      // 一个伪造 JWT：header.payload.signature，每段都够长
      let jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      let r = redactToken(jwt);
      // 打码格式：前 6 + ***[N chars]*** + 后 6
      expect(r.startsWith('eyJhbG')).assertTrue();
      expect(r.endsWith('ssw5c').valueOf() || r.endsWith('Qssw5c').valueOf() || r.includes('***[')).assertTrue();
      expect(r.includes(jwt)).assertEqual(false);  // 原 JWT 不能完整出现
    });

    it('JWT 嵌在错误消息中只 mask JWT 部分', 0, () => {
      let body = 'Login failed: token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c is expired';
      let r = redactToken(body);
      expect(r.startsWith('Login failed: token=eyJhbG')).assertTrue();
      expect(r.endsWith(' is expired')).assertTrue();
      expect(r.includes('SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c')).assertEqual(false);
    });
  });

  describe('Redact.redactToken OAuth JSON 字段', () => {
    it('access_token 字段被 mask 但 key 保留', 0, () => {
      let body = '{"access_token":"ya29.AHESVbXjsKj9_3KsdfsdfL3qhgZ-pZ4_d","token_type":"Bearer","expires_in":3600}';
      let r = redactToken(body);
      expect(r.includes('"access_token":"')).assertTrue();
      expect(r.includes('ya29.AHESVbXjsKj9_3KsdfsdfL3qhgZ-pZ4_d')).assertEqual(false);
      // expires_in 是数字，不应被 mask
      expect(r.includes('"expires_in":3600')).assertTrue();
    });

    it('refresh_token 字段被 mask', 0, () => {
      let body = '{"refresh_token":"M.R3_BAY.0.U.-CpC9oa12345LongRefreshTokenString","scope":"XboxLive.signin"}';
      let r = redactToken(body);
      expect(r.includes('"refresh_token":"')).assertTrue();
      expect(r.includes('M.R3_BAY.0.U.-CpC9oa12345LongRefreshTokenString')).assertEqual(false);
      expect(r.includes('"scope":"XboxLive.signin"')).assertTrue();
    });

    it('Xbox Token 字段（首字母大写）被 mask', 0, () => {
      let body = '{"Token":"eyJraWQiOiJrZXkx12345VeryLongXboxTokenString","DisplayClaims":{}}';
      let r = redactToken(body);
      expect(r.includes('"Token":"')).assertTrue();
      expect(r.includes('eyJraWQiOiJrZXkx12345VeryLongXboxTokenString')).assertEqual(false);
    });
  });

  describe('Redact.redactToken Bearer 头', () => {
    it('Bearer + token，保留 Bearer 前缀', 0, () => {
      let s = 'Authorization: Bearer ya29.AHESVbXjsKj9_3KAbCdEfGh1234567890LongOpaqueToken';
      let r = redactToken(s);
      expect(r.startsWith('Authorization: Bearer ')).assertTrue();
      expect(r.includes('ya29.AHESVbXjsKj9_3KAbCdEfGh1234567890LongOpaqueToken')).assertEqual(false);
    });

    it('小写 bearer 也能识别', 0, () => {
      let s = 'authorization: bearer abcdefghijklmnopqrstuvwxyz0123456789';
      let r = redactToken(s);
      expect(r.startsWith('authorization: bearer ')).assertTrue();
      expect(r.includes('abcdefghijklmnopqrstuvwxyz0123456789')).assertEqual(false);
    });
  });

  describe('Redact.redactToken 长 base64 兜底', () => {
    it('40+ 字符长 base64-like 串被打码', 0, () => {
      // 50 字符纯字母数字
      let s = 'opaqueXboxToken_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789==';
      let r = redactToken(s);
      expect(r).assertEqual('opaque***[54chars]***6789==');
    });

    it('短串（<40）不打码', 0, () => {
      let s = 'short_token_123';
      expect(redactToken(s)).assertEqual('short_token_123');
    });

    it('兆字节字段不溢出匹配栈并保持技术摘要', 0, () => {
      // 在真实 ArkTS 本地测试运行时执行生产实现；不截断输入或关闭脱敏。
      const size: number = 6 * 1024 * 1024;
      const hex: string = 'a'.repeat(size);
      expect(redactToken(hex)).assertEqual(hex);
      const token: string = 'G'.repeat(size) + '==';
      const masked: string = 'GGGGGG***[' + token.length + 'chars]***GGGG==';
      expect(redactToken(token)).assertEqual(masked);
      expect(redactToken(masked)).assertEqual(masked);
    });
  });

  describe('Redact.redactToken 不命中（业务消息保持原样）', () => {
    it('英文错误消息不变', 0, () => {
      let s = 'network unreachable';
      expect(redactToken(s)).assertEqual('network unreachable');
    });

    it('中文错误消息不变', 0, () => {
      let s = '认证服务暂时不可用，请稍后重试';
      expect(redactToken(s)).assertEqual('认证服务暂时不可用，请稍后重试');
    });

    it('短 HTTP 错误码不变', 0, () => {
      let s = 'HTTP 401 Unauthorized';
      expect(redactToken(s)).assertEqual('HTTP 401 Unauthorized');
    });

    it('短 OAuth error code 字段保持完整', 0, () => {
      // OAuth 标准错误体只有 error / error_description 短字段
      let s = '{"error":"invalid_grant","error_description":"Token expired"}';
      let r = redactToken(s);
      // invalid_grant 长度 13，Token expired 长度 13，都 < 40 不应被 mask
      expect(r).assertEqual(s);
    });

    it('普通 URL 不被打码（不含连续 40 字符 base64-like）', 0, () => {
      let s = 'https://api.example.com/v1/users/123';
      expect(redactToken(s)).assertEqual(s);
    });
  });

  describe('Redact.redactToken 边界', () => {
    it('多个 token 同时打码', 0, () => {
      let s = 'access=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c, refresh=opaqueRefreshTokenLongEnoughToTrigger40CharRule==';
      let r = redactToken(s);
      // 两个 token 都被打码
      expect(r.includes('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c')).assertEqual(false);
      expect(r.includes('opaqueRefreshTokenLongEnoughToTrigger40CharRule==')).assertEqual(false);
      // 业务文本保留：开头 access= 不被吃（access=eyJhbG 只 13 字符，未达 40 阈值）
      expect(r.startsWith('access=')).assertTrue();
      // 等号分隔业务键与 token 主体，线性兜底扫描保留键，只遮蔽其后的长字段。
      expect(r.includes(', refresh=')).assertTrue();
    });
  });

}

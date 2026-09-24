/**
 * MicrosoftOAuth.test.ets — Microsoft OAuth 流程单元测试
 *
 * 覆盖：
 *   - base64UrlNoPad         : +/= 字符替换 + padding 剥离
 *   - generatePkce           : 输出形态校验（长度、字母表、唯一性）
 *   - buildAuthorizeUrl      : 必需参数 + URL 编码
 *   - exchangeCodeForToken   : 200 成功路径 + 4xx 错误路径 + 缺字段
 *   - refreshAccessToken     : 表单字段正确 + 解析
 *   - requestDeviceCode      : 字段映射 + verification_uri_complete 兜底
 *   - pollDeviceCodeOnce     : 5 种状态枚举（PENDING/SLOW_DOWN/DECLINED/EXPIRED/TOKEN）
 *
 * 注入策略：HttpClient 接口 + FakeHttpClient，**严禁连真实网**。
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { describe, it, expect } from '@ohos/hypium';
import { HttpClient, HttpResponse } from 'account';
import {
  MicrosoftOAuth,
  generatePkce,
  buildAuthorizeUrl,
  base64UrlNoPad,
  PkceChallenge,
  MsaTokenSet,
  DeviceCodePollKind,
  DeviceCodePollResult,
  OAuthError,
} from 'account';
import {
  MSA_CLIENT_ID,
  MSA_TOKEN_URL,
  MSA_DEVICE_CODE_URL,
  MSA_AUTHORIZE_URL,
  MSA_REDIRECT_URI,
} from 'commons';

// ============================================================
//  FakeHttpClient — 记录最近一次调用，按 url 返回预设响应
// ============================================================

interface RecordedCall {
  method: string;       // 'POST_FORM' | 'POST_JSON' | 'GET'
  url: string;
  body: string;
  bearer: string;
}

class FakeHttpClient implements HttpClient {
  private responses: Map<string, HttpResponse> = new Map();
  private errors: Map<string, Error> = new Map();
  calls: RecordedCall[] = [];

  setResponse(url: string, response: HttpResponse): void {
    this.responses.set(url, response);
  }
  setError(url: string, e: Error): void {
    this.errors.set(url, e);
  }
  lastCall(): RecordedCall {
    return this.calls[this.calls.length - 1];
  }

  async postForm(url: string, urlEncodedBody: string, _extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_FORM', url: url, body: urlEncodedBody, bearer: '' });
    return this.lookup(url);
  }
  async postJson(url: string, jsonBody: string, _extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_JSON', url: url, body: jsonBody, bearer: '' });
    return this.lookup(url);
  }
  async get(url: string, bearerToken: string, _extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'GET', url: url, body: '', bearer: bearerToken });
    return this.lookup(url);
  }
  // putJson / delete 是 HttpClient 后加的（Mojang Profile API 改 cape 等）。
  // OAuth 链路不用它们，但 fake 必须实现完整接口，否则整个测试模块编译失败。
  // 走同一个 lookup，因此 setError 注入的网络错误对这两个动作同样生效。
  async putJson(url: string, bearerToken: string, jsonBody: string,
                _extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'PUT_JSON', url: url, body: jsonBody, bearer: bearerToken });
    return this.lookup(url);
  }
  async delete(url: string, bearerToken: string,
               _extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'DELETE', url: url, body: '', bearer: bearerToken });
    return this.lookup(url);
  }

  private lookup(url: string): HttpResponse {
    let err = this.errors.get(url);
    if (err) throw err;
    let r = this.responses.get(url);
    if (!r) throw new Error('FakeHttpClient: no mock for ' + url);
    return r;
  }
}

// ============================================================
//  辅助：从 application/x-www-form-urlencoded 字符串解析为 Map
// ============================================================

function parseForm(body: string): Map<string, string> {
  let m = new Map<string, string>();
  if (!body || body.length === 0) return m;
  let pairs = body.split('&');
  for (let p of pairs) {
    let eq = p.indexOf('=');
    if (eq < 0) continue;
    let k = decodeURIComponent(p.substring(0, eq));
    let v = decodeURIComponent(p.substring(eq + 1));
    m.set(k, v);
  }
  return m;
}

// ============================================================
//  测试主体
// ============================================================

export default function microsoftOAuthTest() {

  // ----------------------------------------------------------
  //  base64UrlNoPad — 纯字符替换
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.base64UrlNoPad', () => {
    it('替换 +/= 为 -_', 0, () => {
      // 0xFB 0xEF 0xFF: 标准 base64 是 "++//"，base64url 是 "--__"
      let bytes = new Uint8Array([0xfb, 0xef, 0xff]);
      let s = base64UrlNoPad(bytes);
      // 标准 base64: "++//"  (3 字节 → 4 字符，无 padding)
      // base64url:   "--__"
      expect(s).assertEqual('--__');
    });

    it('剥离尾部 padding =', 0, () => {
      // 1 字节标准 base64 是 "<x>=="  →  base64url-no-pad: "<x>"
      let bytes = new Uint8Array([0x66]); // 'f'
      let s = base64UrlNoPad(bytes);
      expect(s.indexOf('=')).assertEqual(-1);
      expect(s.length).assertEqual(2);
    });

    it('空数组返回空串', 0, () => {
      let s = base64UrlNoPad(new Uint8Array([]));
      expect(s).assertEqual('');
    });
  });

  // ----------------------------------------------------------
  //  generatePkce — 调 cryptoFramework，可能在 CLI 测试受限
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.generatePkce', () => {
    it('verifier 长度在 RFC 7636 范围 (43-128)', 0, async () => {
      let pkce: PkceChallenge | null = null;
      try {
        pkce = await generatePkce();
      } catch (e) {
        // CLI 测试可能没 native cryptoFramework 实现，跳过断言
        console.log('[generatePkce] skipped (cryptoFramework unavailable): ' + (e as Error).message);
        return;
      }
      expect(pkce.verifier.length >= 43).assertTrue();
      expect(pkce.verifier.length <= 128).assertTrue();
    });

    it('verifier 字母表是 base64url-no-pad', 0, async () => {
      let pkce: PkceChallenge | null = null;
      try {
        pkce = await generatePkce();
      } catch (e) {
        return;
      }
      // base64url-no-pad: [A-Za-z0-9_-]
      for (let i = 0; i < pkce.verifier.length; i++) {
        let c = pkce.verifier.charAt(i);
        let isAllowed =
          (c >= 'A' && c <= 'Z') ||
          (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') ||
          c === '-' || c === '_';
        expect(isAllowed).assertTrue();
      }
    });

    it('两次调用的 verifier / state 都不同', 0, async () => {
      let p1: PkceChallenge | null = null;
      let p2: PkceChallenge | null = null;
      try {
        p1 = await generatePkce();
        p2 = await generatePkce();
      } catch (e) {
        return;
      }
      expect(p1.verifier !== p2.verifier).assertTrue();
      expect(p1.state !== p2.state).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  buildAuthorizeUrl — 纯字符串拼接
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.buildAuthorizeUrl', () => {
    it('包含必需参数', 0, () => {
      let challenge: PkceChallenge = {
        verifier: 'V0', challenge: 'C0', state: 'S0',
      };
      let url = buildAuthorizeUrl(challenge);
      expect(url.startsWith(MSA_AUTHORIZE_URL + '?')).assertTrue();
      expect(url.indexOf('client_id=' + MSA_CLIENT_ID) >= 0).assertTrue();
      expect(url.indexOf('response_type=code') >= 0).assertTrue();
      expect(url.indexOf('code_challenge=C0') >= 0).assertTrue();
      expect(url.indexOf('code_challenge_method=S256') >= 0).assertTrue();
      expect(url.indexOf('state=S0') >= 0).assertTrue();
      expect(url.indexOf('prompt=select_account') >= 0).assertTrue();
    });

    it('redirect_uri 被 URL 编码', 0, () => {
      let url = buildAuthorizeUrl({ verifier: 'V', challenge: 'C', state: 'S' });
      // MSA_REDIRECT_URI 含 ":"和"/"，必须被 percent-encoded
      let encoded = encodeURIComponent(MSA_REDIRECT_URI);
      expect(url.indexOf('redirect_uri=' + encoded) >= 0).assertTrue();
    });

    it('scope 被正确编码（含空格）', 0, () => {
      let url = buildAuthorizeUrl({ verifier: 'V', challenge: 'C', state: 'S' });
      // "XboxLive.signin offline_access" 中的空格应编码为 %20 或 +
      let hasEncodedScope = url.indexOf('scope=XboxLive.signin%20offline_access') >= 0
        || url.indexOf('scope=XboxLive.signin+offline_access') >= 0;
      expect(hasEncodedScope).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  exchangeCodeForToken
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.exchangeCodeForToken', () => {
    it('200 成功 → 解析 token + 计算 expiresAt（提前 60s）', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: JSON.stringify({
          access_token: 'AT_VAL',
          refresh_token: 'RT_VAL',
          expires_in: 3600,
          token_type: 'Bearer',
        }),
      });
      let oauth = new MicrosoftOAuth(fake);
      let before = Date.now();
      let tok: MsaTokenSet = await oauth.exchangeCodeForToken('the_code', 'the_verifier');
      let after = Date.now();
      expect(tok.accessToken).assertEqual('AT_VAL');
      expect(tok.refreshToken).assertEqual('RT_VAL');
      // expiresAt 应在 [before + (3600-60)*1000, after + (3600-60)*1000]
      expect(tok.expiresAt >= before + (3600 - 60) * 1000).assertTrue();
      expect(tok.expiresAt <= after + (3600 - 60) * 1000).assertTrue();
    });

    it('请求体包含 grant_type=authorization_code + code + verifier', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: '{"access_token":"X","refresh_token":"Y","expires_in":3600}',
      });
      let oauth = new MicrosoftOAuth(fake);
      await oauth.exchangeCodeForToken('THE_CODE', 'THE_VERIFIER');
      let call = fake.lastCall();
      expect(call.method).assertEqual('POST_FORM');
      expect(call.url).assertEqual(MSA_TOKEN_URL);
      let form = parseForm(call.body);
      expect(form.get('grant_type')).assertEqual('authorization_code');
      expect(form.get('client_id')).assertEqual(MSA_CLIENT_ID);
      expect(form.get('code')).assertEqual('THE_CODE');
      expect(form.get('code_verifier')).assertEqual('THE_VERIFIER');
      expect(form.get('redirect_uri')).assertEqual(MSA_REDIRECT_URI);
    });

    it('400 + error JSON → 抛 OAuthError 带正确 code', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({
          error: 'invalid_grant',
          error_description: 'AADSTS70008: code expired',
        }),
      });
      let oauth = new MicrosoftOAuth(fake);
      let caught: Error | null = null;
      try {
        await oauth.exchangeCodeForToken('expired_code', 'V');
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== null).assertTrue();
      expect(caught instanceof OAuthError).assertTrue();
      expect((caught as OAuthError).code).assertEqual('invalid_grant');
      expect((caught as OAuthError).httpStatus).assertEqual(400);
    });

    it('200 但缺 access_token → 抛 invalid_response', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: '{"refresh_token":"only_rt","expires_in":3600}',
      });
      let oauth = new MicrosoftOAuth(fake);
      let caught: Error | null = null;
      try {
        await oauth.exchangeCodeForToken('c', 'v');
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== null).assertTrue();
      expect((caught as OAuthError).code).assertEqual('invalid_response');
    });
  });

  // ----------------------------------------------------------
  //  refreshAccessToken
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.refreshAccessToken', () => {
    it('请求体包含 grant_type=refresh_token + refresh_token + scope', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: '{"access_token":"NEW_AT","refresh_token":"NEW_RT","expires_in":3600}',
      });
      let oauth = new MicrosoftOAuth(fake);
      let tok = await oauth.refreshAccessToken('OLD_RT');
      expect(tok.accessToken).assertEqual('NEW_AT');
      expect(tok.refreshToken).assertEqual('NEW_RT');
      let form = parseForm(fake.lastCall().body);
      expect(form.get('grant_type')).assertEqual('refresh_token');
      expect(form.get('refresh_token')).assertEqual('OLD_RT');
      expect(form.has('scope')).assertTrue();
    });

    it('refresh_token 失效 → 抛 OAuthError invalid_grant', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'invalid_grant', error_description: 'token revoked' }),
      });
      let oauth = new MicrosoftOAuth(fake);
      let caught: OAuthError | null = null;
      try {
        await oauth.refreshAccessToken('STALE_RT');
      } catch (e) {
        caught = e as OAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as OAuthError).code).assertEqual('invalid_grant');
    });
  });

  // ----------------------------------------------------------
  //  requestDeviceCode
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.requestDeviceCode', () => {
    it('200 → 字段映射 + expiresAt 计算', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_DEVICE_CODE_URL, {
        statusCode: 200,
        body: JSON.stringify({
          device_code: 'DEV',
          user_code: 'ABCD-1234',
          verification_uri: 'https://microsoft.com/link',
          verification_uri_complete: 'https://microsoft.com/link?otc=ABCD-1234',
          interval: 5,
          expires_in: 900,
        }),
      });
      let oauth = new MicrosoftOAuth(fake);
      let before = Date.now();
      let req = await oauth.requestDeviceCode();
      let after = Date.now();
      expect(req.deviceCode).assertEqual('DEV');
      expect(req.userCode).assertEqual('ABCD-1234');
      expect(req.verificationUri).assertEqual('https://microsoft.com/link');
      expect(req.verificationUriComplete).assertEqual('https://microsoft.com/link?otc=ABCD-1234');
      expect(req.interval).assertEqual(5);
      expect(req.expiresAt >= before + 900 * 1000).assertTrue();
      expect(req.expiresAt <= after + 900 * 1000).assertTrue();
    });

    it('verification_uri_complete 缺失 → 自动拼接', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_DEVICE_CODE_URL, {
        statusCode: 200,
        body: JSON.stringify({
          device_code: 'DEV',
          user_code: 'XYZ-9',
          verification_uri: 'https://microsoft.com/link',
          interval: 5,
          expires_in: 900,
        }),
      });
      let oauth = new MicrosoftOAuth(fake);
      let req = await oauth.requestDeviceCode();
      expect(req.verificationUriComplete.startsWith('https://microsoft.com/link')).assertTrue();
      expect(req.verificationUriComplete.indexOf('XYZ-9') >= 0).assertTrue();
    });

    it('200 但缺 device_code → 抛 invalid_response', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_DEVICE_CODE_URL, {
        statusCode: 200,
        body: '{"user_code":"X","verification_uri":"u","interval":5,"expires_in":900}',
      });
      let oauth = new MicrosoftOAuth(fake);
      let caught: OAuthError | null = null;
      try {
        await oauth.requestDeviceCode();
      } catch (e) {
        caught = e as OAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as OAuthError).code).assertEqual('invalid_response');
    });
  });

  // ----------------------------------------------------------
  //  pollDeviceCodeOnce — 5 种状态枚举
  // ----------------------------------------------------------
  describe('MicrosoftOAuth.pollDeviceCodeOnce', () => {
    it('error=authorization_pending → PENDING', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'authorization_pending' }),
      });
      let r: DeviceCodePollResult = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.PENDING);
      expect(r.token === null).assertTrue();
    });

    it('error=slow_down → SLOW_DOWN', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'slow_down' }),
      });
      let r = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.SLOW_DOWN);
    });

    it('error=authorization_declined → DECLINED', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'authorization_declined' }),
      });
      let r = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.DECLINED);
    });

    it('error=access_denied 也归 DECLINED', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'access_denied' }),
      });
      let r = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.DECLINED);
    });

    it('error=expired_token → EXPIRED', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'expired_token' }),
      });
      let r = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.EXPIRED);
    });

    it('200 → TOKEN + token 字段填充', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: '{"access_token":"DC_AT","refresh_token":"DC_RT","expires_in":3600}',
      });
      let r = await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      expect(r.kind).assertEqual(DeviceCodePollKind.TOKEN);
      expect(r.token !== null).assertTrue();
      expect((r.token as MsaTokenSet).accessToken).assertEqual('DC_AT');
    });

    it('未知 error → 抛 OAuthError', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MSA_TOKEN_URL, {
        statusCode: 400,
        body: JSON.stringify({ error: 'something_weird' }),
      });
      let caught: OAuthError | null = null;
      try {
        await new MicrosoftOAuth(fake).pollDeviceCodeOnce('DEV');
      } catch (e) {
        caught = e as OAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as OAuthError).code).assertEqual('something_weird');
    });
  });
}

/**
 * MinecraftProfileApi.test.ets — MC bearer + profile 单元测试
 *
 * 覆盖：
 *   - loginWithXbox     : 200 成功 + identityToken 字符串格式 + 缺字段 + 5xx
 *   - getProfile        : 200 成功 + uuid 格式化 + 404 NOT_PREMIUM + 401 token_expired
 *   - formatCanonicalUuid : 32 hex → 8-4-4-4-12，已 canonical → 直返，异常长度兜底
 *
 * 全部 FakeHttpClient mock，不连真实网。
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { describe, it, expect } from '@ohos/hypium';
import { HttpClient, HttpResponse } from 'account';
import {
  MinecraftProfileApi,
  McBearerToken,
  McProfile,
  MinecraftAuthError,
  formatCanonicalUuid,
} from 'account';
import { MC_BEARER_URL, MC_PROFILE_URL } from 'commons';

// ============================================================
//  FakeHttpClient
// ============================================================

interface RecordedCall {
  method: string;
  url: string;
  body: string;     // postJson body 或 GET 时的 bearer
  bearer: string;   // GET 时为 bearer token
}

class FakeHttpClient implements HttpClient {
  private responses: Map<string, HttpResponse> = new Map();
  calls: RecordedCall[] = [];

  setResponse(url: string, response: HttpResponse): void {
    this.responses.set(url, response);
  }
  lastCall(): RecordedCall {
    return this.calls[this.calls.length - 1];
  }

  async postForm(url: string, body: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_FORM', url: url, body: body, bearer: '' });
    return this.lookup(url);
  }
  async postJson(url: string, body: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_JSON', url: url, body: body, bearer: '' });
    return this.lookup(url);
  }
  async get(url: string, bearer: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'GET', url: url, body: '', bearer: bearer });
    return this.lookup(url);
  }
  // putJson / delete 是 HttpClient 后加的（Mojang Profile API 改 cape 等）。
  // 本套用例不覆盖这两个动作，但 fake 必须实现完整接口，否则整个测试模块编译失败。
  // 记录方式与上面三个动作一致，让将来给它们写用例时不需要再改 fake 结构。
  async putJson(url: string, bearer: string, jsonBody: string,
                _h?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'PUT_JSON', url: url, body: jsonBody, bearer: bearer });
    return this.lookup(url);
  }
  async delete(url: string, bearer: string,
               _h?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'DELETE', url: url, body: '', bearer: bearer });
    return this.lookup(url);
  }

  private lookup(url: string): HttpResponse {
    let r = this.responses.get(url);
    if (!r) throw new Error('FakeHttpClient: no mock for ' + url);
    return r;
  }
}

// ============================================================
//  测试 fixture（显式 interface，ArkTS strict 要求）
// ============================================================

interface FakeBearerOk { access_token: string; token_type: string; expires_in: number; }
interface FakeBearerMissingAt { token_type: string; expires_in: number; }
interface FakeProfileOk { id: string; name: string; }
interface FakeProfileMissingName { id: string; }

// 含 skin/cape 数组的 fixture（Mojang Profile API 真实返回结构）
interface FakeSkinEntry { id: string; state: string; url: string; variant: string; }
interface FakeCapeEntry { id: string; state: string; url: string; alias: string; }
interface FakeProfileFull {
  id: string;
  name: string;
  skins: FakeSkinEntry[];
  capes: FakeCapeEntry[];
}

// ============================================================
//  测试主体
// ============================================================

export default function minecraftProfileApiTest() {

  // ----------------------------------------------------------
  //  formatCanonicalUuid — 纯函数
  // ----------------------------------------------------------
  describe('MinecraftProfileApi.formatCanonicalUuid', () => {
    it('32 hex → 8-4-4-4-12', 0, () => {
      let r = formatCanonicalUuid('069a79f444e94726a5befca90e38aaf5');
      expect(r).assertEqual('069a79f4-44e9-4726-a5be-fca90e38aaf5');
    });

    it('已 canonical → 转小写直返', 0, () => {
      let r = formatCanonicalUuid('069A79F4-44E9-4726-A5BE-FCA90E38AAF5');
      expect(r).assertEqual('069a79f4-44e9-4726-a5be-fca90e38aaf5');
    });

    it('空串 → 空串', 0, () => {
      expect(formatCanonicalUuid('')).assertEqual('');
    });

    it('异常长度 → 原样小写返回（不崩）', 0, () => {
      let r = formatCanonicalUuid('AB');
      expect(r).assertEqual('ab');
    });
  });

  // ----------------------------------------------------------
  //  loginWithXbox
  // ----------------------------------------------------------
  describe('MinecraftProfileApi.loginWithXbox', () => {
    it('200 → 解析 access_token + 计算 expiresAt（提前 60s）', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeBearerOk = {
        access_token: 'MC_BEARER_VALUE',
        token_type: 'Bearer',
        expires_in: 86400,
      };
      fake.setResponse(MC_BEARER_URL, { statusCode: 200, body: JSON.stringify(body) });
      let before = Date.now();
      let tok: McBearerToken = await new MinecraftProfileApi(fake).loginWithXbox('UHS', 'XSTS');
      let after = Date.now();
      expect(tok.accessToken).assertEqual('MC_BEARER_VALUE');
      expect(tok.expiresAt >= before + (86400 - 60) * 1000).assertTrue();
      expect(tok.expiresAt <= after + (86400 - 60) * 1000).assertTrue();
    });

    it('请求体含 identityToken=XBL3.0 x=<uhs>;<xsts>', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeBearerOk = { access_token: 'AT', token_type: 'Bearer', expires_in: 86400 };
      fake.setResponse(MC_BEARER_URL, { statusCode: 200, body: JSON.stringify(body) });
      await new MinecraftProfileApi(fake).loginWithXbox('UHSVAL', 'XSTSVAL');
      let call = fake.lastCall();
      expect(call.method).assertEqual('POST_JSON');
      expect(call.url).assertEqual(MC_BEARER_URL);
      expect(call.body.indexOf('"identityToken":"XBL3.0 x=UHSVAL;XSTSVAL"') >= 0).assertTrue();
    });

    it('200 但缺 access_token → 抛 invalid_response', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeBearerMissingAt = { token_type: 'Bearer', expires_in: 86400 };
      fake.setResponse(MC_BEARER_URL, { statusCode: 200, body: JSON.stringify(body) });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).loginWithXbox('U', 'X');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as MinecraftAuthError).stage).assertEqual('bearer');
      expect((caught as MinecraftAuthError).code).assertEqual('invalid_response');
    });

    it('5xx → http_error', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MC_BEARER_URL, { statusCode: 503, body: 'Service Unavailable' });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).loginWithXbox('U', 'X');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      let err = caught as MinecraftAuthError;
      expect(err.stage).assertEqual('bearer');
      expect(err.code).assertEqual('http_error');
      expect(err.httpStatus).assertEqual(503);
    });
  });

  // ----------------------------------------------------------
  //  getProfile
  // ----------------------------------------------------------
  describe('MinecraftProfileApi.getProfile', () => {
    it('200 → uuid + username（uuid 自动 canonical 化）', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileOk = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.uuid).assertEqual('069a79f4-44e9-4726-a5be-fca90e38aaf5');
      expect(p.username).assertEqual('Notch');
    });

    it('Authorization: Bearer <token> 经由 HttpClient.get 传递', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileOk = { id: '069a79f444e94726a5befca90e38aaf5', name: 'X' };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      await new MinecraftProfileApi(fake).getProfile('TOKEN_X');
      let call = fake.lastCall();
      expect(call.method).assertEqual('GET');
      expect(call.url).assertEqual(MC_PROFILE_URL);
      expect(call.bearer).assertEqual('TOKEN_X');
    });

    it('404 → NOT_PREMIUM', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MC_PROFILE_URL, {
        statusCode: 404,
        body: '{"path":"/minecraft/profile","errorMessage":"..."}',
      });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).getProfile('MC_AT');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      let err = caught as MinecraftAuthError;
      expect(err.stage).assertEqual('profile');
      expect(err.code).assertEqual('not_premium');
      expect(err.httpStatus).assertEqual(404);
    });

    it('401 → token_expired', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MC_PROFILE_URL, { statusCode: 401, body: 'Unauthorized' });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).getProfile('MC_AT');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as MinecraftAuthError).code).assertEqual('token_expired');
    });

    it('200 但缺 name → invalid_response', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileMissingName = { id: '069a79f444e94726a5befca90e38aaf5' };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).getProfile('MC_AT');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as MinecraftAuthError).code).assertEqual('invalid_response');
    });

    it('500 → http_error', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(MC_PROFILE_URL, { statusCode: 500, body: 'oops' });
      let caught: MinecraftAuthError | null = null;
      try {
        await new MinecraftProfileApi(fake).getProfile('MC_AT');
      } catch (e) {
        caught = e as MinecraftAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as MinecraftAuthError).code).assertEqual('http_error');
      expect((caught as MinecraftAuthError).httpStatus).assertEqual(500);
    });

    it('skin/cape 缺失（旧 fixture）→ skin=null, cape=null', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileOk = { id: '069a79f444e94726a5befca90e38aaf5', name: 'Notch' };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin).assertNull();
      expect(p.cape).assertNull();
    });
  });

  // ----------------------------------------------------------
  //  getProfile · skin/cape 解析（M2.5 引入）
  // ----------------------------------------------------------
  describe('MinecraftProfileApi.getProfile · skin & cape', () => {

    it('单一 ACTIVE skin → 解析 url + variant', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [{
          id: 'sk1',
          state: 'ACTIVE',
          url: 'http://textures.minecraft.net/texture/aaa',
          variant: 'CLASSIC',
        }],
        capes: [],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin !== null).assertTrue();
      expect(p.skin!.url).assertEqual('http://textures.minecraft.net/texture/aaa');
      expect(p.skin!.variant).assertEqual('CLASSIC');
      expect(p.cape).assertNull();
    });

    it('单一 ACTIVE cape → 解析 url + alias', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [],
        capes: [{
          id: 'cp1',
          state: 'ACTIVE',
          url: 'http://textures.minecraft.net/texture/migrator',
          alias: 'Migrator',
        }],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.cape !== null).assertTrue();
      expect(p.cape!.url).assertEqual('http://textures.minecraft.net/texture/migrator');
      expect(p.cape!.alias).assertEqual('Migrator');
      expect(p.skin).assertNull();
    });

    it('skin + cape 双 ACTIVE → 都解析', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [{ id: 'sk1', state: 'ACTIVE', url: 'http://x/skin', variant: 'SLIM' }],
        capes: [{ id: 'cp1', state: 'ACTIVE', url: 'http://x/cape', alias: 'Vanilla' }],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin!.variant).assertEqual('SLIM');
      expect(p.cape!.alias).assertEqual('Vanilla');
    });

    it('全部 INACTIVE → null', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [{ id: 'sk1', state: 'INACTIVE', url: 'http://x/old', variant: 'CLASSIC' }],
        capes: [{ id: 'cp1', state: 'INACTIVE', url: 'http://x/oldcape', alias: 'Old' }],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin).assertNull();
      expect(p.cape).assertNull();
    });

    it('多个 skin 中精确挑出 ACTIVE 那个', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [
          { id: 'sk0', state: 'INACTIVE', url: 'http://x/old1', variant: 'CLASSIC' },
          { id: 'sk1', state: 'ACTIVE',   url: 'http://x/cur',  variant: 'SLIM' },
          { id: 'sk2', state: 'INACTIVE', url: 'http://x/old2', variant: 'CLASSIC' },
        ],
        capes: [],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin!.url).assertEqual('http://x/cur');
      expect(p.skin!.variant).assertEqual('SLIM');
    });

    it('ACTIVE entry 缺 url → 视为 null（防御性）', 0, async () => {
      let fake = new FakeHttpClient();
      // 故意构造一个 url 为空字符串的项
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [{ id: 'sk1', state: 'ACTIVE', url: '', variant: 'CLASSIC' }],
        capes: [],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin).assertNull();
    });

    it('skins/capes 缺字段（老服务器）→ null', 0, async () => {
      let fake = new FakeHttpClient();
      let body: FakeProfileOk = { id: '069a79f444e94726a5befca90e38aaf5', name: 'Notch' };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.skin).assertNull();
      expect(p.cape).assertNull();
    });

    it('cape 无 alias → 保留 url 但 alias=空串', 0, async () => {
      let fake = new FakeHttpClient();
      // alias 用空串模拟"未知披风"
      let body: FakeProfileFull = {
        id: '069a79f444e94726a5befca90e38aaf5',
        name: 'Notch',
        skins: [],
        capes: [{ id: 'cp1', state: 'ACTIVE', url: 'http://x/cape', alias: '' }],
      };
      fake.setResponse(MC_PROFILE_URL, { statusCode: 200, body: JSON.stringify(body) });
      let p: McProfile = await new MinecraftProfileApi(fake).getProfile('MC_AT');
      expect(p.cape !== null).assertTrue();
      expect(p.cape!.url).assertEqual('http://x/cape');
      expect(p.cape!.alias).assertEqual('');
    });
  });
}

/**
 * XboxLiveAuth.test.ets — XBL + XSTS 认证单元测试
 *
 * 覆盖：
 *   - authenticateXbl       : 200 成功 + 请求 body 字段 + RpsTicket 前缀 d=
 *   - authorizeXsts         : 200 成功 + RelyingParty=Minecraft + UserTokens 数组
 *   - XErr 5 个码全覆盖（2148916233/235/236/237/238）→ 中文消息
 *   - 通用 HTTP 4xx 无 XErr → 错误消息含 server message
 *   - 缺字段（无 Token/uhs）→ 抛 XboxAuthError
 *
 * 不依赖真实网络，全部 FakeHttpClient mock。
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { describe, it, expect } from '@ohos/hypium';
import { HttpClient, HttpResponse } from 'account';
import {
  XboxLiveAuth,
  XblTokenResult,
  XboxAuthError,
  describeXErr,
} from 'account';
import { XBL_AUTH_URL, XSTS_AUTH_URL } from 'commons';

// ============================================================
//  FakeHttpClient（与 MicrosoftOAuth.test 相同模式）
// ============================================================

interface RecordedCall {
  method: string;
  url: string;
  body: string;
  headers: Map<string, string> | undefined;
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

  async postForm(url: string, body: string, headers?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_FORM', url: url, body: body, headers: headers });
    return this.lookup(url);
  }
  async postJson(url: string, body: string, headers?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'POST_JSON', url: url, body: body, headers: headers });
    return this.lookup(url);
  }
  async get(url: string, bearer: string, headers?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'GET', url: url, body: bearer, headers: headers });
    return this.lookup(url);
  }
  // putJson / delete 是 HttpClient 后加的（Mojang Profile API 改 cape 等）。
  // XBL/XSTS 链路不用它们，但 fake 必须实现完整接口，否则整个测试模块编译失败。
  async putJson(url: string, bearer: string, jsonBody: string,
                headers?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'PUT_JSON', url: url, body: jsonBody, headers: headers });
    return this.lookup(url);
  }
  async delete(url: string, bearer: string,
               headers?: Map<string, string>): Promise<HttpResponse> {
    this.calls.push({ method: 'DELETE', url: url, body: bearer, headers: headers });
    return this.lookup(url);
  }

  private lookup(url: string): HttpResponse {
    let r = this.responses.get(url);
    if (!r) throw new Error('FakeHttpClient: no mock for ' + url);
    return r;
  }
}

// ============================================================
//  辅助：构造 XBL/XSTS 成功响应 body
// ============================================================
//
// ArkTS strict 不允许嵌套未声明类型的对象字面量，这里为 fixture 显式声明 shape。

interface FakeXuiClaim { uhs: string; }
interface FakeDisplayClaims { xui: FakeXuiClaim[]; }
interface FakeXblBody {
  IssueInstant: string;
  NotAfter: string;
  Token: string;
  DisplayClaims: FakeDisplayClaims;
}
interface FakeXerrBody {
  Identity: string;
  XErr: number;
  Message: string;
  Redirect: string;
}

function successBody(token: string, uhs: string): string {
  let body: FakeXblBody = {
    IssueInstant: '2026-05-09T00:00:00Z',
    NotAfter: '2026-05-10T00:00:00Z',
    Token: token,
    DisplayClaims: { xui: [{ uhs: uhs }] },
  };
  return JSON.stringify(body);
}

function xerrBody(code: number): string {
  let body: FakeXerrBody = {
    Identity: '0',
    XErr: code,
    Message: '',
    Redirect: 'https://start.ui.xboxlive.com/AddChildToFamily',
  };
  return JSON.stringify(body);
}

// 部分缺字段的错误 fixture（Token 或 uhs 缺失）
interface FakeXblBodyMissingToken {
  DisplayClaims: FakeDisplayClaims;
}
interface FakeXblBodyEmptyXui {
  Token: string;
  DisplayClaims: FakeDisplayClaims;
}
interface FakeXblBodyMessageOnly {
  Message: string;
}

// ============================================================
//  测试主体
// ============================================================

export default function xboxLiveAuthTest() {

  // ----------------------------------------------------------
  //  describeXErr — 纯查表
  // ----------------------------------------------------------
  describe('XboxLiveAuth.describeXErr', () => {
    it('2148916233 → 没 Xbox 账户', 0, () => {
      let info = describeXErr(2148916233);
      expect(info.code).assertEqual(2148916233);
      expect(info.message.indexOf('Xbox') >= 0).assertTrue();
    });

    it('2148916235 → 地区不可用', 0, () => {
      let info = describeXErr(2148916235);
      expect(info.message.indexOf('地区') >= 0).assertTrue();
    });

    it('2148916236 → 需要身份验证', 0, () => {
      let info = describeXErr(2148916236);
      expect(info.message.indexOf('验证') >= 0).assertTrue();
    });

    it('2148916237 → 美国地区身份验证', 0, () => {
      let info = describeXErr(2148916237);
      expect(info.message.indexOf('美国') >= 0).assertTrue();
    });

    it('2148916238 → 未成年家庭组', 0, () => {
      let info = describeXErr(2148916238);
      expect(info.message.indexOf('家庭') >= 0).assertTrue();
    });

    it('未知码 → 通用消息含 code', 0, () => {
      let info = describeXErr(99999);
      expect(info.message.indexOf('99999') >= 0).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  authenticateXbl
  // ----------------------------------------------------------
  describe('XboxLiveAuth.authenticateXbl', () => {
    it('200 → 解析 token + uhs', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: successBody('XBL_TOKEN_VALUE', 'USER_HASH'),
      });
      let r: XblTokenResult = await new XboxLiveAuth(fake).authenticateXbl('MS_AT');
      expect(r.token).assertEqual('XBL_TOKEN_VALUE');
      expect(r.uhs).assertEqual('USER_HASH');
    });

    it('请求体含 RpsTicket=d=<MS_token>', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: successBody('T', 'U'),
      });
      await new XboxLiveAuth(fake).authenticateXbl('THE_MS_TOKEN');
      let call = fake.lastCall();
      expect(call.method).assertEqual('POST_JSON');
      expect(call.url).assertEqual(XBL_AUTH_URL);
      // body 是 JSON 字符串，包含 d=THE_MS_TOKEN
      expect(call.body.indexOf('"RpsTicket":"d=THE_MS_TOKEN"') >= 0).assertTrue();
      expect(call.body.indexOf('"AuthMethod":"RPS"') >= 0).assertTrue();
      expect(call.body.indexOf('"RelyingParty":"http://auth.xboxlive.com"') >= 0).assertTrue();
    });

    it('请求带 x-xbl-contract-version: 1 头', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: successBody('T', 'U'),
      });
      await new XboxLiveAuth(fake).authenticateXbl('AT');
      let h = fake.lastCall().headers;
      expect(h !== undefined).assertTrue();
      expect((h as Map<string, string>).get('x-xbl-contract-version')).assertEqual('1');
    });

    it('200 但缺 Token → 抛 XboxAuthError', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: ((): string => {
          let b: FakeXblBodyMissingToken = { DisplayClaims: { xui: [{ uhs: 'U' }] } };
          return JSON.stringify(b);
        })(),
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authenticateXbl('AT');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as XboxAuthError).stage).assertEqual('xbl');
    });

    it('200 但缺 uhs → 抛 XboxAuthError', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: ((): string => {
          let b: FakeXblBodyEmptyXui = { Token: 'T', DisplayClaims: { xui: [] } };
          return JSON.stringify(b);
        })(),
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authenticateXbl('AT');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
    });

    it('5xx → XboxAuthError stage=xbl', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XBL_AUTH_URL, {
        statusCode: 503,
        body: '<html>Service Unavailable</html>',
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authenticateXbl('AT');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as XboxAuthError).stage).assertEqual('xbl');
      expect((caught as XboxAuthError).httpStatus).assertEqual(503);
    });
  });

  // ----------------------------------------------------------
  //  authorizeXsts
  // ----------------------------------------------------------
  describe('XboxLiveAuth.authorizeXsts', () => {
    it('200 → 解析 token + uhs', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XSTS_AUTH_URL, {
        statusCode: 200,
        body: successBody('XSTS_TOKEN', 'UHS_VALUE'),
      });
      let r = await new XboxLiveAuth(fake).authorizeXsts('XBL_TOKEN');
      expect(r.token).assertEqual('XSTS_TOKEN');
      expect(r.uhs).assertEqual('UHS_VALUE');
    });

    it('请求体含 SandboxId=RETAIL + UserTokens 数组 + Minecraft RelyingParty', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XSTS_AUTH_URL, {
        statusCode: 200,
        body: successBody('T', 'U'),
      });
      await new XboxLiveAuth(fake).authorizeXsts('XBL_X');
      let call = fake.lastCall();
      expect(call.url).assertEqual(XSTS_AUTH_URL);
      expect(call.body.indexOf('"SandboxId":"RETAIL"') >= 0).assertTrue();
      expect(call.body.indexOf('"UserTokens":["XBL_X"]') >= 0).assertTrue();
      expect(call.body.indexOf('rp://api.minecraftservices.com/') >= 0).assertTrue();
    });

    it('401 + XErr=2148916233 → XboxAuthError 含中文 Xbox 提示', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XSTS_AUTH_URL, {
        statusCode: 401,
        body: xerrBody(2148916233),
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authorizeXsts('XBL');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
      let err = caught as XboxAuthError;
      expect(err.stage).assertEqual('xsts');
      expect(err.xerr).assertEqual(2148916233);
      expect(err.userMessage.indexOf('Xbox') >= 0).assertTrue();
    });

    it('401 + XErr=2148916238 → 未成年 family 提示', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XSTS_AUTH_URL, {
        statusCode: 401,
        body: xerrBody(2148916238),
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authorizeXsts('XBL');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
      expect((caught as XboxAuthError).xerr).assertEqual(2148916238);
      expect((caught as XboxAuthError).userMessage.indexOf('家庭') >= 0).assertTrue();
    });

    it('401 但无 XErr 字段 → 通用错误带 server message', 0, async () => {
      let fake = new FakeHttpClient();
      fake.setResponse(XSTS_AUTH_URL, {
        statusCode: 401,
        body: ((): string => {
          let b: FakeXblBodyMessageOnly = { Message: 'token expired' };
          return JSON.stringify(b);
        })(),
      });
      let caught: XboxAuthError | null = null;
      try {
        await new XboxLiveAuth(fake).authorizeXsts('XBL');
      } catch (e) {
        caught = e as XboxAuthError;
      }
      expect(caught !== null).assertTrue();
      let err = caught as XboxAuthError;
      expect(err.xerr).assertEqual(0);  // 没 XErr
      expect(err.userMessage.indexOf('token expired') >= 0).assertTrue();
    });
  });
}

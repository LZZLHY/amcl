/**
 * MicrosoftAccount.test.ets — 微软账户类集成测试（验证 5 步链路串接）
 *
 * 覆盖：
 *   - fromRecord       : 各种 invalid 输入 → null；valid → 字段对应
 *   - serialize        : 字段完整 + payload 含 refreshToken；roundtrip 等价
 *   - fillProfile      : 4 个 setter 调用 + userType=msa
 *   - getDisplayName   : == username
 *   - isUsable         : refreshToken 空 → false
 *   - getAccessToken   : fresh → 缓存 / expired → 触发 refresh
 *   - refresh          : 4 个端点按序调用 / 空 refreshToken 抛错 / fresh 时 no-op
 *   - completeMicrosoftLogin : 跑完整 4 步并返回 InteractiveLoginArgs
 *
 * 注入 FakeHttpClient，用真实 MicrosoftOAuth/XboxLiveAuth/MinecraftProfileApi（薄壳）。
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { describe, it, expect } from '@ohos/hypium';
import { AccountType, AccountRecord, EncryptedBlob, ProfileFieldSink } from 'account';
import {
  MicrosoftAccount,
  MicrosoftAccountDeps,
  InteractiveLoginArgs,
  completeMicrosoftLogin,
} from 'account';
import { HttpClient, HttpResponse } from 'account';
import { MicrosoftOAuth, MsaTokenSet } from 'account';
import { XboxLiveAuth } from 'account';
import { MinecraftProfileApi } from 'account';
import {
  MSA_TOKEN_URL,
  XBL_AUTH_URL,
  XSTS_AUTH_URL,
  MC_BEARER_URL,
  MC_PROFILE_URL,
} from 'commons';

// ============================================================
//  FakeHttpClient（按 url 返回预设 + 记录调用顺序）
// ============================================================

class FakeHttpClient implements HttpClient {
  private responses: Map<string, HttpResponse> = new Map();
  callOrder: string[] = [];

  setResponse(url: string, response: HttpResponse): void {
    this.responses.set(url, response);
  }

  async postForm(url: string, _body: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.callOrder.push(url);
    return this.lookup(url);
  }
  async postJson(url: string, _body: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.callOrder.push(url);
    return this.lookup(url);
  }
  async get(url: string, _bearer: string, _h?: Map<string, string>): Promise<HttpResponse> {
    this.callOrder.push(url);
    return this.lookup(url);
  }
  // putJson / delete 是 HttpClient 后加的（Mojang Profile API 改 cape 等）。
  // 本套用例只验证登录链路的调用顺序，但 fake 必须实现完整接口，否则整个测试模块
  // 编译失败；这里同样只记 url，与其余动作保持一致。
  async putJson(url: string, _bearer: string, _jsonBody: string,
                _h?: Map<string, string>): Promise<HttpResponse> {
    this.callOrder.push(url);
    return this.lookup(url);
  }
  async delete(url: string, _bearer: string,
               _h?: Map<string, string>): Promise<HttpResponse> {
    this.callOrder.push(url);
    return this.lookup(url);
  }

  private lookup(url: string): HttpResponse {
    let r = this.responses.get(url);
    if (!r) throw new Error('FakeHttpClient: no mock for ' + url);
    return r;
  }
}

// ============================================================
//  测试 fixture
// ============================================================

interface FakePayload {
  refreshToken: string;
  mcAccessToken: string;
  mcExpiresAt: number;
}

function buildValidRecord(args: BuildRecordArgs): AccountRecord {
  let payload: FakePayload = {
    refreshToken: args.refreshToken,
    mcAccessToken: args.mcAccessToken,
    mcExpiresAt: args.mcExpiresAt,
  };
  let encrypted: EncryptedBlob = {
    iv: '',
    ciphertext: JSON.stringify(payload),
    tag: '',
  };
  return {
    version: 1,
    id: args.id,
    type: AccountType.MICROSOFT,
    username: args.username,
    uuid: args.uuid,
    createdAt: args.createdAt,
    encrypted: encrypted,
  };
}

interface BuildRecordArgs {
  id: string;
  username: string;
  uuid: string;
  createdAt: number;
  refreshToken: string;
  mcAccessToken: string;
  mcExpiresAt: number;
}

// 给 deps 准备一组通过性 mock：refresh 4 步全 OK
function setupHappyPathHttp(http: FakeHttpClient): void {
  http.setResponse(MSA_TOKEN_URL, {
    statusCode: 200,
    body: '{"access_token":"NEW_MS_AT","refresh_token":"NEW_RT","expires_in":3600}',
  });
  http.setResponse(XBL_AUTH_URL, {
    statusCode: 200,
    body: '{"Token":"XBL_T","DisplayClaims":{"xui":[{"uhs":"UHS_VALUE"}]}}',
  });
  http.setResponse(XSTS_AUTH_URL, {
    statusCode: 200,
    body: '{"Token":"XSTS_T","DisplayClaims":{"xui":[{"uhs":"UHS_VALUE"}]}}',
  });
  http.setResponse(MC_BEARER_URL, {
    statusCode: 200,
    body: '{"access_token":"MC_AT_NEW","token_type":"Bearer","expires_in":86400}',
  });
  // refresh() 末尾会顺手调 profile 同步 skin/cape；此 mock 让该调用成功
  http.setResponse(MC_PROFILE_URL, {
    statusCode: 200,
    body: '{"id":"069a79f444e94726a5befca90e38aaf5","name":"Steve",'
      + '"skins":[{"id":"sk1","state":"ACTIVE","url":"http://x/skin","variant":"CLASSIC"}],'
      + '"capes":[{"id":"cp1","state":"ACTIVE","url":"http://x/cape","alias":"Vanilla"}]}',
  });
}

function makeDeps(http: FakeHttpClient): MicrosoftAccountDeps {
  return {
    oauth: new MicrosoftOAuth(http),
    xbl: new XboxLiveAuth(http),
    mc: new MinecraftProfileApi(http),
  };
}

// 假的 ProfileFieldSink，记录 setter 调用顺序与值
class FakeSink implements ProfileFieldSink {
  username: string = '';
  uuid: string = '';
  accessToken: string = '';
  userType: string = '';
  callOrder: string[] = [];

  setUsername(name: string): ProfileFieldSink {
    this.username = name;
    this.callOrder.push('username');
    return this;
  }
  setUuid(uuid: string): ProfileFieldSink {
    this.uuid = uuid;
    this.callOrder.push('uuid');
    return this;
  }
  setAccessToken(token: string): ProfileFieldSink {
    this.accessToken = token;
    this.callOrder.push('accessToken');
    return this;
  }
  setUserType(type: string): ProfileFieldSink {
    this.userType = type;
    this.callOrder.push('userType');
    return this;
  }
}

// ============================================================
//  测试主体
// ============================================================

export default function microsoftAccountTest() {

  // ----------------------------------------------------------
  //  fromRecord
  // ----------------------------------------------------------
  describe('MicrosoftAccount.fromRecord', () => {
    it('type mismatch → null', 0, () => {
      let rec = buildValidRecord({
        id: 'A', username: 'u', uuid: 'x', createdAt: 100,
        refreshToken: 'RT', mcAccessToken: '', mcExpiresAt: 0,
      });
      rec.type = AccountType.OFFLINE;  // 故意改错
      let acc = MicrosoftAccount.fromRecord(rec);
      expect(acc === null).assertTrue();
    });

    it('missing encrypted → null', 0, () => {
      let rec: AccountRecord = {
        version: 1, id: 'A', type: AccountType.MICROSOFT,
        username: 'u', uuid: 'x', createdAt: 100,
      };
      let acc = MicrosoftAccount.fromRecord(rec);
      expect(acc === null).assertTrue();
    });

    it('encrypted.ciphertext 为非法 JSON → null', 0, () => {
      let rec: AccountRecord = {
        version: 1, id: 'A', type: AccountType.MICROSOFT,
        username: 'u', uuid: 'x', createdAt: 100,
        encrypted: { iv: '', ciphertext: '{not valid json', tag: '' },
      };
      let acc = MicrosoftAccount.fromRecord(rec);
      expect(acc === null).assertTrue();
    });

    it('payload 缺 refreshToken → null', 0, () => {
      let rec: AccountRecord = {
        version: 1, id: 'A', type: AccountType.MICROSOFT,
        username: 'u', uuid: 'x', createdAt: 100,
        encrypted: { iv: '', ciphertext: '{"refreshToken":"","mcAccessToken":"","mcExpiresAt":0}', tag: '' },
      };
      let acc = MicrosoftAccount.fromRecord(rec);
      expect(acc === null).assertTrue();
    });

    it('valid record → 字段对应', 0, () => {
      let rec = buildValidRecord({
        id: 'ID1', username: 'Steve', uuid: '069a79f4-44e9-4726-a5be-fca90e38aaf5',
        createdAt: 12345, refreshToken: 'RT_X', mcAccessToken: 'MC_X', mcExpiresAt: 999999999,
      });
      let http = new FakeHttpClient();
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      expect(acc !== null).assertTrue();
      let a = acc as MicrosoftAccount;
      expect(a.id).assertEqual('ID1');
      expect(a.username).assertEqual('Steve');
      expect(a.uuid).assertEqual('069a79f4-44e9-4726-a5be-fca90e38aaf5');
      expect(a.createdAt).assertEqual(12345);
      expect(a.type).assertEqual(AccountType.MICROSOFT);
    });
  });

  // ----------------------------------------------------------
  //  serialize
  // ----------------------------------------------------------
  describe('MicrosoftAccount.serialize', () => {
    it('schema 完整：version=1 + type=microsoft + encrypted 含 refreshToken', 0, () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'v', createdAt: 1,
        refreshToken: 'RTX', mcAccessToken: 'MCX', mcExpiresAt: 100,
      });
      let http = new FakeHttpClient();
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      let out = (acc as MicrosoftAccount).serialize();
      expect(out.version).assertEqual(1);
      expect(out.type).assertEqual(AccountType.MICROSOFT);
      expect(out.id).assertEqual('X');
      expect(out.username).assertEqual('u');
      expect(out.encrypted !== undefined).assertTrue();
      let cipher = (out.encrypted as EncryptedBlob).ciphertext;
      expect(cipher.indexOf('RTX') >= 0).assertTrue();
      expect(cipher.indexOf('MCX') >= 0).assertTrue();
    });

    it('serialize → fromRecord 往返保留状态', 0, () => {
      let original = buildValidRecord({
        id: 'R', username: 'Notch', uuid: 'u',
        createdAt: 999, refreshToken: 'RT_ORIG', mcAccessToken: 'MC_ORIG', mcExpiresAt: 7777,
      });
      let http = new FakeHttpClient();
      let acc1 = MicrosoftAccount.fromRecord(original, makeDeps(http));
      let serialized = (acc1 as MicrosoftAccount).serialize();
      let acc2 = MicrosoftAccount.fromRecord(serialized, makeDeps(http));
      expect(acc2 !== null).assertTrue();
      let a2 = acc2 as MicrosoftAccount;
      expect(a2.id).assertEqual('R');
      expect(a2.username).assertEqual('Notch');
      expect(a2.uuid).assertEqual('u');
      expect(a2.createdAt).assertEqual(999);
      // 验证 mcAccessToken 也 round-trip 了：通过 fillProfile 看 accessToken
      let sink = new FakeSink();
      a2.fillProfile(sink);
      expect(sink.accessToken).assertEqual('MC_ORIG');
    });
  });

  // ----------------------------------------------------------
  //  fillProfile
  // ----------------------------------------------------------
  describe('MicrosoftAccount.fillProfile', () => {
    it('4 个 setter 都被调到 + userType=msa', 0, () => {
      let rec = buildValidRecord({
        id: 'X', username: 'NameY', uuid: 'UUID-Z', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC_TOK', mcExpiresAt: 99999999999,
      });
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(new FakeHttpClient()));
      let sink = new FakeSink();
      (acc as MicrosoftAccount).fillProfile(sink);
      expect(sink.username).assertEqual('NameY');
      expect(sink.uuid).assertEqual('UUID-Z');
      expect(sink.accessToken).assertEqual('MC_TOK');
      expect(sink.userType).assertEqual('msa');
      expect(sink.callOrder.length).assertEqual(4);
    });
  });

  // ----------------------------------------------------------
  //  getDisplayName / isUsable
  // ----------------------------------------------------------
  describe('MicrosoftAccount basic accessors', () => {
    it('getDisplayName == username', 0, () => {
      let rec = buildValidRecord({
        id: 'X', username: 'Alex', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: '', mcExpiresAt: 0,
      });
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(new FakeHttpClient()));
      expect((acc as MicrosoftAccount).getDisplayName()).assertEqual('Alex');
    });

    it('isUsable: refreshToken 非空 → true', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT', mcAccessToken: '', mcExpiresAt: 0,
      });
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(new FakeHttpClient()));
      let r = await (acc as MicrosoftAccount).isUsable();
      expect(r).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  getAccessToken：缓存 / 过期 触发 refresh
  // ----------------------------------------------------------
  describe('MicrosoftAccount.getAccessToken', () => {
    it('mcToken 仍 fresh → 直接返回缓存，不发 HTTP', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT',
        mcAccessToken: 'CACHED_TOKEN',
        // 1 小时后过期
        mcExpiresAt: Date.now() + 3600 * 1000,
      });
      let http = new FakeHttpClient();
      // 不设任何 mock，但因为不会发 HTTP 应该不抛
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      let tok = await (acc as MicrosoftAccount).getAccessToken();
      expect(tok).assertEqual('CACHED_TOKEN');
      expect(http.callOrder.length).assertEqual(0);
    });

    it('mcToken 已过期 → 触发 refresh，返回新 token', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'OLD_RT',
        mcAccessToken: 'STALE_TOKEN',
        // 已过期（1 小时前）
        mcExpiresAt: Date.now() - 3600 * 1000,
      });
      let http = new FakeHttpClient();
      setupHappyPathHttp(http);
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      let tok = await (acc as MicrosoftAccount).getAccessToken();
      expect(tok).assertEqual('MC_AT_NEW');
    });
  });

  // ----------------------------------------------------------
  //  refresh：5 步链路（实际是 4 步，profile 不重拉）
  // ----------------------------------------------------------
  describe('MicrosoftAccount.refresh', () => {
    it('5 个端点按序调用 (MSA → XBL → XSTS → MC bearer → profile)', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT', mcAccessToken: '', mcExpiresAt: 0,
      });
      let http = new FakeHttpClient();
      setupHappyPathHttp(http);
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      await (acc as MicrosoftAccount).refresh();
      // M2.5 起 refresh 末尾会顺手调 profile 同步 skin/cape
      expect(http.callOrder.length).assertEqual(5);
      expect(http.callOrder[0]).assertEqual(MSA_TOKEN_URL);
      expect(http.callOrder[1]).assertEqual(XBL_AUTH_URL);
      expect(http.callOrder[2]).assertEqual(XSTS_AUTH_URL);
      expect(http.callOrder[3]).assertEqual(MC_BEARER_URL);
      expect(http.callOrder[4]).assertEqual(MC_PROFILE_URL);
    });

    it('refresh 完成后新 mcAccessToken/expiresAt 写入', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT', mcAccessToken: 'OLD', mcExpiresAt: 0,
      });
      let http = new FakeHttpClient();
      setupHappyPathHttp(http);
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      let before = Date.now();
      await (acc as MicrosoftAccount).refresh();
      let sink = new FakeSink();
      (acc as MicrosoftAccount).fillProfile(sink);
      expect(sink.accessToken).assertEqual('MC_AT_NEW');
      // expiresAt 应在 [before + (86400-60)*1000, ...]
      let serialized = (acc as MicrosoftAccount).serialize();
      let payload = JSON.parse((serialized.encrypted as EncryptedBlob).ciphertext) as FakePayload;
      expect(payload.mcExpiresAt >= before + (86400 - 60) * 1000).assertTrue();
    });

    it('MSA 下发新 refresh_token → 写回新值（旧值丢弃）', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'OLD_RT', mcAccessToken: '', mcExpiresAt: 0,
      });
      let http = new FakeHttpClient();
      setupHappyPathHttp(http);  // refresh_token = 'NEW_RT'
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      await (acc as MicrosoftAccount).refresh();
      let serialized = (acc as MicrosoftAccount).serialize();
      let payload = JSON.parse((serialized.encrypted as EncryptedBlob).ciphertext) as FakePayload;
      expect(payload.refreshToken).assertEqual('NEW_RT');
    });

    it('mcToken 仍 fresh → refresh 是 no-op（不发 HTTP）', 0, async () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT',
        mcAccessToken: 'STILL_FRESH',
        mcExpiresAt: Date.now() + 3600 * 1000,
      });
      let http = new FakeHttpClient();
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(http));
      await (acc as MicrosoftAccount).refresh();
      expect(http.callOrder.length).assertEqual(0);
    });

    it('refreshToken 空 → 抛错（账户需要重新登录）', 0, async () => {
      // 直接用 fromInteractiveLogin 构造一个空 refreshToken 的账户
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: '', mcAccessToken: 'CACHED', mcExpiresAt: 0,
      };
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(new FakeHttpClient()));
      let caught: Error | null = null;
      try {
        await acc.refresh();
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== null).assertTrue();
      expect((caught as Error).message.indexOf('refreshToken') >= 0).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  completeMicrosoftLogin：跑完整 4 步并返回 InteractiveLoginArgs
  // ----------------------------------------------------------
  describe('completeMicrosoftLogin', () => {
    it('4 个端点 (XBL → XSTS → MC bearer → profile) 按序 + 返回 InteractiveLoginArgs', 0, async () => {
      let http = new FakeHttpClient();
      // 不需要 MSA_TOKEN_URL，因为这个工具假设上游已拿到 MS token
      http.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XBL_T","DisplayClaims":{"xui":[{"uhs":"UHSvalue"}]}}',
      });
      http.setResponse(XSTS_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XSTS_T","DisplayClaims":{"xui":[{"uhs":"UHSvalue"}]}}',
      });
      http.setResponse(MC_BEARER_URL, {
        statusCode: 200,
        body: '{"access_token":"MC_AT","token_type":"Bearer","expires_in":86400}',
      });
      http.setResponse(MC_PROFILE_URL, {
        statusCode: 200,
        body: '{"id":"069a79f444e94726a5befca90e38aaf5","name":"Steve"}',
      });
      let msTokens: MsaTokenSet = {
        accessToken: 'MS_AT',
        refreshToken: 'MS_RT',
        expiresAt: Date.now() + 3600 * 1000,
      };
      let args = await completeMicrosoftLogin(msTokens, 'NEW_ID', makeDeps(http));
      expect(http.callOrder.length).assertEqual(4);
      expect(http.callOrder[0]).assertEqual(XBL_AUTH_URL);
      expect(http.callOrder[1]).assertEqual(XSTS_AUTH_URL);
      expect(http.callOrder[2]).assertEqual(MC_BEARER_URL);
      expect(http.callOrder[3]).assertEqual(MC_PROFILE_URL);
      expect(args.id).assertEqual('NEW_ID');
      expect(args.username).assertEqual('Steve');
      expect(args.uuid).assertEqual('069a79f4-44e9-4726-a5be-fca90e38aaf5');
      expect(args.refreshToken).assertEqual('MS_RT');
      expect(args.mcAccessToken).assertEqual('MC_AT');
    });

    it('profile 含 skin/cape → InteractiveLoginArgs 透传', 0, async () => {
      let http = new FakeHttpClient();
      http.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XBL","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(XSTS_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XSTS","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(MC_BEARER_URL, {
        statusCode: 200,
        body: '{"access_token":"MC","token_type":"Bearer","expires_in":86400}',
      });
      http.setResponse(MC_PROFILE_URL, {
        statusCode: 200,
        body: '{"id":"069a79f444e94726a5befca90e38aaf5","name":"Steve",'
          + '"skins":[{"id":"sk1","state":"ACTIVE","url":"http://x/skin","variant":"SLIM"}],'
          + '"capes":[{"id":"cp1","state":"ACTIVE","url":"http://x/migrator","alias":"Migrator"}]}',
      });
      let msTokens: MsaTokenSet = {
        accessToken: 'MS_AT', refreshToken: 'MS_RT',
        expiresAt: Date.now() + 3600 * 1000,
      };
      let args = await completeMicrosoftLogin(msTokens, 'NEW_ID', makeDeps(http));
      expect(args.skinUrl).assertEqual('http://x/skin');
      expect(args.skinVariant).assertEqual('SLIM');
      expect(args.capeUrl).assertEqual('http://x/migrator');
      expect(args.capeAlias).assertEqual('Migrator');
    });

    it('profile 无披风 → capeUrl 留 undefined', 0, async () => {
      let http = new FakeHttpClient();
      http.setResponse(XBL_AUTH_URL, {
        statusCode: 200, body: '{"Token":"XBL","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(XSTS_AUTH_URL, {
        statusCode: 200, body: '{"Token":"XSTS","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(MC_BEARER_URL, {
        statusCode: 200, body: '{"access_token":"MC","token_type":"Bearer","expires_in":86400}',
      });
      http.setResponse(MC_PROFILE_URL, {
        statusCode: 200,
        body: '{"id":"069a79f444e94726a5befca90e38aaf5","name":"Steve",'
          + '"skins":[{"id":"sk1","state":"ACTIVE","url":"http://x/skin","variant":"CLASSIC"}],'
          + '"capes":[]}',
      });
      let msTokens: MsaTokenSet = {
        accessToken: 'MS_AT', refreshToken: 'MS_RT', expiresAt: Date.now() + 3600 * 1000,
      };
      let args = await completeMicrosoftLogin(msTokens, 'X', makeDeps(http));
      expect(args.skinUrl).assertEqual('http://x/skin');
      expect(args.capeUrl === undefined).assertTrue();
      expect(args.capeAlias === undefined).assertTrue();
    });
  });

  // ----------------------------------------------------------
  //  M2.5：skin/cape 持久化与还原
  // ----------------------------------------------------------
  describe('MicrosoftAccount · skin/cape', () => {
    it('fromInteractiveLogin 带 skin/cape → getter 返回正确值', 0, () => {
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC', mcExpiresAt: 0,
        skinUrl: 'http://x/skin', skinVariant: 'SLIM',
        capeUrl: 'http://x/cape', capeAlias: 'Migrator',
      };
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(new FakeHttpClient()));
      expect(acc.getSkinUrl()).assertEqual('http://x/skin');
      expect(acc.getSkinVariant()).assertEqual('SLIM');
      expect(acc.getCapeUrl()).assertEqual('http://x/cape');
      expect(acc.getCapeAlias()).assertEqual('Migrator');
    });

    it('fromInteractiveLogin 不带 skin/cape → 4 个 getter 全 null', 0, () => {
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC', mcExpiresAt: 0,
      };
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(new FakeHttpClient()));
      expect(acc.getSkinUrl()).assertNull();
      expect(acc.getSkinVariant()).assertNull();
      expect(acc.getCapeUrl()).assertNull();
      expect(acc.getCapeAlias()).assertNull();
    });

    it('serialize → record 含 skinUrl/capeUrl 字段', 0, () => {
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC', mcExpiresAt: 0,
        skinUrl: 'http://x/skin', skinVariant: 'CLASSIC',
        capeUrl: 'http://x/cape', capeAlias: 'Vanilla',
      };
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(new FakeHttpClient()));
      let rec = acc.serialize();
      expect(rec.skinUrl).assertEqual('http://x/skin');
      expect(rec.skinVariant).assertEqual('CLASSIC');
      expect(rec.capeUrl).assertEqual('http://x/cape');
      expect(rec.capeAlias).assertEqual('Vanilla');
    });

    it('fromRecord 还原 skin/cape', 0, () => {
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC', mcExpiresAt: 0,
      });
      rec.skinUrl = 'http://x/skin';
      rec.skinVariant = 'SLIM';
      rec.capeUrl = 'http://x/cape';
      rec.capeAlias = 'Migrator';
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(new FakeHttpClient()));
      expect(acc !== null).assertTrue();
      let a = acc as MicrosoftAccount;
      expect(a.getSkinUrl()).assertEqual('http://x/skin');
      expect(a.getCapeAlias()).assertEqual('Migrator');
    });

    it('旧 record 无 skin/cape → fromRecord graceful，getter null', 0, () => {
      // 模拟 M2.5 之前持久化的账户记录（无 skin/cape 字段）
      let rec = buildValidRecord({
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'R', mcAccessToken: 'MC', mcExpiresAt: 0,
      });
      let acc = MicrosoftAccount.fromRecord(rec, makeDeps(new FakeHttpClient()));
      expect(acc !== null).assertTrue();
      let a = acc as MicrosoftAccount;
      expect(a.getSkinUrl()).assertNull();
      expect(a.getCapeUrl()).assertNull();
    });

    it('refresh 后 skin/cape 同步更新', 0, async () => {
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT',
        mcAccessToken: 'STALE',
        mcExpiresAt: Date.now() - 1000,  // 已过期，触发 refresh
        skinUrl: 'http://OLD/skin',
        capeUrl: 'http://OLD/cape',
      };
      let http = new FakeHttpClient();
      setupHappyPathHttp(http);  // profile 返回新的 skin/cape
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(http));
      await acc.refresh();
      // 新 mock 返回 skin url=http://x/skin, cape url=http://x/cape
      expect(acc.getSkinUrl()).assertEqual('http://x/skin');
      expect(acc.getCapeUrl()).assertEqual('http://x/cape');
      expect(acc.getCapeAlias()).assertEqual('Vanilla');
    });

    it('refresh 中 profile 失败 → 不阻断；token 仍写入', 0, async () => {
      let args: InteractiveLoginArgs = {
        id: 'X', username: 'u', uuid: 'u', createdAt: 1,
        refreshToken: 'RT', mcAccessToken: '', mcExpiresAt: 0,
      };
      let http = new FakeHttpClient();
      // 不调 setupHappyPathHttp；手动设前 4 步 OK，profile 故意 500
      http.setResponse(MSA_TOKEN_URL, {
        statusCode: 200,
        body: '{"access_token":"NEW_MS","refresh_token":"NEW_RT","expires_in":3600}',
      });
      http.setResponse(XBL_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XBL","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(XSTS_AUTH_URL, {
        statusCode: 200,
        body: '{"Token":"XSTS","DisplayClaims":{"xui":[{"uhs":"U"}]}}',
      });
      http.setResponse(MC_BEARER_URL, {
        statusCode: 200,
        body: '{"access_token":"MC_NEW","token_type":"Bearer","expires_in":86400}',
      });
      http.setResponse(MC_PROFILE_URL, { statusCode: 500, body: 'oops' });
      let acc = MicrosoftAccount.fromInteractiveLogin(args, makeDeps(http));
      await acc.refresh();  // 不应抛
      // token 已更新，skin/cape 仍 null
      let sink = new FakeSink();
      acc.fillProfile(sink);
      expect(sink.accessToken).assertEqual('MC_NEW');
      expect(acc.getSkinUrl()).assertNull();
    });
  });
}

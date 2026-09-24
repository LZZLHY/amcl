/**
 * OfflineAccount.test.ets — 离线账户单元测试
 *
 * 覆盖范围（全部为纯函数 / 同步可测）：
 *   - deriveOfflineUuid    : 用户名 → 稳定 UUID（同输入同输出，不同输入不同输出，36 字符 8-4-4-4-12 格式）
 *   - createOfflineAccount : 工厂方法（默认值、空 username 处理）
 *   - fillProfile          : 4 个 setter 调用次数与参数（用 fake sink）
 *   - serialize            : schema 字段完整、type=legacy、version=1
 *   - getDisplayName       : 等于 username
 *   - refresh / getAccessToken / isUsable : 异步语义（resolve 与状态）
 *
 * 不在本测试范围内：
 *   - AccountStorage 持久化（属于 AccountStorage.test.ets）
 *   - AccountManager 多账户管理（属于 AccountManager.test.ets）
 *   - LaunchProfileBuilder 真实 build（属于集成测试，依赖文件系统）
 *
 * 创建日期：2026-05-09（M1）
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  AccountType,
  AccountRecord,
  ProfileFieldSink,
} from 'account';
import {
  OfflineAccount,
  deriveOfflineUuid,
  OFFLINE_ACCESS_TOKEN_PLACEHOLDER,
} from 'account';

// ============================================================
//  Fake ProfileFieldSink — 记录 setter 调用，便于断言
// ============================================================

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
//  UUID 格式校验（36 字符，5 段，正则 8-4-4-4-12 hex）
// ============================================================

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default function offlineAccountTest() {

  // ============================================================
  //  deriveOfflineUuid — UUID 派生函数
  // ============================================================
  describe('OfflineAccount.deriveOfflineUuid', () => {

    it('返回值符合 36 字符 UUID 格式（8-4-4-4-12 hex）', 0, () => {
      let uuid = deriveOfflineUuid('Steve');
      expect(uuid.length).assertEqual(36);
      expect(UUID_REGEX.test(uuid)).assertTrue();
    });

    it('相同 username 派生稳定（多次调用结果一致）', 0, () => {
      let u1 = deriveOfflineUuid('Steve');
      let u2 = deriveOfflineUuid('Steve');
      let u3 = deriveOfflineUuid('Steve');
      expect(u1).assertEqual(u2);
      expect(u2).assertEqual(u3);
    });

    it('不同 username 派生结果不同', 0, () => {
      let u1 = deriveOfflineUuid('Steve');
      let u2 = deriveOfflineUuid('Alex');
      let u3 = deriveOfflineUuid('Notch');
      expect(u1 === u2).assertFalse();
      expect(u2 === u3).assertFalse();
      expect(u1 === u3).assertFalse();
    });

    it('空 username 也能派生（返回合法 UUID 不抛错）', 0, () => {
      let uuid = deriveOfflineUuid('');
      expect(UUID_REGEX.test(uuid)).assertTrue();
    });

    it('大小写敏感（Steve 与 steve 派生不同）', 0, () => {
      let upper = deriveOfflineUuid('Steve');
      let lower = deriveOfflineUuid('steve');
      expect(upper === lower).assertFalse();
    });

    it('Unicode 用户名也能派生（中文/emoji）', 0, () => {
      let zh = deriveOfflineUuid('阿凉');
      let emoji = deriveOfflineUuid('🎮Player');
      expect(UUID_REGEX.test(zh)).assertTrue();
      expect(UUID_REGEX.test(emoji)).assertTrue();
      expect(zh === emoji).assertFalse();
    });

  });

  // ============================================================
  //  OfflineAccount 构造与字段
  // ============================================================
  describe('OfflineAccount 构造与字段', () => {

    it('create 后 username/uuid/type/createdAt 字段就位', 0, () => {
      let acc = OfflineAccount.create('TestPlayer');
      expect(acc.username).assertEqual('TestPlayer');
      expect(acc.uuid.length).assertEqual(36);
      expect(acc.type).assertEqual(AccountType.OFFLINE);
      expect(acc.createdAt > 0).assertTrue();
      expect(acc.id.length > 0).assertTrue();
    });

    it('create 同名账户：uuid 一致（基于 username 派生），id 不同（独立账户实例）', 0, () => {
      let a = OfflineAccount.create('Steve');
      let b = OfflineAccount.create('Steve');
      expect(a.uuid).assertEqual(b.uuid);
      expect(a.id === b.id).assertFalse();
    });

    it('空 username 退化为默认 MCPlayer', 0, () => {
      let acc = OfflineAccount.create('');
      expect(acc.username).assertEqual('MCPlayer');
    });

    it('username 含两端空格自动 trim', 0, () => {
      let acc = OfflineAccount.create('  Steve  ');
      expect(acc.username).assertEqual('Steve');
    });

  });

  // ============================================================
  //  fillProfile — 4 个 setter 全部调用一次
  // ============================================================
  describe('OfflineAccount.fillProfile', () => {

    it('4 个 setter 各调用恰好一次', 0, () => {
      let acc = OfflineAccount.create('Steve');
      let sink = new FakeSink();
      acc.fillProfile(sink);
      expect(sink.callOrder.length).assertEqual(4);
      expect(sink.callOrder.indexOf('username') >= 0).assertTrue();
      expect(sink.callOrder.indexOf('uuid') >= 0).assertTrue();
      expect(sink.callOrder.indexOf('accessToken') >= 0).assertTrue();
      expect(sink.callOrder.indexOf('userType') >= 0).assertTrue();
    });

    it('注入字段值与账户字段一致', 0, () => {
      let acc = OfflineAccount.create('Steve');
      let sink = new FakeSink();
      acc.fillProfile(sink);
      expect(sink.username).assertEqual('Steve');
      expect(sink.uuid).assertEqual(acc.uuid);
      expect(sink.userType).assertEqual('legacy');  // AccountType.OFFLINE 的字面值
      expect(sink.accessToken.length > 0).assertTrue();
    });

    it('accessToken 是稳定占位值（OFFLINE_ACCESS_TOKEN_PLACEHOLDER）', 0, () => {
      let acc = OfflineAccount.create('Steve');
      let sink = new FakeSink();
      acc.fillProfile(sink);
      expect(sink.accessToken).assertEqual(OFFLINE_ACCESS_TOKEN_PLACEHOLDER);
    });

  });

  // ============================================================
  //  serialize / fromRecord — schema 往返
  // ============================================================
  describe('OfflineAccount.serialize / fromRecord', () => {

    it('serialize 字段完整：version=1, type=legacy, 无 encrypted', 0, () => {
      let acc = OfflineAccount.create('Steve');
      let rec: AccountRecord = acc.serialize();
      expect(rec.version).assertEqual(1);
      expect(rec.type).assertEqual(AccountType.OFFLINE);
      expect(rec.username).assertEqual('Steve');
      expect(rec.uuid).assertEqual(acc.uuid);
      expect(rec.id).assertEqual(acc.id);
      expect(rec.createdAt).assertEqual(acc.createdAt);
      expect(rec.encrypted === undefined).assertTrue();
    });

    it('serialize → fromRecord 往返：所有字段一致', 0, () => {
      let original = OfflineAccount.create('Steve');
      let rec = original.serialize();
      let restored = OfflineAccount.fromRecord(rec);
      expect(restored.id).assertEqual(original.id);
      expect(restored.username).assertEqual(original.username);
      expect(restored.uuid).assertEqual(original.uuid);
      expect(restored.type).assertEqual(original.type);
      expect(restored.createdAt).assertEqual(original.createdAt);
    });

    it('fromRecord 容错：username 缺失时退化为 MCPlayer', 0, () => {
      let badRec: AccountRecord = {
        version: 1,
        id: '11111111-1111-1111-1111-111111111111',
        type: AccountType.OFFLINE,
        username: '',
        uuid: '00000000-0000-0000-0000-000000000000',
        createdAt: Date.now(),
      };
      let acc = OfflineAccount.fromRecord(badRec);
      expect(acc.username).assertEqual('MCPlayer');
    });

  });

  // ============================================================
  //  getDisplayName / refresh / getAccessToken / isUsable
  // ============================================================
  describe('OfflineAccount 辅助方法', () => {

    it('getDisplayName 返回 username', 0, () => {
      let acc = OfflineAccount.create('Steve');
      expect(acc.getDisplayName()).assertEqual('Steve');
    });

    it('refresh 是 no-op（resolve 不抛错）', 0, async () => {
      let acc = OfflineAccount.create('Steve');
      await acc.refresh();  // 不抛错即通过
      expect(true).assertTrue();
    });

    it('getAccessToken 返回稳定占位值', 0, async () => {
      let acc = OfflineAccount.create('Steve');
      let t1 = await acc.getAccessToken();
      let t2 = await acc.getAccessToken();
      expect(t1).assertEqual(OFFLINE_ACCESS_TOKEN_PLACEHOLDER);
      expect(t2).assertEqual(OFFLINE_ACCESS_TOKEN_PLACEHOLDER);
    });

    it('isUsable 永远 true', 0, async () => {
      let acc = OfflineAccount.create('Steve');
      let usable = await acc.isUsable();
      expect(usable).assertTrue();
    });

  });

}

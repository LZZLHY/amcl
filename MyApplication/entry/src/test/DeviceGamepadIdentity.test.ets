/**
 * DeviceGamepadIdentity.test.ets — 逐设备手柄身份表（提案 B1 方案 A / 计划 §63）
 *
 * 钉住的是一条**方向性**契约：`Unknown` 与 `NotGamepad` 的正确处置相反。消费者
 * （`McGamePage.handleDeviceChange`）只在 `NotGamepad` 时跳过手柄端整端释放；把
 * "不知道"压成"不是"就会漏放，那正是用户可感知的卡键方向。
 *
 * 本文件是纯状态覆盖：不驱动 `inputDevice`、不碰 NAPI、不替代真机热插拔矩阵。
 * 平台侧的两条时序假设（remove 之后 getDeviceList 何时排除该设备、事件对象上的
 * deviceId 是否与 inputDevice 同一编号域）**官方都没有承诺**，只能真机取证，
 * 见提案 §十 第 2、6 项。
 *
 * 创建日期：2026-08-21
 */

import { describe, it, expect } from '@ohos/hypium';
import { DeviceGamepadIdentityTable, DeviceGamepadKind, normalizeDeviceId } from 'gamecontrol';

const PAD_A: number = 7;
const PAD_B: number = 8;
const KEYBOARD: number = 11;
const MOUSE: number = 12;

/** 造一份"一次成功枚举"的快照。键 = deviceId，值 = 该设备 sources 含手柄类。 */
function snapshot(entries: [number, boolean][]): Map<number, boolean> {
  const map: Map<number, boolean> = new Map();
  for (let i = 0; i < entries.length; i++) {
    map.set(entries[i][0], entries[i][1]);
  }
  return map;
}

export default function deviceGamepadIdentityTest() {
  describe('InputDeviceAbi.normalizeDeviceId', () => {
    it('⚠️ 0 是"身份不可用"的共享桶，所有不可用输入都必须落到它', 0, () => {
      // 调用方拿到 0 时必须拒绝按设备操作 —— 用 0 做 REMOVED 会取消无关设备的 owner。
      expect(normalizeDeviceId(undefined)).assertEqual(0);
      expect(normalizeDeviceId(0)).assertEqual(0);
      expect(normalizeDeviceId(-1)).assertEqual(0);
      expect(normalizeDeviceId(-0.5)).assertEqual(0);
      expect(normalizeDeviceId(Number.NaN)).assertEqual(0);
      expect(normalizeDeviceId(Number.POSITIVE_INFINITY)).assertEqual(0);
      expect(normalizeDeviceId(Number.NEGATIVE_INFINITY)).assertEqual(0);
    });

    it('合法 id 原样通过', 0, () => {
      expect(normalizeDeviceId(1)).assertEqual(1);
      expect(normalizeDeviceId(7)).assertEqual(7);
      expect(normalizeDeviceId(Number.MAX_SAFE_INTEGER)).assertEqual(Number.MAX_SAFE_INTEGER);
    });

    it('小数被截断：浮点抖动不得产生两个 owner 域', 0, () => {
      expect(normalizeDeviceId(7.9)).assertEqual(7);
      expect(normalizeDeviceId(7.0000001)).assertEqual(7);
      // 截断到 0 的小正数同样落进"不可用"桶，不能变成设备 0
      expect(normalizeDeviceId(0.9)).assertEqual(0);
    });

    it('超安全整数范围 → 0（NAPI 用 int64 读，这一侧已经不精确）', 0, () => {
      expect(normalizeDeviceId(Number.MAX_SAFE_INTEGER + 2)).assertEqual(0);
    });

    it('已知假阳性（刻意保留）：平台真的编号为 0 时无法与"字段不可用"区分', 0, () => {
      // ArkUI 没提供第二个可区分字段，所以这里不猜测。真机确认前保持 NOT VERIFIABLE。
      // 这条用例的作用是让这个局限**可执行地**存在，而不是只写在注释里。
      expect(normalizeDeviceId(0)).assertEqual(normalizeDeviceId(undefined));
    });
  });

  describe('DeviceGamepadIdentityTable', () => {
    it('枚举值数值稳定：Unknown=0 Gamepad=1 NotGamepad=2', 0, () => {
      // 这三个数值会以 `kind=N` 的形式进真机日志，是可判读契约的一部分：
      // 改动它们会让历史日志被误读，所以在这里钉住。
      expect(DeviceGamepadKind.Unknown).assertEqual(0);
      expect(DeviceGamepadKind.Gamepad).assertEqual(1);
      expect(DeviceGamepadKind.NotGamepad).assertEqual(2);
    });

    it('空表一律 Unknown —— 快照还没回来时不得声称"不是手柄"', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Unknown);
      expect(table.knownDeviceCount()).assertEqual(0);
      expect(table.knownGamepadCount()).assertEqual(0);
    });

    it('提交快照后三值各就各位；未登记的设备仍是 Unknown', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[PAD_A, true], [KEYBOARD, false]]));
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Gamepad);
      expect(table.kindOf(KEYBOARD)).assertEqual(DeviceGamepadKind.NotGamepad);
      // MOUSE 从未出现在快照里（例如 getDeviceInfoSync 对它抛了异常）：
      // 必须是 Unknown，不能因为"不在手柄名单里"就被当成 NotGamepad。
      expect(table.kindOf(MOUSE)).assertEqual(DeviceGamepadKind.Unknown);
      expect(table.knownDeviceCount()).assertEqual(2);
      expect(table.knownGamepadCount()).assertEqual(1);
    });

    it('整表替换：上一轮登记过的设备在新快照缺席后回到 Unknown，不残留', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[PAD_A, true], [KEYBOARD, false]]));
      table.commitSnapshot(snapshot([[KEYBOARD, false]]));
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Unknown);
      expect(table.kindOf(KEYBOARD)).assertEqual(DeviceGamepadKind.NotGamepad);
      expect(table.knownGamepadCount()).assertEqual(0);
    });

    it('拔 A 插 B：聚合布尔不变而表必须换（这就是无条件提交的理由）', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[PAD_A, true]]));
      // 若快照只在"聚合 gamepad 布尔发生变化"时才提交，这一步就不会提交，
      // 于是拔掉 B 时会查到 Unknown、拔掉 A 时会查到 Gamepad —— 两个都是错的。
      table.commitSnapshot(snapshot([[PAD_B, true]]));
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Unknown);
      expect(table.kindOf(PAD_B)).assertEqual(DeviceGamepadKind.Gamepad);
      expect(table.knownGamepadCount()).assertEqual(1);
    });

    it('commitSnapshot 深拷：调用方随后改动传入的 Map 不影响内部', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      const live: Map<number, boolean> = snapshot([[PAD_A, true]]);
      table.commitSnapshot(live);
      live.set(PAD_A, false);
      live.set(KEYBOARD, false);
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Gamepad);
      expect(table.kindOf(KEYBOARD)).assertEqual(DeviceGamepadKind.Unknown);
    });

    it('forget 只影响该设备，且幂等；忘掉未知设备是 no-op', 0, () => {
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[PAD_A, true], [PAD_B, true], [KEYBOARD, false]]));
      table.forget(PAD_A);
      table.forget(PAD_A);
      table.forget(MOUSE);
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Unknown);
      expect(table.kindOf(PAD_B)).assertEqual(DeviceGamepadKind.Gamepad);
      expect(table.kindOf(KEYBOARD)).assertEqual(DeviceGamepadKind.NotGamepad);
      expect(table.knownGamepadCount()).assertEqual(1);
      expect(table.knownDeviceCount()).assertEqual(2);
    });

    it('forget 之后迟到的整表提交会把记录写回来 —— 方向是保守释放，不是漏放', 0, () => {
      // 已知竞态（InputDeviceMonitor 的 handler 里有原文说明）：remove 触发的刷新是
      // 异步的，平台快照若仍含该设备，它的提交会覆盖 forget。这里把该行为钉住，
      // 并说明为什么可以接受：结果是 Gamepad ⇒ 消费者照旧释放手柄端 ⇒ 与本轮改动
      // 之前的行为相同。反方向（变成 NotGamepad ⇒ 跳过释放）才是卡键，不会发生。
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[PAD_A, true]]));
      table.forget(PAD_A);
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Unknown);
      table.commitSnapshot(snapshot([[PAD_A, true]]));
      expect(table.kindOf(PAD_A)).assertEqual(DeviceGamepadKind.Gamepad);
    });

    it('全部设备都不是手柄时 knownGamepadCount 为 0 但 knownDeviceCount 不为 0', 0, () => {
      // 两个计数器必须能区分"没有手柄"与"整张表还没有任何观测"，否则日志里
      // pads=0 有两种含义，等于一个数值不可信的计数器。
      const table = new DeviceGamepadIdentityTable();
      table.commitSnapshot(snapshot([[KEYBOARD, false], [MOUSE, false]]));
      expect(table.knownGamepadCount()).assertEqual(0);
      expect(table.knownDeviceCount()).assertEqual(2);
    });
  });
}

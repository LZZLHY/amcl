/**
 * JoystickSector.test.ets — 摇杆八向扇区判定（ArkTS 侧）
 *
 * 本文件与 `entry/src/main/cpp/tests/host/joystick_sector_test.cpp` 是**同一张规格表的
 * 两份断言**。下面 `SPEC` 里的数值必须与那个文件里的 `kSpec` 保持同步 —— 这正是抽出扇区
 * 判定的目的：同一套八向逻辑此前在 native 触控端 / 手柄端 / 触控端 ArkTS 兼容路径里写了
 * 三遍且逐字相同，但没有任何机制保证它们不分叉，谁改一份另两份不会有任何编译或测试提示，
 * 表现为"同一个八向摇杆在三端手感不同" —— 而那不会是设计决定，只会是一次漏改。
 *
 * 用**角度**驱动而不是手写 (dx, dy)：扇区边界是角度定义的，用角度生成向量再断言，
 * 边界值才能精确落在 22.5° + k·45° 上。
 *
 * 创建日期：2026-08-20（多输入端架构改进提案 B2-b）
 */

import { describe, it, expect } from '@ohos/hypium';
import { joystickSector, joystickSectorIsReleased, JoystickSectorResult } from 'gamecontrol';

interface SpecRow {
  deg: number
  w: boolean
  a: boolean
  s: boolean
  d: boolean
  name: string
}

// ============ 跨语言规格表（与 joystick_sector_test.cpp 的 kSpec 同步） ============
//
// 每个扇区取三个点：下边界内侧 +0.1°、中点、上边界内侧 −0.1°。
//
// ⚠️ **刻意不取精确边界值**（不写 202.5 这种）。原因不是宽松，而是那样测的是浮点而不是
// 逻辑：本测试用 cos/sin 造向量、实现再用 atan2 反解角度，这个往返在边界上会损失精度 ——
// native 侧实测 202.5° 反解出 202.49999999999997，落进相邻扇区；八个边界里只有这一个
// 恰好翻车，其余七个是浮点运气。而真实摇杆永远不会产生精确的 202.5000000°，
// 所以"边界点归哪一侧"不是一条有意义的契约。
//
// 有意义的契约是两条，分别由本表和 `sector_boundaries_are_adjacent` 覆盖：
//   1. 每个扇区的**内部**映射到正确的方向；
//   2. 相邻扇区在 22.5° + k·45° 附近**确实换向**（若有人把 22.5 写成 25，本表仍会全过，
//      只有第 2 条能抓住）。
const SPEC: SpecRow[] = [
  // [337.5, 360) ∪ [0, 22.5) → D
  { deg: 0.0, w: false, a: false, s: false, d: true, name: 'right-mid' },
  { deg: 22.4, w: false, a: false, s: false, d: true, name: 'right-upper' },
  { deg: 337.6, w: false, a: false, s: false, d: true, name: 'right-lower' },
  { deg: 359.9, w: false, a: false, s: false, d: true, name: 'right-wrap' },
  // [22.5, 67.5) → D + S
  { deg: 22.6, w: false, a: false, s: true, d: true, name: 'downRight-lower' },
  { deg: 45.0, w: false, a: false, s: true, d: true, name: 'downRight-mid' },
  { deg: 67.4, w: false, a: false, s: true, d: true, name: 'downRight-upper' },
  // [67.5, 112.5) → S
  { deg: 67.6, w: false, a: false, s: true, d: false, name: 'down-lower' },
  { deg: 90.0, w: false, a: false, s: true, d: false, name: 'down-mid' },
  { deg: 112.4, w: false, a: false, s: true, d: false, name: 'down-upper' },
  // [112.5, 157.5) → A + S
  { deg: 112.6, w: false, a: true, s: true, d: false, name: 'downLeft-lower' },
  { deg: 135.0, w: false, a: true, s: true, d: false, name: 'downLeft-mid' },
  { deg: 157.4, w: false, a: true, s: true, d: false, name: 'downLeft-upper' },
  // [157.5, 202.5) → A
  { deg: 157.6, w: false, a: true, s: false, d: false, name: 'left-lower' },
  { deg: 180.0, w: false, a: true, s: false, d: false, name: 'left-mid' },
  { deg: 202.4, w: false, a: true, s: false, d: false, name: 'left-upper' },
  // [202.5, 247.5) → A + W
  { deg: 202.6, w: true, a: true, s: false, d: false, name: 'upLeft-lower' },
  { deg: 225.0, w: true, a: true, s: false, d: false, name: 'upLeft-mid' },
  { deg: 247.4, w: true, a: true, s: false, d: false, name: 'upLeft-upper' },
  // [247.5, 292.5) → W
  { deg: 247.6, w: true, a: false, s: false, d: false, name: 'up-lower' },
  { deg: 270.0, w: true, a: false, s: false, d: false, name: 'up-mid' },
  { deg: 292.4, w: true, a: false, s: false, d: false, name: 'up-upper' },
  // [292.5, 337.5) → D + W
  { deg: 292.6, w: true, a: false, s: false, d: true, name: 'upRight-lower' },
  { deg: 315.0, w: true, a: false, s: false, d: true, name: 'upRight-mid' },
  { deg: 337.4, w: true, a: false, s: false, d: true, name: 'upRight-upper' },
];

function sectorAtDegrees(deg: number, radius: number = 0.8): JoystickSectorResult {
  const rad = deg * Math.PI / 180;
  return joystickSector(Math.cos(rad) * radius, Math.sin(rad) * radius, 0.18);
}

export default function joystickSectorTest() {
  describe('JoystickSector', () => {
    it('spec_table_matches_native', 0, () => {
      for (let i = 0; i < SPEC.length; i++) {
        const row = SPEC[i];
        const got = sectorAtDegrees(row.deg);
        expect(got.w).assertEqual(row.w);
        expect(got.a).assertEqual(row.a);
        expect(got.s).assertEqual(row.s);
        expect(got.d).assertEqual(row.d);
      }
    });

    // 边界**位置**正确性：跨过 22.5° + k·45° 前后 0.1° 必须落在不同扇区。
    // 与上面那张表互补 —— 表保证扇区内部映射对，这条保证换向发生在该发生的地方。
    it('sector_boundaries_are_adjacent', 0, () => {
      for (let k = 0; k < 8; k++) {
        const boundary = 22.5 + k * 45.0;
        const before = sectorAtDegrees(boundary - 0.1);
        const after = sectorAtDegrees(boundary + 0.1);
        const differs = before.w !== after.w || before.a !== after.a ||
          before.s !== after.s || before.d !== after.d;
        expect(differs).assertTrue();
      }
    });

    // 屏幕坐标系约定：dy 向下为正 ⇒ dy 为负是"上" = W。
    // 单独测这条，因为它最容易被"顺手修正成数学坐标系"的改动破坏，
    // 而破坏后三端会**同时**上下颠倒（现在共用一份规格）。
    it('screen_coordinate_convention_dy_down_is_positive', 0, () => {
      const up = joystickSector(0, -0.8, 0.18);
      expect(up.w).assertTrue();
      expect(up.s).assertFalse();
      const down = joystickSector(0, 0.8, 0.18);
      expect(down.s).assertTrue();
      expect(down.w).assertFalse();
      const left = joystickSector(-0.8, 0, 0.18);
      expect(left.a).assertTrue();
      const right = joystickSector(0.8, 0, 0.18);
      expect(right.d).assertTrue();
    });

    // 死区：严格小于才算松开（等于死区视为已出死区）。
    it('dead_zone_boundary_is_exclusive', 0, () => {
      expect(joystickSectorIsReleased(joystickSector(0.1, 0, 0.18))).assertTrue();
      expect(joystickSector(0.18, 0, 0.18).d).assertTrue();
      expect(joystickSector(0.19, 0, 0.18).d).assertTrue();
    });

    // 归中必须松开。抓的是一个具体陷阱：atan2(0,0) 有定义且返回 0，
    // 若不单独挡住长度为 0，死区传 0 的调用方（手柄端在死区重映射之后可能传 0）
    // 会在摇杆归中时被判成"一直向右"，表现为角色自己往右走。
    it('zero_length_releases_even_with_zero_dead_zone', 0, () => {
      expect(joystickSectorIsReleased(joystickSector(0, 0, 0))).assertTrue();
      expect(joystickSectorIsReleased(joystickSector(0, 0, 0.18))).assertTrue();
      // 死区为 0 且有微小位移时应当正常判向（不能被上面那条误伤）。
      expect(joystickSector(1e-9, 0, 0).d).assertTrue();
    });

    // 非有限输入一律松开：让 NaN 决定方向的后果是某个方向键永久按住，
    // 在 MC 里表现为"角色自己一直走"，比丢一次输入严重得多。
    it('non_finite_input_releases', 0, () => {
      expect(joystickSectorIsReleased(joystickSector(NaN, 0, 0.18))).assertTrue();
      expect(joystickSectorIsReleased(joystickSector(0, NaN, 0.18))).assertTrue();
      expect(joystickSectorIsReleased(joystickSector(0.5, 0.5, NaN))).assertTrue();
      expect(joystickSectorIsReleased(joystickSector(Infinity, 0, 0.18))).assertTrue();
      expect(joystickSectorIsReleased(joystickSector(0, -Infinity, 0.18))).assertTrue();
    });

    // 任意方向都不会同时给出相反的两个键（W+S 或 A+D）—— 那会让 MC 里的移动互相抵消，
    // 是一个"看起来像卡住"的典型表现。整圈采样。
    it('never_emits_opposing_pair', 0, () => {
      for (let i = 0; i < 720; i++) {
        const got = sectorAtDegrees(i * 0.5);
        expect(got.w && got.s).assertFalse();
        expect(got.a && got.d).assertFalse();
        // 出了死区必然至少有一个方向，且最多两个（八向，不存在三键同时）。
        const count = (got.w ? 1 : 0) + (got.a ? 1 : 0) + (got.s ? 1 : 0) + (got.d ? 1 : 0);
        expect(count === 1 || count === 2).assertTrue();
      }
    });

    // 半径不影响方向（只影响是否出死区）。抓"不小心把长度掺进角度计算"这类改动。
    it('radius_does_not_affect_direction', 0, () => {
      for (let i = 0; i < 16; i++) {
        const deg = i * 22.5 + 5.0;
        const small = sectorAtDegrees(deg, 0.25);
        const large = sectorAtDegrees(deg, 4.0);
        expect(large.w).assertEqual(small.w);
        expect(large.a).assertEqual(small.a);
        expect(large.s).assertEqual(small.s);
        expect(large.d).assertEqual(small.d);
      }
    });

    // 返回的是新对象：调用方就地修改不得污染后续调用。
    it('returns_fresh_object_each_call', 0, () => {
      const first = joystickSector(0, 0, 0.18);
      first.w = true;
      const second = joystickSector(0, 0, 0.18);
      expect(second.w).assertFalse();
    });
  });
}

/**
 * PhysicalMouseMotion.test.ets — rawDelta 存在性判定（提案 D1 / 计划 §72）
 *
 * 这个判定此前在 `McGamePage` 写了**三遍**：生产路径、`AMCL_MOUSEIN` 探针、Gate 0 遥测。
 * 而后两者存在的唯一目的就是判断 rawDelta 活不活 —— 三份实现一旦漂移，探针就会在它
 * 专门要测的那件事上说谎。现在三处共用同一个函数，这里钉住它的语义。
 *
 * 创建日期：2026-08-22
 */

import { describe, it, expect } from '@ohos/hypium';
import { normalizeRelativeMouseDelta, RelativeMouseDelta } from 'gamecontrol';

export default function physicalMouseMotionTest() {
  describe('PhysicalMouseMotion.normalizeRelativeMouseDelta', () => {
    it('两个字段都在 → present，原值透传', 0, () => {
      const r: RelativeMouseDelta = normalizeRelativeMouseDelta(3.5, -7.25);
      expect(r.present).assertTrue();
      expect(r.dx).assertEqual(3.5);
      expect(r.dy).assertEqual(-7.25);
    });

    it('⚠️ 只有一个字段在 → **不算** present（半可用事件不得通过）', 0, () => {
      // 只判其中一个的后果：半可用事件以 present=true, dy=0 通过 ⇒ "视角只能左右转、
      // 上下不动"，而 native 收到的是语义上合法的 0 增量，不会报错。
      const onlyX: RelativeMouseDelta = normalizeRelativeMouseDelta(5, undefined);
      const onlyY: RelativeMouseDelta = normalizeRelativeMouseDelta(undefined, 5);
      expect(onlyX.present).assertFalse();
      expect(onlyY.present).assertFalse();
    });

    it('两个都缺 → 不 present', 0, () => {
      expect(normalizeRelativeMouseDelta(undefined, undefined).present).assertFalse();
    });

    it('present=false 时 dx/dy **必须**归零（native 事务三元组要自洽）', 0, () => {
      const cases: RelativeMouseDelta[] = [
        normalizeRelativeMouseDelta(5, undefined),
        normalizeRelativeMouseDelta(undefined, 5),
        normalizeRelativeMouseDelta(undefined, undefined),
      ];
      for (let i = 0; i < cases.length; i++) {
        expect(cases[i].dx).assertEqual(0);
        expect(cases[i].dy).assertEqual(0);
      }
    });

    it('0 是合法增量，不能被当成缺失', 0, () => {
      // 静止不动的一帧 rawDelta 就是 (0,0)。把它判成 absent 会让 native 以为
      // 这台设备没有相对通道，从而走完全不同的路径。
      const r: RelativeMouseDelta = normalizeRelativeMouseDelta(0, 0);
      expect(r.present).assertTrue();
      expect(r.dx).assertEqual(0);
      expect(r.dy).assertEqual(0);
    });

    it('负值与小数原样保留（不取整、不取绝对值）', 0, () => {
      const r: RelativeMouseDelta = normalizeRelativeMouseDelta(-0.5, -1.5);
      expect(r.dx).assertEqual(-0.5);
      expect(r.dy).assertEqual(-1.5);
    });

    it('⚠️ 已知缺口（刻意保留，与抽出前逐位相同）：NaN / Infinity 会原样透传', 0, () => {
      // 抽 TU 不改语义。代价见 PhysicalMouseMotion.ets 文件头：NaN 会污染 native 侧的
      // 相对量累加 ⇒ 视角永久失效直到下一次复位。但 NaN 是否可达无任何证据（C 级），
      // 而"顺手加个守卫"是 §66.4 撤销过一次的动作。要加就单独一轮，见计划 §72.2。
      // 这条用例的作用是让这个缺口**可执行地**存在，而不是只写在注释里。
      expect(normalizeRelativeMouseDelta(Number.NaN, 1).present).assertTrue();
      expect(normalizeRelativeMouseDelta(Number.POSITIVE_INFINITY, 1).present).assertTrue();
    });
  });
}

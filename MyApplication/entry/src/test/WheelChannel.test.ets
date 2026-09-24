/**
 * WheelChannel.test.ets — 滚轮两条通道的符号约定 + 分格累加（提案 D1 / 计划 §66）
 *
 * 最要紧的一条：**两个平台量对同一个物理滚动方向的符号约定相反，且各有官方依据。**
 * 滚轮方向与格数是本项目反复出问题的地方（计划 §18/§32/§35.1(d)），而"顺手把两边
 * 统一"正是最容易犯的那个错 —— 有了这里的断言，统一它会变成测试失败而不是真机回归。
 *
 * ⚠️ **作用域（2026-08-24 更正，计划 §90）**：`WheelStepAccumulator` 只服务
 * `AMCL_INPUT_CHANNEL_AXIS_PAN`（排第三）。本段此前写「**两台已知真机上它都从不产出格数**」
 * 并据此把下面的格数用例降格为"只是算术、不是用户会看到什么" —— **那句已被真机否证**：
 * 它是一个**平面相关**的结论，被当成设备相关的写了。typed 平面下 native AXIS 回调曾被一条
 * 早退整场关闭 ⇒ 本通道成为**唯一**滚轮所有者并真的产出格数，用户看到"慢滚不动、快滚跳格"。
 * ⇒ 下面的格数用例现在**既是算术断言、也是用户可见行为的断言**，不要再照旧读法降格。
 *
 * 本文件是纯逻辑覆盖：不驱动 ArkUI 手势、不碰 NAPI，不能替代真机复测。
 *
 * 创建日期：2026-08-21
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  WheelStepAccumulator, wheelDirectionFromPanOffset, wheelDirectionFromAxisVertical,
  WHEEL_PAN_STEP_VP, WHEEL_PAN_MAX_STEPS_PER_UPDATE,
  WHEEL_PAN_TAG, judgeWheelPanGesture, WheelPanJudgement,
} from 'gamecontrol';

export default function wheelChannelTest() {
  // 2026-08-22（计划 §73）：本通道的**入口闸门**。与下面两组不同，这一组断言的东西
  // 在两台已知真机上**每天都在跑** —— 真手指的每次垂直拖动都经它判成
  // `WheelPanJudgement.RejectNotAxisDriven`，§71 那句"Pan 零产出"正是它工作的证据。
  describe('WheelChannel.judgeWheelPanGesture', () => {
    // 三个 tag 取值 × 四个 axisVertical 取值 = 12 组，下面穷举完。
    const OTHER_TAG: string = 'someChildGesture';

    it('非本通道的 tag：四种轴值都返回 NotWheelPanGesture（子组件手势不受影响）', 0, () => {
      // 这一条是"判据按 tag 限定"那句承重注释的可执行版本：GameControls 及其抽屉的
      // 手势都走同一个 onGestureJudgeBegin，任何"忘记先比 tag"的改动都会在这里失败。
      expect(judgeWheelPanGesture(OTHER_TAG, undefined))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(OTHER_TAG, 0))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(OTHER_TAG, 12))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(OTHER_TAG, -12))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
    });

    it('无 tag 的手势（tag 缺省）同样返回 NotWheelPanGesture', 0, () => {
      // `GestureInfo.tag` 是可选的：未 .tag() 的手势走这条路，必须原样放行。
      expect(judgeWheelPanGesture(undefined, undefined))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(undefined, 0))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(undefined, 12))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
      expect(judgeWheelPanGesture(undefined, -12))
        .assertEqual(WheelPanJudgement.NotWheelPanGesture);
    });

    it('⚠️ 本通道 + 无轴值 / 轴值 0 ⇒ RejectNotAxisDriven（真手指拖动的保护）', 0, () => {
      // 这是全函数最承重的一条：放行它就等于"真手指垂直拖动被当滚轮"，
      // 也就是 §18/§32 那族污染的反方向。0 与缺省同等对待，理由见函数注释。
      expect(judgeWheelPanGesture(WHEEL_PAN_TAG, undefined))
        .assertEqual(WheelPanJudgement.RejectNotAxisDriven);
      expect(judgeWheelPanGesture(WHEEL_PAN_TAG, 0))
        .assertEqual(WheelPanJudgement.RejectNotAxisDriven);
    });

    it('本通道 + 非零轴值 ⇒ AcceptAxisDriven，正负都接受', 0, () => {
      // 两个符号都必须接受：接受与否只看"有没有轴驱动"，方向由
      // wheelDirectionFromPanOffset 另行决定（两件事不要混在一处判）。
      expect(judgeWheelPanGesture(WHEEL_PAN_TAG, 12))
        .assertEqual(WheelPanJudgement.AcceptAxisDriven);
      expect(judgeWheelPanGesture(WHEEL_PAN_TAG, -12))
        .assertEqual(WheelPanJudgement.AcceptAxisDriven);
    });

    it('三个取值互不相同（页面只把 RejectNotAxisDriven 映射成 REJECT）', 0, () => {
      // 页面侧是 `verdict === RejectNotAxisDriven ? REJECT : CONTINUE`。若有人把两个
      // "放行"结论合并成同一个数值，这条会失败 —— 那正是本枚举刻意不压成布尔的理由
      // （"没管这个手势"与"认领并接受"是两件事）。
      //
      // ⚠️ 写法说明：**不能**直接写 `A === B` 比较两个枚举成员 —— ArkTS 会把它们各自
      // 收窄成字面量类型，"两者无重叠"是**编译错误**（10505001，2026-08-22 实测被
      // build-hap.ps1 的 [3/7] 拦下）。所以先降到 number 再比。
      const all: number[] = [
        WheelPanJudgement.NotWheelPanGesture as number,
        WheelPanJudgement.RejectNotAxisDriven as number,
        WheelPanJudgement.AcceptAxisDriven as number,
      ];
      const distinct: number[] = [];
      for (let i = 0; i < all.length; i++) {
        if (distinct.indexOf(all[i]) < 0) distinct.push(all[i]);
      }
      expect(distinct.length).assertEqual(3);
    });

    it('tag 常量本身：判据与 .gesture 绑定必须共用这一个字符串', 0, () => {
      // 常量已上移进 WheelChannel.ets（计划 §73）。这条钉住"页面不要再写一遍字面量"：
      // 失配的后果是判据对**所有**手势返回 NotWheelPanGesture，且零编译错误。
      expect(WHEEL_PAN_TAG).assertEqual('amclWheelPan');
      expect(judgeWheelPanGesture('amclWheelPan', 12))
        .assertEqual(WheelPanJudgement.AcceptAxisDriven);
    });
  });

  describe('WheelChannel.direction', () => {
    it('⚠️ 两条通道符号相反，这是契约不是笔误', 0, () => {
      // Pan（GestureEvent.offsetY）：官方「向前滚动，offsetY 的上报数值为正」⇒ +sign
      // AXIS（getVerticalAxisValue）：官方「向前滚动，上报数值为负」⇒ -sign
      // 同一个"向前滚"在两条 API 上是相反的数值符号，两个函数都必须收敛到 GLFW 的 +1。
      expect(wheelDirectionFromPanOffset(63)).assertEqual(1);
      expect(wheelDirectionFromAxisVertical(63)).assertEqual(-1);
      expect(wheelDirectionFromPanOffset(-63)).assertEqual(-1);
      expect(wheelDirectionFromAxisVertical(-63)).assertEqual(1);
      // 如果有人"顺手统一"，上面四条里必有两条失败。
    });

    it('真机核对：Pan 向下滚 offsetY≈-63 ⇒ direction=-1 ⇒ 快捷栏 1→2', 0, () => {
      // 端到端依据：MC 的 Inventory.swapPaint(d) 做 selected -= d ⇒ selected+1。
      // 这是"方向到底对不对"唯一的真机证据，钉在这里防止被当成任意常数改掉。
      expect(wheelDirectionFromPanOffset(-63)).assertEqual(-1);
    });

    it('两条通道的 0 都返回 0（Begin/End 常带 0 值，不该发格）', 0, () => {
      expect(wheelDirectionFromPanOffset(0)).assertEqual(0);
      expect(wheelDirectionFromAxisVertical(0)).assertEqual(0);
    });
  });

  describe('WheelChannel.WheelStepAccumulator', () => {
    it('常量：步长 63vp（= API 26 手机实测一格）、单次上限 3 格', 0, () => {
      // ⚠️ 2026-08-24：40 → 63（计划 §90.2）。40 是按**另一条通道**（TOUCH_WHEEL，
      // 一格 90px ÷ 2.125 ≈ 42vp）校出来的，而本通道实测一格 `offsetY` = 63vp。
      // 阈值与一格不等的直接后果就是跳格，见下面那条对照用例。
      // ⚠️ 63 只在一台设备上实测过（API 26 手机，两轮日志逐位一致）。长期正解是读
      // `AxisEvent.scrollStep`（规范 §九 记着它"完全没读"），那条不在本轮范围。
      expect(WHEEL_PAN_STEP_VP).assertEqual(63);
      expect(WHEEL_PAN_MAX_STEPS_PER_UPDATE).assertEqual(3);
    });

    it('⭐ 一格 = 恰好一格、残量归零（阈值等于实测一格之后的核心性质）', 0, () => {
      // 这是本次修正要买到的东西：一次 63vp 的位移出**一格**，且不留残量 ⇒ 下一格
      // 不会被提前触发。阈值仍是 40 时这里是"1 格 + 余 23"，于是第二格变 2 格 ⇒ 跳格。
      const acc = new WheelStepAccumulator();
      acc.begin();
      const first: number[] = acc.consume(acc.advanceBaseline(63));
      expect(first.length).assertEqual(1);
      expect(first[0]).assertEqual(1);
      expect(acc.residual()).assertEqual(0);
      // 连续三格：每格恰好一格，全程无残量堆积。
      for (let notch = 2; notch <= 4; notch++) {
        const more: number[] = acc.consume(acc.advanceBaseline(63 * notch));
        expect(more.length).assertEqual(1);
        expect(acc.residual()).assertEqual(0);
      }
    });

    it('⭐ 基准恒为 0：手势被识别前那一整格不得丢（慢滚一格不动的根因）', 0, () => {
      // `GestureEvent.offsetY` 官方定义是"相对**手指按下时**的偏移量"，所以它已经是从
      // 手势起点累计的量，正确基准只能是 0。此前 `begin(offsetY)` 拿 onActionStart 那一刻
      // 的 offsetY 当基准 ⇒ 首个 update 的 delta 恒为 0（ArkUI 把 start 与首个 update 派发
      // 在同一 pointer 事件上、带同一 offsetY）⇒ 慢滚时每格自成一个手势、每个手势只有那
      // 一次 delta=0 ⇒ **一格都发不出去**。这条用例把新契约钉死。
      const acc = new WheelStepAccumulator();
      acc.begin();
      // 模拟"慢滚一格"：手势识别时 offsetY 已经是 -63，且这是该手势唯一的一次 update。
      const steps: number[] = acc.consume(acc.advanceBaseline(-63));
      expect(steps.length).assertEqual(1);
      expect(steps[0]).assertEqual(-1);
    });

    it('不足一格不发，残量跨 update 保留（慢滚必须能发出格）', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      // 三次递增到 70vp：前两次不足一格，第三次跨过 63 ⇒ 发一格，残量 7
      expect(acc.consume(acc.advanceBaseline(20)).length).assertEqual(0);
      expect(acc.consume(acc.advanceBaseline(40)).length).assertEqual(0);
      const steps: number[] = acc.consume(acc.advanceBaseline(70));
      expect(steps.length).assertEqual(1);
      expect(steps[0]).assertEqual(1);
      expect(acc.residual()).assertEqual(7);
    });

    it('⚠️ 对照：把阈值当成 40 时同一序列会 1、2 交替（这就是跳格）', 0, () => {
      // 保留这条对照是刻意的：它把"阈值取错会怎样"写成可执行的反例，而不是留在注释里。
      // 用一个**局部**步长模拟旧值，不去改产品常量 —— 否则这条用例会随常量一起失效。
      const legacyStep: number = 40;
      let residual: number = 0;
      const detentsFor = (delta: number): number => {
        residual += delta;
        let n: number = 0;
        while (residual >= legacyStep) { residual -= legacyStep; n++; }
        return n;
      };
      expect(detentsFor(63)).assertEqual(1);   // 余 23
      expect(detentsFor(63)).assertEqual(2);   // 86 ⇒ 2 格，余 6
      expect(detentsFor(63)).assertEqual(1);   // 69 ⇒ 1 格，余 29
      expect(detentsFor(63)).assertEqual(2);   // 92 ⇒ 2 格
    });

    it('残量确实被吸收：递增到 4 格共发 4 格，没有丢格也没有翻倍（总量守恒）', 0, () => {
      // 这一条说明**残量机制本身有效**（与阈值取值无关）。阈值修对之后它同时变成
      // "一格进一格出"的守恒证明；阈值错时它是 1+2+1+2=6 —— 区分这两者决定该动哪一行。
      const acc = new WheelStepAccumulator();
      acc.begin();
      let total: number = 0;
      for (let notch = 1; notch <= 4; notch++) {
        total += acc.consume(acc.advanceBaseline(63 * notch)).length;
      }
      expect(total).assertEqual(4);
      // 4 格 × 63 = 252vp，252/63 = 4 整 ⇒ 发 4 格、残 0。
      expect(acc.residual()).assertEqual(0);
    });

    it('单次 update 最多 3 格（惯性尾包不得一次甩出一串）', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      const steps: number[] = acc.consume(acc.advanceBaseline(1000));
      expect(steps.length).assertEqual(3);
      // 超出上限的位移**留在残量里**，不是丢弃 —— 下一次 update 会继续发。
      expect(acc.residual()).assertEqual(1000 - 3 * 63);
    });

    it('同一次 consume 返回的元素必然同号（这条性质让抽出前的双 while 等价于单循环）', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      const up: number[] = acc.consume(acc.advanceBaseline(200));
      expect(up.length > 0).assertTrue();
      for (let i = 0; i < up.length; i++) expect(up[i]).assertEqual(1);
      acc.reset();
      acc.begin();
      const down: number[] = acc.consume(acc.advanceBaseline(-200));
      expect(down.length > 0).assertTrue();
      for (let i = 0; i < down.length; i++) expect(down[i]).assertEqual(-1);
    });

    it('负方向对称：阈值、上限、残量符号都镜像', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      // 62 < 63 ⇒ 不发格（对称于正向的"不足一格"）
      expect(acc.consume(acc.advanceBaseline(-62)).length).assertEqual(0);
      // 累计到 -126 ⇒ 恰好两格，残量归零
      const steps: number[] = acc.consume(acc.advanceBaseline(-126));
      expect(steps.length).assertEqual(2);
      expect(steps[0]).assertEqual(-1);
      expect(acc.residual()).assertEqual(0);
    });

    it('⚠️ 承重：让位期间必须只推进基准、不吃残量 —— 否则恢复后一次甩出一串', 0, () => {
      // 复现"松手后快捷栏又自己跳几格"：调用方对每次 update 无条件 advanceBaseline，
      // 但只在拥有滚轮所有权时 consume。让位期间的位移因此被**丢弃**。
      const acc = new WheelStepAccumulator();
      acc.begin();
      acc.advanceBaseline(500);            // 让位：只推进基准，位移丢弃
      acc.advanceBaseline(1000);           // 仍在让位
      const steps: number[] = acc.consume(acc.advanceBaseline(1010));  // 重新拿到所有权
      // 只应看到最后这 10vp（不足一格），而不是 500/1000 攒下来的一串
      expect(steps.length).assertEqual(0);
      expect(acc.residual()).assertEqual(10);
    });

    it('对比反例：若把两步合并（每次都吃残量），同一序列会甩出 3 格', 0, () => {
      // 这条用例的作用是把"合并两步会怎样"写成可执行的对照，而不是留在注释里。
      const acc = new WheelStepAccumulator();
      acc.begin();
      acc.consume(acc.advanceBaseline(500));
      acc.consume(acc.advanceBaseline(1000));
      const steps: number[] = acc.consume(acc.advanceBaseline(1010));
      expect(steps.length).assertEqual(WHEEL_PAN_MAX_STEPS_PER_UPDATE);
    });

    it('reset 清残量与基准；begin 后基准恒为 0（cancel 路径必须走 reset）', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      acc.consume(acc.advanceBaseline(70));
      expect(acc.residual()).assertEqual(7);
      acc.reset();
      expect(acc.residual()).assertEqual(0);
      // ⚠️ 新契约：新手势的基准恒为 0，所以首个 update 的 delta **就是** offsetY 本身。
      // 旧契约（basis = start 的 offsetY）在这里会得到 0 格 —— 那正是慢滚不动的根因。
      acc.begin();
      const steps: number[] = acc.consume(acc.advanceBaseline(63));
      expect(steps.length).assertEqual(1);
      expect(acc.residual()).assertEqual(0);
    });

    it('begin 也清残量：漏掉 cancel 时下一次手势不带上一次的残量', 0, () => {
      const acc = new WheelStepAccumulator();
      acc.begin();
      acc.consume(acc.advanceBaseline(62));   // 残 62，差一点就发格
      acc.begin();                            // 新手势（没走 reset）
      expect(acc.residual()).assertEqual(0);
      expect(acc.consume(acc.advanceBaseline(62)).length).assertEqual(0);
    });
  });
}

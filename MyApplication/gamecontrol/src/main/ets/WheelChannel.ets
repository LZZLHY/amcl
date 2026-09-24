/**
 * WheelChannel.ets — 滚轮的两条 ArkTS 通道：符号约定 + 分格累加（提案 D1 / 计划 §66）
 *
 * ⚠️ **作用域 —— 先读这一条**：本文件只服务排第三的 `AMCL_INPUT_CHANNEL_AXIS_PAN`。
 * 它**从不产出格数**（手机让位给 `AMCL_INPUT_CHANNEL_NATIVE_AXIS`、平板手势起不来，§71/§74），
 * 但**手势本身在手机上会起来** —— 别把两件事混成一件。
 *
 * ⚠️ **承重契约：两个平台量对同一物理滚动方向的符号约定相反，不要统一。**
 *   · 本文件读 `GestureEvent.offsetY`（**vp**、累计量）⇒ direction = **+**sign
 *   · 另两条读 `axisVertical`（角度、单次变化量）⇒ direction = **−**sign
 * 不是两个实现打架，是两个平台量各按自己的官方文档；三条产出者只有两种约定。
 * 官方原文、那句被真机否证的 C 头注释、以及逐设备的所有者实测都在计划 §67 / §71。
 *
 * 端到端方向证据（唯一那条，别删）：向下滚 `offsetY ≈ -63` ⇒ direction = -1 ⇒
 * MC 的 `Inventory.swapPaint(d)` 做 `selected -= d` ⇒ 快捷栏 1→2，与桌面端一致。
 *
 * 本文件刻意不依赖 ArkUI / NAPI（与 `InputDeviceLifecycleCoordinator.ets` 同一种分工）。
 */

/**
 * ⚠️ **2026-08-24 更正上面那句"从不产出格数"—— 它是一个平面相关的结论，被当成设备相关的写了。**
 * legacy 平面 + 手机：`NATIVE_AXIS` 约 1ms 后夺权 ⇒ 本通道确实不产出。
 * **typed 平面 + 手机：`NATIVE_AXIS` 的 native AXIS 回调曾被一条早退整场关闭（计划 §90.1，
 * 已修）⇒ 本通道成为唯一所有者并真的产出格数。** 用户就是这样看到跳格的。
 * ⇒ 判据：任何依赖"某条路径现在还没被打开"的无害结论，必须写成待爆而不是无害。
 * 第三台设备不再是取证前置条件 —— typed 开关本身就是第二个维度。
 *
 * 本通道那个 `PanGesture` 的 tag。
 *
 * ⚠️ **它是一对镜像的两端**：`.tag(WHEEL_PAN_TAG)` 与 `judgeWheelPanGesture` 的第一个参数
 * 必须是同一个字符串。所以它和判据放在同一个文件里，而不是留在页面 —— 页面侧两处各写一遍
 * 字面量时，改一处漏一处的后果是**判据对所有手势都返回
 * `WheelPanJudgement.NotWheelPanGesture`**（见下方失效方向），而这不会有任何编译错误。
 */
export const WHEEL_PAN_TAG: string = 'amclWheelPan'

/**
 * `judgeWheelPanGesture` 的三种结论。刻意用中立枚举而不是 `GestureJudgeResult`：
 * 本文件不依赖 ArkUI，且 `WheelPanJudgement.NotWheelPanGesture` 与
 * `WheelPanJudgement.AcceptAxisDriven` 虽然都映射到"放行"，语义完全不同 ——
 * 压成一个布尔就没法在测试里区分"没管这个手势"和"认领并接受了它"。
 */
export enum WheelPanJudgement {
  /** 不是本通道的手势（含无 tag 的手势）。调用方**必须原样放行**。 */
  NotWheelPanGesture = 0,
  /** 是本通道的手势，但驱动源不是轴（= 真手指）。调用方必须拒掉。 */
  RejectNotAxisDriven = 1,
  /** 是本通道的手势且确实由轴驱动（鼠标滚轮 / 触控板双指）。放行。 */
  AcceptAxisDriven = 2,
}

/**
 * 本通道的**入口闸门**：一次 `onGestureJudgeBegin` → 三值结论。
 *
 * 官方依据（A 级）：`BaseGestureEvent.axisVertical`（since 12）**仅在**鼠标滚轮 /
 * 触控板双指驱动的 Pan 手势上有值。所以"有轴值"就是"这个 Pan 不是真手指"的判据。
 *
 * ⚠️ **这是本通道唯一每天都在跑的那段逻辑，别被文件头那句"Pan 从不产出格数"误导。**
 * §71 实测两台设备 `AMCL_WHEEL pan update` 零条，而那正是本函数在工作的证据：真手指的
 * 每次垂直拖动都走到这里并被判成 `WheelPanJudgement.RejectNotAxisDriven`。
 *
 * 失效方向严重不对称（完整因果见计划 §73.2）：误判成放行 ⇒ 真手指垂直拖动被当滚轮，
 * 即 §18 / §32 那族污染的反方向，会破坏触控端已验收的拖动。
 *
 * @param gestureTag 平台给出的 `GestureInfo.tag`，可能缺省。
 * @param axisVertical 平台给出的 `BaseGestureEvent.axisVertical`，可能缺省。
 */
export function judgeWheelPanGesture(
  gestureTag: string | undefined, axisVertical: number | undefined
): WheelPanJudgement {
  if (gestureTag !== WHEEL_PAN_TAG) return WheelPanJudgement.NotWheelPanGesture
  // 0 与缺省同等对待：Pan 的 Begin 包常带 0 轴值，而"0 轴值"分不出"没有轴"与
  // "轴回中"，两者都不足以证明这次手势来自滚轮。⇒ 保守拒（失效方向见上）。
  if (axisVertical === undefined || axisVertical === 0) {
    return WheelPanJudgement.RejectNotAxisDriven
  }
  return WheelPanJudgement.AcceptAxisDriven
}

/**
 * 本通道"一格"的纵向位移阈值（vp，与 `GestureEvent.offsetY` 同量纲）。
 *
 * **契约：阈值必须等于本通道实测的一格**（API 26 手机 `offsetY` = 63vp）。不等就跳格。
 * ⚠️ 只有一个标定源（平板上 Pan 零触发）；长期正解是读 `AxisEvent.scrollStep`。
 * ⚠️ 此前"约 1ms 抢权窗里不会误发"靠的是首个 update `delta` 恒为 0 —— 那是基准取错的
 * 症状，基准修回 0 之后**这个兜底没了**，改由通道所有权保证。因果见计划 §90.2。
 */
export const WHEEL_PAN_STEP_VP: number = 63

/**
 * 单次 Pan update 最多发几格。
 * 防止惯性尾包一次甩出一串（一格滚轮可能与相邻几格合并进同一个手势）。
 */
export const WHEEL_PAN_MAX_STEPS_PER_UPDATE: number = 3

/**
 * 轴驱动 Pan 通道的方向。`offsetY` 正 = 向前滚 = GLFW +1。
 * @returns +1 / -1；`offsetY` 为 0 时返回 0（调用方不应发格）
 */
export function wheelDirectionFromPanOffset(offsetY: number): number {
  if (offsetY > 0) return 1
  if (offsetY < 0) return -1
  return 0
}

/**
 * ArkTS AXIS 通道的方向。`axisVertical` **负** = 向前滚 = GLFW +1。
 * ⚠️ 与 `wheelDirectionFromPanOffset` 符号相反，理由见文件头，不要统一。
 * @returns +1 / -1；为 0 时返回 0（Begin/End 常带 0 值，不该发格）
 */
export function wheelDirectionFromAxisVertical(axisVertical: number): number {
  if (axisVertical < 0) return 1
  if (axisVertical > 0) return -1
  return 0
}

/**
 * 轴驱动 Pan 通道的分格累加器。
 *
 * 契约（改动前必读）：
 *   1. **残量必须跨 update 保留**，否则每次 update 不足一格的位移会被丢弃 ⇒ 慢滚永远发不出格。
 *   2. **单次 update 有格数上限**，否则惯性尾包一次甩出一串。
 *   3. `reset()` 必须同时清残量与基准，且必须在手势 end / **cancel** 都调用 ——
 *      漏掉 cancel 会让下一次手势带着上一次的残量开始。
 *   4. ⚠️ **`advanceBaseline` 与 `consume` 分成两步是承重的，不要合并成一个方法。**
 *      调用方对每一次 update 都必须**无条件**调 `advanceBaseline`，但只在本通道确实
 *      拥有滚轮所有权（`wheelChannelClaim`）时才调 `consume`。让位期间的位移因此被
 *      **丢弃**而不是攒起来 —— 合并成一步就会让基准在让位期间停滞，等重新拿到所有权时
 *      一个巨大的 delta 涌进来，表现为"松手后快捷栏又自己跳几格"。
 *      （`consume` 的上限只能把它压到 3 格，压不掉。）
 */
export class WheelStepAccumulator {
  private residualVp: number = 0
  private lastOffsetY: number = 0

  /**
   * 手势开始：基准恒为 **0**，清残量。
   *
   * ⚠️ **2026-08-24 修正（计划 §90.2）。此前这里写 `this.lastOffsetY = offsetY`，那是错的。**
   * 官方定义：`GestureEvent.offsetY` 是"手势事件相对于**手指按下时**的偏移量 Y（vp）"
   * —— 它**本身就是从手势起点累计的量**，所以它的正确基准只能是 0。
   * 用 `onActionStart` 那一刻的 `offsetY` 当基准，等于把"手势被识别之前已经累计的那一段"
   * 永久丢弃 —— 而对滚轮来说那一段**就是整整一格**（本机实测一格 63vp）。
   *
   * 真机后果（typed 下 AXIS_PAN 成为唯一所有者时暴露）：ArkUI 把 `onActionStart` 与首个
   * `onActionUpdate` 派发在同一个 pointer 事件上、带同一个 `offsetY` ⇒ 首个 update 的
   * `delta` 恒为 0 ⇒ **慢滚时每一格都是一个独立手势、每个手势只有那一次 delta=0
   * ⇒ 一格都发不出去**。而 `reset()` 在 end/cancel 清残量，所以残量也不可能跨手势累积。
   * 快滚时多格并入同一手势，从第二个 update 起才有非零 delta ⇒ 能发但配错阈值 ⇒ 跳格。
   * ⇒ 用户报的"慢滚不动、快滚跳格"是这一条与阈值那一条的**合成**，不是两个独立缺陷。
   */
  begin(): void {
    this.lastOffsetY = 0
    this.residualVp = 0
  }

  /**
   * 推进基准并返回本次增量。**必须对每一次 update 无条件调用**（理由见契约第 4 条）。
   * 它不触碰残量，所以单独调用是安全的。
   */
  advanceBaseline(offsetY: number): number {
    const delta: number = offsetY - this.lastOffsetY
    this.lastOffsetY = offsetY
    return delta
  }

  /**
   * 把一次增量吃进残量，返回本次应发出的方向序列（每个元素 +1 或 -1，长度 ≤ 上限）。
   * **只在本通道拥有滚轮所有权时调用。**
   *
   * **同一次调用返回的元素必然同号**（不是巧合，是可证的）：进入时残量落在
   * `(-STEP, +STEP)`，加上 delta 之后不可能同时满足 `>= +STEP` 与 `<= -STEP`；
   * 每次抽取恰好减去一个 STEP 且在 `< STEP` 时停止，所以残量始终留在 `[0, STEP)` 或
   * `(-STEP, 0]` 的同一侧。抽出前那两个**顺序执行**的 while 循环（先排空正向、再排空
   * 负向）也正是靠这条性质才等价于一个循环 —— 第二个循环实际上永不执行。
   * 这条性质有单测钉住；它一旦不成立，"一格算成两格"就会以方向混杂的形式出现。
   */
  consume(delta: number): number[] {
    this.residualVp += delta
    const steps: number[] = []
    while (steps.length < WHEEL_PAN_MAX_STEPS_PER_UPDATE) {
      if (this.residualVp >= WHEEL_PAN_STEP_VP) {
        this.residualVp -= WHEEL_PAN_STEP_VP
        steps.push(1)
      } else if (this.residualVp <= -WHEEL_PAN_STEP_VP) {
        this.residualVp += WHEEL_PAN_STEP_VP
        steps.push(-1)
      } else {
        break
      }
    }
    return steps
  }

  /** 手势结束 / 取消：清残量与基准。 */
  reset(): void {
    this.residualVp = 0
    this.lastOffsetY = 0
  }

  /** 仅诊断与测试用。 */
  residual(): number {
    return this.residualVp
  }
}

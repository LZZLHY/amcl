/**
 * PhysicalMouseMotion.ets — 物理鼠标相对位移样本的归一化（提案 D1 / 计划 §72）
 *
 * ⚠️ **为什么这一个三行判定值得单独成文件**：同一条"rawDelta 在不在"的判定此前在
 * `McGamePage` 里写了**三遍** —— 生产路径（决定 look 是否有相对量）、`AMCL_MOUSEIN`
 * 聚合探针、Gate 0 遥测各一份。而**后两者存在的唯一目的就是判断 rawDelta 活不活**。
 * ⇒ 一旦探针那两份与生产那份漂移，探针就会在它专门要测的那件事上说谎（§八.5 的形状）。
 *
 * 失效方向不对称：谎称 present ⇒ 向 native 送一对伪造的 0 增量；谎称 absent ⇒ 视角
 * 整条丢失。两者都可感知，后者更严重。
 *
 * 本文件刻意不依赖 ArkUI / NAPI：调用方把两个可选字段的原值传进来
 * （与 `InputDeviceLifecycleCoordinator.ets` 同一种分工）。
 */

/** 一次相对位移样本。`present=false` 时 `dx/dy` 恒为 0，调用方不必再判空。 */
export interface RelativeMouseDelta {
  /** 平台是否给出了**完整**的一对相对增量。 */
  present: boolean
  dx: number
  dy: number
}

/**
 * 归一化 `MouseEvent.rawDeltaX/rawDeltaY`（两者都是可选字段）。
 *
 * 契约（改动前必读）：
 *   1. **必须两个字段都在才算 present。** 只判其中一个的后果是：半可用事件会以
 *      `present=true, dy=0` 通过，表现为"视角只能左右转、上下不动"—— 而 native 侧
 *      收到的是一个语义上合法的 0 增量，不会报错。
 *   2. `present=false` 时**必须**把 dx/dy 归零而不是原样透传 undefined —— native 事务
 *      的签名是 `(present, dx, dy)`，三者必须自洽。
 *
 * ⚠️ **刻意不做有限性校验（NaN / ±Infinity 会原样透传），与抽出前逐位相同。**
 * 抽 TU 不改语义。已知代价：若平台真的送来 NaN，它会以 `present=true` 进入 native 的
 * 相对量累加而那一侧只做范围校验，后果是视角**永久失效直到下一次复位**——比第 1 条更严重。
 * 但 NaN 是否可达**无任何证据**（C 级），而"顺手加个守卫"正是 §66.4 撤销过一次的动作。
 * 要加就单独一轮并说明理由，见计划 §72.2。
 */
export function normalizeRelativeMouseDelta(
  rawDeltaX: number | undefined, rawDeltaY: number | undefined
): RelativeMouseDelta {
  if (rawDeltaX === undefined || rawDeltaY === undefined) {
    return { present: false, dx: 0, dy: 0 }
  }
  return { present: true, dx: rawDeltaX, dy: rawDeltaY }
}

/**
 * LogExportBudget.ets — 导出配额分配（日志系统重构 · P5）
 *
 * 解决的问题（调研 N-7）：`ledgerExport` 的做法是「按固定顺序把各 part 拼成一整段，
 * 再交给 `truncateUtf8Tail` **保尾**截断」。而拼装顺序是
 *   环境头 → 活动摘要 → LAUNCHER → GAME → MC_LATEST → JVM → CRASH_REPORT → SYSTEM_CRASH
 * 且 `ledgerRead(GAME)` 不传上限时读到 16 MB。
 *
 * ⇒ 游戏日志一大，**环境头、活动摘要、启动器日志全部落在被丢掉的头部**，
 *   上传出去的正文可能一行启动器日志都没有 —— 而启动器日志正是「AMCL 自己做了什么决定」
 *   （classpath / JDK / 渲染后端）的唯一记录。
 *
 * ⭐ 修法不是「把顺序调一调」，那只是把问题挪给别人。
 *   正确的形状是**先按 part 分配配额，再各自截断，最后拼** ——
 *   谁大谁被截，而不是谁靠前谁活下来。
 *
 * 两条设计判据：
 *   1. **小而关键的 part 永远不被大 part 挤掉。** 崩溃报告通常只有几 KB，
 *      它的信息密度比 16 MB 的游戏日志高几个数量级。
 *   2. **超配额的 part 保头 + 保尾，不是只保尾。** 启动期根因（类加载 / Mixin /
 *      依赖冲突）在头部，失败现场在尾部，只保一端必丢一半（P1-4）。
 *
 * 关联：docs/refactor/日志系统重构方案.md §二 R4、docs/guides/logging-system.md §3.8
 * 创建日期：2026-09-06
 */

/** 一个 part 对配额的诉求。 */
export interface ExportPartDemand {
  /** part 标识，仅用于诊断与稳定排序。 */
  id: string;
  /** 该 part 实际可提供的字节数。 */
  bytes: number;
  /** 优先级，**越小越重要**。决定谁先拿到保底配额。 */
  priority: number;
  /**
   * 保底字节。只要总预算够，该 part 至少能拿到 `min(bytes, floorBytes)`。
   * 这是「小而关键的段不被挤掉」这条判据的载体。
   */
  floorBytes: number;
}

/** 分配结果。顺序与传入的 demands **一致**（拼装顺序 ≠ 优先级顺序）。 */
export interface ExportPartGrant {
  id: string;
  /** 实际分到的字节数。 */
  granted: number;
  /** 是否被截断（granted < bytes）。 */
  truncated: boolean;
}

/**
 * 把总预算分配给各 part。
 *
 * 算法（两轮 + 找零，刻意做成可预测的，不用浮点比例的复杂形式）：
 *   1. 总需求不超预算 ⇒ 全给，直接返回。
 *   2. 第一轮**按优先级发保底**：每个 part 拿 `min(bytes, floorBytes)`，
 *      预算不够时按优先级顺序发到发不动为止。
 *   3. 第二轮**按未满足需求比例发余额**，每个 part 不超过它自己的 `bytes`。
 *   4. 比例分配的取整余数按优先级补给还差的 part，保证预算不被浪费。
 *
 * @param demands   各 part 的诉求（顺序即拼装顺序）
 * @param totalBudget 总字节预算；≤ 0 视为不限
 */
export function allocateExportBudget(demands: ExportPartDemand[],
  totalBudget: number): ExportPartGrant[] {
  let grants: ExportPartGrant[] = [];
  for (let i = 0; i < demands.length; i++) {
    grants.push({ id: demands[i].id, granted: 0, truncated: false });
  }
  if (demands.length === 0) return grants;

  let totalDemand = 0;
  for (let i = 0; i < demands.length; i++) {
    totalDemand += demands[i].bytes > 0 ? demands[i].bytes : 0;
  }

  // 不限，或者装得下 ⇒ 全给
  if (totalBudget <= 0 || totalDemand <= totalBudget) {
    for (let i = 0; i < demands.length; i++) {
      grants[i].granted = demands[i].bytes > 0 ? demands[i].bytes : 0;
    }
    return grants;
  }

  // 按优先级排出处理顺序（稳定：同优先级保持原顺序）
  let order: number[] = [];
  for (let i = 0; i < demands.length; i++) order.push(i);
  order.sort((a, b) => {
    let d = demands[a].priority - demands[b].priority;
    return d !== 0 ? d : a - b;
  });

  let remaining = totalBudget;

  // ── 第一轮：保底
  for (let k = 0; k < order.length; k++) {
    let i = order[k];
    let want = demands[i].bytes > 0 ? demands[i].bytes : 0;
    let floor = demands[i].floorBytes > 0 ? demands[i].floorBytes : 0;
    let give = want < floor ? want : floor;
    if (give > remaining) give = remaining;
    grants[i].granted = give;
    remaining -= give;
    if (remaining <= 0) break;
  }

  // ── 第二轮：余额按未满足需求比例分
  if (remaining > 0) {
    let unmetTotal = 0;
    for (let i = 0; i < demands.length; i++) {
      let want = demands[i].bytes > 0 ? demands[i].bytes : 0;
      let unmet = want - grants[i].granted;
      if (unmet > 0) unmetTotal += unmet;
    }
    if (unmetTotal > 0) {
      let handedOut = 0;
      for (let k = 0; k < order.length; k++) {
        let i = order[k];
        let want = demands[i].bytes > 0 ? demands[i].bytes : 0;
        let unmet = want - grants[i].granted;
        if (unmet <= 0) continue;
        let share = Math.floor(remaining * unmet / unmetTotal);
        if (share > unmet) share = unmet;
        grants[i].granted += share;
        handedOut += share;
      }
      // ── 找零：取整会剩下一点，按优先级补给还差的 part，别浪费预算
      let leftover = remaining - handedOut;
      for (let k = 0; k < order.length && leftover > 0; k++) {
        let i = order[k];
        let want = demands[i].bytes > 0 ? demands[i].bytes : 0;
        let unmet = want - grants[i].granted;
        if (unmet <= 0) continue;
        let give = unmet < leftover ? unmet : leftover;
        grants[i].granted += give;
        leftover -= give;
      }
    }
  }

  for (let i = 0; i < demands.length; i++) {
    let want = demands[i].bytes > 0 ? demands[i].bytes : 0;
    grants[i].truncated = grants[i].granted < want;
  }
  return grants;
}

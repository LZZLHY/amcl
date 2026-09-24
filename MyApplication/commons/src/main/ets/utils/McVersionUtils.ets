/**
 * McVersionUtils.ets — Minecraft 版本号比较与路由工具
 *
 * 抽出来是因为 JdkManager.autoSelectVersion / ForgeService.getForgeInstallerJdkVersion
 * 都需要"MC 1.20.5 是不是 ≥ 1.20.5"这种判断；如果各自实现一个，未来任何额外节点
 * 都要双向同步。
 *
 * ============================================================
 *  ⚠️ 两个版本号"纪元"（2026-05-30 JDK25-NEW 加入新纪元支持）
 * ============================================================
 *
 * MC 在 26.1 "Tiny Takeover"（2026-03-24）启用了全新的 YY.D.H 版本号格式，
 * 与旧的 1.x.y 不兼容、且无法在同一数字空间里比较大小：
 *
 *   旧纪元（CLASSIC）：1.x / 1.x.y          首段恒为 1（如 1.20.4 / 1.21 / 1.20.5）
 *   新纪元（YEARLY） ：YY.D / YY.D.H        首段是年份 ≥ 22（如 26.1 / 26.1.2 / 26.2）
 *
 * 实测 Mojang manifest 真实 ID（version_manifest_v2.json，2026-05 抓取）：
 *   release      : 26.1 / 26.1.1 / 26.1.2 / 26.2
 *   snapshot     : 26.2-snapshot-8 / 26.2-snapshot-1
 *   week-snapshot: 26w14a（周快照沿用旧 YYwWWn 格式，仍不可比较）
 *   pre-release  : 26.2-pre-2 / 26.2-pre-1
 *   rc           : 26.1.2-rc-1
 *
 * 关键陷阱（这是 JDK 路由的"逻辑炸弹"，本次重构就是为了拆它）：
 *   旧的 isMcVersionAtLeast('26.1', '1.20.5') 会按 26 > 1 返回 true，
 *   让 JdkManager.autoSelectVersion 误把 26.1 路由到 JDK 21（而它需要 JDK 25）。
 *   解决：先判纪元，跨纪元不进数字比较；同纪元才比数字。
 *
 * ============================================================
 *  当前用法
 * ============================================================
 *   compareMcVersion('1.20.5', '1.20.5') === 0
 *   compareMcVersion('1.20.4', '1.20.5') === -1
 *   compareMcVersion('1.21', '1.20.5')   === 1
 *   compareMcVersion('23w14a', '1.20.5') === 0   ← 快照走 fallback（不强切版本）
 *   compareMcVersion('26.1', '1.20.5')   === 1   ← 跨纪元：新纪元恒 > 旧纪元
 *   detectMcEra('26.1') === McEra.YEARLY
 *   detectMcEra('1.20.4') === McEra.CLASSIC
 *
 * 失败语义：任意一侧无法解析就返回 0 / false（不抛异常，让上层走默认决策）。
 */

/** MC 版本号纪元。UNKNOWN 表示快照 / 异常等无法可靠归类的输入。 */
export enum McEra {
  CLASSIC = 'classic',   // 1.x.y（首段 = 1）
  YEARLY = 'yearly',     // YY.D.H（首段 = 年份 ≥ 22）
  UNKNOWN = 'unknown',   // 周快照 / 空 / 非法
}

// 新纪元年份下限：22（2022）。旧纪元 1.x 的首段恒为 1，绝不会 ≥ 22，
// 因此用 22 作阈值可干净区分两个纪元，且给历史/未来留足缓冲。
const YEARLY_ERA_MIN_FIRST_SEGMENT = 22;

/**
 * 判断版本号属于哪个纪元。
 *   - 首段 == 1            → CLASSIC（1.x.y）
 *   - 首段 >= 22           → YEARLY（YY.D.H）
 *   - 周快照 / 空 / 非法    → UNKNOWN
 *
 * 注意：本函数只看"核心数字段的首段"，会先剥掉 -pre/-rc/-snapshot 等后缀
 * （如 26.2-pre-2 → 26.2 → 首段 26 → YEARLY）。周快照（26w14a）含 'w'，
 * 解析失败 → UNKNOWN（与旧行为一致，走默认决策不强切）。
 */
export function detectMcEra(v: string): McEra {
  let parts = parseMcVersionParts(v);
  if (parts === null || parts.length === 0) return McEra.UNKNOWN;
  let first = parts[0];
  if (first === 1) return McEra.CLASSIC;
  if (first >= YEARLY_ERA_MIN_FIRST_SEGMENT) return McEra.YEARLY;
  // 首段既不是 1 也不到 22：理论上不存在（MC 没出过 2.x ~ 21.x），
  // 当成 UNKNOWN 保守处理，避免误判。
  return McEra.UNKNOWN;
}

/**
 * 比较两个 MC 版本号，返回：
 *   -1 if a < b
 *    0 if a == b 或 任意一边解析失败
 *    1 if a > b
 *
 * 跨纪元比较：YEARLY 恒 > CLASSIC（26.x 永远比 1.x 新）。
 * 任意一边 UNKNOWN（快照等）→ 0（不可比，走默认）。
 */
export function compareMcVersion(a: string, b: string): number {
  let eraA = detectMcEra(a);
  let eraB = detectMcEra(b);
  if (eraA === McEra.UNKNOWN || eraB === McEra.UNKNOWN) return 0;

  // 跨纪元：YEARLY > CLASSIC，不进数字逐段比较（26 vs 1 的数字比较恰好也成立，
  // 但显式处理更清晰，且防止未来纪元规则变化时静默出错）。
  if (eraA !== eraB) {
    return eraA === McEra.YEARLY ? 1 : -1;
  }

  // 同纪元：逐段数字比较
  let pa = parseMcVersionParts(a);
  let pb = parseMcVersionParts(b);
  if (pa === null || pb === null) return 0;
  let n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    let va = i < pa.length ? pa[i] : 0;
    let vb = i < pb.length ? pb[i] : 0;
    if (va > vb) return 1;
    if (va < vb) return -1;
  }
  return 0;
}

/**
 * 把 "1.20.4" / "1.21-pre1" / "26.1" / "26.2-pre-2" / "26.2-snapshot-8"
 * 拆成数字段（pre/rc/snapshot 等 dash 后缀剥掉，按其所属 release 算）。
 *   "1.20.4"           → [1, 20, 4]
 *   "26.1"             → [26, 1]
 *   "26.2-pre-2"       → [26, 2]
 *   "26.2-snapshot-8"  → [26, 2]
 *   "26.1.2-rc-1"      → [26, 1, 2]
 * 周快照 "23w14a" / "26w14a" / 异常输入返回 null（含 'w' 或非数字段）。
 *
 * 已导出为共享工具：NeoForgeService 复用它解析 NeoForge 版本号（`26.1.2.76` →
 * [26,1,2,76] / `21.11.42` → [21,11,42]），统一“剥后缀 + 逐段转数字”逻辑（单一事实源）。
 */
export function parseMcVersionParts(v: string): number[] | null {
  if (!v || v.length === 0) return null;
  // 先剥 dash 后缀（pre / rc / snapshot：1.21-pre1 / 26.2-pre-2 / 26.2-snapshot-8）
  let dashIdx = v.indexOf('-');
  let core = dashIdx >= 0 ? v.substring(0, dashIdx) : v;
  // 周快照不能解析（如 23w14a / 26w14a 含 'w'）
  if (core.indexOf('w') >= 0) return null;
  let parts = core.split('.');
  let out: number[] = [];
  for (let p of parts) {
    if (p.length === 0) return null;
    let x = parseInt(p, 10);
    if (isNaN(x)) return null;
    out.push(x);
  }
  return out;
}

/**
 * 判断 MC 版本是否 ≥ 给定阈值（左闭区间）。
 *
 * ⚠️ 仅用于"同纪元"阈值判断（阈值通常是 CLASSIC 的 1.20.5）。
 * 跨纪元语义：
 *   - version 是 YEARLY、threshold 是 CLASSIC → true（新纪元恒 ≥ 任何旧版本）
 *   - version 是 CLASSIC、threshold 是 YEARLY → false
 *   - 任意一边 UNKNOWN（快照 / 空 / 非法）→ false（保守走低版本路径）
 *
 * 例：isMcVersionAtLeast('1.20.5', '1.20.5') === true
 *     isMcVersionAtLeast('1.20.4', '1.20.5') === false
 *     isMcVersionAtLeast('23w14a', '1.20.5') === false
 *     isMcVersionAtLeast('26.1',  '1.20.5')  === true   ← 新纪元 ≥ 旧阈值
 */
export function isMcVersionAtLeast(version: string, threshold: string): boolean {
  let cmp = compareMcVersion(version, threshold);
  // compareMcVersion 返回 0 既可能是"相等"也可能是"不可比"。
  // 用 detectMcEra 区分：两边都可归类才认 0 == "相等 → true"，
  // 否则（任意 UNKNOWN）0 == "不可比 → false"。
  if (cmp === 0) {
    let ev = detectMcEra(version);
    let et = detectMcEra(threshold);
    if (ev === McEra.UNKNOWN || et === McEra.UNKNOWN) return false;
    return true; // equal
  }
  return cmp > 0;
}

/**
 * 给定【干净的 MC 版本号】（如 "1.21.6" / "1.20.4" / "26.1"，非 version-id），返回运行/安装所需
 * 的最低 JDK 大版本：YEARLY(26.1+)→25，CLASSIC≥1.20.5→21，其余→17。
 *
 * 与 JdkManager.requiredJdkMajor 同一套纪元判定（JdkManager 现委托本函数，单一事实源）。
 * 注意：调用方需先把 version-id 归一化为干净 MC 版本（mods.extractGameVersionFromId），
 * commons 不依赖 mods，故本函数不做归一化。
 */
export function requiredJdkMajorForMc(mcVersion: string): number {
  let era = detectMcEra(mcVersion);
  if (era === McEra.YEARLY) return 25;
  if (era === McEra.CLASSIC && isMcVersionAtLeast(mcVersion, '1.20.5')) return 21;
  return 17;
}

/**
 * 从【已安装的 JDK 大版本集合】里挑一个能满足 requiredMajor 的：**取 ≥required 中最低的**
 * （保守，优先 21 而非 25，减少新 HotSpot 在 OHOS fork 路径的风险）。没有满足的返回 0。
 */
export function pickInstalledJdkMajor(requiredMajor: number, installedMajors: number[]): number {
  let sorted = installedMajors.slice().sort((a: number, b: number) => a - b);
  for (let m of sorted) {
    if (m >= requiredMajor) return m;
  }
  return 0;
}

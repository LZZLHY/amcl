/**
 * PhysicalHeldKeyTracker.ets — 实体键盘 held 状态的按设备追踪器
 *
 * 归属与动机（docs/refactor/实体键鼠输入架构重构计划.md §5.2 / §6.4 / Phase 3.3）：
 *
 *   native `InputStateCore` 用 `HeldId{deviceId, kind, code}` 作为 held owner 的唯一键。
 *   ArkTS 侧过去只维护一个不带设备维度的 `Set<number>`，于是：
 *     - 两把实体键盘同时按 W 时，第二把的 Down 被误判成 REPEAT；
 *     - 其中任意一把抬起就把聚合 W 判为已释放，另一把仍按着的键提前结束。
 *   这正是计划 §10.1 "两把键盘同时按 W" 与 P0-2 描述的失败模式。
 *
 *   本类只负责 ArkTS 侧的两件事，且都必须与 core 的 owner 语义一致：
 *     1. repeat 分类：`(deviceId, ohosKey)` 是否已按住 —— 与 core 的 HeldId 同维度；
 *     2. 修饰键聚合：跨设备的 held keyCode 引用计数快照 —— 修饰键是逻辑聚合量，
 *        §5.2 允许它来自 held 快照，但不允许把锁存键（Caps/Num/Scroll）算进来。
 *
 * 边界与失败恢复：
 *   - 本类不是权威状态。native core 才是。blur/overflow/surface reset 会在 ArkUI 不
 *     hide 的情况下清空 core 的 held；调用方必须先对账 reset epoch，再调用本类，并在
 *     epoch 变化时调用 `clear()`。本类无法自己感知 native reset。
 *   - `noteUp` 对未按住的 (device,key) 返回 false 且不改状态：迟到/重复 UP 不会把引用
 *     计数减成负数，也不会凭空生成 owner。core 侧对 ownerless UP 另有诊断。
 *   - `releaseDevice` 返回该设备仍按住的 keyCode，供调用方补发 UP。只影响该设备，
 *     其他设备按住的同一个键继续保留引用（§6.4 "仅释放该 device 的 owners"）。
 *
 * 生产接线与验证边界：
 *   McGamePage 已在进程级 inputDevice 监听的 REMOVED 回调中调用 `releaseDevice`，再以
 *   native `publishDeviceChange` 做权威兜底；session 启动也会发布初始 inventory。
 *   这让代码路径闭合，但 HarmonyOS 回调顺序、真实 deviceId 稳定性和"按住时拔出"
 *   仍属于真机验收项，不能由本类的纯逻辑单测宣称通过。
 *   - 引用计数与 per-device 集合是同一事务内更新的两份索引；任何早退分支都必须让两者
 *     保持一致，否则修饰键会永久卡住。因此所有变更都集中在本文件的 4 个方法里。
 */

/** 一次 Down 的分类结果。 */
export enum HeldKeyDownKind {
  /** 该 (device,key) 首次按下：core 会 acquire owner，后端应发 PRESS。 */
  FirstDown = 0,
  /** 该 (device,key) 已按住：平台自动重复，不新增 owner。 */
  Repeat = 1,
  /**
   * 该 (device,key) 在缓存里仍标为按住，但距上一个 Down 已超出平台重复窗口
   * ⇒ 判定为**陈旧缓存**（中间那个 Up 丢了），已当作首次按下重新登记。
   *
   * 调用方应把它当 FirstDown 用（发 PRESS），并单独计数：它是"某个键失灵"这类
   * 故障唯一的自愈信号，必须可观测，不能静默。
   */
  FirstDownAfterStale = 2,
}

/**
 * 平台自动重复的最大间隔（ms）。超过它的两个连续 Down 不可能是同一次自动重复。
 *
 * 取值依据：HarmonyOS/Android 系的键盘自动重复首延迟通常 ≈400~500ms、后续间隔
 * ≈50~100ms。取 900ms 留足两倍余量，同时远小于人类"按一下、想一想、再按一下"的间隔，
 * 因此不会把真正的自动重复误判成新按下（那会导致重复 PRESS）。
 */
const REPEAT_MAX_GAP_MS = 900

export class PhysicalHeldKeyTracker {
  /** deviceId → 该设备当前按住的 OHOS keyCode 集合。与 core 的 HeldId 同维度。 */
  private byDevice: Map<number, Set<number>> = new Map()
  /** keyCode → 正按住该键的设备数。用于跨设备修饰键聚合，不用于 repeat 判定。 */
  private refs: Map<number, number> = new Map()
  /**
   * `deviceId * 2^21 + ohosKey` → 上一个 Down 的时间戳（ms）。
   *
   * 存在理由（2026-08-19，修"ESC 快按后失灵"）：此前 repeat 判定**只看集合成员**，
   * 没有任何时间边界。一旦某次 Up 丢失（ESC 弹出菜单时焦点转移，快按时概率很高），
   * 该键就永久留在集合里 ⇒ 之后每一次 Down 都被判成 Repeat ⇒ 发 GLFW_REPEAT ⇒
   * native 那边该身份已无 owner ⇒ 记成 ownerless REPEAT 并**丢弃** ⇒ 这个键再也不产生
   * PRESS。而 `clear()` 只在 native reset epoch 变化时被调用，稳态下永远不会发生。
   *
   * 用"上一个 Down 距今是否超过自动重复窗口"就能把这种陈旧缓存与真正的自动重复分开。
   */
  private lastDownAtMs: Map<number, number> = new Map()

  /**
   * 记录一次 Down。
   * 返回 FirstDown 表示这是该设备对该键的首次按下；Repeat 表示平台自动重复；
   * FirstDownAfterStale 表示缓存里的按住状态已陈旧（中间的 Up 丢了），已自愈。
   */
  noteDown(deviceId: number, ohosKey: number): HeldKeyDownKind {
    let keys: Set<number> | undefined = this.byDevice.get(deviceId)
    if (keys === undefined) {
      keys = new Set<number>()
      this.byDevice.set(deviceId, keys)
    }
    const stamp: number = PhysicalHeldKeyTracker.stampKey(deviceId, ohosKey)
    const now: number = Date.now()
    if (keys.has(ohosKey)) {
      const last: number | undefined = this.lastDownAtMs.get(stamp)
      // 有上一个 Down 且在重复窗口内 ⇒ 真正的平台自动重复。
      if (last !== undefined && now - last <= REPEAT_MAX_GAP_MS) {
        this.lastDownAtMs.set(stamp, now)
        return HeldKeyDownKind.Repeat
      }
      // 否则这份"按住"是陈旧的：中间那个 Up 没送到。引用计数已经为该键记过一次，
      // 所以**不能**再加一次（否则修饰键会永久卡住）；只刷新时间戳并告知调用方
      // 按首次按下处理，让 native 重新 acquire owner。
      this.lastDownAtMs.set(stamp, now)
      return HeldKeyDownKind.FirstDownAfterStale
    }
    keys.add(ohosKey)
    this.refs.set(ohosKey, (this.refs.get(ohosKey) ?? 0) + 1)
    this.lastDownAtMs.set(stamp, now)
    return HeldKeyDownKind.FirstDown
  }

  /** (deviceId, ohosKey) → 单一数值键。OHOS keyCode 远小于 2^21。 */
  private static stampKey(deviceId: number, ohosKey: number): number {
    return deviceId * 2097152 + ohosKey
  }

  /**
   * 记录一次 Up。返回 true 表示该 (device,key) 之前确实按住（本次是真实的释放边沿）。
   * 返回 false 时状态完全不变，调用方应把它当作 ownerless UP 处理。
   */
  noteUp(deviceId: number, ohosKey: number): boolean {
    const keys: Set<number> | undefined = this.byDevice.get(deviceId)
    if (keys === undefined || !keys.has(ohosKey)) return false
    keys.delete(ohosKey)
    if (keys.size === 0) this.byDevice.delete(deviceId)
    this.lastDownAtMs.delete(PhysicalHeldKeyTracker.stampKey(deviceId, ohosKey))
    this.decrementRef(ohosKey)
    return true
  }

  /**
   * 设备移除：清掉该设备的全部 held，并返回被释放的 keyCode 列表。
   * 其他设备按住的同一个键不受影响（引用计数只减 1）。
   */
  releaseDevice(deviceId: number): number[] {
    const released: number[] = []
    const keys: Set<number> | undefined = this.byDevice.get(deviceId)
    if (keys === undefined) return released
    keys.forEach((k: number) => { released.push(k) })
    this.byDevice.delete(deviceId)
    for (let i = 0; i < released.length; i++) {
      this.decrementRef(released[i])
      this.lastDownAtMs.delete(
        PhysicalHeldKeyTracker.stampKey(deviceId, released[i]))
    }
    return released
  }

  /** 幂等地丢弃全部缓存。用于 native reset epoch 变化、页面 hide / dispose。 */
  clear(): void {
    this.byDevice.clear()
    this.refs.clear()
    this.lastDownAtMs.clear()
  }

  /**
   * 跨设备聚合的 held keyCode 快照。只用于算修饰键掩码，不代表 owner 数量。
   * 返回新集合，调用方修改它不会影响内部状态。
   */
  heldKeys(): Set<number> {
    const snapshot: Set<number> = new Set<number>()
    this.refs.forEach((count: number, key: number) => {
      if (count > 0) snapshot.add(key)
    })
    return snapshot
  }

  /** 当前 (device,key) owner 总数。仅用于诊断/断言。 */
  ownerCount(): number {
    let total = 0
    this.byDevice.forEach((keys: Set<number>) => { total += keys.size })
    return total
  }

  /** 该设备是否按住该键。仅用于诊断/测试。 */
  isHeld(deviceId: number, ohosKey: number): boolean {
    const keys: Set<number> | undefined = this.byDevice.get(deviceId)
    return keys !== undefined && keys.has(ohosKey)
  }

  private decrementRef(ohosKey: number): void {
    const next = (this.refs.get(ohosKey) ?? 0) - 1
    if (next > 0) this.refs.set(ohosKey, next)
    else this.refs.delete(ohosKey)
  }
}

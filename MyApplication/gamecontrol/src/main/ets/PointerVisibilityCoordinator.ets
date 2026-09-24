import { AppLogger } from 'commons';
import pointer from '@ohos.multimodalInput.pointer'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'PointerVisibility'

/**
 * 系统指针可见性的唯一所有者。
 *
 * 契约：`grabbed && hasMouse` 时隐藏，其余情况可见。
 *
 * ============================ 为什么不是"改一次就完事" ============================
 * 真机现象（2026-08-19，用户报告 + 日志确认）：ESC 进菜单后**不移动鼠标**再按 ESC 回游戏，
 * 系统光标不隐藏；而如果在菜单里移动过鼠标，回游戏就能正确隐藏。
 *
 * 日志证明我们**确实**调用了 `setPointerVisible(false)` 且没有抛异常
 * （`pointer hidden (grabbed=1, hasMouse=1)` 每次都打出来了），所以问题不在"有没有调"，
 * 而在"这次调用有没有真的生效"。可能的原因有两类，我们**无法从应用侧区分**：
 *   1. 平台把可见性变更推迟到下一个指针事件才应用 —— 指针不动就一直画着旧光标；
 *   2. 同一时刻我们还在调 `OH_WindowManager_LockCursor`（`onGrabbedChanged` 里 lock 是
 *      同步调用，而本类是 async 且没有被 await），两者对光标的处置可能互相覆盖。
 *
 * 既然区分不了，就不要赌。本类因此有两条防线：
 *
 *   · **串行化**：所有变更进同一条 promise 链。此前 `sync()` 是裸 async，
 *     两次快速的 grab 翻转会让两个调用交错，后到的那次可能在前一次写回
 *     `this.current` 之前就读到旧值，从而**早退不发**（`target === this.current`）。
 *   · **有界重申**：一次变更之后的若干个 tick 内，无条件重新下发同一个目标值，
 *     不看缓存。这样"调用了但没生效"会在数百毫秒内被纠正，而不是等到玩家动一下鼠标。
 *     重申是有界的（不是每帧无脑重发），稳态下完全静默。
 */
class PointerVisibilityCoordinator {
  /** 当前**已确认下发**的可见性。初始假定 true（系统默认可见）。 */
  private current: boolean = true
  /** 最近一次失败标志，避免高频重试刷日志。 */
  private failed: boolean = false
  /** 串行化：所有平台调用排在这条链上，杜绝交错。 */
  private chain: Promise<void> = Promise.resolve()
  /** 期望值。重申以它为准，而不是以 `current` 为准。 */
  private desired: boolean = true
  /** 还剩多少次重申。>0 时 `tick()` 会无条件重新下发。 */
  private reassertTicksLeft: number = 0

  /**
   * 一次变更之后重申多少个 tick。调用方的轮询是 250ms，取 4 ≈ 1 秒。
   *
   * 为什么是"有界"而不是"一直重申"：`setPointerVisible` 是跨进程调用，
   * 常态每秒 4 次纯属浪费；而"调用没生效"是个瞬时问题，1 秒足够覆盖。
   */
  private static readonly REASSERT_TICKS = 4

  /**
   * 按 grabbed + hasMouse 同步指针可见性。
   * @param grabbed McGamePage 的 isInGame 状态
   * @param hasMouse getInputDeviceMonitor().capabilityNow().mouse
   */
  sync(grabbed: boolean, hasMouse: boolean): void {
    const target = !(grabbed && hasMouse)
    if (target !== this.desired) {
      // 目标变了：重新开始重申窗口。
      this.reassertTicksLeft = PointerVisibilityCoordinator.REASSERT_TICKS
    }
    this.desired = target
    if (target === this.current && this.reassertTicksLeft <= 0) return
    this.enqueue(target)
  }

  /**
   * 由调用方的既有轮询驱动（不要新开定时器）。
   * 在重申窗口内无条件重新下发期望值；窗口外零成本返回。
   */
  tick(): void {
    if (this.reassertTicksLeft <= 0) return
    this.reassertTicksLeft--
    this.enqueue(this.desired)
  }

  /** 把一次平台调用排进串行链。 */
  private enqueue(target: boolean): void {
    this.chain = this.chain.then(() => this.apply(target))
  }

  private async apply(target: boolean): Promise<void> {
    // 期望值可能在排队期间又变了；只下发最新的那个，避免把已经过期的状态写回去。
    if (target !== this.desired) return
    try {
      await pointer.setPointerVisible(target)
      const changed = target !== this.current
      this.current = target
      this.failed = false
      // 只在真的发生变化时打日志；重申命中同一状态时静默，否则会每秒刷 4 条。
      if (changed) {
        hilog.info(0x0000, TAG, 'pointer %{public}s (desired=%{public}s)',
          target ? 'visible' : 'hidden', target ? 'visible' : 'hidden')
      }
    } catch (e) {
      if (!this.failed) {
        AppLogger.warn(TAG, `setPointerVisible(${target ? 'true' : 'false'}) failed: ${(e as Error).message}`)
        this.failed = true
      }
    }
  }

  /**
   * 强制恢复可见。McGamePage.aboutToDisappear / onPageHide 必调，
   * 避免应用切走 / 进程退出后光标依然不可见，影响其他应用。
   */
  restore(): void {
    this.desired = true
    this.reassertTicksLeft = 0
    if (this.current) return
    this.enqueue(true)
  }
}

let _instance: PointerVisibilityCoordinator | null = null

export function getPointerVisibility(): PointerVisibilityCoordinator {
  if (_instance === null) _instance = new PointerVisibilityCoordinator()
  return _instance
}

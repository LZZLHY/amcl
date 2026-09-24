/**
 * GameWindowRestorePolicy.ets — desktop 游戏窗口进入/恢复的纯判定。
 *
 * WindowStatusType 的数值来自 @ohos.window：UNDEFINED/FULL_SCREEN/MAXIMIZE/
 * MINIMIZE/FLOATING/SPLIT_SCREEN = 0..5。这里刻意不依赖 ArkUI，使 default 产品的
 * ArkTS 单测也能覆盖 desktop source-set 的窗口决策。
 */

export enum GameWindowStatus {
  Undefined = 0,
  FullScreen = 1,
  Maximize = 2,
  Minimize = 3,
  Floating = 4,
  SplitScreen = 5,
}

export class DesktopGameWindowPlan {
  maximizeOnEnter: boolean = false
  recoverOnRestore: boolean = false

  static resolve(rawStatus: number): DesktopGameWindowPlan {
    const plan = new DesktopGameWindowPlan()
    const status: GameWindowStatus = DesktopGameWindowPlan.normalize(rawStatus)

    // 只把普通浮动窗口（以及平台暂时答不出状态的可见窗口）切到最大化。
    // 已经全屏/最大化时重复调用会报 1300001；split/minimize 又无法由 recover
    // 精确还原到原状态，因此保持原模式，只接管布局与系统栏。
    if (status === GameWindowStatus.Floating ||
        status === GameWindowStatus.Undefined) {
      plan.maximizeOnEnter = true
      plan.recoverOnRestore = true
    }
    return plan
  }

  private static normalize(rawStatus: number): GameWindowStatus {
    if (!Number.isFinite(rawStatus)) return GameWindowStatus.Undefined
    const value: number = Math.trunc(rawStatus)
    if (value < GameWindowStatus.Undefined || value > GameWindowStatus.SplitScreen) {
      return GameWindowStatus.Undefined
    }
    return value as GameWindowStatus
  }
}

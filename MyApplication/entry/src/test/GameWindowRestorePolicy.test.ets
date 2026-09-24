/** GameWindowRestorePolicy.test.ets — desktop 最大化与可恢复边界的纯判定。 */

import { describe, it, expect } from '@ohos/hypium'
import {
  DesktopGameWindowPlan,
  GameWindowStatus,
} from '../main/ets/window/GameWindowRestorePolicy'

export default function gameWindowRestorePolicyTest(): void {
  describe('GameWindowRestorePolicy', () => {
    it('普通浮动窗口进入时最大化，退出时只 recover 一次', 0, () => {
      const plan: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.Floating)
      expect(plan.maximizeOnEnter).assertTrue()
      expect(plan.recoverOnRestore).assertTrue()
    })

    it('平台暂时答不出状态时仍按可见浮动窗口处理', 0, () => {
      const undefinedPlan: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.Undefined)
      const invalidPlan: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(99)
      const nanPlan: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(Number.NaN)
      expect(undefinedPlan.maximizeOnEnter).assertTrue()
      expect(invalidPlan.maximizeOnEnter).assertTrue()
      expect(nanPlan.maximizeOnEnter).assertTrue()
      expect(invalidPlan.recoverOnRestore).assertTrue()
    })

    it('已有全屏或最大化状态不得重复 maximize/recover', 0, () => {
      const fullScreen: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.FullScreen)
      const maximized: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.Maximize)
      expect(fullScreen.maximizeOnEnter).assertFalse()
      expect(fullScreen.recoverOnRestore).assertFalse()
      expect(maximized.maximizeOnEnter).assertFalse()
      expect(maximized.recoverOnRestore).assertFalse()
    })

    it('split/minimize 无公开的原状态重建手段，保持窗口模式不动', 0, () => {
      const split: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.SplitScreen)
      const minimized: DesktopGameWindowPlan = DesktopGameWindowPlan.resolve(
        GameWindowStatus.Minimize)
      expect(split.maximizeOnEnter).assertFalse()
      expect(split.recoverOnRestore).assertFalse()
      expect(minimized.maximizeOnEnter).assertFalse()
      expect(minimized.recoverOnRestore).assertFalse()
    })
  })
}

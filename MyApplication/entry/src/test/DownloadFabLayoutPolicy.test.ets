/** DownloadFabLayoutPolicy.test.ets — PC 浮动窗口坐标与缩放回归。 */

import { describe, it, expect } from '@ohos/hypium'
import {
  DownloadFabLayoutPolicy, DownloadFabPosition,
} from '../main/ets/window/DownloadFabLayoutPolicy'

export default function downloadFabLayoutPolicyTest(): void {
  describe('DownloadFabLayoutPolicy', () => {
    it('初始位置必须由当前窗口而不是物理屏幕决定', 0, () => {
      const fullscreen: DownloadFabPosition =
        DownloadFabLayoutPolicy.initial(1200, 800, 0)
      const floating: DownloadFabPosition =
        DownloadFabLayoutPolicy.initial(760, 500, 0)

      expect(fullscreen.x).assertEqual(1128)
      expect(fullscreen.y).assertEqual(634)
      expect(floating.x).assertEqual(688)
      expect(floating.y).assertEqual(334)
    })

    it('从全屏缩到浮动窗口时默认位置继续吸附窗口右下角', 0, () => {
      const fullscreen: DownloadFabPosition =
        DownloadFabLayoutPolicy.initial(1200, 800, 0)
      const floating: DownloadFabPosition = DownloadFabLayoutPolicy.reflow(
        fullscreen.x, fullscreen.y, 1200, 800, 760, 500, 0)

      expect(floating.x).assertEqual(688)
      expect(floating.y).assertEqual(334)
    })

    it('用户拖到左侧后缩放仍保持左吸附且纵向不越界', 0, () => {
      const resized: DownloadFabPosition = DownloadFabLayoutPolicy.reflow(
        16, 700, 1200, 800, 500, 300, 0)

      expect(resized.x).assertEqual(16)
      expect(resized.y).assertEqual(134)
    })

    it('拖动结束按窗口中线吸附并保证整个圆可见', 0, () => {
      const right: DownloadFabPosition =
        DownloadFabLayoutPolicy.finishDrag(600, 900, 760, 500, 0)
      const left: DownloadFabPosition =
        DownloadFabLayoutPolicy.finishDrag(-100, -100, 760, 500, 0)

      expect(right.x).assertEqual(688)
      expect(right.y).assertEqual(334)
      expect(left.x).assertEqual(16)
      expect(left.y).assertEqual(16)
    })
  })
}

import { GameControls } from './ets/components/GameControls'
import { DesktopGameControlSurface } from './ets/components/DesktopGameControlSurface'
import { ProductInputProfile } from 'entry/ProductInputProfile'

@Component
export struct ProductGameControlSurface {
  @Prop gameDirectory: string = ''
  @Prop realGameVersion: string = ''
  @Prop isGrabbed: boolean = false
  @Prop surfaceContextGeneration: number = 0
  @Prop pageActive: boolean = true
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}
  build() {
    if (ProductInputProfile.current().acceptDirectTouchInGame) {
      GameControls({ isGrabbed: this.isGrabbed, surfaceContextGeneration: this.surfaceContextGeneration,
        // 页面投影与编辑暂停是正常输入生命周期端口；删除试用资格不能切断物理键鼠/手柄的暂停链。
        pageActive: this.pageActive, onInputPause: this.onInputPause,
        gameDirectory: this.gameDirectory,
        realGameVersion: this.realGameVersion })
    } else {
      DesktopGameControlSurface({ isGrabbed: this.isGrabbed,
        surfaceContextGeneration: this.surfaceContextGeneration, pageActive: this.pageActive })
    }
  }
}

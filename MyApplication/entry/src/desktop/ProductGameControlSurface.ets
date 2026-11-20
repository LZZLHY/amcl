import { ThemeColors } from 'commons'
import { DesktopGameControlSurface } from '../main/ets/components/DesktopGameControlSurface'

/** 专用桌面包保留共用游戏页的组件签名，只把实体 IME 需要的状态转交给控制面。 */
@Component
export struct ProductGameControlSurface {
  @Prop toolTheme: ThemeColors = {} as ThemeColors
  @Prop gameDirectory: string = ''
  @Prop realGameVersion: string = ''
  @Prop isGrabbed: boolean = false
  @Prop surfaceContextGeneration: number = 0
  @Prop pageActive: boolean = true
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}

  build() {
    DesktopGameControlSurface({ isGrabbed: this.isGrabbed, pageActive: this.pageActive })
  }
}

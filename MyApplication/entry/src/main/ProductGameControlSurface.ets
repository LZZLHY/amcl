import { ThemeColors } from 'commons'
import { EditorPalette, editorPalette } from './ets/components/TouchEditorTheme'
import { GameControls } from './ets/components/GameControls'
import { DesktopGameControlSurface } from './ets/components/DesktopGameControlSurface'
import { ProductInputProfile } from 'entry/ProductInputProfile'

@Component
export struct ProductGameControlSurface {
  /** 展示快照只映射工具palette，不参与产品/输入路线或布局身份。 */
  @Prop @Watch('syncToolPalette_') toolTheme: ThemeColors = {} as ThemeColors
  /** 实例palette仅在初始化/主题快照变化时生成；抓取态和游戏帧不分配颜色对象。 */
  @State private palette: EditorPalette = new EditorPalette()
  aboutToAppear(): void { this.syncToolPalette_() }
  private syncToolPalette_(): void { this.palette = editorPalette(this.toolTheme) }
  @Prop gameDirectory: string = ''
  @Prop realGameVersion: string = ''
  @Prop isGrabbed: boolean = false
  @Prop surfaceContextGeneration: number = 0
  @Prop pageActive: boolean = true
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}
  build() {
    if (ProductInputProfile.current().acceptDirectTouchInGame) {
      GameControls({ palette: this.palette, isGrabbed: this.isGrabbed, surfaceContextGeneration: this.surfaceContextGeneration,
        // 页面投影与编辑暂停是正常输入生命周期端口；删除试用资格不能切断物理键鼠/手柄的暂停链。
        pageActive: this.pageActive, onInputPause: this.onInputPause,
        // 电脑的触屏模式同样只在启动器设置分辨率，不能用能否直触来判断设备。
        allowLiveResolution: !ProductInputProfile.selection().desktopWindow,
        gameDirectory: this.gameDirectory,
        realGameVersion: this.realGameVersion })
    } else {
      DesktopGameControlSurface({ isGrabbed: this.isGrabbed, pageActive: this.pageActive })
    }
  }
}

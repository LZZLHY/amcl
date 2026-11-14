import { ThemeColors } from 'commons'
import { DesktopPhysicalTextInput } from './DesktopPhysicalTextInput'
import { GameResolutionPanel } from './GameResolutionPanel'
import { EditorPalette, editorPalette } from './TouchEditorTheme'

/**
 * 实体键鼠产品的游戏控制面，声明桌面IME与本局分辨率面板，不创建触控schema。
 *
 * 产品/输入路线在会话准备时已冻结，桌面路线不认领直接触屏，也没有需要安装或
 * 确认的虚拟控件表。真实游戏尺寸、窗口及单位由 XComponent/输入上下文发布；本组件
 * 不从自身布局拼 Native schema，不让旧实例的布局或 Watch 回调改写后来资源。
 * 键盘、鼠标、滚轮与指针抓取继续由 McGamePage/XComponent 的原实体输入链处理。
 */
@Component
export struct DesktopGameControlSurface {
  /** 共同产品参数只向分辨率工具提供显示快照；透明IME底层不将颜色用于输入决议。 */
  @Prop @Watch('syncToolPalette_') toolTheme: ThemeColors = {} as ThemeColors
  /** 仅初始化/主题快照改变时生成实例palette，抓取态、轮询和输入事件不分配颜色对象。 */
  @State private palette: EditorPalette = new EditorPalette()
  /** 保留统一产品组件签名；桌面控制面不读取触控布局或动作配置。 */
  @Prop gameDirectory: string = ''
  /** 保留统一版本入参；本组件不建立触控 GUI 观察或恢复通道。 */
  @Prop realGameVersion: string = ''
  /** 抓取态只决定 IME 请求，不通过 Watch 发布触控表或改变实体输入资格。 */
  @Prop isGrabbed: boolean = false
  /** 保留统一窗口事实入参；真实上下文由原发布者管理，本组件没有安装权。 */
  @Prop surfaceContextGeneration: number = 0
  /** 当前页面投影与抓取态共同声明 IME 意图；资源资格由原文本运行体独立核实。 */
  @Prop pageActive: boolean = true
  /** 分辨率面板借用页面既有暂停入口；关闭/离开时归还，不影响Native失败的独立暂停原因。 */
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}
  @State private resolutionOpen: boolean = false
  @State private widthVp: number = 360
  @State private heightVp: number = 400

  aboutToAppear(): void { this.syncToolPalette_() }
  private syncToolPalette_(): void { this.palette = editorPalette(this.toolTheme) }

  /** 面板只暂停页面输入，不认领触控表；离开组件归还自己的暂停意图。 */
  aboutToDisappear(): void {
    if (this.resolutionOpen) this.onInputPause(false)
  }

  build() {
    Stack() {
      // 沿用原透明占位和命中行为，但不再采样其几何或登记能写 Native 的布局回调。
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      // 保持原物理 IME 组件及条件；它取得自己的 UIContext/文本绑定，不能由空表成功代签。
      DesktopPhysicalTextInput({
        active: this.pageActive && !this.isGrabbed && !this.resolutionOpen
      })
      if (this.resolutionOpen) {
        GameResolutionPanel({ palette: this.palette, screenWidth: this.widthVp, screenHeight: this.heightVp,
          onDone: (): void => { this.resolutionOpen = false; this.onInputPause(false) } })
      } else if (this.pageActive && !this.isGrabbed) {
        Button('分辨率').height(40).margin(12).align(Alignment.TopEnd)
          .backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent)
          .onClick((): void => { this.resolutionOpen = true; this.onInputPause(true) })
          .onTouch((event: TouchEvent): void => { event.stopPropagation() })
          .onMouse((event: MouseEvent): void => { event.stopPropagation() })
          .id('open-game-resolution-desktop')
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area): void => { this.widthVp = Number(area.width); this.heightVp = Number(area.height) })
  }
}

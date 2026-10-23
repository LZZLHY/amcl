import { DesktopPhysicalTextInput } from './DesktopPhysicalTextInput'

/**
 * 实体键鼠产品的游戏控制面，只声明桌面 IME 的真实组件资源与 active 意图。
 *
 * 产品/输入路线在会话准备时已冻结，桌面路线不认领直接触屏，也没有需要安装或
 * 确认的虚拟控件表。真实游戏尺寸、窗口及单位由 XComponent/输入上下文发布；本组件
 * 不从自身布局拼 Native schema，不让旧实例的布局或 Watch 回调改写后来资源。
 * 键盘、鼠标、滚轮与指针抓取继续由 McGamePage/XComponent 的原实体输入链处理。
 */
@Component
export struct DesktopGameControlSurface {
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
  /** 与通用包装保持一致；桌面没有触控编辑覆盖层，不主动请求输入暂停。 */
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}

  build() {
    Stack() {
      // 沿用原透明占位和命中行为，但不再采样其几何或登记能写 Native 的布局回调。
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      // 保持原物理 IME 组件及条件；它取得自己的 UIContext/文本绑定，不能由空表成功代签。
      DesktopPhysicalTextInput({
        active: this.pageActive && !this.isGrabbed
      })
    }
    .width('100%')
    .height('100%')
  }
}

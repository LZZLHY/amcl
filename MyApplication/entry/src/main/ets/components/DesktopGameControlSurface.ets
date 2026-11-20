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
  /** 抓取态只决定 IME 请求。 */
  @Prop isGrabbed: boolean = false
  /** 当前页面投影与抓取态共同声明 IME 意图；资源资格由原文本运行体独立核实。 */
  @Prop pageActive: boolean = true

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

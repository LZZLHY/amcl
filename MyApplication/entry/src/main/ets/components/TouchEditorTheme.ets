/**
 * 游戏内按键编辑面板的静态视觉标记。
 *
 * 颜色、圆角和间距只在 ArkUI 构建节点时读取，不订阅游戏帧、输入采样或传感器数据。
 * 本模块没有可变状态、定时器及生命周期，编辑器关闭后不会为正常游戏增加常驻工作。
 * 面板使用实色背景，避免游戏控件透出后与设置文本混在同一视觉层。
 */
export class EditorTheme {
  static readonly panel: string = '#152128'
  static readonly surface: string = '#24343A'
  static readonly surfaceActive: string = '#294B40'
  static readonly accent: string = '#9EEFC3'
  static readonly text: string = '#F2F7F4'
  static readonly muted: string = '#A7B7B0'
  static readonly stroke: string = '#3A514E'
  static readonly warning: string = '#F1C78A'
  static readonly danger: string = '#FFA4A4'
  static readonly radiusSmall: number = 12
  static readonly radiusPanel: number = 20
}

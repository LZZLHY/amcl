/**
 * 游戏内按键编辑面板的静态视觉标记。
 *
 * 颜色、圆角和间距只在 ArkUI 构建节点时读取，不订阅游戏帧、输入采样或传感器数据。
 * 本模块没有可变状态、定时器及生命周期，编辑器关闭后不会为正常游戏增加常驻工作。
 * 面板使用实色背景，避免游戏控件透出后与设置文本混在同一视觉层。
 */
import { ThemeColors } from 'commons';

/** 仅为没有传入应用主题的旧宿主保留不可变基线；不能在全局覆盖这些静态颜色。 */
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

/** 每个工具宿主独享的显示快照；不属于ControlItem、布局样式、输入配置或持久化JSON。 */
export class EditorPalette {
  panel: ResourceColor = EditorTheme.panel;
  surface: ResourceColor = EditorTheme.surface;
  surfaceActive: ResourceColor = EditorTheme.surfaceActive;
  /** 文字/图标与按钮填充分别定义，深色模式不能将较暗的按钮底色借给小字。 */
  accent: ResourceColor = EditorTheme.accent;
  accentFill: ResourceColor = EditorTheme.accent;
  onAccent: ResourceColor = EditorTheme.panel;
  text: ResourceColor = EditorTheme.text;
  muted: ResourceColor = EditorTheme.muted;
  stroke: ResourceColor = EditorTheme.stroke;
  warning: ResourceColor = EditorTheme.warning;
  danger: ResourceColor = EditorTheme.danger;
  overlay: ResourceColor = '#80000000';
  radiusSmall: number = EditorTheme.radiusSmall;
  radiusPanel: number = EditorTheme.radiusPanel;
}

/**
 * 只把应用显示角色映射到工具chrome。未提供主题字段时兼容旧宿主，不查询偏好或设备，
 * 不订阅输入/游戏帧，也不把任何结果写入用户控件颜色、布局或输入配置。
 */
export function editorPalette(theme: ThemeColors): EditorPalette {
  const result: EditorPalette = new EditorPalette();
  result.panel = theme.bgElevated ?? theme.bgCard ?? result.panel;
  result.surface = theme.bgInput ?? result.surface;
  result.surfaceActive = theme.primaryLight ?? result.surfaceActive;
  result.accent = theme.actionText ?? result.accent;
  result.accentFill = theme.actionPrimary ?? result.accentFill;
  result.onAccent = theme.textOnPrimary ?? result.onAccent;
  result.text = theme.textPrimary ?? result.text;
  result.muted = theme.textSecondary ?? result.muted;
  result.stroke = theme.controlBorder ?? result.stroke;
  result.warning = theme.warningText ?? result.warning;
  result.danger = theme.errorText ?? result.danger;
  result.overlay = theme.overlayShade ?? result.overlay;
  return result;
}

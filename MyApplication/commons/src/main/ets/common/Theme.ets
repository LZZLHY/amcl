/**
 * Theme.ets — 鸿蒙风格主题配色系统
 * 参考 HarmonyOS Design 设计规范
 * 支持明亮/深色/跟随系统三种模式
 */

export enum ThemeMode {
  LIGHT = 0,
  DARK = 1,
  SYSTEM = 2
}

export class ThemeColors {
  // 背景
  bgPrimary: ResourceColor = '#F1F3F5'
  bgSecondary: ResourceColor = '#FFFFFF'
  bgCard: ResourceColor = '#FFFFFF'
  bgInput: ResourceColor = '#F1F3F5'

  // 文字（不透明实色，与设计稿一致）
  textPrimary: ResourceColor = '#1A1A1A'
  textSecondary: ResourceColor = '#666666'
  textHint: ResourceColor = '#999999'
  textOnPrimary: ResourceColor = '#FFFFFF'

  // 主色（鸿蒙蓝）
  primary: ResourceColor = '#007DFF'
  primaryLight: ResourceColor = '#E6F2FF'
  accent: ResourceColor = '#007DFF'
  /** V2 页面的小字号按钮与状态文字使用较深语义色，保留原有图标/品牌主色不变。 */
  actionPrimary: ResourceColor = '#006FE6'
  successText: ResourceColor = '#207A4E'
  warningText: ResourceColor = '#99610B'
  errorText: ResourceColor = '#C34232'

  // 状态
  success: ResourceColor = '#64BB5C'
  successBg: ResourceColor = '#DCFCE7'      // 淺绿：成功 badge 背景
  warning: ResourceColor = '#E78B00'
  warningBg: ResourceColor = '#FEF3C7'      // 淺黄：BETA / OPTIONAL badge 背景
  error: ResourceColor = '#E84026'
  errorBg: ResourceColor = '#FFF5F5'
  disabled: ResourceColor = '#CCCCCC'

  // Tab（FloatingDock 中也复用这两个：active = 选中图标 / 文字色，inactive = 未选中色）
  tabActive: ResourceColor = '#007DFF'
  tabInactive: ResourceColor = '#6B7280'   // 在浅色玻璃 dock 上比 #999 更清晰
  tabBg: ResourceColor = '#CCF1F3F5'        // legacy；新 dock 走 dockBg + blur

  // 注：原来的 dockBg/dockBorder/dockShadow* 已删除。
  // 现在用 HarmonyOS 官方 HdsTabs.barFloatingStyle.systemMaterialEffect
  // （@kit.UIDesignKit，API 23+）直接做沉浸光感，材质由系统按设备性能 +
  // 主题自适应，应用层不再维护 dock 的玻璃/边框/阴影颜色。
  // 文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material

  // 分割线
  divider: ResourceColor = '#E5E5E5'

  // 阴影
  cardShadowColor: ResourceColor = '#1A000000'
  cardShadowRadius: number = 12
  cardRadius: number = 16

  // ====================================================================
  //  v6.5 (2026-05-22) 任务分类配色（DownloadTasksSheet / TaskCard 用）
  // ====================================================================
  taskMcBlue: ResourceColor = '#3B82F6'
  taskMcBg: ResourceColor = '#DBEAFE'
  taskModPurple: ResourceColor = '#8B5CF6'
  taskModBg: ResourceColor = '#EDE9FE'
  taskShaderIndigo: ResourceColor = '#6366F1'
  taskShaderBg: ResourceColor = '#E0E7FF'
  taskRpackPink: ResourceColor = '#EC4899'
  taskRpackBg: ResourceColor = '#FCE7F3'
  taskDatapackTeal: ResourceColor = '#14B8A6'
  taskDatapackBg: ResourceColor = '#CCFBF1'
  taskModpackOrange: ResourceColor = '#F97316'
  taskModpackBg: ResourceColor = '#FFEDD5'
  taskJdkRedOrange: ResourceColor = '#DC2626'
  taskJdkBg: ResourceColor = '#FEE2E2'
}

const LIGHT_THEME: ThemeColors = new ThemeColors()

function createDarkTheme(): ThemeColors {
  let t = new ThemeColors()
  t.bgPrimary = '#000000'
  t.bgSecondary = '#1A1A1A'
  t.bgCard = '#1A1A1A'
  t.bgInput = '#2C2C2C'
  t.textPrimary = '#E5E5E5'
  t.textSecondary = '#999999'
  t.textHint = '#666666'
  t.textOnPrimary = '#FFFFFF'
  t.primary = '#317AF7'
  t.primaryLight = '#1C2A3E'
  t.accent = '#317AF7'
  // 深色卡片使用提亮的状态文字；主按钮仍保留白字可读的蓝色底。
  t.actionPrimary = '#256BD9'
  t.successText = '#82D59A'
  t.warningText = '#F3C568'
  t.errorText = '#FF9A8B'
  t.success = '#6DB86B'
  t.successBg = '#14331F'                    // 深绿：多深背景上仍能识别 "成功" 语义
  t.warning = '#E78B00'
  t.warningBg = '#3B2A0A'                    // 深黄：BETA badge 深色背景
  t.error = '#E84026'
  t.errorBg = '#2D1414'
  t.disabled = '#444444'
  t.tabActive = '#317AF7'
  t.tabInactive = '#B8BCC2'                    // 暗色玻璃 dock 上的未选中色：从 #666 提亮到接近白色，确保可读
  t.tabBg = '#CC0A0A0A'                        // legacy
  // dock 玻璃/边框/阴影：见 ThemeColors 基类的注释，全部由系统材质接管
  t.divider = '#333333'
  t.cardShadowColor = '#00000000'
  t.cardShadowRadius = 0
  t.cardRadius = 16
  // 任务分类色：保持饱和度但调暗背景（深色主题徽章背景偏深）
  t.taskMcBlue = '#60A5FA'
  t.taskMcBg = '#1E3A5F'
  t.taskModPurple = '#A78BFA'
  t.taskModBg = '#3B2F6B'
  t.taskShaderIndigo = '#818CF8'
  t.taskShaderBg = '#2E3370'
  t.taskRpackPink = '#F472B6'
  t.taskRpackBg = '#5E1F4A'
  t.taskDatapackTeal = '#2DD4BF'
  t.taskDatapackBg = '#0F4F4A'
  t.taskModpackOrange = '#FB923C'
  t.taskModpackBg = '#5C2E14'
  t.taskJdkRedOrange = '#F87171'
  t.taskJdkBg = '#5E1717'
  return t
}

const DARK_THEME: ThemeColors = createDarkTheme()

export function getTheme(isDark: boolean): ThemeColors {
  return isDark ? DARK_THEME : LIGHT_THEME
}

export function resolveTheme(mode: ThemeMode, systemIsDark: boolean): ThemeColors {
  if (mode === ThemeMode.LIGHT) return LIGHT_THEME
  if (mode === ThemeMode.DARK) return DARK_THEME
  return systemIsDark ? DARK_THEME : LIGHT_THEME
}

export function resolveIsDark(mode: ThemeMode, systemIsDark: boolean): boolean {
  if (mode === ThemeMode.LIGHT) return false
  if (mode === ThemeMode.DARK) return true
  return systemIsDark
}

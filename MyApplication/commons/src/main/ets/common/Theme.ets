/**
 * 全应用主题角色与纯解析层。明暗模式与强调色独立，每次解析返回新快照。
 * 本层不读偏好、不通知UI、不订阅游戏帧；HDS自适应材质仍由系统管理。
 */

export enum ThemeMode {
  LIGHT = 0,
  DARK = 1,
  SYSTEM = 2
}

/** 新配置与旧themeMode共存读取，只有这个单键承载新的成对确认值。 */
export const THEME_SELECTION_KEY: string = 'themeSelectionV1';


/** 稳定存储标识，展示名称不参与存储；未知选择回到已批准的玫晶默认。 */
export enum ThemeAccent { ROSE = 'rose', BLUE = 'blue', TEAL = 'teal', VIOLET = 'violet' }

/** 单键提交的完整主题选择；version只标识偏好格式，不改变安装包版本。 */
export class ThemeSelection {
  version: number = 1;
  mode: ThemeMode;
  accent: ThemeAccent;
  constructor(mode: ThemeMode = ThemeMode.SYSTEM, accent: ThemeAccent = ThemeAccent.ROSE) {
    this.mode = mode;
    this.accent = accent;
  }
}

/** 预设元数据，与具体浅深色快照分开；调用者不得依赖名称推导颜色。 */
export class ThemeAccentOption {
  id: ThemeAccent;
  label: string;
  description: string;
  constructor(id: ThemeAccent, label: string, description: string) {
    this.id = id; this.label = label; this.description = description;
  }
}

/** 仅接受既有三种模式，损坏数值安全回退跟随系统。 */
export function normalizeThemeMode(value: number): ThemeMode {
  return value === ThemeMode.LIGHT ? ThemeMode.LIGHT : value === ThemeMode.DARK ? ThemeMode.DARK : ThemeMode.SYSTEM;
}

/** 主题白名单阻止不可信存储把任意HEX注入全应用。 */
export function normalizeThemeAccent(value: string): ThemeAccent {
  if (value === ThemeAccent.BLUE) return ThemeAccent.BLUE;
  if (value === ThemeAccent.TEAL) return ThemeAccent.TEAL;
  if (value === ThemeAccent.VIOLET) return ThemeAccent.VIOLET;
  return ThemeAccent.ROSE;
}

/** 缺失/损坏新键沿用旧明暗，颜色默认玫晶；读取不写盘、不抢占保存事务。 */
export function decodeThemeSelection(raw: string, legacyMode: ThemeMode = ThemeMode.SYSTEM): ThemeSelection {
  const fallback: ThemeSelection = new ThemeSelection(normalizeThemeMode(legacyMode), ThemeAccent.ROSE);
  if (raw.length === 0) return fallback;
  try {
    const parsed: ThemeSelection = JSON.parse(raw) as ThemeSelection;
    if (parsed === null || parsed.version !== 1) return fallback;
    return new ThemeSelection(typeof parsed.mode === 'number' ? normalizeThemeMode(parsed.mode) : fallback.mode,
      typeof parsed.accent === 'string' ? normalizeThemeAccent(parsed.accent) : ThemeAccent.ROSE);
  } catch (_) { return fallback; }
}

/** 规范化后编码到同一个偏好键，使模式与颜色拥有相同持久确认边界。 */
export function encodeThemeSelection(value: ThemeSelection): string {
  return JSON.stringify(new ThemeSelection(normalizeThemeMode(value.mode), normalizeThemeAccent(value.accent)));
}

/** 新数组避免一个页面的临时排序污染其他消费者。 */
export function themeAccentOptions(): ThemeAccentOption[] {
  return [
    new ThemeAccentOption(ThemeAccent.ROSE, '玫晶', '延续粉色像素斧'),
    new ThemeAccentOption(ThemeAccent.BLUE, '原生蓝', '熟悉的原生工具感'),
    new ThemeAccentOption(ThemeAccent.TEAL, '松石青', '安静清爽'),
    new ThemeAccentOption(ThemeAccent.VIOLET, '鸢尾紫', '偏冷的个性选择')
  ];
}

/** 设置摘要使用方案名，不把内部持久标识展示给用户。 */
export function themeAccentLabel(value: ThemeAccent): string {
  if (value === ThemeAccent.BLUE) return '原生蓝';
  if (value === ThemeAccent.TEAL) return '松石青';
  if (value === ThemeAccent.VIOLET) return '鸢尾紫';
  return '玫晶';
}

/**
 * 完整颜色快照：actionPrimary/textOnPrimary是按钮底与反色字，actionText是操作文字/图标/焦点。
 * legacy primary为填充别名；accent/tabActive为文字别名，不能继续将primary用于任意小字。
 * 状态与资源类别保留独立语义，快照只在配置变化或初始化时重建。
 */
export class ThemeColors {
  isDark: boolean = false;
  accentId: ThemeAccent = ThemeAccent.ROSE;
  /** 提升表面、必要控件边界、按下态和禁用文字分别定义，不能互相借用。 */
  bgElevated: ResourceColor = '#FFFFFF';
  controlBorder: ResourceColor = '#7B8089';
  actionPressed: ResourceColor = '#8F205A';
  disabledText: ResourceColor = '#8D9199';
  disabledBg: ResourceColor = '#E4E6EA';
  overlayShade: ResourceColor = '#80000000';

  // 背景
  bgPrimary: ResourceColor = '#F3F4F6'
  bgSecondary: ResourceColor = '#FFFFFF'
  bgCard: ResourceColor = '#FFFFFF'
  bgInput: ResourceColor = '#E8EAEE'

  // 文字（不透明实色，与设计稿一致）
  textPrimary: ResourceColor = '#1C1D21'
  textSecondary: ResourceColor = '#5E626B'
  textHint: ResourceColor = '#646A73'
  textOnPrimary: ResourceColor = '#FFFFFF'

  // 应用强调角色（默认玫晶）
  primary: ResourceColor = '#AF286D'
  primaryLight: ResourceColor = '#FBE8F1'
  accent: ResourceColor = '#9D2361'
  /** V2 页面的小字号按钮与状态文字使用较深语义色，品牌资产独立保留原色。 */
  actionPrimary: ResourceColor = '#AF286D'
  /** 操作文字与按钮底色分开：深色卡片上的小字号链接需要更亮的蓝色。 */
  actionText: ResourceColor = '#9D2361'
  successText: ResourceColor = '#20754E'
  warningText: ResourceColor = '#8B5B0A'
  errorText: ResourceColor = '#B43530'

  // 状态
  success: ResourceColor = '#20754E'
  successBg: ResourceColor = '#E5F4EB'      // 淺绿：成功 badge 背景
  warning: ResourceColor = '#8B5B0A'
  warningBg: ResourceColor = '#FFF1D4'      // 淺黄：BETA / OPTIONAL badge 背景
  error: ResourceColor = '#B43530'
  errorBg: ResourceColor = '#FCEAE7'
  disabled: ResourceColor = '#E4E6EA'

  // Tab（FloatingDock 中也复用这两个：active = 选中图标 / 文字色，inactive = 未选中色）
  tabActive: ResourceColor = '#9D2361'
  tabInactive: ResourceColor = '#5E626B'   // 在浅色玻璃 dock 上比 #999 更清晰
  tabBg: ResourceColor = '#CCF3F4F6'        // legacy；新 dock 走 dockBg + blur

  // 注：原来的 dockBg/dockBorder/dockShadow* 已删除。
  // 现在用 HarmonyOS 官方 HdsTabs.barFloatingStyle.systemMaterialEffect
  // （@kit.UIDesignKit，API 23+）直接做沉浸光感，材质由系统按设备性能 +
  // 主题自适应，应用层不再维护 dock 的玻璃/边框/阴影颜色。
  // 文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material

  // 分割线
  divider: ResourceColor = '#D7DAE0'

  // 阴影
  cardShadowColor: ResourceColor = '#1A000000'
  cardShadowRadius: number = 12
  cardRadius: number = 16

  // ====================================================================
  //  v6.5 (2026-05-22) 任务分类配色（DownloadTasksSheet / TaskCard 用）
  // ====================================================================
  taskMcBlue: ResourceColor = '#2459A2'
  taskMcBg: ResourceColor = '#DBEAFE'
  taskModPurple: ResourceColor = '#6440AB'
  taskModBg: ResourceColor = '#EDE9FE'
  taskShaderIndigo: ResourceColor = '#4A46A5'
  taskShaderBg: ResourceColor = '#E0E7FF'
  taskRpackPink: ResourceColor = '#9D2361'
  taskRpackBg: ResourceColor = '#FCE7F3'
  taskDatapackTeal: ResourceColor = '#00685F'
  taskDatapackBg: ResourceColor = '#CCFBF1'
  taskModpackOrange: ResourceColor = '#98500B'
  taskModpackBg: ResourceColor = '#FFEDD5'
  taskJdkRedOrange: ResourceColor = '#B43530'
  taskJdkBg: ResourceColor = '#FEE2E2'
}

/** 同一强调方案的填充、文字、容器和按下态分别取值。 */
interface AccentPalette { fill: string; ink: string; soft: string; pressed: string; }

/** 明暗色显式配套，不依赖系统替literal颜色自动生成可读深色值。 */
function accentPalette(accent: ThemeAccent, dark: boolean): AccentPalette {
  if (accent === ThemeAccent.BLUE) return dark
    ? { fill: '#256BD9', ink: '#9FC3FF', soft: '#172A49', pressed: '#1D54AA' }
    : { fill: '#006FE6', ink: '#0062CD', soft: '#E9F1FF', pressed: '#0058B8' };
  if (accent === ThemeAccent.TEAL) return dark
    ? { fill: '#087E73', ink: '#81D8C9', soft: '#12352F', pressed: '#06665E' }
    : { fill: '#006D66', ink: '#00685F', soft: '#DDF3EE', pressed: '#00564F' };
  if (accent === ThemeAccent.VIOLET) return dark
    ? { fill: '#7352BA', ink: '#CEB4FF', soft: '#2F2347', pressed: '#5C4197' }
    : { fill: '#6B48B3', ink: '#6440AB', soft: '#F0E9FB', pressed: '#54368F' };
  return dark ? { fill: '#B53378', ink: '#FFACD1', soft: '#371E2B', pressed: '#92265E' }
    : { fill: '#AF286D', ink: '#9D2361', soft: '#FBE8F1', pressed: '#8F205A' };
}

/** 每次生成独立快照，防止修改一个主题污染隐藏页或另一方案；禁止放入游戏帧循环。 */
export function getTheme(isDark: boolean, accent: ThemeAccent = ThemeAccent.ROSE): ThemeColors {
  const t: ThemeColors = new ThemeColors();
  t.isDark = isDark;
  t.accentId = normalizeThemeAccent(accent);
  if (isDark) {
    t.bgPrimary = '#101114';
    t.bgSecondary = '#1C1D21';
    t.bgCard = '#1C1D21';
    t.bgElevated = '#25262B';
    t.bgInput = '#2B2D33';
    t.textPrimary = '#F2F3F5';
    t.textSecondary = '#B2B6BF';
    t.textHint = '#9DA3AD';
    t.successText = '#8AD9A8';
    t.warningText = '#F3CE86';
    t.errorText = '#FFA89D';
    t.success = '#287B50';
    t.successBg = '#183126';
    t.warning = '#95640E';
    t.warningBg = '#352B18';
    t.error = '#BE443A';
    t.errorBg = '#3E2424';
    t.disabled = '#2B2D33';
    t.disabledText = '#737782';
    t.disabledBg = '#2B2D33';
    t.controlBorder = '#858B96';
    t.tabInactive = '#B2B6BF';
    t.tabBg = '#CC101114';
    t.divider = '#34363D';
    t.cardShadowColor = '#00000000';
    t.taskMcBlue = '#9FC3FF';
    t.taskMcBg = '#1E3A5F';
    t.taskModPurple = '#CEB4FF';
    t.taskModBg = '#3B2F6B';
    t.taskShaderIndigo = '#B9BCFF';
    t.taskShaderBg = '#2E3370';
    t.taskRpackPink = '#FFACD1';
    t.taskRpackBg = '#5E1F4A';
    t.taskDatapackTeal = '#81D8C9';
    t.taskDatapackBg = '#0F4F4A';
    t.taskModpackOrange = '#FFC58C';
    t.taskModpackBg = '#5C2E14';
    t.taskJdkRedOrange = '#FFA89D';
    t.taskJdkBg = '#5E1717';
    t.cardShadowRadius = 0;
  }
  const p: AccentPalette = accentPalette(t.accentId, isDark);
  t.actionPrimary = p.fill; t.actionText = p.ink; t.actionPressed = p.pressed;
  t.primary = p.fill; t.primaryLight = p.soft; t.accent = p.ink; t.tabActive = p.ink;
  return t;
}

/** 显式LIGHT/DARK优先，SYSTEM只表示系统明暗，不意味着壁纸动态取色。 */
export function resolveTheme(mode: ThemeMode, systemIsDark: boolean, accent: ThemeAccent = ThemeAccent.ROSE): ThemeColors {
  return getTheme(resolveIsDark(mode, systemIsDark), accent);
}

/** 开屏、系统栏和材质宿主使用同一个明暗判定，避免颜色与系统chrome分叉。 */
export function resolveIsDark(mode: ThemeMode, systemIsDark: boolean): boolean {
  if (mode === ThemeMode.LIGHT) return false;
  if (mode === ThemeMode.DARK) return true;
  return systemIsDark;
}

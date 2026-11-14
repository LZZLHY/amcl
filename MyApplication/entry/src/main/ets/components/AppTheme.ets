/**
 * 把应用语义角色映射到 ArkUI 原生默认主题，补齐未显式着色的光标、焦点和系统控件。
 *
 * API12的ThemeControl与API20的darkColors已覆盖本项目最低API20；只使用基础角色，
 * 不使用API26新增的primary/onPrimary/container同名映射。深浅值同时提供，避免
 * literal HEX在深色原样沿用。HDS材质、光感档位和系统colorMode仍由既有宿主管理。
 */
import { ThemeControl, CustomColors, CustomDarkColors, CustomTheme } from '@kit.ArkUI';
import { ThemeColors, ThemeAccent, getTheme } from 'commons';

/** 显式颜色映射与应用字段名解耦；官方warning为一级危险，alert才对应一般警告。 */
class NativeThemeColors implements CustomColors, CustomDarkColors {
  brand: ResourceColor;
  fontPrimary: ResourceColor;
  fontSecondary: ResourceColor;
  fontTertiary: ResourceColor;
  fontFourth: ResourceColor;
  fontEmphasize: ResourceColor;
  fontOnPrimary: ResourceColor;
  iconPrimary: ResourceColor;
  iconSecondary: ResourceColor;
  iconEmphasize: ResourceColor;
  iconOnPrimary: ResourceColor;
  backgroundPrimary: ResourceColor;
  backgroundSecondary: ResourceColor;
  backgroundTertiary: ResourceColor;
  backgroundEmphasize: ResourceColor;
  compBackgroundPrimary: ResourceColor;
  compBackgroundSecondary: ResourceColor;
  compBackgroundEmphasize: ResourceColor;
  compEmphasizeSecondary: ResourceColor;
  compEmphasizeTertiary: ResourceColor;
  interactiveFocus: ResourceColor;
  interactiveSelect: ResourceColor;
  warning: ResourceColor;
  alert: ResourceColor;
  confirm: ResourceColor;

  /** 输入为完整已解析快照；不读取偏好、不保存配置、不改变用户的布局内容。 */
  constructor(t: ThemeColors) {
    this.brand = t.actionText;
    this.fontPrimary = t.textPrimary; this.fontSecondary = t.textSecondary;
    this.fontTertiary = t.textHint; this.fontFourth = t.disabledText;
    this.fontEmphasize = t.actionText; this.fontOnPrimary = t.textOnPrimary;
    this.iconPrimary = t.textPrimary; this.iconSecondary = t.textSecondary;
    this.iconEmphasize = t.actionText; this.iconOnPrimary = t.textOnPrimary;
    this.backgroundPrimary = t.bgPrimary; this.backgroundSecondary = t.bgSecondary;
    this.backgroundTertiary = t.bgElevated; this.backgroundEmphasize = t.actionPrimary;
    this.compBackgroundPrimary = t.bgCard; this.compBackgroundSecondary = t.bgInput;
    this.compBackgroundEmphasize = t.actionPrimary;
    this.compEmphasizeSecondary = t.primaryLight; this.compEmphasizeTertiary = t.primaryLight;
    this.interactiveFocus = t.actionText;
    // SDK的interactiveSelect是TreeView等选择容器背景，不是Radio的前景标记。
    this.interactiveSelect = t.primaryLight;
    this.warning = t.error; this.alert = t.warning; this.confirm = t.success;
  }
}

/** 同一方案同时声明浅深值；深浅切换不重新探测材质或重复写默认主题。 */
class NativeAppTheme implements CustomTheme {
  colors: CustomColors;
  darkColors: CustomDarkColors;
  constructor(accent: ThemeAccent) {
    this.colors = new NativeThemeColors(getTheme(false, accent));
    this.darkColors = new NativeThemeColors(getTheme(true, accent));
  }
}

let appliedAccent: ThemeAccent | undefined = undefined;

/**
 * 每个ArkTS进程各自缓存已应用方案。预览和取消调用同一个入口，失败时不推进缓存；
 * 此函数不发布确认revision，持久保存与跨页通知由启动器owner完成。
 */
export function applyNativeTheme(theme: ThemeColors): void {
  if (appliedAccent === theme.accentId) return;
  try {
    ThemeControl.setDefaultTheme(new NativeAppTheme(theme.accentId));
    appliedAccent = theme.accentId;
  } catch (_) { /* 原生默认主题失败不阻止显式角色绘制，也不伪报已应用。 */ }
}

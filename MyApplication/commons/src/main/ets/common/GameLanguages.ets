/**
 * GameLanguages.ets — 游戏语言（Minecraft options.txt `lang`）目录 / 常量
 *
 * 单一事实源：全局设置（SettingsTab）、单版本覆盖（VersionManagerSheet）、
 * 存储层（PreferenceManager）与展示层共用本表。
 *
 * code 采用 **现代 MC（1.11+）小写格式**（如 `zh_cn` / `en_us`）——AMCL 目前适配
 * 1.13+（LWJGL3 纪元），全部走小写；native 侧 applyGameLanguage 会把该 code 原样
 * 写进 `<gameDir>/options.txt` 的 `lang` 键。若未来接入 ≤1.10（需 `zh_CN` 末两位大写），
 * 由 native 侧按版本纪元处理，本表保持小写规范。
 *
 * ⚠️ 修改本表的 code 集合时，必须同步 `entry/src/main/cpp/jvm/mc_launcher.cpp`
 * 的 `isSupportedGameLang` 白名单，两处保持一致，否则 native 会拒绝写入未知语言。
 */

/** 单个游戏语言选项。 */
export interface GameLanguageOption {
  /** MC options.txt `lang` 值（小写，如 'zh_cn'）。同时是持久化存储值。 */
  code: string;
  /** UI 展示名（尽量用该语言母语写法，方便用户辨认）。 */
  label: string;
}

/** 全局默认游戏语言：简体中文。 */
export const DEFAULT_GAME_LANGUAGE: string = 'zh_cn';

/** 单版本覆盖里"跟随全局设置"的哨兵值（空字符串）。 */
export const GAME_LANGUAGE_FOLLOW_GLOBAL: string = '';

/** 支持的游戏语言全集（UI 下拉 + native 白名单的事实源）。 */
export const GAME_LANGUAGES: GameLanguageOption[] = [
  { code: 'zh_cn', label: '简体中文' },
  { code: 'zh_tw', label: '繁體中文（台灣）' },
  { code: 'zh_hk', label: '繁體中文（香港）' },
  { code: 'en_us', label: 'English (US)' },
  { code: 'en_gb', label: 'English (UK)' },
  { code: 'ja_jp', label: '日本語' },
  { code: 'ko_kr', label: '한국어' },
  { code: 'ru_ru', label: 'Русский' },
  { code: 'de_de', label: 'Deutsch' },
  { code: 'fr_fr', label: 'Français' },
  { code: 'es_es', label: 'Español (España)' },
  { code: 'pt_br', label: 'Português (Brasil)' },
  { code: 'it_it', label: 'Italiano' },
  { code: 'vi_vn', label: 'Tiếng Việt' },
];

/** 是否是已支持的游戏语言 code。 */
export function isSupportedGameLanguage(code: string): boolean {
  return GAME_LANGUAGES.some((l: GameLanguageOption) => l.code === code);
}

/** 取游戏语言 code 的展示名；未知 code 原样返回。 */
export function gameLanguageLabel(code: string): string {
  let found = GAME_LANGUAGES.find((l: GameLanguageOption) => l.code === code);
  return found !== undefined ? found.label : code;
}

/**
 * 归一化一个全局游戏语言值：非法 / 未知 → 回退默认（zh_cn）。
 * 用于读盘后兜底（避免 prefs 脏数据把非法 lang 写进 options.txt）。
 */
export function normalizeGlobalGameLanguage(code: string): string {
  return isSupportedGameLanguage(code) ? code : DEFAULT_GAME_LANGUAGE;
}

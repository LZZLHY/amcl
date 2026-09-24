/**
 * SemanticColors.ets — 语义化配色单一事实源（2026-05-23）
 *
 * ============================================================================
 *  为什么有这个文件
 * ============================================================================
 * 历史上以下 3 类"语义色"被在多处硬编码：
 *
 *   1. ModSource（Modrinth 绿 / CurseForge 橙）——品牌色
 *   2. VersionChannel（RELEASE / BETA / ALPHA）——发布通道色
 *   3. DependencyType（REQUIRED / OPTIONAL / INCOMPATIBLE / EMBEDDED）——依赖类型色
 *
 * 它们的颜色值与 LoaderCatalog 的 fabric/forge/neoforge/quilt 配色**巧合相同**：
 *   - "#16A34A" 既是 Fabric 绿、也是 Modrinth 品牌绿、也是 success "已启用" 绿
 *   - "#D97706" 既是 Forge 橙、也是 BETA channel 橙、也是 OPTIONAL 橙
 *   - "#DC2626" 既是 NeoForge 红、也是 REQUIRED 红、也是 ALPHA 红
 *
 * 但**语义**不同——强行合并会导致"改 Fabric 色 → Modrinth badge 也跟着变"这种联动 bug。
 * 所以本文件**独立**维护语义色，与 LoaderCatalog 同色但独立编辑。
 *
 * ============================================================================
 *  分层
 * ============================================================================
 *
 *   品牌色（与 theme 无关，深浅模式都用同款，避免 Modrinth 在 dark mode 突然变色）
 *     - MODRINTH / CURSEFORGE
 *
 *   状态色（走 ThemeColors 浅深自适应）
 *     - BETA / OPTIONAL → theme.warning + theme.warningBg
 *     - ALPHA / REQUIRED → theme.error + theme.errorBg
 *     - RELEASE → theme.primary + theme.primaryLight（"主推 / 稳定"）
 *     - EMBEDDED → theme.textSecondary + theme.bgInput（"默认 / 中性"）
 *
 *   独立色（与 theme / loader 都无关的 "罕见状态"）
 *     - INCOMPATIBLE 紫（NeoForge 也是红、ALPHA 也是红，再加红会撞色 → 用紫醒目）
 */

import { ThemeColors } from 'commons';
import { ModSource, VersionChannel, DependencyType } from 'mods';

/** 一对配套色：前景文字色 + 浅背景色 */
export interface SemanticTone {
  color: ResourceColor;
  bg: ResourceColor;
}

// ============================================================================
//  品牌色（不走 theme，保证两套主题下品牌识别稳定）
// ============================================================================

const TONE_MODRINTH: SemanticTone = { color: '#16A34A', bg: '#DCFCE7' };
const TONE_CURSEFORGE: SemanticTone = { color: '#EA580C', bg: '#FFEDD5' };

/** 默认兜底（未知源 / 未识别）：中性灰背景 */
function neutralTone_(theme: ThemeColors): SemanticTone {
  return { color: theme.textSecondary, bg: theme.bgInput };
}

/**
 * 资源数据源（Modrinth / CurseForge）品牌色。
 * 不接收 theme：品牌色在两套主题下保持识别度。
 */
export function modSourceTone(src: ModSource): SemanticTone {
  if (src === ModSource.MODRINTH) return TONE_MODRINTH;
  if (src === ModSource.CURSEFORGE) return TONE_CURSEFORGE;
  return { color: '#666666', bg: '#F1F3F5' };
}

// ============================================================================
//  发布通道（VersionChannel）色：走 theme，自适应深浅
// ============================================================================

/**
 * 发布通道色。
 *   - RELEASE → primary（"主推"）
 *   - BETA   → warning（"预览，可能不稳"）
 *   - ALPHA  → error（"早期，风险高"）
 */
export function channelTone(ch: VersionChannel, theme: ThemeColors): SemanticTone {
  if (ch === VersionChannel.BETA)  return { color: theme.warning, bg: theme.warningBg };
  if (ch === VersionChannel.ALPHA) return { color: theme.error,   bg: theme.errorBg };
  // RELEASE / 未知 → primary
  return { color: theme.primary, bg: theme.primaryLight };
}

// ============================================================================
//  依赖类型（DependencyType）色：走 theme + 1 个独立紫
// ============================================================================

/** INCOMPATIBLE 专用紫——不走 NeoForge 红，避免与 REQUIRED / ALPHA 撞色 */
const TONE_INCOMPATIBLE: SemanticTone = { color: '#9333EA', bg: '#F3E8FF' };

/**
 * 依赖类型色。
 *   - REQUIRED     → error（"必须装"，醒目红）
 *   - OPTIONAL     → warning（"可选装"，提示黄）
 *   - INCOMPATIBLE → 独立紫（醒目但不与 REQUIRED 撞）
 *   - EMBEDDED     → 中性（"打包内置，无需关心"）
 */
export function depTypeTone(t: DependencyType, theme: ThemeColors): SemanticTone {
  if (t === DependencyType.REQUIRED)     return { color: theme.error,   bg: theme.errorBg };
  if (t === DependencyType.OPTIONAL)     return { color: theme.warning, bg: theme.warningBg };
  if (t === DependencyType.INCOMPATIBLE) return TONE_INCOMPATIBLE;
  return neutralTone_(theme);
}

// ============================================================================
//  account 类型（HomeTab 微软正版 / 离线）—— 极简 helper
// ============================================================================

/**
 * 账号类型 badge 色。
 *
 * 当前只有"是否微软正版"两态；后续如果加 Mojang 账号等可扩展为 enum。
 */
export function accountVerifiedTone(verified: boolean, theme: ThemeColors): SemanticTone {
  if (verified) return { color: theme.success, bg: theme.successBg };
  return { color: theme.textSecondary, bg: theme.bgInput };
}

// ============================================================================
//  更新日志分类（changelog entry type）色
// ============================================================================

/**
 * 更新日志条目分类 badge 色。type 词表见 `update` HAR 的 ChangelogTypes.ets
 * （与 AMCL-web/web/src/changelog/parse.js 的 CATEGORY_ORDER 一一对应）。
 *
 * 配色刻意与网页 /changelog 的分类色**语义对齐**（头条粉 / 新增蓝 / 优化绿 /
 * 重构紫 / 修复靛 / 注意黄），这样同一条更新在网页和 App 里是同一个颜色印象。
 * 六个分类必须互相可区分：头条不能也用主色蓝，否则和"新增"糊在一起。
 *
 * 未知 type → 走 notice（黄），与解析层「未知归 notice」的规则保持一致。
 */
export function changelogTone(type: string, theme: ThemeColors): SemanticTone {
  switch (type) {
    case 'highlight':  return { color: theme.taskRpackPink,    bg: theme.taskRpackBg };
    case 'added':      return { color: theme.primary,          bg: theme.primaryLight };
    case 'improved':   return { color: theme.success,          bg: theme.successBg };
    case 'refactored': return { color: theme.taskModPurple,    bg: theme.taskModBg };
    case 'fixed':      return { color: theme.taskShaderIndigo, bg: theme.taskShaderBg };
    default:           return { color: theme.warning,          bg: theme.warningBg };
  }
}

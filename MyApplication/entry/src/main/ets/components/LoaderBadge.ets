/**
 * LoaderBadge.ets — Mod Loader 统一视觉徽章（2026-05-23）
 *
 * 与 AppIcon / VersionBlockIcon 的分工：
 *   - AppIcon            走 sys.symbol 矢量字体（chevron / settings / play …）
 *   - VersionBlockIcon   走 PNG，按 versionId 推断 vanilla / loader 类别
 *   - LoaderBadge ←本文件 高层语义组件，输入 LoaderKey 即可，
 *                        自动套用 LoaderCatalog 的 PNG / SymbolGlyph / 配色
 *
 * 为什么需要：
 *   FabricApiCard、VersionManagerSheet hero 卡、TaskCard MC_VERSION 徽章
 *   都需要"按 loader 类型展示"。之前各自 import VersionBlockIcon + 自己拼
 *   背景圆角 + 自己写颜色。LoaderBadge 把这些浓缩成一个组件：
 *
 *   LoaderBadge({ loader: 'fabric', size: 44, cornerRadius: 12 })
 *
 * style 选项：
 *   - 'block'  默认。PNG 方块（pixel art，与 PCL2 / 版本管理列表同款）
 *              不画背景容器（PNG 自带主题色）
 *   - 'symbol' SymbolGlyph 矢量。需要单色染色时用（比如菜单项 16×16 小图标）
 *              自动套 accentColor + accentBg 圆角容器
 */

import { LoaderKey, getLoaderInfo } from '../components/LoaderCatalog';
import { AppIcon } from './AppIcon';

@Component
export struct LoaderBadge {
  /** loader 键 */
  @Prop loader: LoaderKey = 'vanilla';
  /** 容器边长（vp）。'block' 风格下也是 PNG 边长 */
  @Prop iconSize: number = 44;
  /** 'block' / 'symbol'，详见文件头注释 */
  @Prop style: string = 'block';
  /** 圆角半径（vp）。block 默认 0（保留 pixel art 锐利角）；symbol 默认 12 圆角卡片感 */
  @Prop cornerRadius: number = -1;
  /** symbol 风格下的图标内边距比例（图标占容器的多少）；默认 0.5 = 22 vp / 44 vp */
  @Prop symbolInsetRatio: number = 0.5;

  build() {
    if (this.style === 'symbol') {
      this.SymbolStyle()
    } else {
      this.BlockStyle()
    }
  }

  // ============================================================
  //  PNG 方块（默认风格）—— 与 VersionBlockIcon 视觉一致
  // ============================================================
  @Builder
  BlockStyle() {
    Image(getLoaderInfo(this.loader).blockMedia)
      .width(this.iconSize)
      .height(this.iconSize)
      .borderRadius(this.cornerRadius >= 0 ? this.cornerRadius : 0)
      .objectFit(ImageFit.Contain)
      .interpolation(ImageInterpolation.None)   // pixel art 关插值
      .syncLoad(true)                           // 防 sheet 弹出瞬间空白
  }

  // ============================================================
  //  SymbolGlyph + accentBg 圆角背景 —— 早期菜单项 / chip 用
  // ============================================================
  @Builder
  SymbolStyle() {
    Stack() {
      AppIcon({
        name: getLoaderInfo(this.loader).iconName,
        iconSize: this.iconSize * this.symbolInsetRatio,
        color: getLoaderInfo(this.loader).accentColor,
      })
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .borderRadius(this.cornerRadius >= 0 ? this.cornerRadius : 12)
    .backgroundColor(getLoaderInfo(this.loader).accentBg)
  }
}

/**
 * VersionBlockIcon.ets — 版本前的 PNG 方块图标
 *
 * 与 AppIcon / LoaderBadge 的分工：
 *   - AppIcon       走 sys.symbol，画线条 / 填充矢量图（chevron / settings / play …）
 *   - LoaderBadge   高层语义组件，输入 LoaderKey 即可（chip / FabricApiCard 用）
 *   - VersionBlockIcon ← 本文件
 *                   按 versionId 推断类别（vanilla 草方块/铁砧/loom/...），
 *                   不需要业务方判断 loader / vanilla 子类别 —— 它内部走
 *                   LoaderCatalog.getMediaForVersion 一站式映射。
 *
 * 设计目标：
 *   - 64×64 像素艺术 PNG（3D 等距投影），关闭插值保留 pixel art 锐利感
 *   - 默认 iconSize=48，足以在版本管理 sheet 行卡片清晰展示
 *
 * 资源来源：
 *   全部 64×64 像素艺术 PNG，从 PCL2 原版仓库 [Hex-Dragon/PCL2]
 *   Plain Craft Launcher 2/Images/Blocks/ 目录获取，底层艺术源头是
 *   Mojang vanilla 贴图的 3D 等距重绘。署名与许可见 docs/CREDITS.md。
 *
 *   Grass / Command / Anvil / Gold / CobbleStone / Fabric / Quilt / NeoForge
 *   分别对应：正式版 / 快照 / Forge / 愚人节版 / 远古版 / Fabric loader /
 *           Quilt loader / NeoForge loader
 *
 * 历史改动（2026-05-23）：
 *   类别 → PNG 的 switch 从本文件抽到 LoaderCatalog.getMediaForVersion。
 *   原因：FabricApiCard / VersionManagerSheet 也需要"按 loader 拿 PNG"，
 *   旧设计把映射锁在 selectMedia 私有里没法复用。现在所有 loader 元数据
 *   都收敛到 LoaderCatalog，本组件只剩 Image 渲染壳。
 *
 * 加新版本类型：
 *   1. VersionIdUtils.classifyVersion 加新 case
 *   2. resources/base/media/ 放新 PNG
 *   3. LoaderCatalog 表（LOADER_INFO 或 VANILLA_CATEGORY_INFO）加新 entry
 *   ↑ 不再需要改本文件
 */

import { getMediaForVersion } from '../components/LoaderCatalog';
import { fileUri } from '@kit.CoreFileKit';

@Component
export struct VersionBlockIcon {
  /** MC 版本 id（"1.20.4-fabric-..." / "24w14a" / "b1.7.3" …） */
  @Prop versionId: string = '';
  /** 显式指定类别，覆盖 versionId 推断结果（用于"按 loader 强制显示"等场景） */
  @Prop category: string = '';
  /** 图标边长（vp） */
  @Prop iconSize: number = 48;
  /** 圆角半径（vp）；默认 0 = 直角，与 PCL2 视觉一致；调大可塑造卡片感 */
  @Prop cornerRadius: number = 0;
  /**
   * 覆盖图（整合包图标）的本地绝对路径。非空时渲染该图片(cover)取代方块贴图——
   * 整合包 = 一个版本，显示其项目图标更直观。空串走原方块贴图逻辑。
   */
  @Prop overrideImagePath: string = '';

  build() {
    if (this.overrideImagePath.length > 0) {
      Image(fileUri.getUriFromPath(this.overrideImagePath))
        .width(this.iconSize)
        .height(this.iconSize)
        .borderRadius(this.cornerRadius > 0 ? this.cornerRadius : 8)
        .objectFit(ImageFit.Cover)
        .syncLoad(true)
    } else {
      Image(getMediaForVersion(this.versionId, this.category))
        .width(this.iconSize)
        .height(this.iconSize)
        .borderRadius(this.cornerRadius)
        .objectFit(ImageFit.Contain)
        // pixel art：禁用插值保留方块锐利感；开 antialias 反而模糊
        .interpolation(ImageInterpolation.None)
        // 部分老设备 GDI 的 Image 对小尺寸 PNG 默认 syncLoad=false，
        // 显式打开避免 sheet 弹出瞬间空白闪一下
        .syncLoad(true)
    }
  }
}

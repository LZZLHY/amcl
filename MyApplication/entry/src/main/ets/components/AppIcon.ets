/**
 * 全应用纯图标组件，只负责目录资源、主题颜色和字重。
 * 带点击区的圆形操作统一使用AppRoundIconButton；原生标题项由
 * ImmersiveTitleScaffold消费相同图标目录，避免再维护Row按钮实现。
 * iconSize与系统CustomComponent.size名称分开，根Row满足声明式容器要求。
 */

import { AppIconName, lookupIcon, IconEntry } from 'commons'
import { inferLoaderInfo } from '../components/LoaderCatalog'

/**
 * 基础图标。**只画图标**，不带容器、不带点击。需要点击 / 容器请用
 * AppRoundIconButton。
 */
@Component
export struct AppIcon {
  /** 语义图标名，对应 IconCatalog 中的 entry */
  @Prop name: AppIconName = AppIconName.Help
  /** 字号 vp，默认 16 —— 注意不能叫 size（与 CustomComponent.size 冲突） */
  @Prop iconSize: number = 16
  /** 单色：直接传 ResourceColor */
  @Prop color: ResourceColor = '#1A1A1A'
  /** 字重 */
  @Prop weight: FontWeight = FontWeight.Medium

  build() {
    Row() {
      SymbolGlyph(lookupIcon(this.name).resource)
        .fontSize(this.iconSize)
        .fontColor([this.color])
        .fontWeight(this.weight)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}

// ============================================================================
// 便捷函数：根据 mc 版本字符串挑 loader 图标
//
// 2026-05-23 重构：原本是本文件的字符串 indexOf 实现，与 VersionManagerSheet
// 等地的 detectLoaderFromId 同义但分头维护。现在委托给 LoaderCatalog 统一推断，
// 加新 loader 只改 LoaderCatalog 一个文件（import 已上挥到文件顶部）。
// ============================================================================
export function loaderIconForVersion(mcVersion: string): AppIconName {
  return inferLoaderInfo(mcVersion).iconName
}

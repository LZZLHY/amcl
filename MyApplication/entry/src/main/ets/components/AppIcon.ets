/**
 * AppIcon.ets — AMCL 全应用图标组件
 *
 * 用法（最常见）：
 *   AppIcon({ name: AppIconName.Settings, iconSize: 18, color: theme.textSecondary })
 *
 * 用法（带圆角背景容器，常见在头部按钮）：
 *   AppIconButton({
 *     name: AppIconName.Notification,
 *     iconSize: 18,
 *     containerDiameter: 36,
 *     containerBg: theme.bgCard,
 *     containerShadowRadius: theme.cardShadowRadius,
 *     containerShadowColor: theme.cardShadowColor,
 *     onAction: () => { ... },
 *   })
 *
 * 设计目标：
 *   1. 业务侧不直接写 SymbolGlyph / 不直接写 sys.symbol 字符串
 *   2. 主题化：所有颜色由调用方传入 ResourceColor，组件不缓存自己的主题
 *   3. ArkTS 严格模式友好：@Prop 全部是 primitive / enum / ResourceColor
 *
 * ⚠️ 命名陷阱：
 *   ArkUI CustomComponent 基类已经有内置属性 `size` —— 用来同时设置 width+height
 *   （接受 SizeOptions）。所以子组件**不能重新声明** `size` 当 prop 名，会报：
 *     "Property 'size' in type 'AppIcon' is not assignable to the same property
 *      in base type 'CustomComponent'"
 *   因此本组件用 `iconSize`，AppIconButton 容器尺寸用 `containerDiameter`。
 *
 * ⚠️ Build 根节点：
 *   ArkTS 要求每个 @Component 的 build() 根节点必须是**容器组件**（Row/Column/
 *   Stack/Flex/Grid/...）。SymbolGlyph 不是容器，所以这里用 Row 包一层。
 */

import { AppIconName, lookupIcon, IconEntry } from 'commons'
import { inferLoaderInfo } from '../components/LoaderCatalog'

/**
 * 基础图标。**只画图标**，不带容器、不带点击。需要点击 / 容器请用
 * AppIconButton 或自己外层包 Row。
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
// AppIconButton —— 带圆形 / 圆角容器 + 点击区的复合按钮
// 这是 HomeTab/DownloadTab 顶部 🔔 / ⚙ / 🔍 / ⊗ 这种用法的最优解
// ============================================================================

@Component
export struct AppIconButton {
  /** 语义图标 */
  @Prop name: AppIconName = AppIconName.Help
  /** 图标本身的字号；容器尺寸由 containerDiameter 控制 */
  @Prop iconSize: number = 18
  /** 图标颜色 */
  @Prop color: ResourceColor = '#1A1A1A'

  /** 容器宽高（vp），同时控制点击热区 */
  @Prop containerDiameter: number = 36
  /** 容器背景色 */
  @Prop containerBg: ResourceColor = '#FFFFFF'
  /** 容器圆角半径（vp）；< 0 表示自动取 diameter/2（圆形） */
  @Prop containerRadius: number = -1
  /** 阴影半径（0 = 无阴影） */
  @Prop containerShadowRadius: number = 0
  /** 阴影颜色（仅当 containerShadowRadius > 0 时生效） */
  @Prop containerShadowColor: ResourceColor = '#00000000'

  /** 是否禁用点击（视觉不变，仅吃掉点击） */
  @Prop disabled: boolean = false
  /** 点击回调 */
  onAction: () => void = () => {}

  build() {
    Row() {
      AppIcon({
        name: this.name,
        iconSize: this.iconSize,
        color: this.color,
      })
    }
    .width(this.containerDiameter)
    .height(this.containerDiameter)
    .borderRadius(this.containerRadius >= 0 ? this.containerRadius : this.containerDiameter / 2)
    .backgroundColor(this.containerBg)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.containerShadowRadius, color: this.containerShadowColor })
    .onClick(() => {
      if (!this.disabled) this.onAction()
    })
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

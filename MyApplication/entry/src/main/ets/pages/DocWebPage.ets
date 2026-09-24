/**
 * DocWebPage.ets — 通用文档内嵌页（内嵌 AMCL-web /docs 的某篇文档）
 *
 * 用通用 WebHostView 内嵌文档页（?embed=1 隐藏站点导航/页脚，只显示正文）。
 * 与 FeedbackPage 同套 chrome，只是地址/标题由 router 参数传入，可复用于任意文档。
 *
 * 入口（router.pushUrl('pages/DocWebPage', { src, title, fallback })）：
 *   - 设置 → 常见问题 → 怎么安装 / JIT 解决办法
 *   - 启动前检查 JIT 失败 → 如何解决
 *   - Forge 安装前 JIT 弹窗 → 如何解决
 *
 * 创建日期：2026-07-04
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { DOCS_NO_JIT_URL, DOCS_NO_JIT_FALLBACK_URL } from 'commons';
import { PreferenceManager } from 'feature_system';
import { WebHostView } from '../components/WebHostView';

interface DocWebParams {
  src?: string;
  title?: string;
  fallback?: string;
}

@Entry
@Component
struct DocWebPage {
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0

  // 路由参数（缺省兜底到「无 JIT」文档，避免空白）
  @State private src: string = DOCS_NO_JIT_URL
  @State private title: string = '帮助文档'
  @State private fallback: string = DOCS_NO_JIT_FALLBACK_URL

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    let p = this.getUIContext().getRouter().getParams() as DocWebParams
    if (p !== undefined && p !== null) {
      if (p.src !== undefined && p.src.length > 0) this.src = p.src
      if (p.title !== undefined && p.title.length > 0) this.title = p.title
      if (p.fallback !== undefined && p.fallback.length > 0) this.fallback = p.fallback
    }
    this.applyTheme_()
  }

  private applyTheme_() {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange() {
    this.applyTheme_()
  }

  build() {
    Column() {
      WebHostView({
        theme: this.theme,
        topSafeHeight: this.topSafeHeight,
        src: this.src,
        title: this.title,
        fallbackBrowserUrl: this.fallback,
        onBack: () => { this.getUIContext().getRouter().back() },
      })
    }
    .width('100%').height('100%')
  }
}

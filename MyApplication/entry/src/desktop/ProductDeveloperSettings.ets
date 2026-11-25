import { ThemeColors } from 'commons'

/** 独立电脑产品只装配电脑的诊断页面；是否显示设置入口仍由运行时准入决定。 */
export function developerToolRoute(tool: string): string {
  return tool === 'desktop' ? 'pages/DesktopDeveloperToolsPage' : '';
}

@Component
export struct ProductDeveloperSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  build() {
    Row() {
      Text('开发者工具 · 电脑').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
      Text('OpenGL 验证 ›').fontSize(14).fontColor(this.theme.textHint)
    }.width('100%').height(56)
      .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: developerToolRoute('desktop') }) })
  }
}

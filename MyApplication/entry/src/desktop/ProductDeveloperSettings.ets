import { ThemeColors } from 'commons'

@Component
export struct ProductDeveloperSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  build() {
    Row() {
      Text('开发者工具 · 电脑').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
      Text('OpenGL 验证 ›').fontSize(14).fontColor(this.theme.textHint)
    }.width('100%').height(56)
      .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/DesktopDeveloperToolsPage' }) })
  }
}

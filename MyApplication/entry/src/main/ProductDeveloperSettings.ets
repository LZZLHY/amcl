import { ThemeColors, DiagnosticPolicy, AppLogger } from 'commons'

@Component
export struct ProductDeveloperSettings {
  @Prop theme: ThemeColors = {} as ThemeColors

  build() {
    Column() {
      if (DiagnosticPolicy.hasTestHooks()) {
        Row() {
          Text('开发者工具').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
          Text('›').fontSize(22).fontColor(this.theme.textSecondary)
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/DevToolsPage' }).catch((e: Error) => {
            AppLogger.error('DeveloperSettings', '打开开发者工具失败', e)
          })
        })
      }
    }.width('100%')
  }
}

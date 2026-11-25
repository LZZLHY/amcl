import { ThemeColors, DiagnosticPolicy, AppLogger } from 'commons'

/** 开发产品的具名探针入口随本产品编译；设置页与系统 Skill 共用同一组目的页。 */
export function developerToolRoute(tool: string): string {
  switch (tool) {
    case 'tools': return 'pages/DevToolsPage';
    case 'gles': return 'pages/RenderPage';
    case 'vulkan': return 'pages/VulkanPage';
    case 'input': return 'pages/InputProbePage';
    default: return '';
  }
}

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
          this.getUIContext().getRouter().pushUrl({ url: developerToolRoute('tools') }).catch((e: Error) => {
            AppLogger.error('DeveloperSettings', '打开开发者工具失败', e)
          })
        })
      }
    }.width('100%')
  }
}

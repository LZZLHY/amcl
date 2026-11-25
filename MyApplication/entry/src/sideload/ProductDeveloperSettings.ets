import { ThemeColors } from 'commons'

/** 发行产品没有开发工具路由。 */
export function developerToolRoute(_tool: string): string { return ''; }

@Component
export struct ProductDeveloperSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  build() { Row().height(0).width(0) }
}

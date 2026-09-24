import { ThemeColors } from 'commons'

@Component
export struct ProductDeveloperSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  build() { Row().height(0).width(0) }
}

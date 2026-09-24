import { ThemeColors } from 'commons'

/** Desktop-only does not link touch settings or layout routes. */
@Component
export struct ProductTouchSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  build() {
    Column() {}.height(0)
  }
}

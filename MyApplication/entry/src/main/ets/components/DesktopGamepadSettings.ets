import { common } from '@kit.AbilityKit'
import { DeviceProfile, ThemeColors } from 'commons'
import { PreferenceManager } from 'feature_system'

@Component
export struct DesktopGamepadSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  @State nativeMode: boolean = false

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.nativeMode = new PreferenceManager(context).desktopNativeGamepad
  }

  build() {
    Column() {
      if (DeviceProfile.isPC()) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('由游戏处理手柄').fontSize(16).fontColor(this.theme.textPrimary)
            Text('适合控制器模组。关闭时使用启动器按键映射；下次启动游戏生效。')
              .fontSize(12).fontColor(this.theme.textHint)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.nativeMode })
            .accessibilityText('由游戏处理手柄')
            .onChange((enabled: boolean) => {
              const context = this.getUIContext().getHostContext() as common.UIAbilityContext
              new PreferenceManager(context).desktopNativeGamepad = enabled
              this.nativeMode = enabled
            })
        }.width('100%').padding({ top: 12, bottom: 12 })
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
    }.width('100%')
  }
}

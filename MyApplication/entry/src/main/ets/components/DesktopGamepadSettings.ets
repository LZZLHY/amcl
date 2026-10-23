import { common } from '@kit.AbilityKit'
import { DeviceProfile, ThemeColors } from 'commons'
import { PreferenceManager } from 'feature_system'

@Component
export struct DesktopGamepadSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  @State nativeMode: boolean = false
  @State private saving: boolean = false
  @State private saveMessage: string = ''
  private mounted: boolean = false
  private appearance: number = 0

  /** 每轮前端只读同owner确认值；旧保存可以继续，但不得向新appearance写回显示。 */
  aboutToAppear(): void {
    this.mounted = true
    this.appearance++
    this.saving = false
    this.saveMessage = ''
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.nativeMode = new PreferenceManager(context).desktopNativeGamepad
  }

  /** 只撤本页面显示资格，不能取消已经请求的持久事务或清除原owner的未知回滚状态。 */
  aboutToDisappear(): void { this.mounted = false; this.appearance++ }

  /** 同appearance仅一个保存；flush成功才改确认开关，失败保旧值并显示真实失败。 */
  private async changeNativeMode_(enabled: boolean): Promise<void> {
    if (!this.mounted || this.saving || enabled === this.nativeMode) return
    const appearance: number = this.appearance
    this.saving = true
    this.saveMessage = '正在保存…'
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      await new PreferenceManager(context).saveDesktopNativeGamepad(enabled)
      if (!this.mounted || this.appearance !== appearance) return
      this.nativeMode = enabled
      this.saveMessage = '已保存，下次启动游戏生效。'
    } catch (error) {
      if (!this.mounted || this.appearance !== appearance) return
      this.saveMessage = '保存失败：' + (error as Error).message
    } finally {
      if (this.mounted && this.appearance === appearance) this.saving = false
    }
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
            .enabled(!this.saving)
            .onChange((enabled: boolean) => {
              this.changeNativeMode_(enabled)
            })
        }.width('100%').padding({ top: 12, bottom: 12 })
        if (this.saveMessage.length > 0) {
          Text(this.saveMessage).fontSize(12).fontColor(this.theme.textHint).width('100%')
        }
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
    }.width('100%')
  }
}

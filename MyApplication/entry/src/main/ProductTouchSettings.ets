import { common } from '@kit.AbilityKit'
import { ThemeColors, AppIconName } from 'commons'
import { AppIcon } from './ets/components/AppIcon'
import { ProductInputProfile } from 'entry/ProductInputProfile'

@Component
export struct ProductTouchSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  @State interaction: string = ProductInputProfile.interaction()
  @State deferred: boolean = ProductInputProfile.interactionPending()

  @Builder
  Choice(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.interaction === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.interaction === value ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .height(44)
      .padding({ left: 16, right: 16 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext
        this.deferred = !ProductInputProfile.setInteraction(value, context)
        this.interaction = value
      })
  }

  build() {
    Column() {
      if (ProductInputProfile.canChooseInteraction()) {
        Column() {
          Text('电脑游戏交互').fontSize(16).fontColor(this.theme.textPrimary)
          Text(this.deferred ? '已保存，重启启动器后生效' :
            '自动使用桌面交互，旧系统回退触控；触屏模式提供虚拟按键，也支持键鼠。')
            .fontSize(12).fontColor(this.theme.textHint).margin({ top: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.Choice('auto', '自动')
            this.Choice('touch', '触屏')
            this.Choice('desktop', '键鼠')
          }.margin({ top: 12 })
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 12, bottom: 4 })
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
      Row() {
        Text('自定义按键布局').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
      }.width('100%').height(56)
      .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/LayoutListPage' }) })
      Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
    }.width('100%')
  }
}

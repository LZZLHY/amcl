import { common } from '@kit.AbilityKit'
import { ThemeColors, AppIconName } from 'commons'
import { AppIcon } from './ets/components/AppIcon'
import { ProductInputProfile } from 'entry/ProductInputProfile'

@Component
export struct ProductTouchSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  @State interaction: string = ProductInputProfile.interaction()
  @State deferred: boolean = ProductInputProfile.interactionPending()
  @State private saving: boolean = false
  @State private saveMessage: string = ''
  private mounted: boolean = false
  private appearance: number = 0

  /** 每次挂接读本进程确认的desired与冻结状态，不从旧保存的临时显示借值。 */
  aboutToAppear(): void {
    this.mounted = true
    this.appearance++
    this.saving = false
    this.saveMessage = ''
    this.interaction = ProductInputProfile.interaction()
    this.deferred = ProductInputProfile.interactionPending()
  }

  /** 持久请求独立完成；旧await只能失去显示权，不能写新页面或切本局route。 */
  aboutToDisappear(): void { this.mounted = false; this.appearance++ }

  /** 保存等待期间保持原选项；重复点击拒绝，失败可见且保留旧UI，成功才展示待重启事实。 */
  private async changeInteraction_(value: string): Promise<void> {
    if (!this.mounted || this.saving || value === this.interaction) return
    const appearance: number = this.appearance
    this.saving = true
    this.saveMessage = '正在保存…'
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      const applied: boolean = await ProductInputProfile.setInteraction(value, context)
      if (!this.mounted || this.appearance !== appearance) return
      this.interaction = ProductInputProfile.interaction()
      this.deferred = !applied && ProductInputProfile.interactionPending()
      this.saveMessage = this.deferred ? '已保存，重启启动器后生效。' : '已保存。'
    } catch (error) {
      if (!this.mounted || this.appearance !== appearance) return
      this.saveMessage = '保存失败：' + (error as Error).message
    } finally {
      if (this.mounted && this.appearance === appearance) this.saving = false
    }
  }

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
      .enabled(!this.saving)
      .onClick(() => {
        this.changeInteraction_(value)
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
          if (this.saveMessage.length > 0) {
            Text(this.saveMessage).fontSize(12).fontColor(this.theme.textHint).width('100%')
          }
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

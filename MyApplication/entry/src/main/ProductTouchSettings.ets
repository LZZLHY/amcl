/**
 * 产品触控设置的确认态宿主。交互模式仍由 RuntimeProductProfile 串行保存并判定是否冻结；
 * 本轮只统一组内排版与搜索锚点，不改变保存成功、失败或待重启的生命周期围栏。
 */
import { common } from '@kit.AbilityKit'
import { LauncherSkillBus } from './ets/launcherskill/LauncherSkillBus'
import { SettingsSkillData, settingKeys, settingText, settingFailure } from './ets/launcherskill/SettingsSkillValues'
import { ThemeColors, AppIconName } from 'commons'
import { SettingsValueRow } from './ets/components/SettingsPrimitives'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { PreferenceManager } from 'feature_system'

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
    LauncherSkillBus.bind('settingsInteraction',this,(method: string,args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.skillInteraction_(method,args), (): boolean => this.mounted && ProductInputProfile.canChooseInteraction() &&
        AppStorage.get<boolean>('amclSettingsTabVisible') === true && AppStorage.get<boolean>('appInForeground') === true)
    this.mounted = true
    this.appearance++
    this.saving = false
    this.saveMessage = ''
    this.interaction = ProductInputProfile.interaction()
    this.deferred = ProductInputProfile.interactionPending()
  }

  /** 持久请求独立完成；旧await只能失去显示权，不能写新页面或切本局route。 */
  aboutToDisappear(): void { LauncherSkillBus.unbind('settingsInteraction',this); this.mounted = false; this.appearance++ }

  /** 保存、冻结和回读与电脑交互选择行使用同一所有者。 */
  private async skillInteraction_(method: string,args: SettingsSkillData): Promise<SettingsSkillData> {
    if (this.saving) return settingFailure('busy')
    if (method === 'setDesktopInteraction' && settingKeys(args,['mode'])) {
      const mode = settingText(args,'mode')
      if (!['auto','touch','desktop'].includes(mode)) return settingFailure('invalidMode')
      await this.changeInteraction_(mode)
      if (!this.mounted || ProductInputProfile.interaction() !== mode) return settingFailure('notSaved')
    } else if (method !== 'getDesktopInteraction' || !settingKeys(args,[])) return settingFailure('invalidArguments')
    try {
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mode=new PreferenceManager(context).strictLauncherField('desktopInteraction');
      return mode === ProductInputProfile.interaction() ? {'state':'ready','mode':mode,'restartRequired':ProductInputProfile.interactionPending()} :
        {'state':'unknown','reason':'selectionChanged'};
    } catch (_) { return {'state':'unknown','reason':'settingUnreadable'}; }
  }

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
      .fontSize(14)
      .fontColor(this.interaction === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.interaction === value ? this.theme.actionPrimary : this.theme.bgInput)
      .borderRadius(16)
      .height(48)
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
          Text('设备交互方式').fontSize(16).fontColor(this.theme.textPrimary)
          Text(this.deferred ? '已保存，重启启动器后生效' :
            '自动使用桌面交互，旧系统回退触控；触屏模式提供虚拟按键，也支持键鼠。')
            .fontSize(14).fontColor(this.theme.textSecondary).margin({ top: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.Choice('auto', '自动')
            this.Choice('touch', '触屏')
            this.Choice('desktop', '键鼠')
          }.margin({ top: 12 })
          if (this.saveMessage.length > 0) {
            Text(this.saveMessage).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
          }
        }.alignItems(HorizontalAlign.Start).width('100%').padding(16).id('settings-item-interaction')
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
      SettingsValueRow({ title: '操控方案', description: '管理布局、触控、视角与手柄设置', showIcon: true,
        icon: AppIconName.LayoutList, theme: this.theme, controlId: 'settings-item-layouts', onAction: (): void => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/LayoutListPage' }).catch((): void => {
            if (this.mounted) this.getUIContext().getPromptAction().showToast({ message: '无法打开按键布局，请重试' });
          });
        } })
      SettingsValueRow({title:'编辑当前布局',description:'调整控件、位置、外观和显示',showIcon:true,
        icon:AppIconName.LayoutList,theme:this.theme,controlId:'settings-item-edit-layout',onAction:(): void=>{
          this.getUIContext().getRouter().pushUrl({url:'pages/LayoutEditorPage',params:{settingsOnly:false}})
        }})
    }.width('100%')
  }
}

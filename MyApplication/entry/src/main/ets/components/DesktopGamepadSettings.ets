import { common } from '@kit.AbilityKit'
import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus'
import { SettingsSkillData, settingKeys, settingFailure } from '../launcherskill/SettingsSkillValues'
import { ThemeColors } from 'commons'
import { ProductInputProfile } from 'entry/ProductInputProfile'
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
    LauncherSkillBus.bind('settingsGamepad',this,(method: string,args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.skillGamepad_(method,args), (): boolean => this.mounted && ProductInputProfile.canChooseNativeGamepad() &&
        AppStorage.get<boolean>('amclSettingsTabVisible') === true && AppStorage.get<boolean>('appInForeground') === true)
    this.mounted = true
    this.appearance++
    this.saving = false
    this.saveMessage = ''
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.nativeMode = new PreferenceManager(context).desktopNativeGamepad
  }

  /** 只撤本页面显示资格，不能取消已经请求的持久事务或清除原owner的未知回滚状态。 */
  aboutToDisappear(): void { LauncherSkillBus.unbind('settingsGamepad',this); this.mounted = false; this.appearance++ }

  /** 暴露给启动器 Skill 的是下次启动时的输入处理策略。 */
  private async skillGamepad_(method: string,args: SettingsSkillData): Promise<SettingsSkillData> {
    if (this.saving) return settingFailure('busy')
    if (method === 'setGamepadMode' && settingKeys(args,['native']) && typeof args['native'] === 'boolean') {
      const want = args['native'] as boolean
      await this.changeNativeMode_(want)
      if (!this.mounted || this.nativeMode !== want) return settingFailure('notSaved')
    } else if (method !== 'getGamepadMode' || !settingKeys(args,[])) return settingFailure('invalidArguments')
    try {
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const native=new PreferenceManager(context).strictLauncherField('desktopNativeGamepad');
      return native === this.nativeMode ? {'state':'ready','native':native,'effectiveAt':'nextLaunch'} :
        {'state':'unknown','reason':'selectionChanged'};
    } catch (_) { return {'state':'unknown','reason':'settingUnreadable'}; }
  }

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
      this.saveMessage = ''
      // 这里确认下局偏好已保存；本局实际路线由游戏页报告。通知失败不改写持久结果。
      if (AppStorage.get<boolean>('amclSettingsTabVisible') === true && AppStorage.get<boolean>('appInForeground') === true) {
        const message = enabled ? '已保存，下次启动时由游戏处理手柄。' : '已保存，下次启动时使用启动器手柄映射。'
        try { this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 }) }
        catch (_) { /* 开关已显示确认值，关闭中的通知窗口不影响保存。 */ }
      }
    } catch (error) {
      if (!this.mounted || this.appearance !== appearance) return
      this.saveMessage = '保存失败：' + (error as Error).message
    } finally {
      if (this.mounted && this.appearance === appearance) this.saving = false
    }
  }

  build() {
    Column() {
      if (ProductInputProfile.canChooseNativeGamepad()) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('由游戏处理手柄').fontSize(16).fontColor(this.theme.textPrimary)
            Text('启用后，支持的游戏或手柄模组可读取手柄。关闭时使用启动器键鼠映射。下次启动游戏生效。')
              .fontSize(14).fontColor(this.theme.textSecondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.nativeMode })
            .width(48).height(32).responseRegion({ x: 0, y: -8, width: 48, height: 48 })
            .accessibilityText('由游戏处理手柄')
            .enabled(!this.saving)
            .onChange((enabled: boolean) => {
              this.changeNativeMode_(enabled)
            })
        }.width('100%').padding(16)
        if (this.saveMessage.length > 0) {
          Text(this.saveMessage).fontSize(14).fontColor(this.theme.textSecondary).width('100%').padding({ left: 16, right: 16, bottom: 16 })
        }
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
    }.width('100%')
  }
}

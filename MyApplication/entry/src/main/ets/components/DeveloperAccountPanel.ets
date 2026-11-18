/** 软件更新设置里的常驻账号入口；仅负责展示和Sheet生命周期，授权仍由现有AuthSession执行。 */
import { common } from '@kit.AbilityKit';
import { ThemeColors, AppIconName } from 'commons';
import { DeveloperAccountViewModel } from '../sideload/DeveloperAccountViewModel';
import { DeveloperAuthState } from '../sideload/DeveloperAuthSession';
import { SettingsGroup, SettingsValueRow } from './SettingsPrimitives';
import { DeveloperLoginContent, developerLoginSheetOptions } from './DeveloperLoginContent';

@Component
export struct DeveloperAccountPanel {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop @Watch('syncActive_') active: boolean = true;
  @State private model: DeveloperAccountViewModel = new DeveloperAccountViewModel();
  @StorageProp('screenWidthVp') private screenWidth: number = 360;
  @StorageProp('screenHeightVp') private screenHeight: number = 800;
  @StorageProp('topRectHeight') private topSafe: number = 0;
  @StorageProp('bottomRectHeight') private bottomSafe: number = 0;
  @StorageProp('phoneSheetHeightPercent') private phoneHeight: number = 80;
  private initialized: boolean = false;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // 预览或宿主已退出时无法访问应用私有目录，等下一次出现再绑定授权服务。
    if (!context) return;
    this.model.initialize(context); this.initialized = true; this.syncActive_();
  }
  aboutToDisappear(): void { this.initialized = false; this.model.deactivate(); }
  /** Router隐藏未必卸载组件，因此额外消费页面可见性；离开页面不会留下授权监听器。 */
  private syncActive_(): void {
    if (!this.initialized) return;
    if (this.active) this.model.activate(); else this.model.deactivate();
  }
  private options_(): SheetOptions {
    // 设置行位于页面主内容中，当前组件的 UIContext 就是登录面板所属的窗口。
    return developerLoginSheetOptions({ theme: this.theme, uiContext: this.getUIContext(),
      width: this.screenWidth, height: this.screenHeight, topSafe: this.topSafe, bottomSafe: this.bottomSafe,
      phoneHeightPercent: this.phoneHeight, onClose: (): void => { this.model.closeLogin(); }, onDisappear: (): void => {} });
  }
  build() {
    SettingsGroup({ title: '更新账号', theme: this.theme, content: (): void => { this.accountRow_(); } })
      .bindSheet(this.model.loginVisible, this.login_(), this.options_())
  }
  @Builder
  private accountRow_() {
    SettingsValueRow({ title: '华为开发者账号', description: this.model.description(), value: this.model.statusText(),
      theme: this.theme, actionValue: this.model.needsLogin(), positiveValue: this.model.state === DeveloperAuthState.Valid && !this.model.checking,
      actionEnabled: this.initialized && !this.model.checking, trailingIcon: this.model.checking ? AppIconName.Refresh : this.model.state === DeveloperAuthState.Valid ? AppIconName.CheckCircle :
        this.model.needsLogin() ? AppIconName.ChevronRight : AppIconName.Refresh,
      controlId: 'developer-account-status', onAction: (): void => { this.model.act(); } })
  }
  @Builder
  private login_() {
    DeveloperLoginContent({ theme: this.theme, url: this.model.loginUrl, message: this.model.loginMessage,
      busy: this.model.loginBusy, bottomSafe: this.bottomSafe, onClose: (): void => { this.model.closeLogin(); },
      onRetry: (): void => { this.model.login(); }, onFailure: (message: string): void => { this.model.loginFailed(message); } })
  }
}

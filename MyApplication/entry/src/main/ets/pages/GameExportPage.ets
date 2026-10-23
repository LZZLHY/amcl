/**
 * 游戏包导出的兼容路由宿主。
 *
 * 版本管理直接嵌入 GameExportSheet；活动记录仍可通过本路由按 taskId 重入。
 * 这里仅固定 Router 参数与全局主题，不再复制导出业务状态。系统 Back 必须转交
 * Sheet 注册的关闭保护，普通子组件 onBackPress 不会自动接管页面级返回。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { GameExportSheet } from '../components/GameExportSheet';

@Entry
@Component
struct GameExportPage {
  @StorageProp('topRectHeight') private topSafe_: number = 0;
  @StorageProp('currentColorMode') @Watch('applyTheme_') private colorMode_: number = 0;
  @State private theme_: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State private mcRoot_: string = '';
  @State private versionId_: string = '';
  @State private isolation_: boolean = true;
  @State private taskId_: string = '';
  @State private ready_: boolean = false;
  /** 仅保存已挂载子组件的关闭处理权；子组件销毁时必须回传 undefined。 */
  private dismiss_: ((back?: boolean) => void) | undefined = undefined;

  /** 参数只读取一次，避免异步草稿或任务投影反向改写 Router 中的源身份。 */
  aboutToAppear(): void {
    const params: Record<string, Object> = (this.getUIContext().getRouter().getParams() as Record<string, Object>) ?? {};
    const root: Object = params['mcRoot'];
    const version: Object = params['versionId'];
    const task: Object = params['taskId'];
    this.mcRoot_ = typeof root === 'string' ? root : '';
    this.versionId_ = typeof version === 'string' ? version : '';
    this.taskId_ = typeof task === 'string' ? task : '';
    this.isolation_ = params['versionIsolation'] !== false;
    this.applyTheme_();
    this.ready_ = true;
  }

  /** 跟随工程现有主题偏好，Sheet 的 theme Prop 持续接收更新。 */
  private applyTheme_(): void {
    const context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (context === undefined) return;
    const pref: PreferenceManager = new PreferenceManager(context);
    const dark: boolean = this.colorMode_ === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.theme_ = resolveTheme(pref.themeMode, resolveIsDark(pref.themeMode, dark));
  }

  /** 异步检查与草稿确认期间始终消费原 Back，由 Sheet 决定何时调用宿主离开。 */
  onBackPress(): boolean {
    if (this.dismiss_ !== undefined) this.dismiss_(true);
    else this.getUIContext().getRouter().back();
    return true;
  }

  build() {
    Column() {
      if (this.ready_) {
        GameExportSheet({
          mcRoot: this.mcRoot_, versionId: this.versionId_, versionIsolation: this.isolation_,
          initialTaskId: this.taskId_, theme: this.theme_, backLabel: '返回上一页',
          onBack: (): void => { this.getUIContext().getRouter().back(); },
          onClose: (): void => { this.getUIContext().getRouter().back(); },
          onRegisterDismiss: (handler: ((back?: boolean) => void) | undefined): void => { this.dismiss_ = handler; },
        })
      }
    }.width('100%').height('100%').padding({ top: this.topSafe_ }).backgroundColor(this.theme_.bgPrimary)
  }
}

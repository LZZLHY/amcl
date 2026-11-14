/** 旧路由的兼容容器；正常立即更新在原弹窗内完成，此处复用相同内容与业务。 */
import { SideloadUpdateContent } from '../components/SideloadUpdateContent';
import { SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';
import { resolveUpdateDialogLayout, UpdateDialogLayout } from '../components/UpdateDialogLayout';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeColors, ThemeMode, resolveTheme } from 'commons';
import { PreferenceManager } from 'feature_system';
import { applyNativeTheme } from '../components/AppTheme';

@Entry
@Component
struct SideloadUpdatePage {
  /** 兼容路由的外围背景与卡片使用同一应用主题，不改变更新尝试/关闭保护或固定几何。 */
  @State private theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @StorageProp('currentColorMode') @Watch('applyTheme_') private colorMode_: number = 0;
  @StorageProp('appThemeRevision') @Watch('applyTheme_') private appThemeRevision_: number = 0;
  @State params: SideloadUpdatePageParams = {};
  /** 与正常弹窗共用窗口事实和几何，旧链接进入时也不能退回随内容伸缩的容器。 */
  @StorageProp('screenWidthVp') private windowWidth: number = 360;
  @StorageProp('screenHeightVp') private windowHeight: number = 780;
  @StorageProp('topRectHeight') private topSafe: number = 0;
  @StorageProp('bottomRectHeight') private bottomSafe: number = 0;
  private exitUpdate: () => boolean = (): boolean => true;
  /** 普通方法随视口/避让区重算；避免SDK丢弃struct getter，授权和进度仍不改变外框。 */
  private frame(): UpdateDialogLayout {
    return resolveUpdateDialogLayout(this.windowWidth, this.windowHeight, this.topSafe, this.bottomSafe);
  }
  /** 系统Back是明确退出，先撤销当前Attempt；已派发阶段由内容层拦截。 */
  onBackPress(): boolean { return !this.exitUpdate(); }
  aboutToAppear(): void {
    this.applyTheme_();
    this.params = (this.getUIContext().getRouter().getParams() as SideloadUpdatePageParams) ?? {};
  }
  /** 颜色通知只重建快照，既不initialize ViewModel，也不恢复或取消原更新任务。 */
  private applyTheme_(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return;
    const preferences: PreferenceManager = new PreferenceManager(context);
    this.theme = resolveTheme(preferences.themeMode,
      this.colorMode_ === ConfigurationConstant.ColorMode.COLOR_MODE_DARK, preferences.themeAccent);
    applyNativeTheme(this.theme);
  }
  onPageShow(): void { this.applyTheme_(); }
  build() {
    Column() {
      SideloadUpdateContent({ params: this.params, compact: this.frame().compact,
        onDismiss: (): void => { this.getUIContext().getRouter().back(); },
        onExitGuardReady: (exit: () => boolean): void => { this.exitUpdate = exit; } })
        .width(this.frame().width).height(this.frame().height).borderRadius(20).clip(true)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.theme.bgPrimary)
  }
}

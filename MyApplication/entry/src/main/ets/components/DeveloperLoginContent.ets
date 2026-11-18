/** 设置与自更新共用的官方登录Sheet内容和尺寸；只渲染官方页面，不读取或持久化用户输入。 */
import { UIContext } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { ThemeColors, DeviceProfile, centerSheetForLayout, sheetWidthForLayout, largeSheetHeightForLayout } from 'commons';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';

export interface DeveloperLoginSheetInput {
  theme: ThemeColors; uiContext: UIContext;
  width: number; height: number; topSafe: number; bottomSafe: number; phoneHeightPercent: number;
  onClose: () => void; onDisappear: () => void;
}

/** 始终用主窗口尺寸；手机沿用户设置比例，平板沿统一居中限宽，调用者只提供生命周期回调。 */
export function developerLoginSheetOptions(input: DeveloperLoginSheetInput): SheetOptions {
  const form = DeviceProfile.form(), bp = DeviceProfile.breakpointOf(input.width);
  return {
    height: Math.min(largeSheetHeightForLayout(form, bp, input.bottomSafe, input.topSafe, input.phoneHeightPercent),
      Math.max(1, input.height - input.topSafe - input.bottomSafe)),
    width: sheetWidthForLayout(form, bp), preferType: centerSheetForLayout(form, bp) ? SheetType.CENTER : SheetType.BOTTOM,
    dragBar: !centerSheetForLayout(form, bp), showClose: false, blurStyle: BlurStyle.NONE,
    backgroundColor: input.theme.bgCard, enableOutsideInteractive: false, uiContext: input.uiContext,
    onDisappear: input.onDisappear,
    onWillDismiss: (action: DismissSheetAction): void => { input.onClose(); action.dismiss(); }
  };
}

@Component
export struct DeveloperLoginContent {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop url: string = '';
  @Prop message: string = '';
  @Prop busy: boolean = false;
  @Prop footer: string = '登录凭据加密保存在本机，更新时自动使用';
  @Prop bottomSafe: number = 0;
  closeId: string = 'developer-login-close';
  onClose: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onFailure: (message: string) => void = (_message: string): void => {};
  private webController: webview.WebviewController = new webview.WebviewController();

  build() {
    Column() {
      ImmersiveTitleScaffold({ title: '登录华为账号', theme: this.theme, modal: true,
        surfaceColor: this.theme.bgCard, closeLabel: '关闭授权', closeId: this.closeId, onClose: this.onClose,
        content: (): void => { this.body_(); } }).width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor(this.theme.bgCard)
  }

  /** 状态经Prop更新；重试、取消和页面错误都交还原授权所有者，Web不注入脚本或代理。 */
  @Builder
  private body_() {
    Column({ space: 12 }) {
      if (this.url.length > 0) {
        Web({ src: this.url, controller: this.webController, incognitoMode: true })
          .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).width('100%').layoutWeight(1)
          .onErrorReceive((event): void => {
            if (event.request.isMainFrame()) this.onFailure('登录页面加载失败，请检查网络后重试');
          })
      } else {
        Column({ space: 16 }) {
          if (this.busy) { LoadingProgress().width(40).height(40).color(this.theme.actionText) }
          Text(this.message).fontSize(16).lineHeight(24).fontColor(this.theme.textPrimary)
          if (!this.busy) {
            Button('重新登录').height(48).width('100%').backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
              .onClick((): void => { this.onRetry(); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
      Text(this.footer).fontSize(12).lineHeight(19).fontColor(this.theme.textSecondary).width('100%').flexShrink(0)
    }.width('100%').height('100%').padding({ left: 16, right: 16, bottom: Math.max(16, this.bottomSafe) })
  }
}

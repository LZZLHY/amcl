/**
 * 游戏结果弹窗只承载本次结果与诊断入口。活动详情负责分析会话证据、阅读日志与分享。
 */
import { ThemeColors } from 'commons';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';

@Component
export struct McErrorSheet {
  /** 当前游戏活动的持久化主键。 */
  @Prop sessionKey: number = 0;
  @Prop fault: boolean = false;
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  @State private openingLogs: boolean = false;
  onClose: () => void = () => {};

  /** 以当前会话打开本地故障线索，路由成功后才收起，跳转失败时可重试。 */
  private async openAnalysis_(): Promise<void> {
    if (this.openingLogs || this.sessionKey <= 0) return;
    this.openingLogs = true;
    const uiContext = this.getUIContext();
    try {
      await uiContext.getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: {
        'activityId': this.sessionKey, 'view': 'overview',
      } });
      this.onClose();
    } catch (_) {
      uiContext.getPromptAction().showToast({ message: '无法打开活动详情，请重试', duration: 2000 });
    } finally {
      this.openingLogs = false;
    }
  }

  @Builder
  private analysisAction_() {
    Column() {
      Button('分析日志').id('mc-error-analyze-logs')
        .width('100%').height(48).borderRadius(24).fontSize(15).fontWeight(600)
        .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
        .enabled(!this.openingLogs && this.sessionKey > 0)
        .onClick((): void => { this.openAnalysis_(); })
    }
    .width('100%').padding({ left: 20, right: 20, top: 16, bottom: Math.max(16, this.bottomSafeHeight) })
  }

  build() {
    ImmersiveTitleScaffold({ title: this.fault ? '游戏异常退出' : '游戏已结束', theme: this.theme,
      modal: true, surfaceColor: this.theme.bgPrimary, closeLabel: '关闭游戏结果', closeId: 'mc-error-close',
      closeEnabled: !this.openingLogs, onClose: (): void => { this.onClose(); },
      content: (): void => { this.analysisAction_(); },
    })
  }
}

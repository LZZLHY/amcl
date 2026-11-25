/** 游戏结果直接展示该次会话的诊断；完整日志与提交开发者的确认仍由活动详情管理。 */
import { AppIconName, DistributionPolicy, ThemeColors } from 'commons';
import { classifyMcError, McDiagnosis, McSuggestion } from 'launch';
import { AppIcon } from './AppIcon';
import { AppRoundIconButton } from './AppRoundIconButton';
import { McErrorMark } from './McErrorMark';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';

@Component
export struct McErrorSheet {
  /** 诊断、版本和日志尾部均来自父页面打开的同一份会话快照。 */
  @Prop sessionKey: number = 0;
  @Prop version: string = '';
  @Prop diagnosis: McDiagnosis = classifyMcError('', '', '');
  @Prop logTail: string = '';
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  @State private openingLogs: boolean = false;
  @State private logExpanded: boolean = false;
  /** 只用日志入口这一行的实际宽度控制装饰箭头，使两栏在窄窗仍能显示说明。 */
  @State private roomForArrows_: boolean = false;
  onClose: () => void = () => {};
  onAction: (key: string) => boolean = (): boolean => false;

  /** 分析只看本机。上传先打开本次活动的作者端预览，用户确认后才会发出。 */
  private async openAnalysis_(author: boolean = false): Promise<void> {
    if (this.openingLogs || this.sessionKey <= 0 || (author && !DistributionPolicy.allowPublisherServices())) return;
    this.openingLogs = true;
    const uiContext = this.getUIContext();
    try {
      const params: Record<string, Object> = { 'activityId': this.sessionKey, 'view': 'overview' };
      if (author) {
        params['showShare'] = true;
        params['destination'] = 'author';
      }
      await uiContext.getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params });
      this.onClose();
    } catch (_) {
      uiContext.getPromptAction().showToast({ message: '无法打开活动详情，请重试', duration: 2000 });
    } finally {
      this.openingLogs = false;
    }
  }

  /** 旧分类中的 copy_log 已由独立上传入口承接；其他处理只打开相应管理界面。 */
  private hasRepair_(): boolean {
    return this.diagnosis.category !== 'not_diagnosable' && this.diagnosis.primaryActionKey !== null
      && this.diagnosis.primaryActionKey !== 'copy_log';
  }

  private repair_(): void {
    const key = this.diagnosis.primaryActionKey;
    if (!this.openingLogs && this.hasRepair_() && key !== null) this.onAction(key);
  }

  /** 没有专用管理页的异常仍可分析本局日志，中性结果则提供关闭动作。 */
  private primaryLabel_(): string {
    if (this.hasRepair_()) return this.diagnosis.primaryActionLabel;
    return this.diagnosis.primaryActionKey === 'copy_log' ? '分析日志' : '知道了';
  }

  /** 同局分类决定结果卡的图标和色调；不能归因的记录用中性面色。 */
  private isFault_(): boolean { return this.diagnosis.category !== 'not_diagnosable'; }
  private faultColor_(): ResourceColor { return this.isFault_() ? this.theme.errorText : this.theme.textSecondary; }
  private formatTime(ts: number): string {
    if (!ts || ts <= 0) return '未知时间'
    let d = new Date(ts)
    let pad = (n: number): string => (n < 10 ? '0' + n : '' + n)
    let now = new Date()
    let sameDay = d.getFullYear() === now.getFullYear()
      && d.getMonth() === now.getMonth()
      && d.getDate() === now.getDate()
    let prefix = sameDay ? '今天 ' : pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' '
    return prefix + pad(d.getHours()) + ':' + pad(d.getMinutes())
  }

  /** 原版结果卡以分类图标、实例和本地启动时间标识这一次活动。 */
  @Builder
  private HeroCard_() {
    Column({ space: 12 }) {
      // 保留原来的图标位置；按本局故障类型绘制标记，图形下方直接透出原结果卡底色。
      Stack() {
        McErrorMark({ category: this.diagnosis.category, theme: this.theme, iconSize: 80 })
      }
      .width(88).height(88)

      // 主标题
      Text(this.diagnosis.title)
        .fontSize(18)
        .fontWeight(700)
        .fontColor(this.faultColor_())
        .textAlign(TextAlign.Center)

      // 元信息
      Row({ space: 8 }) {
        Row() {
          Text(this.version || '未知版本')
            .fontSize(11)
            .fontFamily('HarmonyHeiTi-Mono, monospace')
            .fontWeight(600)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor(this.theme.bgInput)
        .constraintSize({ maxWidth: 230 })

        Text('·')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.theme.textHint)

        Text(this.formatTime(this.sessionKey))
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textHint)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 22 })
    .backgroundColor(this.isFault_() ? this.theme.errorBg : this.theme.bgCard)
    .borderRadius(20)
    .alignItems(HorizontalAlign.Center)
  }

  /** 原因和技术摘要在面板打开时即可阅读，详细日志单独展开。 */
  @Builder
  private ReasonCard_() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Info, iconSize: 18, color: this.theme.warningText })
        Text(this.isFault_() ? '为什么会出错？' : '会话结果')
          .fontSize(14)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.diagnosis.description).id('mc-error-reason')
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .lineHeight(20)
        .width('100%')
        .textAlign(TextAlign.Start)

      // 原始异常沿用主题浅色底的等宽摘要，不截断已有原因。
      Row({ space: 8 }) {
        Text('技术原因：')
          .fontSize(11)
          .fontWeight(600)
          .fontColor(this.theme.actionText)
        Text(this.diagnosis.techDetail).id('mc-error-tech-detail')
          .fontSize(10)
          .fontFamily('HarmonyHeiTi-Mono, monospace')
          .fontWeight(500)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(8)
      .backgroundColor(this.theme.primaryLight)
      .alignItems(VerticalAlign.Center)
      if (this.diagnosis.primaryActionKey === null && this.isFault_()) {
        // 仅供说明的故障没有可跳转的修复，仍显示分类器给出的实际处理建议。
        ForEach(this.diagnosis.suggestions, (suggestion: McSuggestion) => {
          if (suggestion.actionKey === null) {
            Text('· ' + suggestion.title).fontSize(12).fontColor(this.theme.textSecondary)
          }
        }, (suggestion: McSuggestion) => suggestion.title)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  /** 目的地直接决定可见文字和回调。两个入口按相同权重布局，窄窗口让出箭头的位置给文字。 */
  @Builder
  private LogEntry_(author: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: this.roomForArrows_ ? 9 : 6 }) {
        AppIcon({ name: author ? AppIconName.Upload : AppIconName.Search, iconSize: 18, color: this.theme.actionText })
        Column({ space: 3 }) {
          Text(author ? '上传给开发者' : '分析日志').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
          Text(author ? '先预览脱敏文件' : '查看本局错误线索').fontSize(12).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.roomForArrows_) {
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 12, color: this.theme.textSecondary })
        }
      }.width('100%').alignItems(VerticalAlign.Center)
    }.id(author ? 'mc-error-upload' : 'mc-error-analyze-logs').layoutWeight(1)
      .constraintSize({ minHeight: 58 }).padding({ left: this.roomForArrows_ ? 12 : 8, right: this.roomForArrows_ ? 12 : 8, top: 9, bottom: 9 })
      // Normal 按钮显式使用同一圆角描边和表面，保证透明卡片在真机上也有完整的圆弧。
      .border({ width: 1, color: this.theme.divider, radius: 14 }).borderRadius(14).backgroundColor(Color.Transparent)
      .accessibilityText(author ? '上传日志给开发者，先预览脱敏文件' : '分析日志，查看本局错误线索')
      .enabled(!this.openingLogs && this.sessionKey > 0).onClick((): void => { this.openAnalysis_(author); })
  }

  /** 日志卡沿用原来的标题和外壳，两个目的地并排；渠道只允许本地分析时该项占满整行。 */
  @Builder
  private LogShareCard_() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Search, iconSize: 18, color: this.theme.actionText })
        Text('日志与诊断').fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
      Row({ space: 9 }) {
        this.LogEntry_(false)
        if (DistributionPolicy.allowPublisherServices()) {
          this.LogEntry_(true)
        }
      }.width('100%').alignItems(VerticalAlign.Center)
        .onAreaChange((_old: Area, current: Area): void => { this.roomForArrows_ = Number(current.width) >= 430; })
    }.width('100%').padding(16).borderRadius(14).backgroundColor(this.theme.bgCard).alignItems(HorizontalAlign.Start)
  }

  /** 折叠部分只切换本次快照的日志片段，不因展开而去读当前游戏的日志。 */
  @Builder
  private TechDetailsCard_() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button() {
          Row({ space: 8 }) {
            AppIcon({ name: this.logExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 16, color: this.theme.textSecondary })
            Text(this.logExpanded ? '技术详情（开发者）' : '技术详情（点击展开）')
              .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Center)
        }.id('mc-error-toggle-log').layoutWeight(1).constraintSize({ minHeight: 32 }).padding(0)
          .accessibilityText(this.logExpanded ? '收起技术详情' : '展开技术详情')
          .backgroundColor(Color.Transparent).onClick((): void => { this.logExpanded = !this.logExpanded; })
        if (DistributionPolicy.allowPublisherServices()) {
          Button() {
            Row({ space: 5 }) {
              AppIcon({ name: AppIconName.Upload, iconSize: 11, color: this.theme.actionText })
              Text('提交给开发者').fontSize(11).fontWeight(500).fontColor(this.theme.actionText)
            }.alignItems(VerticalAlign.Center)
          }.id('mc-error-detail-upload').padding({ left: 9, right: 9, top: 5, bottom: 5 }).borderRadius(8)
            .backgroundColor(this.theme.primaryLight).accessibilityText('上传日志给开发者')
            .enabled(!this.openingLogs && this.sessionKey > 0).onClick((): void => { this.openAnalysis_(true); })
        }
      }.width('100%').alignItems(VerticalAlign.Center)

      if (this.logExpanded) {
        if (this.isFault_()) {
          Row({ space: 8 }) {
            Text('错误类型').fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
            Text(this.diagnosis.errorKind).fontSize(10).fontFamily('HarmonyHeiTi-Mono, monospace')
              .fontWeight(600).fontColor(this.theme.errorText)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(6).backgroundColor(this.theme.errorBg)
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        Scroll() {
          Text(this.logTail.length > 0 ? this.logTail : '本次没有可预览的游戏日志片段。')
            .fontSize(10).fontFamily('HarmonyHeiTi-Mono, monospace').lineHeight(15).fontColor('#A0AEC0')
            .width('100%').textAlign(TextAlign.Start).padding(12).copyOption(CopyOptions.None)
        }.width('100%').constraintSize({ maxHeight: 320 }).scrollBar(BarState.Auto)
          .borderRadius(8).backgroundColor('#0F1115')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: this.logExpanded ? 16 : 14 })
      .backgroundColor(this.theme.bgCard).borderRadius(14).alignItems(HorizontalAlign.Start)
  }

  /** 原版固定底栏始终保留分类主操作和关闭；作者上传仅在渠道允许时出现。 */
  @Builder
  private ActionBar_() {
    Row({ space: 10 }) {
      Button() {
        Row({ space: 8 }) {
          Text(this.primaryLabel_())
            .fontSize(15).fontWeight(600).fontColor(this.theme.textOnPrimary).textAlign(TextAlign.Center)
          Text('→').fontSize(16).fontWeight(700).fontColor(this.theme.textOnPrimary)
        }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center)
      }.id(this.hasRepair_() ? 'mc-error-treatment' : 'mc-error-footer-primary')
        .accessibilityText(this.primaryLabel_())
        .layoutWeight(1).constraintSize({ minHeight: 48 }).borderRadius(24).backgroundColor(this.theme.primary)
        .enabled(!this.openingLogs)
        .onClick((): void => {
          if (this.hasRepair_()) this.repair_();
          else if (this.diagnosis.primaryActionKey === 'copy_log') this.openAnalysis_();
          else this.onClose();
        })
      if (DistributionPolicy.allowPublisherServices()) {
        AppRoundIconButton({ name: AppIconName.Upload, theme: this.theme, visualDiameter: 48,
          accessibilityLabel: '上传日志给开发者', controlId: 'mc-error-footer-upload', actionEnabled: !this.openingLogs && this.sessionKey > 0,
          onAction: (): void => { this.openAnalysis_(true); } })
      }
      AppRoundIconButton({ name: AppIconName.Close, theme: this.theme, accessibilityLabel: '关闭游戏结果',
        controlId: 'mc-error-footer-close', actionEnabled: !this.openingLogs, onAction: (): void => { this.onClose(); } })
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: Math.max(16, this.bottomSafeHeight) })
      .alignItems(VerticalAlign.Center).backgroundColor(this.theme.bgPrimary)
  }

  /** 卡片独立滚动，分类处理按钮留在标题宿主的底部。 */
  @Builder
  private ImmersiveTitleContent1_() {
    Scroll() {
      Column({ space: 14 }) {
        this.HeroCard_()
        this.ReasonCard_()
        this.LogShareCard_()
        this.TechDetailsCard_()
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
    }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    this.ActionBar_()
  }

  build() {
    ImmersiveTitleScaffold({ title: this.isFault_() ? '游戏异常退出' : '游戏已结束', theme: this.theme,
      modal: true, surfaceColor: this.theme.bgPrimary, closeLabel: '关闭游戏结果', closeId: 'mc-error-close',
      closeEnabled: !this.openingLogs, onClose: (): void => { this.onClose(); },
      content: (): void => { this.ImmersiveTitleContent1_(); } })
  }
}

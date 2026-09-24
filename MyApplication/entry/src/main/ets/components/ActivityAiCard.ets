/**
 * 账本列表、手机详情和平板侧栏共用的 AI 结果卡。
 * 仅观察现有分析服务和本地报告；首次出现、展开或切换活动均不会发起上传/分析。
 * 每个实例持有独立订阅，离开时释放；流生命周期仍由 AiAnalysisService 管理。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppIconName, ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';
import { MarkdownView } from './MarkdownView';
import { aiPreviewText } from './ActivityUiModel';
import { loadAiReport, loadAiReportBody, SavedAiReport } from './AiReportStore';
import { AiTaskSnapshot, AiTaskState, getAiTaskSnapshot, subscribeAiTaskChanges, unsubscribeAiTaskChanges, retrySaveAiReport } from './AiAnalysisService';
import { loadShareRecords, LogShareRecord, isShareRecordCurrent, LOGSHARE_API_BASE } from './LogShareClient';
import { AiStructuredDiagnosis, parseAiStructuredDiagnosis } from './AiDiagnostic';
import { AiDiagnosticCard } from './AiDiagnosticCard';
import { common } from '@kit.AbilityKit';

@Component
export struct ActivityAiCard {
  @Prop @Watch('onActivityChange_') activityId: number = 0;
  @Prop @Watch('onActivityChange_') refreshNonce: number = 0;
  @Prop theme: ThemeColors = new ThemeColors();
  /** 列表只读小索引；完整正文只在 expanded 为 true 的详情实例中加载。 */
  @Prop expanded: boolean = false;
  /** 时间轴已有详情入口时省略重复按钮；手机概览仍提供单独阅读入口。 */
  @Prop showCompactAction: boolean = true;
  @Prop allowAnalyze: boolean = true;
  /** 概览不为尚未分析创建大块占位；已有结果/失败仍明确展示。 */
  @Prop hideWhenEmpty: boolean = false;
  onOpen: () => void = () => {};
  onRequestAnalysis: () => void = () => {};
  @State private phase: AiTaskState = AiTaskState.IDLE;
  @State private answer: string = '';
  @State private diagnostic: AiStructuredDiagnosis | undefined = undefined;
  @State private preview: string = '';
  @State private sourceCaption: string = '';
  @State private failure: string = '';
  @State private localSaved: boolean = false;
  @State private historyResult: boolean = false;
  @State private savingResult: boolean = false;
  @State private liveStatus: string = '';
  @State private retryWaiting: boolean = false;
  private retryTimer: number = -1;
  private subscriptionId: number = 0;
  private revision: number = 0;
  private refreshTimer: number = -1;

  /** 上下文来自当前 Ability；缺失时显示读取错误而非假装没有报告。 */
  private context_(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  }

  aboutToAppear(): void {
    this.read_();
    this.subscriptionId = subscribeAiTaskChanges((key: number): void => {
      if (key !== this.activityId || this.refreshTimer >= 0) return;
      // 高频 SSE 增量合并成每 150ms 一次 UI 更新，不在每个 token 上读取文件。
      this.refreshTimer = setTimeout((): void => {
        this.refreshTimer = -1;
        if (!this.applyTask_()) this.read_();
      }, 150);
    });
  }

  aboutToDisappear(): void {
    this.revision++;
    unsubscribeAiTaskChanges(this.subscriptionId);
    if (this.refreshTimer >= 0) clearTimeout(this.refreshTimer);
    this.refreshTimer = -1;
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    this.retryTimer = -1;
  }

  /** 复用平板详情实例时必须清理上一活动的回答，异步读取用 revision 拒绝迟到结果。 */
  private onActivityChange_(): void { this.read_(); }

  /** 优先显示正在运行或刚结束的任务；DONE 与“本地已保存”使用不同文案。 */
  private applyTask_(): boolean {
    const task: AiTaskSnapshot = getAiTaskSnapshot(this.activityId);
    if (task.state === AiTaskState.IDLE) return false;
    // 已落盘的结果走来源核验，不能长期用内存 DONE 掩盖后续撤回或重新分享。
    if (task.state === AiTaskState.DONE && task.saved) return false;
    this.phase = task.state;
    this.liveStatus = task.statusText;
    this.retryWaiting = task.retryAt > Date.now();
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    if (this.retryWaiting) this.retryTimer = setTimeout((): void => { this.retryTimer = -1; this.applyTask_(); },
      Math.min(60000, Math.max(1, task.retryAt - Date.now())));
    this.answer = this.expanded ? task.text : '';
    // 只有详情的最终回答才提取结构化块，避免每个 SSE 增量重复解析和列表额外开销。
    this.diagnostic = this.expanded && task.state === AiTaskState.DONE ? parseAiStructuredDiagnosis(task.text) : undefined;
    this.preview = aiPreviewText(task.text);
    this.failure = task.error || task.saveError;
    this.localSaved = task.saved;
    this.historyResult = false;
    this.sourceCaption = 'LogShare 官方 · ' + (task.saved ? '已保存' : task.state === AiTaskState.RUNNING ? '分析中' : '本次结果');
    return true;
  }

  /** 读取报告索引后校验来源；不把作者回执或过期来源呈现为当前官方结论。 */
  private async read_(): Promise<void> {
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    this.retryTimer = -1; this.retryWaiting = false; this.liveStatus = '';
    const revision: number = ++this.revision;
    const key: number = this.activityId;
    this.phase = AiTaskState.IDLE;
    this.answer = ''; this.preview = ''; this.failure = ''; this.sourceCaption = '';
    this.diagnostic = undefined;
    this.localSaved = false; this.historyResult = false;
    if (key <= 0 || this.applyTask_()) return;
    const context = this.context_();
    if (context === undefined) { this.failure = '暂时无法读取本地 AI 结果'; return; }
    try {
      const report: SavedAiReport | undefined = loadAiReport(context.filesDir, key);
      if (report === undefined) {
        // 旧版本只有固定会话 .md；路径由会话号派生，不信任外部记录中的任意路径。
        const legacyPath: string = context.filesDir + '/logs/ai/' + key + '.md';
        if (!fs.accessSync(legacyPath)) return;
        if (fs.statSync(legacyPath).size > 4 * 1024 * 1024) throw new Error('历史 AI 结果过大');
        const legacy: string = fs.readTextSync(legacyPath);
        if (legacy.trim().length === 0) return;
        this.phase = AiTaskState.DONE; this.preview = aiPreviewText(legacy);
        this.answer = this.expanded ? legacy : ''; this.localSaved = true; this.historyResult = true;
        this.diagnostic = this.expanded ? parseAiStructuredDiagnosis(legacy) : undefined;
        this.sourceCaption = '历史 AI 结果 · 来源未绑定，仅供参考';
        return;
      }
      this.phase = AiTaskState.DONE; this.preview = report.summary; this.localSaved = true;
      this.answer = this.expanded ? loadAiReportBody(context.filesDir, report) : '';
      this.diagnostic = this.expanded ? parseAiStructuredDiagnosis(this.answer) : undefined;
      this.sourceCaption = '已保存 · 正在核验来源';
      const shares: LogShareRecord[] = await loadShareRecords(context);
      if (revision !== this.revision || key !== this.activityId) return;
      const matches: LogShareRecord[] = shares.filter((share: LogShareRecord): boolean => share.activityId === key && share.accepted !== false)
        .sort((left: LogShareRecord, right: LogShareRecord): number => right.sharedAt - left.sharedAt);
      const latest: LogShareRecord | undefined = matches.length > 0 ? matches[0] : undefined;
      const current: boolean = report.apiBaseUrl === LOGSHARE_API_BASE && latest !== undefined && latest.id === report.shareId
        && latest.apiBaseUrl === report.apiBaseUrl && isShareRecordCurrent(latest)
        && report.snapshotDigest.length > 0 && latest.snapshotDigest === report.snapshotDigest;
      this.historyResult = !current;
      this.sourceCaption = current ? 'LogShare 官方 · 已保存 · 分享时快照' : '历史结果 · 来源分享已变化或不可用';
    } catch (e) {
      if (revision === this.revision) this.failure = 'AI 结果读取失败：' + (e as Error).message;
    }
  }

  /** 固定状态文案，不提供未经服务端支持的百分比、排队序号或“作者已处理”。 */
  private title_(): string {
    if (this.phase === AiTaskState.RUNNING) return this.liveStatus || 'AI 正在分析…';
    if (this.phase === AiTaskState.ERROR) return 'AI 分析失败';
    if (this.phase === AiTaskState.DONE) return this.historyResult ? 'AI 历史结果' : 'AI 分析 · 已完成';
    return this.failure.length > 0 ? 'AI 结果暂不可读' : '尚未进行 AI 分析';
  }

  /** 保存失败可独立重试；按钮不会产生第二次公开上传或分析计费。 */
  private async retrySave_(): Promise<void> {
    const context = this.context_();
    if (context === undefined || this.savingResult) return;
    this.savingResult = true;
    try { await retrySaveAiReport(context, this.activityId); this.applyTask_(); }
    finally { this.savingResult = false; }
  }

  /** 没有分析结果时只留一行入口，不让空状态占据活动卡的大块阅读空间。 */
  private compactIdle_(): boolean {
    return !this.expanded && !this.showCompactAction && this.phase === AiTaskState.IDLE && this.failure.length === 0;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Ai, iconSize: 18, color: this.theme.primary })
        Text(this.title_()).fontSize(14).fontWeight(600).fontColor(this.theme.primary).layoutWeight(1)
        if (this.phase === AiTaskState.RUNNING) { LoadingProgress().width(18).height(18).color(this.theme.primary) }
        if (this.expanded || this.phase !== AiTaskState.IDLE) {
          Text('仅供参考').fontSize(11).fontColor(this.theme.warningText)
        }
      }.width('100%')
      if (!this.compactIdle_()) {
      if (this.expanded && this.diagnostic !== undefined) {
        AiDiagnosticCard({ diagnosis: this.diagnostic, theme: this.theme })
      }
      if (this.expanded && this.answer.length > 0) {
        MarkdownView({ content: this.answer, theme: this.theme, baseFontSize: 14, maxCodeLines: 12 })
      } else if (this.preview.length > 0) {
        Text(this.preview).fontSize(14).fontColor(this.theme.textPrimary).width('100%')
          .maxLines(this.showCompactAction ? 3 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(this.phase === AiTaskState.RUNNING ? '可以离开当前页面，完成后在消息中心查看。'
          : this.phase === AiTaskState.DONE ? '分析已完成，点击查看完整回答。'
          : this.phase === AiTaskState.ERROR ? '分析未完成，可在详情中重试。'
          : this.showCompactAction ? 'AI 需要主动确认公开分享；不会自动上传日志。' : '尚无结论 · 可在详情中主动分析')
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      }
      if (this.sourceCaption.length > 0) {
        Text(this.sourceCaption).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      }
      if (this.failure.length > 0) {
        Text(this.failure).fontSize(12).fontColor(this.theme.errorText).width('100%')
          .maxLines(this.expanded ? 20 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.expanded) {
        Text('第三方 AI 未针对 HarmonyOS 校准，可能误判。请核对日志，不要直接执行不适用于本平台的命令。')
          .fontSize(12).fontColor(this.theme.warningText).width('100%')
        if (this.phase === AiTaskState.DONE && !this.localSaved && this.failure.length > 0) {
          Button(this.savingResult ? '正在保存…' : '重试保存结果').height(44)
            .enabled(!this.savingResult).onClick(() => { this.retrySave_() })
        }
        if (this.phase === AiTaskState.IDLE || this.phase === AiTaskState.ERROR) {
          Button(this.phase === AiTaskState.ERROR ? '重试 AI 分析' : '选择日志并分析')
            .height(44).fontSize(14).fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
            .enabled(this.allowAnalyze && !this.retryWaiting).onClick(() => { this.onRequestAnalysis() })
        }
      } else if (this.showCompactAction) {
        Button(this.phase === AiTaskState.RUNNING ? '展开实时分析' : this.phase === AiTaskState.IDLE ? '选择日志并分析' : '展开阅读全文')
          .height(44).fontSize(14).fontWeight(600).fontColor(this.theme.primary)
          .backgroundColor(Color.Transparent).enabled(this.phase !== AiTaskState.IDLE || this.allowAnalyze)
          .onClick(() => { if (this.phase === AiTaskState.IDLE) this.onRequestAnalysis(); else this.onOpen(); })
      }
      }
    }.width('100%').padding(this.compactIdle_() ? 0 : this.showCompactAction ? 16 : 12).borderRadius(18)
      .backgroundColor(this.compactIdle_() ? Color.Transparent : this.theme.primaryLight)
      .alignItems(HorizontalAlign.Start)
      .visibility(this.hideWhenEmpty && this.phase === AiTaskState.IDLE && this.failure.length === 0 ? Visibility.None : Visibility.Visible)
      .onClick(() => { if (!this.expanded && !this.showCompactAction) this.onOpen(); })
  }
}

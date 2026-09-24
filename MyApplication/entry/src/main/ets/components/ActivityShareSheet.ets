/**
 * 活动账本和详情共用的轻量分享层。
 * quick 只由用户点击“分享日志”进入：首次确认默认公开范围，记住后自动冻结/脱敏/分享。
 * advanced 为自定义、预览和作者反馈；AI 永远需要本次明确开启，关闭 sheet 不授权新请求。
 */
import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, AppIconName, DistributionPolicy, EvidenceFileRecord, EvidenceExportSnapshot,
  FrozenEvidenceFile, disposeEvidenceExportSnapshot, evidenceRoleLabel, normalizeEvidenceSelection,
  formatLogBytes, createEvidenceExcerptSnapshot } from 'commons';
import { AppIcon } from './AppIcon';
import { sortEvidenceForView, evidenceReadable, evidenceCaptureLabel, EvidenceScenario,
  EVIDENCE_SCENARIOS, EVIDENCE_SCENARIO_LABELS, evidenceScenarioSelection } from 'commons';
import { AnimatedPillBar } from './AnimatedPillBar';
import { ActivityShareDraft, loadActivityShareDraft, activityShareSummary, activityShareMetadata,
  activityShareDisclosure, prepareActivityShare, quickShareConsentKey, hasQuickShareConsent,
  rememberQuickShareConsent, resetQuickShareConsent, persistActivityShareSelection } from './ActivitySharePreparation';
import { LogShareRecord, LogSharePreflight, prepareLogShare, LOGSHARE_API_BASE, logShareSourceLabel,
  logShareSupportsAi, isShareRecordCurrent, logShareExportBudgetBytes } from './LogShareClient';
import { LogShareRequestError } from './LogShareErrors';
import { shareEvidenceSnapshot, submitEvidenceToAuthor, retryPendingEvidenceShare,
  subscribeEvidenceShare, unsubscribeEvidenceShare } from './EvidenceShareService';
import { saveSessionShare } from './McSessionSnapshot';
import { exportSessionEvidenceZip } from './EvidenceBundleExport';
import { startAiAnalysis } from './AiAnalysisService';
import { ensureNotifyPermission } from './AppNotifier';
import { ActivityLogModel, LogRow } from './ActivityLogModel';
import { AuthorUploadIdentity, prepareAuthorUploadIdentity } from './CrashLogUploader';

@Component
export struct ActivityShareSheet {
  @Prop activityId: number = 0;
  @Prop initialMode: string = 'advanced';
  @Prop initialDestination: string = 'logshare';
  @Prop initialAi: boolean = false;
  @Prop theme: ThemeColors = new ThemeColors();
  onClosed: () => void = () => {};
  onBusyChanged: (busy: boolean) => void = () => {};
  onShared: (record: LogShareRecord) => void = () => {};
  onAuthorAccepted: (id: string, duplicate: boolean) => void = () => {};
  onAdvancedChanged: (advanced: boolean) => void = () => {};
  @State private phase: string = 'loading';
  @State private advanced: boolean = false;
  @State private destination: string = 'logshare';
  @State private requestAi: boolean = false;
  @State private rememberRule: boolean = true;
  @State private draft: ActivityShareDraft = new ActivityShareDraft();
  @State private previews: FrozenEvidenceFile[] = [];
  @State private shared: LogShareRecord | undefined = undefined;
  @State private authorId: string = '';
  @State private errorText: string = '';
  @State private errorKind: string = '';
  @State private confirmUnknownRetry: boolean = false;
  @State private serviceText: string = '';
  @State private showDetails: boolean = false;
  @State private showUnavailable: boolean = false;
  @State private scenario: EvidenceScenario = EvidenceScenario.RECOMMENDED;
  @State private authorDisclosure: string = '';
  @State private excerpted: boolean = false;
  @State private previewName: string = '';
  @State private previewReading: boolean = false;
  @State private previewError: string = '';
  @State private previewPage: number = 0;
  @State private previewNext: boolean = false;
  @State private previewRows: LogRow[] = [];
  private previewModel: ActivityLogModel = new ActivityLogModel();
  private previewFile: FrozenEvidenceFile | undefined = undefined;
  private previewGeneration: number = 0;
  private snapshot: EvidenceExportSnapshot | undefined = undefined;
  private preflight: LogSharePreflight | undefined = undefined;
  private alive: boolean = false;
  private generation: number = 0;
  private subscription: number = 0;
  private authorIdentity: AuthorUploadIdentity | undefined = undefined;
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');

  aboutToAppear(): void {
    this.alive = true;
    this.advanced = this.initialMode !== 'quick';
    this.destination = this.initialDestination;
    this.requestAi = this.advanced && this.initialAi;
    this.subscription = subscribeEvidenceShare((record: LogShareRecord): void => {
      if (this.alive && this.shared?.id === record.id && this.shared.url === record.url) {
        this.shared = record; this.serviceText = this.receiptCaption_(record);
      }
    });
    this.load_();
  }

  aboutToDisappear(): void {
    this.alive = false; this.generation++;
    unsubscribeEvidenceShare(this.subscription); this.previewModel.cancel();
    // 已确认的 POST 可以结束，但它使用的快照必须由 finally 释放，不能在传输中删除。
    if (this.phase !== 'sending') this.release_();
    this.onBusyChanged(false);
  }

  private busy_(): boolean { return this.phase === 'loading' || this.phase === 'preparing' || this.phase === 'sending'; }
  private setPhase_(phase: string): void {
    if (!this.alive) return;
    this.phase = phase; this.onBusyChanged(this.busy_());
  }
  private release_(): void {
    const snapshot = this.snapshot; this.snapshot = undefined;
    if (snapshot !== undefined) { try { disposeEvidenceExportSnapshot(snapshot); } catch (e) { /* 已清理 */ } }
  }
  private fail_(error: Error): void {
    if (!this.alive) return;
    this.errorText = error.message; this.errorKind = error instanceof LogShareRequestError ? error.stage : 'local-prepare';
    this.setPhase_('error');
  }

  /** 出现页面本身不发送；只有调用方明确传 quick 的点击动作才有后续快速发送资格。 */
  private async load_(): Promise<void> {
    const context = this.context;
    if (context === undefined) { this.fail_(new Error('暂时无法读取活动')); return; }
    const generation: number = ++this.generation;
    try {
      const draft = await loadActivityShareDraft(context, this.activityId, !this.advanced);
      if (!this.alive || generation !== this.generation) return;
      this.draft = draft;
      const recommended: string[] = evidenceScenarioSelection(draft.files, EvidenceScenario.RECOMMENDED);
      this.scenario = recommended.length === draft.selectedFileIds.length && recommended.every((id: string): boolean => draft.selectedFileIds.includes(id))
        ? EvidenceScenario.RECOMMENDED : EvidenceScenario.CUSTOM;
      if (this.destination === 'author' && !DistributionPolicy.allowPublisherServices()) {
        this.errorText = '当前版本不提供作者反馈。请主动选择公开分享或本地导出。';
        this.advanced = true; this.setPhase_('select'); return;
      }
      if (!this.advanced && draft.selectedFileIds.length === 0) {
        this.advanced = true; this.errorText = '没有可快捷分享的推荐日志，请选择可读文件。';
      }
      this.setPhase_('select');
      if (!this.advanced) await this.prepare_(true);
    } catch (e) { this.fail_(e as Error); }
  }

  /** 自动化仅替代本地选择/预览步骤；备用服务每次都明确确认，不继承官方授权。 */
  private async prepare_(autoSend: boolean): Promise<void> {
    const context = this.context;
    if (context === undefined || this.draft.selectedFileIds.length === 0 || this.phase === 'sending') return;
    const generation: number = ++this.generation;
    this.errorText = ''; this.errorKind = ''; this.confirmUnknownRetry = false; this.setPhase_('preparing');
    try {
      this.release_();
      const snapshot = await prepareActivityShare(context, this.draft);
      if (!this.alive || generation !== this.generation) { disposeEvidenceExportSnapshot(snapshot); return; }
      this.snapshot = snapshot; this.previews = snapshot.files.slice(); this.excerpted = false;
      if (this.destination === 'logshare') {
        const plan = await prepareLogShare();
        if (!this.alive || generation !== this.generation) return;
        this.preflight = plan; this.serviceText = this.planCaption_(plan);
        if (plan.apiBaseUrl !== LOGSHARE_API_BASE && this.requestAi) {
          this.requestAi = false; this.errorText = '当前为备用服务，不支持 AI。本次只生成分享链接。';
        }
        if (!this.fits_(plan)) throw new LogShareRequestError('推荐日志超过本次上传预算（服务端动态限额或多文件展开安全预算）。可在高级选项减少文件、生成节选预览，或导出完整脱敏 ZIP。', 'limit');
        const allowed: boolean = plan.apiBaseUrl === LOGSHARE_API_BASE
          && await hasQuickShareConsent(context, quickShareConsentKey(plan));
        if (!this.alive || generation !== this.generation) return;
        this.setPhase_('review');
        if (autoSend && !this.advanced && allowed) await this.send_(false);
      } else {
        this.authorIdentity = await prepareAuthorUploadIdentity();
        if (!this.alive || generation !== this.generation) return;
        this.authorDisclosure = 'clientId: ' + this.authorIdentity.clientId + '\ndevice: ' + this.authorIdentity.device
          + '\nosVersion: ' + this.authorIdentity.osVersion + '\nappVersion: ' + this.authorIdentity.appVersion;
        this.serviceText = '提交 AMCL 作者后台，不生成公开链接'; this.setPhase_('review');
      }
    } catch (e) { this.fail_(e as Error); }
    finally { if (!this.alive) this.release_(); }
  }

  private planCaption_(plan: LogSharePreflight): string {
    return (plan.apiBaseUrl === LOGSHARE_API_BASE ? 'LogShare 官方' : 'AMCL 备用服务')
      + ' · 预计保留 ' + Math.ceil(plan.limits.storageTimeSec / 86400) + ' 天 · 知道链接的人可访问';
  }
  private receiptCaption_(record: LogShareRecord): string {
    return logShareSourceLabel(record.url) + ' · 撤回凭据已保存'
      + (record.verificationError ? '\n' + record.verificationError : '\n远端文件清单已核对');
  }
  private samePlan_(left: LogSharePreflight, right: LogSharePreflight): boolean {
    return left.apiBaseUrl === right.apiBaseUrl && left.limits.storageTimeSec === right.limits.storageTimeSec
      && left.limits.maxBytes === right.limits.maxBytes && left.limits.maxLines === right.limits.maxLines;
  }

  /** 确认身份实质未变时不制造第二次确认；离页/重选后任何迟到准备结果都不发 POST。 */
  private async send_(remember: boolean): Promise<void> {
    const context = this.context; const snapshot = this.snapshot;
    if (context === undefined || snapshot === undefined || this.busy_() || !this.alive) return;
    if (this.destination === 'author' && !DistributionPolicy.allowPublisherServices()) return;
    const generation: number = this.generation;
    this.setPhase_('preparing'); this.errorText = ''; this.errorKind = '';
    try {
      if (this.destination === 'logshare') {
        const old = this.preflight;
        if (old === undefined || Date.now() - old.checkedAt > 60000) {
          const fresh = await prepareLogShare();
          if (!this.alive || generation !== this.generation) return;
          this.preflight = fresh; this.serviceText = this.planCaption_(fresh);
          if (fresh.apiBaseUrl !== LOGSHARE_API_BASE) this.requestAi = false;
          if (old === undefined || !this.samePlan_(old, fresh)) {
            this.errorText = '分享服务或限制已变化，请核对后再确认。'; this.setPhase_('review'); return;
          }
        }
        if (remember && this.preflight?.apiBaseUrl === LOGSHARE_API_BASE) {
          await rememberQuickShareConsent(context, quickShareConsentKey(this.preflight));
        }
      }
      if (!this.alive || generation !== this.generation) return;
      this.setPhase_('sending');
      if (this.destination === 'author') {
        const result = await submitEvidenceToAuthor(snapshot, '活动日志反馈：' + (this.draft.manifest?.title ?? ''), 'manual', this.authorIdentity);
        if (!result.ok) throw new LogShareRequestError(result.error, result.errorStage ?? 'http');
        if (this.alive) { this.authorId = result.id; this.setPhase_('done'); this.onAuthorAccepted(result.id, result.duplicate); }
      } else {
        const record = await shareEvidenceSnapshot(context, snapshot, activityShareMetadata(this.draft), this.preflight,
          this.advanced && this.confirmUnknownRetry);
        try { await saveSessionShare(this.activityId, record.id, record.url, record.token, record.sharedAt); }
        catch (e) { /* 独立凭据已落盘；诊断快捷引用失败不能伪装上传失败。 */ }
        if (this.requestAi && logShareSupportsAi(record.url)) this.startAi_(record);
        if (this.alive) {
          this.shared = record; this.serviceText = this.receiptCaption_(record); this.setPhase_('done'); this.onShared(record);
          // 快捷分享的同一次用户操作即拿到可粘贴链接，复制失败独立提示，不重传日志。
          if (!this.advanced) await this.copy_();
        }
      }
    } catch (e) { this.fail_(e as Error); }
    finally { if (this.phase === 'done' || !this.alive) this.release_(); }
  }

  private startAi_(record: LogShareRecord): void {
    const context = this.context;
    if (context === undefined || !logShareSupportsAi(record.url) || !isShareRecordCurrent(record)) return;
    ensureNotifyPermission(context).catch((): void => {});
    startAiAnalysis(context, this.activityId, record.id, this.draft.manifest?.title ?? '', record.apiBaseUrl, record.snapshotDigest ?? '');
  }
  private async retrySave_(): Promise<void> {
    const context = this.context;
    if (context === undefined) return;
    this.setPhase_('preparing');
    try {
      const record = await retryPendingEvidenceShare(context, this.activityId);
      if (record === undefined) throw new Error('本次没有待保存凭据，请到分享记录查看已有链接');
      if (this.alive) { this.shared = record; this.serviceText = this.receiptCaption_(record); this.errorText = '';
        this.setPhase_('done'); this.onShared(record); }
    } catch (e) { this.fail_(e as Error); if (!(e instanceof LogShareRequestError)) this.errorKind = 'persist'; }
  }

  /** 高级选择只能由用户动作进入，不改变任何已经发送的公开链接。 */
  private advanced_(): void {
    if (this.busy_()) return;
    this.onAdvancedChanged(true);
    if (this.errorKind === 'unknown-outcome') { this.advanced = true; return; }
    this.generation++; this.release_(); this.advanced = true; this.previews = []; this.previewName = '';
    this.confirmUnknownRetry = false;
    this.shared = undefined; this.authorId = ''; this.preflight = undefined; this.errorText = ''; this.errorKind = '';
    this.setPhase_('select');
  }
  private toggle_(fileId: string, checked: boolean): void {
    if (this.phase !== 'select' || this.context === undefined) return;
    const next = this.draft.selectedFileIds.filter((id: string): boolean => id !== fileId);
    if (checked) next.push(fileId);
    try {
      persistActivityShareSelection(this.context, this.draft, normalizeEvidenceSelection(this.draft.files, next), this.draft.includePublicSummary);
      this.scenario = EvidenceScenario.CUSTOM;
    }
    catch (e) { this.errorText = '文件选择未保存，请重试'; }
  }

  private toggleSummary_(checked: boolean): void {
    if (this.phase !== 'select' || this.context === undefined) return;
    try { persistActivityShareSelection(this.context, this.draft, this.draft.selectedFileIds, checked); }
    catch (e) { this.errorText = '摘要选项未保存，请重试'; }
  }

  /** 主动模板仅改变高级页选择，不影响记住的快捷分享授权；冻结后再检查真实出站范围。 */
  private chooseScenario_(index: number): void {
    if (this.context === undefined || this.phase !== 'select' || !this.advanced) return;
    const scenario: EvidenceScenario = EVIDENCE_SCENARIOS[index] ?? EvidenceScenario.RECOMMENDED;
    try {
      persistActivityShareSelection(this.context, this.draft, evidenceScenarioSelection(this.draft.files, scenario), this.draft.includePublicSummary);
      this.scenario = scenario;
    } catch (e) { this.errorText = '模板选择未保存：' + (e as Error).message; }
  }

  /** 默认仅展示真正可读文件，未生成项仍能展开核对，避免空 Agent/Debug 挤占首屏。 */
  private selectionFiles_(): EvidenceFileRecord[] {
    return sortEvidenceForView(this.draft.files).filter((file: EvidenceFileRecord): boolean => this.showUnavailable || evidenceReadable(file));
  }
  private async readPreview_(file: FrozenEvidenceFile, page: number = 0): Promise<void> {
    const generation: number = ++this.previewGeneration;
    this.previewError = ''; this.previewPage = page;
    this.previewFile = file; this.previewName = file.name; this.previewReading = true;
    try {
      const loaded: boolean = await this.previewModel.loadEvidence([{ path: file.path, compressed: false }], 0, '', page * 300);
      if (!this.alive || generation !== this.previewGeneration || !loaded || this.previewFile !== file) return;
      const rows: LogRow[] = [];
      for (let index: number = 0; index < this.previewModel.totalCount(); index++) rows.push(this.previewModel.getData(index));
      this.previewRows = rows; this.previewPage = page; this.previewNext = this.previewModel.hasNextPage;
    } catch (e) { if (this.alive && generation === this.previewGeneration) this.previewError = '预览读取失败：' + (e as Error).message; }
    finally { if (this.alive && generation === this.previewGeneration) this.previewReading = false; }
  }
  private async copy_(): Promise<void> {
    if (this.shared === undefined) return;
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.shared.url));
      if (this.alive) this.getUIContext().getPromptAction().showToast({ message: '链接已复制' }); }
    catch (e) { if (this.alive) this.errorText = '复制失败，请重试；分享链接仍已保存。'; }
  }
  private async export_(): Promise<void> {
    if (this.context === undefined || this.busy_()) return;
    this.setPhase_('preparing');
    try {
      const result = await exportSessionEvidenceZip(this.context, this.activityId, activityShareSummary(this.draft));
      if (this.alive) { this.setPhase_(this.shared === undefined ? 'select' : 'done'); if (!result.ok && !result.cancelled) this.errorText = result.message; }
    } catch (e) { this.fail_(e as Error); }
  }

  private menu_(): void {
    if (this.busy_()) return;
    this.getUIContext().getPromptAction().showActionMenu({ title: '分享选项', buttons: [
      { text: '自定义文件与脱敏预览', color: this.theme.primary as string },
      { text: '导出全部可分享日志（脱敏 ZIP）', color: this.theme.primary as string },
      { text: '分享记录与撤回', color: this.theme.primary as string },
      { text: '恢复每次快捷分享前确认', color: this.theme.textSecondary as string },
    ] }).then(async (result: promptAction.ActionMenuSuccessResponse): Promise<void> => {
      if (result.index === 0) this.advanced_();
      else if (result.index === 1) await this.export_();
      else if (result.index === 2) { this.onClosed(); this.getUIContext().getRouter().pushUrl({ url: 'pages/LogShareHistoryPage' }); }
      else if (result.index === 3 && this.context !== undefined) {
        await resetQuickShareConsent(this.context); this.errorText = '已恢复快捷分享前确认。';
      }
    }).catch((): void => {});
  }
  private openPolicy_(): void {
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: 'https://logshare.cn/privacy' };
    this.context?.startAbility(want).catch((): void => { this.errorText = '无法打开隐私说明'; });
  }
  private totalBytes_(): number {
    let bytes: number = 0; for (const file of this.previews) bytes += file.bytes; return bytes;
  }

  /** 配额按冻结后的真实文件/行数与服务限制交集计算，快捷路径绝不静默裁短。 */
  private fits_(plan: LogSharePreflight): boolean {
    return this.previews.length <= 200 && this.totalBytes_() <= logShareExportBudgetBytes(plan.limits)
      && this.previews.every((file: FrozenEvidenceFile): boolean => file.bytes <= plan.limits.maxBytes
        && file.lines <= plan.limits.maxLines);
  }

  private async excerpt_(): Promise<void> {
    const source = this.snapshot; const plan = this.preflight;
    if (source === undefined || plan === undefined || this.busy_()) return;
    this.setPhase_('preparing');
    try {
      // 节选器按全体文件分配预算，用单文件限制与总量的较小者作为保守节选预算；
      // 正常完整分享的 fits_ 仍逐文件检查，不因总行数较多而强迫用户节选。
      const excerpt = await createEvidenceExcerptSnapshot(source,
        Math.min(logShareExportBudgetBytes(plan.limits), plan.limits.maxBytes), plan.limits.maxLines);
      if (!this.alive) { disposeEvidenceExportSnapshot(excerpt); return; }
      this.snapshot = excerpt; this.previews = excerpt.files.slice(); disposeEvidenceExportSnapshot(source);
      this.advanced = true; this.onAdvancedChanged(true); this.excerpted = true;
      this.errorText = ''; this.errorKind = ''; this.setPhase_('review');
    } catch (e) { this.fail_(e as Error); }
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(this.phase === 'done' ? (this.shared === undefined ? '作者端已接收' : '分享链接已就绪') : this.advanced ? '高级分享' : '分享日志')
            .fontSize(24).fontWeight(600).fontColor(this.theme.textPrimary)
          Text(this.draft.manifest?.title ?? '本次活动').fontSize(12).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button() { AppIcon({ name: AppIconName.More, iconSize: 20, color: this.theme.textSecondary }) }
          .width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.busy_())
          .accessibilityText('高级选择、导出与分享管理').onClick(() => { this.menu_(); })
      }.width('100%').padding({ right: 28 })
      if (this.previewName.length > 0) {
        this.Preview_()
      } else {
        Scroll() {
          Column({ space: 16 }) {
            if (this.busy_()) {
              Column({ space: 12 }) {
                LoadingProgress().width(32).height(32).color(this.theme.primary)
                Text(this.phase === 'sending' ? '正在生成分享链接…' : '正在准备推荐日志…').fontSize(16).fontColor(this.theme.textPrimary)
                Text(this.phase === 'sending' ? '发送已经确认，关闭页面不会撤回这次上传。' : '正在本地脱敏与检查服务。关闭即可停止后续发送。')
                  .fontSize(12).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
              }.width('100%').padding(24)
            } else if (this.phase === 'done') {
              Text(this.shared?.url ?? ('接收编号：' + this.authorId)).fontSize(16).fontColor(this.theme.primary).width('100%')
              Text(this.shared === undefined ? '本次提交已接收，不生成公开链接；作者后台分析不回传到 App。' : this.serviceText)
                .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
            } else {
              if (this.advanced && this.phase === 'select') {
                AnimatedPillBar({ labels: DistributionPolicy.allowPublisherServices() ? ['公开分享', '提交作者'] : ['公开分享'],
                  selectedIndex: this.destination === 'author' ? 1 : 0, theme: this.theme,
                  onSelect: (index: number): void => { this.destination = index === 0 ? 'logshare' : 'author'; this.requestAi = false; } })
                Text('按问题选择附加日志').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(EVIDENCE_SCENARIO_LABELS, (label: string, index: number) => {
                      Button(label).height(44).fontSize(12)
                        .backgroundColor(this.scenario === EVIDENCE_SCENARIOS[index] ? this.theme.primaryLight : this.theme.bgCard)
                        .fontColor(this.theme.primary).onClick(() => { this.chooseScenario_(index); })
                    }, (label: string): string => label)
                  }
                }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
                Text('模板会选中相关的可读文件；可以继续逐项调整，预览后才发送。')
                  .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
                ForEach(this.selectionFiles_(), (file: EvidenceFileRecord) => {
                  Row({ space: 8 }) {
                    Toggle({ type: ToggleType.Checkbox, isOn: this.draft.selectedFileIds.includes(file.fileId) })
                      .width(44).height(44).enabled(normalizeEvidenceSelection(this.draft.files, [file.fileId]).length > 0)
                      .onChange((checked: boolean): void => { this.toggle_(file.fileId, checked); })
                    Column({ space: 4 }) {
                      Text(evidenceRoleLabel(file.role)).fontSize(14).fontColor(this.theme.textPrimary)
                      Text(file.path + ' · ' + formatLogBytes(file.bytes)).fontSize(12).fontColor(this.theme.textSecondary)
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(evidenceCaptureLabel(file, this.draft.manifest?.state === 0)).fontSize(11).fontColor(this.theme.textHint)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%')
                }, (file: EvidenceFileRecord): string => file.fileId)
                Button(this.showUnavailable ? '收起未生成的文件' : '查看未生成或不可用的文件').height(44)
                  .fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.textSecondary)
                  .onClick(() => { this.showUnavailable = !this.showUnavailable; })
                Row() {
                  Text('附会话摘要').fontSize(14).fontColor(this.theme.textPrimary).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.draft.includePublicSummary })
                    .onChange((checked: boolean): void => { this.toggleSummary_(checked); })
                }.width('100%')
              } else {
                Text(this.serviceText).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                Text('发送 ' + this.previews.length + ' 个文件 · ' + formatLogBytes(this.totalBytes_()))
                  .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
                Text(this.advanced ? '只发送已选择的文件和公开清单；会话摘要与 AI 由本次选择决定。'
                  : '默认包含本次主日志、游戏输出、JVM 启动输出、可信崩溃证据和启动器日志，并附脱敏系统/CPU/GPU环境与诊断概览；不自动开启 AI。')
                  .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
                if (this.advanced) {
                  ForEach(this.previews, (file: FrozenEvidenceFile) => {
                    Button() {
                      Row({ space: 8 }) {
                        Text(file.name).fontSize(12).fontColor(this.theme.primary).layoutWeight(1)
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(formatLogBytes(file.bytes)).fontSize(12).fontColor(this.theme.textSecondary)
                        AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.primary })
                      }.width('100%')
                    }.width('100%').constraintSize({ minHeight: 48 }).padding(12).backgroundColor(this.theme.bgCard)
                      .onClick(() => { this.readPreview_(file); })
                  }, (file: FrozenEvidenceFile): string => file.name)
                  if (this.destination === 'logshare' && this.preflight?.apiBaseUrl === LOGSHARE_API_BASE) {
                    Row() {
                      Text('分享后开始 AI 分析').fontSize(14).fontColor(this.theme.textPrimary).layoutWeight(1)
                      Toggle({ type: ToggleType.Switch, isOn: this.requestAi }).onChange((checked: boolean): void => { this.requestAi = checked; })
                    }.width('100%')
                  }
                } else if (this.preflight?.apiBaseUrl === LOGSHARE_API_BASE) {
                  Row({ space: 8 }) {
                    Toggle({ type: ToggleType.Checkbox, isOn: this.rememberRule }).width(44).height(44)
                      .onChange((checked: boolean): void => { this.rememberRule = checked; })
                    Text('以后相同默认范围直接分享').fontSize(14).fontColor(this.theme.textPrimary).layoutWeight(1)
                  }.width('100%')
                }
              }
              Text('还会发送 App/游戏版本、设备型号与系统版本。客户端已脱敏，服务端可能再次处理，仍请留意敏感信息。')
                .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              if (this.destination === 'author') {
                Text('作者反馈还包含用于关联重复提交的安装标识。').fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              }
              Button(this.showDetails ? '收起出站元数据' : '查看出站元数据').height(44).fontSize(12)
                .fontColor(this.theme.primary).backgroundColor(Color.Transparent).onClick(() => { this.showDetails = !this.showDetails; })
              if (this.showDetails) {
                Text(this.destination === 'author' ? this.authorDisclosure + '\nactivityId: ' + this.activityId
                  + '\nmeta: 本次快照摘要、脱敏版本' : activityShareDisclosure(this.draft))
                  .fontSize(12).fontFamily('monospace').fontColor(this.theme.textSecondary).width('100%')
              }
              if (this.excerpted) { Text('当前为明确节选，完整本地日志未改动。请核对后再发送。').fontSize(12).fontColor(this.theme.warningText) }
            }
            if (this.errorText.length > 0) { Text(this.errorText).fontSize(12).fontColor(this.errorKind.length > 0 ? this.theme.errorText : this.theme.textSecondary).width('100%') }
            if (this.errorKind === 'limit' && this.snapshot !== undefined) {
              Button('生成节选预览').height(44).fontSize(14).fontColor(this.theme.primary).backgroundColor(Color.Transparent)
                .onClick(() => { this.excerpt_(); })
            }
            if (this.errorKind === 'unknown-outcome' && this.advanced) {
              Row({ space: 8 }) {
                Toggle({ type: ToggleType.Checkbox, isOn: this.confirmUnknownRetry }).width(44).height(44)
                  .onChange((checked: boolean): void => { this.confirmUnknownRetry = checked; })
                Text('我了解上次可能已成功，仍要再次发送此快照').fontSize(12).fontColor(this.theme.warningText).layoutWeight(1)
              }.width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 12 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        if (this.phase === 'done') {
          Button(this.shared === undefined ? '完成' : '复制链接').width('100%').height(48)
            .backgroundColor(this.theme.actionPrimary).fontColor(this.theme.textOnPrimary)
            .onClick(() => { if (this.shared === undefined) this.onClosed(); else this.copy_(); })
        } else if (this.errorKind === 'persist') {
          Button('重试保存凭据').width('100%').height(48).onClick(() => { this.retrySave_(); })
        } else if (this.errorKind === 'verification') {
          Button('查看分享记录').width('100%').height(48)
            .onClick(() => { this.onClosed(); this.getUIContext().getRouter().pushUrl({ url: 'pages/LogShareHistoryPage' }); })
        } else if (this.errorKind === 'unknown-outcome') {
          Button(this.advanced && this.confirmUnknownRetry ? '确认再次公开分享' : '关闭并保留本地日志').width('100%').height(48)
            .onClick(() => { if (this.advanced && this.confirmUnknownRetry) this.send_(false); else this.onClosed(); })
        } else if (this.errorKind === 'limit') {
          Button('选择更少的文件').width('100%').height(48).onClick(() => { this.advanced_(); })
        } else {
          Button(this.busy_() ? '处理中…' : this.phase === 'review'
            ? (this.destination === 'author' ? '确认提交作者' : this.requestAi ? '确认公开分享并分析' : this.advanced ? '确认公开分享' : '同意并分享')
            : '预览并继续').width('100%').height(48).backgroundColor(this.theme.actionPrimary).fontColor(this.theme.textOnPrimary)
            .enabled(!this.busy_() && this.draft.selectedFileIds.length > 0
              && (this.destination === 'logshare' || DistributionPolicy.allowPublisherServices()))
            .onClick(() => { if (this.phase === 'review') this.send_(!this.advanced && this.rememberRule); else this.prepare_(false); })
        }
        if (!this.busy_() && this.phase !== 'done') {
          Row() {
            Button(this.advanced ? '返回文件选择' : '自定义与预览').height(44).fontSize(12)
              .backgroundColor(Color.Transparent).fontColor(this.theme.primary).onClick(() => { this.advanced_(); })
            Blank()
            Button('隐私说明').height(44).fontSize(12).backgroundColor(Color.Transparent)
              .fontColor(this.theme.textSecondary).onClick(() => { this.openPolicy_(); })
          }.width('100%')
        }
      }
    }.width('100%').height('100%').padding({ top: 24, left: 20, right: 20, bottom: 16 })
  }

  /** 在同一个 sheet 内切换到有界分页预览，不再改主页面的原始日志状态。 */
  @Builder
  private Preview_() {
    Column({ space: 12 }) {
      Button('返回分享预览').height(44).fontColor(this.theme.primary).backgroundColor(Color.Transparent)
        .onClick(() => { this.previewGeneration++; this.previewModel.cancel(); this.previewName = ''; this.previewFile = undefined; })
      Text(this.previewName).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      if (this.previewReading) { LoadingProgress().width(28).height(28).color(this.theme.primary) }
      if (this.previewError.length > 0) {
        Text(this.previewError).fontSize(12).fontColor(this.theme.errorText).width('100%')
        Button('重试读取').height(44).onClick(() => { if (this.previewFile !== undefined) this.readPreview_(this.previewFile, this.previewPage); })
      }
      List() {
        LazyForEach(this.previewModel, (row: LogRow) => {
          ListItem() {
            Text(String(row.sourceLineNumber ?? row.lineNumber) + '  ' + row.text).fontSize(12).fontFamily('monospace')
              .fontColor(this.theme.textPrimary).width('100%').copyOption(CopyOptions.LocalDevice).padding(4)
          }
        }, (row: LogRow): string => String(row.key))
      }.width('100%').layoutWeight(1).backgroundColor(this.theme.bgCard).borderRadius(12)
        .visibility(this.previewReading || this.previewError.length > 0 ? Visibility.Hidden : Visibility.Visible)
      Row({ space: 12 }) {
        Button('上一页').height(44).enabled(!this.previewReading && this.previewError.length === 0 && this.previewPage > 0)
          .onClick(() => { if (this.previewFile !== undefined) this.readPreview_(this.previewFile, this.previewPage - 1); })
        Text('第 ' + (this.previewPage + 1) + ' 页').fontSize(12).fontColor(this.theme.textSecondary)
        Button('下一页').height(44).enabled(!this.previewReading && this.previewError.length === 0 && this.previewNext)
          .onClick(() => { if (this.previewFile !== undefined) this.readPreview_(this.previewFile, this.previewPage + 1); })
      }.width('100%')
    }.width('100%').layoutWeight(1)
  }
}

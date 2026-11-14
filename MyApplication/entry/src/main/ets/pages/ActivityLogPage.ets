import { applyNativeTheme } from '../components/AppTheme';
import { DeviceForm, Breakpoint } from 'commons';
/**
 * ActivityLogPage.ets — 活动日志查看页（活动账本 · L5）
 *
 * 一条活动（下载 / 模组安装 / 修复 / JDK / 整合包 / 一局游戏）的完整日志查看器。
 *
 * 与旧的「技术详情」弹窗的根本差别：这里看到的是**账本**里按活动归属分流出来的日志，
 * 只含这条活动自己的行；而不是从全局日志按时间窗切出来的近似片段（并发时会掺进
 * 别的活动，还受轮转与尾读上限限制，详见 docs/guides/activity-ledger.md §1.2）。
 *
 * 结构对齐 `DownloadHistoryPage`（同样的顶部栏 / 安全区 / 主题跟随），保持全屏 push
 * 页的一致观感。
 *
 * 关联：docs/guides/activity-ledger.md §5.2
 * 创建日期：2026-07-30
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { AppTitleAction } from '../components/AppTitleAction';
import { promptAction } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { AppIconName, formatDurationMs, AppLogger } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { ActivityLogModel, LogRow, LogSpan, logSpans, LogReadSource } from '../components/ActivityLogModel';
import { flushPendingShareCredentials } from '../components/EvidenceShareService';
import { EvidenceExportSnapshot, EvidenceUploadSelection, createEvidenceExportSnapshot,
  disposeEvidenceExportSnapshot, verifySessionCaptureRotations,
  normalizeEvidenceSelection, snapshotShareFiles } from 'commons';
import { acquireEvidenceLease, releaseEvidenceLease, ledgerRemovalBlockReason } from 'commons';
import { getAiTaskSnapshot, cancelAiAnalysis } from '../components/AiAnalysisService';
import { ActivityAiCard } from '../components/ActivityAiCard';
import { ActivityShareSheet } from '../components/ActivityShareSheet';
import { AnimatedPillBar } from '../components/AnimatedPillBar';
import { MotionSection } from '../components/MotionSection';
import { ActivityViewTabs } from '../components/ActivityViewTabs';
import { ActivityPaneMotion } from '../components/ActivityPaneMotion';
import { UiMotion } from '../components/UiMotion';
import { DeviceProfile, centerSheetForLayout, detailSheetHeightForLayout, sheetWidthForLayout } from 'commons';
import { clearSessionShare } from '../components/McSessionSnapshot';
import {
  LedgerPart, LedgerState, LedgerManifest,
  ledgerManifest, ledgerManifestAsync, ledgerRead, ledgerPartBytes, ledgerExport,
  ledgerRemoveAsync, ledgerListAsync, ledgerRemovalBlockReasonAsync, ledgerPartLabel, ledgerStateLabel, isAbnormalState,
  formatLogBytes, LogExportTarget, sanitizeLogForExport,
  EvidenceFileRecord, EvidenceFileState, EvidenceRole, evidenceRoleLabel,
  listSessionEvidence, evidenceSelectionOf, setEvidenceSelection,
  readSessionEvidence, readSessionEvidenceAsync, refreshSessionEvidence, evidenceSelectionDigest,
  readSessionEvidenceTextAsync, readSessionEvidenceSnapshotAsync,
  GZIP_EVIDENCE_TRUNCATION_MARKER,
} from 'commons';
import { ActivityCategory } from 'feature_core';
import { evidenceReadable, evidenceCaptureLabel, evidenceIntegrityCaption, sortEvidenceForView,
  recommendedEvidenceFile, evidenceDisplayName, SessionEnvironmentFact, readObservedSessionEnvironmentAsync,
  ledgerSetPinnedAsync, ledgerRelatedActivitiesAsync, LedgerRelatedActivity, environmentFactLabel } from 'commons';
import { loadActivityEvidence } from '../components/ActivityEvidenceService';
import { ActivityDiagnosis, ActivityFinding, ActivityPhase, buildActivityDiagnosis } from '../components/ActivityDiagnostics';
import { exportSessionEvidenceZip } from '../components/EvidenceBundleExport';
import {
  revokeShare, LogShareRecord,
  logShareInstanceForUrl,
  logShareSourceLabel, LOGSHARE_AI_UNAVAILABLE,
  LOGSHARE_API_BASE, isShareRecordCurrent, loadShareRecords, loadShareHistory,
} from '../components/LogShareClient';

const TAG = 'ActivityLogPage'
const WORKSPACE_VIEWS: string[] = ['overview', 'logs', 'files']

/** 级别过滤档位。 */
enum LevelFilter {
  ALL = 0,
  /** WARN 及以上。 */
  WARN_UP = 1,
  /** ERROR 及以上。 */
  ERROR_UP = 2,
}

/** 手机路由和平板主从布局共用的工作区，所有证据与外发操作仍使用原有服务。 */
@Component
export struct ActivityLogWorkspace {
  /** 独立活动页也观察同一已确认高度，不保留设置打开前的比例快照。 */
  @StorageProp('phoneSheetHeightPercent') private phoneSheetHeightPercent_: number = 80;
  @Prop activityId: number = 0
  @Prop embedded: boolean = false
  @Prop @Watch('hostVisibilityChanged_') hostVisible: boolean = true
  @Prop initialView: string = 'logs'
  @Prop initialDestination: string = 'logshare'
  @Prop initialShare: boolean = false
  @Prop initialAi: boolean = false
  @Prop initialDiagnosisTitle: string = ''
  @Prop @Watch('onHostRefresh_') refreshNonce: number = 0
  onClosed: () => void = () => {}
  onBusyChanged: (busy: boolean) => void = () => {}
  /** 宿主可折叠活动列表，把完整宽度交给阅读器；离页必须复位。 */
  onFocusChanged: (focused: boolean) => void = () => {}
  /** 本地保留等元信息成功保存后通知宿主刷新列表，避免左右两侧显示不同状态。 */
  onMetadataChanged: () => void = () => {}
  @State @Watch('viewChanged_') private activeView: string = 'logs'
  @State private viewportWidth: number = 0
  @State private manifest: LedgerManifest | null = null
  @State private parts: LedgerPart[] = []
  @State private activePart: LedgerPart = LedgerPart.LAUNCHER
  /** 当前段总字节数。 */
  @State private partBytes: number = 0
  @State private lineCount: number = 0
  @State private matchingLines: number = 0
  @State private matchingEvents: number = 0
  @State private focusedReader: boolean = false
  @State private wrapLines: boolean = true
  @State private readerFontSize: number = 13
  @State private collapseEvents: boolean = true
  @State private eventRevision: number = 0
  @State private showFilePicker: boolean = false
  @State private showUnavailableFiles: boolean = false
  @State private searchAllFiles: boolean = false
  @State private environmentFacts: SessionEnvironmentFact[] = []
  @State private pinned: boolean = false
  /** pin保存与恢复终态共用canonical写门，提交完成前不切换目标活动或重复派发。 */
  @State @Watch('notifyBusy_') private pinSaving_: boolean = false
  @State private confirmingRemoval_: boolean = false
  private pinGeneration_: number = 0
  @State private relatedActivities: LedgerRelatedActivity[] = []
  @State private showRelated: boolean = false
  @State private followLatest: boolean = false
  @State private showingTail: boolean = false
  private followingRead: boolean = false
  private followingLease: boolean = false
  @State private diagnosis: ActivityDiagnosis | undefined = undefined
  @State private diagnosisProgress: string = ''
  @State private diagnosisError: string = ''
  @State private showAllFindings: boolean = false
  @State private showPhaseList: boolean = false
  private diagnosisGeneration: number = 0
  private followTimer: number = -1
  @State private fromLine: number = 0
  @State private reading: boolean = false
  @State private readError: string = ''
  @State private previewLabel: string = ''
  @State private loading: boolean = true
  @State private levelFilter: LevelFilter = LevelFilter.ALL
  @State private keyword: string = ''
  @State private showSearch: boolean = false
  @State @Watch('notifyBusy_') private sharing: boolean = false
  @State private shareError: string = ''
  @State private sharedLog: LogShareRecord | undefined = undefined
  @State private evidenceFiles: EvidenceFileRecord[] = []
  @State private additionalEvidenceFiles: EvidenceFileRecord[] = []
  @State @Watch('shareVisibilityChanged_') private showShareOptions: boolean = false
  @State private shareNonce: number = 0
  @State private shareMode: string = 'advanced'
  @State private showAiResult: boolean = false
  @State private evidenceRevision: number = 1
  @State private evidenceIntegrityState: string = 'unknown'
  @State private evidenceMissingReasons: string[] = []
  @State private viewingEvidence: boolean = false
  @State private activeEvidenceId: string = ''
  @State @Watch('notifyBusy_') private exportingEvidence: boolean = false
  @State private deleting: boolean = false
  @State private copying: boolean = false
  @State private showCaptureDetails: boolean = false
  @State private requestAi: boolean = false
  @State private diagnosisTitle: string = ''
  /** 仅表示本次提交接收成功，不伪装成持久处理进度或作者 AI 回流。 */
  @State private authorSubmissionId: string = ''
  @State private authorDuplicate: boolean = false
  @State private shareDestination: string = 'logshare'
  /** 阅读页异步加载在离页后不得重新开启文件游标；分享生命周期由独立 sheet 负责。 */
  private pageActive: boolean = false
  @State private currentStorageIssue: string = ''

  @State private theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('onColorModeChange') private appThemeRevision: number = 0;

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)
  private scroller: Scroller = new Scroller()
  private model: ActivityLogModel = new ActivityLogModel()
  private evidenceGeneration: number = 0
  private readGeneration: number = 0
  private readSources: LogReadSource[] = []
  @State private pageStart: number = 0
  @State private hasNextPage: boolean = false
  private searchTimer: number = -1

  /** 概览只显示事实与诊断，切到日志时才加载正文；文件选择不会改变分享选择。 */
  private viewChanged_(): void {
    if (this.pageActive && !this.loading && this.activeView === 'logs' && this.readSources.length > 0) {
      this.loadCurrentPage_(this.pageStart)
    }
    if (this.activeView !== 'logs') this.stopFollowing_()
    if (this.activeView === 'overview' && this.pageActive && !this.loading && this.evidenceFiles.length > 0) this.loadDiagnosis_()
  }

  /** 路由隐藏不一定销毁组件；显式停止跟随/读取与索引，避免后台页面长期持有文件租约。 */
  private hostVisibilityChanged_(): void {
    this.pageActive = this.hostVisible
    if (!this.hostVisible) {
      this.pinGeneration_++; this.pinSaving_ = false
      this.stopFollowing_(); this.model.cancel(); this.readGeneration++; this.evidenceGeneration++; this.diagnosisGeneration++
      this.reading = false; this.diagnosisProgress = ''
    }
  }

  /** 本地索引与 AI 独立，只读取本局证据；页面离开/换活动后拒绝迟到结果。 */
  private async loadDiagnosis_(): Promise<void> {
    const manifest: LedgerManifest | null = this.manifest
    if (manifest === null || this.diagnosisProgress.length > 0) return
    const generation: number = ++this.diagnosisGeneration
    this.diagnosisProgress = '正在整理本地证据…'; this.diagnosisError = ''
    try {
      const result = await buildActivityDiagnosis(this.context.filesDir, manifest, this.evidenceFiles,
        (): boolean => !this.pageActive || generation !== this.diagnosisGeneration,
        (done: number, total: number): void => {
          if (this.pageActive && generation === this.diagnosisGeneration) this.diagnosisProgress = '已扫描 ' + done + ' / ' + total + ' 份诊断日志'
        })
      if (this.pageActive && generation === this.diagnosisGeneration) this.diagnosis = result
    } catch (e) { if (this.pageActive && generation === this.diagnosisGeneration) this.diagnosisError = (e as Error).message }
    finally { if (generation === this.diagnosisGeneration) this.diagnosisProgress = '' }
  }

  /** 问题与阶段都携带原文件行号，定位时清除搜索条件并展示前文。 */
  private openEvidenceAt_(fileId: string, line: number): void {
    this.stopFollowing_()
    const file = this.evidenceFiles.find((item: EvidenceFileRecord): boolean => item.fileId === fileId)
    if (file === undefined || !evidenceReadable(file)) { this.toast_('原文件当前不可读，请刷新活动'); return }
    this.resetReaderFilter_(Math.max(1, line - 12))
    this.activeView = 'logs'; this.switchEvidence_(file)
  }

  /** 有本地线索时直接定位其上下文，没有时使用已推荐的实际文件。 */
  private openRelevantLog_(): void {
    const finding: ActivityFinding | undefined = this.diagnosis?.findings[0]
    if (finding !== undefined) this.openEvidenceAt_(finding.fileId, finding.line)
    else this.activeView = 'logs'
  }

  private focusReader_(): void {
    this.focusedReader = !this.focusedReader
    this.onFocusChanged(this.focusedReader)
  }

  /** 全会话搜索仍按文件展示，保留每个来源的行号；不制造不同线程的全局时间顺序。 */
  private searchScope_(): void {
    this.stopFollowing_()
    this.searchAllFiles = !this.searchAllFiles
    const files: EvidenceFileRecord[] = this.searchAllFiles ? this.evidenceFiles.filter(evidenceReadable)
      : this.evidenceFiles.filter((file: EvidenceFileRecord): boolean => file.fileId === this.activeEvidenceId && evidenceReadable(file))
    this.readSources = files.map((file: EvidenceFileRecord): LogReadSource => { return { path: file.localPath, compressed: file.path.endsWith('.gz') } })
    this.partBytes = files.reduce((sum: number, file: EvidenceFileRecord): number => sum + file.bytes, 0)
    this.fromLine = 0; this.loadCurrentPage_(0)
  }

  private stopFollowing_(): void {
    if (this.followLatest) { this.readGeneration++; this.model.cancel() }
    this.followLatest = false
    if (this.followTimer >= 0) clearTimeout(this.followTimer)
    this.followTimer = -1
    if (this.followingLease) { releaseEvidenceLease(this.context.filesDir, this.activityId); this.followingLease = false }
  }

  /** 用户主动跟随单个本局文件；首次扫描获取行号，后续使用保留的游标只读新增字节。 */
  private toggleFollow_(): void {
    if (this.followLatest) { this.stopFollowing_(); return }
    if (ledgerManifest(this.context.filesDir, this.activityId)?.state !== LedgerState.RUNNING) {
      this.toast_('本次活动已结束，可使用分页和搜索查看完整记录'); return
    }
    if (this.readSources.length !== 1 || this.readSources[0].compressed) {
      this.toast_('请选择一份正在记录的非压缩日志'); return
    }
    this.keyword = ''; this.levelFilter = LevelFilter.ALL; this.fromLine = 0
    this.followLatest = true
    acquireEvidenceLease(this.context.filesDir, this.activityId); this.followingLease = true
    this.followTick_()
  }

  private async followTick_(): Promise<void> {
    if (!this.pageActive || !this.followLatest || this.readSources.length !== 1) return
    if (this.followingRead || this.reading) { this.followTimer = setTimeout(() => { this.followTick_() }, 1000); return }
    const generation: number = ++this.readGeneration
    this.followingRead = true
    if (!this.showingTail) this.reading = true
    try {
      const completed: boolean = await this.model.loadLive(this.readSources[0], this.levelFilter, this.keyword)
      if (!completed || !this.pageActive || !this.followLatest || generation !== this.readGeneration) return
      this.showingTail = true; this.matchingLines = this.model.matchingLines; this.matchingEvents = this.model.matchingEvents
      this.lineCount = this.model.lineCount; this.hasNextPage = false; this.pageStart = 0
      this.readError = ''; this.reading = false
      try { this.scroller.scrollEdge(Edge.Bottom) } catch (e) { /* 列表仍在挂载。 */ }
      const manifest = ledgerManifest(this.context.filesDir, this.activityId)
      if (manifest !== null && manifest.state !== LedgerState.RUNNING) { this.manifest = manifest; this.stopFollowing_() }
    } catch (e) { if (this.pageActive && generation === this.readGeneration) { this.readError = (e as Error).message; this.stopFollowing_() } }
    finally {
      this.followingRead = false
      if (generation === this.readGeneration || !this.followLatest) this.reading = false
      if (this.pageActive && this.followLatest) this.followTimer = setTimeout(() => { this.followTick_() }, 1000)
    }
  }

  /** 原件上的操作不走系统直接复制，整条事件先脱敏再等待剪贴板完成。 */
  private async copyEvent_(row: LogRow): Promise<void> {
    const event = row.event
    if (event === undefined || this.copying) return
    this.copying = true
    try {
      const raw: string = this.sourceLabel_(row) + ':' + event.startLine + '-' + event.endLine + '\n'
        + event.lines.map((line): string => line.text).join('\n')
      const text: string = sanitizeLogForExport(raw, LogExportTarget.CLIPBOARD)
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
      this.toast_(text.indexOf('省略') >= 0 || text.indexOf('截断') >= 0 ? '事件过长，已复制带省略说明的脱敏文本' : '已复制完整事件（脱敏）')
    } catch (e) { this.toast_('复制失败：' + (e as Error).message) }
    finally { this.copying = false }
  }

  /** ZIP 是本地导出，不必先进入分享流程；使用相同冻结/脱敏管线并保护异步生命周期。 */
  private async exportZip_(): Promise<void> {
    if (this.exportingEvidence || this.sharing || this.copying) return
    this.exportingEvidence = true
    try {
      const result = await exportSessionEvidenceZip(this.context, this.activityId, this.publicSummary_())
      if (this.pageActive && !result.cancelled) this.toast_(result.ok ? '完整日志包已导出' : result.message)
    } catch (e) { if (this.pageActive) this.toast_('导出失败：' + (e as Error).message) }
    finally { this.exportingEvidence = false }
  }

  /** 保留只影响本地清理；await owner耐久提交成功后才更新当前活动，离页旧回调不发布。 */
  private async togglePinned_(): Promise<void> {
    if (this.pinSaving_ || !this.pageActive || this.sharing || this.exportingEvidence) return
    const generation: number = ++this.pinGeneration_
    const activityId: number = this.activityId
    const pinned: boolean = !this.pinned
    this.pinSaving_ = true
    try {
      await ledgerSetPinnedAsync(this.context.filesDir, activityId, pinned)
      if (!this.pageActive || generation !== this.pinGeneration_ || activityId !== this.activityId) return
      this.pinned = pinned
      // 先释放选中活动的UI忙态，再通知宿主刷新，避免宿主按“正在保存”拒绝这次真实更新。
      this.pinSaving_ = false
      this.notifyBusy_()
      this.onMetadataChanged()
      this.toast_(this.pinned ? '已保留，不会自动清理' : '已取消保留，将遵循日志保留设置')
    } catch (e) {
      if (this.pageActive && generation === this.pinGeneration_ && activityId === this.activityId) this.toast_('设置失败：' + (e as Error).message)
    } finally { if (generation === this.pinGeneration_) this.pinSaving_ = false }
  }

  /** 仅初始化当前活动，不自动公开日志或启动 AI。嵌入式实例由活动主键重建。 */
  aboutToAppear(): void {
    this.pageActive = true
    this.applyTheme_()
    this.activeView = this.initialView === 'share' ? 'overview' : this.initialView
    this.shareDestination = this.initialDestination
    // 旧版本可能携带 initialAi=true；服务下线后只打开原有分享/阅读页面，不继承发起资格。
    this.requestAi = false
    this.diagnosisTitle = this.initialDiagnosisTitle
    this.showShareOptions = this.initialShare || this.initialView === 'share'
    this.load_()
    this.loadShare_()
  }

  /** 平板发送/导出期间锁住左侧选择，避免异步结果被显示到另一活动。 */
  private notifyBusy_(): void { this.onBusyChanged(this.sharing || this.exportingEvidence || this.pinSaving_) }

  /** 每次明确打开都创建新的 UI 会话，不让系统 sheet 缓存复用上次已关闭的 alive/阶段值。 */
  private shareVisibilityChanged_(): void { if (this.showShareOptions) this.shareNonce++ }

  /** 分享入口统一打开选择层。复用已冻结但未发送的预览，已发送链接仍留在记录页。 */
  private openShareComposer_(): void {
    if (this.loading || this.sharing || this.exportingEvidence) return
    this.shareMode = 'quick'; this.shareDestination = 'logshare'; this.requestAi = false
    this.showShareOptions = true
  }

  /** 原生 sheet 保留拖拽/遮罩/返回动效；手机底部展开，平板使用限宽居中形态。 */
  private shareSheetOptions_(): SheetOptions {
    const form = DeviceProfile.form()
    const breakpoint = DeviceProfile.breakpointOf(this.viewportWidth + (this.embedded ? 424 : 40))
    const center: boolean = centerSheetForLayout(form, breakpoint)
    const height: number = detailSheetHeightForLayout(form, breakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_)
    return { height: form !== DeviceForm.PHONE && this.shareMode === 'quick' ? Math.min(height, 440) : height,
      width: sheetWidthForLayout(form, breakpoint), preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
      // 分享正文已提供统一 X；保留 onDisappear，系统 Back/拖拽关闭仍走原收口。
      showClose: false, dragBar: !center, backgroundColor: this.theme.bgPrimary,
      onDisappear: (): void => { this.showShareOptions = false } }
  }

  /** 只读 AI 历史阅读层；关闭不触发分享、分析或通知权限请求。 */
  private aiSheetOptions_(): SheetOptions {
    return { height: DeviceProfile.form() === DeviceForm.PHONE
      ? detailSheetHeightForLayout(DeviceForm.PHONE, Breakpoint.SM, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_)
      : '88%', preferType: SheetType.BOTTOM, showClose: false, dragBar: true,
      backgroundColor: this.theme.bgPrimary,
      onDisappear: (): void => { this.showAiResult = false } }
  }

  /** 低频操作收进明确命名的菜单，手机标题栏不并排挤四个图标；删除仍走二次确认。 */
  private moreActions_(): void {
    if (this.sharing || this.exportingEvidence || this.pinSaving_ || this.loading) return
    try {
      this.getUIContext().getPromptAction().showActionMenu({ title: '活动日志操作', buttons: [
        { text: '复制全部脱敏证据', color: this.theme.actionText as string },
        { text: '分享记录与撤回', color: this.theme.actionText as string },
        { text: '删除本地活动日志', color: this.theme.errorText as string },
        { text: '自定义分享与预览', color: this.theme.actionText as string },
        { text: '导出完整日志包（脱敏 ZIP）', color: this.theme.actionText as string },
        { text: this.pinned ? '取消保留此活动' : '保留此活动，防止自动清理', color: this.theme.actionText as string },
      ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
        if (result.index === 0) this.copyAll_()
        else if (result.index === 1) this.getUIContext().getRouter().pushUrl({ url: 'pages/LogShareHistoryPage' })
        else if (result.index === 2) {
          if (this.canDelete_()) this.requestRemoveLedger_()
          else this.toast_(ledgerRemovalBlockReason(this.context.filesDir, this.activityId) || '正在读取或导出，请稍后删除')
        } else if (result.index === 3) { this.shareMode = 'advanced'; this.requestAi = false; this.showShareOptions = true }
        else if (result.index === 4) this.exportZip_()
        else if (result.index === 5) this.togglePinned_()
      }).catch((): void => {})
    } catch (e) { this.toast_('暂时无法打开操作菜单') }
  }

  /** 关闭嵌入详情只通知宿主，不误退整个活动账本路由。 */
  private close_(): void {
    if (this.embedded) this.onClosed()
    else this.getUIContext().getRouter().back()
  }

  /** 遗留回调的本地终点；服务下线不能为了分析而引导一次新的公开上传。 */
  private async requestAnalysis_(): Promise<void> {
    this.requestAi = false
    this.toast_(LOGSHARE_AI_UNAVAILABLE)
  }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark), this.prefManager.themeAccent)
    applyNativeTheme(this.theme);
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  /** 首屏先发布轻量事实，再异步校验文件；离页/刷新世代变化后丢弃迟到结果。 */
  private async load_(preserveReader: boolean = false): Promise<void> {
    const generation: number = ++this.evidenceGeneration
    this.currentStorageIssue = AppLogger.storageIssue()
    if (this.activityId <= 0) { this.loading = false; return }
    const dir: string = this.context.filesDir
    try {
      // 首屏元数据也必须真正异步；每个await后撤销旧代次，不能把上一活动的环境/清单写入新详情。
      const manifest = await ledgerManifestAsync(dir, this.activityId)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      const environment = await readObservedSessionEnvironmentAsync(dir, this.activityId)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      const previous = await readSessionEvidenceAsync(dir, this.activityId)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      this.manifest = manifest
      this.pinned = this.manifest?.pinned === true
      this.environmentFacts = environment.facts
      // 关联导航不是首帧必须的文件读取；按同一规则异步读取manifest，避免在首次
      // layout回调扫描全部账本。离页、刷新或更换活动后旧结果不得覆盖当前工作区。
      ledgerRelatedActivitiesAsync(dir, this.activityId,
        (): boolean => !this.pageActive || generation !== this.evidenceGeneration).then((values: LedgerRelatedActivity[]): void => {
        if (this.pageActive && generation === this.evidenceGeneration) this.relatedActivities = values
      }).catch((error: Error): void => {
        if (this.pageActive && generation === this.evidenceGeneration) {
          AppLogger.warn(TAG, 'Related activity metadata unavailable; original evidence retained', error)
        }
      })
      this.evidenceFiles = sortEvidenceForView(previous?.files ?? [])
      this.updateParts_()
      this.evidenceRevision = previous?.revision ?? 1
      this.evidenceIntegrityState = 'unknown'
      this.evidenceMissingReasons = previous?.missingReasons ?? []
      this.loading = false
      this.reading = this.activeView === 'logs'
      await verifySessionCaptureRotations(dir, this.activityId)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      const files: EvidenceFileRecord[] = await loadActivityEvidence(dir, this.activityId,
        (): boolean => !this.pageActive || generation !== this.evidenceGeneration)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      this.evidenceFiles = sortEvidenceForView(files)
      this.updateParts_()
      const issues: string[] = files.filter((file: EvidenceFileRecord): boolean => file.state === EvidenceFileState.PARTIAL)
        .map((file: EvidenceFileRecord): string => file.path + '：' + file.reason)
      this.evidenceMissingReasons = Array.from(new Set<string>(this.evidenceMissingReasons.concat(issues)))
      this.evidenceIntegrityState = issues.length > 0 ? 'partial' : previous?.integrityState ?? 'unknown'
      const selected = preserveReader ? files.find((file: EvidenceFileRecord): boolean =>
        file.fileId === this.activeEvidenceId && evidenceReadable(file)) : undefined
      const preferred = selected ?? recommendedEvidenceFile(files)
      this.model.setCollapsed(this.collapseEvents)
      if (preferred !== undefined) await this.switchEvidence_(preferred, preserveReader ? this.pageStart : 0)
      else { this.readSources = []; await this.loadCurrentPage_(0) }
      if (this.activeView === 'overview') this.loadDiagnosis_()
    } catch (e) {
      if (this.pageActive && generation === this.evidenceGeneration) {
        this.loading = false; this.reading = false; this.readError = '日志核验未完成：' + (e as Error).message
        this.evidenceIntegrityState = 'unknown'
      }
    }
  }

  /** 兼容分段与正文共用已读证据集合，不另走同步路径/旧日志反查重复探测文件。 */
  private updateParts_(): void {
    const all: LedgerPart[] = [LedgerPart.LAUNCHER, LedgerPart.GAME, LedgerPart.MC_LATEST,
      LedgerPart.JVM, LedgerPart.CRASH_REPORT, LedgerPart.SYSTEM_CRASH]
    this.parts = all.filter((part: LedgerPart): boolean => this.partFiles_(part).length > 0)
  }

  aboutToDisappear(): void {
    this.pageActive = false
    this.pinGeneration_++; this.pinSaving_ = false
    this.evidenceGeneration++
    this.diagnosisGeneration++
    this.stopFollowing_()
    this.readGeneration++
    this.model.cancel()
    this.reading = false
    this.onBusyChanged(false)
    this.onFocusChanged(false)
    if (this.followTimer >= 0) clearTimeout(this.followTimer)
    this.followTimer = -1
    if (this.searchTimer >= 0) clearTimeout(this.searchTimer)
  }

  /** 返回页面时重新绑定原件，避免继续读取离页时已经清理的预览临时文件。 */
  private onHostRefresh_(): void {
    if (!this.loading && this.activityId > 0 && !this.sharing && !this.exportingEvidence) {
      this.sharedLog = undefined
      this.load_(true)
      this.loadShare_()
    }
  }

  /** 标签、体积和正文共用同一文件集合，兼容分类不再维护第二份路径/大小判断。 */
  private partFiles_(part: LedgerPart): EvidenceFileRecord[] {
    const roles: EvidenceRole[] = part === LedgerPart.LAUNCHER ? [EvidenceRole.LAUNCHER]
      : part === LedgerPart.GAME ? [EvidenceRole.MINECRAFT_OUTPUT]
      : part === LedgerPart.MC_LATEST ? [EvidenceRole.MINECRAFT_MAIN]
      : part === LedgerPart.JVM ? [EvidenceRole.JVM_STDERR, EvidenceRole.JVM_FATAL, EvidenceRole.JVM_GC]
      : part === LedgerPart.CRASH_REPORT ? [EvidenceRole.CRASH_REPORT]
      : [EvidenceRole.SYSTEM_CRASH, EvidenceRole.SYSTEM_TRACE]
    return this.evidenceFiles.filter((file: EvidenceFileRecord): boolean =>
      roles.indexOf(file.role) >= 0 && this.readableFile_(file))
  }

  private partBytes_(part: LedgerPart): number {
    return this.partFiles_(part).reduce((total: number, file: EvidenceFileRecord): number => total + file.bytes, 0)
  }

  /** 统一按文件流分页，旧账本分段只负责选择对应来源集合。 */
  private async loadPart_(part: LedgerPart, skip: number = 0): Promise<void> {
    this.previewLabel = ''
    this.viewingEvidence = false
    this.activeEvidenceId = ''
    const files: EvidenceFileRecord[] = this.partFiles_(part)
    // 大小与实际阅读集合来自同一清单，JVM fatal/GC 等附属文件不再漏算。
    this.partBytes = files.reduce((total: number, file: EvidenceFileRecord): number => total + file.bytes, 0)
    this.readSources = files
      .map((file: EvidenceFileRecord): LogReadSource => { return { path: file.localPath, compressed: file.path.endsWith('.gz') } })
    await this.loadCurrentPage_(skip)
  }

  private async loadCurrentPage_(skip: number): Promise<void> {
    this.stopFollowing_(); this.showingTail = false
    const generation = ++this.readGeneration
    this.reading = true
    this.readError = ''
    acquireEvidenceLease(this.context.filesDir, this.activityId)
    try {
      const completed = await this.model.loadEvidence(this.readSources.slice(), this.levelFilter, this.keyword.trim(), skip, this.fromLine)
      if (!completed || generation !== this.readGeneration) return
      // 文件缩短或筛选结果变化使原页消失时回到首个有效页，避免呈现假的空文件。
      if (skip > 0 && this.model.matchingLines === 0) { await this.loadCurrentPage_(0); return }
      this.lineCount = this.model.lineCount
      this.matchingLines = this.model.matchingLines
      this.matchingEvents = this.model.matchingEvents
      this.pageStart = this.model.pageStart
      this.hasNextPage = this.model.hasNextPage
      try { this.scroller.scrollEdge(Edge.Top) } catch (e) { /* 尚未挂载 */ }
    } catch (e) {
      if (generation === this.readGeneration) this.readError = '日志读取失败：' + (e as Error).message
    } finally {
      releaseEvidenceLease(this.context.filesDir, this.activityId)
      if (generation === this.readGeneration) this.reading = false
    }
  }

  private switchPart_(part: LedgerPart): void {
    if (this.activePart === part && !this.viewingEvidence) return
    this.activePart = part
    this.keyword = ''
    this.levelFilter = LevelFilter.ALL
    this.loadPart_(part)
  }

  private async switchEvidence_(file: EvidenceFileRecord, skip: number = 0): Promise<void> {
    if (file.state === EvidenceFileState.MISSING || file.state === EvidenceFileState.CLEANED
      || file.state === EvidenceFileState.NOT_PRODUCED || file.state === EvidenceFileState.NOT_APPLICABLE
      || file.state === EvidenceFileState.UNAVAILABLE) return
    this.searchAllFiles = false
    this.viewingEvidence = true
    this.previewLabel = ''
    this.activeEvidenceId = file.fileId
    this.partBytes = file.bytes
    this.showFilePicker = false
    this.readSources = [{ path: file.localPath, compressed: file.path.endsWith('.gz') }]
    if (this.activeView === 'logs') await this.loadCurrentPage_(skip)
  }

  private isLegacyEvidence_(file: EvidenceFileRecord): boolean {
    return file.path === 'launcher/launcher-host.log'
      || file.path === 'launcher/launcher-tail.log'
      || file.path === 'launcher/launcher-tail.1.log'
      || file.path === 'game/mc_output.log'
      || file.path === 'game/logs/latest.log'
      || file.path === 'jvm/jvm-stderr.log'
      || file.path === 'crash-reports/crash-report.txt'
      || file.path === 'system/crash-tail.log'
  }

  private activeEvidenceLabel_(): string {
    if (this.previewLabel.length > 0) return '脱敏预览 · ' + this.previewLabel
    for (const file of this.evidenceFiles) {
      if (file.fileId === this.activeEvidenceId) return evidenceRoleLabel(file.role) + ' · ' + file.path
    }
    return '证据文件'
  }

  private evidenceStateLabel_(state: EvidenceFileState): string {
    if (state === EvidenceFileState.AVAILABLE) return '已保存'
    if (state === EvidenceFileState.COMPLETE) return '完整'
    if (state === EvidenceFileState.WRITING) return '写入中'
    if (state === EvidenceFileState.PARTIAL) return '部分缺失'
    if (state === EvidenceFileState.MISSING) return '缺失'
    if (state === EvidenceFileState.NOT_PRODUCED) return '未产生'
    if (state === EvidenceFileState.NOT_APPLICABLE) return '不适用'
    if (state === EvidenceFileState.UNAVAILABLE) return '不可用'
    if (state === EvidenceFileState.CLEANED) return '已清理'
    return '未知'
  }

  private evidenceIntegrityLabel_(): string {
    return evidenceIntegrityCaption(this.evidenceIntegrityState, this.evidenceMissingReasons, this.manifest?.state === LedgerState.RUNNING)
  }

  /** 来源占位项用于说明未产生/不可用；只有实际可读文件参与查看和文件数展示。 */
  private readableFile_(file: EvidenceFileRecord): boolean {
    return evidenceReadable(file)
  }

  /** UI 忙态与账本保护共同决定可删除性；对话框确认后再次调用，避免确认期间状态改变。 */
  private canDelete_(): boolean {
    return !this.loading && !this.reading && !this.sharing && !this.copying && !this.exportingEvidence && !this.pinSaving_
      && !this.deleting && !this.confirmingRemoval_ && this.activityId > 0
      && ledgerRemovalBlockReason(this.context.filesDir, this.activityId).length === 0
  }

  private savedEvidenceCount_(): number {
    let count: number = 0
    for (const file of this.evidenceFiles) {
      if (this.readableFile_(file)) count++
    }
    return count
  }

  private applyFilter_(): void { this.fromLine = 0; this.loadCurrentPage_(0) }

  private search_(value: string): void {
    // ArkUI 在 text 属性被程序清空时也可能回调 onChange；同值回调不代表新的用户搜索，
    // 否则会在“查看上下文”后把 fromLine 又归零。定时器与显式定位也必须互相取消。
    if (value === this.keyword) return
    this.keyword = value
    if (this.searchTimer >= 0) clearTimeout(this.searchTimer)
    this.searchTimer = setTimeout(() => { this.searchTimer = -1; this.applyFilter_() }, 180)
  }

  private resetReaderFilter_(line: number = 0): void {
    if (this.searchTimer >= 0) clearTimeout(this.searchTimer)
    this.searchTimer = -1
    this.keyword = ''; this.levelFilter = LevelFilter.ALL; this.fromLine = line
  }

  private jumpToFirstError_(): void {
    this.keyword = ''
    this.levelFilter = LevelFilter.ERROR_UP
    this.loadCurrentPage_(0)
  }

  private spans_(row: LogRow): LogSpan[] { return logSpans(row, this.keyword.trim()) }

  /** 文件边界显示原文件名，行号来自该文件而非合并后重编号。 */
  private sourceLabel_(row: LogRow): string {
    const path: string = row.sourcePath ?? ''
    return path.substring(path.lastIndexOf('/') + 1)
  }

  // ---- 操作 ----

  private async loadShare_(): Promise<void> {
    // 已有链接是分享时快照；是否等于当前文件，仍由冻结后的内容摘要核验。
    try {
      await flushPendingShareCredentials(this.context)
      const history = await loadShareHistory(this.context)
      if (!this.pageActive) return
      this.sharedLog = history.records.find((record: LogShareRecord): boolean => record.activityId === this.activityId
        && record.accepted !== false && isShareRecordCurrent(record))
      if (history.warnings.length > 0) this.shareError = history.warnings.join('；')
    }
    catch (e) { this.shareError = (e as Error).message }
  }

  /** 复制现有链接不再复用上传方法，失败不会触发网络发送。 */
  private async copySharedLink_(): Promise<void> {
    const record = this.sharedLog
    if (record === undefined) return
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, record.url))
      this.toast_('链接已复制')
    } catch (e) { this.shareError = '复制失败，链接仍已保存在分享记录中' }
  }

  private publicSummary_(): string {
    const m = this.manifest
    let s = 'AMCL_PUBLIC_SESSION_SUMMARY_V1\n'
    s += 'activityId=' + this.activityId + '\n'
    s += 'category=' + (m?.category ?? '') + '\n'
    s += 'title=' + (m?.title ?? '') + '\n'
    s += 'gameVersion=' + (m?.gameVersionId ?? '') + '\n'
    s += 'loader=' + (m?.loaderType ?? '') + ' ' + (m?.loaderVersion ?? '') + '\n'
    s += 'jdk=' + (m?.jdk ?? '') + '\n'
    s += 'outcome=' + (m !== null && m !== undefined ? ledgerStateLabel(m.state) : 'unknown') + '\n'
    s += 'startedAt=' + (m?.startedAt ?? this.activityId) + '\n'
    s += 'endedAt=' + (m?.endedAt ?? 0) + '\n'
    s += 'evidenceRevision=' + this.evidenceRevision + '\n'
    return s
  }

  /** 快捷和高级分享统一复用同一组件，阅读页不再复制上传状态机。 */
  @Builder
  ShareSelection_() {
    Column() {
    ForEach([this.shareNonce], (nonce: number) => {
      ActivityShareSheet({ activityId: this.activityId, initialMode: this.shareMode,
      initialDestination: this.shareDestination, initialAi: this.requestAi, theme: this.theme,
      onClosed: (): void => { this.showShareOptions = false },
      onAdvancedChanged: (advanced: boolean): void => { if (advanced) this.shareMode = 'advanced' },
      onBusyChanged: (busy: boolean): void => { this.sharing = busy },
      onShared: (record: LogShareRecord): void => { this.sharedLog = record; this.activeView = 'overview' },
      onAuthorAccepted: (id: string, duplicate: boolean): void => {
        this.authorSubmissionId = id; this.authorDuplicate = duplicate; this.activeView = 'overview'
      } })
    }, (nonce: number): string => String(nonce))
    }.width('100%').height('100%')
  }

  private async revoke_(): Promise<void> {
    const rec = this.sharedLog
    if (this.sharing || rec === undefined) return
    this.sharing = true
    this.shareError = ''
    try {
      const result = await revokeShare(this.context, rec)
      if (result.ok) {
        if (getAiTaskSnapshot(this.activityId).shareId === rec.id) cancelAiAnalysis(this.activityId)
        this.sharedLog = undefined
        await clearSessionShare(this.activityId, rec.id)
        this.toast_('分享已撤回')
      }
      else { this.shareError = result.error; this.toast_(result.error) }
    } catch (e) {
      this.shareError = (e as Error).message
      this.toast_((e as Error).message)
    } finally {
      this.sharing = false
    }
  }

  /** 在线撤回单独确认，不把删除远端链接混同于清理本地原件。取消不产生请求。 */
  private confirmRevoke_(): void {
    if (this.sharing || this.sharedLog === undefined) return
    this.getUIContext().getPromptAction().showDialog({ title: '撤回这条在线分享？',
      message: '撤回后链接将无法访问。本地活动日志仍然保留。',
      buttons: [{ text: '取消', color: this.theme.actionText as string }, { text: '撤回分享', color: this.theme.errorText as string }],
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) this.revoke_()
    }).catch((): void => {})
  }

  /** 概览只呈现本次接收结果，选文件/脱敏/确认/ZIP 全部集中到分享 sheet。 */
  @Builder
  private ShareReceipt_() {
    Column({ space: 12 }) {
      if (this.authorSubmissionId.length > 0) {
        Row({ space: 10 }) {
          AppIcon({ name: AppIconName.Document, iconSize: 20, color: this.theme.successText })
          Column({ space: 4 }) {
            Text(this.authorDuplicate ? '作者端已有这份日志' : '作者端已接收')
              .fontSize(14).fontWeight(600).fontColor(this.theme.successText)
            Text('接收编号：' + this.authorSubmissionId).fontSize(12).fontColor(this.theme.textSecondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        Text('不生成公开链接；作者后台分析或人工处理不会回传到此处。')
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      }
      if (this.sharedLog !== undefined) {
        Text('已有公开链接 · 分享时快照').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
        Text(this.shareSourceText_()).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
        Row({ space: 8 }) {
          Button('复制链接').height(44).layoutWeight(1).fontSize(14)
            .fontColor(this.theme.actionText).backgroundColor(this.theme.primaryLight)
            .enabled(!this.sharing).onClick(() => { this.copySharedLink_() })
        }.width('100%')
      }
    }.width('100%').padding(16).borderRadius(12).backgroundColor(this.theme.bgInput)
      .alignItems(HorizontalAlign.Start)
  }

  /** 手机历史阅读层独立滚动；列表与概览始终只渲染本地报告短摘要。 */
  @Builder
  private AiReadingSheet_() {
    Column() {
    // X 仅收起历史阅读层，不在关闭时开始新的分享或分析。
    ImmersiveTitleScaffold({ title: '历史 AI 报告',
      modal: true, theme: this.theme, surfaceColor: this.theme.bgPrimary, closeLabel: '关闭历史 AI 报告',
      onClose: (): void => { this.showAiResult = false; },
      content: (): void => { this.ImmersiveTitleContent1_(); }
    })
    }.width('100%').height('100%')
  }

  private shareSourceText_(): string {
    const record = this.sharedLog
    if (record === undefined) return ''
    const retention = record.storageTimeSec !== undefined && record.storageTimeSec > 0
      ? ' · 保留期约 ' + Math.ceil(record.storageTimeSec / 86400) + ' 天' : ' · 有效期以分享页为准'
    return logShareSourceLabel(record.url) + retention
  }

  private toast_(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 })
    } catch (e) { /* ignore */ }
  }

  /** 复制整条账本（含环境头与全部分段），统一过脱敏出口。 */
  private async copyAll_(): Promise<void> {
    if (this.copying || this.sharing || this.deleting || this.exportingEvidence) return
    this.copying = true
    let snapshot: EvidenceExportSnapshot | undefined = undefined
    try {
      const ids = normalizeEvidenceSelection(this.evidenceFiles, this.evidenceFiles.map((file: EvidenceFileRecord): string => file.fileId))
      const selection: EvidenceUploadSelection = { activityId: this.activityId, revision: this.evidenceRevision,
        selectedFileIds: ids, createdAt: Date.now(), includePublicSummary: true }
      snapshot = await createEvidenceExportSnapshot(this.context.filesDir, this.context.tempDir, selection, this.publicSummary_())
      const files = await snapshotShareFiles(snapshot, 1024 * 1024, Number.MAX_SAFE_INTEGER)
      const text: string = files.map((file): string => '\n===== ' + file.name + ' =====\n' + file.content).join('')
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
      this.toast_('已复制全部脱敏证据')
    } catch (e) {
      this.toast_('复制未完成，可改用完整 ZIP 导出：' + (e as Error).message)
    } finally {
      if (snapshot !== undefined) disposeEvidenceExportSnapshot(snapshot)
      this.copying = false
    }
  }

  /** 展示标题、占用和影响边界；关闭/取消确认框都不删除数据。 */
  private async requestRemoveLedger_(): Promise<void> {
    if (!this.canDelete_()) return
    const activityId: number = this.activityId
    const generation: number = this.pinGeneration_
    const cancelled: () => boolean = (): boolean => !this.pageActive || generation !== this.pinGeneration_ || activityId !== this.activityId
    this.confirmingRemoval_ = true
    let accepted: boolean = false
    try {
      const reason: string = await ledgerRemovalBlockReasonAsync(this.context.filesDir, activityId)
      if (cancelled()) return
      if (reason.length > 0) { this.toast_(reason); return }
      const entry = (await ledgerListAsync(this.context.filesDir, cancelled)).find((value): boolean => value.activityId === activityId)
      if (cancelled()) return
      const title: string = this.manifest?.title ?? '这条活动'
      const message: string = '将删除“' + title + '”的本地日志和证据清单。\n'
        + '状态：' + (this.manifest === null ? '未知' : ledgerStateLabel(this.manifest.state))
        + ' · 占用 ' + (entry?.bytesState === 'current' ? formatLogBytes(entry.bytes) : '暂不可读') + '\n\n'
        + '在线分享仍会保留；清理后可在“日志分享记录”中查看链接或单独撤回。'
      const result: promptAction.ShowDialogSuccessResponse | undefined = await this.getUIContext().getPromptAction().showDialog({
        title: '删除本地活动日志？',
        message: message,
        buttons: [
          { text: '取消', color: this.theme.actionText as string },
          { text: '删除本地日志', color: this.theme.errorText as string },
        ],
      }).catch((): undefined => undefined)
      accepted = result?.index === 1
    } catch (e) {
      if (!cancelled()) this.shareError = '无法核实或确认清理：' + (e as Error).message
    } finally { this.confirmingRemoval_ = false }
    if (accepted && !cancelled()) await this.removeLedger_()
  }

  /** 已确认删除真正等待异步owner；成功/失败只发布给仍存活的同一活动，忙态拒绝重复操作。 */
  private async removeLedger_(): Promise<void> {
    if (!this.canDelete_()) return
    const activityId: number = this.activityId
    const generation: number = this.pinGeneration_
    this.deleting = true
    try {
      await ledgerRemoveAsync(this.context.filesDir, activityId)
      if (!this.pageActive || generation !== this.pinGeneration_ || activityId !== this.activityId) return
      this.toast_('已删除本条日志')
      this.close_()
    } catch (e) {
      if (this.pageActive && generation === this.pinGeneration_ && activityId === this.activityId) this.toast_((e as Error).message)
      hilog.warn(0x0000, TAG, 'remove failed: %{public}s', (e as Error).message)
    } finally {
      this.deleting = false
    }
  }

  // ---- 展示 helper ----

  private categoryLabel_(cat: string): string {
    if (cat === ActivityCategory.LAUNCH) return '启动'
    if (cat === ActivityCategory.DOWNLOAD) return '下载'
    if (cat === ActivityCategory.MOD_INSTALL) return '安装'
    if (cat === ActivityCategory.REPAIR) return '修复'
    if (cat === ActivityCategory.JDK) return 'JDK'
    if (cat === ActivityCategory.APP_UPDATE) return '应用更新'
    if (cat === ActivityCategory.APP_UPDATE_DOWNLOAD) return '更新包下载'
    if (cat === ActivityCategory.MODPACK) return '整合包'
    if (cat === ActivityCategory.GAME_EXPORT) return '游戏包导出'
    if (cat === ActivityCategory.STORAGE) return '存储'
    if (cat === ActivityCategory.VERSION_MANAGE) return '版本管理'
    return cat.length > 0 ? cat : '活动'
  }

  private stateColor_(s: LedgerState): ResourceColor {
    if (s === LedgerState.SUCCESS) return this.theme.successText
    if (s === LedgerState.RUNNING) return this.theme.actionText
    if (s === LedgerState.FAILED || s === LedgerState.CRASHED) return this.theme.errorText
    return this.theme.warningText
  }

  /** 时间使用固定本地字段，避免系统英文区域把中文活动详情变为 AM/PM 长串。 */
  private activityTime_(): string {
    const d: Date = new Date(this.manifest?.startedAt ?? this.activityId)
    const pad = (value: number): string => value < 10 ? '0' + value : String(value)
    return d.getFullYear() + '/' + pad(d.getMonth() + 1) + '/' + pad(d.getDate()) + '  ' + pad(d.getHours()) + ':' + pad(d.getMinutes())
  }

  /** 展开控制不做延迟业务提交；减弱动画为零时长，避免后台回放定时器。 */
  private toggleCapture_(): void {
    this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut }, (): void => {
      this.showCaptureDetails = !this.showCaptureDetails
    })
  }

  private durationLabel_(): string {
    let m = this.manifest
    if (m?.endTimeEstimated === true) return '未知（未记录退出时间）'
    if (m === null || m.endedAt <= 0 || m.startedAt <= 0) return ''
    return formatDurationMs(m.endedAt - m.startedAt)
  }

  /** 标题动作使用可观察字段生成描述；原忙态约束和业务分派都保留。 */
  private workspaceTitleActions_(): AppTitleAction[] {
    const actions: AppTitleAction[] = [];
    if (this.activeView === 'logs') {
      actions.push({ id: 'focus-reader', label: this.focusedReader ? '退出专注' : '专注阅读' });
    }
    actions.push({ id: 'activity-menu', label: '导出、保留与活动管理', icon: AppIconName.More,
      enabled: !this.sharing && !this.exportingEvidence && !this.pinSaving_ && !this.confirmingRemoval_ && !this.deleting && !this.loading });
    return actions;
  }

  build() {
    Column() {
    // embedded 工作区不生成路由返回；独立页仍执行 close_，保留同一正文与阅读状态。
    ImmersiveTitleScaffold({ title: this.focusedReader ? '日志阅读' : '活动详情', titleId: 'activity-log-title',
      theme: this.theme, surfaceColor: this.embedded ? this.theme.bgCard : this.theme.bgPrimary,
      topSafeHeight: this.embedded ? 0 : this.topSafeHeight, showBack: !this.embedded, backLabel: '返回活动账本',
      menuActions: this.workspaceTitleActions_(), onBack: (): void => { this.close_(); },
      onMenuAction: (id: string): void => {
        if (id === 'focus-reader') this.focusReader_();
        else if (id === 'activity-menu') this.moreActions_();
      },
      content: (): void => { this.ImmersiveTitleContent2_(); }
    })
    // 标题 Text 迁移后用稳定锚点承载阅读 Sheet，不能丢失流式阅读关闭后的原回调。
    Column().width(0).height(0)
      .bindSheet(this.showAiResult, this.AiReadingSheet_(), this.aiSheetOptions_())
    }.width('100%').height('100%')
      .backgroundColor(this.embedded ? this.theme.bgCard : this.theme.bgPrimary).borderRadius(this.embedded ? 18 : 0)
      .onAreaChange((_old: Area, current: Area) => { this.viewportWidth = Number(current.width) })
      .bindSheet(this.showShareOptions, this.ShareSelection_(), this.shareSheetOptions_())
  }

  /**
   * 概览辅助区保留已有 AI 报告与分享回执；没有报告时不展示失效的分析入口。
   * 报告卡的打开动作只进入本地阅读层，不依赖远端服务仍然支持新建分析。
   */
  @Builder
  private OverviewTools_() {
    Column({ space: 16 }) {
      ActivityAiCard({ activityId: this.activityId, refreshNonce: this.refreshNonce, theme: this.theme,
        expanded: false, hideWhenEmpty: true, allowAnalyze: false,
        onOpen: (): void => { this.showAiResult = true },
        onRequestAnalysis: (): void => { this.requestAnalysis_() } })
      this.RelatedActivities_()
      if (this.sharedLog !== undefined || this.authorSubmissionId.length > 0) { this.ShareReceipt_() }
      if (this.shareError.length > 0) { Text(this.shareError).fontSize(12).fontColor(this.theme.errorText).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /**
   * 固定底部的查看/分享使用同权重分配剩余宽度，适配窄窗和字体放大。
   * 只改变控件外观与尺寸，查看原文、推荐分享及原忙态资格均沿用现有回调。
   */
  @Builder
  private OverviewActions_() {
    Row({ space: 12 }) {
      Button() {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Document, iconSize: 18, color: this.theme.textOnPrimary })
          Text('查看相关日志').fontSize(14).fontWeight(600).fontColor(this.theme.textOnPrimary)
            .layoutWeight(1).maxLines(2).textAlign(TextAlign.Center)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.constraintSize({ minHeight: 48 }).layoutWeight(1)
        .padding({ left: 12, right: 12, top: 12, bottom: 12 }).borderRadius(24)
        .backgroundColor(this.theme.actionPrimary).onClick(() => { this.openRelevantLog_() })
      Button() {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Share, iconSize: 18, color: this.theme.actionText })
          Text('分享日志').fontSize(14).fontWeight(600).fontColor(this.theme.actionText)
            .layoutWeight(1).maxLines(2).textAlign(TextAlign.Center)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.constraintSize({ minHeight: 48 }).layoutWeight(1)
        .padding({ left: 12, right: 12, top: 12, bottom: 12 }).borderRadius(24)
        .backgroundColor(this.theme.primaryLight).enabled(!this.sharing && !this.exportingEvidence)
        .onClick(() => { this.openShareComposer_() })
    }.width('100%').padding({ top: 12 }).border({ width: { top: 1 }, color: this.theme.divider })
  }

  /** 文件抽屉只改变阅读来源；不与分享多选共用选择状态。 */
  @Builder
  private FilePicker_() {
    Column() {
      ImmersiveTitleScaffold({ title: '选择日志文件', modal: true, theme: this.theme,
        surfaceColor: this.theme.bgPrimary, closeLabel: '关闭日志文件选择',
        onClose: (): void => { this.showFilePicker = false; },
        content: (): void => { this.ImmersiveTitleContent3_(); }
      })
    }.width('100%').height('100%')
  }

  /** 明确关系与同版本历史分开标注；每个入口仍打开独立活动，不合并原件或退出结局。 */
  @Builder
  private RelatedActivities_() {
    if (this.relatedActivities.length > 0) {
      Column({ space: 8 }) {
        Button((this.showRelated ? '收起' : '查看') + '关联与同版本记录 · ' + this.relatedActivities.length)
          .height(44).fontSize(13).fontColor(this.theme.actionText).backgroundColor(Color.Transparent)
          .onClick(() => { this.showRelated = !this.showRelated })
        if (this.showRelated) {
          ForEach(this.relatedActivities, (related: LedgerRelatedActivity) => {
            Button() {
              Column({ space: 4 }) {
                Text(related.relation + ' · ' + ledgerStateLabel(related.state)).fontSize(12).fontColor(this.theme.actionText)
                Text(related.title).fontSize(14).fontColor(this.theme.textPrimary).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(new Date(related.startedAt).toLocaleString()).fontSize(11).fontColor(this.theme.textSecondary)
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').padding(12).backgroundColor(this.theme.bgInput).borderRadius(12)
              .enabled(!this.sharing && !this.exportingEvidence).onClick(() => {
                const params: Record<string, Object> = { 'activityId': related.activityId, 'view': 'overview' }
                this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
                  .catch((): void => { this.toast_('无法打开关联活动，请重试') })
              })
          }, (related: LedgerRelatedActivity): string => String(related.activityId))
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  /** 问题摘要、来源和阶段均来自本地原文；与退出结局、第三方 AI 结果保持独立。 */
  @Builder
  private DiagnosticOverview_() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Search, iconSize: 18, color: this.theme.actionText })
        Text('本地排查').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
        if (this.diagnosisProgress.length > 0) { LoadingProgress().width(20).height(20).color(this.theme.actionText) }
      }.width('100%')
      if (this.diagnosisProgress.length > 0) {
        Text(this.diagnosisProgress).fontSize(12).fontColor(this.theme.textSecondary)
      }
      if (this.diagnosis !== undefined) {
        Text('已读取 ' + this.diagnosis.scannedCount + ' / ' + this.diagnosis.sourceCount
          + ' 份诊断日志 · ' + this.diagnosis.eventCount + ' 个事件')
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
        if (this.diagnosis.ignoredEvents > 0) {
          Text('已折叠 ' + this.diagnosis.ignoredEvents + ' 个已知兼容提示，原文仍完整保留。')
            .fontSize(12).fontColor(this.theme.textHint).width('100%')
        }
        if (this.diagnosis.findings.length === 0) {
          Text('暂无线索可直接定位。可继续阅读原始日志，退出原因仍以本次退出记录为准。')
            .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        } else {
          Text('以下是错误线索，不等于已确定的崩溃原因。').fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          ForEach(this.showAllFindings ? this.diagnosis.findings : this.diagnosis.findings.slice(0, 3), (finding: ActivityFinding) => {
            Button() {
              Column({ space: 6 }) {
                Text(finding.title).fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
                  .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(finding.explanation).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
                Text(finding.fileName + ' · 原文 ' + finding.line + '–' + finding.endLine + ' 行'
                  + (finding.occurrences > 1 ? ' · 多份日志出现 ' + finding.occurrences + ' 次' : ''))
                  .fontSize(12).fontColor(this.theme.actionText).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').padding(16).borderRadius(14).backgroundColor(this.theme.bgInput)
              .onClick(() => { this.openEvidenceAt_(finding.fileId, finding.line) })
          }, (finding: ActivityFinding): string => finding.fileId + ':' + finding.line)
          if (this.diagnosis.findings.length > 3) {
            Button(this.showAllFindings ? '收起其他线索' : '查看其他线索（' + this.diagnosis.findings.length + ' 组）')
              .height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.actionText)
              .onClick(() => { this.showAllFindings = !this.showAllFindings })
          }
        }
        if (this.diagnosis.phases.length > 0) {
          Button((this.showPhaseList ? '收起' : '查看') + '有证据的启动阶段 · ' + this.diagnosis.phases.length)
            .height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.actionText)
            .onClick(() => { this.showPhaseList = !this.showPhaseList })
          if (this.showPhaseList) {
            ForEach(this.diagnosis.phases, (phase: ActivityPhase) => {
              Button() {
                Column({ space: 4 }) {
                  Text('• ' + phase.title).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
                  Text(phase.detail).fontSize(12).fontColor(this.theme.textSecondary).maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(phase.fileName + ':' + phase.line).fontSize(11).fontColor(this.theme.actionText)
                }.width('100%').alignItems(HorizontalAlign.Start)
              }.width('100%').padding(8).backgroundColor(Color.Transparent)
                .onClick(() => { this.openEvidenceAt_(phase.fileId, phase.line) })
            }, (phase: ActivityPhase): string => phase.key)
          }
        }
        if (this.diagnosis.gaps.length > 0) {
          Text('扫描边界：' + this.diagnosis.gaps.join('；')).fontSize(12).fontColor(this.theme.warningText).width('100%')
        }
      }
      if (this.diagnosisError.length > 0) {
        Text('本地排查未完成：' + this.diagnosisError).fontSize(12).fontColor(this.theme.warningText).width('100%')
        Button('重试本地排查').height(44).onClick(() => { this.loadDiagnosis_() })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(18)
      .backgroundColor(this.overviewSurface_())
  }

  /** 只呈现本次会话记录的事实，包含来源与 planned/unavailable，禁止用当前设备填历史。 */
  @Builder
  private EnvironmentFacts_() {
    Column({ space: 8 }) {
      Text('本次环境').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
      if (this.environmentFacts.length === 0) {
        Text('这条历史活动没有保存环境快照。').fontSize(13).fontColor(this.theme.textSecondary)
      }
      ForEach(this.environmentFacts, (fact: SessionEnvironmentFact) => {
        Row({ space: 12 }) {
          Text(environmentFactLabel(fact.key)).fontSize(12).fontColor(this.theme.textSecondary).width(this.viewportWidth >= 620 ? 140 : 92)
          Column({ space: 4 }) {
            Text(fact.value).fontSize(14).fontColor(this.theme.textPrimary).maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text((fact.status === 'planned' ? '启动时计划 · ' : fact.status === 'unavailable' ? '尚未取得 · ' : '记录来源 · ') + fact.source)
              .fontSize(11).fontColor(this.theme.textSecondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 10, bottom: 10 })
          .border({ width: { bottom: 1 }, color: this.theme.divider })
      }, (fact: SessionEnvironmentFact): string => fact.key)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 排版选项全部在本地生效；不会修改原件、日志级别或分享默认范围。 */
  private readerOptions_(): void {
    this.getUIContext().getPromptAction().showActionMenu({ title: '日志阅读', buttons: [
      { text: this.wrapLines ? '关闭自动换行' : '开启自动换行', color: this.theme.actionText as string },
      { text: '字号：' + this.readerFontSize + '（点击切换）', color: this.theme.actionText as string },
      { text: this.collapseEvents ? '展开全部事件' : '折叠长事件', color: this.theme.actionText as string },
      { text: this.searchAllFiles ? '仅搜索当前文件' : '搜索本次全部日志', color: this.theme.actionText as string },
      { text: '导出完整日志包（脱敏 ZIP）', color: this.theme.actionText as string },
      { text: this.followLatest ? '暂停跟随最新日志' : '跟随最新日志', color: this.theme.actionText as string },
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) this.wrapLines = !this.wrapLines
      else if (result.index === 1) this.readerFontSize = this.readerFontSize >= 17 ? 12 : this.readerFontSize + 1
      else if (result.index === 2) { this.collapseEvents = !this.collapseEvents; this.model.setCollapsed(this.collapseEvents) }
      else if (result.index === 3) { this.showSearch = true; this.searchScope_() }
      else if (result.index === 4) this.exportZip_()
      else if (result.index === 5) this.toggleFollow_()
    }).catch((): void => {})
  }

  /** 所有文件均保留捕获状态，不把未产生、缺失和已清理合并成“错误”。 */
  @Builder
  private EvidenceList_() {
    Column({ space: 12 }) {
      Text('本次活动文件').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
      Text(this.evidenceIntegrityLabel_() + ' · ' + this.savedEvidenceCount_() + ' 个文件可读')
        .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      ForEach(this.evidenceFiles.filter((item: EvidenceFileRecord): boolean => this.showUnavailableFiles || evidenceReadable(item)), (file: EvidenceFileRecord) => {
        Button() {
          Row({ space: 12 }) {
            AppIcon({ name: AppIconName.Document, iconSize: 20,
              color: this.readableFile_(file) ? this.theme.actionText : this.theme.textHint })
            Column({ space: 4 }) {
              Text(evidenceRoleLabel(file.role)).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
              Text(file.path).fontSize(12).fontColor(this.theme.textSecondary)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(evidenceCaptureLabel(file, this.manifest?.state === LedgerState.RUNNING) + ' · ' + formatLogBytes(file.bytes))
                .fontSize(12).fontColor(this.theme.textSecondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 60 }).padding(12).borderRadius(12)
          .backgroundColor(this.activeEvidenceId === file.fileId ? this.theme.primaryLight : this.theme.bgCard)
          .enabled(this.readableFile_(file) && !this.sharing)
          .onClick(() => { this.stopFollowing_(); this.fromLine = 0; this.activeView = 'logs'; this.switchEvidence_(file) })
      }, (file: EvidenceFileRecord): string => file.fileId)
      Button(this.showUnavailableFiles ? '收起未生成的文件' : '显示未生成或不可用的文件').height(44).fontSize(12)
        .backgroundColor(Color.Transparent).fontColor(this.theme.textSecondary)
        .onClick(() => { this.showUnavailableFiles = !this.showUnavailableFiles })
      if (this.evidenceFiles.length === 0) {
        Text('没有保存的文件。').fontSize(14).fontColor(this.theme.textSecondary)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }

  /** 概览卡使用页面对应表面；嵌入白色工作区时以背景色形成轻层次，不修改全局主题。 */
  private overviewSurface_(): ResourceColor {
    return this.embedded ? this.theme.bgPrimary : this.theme.bgCard
  }

  /** 退出状态的柔和容器色独立于强调色；运行中才使用当前主题的操作底色。 */
  private stateBackground_(state: LedgerState): ResourceColor {
    if (state === LedgerState.SUCCESS) return this.theme.successBg
    if (state === LedgerState.FAILED || state === LedgerState.CRASHED) return this.theme.errorBg
    return state === LedgerState.RUNNING ? this.theme.primaryLight : this.theme.warningBg
  }

  /**
   * 活动身份、真实退出结果、证据采集分为三层，不以可读文件数暗示完整。
   * 此卡仅供概览调用；环境与附件页继续使用自己的原有 builder 和间距。
   */
  @Builder
  HeaderCard_() {
    Column({ space: 12 }) {
      if (this.currentStorageIssue.length > 0) {
        Text('当前日志存储：' + this.currentStorageIssue).fontSize(12).fontColor(this.theme.warningText).width('100%')
      }
      Row({ space: 8 }) {
        if (this.manifest !== null) {
          Text(this.categoryLabel_(this.manifest.category) + '记录').fontSize(12)
            .fontColor(this.theme.textSecondary).layoutWeight(1)
          Row({ space: 4 }) {
            Row().width(6).height(6).backgroundColor(this.stateColor_(this.manifest.state)).borderRadius(3)
              .accessibilityLevel('no')
            Text(ledgerStateLabel(this.manifest.state)).fontSize(12).fontWeight(600)
              .fontColor(this.stateColor_(this.manifest.state))
          }.padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(8)
            .backgroundColor(this.stateBackground_(this.manifest.state))
        } else {
          Text(this.diagnosisTitle || '历史活动').fontSize(20).fontWeight(600).fontColor(this.theme.textPrimary)
        }
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.manifest !== null) {
        Text(this.manifest.title).fontSize(20).fontWeight(600).fontColor(this.theme.textPrimary)
          .width('100%').copyOption(CopyOptions.LocalDevice)
        if (this.pinned) {
          Text('已保留 · 不会自动清理').fontSize(12).fontColor(this.theme.actionText).width('100%')
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          Text(this.activityTime_()).fontSize(12).fontColor(this.theme.textSecondary).margin({ right: 16, bottom: 4 })
          if (this.durationLabel_().length > 0) {
            Text('用时 ' + this.durationLabel_()).fontSize(12).fontColor(this.theme.textSecondary).margin({ right: 16, bottom: 4 })
          }
        }.width('100%')
        if (this.manifest.outcomeSummary.length > 0 &&
          this.manifest.outcomeSummary.trim() !== ledgerStateLabel(this.manifest.state).trim()) {
          Column() {
            Text(this.manifest.outcomeSummary).fontSize(14).lineHeight(22)
              .fontColor(this.stateColor_(this.manifest.state)).width('100%')
          }.width('100%').padding(12).borderRadius(12).backgroundColor(this.stateBackground_(this.manifest.state))
        }
        Button() {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Document, iconSize: 18, color: this.theme.textSecondary })
            Column({ space: 4 }) {
              Text(this.evidenceIntegrityLabel_() + ' · ' + this.savedEvidenceCount_() + ' 个文件可读')
                .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              Text(this.showCaptureDetails ? '收起采集详情' : '查看采集详情与缺口')
                .fontSize(12).fontColor(this.theme.actionText).width('100%')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: this.showCaptureDetails ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 14, color: this.theme.textSecondary })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 52 }).padding(0).backgroundColor(Color.Transparent)
          .onClick(() => { this.toggleCapture_() })
        if (this.showCaptureDetails) {
          Scroll() {
            Column({ space: 8 }) {
              Text('采集版本：' + this.evidenceRevision + ' · 登记来源 ' + this.evidenceFiles.length)
                .fontSize(12).fontColor(this.theme.textSecondary)
              if (this.manifest.errorKind.length > 0) Text('错误类型：' + this.manifest.errorKind).fontSize(12).fontColor(this.theme.textSecondary)
              if (this.evidenceMissingReasons.length > 0) Text('缺口：' + this.evidenceMissingReasons.join('；')).fontSize(12).fontColor(this.theme.warningText)
              ForEach(this.evidenceFiles, (file: EvidenceFileRecord) => {
                Text(evidenceRoleLabel(file.role) + '：' + evidenceCaptureLabel(file, this.manifest?.state === LedgerState.RUNNING)
                  + ' · ' + file.attribution + (file.reason.length > 0 ? ' · ' + file.reason : ''))
                  .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              }, (file: EvidenceFileRecord): string => file.fileId)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.width('100%').constraintSize({ maxHeight: 140 })
        }
      }
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.overviewSurface_())
      .alignItems(HorizontalAlign.Start)
  }

  /**
   * 宽屏辅助摘要只消费已保存的环境事实，不读取当前设备来补历史。
   * 使用独立 builder，避免修改用户要求保留的 EnvironmentFacts_/EvidenceList_。
   */
  @Builder
  private OverviewEnvironment_() {
    Column({ space: 12 }) {
      Text('本次环境').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
      if (this.environmentFacts.length === 0) {
        Text('这条历史活动没有保存环境快照。').fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      } else {
        ForEach(this.environmentFacts.slice(0, 3), (fact: SessionEnvironmentFact) => {
          Column({ space: 4 }) {
            Text(environmentFactLabel(fact.key)).fontSize(12).fontColor(this.theme.textSecondary)
            Text(fact.value).fontSize(14).fontColor(this.theme.textPrimary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (fact: SessionEnvironmentFact): string => fact.key)
      }
      Button('查看环境与附件').height(44).fontSize(12).fontColor(this.theme.actionText)
        .backgroundColor(Color.Transparent).onClick(() => { this.activeView = 'files' })
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.overviewSurface_())
      .alignItems(HorizontalAlign.Start)
  }

  /** 分段切换。只显示实际存在的段，不给空段留位置。 */
  @Builder
  PartTabs_() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.parts, (p: LedgerPart) => {
          Row({ space: 4 }) {
            Text(ledgerPartLabel(p))
              .fontSize(12)
              .fontWeight(!this.viewingEvidence && this.activePart === p ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(!this.viewingEvidence && this.activePart === p ? this.theme.actionText : this.theme.textSecondary)
            Text(formatLogBytes(this.partBytes_(p)))
              .fontSize(10).fontColor(this.theme.textHint)
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(!this.viewingEvidence && this.activePart === p ? this.theme.primaryLight : this.theme.bgCard)
          .onClick(() => { this.switchPart_(p) })
        }, (p: LedgerPart) => 'part-' + p)
      }
      .padding({ left: 12, right: 12 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 10 })
  }

  /** 完整证据清单中的附加文件查看入口；旧六段由上方兼容标签承载。 */
  @Builder
  EvidenceTabs_() {
    if (this.additionalEvidenceFiles.length > 0) {
      Column({ space: 6 }) {
        Text('本次启动的其他证据')
          .fontSize(11).fontColor(this.theme.textHint).width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.additionalEvidenceFiles, (file: EvidenceFileRecord) => {
              Row({ space: 4 }) {
                Text(evidenceRoleLabel(file.role))
                  .fontSize(12)
                  .fontWeight(this.viewingEvidence && this.activeEvidenceId === file.fileId
                    ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.viewingEvidence && this.activeEvidenceId === file.fileId
                    ? this.theme.actionText : this.theme.textSecondary)
                Text(formatLogBytes(file.bytes)).fontSize(10).fontColor(this.theme.textHint)
              }
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor(this.viewingEvidence && this.activeEvidenceId === file.fileId
                ? this.theme.primaryLight : this.theme.bgCard)
              .accessibilityText(evidenceRoleLabel(file.role) + '，' + this.evidenceStateLabel_(file.state))
              .enabled(this.readableFile_(file))
              .onClick(() => { this.switchEvidence_(file) })
            }, (file: EvidenceFileRecord) => 'evidence-' + file.fileId)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .margin({ top: 8 })
    }
  }

  /**
   * 日志专用工具条与正文采用同一固定反色区域，减少阅读上方的重复面板。
   * 等级仍调用原过滤链；搜索只改变本地筛选，展开动作本身不会读取或发送新文件。
   */
  @Builder
  ToolBar_() {
    Column({ space: 0 }) {
      Row({ space: 4 }) {
        // 等级条只占分配到的剩余宽度；320vp窄窗或大字体时横向延伸，
        // 搜索/刷新仍有各自44vp固定触点，不被阅读区的clip裁掉。
        Scroll() {
          Row({ space: 4 }) {
            this.LevelChip_(LevelFilter.ALL, '全部')
            this.LevelChip_(LevelFilter.WARN_UP, '警告及以上')
            this.LevelChip_(LevelFilter.ERROR_UP, '错误')
          }.height(44)
        }.layoutWeight(1).height(44).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        Button() { AppIcon({ name: AppIconName.Search, iconSize: 18, color: '#B8C5D6' }) }
          .width(44).height(44).padding(0).borderRadius(12)
          .backgroundColor(this.showSearch ? '#263447' : Color.Transparent)
          .accessibilityText(this.showSearch ? '收起日志搜索' : '搜索日志')
          .onClick(() => { this.showSearch = !this.showSearch })
        Button() { AppIcon({ name: AppIconName.Refresh, iconSize: 18, color: '#B8C5D6' }) }
          .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('刷新当前日志').enabled(!this.reading).onClick(() => { this.load_(true) })
      }.width('100%').padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor('#171E2B')
      if (this.showSearch) {
        Column({ space: 4 }) {
          TextInput({ placeholder: this.searchAllFiles ? '搜索本次全部日志' : '搜索当前文件', text: this.keyword })
            .caretColor('#7DD3FC').fontSize(13).fontColor('#E5EAF2').placeholderColor('#94A3B8')
            .height(44).backgroundColor('#1D2939').borderRadius(10).width('100%')
            .onChange((value: string): void => { this.search_(value) })
          Text('保留完整事件、原行号与来源').fontSize(12).fontColor('#94A3B8')
        }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
      }
    }.width('100%')
  }

  /** 等级触点至少44vp；固定反色选中底与错误正文底分开，不改变真实事件级别。 */
  @Builder
  LevelChip_(filter: LevelFilter, label: string) {
    Button(label).height(44).constraintSize({ minWidth: 48 }).padding({ left: 10, right: 10 })
      .fontSize(12).fontWeight(this.levelFilter === filter ? 600 : 400)
      .fontColor(this.levelFilter === filter ? '#FFD1DF' : '#A7B3C5').borderRadius(10)
      .backgroundColor(this.levelFilter === filter ? '#3D2834' : Color.Transparent)
      .accessibilityText(label + (this.levelFilter === filter ? '，已选中' : ''))
      .enabled(!this.reading).onClick(() => { this.levelFilter = filter; this.applyFilter_() })
  }

  /**
   * 当前文件入口与阅读设置在主题色外壳内，文件选择仍绑定原稳定锚点和用户面板高度。
   * 不复用或重绘 EnvironmentFacts_/EvidenceList_，从而完整保留L04的既有视觉。
   */
  @Builder
  private ReaderSourceBar_() {
    Row({ space: 8 }) {
      Button() {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Document, iconSize: 18, color: this.theme.actionText })
          Text(this.searchAllFiles ? '本次全部可读日志' : this.activeEvidenceLabel_()).fontSize(14).fontWeight(600)
            .fontColor(this.theme.textPrimary).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          AppIcon({ name: AppIconName.ChevronDown, iconSize: 14, color: this.theme.textSecondary })
        }.width('100%')
      }.height(48).layoutWeight(1).padding({ left: 12, right: 12 }).borderRadius(12)
        .backgroundColor(this.overviewSurface_()).accessibilityText('选择当前活动的日志文件')
        .onClick(() => { this.showFilePicker = true })
        .bindSheet(this.showFilePicker, this.FilePicker_(), { height: DeviceProfile.form() === DeviceForm.PHONE
          ? detailSheetHeightForLayout(DeviceForm.PHONE, Breakpoint.SM, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_)
          : '70%', showClose: false,
          backgroundColor: this.theme.bgPrimary, onDisappear: (): void => { this.showFilePicker = false } })
      Button() { AppIcon({ name: AppIconName.Filter, iconSize: 20, color: this.theme.actionText }) }
        .width(44).height(44).padding(0).borderRadius(22).backgroundColor(this.overviewSurface_())
        .accessibilityText('阅读选项：换行、字号、搜索范围、导出与跟随')
        .onClick(() => { this.readerOptions_() })
    }.width('100%')
  }

  /**
   * 分页固定在深色阅读区底部，搜索移到上方工具条；正文获得所有剩余高度。
   * 每页仍为原有300单位，切页先停止跟随，已结束活动不会开启实时尾读。
   */
  @Builder
  private ReaderPageBar_() {
    Row({ space: 8 }) {
      Button('上一页').height(48).fontSize(12).fontColor('#7DD3FC').backgroundColor(Color.Transparent)
        .enabled(!this.reading && this.pageStart > 0)
        .onClick(() => { this.stopFollowing_(); this.loadCurrentPage_(Math.max(0, this.pageStart - 300)) })
      Text(this.showingTail ? '最新事件窗口' : '第 ' + (Math.floor(this.pageStart / 300) + 1) + ' 页')
        .fontSize(12).fontColor('#B8C5D6').layoutWeight(1).textAlign(TextAlign.Center)
      Button('下一页').height(48).fontSize(12).fontColor('#7DD3FC').backgroundColor(Color.Transparent)
        .enabled(!this.reading && this.hasNextPage)
        .onClick(() => { this.stopFollowing_(); this.loadCurrentPage_(this.pageStart + 300) })
    }.width('100%').padding({ left: 8, right: 8 }).backgroundColor('#171E2B')
  }

  /** 阅读独立布局只消费当前活动身份和现有日志状态，不在进入页面时引入额外服务请求。 */
  @Builder
  private ReaderWorkspace_() {
    Column({ space: 12 }) {
      if ((this.manifest?.title ?? this.diagnosisTitle).length > 0) {
        Column({ space: 4 }) {
          Text(this.manifest?.title ?? this.diagnosisTitle).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
            .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('本次活动 · ' + this.savedEvidenceCount_() + ' 个可读文件').fontSize(12).fontColor(this.theme.textSecondary)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      this.ReaderSourceBar_()
      this.LogBody_()
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  /** 事件操作保持原来源；定位上下文会清除筛选，避免让用户误以为上下文不存在。 */
  private eventActions_(row: LogRow): void {
    this.getUIContext().getPromptAction().showActionMenu({ title: '日志事件 · 原文 ' + (row.event?.startLine ?? row.lineNumber)
      + '–' + (row.event?.endLine ?? row.lineNumber) + ' 行', buttons: [
      { text: this.model.isEventExpanded(row.eventId ?? '') ? '收起事件' : '展开完整事件', color: this.theme.actionText as string },
      { text: '复制事件（脱敏）', color: this.theme.actionText as string },
      { text: '查看原文件上下文', color: this.theme.actionText as string },
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) { this.model.toggleEvent(row.eventId ?? ''); this.eventRevision++ }
      else if (result.index === 1) this.copyEvent_(row)
      else if (result.index === 2) {
        const file = this.evidenceFiles.find((item: EvidenceFileRecord): boolean => item.localPath === row.sourcePath)
        if (file !== undefined) {
          this.resetReaderFilter_(Math.max(1, (row.event?.startLine ?? row.lineNumber) - 20))
          this.switchEvidence_(file)
        }
      }
    }).catch((): void => {})
  }

  /** 每页只创建可见行节点；折叠隐藏续行而不删除事件，字号与换行只影响排版。 */
  @Builder
  LogBody_() {
    Column() {
      this.ToolBar_()
      Row({ space: 8 }) {
        Text(this.reading ? '正在读取完整事件…' : (this.showingTail ? '最新窗口 · ' : '') + this.matchingEvents + ' 个事件 · ' + this.matchingLines + ' 行')
          .fontSize(12).fontColor('#94A3B8').layoutWeight(1)
        Button('本页末尾').fontSize(12).height(44).fontColor('#7DD3FC').backgroundColor(Color.Transparent)
          .onClick(() => { this.scroller.scrollEdge(Edge.Bottom) })
      }.width('100%').height(44).padding({ left: 12, right: 8 }).backgroundColor('#171E2B')
      if (this.followLatest) {
        Button('正在跟随最新日志 · 点击暂停').height(44).fontSize(12).onClick(() => { this.stopFollowing_() })
      } else if (this.showingTail) {
        Button('已暂停跟随 · 返回完整分页').height(44).fontSize(12).onClick(() => { this.fromLine = 0; this.loadCurrentPage_(0) })
      }
      if (this.fromLine > 0) {
        Button('正在查看局部上下文 · 返回文件开头').height(44).fontSize(12)
          .onClick(() => { this.fromLine = 0; this.loadCurrentPage_(0) })
      }
      if (this.reading) {
        Column({ space: 8 }) {
          LoadingProgress().width(28).height(28).color('#7DD3FC')
          Text('正在扫描匹配事件，异常链与续行会一起保留').fontSize(12).fontColor('#94A3B8')
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.readError.length > 0) {
        Column({ space: 12 }) {
          Text(this.readError).fontSize(13).fontColor('#FCA5A5')
          Button('重新读取').height(44).onClick(() => { this.load_(true) })
        }.padding(16).layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.matchingLines === 0) {
        Column({ space: 12 }) {
          Text(this.readSources.length === 0 ? '这条活动没有可读日志' : this.lineCount === 0 ? '当前文件尚无内容' : '没有匹配的日志事件')
            .fontSize(13).fontColor('#94A3B8')
          if (this.keyword.length > 0 || this.levelFilter !== LevelFilter.ALL) {
            Button('清除筛选').height(44).onClick(() => { this.keyword = ''; this.levelFilter = LevelFilter.ALL; this.applyFilter_() })
          }
        }.padding(16).layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          List({ scroller: this.scroller }) {
            LazyForEach(this.model, (row: LogRow) => {
              ListItem() {
                Column() {
                  if (row.sourceStart === true) {
                    Text(this.sourceLabel_(row)).fontSize(12).fontWeight(600).fontColor('#7DD3FC')
                      .width('100%').textAlign(TextAlign.Start).padding(8)
                  }
                  if (row.eventStart === true && ((row.event?.lines.length ?? 0) > 1 || row.level === 2)) {
                    Button() {
                      Row({ space: 8 }) {
                        Text((row.event?.format === 'xml' ? row.event?.title : '日志事件') ?? '日志事件')
                          .fontSize(12).fontColor('#7DD3FC').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                        Text((row.event?.lines.length ?? 1) + ' 行 · 操作').fontSize(11).fontColor('#94A3B8')
                      }.width('100%')
                    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12 })
                      .backgroundColor(row.level === 2 ? '#2B202C' : '#192332').borderRadius(0).onClick(() => { this.eventActions_(row) })
                  }
                  if (row.event?.format !== 'xml' || this.model.isEventExpanded(row.eventId ?? '')) {
                    Row() {
                      Text(row.continuation ? '·' : String(row.sourceLineNumber ?? row.lineNumber))
                        // 六位以上的原始行号扩展gutter，避免大日志中定位号换行或截断。
                        .fontSize(11).fontFamily('monospace').fontColor('#7F8DA3')
                        .width(Math.max(52, String(row.sourceLineNumber ?? row.lineNumber).length * 8 + 12)).maxLines(1)
                        .textAlign(TextAlign.End).padding({ right: 10, top: 3, bottom: 3 })
                      Text() {
                        ForEach(this.spans_(row), (span: LogSpan) => { Span(span.text).fontColor(span.color) })
                      }.fontSize(this.readerFontSize).fontFamily('monospace').lineHeight(this.readerFontSize + 8)
                        .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.None)
                        .padding({ left: 10, right: 12, top: 3, bottom: 3 })
                        .border({ width: { left: 1 }, color: '#263244' })
                    }.width('100%').alignItems(VerticalAlign.Top)
                      .backgroundColor(row.level === 2 ? '#241922' : row.level === 1 ? '#242119' : '#0F141D')
                      .onClick(() => { this.eventActions_(row) })
                  }
                }.width('100%')
              }
            }, (row: LogRow): string => String(this.eventRevision) + '-' + (row.sourcePath ?? '') + '-' + row.key)
          }.id('activity-log-reader')
            // 非换行模式同时为可扩展原行号与两侧文字留白保留空间。
            .width(this.wrapLines ? '100%' : Math.max(this.viewportWidth - 32, this.model.maxLineLength() * this.readerFontSize * 0.65 + 100))
            .height('100%').cachedCount(8).scrollBar(BarState.Auto)
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto)
      }
      this.ReaderPageBar_()
    }.width('100%').layoutWeight(1).borderRadius(16).clip(true).backgroundColor('#0F141D')
  }


  /** 活动对象与报告共用正文滚动区；长名称完整换行，标题不再为身份和阅读说明保留固定行。 */
  @Builder
  private ImmersiveTitleContent1_() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          if ((this.manifest?.title ?? this.diagnosisTitle).length > 0) {
            Text(this.manifest?.title ?? this.diagnosisTitle).fontSize(16).fontWeight(600)
              .fontColor(this.theme.textPrimary).width('100%').copyOption(CopyOptions.LocalDevice)
          }
          ActivityAiCard({ activityId: this.activityId, refreshNonce: this.refreshNonce, theme: this.theme, expanded: true,
            allowAnalyze: false,
            onRequestAnalysis: (): void => { this.requestAnalysis_() } })
        }.width('100%').padding({ bottom: 24 }).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%').padding({ top: 8, left: 20, right: 20, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent2_() {
    Column({ space: 12 }) {
      ActivityViewTabs({ labels: ['概览', '日志', '环境与附件'], theme: this.theme,
        selectedIndex: WORKSPACE_VIEWS.indexOf(this.activeView),
        onSelect: (index: number): void => { this.activeView = WORKSPACE_VIEWS[index] } })
      Column() {
      ActivityPaneMotion({ identity: this.activeView, active: this.hostVisible }) {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.theme.actionText)
          Text('正在读取活动记录…').fontSize(14).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.activeView === 'overview') {
        Scroll() {
          Column({ space: 20 }) {
            // 身份与排查沿同一阅读轴；右侧辅助列不改变宿主旧版活动列表。
            if (this.viewportWidth >= 760) {
              Row({ space: 20 }) {
                Column({ space: 20 }) { this.HeaderCard_(); this.DiagnosticOverview_() }.layoutWeight(1)
                Column({ space: 16 }) { this.OverviewTools_(); this.OverviewEnvironment_() }.width(260)
              }.width('100%').alignItems(VerticalAlign.Top)
            } else {
              this.HeaderCard_()
              this.DiagnosticOverview_()
              this.OverviewTools_()
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8, bottom: 16 })
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
        this.OverviewActions_()
      } else if (this.activeView === 'files') {
        Scroll() {
          Column({ space: 20 }) {
            this.EnvironmentFacts_()
            this.EvidenceList_()
          }.width('100%')
        }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      } else {
        this.ReaderWorkspace_()
      }
      }
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%')
      .padding({ top: this.embedded ? 12 : 8, left: 16, right: 16,
        bottom: this.embedded ? 12 : this.bottomSafeHeight + 8 })
    }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent3_() {
        Scroll() { this.EvidenceList_() }.width('100%').height('100%').padding(20).align(Alignment.TopStart)
      }
}


/**
 * 原路由保持不变。它只解析稳定的带引号参数，再创建共享工作区；
 * 嵌入工作区不会读取其他路由的参数，避免平板选择被旧诊断覆盖。
 */
@Entry
@Component
struct ActivityLogPage {
  @State private hostVisible: boolean = true
  @State private activityKey: number = 0
  @State private startView: string = 'logs'
  @State private destination: string = 'logshare'
  @State private openShare: boolean = false
  @State private analyzeAfterShare: boolean = false
  @State private sourceTitle: string = ''
  @State private refreshNonce: number = 0

  /** 返回分享历史等路由后重新核验来源，不复用已撤回的链接。 */
  onPageShow(): void { this.hostVisible = true; this.refreshNonce++ }
  onPageHide(): void { this.hostVisible = false }

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>
    this.activityKey = typeof params?.['activityId'] === 'number' ? params['activityId'] as number : 0
    this.startView = params?.['view'] === 'overview' ? 'overview' : 'logs'
    this.destination = params?.['destination'] === 'author' ? 'author' : 'logshare'
    this.openShare = params?.['showShare'] === true
    // 保留旧路由参数兼容，但不再把 requestAi 转为新分析或隐式公开分享。
    this.analyzeAfterShare = false
    this.sourceTitle = typeof params?.['diagnosisTitle'] === 'string' ? params['diagnosisTitle'] as string : ''
  }

  build() {
    Column() {
      if (this.activityKey > 0) {
        ActivityLogWorkspace({ activityId: this.activityKey, hostVisible: this.hostVisible, initialView: this.startView,
          onMetadataChanged: (): void => { this.refreshNonce++ },
          initialDestination: this.destination, initialShare: this.openShare,
          initialAi: this.analyzeAfterShare, initialDiagnosisTitle: this.sourceTitle, refreshNonce: this.refreshNonce })
      } else {
        Text('无法识别这条活动').padding(24)
      }
    }.width('100%').height('100%')
  }
}

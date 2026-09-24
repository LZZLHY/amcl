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
import { acquireEvidenceLease, releaseEvidenceLease, ledgerRemovalBlockReason, ledgerBytesOf } from 'commons';
import { startAiAnalysis, getAiTaskSnapshot, cancelAiAnalysis } from '../components/AiAnalysisService';
import { ActivityAiCard } from '../components/ActivityAiCard';
import { ActivityShareSheet } from '../components/ActivityShareSheet';
import { AnimatedPillBar } from '../components/AnimatedPillBar';
import { MotionSection } from '../components/MotionSection';
import { ActivityViewTabs } from '../components/ActivityViewTabs';
import { ActivityPaneMotion } from '../components/ActivityPaneMotion';
import { UiMotion } from '../components/UiMotion';
import { DeviceProfile, centerSheetForLayout, detailSheetHeightForLayout, sheetWidthForLayout } from 'commons';
import { ensureNotifyPermission } from '../components/AppNotifier';
import { clearSessionShare } from '../components/McSessionSnapshot';
import {
  LedgerPart, LedgerState, LedgerManifest,
  ledgerManifest, ledgerParts, ledgerRead, ledgerPartBytes, ledgerExport,
  ledgerRemove, ledgerPartLabel, ledgerStateLabel, isAbnormalState,
  formatLogBytes, LogExportTarget, sanitizeLogForExport,
  EvidenceFileRecord, EvidenceFileState, EvidenceRole, evidenceRoleLabel,
  listSessionEvidence, evidenceSelectionOf, setEvidenceSelection,
  readSessionEvidence, refreshSessionEvidence, evidenceSelectionDigest,
  readSessionEvidenceTextAsync, readSessionEvidenceSnapshotAsync,
  GZIP_EVIDENCE_TRUNCATION_MARKER,
} from 'commons';
import { ActivityCategory } from 'feature_core';
import { evidenceReadable, evidenceCaptureLabel, evidenceIntegrityCaption, sortEvidenceForView,
  recommendedEvidenceFile, evidenceDisplayName, SessionEnvironmentFact, readObservedSessionEnvironment,
  ledgerSetPinned, ledgerRelatedActivities, LedgerRelatedActivity, environmentFactLabel } from 'commons';
import { loadActivityEvidence } from '../components/ActivityEvidenceService';
import { ActivityDiagnosis, ActivityFinding, ActivityPhase, buildActivityDiagnosis } from '../components/ActivityDiagnostics';
import { exportSessionEvidenceZip } from '../components/EvidenceBundleExport';
import {
  revokeShare, LogShareRecord,
  logShareInstanceForUrl,
  logShareSourceLabel, logShareSupportsAi,
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
  /** 从阅读层转入发送层要等前者真正关闭，避免同时叠两个交互 sheet。 */
  private analyzeAfterReading: boolean = false
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

  /** 保留只影响本地清理，不改变公开链接保留期；写盘成功后再更新按钮。 */
  private togglePinned_(): void {
    try {
      ledgerSetPinned(this.context.filesDir, this.activityId, !this.pinned)
      this.pinned = !this.pinned
      this.onMetadataChanged()
      this.toast_(this.pinned ? '已保留，不会自动清理' : '已取消保留，将遵循日志保留设置')
    } catch (e) { this.toast_('设置失败：' + (e as Error).message) }
  }

  /** 仅初始化当前活动，不自动公开日志或启动 AI。嵌入式实例由活动主键重建。 */
  aboutToAppear(): void {
    this.pageActive = true
    this.applyTheme_()
    this.activeView = this.initialView === 'share' ? 'overview' : this.initialView
    this.shareDestination = this.initialDestination
    this.requestAi = this.initialAi
    this.diagnosisTitle = this.initialDiagnosisTitle
    this.showShareOptions = this.initialShare || this.initialView === 'share'
    this.load_()
    this.loadShare_()
  }

  /** 平板发送/导出期间锁住左侧选择，避免异步结果被显示到另一活动。 */
  private notifyBusy_(): void { this.onBusyChanged(this.sharing || this.exportingEvidence) }

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
    const height: number = detailSheetHeightForLayout(form, breakpoint, this.bottomSafeHeight, this.topSafeHeight)
    return { height: this.shareMode === 'quick' ? Math.min(height, 440) : height,
      width: sheetWidthForLayout(form, breakpoint), preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
      showClose: true, dragBar: !center, backgroundColor: this.theme.bgPrimary,
      onDisappear: (): void => { this.showShareOptions = false } }
  }

  /** 只读 AI 阅读层。不发网络请求，关闭后流仍由服务管理，重开可看到最新内容。 */
  private aiSheetOptions_(): SheetOptions {
    return { height: '88%', preferType: SheetType.BOTTOM, showClose: true, dragBar: true,
      backgroundColor: this.theme.bgPrimary,
      onDisappear: (): void => {
        this.showAiResult = false
        if (this.analyzeAfterReading) { this.analyzeAfterReading = false; this.requestAnalysis_() }
      } }
  }

  /** 低频操作收进明确命名的菜单，手机标题栏不并排挤四个图标；删除仍走二次确认。 */
  private moreActions_(): void {
    if (this.sharing || this.exportingEvidence || this.loading) return
    try {
      this.getUIContext().getPromptAction().showActionMenu({ title: '活动日志操作', buttons: [
        { text: '复制全部脱敏证据', color: this.theme.primary as string },
        { text: '分享记录与撤回', color: this.theme.primary as string },
        { text: '删除本地活动日志', color: this.theme.errorText as string },
        { text: '自定义分享与预览', color: this.theme.primary as string },
        { text: '导出完整日志包（脱敏 ZIP）', color: this.theme.primary as string },
        { text: this.pinned ? '取消保留此活动' : '保留此活动，防止自动清理', color: this.theme.primary as string },
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

  /** 只复用有效的官方分享；没有时进入原有选择/预览/确认流程。 */
  private async requestAnalysis_(): Promise<void> {
    if (this.sharing || this.exportingEvidence) return
    try {
      const records: LogShareRecord[] = await loadShareRecords(this.context)
      const current: LogShareRecord[] = records.filter((record: LogShareRecord): boolean =>
        record.activityId === this.activityId && record.accepted !== false
        && isShareRecordCurrent(record))
        .sort((left: LogShareRecord, right: LogShareRecord): number => right.sharedAt - left.sharedAt)
      const share: LogShareRecord | undefined = current.length > 0 ? current[0] : undefined
      if (share !== undefined && logShareSupportsAi(share.url)) {
        // 已有分享只代表当时快照；明确说明日期/文件数，不暗示它包含后来追加的日志。
        const confirmation = await this.getUIContext().getPromptAction().showDialog({ title: '分析这份已分享快照？',
          message: '分享时间：' + new Date(share.sharedAt).toLocaleString() + '\n文件：' + (share.selectedPaths?.length ?? 0)
            + ' 份。后续新增的本地日志不在其中；如需更换文件，请使用高级分享。',
          buttons: [{ text: '取消', color: this.theme.textSecondary as string }, { text: '分析此快照', color: this.theme.primary as string }] })
        if (confirmation.index !== 1 || !this.pageActive) return
        ensureNotifyPermission(this.context).catch((): void => {})
        startAiAnalysis(this.context, this.activityId, share.id, this.manifest?.title ?? '',
          logShareInstanceForUrl(share.url), share.snapshotDigest ?? '')
        this.activeView = 'overview'
        return
      }
      this.shareDestination = 'logshare'
      this.shareMode = 'advanced'
      this.requestAi = true
      this.showShareOptions = true
    } catch (e) { this.shareError = '无法读取分享记录：' + (e as Error).message }
  }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
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
    this.manifest = ledgerManifest(dir, this.activityId)
    this.pinned = this.manifest?.pinned === true
    this.parts = ledgerParts(dir, this.activityId)
    this.environmentFacts = readObservedSessionEnvironment(dir, this.activityId).facts
    this.relatedActivities = ledgerRelatedActivities(dir, this.activityId)
    const previous = readSessionEvidence(dir, this.activityId)
    this.evidenceFiles = sortEvidenceForView(previous?.files ?? [])
    this.evidenceRevision = previous?.revision ?? 1
    this.evidenceIntegrityState = 'unknown'
    this.evidenceMissingReasons = previous?.missingReasons ?? []
    this.loading = false
    this.reading = this.activeView === 'logs'
    try {
      await verifySessionCaptureRotations(dir, this.activityId)
      const files: EvidenceFileRecord[] = await loadActivityEvidence(dir, this.activityId,
        (): boolean => !this.pageActive || generation !== this.evidenceGeneration)
      if (!this.pageActive || generation !== this.evidenceGeneration) return
      this.evidenceFiles = sortEvidenceForView(files)
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
        this.reading = false; this.readError = '日志核验未完成：' + (e as Error).message
        this.evidenceIntegrityState = 'unknown'
      }
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false
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
    return !this.loading && !this.reading && !this.sharing && !this.copying && !this.exportingEvidence
      && !this.deleting && this.activityId > 0
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
      buttons: [{ text: '取消', color: this.theme.primary as string }, { text: '撤回分享', color: this.theme.error as string }],
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
            .fontColor(this.theme.primary).backgroundColor(this.theme.primaryLight)
            .enabled(!this.sharing).onClick(() => { this.copySharedLink_() })
        }.width('100%')
      }
    }.width('100%').padding(16).borderRadius(12).backgroundColor(this.theme.bgInput)
      .alignItems(HorizontalAlign.Start)
  }

  /** 手机阅读层独立滚动，持续接收公开流式正文；列表与概览始终只渲染短摘要。 */
  @Builder
  private AiReadingSheet_() {
    Column({ space: 16 }) {
      Column({ space: 6 }) {
        Text('AI 分析').fontSize(24).fontWeight(600).fontColor(this.theme.textPrimary)
        Text(this.manifest?.title ?? this.diagnosisTitle).fontSize(12).fontColor(this.theme.textSecondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('实时内容 · 关闭后可随时继续阅读').fontSize(12).fontColor(this.theme.primary)
      }.width('100%').padding({ right: 32 }).alignItems(HorizontalAlign.Start)
      Scroll() {
        ActivityAiCard({ activityId: this.activityId, refreshNonce: this.refreshNonce, theme: this.theme, expanded: true,
          allowAnalyze: !this.sharing && !this.exportingEvidence,
          onRequestAnalysis: (): void => { this.analyzeAfterReading = true; this.showAiResult = false } })
          .margin({ bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%').padding({ top: 24, left: 20, right: 20, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
  }

  private shareSourceText_(): string {
    const record = this.sharedLog
    if (record === undefined) return ''
    const retention = record.storageTimeSec !== undefined && record.storageTimeSec > 0
      ? ' · 保留期约 ' + Math.ceil(record.storageTimeSec / 86400) + ' 天' : ' · 有效期以分享页为准'
    return logShareSourceLabel(record.url) + retention + (logShareSupportsAi(record.url) ? ' · 支持主站 AI 分析' : ' · 备用服务不支持 AI')
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
  private requestRemoveLedger_(): void {
    if (!this.canDelete_()) return
    const title: string = this.manifest?.title ?? '这条活动'
    const message: string = '将删除“' + title + '”的本地日志和证据清单。\n'
      + '状态：' + (this.manifest === null ? '未知' : ledgerStateLabel(this.manifest.state))
      + ' · 占用 ' + formatLogBytes(ledgerBytesOf(this.context.filesDir, this.activityId)) + '\n\n'
      + '在线分享链接不会被撤回；如需撤回，请到“全部分享记录与撤回”处理。'
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除本地活动日志？',
        message: message,
        buttons: [
          { text: '取消', color: this.theme.primary as string },
          { text: '删除本地日志', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) this.removeLedger_()
      }).catch(() => { /* 点框外 = 取消 */ })
    } catch (e) {
      this.shareError = '无法打开确认框：' + (e as Error).message
    }
  }

  private removeLedger_(): void {
    if (!this.canDelete_()) return
    this.deleting = true
    try {
      ledgerRemove(this.context.filesDir, this.activityId)
      this.toast_('已删除本条日志')
      this.close_()
    } catch (e) {
      this.toast_((e as Error).message)
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
    if (cat === ActivityCategory.MODPACK) return '整合包'
    if (cat === ActivityCategory.STORAGE) return '存储'
    if (cat === ActivityCategory.VERSION_MANAGE) return '版本管理'
    return cat.length > 0 ? cat : '活动'
  }

  private stateColor_(s: LedgerState): ResourceColor {
    if (s === LedgerState.SUCCESS) return this.theme.successText
    if (s === LedgerState.RUNNING) return this.theme.primary
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

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        if (!this.embedded) {
          Button() { AppIcon({ name: AppIconName.Back, iconSize: 20, color: this.theme.primary }) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText('返回活动账本').onClick(() => { this.close_() })
        }
        AppIcon({ name: this.activeView === 'logs' ? AppIconName.Document : AppIconName.History, iconSize: 20, color: this.theme.textSecondary })
        Text(this.focusedReader ? '日志阅读' : '活动详情').fontSize(16).fontWeight(600)
          .fontColor(this.theme.textPrimary).layoutWeight(1).id('activity-log-title')
          .bindSheet(this.showAiResult, this.AiReadingSheet_(), this.aiSheetOptions_())
        if (this.activeView === 'logs') {
          Button(this.focusedReader ? '退出专注' : '专注阅读').height(44).fontSize(12)
            .fontColor(this.theme.primary).backgroundColor(Color.Transparent).onClick(() => { this.focusReader_() })
        }
        // 三点明确表示操作菜单，原网格符号容易被误认为布局切换。
        Button() { Text('⋯').fontSize(24).fontWeight(600).fontColor(this.theme.textSecondary) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('导出、保留与活动管理')
          .enabled(!this.sharing && !this.exportingEvidence && !this.loading).onClick(() => { this.moreActions_() })
      }.width('100%')
      ActivityViewTabs({ labels: ['概览', '日志', '环境与附件'], theme: this.theme,
        selectedIndex: WORKSPACE_VIEWS.indexOf(this.activeView),
        onSelect: (index: number): void => { this.activeView = WORKSPACE_VIEWS[index] } })
      Column() {
      ActivityPaneMotion({ identity: this.activeView, active: this.hostVisible }) {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.theme.primary)
          Text('正在读取活动记录…').fontSize(14).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.activeView === 'overview') {
        Scroll() {
          Column({ space: 20 }) {
            this.HeaderCard_()
            // 只在宽屏概览使用辅助栏；日志正文始终保留完整阅读宽度。
            if (this.viewportWidth >= 760) {
              Row({ space: 20 }) {
                Column() { this.DiagnosticOverview_() }.layoutWeight(1)
                Column() { this.OverviewTools_() }.width(260)
              }.width('100%').alignItems(VerticalAlign.Top)
            } else {
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
        Row({ space: 8 }) {
          Button() {
            Row({ space: 8 }) {
              AppIcon({ name: AppIconName.Document, iconSize: 16, color: this.theme.primary })
              Text(this.searchAllFiles ? '本次全部可读日志' : this.activeEvidenceLabel_()).fontSize(13)
                .fontColor(this.theme.primary).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.primary })
            }.width('100%')
          }.height(44).layoutWeight(1).padding({ left: 12, right: 12 }).borderRadius(10).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.showFilePicker = true })
            .bindSheet(this.showFilePicker, this.FilePicker_(), { height: '70%', showClose: true,
              backgroundColor: this.theme.bgPrimary, onDisappear: (): void => { this.showFilePicker = false } })
          Button('阅读选项').height(44).fontSize(12).borderRadius(10).backgroundColor(this.theme.bgInput).fontColor(this.theme.textPrimary)
            .onClick(() => { this.readerOptions_() })
        }.width('100%')
        this.ToolBar_()
        this.LogBody_()
        Row({ space: 8 }) {
          Button('上一页').height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.primary).enabled(!this.reading && this.pageStart > 0)
            .onClick(() => { this.stopFollowing_(); this.loadCurrentPage_(Math.max(0, this.pageStart - 300)) })
          Text(this.showingTail ? '最新事件窗口' : '第 ' + (Math.floor(this.pageStart / 300) + 1) + ' 页').fontSize(12).fontColor(this.theme.textSecondary)
          Button('下一页').height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.primary).enabled(!this.reading && this.hasNextPage)
            .onClick(() => { this.stopFollowing_(); this.loadCurrentPage_(this.pageStart + 300) })
          Blank()
          Button(this.showSearch ? '收起搜索' : '搜索').height(44).fontSize(12).backgroundColor(this.theme.bgInput).fontColor(this.theme.textPrimary)
            .borderRadius(10).onClick(() => { this.showSearch = !this.showSearch })
        }.width('100%')
      }
      }
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%')
      .padding({ top: this.embedded ? 12 : this.topSafeHeight + 8, left: 16, right: 16,
        bottom: this.embedded ? 12 : this.bottomSafeHeight + 8 })
      .backgroundColor(this.embedded ? this.theme.bgCard : this.theme.bgPrimary).borderRadius(this.embedded ? 18 : 0)
      .onAreaChange((_old: Area, current: Area) => { this.viewportWidth = Number(current.width) })
      .bindSheet(this.showShareOptions, this.ShareSelection_(), this.shareSheetOptions_())
  }

  /** 辅助操作独立成组；宽屏靠右、窄屏顺排，仍复用原有分享/AI生命周期。 */
  @Builder
  private OverviewTools_() {
    Column({ space: 16 }) {
      this.RelatedActivities_()
      ActivityAiCard({ activityId: this.activityId, refreshNonce: this.refreshNonce, theme: this.theme,
        expanded: false, hideWhenEmpty: true, allowAnalyze: !this.sharing && !this.exportingEvidence,
        onOpen: (): void => { this.showAiResult = true },
        onRequestAnalysis: (): void => { this.requestAnalysis_() } })
      Button() {
        Row({ space: 12 }) {
          AppIcon({ name: AppIconName.Ai, iconSize: 20, color: this.theme.primary })
          Column({ space: 4 }) {
            Text('AI 辅助分析').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
            Text('查看已有报告或主动发起分析').fontSize(12).fontColor(this.theme.textSecondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textSecondary })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 64 }).padding(12).borderRadius(12)
        .backgroundColor(Color.Transparent).border({ width: 1, color: this.theme.divider })
        .enabled(!this.sharing && !this.exportingEvidence)
        .onClick(() => { this.showAiResult = true })
      if (this.sharedLog !== undefined || this.authorSubmissionId.length > 0) { this.ShareReceipt_() }
      if (this.shareError.length > 0) { Text(this.shareError).fontSize(12).fontColor(this.theme.error).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 主操作固定在详情底部，长诊断/AI 内容不会把查看与分享推到屏幕之外。 */
  @Builder
  private OverviewActions_() {
    Row({ space: 12 }) {
              if (this.viewportWidth >= 620) {
                Text('原始日志与分享').fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
              }
              Button('查看相关日志').height(44).width(this.viewportWidth >= 620 ? 170 : '48%').fontSize(14).borderRadius(10)
                .backgroundColor(this.theme.actionPrimary).fontColor(this.theme.textOnPrimary)
                .onClick(() => { this.openRelevantLog_() })
              Button('分享日志').height(44).width(this.viewportWidth >= 620 ? 130 : '48%').fontSize(14).borderRadius(10)
                .backgroundColor(this.theme.primaryLight).fontColor(this.theme.primary)
                .enabled(!this.sharing && !this.exportingEvidence).onClick(() => { this.openShareComposer_() })
            }.width('100%').padding({ top: 12 }).border({ width: { top: 1 }, color: this.theme.divider })
  }

  /** 文件抽屉只改变阅读来源；不与分享多选共用选择状态。 */
  @Builder
  private FilePicker_() {
    Scroll() { this.EvidenceList_() }.width('100%').height('100%').padding(20).align(Alignment.TopStart)
  }

  /** 明确关系与同版本历史分开标注；每个入口仍打开独立活动，不合并原件或退出结局。 */
  @Builder
  private RelatedActivities_() {
    if (this.relatedActivities.length > 0) {
      Column({ space: 8 }) {
        Button((this.showRelated ? '收起' : '查看') + '关联与同版本记录 · ' + this.relatedActivities.length)
          .height(44).fontSize(13).fontColor(this.theme.primary).backgroundColor(Color.Transparent)
          .onClick(() => { this.showRelated = !this.showRelated })
        if (this.showRelated) {
          ForEach(this.relatedActivities, (related: LedgerRelatedActivity) => {
            Button() {
              Column({ space: 4 }) {
                Text(related.relation + ' · ' + ledgerStateLabel(related.state)).fontSize(12).fontColor(this.theme.primary)
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
        AppIcon({ name: AppIconName.Search, iconSize: 18, color: this.theme.primary })
        Text('本地排查').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
        if (this.diagnosisProgress.length > 0) { LoadingProgress().width(20).height(20).color(this.theme.primary) }
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
                Text(finding.title).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
                  .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(finding.explanation).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
                Text(finding.fileName + ' · 原文 ' + finding.line + '–' + finding.endLine + ' 行'
                  + (finding.occurrences > 1 ? ' · 多份日志出现 ' + finding.occurrences + ' 次' : ''))
                  .fontSize(11).fontColor(this.theme.primary).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').padding(12).borderRadius(12).backgroundColor(this.theme.bgInput)
              .onClick(() => { this.openEvidenceAt_(finding.fileId, finding.line) })
          }, (finding: ActivityFinding): string => finding.fileId + ':' + finding.line)
          if (this.diagnosis.findings.length > 3) {
            Button(this.showAllFindings ? '收起其他线索' : '查看其他线索（' + this.diagnosis.findings.length + ' 组）')
              .height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.primary)
              .onClick(() => { this.showAllFindings = !this.showAllFindings })
          }
        }
        if (this.diagnosis.phases.length > 0) {
          Button((this.showPhaseList ? '收起' : '查看') + '有证据的启动阶段 · ' + this.diagnosis.phases.length)
            .height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.theme.primary)
            .onClick(() => { this.showPhaseList = !this.showPhaseList })
          if (this.showPhaseList) {
            ForEach(this.diagnosis.phases, (phase: ActivityPhase) => {
              Button() {
                Column({ space: 4 }) {
                  Text('• ' + phase.title).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
                  Text(phase.detail).fontSize(12).fontColor(this.theme.textSecondary).maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(phase.fileName + ':' + phase.line).fontSize(11).fontColor(this.theme.primary)
                }.width('100%').alignItems(HorizontalAlign.Start)
              }.width('100%').padding(8).backgroundColor(Color.Transparent)
                .onClick(() => { this.openEvidenceAt_(phase.fileId, phase.line) })
            }, (phase: ActivityPhase): string => phase.key)
          }
        }
        if (this.diagnosis.gaps.length > 0) {
          Text('扫描边界：' + this.diagnosis.gaps.join('；')).fontSize(12).fontColor(this.theme.warning).width('100%')
        }
      }
      if (this.diagnosisError.length > 0) {
        Text('本地排查未完成：' + this.diagnosisError).fontSize(12).fontColor(this.theme.warning).width('100%')
        Button('重试本地排查').height(44).onClick(() => { this.loadDiagnosis_() })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(12)
      .backgroundColor(this.theme.bgCard).border({ width: 1, color: this.theme.divider })
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
      { text: this.wrapLines ? '关闭自动换行' : '开启自动换行', color: this.theme.primary as string },
      { text: '字号：' + this.readerFontSize + '（点击切换）', color: this.theme.primary as string },
      { text: this.collapseEvents ? '展开全部事件' : '折叠长事件', color: this.theme.primary as string },
      { text: this.searchAllFiles ? '仅搜索当前文件' : '搜索本次全部日志', color: this.theme.primary as string },
      { text: '导出完整日志包（脱敏 ZIP）', color: this.theme.primary as string },
      { text: this.followLatest ? '暂停跟随最新日志' : '跟随最新日志', color: this.theme.primary as string },
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
              color: this.readableFile_(file) ? this.theme.primary : this.theme.textHint })
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

  /** 活动身份、退出结果和采集完整性分层呈现；文件数量不暗示内容完整。 */
  @Builder
  HeaderCard_() {
    Column({ space: 12 }) {
      if (this.currentStorageIssue.length > 0) {
        Text('当前日志存储：' + this.currentStorageIssue).fontSize(12).fontColor(this.theme.warning).width('100%')
      }
      Row({ space: 8 }) {
        if (this.manifest !== null) {
          AppIcon({ name: this.manifest.category === ActivityCategory.LAUNCH ? AppIconName.GameController : AppIconName.Download,
            iconSize: 18, color: this.theme.primary })
          Text(this.categoryLabel_(this.manifest.category) + '记录').fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
          // 使用 API 20 的背景/圆角绘制装饰点，避免新版 fill 重载。
          Row().width(6).height(6).backgroundColor(this.stateColor_(this.manifest.state)).borderRadius(3).accessibilityLevel('no')
          Text(ledgerStateLabel(this.manifest.state))
            .fontSize(12).fontWeight(600)
            .fontColor(this.stateColor_(this.manifest.state))
        } else {
          Text(this.diagnosisTitle || '历史活动').fontSize(20).fontWeight(600).fontColor(this.theme.textPrimary)
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      if (this.manifest !== null) {
        Text(this.manifest.title).fontSize(22).fontWeight(600).fontColor(this.theme.textPrimary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (this.pinned) {
          Text('已保留 · 不会自动清理').fontSize(12).fontColor(this.theme.primary).width('100%')
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          Text(this.activityTime_()).fontSize(12).fontColor(this.theme.textSecondary).margin({ right: 20, bottom: 6 })
          if (this.durationLabel_().length > 0) {
            Text('用时 ' + this.durationLabel_()).fontSize(12).fontColor(this.theme.textSecondary).margin({ right: 20, bottom: 6 })
          }
          Text(this.savedEvidenceCount_() + ' 个文件可读').fontSize(12).fontColor(this.theme.textSecondary).margin({ bottom: 6 })
        }.width('100%')

        if (this.manifest.outcomeSummary.length > 0) {
          Text(this.manifest.outcomeSummary)
            .fontSize(14).lineHeight(22)
            .fontColor(this.stateColor_(this.manifest.state))
            .width('100%')
        }
        Button() {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Document, iconSize: 16, color: this.theme.textSecondary })
            Column({ space: 4 }) {
              Text(this.evidenceIntegrityLabel_()).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              Text(this.showCaptureDetails ? '收起采集详情' : '查看采集详情与缺口').fontSize(12).fontColor(this.theme.primary).width('100%')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: this.showCaptureDetails ? AppIconName.ChevronUp : AppIconName.ChevronDown, iconSize: 14, color: this.theme.textSecondary })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 52 }).padding(10).borderRadius(10)
          .backgroundColor(this.theme.bgInput).onClick(() => { this.toggleCapture_() })
        if (this.showCaptureDetails) {
          Scroll() {
            Column({ space: 8 }) {
              Text('采集版本：' + this.evidenceRevision + ' · 登记来源 ' + this.evidenceFiles.length)
                .fontSize(12).fontColor(this.theme.textSecondary)
              if (this.manifest.errorKind.length > 0) Text('错误类型：' + this.manifest.errorKind).fontSize(12).fontColor(this.theme.textSecondary)
              if (this.evidenceMissingReasons.length > 0) Text('缺口：' + this.evidenceMissingReasons.join('；')).fontSize(12).fontColor(this.theme.warning)
              ForEach(this.evidenceFiles, (file: EvidenceFileRecord) => {
                Text(evidenceRoleLabel(file.role) + '：' + evidenceCaptureLabel(file, this.manifest?.state === LedgerState.RUNNING)
                  + ' · ' + file.attribution + (file.reason.length > 0 ? ' · ' + file.reason : ''))
                  .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
              }, (file: EvidenceFileRecord): string => file.fileId)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.width('100%').constraintSize({ maxHeight: 140 })
        }
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
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
              .fontColor(!this.viewingEvidence && this.activePart === p ? this.theme.primary : this.theme.textSecondary)
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
                    ? this.theme.primary : this.theme.textSecondary)
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

  /** 级别过滤 + 搜索 + 跳到首个错误。 */
  @Builder
  ToolBar_() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Row({ space: 6 }) {
          this.LevelChip_(LevelFilter.ALL, '全部')
          this.LevelChip_(LevelFilter.WARN_UP, '警告及以上')
          this.LevelChip_(LevelFilter.ERROR_UP, '错误')
        }
        Blank()
        Button('刷新').height(44).fontSize(12).fontColor(this.theme.primary).backgroundColor(Color.Transparent)
          .enabled(!this.reading).onClick(() => { this.load_(true) })
      }
      .width('100%').alignItems(VerticalAlign.Center)

      if (this.showSearch) {
        TextInput({ placeholder: this.searchAllFiles ? '搜索本次全部日志（保留完整事件）' : '搜索当前文件（保留完整事件）', text: this.keyword })
          .fontSize(13)
          .height(44)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(8)
          .width('100%')
          .onChange((v: string) => { this.search_(v) })
      }

    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  LevelChip_(f: LevelFilter, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.levelFilter === f ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.levelFilter === f ? this.theme.primary : this.theme.textSecondary)
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .constraintSize({ minHeight: 44, minWidth: 52 }).textAlign(TextAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.levelFilter === f ? this.theme.primaryLight : this.theme.bgCard)
      .enabled(!this.reading)
      .onClick(() => { this.levelFilter = f; this.applyFilter_() })
  }

  /** 事件操作保持原来源；定位上下文会清除筛选，避免让用户误以为上下文不存在。 */
  private eventActions_(row: LogRow): void {
    this.getUIContext().getPromptAction().showActionMenu({ title: '日志事件 · 原文 ' + (row.event?.startLine ?? row.lineNumber)
      + '–' + (row.event?.endLine ?? row.lineNumber) + ' 行', buttons: [
      { text: this.model.isEventExpanded(row.eventId ?? '') ? '收起事件' : '展开完整事件', color: this.theme.primary as string },
      { text: '复制事件（脱敏）', color: this.theme.primary as string },
      { text: '查看原文件上下文', color: this.theme.primary as string },
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
      Row({ space: 8 }) {
        Text(this.reading ? '正在读取完整事件…' : (this.showingTail ? '最新窗口 · ' : '') + this.matchingEvents + ' 个事件 · ' + this.matchingLines + ' 行')
          .fontSize(12).fontColor('#94A3B8').layoutWeight(1)
        Button('本页末尾').fontSize(12).height(44).fontColor('#7DD3FC').backgroundColor(Color.Transparent)
          .onClick(() => { this.scroller.scrollEdge(Edge.Bottom) })
      }.width('100%').height(44).padding({ left: 12, right: 8 }).backgroundColor('#171E2B')
      if (this.followLatest) {
        Button('正在跟随最新日志 · 点击暂停').height(40).fontSize(12).onClick(() => { this.stopFollowing_() })
      } else if (this.showingTail) {
        Button('已暂停跟随 · 返回完整分页').height(40).fontSize(12).onClick(() => { this.fromLine = 0; this.loadCurrentPage_(0) })
      }
      if (this.fromLine > 0) {
        Button('正在查看局部上下文 · 返回文件开头').height(40).fontSize(12)
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
                    Text(this.sourceLabel_(row)).fontSize(12).fontColor('#7DD3FC')
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
                      .backgroundColor('#192332').borderRadius(0).onClick(() => { this.eventActions_(row) })
                  }
                  if (row.event?.format !== 'xml' || this.model.isEventExpanded(row.eventId ?? '')) {
                    Row() {
                      Text(row.continuation ? '·' : String(row.sourceLineNumber ?? row.lineNumber))
                        .fontSize(11).fontFamily('monospace').fontColor('#64748B').width(52)
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
            .width(this.wrapLines ? '100%' : Math.max(this.viewportWidth - 32, this.model.maxLineLength() * this.readerFontSize * 0.65 + 76))
            .height('100%').cachedCount(8).scrollBar(BarState.Auto)
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto)
      }
    }.width('100%').layoutWeight(1).borderRadius(12).clip(true).backgroundColor('#0F141D')
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
    this.analyzeAfterShare = params?.['requestAi'] === true
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

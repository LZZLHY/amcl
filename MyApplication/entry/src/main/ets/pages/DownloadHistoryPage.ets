/**
 * 活动记录外围的统计、错误提示和确认按钮使用对应状态前景色，配套已有状态浅底；
 * 时间线、记录过滤、日志清理确认与专业日志阅读的配色和行为不在此调整。
 */
import { applyNativeTheme } from '../components/AppTheme';
/**
 * DownloadHistoryPage.ets — 活动账本 V2（保留原路由名兼容旧入口）
 *
 * 从历史存储与账本读取真实活动，按本地日期分组，支持关键词与类别筛选。
 * 手机打开独立详情；840vp 起复用同一个证据工作区，列表直接展示 AI 摘要。
 *
 * 数据源：features/download/DownloadHistory.DownloadHistoryStore（Preferences 持久化 LRU）
 *
 * 入口：SettingsTab "下载历史" 行 → router.pushUrl('pages/DownloadHistoryPage')
 *
 * 创建日期：2026-05-06
 */

import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import {
  DownloadHistoryRecord,
  DownloadHistoryReadSnapshot,
  getDownloadHistoryStore,
  ActivityCategory,
  ActivityStatus,
} from 'feature_core';
import { formatBytes } from 'feature_core';
import { formatDurationMs } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { LayerRetreatPolicy, RetreatFrame, retreatLayerHeight, retreatLayerOffset,
  retreatStableInset, retreatLeadItemHeight, retreatNeedsTopRestore } from '../components/LayerRetreatPolicy';

// M3：会话快照 —— 判定日志是否还在保留窗口内 + 反查落点
import { isReopenableRecord, resolveSessionSnapshot } from '../components/McSessionSnapshot';
// 活动账本（L5）：任何有账本的活动都能查看完整日志
import { ledgerClearAsync, ledgerClearBlockReasonAsync } from 'commons';
import { formatLogBytes } from 'commons';
import {
  ledgerArchiveCompletedSessions,
} from 'commons';

import { ActivityAiCard } from '../components/ActivityAiCard';
import { ActivityShareSheet } from '../components/ActivityShareSheet';
import { DeviceProfile, DeviceForm, centerSheetForLayout, detailSheetHeightForLayout, sheetWidthForLayout } from 'commons';
import { ActivityTimelineItem } from '../components/ActivityTimelineItem';
import { AnimatedPillBar } from '../components/AnimatedPillBar';
import { MotionSection } from '../components/MotionSection';
import { ActivityPaneMotion } from '../components/ActivityPaneMotion';
import { UiMotion } from '../components/UiMotion';
import { ActivityLogWorkspace } from './ActivityLogPage';
import { ActivityStoragePanel } from '../components/ActivityStoragePanel';
import { activityStorageAlert } from 'commons';
import { ActivityListDataSource, ActivityListRow } from '../components/ActivityListDataSource';
import { ActivityFilter, ActivityDayGroup, ActivityDayStats, matchesActivity, groupActivities,
  activityTodayStats, activityCategory, activityCategoryLabel, activityStatusLabel, isAbnormalActivity,
  ActivityStatusBand, activityStatusBands, activityClock, activityDisplayTitle } from '../components/ActivityUiModel';

const TAG = 'DownloadHistory'
const ACTIVITY_FILTERS: ActivityFilter[] = [ActivityFilter.ALL, ActivityFilter.GAME, ActivityFilter.DOWNLOAD, ActivityFilter.EXPORT, ActivityFilter.ABNORMAL]

@Entry
@Component
struct DownloadHistoryPage {
  /** 独立账本页面消费同一已保存比例，手机分享与管理面板不另行固定高度。 */
  @StorageProp('phoneSheetHeightPercent') private phoneSheetHeightPercent_: number = 80;
  @State records: DownloadHistoryRecord[] = []
  @State loaded: boolean = false
  /** 筛选、分组和概览只来自真实记录；读取失败不伪装为空列表。 */
  @State private query: string = ''
  @State private activeFilter: ActivityFilter = ActivityFilter.ALL
  @State private groups: ActivityDayGroup[] = []
  @State private stats: ActivityDayStats = { total: 0, completed: 0, interrupted: 0, failed: 0 }
  @State private viewportWidth: number = 0
  @State private refreshing: boolean = false
  @State private loadError: string = ''
  @State private selectedRecords: DownloadHistoryRecord[] = []
  @State private detailRevision: number = 0
  @State private selectionBusy: boolean = false
  @State private selectedId: number = 0
  @State private readerFocused: boolean = false
  @State private hostVisible: boolean = true
  /**
   * 活动账本试点仅退让搜索下方的分类与统计，标题和搜索节点始终留在原父级。
   * hidden为累计让出的vp高度；分类先消耗，统计后消耗，反向滑动按相反顺序恢复。
   * 手动统计展开由overviewExpanded独立持有，不把用户偏好写进临时滚动状态。
   */
  @State private retreatHidden_: number = 0
  /** 冻结的内容首占位，不跟随统计/分类收展；负值只用于新数据或窗口上下文重测。 */
  @State private retreatAnchorInset_: number = -1
  /** 整层端点与视觉动画分离；旧动画完成不能解除新动画的测量/命中保护。 */
  @State private retreatAnimating_: boolean = false
  @State private retreatHitHeight_: number = 0
  private retreatAnimationEpoch_: number = 0
  @State private retreatFilterHeight_: number = 0
  @State private retreatOverviewHeight_: number = 0
  /** 只在辅助区完全展开时评估列表是否超出一屏，收展过程不反复改变可滚资格。 */
  private retreatScrollable_: boolean = false
  private retreatSearchFocused_: boolean = false
  private retreatViewportHeight_: number = 0
  private retreatPolicy_: LayerRetreatPolicy = new LayerRetreatPolicy()
  /** 只绑定左活动List；右侧日志工作区没有此控制器。 */
  private retreatScroller_: Scroller = new Scroller()
  private retreatReturning_: boolean = false
  private retreatTouchActive_: boolean = false
  /** 路由隐藏/销毁撤销旧读取；在途返回或元数据变更合并为下一轮，不复用取消中的请求。 */
  private refreshGeneration_: number = 0
  private refreshAgain_: boolean = false
  /** 展示行数据源保持身份不变，LazyForEach 只构建当前视口，不提前构造所有日期/卡片。 */
  private activityRows_: ActivityListDataSource = new ActivityListDataSource()
  @State private overviewExpanded: boolean = false
  @State private showStorage: boolean = false
  @State private storageAlertBytes: number = 0
  private pendingStorageActivity: number = 0
  /** 分享覆盖在账本上，不先跳详情；主键固定为本次用户点击的活动。 */
  @State @Watch('shareVisibilityChanged_') private showQuickShare: boolean = false
  @State private shareNonce: number = 0
  @State private shareRecords: DownloadHistoryRecord[] = []
  @State private shareMode: string = 'quick'
  private availability: Map<number, boolean> = new Map<number, boolean>()
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  /** 顶/底部安全区高度（状态栏 / 导航条避让），与其它全屏 push 页一致。 */
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  /** 系统深浅色：变化时重算主题，跟随全局主题统一。 */
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('onColorModeChange') private appThemeRevision: number = 0;
  /** 正在上传的记录 key（startedAt 字符串）；非空表示该条上传中，UI 禁用按钮。 */
  @State uploadingKey: string = ''
  @State private clearing: boolean = false
  @State private confirmingClear_: boolean = false
  private clearGeneration_: number = 0
  @State private clearError: string = ''
  /** 活动账本总占用字节（L5：让用户知道日志吃了多少空间）。 */
  @State private ledgerBytes: number = 0
  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility 缓存。
  // 详见 docs/guides/api-migration-2026-05.md。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    this.applyTheme_()
    // 首次路由进入随后必经 onPageShow；这里仅初始化主题。原先两处都读取，
    // 已就绪的存储会在生命周期间兑现微任务，导致同一首屏重复扫描账本、
    // 推进详情世代并重建列表。由显示事件统一读取，返回此页时仍取得最新记录。
  }

  /** 首次显示与路由返回共用同一刷新入口；在途防重和发送/导出保护仍由原刷新方法负责。 */
  onPageShow(): void { this.applyTheme_();  this.hostVisible = true; this.refreshRecords() }
  onPageHide(): void {
    this.retreatReturning_ = false
    this.retreatTouchActive_ = false
    this.hostVisible = false; this.refreshGeneration_++; this.refreshAgain_ = false; this.clearGeneration_++
    // 离页不保留上一段手势的方向累计；业务读取与确认代次继续走原有退役路径。
    this.retreatPolicy_.reset()
    this.retreatSearchFocused_ = false
    this.retreatAnimationEpoch_++
    this.retreatAnimating_ = false
  }

  /** 页面销毁即取消未完成只读投影，旧finally也不能在销毁后补发刷新。 */
  aboutToDisappear(): void { this.onPageHide() }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark), this.prefManager.themeAccent)
    applyNativeTheme(this.theme);
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  /**
   * 只读投影使用索引/原清单异步 IO，不在显示回调同步读取全历史或日志正文。
   * 一次性发布同轮结局、可用性和占用；失败保留旧列表，离页结果不改状态或详情。
   */
  private async refreshRecords(): Promise<void> {
    if (!this.hostVisible || this.selectionBusy) return
    if (this.refreshing) { this.refreshAgain_ = true; return }
    // 刷新属于显式的新内容上下文，恢复工具入口但不新建列表或改动数据读取流程。
    this.resetRetreat_(true)
    const generation: number = ++this.refreshGeneration_
    const cancelled: () => boolean = (): boolean => !this.hostVisible || generation !== this.refreshGeneration_
    this.refreshing = true
    this.refreshAgain_ = false
    this.loadError = ''
    try {
      const store = getDownloadHistoryStore()
      await store.init(this.context)
      if (cancelled()) return
      const snapshot: DownloadHistoryReadSnapshot = await store.readSnapshotAsync(cancelled)
      if (cancelled()) return
      this.records = snapshot.records
      this.availability.clear()
      for (const id of snapshot.ledgerIds) this.availability.set(id, true)
      this.ledgerBytes = snapshot.ledgerBytes
      this.loaded = true
      this.storageAlertBytes = activityStorageAlert(this.context.filesDir)
      this.detailRevision++
      this.updateGroups_()
      AppStorage.setOrCreate<number>('activityLedgerRevision', Date.now())
    } catch (e) {
      if (!cancelled()) this.loadError = '活动记录读取失败：' + (e as Error).message
    } finally {
      this.refreshing = false
      if (this.refreshAgain_ && this.hostVisible && !this.selectionBusy) {
        this.refreshAgain_ = false
        this.refreshRecords()
      }
    }
  }

  /** 用户筛选不改变持久数据；平板选中项消失时清空详情，避免显示不在列表中的活动。 */
  private updateGroups_(): void {
    const visible: DownloadHistoryRecord[] = this.records.filter((record: DownloadHistoryRecord): boolean =>
      matchesActivity(record, this.query, this.activeFilter))
    this.groups = groupActivities(visible, Date.now())
    this.activityRows_.replace(this.groups, this.detailRevision)
    this.stats = activityTodayStats(this.records, Date.now())
    const selected = visible.find((record: DownloadHistoryRecord): boolean => record.startedAt === this.selectedId)
    if (selected !== undefined) this.selectedRecords = [selected]
    else if (visible.length > 0) { this.selectedRecords = [visible[0]]; this.selectedId = visible[0].startedAt }
    else { this.selectedRecords = []; this.selectedId = 0 }
  }

  /**
   * 恢复临时辅助区并丢弃旧方向。query/filter/刷新/尺寸变化还需重新评估短内容，
   * 普通获焦或统计手动展开只复位展示，不修改已经选中的分类、查询或活动。
   */
  private resetRetreat_(recheckContent: boolean = false): void {
    this.retreatReturning_ = false
    this.retreatTouchActive_ = false
    this.retreatAnimationEpoch_++
    this.retreatAnimating_ = false
    this.retreatHitHeight_ = 0
    this.retreatHidden_ = 0
    this.retreatPolicy_.reset()
    if (recheckContent) {
      this.retreatScrollable_ = false
      this.retreatAnchorInset_ = -1
    }
  }

  /** 当前需要释放的自然布局高度包含各层尾部间距，不把隐藏层间的空白留在列表上方。 */
  private retreatTotalHeight_(): number {
    return this.retreatFilterHeight_ + this.retreatOverviewHeight_
  }

  /** 本地触点观察仅用于排除拖动中的旧stop事件，不抢占任何手势。 */
  private observeRetreatTouch_(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.retreatPolicy_.cancelQueuedContinuation()
      this.retreatTouchActive_ = true
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.retreatTouchActive_ = false
      this.retreatPolicy_.cancelQueuedContinuation()
    }
  }

  private observeRetreatStop_(): void {
    if (!this.retreatTouchActive_) this.retreatPolicy_.cancelQueuedContinuation()
    this.restoreRetreatAtStart_(!this.retreatTouchActive_)
  }

  private observeRetreatPosition_(offset: number, state: ScrollState): void {
    if (!this.hostVisible) return
    if (offset < -0.01) this.retreatReturning_ = true
    else if (state === ScrollState.Scroll && offset > 0.01) this.retreatReturning_ = false
    this.restoreRetreatAtStart_()
  }

  /** 真实到顶直接补全自动恢复，保留手动统计偏好、冻结首占位与原记录身份。 */
  private restoreRetreatAtStart_(settled: boolean = false): boolean {
    if (!this.hostVisible || !this.loaded || this.groups.length === 0 || this.retreatHidden_ <= 0
      || (this.readerFocused && this.viewportWidth >= 840)) return false
    try {
      const position: OffsetResult = this.retreatScroller_.currentOffset()
      if (!position || !retreatNeedsTopRestore(this.retreatHidden_, position.yOffset,
        this.retreatReturning_, settled && !this.retreatTouchActive_)) return false
    } catch (_) { return false }
    this.retreatPolicy_.reset()
    this.animateRetreatTo_(0)
    return true
  }

  /** 未浏览前使用自然工具区高度；首次实际滚动后该内容坐标基准保持不变。 */
  private retreatListInset_(): number {
    return retreatStableInset(this.retreatAnchorInset_, this.retreatTotalHeight_())
  }

  /** 显式统计开关也先冻结，恢复/收起工具区不会把正在看的记录推走。 */
  private freezeRetreatAnchor_(): void {
    if (this.retreatAnchorInset_ < 0 && this.retreatFilterHeight_ > 0 && this.retreatOverviewHeight_ > 0) {
      this.retreatAnchorInset_ = this.retreatListInset_()
    }
  }

  /** 完全退场的覆盖层不参与命中，显示时阻止下面的记录透出或被误点。 */
  private retreatOverlayHeight_(hidden: number = this.retreatHidden_): number {
    return retreatLayerHeight(this.retreatFilterHeight_, hidden, 0)
      + retreatLayerHeight(this.retreatOverviewHeight_, hidden, this.retreatFilterHeight_)
  }

  private retreatInputEnabled_(): boolean {
    return this.hostVisible && this.loaded && this.groups.length > 0 && this.retreatAnchorInset_ >= 0
      && this.retreatScrollable_ && !this.refreshing && !this.selectionBusy && !this.retreatSearchFocused_
      && !this.showQuickShare && !this.showStorage && (!this.readerFocused || this.viewportWidth < 840)
  }

  /**
   * 内层保持自然高度，外层只裁剪并让出占位。尺寸回调只写真实变化，避免滚动每帧
   * 重置进度；完全展开且整层动画已结束后才重新接受统计/字体变化的自然高度。
   */
  private measureRetreatLayer_(filter: boolean, area: Area): void {
    // 裁剪中的测量已受父层可见高度约束，不能把它回写成自然高而缩掉退让容量。
    if (this.retreatHidden_ > 0 || this.retreatAnimating_) return
    const measured: number = Number(area.height)
    if (!Number.isFinite(measured) || measured <= 0) return
    const previous: number = filter ? this.retreatFilterHeight_ : this.retreatOverviewHeight_
    if (Math.abs(previous - measured) <= 0.5) return
    if (filter) this.retreatFilterHeight_ = measured
    else this.retreatOverviewHeight_ = measured
    this.retreatHidden_ = Math.min(this.retreatHidden_, this.retreatTotalHeight_())
  }

  /**
   * 当前可见首末行只在完全展开的参考视口中参与短内容判断。保守地将首尾同时可见
   * 的列表视作短内容，确保空态、短历史与其分类/刷新入口始终可达；隐藏期间不反馈
   * 当前扩大的视口，避免可滚资格与头部高度互相驱动而振荡。
   */
  private updateRetreatScrollable_(start: number, end: number): void {
    if (this.retreatHidden_ > 0) return
    const count: number = this.activityRows_.totalCount()
    // 第0项是固定内容首占位，真实LazyForEach行索引整体加1。
    this.retreatScrollable_ = count > 0 && (start > 1 || end < count)
  }

  /**
   * 只在左侧活动List观察方向段并触发一次整层平移，列表原始位移始终完整放行。
   * 完全隐藏时仍由同一可见List接收反向输入，右侧详情与Sheet没有这一绑定。
   * 初载/刷新、搜索编辑、分享/管理覆盖层及专业阅读期间均不抢占正文位移。
   */
  private retreatScrollFrame_(offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult {
    if (state === ScrollState.Scroll) {
      if (offset < -0.01) this.retreatReturning_ = true
      else if (offset > 0.01) this.retreatReturning_ = false
      if (offset < -0.01 && this.restoreRetreatAtStart_()) return { offsetRemain: offset }
    }
    if (state === ScrollState.Scroll) this.freezeRetreatAnchor_()
    const frame: RetreatFrame = this.retreatPolicy_.step(offset, this.retreatHidden_,
      [this.retreatFilterHeight_, this.retreatOverviewHeight_], this.retreatInputEnabled_(), state === ScrollState.Scroll)
    this.animateRetreatTo_(frame.hidden)
    return { offsetRemain: frame.offsetRemain }
  }

  /** 普通逐层和到顶补全复用同一动画世代，旧完成不能覆盖新的上滑方向。 */
  private animateRetreatTo_(next: number): void {
    if (next !== this.retreatHidden_) {
      const epoch: number = ++this.retreatAnimationEpoch_
      this.retreatHitHeight_ = Math.max(this.retreatHitHeight_, this.retreatOverlayHeight_(), this.retreatOverlayHeight_(next))
      this.retreatAnimating_ = true
      this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut,
        onFinish: (): void => {
          if (epoch !== this.retreatAnimationEpoch_) return
          this.retreatAnimating_ = false
          this.retreatHitHeight_ = 0
          if (this.restoreRetreatAtStart_()) return
          const continuation: RetreatFrame = this.retreatPolicy_.finishTransition(this.retreatHidden_,
            [this.retreatFilterHeight_, this.retreatOverviewHeight_], this.retreatInputEnabled_(), this.retreatTouchActive_)
          this.animateRetreatTo_(continuation.hidden)
        } }, (): void => { this.retreatHidden_ = next })
    }
  }

  /** 平板侧栏只切换选中活动，手机则进入相同工作区的路由包装。 */
  private openOverview_(record: DownloadHistoryRecord): void {
    if (this.selectionBusy) { this.safeToast_('正在发送或导出，请稍后切换活动'); return }
    // 导出记录的主行动是恢复任务结果，读取私有记录后由向导展示其真实请求与终态。
    // 不能把导出当成下载日志，也不依赖当前首页版本或自动重新写入用户保存目标。
    if (this.cat_(record) === ActivityCategory.GAME_EXPORT) { this.openGameExport_(record); return }
    if (this.viewportWidth >= 840) {
      if (this.selectedId === record.startedAt) return
      this.selectedId = record.startedAt
      this.selectedRecords = [record]
    } else {
      const params: Record<string, Object> = { 'activityId': record.startedAt, 'view': 'overview',
        'diagnosisTitle': this.cardTitle_(record) }
      try {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
          .catch((): void => { this.safeToast_('无法打开活动详情，请重试') })
      } catch (e) { this.safeToast_('无法打开活动详情，请重试') }
    }
  }

  /** 历史只传递受控任务身份；目标 URI 留在私有任务记录，路由不会恢复执行授权。 */
  private async openGameExport_(record: DownloadHistoryRecord): Promise<void> {
    const id: string = record.exportTaskId ?? ''
    if (!/^[0-9]+-[a-zA-Z0-9-]+$/.test(id) || !record.mcDir) {
      this.safeToast_('这条导出记录缺少可恢复的任务身份，请从版本管理重新导出')
      return
    }
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/GameExportPage',
        params: { 'mcRoot': record.mcDir, 'versionId': record.versionName, 'taskId': id } })
    } catch (e) { this.safeToast_('无法打开导出结果：' + (e as Error).message) }
  }

  /** 占用与撤回集中在管理菜单，不再用常驻页脚挤占活动列表；取消不产生任何副作用。 */
  private manage_(): void {
    try {
    // 占用来自最近成功投影；打开菜单不重新同步扫描全部目录，详细面板仍可请求最新计量。
    this.getUIContext().getPromptAction().showActionMenu({
      title: '管理活动账本 · ' + (this.ledgerBytes < 0 ? '占用暂不可读' : '日志占用 ' + formatLogBytes(this.ledgerBytes)),
      buttons: [
        { text: '分享记录与撤回', color: this.theme.actionText as string },
        { text: '清空本地记录与日志', color: this.theme.errorText as string },
        { text: '日志占用、保留与空间提醒', color: this.theme.actionText as string },
      ],
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) this.getUIContext().getRouter().pushUrl({ url: 'pages/LogShareHistoryPage' })
      else if (result.index === 2) this.showStorage = true
      else if (this.canClear_()) this.confirmClearAll_()
      else this.safeToast_('当前没有可清理的活动，或操作仍在进行中')
    }).catch((): void => {})
    } catch (e) { this.safeToast_('无法打开管理菜单，请重试') }
  }

  /** 行渲染不再遍历磁盘；可用性在刷新阶段形成快照。 */
  private hasEvidence_(record: DownloadHistoryRecord): boolean { return this.availability.get(record.startedAt) === true }

  /** 侧边详情关闭/删除后重新读取，保留网络与本地清理的原有确认边界。 */
  private closeDetail_(): void {
    this.selectedId = 0
    this.selectedRecords = []
    this.selectionBusy = false
    this.refreshRecords()
  }

  private safeToast_(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 })
    } catch (e) { /* ignore */ }
  }

  /** 快捷按钮只开启公开默认分享，不自动提交作者或启动 AI。 */
  private doUploadActivity_(record: DownloadHistoryRecord): void {
    if (this.selectionBusy) return
    this.shareRecords = [record]; this.shareMode = 'quick'; this.showQuickShare = true
  }

  private shareVisibilityChanged_(): void { if (this.showQuickShare) this.shareNonce++ }

  private recordMenu_(record: DownloadHistoryRecord): void {
    if (this.selectionBusy) return
    this.getUIContext().getPromptAction().showActionMenu({ title: this.cardTitle_(record), buttons: [
      { text: '自定义分享与预览', color: this.theme.actionText as string },
      { text: '查看原始日志', color: this.theme.actionText as string },
      { text: '查看活动详情', color: this.theme.actionText as string },
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) { this.shareRecords = [record]; this.shareMode = 'advanced'; this.showQuickShare = true }
      else if (result.index === 1) this.openActivityLog_(record)
      else if (result.index === 2) this.openOverview_(record)
    }).catch((): void => {})
  }

  private ledgerShareOptions_(): SheetOptions {
    const form = DeviceProfile.form(); const breakpoint = DeviceProfile.breakpointOf(this.viewportWidth)
    const center: boolean = centerSheetForLayout(form, breakpoint)
    const height: number = detailSheetHeightForLayout(form, breakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_)
    return { height: form !== DeviceForm.PHONE && this.shareMode === 'quick' ? Math.min(height, 440) : height,
      width: sheetWidthForLayout(form, breakpoint), preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
      // 内容组件的统一原生标题负责 X；消失收口仍在本宿主，拖拽/系统返回也会执行。
      showClose: false, dragBar: !center, backgroundColor: this.theme.bgPrimary,
      onDisappear: (): void => { this.showQuickShare = false; this.selectionBusy = false; this.detailRevision++ } }
  }

  @Builder
  private LedgerShare_() {
    Column() {
      ForEach(this.shareRecords, (record: DownloadHistoryRecord) => {
        ActivityShareSheet({ activityId: record.startedAt, initialMode: this.shareMode, theme: this.theme,
          onClosed: (): void => { this.showQuickShare = false },
          onAdvancedChanged: (advanced: boolean): void => { if (advanced) this.shareMode = 'advanced' },
          onBusyChanged: (busy: boolean): void => { this.selectionBusy = busy },
          onShared: (): void => { this.detailRevision++ } })
      }, (record: DownloadHistoryRecord): string => String(record.startedAt) + '-' + this.shareNonce)
    }.width('100%').height('100%')
  }

  /**
   * 该条记录的日志是否已超出保留窗口（M3）。
   *
   * 优先查会话快照，旧记录回退到工作日志。两处均不可用时置灰说明。
   *
   * 每次 build 都会调，findSessionLog 只探测两种目录布局的日志头，
   * 开销可以接受；真成瓶颈再加缓存。
   */
  private logExpired_(record: DownloadHistoryRecord): boolean {
    let mcRoot = (AppStorage.get<string>('mcDir') as string) || ''
    if (mcRoot.length === 0) return true
    return resolveSessionSnapshot(record, mcRoot).logExpired
  }

  /**
   * 请求 Index 打开该会话的错误 Sheet（M3）。
   *
   * 错误 Sheet 挂在 Index 上（`bindSheet` 锚点），本页是 router 独立页，没法直接开。
   * 沿用项目里已有的做法：把请求写进 AppStorage，Index 用 `@StorageLink` + `@Watch`
   * 消费（与 `pendingLayoutImportUri`、`amcl_open_netdiag_nonce` 同一套路），然后返回。
   */
  private openErrorSheet_(record: DownloadHistoryRecord): void {
    AppStorage.setOrCreate('amcl_open_error_sheet_session', record.startedAt)
    try {
      this.getUIContext().getRouter().back()
    } catch (e) {
      hilog.warn(0x0000, TAG, 'router.back failed: %{public}s', (e as Error).message)
    }
  }

  /** 打开该活动的完整日志（活动账本 · L5）。 */
  private openActivityLog_(record: DownloadHistoryRecord): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ActivityLogPage',
        // 路由参数名会经过属性混淆；跨页面读取必须使用稳定的字符串键。
        params: { 'activityId': record.startedAt },
      })
    } catch (e) {
      hilog.warn(0x0000, TAG, 'open activity log failed: %{public}s', (e as Error).message)
    }
  }

  /** 全量清理不可撤销，确认前列出条数与占用；任何受保护活动存在时禁用入口。 */
  private async confirmClearAll_(): Promise<void> {
    if (!this.canClear_()) return
    const generation: number = ++this.clearGeneration_
    this.confirmingClear_ = true
    let accepted: boolean = false
    try {
      const reason: string = await ledgerClearBlockReasonAsync(this.context.filesDir)
      if (!this.hostVisible || generation !== this.clearGeneration_) return
      if (reason.length > 0) { this.safeToast_(reason); return }
      const message: string = '将删除本地活动记录和已保存的活动日志。\n\n'
        + '当前记录：' + this.records.length + ' 条\n'
        + '日志占用：' + (this.ledgerBytes < 0 ? '暂不可读' : formatLogBytes(this.ledgerBytes)) + '\n\n'
        + '在线分享仍会保留；清理后可在“日志分享记录”中查看链接或单独撤回。'
      const result: promptAction.ShowDialogSuccessResponse = await this.getUIContext().getPromptAction().showDialog({
        title: '清空本地活动记录？',
        message: message,
        buttons: [
          { text: '取消', color: this.theme.actionText as string },
          { text: '清空本地记录', color: this.theme.errorText as string },
        ],
      })
      accepted = result.index === 1
    } catch (e) {
      if (this.hostVisible && generation === this.clearGeneration_) this.clearError = '无法核实或确认清理：' + (e as Error).message
    } finally { this.confirmingClear_ = false }
    if (accepted && this.hostVisible && generation === this.clearGeneration_) await this.clearAll()
  }

  /** 确认后仍检查保护条件；先核验文件删除，再清历史索引。部分失败保留错误并刷新真实占用。 */
  private async clearAll(): Promise<void> {
    if (!this.canClear_()) return
    this.clearing = true
    this.clearError = ''
    const generation: number = this.clearGeneration_
    try {
      await ledgerClearAsync(this.context.filesDir)
      await getDownloadHistoryStore().clear()
      if (this.hostVisible && generation === this.clearGeneration_) this.safeToast_('本地活动记录已清空，在线分享仍保留')
    } catch (e) {
      if (this.hostVisible && generation === this.clearGeneration_) this.clearError = '清空失败：' + (e as Error).message
      hilog.warn(0x0000, TAG, 'clear failed: %{public}s', (e as Error).message)
    } finally {
      this.clearing = false
      // 完成的是已确认的持久操作；若当前页已返回，用新读取世代刷新，而非发布旧快照。
      if (this.hostVisible) await this.refreshRecords()
    }
  }

  private canClear_(): boolean {
    return this.loaded && !this.clearing && this.records.length > 0
      && this.hostVisible && !this.confirmingClear_ && !this.selectionBusy && !this.refreshing
  }

  private statusBadgeColor(status: string): ResourceColor {
    if (status === 'success') return this.theme.successText
    if (status === 'failed' || status === 'crashed') return this.theme.errorText
    if (status === 'aborted' || status === 'interrupted') return this.theme.warningText
    if (status === 'running') return this.theme.actionText
    return this.theme.textHint
  }

  /** 取消/中断用警示底色，避免在列表中与失败、崩溃混为同一强红色。 */
  private statusBadgeBackground_(status: string): ResourceColor {
    if (status === 'success') return this.theme.successBg
    if (status === 'failed' || status === 'crashed') return this.theme.errorBg
    if (status === 'aborted' || status === 'interrupted') return this.theme.warningBg
    return this.theme.primaryLight
  }

  private statusBadgeText(status: string): string {
    if (status === 'success') return '成功'
    if (status === 'failed') return '失败'
    if (status === 'aborted') return '取消'
    if (status === 'crashed') return '崩溃'
    return status
  }

  // ---- 活动时间线：类别自适应 helper ----
  private cat_(record: DownloadHistoryRecord): string {
    if (record.category && record.category.length > 0) return record.category
    // 旧记录无 category：按 loaderType 推断
    return (record.loaderType.indexOf('mod-') === 0) ? ActivityCategory.MOD_INSTALL : ActivityCategory.DOWNLOAD
  }

  /** 是否文件型操作（下载/模组安装）→ 展示字节/文件数。其余（启动/修复/JDK/账户）不展示。 */
  private isFileBased_(record: DownloadHistoryRecord): boolean {
    let c = this.cat_(record)
    return c === ActivityCategory.DOWNLOAD || c === ActivityCategory.MOD_INSTALL
  }

  /** 右上角标签：下载/安装沿用加载器标签；其余显示类别名。 */
  private categoryTag_(record: DownloadHistoryRecord): string {
    const category = this.cat_(record)
    return category === ActivityCategory.DOWNLOAD ? this.loaderTag(record) : activityCategoryLabel(category)
  }

  /** 卡片主标题：优先 title，回退 versionName。 */
  private cardTitle_(record: DownloadHistoryRecord): string {
    return (record.title && record.title.length > 0) ? record.title : record.versionName
  }

  private formatStartedAt(ms: number): string {
    if (ms <= 0) return '—'
    let d = new Date(ms)
    let pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString())
    return d.getFullYear().toString() + '-'
      + pad(d.getMonth() + 1) + '-'
      + pad(d.getDate()) + ' '
      + pad(d.getHours()) + ':'
      + pad(d.getMinutes())
  }

  private loaderTag(record: DownloadHistoryRecord): string {
    if (record.loaderType === 'forge') {
      return record.loaderVersion ? 'Forge ' + record.loaderVersion : 'Forge'
    }
    if (record.loaderType === 'fabric') {
      return record.loaderVersion ? 'Fabric ' + record.loaderVersion : 'Fabric'
    }
    return '原版'
  }

  build() {
    Column() {
      // 标题菜单只转交既有管理操作；账本分栏和嵌入详情的生命周期仍由原页面持有。
      // 用途已由分类和记录列表表达，标题下不再常驻一行解释文字。
      ImmersiveTitleScaffold({ title: '活动账本', titleId: 'activity-records-title',
        theme: this.theme, surfaceColor: this.theme.bgPrimary, topSafeHeight: this.topSafeHeight,
        backLabel: '返回设置', menuActions: [{ id: 'manage-ledger', label: '管理', enabled: !this.selectionBusy }],
        onBack: (): void => { this.getUIContext().getRouter().back(); },
        onMenuAction: (id: string): void => { if (id === 'manage-ledger') this.manage_(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
      // 原管理按钮迁入 HDS 菜单后改用稳定零尺寸锚点，不能丢失原存储 Sheet 生命周期。
      Column().width(0).height(0)
        .bindSheet(this.showStorage, this.Storage_(), this.storageSheetOptions_())
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
      .onAreaChange((_previous: Area, current: Area) => {
        const width: number = Number(current.width)
        const height: number = Number(current.height)
        // 页面尺寸变化才废弃旧测量上下文；辅助层收展不改变页面本身尺寸。
        if (Math.abs(width - this.viewportWidth) > 0.5 || Math.abs(height - this.retreatViewportHeight_) > 0.5) {
          this.resetRetreat_(true)
        }
        this.viewportWidth = width
        this.retreatViewportHeight_ = height
      })
      .bindSheet(this.showQuickShare, this.LedgerShare_(), this.ledgerShareOptions_())
  }

  /** 管理和快捷分享使用不同的稳定锚点，避免对同一元素重复 bindSheet 覆盖前一个弹层。 */
  private storageSheetOptions_(): SheetOptions {
    const options: SheetOptions = this.ledgerShareOptions_()
    if (DeviceProfile.form() !== DeviceForm.PHONE) options.height = '85%'
    options.onDisappear = (): void => {
      this.showStorage = false
      if (this.pendingStorageActivity > 0) {
        const id: number = this.pendingStorageActivity; this.pendingStorageActivity = 0
        const params: Record<string, Object> = { 'activityId': id, 'view': 'overview' }
        this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
          .catch((): void => { this.safeToast_('无法打开活动，请重试') })
      } else this.refreshRecords()
    }
    return options
  }

  @Builder
  private Storage_() {
    ActivityStoragePanel({ theme: this.theme,
      onClose: (): void => { this.showStorage = false },
      onOpenActivity: (id: number): void => { this.pendingStorageActivity = id; this.showStorage = false } })
  }

  /** 日统计默认压成一行；需要比较数量时展开，始终以真实结局计数。 */
  @Builder
  private TodayOverview_() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('今天 · ' + this.stats.total + ' 条').fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
        if (this.stats.failed > 0) { Text(this.stats.failed + ' 次失败').fontSize(12).fontColor(this.theme.errorText) }
        Button(this.overviewExpanded ? '收起' : '统计').height(44).fontSize(12)
          .backgroundColor(Color.Transparent).fontColor(this.theme.actionText).onClick(() => {
            this.freezeRetreatAnchor_()
            // 明确的统计操作先完整显示辅助区；只改变原统计偏好，不借用退让量保存选择。
            this.resetRetreat_()
            // 小块统计展开只使用有界时长；系统减弱动画时立即呈现。
            this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut }, (): void => {
              this.overviewExpanded = !this.overviewExpanded
            })
          })
        Button() { AppIcon({ name: AppIconName.Refresh, iconSize: 16, color: this.theme.actionText }) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('刷新活动账本')
          .enabled(!this.refreshing && !this.selectionBusy).onClick(() => { this.refreshRecords() })
      }.width('100%')
      if (this.overviewExpanded) {
        Row({ space: 12 }) {
          Text(this.stats.completed + ' 已完成').fontSize(13).fontColor(this.theme.successText)
          Text(this.stats.interrupted + ' 中断/取消').fontSize(13).fontColor(this.theme.warningText)
        }.width('100%').padding({ bottom: 8 })
      }
    }.width('100%').padding({ left: 4, right: 0 })
  }

  /**
   * 统计层位于搜索下方但最后退让；12vp尾距属于本层自然高度，完全收起不留下空行。
   * 裁剪期间整层暂停命中与读屏，避免只剩半个刷新按钮却仍可被点击或焦点选中。
   */
  @Builder
  private RetreatOverview_() {
    Column() {
      Column() {
        MotionSection({ order: 0 }) { this.TodayOverview_() }
      }.width('100%').padding({ bottom: 12 }).flexShrink(0)
        .height((this.retreatAnimating_ || this.retreatHidden_ > 0) && this.retreatOverviewHeight_ > 0
          ? this.retreatOverviewHeight_ : LayoutPolicy.fixAtIdealSize)
        .constraintSize({ minHeight: this.retreatAnimating_ || this.retreatHidden_ > 0 ? this.retreatOverviewHeight_ : 0 })
        .translate({ y: retreatLayerOffset(this.retreatOverviewHeight_, this.retreatHidden_, this.retreatFilterHeight_) })
        .renderFit(RenderFit.TOP_LEFT)
        .onAreaChange((_previous: Area, current: Area) => { this.measureRetreatLayer_(false, current) })
    }.width('100%')
      .height(this.retreatOverviewHeight_ > 0
        ? retreatLayerHeight(this.retreatOverviewHeight_, this.retreatHidden_, this.retreatFilterHeight_) : LayoutPolicy.fixAtIdealSize)
      .clip(true)
      .enabled(!this.retreatAnimating_ && this.retreatHidden_ <= this.retreatFilterHeight_)
      .accessibilityLevel(!this.retreatAnimating_ && this.retreatHidden_ <= this.retreatFilterHeight_ ? 'auto' : 'no-hide-descendants')
  }

  /** 分类先退让，恢复时先显示统计再找回分类；原筛选值和回调由本页持续持有。 */
  @Builder
  private RetreatFilters_() {
    Column() {
      Column() {
        AnimatedPillBar({ labels: ['全部', '游戏', '下载', '导出', '异常'], theme: this.theme, filled: false,
          selectedIndex: ACTIVITY_FILTERS.indexOf(this.activeFilter), disabled: this.selectionBusy,
          onSelect: (index: number): void => {
            this.resetRetreat_(true)
            this.activeFilter = ACTIVITY_FILTERS[index]
            this.updateGroups_()
          } })
      }.width('100%').padding({ bottom: 12 }).flexShrink(0)
        .height((this.retreatAnimating_ || this.retreatHidden_ > 0) && this.retreatFilterHeight_ > 0
          ? this.retreatFilterHeight_ : LayoutPolicy.fixAtIdealSize)
        .constraintSize({ minHeight: this.retreatAnimating_ || this.retreatHidden_ > 0 ? this.retreatFilterHeight_ : 0 })
        .translate({ y: retreatLayerOffset(this.retreatFilterHeight_, this.retreatHidden_, 0) })
        .renderFit(RenderFit.TOP_LEFT)
        .onAreaChange((_previous: Area, current: Area) => { this.measureRetreatLayer_(true, current) })
    }.width('100%')
      .height(this.retreatFilterHeight_ > 0
        ? retreatLayerHeight(this.retreatFilterHeight_, this.retreatHidden_, 0) : LayoutPolicy.fixAtIdealSize)
      .clip(true).enabled(!this.retreatAnimating_ && this.retreatHidden_ <= 0)
      .accessibilityLevel(!this.retreatAnimating_ && this.retreatHidden_ <= 0 ? 'auto' : 'no-hide-descendants')
  }

  /** 左侧记录使用固定视口；统计与分类覆盖在上面，右侧详情不在此Builder。 */
  @Builder
  private RetreatLedgerResults_() {
    // List的几何视口固定；辅助区仅作为局部覆盖层收展。
    Stack({ alignContent: Alignment.TopStart }) {
    if (this.groups.length === 0) {
      Column({ space: 16 }) {
        AppIcon({ name: AppIconName.History, iconSize: 40, color: this.theme.actionText })
        Text(this.records.length === 0 ? '故事，从一次启动开始' : '没有匹配的活动')
          .fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
        Text(this.records.length === 0 ? '下载、启动、安装和修复等活动会自动出现在这里。' : '试试其他关键词或清除筛选条件。')
          .fontSize(12).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
        if (this.records.length > 0) {
          Button('清除筛选').height(44).onClick(() => {
            this.resetRetreat_(true)
            this.query = ''; this.activeFilter = ActivityFilter.ALL; this.updateGroups_()
          })
        }
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20, top: this.retreatListInset_() + 20, bottom: 20 })
    } else {
      List({ space: 8, scroller: this.retreatScroller_ }) {
        // 固定声明的首项随真实内容滚动，收展期间不改高度或原数据源的key。
        ListItem() { Column().width('100%').height('100%') }
          .height(retreatLeadItemHeight(this.retreatListInset_(), 8))
          .id('activity-retreat-content-inset').focusable(false)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        LazyForEach(this.activityRows_, (row: ActivityListRow) => {
          ListItem() {
            if (row.header) {
            Row({ space: 8 }) {
              Text(row.groupLabel).fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              Text(row.groupCount + ' 条').fontSize(12).fontColor(this.theme.textSecondary)
              Divider().layoutWeight(1).color(this.theme.divider)
            }.width('100%').padding({ top: 12, bottom: 4 })
            } else {
              MotionSection({ order: row.indexInGroup + 1, animateEntrance: row.groupIndex === 0 && row.indexInGroup < 5 }) {
                ActivityTimelineItem({ time: activityClock(row.record.startedAt), color: this.statusBadgeColor(row.record.status),
                  last: row.lastInGroup, theme: this.theme }) { this.RecordCard(row.record) }
              }
            }
          }
        }, (row: ActivityListRow): string => row.key)
      }.width('100%').height('100%').scrollBar(BarState.Auto).cachedCount(4).id('activity-records-scroll')
        // 退让扩大视口后可能恰好容纳全部记录，仍保留结果区的反向恢复输入。
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onScrollStart(() => {
          if (!this.retreatAnimating_) this.retreatPolicy_.reset()
        })
        .onScrollFrameBegin((offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult => {
          return this.retreatScrollFrame_(offset, state)
        })
        .onTouch((event: TouchEvent) => { this.observeRetreatTouch_(event) })
        .onReachStart(() => { this.restoreRetreatAtStart_() })
        .onDidScroll((offset: number, state: ScrollState) => { this.observeRetreatPosition_(offset, state) })
        .onScrollStop(() => { this.observeRetreatStop_() })
        .onScrollIndex((start: number, end: number): void => { this.updateRetreatScrollable_(start, end) })
    }
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.RetreatOverview_()
          this.RetreatFilters_()
        }.width('100%').backgroundColor(this.theme.bgPrimary).clip(true)
        if (this.retreatAnimating_ && this.retreatHitHeight_ > 0) {
          Column().width('100%').height(this.retreatHitHeight_).hitTestBehavior(HitTestMode.Block)
        }
      }.id('activity-retreat-overlay').width('100%')
        .height(this.retreatAnimating_ ? this.retreatHitHeight_
          : (this.retreatTotalHeight_() > 0 ? this.retreatOverlayHeight_() : LayoutPolicy.fixAtIdealSize))
        .clip(true)
        .hitTestBehavior(this.retreatAnimating_ || this.retreatOverlayHeight_() > 0 ? HitTestMode.Default : HitTestMode.None)
    }.id('activity-retreat-viewport').width('100%').layoutWeight(1).clip(true)
  }

  /** 标题独占整行，状态与快捷操作放在下一行，长版本名不再被两枚操作按钮挤窄。 */
  @Builder
  RecordCard(record: DownloadHistoryRecord) {
    Column({ space: 0 }) {
      Button() {
        Column({ space: 6 }) {
          Text(activityDisplayTitle(record)).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          if (isAbnormalActivity(record) && (record.errorMessage ?? '').length > 0) {
            Text(record.errorMessage ?? '').fontSize(12).fontColor(this.theme.textSecondary).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }
          if ((record.parentActivityId ?? 0) > 0) {
            Text(record.relation === 'retry' ? '重试记录' : record.relation === 'graphics-recovery' ? '图形恢复尝试' : '关联的子任务')
              .fontSize(11).fontColor(this.theme.actionText).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 44 }).padding(0).borderRadius(0)
        .backgroundColor(Color.Transparent).onClick(() => { this.openOverview_(record) })
      Row({ space: 4 }) {
        Column({ space: 3 }) {
          Text(activityStatusLabel(record) + (record.pinned === true ? ' · 保留' : '')).fontSize(12).fontWeight(500)
            .fontColor(this.statusBadgeColor(record.status)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 4 }) {
            if (this.cat_(record) === ActivityCategory.GAME_EXPORT) {
              AppIcon({ name: AppIconName.Export, iconSize: 14, color: this.theme.textSecondary })
            }
            Text(this.categoryTag_(record) + ' · ' + (record.durationEstimated === true ? '用时未知' : formatDurationMs(record.durationMs)))
              .fontSize(11).fontColor(this.theme.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Row() {
          Button() { AppIcon({ name: AppIconName.Share, iconSize: 16, color: this.theme.textSecondary }) }
            .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
            .enabled(!this.selectionBusy && this.hasEvidence_(record)).accessibilityText('分享本次活动的推荐日志')
            .onClick(() => { this.doUploadActivity_(record) })
          // 三点与详情工具栏一致，保留原有 44vp 点击区域。
          Button() { Text('⋯').fontSize(22).fontWeight(600).fontColor(this.theme.textSecondary) }
            .width(44).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.selectionBusy)
            .accessibilityText('自定义分享与活动详情').onClick(() => { this.recordMenu_(record) })
        }
      }.width('100%')
    }.width('100%').padding({ left: 12, right: 8, top: 6, bottom: 6 }).borderRadius(12)
      .backgroundColor(this.viewportWidth >= 840 && this.selectedId === record.startedAt ? this.theme.primaryLight : this.theme.bgCard)
      .border({ width: { left: 3 }, color: this.viewportWidth >= 840 && this.selectedId === record.startedAt ? this.theme.actionText : Color.Transparent })
      .alignItems(HorizontalAlign.Start)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
    Column({ space: 12 }) {
      if (this.loadError.length > 0 || this.clearError.length > 0) {
        Row({ space: 12 }) {
          Text(this.loadError || this.clearError).fontSize(12).fontColor(this.theme.errorText).layoutWeight(1)
          Button('重试').height(44).enabled(!this.refreshing).onClick(() => { this.refreshRecords() })
        }.width('100%').padding(12).borderRadius(16).backgroundColor(this.theme.errorBg)
      }
      if (!this.loaded && this.refreshing) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.theme.actionText)
          Text('正在读取本地活动…').fontSize(14).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (!this.loaded && this.loadError.length > 0) {
        Column({ space: 12 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 36, color: this.theme.warningText })
          Text('暂时无法读取活动账本').fontSize(16).fontColor(this.theme.textPrimary)
          Text('读取恢复前不会把它显示为空账本。').fontSize(12).fontColor(this.theme.textSecondary)
          Button('重新读取').height(44).onClick(() => { this.refreshRecords() })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Row({ space: 20 }) {
          if (!this.readerFocused || this.viewportWidth < 840) {
          // 搜索是左列表的固定首节点；只调整其后的辅助层，不改标题宿主或右侧工作区。
          Column({ space: 0 }) {
            TextInput({ placeholder: '搜索活动、版本或错误摘要', text: this.query }).caretColor(this.theme.actionText)
              .id('activity-records-search')
              .height(44).fontSize(13).backgroundColor(this.theme.bgCard).borderRadius(12)
              .margin({ bottom: 12 }).enabled(!this.selectionBusy)
              .onFocus(() => {
                this.retreatSearchFocused_ = true
                this.resetRetreat_()
              })
              .onBlur(() => { this.retreatSearchFocused_ = false; this.retreatPolicy_.reset() })
              .onChange((value: string): void => {
                if (!this.selectionBusy) {
                  this.resetRetreat_(true)
                  this.query = value
                  this.updateGroups_()
                }
              })
            // 空间提醒是实际问题入口，留在退让层外；不存在时不额外占位。
            if (this.storageAlertBytes > 0 && this.ledgerBytes >= this.storageAlertBytes) {
              Button('日志占用已达到提醒阈值 · 查看').height(44).fontSize(12).fontColor(this.theme.warningText)
                .margin({ bottom: 12 }).backgroundColor(this.theme.bgCard)
                .onClick(() => { this.resetRetreat_(); this.showStorage = true })
            }
            this.RetreatLedgerResults_()
            // 最后一个子节点就是可伸展的列表/空态，底部不再保留 44vp 操作行与 16vp 间隔。
          }.width(this.viewportWidth >= 840 ? 320 : '100%').height('100%')
          }
          if (this.viewportWidth >= 840) {
            Column() {
              ActivityPaneMotion({ identity: String(this.selectedId), active: this.hostVisible }) {
              ForEach(this.selectedRecords, (selected: DownloadHistoryRecord) => {
                if (this.cat_(selected) === ActivityCategory.GAME_EXPORT) {
                  // 导出结果保存在私有任务文件，不要求存在日志账本才能重入。
                  // 宽窗自动选中行仅展示历史摘要；用户点击按钮后读取准确任务结果。
                  Column({ space: 16 }) {
                    AppIcon({ name: AppIconName.Export, iconSize: 32, color: this.theme.actionText })
                    Text(this.cardTitle_(selected)).fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                    Text(activityStatusLabel(selected)).fontSize(14).fontColor(this.statusBadgeColor(selected.status)).width('100%')
                    Text(selected.subtitle ?? '').fontSize(13).fontColor(this.theme.textSecondary).width('100%')
                    if ((selected.errorMessage ?? '').length > 0) {
                      Text(selected.errorMessage ?? '').fontSize(13).fontColor(this.theme.errorText).width('100%')
                    }
                    Button('查看导出结果').width('100%').height(48).fontColor(this.theme.textOnPrimary)
                      .backgroundColor(this.theme.primary).onClick(() => { this.openGameExport_(selected) })
                  }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
                } else {
                ActivityLogWorkspace({ activityId: selected.startedAt, embedded: true, hostVisible: this.hostVisible, initialView: 'overview', refreshNonce: this.detailRevision,
                  initialDiagnosisTitle: this.cardTitle_(selected),
                  onClosed: () => { this.closeDetail_() },
                  onBusyChanged: (busy: boolean) => { this.selectionBusy = busy },
                  onFocusChanged: (focused: boolean): void => { this.readerFocused = focused },
                  onMetadataChanged: (): void => { this.refreshRecords() },
                })
                }
              }, (selected: DownloadHistoryRecord): string => selected.startedAt.toString())
              if (this.selectedRecords.length === 0) {
                Text('选择左侧活动查看详情').fontSize(16).fontColor(this.theme.textSecondary).padding(32)
              }
              }
            }.layoutWeight(1).height('100%').backgroundColor(this.theme.bgCard).borderRadius(18)
              .border({ width: 1, color: this.theme.divider }).clip(true)
          }
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
      // 标题已不含说明行，正文从首个真实统计控件开始；不再叠加16vp顶部空白。
      .padding({ top: 0, left: 20, right: 20, bottom: this.bottomSafeHeight + 12 })
      }
}

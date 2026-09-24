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
  getDownloadHistoryStore,
  ActivityCategory,
  ActivityStatus,
} from 'feature_core';
import { formatBytes } from 'feature_core';
import { formatDurationMs } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';

// M3：会话快照 —— 判定日志是否还在保留窗口内 + 反查落点
import { isReopenableRecord, resolveSessionSnapshot } from '../components/McSessionSnapshot';
// 活动账本（L5）：任何有账本的活动都能查看完整日志
import { ledgerHas, ledgerClear, ledgerTotalBytes, ledgerList, LEDGER_MAX_ENTRIES, ledgerClearBlockReason, DistributionPolicy } from 'commons';
import { formatLogBytes } from 'commons';
import {
  ledgerArchiveCompletedSessions,
} from 'commons';

import { ActivityAiCard } from '../components/ActivityAiCard';
import { ActivityShareSheet } from '../components/ActivityShareSheet';
import { DeviceProfile, centerSheetForLayout, detailSheetHeightForLayout, sheetWidthForLayout } from 'commons';
import { ActivityTimelineItem } from '../components/ActivityTimelineItem';
import { AnimatedPillBar } from '../components/AnimatedPillBar';
import { MotionSection } from '../components/MotionSection';
import { ActivityPaneMotion } from '../components/ActivityPaneMotion';
import { UiMotion } from '../components/UiMotion';
import { ActivityLogWorkspace } from './ActivityLogPage';
import { ActivityStoragePanel } from '../components/ActivityStoragePanel';
import { activityStorageAlert } from 'commons';
import { ActivityFilter, ActivityDayGroup, ActivityDayStats, matchesActivity, groupActivities,
  activityTodayStats, activityCategory, activityStatusLabel, isAbnormalActivity,
  ActivityStatusBand, activityStatusBands, activityClock, activityDisplayTitle } from '../components/ActivityUiModel';

const TAG = 'DownloadHistory'
const ACTIVITY_FILTERS: ActivityFilter[] = [ActivityFilter.ALL, ActivityFilter.GAME, ActivityFilter.DOWNLOAD, ActivityFilter.ABNORMAL]

@Entry
@Component
struct DownloadHistoryPage {
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
  /** 正在上传的记录 key（startedAt 字符串）；非空表示该条上传中，UI 禁用按钮。 */
  @State uploadingKey: string = ''
  @State private clearing: boolean = false
  @State private clearError: string = ''
  /** 活动账本总占用字节（L5：让用户知道日志吃了多少空间）。 */
  @State private ledgerBytes: number = 0
  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility 缓存。
  // 详见 docs/guides/api-migration-2026-05.md。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    this.applyTheme_()
    this.refreshRecords()
  }

  onPageShow(): void { this.hostVisible = true; this.refreshRecords() }
  onPageHide(): void { this.hostVisible = false }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  /** 读取成功后一次性更新列表与占用；旧结果在刷新失败时保持可见。 */
  private async refreshRecords(): Promise<void> {
    if (this.refreshing || this.selectionBusy) return
    this.refreshing = true
    this.loadError = ''
    try {
      const store = getDownloadHistoryStore()
      await store.init(this.context)
      // 退出恢复负责归档；列表只读取派生索引与 manifest，不在每次进页重新复制/校验所有原件。
      this.records = store.list()
      this.availability.clear()
      for (const record of this.records) {
        this.availability.set(record.startedAt, ledgerHas(this.context.filesDir, record.startedAt))
      }
      try { this.ledgerBytes = ledgerList(this.context.filesDir).reduce((sum, entry): number => sum + entry.bytes, 0) }
      catch (e) { this.ledgerBytes = -1 }
      this.loaded = true
      this.storageAlertBytes = activityStorageAlert(this.context.filesDir)
      this.detailRevision++
      this.updateGroups_()
      AppStorage.setOrCreate<number>('activityLedgerRevision', Date.now())
    } catch (e) {
      this.loadError = '活动记录读取失败：' + (e as Error).message
    } finally { this.refreshing = false }
  }

  /** 用户筛选不改变持久数据；平板选中项消失时清空详情，避免显示不在列表中的活动。 */
  private updateGroups_(): void {
    const visible: DownloadHistoryRecord[] = this.records.filter((record: DownloadHistoryRecord): boolean =>
      matchesActivity(record, this.query, this.activeFilter))
    this.groups = groupActivities(visible, Date.now())
    this.stats = activityTodayStats(this.records, Date.now())
    const selected = visible.find((record: DownloadHistoryRecord): boolean => record.startedAt === this.selectedId)
    if (selected !== undefined) this.selectedRecords = [selected]
    else if (visible.length > 0) { this.selectedRecords = [visible[0]]; this.selectedId = visible[0].startedAt }
    else { this.selectedRecords = []; this.selectedId = 0 }
  }

  /** 平板侧栏只切换选中活动，手机则进入相同工作区的路由包装。 */
  private openOverview_(record: DownloadHistoryRecord): void {
    if (this.selectionBusy) { this.safeToast_('正在发送或导出，请稍后切换活动'); return }
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

  /** 占用与撤回集中在管理菜单，不再用常驻页脚挤占活动列表；取消不产生任何副作用。 */
  private manage_(): void {
    try {
    try { this.ledgerBytes = ledgerTotalBytes(this.context.filesDir) } catch (e) { this.ledgerBytes = -1 }
    this.getUIContext().getPromptAction().showActionMenu({
      title: '管理活动账本 · ' + (this.ledgerBytes < 0 ? '占用暂不可读' : '日志占用 ' + formatLogBytes(this.ledgerBytes)),
      buttons: [
        { text: '分享记录与撤回', color: this.theme.primary as string },
        { text: '清空本地记录与日志', color: this.theme.error as string },
        { text: '日志占用、保留与空间提醒', color: this.theme.primary as string },
      ],
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) this.getUIContext().getRouter().pushUrl({ url: 'pages/LogShareHistoryPage' })
      else if (result.index === 2) this.showStorage = true
      else if (this.canClear_()) this.confirmClearAll_()
      else this.safeToast_(ledgerClearBlockReason(this.context.filesDir) || '当前没有可清理的活动')
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
      { text: '自定义分享与预览', color: this.theme.primary as string },
      { text: '查看原始日志', color: this.theme.primary as string },
      { text: '查看活动详情', color: this.theme.primary as string },
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) { this.shareRecords = [record]; this.shareMode = 'advanced'; this.showQuickShare = true }
      else if (result.index === 1) this.openActivityLog_(record)
      else if (result.index === 2) this.openOverview_(record)
    }).catch((): void => {})
  }

  private ledgerShareOptions_(): SheetOptions {
    const form = DeviceProfile.form(); const breakpoint = DeviceProfile.breakpointOf(this.viewportWidth)
    const center: boolean = centerSheetForLayout(form, breakpoint)
    const height: number = detailSheetHeightForLayout(form, breakpoint, this.bottomSafeHeight, this.topSafeHeight)
    return { height: this.shareMode === 'quick' ? Math.min(height, 440) : height,
      width: sheetWidthForLayout(form, breakpoint), preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
      showClose: true, dragBar: !center, backgroundColor: this.theme.bgPrimary,
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
  private confirmClearAll_(): void {
    if (!this.canClear_()) return
    const message: string = '将删除本地活动记录和已保存的活动日志。\n\n'
      + '当前记录：' + this.records.length + ' 条\n'
      + '日志占用：' + formatLogBytes(this.ledgerBytes) + '\n\n'
      + '在线分享链接不会被撤回，请在“日志分享记录”中单独处理。'
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '清空本地活动记录？',
        message: message,
        buttons: [
          { text: '取消', color: this.theme.primary as string },
          { text: '清空本地记录', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) this.clearAll()
      }).catch(() => { /* 点框外 = 取消 */ })
    } catch (e) {
      this.clearError = '无法打开确认框：' + (e as Error).message
    }
  }

  /** 确认后仍检查保护条件；先核验文件删除，再清历史索引。部分失败保留错误并刷新真实占用。 */
  private async clearAll(): Promise<void> {
    if (!this.canClear_()) return
    this.clearing = true
    this.clearError = ''
    try {
      ledgerClear(this.context.filesDir)
      await getDownloadHistoryStore().clear()
      this.safeToast_('本地活动记录已清空，在线分享仍保留')
    } catch (e) {
      this.clearError = '清空失败：' + (e as Error).message
      hilog.warn(0x0000, TAG, 'clear failed: %{public}s', (e as Error).message)
    } finally {
      await this.refreshRecords()
      this.clearing = false
    }
  }

  private canClear_(): boolean {
    return this.loaded && !this.clearing && this.records.length > 0
      && ledgerClearBlockReason(this.context.filesDir).length === 0
  }

  private statusBadgeColor(status: string): ResourceColor {
    if (status === 'success') return this.theme.successText
    if (status === 'failed' || status === 'crashed') return this.theme.errorText
    if (status === 'aborted' || status === 'interrupted') return this.theme.warningText
    if (status === 'running') return this.theme.primary
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
    let c = this.cat_(record)
    if (c === ActivityCategory.LAUNCH) return '启动'
    if (c === ActivityCategory.REPAIR) return '修复'
    if (c === ActivityCategory.JDK) return 'JDK'
    if (c === ActivityCategory.ACCOUNT) return '账户'
    if (c === ActivityCategory.MODPACK) return '整合包'
    if (c === ActivityCategory.MOD_INSTALL) return '安装'
    return this.loaderTag(record)
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
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button() { AppIcon({ name: AppIconName.Back, iconSize: 20, color: this.theme.primary }) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('返回设置')
          .onClick(() => { this.getUIContext().getRouter().back() })
        Column({ space: 4 }) {
          Text('活动账本').fontSize(24).fontWeight(600).fontColor(this.theme.textPrimary).id('activity-records-title')
          Text('启动、下载与排查记录').fontSize(12).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('管理').height(44).fontSize(14).fontColor(this.theme.primary)
          .backgroundColor(this.theme.bgCard).borderRadius(12).enabled(!this.selectionBusy).onClick(() => { this.manage_() })
          .bindSheet(this.showStorage, this.Storage_(), this.storageSheetOptions_())
      }.width('100%')
      if (this.loadError.length > 0 || this.clearError.length > 0) {
        Row({ space: 12 }) {
          Text(this.loadError || this.clearError).fontSize(12).fontColor(this.theme.error).layoutWeight(1)
          Button('重试').height(44).enabled(!this.refreshing).onClick(() => { this.refreshRecords() })
        }.width('100%').padding(12).borderRadius(16).backgroundColor(this.theme.errorBg)
      }
      if (!this.loaded && this.refreshing) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.theme.primary)
          Text('正在读取本地活动…').fontSize(14).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (!this.loaded && this.loadError.length > 0) {
        Column({ space: 12 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 36, color: this.theme.warning })
          Text('暂时无法读取活动账本').fontSize(16).fontColor(this.theme.textPrimary)
          Text('读取恢复前不会把它显示为空账本。').fontSize(12).fontColor(this.theme.textSecondary)
          Button('重新读取').height(44).onClick(() => { this.refreshRecords() })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Row({ space: 20 }) {
          if (!this.readerFocused || this.viewportWidth < 840) {
          Column({ space: 12 }) {
            MotionSection({ order: 0 }) { this.TodayOverview_() }
            if (this.storageAlertBytes > 0 && this.ledgerBytes >= this.storageAlertBytes) {
              Button('日志占用已达到提醒阈值 · 查看').height(44).fontSize(12).fontColor(this.theme.warning)
                .backgroundColor(this.theme.bgCard).onClick(() => { this.showStorage = true })
            }
            TextInput({ placeholder: '搜索活动、版本或错误摘要', text: this.query })
              .height(44).fontSize(13).backgroundColor(this.theme.bgCard).borderRadius(12)
              .enabled(!this.selectionBusy)
              .onChange((value: string): void => { if (!this.selectionBusy) { this.query = value; this.updateGroups_() } })
            AnimatedPillBar({ labels: ['全部', '游戏', '下载', '异常'], theme: this.theme, filled: false,
              selectedIndex: ACTIVITY_FILTERS.indexOf(this.activeFilter), disabled: this.selectionBusy,
              onSelect: (index: number): void => { this.activeFilter = ACTIVITY_FILTERS[index]; this.updateGroups_() } })
            if (this.groups.length === 0) {
              Column({ space: 16 }) {
                AppIcon({ name: AppIconName.History, iconSize: 40, color: this.theme.primary })
                Text(this.records.length === 0 ? '故事，从一次启动开始' : '没有匹配的活动')
                  .fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
                Text(this.records.length === 0 ? '下载、启动、安装和修复等活动会自动出现在这里。' : '试试其他关键词或清除筛选条件。')
                  .fontSize(12).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
                if (this.records.length > 0) {
                  Button('清除筛选').height(44).onClick(() => { this.query = ''; this.activeFilter = ActivityFilter.ALL; this.updateGroups_() })
                }
              }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(20)
            } else {
              List({ space: 8 }) {
                ForEach(this.groups, (group: ActivityDayGroup, groupIndex: number) => {
                  ListItem() {
                    Row({ space: 8 }) {
                      Text(group.label).fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
                      Text(group.records.length + ' 条').fontSize(12).fontColor(this.theme.textSecondary)
                      Divider().layoutWeight(1).color(this.theme.divider)
                    }.width('100%').padding({ top: 12, bottom: 4 })
                  }
                  ForEach(group.records, (record: DownloadHistoryRecord, index: number) => {
                    ListItem() {
                      MotionSection({ order: index + 1, animateEntrance: groupIndex === 0 && index < 5 }) {
                        ActivityTimelineItem({ time: activityClock(record.startedAt), color: this.statusBadgeColor(record.status),
                          last: index === group.records.length - 1, theme: this.theme }) { this.RecordCard(record) }
                      }
                    }
                  }, (record: DownloadHistoryRecord): string => record.startedAt.toString() + '-' + activityCategory(record))
                // V1 ForEach 不会因相同日期下普通对象的内层字段变化重建 BuilderParam。
                // 刷新世代进入分组 key，让保留/结局更新立即反映到行内，右侧工作区仍按活动 ID 复用。
                }, (group: ActivityDayGroup): string => group.key + '-' + this.detailRevision)
              }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).cachedCount(4).id('activity-records-scroll')
            }
            // 最后一个子节点就是可伸展的列表/空态，底部不再保留 44vp 操作行与 16vp 间隔。
          }.width(this.viewportWidth >= 840 ? 320 : '100%').height('100%')
          }
          if (this.viewportWidth >= 840) {
            Column() {
              ActivityPaneMotion({ identity: String(this.selectedId), active: this.hostVisible }) {
              ForEach(this.selectedRecords, (selected: DownloadHistoryRecord) => {
                ActivityLogWorkspace({ activityId: selected.startedAt, embedded: true, hostVisible: this.hostVisible, initialView: 'overview', refreshNonce: this.detailRevision,
                  initialDiagnosisTitle: this.cardTitle_(selected),
                  onClosed: () => { this.closeDetail_() },
                  onBusyChanged: (busy: boolean) => { this.selectionBusy = busy },
                  onFocusChanged: (focused: boolean): void => { this.readerFocused = focused },
                  onMetadataChanged: (): void => { this.refreshRecords() },
                })
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
      .padding({ top: this.topSafeHeight + 16, left: 20, right: 20, bottom: this.bottomSafeHeight + 12 })
      .onAreaChange((_previous: Area, current: Area) => { this.viewportWidth = Number(current.width) })
      .bindSheet(this.showQuickShare, this.LedgerShare_(), this.ledgerShareOptions_())
  }

  /** 管理和快捷分享使用不同的稳定锚点，避免对同一元素重复 bindSheet 覆盖前一个弹层。 */
  private storageSheetOptions_(): SheetOptions {
    const options: SheetOptions = this.ledgerShareOptions_()
    options.height = '85%'
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
          .backgroundColor(Color.Transparent).fontColor(this.theme.primary).onClick(() => {
            // 小块统计展开只使用有界时长；系统减弱动画时立即呈现。
            this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut }, (): void => {
              this.overviewExpanded = !this.overviewExpanded
            })
          })
        Button() { AppIcon({ name: AppIconName.Refresh, iconSize: 16, color: this.theme.primary }) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('刷新活动账本')
          .enabled(!this.refreshing && !this.selectionBusy).onClick(() => { this.refreshRecords() })
      }.width('100%')
      if (this.overviewExpanded) {
        Row({ space: 12 }) {
          Text(this.stats.completed + ' 已完成').fontSize(13).fontColor(this.theme.success)
          Text(this.stats.interrupted + ' 中断/取消').fontSize(13).fontColor(this.theme.warning)
        }.width('100%').padding({ bottom: 8 })
      }
    }.width('100%').padding({ left: 4, right: 0 })
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
              .fontSize(11).fontColor(this.theme.primary).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 44 }).padding(0).borderRadius(0)
        .backgroundColor(Color.Transparent).onClick(() => { this.openOverview_(record) })
      Row({ space: 4 }) {
        Column({ space: 3 }) {
          Text(activityStatusLabel(record) + (record.pinned === true ? ' · 保留' : '')).fontSize(12).fontWeight(500)
            .fontColor(this.statusBadgeColor(record.status)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.categoryTag_(record) + ' · ' + (record.durationEstimated === true ? '用时未知' : formatDurationMs(record.durationMs)))
            .fontSize(11).fontColor(this.theme.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
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
      .border({ width: { left: 3 }, color: this.viewportWidth >= 840 && this.selectedId === record.startedAt ? this.theme.primary : Color.Transparent })
      .alignItems(HorizontalAlign.Start)
  }
}

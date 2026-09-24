/**
 * DownloadTasksSheet.ets — 统一下载任务面板（v6.5 2026-05-22）
 *
 * 这是 FAB 点开后弹出的 sheet，取代了原来的 `DownloadSheet`（MC 专用）+
 * `ModDownloadSheet`（模组专用）的二元结构。
 *
 * 两个子屏：
 *   - 'list'   → 任务总览（默认）
 *   - 'detail' → 单个任务详情，委托给独立的 `TaskDetailView` 组件渲染
 *
 * 设计稿：docs/design/download-page-redesign/10_download_tasks_sheet.png
 *
 * 数据源：`DownloadTaskRegistry.instance()`。aboutToAppear 时注册 listener，
 *         任务增删 → 重新 listAll() 并赋给 `@State snapshot`（数组级变化）。
 *         单卡片 / 详情的字段级变化由 `@Observed UnifiedTaskView` + `@ObjectLink`
 *         自动处理（列表用 TaskCard，详情用 TaskDetailView）。
 *
 * 2026-06-07 重构：详情屏从本组件的一堆 @Builder 抽成独立 `TaskDetailView`。
 *   原实现靠 detailRev 计数器在 registry 通知时 ++ 来"强制刷新"详情，但 ArkUI 的
 *   `if` 只在分支选择变化时才重建子树——currentStep 一直 detail 时分支不变，@Builder
 *   不重跑 → 进度/状态停在进入瞬间，必须退出再进才刷新一次。改用 @ObjectLink 后字段
 *   级变化直接驱动 TaskDetailView 重渲染，彻底修掉「详情状态不动」。
 */

import {
  DownloadTaskRegistry, RegistryListener, getDownloadTaskRegistry,
} from 'feature_core';
import { UnifiedTaskView } from 'feature_core';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { TaskCard } from './TaskCard';
import { TaskDetailView } from './TaskDetailView';
import { DownloadTaskSnapshot, makeDownloadTaskSnapshot } from './DownloadTaskSnapshot';

/** 筛选 chips */
const FILTER_ALL = 'all'
const FILTER_ACTIVE = 'active'
const FILTER_DONE = 'done'
const FILTER_ERROR = 'error'

/** 子屏 step */
const STEP_LIST = 'list'
const STEP_DETAIL = 'detail'

@Component
export struct DownloadTasksSheet {
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop bottomSafeHeight: number = 0
  @Prop topSafeHeight: number = 0

  /** 当前快照（registry listener 触发时 reassign） */
  @State private snapshot: DownloadTaskSnapshot = makeDownloadTaskSnapshot([])
  @State private currentStep: string = STEP_LIST
  @State private selectedTaskId: string = ''
  @State private filter: string = FILTER_ALL
  /**
   * detail 选中的 view —— 直接作为 TaskDetailView 的 @ObjectLink 源。
   * 它是 registry 里的 @Observed UnifiedTaskView 同一引用，字段变化会被 ObjectLink 捕获。
   */
  @State private selectedView: UnifiedTaskView | null = null

  /** 关闭 sheet（用户点击 ✕ 或所有任务已 purge） */
  onClose: () => void = () => {}

  private registry_: DownloadTaskRegistry = getDownloadTaskRegistry()
  private listener_: RegistryListener = () => { this.refresh() }

  aboutToAppear(): void {
    this.registry_.addListener(this.listener_)
    this.refresh()
  }

  aboutToDisappear(): void {
    this.registry_.removeListener(this.listener_)
  }

  // ============================================================
  //  内部辅助
  // ============================================================

  private refresh(): void {
    this.snapshot = makeDownloadTaskSnapshot(this.registry_.listAll())
    // detail 字段级刷新由 TaskDetailView 的 @ObjectLink 处理，这里只负责数组级
    // 变化。如果正看的任务已被 purge（不在 snapshot 里）→ 回列表，避免悬空详情。
    if (this.currentStep !== STEP_LIST) {
      let exists = false
      for (let v of this.snapshot.all) {
        if (v.id === this.selectedTaskId) { exists = true; break }
      }
      if (!exists) this.backToList_()
    }
  }

  private filteredSnapshot(): UnifiedTaskView[] {
    if (this.filter === FILTER_ACTIVE) return this.snapshot.inProgress
    if (this.filter === FILTER_DONE) return this.snapshot.done
    if (this.filter === FILTER_ERROR) return this.snapshot.failed
    return this.snapshot.all
  }

  // 注：ArkTS @Component 下某些名字会与内部 binder 冲突（如 activeCount），
  // 这里为全部 stats getter 加 get 前缀 + _ 后缀。

  private getAggregateProgress_(): number { return this.snapshot.progress }
  private getActiveCount_(): number   { return this.snapshot.activeCount }
  private getWaitingCount_(): number  { return this.snapshot.waitingCount }
  private getFinishedCount_(): number { return this.snapshot.done.length }
  private hasAnyFinished_(): boolean  { return this.snapshot.done.length + this.snapshot.failed.length > 0 }

  private openDetail_(id: string): void {
    let v = this.registry_.get(id)
    if (!v) return
    this.selectedTaskId = id
    this.selectedView = v
    this.currentStep = STEP_DETAIL
  }

  private backToList_(): void {
    this.currentStep = STEP_LIST
    this.selectedTaskId = ''
    this.selectedView = null
  }

  // ============================================================
  //  build
  // ============================================================

  build() {
    Column() {
      if (this.currentStep === STEP_LIST || this.selectedView === null) {
        this.ListView()
      } else {
        // 详情屏：@ObjectLink 订阅 selectedView 字段级变化 → 实时刷新
        TaskDetailView({
          view: this.selectedView,
          theme: this.theme,
          bottomSafeHeight: this.bottomSafeHeight,
          onBack: () => { this.backToList_() },
          onClose: () => { this.onClose() },
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  Step 1 —— 任务总览
  // ============================================================

  @Builder
  ListView() {
    Column() {
      // ============ Stats Bar ============
      this.StatsBar()

      // ============ Filter Chips ============
      this.FilterChips()

      // ============ 任务列表 / 空态 ============
      if (this.snapshot.all.length === 0) {
        this.EmptyState()
      } else {
        Scroll() {
          Column({ space: 10 }) {
            ForEach(this.filteredSnapshot(), (v: UnifiedTaskView) => {
              TaskCard({
                view: v,
                theme: this.theme,
                onTap: () => { this.openDetail_(v.id) },
                onPause: () => { this.registry_.pause(v.id) },
                onResume: () => { this.registry_.resume(v.id) },
                onCancel: () => { this.registry_.cancel(v.id, false) },
                onRetry: () => { this.registry_.retry(v.id) },
                onRemove: () => { this.registry_.remove(v.id) },
              })
            // ⚠️ key 必须只用 v.id，不能拼 listRev！
            // listRev 进入 key 会导致每次 registry 通知都让所有卡片"key 全变"→
            // ArkUI 销毁全部 TaskCard 重建 → 下载时主线程过载 → 卡死/闪退。
            // 单字段刷新由 @Observed UnifiedTaskView + @ObjectLink TaskCard 处理。
            }, (v: UnifiedTaskView) => v.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }

      // ============ 底部操作栏 ============
      this.BottomBar()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  StatsBar() {
    Column({ space: 12 }) {
      // 标题 + 关闭
      Row() {
        Text('下载管理')
          .fontSize(20)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Stack() {
          AppIcon({ name: AppIconName.Close, iconSize: 18, color: this.theme.textSecondary })
        }
        .width(36).height(36)
        .borderRadius(18)
        .backgroundColor(this.theme.bgInput)
        .onClick(() => { this.onClose() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 三宫格 stats
      Row({ space: 10 }) {
        this.StatCell((): string => this.getActiveCount_().toString(), '进行中', (): ResourceColor => this.theme.primary)
        this.StatCell((): string => this.getWaitingCount_().toString(), '等待中', (): ResourceColor => this.theme.warning)
        this.StatCell((): string => this.getFinishedCount_().toString(), '已完成', (): ResourceColor => this.theme.success)
      }
      .width('100%')

      // 全局进度条
      if (this.getActiveCount_() > 0) {
        Row({ space: 10 }) {
          Progress({
            value: Math.max(0, Math.min(this.getAggregateProgress_(), 100)),
            total: 100,
            type: ProgressType.Linear,
          })
            .layoutWeight(1)
            .height(6)
            .color(this.theme.primary)
            .backgroundColor(this.theme.divider)
          Text(Math.round(this.getAggregateProgress_()) + '%')
            .fontSize(12)
            .fontWeight(700)
            .fontColor(this.theme.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 12 })
  }

  @Builder
  // Builder 的多参数按值传递会固定首次值；动态字段通过回调在 Text 的依赖收集阶段读取。
  StatCell(value: () => string, label: string, valueColor: () => ResourceColor) {
    Column({ space: 2 }) {
      Text(value())
        .fontSize(20)
        .fontWeight(700)
        .fontColor(valueColor())
      Text(label)
        .fontSize(10)
        .fontColor(this.theme.textSecondary)
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  FilterChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.FilterChip(FILTER_ALL,    (): string => '全部 (' + this.snapshot.all.length + ')')
        this.FilterChip(FILTER_ACTIVE, (): string => '进行中 (' + (this.getActiveCount_() + this.getWaitingCount_()) + ')')
        this.FilterChip(FILTER_DONE,   (): string => '已完成 (' + this.getFinishedCount_() + ')')
        this.FilterChip(FILTER_ERROR,  (): string => '失败 (' + this.getErrorCount_() + ')')
      }
      .padding({ left: 16, right: 16, top: 2, bottom: 8 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  private getErrorCount_(): number {
    return this.snapshot.failed.length
  }

  @Builder
  FilterChip(value: string, label: () => string) {
    Text(label())
      .fontSize(12)
      .fontWeight(this.filter === value ? 600 : 500)
      .fontColor(this.filter === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.filter === value ? this.theme.primary : this.theme.bgCard)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => { this.filter = value })
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      AppIcon({
        name: AppIconName.CloudDownload,
        iconSize: 48,
        color: this.theme.textHint,
      })
      Text(this.filter === FILTER_ALL ? '当前没有下载任务' : '当前筛选下没有任务')
        .fontSize(14)
        .fontColor(this.theme.textSecondary)
      if (this.filter === FILTER_ALL) {
        Text('从「下载」页选择 Minecraft 版本或在「模组」中搜索即可开始')
          .fontSize(12)
          .fontColor(this.theme.textHint)
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      } else {
        Text('切到「全部」可看其他任务')
          .fontSize(12)
          .fontColor(this.theme.textHint)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  BottomBar() {
    Row({ space: 10 }) {
      if (this.hasAnyFinished_()) {
        Button('清理已结束')
          .fontSize(13)
          .fontColor(this.theme.textSecondary)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(20)
          .height(38)
          .layoutWeight(1)
          .onClick(() => {
            this.registry_.purgeFinished()
          })
      }
      Button('关闭')
        .fontSize(13)
        .fontColor(this.theme.textOnPrimary)
        .backgroundColor(this.theme.primary)
        .borderRadius(20)
        .height(38)
        .layoutWeight(1)
        .onClick(() => { this.onClose() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: Math.max(16, this.bottomSafeHeight) })
    .backgroundColor(this.theme.bgPrimary)
  }
}

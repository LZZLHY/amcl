/**
 * TaskDetailView.ets — 单个下载任务详情（从 DownloadTasksSheet 抽出，2026-06-07）
 *
 * 为什么要独立成 @Component：
 *   原来详情屏全部写在 DownloadTasksSheet 的 @Builder 里，靠一个 detailRev 计数器
 *   在 registry 通知时 ++ 来"强制刷新"。但 ArkUI V1 的 `if` 组件只在**分支选择变化**
 *   时才重建子树——currentStep 一直是 detail 时分支没变 → @Builder 不会被重新执行，
 *   于是详情里的进度/状态永远停在进入瞬间的快照，必须退出再进才刷新一次。
 *
 * 正确做法（分两层）：
 *   1. 详情屏作为独立 @Component，用 `@ObjectLink view` 订阅 `@Observed UnifiedTaskView`
 *      的字段级变化（和列表里的 TaskCard 同一机制）→ build() 随任务字段变化自动重跑。
 *   2. 阶段行 / 文件行也各自做成独立 @Component，用 @ObjectLink 订阅自己的 @Observed
 *      数据源（PhaseDetailModel / UnifiedTaskView）。这样进度条的 value 是**原地更新**，
 *      而不是靠 ForEach 改 key 销毁重建——后者会让 Progress 每帧从 0 重播进场动画，
 *      看起来像抽搐。@ObjectLink 原地改 value 则平滑过渡。
 *
 * 注意 JDK 三阶段不用 ForEach（直接调 @Builder），组件树位置稳定，build() 重跑时
 * ArkUI 原地更新 Progress.value，本身就平滑，无需独立组件。
 */

import {
  DownloadTaskRegistry, getDownloadTaskRegistry,
} from 'feature_core';
import {
  UnifiedTaskView, UnifiedTaskState, TaskCategory, stateLabel, isActiveState,
} from 'feature_core';
import { McVersionTask } from 'feature_core';
import { ResourceFileProvider, ResourceFileEntry } from 'mods';
import { DownloadPhase, PhaseDetailModel } from 'feature_core';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { formatBytes, formatEta, formatSpeed } from 'commons';

// ============================================================
//  阶段状态 → 颜色 / 图标 / 文案（PhaseRowComp 与 JDK @Builder 共用）
// ============================================================

function phaseColor(theme: ThemeColors, status: string): ResourceColor {
  if (status === 'done')    return theme.success
  if (status === 'error')   return theme.error
  if (status === 'running') return theme.primary
  return theme.textHint
}

function phaseLabelColor(theme: ThemeColors, status: string): ResourceColor {
  if (status === 'pending') return theme.textHint
  if (status === 'done')    return theme.textSecondary
  return theme.textPrimary
}

function phaseIcon(status: string): AppIconName {
  if (status === 'done')    return AppIconName.CheckCircle
  if (status === 'error')   return AppIconName.Error
  if (status === 'running') return AppIconName.ArrowDown
  return AppIconName.Time
}

function phaseRightText(p: PhaseDetailModel): string {
  if (p.status === 'done')    return '100%'
  if (p.status === 'pending') return '待执行'
  if (p.status === 'error')   return '失败'
  if (p.total > 0) return Math.round(100 * p.current / p.total) + '%'
  return '进行中'
}

// ============================================================
//  MC 阶段行 —— @ObjectLink PhaseDetailModel，进度原地更新（不重建 → 不抽搐）
// ============================================================

@Component
struct McPhaseRowComp {
  @ObjectLink phase: PhaseDetailModel
  @Prop theme: ThemeColors

  /** MC 阶段标签随 current/total 实时变化，在组件内算（@ObjectLink 触发重渲染时刷新）。 */
  private label_(): string {
    let p = this.phase
    switch (p.phase) {
      case DownloadPhase.PREPARE:   return '准备版本元数据'
      case DownloadPhase.CLIENT:    return '主程序 jar' + (p.total > 0 ? ' (' + formatBytes(p.total) + ')' : '')
      case DownloadPhase.LIBRARIES: return '依赖库' + (p.total > 0 ? ' (' + p.current + ' / ' + p.total + ')' : '')
      case DownloadPhase.ASSETS:    return '游戏资源 (assets)' + (p.total > 0 ? ' (' + p.current + ' / ' + p.total + ')' : '')
      case DownloadPhase.MODLOADER: return '安装 ModLoader'
      case DownloadPhase.MERGE:     return '合并版本'
      default:                       return p.phase
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        AppIcon({ name: phaseIcon(this.phase.status), iconSize: 18, color: phaseColor(this.theme, this.phase.status) })
        Text(this.label_())
          .fontSize(14)
          .fontWeight(this.phase.status === 'running' ? 600 : 500)
          .fontColor(phaseLabelColor(this.theme, this.phase.status))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(phaseRightText(this.phase))
          .fontSize(13)
          .fontWeight(600)
          .fontColor(phaseColor(this.theme, this.phase.status))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.phase.status === 'running' && this.phase.total > 0) {
        Progress({
          value: Math.max(0, Math.min(this.phase.current, this.phase.total)),
          total: this.phase.total,
          type: ProgressType.Linear,
        })
          .width('100%')
          .height(4)
          .color(this.theme.primary)
          .backgroundColor(this.theme.divider)
      }
      if (this.phase.status === 'running' && this.phase.message && this.phase.message.length > 0) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.ArrowDown, iconSize: 11, color: this.theme.primary })
          Text('正在下载 ' + this.phase.message)
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .border(this.phase.status === 'running'
      ? { width: 1.5, color: this.theme.primary, style: BorderStyle.Solid }
      : (this.phase.status === 'error'
        ? { width: 1.5, color: this.theme.error, style: BorderStyle.Solid }
        : { width: 0 }))
  }
}

// ============================================================
//  资源（模组等）文件行 —— @ObjectLink UnifiedTaskView，进度原地更新
// ============================================================

@Component
struct ModFileRowComp {
  @ObjectLink view: UnifiedTaskView
  @Prop entry: ResourceFileEntry
  @Prop idx: number
  @Prop theme: ThemeColors

  private registry_: DownloadTaskRegistry = getDownloadTaskRegistry()

  /** 是否为「资源安装任务」(ResourceInstallTask 适配器) —— 仅这些可调 getFileEntries/getCurrentDmView。 */
  private isResourceTask_(): boolean {
    let c = this.view.category
    return c === TaskCategory.MOD || c === TaskCategory.SHADER
        || c === TaskCategory.RESOURCE_PACK || c === TaskCategory.DATAPACK
  }

  /** 当前 worker 在跑的文件名集合（从 ResourceInstallTask 现取）。 */
  private activeFiles_(): string[] {
    if (!this.isResourceTask_()) return []
    let a = this.registry_.getAdapter(this.view.id)
    if (!a) return []
    let t = a as object as ResourceFileProvider
    let dmv = t.getCurrentDmView()
    if (!dmv) return []
    return dmv.currentFiles ? dmv.currentFiles : []
  }

  private rowStatus_(): string {
    if (this.view.state === UnifiedTaskState.DONE) return 'done'
    for (let f of this.activeFiles_()) {
      if (f === this.entry.filename) return 'running'
    }
    if (this.idx < this.view.filesDone) return 'done'
    return 'pending'
  }

  private rowColor_(s: string): ResourceColor {
    if (s === 'done')    return this.theme.success
    if (s === 'running') return this.theme.primary
    return this.theme.textHint
  }

  private rowIcon_(s: string): AppIconName {
    if (s === 'done')    return AppIconName.CheckCircle
    if (s === 'running') return AppIconName.ArrowDown
    return AppIconName.Time
  }

  private rightText_(s: string): string {
    if (s === 'done')    return this.entry.sizeBytes > 0 ? formatBytes(this.entry.sizeBytes) : '完成'
    if (s === 'pending') return '等待中'
    if (this.view.bytesTotal > 0) {
      return formatBytes(this.view.bytesDone) + ' / ' + formatBytes(this.view.bytesTotal)
    }
    return this.entry.sizeBytes > 0 ? formatBytes(this.entry.sizeBytes) : ''
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        AppIcon({ name: this.rowIcon_(this.rowStatus_()), iconSize: 18, color: this.rowColor_(this.rowStatus_()) })
        Text(this.entry.filename)
          .fontSize(13)
          .fontWeight(this.rowStatus_() === 'running' ? 600 : 500)
          .fontColor(this.rowStatus_() === 'pending' ? this.theme.textHint : this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.rightText_(this.rowStatus_()))
          .fontSize(12)
          .fontWeight(this.rowStatus_() === 'running' ? 600 : 500)
          .fontColor(this.rowColor_(this.rowStatus_()))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.rowStatus_() === 'running' && this.view.bytesTotal > 0) {
        Progress({
          value: Math.max(0, Math.min(this.view.bytesDone, this.view.bytesTotal)),
          total: this.view.bytesTotal,
          type: ProgressType.Linear,
        })
          .width('100%')
          .height(4)
          .color(this.theme.primary)
          .backgroundColor(this.theme.divider)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .border(this.rowStatus_() === 'running'
      ? { width: 1.5, color: this.theme.primary, style: BorderStyle.Solid }
      : { width: 0 })
  }
}

@Component
export struct TaskDetailView {
  /** 实时任务视图（@Observed），字段级变化自动驱动本组件刷新 —— 这是修复的核心。 */
  @ObjectLink view: UnifiedTaskView
  @Prop theme: ThemeColors
  @Prop bottomSafeHeight: number = 0

  /** 返回任务列表。 */
  onBack: () => void = () => {}
  /** 关闭整个 sheet。 */
  onClose: () => void = () => {}

  private registry_: DownloadTaskRegistry = getDownloadTaskRegistry()

  // ---- 适配器现取（不缓存，build() 重跑时拿最新字段）----
  private mcAdapter_(): McVersionTask | null {
    let a = this.registry_.getAdapter(this.view.id)
    return a ? (a as object as McVersionTask) : null
  }

  /** 是否为「资源安装任务」(ResourceInstallTask 适配器) —— 仅这些可调 getFileEntries。 */
  private isResourceTask_(): boolean {
    let c = this.view.category
    return c === TaskCategory.MOD || c === TaskCategory.SHADER
        || c === TaskCategory.RESOURCE_PACK || c === TaskCategory.DATAPACK
  }

  build() {
    Column() {
      this.DetailHeader_()
      Scroll() {
        Column({ space: 14 }) {
          this.DetailHeroCard_()
          this.DetailStatsRow_()
          if (this.view.category === TaskCategory.MC_VERSION) {
            this.McPhaseListPanel_()
          } else if (this.view.category === TaskCategory.JDK) {
            this.JdkPhaseListPanel_()
          } else if (this.view.category === TaskCategory.MODPACK) {
            this.ModpackInfoPanel_()
          } else {
            this.ResourceFilesPanel_()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      this.DetailActionBar_()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  共用工具
  // ============================================================

  private formatDurationLong_(ms: number): string {
    if (ms <= 0) return '—'
    let s = Math.round(ms / 1000)
    if (s < 60) return s + 's'
    let m = Math.floor(s / 60)
    let rem = s % 60
    return m + 'm ' + rem + 's'
  }

  // ============================================================
  //  MC 阶段进度面板
  // ============================================================

  private mcPhaseList_(): PhaseDetailModel[] {
    let a = this.mcAdapter_()
    if (!a) return []
    return a.dlState.phaseDetails
  }

  private mcPhaseDoneCount_(): number {
    let n = 0
    for (let p of this.mcPhaseList_()) {
      if (p.status === 'done') n++
    }
    return n
  }

  @Builder
  McPhaseListPanel_() {
    Column({ space: 8 }) {
      Row() {
        Text('·  阶段进度 (' + this.mcPhaseDoneCount_() + ' / ' + this.mcPhaseList_().length + ')')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED
            ? this.theme.error : this.theme.textPrimary)
          .layoutWeight(1)
        Text(this.view.durationMs > 0 ? '耗时 ' + this.formatDurationLong_(this.view.durationMs) : '')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 2 })
      .alignItems(VerticalAlign.Center)

      // 稳定 key（仅 phase 枚举），进度原地更新交给 McPhaseRowComp 的 @ObjectLink。
      ForEach(this.mcPhaseList_(), (p: PhaseDetailModel) => {
        McPhaseRowComp({ phase: p, theme: this.theme })
      }, (p: PhaseDetailModel) => p.phase)
    }
    .width('100%')
  }

  // ============================================================
  //  JDK 三阶段面板（直接 @Builder，组件树位置稳定 → 原地更新已平滑）
  // ============================================================

  private jdkPhaseOrder_(s: string): number {
    if (s === UnifiedTaskState.PREPARING)   return 0
    if (s === UnifiedTaskState.DOWNLOADING) return 1
    if (s === UnifiedTaskState.VERIFYING)   return 2
    if (s === UnifiedTaskState.EXTRACTING)  return 3
    if (s === UnifiedTaskState.DONE)        return 4
    return 0
  }

  private jdkPhaseAsDetail_(label: string, phaseState: string, v: UnifiedTaskView): PhaseDetailModel {
    let cur = this.jdkPhaseOrder_(v.state)
    let target = this.jdkPhaseOrder_(phaseState)
    let status: string = 'pending'
    let current: number = 0
    let total: number = 0
    let message: string = ''
    if (v.state === UnifiedTaskState.ERROR || v.state === UnifiedTaskState.ABORTED) {
      status = (target < cur) ? 'done' : (target === cur ? 'error' : 'pending')
    } else if (cur > target) {
      status = 'done'
      current = 1
      total = 1
    } else if (cur === target) {
      status = 'running'
      current = Math.round(v.progress)
      total = 100
      message = v.currentLabel
    } else {
      status = 'pending'
    }
    return new PhaseDetailModel(label, label, status, current, total, message)
  }

  @Builder
  JdkPhaseListPanel_() {
    Column({ space: 8 }) {
      Row() {
        Text('·  安装阶段 (3)')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED
            ? this.theme.error : this.theme.textPrimary)
          .layoutWeight(1)
        Text(this.view.durationMs > 0 ? '耗时 ' + this.formatDurationLong_(this.view.durationMs) : '')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 2 })

      this.JdkPhaseRow_(this.jdkPhaseAsDetail_('JDK 下载',  UnifiedTaskState.DOWNLOADING, this.view))
      this.JdkPhaseRow_(this.jdkPhaseAsDetail_('SHA-256 校验', UnifiedTaskState.VERIFYING, this.view))
      this.JdkPhaseRow_(this.jdkPhaseAsDetail_('解压安装',    UnifiedTaskState.EXTRACTING, this.view))
    }
    .width('100%')
  }

  @Builder
  JdkPhaseRow_(p: PhaseDetailModel) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        AppIcon({ name: phaseIcon(p.status), iconSize: 18, color: phaseColor(this.theme, p.status) })
        Text(p.phase)  // JDK label 存在 phase 字段
          .fontSize(14)
          .fontWeight(p.status === 'running' ? 600 : 500)
          .fontColor(phaseLabelColor(this.theme, p.status))
          .layoutWeight(1)
        Text(phaseRightText(p))
          .fontSize(13)
          .fontWeight(600)
          .fontColor(phaseColor(this.theme, p.status))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (p.status === 'running' && p.total > 0) {
        Progress({
          value: Math.max(0, Math.min(p.current, p.total)),
          total: p.total,
          type: ProgressType.Linear,
        })
          .width('100%')
          .height(4)
          .color(this.theme.primary)
          .backgroundColor(this.theme.divider)
      }
      if (p.status === 'running' && p.message && p.message.length > 0) {
        Text(p.message)
          .fontSize(11)
          .fontColor(this.theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .border(p.status === 'running'
      ? { width: 1.5, color: this.theme.primary, style: BorderStyle.Solid }
      : (p.status === 'error'
        ? { width: 1.5, color: this.theme.error, style: BorderStyle.Solid }
        : { width: 0 }))
  }

  // ============================================================
  //  资源（模组等）文件列表面板
  // ============================================================

  private modFileEntries_(): ResourceFileEntry[] {
    if (!this.isResourceTask_()) return []
    let a = this.registry_.getAdapter(this.view.id)
    if (!a) return []
    let t = a as object as ResourceFileProvider
    return t.getFileEntries()
  }

  // ============================================================
  //  整合包信息面板（无文件级明细，展示阶段/状态/缺失提示）
  // ============================================================

  @Builder
  ModpackInfoPanel_() {
    Column({ space: 8 }) {
      Row() {
        Text('·  整合包安装')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED
            ? this.theme.error : this.theme.textPrimary)
          .layoutWeight(1)
        Text(this.view.durationMs > 0 ? '耗时 ' + this.formatDurationLong_(this.view.durationMs) : '')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 2 })

      Text(this.view.currentLabel.length > 0 ? this.view.currentLabel : stateLabel(this.view.state))
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .width('100%')
      if (this.view.filesTotal > 0 && this.view.state !== UnifiedTaskState.DONE) {
        Text('文件 ' + this.view.filesDone + ' / ' + this.view.filesTotal)
          .fontSize(12)
          .fontColor(this.theme.textHint)
          .width('100%')
          .margin({ top: 2 })
      }
      if (this.view.state === UnifiedTaskState.ERROR && this.view.errorMessage.length > 0) {
        Text(this.view.errorMessage)
          .fontSize(12)
          .fontColor(this.theme.error)
          .width('100%')
          .margin({ top: 4 })
      }
      Text('整合包会创建一个独立新版本（下载基础版本+加载器、批量下模组、铺覆盖文件）。完成后可在版本列表查看。')
        .fontSize(11)
        .fontColor(this.theme.textHint)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
  }

  @Builder
  ResourceFilesPanel_() {
    Column({ space: 8 }) {
      Row() {
        Text('·  文件进度 (' + this.view.filesDone + ' / ' + this.view.filesTotal + ')')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED
            ? this.theme.error : this.theme.textPrimary)
          .layoutWeight(1)
        Text(this.view.durationMs > 0 ? '耗时 ' + this.formatDurationLong_(this.view.durationMs) : '')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 2 })

      // 稳定 key（文件名+序号），进度原地更新交给 ModFileRowComp 的 @ObjectLink。
      ForEach(this.modFileEntries_(), (entry: ResourceFileEntry, idx: number) => {
        ModFileRowComp({ view: this.view, entry: entry, idx: idx, theme: this.theme })
      }, (entry: ResourceFileEntry, idx: number) => entry.filename + ':' + idx)
    }
    .width('100%')
  }

  // ============================================================
  //  Header
  // ============================================================

  @Builder
  DetailHeader_() {
    Row({ space: 10 }) {
      Stack() {
        AppIcon({ name: AppIconName.Back, iconSize: 18, color: this.theme.textPrimary })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.bgCard)
      .onClick(() => { this.onBack() })

      Column({ space: 1 }) {
        Text(this.detailHeaderLabel_())
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.detailHeaderLabelColor_())
          .maxLines(1)
        Text(this.view.title)
          .fontSize(18)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Stack() {
        AppIcon({ name: AppIconName.More, iconSize: 18, color: this.theme.textSecondary })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.bgCard)
      .onClick(() => { this.onClose() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  private detailHeaderLabel_(): string {
    let v = this.view
    if (v.state === UnifiedTaskState.ERROR)   return '任务详情 · 失败'
    if (v.state === UnifiedTaskState.ABORTED) return '任务详情 · 已取消'
    if (v.state === UnifiedTaskState.DONE)    return '任务详情 · 已完成'
    if (v.state === UnifiedTaskState.PAUSED)  return '任务详情 · 已暂停'
    return '任务详情'
  }

  private detailHeaderLabelColor_(): ResourceColor {
    let v = this.view
    if (v.state === UnifiedTaskState.ERROR || v.state === UnifiedTaskState.ABORTED) return this.theme.error
    if (v.state === UnifiedTaskState.DONE)   return this.theme.success
    if (v.state === UnifiedTaskState.PAUSED) return this.theme.warning
    return this.theme.textHint
  }

  // ============================================================
  //  Hero Card
  // ============================================================

  @Builder
  DetailHeroCard_() {
    Column({ space: 12 }) {
      Stack() {
        Progress({
          value: Math.max(0, Math.min(this.view.progress, 100)),
          total: 100,
          type: ProgressType.Ring,
        })
          .width(140).height(140)
          .style({ strokeWidth: 12, scaleCount: 0, scaleWidth: 0 })
          .color(this.heroRingColor_(this.view))
          .backgroundColor(this.heroRingBg_(this.view))

        if (this.isHeroError_(this.view)) {
          Column({ space: 4 }) {
            AppIcon({ name: AppIconName.Close, iconSize: 36, color: this.theme.error })
            Text('下载失败')
              .fontSize(12)
              .fontWeight(600)
              .fontColor(this.theme.error)
          }
          .alignItems(HorizontalAlign.Center)
        } else {
          Column({ space: 4 }) {
            Text(Math.round(this.view.progress) + '%')
              .fontSize(34)
              .fontWeight(700)
              .fontColor(this.heroRingColor_(this.view))
            Text(stateLabel(this.view.state))
              .fontSize(11)
              .fontWeight(500)
              .fontColor(this.theme.textSecondary)
          }
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width(140).height(140)

      Text(this.heroTitleText_(this.view))
        .fontSize(16)
        .fontWeight(600)
        .fontColor(this.isHeroError_(this.view) ? this.theme.error : this.theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)

      Text(this.view.subtitle)
        .fontSize(12)
        .fontColor(this.theme.textHint)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 22 })
    .backgroundColor(this.heroCardBg_(this.view))
    .borderRadius(20)
    .alignItems(HorizontalAlign.Center)
  }

  private heroTitleText_(v: UnifiedTaskView): string {
    if (this.isHeroError_(v)) return v.title
    if (v.state === UnifiedTaskState.DONE) return '安装完成 ' + v.title
    if (v.state === UnifiedTaskState.PAUSED) return '已暂停 ' + v.title
    if (v.state === UnifiedTaskState.WAITING) return '排队中 ' + v.title
    return '正在安装 ' + v.title
  }

  private isHeroError_(v: UnifiedTaskView): boolean {
    return v.state === UnifiedTaskState.ERROR || v.state === UnifiedTaskState.ABORTED
  }

  private heroCardBg_(v: UnifiedTaskView): ResourceColor {
    if (this.isHeroError_(v)) return this.theme.errorBg
    return this.theme.bgCard
  }

  private heroRingColor_(v: UnifiedTaskView): ResourceColor {
    if (v.state === UnifiedTaskState.DONE)   return this.theme.success
    if (this.isHeroError_(v))                return this.theme.error
    if (v.state === UnifiedTaskState.PAUSED || v.state === UnifiedTaskState.WAITING) return this.theme.warning
    if (v.category === TaskCategory.MC_VERSION)    return this.theme.taskMcBlue
    if (v.category === TaskCategory.MOD)           return this.theme.taskModPurple
    if (v.category === TaskCategory.SHADER)        return this.theme.taskShaderIndigo
    if (v.category === TaskCategory.RESOURCE_PACK) return this.theme.taskRpackPink
    if (v.category === TaskCategory.DATAPACK)      return this.theme.taskDatapackTeal
    if (v.category === TaskCategory.MODPACK)       return this.theme.taskModpackOrange
    if (v.category === TaskCategory.JDK)           return this.theme.taskJdkRedOrange
    return this.theme.primary
  }

  private heroRingBg_(v: UnifiedTaskView): ResourceColor {
    if (this.isHeroError_(v)) return '#F9D9DA'
    return this.theme.divider
  }

  // ============================================================
  //  Stats Row
  // ============================================================

  //
  // ⚠️ 内联渲染（2026-07-03 修复「详情页速度/已下载/剩余卡死」）：
  //   三个 stat cell 必须直接在本 @Builder 里读 this.view.* 后渲染 Text，
  //   不能再抽成 DetailStatCell_(value: string, ...) 那样把**已算好的字符串**当
  //   【值类型基本参数】传给子 @Builder —— ArkUI V1 对 @Builder 的值类型基本参数
  //   不建立依赖追踪，this.view.speedBps/bytesDone/etaSeconds 变化时子 @Builder 的
  //   Text 不会刷新，于是"进度条（直接读 this.view.progress / 各自 @ObjectLink 的
  //   阶段行）照常推进，但速度/已下载/剩余卡死"。直接读 this.view.* 的 Text 才是
  //   响应式的。同一坑在 HomeTab/DownloadTab 也靠内联规避（见其注释）。
  //
  @Builder
  DetailStatsRow_() {
    Row() {
      // ---- 已下载 ----
      Column({ space: 4 }) {
        Text(this.view.bytesTotal > 0
          ? formatBytes(this.view.bytesDone) + ' / ' + formatBytes(this.view.bytesTotal)
          : (this.view.bytesDone > 0 ? formatBytes(this.view.bytesDone) : '—'))
          .fontSize(15)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('已下载')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      // ---- 速度 / 错误 ----
      Column({ space: 4 }) {
        Text(this.isHeroError_(this.view)
          ? (this.view.errorKind.length > 0 ? this.view.errorKind : '失败')
          : (this.view.speedBps > 0 ? formatSpeed(this.view.speedBps) : '—'))
          .fontSize(15)
          .fontWeight(700)
          .fontColor(this.isHeroError_(this.view) ? this.theme.error : this.theme.primary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.isHeroError_(this.view) ? '错误' : '速度')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      // ---- 耗时 / 剩余 ----
      Column({ space: 4 }) {
        Text((this.isHeroError_(this.view) || this.view.state === UnifiedTaskState.DONE)
          ? (this.view.durationMs > 0 ? this.formatDurationLong_(this.view.durationMs) : '—')
          : (this.view.etaSeconds >= 0 ? '~ ' + formatEta(this.view.etaSeconds) : '—'))
          .fontSize(15)
          .fontWeight(700)
          .fontColor((this.isHeroError_(this.view) || this.view.state === UnifiedTaskState.DONE)
            ? this.theme.textPrimary : this.theme.success)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.isHeroError_(this.view) || this.view.state === UnifiedTaskState.DONE) ? '耗时' : '剩余')
          .fontSize(11)
          .fontColor(this.theme.textHint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  // ============================================================
  //  Action Bar
  // ============================================================

  @Builder
  DetailActionBar_() {
    Row({ space: 12 }) {
      if (this.view.state === UnifiedTaskState.DONE) {
        this.PrimaryActionBtn_(AppIconName.Check, '完成',
          this.theme.textOnPrimary, this.theme.success,
          () => this.onBack())
      } else if (this.isHeroError_(this.view)) {
        this.PrimaryActionBtn_(AppIconName.Refresh, '重试',
          this.theme.textOnPrimary, this.theme.primary,
          () => { this.registry_.retry(this.view.id) })
        this.SecondaryCircleBtn_(AppIconName.Trash, this.theme.textHint,
          this.theme.bgCard, () => { this.registry_.remove(this.view.id) })
      } else if (this.view.canResume) {
        this.PrimaryActionBtn_(AppIconName.Play, '继续下载',
          this.theme.textOnPrimary, this.theme.primary,
          () => { this.registry_.resume(this.view.id) })
        this.SecondaryCircleBtn_(AppIconName.Close, this.theme.error,
          this.theme.errorBg, () => { this.registry_.cancel(this.view.id, false) })
      } else if (this.view.canPause && isActiveState(this.view.state)) {
        this.PrimaryActionBtn_(AppIconName.Close, '取消下载',
          this.theme.error, this.theme.errorBg,
          () => { this.registry_.cancel(this.view.id, false) })
        this.SecondaryCircleBtn_(AppIconName.Pause, this.theme.textSecondary,
          this.theme.bgCard, () => { this.registry_.pause(this.view.id) })
      } else if (this.view.canCancel) {
        this.PrimaryActionBtn_(AppIconName.Close, '取消下载',
          this.theme.error, this.theme.errorBg,
          () => { this.registry_.cancel(this.view.id, false) })
      } else {
        this.PrimaryActionBtn_(AppIconName.Back, '返回列表',
          this.theme.textSecondary, this.theme.bgCard, () => this.onBack())
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: Math.max(16, this.bottomSafeHeight) })
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  PrimaryActionBtn_(icon: AppIconName, label: string, fgColor: ResourceColor,
                    bgColor: ResourceColor, handler: () => void) {
    Row({ space: 8 }) {
      AppIcon({ name: icon, iconSize: 16, color: fgColor })
      Text(label)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(fgColor)
    }
    .layoutWeight(1)
    .height(46)
    .borderRadius(23)
    .backgroundColor(bgColor)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(handler)
  }

  @Builder
  SecondaryCircleBtn_(icon: AppIconName, fgColor: ResourceColor,
                      bgColor: ResourceColor, handler: () => void) {
    Stack() {
      AppIcon({ name: icon, iconSize: 18, color: fgColor })
    }
    .width(46).height(46)
    .borderRadius(23)
    .backgroundColor(bgColor)
    .onClick(handler)
  }
}

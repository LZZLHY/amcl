/**
 * TaskCard.ets — 统一任务列表卡片（v6.5 2026-05-22）
 *
 * 七种任务分类（MC / Mod / Shader / RPack / Datapack / Modpack / JDK）共用
 * 同一份卡片结构，差异仅在徽章色 + 图标 + 进度条颜色。
 *
 * 设计稿：docs/design/download-page-redesign/10_download_tasks_sheet.png
 *
 * 视觉结构：
 *   ┌──────────────────────────────────────┐
 *   │ [44]   Title                  [⏸][✕] │
 *   │        subtitle                       │
 *   │        ●●●○○○○○○○                 68% │  ← progress bar + percent
 *   │        ↓ 4.2 MB/s · ~20s              │  ← meta row
 *   └──────────────────────────────────────┘
 */

import {
  UnifiedTaskView, UnifiedTaskState, TaskCategory, stateLabel,
} from 'feature_core';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { VersionBlockIcon } from './VersionBlockIcon';
import { taskCategoryIcon } from '../components/ResourceIcons';
import { formatBytes, formatEta, formatSpeed } from 'commons';

@Component
export struct TaskCard {
  @ObjectLink view: UnifiedTaskView
  @Prop theme: ThemeColors = {} as ThemeColors
  /** 远程图标加载失败 → 回退到分类图标（避免透明图标露出底下兜底图标） */
  @State private iconErr: boolean = false

  /** 卡片整体点击 → 进 detail subview */
  onTap: () => void = () => {}
  /** 暂停 / 恢复 / 取消 / 重试 / 移除（终态） */
  onPause: () => void = () => {}
  onResume: () => void = () => {}
  onCancel: () => void = () => {}
  onRetry: () => void = () => {}
  onRemove: () => void = () => {}

  // ============================================================
  //  分类 → 颜色 / 图标
  // ============================================================

  private categoryColor(): ResourceColor {
    switch (this.view.category) {
      case TaskCategory.MC_VERSION:    return this.theme.taskMcBlue
      case TaskCategory.MOD:           return this.theme.taskModPurple
      case TaskCategory.SHADER:        return this.theme.taskShaderIndigo
      case TaskCategory.RESOURCE_PACK: return this.theme.taskRpackPink
      case TaskCategory.DATAPACK:      return this.theme.taskDatapackTeal
      case TaskCategory.MODPACK:       return this.theme.taskModpackOrange
      case TaskCategory.JDK:           return this.theme.taskJdkRedOrange
      default:                          return this.theme.primary
    }
  }

  private categoryBg(): ResourceColor {
    switch (this.view.category) {
      case TaskCategory.MC_VERSION:    return this.theme.taskMcBg
      case TaskCategory.MOD:           return this.theme.taskModBg
      case TaskCategory.SHADER:        return this.theme.taskShaderBg
      case TaskCategory.RESOURCE_PACK: return this.theme.taskRpackBg
      case TaskCategory.DATAPACK:      return this.theme.taskDatapackBg
      case TaskCategory.MODPACK:       return this.theme.taskModpackBg
      case TaskCategory.JDK:           return this.theme.taskJdkBg
      default:                          return this.theme.primaryLight
    }
  }

  // 2026-05-22：TaskCategory → AppIconName 已迁出到 components/ResourceIcons.taskCategoryIcon。
  // 下面 build() 里遇到 MC_VERSION 会优先用 VersionBlockIcon（PNG 方块），
  // 只有非 MC_VERSION 任务才走 taskCategoryIcon 这条路。

  // ============================================================
  //  状态 → 颜色 / 图标
  // ============================================================

  private isWaiting(): boolean { return this.view.state === UnifiedTaskState.WAITING }
  private isActive(): boolean {
    let s = this.view.state
    return s === UnifiedTaskState.PREPARING || s === UnifiedTaskState.DOWNLOADING
        || s === UnifiedTaskState.EXTRACTING || s === UnifiedTaskState.VERIFYING
  }
  private isPaused(): boolean { return this.view.state === UnifiedTaskState.PAUSED }
  private isDone(): boolean { return this.view.state === UnifiedTaskState.DONE }
  private isError(): boolean {
    return this.view.state === UnifiedTaskState.ERROR || this.view.state === UnifiedTaskState.ABORTED
  }

  /** 进度条主色（活跃时用分类色；暂停 warning；终态对应色） */
  private progressColor(): ResourceColor {
    if (this.isDone()) return this.theme.success
    if (this.isError()) return this.theme.error
    if (this.isPaused() || this.isWaiting()) return this.theme.warning
    return this.categoryColor()
  }

  private progressBgColor(): ResourceColor {
    if (this.isWaiting()) return this.theme.bgInput
    return this.theme.divider
  }

  /** 状态行图标（"↓ 下载中"前面那个） */
  private statusIcon(): AppIconName {
    if (this.isDone())   return AppIconName.CheckCircle
    if (this.isError())  return AppIconName.Error
    if (this.isPaused()) return AppIconName.Pause
    if (this.isWaiting())return AppIconName.Hourglass
    if (this.view.state === UnifiedTaskState.EXTRACTING) return AppIconName.DataPack
    if (this.view.state === UnifiedTaskState.VERIFYING)  return AppIconName.Check
    return AppIconName.ArrowDown
  }

  private statusIconColor(): ResourceColor {
    if (this.isDone())   return this.theme.success
    if (this.isError())  return this.theme.error
    if (this.isPaused() || this.isWaiting()) return this.theme.warning
    return this.categoryColor()
  }

  // ============================================================
  //  状态文案
  // ============================================================

  /** 进度条右侧大百分比 / 等待编号 */
  private percentLabel(): string {
    if (this.isWaiting()) {
      return this.view.queuePosition > 0 ? '队列第 ' + this.view.queuePosition + ' 位' : '等待中'
    }
    return Math.round(this.view.progress) + '%'
  }

  /** meta 行左侧（"4.2 MB/s · ~20s · 阶段 3/6"） */
  private metaLeft(): string {
    if (this.isWaiting())  return '待启动'
    if (this.isDone())     return '完成 · 用时 ' + this.formatDuration_(this.view.durationMs)
    if (this.isError())    return this.view.errorKind ? this.view.errorKind + ' · 失败' : '失败'

    let parts: string[] = []
    if (this.view.speedBps > 0 && this.isActive() && !this.isPaused()) {
      parts.push(formatSpeed(this.view.speedBps))
    }
    if (this.view.etaSeconds >= 0 && this.isActive() && !this.isPaused()) {
      parts.push('~ ' + formatEta(this.view.etaSeconds))
    }
    if (this.view.currentLabel.length > 0) {
      parts.push(this.view.currentLabel)
    }
    if (parts.length === 0) {
      // fallback
      parts.push(stateLabel(this.view.state))
    }
    return parts.join(' · ')
  }

  /** meta 行右侧（"195 / 285 MB"） */
  private metaRight(): string {
    if (this.isWaiting()) {
      return this.view.bytesTotal > 0 ? '~' + formatBytes(this.view.bytesTotal) : ''
    }
    if (this.view.bytesTotal > 0) {
      return formatBytes(this.view.bytesDone) + ' / ' + formatBytes(this.view.bytesTotal)
    }
    if (this.view.filesTotal > 0) {
      return this.view.filesDone + ' / ' + this.view.filesTotal + ' 文件'
    }
    return ''
  }

  private formatDuration_(ms: number): string {
    if (ms <= 0) return '—'
    let s = Math.round(ms / 1000)
    if (s < 60) return s + 's'
    let m = Math.floor(s / 60)
    let rem = s % 60
    return m + 'm ' + rem + 's'
  }

  // ============================================================
  //  build
  // ============================================================

  build() {
    Column({ space: 10 }) {
      // ============= top row：badge + title + actions =============
      Row({ space: 12 }) {
        // 分类徽章：
        //   - MC_VERSION + view.title 是合法 versionId → 走 VersionBlockIcon（PNG 方块 / loader 图标）
        //     与版本列表 / 版本详情 / 主页英雄卡保持同一套视觉
        //   - 其他类别 → AppIcon（SymbolGlyph 照旧）
        //   - MC_VERSION 但 view.title 为空 → 兑底走 AppIcon。
        Stack() {
          // 远程项目图标（模组/资源）优先；为空或加载失败时回退分类图标。
          // 用 if/else 而非叠层，避免半透明 PNG 图标露出底下的兜底图标。
          if (this.view.iconUrl.length > 0 && !this.iconErr) {
            Image(this.view.iconUrl)
              .width(44).height(44)
              .objectFit(ImageFit.Cover)
              .draggable(false)
              .onError(() => { this.iconErr = true })
          } else if (this.view.category === TaskCategory.MC_VERSION && this.view.title.length > 0) {
            VersionBlockIcon({
              versionId: this.view.title,
              iconSize: 30,
              cornerRadius: 6,
            })
          } else {
            AppIcon({
              name: taskCategoryIcon(this.view.category),
              iconSize: 22,
              color: this.categoryColor(),
            })
          }
        }
        .width(44).height(44)
        .borderRadius(14)
        .clip(true)
        .backgroundColor(this.categoryBg())

        // 标题列
        Column({ space: 3 }) {
          Text(this.view.title)
            .fontSize(15)
            .fontWeight(600)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.view.subtitle)
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 操作按钮组
        this.ActionGroup()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ============= progress row（隐藏：仅 done/error 不显示） =============
      if (!this.isDone() && !this.isError()) {
        Row({ space: 10 }) {
          Progress({
            value: Math.max(0, Math.min(this.view.progress, 100)),
            total: 100,
            type: ProgressType.Linear,
          })
            .layoutWeight(1)
            .height(6)
            .color(this.progressColor())
            .backgroundColor(this.progressBgColor())

          Text(this.percentLabel())
            .fontSize(this.isWaiting() ? 11 : 12)
            .fontWeight(this.isWaiting() ? 600 : 700)
            .fontColor(this.isWaiting() ? this.theme.warning : this.theme.textPrimary)
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ============= meta row =============
      Row() {
        Row({ space: 6 }) {
          AppIcon({
            name: this.statusIcon(),
            iconSize: 12,
            color: this.statusIconColor(),
          })
          Text(this.metaLeft())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.isError() ? this.theme.error : this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        if (this.metaRight().length > 0) {
          Text(this.metaRight())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textHint)
            .maxLines(1)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .onClick(() => { this.onTap() })
  }

  @Builder
  ActionGroup() {
    Row({ space: 6 }) {
      // 主操作（pause / resume / retry）
      if (this.view.canPause && this.isActive()) {
        this.IconButton(AppIconName.Pause, this.theme.bgInput, this.theme.textSecondary, () => this.onPause())
      } else if (this.view.canResume) {
        this.IconButton(AppIconName.Play, this.theme.primaryLight, this.theme.primary, () => this.onResume())
      } else if (this.view.canRetry) {
        this.IconButton(AppIconName.Refresh, this.theme.primaryLight, this.theme.primary, () => this.onRetry())
      }

      // 副操作：取消（活跃 / 暂停）或 移除（终态）
      if (this.view.canCancel) {
        this.IconButton(AppIconName.Close, this.theme.errorBg, this.theme.error, () => this.onCancel())
      } else if (this.isDone() || this.isError()) {
        this.IconButton(AppIconName.Trash, this.theme.bgInput, this.theme.textHint, () => this.onRemove())
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  IconButton(icon: AppIconName, bgColor: ResourceColor, iconColor: ResourceColor, onClick: () => void) {
    Stack() {
      AppIcon({ name: icon, iconSize: 16, color: iconColor })
    }
    .width(34).height(34)
    .borderRadius(17)
    .backgroundColor(bgColor)
    .onClick(() => {
      // 阻止冒泡到卡片 onTap——ArkUI .onClick 不会冒泡到父的 onClick，
      // 但如果外部也是 Stack 的话可能会。实际测试表明：ArkUI 点击事件会冒泡，
      // 为安全起见调用方的 onClick 实现应该不依赖以上层级 onTap 不出发
      onClick()
    })
  }
}

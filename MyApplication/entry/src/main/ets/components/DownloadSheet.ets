/**
 * DownloadSheet.ets — 版本下载进度 Sheet（Phase R-3 重设计 2026-05-13）
 *
 * 设计稿：docs/design/download-page-redesign/08_version_download_progress.png（Screen H）
 *
 * v5.2（保留）: 使用 @ObjectLink + @Observed 替代 @Prop，
 *               解决 bindSheet 内组件不响应父组件 @State 变化的问题。
 *
 * Phase R-3 视觉升级：
 *   - 顶部 Hero Card：120 dp 圆环 + 30 sp 大百分比 + 标题 + 副标题
 *   - Stats 三列网格：已下/总 · 速度 · 剩余
 *   - 阶段卡片列表（保留现有 DownloadPhaseCard，对齐 6 阶段独立 progress）
 *   - 底部 CTA：红色"取消"主按钮 + 圆形⏸暂停（取代现有平铺按钮组）
 */

import { DownloadPhase, PhaseDetailModel, FailedFileBrief, DownloadStateModel } from 'feature_core';
import { DownloadPhaseCard } from './DownloadPhaseCard';
import { ThemeColors } from 'commons';
import { formatBytes, formatEta, formatDurationMs, formatSpeed } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

@Component
export struct DownloadSheet {
  @ObjectLink dlState: DownloadStateModel
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop bottomSafeHeight: number = 0

  onPause: () => void = () => {}
  onResume: () => void = () => {}
  onCancel: () => void = () => {}
  onRetry: () => void = () => {}
  onClose: () => void = () => {}

  private isDownloading(): boolean {
    return this.dlState.phase === DownloadPhase.PREPARE
      || this.dlState.phase === DownloadPhase.CLIENT
      || this.dlState.phase === DownloadPhase.LIBRARIES
      || this.dlState.phase === DownloadPhase.ASSETS
      || this.dlState.phase === DownloadPhase.MODLOADER
      || this.dlState.phase === DownloadPhase.MERGE
  }

  private isPaused(): boolean {
    return this.dlState.phase === DownloadPhase.PAUSED || this.dlState.phase === DownloadPhase.ABORTED
  }

  private isSuccess(): boolean {
    return this.dlState.phase === DownloadPhase.DONE
  }

  private isError(): boolean {
    return this.dlState.phase === DownloadPhase.ERROR
  }

  private getTitleIcon(): AppIconName {
    if (this.isSuccess()) return AppIconName.CheckCircle
    if (this.isError()) return AppIconName.Error
    if (this.isPaused()) return AppIconName.Pause
    return AppIconName.Download
  }

  private getTitleIconColor(): ResourceColor {
    if (this.isSuccess()) return this.theme.success
    if (this.isError()) return this.theme.error
    if (this.isPaused()) return this.theme.warning
    return this.theme.primary
  }

  private getTitleText(): string {
    if (this.isSuccess()) return '下载完成'
    if (this.isError()) return '下载失败'
    if (this.isPaused()) return '下载已暂停'
    return '下载中'
  }

  private getProgressColor(): ResourceColor {
    if (this.isSuccess()) return this.theme.success
    if (this.isError()) return this.theme.error
    if (this.isPaused()) return this.theme.warning
    return this.theme.primary
  }

  private getActivePhase(): string {
    for (let d of this.dlState.phaseDetails) {
      if (d.status === 'running') return d.phase
    }
    return ''
  }

  private getFailedFilesForPhase(phase: string): FailedFileBrief[] {
    for (let d of this.dlState.phaseDetails) {
      if (d.phase === phase && d.status === 'error') {
        return this.dlState.failedFiles
      }
    }
    return []
  }

  // ============================================================
  //  Phase R-3 新增 Builder：Hero Card + Stats Row
  // ============================================================

  @Builder
  HeroProgressCard() {
    Column({ space: 10 }) {
      // 120 dp 同心圆环（外环色 + 内环白底 + 中央大字百分比）
      Stack() {
        Column()
          .width(120).height(120)
          .borderRadius(60)
          .backgroundColor(this.theme.primaryLight)
        Column()
          .width(98).height(98)
          .borderRadius(49)
          .backgroundColor(this.theme.bgCard)
        Column({ space: 0 }) {
          Text(Math.round(this.dlState.progress) + '%')
            .fontSize(30)
            .fontWeight(700)
            .fontColor(this.getProgressColor())
          Text(this.getTitleText())
            .fontSize(10)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(120).height(120)

      // 标题 + 副标题
      Text(this.heroTitle())
        .fontSize(16)
        .fontWeight(600)
        .fontColor(this.theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.dlState.versionName.length > 0) {
        Text(this.dlState.versionName)
          .fontSize(11)
          .fontColor(this.theme.textHint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .margin({ left: 20, right: 20, top: 4 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(18)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  StatsRow() {
    Row() {
      this.StatCell(
        this.dlState.bytesTotal > 0 ? formatBytes(this.dlState.bytesDone) : '—',
        this.dlState.bytesTotal > 0 ? '已下 / ' + formatBytes(this.dlState.bytesTotal) : '已下',
        this.theme.textPrimary
      )
      this.StatCell(
        this.dlState.speed.length > 0 ? this.dlState.speed : '—',
        '速度',
        this.theme.primary
      )
      this.StatCell(
        this.isDownloading() && this.dlState.etaSeconds >= 0
          ? '~ ' + formatEta(this.dlState.etaSeconds)
          : (this.dlState.durationMs > 0 ? formatDurationMs(this.dlState.durationMs) : '—'),
        this.isDownloading() ? '剩余' : '耗时',
        this.theme.success
      )
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 4 })
  }

  @Builder
  StatCell(value: string, label: string, valueColor: ResourceColor) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(700)
        .fontColor(valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(10)
        .fontColor(this.theme.textHint)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
  }

  private heroTitle(): string {
    if (this.isSuccess()) return '下载完成 · ' + this.dlState.versionName
    if (this.isError()) return '下载失败 · ' + this.dlState.versionName
    if (this.isPaused()) return '已暂停 · ' + this.dlState.versionName
    return '正在安装 ' + this.dlState.versionName
  }

  build() {
    Column() {
      // ==================== Hero Card：120 dp 圆环 + 大百分比 ====================
      this.HeroProgressCard()

      // ==================== Stats 三列网格 ====================
      if (this.dlState.bytesTotal > 0 || this.dlState.speed.length > 0 || this.dlState.etaSeconds >= 0) {
        this.StatsRow()
      }

      // ==================== 阶段卡片列表 ====================
      Scroll() {
        Column() {
          ForEach(this.dlState.phaseDetails, (detail: PhaseDetailModel) => {
            DownloadPhaseCard({
              detail: detail,
              currentFiles: detail.phase === this.getActivePhase() ? this.dlState.currentFiles : [],
              failedFiles: this.getFailedFilesForPhase(detail.phase),
              theme: this.theme,
              isActivePhase: detail.phase === this.getActivePhase(),
            })
          }, (detail: PhaseDetailModel) => detail.phase)

          if (this.isError() && this.dlState.errorMessage) {
            Column() {
              Text('错误详情')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.error)
                .margin({ bottom: 4 })
              Text(this.dlState.errorKind ? this.dlState.errorKind + ': ' + this.dlState.errorMessage : this.dlState.errorMessage)
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
                .maxLines(5)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.theme.errorBg)
            .borderRadius(8)
            .margin({ top: 4 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // ==================== 底部操作栏 ====================
      Row() {
        if (this.isDownloading()) {
          Button('暂停')
            .fontSize(14)
            .fontColor(this.theme.primary)
            .backgroundColor(this.theme.primaryLight)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => this.onPause())

          Button('取消')
            .fontSize(14)
            .fontColor(this.theme.error)
            .backgroundColor(this.theme.errorBg)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick(() => this.onCancel())
        } else if (this.isPaused()) {
          Button('继续下载')
            .fontSize(14)
            .fontColor(this.theme.textOnPrimary)
            .backgroundColor(this.theme.primary)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => this.onResume())

          Button('取消')
            .fontSize(14)
            .fontColor(this.theme.error)
            .backgroundColor(this.theme.errorBg)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick(() => this.onCancel())
        } else if (this.isError()) {
          Button('重试')
            .fontSize(14)
            .fontColor(this.theme.textOnPrimary)
            .backgroundColor(this.theme.primary)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => this.onRetry())

          Button('关闭')
            .fontSize(14)
            .fontColor(this.theme.textSecondary)
            .backgroundColor(this.theme.bgPrimary)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick(() => this.onClose())
        } else if (this.isSuccess()) {
          Button('完成')
            .fontSize(14)
            .fontColor(this.theme.textOnPrimary)
            .backgroundColor(this.theme.success)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .onClick(() => this.onClose())
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: Math.max(16, this.bottomSafeHeight) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }
}

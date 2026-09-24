/**
 * DownloadFab.ets — 浮动下载进度圆 (v5.1)
 *
 * 右下角 56dp 圆形 FAB：
 *   - 外圈：Ring 进度条显示全局百分比
 *   - 内部：下载箭头动画（循环）或终态符号
 *   - 终态：成功变绿 ✓ / 失败变红 ✗ / 暂停 ‖
 *   - 短按打开 Sheet，长距离拖动移动位置，松手吸附左/右屏幕边缘
 *   - 支持 fadeOut() 方法供父组件调用淡出消失
 */

import { DownloadPhase } from 'feature_core';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import {
  DOWNLOAD_FAB_SIZE, DownloadFabLayoutPolicy, DownloadFabPosition,
} from '../window/DownloadFabLayoutPolicy';

const RING_STROKE = 4
const INNER_SIZE = DOWNLOAD_FAB_SIZE - RING_STROKE * 2

@Component
export struct DownloadFab {
  @Prop active: boolean = false
  @Prop phase: string = ''
  @Prop progress: number = 0
  @Prop theme: ThemeColors = {} as ThemeColors

  /**
   * Phase R-4 新增：当前活跃任务数 badge（含 MC 版本下载 + Mod 下载等）。
   * 0 表示不显示 badge。Index 端聚合 `mcDownloading + activeTasksByCategory('mod:').length`。
   */
  @Prop activeTaskCount: number = 0

  @Link fabOffsetX: number
  @Link fabOffsetY: number
  /** 当前 ArkUI 可绘制窗口尺寸（vp），由 Index 的主窗口监听统一下发。 */
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 800
  @Prop bottomSafeHeight: number = 0

  onTap: () => void = () => {}

  @State private arrowY: number = 0
  @State private fabScale: number = 0
  @State private fabOpacity: number = 0
  @State private dragDeltaX: number = 0
  @State private dragDeltaY: number = 0
  private arrowAnimRunning: boolean = false

  aboutToAppear(): void {
    // 不在此处设 fabScale/fabOpacity=1，让 onAppear → fadeIn() 产生入场动画
    if (this.active) {
      this.startArrowAnim()
    }
  }

  aboutToDisappear(): void {
    this.arrowAnimRunning = false
  }

  private startArrowAnim(): void {
    if (this.arrowAnimRunning) return
    this.arrowAnimRunning = true
    this.tickArrow()
  }

  private tickArrow(): void {
    if (!this.arrowAnimRunning) return
    let uiCtx = this.getUIContext()
    uiCtx.animateTo({ duration: 600, curve: Curve.EaseInOut, onFinish: () => {
      if (!this.arrowAnimRunning) return
      uiCtx.animateTo({ duration: 600, curve: Curve.EaseInOut, onFinish: () => {
        this.tickArrow()
      }}, () => { this.arrowY = 0 })
    }}, () => { this.arrowY = 5 })
  }

  fadeOut(onDone: () => void): void {
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut, onFinish: () => {
      onDone()
    }}, () => {
      this.fabScale = 0
      this.fabOpacity = 0
    })
  }

  fadeIn(): void {
    this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
      this.fabScale = 1
      this.fabOpacity = 1
    })
    this.startArrowAnim()
  }

  private isDownloading(): boolean {
    return this.phase === DownloadPhase.PREPARE
      || this.phase === DownloadPhase.CLIENT
      || this.phase === DownloadPhase.LIBRARIES
      || this.phase === DownloadPhase.ASSETS
      || this.phase === DownloadPhase.MODLOADER
      || this.phase === DownloadPhase.MERGE
  }

  private isPaused(): boolean {
    return this.phase === DownloadPhase.PAUSED || this.phase === DownloadPhase.ABORTED
  }

  private isSuccess(): boolean { return this.phase === DownloadPhase.DONE }
  private isError(): boolean { return this.phase === DownloadPhase.ERROR }

  private getRingColor(): ResourceColor {
    if (this.isSuccess()) return this.theme.success
    if (this.isError()) return this.theme.error
    if (this.isPaused()) return this.theme.warning
    return this.theme.primary
  }

  private badgeText(): string {
    if (this.activeTaskCount > 99) return '99+'
    return this.activeTaskCount.toString()
  }

  build() {
    if (this.active) {
      // alignContent: Center 让 Progress 圆环 + 中心 Column 同心对齐
      // （之前用 TopEnd 是为了 badge 但导致 INNER_SIZE 的 Column 被推到右上 → 偏离圆心）
      // badge 改成绝对定位 position()，独立于 alignContent。
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: Math.max(0, Math.min(this.progress, 100)), total: 100, type: ProgressType.Ring })
          .width(DOWNLOAD_FAB_SIZE)
          .height(DOWNLOAD_FAB_SIZE)
          .color(this.getRingColor())
          .backgroundColor(this.theme.divider)
          .style({ strokeWidth: RING_STROKE })

        Column() {
          if (this.isSuccess()) {
            AppIcon({
              name: AppIconName.Check,
              iconSize: 24,
              color: this.theme.success,
              weight: FontWeight.Bold,
            })
          } else if (this.isError()) {
            AppIcon({
              name: AppIconName.Close,
              iconSize: 24,
              color: this.theme.error,
              weight: FontWeight.Bold,
            })
          } else if (this.isPaused()) {
            AppIcon({
              name: AppIconName.Pause,
              iconSize: 22,
              color: this.theme.warning,
              weight: FontWeight.Bold,
            })
          } else {
            Column() {
              AppIcon({
                name: AppIconName.ArrowDown,
                iconSize: 22,
                color: this.theme.primary,
                weight: FontWeight.Bold,
              })
            }
            .translate({ y: this.arrowY })
          }
        }
        .width(INNER_SIZE)
        .height(INNER_SIZE)
        .borderRadius(INNER_SIZE / 2)
        .backgroundColor(this.theme.bgCard)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        // Phase R-4 新增：多任务 badge（右上角小圆点 + 数字）
        // 用 position() 绝对定位，独立于 Stack 的 alignContent，不影响圆环居中。
        if (this.activeTaskCount > 1) {
          Text(this.badgeText())
            .fontSize(9)
            .fontWeight(700)
            .fontColor(this.theme.textOnPrimary)
            .height(18)
            .constraintSize({ minWidth: 18 })
            .padding({ left: 5, right: 5 })
            .borderRadius(9)
            .backgroundColor(this.theme.primary)
            .textAlign(TextAlign.Center)
            .position({ x: DOWNLOAD_FAB_SIZE - 16, y: -2 })
        }
      }
      .width(DOWNLOAD_FAB_SIZE)
      .height(DOWNLOAD_FAB_SIZE)
      .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 2 })
      .borderRadius(DOWNLOAD_FAB_SIZE / 2)
      .position({ x: this.fabOffsetX + this.dragDeltaX, y: this.fabOffsetY + this.dragDeltaY })
      .scale({ x: this.fabScale, y: this.fabScale })
      .opacity(this.fabOpacity)
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture()
            .onAction(() => {
              this.onTap()
            }),
          PanGesture({ distance: 8 })
            .onActionUpdate((event: GestureEvent) => {
              this.dragDeltaX = event.offsetX
              this.dragDeltaY = event.offsetY
            })
            .onActionEnd(() => {
              const position: DownloadFabPosition = DownloadFabLayoutPolicy.finishDrag(
                this.fabOffsetX + this.dragDeltaX,
                this.fabOffsetY + this.dragDeltaY,
                this.viewportWidth,
                this.viewportHeight,
                this.bottomSafeHeight)
              this.fabOffsetX = position.x
              this.fabOffsetY = position.y
              this.dragDeltaX = 0
              this.dragDeltaY = 0
            })
        )
      )
      .onAppear(() => {
        if (this.active && this.fabScale < 1) {
          this.fadeIn()
        }
      })
    }
  }
}

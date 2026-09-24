/**
 * DownloadFabLayoutPolicy.ets — 下载悬浮球的窗口内布局纯策略。
 *
 * 坐标空间必须是当前 ArkUI 可绘制窗口（drawableRect，单位 vp），不能是物理显示器：
 * PC 浮动窗口只占屏幕的一部分，用 display.width/height 算出来的右下角会落到窗口外，
 * 最终被根 Stack 裁掉；全屏时两者恰好近似相等，才会制造“只有全屏可见”的假象。
 */

export const DOWNLOAD_FAB_SIZE: number = 56
export const DOWNLOAD_FAB_MARGIN: number = 16

const DOWNLOAD_DOCK_TOTAL_HEIGHT: number = 70
const DOWNLOAD_FAB_DOCK_GAP: number = 16
const DOWNLOAD_FAB_SAFE_BOTTOM_FALLBACK: number = 24

export class DownloadFabPosition {
  x: number = 0
  y: number = 0

  static at(x: number, y: number): DownloadFabPosition {
    const result = new DownloadFabPosition()
    result.x = x
    result.y = y
    return result
  }
}

export class DownloadFabLayoutPolicy {
  /** 第一次拿到窗口尺寸时，把 FAB 放在窗口右下角、底部 dock 上方。 */
  static initial(viewportWidth: number, viewportHeight: number,
    bottomSafeHeight: number): DownloadFabPosition {
    const x: number = DownloadFabLayoutPolicy.maxCoordinate(viewportWidth)
    const preferredY: number = viewportHeight - DOWNLOAD_DOCK_TOTAL_HEIGHT -
      Math.max(bottomSafeHeight, DOWNLOAD_FAB_SAFE_BOTTOM_FALLBACK) -
      DOWNLOAD_FAB_SIZE - DOWNLOAD_FAB_DOCK_GAP
    const y: number = DownloadFabLayoutPolicy.clampVisibleCoordinate(
      preferredY, viewportHeight)
    return DownloadFabPosition.at(x, y)
  }

  /**
   * 窗口缩放时维持最近的左右吸附边；默认底部位置继续跟随 dock，用户自定义高度只夹回可见区。
   */
  static reflow(currentX: number, currentY: number,
    oldViewportWidth: number, oldViewportHeight: number,
    newViewportWidth: number, newViewportHeight: number,
    bottomSafeHeight: number): DownloadFabPosition {
    if (oldViewportWidth <= 0 || oldViewportHeight <= 0) {
      return DownloadFabLayoutPolicy.initial(
        newViewportWidth, newViewportHeight, bottomSafeHeight)
    }

    const wasRight: boolean =
      currentX + DOWNLOAD_FAB_SIZE / 2 >= oldViewportWidth / 2
    const x: number = wasRight
      ? DownloadFabLayoutPolicy.maxCoordinate(newViewportWidth)
      : DownloadFabLayoutPolicy.minCoordinate(newViewportWidth)

    const oldDefault: DownloadFabPosition = DownloadFabLayoutPolicy.initial(
      oldViewportWidth, oldViewportHeight, bottomSafeHeight)
    const newDefault: DownloadFabPosition = DownloadFabLayoutPolicy.initial(
      newViewportWidth, newViewportHeight, bottomSafeHeight)
    const followedDefaultBottom: boolean =
      Math.abs(currentY - oldDefault.y) <= DOWNLOAD_FAB_MARGIN
    const y: number = followedDefaultBottom
      ? newDefault.y
      : DownloadFabLayoutPolicy.clampVerticalCoordinate(
          currentY, newViewportHeight, bottomSafeHeight)
    return DownloadFabPosition.at(x, y)
  }

  /** 拖动结束：按当前窗口中线吸附左右边，并确保整个圆仍在窗口内。 */
  static finishDrag(candidateX: number, candidateY: number,
    viewportWidth: number, viewportHeight: number,
    bottomSafeHeight: number): DownloadFabPosition {
    const snapRight: boolean =
      candidateX + DOWNLOAD_FAB_SIZE / 2 >= viewportWidth / 2
    const x: number = snapRight
      ? DownloadFabLayoutPolicy.maxCoordinate(viewportWidth)
      : DownloadFabLayoutPolicy.minCoordinate(viewportWidth)
    const y: number = DownloadFabLayoutPolicy.clampVerticalCoordinate(
      candidateY, viewportHeight, bottomSafeHeight)
    return DownloadFabPosition.at(x, y)
  }

  private static minCoordinate(viewportLength: number): number {
    const visibleMax: number = Math.max(0, viewportLength - DOWNLOAD_FAB_SIZE)
    return Math.min(DOWNLOAD_FAB_MARGIN, visibleMax)
  }

  private static maxCoordinate(viewportLength: number): number {
    const visibleMax: number = Math.max(0, viewportLength - DOWNLOAD_FAB_SIZE)
    const minimum: number = DownloadFabLayoutPolicy.minCoordinate(viewportLength)
    return Math.max(minimum, visibleMax - DOWNLOAD_FAB_MARGIN)
  }

  private static clampVisibleCoordinate(value: number, viewportLength: number): number {
    const minimum: number = DownloadFabLayoutPolicy.minCoordinate(viewportLength)
    const maximum: number = DownloadFabLayoutPolicy.maxCoordinate(viewportLength)
    return Math.max(minimum, Math.min(value, maximum))
  }

  /** 纵向拖动不能压住底部 dock；极小窗口再退化为“至少完整可见”。 */
  private static clampVerticalCoordinate(value: number, viewportHeight: number,
    bottomSafeHeight: number): number {
    const minimum: number = DownloadFabLayoutPolicy.minCoordinate(viewportHeight)
    const preferredMaximum: number = viewportHeight - DOWNLOAD_DOCK_TOTAL_HEIGHT -
      Math.max(bottomSafeHeight, DOWNLOAD_FAB_SAFE_BOTTOM_FALLBACK) -
      DOWNLOAD_FAB_SIZE - DOWNLOAD_FAB_DOCK_GAP
    const visibleMaximum: number = DownloadFabLayoutPolicy.maxCoordinate(viewportHeight)
    const maximum: number = Math.max(
      minimum, Math.min(preferredMaximum, visibleMaximum))
    return Math.max(minimum, Math.min(value, maximum))
  }
}

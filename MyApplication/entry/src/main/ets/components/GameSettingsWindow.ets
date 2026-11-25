/** 同时检查高度，避免长宽比很大的横屏手机误用平板侧栏。单位均为宿主可用 vp。 */
export function gameSettingsWide(width: number,height: number): boolean {
  return width >= 900 && height >= 480
}

/** 手机保留原 8vp 横向边距。平板将详情限在可读宽度，窄平板为侧栏和双栏表单保留空间。 */
export function gameSettingsWidth(width: number, height: number): number {
  if (!gameSettingsWide(width,height)) return Math.max(1,width-16)
  return Math.min(1024,width-32,Math.max(828,Math.round(width*0.76)))
}

/** 平板留出周围游戏画面；短窗口保证目录和固定操作区之间仍有可滚动的内容区域。 */
export function gameSettingsHeight(width: number, height: number): number {
  if (!gameSettingsWide(width,height)) return Math.max(1,height-12)
  return Math.min(640,height-24,Math.max(424,Math.round(height*0.70)))
}

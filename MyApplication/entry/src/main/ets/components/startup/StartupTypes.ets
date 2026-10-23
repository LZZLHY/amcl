/**
 * 开屏与首页之间的轻量交接数据。
 *
 * 坐标契约：x/y 使用 ArkUI Area.globalPosition 的窗口内 vp 坐标；width/height
 * 是首页 30 vp 品牌 Image 的实际布局尺寸，包含图片自身透明边距。开屏负责减去
 * 自身 Canvas 的窗口原点，不能由首页预先减安全区，否则横屏/分屏会重复偏移。
 * 父组件每次测量后替换整个实例，以便 V1 @Prop 能观察到锚点变化。
 */
export class StartupTargetRect {
  x: number = 0;
  y: number = 0;
  width: number = 0;
  height: number = 0;
  valid: boolean = false;
}

/**
 * 聚合阶段专用的连续视觉时钟。早期真实准备完成时，逐帧将速率从1提高到1.5，
 * 将正常约1.12秒的聚合压缩到约0.75～0.85秒。保持累计时间连续，不能ready时
 * 直接跳到某个动画进度。正常/慢启动仍使用1倍；达到聚合终点后恢复1倍。
 *
 * 此时钟不参与退出进度或真实等待提示；调用方分别使用真实前台时间决定它们。
 */
export class StartupAssemblyClock {
  elapsedMs: number = 0;
  private rate_: number = 1;
  private fastSelected_: boolean = false;

  /**
   * 输入一个前台帧间隔及真实准备状态，返回连续视觉时间。单帧限幅48ms避免
   * 启动IO卡顿后直接跳过聚合；前台真实耗时超过300ms后不再选择快启动节奏。
   */
  advance(deltaMs: number, foregroundMs: number, ready: boolean, failed: boolean,
    reducedMotion: boolean, assemblyDurationMs: number): number {
    const delta: number = Math.min(48, Math.max(0, deltaMs));
    if (!reducedMotion && ready && !failed && foregroundMs <= 300 && this.elapsedMs <= 280) {
      this.fastSelected_ = true;
    }
    if (!reducedMotion && this.fastSelected_ && this.elapsedMs < assemblyDurationMs) {
      // 大约90ms内平滑提高速率，场景坐标始终由同一连续时间求值。
      this.rate_ = Math.min(1.5, this.rate_ + delta / 180);
      const remaining: number = assemblyDurationMs - this.elapsedMs;
      const advance: number = delta * this.rate_;
      if (advance <= remaining) {
        this.elapsedMs += advance;
      } else {
        // 本帧跨过聚合终点时，剩余真实帧间隔按1倍使用，不把倍速带入悬浮/收尾。
        this.elapsedMs = assemblyDurationMs + delta - remaining / this.rate_;
      }
    } else {
      this.elapsedMs += delta;
    }
    return this.elapsedMs;
  }
}

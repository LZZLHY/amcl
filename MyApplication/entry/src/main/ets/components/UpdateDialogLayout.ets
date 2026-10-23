/**
 * 自更新弹窗的纯展示几何：发现态、进行态和旧路由共用同一尺寸计算。
 * 输入均为宿主已经发布的窗口 vp 与系统避让高度；不读取更新阶段、下载进度或授权状态，
 * 因而内容切换、端口展开及登录 Sheet 显隐都不会重新选择另一套外框。
 */
export interface UpdateDialogLayout {
  width: number;
  height: number;
  compact: boolean;
}

/** 将尚未发布或非法的窗口值收敛为首次展示基线，避免 NaN 进入 ArkUI 尺寸属性。 */
function positiveWindow(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/**
 * 在可用窗口内居中保留边距，常规手机使用 R3 的 320×464 vp 外框。
 * 只有真实窗口或避让区变化时才缩小外框；窄/矮窗口同时启用紧凑内部留白。
 * 避让值不得把可用尺寸变成负数；极端窗口仍返回有限正值，由唯一内容滚动区承接正文。
 */
export function resolveUpdateDialogLayout(windowWidth: number, windowHeight: number,
  topSafe: number, bottomSafe: number): UpdateDialogLayout {
  const width = positiveWindow(windowWidth, 360);
  const height = positiveWindow(windowHeight, 780);
  const top = Number.isFinite(topSafe) ? Math.max(0, topSafe) : 0;
  const bottom = Number.isFinite(bottomSafe) ? Math.max(0, bottomSafe) : 0;
  const frameWidth = Math.min(320, Math.max(1, width - 40));
  const frameHeight = Math.min(464, Math.max(1, height - top - bottom - 40));
  return { width: frameWidth, height: frameHeight, compact: frameHeight < 400 || frameWidth < 300 };
}

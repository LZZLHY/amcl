/**
 * 游戏分辨率的纯政策：显示矩形保持原尺寸，游戏窗口与图像使用同一缩小目标。
 * 此处不调用 NativeWindow，也不把请求当实际图像。存储值 0 表示未显式配置/继承，
 * 100 表示明确使用原生尺寸；最终启动计划只发布一个规范 marker。
 */
export const GAME_RESOLUTION_MIN_PERCENT: number = 50;
export const GAME_RESOLUTION_MAX_PERCENT: number = 100;
export const GAME_RESOLUTION_MARKER: string = '-Damcl.render.scale=';

/** 非法或旧缺失字段归为继承，不把坏值钳位成玩家没有选择过的性能档。 */
export function normalizeResolutionPreference(value: number | undefined): number {
  return value !== undefined && Number.isFinite(value) && value >= GAME_RESOLUTION_MIN_PERCENT
    && value <= GAME_RESOLUTION_MAX_PERCENT ? value : 0;
}

/**
 * 明确的实例/全局设置优先于旧 marker；均未明确设置时保留最后一个旧 marker 的语义。
 * marker 必须是完整独立参数；最后一项非法则回原生，不能偷偷退回更早的合法项。
 */
export function resolveResolutionPercent(preference: number, argumentsList: string[]): number {
  const explicit: number = normalizeResolutionPreference(preference);
  if (explicit > 0) return explicit;
  let percent: number = GAME_RESOLUTION_MAX_PERCENT;
  for (const argument of argumentsList) {
    if (!argument.startsWith(GAME_RESOLUTION_MARKER)) continue;
    const text: string = argument.substring(GAME_RESOLUTION_MARKER.length);
    // 接受常规小数与科学记数法，拒绝空值、非有限值和尾随垃圾。
    const decimal: boolean = /^[+\-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+\-]?\d+)?$/.test(text);
    const value: number = decimal ? Number(text) * 100 : 0;
    percent = normalizeResolutionPreference(value) || GAME_RESOLUTION_MAX_PERCENT;
  }
  return percent;
}

/** 移除重复来源，再写唯一的已解析政策；不修改原参数数组或任何其他 JVM 属性。 */
export function withResolutionPolicy(argumentsList: string[], percent: number): string[] {
  const resolved: number = normalizeResolutionPreference(percent) || GAME_RESOLUTION_MAX_PERCENT;
  const result: string[] = argumentsList.filter((argument: string): boolean => !argument.startsWith(GAME_RESOLUTION_MARKER));
  result.push(GAME_RESOLUTION_MARKER + (resolved / 100).toString());
  return result;
}

/** 与 Native ScaledDimension 同一取整政策；100% 不改变奇数宽高，非正尺寸等待窗口就绪。 */
export function gameResolutionDimension(physicalPixels: number, percent: number): number {
  const valid: number = normalizeResolutionPreference(percent);
  if (!Number.isFinite(physicalPixels) || physicalPixels <= 0) return 0;
  const physical: number = Math.floor(physicalPixels);
  if (valid === 0 || valid === 100) return physical;
  return Math.min(physical, Math.max(2, Math.floor(Math.round(physical * valid / 100) / 2) * 2));
}

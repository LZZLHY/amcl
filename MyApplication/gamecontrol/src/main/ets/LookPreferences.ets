/**
 * LookPreferences — 方案中独立来源视角政策的持久边界。
 * 旧方案不含此扩展，仍以四个全局标量运行；用户主动拆分时才生成布局v4。
 * 每来源是一组完整参数，不允许用缺省字段把一次导入拼成新旧参数混合。
 * 本模块只校验和复制值，不保存仓库、不调用Native，也不退休接触或已有尾量。
 */
export interface LookParameters {
  sensitivity: number
  invertY: boolean
  smoothing: number
  acceleration: number
}

/** 来源名是持久协议；physical的平滑例外、gyro随touch政策仍由实际执行模型维持。 */
export type LookPolicySource = 'physical' | 'touch' | 'gamepad' | 'external'
export type LookPolicyMode = 'legacy-global' | 'independent'

/** 只有显式迁移才存在。legacy保留原全来源手感，可恢复兼容政策而不丢独立参数草稿。 */
export interface SourceLookPreferences {
  version: number
  mode: LookPolicyMode
  legacy: LookParameters
  physical: LookParameters
  touch: LookParameters
  gamepad: LookParameters
  external: LookParameters
}

/** 类型与范围严格验证；不把字符串、NaN或半组字段变成用户没有选择的政策。 */
export function validLookParameters(value: LookParameters): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === 4 && Object.keys(value).every((key: string): boolean =>
      key === 'sensitivity' || key === 'invertY' || key === 'smoothing' || key === 'acceleration')
    && typeof value.sensitivity === 'number' && Number.isFinite(value.sensitivity)
    && value.sensitivity >= 0.3 && value.sensitivity <= 3
    && typeof value.invertY === 'boolean'
    && typeof value.smoothing === 'number' && Number.isFinite(value.smoothing)
    && value.smoothing >= 0.1 && value.smoothing <= 1
    && typeof value.acceleration === 'number' && Number.isFinite(value.acceleration)
    && value.acceleration >= 0 && value.acceleration <= 1
}

/** 四标量深拷贝；不共享可被编辑器改写的来源对象。调用方应先校验外部值。 */
export function copyLookParameters(value: LookParameters): LookParameters {
  return { sensitivity: value.sensitivity, invertY: value.invertY,
    smoothing: value.smoothing, acceleration: value.acceleration }
}

/** undefined是合法旧格式；非法扩展返回undefined，调用者须区分缺席与校验失败。 */
export function copySourceLookPreferences(value?: SourceLookPreferences): SourceLookPreferences | undefined {
  if (value === undefined) return undefined
  if (value === null || typeof value !== 'object' || Array.isArray(value) || value.version !== 1
      || Object.keys(value).length !== 7 || Object.keys(value).some((key: string): boolean =>
        key !== 'version' && key !== 'mode' && key !== 'legacy' && key !== 'physical'
        && key !== 'touch' && key !== 'gamepad' && key !== 'external')
      || (value.mode !== 'legacy-global' && value.mode !== 'independent')
      || !validLookParameters(value.legacy) || !validLookParameters(value.physical)
      || !validLookParameters(value.touch) || !validLookParameters(value.gamepad)
      || !validLookParameters(value.external)) return undefined
  return { version: 1, mode: value.mode, legacy: copyLookParameters(value.legacy),
    physical: copyLookParameters(value.physical), touch: copyLookParameters(value.touch),
    gamepad: copyLookParameters(value.gamepad), external: copyLookParameters(value.external) }
}

/** 显式拆分原全来源值，逐来源复制原参数；这一步本身不改变任何来源的有效手感。 */
export function splitLegacyLookPolicy(value: LookParameters): SourceLookPreferences | undefined {
  if (!validLookParameters(value)) return undefined
  return { version: 1, mode: 'independent', legacy: copyLookParameters(value),
    physical: copyLookParameters(value), touch: copyLookParameters(value),
    gamepad: copyLookParameters(value), external: copyLookParameters(value) }
}

/** 返回指定来源值副本；兼容模式完整使用legacy组，不拼接独立字段。 */
export function sourceLookParameters(value: SourceLookPreferences, source: LookPolicySource): LookParameters {
  if (value.mode === 'legacy-global') return copyLookParameters(value.legacy)
  if (source === 'physical') return copyLookParameters(value.physical)
  if (source === 'touch') return copyLookParameters(value.touch)
  if (source === 'gamepad') return copyLookParameters(value.gamepad)
  return copyLookParameters(value.external)
}

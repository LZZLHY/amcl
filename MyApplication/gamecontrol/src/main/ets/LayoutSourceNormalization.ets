/**
 * 合法历史source方案的按需规范化。原raw由source repository保存；此纯函数只产生独立运行/编辑副本。
 * 派生系统ID与可选hotbar ID采用完整树避让的确定性序号，同一冻结源在owner/child中得到相同定义。
 * 自动hotbar实际窗口几何由runtime纯投影负责，读取源时不把当前窗口写进冻结基线。
 */
import { LayoutProfile, ControlItem, ControlType, makeHotbarSelector, validateAndNormalizeLayout } from './ControlLayout'
import { buildLayoutCandidate } from './LayoutCandidate'

export function derivedLayoutControlId(base: string, controls: ControlItem[]): string {
  const ids: Set<string> = new Set<string>()
  const collect = (items: ControlItem[]): void => {
    for (const item of items) { ids.add(item.id); collect(item.children ?? []) }
  }
  collect(controls)
  if (!ids.has(base)) return base
  let index: number = 1
  while (ids.has(base + '_' + index.toString())) index++
  return base + '_' + index.toString()
}

export function normalizeLayoutSource(raw: string, profileId: string, profileRevision: number, name: string): LayoutProfile {
  const source: LayoutProfile | null = validateAndNormalizeLayout(JSON.parse(raw) as LayoutProfile)
  if (source === null) throw new Error('Invalid historical layout source; original retained')
  source.profileId = profileId; source.profileRevision = profileRevision; source.name = name
  if (!source.controls.some((item: ControlItem): boolean => item.type === ControlType.HOTBAR_SELECTOR) && source.hotbarAutoAdded !== true) {
    const hotbar: ControlItem = makeHotbarSelector(.34, .9, 300, 36)
    hotbar.id = derivedLayoutControlId('hotbar_sel', source.controls)
    source.controls.push(hotbar); source.hotbarAutoAdded = true
  }
  const candidate = buildLayoutCandidate(source)
  // 旧不支持结构/补齐预算失败保留原定义与导出，不删用户控件也不把子摇杆假装成按钮。
  if (candidate.profile !== null) return candidate.profile
  const original: LayoutProfile | null = validateAndNormalizeLayout(JSON.parse(raw) as LayoutProfile)
  if (original === null) throw new Error('Invalid historical layout source; original retained')
  original.profileId = profileId; original.profileRevision = profileRevision; original.name = name
  return original
}

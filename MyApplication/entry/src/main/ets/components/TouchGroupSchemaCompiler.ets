/**
 * 将已校验的持久组图编译为当前几何快照的有界索引。只在结构发布执行，不位于 MOVE 热路径。
 * 不计算运行 mask，不读取 Native 状态；所有组即使初始隐藏也保留定义和有效场景内的几何。
 */
import { LayoutProfile, ControlItem, RuntimeTouchLayout, ControlActionPhase, ControlGroup, ControlPhaseBinding, effectiveKeys } from 'gamecontrol'
import { ControlSchemaEntry, TouchGroupSchema, TouchGroupSchemaControl, TouchGroupSchemaPhase, TouchGroupSchemaDefinition } from 'libentry.so'

export function compileTouchGroups(profile: LayoutProfile, layout: RuntimeTouchLayout,
  controls: ControlSchemaEntry[]): TouchGroupSchema | undefined {
  if (profile.controlGroups === undefined) return undefined
  const phaseNames: ControlActionPhase[] = ['press','longPress','click','doubleClick']
  const ids: string[] = profile.controlGroups.map((group: ControlGroup): string => group.id)
  const result: TouchGroupSchema = { profile:profile.profileId ?? 'unsaved',
    groups:profile.controlGroups.map((group: ControlGroup): TouchGroupSchemaDefinition => { return {id:group.id,initialVisible:group.initialVisible} }), controls:[] }
  for (let index: number = 0; index < controls.length; index++) {
    const entry = layout.find(controls[index].id)
    const item: ControlItem | undefined = entry?.item
    const parent: ControlItem | undefined = entry !== undefined && entry.parentId.length > 0 ? layout.find(entry.parentId)?.item : undefined
    const groupId: string | undefined = item?.controlGroupId ?? parent?.controlGroupId
    const group: number = groupId === undefined ? -1 : ids.indexOf(groupId)
    const phases: boolean = item !== undefined && (item.phaseBindings !== undefined || (item.groupActions?.length ?? 0) > 0)
    const binding: TouchGroupSchemaControl = { group:group,phases:phases,fcl:item?.gesturePolicy === 'fcl',mouseTool:item?.systemAction === 'mouse',rank:index,bindings:[] }
    for (const phase of phaseNames) {
      const value: TouchGroupSchemaPhase = { keys:[],autoKeep:false,actions:[] }
      if (item !== undefined && phases) {
        if (item.phaseBindings !== undefined) {
          const saved = item.phaseBindings.find((candidate: ControlPhaseBinding): boolean => candidate.phase === phase)
          if (saved !== undefined) { value.keys=saved.keys.slice(); value.autoKeep=saved.autoKeep }
        } else {
          const legacyPhase: ControlActionPhase = item.trigger === 'longPress' ? 'longPress' : item.trigger === 'doubleTap' ? 'doubleClick' : 'press'
          if (legacyPhase === phase) { value.keys=effectiveKeys(item); value.autoKeep=item.trigger === 'toggle' }
        }
        for (const action of item.groupActions ?? []) {
          if (action.phase !== phase) continue
          for (const target of action.targets) value.actions.push({ target:ids.indexOf(target),
            operation:action.operation === 'toggle' ? 0 : action.operation === 'show' ? 1 : 2 })
        }
      }
      binding.bindings.push(value)
    }
    result.controls.push(binding)
  }
  // Native/UI 使用同一个全序。恢复和运行辅助区位于所有用户组之上，同组保持原条目次序。
  const order: number[] = []
  for (let index: number = 0; index < result.controls.length; index++) order.push(index)
  order.sort((a: number,b: number): number => {
    const left: number = result.controls[a].group < 0 ? ids.length : result.controls[a].group
    const right: number = result.controls[b].group < 0 ? ids.length : result.controls[b].group
    return left === right ? a - b : left - right
  })
  for (let rank: number = 0; rank < order.length; rank++) result.controls[order[rank]].rank=rank
  return result
}

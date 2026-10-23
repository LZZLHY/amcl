/**
 * 触控组持久协议。只描述定义、校验和深复制，不持有本局显隐，也不调用平台输入。
 * 数量限制与 Native touch_group_state.h 由契约测试逐项核对；隐藏成员仍计入原布局总预算。
 */
export const CONTROL_GROUP_PROFILE_VERSION: number = 5
export const MAX_CONTROL_GROUPS: number = 128
export const MAX_CONTROL_GROUP_TARGETS: number = 128
export const MAX_CONTROL_GROUP_OPERATIONS: number = 1024
export const TOUCH_GROUP_CAPABILITY: string = 'touch-groups-v1'
export const TOUCH_PHASE_CAPABILITY: string = 'touch-phases-v1'

/** 手势阶段与键锁存相互独立。click 在合格 UP 触发，不能映射成 press 的 DOWN。 */
export type ControlActionPhase = 'press' | 'longPress' | 'click' | 'doubleClick'
export type ControlGroupOperation = 'toggle' | 'show' | 'hide'
export type ControlGesturePolicy = 'amcl' | 'fcl'

/** 平级有序组；顺序只由 profile.controlGroups 数组表达，名称不是引用身份。 */
export interface ControlGroup {
  id: string
  name: string
  initialVisible: boolean
}

/** 一次阶段可带多个有序操作；targets 保留重复项，Native 按顺序计算最终 mask。 */
export interface ControlGroupAction {
  phase: ControlActionPhase
  operation: ControlGroupOperation
  targets: string[]
}

/**
 * 显式四阶段键绑定。存在时替代旧 keys/trigger 的运行解释；每阶段独立拥有键锁存。
 * 连点宏、文本及启动器业务不在本协议内，解析端必须拒绝，不能作为未识别字段丢弃。
 */
export interface ControlPhaseBinding {
  phase: ControlActionPhase
  keys: number[]
  autoKeep: boolean
}

/** 同时供导入和严格读取使用；先校验未知字段，再深复制，避免 clone 抹掉未知执行语义。 */
export function hasOnlyControlGroupFields(value: Object, fields: string[]): boolean {
  return Object.keys(value).every((key: string): boolean => fields.indexOf(key) >= 0)
}

export function validControlGroupId(id: string): boolean {
  return typeof id === 'string' && new RegExp('^[a-zA-Z0-9_-]{1,23}$').test(id)
}

export function validControlActionPhase(phase: string): boolean {
  return phase === 'press' || phase === 'longPress' || phase === 'click' || phase === 'doubleClick'
}

/** 复制定义而不共享可变数组；undefined 保留旧格式“没有启用组”的含义。 */
export function cloneControlGroups(groups: ControlGroup[] | undefined): ControlGroup[] | undefined {
  return groups?.map((group: ControlGroup): ControlGroup => {
    return { id: group.id, name: group.name, initialVisible: group.initialVisible ?? true }
  })
}

export function cloneControlGroupActions(actions: ControlGroupAction[] | undefined): ControlGroupAction[] | undefined {
  return actions?.map((action: ControlGroupAction): ControlGroupAction => {
    return { phase: action.phase, operation: action.operation, targets: action.targets.slice() }
  })
}

export function cloneControlPhaseBindings(bindings: ControlPhaseBinding[] | undefined): ControlPhaseBinding[] | undefined {
  return bindings?.map((binding: ControlPhaseBinding): ControlPhaseBinding => {
    return { phase: binding.phase, keys: binding.keys.slice(), autoKeep: binding.autoKeep }
  })
}

/** 返回可定位原因；不修剪数组、不推测歧义 ID，不把未知动作当作空操作。 */
export function controlGroupTableIssue(groups: ControlGroup[] | undefined, defaultId: string | undefined): string {
  if (!Array.isArray(groups) || groups.length === 0 || groups.length > MAX_CONTROL_GROUPS) return 'groups.count'
  const ids: Set<string> = new Set<string>()
  for (let index: number = 0; index < groups.length; index++) {
    const group: ControlGroup = groups[index]
    if (!group || !hasOnlyControlGroupFields(group, ['id', 'name', 'initialVisible'])) return 'groups.fields'
    if (!validControlGroupId(group.id) || ids.has(group.id)) return 'groups.identity'
    if (typeof group.name !== 'string' || group.name.length === 0 || group.name.length > 64) return 'groups.name'
    if (group.initialVisible !== undefined && typeof group.initialVisible !== 'boolean') return 'groups.initialVisible'
    ids.add(group.id)
  }
  return defaultId === undefined || !ids.has(defaultId) ? 'groups.default' : ''
}

/** 校验原始目标数量，奇偶归一化不能让超大输入绕过工作量预算。 */
export function controlGroupActionIssue(actions: ControlGroupAction[] | undefined, ids: Set<string>): string {
  if (actions === undefined) return ''
  if (!Array.isArray(actions) || actions.length > 16) return 'groupActions.count'
  const phaseCounts: Map<string, number> = new Map<string, number>()
  for (const action of actions) {
    if (!action || !hasOnlyControlGroupFields(action, ['phase', 'operation', 'targets'])) return 'groupActions.fields'
    if (!validControlActionPhase(action.phase) || (action.operation !== 'toggle' &&
      action.operation !== 'show' && action.operation !== 'hide')) return 'groupActions.operation'
    if (!Array.isArray(action.targets) || action.targets.length === 0 ||
      action.targets.length > MAX_CONTROL_GROUP_TARGETS) return 'groupActions.targets'
    for (const target of action.targets) if (!ids.has(target)) return 'groupActions.target'
    const count: number = (phaseCounts.get(action.phase) ?? 0) + action.targets.length
    if (count > MAX_CONTROL_GROUP_TARGETS) return 'groupActions.phase-budget'
    phaseCounts.set(action.phase, count)
  }
  return ''
}

/** 四阶段键必须是可执行的 GLFW 输出码；零仅用于旧兼容字段，不允许混入 keys。 */
export function controlPhaseBindingIssue(bindings: ControlPhaseBinding[] | undefined): string {
  if (bindings === undefined) return ''
  if (!Array.isArray(bindings) || bindings.length > 4) return 'phaseBindings.count'
  const phases: Set<string> = new Set<string>()
  for (const binding of bindings) {
    if (!binding || !hasOnlyControlGroupFields(binding, ['phase', 'keys', 'autoKeep'])) return 'phaseBindings.fields'
    if (!validControlActionPhase(binding.phase) || phases.has(binding.phase) ||
      typeof binding.autoKeep !== 'boolean') return 'phaseBindings.phase'
    phases.add(binding.phase)
    if (!Array.isArray(binding.keys) || binding.keys.length > 6) return 'phaseBindings.keys'
    for (const key of binding.keys) {
      if (!Number.isInteger(key) || !((key >= 32 && key <= 348) || (key >= -8 && key <= -1))) return 'phaseBindings.key'
    }
  }
  return ''
}

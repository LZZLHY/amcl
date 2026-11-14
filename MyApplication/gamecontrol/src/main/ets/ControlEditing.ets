/**
 * 控件编辑的纯能力与身份规则。列表、属性、批量命令和阶段转换共用这里的判断；
 * 不持有游戏状态，不调用Native，也不改变持久方案。调用方只在显式用户确认后采用返回草稿。
 */
import { ControlItem, ControlType, LayoutProfile, effectiveKeys, enableLayoutControlGroups,
  validateAndNormalizeLayout } from './ControlLayout'
import { ControlPhaseBinding, ControlActionPhase, cloneControlPhaseBindings, controlPhaseBindingIssue,
  TOUCH_PHASE_CAPABILITY } from './ControlGroups'

/** 一层抽屉子项以稳定ID定位；parent仅用于编辑归属和顺序，不建立新的坐标系统。 */
export class ControlEditTarget {
  item: ControlItem
  parent: ControlItem | undefined
  constructor(item: ControlItem, parent?: ControlItem) { this.item = item; this.parent = parent }
}

/** 返回现有模型的引用，修改必须发生在调用方自己的草稿中；不跳过隐藏项。 */
export function controlEditTargets(controls: ControlItem[]): ControlEditTarget[] {
  const result: ControlEditTarget[] = []
  for (const item of controls) {
    result.push(new ControlEditTarget(item))
    for (const child of item.children ?? []) result.push(new ControlEditTarget(child, item))
  }
  return result
}

/** 校验后的控件ID全树唯一；找不到返回undefined，绝不按旧下标退回其他控件。 */
export function findControlEditTarget(controls: ControlItem[], id: string): ControlEditTarget | undefined {
  return controlEditTargets(controls).find((target: ControlEditTarget): boolean => target.item.id === id)
}

/** 编辑能力只反映在役消费者；历史无效外观字段保留存档，但不提供误导性滑条。 */
export class ControlEditCapabilities {
  ordinary: boolean = false
  binding: boolean = false
  label: boolean = true
  opacity: boolean = false
  corner: boolean = false
  scene: boolean = true
  position: boolean = true
  removable: boolean = true
  constructor(item: ControlItem, child: boolean = false) {
    this.ordinary = item.type === ControlType.BUTTON && item.systemAction === undefined
    this.binding = (this.ordinary || item.systemAction === 'input') && item.secondaryAction === undefined
    this.label = item.systemAction !== 'visibility'
    this.opacity = item.type === ControlType.BUTTON
    this.corner = item.type === ControlType.BUTTON || item.type === ControlType.JOYSTICK ||
      item.type === ControlType.HOTBAR_SELECTOR
    this.scene = item.systemAction === undefined && item.secondaryAction === undefined
    this.position = !child
    this.removable = item.systemAction === undefined &&
      !(item.children ?? []).some((child: ControlItem): boolean => child.systemAction !== undefined)
  }
}

/** 与TouchGroupSchemaCompiler一致：附组动作也已经属于阶段解释，不能只看phaseBindings。 */
export function controlUsesPhases(item: ControlItem): boolean {
  return item.secondaryAction !== undefined || item.phaseBindings !== undefined || (item.groupActions?.length ?? 0) > 0
}

/** 冻结当前实际阶段定义；旧表示只用于转换预览，调用本函数本身不升级方案。 */
export function controlEffectivePhases(item: ControlItem): ControlPhaseBinding[] {
  // 层级入口覆盖原输出，原字段仅为解绑恢复保留，不能被手柄/陀螺仪等消费者误认为当前输出。
  if (item.secondaryAction !== undefined) return []
  if (item.phaseBindings !== undefined) return cloneControlPhaseBindings(item.phaseBindings) ?? []
  const phase: ControlActionPhase = item.trigger === 'longPress' ? 'longPress' :
    item.trigger === 'doubleTap' ? 'doubleClick' : 'press'
  const saved: number[] = effectiveKeys(item)
  // 旧keyOrMouse=0且没有keys也是无输出；只处理这一个空意图，不从组合中静默滤掉非法码。
  const keys: number[] = saved.length === 1 && saved[0] === 0 ? [] : saved.slice()
  return keys.length === 0 ? [] : [{ phase: phase, keys: keys, autoKeep: item.trigger === 'toggle' }]
}

/** 阶段码域比旧按钮窄；不可表达的组合/修饰必须整笔拒绝，不能截掉个别输出。 */
export function controlPhaseConversionIssue(item: ControlItem): string {
  if (item.secondaryAction !== undefined) return '请先解除二级组绑定，再编辑游戏按键动作'
  if (!new ControlEditCapabilities(item).ordinary) return '系统或专用控件不能改成阶段按钮'
  if ((item.modifiers ?? 0) !== 0) return '原修饰掩码无法等价转换，请保留现有按钮定义'
  if (controlPhaseBindingIssue(controlEffectivePhases(item)).length > 0)
    return '原绑定包含阶段按钮不支持的键码，不能转换或截断原组合'
  return ''
}

/** 展示解释器切换的真实差异；所有旧按钮首次转换都要确认，既有阶段则保持原政策。 */
export function controlPhaseConversionDescription(item: ControlItem): string {
  let detail: string = '保留原输出，改用分阶段解释；取消将退休本按钮的阶段持有。'
  if (item.trigger === 'doubleTap') detail += '\n双击从第二次按下触发改为第二次合格抬起；长时间按住或移动可能不再触发。'
  else if (item.trigger === 'longPress') detail += '\n长按将采用阶段的移动取消规则；原普通长按不因移动而取消。'
  else if (item.trigger === 'toggle') detail += '\n保持改为本阶段的“再次触发松开”；取消和隐藏沿阶段退休规则处理。'
  return detail + '\n只修改编辑草稿；一次撤销可恢复完整原定义，保存后才使用。'
}

/** 用户确认后才创建完整v5草稿；原对象/版本不改动，失败返回null并保留原数据。 */
export function convertControlToPhases(profile: LayoutProfile, id: string): LayoutProfile | null {
  const original: ControlItem | undefined = findControlEditTarget(profile.controls, id)?.item
  if (original === undefined || controlPhaseConversionIssue(original).length > 0) return null
  const draft: LayoutProfile = enableLayoutControlGroups(profile)
  const target: ControlItem | undefined = findControlEditTarget(draft.controls, id)?.item
  if (target === undefined) return null
  target.phaseBindings = controlEffectivePhases(original)
  target.keys = []; target.keyOrMouse = 0; target.modifiers = 0; target.trigger = 'press'
  const capabilities: string[] = draft.requiredCapabilities?.slice() ?? []
  if (capabilities.indexOf(TOUCH_PHASE_CAPABILITY) < 0) capabilities.push(TOUCH_PHASE_CAPABILITY)
  draft.requiredCapabilities = capabilities
  return validateAndNormalizeLayout(draft)
}

/** 保存一直沿原Store的保存并采用事务；文案揭示预设副本及非活动方案的影响。 */
export function controlProfileSaveLabel(preset: boolean, active: boolean): string {
  return preset ? '保存为副本并使用' : active ? '保存' : '保存并使用'
}

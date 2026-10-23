/**
 * 布局候选的纯构建规则。预览、新增、编辑和加载迁移共用系统入口目录与能力检查。
 * 输入始终保持不变；补齐后的完整树再验证，预算不足返回失败，不能移除用户控件或少补入口。
 */
import { LayoutProfile, ControlItem, ControlType, SystemAction, cloneLayout,
  makeSystemButton, validateAndNormalizeLayoutWithReason } from './ControlLayout'
import { ensureSystemMouseControl } from './TouchControlPresentation'

/** 原文件读取以 UTF-8 字节计；此限额只用于导入，合法单方案可在 V2 通过多个块传输。 */
export const MAX_LAYOUT_PROFILE_BYTES: number = 256 * 1024
export const REQUIRED_LAYOUT_ACTIONS: SystemAction[] = ['input', 'edit', 'visibility', 'mouse']

export interface LayoutCandidateResult {
  profile: LayoutProfile | null
  reason: string
}

/** 当前 UI/Native 的共同能力：顶层控件，抽屉只含一层普通 BUTTON；不把子摇杆重新解释为按钮。 */
export function layoutCapabilityIssue(profile: LayoutProfile): string {
  for (let index: number = 0; index < profile.controls.length; index++) {
    const item: ControlItem = profile.controls[index]
    if (item.systemAction !== undefined && item.type !== ControlType.BUTTON) return 'UnsupportedFeature:系统功能入口必须是按钮'
    const children: ControlItem[] = item.children ?? []
    if (children.length > 0 && item.type !== ControlType.DRAWER) return 'UnsupportedFeature:非抽屉控件不能含子控件'
    for (const child of children) {
      if (child.type !== ControlType.BUTTON || (child.children ?? []).length > 0) {
        return 'UnsupportedFeature:当前抽屉只支持一层按钮'
      }
    }
  }
  return ''
}

/** 完整树 ID 共享同一命名空间，系统保留 ID 也须避开抽屉子控件。 */
function containsId(items: ControlItem[], id: string): boolean {
  return items.some((item: ControlItem): boolean => item.id === id || containsId(item.children ?? [], id))
}

/** 目录固定系统行为但保留已有用户位置/样式；补齐在独立副本进行，失败整体拒绝。 */
export function buildLayoutCandidate(source: LayoutProfile): LayoutCandidateResult {
  const first = validateAndNormalizeLayoutWithReason(source)
  if (first.profile === null) return { profile: null, reason: first.reason }
  const issue: string = layoutCapabilityIssue(first.profile)
  if (issue.length > 0) return { profile: null, reason: issue }
  const candidate: LayoutProfile = cloneLayout(first.profile)
  const positions: number[][] = [[.778, .106, 2], [.914, .017, 5], [.778, .195, 6]]
  for (let index: number = 0; index < 3; index++) {
    const action: SystemAction = REQUIRED_LAYOUT_ACTIONS[index]
    let item: ControlItem | undefined = candidate.controls.find((control: ControlItem): boolean => control.systemAction === action)
    if (item === undefined && action === 'input') {
      item = candidate.controls.find((control: ControlItem): boolean => control.id === 'ime_chat' && control.systemAction === undefined)
    }
    if (item === undefined) {
      item = makeSystemButton(action, positions[index][0], positions[index][1], positions[index][2])
      if (containsId(candidate.controls, item.id)) {
        const base: string = 'system_' + action
        let index: number = 0
        while (containsId(candidate.controls, base + '_' + index.toString())) index++
        item.id = base + '_' + index.toString()
      }
      candidate.controls.push(item)
    }
    item.systemAction = action
    // 恢复层不进入用户组；新注入聊天入口则进入默认组，已有成员归属保持。
    if (candidate.controlGroups !== undefined) item.controlGroupId = action === 'input' ?
      (item.controlGroupId ?? candidate.defaultControlGroupId) : undefined
    // 系统入口不向游戏发用户绑定，不允许toggle/dragLook等普通按钮解释改变输入/编辑职责。
    item.keyOrMouse = 0; item.keys = []; item.modifiers = 0; item.trigger = 'press'
    item.grabbedOnly = false
    item.menuOnly = false
    item.hidden = false
    item.visibilityOverride = undefined; item.dragLook = false; item.swipeGroup = undefined
  }
  ensureSystemMouseControl(candidate)
  const final = validateAndNormalizeLayoutWithReason(candidate)
  if (final.profile === null) return { profile: null, reason: 'BudgetExceeded:' + final.reason }
  return { profile: final.profile, reason: '' }
}

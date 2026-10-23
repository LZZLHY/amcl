/**
 * 触控交互选项的持久化边界。
 *
 * 本文件只定义和校验布局中的触控策略，不读取设备、不注册传感器、不发送输入。
 * 未指定策略的方案采用直接按住：落指建立左键按下，抬指结束同一次按住，不等待第二指或长按。
 * 显式保存的双指滚动偏好保持原值；触摸板缺省仍允许双指滚动，直接模式启用它时进入手势仲裁。
 * 默认值只作用于运行时归一化，不改写旧方案原文；战斗、丢弃、自动前进继续显式启用。
 * 所有编辑、导入和运行时投递共用同一归一化函数，避免 UI 接受而 native 无法解释的半份配置。
 */
import { TOUCH_ACTION_NAMES } from './TouchActionBindings'

export type MenuTouchMode = 'direct' | 'touchpad'
export type JoystickCenterMode = 'fixed' | 'floating'
export type TouchGestureMode = 'buttons' | 'build' | 'combat'
export type TouchGyroscopeMode = 'off' | 'aim' | 'always'

/** JSON 可缺省字段；version 是本扩展自身的格式版本，与旧布局版本相互独立。 */
export interface TouchPreferences {
  version?: number
  menuMode?: MenuTouchMode
  menuSensitivity?: number
  menuTwoFingerScroll?: boolean
  menuHoldMs?: number
  joystickCenter?: JoystickCenterMode
  joystickSprint?: boolean
  joystickAutoWalk?: boolean
  joystickSprintThreshold?: number
  followGameBindings?: boolean
  hotbarSwapDoubleTap?: boolean
  hotbarDropHold?: boolean
  holdMs?: number
  gestureMode?: TouchGestureMode
  gyroscopeMode?: TouchGyroscopeMode
  gyroscopeSensitivity?: number
  gyroscopeInvertX?: boolean
  gyroscopeInvertY?: boolean
  /** 显式动作覆盖；0解除绑定，仅影响专用控件，不修改游戏配置文件。 */
  actionOverrides?: Record<string, number>
}

/** 已校验的完整快照；调用方可直接读取，不在事件热路径反复补缺省。 */
export class TouchConfiguration implements TouchPreferences {
  version: number = 1
  menuMode: MenuTouchMode = 'direct'
  menuSensitivity: number = 1
  menuTwoFingerScroll: boolean = false
  menuHoldMs: number = 350
  joystickCenter: JoystickCenterMode = 'fixed'
  joystickSprint: boolean = false
  joystickAutoWalk: boolean = false
  joystickSprintThreshold: number = 0.9
  followGameBindings: boolean = true
  hotbarSwapDoubleTap: boolean = false
  hotbarDropHold: boolean = false
  holdMs: number = 500
  gestureMode: TouchGestureMode = 'buttons'
  gyroscopeMode: TouchGyroscopeMode = 'off'
  gyroscopeSensitivity: number = 1
  gyroscopeInvertX: boolean = false
  gyroscopeInvertY: boolean = false
  actionOverrides: Record<string, number> = {}
}

/** 可选数值必须有限且在范围内；拒绝字符串、NaN 和无穷值，不以隐式转换修复非法导入。 */
function touchNumber(value: number | undefined, minimum: number, maximum: number): boolean {
  return value === undefined || (typeof value === 'number' && Number.isFinite(value)
    && value >= minimum && value <= maximum)
}

/** 可选布尔量只接受真实 boolean，避免导入的字符串 "false" 被当成启用。 */
function touchBoolean(value: boolean | undefined): boolean {
  return value === undefined || typeof value === 'boolean'
}

/**
 * 创建独立快照。undefined 表示旧方案；返回 undefined 表示有字段非法，调用方必须保留旧配置。
 * 时间参数以毫秒存档，比例不随屏幕像素密度改变；native 入口负责转换为单调时间和 surface px。
 */
export function normalizeTouchPreferences(source?: TouchPreferences): TouchConfiguration | undefined {
  const result = new TouchConfiguration()
  if (source === undefined) return result
  if (source === null || typeof source !== 'object' || Array.isArray(source)) return undefined
  if (source.version !== undefined && source.version !== 1) return undefined
  if (source.menuMode !== undefined && source.menuMode !== 'direct' && source.menuMode !== 'touchpad') return undefined
  if (source.joystickCenter !== undefined && source.joystickCenter !== 'fixed'
    && source.joystickCenter !== 'floating') return undefined
  if (source.gestureMode !== undefined && source.gestureMode !== 'buttons'
    && source.gestureMode !== 'build' && source.gestureMode !== 'combat') return undefined
  if (source.gyroscopeMode !== undefined && source.gyroscopeMode !== 'off'
    && source.gyroscopeMode !== 'aim' && source.gyroscopeMode !== 'always') return undefined
  if (!touchNumber(source.menuSensitivity, 0.3, 3) || !touchNumber(source.menuHoldMs, 150, 1000)
    || !touchNumber(source.joystickSprintThreshold, 0.5, 1.5) || !touchNumber(source.holdMs, 200, 1500)
    || !touchNumber(source.gyroscopeSensitivity, 0.1, 3)) return undefined
  if (!touchBoolean(source.menuTwoFingerScroll) || !touchBoolean(source.joystickSprint)
    || !touchBoolean(source.joystickAutoWalk) || !touchBoolean(source.followGameBindings)
    || !touchBoolean(source.hotbarSwapDoubleTap) || !touchBoolean(source.hotbarDropHold)
    || !touchBoolean(source.gyroscopeInvertX) || !touchBoolean(source.gyroscopeInvertY)) return undefined
  result.menuMode = source.menuMode ?? result.menuMode
  result.menuSensitivity = source.menuSensitivity ?? result.menuSensitivity
  // 直接操作优先连续按住；相对触摸板没有落指即按下的含义，可以缺省保留双指滚动。
  // 用户明确写出的true/false始终优先，不因为本轮缺省修正静默覆盖已有操作习惯。
  result.menuTwoFingerScroll = source.menuTwoFingerScroll ?? (result.menuMode === 'touchpad')
  result.menuHoldMs = source.menuHoldMs ?? result.menuHoldMs
  result.joystickCenter = source.joystickCenter ?? result.joystickCenter
  result.joystickSprint = source.joystickSprint ?? result.joystickSprint
  result.joystickAutoWalk = source.joystickAutoWalk ?? result.joystickAutoWalk
  result.joystickSprintThreshold = source.joystickSprintThreshold ?? result.joystickSprintThreshold
  result.followGameBindings = source.followGameBindings ?? result.followGameBindings
  result.hotbarSwapDoubleTap = source.hotbarSwapDoubleTap ?? result.hotbarSwapDoubleTap
  result.hotbarDropHold = source.hotbarDropHold ?? result.hotbarDropHold
  result.holdMs = source.holdMs ?? result.holdMs
  result.gestureMode = source.gestureMode ?? result.gestureMode
  result.gyroscopeMode = source.gyroscopeMode ?? result.gyroscopeMode
  result.gyroscopeSensitivity = source.gyroscopeSensitivity ?? result.gyroscopeSensitivity
  result.gyroscopeInvertX = source.gyroscopeInvertX ?? result.gyroscopeInvertX
  result.gyroscopeInvertY = source.gyroscopeInvertY ?? result.gyroscopeInvertY
  if (source.actionOverrides !== undefined) {
    if (source.actionOverrides === null || typeof source.actionOverrides !== 'object'
      || Array.isArray(source.actionOverrides)) return undefined
    const names: string[] = Object.keys(source.actionOverrides).sort()
    if (names.length > TOUCH_ACTION_NAMES.length) return undefined
    for (const name of names) {
      const code: number = source.actionOverrides[name]
      if (TOUCH_ACTION_NAMES.indexOf(name) < 0 || !Number.isInteger(code) || code < -16 || code > 512) return undefined
      result.actionOverrides[name] = code
    }
  }
  return result
}

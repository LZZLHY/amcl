/**
 * PojavImporter.ets — PojavLauncher 布局 JSON 兼容导入（阶段 3.5）
 *
 * PojavLauncher 的 customcontrols/*.json 顶层有 mControlDataList 字段，每项
 * 描述一个虚拟按键。本文件把 PojavLauncher v6 的格式转换成 AMCL LayoutProfile v2。
 *
 * ⚠️ 不保证 100% 兼容——dynamic 表达式的语法（"${screen_width} - 100" 等）
 * 这里只支持最简单的常数 / 像素值。复杂表达式会被忽略并使用默认位置。
 *
 * 来源参考：
 *   https://github.com/PojavLauncherTeam/PojavLauncher/blob/main/app_pojavlauncher/src/main/java/net/kdt/pojavlaunch/customcontrols/ControlData.java
 *   https://github.com/PojavLauncherTeam/PojavLauncher/blob/main/app_pojavlauncher/src/main/java/net/kdt/pojavlaunch/customcontrols/CustomControls.java
 *
 * Pojav 用的键码：
 *   - 鼠标用 SPECIAL_KEYCODE，例如左键 = -1, 右键 = -2（注意：与 AMCL 的 -(button+1) 不一样！）
 *   - 字母 / 数字键用 LWJGL/GLFW 数值（与本项目一致）
 */

import {
  ControlItem, ControlType, LayoutProfile, AlignGroup,
  LAYOUT_PROFILE_VERSION,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_JOYSTICK_DEAD_ZONE
} from './ControlLayout';
import { encodeMouse, GLFW_MOUSE_BUTTON_LEFT, GLFW_MOUSE_BUTTON_RIGHT, GLFW_MOUSE_BUTTON_MIDDLE } from './GlfwKeys';

interface PojavControlData {
  name?: string
  keycodes?: number[]
  dynamicX?: string  // 字符串表达式（"100", "${screen_width}/2", ...）
  dynamicY?: string
  specifiedWidth?: number
  specifiedHeight?: number
  isToggle?: boolean
  passThruEnabled?: boolean
  isHideable?: boolean
  isDynamicBtn?: boolean
  cornerRadius?: number
  opacity?: number
  bgColor?: number   // ARGB int
  strokeColor?: number
  strokeWidth?: number
}

interface PojavRoot {
  version?: number
  mScaledAt?: number
  mControlDataList?: PojavControlData[]
  scaledAt?: number       // 可能字段名不同
  controlDataList?: PojavControlData[]
}

/**
 * 检测一段 JSON 是不是 PojavLauncher 格式。
 * 简单按存在 mControlDataList / controlDataList 判断。
 */
export function isPojavLayoutJson(obj: object): boolean {
  // ts-style runtime 检测：用任意属性访问而不断言 as
  const root = obj as PojavRoot
  return Array.isArray(root.mControlDataList) || Array.isArray(root.controlDataList)
}

/**
 * 把 PojavLauncher 键码转成 AMCL 键码：
 *   - -1（鼠标左键）→ encodeMouse(GLFW_MOUSE_BUTTON_LEFT) = -1（巧合一致）
 *   - -2（鼠标右键）→ encodeMouse(GLFW_MOUSE_BUTTON_RIGHT) = -2（巧合一致）
 *   - -3（鼠标中键）→ encodeMouse(GLFW_MOUSE_BUTTON_MIDDLE) = -3
 *   - >= 0 → GLFW key code，原样使用
 */
function pojavKeyToAmcl(pojavKey: number): number {
  if (pojavKey === -1) return encodeMouse(GLFW_MOUSE_BUTTON_LEFT)
  if (pojavKey === -2) return encodeMouse(GLFW_MOUSE_BUTTON_RIGHT)
  if (pojavKey === -3) return encodeMouse(GLFW_MOUSE_BUTTON_MIDDLE)
  if (pojavKey < 0) return 0  // 未知特殊键
  return pojavKey
}

/**
 * 极简 dynamicX / dynamicY 表达式求值。
 *   - 纯数字 → 数字（像素）
 *   - "${screen_width}" / "${screen_height}" → 1.0（按百分比）
 *   - "${screen_width}-100" → 简单减法（仅支持常数减常数）
 *
 * 失败时返回 0.5（屏幕中心）。
 */
function evalDynamic(expr: string | undefined, screenRefVp: number): number {
  if (!expr) return 0.5
  const s = expr.trim()
  // 纯数字
  const numMatch = s.match(/^-?\d+(\.\d+)?$/)
  if (numMatch) {
    const px = parseFloat(s)
    return Math.max(0, Math.min(1, px / screenRefVp))
  }
  // ${screen_width} / ${screen_height}
  if (s === '${screen_width}' || s === '${screen_height}') return 1.0
  // ${screen_width}-N / ${screen_height}-N
  const minusMatch = s.match(/^\$\{screen_(width|height)\}\s*-\s*(\d+(\.\d+)?)$/)
  if (minusMatch) {
    const px = parseFloat(minusMatch[2])
    return Math.max(0, Math.min(1, 1 - px / screenRefVp))
  }
  return 0.5
}

/**
 * 主入口：解析 PojavLauncher JSON 字符串为 LayoutProfile。
 * profileName：导入后赋的名字（用户在 import UI 里确认）。
 */
export function importPojavLayout(json: string, profileName: string): LayoutProfile | null {
  let root: PojavRoot
  try {
    root = JSON.parse(json) as PojavRoot
  } catch (e) {
    return null
  }
  const list: PojavControlData[] = root.mControlDataList ?? root.controlDataList ?? []
  if (list.length === 0) return null

  // 屏幕基准（PojavLauncher 默认 720vp 横屏）
  const SCREEN_REF_W = 720
  const SCREEN_REF_H = 360

  const controls: ControlItem[] = []
  for (let i = 0; i < list.length; i++) {
    const p = list[i]
    const keys = p.keycodes ?? []
    if (keys.length === 0) continue
    const primaryKey = pojavKeyToAmcl(keys[0])
    if (primaryKey === 0) continue  // 不支持的键

    const xPct = evalDynamic(p.dynamicX, SCREEN_REF_W)
    const yPct = evalDynamic(p.dynamicY, SCREEN_REF_H)

    const w = p.specifiedWidth ?? 50
    const h = p.specifiedHeight ?? 50

    // PojavLauncher 多键 → 用 keys[] 字段（去重 / 过滤无效）
    const allKeys: number[] = []
    for (let k = 0; k < keys.length; k++) {
      const ak = pojavKeyToAmcl(keys[k])
      if (ak !== 0 && allKeys.indexOf(ak) < 0) allKeys.push(ak)
    }

    const item: ControlItem = {
      id: 'pojav_' + i.toString() + '_' + (p.name ?? 'btn'),
      label: p.name ?? '',
      type: ControlType.BUTTON,
      keyOrMouse: primaryKey,
      keys: allKeys.length > 1 ? allKeys : undefined,
      trigger: p.isToggle ? 'toggle' : 'press',
      xPct, yPct,
      baseWidth: w, baseHeight: h,
      itemScale: 1.0,
      isCircle: (p.cornerRadius ?? 0) >= 50,
      alignGroup: AlignGroup.NONE, alignIndex: 0,
      grabbedOnly: !(p.passThruEnabled ?? false),
      hidden: false,
      locked: false
    }
    controls.push(item)
  }

  if (controls.length === 0) return null

  const scale = ((root.mScaledAt ?? root.scaledAt ?? 100) as number) / 100
  return {
    version: LAYOUT_PROFILE_VERSION,
    name: profileName,
    globalScale: scale,
    lookSensitivity: DEFAULT_LOOK_SENSITIVITY,
    invertY: DEFAULT_INVERT_Y,
    joystickDeadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
    haptic: true,
    targetDevice: 'any',
    isPreset: false,
    controls
  }
}

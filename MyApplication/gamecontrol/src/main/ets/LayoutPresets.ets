/**
 * LayoutPresets.ets — 系统预设布局集合
 *
 * 重构 2026-05-30：预设系统精简为 **两套**——手机画幅 / 平板画幅。
 *   - 所有按钮统一为 DEFAULT_BUTTON_SIZE 正方形框（与 hotbar 数字键同尺寸 + 同圆角）。
 *   - 框内文字由绑定键自动推导（label 留空 → effectiveLabel）；鼠标左/右键显示"左""右"。
 *   - 摇杆默认圆形（可在编辑器切方形）。
 *   - 两套差异仅在画幅：平板用更大的 globalScale + 更宽的 hotbar 步进 + 贴边布局。
 *
 * 旧的 5 套（经典手机 / 基岩版 / PvP / 平板宽屏 / Mod）已删除；LayoutStore.load()
 * 会把用户存档里残留的旧系统预设按名清理掉（仅清 isPreset 的，用户克隆的方案保留）。
 *
 * 命名规范：预设名以 "★" 开头，便于在方案列表中和用户自定义方案区分。
 */

import {
  ControlItem, ControlType, LayoutProfile, AlignGroup,
  LAYOUT_PROFILE_VERSION,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_JOYSTICK_DEAD_ZONE,
  DEFAULT_BUTTON_SIZE, DEFAULT_CORNER_RADIUS, makeHotbarSelector, makeSystemButton
} from './ControlLayout';
import {
  GLFW_KEY_SPACE, GLFW_KEY_E, GLFW_KEY_Q, GLFW_KEY_T, GLFW_KEY_M,
  GLFW_KEY_ESCAPE, GLFW_KEY_TAB,
  GLFW_KEY_F3, GLFW_KEY_F4, GLFW_KEY_F5,
  GLFW_KEY_LEFT_SHIFT,
  GLFW_KEY_1,
  encodeMouse, GLFW_MOUSE_BUTTON_LEFT, GLFW_MOUSE_BUTTON_RIGHT
} from './GlfwKeys';

const M_LMB = encodeMouse(GLFW_MOUSE_BUTTON_LEFT)
const M_RMB = encodeMouse(GLFW_MOUSE_BUTTON_RIGHT)

/**
 * 统一正方形按钮：所有普通按钮共用 DEFAULT_BUTTON_SIZE 方形基准 + DEFAULT_CORNER_RADIUS
 * 轻微圆角，外观完全一致（和 hotbar 数字键同尺寸）。label 留空 → 框内显示绑定键名。
 *   scale / corner：可选，复现用户在设备上调过的"放大动作键 / 圆角摇杆"等个性化。
 */
function sqBtn(
  id: string, label: string, key: number,
  xPct: number, yPct: number,
  group: AlignGroup = AlignGroup.NONE, alignIndex: number = 0,
  grabbedOnly: boolean = false,
  scale: number = 1.0, corner: number = DEFAULT_CORNER_RADIUS,
  dragLook: boolean = false
): ControlItem {
  return {
    id, label, type: ControlType.BUTTON, keyOrMouse: key,
    xPct, yPct,
    baseWidth: DEFAULT_BUTTON_SIZE, baseHeight: DEFAULT_BUTTON_SIZE,
    itemScale: scale, isCircle: corner >= 0.99,
    style: { cornerRadius: corner },
    alignGroup: group, alignIndex,
    grabbedOnly,
    dragLook: dragLook ? true : undefined
  }
}

function joystick(xPct: number, yPct: number, size: number = 120,
                  scale: number = 1.5, corner: number = 0.3): ControlItem {
  return {
    id: 'joystick', label: '', type: ControlType.JOYSTICK, keyOrMouse: 0,
    xPct, yPct,
    baseWidth: size, baseHeight: size,
    itemScale: scale, isCircle: corner >= 0.99,
    style: { cornerRadius: corner },
    alignGroup: AlignGroup.NONE, alignIndex: 0,
    grabbedOnly: true
  }
}

function scrollWheel(xPct: number, yPct: number, w: number = 28, h: number = 84,
                     scale: number = 1.15): ControlItem {
  return {
    id: 'scroll', label: '⇅', type: ControlType.SCROLL_WHEEL, keyOrMouse: 0,
    xPct, yPct,
    baseWidth: w, baseHeight: h,
    itemScale: scale, isCircle: false,
    alignGroup: AlignGroup.NONE, alignIndex: 0,
    grabbedOnly: true
  }
}

/**
 * 1-9 hotbar：从 startXPct 起、按 stepXPct 等距并排（贴在一起）。统一正方形框。
 * 直接给百分比步距，复现用户在设备上调好的紧贴间距。
 */
function hotbar(startXPct: number, yPct: number, stepXPct: number): ControlItem[] {
  const items: ControlItem[] = []
  for (let n = 1; n <= 9; n++) {
    items.push({
      id: 'hb' + n.toString(),
      label: '',
      type: ControlType.BUTTON,
      keyOrMouse: GLFW_KEY_1 + n - 1,
      xPct: startXPct + (n - 1) * stepXPct,
      yPct,
      baseWidth: DEFAULT_BUTTON_SIZE, baseHeight: DEFAULT_BUTTON_SIZE,
      itemScale: 1.0, isCircle: false,
      style: { cornerRadius: DEFAULT_CORNER_RADIUS },
      alignGroup: AlignGroup.HOTBAR, alignIndex: n - 1,
      grabbedOnly: true
    })
  }
  return items
}

function withDefaults(name: string, controls: ControlItem[], scale: number = 1.0,
                     targetDevice: 'phone' | 'tablet' | 'foldable' | 'any' = 'any',
                     globalOpacity: number = 1.0): LayoutProfile {
  return {
    version: LAYOUT_PROFILE_VERSION,
    name,
    globalScale: scale,
    lookSensitivity: DEFAULT_LOOK_SENSITIVITY,
    invertY: DEFAULT_INVERT_Y,
    joystickDeadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
    haptic: true,
    globalOpacity,
    targetDevice,
    isPreset: true,
    controls
  }
}

// ==================== 预设 1：手机画幅 ====================
// 2026-07-16 更新：直接采用用户在手机上精修并设为主用的"★ 手机 副本"（从设备存档拉取，逐控件对齐）。
// 与旧版差异：**去掉 hb1–hb9 数字键行**（改用底部物品栏直点条直接选格）；系统三键（聊/设置/显示）
// 精确烘焙到用户摆放的位置；动作键位置为吸附后的精确小数。globalScale 0.7、globalOpacity 1.0。
export function presetPhone(): LayoutProfile {
  // 系统功能按钮（聊/设置/显示）—— 位置取用户精修值；label/场景由 makeSystemButton 定，聊沿用"聊"。
  const chat = makeSystemButton('input', 0.9208632440476191, 0.0200, 3)
  chat.label = '聊'
  const edit = makeSystemButton('edit', 0.8754019345238095, 0.0200, 5)
  const vis = makeSystemButton('visibility', 0.829940625, 0.0200, 6)
  const controls: ControlItem[] = [
    joystick(0.0666, 0.5205, 120, 1.6, 0.3),
    // 右下动作键（放大 1.45；攻击/放置开启拖动瞄准 dragLook=true）
    sqBtn('atk', '', M_LMB, 0.8020000000000002, 0.4610, AlignGroup.ACTION_RIGHT, 0, true, 1.45, 0.12, true),
    sqBtn('place', '', M_RMB, 0.8657425595238096, 0.4610, AlignGroup.ACTION_RIGHT, 1, true, 1.45, 0.12, true),
    sqBtn('jump', '', GLFW_KEY_SPACE, 0.8208, 0.6350, AlignGroup.MOVE_RIGHT, 0, true, 1.45),
    sqBtn('sneak', '', GLFW_KEY_LEFT_SHIFT, 0.8208, 0.7759046052631579, AlignGroup.MOVE_RIGHT, 1, true, 1.45),
    // 左上角：ESC / F3 / F5 / TAB
    sqBtn('key_ESC', '', GLFW_KEY_ESCAPE, 0.0120, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 0, false),
    sqBtn('key_F3', '', GLFW_KEY_F3, 0.0713, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 1, true),
    sqBtn('key_F5', '', GLFW_KEY_F5, 0.16222261904761903, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 2, true),
    sqBtn('key_TAB', '', GLFW_KEY_TAB, 0.0120, 0.12049342105263157, AlignGroup.DEBUG_TOP_LEFT, 3, false),
    // 中右上：功能键 E / Q / M（id 沿用 key_F，实际绑 M 键）
    sqBtn('key_E', '', GLFW_KEY_E, 0.6673749999999998, 0.1160, AlignGroup.FUNC_TOP_RIGHT, 0, true),
    sqBtn('key_Q', '', GLFW_KEY_Q, 0.7128363095238094, 0.1160, AlignGroup.FUNC_TOP_RIGHT, 1, true),
    sqBtn('key_F', '', GLFW_KEY_M, 0.7582976190476189, 0.1160, AlignGroup.FUNC_TOP_RIGHT, 2, true),
    // 聊天（系统输入按钮）
    chat,
    // 用户新增：F4（配合 F3 切游戏模式）+ 第二个潜行键（右下）
    sqBtn('btn_788064', '', GLFW_KEY_F4, 0.1167613095238095, 0.0200, AlignGroup.NONE, 0, true),
    sqBtn('btn_086848', '', GLFW_KEY_LEFT_SHIFT, 0.8887, 0.8430, AlignGroup.NONE, 0, true),
    // 滚轮
    scrollWheel(0.6863, 0.7243),
    // 系统：设置 / 显示
    edit,
    vis,
  ]
  // F1：物品栏直点条默认开启（LayoutStore.load 按设备精确对齐 MC hotbar；此处仅占位位置）
  controls.push(makeHotbarSelector(0.34, 0.9, 300, 36))
  return withDefaults('★ 手机', controls, 0.7, 'phone', 1.0)
}

// ==================== 预设 2：平板画幅 ====================
// 2026-07-16 更新：直接采用用户在平板上精修并设为主用的"★ 平板 副本"（从设备存档拉取，逐控件对齐）。
// 与旧版差异：去掉 hb1–hb9 数字键行（改用底部物品栏直点条）；系统三键（聊/设置/显示）精确烘焙；
// 动作键为吸附后精确坐标。globalScale 1.15、globalOpacity 0.9。
export function presetTablet(): LayoutProfile {
  const chat = makeSystemButton('input', 0.928825, 0.0200, 3)
  chat.label = '聊'
  const edit = makeSystemButton('edit', 0.8823785714285715, 0.0200, 5)
  const vis = makeSystemButton('visibility', 0.8359321428571428, 0.0200, 6)
  const controls: ControlItem[] = [
    joystick(0.0782, 0.6394, 120, 1.5, 0.3),
    // 右下动作键（放大 1.45；攻击/放置开启拖动瞄准 dragLook=true）
    sqBtn('atk', '', M_LMB, 0.8170803571428571, 0.5010853260869566, AlignGroup.ACTION_RIGHT, 0, true, 1.45, 0.12, true),
    sqBtn('place', '', M_RMB, 0.8823785714285713, 0.5010853260869566, AlignGroup.ACTION_RIGHT, 1, true, 1.45, 0.12, true),
    sqBtn('jump', '', GLFW_KEY_SPACE, 0.8516, 0.6423999999999999, AlignGroup.MOVE_RIGHT, 0, true, 1.45),
    sqBtn('sneak', '', GLFW_KEY_LEFT_SHIFT, 0.8516, 0.7417668478260868, AlignGroup.MOVE_RIGHT, 1, true, 1.45),
    // 中右上：功能键 E / Q / M（id 沿用 key_F，实际绑 M 键）
    sqBtn('key_E', '', GLFW_KEY_E, 0.6742214285714285, 0.1282641304347826, AlignGroup.FUNC_TOP_RIGHT, 0, true),
    sqBtn('key_Q', '', GLFW_KEY_Q, 0.7206678571428571, 0.1282641304347826, AlignGroup.FUNC_TOP_RIGHT, 1, true),
    sqBtn('key_F', '', GLFW_KEY_M, 0.7671142857142857, 0.1282641304347826, AlignGroup.FUNC_TOP_RIGHT, 2, true),
    // 左上角：ESC / F3 / F5 / TAB
    sqBtn('key_ESC', '', GLFW_KEY_ESCAPE, 0.0117, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 0, false),
    sqBtn('key_F3', '', GLFW_KEY_F3, 0.0779, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 1, false),
    sqBtn('key_F5', '', GLFW_KEY_F5, 0.17079285714285714, 0.0200, AlignGroup.DEBUG_TOP_LEFT, 2, true),
    sqBtn('key_TAB', '', GLFW_KEY_TAB, 0.0117, 0.09067934782608696, AlignGroup.DEBUG_TOP_LEFT, 3, false),
    // 聊天（系统输入按钮）
    chat,
    // 用户新增：F4（配合 F3 切游戏模式）+ 第二个潜行键（右下）
    sqBtn('btn_247776', '', GLFW_KEY_F4, 0.12434642857142857, 0.0200, AlignGroup.NONE, 0, false),
    sqBtn('btn_420906', '', GLFW_KEY_LEFT_SHIFT, 0.9258, 0.8088, AlignGroup.NONE, 0, true),
    // 滚轮
    scrollWheel(0.7291, 0.8717),
    // 系统：设置 / 显示
    edit,
    vis,
  ]
  // F1：物品栏直点条默认开启（LayoutStore.load 按设备精确对齐 MC hotbar；此处仅占位位置）
  controls.push(makeHotbarSelector(0.34, 0.9, 300, 36))
  return withDefaults('★ 平板', controls, 1.15, 'tablet', 0.9)
}

/**
 * 所有系统预设的列表。LayoutStore 在 store 为空 / 启动时调用。
 * 第 0 项作为默认活跃方案（按设备画幅自动选 phone / tablet，见 LayoutStore.pickDefaultByDevice）。
 */
export function getAllPresets(): LayoutProfile[] {
  return [
    presetPhone(),
    presetTablet(),
  ]
}

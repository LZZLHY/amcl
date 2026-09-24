/**
 * GlfwKeys.ets — GLFW key constants for virtual controls
 *
 * Must match GLFW 3.x key codes used by input_bridge_ohos.c and MC.
 * 数值参考：https://www.glfw.org/docs/latest/group__keys.html
 *
 * 2026-05-28 input-system-refactor 阶段 2.1：补完 GLFW 3.x 完整键集
 *   （之前只有约 40 个，做改键 UI 前必须先把 120+ 都列上）。
 */

// Action constants
export const GLFW_PRESS = 1
export const GLFW_RELEASE = 0
export const GLFW_REPEAT = 2

// Modifier mask（与 GLFW 一致；可按位或后传给 sendKeyEvent 的 mods 参数）
export const GLFW_MOD_SHIFT     = 0x0001
export const GLFW_MOD_CONTROL   = 0x0002
export const GLFW_MOD_ALT       = 0x0004
export const GLFW_MOD_SUPER     = 0x0008
export const GLFW_MOD_CAPS_LOCK = 0x0010
export const GLFW_MOD_NUM_LOCK  = 0x0020

// Mouse buttons
export const GLFW_MOUSE_BUTTON_LEFT = 0
export const GLFW_MOUSE_BUTTON_RIGHT = 1
export const GLFW_MOUSE_BUTTON_MIDDLE = 2
export const GLFW_MOUSE_BUTTON_4 = 3
export const GLFW_MOUSE_BUTTON_5 = 4
export const GLFW_MOUSE_BUTTON_6 = 5
export const GLFW_MOUSE_BUTTON_7 = 6
export const GLFW_MOUSE_BUTTON_8 = 7

// ==================== 可打印键 ====================
export const GLFW_KEY_SPACE = 32
export const GLFW_KEY_APOSTROPHE = 39      /* ' */
export const GLFW_KEY_COMMA = 44           /* , */
export const GLFW_KEY_MINUS = 45           /* - */
export const GLFW_KEY_PERIOD = 46          /* . */
export const GLFW_KEY_SLASH = 47           /* / */
export const GLFW_KEY_0 = 48
export const GLFW_KEY_1 = 49
export const GLFW_KEY_2 = 50
export const GLFW_KEY_3 = 51
export const GLFW_KEY_4 = 52
export const GLFW_KEY_5 = 53
export const GLFW_KEY_6 = 54
export const GLFW_KEY_7 = 55
export const GLFW_KEY_8 = 56
export const GLFW_KEY_9 = 57
export const GLFW_KEY_SEMICOLON = 59       /* ; */
export const GLFW_KEY_EQUAL = 61           /* = */

export const GLFW_KEY_A = 65
export const GLFW_KEY_B = 66
export const GLFW_KEY_C = 67
export const GLFW_KEY_D = 68
export const GLFW_KEY_E = 69
export const GLFW_KEY_F = 70
export const GLFW_KEY_G = 71
export const GLFW_KEY_H = 72
export const GLFW_KEY_I = 73
export const GLFW_KEY_J = 74
export const GLFW_KEY_K = 75
export const GLFW_KEY_L = 76
export const GLFW_KEY_M = 77
export const GLFW_KEY_N = 78
export const GLFW_KEY_O = 79
export const GLFW_KEY_P = 80
export const GLFW_KEY_Q = 81
export const GLFW_KEY_R = 82
export const GLFW_KEY_S = 83
export const GLFW_KEY_T = 84
export const GLFW_KEY_U = 85
export const GLFW_KEY_V = 86
export const GLFW_KEY_W = 87
export const GLFW_KEY_X = 88
export const GLFW_KEY_Y = 89
export const GLFW_KEY_Z = 90

export const GLFW_KEY_LEFT_BRACKET = 91    /* [ */
export const GLFW_KEY_BACKSLASH = 92       /* \ */
export const GLFW_KEY_RIGHT_BRACKET = 93   /* ] */
export const GLFW_KEY_GRAVE_ACCENT = 96    /* ` */
export const GLFW_KEY_WORLD_1 = 161
export const GLFW_KEY_WORLD_2 = 162

// ==================== 控制键 ====================
export const GLFW_KEY_ESCAPE = 256
export const GLFW_KEY_ENTER = 257
export const GLFW_KEY_TAB = 258
export const GLFW_KEY_BACKSPACE = 259
export const GLFW_KEY_INSERT = 260
export const GLFW_KEY_DELETE = 261

// 方向键
export const GLFW_KEY_RIGHT = 262
export const GLFW_KEY_LEFT = 263
export const GLFW_KEY_DOWN = 264
export const GLFW_KEY_UP = 265

export const GLFW_KEY_PAGE_UP = 266
export const GLFW_KEY_PAGE_DOWN = 267
export const GLFW_KEY_HOME = 268
export const GLFW_KEY_END = 269
export const GLFW_KEY_CAPS_LOCK = 280
export const GLFW_KEY_SCROLL_LOCK = 281
export const GLFW_KEY_NUM_LOCK = 282
export const GLFW_KEY_PRINT_SCREEN = 283
export const GLFW_KEY_PAUSE = 284

// F 键
export const GLFW_KEY_F1 = 290
export const GLFW_KEY_F2 = 291
export const GLFW_KEY_F3 = 292
export const GLFW_KEY_F4 = 293
export const GLFW_KEY_F5 = 294
export const GLFW_KEY_F6 = 295
export const GLFW_KEY_F7 = 296
export const GLFW_KEY_F8 = 297
export const GLFW_KEY_F9 = 298
export const GLFW_KEY_F10 = 299
export const GLFW_KEY_F11 = 300
export const GLFW_KEY_F12 = 301
export const GLFW_KEY_F13 = 302
export const GLFW_KEY_F14 = 303
export const GLFW_KEY_F15 = 304
export const GLFW_KEY_F16 = 305
export const GLFW_KEY_F17 = 306
export const GLFW_KEY_F18 = 307
export const GLFW_KEY_F19 = 308
export const GLFW_KEY_F20 = 309
export const GLFW_KEY_F21 = 310
export const GLFW_KEY_F22 = 311
export const GLFW_KEY_F23 = 312
export const GLFW_KEY_F24 = 313
export const GLFW_KEY_F25 = 314

// 小键盘
export const GLFW_KEY_KP_0 = 320
export const GLFW_KEY_KP_1 = 321
export const GLFW_KEY_KP_2 = 322
export const GLFW_KEY_KP_3 = 323
export const GLFW_KEY_KP_4 = 324
export const GLFW_KEY_KP_5 = 325
export const GLFW_KEY_KP_6 = 326
export const GLFW_KEY_KP_7 = 327
export const GLFW_KEY_KP_8 = 328
export const GLFW_KEY_KP_9 = 329
export const GLFW_KEY_KP_DECIMAL = 330
export const GLFW_KEY_KP_DIVIDE = 331
export const GLFW_KEY_KP_MULTIPLY = 332
export const GLFW_KEY_KP_SUBTRACT = 333
export const GLFW_KEY_KP_ADD = 334
export const GLFW_KEY_KP_ENTER = 335
export const GLFW_KEY_KP_EQUAL = 336

// 修饰键
export const GLFW_KEY_LEFT_SHIFT = 340
export const GLFW_KEY_LEFT_CONTROL = 341
export const GLFW_KEY_LEFT_ALT = 342
export const GLFW_KEY_LEFT_SUPER = 343
export const GLFW_KEY_RIGHT_SHIFT = 344
export const GLFW_KEY_RIGHT_CONTROL = 345
export const GLFW_KEY_RIGHT_ALT = 346
export const GLFW_KEY_RIGHT_SUPER = 347
export const GLFW_KEY_MENU = 348

/**
 * 编码鼠标按钮为 ControlItem.keyOrMouse 字段（向下兼容）。
 * 例：encodeMouse(GLFW_MOUSE_BUTTON_LEFT) = -1，对应 ArkTS 与 C 层的"<0 = 鼠标"约定。
 */
export function encodeMouse(button: number): number {
  return -(button + 1)
}

/**
 * 判断 keyOrMouse 是否表示鼠标按钮。
 */
export function isMouseCode(code: number): boolean {
  return code < 0
}

/**
 * 解码 keyOrMouse 为鼠标按钮 index（仅当 isMouseCode 为 true 时有意义）。
 */
export function decodeMouse(code: number): number {
  return -(code) - 1
}

// ==================== 滚轮方向约定（R3 / 单一真相源） ====================
//
// GLFW scroll 约定：yoffset 向上滚 = 正、向下滚 = 负。MC 用 yoffset 切 hotbar
// （向上滚 = 上一格 / prev，向下滚 = 下一格 / next）。
//
// 虚拟滚轮控件（上滑手势）和物理滚轮 / 手柄肩键都引用这两个常量，确保所有来源对
// "同方向 → 同 yoffset 符号"的约定一致，避免不同设备切 hotbar 方向相反。
export const SCROLL_YOFFSET_UP: number = 1     // 向上滚 / 上滑 / hotbar prev
export const SCROLL_YOFFSET_DOWN: number = -1  // 向下滚 / 下滑 / hotbar next

/**
 * 改键 UI 使用：键码 → 显示名称。
 * 未列出的键 fallback 到 "Key #<code>" 字符串，方便调试。
 */
export function glfwKeyName(code: number): string {
  if (isMouseCode(code)) {
    const b = decodeMouse(code)
    if (b === GLFW_MOUSE_BUTTON_LEFT) return '鼠标左键'
    if (b === GLFW_MOUSE_BUTTON_RIGHT) return '鼠标右键'
    if (b === GLFW_MOUSE_BUTTON_MIDDLE) return '鼠标中键'
    if (b === GLFW_MOUSE_BUTTON_4) return '鼠标 4'
    if (b === GLFW_MOUSE_BUTTON_5) return '鼠标 5'
    return '鼠标 #' + b.toString()
  }
  // ASCII 可打印
  if (code >= GLFW_KEY_A && code <= GLFW_KEY_Z) return String.fromCharCode(code)
  if (code >= GLFW_KEY_0 && code <= GLFW_KEY_9) return String.fromCharCode(code)
  // 常用功能键
  switch (code) {
    case GLFW_KEY_SPACE: return 'Space'
    case GLFW_KEY_APOSTROPHE: return "'"
    case GLFW_KEY_COMMA: return ','
    case GLFW_KEY_MINUS: return '-'
    case GLFW_KEY_PERIOD: return '.'
    case GLFW_KEY_SLASH: return '/'
    case GLFW_KEY_SEMICOLON: return ';'
    case GLFW_KEY_EQUAL: return '='
    case GLFW_KEY_LEFT_BRACKET: return '['
    case GLFW_KEY_BACKSLASH: return '\\'
    case GLFW_KEY_RIGHT_BRACKET: return ']'
    case GLFW_KEY_GRAVE_ACCENT: return '`'
    case GLFW_KEY_ESCAPE: return 'Esc'
    case GLFW_KEY_ENTER: return 'Enter'
    case GLFW_KEY_TAB: return 'Tab'
    case GLFW_KEY_BACKSPACE: return 'Backspace'
    case GLFW_KEY_INSERT: return 'Insert'
    case GLFW_KEY_DELETE: return 'Delete'
    case GLFW_KEY_RIGHT: return '→'
    case GLFW_KEY_LEFT: return '←'
    case GLFW_KEY_DOWN: return '↓'
    case GLFW_KEY_UP: return '↑'
    case GLFW_KEY_PAGE_UP: return 'PgUp'
    case GLFW_KEY_PAGE_DOWN: return 'PgDn'
    case GLFW_KEY_HOME: return 'Home'
    case GLFW_KEY_END: return 'End'
    case GLFW_KEY_CAPS_LOCK: return 'CapsLk'
    case GLFW_KEY_SCROLL_LOCK: return 'ScrLk'
    case GLFW_KEY_NUM_LOCK: return 'NumLk'
    case GLFW_KEY_PRINT_SCREEN: return 'PrtSc'
    case GLFW_KEY_PAUSE: return 'Pause'
    case GLFW_KEY_LEFT_SHIFT: return 'L Shift'
    case GLFW_KEY_LEFT_CONTROL: return 'L Ctrl'
    case GLFW_KEY_LEFT_ALT: return 'L Alt'
    case GLFW_KEY_LEFT_SUPER: return 'L Super'
    case GLFW_KEY_RIGHT_SHIFT: return 'R Shift'
    case GLFW_KEY_RIGHT_CONTROL: return 'R Ctrl'
    case GLFW_KEY_RIGHT_ALT: return 'R Alt'
    case GLFW_KEY_RIGHT_SUPER: return 'R Super'
    case GLFW_KEY_MENU: return 'Menu'
  }
  // F 键
  if (code >= GLFW_KEY_F1 && code <= GLFW_KEY_F12) {
    return 'F' + (code - GLFW_KEY_F1 + 1).toString()
  }
  if (code >= GLFW_KEY_F13 && code <= GLFW_KEY_F25) {
    return 'F' + (code - GLFW_KEY_F1 + 1).toString()
  }
  // 小键盘
  if (code >= GLFW_KEY_KP_0 && code <= GLFW_KEY_KP_9) {
    return 'KP ' + (code - GLFW_KEY_KP_0).toString()
  }
  switch (code) {
    case GLFW_KEY_KP_DECIMAL: return 'KP .'
    case GLFW_KEY_KP_DIVIDE: return 'KP /'
    case GLFW_KEY_KP_MULTIPLY: return 'KP *'
    case GLFW_KEY_KP_SUBTRACT: return 'KP -'
    case GLFW_KEY_KP_ADD: return 'KP +'
    case GLFW_KEY_KP_ENTER: return 'KP Enter'
    case GLFW_KEY_KP_EQUAL: return 'KP ='
  }
  return 'Key #' + code.toString()
}

/**
 * 虚拟按键"框内短标签"——UI 重构 2026-05-30。
 *
 * 与 glfwKeyName 的区别：glfwKeyName 面向改键列表（要清晰、可长），keyShortLabel
 * 面向"正方形按键框内显示一个字母/短词"，所以更短、更符合按键帽观感：
 *   - 鼠标左键 → "左"，右键 → "右"，中键 → "中"，其余 → "侧4/侧5"
 *   - 字母 / 数字 → 该字符（"E" / "1"）
 *   - Space / Shift / Ctrl / Alt / Tab / Enter / Esc → 短词（去掉 L/R 前缀）
 *   - 其余键回退 glfwKeyName（F3 / Home / ↑ 等本身已够短）
 */
export function keyShortLabel(code: number): string {
  if (isMouseCode(code)) {
    const b = decodeMouse(code)
    if (b === GLFW_MOUSE_BUTTON_LEFT) return '左'
    if (b === GLFW_MOUSE_BUTTON_RIGHT) return '右'
    if (b === GLFW_MOUSE_BUTTON_MIDDLE) return '中'
    return '侧' + (b + 1).toString()
  }
  // 字母 / 数字直接显示该字符
  if (code >= GLFW_KEY_A && code <= GLFW_KEY_Z) return String.fromCharCode(code)
  if (code >= GLFW_KEY_0 && code <= GLFW_KEY_9) return String.fromCharCode(code)
  switch (code) {
    case GLFW_KEY_SPACE: return 'Space'
    case GLFW_KEY_LEFT_SHIFT:
    case GLFW_KEY_RIGHT_SHIFT: return 'Shift'
    case GLFW_KEY_LEFT_CONTROL:
    case GLFW_KEY_RIGHT_CONTROL: return 'Ctrl'
    case GLFW_KEY_LEFT_ALT:
    case GLFW_KEY_RIGHT_ALT: return 'Alt'
    case GLFW_KEY_LEFT_SUPER:
    case GLFW_KEY_RIGHT_SUPER: return 'Super'
    case GLFW_KEY_TAB: return 'Tab'
    case GLFW_KEY_ENTER: return 'Enter'
    case GLFW_KEY_ESCAPE: return 'Esc'
    case GLFW_KEY_BACKSPACE: return '⌫'
    case GLFW_KEY_UP: return '↑'
    case GLFW_KEY_DOWN: return '↓'
    case GLFW_KEY_LEFT: return '←'
    case GLFW_KEY_RIGHT: return '→'
    default: return glfwKeyName(code)
  }
}

/**
 * 改键 UI 选项分组（每组 = 一个 Tab 或 Section）。
 * UI 直接遍历这个数组渲染按钮列表。
 */
export interface KeyOption {
  code: number
  name: string
}

export interface KeyGroup {
  title: string
  options: KeyOption[]
}

function opt(code: number): KeyOption {
  return { code: code, name: glfwKeyName(code) }
}

export function getKeyOptionGroups(): KeyGroup[] {
  return [
    {
      title: '鼠标',
      options: [
        opt(encodeMouse(GLFW_MOUSE_BUTTON_LEFT)),
        opt(encodeMouse(GLFW_MOUSE_BUTTON_RIGHT)),
        opt(encodeMouse(GLFW_MOUSE_BUTTON_MIDDLE)),
        opt(encodeMouse(GLFW_MOUSE_BUTTON_4)),
        opt(encodeMouse(GLFW_MOUSE_BUTTON_5)),
      ]
    },
    {
      title: '字母',
      options: [
        opt(GLFW_KEY_A), opt(GLFW_KEY_B), opt(GLFW_KEY_C), opt(GLFW_KEY_D),
        opt(GLFW_KEY_E), opt(GLFW_KEY_F), opt(GLFW_KEY_G), opt(GLFW_KEY_H),
        opt(GLFW_KEY_I), opt(GLFW_KEY_J), opt(GLFW_KEY_K), opt(GLFW_KEY_L),
        opt(GLFW_KEY_M), opt(GLFW_KEY_N), opt(GLFW_KEY_O), opt(GLFW_KEY_P),
        opt(GLFW_KEY_Q), opt(GLFW_KEY_R), opt(GLFW_KEY_S), opt(GLFW_KEY_T),
        opt(GLFW_KEY_U), opt(GLFW_KEY_V), opt(GLFW_KEY_W), opt(GLFW_KEY_X),
        opt(GLFW_KEY_Y), opt(GLFW_KEY_Z),
      ]
    },
    {
      title: '数字',
      options: [
        opt(GLFW_KEY_0), opt(GLFW_KEY_1), opt(GLFW_KEY_2), opt(GLFW_KEY_3),
        opt(GLFW_KEY_4), opt(GLFW_KEY_5), opt(GLFW_KEY_6), opt(GLFW_KEY_7),
        opt(GLFW_KEY_8), opt(GLFW_KEY_9),
      ]
    },
    {
      title: 'F 键',
      options: [
        opt(GLFW_KEY_F1), opt(GLFW_KEY_F2), opt(GLFW_KEY_F3), opt(GLFW_KEY_F4),
        opt(GLFW_KEY_F5), opt(GLFW_KEY_F6), opt(GLFW_KEY_F7), opt(GLFW_KEY_F8),
        opt(GLFW_KEY_F9), opt(GLFW_KEY_F10), opt(GLFW_KEY_F11), opt(GLFW_KEY_F12),
        opt(GLFW_KEY_F13), opt(GLFW_KEY_F14), opt(GLFW_KEY_F15), opt(GLFW_KEY_F16),
        opt(GLFW_KEY_F17), opt(GLFW_KEY_F18), opt(GLFW_KEY_F19), opt(GLFW_KEY_F20),
        opt(GLFW_KEY_F21), opt(GLFW_KEY_F22), opt(GLFW_KEY_F23), opt(GLFW_KEY_F24),
        opt(GLFW_KEY_F25),
      ]
    },
    {
      title: '修饰',
      options: [
        opt(GLFW_KEY_LEFT_SHIFT), opt(GLFW_KEY_RIGHT_SHIFT),
        opt(GLFW_KEY_LEFT_CONTROL), opt(GLFW_KEY_RIGHT_CONTROL),
        opt(GLFW_KEY_LEFT_ALT), opt(GLFW_KEY_RIGHT_ALT),
        opt(GLFW_KEY_LEFT_SUPER), opt(GLFW_KEY_RIGHT_SUPER),
      ]
    },
    {
      title: '导航',
      options: [
        opt(GLFW_KEY_UP), opt(GLFW_KEY_DOWN), opt(GLFW_KEY_LEFT), opt(GLFW_KEY_RIGHT),
        opt(GLFW_KEY_HOME), opt(GLFW_KEY_END),
        opt(GLFW_KEY_PAGE_UP), opt(GLFW_KEY_PAGE_DOWN),
        opt(GLFW_KEY_INSERT), opt(GLFW_KEY_DELETE),
      ]
    },
    {
      title: '杂项',
      options: [
        opt(GLFW_KEY_SPACE), opt(GLFW_KEY_TAB),
        opt(GLFW_KEY_ENTER), opt(GLFW_KEY_BACKSPACE),
        opt(GLFW_KEY_ESCAPE),
        opt(GLFW_KEY_GRAVE_ACCENT),
        opt(GLFW_KEY_MINUS), opt(GLFW_KEY_EQUAL),
        opt(GLFW_KEY_LEFT_BRACKET), opt(GLFW_KEY_RIGHT_BRACKET),
        opt(GLFW_KEY_BACKSLASH), opt(GLFW_KEY_SEMICOLON),
        opt(GLFW_KEY_APOSTROPHE), opt(GLFW_KEY_COMMA),
        opt(GLFW_KEY_PERIOD), opt(GLFW_KEY_SLASH),
        opt(GLFW_KEY_CAPS_LOCK), opt(GLFW_KEY_PRINT_SCREEN), opt(GLFW_KEY_PAUSE),
        opt(GLFW_KEY_SCROLL_LOCK), opt(GLFW_KEY_NUM_LOCK), opt(GLFW_KEY_MENU),
        opt(GLFW_KEY_WORLD_1), opt(GLFW_KEY_WORLD_2),
      ]
    },
    {
      title: '小键盘',
      options: [
        opt(GLFW_KEY_KP_0), opt(GLFW_KEY_KP_1), opt(GLFW_KEY_KP_2), opt(GLFW_KEY_KP_3),
        opt(GLFW_KEY_KP_4), opt(GLFW_KEY_KP_5), opt(GLFW_KEY_KP_6), opt(GLFW_KEY_KP_7),
        opt(GLFW_KEY_KP_8), opt(GLFW_KEY_KP_9),
        opt(GLFW_KEY_KP_DECIMAL), opt(GLFW_KEY_KP_DIVIDE), opt(GLFW_KEY_KP_MULTIPLY),
        opt(GLFW_KEY_KP_SUBTRACT), opt(GLFW_KEY_KP_ADD), opt(GLFW_KEY_KP_ENTER),
        opt(GLFW_KEY_KP_EQUAL),
      ]
    },
  ]
}

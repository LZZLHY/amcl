/**
 * KeyMap.ets — OHOS multimodalInput.keyCode → GLFW key code 映射表
 *
 * 2026-05-29 重构：OHOS keyCode 常量统一从 OhosKeyCodes.ets（SSOT）导入，不再在本文件
 * 私有硬编码。修复了此前的两个数值 bug：
 *   - F1–F12 段误用 2120+N（与 NUMPAD_EQUALS 撞码）→ 已改用 SDK 真值 2090+N
 *   - PageUp/Down 误用 2085/2086 → 已改用 SDK 真值 2068/2069
 * 详见 docs/guides/input-system-unified-direction-2026-05-29.md §一、§二（⚠️ 那份文档已**部分**
 * 过期，见它头部横幅：§2.2 关于「滚轮走 onAxisEvent」与「rawDelta 是原始 HID 增量」两句都已被
 * 真机否证；本文依赖的是它 §二 的 keyCode 真值，那部分仍成立）。当前输入契约以
 * docs/refactor/输入架构规范.md 为准。
 *
 * 本表只填业务会用到的常用键（约 100 个）；罕见键（媒体控制 / 多语言键等）不映射，
 * glfwKeyFromOhos 返回 0，调用方应做容错（key=0 时跳过 sendKeyEvent）。
 */

import {
  GLFW_KEY_SPACE, GLFW_KEY_APOSTROPHE, GLFW_KEY_COMMA, GLFW_KEY_MINUS,
  GLFW_KEY_PERIOD, GLFW_KEY_SLASH, GLFW_KEY_SEMICOLON, GLFW_KEY_EQUAL,
  GLFW_KEY_0, GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3, GLFW_KEY_4, GLFW_KEY_5,
  GLFW_KEY_6, GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9,
  GLFW_KEY_A, GLFW_KEY_B, GLFW_KEY_C, GLFW_KEY_D, GLFW_KEY_E, GLFW_KEY_F,
  GLFW_KEY_G, GLFW_KEY_H, GLFW_KEY_I, GLFW_KEY_J, GLFW_KEY_K, GLFW_KEY_L,
  GLFW_KEY_M, GLFW_KEY_N, GLFW_KEY_O, GLFW_KEY_P, GLFW_KEY_Q, GLFW_KEY_R,
  GLFW_KEY_S, GLFW_KEY_T, GLFW_KEY_U, GLFW_KEY_V, GLFW_KEY_W, GLFW_KEY_X,
  GLFW_KEY_Y, GLFW_KEY_Z,
  GLFW_KEY_LEFT_BRACKET, GLFW_KEY_BACKSLASH, GLFW_KEY_RIGHT_BRACKET,
  GLFW_KEY_GRAVE_ACCENT,
  GLFW_KEY_ESCAPE, GLFW_KEY_ENTER, GLFW_KEY_TAB, GLFW_KEY_BACKSPACE,
  GLFW_KEY_INSERT, GLFW_KEY_DELETE,
  GLFW_KEY_RIGHT, GLFW_KEY_LEFT, GLFW_KEY_DOWN, GLFW_KEY_UP,
  GLFW_KEY_PAGE_UP, GLFW_KEY_PAGE_DOWN, GLFW_KEY_HOME, GLFW_KEY_END,
  GLFW_KEY_CAPS_LOCK, GLFW_KEY_SCROLL_LOCK, GLFW_KEY_NUM_LOCK,
  GLFW_KEY_PRINT_SCREEN, GLFW_KEY_PAUSE,
  GLFW_KEY_F1, GLFW_KEY_F2, GLFW_KEY_F3, GLFW_KEY_F4, GLFW_KEY_F5,
  GLFW_KEY_F6, GLFW_KEY_F7, GLFW_KEY_F8, GLFW_KEY_F9, GLFW_KEY_F10,
  GLFW_KEY_F11, GLFW_KEY_F12,
  GLFW_KEY_KP_0, GLFW_KEY_KP_1, GLFW_KEY_KP_2, GLFW_KEY_KP_3, GLFW_KEY_KP_4,
  GLFW_KEY_KP_5, GLFW_KEY_KP_6, GLFW_KEY_KP_7, GLFW_KEY_KP_8, GLFW_KEY_KP_9,
  GLFW_KEY_KP_DECIMAL, GLFW_KEY_KP_DIVIDE, GLFW_KEY_KP_MULTIPLY,
  GLFW_KEY_KP_SUBTRACT, GLFW_KEY_KP_ADD, GLFW_KEY_KP_ENTER, GLFW_KEY_KP_EQUAL,
  GLFW_KEY_LEFT_SHIFT, GLFW_KEY_LEFT_CONTROL, GLFW_KEY_LEFT_ALT, GLFW_KEY_LEFT_SUPER,
  GLFW_KEY_RIGHT_SHIFT, GLFW_KEY_RIGHT_CONTROL, GLFW_KEY_RIGHT_ALT, GLFW_KEY_RIGHT_SUPER,
  GLFW_KEY_MENU,
  GLFW_MOD_SHIFT, GLFW_MOD_CONTROL, GLFW_MOD_ALT, GLFW_MOD_SUPER,
  GLFW_MOD_CAPS_LOCK, GLFW_MOD_NUM_LOCK
} from './GlfwKeys';

// OHOS keyCode 常量统一从 OhosKeyCodes.ets（SSOT）导入。
// 这里用本地别名（OHOS_KEYCODE_* = 导入的 OHOS_*）保持下方 switch/逻辑不改动，
// 同时让数值只在 OhosKeyCodes.ets 一处维护。
import {
  OHOS_NUM_0, OHOS_NUM_9, OHOS_A, OHOS_Z,
  OHOS_DPAD_UP, OHOS_DPAD_DOWN, OHOS_DPAD_LEFT, OHOS_DPAD_RIGHT, OHOS_DPAD_CENTER,
  OHOS_COMMA, OHOS_PERIOD, OHOS_ALT_LEFT, OHOS_ALT_RIGHT, OHOS_SHIFT_LEFT, OHOS_SHIFT_RIGHT,
  OHOS_TAB, OHOS_SPACE, OHOS_ENTER, OHOS_DEL, OHOS_GRAVE, OHOS_MINUS, OHOS_EQUALS,
  OHOS_LEFT_BRACKET, OHOS_RIGHT_BRACKET, OHOS_BACKSLASH, OHOS_SEMICOLON, OHOS_APOSTROPHE,
  OHOS_SLASH, OHOS_MENU, OHOS_PAGE_UP, OHOS_PAGE_DOWN, OHOS_ESCAPE, OHOS_FORWARD_DEL,
  OHOS_CTRL_LEFT, OHOS_CTRL_RIGHT, OHOS_CAPS_LOCK, OHOS_SCROLL_LOCK,
  OHOS_META_LEFT, OHOS_META_RIGHT, OHOS_SYSRQ, OHOS_BREAK,
  OHOS_MOVE_HOME, OHOS_MOVE_END, OHOS_INSERT,
  OHOS_F1, OHOS_F12, OHOS_NUM_LOCK, OHOS_NUMPAD_0, OHOS_NUMPAD_9,
  OHOS_NUMPAD_DIVIDE, OHOS_NUMPAD_MULTIPLY, OHOS_NUMPAD_SUBTRACT, OHOS_NUMPAD_ADD,
  OHOS_NUMPAD_DOT, OHOS_NUMPAD_ENTER, OHOS_NUMPAD_EQUALS
} from './OhosKeyCodes'

const OHOS_KEYCODE_DPAD_UP = OHOS_DPAD_UP
const OHOS_KEYCODE_DPAD_DOWN = OHOS_DPAD_DOWN
const OHOS_KEYCODE_DPAD_LEFT = OHOS_DPAD_LEFT
const OHOS_KEYCODE_DPAD_RIGHT = OHOS_DPAD_RIGHT
const OHOS_KEYCODE_DPAD_CENTER = OHOS_DPAD_CENTER
const OHOS_KEYCODE_A = OHOS_A
const OHOS_KEYCODE_Z = OHOS_Z
const OHOS_KEYCODE_COMMA = OHOS_COMMA
const OHOS_KEYCODE_PERIOD = OHOS_PERIOD
const OHOS_KEYCODE_ALT_LEFT = OHOS_ALT_LEFT
const OHOS_KEYCODE_ALT_RIGHT = OHOS_ALT_RIGHT
const OHOS_KEYCODE_SHIFT_LEFT = OHOS_SHIFT_LEFT
const OHOS_KEYCODE_SHIFT_RIGHT = OHOS_SHIFT_RIGHT
const OHOS_KEYCODE_TAB = OHOS_TAB
const OHOS_KEYCODE_SPACE = OHOS_SPACE
const OHOS_KEYCODE_ENTER = OHOS_ENTER
const OHOS_KEYCODE_DEL = OHOS_DEL              // Backspace
const OHOS_KEYCODE_GRAVE = OHOS_GRAVE
const OHOS_KEYCODE_MINUS = OHOS_MINUS
const OHOS_KEYCODE_EQUALS = OHOS_EQUALS
const OHOS_KEYCODE_LEFT_BRACKET = OHOS_LEFT_BRACKET
const OHOS_KEYCODE_RIGHT_BRACKET = OHOS_RIGHT_BRACKET
const OHOS_KEYCODE_BACKSLASH = OHOS_BACKSLASH
const OHOS_KEYCODE_SEMICOLON = OHOS_SEMICOLON
const OHOS_KEYCODE_APOSTROPHE = OHOS_APOSTROPHE
const OHOS_KEYCODE_SLASH = OHOS_SLASH
const OHOS_KEYCODE_NUM_0 = OHOS_NUM_0
const OHOS_KEYCODE_NUM_9 = OHOS_NUM_9
const OHOS_KEYCODE_ESCAPE = OHOS_ESCAPE
const OHOS_KEYCODE_FORWARD_DEL = OHOS_FORWARD_DEL     // Delete
const OHOS_KEYCODE_CTRL_LEFT = OHOS_CTRL_LEFT
const OHOS_KEYCODE_CTRL_RIGHT = OHOS_CTRL_RIGHT
const OHOS_KEYCODE_CAPS_LOCK = OHOS_CAPS_LOCK
const OHOS_KEYCODE_SCROLL_LOCK = OHOS_SCROLL_LOCK
const OHOS_KEYCODE_META_LEFT = OHOS_META_LEFT       // Super / Win
const OHOS_KEYCODE_META_RIGHT = OHOS_META_RIGHT
const OHOS_KEYCODE_SYSRQ = OHOS_SYSRQ           // Print Screen
const OHOS_KEYCODE_BREAK = OHOS_BREAK           // Pause
const OHOS_KEYCODE_MOVE_HOME = OHOS_MOVE_HOME
const OHOS_KEYCODE_MOVE_END = OHOS_MOVE_END
const OHOS_KEYCODE_INSERT = OHOS_INSERT
const OHOS_KEYCODE_PAGE_UP = OHOS_PAGE_UP
const OHOS_KEYCODE_PAGE_DOWN = OHOS_PAGE_DOWN
const OHOS_KEYCODE_NUM_LOCK = OHOS_NUM_LOCK
const OHOS_KEYCODE_NUMPAD_0 = OHOS_NUMPAD_0
const OHOS_KEYCODE_NUMPAD_9 = OHOS_NUMPAD_9
const OHOS_KEYCODE_NUMPAD_DIVIDE = OHOS_NUMPAD_DIVIDE
const OHOS_KEYCODE_NUMPAD_MULTIPLY = OHOS_NUMPAD_MULTIPLY
const OHOS_KEYCODE_NUMPAD_SUBTRACT = OHOS_NUMPAD_SUBTRACT
const OHOS_KEYCODE_NUMPAD_ADD = OHOS_NUMPAD_ADD
const OHOS_KEYCODE_NUMPAD_DOT = OHOS_NUMPAD_DOT
const OHOS_KEYCODE_NUMPAD_ENTER = OHOS_NUMPAD_ENTER
const OHOS_KEYCODE_NUMPAD_EQUALS = OHOS_NUMPAD_EQUALS
const OHOS_KEYCODE_F1 = OHOS_F1
const OHOS_KEYCODE_F12 = OHOS_F12
const OHOS_KEYCODE_MENU = OHOS_MENU

/**
 * 把 OHOS KeyCode 转成 GLFW key code。返回 0 表示不支持。
 *
 * OHOS keyCode 常量来自 OhosKeyCodes.ets（已对照本机 SDK 核对）。调用方仍应做容错
 * （key=0 时跳过 sendKeyEvent），覆盖未映射的罕见键。
 */
export function glfwKeyFromOhos(ohosKey: number): number {
  // 字母段连续：A=2017..Z=2042 → GLFW A=65..Z=90
  if (ohosKey >= OHOS_KEYCODE_A && ohosKey <= OHOS_KEYCODE_Z) {
    return GLFW_KEY_A + (ohosKey - OHOS_KEYCODE_A)
  }
  // 数字行：0=2000..9=2009 → GLFW 48..57
  if (ohosKey >= OHOS_KEYCODE_NUM_0 && ohosKey <= OHOS_KEYCODE_NUM_9) {
    return GLFW_KEY_0 + (ohosKey - OHOS_KEYCODE_NUM_0)
  }
  // F1..F12
  if (ohosKey >= OHOS_KEYCODE_F1 && ohosKey <= OHOS_KEYCODE_F12) {
    return GLFW_KEY_F1 + (ohosKey - OHOS_KEYCODE_F1)
  }
  // 小键盘 0..9
  if (ohosKey >= OHOS_KEYCODE_NUMPAD_0 && ohosKey <= OHOS_KEYCODE_NUMPAD_9) {
    return GLFW_KEY_KP_0 + (ohosKey - OHOS_KEYCODE_NUMPAD_0)
  }
  switch (ohosKey) {
    case OHOS_KEYCODE_DPAD_UP: return GLFW_KEY_UP
    case OHOS_KEYCODE_DPAD_DOWN: return GLFW_KEY_DOWN
    case OHOS_KEYCODE_DPAD_LEFT: return GLFW_KEY_LEFT
    case OHOS_KEYCODE_DPAD_RIGHT: return GLFW_KEY_RIGHT
    case OHOS_KEYCODE_DPAD_CENTER: return GLFW_KEY_ENTER
    case OHOS_KEYCODE_COMMA: return GLFW_KEY_COMMA
    case OHOS_KEYCODE_PERIOD: return GLFW_KEY_PERIOD
    case OHOS_KEYCODE_ALT_LEFT: return GLFW_KEY_LEFT_ALT
    case OHOS_KEYCODE_ALT_RIGHT: return GLFW_KEY_RIGHT_ALT
    case OHOS_KEYCODE_SHIFT_LEFT: return GLFW_KEY_LEFT_SHIFT
    case OHOS_KEYCODE_SHIFT_RIGHT: return GLFW_KEY_RIGHT_SHIFT
    case OHOS_KEYCODE_TAB: return GLFW_KEY_TAB
    case OHOS_KEYCODE_SPACE: return GLFW_KEY_SPACE
    case OHOS_KEYCODE_ENTER: return GLFW_KEY_ENTER
    case OHOS_KEYCODE_DEL: return GLFW_KEY_BACKSPACE
    case OHOS_KEYCODE_FORWARD_DEL: return GLFW_KEY_DELETE
    case OHOS_KEYCODE_GRAVE: return GLFW_KEY_GRAVE_ACCENT
    case OHOS_KEYCODE_MINUS: return GLFW_KEY_MINUS
    case OHOS_KEYCODE_EQUALS: return GLFW_KEY_EQUAL
    case OHOS_KEYCODE_LEFT_BRACKET: return GLFW_KEY_LEFT_BRACKET
    case OHOS_KEYCODE_RIGHT_BRACKET: return GLFW_KEY_RIGHT_BRACKET
    case OHOS_KEYCODE_BACKSLASH: return GLFW_KEY_BACKSLASH
    case OHOS_KEYCODE_SEMICOLON: return GLFW_KEY_SEMICOLON
    case OHOS_KEYCODE_APOSTROPHE: return GLFW_KEY_APOSTROPHE
    case OHOS_KEYCODE_SLASH: return GLFW_KEY_SLASH
    case OHOS_KEYCODE_ESCAPE: return GLFW_KEY_ESCAPE
    case OHOS_KEYCODE_CTRL_LEFT: return GLFW_KEY_LEFT_CONTROL
    case OHOS_KEYCODE_CTRL_RIGHT: return GLFW_KEY_RIGHT_CONTROL
    case OHOS_KEYCODE_CAPS_LOCK: return GLFW_KEY_CAPS_LOCK
    case OHOS_KEYCODE_SCROLL_LOCK: return GLFW_KEY_SCROLL_LOCK
    case OHOS_KEYCODE_NUM_LOCK: return GLFW_KEY_NUM_LOCK
    case OHOS_KEYCODE_META_LEFT: return GLFW_KEY_LEFT_SUPER
    case OHOS_KEYCODE_META_RIGHT: return GLFW_KEY_RIGHT_SUPER
    case OHOS_KEYCODE_SYSRQ: return GLFW_KEY_PRINT_SCREEN
    case OHOS_KEYCODE_BREAK: return GLFW_KEY_PAUSE
    case OHOS_KEYCODE_MOVE_HOME: return GLFW_KEY_HOME
    case OHOS_KEYCODE_MOVE_END: return GLFW_KEY_END
    case OHOS_KEYCODE_INSERT: return GLFW_KEY_INSERT
    case OHOS_KEYCODE_PAGE_UP: return GLFW_KEY_PAGE_UP
    case OHOS_KEYCODE_PAGE_DOWN: return GLFW_KEY_PAGE_DOWN
    case OHOS_KEYCODE_NUMPAD_DIVIDE: return GLFW_KEY_KP_DIVIDE
    case OHOS_KEYCODE_NUMPAD_MULTIPLY: return GLFW_KEY_KP_MULTIPLY
    case OHOS_KEYCODE_NUMPAD_SUBTRACT: return GLFW_KEY_KP_SUBTRACT
    case OHOS_KEYCODE_NUMPAD_ADD: return GLFW_KEY_KP_ADD
    case OHOS_KEYCODE_NUMPAD_DOT: return GLFW_KEY_KP_DECIMAL
    case OHOS_KEYCODE_NUMPAD_ENTER: return GLFW_KEY_KP_ENTER
    case OHOS_KEYCODE_NUMPAD_EQUALS: return GLFW_KEY_KP_EQUAL
    case OHOS_KEYCODE_MENU: return GLFW_KEY_MENU
    default:
      return 0
  }
}

// ============================================================
// 平台锁存快照（lockState）——与 native ABI 位对位镜像
//
// 唯一真相在 entry/src/main/cpp/input/amcl_input_event.h 的
// AMCL_INPUT_LOCK_STATE_*。两处必须同时修改；新增锁存位只能追加到 MASK 内，禁止改号。
//
// 为什么需要 VALID 位：0 无法区分"平台报告三个锁存都关"和"这台设备/这版 SDK
// 根本没报告锁存"。少了这个区分，消费方只能靠"锁存键是否按住"来猜，而这正是
// 重构计划 §5.2 / §10.1 明确禁止的（Caps/Num/Scroll 是锁存量，不是按住量）。
//
// 为什么 VALID 在 bit 16 而不是 bit 0：native 的 physicalKeyTransaction 里
// `modifiers` 与 `locks` 是相邻的同型 uint32 参数，实参错位是现实可能的失误。
// GLFW modifier 只用到 bit 0..5（SHIFT 0x01 … NUM_LOCK 0x20），把 VALID 放到
// 它们之上，任何被误放进 locks 槽的 modifier 值都不可能声称"平台已回答"；
// 剩余情况由 native ingress 的 MASK 校验拒掉（超出 MASK 即降级为未知并计
// unsupported）。ArkTS 侧不做修复，只保证自己组装出的值合法。
// ============================================================

/** Caps Lock 处于锁定态。 */
export const AMCL_LOCK_STATE_CAPS: number = 1
/** Num Lock 处于锁定态。 */
export const AMCL_LOCK_STATE_NUM: number = 2
/** Scroll Lock 处于锁定态。 */
export const AMCL_LOCK_STATE_SCROLL: number = 4
/** 置位表示整个 lockState 快照来自平台，三个锁存位才有意义。= 1 << 16。 */
export const AMCL_LOCK_STATE_VALID: number = 65536

/**
 * 把 ArkUI `KeyEvent` 的三个可选锁存字段组装成 native lockState。
 *
 * 三个字段全为 undefined（旧 SDK / 该设备不上报）时返回 0，即"未知"，native trace
 * 会把它计入 MissingField::LockState。只要有任意一个字段存在，就置 VALID：此时
 * undefined 的那一项按"未锁定"处理，因为平台已经在回答这组状态了。
 *
 * 失败恢复：本函数不抛异常，也不读取任何外部状态；上层拿不到字段时传 undefined
 * 即可，绝不允许改成从 held 集合推断。
 */
export function composeOhosLockState(caps: boolean | undefined,
                                     num: boolean | undefined,
                                     scroll: boolean | undefined): number {
  if (caps === undefined && num === undefined && scroll === undefined) return 0
  let mask = AMCL_LOCK_STATE_VALID
  if (caps === true) mask |= AMCL_LOCK_STATE_CAPS
  if (num === true) mask |= AMCL_LOCK_STATE_NUM
  if (scroll === true) mask |= AMCL_LOCK_STATE_SCROLL
  return mask
}

/**
 * 只从 held 集合推导"按住即生效"的 4 个修饰键（Shift/Ctrl/Alt/Super）。
 *
 * 锁存键**不在**此列：Caps/Num/Scroll 的语义是锁定态，按住与否与锁定与否无关。
 * 调用方应改用 composeGlfwMods() 让锁存位来自平台快照。
 */
export function computeGlfwHeldMods(activeOhosKeys: Set<number>): number {
  let mods = 0
  if (activeOhosKeys.has(OHOS_KEYCODE_SHIFT_LEFT) || activeOhosKeys.has(OHOS_KEYCODE_SHIFT_RIGHT)) mods |= GLFW_MOD_SHIFT
  if (activeOhosKeys.has(OHOS_KEYCODE_CTRL_LEFT) || activeOhosKeys.has(OHOS_KEYCODE_CTRL_RIGHT)) mods |= GLFW_MOD_CONTROL
  if (activeOhosKeys.has(OHOS_KEYCODE_ALT_LEFT) || activeOhosKeys.has(OHOS_KEYCODE_ALT_RIGHT)) mods |= GLFW_MOD_ALT
  if (activeOhosKeys.has(OHOS_KEYCODE_META_LEFT) || activeOhosKeys.has(OHOS_KEYCODE_META_RIGHT)) mods |= GLFW_MOD_SUPER
  return mods
}

/**
 * 最终 GLFW modifier 快照 = held 推导的 4 个按住型修饰键 + 锁存位。
 *
 * lockState 带 VALID 时锁存位完全来自平台，held 里是否按着 Caps/Num 不再影响结果。
 *
 * lockState 无 VALID 时执行**显式降级**：沿用旧的"按住 Caps/Num 就当锁定"推断。
 * 这条降级只为了让不上报锁存的设备保持既有可用性（MC 聊天框大小写），它明确违反
 * §5.2，适用条件是 `isCapsLockOn/isNumLockOn/isScrollLockOn` 全部缺失，删除阶段为
 * 计划 Phase 6（TextInputSession 接管文本路径后，US 布局硬算字符整条移除）。
 */
export function composeGlfwMods(activeOhosKeys: Set<number>, lockState: number): number {
  const mods = computeGlfwHeldMods(activeOhosKeys)
  if ((lockState & AMCL_LOCK_STATE_VALID) === 0) {
    let degraded = mods
    if (activeOhosKeys.has(OHOS_KEYCODE_CAPS_LOCK)) degraded |= GLFW_MOD_CAPS_LOCK
    if (activeOhosKeys.has(OHOS_KEYCODE_NUM_LOCK)) degraded |= GLFW_MOD_NUM_LOCK
    return degraded
  }
  let latched = mods
  if ((lockState & AMCL_LOCK_STATE_CAPS) !== 0) latched |= GLFW_MOD_CAPS_LOCK
  if ((lockState & AMCL_LOCK_STATE_NUM) !== 0) latched |= GLFW_MOD_NUM_LOCK
  return latched
}

/**
 * 兼容入口：等价于 composeGlfwMods(keys, 0)，即"平台未提供锁存快照"的降级分支。
 *
 * 保留原因：手柄/虚拟按键等合成输入源没有平台锁存快照可用。实体键盘路径必须改用
 * composeGlfwMods()，不要新增本函数的调用点。
 */
export function computeGlfwMods(activeOhosKeys: Set<number>): number {
  return composeGlfwMods(activeOhosKeys, 0)
}

/**
 * 判断给定 OHOS KeyCode 是否对应一个"可打印字符"，需要同时发 sendCharEvent。
 * 仅用于 normal 模式 / IME 关闭场景的简易回灌；中文等多 codepoint 输入应通过 IME。
 *
 * 这里只覆盖 ASCII 可打印（基于 OHOS 文档里的 KeyEvent.unicodeChar 兜底）。
 */
export function isPrintableOhosKey(ohosKey: number): boolean {
  if (ohosKey >= OHOS_KEYCODE_A && ohosKey <= OHOS_KEYCODE_Z) return true
  if (ohosKey >= OHOS_KEYCODE_NUM_0 && ohosKey <= OHOS_KEYCODE_NUM_9) return true
  switch (ohosKey) {
    case OHOS_KEYCODE_SPACE:
    case OHOS_KEYCODE_COMMA:
    case OHOS_KEYCODE_PERIOD:
    case OHOS_KEYCODE_MINUS:
    case OHOS_KEYCODE_EQUALS:
    case OHOS_KEYCODE_LEFT_BRACKET:
    case OHOS_KEYCODE_RIGHT_BRACKET:
    case OHOS_KEYCODE_BACKSLASH:
    case OHOS_KEYCODE_SEMICOLON:
    case OHOS_KEYCODE_APOSTROPHE:
    case OHOS_KEYCODE_SLASH:
    case OHOS_KEYCODE_GRAVE:
      return true
    default:
      return false
  }
}

/**
 * 将 OHOS KeyCode + 当前 mods 计算可打印字符的 codepoint。
 * 没考虑国际化键盘，仅做 US 布局的最小可用版本（够 MC 聊天框使用）。
 */
export function ohosKeyToCodepoint(ohosKey: number, mods: number): number {
  const shift = (mods & GLFW_MOD_SHIFT) !== 0
  const caps = (mods & GLFW_MOD_CAPS_LOCK) !== 0
  // 字母
  if (ohosKey >= OHOS_KEYCODE_A && ohosKey <= OHOS_KEYCODE_Z) {
    const baseLower = 'a'.charCodeAt(0) + (ohosKey - OHOS_KEYCODE_A)
    const upper = (shift !== caps)  // XOR：shift 与 caps 相反时大写
    return upper ? (baseLower - 32) : baseLower
  }
  // 数字 + shift 符号
  if (ohosKey >= OHOS_KEYCODE_NUM_0 && ohosKey <= OHOS_KEYCODE_NUM_9) {
    const n = ohosKey - OHOS_KEYCODE_NUM_0
    if (!shift) {
      return '0'.charCodeAt(0) + n
    }
    // shift + 数字 = 美式键盘的符号
    const symbols = ')!@#$%^&*('
    return symbols.charCodeAt(n)
  }
  switch (ohosKey) {
    case OHOS_KEYCODE_SPACE: return 0x20
    case OHOS_KEYCODE_COMMA: return shift ? '<'.charCodeAt(0) : ','.charCodeAt(0)
    case OHOS_KEYCODE_PERIOD: return shift ? '>'.charCodeAt(0) : '.'.charCodeAt(0)
    case OHOS_KEYCODE_MINUS: return shift ? '_'.charCodeAt(0) : '-'.charCodeAt(0)
    case OHOS_KEYCODE_EQUALS: return shift ? '+'.charCodeAt(0) : '='.charCodeAt(0)
    case OHOS_KEYCODE_LEFT_BRACKET: return shift ? '{'.charCodeAt(0) : '['.charCodeAt(0)
    case OHOS_KEYCODE_RIGHT_BRACKET: return shift ? '}'.charCodeAt(0) : ']'.charCodeAt(0)
    case OHOS_KEYCODE_BACKSLASH: return shift ? '|'.charCodeAt(0) : '\\'.charCodeAt(0)
    case OHOS_KEYCODE_SEMICOLON: return shift ? ':'.charCodeAt(0) : ';'.charCodeAt(0)
    case OHOS_KEYCODE_APOSTROPHE: return shift ? '"'.charCodeAt(0) : '\''.charCodeAt(0)
    case OHOS_KEYCODE_SLASH: return shift ? '?'.charCodeAt(0) : '/'.charCodeAt(0)
    case OHOS_KEYCODE_GRAVE: return shift ? '~'.charCodeAt(0) : '`'.charCodeAt(0)
    default:
      return 0
  }
}

/**
 * 平台给出的码位能否直接进入 GLFW char 通道。
 *
 * ArkUI KeyEvent.unicode（API14+）比 US 键位表更接近实体键盘当前布局；API24 文档
 * 只承诺 U+0021..U+007E，但这里按完整 Unicode scalar 校验，为 API26/后续扩展保留
 * 正确边界。C0/C1 控制字符、DEL、surrogate 与越界值一律拒绝。
 */
export function isPrintableUnicodeCodepoint(codepoint: number | undefined): boolean {
  if (codepoint === undefined || !Number.isFinite(codepoint)) return false
  const cp: number = Math.trunc(codepoint)
  if (cp !== codepoint || cp < 0x20 || cp > 0x10FFFF) return false
  if (cp === 0x7F || (cp >= 0x80 && cp <= 0x9F)) return false
  return cp < 0xD800 || cp > 0xDFFF
}

/**
 * 实体键盘字符的单一解析入口：平台布局码位优先，US KeyCode 表仅作旧 API/空值兜底。
 * 该结果与 GLFW key 映射正交；未映射物理键仍可合法地产生 char。
 */
export function resolvePhysicalKeyCodepoint(
  platformUnicode: number | undefined, ohosKey: number, mods: number
): number {
  if (isPrintableUnicodeCodepoint(platformUnicode)) {
    return Math.trunc(platformUnicode as number)
  }
  return ohosKeyToCodepoint(ohosKey, mods)
}

// ⚠️ 墓碑: `glfwMouseFromOhos` 已删除（2026-09-01）。**不要再加回来。**
// 它断言 ArkUI `MouseButton` 是**顺序值**（Middle=3），而在役的
// `handleMouseEvent` 断言它是**位掩码**（Middle=4）并原样传给 native ——
// 两者不可能同时正确，而位掩码那侧记录着一次已修复的真实故障且经过真机验收。
// 本函数从那次修复起就是死代码（全仓零读者）⇒ 它唯一的作用是给下一个人一段
// **自信、具体、且错误**的规格说明。因果见计划 §107.7。
// ⇒ 要处理鼠标按钮：**不要在 ArkTS 侧映射**，原样传掩码给 native 统一 fail-closed。

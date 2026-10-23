/**
 * Minecraft options.txt 到专用触控动作的纯解析。
 *
 * 支持旧 LWJGL2 数字键码和新 key.keyboard/key.mouse 名字。只读配置，不改写游戏文件；
 * 不可识别的值保留该动作的默认绑定并登记动作名，显式 unbound 则输出 0（不得回退成别的键）。
 * keys 下标与 native touch_interaction.h 的 TouchAction 相同，发布时作为完整 schema 快照原子替换。
 */
export const TOUCH_ACTION_NAMES: string[] = [
  'forward', 'left', 'back', 'right', 'sprint', 'swapOffhand', 'drop',
  'hotbar.1', 'hotbar.2', 'hotbar.3', 'hotbar.4', 'hotbar.5', 'hotbar.6', 'hotbar.7', 'hotbar.8', 'hotbar.9',
  'attack', 'use'
]
/** 与动作顺序一起维护，供编辑器选择语义动作；用户不需要理解底层键码。 */
export const TOUCH_ACTION_LABELS: string[] = [
  '前进','左移','后退','右移','疾跑','交换副手','丢弃',
  '快捷栏1','快捷栏2','快捷栏3','快捷栏4','快捷栏5','快捷栏6','快捷栏7','快捷栏8','快捷栏9','攻击','使用物品'
]

/** 专用控件的默认键；普通可编辑按钮不经过此表，仍尊重用户自己的 keys。 */
export function defaultTouchActionKeys(): number[] {
  return [87, 65, 83, 68, 341, 70, 81, 49, 50, 51, 52, 53, 54, 55, 56, 57, -1, -2]
}

/** 独立结果对象，不持有 options 原文；unsupported 仅含动作名，可用于提示而不泄露实例内容。 */
export class TouchBindingSnapshot {
  keys: number[] = defaultTouchActionKeys()
  unsupported: string[] = []
}

/** LWJGL2 Keyboard 的旧扫描码，取值显式列出，不能把它当作 GLFW 键码直接发送。 */
const LEGACY_TOUCH_KEYS: Record<string, number> = {
  '1': 256, '2': 49, '3': 50, '4': 51, '5': 52, '6': 53, '7': 54, '8': 55, '9': 56, '10': 57, '11': 48,
  '12': 45, '13': 61, '14': 259, '15': 258, '16': 81, '17': 87, '18': 69, '19': 82, '20': 84,
  '21': 89, '22': 85, '23': 73, '24': 79, '25': 80, '26': 91, '27': 93, '28': 257, '29': 341,
  '30': 65, '31': 83, '32': 68, '33': 70, '34': 71, '35': 72, '36': 74, '37': 75, '38': 76,
  '39': 59, '40': 39, '41': 96, '42': 340, '43': 92, '44': 90, '45': 88, '46': 67, '47': 86,
  '48': 66, '49': 78, '50': 77, '51': 44, '52': 46, '53': 47, '54': 344, '55': 332, '56': 342,
  '57': 32, '58': 280, '69': 282, '70': 281, '71': 327, '72': 328, '73': 329, '74': 333,
  '75': 324, '76': 325, '77': 326, '78': 334, '79': 321, '80': 322, '81': 323, '82': 320,
  '83': 330, '87': 300, '88': 301, '156': 335, '157': 345, '181': 331, '184': 346,
  '199': 268, '200': 265, '201': 266, '203': 263, '205': 262, '207': 269, '208': 264, '209': 267,
  '210': 260, '211': 261, '219': 343, '220': 347, '221': 348
}

/** 新版 GLFW 名字；字母、数字、F 键与小键盘数字在下面按范围处理。 */
const NAMED_TOUCH_KEYS: Record<string, number> = {
  'space': 32, 'escape': 256, 'enter': 257, 'tab': 258, 'backspace': 259,
  'insert': 260, 'delete': 261, 'right': 262, 'left': 263, 'down': 264, 'up': 265,
  'page.up': 266, 'page.down': 267, 'home': 268, 'end': 269, 'caps.lock': 280,
  'scroll.lock': 281, 'num.lock': 282, 'print.screen': 283, 'pause': 284,
  'left.shift': 340, 'left.control': 341, 'left.alt': 342, 'left.win': 343,
  'right.shift': 344, 'right.control': 345, 'right.alt': 346, 'right.win': 347, 'menu': 348,
  'apostrophe': 39, 'comma': 44, 'minus': 45, 'period': 46, 'slash': 47, 'semicolon': 59,
  'equal': 61, 'left.bracket': 91, 'backslash': 92, 'right.bracket': 93, 'grave.accent': 96,
  'keypad.decimal': 330, 'keypad.divide': 331, 'keypad.multiply': 332, 'keypad.subtract': 333,
  'keypad.add': 334, 'keypad.enter': 335, 'keypad.equal': 336
}

/** undefined 表示未知格式；0 表示玩家明确解除绑定；负数沿用项目的鼠标按钮编码。 */
export function parseMinecraftTouchKey(raw: string): number | undefined {
  const value: string = raw.trim().toLowerCase()
  if (value === 'key.keyboard.unknown' || value === 'key.unknown' || value === '0') return 0
  if (value.startsWith('key.mouse.')) {
    const button: string = value.substring(10)
    if (button === 'left') return -1
    if (button === 'right') return -2
    if (button === 'middle') return -3
    if (new RegExp('^[0-9]+$').test(button)) {
      const number: number = Number(button)
      if (number >= 1 && number <= 16) return -number
    }
    return undefined
  }
  if (value.startsWith('key.keyboard.')) {
    const key: string = value.substring(13)
    if (key.length === 1 && new RegExp('^[a-z0-9]$').test(key)) return key.toUpperCase().charCodeAt(0)
    if (new RegExp('^f([1-9]|1[0-9]|2[0-5])$').test(key)) return 289 + Number(key.substring(1))
    if (new RegExp('^keypad\\.[0-9]$').test(key)) return 320 + Number(key.substring(7))
    return NAMED_TOUCH_KEYS[key]
  }
  if (!new RegExp('^-?[0-9]+$').test(value)) return undefined
  const legacy: number = Number(value)
  if (!Number.isSafeInteger(legacy)) return undefined
  if (legacy >= -100 && legacy <= -85) return -(legacy + 101)
  if (legacy >= 59 && legacy <= 68) return 290 + legacy - 59
  return LEGACY_TOUCH_KEYS[value]
}

/**
 * 解析一份有限大小的配置。只接受已知动作，重复定义按游戏配置的最后一行生效。
 * 上层在活动实例变更/菜单回到游戏时重读；返回的数组必须随 schema 发布，不能在 UP 时临时查询。
 */
export function parseTouchActionBindings(text: string, enabled: boolean = true): TouchBindingSnapshot {
  const result = new TouchBindingSnapshot()
  if (!enabled || text.length > 1048576) return result
  const values: Record<string, string> = {}
  const lines: string[] = text.split('\n')
  for (let i = 0; i < lines.length; i++) {
    const split: number = lines[i].indexOf(':')
    if (split <= 0) continue
    const key: string = lines[i].substring(0, split).trim()
    if (key.startsWith('key_key.')) values[key.substring(8)] = lines[i].substring(split + 1)
    else if (key.startsWith('key_')) values[key.substring(4)] = lines[i].substring(split + 1)
  }
  for (let i = 0; i < TOUCH_ACTION_NAMES.length; i++) {
    const name: string = TOUCH_ACTION_NAMES[i]
    const raw: string | undefined = name === 'swapOffhand' ? (values[name] ?? values['swapHands']) : values[name]
    if (raw === undefined) continue
    const code: number | undefined = parseMinecraftTouchKey(raw)
    if (code === undefined) result.unsupported.push(name)
    else result.keys[i] = code
  }
  return result
}

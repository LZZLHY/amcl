/**
 * OhosKeyCodes.ets — OHOS @ohos.multimodalInput.keyCode 常量的单一真相源（SSOT）
 *
 * 背景：此前 KeyMap.ets 与 GamepadMap.ets 各自硬编码了一份 OHOS keyCode，导致：
 *   - F1–F12 在 KeyMap 里被写成 2120+N（实际 2090+N），整段错位 → 物理 F 键失效
 *   - PageUp/Down 写成 2085/2086（实际 2068/2069）
 *   - 手柄 L1/R1/L2/R2/SELECT/START/MODE/THUMBL/THUMBR 在 GamepadMap 里全部偏移
 *   - 出现 SDK 不存在的 BUTTON_C / BUTTON_Z 死码
 *
 * 本文件所有数值**逐个对照本机 SDK** 核对：
 *   D:\Huawei\command-line-tools\sdk\default\openharmony\ets\api\@ohos.multimodalInput.keyCode.d.ts
 *
 * 这是叶子模块（无任何 import），KeyMap / GamepadManager 单向 import，不引入循环。
 * SDK 升级若改了数值，只需改这一处。
 *
 * 命名约定：去掉 SDK 的 KEYCODE_ 前缀，保留其余（如 KEYCODE_DPAD_UP → OHOS_DPAD_UP）。
 */

// ==================== 数字行 0-9（2000-2009） ====================
export const OHOS_NUM_0 = 2000
export const OHOS_NUM_1 = 2001
export const OHOS_NUM_2 = 2002
export const OHOS_NUM_3 = 2003
export const OHOS_NUM_4 = 2004
export const OHOS_NUM_5 = 2005
export const OHOS_NUM_6 = 2006
export const OHOS_NUM_7 = 2007
export const OHOS_NUM_8 = 2008
export const OHOS_NUM_9 = 2009

// ==================== 方向键 DPAD（2012-2016） ====================
export const OHOS_DPAD_UP = 2012
export const OHOS_DPAD_DOWN = 2013
export const OHOS_DPAD_LEFT = 2014
export const OHOS_DPAD_RIGHT = 2015
export const OHOS_DPAD_CENTER = 2016

// ==================== 字母 A-Z（2017-2042，连续） ====================
export const OHOS_A = 2017
export const OHOS_Z = 2042

// ==================== 标点 / 修饰 / 控制（2043-2083） ====================
export const OHOS_COMMA = 2043
export const OHOS_PERIOD = 2044
export const OHOS_ALT_LEFT = 2045
export const OHOS_ALT_RIGHT = 2046
export const OHOS_SHIFT_LEFT = 2047
export const OHOS_SHIFT_RIGHT = 2048
export const OHOS_TAB = 2049
export const OHOS_SPACE = 2050
export const OHOS_ENTER = 2054
export const OHOS_DEL = 2055              // Backspace
export const OHOS_GRAVE = 2056            // `
export const OHOS_MINUS = 2057
export const OHOS_EQUALS = 2058
export const OHOS_LEFT_BRACKET = 2059
export const OHOS_RIGHT_BRACKET = 2060
export const OHOS_BACKSLASH = 2061
export const OHOS_SEMICOLON = 2062
export const OHOS_APOSTROPHE = 2063
export const OHOS_SLASH = 2064
export const OHOS_MENU = 2067
export const OHOS_PAGE_UP = 2068          // 修正：旧 KeyMap 误写 2085
export const OHOS_PAGE_DOWN = 2069        // 修正：旧 KeyMap 误写 2086
export const OHOS_ESCAPE = 2070
export const OHOS_FORWARD_DEL = 2071      // Delete
export const OHOS_CTRL_LEFT = 2072
export const OHOS_CTRL_RIGHT = 2073
export const OHOS_CAPS_LOCK = 2074
export const OHOS_SCROLL_LOCK = 2075
export const OHOS_META_LEFT = 2076        // Super / Win
export const OHOS_META_RIGHT = 2077
export const OHOS_FUNCTION = 2078
export const OHOS_SYSRQ = 2079            // Print Screen
export const OHOS_BREAK = 2080            // Pause
export const OHOS_MOVE_HOME = 2081
export const OHOS_MOVE_END = 2082
export const OHOS_INSERT = 2083

// ==================== 功能键 F1-F12（2090-2101，连续） ====================
// 修正：旧 KeyMap 误用 2120+N（与 NUMPAD_EQUALS=2120 撞码，整段错位）
export const OHOS_F1 = 2090
export const OHOS_F12 = 2101

// ==================== 小键盘（2102-2120） ====================
export const OHOS_NUM_LOCK = 2102
export const OHOS_NUMPAD_0 = 2103
export const OHOS_NUMPAD_9 = 2112
export const OHOS_NUMPAD_DIVIDE = 2113
export const OHOS_NUMPAD_MULTIPLY = 2114
export const OHOS_NUMPAD_SUBTRACT = 2115
export const OHOS_NUMPAD_ADD = 2116
export const OHOS_NUMPAD_DOT = 2117
export const OHOS_NUMPAD_ENTER = 2119
export const OHOS_NUMPAD_EQUALS = 2120

// ==================== 游戏手柄按键（2301-2315） ====================
// 全部对照 SDK 修正（旧 GamepadMap 的值偏移）。SDK 无 BUTTON_C / BUTTON_Z。
export const OHOS_BUTTON_A = 2301
export const OHOS_BUTTON_B = 2302
export const OHOS_BUTTON_X = 2304
export const OHOS_BUTTON_Y = 2305
export const OHOS_BUTTON_L1 = 2307        // 修正：旧 2310
export const OHOS_BUTTON_R1 = 2308        // 修正：旧 2311
export const OHOS_BUTTON_L2 = 2309        // 修正：旧 2312
export const OHOS_BUTTON_R2 = 2310        // 修正：旧 2313
export const OHOS_BUTTON_SELECT = 2311    // 修正：旧 2320
export const OHOS_BUTTON_START = 2312     // 修正：旧 2321
export const OHOS_BUTTON_MODE = 2313      // 修正：旧 2322
export const OHOS_BUTTON_THUMBL = 2314    // L3，修正：旧 2317
export const OHOS_BUTTON_THUMBR = 2315    // R3，修正：旧 2318

// ==================== ArkUI MouseButton 枚举（注意：不是 multimodalInput 的） ====================
// 来源：component/enums.d.ts 的 MouseButton。与 GLFW 的映射是 (N-1)，None 丢弃。
export const ARKUI_MOUSE_NONE = 0
export const ARKUI_MOUSE_LEFT = 1
export const ARKUI_MOUSE_RIGHT = 2
export const ARKUI_MOUSE_MIDDLE = 3
export const ARKUI_MOUSE_BACK = 4
export const ARKUI_MOUSE_FORWARD = 5

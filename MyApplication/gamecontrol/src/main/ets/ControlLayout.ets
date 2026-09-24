/**
 * ControlLayout.ets — 按钮布局数据模型
 *
 * 定义每个虚拟按钮/摇杆的位置、大小、对齐组等信息。
 * 坐标系统：使用百分比（0~1）相对于屏幕宽高，保证不同分辨率适配。
 *
 * 版本演进（2026-05-28 input-system-refactor）：
 *   v1 → v2：
 *     - LayoutProfile 加 version / lookSensitivity / invertY / joystickDeadZone
 *               / haptic / targetDevice / isPreset
 *     - ControlItem 加 keys[] / modifiers / trigger / style / hidden / locked / children
 *     - ControlType 加 SCROLL_WHEEL / DRAWER
 *   旧字段（keyOrMouse / isCircle）保留不删，import / runtime 双向兼容；
 *   迁移逻辑由 LayoutStore.migrate() 在 import / load 时执行。
 */

// ==================== GLFW 键码（统一从 GlfwKeys 导入） ====================
//
// Phase 2（fix/input-system §P1-1 / §P1-2）：之前这里有一份私有 K_*/M_* 常量副本，
// 与 GlfwKeys.ets 是同一组数值的两份定义；新增/改值时容易漏一边。改成单向 import，
// GlfwKeys.ets 是叶子模块（无任何 import），不会引入循环。
//
// 鼠标按钮的负数编码统一走 encodeMouse(GLFW_MOUSE_BUTTON_*)，避免散落的 -(x+1)。
//
// ArkTS 严格模式（arkts-no-misplaced-imports）要求所有 import 必须在文件顶部，
// 不能放在 export const 之后。
import {
  GLFW_KEY_SPACE, GLFW_KEY_1, GLFW_KEY_E, GLFW_KEY_F, GLFW_KEY_Q, GLFW_KEY_T,
  GLFW_KEY_ESCAPE, GLFW_KEY_TAB, GLFW_KEY_F3, GLFW_KEY_F5, GLFW_KEY_LEFT_SHIFT,
  GLFW_KEY_LEFT_CONTROL,
  GLFW_MOUSE_BUTTON_LEFT, GLFW_MOUSE_BUTTON_RIGHT,
  encodeMouse, keyShortLabel
} from './GlfwKeys'

/**
 * 当前数据模型版本号。LayoutStore 在 load 时会迁移老 profile 到此版本。
 *   v2：input-system-refactor（keys[] / trigger / style / SCROLL_WHEEL / DRAWER 等）
 *   v3：手柄打底（LayoutProfile.gamepad）
 */
export const LAYOUT_PROFILE_VERSION: number = 3

/**
 * 按钮类型
 */
export enum ControlType {
  BUTTON,         // 普通按钮（圆形/矩形）
  JOYSTICK,       // 摇杆
  SCROLL_WHEEL,   // 滚轮控件（v2 新增；纵向滑动 → glfwScroll）
  DRAWER,         // 折叠抽屉（v2 新增；children 是子按钮）
  // F1（2026-07-11）：物品栏直点条。透明叠在 MC 真实 hotbar 上，点第 i 格 → 发数字键 1+i
  // （绝对选格，点哪格选哪格）；横向滑动可扫选。枚举值追加在末尾，不改动已有值，兼容旧存档。
  HOTBAR_SELECTOR,
}

/**
 * 对齐组：同组按钮在自动对齐模式下保持对齐
 */
export enum AlignGroup {
  NONE = 'none',
  HOTBAR = 'hotbar',        // 快捷栏 1-9
  ACTION_RIGHT = 'action_right',  // 攻击/放置
  MOVE_RIGHT = 'move_right',     // 跳跃/潜行
  FUNC_TOP_RIGHT = 'func_top_right', // E/ESC/T/Q/F 功能键
  DEBUG_TOP_LEFT = 'debug_top_left', // F3/F5/TAB
}

/**
 * 触发模式（v2 新增）
 *   press      — 默认；按下 PRESS、抬起 RELEASE
 *   toggle     — 按下切换状态：奇数次按下发 PRESS、偶数次按下发 RELEASE，抬起不动
 *   doubleTap  — 300ms 内连点两次才触发 PRESS+RELEASE
 *   longPress  — 按住 200ms 才触发 PRESS+RELEASE
 *
 * 边界条件（GameControls 实现）：
 *   - grabbed 翻转 (true→false)、编辑模式进入、应用切后台、改键时
 *     必须强制 RELEASE 并清零 toggle 状态，避免"切到菜单后角色还在潜行"。
 */
export type TriggerMode = 'press' | 'toggle' | 'doubleTap' | 'longPress'

/**
 * 可见性覆盖（Phase C 新增，键鼠适配）
 *
 * ⚠️ **实际生效的只有 `force_hide`（2026-08-20 全仓核实）。**
 * 这段注释原文是「auto — 跟系统判断（hideOnInput + 当前设备 capability 决定）；
 * force_show — 永远显示（即使物理键鼠都接了也不隐）；force_hide — 永远隐藏」。
 * 前两条都不成立，因为它们描述的"系统判断"（接键鼠自动隐藏）在 2026-06 被刻意删除了。
 *
 * 现在的真实语义：
 *   auto        — 无任何额外效果（`isControlVisible` 只查 `force_hide`）
 *   force_show  — **与 auto 完全相同，零作用**
 *   force_hide  — 永远隐藏 ✅ 唯一真正生效的取值
 *
 * `force_show` 的读取点全仓只有三处，没有一处影响可见性：
 *   ① 本文件 `validateAndNormalizeLayout` 的取值白名单（只做合法性校验）；
 *   ② 本文件 `shouldAutoHide()` 内部 —— 而那个函数**零调用方**；
 *   ③ `LayoutEditor` 的按钮文案与颜色（把它显示成绿色的「强显」）。
 *
 * 也就是说：**编辑器里那个三档开关对用户撒谎。** 用户切到「强显」会看到绿色高亮和
 * 「显示策略 = 强显」的提示，实际什么都没变。这是本轮审计里唯一一条**用户可感知**的
 * 缺陷（其余都是注释误导开发者）。
 *
 * **刻意不在本轮修**：两条改法都是功能变更 —— 要么让 force_show 真的生效
 * （需要先决定 auto 到底判什么），要么把三档收成两档（用户可感知的功能移除）。
 * 这与"自动显隐要不要重新接上"是同一个决定，已交给用户，见
 * `docs/refactor/多输入端架构愿景与改进提案.md` §9.1。
 *
 * 顺带回答了 §51.6 留下的那个前置问题：`visibilityOverride` **已经暴露给用户**
 * （编辑器眼睛 chip），而 `hideOnInput` **没有**（只在新建按钮时被写成 `[]`，无编辑 UI）。
 * 所以走"彻底删除"那条路时，可感知的变化是"三档变两档"，不是"删掉用户在用的开关"。
 */
export type VisibilityOverride = 'auto' | 'force_show' | 'force_hide'

/**
 * 自动隐藏条件（Phase C 新增）
 *   'mouse'              — 接了鼠标就隐
 *   'keyboard'           — 接了键盘就隐
 *   'mouse_and_keyboard' — 必须键鼠都接才隐（hotbar 用：单接鼠标时仍要 hotbar 切手中物）
 */
export type HideTrigger = 'mouse' | 'keyboard' | 'mouse_and_keyboard'

/**
 * 手柄相关类型（v3 新增，为手柄接入打底）。
 *
 * 平台事实（docs/guides/input-system-unified-direction-2026-05-29.md §2.4；⚠️ 那份文档已部分过期，
 * 见其头部横幅，但 §2.4 这两条仍成立。当前契约以 docs/refactor/输入架构规范.md 为准）：
 *   - 手柄按键经 onKeyEvent 上报（KEYCODE_BUTTON_* / KEYCODE_DPAD_*）。
 *   - 摇杆 / 扳机经 onFocusAxisEvent 上报（AxisModel，since 15）。
 *   - ⚠️ 但**轴的取值范围与符号方向官方在两条 API 路径上都没写**，只能真机取证（规范 §九）。
 *
 * 全部字段 optional，向下兼容；未配置时 GamepadManager 用 DEFAULT_GAMEPAD_CONFIG 兜底。
 */

/**
 * 手柄逻辑按钮名（与具体 OHOS keyCode 解耦，便于用户重映射 + UI 展示）。
 */
export type GamepadButton =
  'A' | 'B' | 'X' | 'Y' |
  'L1' | 'R1' | 'L2' | 'R2' |
  'START' | 'SELECT' | 'MODE' |
  'L3' | 'R3' |
  'DPAD_UP' | 'DPAD_DOWN' | 'DPAD_LEFT' | 'DPAD_RIGHT'

/**
 * 手柄按钮触发的 MC 动作：
 *   - number > 0：GLFW key code
 *   - number < 0：编码鼠标按钮（encodeMouse）
 *   - 'hotbarPrev' / 'hotbarNext'：滚轮切手中物（sendScrollEvent ±1）
 *   - 'none'：不绑定
 */
export type GamepadActionKind = 'key' | 'hotbarPrev' | 'hotbarNext' | 'none'

export interface GamepadAction {
  kind: GamepadActionKind
  code?: number          // kind === 'key' 时有效（GLFW key 或编码鼠标）
}

/**
 * 摇杆角色：左摇杆默认 move（→ WASD 八向），右摇杆默认 look（→ sendCursorDelta）。
 */
export type StickRole = 'move' | 'look' | 'none'

export interface GamepadConfig {
  enabled?: boolean                 // 默认 true
  buttonMap?: Record<string, GamepadAction>  // GamepadButton → 动作
  leftStick?: StickRole             // 默认 'move'
  rightStick?: StickRole            // 默认 'look'
  stickDeadZone?: number            // 默认 0.18
  triggerThreshold?: number         // 默认 0.5（LT/RT 模拟值过阈值视为按下）
  lookScale?: number                // 右摇杆视角额外系数，默认 1.0（最终再乘 profile.lookSensitivity）
}

/**
 * 控件视觉样式（v2 新增；可选，未提供时 GameControls 用默认渲染）
 */
export interface ControlStyle {
  bg?: string
  bgPressed?: string
  fg?: string
  opacity?: number
  shape?: 'circle' | 'square' | 'rounded' | 'diamond'
  /**
   * 圆角度（UI 重构 2026-05-29）：0..1 连续值，表示圆角占"按钮短边一半"的比例。
   *   0   = 直角方形
   *   0.5 = 圆角矩形
   *   1.0 = 完全圆（短边方形时即正圆）
   * 优先级：cornerRadius 显式设置 > shape > isCircle 兼容字段。
   */
  cornerRadius?: number
}

/**
 * 单个控件的布局数据
 */
export interface ControlItem {
  id: string             // 唯一标识 (如 'atk', 'jump', 'hb1', 'joystick', 'ime_chat')
                         // v2 约定特殊 id：
                         //   'ime_chat' = 聊天 / IME 桥接按钮（按下打开系统输入法 + 发原 keyOrMouse）
                         //   'joystick' = 摇杆（type 必须是 JOYSTICK）
                         //   'scroll'   = 滚轮（type 必须是 SCROLL_WHEEL）
  label: string          // 显示文本
  type: ControlType      // 按钮/摇杆/滚轮/抽屉
  keyOrMouse: number     // [兼容字段] GLFW key code (>0) 或 mouse button (负数编码)
                         // v2：建议优先使用 keys[]；旧字段保留供向下兼容。
                         // 当 keys 为空时回退读 keyOrMouse。
  // v2 新增：组合键序列（PRESS 按顺序、RELEASE 倒序）。
  // 例：keys=[GLFW_KEY_LEFT_CONTROL, GLFW_KEY_1] = "Ctrl+1"。
  // 不写或空数组 → 退回用 keyOrMouse。
  keys?: number[]
  modifiers?: number     // GLFW MOD mask（备用）
  trigger?: TriggerMode  // 触发模式，缺省 'press'
  // 位置：相对于屏幕宽高的百分比 (0~1)
  xPct: number
  yPct: number
  // 大小：vp 基准值（会被 globalScale * itemScale 缩放）
  baseWidth: number
  baseHeight: number
  // 个别缩放（默认 1.0）
  itemScale: number
  // 形状（v1）；优先级：style.shape > isCircle
  isCircle: boolean
  style?: ControlStyle
  // 对齐组
  alignGroup: AlignGroup
  // 对齐组内序号（用于自动对齐排列）
  alignIndex: number
  // 是否在 grabbed 模式下显示（false = 两种模式都显示）
  //   场景可见性（2026-05-30）：grabbedOnly + menuOnly 组合表达"游戏/菜单/始终"三种场景。
  //     grabbedOnly=true,  menuOnly=false → 仅游戏中（grabbed）显示
  //     grabbedOnly=false, menuOnly=true  → 仅菜单（背包/选项等，非 grabbed）显示
  //     grabbedOnly=false, menuOnly=false → 始终显示
  //   见 ControlScene / controlScene / setControlScene / isVisibleInScene。
  grabbedOnly: boolean
  // 仅在菜单（非 grabbed，如背包/选项）显示。默认 undefined = false。
  menuOnly?: boolean
  // v2：编辑器辅助字段
  hidden?: boolean
  locked?: boolean
  /**
   * Phase C（键鼠适配）：用户对自动隐藏的覆盖。auto = 跟系统判断；
   * force_show = 永远显示；force_hide = 永远隐藏。缺省视为 'auto'。
   */
  visibilityOverride?: VisibilityOverride
  /**
   * Phase C（键鼠适配）：该按钮在哪些条件下应被自动隐藏。
   * 缺省（undefined）由 inferDefaultHideOnInput 按 id / type 推断。
   * 空数组 = 永不隐藏。
   */
  hideOnInput?: HideTrigger[]
  /**
   * 2026-05-30：按住拖动瞄准。true 时——按住该按钮保持 PRESS 不放，手指在屏上拖动
   * 转视角（sendCursorDelta），抬手才 RELEASE。用于"按住右键蓄力弓箭/盾牌时拖动瞄准，
   * 松手再释放"。仅对 type=BUTTON 有意义（摇杆/滚轮/抽屉不适用）。
   */
  dragLook?: boolean
  /**
   * 物品栏直点条（HOTBAR_SELECTOR）专用：用户是否在编辑器里手动摆放 / 缩放过它。
   * - 缺省 / false → 视为"系统对齐控件"：每次 load 都按本机分辨率 + guiScale 重新对齐到 MC hotbar
   *   的真实像素矩形（见 LayoutStore.ensureHotbarSelector / computeHotbarRectPx），保证点击格与
   *   游戏内 hotbar 严格对齐；
   * - true → 用户已手动定位（例如用了手动档 guiScale 或特殊摆放），load 时不再覆盖，尊重用户。
   * 仅对 type=HOTBAR_SELECTOR 有意义；其它控件忽略此字段。
   */
  hotbarUserPlaced?: boolean
  /**
   * 系统功能按钮标记。非空时该控件外观同普通按钮，但点击执行应用级功能（不发键），且不可删除：
   *   'input'      → 游戏内=聊天键(T)+聊天IME；菜单=field IME（同步到聚焦文本框）
   *   'edit'       → 进入布局编辑器
   *   'visibility' → 循环全局可见性档位（全部/仅菜单/全部隐藏），按钮文字随档位变化
   * 仅存在于 ArkTS 布局层，不进 native POD；native 只把它们当 handledBy=arkts 条目避让视角。
   */
  systemAction?: SystemAction
  // v2：DRAWER 类型的子按钮
  children?: ControlItem[]
}

/**
 * 完整布局方案
 */
export interface LayoutProfile {
  // v2 新增：模型版本，缺省视为 1（迁移目标 = LAYOUT_PROFILE_VERSION）
  version?: number
  name: string                  // 方案名称
  globalScale: number           // 全局缩放 (0.5 ~ 2.0，默认 1.0)
  // v2 新增：全局参数
  lookSensitivity?: number      // 视角灵敏度 0.3..3.0（默认 1.0）
  invertY?: boolean             // Y 轴倒置（默认 false）
  // 方案 C（2026-07-11）：视角手感全局参数
  lookSmoothing?: number        // 平滑系数 α（0.1..1.0，越大越跟手；1.0=关闭平滑；默认 0.6）
  lookAccel?: number            // 视角加速强度（0..1，0=关闭；默认 0）
  joystickDeadZone?: number     // 摇杆死区（0.01..0.95，默认 0.18）
  haptic?: boolean              // 触觉反馈开关（默认 true，目前 stub 不真发）
  // 2026-05-30：全局透明度（0.1..1.0，默认 1.0）。渲染时与每个按钮自身 opacity 相乘。
  globalOpacity?: number
  targetDevice?: 'phone' | 'tablet' | 'foldable' | 'any'
  isPreset?: boolean            // 系统预设标记，预设方案不可直接编辑（克隆才能改）
  // 2026-07-16：导出/最后编辑该方案的设备型号（deviceInfo.marketName）。仅信息记录，不参与设备匹配判断。
  // 导出时盖当前设备型号；在导入的方案上编辑保存时同步为当前设备型号。
  deviceModel?: string
  // F1（2026-07-11）：物品栏直点条已默认注入标记。LayoutStore.load 对缺失该控件且未标记的老方案
  // 注入一个（默认开）；置 true 后即使用户删掉也不再重复注入，尊重用户选择。
  hotbarAutoAdded?: boolean
  // 编辑器自动对齐/吸附（2026-07-16）：拖动/新增按钮时对齐到其它按钮的边/中心/相邻间距并显示虚线。
  //   snapEnabled  — 总开关（默认 true）
  //   snapGap      — 相邻贴靠间距 vp（"我的右缘 ↔ 你的左缘"之间留的空隙；默认 0 = 紧贴）
  //   snapStrength — 吸附灵敏度 vp（进入阈值 SNAP_IN；脱离阈值按其倍数派生，形成黏滞防抖）
  snapEnabled?: boolean
  snapGap?: number
  snapStrength?: number
  // v3 新增：手柄配置（全 optional，未设时用 DEFAULT_GAMEPAD_CONFIG 兜底）
  gamepad?: GamepadConfig
  controls: ControlItem[]       // 所有控件
}

/** 编辑器自动对齐默认值（vp）。SNAP_OUT（脱离阈值）在编辑器内按 strength × 倍数派生。 */
// 默认相邻贴靠间距 6vp：吸附到相邻按钮时默认留一点缝隙（而非紧贴），也是"一键等间距"的默认目标间距。
export const DEFAULT_SNAP_GAP: number = 6
export const DEFAULT_SNAP_STRENGTH: number = 5

/**
 * 默认参数集合 — 给 v1 → v2 迁移和"没设置过"的 profile 用的兜底
 */
export const DEFAULT_LOOK_SENSITIVITY: number = 1.0
export const DEFAULT_INVERT_Y: boolean = false
// 方案 C：视角平滑默认 α=0.6（与 native s_lookSmoothAlpha 默认一致）；加速默认关闭。
export const DEFAULT_LOOK_SMOOTHING: number = 0.6
export const DEFAULT_LOOK_ACCEL: number = 0.0
export const DEFAULT_JOYSTICK_DEAD_ZONE: number = 0.18
/** 2026-05-30：全局透明度默认 1.0（不透明）。渲染时 = effectiveOpacity(item) × globalOpacity。 */
export const DEFAULT_GLOBAL_OPACITY: number = 1.0

// ==================== 按钮外观默认值（UI 重构 2026-05-30） ====================
//
// 设计目标（参考 PojavLauncher / 各主流触屏方案的"按键帽"观感）：
//   每个按键默认 = 一个大小相同的正方形框，框内显示其绑定键的字母/短词。
//   鼠标左右键框内显示"左""右"。用户仍可单独改每个按键的大小 / 圆角。
//
/** 统一按钮基准尺寸（vp）。所有普通按钮默认用它，"统一大小"一键也用它。 */
export const DEFAULT_BUTTON_SIZE: number = 48
/** 默认按钮透明度（0..1）。 */
export const DEFAULT_BUTTON_OPACITY: number = 1.0
/**
 * 默认圆角度（0..1）：UI 重构 2026-05-30 从 0.18 改为 0.12，更贴近"正方形框"观感，
 * 但保留极轻微圆角避免硬直角。0 = 直角；0.5 = 圆角矩形；1 = 短边方形时为正圆。
 */
export const DEFAULT_CORNER_RADIUS: number = 0.12

/**
 * 取按钮的有效圆角度（0..1）。优先 style.cornerRadius；否则按 shape / isCircle 推断：
 *   circle/isCircle → 1.0；square → 0；rounded → 0.3；其它 → DEFAULT_CORNER_RADIUS。
 */
export function effectiveCornerRadius(c: ControlItem): number {
  const cr = c.style?.cornerRadius
  if (cr !== undefined) return cr < 0 ? 0 : (cr > 1 ? 1 : cr)
  const shape = c.style?.shape
  if (shape === 'circle') return 1.0
  if (shape === 'square') return 0
  if (shape === 'rounded') return 0.3
  if (c.isCircle) return 1.0
  return DEFAULT_CORNER_RADIUS
}

/**
 * 取按钮"框内显示的文本"——UI 重构 2026-05-30。
 *
 * 规则：
 *   - 用户显式设了 label（非空）→ 用 label（尊重自定义，比如"丢弃"/"物品栏"）。
 *   - 否则按绑定键自动生成短标签：字母键→字母，鼠标左/右→"左"/"右"，Space/Shift… → 短词。
 *   - 摇杆 / 滚轮等无键控件 → 空串（各自的 Builder 有专属视觉）。
 *
 * 这样默认布局不再需要在数据里硬编码 ⚔🛡▲▼ 等表情；框内直接显示按键字母，
 * 改键后标签自动跟着变（除非用户手动覆盖了 label）。
 */
export function effectiveLabel(c: ControlItem): string {
  if (c.label && c.label.length > 0) return c.label
  if (c.type === ControlType.JOYSTICK || c.type === ControlType.SCROLL_WHEEL
      || c.type === ControlType.HOTBAR_SELECTOR) return ''
  const keys = effectiveKeys(c)
  if (keys.length === 0) return ''
  // 组合键：用 "+" 连接各键短标签（如 Ctrl+1）
  if (keys.length > 1) {
    return keys.map((k: number) => keyShortLabel(k)).join('+')
  }
  return keyShortLabel(keys[0])
}

/**
 * 场景可见性（2026-05-30）：一个按钮在"游戏中 / 菜单里 / 两者"哪个场景显示。
 *   'game'   — 仅游戏中（grabbed，鼠标锁定操作角色时）
 *   'menu'   — 仅菜单中（非 grabbed，背包 / 选项 / 暂停菜单等鼠标可见时）
 *   'always' — 两个场景都显示
 *
 * 底层用 grabbedOnly + menuOnly 两个布尔编码（向下兼容旧数据：老数据只有 grabbedOnly，
 * 自然映射成 game / always）。
 */
export type ControlScene = 'game' | 'menu' | 'always'

/** 读取一个控件的场景。 */
export function controlScene(c: ControlItem): ControlScene {
  if (c.menuOnly === true) return 'menu'
  if (c.grabbedOnly === true) return 'game'
  return 'always'
}

/** 设置一个控件的场景（写回 grabbedOnly + menuOnly）。 */
export function setControlScene(c: ControlItem, scene: ControlScene): void {
  if (scene === 'game') {
    c.grabbedOnly = true
    c.menuOnly = false
  } else if (scene === 'menu') {
    c.grabbedOnly = false
    c.menuOnly = true
  } else {
    c.grabbedOnly = false
    c.menuOnly = false
  }
}

/**
 * 给定当前是否 grabbed，判断控件在该场景下是否应显示（只看场景，不含 hidden / 自动隐藏）。
 */
export function isVisibleInScene(c: ControlItem, isGrabbed: boolean): boolean {
  const scene = controlScene(c)
  if (scene === 'always') return true
  if (scene === 'game') return isGrabbed
  return !isGrabbed   // 'menu'
}

/** 取按钮的有效透明度（0..1）。 */
export function effectiveOpacity(c: ControlItem): number {
  const o = c.style?.opacity
  if (o === undefined) return DEFAULT_BUTTON_OPACITY
  return o < 0.1 ? 0.1 : (o > 1 ? 1 : o)
}

/** 取全局透明度（0.1..1.0）。缺省 1.0。 */
export function effectiveGlobalOpacity(p: LayoutProfile): number {
  const o = p.globalOpacity
  if (o === undefined) return DEFAULT_GLOBAL_OPACITY
  return o < 0.1 ? 0.1 : (o > 1 ? 1 : o)
}

/** 渲染用的最终透明度 = 按钮自身 opacity × 全局 opacity（0.1..1.0）。 */
export function renderOpacity(c: ControlItem, p: LayoutProfile): number {
  const v = effectiveOpacity(c) * effectiveGlobalOpacity(p)
  return v < 0.05 ? 0.05 : (v > 1 ? 1 : v)
}

// ==================== 手柄默认配置（v3） ====================
export const DEFAULT_GAMEPAD_DEAD_ZONE: number = 0.18
export const DEFAULT_TRIGGER_THRESHOLD: number = 0.5

/**
 * 默认手柄按钮映射（Xbox 布局）。返回新对象，调用方可安全修改。
 *   A=跳 B=潜行 X=放置(RMB) Y=切手(F)
 *   L1/R1=切手中物  L2=丢弃(Q)  R2=攻击(LMB)
 *   START=ESC  SELECT=TAB  L3/R3=空（留给 sneak/sprint toggle 后续）
 *   DPAD=空（部分手柄方向键走轴，由 GamepadManager 的 HAT 轴兜底）
 */
export function defaultGamepadButtonMap(): Record<string, GamepadAction> {
  const m: Record<string, GamepadAction> = {}
  m['A'] = { kind: 'key', code: GLFW_KEY_SPACE }
  m['B'] = { kind: 'key', code: GLFW_KEY_LEFT_SHIFT }
  m['X'] = { kind: 'key', code: encodeMouse(GLFW_MOUSE_BUTTON_RIGHT) }
  m['Y'] = { kind: 'key', code: GLFW_KEY_F }
  m['L1'] = { kind: 'hotbarPrev' }
  m['R1'] = { kind: 'hotbarNext' }
  m['L2'] = { kind: 'key', code: GLFW_KEY_Q }
  m['R2'] = { kind: 'key', code: encodeMouse(GLFW_MOUSE_BUTTON_LEFT) }
  m['START'] = { kind: 'key', code: GLFW_KEY_ESCAPE }
  m['SELECT'] = { kind: 'key', code: GLFW_KEY_TAB }
  m['MODE'] = { kind: 'none' }
  m['L3'] = { kind: 'none' }
  m['R3'] = { kind: 'none' }
  m['DPAD_UP'] = { kind: 'none' }
  m['DPAD_DOWN'] = { kind: 'none' }
  m['DPAD_LEFT'] = { kind: 'hotbarPrev' }
  m['DPAD_RIGHT'] = { kind: 'hotbarNext' }
  return m
}

/**
 * 默认手柄配置。GamepadManager 在 profile.gamepad 缺字段时用它兜底。
 */
export function defaultGamepadConfig(): GamepadConfig {
  return {
    enabled: true,
    buttonMap: defaultGamepadButtonMap(),
    leftStick: 'move',
    rightStick: 'look',
    stickDeadZone: DEFAULT_GAMEPAD_DEAD_ZONE,
    triggerThreshold: DEFAULT_TRIGGER_THRESHOLD,
    lookScale: 1.0
  }
}

/**
 * 默认布局（UI 重构 2026-05-30）
 *
 * 设计：每个按键 = 大小相同的正方形框（DEFAULT_BUTTON_SIZE），框内文字由绑定键
 * 自动推导（label 留空 → effectiveLabel 取键名）。鼠标左/右键框内显示"左""右"。
 * 摇杆默认圆形（cornerRadius=1），用户可在编辑器切方形。
 *
 * 坐标使用百分比，基于典型横屏 (如 720x360 vp)。
 */
function defBtn(
  id: string, key: number, xPct: number, yPct: number,
  group: AlignGroup, alignIndex: number, grabbedOnly: boolean
): ControlItem {
  return {
    id, label: '', type: ControlType.BUTTON, keyOrMouse: key,
    xPct, yPct,
    baseWidth: DEFAULT_BUTTON_SIZE, baseHeight: DEFAULT_BUTTON_SIZE,
    itemScale: 1.0, isCircle: false,
    style: { cornerRadius: DEFAULT_CORNER_RADIUS },
    alignGroup: group, alignIndex,
    grabbedOnly
  }
}

export function getDefaultLayout(): LayoutProfile {
  const controls: ControlItem[] = [
    // 摇杆（默认圆形，可在编辑器切方形）
    {
      id: 'joystick', label: '', type: ControlType.JOYSTICK,
      keyOrMouse: 0,
      xPct: 0.021, yPct: 0.57,
      baseWidth: 140, baseHeight: 140,
      itemScale: 1.0, isCircle: true,
      style: { cornerRadius: 1.0 },
      alignGroup: AlignGroup.NONE, alignIndex: 0,
      grabbedOnly: true
    },
    // 攻击 / 放置（鼠标左右键 → 框内自动显示"左""右"）
    defBtn('atk', encodeMouse(GLFW_MOUSE_BUTTON_LEFT), 0.833, 0.36, AlignGroup.ACTION_RIGHT, 0, true),
    defBtn('place', encodeMouse(GLFW_MOUSE_BUTTON_RIGHT), 0.917, 0.36, AlignGroup.ACTION_RIGHT, 1, true),
    // 跳跃 / 潜行
    defBtn('jump', GLFW_KEY_SPACE, 0.889, 0.64, AlignGroup.MOVE_RIGHT, 0, true),
    defBtn('sneak', GLFW_KEY_LEFT_SHIFT, 0.889, 0.81, AlignGroup.MOVE_RIGHT, 1, true),
    // 功能键（E, ESC, 聊天, Q, F）
    defBtn('key_E', GLFW_KEY_E, 0.778, 0.017, AlignGroup.FUNC_TOP_RIGHT, 0, false),
    defBtn('key_ESC', GLFW_KEY_ESCAPE, 0.846, 0.017, AlignGroup.FUNC_TOP_RIGHT, 1, false),
    // 系统功能按钮：输入（原"聊"，双模式）、设置（进编辑器）、显示（循环可见性档位）。
    // 外观同普通按钮、可移动可配置，但不可删除（由 LayoutStore.ensureSystemControls 保证存在）。
    makeSystemButton('input', 0.778, 0.106, 2),
    makeSystemButton('edit', 0.914, 0.017, 5),
    makeSystemButton('visibility', 0.778, 0.195, 6),
    defBtn('key_Q', GLFW_KEY_Q, 0.846, 0.106, AlignGroup.FUNC_TOP_RIGHT, 3, true),
    defBtn('key_F', GLFW_KEY_F, 0.914, 0.106, AlignGroup.FUNC_TOP_RIGHT, 4, true),
    // 调试键
    defBtn('key_F3', GLFW_KEY_F3, 0.014, 0.017, AlignGroup.DEBUG_TOP_LEFT, 0, false),
    defBtn('key_F5', GLFW_KEY_F5, 0.082, 0.017, AlignGroup.DEBUG_TOP_LEFT, 1, false),
    defBtn('key_TAB', GLFW_KEY_TAB, 0.150, 0.017, AlignGroup.DEBUG_TOP_LEFT, 2, false),
  ]
  // 快捷栏 1-9（统一正方形框，框内显示数字）
  for (let n = 1; n <= 9; n++) {
    controls.push({
      id: 'hb' + n.toString(),
      label: '',
      type: ControlType.BUTTON,
      keyOrMouse: GLFW_KEY_1 + n - 1,
      xPct: 0.5 + ((n - 5) * 54 - DEFAULT_BUTTON_SIZE / 2) / 720,
      yPct: 0.017,
      baseWidth: DEFAULT_BUTTON_SIZE, baseHeight: DEFAULT_BUTTON_SIZE,
      itemScale: 1.0, isCircle: false,
      style: { cornerRadius: DEFAULT_CORNER_RADIUS },
      alignGroup: AlignGroup.HOTBAR, alignIndex: n - 1,
      grabbedOnly: true
    })
  }
  // 滚轮（放在 hotbar 右侧，方便切手中物品）
  controls.push({
    id: 'scroll',
    label: '⇅',
    type: ControlType.SCROLL_WHEEL,
    keyOrMouse: 0,
    xPct: 0.95, yPct: 0.017,
    baseWidth: 28, baseHeight: 84,
    itemScale: 1.0, isCircle: false,
    alignGroup: AlignGroup.NONE, alignIndex: 0,
    grabbedOnly: true
  })
  // F1（2026-07-11）：物品栏直点条，默认开启。底部中央近似位置，LayoutStore.load 会按设备精确对齐 MC hotbar。
  controls.push(makeHotbarSelector(0.34, 0.9, 300, 36))
  return {
    version: LAYOUT_PROFILE_VERSION,
    name: '默认',
    globalScale: 1.0,
    lookSensitivity: DEFAULT_LOOK_SENSITIVITY,
    invertY: DEFAULT_INVERT_Y,
    joystickDeadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
    haptic: true,
    targetDevice: 'any',
    hotbarAutoAdded: true,
    controls: controls
  }
}

/**
 * 递归深拷贝单个控件。
 *
 * 设计约束：style、keys、hideOnInput 和任意层 children 都必须分配新对象；编辑器撤销栈、
 * 复制抽屉和持久化快照因此不会再通过嵌套引用互相污染。ID 在普通克隆时保持稳定，只有明确的
 * “复制为新控件”操作才调用 cloneItemWithFreshIds 重新分配整棵子树的 ID。
 */
function cloneItemFields(c: ControlItem, children: ControlItem[] | undefined): ControlItem {
  return {
    id: c.id, label: c.label, type: c.type, keyOrMouse: c.keyOrMouse,
    keys: c.keys ? c.keys.slice() : undefined,
    modifiers: c.modifiers,
    trigger: c.trigger,
    xPct: c.xPct, yPct: c.yPct,
    baseWidth: c.baseWidth, baseHeight: c.baseHeight,
    itemScale: c.itemScale, isCircle: c.isCircle,
    style: c.style ? {
      bg: c.style.bg, bgPressed: c.style.bgPressed, fg: c.style.fg,
      opacity: c.style.opacity, shape: c.style.shape, cornerRadius: c.style.cornerRadius
    } : undefined,
    alignGroup: c.alignGroup, alignIndex: c.alignIndex,
    grabbedOnly: c.grabbedOnly,
    menuOnly: c.menuOnly,
    hidden: c.hidden,
    locked: c.locked,
    visibilityOverride: c.visibilityOverride,
    hideOnInput: c.hideOnInput ? c.hideOnInput.slice() : undefined,
    dragLook: c.dragLook,
    hotbarUserPlaced: c.hotbarUserPlaced,
    systemAction: c.systemAction,
    children: children
  }
}

export function cloneItem(c: ControlItem): ControlItem {
  const children: ControlItem[] | undefined = c.children === undefined ? undefined : []
  if (c.children && children) {
    for (let i = 0; i < c.children.length; i++) children.push(cloneItem(c.children[i]))
  }
  return cloneItemFields(c, children)
}

/** 深拷贝手柄配置（含 buttonMap）。undefined 透传。 */
function cloneGamepadConfig(g: GamepadConfig | undefined): GamepadConfig | undefined {
  if (!g) return undefined
  let buttonMap: Record<string, GamepadAction> | undefined = undefined
  if (g.buttonMap) {
    buttonMap = {}
    const keys = Object.keys(g.buttonMap)
    for (let i = 0; i < keys.length; i++) {
      const a = g.buttonMap[keys[i]]
      buttonMap[keys[i]] = { kind: a.kind, code: a.code }
    }
  }
  return {
    enabled: g.enabled,
    buttonMap: buttonMap,
    leftStick: g.leftStick,
    rightStick: g.rightStick,
    stickDeadZone: g.stickDeadZone,
    triggerThreshold: g.triggerThreshold,
    lookScale: g.lookScale
  }
}

/** 深拷贝完整方案；包括 hotbarAutoAdded，避免编辑器保存后丢失“一次性自动注入”状态。 */
export function cloneLayout(src: LayoutProfile): LayoutProfile {
  const controls: ControlItem[] = []
  for (let i = 0; i < src.controls.length; i++) controls.push(cloneItem(src.controls[i]))
  return {
    version: src.version ?? LAYOUT_PROFILE_VERSION,
    name: src.name,
    globalScale: src.globalScale,
    lookSensitivity: src.lookSensitivity,
    invertY: src.invertY,
    lookSmoothing: src.lookSmoothing,
    lookAccel: src.lookAccel,
    joystickDeadZone: src.joystickDeadZone,
    haptic: src.haptic,
    globalOpacity: src.globalOpacity,
    targetDevice: src.targetDevice,
    isPreset: src.isPreset,
    deviceModel: src.deviceModel,
    hotbarAutoAdded: src.hotbarAutoAdded,
    snapEnabled: src.snapEnabled,
    snapGap: src.snapGap,
    snapStrength: src.snapStrength,
    gamepad: cloneGamepadConfig(src.gamepad),
    controls: controls
  }
}

// ==================== 稳定短 ID ====================
//
// ID 只使用 ASCII：时间基数 + 进程盐 + 单调序号。当前长度约 18 字节，始终低于 23 字节；
// 同一进程由单调序号保证不重复，跨进程由毫秒时间和随机盐共同隔离。调用时还会扫描完整 children
// 树并避开已有 ID，所以即使导入布局恰好含同格式 ID，也不会产生局部或子控件冲突。
let gControlIdSequence: number = 0
const CONTROL_ID_SESSION: string = Math.floor(Math.random() * 1679616).toString(36)

function collectControlIds(items: ControlItem[], used: Set<string>): void {
  for (let i = 0; i < items.length; i++) {
    used.add(items[i].id)
    if (items[i].children) collectControlIds(items[i].children!, used)
  }
}

function nextControlId(used: Set<string>): string {
  let id = ''
  do {
    gControlIdSequence++
    id = 'c' + Date.now().toString(36) + CONTROL_ID_SESSION + gControlIdSequence.toString(36)
  } while (used.has(id) || utf8ByteLength(id) > 23)
  used.add(id)
  return id
}

/** 生成全局短 ID；existing 会递归扫描，children 与顶层共享同一命名空间。 */
export function generateControlId(existing: ControlItem[]): string {
  const used = new Set<string>()
  collectControlIds(existing, used)
  return nextControlId(used)
}

/** 深拷贝控件并为根及全部 children 分配新 ID，供“复制控件”使用。 */
export function cloneItemWithFreshIds(src: ControlItem, existing: ControlItem[]): ControlItem {
  const copy = cloneItem(src)
  const used = new Set<string>()
  collectControlIds(existing, used)
  const assign = (item: ControlItem): void => {
    item.id = nextControlId(used)
    if (item.children) {
      for (let i = 0; i < item.children.length; i++) assign(item.children[i])
    }
  }
  assign(copy)
  return copy
}

// ==================== 统一布局校验 / 规范化 ====================

/**
 * 校验上限是安全边界而非“截断目标”；任一层越界都会让整个方案失败。
 *
 * ============ ⚠️ 这一组里有三个数是 native ABI 的镜像 ============
 *
 * 唯一真相在 `entry/src/main/cpp/platform/touch_input.h`：
 *
 * | 这里 | native | 校验点 |
 * |---|---|---|
 * | `MAX_LAYOUT_CONTROL_COUNT = 256` | `AMCL_CONTROL_SCHEMA_MAX_CONTROLS 256` | `normalizeControlItem` 的 `state.count >=` |
 * | id 的 **23 字节**上限（`normalizeControlItem` 里的裸字面量） | `AMCL_CONTROL_ID_MAX_BYTES 23` | `utf8ByteLength(source.id) > 23` |
 * | keys 的 **6** 个上限（同上，裸字面量） | `AMCL_CONTROL_MAX_KEYS 6` | `source.keys.length > 6` |
 *
 * **三处必须与 native 同时修改。** 2026-08-20 逐一核对过，当前三方一致
 * （含 `count == 256` 的边界：这里放行 256、native 拒 `> 256`，无 off-by-one）。
 *
 * **失效是不对称的，所以这条纪律不是洁癖：**
 *   - native 上界**调低**而这里没跟 → ArkTS 放行一个 native 会拒的控件 →
 *     `RejectSchema` 拒的是**整条消息** → **所有虚拟按键、摇杆、物品栏一起失效**。
 *     立即可见、灾难性，而且日志只有一行 `ControlSchema NAPI rejected: id-length`。
 *   - native 上界**调高**而这里没跟 → ArkTS 静默丢掉那个控件 → 只是某个按钮消失。
 *     更轻，但**静默**。
 *
 * 这一层校验之所以承重，是因为它是**外部输入**的第一道关：应用注册了 `.json` 的系统
 * 「打开方式」用于导入按键布局方案（见 `entry/src/main/module.json5`），所以 id 与 keys
 * 可以来自任意文件。`MAX_LAYOUT_CHILD_DEPTH` 没有 native 对应物（native 收到的是拍平后的
 * 数组），它只防递归炸弹。
 *
 * 参照写法见 `KeyMap.ets` 的 `AMCL_LOCK_STATE_*` 与 `InputDeviceAbi.ets` 的
 * `AMCL_DEVICE_CAP_*` —— 那两组都有同样的声明，也正因为如此，2026-08-20 的三方数值
 * 核对在它们那里是**零偏差**。本注释就是把同一道纪律补到这三个数上。
 */
export const MAX_LAYOUT_CONTROL_COUNT: number = 256
export const MAX_LAYOUT_CHILD_DEPTH: number = 8

/** 不依赖平台 API 的 UTF-8 字节计数，正确处理代理对；孤立代理按替换字符 3 字节计。 */
export function utf8ByteLength(value: string): number {
  let bytes = 0
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    if (code <= 0x7F) bytes += 1
    else if (code <= 0x7FF) bytes += 2
    else if (code >= 0xD800 && code <= 0xDBFF) {
      if (i + 1 < value.length) {
        const low = value.charCodeAt(i + 1)
        if (low >= 0xDC00 && low <= 0xDFFF) { bytes += 4; i++; continue }
      }
      bytes += 3
    } else bytes += 3
  }
  return bytes
}

function finiteInRange(value: number, min: number, max: number): boolean {
  return Number.isFinite(value) && value >= min && value <= max
}

function validInteger(value: number, min: number, max: number): boolean {
  return Number.isFinite(value) && Math.floor(value) === value && value >= min && value <= max
}

/**
 * 与 native Control Schema v2 完全一致的输出编码：GLFW key 1..512，鼠标按钮编码 -1..-16。
 * 0 只允许作为摇杆/滚轮/抽屉等非输出控件的兼容占位；BUTTON 的有效绑定绝不能为 0，
 * 否则 ArkTS 视觉已接受布局而 native 会拒绝整张 schema，形成不可见旧热区。
 */
function validOutputCode(value: number): boolean {
  return validInteger(value, 1, 512) || validInteger(value, -16, -1)
}

function validCompatOutputCode(value: number): boolean {
  return value === 0 || validOutputCode(value)
}

function validControlType(value: ControlType): boolean {
  return value === ControlType.BUTTON || value === ControlType.JOYSTICK
    || value === ControlType.SCROLL_WHEEL || value === ControlType.DRAWER
    || value === ControlType.HOTBAR_SELECTOR
}

function validAlignGroup(value: AlignGroup): boolean {
  return value === AlignGroup.NONE || value === AlignGroup.HOTBAR || value === AlignGroup.ACTION_RIGHT
    || value === AlignGroup.MOVE_RIGHT || value === AlignGroup.FUNC_TOP_RIGHT || value === AlignGroup.DEBUG_TOP_LEFT
}

function validTrigger(value: TriggerMode): boolean {
  return value === 'press' || value === 'toggle' || value === 'doubleTap' || value === 'longPress'
}

function validOptionalBoolean(value: boolean | undefined): boolean {
  return value === undefined || typeof value === 'boolean'
}

interface NormalizeState {
  usedIds: Set<string>
  count: number
}

/**
 * 递归规范化单个控件。这里只补老版本明确允许缺省的字段；不会修剪 keys/children、夹取数值或
 * 丢弃坏节点。任何非法值直接返回 null，由最外层拒绝整个布局，保证导入和持久化 fail closed。
 */
function normalizeControlItem(source: ControlItem, depth: number, state: NormalizeState): ControlItem | null {
  if (!source || depth > MAX_LAYOUT_CHILD_DEPTH || state.count >= MAX_LAYOUT_CONTROL_COUNT) return null
  // 23 = native 的 `AMCL_CONTROL_ID_MAX_BYTES`（ABI 镜像，见 MAX_LAYOUT_CONTROL_COUNT 处的说明）。
  // 用**字节**而不是字符：native 侧是定长 char[]，一个中文 id 是 3 字节/字。
  if (typeof source.id !== 'string' || source.id.length === 0 || utf8ByteLength(source.id) > 23
      || state.usedIds.has(source.id)) return null
  if (typeof source.label !== 'string' || utf8ByteLength(source.label) > 256) return null
  if (!validControlType(source.type) || !validCompatOutputCode(source.keyOrMouse)) return null
  if (!finiteInRange(source.xPct, 0, 1) || !finiteInRange(source.yPct, 0, 1)) return null
  if (!finiteInRange(source.baseWidth, 1, 4096) || !finiteInRange(source.baseHeight, 1, 4096)) return null
  if (source.itemScale !== undefined && !finiteInRange(source.itemScale, 0.1, 10)) return null
  if (typeof source.isCircle !== 'boolean') return null

  if (source.trigger !== undefined && !validTrigger(source.trigger)) return null
  if (source.alignGroup !== undefined && !validAlignGroup(source.alignGroup)) return null
  if (source.alignIndex !== undefined && !validInteger(source.alignIndex, 0, 255)) return null
  if (source.grabbedOnly !== undefined && typeof source.grabbedOnly !== 'boolean') return null
  const trigger: TriggerMode = source.trigger ?? 'press'
  const alignGroup: AlignGroup = source.alignGroup ?? AlignGroup.NONE
  const alignIndex: number = source.alignIndex ?? 0
  const grabbedOnly: boolean = source.grabbedOnly ?? false
  if (!validOptionalBoolean(source.menuOnly) || !validOptionalBoolean(source.hidden)
      || !validOptionalBoolean(source.locked) || !validOptionalBoolean(source.dragLook)) return null

  if (source.keys !== undefined) {
    // 6 = native 的 `AMCL_CONTROL_MAX_KEYS`（ABI 镜像，见 MAX_LAYOUT_CONTROL_COUNT 处的说明）。
    if (!Array.isArray(source.keys) || source.keys.length > 6) return null
    for (let i = 0; i < source.keys.length; i++) {
      if (!validOutputCode(source.keys[i])) return null
    }
  }
  // keys[] 非空时它是实际绑定；否则 BUTTON 回退 keyOrMouse。两条路径都必须至少提供一个
  // native 可表达的输出，禁止把 0 当作“以后再配”并持久化到运行时 schema。
  if (source.systemAction !== undefined && source.systemAction !== 'input'
      && source.systemAction !== 'edit' && source.systemAction !== 'visibility') return null
  // 系统功能按钮（systemAction 非空）不发键，豁免"BUTTON 必须有有效键"的要求。
  if (source.type === ControlType.BUTTON && source.systemAction === undefined
      && (!source.keys || source.keys.length === 0) && !validOutputCode(source.keyOrMouse)) return null
  if (source.modifiers !== undefined && !validInteger(source.modifiers, 0, 65535)) return null
  if (source.visibilityOverride !== undefined && source.visibilityOverride !== 'auto'
      && source.visibilityOverride !== 'force_show' && source.visibilityOverride !== 'force_hide') return null
  if (source.hideOnInput !== undefined) {
    if (!Array.isArray(source.hideOnInput) || source.hideOnInput.length > 3) return null
    for (let i = 0; i < source.hideOnInput.length; i++) {
      const h = source.hideOnInput[i]
      if (h !== 'mouse' && h !== 'keyboard' && h !== 'mouse_and_keyboard') return null
    }
  }
  if (source.style !== undefined) {
    if (!source.style || typeof source.style !== 'object') return null
    const s = source.style
    if ((s.bg !== undefined && (typeof s.bg !== 'string' || s.bg.length > 64))
        || (s.bgPressed !== undefined && (typeof s.bgPressed !== 'string' || s.bgPressed.length > 64))
        || (s.fg !== undefined && (typeof s.fg !== 'string' || s.fg.length > 64))) return null
    if (s.opacity !== undefined && !finiteInRange(s.opacity, 0.1, 1)) return null
    if (s.cornerRadius !== undefined && !finiteInRange(s.cornerRadius, 0, 1)) return null
    if (s.shape !== undefined && s.shape !== 'circle' && s.shape !== 'square'
        && s.shape !== 'rounded' && s.shape !== 'diamond') return null
  }
  if (source.children !== undefined && !Array.isArray(source.children)) return null
  if (source.hotbarUserPlaced !== undefined && typeof source.hotbarUserPlaced !== 'boolean') return null

  state.usedIds.add(source.id)
  state.count++
  const normalized = cloneItemFields(source, undefined)
  normalized.itemScale = source.itemScale ?? 1.0
  normalized.trigger = trigger
  normalized.alignGroup = alignGroup
  normalized.alignIndex = alignIndex
  normalized.grabbedOnly = grabbedOnly
  if (isLegacyDecorLabel(normalized.label)) normalized.label = ''
  if (normalized.hideOnInput === undefined) normalized.hideOnInput = inferDefaultHideOnInput(normalized)
  if (normalized.id === 'joystick' && normalized.hideOnInput.length === 0) {
    normalized.hideOnInput = inferDefaultHideOnInput(normalized)
  }

  if (source.children) {
    normalized.children = []
    for (let i = 0; i < source.children.length; i++) {
      const child = normalizeControlItem(source.children[i], depth + 1, state)
      if (!child) return null
      normalized.children.push(child)
    }
  }
  return normalized
}

function validGamepadConfig(g: GamepadConfig | undefined): boolean {
  if (g === undefined) return true
  if (!g || typeof g !== 'object') return false
  if (!validOptionalBoolean(g.enabled)) return false
  if (g.leftStick !== undefined && g.leftStick !== 'move' && g.leftStick !== 'look' && g.leftStick !== 'none') return false
  if (g.rightStick !== undefined && g.rightStick !== 'move' && g.rightStick !== 'look' && g.rightStick !== 'none') return false
  if (g.stickDeadZone !== undefined && !finiteInRange(g.stickDeadZone, 0, 0.95)) return false
  if (g.triggerThreshold !== undefined && !finiteInRange(g.triggerThreshold, 0, 1)) return false
  if (g.lookScale !== undefined && !finiteInRange(g.lookScale, 0.1, 10)) return false
  if (g.buttonMap !== undefined) {
    if (!g.buttonMap || typeof g.buttonMap !== 'object' || Array.isArray(g.buttonMap)) return false
    const names = Object.keys(g.buttonMap)
    if (names.length > 64) return false
    for (let i = 0; i < names.length; i++) {
      const action = g.buttonMap[names[i]]
      if (!action || (action.kind !== 'key' && action.kind !== 'hotbarPrev'
          && action.kind !== 'hotbarNext' && action.kind !== 'none')) return false
      if (action.kind === 'key' && (action.code === undefined || !validOutputCode(action.code))) return false
      if (action.kind !== 'key' && action.code !== undefined) return false
    }
  }
  return true
}

/**
 * 统一纯函数入口：输入不被修改；成功返回完成迁移且完全深拷贝的新对象，失败返回 null。
 * 所有计数、ID 唯一性和深度规则覆盖整棵 children 树，不存在“前 256 个可用、后面静默丢弃”的部分接受。
 */
export function validateAndNormalizeLayout(source: LayoutProfile): LayoutProfile | null {
  if (!source || typeof source.name !== 'string' || source.name.length === 0 || utf8ByteLength(source.name) > 256
      || !Array.isArray(source.controls)) return null
  if (source.version !== undefined && !validInteger(source.version, 1, LAYOUT_PROFILE_VERSION)) return null
  if (source.globalScale !== undefined && !finiteInRange(source.globalScale, 0.5, 2)) return null
  if (source.lookSensitivity !== undefined && !finiteInRange(source.lookSensitivity, 0.3, 3)) return null
  if (source.lookSmoothing !== undefined && !finiteInRange(source.lookSmoothing, 0.1, 1)) return null
  if (source.lookAccel !== undefined && !finiteInRange(source.lookAccel, 0, 1)) return null
  // Native Control Schema v2 要求 deadZone > 0；与编辑器 1% 最小步长统一，避免 ArkTS
  // 接受 0 后运行时整张 schema 被拒绝。合法空 controls 表也遵循同一契约。
  if (source.joystickDeadZone !== undefined && !finiteInRange(source.joystickDeadZone, 0.01, 0.95)) return null
  if (source.globalOpacity !== undefined && !finiteInRange(source.globalOpacity, 0.1, 1)) return null
  const globalScale = source.globalScale ?? 1.0
  const lookSensitivity = source.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY
  const lookSmoothing = source.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING
  const lookAccel = source.lookAccel ?? DEFAULT_LOOK_ACCEL
  const joystickDeadZone = source.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE
  const globalOpacity = source.globalOpacity ?? DEFAULT_GLOBAL_OPACITY
  if (!finiteInRange(globalScale, 0.5, 2) || !finiteInRange(lookSensitivity, 0.3, 3)
      || !finiteInRange(lookSmoothing, 0.1, 1) || !finiteInRange(lookAccel, 0, 1)
      || !finiteInRange(joystickDeadZone, 0.01, 0.95) || !finiteInRange(globalOpacity, 0.1, 1)) return null
  if (!validOptionalBoolean(source.invertY) || !validOptionalBoolean(source.haptic)
      || !validOptionalBoolean(source.isPreset) || !validOptionalBoolean(source.hotbarAutoAdded)
      || !validOptionalBoolean(source.snapEnabled)) return null
  if (source.snapGap !== undefined && !finiteInRange(source.snapGap, 0, 400)) return null
  if (source.snapStrength !== undefined && !finiteInRange(source.snapStrength, 1, 60)) return null
  if (source.targetDevice !== undefined && source.targetDevice !== 'phone' && source.targetDevice !== 'tablet'
      && source.targetDevice !== 'foldable' && source.targetDevice !== 'any') return null
  if (!validGamepadConfig(source.gamepad)) return null

  const state: NormalizeState = { usedIds: new Set<string>(), count: 0 }
  const controls: ControlItem[] = []
  for (let i = 0; i < source.controls.length; i++) {
    const item = normalizeControlItem(source.controls[i], 0, state)
    if (!item) return null
    controls.push(item)
  }
  const result = cloneLayout(source)
  result.version = LAYOUT_PROFILE_VERSION
  result.globalScale = globalScale
  result.lookSensitivity = lookSensitivity
  result.invertY = source.invertY ?? DEFAULT_INVERT_Y
  result.lookSmoothing = lookSmoothing
  result.lookAccel = lookAccel
  result.joystickDeadZone = joystickDeadZone
  result.haptic = source.haptic ?? true
  result.globalOpacity = globalOpacity
  result.targetDevice = source.targetDevice ?? 'any'
  // deviceModel：仅接受合法字符串（≤256 字节），否则清空，防止导入携带异常值。
  result.deviceModel = (typeof source.deviceModel === 'string' && utf8ByteLength(source.deviceModel) <= 256)
    ? source.deviceModel : undefined
  result.controls = controls
  return result
}

/** v1/v2/v3 迁移统一委托给 fail-closed 规范化器；不再原地修改或部分迁移。 */
export function migrateProfile(p: LayoutProfile): LayoutProfile | null {
  return validateAndNormalizeLayout(p)
}

/**
 * UI 重构 2026-05-30：判断某 label 是否是旧版默认的"装饰性符号标签"。
 * 这些符号过去硬编码在默认布局 / 预设里（攻击 ⚔、放置 🛡、跳跃 ▲、潜行 ▼），
 * 重构后改为按键名自动显示，迁移时清掉它们即可让老 profile 跟上新观感。
 */
function isLegacyDecorLabel(label: string): boolean {
  return label === '⚔' || label === '🛡' || label === '▲' || label === '▼'
}

/**
 * 取一个控件的"实际触发键序列"。
 * 优先级：keys[] 非空 → keys；否则 → [keyOrMouse]。
 * 调用方负责处理 keyOrMouse 的鼠标负数编码。
 */
export function effectiveKeys(c: ControlItem): number[] {
  if (c.keys && c.keys.length > 0) return c.keys
  return [c.keyOrMouse]
}

/**
 * Phase C（键鼠适配）：按 id / type 推断默认隐藏条件。
 *
 * 规则（Phase E 修订）：
 *   - joystick：接键盘后隐藏（接键盘有 WASD 走路；只接鼠标无键盘时摇杆仍可用）
 *   - 滚轮 SCROLL_WHEEL：接鼠标就隐（鼠标硬件滚轮替代）
 *   - hotbar (id 以 'hb' 开头)：键鼠都接才隐（单接鼠标时仍需虚拟 hotbar 切手中物）
 *   - 鼠标按键类（keyOrMouse < 0）：接鼠标就隐
 *   - 普通键盘按钮（keyOrMouse > 0）：接键盘就隐
 *   - 其他（如自定义按钮）：[] 永不隐藏
 */
export function inferDefaultHideOnInput(c: ControlItem): HideTrigger[] {
  if (c.id === 'joystick') return ['keyboard']
  if (c.type === ControlType.SCROLL_WHEEL) return ['mouse']
  if (c.id.startsWith('hb')) return ['mouse_and_keyboard']
  // 鼠标按键类：keyOrMouse < 0 或 keys[] 含负数
  const keys = effectiveKeys(c)
  let hasMouseKey = false
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] < 0) { hasMouseKey = true; break }
  }
  if (hasMouseKey) return ['mouse']
  if (c.type === ControlType.BUTTON && c.keyOrMouse > 0) return ['keyboard']
  return []
}

/**
 * Phase C（键鼠适配）：按当前 capability + 用户覆盖判断按钮是否应自动隐藏。
 *
 * ⚠️ **当前没有任何调用方（2026-08-20 全仓核实）。**
 * 这一行原先写着「调用方：GameControls.shouldHideForInputMode」，而那个方法**从不存在**——
 * 它只出现在注释里。真实历史：`hideOnInput` 驱动的"接键鼠自动隐藏虚拟按键"在 2026-06 被
 * 刻意解耦删除，换成 `GameControls.globalVisMode` 那套纯手动三档可见性；删的时候留下了
 * 本函数、`inferDefaultHideOnInput`、以及 `validateAndNormalizeLayout` 里对 `hideOnInput`
 * 的校验/推断/克隆整条链路，全部无消费者。
 *
 * 之所以标注而不直接删：`hideOnInput` 已经**写进用户的持久化布局文件**了
 * （`cloneItem` 会拷它、`inferDefaultHideOnInput` 会给缺省值补上、LayoutEditor 新建按钮时
 * 显式写 `[]`）。删字段要连迁移一起考虑，那是一次独立的决定，不能在读日志的途中顺手做掉。
 * 是否重新接上、还是彻底删除，见 docs/refactor/多输入端架构愿景与改进提案.md。
 *
 * @param c 控件
 * @param hasMouse 当前是否接了鼠标
 * @param hasKeyboard 当前是否接了键盘
 */
export function shouldAutoHide(c: ControlItem, hasMouse: boolean, hasKeyboard: boolean): boolean {
  const ov = c.visibilityOverride ?? 'auto'
  if (ov === 'force_show') return false
  if (ov === 'force_hide') return true
  // auto
  const triggers = c.hideOnInput ?? []
  for (let i = 0; i < triggers.length; i++) {
    const t = triggers[i]
    if (t === 'mouse' && hasMouse) return true
    if (t === 'keyboard' && hasKeyboard) return true
    if (t === 'mouse_and_keyboard' && hasMouse && hasKeyboard) return true
  }
  return false
}

// ==================== F1（2026-07-11）：物品栏直点条 ====================

/** 物品栏默认格数（MC 原版 9 格）。 */
export const HOTBAR_SLOT_COUNT: number = 9

/**
 * 新建一个物品栏直点条控件。默认放屏幕底部中央（可在编辑器「对齐物品栏」精确贴合，或手动调）。
 * 点第 i 格发数字键 GLFW_KEY_1 + i（绝对选格）；grabbedOnly=true 仅游戏中叠在 MC 真实 hotbar 上。
 * keyOrMouse 存首键（GLFW_KEY_1），槽位偏移在 GameControls 触摸处理里算。
 */
// ==================== 系统功能按钮（输入 / 设置 / 显示）====================
// 外观与普通按钮一致（走同一 ButtonView），但由 systemAction 触发应用级功能而非发键。可移动/缩放/
// 改外观，但不可删除，并由 LayoutStore.ensureSystemControls 保证每个方案都存在。
export type SystemAction = 'input' | 'edit' | 'visibility'
export const SYS_INPUT_ID: string = 'ime_chat'   // 沿用历史 id，兼容老存档
export const SYS_EDIT_ID: string = 'sys_edit'
export const SYS_VIS_ID: string = 'sys_vis'

export function systemActionId(action: SystemAction): string {
  if (action === 'input') return SYS_INPUT_ID
  if (action === 'edit') return SYS_EDIT_ID
  return SYS_VIS_ID
}

/** 新建一颗系统功能按钮。input/edit 默认两个场景都显示；visibility 默认仅游戏（隐藏切换只在游戏内需要）。 */
export function makeSystemButton(action: SystemAction, xPct: number, yPct: number, alignIndex: number): ControlItem {
  return {
    id: systemActionId(action),
    label: action === 'input' ? '输入' : (action === 'edit' ? '设置' : '显示'),
    type: ControlType.BUTTON,
    systemAction: action,
    // 仅 input 需要一个真实键（默认 T）用于在游戏内打开 MC 聊天；edit/visibility 不发键。
    keyOrMouse: action === 'input' ? GLFW_KEY_T : 0,
    xPct, yPct,
    baseWidth: DEFAULT_BUTTON_SIZE, baseHeight: DEFAULT_BUTTON_SIZE,
    itemScale: 1.0, isCircle: false,
    style: { cornerRadius: DEFAULT_CORNER_RADIUS },
    alignGroup: AlignGroup.FUNC_TOP_RIGHT, alignIndex,
    grabbedOnly: action === 'visibility',
    menuOnly: false
  }
}

export function makeHotbarSelector(xPct: number, yPct: number, baseWidth: number, baseHeight: number): ControlItem {
  return {
    id: 'hotbar_sel',
    label: '',
    type: ControlType.HOTBAR_SELECTOR,
    keyOrMouse: GLFW_KEY_1,
    xPct, yPct,
    baseWidth, baseHeight,
    itemScale: 1.0, isCircle: false,
    style: { cornerRadius: 0.12 },
    alignGroup: AlignGroup.NONE, alignIndex: 0,
    grabbedOnly: true,
    hideOnInput: []
  }
}

/**
 * MC 自动档 guiScale（复刻 Window.calculateScale，guiScale=0/自动）：最大整数 s 使缩放后 UI 仍
 * ≥ 320×240。整数运算，与 MC 一致。wPx/hPx = 物理帧缓冲宽高。用户手动设了 guiScale 档时不适用
 * （编辑器"对齐"按钮假定自动档，最常见；手动档需用户微调）。
 */
export function computeAutoGuiScale(wPx: number, hPx: number): number {
  let i = 1
  while (i < wPx && i < hPx
      && Math.floor(wPx / (i + 1)) >= 320
      && Math.floor(hPx / (i + 1)) >= 240) {
    i++
  }
  return i
}

export interface HotbarRectPx { leftPx: number; topPx: number; widthPx: number; heightPx: number }

/**
 * 计算 MC 真实 hotbar 中 **9 个格子** 的可点击物理像素矩形（逐字复刻 MC 渲染 + Pojav handleGuiBar）。
 *
 * 背景：MC 的 hotbar widget 贴图是 182×22（GUI 缩放坐标，含左右各 1px 边框），绘制在
 *   x0 = floor(sw/2) - 91、y0 = sh - 22（sw=ceil(w/gs)、sh=ceil(h/gs)）。
 * 但真正对应 9 个物品格的区域是去掉边框后的 **180 宽（9×20）**，起点 = x0 + 1 = floor(sw/2) - 90。
 * MC 每格 20px、Pojav 的 handleGuiBar 也用 barWidth=180*scale、barX=(W-180*scale)/2、slot=(x-barX)/(20*scale)。
 *
 * 因此这里返回 9 格区域而不是整块 widget：
 *   - leftPx = (floor(sw/2) - 90) * gs
 *   - widthPx = 180 * gs        → native 的 slot = floor((px - x) / (w/9)) 恰好 = (px - x) / (20*gs)，逐格与游戏像素对齐
 * 旧实现返回整块 182 宽，native 再除以 w/9(=20.22*gs)，会产生逐格累积偏移（末格最大 ~2*gs px），
 * 是"点击格与真实 hotbar 对不齐"的根因之一；此处收敛为与 MC/Pojav 完全一致的精确模型。
 * 竖直方向仍返回完整 22 高，方便命中判定与半透明视觉条覆盖 MC hotbar。
 */
export function computeHotbarRectPx(wPx: number, hPx: number, guiScale: number): HotbarRectPx {
  const gs = guiScale < 1 ? 1 : guiScale
  const sw = Math.ceil(wPx / gs)
  const sh = Math.ceil(hPx / gs)
  const slotLeft = Math.floor(sw / 2) - 90   // widget 左缘 floor(sw/2)-91 去掉 1px 边框
  const widthPx = 180 * gs
  const heightPx = 22 * gs
  // 关键：MC 用 sh=ceil(h/gs)，绘制底边在 sh*gs，当 h 不是 gs 整数倍时 sh*gs > h，hotbar 底边会
  // 略微超出帧缓冲（MC 自身会裁剪到屏幕底）。若我们照搬未裁剪的 (sh-22)*gs，控件 y+h 会超过 compH，
  // native 的 schema 校验 (e.y+e.h > compH+1) 会**拒绝整张表**，导致所有控件（不止 hotbar）全部失效。
  // 因此这里把矩形夹进 [0,wPx]×[0,hPx]：既贴合 MC 可见 hotbar（底部对齐），又保证 schema 恒合法。
  let leftPx = slotLeft * gs
  let topPx = (sh - 22) * gs
  if (leftPx + widthPx > wPx) leftPx = wPx - widthPx
  if (leftPx < 0) leftPx = 0
  if (topPx + heightPx > hPx) topPx = hPx - heightPx
  if (topPx < 0) topPx = 0
  return { leftPx, topPx, widthPx, heightPx }
}

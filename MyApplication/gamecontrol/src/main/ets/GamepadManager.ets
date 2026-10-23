import { AppLogger } from 'commons';
/**
 * GamepadManager.ets — 游戏手柄输入归一化（v3 手柄打底）
 *
 * 平台事实（docs/guides/input-system-unified-direction-2026-05-29.md §2.4，已对照本机 SDK；⚠️ 那份文档已部分过期见其横幅，§2.4 仍成立，但轴范围与符号官方未写、只能真机取证 —— 当前契约以 docs/refactor/输入架构规范.md 为准）：
 *   - 手柄按键经组件 onKeyEvent 上报，键值 = KEYCODE_BUTTON_* / KEYCODE_DPAD_*。
 *   - 摇杆 / 扳机（模拟轴）经组件 onFocusAxisEvent 上报：
 *       FocusAxisEvent.axisMap: Map<AxisModel, number>，AxisModel 自 API 15 起可用。
 *       ABS_X/Y=左摇杆  ABS_Z/RZ=右摇杆  ABS_GAS=RT  ABS_BRAKE=LT  ABS_HAT0X/Y=方向键
 *
 * 本类把这两路输入归一化成 MC 能消费的 GLFW 事件，通过 emit* 回调交给 McGamePage 发 NAPI：
 *   - 按钮 → buttonMap → GLFW key / 鼠标 / hotbar 切换
 *   - 左摇杆 → 八向 WASD（复用与触摸摇杆一致的扇区逻辑）
 *   - 右摇杆 → 按设备保留速度状态，由GameInputRuntime用单调时钟积分视角增量
 *   - 扳机 → 过阈值视为按下 / 松开（发对应动作的 PRESS/RELEASE）
 *
 * 设计要点：
 *   - 无 ArkUI 依赖（纯逻辑 + emit 回调），由 GamepadManager.test.ets 覆盖状态安全契约。
 *   - 按设备维护 logical contributors，并在映射输出层聚合，保证首 PRESS / 末 RELEASE。
 *   - OHOS keyCode 常量来自 OhosKeyCodes.ets（SSOT）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D,
  isMouseCode, decodeMouse,
  SCROLL_YOFFSET_UP, SCROLL_YOFFSET_DOWN
} from './GlfwKeys'
import {
  GamepadConfig, GamepadButton, GamepadAction, StickRole,
  defaultGamepadButtonMap, DEFAULT_GAMEPAD_DEAD_ZONE, DEFAULT_TRIGGER_THRESHOLD
} from './ControlLayout'
import {
  OHOS_BUTTON_A, OHOS_BUTTON_B, OHOS_BUTTON_X, OHOS_BUTTON_Y,
  OHOS_BUTTON_L1, OHOS_BUTTON_R1, OHOS_BUTTON_L2, OHOS_BUTTON_R2,
  OHOS_BUTTON_SELECT, OHOS_BUTTON_START, OHOS_BUTTON_MODE,
  OHOS_BUTTON_THUMBL, OHOS_BUTTON_THUMBR,
  OHOS_DPAD_UP, OHOS_DPAD_DOWN, OHOS_DPAD_LEFT, OHOS_DPAD_RIGHT
} from './OhosKeyCodes'
import { AmclInputSource, InputEnd } from './InputSourceRegistry'
import { normalizeDeviceId } from './InputDeviceAbi'
import { joystickSector } from './JoystickSector'
import { gamepadBehaviorKey } from './InputConfiguration'
import { InputDeviceConnectionLease, InputDeviceConnectionReader, GamepadAxisSnapshot } from './InputDeviceConnectionLease'

const TAG = 'GamepadManager'

/**
 * GLFW 动作常量（避免依赖 ArkUI；与 GlfwKeys 一致）。
 */
const GLFW_RELEASE_ACTION = 0
const GLFW_PRESS_ACTION = 1

/**
 * 把 OHOS 手柄 keyCode 映射到逻辑按钮名。返回 null = 非手柄按键。
 */
export function ohosKeyToGamepadButton(ohosKey: number): GamepadButton | null {
  switch (ohosKey) {
    case OHOS_BUTTON_A: return 'A'
    case OHOS_BUTTON_B: return 'B'
    case OHOS_BUTTON_X: return 'X'
    case OHOS_BUTTON_Y: return 'Y'
    case OHOS_BUTTON_L1: return 'L1'
    case OHOS_BUTTON_R1: return 'R1'
    case OHOS_BUTTON_L2: return 'L2'
    case OHOS_BUTTON_R2: return 'R2'
    case OHOS_BUTTON_START: return 'START'
    case OHOS_BUTTON_SELECT: return 'SELECT'
    case OHOS_BUTTON_MODE: return 'MODE'
    case OHOS_BUTTON_THUMBL: return 'L3'
    case OHOS_BUTTON_THUMBR: return 'R3'
    case OHOS_DPAD_UP: return 'DPAD_UP'
    case OHOS_DPAD_DOWN: return 'DPAD_DOWN'
    case OHOS_DPAD_LEFT: return 'DPAD_LEFT'
    case OHOS_DPAD_RIGHT: return 'DPAD_RIGHT'
    default: return null
  }
}

export function isGamepadKey(ohosKey: number): boolean {
  return ohosKeyToGamepadButton(ohosKey) !== null
}

/**
 * DPAD 的 4 个方向码在 OHOS 上被**实体键盘方向键和手柄十字键共用**
 * （KEYCODE_DPAD_UP..RIGHT = 2012..2015）。仅凭 keyCode 无法区分来源。
 */
export function isSharedDirectionalKey(ohosKey: number): boolean {
  return ohosKey === OHOS_DPAD_UP || ohosKey === OHOS_DPAD_DOWN ||
    ohosKey === OHOS_DPAD_LEFT || ohosKey === OHOS_DPAD_RIGHT
}

/**
 * 决定一个按键事件应该走手柄归一化，还是走实体键鼠 physical route。
 *
 * 为什么需要它（Phase 3.3 收口 physical route）：
 *   过去只用 `isGamepadKey(keyCode)` 判定，于是**实体键盘的方向键**因为与手柄
 *   十字键共用 keyCode，被整条送进 GamepadManager，永远到不了
 *   physicalKeyTransaction —— 既没有 deviceId/锁存快照，也不参与 core 的 held
 *   owner 与 reset 对账。这正是"physical route 未真正收口"的一个缺口。
 *
 * 判据与边界：
 *   - 非共用码（A/B/X/Y、L1/R1、START…）永远走手柄，与来源无关。
 *   - 共用码只在平台**明确报告** `KeySource.Keyboard` 时判为键盘键。
 *   - `KeySource.Unknown`（以及 JOYSTICK）保持旧行为走手柄：这是**有意保守**，
 *     宁可维持既有手柄可用性，也不因为一个无法证实的来源猜测而让十字键失效。
 *     该歧义在真机（实体键盘 + 手柄同时接入）验证前保持 NOT VERIFIABLE。
 *
 * 失败恢复：本函数是纯判定，无状态。若真机证明某设备报告 Unknown，可只改这里的
 * 判据，不影响 tracker / core / adapter 任何一层。
 */
export function routeKeyToGamepad(ohosKey: number, sourceIsKeyboard: boolean): boolean {
  if (!isGamepadKey(ohosKey)) return false
  if (sourceIsKeyboard && isSharedDirectionalKey(ohosKey)) return false
  return true
}

/**
 * GamepadManager 向外发事件的回调集合（由 McGamePage 注入，内部转 NAPI）。
 */
export interface GamepadEmitter {
  /** 原应用连接贡献入口；缺席只Pending，不能回退raw数字出口。RELEASE仍允许已退lease精确清理。 */
  emitControlForConnection?: (connection: InputDeviceConnectionLease, controlId: string, code: number, action: number) => boolean
  /** 原lease下的Native look子流；applicationScope不当作系统generation或改变公开device字段。 */
  emitLookVelocityForConnection?: (connection: InputDeviceConnectionLease, childLook: number, xPerSecond: number, yPerSecond: number) => boolean
  /** 只取消原lease的原look子流；false保存该子句柄墓碑，不能借新sameid重试。 */
  retireLookForConnection?: (connection: InputDeviceConnectionLease, childLook: number) => boolean
  /** 即时滚轮也携原连接，在入口及回入后验证；脉冲已接受不虚构持有。 */
  emitScrollForConnection?: (connection: InputDeviceConnectionLease, direction: number) => boolean
  /** 显式旧delta模型的连接出口；缺席不把scoped事实送入无连接的全局delta。 */
  emitLookDeltaForConnection?: (connection: InputDeviceConnectionLease, dx: number, dy: number, monotonicNs: number) => boolean
  /** 稳定维护SourceClient在途/未知token墓碑，UI关闭后仍可重试，false保持Pending。 */
  reconcileConnectionControls?: () => boolean
  /** 原lease的Client全部intent先标退休，含尚未返token/未知token；不扩大到兄弟连接。 */
  releaseConnectionControls?: (connection: InputDeviceConnectionLease) => boolean
  /** 准备时冻结的视角执行模型；缺省仅供旧显式兼容端，新模式拒绝时不能偷偷重发delta。 */
  lookExecutionMode?: string
  /** 归一后的每连接virtual counts/s事实；时间由Native owner采样，返回false保留待提交。 */
  emitLookVelocity?: (deviceId: number, connection: number, xPerSecond: number, yPerSecond: number) => boolean
  /** 只推进并封已知Native速率/尾量，不携JS uptime或已积分delta。 */
  advanceLookExecution?: () => boolean
  /** 退休原连接未交付量；未知/已退休幂等，false仍保原连接以便重试。 */
  retireLookConnection?: (deviceId: number, connection: number) => boolean
  /** 产品入口保留每设备/控件贡献者；旧二元 emitter 仅作显式兼容，不能同时双发。 */
  emitControl?: (deviceId: number, controlId: string, code: number, action: number) => boolean
  dropControlsAfterNativeReset?: () => void
  /**
   * 发 GLFW 键事件。action: GLFW_PRESS_ACTION / GLFW_RELEASE_ACTION。
   * 返回 false = native 未改变本端记录（被拒），本类据此不记账、保留原状态以便重试；
   * true / void = 本端持有变更已生效，包括别端也按着同一键、因而未发最终边沿的情形。
   */
  emitKey: (glfwKey: number, action: number) => boolean | void
  /** 发 GLFW 鼠标按钮事件；返回值契约同 emitKey。 */
  emitMouse: (glfwButton: number, action: number) => boolean | void
  /** 发滚轮（切手中物）。dir：+1 上一格 / -1 下一格。 */
  emitScroll: (dir: number) => boolean | void
  /** 发按时间积分的视角增量；仅已乘手柄lookScale，公共灵敏度由native处理。 */
  emitLookDelta: (dx: number, dy: number, monotonicNs?: number) => boolean | void
}

/**
 * AxisModel 数值（与 ArkUI enums.d.ts 一致；这里用裸数字避免 import ArkUI 类型到 service 层）。
 * ABS_X=0 ABS_Y=1 ABS_Z=2 ABS_RZ=3 ABS_GAS=4 ABS_BRAKE=5 ABS_HAT0X=6 ABS_HAT0Y=7
 */
export const AXIS_ABS_X = 0
export const AXIS_ABS_Y = 1
export const AXIS_ABS_Z = 2
export const AXIS_ABS_RZ = 3
export const AXIS_ABS_GAS = 4
export const AXIS_ABS_BRAKE = 5
export const AXIS_ABS_HAT0X = 6
export const AXIS_ABS_HAT0Y = 7

/**
 * 映射视角速度（像素/秒）：保留旧60Hz设备上18px/sample的手感，但不再依赖事件频率。
 * Native仍负责公共灵敏度/倒置/平滑；这里只积分摇杆速度和手柄专属lookScale。
 */
const RIGHT_STICK_LOOK_GAIN = 1080

/**
 * 离散动作的保守迟滞带。它们只稳定既有八向/扳机映射，不推断平台设备校准值：
 * 扳机和移动半径的退出边界最多低于用户进入阈值满量程的2%，且不超过阈值的一半；
 * 八向切换需越过旧扇区边界3度。真实归零始终释放，0阈值仍表示任意正行程可触发。
 * 华为文档仅规定轴事件/API事实，并未要求这些算法或参数；具体型号手感仍需实体确认。
 */
const ANALOG_RELEASE_HYSTERESIS = 0.02
const MOVE_SECTOR_HYSTERESIS_DEGREES = 3

// The existing product ingress has no proven gamepad identity yet. Keep its
// historical single bucket at 0 while exposing device-scoped entry points for
// callers that do have a session-local identity.
const COMPAT_GAMEPAD_DEVICE_ID: number = 0
const CONTRIBUTOR_DIGITAL: string = 'digital'
const CONTRIBUTOR_TRIGGER_AXIS: string = 'trigger-axis'
const CONTRIBUTOR_HAT_AXIS: string = 'hat-axis'

class PressedRecord {
  isMouse: boolean = false
  code: number = 0
}

class MappedOutputAggregate {
  isMouse: boolean = false
  code: number = 0
  contributors: Set<string> = new Set<string>()
}

/** 每次输入/退休换一个原样本围栏对象，防同步回入的新事实让旧正文继续提交；没有数字代回绕。 */
class GamepadStateInputFence {}

class GamepadDeviceState {
  readonly deviceId: number
  readonly connection: InputDeviceConnectionLease | undefined
  inputFence: GamepadStateInputFence = new GamepadStateInputFence()
  retiring: boolean = false
  inFlight: number = 0
  cleanupRunning: boolean = false
  lookRetiringInFlight: boolean = false
  /** 已接受但在返回时失去原样本资格的输出只留清理记录，不进入live aggregate。 */
  pendingControlReleases: Map<string, PressedRecord> = new Map<string, PressedRecord>()
  releasingControls: Set<string> = new Set<string>()
  /** 正常UP在途回入的最新逻辑事实；不计作Native持有，原UP确认后才能取得新token。 */
  pendingControlReentry: Map<GamepadButton, Set<string>> = new Map<GamepadButton, Set<string>>()
  pendingMoveReentry: Map<number, boolean> = new Map<number, boolean>()
  /** 回入desired交接的短时guard；同control新事实只更新desired，不递归重放同一笔Native调用。 */
  settlingReentry: Set<string> = new Set<string>()

  /** 数字桶是显式legacy兼容；scoped状态额外持原opaque对象，清理永远使用这份冻结身份。 */
  constructor(deviceId: number, connection?: InputDeviceConnectionLease) {
    this.deviceId = deviceId; this.connection = connection
  }
  /** 本来源实例的原连接，不回绕；中心状态保留连接以让Native正常完成平滑尾量。 */
  lookConnection: number = 0
  lookVelocityDirty: boolean = false
  lookRetirementPending: boolean = false
  /** 最近轴快照归一后的视角速度方向；归中、复位、拔出即清零。 */
  lookX: number = 0
  lookY: number = 0
  /**
   * 各根移动杆自己的已选扇区中心角（0..315，每45度一档；-1=归中/非move）。
   * 它们仅记录轴解释历史，不代表Native已接受方向键；真正持有仍由activeMoveKeys管理。
   * 两根杆不能共享一个迟滞状态，否则一根归中会改变另一根的方向或释放边界。
   */
  leftMoveDirection: number = -1
  rightMoveDirection: number = -1
  // One logical control may be reported by two platform channels: L2/R2 as a
  // digital key and an analog trigger, DPAD as key codes and HAT axes. Their OR
  // owns one mapped output contributor, so the first channel down presses and
  // the last channel up releases.
  controlContributors: Map<string, Set<string>> = new Map<string, Set<string>>()
  pressedControls: Map<string, PressedRecord> = new Map<string, PressedRecord>()
  activeMoveKeys: Set<number> = new Set<number>()

  isEmpty(): boolean {
    return this.inFlight === 0 && this.pendingControlReleases.size === 0 && this.pendingControlReentry.size === 0 &&
      this.pendingMoveReentry.size === 0 && this.controlContributors.size === 0 &&
      this.pressedControls.size === 0 && this.activeMoveKeys.size === 0 &&
      this.leftMoveDirection < 0 && this.rightMoveDirection < 0 &&
      this.lookX === 0 && this.lookY === 0 && this.lookConnection === 0 && !this.lookRetirementPending
  }
}

/**
 * 手柄端。它是三个平级输入端之一（见 cpp/platform/input_source.h 与
 * InputSourceRegistry.ets），实现 `InputEnd` 以便所有复位边界能对它一视同仁。
 *
 * 刻意保持**零 ArkUI 依赖、零 NAPI 依赖**：输出经注入的 emitter 走出去，
 * 端级 native 记账由注册表负责。这样本类可以单测，也不会把 HAR 绑死在宿主的 NAPI 上。
 */
export class GamepadManager implements InputEnd {
  readonly inputSource: AmclInputSource = AmclInputSource.Gamepad
  readonly endName: string = 'GamepadManager'

  private mappedOutputEnabled: boolean = true
  /**
   * 只读本来源路线的真实应用开关。配置enabled可暂时禁用映射功能，因此isEnabled()
   * 不能作为路线应用回执；拒绝旧RELEASE时这里仍返回原值，宿主必须保留Pending。
   * 此读取不重试释放、不改owner/轴，也不证明原生consumer或游戏模组已使用。
   */
  isMappedOutputEnabled(): boolean { return this.mappedOutputEnabled }

  /** 路线切换先按原冻结输出释放；未确认的持有保留原路线，下一次由宿主显式重试。 */
  setMappedOutputEnabled(enabled: boolean): void {
    if (this.mappedOutputEnabled === enabled) return
    this.releaseAll()
    if (this.hasAnyDeviceState()) return
    this.mappedOutputEnabled = enabled
  }

  private cfg: GamepadConfig
  private emitter: GamepadEmitter
  /** 模型由宿主准备时明确选择；临时NotReady/拒绝不会使它转回旧积分并双发。 */
  private readonly sharedLookExecution: boolean
  private nextLookConnection: number = 1
  private devices: Map<number, GamepadDeviceState> = new Map<number, GamepadDeviceState>()
  private connectionDevices: Map<InputDeviceConnectionLease, GamepadDeviceState> = new Map<InputDeviceConnectionLease, GamepadDeviceState>()
  /** reset同步回入后才返回的已接受输出也保留原清理owner，不覆盖后来同lease创建的新state。 */
  private pendingCleanupStates: Set<GamepadDeviceState> = new Set<GamepadDeviceState>()
  private connectionReader: InputDeviceConnectionReader | undefined
  private resetting: boolean = false
  private connectionCleanupInFlight: Set<InputDeviceConnectionLease> = new Set<InputDeviceConnectionLease>()
  private knownDevices: Set<number> = new Set<number>()
  // 聚合表保各控件/设备的独立贡献。旧binary出口只发首DOWN/末UP；scoped出口每个
  // contributor取得自己的真实token，由共同Native Source归约最终边沿，不能在这里
  // 因同码已经聚合就吞掉新连接的独立持有。
  private outputAggregates: Map<string, MappedOutputAggregate> =
    new Map<string, MappedOutputAggregate>()

  constructor(cfg: GamepadConfig | undefined, emitter: GamepadEmitter, connectionReader?: InputDeviceConnectionReader) {
    this.connectionReader = connectionReader
    // 私有新契约只认识这两种执行模型；未知声明不能被当旧兼容并输出另一条路线。
    if (emitter.lookExecutionMode !== undefined && emitter.lookExecutionMode !== 'neutral-rate-v1' &&
      emitter.lookExecutionMode !== 'legacy-delta') throw new Error('Invalid mapped look execution model')
    this.cfg = GamepadManager.normalizeConfig(cfg)
    this.emitter = emitter
    this.sharedLookExecution = emitter.lookExecutionMode === 'neutral-rate-v1'
  }

  /**
   * profile 变化时更新配置。
   *
   * 先按旧配置释放全部持有态，再切换映射。否则一个已按下的逻辑按钮在
   * buttonMap / stick role / enabled 变化后会丢失它原先的 RELEASE 目标，留下卡键。
   */
  updateConfig(cfg: GamepadConfig | undefined): boolean {
    const next: GamepadConfig = GamepadManager.normalizeConfig(cfg)
    // 配置广播可以由按钮文案/外观触发；本域语义未变时保持设备轴与持有，不能无谓松键。
    if (gamepadBehaviorKey(next) === gamepadBehaviorKey(this.cfg)) return true
    this.releaseAll()
    // native 拒绝旧 RELEASE 时保留旧配置与 DOWN-time 映射，禁止一边仍持有旧 owner、
    // 一边切到新映射。下次 update/lifecycle release 会继续重试。
    if (this.hasAnyDeviceState()) return false
    this.cfg = next
    return true
  }

  isEnabled(): boolean {
    return !this.resetting && this.cfg.enabled !== false && this.mappedOutputEnabled
  }

  /**
   * 处理手柄按键。返回 true 表示这是手柄按键（已消费）。
   * @param ohosKey OHOS keyCode
   * @param isDown  true=按下 false=抬起
   */
  handleButton(ohosKey: number, isDown: boolean): boolean {
    return this.handleButtonForDevice(COMPAT_GAMEPAD_DEVICE_ID, ohosKey, isDown)
  }

  /** 旧raw按钮兼容入口：deviceId=0是显式匿名桶，不能据数字相同取得原连接资格。 */
  handleButtonForDevice(deviceId: number, ohosKey: number, isDown: boolean): boolean {
    const btn = ohosKeyToGamepadButton(ohosKey)
    if (btn === null) return false
    if (!this.isEnabled()) return true
    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    if (normalizedDeviceId !== COMPAT_GAMEPAD_DEVICE_ID) this.knownDevices.add(normalizedDeviceId)
    const state = this.deviceState(normalizedDeviceId)
    // 旧raw API明确只具兼容数字桶语义；新的一次事实不继承上一轮正文的样本围栏。
    state.retiring = false
    const fence = this.beginStateSample(state)
    this.setControlContributor(normalizedDeviceId, state, btn, CONTRIBUTOR_DIGITAL, isDown, fence)
    this.pruneDeviceState(normalizedDeviceId, state)
    return true
  }

  /** 按原lease处理按钮。已退/known0只消费而不输出；新sameid必须持新的原对象。 */
  handleButtonForConnection(connection: InputDeviceConnectionLease, ohosKey: number, isDown: boolean): boolean {
    const btn = ohosKeyToGamepadButton(ohosKey)
    if (btn === null) return false
    if (!this.isEnabled() || !this.acceptsConnection(connection)) return true
    const state = this.connectionState(connection)
    if (state.retiring) return true
    const fence = this.beginStateSample(state)
    this.setControlContributor(connection.rawPlatformId, state, btn, CONTRIBUTOR_DIGITAL, isDown, fence)
    this.pruneDeviceState(connection.rawPlatformId, state)
    return true
  }

  /**
   * 处理一帧摇杆 / 扳机轴值。
   * @param getAxis 给定 AxisModel 数值返回轴值（[-1,1]，扳机 [0,1]），无值返回 undefined。
   */
  handleAxis(getAxis: (axis: number) => number | undefined): void {
    this.handleAxisForDevice(COMPAT_GAMEPAD_DEVICE_ID, getAxis)
  }

  /** 旧raw轴兼容入口：先复制完整轴帧，缺轴沿原中心值语义；共同归约仍保原拒绝重试。 */
  handleAxisForDevice(deviceId: number, getAxis: (axis: number) => number | undefined): void {
    if (!this.isEnabled()) return
    // 原8轴一次复制完才可能进入维护/emitter；旧兼容算法仍用同一sanitize/映射正文。
    const snapshot = new GamepadAxisSnapshot(getAxis)
    if (!this.isEnabled()) return
    const normalizedDeviceId = GamepadManager.normalizeGamepadDeviceId(deviceId)
    if (normalizedDeviceId !== COMPAT_GAMEPAD_DEVICE_ID) this.knownDevices.add(normalizedDeviceId)
    const state = this.deviceState(normalizedDeviceId)
    state.retiring = false
    this.handleAxisState(normalizedDeviceId, state, snapshot, this.beginStateSample(state))
    this.pruneDeviceState(normalizedDeviceId, state)
  }

  /** 只接第一入口已经冻结的八轴事实；metadata/timer不能再读后来event map。 */
  handleAxisForConnection(connection: InputDeviceConnectionLease, snapshot: GamepadAxisSnapshot): void {
    if (!this.isEnabled() || !this.acceptsConnection(connection)) return
    const state = this.connectionState(connection)
    if (state.retiring) return
    this.handleAxisState(connection.rawPlatformId, state, snapshot, this.beginStateSample(state))
    // 同步回入可使共同轴正文提前返回；仍以精确原state检查清掉已经确认的空桶。
    this.pruneDeviceState(connection.rawPlatformId, state)
  }

  /** 两条入口共用生产轴归一正文；每笔输出之后重新核原样本，避免同步退休后继续扳机/HAT。 */
  private handleAxisState(deviceId: number, state: GamepadDeviceState, snapshot: GamepadAxisSnapshot,
    fence: GamepadStateInputFence): void {
    if (!this.acceptsStateSample(state, fence)) return
    const dz = this.cfg.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE

    // 先保留原二维方向。分别对X/Y减死区会旋转向量，并让推深相同方向的杆改变八向判定。
    // 仍使用现有经典轴和既有[-1,1]防御边界，不从其他API或无实体的型号推测新轴范围。
    const lx = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_X))
    const ly = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_Y))
    const rx = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_Z))
    const ry = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_RZ))

    // 两根摇杆都可被配成 move。先聚合两者期望的方向键，再一次更新；
    // 若逐根调 updateMoveKeys，后处理的居中摇杆会把前一根刚按下的键释放掉。
    const desiredMoveKeys: Set<number> = new Set<number>()
    state.lookX = 0
    state.lookY = 0
    // 视角是连续量：仅按合成半径缩放死区，保留角度，并把每根杆的满行程限制在单位圆。
    // 不把移动的离散迟滞套到look上，归中后的视角速度严格为0，不能留下低速漂移。
    if (this.cfg.leftStick === 'look') {
      const scale = GamepadManager.radialDeadZoneScale(lx, ly, dz)
      state.lookX += lx * scale; state.lookY += ly * scale
    }
    if (this.cfg.rightStick === 'look') {
      const scale = GamepadManager.radialDeadZoneScale(rx, ry, dz)
      state.lookX += rx * scale; state.lookY += ry * scale
    }
    // 同一轴快照可能同时改变视角和触发WASD/扳机。先提交速度边界，Native原action批次
    // 才能推进此前速率到此刻；不能等16ms timer之后再把旧look放到按钮另一侧。
    if (this.sharedLookExecution) {
      state.lookVelocityDirty = state.lookX !== 0 || state.lookY !== 0 || state.lookConnection !== 0
      this.publishLookVelocity(deviceId, state)
      if (!this.acceptsStateSample(state, fence)) return
    }
    state.leftMoveDirection = this.applyStick(this.cfg.leftStick ?? 'move', lx, ly, dz,
      state.leftMoveDirection, desiredMoveKeys)
    state.rightMoveDirection = this.applyStick(this.cfg.rightStick ?? 'look', rx, ry, dz,
      state.rightMoveDirection, desiredMoveKeys)
    this.updateMoveKeys(deviceId, state, desiredMoveKeys, fence)
    if (!this.acceptsStateSample(state, fence)) return

    // ---- 扳机 ----
    const thr = this.cfg.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD
    this.applyTrigger(deviceId, state, 'L2',
      GamepadManager.sanitizeTriggerAxis(snapshot.get(AXIS_ABS_BRAKE)), thr, fence)
    if (!this.acceptsStateSample(state, fence)) return
    this.applyTrigger(deviceId, state, 'R2',
      GamepadManager.sanitizeTriggerAxis(snapshot.get(AXIS_ABS_GAS)), thr, fence)
    if (!this.acceptsStateSample(state, fence)) return

    // ---- 方向键走轴（部分手柄）：HAT 当离散方向，映射到 buttonMap 的 DPAD_* ----
    const hatX = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_HAT0X))
    const hatY = GamepadManager.sanitizeSignedAxis(snapshot.get(AXIS_ABS_HAT0Y))
    this.applyHat(deviceId, state, 'DPAD_LEFT', 'DPAD_RIGHT', hatX, fence)
    if (!this.acceptsStateSample(state, fence)) return
    this.applyHat(deviceId, state, 'DPAD_UP', 'DPAD_DOWN', hatY, fence)
    this.pruneDeviceState(deviceId, state)
  }

  /**
   * 释放所有按下中的手柄状态（grabbed 翻转 / 失焦 / 切后台 / 拔手柄时调）。
   *
   * 幂等：集合清空后重复调用是 no-op，所以"页面隐藏 + Ability 后台"叠加触发无害。
   * 发出的 RELEASE 与本端自己的 PRESS 配对，因此**必须在 native cancelAllInput 之前**
   * 调用（顺序理由见 InputSourceRegistry.ets 的"顺序纪律"一节）。
   */
  releaseAll(): void {
    const states = this.allStates()
    for (const state of states) this.releaseState(state)
  }

  /** 显式legacy数字桶清理；没有opaque硬件连接代，不能用于scoped新连接的定向退休。 */
  releaseDevice(deviceId: number): void {
    const normalizedDeviceId = GamepadManager.normalizeGamepadDeviceId(deviceId)
    const state = this.devices.get(normalizedDeviceId)
    if (state === undefined) { this.knownDevices.delete(normalizedDeviceId); return }
    this.releaseState(state)
    if (!this.devices.has(normalizedDeviceId)) this.knownDevices.delete(normalizedDeviceId)
  }

  /** 原lease的清理权限独立于输入准入；false保原token/子流墓碑，不lookup新sameid。 */
  releaseConnection(connection: InputDeviceConnectionLease, _reason: string = 'device-remove'): boolean {
    const states = this.allStates().filter((state: GamepadDeviceState): boolean => state.connection === connection)
    // 先围栏所有原state，Client回调同步进来的旧轴/按钮不能趁清理阶段再产生输入。
    for (const state of states) { state.retiring = true; state.inputFence = new GamepadStateInputFence() }
    if (this.connectionCleanupInFlight.has(connection)) return false
    this.connectionCleanupInFlight.add(connection)
    let completed: boolean = true
    try {
      try { if (this.emitter.releaseConnectionControls?.(connection) === false) completed = false }
      catch (_) { completed = false }
      for (const state of states) if (!this.releaseState(state)) completed = false
    } finally { this.connectionCleanupInFlight.delete(connection) }
    return completed
  }

  /** 只读输入资格。known hardware0保NativePending；只能明确compatibility lease使用compat0。 */
  acceptsConnection(connection: InputDeviceConnectionLease): boolean {
    const reader = this.connectionReader
    return !this.resetting && reader !== undefined && reader.accepts(connection) && reader.allowsLegacyDeviceField(connection)
  }

  /** 只读原对象是否仍有live状态或清理墓碑，不用rawID去认领新state。 */
  hasConnectionState(connection: InputDeviceConnectionLease): boolean {
    return this.allStates().some((state: GamepadDeviceState): boolean => state.connection === connection)
  }

  /** 稳定维护Client未知token及Manager旧输出墓碑，retired scope只清理不产生新的PRESS/速度。 */
  reconcileConnectionCleanup(): boolean {
    let completed: boolean = true
    try { if (this.emitter.reconcileConnectionControls?.() === false) completed = false }
    catch (_) { completed = false }
    for (const state of this.allStates()) {
      if (state.connection !== undefined && !this.acceptsConnection(state.connection)) state.retiring = true
      if (state.retiring && !this.releaseState(state)) completed = false
      if (!state.retiring) {
        // 样本被兄弟输入替代而原lease仍live时，只清理该样本已接受的原输出，不退休兄弟。
        for (const entry of Array.from(state.pendingControlReleases.entries())) {
          if (this.emitOriginalControlRelease(state, entry[0], entry[1])) {
            if (state.pendingControlReleases.get(entry[0]) === entry[1]) state.pendingControlReleases.delete(entry[0])
          } else completed = false
        }
        // 稳定维护只提交此前实际收到的原连接事实；压力拒绝仍保原UP/desired，不靠新输入排空。
        for (const control of Array.from(state.pendingControlReentry.keys())) {
          if (!this.settleControlReentry(state.deviceId, state, control)) completed = false
        }
        for (const key of Array.from(state.pendingMoveReentry.keys())) {
          if (!this.settleMoveReentry(state.deviceId, state, key)) completed = false
        }
        this.pruneDeviceState(state.deviceId, state)
      }
    }
    return completed
  }

  /** 共同退休正文。先换原样本围栏并归零轴，inFlight期间不prune；所有失败仍保原身份。 */
  private releaseState(state: GamepadDeviceState): boolean {
    state.retiring = true; state.inputFence = new GamepadStateInputFence()
    // 整资源退休撤销未取得token的回入desired；不能在旧lease cleanup之后继续补新PRESS。
    state.pendingControlReentry.clear(); state.pendingMoveReentry.clear()
    state.lookX = 0; state.lookY = 0
    // 配置切换、失焦、停用和断开都从新接触重新解释，不让旧扇区降低下一轮进入门槛。
    state.leftMoveDirection = -1; state.rightMoveDirection = -1
    if (this.sharedLookExecution && state.lookConnection !== 0) {
      state.lookVelocityDirty = false; state.lookRetirementPending = true
    }
    // release emitter也可能同步回入本退休入口；嵌套只保Pending，不能递归发同一个UP。
    if (state.cleanupRunning) return false
    state.cleanupRunning = true
    try {
      if (state.lookRetirementPending) this.retireLookConnection(state.deviceId, state)
      const remainingControls: Map<string, Set<string>> = new Map<string, Set<string>>()
      const remainingPressed: Map<string, PressedRecord> = new Map<string, PressedRecord>()
      state.pressedControls.forEach((record: PressedRecord, control: string): void => {
        const contributorId = GamepadManager.controlContributorId(state.deviceId, control, state.connection)
        if (!this.releaseMappedOutput(record, contributorId, state.deviceId, state)) {
          remainingPressed.set(control, record)
          const contributors = state.controlContributors.get(control)
          if (contributors !== undefined) remainingControls.set(control, contributors)
        }
      })
      state.pressedControls = remainingPressed; state.controlContributors = remainingControls
      const remainingMoveKeys: Set<number> = new Set<number>()
      state.activeMoveKeys.forEach((key: number): void => {
        const record = GamepadManager.keyRecord(key)
        const contributorId = GamepadManager.moveContributorId(state.deviceId, key, state.connection)
        if (!this.releaseMappedOutput(record, contributorId, state.deviceId, state)) remainingMoveKeys.add(key)
      })
      state.activeMoveKeys = remainingMoveKeys
      const pending = Array.from(state.pendingControlReleases.entries())
      for (const entry of pending) {
        if (this.emitOriginalControlRelease(state, entry[0], entry[1])) state.pendingControlReleases.delete(entry[0])
      }
    } finally { state.cleanupRunning = false }
    this.pruneDeviceState(state.deviceId, state)
    return state.isEmpty()
  }

  /** Whether this normalized device bucket still owns any logical input state. */
  hasDeviceState(deviceId: number): boolean {
    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    return this.devices.has(normalizedDeviceId)
  }

  /** Event-domain identity observed during this connection, even when currently idle. */
  knowsDevice(deviceId: number): boolean {
    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    return normalizedDeviceId !== COMPAT_GAMEPAD_DEVICE_ID &&
      this.knownDevices.has(normalizedDeviceId)
  }

  /** InputEnd 契约：ArkTS 先归零，发出与自己 PRESS 配对的 RELEASE。 */
  releaseAllInputs(reason: string): void {
    const hadState: boolean = this.hasAnyDeviceState()
    this.releaseAll()
    if (hadState) {
      const remaining: number = this.heldStateCount()
      if (remaining === 0) {
        hilog.info(0x0000, TAG, 'released all inputs reason=%{public}s', reason)
      } else {
        AppLogger.warn(TAG, `release incomplete reason=${reason} remaining=${remaining}`)
      }
    }
  }

  /**
   * InputEnd 契约：native 先归零，只丢弃本端缓存、**不发任何边沿**。
   *
   * 为什么不能直接调 releaseAll：那条路径会经 emitter 逐键发一批 RELEASE，而本端此刻
   * 已经不知道 native 那边还剩什么，逐键补发只会往跨语言边界灌一批可能无配对的调用。
   * 语义上也不对：本端的职责是"承认 native 已归零"，不是再复位一次。
   *
   * ⚠️ **但"native 已归零"这件事本端不能假设，它由注册表负责强制**（2026-08-21）：
   * `InputSourceRegistry.dropAllEndStateAfterNativeReset` 在广播完本方法之后会对三个真实端
   * 各调一次按端释放原语 `releaseSourceHeld`，把 external 表里可能残留的持有记录清干净。
   * 原因是驱动对账的 reset epoch 有两个语义（typed core 自己的 RESET / 完整 legacy cancel
   * 收口），前者**不**清 external held 与 ledger —— 而 surface 几何变化只产生前者。
   * 详细因果与卡键机制写在注册表那个方法上方，不在这里重复。
   *
   * 本端**刻意不**自己调那个原语：`GamepadManager` 要保持零 ArkUI / 零 NAPI 依赖
   * （见文件头），跨语言调用一律经宿主注入的 emitter 或注册表的 native 接缝。
   */
  dropHeldStateAfterNativeReset(reason: string): void {
    const hadState = this.hasAnyDeviceState()
    this.resetting = true
    // Native reset覆盖已知记录；尚在调用中的原state先fence，返后新取得的token仍需精确清理。
    for (const state of this.allStates()) {
      state.retiring = true; state.inputFence = new GamepadStateInputFence()
      state.pendingControlReentry.clear(); state.pendingMoveReentry.clear()
    }
    try { this.emitter.dropControlsAfterNativeReset?.() }
    finally {
      this.devices.clear(); this.connectionDevices.clear(); this.pendingCleanupStates.clear()
      this.outputAggregates.clear(); this.resetting = false
    }
    if (hadState) hilog.info(0x0000, TAG, 'dropped held cache after native reset reason=%{public}s', reason)
  }

  // ============ 内部 ============

  private resolveButton(btn: GamepadButton): GamepadAction | undefined {
    const map = this.cfg.buttonMap
    if (map && map[btn]) return map[btn]
    return undefined
  }

  private setControlContributor(deviceId: number, state: GamepadDeviceState,
    btn: GamepadButton, contributor: string, isDown: boolean, fence: GamepadStateInputFence,
    replaying: boolean = false): boolean {
    if (!this.acceptsStateSample(state, fence)) return false
    const contributorId: string = GamepadManager.controlContributorId(deviceId, btn, state.connection)
    if (state.releasingControls.has(contributorId) || (!replaying && state.pendingControlReentry.has(btn))) {
      // 在途旧UP尚未返Native回执，duplicate-DOWN不能借旧logical/token称接受；仅冻结
      // 此原control各真实通道的最新desired，后续同通道UP可撤回，不造假pressed/aggregate。
      let desired = state.pendingControlReentry.get(btn)
      if (desired === undefined) { desired = new Set<string>(); state.pendingControlReentry.set(btn, desired) }
      if (isDown) desired.add(contributor)
      else desired.delete(contributor)
      return state.releasingControls.has(contributorId) || state.settlingReentry.has(contributorId) ? true :
        this.settleControlReentry(deviceId, state, btn)
    }
    let contributors: Set<string> | undefined = state.controlContributors.get(btn)
    if (isDown) {
      if (contributors !== undefined && contributors.has(contributor)) return true
      if (contributors !== undefined && contributors.size > 0) {
        contributors.add(contributor)
        return true
      }

      const action: GamepadAction | undefined = this.resolveButton(btn)
      const replayDesired = replaying ? state.pendingControlReentry.get(btn) : undefined
      // 原desired对象保持到Native返回：兄弟B的新样本只能截断轴续体，不能撤销A仍为true的
      // 独立逻辑事实。同A的UP/真实state退休则立即使本条件失败，不能提交那个已撤的PRESS。
      const stillDesired = replayDesired === undefined ? undefined : (): boolean =>
        this.acceptsStateOwner(state) && state.pendingControlReentry.get(btn) === replayDesired && replayDesired.has(contributor)
      let accepted: boolean | void = true
      let record: PressedRecord | undefined = undefined
      if (action !== undefined && action.kind === 'hotbarPrev') {
        accepted = this.emitScrollForState(state, SCROLL_YOFFSET_UP)
      } else if (action !== undefined && action.kind === 'hotbarNext') {
        accepted = this.emitScrollForState(state, SCROLL_YOFFSET_DOWN)
      } else if (action !== undefined && action.kind === 'key') {
        const configuredCode: number = action.code ?? 0
        if (configuredCode !== 0) {
          record = GamepadManager.mappedRecord(configuredCode)
          accepted = this.acquireMappedOutput(record, contributorId, deviceId, state, fence, stillDesired)
        }
      }
      if (accepted === false || (!this.acceptsStateSample(state, fence) && stillDesired?.() !== true)) return false

      contributors = new Set<string>()
      contributors.add(contributor)
      state.controlContributors.set(btn, contributors)
      if (record !== undefined) state.pressedControls.set(btn, record)
      return true
    }

    if (contributors === undefined || !contributors.has(contributor)) return true
    if (contributors.size > 1) {
      contributors.delete(contributor)
      return true
    }

    const record: PressedRecord | undefined = state.pressedControls.get(btn)
    if (record !== undefined) {
      // 最后一路UP的desired先变空，旧Native/logical记录仍保到回执确认。即使这次拒绝后
      // Client在下一次稳定维护先释放token，回入DOWN也会命中待定集合而非旧duplicate分支。
      state.pendingControlReentry.set(btn, new Set<string>())
      if (!this.releaseMappedOutput(record, contributorId, deviceId, state)) {
        // 原binary兼容端无Client退休intent；没有回入desired时保持旧“下一UP/releaseAll”
        // 重试次数，不因新的交接设施让同一轴帧后的legacy积分额外发送一次UP。
        if (state.connection === undefined && this.emitter.emitControl === undefined &&
          state.pendingControlReentry.get(btn)?.size === 0) state.pendingControlReentry.delete(btn)
        return false
      }
      // 真实UP已经确认，必须提交原record的退休；别的输入换sample fence不能令旧缓存
      // 复活。回入的新同control事实在上面单独待定，不能被这里的旧回执一并删除。
      if (state.pressedControls.get(btn) === record) state.pressedControls.delete(btn)
    }
    contributors.delete(contributor)
    if (state.controlContributors.get(btn) === contributors) state.controlContributors.delete(btn)
    if (state.pendingControlReentry.has(btn)) this.settleControlReentry(deviceId, state, btn)
    return true
  }

  /**
   * 同control旧UP与新desired串行。重试只针对原record；明确拒绝保两份事实，不把新DOWN
   * 当旧token幂等。原UP确认后按真实最新通道集合补PRESS，失败只保desired，不声称held。
   */
  private settleControlReentry(deviceId: number, state: GamepadDeviceState, btn: GamepadButton): boolean {
    const desired = state.pendingControlReentry.get(btn)
    if (desired === undefined) return true
    const contributorId: string = GamepadManager.controlContributorId(deviceId, btn, state.connection)
    if (state.releasingControls.has(contributorId) || state.settlingReentry.has(contributorId) || !this.acceptsStateOwner(state)) return false
    state.settlingReentry.add(contributorId)
    try {
      const oldRecord = state.pressedControls.get(btn), oldContributors = state.controlContributors.get(btn)
      if (oldRecord !== undefined) {
        if (!this.releaseMappedOutput(oldRecord, contributorId, deviceId, state)) return false
        if (state.pressedControls.get(btn) === oldRecord) state.pressedControls.delete(btn)
        if (state.controlContributors.get(btn) === oldContributors) state.controlContributors.delete(btn)
      }
      if (!this.acceptsStateOwner(state) || state.pendingControlReentry.get(btn) !== desired) return false
      // 有界原通道快照；回调后来新增的通道留下一次维护，不循环追逐任意Native回入。
      for (const contributor of Array.from(desired)) {
        if (!desired.has(contributor)) continue
        this.setControlContributor(deviceId, state, btn, contributor, true, state.inputFence, true)
        if (!this.acceptsStateOwner(state) || state.pendingControlReentry.get(btn) !== desired) return false
      }
      const applied = state.controlContributors.get(btn)
      let pending: boolean = false
      for (const contributor of desired) if (applied?.has(contributor) !== true) pending = true
      if (!pending) state.pendingControlReentry.delete(btn)
      return !pending
    } finally { state.settlingReentry.delete(contributorId) }
  }

  private applyStick(role: StickRole, x: number, y: number, deadZone: number,
    previousDirection: number, desiredMoveKeys: Set<number>): number {
    if (role === 'move') return this.collectMoveKeys(x, y, deadZone, previousDirection, desiredMoveKeys)
    // look由advanceMappedLook按时间积分；none不产生输出。
    return -1
  }

  /** 只供映射runtime调度；原生手柄查询完全不经此接口。 */
  hasLookMotion(): boolean {
    if (!this.isEnabled()) return false
    return this.allStates().some((state: GamepadDeviceState): boolean => state.lookX !== 0 || state.lookY !== 0 ||
      state.lookVelocityDirty || state.lookRetirementPending || state.retiring && !state.isEmpty())
  }

  /** 用单调时间积分当前状态；多个设备按速度相加，单次最大50ms防止后台追赶。 */
  advanceMappedLook(seconds: number, monotonicNs: number = 0): void {
    this.reconcileConnectionCleanup()
    if (this.sharedLookExecution) {
      this.reconcileLookExecution()
      // 只有仍live的原流才推进。原退休失败墓碑可重试，不能自己续旧速度。
      if (this.isEnabled() && this.allStates().some((state: GamepadDeviceState): boolean =>
        this.acceptsStateSample(state, state.inputFence) && state.lookConnection !== 0)) {
        try { this.emitter.advanceLookExecution?.() } catch (_) { /* Native维护失败保持Pending，不转delta。 */ }
      }
      return
    }
    if (!this.isEnabled() || !Number.isFinite(seconds) || seconds <= 0) return
    const gain = RIGHT_STICK_LOOK_GAIN * (this.cfg.lookScale ?? 1) * Math.min(seconds, 0.05)
    let x: number = 0, y: number = 0
    const legacyFences: Map<GamepadDeviceState, GamepadStateInputFence> = new Map<GamepadDeviceState, GamepadStateInputFence>()
    for (const state of this.allStates()) {
      if (!this.acceptsStateSample(state, state.inputFence)) continue
      if (state.connection === undefined) { legacyFences.set(state, state.inputFence); continue }
      if (state.lookX === 0 && state.lookY === 0) continue
      const fence = state.inputFence
      this.invokeStateEmitter(state, (): boolean => this.emitter.emitLookDeltaForConnection?.(
        state.connection!, state.lookX * gain, state.lookY * gain, monotonicNs) === true)
      if (!this.acceptsStateSample(state, fence)) this.releaseState(state)
    }
    // 仅显式legacy数字桶继续原速度求和；scoped事实从不借此无lease出口。
    legacyFences.forEach((fence: GamepadStateInputFence, state: GamepadDeviceState): void => {
      if (this.acceptsStateSample(state, fence)) { x += state.lookX; y += state.lookY }
    })
    if (x !== 0 || y !== 0) this.emitter.emitLookDelta(x * gain, y * gain, monotonicNs)
  }

  /** 只读冻结模型；Runtime据此不再以JS时钟积分新路线，不从后端Ready投影改路线。 */
  usesSharedLookExecution(): boolean { return this.sharedLookExecution }

  /** 显式维护只重试原连接提交/退休。取消不扩大同目标其它设备的速率或尾量。 */
  reconcileLookExecution(): void {
    this.reconcileConnectionCleanup()
    if (!this.sharedLookExecution) return
    for (const state of this.allStates()) {
      if (state.lookRetirementPending) this.retireLookConnection(state.deviceId, state)
      else if (state.lookVelocityDirty && this.acceptsStateSample(state, state.inputFence)) this.publishLookVelocity(state.deviceId, state)
    }
  }

  /**
   * 仅一次分配本实例连接号，最大uint32合法用一次后拒绝新look，不复用失效编号。Native
   * 再绑定原session/resource，不能把相同OHOS设备ID当作重新插入后的同一连接。这里只
   * 做1080*lookScale单位换算，各设备非线性加工与family总和仍由唯一Native owner处理。
   */
  private publishLookVelocity(deviceId: number, state: GamepadDeviceState): void {
    const fence = state.inputFence
    if (!state.lookVelocityDirty || state.lookRetirementPending || !this.acceptsStateSample(state, fence)) return
    if (state.lookConnection === 0) {
      if (this.nextLookConnection > 4294967295) {
        state.lookX = 0; state.lookY = 0; state.lookVelocityDirty = false
        AppLogger.warn(TAG, 'mapped look connection identities exhausted; new look rejected'); return
      }
      state.lookConnection = this.nextLookConnection++
    }
    const child = state.lookConnection
    const gain = RIGHT_STICK_LOOK_GAIN * (this.cfg.lookScale ?? 1)
    const accepted = this.invokeStateEmitter(state, (): boolean => state.connection === undefined ?
      this.emitter.emitLookVelocity?.(deviceId, child, state.lookX * gain, state.lookY * gain) === true :
      this.emitter.emitLookVelocityForConnection?.(state.connection, child, state.lookX * gain, state.lookY * gain) === true)
    if (!this.acceptsStateSample(state, fence)) {
      // 速度调用中同步退休，即使返true也只按原子流清理，绝不推进后续扳机/WASD。
      state.lookConnection = child; state.lookRetirementPending = true; this.retainCleanupState(state)
      this.releaseState(state); return
    }
    if (accepted && state.lookConnection === child) state.lookVelocityDirty = false
  }

  /** 只清原流；清理权限不读当前rawID，失败保child；同步回入由cleanupRunning围栏。 */
  private retireLookConnection(deviceId: number, state: GamepadDeviceState): void {
    const child = state.lookConnection
    if (child === 0) { state.lookRetirementPending = false; return }
    if (state.lookRetiringInFlight) return
    state.lookRetiringInFlight = true
    let accepted: boolean = false
    try { accepted = this.invokeStateEmitter(state, (): boolean => state.connection === undefined ?
      this.emitter.retireLookConnection?.(deviceId, child) === true :
      this.emitter.retireLookForConnection?.(state.connection, child) === true) }
    finally { state.lookRetiringInFlight = false }
    if (!accepted || state.lookConnection !== child) return
    state.lookX = 0; state.lookY = 0; state.lookConnection = 0
    state.lookRetirementPending = false; state.lookVelocityDirty = false
    this.pruneDeviceState(deviceId, state)
  }

  /**
   * 移动杆八向 → WASD。原二维向量决定角度，半径仅决定是否激活，推深不改变走向。
   * 上一方向只扩大原扇区退出边界3度；明显转向立即切换，不加入定时器或延迟输出。
   * 半径首次超过用户死区才激活，已激活时用略低的退出边界过滤阈值附近的小波动；
   * 真实归零/缺轴/无效轴始终归中。返回的角度只供同设备同一根杆下一样本使用。
   * y向下为正仍沿既有映射解释，未据此声称已验证所有实体手柄的轴符号。
   */
  private collectMoveKeys(x: number, y: number, deadZone: number,
    previousDirection: number, desiredMoveKeys: Set<number>): number {
    const radius = Math.sqrt(x * x + y * y)
    const releaseBoundary = GamepadManager.analogReleaseBoundary(deadZone)
    if (radius === 0 || radius <= (previousDirection < 0 ? deadZone : releaseBoundary)) return -1
    let degrees = Math.atan2(y, x) * 180 / Math.PI
    if (degrees < 0) degrees += 360
    let direction = (Math.floor((degrees + 22.5) / 45) % 8) * 45
    if (previousDirection >= 0) {
      // 环形角差必须跨0度正确计算，避免向右附近抖动误判成一次完整转向。
      const difference = ((degrees - previousDirection + 540) % 360) - 180
      if (Math.abs(difference) <= 22.5 + MOVE_SECTOR_HYSTERESIS_DEGREES) direction = previousDirection
    }
    // 仍复用共同的八向→按键规格，不另抄一张WASD表；中心角不会落在扇区边界。
    const radians = direction * Math.PI / 180
    const sector = joystickSector(Math.cos(radians), Math.sin(radians), 0)
    if (sector.w) desiredMoveKeys.add(GLFW_KEY_W)
    if (sector.a) desiredMoveKeys.add(GLFW_KEY_A)
    if (sector.s) desiredMoveKeys.add(GLFW_KEY_S)
    if (sector.d) desiredMoveKeys.add(GLFW_KEY_D)
    return direction
  }

  private updateMoveKeys(deviceId: number, state: GamepadDeviceState,
    desiredMoveKeys: Set<number>, fence: GamepadStateInputFence): void {
    this.applyMoveKey(deviceId, state, GLFW_KEY_W, desiredMoveKeys.has(GLFW_KEY_W), fence)
    this.applyMoveKey(deviceId, state, GLFW_KEY_A, desiredMoveKeys.has(GLFW_KEY_A), fence)
    this.applyMoveKey(deviceId, state, GLFW_KEY_S, desiredMoveKeys.has(GLFW_KEY_S), fence)
    this.applyMoveKey(deviceId, state, GLFW_KEY_D, desiredMoveKeys.has(GLFW_KEY_D), fence)
  }

  private applyMoveKey(deviceId: number, state: GamepadDeviceState,
    key: number, want: boolean, fence: GamepadStateInputFence, replaying: boolean = false): void {
    if (!this.acceptsStateSample(state, fence)) return
    const contributorId: string = GamepadManager.moveContributorId(deviceId, key, state.connection)
    if (state.releasingControls.has(contributorId) || (!replaying && state.pendingMoveReentry.has(key))) {
      // 与离散按钮同一合同：旧UP在途只保原key最新desired，不能借activeMoveKeys旧缓存
      // 跳过新PRESS；归中回入可撤该desired，整连接退休则由releaseState统一清掉。
      state.pendingMoveReentry.set(key, want)
      if (!state.releasingControls.has(contributorId) && !state.settlingReentry.has(contributorId)) this.settleMoveReentry(deviceId, state, key)
      return
    }
    const has: boolean = state.activeMoveKeys.has(key)
    const record: PressedRecord = GamepadManager.keyRecord(key)
    if (want && !has) {
      const stillDesired = replaying ? (): boolean => this.acceptsStateOwner(state) && state.pendingMoveReentry.get(key) === true : undefined
      if (this.acquireMappedOutput(record, contributorId, deviceId, state, fence, stillDesired)) state.activeMoveKeys.add(key)
    } else if (!want && has) {
      state.pendingMoveReentry.set(key, false)
      if (this.releaseMappedOutput(record, contributorId, deviceId, state)) {
        state.activeMoveKeys.delete(key)
        if (state.pendingMoveReentry.has(key)) this.settleMoveReentry(deviceId, state, key)
      } else if (state.connection === undefined && this.emitter.emitControl === undefined &&
        state.pendingMoveReentry.get(key) === false) state.pendingMoveReentry.delete(key)
    }
  }

  /** 原WASD输出确认退休后才领取待定新方向；false保原UP墓碑及最新desired供稳定维护。 */
  private settleMoveReentry(deviceId: number, state: GamepadDeviceState, key: number): boolean {
    if (!state.pendingMoveReentry.has(key)) return true
    const contributorId: string = GamepadManager.moveContributorId(deviceId, key, state.connection)
    if (state.releasingControls.has(contributorId) || state.settlingReentry.has(contributorId) || !this.acceptsStateOwner(state)) return false
    state.settlingReentry.add(contributorId)
    try {
      if (state.activeMoveKeys.has(key)) {
        if (!this.releaseMappedOutput(GamepadManager.keyRecord(key), contributorId, deviceId, state)) return false
        state.activeMoveKeys.delete(key)
      }
      if (!this.acceptsStateOwner(state)) return false
      if (state.pendingMoveReentry.get(key) !== true) { state.pendingMoveReentry.delete(key); return true }
      this.applyMoveKey(deviceId, state, key, true, state.inputFence, true)
      if (!this.acceptsStateOwner(state)) return false
      const pending: boolean = state.pendingMoveReentry.get(key) === true && !state.activeMoveKeys.has(key)
      if (!pending) state.pendingMoveReentry.delete(key)
      return !pending
    } finally { state.settlingReentry.delete(contributorId) }
  }

  // ⚠️ 墓碑: `releaseMoveKeys` 已删除（全仓零调用方）。它做的事是 `releaseAll` 的真子集
  // —— 后者对 `activeMoveKeys` **全集**发 RELEASE 再 clear，不限于 WASD 四个键，
  // 详见计划 §64.2。

  /**
   * 扳机按用户阈值首次按下，已持有的模拟贡献降至较低退出边界才抬起。
   * 只读取该设备该按钮的模拟通道，数字键贡献不能降低一个尚未按下的模拟扳机门槛。
   * pending desired优先于旧持有快照，保留原UP在途/拒绝重试的事实；实际输出和所有者
   * 配对仍完整经过setControlContributor，0/缺轴/无效值不会被迟滞保成按住。
   */
  private applyTrigger(deviceId: number, state: GamepadDeviceState,
    btn: GamepadButton, value: number, threshold: number, fence: GamepadStateInputFence): void {
    const contributors = state.pendingControlReentry.get(btn) ?? state.controlContributors.get(btn)
    const wasDown = contributors?.has(CONTRIBUTOR_TRIGGER_AXIS) === true
    const isDown = value > 0 && (wasDown
      ? value > GamepadManager.analogReleaseBoundary(threshold) : value >= threshold)
    this.setControlContributor(deviceId, state, btn, CONTRIBUTOR_TRIGGER_AXIS, isDown, fence)
  }

  /** HAT 轴（方向键走轴）→ 离散左右 / 上下两个逻辑按钮，过 0.5 视为按下。 */
  private applyHat(deviceId: number, state: GamepadDeviceState,
    negBtn: GamepadButton, posBtn: GamepadButton, value: number, fence: GamepadStateInputFence): void {
    this.setControlContributor(
      deviceId, state, negBtn, CONTRIBUTOR_HAT_AXIS, value <= -0.5, fence)
    this.setControlContributor(
      deviceId, state, posBtn, CONTRIBUTOR_HAT_AXIS, value >= 0.5, fence)
  }

  /**
   * 原映射候选先取得真实输出回执，再进入aggregate。调用中退休的已接受PRESS只留原清理
   * 记录；inFlight固定原state寿命，回入release不能把尚未返回的token承诺误判为空。
   */
  private acquireMappedOutput(record: PressedRecord, contributorId: string, deviceId: number,
    state: GamepadDeviceState, fence: GamepadStateInputFence, stillDesired?: () => boolean): boolean {
    if (!this.acceptsStateSample(state, fence)) return false
    const owned = state.connection !== undefined || this.emitter.emitControl !== undefined
    const outputKey = GamepadManager.outputKey(record)
    let aggregate = this.outputAggregates.get(outputKey)
    const accepted = owned ? this.emitOwnedControl(state, contributorId, record, GLFW_PRESS_ACTION) :
      aggregate !== undefined || this.invokeStateEmitter(state, (): boolean | void => record.isMouse ?
        this.emitter.emitMouse(record.code, GLFW_PRESS_ACTION) : this.emitter.emitKey(record.code, GLFW_PRESS_ACTION))
    if (!accepted) return false
    if (!this.acceptsStateSample(state, fence) && stillDesired?.() !== true) {
      state.pendingControlReleases.set(contributorId, record); this.retainCleanupState(state)
      if (this.acceptsStateOwner(state)) {
        // 仅sample superseded（例如兄弟B重复DOWN）不等于整个连接退休。这个尚未进入
        // aggregate的原A输出只精确撤A，失败保原UP墓碑，不能为它取消已正确持有的B。
        if (this.emitOriginalControlRelease(state, contributorId, record) &&
          state.pendingControlReleases.get(contributorId) === record) state.pendingControlReleases.delete(contributorId)
      } else this.releaseState(state)
      return false
    }
    aggregate = this.outputAggregates.get(outputKey)
    if (aggregate === undefined) {
      aggregate = new MappedOutputAggregate(); aggregate.isMouse = record.isMouse; aggregate.code = record.code
      this.outputAggregates.set(outputKey, aggregate)
    }
    aggregate.contributors.add(contributorId)
    return true
  }

  /** 原aggregate只删原贡献；Native确认前不删缓存，同步回入的新aggregate对象不受旧回执影响。 */
  private releaseMappedOutput(record: PressedRecord, contributorId: string, deviceId: number,
    state: GamepadDeviceState): boolean {
    const outputKey = GamepadManager.outputKey(record)
    const aggregate = this.outputAggregates.get(outputKey)
    if (aggregate === undefined || !aggregate.contributors.has(contributorId)) return true
    if (!this.emitOriginalControlRelease(state, contributorId, record, aggregate.contributors.size > 1)) return false
    aggregate.contributors.delete(contributorId)
    if (aggregate.contributors.size === 0 && this.outputAggregates.get(outputKey) === aggregate) this.outputAggregates.delete(outputKey)
    return true
  }

  /** 每个scope/nativeControl的PRESS与UP走同一个明确出口；scoped缺口不回退raw口。 */
  private emitOwnedControl(state: GamepadDeviceState, contributorId: string, record: PressedRecord, action: number): boolean {
    const code = record.isMouse ? -(record.code + 1) : record.code
    return this.invokeStateEmitter(state, (): boolean => state.connection === undefined ?
      this.emitter.emitControl?.(state.deviceId, contributorId, code, action) === true :
      this.emitter.emitControlForConnection?.(state.connection, contributorId, code, action) === true)
  }

  /** 清理原已接受输出，不检查输入准入；releasing集合阻断同token对应control的递归UP。 */
  private emitOriginalControlRelease(state: GamepadDeviceState, contributorId: string, record: PressedRecord,
    hasOtherContributors: boolean = false): boolean {
    if (state.releasingControls.has(contributorId)) return false
    state.releasingControls.add(contributorId)
    try {
      if (state.connection !== undefined || this.emitter.emitControl !== undefined)
        return this.emitOwnedControl(state, contributorId, record, GLFW_RELEASE_ACTION)
      // 旧binary兼容出口仍遵循首按末松；原pending PRESS未入aggregate时也不能松掉兄弟。
      const aggregate = this.outputAggregates.get(GamepadManager.outputKey(record))
      if (hasOtherContributors || (aggregate !== undefined && aggregate.contributors.size > 0 &&
        !aggregate.contributors.has(contributorId))) return true
      return this.invokeStateEmitter(state, (): boolean | void => record.isMouse ?
        this.emitter.emitMouse(record.code, GLFW_RELEASE_ACTION) : this.emitter.emitKey(record.code, GLFW_RELEASE_ACTION))
    } finally { state.releasingControls.delete(contributorId) }
  }

  /** 即时scroll按原lease出口，void接受仅保旧legacy语义；调用后由共同按钮正文核围栏。 */
  private emitScrollForState(state: GamepadDeviceState, direction: number): boolean {
    return this.invokeStateEmitter(state, (): boolean | void => state.connection === undefined ?
      this.emitter.emitScroll(direction) : this.emitter.emitScrollForConnection?.(state.connection, direction) === true)
  }

  /** 固定原state的在途寿命；异常不建立假owner。Client的unknownToken由独立稳定维护负责。 */
  private invokeStateEmitter(state: GamepadDeviceState, callback: () => boolean | void): boolean {
    state.inFlight++
    try { return callback() !== false }
    catch (_) { return false }
    finally { state.inFlight-- }
  }

  /** 一次事实只认可当次原围栏；同步退休、reset或新样本都使旧正文失去后续副作用权限。 */
  private beginStateSample(state: GamepadDeviceState): GamepadStateInputFence {
    state.inputFence = new GamepadStateInputFence(); return state.inputFence
  }

  /** 原state必须仍登记；scoped还需Reader原对象准入，legacy只保显式数字桶的应用样本寿命。 */
  private acceptsStateSample(state: GamepadDeviceState, fence: GamepadStateInputFence): boolean {
    return state.inputFence === fence && this.acceptsStateOwner(state)
  }

  /** 原资源资格与样本围栏分开：兄弟新样本只撤原续体，真实退源/reset才退出整个state。 */
  private acceptsStateOwner(state: GamepadDeviceState): boolean {
    if (!this.isEnabled() || state.retiring || state.cleanupRunning) return false
    return state.connection === undefined ? this.devices.get(state.deviceId) === state :
      this.connectionDevices.get(state.connection) === state && this.acceptsConnection(state.connection)
  }

  /** 显式legacy原数字桶；不从此方法创建任何opaque hardware连接。 */
  private deviceState(deviceId: number): GamepadDeviceState {
    let state = this.devices.get(deviceId)
    if (state === undefined) { state = new GamepadDeviceState(deviceId); this.devices.set(deviceId, state) }
    return state
  }

  /** 同rawID的新lease有独立state；相同字段的伪造对象在公开入口已被Reader拒绝。 */
  private connectionState(connection: InputDeviceConnectionLease): GamepadDeviceState {
    let state = this.connectionDevices.get(connection)
    if (state === undefined) { state = new GamepadDeviceState(connection.rawPlatformId, connection); this.connectionDevices.set(connection, state) }
    return state
  }

  /** 非empty的原清理owner不覆盖新state；独立集合覆盖同步reset后原acquire才返回的情况。 */
  private retainCleanupState(state: GamepadDeviceState): void { this.pendingCleanupStates.add(state) }

  /** 只删除精确原state，inFlight/失败墓碑不删除；旧回执绝不删除后来同id/state。 */
  private pruneDeviceState(deviceId: number, state: GamepadDeviceState): void {
    if (!state.isEmpty()) return
    if (state.connection === undefined) {
      if (this.devices.get(deviceId) === state) this.devices.delete(deviceId)
    } else if (this.connectionDevices.get(state.connection) === state) this.connectionDevices.delete(state.connection)
    this.pendingCleanupStates.delete(state)
  }

  /** 三个容器取去重快照，回调重入不会让迭代认领后来新增state或跳过兄弟原state。 */
  private allStates(): GamepadDeviceState[] {
    const states: Set<GamepadDeviceState> = new Set<GamepadDeviceState>()
    this.devices.forEach((state: GamepadDeviceState): void => { states.add(state) })
    this.connectionDevices.forEach((state: GamepadDeviceState): void => { states.add(state) })
    this.pendingCleanupStates.forEach((state: GamepadDeviceState): void => { states.add(state) })
    return Array.from(states)
  }

  private hasAnyDeviceState(): boolean { return this.allStates().length > 0 }

  /** 诊断计入live持有及待清理记录；没有把acquiring intent或未知token声称为已交付owner。 */
  private heldStateCount(): number {
    let count: number = 0
    for (const state of this.allStates()) {
      count += state.controlContributors.size + state.activeMoveKeys.size + state.pendingControlReleases.size
      if (state.lookRetirementPending) count++
    }
    return count
  }

  private static normalizeGamepadDeviceId(deviceId: number): number {
    if (deviceId === COMPAT_GAMEPAD_DEVICE_ID) return COMPAT_GAMEPAD_DEVICE_ID
    return normalizeDeviceId(deviceId)
  }

  private static mappedRecord(configuredCode: number): PressedRecord {
    const record: PressedRecord = new PressedRecord()
    record.isMouse = isMouseCode(configuredCode)
    record.code = record.isMouse ? decodeMouse(configuredCode) : configuredCode
    return record
  }

  private static keyRecord(key: number): PressedRecord {
    const record: PressedRecord = new PressedRecord()
    record.isMouse = false
    record.code = key
    return record
  }

  private static outputKey(record: PressedRecord): string {
    return `${record.isMouse ? 'm' : 'k'}:${record.code}`
  }

  private static controlContributorId(deviceId: number, control: string, connection?: InputDeviceConnectionLease): string {
    return connection === undefined ? `device:${deviceId}:control:${control}` : `connection:${connection.applicationScope}:control:${control}`
  }

  private static moveContributorId(deviceId: number, key: number, connection?: InputDeviceConnectionLease): string {
    return connection === undefined ? `device:${deviceId}:move:${key}` : `connection:${connection.applicationScope}:move:${key}`
  }

  /**
   * 返回同时乘给X/Y的径向缩放系数：死区内为0，区外按半径线性回到[0,1]。
   * 方形行程角点先限制合成半径为1，方向由原半径归一；不分别截断两个新分量。
   * 入口已将分量防御到有限[-1,1]，配置死区已限制为[0,0.95]，分母不会为0。
   */
  private static radialDeadZoneScale(x: number, y: number, deadZone: number): number {
    const radius = Math.sqrt(x * x + y * y)
    if (radius === 0 || radius <= deadZone) return 0
    return (Math.min(radius, 1) - deadZone) / ((1 - deadZone) * radius)
  }

  /** 小阈值按比例缩小迟滞，0保留0，不能因固定迟滞宽度把用户阈值变成永不松开。 */
  private static analogReleaseBoundary(threshold: number): number {
    return threshold - Math.min(ANALOG_RELEASE_HYSTERESIS, threshold / 2)
  }

  /** 摇杆 / HAT 轴的防御边界：非有限值当居中，有限越界值压到 [-1, 1]。 */
  private static sanitizeSignedAxis(value: number | undefined): number {
    if (value === undefined || !Number.isFinite(value)) return 0
    if (value < -1) return -1
    if (value > 1) return 1
    return value
  }

  /** 扳机轴只接受 [0, 1]；非有限值视为松开，避免留下无法对账的持有态。 */
  private static sanitizeTriggerAxis(value: number | undefined): number {
    if (value === undefined || !Number.isFinite(value)) return 0
    if (value < 0) return 0
    if (value > 1) return 1
    return value
  }

  private static sanitizeConfigNumber(value: number | undefined, fallback: number,
    min: number, max: number): number {
    if (value === undefined || !Number.isFinite(value)) return fallback
    if (value < min) return min
    if (value > max) return max
    return value
  }

  private static normalizeConfig(cfg: GamepadConfig | undefined): GamepadConfig {
    if (!cfg) {
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
    // 补缺省字段（不改原对象）
    return {
      enabled: cfg.enabled,
      buttonMap: cfg.buttonMap ?? defaultGamepadButtonMap(),
      leftStick: cfg.leftStick ?? 'move',
      rightStick: cfg.rightStick ?? 'look',
      stickDeadZone: GamepadManager.sanitizeConfigNumber(
        cfg.stickDeadZone, DEFAULT_GAMEPAD_DEAD_ZONE, 0, 0.95),
      triggerThreshold: GamepadManager.sanitizeConfigNumber(
        cfg.triggerThreshold, DEFAULT_TRIGGER_THRESHOLD, 0, 1),
      lookScale: GamepadManager.sanitizeConfigNumber(cfg.lookScale, 1.0, 0.1, 10)
    }
  }
}

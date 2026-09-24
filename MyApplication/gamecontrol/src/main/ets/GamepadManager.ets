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
 *   - 右摇杆 → 视角增量（sendCursorDelta，乘灵敏度）
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
  /** 发 GLFW 键事件。action: GLFW_PRESS_ACTION / GLFW_RELEASE_ACTION。 */
  emitKey: (glfwKey: number, action: number) => boolean | void
  /** 发 GLFW 鼠标按钮事件。 */
  emitMouse: (glfwButton: number, action: number) => boolean | void
  /** 发滚轮（切手中物）。dir：+1 上一格 / -1 下一格。 */
  emitScroll: (dir: number) => boolean | void
  /** 发视角增量（右摇杆 look）。dx/dy 已乘灵敏度。 */
  emitLookDelta: (dx: number, dy: number) => boolean | void
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
 * 右摇杆视角基础增益：把 [-1,1] 的轴值换成"每帧/每事件像素增量"的基准。
 * 最终增量 = axis * RIGHT_STICK_LOOK_GAIN * lookScale，再交 C 层乘灵敏度 + 平滑。
 */
const RIGHT_STICK_LOOK_GAIN = 18

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

class GamepadDeviceState {
  // One logical control may be reported by two platform channels: L2/R2 as a
  // digital key and an analog trigger, DPAD as key codes and HAT axes. Their OR
  // owns one mapped output contributor, so the first channel down presses and
  // the last channel up releases.
  controlContributors: Map<string, Set<string>> = new Map<string, Set<string>>()
  pressedControls: Map<string, PressedRecord> = new Map<string, PressedRecord>()
  activeMoveKeys: Set<number> = new Set<number>()

  isEmpty(): boolean {
    return this.controlContributors.size === 0 &&
      this.pressedControls.size === 0 && this.activeMoveKeys.size === 0
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
  setMappedOutputEnabled(enabled: boolean): void {
    if (this.mappedOutputEnabled === enabled) return
    this.releaseAll()
    if (this.hasAnyDeviceState()) return
    this.mappedOutputEnabled = enabled
  }

  private cfg: GamepadConfig
  private emitter: GamepadEmitter
  private devices: Map<number, GamepadDeviceState> = new Map<number, GamepadDeviceState>()
  private knownDevices: Set<number> = new Set<number>()
  // Mapped key/mouse outputs are binary at the emitter boundary. Contributors
  // may come from multiple controls and multiple devices; only the first DOWN
  // and final UP cross that boundary.
  private outputAggregates: Map<string, MappedOutputAggregate> =
    new Map<string, MappedOutputAggregate>()

  constructor(cfg: GamepadConfig | undefined, emitter: GamepadEmitter) {
    this.cfg = GamepadManager.normalizeConfig(cfg)
    this.emitter = emitter
  }

  /**
   * profile 变化时更新配置。
   *
   * 先按旧配置释放全部持有态，再切换映射。否则一个已按下的逻辑按钮在
   * buttonMap / stick role / enabled 变化后会丢失它原先的 RELEASE 目标，留下卡键。
   */
  updateConfig(cfg: GamepadConfig | undefined): void {
    this.releaseAll()
    // native 拒绝旧 RELEASE 时保留旧配置与 DOWN-time 映射，禁止一边仍持有旧 owner、
    // 一边切到新映射。下次 update/lifecycle release 会继续重试。
    if (this.hasAnyDeviceState()) return
    this.cfg = GamepadManager.normalizeConfig(cfg)
  }

  isEnabled(): boolean {
    return this.cfg.enabled !== false && this.mappedOutputEnabled
  }

  /**
   * 处理手柄按键。返回 true 表示这是手柄按键（已消费）。
   * @param ohosKey OHOS keyCode
   * @param isDown  true=按下 false=抬起
   */
  handleButton(ohosKey: number, isDown: boolean): boolean {
    return this.handleButtonForDevice(COMPAT_GAMEPAD_DEVICE_ID, ohosKey, isDown)
  }

  /** Device-scoped button entry. deviceId=0 is the explicit compatibility bucket. */
  handleButtonForDevice(deviceId: number, ohosKey: number, isDown: boolean): boolean {
    const btn = ohosKeyToGamepadButton(ohosKey)
    if (btn === null) return false
    if (!this.isEnabled()) return true  // 仍算手柄键（消费），只是不派发

    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    if (normalizedDeviceId !== COMPAT_GAMEPAD_DEVICE_ID) {
      this.knownDevices.add(normalizedDeviceId)
    }
    const state: GamepadDeviceState = this.deviceState(normalizedDeviceId)
    this.setControlContributor(
      normalizedDeviceId, state, btn, CONTRIBUTOR_DIGITAL, isDown)
    this.pruneDeviceState(normalizedDeviceId, state)
    return true
  }

  /**
   * 处理一帧摇杆 / 扳机轴值。
   * @param getAxis 给定 AxisModel 数值返回轴值（[-1,1]，扳机 [0,1]），无值返回 undefined。
   */
  handleAxis(getAxis: (axis: number) => number | undefined): void {
    this.handleAxisForDevice(COMPAT_GAMEPAD_DEVICE_ID, getAxis)
  }

  /** Device-scoped axis entry. Missing axes retain the historical "center" interpretation. */
  handleAxisForDevice(deviceId: number,
    getAxis: (axis: number) => number | undefined): void {
    if (!this.isEnabled()) return
    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    if (normalizedDeviceId !== COMPAT_GAMEPAD_DEVICE_ID) {
      this.knownDevices.add(normalizedDeviceId)
    }
    const state: GamepadDeviceState = this.deviceState(normalizedDeviceId)
    const dz = this.cfg.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE

    // ---- 左摇杆 → move (WASD) 或 look ----
    const lx = GamepadManager.applyDeadZone(
      GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_X)), dz)
    const ly = GamepadManager.applyDeadZone(
      GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_Y)), dz)
    // ---- 右摇杆 → look 或 move ----
    const rx = GamepadManager.applyDeadZone(
      GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_Z)), dz)
    const ry = GamepadManager.applyDeadZone(
      GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_RZ)), dz)

    // 两根摇杆都可被配成 move。先聚合两者期望的方向键，再一次更新；
    // 若逐根调 updateMoveKeys，后处理的居中摇杆会把前一根刚按下的键释放掉。
    const desiredMoveKeys: Set<number> = new Set<number>()
    this.applyStick(this.cfg.leftStick ?? 'move', lx, ly, desiredMoveKeys)
    this.applyStick(this.cfg.rightStick ?? 'look', rx, ry, desiredMoveKeys)
    this.updateMoveKeys(normalizedDeviceId, state, desiredMoveKeys)

    // ---- 扳机 ----
    const thr = this.cfg.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD
    this.applyTrigger(normalizedDeviceId, state, 'L2',
      GamepadManager.sanitizeTriggerAxis(getAxis(AXIS_ABS_BRAKE)), thr)
    this.applyTrigger(normalizedDeviceId, state, 'R2',
      GamepadManager.sanitizeTriggerAxis(getAxis(AXIS_ABS_GAS)), thr)

    // ---- 方向键走轴（部分手柄）：HAT 当离散方向，映射到 buttonMap 的 DPAD_* ----
    const hatX = GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_HAT0X))
    const hatY = GamepadManager.sanitizeSignedAxis(getAxis(AXIS_ABS_HAT0Y))
    this.applyHat(normalizedDeviceId, state, 'DPAD_LEFT', 'DPAD_RIGHT', hatX)
    this.applyHat(normalizedDeviceId, state, 'DPAD_UP', 'DPAD_DOWN', hatY)
    this.pruneDeviceState(normalizedDeviceId, state)
  }

  /**
   * 释放所有按下中的手柄状态（grabbed 翻转 / 失焦 / 切后台 / 拔手柄时调）。
   *
   * 幂等：集合清空后重复调用是 no-op，所以"页面隐藏 + Ability 后台"叠加触发无害。
   * 发出的 RELEASE 与本端自己的 PRESS 配对，因此**必须在 native cancelAllInput 之前**
   * 调用（顺序理由见 InputSourceRegistry.ets 的"顺序纪律"一节）。
   */
  releaseAll(): void {
    const deviceIds: number[] = []
    this.devices.forEach((_state: GamepadDeviceState, deviceId: number) => {
      deviceIds.push(deviceId)
    })
    for (let i = 0; i < deviceIds.length; i++) this.releaseDevice(deviceIds[i])
  }

  /** Release only one device bucket. Rejected final RELEASE remains retryable. */
  releaseDevice(deviceId: number): void {
    const normalizedDeviceId: number = GamepadManager.normalizeGamepadDeviceId(deviceId)
    const state: GamepadDeviceState | undefined = this.devices.get(normalizedDeviceId)
    if (state === undefined) {
      // An idle identity is still useful to distinguish a real device-removal
      // edge from an unknown event-domain id.  Once no retryable held state
      // exists, forgetting it is safe and keeps the identity table bounded.
      this.knownDevices.delete(normalizedDeviceId)
      return
    }

    const remainingControls: Map<string, Set<string>> = new Map<string, Set<string>>()
    const remainingPressed: Map<string, PressedRecord> = new Map<string, PressedRecord>()
    state.pressedControls.forEach((record: PressedRecord, control: string) => {
      const contributorId: string =
        GamepadManager.controlContributorId(normalizedDeviceId, control)
      if (!this.releaseMappedOutput(record, contributorId)) {
        remainingPressed.set(control, record)
        const contributors: Set<string> | undefined = state.controlContributors.get(control)
        if (contributors !== undefined) remainingControls.set(control, contributors)
      }
    })
    state.pressedControls = remainingPressed
    state.controlContributors = remainingControls

    const remainingMoveKeys: Set<number> = new Set<number>()
    state.activeMoveKeys.forEach((key: number) => {
      const record: PressedRecord = GamepadManager.keyRecord(key)
      const contributorId: string =
        GamepadManager.moveContributorId(normalizedDeviceId, key)
      if (!this.releaseMappedOutput(record, contributorId)) remainingMoveKeys.add(key)
    })
    state.activeMoveKeys = remainingMoveKeys
    this.pruneDeviceState(normalizedDeviceId, state)
    // Keep the identity tombstone while a native RELEASE was rejected.  A
    // later removal/reconciliation must be able to find the same bucket and
    // retry the exact DOWN-time mapping; deleting it before the retry would
    // force McGamePage onto its conservative whole-source fallback.
    if (!this.devices.has(normalizedDeviceId)) {
      this.knownDevices.delete(normalizedDeviceId)
    }
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
    const hadState: boolean = this.hasAnyDeviceState()
    this.devices.clear()
    this.outputAggregates.clear()
    if (hadState) {
      hilog.info(0x0000, TAG, 'dropped held cache after native reset reason=%{public}s', reason)
    }
  }

  // ============ 内部 ============

  private resolveButton(btn: GamepadButton): GamepadAction | undefined {
    const map = this.cfg.buttonMap
    if (map && map[btn]) return map[btn]
    return undefined
  }

  private setControlContributor(deviceId: number, state: GamepadDeviceState,
    btn: GamepadButton, contributor: string, isDown: boolean): boolean {
    let contributors: Set<string> | undefined = state.controlContributors.get(btn)
    if (isDown) {
      if (contributors !== undefined && contributors.has(contributor)) return true
      if (contributors !== undefined && contributors.size > 0) {
        contributors.add(contributor)
        return true
      }

      const action: GamepadAction | undefined = this.resolveButton(btn)
      let accepted: boolean | void = true
      let record: PressedRecord | undefined = undefined
      if (action !== undefined && action.kind === 'hotbarPrev') {
        accepted = this.emitter.emitScroll(SCROLL_YOFFSET_UP)
      } else if (action !== undefined && action.kind === 'hotbarNext') {
        accepted = this.emitter.emitScroll(SCROLL_YOFFSET_DOWN)
      } else if (action !== undefined && action.kind === 'key') {
        const configuredCode: number = action.code ?? 0
        if (configuredCode !== 0) {
          record = GamepadManager.mappedRecord(configuredCode)
          const contributorId: string = GamepadManager.controlContributorId(deviceId, btn)
          accepted = this.acquireMappedOutput(record, contributorId)
        }
      }
      if (accepted === false) return false

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
      const contributorId: string = GamepadManager.controlContributorId(deviceId, btn)
      if (!this.releaseMappedOutput(record, contributorId)) return false
      state.pressedControls.delete(btn)
    }
    contributors.delete(contributor)
    state.controlContributors.delete(btn)
    return true
  }

  private applyStick(role: StickRole, x: number, y: number,
    desiredMoveKeys: Set<number>): void {
    if (role === 'move') {
      this.collectMoveKeys(x, y, desiredMoveKeys)
    } else if (role === 'look') {
      if (x === 0 && y === 0) return
      // R2：灵敏度 / 倒置 Y / 平滑统一由 C 层 ohos_send_cursor_delta(applyLookDelta) 处理，
      // 这里只把摇杆 [-1,1] 换算成"原始像素增量"（基础增益 * 手柄专属 lookScale），
      // 不再预乘 lookSensitivity / 不在此倒置 Y，避免与 C 层重复加工。
      const gain = RIGHT_STICK_LOOK_GAIN * (this.cfg.lookScale ?? 1.0)
      const dx = x * gain
      const dy = y * gain
      this.emitter.emitLookDelta(dx, dy)
    }
    // 'none'：不处理
  }

  /**
   * 左摇杆八向 → WASD。与触摸摇杆一致：atan2 分扇区，死区内全释放。
   * 注意：摇杆 y 向下为正（与屏幕一致），上为负。
   */
  private collectMoveKeys(x: number, y: number, desiredMoveKeys: Set<number>): void {
    // 扇区判定已抽到 JoystickSector.ets（纯函数，有单测，与 native 侧同一份规格）。
    // 抽出的理由不是这段代码难懂，而是同一张扇区表在本项目里写了三遍，谁改一份另两份
    // 不会有任何提示，表现为"同一个八向摇杆在三端手感不同"。
    //
    // 死区阈值传 0.0001 而不是 cfg.stickDeadZone：轴值在进来之前已经过
    // `applyDeadZone` 重映射（死区外线性拉回 [0,1]），此处只需挡住"归中"这一种情况。
    // 这与抽出前的行为逐位相同 —— 抽 TU 不改语义。
    const sector = joystickSector(x, y, 0.0001)
    if (sector.w) desiredMoveKeys.add(GLFW_KEY_W)
    if (sector.a) desiredMoveKeys.add(GLFW_KEY_A)
    if (sector.s) desiredMoveKeys.add(GLFW_KEY_S)
    if (sector.d) desiredMoveKeys.add(GLFW_KEY_D)
  }

  private updateMoveKeys(deviceId: number, state: GamepadDeviceState,
    desiredMoveKeys: Set<number>): void {
    this.applyMoveKey(deviceId, state, GLFW_KEY_W, desiredMoveKeys.has(GLFW_KEY_W))
    this.applyMoveKey(deviceId, state, GLFW_KEY_A, desiredMoveKeys.has(GLFW_KEY_A))
    this.applyMoveKey(deviceId, state, GLFW_KEY_S, desiredMoveKeys.has(GLFW_KEY_S))
    this.applyMoveKey(deviceId, state, GLFW_KEY_D, desiredMoveKeys.has(GLFW_KEY_D))
  }

  private applyMoveKey(deviceId: number, state: GamepadDeviceState,
    key: number, want: boolean): void {
    const has: boolean = state.activeMoveKeys.has(key)
    const record: PressedRecord = GamepadManager.keyRecord(key)
    const contributorId: string = GamepadManager.moveContributorId(deviceId, key)
    if (want && !has) {
      if (this.acquireMappedOutput(record, contributorId)) state.activeMoveKeys.add(key)
    } else if (!want && has) {
      if (this.releaseMappedOutput(record, contributorId)) state.activeMoveKeys.delete(key)
    }
  }

  // ⚠️ 墓碑: `releaseMoveKeys` 已删除（全仓零调用方）。它做的事是 `releaseAll` 的真子集
  // —— 后者对 `activeMoveKeys` **全集**发 RELEASE 再 clear，不限于 WASD 四个键，
  // 详见计划 §64.2。

  /** 扳机模拟值过阈值 → 视为对应逻辑按钮按下；回落 → 抬起。 */
  private applyTrigger(deviceId: number, state: GamepadDeviceState,
    btn: GamepadButton, value: number, threshold: number): void {
    this.setControlContributor(
      deviceId, state, btn, CONTRIBUTOR_TRIGGER_AXIS, value >= threshold)
  }

  /** HAT 轴（方向键走轴）→ 离散左右 / 上下两个逻辑按钮，过 0.5 视为按下。 */
  private applyHat(deviceId: number, state: GamepadDeviceState,
    negBtn: GamepadButton, posBtn: GamepadButton, value: number): void {
    this.setControlContributor(
      deviceId, state, negBtn, CONTRIBUTOR_HAT_AXIS, value <= -0.5)
    this.setControlContributor(
      deviceId, state, posBtn, CONTRIBUTOR_HAT_AXIS, value >= 0.5)
  }

  private acquireMappedOutput(record: PressedRecord, contributorId: string): boolean {
    const outputKey: string = GamepadManager.outputKey(record)
    let aggregate: MappedOutputAggregate | undefined = this.outputAggregates.get(outputKey)
    if (aggregate !== undefined) {
      aggregate.contributors.add(contributorId)
      return true
    }

    const accepted: boolean | void = record.isMouse
      ? this.emitter.emitMouse(record.code, GLFW_PRESS_ACTION)
      : this.emitter.emitKey(record.code, GLFW_PRESS_ACTION)
    if (accepted === false) return false

    aggregate = new MappedOutputAggregate()
    aggregate.isMouse = record.isMouse
    aggregate.code = record.code
    aggregate.contributors.add(contributorId)
    this.outputAggregates.set(outputKey, aggregate)
    return true
  }

  private releaseMappedOutput(record: PressedRecord, contributorId: string): boolean {
    const outputKey: string = GamepadManager.outputKey(record)
    const aggregate: MappedOutputAggregate | undefined = this.outputAggregates.get(outputKey)
    if (aggregate === undefined || !aggregate.contributors.has(contributorId)) return true
    if (aggregate.contributors.size > 1) {
      aggregate.contributors.delete(contributorId)
      return true
    }

    const accepted: boolean | void = record.isMouse
      ? this.emitter.emitMouse(record.code, GLFW_RELEASE_ACTION)
      : this.emitter.emitKey(record.code, GLFW_RELEASE_ACTION)
    if (accepted === false) return false
    aggregate.contributors.delete(contributorId)
    this.outputAggregates.delete(outputKey)
    return true
  }

  private deviceState(deviceId: number): GamepadDeviceState {
    let state: GamepadDeviceState | undefined = this.devices.get(deviceId)
    if (state === undefined) {
      state = new GamepadDeviceState()
      this.devices.set(deviceId, state)
    }
    return state
  }

  private pruneDeviceState(deviceId: number, state: GamepadDeviceState): void {
    if (state.isEmpty()) this.devices.delete(deviceId)
  }

  private hasAnyDeviceState(): boolean {
    return this.devices.size > 0
  }

  private heldStateCount(): number {
    let count: number = 0
    this.devices.forEach((state: GamepadDeviceState, _deviceId: number) => {
      count += state.controlContributors.size + state.activeMoveKeys.size
    })
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

  private static controlContributorId(deviceId: number, control: string): string {
    return `device:${deviceId}:control:${control}`
  }

  private static moveContributorId(deviceId: number, key: number): string {
    return `device:${deviceId}:move:${key}`
  }

  private static applyDeadZone(v: number, dz: number): number {
    if (Math.abs(v) < dz) return 0
    // 重映射：把 [dz,1] 线性拉回 [0,1]，避免死区边缘突跳
    const sign = v < 0 ? -1 : 1
    return sign * (Math.abs(v) - dz) / (1 - dz)
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

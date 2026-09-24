/**
 * GamepadManager.test.ets —— 手柄纯逻辑安全边界。
 *
 * 只验证不需要真机即可确定的状态机契约：重复边沿与双通道去重、逐设备 bucket、
 * 映射输出聚合、配置切换、数值防御与 release 幂等。轴符号和具体型号仍需真机取证。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  GamepadManager, GamepadEmitter, GamepadConfig, GamepadAction, defaultGamepadConfig,
  AXIS_ABS_X, AXIS_ABS_Y, AXIS_ABS_Z, AXIS_ABS_GAS, AXIS_ABS_HAT0X,
  OHOS_BUTTON_A, OHOS_BUTTON_B, OHOS_BUTTON_R2, OHOS_DPAD_LEFT,
  GLFW_KEY_SPACE, GLFW_KEY_W, GLFW_KEY_D, GLFW_MOUSE_BUTTON_LEFT,
  GLFW_PRESS, GLFW_RELEASE,
} from 'gamecontrol';

class RecordingGamepadEmitter implements GamepadEmitter {
  private keyEvents: string[] = []
  private mouseEvents: string[] = []
  private scrollEvents: number[] = []
  private lookDx: number[] = []
  private lookDy: number[] = []
  private keyAccepted: boolean = true
  private mouseAccepted: boolean = true

  emitKey(glfwKey: number, action: number): boolean {
    this.keyEvents.push(`${glfwKey}:${action}`)
    return this.keyAccepted
  }

  emitMouse(glfwButton: number, action: number): boolean {
    this.mouseEvents.push(`${glfwButton}:${action}`)
    return this.mouseAccepted
  }

  emitScroll(dir: number): boolean {
    this.scrollEvents.push(dir)
    return true
  }

  emitLookDelta(dx: number, dy: number): boolean {
    this.lookDx.push(dx)
    this.lookDy.push(dy)
    return true
  }

  setKeyAccepted(accepted: boolean): void {
    this.keyAccepted = accepted
  }

  setMouseAccepted(accepted: boolean): void {
    this.mouseAccepted = accepted
  }

  countKey(glfwKey: number, action: number): number {
    const target: string = `${glfwKey}:${action}`
    let count: number = 0
    for (let i = 0; i < this.keyEvents.length; i++) {
      if (this.keyEvents[i] === target) count++
    }
    return count
  }

  countMouse(glfwButton: number, action: number): number {
    const target: string = `${glfwButton}:${action}`
    let count: number = 0
    for (let i = 0; i < this.mouseEvents.length; i++) {
      if (this.mouseEvents[i] === target) count++
    }
    return count
  }

  countScroll(direction: number): number {
    let count: number = 0
    for (let i = 0; i < this.scrollEvents.length; i++) {
      if (this.scrollEvents[i] === direction) count++
    }
    return count
  }

  keyEventCount(): number {
    return this.keyEvents.length
  }

  mouseEventCount(): number {
    return this.mouseEvents.length
  }

  lookEventCount(): number {
    return this.lookDx.length
  }

  lookXAt(index: number): number {
    return this.lookDx[index] ?? NaN
  }

  lookYAt(index: number): number {
    return this.lookDy[index] ?? NaN
  }
}

class AxisFrame {
  private values: Map<number, number> = new Map<number, number>()

  set(axis: number, value: number): void {
    this.values.set(axis, value)
  }

  get(axis: number): number | undefined {
    return this.values.get(axis)
  }
}

function feedAxis(manager: GamepadManager, frame: AxisFrame): void {
  manager.handleAxis((axis: number): number | undefined => frame.get(axis))
}

function feedAxisForDevice(manager: GamepadManager, deviceId: number, frame: AxisFrame): void {
  manager.handleAxisForDevice(
    deviceId, (axis: number): number | undefined => frame.get(axis))
}

export default function gamepadManagerTest() {
  describe('GamepadManager.stateSafety', () => {
    it('repeated_button_down_and_up_emit_one_paired_edge', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)

      expect(manager.handleButton(OHOS_BUTTON_A, true)).assertTrue()
      expect(manager.handleButton(OHOS_BUTTON_A, true)).assertTrue()
      expect(manager.handleButton(OHOS_BUTTON_A, true)).assertTrue()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_PRESS)).assertEqual(1)

      expect(manager.handleButton(OHOS_BUTTON_A, false)).assertTrue()
      expect(manager.handleButton(OHOS_BUTTON_A, false)).assertTrue()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)
    })

    it('updateConfig_releases_old_button_and_disabling_stays_quiet', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      manager.handleButton(OHOS_BUTTON_A, true)

      const disabled: GamepadConfig = defaultGamepadConfig()
      disabled.enabled = false
      manager.updateConfig(disabled)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)

      const eventCount: number = emitter.keyEventCount()
      manager.handleButton(OHOS_BUTTON_A, true)
      feedAxis(manager, new AxisFrame())
      expect(emitter.keyEventCount()).assertEqual(eventCount)
    })

    it('stick_role_switch_releases_move_key_before_new_role_is_used', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const initial: GamepadConfig = defaultGamepadConfig()
      initial.rightStick = 'none'
      const manager = new GamepadManager(initial, emitter)
      const frame = new AxisFrame()
      frame.set(AXIS_ABS_Y, -1)
      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_PRESS)).assertEqual(1)

      const switched: GamepadConfig = defaultGamepadConfig()
      switched.leftStick = 'look'
      switched.rightStick = 'none'
      manager.updateConfig(switched)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(1)

      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_PRESS)).assertEqual(1)
      expect(emitter.lookEventCount()).assertEqual(1)
    })

    it('dead_zone_boundary_releases_and_just_outside_press', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.stickDeadZone = 0.2
      cfg.rightStick = 'none'
      const manager = new GamepadManager(cfg, emitter)
      const frame = new AxisFrame()

      frame.set(AXIS_ABS_X, 0.2)
      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_PRESS)).assertEqual(0)

      frame.set(AXIS_ABS_X, 0.201)
      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_PRESS)).assertEqual(1)

      frame.set(AXIS_ABS_X, 0.2)
      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_RELEASE)).assertEqual(1)
    })

    it('non_finite_axis_and_config_values_fall_back_without_nan_output', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.leftStick = 'none'
      cfg.rightStick = 'look'
      cfg.stickDeadZone = NaN
      cfg.triggerThreshold = NaN
      cfg.lookScale = NaN
      const manager = new GamepadManager(cfg, emitter)
      const frame = new AxisFrame()

      frame.set(AXIS_ABS_Z, NaN)
      frame.set(AXIS_ABS_GAS, Infinity)
      feedAxis(manager, frame)
      expect(emitter.lookEventCount()).assertEqual(0)
      expect(emitter.mouseEventCount()).assertEqual(0)

      frame.set(AXIS_ABS_Z, 99)
      frame.set(AXIS_ABS_GAS, 0.49)
      feedAxis(manager, frame)
      expect(emitter.lookEventCount()).assertEqual(1)
      expect(Number.isFinite(emitter.lookXAt(0))).assertTrue()
      expect(emitter.lookXAt(0)).assertEqual(18)
      expect(emitter.lookYAt(0)).assertEqual(0)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(0)

      frame.set(AXIS_ABS_Z, 0)
      frame.set(AXIS_ABS_GAS, 0.5)
      feedAxis(manager, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(1)
      frame.set(AXIS_ABS_GAS, NaN)
      feedAxis(manager, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(1)
    })

    it('finite_out_of_range_config_is_clamped_before_axis_math', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.stickDeadZone = 4
      cfg.triggerThreshold = 4
      cfg.lookScale = 50
      const manager = new GamepadManager(cfg, emitter)
      const frame = new AxisFrame()
      frame.set(AXIS_ABS_X, 1)
      frame.set(AXIS_ABS_Z, 1)
      frame.set(AXIS_ABS_GAS, 0.999)
      feedAxis(manager, frame)

      expect(emitter.countKey(GLFW_KEY_D, GLFW_PRESS)).assertEqual(1)
      expect(emitter.lookXAt(0)).assertEqual(180)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(0)

      frame.set(AXIS_ABS_GAS, 1)
      feedAxis(manager, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(1)
    })

    it('two_move_sticks_are_aggregated_instead_of_overwriting_each_other', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.leftStick = 'move'
      cfg.rightStick = 'move'
      const manager = new GamepadManager(cfg, emitter)
      const frame = new AxisFrame()
      frame.set(AXIS_ABS_Y, -1)
      frame.set(AXIS_ABS_Z, 1)
      feedAxis(manager, frame)

      expect(emitter.countKey(GLFW_KEY_W, GLFW_PRESS)).assertEqual(1)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_PRESS)).assertEqual(1)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(0)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_RELEASE)).assertEqual(0)

      frame.set(AXIS_ABS_Y, 0)
      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(1)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_RELEASE)).assertEqual(0)
      expect(emitter.countKey(GLFW_KEY_D, GLFW_PRESS)).assertEqual(1)
    })

    it('releaseAll_releases_every_held_kind_once_and_is_idempotent', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.rightStick = 'none'
      const manager = new GamepadManager(cfg, emitter)
      manager.handleButton(OHOS_BUTTON_A, true)
      const frame = new AxisFrame()
      frame.set(AXIS_ABS_Y, -1)
      frame.set(AXIS_ABS_GAS, 1)
      feedAxis(manager, frame)

      manager.releaseAll()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(1)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(1)

      const keyCount: number = emitter.keyEventCount()
      const mouseCount: number = emitter.mouseEventCount()
      manager.releaseAll()
      expect(emitter.keyEventCount()).assertEqual(keyCount)
      expect(emitter.mouseEventCount()).assertEqual(mouseCount)

      feedAxis(manager, frame)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_PRESS)).assertEqual(2)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(2)
    })

    it('rejected_native_edges_do_not_lie_about_gamepad_held_state', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)

      // 拒收 PRESS 不得进入 pressedButtons；恢复后同一物理 Down 必须能重试。
      emitter.setKeyAccepted(false)
      manager.handleButton(OHOS_BUTTON_A, true)
      emitter.setKeyAccepted(true)
      manager.handleButton(OHOS_BUTTON_A, true)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_PRESS)).assertEqual(2)

      // 拒收 RELEASE 必须保留 held 记录；下一次 releaseAll 会重试实际 DOWN-time code。
      emitter.setKeyAccepted(false)
      manager.handleButton(OHOS_BUTTON_A, false)
      emitter.setKeyAccepted(true)
      manager.releaseAll()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(2)

      // 模拟 trigger/HAT 还有第二份 latch；它也必须只在 checked edge 成功后翻转。
      const frame = new AxisFrame()
      frame.set(AXIS_ABS_GAS, 1)
      emitter.setMouseAccepted(false)
      feedAxis(manager, frame)
      emitter.setMouseAccepted(true)
      feedAxis(manager, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(2)

      frame.set(AXIS_ABS_GAS, 0)
      emitter.setMouseAccepted(false)
      feedAxis(manager, frame)
      emitter.setMouseAccepted(true)
      feedAxis(manager, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(2)
    })

    it('two_devices_sharing_one_mapping_emit_first_press_and_final_release_only', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)

      manager.handleButtonForDevice(7, OHOS_BUTTON_A, true)
      manager.handleButtonForDevice(8, OHOS_BUTTON_A, true)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_PRESS)).assertEqual(1)
      expect(manager.hasDeviceState(7)).assertTrue()
      expect(manager.hasDeviceState(8)).assertTrue()

      manager.releaseDevice(7)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(0)
      expect(manager.hasDeviceState(7)).assertFalse()
      expect(manager.hasDeviceState(8)).assertTrue()

      manager.releaseDevice(8)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)
      expect(manager.hasDeviceState(8)).assertFalse()
    })

    it('two_controls_mapped_to_one_output_share_the_same_aggregate', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      const sharedAction: GamepadAction = { kind: 'key', code: GLFW_KEY_SPACE }
      if (cfg.buttonMap !== undefined) {
        cfg.buttonMap['A'] = sharedAction
        cfg.buttonMap['B'] = sharedAction
      }
      const manager = new GamepadManager(cfg, emitter)

      manager.handleButtonForDevice(9, OHOS_BUTTON_A, true)
      manager.handleButtonForDevice(9, OHOS_BUTTON_B, true)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_PRESS)).assertEqual(1)
      manager.handleButtonForDevice(9, OHOS_BUTTON_A, false)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(0)
      manager.handleButtonForDevice(9, OHOS_BUTTON_B, false)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)
      expect(manager.hasDeviceState(9)).assertFalse()
    })

    it('two_device_move_contributors_do_not_release_each_other', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const cfg: GamepadConfig = defaultGamepadConfig()
      cfg.rightStick = 'none'
      const manager = new GamepadManager(cfg, emitter)
      const moving = new AxisFrame()
      moving.set(AXIS_ABS_Y, -1)

      feedAxisForDevice(manager, 17, moving)
      feedAxisForDevice(manager, 18, moving)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_PRESS)).assertEqual(1)

      const centered = new AxisFrame()
      centered.set(AXIS_ABS_Y, 0)
      feedAxisForDevice(manager, 17, centered)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(0)
      expect(manager.hasDeviceState(17)).assertFalse()
      expect(manager.hasDeviceState(18)).assertTrue()

      feedAxisForDevice(manager, 18, centered)
      expect(emitter.countKey(GLFW_KEY_W, GLFW_RELEASE)).assertEqual(1)
      expect(manager.hasDeviceState(18)).assertFalse()
    })

    it('digital_and_analog_trigger_are_one_logical_contributor', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      const frame = new AxisFrame()

      manager.handleButtonForDevice(27, OHOS_BUTTON_R2, true)
      frame.set(AXIS_ABS_GAS, 1)
      feedAxisForDevice(manager, 27, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(1)

      manager.handleButtonForDevice(27, OHOS_BUTTON_R2, false)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(0)
      frame.set(AXIS_ABS_GAS, 0)
      feedAxisForDevice(manager, 27, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(1)

      frame.set(AXIS_ABS_GAS, 1)
      feedAxisForDevice(manager, 27, frame)
      manager.handleButtonForDevice(27, OHOS_BUTTON_R2, true)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS)).assertEqual(2)
      frame.set(AXIS_ABS_GAS, 0)
      feedAxisForDevice(manager, 27, frame)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(1)
      manager.handleButtonForDevice(27, OHOS_BUTTON_R2, false)
      expect(emitter.countMouse(GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE)).assertEqual(2)
      expect(manager.hasDeviceState(27)).assertFalse()
    })

    it('dpad_key_hat_and_repeated_down_trigger_hotbar_once_per_press', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      const frame = new AxisFrame()

      manager.handleButtonForDevice(37, OHOS_DPAD_LEFT, true)
      manager.handleButtonForDevice(37, OHOS_DPAD_LEFT, true)
      expect(emitter.countScroll(1)).assertEqual(1)

      frame.set(AXIS_ABS_HAT0X, -1)
      feedAxisForDevice(manager, 37, frame)
      expect(emitter.countScroll(1)).assertEqual(1)
      manager.handleButtonForDevice(37, OHOS_DPAD_LEFT, false)
      expect(manager.hasDeviceState(37)).assertTrue()

      frame.set(AXIS_ABS_HAT0X, 0)
      feedAxisForDevice(manager, 37, frame)
      expect(manager.hasDeviceState(37)).assertFalse()

      manager.handleButtonForDevice(37, OHOS_DPAD_LEFT, true)
      expect(emitter.countScroll(1)).assertEqual(2)
      manager.handleButtonForDevice(37, OHOS_DPAD_LEFT, false)
    })

    it('rejected_final_release_stays_with_the_last_device_for_retry', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      manager.handleButtonForDevice(47, OHOS_BUTTON_A, true)
      manager.handleButtonForDevice(48, OHOS_BUTTON_A, true)

      emitter.setKeyAccepted(false)
      manager.releaseDevice(47)
      expect(manager.hasDeviceState(47)).assertFalse()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(0)

      manager.releaseDevice(48)
      expect(manager.hasDeviceState(48)).assertTrue()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(1)

      emitter.setKeyAccepted(true)
      manager.releaseDevice(48)
      expect(manager.hasDeviceState(48)).assertFalse()
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(2)
    })

    it('rejected_device_release_keeps_identity_until_retry', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      manager.handleButtonForDevice(49, OHOS_BUTTON_A, true)
      emitter.setKeyAccepted(false)
      manager.releaseDevice(49)
      expect(manager.hasDeviceState(49)).assertTrue()
      expect(manager.knowsDevice(49)).assertTrue()
      emitter.setKeyAccepted(true)
      manager.releaseDevice(49)
      expect(manager.hasDeviceState(49)).assertFalse()
      expect(manager.knowsDevice(49)).assertFalse()
    })

    it('centered_device_frame_does_not_leave_an_empty_bucket', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      feedAxisForDevice(manager, 57, new AxisFrame())
      expect(manager.hasDeviceState(57)).assertFalse()
      expect(manager.knowsDevice(57)).assertTrue()
      manager.releaseDevice(57)
      expect(manager.knowsDevice(57)).assertFalse()
    })

    it('native_first_reset_drops_all_buckets_and_output_aggregates_without_edges', 0, () => {
      const emitter = new RecordingGamepadEmitter()
      const manager = new GamepadManager(undefined, emitter)
      manager.handleButtonForDevice(67, OHOS_BUTTON_A, true)
      manager.handleButtonForDevice(68, OHOS_BUTTON_A, true)
      manager.dropHeldStateAfterNativeReset('test-reset')

      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_RELEASE)).assertEqual(0)
      expect(manager.hasDeviceState(67)).assertFalse()
      expect(manager.hasDeviceState(68)).assertFalse()

      manager.handleButtonForDevice(67, OHOS_BUTTON_A, true)
      expect(emitter.countKey(GLFW_KEY_SPACE, GLFW_PRESS)).assertEqual(2)
    })
  })
}

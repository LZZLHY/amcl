/**
 * PhysicalHeldKeyTracker.test.ets — Phase 3.3 实体键盘 held 按设备追踪 + 平台锁存快照
 *
 * 纯逻辑覆盖计划 §10.1 中过去在 ArkTS 缓存层不可能表达的两条语义：
 *   - "两把键盘同时按 W：一把抬起不提前释放 aggregate W；两把都抬起才结束"
 *   - "按住键时拔设备：只释放该设备 owner"
 * 以及 §5.2 / §10.1 的锁存契约："Caps/Num/Scroll 为锁存状态，不按 held 模拟"。
 * 本文件不驱动系统 inputDevice、NAPI 或真机，不能替代热插拔/双键盘验收矩阵。
 *
 * 创建日期：2026-08-12（docs/refactor/实体键鼠输入架构重构计划.md Phase 3.3）
 */

import { describe, it, expect } from '@ohos/hypium';
import { PhysicalHeldKeyTracker, HeldKeyDownKind } from 'gamecontrol';
import {
  composeOhosLockState, composeGlfwMods, computeGlfwHeldMods, computeGlfwMods,
  AMCL_LOCK_STATE_VALID, AMCL_LOCK_STATE_CAPS, AMCL_LOCK_STATE_NUM,
  AMCL_LOCK_STATE_SCROLL,
} from 'gamecontrol';
import {
  GLFW_MOD_SHIFT, GLFW_MOD_CONTROL, GLFW_MOD_CAPS_LOCK, GLFW_MOD_NUM_LOCK,
} from 'gamecontrol';
import {
  routeKeyToGamepad, isSharedDirectionalKey, isGamepadKey,
} from 'gamecontrol';
import {
  deviceCapabilityBitsFromSources,
  AMCL_DEVICE_CAP_KEYBOARD, AMCL_DEVICE_CAP_POINTER_ABSOLUTE,
  AMCL_DEVICE_CAP_POINTER_RELATIVE, AMCL_DEVICE_CAP_POINTER_BUTTONS,
  AMCL_DEVICE_CAP_WHEEL, AMCL_DEVICE_CAP_TEXT, AMCL_DEVICE_CAP_HOVER,
  AMCL_DEVICE_CAP_CAPTURE, InputDeviceClass,
  normalizeMonotonicTimestampNs, pointerDeviceClassFromSourceTool,
  pointerDeviceClassFromSources,
} from 'gamecontrol';
import {
  OHOS_DPAD_UP, OHOS_DPAD_DOWN, OHOS_DPAD_LEFT, OHOS_DPAD_RIGHT,
  OHOS_DPAD_CENTER, OHOS_BUTTON_A, OHOS_BUTTON_START,
} from 'gamecontrol';
import {
  OHOS_SHIFT_LEFT, OHOS_CTRL_LEFT, OHOS_CAPS_LOCK, OHOS_NUM_LOCK,
  OHOS_A, OHOS_Z,
} from 'gamecontrol';
import {
  DeviceChangeFanout, DeviceInventoryPublicationGuard,
  LatestAsyncRequestCommitGuard, ProcessDeviceMonitorRegistrationLatch,
  normalizeInputDeviceChange,
} from 'gamecontrol';
import { DeviceChangeEvent } from 'gamecontrol';

const KEYBOARD_A: number = 11;
const KEYBOARD_B: number = 22;
// OhosKeyCodes 只给出 A/Z 两个端点常量，字母段连续（OHOS_A=2017 … OHOS_Z=2042，
// 共 26 个码）。W 是 A 之后第 22 个，这里由端点推出而不是硬编码 2039。
const OHOS_KEY_W: number = OHOS_A + 22;

export default function physicalHeldKeyTrackerTest() {
  describe('InputDeviceLifecycleCoordinator', () => {
    it('进程监听闩锁幂等，注册失败后允许重试', 0, () => {
      const latch = new ProcessDeviceMonitorRegistrationLatch();
      expect(latch.begin()).assertTrue();
      expect(latch.begin()).assertFalse();
      expect(latch.isActive()).assertTrue();
      latch.markFailed();
      expect(latch.isActive()).assertFalse();
      expect(latch.begin()).assertTrue();
    });

    it('并发快照 latest-request-wins：旧请求迟到不能提交', 0, () => {
      const guard = new LatestAsyncRequestCommitGuard();
      const older: number = guard.begin();
      expect(guard.isCurrent(older)).assertTrue();
      const newer: number = guard.begin();
      expect(guard.isCurrent(older)).assertFalse();
      expect(guard.isCurrent(newer)).assertTrue();
    });

    it('只规范化 add/remove，未知 change type 不得猜成 remove', 0, () => {
      const added: DeviceChangeEvent | undefined = normalizeInputDeviceChange('add', KEYBOARD_A);
      const removed: DeviceChangeEvent | undefined = normalizeInputDeviceChange('remove', KEYBOARD_B);
      expect(added !== undefined && added.added).assertTrue();
      expect(removed !== undefined && !removed.added).assertTrue();
      expect(normalizeInputDeviceChange('change', KEYBOARD_A) === undefined).assertTrue();
      expect(normalizeInputDeviceChange('', KEYBOARD_A) === undefined).assertTrue();
    });

    it('扇出遍历快照：监听器同步退订不跳过当前边沿，下一次才生效', 0, () => {
      const fanout = new DeviceChangeFanout();
      let firstCount: number = 0;
      let secondCount: number = 0;
      const second = (event: DeviceChangeEvent): void => { secondCount++; };
      const first = (event: DeviceChangeEvent): void => {
        firstCount++;
        fanout.remove(second);
      };
      fanout.add(first);
      fanout.add(second);
      const event: DeviceChangeEvent = { added: false, deviceId: KEYBOARD_A };
      expect(fanout.dispatch(event)).assertEqual(0);
      expect(firstCount).assertEqual(1);
      expect(secondCount).assertEqual(1);
      expect(fanout.dispatch(event)).assertEqual(0);
      expect(firstCount).assertEqual(2);
      expect(secondCount).assertEqual(1);
    });

    it('单个监听器抛错不阻断后续监听器', 0, () => {
      const fanout = new DeviceChangeFanout();
      let delivered: number = 0;
      fanout.add((event: DeviceChangeEvent): void => { throw new Error('expected'); });
      fanout.add((event: DeviceChangeEvent): void => { delivered++; });
      const event: DeviceChangeEvent = { added: true, deviceId: KEYBOARD_A };
      expect(fanout.dispatch(event)).assertEqual(1);
      expect(delivered).assertEqual(1);
    });

    it('启动 inventory 无实时边沿时可发布；已知在场设备也可幂等补报', 0, () => {
      const guard = new DeviceInventoryPublicationGuard();
      const initialGeneration: number = guard.beginInventory();
      expect(guard.mayPublishAdded(KEYBOARD_A, initialGeneration)).assertTrue();
      guard.noteRealtimeChange(KEYBOARD_A, true);
      const afterAddGeneration: number = guard.beginInventory();
      expect(guard.mayPublishAdded(KEYBOARD_A, afterAddGeneration)).assertTrue();
    });

    it('remove-wins：快照前墓碑和快照后的 remove 都拒绝迟到 ADDED', 0, () => {
      const guard = new DeviceInventoryPublicationGuard();
      guard.noteRealtimeChange(KEYBOARD_A, false);
      const afterRemoveGeneration: number = guard.beginInventory();
      expect(guard.mayPublishAdded(KEYBOARD_A, afterRemoveGeneration)).assertFalse();

      const beforeRaceGeneration: number = guard.beginInventory();
      guard.noteRealtimeChange(KEYBOARD_B, false);
      expect(guard.mayPublishAdded(KEYBOARD_B, beforeRaceGeneration)).assertFalse();
    });

    it('inventory 开始后的 add 由实时路径负责，迟到快照不重复发布', 0, () => {
      const guard = new DeviceInventoryPublicationGuard();
      const inventoryGeneration: number = guard.beginInventory();
      guard.noteRealtimeChange(KEYBOARD_A, true);
      expect(guard.mayPublishAdded(KEYBOARD_A, inventoryGeneration)).assertFalse();
    });
  });

  describe('PhysicalHeldKeyTracker.perDeviceOwners', () => {
    it('前置断言：OHOS 字母段连续，OHOS_KEY_W 推导有效', 0, () => {
      // 本文件用 OHOS_A + 22 表示 W。一旦 SSOT 里字母段不再连续，这条会先失败，
      // 而不是让后面所有用例静默测到一个错误的 keyCode。
      expect(OHOS_Z - OHOS_A).assertEqual(25);
    });

    it('同一设备重复 Down → Repeat，不新增 owner', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      expect(t.noteDown(KEYBOARD_A, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.FirstDown);
      expect(t.noteDown(KEYBOARD_A, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.Repeat);
      expect(t.noteDown(KEYBOARD_A, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.Repeat);
      expect(t.ownerCount()).assertEqual(1);
    });

    it('两把键盘同键 → 两个独立 owner，先抬起的不提前结束聚合键', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      expect(t.noteDown(KEYBOARD_A, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.FirstDown);
      // 第二把键盘的首次 Down 不能被误判成 Repeat
      expect(t.noteDown(KEYBOARD_B, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.FirstDown);
      expect(t.ownerCount()).assertEqual(2);

      expect(t.noteUp(KEYBOARD_A, OHOS_KEY_W)).assertTrue();
      // A 抬起后 B 仍持有：聚合快照必须仍然认为 W 按着
      expect(t.isHeld(KEYBOARD_B, OHOS_KEY_W)).assertTrue();
      expect(t.heldKeys().has(OHOS_KEY_W)).assertTrue();
      expect(t.ownerCount()).assertEqual(1);

      expect(t.noteUp(KEYBOARD_B, OHOS_KEY_W)).assertTrue();
      expect(t.heldKeys().has(OHOS_KEY_W)).assertFalse();
      expect(t.ownerCount()).assertEqual(0);
    });

    it('未持有的 UP 不改状态、不产生负引用', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      expect(t.noteUp(KEYBOARD_A, OHOS_KEY_W)).assertFalse();
      expect(t.ownerCount()).assertEqual(0);
      expect(t.heldKeys().has(OHOS_KEY_W)).assertFalse();

      t.noteDown(KEYBOARD_A, OHOS_KEY_W);
      // 其他设备的 UP 不能释放本设备的 owner
      expect(t.noteUp(KEYBOARD_B, OHOS_KEY_W)).assertFalse();
      expect(t.isHeld(KEYBOARD_A, OHOS_KEY_W)).assertTrue();
      expect(t.ownerCount()).assertEqual(1);
      // 同一设备重复 UP：第二次已无 owner
      expect(t.noteUp(KEYBOARD_A, OHOS_KEY_W)).assertTrue();
      expect(t.noteUp(KEYBOARD_A, OHOS_KEY_W)).assertFalse();
      expect(t.ownerCount()).assertEqual(0);
    });

    it('releaseDevice 只释放该设备 owner', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      t.noteDown(KEYBOARD_A, OHOS_KEY_W);
      t.noteDown(KEYBOARD_A, OHOS_SHIFT_LEFT);
      t.noteDown(KEYBOARD_B, OHOS_KEY_W);

      const released = t.releaseDevice(KEYBOARD_A);
      expect(released.length).assertEqual(2);
      expect(released.includes(OHOS_KEY_W)).assertTrue();
      expect(released.includes(OHOS_SHIFT_LEFT)).assertTrue();

      // B 的 W 必须存活；A 的 SHIFT 必须消失
      expect(t.isHeld(KEYBOARD_B, OHOS_KEY_W)).assertTrue();
      expect(t.heldKeys().has(OHOS_KEY_W)).assertTrue();
      expect(t.heldKeys().has(OHOS_SHIFT_LEFT)).assertFalse();
      expect(t.ownerCount()).assertEqual(1);

      // 幂等：重复移除同一设备不产生副作用
      expect(t.releaseDevice(KEYBOARD_A).length).assertEqual(0);
      expect(t.ownerCount()).assertEqual(1);
    });

    it('clear 幂等且清空两份索引', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      t.noteDown(KEYBOARD_A, OHOS_KEY_W);
      t.noteDown(KEYBOARD_B, OHOS_CTRL_LEFT);
      t.clear();
      t.clear();
      expect(t.ownerCount()).assertEqual(0);
      expect(t.heldKeys().size).assertEqual(0);
      // clear 后的首个 Down 必须是 FirstDown，不能被误标 Repeat
      expect(t.noteDown(KEYBOARD_A, OHOS_KEY_W)).assertEqual(HeldKeyDownKind.FirstDown);
    });

    it('heldKeys 返回快照，外部修改不影响内部状态', 0, () => {
      const t = new PhysicalHeldKeyTracker();
      t.noteDown(KEYBOARD_A, OHOS_KEY_W);
      const snapshot = t.heldKeys();
      snapshot.delete(OHOS_KEY_W);
      expect(t.heldKeys().has(OHOS_KEY_W)).assertTrue();
    });
  });

  describe('InputDeviceAbi.deviceCapabilityBitsFromSources', () => {
    it('keyboard → KEYBOARD | TEXT', 0, () => {
      const bits = deviceCapabilityBitsFromSources(['keyboard']);
      expect((bits & AMCL_DEVICE_CAP_KEYBOARD) !== 0).assertTrue();
      expect((bits & AMCL_DEVICE_CAP_TEXT) !== 0).assertTrue();
      expect((bits & AMCL_DEVICE_CAP_POINTER_ABSOLUTE) !== 0).assertFalse();
    });

    it('mouse / touchpad → 绝对坐标 + 按键 + 滚轮 + hover', 0, () => {
      const mouse = deviceCapabilityBitsFromSources(['mouse']);
      const pad = deviceCapabilityBitsFromSources(['touchpad']);
      expect(mouse).assertEqual(pad);
      expect((mouse & AMCL_DEVICE_CAP_POINTER_ABSOLUTE) !== 0).assertTrue();
      expect((mouse & AMCL_DEVICE_CAP_POINTER_BUTTONS) !== 0).assertTrue();
      expect((mouse & AMCL_DEVICE_CAP_WHEEL) !== 0).assertTrue();
      expect((mouse & AMCL_DEVICE_CAP_HOVER) !== 0).assertTrue();
    });

    it('默认不从 source 名字猜 RELATIVE / CAPTURE', 0, () => {
      const all = deviceCapabilityBitsFromSources(
        ['keyboard', 'mouse', 'touchpad', 'touchscreen', 'joystick', 'trackball']);
      expect((all & AMCL_DEVICE_CAP_POINTER_RELATIVE) !== 0).assertFalse();
      expect((all & AMCL_DEVICE_CAP_CAPTURE) !== 0).assertFalse();
    });

    it('relative/capture 只能由显式平台能力打开', 0, () => {
      const baseline = deviceCapabilityBitsFromSources(['mouse']);
      const relative = deviceCapabilityBitsFromSources(['mouse'], true, false);
      const captured = deviceCapabilityBitsFromSources(['mouse'], true, true);
      expect((baseline & AMCL_DEVICE_CAP_POINTER_RELATIVE) === 0).assertTrue();
      expect((baseline & AMCL_DEVICE_CAP_CAPTURE) === 0).assertTrue();
      expect((relative & AMCL_DEVICE_CAP_POINTER_RELATIVE) !== 0).assertTrue();
      expect((relative & AMCL_DEVICE_CAP_CAPTURE) === 0).assertTrue();
      expect((captured & AMCL_DEVICE_CAP_POINTER_RELATIVE) !== 0).assertTrue();
      expect((captured & AMCL_DEVICE_CAP_CAPTURE) !== 0).assertTrue();
      expect(deviceCapabilityBitsFromSources(['touchscreen'], true, true))
        .assertEqual(AMCL_DEVICE_CAP_POINTER_ABSOLUTE);
    });

    it('未识别 source 与空数组 → 0，不产生未知位', 0, () => {
      expect(deviceCapabilityBitsFromSources([])).assertEqual(0);
      expect(deviceCapabilityBitsFromSources(['joystick'])).assertEqual(0);
      expect(deviceCapabilityBitsFromSources(['trackball'])).assertEqual(0);
      expect(deviceCapabilityBitsFromSources(['not-a-real-source'])).assertEqual(0);
    });

    it('位值与 native ABI 镜像一致（1/2/4/8/16/32/64/128）', 0, () => {
      expect(AMCL_DEVICE_CAP_KEYBOARD).assertEqual(1);
      expect(AMCL_DEVICE_CAP_POINTER_ABSOLUTE).assertEqual(2);
      expect(AMCL_DEVICE_CAP_POINTER_RELATIVE).assertEqual(4);
      expect(AMCL_DEVICE_CAP_POINTER_BUTTONS).assertEqual(8);
      expect(AMCL_DEVICE_CAP_WHEEL).assertEqual(16);
      expect(AMCL_DEVICE_CAP_TEXT).assertEqual(32);
      expect(AMCL_DEVICE_CAP_HOVER).assertEqual(64);
      expect(AMCL_DEVICE_CAP_CAPTURE).assertEqual(128);
    });

    it('DeviceClass ABI 固定且 mouse/touchpad 不再压成同一类', 0, () => {
      expect(InputDeviceClass.Unknown as number).assertEqual(0);
      expect(InputDeviceClass.Mouse as number).assertEqual(1);
      expect(InputDeviceClass.Touchpad as number).assertEqual(2);
      expect(pointerDeviceClassFromSources(['mouse']))
        .assertEqual(InputDeviceClass.Mouse);
      expect(pointerDeviceClassFromSources(['touchpad']))
        .assertEqual(InputDeviceClass.Touchpad);
    });

    it('复合/未知 inventory 与未知 event tool 显式降级 Unknown', 0, () => {
      expect(pointerDeviceClassFromSources(['mouse', 'touchpad']))
        .assertEqual(InputDeviceClass.Unknown);
      expect(pointerDeviceClassFromSources(['keyboard']))
        .assertEqual(InputDeviceClass.Unknown);
      expect(pointerDeviceClassFromSourceTool(0))
        .assertEqual(InputDeviceClass.Unknown);
      expect(pointerDeviceClassFromSourceTool(7))
        .assertEqual(InputDeviceClass.Unknown);
      expect(pointerDeviceClassFromSourceTool(3))
        .assertEqual(InputDeviceClass.Mouse);
      expect(pointerDeviceClassFromSourceTool(4))
        .assertEqual(InputDeviceClass.Touchpad);
    });

    it('平台 monotonic ns 只接受正的安全整数', 0, () => {
      expect(normalizeMonotonicTimestampNs(undefined)).assertEqual(0);
      expect(normalizeMonotonicTimestampNs(Number.NaN)).assertEqual(0);
      expect(normalizeMonotonicTimestampNs(-1)).assertEqual(0);
      expect(normalizeMonotonicTimestampNs(12.9)).assertEqual(12);
      expect(normalizeMonotonicTimestampNs(Number.MAX_SAFE_INTEGER + 1))
        .assertEqual(0);
    });
  });

  describe('KeyMap.lockStateSnapshot', () => {
    it('三个字段全缺失 → 0（未知），不置 VALID', 0, () => {
      expect(composeOhosLockState(undefined, undefined, undefined)).assertEqual(0);
    });

    it('有任一字段即置 VALID；缺失项按未锁定', 0, () => {
      expect(composeOhosLockState(false, undefined, undefined))
        .assertEqual(AMCL_LOCK_STATE_VALID);
      expect(composeOhosLockState(true, undefined, undefined))
        .assertEqual(AMCL_LOCK_STATE_VALID | AMCL_LOCK_STATE_CAPS);
      expect(composeOhosLockState(undefined, true, undefined))
        .assertEqual(AMCL_LOCK_STATE_VALID | AMCL_LOCK_STATE_NUM);
      expect(composeOhosLockState(undefined, undefined, true))
        .assertEqual(AMCL_LOCK_STATE_VALID | AMCL_LOCK_STATE_SCROLL);
    });

    it('三个锁存全开 → VALID + 三位', 0, () => {
      expect(composeOhosLockState(true, true, true)).assertEqual(
        AMCL_LOCK_STATE_VALID | AMCL_LOCK_STATE_CAPS | AMCL_LOCK_STATE_NUM |
        AMCL_LOCK_STATE_SCROLL);
    });

    it('位值与 native ABI 镜像一致：CAPS=1 NUM=2 SCROLL=4 VALID=1<<16', 0, () => {
      expect(AMCL_LOCK_STATE_CAPS).assertEqual(1);
      expect(AMCL_LOCK_STATE_NUM).assertEqual(2);
      expect(AMCL_LOCK_STATE_SCROLL).assertEqual(4);
      expect(AMCL_LOCK_STATE_VALID).assertEqual(65536);
    });

    it('VALID 位高于所有 GLFW modifier 位，误放的 mods 不可能声称已回答', 0, () => {
      // GLFW modifier 只用 bit 0..5：SHIFT 0x1 / CTRL 0x2 / ALT 0x4 / SUPER 0x8 /
      // CAPS_LOCK 0x10 / NUM_LOCK 0x20。全部与 VALID 无交集。
      const allGlfwMods = GLFW_MOD_SHIFT | GLFW_MOD_CONTROL | GLFW_MOD_CAPS_LOCK |
        GLFW_MOD_NUM_LOCK;
      expect((allGlfwMods & AMCL_LOCK_STATE_VALID) === 0).assertTrue();
    });
  });

  describe('GamepadManager.routeKeyToGamepad', () => {
    it('DPAD 4 方向码是共用码，DPAD_CENTER 与普通手柄键不是', 0, () => {
      expect(isSharedDirectionalKey(OHOS_DPAD_UP)).assertTrue();
      expect(isSharedDirectionalKey(OHOS_DPAD_DOWN)).assertTrue();
      expect(isSharedDirectionalKey(OHOS_DPAD_LEFT)).assertTrue();
      expect(isSharedDirectionalKey(OHOS_DPAD_RIGHT)).assertTrue();
      expect(isSharedDirectionalKey(OHOS_DPAD_CENTER)).assertFalse();
      expect(isSharedDirectionalKey(OHOS_BUTTON_A)).assertFalse();
    });

    it('平台报告 Keyboard 时，方向键交回 physical route', 0, () => {
      expect(routeKeyToGamepad(OHOS_DPAD_UP, true)).assertFalse();
      expect(routeKeyToGamepad(OHOS_DPAD_RIGHT, true)).assertFalse();
    });

    it('来源非 Keyboard（含 Unknown）时保持旧手柄行为', 0, () => {
      expect(routeKeyToGamepad(OHOS_DPAD_UP, false)).assertTrue();
      expect(routeKeyToGamepad(OHOS_DPAD_RIGHT, false)).assertTrue();
    });

    it('非共用手柄键与来源无关，永远走手柄', 0, () => {
      expect(routeKeyToGamepad(OHOS_BUTTON_A, true)).assertTrue();
      expect(routeKeyToGamepad(OHOS_BUTTON_A, false)).assertTrue();
      expect(routeKeyToGamepad(OHOS_BUTTON_START, true)).assertTrue();
    });

    it('非手柄键永不走手柄，且与 isGamepadKey 一致', 0, () => {
      expect(isGamepadKey(OHOS_KEY_W)).assertFalse();
      expect(routeKeyToGamepad(OHOS_KEY_W, true)).assertFalse();
      expect(routeKeyToGamepad(OHOS_KEY_W, false)).assertFalse();
    });
  });

  describe('KeyMap.composeGlfwMods', () => {
    it('held 只贡献按住型修饰键，不含锁存位', 0, () => {
      const held: Set<number> = new Set<number>();
      held.add(OHOS_SHIFT_LEFT);
      held.add(OHOS_CAPS_LOCK);
      held.add(OHOS_NUM_LOCK);
      const mods = computeGlfwHeldMods(held);
      expect((mods & GLFW_MOD_SHIFT) !== 0).assertTrue();
      expect((mods & GLFW_MOD_CAPS_LOCK) !== 0).assertFalse();
      expect((mods & GLFW_MOD_NUM_LOCK) !== 0).assertFalse();
    });

    it('VALID 快照：锁存位只来自平台，按住 Caps 不再置位', 0, () => {
      const held: Set<number> = new Set<number>();
      held.add(OHOS_CAPS_LOCK);   // 按住 Caps 但平台报告未锁定
      held.add(OHOS_CTRL_LEFT);
      const mods = composeGlfwMods(held, AMCL_LOCK_STATE_VALID);
      expect((mods & GLFW_MOD_CONTROL) !== 0).assertTrue();
      expect((mods & GLFW_MOD_CAPS_LOCK) !== 0).assertFalse();
    });

    it('VALID 快照：平台报告已锁定时置位，与是否按住无关', 0, () => {
      const held: Set<number> = new Set<number>();
      const mods = composeGlfwMods(held,
        AMCL_LOCK_STATE_VALID | AMCL_LOCK_STATE_CAPS | AMCL_LOCK_STATE_NUM);
      expect((mods & GLFW_MOD_CAPS_LOCK) !== 0).assertTrue();
      expect((mods & GLFW_MOD_NUM_LOCK) !== 0).assertTrue();
    });

    it('无 VALID：显式降级为旧的按住推断，且与兼容入口等价', 0, () => {
      const held: Set<number> = new Set<number>();
      held.add(OHOS_CAPS_LOCK);
      const degraded = composeGlfwMods(held, 0);
      expect((degraded & GLFW_MOD_CAPS_LOCK) !== 0).assertTrue();
      expect(degraded).assertEqual(computeGlfwMods(held));
    });
  });
}

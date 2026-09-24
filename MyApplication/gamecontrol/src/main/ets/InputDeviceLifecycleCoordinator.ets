/**
 * InputDeviceLifecycleCoordinator.ets — Phase 3.3 设备生命周期的纯状态部件
 *
 * 本文件刻意不依赖 inputDevice / Ability / NAPI，让插拔监听的幂等、扇出和启动期
 * inventory 竞态可以在 host-independent ArkTS 单测中穷举。平台对象仍由
 * InputDeviceMonitor 持有，native DeviceRegistry 仍是 owner 生命周期的权威状态。
 */

import { DeviceChangeEvent } from './InputDeviceAbi'

export type DeviceChangeListener = (event: DeviceChangeEvent) => void

/**
 * 进程级系统监听的注册闩锁。
 *
 * begin() 必须先于平台 register 调用，以阻断同步重入；register 抛错时调用
 * markFailed()，下一次 Ability create 才能重试。返回 false 表示已有注册者。
 */
export class ProcessDeviceMonitorRegistrationLatch {
  private active: boolean = false

  begin(): boolean {
    if (this.active) return false
    this.active = true
    return true
  }

  markFailed(): void {
    this.active = false
  }

  isActive(): boolean {
    return this.active
  }
}

/**
 * 并发异步快照的 latest-request-wins 提交门禁。
 * begin() 返回单调 token；旧请求即使更晚 resolve，也不能覆盖更新请求的结果。
 */
export class LatestAsyncRequestCommitGuard {
  private generation: number = 0

  begin(): number {
    this.generation++
    return this.generation
  }

  isCurrent(generation: number): boolean {
    return generation === this.generation
  }
}

/** 只接受协议已定义的 add/remove；未知平台枚举不能被猜成 REMOVED。 */
export function normalizeInputDeviceChange(type: string, deviceId: number): DeviceChangeEvent | undefined {
  if (type !== 'add' && type !== 'remove') return undefined
  const event: DeviceChangeEvent = {
    added: type === 'add',
    deviceId: deviceId,
  }
  return event
}

/**
 * 页面订阅者扇出。dispatch 遍历快照，因此监听器在回调内同步退订不会让后续监听器
 * 漏掉当前边沿；单个监听器抛错也不会阻断剩余订阅者。返回异常数量供外层记录诊断。
 */
export class DeviceChangeFanout {
  private listeners: DeviceChangeListener[] = []

  add(listener: DeviceChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) this.listeners.push(listener)
  }

  remove(listener: DeviceChangeListener): void {
    const index = this.listeners.indexOf(listener)
    if (index >= 0) this.listeners.splice(index, 1)
  }

  dispatch(event: DeviceChangeEvent): number {
    const snapshot: DeviceChangeListener[] = this.listeners.slice()
    let failureCount: number = 0
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](event)
      } catch (e) {
        failureCount++
      }
    }
    return failureCount
  }
}

/**
 * 启动期 inventory 与实时 add/remove 的 remove-wins 门禁。
 *
 * getDeviceList() 是异步快照：快照含 D 后若实时 REMOVED 先到，迟到续体不能再发布
 * ADDED。beginInventory() 捕获全局代次；每个实时边沿记录该设备的最新代次和在场态。
 * inventory 仅在以下情况可发布：
 *   - 此页面生命周期从未见过该设备边沿；或
 *   - 最新边沿不晚于 inventory 起点，且明确是 ADDED。
 * 最新为 REMOVED（无论早晚）或 inventory 开始后发生过任何边沿时一律拒绝。后者的
 * 实时回调已经负责发布，拒绝还能避免重复与跨平面乱序。
 */
export class DeviceInventoryPublicationGuard {
  private generation: number = 0
  private deviceGeneration: Map<number, number> = new Map()
  private devicePresent: Map<number, boolean> = new Map()

  noteRealtimeChange(deviceId: number, added: boolean): void {
    this.generation++
    this.deviceGeneration.set(deviceId, this.generation)
    this.devicePresent.set(deviceId, added)
  }

  beginInventory(): number {
    return this.generation
  }

  mayPublishAdded(deviceId: number, inventoryGeneration: number): boolean {
    const latestGeneration: number | undefined = this.deviceGeneration.get(deviceId)
    if (latestGeneration === undefined) return true
    if (latestGeneration > inventoryGeneration) return false
    return this.devicePresent.get(deviceId) === true
  }
}

/**
 * 一个 deviceId 是不是手柄 —— **三值**，`Unknown` 是承重值。
 *
 * 为什么不能用 `boolean`：调用方要据此决定"拔掉这个设备时要不要保守释放整个手柄端"。
 * `false` 与"不知道"的正确处置**相反** —— 前者可以跳过释放，后者必须照旧释放。
 * 压成两值就等于把"不知道"当成"不是"，那正是会造成卡键的方向。
 */
export enum DeviceGamepadKind {
  /** 从未成功读到该设备的 sources（详情读取失败 / 枚举失败 / 快照还没回来）。 */
  Unknown = 0,
  /** sources 含 `'joystick'` 或 `'gamepad'`。 */
  Gamepad = 1,
  /** sources 已成功读到且不含手柄类。 */
  NotGamepad = 2,
}

/**
 * deviceId → 是否手柄 的缓存表。刻意不依赖 inputDevice，让竞态可在 ArkTS 单测里穷举。
 *
 * **整表替换而不是逐条增删**：唯一的数据来源是一次成功的全量枚举，逐条打补丁会让表里
 * 混进不同时刻的观测。`forget` 是唯一的例外，理由见该方法。
 *
 * 只记录**成功读到 sources** 的设备：详情读取抛异常的设备不写入，于是它保持 `Unknown`，
 * 调用方走保守分支。这是"缺少信号 ≠ 能力缺失"（规范 §八 第二条）在这张表上的形状。
 */
export class DeviceGamepadIdentityTable {
  private isGamepadById: Map<number, boolean> = new Map()

  /**
   * 用一次成功枚举的结果整表替换。
   *
   * 必须与聚合布尔 `DeviceCapability.gamepad` 在**同一个代次判定之后**提交：分开提交会
   * 出现"`hasGamepad()` 说有、逐设备表说无"的瞬间，让按设备的门控在竞态下误放。
   */
  commitSnapshot(snapshot: Map<number, boolean>): void {
    const copy: Map<number, boolean> = new Map()
    snapshot.forEach((isGamepad: boolean, deviceId: number) => { copy.set(deviceId, isGamepad) })
    this.isGamepadById = copy
  }

  kindOf(deviceId: number): DeviceGamepadKind {
    const known: boolean | undefined = this.isGamepadById.get(deviceId)
    if (known === undefined) return DeviceGamepadKind.Unknown
    return known ? DeviceGamepadKind.Gamepad : DeviceGamepadKind.NotGamepad
  }

  /**
   * 忘掉一个设备（唯一的逐条写入口）。
   *
   * 只在实时 REMOVED 边沿**分发之后**调用：分发前调用会让消费者恰好在需要答案的那一刻
   * 拿到 `Unknown`。它不是"顺便清理"—— 全量枚举能否在 remove 之后立刻把该设备排除掉
   * **官方无时序承诺**（真机待验清单第 6 项），所以这一步是该设备不再被当作在线手柄的
   * 唯一确定性来源。
   */
  forget(deviceId: number): void {
    this.isGamepadById.delete(deviceId)
  }

  /** 当前已知在线的手柄数。诊断用（让"跳过释放"的判断在日志里可复核）。 */
  knownGamepadCount(): number {
    let count: number = 0
    this.isGamepadById.forEach((isGamepad: boolean, deviceId: number) => {
      if (isGamepad) count++
    })
    return count
  }

  /** 表里一共记了几个设备。诊断用：0 表示"整张表还没有任何观测"。 */
  knownDeviceCount(): number {
    return this.isGamepadById.size
  }
}

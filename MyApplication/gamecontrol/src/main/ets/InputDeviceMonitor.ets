import { AppLogger } from 'commons';
/**
 * InputDeviceMonitor.ets — 进程级物理设备监听，及它产出的两种视图
 *
 * ============================ 职责 ============================
 *
 * 一个系统监听（`inputDevice.on('change')`），两种下游视图：
 *
 *   1. **聚合能力** `DeviceCapability { mouse, keyboard, gamepad }`
 *      回答"现在物理上接着什么类型的设备"，不依赖用户最近是否用过。
 *      用途：**光标锁**与**指针可见性**的前置判断。
 *
 *      同一次枚举还产出**逐设备手柄身份表**（`gamepadKindOf`）。聚合布尔回答不了
 *      "被拔掉的这一个是不是手柄"，而那才是"拔键盘要不要连带放掉手柄端"的判据。
 *      两者必须同代次提交，理由见规范 §3.4。
 *
 *      ⚠️ capability **不参与虚拟按键显隐**。`GameControls.capability` 是一条只写不读的
 *      链路（"接键鼠自动隐藏"于 2026-06 刻意解耦删除，待决方案见提案 §9.1）。
 *      这里曾有一条声称相反的假注释，来历与教训见规范 §八 第六条纪律。
 *   2. **原始插拔事件** `DeviceChangeEvent { deviceId, added }`
 *      聚合能力丢掉了 deviceId，而 native core 的 held owner 以 `(deviceId, control)`
 *      为键 —— DEVICE_REMOVED 必须携带具体 deviceId 才能只释放该设备的 owner。
 *
 * 两个视图共用同一个系统监听，所以同处一个模块；它们**不是**同一个概念。
 *
 * ============================ 硬约束：进程级单实例 ============================
 *
 * 监听**不得**归某个 Ability 所有、**不得**在它的 stage destroy 时 `off` —— 两个
 * Ability 有各自独立的 WindowStage，那样仍在运行的 McGamePage 会静默失去
 * DEVICE_REMOVED（按住后拔掉的键就无法按设备收口）。所以：HAR 单例持有**不捕获
 * Ability/Page 的**回调，两个 Ability 都只调幂等的 `ensureStarted()`；注册失败必须
 * 清空字段以允许重试，绝不把失败永久锁存。
 *
 * ⚠️ HAR 单例作用域的硬约束见 `InputSourceRegistry.ets` 的类注释 —— 同样适用于本文件。
 *
 * 本文件由 `InputModeManager.ets` 拆分而来（提案 D2），拆分理由见该提案。
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import inputDevice from '@ohos.multimodalInput.inputDevice'
import { DeviceChangeEvent } from './InputDeviceAbi'
import {
  DeviceChangeFanout, DeviceGamepadIdentityTable, DeviceGamepadKind,
  LatestAsyncRequestCommitGuard,
  ProcessDeviceMonitorRegistrationLatch, normalizeInputDeviceChange,
} from './InputDeviceLifecycleCoordinator'

const TAG = 'InputDeviceMonitor'

/** 物理设备接入状态。所有字段反映"现在是否接着该类设备"，不依赖用户最近是否用过。 */
export interface DeviceCapability {
  mouse: boolean
  keyboard: boolean
  gamepad: boolean
}

class InputDeviceMonitor {
  // ============ 视图一：聚合能力（+ 与它同代次提交的逐设备手柄身份表）============
  private capability: DeviceCapability = { mouse: false, keyboard: false, gamepad: false }
  private capListeners: ((c: DeviceCapability) => void)[] = []

  // 逐设备手柄身份。`capability.gamepad` 只回答"有没有手柄"，回答不了"被拔的这个是不是
  // 手柄" —— 而后者才是"拔键盘要不要放掉手柄端"的判据。两者由同一次枚举产出，必须在
  // 同一个代次判定之后提交（理由见 DeviceGamepadIdentityTable.commitSnapshot）。
  private gamepadIdentity: DeviceGamepadIdentityTable = new DeviceGamepadIdentityTable()

  private deviceChangeHandler: ((data: inputDevice.DeviceListener) => void) | undefined = undefined
  private deviceMonitorLatch: ProcessDeviceMonitorRegistrationLatch =
    new ProcessDeviceMonitorRegistrationLatch()
  // EntryAbility、GameAbility、页面 appear 与 change 回调都可并发刷新。只允许最新请求
  // 提交，禁止较早 getDeviceList 的迟到结果把 capability 倒退成旧快照。
  private capabilityRefreshGuard: LatestAsyncRequestCommitGuard =
    new LatestAsyncRequestCommitGuard()

  /** 同步读当前设备能力（不查 SDK，直接返回缓存）。 */
  capabilityNow(): DeviceCapability {
    // 返回浅拷贝，调用方不能直接修改内部状态
    return { mouse: this.capability.mouse, keyboard: this.capability.keyboard, gamepad: this.capability.gamepad }
  }

  // 逐字段只读访问器：热路径（onMouse / onAxisEvent / 虚拟控件命中过滤）只需要一个
  // 布尔量，不该为此在每个鼠标样本上构造一个 DeviceCapability 对象。语义与
  // capabilityNow() 完全一致，只是不分配。
  hasMouse(): boolean { return this.capability.mouse }
  hasKeyboard(): boolean { return this.capability.keyboard }
  hasGamepad(): boolean { return this.capability.gamepad }

  /**
   * 这个 deviceId 是不是手柄。**三值**，`Unknown` 必须走保守分支（见 `DeviceGamepadKind`）。
   *
   * 编号域：参数取自 `inputDevice` 自己的编号域（`getDeviceList()` / `on('change')`）。
   * ⚠️ 官方**从未**说明 ArkUI 事件对象上的 `deviceId`（`KeyEvent` / `BaseEvent`）与它是不是
   * 同一个编号空间，所以**不要**拿事件里的 deviceId 来查这张表。
   */
  gamepadKindOf(deviceId: number): DeviceGamepadKind {
    return this.gamepadIdentity.kindOf(deviceId)
  }

  /** 已知在线手柄数 / 表里已有观测的设备数。仅诊断（让按设备门控的判断在日志里可复核）。 */
  knownGamepadCount(): number { return this.gamepadIdentity.knownGamepadCount() }
  knownDeviceCount(): number { return this.gamepadIdentity.knownDeviceCount() }

  /** 监听 capability 变化（设备插拔时回调）。 */
  addCapabilityListener(cb: (c: DeviceCapability) => void): void {
    // Ability/Page lifecycle may re-enter aboutToAppear. The same callback must never be
    // retained twice, otherwise one remove leaves a stale page closure behind.
    if (this.capListeners.indexOf(cb) < 0) this.capListeners.push(cb)
  }
  removeCapabilityListener(cb: (c: DeviceCapability) => void): void {
    const idx = this.capListeners.indexOf(cb)
    if (idx >= 0) this.capListeners.splice(idx, 1)
  }

  // ============ 视图二：原始插拔事件（携带 deviceId）============
  //
  // 归属：本单例只做扇出，不持有任何输入协议状态。系统监听也由本单例按进程期幂等注册；
  // 页面只按 add/remove 成对订阅扇出，避免 Ability/Page 重建时重复注册系统监听
  // 或重复接收同一次边沿。
  private deviceFanout: DeviceChangeFanout = new DeviceChangeFanout()

  addDeviceChangeListener(cb: (e: DeviceChangeEvent) => void): void {
    // aboutToAppear/WindowStage 重入不应让同一个页面回调收到两次 REMOVED。
    this.deviceFanout.add(cb)
  }

  removeDeviceChangeListener(cb: (e: DeviceChangeEvent) => void): void {
    this.deviceFanout.remove(cb)
  }

  /**
   * 由本单例持有的 inputDevice.on('change') 回调调用。
   *
   * 单个监听器抛异常不能影响其余监听器，也不能让系统回调整体失败：拔设备时若因为
   * 一个监听器出错而中断分发，剩下的监听器就永远收不到这次移除，被拔设备的 held
   * owner 会一直留着。因此逐个 try/catch（在 DeviceChangeFanout 内部）。
   */
  notifyDeviceChange(event: DeviceChangeEvent): void {
    const failureCount: number = this.deviceFanout.dispatch(event)
    if (failureCount > 0) {
      AppLogger.warn(TAG, `device listener failures: ${failureCount}`)
    }
  }

  // ============ 系统监听的幂等启动 ============

  /**
   * 幂等启动进程级物理设备监听。两个 Ability 的 onCreate 都调它。
   *
   * 该监听只做两件事：刷新聚合 capability，并把带 deviceId 的原始 add/remove 扇出给
   * 当前页面。它不持有 held、epoch 或 backend 状态；那些仍分别属于页面临时缓存与
   * native InputStateCore。回调不捕获 Ability，因此不能延长窗口生命周期。
   */
  ensureStarted(): void {
    if (!this.deviceMonitorLatch.begin()) {
      this.refreshCapability()
      return
    }

    const handler = (data: inputDevice.DeviceListener): void => {
      this.refreshCapability()
      const event: DeviceChangeEvent | undefined =
        normalizeInputDeviceChange(data.type as string, data.deviceId)
      if (event === undefined) {
        // 未知平台枚举绝不能被 `else` 猜成 REMOVED；误删一个 deviceId 会释放
        // 本来仍有效的 owner。保留 capability 刷新，但拒绝协议边沿。
        AppLogger.warn(TAG, `unsupported inputDevice change type`)
        return
      }
      this.notifyDeviceChange(event)
      if (!event.added) {
        // **分发之后**才忘：消费者正是在这一刻需要"被拔的是不是手柄"的答案。
        //
        // 已知竞态（方向是安全的，不修）：上面那次 refreshCapability 是异步的，若平台的
        // getDeviceList 在 remove 之后仍短暂含该设备（官方无时序承诺），它的整表提交会把
        // 这条记录重新写回来。后果只是该设备在下一次刷新前仍被当作在线手柄，即"照旧保守
        // 释放手柄端" —— 与本次改动之前的行为相同，不会退化成漏放。
        this.gamepadIdentity.forget(event.deviceId)
      }
    }
    try {
      // 先发布 provisional 字段，阻断同步重入造成的重复注册；系统 API 抛错时清空，
      // 下一次 Ability create 仍可重试。
      this.deviceChangeHandler = handler
      inputDevice.on('change', handler)
      this.refreshCapability()
      hilog.info(0x0000, TAG, 'process inputDevice listener registered')
    } catch (e) {
      this.deviceChangeHandler = undefined
      this.deviceMonitorLatch.markFailed()
      AppLogger.warn(TAG, `inputDevice listener register failed: ${(e as Error).message}`)
    }
  }

  /**
   * 全量重查物理设备列表，更新 capability。
   *
   * 调用时机：
   *   - EntryAbility / GameAbility onCreate 的幂等 ensureStarted（初始化）
   *   - inputDevice.on('change') 回调里（插拔事件）
   *   - McGamePage.aboutToAppear 兜底（避免事件丢失）
   *
   * inputDevice.getDeviceList / getDeviceInfoSync 都是 since 9 + 第三方应用可用。
   */
  async refreshCapability(): Promise<void> {
    const refreshGeneration: number = this.capabilityRefreshGuard.begin()
    let cap: DeviceCapability = { mouse: false, keyboard: false, gamepad: false }
    // 逐设备手柄身份与聚合布尔来自同一次遍历。只登记**成功读到 sources** 的设备：
    // 详情读取失败的那一个不写入，于是它保持 Unknown 而不是被记成"不是手柄"。
    const gamepadByDevice: Map<number, boolean> = new Map()
    try {
      const ids: number[] = await inputDevice.getDeviceList()
      for (let i = 0; i < ids.length; i++) {
        try {
          const info = inputDevice.getDeviceInfoSync(ids[i])
          let isGamepad: boolean = false
          for (let j = 0; j < info.sources.length; j++) {
            const s = info.sources[j] as string
            if (s === 'mouse' || s === 'touchpad') cap.mouse = true
            else if (s === 'keyboard') cap.keyboard = true
            else if (s === 'joystick' || s === 'gamepad') { cap.gamepad = true; isGamepad = true }
          }
          gamepadByDevice.set(ids[i], isGamepad)
        } catch (e) {
          // 某个 device 取详情失败不致命，跳过
        }
      }
    } catch (e) {
      AppLogger.warn(TAG, `refreshCapability failed: ${(e as Error).message}`)
      return
    }
    if (!this.capabilityRefreshGuard.isCurrent(refreshGeneration)) return
    // 无条件提交（不放进下面的 changed 分支）：逐设备构成可以变化而聚合三个布尔不变
    // —— 拔掉手柄 A 同时插上手柄 B 时 `gamepad` 一直是 true，但表必须换。
    this.gamepadIdentity.commitSnapshot(gamepadByDevice)
    if (cap.mouse !== this.capability.mouse ||
        cap.keyboard !== this.capability.keyboard ||
        cap.gamepad !== this.capability.gamepad) {
      this.capability = cap
      hilog.info(0x0000, TAG, 'capability changed: mouse=%{public}s keyboard=%{public}s gamepad=%{public}s',
        cap.mouse ? '1' : '0', cap.keyboard ? '1' : '0', cap.gamepad ? '1' : '0')
      this.fireCapability()
    }
  }

  private fireCapability(): void {
    const snapshot = this.capabilityNow()
    for (let i = 0; i < this.capListeners.length; i++) {
      try { this.capListeners[i](snapshot) } catch (e) {
        AppLogger.warn(TAG, 'capability listener threw: ' + (e as Error).message)
      }
    }
  }
}

let monitor: InputDeviceMonitor | undefined = undefined

/** 进程内单例。约束见文件头与 InputSourceRegistry.ets 的 HAR 作用域说明。 */
export function getInputDeviceMonitor(): InputDeviceMonitor {
  if (!monitor) monitor = new InputDeviceMonitor()
  return monitor
}

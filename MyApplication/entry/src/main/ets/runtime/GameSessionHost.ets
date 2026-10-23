/**
 * 单局游戏的输入运行宿主。进程模块只保存本局实例，页面拿前端租约；页面重建不会
 * 重建映射来源、配置订阅或维护时钟。高频键鼠/触控仍走原生产端口，不经宿主转发。
 * 所有方法运行在 ArkTS 事件线程；Native 窗口/consumer 失效仍在各自线程立即生效。
 * 共同维护只依赖Native维护scope，触控前端通过受限来源接口登记；因此desktop宿主
 * 不会因持有维护资格而把移动布局、触控组件或陀螺仪前端带入编译依赖闭包。
 */
import { common, Want, appRecovery } from '@kit.AbilityKit'
import { systemDateTime } from '@kit.BasicServicesKit'
import { AppLogger, ActivityLogger, LOG_DOMAIN_LAUNCH } from 'commons'
import { GamepadManager, GamepadEmitter, GameInputRuntime, SourceControlClient,
  AmclInputSource, GLFW_PRESS, getInputSourceRegistry, getInputDeviceMonitor,
  getPointerVisibility, LayoutStore, InputConfigurationRuntime,
  InputDeviceConnectionReader, InputDeviceConnectionLease, InputDeviceConnectionChange } from 'gamecontrol'
import { parseInputPlan } from 'launch'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { ProductGameWindowCoordinator, ProductGameWindowSnapshot } from 'entry/ProductGameWindowCoordinator'
import testNapi from 'libentry.so'
import { createEntrySourceControlClient } from '../components/EntrySourceControlClient'
import { reconcileEntryInputSession } from '../components/EntryInputSessionCoordinator'
import { EntryTextInputRuntime, EntryTextInputRuntimeSnapshot } from './EntryTextInputRuntime'
import { EntryTouchInputMaintenanceLease, startEntryTouchInputMaintenance,
  reconcileEntryTouchInputMaintenance, reconcileEntryTouchInputMaintenanceCleanup,
  EntryTouchInputMaintenanceStopReceipt, stopEntryTouchInputMaintenance } from '../components/EntryTouchInputMaintenance'
import { GameLaunchGate } from './GameLaunchGate'
import { GamepadOutputRoute, NativeGamepadRouteDecision, resolveNativeGamepadRoute,
  NATIVE_GAMEPAD_ROUTE_REQUESTED_KEY, NATIVE_GAMEPAD_CAPTURE_READY_KEY } from './NativeGamepadRoutePolicy'

// 与原文本停资源同量级的有限安全预算；复用Host原250ms heartbeat槽，不新增生产时钟。
const TOUCH_STOP_RETRY_BUDGET: number=5
const TOUCH_STOP_BUDGET_MS: number=2000
// 主动退出可能尚未进入Native JVM exit hook，不能只借它的3秒pipe预算。此一次性
// 期限仅约束ArkTS等待前台请求；不宣称取消OS请求、前台已显示或进程已在3秒内终止。
const EXIT_HANDOFF_BUDGET_MS: number=3000

/** 前端只收状态和观察机会；去掉订阅不会停止输入维护或游戏退出检测。 */
export interface GameSessionFrontend {
  onState: (grabbed: boolean, active: boolean) => void
  onMaintenance: () => void
  onLog: () => void
}

/** 仅限本进程对象身份比较，id 用于日志；不替代任何 Native uint64 资源身份。 */
export class GameFrontendLease {
  readonly id: number
  retired: boolean = false
  constructor(id: number) { this.id = id }
}

/** 单步清理回执只陈述本步是否完成；异常不阻断后续资源收口。 */
export interface GameSessionCleanupStep {
  name: string
  completed: boolean
  reason: string
}

/** 最多16个原前端等待者；等待只组织装配，不代表consumer READY或取消持久存储事务。 */
interface InputPreparationWaiter {
  finish: (ready: boolean) => void
  timer: number
}

export class GameSessionHost {
  readonly gamepad: GamepadManager
  readonly inputRuntime: GameInputRuntime
  /** IME controller及必要维护归本局，前端只绑定原UI资源和观察；构造不取OS/Native能力。 */
  readonly textInputRuntime: EntryTextInputRuntime = new EntryTextInputRuntime()
  /** 单局single-flight属于会话，重建页面不能并行准备第二次Native/JVM启动。 */
  readonly launchGate: GameLaunchGate = new GameLaunchGate()
  /** 同一Monitor reader覆盖客户端/归约器；应用scope只围栏已接收事实，不冒称Native连接代。 */
  private readonly deviceConnections: InputDeviceConnectionReader = getInputDeviceMonitor().connectionReader()
  private controls: SourceControlClient = createEntrySourceControlClient(AmclInputSource.Gamepad,
    (): string => '', this.deviceConnections)
  private connectionSubscribed: boolean = false
  /** 接入后原remove直接退原对象；页面重建/观察退订不终止映射来源的连接维护。 */
  private connectionListener: (event: InputDeviceConnectionChange) => void =
    (event: InputDeviceConnectionChange): void => {
      if (!event.added && event.originalConnection !== undefined)
        this.gamepad.releaseConnection(event.originalConnection)
    }
  private configuration: InputConfigurationRuntime = new InputConfigurationRuntime()
  /** 新私有契约的存在按进程冻结；错误/暂不可用不能自动改走旧JS积分并绕过身份检查。 */
  private readonly sharedLookContractDeclared: boolean
  private state: string = 'Created'
  private activityId: number = 0
  private context: common.UIAbilityContext | undefined = undefined
  private lease: GameFrontendLease | undefined = undefined
  private frontend: GameSessionFrontend | undefined = undefined
  private nextLease: number = 1
  private requestedActive: boolean = false
  private grabbed: boolean = false
  private launched: boolean = false
  private windowId: number = 0
  private heartbeat: number = -1
  private runtimePoll: number = -1
  private maintenanceExecuting: boolean = false
  private runtimePollExecuting: boolean = false
  private startTimer: number = -1
  private exitStarted: boolean = false
  private inputPlanWire: string = ''
  private failureCounts: Map<string, number> = new Map<string, number>()
  private cleanup: GameSessionCleanupStep[] = []
  private grabSubscribed: boolean = false
  private productConfigured: boolean = false
  private inputPrepared: boolean = false
  private preparationWaiters: InputPreparationWaiter[] = []
  private touchMaintenance: EntryTouchInputMaintenanceLease | undefined = undefined
  /** 原退休回执保到真实确认或进程收尾；超限不能丢原句柄或伪改Clean。 */
  private touchStopReceipt: EntryTouchInputMaintenanceStopReceipt | undefined = undefined
  private touchStopStep: GameSessionCleanupStep | undefined = undefined
  private touchStopAttempts: number=0
  private touchStopDeadline: number=0
  /** 只持Native异步GUI服务的原会话身份；前端重建共用，停止不等待可能停在JVM里的worker。 */
  private guiObservationScope: number = 0
  private guiObservationAttempted: boolean = false
  /** 用户路由请求和平台采集事实按本局冻结；实际ABI出口与来源开关分别确认。 */
  private gamepadRouteFactsFrozen: boolean = false
  private gamepadNativeRequested: boolean = false
  private gamepadCaptureReady: boolean = false
  private gamepadRouteDecision: NativeGamepadRouteDecision | undefined = undefined
  private gamepadRouteDescription: string = ''
  private coordinator: ProductGameWindowCoordinator = new ProductGameWindowCoordinator()
  private windowEntered: boolean = false
  private enteringWindow: Promise<ProductGameWindowSnapshot> | undefined = undefined
  private restoringWindow: Promise<void> | undefined = undefined
  /** 同局重建前端的只读显示基线，不重新解析运行库或再次调用 JVM。 */
  gameDirectory: string = ''
  realGameVersion: string = ''
  minecraftDirectory: string = ''

  constructor() {
    this.sharedLookContractDeclared = typeof testNapi.sharedLookExecutionSupported === 'function'
    // emitter 捕获稳定会话而非页面；被冻结的 control/device 配对继续由共同来源客户端维护。
    const emitter: GamepadEmitter = {
      // 来源先登记原intent，再调Native；同步回入退连接由Client按返回原token精准收尾。
      emitControlForConnection: (connection: InputDeviceConnectionLease, control: string, code: number, action: number): boolean => {
        if (action === GLFW_PRESS && (!this.active() || this.state === 'Ended')) return false
        return action === GLFW_PRESS ? this.controls.acquireForConnection(connection, control, [code]).length > 0
          : this.controls.releaseForConnection(connection, control)
      },
      releaseConnectionControls: (connection: InputDeviceConnectionLease): boolean => {
        return this.controls.releaseConnection(connection)
      },
      reconcileConnectionControls: (): boolean => { return this.controls.reconcileRetirements() },
      emitLookVelocityForConnection: (connection: InputDeviceConnectionLease, child: number, x: number, y: number): boolean => {
        if (!this.active() || !this.grabbed || !this.deviceConnections.accepts(connection) ||
          !this.deviceConnections.allowsLegacyDeviceField(connection)) return false
        try { return testNapi.setMappedLookVelocity(connection.rawPlatformId, child, x, y) }
        catch (_) { return false }
      },
      retireLookForConnection: (connection: InputDeviceConnectionLease, child: number): boolean => {
        // cleanup只携原lease下子流；不要求原对象仍live，不查询current(rawID)后误退新同ID。
        try { return testNapi.retireMappedLookConnection(connection.rawPlatformId, child) }
        catch (_) { return false }
      },
      emitScrollForConnection: (connection: InputDeviceConnectionLease, direction: number): boolean => {
        if (!this.active() || !this.deviceConnections.accepts(connection) ||
          !this.deviceConnections.allowsLegacyDeviceField(connection)) return false
        try { return testNapi.sendSourceScrollEvent(AmclInputSource.Gamepad, 0, direction) }
        catch (_) { return false }
      },
      emitLookDeltaForConnection: (connection: InputDeviceConnectionLease, x: number, y: number, ns: number): boolean => {
        if (!this.active() || !this.grabbed || !this.deviceConnections.accepts(connection) ||
          !this.deviceConnections.allowsLegacyDeviceField(connection)) return false
        try { return testNapi.sendSourceCursorSample(AmclInputSource.Gamepad, x, y, ns) }
        catch (_) { return false }
      },
      // 旧未声明此端口的显式兼容宿主仍使用旧delta。当前新端口必须在prepare证明owner；
      // source/consumer未Ready时只Pending，不在一次拒绝后切另一副作用执行模型。
      lookExecutionMode: this.sharedLookContractDeclared ? 'neutral-rate-v1' : 'legacy-delta',
      emitLookVelocity: (device: number, connection: number, x: number, y: number): boolean => {
        if (!this.active() || !this.grabbed) return false
        try { return testNapi.setMappedLookVelocity(device, connection, x, y) }
        catch (_) { return false }
      },
      advanceLookExecution: (): boolean => {
        if (!this.active() || !this.grabbed) return false
        try { return testNapi.advanceMappedLookExecution() }
        catch (_) { return false }
      },
      retireLookConnection: (device: number, connection: number): boolean => {
        // 本连接取消是清理权限，不能因Stopping或当前grab已翻转而拒绝原stream的退休。
        try { return testNapi.retireMappedLookConnection(device, connection) }
        catch (_) { return false }
      },
      emitControl: (device: number, control: string, code: number, action: number): boolean => {
        if (action === GLFW_PRESS && !this.active()) return false
        if (this.state === 'Ended') return false
        return action === GLFW_PRESS ? this.controls.acquire(control, [code], device).length > 0
          : this.controls.release(control, device)
      },
      dropControlsAfterNativeReset: (): void => { this.controls.dropAfterNativeReset() },
      emitKey: (key: number, action: number): boolean => {
        if ((action === GLFW_PRESS && !this.active()) || this.state === 'Ended') return false
        try { return testNapi.sendSourceKeyEvent(AmclInputSource.Gamepad, key, 0, action, 0) }
        catch (_) { return false }
      },
      emitMouse: (button: number, action: number): boolean => {
        if ((action === GLFW_PRESS && !this.active()) || this.state === 'Ended') return false
        try { return testNapi.sendSourceMouseEvent(AmclInputSource.Gamepad, button, action, 0) }
        catch (_) { return false }
      },
      emitScroll: (direction: number): boolean => {
        if (!this.active()) return false
        try { return testNapi.sendSourceScrollEvent(AmclInputSource.Gamepad, 0, direction) }
        catch (_) { return false }
      },
      emitLookDelta: (dx: number, dy: number, ns: number = 0): boolean => {
        if (!this.active() || !this.grabbed) return false
        try { return testNapi.sendSourceCursorSample(AmclInputSource.Gamepad, dx, dy, ns) }
        catch (_) { return false }
      }
    }
    this.gamepad = new GamepadManager(undefined, emitter, this.deviceConnections)
    this.inputRuntime = new GameInputRuntime(this.gamepad,
      (): number => systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE),
      (): void => { this.textInputRuntime.maintain() },
      (): void => { reconcileEntryInputSession() },
      (): void => { this.refreshEligibility() },
      (): void => { this.refreshEligibility() })
  }

  /** 会话状态查询不触发输入、配置应用或平台调用。 */
  lifecycle(): string { return this.state }
  isRunning(): boolean { return this.launched && !this.ended() }
  isEnded(): boolean { return this.ended() }
  /** 无路由ID的同局重建复用已确认活动，不能重新用Date.now产生第二局身份。 */
  sessionActivity(): number { return this.activityId }
  /** 与现有活动账本共用身份；首次无路由ID时仍由既有启动入口生成，不另造主键。 */
  bindActivity(activityId: number): void {
    if (!Number.isSafeInteger(activityId) || activityId <= 0 || this.ended()) throw new Error('Invalid game activity')
    if (this.activityId > 0 && this.activityId !== activityId) throw new Error('Game activity already frozen')
    // 无路由ID时，原配置实例可以先准备；真实启动入口确认活动之后仅绑定原准备代。
    // 已停止/不同局或同步观察回调结束宿主时拒绝，不重新装配配置、重发成功域或造主键。
    if (this.inputPrepared && this.activityId === 0 &&
      (!this.configuration.bindSession(activityId) || this.ended())) {
      throw new Error('Input policy session could not bind original preparation')
    }
    this.activityId = activityId
  }
  get windowCoordinator(): ProductGameWindowCoordinator { return this.coordinator }

  /**
   * 窗口获取/释放串行属于本局资源绑定。新前端等待原enter及原restore收口后才取得
   * 新publisher；迟到旧enter只恢复它原来取得的coordinator，不碰后来窗口。
   */
  async enterWindow(lease: GameFrontendLease | undefined, context: common.UIAbilityContext): Promise<ProductGameWindowSnapshot> {
    const pending: Promise<ProductGameWindowSnapshot> | undefined = this.enteringWindow
    if (pending !== undefined) { try { await pending } catch (_) { /* 原获取已自行恢复。 */ } }
    if (this.restoringWindow !== undefined) await this.restoringWindow
    if (!this.accepts(lease)) throw new Error('Stale frontend window acquisition')
    if (this.windowEntered) return this.coordinator.snapshot()
    const coordinator: ProductGameWindowCoordinator = new ProductGameWindowCoordinator()
    this.coordinator = coordinator
    const entering: Promise<ProductGameWindowSnapshot> = this.enterWindowInternal(lease, context, coordinator)
    this.enteringWindow = entering
    try { return await entering }
    finally { if (this.enteringWindow === entering) this.enteringWindow = undefined }
  }

  private async enterWindowInternal(lease: GameFrontendLease | undefined,
    context: common.UIAbilityContext, coordinator: ProductGameWindowCoordinator): Promise<ProductGameWindowSnapshot> {
    try {
      const snapshot: ProductGameWindowSnapshot = await coordinator.enter(context)
      if (!this.accepts(lease)) throw new Error('Frontend retired during window acquisition')
      this.windowEntered = true
      this.windowId = snapshot.windowId
      return snapshot
    } catch (error) {
      try { await coordinator.restore() } catch (restoreError) { this.noteFault('window-prepare-restore', restoreError) }
      throw error as Error
    }
  }

  /** 原资源幂等退休；只有当前coordinator才改变本局的窗口事实。 */
  async restoreWindow(coordinator: ProductGameWindowCoordinator): Promise<void> {
    if (this.coordinator !== coordinator) { await coordinator.restore(); return }
    this.windowEntered = false
    const restoring: Promise<void> = coordinator.restore()
    this.restoringWindow = restoring
    try { await restoring }
    finally { if (this.restoringWindow === restoring) this.restoringWindow = undefined }
  }

  /** 已解析路径随本局保留，只为重建前端恢复控制布局/日志展示。 */
  rememberGame(directory: string, version: string, minecraftDirectory: string): void {
    this.gameDirectory = directory
    this.realGameVersion = version
    this.minecraftDirectory = minecraftDirectory
  }

  /** attach 仅替换前端能力；旧闭包立即失效，同局运行资源和 JVM 占用事实不变。 */
  attach(context: common.UIAbilityContext, activityId: number, frontend: GameSessionFrontend): GameFrontendLease {
    if (this.ended()) throw new Error('Game session retired')
    if (this.nextLease >= 9007199254740991) throw new Error('Frontend lease exhausted; process restart required')
    if (this.activityId > 0 && activityId > 0 && this.activityId !== activityId) {
      throw new Error('Game session activity conflict; process restart required')
    }
    if (activityId > 0) this.activityId = activityId
    this.context = context
    // scope先于前端控件构造建立。GUI只是观察/恢复能力，缺席不剥夺基本输入和退出资格；
    // 每局仅尝试一次，不让重建页面暗中创建另一会话或把旧异步结果绑定新局。
    if (!this.guiObservationAttempted && this.activityId > 0) {
      this.guiObservationAttempted = true
      try {
        const scope: number = testNapi.gameGuiStartSession(this.activityId)
        if (!Number.isSafeInteger(scope) || scope <= 0 || scope > 4294967295) {
          throw new Error('Native GUI observation unavailable')
        }
        this.guiObservationScope = scope
      } catch (error) { this.noteFault('gui-observation-start', error) }
    }
    if (this.lease !== undefined) {
      this.lease.retired = true
      this.settlePreparation(false)
      this.launchGate.retireBeforeNative()
      // 替换前端时退休原窗口publisher，新enter必须等原restore，不能共用旧页面的恢复事务。
      this.restoreWindow(this.coordinator).catch((error: Error): void => { this.noteFault('frontend-rebind-window', error) })
    }
    this.requestedActive = false
    const lease: GameFrontendLease = new GameFrontendLease(this.nextLease++)
    this.lease = lease
    this.frontend = frontend
    this.refreshEligibility()
    return lease
  }

  /** 迟到 detach 不得注销新页面。只有本租约的输入资格及延迟启动被撤销，不全局 cancel。 */
  detach(lease: GameFrontendLease): void {
    lease.retired = true
    if (this.lease !== lease) return
    this.settlePreparation(false)
    this.cancelScheduledStart()
    this.launchGate.retireBeforeNative()
    this.requestedActive = false
    this.frontend = undefined
    this.lease = undefined
    this.refreshEligibility()
  }

  /** 真实窗口资源退休由前端资源适配报告；旧租约不能解锁已交给新前端的窗口。 */
  retireWindow(lease: GameFrontendLease | undefined, windowId: number): boolean {
    if (!this.accepts(lease) || this.windowId !== windowId) return false
    this.requestedActive = false
    this.runStep('window-unlock', (): void => { testNapi.setCursorLocked(windowId, false) })
    this.runStep('window-filter-retire', (): void => { testNapi.uninstallWindowInputFilters(windowId) })
    this.windowId = 0
    this.refreshEligibility()
    return true
  }

  /** 所有异步续体都核原租约，不能读取 current 后把旧任务重新绑定到新前端。 */
  accepts(lease: GameFrontendLease | undefined): boolean {
    return lease !== undefined && this.lease === lease && !lease.retired && !this.ended()
  }

  /** 每个启动操作强制绑定原前端；串行等待期间退休的操作不能占下一次Native启动。 */
  runLaunch(lease: GameFrontendLease | undefined, operation: () => Promise<void>): Promise<void> {
    return this.launchGate.run(operation, (): boolean => this.accepts(lease))
  }

  /**
   * Surface延迟并不能证明布局基线就绪。启动在原lease等待真实prepare完成；前端/会话
   * 退休立即得到false。120s仅为该启动等待的有界截止，未完成存储事务不被取消或覆盖，
   * 超时结束本局输入资格，迟到初始化不能重新开启它；此预算不是设备性能验收结果。
   */
  waitPrepared(lease: GameFrontendLease | undefined): Promise<boolean> {
    if (!this.accepts(lease)) return Promise.resolve(false)
    if (this.inputPrepared) return Promise.resolve(true)
    if (this.preparationWaiters.length >= 16) return Promise.resolve(false)
    return new Promise<boolean>((resolve): void => {
      const waiter: InputPreparationWaiter = {
        finish: (ready: boolean): void => { resolve(ready && this.accepts(lease)) },
        timer: -1
      }
      waiter.timer = setTimeout((): void => {
        const index: number = this.preparationWaiters.indexOf(waiter)
        if (index < 0) return
        this.preparationWaiters.splice(index, 1)
        waiter.finish(false)
        this.noteFault('input-preparation-timeout', new Error('Input baseline not ready within 120 seconds'))
        this.stop('input-preparation-timeout')
      }, 120000) as number
      this.preparationWaiters.push(waiter)
    })
  }

  /** 产品锁存先于来源/Surface 注册；相同进程重复配置只核一致性，不制造第二份策略。 */
  configureProduct(statusStore?: LayoutStore): void {
    if (this.ended()) throw new Error('Game session retired before product preparation')
    if (this.productConfigured) return
    this.state = 'Preparing'
    try {
      ProductInputProfile.freeze()
      const policy = ProductInputProfile.current()
      const result: number = testNapi.configureInputProduct(policy.productKind, policy.runtimeApi)
      if (result === 5) throw new Error('Native input source owner contract unavailable')
      if (result !== 0 && result !== 1) throw new Error('Native input product rejected: result=' + result)
      this.productConfigured = true
      // 纯报告资格先于页面/控件的布局等待建立；此时不读默认定义、不应用Native政策。
      if (statusStore !== undefined) this.configuration.prepareStatus(statusStore, this.activityId)
    } catch (error) {
      this.state = 'Failed'
      this.stop('input-product-prepare-failed')
      throw error as Error
    }
  }

  /** 持久仓库就绪之后装配会话运行体。注册表只清点来源，不成为新的政策权威。 */
  prepare(store: LayoutStore): void {
    if (this.ended()) throw new Error('Game session retired during prepare')
    if (!this.productConfigured) throw new Error('Input product not configured')
    try {
      if (this.sharedLookContractDeclared && !testNapi.sharedLookExecutionSupported()) {
        throw new Error('Shared look execution owner contract unavailable')
      }
      getInputSourceRegistry().register(this.inputRuntime)
      if (this.touchMaintenance === undefined) this.touchMaintenance = startEntryTouchInputMaintenance()
      // 政策回执绑定本局真实activity；保存/应用/迟到完成不能借用后来会话的身份。
      this.configuration.start(store, this.activityId)
      if (this.ended()) throw new Error('Input session retired during configuration prepare')
      this.textInputRuntime.start()
      if (this.ended()) throw new Error('Input session retired during text runtime prepare')
      if (!this.connectionSubscribed) {
        getInputDeviceMonitor().addConnectionListener(this.connectionListener)
        this.connectionSubscribed = true
      }
      this.inputRuntime.start(store)
      this.inputRuntime.resumeAfterLifecycle()
      // 采集就绪不能升级为实际ABI出口。尚未绑定计划保持映射，L2明确保留降级；
      // GLFW/SDL可提供原生出口时尊重用户“由游戏处理”选择，不从查询次数推定接管。
      if (!this.gamepadRouteFactsFrozen) {
        this.gamepadRouteFactsFrozen = true
        this.gamepadNativeRequested = AppStorage.get<boolean>(NATIVE_GAMEPAD_ROUTE_REQUESTED_KEY) ?? false
        this.gamepadCaptureReady = AppStorage.get<boolean>(NATIVE_GAMEPAD_CAPTURE_READY_KEY) ?? false
      }
      this.reconcileGamepadRoute()
      if (!this.launched) this.state = 'Bound'
      this.inputPrepared = true
      this.settlePreparation(true)
      this.refreshEligibility()
      this.startMaintenance()
    } catch (error) {
      // 取得一半资源时也沿同一依赖清理，单步失败不掩盖原准备错误。
      this.state = 'Failed'
      this.stop('input-source-prepare-failed')
      throw error as Error
    }
  }

  /** 启动冻结计划只校验/保存，不表示游戏 consumer READY；真实注册继续由 Native 实例产生。 */
  bindPlan(wire: string): void {
    if (this.ended() || parseInputPlan(wire) === undefined) throw new Error('Invalid or retired input plan')
    if (this.inputPlanWire.length > 0 && this.inputPlanWire !== wire) throw new Error('Input plan already frozen')
    this.inputPlanWire = wire
    if (this.gamepadRouteFactsFrozen) this.reconcileGamepadRoute()
    this.runStep('input-plan-log', (): void => {
      this.logger().info('InputSession', 'input_plan activity=' + this.activityId + ' ' + wire, LOG_DOMAIN_LAUNCH)
    })
  }

  /** 原前端在进入Native不可重建边界前最后核身份，随后任何页面都不能再重试此调用。 */
  markNativeAttempted(lease: GameFrontendLease | undefined): void {
    if (!this.accepts(lease)) throw new Error('Frontend retired before Native launch')
    if (!this.inputPrepared) throw new Error('Input baseline not prepared before Native launch')
    this.launchGate.markNativeAttempted()
  }

  /** 前端提交真实可见/焦点/窗口合取值；Ability 墓碑仍由来源运行体保持，不能被旧 UI 覆盖。 */
  setFrontendState(lease: GameFrontendLease | undefined, active: boolean, windowId: number): void {
    if (!this.accepts(lease)) return
    this.requestedActive = active
    this.windowId = windowId
    this.refreshEligibility()
  }

  /** Surface 的延迟仅用于现有启动等待；保存句柄且绑定前端，detach/stop 后不可启动 JVM。 */
  scheduleStart(lease: GameFrontendLease | undefined, start: () => Promise<void>): void {
    if (!this.accepts(lease) || this.launched) return
    this.cancelScheduledStart()
    this.startTimer = setTimeout((): void => {
      this.startTimer = -1
      if (!this.accepts(lease) || this.launched) return
      try { start().catch((error: Error): void => { this.noteFault('start', error) }) }
      catch (error) { this.noteFault('start-dispatch', error) }
    }, 500) as number
  }

  /** 仅承认本次 Native 启动调用成功。进程 JVM marker 不在这里创建/复位。 */
  markRunning(): void {
    if (this.ended() || this.inputPlanWire.length === 0) throw new Error('Input session launch not prepared')
    if (!this.inputPrepared) throw new Error('Input baseline not prepared')
    this.launched = true
    this.state = 'Running'
    if (!this.grabSubscribed) {
      this.grabSubscribed = true
      try {
        testNapi.onGrabChange((grabbed: boolean): void => {
          if (!this.ended()) this.applyGrab(grabbed)
        })
      } catch (error) { this.noteFault('grab-subscribe', error) }
    }
    this.startMaintenance()
    this.startRuntimePoll()
  }

  /**
   * 读取本宿主唯一停止事务在调用时的值快照；停止前为空。只复制标量字段，既不推进
   * 清理，也不把内部可变步骤借给观察者。异步资源完成后须重新读取，旧快照保持原值；
   * 调用方修改返回数组或步骤不会改变日志、清理预算及重试资格。
   */
  cleanupSnapshot(): GameSessionCleanupStep[] {
    return this.cleanup.map((step: GameSessionCleanupStep): GameSessionCleanupStep => {
      return { name: step.name, completed: step.completed, reason: step.reason }
    })
  }

  /**
   * 同步关闭本局输入准入并启动各域清理，重复调用不重做副作用，返回独立值快照。
   * Ended只表示输入终态；Pending资源由原异步步骤继续收口，真实进程结束仍另行确认。
   */
  stop(reason: string): GameSessionCleanupStep[] {
    if (this.ended()) return this.cleanupSnapshot()
    this.state = 'Stopping'
    this.inputPrepared = false
    this.settlePreparation(false)
    this.requestedActive = false
    if (this.lease !== undefined) this.lease.retired = true
    this.frontend = undefined
    this.lease = undefined
    // 先撤三个原timer的本地句柄；任何clearTimeout异常只失败该清理步骤，不能跳过停源。
    const startTimer: number=this.startTimer
    const heartbeat: number=this.heartbeat
    const runtimePoll: number=this.runtimePoll
    this.startTimer = -1
    this.heartbeat = -1
    this.runtimePoll = -1
    this.cleanupStep('start-timer-stop', (): void => { if (startTimer>=0) clearTimeout(startTimer) })
    this.cleanupStep('heartbeat-stop', (): void => { if (heartbeat>=0) clearTimeout(heartbeat) })
    this.cleanupStep('runtime-poll-stop', (): void => { if (runtimePoll>=0) clearTimeout(runtimePoll) })
    this.cleanupStep('gui-observation-stop', (): void => {
      const scope: number = this.guiObservationScope
      this.guiObservationScope = 0
      if (scope > 0 && !testNapi.gameGuiStopSession(scope)) {
        throw new Error('Native GUI observation retirement rejected')
      }
    })
    const touchStep: GameSessionCleanupStep={name:'touch-maintenance-stop',completed:false,reason:'Pending'}
    this.cleanup.push(touchStep)
    const touchOrigin: EntryTouchInputMaintenanceLease | undefined=this.touchMaintenance
    this.touchMaintenance=undefined
    this.touchStopStep=touchStep; this.touchStopAttempts=1
    // 计时器只约束重试，不拥有实际停源权；clock失败仍必须撤原scope/16ms/gyro。
    this.touchStopDeadline=0
    try { this.touchStopDeadline=systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE)+TOUCH_STOP_BUDGET_MS }
    catch (_) { /* 保0作ClockUnavailable，下面仍执行原停止；同步清完可Completed。 */ }
    try {
      if (touchOrigin===undefined) { touchStep.completed=true; touchStep.reason='' }
      else {
        const receipt: EntryTouchInputMaintenanceStopReceipt | undefined=stopEntryTouchInputMaintenance(touchOrigin)
        this.touchStopReceipt=receipt
        if (receipt!==undefined && receipt.complete()) { touchStep.completed=true; touchStep.reason='' }
        else if (receipt===undefined) touchStep.reason='TouchSourceStopScopeUnavailable'
      }
    } catch (error) {
      touchStep.reason='TouchSourceStopFailed'; this.noteFault('touch-maintenance-stop',error)
    }
    // OS attach/detach是异步资源事实。先围栏callback，再沿原runtime/原step捕获实际
    // Completed/Failed/TimedOut；不能因同步stop返回就把未结束的Promise记为Clean。
    const textStep: GameSessionCleanupStep = { name: 'text-input-stop', completed: false, reason: 'Pending' }
    this.cleanup.push(textStep)
    const textRuntime: EntryTextInputRuntime = this.textInputRuntime
    const textOutcome = (snapshot: EntryTextInputRuntimeSnapshot): void => {
      textStep.completed = snapshot.stopOutcome === 'Completed'
      textStep.reason = textStep.completed ? '' : snapshot.stopOutcome === 'Pending' ? 'Pending' :
        snapshot.failure.length>0 ? snapshot.failure : snapshot.stopOutcome
      // 同步stop回执可能早于其它清理步骤登记；初次完整结果由stop末尾统一记录。
      if (this.state === 'Ended') this.logOutcome(reason)
      if (snapshot.stopOutcome === 'Completed' || snapshot.stopOutcome === 'Failed' ||
          (snapshot.stopOutcome === 'TimedOut' && snapshot.platformDetachResolved && snapshot.localLeaseClosed)) {
        textRuntime.removeStopOutcomeListener(textOutcome)
      }
    }
    try {
      textRuntime.addStopOutcomeListener(textOutcome)
      textOutcome(textRuntime.stop(reason))
    } catch (error) {
      textStep.reason = error instanceof Error ? error.message : 'Text input stop failed'
      this.noteFault('text-input-stop', error)
    }
    this.cleanupStep('source-release', (): void => { getInputSourceRegistry().releaseAllEnds(reason) })
    this.cleanupStep('native-cancel', (): void => { testNapi.cancelAllInput(4) })
    // Runtime.stop只封住新输入并尝试退休，void并不证明原token/子流释放已确认。
    // Native cancel也只有调用回执，不能据此虚构reset epoch或把未知清理写成Clean。
    // 会话围栏同步完成；未确认墓碑保留为Pending，由进程退出事实承担最终资源收口。
    const mappedStep: GameSessionCleanupStep = { name: 'mapped-stop', completed: false, reason: 'Pending' }
    this.cleanup.push(mappedStep)
    try {
      this.inputRuntime.stop()
      if (this.gamepad.reconcileConnectionCleanup()) {
        mappedStep.completed = true
        mappedStep.reason = ''
      }
    } catch (error) {
      mappedStep.reason = (error as Error).message
      this.noteFault('mapped-stop', error)
    }
    if (this.connectionSubscribed) this.cleanupStep('device-connection-unsubscribe', (): void => {
      getInputDeviceMonitor().removeConnectionListener(this.connectionListener)
    })
    this.connectionSubscribed = false
    this.cleanupStep('configuration-stop', (): void => { this.configuration.stop() })
    this.cleanupStep('source-unregister', (): void => { getInputSourceRegistry().unregister(this.inputRuntime) })
    this.cleanupStep('native-gamepad-focus', (): void => { testNapi.desktopGamepadFocus(false) })
    if (this.windowId > 0) {
      this.cleanupStep('cursor-unlock', (): void => { testNapi.setCursorLocked(this.windowId, false) })
      this.cleanupStep('window-filter', (): void => { testNapi.uninstallWindowInputFilters(this.windowId) })
    }
    if (this.grabSubscribed) this.cleanupStep('grab-unsubscribe', (): void => { testNapi.onGrabChange() })
    this.grabSubscribed = false
    this.cleanupStep('pointer-restore', (): void => { getPointerVisibility().restore() })
    // Window恢复为平台异步事务，回执先保持Pending；不能把未完成的Promise记为Clean。
    const windowStep: GameSessionCleanupStep = { name: 'window-restore', completed: false, reason: 'Pending' }
    this.cleanup.push(windowStep)
    this.restoreWindow(this.coordinator).then((): void => {
      windowStep.completed = true
      windowStep.reason = ''
      this.logOutcome(reason)
    }).catch((error: Error): void => {
      windowStep.reason = error.message
      this.noteFault('window-restore', error)
      this.logOutcome(reason)
    })
    this.state = 'Ended'
    this.scheduleTouchStopCleanup(reason)
    this.logOutcome(reason)
    return this.cleanupSnapshot()
  }

  /**
   * 运行退出检测及用户请求共用单次事务。先尝试原context的前台归还，在成功、失败或
   * 等待期限结束后只尝试一次Native ACK；不把输入Ended当作OS资源/进程全部回收。
   */
  async requestExit(): Promise<void> {
    if (this.exitStarted) return
    this.exitStarted = true
    this.stop('session-stop')
    if (AppStorage.get<boolean>('desktopGameProcess') === true) {
      try {
        if (this.context === undefined) throw new Error('Game context unavailable')
        const parameters: Record<string, number> = { 'gameExitActivityId': this.activityId }
        const want: Want = { bundleName: 'com.amcl.launcher', abilityName: 'EntryAbility', parameters: parameters }
        await this.requestLauncherHandoff(this.context, want)
      } catch (error) { this.noteFault('return-to-launcher', error) }
      finally { try { testNapi.mcForceExit() } catch (error) { this.noteFault('exit-ack', error) } }
      return
    }
    try { testNapi.mcForceExit() } catch (error) { this.noteFault('shared-exit', error) }
    try { appRecovery.restartApp() } catch (error) { this.noteFault('shared-restart', error) }
  }

  /**
   * 只给本次退出的原平台Promise加有限等待。OS请求仍按原调用执行，迟到完成只消费
   * 原Promise的结果，不再触发ACK或改写超时。计时器故障按失败收口，不能跳过退出；
   * clearTimeout失败时已settled的闭包仍无权二次完成。正常成功/拒绝立即撤掉本地timer。
   */
  private requestLauncherHandoff(context: common.UIAbilityContext, want: Want): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let settled: boolean = false
      let timer: number = -1
      const finish = (failure?: Error): void => {
        if (settled) return
        settled = true
        if (timer >= 0) {
          try { clearTimeout(timer) } catch (error) { this.noteFault('exit-handoff-timer-clear', error) }
          timer = -1
        }
        if (failure !== undefined) reject(failure)
        else resolve()
      }
      try {
        // 先发出原前台请求并接住晚到拒绝，再建立本次等待预算；调度失败也不会留下
        // unhandled rejection或要求再次调用startAbility。一次性timer不复活输入维护。
        context.startAbility(want).then((): void => { finish() }).catch((error: Error): void => { finish(error) })
        if (!settled) timer = setTimeout((): void => {
          finish(new Error('ReturnToLauncherDeadlineExceeded'))
        }, EXIT_HANDOFF_BUDGET_MS) as number
      } catch (error) { finish(error as Error) }
    })
  }

  private active(): boolean {
    return this.requestedActive && this.lease !== undefined && !this.lease.retired &&
      !this.ended() && this.inputRuntime.isLifecycleActive()
  }

  private ended(): boolean { return this.state === 'Stopping' || this.state === 'Ended' }

  /** 只返回独立的政策决议快照；Applied表示来源路由已切换，不表示consumer或游戏读取。 */
  nativeGamepadRoute(): NativeGamepadRouteDecision | undefined {
    if (!this.gamepadRouteFactsFrozen) return undefined
    const applied: GamepadOutputRoute = this.gamepad.isMappedOutputEnabled()
      ? GamepadOutputRoute.Mapped : GamepadOutputRoute.Native
    return resolveNativeGamepadRoute(this.gamepadNativeRequested, this.gamepadCaptureReady,
      this.inputPlanWire, applied)
  }

  /**
   * 前端只能读取自己原lease仍属于本局的路由值副本。旧页面/复制lease/另一会话传来的
   * 同编号对象均无读取资格；不取得current lease补旧调用，也不推进采集或来源切换。
   * 无前端时原250ms必要维护继续，撤销此观察资格不会撤销用户请求或停止生产路由。
   */
  nativeGamepadRouteForFrontend(lease: GameFrontendLease | undefined): NativeGamepadRouteDecision | undefined {
    if (!this.accepts(lease)) return undefined
    const decision: NativeGamepadRouteDecision | undefined = this.nativeGamepadRoute()
    // 生产读取为纯值；仍守住可能同步回入的依赖边缘，旧读回不能取得后来前端的结果。
    return this.accepts(lease) ? decision : undefined
  }

  /** 按真实来源开关收回应用回执；release拒绝保持Pending，必要维护可重试同一政策。 */
  private reconcileGamepadRoute(): void {
    if (!this.gamepadRouteFactsFrozen || this.ended()) return
    const before: GamepadOutputRoute = this.gamepad.isMappedOutputEnabled()
      ? GamepadOutputRoute.Mapped : GamepadOutputRoute.Native
    const target: NativeGamepadRouteDecision = resolveNativeGamepadRoute(this.gamepadNativeRequested,
      this.gamepadCaptureReady, this.inputPlanWire, before)
    this.gamepad.setMappedOutputEnabled(target.mappedOutputEnabled)
    const applied: NativeGamepadRouteDecision | undefined = this.nativeGamepadRoute()
    this.gamepadRouteDecision = applied
    if (applied !== undefined) {
      const description: string = JSON.stringify(applied)
      if (description !== this.gamepadRouteDescription) {
        this.gamepadRouteDescription = description
        this.runStep('gamepad-route-log', (): void => {
          this.logger().info('InputSession', 'input_gamepad_route ' + description +
            ' consumer_ready=unconfirmed game_usage=unconfirmed', LOG_DOMAIN_LAUNCH)
        })
      }
    }
    if (applied !== undefined && applied.applied !== before) this.refreshEligibility()
  }

  /** 每次变化先同步生产资格，再投影 UI；observer 抛错只丢观察，不改变后续维护。 */
  private refreshEligibility(): void {
    const active: boolean = this.active()
    this.inputRuntime.setState(active, this.grabbed)
    this.runStep('cursor-lock', (): void => {
      if (this.windowId > 0 && ProductInputProfile.current().supportsCursorLock) {
        testNapi.setCursorLocked(this.windowId, this.launched && active && this.grabbed && getInputDeviceMonitor().hasMouse())
      }
    })
    this.runStep('pointer-state', (): void => {
      getPointerVisibility().sync(active && this.grabbed, getInputDeviceMonitor().hasMouse())
    })
    this.runStep('desktop-gamepad-focus', (): void => {
      if (ProductInputProfile.selection().desktopWindow) {
        // 原映射持有未能释放时applied仍Mapped，不同时开启游戏原生出口焦点。
        testNapi.desktopGamepadFocus(active && this.gamepadRouteDecision?.applied === GamepadOutputRoute.Native)
      }
    })
    const frontend: GameSessionFrontend | undefined = this.frontend
    if (frontend !== undefined) this.runStep('frontend-state', (): void => { frontend.onState(this.grabbed, active) })
  }

  private applyGrab(grabbed: boolean): void {
    if (grabbed !== this.grabbed) {
      this.grabbed = grabbed
      this.runStep('grab-source-release', (): void => {
        getInputSourceRegistry().releaseEndsOfSource(AmclInputSource.Gamepad, 'grab-flip')
      })
    }
    this.refreshEligibility()
  }

  /** 复用250ms时钟，每步失败隔离；无页面也继续配置、文本、复位与期限维护。 */
  private startMaintenance(): void {
    if (this.heartbeat >= 0 || this.maintenanceExecuting || this.ended()) return
    const tick = (): void => {
      // 排队旧生产tick不能擦掉stop刚复用的heartbeat清理句柄。
      if (this.ended()) return
      this.heartbeat = -1
      this.maintenanceExecuting = true
      this.runStep('grab-state', (): void => { this.applyGrab(testNapi.isGrabbed()) })
      this.runStep('configuration', (): void => { this.configuration.reconcile() })
      this.runStep('gamepad-route', (): void => { this.reconcileGamepadRoute() })
      this.runStep('mapped-runtime', (): void => { this.inputRuntime.reconcile() })
      this.runStep('text-session', (): void => { this.textInputRuntime.maintain() })
      this.runStep('reset-domains', (): void => { reconcileEntryInputSession() })
      this.runStep('touch-maintenance', (): void => {
        if (this.touchMaintenance !== undefined && !reconcileEntryTouchInputMaintenance(this.touchMaintenance)) {
          throw new Error('Touch maintenance scope unavailable')
        }
        if (this.touchMaintenance!==undefined) reconcileEntryTouchInputMaintenanceCleanup(this.touchMaintenance)
      })
      this.runStep('cursor-watchdog', (): void => {
        if (testNapi.cursorLockWatchdogTick() && this.windowId > 0) {
          testNapi.setCursorLocked(this.windowId, false)
          this.refreshEligibility()
        }
      })
      this.runStep('pointer-maintenance', (): void => { getPointerVisibility().tick() })
      this.runStep('input-invariant', (): void => { testNapi.inputInvariantTick() })
      const frontend: GameSessionFrontend | undefined = this.frontend
      if (frontend !== undefined) this.runStep('frontend-maintenance', (): void => { frontend.onMaintenance() })
      this.maintenanceExecuting = false
      if (!this.ended() && this.heartbeat < 0) this.heartbeat = setTimeout(tick, 250) as number
    }
    this.heartbeat = setTimeout(tick, 250) as number
  }

  /**
   * 只复用已停产的heartbeat槽重试原退休回执，最多5次/2s；不恢复producer、路由或UI。
   * 不读后来scope；超限留原墓碑并报告具名CleanupFailed，进程结束承担最终隔离。
   */
  private scheduleTouchStopCleanup(reason: string): void {
    const original: EntryTouchInputMaintenanceStopReceipt | undefined=this.touchStopReceipt
    const step: GameSessionCleanupStep | undefined=this.touchStopStep
    if (original===undefined || step===undefined || step.completed) return
    if (!original.waiting()) { step.reason='TouchSourceCleanupFailed'; return }
    if (this.touchStopDeadline===0) { step.reason='TouchSourceCleanupClockUnavailable'; return }
    if (this.touchStopAttempts>=TOUCH_STOP_RETRY_BUDGET) { step.reason='TouchSourceCleanupAttemptBudgetExceeded'; return }
    let now: number=0
    try { now=systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE) }
    catch (_) { step.reason='TouchSourceCleanupClockUnavailable'; return }
    if (now>=this.touchStopDeadline) { step.reason='TouchSourceCleanupDeadlineExceeded'; return }
    try { this.heartbeat=setTimeout((): void => {
      if (this.touchStopReceipt!==original || this.touchStopStep!==step || !this.ended()) return
      this.heartbeat=-1
      let at: number=0
      try { at=systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE) }
      catch (_) { step.reason='TouchSourceCleanupClockUnavailable'; this.logOutcome(reason); return }
      if (at>=this.touchStopDeadline) { step.reason='TouchSourceCleanupDeadlineExceeded'; this.logOutcome(reason); return }
      this.touchStopAttempts++
      if (original.reconcile()) { step.completed=true; step.reason=''; this.touchStopReceipt=undefined }
      else this.scheduleTouchStopCleanup(reason)
      this.logOutcome(reason)
    },Math.min(250,this.touchStopDeadline-now)) as number }
    catch (_) {
      // 调度失败仍保原receipt和Pending资源；已执行的首次停源及其它域清理不受影响。
      this.heartbeat=-1
      step.reason='TouchSourceCleanupTimerUnavailable'
    }
  }

  /** 游戏退出轮询独立于日志显示及页面寿命。日志仅为可关闭的观察回调。 */
  private startRuntimePoll(): void {
    if (this.runtimePoll >= 0 || this.runtimePollExecuting || this.ended()) return
    const poll = (): void => {
      this.runtimePoll = -1
      if (this.ended()) return
      this.runtimePollExecuting = true
      // Native退出事实先于可关闭日志观察；JNI观察已由Native异步服务承担，UI不进入JVM。
      // requestExit的同步前缀退休整个会话后，本轮不再调用旧前端，也不复活时钟。
      this.runStep('game-running', (): void => {
        if (!testNapi.mcIsRunning()) this.requestExit().catch((error: Error): void => { this.noteFault('exit', error) })
      })
      const frontend: GameSessionFrontend | undefined = this.frontend
      if (!this.ended() && frontend !== undefined) this.runStep('frontend-log', (): void => { frontend.onLog() })
      this.runtimePollExecuting = false
      if (!this.ended() && this.runtimePoll < 0) this.runtimePoll = setTimeout(poll, 1000) as number
    }
    this.runtimePoll = setTimeout(poll, 1000) as number
  }

  private cancelScheduledStart(): void {
    if (this.startTimer >= 0) clearTimeout(this.startTimer)
    this.startTimer = -1
  }

  /** 装配/退休在同一事件线程交接所有原等待者，清deadline后完成，不产生拒绝型无人处理Promise。 */
  private settlePreparation(ready: boolean): void {
    const waiters: InputPreparationWaiter[] = this.preparationWaiters
    this.preparationWaiters = []
    for (const waiter of waiters) {
      if (waiter.timer >= 0) clearTimeout(waiter.timer)
      waiter.finish(ready)
    }
  }

  /** stop期间只尝试一次；失败回执由进程终止兜底，不在后台无限重试外部副作用。 */
  private cleanupStep(name: string, action: () => void): void {
    let reason: string = ''
    let completed: boolean = true
    try { action() } catch (error) { completed = false; reason = (error as Error).message; this.noteFault(name, error) }
    this.cleanup.push({ name: name, completed: completed, reason: reason })
  }

  /** Pending是异步资源尚未结束，既不伪造Clean也不提前记为失败；日志失败仍继续退出。 */
  private logOutcome(reason: string): void {
    try {
      const failed: boolean = this.cleanup.some((step: GameSessionCleanupStep): boolean => !step.completed && step.reason !== 'Pending')
      const pending: boolean = this.cleanup.some((step: GameSessionCleanupStep): boolean => step.reason === 'Pending')
      this.logger().info('InputSession', 'input_session_end activity=' + this.activityId + ' reason=' + reason +
        ' outcome=' + (failed ? 'CleanupFailed' : pending ? 'Pending' : 'Clean') +
        ' steps=' + JSON.stringify(this.cleanup), LOG_DOMAIN_LAUNCH)
    } catch (error) { this.noteFault('outcome-log', error) }
  }

  private runStep(name: string, action: () => void): void {
    if (this.ended()) return
    try { action() } catch (error) { this.noteFault(name, error) }
  }

  private logger(): ActivityLogger { return new ActivityLogger(this.activityId) }

  /** 诊断按步骤节流且绝不向定时器/生命周期逃逸。 */
  private noteFault(name: string, error: Object): void {
    try {
      const count: number = (this.failureCounts.get(name) ?? 0) + 1
      this.failureCounts.set(name, count)
      if ((count & (count - 1)) === 0) AppLogger.warn('InputSession',
        'session step failed; continuing step=' + name + ' count=' + count, error, LOG_DOMAIN_LAUNCH)
    } catch (_) { /* 日志失败不能阻止清理/维护。 */ }
  }
}

let processSession: GameSessionHost | undefined = undefined

/** 同局页面复用宿主；已结束宿主保留墓碑，不凭 UI 重建恢复可创建 JVM 的资格。 */
export function getGameSessionHost(): GameSessionHost {
  if (processSession === undefined) processSession = new GameSessionHost()
  return processSession
}

/** Ability真实销毁结束本局；不为清理创建原本不存在的会话，也不触碰进程 JVM marker。 */
export function stopGameSession(reason: string): boolean {
  if (processSession === undefined) return false
  processSession.stop(reason)
  return true
}

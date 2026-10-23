import { InputDeviceConnectionLease, GamepadAxisSnapshot } from './InputDeviceConnectionLease'
/**
 * 映射手柄来源运行体：管理本来源的配置应用、单调积分时钟及准入生命周期。
 * 本类不认识 ArkUI/NAPI 或图形 profile；时钟、文本/复位端口由稳定游戏会话宿主注入。
 * 原生手柄由游戏查询，不经过这里的轴积分；这里只有启动器的键鼠映射端。
 */
import { GamepadManager } from './GamepadManager'
import { LayoutProfile } from './ControlLayout'
import { LayoutStore } from './LayoutStore'
import { AmclInputSource, InputEnd } from './InputSourceRegistry'
import { InputConfigurationListener } from './InputConfiguration'

/** 原Runtime实例/activation与8轴原值；外部构造同字段也不在issued集合中。 */
export class GameInputAxisFact {
  readonly connection: InputDeviceConnectionLease
  readonly axes: GamepadAxisSnapshot
  readonly activation: number
  constructor(connection: InputDeviceConnectionLease, axes: GamepadAxisSnapshot, activation: number) {
    this.connection = connection; this.axes = axes; this.activation = activation
  }
}

export class GameInputRuntime implements InputEnd {
  readonly inputSource: AmclInputSource = AmclInputSource.Gamepad
  readonly endName: string = 'GameInputRuntime'
  private gamepad: GamepadManager
  private nowMs: () => number
  private onReset: () => void
  private beforeSample: () => void
  private onSuspended: () => void
  private onForeground: () => void
  private store: LayoutStore | undefined = undefined
  private active: boolean = false
  /** Ability先于页面回调退后台时锁住准入，不能靠仍为true的旧UI字段重新激活。 */
  private lifecycleSuspended: boolean = false
  /** Ability前后台独立于页面显隐/组件焦点，不能用其中一条边沿覆盖另一条事实。 */
  private abilitySuspended: boolean = false
  private grabbed: boolean = false
  private timer: number = -1
  private lastTickMs: number = -1
  private pendingProfile: LayoutProfile | undefined = undefined
  private admissionEpoch: number = 1
  private admissionExhausted: boolean = false
  private issuedAxisFacts: Set<GameInputAxisFact> = new Set<GameInputAxisFact>()

  private configListener: InputConfigurationListener =
    (profile: LayoutProfile, _revision: number): boolean => {
      // 配置切换先退休旧映射；被 native 拒绝的 RELEASE 仍由 manager 保留、重试。
      this.pendingProfile = profile
      this.applyConfiguration()
      this.schedule()
      return this.pendingProfile === undefined
    }

  constructor(gamepad: GamepadManager, nowMs: () => number, onReset: () => void,
    beforeSample: () => void = (): void => {}, onSuspended: () => void = (): void => {},
    onForeground: () => void = (): void => {}) {
    this.gamepad = gamepad
    this.nowMs = nowMs
    this.onReset = onReset
    this.beforeSample = beforeSample
    this.onSuspended = onSuspended
    this.onForeground = onForeground
  }

  /** 布局存储就绪后接入；订阅立即投递最新快照，消除“仅初始化读取一次”的失步。 */
  start(store: LayoutStore): void {
    if (this.store === store) return
    // 初始配置可能await之后才就绪；它没有撤销期间已发生background的权限。
    const suspended: boolean = this.lifecycleSuspended
    this.stop()
    this.lifecycleSuspended = suspended
    this.store = store
    store.addInputConfigurationListener(this.configListener, 'mapped-gamepad')
  }

  /** 会话停止时移除本来源订阅和计时器；单独前端detach不会调用本方法。 */
  stop(): void {
    this.retireAdmission()
    this.stopClock()
    if (this.store !== undefined) this.store.removeInputConfigurationListener(this.configListener)
    this.store = undefined
    this.pendingProfile = undefined
    this.active = false
    this.lifecycleSuspended = true
    this.gamepad.releaseAllInputs('runtime-stop')
  }

  /** 页面失活或 grab 翻转都截断轴积分，恢复后等待新轴事实，不重播后台时间。 */
  setState(active: boolean, grabbed: boolean): void {
    active = active && this.isLifecycleActive()
    if (active === this.active && grabbed === this.grabbed) return
    this.retireAdmission()
    this.stopClock()
    this.gamepad.releaseAllInputs(active ? 'runtime-grab-change' : 'runtime-inactive')
    this.active = active
    this.grabbed = grabbed
    this.applyConfiguration()
  }

  /** 只恢复页面显隐墓碑；即使晚到的onFocus调用本方法，也不能覆盖Ability后台事实。 */
  resumeAfterLifecycle(): void { this.lifecycleSuspended = false }

  /** 页面异步window-enter续体也必须检查墓碑，不能用晚到的ready覆盖后台事实。 */
  isLifecycleActive(): boolean { return !this.lifecycleSuspended && !this.abilitySuspended }

  /** 真实Ability前台只清后台事实，并请页面重新合取原有visible/focus/window状态。 */
  onAbilityForeground(): void {
    if (!this.abilitySuspended) return
    this.abilitySuspended = false
    this.onForeground()
  }

  /** 接收轴快照前先积分旧状态；采样频率不能决定转头速度。 */
  handleAxis(deviceId: number, getAxis: (axis: number) => number | undefined): void {
    this.beforeSample()
    if (!this.active) return
    this.advance()
    this.gamepad.handleAxisForDevice(deviceId, getAxis)
    this.schedule()
  }


  /** 真实第一入口先复制8轴并发原fact。没有Native/维护副作用；有界128个未提交fact防遗留队列。 */
  captureAxisForConnection(connection: InputDeviceConnectionLease,
    getAxis: (axis: number) => number | undefined): GameInputAxisFact | undefined {
    if (this.admissionExhausted || !this.active || !this.gamepad.acceptsConnection(connection) || this.issuedAxisFacts.size >= 128) return undefined
    const activation = this.admissionEpoch, axes = new GamepadAxisSnapshot(getAxis)
    if (activation !== this.admissionEpoch || !this.gamepad.acceptsConnection(connection)) return undefined
    const fact = new GameInputAxisFact(connection, axes, activation)
    this.issuedAxisFacts.add(fact); return fact
  }

  /** 只接收本实例实际发出的原fact，一次领取；beforeSample/advance回入必须再次核原activation/lease。 */
  handleAxisFact(fact: GameInputAxisFact): void {
    if (!this.issuedAxisFacts.delete(fact) || !this.acceptsAxisFact(fact)) return
    this.beforeSample()
    if (!this.acceptsAxisFact(fact)) return
    this.advance()
    if (!this.acceptsAxisFact(fact)) return
    this.gamepad.handleAxisForConnection(fact.connection, fact.axes)
    this.schedule()
  }

  /** 原lease退休不lookup新sameid；运动清零与原token/子流压力墓碑由同Manager维护。 */
  releaseConnection(connection: InputDeviceConnectionLease, reason: string): void {
    this.gamepad.releaseConnection(connection, reason)
    this.gamepad.reconcileConnectionCleanup()
    this.schedule()
  }

  /** 无法把copy/旧Runtime/退源fact借成新激活；消费者阶段与Native generation仍另外报告。 */
  private acceptsAxisFact(fact: GameInputAxisFact): boolean {
    return !this.admissionExhausted && this.active && this.isLifecycleActive() &&
      fact.activation === this.admissionEpoch && this.gamepad.acceptsConnection(fact.connection)
  }

  /** 本实例应用activation不回绕；饱和后永久拒新输入事实，原cleanup仍合法。 */
  private retireAdmission(): void {
    this.issuedAxisFacts.clear()
    if (this.admissionEpoch >= Number.MAX_SAFE_INTEGER) { this.admissionExhausted = true; return }
    this.admissionEpoch++
  }

  /** 外部 heartbeat/新事件也是重试配置的机会，不要求持续开一个空转高频 timer。 */
  reconcile(): void {
    this.gamepad.reconcileConnectionCleanup()
    this.gamepad.reconcileLookExecution()
    this.store?.reconcileInputConfiguration()
    this.applyConfiguration()
    this.schedule()
  }

  releaseAllInputs(reason: string): void {
    this.retireAdmission()
    // 与端注册表契约一致：自释放保留被拒绝的RELEASE，native兜底之后再丢缓存。
    this.stopClock()
    this.gamepad.releaseAllInputs(reason)
    if (reason === 'page-hide' || reason === 'page-dispose' ||
        reason.endsWith('-background') || reason.endsWith('-destroy')) {
      this.active = false
      if (reason.endsWith('-background')) this.abilitySuspended = true
      else this.lifecycleSuspended = true
      // 立即同步页面准入与capture期望；不能等不保证到达的ArkUI onBlur。
      this.onSuspended()
    }
  }

  dropHeldStateAfterNativeReset(reason: string): void {
    this.retireAdmission()
    // Native已清权威持有；轴缓存和文本宿主号必须在下一次输出前同时对账。
    this.stopClock()
    this.gamepad.dropHeldStateAfterNativeReset(reason)
    this.onReset()
    this.applyConfiguration()
  }

  private applyConfiguration(): void {
    const profile: LayoutProfile | undefined = this.pendingProfile
    if (profile !== undefined && this.gamepad.updateConfig(profile.gamepad)) this.pendingProfile = undefined
  }

  private stopClock(): void {
    if (this.timer >= 0) clearTimeout(this.timer)
    this.timer = -1
    this.lastTickMs = -1
  }

  private schedule(): void {
    if (!this.active || this.timer >= 0) return
    if (this.pendingProfile === undefined && (!this.grabbed || !this.gamepad.hasLookMotion())) return
    if (this.lastTickMs < 0) this.lastTickMs = this.readClock()
    const activation = this.admissionEpoch
    this.timer = setTimeout((): void => {
      // 已排队旧timer也不能清掉后来激活期的新timer字段。
      if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return
      this.timer = -1
      // 250ms会话heartbeat不足以隔离高频look；每次实际运动输出前先确认reset epoch。
      this.beforeSample()
      if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return
      this.gamepad.reconcileConnectionCleanup()
      // 精确token/子流清理也会调用Native，并可同步切换activation及安装新轴事实。
      // 原timer在每个可回入副作用之后仍须核原代次，不能借新look状态继续advance或配置。
      if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return
      this.advance()
      if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return
      this.applyConfiguration()
      if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return
      this.schedule()
    }, 16) as number
  }

  private advance(): void {
    if (this.gamepad.usesSharedLookExecution()) {
      // Native owner在样本/动作/维护边界采自身MONOTONIC，不能把ACTIVE uptime的ns
      // 当作同一时钟再积分一次。后台/未抓取不推进，新动作由原Native提交批次封prefix。
      if (this.active && this.grabbed) this.gamepad.advanceMappedLook(0, 0)
      return
    }
    const now: number = this.readClock()
    const previous: number = this.lastTickMs
    this.lastTickMs = now
    if (!this.active || !this.grabbed || previous < 0 || !Number.isFinite(now) || now < previous) return
    // 事件线程卡顿只计算最多50ms，禁止恢复时补发数秒相机旋转。
    // 与dt使用同一次单调时钟采样，跨NAPI后仍保留毫秒→纳秒的明确单位边界。
    this.gamepad.advanceMappedLook(Math.min(50, now - previous) / 1000, Math.trunc(now * 1000000))
  }

  /** 平台时钟异常不逃出timer回调；下次有效采样重新建立基线，不使用墙钟兜底。 */
  private readClock(): number {
    try {
      const value: number = this.nowMs()
      return Number.isFinite(value) && value >= 0 ? value : -1
    } catch (_) { return -1 }
  }
}

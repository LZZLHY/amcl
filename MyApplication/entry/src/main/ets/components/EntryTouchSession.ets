/**
 * 触控来源与前端的受限接线：来源自有16ms维护/gyro时钟，视觉订阅只接收只读投影。
 * 来源归原游戏会话scope及本触控lease组织；关闭视觉订阅不停止生产维护或传感器。
 * 输入解释仍在Native；本对象不持有按键、不修改游戏配置，停止仅撤自身来源/前端。
 */
import testNapi, { TouchSchemaOptions } from 'libentry.so'
import fs from '@ohos.file.fs'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { EntryTouchGyroscope } from './EntryTouchGyroscope'
import { LayoutProfile, LayoutStore, getLayoutStore, InputConfigurationListener, InputConfigurationDefinitionListener,
  InputConfigurationProgress, TouchConfiguration, normalizeTouchPreferences, TouchBindingSnapshot,
  parseTouchActionBindings, TOUCH_ACTION_NAMES, GameGuiState, parseGameGuiState, estimateGameGuiFromOptions, usesLegacyGuiScale } from 'gamecontrol'
import { TouchGuideFeedback, parseTouchGuideFeedback } from 'gamecontrol'
import { RuntimeTouchContext } from 'gamecontrol'
import { EntryTouchInputMaintenanceLease, captureEntryTouchInputMaintenanceScope,
  registerEntryTouchInputMaintenanceSource, unregisterEntryTouchInputMaintenanceSource,
  isEntryTouchInputMaintenanceCurrent, reconcileEntryTouchInputMaintenance } from './EntryTouchInputMaintenance'
// 旧前端调用/测试仍取得同一个Native scope实现；共同宿主直接依赖纯维护模块，不经此触控前端。
export { EntryTouchInputMaintenanceLease, startEntryTouchInputMaintenance,
  reconcileEntryTouchInputMaintenance, stopEntryTouchInputMaintenance } from './EntryTouchInputMaintenance'

/** 全部坐标为surface px，页面在绘制入口统一除density；不把本对象当作新的输入状态机。 */
export class EntryTouchVisual {
  menuX: number = 0
  menuY: number = 0
  menuVisible: boolean = false
  centerX: number = 0
  centerY: number = 0
  joystickX: number = 0
  joystickY: number = 0
  locked: boolean = false
  armed: boolean = false
  progress: number = 0
  joystickActive: boolean = false
  aiming: boolean = false
  schemaGeneration: number = 0
  joystickIndex: number = -1
  guide: TouchGuideFeedback=new TouchGuideFeedback()
}

/** 只读操作收据来自原会话的实际计数；读取不取得来源资格，也不推进任何时钟。 */
export class EntryTouchObservationSnapshot {
  sourceCurrent: boolean = false
  timerActive: boolean = false
  visualSubscribed: boolean = false
  geometrySubscribed: boolean = false
  guiSubscribed: boolean = false
  guiReads: number = 0
  geometryDeliveries: number = 0
  visualDeliveries: number = 0
  gyroStatus: string = ''
}

export class EntryTouchSession {
  private directory: string = ''
  private bindings: TouchBindingSnapshot = new TouchBindingSnapshot()
  private follow: boolean = true
  /** options原文仅在既有刷新边缘读取；候选构值用缓存和本次follow值，不读盘/采用政策。 */
  private bindingOptionsText: string = ''
  private bindingActivation: string = ''
  private timer: number = -1
  private receive: ((state: EntryTouchVisual) => void) | undefined = undefined
  private lastVisual: string = ''
  /** 菜单面板位置是实际绘制/命中几何；它与可退订的光标、高亮、教学投影分别送达。 */
  private geometryReceive: ((x: number, y: number) => void) | undefined = undefined
  private lastGeometry: string = ''
  private guiReads: number = 0
  private geometryDeliveries: number = 0
  private visualDeliveries: number = 0
  private warned: boolean = false
  private heartbeatWarned: boolean = false
  private active: boolean = false
  private grabbed: boolean = false
  private gyroOptions: TouchConfiguration = new TouchConfiguration()
  private rotation: number = 0
  private touchAdmitted: boolean = false
  private heartbeat: (() => void) | undefined = undefined
  private gyro: EntryTouchGyroscope = new EntryTouchGyroscope()
  /** gyro独立消费原确认定义；复用Store投递回执，不借touch-controls/几何Applied代证。 */
  private gyroStore: LayoutStore | undefined = undefined
  private gyroListener: InputConfigurationListener | undefined = undefined
  private gyroDefinitionListener: InputConfigurationDefinitionListener | undefined = undefined
  private gyroConfigurationEpoch: number = 0
  private gyroDefinitionRevision: number = 0
  private gyroOperation: number = 0
  private gyroProgress: InputConfigurationProgress = new InputConfigurationProgress()
  private guiReceive: ((state: GameGuiState) => void) | undefined = undefined
  private guiWidth: number=0
  private guiHeight: number=0
  private guiVersion: string=''
  private guideActive: boolean=false
  private nextGuiRead: number=0
  private lastGui: string=''
  /** 与触控scope分别捕获原GUI会话；不存在时保持降级，不为视觉创建/复活会话。 */
  private readonly guiOriginScope: number = typeof testNapi.gameGuiCaptureSession === 'function' ? testNapi.gameGuiCaptureSession() : 0
  private guiSource: number = 0
  /** 仅本前端接受的原Native票；换source不能从新缓存等候/认领旧票回执。 */
  private guiRestoreTicket: number = 0
  /** 观察者暂停期间的本前端撤票回执；重订阅只交它，不从新source猜旧票完成。 */
  private guiWithdrawnTicket: number = 0
  private fallbackGuiRevision: number=1000000000
  private fallbackGuiKey: string=''
  private fallbackOptionsStamp: string=''
  private fallbackOptions: string=''
  /** 前端创建时冻结原宿主。异步waitReady之后的start也只能向原scope申请，不能偷取新局。 */
  private readonly originLease: EntryTouchInputMaintenanceLease | undefined = captureEntryTouchInputMaintenanceScope()
  /** 只在显式startSources取得；setActive/迟到timer不能从global current偷取后来会话。 */
  private sourceLease: EntryTouchInputMaintenanceLease | undefined = undefined

  /** 几何来自实际XComponent，不读设备默认全屏；版本使用启动器解析的继承根版本。 */
  setGuiViewport(widthPx: number,heightPx: number,version: string): void {
    this.guiWidth=widthPx; this.guiHeight=heightPx; this.guiVersion=version
  }
  /** 当前投影context是旋转/密度/视口的唯一来源，不读取可能属于另一显示器的默认display。 */
  setRuntimeContext(context: RuntimeTouchContext): void {
    this.rotation = context.transform
    this.guiWidth = context.widthPx; this.guiHeight = context.heightPx
  }
  /** publication/modal关闭新触控加工时立即退休gyro基线；恢复只能从后续新样本开始积分。 */
  setTouchAdmission(admitted: boolean): void {
    if (this.touchAdmitted === admitted) return
    this.touchAdmitted = admitted
    if (!admitted) {
      this.waitForGyroAdmission('InputNotAdmitted')
      this.gyro.stop()
    }
  }
  /** 复用原有页面16ms心跳；视觉未变化也必须对账临时失败，避免丢掉单次dirty入口。 */
  setHeartbeat(heartbeat: () => void): void { this.heartbeat = heartbeat }
  /** 教学才需要菜单语义；关闭时普通GUI轮询继续，但不再扫描游戏控件。 */
  setGuideActive(active: boolean): void {
    if(this.guideActive===active) return
    this.guideActive=active; this.nextGuiRead=0
  }

  /** 页面发布游戏/菜单状态；native仍会在真正的grab事务中复核，不依赖UI声明放行。 */
  setGrabbed(grabbed: boolean): void {
    this.grabbed=grabbed
    if (!grabbed) {
      this.waitForGyroAdmission('InputNotAdmitted')
      this.gyro.stop()
    }
  }

  /**
   * 即时失权只同步原来源/原定义的报告缓存，不新增Native维护或把退休墓碑记为完成。
   * off定义已确认的是关闭事实，失去输入资格不撤回它；未确认的off仍保原Waiting。
   * 写缓存先于外部停止边缘，sensor/GUI回入后本续体不再写旧operation，避免覆盖新定义
   * 或新epoch的Applied/Retired；已退休/未登记来源也不能由迟到setter改回Waiting。
   */
  private waitForGyroAdmission(reason: string): void {
    const lease: EntryTouchInputMaintenanceLease | undefined = this.sourceLease
    if (this.gyroStore===undefined || lease===undefined || !isEntryTouchInputMaintenanceCurrent(lease) ||
      this.gyroDefinitionRevision<=0 || this.gyroOptions.gyroscopeMode==='off') return
    this.gyroProgress.stage='Waiting'; this.gyroProgress.reason=reason
  }

  /** 换实例先丢弃旧绑定；下一次schema发布之前刷新，不让旧目录数据跨实例流转。 */
  setDirectory(directory: string): void {
    if (this.directory === directory) return
    this.directory = directory
    this.fallbackOptions=''; this.fallbackOptionsStamp=''; this.fallbackGuiKey=''
    this.refreshBindings()
  }

  /** 进入游戏时重读options；缺文件为游戏首次启动，合法使用默认键。 */
  refreshBindings(): void {
    let text: string = ''
    if (this.directory.length > 0) {
      try { text = fs.readTextSync(this.directory + '/options.txt') }
      catch (_) { text = '' }
    }
    this.bindingOptionsText = text
    this.bindings = parseTouchActionBindings(text,this.follow)
    if (this.bindings.unsupported.length > 0) {
      hilog.warn(0x0000,'GameControls','Unrecognized touch action bindings: %{public}s',
        this.bindings.unsupported.join(','))
    }
  }
  /** 编辑器只读有效来源键，不暴露或重新解析整份options原文。 */
  actionKeys(): number[] { return this.bindings.keys.slice() }
  gyroscopeStatus(): string { return this.gyro.currentStatus() }

  /** 完整投影一次发布；动作下标和配置值均已由纯模型校验，native仍再次校验。 */
  schemaOptions(profile: LayoutProfile): TouchSchemaOptions {
    const options: TouchConfiguration = normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()
    // 只生成本候选值：失败候选不能改变运行gyro、follow或IO状态。新follow即使与
    // 旧applied不同也从同一缓存纯解析，实际采用仅在原UI/Native确认接点完成。
    const actions: number[] = parseTouchActionBindings(this.bindingOptionsText,options.followGameBindings).keys.slice()
    for (let i=0;i<TOUCH_ACTION_NAMES.length;i++) {
      const override: number | undefined = options.actionOverrides[TOUCH_ACTION_NAMES[i]]
      if (override !== undefined) actions[i] = override
    }
    // 退役字段仍能无损存档；运行协议固定关闭，旧布局不能重新开启隐藏功能。
    return {
      version: 1, touchpad: options.menuMode === 'touchpad', menuSensitivity: options.menuSensitivity,
      menuScroll: options.menuTwoFingerScroll, menuHoldMs: Math.round(options.menuHoldMs),
      floatingJoystick: options.joystickCenter === 'floating', sprint: options.joystickSprint,
      autoWalk: false, sprintThreshold: options.joystickSprintThreshold,
      hotbarSwap: options.hotbarSwapDoubleTap, hotbarDrop: options.hotbarDropHold,
      holdMs: Math.round(options.holdMs), gestureMode: 0, actions: actions
    }
  }

  /** 已确认候选的绑定投影；只由GameControls原等价Applied/真实confirm调用，不触gyro域。 */
  adoptConfirmedTouchBindings(profile: LayoutProfile, schema: TouchSchemaOptions,
    operation: string, candidate: string, token: string): void {
    if (candidate.length===0 || token.length===0 || !isEntryTouchInputMaintenanceCurrent(this.originLease)) return
    const options: TouchConfiguration = normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()
    this.follow = options.followGameBindings
    const binding: TouchBindingSnapshot = parseTouchActionBindings(this.bindingOptionsText,this.follow)
    binding.keys = schema.actions.slice()
    this.bindings = binding
    // operation/candidate/token随原完成接点传入，不能用后来desired或从current改绑。
    this.bindingActivation=JSON.stringify([profile.profileId,profile.profileRevision,operation,candidate,token])
  }

  /** 原Store定义观察先冻结本域operation，Native/sensor调用只在具名应用listener执行。 */
  private bindGyroConfiguration(store: LayoutStore, lease: EntryTouchInputMaintenanceLease): void {
    const epoch: number = this.gyroConfigurationEpoch
    this.gyroStore = store
    const definition: InputConfigurationDefinitionListener = (profile: LayoutProfile, revision: number): void => {
      if (this.gyroStore!==store || this.gyroConfigurationEpoch!==epoch || this.sourceLease!==lease) return
      if (revision<=this.gyroDefinitionRevision) return
      if (this.gyroOperation>=Number.MAX_SAFE_INTEGER) {
        this.gyroProgress.stage='Waiting'; this.gyroProgress.reason='IdentityExhausted'; return
      }
      this.gyroDefinitionRevision=revision; this.gyroOperation++
      this.gyroOptions=normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()
      const progress: InputConfigurationProgress = new InputConfigurationProgress()
      progress.operationId='gyro:'+epoch.toString()+':'+this.gyroOperation.toString()
      progress.targetProfileId=profile.profileId ?? ''; progress.targetProfileRevision=profile.profileRevision ?? 0
      progress.stage='Waiting'; progress.reason='NotApplied'; this.gyroProgress=progress
    }
    const listener: InputConfigurationListener = (_profile: LayoutProfile, revision: number): boolean => {
      const operation: number = this.gyroOperation
      if (this.gyroStore!==store || this.gyroConfigurationEpoch!==epoch || this.sourceLease!==lease ||
        revision!==this.gyroDefinitionRevision || !isEntryTouchInputMaintenanceCurrent(lease)) return false
      const completed: boolean = this.maintainSources()
      return completed && this.gyroStore===store && this.gyroConfigurationEpoch===epoch &&
        this.sourceLease===lease && revision===this.gyroDefinitionRevision && operation===this.gyroOperation &&
        isEntryTouchInputMaintenanceCurrent(lease)
    }
    this.gyroDefinitionListener=definition; this.gyroListener=listener
    store.addInputConfigurationDefinitionListener(definition)
    if (this.gyroStore!==store || this.gyroConfigurationEpoch!==epoch || this.sourceLease!==lease) {
      store.removeInputConfigurationDefinitionListener(definition); return
    }
    store.addInputConfigurationListener(listener,'touch-gyro',(): InputConfigurationProgress => this.gyroConfigurationProgress())
    if (this.gyroStore!==store || this.gyroConfigurationEpoch!==epoch || this.sourceLease!==lease) {
      store.removeInputConfigurationListener(listener); store.removeInputConfigurationDefinitionListener(definition)
    }
  }

  /** 只读缓存副本；状态查询不推进retire/Native/sensor或原配置listener。 */
  private gyroConfigurationProgress(): InputConfigurationProgress {
    const copy: InputConfigurationProgress=new InputConfigurationProgress()
    copy.stage=this.gyroProgress.stage; copy.reason=this.gyroProgress.reason
    copy.operationId=this.gyroProgress.operationId; copy.targetProfileId=this.gyroProgress.targetProfileId
    copy.targetProfileRevision=this.gyroProgress.targetProfileRevision
    return copy
  }

  /** 兼容现有前端挂接入口；来源启动与视觉订阅分别执行，后续可以独立撤销观察者。 */
  start(receive: (state: EntryTouchVisual) => void, active: boolean,
    guiReceive?: (state: GameGuiState) => void,
    geometryReceive?: (x: number, y: number) => void): void {
    this.stop()
    this.geometryReceive=geometryReceive; this.lastGeometry=''
    this.subscribeVisual(receive, guiReceive)
    this.startSources(active)
  }

  /** 只挂接只读前端投影；不会取得来源资格、重建gyro或开启生产时钟。 */
  subscribeVisual(receive: (state: EntryTouchVisual) => void,
    guiReceive?: (state: GameGuiState) => void): void {
    this.receive = receive
    // 兼容原挂接签名；未提供GUI闭包的视觉恢复不得清掉必要几何订阅。
    if (guiReceive!==undefined) { this.guiReceive=guiReceive; this.nextGuiRead=0; this.lastGui='' }
    this.lastVisual = ''
    this.deliverWithdrawnGuiTicket()
  }

  /** 撤销视觉/教学只清可选闭包；GUI缩放和菜单面板几何仍服务原schema/绘制/命中。 */
  unsubscribeVisual(): void {
    this.receive = undefined
    this.guideActive = false; this.lastVisual = ''
  }

  /** 显式挂接本来源；没有活跃宿主或来源容量不足时保持关闭，不把旧源改绑未来会话。 */
  startSources(active: boolean): void {
    // 同一原会话可重挂配置观察；gyro自身必须先确认旧callback/token结束，才允许新采样。
    // 停局后的origin已退休，后面的登记检查会拒绝，不能借重挂跨入新会话。
    this.stopSources()
    if (this.gyroConfigurationEpoch>=Number.MAX_SAFE_INTEGER) return
    const lease: EntryTouchInputMaintenanceLease | undefined = this.originLease
    if (lease === undefined || !registerEntryTouchInputMaintenanceSource(lease, this)) return
    this.sourceLease = lease
    this.bindGyroConfiguration(getLayoutStore(),lease)
    this.setActive(active)
  }

  /** 独立撤自身来源lease；先关闭时钟与迟到回调，再取消传感器，保持前端订阅可单独管理。 */
  stopSources(): boolean {
    const store: LayoutStore | undefined=this.gyroStore
    const listener: InputConfigurationListener | undefined=this.gyroListener
    const definition: InputConfigurationDefinitionListener | undefined=this.gyroDefinitionListener
    if (this.gyroConfigurationEpoch<Number.MAX_SAFE_INTEGER) this.gyroConfigurationEpoch++
    this.gyroDefinitionRevision=0
    this.gyroStore=undefined; this.gyroListener=undefined; this.gyroDefinitionListener=undefined
    this.gyroProgress.stage='Retired'; this.gyroProgress.reason='SourceRetired'
    this.active = false; this.sourceLease = undefined
    const timer: number = this.timer
    this.timer = -1
    // 先撤本地准入，再分别退出配置、GUI、时钟和传感器。任一外部步骤异常仍须执行后续清理。
    // 未完成退订的对象继续留在原有有界登记集合，供Host低频维护或最终stop回执接管。
    try { if (store!==undefined && listener!==undefined) store.removeInputConfigurationListener(listener) }
    finally {
      try { if (store!==undefined && definition!==undefined) store.removeInputConfigurationDefinitionListener(definition) }
      finally {
        try { this.retireGuiSource() }
        finally {
          try { if (timer !== -1) clearInterval(timer) }
          finally {
            this.gyro.stop()
            if (this.gyro.stoppedCleanupComplete() && this.originLease!==undefined) {
              unregisterEntryTouchInputMaintenanceSource(this.originLease,this)
            }
          }
        }
      }
    }
    // 退出scope/停钟只围栏准入；原sensor.off、Native token或回入取得未收口须保Pending。
    return this.gyro.stoppedCleanupComplete()
  }

  /** 原Host低频维护/退休回执只清本对象失权资源，活跃流仍走原16ms维护。 */
  reconcileStoppedSources(): boolean {
    if (this.active) return true
    const complete: boolean=this.gyro.reconcileStoppedCleanup()
    // 后台暂停仍持sourceLease，清理完保留其合法登记；彻底停止才释放原origin的登记槽。
    // originLease只撤本对象最早登记，不从current获取或修补后来会话的身份。
    if (complete && this.sourceLease===undefined && this.originLease!==undefined) {
      unregisterEntryTouchInputMaintenanceSource(this.originLease,this)
    }
    return complete
  }

  /**
   * 后台/模态资格由原lease合取，16ms来源时钟保留原反馈节奏；时钟不依赖receive是否存在。
   * 队列里已经取出的旧timer也核原scope，宿主停局后不能发输入或继续保持组件闭包。
   */
  setActive(active: boolean): void {
    active = active && isEntryTouchInputMaintenanceCurrent(this.sourceLease)
    this.active=active
    if (!active) {
      this.waitForGyroAdmission('SourceInactive')
      try { this.retireGuiSource() }
      finally {
        this.gyro.stop()
        if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1 }
      }
      return
    }
    else if (this.guiSource === 0 && this.guiOriginScope > 0 && typeof testNapi.gameGuiAttachSource === 'function') {
      try { this.guiSource = testNapi.gameGuiAttachSource(this.guiOriginScope) }
      catch (_) {
        // 缺GUI源只降级观察/恢复；基本触控来源的16ms维护仍继续，不创建假lease。
        this.guiSource = 0
      }
    }
    if (active && this.timer === -1) {
      const lease: EntryTouchInputMaintenanceLease | undefined = this.sourceLease
      this.timer = setInterval(() => {
        if (!this.active || lease === undefined || this.sourceLease !== lease || !isEntryTouchInputMaintenanceCurrent(lease)) return
        try { this.heartbeat?.() }
        catch (error) {
          if (!this.heartbeatWarned) {
            this.heartbeatWarned = true
            try { hilog.warn(0x0000,'GameControls','Touch frontend maintenance failed: %{public}s',String(error)) }
            catch (_) { /* 日志只缺观察，原Source/gyro维护继续，不补输入或重建订阅。 */ }
          }
        }
        this.maintainSources()
        this.refreshVisual()
      },16) as number
    }
  }

  /**
   * 来源必要维护独立于UI getter。Native缺实际mode或快照资格时立即停gyro；重新取得合法
   * schema/抓取状态后只从新样本积分，不重放停顿期间的时间或旧传感器尾量。
   */
  maintainSources(): boolean {
    const lease: EntryTouchInputMaintenanceLease | undefined = this.sourceLease
    const operation: number=this.gyroOperation
    this.gyroProgress.stage='Waiting'; this.gyroProgress.reason='SourceInactive'
    if (!this.active || lease === undefined || !isEntryTouchInputMaintenanceCurrent(lease)) return false
    try {
      if (!reconcileEntryTouchInputMaintenance(lease) || typeof testNapi.touchInteractionVisual !== 'function') {
        this.gyro.stop(); return false
      }
      if (this.gyroOptions.gyroscopeMode === 'off') {
        const closed: boolean=this.gyro.configure(false,this.gyroOptions,this.rotation,0)
        const current: boolean=operation===this.gyroOperation && this.sourceLease===lease && isEntryTouchInputMaintenanceCurrent(lease)
        if (closed && current) { this.gyroProgress.stage='Applied'; this.gyroProgress.reason='' }
        // 关闭尚未完成时只读原gyro清理状态；回入后的旧续体不能覆盖后来operation的原因。
        else if (current) this.gyroProgress.reason=this.gyro.currentStatus()
        return closed && current
      }
      if (!this.touchAdmitted || !this.grabbed) {
        this.gyro.stop(); this.gyroProgress.reason='InputNotAdmitted'; return false
      }
      const values: number[] = testNapi.touchInteractionVisual()
      if (values.length < 14 || values.some((value: number): boolean => !Number.isFinite(value))) {
        this.gyro.stop(); this.gyroProgress.reason='NativeVisualUnavailable'; return false
      }
      const nativeGrabbed: boolean = values.length < 25 || values[24] === 1
      const gyroEnabled: boolean = nativeGrabbed &&
        (this.gyroOptions.gyroscopeMode === 'always' || values[11] === 1)
      const completed: boolean=this.gyro.configure(gyroEnabled,this.gyroOptions,this.rotation,values[12])
      if (operation!==this.gyroOperation || this.sourceLease!==lease || !isEntryTouchInputMaintenanceCurrent(lease)) {
        this.gyro.stop(); return false
      }
      this.gyroProgress.stage=completed ? 'Applied' : 'Waiting'
      this.gyroProgress.reason=completed ? '' : this.gyro.currentStatus()
      return completed
    } catch (_) { this.gyro.stop(); this.gyroProgress.reason='OutcomeUnknown'; return false }
  }

  /** 同步只读投影用于DOWN后的即时反馈；定时读取补齐native命中扩展区和锁定后的静止状态。 */
  refreshVisual(): void {
    // 立即刷新也可能来自已排队的旧UI事件；原来源退休后不可读取后来资源的全局快照。
    if (!this.active || !this.hasCurrentSource()) return
    const guiReceive: ((state: GameGuiState) => void) | undefined=this.guiReceive
    const geometryReceive: ((x: number, y: number) => void) | undefined=this.geometryReceive
    const receive: ((state: EntryTouchVisual) => void) | undefined=this.receive
    if (guiReceive===undefined && geometryReceive===undefined && receive===undefined) return
    // 捕获本轮原闭包；Native/用户回调同步回入退订或换实例后，旧续体不能借新receiver发布。
    const lease: EntryTouchInputMaintenanceLease | undefined=this.sourceLease
    try {
      // GUI端口或必要接收器异常不阻断菜单面板几何；同一原时钟内分开异常边界。
      try { this.refreshGuiProjection_(guiReceive,lease) } catch (_) { this.warnProjection_() }
      // GUI接收器可经registerRegions同步停源。不得在失权后读取全局Native缓存，
      // 同一local lease也不代替仍有效的scope；只继续本次captured lease的活跃续体。
      if (!this.isCurrentProjectionSource_(lease)) return
      if (typeof testNapi.touchInteractionVisual!=='function' || (geometryReceive===undefined && receive===undefined)) return
      const values: number[] = testNapi.touchInteractionVisual()
      // Native边缘同样可同步回入停止/换scope；返回数值不能给原续体重新授予发布资格。
      if (!this.isCurrentProjectionSource_(lease)) return
      if (values.length < 14 || values.some((value: number): boolean => !Number.isFinite(value))) {
        return
      }
      const geometry: string=values[0].toString()+','+values[1].toString()
      if (geometryReceive!==undefined && geometry!==this.lastGeometry &&
        this.geometryReceive===geometryReceive && this.sourceLease===lease) {
        this.lastGeometry=geometry; this.geometryDeliveries++
        try { geometryReceive(values[0],values[1]) } catch (_) { this.warnProjection_() }
      }
      // 必要几何接收器也可停源；其返回后不能继续构值/递送可选显示。
      if (!this.isCurrentProjectionSource_(lease) || receive===undefined || this.receive!==receive) return
      const signature: string = values.join(',')
      if (signature === this.lastVisual) return
      this.lastVisual = signature
      const state = new EntryTouchVisual()
      state.menuX=values[0]; state.menuY=values[1]; state.menuVisible=values[2] === 1
      state.centerX=values[3]; state.centerY=values[4]; state.joystickX=values[5]; state.joystickY=values[6]
      state.locked=values[7] === 1; state.armed=values[8] === 1; state.progress=values[9]
      state.joystickActive=values[10] === 1; state.aiming=values[11] === 1
      state.schemaGeneration=values[12]; state.joystickIndex=values[13]
      state.guide=parseTouchGuideFeedback(values)
      this.visualDeliveries++; receive(state)
    } catch (error) {
      if (!this.warned) {
        this.warned=true
        hilog.warn(0x0000,'GameControls','Touch visual projection unavailable: %{public}s',String(error))
      }
    }
  }

  /** 每个外部返回边界复核同一个原Source；纯资格查询不维护/复活来源，也不读Native。 */
  private isCurrentProjectionSource_(lease: EntryTouchInputMaintenanceLease | undefined): boolean {
    return this.active && lease!==undefined && this.sourceLease===lease && isEntryTouchInputMaintenanceCurrent(lease)
  }

  /** 原2Hz读取保留缩放/hotbar资格；必要GUI不借可选visual receiver作为前置门。 */
  private refreshGuiProjection_(guiReceive: ((state: GameGuiState) => void) | undefined,
    lease: EntryTouchInputMaintenanceLease | undefined): void {
      // 复用现有活跃页面时钟，GUI设置最多2Hz；后台停表，真实教学仅观察这份已有快照。
      if(guiReceive!==undefined && (Date.now()>=this.nextGuiRead || Date.now()<this.nextGuiRead-500) && this.guiWidth>0 && this.guiHeight>0 &&
        this.guiVersion.length>0 && typeof testNapi.gameGuiState==='function') {
        this.nextGuiRead=Date.now()+500
        const raw: number[] = typeof testNapi.gameGuiStateForSource === 'function' ?
          testNapi.gameGuiStateForSource(this.guiSource,Math.round(this.guiWidth),Math.round(this.guiHeight),this.guiVersion,this.guideActive) :
          testNapi.gameGuiState(Math.round(this.guiWidth),Math.round(this.guiHeight),this.guiVersion,this.guideActive)
        this.guiReads++
        let state: GameGuiState=parseGameGuiState(raw)
        state.legacy=usesLegacyGuiScale(this.guiVersion)
        // Native现返回完整19项，即使游戏不支持桥也保留实际framebuffer前缀。
        // 两种完整快照均可降级到options估算；未知/截断数组不参与，估算仍没有即时恢复或导航权限。
        if(!state.valid && (raw.length===13 || raw.length===19) && this.directory.length>0) {
          try {
            const stat=fs.statSync(this.directory+'/options.txt')
            const stamp: string=stat.mtime.toString()+':'+stat.size.toString()
            if(stat.size>1048576) { this.fallbackOptions=''; this.fallbackOptionsStamp=stamp }
            if(stamp!==this.fallbackOptionsStamp && stat.size<=1048576) {
              this.fallbackOptions=fs.readTextSync(this.directory+'/options.txt'); this.fallbackOptionsStamp=stamp
            }
          } catch (_) { this.fallbackOptions='' }
          const candidate: GameGuiState=estimateGameGuiFromOptions(this.fallbackOptions,raw[3],raw[4],!this.grabbed,this.fallbackGuiRevision,state.legacy)
          const key: string=[candidate.requested,candidate.effective,raw[3],raw[4],candidate.menu].join(',')
          if(key!==this.fallbackGuiKey) { this.fallbackGuiKey=key; this.fallbackGuiRevision++ }
          candidate.revision=this.fallbackGuiRevision; state=candidate
        }
        // 无有效几何时仍可有本source真实Cancelled/Failed回执（窗口已退休）。它只结束
        // 原恢复票据，不授予导航/即时恢复能力；旧公共包不使用这一私有来源证明。
        if (typeof testNapi.gameGuiStateForSource === 'function' && this.guiSource > 0 && raw.length === 19 &&
          Number.isSafeInteger(raw[10]) && raw[10] > 0 && (raw[11] === -1 || raw[11] === 2 || raw[11] === 3)) {
          state.requestId = raw[10]; state.result = raw[11]
        }
        const signature: string=JSON.stringify(state)
        if (this.guiRestoreTicket > 0 && state.requestId === this.guiRestoreTicket && state.result !== 1) this.guiRestoreTicket = 0
        if(signature!==this.lastGui && this.guiReceive===guiReceive && this.sourceLease===lease) {
          this.lastGui=signature
          // 必要GUI接收器失败只影响这次投影，不能阻断后面的必要菜单几何或来源维护。
          try { guiReceive(state) } catch (_) { this.warnProjection_() }
        }
      }
  }

  /** 只记固定诊断，不把回调异常文字带入操作收据；同一次会话只告警一次。 */
  private warnProjection_(): void {
    if (this.warned) return
    this.warned=true
    try { hilog.warn(0x0000,'GameControls','Touch projection receiver unavailable') } catch (_) {}
  }

  /** 原计数/原lease的只读快照；不调用Native getter或维护算法。 */
  hasCurrentSource(): boolean { return isEntryTouchInputMaintenanceCurrent(this.sourceLease) }

  /** 状态字段只记录已取得的原Source与投影调用次数，不代替Native/UI完成回执。 */
  observationSnapshot(): EntryTouchObservationSnapshot {
    const snapshot: EntryTouchObservationSnapshot=new EntryTouchObservationSnapshot()
    snapshot.sourceCurrent=isEntryTouchInputMaintenanceCurrent(this.sourceLease)
    snapshot.timerActive=this.timer!==-1
    snapshot.visualSubscribed=this.receive!==undefined
    snapshot.geometrySubscribed=this.geometryReceive!==undefined
    snapshot.guiSubscribed=this.guiReceive!==undefined
    snapshot.guiReads=this.guiReads; snapshot.geometryDeliveries=this.geometryDeliveries
    snapshot.visualDeliveries=this.visualDeliveries; snapshot.gyroStatus=this.gyro.currentStatus()
    return snapshot
  }

  /** 恢复属于本前端原来源；没有lease时明确未接受，不凭global current取得后来会话资格。 */
  restoreGui(scale: number, revision: number): number {
    if (this.guiSource === 0 || typeof testNapi.restoreGameGuiScaleForSource !== 'function') return 0
    const ticket: number = testNapi.restoreGameGuiScaleForSource(this.guiSource,scale,revision)
    if (ticket > 0) this.guiRestoreTicket = ticket
    return ticket
  }

  /** 先撤本地资格再通知Native；不join worker、不经JNI，在background/stop也能及时完成。 */
  private retireGuiSource(): void {
    const source: number = this.guiSource
    this.guiSource = 0
    const ticket: number = this.guiRestoreTicket
    this.guiRestoreTicket = 0
    try {
      if (source > 0 && typeof testNapi.gameGuiRetireSource === 'function') testNapi.gameGuiRetireSource(source)
    } finally {
      // source退休后不会再有来自原cache的正常ACK；只结束本前端原票的等待，状态3
      // 表示资格撤销/未完成，绝不说实际set成功或worker已join。Native异常仍向外报告，
      // 由stopSources/setActive的独立finally继续其它资源清理；不用新source替旧票。
      if (ticket > 0) { this.guiWithdrawnTicket = ticket; this.deliverWithdrawnGuiTicket() }
    }
  }

  /** 本对象拥有的一次撤票观察，先消费再回调防同步重入重复；失败不恢复Native资格。 */
  private deliverWithdrawnGuiTicket(): void {
    const ticket: number = this.guiWithdrawnTicket
    if (ticket <= 0 || this.guiReceive === undefined) return
    this.guiWithdrawnTicket = 0
    const state: GameGuiState = new GameGuiState()
    state.requestId = ticket; state.result = 3
    this.lastGui = ''; this.guiReceive(state)
  }

  /** 页面退休后清定时器和闭包，迟到的时钟任务不会触达旧组件。 */
  stop(): void {
    try { this.stopSources() }
    finally {
      this.unsubscribeVisual()
      this.guiReceive=undefined; this.geometryReceive=undefined; this.lastGeometry=''; this.lastGui=''
      this.heartbeat=undefined
    }
  }
}

/**
 * 单局稳定宿主拥有的IME来源运行体。只有这里持有进程controller和attach串行状态；
 * UI提供原UIContext资源与明确请求，观察订阅只投影状态，退订不能停止租约维护。
 * Coordinator继续拥有文本命令资格/Native epoch恢复，本类不替代它或重写Native编辑键。
 */
import { inputMethod } from '@kit.IMEKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { UIContext } from '@ohos.arkui.UIContext'
import deviceInfo from '@ohos.deviceInfo'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { DiagnosticPolicy } from 'commons'
import { AmclInputSource, GLFW_KEY_BACKSPACE, GLFW_KEY_DELETE, GLFW_KEY_ENTER, GLFW_KEY_ESCAPE,
  OHOS_DEL, OHOS_FORWARD_DEL, OHOS_ENTER, OHOS_ESCAPE, ImeCallbackLease, ImeInsertPiece,
  ImeInsertSplit, TextInputSessionLease, TextInputBeginStatus, TextInputKeyTapResult,
  TEXT_INPUT_MAX_SCALARS, getImeActivationGate, splitImeInsertText } from 'gamecontrol'
import { getEntryTextInputSession, commitEntryTextInput, tapEntryTextInputKey,
  sendLegacyEntryKeyTap, endEntryTextInputSession, reconcileEntryTextInputSession,
  addEntryTextSessionAvailabilityListener, removeEntryTextSessionAvailabilityListener,
  setEntrySoftTextInputRequested, isEntrySoftTextInputRequested } from '../components/EntryTextInputSession'

const TAG: string = 'EntryTextRuntime'
const RETRY_BUDGET: number = 5
const STOP_BUDGET_MS: number = 2000

/** 原页面资源的不可复用身份；相同role或UIContext不意味着另一轮绑定是原资源。 */
export class EntryTextInputBinding {
  readonly id: number
  readonly role: string
  constructor(id: number, role: string) { this.id = id; this.role = role }
}

/** 一轮明确请求的原能力；运行体还核精确对象，旧按钮不能借相同binding的后来activation。 */
export class EntryTextInputIntent {
  readonly binding: EntryTextInputBinding
  readonly activation: number
  constructor(binding: EntryTextInputBinding, activation: number) { this.binding = binding; this.activation = activation }
}

/** 显式UI资源，不从后来current页面取context；关闭通知也只属于原绑定。 */
export interface EntryTextInputViewResource {
  uiContext: UIContext
  onClose: () => void
}

/** 每次返回独立显示副本；UI写这个对象不能改变controller/lease或原请求。 */
export class EntryTextInputProjection {
  role: string = ''
  phase: string = 'Pending'
  echo: string = ''
  preview: string = ''
  requested: boolean = false
  attached: boolean = false
  failure: string = ''
  /** 最新一次原操作的文档能力结果；只是显示副本，不授予文档修改或系统回调权限。 */
  documentOperation: string = ''
  documentStartUtf16: number = 0
  documentEndUtf16: number = 0
  documentOutcome: string = ''
  documentMessage: string = ''
}

/** 停止只报告实取事实；Pending/Failed不冒充OS已detach或Native完成消费。 */
export class EntryTextInputRuntimeSnapshot {
  phase: string = 'Created'
  controllerPhase: string = 'Idle'
  stopOutcome: string = 'NotStopped'
  callbackFenced: boolean = true
  localLeaseClosed: boolean = true
  platformDetachResolved: boolean = false
  failure: string = ''
}

/** 单来源请求/回声状态。三角色使用同一实现，只保各自的显式文本交互差异。 */
class EntryTextSource {
  readonly binding: EntryTextInputBinding
  readonly resource: EntryTextInputViewResource
  wanted: boolean = false
  intent: EntryTextInputIntent | undefined = undefined
  retired: boolean = false
  activation: number = 0
  requestOrder: number = 0
  retryAttempt: number = 0
  retryExhausted: boolean = false
  failedActivation: boolean = false
  failure: string = ''
  echo: string = ''
  preview: string = ''
  echoGeneration: number = 0
  /** 每个来源最多保存一个原文档意图，旧激活/原 Native 文字代次退出即清；不积压请求队列。 */
  documentRequest: EntryTextDocumentRequest | undefined = undefined
  observer: ((value: EntryTextInputProjection) => void) | undefined = undefined
  constructor(binding: EntryTextInputBinding, resource: EntryTextInputViewResource) {
    this.binding = binding; this.resource = resource
  }
}

/** 一次原attach操作，Promise、OS回调、text lease与resource始终指向同一对象。 */
class EntryImeOperation {
  readonly source: EntryTextSource
  readonly activation: number
  readonly lease: TextInputSessionLease
  readonly scope: ImeCallbackLease
  phase: string = 'Attaching'
  retired: boolean = false
  localLeaseClosed: boolean = false
  failure: string = ''
  insert: (text: string) => void = (_text: string): void => {}
  deleteLeft: (length: number) => void = (_length: number): void => {}
  deleteRight: (length: number) => void = (_length: number): void => {}
  functionKey: (key: inputMethod.FunctionKey) => void = (_key: inputMethod.FunctionKey): void => {}
  getLeft: (length: number) => string = (_length: number): string => ''
  getRight: (length: number) => string = (_length: number): string => ''
  getIndex: () => number = (): number => 0
  preview: inputMethod.SetPreviewTextCallback = (_text: string, _range: inputMethod.Range): void => {}
  finishPreview: () => void = (): void => {}
  select: (range: inputMethod.Range) => void = (_range: inputMethod.Range): void => {}
  constructor(source: EntryTextSource, lease: TextInputSessionLease) {
    this.source = source; this.activation = source.activation; this.lease = lease
    this.scope = new ImeCallbackLease(lease, source.binding.role)
  }
}

/**
 * 文档 Range 与预编辑内部选区是两个对象。这里仅保存原 operation 的有界意图和 UTF-16
 * 原值，不持有第二份游戏文档、不推测实际 caret，也不为没有 provider 的请求制造 ACK。
 * replacementText 是本次已按原预编辑预算准备的字符串，只能描述请求，不是替换后的文档。
 */
class EntryTextDocumentRequest {
  readonly operation: EntryImeOperation
  readonly hostGeneration: number
  readonly kind: string
  readonly startUtf16: number
  readonly endUtf16: number
  readonly replacementText: string
  readonly outcome: string
  constructor(operation: EntryImeOperation, hostGeneration: number, kind: string,
    startUtf16: number, endUtf16: number, replacementText: string, outcome: string) {
    this.operation = operation; this.hostGeneration = hostGeneration; this.kind = kind
    // 只接收已捕获的原数值；构造阶段不再读取可能带getter的外部Range对象。
    this.startUtf16 = startUtf16; this.endUtf16 = endUtf16
    this.replacementText = replacementText; this.outcome = outcome
  }
}

export class EntryTextInputRuntime {
  private sources: Map<number, EntryTextSource> = new Map<number, EntryTextSource>()
  private nextBinding: number = 1
  private nextRequest: number = 1
  private controller: inputMethod.InputMethodController | undefined = undefined
  private operation: EntryImeOperation | undefined = undefined
  private started: boolean = false
  private stopped: boolean = false
  private stopOutcome: string = 'NotStopped'
  private detachResolved: boolean = false
  private failure: string = ''
  private retryTimer: number = -1
  private retrySource: EntryTextSource | undefined = undefined
  private reconciling: boolean = false
  private reconcileAgain: boolean = false
  private available: () => void = (): void => { this.onAvailability() }
  private droppedControls: number = 0
  private rejectedKeys: number = 0
  private truncatedInserts: number = 0
  /** 单局原runtime最多64条阶段观察；不随observer退订停维护，不作为controller状态。 */
  private imePhaseTraceCount: number = 0
  private stopTimer: number = -1
  private stopListeners: Set<(value: EntryTextInputRuntimeSnapshot) => void> = new Set<(value: EntryTextInputRuntimeSnapshot) => void>()

  /** 构造只初始化本地对象；prepare之前不查询Native、不取得controller、不发OS attach。 */
  constructor() {}

  /** Host实际装配成立之后才启动。重复start幂等，已停止运行体没有借UI重建复活的入口。 */
  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    addEntryTextSessionAvailabilityListener(this.available)
    try { this.controller = inputMethod.getController() }
    catch (error) { this.failure = this.message(error); this.note('controller unavailable', this.failure) }
    this.maintain()
  }

  /** 原UIContext绑定不触发controller；role精确取chat/field/physical，不猜窗口或设备身份。 */
  bind(role: string, resource: EntryTextInputViewResource): EntryTextInputBinding | undefined {
    if (this.stopped || (role !== 'chat' && role !== 'field' && role !== 'physical') ||
        this.nextBinding >= Number.MAX_SAFE_INTEGER) return undefined
    const binding = new EntryTextInputBinding(this.nextBinding++, role)
    this.sources.set(binding.id, new EntryTextSource(binding, resource))
    this.noteImePhase('bind', binding, 0, 'Bound')
    return binding
  }

  /** 显式激活翻转清原来源预算；新绑定/同名role不能改写在途旧操作的resource。 */
  request(binding: EntryTextInputBinding, wanted: boolean): void {
    const source = this.source(binding)
    if (source === undefined || source.wanted === wanted) return
    source.wanted = wanted; source.activation++
    source.intent = wanted ? new EntryTextInputIntent(binding, source.activation) : undefined
    source.documentRequest = undefined
    source.failedActivation = false; source.retryExhausted = false; source.retryAttempt = 0; source.failure = ''
    if (wanted) source.requestOrder = this.nextRequest++
    this.noteImePhase('request', binding, source.activation, wanted ? 'Wanted' : 'Hidden')
    this.clearRetry(source)
    this.updateSoftRequests()
    this.reconcile()
  }

  /** 退观察只释放UI闭包，不改变wanted/operation；Host维护和OS原回调仍由稳定运行体拥有。 */
  observe(binding: EntryTextInputBinding, observer: (value: EntryTextInputProjection) => void): void {
    const source = this.source(binding)
    if (source === undefined) return
    source.observer = observer; this.publish(source)
  }
  /** 精确原资源的显示闭包退出，保留请求和Host维护；与真实unbind不同。 */
  unobserve(binding: EntryTextInputBinding): void {
    const source = this.source(binding)
    if (source !== undefined) source.observer = undefined
  }

  /** 原资源真实退出会退休请求和callback，不用“关订阅”冒充unbind。 */
  unbind(binding: EntryTextInputBinding): void {
    const source = this.source(binding)
    if (source === undefined) return
    source.wanted = false; source.retired = true; source.observer = undefined; source.activation++
    source.intent = undefined
    source.documentRequest = undefined
    this.clearRetry(source); this.sources.delete(binding.id); this.updateSoftRequests(); this.reconcile()
  }

  /** Host独立心跳对账Native epoch并维护所有请求；没有UI观察者也不丢预算恢复/清理。 */
  maintain(): void {
    if (!this.started || this.stopped) return
    reconcileEntryTextInputSession()
    const operation = this.operation
    if (operation !== undefined) this.syncEcho(operation)
    this.reconcile()
  }

  /** 用户重新显示是明确恢复边界。Failed detach只重试原cleanup，不新造controller/lease。 */
  show(intent: EntryTextInputIntent | undefined): void {
    const source = this.intentSource(intent)
    if (source === undefined || !source.wanted || this.stopped) return
    source.failedActivation = false; source.retryExhausted = false; source.retryAttempt = 0; source.failure = ''
    this.clearRetry(source)
    const operation = this.operation
    if (operation !== undefined && operation.phase === 'CleanupFailed') { this.detach(operation); return }
    if (operation !== undefined && operation.source === source && this.accepts(operation)) {
      const controller = this.controller
      if (controller === undefined || source.binding.role === 'physical') return
      try { controller.showTextInput(inputMethod.RequestKeyboardReason.TOUCH).catch((error: BusinessError): void => {
        if (this.operation !== operation) return
        operation.failure = error.message; this.retire(operation); this.detach(operation)
      }) } catch (error) { operation.failure = this.message(error); this.retire(operation); this.detach(operation) }
      return
    }
    this.reconcile()
  }

  /** UI渲染时取原请求能力；调用本身没有OS/Native副作用，Pending阶段也可明确取消。 */
  captureIntent(binding: EntryTextInputBinding): EntryTextInputIntent | undefined { return this.source(binding)?.intent }
  submit(intent: EntryTextInputIntent | undefined): void { this.closeSoft(intent, false) }
  cancel(intent: EntryTextInputIntent | undefined): void { this.closeSoft(intent, true) }

  /** stop同步围栏后返回。待attach完成只清理原操作；不阻塞线程等OS Promise。 */
  stop(reason: string): EntryTextInputRuntimeSnapshot {
    if (!this.stopped) {
      this.stopped = true; this.stopOutcome = 'Completed'; this.clearRetry()
      if (this.started) removeEntryTextSessionAvailabilityListener(this.available)
      this.sources.forEach((source: EntryTextSource): void => {
        source.wanted = false; source.retired = true; source.intent = undefined
        source.documentRequest = undefined; source.activation++
      })
      this.updateSoftRequests()
      const operation = this.operation
      if (operation !== undefined) {
        operation.failure = operation.failure || reason; this.retire(operation); this.closeLease(operation); this.stopOutcome = 'Pending'
        if (operation.phase !== 'Attaching' && operation.phase !== 'Detaching') this.detach(operation)
      }
      if (this.stopOutcome === 'Pending') {
        this.stopTimer = setTimeout((): void => {
          this.stopTimer = -1
          if (this.stopOutcome !== 'Pending') return
          this.stopOutcome = 'TimedOut'; this.failure = 'StopDetachBudgetExceeded'; this.publishStop()
        }, STOP_BUDGET_MS) as number
      } else this.publishStop()
    }
    return this.snapshot()
  }

  /** 全新副本，只陈述controller/本地租约结果，不声称Native abort等于真实游戏消费完成。 */
  snapshot(): EntryTextInputRuntimeSnapshot {
    const value = new EntryTextInputRuntimeSnapshot(), operation = this.operation
    value.phase = this.stopped ? this.stopOutcome === 'Pending' ? 'Stopping' :
      this.stopOutcome === 'Failed' || this.stopOutcome === 'TimedOut' ? 'StopFailed' : 'Stopped' : this.started ? 'Running' : 'Created'
    value.controllerPhase = operation?.phase ?? 'Idle'; value.stopOutcome = this.stopOutcome
    value.callbackFenced = operation === undefined || operation.retired
    value.localLeaseClosed = operation === undefined || operation.localLeaseClosed
    value.platformDetachResolved = this.detachResolved; value.failure = this.failure
    return value
  }

  /** Host登记原stop结果闭包；新观察者得到终结事实，Pending不能提前发成Completed。 */
  addStopOutcomeListener(listener: (value: EntryTextInputRuntimeSnapshot) => void): void {
    this.stopListeners.add(listener)
    if (this.stopped && this.stopOutcome !== 'Pending') {
      try { listener(this.snapshot()) } catch (error) { this.note('stop observer failed', this.message(error)) }
    }
  }
  removeStopOutcomeListener(listener: (value: EntryTextInputRuntimeSnapshot) => void): void { this.stopListeners.delete(listener) }

  /** 精确原订阅集合快照，回入退订/日志异常不能阻止其它Host回执或真实资源收口。 */
  private publishStop(): void {
    if (!this.stopped || this.stopOutcome === 'Pending') return
    if (this.stopTimer >= 0) clearTimeout(this.stopTimer)
    this.stopTimer = -1
    const listeners: ((value: EntryTextInputRuntimeSnapshot) => void)[] = []
    this.stopListeners.forEach((listener: (value: EntryTextInputRuntimeSnapshot) => void): void => { listeners.push(listener) })
    for (const listener of listeners) {
      try { listener(this.snapshot()) } catch (error) { this.note('stop observer failed', this.message(error)) }
    }
  }

  /** 只有原绑定对象在map中仍存活才有操作权限；id相同的另一个对象也拒绝。 */
  private source(binding: EntryTextInputBinding): EntryTextSource | undefined {
    const source = this.sources.get(binding.id)
    return source !== undefined && source.binding === binding && !source.retired ? source : undefined
  }

  /** 保原softRequests的role聚合，不因重建时旧实例退出而清掉同role的新请求。 */
  private updateSoftRequests(): void {
    let chat: boolean = false, field: boolean = false
    this.sources.forEach((source: EntryTextSource): void => {
      if (source.retired || !source.wanted) return
      if (source.binding.role === 'chat') chat = true
      if (source.binding.role === 'field') field = true
    })
    setEntrySoftTextInputRequested('chat', chat); setEntrySoftTextInputRequested('field', field)
  }

  /** 活着的soft请求优先，soft失败不偷偷自动抢回hard；同层按明确请求次序选择。 */
  private candidate(): EntryTextSource | undefined {
    let soft: EntryTextSource | undefined = undefined, hard: EntryTextSource | undefined = undefined
    this.sources.forEach((source: EntryTextSource): void => {
      if (source.retired || !source.wanted) return
      if (source.binding.role === 'physical') {
        if (hard === undefined || source.requestOrder < hard.requestOrder) hard = source
      } else if (soft === undefined || source.requestOrder < soft.requestOrder) soft = source
    })
    return soft ?? (isEntrySoftTextInputRequested() ? undefined : hard)
  }

  /** 单一controller串行机；同步availability/观察回入只要求再检查，不重叠attach/detach。 */
  private reconcile(): void {
    if (this.reconciling) { this.reconcileAgain = true; return }
    this.reconciling = true
    do {
      this.reconcileAgain = false
      const candidate = this.stopped ? undefined : this.candidate(), operation = this.operation
      if (operation !== undefined) {
        if (operation.source !== candidate || operation.activation !== operation.source.activation || operation.source.retired) {
          this.retire(operation)
          if (operation.phase === 'Attached') this.detach(operation)
        }
      } else if (this.started && !this.stopped && this.controller !== undefined && candidate !== undefined &&
          !candidate.failedActivation && !candidate.retryExhausted && this.retryTimer < 0) this.attach(candidate)
      this.publishAll()
    } while (this.reconcileAgain)
    this.reconciling = false
  }

  /** 只有HostRejected是有界暂缺；Busy等真正租约交还，InvalidOwner锁本activation。 */
  private attach(source: EntryTextSource): void {
    // tryBegin可能通知现有订阅者；观察先冻结本次原请求代次，不能用返回后的current补身份。
    const requestedActivation: number = source.activation
    const begin = getEntryTextInputSession().tryBegin(source.binding.role === 'physical' ? 'desktop-physical-ime' : 'mobile-ime-' + source.binding.role)
    this.noteImePhase('lease', source.binding, requestedActivation, begin.status.toString())
    if (begin.lease === undefined) {
      if (begin.status === TextInputBeginStatus.HostRejected) this.retry(source)
      else if (begin.status === TextInputBeginStatus.InvalidOwner) { source.failedActivation = true; source.failure = 'InvalidOwner' }
      return
    }
    const operation = new EntryImeOperation(source, begin.lease); this.operation = operation
    source.echo = ''; source.preview = ''; source.echoGeneration = getEntryTextInputSession().hostGenerationOf(operation.lease)
    this.bindCallbacks(operation)
    const controller = this.controller
    if (controller === undefined) { this.attachFailed(operation, 'ControllerUnavailable'); return }
    const physical: boolean = source.binding.role === 'physical'
    const config: inputMethod.TextConfig = { inputAttribute: { textInputType: inputMethod.TextInputType.TEXT,
      enterKeyType: physical ? inputMethod.EnterKeyType.NEWLINE : source.binding.role === 'field' ? inputMethod.EnterKeyType.DONE : inputMethod.EnterKeyType.SEND } }
    if (physical) config.newEditBox = true
    let pending: Promise<void>
    try {
      // 预编辑能力必须在attach时协商，普通编辑/查询在成功之后注册。
      controller.on('setPreviewText', operation.preview); controller.on('finishTextPreview', operation.finishPreview)
      // API23起，两种入口都显式绑定原UI资源的窗口；showKeyboard仍按原physical/soft意图。
      // 这只收紧窗口关联。官方JS listener仍会查进程callback表，不能据此宣布最早OS来源已闭。
      // API20保原legacy能力；错误仍由原operation的attachFailed/cleanup承接，不降级重发文本。
      this.noteImePhase('attach-call', source.binding, operation.activation, 'Called')
      pending = deviceInfo.sdkApiVersion >= 23
        ? controller.attachWithUIContext(source.resource.uiContext, config,
          { showKeyboard: !physical, requestKeyboardReason: inputMethod.RequestKeyboardReason.NONE })
        : controller.attach(!physical, config)
    } catch (error) { this.attachFailed(operation, this.message(error)); return }
    pending.then((): void => {
      if (this.operation !== operation) {
        this.noteImePhase('attach-resolved', operation.source.binding, operation.activation, 'OriginalOperationNoLongerCurrent')
        return
      }
      operation.phase = 'Attached'
      if (!this.currentRequest(operation)) {
        this.noteImePhase('attach-resolved', operation.source.binding, operation.activation, 'OriginalRequestRetired')
        this.retire(operation); this.detach(operation); return
      }
      if (!this.registerCallbacks(operation)) { this.attachFailed(operation, 'PostAttachCallbackRegistrationFailed'); return }
      getImeActivationGate().setActive(this.gateRole(source), true); this.publish(source)
      this.noteImePhase('attached', operation.source.binding, operation.activation, 'CallbacksRegistered')
    }).catch((error: BusinessError): void => { if (this.operation === operation) this.attachFailed(operation, error.message) })
  }

  /** 原操作出现平台失败锁其activation；先围栏，再有界清理同一controller。 */
  private attachFailed(operation: EntryImeOperation, reason: string): void {
    this.noteImePhase('attach-failed', operation.source.binding, operation.activation, 'Failed')
    // 旧Promise可能在同绑定已经关→开后拒绝，只能记录旧操作失败，不能把新activation
    // 锁成永久失败。cleanup仍针对原lease/controller，完成后再处理后来明确的请求。
    if (operation.activation === operation.source.activation && !operation.source.retired) {
      operation.source.failedActivation = true; operation.source.failure = reason
    }
    operation.failure = reason
    this.retire(operation); this.detach(operation)
  }

  /** 捕获完整原operation和已有ImeCallbackLease；迟到查询不清后来echo，迟到编辑不借新lease。 */
  private bindCallbacks(operation: EntryImeOperation): void {
    operation.insert = (text: string): void => {
      const accepted: boolean = this.accepts(operation)
      hilog.info(0x0, TAG, 'AMCL_IMEINSERT role=%{public}s len=%{public}d accepted=%{public}d',
        operation.source.binding.role, text.length, accepted ? 1 : 0)
      if (accepted) this.insert(operation, text)
    }
    operation.deleteLeft = (length: number): void => { if (this.accepts(operation)) this.deleteText(operation, length, false) }
    operation.deleteRight = (length: number): void => { if (this.accepts(operation)) this.deleteText(operation, length, true) }
    operation.functionKey = (_key: inputMethod.FunctionKey): void => { if (this.accepts(operation)) this.functionKey(operation) }
    operation.getLeft = (length: number): string => this.accepts(operation) ? this.leftText(operation, length) : ''
    operation.getRight = (_length: number): string => ''
    operation.getIndex = (): number => this.accepts(operation) ? this.utf16Length(operation) : 0
    operation.preview = (text: string, range: inputMethod.Range): void => { if (this.accepts(operation)) this.preview(operation, text, range) }
    operation.finishPreview = (): void => { if (this.accepts(operation)) this.finishPreview(operation) }
    // selectByRange 是原编辑文档的选择命令，不能因为已有 preview 就改成预编辑内部选区。
    operation.select = (range: inputMethod.Range): void => { if (this.accepts(operation)) this.documentSelection(operation, range) }
  }

  /** 身份检查先于任何业务或Native调用，连原可写lease被冻结数值被改也不能越过围栏。 */
  private accepts(operation: EntryImeOperation): boolean {
    const current: EntryImeOperation | undefined = this.operation
    return current === operation && !operation.retired && operation.phase === 'Attached' && this.currentRequest(operation) &&
      operation.scope.accepts(current.scope, current.lease, operation.source.binding.role)
  }
  /** 原资源/原activation仍是明确候选；不以同role、相同UIContext或新请求替代原操作。 */
  private currentRequest(operation: EntryImeOperation): boolean {
    return !this.stopped && !operation.source.retired && operation.source.wanted &&
      this.source(operation.source.binding) === operation.source && operation.activation === operation.source.activation &&
      this.candidate() === operation.source
  }

  /** SDK要求attach后普通on，preview不能在此off再on；失败保持真实cleanup结果。 */
  private registerCallbacks(operation: EntryImeOperation): boolean {
    const controller = this.controller
    if (controller === undefined) return false
    try {
      controller.on('insertText', operation.insert); controller.on('deleteLeft', operation.deleteLeft)
      if (operation.source.binding.role === 'physical') controller.on('deleteRight', operation.deleteRight)
      controller.on('sendFunctionKey', operation.functionKey); controller.on('getLeftTextOfCursor', operation.getLeft)
      controller.on('getRightTextOfCursor', operation.getRight); controller.on('getTextIndexAtCursor', operation.getIndex)
      controller.on('selectByRange', operation.select); return true
    } catch (error) { this.note('callback registration failed', this.message(error)); return false }
  }

  /** 同步退休先于每个可失败的off；逐项隔离失败，不能第一项失败后留下后续合法注册。 */
  private retire(operation: EntryImeOperation): void {
    if (operation.retired) return
    operation.retired = true; operation.scope.retire(); getImeActivationGate().setActive(this.gateRole(operation.source), false)
    if (operation.source.documentRequest?.operation === operation) operation.source.documentRequest = undefined
    const controller = this.controller
    if (controller === undefined) return
    try { controller.off('insertText', operation.insert) } catch (_) {}
    try { controller.off('deleteLeft', operation.deleteLeft) } catch (_) {}
    try { controller.off('deleteRight', operation.deleteRight) } catch (_) {}
    try { controller.off('sendFunctionKey', operation.functionKey) } catch (_) {}
    try { controller.off('getLeftTextOfCursor', operation.getLeft) } catch (_) {}
    try { controller.off('getRightTextOfCursor', operation.getRight) } catch (_) {}
    try { controller.off('getTextIndexAtCursor', operation.getIndex) } catch (_) {}
    try { controller.off('setPreviewText', operation.preview) } catch (_) {}
    try { controller.off('finishTextPreview', operation.finishPreview) } catch (_) {}
    try { controller.off('selectByRange', operation.select) } catch (_) {}
  }

  /** 原操作detach不重绑current UI。拒绝后隔离controller，只有明确show可重试旧cleanup。 */
  private detach(operation: EntryImeOperation): void {
    if (this.operation !== operation || operation.phase === 'Detaching') return
    this.retire(operation); operation.phase = 'Detaching'; this.detachResolved = false
    const controller = this.controller
    if (controller === undefined) { this.detachFailed(operation, 'ControllerUnavailable'); return }
    const runDetach = (): void => {
      let pending: Promise<void>
      try { pending = controller.detach() } catch (error) { this.detachFailed(operation, this.message(error)); return }
      pending.then((): void => {
        if (this.operation !== operation) return
        this.detachResolved = true; this.closeLease(operation); this.operation = undefined
        operation.source.echo = ''; operation.source.preview = ''; operation.source.echoGeneration = 0
        if (this.stopped) {
          if (this.stopOutcome !== 'TimedOut') this.stopOutcome = operation.localLeaseClosed ? 'Completed' : 'Failed'
          this.publishStop()
        }
        this.reconcile()
      }).catch((error: BusinessError): void => { if (this.operation === operation) this.detachFailed(operation, error.message) })
    }
    if (operation.source.binding.role === 'physical') { runDetach(); return }
    try { controller.hideTextInput().catch((error: BusinessError): void => { this.note('hide rejected before detach', error.message) }).then(runDetach) }
    catch (error) { this.note('hide threw before detach', this.message(error)); runDetach() }
  }
  /** OS未确认解绑时保原controller隔离与失败事实，本地闭租约不伪称平台资源已退休。 */
  private detachFailed(operation: EntryImeOperation, reason: string): void {
    this.closeLease(operation); operation.phase = 'CleanupFailed'; operation.failure = reason; this.failure = reason
    if (this.stopped) { if (this.stopOutcome !== 'TimedOut') this.stopOutcome = 'Failed'; this.publishStop() }
    this.publishAll(); this.note('detach failed; original controller quarantined', reason)
  }
  /** 仅闭原text lease；Coordinator的abort仍只是本地围栏，不能记为游戏已消费。 */
  private closeLease(operation: EntryImeOperation): void {
    if (operation.localLeaseClosed) return
    operation.localLeaseClosed = endEntryTextInputSession(operation.lease, operation.failure || 'ime-detach')
    // END失败后的Coordinator abort只证明本地围栏，不在snapshot伪称Native已确认退休。
    if (!operation.localLeaseClosed) { this.failure = 'LocalTextLeaseCloseRejected'; this.note('local lease close rejected', this.failure) }
  }

  /** HostRejected最多5次退避；timer捕获原source/activation，不给重建UI借用旧预算。 */
  private retry(source: EntryTextSource): void {
    if (this.retryTimer >= 0) return
    if (source.retryAttempt >= RETRY_BUDGET) { source.retryExhausted = true; source.failure = 'HostRejectedBudgetExhausted'; return }
    const activation = source.activation, delay = 50 * Math.pow(2, source.retryAttempt++)
    this.retrySource = source
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1; this.retrySource = undefined
      if (!source.retired && source.activation === activation && source.wanted) this.reconcile()
    }, delay) as number
  }
  /** 取消指定原来源或stop唯一timer，兄弟来源不能误清另一轮等待。 */
  private clearRetry(source: EntryTextSource | undefined = undefined): void {
    if (source !== undefined && this.retrySource !== source) return
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer)
    this.retryTimer = -1; this.retrySource = undefined
  }
  /** 真实epoch/lease交还只重新武装暂缺预算；OS永久失败等待用户激活/show。 */
  private onAvailability(): void {
    if (!this.started || this.stopped) return
    this.sources.forEach((source: EntryTextSource): void => {
      if (source.retryExhausted) { source.retryExhausted = false; source.retryAttempt = 0; source.failure = '' }
    })
    this.reconcile()
  }

  /** 本地echo只描述当前host号的成功提交；epoch恢复不把旧echo作为真实游戏文本。 */
  private syncEcho(operation: EntryImeOperation): void {
    const generation = getEntryTextInputSession().hostGenerationOf(operation.lease), source = operation.source
    if (generation === source.echoGeneration) return
    source.echo = ''; source.preview = ''; source.documentRequest = undefined
    source.echoGeneration = generation; this.publish(source)
  }

  /** 同一拆分实现：hard逐行Enter，soft单行首换行提交并关闭，失败即停止后续段/按键。 */
  private insert(operation: EntryImeOperation, text: string): void {
    if (text.length === 0) return
    const source = operation.source, split: ImeInsertSplit = splitImeInsertText(text)
    this.droppedControls += split.droppedControls
    if (split.droppedControls > 0) this.counted('dropped non-printable controls', this.droppedControls)
    for (let i: number = 0; i < split.pieces.length; i++) {
      // Native命令可同步导致stop/unbind；回调入场准入不能授权其后的另一个文本段/Enter。
      if (!this.accepts(operation)) return
      const piece: ImeInsertPiece = split.pieces[i]
      if (piece.lineBreak) {
        this.finishPreview(operation)
        if (!this.accepts(operation)) return
        if (source.binding.role !== 'physical') {
          if (i + 1 < split.pieces.length) this.counted('truncated after first line break', ++this.truncatedInserts)
          this.submit(source.intent); return
        }
        if (!this.keyTap(source, operation.lease, OHOS_ENTER, GLFW_KEY_ENTER)) return
        source.echo = ''; this.publish(source); continue
      }
      if (!commitEntryTextInput(operation.lease, piece.text)) return
      if (!this.accepts(operation)) return
      this.syncEcho(operation); source.echo = this.recent(source.echo + piece.text); this.finishPreview(operation); this.publish(source)
    }
  }
  /**
   * OS setPreviewText 的 Range 表示原文档替换范围；TEXT_EDITING 内部 caret 仅属于本包。
   * 原 Range 始终保 UTF-16 原值与原 operation，当前无真实文档 provider 时明确报告未支持。
   * 预编辑 transport 可以继续，但不能再把文档 Range 发成 preview selection 或承诺已替换。
   */
  private preview(operation: EntryImeOperation, text: string, range: inputMethod.Range): void {
    if (!this.accepts(operation)) return
    this.syncEcho(operation); const value = this.recent(text)
    if (!this.accepts(operation)) return
    const request = this.documentRequest(operation, 'Replacement', range, value)
    // Range取值/请求构造边缘可能同步退休或重开；返回对象本身不授权后面的写入或Native调用。
    if (request === undefined || !this.accepts(operation)) return
    operation.source.documentRequest = request
    if (request.outcome === 'InvalidDocumentRange') { this.publish(operation.source); return }
    // Native false/异常只有既有预编辑调用结果；不得追加文档 selection、alternate 或 retry。
    const accepted = getEntryTextInputSession().editing(operation.lease, value, this.scalars(value).length, 0)
    if (!this.accepts(operation)) return
    if (accepted) operation.source.preview = value
    this.publish(operation.source)
  }
  /** 原组合结束只清原preview；没有预编辑时不制造重复Native editing。 */
  private finishPreview(operation: EntryImeOperation): void {
    if (!this.accepts(operation)) return
    if (operation.source.preview.length > 0) getEntryTextInputSession().editing(operation.lease, '', 0, 0)
    operation.source.preview = ''; this.publish(operation.source)
  }
  /**
   * 独立文档选择只记录原 Range 与准确能力结果。echo 是有限提交历史，不能用来把未知游戏
   * 文档的 UTF-16 位置转成 Core scalar；不存在真实文档快照时不调用 selection 修改另一对象。
   */
  private documentSelection(operation: EntryImeOperation, range: inputMethod.Range): void {
    if (!this.accepts(operation)) return
    this.syncEcho(operation)
    if (!this.accepts(operation)) return
    const request = this.documentRequest(operation, 'Selection', range, '')
    if (request === undefined || !this.accepts(operation)) return
    operation.source.documentRequest = request
    this.publish(operation.source)
  }

  /**
   * 只核可证明的数值形状：有限精确整数、非负有序，或 replacement 的原 [-1,-1] 默认形状。
   * 默认值仅原样保留，不猜真实光标；文档长度/代理对边界必须由未来真实 provider 核对。
   * 每来源一个对象并使用原预编辑预算，不以范围长度分配内存或按数字发送编辑键。
   */
  private documentRequest(operation: EntryImeOperation, kind: string, range: inputMethod.Range,
    replacementText: string): EntryTextDocumentRequest | undefined {
    // 外部对象的两个字段各读取一次，每次取值后都核原operation；失效后连第二getter也不续读。
    const startUtf16: number = range.start
    if (!this.accepts(operation)) return undefined
    const endUtf16: number = range.end
    if (!this.accepts(operation)) return undefined
    const normal = Number.isSafeInteger(startUtf16) && Number.isSafeInteger(endUtf16) &&
      startUtf16 >= 0 && endUtf16 >= startUtf16
    const originalDefault = kind === 'Replacement' && startUtf16 === -1 && endUtf16 === -1
    const outcome = normal || originalDefault ? kind === 'Replacement' ?
      'DocumentReplacementUnsupported' : 'DocumentSelectionUnsupported' : 'InvalidDocumentRange'
    const request = new EntryTextDocumentRequest(operation, operation.source.echoGeneration, kind,
      startUtf16, endUtf16, replacementText, outcome)
    return this.accepts(operation) ? request : undefined
  }

  /** 固定中文能力提示不包含聊天/候选正文，也不把 composition transport 当文档修改成功。 */
  private documentMessage(outcome: string): string {
    if (outcome === 'DocumentReplacementUnsupported') return '当前游戏暂不支持替换已有文字，预编辑不会替换原文字。'
    if (outcome === 'DocumentSelectionUnsupported') return '当前游戏暂不支持选择已有文字。'
    if (outcome === 'InvalidDocumentRange') return '系统返回的文本范围无效，本次文档操作未执行。'
    return ''
  }
  /** 首个拒绝即停止按键；左删只删除实送数量的echo，hard前删不改末尾右侧空上下文。 */
  private deleteText(operation: EntryImeOperation, length: number, right: boolean): void {
    if (!Number.isFinite(length) || Math.trunc(length) !== length || length <= 0 || length > TEXT_INPUT_MAX_SCALARS) return
    if (right && operation.source.binding.role !== 'physical') return
    let delivered: number = 0
    while (delivered < length && this.accepts(operation) && this.keyTap(operation.source, operation.lease,
      right ? OHOS_FORWARD_DEL : OHOS_DEL, right ? GLFW_KEY_DELETE : GLFW_KEY_BACKSPACE)) delivered++
    if (!this.accepts(operation)) return
    if (!right) { this.syncEcho(operation); const values = this.scalars(operation.source.echo)
      operation.source.echo = this.join(values, 0, Math.max(0, values.length - delivered)); this.publish(operation.source) }
  }
  /** soft保持chat/field提交关闭，hard按NEWLINE发Enter且成功后清原echo。 */
  private functionKey(operation: EntryImeOperation): void {
    if (!this.accepts(operation)) return
    if (operation.source.binding.role !== 'physical') { this.submit(operation.source.intent); return }
    if (this.keyTap(operation.source, operation.lease, OHOS_ENTER, GLFW_KEY_ENTER)) {
      operation.source.echo = ''; this.publish(operation.source)
    }
  }
  /** IMF周边长度是UTF-16偏移；从原echo末尾取有界文本，半代理对起点向内收缩。 */
  private leftText(operation: EntryImeOperation, length: number): string {
    this.syncEcho(operation); const text = operation.source.echo
    const count = Number.isFinite(length) ? Math.max(0, Math.trunc(length)) : 0
    let start: number = Math.max(0, text.length - count)
    if (this.scalarIndex(text, start) < 0) start++
    return text.substring(start)
  }
  /** IMF光标与Range使用同一UTF-16偏移；只有进入Core selection/editing时转换为scalar。 */
  private utf16Length(operation: EntryImeOperation): number { this.syncEcho(operation); return operation.source.echo.length }

  /** 原intent对象、binding和activation共同匹配；显式hide、unbind、stop都会撤销原能力。 */
  private intentSource(intent: EntryTextInputIntent | undefined): EntryTextSource | undefined {
    if (intent === undefined) return undefined
    const source = this.source(intent.binding)
    return source !== undefined && source.wanted && source.intent === intent && source.activation === intent.activation ? source : undefined
  }

  /** UI关闭保原chat Enter/Esc、field无键；被拒也关闭，原resource通知不替代请求退休。 */
  private closeSoft(intent: EntryTextInputIntent | undefined, cancel: boolean): void {
    const source = this.intentSource(intent)
    if (source === undefined || source.binding.role === 'physical') return
    if (this.started && !this.stopped && source.binding.role === 'chat') {
      const operation = this.operation
      const lease = operation !== undefined && operation.source === source && !operation.retired ? operation.lease : undefined
      this.keyTap(source, lease, cancel ? OHOS_ESCAPE : OHOS_ENTER, cancel ? GLFW_KEY_ESCAPE : GLFW_KEY_ENTER)
      // Native调用可同步退休或重开来源；原按钮不能在返回后关闭后来activation。
      if (this.intentSource(intent) !== source) return
    }
    source.echo = ''; this.publish(source); this.request(source.binding, false)
    try { source.resource.onClose() } catch (error) { this.note('original view close failed', this.message(error)) }
  }
  /** 保既有三态合同：仅NotTypedRoute/无lease回退原source，Rejected/false不补另一副作用路线。 */
  private keyTap(source: EntryTextSource, lease: TextInputSessionLease | undefined, ohos: number, glfw: number): boolean {
    if (!this.started || this.stopped) return false
    if (lease !== undefined) {
      const result = tapEntryTextInputKey(lease, ohos, glfw)
      if (result === TextInputKeyTapResult.Submitted) return true
      if (result === TextInputKeyTapResult.Rejected) { this.counted('edit key rejected', ++this.rejectedKeys); return false }
    }
    return sendLegacyEntryKeyTap(source.binding.role === 'physical' ? AmclInputSource.PhysicalKbm : AmclInputSource.TouchControls, glfw)
  }

  /** Unicode-scalar工具共用一份；UTF-16中途边界拒绝，不把半个代理对视作选区。 */
  private scalars(text: string): number[] {
    const values: number[] = []; let offset: number = 0
    while (offset < text.length) { const value = text.codePointAt(offset) ?? 0; values.push(value); offset += value > 65535 ? 2 : 1 }
    return values
  }
  /** 从已验证scalar数组构造指定半开区间，避免UTF-16截断组合字符。 */
  private join(values: number[], start: number, end: number): string {
    let text: string = ''; for (let i = start; i < end; i++) text += String.fromCodePoint(values[i]); return text
  }
  /** 周边回声只保最近4096 scalar，不把它作为游戏真实编辑文本。 */
  private recent(text: string): string {
    const values = this.scalars(text); return this.join(values, Math.max(0, values.length - TEXT_INPUT_MAX_SCALARS), values.length)
  }
  /** 平台索引仅在整数、范围和完整UTF-16边界都合法时转换；否则返回-1。 */
  private scalarIndex(text: string, index: number): number {
    if (!Number.isFinite(index) || Math.trunc(index) !== index || index < 0 || index > text.length) return -1
    let offset: number = 0, count: number = 0
    while (offset < index) { const width = (text.codePointAt(offset) ?? 0) > 65535 ? 2 : 1
      if (offset + width > index) return -1; offset += width; count++ }
    return count
  }
  /** 保原ActivationGate角色键，来源优先权不按OS查询次数自动切换。 */
  private gateRole(source: EntryTextSource): string { return source.binding.role === 'physical' ? 'desktop-physical-ime' : source.binding.role }
  /** 投影观察与运行维护分离，观察错误不会停止controller清理或兄弟请求。 */
  private publishAll(): void { this.sources.forEach((source: EntryTextSource): void => { this.publish(source) }) }
  /** 每次构造新显示对象并隔离UI异常，不向组件暴露operation/lease的可写引用。 */
  private publish(source: EntryTextSource): void {
    const value = new EntryTextInputProjection(), operation = this.operation
    value.role = source.binding.role; value.echo = source.echo; value.preview = source.preview; value.requested = source.wanted
    value.attached = operation !== undefined && operation.source === source && this.accepts(operation)
    value.phase = value.attached ? 'Attached' : source.failedActivation ? 'Failed' : source.wanted ? 'Pending' : 'Idle'
    value.failure = source.failure || (operation?.source === source ? operation.failure : '')
    const request = source.documentRequest
    // 投影只读现有身份，不查询Native或推进controller；旧原操作/代次不能显示成后来请求的结果。
    if (request !== undefined && operation !== undefined && operation === request.operation && operation.source === source &&
        this.accepts(operation) && request.hostGeneration === source.echoGeneration) {
      value.documentOperation = request.kind; value.documentStartUtf16 = request.startUtf16
      value.documentEndUtf16 = request.endUtf16; value.documentOutcome = request.outcome
      value.documentMessage = this.documentMessage(request.outcome)
    }
    try { source.observer?.(value) } catch (error) { this.note('view projection failed', this.message(error)) }
  }
  /** SDK异常优先读message，未知异常保留可诊断字符串，不作为消费成功。 */
  private message(error: Object): string { return (error as BusinessError).message ?? String(error) }
  /** 日志只报告来源/操作事实，不打印提交文本或使用日志代替平台回执。 */
  /**
   * 只读原binding和传入的原activation，记录调用阶段，不生成callback资格或OS来源证明。
   * 关闭诊断不发日志，预算耗尽/HiLog失败不影响任何attach、清理或输入；不记文本与异常正文。
   * phase/outcome由本实现的固定词表提供，binding id和activation是已有生命周期数值。
   */
  private noteImePhase(phase: string, binding: EntryTextInputBinding,
    activation: number, outcome: string): void {
    try {
      if (!DiagnosticPolicy.inputTraceEnabled() || this.imePhaseTraceCount >= 64) return
      this.imePhaseTraceCount++
      hilog.info(0x0, TAG,
        'AMCL_IME_PHASE phase=%{public}s role=%{public}s binding=%{public}s activation=%{public}s outcome=%{public}s',
        phase, binding.role, binding.id.toString(), activation.toString(), outcome)
    } catch (_) { /* 原请求的诊断失败仅丢观察，绝不退休租约、重试平台或补发文字。 */ }
  }

  private note(reason: string, detail: string): void { hilog.warn(0x0, TAG, '%{public}s: %{public}s', reason, detail) }
  /** 错误累计第1/2/4/8次节流，持续控制字符/拒键不会按每字符刷屏。 */
  private counted(reason: string, count: number): void { if (count > 0 && (count & (count - 1)) === 0) this.note(reason, count.toString()) }
}

/**
 * entry触控发布协调器：desired、Native回执、请求呈现和UI确认分开保存。
 * 首批只在Native fence之后同时确认两层零触点再安装；didLayout只用于核实本面板几何，
 * 不代表物理屏幕送显，更不替代Minecraft菜单的present屏障。
 */
import testNapi, { ControlSchemaMsg, TouchPublicationReceipt } from 'libentry.so'
import { LayoutProfile, RuntimeTouchLayout, cloneLayout, cloneRuntimeTouchLayout, InputConfigurationProgress } from 'gamecontrol'

/** 单次候选冻结profile/几何/消息；candidateId由本控制器分配，不能用库revision代替发布身份。 */
export class TouchSurfaceCandidate {
  private identity: string = ''
  private readonly semanticKey: string
  private readonly profileValue: LayoutProfile
  private readonly layoutValue: RuntimeTouchLayout
  private readonly schemaValue: ControlSchemaMsg
  /** 能力结果随候选冻结；安全空表的安装成功不能把原不支持树改称可运行。 */
  private readonly capabilityIssueValue: string
  constructor(profile: LayoutProfile, layout: RuntimeTouchLayout, schema: ControlSchemaMsg, capabilityIssue: string = '') {
    this.profileValue = cloneLayout(profile)
    this.layoutValue = cloneRuntimeTouchLayout(layout)
    this.schemaValue = JSON.parse(JSON.stringify(schema)) as ControlSchemaMsg
    this.capabilityIssueValue = capabilityIssue
    this.semanticKey = JSON.stringify([this.layoutValue.context.key, this.profileValue.controls,
      this.profileValue.globalScale, this.profileValue.globalOpacity, this.schemaValue, this.capabilityIssueValue])
  }
  get id(): string { return this.identity }
  get key(): string { return this.semanticKey }
  /** 只读原候选的能力事实；不重新查页面profile、Native或当前资源。 */
  get capabilityIssue(): string { return this.capabilityIssueValue }
  /** 读取返回独立副本；等待/呈现期间外部草稿或UI修改都不能反写Native待发消息。 */
  get profile(): LayoutProfile { return cloneLayout(this.profileValue) }
  get layout(): RuntimeTouchLayout { return cloneRuntimeTouchLayout(this.layoutValue) }
  get schema(): ControlSchemaMsg { return JSON.parse(JSON.stringify(this.schemaValue)) as ControlSchemaMsg }
  bindIdentity(identity: string): void {
    if (this.identity.length !== 0) throw new Error('触控候选身份不能复用')
    this.identity = identity
  }
}

/** 一个在途操作；安装后只能对相同token和候选确认，迟到布局回调不能解封后来发布。 */
class TouchSurfacePublication {
  operationId: string = ''
  candidate: TouchSurfaceCandidate
  token: string = ''
  presenting: boolean = false
  constructor(candidate: TouchSurfaceCandidate) { this.candidate = candidate }
}

let nextTouchSurfaceController: number = 1

export class TouchSurfaceController {
  private readonly prefix: string = 'touch-ui-' + (nextTouchSurfaceController++).toString() + ':'
  private nextIdentity: number = 1
  private desired: TouchSurfaceCandidate | undefined = undefined
  private applied: TouchSurfaceCandidate | undefined = undefined
  /** 已结束的原安装/UI操作身份，仅证明本候选完成；不分配第二operation或复用后来ACK。 */
  private appliedOperationId: string = ''
  /** 等价请求只前移定义投递身份，仍复用原candidate/operation/token，不伪造新安装或UI确认。 */
  private completedProfileId: string = ''
  private completedProfileRevision: number = 0
  private publication: TouchSurfacePublication | undefined = undefined
  private rejectedKey: string = ''
  private active: boolean = true
  private disposed: boolean = false
  private busy: boolean = false
  private acceptedToken: string = ''
  /** 相同pending失败只报告一次；恢复后新故障可重新报告，不向每帧日志/界面刷屏。 */
  private lastFailure: string = ''
  /** 真实推进路径记录的阶段；只读status不查询Native、不数触点或推进发布。 */
  private progressStage: string = 'Waiting'
  private progressReason: string = 'NoCandidate'
  private readonly present: (candidate: TouchSurfaceCandidate, token: string) => void
  private readonly contacts: () => number
  private readonly report: (message: string) => void
  private readonly groupsChanged: (revision: string) => void

  constructor(present: (candidate: TouchSurfaceCandidate, token: string) => void,
    contacts: () => number, report: (message: string) => void,
    groupsChanged: (revision: string) => void = (_revision: string): void => {}) {
    this.present = present; this.contacts = contacts; this.report = report
    this.groupsChanged = groupsChanged
  }

  /** 所有dirty来源汇入最新desired；相同候选不创建新operation，也不反复退休owner。 */
  request(candidate: TouchSurfaceCandidate): boolean {
    if (this.disposed) return false
    if (this.desired === undefined || this.desired.key !== candidate.key) {
      // 控制器取得自己独立的冻结对象，不给外部candidate写身份；同一外部草稿可安全再次请求。
      const desired = new TouchSurfaceCandidate(candidate.profile,candidate.layout,candidate.schema,candidate.capabilityIssue)
      desired.bindIdentity(this.takeIdentity('candidate'))
      this.desired = desired; this.rejectedKey = ''
      this.progressStage = 'Waiting'; this.progressReason = 'PreparingCandidate'
    }
    this.reconcile()
    const completed: boolean = this.applied?.key === candidate.key && this.publication === undefined
    if (completed) {
      // 只在实际请求路径核完整有效值等价后采用本次定义元信息。名字/修订改变
      // 不需要重装空投影，但旧progress也不能凭页面current借成后来定义的终结。
      const definition: LayoutProfile = candidate.profile
      this.completedProfileId = definition.profileId ?? ''; this.completedProfileRevision = definition.profileRevision ?? 0
    }
    return completed
  }

  setActive(active: boolean): void { this.active = active; if (active) this.reconcile() }
  token(): string { return this.acceptedToken }
  /** publication和模态是独立门；这里仅核实UI呈现token，不改变physical/text权威。 */
  admits(token: string): boolean {
    return !this.disposed && this.active && this.publication === undefined && token.length > 0 &&
      token === this.acceptedToken && this.applied !== undefined
  }
  pending(): boolean { return this.publication !== undefined || this.applied?.key !== this.desired?.key }
  /**
   * 本控制器原候选/operation/token 的值快照，供配置域报告。targetProfile 是当前
   * 在途（或已应用）候选冻结的保存身份，desiredCandidateId 另述最新目标；二者不同
   * 时明确等待上一发布，不把旧 UI ACK 拼接到新保存修订。读取不数触点、不访问 Native。
   */
  status(): InputConfigurationProgress {
    const state: InputConfigurationProgress = new InputConfigurationProgress()
    state.operationId = this.publication?.operationId ?? ''
    state.candidateId = this.publication?.candidate.id ?? this.desired?.id ?? ''
    state.token = this.publication?.token ?? this.acceptedToken
    state.desiredCandidateId = this.desired?.id ?? ''
    const target: LayoutProfile | undefined = (this.publication?.candidate ?? this.applied ?? this.desired)?.profile
    state.targetProfileId = target?.profileId ?? ''; state.targetProfileRevision = target?.profileRevision ?? 0
    if (this.disposed) { state.stage = 'Retired'; state.reason = 'FrontendRetired'; return state }
    if (!this.active) { state.stage = 'Waiting'; state.reason = 'FrontendInactive'; return state }
    if (this.desired === undefined) { state.stage = 'Waiting'; state.reason = 'NoCandidate'; return state }
    if (this.publication !== undefined && this.publication.candidate.key !== this.desired.key) {
      state.stage = 'Waiting'; state.reason = 'PreviousPublication'; return state
    }
    if (!this.pending()) {
      // 安全禁用也必须先完成原Native安装与真实UI确认。此时终结的是定义投递，
      // 原控件能力仍Rejected；其它来源由各自owner继续采用，不能整局一并关掉。
      const completed: TouchSurfaceCandidate | undefined = this.applied
      if (completed !== undefined && completed.capabilityIssue.length > 0) {
        state.stage = 'Rejected'; state.reason = 'UnsupportedFeature'
        state.terminalRejection = true; state.completedOperationId = this.appliedOperationId
        state.completedProfileId = this.completedProfileId; state.completedProfileRevision = this.completedProfileRevision
        state.capabilityIssue = completed.capabilityIssue
      } else { state.stage = 'Applied'; state.reason = '' }
      return state
    }
    state.stage = this.progressStage; state.reason = this.progressReason
    return state
  }
  pendingPresentation(): TouchSurfaceCandidate | undefined {
    return this.publication?.presenting ? this.publication.candidate : undefined
  }
  presentationToken(): string { return this.publication?.token ?? '' }

  /**
   * 复用页面心跳恢复临时失败与丢回执；查询相同operation确认安装结果，不猜测异常意味着未安装。
   * invalid候选等待dirty产生新内容，后台停止；任何未知结果保留fence和在途身份。
   */
  reconcile(): void {
    if (this.busy || this.disposed || !this.active || this.desired === undefined) return
    if (this.publication === undefined && this.rejectedKey === this.desired.key) return
    this.busy = true
    try {
      let state: TouchPublicationReceipt = testNapi.touchPublicationState()
      if (!this.validReceipt(state)) throw new Error('触控发布状态不可用')
      // 原必要维护只追加标量通知；完整 mask 由变化/在途恢复分支按需读取。
      if (state.groupRevision !== undefined) this.groupsChanged(state.groupRevision)
      if (this.publication === undefined && this.applied?.key === this.desired.key) {
        if (!state.fenced && state.token === this.acceptedToken) return
        // Native生命周期已换代，UI库revision没变也必须重新绑定当前session/surface。
        this.applied = undefined; this.appliedOperationId = ''; this.completedProfileId = ''; this.completedProfileRevision = 0; this.acceptedToken = ''
      }
      if (this.publication === undefined) {
        const candidate: TouchSurfaceCandidate = this.desired
        const layout: RuntimeTouchLayout = candidate.layout
        if (!layout.context.valid) { this.progressStage='Waiting'; this.progressReason='ResourceUnavailable'; return }
        if (layout.context.density !== state.density || layout.context.transform !== state.transform) { this.progressStage='Waiting'; this.progressReason='ResourceChanged'; return }
        if (candidate.schema.grabbed !== state.grabbed) { this.progressStage='Waiting'; this.progressReason='GrabChanged'; return }
        const publication = new TouchSurfacePublication(candidate)
        publication.operationId = this.takeIdentity('publication')
        this.publication = publication
        state = testNapi.beginTouchPublication(publication.operationId, candidate.id,
          state.surface, state.session, state.policy, state.schemaGeneration,state.grabEpoch)
      }
      const publication: TouchSurfacePublication | undefined = this.publication
      if (publication === undefined) return
      if (!this.validReceipt(state)) throw new Error('触控发布回执格式无效')
      if (state.operationId !== publication.operationId || state.candidateId !== publication.candidate.id) {
        // 明确被其它当前发布取代时丢弃本地在途，重新基于active事实申请；旧token永不确认。
        this.publication = undefined; this.acceptedToken = ''
        this.progressStage='Waiting'; this.progressReason='PublicationChanged'; return
      }
      if (state.status === 'stale') {
        // 原surface/policy已经失效时abort不会开门；以当前事实创建新操作恢复，旧Native fence继续保护。
        this.publication = undefined; this.acceptedToken = ''
        this.progressStage='Waiting'; this.progressReason='ResourceChanged'; return
      }
      if (state.status === 'invalid') {
        this.rejectPublication(publication)
        return
      }
      if (state.status === 'unavailable') { this.progressStage='Waiting'; this.progressReason='NativeUnavailable'; return }
      if (state.status === 'waiting' || state.status === 'fenced') {
        if (!state.fenced || state.nativeTouches !== 0 || this.contacts() !== 0) {
          this.progressStage='Waiting'; this.progressReason='ContactsEnding'; return
        }
        this.progressStage='Waiting'; this.progressReason='NativeInstall'
        state = testNapi.publishTouchSchema(publication.candidate.schema, publication.operationId)
        if (!this.validReceipt(state)) throw new Error('触控安装回执不可用')
        if (state.operationId !== publication.operationId || state.candidateId !== publication.candidate.id) return
        // NAPI解析拒绝可能只返回invalid而不改Native记录，当次必须收口，不能靠下次query猜测。
        if (state.status === 'invalid') { this.rejectPublication(publication); return }
      }
      if ((state.status === 'committed' || state.status === 'unchanged') && state.token.length > 0) {
        if (!publication.presenting || publication.token !== state.token) {
          publication.token = state.token; publication.presenting = true
          this.progressStage='Waiting'; this.progressReason='UiConfirmation'
          this.present(publication.candidate, state.token)
        }
        this.lastFailure = ''
      }
    } catch (error) {
      // 下次活跃心跳先查询同一operation。保留publication确保outcomeUnknown不自动解封。
      this.progressStage='Waiting'; this.progressReason='OutcomeUnknown'
      this.noteFailure('触控发布等待恢复：' + String(error))
    } finally { this.busy = false }
  }

  /** 仅本候选节点几何在didLayout后已验证时调用；失败保持fence供后续布局/心跳重试。 */
  confirm(candidateId: string, token: string): boolean {
    const publication: TouchSurfacePublication | undefined = this.publication
    if (!this.active || this.disposed || publication === undefined || !publication.presenting ||
      publication.candidate.id !== candidateId || publication.token !== token) return false
    try {
      if (!testNapi.confirmTouchPublication(publication.operationId, token)) return false
    } catch (_) { return false }
    // 确认边缘可同步退休/替换controller；只给仍属本实例的原publication保存完成与能力。
    // desired已换B时允许A按原协议收口，下面reconcile继续B；A能力不能贴到B的回执。
    if (!this.active || this.disposed || this.publication !== publication) return false
    this.applied = publication.candidate; this.appliedOperationId = publication.operationId
    const definition: LayoutProfile = publication.candidate.profile
    this.completedProfileId = definition.profileId ?? ''; this.completedProfileRevision = definition.profileRevision ?? 0
    this.acceptedToken = token; this.publication = undefined
    this.progressStage='Applied'; this.progressReason=''
    this.reconcile()
    return true
  }

  /** 销毁只尝试退出尚未安装操作；已经安装但未呈现的fence由下一页面当前发布恢复。 */
  dispose(): void {
    this.disposed = true; this.active = false; this.acceptedToken = ''
    this.progressStage='Retired'; this.progressReason='FrontendRetired'
    const publication: TouchSurfacePublication | undefined = this.publication
    if (publication !== undefined) {
      try { testNapi.abortTouchPublication(publication.operationId) }
      catch (error) { this.noteFailure('触控页面退休等待Native确认：' + String(error)) }
    }
    this.desired = undefined; this.applied = undefined; this.appliedOperationId = ''
    this.completedProfileId = ''; this.completedProfileRevision = 0
  }

  private validReceipt(receipt: TouchPublicationReceipt): boolean {
    return receipt !== undefined && receipt.version === 1 && typeof receipt.status === 'string' &&
      typeof receipt.surface === 'string' && typeof receipt.session === 'string' &&
      typeof receipt.policy === 'string' && typeof receipt.schemaGeneration === 'string' &&
      typeof receipt.token === 'string' && typeof receipt.operationId === 'string' &&
      typeof receipt.candidateId === 'string' && typeof receipt.fenced === 'boolean' &&
      typeof receipt.grabEpoch === 'string' && typeof receipt.grabbed === 'boolean' &&
      Number.isSafeInteger(receipt.nativeTouches) && receipt.nativeTouches >= 0
  }

  /** 明确未安装的坏候选只abort一次并保留旧applied；相同坏内容等下一次dirty，不按心跳盲重试。 */
  private rejectPublication(publication: TouchSurfacePublication): void {
    this.progressStage='Rejected'; this.progressReason='CandidateInvalid'
    const result: TouchPublicationReceipt = testNapi.abortTouchPublication(publication.operationId)
    // 没有旧applied时Native明确结束未commit操作但保留安全fence；允许新dirty恢复，不能永留坏flight。
    const endedWithoutApplied: boolean = this.validReceipt(result) && result.operationId.length === 0 &&
      result.candidateId.length === 0 && result.status === 'invalid' && result.fenced && result.token === '0'
    if (this.validReceipt(result) && (!result.fenced || endedWithoutApplied)) {
      this.publication = undefined; this.rejectedKey = publication.candidate.key
      if (endedWithoutApplied) {
        this.applied = undefined; this.appliedOperationId = ''; this.completedProfileId = ''; this.completedProfileRevision = 0; this.acceptedToken = ''
      }
      this.report('触控布局未应用：Native拒绝候选，请检查布局约束')
    }
  }

  private noteFailure(message: string): void {
    if (message === this.lastFailure) return
    this.lastFailure = message
    this.report(message)
  }

  private takeIdentity(kind: string): string {
    if (this.nextIdentity >= 9007199254740991) throw new Error('触控发布身份已耗尽')
    return this.prefix + kind + '-' + (this.nextIdentity++).toString()
  }
}

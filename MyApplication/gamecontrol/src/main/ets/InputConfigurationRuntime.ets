/**
 * 游戏会话拥有的配置应用运行体。仓库先提交定义，本对象再把已确认快照应用到平台端口。
 * start/stop/reconcile 由 GameSessionHost 组织，不拥有页面、JVM、窗口或高频输入样本。
 * 首次迁移只收回 Native look 权威；触控发布和映射手柄仍有各自的真实应用回执。
 */
import { LayoutStore } from './LayoutStore'
import { LayoutProfile } from './ControlLayout'
import { InputConfigurationListener, InputConfigurationStatus, lookConfiguration,
  InputConfigurationProgress, InputPolicyActivationSnapshot, InputPolicyProjection,
  InputPolicyStatusRegistration, projectInputPolicy, inputPolicyDifference, cloneInputPolicySnapshot,
  InputConfigurationDefinitionListener } from './InputConfiguration'
import { InputConfigurationNativeBinding, InputConfigurationNativePort,
  RegisteredInputConfigurationNativePort } from './InputConfigurationNativePort'
import { LookPolicySource, sourceLookParameters } from './LookPreferences'

/** 每来源的真实确认缓存；未变值只前移本域定义修订，不重新应用Native或清尾量。 */
class SourceLookActivation {
  source: LookPolicySource
  signature: string = ''
  state: InputConfigurationStatus = new InputConfigurationStatus()
  constructor(source: LookPolicySource) { this.source = source; this.state.name = 'look-' + source }
}

export class InputConfigurationRuntime {
  private readonly port: InputConfigurationNativePort
  private store: LayoutStore | undefined = undefined
  /** 报告资源可先于仓库加载准备；没有listener时不读取默认定义或调用Native应用。 */
  private statusStore: LayoutStore | undefined = undefined
  private listener: InputConfigurationListener | undefined = undefined
  private generation: number = 0
  private nativeGeneration: number = -1
  private appliedSignature: string = ''
  private sessionId: number = 0
  private operationSequence: number = 0
  private snapshotValue: InputPolicyActivationSnapshot = new InputPolicyActivationSnapshot()
  private projection: InputPolicyProjection | undefined = undefined
  private registration: InputPolicyStatusRegistration | undefined = undefined
  private progress: InputConfigurationProgress = new InputConfigurationProgress()
  private definitionListener: InputConfigurationDefinitionListener | undefined = undefined
  private sourceLook: SourceLookActivation[] = [new SourceLookActivation('physical'),
    new SourceLookActivation('touch'), new SourceLookActivation('gamepad'), new SourceLookActivation('external')]

  /** 平台依赖显式注入；缺省借用现有进程注册，不在构造时产生Native副作用。 */
  constructor(port: InputConfigurationNativePort = new RegisteredInputConfigurationNativePort()) {
    this.port = port
  }

  /**
   * 已确认仓库就绪后挂接本局应用订阅。重复挂接同一仓库幂等；换仓库先退休旧订阅。
   * 回调捕获本次运行身份，移除后的迟到回调不能借用当前会话重新应用旧配置。
   */
  start(store: LayoutStore, sessionId: number = 0): void {
    if (this.store === store) return
    // 延迟装配沿同一原准备代使用先前provider，不能替换它丢掉早到控件的订阅。
    if (this.statusStore !== store) this.prepareStatus(store, sessionId)
    const preparation: number = this.generation
    this.store = store
    if (Number.isSafeInteger(sessionId) && sessionId > 0 && !this.bindSession(sessionId)) {
      throw new Error('Input policy preparation already belongs to another game session')
    }
    if (this.store !== store || this.generation !== preparation) {
      throw new Error('Input policy retired during session binding')
    }
    const generation: number = this.generation
    const definition: InputConfigurationDefinitionListener = (profile: LayoutProfile, revision: number, saved: boolean): void => {
      if (this.store !== store || this.generation !== generation) return
      this.captureDefinition(profile, revision, saved)
    }
    this.definitionListener = definition; store.addInputConfigurationDefinitionListener(definition)
    const listener: InputConfigurationListener = (profile: LayoutProfile, revision: number): boolean => {
      if (this.store !== store || this.generation !== generation) return false
      this.captureDefinition(profile, revision)
      return this.apply(profile, store, generation, revision)
    }
    this.listener = listener
    store.addInputConfigurationListener(listener, 'native-look', (): InputConfigurationProgress => this.progressSnapshot())
  }

  /**
   * 产品准备后、首个布局await前登记本局报告资格。只发布Preparing值，不订阅定义或
   * 应用Native；后续start沿同一generation/registration继续，控件不会错过provider。
   * 跨仓库/新代先stop，不把旧订阅自动改绑另一次会话。
   */
  prepareStatus(store: LayoutStore, sessionId: number = 0): void {
    if (this.statusStore === store) return
    this.stop()
    this.statusStore = store
    this.sessionId = Number.isSafeInteger(sessionId) && sessionId > 0 ? sessionId : 0
    this.snapshotValue = new InputPolicyActivationSnapshot()
    this.snapshotValue.generation = this.generation; this.snapshotValue.sessionId = this.sessionId
    this.snapshotValue.identityStage = 'Preparing'; this.snapshotValue.activationState = 'Preparing'
    this.registration = store.registerInputPolicyStatusProvider((): InputPolicyActivationSnapshot => this.snapshot())
  }

  /** 原Preparing代首次补实际activity；不新建operation、不重发成功域、不改绑已结束/异ID。 */
  bindSession(activityId: number): boolean {
    if (this.statusStore === undefined || !Number.isSafeInteger(activityId) || activityId <= 0) return false
    if (this.sessionId > 0 && this.sessionId !== activityId) return false
    const statusStore: LayoutStore = this.statusStore
    const generation: number = this.generation
    this.sessionId = activityId
    this.snapshotValue.sessionId = activityId
    this.notifyStatus()
    return this.statusStore === statusStore && this.generation === generation && this.sessionId === activityId
  }

  /** 停局先使旧回调失效，再取消订阅。进程端口及已占用JVM事实不归本对象释放。 */
  stop(): void {
    const store: LayoutStore | undefined = this.store
    const statusStore: LayoutStore | undefined = this.statusStore
    const listener: InputConfigurationListener | undefined = this.listener
    const registration: InputPolicyStatusRegistration | undefined = this.registration
    const definition: InputConfigurationDefinitionListener | undefined = this.definitionListener
    const retired: InputPolicyActivationSnapshot = this.snapshot()
    retired.identityStage = 'Retired'
    retired.activationState = 'Retired'
    retired.domains.forEach((state: InputConfigurationStatus): void => { state.stage = 'Retired'; state.reason = 'SessionEnded' })
    this.generation++
    this.store = undefined; this.statusStore = undefined; this.listener = undefined
    this.definitionListener = undefined
    this.registration = undefined; this.sessionId = 0; this.projection = undefined
    this.snapshotValue = retired; this.progress = new InputConfigurationProgress()
    this.appliedSignature = ''; this.nativeGeneration = -1
    this.sourceLook = [new SourceLookActivation('physical'), new SourceLookActivation('touch'),
      new SourceLookActivation('gamepad'), new SourceLookActivation('external')]
    if (store !== undefined && listener !== undefined) store.removeInputConfigurationListener(listener)
    if (store !== undefined && definition !== undefined) store.removeInputConfigurationDefinitionListener(definition)
    // 先退应用资格再观察通知。同步观察中的start/stop不能让旧续体注销后来provider。
    if (statusStore !== undefined && registration !== undefined) {
      statusStore.publishInputPolicyStatus(registration)
      statusStore.removeInputPolicyStatusProvider(registration)
    }
  }

  /**
   * 复用会话现有维护时钟；平台端口替换只失效本域回执，随后重试最新已保存定义。
   * 平台暂不可用保留 pending，不额外开高频时钟，也不回退成配置保存失败。
   */
  reconcile(): void {
    const store: LayoutStore | undefined = this.store
    if (store === undefined) return
    const generation: number = this.generation
    const registration: InputPolicyStatusRegistration | undefined = this.registration
    try {
      const binding: InputConfigurationNativeBinding = this.port.binding()
      if (this.store !== store || this.generation !== generation) return
      if (binding.generation !== this.nativeGeneration) {
        this.nativeGeneration = binding.generation
        this.sourceLook.forEach((item: SourceLookActivation): void => {
          item.state.pending = true; item.state.stage = 'Waiting'; item.state.reason = 'PortChanged'
        })
        this.appliedSignature = ''
        store.invalidateInputConfiguration('native-look')
      }
    } catch (_) {
      if (this.store !== store || this.generation !== generation) return
      this.sourceLook.forEach((item: SourceLookActivation): void => {
        item.state.pending = true; item.state.stage = 'Waiting'; item.state.reason = 'PortUnavailable'
      })
      // 无法读取当前端口资格时只能说结果待确认；不把异常解释成 Native 拒绝，
      // 也不能沿用先前端口的 Applied 让用户误以为当前资源仍然生效。
      this.progress.stage = 'Waiting'; this.progress.reason = 'StatusUnavailable'
      // 仅作废观察失败域的 delivery 回执，保留原成功值签名；端口恢复且确为同一
      // generation 时，实际 listener 可以核相同值而无需再次写 Native。
      store.invalidateInputConfiguration('native-look')
      if (registration !== undefined) store.publishInputPolicyStatus(registration)
      return
    }
    store.reconcileInputConfiguration()
  }

  /** 只读原运行代快照；读取不调用Native、不reconcile、不从后来会话补operation身份。 */
  snapshot(): InputPolicyActivationSnapshot {
    const value: InputPolicyActivationSnapshot = cloneInputPolicySnapshot(this.snapshotValue)
    if (this.store !== undefined) {
      value.sessionId = this.sessionId
      value.identityStage = this.sessionId > 0 ? 'Bound' : 'Preparing'
      // native-look是内部投递总回执；独立模式展示真正各来源applied，不把部分成功说成整组成功。
      value.domains = this.store.inputConfigurationStatus().filter((state: InputConfigurationStatus): boolean =>
        state.name !== 'native-look').concat(this.status())
      // 永久不支持的安全投影完成后是部分可用，不是永久Pending。其它独立域的
      // Applied/修订原样保留；仍在等待的资源或定义优先报告Pending，不能被终结拒绝掩盖。
      value.activationState = value.identityStage === 'Preparing' ? 'Preparing' : value.domains.length === 0 ? 'NotApplied' :
        value.domains.some((state: InputConfigurationStatus): boolean => state.pending || (state.stage !== 'Applied' && !state.terminalRejection)) ? 'Pending' :
        value.domains.some((state: InputConfigurationStatus): boolean => state.terminalRejection) ? 'PartiallyApplied' : 'Applied'
    }
    return value
  }

  /** 原 Native look 回执的深拷贝；不取得端口/资源，也不在读路径重新应用政策。 */
  private progressSnapshot(): InputConfigurationProgress {
    return JSON.parse(JSON.stringify(this.progress)) as InputConfigurationProgress
  }

  /** 新确认定义才分配本代操作；保存ID/revision与内存delivery revision分别保存。 */
  private captureDefinition(profile: LayoutProfile, revision: number, saved: boolean = false): void {
    if (revision < this.snapshotValue.definitionDeliveryRevision) return
    if (revision === this.snapshotValue.definitionDeliveryRevision) {
      if (saved) this.snapshotValue.definitionState = 'Saved'
      return
    }
    const projection: InputPolicyProjection = projectInputPolicy(profile)
    this.snapshotValue.difference = inputPolicyDifference(this.projection, projection)
    this.projection = projection
    this.snapshotValue.profileId = projection.profileId; this.snapshotValue.profileRevision = projection.profileRevision
    this.snapshotValue.look = projection.look; this.snapshotValue.definitionDeliveryRevision = revision
    this.snapshotValue.definitionState = saved ? 'Saved' : 'Confirmed'
    this.operationSequence++
    this.snapshotValue.operationId = 'configuration-' + this.generation.toString() + ':' + this.operationSequence.toString()
    this.progress.stage = 'Waiting'; this.progress.reason = 'NotApplied'
    this.progress.operationId = this.snapshotValue.operationId
    this.progress.targetProfileId = projection.profileId; this.progress.targetProfileRevision = projection.profileRevision
    if (projection.look.mode === 'IndependentSources') {
      this.sourceLook.forEach((item: SourceLookActivation): void => {
        item.state.desiredRevision = revision; item.state.desiredProfileId = projection.profileId
        item.state.desiredProfileRevision = projection.profileRevision
        item.state.operationId = this.snapshotValue.operationId
        item.state.pending = true; item.state.stage = 'Waiting'; item.state.reason = 'NotApplied'
      })
    }
  }
  /** 只通知本运行体原 Store registration；新 provider 会使旧通知失效，不重绑订阅。 */
  private notifyStatus(): void {
    if (this.statusStore !== undefined && this.registration !== undefined) this.statusStore.publishInputPolicyStatus(this.registration)
  }

  /** 只读本对象的真实应用回执；停止后无活跃订阅，不能把旧状态投射到下一局。 */
  status(): InputConfigurationStatus[] {
    if (this.store !== undefined && this.projection?.look.mode === 'IndependentSources') {
      return this.sourceLook.map((item: SourceLookActivation): InputConfigurationStatus =>
        JSON.parse(JSON.stringify(item.state)) as InputConfigurationStatus)
    }
    return this.store?.inputConfigurationStatus().filter((state: InputConfigurationStatus): boolean =>
      state.name === 'native-look') ?? []
  }

  /**
   * 保留历史完整方案的全来源look语义，成组调用一次平台端口。只有成功并且原会话与
   * 原端口仍有效时记已应用签名；同步平台回调中的stop/换端口不会让旧续体覆盖新回执。
   */
  private apply(profile: LayoutProfile, store: LayoutStore, generation: number, revision: number): boolean {
    const operation: string = this.snapshotValue.operationId
    try {
      if (revision !== this.snapshotValue.definitionDeliveryRevision) return false
      const binding: InputConfigurationNativeBinding = this.port.binding()
      if (!this.currentOperation(store, generation, operation)) return false
      if (binding.sink === null) {
        this.progress.stage = 'Waiting'; this.progress.reason = 'PortUnavailable'
        this.sourceLook.forEach((item: SourceLookActivation): void => {
          item.state.pending = true; item.state.stage = 'Waiting'; item.state.reason = 'PortUnavailable'
        })
        return false
      }
      if (profile.lookPolicies?.mode === 'independent') {
        // 单源政策互相独立；成功来源不因另一域拒绝而撤销或重复写入。内部总listener保pending，
        // 每来源的实际修订分别报告。只有旧兼容模式通过原全来源一次事务应用。
        this.appliedSignature = ''
        const applied: boolean = this.applySources(profile, store, generation, revision, operation, binding)
        if (this.currentOperation(store, generation, operation)) {
          this.progress.stage = applied ? 'Applied' : 'Waiting'; this.progress.reason = applied ? '' : 'NotApplied'
        }
        return applied
      }
      const config = lookConfiguration(profile)
      const signature: string = binding.generation.toString() + ':' + JSON.stringify(config)
      if (signature === this.appliedSignature) { this.progress.stage = 'Applied'; this.progress.reason = ''; return true }
      // 即使Native已经写入，后续端口查询仍可能异常/换代；在可能覆盖全来源的调用前
      // 先失效单源缓存。否则返回独立模式时会借旧signature跳过真实重申并虚报Applied。
      this.sourceLook.forEach((item: SourceLookActivation): void => { item.signature = '' })
      this.appliedSignature = ''
      const accepted: boolean = binding.sink.applyLookConfiguration(config)
      // Native 同步回调可以退休运行体或发布另一确认定义。旧返回值只能结束本次
      // 调用，绝不能覆盖后来 operation 的进度，即使这次 false/异常也一样。
      if (!this.currentOperation(store, generation, operation)) return false
      if (!accepted) { this.progress.stage = 'Waiting'; this.progress.reason = 'NotApplied'; return false }
      const completedBinding: InputConfigurationNativeBinding = this.port.binding()
      // 查询本身也可同步stop/start另一仓库，返回相同generation不代表原运行代仍活着。
      if (!this.currentOperation(store, generation, operation)) return false
      if (completedBinding.generation !== binding.generation) {
        this.progress.stage = 'Waiting'; this.progress.reason = 'PortChanged'; return false
      }
      this.nativeGeneration = binding.generation
      this.appliedSignature = signature
      this.progress.stage = 'Applied'; this.progress.reason = ''
      return true
    } catch (_) {
      if (this.currentOperation(store, generation, operation)) { this.progress.stage = 'Waiting'; this.progress.reason = 'NotApplied' }
      return false
    }
  }

  /** 沿原operation依次确认真正独立域，任何同步换代/换端口都会结束旧续体，不自动重绑。 */
  private applySources(profile: LayoutProfile, store: LayoutStore, generation: number, revision: number,
    operation: string, binding: InputConfigurationNativeBinding): boolean {
    const preferences = profile.lookPolicies
    if (preferences === undefined || binding.sink === null) return false
    let complete: boolean = true
    for (const item of this.sourceLook) {
      if (!this.currentOperation(store, generation, operation)) return false
      const state: InputConfigurationStatus = item.state
      state.desiredRevision = revision; state.desiredProfileId = profile.profileId ?? ''
      state.desiredProfileRevision = profile.profileRevision ?? 0
      state.targetProfileId = profile.profileId ?? ''; state.targetProfileRevision = profile.profileRevision ?? 0
      state.operationId = operation; state.pending = true; state.stage = 'Waiting'; state.reason = 'NotApplied'
      const parameters = sourceLookParameters(preferences, item.source)
      const signature: string = binding.generation.toString() + ':' + JSON.stringify(parameters)
      let accepted: boolean = signature === item.signature
      if (!accepted) {
        if (binding.sink.applySourceLookConfiguration === undefined) state.reason = 'PortUnavailable'
        else {
          // 同样不能在已写入但完成确认异常后沿用本域旧值缓存；只失效这一真实域。
          item.signature = ''
          try { accepted = binding.sink.applySourceLookConfiguration(item.source, parameters) }
          catch (_) { accepted = false }
        }
      }
      if (!this.currentOperation(store, generation, operation)) return false
      const completedBinding: InputConfigurationNativeBinding = this.port.binding()
      if (!this.currentOperation(store, generation, operation) || completedBinding.generation !== binding.generation) return false
      if (accepted) {
        item.signature = signature; state.appliedRevision = revision
        state.appliedProfileId = profile.profileId ?? ''; state.appliedProfileRevision = profile.profileRevision ?? 0
        state.pending = false; state.stage = 'Applied'; state.reason = ''
      } else { state.failures++; complete = false }
    }
    this.nativeGeneration = binding.generation
    return complete
  }

  /** 同步续体写回前只核原仓库/运行代/操作；不取得新会话身份，也不调用平台。 */
  private currentOperation(store: LayoutStore, generation: number, operation: string): boolean {
    return this.store === store && this.generation === generation && this.snapshotValue.operationId === operation
  }
}

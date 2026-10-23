/** 输入配置的语义投影与投递回执。只管理确认后的内存快照，不读Preferences，不调用NAPI或ArkUI。 */
import { AppLogger } from 'commons'
import {
  LayoutProfile, ControlItem, GamepadConfig, AlignGroup, cloneLayout, effectiveKeys,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  DEFAULT_GAMEPAD_DEAD_ZONE, DEFAULT_TRIGGER_THRESHOLD, defaultGamepadButtonMap
} from './ControlLayout'
import { normalizeTouchPreferences } from './TouchPreferences'
import { LookParameters, SourceLookPreferences, copySourceLookPreferences } from './LookPreferences'

// 运行配置与持久来源参数使用同一四标量声明；保持旧导出名供既有端口调用。
// ArkTS按名判断类型，两个形状相同的interface不能互传；别通过cast或第二份复制类型绕过。
export type LookConfiguration = LookParameters

/**
 * 旧方案四标量的显式兼容政策。历史 Native Configure(-1) 把同一参数组给所有
 * 注册来源桶及触控 gyro 内部槽；这不是新引入的全来源行为。物理相对位移历史使用
 * alpha=1，不因旧 lookSmoothing 做平滑；gyro 历史不经过触控平滑/加速，照样保留。
 * 类名保留旧导出兼容，实例同时承载两种明确的值投影：旧方案保全来源兼容政策，
 * 显式独立方案携带仓库已确认的四来源参数副本，由 projectInputPolicy 设置 mode。
 * 此处不回写旧 JSON、不执行 Native 应用，也不静默把旧手感改成仅触控；已加工
 * pending 的处理与各域真实生效回执仍由相应运行体负责，投影存在不等于已经生效。
 */
export class LegacyGlobalLookPolicy {
  mode: string = 'LegacyGlobalLookCompat'
  parameters: LookConfiguration = { sensitivity: DEFAULT_LOOK_SENSITIVITY, invertY: DEFAULT_INVERT_Y,
    smoothing: DEFAULT_LOOK_SMOOTHING, acceleration: DEFAULT_LOOK_ACCEL }
  affectedSources: string[] = ['UntaggedCompat0', 'TouchControls1', 'Gamepad2', 'PhysicalKBM3', 'TouchGyroscopeInternal']
  exceptions: string[] = ['PhysicalRelativeSmoothingAlpha1', 'GyroscopeNoTouchSmoothingOrAcceleration']
  /** 独立模式携完整来源值，报告仍是值副本；旧模式明确缺席，不静默分源。 */
  sources: SourceLookPreferences | undefined = undefined
}

/** 投影当前登记的视角、触控行为与映射手柄域；补缺省值不授予配置应用权。 */
export class InputPolicyProjection {
  profileId: string = ''
  profileRevision: number = 0
  look: LegacyGlobalLookPolicy = new LegacyGlobalLookPolicy()
  touchKey: string = ''
  gamepadKey: string = ''
}

/** 输入为仓库已确认的独立方案快照；输出补缺省的值投影，既不回写旧 JSON 也不执行应用。 */
export function projectInputPolicy(profile: LayoutProfile): InputPolicyProjection {
  const result: InputPolicyProjection = new InputPolicyProjection()
  result.profileId = profile.profileId ?? ''; result.profileRevision = profile.profileRevision ?? 0
  result.look.parameters = lookConfiguration(profile)
  result.look.sources = copySourceLookPreferences(profile.lookPolicies)
  if (result.look.sources?.mode === 'independent') result.look.mode = 'IndependentSources'
  result.touchKey = touchBehaviorKey(profile)
  const gamepad: GamepadConfig = profile.gamepad ?? {}
  result.gamepadKey = gamepadBehaviorKey({ enabled: gamepad.enabled ?? true,
    leftStick: gamepad.leftStick ?? 'move', rightStick: gamepad.rightStick ?? 'look',
    buttonMap: gamepad.buttonMap ?? defaultGamepadButtonMap(),
    stickDeadZone: gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE,
    triggerThreshold: gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD, lookScale: gamepad.lookScale ?? 1 })
  return result
}

/** 有效语义差异仅用于解释/选域，完整确认定义仍发布；反馈生存已由既有Native合同处理。 */
export class InputPolicyDifference {
  lookChanged: boolean = true
  touchChanged: boolean = true
  gamepadChanged: boolean = true
}

/** 同局前后有效行为分类。第一次登记所有已知域均需应用；反馈的完整发布另有真实回执。 */
export function inputPolicyDifference(before: InputPolicyProjection | undefined, after: InputPolicyProjection): InputPolicyDifference {
  const result: InputPolicyDifference = new InputPolicyDifference()
  if (before !== undefined) {
    result.lookChanged = JSON.stringify(before.look) !== JSON.stringify(after.look)
    result.touchChanged = before.touchKey !== after.touchKey
    result.gamepadChanged = before.gamepadKey !== after.gamepadKey
  }
  return result
}

/** 消费者纯缓存状态。Waiting/NotApplied不推断false究竟是Native拒绝还是运输暂不可用。 */
export class InputConfigurationProgress {
  stage: string = 'Waiting'
  reason: string = 'NotApplied'
  operationId: string = ''
  candidateId: string = ''
  token: string = ''
  desiredCandidateId: string = ''
  targetProfileId: string = ''
  targetProfileRevision: number = 0
  /** 安全投影已沿原operation/candidate/token完成，但原定义能力永久不支持；不是待重试。 */
  terminalRejection: boolean = false
  completedOperationId: string = ''
  completedProfileId: string = ''
  completedProfileRevision: number = 0
  capabilityIssue: string = ''
}
export type InputConfigurationProgressReader = () => InputConfigurationProgress

/** 原运行代拥有的激活报告；sessionId=0明确Preparing，不借新session补旧操作身份。 */
export class InputPolicyActivationSnapshot {
  sessionId: number = 0
  generation: number = 0
  operationId: string = ''
  identityStage: string = 'Unbound'
  profileId: string = ''
  profileRevision: number = 0
  definitionDeliveryRevision: number = 0
  definitionState: string = 'Confirmed'
  /** 从实际域回执只读归约；缺席域不能靠空数组得到“全部已应用”。 */
  activationState: string = 'NotApplied'
  look: LegacyGlobalLookPolicy = new LegacyGlobalLookPolicy()
  difference: InputPolicyDifference = new InputPolicyDifference()
  domains: InputConfigurationStatus[] = []
}
export type InputPolicyStatusListener = (snapshot: InputPolicyActivationSnapshot) => void

/** Store只转发原Runtime的值快照；不具备应用权。registration按对象身份隔离旧provider。 */
export class InputPolicyStatusRegistration {}
export class InputPolicyStatusSubscription {}

/** 观察者/Store只取得值副本，不能修改运行权威或跨域共享数组。 */
export function cloneInputPolicySnapshot(source: InputPolicyActivationSnapshot): InputPolicyActivationSnapshot {
  return JSON.parse(JSON.stringify(source)) as InputPolicyActivationSnapshot
}

/** 产品解释只读报告，不推断Native拒绝，也不把准备中的0身份说成本局已绑定生效。 */
export function inputPolicyStatusMessage(snapshot: InputPolicyActivationSnapshot): string {
  if (snapshot.profileId.length === 0) return ''
  const prefix: string = snapshot.definitionState === 'Saved' ? '方案已保存' : '当前方案已确认'
  if (snapshot.identityStage === 'Retired') return prefix + '；本局输入运行已结束'
  if (snapshot.identityStage === 'Preparing') return prefix + '；等待游戏会话身份确认'
  if (snapshot.domains.length === 0) return prefix + '，待生效；等待输入域登记'
  const waiting: string[] = []
  const disabled: string[] = []
  for (const state of snapshot.domains) {
    if (!state.pending && state.stage === 'Applied') continue
    const name: string = state.name === 'native-look' ? '视角设置（旧方案兼容）' :
      state.name === 'look-physical' ? '物理鼠标视角' : state.name === 'look-touch' ? '触控与陀螺仪视角' :
      state.name === 'look-gamepad' ? '映射手柄视角' : state.name === 'look-external' ? '外部兼容视角' :
      state.name === 'touch-controls' ? '触控布局' : state.name === 'touch-gyro' ? '陀螺仪' :
      state.name === 'mapped-gamepad' ? '手柄映射' : state.name
    // terminalRejection只能由原完成元组确认；永久不支持应解释安全禁用，不能显示待生效或Applied。
    if (!state.pending && state.stage === 'Rejected' && state.terminalRejection) {
      disabled.push(name + '：方案功能不支持，已安全禁用')
      continue
    }
    // gyro的原平台订阅和Native子流是两个独立清理资源。只解释真实缓存原因，
    // 不将等待文字改成Applied，也不在状态读取中调用sensor或重试原token。
    const reason: string = state.reason === 'ContactsEnding' ? '等待旧接触结束' :
      state.reason === 'NativeInstall' ? '等待输入端安装确认' : state.reason === 'UiConfirmation' ? '等待页面布局确认' :
      state.reason === 'PreviousPublication' ? '等待上一布局操作结束' :
      state.reason === 'CandidateInvalid' ? '候选配置未被接受' : state.reason === 'NativeUnavailable' || state.reason === 'PortUnavailable' ? '端口暂不可用' :
      state.reason === 'ResourceChanged' || state.reason === 'ResourceUnavailable' ? '等待有效窗口资源' :
      state.reason === 'FrontendInactive' ? '等待前端恢复' : state.reason === 'FrontendRetired' ? '前端已退休' :
      state.name === 'touch-gyro' && state.reason === 'unsubscribe-pending' ? '等待原传感器订阅关闭确认' :
      state.name === 'touch-gyro' && state.reason === 'retirement-pending' ? '等待原陀螺仪输入流结束确认' :
      state.name === 'touch-gyro' && state.reason === 'unavailable' ? '传感器或输入端暂不可用' :
      state.name === 'touch-gyro' && state.reason === 'pending' ? '等待有效陀螺仪输入资源' :
      state.name === 'touch-gyro' && state.reason === 'InputNotAdmitted' ? '当前未开放陀螺仪输入，等待游戏准入恢复' :
      state.name === 'touch-gyro' && state.reason === 'SourceInactive' ? '等待游戏前台与来源恢复' :
      state.name === 'touch-gyro' && state.reason === 'NativeVisualUnavailable' ? '等待输入状态确认' :
      state.name === 'touch-gyro' && state.reason === 'OutcomeUnknown' ? '陀螺仪采用结果待确认' :
      state.name === 'touch-gyro' && state.reason === 'retired' ? '原陀螺仪输入流已结束，等待重新确认' : '尚未应用，等待确认'
    waiting.push(name + '：' + reason)
  }
  if (waiting.length === 0) return disabled.length === 0 ? prefix + '；当前已登记输入域已生效' : prefix + '；' + disabled.join('；')
  return prefix + '，待生效；' + waiting.concat(disabled).join('；')
}

export function lookConfiguration(profile: LayoutProfile): LookConfiguration {
  if (profile.lookPolicies !== undefined) return {
    sensitivity: profile.lookPolicies.legacy.sensitivity, invertY: profile.lookPolicies.legacy.invertY,
    smoothing: profile.lookPolicies.legacy.smoothing, acceleration: profile.lookPolicies.legacy.acceleration
  }
  return {
    sensitivity: profile.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY,
    invertY: profile.invertY ?? DEFAULT_INVERT_Y,
    smoothing: profile.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING,
    acceleration: profile.lookAccel ?? DEFAULT_LOOK_ACCEL
  }
}

/** 仅保留会改变命中/触发/输入输出的字段。反馈开关、文字、颜色和编辑偏好不退休持有。 */
function controlBehaviorKey(control: ControlItem): string {
  const fields: string[] = [control.id, String(control.type), String(control.xPct), String(control.yPct),
    String(control.baseWidth), String(control.baseHeight), String(control.itemScale ?? 1),
    String(control.alignGroup ?? AlignGroup.NONE), String(control.alignIndex ?? 0),
    String(control.hidden ?? false), String(control.grabbedOnly ?? false), String(control.menuOnly ?? false),
    control.visibilityOverride ?? 'auto', control.systemAction ?? '', control.trigger ?? 'press',
    String(control.dragLook ?? false), control.swipeGroup ?? '', JSON.stringify(effectiveKeys(control)),
    control.controlGroupId ?? '', JSON.stringify(control.groupActions ?? []),
    JSON.stringify(control.phaseBindings ?? []), control.gesturePolicy ?? 'amcl']
  const children: ControlItem[] = control.children ?? []
  for (let i = 0; i < children.length; i++) fields.push(controlBehaviorKey(children[i]))
  return JSON.stringify(fields)
}

export function touchBehaviorKey(profile: LayoutProfile): string {
  // 本键只用于输入行为分类；完整配置/Native表仍单独比较haptic并真实安装新反馈，
  // 不能用输入等价性短路整个定义发布，导致后来触点永远读取旧开关。
  const fields: string[] = [String(profile.globalScale), String(profile.joystickDeadZone ?? 0.18),
    JSON.stringify(normalizeTouchPreferences(profile.touch))]
  // 组名仅用于编辑展示；次序、身份、初始态与能力会改变解释结果，必须进入行为签名。
  for (const group of profile.controlGroups ?? []) fields.push(JSON.stringify([group.id, group.initialVisible]))
  for (let i = 0; i < profile.controls.length; i++) fields.push(controlBehaviorKey(profile.controls[i]))
  return JSON.stringify(fields)
}

/** 调用方先归一化缺省值；映射表按名字排序，导入JSON的属性顺序不构成改键。 */
export function gamepadBehaviorKey(config: GamepadConfig): string {
  const fields: string[] = [String(config.enabled ?? true), config.leftStick ?? 'move', config.rightStick ?? 'look',
    String(config.stickDeadZone), String(config.triggerThreshold), String(config.lookScale)]
  if (config.buttonMap !== undefined) {
    const names: string[] = Object.keys(config.buttonMap).sort()
    for (let i = 0; i < names.length; i++) {
      const action = config.buttonMap[names[i]]
      fields.push(JSON.stringify([names[i], action.kind, String(action.code ?? 0)]))
    }
  }
  return JSON.stringify(fields)
}

/** true/void表示本域已应用；false或异常保留待应用，下次reconcile重试，不重发已成功域。 */
export type InputConfigurationListener = (profile: LayoutProfile, revision: number) => boolean | void
/** 已确认定义事件只传身份/值，不授予应用权；运行体据此在消费者回调前冻结operation。 */
export type InputConfigurationDefinitionListener = (profile: LayoutProfile, revision: number, saved: boolean) => void

export class InputConfigurationStatus {
  name: string = ''
  desiredRevision: number = 0
  appliedRevision: number = 0
  failures: number = 0
  pending: boolean = false
  stage: string = 'Waiting'
  reason: string = 'NotApplied'
  operationId: string = ''
  candidateId: string = ''
  token: string = ''
  desiredCandidateId: string = ''
  targetProfileId: string = ''
  targetProfileRevision: number = 0
  desiredProfileId: string = ''
  desiredProfileRevision: number = 0
  appliedProfileId: string = ''
  appliedProfileRevision: number = 0
  /** 原listener完成且能力Rejected时，投递可终结但不能冒称该原定义已经采用。 */
  terminalRejection: boolean = false
  completedOperationId: string = ''
  completedProfileId: string = ''
  completedProfileRevision: number = 0
  capabilityIssue: string = ''
}

/** 单个具名消费者的真实 delivery 回执；缓存 reader 不拥有应用权，已应用身份不会借 desired 替换。 */
class ConfigurationSubscriber {
  name: string = ''
  listener: InputConfigurationListener = (_profile: LayoutProfile, _revision: number): boolean => false
  applied: number = 0
  failures: number = 0
  progress: InputConfigurationProgressReader | undefined = undefined
  appliedProfileId: string = ''
  appliedProfileRevision: number = 0
}

/** 同一UI线程使用。回调期间新发布只更新desired，避免递归应用后旧续体覆盖新版本。 */
export class InputConfigurationDelivery {
  private signature: string = ''
  private profile: LayoutProfile | undefined = undefined
  private revision: number = 0
  private applying: boolean = false
  private subscribers: ConfigurationSubscriber[] = []
  private definitions: InputConfigurationDefinitionListener[] = []
  private saved: boolean = false

  /** 接受完整已确认定义，saved 仅由仓库确认提交后传 true；订阅失败不撤销定义。 */
  publish(profile: LayoutProfile, saved: boolean = false): void {
    const signature: string = JSON.stringify(profile)
    if (signature !== this.signature) {
      this.signature = signature
      this.profile = cloneLayout(profile)
      this.revision++
      this.saved = saved
      // 定义观察可同步触发另一确认发布；每次通知仍绑定本次 profile/revision，
      // 不能向后续 listener 拼接旧值与后来修订。运行体会拒绝已经迟到的旧修订。
      const revision: number = this.revision
      for (const listener of this.definitions.slice()) {
        if (this.definitions.indexOf(listener) < 0) continue
        try { listener(cloneLayout(profile), revision, saved) }
        catch (_) { /* 定义观察失败不回滚确认存储；继续其它原 listener，不伪造 Applied。 */ continue }
      }
      if (this.signature !== signature) return
    }
    if (saved && !this.saved) {
      this.saved = true
      const revision: number = this.revision
      for (const listener of this.definitions.slice()) {
        if (this.definitions.indexOf(listener) < 0) continue
        try { listener(cloneLayout(profile), revision, true) }
        catch (_) { /* 仅更新真实保存事实；观察失败不改结果，继续其它原 listener。 */ continue }
      }
      if (this.signature !== signature) return
    }
    this.reconcile()
  }

  /** 登记定义观察并回放当前确认值；观察先于应用，用于冻结原 operation，不取得应用资格。 */
  addDefinitionListener(listener: InputConfigurationDefinitionListener): void {
    if (this.definitions.indexOf(listener) >= 0) return
    this.definitions.push(listener)
    if (this.profile !== undefined) listener(cloneLayout(this.profile), this.revision, this.saved)
  }
  /** 按原闭包身份退休观察，已捕获的迟到回调由运行体 generation 再拒绝。 */
  removeDefinitionListener(listener: InputConfigurationDefinitionListener): void {
    this.definitions = this.definitions.filter((entry: InputConfigurationDefinitionListener): boolean => entry !== listener)
  }

  /** 具名消费者仍以真实 listener 返回值确认定义；可选 progress 只细化原消费者的等待原因。 */
  add(name: string, listener: InputConfigurationListener, progress?: InputConfigurationProgressReader): void {
    if (this.subscribers.some((item: ConfigurationSubscriber): boolean => item.listener === listener)) return
    const subscriber = new ConfigurationSubscriber()
    subscriber.name = name
    subscriber.listener = listener
    subscriber.progress = progress
    this.subscribers.push(subscriber)
    this.reconcile()
  }

  remove(listener: InputConfigurationListener): void {
    this.subscribers = this.subscribers.filter((item: ConfigurationSubscriber): boolean => item.listener !== listener)
  }

  invalidate(name: string): void {
    this.subscribers.forEach((item: ConfigurationSubscriber): void => { if (item.name === name) item.applied = 0 })
  }

  reconcile(): void {
    if (this.applying || this.profile === undefined) return
    this.applying = true
    const revision: number = this.revision
    const profile: LayoutProfile = this.profile
    const subscribers: ConfigurationSubscriber[] = this.subscribers.slice()
    try {
      for (let i = 0; i < subscribers.length; i++) {
        // 新定义已经到达时结束旧轮投递；已完成的旧回执保留其旧 revision，
        // 后续维护再应用最新定义，不继续把旧值交给尚未执行的其它域。
        if (this.revision !== revision) break
        const item: ConfigurationSubscriber = subscribers[i]
        if (item.applied === revision || this.subscribers.indexOf(item) < 0) continue
        let applied: boolean = false
        try { applied = item.listener(cloneLayout(profile), revision) !== false } catch (_) { applied = false }
        if (applied) { item.applied = revision; item.appliedProfileId = profile.profileId ?? ''; item.appliedProfileRevision = profile.profileRevision ?? 0 }
        else {
          item.failures++
          if ((item.failures & (item.failures - 1)) === 0) {
            try { AppLogger.warn('InputConfiguration', `配置待重试 domain=${item.name} revision=${revision} failures=${item.failures}`) }
            catch (_) { /* 日志只是观察；失败后继续下一域，不改变确认保存和本域 pending。 */ continue }
          }
        }
      }
    } finally { this.applying = false }
  }

  /** 返回值副本，读 progress 缓存但不重试 listener；旧 Applied 缓存不能盖掉新 delivery 的 pending。 */
  status(): InputConfigurationStatus[] {
    const states: InputConfigurationStatus[] = []
    this.subscribers.forEach((item: ConfigurationSubscriber): void => {
      const state = new InputConfigurationStatus()
      state.name = item.name
      state.desiredRevision = this.revision
      state.appliedRevision = item.applied
      state.failures = item.failures
      state.pending = item.applied !== this.revision
      state.desiredProfileId = this.profile?.profileId ?? ''; state.desiredProfileRevision = this.profile?.profileRevision ?? 0
      state.appliedProfileId = item.appliedProfileId; state.appliedProfileRevision = item.appliedProfileRevision
      state.stage = state.pending ? 'Waiting' : 'Applied'
      state.reason = state.pending ? 'NotApplied' : ''
      // reader只能观察其原消费者缓存，不能reconcile/查询推进Native。异常不伪造Rejected。
      if (item.progress !== undefined) {
        try {
          const progress: InputConfigurationProgress = item.progress()
          state.stage = progress.stage; state.reason = progress.reason
          state.operationId = progress.operationId; state.candidateId = progress.candidateId; state.token = progress.token
          state.desiredCandidateId = progress.desiredCandidateId
          state.targetProfileId = progress.targetProfileId; state.targetProfileRevision = progress.targetProfileRevision
          // 缓存 Applied 只能解释已确认的 delivery；false 尚未应用的新定义不能
          // 借旧候选/旧有效值的 Applied 缓存变成成功。
          if (state.pending && progress.stage === 'Applied') { state.stage = 'Waiting'; state.reason = 'NotApplied' }
          if (progress.stage !== 'Applied') {
            // safe-disabled不是Native拒绝安装。只有listener已完成当前定义，且原
            // completion精确对上当前profile/candidate/token，才能终结永久不支持。
            // 旧进度/旧候选不能借后来delivery的完成值给新定义盖终结章。
            const terminal: boolean = !state.pending && progress.stage === 'Rejected' && progress.terminalRejection &&
              progress.reason === 'UnsupportedFeature' && progress.capabilityIssue.startsWith('UnsupportedFeature:') &&
              progress.completedOperationId.length > 0 && progress.candidateId.length > 0 &&
              progress.candidateId === progress.desiredCandidateId && progress.token.length > 0 && progress.token !== '0' &&
              progress.completedProfileId.length > 0 && Number.isSafeInteger(progress.completedProfileRevision) && progress.completedProfileRevision > 0 &&
              progress.completedProfileId === state.desiredProfileId && progress.completedProfileRevision === state.desiredProfileRevision
            if (terminal) {
              state.terminalRejection = true; state.completedOperationId = progress.completedOperationId
              state.completedProfileId = progress.completedProfileId; state.completedProfileRevision = progress.completedProfileRevision
              state.capabilityIssue = progress.capabilityIssue
              state.appliedRevision = 0; state.appliedProfileId = ''; state.appliedProfileRevision = 0
            } else {
              state.pending = true
              if (progress.terminalRejection) { state.stage = 'Waiting'; state.reason = 'PreviousPublication' }
            }
          }
        } catch (_) { state.stage = 'Waiting'; state.reason = 'StatusUnavailable'; state.pending = true }
      }
      states.push(state)
    })
    return states
  }
}

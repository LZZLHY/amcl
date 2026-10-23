/**
 * 受控Want到当前触控组件的窄接线。登记只保存原Host/appearance及一个操作闭包，
 * 不拥有Source、输入配置、维护时钟或持久状态；desktop依赖本文件也不会加载移动组件。
 * 对象身份就是登记资格，旧组件退休不会清掉后来组件，新Host也不能借旧登记操作。
 */
import { GameSessionHost } from '../runtime/GameSessionHost'

/** 固定结果字段只陈述原观察及必要维护事实，不包含文本、账号、路径或游戏内容。 */
export class EntryInputObservationResult {
  outcome: string = 'FrontendUnavailable'
  /** 只有原Host/原组件操作前后均有效才为true；不可用结果的默认字段不能作为状态事实。 */
  qualified: boolean = false
  activity: number = 0
  appearance: number = 0
  enabled: boolean = true
  visualSubscribed: boolean = false
  feedbackLease: number = 0
  feedbackClearComplete: boolean = true
  buttonBaseline: string = 'UnknownUntilNextEdge'
  sourceCurrent: boolean = false
  timerActive: boolean = false
  guiSubscribed: boolean = false
  geometrySubscribed: boolean = false
  guiReads: number = 0
  geometryDeliveries: number = 0
  visualDeliveries: number = 0
  gyroStatus: string = ''
  pageActive: boolean = false
  schemaActive: boolean = false
  publicationToken: string = ''
  /** 这三个诊断由各自原机制管理，本操作从不改变它们。 */
  graphics: string = 'Independent'
  shadow: string = 'Independent'
  trace: string = 'Independent'
}

/** 登记资格仅在本进程按原对象比较，不替代Native资源ID，不作为全局revision。 */
export class EntryInputObservationRegistration {
  /** 四个创建时事实沿原对象/值保存；readonly不允许后来登记重贴新Host或活动资格。 */
  readonly host: GameSessionHost
  readonly activity: number
  readonly appearance: number
  readonly operate: (action: string) => EntryInputObservationResult | undefined
  /**
   * ArkTS要求字段在类体显式声明，不能使用TypeScript的构造参数属性简写。
   * 这里只赋入原四参数，不查询Host、不调用操作闭包、不获取任何新Source或维护时钟。
   */
  constructor(host: GameSessionHost, activity: number, appearance: number,
    operate: (action: string) => EntryInputObservationResult | undefined) {
    this.host=host
    this.activity=activity
    this.appearance=appearance
    this.operate=operate
  }
}
let current: EntryInputObservationRegistration | undefined = undefined

/**
 * 真实组件挂接后登记原活动，允许原Host尚在正常启动准备期；GC可早于runLaunch出现。
 * 登记本身不授予操作/启动资格，实际operate仍要求原Host已运行。结束墓碑禁止登记。
 */
export function registerEntryInputObservation(host: GameSessionHost, appearance: number,
  operate: (action: string) => EntryInputObservationResult | undefined): EntryInputObservationRegistration | undefined {
  const activity: number=host.sessionActivity()
  if (host.isEnded() || !Number.isSafeInteger(activity) || activity<=0 || appearance<=0) return undefined
  const registration: EntryInputObservationRegistration=new EntryInputObservationRegistration(host,activity,appearance,operate)
  current=registration
  return registration
}

/** 先撤登记再释放组件资源；旧dispose不能注销另一实例的登记。 */
export function unregisterEntryInputObservation(registration: EntryInputObservationRegistration | undefined): void {
  if (registration!==undefined && current===registration) current=undefined
}

/** 验证原Host/活动前后都成立；回入退休或换登记得到失权收据，不能返回后来页面的状态。 */
export function operateEntryInputObservation(activity: number, action: string): EntryInputObservationResult {
  const registration: EntryInputObservationRegistration | undefined=current
  const unavailable: EntryInputObservationResult=new EntryInputObservationResult()
  unavailable.activity=activity
  if (action!=='off' && action!=='on' && action!=='read') { unavailable.outcome='UnsupportedAction'; return unavailable }
  if (registration===undefined || registration.activity!==activity) return unavailable
  // 只用本登记捕获的原Host。缺页面时不调用工厂getter，不能新建Created宿主来“读取”。
  const host: GameSessionHost=registration.host
  if (!host.isRunning() || host.sessionActivity()!==activity || current!==registration) return unavailable
  const result: EntryInputObservationResult | undefined=registration.operate(action)
  if (result===undefined || current!==registration || !host.isRunning() || host.sessionActivity()!==activity || current!==registration) {
    unavailable.outcome='FrontendRetired'; return unavailable
  }
  result.qualified=true
  return result
}

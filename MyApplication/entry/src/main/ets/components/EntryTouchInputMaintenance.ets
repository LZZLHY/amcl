/**
 * 游戏会话的Native输入维护scope及来源登记。此模块只借用Native维护和平台日志端口，
 * 不依赖触控前端、布局、视觉投影或传感器；纯实体输入产品也可以拥有同一会话维护合同。
 * 来源以受限stopSources接口登记，具体的16ms时钟和gyro仍由其自身运行体管理。
 */
import testNapi from 'libentry.so'
import { hilog } from '@kit.PerformanceAnalysisKit'

/** 身份按对象同一性比较；generation只作诊断，不冒充Native session/Surface/触点代次。 */
export class EntryTouchInputMaintenanceLease {
  readonly generation: number
  constructor(generation: number) { this.generation = generation }
}

/** 宿主只取得停源能力，不持有来源页面、布局对象、传感器API或运动样本处理方法。 */
export interface EntryTouchInputMaintenanceSource {
  stopSources(): boolean
  /** 只清理已失权原资源；不能在此开启采样、读current或重建来源。 */
  reconcileStoppedSources(): boolean
}

let maintenanceGeneration: number = 0
let maintenanceLease: EntryTouchInputMaintenanceLease | undefined = undefined
const maintenanceSources: Set<EntryTouchInputMaintenanceSource> = new Set<EntryTouchInputMaintenanceSource>()
// 第一次合法登记冻结Source构造域。弱键不延长来源寿命，不创建资源owner；
// 旧scope同对象即使已解绑，也不得登记到后来scope供旧stop/receipt误停或误签。
const maintenanceSourceOrigins: WeakMap<EntryTouchInputMaintenanceSource,EntryTouchInputMaintenanceLease> =
  new WeakMap<EntryTouchInputMaintenanceSource,EntryTouchInputMaintenanceLease>()
const MAX_MAINTENANCE_SOURCES: number = 16

/** 单局宿主在来源挂接前取得唯一scope；重复创建另一个活跃所有者明确拒绝。 */
export function startEntryTouchInputMaintenance(): EntryTouchInputMaintenanceLease {
  if (maintenanceLease !== undefined) throw new Error('输入生产维护已由另一活跃游戏会话拥有')
  if (maintenanceGeneration >= 9007199254740991) throw new Error('输入生产维护身份已耗尽')
  const lease = new EntryTouchInputMaintenanceLease(++maintenanceGeneration)
  maintenanceLease = lease
  return lease
}

/** 来源构造时冻结原scope；本读取没有副作用，后续异步start只验证原句柄，不重新capture。 */
export function captureEntryTouchInputMaintenanceScope(): EntryTouchInputMaintenanceLease | undefined {
  return maintenanceLease
}

/** 只读身份核验；undefined、伪造同generation对象和已退休scope均不能取得当前资格。 */
export function isEntryTouchInputMaintenanceCurrent(lease: EntryTouchInputMaintenanceLease | undefined): boolean {
  return lease !== undefined && maintenanceLease === lease
}

/**
 * 挂接必须携带构造时取得的原scope。同一来源重复登记幂等，容量只限制新来源；
 * false表示旧scope或容量压力，调用方须保持自己的时钟/传感器关闭，不借current改绑。
 */
export function registerEntryTouchInputMaintenanceSource(lease: EntryTouchInputMaintenanceLease,
  source: EntryTouchInputMaintenanceSource): boolean {
  if (!isEntryTouchInputMaintenanceCurrent(lease)) return false
  const original: EntryTouchInputMaintenanceLease | undefined=maintenanceSourceOrigins.get(source)
  if (original!==undefined && original!==lease) return false
  if (maintenanceSources.has(source)) return true
  if (maintenanceSources.size >= MAX_MAINTENANCE_SOURCES) return false
  maintenanceSourceOrigins.set(source,lease)
  maintenanceSources.add(source)
  return true
}

/** 只撤原scope的登记；旧stop续体不能删除后来scope的新对象，旧对象也不能跨域重挂。 */
export function unregisterEntryTouchInputMaintenanceSource(lease: EntryTouchInputMaintenanceLease,
  source: EntryTouchInputMaintenanceSource): void {
  if (isEntryTouchInputMaintenanceCurrent(lease)) maintenanceSources.delete(source)
}

/** 无前端也能显式推进必要Native维护；旧宿主与未绑定调用一律无输出。 */
export function reconcileEntryTouchInputMaintenance(lease: EntryTouchInputMaintenanceLease): boolean {
  if (!isEntryTouchInputMaintenanceCurrent(lease)) return false
  try {
    return typeof testNapi.maintainTouchInput === 'function' && testNapi.maintainTouchInput()
  } catch (_) { return false }
}

/** 原scope退休回执，最多保留原16个Source与其中待退callback/token，不是新来源owner。 */
export class EntryTouchInputMaintenanceStopReceipt {
  readonly generation: number
  private pending: EntryTouchInputMaintenanceSource[]
  private failed: boolean
  private reconciling: boolean=false
  constructor(generation: number,pending: EntryTouchInputMaintenanceSource[],failed: boolean) {
    this.generation=generation; this.pending=pending; this.failed=failed
  }
  /** 原资源全部确认且过程中没有未知异常才算完成；检查本身没有清理副作用。 */
  complete(): boolean { return !this.reconciling && !this.failed && this.pending.length===0 }
  /** 是否仍有原资源可继续清理；失败历史与等待状态分别表达，不能互相覆盖。 */
  waiting(): boolean { return this.reconciling || this.pending.length>0 }
  /** 冻结原对象逐项重试；回入不递归，后来scope不会进入旧回执。异常不伪改成功。 */
  reconcile(): boolean {
    if (this.reconciling) return false
    this.reconciling=true
    const originals: EntryTouchInputMaintenanceSource[]=this.pending
    this.pending=[]
    try {
      for (const source of originals) {
        try { if (!source.reconcileStoppedSources()) this.pending.push(source) }
        catch (_) { this.failed=true; this.pending.push(source) }
      }
    } finally { this.reconciling=false }
    return this.complete()
  }
}

/** 仅原Host 250ms调用，收回仍登记但inactive的原资源；不加入16ms热维护。 */
export function reconcileEntryTouchInputMaintenanceCleanup(lease: EntryTouchInputMaintenanceLease): boolean {
  if (!isEntryTouchInputMaintenanceCurrent(lease)) return false
  const originals: EntryTouchInputMaintenanceSource[]=[]
  maintenanceSources.forEach((source: EntryTouchInputMaintenanceSource): void => { originals.push(source) })
  let complete: boolean=true
  for (const source of originals) {
    if (!isEntryTouchInputMaintenanceCurrent(lease)) return false
    try { if (!source.reconcileStoppedSources()) complete=false } catch (_) { complete=false }
    if (!isEntryTouchInputMaintenanceCurrent(lease)) return false
  }
  return complete
}

/** 停局先撤scope/登记，再停止各源；保原pending/失败句柄，日志失败不跳兄弟。 */
export function stopEntryTouchInputMaintenance(lease: EntryTouchInputMaintenanceLease): EntryTouchInputMaintenanceStopReceipt | undefined {
  if (!isEntryTouchInputMaintenanceCurrent(lease)) return undefined
  maintenanceLease = undefined
  const sources: EntryTouchInputMaintenanceSource[] = []
  maintenanceSources.forEach((source: EntryTouchInputMaintenanceSource): void => { sources.push(source) })
  maintenanceSources.clear()
  const pending: EntryTouchInputMaintenanceSource[]=[]
  let failed: boolean=false
  for (const source of sources) {
    try { if (source.stopSources()!==true) pending.push(source) }
    catch (error) {
      failed=true; pending.push(source)
      try { hilog.warn(0x0000,'InputSession','输入来源维护清理失败：%{public}s',String(error)) }
      catch (_) {
        // 清理日志只是观察。日志端口失效不能夺走后续来源的停止机会；scope和登记集合
        // 已经退休，直接继续清理下一来源，不再调用可能重复失败的日志兜底或恢复旧scope。
        continue
      }
    }
  }
  return new EntryTouchInputMaintenanceStopReceipt(lease.generation,pending,failed)
}

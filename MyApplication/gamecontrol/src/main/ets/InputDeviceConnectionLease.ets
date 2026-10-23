/**
 * 仅应用入口已经观察到的设备连接寿命。Monitor拥有这一表，Native/Core仍是实际输入权威。
 * applicationScope是不可复用的应用贡献命名空间，既不是platform generation，也不是look流号。
 * 缺少系统代的旧OS事实首次迟到仍未证；本类不以raw ID相同、metadata成功或clock比较填洞。
 */

/** 原字段证据；known0与missing0分开，兼容降级必须由调用者明确请求。 */
export class InputDeviceIdentityEvidence {
  readonly rawPlatformId: number
  readonly idKnown: boolean
  readonly compatibility: boolean
  constructor(rawPlatformId: number, idKnown: boolean, compatibility: boolean) {
    this.rawPlatformId = rawPlatformId; this.idKnown = idKnown; this.compatibility = compatibility
  }
}

/** 每个应用连接的精确原对象；复制相同字段不能通过Registry reader的对象核验。 */
export class InputDeviceConnectionLease {
  readonly rawPlatformId: number
  readonly idKnown: boolean
  readonly compatibility: boolean
  readonly applicationScope: number
  constructor(identity: InputDeviceIdentityEvidence, applicationScope: number) {
    this.rawPlatformId = identity.rawPlatformId; this.idKnown = identity.idKnown
    this.compatibility = identity.compatibility; this.applicationScope = applicationScope
  }
}

/** 纯只读准入端口。允许现device字段不等于Native已应用、consumer Ready或游戏采纳。 */
export interface InputDeviceConnectionReader {
  accepts: (connection: InputDeviceConnectionLease) => boolean
  allowsLegacyDeviceField: (connection: InputDeviceConnectionLease) => boolean
}

/** 一次原inventory请求身份；任何实时变更都令其整批过期，不把后来的连接补进旧快照。 */
export class InputDeviceInventoryTicket {
  readonly revision: number
  readonly request: number
  constructor(revision: number, request: number) { this.revision = revision; this.request = request }
}

/** 原实时边沿快照；移除发布已fence的原lease，后续cleanup不需要lookup新sameid。 */
export class InputDeviceConnectionChange {
  readonly rawPlatformId: number
  readonly added: boolean
  readonly originalConnection: InputDeviceConnectionLease | undefined
  constructor(rawPlatformId: number, added: boolean, originalConnection: InputDeviceConnectionLease | undefined) {
    this.rawPlatformId = rawPlatformId; this.added = added; this.originalConnection = originalConnection
  }
}

/** 结果保持显式Pending/Invalid/Exhausted，不把失效hardware或数值错误自动当兼容0。 */
export class InputDeviceConnectionCapture {
  readonly status: string
  readonly connection: InputDeviceConnectionLease | undefined
  constructor(status: string, connection: InputDeviceConnectionLease | undefined = undefined) {
    this.status = status; this.connection = connection
  }
}

// 整模块进程命名空间：测试创建两Registry也不生成同scope；MAX最后一次用完后永久耗尽。
let nextApplicationScope: number = 1

export class InputDeviceConnectionRegistry {
  private current: Map<number, InputDeviceConnectionLease> = new Map<number, InputDeviceConnectionLease>()
  private removed: Set<number> = new Set<number>()
  private compatibilityConnection: InputDeviceConnectionLease | undefined = undefined
  private revision: number = 0
  private nextRequest: number = 1
  private latestInventory: InputDeviceInventoryTicket | undefined = undefined
  private publicationExhausted: boolean = false
  readonly reader: InputDeviceConnectionReader = {
    accepts: (connection: InputDeviceConnectionLease): boolean => this.accepts(connection),
    allowsLegacyDeviceField: (connection: InputDeviceConnectionLease): boolean => this.allowsLegacyDeviceField(connection)
  }

  /** 纯构造，无平台/Native副作用。每个进程Monitor只持一Registry。 */
  constructor() {}

  /** 真实add才有开hardware权限；重复live add幂等，remove→add产生另一个原对象/scope。 */
  observeAdd(rawPlatformId: number): InputDeviceConnectionChange {
    if (!this.validId(rawPlatformId) || !this.advanceRevision()) return new InputDeviceConnectionChange(rawPlatformId, true, undefined)
    this.removed.delete(rawPlatformId)
    let connection = this.current.get(rawPlatformId)
    if (connection === undefined) {
      connection = this.allocate(new InputDeviceIdentityEvidence(rawPlatformId, true, false))
      if (connection !== undefined) this.current.set(rawPlatformId, connection)
    }
    return new InputDeviceConnectionChange(rawPlatformId, true, connection)
  }

  /** 先fence当时原对象，再返回同一对象。计数耗尽也必须允许原remove/cleanup。 */
  retireCurrent(rawPlatformId: number): InputDeviceConnectionChange {
    const connection = this.current.get(rawPlatformId)
    if (!this.validId(rawPlatformId)) return new InputDeviceConnectionChange(rawPlatformId, false, undefined)
    this.advanceRevision(); this.current.delete(rawPlatformId); this.removed.add(rawPlatformId)
    return new InputDeviceConnectionChange(rawPlatformId, false, connection)
  }

  /** 输入入口只捕获当前原对象；不由事件、迟到详情或查询次数自动create hardware。 */
  capture(identity: InputDeviceIdentityEvidence): InputDeviceConnectionCapture {
    if (!identity.idKnown) {
      if (identity.rawPlatformId !== 0) return new InputDeviceConnectionCapture('Invalid')
      if (!identity.compatibility) return new InputDeviceConnectionCapture('Pending')
      if (this.compatibilityConnection === undefined)
        this.compatibilityConnection = this.allocate(new InputDeviceIdentityEvidence(0, false, true))
      return this.compatibilityConnection === undefined ? new InputDeviceConnectionCapture('Exhausted') :
        new InputDeviceConnectionCapture('Compatibility', this.compatibilityConnection)
    }
    if (identity.compatibility || !this.validId(identity.rawPlatformId)) return new InputDeviceConnectionCapture('Invalid')
    const connection = this.current.get(identity.rawPlatformId)
    if (connection === undefined) return new InputDeviceConnectionCapture(this.publicationExhausted || nextApplicationScope > Number.MAX_SAFE_INTEGER ? 'Exhausted' : 'Pending')
    return new InputDeviceConnectionCapture(identity.rawPlatformId === 0 ? 'NativePending' : 'Live', connection)
  }

  /** latest请求+原revision的精确对象；安全上限耗尽拒新inventory，仍可退休已有连接。 */
  beginInventory(): InputDeviceInventoryTicket | undefined {
    if (this.publicationExhausted || this.nextRequest > Number.MAX_SAFE_INTEGER) return undefined
    const ticket = new InputDeviceInventoryTicket(this.revision, this.nextRequest++)
    this.latestInventory = ticket; return ticket
  }

  /** 第一次合法inventory可建立候选；removed墓碑直到真正add才清，旧list不能复生。 */
  inventoryConnection(ticket: InputDeviceInventoryTicket, rawPlatformId: number): InputDeviceConnectionLease | undefined {
    if (!this.acceptsInventory(ticket) || !this.validId(rawPlatformId) || this.removed.has(rawPlatformId)) return undefined
    let connection = this.current.get(rawPlatformId)
    if (connection === undefined) {
      connection = this.allocate(new InputDeviceIdentityEvidence(rawPlatformId, true, false))
      if (connection !== undefined) this.current.set(rawPlatformId, connection)
    }
    return connection
  }

  /** detail成功前后都检查；最新ticket不保证该lease仍是原对象，所以两项必须合取。 */
  acceptsInventory(ticket: InputDeviceInventoryTicket, connection?: InputDeviceConnectionLease): boolean {
    return !this.publicationExhausted && this.latestInventory === ticket && ticket.revision === this.revision &&
      (connection === undefined || (!connection.compatibility && this.accepts(connection)))
  }

  /** 原对象准入；hardware0是合法应用连接，不能与独立compatibility对象混为一桶。 */
  accepts(connection: InputDeviceConnectionLease): boolean {
    return connection.compatibility ? this.compatibilityConnection === connection :
      connection.idKnown && this.current.get(connection.rawPlatformId) === connection
  }

  /** 目前Native device字段只支持positive hardware或明确compat0；known hardware0保持Pending。 */
  allowsLegacyDeviceField(connection: InputDeviceConnectionLease): boolean {
    return this.accepts(connection) && (connection.compatibility || connection.rawPlatformId > 0)
  }

  /** 所有live hardware副本供当前snapshot汇总；不包含retired或compatible bucket。 */
  liveConnections(): InputDeviceConnectionLease[] {
    const result: InputDeviceConnectionLease[] = []
    this.current.forEach((connection: InputDeviceConnectionLease): void => { result.push(connection) })
    return result
  }

  /** 只接受可精确表示的原非负整数；不截断、不加1、不将invalid转换成missing。 */
  private validId(value: number): boolean { return Number.isSafeInteger(value) && value >= 0 }

  /** 不回绕的opaque命名空间，最后MAX可分配一次；不因remove或失败退回计数。 */
  private allocate(identity: InputDeviceIdentityEvidence): InputDeviceConnectionLease | undefined {
    if (nextApplicationScope > Number.MAX_SAFE_INTEGER) return undefined
    return new InputDeviceConnectionLease(identity, nextApplicationScope++)
  }

  /** publication计数也有安全上限；饱和撤inventory资格，不能让同值比较放过后续实时变化。 */
  private advanceRevision(): boolean {
    this.latestInventory = undefined
    if (this.revision >= Number.MAX_SAFE_INTEGER) { this.publicationExhausted = true; return false }
    this.revision++; return true
  }
}

/** 八轴原值副本；所有getter先于任何维护/Native输出，外部event map后来变化不能改这份事实。 */
export class GamepadAxisSnapshot {
  private values: Array<number | undefined>
  constructor(getAxis: (axis: number) => number | undefined) {
    this.values = []
    for (let axis: number = 0; axis < 8; axis++) this.values.push(getAxis(axis))
  }
  /** 只读单轴；不暴露可变数组，非法axis也不读取后来event对象。 */
  get(axis: number): number | undefined { return Number.isInteger(axis) && axis >= 0 && axis < 8 ? this.values[axis] : undefined }
}

/** 原key值副本；来源准入由原connection/会话判，重复码和timestamp不能产生设备身份。 */
export class GamepadButtonSnapshot {
  readonly ohosKey: number
  readonly down: boolean
  constructor(ohosKey: number, down: boolean) { this.ohosKey = ohosKey; this.down = down }
}

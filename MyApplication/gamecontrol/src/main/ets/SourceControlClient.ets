import { InputDeviceConnectionLease, InputDeviceConnectionReader } from './InputDeviceConnectionLease'
/** 控件身份到原生持有令牌的客户端。此模块不依赖 NAPI、ArkUI 或当前布局；按下时冻结绑定，
 * 释放只发送取得的 token。每个端实例使用独立命名空间，页面/控件重建不会认领旧持有。
 */
export interface SourceControlPort {
  acquire: (source: number, deviceId: number, controlId: string, codes: number[], originalControl?: string) => string
  release: (token: string) => boolean
}

/** 当前呈现节点的成员身份与资格；只用于取得新持有，释放始终沿原 token。 */
export interface ControlGroupWitness { memberId: string; eligibility: string }

class ControlClientLease {
  token: string
  bindings: string
  constructor(token: string, bindings: string) { this.token = token; this.bindings = bindings }
}

let nextControlClientId: number = 1

/** 一个原连接control的在途intent；token未返回也已能退休，返回后不会遗失实际Native持有。 */
class ConnectionControlIntent {
  token: string = ''
  readonly bindings: string
  acquiring: boolean = true
  retiring: boolean = false
  unknownToken: boolean = false
  releasing: boolean = false
  constructor(bindings: string) { this.bindings = bindings }
}

export class SourceControlClient {
  private source: number
  private port: SourceControlPort
  private namespace: string
  private leases: Map<string, ControlClientLease> = new Map<string, ControlClientLease>()
  /** 公共原token出口与连接墓碑共用在途围栏；同步Native回入不能递归发同一个RELEASE。 */
  private releasingTokens: Set<string> = new Set<string>()

  private connectionReader: InputDeviceConnectionReader | undefined
  private connectionIntents: Map<InputDeviceConnectionLease, Map<string, ConnectionControlIntent>> =
    new Map<InputDeviceConnectionLease, Map<string, ConnectionControlIntent>>()

  constructor(source: number, port: SourceControlPort, connectionReader?: InputDeviceConnectionReader) {
    this.connectionReader = connectionReader
    this.source = source
    this.port = port
    if (nextControlClientId > Number.MAX_SAFE_INTEGER) throw new Error('Control client identities exhausted')
    this.namespace = `client:${nextControlClientId++}:`
  }

  /** 返回空串表示未取得持有；同一控件的重复按下幂等，未释放时禁止偷偷更换绑定。 */
  acquire(control: string, codes: number[], deviceId: number = 0): string {
    const key: string = `${deviceId}:${control}`
    // 同一组合键中的重复码没有额外持有语义，按首次出现顺序归一，保持已有导入布局可用。
    const normalized: number[] = []
    for (let i: number = 0; i < codes.length; i++) {
      if (normalized.indexOf(codes[i]) < 0) normalized.push(codes[i])
    }
    const bindings: string = JSON.stringify(normalized)
    const existing: ControlClientLease | undefined = this.leases.get(key)
    if (existing !== undefined) return existing.bindings === bindings ? existing.token : ''
    try {
      const token: string = this.port.acquire(this.source, deviceId, this.namespace + control, normalized, control)
      if (token.length === 0) return ''
      this.leases.set(key, new ControlClientLease(token, bindings))
      return token
    } catch (_) { return '' }
  }

  /** 只在原生确认后删除缓存；失败保留原 token，下一次生命周期边界可以重试。 */
  release(control: string, deviceId: number = 0): boolean {
    const existing: ControlClientLease | undefined = this.leases.get(`${deviceId}:${control}`)
    return existing === undefined ? true : this.releaseToken(existing.token)
  }

  /** UI 的按下记录保留该 token；迟到释放必须针对原记录，不能重新查询同名控件的新租约。 */
  currentToken(control: string, deviceId: number = 0): string {
    return this.leases.get(`${deviceId}:${control}`)?.token ?? ''
  }

  releaseToken(token: string): boolean {
    if (token.length === 0) return true
    if (this.releasingTokens.has(token)) return false
    // 调用前冻结原记录，并先撤连接的新输入资格。回调可reset/重建同名control，返回续体
    // 只能删除这里记录的原对象；不得由返回后的当前Map去认领后来lease或intent。
    const originalLeases: Map<string, ControlClientLease> = new Map<string, ControlClientLease>()
    const originalIntents: Map<InputDeviceConnectionLease, Map<string, ConnectionControlIntent>> =
      new Map<InputDeviceConnectionLease, Map<string, ConnectionControlIntent>>()
    this.leases.forEach((lease: ControlClientLease, key: string): void => {
      if (lease.token === token) originalLeases.set(key, lease)
    })
    this.connectionIntents.forEach((controls: Map<string, ConnectionControlIntent>, connection: InputDeviceConnectionLease): void => {
      controls.forEach((intent: ConnectionControlIntent, control: string): void => {
        if (intent.acquiring || intent.token !== token) return
        intent.retiring = true
        let originals = originalIntents.get(connection)
        if (originals === undefined) { originals = new Map<string, ConnectionControlIntent>(); originalIntents.set(connection, originals) }
        originals.set(control, intent)
      })
    })
    try {
      if (!this.releaseNativeToken(token)) return false
      originalLeases.forEach((lease: ControlClientLease, key: string): void => {
        if (this.leases.get(key) === lease) this.leases.delete(key)
      })
      // 公共原token释放也收口连接journal，不把已释放token留成下次acquire的假live。
      originalIntents.forEach((controls: Map<string, ConnectionControlIntent>, connection: InputDeviceConnectionLease): void => {
        controls.forEach((intent: ConnectionControlIntent, control: string): void => {
          this.deleteConnectionIntent(connection, control, intent)
        })
      })
      return true
    } catch (_) { return false }
  }

  /**
   * 两条释放入口的唯一Native调用围栏。false包括明确拒绝、异常或同token在途，保留原墓碑
   * 供后续稳定维护；本方法不猜测token归属，也不以回入查询或RESET当作这次调用已成功。
   */
  private releaseNativeToken(token: string): boolean {
    if (this.releasingTokens.has(token)) return false
    this.releasingTokens.add(token)
    try { return this.port.release(token) }
    catch (_) { return false }
    finally { this.releasingTokens.delete(token) }
  }


  /**
   * 原lease贡献入场。Native调用前登记Acquiring intent，releaseConnection同步回入可以先标退休。
   * 返token后才确定成功：旧资格退休则只精确cleanup原token；失败保原墓碑供稳定维护重试。
   * known hardware0当前无Native device口，明确Pending；缺省compat0是另一个显式lease。
   */
  acquireForConnection(connection: InputDeviceConnectionLease, control: string, codes: number[]): string {
    const reader = this.connectionReader
    if (reader === undefined || !reader.allowsLegacyDeviceField(connection)) return ''
    const normalized: number[] = []
    for (const code of codes) if (normalized.indexOf(code) < 0) normalized.push(code)
    const bindings: string = JSON.stringify(normalized)
    const nativeControl: string = this.namespace + 'c:' + connection.applicationScope + ':' + control
    // 实际NAPI入口上限192 UTF-8 bytes，比POD buffer更窄；超预算拒绝，绝不截断身份。
    if (this.utf8Length(nativeControl) > 192) return ''
    let controls = this.connectionIntents.get(connection)
    if (controls === undefined) { controls = new Map<string, ConnectionControlIntent>(); this.connectionIntents.set(connection, controls) }
    const existing = controls.get(control)
    if (existing !== undefined) return !existing.retiring && !existing.acquiring && existing.bindings === bindings ? existing.token : ''
    const intent = new ConnectionControlIntent(bindings)
    controls.set(control, intent)
    try { intent.token = this.port.acquire(this.source, connection.rawPlatformId, nativeControl, normalized) }
    catch (_) { intent.retiring = true; intent.unknownToken = true }
    intent.acquiring = false
    if (intent.unknownToken) return ''
    if (intent.token.length === 0) { this.deleteConnectionIntent(connection, control, intent); return '' }
    if (intent.retiring || !reader.accepts(connection) || this.connectionIntents.get(connection)?.get(control) !== intent) {
      intent.retiring = true; this.cleanupConnectionIntent(connection, control, intent); return ''
    }
    return intent.token
  }

  /** 精确一个原control；在途intent只先标退休，实际token返回后由原acquire续体cleanup。 */
  releaseForConnection(connection: InputDeviceConnectionLease, control: string): boolean {
    const intent = this.connectionIntents.get(connection)?.get(control)
    if (intent === undefined) return true
    intent.retiring = true
    return intent.acquiring ? false : this.cleanupConnectionIntent(connection, control, intent)
  }

  /** 按原对象退休，不lookup rawID或新sameid。返回false保未完成/在途真实墓碑，不假称全释放。 */
  releaseConnection(connection: InputDeviceConnectionLease): boolean {
    const controls = this.connectionIntents.get(connection)
    if (controls === undefined) return true
    let completed: boolean = true
    controls.forEach((intent: ConnectionControlIntent, control: string): void => {
      intent.retiring = true
      if (intent.acquiring || !this.cleanupConnectionIntent(connection, control, intent)) completed = false
    })
    return completed
  }

  /** 稳定Host/Manager维护原墓碑；即使UI观察关闭、acquire返空串，实际token仍有cleanup owner。 */
  reconcileRetirements(): boolean {
    let completed: boolean = true
    this.connectionIntents.forEach((controls: Map<string, ConnectionControlIntent>, connection: InputDeviceConnectionLease): void => {
      controls.forEach((intent: ConnectionControlIntent, control: string): void => {
        if (!intent.retiring) return
        if (intent.acquiring || !this.cleanupConnectionIntent(connection, control, intent)) completed = false
      })
    })
    return completed
  }

  /** 原token已确认才删原对象；同步port回入创建兄弟record也不会被此cleanup删除。 */
  private cleanupConnectionIntent(connection: InputDeviceConnectionLease, control: string, intent: ConnectionControlIntent): boolean {
    if (intent.acquiring || intent.unknownToken || intent.releasing) return false
    intent.releasing = true
    try { if (intent.token.length > 0 && !this.releaseNativeToken(intent.token)) return false }
    catch (_) { return false }
    finally { intent.releasing = false }
    this.deleteConnectionIntent(connection, control, intent); return true
  }

  /** Map/record双精确检查；不靠同名control推断后来记录是原记录。 */
  private deleteConnectionIntent(connection: InputDeviceConnectionLease, control: string, intent: ConnectionControlIntent): void {
    const controls = this.connectionIntents.get(connection)
    if (controls?.get(control) !== intent) return
    controls.delete(control)
    if (controls.size === 0 && this.connectionIntents.get(connection) === controls) this.connectionIntents.delete(connection)
  }

  /** UTF-8边界预算；非法半代理对也拒绝，避免Native读到另一种字节身份。 */
  private utf8Length(text: string): number {
    let length: number = 0, offset: number = 0
    while (offset < text.length) {
      const code: number = text.codePointAt(offset) ?? 0
      if (code >= 55296 && code <= 57343) return 193
      length += code <= 127 ? 1 : code <= 2047 ? 2 : code <= 65535 ? 3 : 4
      offset += code > 65535 ? 2 : 1
    }
    return length
  }

  /** 仅在已确认本来源的 native 权威状态被撤销时调用，不把别的来源复位投影到本实例。 */
  dropAfterNativeReset(): void {
    this.leases.clear()
    // 实际reset可清已完成/unknown记录；在途调用尚未返回，必须保其原intent等待token结果。
    this.connectionIntents.forEach((controls: Map<string, ConnectionControlIntent>, connection: InputDeviceConnectionLease): void => {
      controls.forEach((intent: ConnectionControlIntent, control: string): void => {
        if (intent.acquiring) intent.retiring = true
        else this.deleteConnectionIntent(connection, control, intent)
      })
    })
  }
}

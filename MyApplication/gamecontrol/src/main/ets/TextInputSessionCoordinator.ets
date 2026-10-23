/**
 * IME 编辑键（退格/前删/回车/小键盘回车/Esc）一次“按下+抬起”的三态结果。
 * 数值是跨语言镜像：与 native 的 PlatformInputTextKeyTapResult 及 NAPI textInputKeyTap
 * 的返回值逐值对应，改任一侧都必须同步另外两侧。
 */
export enum TextInputKeyTapResult {
  /** 已作为 typed 物理键进入 core，与同一会话的提交文本共用序号，交付顺序与调用顺序一致。 */
  Submitted = 0,
  /** 进程不在 typed 物理路由：调用方必须改走原 legacy ring 按键对。 */
  NotTypedRoute = 1,
  /** 被拒（键不合法、门禁关闭、会话失效或 core 拒收）：调用方不得回退 ring，否则会越过已排队的文本。 */
  Rejected = 2
}

/** 把宿主返回的数值收敛成三态；未知数值一律按 Rejected，绝不猜成“可以回退 ring”。 */
export function textInputKeyTapResultFromNative(value: number): TextInputKeyTapResult {
  if (value === 0) return TextInputKeyTapResult.Submitted
  if (value === 1) return TextInputKeyTapResult.NotTypedRoute
  return TextInputKeyTapResult.Rejected
}

/** Unicode-scalar indexed text-session command sink supplied by the host. */
export interface TextInputSessionSink {
  begin(owner: string, generation: number): boolean
  end(owner: string, generation: number, reason: string): boolean
  abort(owner: string, generation: number, reason: string): void
  commit(owner: string, generation: number, text: string): boolean
  /**
   * 会话内有序编辑键。generation 为 0 表示宿主会话暂未重建：宿主仍须先回答是否处于
   * typed 路由（legacy 路由下调用方要回退 ring），typed 路由下再以会话失效拒绝。
   */
  keyTap(owner: string, generation: number, ohosKeyCode: number,
    glfwKey: number): TextInputKeyTapResult
  editing(
    owner: string,
    generation: number,
    text: string,
    selectionStart: number,
    selectionLength: number
  ): boolean
  selection(
    owner: string,
    generation: number,
    selectionStart: number,
    selectionLength: number
  ): boolean
  candidates(
    owner: string,
    generation: number,
    items: string[],
    selected: number,
    pageStart: number,
    pageSize: number
  ): boolean
}

export class TextInputSessionLease {
  owner: string = ''
  generation: number = 0

  copy(): TextInputSessionLease {
    const value = new TextInputSessionLease()
    value.owner = this.owner
    value.generation = this.generation
    return value
  }
}

export enum TextInputBeginStatus {
  Granted = 0,
  Busy = 1,
  HostRejected = 2,
  InvalidOwner = 3
}

export class TextInputBeginResult {
  status: TextInputBeginStatus = TextInputBeginStatus.InvalidOwner
  lease: TextInputSessionLease | undefined = undefined
}

export const TEXT_INPUT_MAX_SCALARS: number = 4096
export const TEXT_INPUT_MAX_CANDIDATES: number = 64
export const TEXT_INPUT_MAX_CANDIDATE_SCALARS: number = 256

/**
 * Single-owner session coordinator shared by mobile and desktop IME adapters.
 * A lease fences late async callbacks; only an accepted host BEGIN becomes live.
 */
export class TextInputSessionCoordinator {
  private sink: TextInputSessionSink
  private activeLease: TextInputSessionLease | undefined = undefined
  private nextGeneration: number = 1
  /** UI lease保持稳定；Native RESET只作废宿主会话号，下条合法文本命令惰性重建。 */
  private hostGeneration: number = 0

  constructor(sink: TextInputSessionSink) {
    this.sink = sink
  }

  begin(owner: string): TextInputSessionLease | undefined {
    return this.tryBegin(owner).lease
  }

  tryBegin(owner: string): TextInputBeginResult {
    const result = new TextInputBeginResult()
    if (owner.length === 0) return result
    const active: TextInputSessionLease | undefined = this.activeLease
    if (active !== undefined) {
      result.status = TextInputBeginStatus.Busy
      return result
    }
    const lease = new TextInputSessionLease()
    lease.owner = owner
    lease.generation = this.takeGeneration()
    if (lease.generation === 0) {
      result.status = TextInputBeginStatus.HostRejected
      return result
    }
    if (!this.sink.begin(lease.owner, lease.generation)) {
      result.status = TextInputBeginStatus.HostRejected
      return result
    }
    this.activeLease = lease
    this.hostGeneration = lease.generation
    result.status = TextInputBeginStatus.Granted
    result.lease = lease.copy()
    return result
  }

  end(lease: TextInputSessionLease, reason: string): boolean {
    if (!this.matches(lease)) return false
    if (this.hostGeneration !== 0 && !this.sink.end(lease.owner, this.hostGeneration, reason)) return false
    this.activeLease = undefined
    this.hostGeneration = 0
    return true
  }

  /** Local lifecycle fence when a host END cannot be acknowledged. */
  abort(lease: TextInputSessionLease, reason: string): boolean {
    if (!this.matches(lease)) return false
    try {
      if (this.hostGeneration !== 0) this.sink.abort(lease.owner, this.hostGeneration, reason)
    } catch (_) {
      // The local generation must still close; a future host sink records/reset this failure.
    }
    this.activeLease = undefined
    this.hostGeneration = 0
    return true
  }

  commit(lease: TextInputSessionLease, text: string): boolean {
    if (!this.matches(lease) || !TextInputSessionCoordinator.validText(text, false)) {
      return false
    }
    return this.ensureHostSession(lease) && this.sink.commit(lease.owner, this.hostGeneration, text)
  }

  editing(
    lease: TextInputSessionLease,
    text: string,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    if (!this.matches(lease) || !TextInputSessionCoordinator.validText(text, true)) {
      return false
    }
    const scalarCount: number = TextInputSessionCoordinator.scalarCount(text)
    if (scalarCount < 0) return false
    if (!TextInputSessionCoordinator.validRange(
      selectionStart, selectionLength, scalarCount)) return false
    return this.ensureHostSession(lease) && this.sink.editing(
      lease.owner, this.hostGeneration, text, selectionStart, selectionLength)
  }

  selection(
    lease: TextInputSessionLease,
    selectionStart: number,
    selectionLength: number
  ): boolean {
    if (!this.matches(lease) ||
        !TextInputSessionCoordinator.validRange(
          selectionStart, selectionLength, TEXT_INPUT_MAX_SCALARS)) {
      return false
    }
    return this.ensureHostSession(lease) && this.sink.selection(
      lease.owner, this.hostGeneration, selectionStart, selectionLength)
  }

  candidates(
    lease: TextInputSessionLease,
    items: string[],
    selected: number,
    pageStart: number,
    pageSize: number
  ): boolean {
    if (!this.matches(lease) || items.length > TEXT_INPUT_MAX_CANDIDATES ||
        !TextInputSessionCoordinator.validNonNegativeInteger(selected) ||
        !TextInputSessionCoordinator.validNonNegativeInteger(pageStart) ||
        !TextInputSessionCoordinator.validNonNegativeInteger(pageSize)) {
      return false
    }
    let totalScalars: number = 0
    const copy: string[] = []
    for (let i: number = 0; i < items.length; i++) {
      const item: string = items[i]
      const itemScalars: number = TextInputSessionCoordinator.scalarCount(item)
      if (itemScalars < 0 || itemScalars > TEXT_INPUT_MAX_CANDIDATE_SCALARS) return false
      totalScalars += itemScalars
      if (totalScalars > TEXT_INPUT_MAX_SCALARS) return false
      copy.push(item)
    }
    if (items.length === 0) {
      if (selected !== 0 || pageStart !== 0 || pageSize !== 0) return false
    } else if (selected >= items.length || pageStart >= items.length ||
               pageSize === 0 || pageStart + pageSize > items.length ||
               selected < pageStart || selected >= pageStart + pageSize) {
      return false
    }
    return this.ensureHostSession(lease) && this.sink.candidates(
      lease.owner, this.hostGeneration, copy, selected, pageStart, pageSize)
  }

  /**
   * 文本会话内的有序编辑键。与提交同一规则惰性恢复宿主会话；恢复失败时把 0 号交给宿主，
   * 让它先按路由回答（legacy 路由下调用方据 NotTypedRoute 回退 ring），而不是在这里
   * 替宿主猜路由。租约不匹配（迟到回调）直接 Rejected：已结束的客户端不得再发键。
   */
  keyTap(lease: TextInputSessionLease, ohosKeyCode: number,
    glfwKey: number): TextInputKeyTapResult {
    if (!this.matches(lease)) return TextInputKeyTapResult.Rejected
    const generation: number = this.ensureHostSession(lease) ? this.hostGeneration : 0
    return this.sink.keyTap(lease.owner, generation, ohosKeyCode, glfwKey)
  }

  /**
   * 该租约当前的宿主会话号；0 表示宿主会话已被 native reset 作废、尚待下一条命令重建，
   * 或租约已不是当前租约。输入客户端据此判断本地回显是否仍描述同一个宿主会话。
   */
  hostGenerationOf(lease: TextInputSessionLease): number {
    return this.matches(lease) ? this.hostGeneration : 0
  }

  /** 仅在宿主明确发布新reset epoch时调用，不借提交失败猜测复位或重放已成功文本。 */
  invalidateHostSession(): void { this.hostGeneration = 0 }

  private ensureHostSession(lease: TextInputSessionLease): boolean {
    if (!this.matches(lease)) return false
    if (this.hostGeneration !== 0) return true
    const generation: number = this.takeGeneration()
    if (generation === 0 || !this.sink.begin(lease.owner, generation)) return false
    this.hostGeneration = generation
    return true
  }

  active(): TextInputSessionLease | undefined {
    return this.activeLease?.copy()
  }

  isActive(): boolean {
    return this.activeLease !== undefined
  }

  private matches(lease: TextInputSessionLease): boolean {
    const active: TextInputSessionLease | undefined = this.activeLease
    return active !== undefined && active.owner === lease.owner &&
      active.generation === lease.generation
  }

  private takeGeneration(): number {
    const value: number = this.nextGeneration
    if (value > 9007199254740991) return 0
    this.nextGeneration++
    return value
  }

  private static validText(text: string, allowEmpty: boolean): boolean {
    const count: number = TextInputSessionCoordinator.scalarCount(text)
    return count >= 0 && (allowEmpty || count > 0) && count <= TEXT_INPUT_MAX_SCALARS
  }

  private static validRange(start: number, length: number, total: number): boolean {
    return TextInputSessionCoordinator.validNonNegativeInteger(start) &&
      TextInputSessionCoordinator.validNonNegativeInteger(length) &&
      start <= total && length <= total - start
  }

  private static validNonNegativeInteger(value: number): boolean {
    return Number.isFinite(value) && value >= 0 && Math.trunc(value) === value
  }

  private static scalarCount(text: string): number {
    let count: number = 0
    let index: number = 0
    while (index < text.length) {
      const codepoint: number = text.codePointAt(index) ?? 0
      if (codepoint >= 55296 && codepoint <= 57343) return -1
      index += codepoint > 65535 ? 2 : 1
      count++
    }
    return count
  }
}

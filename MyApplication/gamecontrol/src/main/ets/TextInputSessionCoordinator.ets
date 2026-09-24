/** Unicode-scalar indexed text-session command sink supplied by the host. */
export interface TextInputSessionSink {
  begin(owner: string, generation: number): boolean
  end(owner: string, generation: number, reason: string): boolean
  abort(owner: string, generation: number, reason: string): void
  commit(owner: string, generation: number, text: string): boolean
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
    result.status = TextInputBeginStatus.Granted
    result.lease = lease.copy()
    return result
  }

  end(lease: TextInputSessionLease, reason: string): boolean {
    if (!this.matches(lease)) return false
    if (!this.sink.end(lease.owner, lease.generation, reason)) return false
    this.activeLease = undefined
    return true
  }

  /** Local lifecycle fence when a host END cannot be acknowledged. */
  abort(lease: TextInputSessionLease, reason: string): boolean {
    if (!this.matches(lease)) return false
    try {
      this.sink.abort(lease.owner, lease.generation, reason)
    } catch (_) {
      // The local generation must still close; a future host sink records/reset this failure.
    }
    this.activeLease = undefined
    return true
  }

  commit(lease: TextInputSessionLease, text: string): boolean {
    if (!this.matches(lease) || !TextInputSessionCoordinator.validText(text, false)) {
      return false
    }
    return this.sink.commit(lease.owner, lease.generation, text)
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
    return this.sink.editing(
      lease.owner, lease.generation, text, selectionStart, selectionLength)
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
    return this.sink.selection(
      lease.owner, lease.generation, selectionStart, selectionLength)
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
    return this.sink.candidates(
      lease.owner, lease.generation, copy, selected, pageStart, pageSize)
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

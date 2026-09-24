/**
 * 当前游戏输入 surface 的唯一、可代际覆盖的事实快照。
 *
 * 本模块只保存平台已经证明的字段，不依赖 ArkUI。Window/display/XComponent
 * 适配器负责采样，输入前端、布局与 native publisher 只消费这里的快照。
 */

export const INPUT_SURFACE_FIELD_WINDOW: number = 1
export const INPUT_SURFACE_FIELD_DISPLAY: number = 2
export const INPUT_SURFACE_FIELD_RECT: number = 4
export const INPUT_SURFACE_FIELD_DENSITY: number = 8
export const INPUT_SURFACE_FIELD_TRANSFORM: number = 16
export const INPUT_SURFACE_FIELD_REFRESH_RATE: number = 32

const MAX_SURFACE_GENERATION: number = 9007199254740991

/** Adapter-side publication candidate. Generation and validity are store-owned. */
export class InputSurfaceContextCandidate {
  windowId: number = 0
  displayId: number = -1
  leftPx: number = 0
  topPx: number = 0
  widthPx: number = 0
  heightPx: number = 0
  density: number = 0
  transform: number = -1
  refreshRateHz: number = 0
  provisional: boolean = true
}

/** Immutable-by-convention snapshot returned as a defensive copy. */
export class InputSurfaceContext {
  windowId: number = 0
  displayId: number = -1
  leftPx: number = 0
  topPx: number = 0
  widthPx: number = 0
  heightPx: number = 0
  density: number = 0
  transform: number = 0
  refreshRateHz: number = 0
  generation: number = 0
  validFields: number = 0
  provisional: boolean = true

  copy(): InputSurfaceContext {
    const value = new InputSurfaceContext()
    value.windowId = this.windowId
    value.displayId = this.displayId
    value.leftPx = this.leftPx
    value.topPx = this.topPx
    value.widthPx = this.widthPx
    value.heightPx = this.heightPx
    value.density = this.density
    value.transform = this.transform
    value.refreshRateHz = this.refreshRateHz
    value.generation = this.generation
    value.validFields = this.validFields
    value.provisional = this.provisional
    return value
  }

  has(field: number): boolean {
    return (this.validFields & field) === field
  }
}

/** Fences late Window callbacks and restore calls from an older game page. */
export class InputSurfacePublisherLease {
  owner: string = ''
  id: number = 0

  copy(): InputSurfacePublisherLease {
    const value = new InputSurfacePublisherLease()
    value.owner = this.owner
    value.id = this.id
    return value
  }
}

/**
 * Process-local SSOT. Equivalent publications are deduplicated; a provisional
 * default-display sample is never equivalent to an authoritative Window sample.
 */
export class InputSurfaceContextStore {
  private currentValue: InputSurfaceContext = new InputSurfaceContext()
  private nextGeneration: number = 1
  private activePublisher: InputSurfacePublisherLease | undefined = undefined
  private nextPublisherId: number = 1

  snapshot(): InputSurfaceContext {
    return this.currentValue.copy()
  }

  beginPublisher(owner: string): InputSurfacePublisherLease | undefined {
    if (owner.length === 0) return undefined
    const lease = new InputSurfacePublisherLease()
    lease.owner = owner
    lease.id = this.nextPublisherId
    if (this.nextPublisherId < MAX_SURFACE_GENERATION) this.nextPublisherId++
    if (this.activePublisher !== undefined || this.currentValue.validFields !== 0) {
      this.invalidateCurrent()
    }
    this.activePublisher = lease
    return lease.copy()
  }

  publish(
    lease: InputSurfacePublisherLease,
    candidate: InputSurfaceContextCandidate
  ): InputSurfaceContext | undefined {
    if (!this.matchesPublisher(lease)) return undefined
    const normalized: InputSurfaceContext = InputSurfaceContextStore.normalize(candidate)
    if (InputSurfaceContextStore.sameSemantics(this.currentValue, normalized)) {
      return this.currentValue.copy()
    }
    normalized.generation = this.takeGeneration()
    this.currentValue = normalized
    return normalized.copy()
  }

  /** Only the current page may invalidate its publication on restore/dispose. */
  endPublisher(lease: InputSurfacePublisherLease): InputSurfaceContext | undefined {
    if (!this.matchesPublisher(lease)) return undefined
    this.activePublisher = undefined
    return this.invalidateCurrent()
  }

  private invalidateCurrent(): InputSurfaceContext {
    const cleared = new InputSurfaceContext()
    // A publisher existed and explicitly ended. This is authoritative absence,
    // not the pre-window provisional state; consumers must not fall back to the
    // default display and resurrect stale geometry.
    cleared.provisional = false
    cleared.generation = this.takeGeneration()
    this.currentValue = cleared
    return cleared.copy()
  }

  private matchesPublisher(lease: InputSurfacePublisherLease): boolean {
    const active: InputSurfacePublisherLease | undefined = this.activePublisher
    return active !== undefined && lease.id !== 0 && active.id === lease.id &&
      active.owner === lease.owner
  }

  private takeGeneration(): number {
    const value: number = this.nextGeneration
    if (this.nextGeneration < MAX_SURFACE_GENERATION) {
      this.nextGeneration++
    }
    return value
  }

  private static finiteInteger(value: number, fallback: number): number {
    if (!Number.isFinite(value)) return fallback
    return Math.trunc(value)
  }

  private static normalize(candidate: InputSurfaceContextCandidate): InputSurfaceContext {
    const value = new InputSurfaceContext()
    value.provisional = candidate.provisional

    const windowId: number = InputSurfaceContextStore.finiteInteger(candidate.windowId, 0)
    if (windowId > 0) {
      value.windowId = windowId
      value.validFields |= INPUT_SURFACE_FIELD_WINDOW
    }

    const displayId: number = InputSurfaceContextStore.finiteInteger(candidate.displayId, -1)
    if (displayId >= 0) {
      value.displayId = displayId
      value.validFields |= INPUT_SURFACE_FIELD_DISPLAY
    }

    const leftPx: number = InputSurfaceContextStore.finiteInteger(candidate.leftPx, 0)
    const topPx: number = InputSurfaceContextStore.finiteInteger(candidate.topPx, 0)
    const widthPx: number = InputSurfaceContextStore.finiteInteger(candidate.widthPx, 0)
    const heightPx: number = InputSurfaceContextStore.finiteInteger(candidate.heightPx, 0)
    if (widthPx > 0 && heightPx > 0) {
      value.leftPx = leftPx
      value.topPx = topPx
      value.widthPx = widthPx
      value.heightPx = heightPx
      value.validFields |= INPUT_SURFACE_FIELD_RECT
    }

    if (Number.isFinite(candidate.density) && candidate.density > 0) {
      value.density = candidate.density
      value.validFields |= INPUT_SURFACE_FIELD_DENSITY
    }

    const transform: number = InputSurfaceContextStore.finiteInteger(candidate.transform, -1)
    if (transform >= 0 && transform <= 3) {
      value.transform = transform
      value.validFields |= INPUT_SURFACE_FIELD_TRANSFORM
    }

    if (Number.isFinite(candidate.refreshRateHz) &&
        candidate.refreshRateHz > 0 && candidate.refreshRateHz <= 1000) {
      value.refreshRateHz = candidate.refreshRateHz
      value.validFields |= INPUT_SURFACE_FIELD_REFRESH_RATE
    }
    return value
  }

  private static sameSemantics(
    left: InputSurfaceContext,
    right: InputSurfaceContext
  ): boolean {
    return left.windowId === right.windowId &&
      left.displayId === right.displayId &&
      left.leftPx === right.leftPx &&
      left.topPx === right.topPx &&
      left.widthPx === right.widthPx &&
      left.heightPx === right.heightPx &&
      left.density === right.density &&
      left.transform === right.transform &&
      left.refreshRateHz === right.refreshRateHz &&
      left.validFields === right.validFields &&
      left.provisional === right.provisional
  }
}

let surfaceContextStore: InputSurfaceContextStore | undefined = undefined

export function getInputSurfaceContextStore(): InputSurfaceContextStore {
  if (surfaceContextStore === undefined) {
    surfaceContextStore = new InputSurfaceContextStore()
  }
  return surfaceContextStore
}

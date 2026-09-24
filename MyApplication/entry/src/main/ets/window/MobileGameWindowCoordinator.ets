import { GameWindowSnapshot } from './GameWindowSnapshot'
import { common } from '@kit.AbilityKit'
import { display, window } from '@kit.ArkUI'
import {
  InputSurfaceContext,
  InputSurfaceContextCandidate,
  InputSurfacePublisherLease,
  getInputSurfaceContextStore
} from 'gamecontrol'

let nextGameWindowOwnerId: number = 1
let activeGameWindowOwnerId: number = 0
let gameWindowRestoreBarrier: Promise<void> | undefined = undefined
class MobileGameWindowBaseline {
  windowId: number = 0
  orientation: window.Orientation = window.Orientation.UNSPECIFIED
  layoutFullScreen: boolean = false
  restoreFailed: boolean = false
}
let gameWindowBaseline: MobileGameWindowBaseline | undefined = undefined

function acquireGameWindowOwner(
  windowId: number,
  orientation: window.Orientation,
  layoutFullScreen: boolean
): number {
  const baseline: MobileGameWindowBaseline | undefined = gameWindowBaseline
  if (baseline !== undefined && baseline.windowId !== windowId) return 0
  if (baseline !== undefined && baseline.restoreFailed) return 0
  if (baseline === undefined) {
    const initial = new MobileGameWindowBaseline()
    initial.windowId = windowId
    initial.orientation = orientation
    initial.layoutFullScreen = layoutFullScreen
    gameWindowBaseline = initial
  }
  const id: number = nextGameWindowOwnerId
  if (nextGameWindowOwnerId < 9007199254740991) nextGameWindowOwnerId++
  activeGameWindowOwnerId = id
  return id
}

function trackGameWindowRestore(pending: Promise<void>): void {
  gameWindowRestoreBarrier = pending
  pending.then((): void => {
    if (gameWindowRestoreBarrier === pending) gameWindowRestoreBarrier = undefined
  }).catch((): void => {
    if (gameWindowRestoreBarrier === pending) gameWindowRestoreBarrier = undefined
  })
}

/** 当前游戏 Window 的事实快照；desktop source-set 导出完全相同的类型与方法。 */


/**
 * phone/tablet 产品窗口前端。
 *
 * 行为保持原 McGamePage：横屏、内容全屏、隐藏系统栏。区别仅在于三条 Promise
 * 现在严格串行 await，并保存进入前状态供启动失败/页面离开时幂等恢复。
 */
export class MobileGameWindowCoordinator {
  private activeWindow: window.Window | undefined = undefined
  private initialOrientation: window.Orientation = window.Orientation.UNSPECIFIED
  private initialLayoutFullScreen: boolean = false
  private entered: boolean = false
  private enterPromise: Promise<GameWindowSnapshot> | undefined = undefined
  private restorePromise: Promise<void> | undefined = undefined
  private restoreRequested: boolean = false
  private lastSnapshot: GameWindowSnapshot = new GameWindowSnapshot()
  private surfacePublisher: InputSurfacePublisherLease = new InputSurfacePublisherLease()
  private windowOwnerId: number = 0
  private rectChangeListener: Callback<window.RectChangeOptions> =
    (_options: window.RectChangeOptions): void => { this.updateSnapshotFromActiveWindow() }
  private displayIdChangeListener: Callback<number> =
    (_displayId: number): void => { this.updateSnapshotFromActiveWindow() }

  enter(context: common.UIAbilityContext): Promise<GameWindowSnapshot> {
    if (this.enterPromise !== undefined) return this.enterPromise
    this.enterPromise = this.enterInternal(context)
    return this.enterPromise
  }

  restore(): Promise<void> {
    this.restoreRequested = true
    if (this.restorePromise !== undefined) return this.restorePromise
    this.restorePromise = this.restoreInternal()
    const pending: Promise<void> = this.restorePromise
    pending.catch((): void => {
      if (this.restorePromise === pending) this.restorePromise = undefined
    })
    trackGameWindowRestore(this.restorePromise)
    return this.restorePromise
  }

  snapshot(): GameWindowSnapshot {
    if (this.activeWindow !== undefined) {
      this.lastSnapshot = MobileGameWindowCoordinator.readSnapshot(
        this.activeWindow, this.surfacePublisher)
    }
    return this.lastSnapshot
  }

  private async enterInternal(
    context: common.UIAbilityContext
  ): Promise<GameWindowSnapshot> {
    try {
      if (this.restoreRequested) throw new Error('Game window enter cancelled')
      const restoreBarrier: Promise<void> | undefined = gameWindowRestoreBarrier
      if (restoreBarrier !== undefined) {
        try { await restoreBarrier } catch (_) {}
      }
      if (this.restoreRequested) throw new Error('Game window enter cancelled')
      const win: window.Window = await window.getLastWindow(context)
      if (this.restoreRequested) throw new Error('Game window enter cancelled')
      const before: window.WindowProperties = win.getWindowProperties()
      const orientation: window.Orientation = win.getPreferredOrientation()
      this.windowOwnerId = acquireGameWindowOwner(
        before.id, orientation, before.isLayoutFullScreen)
      if (!this.ownsGameWindow()) throw new Error('Game window ownership rejected')
      this.activeWindow = win
      this.entered = true
      const publisher: InputSurfacePublisherLease | undefined =
        getInputSurfaceContextStore().beginPublisher('mobile-game-window')
      if (publisher === undefined) throw new Error('Input surface publisher rejected')
      this.surfacePublisher = publisher
      this.installContextListeners(win)
      const baseline: MobileGameWindowBaseline | undefined = gameWindowBaseline
      if (baseline === undefined) throw new Error('Game window baseline unavailable')
      this.initialOrientation = baseline.orientation
      this.initialLayoutFullScreen = baseline.layoutFullScreen
      // 从第一条平台写操作开始，本 coordinator 就拥有恢复责任。任何后续 reject 都会由
      // McGamePage 的失败边界调用 restore，不把半应用状态留给启动器。
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE)
      if (!this.ownsGameWindow()) throw new Error('Game window ownership replaced')
      await win.setWindowLayoutFullScreen(true)
      if (!this.ownsGameWindow()) throw new Error('Game window ownership replaced')
      await win.setWindowSystemBarEnable([])
      if (!this.ownsGameWindow()) throw new Error('Game window ownership replaced')

      this.lastSnapshot = MobileGameWindowCoordinator.readSnapshot(win, this.surfacePublisher)
      return this.lastSnapshot
    } catch (e) {
      throw e as Error
    }
  }

  private async restoreInternal(): Promise<void> {
    const pending: Promise<GameWindowSnapshot> | undefined = this.enterPromise
    if (pending !== undefined) {
      try {
        await pending
      } catch (_) {
        // enter 可能在第二/第三条平台 Promise 上失败；entered 已在首个写操作前置 true，
        // 所以下面仍会对同一 Window 做 best-effort 回滚。
      }
    }
    const win: window.Window | undefined = this.activeWindow
    if (win === undefined) {
      this.closeSurfacePublisher()
      this.releaseGameWindowOwner()
      return
    }
    if (!this.entered) {
      this.removeContextListeners(win)
      this.activeWindow = undefined
      this.closeSurfacePublisher()
      this.releaseGameWindowOwner()
      return
    }

    if (!this.ownsGameWindow()) {
      this.removeContextListeners(win)
      this.entered = false
      this.activeWindow = undefined
      this.closeSurfacePublisher()
      this.releaseGameWindowOwner()
      return
    }

    let firstError: Error | undefined = undefined
    try {
      const enabledBars: Array<'status' | 'navigation'> = ['status', 'navigation']
      await win.setWindowSystemBarEnable(enabledBars)
    } catch (e) {
      firstError = e as Error
    }
    try {
      await win.setWindowLayoutFullScreen(this.initialLayoutFullScreen)
    } catch (e) {
      if (firstError === undefined) firstError = e as Error
    }
    try {
      await win.setPreferredOrientation(this.initialOrientation)
    } catch (e) {
      if (firstError === undefined) firstError = e as Error
    }
    this.removeContextListeners(win)
    this.closeSurfacePublisher()
    if (firstError !== undefined) {
      const baseline: MobileGameWindowBaseline | undefined = gameWindowBaseline
      if (baseline !== undefined) baseline.restoreFailed = true
      throw firstError
    }
    this.entered = false
    this.activeWindow = undefined
    this.releaseGameWindowOwner()
  }

  private static readSnapshot(
    win: window.Window,
    publisher: InputSurfacePublisherLease
  ): GameWindowSnapshot {
    try {
      const properties: window.WindowProperties = win.getWindowProperties()
      const rect: window.Rect = properties.windowRect
      const snapshot = new GameWindowSnapshot()
      snapshot.windowId = properties.id
      snapshot.displayId = properties.displayId ?? -1
      snapshot.left = rect.left
      snapshot.top = rect.top
      snapshot.width = rect.width
      snapshot.height = rect.height
      if (snapshot.displayId >= 0) {
        try {
          const currentDisplay: display.Display = display.getDisplayByIdSync(snapshot.displayId)
          snapshot.density = currentDisplay.densityPixels
          snapshot.transform = currentDisplay.rotation
          snapshot.refreshRateHz = currentDisplay.refreshRate
        } catch (_) {
          // A known Window displayId must not be replaced with the default display.
        }
      }
      const candidate = new InputSurfaceContextCandidate()
      candidate.windowId = snapshot.windowId
      candidate.displayId = snapshot.displayId
      candidate.leftPx = snapshot.left
      candidate.topPx = snapshot.top
      candidate.widthPx = snapshot.width
      candidate.heightPx = snapshot.height
      candidate.density = snapshot.density
      candidate.transform = snapshot.transform
      candidate.refreshRateHz = snapshot.refreshRateHz
      candidate.provisional = false
      const context: InputSurfaceContext | undefined =
        getInputSurfaceContextStore().publish(publisher, candidate)
      if (context === undefined) throw new Error('Stale input surface publisher')
      snapshot.contextGeneration = context.generation
      return snapshot
    } catch (e) {
      throw e as Error
    }
  }

  private installContextListeners(win: window.Window): void {
    try { win.on('windowRectChange', this.rectChangeListener) } catch (_) {}
    try { win.on('displayIdChange', this.displayIdChangeListener) } catch (_) {}
  }

  private removeContextListeners(win: window.Window): void {
    try { win.off('windowRectChange', this.rectChangeListener) } catch (_) {}
    try { win.off('displayIdChange', this.displayIdChangeListener) } catch (_) {}
  }

  private updateSnapshotFromActiveWindow(): void {
    const win: window.Window | undefined = this.activeWindow
    if (win === undefined) return
    try {
      this.lastSnapshot = MobileGameWindowCoordinator.readSnapshot(
        win, this.surfacePublisher)
    } catch (_) {}
  }

  private closeSurfacePublisher(): void {
    if (this.surfacePublisher.id === 0) return
    getInputSurfaceContextStore().endPublisher(this.surfacePublisher)
    this.surfacePublisher = new InputSurfacePublisherLease()
  }

  private ownsGameWindow(): boolean {
    return this.windowOwnerId !== 0 && activeGameWindowOwnerId === this.windowOwnerId
  }

  private releaseGameWindowOwner(): void {
    if (this.ownsGameWindow()) {
      activeGameWindowOwnerId = 0
      gameWindowBaseline = undefined
    }
    this.windowOwnerId = 0
  }
}

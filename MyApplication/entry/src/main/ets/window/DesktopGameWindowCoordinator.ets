import { common } from '@kit.AbilityKit'
import { display, window } from '@kit.ArkUI'
import { GameWindowSnapshot } from './GameWindowSnapshot'
import { getDesktopSystemBridge, resolveWindowGlobalPosition } from './DesktopSystemBridge'
import { InputSurfaceContext, InputSurfaceContextCandidate, InputSurfacePublisherLease,
  getInputSurfaceContextStore } from 'gamecontrol'

let restoreBarrier: Promise<void> | undefined = undefined

/** Publishes page input geometry; the system bridge belongs to GameAbility's Window. */
export class DesktopGameWindowCoordinator {
  private activeWindow: window.Window | undefined = undefined
  private surfacePublisher: InputSurfacePublisherLease = new InputSurfacePublisherLease()
  private lastSnapshot: GameWindowSnapshot = new GameWindowSnapshot()
  private disposed: boolean = false
  private enterPromise: Promise<GameWindowSnapshot> | undefined = undefined
  private restorePromise: Promise<void> | undefined = undefined
  private rectListener: Callback<window.RectChangeOptions> = (): void => { this.refresh() }
  private displayListener: Callback<number> = (): void => { this.refresh() }

  enter(context: common.UIAbilityContext): Promise<GameWindowSnapshot> {
    if (this.enterPromise === undefined) this.enterPromise = this.enterInternal(context)
    return this.enterPromise
  }
  restore(): Promise<void> {
    this.disposed = true
    if (this.restorePromise === undefined) {
      this.restorePromise = this.restoreInternal()
      const pending: Promise<void> = this.restorePromise
      restoreBarrier = pending
      pending.then((): void => { if (restoreBarrier === pending) restoreBarrier = undefined },
        (): void => { if (restoreBarrier === pending) restoreBarrier = undefined })
    }
    return this.restorePromise
  }
  snapshot(): GameWindowSnapshot {
    if (!this.disposed && this.activeWindow !== undefined) {
      this.lastSnapshot = DesktopGameWindowCoordinator.readSnapshot(this.activeWindow, this.surfacePublisher)
    }
    return this.lastSnapshot
  }
  private async enterInternal(context: common.UIAbilityContext): Promise<GameWindowSnapshot> {
    const pending: Promise<void> | undefined = restoreBarrier
    if (pending !== undefined) await pending
    if (this.disposed) throw new Error('Game page has already closed')
    const win: window.Window = await window.getLastWindow(context)
    if (this.disposed) throw new Error('Game page closed while obtaining Window')
    const publisher: InputSurfacePublisherLease | undefined = getInputSurfaceContextStore().beginPublisher('desktop-game-window')
    if (publisher === undefined) throw new Error('Desktop input publisher rejected')
    this.surfacePublisher = publisher
    this.activeWindow = win
    win.on('windowRectChange', this.rectListener)
    win.on('displayIdChange', this.displayListener)
    await getDesktopSystemBridge().start(win)
    if (this.disposed) throw new Error('Game page closed during desktop initialization')
    this.lastSnapshot = DesktopGameWindowCoordinator.readSnapshot(win, publisher)
    return this.lastSnapshot
  }
  private async restoreInternal(): Promise<void> {
    const pending: Promise<GameWindowSnapshot> | undefined = this.enterPromise
    if (pending !== undefined) { try { await pending } catch (_) {} }
    // The system bridge owns the GameAbility Window callbacks and native host
    // generation. Releasing only the input publisher leaves that generation
    // attached after a failed launch or a normal page teardown, so the next
    // singleton/WindowStage launch can publish through a stale Window object.
    getDesktopSystemBridge().stop()
    const win: window.Window | undefined = this.activeWindow
    if (win !== undefined) {
      try { win.off('windowRectChange', this.rectListener) } catch (_) {}
      try { win.off('displayIdChange', this.displayListener) } catch (_) {}
    }
    if (this.surfacePublisher.id !== 0) getInputSurfaceContextStore().endPublisher(this.surfacePublisher)
    this.surfacePublisher = new InputSurfacePublisherLease()
    this.activeWindow = undefined
  }
  private refresh(): void {
    if (this.disposed) return
    try { this.snapshot() } catch (_) {}
  }
  private static readSnapshot(
    win: window.Window,
    publisher: InputSurfacePublisherLease
  ): GameWindowSnapshot {
    try {
      const properties: window.WindowProperties = win.getWindowProperties()
      const rect: window.Rect = properties.drawableRect
      const snapshot = new GameWindowSnapshot()
      snapshot.windowId = properties.id
      snapshot.displayId = properties.displayId ?? -1
      const globalPosition: display.Position = resolveWindowGlobalPosition(properties, rect)
      snapshot.left = globalPosition.x
      snapshot.top = globalPosition.y
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

}

import { window, display } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import deviceInfo from '@ohos.deviceInfo'
import { AppLogger, LOG_DOMAIN_LAUNCH } from 'commons'
import testNapi, { DesktopHostCommand } from 'libentry.so'

/** Resolve a display-relative point in the global coordinate space. */
export function resolveDisplayGlobalPosition(
  displayId: number,
  relative: display.Position
): display.Position {
  if (displayId < 0 || !Number.isFinite(relative.x) || !Number.isFinite(relative.y)) {
    throw new Error('Desktop display coordinate unavailable')
  }
  try {
    return display.convertRelativeToGlobalCoordinate({ displayId: displayId, position: relative })
  } catch (error) {
    // API22–25 desktop runs are intentionally single/default-display only.
    // That display has a stable global origin even while the WindowStage is
    // being recreated and the conversion service briefly rejects requests.
    try {
      if (display.getDefaultDisplaySync().id === displayId) return relative
    } catch (_) { /* preserve the original display-service error */ }
    if (deviceInfo.sdkApiVersion < 26) return relative
    throw error as Error
  }
}

/** Resolve a window's drawable origin in the global coordinate space. */
export function resolveWindowGlobalPosition(
  properties: window.WindowProperties,
  drawable: window.Rect
): display.Position {
  const globalRect: window.Rect | undefined = properties.globalDisplayRect
  if (globalRect !== undefined && globalRect.width > 0 && globalRect.height > 0 &&
    Number.isFinite(globalRect.left) && Number.isFinite(globalRect.top)) {
    return { x: globalRect.left + drawable.left, y: globalRect.top + drawable.top }
  }
  const displayId: number | undefined = properties.displayId
  if (displayId === undefined || displayId < 0) throw new Error('Desktop window display ID unavailable')
  const relative: display.Position = { x: properties.windowRect.left + drawable.left,
    y: properties.windowRect.top + drawable.top }
  return resolveDisplayGlobalPosition(displayId, relative)
}

/** Owns one Window lease. Native requests are serialized here on the UI thread. */
export class DesktopSystemBridge {
  private win: window.Window | undefined = undefined
  private generation: number = 0
  private draining: boolean = false
  private refreshing: boolean = false
  private refreshPending: boolean = false
  private decorated: boolean = true
  private resizable: boolean = true
  private limits: window.WindowLimits = {}
  private baseLimits: window.WindowLimits = {}
  private publishChain: Promise<void> = Promise.resolve()
  private displays: display.Display[] = []
  // Display enumeration and available-area observers were added to the public
  // desktop surface in API 26. API 22 still has a usable default display and
  // native window, so keep the older route free of those newer calls.
  private enhancedDisplays: boolean = false
  private rectListener: Callback<window.RectChangeOptions> = (): void => { this.refresh() }
  private statusListener: Callback<window.WindowStatusType> = (): void => { this.refresh() }
  private displayListener: Callback<number> = (): void => { this.refresh() }
  private areaListener: Callback<display.Rect> = (): void => { this.refresh() }
  private closeListener: Callback<void, Promise<boolean>> = async (): Promise<boolean> => {
    if (!testNapi.mcIsRunning()) return false
    testNapi.desktopRequestClose(true)
    return true
  }

  async start(win: window.Window): Promise<void> {
    if (this.win !== undefined && this.generation > 0) {
      try {
        if (this.win.getWindowProperties().id === win.getWindowProperties().id) {
          await this.publish()
          return
        }
      } catch (_) {
        // A WindowStage can hand us an object whose properties are already
        // invalid after the previous game ended. Drop that generation before
        // attaching the replacement window.
        this.stop()
      }
    }
    this.stop()
    this.win = win
    this.enhancedDisplays = deviceInfo.sdkApiVersion >= 26
    this.baseLimits = win.getWindowLimits()
    this.limits = this.copyBaseLimits()
    this.decorated = true
    this.resizable = true
    this.generation = testNapi.desktopAttach((): void => { this.drain() })
    if (this.generation <= 0) { this.win = undefined; throw new Error('Desktop system bridge unavailable') }
    try {
      win.on('windowRectChange', this.rectListener)
      win.on('windowStatusChange', this.statusListener)
      win.on('displayIdChange', this.displayListener)
      win.on('windowWillClose', this.closeListener)
      if (this.enhancedDisplays) {
        display.on('add', this.displayListener)
        display.on('remove', this.displayListener)
        display.on('change', this.displayListener)
      }
      await this.publish()
    } catch (error) {
      // A failed initial publication must not leave a live generation or old
      // Window callbacks behind for the next launch.
      this.stop()
      throw error as Error
    }
  }

  stop(): void {
    const win: window.Window | undefined = this.win
    if (win !== undefined) {
      try { win.off('windowRectChange', this.rectListener) } catch (_) {}
      try { win.off('windowStatusChange', this.statusListener) } catch (_) {}
      try { win.off('displayIdChange', this.displayListener) } catch (_) {}
      try { win.off('windowWillClose', this.closeListener) } catch (_) {}
    }
    if (this.enhancedDisplays) {
      try { display.off('add', this.displayListener) } catch (_) {}
      try { display.off('remove', this.displayListener) } catch (_) {}
      try { display.off('change', this.displayListener) } catch (_) {}
    }
    this.clearDisplayListeners()
    if (this.generation > 0) testNapi.desktopDetach(this.generation)
    this.generation = 0
    this.win = undefined
  }

  private clearDisplayListeners(): void {
    for (let i = 0; i < this.displays.length; i++) {
      if (this.enhancedDisplays) {
        try { this.displays[i].off('availableAreaChange', this.areaListener) } catch (_) {}
      }
    }
    this.displays = []
  }

  private refresh(): void {
    this.refreshPending = true
    if (!this.refreshing) this.publishLoop()
  }

  private async publishLoop(): Promise<void> {
    this.refreshing = true
    try {
      while (this.refreshPending && this.win !== undefined) {
        this.refreshPending = false
        await this.publish()
      }
    } catch (e) {
      AppLogger.warn('DesktopWindow', 'Window facts refresh failed', e, LOG_DOMAIN_LAUNCH)
    } finally { this.refreshing = false }
  }

  private publish(): Promise<void> {
    const next: Promise<void> = this.publishChain.catch((): void => {}).then((): Promise<void> => this.publishCurrent())
    this.publishChain = next
    return next
  }

  private async publishCurrent(): Promise<void> {
    const win: window.Window | undefined = this.win
    const generation: number = this.generation
    if (win === undefined || generation === 0) return
    const properties: window.WindowProperties = win.getWindowProperties()
    const displayId: number | undefined = properties.displayId
    if (displayId === undefined) throw new Error('Desktop window display ID unavailable')
    let devices: display.Display[] = []
    try {
      devices = this.enhancedDisplays
        ? await display.getAllDisplays()
        : [display.getDefaultDisplaySync()]
    } catch (error) {
      // Window facts can still be published from WindowProperties when the
      // display service is between stages. Keep the display list empty for
      // this refresh and let the listener trigger a later retry.
      AppLogger.warn('DesktopWindow', 'Display enumeration unavailable during refresh', error, LOG_DOMAIN_LAUNCH)
    }
    let primaryId: number = displayId
    try { primaryId = display.getDefaultDisplaySync().id } catch (_) { /* retain the window display id */ }
    devices.sort((a: display.Display, b: display.Display): number => {
      if (a.id === b.id) return 0
      if (a.id === primaryId) return -1
      if (b.id === primaryId) return 1
      return a.id - b.id
    })
    const values: number[] = []
    const names: string[] = []
    for (let i = 0; i < devices.length && i < 16; i++) {
      const item: display.Display = devices[i]
      const position: display.Position = { x: 0, y: 0 }
      const relative: display.RelativePosition = { displayId: item.id, position: position }
      let origin: display.Position
      try {
        origin = item.id === primaryId
          ? position
          : display.convertRelativeToGlobalCoordinate(relative)
      } catch (error) {
        if (item.id !== primaryId) {
          AppLogger.warn('DesktopWindow', 'Secondary display origin unavailable; retrying later', error, LOG_DOMAIN_LAUNCH)
          continue
        }
        origin = position
      }
      const area: display.Rect = this.enhancedDisplays
        ? await item.getAvailableArea()
        : { left: 0, top: 0, width: item.width, height: item.height }
      values.push(item.id, origin.x, origin.y, item.width, item.height,
        origin.x + area.left, origin.y + area.top, area.width, area.height,
        item.densityPixels, item.refreshRate,
        item.xDPI > 0 ? item.width * 25.4 / item.xDPI : 0,
        item.yDPI > 0 ? item.height * 25.4 / item.yDPI : 0)
      names.push(item.name)
    }
    if (generation !== this.generation || win !== this.win) return
    this.clearDisplayListeners()
    this.displays = devices
    for (let i = 0; i < devices.length; i++) {
      if (this.enhancedDisplays) {
        try { devices[i].on('availableAreaChange', this.areaListener) } catch (_) {}
      }
    }
    const outer: window.Rect = properties.windowRect
    const rect: window.Rect = properties.drawableRect
    if (rect.width <= 0 || rect.height <= 0) throw new Error('Window drawable area unavailable')
    const global: display.Position = resolveWindowGlobalPosition(properties, rect)
    const facts: number[] = [properties.id, displayId, global.x, global.y,
      rect.width, rect.height, win.getWindowStatus() as number,
      this.decorated ? 1 : 0, this.resizable ? 1 : 0, rect.left, rect.top,
      outer.width - rect.left - rect.width, outer.height - rect.top - rect.height]
    if (!testNapi.desktopPublishState(generation, facts, values, names)) {
      throw new Error('Desktop window facts rejected')
    }
  }

  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      while (this.win !== undefined) {
        const command: DesktopHostCommand | undefined = testNapi.desktopTakeCommand()
        if (command === undefined) break
        let error: number = 0
        try {
          if (command.generation !== this.generation) throw new Error('Stale desktop command')
          await this.execute(command, this.win)
          if (command.generation !== this.generation) throw new Error('Window detached during command')
          await this.publish()
        } catch (e) {
          const failure = e as BusinessError
          error = failure.code || -1
          AppLogger.warn('DesktopWindow', 'Command failed kind=' + command.kind +
            ' sequence=' + command.sequence + ' code=' + error, e, LOG_DOMAIN_LAUNCH)
        }
        testNapi.desktopCompleteCommand(command.generation, command.sequence, error)
      }
    } finally { this.draining = false }
  }

  private async execute(command: DesktopHostCommand, win: window.Window): Promise<void> {
    const status: window.WindowStatusType = win.getWindowStatus()
    switch (command.kind) {
      case 1:
        if (command.a <= 0 || command.b <= 0) throw new Error('Invalid window size')
        const sizeProperties: window.WindowProperties = win.getWindowProperties()
        await win.resize(command.a + sizeProperties.windowRect.width - sizeProperties.drawableRect.width,
          command.b + sizeProperties.windowRect.height - sizeProperties.drawableRect.height)
        break
      case 2:
        const moveRect: window.Rect = win.getWindowProperties().drawableRect
        await win.moveWindowToGlobal(command.a - moveRect.left, command.b - moveRect.top)
        break
      case 3:
        if (command.a !== 0) {
          const targetId: number = command.b
          const currentId: number | undefined = win.getWindowProperties().displayId
          if (targetId >= 0 && targetId !== currentId) {
            if (status === window.WindowStatusType.FULL_SCREEN || status === window.WindowStatusType.MAXIMIZE) await win.recover()
            const target: display.Display = display.getDisplayByIdSync(targetId)
            const origin: display.Position = resolveDisplayGlobalPosition(target.id, { x: 0, y: 0 })
            await win.moveWindowToGlobal(origin.x, origin.y)
          }
          if (win.getWindowStatus() !== window.WindowStatusType.FULL_SCREEN) await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE)
        } else if (status === window.WindowStatusType.FULL_SCREEN || status === window.WindowStatusType.MAXIMIZE) {
          await win.recover()
        }
        break
      case 4:
      case 8:
        await win.minimize()
        break
      case 5:
        if (status === window.WindowStatusType.MINIMIZE) await win.restore()
        else if (status === window.WindowStatusType.MAXIMIZE || status === window.WindowStatusType.FULL_SCREEN) await win.recover()
        else await win.showWindow()
        break
      case 7:
        if (status === window.WindowStatusType.MINIMIZE) await win.restore()
        else await win.showWindow()
        break
      case 6:
        await win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)
        break
      case 9:
        await win.setWindowTitle(command.text)
        break
      case 10:
        const limitProperties: window.WindowProperties = win.getWindowProperties()
        const borderWidth: number = limitProperties.windowRect.width - limitProperties.drawableRect.width
        const borderHeight: number = limitProperties.windowRect.height - limitProperties.drawableRect.height
        this.limits = this.copyBaseLimits()
        if (command.a > 0) this.limits.minWidth = command.a + borderWidth
        if (command.b > 0) this.limits.minHeight = command.b + borderHeight
        if (command.c > 0) this.limits.maxWidth = command.c + borderWidth
        if (command.d > 0) this.limits.maxHeight = command.d + borderHeight
        if (this.resizable) await win.setWindowLimits(this.limits)
        break
      case 11:
        win.setWindowDecorVisible(command.a !== 0)
        this.decorated = command.a !== 0
        break
      case 12:
        if (command.a !== 0) await win.setWindowLimits(this.limits)
        else {
          const rect: window.Rect = win.getWindowProperties().windowRect
          const fixed: window.WindowLimits = { minWidth: rect.width, maxWidth: rect.width,
            minHeight: rect.height, maxHeight: rect.height }
          await win.setWindowLimits(fixed)
        }
        this.resizable = command.a !== 0
        break
      case 13:
        if (command.a > 0 && command.b > 0) await win.setAspectRatio(command.a / command.b)
        else await win.resetAspectRatio()
        break
      case 14:
        if (pasteboard.getSystemPasteboard().hasDataType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
          const context = win.getUIContext().getHostContext() as common.UIAbilityContext
          const permissions: Permissions[] = ['ohos.permission.READ_PASTEBOARD']
          const granted = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
          if (granted.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            throw new Error('Clipboard permission denied or missing from signing Profile')
          }
        }
        break
      default: throw new Error('Unsupported desktop command')
    }
  }

  private copyBaseLimits(): window.WindowLimits {
    return { minWidth: this.baseLimits.minWidth, minHeight: this.baseLimits.minHeight,
      maxWidth: this.baseLimits.maxWidth, maxHeight: this.baseLimits.maxHeight }
  }
}

const desktopSystemBridge: DesktopSystemBridge = new DesktopSystemBridge()
export function getDesktopSystemBridge(): DesktopSystemBridge { return desktopSystemBridge }

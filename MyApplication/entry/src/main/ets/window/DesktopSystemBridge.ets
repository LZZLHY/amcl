import { window, display } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import deviceInfo from '@ohos.deviceInfo'
import { AppLogger, LOG_DOMAIN_LAUNCH } from 'commons'
import testNapi, { DesktopHostCommand } from 'libentry.so'
import { parseGameResolutionState } from '../runtime/GameResolutionState'

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

/** 一次完整采样同时持有拓扑、Native 数值和对应的可用区域监听对象。 */
class DesktopDisplaySnapshot {
  devices: display.Display[] = []
  values: number[] = []
  names: string[] = []
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
  private displaySnapshot: DesktopDisplaySnapshot = new DesktopDisplaySnapshot()
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
    for (let i = 0; i < this.displaySnapshot.devices.length; i++) {
      if (this.enhancedDisplays) {
        try { this.displaySnapshot.devices[i].off('availableAreaChange', this.areaListener) } catch (_) {}
      }
    }
    this.displaySnapshot = new DesktopDisplaySnapshot()
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
    const sampledDisplay: number | undefined = win.getWindowProperties().displayId
    if (sampledDisplay === undefined || sampledDisplay < 0) throw new Error('Desktop window display ID unavailable')
    let snapshot: DesktopDisplaySnapshot
    try {
      const devices: display.Display[] = this.enhancedDisplays
        ? await display.getAllDisplays() : [display.getDefaultDisplaySync()]
      if (devices.length === 0) throw new Error('No desktop display reported for the live window')
      snapshot = await this.readDisplayFacts(devices, sampledDisplay)
    } catch (error) {
      // 枚举或读取某一屏失败都不是拔屏。复用本代最后一次完整采样，窗口状态仍独立刷新。
      if (generation !== this.generation || win !== this.win) return
      AppLogger.warn('DesktopWindow', 'Display enumeration unavailable during refresh', error, LOG_DOMAIN_LAUNCH)
      snapshot = this.displaySnapshot
      if (snapshot.devices.length === 0) {
        // 新窗口没有历史拓扑时只发布系统可核实的当前屏，后续正常枚举再补齐其他屏。
        snapshot = await this.readDisplayFacts([display.getDisplayByIdSync(sampledDisplay)], sampledDisplay)
      }
    }
    if (generation !== this.generation || win !== this.win) return
    // 枚举显示器会让出事件循环。窗口模式、所在显示器和位置从同一次最终回读发布。
    const properties: window.WindowProperties = win.getWindowProperties()
    const displayId: number | undefined = properties.displayId
    if (displayId === undefined || displayId < 0) throw new Error('Desktop window display ID unavailable')
    const outer: window.Rect = properties.windowRect
    const rect: window.Rect = properties.drawableRect
    if (rect.width <= 0 || rect.height <= 0) throw new Error('Window drawable area unavailable')
    const global: display.Position = resolveWindowGlobalPosition(properties, rect)
    const facts: number[] = [properties.id, displayId, global.x, global.y,
      rect.width, rect.height, win.getWindowStatus() as number,
      this.decorated ? 1 : 0, this.resizable ? 1 : 0, rect.left, rect.top,
      outer.width - rect.left - rect.width, outer.height - rect.top - rect.height]
    if (!testNapi.desktopPublishState(generation, facts, snapshot.values, snapshot.names)) {
      throw new Error('Desktop window facts rejected')
    }
    if (snapshot !== this.displaySnapshot) {
      this.clearDisplayListeners()
      this.displaySnapshot = snapshot
      if (this.enhancedDisplays) {
        for (const item of snapshot.devices) {
          try { item.on('availableAreaChange', this.areaListener) } catch (_) {}
        }
      }
    }
  }

  /** 先把各屏的工作区与全局坐标读齐；任一采样失败整批保留旧拓扑。 */
  private async readDisplayFacts(devices: display.Display[], displayId: number): Promise<DesktopDisplaySnapshot> {
    let primaryId: number = displayId
    try { primaryId = display.getDefaultDisplaySync().id } catch (_) { /* retain the window display id */ }
    devices.sort((a: display.Display, b: display.Display): number => {
      if (a.id === b.id) return 0
      if (a.id === primaryId) return -1
      if (b.id === primaryId) return 1
      return a.id - b.id
    })
    const snapshot = new DesktopDisplaySnapshot()
    snapshot.devices = devices
    for (let i = 0; i < devices.length && i < 16; i++) {
      const item: display.Display = devices[i]
      const position: display.Position = { x: 0, y: 0 }
      const relative: display.RelativePosition = { displayId: item.id, position: position }
      const origin: display.Position = item.id === primaryId
        ? position : display.convertRelativeToGlobalCoordinate(relative)
      const area: display.Rect = this.enhancedDisplays
        ? await item.getAvailableArea()
        : { left: 0, top: 0, width: item.width, height: item.height }
      snapshot.values.push(item.id, origin.x, origin.y, item.width, item.height,
        origin.x + area.left, origin.y + area.top, area.width, area.height,
        item.densityPixels, item.refreshRate,
        item.xDPI > 0 ? item.width * 25.4 / item.xDPI : 0,
        item.yDPI > 0 ? item.height * 25.4 / item.yDPI : 0)
      snapshot.names.push(item.name)
    }
    return snapshot
  }

  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      while (this.win !== undefined) {
        const command: DesktopHostCommand | undefined = testNapi.desktopTakeCommand()
        if (command === undefined) break
        const win: window.Window = this.win
        let error: number = 0
        try {
          if (command.generation !== this.generation) throw new Error('Stale desktop command')
          await this.execute(command, win)
          this.checkCommandWindow(command, win)
        } catch (e) {
          const failure = e as BusinessError
          error = failure.code || -1
          AppLogger.warn('DesktopWindow', 'Command failed kind=' + command.kind +
            ' sequence=' + command.sequence + ' code=' + error, e, LOG_DOMAIN_LAUNCH)
        }
        // 系统拒绝也可能发生在 recover 或移动已成功之后，先回读最终事实再确认原序号。
        if (command.generation === this.generation && win === this.win) {
          try { await this.publish() } catch (e) {
            if (error === 0) error = (e as BusinessError).code || -1
            AppLogger.warn('DesktopWindow', 'Window facts unavailable after command', e, LOG_DOMAIN_LAUNCH)
          }
        }
        testNapi.desktopCompleteCommand(command.generation, command.sequence, error)
      }
    } finally { this.draining = false }
  }

  private checkCommandWindow(command: DesktopHostCommand, win: window.Window): void {
    if (command.generation !== this.generation || this.win !== win) throw new Error('Window detached during command')
  }

  /** moveWindowToGlobal 采用外框原点。先记住系统从全屏恢复出的浮窗位置，便于原屏回退。 */
  private outerOrigin(properties: window.WindowProperties): display.Position {
    const rect: window.Rect = properties.drawableRect
    const origin: display.Position = resolveWindowGlobalPosition(properties, rect)
    return { x: origin.x - rect.left, y: origin.y - rect.top }
  }

  private async switchFullscreenDisplay(command: DesktopHostCommand, win: window.Window,
    originalDisplay: number, originalStatus: window.WindowStatusType): Promise<void> {
    this.checkCommandWindow(command, win)
    // 先验证目标屏，包括可能失败的坐标查询。目标已拔掉时不动原屏全屏状态。
    const target: display.Display = display.getDisplayByIdSync(command.b)
    const targetOrigin: display.Position = resolveDisplayGlobalPosition(target.id, { x: 0, y: 0 })
    let restoreOrigin: display.Position = this.outerOrigin(win.getWindowProperties())
    const fullscreen: boolean = originalStatus === window.WindowStatusType.FULL_SCREEN
    const maximized: boolean = originalStatus === window.WindowStatusType.MAXIMIZE
    try {
      if (fullscreen || maximized) {
        await win.recover()
        this.checkCommandWindow(command, win)
        restoreOrigin = this.outerOrigin(win.getWindowProperties())
      }
      await win.moveWindowToGlobal(targetOrigin.x, targetOrigin.y)
      this.checkCommandWindow(command, win)
      // 移动 Promise 完成后目标也可能刚被拔掉，不能在系统选中的另一屏执行最大化。
      if (win.getWindowProperties().displayId !== target.id) throw new Error('Window did not reach the target display')
      await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE)
      this.checkCommandWindow(command, win)
      if (win.getWindowProperties().displayId !== target.id || win.getWindowStatus() !== window.WindowStatusType.FULL_SCREEN) {
        throw new Error('Target fullscreen state was not confirmed')
      }
    } catch (failure) {
      try { await this.restoreFullscreenSource(command, win, originalDisplay, originalStatus, restoreOrigin) }
      catch (error) { AppLogger.warn('DesktopWindow', 'Cross-display fullscreen restoration failed', error, LOG_DOMAIN_LAUNCH) }
      throw failure as Error
    }
  }

  /** 只补偿原命令涉及的窗口和屏幕。旧窗口被替换、用户已最小化或移到第三屏时停止。 */
  private async restoreFullscreenSource(command: DesktopHostCommand, win: window.Window, originalDisplay: number,
    originalStatus: window.WindowStatusType, restoreOrigin: display.Position): Promise<void> {
    if (command.generation !== this.generation || this.win !== win) return
    let currentDisplay = win.getWindowProperties().displayId
    let currentMode: window.WindowStatusType = win.getWindowStatus()
    if (currentMode === window.WindowStatusType.MINIMIZE ||
        (currentDisplay !== originalDisplay && currentDisplay !== command.b)) return
    const restoreFloating: boolean = originalStatus === window.WindowStatusType.FLOATING
    if (currentDisplay !== originalDisplay || restoreFloating) {
      display.getDisplayByIdSync(originalDisplay)
      if (currentMode === window.WindowStatusType.FULL_SCREEN || currentMode === window.WindowStatusType.MAXIMIZE) {
        await win.recover()
        this.checkCommandWindow(command, win)
      }
      const properties: window.WindowProperties = win.getWindowProperties()
      currentDisplay = properties.displayId
      currentMode = win.getWindowStatus()
      if (currentMode === window.WindowStatusType.MINIMIZE ||
          (currentDisplay !== originalDisplay && currentDisplay !== command.b)) return
      const actual: display.Position = this.outerOrigin(properties)
      if (currentDisplay !== originalDisplay || actual.x !== restoreOrigin.x || actual.y !== restoreOrigin.y) {
        await win.moveWindowToGlobal(restoreOrigin.x, restoreOrigin.y)
        this.checkCommandWindow(command, win)
      }
    }
    if (win.getWindowProperties().displayId !== originalDisplay || win.getWindowStatus() === originalStatus) return
    if (originalStatus === window.WindowStatusType.FULL_SCREEN) {
      await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE)
    } else if (originalStatus === window.WindowStatusType.MAXIMIZE) {
      await win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)
    }
  }

  private async execute(command: DesktopHostCommand, win: window.Window): Promise<void> {
    const status: window.WindowStatusType = win.getWindowStatus()
    switch (command.kind) {
      case 1:
        if (command.a <= 0 || command.b <= 0) throw new Error('Invalid window size')
        // 虚拟分辨率会话的L不是OS窗口P。尤其在全屏中改比例后，Minecraft保存的
        // 旧windowed尺寸不能再次resize宿主，否则每次退出全屏都会缩小窗口。
        // 显示区域由OS拖动边框及case3的recover/maximize管理；这里只满足固定
        // 主呈现窗口的尺寸约束，实际尺寸仍通过窗口事实回传，不回报请求数字。
        const resolutionState = parseGameResolutionState(testNapi.mcGetResolutionState())
        if (resolutionState.phase === 'unavailable') throw new Error('分辨率政策不可用，暂不改变系统窗口尺寸')
        if (resolutionState.virtualWindowManaged) break
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
            if (currentId === undefined || currentId < 0) throw new Error('Current desktop display unavailable')
            await this.switchFullscreenDisplay(command, win, currentId, status)
            break
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

import { window } from '@kit.ArkUI'

/** 只管理本局对宿主主窗口提出的常亮请求。 */
export class GameWindowKeepScreenOn {
  private readonly target: window.Window
  private readonly reportError: (error: Error) => void
  private listening: boolean = false
  private wanted: boolean = false
  private applied: boolean | undefined = false
  private pending: Promise<void> = Promise.resolve()
  private readonly onWindowEvent = (event: window.WindowEventType): void => {
    if (!this.listening) return
    // 前后台与焦点不同。游戏窗口可见时，弹出其他窗口或失去键鼠焦点也能保持亮屏。
    if (event === window.WindowEventType.WINDOW_SHOWN || event === window.WindowEventType.WINDOW_HIDDEN) {
      this.request(event === window.WindowEventType.WINDOW_SHOWN)
    }
  }

  constructor(target: window.Window, reportError: (error: Error) => void) {
    this.target = target
    this.reportError = reportError
  }

  start(): void {
    // 内嵌游戏和启动器共用主窗口。若已有常亮请求，游戏无须取得其所有权。
    if (this.target.getWindowProperties().isKeepScreenOn) return
    this.target.on('windowEvent', this.onWindowEvent)
    this.listening = true
    this.request(this.target.isWindowShowing())
  }

  close(): Promise<void> {
    if (!this.listening) return this.pending
    this.listening = false
    this.request(false)
    try { this.target.off('windowEvent', this.onWindowEvent) }
    catch (error) { this.reportError(error as Error) }
    return this.pending
  }

  /** 串行写窗口属性，等在途请求结束后再应用最新状态，避免退场后被旧请求重新点亮。 */
  private request(wanted: boolean): void {
    this.wanted = wanted
    this.pending = this.pending.then(async (): Promise<void> => {
      const desired: boolean = this.wanted
      if (this.applied === desired) return
      try {
        await this.target.setWindowKeepScreenOn(desired)
        this.applied = desired
      } catch (error) {
        // 写入失败时状态未知，下一次切换或退出仍应重新向系统确认目标属性。
        this.applied = undefined
        this.reportError(error as Error)
      }
    })
  }
}

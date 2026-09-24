import { window } from '@kit.ArkUI'

/**
 * 2in1 桌面窗口不使用手机方向锁与 status/navigation system-bar API；API26 编译器明确
 * 标记它们对 2in1 unavailable。桌面标题栏/任务栏由窗口最大化与系统桌面负责。
 */
export class ProductLauncherWindowChrome {
  static applyInitial(_windowClass: window.Window): Promise<void> {
    return Promise.resolve()
  }

  static applyTheme(_windowClass: window.Window, _isDark: boolean): Promise<void> {
    return Promise.resolve()
  }
}

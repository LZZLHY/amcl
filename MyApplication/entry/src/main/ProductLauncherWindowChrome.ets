import { ProductInputProfile } from 'entry/ProductInputProfile'
import { window } from '@kit.ArkUI'

/** phone/tablet launcher chrome policy; desktop source-set replaces this file. */
export class ProductLauncherWindowChrome {
  static applyInitial(windowClass: window.Window): Promise<void> {
    if (ProductInputProfile.selection().desktopWindow) return Promise.resolve()
    return windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
  }

  static applyTheme(windowClass: window.Window, isDark: boolean): Promise<void> {
    if (ProductInputProfile.selection().desktopWindow) return Promise.resolve()
    const properties: window.SystemBarProperties = {
      statusBarContentColor: isDark ? '#FFFFFFFF' : '#FF000000',
      navigationBarContentColor: isDark ? '#FFFFFFFF' : '#FF000000',
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000'
    }
    return windowClass.setWindowSystemBarProperties(properties)
  }
}

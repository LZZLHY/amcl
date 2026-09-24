/** Pure interaction policy. ProductRuntimePolicy chooses Mobile/Desktop/DesktopTouch;
 * raw availability is bounded by the compiled route and the native runtime probe. */

export enum InputProductKind {
  Mobile = 0,
  Desktop = 1,
  DesktopTouch = 2,
}

/** 一次进程生命周期内不可变的产品输入决策。 */
export class ProductInputDecision {
  productKind: InputProductKind = InputProductKind.Mobile
  runtimeApi: number = 0
  formalDesktop: boolean = false
  compatibilityDesktop: boolean = false
  mobileTouchFallback: boolean = false
  acceptDirectTouchInGame: boolean = true
  showTouchLayoutSettings: boolean = true
  allowPlatformBackGesture: boolean = true
  supportsRelativeMouse: boolean = false
  supportsCursorLock: boolean = false
  supportsHardwareRawMouse: boolean = false
  notifyBackendFocus: boolean = false

  static resolve(productKind: InputProductKind, runtimeApi: number,
    rawMouseCompiled: boolean = true): ProductInputDecision {
    const decision = new ProductInputDecision()
    decision.productKind = productKind
    decision.runtimeApi = ProductInputDecision.normalizeApi(runtimeApi)

    if (productKind === InputProductKind.Mobile) {
      // 移动/平板继续沿用既有触控产品。外接鼠标可在 API 22+ 使用窗口光标锁，
      // 但本决策不把移动产品宣称成完整 desktop Raw Input 产品。
      decision.supportsRelativeMouse = decision.runtimeApi >= 22
      decision.supportsCursorLock = decision.runtimeApi >= 22
      return decision
    }

    decision.formalDesktop = decision.runtimeApi >= 26 && rawMouseCompiled
    decision.compatibilityDesktop = decision.runtimeApi >= 22 && !decision.formalDesktop
    decision.mobileTouchFallback = decision.runtimeApi < 22
    decision.acceptDirectTouchInGame = decision.mobileTouchFallback || productKind === InputProductKind.DesktopTouch
    decision.showTouchLayoutSettings = decision.acceptDirectTouchInGame
    decision.allowPlatformBackGesture = decision.acceptDirectTouchInGame
    decision.supportsRelativeMouse = decision.runtimeApi >= 22
    decision.supportsCursorLock = decision.runtimeApi >= 22
    decision.supportsHardwareRawMouse = decision.formalDesktop
    decision.notifyBackendFocus = decision.runtimeApi >= 22
    return decision
  }

  private static normalizeApi(runtimeApi: number): number {
    if (!Number.isFinite(runtimeApi)) return 0
    const value: number = Math.trunc(runtimeApi)
    return value > 0 ? value : 0
  }
}

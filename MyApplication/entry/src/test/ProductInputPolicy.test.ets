/** ProductInputPolicy.test.ets — desktop API 分层与移动 fallback 的产品合同。 */

import { describe, it, expect } from '@ohos/hypium'
import { InputProductKind, ProductInputDecision } from 'gamecontrol'
import { ProductRuntimePolicy } from 'gamecontrol'

export default function productInputPolicyTest(): void {
  describe('ProductInputPolicy', () => {
    it('universal retains computer touch on API26 and old-system fallback', 0, () => {
      const touch = ProductRuntimePolicy.resolve('universal', '2in1', 26, 'touch', true)
      expect(touch.desktopWindow).assertTrue()
      expect(touch.input.acceptDirectTouchInGame).assertTrue()
      expect(touch.input.supportsHardwareRawMouse).assertTrue()
      const old = ProductRuntimePolicy.resolve('universal', '2in1', 21, 'auto', true)
      expect(old.input.mobileTouchFallback).assertTrue()
      expect(old.input.supportsHardwareRawMouse).assertFalse()
      const compat = ProductRuntimePolicy.resolve('universal', '2in1', 24, 'desktop', true)
      expect(compat.input.compatibilityDesktop).assertTrue()
      expect(compat.input.supportsHardwareRawMouse).assertFalse()
    })

    it('desktop-only rejects mobile and never enables touch; legacy cannot claim raw', 0, () => {
      const desktop = ProductRuntimePolicy.resolve('desktop', '2in1', 26, 'touch', true)
      expect(desktop.input.acceptDirectTouchInGame).assertFalse()
      expect(desktop.touchControlsAvailable).assertFalse()
      expect(ProductRuntimePolicy.resolve('desktop', 'phone', 26, 'auto', true).supported).assertFalse()
      const legacy = ProductRuntimePolicy.resolve('desktopLegacy', '2in1', 26, 'auto', false)
      expect(legacy.input.formalDesktop).assertFalse()
      expect(legacy.input.supportsHardwareRawMouse).assertFalse()
      expect(legacy.input.compatibilityDesktop).assertTrue()
    })

    it('runtime capability failure cannot be upgraded by the API number', 0, () => {
      const missing = ProductRuntimePolicy.resolve('universal', '2in1', 26, 'auto', false)
      expect(missing.input.supportsHardwareRawMouse).assertFalse()
      const phone = ProductRuntimePolicy.resolve('universal', 'phone', 26, 'desktop', true)
      expect(phone.input.productKind).assertEqual(InputProductKind.Mobile)
      expect(phone.input.acceptDirectTouchInGame).assertTrue()
    })
    it('historical desktopLegacy metadata maps to universal input compatibility', 0, () => {
      const old = ProductRuntimePolicy.resolve('desktopLegacy', '2in1', 21, 'auto', false)
      expect(old.supported).assertTrue()
      expect(old.input.mobileTouchFallback).assertTrue()
      const modern = ProductRuntimePolicy.resolve('desktopLegacy', '2in1', 22, 'auto', false)
      expect(modern.input.mobileTouchFallback).assertFalse()
      const universal = ProductRuntimePolicy.resolve('universal', '2in1', 26, 'auto', true)
      expect(universal.touchControlsAvailable).assertTrue()
    })
    it('API26 desktop = formal desktop + cursor lock + hardware raw', 0, () => {
      const d: ProductInputDecision = ProductInputDecision.resolve(InputProductKind.Desktop, 26)
      expect(d.formalDesktop).assertTrue()
      expect(d.compatibilityDesktop).assertFalse()
      expect(d.mobileTouchFallback).assertFalse()
      expect(d.acceptDirectTouchInGame).assertFalse()
      expect(d.showTouchLayoutSettings).assertFalse()
      expect(d.allowPlatformBackGesture).assertFalse()
      expect(d.supportsRelativeMouse).assertTrue()
      expect(d.supportsCursorLock).assertTrue()
      expect(d.supportsHardwareRawMouse).assertTrue()
      expect(d.notifyBackendFocus).assertTrue()
    })

    it('API22-25 desktop = relative compatibility, never hardware raw', 0, () => {
      for (let api: number = 22; api <= 25; api++) {
        const d: ProductInputDecision = ProductInputDecision.resolve(InputProductKind.Desktop, api)
        expect(d.formalDesktop).assertFalse()
        expect(d.compatibilityDesktop).assertTrue()
        expect(d.mobileTouchFallback).assertFalse()
        expect(d.acceptDirectTouchInGame).assertFalse()
        expect(d.supportsRelativeMouse).assertTrue()
        expect(d.supportsCursorLock).assertTrue()
        expect(d.supportsHardwareRawMouse).assertFalse()
        expect(d.notifyBackendFocus).assertTrue()
      }
    })

    it('API21及以下 desktop 明确回退移动触控产品', 0, () => {
      const api21: ProductInputDecision = ProductInputDecision.resolve(InputProductKind.Desktop, 21)
      const invalid: ProductInputDecision = ProductInputDecision.resolve(
        InputProductKind.Desktop, Number.NaN)
      expect(api21.mobileTouchFallback).assertTrue()
      expect(api21.acceptDirectTouchInGame).assertTrue()
      expect(api21.showTouchLayoutSettings).assertTrue()
      expect(api21.allowPlatformBackGesture).assertTrue()
      expect(api21.supportsRelativeMouse).assertFalse()
      expect(api21.supportsCursorLock).assertFalse()
      expect(api21.supportsHardwareRawMouse).assertFalse()
      expect(invalid.runtimeApi).assertEqual(0)
      expect(invalid.mobileTouchFallback).assertTrue()
    })

    it('mobile/tablet 产品不因 API26 自动变成 desktop', 0, () => {
      const d: ProductInputDecision = ProductInputDecision.resolve(InputProductKind.Mobile, 26)
      expect(d.formalDesktop).assertFalse()
      expect(d.compatibilityDesktop).assertFalse()
      expect(d.mobileTouchFallback).assertFalse()
      expect(d.acceptDirectTouchInGame).assertTrue()
      expect(d.showTouchLayoutSettings).assertTrue()
      expect(d.allowPlatformBackGesture).assertTrue()
      expect(d.supportsRelativeMouse).assertTrue()
      expect(d.supportsCursorLock).assertTrue()
      expect(d.supportsHardwareRawMouse).assertFalse()
      expect(d.notifyBackendFocus).assertFalse()
    })
  })
}

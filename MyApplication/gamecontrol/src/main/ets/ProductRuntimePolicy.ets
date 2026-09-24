import { InputProductKind, ProductInputDecision } from './ProductInputPolicy'

export class ProductRuntimeSelection {
  supported: boolean = false
  desktopWindow: boolean = false
  /** 是否派发到私有 GameAbility 进程；与桌面窗口/输入样式正交。 */
  isolatedGameProcess: boolean = false
  touchControlsAvailable: boolean = false
  input: ProductInputDecision = new ProductInputDecision()
}

/** Pure product/interaction decision. Window width and channel are not inputs. */
export class ProductRuntimePolicy {
  /**
   * 静态私有 UIAbility 进程的平台准入，仅依据真实设备/产品/API，不依据宽屏或触控模式。
   * API14 是平台能力起点；实际 universal 安装下限另由产品清单约束，不能冒充实机覆盖。
   */
  static supportsTabletIsolation(family: string, deviceType: string, runtimeApi: number): boolean {
    return (family === 'universal' || family === 'desktopLegacy') && deviceType === 'tablet' && runtimeApi >= 14
  }

  static normalizeInteraction(value: string): string {
    return value === 'touch' || value === 'desktop' ? value : 'auto'
  }

  static resolve(family: string, deviceType: string, runtimeApi: number,
    interaction: string, rawMouseCompiled: boolean,
    tabletIsolationEnabled: boolean = false): ProductRuntimeSelection {
    // Read compatibility for historical metadata; no build target produces it.
    const normalizedFamily: string = family === 'desktopLegacy' ? 'universal' : family
    const selection = new ProductRuntimeSelection()
    selection.desktopWindow = deviceType === '2in1'
    selection.touchControlsAvailable = normalizedFamily !== 'desktop'
    selection.supported = normalizedFamily === 'universal'
      ? deviceType === 'phone' || deviceType === 'tablet' || selection.desktopWindow
      : normalizedFamily === 'desktop' && selection.desktopWindow && runtimeApi >= 22
    // 电脑路线不受平板开关影响。平板选择由调用方传入首次初始化锁存的持久偏好；
    // 此处的缺省 false 只表示调用方没有提供选择，不是产品偏好默认值。
    // 手机/未知设备不能被偏好提升为可隔离，实际创建仍须 GameAbility 的 PID/锁验证。
    selection.isolatedGameProcess = selection.desktopWindow || (selection.supported &&
      ProductRuntimePolicy.supportsTabletIsolation(family, deviceType, runtimeApi) && tabletIsolationEnabled)
    let kind: InputProductKind = InputProductKind.Mobile
    if (selection.desktopWindow) {
      const touch: boolean = selection.touchControlsAvailable &&
        (ProductRuntimePolicy.normalizeInteraction(interaction) === 'touch' || runtimeApi < 22)
      kind = touch ? InputProductKind.DesktopTouch : InputProductKind.Desktop
    }
    selection.input = ProductInputDecision.resolve(kind, runtimeApi, rawMouseCompiled)
    return selection
  }
}

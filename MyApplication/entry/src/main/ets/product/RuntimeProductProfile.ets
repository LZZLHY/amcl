import deviceInfo from '@ohos.deviceInfo'
import testNapi from 'libentry.so'
import { ProductInputDecision, ProductRuntimePolicy, ProductRuntimeSelection } from 'gamecontrol'
import { PreferenceManager } from 'feature_system'
import { ProductBuildProfile } from 'entry/ProductBuildProfile'
import { AppLogger, LOG_DOMAIN_LAUNCH, ProcessPreferences } from 'commons'

let selection: ProductRuntimeSelection | undefined = undefined
let interaction: string = 'auto'
let activeInteraction: string = 'auto'
let frozen: boolean = false
let rawAvailable: boolean = false
/** 独立于输入 frozen 的进程路线锁存；同 PID 重建 Entry 不得提前应用待重启设置。 */
let processRouteInitialized: boolean = false
let activeTabletIsolation: boolean = false

export class RuntimeProductProfile {
  static initialize(context: Context): void {
    if (frozen) return
    const preferences = new PreferenceManager(context)
    interaction = ProductRuntimePolicy.normalizeInteraction(preferences.desktopInteraction)
    rawAvailable = ProductBuildProfile.runtimeRawMouse && testNapi.hardwareRawMouseAvailable()
    if (!processRouteInitialized) {
      // 子快照可能已包含父侧“关闭、待重启”的新偏好，但本局是已派发的独立进程。
      // 只在快照角色及 native 当前 PID 持锁事实同时成立时确认实际路线，不盲信偏好或布尔 Want。
      if (ProcessPreferences.isGameProcess()) {
        if (testNapi.desktopGameProcessState(context.filesDir, 0) !== 1) {
          throw new Error('无法确认独立游戏进程身份')
        }
        activeTabletIsolation = true
      } else {
        activeTabletIsolation = RuntimeProductProfile.canChooseTabletProcess()
          ? preferences.tabletIndependentGameProcess : false
      }
      processRouteInitialized = true
      AppLogger.info('GameProcess', 'Process route locked: tabletIsolation=' + activeTabletIsolation
        + '; gameSnapshot=' + ProcessPreferences.isGameProcess(), LOG_DOMAIN_LAUNCH)
    }
    // 一次性开发标记已退役：既不读取也不消费，不能覆盖用户明确保存的关闭值。
    selection = undefined
  }

  static selection(): ProductRuntimeSelection {
    if (selection === undefined) {
      activeInteraction = interaction
      selection = ProductRuntimePolicy.resolve(ProductBuildProfile.family,
        deviceInfo.deviceType, deviceInfo.sdkApiVersion, interaction,
        rawAvailable, activeTabletIsolation)
    }
    return selection
  }

  static current(): ProductInputDecision {
    return RuntimeProductProfile.selection().input
  }

  static freeze(): void {
    if (!RuntimeProductProfile.selection().supported) {
      throw new Error('当前产品不支持此设备或系统版本')
    }
    frozen = true
  }

  /**
   * 保存的是下一次可采用的交互选择。await期间不改desired/selection；Preferences原owner
   * 的读屏障也阻止initialize从未确认缓存取得新值。持久成功以后再次核frozen：若等待中
   * 已启动本局，则只更新已保存desired，保留原selection对象与activeInteraction。
   * false表示原路线冻结、需重启，并不表示写盘失败；写盘失败由Promise拒绝交给原UI。
   */
  static async setInteraction(value: string, context: Context): Promise<boolean> {
    if (!ProductBuildProfile.touchControls) return false
    const mode: string = ProductRuntimePolicy.normalizeInteraction(value)
    await new PreferenceManager(context).saveDesktopInteraction(mode)
    interaction = mode
    if (frozen) return false
    selection = undefined
    return true
  }

  static interaction(): string { return interaction }
  static interactionPending(): boolean { return frozen && interaction !== activeInteraction }
  static canChooseInteraction(): boolean {
    return ProductBuildProfile.touchControls && deviceInfo.deviceType === '2in1'
  }
  /** 设置开关只对平台和产品均支持的真实平板开放；不改变电脑固定隔离与手机页面路线。 */
  static canChooseTabletProcess(): boolean {
    return ProductRuntimePolicy.supportsTabletIsolation(ProductBuildProfile.family,
      deviceInfo.deviceType, deviceInfo.sdkApiVersion)
  }
  static supportsTouchLayouts(): boolean { return ProductBuildProfile.touchControls }
}

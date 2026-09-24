import { DesktopGameResults } from '../runtime/DesktopGameResults'
import { GameLaunchGate } from '../runtime/GameLaunchGate'
import { ProcessPreferences } from 'commons'
import { DesktopFileDrop } from '../runtime/DesktopFileDrop'
import { DiagnosticPolicy } from 'commons'
/**
 * McGamePage.ets — MC 全屏渲染页面（横屏）
 *
 * 流程：强制横屏 → XComponent 全屏 → OnSurfaceCreated → 启动 MC → 渲染
 * 触摸事件由 XComponent native DispatchTouchEvent 回调直接处理（render.cpp）
 */
import { AppLogger, ActivityLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
// 活动账本（L3）：游戏会话也是一条活动，与下载/安装共用同一套账本
// （ActivityCategory 本文件下方已 import，不再重复引入）
import { ledgerBegin, LedgerBeginMeta, ledgerHas, ledgerEnd, LedgerState, LedgerOutcome } from 'commons';
import { enrichSessionEnvironment } from '../runtime/SessionEnvironmentCollector';
import { ProductRenderDiagnostics } from 'entry/ProductRenderDiagnostics';
import testNapi from 'libentry.so';
import display from '@ohos.display';
import { ProductGameControlSurface } from 'entry/ProductGameControlSurface';
import { ProductGameWindowCoordinator, ProductGameWindowSnapshot } from 'entry/ProductGameWindowCoordinator';
import { ProductInputProfile } from 'entry/ProductInputProfile';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { GLFW_KEY_ESCAPE, GLFW_PRESS, GLFW_RELEASE } from 'gamecontrol';
import { getLayoutStore } from 'gamecontrol';
import { glfwKeyFromOhos, resolvePhysicalKeyCodepoint } from 'gamecontrol';
import { composeGlfwMods, composeOhosLockState } from 'gamecontrol';
import { PhysicalHeldKeyTracker, HeldKeyDownKind } from 'gamecontrol';
import { decidePhysicalKeyEdge, PhysicalKeyEdgeActions, SHADOW_KEY_UP } from 'gamecontrol';
import { shouldSuppressBackPressAfterEsc, shouldRefillChar } from 'gamecontrol';
import { normalizeDeviceId } from 'gamecontrol';
import { WheelStepAccumulator, wheelDirectionFromAxisVertical } from 'gamecontrol';
import { WHEEL_PAN_TAG, judgeWheelPanGesture, WheelPanJudgement } from 'gamecontrol';
import { normalizeRelativeMouseDelta, RelativeMouseDelta } from 'gamecontrol';
import { GamepadManager, GamepadEmitter, routeKeyToGamepad } from 'gamecontrol';
import { getInputDeviceMonitor, DeviceCapability, DeviceGamepadKind } from 'gamecontrol';
import { getPhysicalPointerEcho, getImeActivationGate } from 'gamecontrol';
import {
  DeviceChangeEvent, deviceCapabilityBitsFromSources, InputDeviceClass,
  InputDeviceDescriptor, normalizeMonotonicTimestampNs,
  pointerDeviceClassFromSourceTool, pointerDeviceClassFromSources
} from 'gamecontrol';
import { getInputSourceRegistry, AmclInputSource, InputEnd, CallbackInputEnd } from 'gamecontrol';
import { DeviceInventoryPublicationGuard } from 'gamecontrol';
import { ProductInputDecision } from 'gamecontrol';
import {
  InputSurfaceContext,
  INPUT_SURFACE_FIELD_DENSITY,
  INPUT_SURFACE_FIELD_DISPLAY,
  INPUT_SURFACE_FIELD_RECT,
  INPUT_SURFACE_FIELD_REFRESH_RATE,
  getInputSurfaceContextStore
} from 'gamecontrol';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { getPointerVisibility } from 'gamecontrol';
import { common, appRecovery, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { GraphicsProfileInput, GraphicsGameApi, LaunchProfileBuilder, LaunchProfile } from 'launch';
import { MinecraftGraphicsPreferenceInput, MinecraftGraphicsRequest, resolveMinecraftGraphicsRequest,
  minecraftGraphicsBackendForProfile } from 'launch';
import { prepareGraphicsProfileInput } from '../runtime/GraphicsCapabilityAdapter';
import { GraphicsHistoryStore, GraphicsHistoryOutcome } from '../runtime/GraphicsHistoryStore';
import { GraphicsLaunchFailure, parseGraphicsLaunchFailure, graphicsLaunchFailureMessage } from '../runtime/GraphicsLaunchFailure';
import { GraphicsRecoveryStore } from '../runtime/GraphicsRecoveryStore';
import { verifyLwjglRuntimeSlot } from 'launch';
import { GraphicsRecoveryTicket, GraphicsRecoveryFailure, GraphicsRuntimeState, graphicsFailureRetryable,
  graphicsRecoveryCandidate, parseGraphicsRuntimeState } from '../runtime/GraphicsRecoveryPolicy';
import { RuntimeDeployer } from 'launch';
import { SUPPORTED_JDK_VERSION, SUPPORTED_JDK_VERSIONS } from 'commons';
import { getAccountManager } from 'account';
import { AccountType } from 'account';
import { AuthlibInjectorAccount, YggdrasilApi, RealHttpClient } from 'account';
import { AUTHLIB_INJECTOR_JAR_NAME, encodeStandardBase64, stringToUtf8 } from 'commons';
import { formatError } from 'commons';
import { SessionMarker } from 'launch';
import { PreferenceManager } from 'feature_system';
import { getDownloadHistoryStore, ActivityCategory, ActivityStatus, ActivityRecord } from 'feature_core';

const TAG = LogTags.PAGE_MC_GAME;

/** 启动页传入的稳定路由字段；用命名属性避免 ArkTS 动态下标访问。 */
interface McGameRouteParams {
  activityId?: number;
  mcVersion?: string;
  mcDir?: string;
}
// `AmclGate0ArktsMousePresence` 镜像（`cpp/platform/gate0_input_telemetry.h`）。
// 只影响 Gate 0 取证日志的判读，不参与任何路由决策 —— 错位的后果是"证据看起来自洽
// 但指向错的结论"，比功能失效更难发现。
const GATE0_ARKTS_DEVICE_PRESENT: number = 1 << 0
const GATE0_ARKTS_GLOBAL_PRESENT: number = 1 << 1
const GATE0_ARKTS_RAW_PRESENT: number = 1 << 2
const GATE0_ARKTS_PRESSED_BUTTONS_PRESENT: number = 1 << 3
// ⚠️ 墓碑: `WHEEL_PAN_TAG` 已上移到 `gamecontrol/WheelChannel.ets`（计划 §73）——
// 它与 `judgeWheelPanGesture` 是一对必须同字符串的镜像，放在同一文件里才不会各改一半。

// 滚轮通道编号，必须与 native 的 AmclInputChannel（input_channel_policy.h）一致。
// 只列 ArkTS 侧持有的两条；native 侧那两条由 C++ 自己申报。
const WHEEL_CHANNEL_ARKTS_AXIS: number = 5
const WHEEL_CHANNEL_AXIS_PAN: number = 6

// `AmclCursorLockResult` 镜像（`cursor_lock.h`）。⚠️ **刻意只镜像会被分支的取值**：
// native 那侧到 4（`AMCL_CURSOR_LOCK_PLATFORM_ERROR`），这里只有"成功"与"无变化"两个
// 成功码，其余一律走
// 诊断分支。不要为了"补齐枚举"把剩下的值加进来 —— 那会造出新的零读者常量。
//
// ⚠️ 墓碑: `CURSOR_LOCK_UNSUPPORTED` 已删除（零读者；取值 2 的含义只出现在诊断日志
// 文案里，不参与判断），详见计划 §65.1。
const CURSOR_LOCK_OK: number = 0
const CURSOR_LOCK_UNCHANGED: number = 1

// `AmclWindowInputFilterResult` 镜像（`window_event_filter.h`）。同上，**刻意部分**：
// native 那侧到 5（`AMCL_WINDOW_INPUT_FILTER_NO_TOOLTYPE`），这里只镜像两个成功码。
const WINDOW_FILTER_OK: number = 0
const WINDOW_FILTER_UNCHANGED: number = 1

// ProductInputConfigureResult 镜像。只接受 applied / identical；invalid 或
// process-latch conflict 都表示 ArkTS 产品身份与 native 已不一致，必须 fail loud。
const INPUT_PRODUCT_APPLIED: number = 0
const INPUT_PRODUCT_UNCHANGED: number = 1

// AmclLegacyPhysicalOutcome 中会维持/建立 native held 的结果。duplicate-down 表示 native
// 已有 owner，ArkTS 缓存也应继续视为 held；其余失败在 Down 时回滚页面缓存。
const PHYSICAL_KEY_EMITTED: number = 0
const PHYSICAL_KEY_HANDLED_NO_FINAL_EDGE: number = 1
const PHYSICAL_KEY_DUPLICATE_DOWN: number = 6
const PHYSICAL_KEY_TYPED_ROUTE_HANDLED: number = 11

// 已撤销的方案：用 `responseRegionList` 把鼠标从 XComponent 的命中链剔除。
// 真机否证记录见 build() 里 XComponent 上那段注释——属性生效了（合成包消失），
// 但左键随之彻底消失，因为合成流是本机左键的唯一载体。不要再加回来。

@Entry
@Component
struct McGamePage {
  @State statusText: string = '正在初始化渲染面...'
  @State mcStarted: boolean = false
  @State mcLog: string = ''
  @State showLog: boolean = false
  @State @Watch('onGrabbedChanged') isInGame: boolean = false
  @State surfaceContextGeneration: number = 0
  @State pageInputActive: boolean = true
  private pageVisible: boolean = true
  private surfaceFocused: boolean = true
  private gameWindowReady: boolean = false
  private mcDir: string = ''
  private navigatedAway: boolean = false  // 防止多次 router.back()
  // 方案 B 修复（2026-07-11）：grabbed 状态兜底轮询计时器。onGrabChange 的 native 推回调
  // 在真机上不一定触发（跨 .so 反向 env 句柄机制未验证可用），导致进世界后 isInGame 卡在 false、
  // 游戏内按键（摇杆/跳跃/攻击等 game 场景控件）全部不显示。恢复低频轮询 isGrabbed() 作为可靠兜底，
  // 回调若能工作则提供即时响应、轮询只是补齐；二者取或，互不冲突。
  private grabPollTimer: number = -1
  // 游戏窗口 id，用于 OH_WindowManager_LockCursor。0 表示尚未取到。
  private gameWindowId: number = 0
  private gameDisplayId: number = -1
  private nativeSurfaceContextGeneration: number = 0
  // 页面协调器拥有输入几何；桌面系统桥随 GameAbility Window 存活。
  private gameWindowCoordinator: ProductGameWindowCoordinator = new ProductGameWindowCoordinator()
  private windowRestorePromise: Promise<void> | undefined = undefined
  private windowLifecycleGeneration: number = 0
  private windowRestoreRequestedForHide: boolean = false
  private windowResumeInFlight: boolean = false
  private windowResumeQueued: boolean = false
  // source-set 编译期身份 × runtime API 的不可变决定。所有桌面特例只读这一份，
  // native 会从同一对 (productKind, runtimeApi) 重新推导并锁存策略。
  private inputProduct: ProductInputDecision = ProductInputProfile.current()
  // 只在首次不支持/被拒时打一条日志，避免 250ms 对账把日志刷满。
  private cursorLockDiagnosed: boolean = false

  // 活动记录（操作时间线 · 阶段2）：仅记录【启动失败】（没起 JVM / 没写 SessionMarker 的前置失败）。
  // 启动成功后的正常退出/崩溃由 Index 会话恢复处统一补记（SIGABRT 杀 app，本页写不了）。
  private launchStartedAt_: number = 0
  private launchRecorded_: boolean = false  // 防同一次启动重复记录
  private gameLaunchGate: GameLaunchGate = new GameLaunchGate()
  private launchLifecycleEpoch: number = 0

  // 阶段 4.3 / 4.4 物理键鼠：实体键盘 held 缓存。
  //
  // Phase 3.3：由不带设备维度的 Set<number> 改为按 (deviceId, keyCode) 追踪，与 native
  // InputStateCore 的 HeldId 同维度。旧结构在两把实体键盘同时按同一个键时会把第二把的
  // Down 误判成 Repeat，并让先抬起的那把提前释放聚合键（计划 §10.1 / P0-2）。
  // 修饰键仍取跨设备聚合快照，锁存键不参与聚合（见 composeGlfwMods 注释）。
  private heldKeys: PhysicalHeldKeyTracker = new PhysicalHeldKeyTracker()
  // Phase 3.2：native 是 held/reset 的权威所有者；页面缓存只服务修饰键和 repeat 分类。
  // blur/overflow/surface reset 可在页面不 hide 时清 native 状态，因此每个实体键事件先比较
  // 完整 cancel 后发布的单调 epoch。变化时丢弃缓存，禁止恢复后的首个 Down 被误标 Repeat。
  private inputResetEpoch: string = ''
  // 异步初始设备清点不能在页面/session 销毁后继续向新生命周期发布 ADDED。
  // aboutToDisappear 递增；promise 续体只接受捕获到的同一代。
  private inputLifecycleEpoch: number = 1
  // getDeviceList 是异步快照；实时 REMOVED 必须压过迟到的 inventory ADDED。
  // 纯状态门禁按设备记录最后边沿及代次，规则由独立 ArkTS 单测覆盖。
  private deviceInventoryGuard: DeviceInventoryPublicationGuard =
    new DeviceInventoryPublicationGuard()

  // v3 手柄打底：GamepadManager 把手柄按键 + 模拟轴归一化成 GLFW 事件。
  // emitter 把事件转成 NAPI 调用。配置来自活跃 LayoutProfile.gamepad（缺省走默认）。
  // 每一条都**申报手柄端身份**（sendSource* 系列），而不是用不带端标注的旧入口。
  // 三件实际后果：① native 的持有记录按端隔离，手柄的 RELEASE 不会拿走屏幕虚拟按键的
  // owner；② 拔手柄时可以只释放手柄端（releaseSourceHeld）；③ 右摇杆视角走手柄端自己的
  // 量纲归一系数，不再与触控 dragLook 共用一个标注（后者曾被记成 lookPad）。
  private gamepadEmitter: GamepadEmitter = {
    emitKey: (glfwKey: number, action: number): boolean => {
      try {
        return testNapi.sendSourceKeyEvent(
          AmclInputSource.Gamepad as number, glfwKey, 0, action, 0)
      } catch (e) { return false }
    },
    emitMouse: (glfwButton: number, action: number): boolean => {
      try {
        return testNapi.sendSourceMouseEvent(
          AmclInputSource.Gamepad as number, glfwButton, action, 0)
      } catch (e) { return false }
    },
    emitScroll: (dir: number): boolean => {
      try {
        return testNapi.sendSourceScrollEvent(AmclInputSource.Gamepad as number, 0, dir)
      } catch (e) { return false }
    },
    emitLookDelta: (dx: number, dy: number): boolean => {
      // A right-stick look sample is meaningful only while Minecraft owns
      // the captured gameplay surface.  Menus still receive focus-axis
      // notifications on some ArkUI builds; dropping them here prevents a
      // controller from moving the legacy menu cursor or accumulating a
      // stale camera delta while the page is not grabbed.
      if (!this.isInGame) return false
      try {
        return testNapi.sendSourceCursorDelta(AmclInputSource.Gamepad as number, dx, dy)
      } catch (e) { return false }
    }
  }
  private gamepad: GamepadManager = new GamepadManager(undefined, this.gamepadEmitter)

  /**
   * 物理键鼠端的 InputEnd 适配器。
   *
   * 这一端的 held 真相有两份：native core 的 owner（deviceId + 原生键码）与本页面的
   * `heldKeys` 缓存。native 侧由 `cancelAllInput` / focus / surface reset 负责，
   * 本适配器只清 ArkTS 那一份 —— 与既有 `onPageHide` 的行为逐位相同。
   *
   * 刻意**不**在这里逐键补发 RELEASE：native 的复位路径已经把 ledger 归零，再补发只会
   * 产生一批 ownerless 边沿，把真正的失步问题淹没在诊断噪声里。设备拔出那条路径才需要
   * 逐键补发（那里 native 还没复位），它保留在 handleDeviceChange 里。
   */
  // 两个方向都是 `heldKeys.clear()`：这一端的 ArkTS 侧**只有缓存、没有输出通道**
  // （边沿由 native core 的 owner 负责），所以"自释放"与"承认 native 已归零"恰好同一个动作。
  // 仍然显式传两个回调，而不是复用同一个函数引用 —— 让下一个读代码的人看到这是
  // 经过判断的相同，而不是漏写。
  private physicalKbmEnd: InputEnd = new CallbackInputEnd(
    AmclInputSource.PhysicalKbm, 'PhysicalHeldKeyTracker',
    (reason: string) => { this.heldKeys.clear() },
    (reason: string) => { this.heldKeys.clear() })
  // 触屏可能被 ArkUI 再合成为 MouseEvent；无物理鼠标时必须整条丢弃，避免绕过 Native 菜单事务。
  // Gate 0 evidence seam: ordinary product builds resolve this once to false,
  // so the mouse hot path performs only a local boolean branch. Diagnostic
  // builds observe the exact production .onMouse event before any route filter;
  // the native observer never submits or mutates input state.
  private gate0TelemetryEnabled: boolean = false
  private gate0DisplayDensity: number = 0

  // Phase E（键鼠适配 2026-05-29）：物理 ESC 的时间戳，用于 onBackPress 去抖。
  // OHOS NEXT 上某些设备物理键盘 ESC 会**同时**触发 onKeyEvent + onBackPress，
  // 导致 MC 收到两次 ESC（菜单弹出立刻被关）。记下 ESC down 的时间，窗口内
  // 再触发的 onBackPress 视为副作用，silent 不重发。
  // R4：去抖窗口统一为一个常量（文档与代码一致），并只在确有物理键盘时启用。
  private lastEscFromKeyAt: number = 0
  private physicalKeyRejectLogCount: number = 0
  private static readonly ESC_BACKPRESS_DEBOUNCE_MS: number = 250

  // Phase B（fix/input-system 键鼠适配）：监听设备插拔，capability 变化时同步光标可见性
  private capabilityListener: (c: DeviceCapability) => void = (c: DeviceCapability) => {
    getPointerVisibility().sync(this.isInGame, c.mouse)
  }

  // Phase 3.3：设备插拔 → 输入 owner 生命周期。与 capabilityListener 职责不同：
  // 后者只管虚拟按键显隐/光标可见性（聚合布尔量），这里管 native held owner 的
  // 按设备释放（需要具体 deviceId）。二者都订阅同一个进程级系统监听的页面扇出。
  private deviceChangeListener: (e: DeviceChangeEvent) => void = (e: DeviceChangeEvent) => {
    this.handleDeviceChange(e)
  }

  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility 缓存的
  // UIAbilityContext。下面所有 `this.context as common.UIAbilityContext` 现在
  // 已经是直接的 UIAbilityContext，可以去掉断言（保留以减少 diff，类型上等价）。
  // 详见 docs/guides/api-migration-2026-05.md。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;

  /**
   * DisplayManager 事件只负责通知；Coordinator 在 ArkTS 事件线程重新读取当前 Window 所属
   * display 的刷新率，再经 surface-context 同代快照显式传给 native 应用。这样不会从 native
   * DisplayManager 回调线程直接碰 XComponent；无有效刷新率时 native 仍保留默认显示查询兜底。
   */
  private displayChangeListenerRegistered: boolean = false
  private displayChangeListener: Callback<number> = (_displayId: number): void => {
    try {
      const snapshot: ProductGameWindowSnapshot = this.gameWindowCoordinator.snapshot()
      this.syncInputSurfaceContext(snapshot, 'display-change')
    } catch (e) {
      this.launchLogger_().warn(TAG, 'Display change surface-context query failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * McGamePage 是 ArkTS Window 快照到 native core 的唯一编排点。Coordinator/lease
   * 拥有采样与 generation，页面只把同一代完整发布给 native，并让旧 density/frame-hint
   * 兼容消费者也读这份事实。没有当前 Window 时不再用 default display 冒充。
   */
  private syncInputSurfaceContext(
    snapshot: ProductGameWindowSnapshot,
    reason: string
  ): void {
    const context: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
    if (context.generation <= 0 ||
        snapshot.contextGeneration !== context.generation) return
    this.publishStoredInputSurfaceContext(context, reason)
  }

  private publishCurrentInputSurfaceContext(reason: string): void {
    const context: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
    if (context.generation <= 0) return
    this.publishStoredInputSurfaceContext(context, reason)
  }

  private publishStoredInputSurfaceContext(
    context: InputSurfaceContext,
    reason: string
  ): void {
    this.surfaceContextGeneration = context.generation
    if (context.has(INPUT_SURFACE_FIELD_DISPLAY)) {
      this.gameDisplayId = context.displayId
    } else {
      this.gameDisplayId = -1
    }

    if (this.nativeSurfaceContextGeneration !== context.generation) {
      try {
        const accepted: boolean = testNapi.publishInputSurfaceContext(
          context.windowId, context.displayId, context.leftPx, context.topPx,
          context.widthPx, context.heightPx, context.density,
          context.refreshRateHz, context.transform, context.validFields,
          context.generation)
        if (accepted) this.nativeSurfaceContextGeneration = context.generation
      } catch (e) {
        // Older libentry has no additive publisher. Keep ArkTS consumers on the
        // same generation; the heartbeat retries after a compatible native is present.
        this.launchLogger_().warn(TAG, `Input surface native publish failed reason=${reason}`, e,
          LOG_DOMAIN_LAUNCH)
      }
    }

    try {
      const hasDensity: boolean = context.has(INPUT_SURFACE_FIELD_DENSITY)
      const densityPixels: number = hasDensity ? context.density : 0
      if (hasDensity) testNapi.setDisplayDensity(densityPixels)
      this.gate0TelemetryEnabled = testNapi.gate0InputTelemetryEnabled()
      this.gate0DisplayDensity = this.gate0TelemetryEnabled ? densityPixels : 0
      const hasRefresh: boolean = context.has(INPUT_SURFACE_FIELD_REFRESH_RATE)
      const frameHintApplied: boolean = hasRefresh
        ? testNapi.refreshOhosFrameRateHint(context.refreshRateHz) : false
      if (reason !== 'window-heartbeat' || DiagnosticPolicy.inputTraceEnabled()) {
        this.launchLogger_().info(TAG,
          `Input surface context: reason=${reason} generation=${context.generation} ` +
          `display=${this.gameDisplayId} rect=${context.leftPx},${context.topPx},` +
          `${context.widthPx}x${context.heightPx} density=${densityPixels} ` +
          `refresh=${context.refreshRateHz} valid=0x${context.validFields.toString(16)} ` +
          `native=${this.nativeSurfaceContextGeneration} frameHintApplied=${frameHintApplied}`,
          LOG_DOMAIN_LAUNCH)
      }
    } catch (e) {
      this.gate0TelemetryEnabled = false
      this.gate0DisplayDensity = 0
      this.launchLogger_().warn(TAG, `Input surface compatibility publish failed reason=${reason}`, e,
        LOG_DOMAIN_LAUNCH)
    }
  }

  private applyOhosFrameRatePreference(): void {
    let fpsCap: number = 0
    try {
      fpsCap = new PreferenceManager(this.context).ohosFrameRateCap
    } catch (e) {
      this.launchLogger_().warn(TAG, 'OHOS frame-rate preference read failed; using Auto', e, LOG_DOMAIN_LAUNCH)
    }

    try {
      const accepted: boolean = testNapi.setOhosFrameRateCap(fpsCap)
      this.launchLogger_().info(TAG,
        `OHOS scheduler cap injected: ${fpsCap === 0 ? 'auto' : fpsCap + ' Hz'} accepted=${accepted}`,
        LOG_DOMAIN_LAUNCH)
    } catch (e) {
      this.launchLogger_().warn(TAG, 'OHOS frame-rate cap injection failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  private registerDisplayChangeListener(): void {
    if (this.displayChangeListenerRegistered) return
    try {
      display.on('change', this.displayChangeListener)
      this.displayChangeListenerRegistered = true
      this.launchLogger_().info(TAG, 'Display change listener registered', LOG_DOMAIN_LAUNCH)
    } catch (e) {
      this.launchLogger_().warn(TAG, 'Display change listener registration failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  private unregisterDisplayChangeListener(): void {
    if (!this.displayChangeListenerRegistered) return
    try {
      display.off('change', this.displayChangeListener)
    } catch (e) {
      this.launchLogger_().warn(TAG, 'Display change listener removal failed', e, LOG_DOMAIN_LAUNCH)
    }
    this.displayChangeListenerRegistered = false
  }

  async aboutToAppear(): Promise<void> {
    const expectedLifecycleEpoch: number = this.inputLifecycleEpoch
    this.pageVisible = true
    this.gameWindowReady = false
    this.updatePageInputActive()
    this.configureNativeInputProduct()
    // ---- 三端平级：注册本页面拥有的两个端，并把 native 的按端接缝注入注册表 ----
    //
    // 触控虚拟按键端由 GameControls 自己注册（它才拥有那份 ArkTS 兼容状态）。
    // gamecontrol 是 HAR，不能直接依赖宿主的 libentry.so，所以 native 接缝必须由宿主注入。
    // 注入是幂等的：页面重建时 NAPI 对象不变，重复注入无副作用。
    getInputSourceRegistry().setNativeSink({
      releaseSourceHeld: (source: number) => {
        try { testNapi.releaseSourceHeld(source) } catch (e) { /* 老 native 兼容 */ }
      },
      noteSourceReset: (source: number) => {
        try { testNapi.noteSourceReset(source) } catch (e) { /* 老 native 兼容 */ }
      }
    })
    getInputSourceRegistry().register(this.gamepad)
    getInputSourceRegistry().register(this.physicalKbmEnd)
    // 先写入 cap 并监听模式变化：即使 XComponent 尚未创建，native 也会保存 cap，
    // OnSurfaceCreated 再用当时的真实刷新率应用；不存在启动期竞态窗口。
    this.applyOhosFrameRatePreference()
    this.registerDisplayChangeListener()

    // Phase 3.3：订阅 capability 与原始插拔事件。两者都必须在下面第一个 await
    // **之前**注册，并与 aboutToDisappear 成对退订。
    //
    // 必须在下面第一个 await **之前** 注册：aboutToAppear 是 async，若页面在 await
    // 未 resolve 时被退出，aboutToDisappear 会先执行，此时退订是空操作，续体恢复后
    // 才注册的监听器将永不退订，每次进出累加一个持有已销毁页面实例的闭包。
    // 与 aboutToDisappear 的 removeDeviceChangeListener 成对。
    getInputDeviceMonitor().addDeviceChangeListener(this.deviceChangeListener)
    getInputDeviceMonitor().addCapabilityListener(this.capabilityListener)
    getInputDeviceMonitor().refreshCapability()

    // 初始化布局存储（必须 await，GameControls.aboutToAppear 会 waitReady）
    await getLayoutStore().init(this.context)
    // 页面可能在 await 期间已经销毁。aboutToDisappear 已退订并推进 epoch；旧续体
    // 必须在触碰 Gamepad/window 前终止，尤其不能重新注册持有旧页面的闭包。
    if (expectedLifecycleEpoch !== this.inputLifecycleEpoch) return

    // v3 手柄打底：把活跃方案的手柄配置同步给 GamepadManager。
    // R2：look 灵敏度 / 倒置 Y 由 C 层 ohos_send_cursor_delta 统一处理，GamepadManager 不再需要。
    try {
      const ap = getLayoutStore().getActiveProfile()
      this.gamepad.updateConfig(ap.gamepad)
      this.gamepad.setMappedOutputEnabled(!(AppStorage.get<boolean>('nativeGamepadOutputActive') ?? false))
    } catch (e) { /* ignore，GamepadManager 自带默认兜底 */ }

    // 产品窗口事务必须串行 await。旧实现把三个 Promise 当同步调用，异步 reject 逃出
    // try/catch，且页面启动失败后没有恢复。source-set seam 现在同时拥有进入与幂等恢复。
    try {
      const windowSnapshot: ProductGameWindowSnapshot =
        await this.gameWindowCoordinator.enter(this.context)
      if (expectedLifecycleEpoch !== this.inputLifecycleEpoch) {
        await this.restoreGameWindow(
          this.gameWindowCoordinator, 'page-disposed-during-window-enter')
        return
      }
      this.gameWindowId = windowSnapshot.windowId
      this.syncInputSurfaceContext(windowSnapshot, 'window-enter')
      this.gameWindowReady = true
      this.updatePageInputActive()
      this.installWindowInputFilters()
      this.launchLogger_().info(TAG,
        `Game window entered: id=${windowSnapshot.windowId} display=${windowSnapshot.displayId} ` +
        `rect=${windowSnapshot.left},${windowSnapshot.top},${windowSnapshot.width}x${windowSnapshot.height}`,
        LOG_DOMAIN_LAUNCH)
    } catch (e) {
      this.gameWindowReady = false
      this.updatePageInputActive()
      await this.restoreGameWindow(this.gameWindowCoordinator, 'window-enter-failed')
      this.launchLogger_().warn(TAG, 'Game window enter failed; restored launcher window', e,
        LOG_DOMAIN_LAUNCH)
    }

  }

  private configureNativeInputProduct(): void {
    ProductInputProfile.freeze()
    const result: number = testNapi.configureInputProduct(
      this.inputProduct.productKind as number, this.inputProduct.runtimeApi)
    if (result !== INPUT_PRODUCT_APPLIED && result !== INPUT_PRODUCT_UNCHANGED) {
      throw new Error(
        `Native input product rejected: result=${result} ` +
        `product=${this.inputProduct.productKind} api=${this.inputProduct.runtimeApi}`)
    }
    this.launchLogger_().info(TAG,
      `Input product ready: product=${this.inputProduct.productKind} ` +
      `api=${this.inputProduct.runtimeApi} formalDesktop=${this.inputProduct.formalDesktop} ` +
      `compatDesktop=${this.inputProduct.compatibilityDesktop} ` +
      `touchFallback=${this.inputProduct.mobileTouchFallback} ` +
      `relative=${this.inputProduct.supportsRelativeMouse} ` +
      `hardwareRaw=${this.inputProduct.supportsHardwareRawMouse}`,
      LOG_DOMAIN_LAUNCH)
  }

  // ⚠️ 墓碑: 这里曾有一段"Phase B：grabbed 翻转时同步系统光标可见性"的 JSDoc，而它
  // 描述的功能在提案 D2 已搬到 `PointerVisibilityCoordinator`（HAR）。它当时既没跟着
  // 代码走、也没挂在任何方法上（三个 JSDoc 连续堆叠，只有最后一个会附着），
  // 所以是一段**孤立的假文档**。详见计划 §69.2。

  /**
   * 安装窗口级输入事件过滤器。契约与三个机制的关系见规范 §6.1。
   *
   * ⚠️ **装一次即可，不随 grab 翻转装卸**：菜单/游戏的区分在 native 回调里逐事件按光标锁
   * 状态判定。**菜单态必须放行** —— 本机左键从不出现在 `onMouse`，菜单点击只以合成包存在，
   * 无条件过滤会让鼠标点不了任何菜单。
   *
   * 装不上不是致命的（回到"滚轮运动学指纹 + 触摸镜像视角"的旧行为），所以这里只诊断、
   * 不阻断进入游戏。
   */
  private installWindowInputFilters(): void {
    if (this.gameWindowId <= 0) return
    try {
      const result: number = testNapi.installWindowInputFilters(this.gameWindowId)
      if (result === WINDOW_FILTER_OK || result === WINDOW_FILTER_UNCHANGED) {
        this.launchLogger_().info(TAG,
          `window input filters installed (windowId=${this.gameWindowId})`,
          LOG_DOMAIN_LAUNCH)
        return
      }
      // 失败不是致命的：过滤器只是"去掉一条多余的合成流"，不装则回到原有行为
      // （滚轮运动学指纹 + 触摸镜像视角），因此这里只诊断、不阻断进入游戏。
      this.launchLogger_().warn(TAG,
        `window input filter unavailable result=${result} ` +
        `(2=API<15 3=badWindowId 4=wmRejected 5=API<24 observeOnly)`,
        LOG_DOMAIN_LAUNCH)
    } catch (e) {
      this.launchLogger_().warn(TAG, 'installWindowInputFilters NAPI missing', e,
        LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * 游戏内锁定系统光标，菜单里释放。契约见规范 §6.1。
   *
   * ⚠️ **不得在 ArkTS 侧缓存锁状态，这里做的是无条件对账。** 状态的唯一所有者在 native：
   * 仅获焦窗口可锁、失焦时窗口管理器**自动解锁**。缓存一份就会重演指针可见性那个
   * "以为已隐藏、其实系统已恢复"的 bug。状态一致时 native 返回 `CURSOR_LOCK_UNCHANGED`，
   * 不触达窗口管理器，所以 4 次/秒的对账成本可忽略。
   */
  private syncCursorLock(): void {
    if (!this.inputProduct.supportsCursorLock) return
    if (this.gameWindowId <= 0) return
    const desired: boolean =
      this.mcStarted && this.isInGame && getInputDeviceMonitor().capabilityNow().mouse
    try {
      const result: number = testNapi.setCursorLocked(this.gameWindowId, desired)
      if (result === CURSOR_LOCK_OK || result === CURSOR_LOCK_UNCHANGED) return
      if (!this.cursorLockDiagnosed) {
        this.cursorLockDiagnosed = true
        this.launchLogger_().warn(TAG,
          `cursor lock unavailable result=${result} (2=device/API<22 unsupported)`,
          LOG_DOMAIN_LAUNCH)
      }
    } catch (e) {
      if (!this.cursorLockDiagnosed) {
        this.cursorLockDiagnosed = true
        this.launchLogger_().warn(TAG, 'setCursorLocked NAPI missing', e, LOG_DOMAIN_LAUNCH)
      }
    }
  }

  private onGrabbedChanged(): void {
    const cap = getInputDeviceMonitor().capabilityNow()
    getPointerVisibility().sync(this.isInGame, cap.mouse)
    this.syncCursorLock()
    // grabbed 翻转时释放手柄端的按下态（WASD / 按钮 / 扳机），
    // 避免"切到菜单后角色还在走 / 还按着攻击"。
    //
    // 只放手柄端，不动另两端：触控端的 grab 翻转由 GameControls 与 native 的
    // onGrabFlipCancel 各自处理（native 刻意让 external/physical owner 活过 grab 翻转），
    // 物理键鼠端在菜单里照常可用。这正是"按端复位"与"全局复位"的区别。
    getInputSourceRegistry().releaseEndsOfSource(AmclInputSource.Gamepad, 'grab-flip')
  }

  // 拦截系统返回手势 / Back 按键
  //
  // Phase E（键鼠适配 2026-05-29）：物理 ESC 在 onKeyEvent 已经发过 PRESS/RELEASE
  // 的情况下，onBackPress 不再重发，避免 MC 收到两次 ESC。
  // 触屏返回手势 / 系统 BACK 键（无物理键盘）走原模拟 ESC 路径。
  onBackPress(): boolean {
    if (!this.mcStarted) return false
    // R4：仅在确有物理键盘接入时，才把"刚发生的物理 ESC"视为 onBackPress 的副作用并抑制。
    // 纯触摸设备没有物理 ESC，不需要抑制，避免误吞真实的返回手势。
    const hasKeyboard = getInputDeviceMonitor().capabilityNow().keyboard
    const dt = Date.now() - this.lastEscFromKeyAt
    if (!this.inputProduct.allowPlatformBackGesture) {
      this.launchLogger_().info(TAG,
        `onBackPress consumed by desktop physical-input policy ` +
        `(recentPhysicalEsc=${hasKeyboard && dt <= McGamePage.ESC_BACKPRESS_DEBOUNCE_MS})`,
        LOG_DOMAIN_LAUNCH)
      return true
    }
    if (shouldSuppressBackPressAfterEsc(
          hasKeyboard, dt, McGamePage.ESC_BACKPRESS_DEBOUNCE_MS)) {
      this.launchLogger_().info(TAG, `onBackPress suppressed (recent physical ESC ${dt}ms ago)`, LOG_DOMAIN_LAUNCH)
      return true   // 消费事件，不重发 ESC
    }
    // 触屏 / 系统 BACK：发送 ESC（press + microtask release）
    this.launchLogger_().info(TAG, 'onBackPress -> simulate ESC (no recent physical ESC)', LOG_DOMAIN_LAUNCH)
    try {
      // 申报 `PlatformGesture`：系统返回键/返回手势**不属于三端任何一端**。
      // 刻意不硬塞进触控端 —— 那会让"触控端的按下态"包含一个用户根本没碰屏幕的边沿，
      // 按端复位时也就无从判断该不该放。
      //
      // 也刻意不再用 `None`：那是**告警值**（"这个调用点忘了申报"）。两种含义挤在同一栏
      // 会让 `untagged` 计数失去告警能力 —— 分不清"有人漏改"和"用户按了返回键"。
      const platformGesture = AmclInputSource.PlatformGesture as number
      testNapi.sendSourceKeyEvent(platformGesture, GLFW_KEY_ESCAPE, 0, GLFW_PRESS, 0)
      Promise.resolve().then(() => {
        try {
          testNapi.sendSourceKeyEvent(platformGesture, GLFW_KEY_ESCAPE, 0, GLFW_RELEASE, 0)
        } catch (e2) { /* ignore */ }
      })
    } catch (e) {
      this.launchLogger_().warn(TAG, 'Failed to send ESC key', e, LOG_DOMAIN_LAUNCH)
    }
    return true  // 消费事件，不退出页面
  }

  /** 按钮和既有退出轮询的统一 void 入口，异步返回请求失败不能产生未处理 Promise。 */
  private graphicsRecoveryTicket_: GraphicsRecoveryTicket | undefined = undefined
  private graphicsRecoveryNext_: string = ''
  private graphicsRecoveryAutomatic_: boolean = false
  private graphicsCurrentProfile_: string = ''
  private graphicsCurrentVersion_: string = ''
  private graphicsFaultHandled_: boolean = false
  private graphicsMetricsAt_: number = 0
  private graphicsHistoryScope_: string = ''
  private graphicsOutcomeSent_: boolean = false
  private graphicsFirstPresentAt_: number = 0
  // 成功启动后交由进程寿命持有 native fd，页面隐藏/前后台切换不能释放运行库读租约。
  private runtimeSlotLease_: string = ''

  /** 只将经过父快照验证的首尝试交回父进程。先 fsync 原因，再退出旧进程，绝不在本页重入 JVM。 */
  private requestGraphicsRecovery_(stage: string, code: string, frames: number, diagnosticInjected: boolean = false): boolean {
    this.reportGraphicsHistory_('startup-failed', stage, code, frames, diagnosticInjected)
    const ticket = this.graphicsRecoveryTicket_
    if (ticket === undefined || ticket.attempt !== 0 || !this.graphicsRecoveryAutomatic_
      || this.graphicsRecoveryNext_.length === 0 || !graphicsFailureRetryable(stage, code, frames)
      || AppStorage.get<boolean>('desktopGameProcess') !== true) return false
    try {
      const failure: GraphicsRecoveryFailure = { id: ticket.id, parentPid: ticket.parentPid,
        activityId: ticket.activityId, childPid: testNapi.desktopProcessId(), createdAt: Date.now(),
        profile: this.graphicsCurrentProfile_, nextProfile: this.graphicsRecoveryNext_, stage: stage,
        code: code, presentCount: frames, automatic: true,
        diagnosticInjected: diagnosticInjected || ticket.diagnosticInjected === true }
      GraphicsRecoveryStore.report(this.context.filesDir, failure)
      this.launchLogger_().warn(TAG, 'graphics_recovery_handoff ' + JSON.stringify(failure), undefined, LOG_DOMAIN_LAUNCH)
      AppLogger.flush()
      return true
    } catch (error) {
      this.launchLogger_().warn(TAG, 'Graphics recovery unavailable; original failure retained', error, LOG_DOMAIN_LAUNCH)
      return false
    }
  }

  /** 复用现有心跳消费异步致命故障。出帧后的故障保留游戏自身保存/退出流程，不强制重开世界。 */
  private pollGraphicsFailure_(exitAfterHandoff: boolean = true): void {
    if (!this.mcStarted || this.graphicsFaultHandled_) return
    try {
      const state: GraphicsRuntimeState | undefined = parseGraphicsRuntimeState(testNapi.mcGetGraphicsRuntimeFailure())
      if (state === undefined || state.failureSequence === 0 || state.pid !== testNapi.desktopProcessId()
        || state.profile !== this.graphicsCurrentProfile_) return
      this.graphicsFaultHandled_ = true
      this.statusText = '图形后端发生错误：' + state.failureStage + '（' + state.failureCode + '）'
      this.showLog = true
      this.recordLaunchFailure_(this.graphicsCurrentVersion_, this.statusText)
      const handedOff: boolean = this.requestGraphicsRecovery_('render', state.failureStage,
        Math.max(state.presentCount, state.failurePresentCount))
      if (handedOff && exitAfterHandoff) this.requestExit_()
    } catch (error) { this.launchLogger_().warn(TAG, 'Graphics fault observation failed', error, LOG_DOMAIN_LAUNCH) }
  }

  /**
   * UI心跳每5秒采集一次固定容量观测快照，量化计算和日志写入不进入游戏呈现线程。
   * 保留原有单调present证据格式；低帧率、暂停或采样关闭时也输出真实状态，不能靠
   * 帧数触发而让卡死无记录。退出前强制采集，调用失败不阻塞退出或影响游戏。
   */
  private collectGraphicsMetrics_(force: boolean = false): void {
    if (!this.mcStarted) return
    const now: number = Date.now()
    if (!force && now >= this.graphicsMetricsAt_ && now - this.graphicsMetricsAt_ < 5000) return
    this.graphicsMetricsAt_ = now
    try {
      const wire: string = testNapi.mcGetGraphicsRuntimeState()
      const state: GraphicsRuntimeState | undefined = parseGraphicsRuntimeState(wire)
      if (state === undefined || state.pid !== testNapi.desktopProcessId()
        || state.profile !== this.graphicsCurrentProfile_) return
      if (state.presentCount > 0 && this.graphicsFirstPresentAt_ === 0) this.graphicsFirstPresentAt_ = now
      if (state.failureSequence === 0 && state.presentCount >= 300 && this.graphicsFirstPresentAt_ > 0
        && now - this.graphicsFirstPresentAt_ >= 10000) this.reportGraphicsHistory_('presented', '', '', state.presentCount)
      this.launchLogger_().info(TAG, 'graphics_frame_stats ' + wire, LOG_DOMAIN_LAUNCH)
      this.launchLogger_().info(TAG, `graphics_present pid=${state.pid} selected_profile=${state.profile} ` +
        `api_family=${state.apiFamily} window_provider=${state.provider} ` +
        `surface_generation=${state.surfaceGeneration} present_count=${state.presentCount}`, LOG_DOMAIN_LAUNCH)
    } catch (error) { this.launchLogger_().warn(TAG, 'Graphics metrics collection failed', error, LOG_DOMAIN_LAUNCH) }
  }

  /** 单局回执只陈述已验证呈现/明确首帧前失败，由父进程确认退出后持久化为排序历史。 */
  private reportGraphicsHistory_(status: string, stage: string, code: string, frames: number,
    diagnostic: boolean = false): void {
    const ticket = this.graphicsRecoveryTicket_
    if (this.graphicsOutcomeSent_ || ticket === undefined || !this.graphicsRecoveryAutomatic_
      || this.graphicsHistoryScope_.length === 0 || diagnostic || ticket.diagnosticInjected === true
      || (status === 'startup-failed' && !graphicsFailureRetryable(stage, code, frames))) return
    const outcome: GraphicsHistoryOutcome = { id: ticket.id, parentPid: ticket.parentPid,
      childPid: testNapi.desktopProcessId(), activityId: ticket.activityId, createdAt: Date.now(),
      scopeHash: this.graphicsHistoryScope_, profile: this.graphicsCurrentProfile_, status: status,
      stage: stage, code: code, presentCount: frames, automatic: true, diagnosticInjected: false }
    try {
      GraphicsHistoryStore.report(this.context.filesDir, outcome); this.graphicsOutcomeSent_ = true
      this.launchLogger_().info(TAG, 'graphics_history_outcome ' + JSON.stringify(outcome), LOG_DOMAIN_LAUNCH)
    } catch (error) { this.launchLogger_().warn(TAG, 'Optional graphics history outcome deferred', error, LOG_DOMAIN_LAUNCH) }
  }

  private requestExit_(): void {
    this.doExit().catch((error: Error) => {
      this.launchLogger_().warn(TAG, 'Game exit handoff failed; native timeout retains the exit boundary',
        error, LOG_DOMAIN_LAUNCH)
    })
  }

  /**
   * 独立游戏在仍拥有前台身份时先请求返回 Entry，再确认 native 的退出握手。
   * mcForceExit 在 exitPending 时仅 ACK，真正的退出代码由 JVM hook 保留；无 pending
   * 则沿用原有立即退出。这里不等 JVM、不开新计时器，也不触碰任何 JVM 锁或销毁操作。
   */
  private async doExit(): Promise<void> {
    if (this.navigatedAway) return
    // JVM 可能比 250ms 心跳更快结束；返回父进程之前再消费一次明确的原生图形故障。
    this.pollGraphicsFailure_(false)
    this.collectGraphicsMetrics_(true)
    this.navigatedAway = true
    if (AppStorage.get<boolean>('desktopGameProcess') === true) {
      try {
        const parameters: Record<string, number> = { 'gameExitActivityId': this.launchStartedAt_ }
        const want: Want = { bundleName: 'com.amcl.launcher', abilityName: 'EntryAbility', parameters: parameters }
        this.launchLogger_().info(TAG, `AMCL_GAME_RETURN_BEGIN activityId=${this.launchStartedAt_}`, LOG_DOMAIN_LAUNCH)
        await this.context.startAbility(want)
        this.launchLogger_().info(TAG, `AMCL_GAME_RETURN_REQUESTED activityId=${this.launchStartedAt_}`, LOG_DOMAIN_LAUNCH)
      } catch (error) {
        // 拒绝前台请求不能让停机永久等待；原生记录仍可由后续冷启动/前台恢复消费。
        this.launchLogger_().warn(TAG, 'Foreground game could not return to launcher; exit journal retained',
          error, LOG_DOMAIN_LAUNCH)
      } finally {
        try { testNapi.mcForceExit() }
        catch (error) {
          this.launchLogger_().warn(TAG, 'Game exit acknowledgement failed; native timeout will finish exit',
            error, LOG_DOMAIN_LAUNCH)
        }
      }
      return
    }
    // 未经 PID/锁验证的同进程路线保留旧退出兜底，不借独立进程握手改变其生命周期。
    this.launchLogger_().info(TAG, 'doExit: shared-process exit fallback', LOG_DOMAIN_LAUNCH)
    try { testNapi.mcForceExit() } catch (e) { /* ignore */ }
    try { appRecovery.restartApp() } catch (e) { /* ignore */ }
  }

  /**
   * 250ms 页面心跳。名字只说了它最初的用途（grabbed 兜底轮询），**实际是六件事的唯一载体**
   * —— 别照名字推断作用域（规范 §七 有同样的警告）。
   *
   * ⚠️ **不得为其中任何一件新开第二个定时器。** 这个项目已经删掉过两个"常驻 worker +
   * mutex + condvar"子系统，代价是它们把自己拉进了全局锁序。
   *
   * ⚠️ **`reconcileNativeResetEpoch` 必须留在这里**：另外两个调用点是物理按键事件与设备
   * 移除，于是纯触摸 + 手柄的设备上对账一次都不会跑（规范 §3.2）。这条心跳是唯一与输入
   * 设备类型无关的。
   *
   * 稳态成本：epoch 未变时一次返回字符串的 NAPI 调用；光标锁/指针可见性在状态一致时
   * 都是零跨进程调用。
   */
  private startGrabPoll(): void {
    if (this.grabPollTimer !== -1) return
    const tick = () => {
      if (this.navigatedAway) { this.grabPollTimer = -1; return }
      // ① grabbed 对账。native 推回调在真机上不一定触发，这条 read 是可靠兜底。
      try {
        const g: boolean = testNapi.isGrabbed()
        if (g !== this.isInGame) this.isInGame = g
      } catch (e) { /* ignore */ }
      // ①b 当前窗口 display 对账。自由窗口跨屏不一定伴随 default display change；
      // 复用既有 250ms heartbeat 读取完整 Window context，不新增定时器。publisher
      // lease 自己去重；native 发布失败时 generation 不前移，下一 tick 会重试。
      try {
        const snapshot: ProductGameWindowSnapshot = this.gameWindowCoordinator.snapshot()
        this.syncInputSurfaceContext(snapshot, 'window-heartbeat')
      } catch (e) { /* 下一 tick 重试 */ }
      // ② 光标锁**无条件**对账（失焦时被系统自动解除，不能只在 grab 翻转时设一次）。规范 §6.1
      this.syncCursorLock()
      // ③ 指针可见性的有界重申。"调用成功"不等于"已生效"（真机：日志显示
      //    setPointerVisible(false) 调过且没报错，光标却没隐藏），所以变更后 1 秒内重发几次。
      getPointerVisibility().tick()
      // ④ 钉住模式看门狗。返回 true = 刚降级回跟随模式，**必须重新加锁一次**新模式才生效
      //    —— 窗口管理器只在 lock 时读该参数，少这一步降级就不落地。
      try {
        if (testNapi.cursorLockWatchdogTick()) {
          testNapi.setCursorLocked(this.gameWindowId, false)
          this.syncCursorLock()
        }
      } catch (e) { /* 老 native 无此入口时保持现状 */ }
      // ⑤ native 复位与 ArkTS 三端缓存的对账（理由见本方法头注释与规范 §3.2）。
      this.reconcileNativeResetEpoch()
      // ⑥ 输入不变量自检。稳态零输出；账目失衡时 native 打一行 AMCL_INVARIANT error。
      try { testNapi.inputInvariantTick() } catch (e) { /* 老 native 兼容 */ }
      this.pollGraphicsFailure_()
      this.collectGraphicsMetrics_()
      this.grabPollTimer = setTimeout(tick, 250) as number
    }
    this.grabPollTimer = setTimeout(tick, 250) as number
  }

  onPageHide(): void {
    this.windowLifecycleGeneration++
    this.windowRestoreRequestedForHide = true
    this.pageVisible = false
    this.gameWindowReady = false
    this.updatePageInputActive()
    // 页面隐藏后 ArkUI 不保证继续派发 UP/CANCEL。
    //
    // 顺序纪律（见 InputSourceRegistry.ets）：**先让各端自己释放，再跑 native 兜底**。
    // 端自己发出的 RELEASE 需要与它自己的 PRESS 配对才能被 native 接受；反过来先跑
    // cancelAllInput 会把 ledger 清空，随后这些 RELEASE 全变成无配对边沿被丢弃 ——
    // 聚合结果仍是零，但日志里会多出一批 ownerless 边沿，掩盖真正的失步问题。
    //
    // 遍历注册表而不是逐个点名，是"三端平级"的直接体现：以后新增第四个端
    // （例如体感 / 远程串流）只需 register，所有边界自动覆盖它，不需要再改这里。
    getInputSourceRegistry().releaseAllEnds('page-hide')
    try { testNapi.cancelAllInput(2) } catch (e) { /* 老 native 兼容 */ }
    this.requestGameWindowRestore('page-hide')
  }

  onPageShow(): void {
    this.pageVisible = true
    if (!this.windowRestoreRequestedForHide) {
      this.updatePageInputActive()
      return
    }
    if (this.windowResumeInFlight) {
      this.windowResumeQueued = true
      return
    }
    this.startWindowResume()
  }

  private startWindowResume(): void {
    this.gameWindowReady = false
    this.updatePageInputActive()
    const expectedGeneration: number = ++this.windowLifecycleGeneration
    this.windowResumeInFlight = true
    this.resumeGameWindow(expectedGeneration).then((): void => {
      this.finishWindowResume()
    }).catch((e: Error) => {
      this.finishWindowResume()
      this.launchLogger_().warn(TAG, 'Game window resume failed', e, LOG_DOMAIN_LAUNCH)
    })
  }

  private finishWindowResume(): void {
    this.windowResumeInFlight = false
    if (!this.windowResumeQueued) return
    this.windowResumeQueued = false
    if (this.pageVisible && this.windowRestoreRequestedForHide) {
      this.startWindowResume()
    }
  }

  aboutToDisappear(): void {
    this.pageVisible = false
    this.gameWindowReady = false
    this.updatePageInputActive()
    this.windowLifecycleGeneration++
    this.windowResumeQueued = false
    // 先让异步 inventory 续体失效，再关闭 native owner；否则旧页面可能在 cancel 后
    // 向仍存活/新建的 session 补发过期 ADDED。
    this.inputLifecycleEpoch++
    this.unregisterDisplayChangeListener()
    this.gameDisplayId = -1
    // 同上的顺序纪律：先各端自释放，再 native 兜底。
    // 页面销毁早于/独立于 XComponent surface 回调；主动关闭 native owner，不能假设 surface lost 总会先到。
    getInputSourceRegistry().releaseAllEnds('page-dispose')
    try { testNapi.cancelAllInput(4) } catch (e) { /* 老 native 兼容 */ }
    // 方案 B 修复：停兜底轮询计时器
    if (this.grabPollTimer !== -1) { clearTimeout(this.grabPollTimer); this.grabPollTimer = -1 }
    // 必须显式解锁：光标锁是窗口级状态，页面销毁后系统不一定立刻释放，
    // 否则回到启动器界面会出现光标不动、无法操作 UI。
    if (this.gameWindowId > 0) {
      try { testNapi.setCursorLocked(this.gameWindowId, false) } catch (e) { /* 老 native 兼容 */ }
      // 窗口级过滤器同理：注册由窗口管理器持有，页面销毁后不摘掉，回调会继续被系统
      // 调用并指向已失效的窗口身份。
      try { testNapi.uninstallWindowInputFilters(this.gameWindowId) } catch (e) { /* 老 native 兼容 */ }
    }
    // 方案 B：注销 grabbed 回调（释放 native threadsafe function），避免页面销毁后
    // 回调仍持有已失效的闭包。传空参 = 注销。
    try { testNapi.onGrabChange() } catch (e) { /* ignore */ }
    // Phase B：取消监听 + 强制恢复光标可见，避免下个 app 接管时指针消失
    getInputDeviceMonitor().removeCapabilityListener(this.capabilityListener)
    getInputDeviceMonitor().removeDeviceChangeListener(this.deviceChangeListener)
    getPointerVisibility().restore()
    // 注销本页面拥有的两个端。必须在上面的 releaseAllEnds 之后：先放干净再摘掉，
    // 反过来会让这两个端的按下态永远没人释放。
    getInputSourceRegistry().unregister(this.physicalKbmEnd)
    getInputSourceRegistry().unregister(this.gamepad)
    // page-hide 与 dispose 可能连续到达；coordinator 返回同一条 restore Promise，
    // 不会重复 recover / 系统栏 / 方向操作。
    this.requestGameWindowRestore('page-dispose')
  }

  private async restoreGameWindow(
    coordinator: ProductGameWindowCoordinator,
    reason: string
  ): Promise<void> {
    try {
      await coordinator.restore()
      // endPublisher creates an explicit invalid generation. Publish it so
      // native/backend and generation-watched controls cannot retain an old
      // Window/display context after the page has gone away.
      this.publishCurrentInputSurfaceContext(`window-restored-${reason}`)
    } catch (e) {
      this.launchLogger_().warn(TAG, `Game window restore failed reason=${reason}`, e,
        LOG_DOMAIN_LAUNCH)
      throw e as Error
    }
  }

  private requestGameWindowRestore(reason: string): void {
    const coordinator: ProductGameWindowCoordinator = this.gameWindowCoordinator
    const pending: Promise<void> = this.restoreGameWindow(coordinator, reason)
    this.windowRestorePromise = pending
    pending.catch((e: Error) => {
      this.launchLogger_().warn(TAG, `Game window restore promise failed reason=${reason}`, e,
        LOG_DOMAIN_LAUNCH)
    })
  }

  private async resumeGameWindow(expectedGeneration: number): Promise<void> {
    const pending: Promise<void> | undefined = this.windowRestorePromise
    if (pending !== undefined) {
      try {
        await pending
      } catch (_) {
        await this.restoreGameWindow(
          this.gameWindowCoordinator, 'page-show-restore-retry')
      }
    }
    if (!this.pageVisible || this.navigatedAway ||
        expectedGeneration !== this.windowLifecycleGeneration) return
    const coordinator = new ProductGameWindowCoordinator()
    this.gameWindowCoordinator = coordinator
    const snapshot: ProductGameWindowSnapshot = await coordinator.enter(this.context)
    if (!this.pageVisible || this.navigatedAway ||
        expectedGeneration !== this.windowLifecycleGeneration) {
      await coordinator.restore()
      return
    }
    this.gameWindowId = snapshot.windowId
    this.nativeSurfaceContextGeneration = 0
    this.syncInputSurfaceContext(snapshot, 'page-show')
    this.installWindowInputFilters()
    this.windowRestoreRequestedForHide = false
    this.gameWindowReady = true
    this.updatePageInputActive()
  }

  private updatePageInputActive(): void {
    this.pageInputActive = this.pageVisible && this.surfaceFocused && this.gameWindowReady
    if (ProductInputProfile.selection().desktopWindow) testNapi.desktopGamepadFocus(this.pageInputActive)
  }

  // Touch events are now handled natively by XComponent's DispatchTouchEvent callback
  // (implemented in render.cpp → OnDispatchTouchEvent → input_bridge_ohos.c event queue)
  // No ArkTS overlay or NAPI sendTouchEvent needed.

  build() {
    Stack() {
      // MC 渲染区域
      XComponent({
        id: 'mc_game_surface',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%')
        .height('100%')
        // ⚠️ 这里曾用 `responseRegionList` 把鼠标从本组件的命中链剔除（FINGER/PEN 全区、
        // MOUSE 推到组件外），想借 `xcomponentAndWebOnly` 那条"按组件类型判定转换"的能力
        // 让左键回到 onMouse。**真机已否证，不要再加回来。**
        //
        // 证据（2026-08-19，`59JYD25815201311`）：属性确实生效了 —— `mirrorMove` 全程为 0
        // （普查的 mirrorMove 打点在分类阶段、早于任何视角产出，归零意味着合成触摸包真的
        // 不再抵达 XComponent），`AMCL_HITTEST` 在游戏态一次都没回调。但代价是
        // **左键彻底消失**：`AMCL_MOUSEIN` 每一行的 actions[1]=Press、actions[2]=Release
        // 全为 0，`btnArkui`/`btnMirror`/`btnNative` 三条通道整段缺席。
        //
        // 原因很清楚：本机左键的唯一载体就是那条合成触摸流。把鼠标从命中链剔除之后，
        // 合成包没有了落点，而 ArkUI 并没有因此改为投递 onMouse ——
        // ⇒ 左键的转换发生在 ArkUI ingress，与命中链无关；命中链只决定合成包送给谁。
        // 剔除鼠标 = 既拿不到 onMouse 左键，又丢掉合成流，净损失。
        // 决定性诊断：onTouchIntercept 运行在**命中测试阶段**，官方原文说它可"根据事件在
        // 控件上按下时的位置、**输入源**等事件信息决定 HitTestMode"。它是唯一能在 ArkTS 侧
        // 看清"鼠标左键合成出来的那一包，在命中测试时被框架标成什么来源"的接口。
        //   · 若这里看到 source=Mouse ⇒ 合成发生在命中测试之后，剔除 MOUSE 能连合成流一起断；
        //   · 若看到 source=TouchScreen/tool=Finger ⇒ 合成早于命中测试，热区改不了合成侧，
        //     必须立刻停止在热区方向投入。
        // 返回 Default 表示不改变行为，纯观测。频率极低（命中测试只在 DOWN 发生），
        // 但仍然限流，避免异常情况下刷屏。
        .onTouchIntercept((e: TouchEvent): HitTestMode => {
          if (DiagnosticPolicy.inputTraceEnabled() && this.surfaceHitTestProbeCount < 40) {
            this.surfaceHitTestProbeCount++
            this.launchLogger_().info(TAG,
              `AMCL_HITTEST xc src=${e.source} tool=${e.sourceTool} ` +
              `grabbed=${this.isInGame ? 1 : 0}`,
              LOG_DOMAIN_LAUNCH)
          }
          return HitTestMode.Default
        })
        .allowDrop(['general.file-uri', 'general.file'])
        .onDrop((event: DragEvent): void => { this.receiveDesktopDrop(event) })
        .onLoad(() => {
          this.launchLogger_().info(TAG, 'XComponent onLoad', LOG_DOMAIN_LAUNCH)
          this.statusText = '渲染面就绪，正在启动 MC...'
          setTimeout(() => {
            this.startMC().catch((e: Error) => {
              this.launchLogger_().warn(TAG, 'startMC promise failed', e, LOG_DOMAIN_LAUNCH)
            })
          }, 500)
        })
        .onDestroy(() => {
          this.launchLogger_().info(TAG, 'XComponent destroyed', LOG_DOMAIN_LAUNCH)
        })

      // 触摸事件主路径：XComponent native DispatchTouchEvent 回调 (render.cpp)
      // 备用路径：ArkTS onTouch 直接绑在 XComponent 上（文档说 libraryname 存在时不生效，
      // 但作为诊断保留，如果 native 回调不工作可以切换到覆盖层方案）

      // 状态叠加（启动前/出错时显示）
      if (!this.mcStarted) {
        Column() {
          Text(this.statusText)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 12 })
          Button('返回')
            .type(ButtonType.Capsule)
            .width(100)
            .height(32)
            .fontSize(13)
            .backgroundColor('#666666')
            .onClick(() => { this.requestExit_() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#CC000000')
      }

      // 产品控制面：手机/平板 target 编译触控 GameControls；desktop target 编译纯实体键鼠控制面。
      if (this.mcStarted) {
        ProductGameControlSurface({
          isGrabbed: this.isInGame,
          surfaceContextGeneration: this.surfaceContextGeneration,
          pageActive: this.pageInputActive
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // ============= 物理键鼠 + 手柄监听 =============
    // 平台 API 已对照本机 SDK 核实（依据 docs/guides/input-system-unified-direction-2026-05-29.md
    // §2.1/§2.3/§2.4 —— ⚠️ 那份文档已**部分**过期，见它头部的横幅；当前契约以
    // docs/refactor/输入架构规范.md 为准）：
    //   onKeyEvent（键盘 + 手柄按键）/ onMouse（鼠标按键由 native，Move 用 rawDelta）/
    //   onFocusAxisEvent（手柄摇杆+扳机，AxisModel since 15）。
    // ⚠️ onAxisEvent 仍然挂着，但**它不是本机的滚轮载体** —— 两台已知设备上都是零调用
    // （详见下方滚轮那段）。挂着的理由是它只是四条滚轮候选通道之一，谁赢由运行期仲裁决定。
    // 全部 try/catch 兜底，不影响触摸主路径。
    .focusable(true)
    .defaultFocus(true)
    .onFocus(() => {
      this.surfaceFocused = true
      this.updatePageInputActive()
    })
    .onBlur(() => {
      // Window/page focus loss must close the formal desktop IME session; the
      // zero-sized DesktopPhysicalTextInput itself never requests ArkUI focus.
      this.surfaceFocused = false
      this.updatePageInputActive()
    })
    // v3 手柄：focusScopeId(arrowStepOut=false) 屏蔽方向键 / 左摇杆走焦，
    // 让方向输入只用于游戏内操作而不是在 UI 控件间跳焦点。
    .focusScopeId('mc_game_focus', true, false)
    .onKeyEvent((e: KeyEvent) => {
      this.handleKeyEvent(e)
    })
    .onMouse((e: MouseEvent) => {
      this.handleMouseEvent(e)
    })
    .onAxisEvent((e: AxisEvent) => {
      this.handleAxisEvent(e)
    })
    // ============= 滚轮：认领"轴驱动的 Pan 手势" =============
    // 本机滚轮既不走 native AXIS 回调（注册成功、零样本），也不走 onAxisEvent（零调用）。
    // 平台把它归一化成**合成的手指滑动**投给 XComponent（MMI 的 axis-begin/end 次数与
    // 触摸 DOWN/UP 1:1 对齐，且期间触摸屏设备无任何上报），落在虚拟控件之外就被解释成
    // 空白 look —— 这就是"滚轮上下转视角"。
    //
    // 官方给了一条可判定的通道：`BaseGestureEvent.axisVertical`（since 12）**仅在**
    // 鼠标滚轮 / 触控板双指驱动的 Pan 手势上有值。因此这里用一个带 tag 的 PanGesture
    // 认领它，判据本体在 `gamecontrol/WheelChannel.ets` 的 `judgeWheelPanGesture`
    // （含失效方向与官方依据），由 `WheelChannel.test.ets` 穷举。这里只做枚举映射：
    // 除"是本通道的手势且非轴驱动"之外一律放行，子组件的手势不受影响。
    .onGestureJudgeBegin(
      (info: GestureInfo, event: BaseGestureEvent): GestureJudgeResult => {
        const verdict: WheelPanJudgement =
          judgeWheelPanGesture(info.tag, event.axisVertical)
        return verdict === WheelPanJudgement.RejectNotAxisDriven
          ? GestureJudgeResult.REJECT
          : GestureJudgeResult.CONTINUE
      })
    .gesture(
      // distance:1 让一格滚轮（本机实测约 90px 阶跃）立刻被识别。
      PanGesture({ direction: PanDirection.Vertical, fingers: 1, distance: 1 })
        .tag(WHEEL_PAN_TAG)
        .onActionStart((e: GestureEvent) => { this.onWheelPanStart(e) })
        .onActionUpdate((e: GestureEvent) => { this.onWheelPanUpdate(e) })
        .onActionEnd(() => { this.onWheelPanEnd() })
        .onActionCancel(() => { this.onWheelPanEnd() })
    )
    // v3 手柄：摇杆 / 扳机经焦点轴事件上报（AxisModel，since 15）。
    .onFocusAxisEvent((e: FocusAxisEvent) => {
      this.handleFocusAxisEvent(e)
    })
    // ⚠️ 墓碑: `.onHover` 绑定已删除（函数体为空，注册它只是让平台多派发一次回调），
    // 详见计划 §65.1。hover 的实际用途在 native：`onMouse` 的非 Move 分支已经覆盖
    // Hover/Enter/Leave（见 `handleMouseEvent` 那处早退）。
  }

  /**
   * 把 native 侧发生过的复位回灌到 ArkTS 三端（契约见规范 §三 / §3.3）。
   *
   * ⚠️ **必须走 `dropAllEndStateAfterNativeReset`，不能走 `releaseAllEnds`。**
   * 本函数挂在**每个物理按键事件**上，而后者允许 UI 副作用 ⇒ 会变成"按一下键盘，
   * 聊天输入条和抽屉莫名关掉"。且 `inputResetEpoch` 初值为空串，页面创建后第一次按键
   * **必然**命中这个分支（这不是罕见路径）。
   *
   * ⚠️ 调用点必须**保持三处**：物理按键事件、设备移除前、250ms 心跳。少了第三处，
   * 纯触摸 + 手柄的设备上这条对账一次都不会跑。
   */
  private reconcileNativeResetEpoch(): void {
    try {
      const epoch: string = testNapi.getInputResetEpoch()
      if (epoch.length > 0 && epoch !== this.inputResetEpoch) {
        const first: boolean = this.inputResetEpoch.length === 0
        this.inputResetEpoch = epoch
        // 首次观测只是**建立基准**，不代表刚刚发生过复位：页面刚创建时 ArkTS 侧本来
        // 就没有任何按下缓存，此时去丢弃缓存没有意义，只会白跑一遍三端。
        if (!first) {
          getInputSourceRegistry().dropAllEndStateAfterNativeReset('native-reset-epoch')
        }
      }
    } catch (e) {
      // 老 native 没有 getter 时维持旧兼容行为；page hide/dispose 仍显式清缓存。
      //
      // 边界（必须知道代价）：这条降级让 tracker 失去唯一的自愈机制。此后 native 侧
      // 的 blur/overflow/surface reset 不会再反映到页面缓存，页面可能比 core 多持有
      // held，直到 onPageHide / aboutToDisappear 显式 clear()。后果不是卡键——多余的
      // held 只会让该键的下一个 Down 被判 Repeat，core 按 ownerless REPEAT 记诊断并
      // 丢弃——但修饰键掩码会在这段时间内偏大。不做兜底猜测，只保留可诊断的降级。
    }
  }

  /**
   * 手柄端 `deviceId` 的真机取证探针（限量 24 条）。
   *
   * 为什么需要它：`GamepadManager` 已具备按设备分桶与跨设备输出聚合，但产品是否能把
   * `KeyEvent.deviceId` 当作稳定连接身份，仍必须由真机确认。身份不可用时会落入显式的
   * 单设备兼容桶；在证据闭合前不能把 inventory 编号域与事件编号域强行拼接。
   *
   * ⚠️ 注意它**不是**"拔键盘会放掉手柄按态"那条降级的前置条件 —— 那条已由 §63 用
   * `inputDevice` 自己的编号域修好（`handleDeviceChange` 的 `gamepadKindOf` 门控），
   * 刻意不依赖本探针的结论。这里问的是另一个问题：手柄端**内部**能否分桶。
   *
   * 这一条官方文档回答不了：`KeyEvent.deviceId` 的存在性是 A 级（API 11 起），但
   * 手柄事件里它是否可用、以及 `keySource` 的取值，文档页折叠未给出取值表。
   * 官方另有一条明确警告：同一物理设备**反复插拔或重启后 deviceId 可能变化**，
   * 所以它只能用作"本次连接期间"的身份 —— 那对我们够用（我们要的正是这个粒度）。
   *
   * 判读方式：
   *   · `dev=0` 出现 ⇒ 平台不给手柄事件的设备身份，按设备追踪**做不到**，
   *     只能退化为"单设备桶"，行为与现在一致；
   *   · `dev` 非零且同一手柄始终同一个值 ⇒ 前置条件成立，可以做；
   *   · 接两个手柄时两个值不同 ⇒ 收口后"拔一个不误放另一个"才真的可实现。
   *
   * 探针只在手柄按键的 Down/Up 边沿打，限量 24 条，稳态零噪声。
   */
  private gamepadIdentityProbeCount: number = 0

  private probeGamepadDeviceIdentity(e: KeyEvent): void {
    if (!DiagnosticPolicy.inputTraceEnabled()) return
    if (this.gamepadIdentityProbeCount >= 24) return
    this.gamepadIdentityProbeCount++
    try {
      const raw: number | undefined = e.deviceId as number | undefined
      const normalized = normalizeDeviceId(raw)
      this.launchLogger_().info(TAG,
        `AMCL_PADID key=${(e.keyCode as number) ?? 0} type=${e.type} ` +
        `rawDev=${raw} dev=${normalized} keySource=${e.keySource}`,
        LOG_DOMAIN_LAUNCH)
    } catch (err) {
      // 探针本身绝不能影响手柄可用性。deviceId 在某些 SDK 上可能根本不存在于
      // KeyEvent 上，读它抛异常时静默放弃这一条。
      this.launchLogger_().info(TAG, 'AMCL_PADID unavailable on this SDK', LOG_DOMAIN_LAUNCH)
      this.gamepadIdentityProbeCount = 24
    }
  }

  /**
   * 摇杆/扳机路径的 `deviceId` 取证探针（限量 24 条）。
   *
   * 为什么单独要一条：按键路径（`AMCL_PADID`）与摇杆路径是**两个不同的事件类型**，
   * 官方对它们的 deviceId 承诺也不同 —— `KeyEvent.deviceId` 是必选 `number`（API 11），
   * 而 `FocusAxisEvent` 继承 `BaseEvent`，`deviceId?: number`（API 12）**可选**、
   * 官方只承诺"默认值 0、取值范围 [0,+∞)"。所以按键路径取到了身份**不能**推出摇杆
   * 路径也取到了。此前只有按键那一半有探针，最可能失败的那一半反而没取证。
   *
   * `kind=` 是这条探针真正的目的：拿事件里的 deviceId 去查 `inputDevice` 编号域的手柄
   * 身份表。⚠️ **两个编号域是否相通官方从未说明**，所以它只是证据、不是结论，产品逻辑
   * 刻意不依赖它（规范 §3.4）。**逐字段判读方式见计划 §63.4**。
   *
   * 限量策略：前 8 条无条件打，之后只在出现**新的** dev 值时才打，总量封顶 24 ——
   * 否则摇杆一推就在几十毫秒内烧光配额，看不到第二个手柄。
   */
  private axisIdentityProbeCount: number = 0
  private axisIdentitySeenDevices: Set<number> = new Set<number>()

  private probeAxisDeviceIdentity(e: FocusAxisEvent): void {
    if (!DiagnosticPolicy.inputTraceEnabled()) return
    if (this.axisIdentityProbeCount >= 24) return
    try {
      // BaseEvent.deviceId 是可选字段，不能沿用 KeyEvent 那边的无判空写法。
      const raw: number | undefined = e.deviceId
      const normalized: number = normalizeDeviceId(raw)
      const fresh: boolean = !this.axisIdentitySeenDevices.has(normalized)
      if (!fresh && this.axisIdentityProbeCount >= 8) return
      this.axisIdentitySeenDevices.add(normalized)
      this.axisIdentityProbeCount++
      this.launchLogger_().info(TAG,
        `AMCL_PADAXIS rawDev=${raw} dev=${normalized} ` +
        `kind=${getInputDeviceMonitor().gamepadKindOf(normalized)} ` +
        `knownDevices=${getInputDeviceMonitor().knownDeviceCount()} ` +
        `axes=${e.axisMap.size} source=${e.source} distinct=${this.axisIdentitySeenDevices.size}`,
        LOG_DOMAIN_LAUNCH)
    } catch (err) {
      // 探针绝不能影响摇杆可用性。字段在某些 SDK 上可能不可读，抛异常时永久放弃。
      this.launchLogger_().info(TAG, 'AMCL_PADAXIS unavailable on this SDK', LOG_DOMAIN_LAUNCH)
      this.axisIdentityProbeCount = 24
    }
  }

  // ⚠️ 墓碑: `McGamePage.normalizeDeviceId` 已上移到 `gamecontrol/InputDeviceAbi.ets` 的
  // 同名导出（5 个调用点跨物理键鼠/手柄/设备生命周期三个方向，**不得**在任何一处复制第二份
  // 实现 —— 注释门禁抓不到纯函数漂移），详见计划 §68.1。契约与已知局限写在新落点。

  /**
   * 物理设备插拔 → 输入 owner 生命周期。完整因果见规范 §3.4 与计划 §10.1。
   *
   * ⚠️ **移除路径的四步顺序是承重的，不要重排**（改一处的后果都写在旁边）：
   *   1. 先 `reconcileNativeResetEpoch()` —— 否则下面补发的每个 UP 都是 ownerless；
   *   2. 再 `releaseDevice` 摘缓存 —— 先摘再发，否则补发的 UP 会被判成 Repeat；
   *   3. 逐键补 `physicalKeyTransaction(UP)` —— legacy edge router 没有"设备移除"入口，
   *      只能靠显式 UP 边沿释放；
   *   4. 最后 `publishInputDeviceChange(removed)` 作权威兜底（第 3 步成功时它幂等）。
   *
   * 新增设备只上报能力位，不触碰任何 held 状态。整段 try/catch：任何一步抛出都不能让
   * 系统回调失败，否则该次 remove 的其余监听器全部收不到。
   */
  private handleDeviceChange(e: DeviceChangeEvent): void {
    try {
      const deviceId = normalizeDeviceId(e.deviceId)
      if (deviceId === 0) {
        // 0 是"身份不可用"的共享桶，用它做移除会取消无关设备的 owner。
        this.launchLogger_().warn(TAG, `inputDevice change with unusable deviceId=${e.deviceId}`, LOG_DOMAIN_LAUNCH)
        return
      }

      // 必须先于 mcStarted 早退记录：设备可能在 session 建立前拔出，而启动 inventory
      // 的平台快照仍短暂包含它。墓碑让 REMOVED 赢过随后到达的迟到 ADDED。
      this.deviceInventoryGuard.noteRealtimeChange(deviceId, e.added)

      // MC 未启动时没有 native session，任何 publish 都只会被 ingress 记成 stale
      // consumer 噪声。但页面缓存仍要保持与现实一致，否则设备拔掉后它的 held 会留在
      // 修饰键聚合里。所以：只摘缓存，不触达 native。
      if (!this.mcStarted) {
        this.heldKeys.releaseDevice(deviceId)
        if (!e.added) {
          this.gamepad.dropHeldStateAfterNativeReset(
            `device-removed-before-session:${deviceId}`)
        }
        return
      }

      if (e.added) {
        // 实时 ADD 边沿本身已证明设备存在；详情暂时读取失败时仍发布 identity，
        // capability=0 只表示 advisory 未知，不应丢掉 DeviceRegistry 的生命周期边沿。
        const descriptor: InputDeviceDescriptor | undefined =
          this.readDeviceDescriptor(deviceId)
        const capabilities: number = descriptor?.capabilities ?? 0
        const deviceClass: InputDeviceClass = descriptor?.deviceClass ?? InputDeviceClass.Unknown
        try {
          testNapi.publishInputDeviceChange(
            deviceId, true, capabilities, deviceClass as number)
        } catch (e2) { /* 老 native 兼容 */ }
        return
      }

      // native 可能刚因 blur/overflow/surface reset 清过 held（页面不会 hide）。先对账
      // epoch：否则下面补发的每个 UP 都是 ownerless，core 与 legacy 各记一条无意义诊断。
      this.reconcileNativeResetEpoch()

      const released: number[] = this.heldKeys.releaseDevice(deviceId)
      // mods 在循环外算一次：releaseDevice 已经一次性摘掉该设备的**全部**键，循环期间
      // 聚合快照不再变化（跨设备仍按住的同一修饰键会正确保留）。放在循环内只是空转。
      // 锁存快照不可用——设备已拔，平台不会再报——传 0 = 未知，让 native 计
      // MissingField::LockState，而不是编造锁存位。
      const mods = composeGlfwMods(this.heldKeys.heldKeys(), 0)
      for (let i = 0; i < released.length; i++) {
        const ohosKey = released[i]
        const glfwKey = glfwKeyFromOhos(ohosKey)
        try {
          testNapi.physicalKeyTransaction(
            ohosKey, 0, 0, SHADOW_KEY_UP, mods, 0, deviceId, glfwKey, GLFW_RELEASE)
        } catch (e3) { /* 老 native 兼容；下一步的 device removed 仍是兜底 */ }
      }
      try {
        testNapi.publishInputDeviceChange(
          deviceId, false, 0, InputDeviceClass.Unknown as number)
      } catch (e4) { /* 老 native 兼容 */ }

      // 手柄按设备桶先做定向释放；事件 id 与 inventory id 的编号域若不一致，
      // 找不到桶时仍回退整端释放，保持原来的防卡键方向。
      //
      // 这次整端释放**按被拔设备的类型收口**（规范 §3.4）：只有已知"不是手柄"时才跳过。
      // `Unknown` 必须照旧释放 —— 判不出来时把它当"不是手柄"就是会卡键的那个方向。
      // ⚠️ 官方仍未声明 inventory 与 Key/FocusAxis 的编号域一致。key/axis 两类事件
      // 同值只作为探针，不授权产品定向释放；真机连接代证据闭合前仍保守释放整端。
      //
      const padKind: DeviceGamepadKind = getInputDeviceMonitor().gamepadKindOf(deviceId)
      if (padKind === DeviceGamepadKind.NotGamepad) {
        this.launchLogger_().info(TAG,
          `device ${deviceId} removed, known non-gamepad, gamepad end kept ` +
          `(pads=${getInputDeviceMonitor().knownGamepadCount()})`,
          LOG_DOMAIN_LAUNCH)
      } else {
        const reason: string = padKind === DeviceGamepadKind.Gamepad
          ? `device-removed-gamepad:${deviceId}`
          : `device-removed-unknown-kind:${deviceId}`
        getInputSourceRegistry().releaseEndsOfSource(AmclInputSource.Gamepad, reason)
        this.gamepad.dropHeldStateAfterNativeReset(reason)
      }

      if (released.length > 0) {
        this.launchLogger_().info(TAG, `device ${deviceId} removed, released ${released.length} held key(s)`, LOG_DOMAIN_LAUNCH)
      }
    } catch (err) {
      this.launchLogger_().warn(TAG, 'handleDeviceChange failed', err, LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * 读取设备能力位。取不到详情时返回 undefined：实时 ADD 调用方会降级为 0，初始
   * inventory 调用方则把它视为可能过期的快照并跳过。deviceId 才是 owner 域的关键，
   * 能力位只是给后端的 advisory 信息。
   *
   * sources 逐元素转成 string 后再交给纯映射函数：SDK 类型是 Array<SourceType>
   * （字面量联合），ArkTS 下数组级 `as string[]` 的合法性不确定，与
   * InputDeviceMonitor.refreshCapability 保持同一种写法。
   */
  private readDeviceDescriptor(deviceId: number): InputDeviceDescriptor | undefined {
    try {
      const info = inputDevice.getDeviceInfoSync(deviceId)
      const sources: string[] = []
      for (let i = 0; i < info.sources.length; i++) {
        sources.push(info.sources[i] as string)
      }
      const descriptor = new InputDeviceDescriptor()
      descriptor.capabilities = deviceCapabilityBitsFromSources(
        sources, this.inputProduct.supportsRelativeMouse,
        this.inputProduct.supportsCursorLock)
      descriptor.deviceClass = pointerDeviceClassFromSources(sources)
      return descriptor
    } catch (e) {
      return undefined
    }
  }

  /**
   * 启动期设备清点：把 MC 启动前就已接入的设备补报一次 ADDED。
   *
   * 为什么需要：inputDevice.on('change') 只覆盖热插拔，启动前已连接的键鼠永远不会
   * 触发它，core 的 DeviceRegistry 因此对这些设备为空，能力位在真机上基本走不到。
   * 这一次清点让 ADDED 的覆盖面与真实设备一致。
   *
   * 时机：必须在 mcStarted 之后（native session 已建立），否则 publish 只会被记成
   * stale consumer 噪声。实时边沿与该异步快照可能乱序，所以每个发布还必须通过
   * DeviceInventoryPublicationGuard：REMOVED 增加墓碑，inventory 开始后的任意边沿
   * 由实时路径负责，迟到续体不得重复发布。
   *
   * 失败恢复：整段吞异常。清点失败只丢能力位（advisory），不影响 owner 生命周期；
   * 下一次真正的插拔事件仍会补上该设备的能力位。
   */
  private publishInitialDeviceInventory(): void {
    const expectedLifecycleEpoch = this.inputLifecycleEpoch
    const expectedDeviceGeneration = this.deviceInventoryGuard.beginInventory()
    inputDevice.getDeviceList().then((ids: number[]) => {
      if (expectedLifecycleEpoch !== this.inputLifecycleEpoch || !this.mcStarted) return
      for (let i = 0; i < ids.length; i++) {
        if (expectedLifecycleEpoch !== this.inputLifecycleEpoch || !this.mcStarted) return
        const deviceId = normalizeDeviceId(ids[i])
        if (deviceId === 0) continue
        if (!this.deviceInventoryGuard.mayPublishAdded(deviceId, expectedDeviceGeneration)) continue
        const descriptor: InputDeviceDescriptor | undefined =
          this.readDeviceDescriptor(deviceId)
        // inventory 是快照，不是实时 add 边沿；详情读取失败通常表示设备已离开或
        // snapshot 已过期。此时跳过，禁止在真实 REMOVED 后重新制造迟到 ADDED。
        if (descriptor === undefined) continue
        if (!this.deviceInventoryGuard.mayPublishAdded(deviceId, expectedDeviceGeneration)) continue
        try {
          testNapi.publishInputDeviceChange(
            deviceId, true, descriptor.capabilities,
            descriptor.deviceClass as number)
        } catch (e) { /* 老 native 兼容 */ }
      }
    }).catch((err: Error) => {
      this.launchLogger_().warn(TAG, 'initial device inventory failed', err, LOG_DOMAIN_LAUNCH)
    })
  }

  private handleKeyEvent(e: KeyEvent): void {
    if (!this.mcStarted) return
    try {
      const ohosKey = (e.keyCode as number) ?? 0
      // Phase（fix/input-system §N4）：用 KeyType 枚举替代裸数字 1/2，避免 SDK 升
      // 级改变枚举值时静默失效。
      const isDown = e.type === KeyType.Down
      const isUp = e.type === KeyType.Up

      // v3 手柄：先看是不是手柄按键，是就交给 GamepadManager 归一化。
      //
      // Phase 3.3：DPAD 4 个方向码与实体键盘方向键共用 keyCode，过去被整条送进
      // GamepadManager，绕过了 physicalKeyTransaction / deviceId / 锁存快照 / core
      // held owner 与 reset 对账。现在只在平台明确报告 KeySource.Keyboard 时把它们
      // 交回 physical route；Unknown 保持旧手柄行为（判据与理由见 routeKeyToGamepad）。
      const sourceIsKeyboard = e.keySource === KeySource.Keyboard
      if (routeKeyToGamepad(ohosKey, sourceIsKeyboard)) {
        if (isDown || isUp) {
          this.probeGamepadDeviceIdentity(e)
          const gamepadDeviceId: number = normalizeDeviceId(e.deviceId)
          this.gamepad.handleButtonForDevice(
            gamepadDeviceId, ohosKey, isDown)
        }
        return
      }

      // Native blur/overflow may have reset authoritative held state without
      // causing ArkUI page hide. Reconcile before reading held/modifier state.
      this.reconcileNativeResetEpoch()

      // Phase 3.3：发布真实设备身份与平台锁存快照。
      //
      // deviceId 让 native 的 HeldId{deviceId,key} 真正按设备成立：两把实体键盘同时按
      // 同一个键会各自持有 owner，先抬起的那把不会提前释放聚合键；拔掉某把键盘时也只
      // 释放它自己的 owner。归一化到非负整数，拿不到时落 0，native trace 计 missing。
      const deviceId = normalizeDeviceId(e.deviceId)
      // 锁存状态只能来自平台。三个字段都缺失时 composeOhosLockState 返回 0（未知），
      // native 计 MissingField::LockState，GLFW mods 才退回"按住即锁定"的显式降级。
      const lockState = composeOhosLockState(e.isCapsLockOn, e.isNumLockOn, e.isScrollLockOn)

      // repeat 分类必须与 core 的 owner 维度一致：同一 (device,key) 的第二次 Down 是
      // 平台自动重复，不新增 owner；不同设备的同键 Down 是独立的首次按下。
      //
      // 为什么先记账再发 native（顺序有意）：mods 快照必须包含本次边沿的效果，
      // 否则按下 Shift 的那一帧自身不带 SHIFT 位。代价是 native 侧若拒收
      // （surface gate 关闭、physicalKeyTransaction 抛异常被下面 catch 吞掉），
      // 页面会比 core 多持有一个 held。恢复路径唯一：core 的 reset epoch 变化时
      // reconcileNativeResetEpoch() 清空缓存；页面 hide/dispose 也会清。期间该键的
      // 下一个 Down 会被判 Repeat，core 按 ownerless REPEAT 记诊断并丢弃，不会卡键。
      //
      // 未持有的 UP 仍然照常上报：native core 与 legacy edge router 各自记录
      // ownerless 诊断（§11 发布门禁第 1 条：不允许 silent drop），页面状态不变。
      // ArkTS 侧不再重复计数，避免出现第二个状态所有者。
      let downKind: HeldKeyDownKind | undefined = undefined
      if (isDown) {
        const kind: HeldKeyDownKind = this.heldKeys.noteDown(deviceId, ohosKey)
        downKind = kind
        if (kind === HeldKeyDownKind.FirstDownAfterStale) {
          // 缓存里的"按住"已陈旧（中间那个 Up 丢了）。按首次按下处理，让 native
          // 重新 acquire owner —— 否则这个键会永久发 REPEAT，而 native 那边已无 owner，
          // 边沿被整条丢弃，用户看到的就是"这个键失灵了"（ESC 快按后失效即此）。
          //
          // 必须留下痕迹：这是该故障唯一的自愈信号，静默自愈会让下次同类问题再次无迹可查。
          try { testNapi.noteKeyRepeatSelfHealed() } catch (e2) { /* 老 native 兼容 */ }
          this.launchLogger_().warn(TAG,
            `AMCL_KBD stale held self-healed ohosKey=${ohosKey} deviceId=${deviceId} ` +
            `(a lost UP left this key latched; re-issuing as first down)`,
            LOG_DOMAIN_LAUNCH)
        }
      } else if (isUp) {
        this.heldKeys.noteUp(deviceId, ohosKey)
      }
      // 修饰键取跨设备聚合的 held 快照 + 平台锁存位。锁存位不从 held 推断。
      const mods = composeGlfwMods(this.heldKeys.heldKeys(), lockState)
      // 两个输出平面的动作码由同一次判定产出，**必须同分类**：typed 判 REPEAT 而 legacy
      // 判 PRESS 会让 legacy edge router 多拿一个 owner 而 typed 不会，两侧从此永久不等，
      // 且不变量自检抓不到（各自都自洽）。契约与穷举见
      // `gamecontrol/PhysicalKeyEdge.ets` 与 `PhysicalKeyEdge.test.ets`。
      const edge: PhysicalKeyEdgeActions = decidePhysicalKeyEdge(isDown, isUp, downKind)
      if (!edge.shouldPublish) return

      const glfwKey = glfwKeyFromOhos(ohosKey)
      const shadowAction = edge.shadowAction
      const glfwAction = edge.glfwAction
      // One native call owns gate validation + typed publication + legacy
      // routing. Unknown GLFW mappings still publish raw typed identity and
      // are finalized as unmapped rather than disappearing.
      // hardwareScan / hidUsage 保持 0：ArkUI KeyEvent 不暴露这两项，属于 P0-7 未解部分。
      const physicalOutcome: number = testNapi.physicalKeyTransaction(
        ohosKey, 0, 0, shadowAction, mods, lockState, deviceId, glfwKey, glfwAction)
      const nativeOwnsDown: boolean =
        physicalOutcome === PHYSICAL_KEY_EMITTED ||
        physicalOutcome === PHYSICAL_KEY_HANDLED_NO_FINAL_EDGE ||
        physicalOutcome === PHYSICAL_KEY_DUPLICATE_DOWN ||
        physicalOutcome === PHYSICAL_KEY_TYPED_ROUTE_HANDLED
      if (isDown && !nativeOwnsDown) {
        // 页面先记账是为了让 Shift 本次 Down 自身带 mods；native 明确拒收后必须撤销，
        // 否则后续平台 repeat 会永久被误分成 ownerless REPEAT。
        this.heldKeys.noteUp(deviceId, ohosKey)
      }
      if (!nativeOwnsDown && physicalOutcome !== PHYSICAL_KEY_EMITTED &&
          this.physicalKeyRejectLogCount < 40) {
        this.physicalKeyRejectLogCount++
        this.launchLogger_().warn(TAG,
          `physical key transaction rejected outcome=${physicalOutcome} ` +
          `key=${ohosKey} device=${deviceId} down=${isDown} up=${isUp}`,
          LOG_DOMAIN_LAUNCH)
      }

      // Phase E（键鼠适配 2026-05-29）：物理键盘 ESC 在某些 OHOS 版本会同时触发
      // onBackPress（系统把它当 BACK 语义）。记下时间戳，让 onBackPress 在窗口
      // 内 silent 跳过，避免给 MC 发两次 ESC（菜单刚弹出又被关）。
      if (glfwKey === GLFW_KEY_ESCAPE && isDown) {
        this.lastEscFromKeyAt = Date.now()
        this.launchLogger_().info(TAG, `physical ESC down at ${this.lastEscFromKeyAt}, suppress onBackPress for ${McGamePage.ESC_BACKPRESS_DEBOUNCE_MS}ms`, LOG_DOMAIN_LAUNCH)
      }

      // 可打印字符 + 非 grabbed 状态：补发 char（菜单 / 命令打字）。
      // R3：IME 桥 / 系统输入法激活时跳过——输入法会先消费可打印键，应用再发 char 等于双发。
      // API14+ 优先使用 KeyEvent.unicode（当前实体键盘布局的事实）；平台没给时才退回
      // US KeyCode 表。char 与 GLFW key 映射正交，所以未映射物理键也不会提前 return。
      const cp: number = resolvePhysicalKeyCodepoint(e.unicode, ohosKey, mods)
      if (shouldRefillChar(isDown, cp > 0,
                           this.isInGame, getImeActivationGate().isActive())) {
        try { testNapi.sendCharEvent(cp) } catch (e2) { /* ignore */ }
      }

    } catch (err) {
      this.launchLogger_().warn(TAG, 'handleKeyEvent failed', err, LOG_DOMAIN_LAUNCH)
    }
  }

  // ============================================================
  private traceGate0MouseEvent(e: MouseEvent): void {
    if (!this.gate0TelemetryEnabled) return
    try {
      let presence: number = 0
      const devicePresent: boolean = e.deviceId !== undefined
      const globalPresent: boolean =
        e.globalDisplayX !== undefined && e.globalDisplayY !== undefined
      // 同一个判定函数（理由同 probeMouseEntry）。
      const rel: RelativeMouseDelta =
        normalizeRelativeMouseDelta(e.rawDeltaX, e.rawDeltaY)
      const rawPresent: boolean = rel.present
      const pressedButtonsPresent: boolean = e.pressedButtons !== undefined
      if (devicePresent) presence |= GATE0_ARKTS_DEVICE_PRESENT
      if (globalPresent) presence |= GATE0_ARKTS_GLOBAL_PRESENT
      if (rawPresent) presence |= GATE0_ARKTS_RAW_PRESENT
      if (pressedButtonsPresent) presence |= GATE0_ARKTS_PRESSED_BUTTONS_PRESENT

      testNapi.traceGate0ArktsMouse(
        normalizeMonotonicTimestampNs(e.timestamp),
        devicePresent ? e.deviceId as number : 0,
        e.source as number,
        e.sourceTool as number,
        e.action as number,
        e.button as number,
        presence,
        pressedButtonsPresent ? (e.pressedButtons as MouseButton[]).length : 0,
        getInputDeviceMonitor().capabilityNow().mouse,
        this.mcStarted,
        this.isInGame,
        e.x,
        e.y,
        e.windowX,
        e.windowY,
        e.displayX,
        e.displayY,
        globalPresent ? e.globalDisplayX as number : 0,
        globalPresent ? e.globalDisplayY as number : 0,
        rel.dx,
        rel.dy,
        this.gate0DisplayDensity,
        1)
    } catch (e2) {
      // A diagnostic bridge failure must not affect production routing or keep
      // throwing on every MOVE. Disable only this observer for the page.
      this.gate0TelemetryEnabled = false
    }
  }

  // ============================================================
  //   阶段 4.4 物理鼠标
  //
  //   Phase E.3（键鼠适配 2026-05-30，再次修订）分工：
  //   - 鼠标按键（Press/Release）→ native DispatchMouseEvent（左键 ArkUI 不报）
  //   - 鼠标视角（Move）→ ArkTS rawDeltaX/Y（since 15；字段存在不等于已证明底层 raw HID）
  //   - 普通模式（菜单）→ verified 时由 native surface-local absolute 独占；
  //     未验证/默认构建才由 ArkTS 进入 legacy window-coordinate 事务
  //   - 滚轮（Axis）→ handleAxisEvent
  //
  //   关键：ArkUI 可能把 XComponent 上的触屏手势再次合成为 MouseEvent。
  //   无物理鼠标接入时整条过滤，否则同一手势会绕过 Native MENU_POINTER 事务、帧屏障与 finger epoch。
  //   确有物理鼠标时，这里只处理它的 raw Move/菜单绝对位置及 Native 未覆盖的辅助键。
  //
  //   native MouseEvent 只有 ev.x/y 绝对坐标；ArkUI rawDeltaX/rawDeltaY 是当前
  //   平台提供的相对量来源，但真实设备的底层采样语义仍需单独验证。
  // ============================================================
  private handleMouseEvent(e: MouseEvent): void {
    // ⚠️ 必须是函数的**第一条语句**，且不受任何编译期开关约束。
    //
    // 教训：此前所有鼠标打点都在 mcStarted / hasMouse / action===Move 三道早退之后，
    // 于是"按住左键期间 onMouse 停投"与"onMouse 一直在被调用、但 action 不是 Move
    // 而被我们在下面丢掉"这两件完全不同的事，在日志里完全无法区分。我按前者设计了
    // 好几轮，而证据只支持"到达 Move 分支的样本很少"。这条聚合打点把前提钉死。
    this.probeMouseEntry(e)
    // Intentionally before mcStarted/capability/action filters: Gate 0 must see
    // platform-synthesized touch MouseEvents as well as accepted physical ones.
    this.traceGate0MouseEvent(e)
    // 物理光标位置回声：这是**菜单态**区分"鼠标镜像触点"与"真手指"的唯一可判定信息。
    // 真机已证伪元数据路线（native 对 618/618 个触摸包都报 TOUCHSCREEN，鼠标合成包
    // 也一样），而 onMouse 本身按鼠标身份上报，所以光标坐标是确定已知的。
    // 虚拟控件据此拒收落在光标处的触点，详见 PhysicalPointerEcho.isLikelyPhysicalPointerAt。
    // 放在 mcStarted / capability 过滤之前：菜单态同样需要它。
    if (e.windowX !== undefined && e.windowY !== undefined) {
      getPhysicalPointerEcho().note(
        e.windowX as number, e.windowY as number)
    }
    if (!this.mcStarted) return
    try {
      // 输入所有权边界：纯触屏设备的唯一 owner 是 Native XComponent Touch。
      // ArkUI 生成的 MouseEvent 是同一物理手势的二次投递，若继续送 NAPI，会直接生成普通
      // MOUSE_BUTTON/CURSOR_DELTA，绕开 MENU_POINTER 的有序坐标、present barrier 和跨层手指作废。
      // hasMouse() 而不是 capabilityNow().mouse：后者每个 Move 样本都要新建一个对象。
      if (!getInputDeviceMonitor().hasMouse()) {
        return
      }

      // Identity/class/time all come from this exact MouseEvent. Do not query
      // inputDevice by event deviceId here: the platform docs never bind those
      // numbering domains. Unknown SourceTool stays explicit Unknown rather
      // than being guessed from SourceType.Mouse (touchpad often uses that same
      // source with a different tool class).
      const deviceId: number = normalizeDeviceId(e.deviceId)
      const deviceClass: InputDeviceClass =
        pointerDeviceClassFromSourceTool(e.sourceTool as number)
      const monotonicTimeNs: number =
        normalizeMonotonicTimestampNs(e.timestamp)

      // API 24 MatePad 真机证明 native DispatchMouseEvent 可能注册成功却把按钮边沿
      // 上报为 action=NONE/button=NONE；ArkUI onMouse 同时给出可用的 Press/Release。
      // 把边沿交给 native 的 first-valid-source 仲裁：合法 native 边沿先到时本调用被丢弃，
      // ArkUI 先到时则由这里独占，避免双 PRESS/RELEASE，也不再无条件吞掉唯一可用来源。
      if (e.action === MouseAction.Press || e.action === MouseAction.Release) {
        // MouseButton 是**位掩码**，不是 0..4 顺序值：
        //   Left=1 Right=2 Middle=4 Back=8 Forward=16 None=0
        // 而且这些值与 native 的 OH_NATIVEXCOMPONENT_*_BUTTON 位值完全一致，
        // 所以掩码本身就是跨两条通道通用的按钮身份，必须原样传下去。
        //
        // 之前这里按 `>=0 && <=4` 过滤再由 native 左移一次，后果是确定的：
        // 左键(1) 变成右键、右键(2) 变成中键、侧键(8/16) 被静默丢弃，
        // 而 None(0) 反而通过并被伪造成左键。这就是"左右键无反应或按错"的根因。
        const buttonMask: number = e.button as number
        const action: number = e.action === MouseAction.Press ? GLFW_PRESS : GLFW_RELEASE
        try {
          // 合法性判定（含 None 与未知新位）由 native 统一 fail-closed，避免两侧各写一份。
          testNapi.physicalMouseButtonTransaction(
            deviceId, buttonMask, action, 0, deviceClass as number,
            monotonicTimeNs)
        } catch (e2) {
          // 物理按钮不能回退到普通 sendMouseEvent；那会绕过 source 仲裁并可能双发。
        }
          return
      }
      if (e.action !== MouseAction.Move) {
        // 其他非 Move（Hover / Enter / Leave）：仅模式通知
          return
      }

      // ---- default input-trace：按住键期间 rawDelta 是否存活（上限 30 条）----
      // 官方转换清单只包含"鼠标左键的点击与滑动、以及滚轮"，**不含右键/中键**。
      // 因此："按住右键拖动"若能持续拿到非零 rawDelta，就证明 onMouse 这条通道本身
      // 在有键按下时完全正常，问题纯粹是左键被转成了触摸；反之若右键按住也拿不到，
      // 说明是 rawDelta 在"任何键按下时"都失效，那是另一个性质的问题。
      // 这是当前唯一不需要受限权限就能做出的判定，结果直接决定下一步走哪条路。
      const pressed: MouseButton[] | undefined = e.pressedButtons
      if (DiagnosticPolicy.inputTraceEnabled() && pressed !== undefined && pressed.length > 0 &&
          this.heldButtonProbeCount < 30) {
        this.heldButtonProbeCount++
        this.launchLogger_().info(TAG,
          `AMCL_HELD buttons=[${pressed.join(',')}] action=${e.action} ` +
          `rawPresent=${e.rawDeltaX !== undefined} ` +
          `rawDx=${e.rawDeltaX} rawDy=${e.rawDeltaY} ` +
          `winX=${e.windowX} winY=${e.windowY}`,
          LOG_DOMAIN_LAUNCH)
      }

      // Move 路径只进入一个 native 事务。ArkTS 同时提供 rawDelta（若存在）
      // 与 window 坐标，但绝不使用异步 isInGame 选择物理源平面；native 在同一
      // surface gate 内采样 bridge grab SSOT、surface generation 与 reset epoch。
      //
      // rawDelta 的存在性判定走 `gamecontrol/PhysicalMouseMotion.ets` 的唯一实现 ——
      // 下面两个探针用的是**同一个函数**，所以"探针在它专门要测的事情上说谎"这条
      // 失效模式被结构性消掉了（此前这条判定在本文件写了三遍）。
      const rel: RelativeMouseDelta =
        normalizeRelativeMouseDelta(e.rawDeltaX, e.rawDeltaY)
      // ---- 绝对坐标必须用**组件坐标系**，不是窗口坐标系 ----
      //
      // 菜单态（未 grab）时 native 会把这一对当成 MC 的菜单光标位置。MC 那一侧的坐标空间
      // 是"XComponent 内的物理 px"—— 手指菜单通道送的就是触点的 px。
      //
      // 此前这里送的是 `e.windowX/windowY`（窗口坐标系），有两处错位：原点是窗口而不是
      // 组件，单位是 vp 而不是 px。结果 MC 的菜单光标恒在左上角一小块区域里，
      // 于是**点不中按钮、悬浮也不出高亮**（高亮由 MC 自己的光标位置决定）。
      //
      // `MouseEvent.x/y` 是组件坐标系、单位 vp，且官方属性表标注为**必有**字段
      // （非可选，API 11 起）。vp→px 的换算由 native 用已下发的 display density 完成，
      // 那边才是唯一知道 MC 期望什么量纲的地方。
      const localVpX = e.x as number
      const localVpY = e.y as number
      try {
        testNapi.physicalPointerMotionTransaction(
          rel.present, rel.dx, rel.dy, localVpX, localVpY,
          deviceId, deviceClass as number, monotonicTimeNs)
      } catch (e2) {
        // 新事务缺失时不能回退到 UI grab 观察值，否则会重新引入切换窗口双发。
      }

    } catch (err) {
      this.launchLogger_().warn(TAG, 'handleMouseEvent failed', err, LOG_DOMAIN_LAUNCH)
    }
  }

  // ============================================================
  //   物理鼠标滚轮
  //
  //   2026-05-29 输入路由根因修复：滚轮已改由 native UIInputEvent(AXIS) 通道处理
  //   （xcomponent.cpp 注册 RegisterUIInputEventCallback + touch_input.cpp
  //   OnDispatchAxisEvent → sendScrollEvent）。native 路径更可靠（直接拿 vertical
  //   axis 角度），且不会被触摸路径误判。
  //
  //   ⚠️ 这里曾写着「ArkTS onAxisEvent **不再发 scroll**……仅保留模式通知……可在确认
  //   native 失效后再启用 ArkTS 兜底（需加去重）」。**那三句现在全都不成立**：
  //   `handleAxisEvent` 会先 `claimWheelChannel(WHEEL_CHANNEL_ARKTS_AXIS)`，
  //   拿到所有权就 `sendSourceScrollEvent(PhysicalKbm, 0, direction)` —— 它是一条**活的**
  //   滚轮生产者，而且在 native AXIS 零样本的设备（API 24 平板）上是**唯一**的那条。
  //   "兜底"早已启用，"去重"由 §35 引入的策略层（input_channel_policy）承担，
  //   不再靠调用点各自判断。
  //
  //   为什么必须改掉这段：滚轮的方向与格数是本项目反复出问题的地方（§18/§32/§35），
  //   照这段注释排查会**整条跳过这个函数**，或者"顺手把兜底加回来"从而造成真正的双发。
  // ============================================================
  // 滚轮 —— 轴驱动 Pan 手势通道（本机滚轮的真实到达形态）。
  // 分格规则、步长依据与"两条通道符号相反"的契约都在 `gamecontrol/WheelChannel.ets`，
  // 由 `WheelChannel.test.ets` 穷举。这里只持有累加器实例与取证计数。
  private wheelPan: WheelStepAccumulator = new WheelStepAccumulator()
  private wheelProbeCount: number = 0
  /** AMCL_HELD 取证计数（按住任意鼠标键期间的 rawDelta 存活性）。 */
  private heldButtonProbeCount: number = 0

  // XComponent 命中测试探针的打印上限。onTouchIntercept 只在命中测试（DOWN）时回调，
  // 频率天然很低；限流只是防止异常情况下刷屏，不参与任何路由决策。
  private surfaceHitTestProbeCount: number = 0

  // ---- onMouse 入口聚合普查（常开，每秒最多一行）----
  // MouseAction: Press=1 Release=2 Move=3 Hover=4 ENTER_WINDOW/LEAVE_WINDOW 另有取值。
  // 用定长数组按 action 计数，外加"有键按下"的样本数，成本 = 每事件一次数组自增。
  private mouseActionCounts: number[] = [0, 0, 0, 0, 0, 0, 0, 0]
  private mouseHeldSamples: number = 0
  private mouseRawPresentSamples: number = 0
  private mouseProbeNextFlushMs: number = 0
  // rawDelta 的**量子**：本次会话见过的最小非零 |rawDeltaX|/|rawDeltaY|。
  //
  // 它是判定"这台设备用哪套 rawDelta 量纲"的唯一无混淆手段（计划 §78.3）：
  // HarmonyOS 7.0 起 rawDelta 是硬件原始值 ⇒ 量子 = 1；7.0 之前是原始值除以系统显示
  // 大小比例 ⇒ 量子 = 1/比例（平板实测 ≈ 0.47 = 1/2.125）。
  // ⚠️ 刻意**不**用 |rawDelta|/|Δvp| 的比值：那条路混进了系统指针速度/加速设置
  // （比值 = 比例/速度），单看一台设备分不出是量纲还是速度造成的。量子没有这个问题。
  // 0 = 本秒还没见过任何非零 rawDelta。
  private mouseRawQuantum: number = 0

  private probeMouseEntry(e: MouseEvent): void {
    if (!DiagnosticPolicy.inputTraceEnabled()) return
    const a: number = e.action as number
    if (a >= 0 && a < 8) this.mouseActionCounts[a] = this.mouseActionCounts[a] + 1
    const pressed: MouseButton[] | undefined = e.pressedButtons
    if (pressed !== undefined && pressed.length > 0) this.mouseHeldSamples++
    // 与生产路径**同一个**判定函数：探针要测的正是"rawDelta 活不活"，两份实现漂移
    // 就会让它在这件事上说谎（见 PhysicalMouseMotion.ets 文件头）。
    const rel: RelativeMouseDelta =
      normalizeRelativeMouseDelta(e.rawDeltaX, e.rawDeltaY)
    if (rel.present) {
      this.mouseRawPresentSamples++
      const ax: number = rel.dx < 0 ? -rel.dx : rel.dx
      const ay: number = rel.dy < 0 ? -rel.dy : rel.dy
      if (ax > 0 && (this.mouseRawQuantum === 0 || ax < this.mouseRawQuantum)) {
        this.mouseRawQuantum = ax
      }
      if (ay > 0 && (this.mouseRawQuantum === 0 || ay < this.mouseRawQuantum)) {
        this.mouseRawQuantum = ay
      }
    }
    const now: number = Date.now()
    if (this.mouseProbeNextFlushMs === 0) {
      this.mouseProbeNextFlushMs = now + 1000
      return
    }
    if (now < this.mouseProbeNextFlushMs) return
    this.mouseProbeNextFlushMs = now + 1000
    this.launchLogger_().info(TAG,
      `AMCL_MOUSEIN 1s actions=[${this.mouseActionCounts.join(',')}] ` +
      `heldSamples=${this.mouseHeldSamples} rawPresent=${this.mouseRawPresentSamples} ` +
      `rawQuantum=${this.mouseRawQuantum} ` +
      `mcStarted=${this.mcStarted} hasMouse=${getInputDeviceMonitor().hasMouse()}`,
      LOG_DOMAIN_LAUNCH)
    for (let i = 0; i < this.mouseActionCounts.length; i++) {
      this.mouseActionCounts[i] = 0
    }
    this.mouseHeldSamples = 0
    this.mouseRawPresentSamples = 0
    // ⚠️ `mouseRawQuantum` **刻意不清零**：它是会话级的"这台设备的量纲"，
    // 不是每秒的活动量。清零会让它退化成"最近一秒的最小位移"，那随手速变化，
    // 判不出量纲（这正是不用 |raw|/|Δvp| 比值的同一个理由）。
  }

  private onWheelPanStart(e: GestureEvent): void {
    // ⚠️ 不再把 start 的 offsetY 当基准（计划 §90.2）：`offsetY` 官方定义就是"相对手指
    // 按下时"的累计量，基准只能是 0。传它进去等于丢掉手势被识别前那一整格。
    this.wheelPan.begin()
    // 抑制窗：手势期间 native 不再把这条合成滑动解释成空白 look。
    try { testNapi.noteAxisPanActive(true) } catch (e2) { /* 老 native 兼容 */ }
    this.probeWheelPan('start', e.offsetY as number, 0)
  }

  private onWheelPanUpdate(e: GestureEvent): void {
    const offsetY: number = e.offsetY as number
    // 基准**无条件**推进（即使下面让位不发格）：让位期间的位移必须被丢弃而不是攒起来，
    // 否则重新拿到所有权时一个巨大的 delta 涌进来 ⇒ "松手后快捷栏又自己跳几格"。
    // 这条分工写在 WheelStepAccumulator 的契约第 4 条，别把两步合并。
    const delta: number = this.wheelPan.advanceBaseline(offsetY)
    // 抑制窗必须**无条件**通知，与是否拥有滚轮所有权无关：即使本通道让位不发 scroll，
    // 这条合成滑动仍然会落到 XComponent 上，不抑制就会被解释成空白 look（滚轮转视角）。
    try { testNapi.noteAxisPanActive(true) } catch (e2) { /* 老 native 兼容 */ }
    this.probeWheelPan('update', offsetY, delta)
    if (!this.mcStarted) return

    // ---- 单一所有者门控（2026-08-19 新增，修"滚轮方向反了且时好时坏"）----
    //
    // 此前这条通道**从不询问**所有者，于是它与 native AXIS 同时产出：真机一秒内
    // `nativeAxisScroll=9` 而 `scrollOut=19`，多出来的十格全是这里发的，而两条通道
    // 的符号相反 —— 慢滚 native 赢、快滚这里赢，用户看到的就是"方向是反的，
    // 但快速滚动有时又正常"，像两套逻辑在打架。确实是两套。
    //
    // 现在所有滚轮产出点都必须先向策略层申请，同一时刻只有一条通道能发。
    if (!this.claimWheelChannel(WHEEL_CHANNEL_AXIS_PAN)) return

    // 分格与符号约定见 `WheelChannel.ets`：本通道 direction = +sign(offsetY)，
    // 而 AXIS 通道是 **-**sign(axisVertical)。**两条不要统一**，各有官方依据。
    const steps: number[] = this.wheelPan.consume(delta)
    for (let i = 0; i < steps.length; i++) {
      this.emitWheelStep(steps[i])
    }
  }

  private onWheelPanEnd(): void {
    this.wheelPan.reset()
    try { testNapi.noteAxisPanActive(false) } catch (e2) { /* 老 native 兼容 */ }
  }

  private emitWheelStep(direction: number): void {
    try {
      // 物理键鼠端：滚轮是这一端的输出，端身份让它与手柄 L1/R1 切格、
      // 屏幕虚拟滚轮条在普查里可分。滚轮没有持续按下态，所以只影响诊断归属。
      testNapi.sendSourceScrollEvent(AmclInputSource.PhysicalKbm as number, 0, direction)
    } catch (e2) { /* 老 native 兼容 */ }
  }

  /**
   * 向 native 策略层申请滚轮所有权。一次调用同时登记"本通道确实送来过样本"
   * 与"询问它是否为当前所有者"，所以顺序不可能写错。
   *
   * 老 native 没有这个入口时 fail-open（返回 true）：那种构建里 Pan 是唯一通道，
   * 拒绝会让滚轮彻底失效，比双通道更糟。
   */
  private claimWheelChannel(channel: number): boolean {
    try {
      return testNapi.wheelChannelClaim(channel)
    } catch (e) {
      return true
    }
  }

  /** default input-trace 取证（上限 30 条）：一格滚轮到底给出多少 vp，决定 WHEEL_PAN_STEP_VP 是否需要校准。 */
  private probeWheelPan(phase: string, offsetY: number, delta: number): void {
    if (!DiagnosticPolicy.inputTraceEnabled()) return
    if (this.wheelProbeCount >= 30) return
    this.wheelProbeCount++
    this.launchLogger_().info(TAG,
      `AMCL_WHEEL pan ${phase} offsetY=${offsetY.toFixed(2)} delta=${delta.toFixed(2)}`,
      LOG_DOMAIN_LAUNCH)
  }

  private handleAxisEvent(e: AxisEvent): void {
    // 取证打点在功能过滤之前，但只有 default 的 input-trace 模式启用。
    //
    // 理由：用户复测"滚轮仍然是上下转视角"时，必须先能区分三种完全不同的原因——
    //   (a) onAxisEvent 根本没被调用（滚轮被别的通道吃掉，例如被平台镜像成触摸/Move）；
    //   (b) 被调用了但被 mcStarted / mouse capability 早退挡掉；
    //   (c) 被调用且发了 scroll，但方向或量级不对。
    // 之前这三种在日志里长得一模一样（都是"没反应"），于是每轮真机只能靠猜。
    // 滚轮一格一条事件，逐条打印的成本可以忽略。
    let vyProbe: number = 0
    try { vyProbe = e.getVerticalAxisValue() } catch (e2) { vyProbe = 0 }
    let nativeOwns: boolean = false
    try { nativeOwns = testNapi.nativeWheelChannelActive() } catch (e2) { nativeOwns = false }
    try {
      if (DiagnosticPolicy.inputTraceEnabled()) {
        testNapi.noteArktsAxisEvent(e.action as number, vyProbe, nativeOwns)
      }
    } catch (e2) { /* 老 native 无此入口时不影响滚轮功能 */ }

    if (!this.mcStarted) return
    try {
      if (!getInputDeviceMonitor().hasMouse()) return
      // 所有权统一向 native 策略层申请（与轴驱动 Pan 通道共用同一张优先级表），
      // 不再各自判断。`nativeOwns` 现在只用于上面那条取证日志。
      if (!this.claimWheelChannel(WHEEL_CHANNEL_ARKTS_AXIS)) {
          return
      }
      if (vyProbe === 0) return
      const deviceId: number = normalizeDeviceId(e.deviceId)
      const deviceClass: InputDeviceClass =
        pointerDeviceClassFromSourceTool(e.sourceTool as number)
      const monotonicTimeNs: number =
        normalizeMonotonicTimestampNs(e.timestamp)
      let typedOwned: boolean = false
      try {
        typedOwned = testNapi.physicalPointerWheelTransaction(
          0, vyProbe, true, deviceId, deviceClass as number,
          monotonicTimeNs)
      } catch (e2) {
        typedOwned = false
      }
      // typedOwned remains true even when its gate rejects this sample. Falling
      // back in that case would split one startup-latched route across typed and
      // legacy planes, so only a genuinely legacy host reaches the old emitter.
      if (typedOwned) return
      // Begin/End 常带 0 值，只有真正的滚动增量才发；这同时天然避免了同一格重复计数。
      const direction: number = wheelDirectionFromAxisVertical(vyProbe)
      if (direction !== 0) {
        // 本通道 direction = **-**sign(axisVertical)，而 Pan 通道是 **+**sign(offsetY)。
        // 两条相反且各有官方依据，**不要统一** —— 官方原文、native C 头的第三种说法与
        // 真机核对全部记在 `gamecontrol/WheelChannel.ets` 的文件头，由单测钉住。
        try {
          // 物理键鼠端：滚轮是这一端的输出。端身份让它与手柄 L1/R1 切格、
          // 屏幕虚拟滚轮条在普查里可分；滚轮无持续按下态，故只影响诊断归属。
          testNapi.sendSourceScrollEvent(
            AmclInputSource.PhysicalKbm as number, 0, direction)
        } catch (e2) { /* 老 native 兼容 */ }
      }
    } catch (err) {
      this.launchLogger_().warn(TAG, 'handleAxisEvent failed', err, LOG_DOMAIN_LAUNCH)
    }
  }

  // ============================================================
  //   v3 手柄：摇杆 / 扳机模拟轴（onFocusAxisEvent，AxisModel since 15）
  //
  //   axisMap: Map<AxisModel, number>
  //     ABS_X/Y   = 左摇杆（默认 → WASD 八向走路）
  //     ABS_Z/RZ  = 右摇杆（默认 → 视角 sendCursorDelta）
  //     ABS_GAS   = RT（默认 → 攻击）  ABS_BRAKE = LT（默认 → 丢弃）
  //     ABS_HAT0X/Y = 方向键走轴（部分手柄）
  //
  //   归一化逻辑全部在 GamepadManager；这里只把 axisMap 解成"取轴值"回调传进去。
  //   仅 grabbed 时把右摇杆当视角用（菜单里右摇杆不转视角，避免乱动）。
  // ============================================================
  private handleFocusAxisEvent(e: FocusAxisEvent): void {
    if (!this.mcStarted) return
    try {
      this.probeAxisDeviceIdentity(e)
      const gamepadDeviceId: number = normalizeDeviceId(e.deviceId)
      const map = e.axisMap
      // 取轴值回调：map.get(AxisModel) 在 ArkTS 里 AxisModel 是 enum，其数值与
      // GamepadManager 的 AXIS_* 常量一致，可直接用数字 key 取。
      this.gamepad.handleAxisForDevice(
        gamepadDeviceId, (axis: number): number | undefined => {
        const v = map.get(axis as number as AxisModel)
        return (v === undefined || v === null) ? undefined : (v as number)
      })
    } catch (err) {
      this.launchLogger_().warn(TAG, 'handleFocusAxisEvent failed', err, LOG_DOMAIN_LAUNCH)
    }
  }

  private refreshLog() {
    if (this.mcDir) {
      try {
        let log: string = testNapi.mcReadLog(this.mcDir, 16384)
        let status: string = testNapi.mcGetStatus()
        this.mcLog = '状态: ' + status + '\n\n' + log
      } catch (e) {
        this.mcLog = '读取日志失败: ' + formatError(e)
      }
    }
  }

  /**
   * 确保 amcl-launcher.jar 之外的运行期 raw 资源就绪（v6 起仅占位，无实际工作）。
   *
   * 历史（v1-v5）：这里是 ensureCacioJars()，把 cacio-shared.jar / cacio-tta.jar
   * 提取到 filesDir/cacio/ 让 jvm_launcher.cpp 检测后启用 Cacio AWT。v6 切到真
   * headless 模式后不再需要 Cacio，方法已删除（连同 rawfile 里的两个 jar）。
   *
   * 留这条注释存档；如果未来还要在 startMC 阶段提前准备 raw 资源，挂在这里即可。
   */

  /**
   * 准备第三方皮肤站（authlib-injector）启动所需：
   *   1) 从 rawfile 提取 authlib-injector.jar 到 filesDir（幂等，已存在且非空则跳过）
   *   2) GET apiRoot 预取元数据（同时借 YggdrasilApi 完成 ALI 解析），base64 编码
   *   3) builder.setAuthlibInjector(jarPath, resolvedRoot, prefetchedBase64)
   *
   * 成功返回 ''；失败返回错误描述（调用方据此中断启动）。
   */
  private async prepareAuthlibInjector_(acc: AuthlibInjectorAccount, builder: LaunchProfileBuilder, filesDir: string): Promise<string> {
    // 1) 提取 jar
    let jarPath = filesDir + '/' + AUTHLIB_INJECTOR_JAR_NAME
    try {
      let needExtract = true
      try {
        let st = fs.statSync(jarPath)
        if (st.size > 0) needExtract = false
      } catch (e) { /* 不存在 → 需提取 */ }
      if (needExtract) {
        let data = await this.context.resourceManager.getRawFileContent(AUTHLIB_INJECTOR_JAR_NAME)
        if (!data || data.byteLength <= 0) {
          return AUTHLIB_INJECTOR_JAR_NAME + ' 为空（rawfile 可能未正确打包）'
        }
        let f = fs.openSync(jarPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
        try {
          fs.writeSync(f.fd, data.buffer)
        } finally {
          fs.closeSync(f)
        }
        let writtenSize = 0
        try { writtenSize = fs.statSync(jarPath).size } catch (e) { /* ignore */ }
        if (writtenSize <= 0) {
          return AUTHLIB_INJECTOR_JAR_NAME + ' 写入后大小为 0'
        }
        this.launchLogger_().info(TAG, `Extracted ${AUTHLIB_INJECTOR_JAR_NAME}: ${writtenSize} bytes`, LOG_DOMAIN_LAUNCH)
      }
    } catch (e) {
      return '提取 ' + AUTHLIB_INJECTOR_JAR_NAME + ' 失败: ' + (e as Error).message
    }

    // 2) 预取元数据（含 ALI 解析）
    this.statusText = '正在连接第三方登录服务器...'
    let apiRoot = acc.getApiRoot()
    try {
      let ygg = new YggdrasilApi(new RealHttpClient())
      let meta = await ygg.resolveMetadata(apiRoot)
      let prefetched = encodeStandardBase64(stringToUtf8(meta.raw))
      // 3) 注入
      builder.setAuthlibInjector(jarPath, meta.resolvedRoot, prefetched)
      this.launchLogger_().info(TAG, `authlib prefetch ok: root=${meta.resolvedRoot} raw=${meta.raw.length}B`, LOG_DOMAIN_LAUNCH)
      return ''
    } catch (e) {
      return '无法连接皮肤站（' + apiRoot + '）：' + (e as Error).message
    }
  }

  // ⚰️ 2026-09-04（启动架构世代化 §S02）：这里曾有 `isForgeLaunchProfile()` ——
  //   本仓**第五份**路线判定（versionId/mainClass/classpath/mcArgs 四路子串匹配），
  //   而它的唯一用途是启动失败日志里那个 `isForge=` 字段。判定已收敛到
  //   `LoaderGenerationResolver`，日志改打 `profile.generation`（分辨率从二元升到七元）。
  //   删除理由见 `docs/refactor/启动世代契约规范.md` §1.1 纪律 1。

  /** 取应用级 filesDir；MobileGlues 等跨 HAP 日志可能落在这里。 */
  private applicationFilesDir_(): string {
    try { return this.context.getApplicationContext().filesDir; }
    catch (e) { return this.context.filesDir; }
  }

  /** 写一条「启动失败」活动记录（前置失败：JVM 未起、未写 SessionMarker）。幂等防重复。 */
  private recordLaunchFailure_(version: string, reason: string): void {
    if (this.launchRecorded_) return
    this.launchRecorded_ = true
    let nowMs = Date.now()
    let started = this.launchStartedAt_ > 0 ? this.launchStartedAt_ : nowMs
    let ver = version.length > 0 ? version : 'unknown'
    // Even failures before JVM creation need a shareable activity. Preserve
    // the same id from launch preparation through native admission and exit.
    if (!ledgerHas(this.context.filesDir, started)) {
      const meta: LedgerBeginMeta = { category: ActivityCategory.LAUNCH, title: ver,
        gameVersionId: ver, mcDir: this.mcDir, appFilesDir: this.applicationFilesDir_() }
      ledgerBegin(this.context.filesDir, started, enrichSessionEnvironment(this.context, started, meta))
    }
    new ActivityLogger(started).error(TAG, reason, null, LOG_DOMAIN_LAUNCH)
    const outcome: LedgerOutcome = { state: LedgerState.FAILED, source: 'launch-preparation', summary: reason }
    ledgerEnd(this.context.filesDir, started, outcome)
    let rec: ActivityRecord = {
      versionName: ver,
      gameVersion: ver,
      loaderType: 'launch',
      startedAt: started,
      durationMs: nowMs - started,
      totalBytes: 0,
      fileCount: 0,
      status: ActivityStatus.FAILED,
      category: ActivityCategory.LAUNCH,
      endedAt: nowMs,
      title: ver,
      subtitle: '启动失败',
    }
    if (reason.length > 0) rec.errorMessage = reason
    if (AppStorage.get<boolean>('desktopGameProcess') === true) {
      DesktopGameResults.queue(this.context, rec)
      return
    }
    let store = getDownloadHistoryStore()
    store.init(this.context)
    store.add(rec).catch((e: Error) => {
      this.launchLogger_().warn(TAG, 'launch failure record add failed', e, LOG_DOMAIN_LAUNCH)
    })
  }

  /** 每次调用显式绑定本局；不使用跨 await 的全局当前活动。 */
  private launchLogger_(): ActivityLogger { return new ActivityLogger(this.launchStartedAt_); }

  private startMC(): Promise<void> {
    return this.gameLaunchGate.run((): Promise<void> => this.startMCOnce())
  }

  /** 在窗口校验、资源部署和 JVM 参数构造前建立本局账本，消除启动前日志空窗。 */
  private beginLaunchLedgerEarly_(): void {
    if (this.launchStartedAt_ <= 0 || ledgerHas(this.context.filesDir, this.launchStartedAt_)) return
    let version: string = ''
    let mcDir: string = ''
    try {
      const params: McGameRouteParams = this.getUIContext().getRouter().getParams() as McGameRouteParams
      version = params.mcVersion ?? (AppStorage.get('mcVersion') as string) ?? ''
      mcDir = params.mcDir ?? (AppStorage.get('mcDir') as string) ?? ''
    } catch (e) { /* 继续使用空元信息，后续 startMCInternal 会补齐 */ }
    const meta: LedgerBeginMeta = {
      category: ActivityCategory.LAUNCH,
      title: version.length > 0 ? version : 'unknown',
      gameVersionId: version,
      mcDir: mcDir,
      appFilesDir: this.applicationFilesDir_(),
    }
    try {
      ledgerBegin(this.context.filesDir, this.launchStartedAt_, enrichSessionEnvironment(this.context, this.launchStartedAt_, meta))
      // native 横幅需要在 stdout 重定向之前知道本局 activityId。
      testNapi.amclLedgerSetLaunchActivity(this.launchStartedAt_)
    } catch (e) {
      // 账本是诊断增强能力；建立失败不能阻止正常启动流程。
      this.launchLogger_().warn(TAG, 'early launch ledger begin failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  private async receiveDesktopDrop(event: DragEvent): Promise<void> {
    if (!ProductInputProfile.selection().desktopWindow) return
    const epoch: number = this.inputLifecycleEpoch
    let paths: string[] = []
    try {
      paths = await DesktopFileDrop.stage(this.context, event.getData())
      if (epoch !== this.inputLifecycleEpoch || this.navigatedAway || !testNapi.desktopPublishDrop(paths)) {
        throw new Error('游戏窗口已关闭或拖入队列已满')
      }
    } catch (error) {
      DesktopFileDrop.discard(this.context, paths)
      this.launchLogger_().warn(TAG, 'Desktop file drop failed', error, LOG_DOMAIN_LAUNCH)
      if (epoch === this.inputLifecycleEpoch) this.getUIContext().getPromptAction().showToast({ message: '拖入失败：' + (error as Error).message })
    }
  }

  private async startMCOnce(): Promise<void> {
    this.launchLifecycleEpoch = this.inputLifecycleEpoch
    let launchActivityId: number = 0
    try {
      const launchParams: McGameRouteParams = this.getUIContext().getRouter().getParams() as McGameRouteParams
      launchActivityId = launchParams.activityId ?? 0
    } catch (e) { /* desktop GameAbility 通过 AppStorage 传递 */ }
    if (launchActivityId <= 0) launchActivityId = AppStorage.get<number>('mcLaunchActivityId') ?? 0
    this.launchStartedAt_ = launchActivityId > 0 ? launchActivityId : Date.now()
    this.launchRecorded_ = false
    this.beginLaunchLedgerEarly_()
    try {
      if (ProductInputProfile.selection().desktopWindow) {
        const snapshot: ProductGameWindowSnapshot = await this.gameWindowCoordinator.enter(this.context)
        if (snapshot.windowId <= 0 || snapshot.contextGeneration <= 0 || snapshot.width <= 0 || snapshot.height <= 0) {
          throw new Error('桌面窗口或输入几何尚未就绪')
        }
      }
      if (this.launchLifecycleEpoch !== this.inputLifecycleEpoch || this.navigatedAway) return
      await this.startMCInternal()
    } catch (e) {
      this.statusText = '游戏启动准备失败：' + (e as Error).message
      this.launchLogger_().error(TAG, 'Game launch preparation rejected', e, LOG_DOMAIN_LAUNCH)
      this.recordLaunchFailure_(AppStorage.get<string>('mcVersion') ?? '', this.statusText)
    } finally {
      // 所有早退（参数缺失、资源失败、profile 拒绝、native rc）统一经过这里；
      // 不再要求每个新增失败分支记得手工恢复窗口。
      if (!this.mcStarted) {
        await this.restoreGameWindow(this.gameWindowCoordinator, 'launch-failed')
      }
    }
  }

  private async startMCInternal(): Promise<void> {
    const processError: string = AppStorage.get<string>('gameAbilityLaunchError') ?? '';
    if (processError.length > 0) { this.statusText = processError; return; }
    if (this.mcStarted) return

    // 检查是否有残留的 JVM 进程（上次 MC 退出后进程未被完全杀死）
    try {
      if (testNapi.mcIsRunning()) {
        this.launchLogger_().warn(TAG, 'Previous MC instance still running, force killing process', null, LOG_DOMAIN_LAUNCH)
        this.statusText = '检测到残留进程，正在重启...'
        try { testNapi.mcForceExit() } catch (e) { /* ignore */ }
        return // _exit 会杀死进程，不会到这里
      }
    } catch (e) { /* ignore */ }

    // 从 router params 或 AppStorage 读取参数（兼容单窗口/新窗口两种模式）
    // 2026-05-23 API NEXT 迁移：router.getParams 全局函数弃用，
    // 改走 this.getUIContext().getRouter().getParams()。
    // 详见 docs/guides/api-migration-2026-05.md。
    let params = this.getUIContext().getRouter().getParams() as Record<string, string | number>
    let filesDir: string = (params?.['filesDir'] as string) || (AppStorage.get('mcFilesDir') as string) || ''
    this.mcDir = (params?.['mcDir'] as string) || (AppStorage.get('mcDir') as string) || ''
    // gameDir：版本隔离时为 .minecraft/versions/<ver>/，否则等于 mcDir。
    // ⚠️ 不再静默退化为 mcDir，避免 GameAbility 漏传 'gameDir' 时悄悄丢失版本隔离。
    let gameDir: string = (params?.['gameDir'] as string) || (AppStorage.get('mcGameDir') as string) || ''
    // 关键修复：以前 fallback 到 '1.20.4'，但用户可能根本没装该版本（首次启动 + GameAbility
     // 缺参数的边界），LaunchProfileBuilder 后续会报"version.json 解析失败"，体验差。
     // 改为允许空值，让下面的"未指定 MC 版本"检查命中并提示用户回首页选版本。
    let mcVersion: string = (params?.['mcVersion'] as string) || (AppStorage.get('mcVersion') as string) || ''
    // mcXmx 取值优先级：params 非 0 > AppStorage 非 0 > 0（让 C 层自行兜底）。
    // 注：`||` 把 0 当 falsy 是有意的——0 表示"用户没显式设过"，让兜底链生效；
    // 真用户绝不会主动选 0 MB heap（Slider min=512）。
    let mcXmx: number = (params?.['mcXmx'] as number) || (AppStorage.get('mcXmx') as number) || 0
    // 防御性兜底：如果链路全部丢失，确保 C 层拿到一个合理值（512 是最低保守值）。
    if (mcXmx > 0 && mcXmx < 512) {
      this.launchLogger_().warn(TAG, `mcXmx ${mcXmx} below 512 floor, clamping to 1024`, null, LOG_DOMAIN_LAUNCH)
      mcXmx = 1024
    }
    let jdkVersion: string = (params?.['jdkVersion'] as string) || (AppStorage.get('jdkVersion') as string) || SUPPORTED_JDK_VERSION
    const launchMeta: LedgerBeginMeta = { category: ActivityCategory.LAUNCH,
      title: mcVersion || 'unknown', gameVersionId: mcVersion, jdk: jdkVersion,
      mcDir: this.mcDir, gameDir: gameDir, appFilesDir: this.applicationFilesDir_() }
    ledgerBegin(this.context.filesDir, this.launchStartedAt_, enrichSessionEnvironment(this.context, this.launchStartedAt_, launchMeta))
    testNapi.amclLedgerSetLaunchActivity(this.launchStartedAt_)
    this.launchLogger_().info(TAG, `Launch params resolved: filesDir=${filesDir} mcDir=${this.mcDir} gameDir=${gameDir} mcVersion=${mcVersion}`, LOG_DOMAIN_LAUNCH)

    // 版本隔离硬校验：用户开启了 versionIsolation 但 gameDir 等于 mcDir 根目录
    //   → 几乎一定是 GameAbility/Index 的传参链路出 bug，拒绝启动避免存档落到错误位置。
    try {
      let pref = new PreferenceManager(this.context)
      if (pref.versionIsolation && (!gameDir || gameDir === this.mcDir)) {
        this.launchLogger_().error(TAG, `Version isolation enabled but gameDir=${gameDir} mcDir=${this.mcDir} — refusing to launch`, null, LOG_DOMAIN_LAUNCH)
        this.statusText = '❌ 启动终止：版本隔离已开启但 gameDir 未正确设置\n'
          + '请重启应用后再试，若仍失败请反馈日志。'
        this.showLog = true
        this.recordLaunchFailure_(mcVersion, '版本隔离已开启但 gameDir 未正确设置')
        return
      }
    } catch (e) { /* PreferenceManager init 失败时不强求校验 */ }
    // 容许非版本隔离场景下 gameDir 退化为 mcDir（这是合法配置）
    if (!gameDir) gameDir = this.mcDir
    // 多版本时代（17 / 21 / 25）：仍然要校验 jdkVersion 是支持版本之一，
    // 但不再强制覆盖回 SUPPORTED_JDK_VERSION（17）。
    // 兜底：未知版本 → 回退到 SUPPORTED_JDK_VERSION，避免 native 层加载空目录。
    if (SUPPORTED_JDK_VERSIONS.indexOf(jdkVersion) < 0) {
      this.launchLogger_().warn(TAG, `Override unsupported JDK ${jdkVersion} -> ${SUPPORTED_JDK_VERSION}`, null, LOG_DOMAIN_LAUNCH)
      jdkVersion = SUPPORTED_JDK_VERSION
      try {
        AppStorage.setOrCreate('jdkVersion', SUPPORTED_JDK_VERSION)
      } catch (e) { /* ignore */ }
    }

    if (!filesDir || !this.mcDir) {
      // GameAbility.onCreate 会把 hasValidParams 写到 AppStorage；通过 router.pushUrl
      // 走的本进程内启动则不会设置该 key，此时默认为 true 沿用旧文案。
      let hasValidParams = AppStorage.get('gameAbilityHasValidParams') as boolean
      if (hasValidParams === false) {
        this.statusText = '❌ 启动参数缺失\n请通过启动器首页选择已安装的版本再进入游戏。'
      } else {
        this.statusText = '❌ 启动参数缺失'
      }
      return
    }
    // 即便 filesDir/mcDir 齐全，mcVersion 缺失也无意义（避免悄悄用默认值启动错误版本）
    if (!mcVersion) {
      this.statusText = '❌ 未指定 MC 版本，请通过启动器首页选择版本'
      return
    }

    // 提取 amcl-launcher.jar（Java 启动中间层，C 层 JVM classpath 需要）
    // 关键资源：缺失则无法进入 com.amcl.launcher.AmclLauncher，必须硬失败
    try {
      let launcherJarDest = filesDir + '/amcl-launcher.jar'
      let resManager = this.context.resourceManager
      let data = await resManager.getRawFileContent('amcl-launcher.jar')
      if (!data || data.byteLength <= 0) {
        throw new Error('amcl-launcher.jar 为空（rawfile 可能未正确打包）')
      }
      let f = fs.openSync(launcherJarDest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try { fs.writeSync(f.fd, data.buffer) } finally { fs.closeSync(f) }
      let writtenSize = 0
      try { writtenSize = fs.statSync(launcherJarDest).size } catch (e) { /* ignore */ }
      if (writtenSize <= 0) {
        throw new Error('amcl-launcher.jar 写入后大小为 0')
      }
      this.launchLogger_().info(TAG, `Extracted amcl-launcher.jar: ${writtenSize} bytes`, LOG_DOMAIN_LAUNCH)
      await new RuntimeDeployer(this.context).deployGameCompatibility(filesDir)
    } catch (e) {
      let reason = (e as Error).message
      this.launchLogger_().error(TAG, 'FATAL: Failed to deploy Java runtime components', e, LOG_DOMAIN_LAUNCH)
      this.statusText = '❌ 启动终止：部署 Java 运行组件失败\n' + reason
        + '\n请重新安装应用或联系开发者。'
      this.showLog = true
      this.refreshLog()
      this.recordLaunchFailure_(mcVersion, '部署 Java 运行组件失败: ' + reason)
      return
    }

    // v6 起放弃 Cacio AWT，改走真 headless 模式（jvm_launcher.cpp 设
    // -Djava.awt.headless=true + -Dfabric.noGui=true）。
    // 之前在这里调用的 ensureCacioJars 已删除；如果未来要在启动前准备 raw 资源，
    // 挂在 ensureRuntimeRawFiles 里即可。详见 docs/archive/jdk21-awt-headless-journey-202605.md §5。

    // 账户体系：先确保 AccountManager 就绪，把账户四件套灌进 builder
    // - OfflineAccount: refresh() 是 no-op
    // - MicrosoftAccount (M2 Phase B): refresh() 走 refresh_token → XBL → XSTS → MC bearer，
    //   成功后 mcAccessToken / mcExpiresAt / refreshToken（可能轮换）需写回加密存储
    let accountManager = getAccountManager()
    try {
      await accountManager.init(this.context)
    } catch (e) {
      this.launchLogger_().warn(TAG, 'AccountManager init failed (continuing with fallback)', e, LOG_DOMAIN_LAUNCH)
    }
    let account = accountManager.getSelected()
    if (ProcessPreferences.isGameProcess()) {
      const expected: string = ProcessPreferences.open(this.context, 'amcl_accounts').getSync('selected_account_id', '') as string
      if (expected.length > 0 && account.id !== expected) throw new Error('无法恢复本次启动账户，请在启动器重新登录')
    }
    let refreshed = false
    if (!ProcessPreferences.isGameProcess()) {
      try {
        await account.refresh()
        refreshed = true
      } catch (e) {
        this.launchLogger_().warn(TAG, 'account.refresh() failed (continuing with cached token)', e, LOG_DOMAIN_LAUNCH)
      }
    }
    // refresh 成功后写回：Microsoft（token 轮换）与第三方皮肤站（accessToken/clientToken
    // 可能刷新、纹理快照可能更新）都需要持久化；OfflineAccount 无状态变化，跳过。
    if (!ProcessPreferences.isGameProcess() && refreshed && (account.type === AccountType.MICROSOFT || account.type === AccountType.AUTHLIB_INJECTOR)) {
      try {
        await accountManager.persistOne(account)
        this.launchLogger_().info(TAG, `account tokens persisted (id=${account.id} type=${account.type})`, LOG_DOMAIN_LAUNCH)
      } catch (e) {
        this.launchLogger_().warn(TAG, 'persist refreshed tokens failed', e, LOG_DOMAIN_LAUNCH)
      }
    }

    // 使用 LaunchProfileBuilder 验证启动参数
    // mcDir = .minecraft 根目录（jar/libraries/assets 查找）
    // gameDir = 运行时目录（版本隔离时为 .minecraft/versions/<ver>/）
    this.statusText = '正在解析 version.json...'
    // 当前游戏 Window rect 是 MC 初始分辨率的唯一来源。default display 在自由窗口、跨屏
    // 与折叠态都可能不是这个 Window；拿它会让启动分辨率与输入 surface 从第一帧就分裂。
    // Window 快照不可用时保持 0，让 builder 跳过注入，不再猜一个屏幕尺寸。
    let surfaceW = 0
    let surfaceH = 0
    try {
      const snapshot: ProductGameWindowSnapshot =
        await this.gameWindowCoordinator.enter(this.context)
      this.syncInputSurfaceContext(snapshot, 'launch-window-size')
      const surfaceContext: InputSurfaceContext =
        getInputSurfaceContextStore().snapshot()
      if (surfaceContext.has(INPUT_SURFACE_FIELD_RECT)) {
        surfaceW = surfaceContext.widthPx
        surfaceH = surfaceContext.heightPx
      }
    } catch (e) {
      this.launchLogger_().warn(TAG, 'Current game Window size unavailable', e, LOG_DOMAIN_LAUNCH)
      if (ProductInputProfile.selection().desktopWindow) throw e as Error
    }
    const nativeGlValidation: boolean = testNapi.nativeGlValidationEnabled()
    const preferenceManager: PreferenceManager = new PreferenceManager(this.context)
    const devRendererOverride: string = nativeGlValidation ? 'nativegl' :
      (DiagnosticPolicy.isDeveloperBuild() ? preferenceManager.devRendererOverride : '')
    // 一次收集实际安装清单、基础版本和设备证据；后面的 options 策略不再用实例目录名判断版本。
    // mcVersion 可以是中文或整合包名，只有 graphicsEnvironment.realMcVersion 才是版本事实。
    const graphicsEnvironment: GraphicsProfileInput = await prepareGraphicsProfileInput(
      this.context, this.mcDir, mcVersion, preferenceManager.graphicsProfile, false,
      preferenceManager.graphicsProfileExplicit)
    const graphicsPreference: MinecraftGraphicsPreferenceInput = {
      launcherProfile: preferenceManager.graphicsProfile,
      launcherExplicit: preferenceManager.graphicsProfileExplicit,
      developerOverride: devRendererOverride,
      optionsText: this.readGameGraphicsOptions(gameDir),
    }
    const graphicsRequest: MinecraftGraphicsRequest = resolveMinecraftGraphicsRequest(graphicsEnvironment, graphicsPreference)
    const recoveryId: string = AppStorage.get<string>('graphicsRecoveryId') ?? ''
    this.graphicsRecoveryTicket_ = recoveryId.length > 0 ? GraphicsRecoveryStore.ticket(filesDir, recoveryId) : undefined
    const recoveryTicket = this.graphicsRecoveryTicket_
    if (recoveryTicket !== undefined && recoveryTicket.attempt === 1
      && (graphicsRequest.preferenceExplicit || graphicsRequest.requireVulkan || devRendererOverride.length > 0)) {
      this.statusText = '图形设置已更改，已停止自动恢复，请重新启动游戏'
      this.recordLaunchFailure_(mcVersion, this.statusText)
      return
    }
    const requestedGraphicsProfile: string = recoveryTicket !== undefined && recoveryTicket.attempt === 1
      && recoveryTicket.retryProfile.length > 0 ? recoveryTicket.retryProfile : graphicsRequest.requestedProfile
    if (recoveryTicket !== undefined && recoveryTicket.attempt === 1) {
      graphicsEnvironment.graphicsRecoveryProfile = requestedGraphicsProfile
    }
    graphicsEnvironment.userPreferredBackendId = requestedGraphicsProfile
    graphicsEnvironment.graphicsProfilePreference = requestedGraphicsProfile
    graphicsEnvironment.graphicsProfileExplicit = graphicsRequest.preferenceExplicit
    // 自动模式中的游戏 OpenGL 偏好作为 API 策略传递；默认 Vulkan 不变成显式锁定。
    graphicsEnvironment.vulkanPolicy = graphicsRequest.vulkanPolicy
    // 保留既有严格 Vulkan 政策：用户/游戏请求 Vulkan 时，设备或窗口准入失败应终止，
    // 不能静默回到 OpenGL。真实模块、provider 与审计证据仍由 adapter/resolver 逐项验证。
    if (graphicsRequest.requireVulkan) graphicsEnvironment.gameApi = GraphicsGameApi.VULKAN
    if (preferenceManager.graphicsProfileExplicit && devRendererOverride.length === 0) {
      this.applyGameGraphicsPreference(gameDir, graphicsEnvironment.realMcVersion, preferenceManager.graphicsProfile)
    }
    this.launchLogger_().info('GraphicsCapability', 'Graphics launch evidence: ' + JSON.stringify(graphicsEnvironment), LOG_DOMAIN_LAUNCH)
    AppLogger.flush()
    let builder = new LaunchProfileBuilder()
      .setGraphicsEnvironment(graphicsEnvironment)
      .setFilesDir(filesDir)
      .setMcDir(this.mcDir)
      .setActivityId(this.launchStartedAt_)
      .setGameDir(gameDir)
      .setVersion(mcVersion)
      .setJdkVersion(jdkVersion)
      .setXmxMb(mcXmx)
      .setWindowSize(surfaceW, surfaceH)
      .setCustomJvmArgs(preferenceManager.resolveLaunch(mcVersion).customJvmArgs)
      .setGraphicsProfile(requestedGraphicsProfile)
      // DevTools 后端覆盖（candidate 验证通道，治理规范 §2.3）。产品常态是空串 = 无覆盖；
      // 开发验证产品的设置页与 DevTools 共用覆盖偏好；解析器校验候选状态和 SDL3 路线。
      .setDevRendererOverride(devRendererOverride)
    account.fillProfile(builder)

    // 第三方皮肤站（authlib-injector）：提取 jar + 预取元数据，注入 javaagent。
    // 失败即中断启动（对齐 PCL2：连不上皮肤站就不该带着半截配置进游戏）。
    if (account.type === AccountType.AUTHLIB_INJECTOR) {
      let authlibErr = await this.prepareAuthlibInjector_(account as AuthlibInjectorAccount, builder, filesDir)
      if (authlibErr.length > 0) {
        this.launchLogger_().error(TAG, `authlib-injector prep failed: ${authlibErr}`, null, LOG_DOMAIN_LAUNCH)
        this.statusText = '❌ 启动终止：第三方登录准备失败\n' + authlibErr
        this.showLog = true
        this.refreshLog()
        this.recordLaunchFailure_(mcVersion, '第三方登录准备失败: ' + authlibErr)
        return
      }
    }

    try { await builder.prepareLogging() }
    catch (e) {
      this.statusText = '日志配置准备失败：' + (e as Error).message
      this.recordLaunchFailure_(mcVersion, this.statusText)
      return
    }
    let profile = builder.build()
    this.graphicsCurrentVersion_ = mcVersion
    this.graphicsHistoryScope_ = graphicsEnvironment.graphicsHistoryScope ?? ''
    if (profile !== null && profile.graphicsPlan !== undefined) {
      this.graphicsCurrentProfile_ = profile.graphicsPlan.profile
      this.graphicsRecoveryNext_ = graphicsRecoveryCandidate(profile.graphicsPlan)
      this.graphicsRecoveryAutomatic_ = !graphicsRequest.preferenceExplicit && !graphicsRequest.requireVulkan
        && devRendererOverride.length === 0
    }
    if (nativeGlValidation && profile !== null && !profile.extraJvmArgs.includes('-Damcl.gl.backend=nativegl')) {
      this.statusText = '此版本不在原生 OpenGL 验证范围内'
      this.recordLaunchFailure_(mcVersion, this.statusText)
      return
    }

    if (profile) {
      this.launchLogger_().info(TAG, `LaunchProfile: main=${profile.mainClass} lwjgl=${profile.lwjglVersion}`, LOG_DOMAIN_LAUNCH)
      this.statusText = '正在启动 ' + mcVersion + ' (' + profile.mainClass.split('.').pop() + ')...'
    } else {
      let reason = builder.getLastBuildError()
      if (!reason || reason.length === 0) {
        reason = '构建启动配置失败'
      }
      this.launchLogger_().error(TAG, `Launch blocked by precheck: ${reason}`, null, LOG_DOMAIN_LAUNCH)
      this.statusText = '❌ ' + reason
      this.showLog = true
      this.refreshLog()
      this.recordLaunchFailure_(mcVersion, reason)
      return
    }

    // ============================================================
    //  活动账本（L3）：开本局的账本，并把 native 启动线程的日志归属设过去。
    //
    //  必须在 mcLaunchWithProfileV2 **之前**做完 —— native 启动线程一开跑就在写
    //  MC_LAUNCHER / JVM_LAUNCHER 日志（真机统计占启动器日志的 81%），
    //  晚一步这些行就归属不上，账本里会缺掉整个启动过程。
    //
    //  sessionStartedAt 之后要原样传给 SessionMarker.writeStart —— 它同时是
    //  活动记录主键、M3 的 sessionKey 与账本 activityId，三者必须是同一个值。
    // ============================================================
    if (this.launchLifecycleEpoch !== this.inputLifecycleEpoch || this.navigatedAway) return
    const sessionStartedAt: number = this.launchStartedAt_
    try {
      let meta: LedgerBeginMeta = {
        category: ActivityCategory.LAUNCH,
        title: mcVersion,
        gameVersionId: mcVersion,
        jdk: profile.jdkVersion,
        gameDir: profile.gameDir,
        // 封账与中断恢复时按会话身份将完整游戏输出归档到账本。
        mcDir: this.mcDir,
        appFilesDir: this.applicationFilesDir_(),
      }
      // 自动图形恢复票据携带最初尝试的身份，详情据此显示真实关联，不合并两局原件。
      if (recoveryTicket !== undefined && recoveryTicket.attempt === 1 && recoveryTicket.rootActivityId !== sessionStartedAt) {
        meta.parentActivityId = recoveryTicket.rootActivityId
        meta.relation = 'graphics-recovery'
      }
      ledgerBegin(profile.filesDir, sessionStartedAt, enrichSessionEnvironment(this.context, sessionStartedAt, meta, profile))
      testNapi.amclLedgerSetLaunchActivity(sessionStartedAt)
    } catch (e) {
      // 账本开失败绝不能阻断启动（设计文档 §8 的硬要求）
      this.launchLogger_().warn(TAG, 'ledger begin for game session failed', e, LOG_DOMAIN_LAUNCH)
    }

    try {
      // v4 数据驱动启动：参数数组直传（避免逗号拼接破坏 Forge 参数）。
      //
      // 关键修复：以前 V2 失败 + !isForgeLaunch 时会降级到 V1 字符串协议（mcArgs.join(',')），
      // 但 Vanilla MC 1.13+ 的 game args 也可能含逗号（如 quickPlay 系列、Paper 服务器 IP 等），
      // 字符串拼接会破坏参数语义。统一禁用降级：V2 失败就是失败，让上层走错误路径。
      this.runtimeSlotLease_ = testNapi.runtimeSlotAcquire(profile.lwjglJarDir)
      const leasedSlot = await verifyLwjglRuntimeSlot(profile.lwjglJarDir)
      if (!leasedSlot.ok) {
        testNapi.runtimeSlotRelease(this.runtimeSlotLease_)
        this.runtimeSlotLease_ = ''
        throw new Error(leasedSlot.detail)
      }
      let rc = testNapi.mcLaunchWithProfileV2(
        profile.filesDir, profile.gameDir, profile.jdkVersion, profile.xmxMb,
        profile.mainClass, profile.classpath, profile.mcArgs, profile.extraJvmArgs
      )
      if (rc !== 0) {
        if (this.runtimeSlotLease_.length > 0) {
          testNapi.runtimeSlotRelease(this.runtimeSlotLease_)
          this.runtimeSlotLease_ = ''
        }
        this.launchLogger_().error(TAG,
          `mcLaunchWithProfileV2 failed (rc=${rc}, generation=${profile.generation}, delivery=${profile.classpathDelivery}); legacy V1 fallback disabled to avoid arg corruption`,
          null, LOG_DOMAIN_LAUNCH)
      }
      if (rc !== 0) {
        let status: string = testNapi.mcGetStatus()
        // 只消费本次同步调用的结构化失败。已锁存 provider 的进程通过现有“返回”流程
        // 退出后才能重新启动；不在此处循环调用 native 或静默改掉用户的 Vulkan 请求。
        let graphicsFailure: GraphicsLaunchFailure | undefined = undefined
        try {
          graphicsFailure = parseGraphicsLaunchFailure(testNapi.mcGetGraphicsLaunchFailure(), rc)
        } catch (error) {
          this.launchLogger_().warn(TAG, 'Graphics failure detail unavailable', error, LOG_DOMAIN_LAUNCH)
        }
        if (graphicsFailure !== undefined) {
          this.launchLogger_().error(TAG, 'Graphics launch rejected: ' + JSON.stringify(graphicsFailure), null, LOG_DOMAIN_LAUNCH)
        }
        this.statusText = '❌ ' + graphicsLaunchFailureMessage(status, graphicsFailure)
        this.showLog = true
        this.refreshLog()
        this.recordLaunchFailure_(mcVersion, 'mcLaunchWithProfileV2 rc=' + rc + ': ' + status
          + (graphicsFailure === undefined ? '' : ' [' + graphicsFailure.stage + '/' + graphicsFailure.code + ']'))
        if (graphicsFailure !== undefined && graphicsFailure.profile === this.graphicsCurrentProfile_) {
          if (this.requestGraphicsRecovery_(graphicsFailure.stage, graphicsFailure.code, 0, graphicsFailure.diagnosticInjected === true)) this.requestExit_()
        }
        return
      }
      this.mcStarted = true
      // Phase 3.3：native session 已建立，补报启动前就已接入的设备。
      // 必须在 mcStarted 之后：更早 publish 只会被 ingress 记成 stale consumer 噪声。
      this.publishInitialDeviceInventory()
      this.statusText = 'MC 运行中'
      this.launchLogger_().info(TAG, 'MC launched successfully', LOG_DOMAIN_LAUNCH)

      // 写 SessionMarker：MC 一旦因 System.exit 触发 SIGABRT 杀掉整个 app，
      // 这个标记会在下次冷启动时被 EntryAbility 读出来，给 Index 显示
      // 错误 Sheet（v6 起从简单 toast 升级为带 stack trace 的结构化 Sheet）。
      // mcDir 用于冷启动后定位 mc_output.log；版本隔离场景下必传。
      // 详见 SessionMarker.ets 文件头注释 + docs/archive/jdk21-awt-headless-journey-202605.md §5.2。
      // 传入上面开账本用的同一个 sessionStartedAt（活动账本 · L3）：
      // marker / 活动记录 / 账本必须共用一个主键，否则冷启动回流时对不上。
      SessionMarker.writeStart(filesDir, mcVersion, this.mcDir, sessionStartedAt)

      // 方案 B：grabbed 状态改为 native 回调驱动（取代旧的 300ms 轮询）。
      // MC 的 GLFW 层翻转 grab 时经 native threadsafe function 即时回到 UI 线程，
      // 无延迟、无 env 竞争。先读一次初始态兜底，再注册回调接管后续变化。
      try { this.isInGame = testNapi.isGrabbed() } catch (e) { /* ignore */ }
      try {
        testNapi.onGrabChange((grabbed: boolean) => { this.isInGame = grabbed })
      } catch (e) {
        this.launchLogger_().warn(TAG, 'onGrabChange register failed', e, LOG_DOMAIN_LAUNCH)
      }
      // 兜底轮询：即使 onGrabChange 未触发，也保证进/出世界时虚拟按键显隐正确同步。
      this.startGrabPoll()

      // 轮询日志（递归 setTimeout）。终止条件：navigatedAway（doExit 已设置）或 MC 进程已退出。
      // R9：补上 navigatedAway 检查，让组件 disappear 后 poll 链不再续。
      // 即便 mcForceExit 在 doExit 内调用通常会终止整个进程，这里加上守卫提升鲁棒性。
      //
      // 优化：refreshLog 每秒读 16KB 日志写入 @State this.mcLog，但仅在
      // showLog=true 时展示。用户没打开日志面板时跳过 IO 与状态更新，
      // 减少 ArkTS 主线程压力（长时间游戏会话累计能节省可观时间）。
      let poll = () => {
        if (this.navigatedAway) return
        if (this.showLog) {
          this.refreshLog()
        }
        let running: boolean = testNapi.mcIsRunning()
        if (!running) {
          this.launchLogger_().info(TAG, 'MC process exited, navigating back to launcher', LOG_DOMAIN_LAUNCH)
          this.requestExit_()
        } else {
          setTimeout(poll, 1000)
        }
      }
      setTimeout(poll, 1000)
    } catch (e) {
      this.statusText = '❌ 启动异常: ' + formatError(e)
      this.showLog = true
      this.recordLaunchFailure_(mcVersion, '启动异常: ' + formatError(e))
    } finally {
      // 校验异常和 NAPI 抛错同样必须归还未使用的租约；一旦 native 启动成功，
      // JVM 仍可能延迟加载类，租约必须保留到整个游戏进程退出，不能随页面销毁释放。
      if (!this.mcStarted && this.runtimeSlotLease_.length > 0) {
        testNapi.runtimeSlotRelease(this.runtimeSlotLease_)
        this.runtimeSlotLease_ = ''
      }
    }
  }

  /** 只读取游戏选项快照；是否支持 API 偏好由纯逻辑使用真实基础版本判断。缺文件沿用默认。 */
  private readGameGraphicsOptions(gameDir: string): string {
    if (gameDir.length === 0) return ''
    try {
      return fs.readTextSync(gameDir + '/options.txt')
    } catch (e) {
      return ''
    }
  }

  /** 将启动器显式选择的 API 同步到游戏选项；名称映射只查询 canonical registry。 */
  private applyGameGraphicsPreference(gameDir: string, realMcVersion: string, profileId: string): void {
    if (gameDir.length === 0) return
    const backend: string = minecraftGraphicsBackendForProfile(realMcVersion, profileId).toLowerCase()
    if (backend.length === 0) return
    const optionsPath: string = gameDir + '/options.txt'
    try {
      let original: string = ''
      try { original = fs.readTextSync(optionsPath) } catch (e) { original = '' }
      const newline: string = original.indexOf('\r\n') >= 0 ? '\r\n' : '\n'
      const hadTrailingNewline: boolean = original.endsWith('\n') || original.endsWith('\r')
      const sourceLines: string[] = original.length === 0 ? [] : original.split(new RegExp('\\r?\\n'))
      if (hadTrailingNewline && sourceLines.length > 0 && sourceLines[sourceLines.length - 1] === '') {
        sourceLines.pop()
      }
      const replacement: string = 'preferredGraphicsBackend:"' + backend + '"'
      const cleanStartupMarker: string = 'startedCleanly:true'
      let found: boolean = false
      let startupMarkerFound: boolean = false
      for (let i = 0; i < sourceLines.length; i++) {
        if (sourceLines[i].startsWith('preferredGraphicsBackend:')) {
          sourceLines[i] = replacement
          found = true
        }
        if (sourceLines[i].startsWith('startedCleanly:')) {
          sourceLines[i] = cleanStartupMarker
          startupMarkerFound = true
        }
      }
      if (!found) sourceLines.push(replacement)
      // Minecraft deliberately resets a Vulkan preference after it observes
      // an unclean previous launch.  The launcher owns this pre-launch marker
      // for an explicit Settings choice, just like FCL, so a failed previous
      // process cannot silently turn the next Vulkan launch back into the
      // OpenGL-first default path.
      if (!startupMarkerFound) sourceLines.push(cleanStartupMarker)
      let updated: string = sourceLines.join(newline)
      if (hadTrailingNewline || sourceLines.length > 0) updated += newline
      const file = fs.openSync(optionsPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try {
        fs.writeSync(file.fd, updated)
        fs.fsyncSync(file.fd)
      } finally {
        fs.closeSync(file)
      }
      this.launchLogger_().info(TAG, 'Synchronized Minecraft graphics preference: ' + replacement
        + ' and ' + cleanStartupMarker, LOG_DOMAIN_LAUNCH)
    } catch (e) {
      // The native profile remains authoritative for this launch. Keep a
      // visible warning when a read-only game directory blocks persistence.
      this.launchLogger_().warn(TAG, 'Cannot synchronize Minecraft graphics preference at ' + optionsPath, e, LOG_DOMAIN_LAUNCH)
    }
  }
}

/**
 * GameControls.ets — 虚拟按键（Control Schema v2 + ArkUI 辅助交互）
 *
 * 当前所有权：
 * - grabbed 下的摇杆、普通按钮、滚轮、hotbar 与 look 由 native schema 解释并产生输入；
 * - native 按钮视觉边沿经 onButtonPressed 投影回来，ArkTS 不再为已接管控件重复发键；
 * - IME、drawer/抽屉子按钮等 handledBy=arkts 控件仍由 ArkUI exact rect 处理；
 * - legacy region 注册仅在 schema 不可用时过滤 native look，不是第二套输出状态源。
 *
 * ArkTS 仍维护的 finger/trigger/WASD 状态只服务 handledBy=arkts 与兼容路径；生命周期边界先调用
 * native cancelAll 清空权威 ledger，再清这些 UI/兼容瞬时状态，禁止恢复 grabbed 主路径双发。
 */
import testNapi from 'libentry.so';
import { ControlSchemaEntry, ControlSchemaMsg } from 'libentry.so';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  GLFW_PRESS, GLFW_RELEASE,
  GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D, GLFW_KEY_1,
  isMouseCode, decodeMouse,
  SCROLL_YOFFSET_UP, SCROLL_YOFFSET_DOWN
} from 'gamecontrol';
import {
  ControlItem, ControlType, LayoutProfile, TriggerMode,
  getDefaultLayout, cloneLayout,
  DEFAULT_JOYSTICK_DEAD_ZONE, effectiveKeys, HOTBAR_SLOT_COUNT,
  effectiveCornerRadius, effectiveLabel, isVisibleInScene, renderOpacity
} from 'gamecontrol';
import { getLayoutStore } from 'gamecontrol';
import { LayoutEditor } from './LayoutEditor';
import { ChatInputBridge } from './ChatInputBridge';
import { hapticTap } from 'feature_system';
import { getInputDeviceMonitor, DeviceCapability } from 'gamecontrol';
import { getPhysicalPointerEcho } from 'gamecontrol';
import { getImeActivationGate } from 'gamecontrol';
import { getInputSourceRegistry, AmclInputSource, InputEnd, CallbackInputEnd } from 'gamecontrol';
import { joystickSector } from 'gamecontrol';
import {
  EntryControlFeedbackLease,
  acquireEntryControlFeedback,
  releaseEntryControlFeedback
} from './EntryControlFeedbackBroker';
import {
  InputSurfaceContext,
  INPUT_SURFACE_FIELD_DENSITY,
  getInputSurfaceContextStore
} from 'gamecontrol';

// 夹取后的控件物理像素矩形（clampEntryRect 返回值）。
interface RectPx { x: number; y: number; w: number; h: number }

// ---- 触控虚拟按键端的输出出口，全部**申报端身份** ----
//
// 这些是本端在"native 未接管"时（菜单态、handledBy=arkts 控件、schema 不可用降级）
// 的输出路径；grabbed 下被 C 层解释器接管的那部分不经过这里（它在 native 侧用
// schema owner 直接进 ledger）。同一个端因 grabbed 走两套 owner 体系是既有设计，
// 端身份让两者在诊断上归到同一栏。
//
// 申报端身份带来的实际差别：手柄和触控端可能映射到同一个键（例如手柄 A 与屏幕跳跃键
// 都是空格）。ledger 按引用计数聚合，所以同时按住是正确的；但**抬起必须与自己的按下
// 配对**，否则一端的 RELEASE 会拿走另一端的 owner。旧实现取队首，正是这个缺陷。
const TOUCH_SOURCE: number = AmclInputSource.TouchControls as number

function sendKey(key: number, action: number): boolean {
  return testNapi.sendSourceKeyEvent(TOUCH_SOURCE, key, 0, action, 0)
}
function sendMouse(button: number, action: number): boolean {
  return testNapi.sendSourceMouseEvent(TOUCH_SOURCE, button, action, 0)
}

// 阶段 1.4：方向稳定锁存窗口（毫秒）。release 后该窗口内不允许 press 反向键。
const JOYSTICK_REPRESS_LOCKOUT_MS: number = 30

// 阶段 1.5：滚轮控件灵敏度——纵向每移动 SCROLL_STEP_VP 触发一次 scroll 事件。
//   12 vp ≈ 大拇指轻轻一拨的距离，对应 hotbar 切一格。
const SCROLL_STEP_VP: number = 12

// 阶段 4.2：摇杆 onTouch 视觉刷新节流（毫秒）。60Hz ≈ 16ms。
//   - WASD PRESS / RELEASE 仍即时发，不节流（玩家手感优先）。
//   - 仅 joystickX / joystickY 这俩 @State（驱动内圈视觉位置）按节流刷。
//   - 设为 0 关闭节流。中端机能耗显著优化。
const JOYSTICK_VISUAL_THROTTLE_MS: number = 16

// native OH_NativeXComponent_TouchPointToolType 的编号（**不是** ArkUI SourceTool）。
// 真机上 ArkUI 事件的 sourceTool 填的是这一套：真实鼠标 = 7。详见 isPointerDeviceSourced。
const NATIVE_TOOL_TYPE_MOUSE: number = 7
const NATIVE_TOOL_TYPE_LENS: number = 8

const VIS_ALL: number = 0
const VIS_MENU: number = 1
const VIS_HIDE: number = 2
const GAME_CONTROLS_TAG: string = 'GameControls'

// 方案 E.2（渲染精修 2026-07-11）：单个按钮的按下视觉状态对象。
// 父组件持有每个按钮的稳定状态对象；setPressed 修改 pressed 并递增 btnPressedVer，
// 由父组件重建后通过 @Prop 传给按钮子组件，避免普通表达式误绑定 @ObjectLink。
@Observed
class BtnVisState {
  pressed: boolean = false
}

class ArktsButtonOutputRecord {
  keys: number[] = []
}

// 方案 E.2：可复用按钮视图子组件（普通按钮 + 抽屉子按钮共用）。
// - @Prop vis：父级 btnPressedVer 变化触发重建时读取最新 pressed；不依赖不稳定的 @ObjectLink 刷新。
// - 几何 / 颜色 / 标签由父级算好传入（一次性 @Prop，仅布局变化时才随父级重建刷新）。
// - onTouchEvent：把触摸事件原样回调给父级处理（buttonAddFinger/dragLook 等逻辑全留在父级，行为零变化）。
@Component
struct ButtonItemView {
  @Prop vis: BtnVisState
  // 父级 setPressed 时自增此值 → 本组件作为 @Prop 变化重渲染并读取当前 vis.pressed；
  // 值本身不参与渲染。
  @Prop pressedVer: number
  @Prop label: string
  @Prop x: number
  @Prop y: number
  @Prop w: number
  @Prop h: number
  @Prop fontSizeVp: number
  @Prop borderRadiusVp: number
  @Prop opacityVal: number
  @Prop fgNormal: string
  @Prop fgPressed: string
  @Prop bgNormal: string
  @Prop bgPressed: string
  onTouchEvent: (event: TouchEvent) => void = () => {}
  onAccessibilityActivate: () => void = () => {}
  private lastPhysicalTouchAtMs: number = 0

  private forwardTouch(event: TouchEvent): void {
    this.lastPhysicalTouchAtMs = Date.now()
    this.onTouchEvent(event)
  }

  private activateWithoutTouch(): void {
    if (Date.now() - this.lastPhysicalTouchAtMs < 500) return
    this.onAccessibilityActivate()
  }

  build() {
    Text(this.label)
      .width(this.w)
      .height(this.h)
      .fontSize(this.fontSizeVp)
      .fontWeight(FontWeight.Medium)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .fontColor(this.vis.pressed ? this.fgPressed : this.fgNormal)
      .borderRadius(this.borderRadiusVp)
      .backgroundColor(this.vis.pressed ? this.bgPressed : this.bgNormal)
      .opacity(this.opacityVal)
      .scale({ x: this.vis.pressed ? 0.95 : 1.0, y: this.vis.pressed ? 0.95 : 1.0 })
      .animation({ duration: 50, curve: Curve.EaseOut })
      .position({ x: this.x, y: this.y })
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .accessibilityText(this.label)
      .accessibilityDescription(this.vis.pressed ?
        $r('app.string.input_control_pressed') : $r('app.string.input_control_released'))
      .onTouch((event: TouchEvent) => { this.forwardTouch(event) })
      .onClick(() => { this.activateWithoutTouch() })
  }
}

@Component
export struct GameControls {
  @Prop @Watch('onGrabChanged') isGrabbed: boolean = false
  @Prop @Watch('onSurfaceContextChanged') surfaceContextGeneration: number = 0

  // 布局数据
  @State profile: LayoutProfile = getDefaultLayout()
  @State profileVer: number = 0

  // 编辑模式
  @State editing: boolean = false
  /** 打开期间也独占一次编辑请求，避免预设克隆尚未完成时连续点击创建多个副本。 */
  private editorOpening: boolean = false
  /** 本组件持有的编辑租约与暂停状态；只释放自己取得的那一份，不干扰子编辑器租约。 */
  private editorLeaseHeld: boolean = false
  private editorInputPaused: boolean = false
  private editorDisposeTask: Promise<void> | undefined = undefined


  // 全局按键可见性档位（2026-06 重构，取代旧的"接键鼠才出现 + forceShowAll"耦合逻辑）。
  // 左下角按钮循环切换：0=全部显示 / 1=仅菜单按键 / 2=全部隐藏（全透明，按钮自身消失但热区可点恢复）。
  // 与键盘/鼠标 capability 解耦——纯手动的全局隐藏手段。
  @State globalVisMode: number = 0

  // 阶段 2.8：IME 桥接显隐
  @State @Watch('onImeOpenChanged') imeOpen: boolean = false

  // 2026-05-30：通用文本框输入（菜单态）。点浮动键盘按钮 → field 模式 IME 桥，
  // 字符实时同步进 MC 当前聚焦的 EditBox（存档搜索 / 创造物品栏搜索 / JEI 搜索等），
  // 提交/取消不发 ENTER/ESC（避免误关 MC GUI 屏）。
  @State @Watch('onImeOpenChanged') fieldImeOpen: boolean = false

  // ⚠️ 这里曾有 `@State currentInputMode: InputMode` 与它的 InputModeManager 监听器。
  // **已删除**：那是一条只写不读的链路 —— 字段在 build() 与任何判断里都没有被读到
  // （按钮可见性早已改用 capability 监听器），而它的上游 `notify('touch')` 全仓根本
  // 没有调用点，也就是说三端里连触控端自己都不是它的生产者。
  //
  // 「最近活跃的是哪个端」这个概念**整体没有被保留**。同一轮里我曾把它搬进
  // InputSourceRegistry 并补上触控端生产者，但那个版本**同样没有读取方** ——
  // 只是把空抽象换了个位置，还在 onMouse Move 热路径上加了一次 Date.now()。
  // 判据记在 InputSourceRegistry.ets 里：先有消费者，再有生产者。

  /**
   * 触控虚拟按键端的 InputEnd 适配器。
   *
   * 本端的按下态分两处：grabbed 下被 C 层解释器接管的部分（native schema owner，由
   * native 的 schemaResetTransientStateLocked 负责），以及本组件在菜单态 /
   * handledBy=arkts / schema 降级时自己维护的那部分。这里负责后者。
   *
   * keepHeldButtons=false：这是"后续抬起不保证到达"的边界，必须整体放干净。
   */
  private touchControlsEnd: InputEnd = new CallbackInputEnd(
    AmclInputSource.TouchControls, 'GameControls',
    (reason: string) => { this.resetTransientInputState() },
    (reason: string) => { this.dropHeldCacheAfterNativeReset() })

  /**
   * native 已归零后的**纯缓存丢弃**：不发任何 GLFW 边沿，不动任何用户可见状态。
   *
   * 与 `resetTransientInputState()` 的区别是刻意的，也是本方法存在的全部理由：
   * 那个函数会关闭聊天输入条（imeOpen / fieldImeOpen）、收起抽屉（drawerOpen）、
   * 清 toggle 与 longPress 状态机（内部还会补发 RELEASE）。而本方法的调用方是
   * reset-epoch 对账，它挂在**每个物理按键事件**上 —— 用那个函数顶替本方法，
   * 结果就是"用户按一下键盘，聊天输入框和抽屉莫名关掉"。
   *
   * 这里只清"我认为哪些键还按着 / 哪根手指占着哪个控件"这类**本端自己的账本**：
   * 账本不清会让下一次按下被误判成重复按下（集合非空 → 不发 PRESS），表现为该控件失灵。
   *
   * ⚠️ native 侧对应的 owner **不一定**已经被清空（2026-08-21）：驱动本方法的 reset epoch
   * 有两个语义，"typed core 观测到自己的 RESET"那一路不清 external held 与 ledger，而
   * surface 几何变化（平板分屏 / 悬浮窗 / 折叠屏形态切换）只产生那一路。所以清空由
   * `InputSourceRegistry.dropAllEndStateAfterNativeReset` 在广播完本方法之后按端强制执行 ——
   * 本组件不要自己去调，否则端级复位计数翻倍。因果与卡键机制见注册表那个方法上方。
   * 本端受影响的载体是 `buttonFingerIds` / `toggleStates` / `longPressFired`
   * （grabbed 下的 schema owner 走 C 层、不经 external 表，不受影响；
   * 但 handledBy=arkts 的抽屉子按钮在 grabbed 下仍走本组件，同样受影响）。
   *
   * 刻意保留的东西：`keyLastReleaseAt`（30ms 方向锁存的时间戳，清掉会让复位瞬间的
   * 反向键失去去抖）、按下视觉（下一次真实边沿会刷新它）、IME / 抽屉 / 可见性档位。
   */
  private dropHeldCacheAfterNativeReset(): void {
    // 方向键：只从"按下集合"里摘掉，不发 RELEASE。
    this.activeKeys.clear()
    this.joystickFingerId = -1
    this.joystickX = 0
    this.joystickY = 0
    // 按钮占用集合：native owner 已空，这里必须同步清，否则集合非空会吞掉下一次 PRESS。
    this.buttonFingerIds.forEach((set: Set<number>) => { set.clear() })
    this.arktsButtonOutputs.clear()
    // 按下高亮跟着账本走（这是账本的投影，不是独立的用户状态）。
    this.btnVisMap.forEach((v: BtnVisState) => { v.pressed = false })
    this.btnPressedVer++
    // longPress 定时器必须清：它们的回调会在复位之后 fire 并发出一个无主的 PRESS。
    this.longPressTimers.forEach((tid: number) => clearTimeout(tid))
    this.longPressTimers.clear()
    this.longPressFired.clear()
    this.toggleStates.clear()
    this.accessibilityToggleStates.clear()
    this.lastTapAt.clear()
    // 手势跟踪基准：不清会让复位后的第一个 MOVE 算出一段跨越整次复位的假位移。
    this.scrollFingerIds.clear()
    this.scrollAccumDy.clear()
    this.scrollLastY.clear()
    this.hotbarFingerId.clear()
    this.hotbarLastSlot.clear()
    this.dragLookFinger.clear()
    this.dragLookLastX.clear()
    this.dragLookLastY.clear()
  }

  // 物理设备插拔状态。
  //
  // ⚠️ **这是一条只写不读的链路（2026-08-20 全仓核实）。** 本字段只有下面两处赋值
  // （listener 与 aboutToAppear），**零读取点** —— `isControlVisible` 与 build() 都不看它。
  //
  // 三句已删除的假注释，记在这里防止有人"照原样写回去"：
  //   ① 「变化时触发 build 重渲染让按钮显隐生效」 —— 重渲染确实会发生（@State），
  //      但渲染结果**逐位相同**，因为可见性判定不读 capability。
  //   ② 「capability 变化后还要重新注册 C 层命中矩形（否则隐藏的按钮仍吞 native 视角）」
  //      —— 这句最危险，它给出一条**因果**。真实情况：`registerRegions` →
  //      `sendControlSchema` → `isControlVisible` 全链不读 capability，所以 listener 里
  //      那次调用的输出恒等，那个"否则"永远不会发生。
  //   ③ `aboutToAppear` 处的「按钮显隐随插拔实时变化」 —— 同上，不成立。
  //
  // 为什么保留而不删：`hideOnInput` 那条数据链已经写进用户磁盘上的布局文件，
  // 删字段要连迁移一起设计；而"要不要自动显隐"是产品决定。两条路的代价见
  // `docs/refactor/多输入端架构愿景与改进提案.md` §9.1。
  @State capability: DeviceCapability = { mouse: false, keyboard: false, gamepad: false }
  private capabilityListener: (c: DeviceCapability) => void = (c: DeviceCapability) => {
    this.capability = c
    // 保留这次调用只为"capability 变化时布局表仍被重新下发一次"这个无害的现状；
    // 它不产生任何可观测差异（见上）。
    this.registerRegions()
  }

  // 摇杆视觉状态
  @State joystickX: number = 0
  @State joystickY: number = 0

  // 阶段 1.1 多指：摇杆当前占用的 fingerId（-1 = 未被占用）
  // 摇杆只跟踪自己 DOWN 时拿到的那根 finger；其他 finger 进入摇杆区时忽略。
  private joystickFingerId: number = -1

  // 阶段 4.2：摇杆视觉刷新节流的"上次刷新时间戳"
  private joystickLastVisualUpdateAt: number = 0

  // 按钮按下状态（用于高亮）。id → 稳定 BtnVisState；btnPressedVer 驱动子组件读取最新状态。
  private btnVisMap: Map<string, BtnVisState> = new Map()
  // 2026-07-11 修复：真机上持续高亮未能可靠触发子组件重渲染。
  // 加一个 @State 版本号作为明确的重渲染信号：setPressed 时自增 → build 重跑 →
  // ButtonView 重建 ButtonItemView 并通过 @Prop 读取当前 vis.pressed，保证视觉一定跟上。
  @State private btnPressedVer: number = 0

  // 按 id 取（不存在则建）按下态对象；稳定实例集中保存按钮视觉状态。
  private getBtnVis(id: string): BtnVisState {
    let v = this.btnVisMap.get(id)
    if (!v) { v = new BtnVisState(); this.btnVisMap.set(id, v) }
    return v
  }

  // 阶段 1.1 多指：每个按钮 id → 占用它的 fingerId 集合。
  // 集合空 ↔ 满变化才发 PRESS / RELEASE；避免双指交替按住同一按钮时漏 RELEASE。
  private buttonFingerIds: Map<string, Set<number>> = new Map()
  // Down-time output mapping for ArkTS-owned buttons. RELEASE never re-evaluates
  // grabbed/current schema ownership or a hot-reloaded mapping.
  private arktsButtonOutputs: Map<string, ArktsButtonOutputRecord> =
    new Map<string, ArktsButtonOutputRecord>()

  // 2026-05-30：拖动瞄准（dragLook）。按钮 id → 该按钮上正在拖动的 fingerId 及其上次坐标。
  // 用于"按住按钮（保持 PRESS）+ 拖动转视角"：MOVE 时按 finger 位移发 sendCursorDelta。
  private dragLookFinger: Map<string, number> = new Map()
  private dragLookLastX: Map<string, number> = new Map()
  private dragLookLastY: Map<string, number> = new Map()

  // 阶段 1.5：滚轮控件状态。每个滚轮 id → { fingerId, accumDy }。
  // accumDy 是从 DOWN 起累计的纵向位移（vp）；每达到 SCROLL_STEP_VP 触发一次 scroll 事件。
  private scrollFingerIds: Map<string, number> = new Map()
  private scrollAccumDy: Map<string, number> = new Map()
  private scrollLastY: Map<string, number> = new Map()

  // F1（2026-07-11）：物品栏直点条状态。每个 hotbar id → 占用 fingerId / 上次落在的槽位（用于滑动扫选去重）。
  // 物品栏发的是"数字键 tap（PRESS+RELEASE）"，无持续按住态，故无键卡死风险，仅跟踪 finger + lastSlot。
  private hotbarFingerId: Map<string, number> = new Map()
  private hotbarLastSlot: Map<string, number> = new Map()

  // 阶段 3.1：抽屉打开状态。每个 drawer id → 是否展开。
  @State drawerOpen: Map<string, boolean> = new Map()

  // WASD 追踪
  private activeKeys: Set<number> = new Set()
  // 阶段 1.4：键的最后一次 RELEASE 时间戳；用于 30ms 锁存抑制方向边界震荡。
  private keyLastReleaseAt: Map<number, number> = new Map()

  // 组件尺寸 + density
  @State compWidth: number = 0
  @State compHeight: number = 0
  private density: number = 0
  private mounted: boolean = false
  private appearanceGeneration: number = 0
  private feedbackLease: EntryControlFeedbackLease | undefined = undefined

  async aboutToAppear(): Promise<void> {
    this.mounted = true
    const expectedAppearanceGeneration: number = ++this.appearanceGeneration
    // 三端平级：把触控虚拟按键端登记进注册表，让所有复位边界都能覆盖到它。
    // 此前这一端的 ArkTS 状态在六个 native 复位边界上零覆盖（两个 Ability 的
    // onBackground、GameAbility.onDestroy、surface 销毁、失焦、窗口重建）——
    // 那些边界只调 cancelAllInput，而 cancelAllInput 触达不到本组件的字段。
    //
    // ⚠️ **必须在第一个 await 之前**。若放在 `await store.waitReady()` 之后，组件在
    // 等待期间被销毁时，`aboutToDisappear` 里的 unregister 会先跑（那时还没注册，是空操作），
    // 随后 await 的续体恢复并注册一个指向已销毁组件的端 —— 它永不注销，后续每次
    // 复位都会写一个已释放组件的 @State。官方文档也只保证"父组件 aboutToAppear 早于
    // 子组件创建"这条**同步**顺序，await 之后的续体不在任何顺序保证之内。
    getInputSourceRegistry().register(this.touchControlsEnd)
    const store = getLayoutStore()
    await store.waitReady()
    if (!this.mounted || expectedAppearanceGeneration !== this.appearanceGeneration) return
    store.refreshDeviceDerivedLayout()
    this.profile = cloneLayout(store.getActiveProfile())
    this.profileVer++
    // 监听物理设备插拔。⚠️ 这里曾写「按钮显隐随插拔实时变化」——**不成立**，
    // `this.capability` 是只写不读的（理由与三句假注释的原文见该字段处）。
    getInputDeviceMonitor().addCapabilityListener(this.capabilityListener)
    this.capability = getInputDeviceMonitor().capabilityNow()
    // C 接管按钮后，按下态由 C 推回 ArkTS 更新高亮（键与视觉同源）。
    if (this.schemaActive) {
      this.feedbackLease = acquireEntryControlFeedback((id: string, pressed: boolean) => {
        if (!this.mounted || expectedAppearanceGeneration !== this.appearanceGeneration) return
        this.getBtnVis(id).pressed = pressed
        this.btnPressedVer++
      }, (strength: number) => {
        if (!this.mounted || expectedAppearanceGeneration !== this.appearanceGeneration) return
        hapticTap(strength)
      })
      // native 是 grabbed 按钮 PRESS 的唯一生成者；系统触觉 API 留在 UI 线程执行。
      // TSFN 自身有界，UI 卡顿时反馈可丢弃，但绝不会阻塞触摸或延迟补震。
      if (this.feedbackLease === undefined) {
        hilog.warn(0x0000, GAME_CONTROLS_TAG, 'Native feedback broker unavailable')
      }
    } else {
      // Release 混淆配置或新旧 HAP/native 不匹配时 fail open 到旧 ArkTS 输出路径；
      // legacy native region 仍负责阻止控件触摸穿透成 look，避免整套按键同时失效。
      hilog.warn(0x0000, GAME_CONTROLS_TAG,
        'Native Control Schema unavailable; using ArkTS compatibility input')
    }
  }

  /**
   * Phase 1（fix/input-system §P0-2）：把所有"瞬时输入状态"的释放集中到一个方法里，
   * onGrabChanged / aboutToDisappear / 编辑模式入口 / setTouchPaused 都复用同一份。
   *
   * @param keepHeldButtons 多键健壮性（2026-05-30）：true 时**不**释放仍被手指按住的按钮
   *   （press/doubleTap 类占用集合非空的），只清"非按住"的瞬时态。用于 grabbed 翻转——
   *   因为"按住 F3 时按 F4 打开游戏模式切换器"会 ungrab，此时强制松 F3 会让切换器立刻关闭，
   *   只能切一次。保留按住态后，F3 的 UP 在玩家真正抬手时才到，可连续切换。
   *
   * 释放范围：
   *   - WASD activeKeys（releaseAllDirections）
   *   - 摇杆 finger / 视觉位移
   *   - 按钮 buttonFingerIds + pressedButtons + toggle/longPress 状态机
   *   - 滚轮三件套（scrollFingerIds / scrollAccumDy / scrollLastY）— 之前漏清，
   *     导致 grabbed 翻转后同 fingerId 再落到滚轮被忽略
   *   - imeOpen — 之前漏关，IME 桥会留在屏上
   *   - drawerOpen — 之前漏收，抽屉子按钮会浮在 grabbed=false 的 UI 上
   *
   * 不动的：齿轮淡化计时（由调用方按 isGrabbed 自行管理）。
   */
  private resetTransientInputState(keepHeldButtons: boolean = false): void {
    this.releaseAllDirections()
    this.joystickFingerId = -1
    this.joystickX = 0
    this.joystickY = 0
    this.buttonReleaseAllFingers(keepHeldButtons)
    if (!keepHeldButtons) this.releaseAllArktsButtonOutputs()
    // 滚轮：清三个 Map（buttonReleaseAllFingers 不管这块）
    this.scrollFingerIds.clear()
    this.scrollAccumDy.clear()
    this.scrollLastY.clear()
    // F1：物品栏直点条跟踪清理（无持续按住态，仅清 finger/slot 跟踪）
    this.hotbarFingerId.clear()
    this.hotbarLastSlot.clear()
    // 拖动瞄准跟踪清理（不论 keepHeld：抬手才有意义，状态泄漏会让下次 MOVE 误算位移）
    this.dragLookFinger.clear()
    this.dragLookLastX.clear()
    this.dragLookLastY.clear()
    // IME 桥：聊天框（ime_chat）按下会让 MC 打开聊天屏 → ungrab → 触发本方法。
    // 此时**不能**关闭 imeOpen（keepHeldButtons=true 即 grabbed 翻转场景），否则刚弹出的
    // 输入框立刻消失、打不了字。仅在"非 grabbed 翻转"的清理（编辑入口 / 销毁）时才关闭。
    // 用户提交 / 点空白 / 关闭由 ChatInputBridge 自己回调 onClose 处理。
    if (!keepHeldButtons && this.imeOpen) this.imeOpen = false
    // field 模式输入条同理：编辑入口 / 销毁时关闭；grabbed 翻转不动（菜单态才用它）。
    if (!keepHeldButtons && this.fieldImeOpen) this.fieldImeOpen = false
    if (!keepHeldButtons) {
      // 两个输入条都已确定关闭 → 无条件清空 IME 闸门的 owner 集合。
      //
      // 这是 owner 记账的**安全网**，不是冗余：按 owner 记账把"闸门被误关"（双发字符）
      // 换成了"owner 泄漏 → 闸门永久激活 → 物理键盘打不出可打印字符"，而后者更严重。
      // 把清空挂在这里，使"关掉了输入条却漏了 owner"在结构上不可能发生。
      // 注意必须在 `!keepHeldButtons` 分支内：grabbed 翻转时输入条刻意保持打开
      // （上面两行同样被挡住），那时清空会让仍在使用的 IME 失去保护、当场双发。
      getImeActivationGate().clear()
    }
    // 抽屉：grabbed 翻转或销毁时收起
    if (this.drawerOpen.size > 0) {
      this.drawerOpen.clear()
      this.drawerOpen = new Map(this.drawerOpen)
    }
  }

  // 阶段 1.1 / 2.4：grabbed 翻转时释放所有按下中的虚拟按键 / 摇杆 / 滚轮 / IME / 抽屉，防止状态泄漏，
  // 并重注册 C 层命中矩形（可见集合随 grabbed 改变）。
  onGrabChanged(): void {
    // 多键健壮性（2026-05-30）：grabbed 翻转时保留仍被按住的按钮（keepHeldButtons=true），
    // 支持"按住 F3 + 连点 F4"这类跨 grab 翻转的组合键（F4 开切换器会 ungrab）。
    this.resetTransientInputState(true)

    // R1：grabbed 翻转改变了 grabbedOnly / joystick / scroll 的可见性，
    // 重新注册 C 层命中矩形，避免 normal↔grabbed 切换后矩形表与渲染层不同步。
    this.registerRegions()
  }

  private onSurfaceContextChanged(): void {
    this.density = 0
    this.releaseInputForSurfaceRebuild()
    const store = getLayoutStore()
    if (store.isReady()) {
      store.refreshDeviceDerivedLayout()
      this.profile = cloneLayout(store.getActiveProfile())
      this.profileVer++
    }
    this.registerRegions()
  }

  private releaseInputForSurfaceRebuild(): void {
    this.releaseAllDirections()
    this.joystickFingerId = -1
    this.joystickX = 0
    this.joystickY = 0
    this.buttonReleaseAllFingers(false)
    this.releaseAllArktsButtonOutputs()
    this.scrollFingerIds.clear()
    this.scrollAccumDy.clear()
    this.scrollLastY.clear()
    this.hotbarFingerId.clear()
    this.hotbarLastSlot.clear()
    this.dragLookFinger.clear()
    this.dragLookLastX.clear()
    this.dragLookLastY.clear()
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.appearanceGeneration++
    // 编辑器可能仍在 await 克隆/保存；销毁不能把 native 永久留在 touch paused。
    // opening 的租约由其 finally 在回滚结束后释放；已显示的编辑器另持自己的租约。
    this.resumeEditorInput_()
    this.editing = false
    if (!this.editorOpening && this.editorLeaseHeld && this.editorDisposeTask === undefined) {
      this.editorDisposeTask = this.restoreDisposedEditor_()
    }
    // Phase 1（fix/input-system §P0-3）：组件销毁时也走完整释放路径。
    // buttonReleaseAllFingers → clearAllToggles 内部会 clearTimeout(longPressTimers)，
    // 之前漏调本路径会让 longPress 计时回调在销毁后 fire 访问悬空 this。
    // native 是持续输出的最终所有者；页面销毁时先关闭 ledger，再清 ArkTS 视觉/辅助状态。
    // 即使 surface 回调稍后才到，这里也保证 PAGE_DISPOSE 边界后没有悬空 PRESS。
    // 顺序纪律（见 InputSourceRegistry.ets）：先本端自释放，再 native 兜底。
    this.resetTransientInputState()
    // ⚠️ 这里**不再**调 `cancelAllInput(4)`。
    //
    // 官方文档明确：组件销毁顺序是**父先子后**（Parent aboutToDisappear → Child
    // aboutToDisappear）。所以本组件的 aboutToDisappear 一定跑在 McGamePage 的之后，
    // 而页面那一侧已经按顺序纪律做过完整的"三端自释放 → cancelAllInput(4)"。
    // 在这之后再 cancel 一次的实际后果不是"更安全"，而是**再推进一次 reset epoch**，
    // 让下一次对账多跑一遍三端缓存丢弃 —— 纯噪声。
    // 本组件自己的 ArkTS 状态由上面一行负责，native ledger 由页面那一侧负责。
    // 注销本端。必须在上面的释放之后，否则本端的按下态就没人负责了。
    getInputSourceRegistry().unregister(this.touchControlsEnd)
    // Phase C（键鼠适配）：取消 capability 监听
    getInputDeviceMonitor().removeCapabilityListener(this.capabilityListener)
    // 注销 native→UI 反馈回调。
    if (this.schemaActive) {
      const lease: EntryControlFeedbackLease | undefined = this.feedbackLease
      this.feedbackLease = undefined
      if (lease !== undefined) releaseEntryControlFeedback(lease)
    }
  }

  // 根据布局数据计算控件实际 vp 位置和大小
  private itemX(item: ControlItem): number {
    return item.xPct * this.compWidth
  }
  private itemY(item: ControlItem): number {
    return item.yPct * this.compHeight
  }
  private itemW(item: ControlItem): number {
    return item.baseWidth * item.itemScale * this.profile.globalScale
  }
  private itemH(item: ControlItem): number {
    return item.baseHeight * item.itemScale * this.profile.globalScale
  }

  /**
   * 把一个控件矩形夹成 native schema 恒合法：0 <= x、0 < w <= compWpx、x+w <= compWpx（y/h 同理）。
   *
   * 为什么必须在这里做：控件矩形是运行时算出来的（itemW = baseWidth × itemScale × globalScale，再 × density），
   * 而 validateAndNormalizeLayout 只校验存储的 baseWidth/xPct，**不校验这个像素乘积**。因此即使布局本身合法，
   * 极端缩放/密度仍可能算出 w<=0 或 x+w>compW 的矩形；而 native 的 schema 校验对**任一**越界控件会拒绝
   * 整张表 → 所有按键/摇杆/hotbar 一起失效（本轮 hotbar 事故就是这一类）。这里逐控件夹取即可根除该类故障。
   *
   * 先夹宽高（含 NaN / 非正兜底），再夹位置；正常控件（含 hotbar 的 180*gs 宽）本就在界内、原样返回，
   * 只有异常大/越界的控件才被收拢，且优先保证不改变宽度（hotbar 槽位对齐只依赖 x/w）。
   */
  private clampEntryRect(x: number, y: number, w: number, h: number, compWpx: number, compHpx: number): RectPx {
    let cw = w > 0 ? w : 1
    let ch = h > 0 ? h : 1
    if (cw > compWpx) cw = compWpx
    if (ch > compHpx) ch = compHpx
    let cx = x > 0 ? x : 0
    let cy = y > 0 ? y : 0
    if (cx + cw > compWpx) cx = compWpx - cw
    if (cy + ch > compHpx) cy = compHpx - ch
    if (cx < 0) cx = 0
    if (cy < 0) cy = 0
    return { x: cx, y: cy, w: cw, h: ch }
  }

  // 摇杆外圈 / 内圈圆角（px）：cornerRadius × 短边一半。1.0=正圆、0=正方形。
  private joystickOuterRadius(item: ControlItem): number {
    const w = this.itemW(item) * 0.93
    const h = this.itemH(item) * 0.93
    return effectiveCornerRadius(item) * Math.min(w, h) / 2
  }
  private joystickInnerRadius(item: ControlItem): number {
    const w = this.itemW(item) * 0.37
    const h = this.itemH(item) * 0.37
    return effectiveCornerRadius(item) * Math.min(w, h) / 2
  }

  /**
   * R1（input-system-full-review §P0-1/D1）：单一可见性判定。
   * 渲染层 build() 和 C 层 registerRegions() 共用，保证"看得见的才注册命中矩形"。
   *
   * 与 build() 的三层过滤完全一致：
   *   - hidden / globalVisMode / visibilityOverride==='force_hide' / isVisibleInScene
   *   - grabbedOnly：仅 grabbed 显示
   *   - JOYSTICK / SCROLL_WHEEL / HOTBAR_SELECTOR：仅 grabbed 渲染（其它类型不受此限）
   *
   * ⚠️ 这段注释曾写作「hidden / shouldHideForInputMode（含 forceShowAll + capability +
   * visibilityOverride）」。**那是假的**：`shouldHideForInputMode` 全仓不存在，只在注释里
   * 出现；`capability` 在本函数里一次都没被读到。真实情况是"接键鼠自动隐藏虚拟按键"这个
   * 功能在 2026-06 被**刻意解耦删除**（见本类 globalVisMode 字段处的注释），换成了纯手动的
   * 三档全局可见性。删的时候漏改了这段注释，于是它继续描述一个不存在的实现。
   *
   * 代价是真实的：2026-08-20 我依据这段注释写出了一条"插键盘后虚拟按键应自动隐藏"的
   * 复测判据，用户在真机上照着测，结论当然是"不生效"。**注释说谎比没有注释更贵**——
   * 它会被当成规格来用。这是本项目第六条纪律的来源。
   */
  private isControlVisible(item: ControlItem): boolean {
    if (item.hidden) return false
    // 多键健壮性（2026-05-30）：仍被手指按住的按钮强制保持可见，无论档位 / grabbed / 场景怎么变。
    if (this.isButtonHeld(item.id)) return true
    // "显示"系统按钮不受 globalVisMode 影响（否则全部隐藏后无法再切回）；仅受 hidden / 场景 / force_hide。
    // 它在 VIS_HIDE 档位下仍显示，文字变为"显示"，点击即恢复。
    if (item.systemAction === 'visibility') {
      if ((item.visibilityOverride ?? 'auto') === 'force_hide') return false
      return isVisibleInScene(item, this.isGrabbed)
    }
    // 全局可见性档位（2026-06，已与键盘解耦）
    if (this.globalVisMode === VIS_HIDE) return false
    // 编辑器里手动「永远隐藏」的按钮仍然尊重（与键盘无关）
    if ((item.visibilityOverride ?? 'auto') === 'force_hide') return false
    if (this.globalVisMode === VIS_MENU) {
      // 仅菜单按键：只留 menu / always 场景，隐藏游戏内（game 场景）+ 摇杆 / 滚轮
      if (!isVisibleInScene(item, false)) return false
      if (item.type === ControlType.JOYSTICK || item.type === ControlType.SCROLL_WHEEL
          || item.type === ControlType.HOTBAR_SELECTOR) return false
      return true
    }
    // VIS_ALL：按场景正常显示（game 仅 grabbed / menu 仅非 grabbed / always 都显示）。
    if (!isVisibleInScene(item, this.isGrabbed)) return false
    if ((item.type === ControlType.JOYSTICK || item.type === ControlType.SCROLL_WHEEL
        || item.type === ControlType.HOTBAR_SELECTOR) && !this.isGrabbed) {
      return false
    }
    return true
  }

  /** 某按钮当前是否被至少一根手指按住（buttonFingerIds 占用集合非空）。 */
  /**
   * 安全网（2026-06）：IME（聊天 / field 文本框）打开瞬间，释放所有按住的方向/摇杆/按钮。
   * 杜绝「点输入框时触摸误触下层虚拟按键 → 按钮收到 DOWN 但 IME 开起丢了 UP → 键卡死」。
   * 延后到下一帧执行，避免与触发它的那次触摸处理（如 ime_chat 按钮 DOWN）交叉。
   * 注意：不动 imeOpen / fieldImeOpen / drawer 等显隐标志，只清「会发 PRESS 却可能丢 RELEASE」的输入。
   */
  private onImeOpenChanged(): void {
    if (this.imeOpen || this.fieldImeOpen) {
      setTimeout(() => {
        this.releaseAllDirections()
        this.joystickFingerId = -1
        this.joystickX = 0
        this.joystickY = 0
        this.buttonReleaseAllFingers(false)
      }, 0)
    }
  }

  private isButtonHeld(id: string): boolean {
    const set = this.buttonFingerIds.get(id)
    return set !== undefined && set.size > 0
  }

  // 注册所有控件区域到 C 层（px 坐标），供 C 层过滤 native 触摸
  //
  // R1：只注册"当前真的渲染出来"的控件（isControlVisible）。之前全量注册导致
  // 隐藏 / 自动隐藏 / grabbedOnly 的按钮在 C 层仍占命中矩形，吞掉 native 视角。
  private registerRegions(): void {
    const W = this.compWidth
    const H = this.compHeight
    if (W === 0 || H === 0) return
    const context: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
    if (!context.provisional) {
      if (!context.has(INPUT_SURFACE_FIELD_DENSITY)) {
        this.density = 0
        this.publishUnresolvedSurfaceSchema()
        return
      }
      this.density = context.density
    } else if (this.density === 0) {
      try {
        this.density = display.getDefaultDisplaySync().densityPixels
      } catch (e) {
        this.density = 3.0
      }
    }
    const s = this.density

    // ⚠️ 墓碑: `testNapi.setCompSize(W * s, H * s)` 已删除（跨四层，终点 `s_compWidth/Height`
    // 零读者，与下面那张 legacy 矩形表是同一个形状），详见计划 §64.3。
    // 组件尺寸并没有因此丢失：下面的 Control Schema 逐次携带 `compWidth`/`compHeight`，
    // 而那两个字段是**活的** —— NAPI 与 native 各用它们做一次"控件矩形不得越界"的校验。
    //
    // ⚠️ 这里曾额外维护一份 legacy 矩形表：先 `clearButtons()` + `clearJoystick()`，
    // 再逐个 `registerButton()` / `registerJoystick()`，包括 VIS_HIDE 档那个左下角
    // 恢复热区。**已随 native 侧一起删除。**
    //
    // 原因：那张表在 C 层的唯一读取方（hitButton / isInJoystick）位于一个永不执行的
    // 分支里（`s_schemaActive` 是永为 true 的常量）。于是每一次布局重建 —— 插拔设备、
    // grab 翻转、可见性档位循环、编辑器保存、onAreaChange —— 都在跨语言填一张没人读的表。
    //
    // 触控虚拟按键端的唯一权威表述是下面这一行的 Control Schema：它带 hit-test、
    // hitSlop、handledBy、四种 trigger，native 侧由 handleSchemaGrabbedTouch 单一解释。
    this.sendControlSchema()
  }

  private publishUnresolvedSurfaceSchema(): void {
    if (!this.schemaActive) return
    try {
      const schema: ControlSchemaMsg = {
        schemaVersion: 2,
        compWidth: 1,
        compHeight: 1,
        grabbed: this.isGrabbed,
        deadZone: this.profile.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE,
        controls: []
      }
      testNapi.setControlSchema(schema)
    } catch (_) {
      hilog.warn(0x0000, GAME_CONTROLS_TAG, 'Failed to clear unresolved surface schema')
    }
  }

  // ============= Control Schema v2 运行时契约 =============
  // native 已接管 grabbed 下的摇杆、按钮、滚轮和 hotbar。handledBy=arkts 控件仍由 ArkUI exact rect
  // 直接处理；native schema 只把这些区域标为不可解释成 look，不再维持无生产者的激活回调假链路。
  private schemaActive: boolean =
    typeof testNapi.setControlSchema === 'function' &&
    typeof testNapi.onButtonPressed === 'function' &&
    typeof testNapi.onHaptic === 'function'
  private schemaTakeoverJoystick: boolean = true
  private schemaTakeoverButtons: boolean = true
  private schemaTakeoverScroll: boolean = true
  private schemaTakeoverHotbar: boolean = true

  /**
   * 架构约束：物理鼠标与屏幕虚拟按键是两条**并列**的输入源，鼠标不得激活虚拟控件。
   *
   * ArkUI 会把鼠标主键按下转换成 TouchEvent，并且转换过程中 SourceType 保持不变，
   * 所以每个虚拟控件入口都必须显式拒收鼠标来源；否则鼠标能按虚拟按键、拨摇杆、翻物品栏、
   * 开抽屉，与 native 侧的鼠标通道重复计账。native 侧已在 OnDispatchTouchEvent 按来源拦下
   * 同一批事件，这里是 ArkUI 直接投递的那一半，两边缺一不可。
   *
   * 真实手指是 SourceType.TouchScreen，手写笔亦不受影响，因此纯触摸设备行为不变。
   */
  private isMouseSourced(source: SourceType): boolean {
    return source === SourceType.Mouse
  }

  /**
   * 判定一个 TouchEvent 是否由指针设备（鼠标/触摸板）合成，而非真实手指。
   *
   * 只看 `source` 是不够的：SDK 只承诺"鼠标左键会被转换成触摸事件并触发 onTouch"，
   * **并未承诺转换后 SourceType 仍为 Mouse**，而官方示例判别输入源用的是 `sourceTool`
   * （SourceTool: Unknown=0 Finger=1 Pen=2 MOUSE=3 TOUCHPAD=4）。真机上滚轮镜像事件
   * 的来源元数据确实不可靠，所以这里取两个维度的并集，命中任一即拒收。
   *
   * 方向刻意是"否定式"而不是"只放行 Finger"：元数据缺失时按触摸处理，
   * 这样某个固件答不出来源时也不会让触摸屏整体失效。
   */
  private isPointerDeviceSourced(source: SourceType, tool: SourceTool): boolean {
    if (this.isMouseSourced(source)) return true
    // ⚠️ 枚举错位（真机证据）：本机 ArkUI 的 `sourceTool` 填的是 **native
    // OH_NativeXComponent_TouchPointToolType** 那套编号，而不是文档里的 `SourceTool`：
    //   native：UNKNOWN=0 FINGER=1 PEN=2 RUBBER=3 BRUSH=4 PENCIL=5 AIRBRUSH=6 MOUSE=7 LENS=8
    //   ArkUI ：Unknown=0 Finger=1 Pen=2  MOUSE=3  TOUCHPAD=4 JOYSTICK=5
    //   MMI   ：UNKNOWN=0 MOUSE=1  JOYSTICK=2 TOUCHPAD=3
    // gate0 遥测里 757/758 条真实鼠标样本的 sourceTool 都是 **7** = native MOUSE。
    // 因此 `tool === SourceTool.MOUSE`(=3) 实际比的是 native 的 RUBBER，
    // `SourceTool.TOUCHPAD`(=4) 比的是 BRUSH —— 鼠标永远匹配不上。
    // 两套编号同时接受：3/4 在 native 编号里是橡皮/画刷，本设备不会产生，
    // 因此并集不会引入假阳性，同时对"某版本改用文档编号"也是向前兼容的。
    if (tool === SourceTool.MOUSE || tool === SourceTool.TOUCHPAD) return true
    if (tool === NATIVE_TOOL_TYPE_MOUSE || tool === NATIVE_TOOL_TYPE_LENS) {
      return true
    }
    // grabbed（游戏内）时额外把 `Unknown` 也算成鼠标派生。
    //
    // 依据是真机：系统把鼠标左键转换出来的触摸包，toolType 恒为 UNKNOWN(0)，
    // 而真手指恒为 FINGER(1)（native 侧 618 个样本无例外）。C 层的镜像判据
    // （`mirrorPacket` = 光标锁生效 && tool==UNKNOWN）正是同一条规则。
    //
    // 为什么限定 grabbed：这条规则的安全性依赖"光标锁已建立"，而锁只在游戏内且检测到
    // 物理鼠标后才建立；纯触摸设备与菜单态都不受影响，不存在"某固件把真手指报成
    // UNKNOWN 导致整块触摸屏失效"的风险。
    //
    // 不加这一条的后果（审计发现的真实回归）：游戏内鼠标能按下虚拟按键、拨摇杆、
    // 开合抽屉——因为 ArkTS 侧的元数据判据不含 UNKNOWN，而位置回声在 grabbed 下已停用。
    if (this.isGrabbed && tool === SourceTool.Unknown) return true
    return false
  }

  /**
   * 元数据 + 位置回声的并集判定。
   *
   * 为什么必须加位置这一维：本机真机上鼠标镜像出的 TouchEvent 在元数据上与手指
   * **不可区分**（native 侧 618/618 个包都报 TOUCHSCREEN）。菜单态又按设计不锁光标，
   * 所以"鼠标点到虚拟按键"只能靠"这一触点正好落在物理光标处"来拒收。
   * 判据与容差见 PhysicalPointerEcho.isLikelyPhysicalPointerAt。
   *
   * 取 changedTouches[0] 的窗口坐标：它就是本次边沿真正发生的位置，
   * 与 onMouse 上报的 windowX/windowY 同一坐标系。
   */
  private isPointerSourcedTouch(event: TouchEvent): boolean {
    if (this.isPointerDeviceSourced(event.source, event.sourceTool)) return true
    // 位置回声**只在菜单态（未 grabbed）使用**。
    //
    // grabbed 下用它是有害的：光标锁生效时指针位置在游戏内不再由用户自由控制，
    // 而 onMouse 会持续把那个位置刷成"新鲜"，于是任何落在该点 ±4vp 内的**真手指**
    // 都会被判成鼠标而被六个入口一致拒收 —— 表现为屏幕上某一小块区域的虚拟控件
    // 间歇性失灵，且极难复现定位。
    // 而 grabbed 下本来就不需要这一维：鼠标派生的触摸包已由 C 层 mirrorPacket 分流，
    // 根本不会到达 ArkTS 虚拟控件。菜单态才是它唯一有价值的场景（那里按设计不锁光标）。
    if (this.isGrabbed) return false
    const changed = event.changedTouches
    if (!changed || changed.length === 0) return false
    const t = changed[0]
    return getPhysicalPointerEcho().isLikelyPhysicalPointerAt(t.windowX, t.windowY)
  }

  /** C 层是否已接管摇杆（grabbed 下）：是则 ArkTS 只更新视觉、不发 WASD，交给 C。 */
  private cOwnsJoystick(): boolean {
    return this.schemaActive && this.schemaTakeoverJoystick && this.isGrabbed
  }

  /**
   * C 层是否已接管该按钮的按键发送（grabbed 下）：是则 ArkTS 只保留视觉高亮 + 触觉、不发键、不做 dragLook。
   * 仅接管**顶层 native 普通按钮**——排除 ime_chat（handledBy=arkts）、抽屉子按钮（不在 C schema 里）。
   */
  private cOwnsButton(item: ControlItem): boolean {
    if (!this.schemaActive || !this.schemaTakeoverButtons || !this.isGrabbed) return false
    // 系统功能按钮（输入/设置/显示）由 ArkTS 处理（handledBy=arkts），C 不接管发键。
    if (item.systemAction !== undefined) return false
    const top = this.profile.controls.find((c: ControlItem) => c.id === item.id)
    if (top === undefined || top.type !== ControlType.BUTTON) return false
    // 收尾：所有触发模式（press/toggle/doubleTap/longPress）均由 C 接管——键 C 发、视觉经
    // onButtonPressed 推回 ArkTS 更新高亮，单一真相源、不再失步。ime_chat/抽屉子按钮除外（上面已排除）。
    return true
  }

  /** C 层是否已接管滚轮 / 物品栏（grabbed 下，无状态，ArkTS onTouch 直接 no-op 交给 C）。 */
  private cOwnsScroll(): boolean {
    return this.schemaActive && this.schemaTakeoverScroll && this.isGrabbed
  }
  private cOwnsHotbar(): boolean {
    return this.schemaActive && this.schemaTakeoverHotbar && this.isGrabbed
  }

  private triggerCode(t?: TriggerMode): number {
    if (t === 'toggle') return 1
    if (t === 'doubleTap') return 2
    if (t === 'longPress') return 3
    return 0
  }

  private sendControlSchema(): void {
    if (!this.schemaActive) return
    try {
      const W = this.compWidth
      const H = this.compHeight
      if (W === 0 || H === 0) return
      if (this.density <= 0) {
        this.publishUnresolvedSurfaceSchema()
        return
      }
      const s = this.density
      const controls: ControlSchemaEntry[] = []
      for (let ci = 0; ci < this.profile.controls.length; ci++) {
        const c = this.profile.controls[ci]
        if (!this.isControlVisible(c)) continue
        const handledBy = (c.systemAction !== undefined || c.type === ControlType.DRAWER) ? 1 : 0
        // 防御：native schema 校验一旦发现任一控件 e.x+e.w / e.y+e.h 越界，会**拒绝整张表** →
        // 所有控件（含所有按键、摇杆、hotbar）全部失效。控件因取整/对齐偶尔差几像素越界不应造成
        // 这种灾难，故这里把矩形夹回 comp 边界内（只平移、不改宽高，保持命中几何与槽位对齐）。
        const rect = this.clampEntryRect(this.itemX(c) * s, this.itemY(c) * s,
                                         this.itemW(c) * s, this.itemH(c) * s, W * s, H * s)
        const e: ControlSchemaEntry = {
          id: c.id,
          kind: c.type as number,
          handledBy: handledBy,
          x: rect.x,
          y: rect.y,
          w: rect.w,
          h: rect.h,
          // hitSlop 明确以物理 px 入协议：8/12vp 乘 density 后，各密度设备获得一致的可触范围。
          // handledBy=arkts 强制为 0，native 不能扩张 ArkUI 的视觉热区形成 look 死区。
          hitSlop: handledBy === 1 ? 0 : (c.type === ControlType.JOYSTICK ? 12 * s : 8 * s),
          keyOrMouse: c.keyOrMouse,
          keys: effectiveKeys(c),
          trigger: this.triggerCode(c.trigger),
          dragLook: c.dragLook === true,
          haptic: this.profile.haptic ?? true
        }
        controls.push(e)
      }
      // 方案 A 收尾：展开抽屉的子按钮不在顶层 controls 里，若不下发 C 会把子按钮区域当空白 → 拖动误转视角。
      // 把可见的展开子按钮以 handledBy=arkts（C 命中即忽略、不 look，仍由 ArkTS 处理）下发，堵住 look 穿透。
      for (let ci = 0; ci < this.profile.controls.length; ci++) {
        const d = this.profile.controls[ci]
        if (d.type !== ControlType.DRAWER) continue
        if (!(this.drawerOpen.get(d.id) ?? false) || !d.children) continue
        if (!this.isControlVisible(d)) continue
        for (let k = 0; k < d.children.length; k++) {
          const ch2 = d.children[k]
          if (ch2.hidden) continue
          const childRect = this.clampEntryRect(this.drawerChildX(d, ch2, k) * s, this.drawerChildY(d, ch2, k) * s,
                                                 this.itemW(ch2) * s, this.itemH(ch2) * s, W * s, H * s)
          controls.push({
            // 子按钮 id 在布局层保证全局唯一且不超过 23 UTF-8 字节，禁止在协议边界拼接/截断后碰撞。
            id: ch2.id,
            kind: ControlType.BUTTON as number,
            handledBy: 1,
            x: childRect.x,
            y: childRect.y,
            w: childRect.w,
            h: childRect.h,
            hitSlop: 0,
            keyOrMouse: ch2.keyOrMouse,
            keys: effectiveKeys(ch2),
            trigger: 0,
            dragLook: false,
            haptic: this.profile.haptic ?? true
          })
        }
      }
      const msg: ControlSchemaMsg = {
        schemaVersion: 2,
        compWidth: W * s,
        compHeight: H * s,
        grabbed: this.isGrabbed,
        deadZone: this.profile.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE,
        controls: controls
      }
      const generation: number = testNapi.setControlSchema(msg)
      if (generation <= 0) {
        // 视觉已切到新布局而 native 拒绝 schema 时，保留旧表会触发不可见控件。必须立即发布一张
        // 合法空表关闭 native 热区；这比“继续用旧表”更安全，也让拒绝在日志中可观测。
        hilog.error(0x0000, GAME_CONTROLS_TAG,
          'Control schema rejected; publishing empty fail-closed table (controls=%{public}d)', controls.length)
        const cleared: number = testNapi.setControlSchema({
          schemaVersion: 2, compWidth: W * s, compHeight: H * s,
          grabbed: this.isGrabbed,
          deadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
          controls: []
        })
        if (cleared <= 0) {
          hilog.error(0x0000, GAME_CONTROLS_TAG, 'Control schema fail-closed publish also rejected')
        }
      }
    } catch (e) {
      // NAPI 异常同样不能静默保留旧热区。尽力清表；若 native 模块本身不可用，旧兼容层仍会按
      // registerRegions 工作，但 schema 接管路径不会得到一张看似成功的半表。
      hilog.error(0x0000, GAME_CONTROLS_TAG, 'sendControlSchema failed: %{public}s', (e as Error).message)
      try {
        const s = this.density > 0 ? this.density : 3.0
        if (this.compWidth > 0 && this.compHeight > 0) {
          testNapi.setControlSchema({
            schemaVersion: 2,
            compWidth: this.compWidth * s,
            compHeight: this.compHeight * s,
            grabbed: this.isGrabbed,
            deadZone: DEFAULT_JOYSTICK_DEAD_ZONE,
            controls: []
          })
        }
      } catch (_) { /* native 不可用时只能停在兼容路径 */ }
    }
  }

  /** 循环全局可见性档位（全部显示 → 仅菜单 → 全部隐藏 → …）。由"显示"系统按钮触发。 */
  private cycleVisMode(): void {
    this.globalVisMode = (this.globalVisMode + 1) % 3
    // 可见集合变了，重注册 C 层命中矩形（隐藏的按钮不再吞 native 视角）
    this.registerRegions()
  }

  /**
   * 系统功能按钮（输入/设置/显示）统一动作分发。这些按钮外观同普通按钮，但点击执行应用级功能。
   * - input：游戏内(grabbed)=发聊天键(T)打开 MC 聊天 + 聊天 IME（回车提交/ESC 取消）；
   *          菜单(!grabbed)=field IME（实时同步到已聚焦文本框，不发 ENTER/ESC）。一个按钮统筹所有输入。
   * - edit：进入布局编辑器。
   * - visibility：循环可见性档位。
   */
  private handleSystemAction(item: ControlItem): void {
    const action = item.systemAction
    if (action === 'input') {
      // ⚠️ 开一个之前**必须**关另一个。两个输入条同时开从来不是合法状态：
      // 它们各挂一个 `ChatInputBridge`，而 `inputMethod.getController()` 返回的是
      // **进程级**客户端实例 —— 后 attach 的那条会用 `off()` + `on()` 静默夺走前一条的
      // 全部 IME 回调，而前一条的 `attached` 仍是 true，于是它的"重新唤起软键盘"会对一个
      // 已 detach 的 controller 调 `showSoftKeyboard()`。
      //
      // 此前之所以能同时开：`imeOpen` 只在 grabbed 开、`fieldImeOpen` 只在 !grabbed 开
      // （看着互斥），但 **grab 翻转刻意不关闭它们**（`resetTransientInputState(true)`
      // 里那两行被 `!keepHeldButtons` 挡住）。于是"菜单开 field → 进游戏 → 开 chat"
      // 就同时开着两条。故障表现是物理键盘字符双发，完整序列见
      // `gamecontrol/src/main/ets/ImeActivationGate.ets` 的头注释。
      if (this.isGrabbed) {
        if (!this.dispatchButton(item, GLFW_PRESS)) return
        Promise.resolve().then(() => { this.dispatchButton(item, GLFW_RELEASE) })
        this.fieldImeOpen = false
        this.imeOpen = true
      } else {
        this.imeOpen = false
        this.fieldImeOpen = true
      }
    } else if (action === 'edit') {
      this.openEditor()
    } else if (action === 'visibility') {
      this.cycleVisMode()
    }
  }

  /**
   * 进入布局编辑器：租约先于异步克隆，事务基线先于预设副本；持久化失败绝不打开
   * 一份假成功的草稿。组件销毁或 appearance 改变后，旧续体只回滚，不再操作 UI。
   */
  private async openEditor(): Promise<void> {
    if (!this.mounted || this.editorOpening || this.editing || this.editorLeaseHeld) return
    this.editorDisposeTask = undefined
    this.editorOpening = true
    const appearance: number = this.appearanceGeneration
    const store = getLayoutStore()
    let opened: boolean = false
    try {
      if (!store.beginEditorSession()) throw new Error('布局正在同步，请稍后再试')
      this.editorLeaseHeld = true
      store.beginEditorTransaction()
      // 先记录本组件拥有暂停，再调用 native；即使边界抛错也会尝试撤销暂停。
      this.editorInputPaused = true
      testNapi.setTouchPaused(true)
      this.releaseAllDirections()
      this.joystickFingerId = -1
      this.buttonReleaseAllFingers()
      if (this.profile.isPreset) {
        const cloned: LayoutProfile | null = await store.cloneAsUser(this.profile.name)
        if (cloned === null) throw new Error('无法创建可编辑的布局副本')
      }
      if (!this.mounted || appearance !== this.appearanceGeneration) return
      this.profile = cloneLayout(store.getActiveProfile())
      this.profileVer++
      this.onLayoutChanged()
      this.editing = true
      opened = true
    } catch (error) {
      this.showEditorError_('无法打开布局编辑器：' + (error as Error).message)
    } finally {
      if (!opened) {
        // 恢复触控不等待回滚写盘；回滚失败仍由 Store 保留原事务，后续可以重试。
        this.resumeEditorInput_()
        if (this.editorLeaseHeld) {
          try {
            if (!(await store.restoreEditorTransaction())) {
              this.showEditorError_('编辑未打开，恢复原布局失败；请重试，尚未确认保存')
            }
            if (this.mounted && appearance === this.appearanceGeneration) {
              this.profile = cloneLayout(store.getActiveProfile())
              this.profileVer++
              this.onLayoutChanged()
            }
          } catch (error) {
            this.showEditorError_('恢复原布局失败：' + (error as Error).message)
          } finally {
            this.releaseEditorLease_()
          }
        }
      }
      this.editorOpening = false
    }
  }

  /** 只释放本组件的租约；重复 onDone/销毁不会抵消子编辑器或其他调用者的计数。 */
  private releaseEditorLease_(): void {
    if (!this.editorLeaseHeld) return
    this.editorLeaseHeld = false
    getLayoutStore().endEditorSession()
  }

  /** child 尚未来得及 mount 也必须有人恢复打开事务；Store 会合并父子并发取消。 */
  private async restoreDisposedEditor_(): Promise<void> {
    try {
      if (!(await getLayoutStore().restoreEditorTransaction())) {
        this.showEditorError_('编辑器已关闭，但恢复原布局失败；请重新进入后重试取消')
      }
    } catch (error) {
      this.showEditorError_('关闭编辑器时恢复布局失败：' + (error as Error).message)
    } finally {
      this.releaseEditorLease_()
    }
  }

  /** 无论打开、刷新还是关闭失败，都收回本组件设置的触控暂停，不把异常静默吞掉。 */
  private resumeEditorInput_(): void {
    if (!this.editorInputPaused) return
    this.editorInputPaused = false
    try { testNapi.setTouchPaused(false) }
    catch (error) { this.showEditorError_('恢复游戏触控失败：' + (error as Error).message) }
  }

  /** 编辑失败必须用户可见；组件已经销毁时只记录，不访问失效的 UIContext。 */
  private showEditorError_(message: string): void {
    hilog.error(0x0000, GAME_CONTROLS_TAG, '%{public}s', message)
    if (!this.mounted) return
    try { this.getUIContext().getPromptAction().showToast({ message: message }) }
    catch (error) { hilog.error(0x0000, GAME_CONTROLS_TAG, 'Cannot show layout error: %{public}s', (error as Error).message) }
  }

  /**
   * Store 已确认保存/取消后才退出覆盖层。取消也从已恢复的活跃方案重建 schema，
   * 不能继续显示打开时的预设副本；布局刷新异常同样必须恢复暂停和释放租约。
   */
  private finishEditor_(result: LayoutProfile | null): void {
    if (!this.editing) return
    try {
      if (this.mounted) {
        this.profile = cloneLayout(result ?? getLayoutStore().getActiveProfile())
        this.profileVer++
        this.onLayoutChanged()
      }
    } catch (error) {
      this.showEditorError_('布局结果已确认，但刷新按键失败：' + (error as Error).message)
    } finally {
      this.editing = false
      this.releaseEditorLease_()
      this.resumeEditorInput_()
    }
  }

  /** 子编辑器进入阶段失败不是保存成功；关闭覆盖层并让用户看到原始失败原因。 */
  private editorInitializationFailed_(message: string): void {
    this.showEditorError_(message)
    this.finishEditor_(null)
  }

  /** 系统按钮的显示文字：visibility 随档位变化（全部/仅菜单/显示）；其余用控件自身标签。 */
  private systemButtonLabel(item: ControlItem): string {
    if (item.systemAction === 'visibility') {
      if (this.globalVisMode === VIS_MENU) return '仅菜单'
      if (this.globalVisMode === VIS_HIDE) return '显示'
      return '全部'
    }
    return effectiveLabel(item)
  }

  // 布局 / 可见性变化时重新注册 C 层命中矩形。
  // 否则 C 层矩形表与渲染层不同步，native look 过滤区域错位。
  private onLayoutChanged(): void {
    this.registerRegions()
  }

  /**
   * 阶段 1.4：8 向摇杆 + 死区 + 30ms 锁存
   *
   * 用 atan2 把 (dx, dy) 映射到 8 向扇区（每扇区 45°，正方向居中）。
   * 死区由 LayoutProfile.joystickDeadZone 决定（默认 0.18），半径在死区内时
   * 释放所有方向键。
   *
   * 锁存：刚 release 的键在 30ms 内不允许 press；防止用户手指刚好在边界
   * 抖动时 W/S 反复触发。
   *
   * 参数 dx, dy：归一化到 [-1, 1] 的摇杆位移（圆裁剪后）。
   */
  private updateJoystickKeys(dx: number, dy: number): void {
    const deadZone: number = this.profile.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE
    // 8 向扇区判定已抽到 gamecontrol 的 JoystickSector.ets（纯函数，有单测，
    // 与 native 侧 cpp/platform/joystick_sector.cpp 是同一份规格的两个实现）。
    //
    // 抽出的理由不是这段代码难懂，而是同一张扇区表在本项目里写了三遍（native 触控 /
    // 手柄端 / 这里），谁改一份另两份不会有任何编译或测试提示，表现为"同一个八向摇杆
    // 在三端手感不同" —— 而那不会是设计决定，只会是一次漏改。规格表见那个文件的头部注释。
    //
    // 死区内返回全 false，逐键 applyDirection(false) 与旧的 releaseAllDirections()
    // 等价（后者也只对 activeKeys 里存在的方向发 RELEASE）。30ms 方向锁存仍在
    // applyDirection 里 —— 它有状态，且三端策略本来就不同，不与扇区判定一起抽。
    const sector = joystickSector(dx, dy, deadZone)
    this.applyDirection(GLFW_KEY_W, sector.w)
    this.applyDirection(GLFW_KEY_A, sector.a)
    this.applyDirection(GLFW_KEY_S, sector.s)
    this.applyDirection(GLFW_KEY_D, sector.d)
  }

  /**
   * 单个方向键的 PRESS / RELEASE 状态机 + 30ms 锁存。
   */
  private applyDirection(key: number, want: boolean): void {
    const has = this.activeKeys.has(key)
    if (want && !has) {
      const lastReleaseAt = this.keyLastReleaseAt.get(key) ?? 0
      const now = Date.now()
      if (now - lastReleaseAt < JOYSTICK_REPRESS_LOCKOUT_MS) {
        return  // 锁存窗口内禁止 press
      }
      // Keep the local held cache aligned with the native owner.  A closed
      // surface gate or a stale native bridge must not turn a rejected PRESS
      // into a synthetic held key that suppresses every later retry.
      if (sendKey(key, GLFW_PRESS)) this.activeKeys.add(key)
    } else if (!want && has) {
      // A rejected RELEASE remains retryable on the next lifecycle boundary;
      // removing it here would strand the native owner with no ArkTS record.
      if (sendKey(key, GLFW_RELEASE)) {
        this.activeKeys.delete(key)
        this.keyLastReleaseAt.set(key, Date.now())
      }
    }
  }

  private releaseAllDirections(): void {
    const dirs = [GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D]
    for (let di = 0; di < dirs.length; di++) {
      if (this.activeKeys.has(dirs[di])) {
        if (sendKey(dirs[di], GLFW_RELEASE)) {
          this.activeKeys.delete(dirs[di])
          this.keyLastReleaseAt.set(dirs[di], Date.now())
        }
      }
    }
  }

  // 改对应按钮的 @Observed 对象；并自增 @State 版本号，驱动子组件通过 @Prop 读取最新值。
  private setPressed(id: string, pressed: boolean): void {
    this.getBtnVis(id).pressed = pressed
    this.btnPressedVer++
  }

  private isPressed(id: string): boolean {
    const v = this.btnVisMap.get(id)
    return v !== undefined && v.pressed
  }

  // 阶段 2.4：trigger 状态机相关
  //
  // - toggle：每次 buttonAddFinger 都切换状态（奇数次 PRESS，偶数次 RELEASE）。
  //   按下抬起的"集合空 ↔ 满"模型对 toggle 不适用。
  // - doubleTap：300ms 内连点两次才发 PRESS+RELEASE。
  // - longPress：按住 200ms 才发 PRESS；release 时如果已 press 才 RELEASE。
  //
  // 这些状态在 onGrabChanged / setTouchPaused / 编辑改键等场景必须清零，
  // 已在 onGrabChanged + clearAllToggles 里处理。
  private toggleStates: Set<string> = new Set()                // 当前 toggle 处于按下态的按钮 id
  private accessibilityToggleStates: Set<string> = new Set<string>()
  private lastTapAt: Map<string, number> = new Map()           // doubleTap 用：上次点击时间戳
  private longPressTimers: Map<string, number> = new Map()     // longPress 用：定时器 id
  private longPressFired: Set<string> = new Set()              // longPress 已触发过 PRESS 的按钮

  private clearAllToggles(): void {
    this.toggleStates.forEach((id: string) => {
      const item = this.profile.controls.find((c: ControlItem) => c.id === id)
      if (item !== undefined) this.dispatchButton(item, GLFW_RELEASE)
    })
    this.toggleStates.clear()
    this.accessibilityToggleStates.forEach((id: string) => {
      const item: ControlItem | undefined =
        this.profile.controls.find((control: ControlItem) => control.id === id)
      if (item !== undefined) this.emitAccessibilityButton(item, GLFW_RELEASE)
    })
    this.accessibilityToggleStates.clear()
    this.lastTapAt.clear()
    this.longPressTimers.forEach((tid: number) => clearTimeout(tid))
    this.longPressTimers.clear()
    this.longPressFired.forEach((id: string) => {
      const item = this.profile.controls.find((c: ControlItem) => c.id === id)
      if (item !== undefined) this.dispatchButton(item, GLFW_RELEASE)
    })
    this.longPressFired.clear()
  }

  // 按钮按下/抬起事件（阶段 1.1 多指 + 阶段 2.4 trigger + 阶段 2.5 组合键）
  //
  // - 用 effectiveKeys(item) 取该按钮的"实际触发键序列"；keys[] 非空时 → keys，
  //   否则回退 [keyOrMouse]（向下兼容 v1 数据）。
  // - PRESS 顺序：keys[0..n-1]；RELEASE 倒序：keys[n-1..0]。
  // - addFinger：fingerId 加入按钮的占用集合，集合空→满时发整串 PRESS（trigger='press'）。
  //   trigger=toggle/doubleTap/longPress 走专门状态机，不走 PRESS/RELEASE 配对。
  // - 这样保证双指交替按住同一按钮时（A 先按，B 也按了，A 抬起）不漏 RELEASE。
  private dispatchButton(item: ControlItem, action: number): boolean {
    if (action === GLFW_PRESS) {
      if (this.cOwnsButton(item)) return true
      if (this.arktsButtonOutputs.has(item.id)) return true
      const keys: number[] = effectiveKeys(item)
      if (!this.emitCheckedKeySequence(keys, GLFW_PRESS)) return false
      const record = new ArktsButtonOutputRecord()
      record.keys = keys.slice()
      this.arktsButtonOutputs.set(item.id, record)
      if (this.profile.haptic ?? true) hapticTap(8)
      return true
    }

    const record: ArktsButtonOutputRecord | undefined =
      this.arktsButtonOutputs.get(item.id)
    if (record === undefined) return true
    if (!this.emitCheckedKeySequence(record.keys, GLFW_RELEASE)) return false
    this.arktsButtonOutputs.delete(item.id)
    return true
  }

  private emitCheckedKeySequence(keys: number[], action: number): boolean {
    const sequence: number[] = action === GLFW_PRESS ? keys : keys.slice().reverse()
    const emitted: number[] = []
    for (let i: number = 0; i < sequence.length; i++) {
      const key: number = sequence[i]
      const accepted: boolean = isMouseCode(key)
        ? sendMouse(decodeMouse(key), action)
        : sendKey(key, action)
      if (!accepted) {
        if (action === GLFW_PRESS) {
          let rollbackFailed: boolean = false
          for (let j: number = emitted.length - 1; j >= 0; j--) {
            const rollbackKey: number = emitted[j]
            const rolledBack: boolean = isMouseCode(rollbackKey)
              ? sendMouse(decodeMouse(rollbackKey), GLFW_RELEASE)
              : sendKey(rollbackKey, GLFW_RELEASE)
            if (!rolledBack) rollbackFailed = true
          }
          if (rollbackFailed) this.forceReleaseTouchSource('button-chord-rollback')
        } else {
          this.forceReleaseTouchSource('button-partial-release')
        }
        return false
      }
      emitted.push(key)
    }
    return true
  }

  private releaseAllArktsButtonOutputs(): void {
    const ids: string[] = []
    this.arktsButtonOutputs.forEach(
      (_record: ArktsButtonOutputRecord, id: string) => { ids.push(id) })
    for (let i: number = 0; i < ids.length; i++) {
      const id: string = ids[i]
      const record: ArktsButtonOutputRecord | undefined = this.arktsButtonOutputs.get(id)
      if (record === undefined) continue
      if (this.emitCheckedKeySequence(record.keys, GLFW_RELEASE)) {
        this.arktsButtonOutputs.delete(id)
      }
    }
  }

  private activateButtonFromAccessibility(item: ControlItem): void {
    if (item.systemAction !== undefined) {
      this.handleSystemAction(item)
      return
    }
    const trigger: TriggerMode = item.trigger ?? 'press'
    if (trigger === 'toggle') {
      if (this.accessibilityToggleStates.has(item.id)) {
        if (this.emitAccessibilityButton(item, GLFW_RELEASE)) {
          this.accessibilityToggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else if (this.toggleStates.has(item.id)) {
        if (this.dispatchButton(item, GLFW_RELEASE)) {
          this.toggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else {
        if (this.emitAccessibilityButton(item, GLFW_PRESS)) {
          this.accessibilityToggleStates.add(item.id)
          this.setPressed(item.id, true)
        }
      }
      return
    }
    if (!this.emitAccessibilityButton(item, GLFW_PRESS)) return
    this.setPressed(item.id, true)
    this.emitAccessibilityButton(item, GLFW_RELEASE)
    this.setPressed(item.id, false)
  }

  private emitAccessibilityButton(item: ControlItem, action: number): boolean {
    const keys: number[] = effectiveKeys(item)
    const sequence: number[] = action === GLFW_PRESS ? keys : keys.slice().reverse()
    const emitted: number[] = []
    for (let i: number = 0; i < sequence.length; i++) {
      const key: number = sequence[i]
      const accepted: boolean = isMouseCode(key)
        ? sendMouse(decodeMouse(key), action)
        : sendKey(key, action)
      if (!accepted) {
        if (action === GLFW_PRESS) {
          let rollbackFailed: boolean = false
          for (let j: number = emitted.length - 1; j >= 0; j--) {
            const rollbackKey: number = emitted[j]
            if (isMouseCode(rollbackKey)) {
              if (!sendMouse(decodeMouse(rollbackKey), GLFW_RELEASE)) rollbackFailed = true
            } else {
              if (!sendKey(rollbackKey, GLFW_RELEASE)) rollbackFailed = true
            }
          }
          if (rollbackFailed) this.forceReleaseTouchSource('chord-rollback')
        } else {
          this.forceReleaseTouchSource('accessibility-partial-release')
        }
        return false
      }
      emitted.push(key)
    }
    if (action === GLFW_PRESS && (this.profile.haptic ?? true)) hapticTap(8)
    return true
  }

  private forceReleaseTouchSource(reason: string): void {
    try {
      testNapi.releaseSourceHeld(TOUCH_SOURCE)
      try { testNapi.noteSourceReset(TOUCH_SOURCE) } catch (_) {
        hilog.warn(0x0000, GAME_CONTROLS_TAG,
          'Accessibility source reset accounting failed reason=%{public}s', reason)
      }
      this.dropHeldCacheAfterNativeReset()
    } catch (_) {
      hilog.warn(0x0000, GAME_CONTROLS_TAG,
        'Accessibility source force-release failed reason=%{public}s', reason)
    }
  }

  private buttonAddFinger(item: ControlItem, fingerId: number): void {
    const trig: TriggerMode = item.trigger ?? 'press'
    let set = this.buttonFingerIds.get(item.id)
    if (!set) {
      set = new Set<number>()
      this.buttonFingerIds.set(item.id, set)
    }
    const wasEmpty = set.size === 0
    set.add(fingerId)
    if (!wasEmpty) return  // 同按钮已有手指占用，trigger 状态机只看"首根手指 DOWN"

    // 系统功能按钮（输入/设置/显示）：不走普通发键/trigger 状态机，按 systemAction 执行应用级动作，
    // 只做一次"按下抬起"视觉反馈。
    if (item.systemAction !== undefined) {
      this.handleSystemAction(item)
      this.setPressed(item.id, true)
      setTimeout(() => { this.setPressed(item.id, false) }, 100)
      return
    }

    if (trig === 'press') {
      if (this.dispatchButton(item, GLFW_PRESS)) {
        this.setPressed(item.id, true)
      } else {
        set.delete(fingerId)
      }
    } else if (trig === 'toggle') {
      // 切换 toggle 状态：第 1 / 3 / 5 ... 次 → PRESS；第 2 / 4 / 6 ... 次 → RELEASE
      if (this.accessibilityToggleStates.has(item.id)) {
        if (this.emitAccessibilityButton(item, GLFW_RELEASE)) {
          this.accessibilityToggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else if (this.toggleStates.has(item.id)) {
        if (this.dispatchButton(item, GLFW_RELEASE)) {
          this.toggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else {
        if (this.dispatchButton(item, GLFW_PRESS)) {
          this.toggleStates.add(item.id)
          this.setPressed(item.id, true)
        }
      }
    } else if (trig === 'doubleTap') {
      const now = Date.now()
      const last = this.lastTapAt.get(item.id) ?? 0
      if (now - last < 300) {
        // 命中：发一次 PRESS+RELEASE
        if (this.dispatchButton(item, GLFW_PRESS)) {
          // 立即在下一帧 RELEASE，避免持续按住
          Promise.resolve().then(() => {
            if (this.dispatchButton(item, GLFW_RELEASE)) this.setPressed(item.id, false)
          })
          this.lastTapAt.delete(item.id)
          this.setPressed(item.id, true)
        }
      } else {
        this.lastTapAt.set(item.id, now)
      }
    } else if (trig === 'longPress') {
      // 200ms 后才发 PRESS；如果手指在 200ms 内抬起则取消
      const tid: number = setTimeout(() => {
        this.longPressTimers.delete(item.id)
        if (this.dispatchButton(item, GLFW_PRESS)) {
          this.longPressFired.add(item.id)
          this.setPressed(item.id, true)
        }
      }, 200) as number
      this.longPressTimers.set(item.id, tid)
    }
  }

  private buttonRemoveFinger(item: ControlItem, fingerId: number): void {
    const trig: TriggerMode = item.trigger ?? 'press'
    const set = this.buttonFingerIds.get(item.id)
    if (!set) return
    if (!set.has(fingerId)) return
    set.delete(fingerId)
    if (set.size > 0) return  // 还有其他手指压着，按钮态不变

    // 系统功能按钮的动作在 add 路径一次性完成，抬手不发事件。
    if (item.systemAction !== undefined) return

    if (trig === 'press') {
      if (this.dispatchButton(item, GLFW_RELEASE)) this.setPressed(item.id, false)
    } else if (trig === 'longPress') {
      // 在 longPress 计时未到 200ms 就抬手 → 取消
      const tid = this.longPressTimers.get(item.id)
      if (tid !== undefined) {
        clearTimeout(tid)
        this.longPressTimers.delete(item.id)
      }
      // 已 press 的话发 RELEASE
      if (this.longPressFired.has(item.id)) {
        if (this.dispatchButton(item, GLFW_RELEASE)) {
          this.setPressed(item.id, false)
          this.longPressFired.delete(item.id)
        }
      }
    }
    // toggle / doubleTap：抬起不做事（PRESS/RELEASE 配对在 buttonAddFinger 完成）
  }

  // 释放某 fingerId 在所有按钮上的占用（用于布局重建 / 编辑模式进入等场景）
  //
  // Phase（fix/input-system §N2）：之前的实现对所有占用按钮都发 RELEASE，紧接着
  // clearAllToggles 又会对 toggle / longPress 类发一次。GLFW 对重复 RELEASE 是
  // 幂等的所以不会出 bug，但调试日志里会重复刷。这里按 trigger 分工：
  //   - press / doubleTap：buttonReleaseAllFingers 自己发 RELEASE
  //   - toggle / longPress：留给 clearAllToggles 统一处理（它知道哪些已经在按下态）
  // ime_chat 不走"持续按住"语义，对它也只清占用集合，不发 RELEASE
  // （PRESS/RELEASE 在 buttonAddFinger 里已经成对发完）。
  //
  // @param keepHeld 多键健壮性（2026-05-30）：true 时跳过"占用集合仍非空（手指还按着）"
  //   的 press 类按钮——不发 RELEASE、不清占用集合、不清按下视觉，留给真正的 UP 事件处理。
  //   用于 grabbed 翻转，支持跨翻转的组合键（如按住 F3 点 F4）。
  private buttonReleaseAllFingers(keepHeld: boolean = false): void {
    this.buttonFingerIds.forEach((set, id) => {
      if (set.size === 0) return
      const item = this.profile.controls.find((c: ControlItem) => c.id === id)
      const trig: TriggerMode = item ? (item.trigger ?? 'press') : 'press'
      // 系统功能按钮（输入/设置/显示）不发键、无持续按住语义，只清占用集合，绝不补发 RELEASE
      // （尤其 edit/visibility 的 keyOrMouse=0，误发会投递一个无意义的 key 0 事件）。
      const isSystem = item !== undefined && item.systemAction !== undefined
      // 保留按住态：press 类且仍被按住的，跳过（不释放、不清集合）。
      // toggle / longPress / doubleTap / 系统按钮不属于"持续按住"语义，照常清理。
      if (keepHeld && !isSystem && trig === 'press') {
        return
      }
      if (item && !isSystem && (trig === 'press' || trig === 'doubleTap')) {
        this.dispatchButton(item, GLFW_RELEASE)
      }
      set.clear()
    })
    // 重建按下视觉：先全部清按下，再把"仍被按住的按钮"标回按下（keepHeld 时保留 F3 高亮）。
    // 方案 E.2：逐个改 @Observed 对象，仅涉及的按钮子组件刷新。
    this.btnVisMap.forEach((v: BtnVisState) => { v.pressed = false })
    this.buttonFingerIds.forEach((set: Set<number>, id: string) => {
      if (set.size > 0) this.getBtnVis(id).pressed = true
    })
    this.btnPressedVer++   // 触发重渲染，保证按下高亮同步
    // 同步清掉 toggle / longPress 状态机（内部会按需补发 RELEASE）。
    // 注意：keepHeld 下 toggle/longPress 仍清理（它们不是"按住即生效"的连续语义）。
    this.clearAllToggles()
  }

  build() {
    Stack() {
      // 数据驱动：遍历 profile 中的控件
      ForEach(this.profile.controls, (item: ControlItem) => {
        // R1：渲染过滤与 C 层注册共用 isControlVisible（含 hidden / globalVisMode 三档 /
        // force_hide / 场景 / joystick&scroll&hotbar 仅 grabbed）。ArkUI ForEach itemBuilder
        // 不允许 `return`，用嵌套 if 跳过不渲染的分支。
        //
        // ⚠️ 这里曾把"自动隐藏"列为 isControlVisible 的组成部分。**不成立**，
        // 那个功能 2026-06 已删（详见 isControlVisible 的头注释）。这是全仓最后一处
        // 以现在时这样描述的地方，而它离代码最近、最容易被信 —— 所以必须一起改。
        if (this.isControlVisible(item)) {
          if (item.type === ControlType.JOYSTICK) {
            this.JoystickView(item)
          } else if (item.type === ControlType.BUTTON) {
            this.ButtonView(item)
          } else if (item.type === ControlType.SCROLL_WHEEL) {
            this.ScrollWheelView(item)
          } else if (item.type === ControlType.HOTBAR_SELECTOR) {
            this.HotbarSelectorView(item)
          } else if (item.type === ControlType.DRAWER) {
            this.DrawerView(item)
          }
        }
      }, (item: ControlItem) => item.id + '_v' + this.profileVer.toString())

      // 注：编辑布局 / 显示（可见性档位）已改为布局中的"系统功能按钮"（systemAction=edit/visibility），
      // 与普通按钮同样式、可移动、右上角默认位置，由上方 ForEach 统一渲染，这里不再单独画 HUD 覆盖层。

      // 编辑模式
      if (this.editing) {
        this.EditorOverlay()
      }

      // 注：菜单态输入已并入"输入"系统按钮（systemAction=input）：菜单点它开 field IME、游戏内点它开
      // 聊天 IME。一个常驻按钮统筹所有输入，这里不再单独画悬浮键盘按钮。

      // 阶段 2.8：IME 桥接（聊天）
      ChatInputBridge({
        visible: this.imeOpen,
        mode: 'chat',
        onClose: () => { this.imeOpen = false }
      })

      // 2026-05-30：IME 桥接（通用文本框 / 菜单搜索框）。field 模式：提交/取消不发 ENTER/ESC。
      ChatInputBridge({
        visible: this.fieldImeOpen,
        mode: 'field',
        onClose: () => { this.fieldImeOpen = false }
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_oldVal: Area, newVal: Area) => {
      this.compWidth = newVal.width as number
      this.compHeight = newVal.height as number
      this.onLayoutChanged()
    })
  }

  @Builder
  JoystickView(item: ControlItem) {
    // UI 重构 2026-05-30：摇杆形状跟随 effectiveCornerRadius——
    //   1.0（默认）→ 正圆底盘；0 → 正方形底盘；中间 → 圆角方形。
    //   内圈拇指点同步用同一圆角比例，保持观感统一。保留圆形为默认。
    Stack() {
      // 外圈底盘
      Stack()
        .width(this.itemW(item) * 0.93)
        .height(this.itemH(item) * 0.93)
        .backgroundColor('#28FFFFFF')
        .borderRadius(this.joystickOuterRadius(item))
        .border({ width: 1.5, color: '#40FFFFFF' })
      // 内圈拇指点
      Stack()
        .width(this.itemW(item) * 0.37)
        .height(this.itemH(item) * 0.37)
        .backgroundColor(this.joystickX !== 0 || this.joystickY !== 0 ? '#A0FFFFFF' : '#60FFFFFF')
        .borderRadius(this.joystickInnerRadius(item))
        .offset({
          x: this.joystickX * this.itemW(item) * 0.26,
          y: this.joystickY * this.itemH(item) * 0.26
        })
    }
    .width(this.itemW(item))
    .height(this.itemH(item))
    .position({ x: this.itemX(item), y: this.itemY(item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，不能拨动摇杆（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      // 阶段 1.1 多指：摇杆从 DOWN 起锁定一根 fingerId，其他手指不影响。
      // 解决"按住摇杆时另一根手指落在屏幕，touches[0] 错位 → 摇杆瞬间跳变"问题。
      const cx = this.itemW(item) / 2
      const cy = this.itemH(item) / 2
      const radius = this.itemW(item) * 0.34

      // changedTouches 是本次事件涉及的触点（DOWN/UP 的新触点 / MOVE 的位置变化点）
      const changed = event.changedTouches
      if (event.type === TouchType.Down) {
        // 只接管"摇杆未被占用"的首根落到摇杆上的手指
        if (this.joystickFingerId === -1 && changed && changed.length > 0) {
          const t = changed[0]
          this.joystickFingerId = t.id
          let dx = (t.x - cx) / radius
          let dy = (t.y - cy) / radius
          const len = Math.sqrt(dx * dx + dy * dy)
          if (len > 1.0) { dx /= len; dy /= len }
          this.joystickX = dx
          this.joystickY = dy
          if (!this.cOwnsJoystick()) this.updateJoystickKeys(dx, dy)  // A.6：C 接管时只留视觉，WASD 由 C 发
        }
      } else if (event.type === TouchType.Move) {
        if (this.joystickFingerId === -1) return
        // 在 touches 里找占用的 fingerId 对应的位置
        const t = event.touches.find((tt: TouchObject) => tt.id === this.joystickFingerId)
        if (!t) return
        let dx = (t.x - cx) / radius
        let dy = (t.y - cy) / radius
        const len = Math.sqrt(dx * dx + dy * dy)
        if (len > 1.0) { dx /= len; dy /= len }
        // 阶段 4.2：WASD 状态机仍即时跑（手感优先），@State 视觉更新按 60Hz 节流
        if (!this.cOwnsJoystick()) this.updateJoystickKeys(dx, dy)   // A.6：C 接管时只留视觉
        const now = Date.now()
        if (now - this.joystickLastVisualUpdateAt >= JOYSTICK_VISUAL_THROTTLE_MS) {
          this.joystickX = dx
          this.joystickY = dy
          this.joystickLastVisualUpdateAt = now
        }
      } else {
        // Up / Cancel：仅当本次抬起的是占用的那根 finger 时才释放摇杆
        if (this.joystickFingerId !== -1 && changed) {
          const upMine = changed.some((tt: TouchObject) => tt.id === this.joystickFingerId)
          if (upMine) {
            this.joystickFingerId = -1
            this.joystickX = 0
            this.joystickY = 0
            if (!this.cOwnsJoystick()) this.releaseAllDirections()   // A.6：C 接管时由 C 松 WASD
          }
        }
      }
    })
  }

  // 方案 E.2：普通按钮改用 ButtonItemView 子组件（btnPressedVer + @Prop 保证按下态刷新）；
  // 几何/颜色父级算好传入，触摸事件原样回调 handleButtonTouch（逻辑不变）。
  @Builder
  ButtonView(item: ControlItem) {
    ButtonItemView({
      vis: this.getBtnVis(item.id),
      pressedVer: this.btnPressedVer,
      label: this.systemButtonLabel(item),
      x: this.itemX(item),
      y: this.itemY(item),
      w: this.itemW(item),
      h: this.itemH(item),
      fontSizeVp: this.btnFontSize(item),
      borderRadiusVp: this.btnBorderRadius(item),
      opacityVal: renderOpacity(item, this.profile),
      fgNormal: item.style?.fg ?? '#DDFFFFFF',
      fgPressed: item.style?.fg ?? '#FFFFFFFF',
      bgNormal: item.style?.bg ?? '#30FFFFFF',
      bgPressed: item.style?.bgPressed ?? item.style?.bg ?? '#52FFFFFF',
      onTouchEvent: (event: TouchEvent) => { this.handleButtonTouch(item, event) },
      onAccessibilityActivate: () => { this.activateButtonFromAccessibility(item) }
    })
  }

  // 普通按钮触摸处理（从原 ButtonView.onTouch 提取，逻辑零变化）。
  private handleButtonTouch(item: ControlItem, event: TouchEvent): void {
    // 鼠标是并列输入源，不能按虚拟按键（见 isPointerSourcedTouch）。
    if (this.isPointerSourcedTouch(event)) return
    // New DOWN follows current ownership. A pre-existing ArkTS DOWN must still
    // receive its UP/CANCEL after a grab flip even if the current schema now owns
    // this control; the down-time output record is authoritative for that edge.
    if (this.cOwnsButton(item)) {
      if (!this.arktsButtonOutputs.has(item.id)) return
      if (event.type !== TouchType.Up && event.type !== TouchType.Cancel) return
    }
    // 阶段 1.1 多指：用 fingerId 集合跟踪占用，集合空↔满变化才发 PRESS/RELEASE。
    // 多指健壮性（2026-05-30）：DOWN 只认"落点确实在本按钮范围内"的触点——
    // ArkUI 在按钮紧贴（如 1-9 hotbar）/ 事件交叉派发时，可能把别的按钮的触点也
    // 派到本按钮的 onTouch；不过滤会导致"按住 F3 点 F4，F4 的指被加进 F3 集合
    // → 松手后 F3 卡住"。UP/Cancel 不过滤（靠 buttonRemoveFinger 的 set.has 兜底）。
    const changed = event.changedTouches
    if (!changed || changed.length === 0) return
    const isDragLook = item.dragLook === true
    if (event.type === TouchType.Down) {
      for (let i = 0; i < changed.length; i++) {
        if (this.touchInItem(item, changed[i])) {
          this.buttonAddFinger(item, changed[i].id)
          // 拖动瞄准：记录本按钮上拖动的 finger + 起始坐标（用组件局部 x/y，按钮不移动，
          // 局部位移即手指位移）。MOVE 时按位移发 cursorDelta。只跟踪首根落在按钮上的 finger。
          if (isDragLook && !this.dragLookFinger.has(item.id)) {
            this.dragLookFinger.set(item.id, changed[i].id)
            this.dragLookLastX.set(item.id, changed[i].x)
            this.dragLookLastY.set(item.id, changed[i].y)
          }
        }
      }
    } else if (event.type === TouchType.Move) {
      // 拖动瞄准：按住按钮保持 PRESS，手指拖动 → sendCursorDelta 转视角。
      // A.6 阶段2：C 接管该按钮时，dragLook 也由 C 处理，ArkTS 跳过（避免双份视角增量）。
      if (isDragLook && !this.cOwnsButton(item)) {
        const owner = this.dragLookFinger.get(item.id)
        if (owner !== undefined) {
          const t = event.touches.find((tt: TouchObject) => tt.id === owner)
          if (t) {
            const lastX = this.dragLookLastX.get(item.id) ?? t.x
            const lastY = this.dragLookLastY.get(item.id) ?? t.y
            const dx = t.x - lastX
            const dy = t.y - lastY
            this.dragLookLastX.set(item.id, t.x)
            this.dragLookLastY.set(item.id, t.y)
            if (dx !== 0 || dy !== 0) {
              // 申报**触控端**。此前这里走不带端标注的 sendCursorDelta，native 一律
              // 记成手柄端，于是 `lookPad` 计数实际是"手柄 + 触控 dragLook"，而两者
              // 量纲完全不同（这里是 vp 局部坐标差分，手柄是摇杆归一量×增益）。
              try {
                testNapi.sendSourceCursorDelta(TOUCH_SOURCE, dx, dy)
              } catch (e) { /* ignore */ }
            }
          }
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 拖动瞄准：本次抬起的是占用的那根 finger 时清掉跟踪
      if (isDragLook) {
        const owner = this.dragLookFinger.get(item.id)
        if (owner !== undefined && changed.some((tt: TouchObject) => tt.id === owner)) {
          this.dragLookFinger.delete(item.id)
          this.dragLookLastX.delete(item.id)
          this.dragLookLastY.delete(item.id)
        }
      }
      // 抬起的所有 finger 从占用集合移除（set.has 兜底，移除不属于本按钮的 id 是 no-op）
      for (let i = 0; i < changed.length; i++) {
        this.buttonRemoveFinger(item, changed[i].id)
      }
    }
    // 非 dragLook 按钮：Move 不参与；按下后即使手指轻微移动仍保持按下，松手才 RELEASE
  }

  /**
   * 多指健壮性（2026-05-30）：判断一个触点是否落在本控件范围内。
   * ArkUI 的 TouchObject.x/y 是相对当前 onTouch 组件的局部坐标（与 JoystickView 一致），
   * 所以"在范围内" = 局部坐标落在 [−tol, W+tol] × [−tol, H+tol]（留 2vp 容差防边界抖动）。
   */
  private touchInItem(item: ControlItem, t: TouchObject): boolean {
    const tol = 2
    const w = this.itemW(item)
    const h = this.itemH(item)
    return t.x >= -tol && t.x <= w + tol && t.y >= -tol && t.y <= h + tol
  }

  // ============= 阶段 3.2：按钮外观（style 优先于硬编码默认） =============

  private btnFgColor(item: ControlItem): string {
    if (item.style?.fg) return item.style.fg
    if (this.isPressed(item.id)) return '#FFFFFFFF'
    return '#DDFFFFFF'
  }

  // UI 重构 2026-05-30：框内字号按短边自适应，正方形框统一观感。
  //   字号 = 短边 × 0.42，夹在 [10, 22] vp；多字符短标签（Space/Ctrl+1）也能读。
  private btnFontSize(item: ControlItem): number {
    const w = this.itemW(item)
    const h = this.itemH(item)
    const shortSide = Math.min(w, h)
    let fs = shortSide * 0.42
    // 标签较长（>2 字符，如 Space / Shift / Enter）时缩一档，避免溢出
    const label = effectiveLabel(item)
    if (label.length >= 4) fs = shortSide * 0.30
    else if (label.length === 3) fs = shortSide * 0.36
    if (fs < 10) fs = 10
    if (fs > 22) fs = 22
    return fs
  }

  private btnBgColor(item: ControlItem): string {
    if (item.style) {
      if (this.isPressed(item.id) && item.style.bgPressed) return item.style.bgPressed
      if (item.style.bg) return item.style.bg
    }
    if (this.isPressed(item.id)) {
      return '#52FFFFFF'
    }
    return '#30FFFFFF'
  }

  private btnBorderRadius(item: ControlItem): number {
    // UI 重构 2026-05-29：统一用连续 cornerRadius（0..1）× 短边一半，得到实际圆角 px。
    //   0 → 直角；1 → 短边方形时为正圆。兼容旧 style.shape / isCircle（见 effectiveCornerRadius）。
    const w = this.itemW(item)
    const h = this.itemH(item)
    const shortHalf = Math.min(w, h) / 2
    return effectiveCornerRadius(item) * shortHalf
  }
  @Builder
  ScrollWheelView(item: ControlItem) {
    Stack() {
      // 视觉：纵向胶囊条，中间画一个浅浅的"双向箭头"或 ⇅ 字符
      Column() {
        Text('▲').fontSize(10 * this.profile.globalScale).fontColor('#88FFFFFF')
        Text(item.label).fontSize(11 * item.itemScale * this.profile.globalScale).fontColor('#BBFFFFFF')
        Text('▼').fontSize(10 * this.profile.globalScale).fontColor('#88FFFFFF')
      }
      .width(this.itemW(item))
      .height(this.itemH(item))
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Center)
      .padding(4)
    }
    .width(this.itemW(item))
    .height(this.itemH(item))
    .backgroundColor('#28FFFFFF')
    .borderRadius(this.itemW(item) / 2)
    .position({ x: this.itemX(item), y: this.itemY(item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，滚轮由物理 AXIS 通道处理（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      // A.6 阶段3：C 接管滚轮时 ArkTS 直接不处理（滚动由 C 发）
      if (this.cOwnsScroll()) return
      // 阶段 1.5：滚轮控件——纵向 drag → 累计 dy → 每 SCROLL_STEP_VP 触发一次 scroll 事件。
      // 上滑（dy<0）发 +1（hotbar 往左切），下滑（dy>0）发 -1。
      const changed = event.changedTouches
      if (!changed || changed.length === 0) return
      const id = item.id
      if (event.type === TouchType.Down) {
        if (this.scrollFingerIds.has(id)) return
        const t = changed[0]
        this.scrollFingerIds.set(id, t.id)
        this.scrollLastY.set(id, t.y)
        this.scrollAccumDy.set(id, 0)
      } else if (event.type === TouchType.Move) {
        const owner = this.scrollFingerIds.get(id)
        if (owner === undefined) return
        const t = event.touches.find((tt: TouchObject) => tt.id === owner)
        if (!t) return
        const lastY = this.scrollLastY.get(id) ?? t.y
        const dy = t.y - lastY
        this.scrollLastY.set(id, t.y)
        let accum = (this.scrollAccumDy.get(id) ?? 0) + dy
        // 每 SCROLL_STEP_VP 触发一次。R3：方向引用单一约定常量（上滑=UP，下滑=DOWN）。
        while (accum <= -SCROLL_STEP_VP) {
          testNapi.sendSourceScrollEvent(TOUCH_SOURCE, 0, SCROLL_YOFFSET_UP)
          accum += SCROLL_STEP_VP
        }
        while (accum >= SCROLL_STEP_VP) {
          testNapi.sendSourceScrollEvent(TOUCH_SOURCE, 0, SCROLL_YOFFSET_DOWN)
          accum -= SCROLL_STEP_VP
        }
        this.scrollAccumDy.set(id, accum)
      } else {
        // Up / Cancel：本次抬起的是占用的那根 finger 才释放
        const owner = this.scrollFingerIds.get(id)
        if (owner === undefined) return
        const upMine = changed.some((tt: TouchObject) => tt.id === owner)
        if (upMine) {
          this.scrollFingerIds.delete(id)
          this.scrollLastY.delete(id)
          this.scrollAccumDy.delete(id)
        }
      }
    })
  }

  // ============= F1（2026-07-11）：物品栏直点条 =============
  //
  // 透明 9 分区条，叠在 MC 真实 hotbar 上（几乎不可见，让 MC 自己的选中高亮透出）。
  // 点第 i 格 → 发数字键 GLFW_KEY_1+i（绝对选格）；横向滑动跨格补发（扫选）。
  // 发的是 tap（PRESS+RELEASE），无持续按住态。命中矩形由 registerRegions 的 else 分支注册，
  // grabbed 下 native 视角会避让此区域（不会点物品栏时误转视角）。

  private hotbarZones(): number[] {
    const arr: number[] = []
    for (let i = 0; i < HOTBAR_SLOT_COUNT; i++) arr.push(i)
    return arr
  }

  private hotbarSlotOf(item: ControlItem, localX: number): number {
    const w = this.itemW(item)
    if (w <= 0) return 0
    let s = Math.floor(localX / (w / HOTBAR_SLOT_COUNT))
    if (s < 0) s = 0
    if (s > HOTBAR_SLOT_COUNT - 1) s = HOTBAR_SLOT_COUNT - 1
    return s
  }

  private sendHotbarSlot(slot: number): void {
    const key = GLFW_KEY_1 + slot
    if (!sendKey(key, GLFW_PRESS)) return
    // A tap still has a native held edge between the two calls.  If the
    // release is rejected (for example during a surface transition), invoke
    // the source-scoped recovery path instead of silently leaving the slot
    // key held in the external ledger.
    if (!sendKey(key, GLFW_RELEASE)) {
      this.forceReleaseTouchSource('hotbar-release-rejected')
      return
    }
    if (this.profile.haptic ?? true) hapticTap(6)
  }

  @Builder
  HotbarSelectorView(item: ControlItem) {
    Row() {
      ForEach(this.hotbarZones(), (z: number) => {
        Column()
          .layoutWeight(1)
          .height('100%')
          // 首格无左分隔线，其余格画一条极淡竖线示意分区；整体保持高透明，让 MC hotbar 透出
          .border({ width: { left: z === 0 ? 0 : 0.5 }, color: '#33FFFFFF' })
      }, (z: number) => item.id + '_z' + z.toString() + '_v' + this.profileVer.toString())
    }
    .width(this.itemW(item))
    .height(this.itemH(item))
    .backgroundColor('#12FFFFFF')
    .borderRadius(this.btnBorderRadius(item))
    .border({ width: 1, color: '#3CFFFFFF' })
    .position({ x: this.itemX(item), y: this.itemY(item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，不能翻物品栏（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      // A.6 阶段3：C 接管物品栏时 ArkTS 直接不处理（切格数字键由 C 发）
      if (this.cOwnsHotbar()) return
      const changed = event.changedTouches
      if (!changed || changed.length === 0) return
      const id = item.id
      if (event.type === TouchType.Down) {
        if (this.hotbarFingerId.has(id)) return
        const t = changed[0]
        this.hotbarFingerId.set(id, t.id)
        const slot = this.hotbarSlotOf(item, t.x)
        this.hotbarLastSlot.set(id, slot)
        this.sendHotbarSlot(slot)
      } else if (event.type === TouchType.Move) {
        const owner = this.hotbarFingerId.get(id)
        if (owner === undefined) return
        const t = event.touches.find((tt: TouchObject) => tt.id === owner)
        if (!t) return
        const slot = this.hotbarSlotOf(item, t.x)
        if (slot !== (this.hotbarLastSlot.get(id) ?? -1)) {
          this.hotbarLastSlot.set(id, slot)
          this.sendHotbarSlot(slot)   // 扫选：跨格补发
        }
      } else {
        const owner = this.hotbarFingerId.get(id)
        if (owner === undefined) return
        if (changed.some((tt: TouchObject) => tt.id === owner)) {
          this.hotbarFingerId.delete(id)
          this.hotbarLastSlot.delete(id)
        }
      }
    })
  }

  // ============= 阶段 3.1：折叠抽屉 =============

  /**
   * 抽屉控件：渲染一个主按钮（点击切换 open/close 状态）；展开时把 children
   * 按扇形 / 简单网格围绕在主按钮周围。
   *
   * 当前实现：children 简单地以主按钮为中心，按 8 向均分（最多 8 个）排成一圈
   * 距离 1.4 倍主按钮宽度的位置；超过 8 个则换到第二圈（1.7 倍距离）。
   * 子按钮渲染走 ButtonView 路径，所以触发 / trigger / 改键全部复用现有逻辑。
   */
  @Builder
  DrawerView(item: ControlItem) {
    // 主按钮（永远显示）
    Text(item.label || '⋯')
      .width(this.itemW(item))
      .height(this.itemH(item))
      .fontSize(16 * item.itemScale * this.profile.globalScale)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .fontColor('#FFFFFF')
      .borderRadius(this.itemW(item) / 2)
      .backgroundColor(this.drawerOpen.get(item.id) ? '#88448AFF' : '#44448AFF')
      .position({ x: this.itemX(item), y: this.itemY(item) })
      .hitTestBehavior(HitTestMode.Block)
      .animation({ duration: 200 })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .accessibilityText(effectiveLabel(item))
      .accessibilityDescription((this.drawerOpen.get(item.id) ?? false) ?
        $r('app.string.input_drawer_open') : $r('app.string.input_drawer_closed'))
      .onClick((event: ClickEvent) => {
        // 鼠标是并列输入源，不能开合抽屉（见 isPointerSourcedTouch）。onClick 对鼠标
        // 主键必然触发，因此这里与 onTouch 入口一样需要显式拦截。ClickEvent 自带窗口
        // 坐标，可直接做位置回声判定。
        if (this.isPointerDeviceSourced(event.source, event.sourceTool) ||
            (!this.isGrabbed &&
             getPhysicalPointerEcho().isLikelyPhysicalPointerAt(
                 event.windowX, event.windowY))) {
          return
        }
        const cur = this.drawerOpen.get(item.id) ?? false
        this.drawerOpen.set(item.id, !cur)
        this.drawerOpen = new Map(this.drawerOpen)
        // 方案 A 收尾：抽屉展开/收起改变了可见子按钮，重下发 schema 让 C 更新"忽略区"（防子按钮 look 穿透）。
        this.registerRegions()
      })

    // 子按钮（仅 open 时渲染）
    if ((this.drawerOpen.get(item.id) ?? false) && item.children) {
      ForEach(item.children, (c: ControlItem, ci: number) => {
        if (!c.hidden) {
          this.DrawerChild(item, c, ci)
        }
      }, (c: ControlItem, ci: number) => item.id + '_' + c.id + '_v' + this.profileVer.toString())
    }
  }

  /** 计算子按钮在抽屉中的位置（vp 绝对坐标）。Builder 里禁止命令式语句，所以拆出来。 */
  private drawerChildX(p: ControlItem, c: ControlItem, idx: number): number {
    const total = (p.children ? p.children.length : 1)
    const ringIdx = Math.floor(idx / 8)
    const angleStep = (Math.PI * 2) / Math.min(8, total)
    const startAngle = -Math.PI / 2
    const angle = startAngle + angleStep * (idx % 8)
    const distance = (1.4 + ringIdx * 0.4) * this.itemW(p) / 2 + this.itemW(c)
    return this.itemPxCenterX(p) + Math.cos(angle) * distance - this.itemW(c) / 2
  }
  private drawerChildY(p: ControlItem, c: ControlItem, idx: number): number {
    const total = (p.children ? p.children.length : 1)
    const ringIdx = Math.floor(idx / 8)
    const angleStep = (Math.PI * 2) / Math.min(8, total)
    const startAngle = -Math.PI / 2
    const angle = startAngle + angleStep * (idx % 8)
    const distance = (1.4 + ringIdx * 0.4) * this.itemW(p) / 2 + this.itemW(c)
    return this.itemPxCenterY(p) + Math.sin(angle) * distance - this.itemH(c) / 2
  }

  // 方案 E.2：抽屉子按钮同样复用 ButtonItemView（btnPressedVer + @Prop 刷新），触摸回调 handleDrawerChildTouch。
  @Builder
  DrawerChild(p: ControlItem, c: ControlItem, idx: number) {
    ButtonItemView({
      vis: this.getBtnVis(c.id),
      pressedVer: this.btnPressedVer,
      label: effectiveLabel(c),
      x: this.drawerChildX(p, c, idx),
      y: this.drawerChildY(p, c, idx),
      w: this.itemW(c),
      h: this.itemH(c),
      fontSizeVp: this.btnFontSize(c),
      borderRadiusVp: this.btnBorderRadius(c),
      opacityVal: renderOpacity(c, this.profile),
      fgNormal: c.style?.fg ?? '#DDFFFFFF',
      fgPressed: c.style?.fg ?? '#FFFFFFFF',
      bgNormal: c.style?.bg ?? '#30FFFFFF',
      bgPressed: c.style?.bgPressed ?? c.style?.bg ?? '#52FFFFFF',
      onTouchEvent: (event: TouchEvent) => { this.handleDrawerChildTouch(c, event) },
      onAccessibilityActivate: () => { this.activateButtonFromAccessibility(c) }
    })
  }

  // 抽屉子按钮触摸处理（从原 DrawerChild.onTouch 提取，逻辑零变化：无 dragLook）。
  private handleDrawerChildTouch(c: ControlItem, event: TouchEvent): void {
    // 鼠标是并列输入源，不能按抽屉子按钮（见 isPointerSourcedTouch）。
    // 子按钮是 handledBy=arkts，native 从不接管，所以这里是唯一的拦截点。
    if (this.isPointerSourcedTouch(event)) return
    const changed = event.changedTouches
    if (!changed || changed.length === 0) return
    if (event.type === TouchType.Down) {
      for (let i = 0; i < changed.length; i++) {
        if (this.touchInItem(c, changed[i])) {
          this.buttonAddFinger(c, changed[i].id)
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      for (let i = 0; i < changed.length; i++) {
        this.buttonRemoveFinger(c, changed[i].id)
      }
    }
  }

  private itemPxCenterX(c: ControlItem): number {
    return this.itemX(c) + this.itemW(c) / 2
  }
  private itemPxCenterY(c: ControlItem): number {
    return this.itemY(c) + this.itemH(c) / 2
  }

  @Builder
  EditorOverlay() {
    LayoutEditor({
      screenWidth: this.compWidth,
      screenHeight: this.compHeight,
      onDone: (result: LayoutProfile | null) => { this.finishEditor_(result) },
      onInitializationFailed: (message: string) => { this.editorInitializationFailed_(message) }
    })
  }
}

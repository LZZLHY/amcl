/**
 * GameControls.ets — 虚拟按键（Control Schema v3 + publication v1 + ArkUI 辅助交互）
 *
 * 当前所有权：
 * - grabbed 下的摇杆、普通按钮、滚轮、hotbar 与 look 由 native schema 解释并产生输入；
 * - native 按钮视觉边沿经 onButtonPressed 投影回来，ArkTS 不再为已接管控件重复发键；
 * - IME、drawer/抽屉子按钮等 handledBy=arkts 控件仍由 ArkUI exact rect 处理；
 * - 几何由RuntimeTouchLayout一次投影，安装/呈现/确认由TouchSurfaceController协调；
 * - Native拒绝保留旧有效表，失效context取得touch模态；不再用v2空表重置触控策略。
 *
 * ArkTS 仍维护的 finger/trigger/WASD 状态只服务 handledBy=arkts 与兼容路径；生命周期边界先由本端
 * 按按下时的记录自释放，再由 native cancelAll 兜底清空权威 ledger，禁止恢复 grabbed 主路径双发。
 */
import testNapi from 'libentry.so';
import { ControlSchemaEntry, ControlSchemaMsg } from 'libentry.so';
import { EntryTouchSession, EntryTouchVisual, EntryTouchObservationSnapshot } from './EntryTouchSession';
import { RuntimeTouchLayout, RuntimeTouchEntry, runtimeTouchContext, projectRuntimeTouchLayout,
  runtimeTouchControlVisible, layoutCapabilityIssue, RuntimeTouchOverlay, appendRuntimeTouchOverlay } from 'gamecontrol';
import { getGameSessionHost } from '../runtime/GameSessionHost'
import { EntryInputObservationResult, EntryInputObservationRegistration, registerEntryInputObservation,
  unregisterEntryInputObservation } from './EntryInputObservationPort'
import { componentUtils } from '@kit.ArkUI';
import { TouchSurfaceController, TouchSurfaceCandidate } from './TouchSurfaceController';
import { EntryTouchModalLease, acquireEntryTouchModal, releaseEntryTouchModal,
  reconcileEntryTouchModals, hasEntryTouchModal } from './EntryTouchModalBroker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticPolicy } from 'commons';
import {
  GLFW_PRESS, GLFW_RELEASE,
  GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D, GLFW_KEY_1,
  SCROLL_YOFFSET_UP, SCROLL_YOFFSET_DOWN
} from 'gamecontrol';
import {
  ControlItem, ControlType, LayoutProfile, TriggerMode, AlignGroup,
  getDefaultLayout, cloneLayout, validateAndNormalizeLayout,
  DEFAULT_JOYSTICK_DEAD_ZONE, effectiveKeys, HOTBAR_SLOT_COUNT, MAX_LAYOUT_CHILD_DEPTH,
  effectiveCornerRadius, effectiveLabel, isVisibleInScene, renderOpacity,
  InputConfigurationListener, InputConfigurationProgress, InputPolicyActivationSnapshot, InputPolicyStatusSubscription, inputPolicyStatusMessage
} from 'gamecontrol';
import { getLayoutStore, LayoutStore } from 'gamecontrol';
import { LayoutEditor } from './LayoutEditor';
import { InputSettingsEditor } from './InputSettingsEditor';
import { SourceControlClient } from 'gamecontrol';
import { GameGuiState, projectGameNavigation, SmallGuiGuard, FloatingMouseFrame,
  TouchGuideLayout, touchGuideLayout } from 'gamecontrol'
import { EntryVirtualMouse } from './EntryVirtualMouse'
import { VirtualMousePanel } from './VirtualMousePanel'
import { TouchLearningView } from './TouchLearningView'
import { TouchLearningStore } from './TouchLearningStore'
import { TouchJoystickVisual } from './TouchJoystickVisual'
import { touchHotbarSlot } from 'gamecontrol'
import { TouchGuide, TouchGuideStep, TouchControlRect, normalizeTouchPreferences } from 'gamecontrol'
import { createEntrySourceControlClient } from './EntrySourceControlClient';
import { ChatInputBridge } from './ChatInputBridge';
import { DesktopPhysicalTextInput } from './DesktopPhysicalTextInput';
import { ProductInputProfile } from 'entry/ProductInputProfile';
import { hapticTap } from 'feature_system';
import { getInputDeviceMonitor, DeviceCapability } from 'gamecontrol';
import { getPhysicalPointerEcho } from 'gamecontrol';
import { getInputSourceRegistry, AmclInputSource, InputEnd, CallbackInputEnd } from 'gamecontrol';
import { ControlGroupWitness } from 'gamecontrol';
import { TouchGroupReceipt, TouchGroupSchema, TouchGroupCommandReceipt } from 'libentry.so';
import { compileTouchGroups } from './TouchGroupSchemaCompiler';
import { joystickSector } from 'gamecontrol';
import {
  EntryControlFeedbackLease,
  acquireEntryControlFeedback,
  releaseEntryControlFeedback
} from './EntryControlFeedbackBroker';
import {
  InputSurfaceContext,
  getInputSurfaceContextStore
} from 'gamecontrol';

// 夹取后的控件物理像素矩形（clampEntryRect 返回值）。
interface RectPx { x: number; y: number; w: number; h: number }

/** Builder只使用单个按引用对象；stable ID保留节点，profileVer同步当前item和publication。 */
interface TouchControlViewArgs { item: ControlItem; revision: number; token: string; groupEpoch?: string }
interface TouchDrawerChildArgs { item: ControlItem; parent: ControlItem; index: number; revision: number; token: string; groupEpoch?: string }
/** 提示面板也绑定实际呈现token；单个Builder引用参数让重新呈现时同步更新事件资格。 */
interface TouchOverlayViewArgs { token: string }
/** UI 命令在调用前冻结身份；异常只保留原序号查询，不能把重试变成第二次 toggle。 */
interface TouchGroupCommandIntent { token: string; control: string; eligibility: string; producer: string; sequence: string; phase: number }

/** 首次打开前没有可见鼠标本体；有效视口同步后才将模型几何投影为真实绘制和Native范围。 */
function emptyFloatingMouseFrame(): FloatingMouseFrame {
  const frame: FloatingMouseFrame=new FloatingMouseFrame()
  frame.width=0; frame.height=0
  return frame
}

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
  token: string = ''
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
  @Prop nodeId: string = ''
  @Prop groupVisible: boolean = true
  @Prop groupRank: number = 0
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
    // 固定根节点承担命中与呈现确认；按下缩放只改变其内部视觉，不改变schema对应矩形。
    // 因此按住其它组按钮时，组ACK不会被0.95缩放或50ms回弹动画阻塞。
    Stack() {
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
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
    }
      .width(this.w).height(this.h)
      .id(this.nodeId)
      .visibility(this.groupVisible ? Visibility.Visible : Visibility.Hidden)
      .zIndex(this.groupRank)
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
  /** 仅为 Native 回执的呈现镜像，任何按钮回调不得直接翻转该数组。 */
  @State private groupMask: boolean[] = []
  @State private groupRevision: string = ''
  private groupEpochs: string[] = []
  private groupSchema: TouchGroupSchema | undefined = undefined
  private groupToken: string = ''
  private groupPending: boolean = false
  private groupPresentedRevision: string = ''
  private groupRegistration: string = ''
  private nextGroupListenerAttempt: number = 0
  private groupCommandSequence: number = 0
  private groupRestoreRequested: boolean = false
  private groupRestoreSequence: string = ''
  private groupRestoreToken: string = ''
  private groupRanks: Map<string, number> = new Map<string, number>()
  private groupIndices: Map<string, number> = new Map<string, number>()
  private groupControls: ControlItem[] = []
  private pendingGroupCommands: Map<string, TouchGroupCommandIntent> = new Map<string, TouchGroupCommandIntent>()
  private lastGroupIssue: string = ''
  /** 由页面传入经过实例隔离校验的目录，只读该游戏的动作绑定。 */
  @Prop @Watch('onTouchGameDirectoryChanged') gameDirectory: string = ''
  @Prop @Watch('onTouchGameDirectoryChanged') realGameVersion: string = ''
  private touchSession: EntryTouchSession = new EntryTouchSession()
  @State touchVisual: EntryTouchVisual = new EntryTouchVisual()
  /** 面板的必要绘制/命中位置独立于光标等可选显示；由原Session只读快照更新。 */
  @State private menuGeometryX: number = 0
  @State private menuGeometryY: number = 0
  private observationEnabled: boolean = true
  private observationGeneration: number = 0
  /** 每个原组件实例最多64条输入入口阶段记录；无@State，不驱动呈现或输入资格。 */
  private imeRouteTraceCount: number = 0
  private observationRegistration: EntryInputObservationRegistration | undefined = undefined
  private observationResumeTeaching: boolean = false
  private feedbackClearComplete: boolean = true
  @State private guiState: GameGuiState=new GameGuiState()
  @State private mouseOpen: boolean=false
  @State private guiHint: boolean=false
  @State private guiMessage: string=''
  @State private restorePending: number=0
  @State private tutorialOpen: boolean=false
  @State private guideStep: number=TouchGuideStep.Move
  private touchGuide: TouchGuide=new TouchGuide()
  private guideScrollRequested: boolean=false
  private guideBoundsKey: string=''
  private mouseController: EntryVirtualMouse=new EntryVirtualMouse()
  /**
   * 鼠标本体唯一可观察几何；模型原始随指与Native指针反馈互相独立，不能只靠menuGeometry刷新。
   * 同一份投影同时用于绘制与排除区，仅几何实际改变才整体赋值，不重建触控schema。
   */
  @State private mouseGeometry: FloatingMouseFrame=emptyFloatingMouseFrame()
  /** 已请求呈现的唯一几何投影；desired配置在协调器中保存，拒绝时不改这里。 */
  @State private runtimeLayout: RuntimeTouchLayout = new RuntimeTouchLayout()
  @State private uiPublicationToken: string = ''
  private presentedCandidateId: string = ''
  @State private touchStatusMessage: string = ''
  /** 原会话provider只读状态，保存与激活分别显示；订阅本身不驱动输入或发布。 */
  @State private configurationStatusMessage: string = ''
  /** 同一次原报告的普通值缓存；不交给ArkUI观察代理，也不将展示过滤结果写回Store或运行域。 */
  private configurationStatusSnapshot: InputPolicyActivationSnapshot | undefined = undefined
  /** 仅结构化分类结果参与响应；同类新快照不重复赋值，避免对象身份变化驱动额外UI更新。 */
  @State private configurationStatusEditorPauseWait: boolean = false
  private configurationStatusSubscription: InputPolicyStatusSubscription | undefined = undefined
  private configurationStatusStore: LayoutStore | undefined = undefined
  private desiredProfile: LayoutProfile = getDefaultLayout()
  private imeModal: EntryTouchModalLease | undefined = undefined
  private editorModal: EntryTouchModalLease | undefined = undefined
  /** 实测几何资格缺失时独立关门；有效新候选布局确认后只释放本租约。 */
  private unresolvedSurfaceModal: EntryTouchModalLease | undefined = undefined
  private blockedUiFingers: Set<number> = new Set<number>()
  /** 被局部组门拒绝的段没有 UI owner；Native 保留真实接触及隔离，不能把此墓碑当活触点阻塞整表。 */
  private groupBlockedUiFingers: Set<number> = new Set<number>()
  private layoutObserverRegistered: boolean = false
  private nextLayoutObserverAttempt: number = 0
  private nextFeedbackAttempt: number = 0
  private feedbackRegistrationWarned: boolean = false
  private readonly didTouchLayout: () => void = (): void => { this.confirmTouchLayout_() }
  private touchSurface: TouchSurfaceController = this.createTouchSurface_()
  /** Native租约退休后只推进鼠标UI投影；面板保持打开，不新增轮询或再发送释放。 */
  @State private mouseResetRevision: number=0
  private guiGuard: SmallGuiGuard=new SmallGuiGuard()
  private learningSeen: boolean=true
  private learningStore: TouchLearningStore | undefined=undefined
  private learningRequested: boolean=false

  /** 实例切换连同动作快照一起退休，不从另一个AppStorage实例猜测目录。 */
  private onTouchGameDirectoryChanged(): void {
    this.touchSession.setDirectory(this.gameDirectory)
    if (this.mounted && !this.editing) this.registerRegions()
  }

  /** 只显示已安装/呈现的共同投影：Native根先、UI根后，抽屉孩子随UI父Builder后绘。
   * Native只在跨解释域先让出UI exact；本列表不声称Native内部最近中心等于视觉Z顺序。
   */
  private displayedControls(): ControlItem[] {
    return this.runtimeLayout.controls
  }

  /** 设置桥只有数值快照；几何真正变化才重发命中表，页面身份变化不让普通输入无故换代。 */
  private receiveGameGui(state: GameGuiState): void {
    if(!this.mounted) return
    const changed: boolean=state.valid!==this.guiState.valid || state.effective!==this.guiState.effective ||
      state.framebufferWidth!==this.guiState.framebufferWidth || state.framebufferHeight!==this.guiState.framebufferHeight ||
      state.guiWidth!==this.guiState.guiWidth || state.guiHeight!==this.guiState.guiHeight
    this.guiState=state
    if(this.restorePending>0 && state.requestId===this.restorePending && state.result!==1) {
      this.restorePending=0
      this.guiMessage=state.result===2 ? '已恢复界面大小' : '界面已改变或恢复未完成，可用精细鼠标调整'
      if(state.result===2) this.guiHint=false
    }
    if(!this.isGrabbed && !this.editing && this.guiGuard.observe(state,this.compWidth)) {
      this.guiHint=true; this.guiMessage=state.estimated ?
        '游戏界面较小。此版本暂以设置文件估算大小，可用精细鼠标调整，或继续保留。' :
        '游戏界面元素变得较小，是否恢复之前的大小？'
    }
    if(changed || this.guiHint) this.registerRegions()
    this.maybeOpenLearning()
  }
  /** 只在实际游戏抓取态开始，主菜单/启动画面绝不弹出按键教学；未抬手时继续等候。 */
  private maybeOpenLearning(): void {
    if(this.observationEnabled!==false && this.touchVisual.guide.grabbed && this.pageActive && this.isGrabbed && this.learningRequested && !this.editing && !this.guiHint &&
      !this.mouseOpen && !this.hasContinuousControlInteraction() &&
      !this.imeOpen && !this.fieldImeOpen) this.openLearning()
  }
  /** 引导不暂停或复位真实输入；工具栏单独更新热区，不能用整表换代取消已按住的键。 */
  private openLearning(): void {
    if(this.observationEnabled===false || this.tutorialOpen || this.editing || !this.touchGuide.start(this.touchVisual.guide)) return
    this.learningSeen=true; this.learningRequested=false
    if(this.learningStore!==undefined) this.learningStore.markSeen()
    this.guideStep=this.touchGuide.step; this.tutorialOpen=true
    this.syncGuideObservation()
    this.syncGuideBounds(); this.touchSession.refreshVisual()
  }
  /** 实际事件达成且全部抬手后自动下一步，旧事件、暂停或schema换代不会被追认为新成果。 */
  private observeLearning(): void {
    if(this.observationEnabled===false || !this.tutorialOpen) return
    if(!this.pageActive || this.editing || this.guiHint || this.imeOpen || this.fieldImeOpen || hasEntryTouchModal()) {
      this.touchGuide.baseline(this.touchVisual.guide); this.syncGuideObservation(); this.syncGuideBounds(); return
    }
    if(this.guideScrollRequested && this.touchVisual.guide.fingers===0) {
      this.guideScrollRequested=false
      if(this.touchGuide.beginScroll(this.touchVisual.guide,normalizeTouchPreferences(this.profile.touch)?.menuTwoFingerScroll ?? true)) {
        this.learningStore?.markLesson(TouchGuideStep.Menu); this.guideStep=this.touchGuide.step
      }
    }
    const previous: number=this.touchGuide.step
    if(this.touchGuide.observe(this.touchVisual.guide)) {
      this.learningStore?.markLesson(previous); this.guideStep=this.touchGuide.step
    }
    if(this.guideStep===TouchGuideStep.Done) this.closeLearning(true)
    this.syncGuideObservation()
  }
  private closeLearning(completed: boolean=false): void {
    this.touchGuide.stop(); this.tutorialOpen=false; this.guideScrollRequested=false
    this.syncGuideObservation()
    this.learningStore?.markClosed(completed)
    this.syncGuideBounds()
  }
  private skipLearning(): void {
    this.touchGuide.skip(this.touchVisual.guide); this.guideStep=this.touchGuide.step
    this.syncGuideObservation()
    if(this.guideStep===TouchGuideStep.Done) this.closeLearning(false)
  }
  private startScrollLearning(): void {
    // 已确认的视频页没有滚动余量时不伪造滚动教学；未知/模组页面仍允许用户选择真实列表开始。
    if(this.guiState.navigationKind===3 && this.guiState.navigationScrollKnown && !this.guiState.navigationScrollable) return
    this.guideScrollRequested=true
    this.touchSession.refreshVisual(); this.observeLearning()
  }
  /** 菜单两课才观察控件语义；其他课及关闭后只保留原有GUI尺寸采集。 */
  private syncGuideObservation(): void {
    this.touchSession.setGuideActive(this.observationEnabled!==false && this.tutorialOpen && !this.editing && !this.guiHint &&
      !this.imeOpen && !this.fieldImeOpen && !hasEntryTouchModal() &&
      (this.guideStep===TouchGuideStep.Menu || this.guideStep===TouchGuideStep.Scroll))
  }
  /** 指向真实可见控件；缺少控件时返回空矩形，绝不再创建一个假的练习控件。 */
  private guideTarget(): TouchControlRect {
    const items: ControlItem[]=this.displayedControls().filter((item: ControlItem): boolean => this.isControlVisible(item))
    let item: ControlItem | undefined=undefined
    if((this.guideStep<TouchGuideStep.Menu && !this.isGrabbed) ||
      (this.guideStep===TouchGuideStep.Menu && this.isGrabbed) || (this.guideStep===TouchGuideStep.Mouse && this.isGrabbed)) {
      item=items.find((candidate: ControlItem): boolean => effectiveKeys(candidate).indexOf(256)>=0)
    } else if(this.guideStep===TouchGuideStep.Move) item=items.find((candidate: ControlItem): boolean => candidate.type===ControlType.JOYSTICK)
    else if(this.guideStep===TouchGuideStep.Hotbar) item=items.find((candidate: ControlItem): boolean => candidate.type===ControlType.HOTBAR_SELECTOR)
    else if(this.guideStep===TouchGuideStep.Mouse && !this.mouseOpen) item=items.find((candidate: ControlItem): boolean => candidate.systemAction==='mouse')
    const entry: RuntimeTouchEntry | undefined = item === undefined ? undefined : this.runtimeLayout.find(item.id)
    const rect: TouchControlRect = new TouchControlRect()
    if (entry !== undefined) {
      rect.x=entry.rectVp.x; rect.y=entry.rectVp.y; rect.width=entry.rectVp.width; rect.height=entry.rectVp.height
    }
    if(item!==undefined && this.guideStep===TouchGuideStep.Hotbar && this.isGrabbed) { rect.width/=9; rect.x+=rect.width*4 }
    if(this.guideStep===TouchGuideStep.Mouse && this.mouseOpen) {
      const frame: FloatingMouseFrame=this.mouseFrame(); rect.x=frame.x; rect.y=frame.y; rect.width=frame.width; rect.height=frame.height
    } else if(!this.isGrabbed && this.guideStep===TouchGuideStep.Menu) {
      return projectGameNavigation(this.guiState,this.compWidth,this.compHeight)
    } else if(!this.isGrabbed && this.guideStep===TouchGuideStep.Scroll) {
      rect.x=this.compWidth*.12; rect.y=80; rect.width=this.compWidth*.76; rect.height=Math.max(60,this.compHeight-112)
    }
    return rect
  }
  /** 同一纯几何用于绘制和Native排除区，手机/转屏不能留下旧的工具栏命中范围。 */
  private guideLayout(): TouchGuideLayout {
    return touchGuideLayout(this.compWidth,this.compHeight,this.guideStep,this.isGrabbed,this.guideTarget())
  }
  private guideToolbarX(): number { return this.guideLayout().toolbar.x }
  /**
   * 教学可操作区域独立于用户控件schema。几何与绘制统一按vp转surface px，隐藏时发布空矩形。
   * 只有Native接受后缓存，失败保留可重试；已有触点角色、按键owner和菜单拖动均不改变。
   */
  private syncGuideBounds(): void {
    const visible: boolean=this.mounted && this.pageActive && this.tutorialOpen && !this.editing && !this.guiHint &&
      !this.imeOpen && !this.fieldImeOpen && !hasEntryTouchModal() &&
      this.compWidth>16 && this.compHeight>64 && this.density>0
    const toolbar: TouchControlRect | undefined=visible ? this.guideLayout().toolbar : undefined
    const x: number=(toolbar?.x ?? 0)*this.density
    const y: number=(toolbar?.y ?? 0)*this.density
    const width: number=(toolbar?.width ?? 0)*this.density
    const height: number=(toolbar?.height ?? 0)*this.density
    const key: string=[this.runtimeLayout.context.key,this.uiPublicationToken,x,y,width,height].join(',')
    if(key===this.guideBoundsKey) return
    try {
      if(testNapi.setTouchGuideBounds(x,y,width,height,this.uiPublicationToken)) this.guideBoundsKey=key
    } catch (_) { this.guideBoundsKey='' }
  }
  /** Child的保存已经得到Store确认，再核对真实控件内容；取消不算教学完成。 */

  /**
   * 入口的产品显隐资格取自实际控件定义，遵循场景、用户覆盖和全局三档，不用固定ID判断。
   * desired用于用户刚隐藏/换布局时立即退休旧面板；不以候选是否尚未完成发布判断生命周期。
   */
  private mouseEntryVisible_(profile: LayoutProfile): boolean {
    // 合法导入允许抽屉内的BUTTON承担系统动作；与运行时投影一致，先核父项可见并确认已展开，
    // 再检查孩子。子项force_show只能覆盖自己的场景/全局档，不能穿过隐藏或收起的父抽屉。
    for(const item of profile.controls) {
      if(!runtimeTouchControlVisible(item,this.isGrabbed,this.globalVisMode)) continue
      if (this.groupSchema !== undefined && profile.profileId === this.profile.profileId && !this.touchGroupVisible_(item.id)) continue
      if(item.systemAction==='mouse') return true
      if(item.type!==ControlType.DRAWER || !(this.drawerOpen.get(item.id) ?? false)) continue
      for(const child of item.children ?? []) {
        if(child.type===ControlType.BUTTON && child.systemAction==='mouse' &&
          runtimeTouchControlVisible(child,this.isGrabbed,this.globalVisMode)) return true
      }
    }
    return false
  }
  /** 只读实际呈现entries，包含展开抽屉的孩子；roots controls不含孩子，不能替代完整呈现集合。 */
  private mouseEntryPresented_(): boolean {
    return this.runtimeLayout.entries.some((entry: RuntimeTouchEntry): boolean => entry.item.systemAction==='mouse' &&
      (this.groupSchema === undefined || this.touchGroupVisible_(entry.item.id)) && runtimeTouchControlVisible(entry.item,this.isGrabbed,this.globalVisMode))
  }
  /** 新打开必须来自本次真实呈现；旧提示回调不能借当前token或后来布局重新打开已隐藏的面板。 */
  private canOpenMouse_(token: string): boolean {
    return token===this.uiPublicationToken && this.admitTouchAction_(token) &&
      this.mouseEntryVisible_(this.desiredProfile) && this.mouseEntryPresented_()
  }
  /**
   * 绘制和Native范围共用只读资格。发布等待不参与此处active判断，只在sync中单独关闭新DOWN。
   * 隐藏/失焦/IME/编辑/模态会停用本面板，不把工具owner取消扩大为其它触控或实体输入复位。
   */
  private mousePanelVisible_(): boolean {
    return this.mouseOpen && this.mouseEntryVisible_(this.desiredProfile) && this.mouseEntryPresented_() &&
      !this.isGrabbed && this.pageActive && !this.imeOpen && !this.fieldImeOpen && !this.editing &&
      this.runtimeLayout.context.valid && !hasEntryTouchModal()
  }
  /**
   * 用户隐藏意图先于发布等待生效，避免原鼠标contact反过来阻止隐藏候选归零安装。
   * 仅在真正采纳新呈现集合时检查缺项，不能拿尚未安装的pending/空候选误退休已有接触。
   * 关闭不递归请求schema；当前调用方继续同一次发布，失败取消由原心跳configure继续重试。
   */
  private retireHiddenMouse_(checkPresented: boolean=false): void {
    if(this.mouseOpen && (!this.mouseEntryVisible_(this.desiredProfile) ||
      (checkPresented && !this.mouseEntryPresented_()))) this.closeMouse(false)
  }
  private openMouse(token: string=this.uiPublicationToken, memberId: string = ''): void {
    if(!this.canOpenMouse_(token)) return
    if(this.isGrabbed) {
      // 工具入口不改变游戏状态；菜单鼠标只在真实未grab时输出，不能隐式发Esc或攻击。
      this.getUIContext().getPromptAction().showToast({message:'打开背包或菜单后，可使用虚拟鼠标精确操作'})
      return
    }
    if (this.groupSchema !== undefined) {
      const entry: RuntimeTouchEntry | undefined=this.runtimeLayout.entries.find((value: RuntimeTouchEntry): boolean =>
        value.item.systemAction === 'mouse' && (memberId.length === 0 || value.item.id === memberId) && this.touchGroupVisible_(value.item.id))
      if (entry === undefined || !testNapi.bindTouchGroupMouseOwner(token,entry.item.id,this.touchControlGroupEpoch_(entry.item.id))) return
    }
    this.mouseOpen=true
    this.mouseController.configure(this.pageActive,this.density)
    this.syncMouseBounds()
    this.registerRegions()
  }
  /** 先收起视觉再退休本工具；保留失败回执及心跳重试，rebuild=false用于发布入口避免递归。 */
  private closeMouse(rebuild: boolean=true): void {
    this.mouseOpen=false
    this.mouseController.release()
    if(rebuild) this.registerRegions()
  }
  /** 只读已同步的State投影；build不推进模型，避免重复求值造成摆位或触点生命周期副作用。 */
  private mouseFrame(): FloatingMouseFrame {
    return this.mouseGeometry
  }
  private syncMouseBounds(): void {
    this.mouseController.setRuntimeContext(this.runtimeLayout.context, this.uiPublicationToken)
    // 生命周期关闭需要取消旧工具事务；publication的等待门只拒绝新DOWN/锁存意图。
    // 手仍未抬起时必须保留既有contact的MOVE/UP，不能以configure(false)代替候选等待。
    const active: boolean=this.mousePanelVisible_()
    this.mouseController.configure(active,this.density,this.touchSurface.admits(this.uiPublicationToken))
    if(!active) { this.mouseController.bounds(0,0,0,0); return }
    // 真实触点回调会进入这里；即使指针已碰边、端口拒收或Native反馈尚未改变，原始随指仍能更新本体。
    // 模型内部仅接受当前触点驱动几何；被拒DOWN、迟到MOVE与取消失败都不能借UI刷新复活旧接触。
    const frame: FloatingMouseFrame=this.mouseController.model.frame(this.menuGeometryX/Math.max(1,this.density),
      this.menuGeometryY/Math.max(1,this.density),this.compWidth,this.compHeight)
    const current: FloatingMouseFrame=this.mouseGeometry
    if(current.x!==frame.x || current.y!==frame.y || current.width!==frame.width ||
      current.height!==frame.height || current.compact!==frame.compact) this.mouseGeometry=frame
    this.mouseController.bounds(frame.x,frame.y,frame.width,frame.height)
  }
  private hintWidth(): number { return Math.min(400,Math.max(160,this.compWidth-24)) }
  private restoreGui(): void {
    if(this.restorePending>0) return
    try {
      // 恢复请求跟随本控件原GUI来源租约；旧页面不能借当前全局会话修改新资源。
      this.restorePending=this.touchSession.restoreGui(this.guiGuard.target,this.guiState.revision)
      this.guiMessage=this.restorePending>0 ? '正在恢复…' : '当前状态无法即时恢复，可用精细鼠标调整'
    } catch (error) { this.guiMessage='恢复请求失败：'+String(error) }
  }
  /** 面板整块区域阻止Native触点穿透，子控件自己在ArkUI中处理；ID按本次实际列表去重。 */
  private addUiBlock(controls: ControlSchemaEntry[],name: string,x: number,y: number,w: number,h: number,_scale: number,
    layout: RuntimeTouchLayout, role: string): void {
    let suffix: number=0
    while(controls.some((entry: ControlSchemaEntry): boolean => entry.id===name+suffix.toString())) suffix++
    const vp: TouchControlRect=new TouchControlRect();vp.x=x;vp.y=y;vp.width=w;vp.height=h
    const overlay: RuntimeTouchOverlay=appendRuntimeTouchOverlay(layout,name+suffix.toString(),role,vp)
    const rect: TouchControlRect=overlay.rectPx
    controls.push({id:overlay.id,kind:0,handledBy:1,x:rect.x,y:rect.y,w:rect.width,h:rect.height,
      hitSlop:0,keyOrMouse:0,keys:[],trigger:0,dragLook:false,haptic:false,swipeGroup:0})
  }

  /** 多摇杆方案只移动实际被native认领的那个控件，索引按同一可见schema顺序解释。 */
  private usesNativeJoystick(item: ControlItem): boolean {
    if (!this.cOwnsJoystick() || this.touchVisual.joystickIndex < 0) return false
    const controls: ControlItem[] = this.displayedControls().filter((control: ControlItem): boolean => this.isControlVisible(control))
    return controls.findIndex((control: ControlItem): boolean => control.id === item.id) === this.touchVisual.joystickIndex
  }
  @Prop @Watch('onGrabChanged') isGrabbed: boolean = false
  @Prop @Watch('onPageActiveChanged') pageActive: boolean = true
  /** 编辑覆盖层只发布准入事实；页面runtime统一停止其它输入端和capture。 */
  onInputPause: (paused: boolean) => void = (_paused: boolean): void => {}
  @Prop @Watch('onSurfaceContextChanged') surfaceContextGeneration: number = 0

  // 布局数据
  @State profile: LayoutProfile = getDefaultLayout()
  @State profileVer: number = 0

  // 编辑模式
  @State editing: boolean = false
  /** 同一模态下先选择任务，再挂载唯一编辑器；两个界面不共享未保存草稿。 */
  @State private editorMode: string = 'choose'
  @State private editorChoiceBusy: boolean = false
  /** 读取草稿和取得输入暂停期间也独占请求，避免连续点击并发打开编辑覆盖层。 */
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
   * native 已归零后的**纯缓存丢弃**：不发任何 GLFW 边沿，不改变用户配置和界面的开启状态。
   * 按下/锁定提示属于租约投影，必须同时清空，不能在Native已放开后继续显示“按住”。
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
    this.controlClient.dropAfterNativeReset()
    // 注册表的本次复位负责退休TouchControls租约；这里只清模型和UI，不重复补UP。
    this.mouseController.model.acknowledgeReset()
    this.mouseResetRevision++
    // 方向键：只从"按下集合"里摘掉，不发 RELEASE；摇杆手指随之作废，待补发的锁存方向也一并取消。
    this.activeKeys.clear()
    this.cancelDirectionLatch()
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
  private controlClient: SourceControlClient = createEntrySourceControlClient(TOUCH_SOURCE,(): string => this.uiPublicationToken,
    undefined,(control: string): ControlGroupWitness | undefined => {
      if (this.groupSchema === undefined) return undefined
      const colon: number = control.indexOf(':')
      const id: string = colon < 0 ? control : control.substring(colon + 1)
      return { memberId:id,eligibility:this.touchControlGroupEpoch_(id) }
    })
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
  // 被 30ms 锁存暂压、但摇杆仍想按下的方向键。手指停住不动时不会再有新采样，锁存到期必须
  // 由唯一的补发定时器替它按下；任何 want=false 采样、松开摇杆或复位都会把它清掉。
  private pendingLatchedDirections: Set<number> = new Set<number>()
  private directionLatchTimer: number = -1
  private directionLatchDueAt: number = 0

  // 组件尺寸 + density
  @State compWidth: number = 0
  @State compHeight: number = 0
  private density: number = 0
  private mounted: boolean = false
  private appearanceGeneration: number = 0
  private feedbackLease: EntryControlFeedbackLease | undefined = undefined
  /** 外部已确认配置更新不覆盖正在编辑的草稿；编辑完成已有显式回读。 */
  private configurationListener: InputConfigurationListener =
    (profile: LayoutProfile, _revision: number): boolean => {
      if (!this.mounted || this.editing || this.editorOpening) return false
      this.desiredProfile = cloneLayout(profile)
      return this.registerRegions()
    }

  /**
   * 原挂接完成后订阅读only会话报告。回调只缓存原文字/值与展示分类，不应用配置、不调用 Native。
   * 仓库 registration 在订阅时冻结，appearance 同时防止同一组件重开后的迟到投影。
   */
  private subscribeConfigurationStatus_(store: LayoutStore): void {
    this.retireConfigurationStatus_()
    // 没有本局 provider 是能力缺席，不能沿用上一 appearance 的“已生效”文字。
    this.configurationStatusMessage = ''
    this.configurationStatusSnapshot = undefined
    if (this.configurationStatusEditorPauseWait) this.configurationStatusEditorPauseWait = false
    const appearance: number = this.appearanceGeneration
    this.configurationStatusStore = store
    this.configurationStatusSubscription = store.addInputPolicyStatusListener((snapshot: InputPolicyActivationSnapshot): void => {
      if (!this.mounted || this.appearanceGeneration !== appearance) return
      this.configurationStatusMessage = inputPolicyStatusMessage(snapshot)
      this.configurationStatusSnapshot = snapshot
      // 分类只沿这条已有通知计算，不在build/按帧读取快照。此处不依赖editing：
      // openEditor的暂停回调可先同步发出报告，随后editing=true仍必须使用这次正确分类。
      let expected: boolean = snapshot.identityStage === 'Bound' && snapshot.activationState === 'Pending' &&
        snapshot.domains.length > 0
      let touchPaused: boolean = false
      if (expected) {
        for (const state of snapshot.domains) {
          if (state.stage === 'Rejected' || state.terminalRejection || state.capabilityIssue.length > 0) {
            expected = false; break
          }
          if (!state.pending && state.stage === 'Applied') continue
          if (!state.pending || state.stage !== 'Waiting') { expected = false; break }
          if (state.name === 'touch-controls' && state.reason === 'FrontendInactive') {
            touchPaused = true
            continue
          }
          if (state.name === 'touch-gyro' && (state.reason === 'SourceInactive' || state.reason === 'InputNotAdmitted')) continue
          expected = false; break
        }
      }
      const editorPauseWait: boolean = expected && touchPaused
      if (this.configurationStatusEditorPauseWait !== editorPauseWait) {
        this.configurationStatusEditorPauseWait = editorPauseWait
      }
    })
  }

  /**
   * 编辑器主动暂停触控时，原报告仍如实保留FrontendInactive；这不是一次保存失败。
   * 这里只决定HUD文字是否需要呈现，不改保存事实、域状态或准入，也不发起任何重试。
   *
   * 必须同时持有本编辑器的暂停与模态，并在原Bound快照中确实看到触控域前端失活，
   * 才能把该等待归因于编辑暂停。其它域只容忍已生效，或随触控暂停产生的陀螺仪
   * SourceInactive/InputNotAdmitted；任意拒绝、能力问题、未知原因及端口不可用均保留整条报告。
   * ContactsEnding/NativeInstall/UiConfirmation/PreviousPublication是实际发布过程，不能一并隐藏。
   * failures包含消费者正常返回false的累计次数，不具备错误分类语义，因此不读取它。
   * 原快照分类只在已有报告通知中缓存为轻量布尔；渲染路径不观察/遍历新的快照对象。
   */
  private configurationHudMessage_(): string {
    const message: string = this.configurationStatusMessage
    if (!this.editing || !this.editorInputPaused || this.editorModal === undefined) return message
    return this.configurationStatusEditorPauseWait ? '' : message
  }

  /** 先撤本前端观察引用再按原仓库退订；清理不借 getLayoutStore 的后来实例/运行代。 */
  private retireConfigurationStatus_(): void {
    const subscription: InputPolicyStatusSubscription | undefined = this.configurationStatusSubscription
    const store: LayoutStore | undefined = this.configurationStatusStore
    this.configurationStatusSubscription = undefined; this.configurationStatusStore = undefined
    if (subscription !== undefined && store !== undefined) store.removeInputPolicyStatusListener(subscription)
  }

  /** 每次真实挂接取得新协调器身份；同一组件再出现时旧dispose不能永久关闭新页面。 */
  private createTouchSurface_(): TouchSurfaceController {
    return new TouchSurfaceController(
      (candidate: TouchSurfaceCandidate, token: string): void => { this.presentTouchCandidate_(candidate, token) },
      (): number => this.arktsTouchContactCount_(),
      (message: string): void => {
        if (this.mounted) this.touchStatusMessage = message
        hilog.warn(0x0000,GAME_CONTROLS_TAG,'%{public}s',message)
      }, (revision: string): void => { this.syncTouchGroups_(revision) })
  }

  /** 当前成员的组索引来自已安装候选；抽屉子项继承父组。 */
  private touchControlGroupIndex_(id: string): number {
    if (this.groupSchema === undefined) return -1
    return this.groupIndices.get(id) ?? -1
  }

  private touchControlGroupEpoch_(id: string): string {
    const group: number = this.touchControlGroupIndex_(id)
    return group < 0 ? '1' : (this.groupEpochs[group] ?? '0')
  }

  private touchGroupVisible_(id: string): boolean {
    const group: number = this.touchControlGroupIndex_(id)
    return group < 0 || (this.groupMask[group] ?? false)
  }

  /** 注册身份绑定本次 appearance；关闭可选高亮/触觉不影响此必要状态通道。 */
  private ensureTouchGroupListener_(): void {
    if (!this.mounted || this.groupSchema === undefined || this.groupRegistration.length > 0 ||
      Date.now() < this.nextGroupListenerAttempt || typeof testNapi.onTouchGroupsChanged !== 'function' ||
      !this.touchSession.hasCurrentSource()) return
    const appearance: number = this.appearanceGeneration
    const session: EntryTouchSession = this.touchSession
    this.nextGroupListenerAttempt=Date.now()+1000
    try {
      this.groupRegistration = testNapi.onTouchGroupsChanged((): void => {
        if (this.mounted && appearance === this.appearanceGeneration && this.touchSession === session && session.hasCurrentSource())
          this.syncTouchGroups_()
      })
    } catch (_) { /* 原 reconcile 在活跃时重试登记和取回完整回执。 */ }
  }

  /** 只在修订改变、静态呈现或在途恢复时取完整 mask；保持现有维护频率，不增加定时器。 */
  private syncTouchGroups_(hint?: string): void {
    if (!this.mounted || this.groupSchema === undefined || this.uiPublicationToken.length === 0 ||
      typeof testNapi.readTouchGroups !== 'function') return
    this.ensureTouchGroupListener_()
    if (hint !== undefined && hint === this.groupRevision && this.groupToken === this.uiPublicationToken && !this.groupPending) return
    try {
      const value: TouchGroupReceipt = testNapi.readTouchGroups(this.uiPublicationToken)
      if (!value.enabled || value.token !== this.uiPublicationToken || value.mask.length !== this.groupSchema.groups.length ||
        value.epochs.length !== value.mask.length) return
      const previous: boolean[] = this.groupMask
      this.groupToken=value.token; this.groupEpochs=value.epochs.slice(); this.groupPending=value.pending
      if (value.revision !== this.groupRevision || previous.length !== value.mask.length) {
        this.groupPresentedRevision=''
        this.groupMask=value.mask.slice(); this.groupRevision=value.revision
        for (const entry of this.runtimeLayout.entries) {
          const group: number = this.touchControlGroupIndex_(entry.item.id)
          if (group >= 0 && !value.mask[group]) this.releaseControlInputs(entry.item.id)
        }
        this.retireHiddenMouse_()
      }
      // 已有一次真实 didLayout 证明该修订完成，但 ACK 暂拒/丢失时可沿原维护重试。
      // 未经过布局确认的新修订不进入此分支，也不靠固定下一帧猜测成功。
      if (this.groupPending && this.groupPresentedRevision === value.revision && this.touchSurface.admits(value.token)) {
        if (testNapi.confirmTouchGroups(value.token,value.revision)) this.groupPending=false
      }
    } catch (_) { /* 结果未知保留原 token/revision 和门控，原维护继续查询。 */ }
  }

  private touchGroupMarkerId_(): string { return this.touchMarkerId_() + '-groups-' + this.groupRevision }

  /** 组命令失败不临时创建未登记的可点击覆盖层；用既有Toast通道提示并去重离散日志。 */
  private reportGroupIssue_(message: string): void {
    if (message === this.lastGroupIssue) return
    this.lastGroupIssue=message
    hilog.warn(0x0000,GAME_CONTROLS_TAG,'%{public}s',message)
    try { this.getUIContext().getPromptAction().showToast({message:message}) } catch (_) {}
  }

  /** 首次发送与结果未知后的查询使用同一份完整参数；Native 先查幂等记录。 */
  private dispatchGroupIntent_(intent: TouchGroupCommandIntent): void {
    try {
      const receipt: TouchGroupCommandReceipt=testNapi.invokeTouchGroupControl(intent.token,intent.control,intent.eligibility,
        intent.producer,intent.sequence,intent.phase)
      if (receipt === undefined) return
      this.pendingGroupCommands.delete(intent.sequence)
      if (receipt.status === 'rejected' || receipt.status === 'stale' || receipt.status === 'expired')
        this.reportGroupIssue_('组动作未被接受或已过期，未重复执行；可在布局稳定后重新操作')
    } catch (_) { this.reportGroupIssue_('组动作结果待确认，正在查询原操作') }
  }

  /** 复用已有维护，每次至多查询四项；空队列零调用，换代直接结束旧 UI 查询义务。 */
  private reconcileGroupIntents_(): void {
    let budget: number=4
    this.pendingGroupCommands.forEach((intent: TouchGroupCommandIntent, sequence: string): void => {
      if (budget-- <= 0) return
      if (intent.token !== this.uiPublicationToken || intent.producer !== this.groupRegistration) {
        this.pendingGroupCommands.delete(sequence); return
      }
      this.dispatchGroupIntent_(intent)
    })
  }

  /** 新 marker 与全部成员节点由实际 didLayout 验证后，才确认当前组态；旧回调不能开新门。 */
  private confirmTouchGroupLayout_(): void {
    if (!this.groupPending || this.groupToken !== this.uiPublicationToken || !this.touchSurface.admits(this.groupToken)) return
    const token: string = this.groupToken, revision: string = this.groupRevision
    try {
      const utils = this.getUIContext().getComponentUtils()
      const marker: componentUtils.ComponentInfo = utils.getRectangleById(this.touchGroupMarkerId_())
      if (marker.size.width <= 0 || marker.size.height <= 0) return
      for (const entry of this.runtimeLayout.entries) {
        const actual: componentUtils.ComponentInfo = utils.getRectangleById(this.touchNodeId_(entry.item.id))
        if (Math.abs(actual.size.width-entry.rectPx.width)>1 || Math.abs(actual.size.height-entry.rectPx.height)>1 ||
          Math.abs(actual.localOffset.x-entry.rectPx.x)>1 || Math.abs(actual.localOffset.y-entry.rectPx.y)>1) return
      }
      this.groupPresentedRevision=revision
      if (testNapi.confirmTouchGroups(token,revision)) this.syncTouchGroups_()
    } catch (_) { /* 失败保留在途事实，下一次真实布局完成或恢复后继续。 */ }
  }

  /** SDK观察注册瞬时失败也可由同一活跃心跳恢复；每秒至多一次，注销只针对自己的callback。 */
  private ensureTouchLayoutObserver_(): void {
    if (!this.mounted || !this.pageActive || this.layoutObserverRegistered || Date.now()<this.nextLayoutObserverAttempt) return
    this.nextLayoutObserverAttempt=Date.now()+1000
    try {
      const observer=this.getUIContext().getUIObserver()
      observer.off('didLayout',this.didTouchLayout)
      observer.on('didLayout',this.didTouchLayout)
      this.layoutObserverRegistered=true
      this.profileVer++
    } catch (_) { this.touchStatusMessage='触控布局确认暂不可用，等待页面恢复' }
  }

  /**
   * 非分配的纯boolean读取：Native注册可同步回入改变原观察字段，不能让控制流分析
   * 把注册前的true固化到返回后。每次只读同一原字段，不造闭包/数组/对象或调用Native；
   * 仅明确true允许观察，未初始化/未知值拒绝，不能借helper给fixture假放行。
   */
  private touchFeedbackObservationEnabled_(): boolean { return this.observationEnabled===true }

  /**
   * 反馈恢复仍用原broker；观察关闭期间原heartbeat不能自动复订阅。闭包合取原
   * appearance、Session、观察代及实际反馈lease，off/on之后旧TSFN不能写高亮或震动。
   */
  private ensureTouchFeedback_(): void {
    // 反馈属于捕获的原Session；Source退休后即使组件仍mounted也不得登记/接受旧反馈。
    const session: EntryTouchSession=this.touchSession
    if (!this.touchFeedbackObservationEnabled_() || !this.mounted || !this.pageActive || !this.schemaActive ||
      this.feedbackLease!==undefined || Date.now()<this.nextFeedbackAttempt || !session.hasCurrentSource()) return
    this.nextFeedbackAttempt=Date.now()+1000
    const appearance: number=this.appearanceGeneration
    const generation: number=this.observationGeneration
    let lease: EntryControlFeedbackLease | undefined=undefined
    const accepts: () => boolean=(): boolean => this.mounted && this.touchFeedbackObservationEnabled_() &&
      appearance===this.appearanceGeneration && generation===this.observationGeneration && this.touchSession===session &&
      lease!==undefined && this.feedbackLease===lease && session.hasCurrentSource()
    lease=acquireEntryControlFeedback((id: string,pressed: boolean): void => {
      if (!accepts()) return
      this.getBtnVis(id).pressed=pressed; this.btnPressedVer++
    },(strength: number): void => {
      if (!accepts() || !this.pageActive) return
      hapticTap(strength)
    },(id: string): boolean => accepts() && this.pageActive && !this.editing && !this.imeOpen && !this.fieldImeOpen &&
      this.runtimeLayout.find(id)!==undefined)
    // Native注册期间也可能停原Source；失权返回lease沿原broker归还，不安装到后来观察代。
    if (!this.mounted || !this.touchFeedbackObservationEnabled_() || appearance!==this.appearanceGeneration ||
      generation!==this.observationGeneration || session!==this.touchSession || !session.hasCurrentSource()) {
      if (lease!==undefined) releaseEntryControlFeedback(lease)
      return
    }
    this.feedbackLease=lease
    if (lease===undefined && !this.feedbackRegistrationWarned) {
      this.feedbackRegistrationWarned=true
      hilog.warn(0x0000,GAME_CONTROLS_TAG,'Native feedback unavailable; retry on active heartbeat')
    } else if (lease!==undefined) this.feedbackRegistrationWarned=false
  }

  /** 订阅仅捕获本组件原资源；恢复第一次当前快照只重设教学基线，不补旧进度/输入。 */
  private subscribeTouchObservation_(): void {
    const appearance: number=this.appearanceGeneration
    const generation: number=this.observationGeneration
    const session: EntryTouchSession=this.touchSession
    let baseline: boolean=true
    session.subscribeVisual((state: EntryTouchVisual): void => {
      if (!this.mounted || this.observationEnabled===false || appearance!==this.appearanceGeneration ||
        generation!==this.observationGeneration || session!==this.touchSession || !session.hasCurrentSource()) return
      this.touchVisual=state
      if (baseline) {
        baseline=false; this.touchGuide.baseline(state.guide)
      }
      // 原教学只在当前原Source提供真实guide快照时恢复；桥暂缺时保留等待，不把
      // 观察关闭期间的旧增量追认为成果，也不写markSeen/markClosed等用户持久偏好。
      if (this.observationResumeTeaching && state.guide.available) {
        this.observationResumeTeaching=false; this.touchGuide.baseline(state.guide)
        this.tutorialOpen=true; this.syncGuideObservation()
      }
      this.syncGuideBounds(); this.maybeOpenLearning(); this.observeLearning()
    })
  }

  /**
   * 只操作原显示观察；不动Source、pageActive、schema、准入、按键记录和持久偏好。
   * 先撤观察代再外部注销，释放失败也围住旧闭包。on只接当前快照及未来反馈边沿，
   * broker没有当前按下基线接口，故清旧高亮并明确UnknownUntilNextEdge，不补造PRESS。
   */
  private operateTouchObservation_(action: string): EntryInputObservationResult {
    if (action!=='read' && (action==='on')!==this.observationEnabled) {
      if (this.observationGeneration>=Number.MAX_SAFE_INTEGER) return this.touchObservationResult_('IdentityExhausted')
      this.observationGeneration++; this.observationEnabled=action==='on'
      if (!this.observationEnabled) {
        this.touchSession.unsubscribeVisual()
        this.observationResumeTeaching=this.tutorialOpen
        this.tutorialOpen=false; this.guideScrollRequested=false; this.syncGuideObservation(); this.syncGuideBounds()
        const lease: EntryControlFeedbackLease | undefined=this.feedbackLease
        this.feedbackLease=undefined
        try { this.feedbackClearComplete=lease===undefined || releaseEntryControlFeedback(lease) }
        catch (_) { this.feedbackClearComplete=false }
        this.btnVisMap.forEach((state: BtnVisState): void => { state.pressed=false }); this.btnPressedVer++
        this.touchVisual=new EntryTouchVisual()
      } else {
        this.subscribeTouchObservation_(); this.nextFeedbackAttempt=0; this.ensureTouchFeedback_()
        // 受控Want只恢复订阅。当前快照由下一次原16ms时钟投递，不直接GUI/JNI读取或额外tick。
      }
    }
    return this.touchObservationResult_(this.observationEnabled ? 'Observing' :
      (this.feedbackClearComplete ? 'ObserversRetired' : 'ObserversRetiredNativeClearUnknown'))
  }

  /** 读取原计数与资格，不推进publication/Native维护或构造新输入；字段用于固定沙箱回读。 */
  private touchObservationResult_(outcome: string): EntryInputObservationResult {
    const source: EntryTouchObservationSnapshot=this.touchSession.observationSnapshot()
    const result: EntryInputObservationResult=new EntryInputObservationResult()
    result.outcome=outcome; result.appearance=this.appearanceGeneration; result.enabled=this.observationEnabled
    result.activity=this.observationRegistration?.activity ?? 0
    result.feedbackLease=this.feedbackLease?.id ?? 0; result.feedbackClearComplete=this.feedbackClearComplete
    result.visualSubscribed=source.visualSubscribed; result.guiSubscribed=source.guiSubscribed
    result.geometrySubscribed=source.geometrySubscribed; result.sourceCurrent=source.sourceCurrent
    result.timerActive=source.timerActive; result.guiReads=source.guiReads
    result.geometryDeliveries=source.geometryDeliveries; result.visualDeliveries=source.visualDeliveries
    result.gyroStatus=source.gyroStatus; result.pageActive=this.pageActive; result.schemaActive=this.schemaActive
    result.publicationToken=this.uiPublicationToken
    return result
  }

  /** Native安装后才请求同一候选呈现；这里只改变UI快照，didLayout确认以前所有新意图仍受fence。 */
  private presentTouchCandidate_(candidate: TouchSurfaceCandidate, token: string): void {
    if (this.groupSchema !== undefined) {
      this.groupBlockedUiFingers.forEach((id: number): void => { this.blockedUiFingers.delete(id) })
      this.groupBlockedUiFingers.clear()
    }
    if (!this.mounted) return
    this.profile = candidate.profile
    this.runtimeLayout = candidate.layout
    this.presentedCandidateId = candidate.id
    this.density = this.runtimeLayout.context.density
    this.uiPublicationToken = token
    const groupMetadata: TouchGroupSchema | undefined = candidate.schema.groupSchema
    // 空组扩展只携旧方案的编辑身份，界面和按钮仍沿原v3路由，不登记组显示/命中控制。
    this.groupSchema = groupMetadata !== undefined && groupMetadata.groups.length > 0 ? groupMetadata : undefined
    this.groupRanks = new Map<string, number>()
    this.groupIndices = new Map<string, number>()
    this.groupControls = []
    if (this.groupSchema !== undefined) {
      const controls: ControlSchemaEntry[] = candidate.schema.controls
      for (let index: number = 0; index < controls.length; index++) {
        this.groupRanks.set(controls[index].id,this.groupSchema.controls[index].rank)
        this.groupIndices.set(controls[index].id,this.groupSchema.controls[index].group)
      }
      this.groupControls=this.runtimeLayout.entries.map((entry: RuntimeTouchEntry): ControlItem => entry.item)
      this.groupToken=''; this.groupRevision=''; this.groupMask=[]; this.groupEpochs=[]; this.groupPresentedRevision=''
      this.syncTouchGroups_()
    } else { this.groupToken=''; this.groupRevision=''; this.groupMask=[]; this.groupEpochs=[]; this.groupPending=false }
    this.profileVer++
    const issue: string = layoutCapabilityIssue(candidate.profile)
    // 正常发布的等待态只由协调器持有，不在每次显隐/grab翻转时创建可见提示框。
    // 能力不支持和真实失败仍按原错误路径显示；清空文字不提前解除Native/UI确认屏障。
    this.touchStatusMessage = issue
    this.touchSession.setRuntimeContext(this.runtimeLayout.context)
    this.retireHiddenMouse_(true)
    this.syncMouseBounds(); this.syncGuideBounds()
  }

  /** 稳定节点仅捕获ID；deleted节点的迟到回调得到隐藏空绑定，不能借用其它控件的新身份。 */
  private currentTouchItem_(id: string): ControlItem {
    const entry: RuntimeTouchEntry | undefined = this.runtimeLayout.find(id)
    if (entry !== undefined) return entry.item
    return { id:id,label:'',type:ControlType.BUTTON,keyOrMouse:0,keys:[],xPct:0,yPct:0,
      baseWidth:1,baseHeight:1,itemScale:1,isCircle:false,hidden:true,alignGroup:AlignGroup.NONE,alignIndex:0,grabbedOnly:false }
  }

  private drawerTouchIds_(parentId: string): string[] {
    return this.runtimeLayout.entries.filter((entry: RuntimeTouchEntry): boolean => entry.parentId === parentId)
      .map((entry: RuntimeTouchEntry): string => entry.item.id)
  }

  /** 同一页面节点ID不随布局revision改变；publication marker单独证明新候选已进入布局树。 */
  private touchNodeId_(id: string): string { return 'touch-surface-' + this.appearanceGeneration.toString() + ':' + id }
  private touchMarkerId_(): string { return this.touchNodeId_('publication-' + this.uiPublicationToken) }

  /** UI提示的真实矩形仍取已安装候选，不在绘制侧再夹一遍或引用默认display。 */
  private touchOverlay_(role: string): RuntimeTouchOverlay {
    return this.runtimeLayout.overlays.find((overlay: RuntimeTouchOverlay): boolean => overlay.role === role) ?? new RuntimeTouchOverlay()
  }

  /**
   * didLayout不携带token，必须额外核实本候选marker及每个命中节点的实际px矩形。
   * 只验证本触控面的布局完成，不宣称整机屏幕已显示。旧回调、缺节点、动画中几何不符均保持屏障。
   */
  private confirmTouchLayout_(): void {
    if (!this.mounted || !this.pageActive || !this.layoutObserverRegistered) return
    if (this.groupPending) this.confirmTouchGroupLayout_()
    const candidate: TouchSurfaceCandidate | undefined = this.touchSurface.pendingPresentation()
    const token: string = this.touchSurface.presentationToken()
    if (candidate === undefined || candidate.id !== this.presentedCandidateId || token !== this.uiPublicationToken) return
    try {
      const utils = this.getUIContext().getComponentUtils()
      const marker: componentUtils.ComponentInfo = utils.getRectangleById(this.touchMarkerId_())
      if (marker.size.width <= 0 || marker.size.height <= 0) return
      const layout: RuntimeTouchLayout = candidate.layout
      for (const entry of layout.entries) {
        const actual: componentUtils.ComponentInfo = utils.getRectangleById(this.touchNodeId_(entry.item.id))
        const expected: TouchControlRect = entry.rectPx
        if (Math.abs(actual.size.width-expected.width)>1 || Math.abs(actual.size.height-expected.height)>1 ||
          Math.abs(actual.localOffset.x-expected.x)>1 || Math.abs(actual.localOffset.y-expected.y)>1) return
      }
      for (const overlay of layout.overlays) {
        const actual: componentUtils.ComponentInfo = utils.getRectangleById(this.touchNodeId_(overlay.id))
        const expected: TouchControlRect = overlay.rectPx
        if (Math.abs(actual.size.width-expected.width)>1 || Math.abs(actual.size.height-expected.height)>1 ||
          Math.abs(actual.localOffset.x-expected.x)>1 || Math.abs(actual.localOffset.y-expected.y)>1) return
      }
      const completedOperation: string=this.touchSurface.status().operationId
      if (this.touchSurface.confirm(candidate.id,token)) {
        // 只采用此真实确认且仍当前的候选绑定。confirm可同步推进后来desired；旧续体
        // 不能以旧profile或“现在的desired”覆盖它。gyro有独立配置回执，不在此盖Applied。
        if (this.touchSurface.admits(token) && this.touchSurface.status().desiredCandidateId===candidate.id && candidate.schema.touch!==undefined)
          this.touchSession.adoptConfirmedTouchBindings(candidate.profile,candidate.schema.touch,completedOperation,candidate.id,token)
        const unresolved: EntryTouchModalLease | undefined = this.unresolvedSurfaceModal
        this.unresolvedSurfaceModal = undefined
        if (unresolved !== undefined && !releaseEntryTouchModal(unresolved)) this.touchStatusMessage='触控窗口恢复等待Native确认'
        else if (!this.touchSurface.pending()) this.touchStatusMessage=layoutCapabilityIssue(this.profile)
        this.syncMouseBounds(); this.syncGuideBounds()
        this.touchSession.setTouchAdmission(!hasEntryTouchModal() && !this.editing && !this.imeOpen && !this.fieldImeOpen)
      }
    } catch (_) { /* 缺节点或失效UIContext继续保持fence，后续真实didLayout再确认。 */ }
  }

  /** 已有页面心跳负责失败恢复；背景由EntryTouchSession停表，不增加另一条全局计时器。 */
  private reconcileTouchSurface_(): void {
    if (!this.mounted || !this.pageActive) return
    reconcileEntryTouchModals()
    this.ensureTouchLayoutObserver_(); this.ensureTouchFeedback_()
    this.touchSurface.reconcile()
    if (this.groupSchema !== undefined && this.pendingGroupCommands.size > 0) this.reconcileGroupIntents_()
    this.reconcileGroupRestore_()
    this.touchSession.setTouchAdmission(!hasEntryTouchModal() && !this.editing && !this.imeOpen && !this.fieldImeOpen &&
      this.touchSurface.admits(this.uiPublicationToken))
    this.syncMouseBounds(); this.syncGuideBounds()
  }

  /** 恢复请求只重试未知回执；Native明确拒绝/过期后结束，不能每个维护tick永久发送。 */
  private reconcileGroupRestore_(): void {
    if (this.groupRestoreRequested && !this.editing && this.groupRegistration.length > 0 && this.touchSurface.admits(this.uiPublicationToken)) {
      try {
        if (this.groupRestoreSequence.length === 0) {
          if (this.groupCommandSequence >= Number.MAX_SAFE_INTEGER) {
            this.groupRestoreRequested=false; this.reportGroupIssue_('组命令序号已耗尽，请重新进入游戏'); return
          }
          this.groupRestoreSequence=(++this.groupCommandSequence).toString(); this.groupRestoreToken=this.uiPublicationToken
        }
        if (this.groupRestoreToken !== this.uiPublicationToken) {
          this.groupRestoreRequested=false; this.groupRestoreSequence=''; this.reportGroupIssue_('恢复请求所属布局已更换，请重新操作'); return
        }
        const receipt: TouchGroupCommandReceipt=testNapi.restoreTouchGroups(this.groupRestoreToken,this.groupRegistration,this.groupRestoreSequence)
        if (receipt === undefined) return
        this.groupRestoreRequested=false; this.groupRestoreSequence=''
        if (receipt.status === 'rejected' || receipt.status === 'stale' || receipt.status === 'expired')
          this.reportGroupIssue_('恢复初始显隐未被接受或已过期，请在布局稳定后重新操作')
        else this.syncTouchGroups_()
      } catch (_) { /* 继续重试同一序号，不另造 toggle。 */ }
    }
  }

  /**
   * 发布的zero条件必须包含工具鼠标的真实contact；按键锁存owner不是手指，不阻塞等价保留。
   * 工具模型只提供是否非零，故活跃时至少计1，不伪报精确人数；这里的用途仅是判断能否归零安装。
   */
  private arktsTouchContactCount_(): number {
    const fingers: Set<number> = new Set<number>()
    this.buttonFingerIds.forEach((held: Set<number>): void => { held.forEach((id: number): void => { fingers.add(id) }) })
    this.scrollFingerIds.forEach((id: number): void => { fingers.add(id) })
    this.hotbarFingerId.forEach((id: number): void => { fingers.add(id) })
    this.dragLookFinger.forEach((id: number): void => { fingers.add(id) })
    this.blockedUiFingers.forEach((id: number): void => {
      if (this.groupSchema === undefined || !this.groupBlockedUiFingers.has(id)) fingers.add(id)
    })
    if (this.joystickFingerId >= 0) fingers.add(this.joystickFingerId)
    return fingers.size + (this.mouseController.model.activeContacts() ? 1 : 0)
  }

  /** 无TouchEvent的键盘onClick/无障碍/system动作也必须带实际呈现token，Native再次复核。 */
  private admitTouchAction_(token: string, controlId: string = '', groupEpoch: string = ''): boolean {
    if (!this.mounted || !this.pageActive || this.editing || this.imeOpen || this.fieldImeOpen || hasEntryTouchModal() ||
      !this.touchSurface.admits(token)) return false
    try {
      if (!testNapi.isTouchPublicationCurrent(token)) return false
      return this.groupSchema === undefined || controlId.length === 0 ||
        testNapi.isTouchGroupControlCurrent(token,controlId,groupEpoch)
    } catch (_) { return false }
  }

  /** 关门期间DOWN作废到真实UP；已有owner的UP/CANCEL独立放行，MOVE不补造按下。 */
  private admitTouchUi_(event: TouchEvent, token: string, controlId: string = '', groupEpoch: string = ''): boolean {
    // 先按既有来源分类，不能让publication fence污染实体鼠标/触控板镜像路径。
    if (this.isPointerSourcedTouch(event)) return false
    const changed: TouchObject[] = event.changedTouches ?? []
    if (event.type === TouchType.Down) {
      if (this.groupSchema !== undefined) {
        // 新的真实 DOWN 可以结束被隐藏节点没收到 UP 的旧隔离墓碑；MOVE 永不走此分支。
        for (const touch of changed) if (this.groupBlockedUiFingers.delete(touch.id)) this.blockedUiFingers.delete(touch.id)
      }
      const publicationAllowed: boolean=this.admitTouchAction_(token)
      let memberAllowed: boolean=true
      if (publicationAllowed && this.groupSchema !== undefined && controlId.length > 0) {
        try { memberAllowed=testNapi.isTouchGroupControlCurrent(token,controlId,groupEpoch) } catch (_) { memberAllowed=false }
      }
      if (!publicationAllowed || !memberAllowed) {
        for (const touch of changed) {
          this.blockedUiFingers.add(touch.id)
          if (publicationAllowed && !memberAllowed) this.groupBlockedUiFingers.add(touch.id)
        }
        return false
      }
    }
    let blocked: boolean = false
    for (const touch of changed) if (this.blockedUiFingers.has(touch.id)) blocked = true
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      for (const touch of changed) {
        this.blockedUiFingers.delete(touch.id)
        if (this.groupSchema !== undefined) this.groupBlockedUiFingers.delete(touch.id)
      }
      return !blocked
    }
    return !blocked
  }

  private hasContinuousControlInteraction(): boolean {
    if (this.touchVisual.joystickActive || this.touchVisual.locked) return true
    if (this.activeKeys.size > 0 || this.arktsButtonOutputs.size > 0 ||
      this.accessibilityToggleStates.size > 0 || this.joystickFingerId >= 0 ||
      this.scrollFingerIds.size > 0 || this.hotbarFingerId.size > 0) return true
    let active: boolean = false
    this.buttonFingerIds.forEach((fingers: Set<number>, _id: string) => { if (fingers.size > 0) active = true })
    this.btnVisMap.forEach((state: BtnVisState, _id: string) => { if (state.pressed) active = true })
    return active
  }

  private onPageActiveChanged(): void {
    this.touchSurface.setActive(this.pageActive)
    this.touchSession.setActive(this.pageActive && !this.editing)
    if(this.pageActive && this.learningStore?.requested()) { this.touchGuide.stop(); this.tutorialOpen=false; this.learningSeen=false; this.learningRequested=true }
    if(!this.pageActive) this.touchGuide.baseline(this.touchVisual.guide)
    if(this.pageActive) this.maybeOpenLearning()
    this.syncGuideBounds()
    if (!this.pageActive) this.resetTransientInputState()
  }

  async aboutToAppear(): Promise<void> {
    this.mounted = true
    this.touchSurface = this.createTouchSurface_()
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
    this.desiredProfile = cloneLayout(this.profile)
    this.ensureTouchLayoutObserver_()
    try {
      const context=this.getUIContext().getHostContext()
      if(context!==undefined) { this.learningStore=new TouchLearningStore(context.filesDir); this.learningSeen=this.learningStore.seen(); this.learningRequested=this.learningStore.requested() }
    } catch (_) { this.learningSeen=true }
    this.touchSession.setDirectory(this.gameDirectory)
    this.touchSession.refreshBindings()
    this.touchSession.setGrabbed(this.isGrabbed)
    // 必要GUI缩放影响hotbar/schema，菜单点影响面板绘制/命中；两者不随视觉观察退订。
    const session: EntryTouchSession=this.touchSession
    this.observationEnabled=true; this.observationGeneration++
    this.touchSession.start((_state: EntryTouchVisual): void => {}, this.pageActive,(state: GameGuiState): void => {
      if (this.mounted && expectedAppearanceGeneration===this.appearanceGeneration && session===this.touchSession && session.hasCurrentSource()) this.receiveGameGui(state)
    },(x: number,y: number): void => {
      if (!this.mounted || expectedAppearanceGeneration!==this.appearanceGeneration || session!==this.touchSession || !session.hasCurrentSource()) return
      this.menuGeometryX=x; this.menuGeometryY=y; this.syncMouseBounds()
    })
    this.subscribeTouchObservation_()
    const appearance: number=expectedAppearanceGeneration
    const observationHost=getGameSessionHost()
    // 无路由ID时Host可先准备activity0，随后正常启动才bindActivity。只在原心跳上
    // 等原Host实际绑定后登记，不另开时钟、不取得新Host，也不凭Want创造活动/来源。
    const registerObservation: () => void=(): void => {
      if (this.observationRegistration!==undefined || !this.mounted || !this.pageActive ||
        appearance!==this.appearanceGeneration || session!==this.touchSession || !session.hasCurrentSource()) return
      this.observationRegistration=registerEntryInputObservation(observationHost,appearance,
        (action: string): EntryInputObservationResult | undefined => {
          if (!this.mounted || appearance!==this.appearanceGeneration || session!==this.touchSession || !session.hasCurrentSource()) return undefined
          return this.operateTouchObservation_(action)
        })
    }
    registerObservation()
    this.touchSession.setHeartbeat((): void => {
      if (!this.mounted || appearance!==this.appearanceGeneration || session!==this.touchSession) return
      this.reconcileTouchSurface_(); registerObservation()
    })
    this.registerRegions()
    this.profileVer++
    // 进度读取也冻结本次实际控制器；同组件重建不能让已捕获的旧 reader 借后来
    // touchSurface 报告新 token/operation。正常退订之外，原控制器 dispose 仍给出 Retired。
    const configurationSurface: TouchSurfaceController = this.touchSurface
    store.addInputConfigurationListener(this.configurationListener, 'touch-controls', () => configurationSurface.status())
    this.subscribeConfigurationStatus_(store)
    // 监听物理设备插拔。⚠️ 这里曾写「按钮显隐随插拔实时变化」——**不成立**，
    // `this.capability` 是只写不读的（理由与三句假注释的原文见该字段处）。
    getInputDeviceMonitor().addCapabilityListener(this.capabilityListener)
    this.capability = getInputDeviceMonitor().capabilityNow()
    // C 接管按钮后，按下态由 C 推回 ArkTS 更新高亮（键与视觉同源）。
    if (this.schemaActive) {
      this.ensureTouchFeedback_()
      // native 是 grabbed 按钮 PRESS 的唯一生成者；系统触觉 API 留在 UI 线程执行。
      // TSFN 自身有界，UI 卡顿时反馈可丢弃，但绝不会阻塞触摸或延迟补震。
    } else {
      // 触控发布协议缺失时明确保持新UI准入关闭，等待匹配产物，不能假装存在旧region降级。
      this.touchStatusMessage='触控发布能力暂不可用，请使用配套应用产物'
      hilog.warn(0x0000, GAME_CONTROLS_TAG,
        'Native touch publication unavailable; waiting for matching runtime')
    }
  }

  /**
   * Phase 1（fix/input-system §P0-2）：把所有"瞬时输入状态"的释放集中到一个方法里，
   * onGrabChanged / aboutToDisappear / 编辑模式入口 / 具名touch模态 都复用同一份。
   *
   * @param keepHeldButtons 多键健壮性（2026-05-30）：true 时**不**释放仍被手指按住的顶层 press
   *   按钮，只清"非按住"的瞬时态。用于 grabbed 翻转——
   *   因为"按住 F3 时按 F4 打开游戏模式切换器"会 ungrab，此时强制松 F3 会让切换器立刻关闭，
   *   只能切一次。保留按住态后，F3 的 UP 在玩家真正抬手时才到，可连续切换。抽屉子按钮与
   *   toggle / longPress 照常按记录释放：本方法随后收起全部抽屉，子按钮的抬手事件不保证送达。
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
    this.mouseController.release(); this.mouseOpen=false
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
    // gate由客户端在detach完成后归还。这里不能提前clear：controller仍在飞时
    // 放开char回灌会重复输入，DesktopTouch也可能有另一个合法的硬键盘owner。
    // 抽屉：grabbed 翻转或销毁时收起
    if (this.drawerOpen.size > 0) {
      this.drawerOpen.clear()
      this.drawerOpen = new Map(this.drawerOpen)
    }
  }

  // 阶段 1.1 / 2.4：grabbed 翻转时释放所有按下中的虚拟按键 / 摇杆 / 滚轮 / IME / 抽屉，防止状态泄漏，
  // 并重注册 C 层命中矩形（可见集合随 grabbed 改变）。
  onGrabChanged(): void {
    this.touchSession.setGrabbed(this.isGrabbed)
    if (this.isGrabbed) this.touchSession.refreshBindings()
    // 多键健壮性（2026-05-30）：grabbed 翻转时保留仍被按住的按钮（keepHeldButtons=true），
    // 支持"按住 F3 + 连点 F4"这类跨 grab 翻转的组合键（F4 开切换器会 ungrab）。
    this.resetTransientInputState(true)
    if(this.isGrabbed) { this.mouseController.release(); this.mouseOpen=false; this.guiHint=false }

    // R1：grabbed 翻转改变了 grabbedOnly / joystick / scroll 的可见性，
    // 重新注册 C 层命中矩形，避免 normal↔grabbed 切换后矩形表与渲染层不同步。
    this.registerRegions()
    this.touchSession.refreshVisual()
    this.maybeOpenLearning()
  }

  private onSurfaceContextChanged(): void {
    const store = getLayoutStore()
    // 运行层始终重新投影已确认方案；编辑草稿只由编辑器持有。
    if (store.isReady()) {
      store.refreshDeviceDerivedLayout()
      this.desiredProfile = cloneLayout(store.getActiveProfile())
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
    const groupRegistration: string = this.groupRegistration
    this.groupRegistration=''
    this.pendingGroupCommands.clear()
    if (groupRegistration.length > 0) {
      try { testNapi.onTouchGroupsChanged(null,groupRegistration) } catch (_) {}
    }
    unregisterEntryInputObservation(this.observationRegistration); this.observationRegistration=undefined
    this.observationEnabled=false; this.observationGeneration++
    this.mounted = false
    this.touchSurface.dispose()
    if (this.layoutObserverRegistered) {
      try { this.getUIContext().getUIObserver().off('didLayout', this.didTouchLayout) } catch (_) {}
      this.layoutObserverRegistered = false
    }
    const imeModal: EntryTouchModalLease | undefined = this.imeModal
    this.imeModal = undefined
    if (imeModal !== undefined) releaseEntryTouchModal(imeModal)
    const unresolved: EntryTouchModalLease | undefined = this.unresolvedSurfaceModal
    this.unresolvedSurfaceModal = undefined
    if (unresolved !== undefined) releaseEntryTouchModal(unresolved)
    this.syncGuideBounds()
    this.touchSession.stop()
    this.touchGuide.stop()
    getLayoutStore().removeInputConfigurationListener(this.configurationListener)
    this.retireConfigurationStatus_()
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
    return this.runtimeLayout.find(item.id)?.rectVp.x ?? 0
  }
  private itemY(item: ControlItem): number {
    return this.runtimeLayout.find(item.id)?.rectVp.y ?? 0
  }
  private itemW(item: ControlItem): number {
    return this.runtimeLayout.find(item.id)?.rectVp.width ?? 0
  }
  private itemH(item: ControlItem): number {
    return this.runtimeLayout.find(item.id)?.rectVp.height ?? 0
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

  /** UI只呈现已安装候选；dirty的grab/可见性不先移除仍拥有旧角色的节点。 */
  private isControlVisible(item: ControlItem): boolean {
    return this.runtimeLayout.find(item.id) !== undefined
  }

  /** 某按钮当前是否被至少一根手指按住（buttonFingerIds 占用集合非空）。 */
  /**
   * 安全网（2026-06）：IME（聊天 / field 文本框）打开瞬间，释放所有按住的方向/摇杆/按钮。
   * 杜绝「点输入框时触摸误触下层虚拟按键 → 按钮收到 DOWN 但 IME 开起丢了 UP → 键卡死」。
   * 延后到下一帧执行，避免与触发它的那次触摸处理（如 ime_chat 按钮 DOWN）交叉。
   * 注意：不动 imeOpen / fieldImeOpen / drawer 等显隐标志，只清「会发 PRESS 却可能丢 RELEASE」的输入。
   */
  private onImeOpenChanged(): void {
    const open: boolean = this.imeOpen || this.fieldImeOpen
    if (open && this.imeModal === undefined) {
      // 先按按下记录退休ArkTS输出，再原子取得Native touch域门；其它输入端和有效text lease保留。
      this.releaseInputForSurfaceRebuild()
      this.imeModal = acquireEntryTouchModal('ime:' + this.appearanceGeneration.toString())
      if (this.imeModal === undefined) this.touchStatusMessage = '文本覆盖层触控隔离暂不可用，请关闭后重试'
    } else if (!open && this.imeModal !== undefined) {
      const lease: EntryTouchModalLease = this.imeModal
      this.imeModal = undefined
      if (!releaseEntryTouchModal(lease)) this.touchStatusMessage = '触控恢复等待Native确认'
    }
    this.touchGuide.baseline(this.touchVisual.guide)
    this.syncGuideObservation(); this.syncGuideBounds(); this.syncMouseBounds()
    this.touchSession.setTouchAdmission(!open && !this.editing && !hasEntryTouchModal() &&
      this.touchSurface.admits(this.uiPublicationToken))
  }

  private isButtonHeld(id: string): boolean {
    const set = this.buttonFingerIds.get(id)
    return set !== undefined && set.size > 0
  }

  // 注册所有控件区域到 C 层（px 坐标），供 C 层过滤 native 触摸
  //
  // R1：只注册"当前真的渲染出来"的控件（isControlVisible）。之前全量注册导致
  // 隐藏 / 自动隐藏 / grabbedOnly 的按钮在 C 层仍占命中矩形，吞掉 native 视角。
  private registerRegions(): boolean {
    if (!this.mounted) return false
    this.retireHiddenMouse_()
    if (!Number.isFinite(this.compWidth) || !Number.isFinite(this.compHeight) || this.compWidth <= 0 || this.compHeight <= 0) {
      this.publishUnresolvedSurfaceSchema(); return false
    }
    try { return this.sendControlSchema() }
    catch (error) {
      this.touchStatusMessage = '触控布局待恢复：' + String(error)
      return false
    }
  }

  private publishUnresolvedSurfaceSchema(): void {
    // 权威上下文缺字段时关闭UI的新解释并保留desired；绝不发布v2空表抹掉旧策略。
    this.touchSession.setTouchAdmission(false)
    if (this.unresolvedSurfaceModal === undefined) {
      this.releaseInputForSurfaceRebuild()
      this.unresolvedSurfaceModal = acquireEntryTouchModal('surface-unresolved:' + this.appearanceGeneration.toString())
    }
    this.touchStatusMessage = '触控窗口几何暂不可用，等待窗口恢复'
  }

  // ============= Control Schema v2 运行时契约 =============
  // native 已接管 grabbed 下的摇杆、按钮、滚轮和 hotbar。handledBy=arkts 控件仍由 ArkUI exact rect
  // 直接处理；native schema 只把这些区域标为不可解释成 look，不再维持无生产者的激活回调假链路。
  private schemaActive: boolean =
    typeof testNapi.publishTouchSchema === 'function' &&
    typeof testNapi.touchPublicationState === 'function' &&
    typeof testNapi.confirmTouchPublication === 'function' &&
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
   * C 层是否接管该按钮的按键发送（游戏和菜单共用）：是则 ArkTS 只保留视觉高亮 + 触觉、不发键、不做 dragLook。
   * 普通按钮含展开抽屉子项均按实际投影接管；系统功能入口继续属于ArkUI。
   */
  private cOwnsButton(item: ControlItem): boolean {
    if (!this.schemaActive || !this.schemaTakeoverButtons) return false
    // 系统功能按钮（输入/设置/显示）由 ArkTS 处理（handledBy=arkts），C 不接管发键。
    if (item.systemAction !== undefined) return false
    return item.type === ControlType.BUTTON && this.runtimeLayout.find(item.id)?.handledBy === 0
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

  private sendControlSchema(): boolean {
    const surface: InputSurfaceContext = getInputSurfaceContextStore().snapshot()
    let measuredDensity: number = 0
    try { measuredDensity = this.getUIContext().vp2px(1) } catch (_) {}
    const context = runtimeTouchContext(surface, this.compWidth, this.compHeight, measuredDensity)
    if (!context.valid) { this.publishUnresolvedSurfaceSchema(); return false }
    const profile: LayoutProfile = cloneLayout(this.desiredProfile)
    const issue: string = layoutCapabilityIssue(profile)
    const layout: RuntimeTouchLayout = projectRuntimeTouchLayout(profile, context, this.guiState,
      this.isGrabbed, this.globalVisMode, this.drawerOpen)
    // 不支持的历史树保留原文及编辑/导出入口，运行时明示不可用，不把子摇杆假装BUTTON。
    if (issue.length > 0) { layout.entries=[]; layout.controls=[]; this.touchStatusMessage=issue }
    const swipeGroups: string[] = []
    for (const control of profile.controls) {
      if (control.swipeGroup && swipeGroups.indexOf(control.swipeGroup) < 0) swipeGroups.push(control.swipeGroup)
    }
    swipeGroups.sort()
    const controls: ControlSchemaEntry[] = []
    for (const entry of layout.entries) {
      const item: ControlItem = entry.item
      controls.push({ id:item.id, kind:item.type as number, handledBy:entry.handledBy,
        x:entry.rectPx.x, y:entry.rectPx.y, w:entry.rectPx.width, h:entry.rectPx.height,
        hitSlop:entry.hitSlopPx, keyOrMouse:item.keyOrMouse, keys:effectiveKeys(item),
        trigger:this.triggerCode(item.trigger), dragLook:item.dragLook === true,
        haptic:profile.haptic ?? true, swipeGroup:item.swipeGroup ? swipeGroups.indexOf(item.swipeGroup)+1 : 0 })
    }
    if(this.guiHint && !this.isGrabbed) this.addUiBlock(controls,'gui_hint_',Math.max(12,(context.widthVp()-this.hintWidth())/2),12,
      this.hintWidth(),Math.min(240,context.heightVp()-24),context.density,layout,'gui-hint')
    if(issue.length>0) this.addUiBlock(controls,'touch_status_',12,48,Math.max(1,Math.min(400,context.widthVp()-24)),
      Math.max(1,Math.min(112,context.heightVp()-24)),context.density,layout,'compatibility')
    this.touchSession.setRuntimeContext(context)
    this.touchSession.setGuiViewport(context.widthPx,context.heightPx,this.realGameVersion)
    const schema: ControlSchemaMsg = { schemaVersion:3, compWidth:context.widthPx, compHeight:context.heightPx,
      contextDensity:context.density,contextTransform:context.transform,
      grabbed:this.isGrabbed, deadZone:profile.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE,
      controls:controls, touch:this.touchSession.schemaOptions(profile) }
    // 只有持久组定义需要v4扩展，编辑草稿不再进入运行表。
    const groups: TouchGroupSchema | undefined = profile.controlGroups === undefined ? undefined :
      compileTouchGroups(profile,layout,controls)
    if (groups !== undefined) {
      if (groups.groups.length > 0 && (typeof testNapi.readTouchGroups !== 'function' || typeof testNapi.confirmTouchGroups !== 'function')) {
        this.reportGroupIssue_('UnsupportedFeature: 当前 Native 不支持触控组'); return false
      }
      schema.schemaVersion=4; schema.groupSchema=groups
    }
    // 能力与安全投影属于同一冻结候选。原Native/UI完成只授安全安装，不把不支持
    // 的原树写成Applied；状态读取不能从后来this.profile给旧候选补能力结果。
    const applied: boolean=this.touchSurface.request(new TouchSurfaceCandidate(profile,layout,schema,issue))
    if (applied && schema.touch!==undefined) {
      // 完全等价请求可复用原Native/UI完成；本次冻结值与原token共同前移绑定定义，
      // 不伪造新的呈现/Native确认，也不让失败B候选改变follow/action。
      const completion: InputConfigurationProgress=this.touchSurface.status()
      if (this.touchSurface.admits(completion.token))
        this.touchSession.adoptConfirmedTouchBindings(profile,schema.touch,completion.operationId,completion.desiredCandidateId,completion.token)
    }
    return applied
  }

  /** 循环全局可见性档位（全部显示 → 仅菜单 → 全部隐藏 → …）。由"显示"系统按钮触发。 */
  private cycleVisMode(): void {
    this.globalVisMode = (this.globalVisMode + 1) % 3
    // 被新档位隐藏的展开抽屉等同于收起：子按钮视图随之移出组件树，抬手事件不保证送达。
    this.collapseHiddenDrawers()
    // 可见集合变了，重注册 C 层命中矩形（隐藏的按钮不再吞 native 视角）
    this.registerRegions()
  }

  /** 当前档位下已不可见、却仍处于展开态的抽屉：先按记录释放其子按钮输出，再收起。 */
  private collapseHiddenDrawers(): void {
    let changed: boolean = false
    for (let i = 0; i < this.profile.controls.length; i++) {
      const drawer: ControlItem = this.profile.controls[i]
      if (drawer.type !== ControlType.DRAWER || !(this.drawerOpen.get(drawer.id) ?? false)) continue
      if (runtimeTouchControlVisible(drawer,this.isGrabbed,this.globalVisMode)) continue
      this.releaseDrawerChildren(drawer)
      this.drawerOpen.set(drawer.id, false)
      changed = true
    }
    if (changed) this.drawerOpen = new Map(this.drawerOpen)
  }

  /**
   * 用户点击抽屉主按钮：收起前先释放整棵子树里按住 / 切换中 / 长按计时中的输出。收起后子按钮
   * 视图被移出组件树，ArkUI 是否仍把那根手指的 UP 投递给已移除节点没有保证，不能指望抬手时再放。
   */
  private toggleDrawer(drawer: ControlItem): void {
    const open: boolean = this.drawerOpen.get(drawer.id) ?? false
    if (open) this.releaseDrawerChildren(drawer)
    this.drawerOpen.set(drawer.id, !open)
    this.drawerOpen = new Map(this.drawerOpen)
    // 方案 A 收尾：抽屉展开/收起改变了可见子按钮，重下发 schema 让 C 更新"忽略区"（防子按钮 look 穿透）。
    this.registerRegions()
  }

  /** 递归释放抽屉全部后代控件的 ArkTS 侧输入；有任何状态被清掉时刷新一次按下视觉。 */
  private releaseDrawerChildren(drawer: ControlItem, depth: number = 0): void {
    const children: ControlItem[] | undefined = drawer.children
    if (children === undefined || depth >= MAX_LAYOUT_CHILD_DEPTH) return
    let released: boolean = false
    for (let i = 0; i < children.length; i++) {
      if (this.releaseControlInputs(children[i].id)) released = true
      this.releaseDrawerChildren(children[i], depth + 1)
    }
    if (released) this.btnPressedVer++
  }

  /**
   * 释放单个控件在 ArkTS 侧的全部输入状态：清手指占用与长按计时，按按下时记录的输出发 RELEASE
   * （普通 / toggle / longPress 共用 `arktsButtonOutputs`，无障碍 toggle 用自己的记录），再清状态机
   * 与按下高亮。RELEASE 被拒时记录由恢复路径处理，这里不伪造“已释放”。返回是否清掉了任何状态。
   */
  private releaseControlInputs(id: string): boolean {
    let active: boolean = false
    const fingers: Set<number> | undefined = this.buttonFingerIds.get(id)
    if (fingers !== undefined && fingers.size > 0) {
      fingers.clear()
      active = true
    }
    const timer: number | undefined = this.longPressTimers.get(id)
    if (timer !== undefined) {
      clearTimeout(timer)
      this.longPressTimers.delete(id)
      active = true
    }
    if (this.arktsButtonOutputs.has(id)) {
      this.releaseArktsButtonOutput(id)
      active = true
    }
    if (this.accessibilityToggleStates.has(id)) {
      this.releaseAccessibilityToggle(id)
      active = true
    }
    if (this.toggleStates.delete(id)) active = true
    if (this.longPressFired.delete(id)) active = true
    // 抽屉孩子也复用dragLook；收起/隐藏时一并退休坐标锚点，迟到MOVE不能续用已结束的触指。
    if (this.dragLookFinger.delete(id)) active = true
    this.dragLookLastX.delete(id)
    this.dragLookLastY.delete(id)
    this.lastTapAt.delete(id)
    // Native按钮在ArkTS没有手指/输出记录，但其高亮仍属于本控件；隐藏/退休必须清掉，
    // 不能把“没有ArkTS owner”误当作“没有视觉状态”。其它控件和来源保持原样。
    const vis: BtnVisState | undefined = this.btnVisMap.get(id)
    if (vis !== undefined && vis.pressed) { vis.pressed = false; active = true }
    return active
  }

  /**
   * 仅原input-trace策略启用时记录真实阶段结果。预算、日志异常都只丢诊断；
   * 不读取Native、不补投输入、不取得owner，也不记录文本、键码、控件名称或token。
   * appearance是调用点已有代次，result只表示该阶段原调用返回，不代表游戏采用。
   */
  private noteImeRoute(phase: string, role: string, appearance: number,
    result: boolean, touchType: number = -1): void {
    try {
      if (!DiagnosticPolicy.inputTraceEnabled() || this.imeRouteTraceCount >= 64) return
      this.imeRouteTraceCount++
      hilog.info(0x0000, GAME_CONTROLS_TAG,
        'AMCL_IME_ROUTE phase=%{public}s role=%{public}s appearance=%{public}s result=%{public}d touch=%{public}d',
        phase, role, appearance.toString(), result ? 1 : 0, touchType)
    } catch (_) { /* 观察失败不得让原按钮准入、发键或模态处理抛出新异常。 */ }
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
      this.closeMouse()
      // 这些值只供本次动作的观察；异步RELEASE记录沿原role/appearance，不借后来grab状态。
      const imeRole: string = this.isGrabbed ? 'chat' : 'field'
      const imeAppearance: number = this.appearanceGeneration
      this.noteImeRoute('request', imeRole, imeAppearance, true)
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
        const acquired: boolean = this.dispatchButton(item, GLFW_PRESS)
        this.noteImeRoute('key-acquire', imeRole, imeAppearance, acquired)
        if (!acquired) return
        Promise.resolve().then(() => {
          const released: boolean = this.dispatchButton(item, GLFW_RELEASE)
          this.noteImeRoute('key-release', imeRole, imeAppearance, released)
        })
        this.imeModal = acquireEntryTouchModal('chat:' + this.appearanceGeneration.toString())
        this.noteImeRoute('modal', imeRole, imeAppearance, this.imeModal !== undefined)
        if (this.imeModal === undefined) { this.touchStatusMessage='聊天触控隔离暂不可用，请重试'; return }
        this.fieldImeOpen = false
        this.imeOpen = true
        this.noteImeRoute('frontend-requested', imeRole, imeAppearance, true)
      } else {
        this.imeModal = acquireEntryTouchModal('field:' + this.appearanceGeneration.toString())
        this.noteImeRoute('modal', imeRole, imeAppearance, this.imeModal !== undefined)
        if (this.imeModal === undefined) { this.touchStatusMessage='文本触控隔离暂不可用，请重试'; return }
        this.imeOpen = false
        this.fieldImeOpen = true
        this.noteImeRoute('frontend-requested', imeRole, imeAppearance, true)
      }
    } else if (action === 'edit') {
      this.openEditor()
    } else if (action === 'visibility') {
      this.cycleVisMode()
    } else if (action === 'mouse') {
      if(this.mouseOpen) this.closeMouse(); else this.openMouse(this.uiPublicationToken,item.id)
    }
  }

  /**
   * 进入布局编辑器：租约先于异步克隆，事务基线先于预设副本；持久化失败绝不打开
   * 一份假成功的草稿。组件销毁或 appearance 改变后，旧续体只回滚，不再操作 UI。
   */
  private async openEditor(): Promise<void> {
    // 同一编辑租约只允许一个覆盖层，保存或取消确认后才恢复运行输入。
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
      // 按按下记录先退休ArkTS输出，再取得具名Native touch域模态；页面runtime独立控制物理键鼠/手柄routing。
      this.resetTransientInputState()
      this.editorModal = acquireEntryTouchModal('editor:' + this.appearanceGeneration.toString())
      if (this.editorModal === undefined) throw new Error('无法取得布局编辑的触控隔离租约')
      this.editorInputPaused = true
      this.onInputPause(true)
      if (!this.mounted || appearance !== this.appearanceGeneration) return
      this.profile = cloneLayout(store.getActiveProfile())
      this.desiredProfile = cloneLayout(this.profile)
      this.profileVer++
      this.onLayoutChanged()
      this.editorMode='choose'
      this.editing = true
      this.syncGuideBounds()
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
              this.desiredProfile = cloneLayout(this.profile)
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
    // 销毁仍须退休自己持有的模态；Native关闭结果未知时保留代理的恢复义务。
    const lease: EntryTouchModalLease | undefined = this.editorModal
    this.editorModal = undefined
    if (lease !== undefined && !releaseEntryTouchModal(lease)) this.showEditorError_('恢复游戏触控等待Native确认')
    if (!this.editorInputPaused) return
    this.editorInputPaused = false
    try { this.onInputPause(false) }
    catch (error) { this.showEditorError_('恢复页面输入失败：' + (error as Error).message) }
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
    // 保存/取消已由子编辑器确认；运行层只发布这个确认结果。
    try {
      if (this.mounted) {
        this.profile = cloneLayout(result ?? getLayoutStore().getActiveProfile())
        this.desiredProfile = cloneLayout(this.profile)
        this.profileVer++
        this.onLayoutChanged()
      }
    } catch (error) {
      this.showEditorError_('布局结果已确认，但刷新按键失败：' + (error as Error).message)
    } finally {
      this.editing = false
      this.releaseEditorLease_()
      this.resumeEditorInput_()
      this.syncGuideBounds()
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
   *
   * 锁存窗口内想按下的方向不再直接丢弃：记入 pendingLatchedDirections 并确保有一个到期补发定时器，
   * 否则手指停在新方向不动（没有后续采样）时该方向永远不会按下。want=false 的采样立即撤销待补发。
   */
  private applyDirection(key: number, want: boolean): void {
    const has = this.activeKeys.has(key)
    if (!want) this.pendingLatchedDirections.delete(key)
    if (want && !has) {
      const lastReleaseAt = this.keyLastReleaseAt.get(key) ?? 0
      const now = Date.now()
      if (now - lastReleaseAt < JOYSTICK_REPRESS_LOCKOUT_MS) {
        // 锁存窗口内禁止 press；到期时由 onDirectionLatchExpired 按当时仍成立的意图补发。
        this.pendingLatchedDirections.add(key)
        this.armDirectionLatchTimer(lastReleaseAt + JOYSTICK_REPRESS_LOCKOUT_MS)
        return
      }
      this.pendingLatchedDirections.delete(key)
      // Keep the local held cache aligned with the native owner.  A closed
      // surface gate or a stale native bridge must not turn a rejected PRESS
      // into a synthetic held key that suppresses every later retry.
      if (this.emitTouchKey('direction', key, GLFW_PRESS)) this.activeKeys.add(key)
    } else if (!want && has) {
      // A rejected RELEASE remains retryable on the next lifecycle boundary;
      // removing it here would strand the native owner with no ArkTS record.
      if (this.emitTouchKey('direction', key, GLFW_RELEASE)) {
        this.activeKeys.delete(key)
        this.keyLastReleaseAt.set(key, Date.now())
      }
    }
  }

  /**
   * 全组件只有一个锁存补发定时器：已有更早到期的就沿用，新的到期点更早时改排到更早的那一刻。
   * 到期后仍在锁存内的键会在 applyDirection 里重新排队，所以最多晚一个定时器粒度。
   */
  private armDirectionLatchTimer(dueAt: number): void {
    if (this.directionLatchTimer !== -1) {
      if (this.directionLatchDueAt <= dueAt) return
      clearTimeout(this.directionLatchTimer)
    }
    this.directionLatchDueAt = dueAt
    const delay: number = Math.max(0, dueAt - Date.now())
    this.directionLatchTimer = setTimeout(() => { this.onDirectionLatchExpired() }, delay) as number
  }

  /** 锁存到期：摇杆仍由本组件驱动且手指仍在时，按记录的意图补发 PRESS；否则直接丢弃。 */
  private onDirectionLatchExpired(): void {
    this.directionLatchTimer = -1
    this.directionLatchDueAt = 0
    if (!this.mounted || this.joystickFingerId === -1 || this.cOwnsJoystick()) {
      this.pendingLatchedDirections.clear()
      return
    }
    const keys: number[] = []
    this.pendingLatchedDirections.forEach((key: number) => { keys.push(key) })
    for (let i = 0; i < keys.length; i++) this.applyDirection(keys[i], true)
  }

  /** 松开摇杆、各类复位与组件销毁都会调用：清空待补发方向并撤销定时器，不留迟到的 PRESS。 */
  private cancelDirectionLatch(): void {
    this.pendingLatchedDirections.clear()
    if (this.directionLatchTimer !== -1) {
      clearTimeout(this.directionLatchTimer)
      this.directionLatchTimer = -1
    }
    this.directionLatchDueAt = 0
  }

  private releaseAllDirections(): void {
    this.cancelDirectionLatch()
    const dirs = [GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D]
    for (let di = 0; di < dirs.length; di++) {
      if (this.activeKeys.has(dirs[di])) {
        if (this.emitTouchKey('direction', dirs[di], GLFW_RELEASE)) {
          this.activeKeys.delete(dirs[di])
          this.keyLastReleaseAt.set(dirs[di], Date.now())
        }
      }
    }
  }

  /** 兼容ArkUI控件的输入记录照常流转，关闭观察只停止高亮写入，不撤按键所有权。 */
  private setPressed(id: string, pressed: boolean): void {
    if (this.observationEnabled===false) return
    this.getBtnVis(id).pressed = pressed
    this.btnPressedVer++
  }

  private isPressed(id: string): boolean {
    if (this.observationEnabled===false) return false
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
  // 这些状态在 onGrabChanged / touch模态 / 编辑改键等场景必须清零，
  // 已在 onGrabChanged + clearAllToggles 里处理。
  private toggleStates: Set<string> = new Set()                // 当前 toggle 处于按下态的按钮 id
  // 无障碍激活的 toggle：id → 按下时实际发出的键。释放只按这份记录，热更新改键后也不会用新键去放旧键。
  private accessibilityToggleStates: Map<string, ArktsButtonOutputRecord> =
    new Map<string, ArktsButtonOutputRecord>()
  private lastTapAt: Map<string, number> = new Map()           // doubleTap 用：上次点击时间戳
  private longPressTimers: Map<string, number> = new Map()     // longPress 用：定时器 id
  private longPressFired: Set<string> = new Set()              // longPress 已触发过 PRESS 的按钮

  /**
   * 清空 toggle / longPress / 无障碍 toggle 状态机并按按下时的记录补发 RELEASE。
   * 全部按 id 读记录，不再到顶层 controls 里查控件：抽屉子按钮与已被替换掉的控件同样能放干净。
   * RELEASE 被拒时 `arktsButtonOutputs` / 无障碍记录保留，由下一次完整复位或源级恢复继续处理。
   */
  private clearAllToggles(): void {
    const toggled: string[] = []
    this.toggleStates.forEach((id: string) => { toggled.push(id) })
    for (let i = 0; i < toggled.length; i++) this.releaseArktsButtonOutput(toggled[i])
    this.toggleStates.clear()
    const accessible: string[] = []
    this.accessibilityToggleStates.forEach((_record: ArktsButtonOutputRecord, id: string) => { accessible.push(id) })
    for (let i = 0; i < accessible.length; i++) this.releaseAccessibilityToggle(accessible[i])
    this.lastTapAt.clear()
    this.longPressTimers.forEach((tid: number) => clearTimeout(tid))
    this.longPressTimers.clear()
    const fired: string[] = []
    this.longPressFired.forEach((id: string) => { fired.push(id) })
    for (let i = 0; i < fired.length; i++) this.releaseArktsButtonOutput(fired[i])
    this.longPressFired.clear()
  }

  /** 在整棵控件树（顶层 + 抽屉 children）里按 id 找控件；id 全树唯一由布局校验器保证。 */
  private findControlById(id: string): ControlItem | undefined {
    return this.findControlIn(this.profile.controls, id, 0)
  }

  private findControlIn(items: ControlItem[], id: string, depth: number): ControlItem | undefined {
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === id) return items[i]
      const children: ControlItem[] | undefined = items[i].children
      if (children !== undefined && depth < MAX_LAYOUT_CHILD_DEPTH) {
        const found: ControlItem | undefined = this.findControlIn(children, id, depth + 1)
        if (found !== undefined) return found
      }
    }
    return undefined
  }

  /** 是否顶层控件。keepHeld 豁免只给顶层 press 按钮：抽屉子按钮会随同一次复位被收起。 */
  private isTopLevelControl(id: string): boolean {
    return this.profile.controls.some((c: ControlItem) => c.id === id)
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
      if (!this.emitCheckedKeySequence(keys, GLFW_PRESS, 'button:' + item.id)) return false
      const record = new ArktsButtonOutputRecord()
      record.keys = keys.slice()
      record.token = this.controlClient.currentToken('button:' + item.id)
      this.arktsButtonOutputs.set(item.id, record)
      if (this.profile.haptic ?? true) hapticTap(8)
      return true
    }

    return this.releaseArktsButtonOutput(item.id)
  }

  /**
   * 按 PRESS 时记录的实际输出释放某个控件：不重新判断 grabbed / schema 归属，也不读可能已热更新的
   * 键位，因此控件是否仍在布局里都能放对。没有记录视为已释放（true）；native 拒绝 RELEASE 时返回
   * false 且这里不删记录，原 token 留给下一次边界重试。原生先复位时旧 token 幂等成功，
   * 不再通过输出键找同端另一控件的 owner，也不扩大成整个触控端的释放。
   */
  private releaseArktsButtonOutput(id: string): boolean {
    const record: ArktsButtonOutputRecord | undefined = this.arktsButtonOutputs.get(id)
    if (record === undefined) return true
    if (!this.controlClient.releaseToken(record.token)) return false
    this.arktsButtonOutputs.delete(id)
    return true
  }

  // 原生以同一控件token冻结整串绑定并负责失败回滚，ArkTS不再逐键寻找LIFO owner。
  private emitCheckedKeySequence(keys: number[], action: number, control: string): boolean {
    return action === GLFW_PRESS ? this.controlClient.acquire(control, keys).length > 0
      : this.controlClient.release(control)
  }

  private emitTouchKey(control: string, key: number, action: number): boolean {
    return this.emitCheckedKeySequence([key], action, `${control}:${key}`)
  }

  private releaseAllArktsButtonOutputs(): void {
    const ids: string[] = []
    this.arktsButtonOutputs.forEach(
      (_record: ArktsButtonOutputRecord, id: string) => { ids.push(id) })
    for (let i: number = 0; i < ids.length; i++) {
      const id: string = ids[i]
      const record: ArktsButtonOutputRecord | undefined = this.arktsButtonOutputs.get(id)
      if (record === undefined) continue
      if (this.controlClient.releaseToken(record.token)) {
        this.arktsButtonOutputs.delete(id)
      }
    }
  }

  private activateButtonFromAccessibility(item: ControlItem, eligibility: string = ''): void {
    if (item.systemAction !== undefined) {
      this.handleSystemAction(item)
      return
    }
    if (this.groupSchema !== undefined && (item.phaseBindings !== undefined || (item.groupActions?.length ?? 0) > 0)) {
      if (!this.admitTouchAction_(this.uiPublicationToken,item.id,eligibility) || this.groupRegistration.length === 0) return
      const controlIndex: number=this.runtimeLayout.entries.findIndex((entry: RuntimeTouchEntry): boolean => entry.item.id === item.id)
      const activePhases: number[]=[]
      if (controlIndex < 0) return
      for (let index: number=0; index<4; index++) {
        const phase=this.groupSchema.controls[controlIndex].bindings[index]
        if (phase.keys.length > 0 || phase.actions.length > 0) activePhases.push(index)
      }
      // 一次无障碍激活没有真实 DOWN/UP/长按轨迹；明确拒绝无法表达的组合，不能只执行其中一槽。
      if (activePhases.length !== 1) { this.reportGroupIssue_('多阶段按钮请使用触摸手势；键盘或辅助功能可使用单阶段入口'); return }
      if (this.pendingGroupCommands.size >= 64 || this.groupCommandSequence >= Number.MAX_SAFE_INTEGER) {
        this.reportGroupIssue_('组动作等待队列已满或序号不可用，请等待当前操作确认'); return
      }
      const intent: TouchGroupCommandIntent={token:this.uiPublicationToken,control:item.id,eligibility:eligibility,
        producer:this.groupRegistration,sequence:(++this.groupCommandSequence).toString(),phase:activePhases[0]}
      this.pendingGroupCommands.set(intent.sequence,intent); this.dispatchGroupIntent_(intent); this.syncTouchGroups_()
      return
    }
    const trigger: TriggerMode = item.trigger ?? 'press'
    // 同一次激活的 PRESS / RELEASE 必须用同一份键序列；toggle 另把它存成释放记录。
    const keys: number[] = effectiveKeys(item).slice()
    if (trigger === 'toggle') {
      if (this.accessibilityToggleStates.has(item.id)) {
        if (this.releaseAccessibilityToggle(item.id)) this.setPressed(item.id, false)
      } else if (this.toggleStates.has(item.id)) {
        if (this.dispatchButton(item, GLFW_RELEASE)) {
          this.toggleStates.delete(item.id)
          this.setPressed(item.id, false)
        }
      } else {
        if (this.emitAccessibilityKeys(keys, GLFW_PRESS, item.id)) {
          const record: ArktsButtonOutputRecord = new ArktsButtonOutputRecord()
          record.keys = keys
          record.token = this.controlClient.currentToken('accessibility:' + item.id)
          this.accessibilityToggleStates.set(item.id, record)
          this.setPressed(item.id, true)
        }
      }
      return
    }
    if (!this.emitAccessibilityKeys(keys, GLFW_PRESS, item.id)) return
    this.setPressed(item.id, true)
    this.emitAccessibilityKeys(keys, GLFW_RELEASE, item.id)
    this.setPressed(item.id, false)
  }

  /** 按无障碍 toggle 按下时取得的 token 释放；只有原生确认退休后才删除 UI 记录。 */
  private releaseAccessibilityToggle(id: string): boolean {
    const record: ArktsButtonOutputRecord | undefined = this.accessibilityToggleStates.get(id)
    if (record === undefined) return true
    if (!this.controlClient.releaseToken(record.token)) return false
    this.accessibilityToggleStates.delete(id)
    return true
  }

  /**
   * 无障碍激活没有触摸，也不经 native schema：由 ArkTS 直接按给定键序列发边沿（RELEASE 倒序）。
   * 原生负责组合键失败回滚，RELEASE 只针对该无障碍控件的 token，避免触及同时持有的触摸控件。
   */
  private emitAccessibilityKeys(keys: number[], action: number, id: string): boolean {
    const accepted: boolean = this.emitCheckedKeySequence(keys, action, 'accessibility:' + id)
    if (accepted && action === GLFW_PRESS && (this.profile.haptic ?? true)) hapticTap(8)
    return accepted
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
        // 无障碍打开的 toggle 由触摸关闭：按那次无障碍 PRESS 记录的键释放。
        if (this.releaseAccessibilityToggle(item.id)) this.setPressed(item.id, false)
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
  //   的顶层 press 类按钮——不发 RELEASE、不清占用集合、不清按下视觉，留给真正的 UP 事件处理。
  //   用于 grabbed 翻转，支持跨翻转的组合键（如按住 F3 点 F4）。抽屉子按钮不豁免：同一次复位会
  //   收起抽屉，子按钮视图被移出组件树后抬手事件没有保证。
  private buttonReleaseAllFingers(keepHeld: boolean = false): void {
    this.buttonFingerIds.forEach((set, id) => {
      if (set.size === 0) return
      // 全树查找：抽屉子按钮与顶层共用这些以 id 为键的账本，只查顶层会把子按钮的记录留成孤儿。
      const item: ControlItem | undefined = this.findControlById(id)
      const trig: TriggerMode = item ? (item.trigger ?? 'press') : 'press'
      // 系统功能按钮（输入/设置/显示）不发键、无持续按住语义，只清占用集合，绝不补发 RELEASE
      // （尤其 edit/visibility 的 keyOrMouse=0，误发会投递一个无意义的 key 0 事件）。
      const isSystem = item !== undefined && item.systemAction !== undefined
      // 保留按住态：仍被按住的顶层 press 类按钮跳过（不释放、不清集合）。
      // toggle / longPress / doubleTap / 系统按钮不属于"持续按住"语义，照常清理。
      if (keepHeld && !isSystem && trig === 'press' && item !== undefined && this.isTopLevelControl(id)) {
        return
      }
      // 按按下时的记录释放；控件已不在当前布局（被替换）时同样放掉记录，不留孤儿。
      if (!isSystem && (trig === 'press' || trig === 'doubleTap')) {
        this.releaseArktsButtonOutput(id)
      }
      set.clear()
    })
    // 重建按下视觉：先全部清按下，再把"仍被按住的按钮"标回按下（keepHeld 时保留 F3 高亮）。
    // 方案 E.2：逐个改 @Observed 对象，仅涉及的按钮子组件刷新。
    this.btnVisMap.forEach((v: BtnVisState) => { v.pressed = false })
    this.buttonFingerIds.forEach((set: Set<number>, id: string) => {
      if (this.observationEnabled!==false && set.size > 0) this.getBtnVis(id).pressed = true
    })
    this.btnPressedVer++   // 触发重渲染，保证按下高亮同步
    // 同步清掉 toggle / longPress 状态机（内部会按需补发 RELEASE）。
    // 注意：keepHeld 下 toggle/longPress 仍清理（它们不是"按住即生效"的连续语义）。
    this.clearAllToggles()
  }

  build() {
    Stack() {
      // 运行按键和编辑草稿必须互斥显示：输入暂停/模态租约只隔离输入，并不会隐藏ArkUI节点。
      // 编辑态只把本运行层透明度置零，保留控件ID、尺寸、原点与didLayout确认所需的真实矩形；
      // 保留节点及热区呈现资格；编辑时隐藏运行视觉，退出后恢复原透明度。
      // 全尺寸容器原点固定为(0,0)，且Transparent允许空白look继续命中下层，绝不能改为Block。
      Stack() {
        // 保留已确认候选的跨域顺序。DrawerView紧随UI父项发出孩子，不重新按profile重排。
        ForEach(this.displayedGroupControls_(), (item: ControlItem) => {
          this.ControlView({item:this.currentTouchItem_(item.id),revision:this.profileVer,token:this.uiPublicationToken,
            groupEpoch:this.touchControlGroupEpoch_(item.id)})
        }, (item: ControlItem) => item.id)
      }.width('100%').height('100%').position({x:0,y:0})
        .opacity(this.editing ? 0 : 1)
        .hitTestBehavior(HitTestMode.Transparent)
      // marker的实际节点存在性与控件矩形一起核验，不用固定下一帧/timeout假装完成布局。
      Text('').width(1).height(1).position({x:0,y:0}).id(this.touchMarkerId_())
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      // 分支本身必须读取可观察状态。首次build时groupSchema尚未安装且不是@State；
      // 若用它作条件，后续回执虽刷新按钮显隐，却不会创建此确认节点，组队列将一直等待ACK。
      // 组修订在安装有效组方案时非空，回到旧布局时清空，正好界定节点的创建/移除。
      if (this.groupRevision.length > 0) {
        Text(this.groupRevision).width(1).height(1).fontSize(1).opacity(0).position({x:0,y:0})
          .id(this.touchGroupMarkerId_()).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      if (this.editing && this.configurationHudMessage_().length > 0) {
        // 配置保存/激活报告只在编辑布局时展示，不作为所有游戏版本的常驻HUD。
        // 原报告订阅与失败事实保留；纯观察文字不参与触控命中和Native排除区。
        Row() {
          Text(this.configurationHudMessage_()).fontSize(13).fontColor('#FFFFFF')
        }.padding(8).backgroundColor('#88000000').borderRadius(8)
          .align(Alignment.TopStart).margin({left:12,top:12}).hitTestBehavior(HitTestMode.None)
      }
      if (this.touchStatusMessage.length > 0) {
        Column({space:8}) {
          Text(this.touchStatusMessage).fontSize(13).fontColor('#FFFFFF')
          if (layoutCapabilityIssue(this.profile).length > 0 && !this.editing) {
            Button('编辑布局').onClick((): void => {
              if (this.admitTouchAction_(this.uiPublicationToken)) this.openEditor()
            })
          }
        }.padding(12).backgroundColor('#D9222D3D').borderRadius(10)
          .width(this.touchOverlay_('compatibility').rectVp.width>0 ? this.touchOverlay_('compatibility').rectVp.width : 300)
          .height(this.touchOverlay_('compatibility').rectVp.height>0 ? this.touchOverlay_('compatibility').rectVp.height : 112)
          .id(this.touchNodeId_(this.touchOverlay_('compatibility').id))
          .position({x:this.touchOverlay_('compatibility').rectVp.x,y:this.touchOverlay_('compatibility').rectVp.y})
          .hitTestBehavior(this.touchOverlay_('compatibility').id.length>0 ? HitTestMode.Block : HitTestMode.None)
      }

      // 注：编辑布局 / 显示（可见性档位）已改为布局中的"系统功能按钮"（systemAction=edit/visibility），
      // 与普通按钮同样式、可移动、右上角默认位置，由上方 ForEach 统一渲染，这里不再单独画 HUD 覆盖层。

      // 编辑模式
      if (this.observationEnabled && !this.isGrabbed && this.pageActive && !this.editing && this.touchVisual.menuVisible && this.density > 0 &&
        (this.mouseOpen || this.profile.touch?.menuMode==='touchpad')) {
        Image($r('app.media.touch_cursor')).width(28).height(36)
          .position({ x: this.touchVisual.menuX/this.density-3, y: this.touchVisual.menuY/this.density-2 })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      if (this.observationEnabled && this.isGrabbed && this.touchVisual.progress > 0 && !this.editing) {
        Progress({ value: this.touchVisual.progress*100, total: 100, type: ProgressType.Linear })
          .width(88).height(4).position({ x: this.compWidth/2-44, y: this.compHeight/2+28 })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      if(this.mousePanelVisible_()) {
        VirtualMousePanel({model:this.mouseController.model,resetRevision:this.mouseResetRevision,compact:this.mouseFrame().compact,
          onClose:(): void => { this.closeMouse() },
          onInteraction:(): void => { this.touchSession.refreshVisual(); this.syncMouseBounds() }})
          .width(this.mouseFrame().width).height(this.mouseFrame().height)
          .position({x:this.mouseFrame().x,y:this.mouseFrame().y})
      }
      if(this.guiHint && !this.isGrabbed && !this.editing && this.touchOverlay_('gui-hint').id.length>0) {
        this.GuiSizeHint({ token: this.uiPublicationToken })
      }
      if(this.tutorialOpen && !this.editing && !this.guiHint && !this.imeOpen && !this.fieldImeOpen && !hasEntryTouchModal()) {
        TouchLearningView({step:this.guideStep,active:this.pageActive,grabbed:this.isGrabbed,mouseOpen:this.mouseOpen,publicationToken:this.uiPublicationToken,
          fingers:this.touchVisual.guide.fingers,scrollEnabled:normalizeTouchPreferences(this.profile.touch)?.menuTwoFingerScroll ?? true,
          viewWidth:this.compWidth,viewHeight:this.compHeight,target:this.guideTarget(),toolbarX:this.guideToolbarX(),
          navigationKind:this.guiState.navigationKind,navigationScrollable:this.guiState.navigationScrollable,
          navigationScrollKnown:this.guiState.navigationScrollKnown,
          onSkip:(token: string): void => { if (this.admitTouchAction_(token)) this.skipLearning() },
          onBeginScroll:(token: string): void => { if (this.admitTouchAction_(token)) this.startScrollLearning() },
          onClose:(token: string): void => { if (this.admitTouchAction_(token)) this.closeLearning() }})
      }
      if (this.editing) {
        this.EditorOverlay()
      }

      // 注：菜单态输入已并入"输入"系统按钮（systemAction=input）：菜单点它开 field IME、游戏内点它开
      // 聊天 IME。一个常驻按钮统筹所有输入，这里不再单独画悬浮键盘按钮。

      // 触控overlay与物理文本能力叠加：电脑触屏和外接键盘仍有自动无视觉IME。
      // 软键盘请求由共享lease仲裁器优先处理，不能两个controller同时attach。
      DesktopPhysicalTextInput({
        active: this.pageActive && !this.isGrabbed && !this.editing &&
          (ProductInputProfile.selection().desktopWindow || this.capability.keyboard)
      })
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
  ControlView($$: TouchControlViewArgs) {
    // 显隐直接作用于真实控件根节点。Hidden保留布局但退出命中；不能用透明的全屏包装层代替。
    this.ControlContent({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
  }

  /** 所有方案都平铺实际几何条目；无组按解释域分层，有组继续使用共同rank。 */
  private displayedGroupControls_(): ControlItem[] {
    return this.groupSchema === undefined ? this.runtimeLayout.entries.map((entry: RuntimeTouchEntry): ControlItem => entry.item) : this.groupControls
  }

  @Builder
  ControlContent($$: TouchControlViewArgs) {
    if (this.isControlVisible($$.item)) {
      if ($$.item.type === ControlType.JOYSTICK) {
        this.JoystickView({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
      } else if ($$.item.type === ControlType.BUTTON) {
        this.ButtonView({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
      } else if ($$.item.type === ControlType.SCROLL_WHEEL) {
        this.ScrollWheelView({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
      } else if ($$.item.type === ControlType.HOTBAR_SELECTOR) {
        this.HotbarSelectorView({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
      } else if ($$.item.type === ControlType.DRAWER) {
        this.DrawerView({item:$$.item,revision:$$.revision,token:$$.token,groupEpoch:$$.groupEpoch})
      }
    }
  }

  @Builder
  JoystickView($$: TouchControlViewArgs) {
    // UI 重构 2026-05-30：摇杆形状跟随 effectiveCornerRadius——
    //   1.0（默认）→ 正圆底盘；0 → 正方形底盘；中间 → 圆角方形。
    //   内圈拇指点同步用同一圆角比例，保持观感统一。保留圆形为默认。
    Stack() {
      Stack() {
      TouchJoystickVisual({controlWidth:this.itemW($$.item),controlHeight:this.itemH($$.item),corner:effectiveCornerRadius($$.item),
        directionX:this.observationEnabled===false ? 0 : this.cOwnsJoystick() ? (this.usesNativeJoystick($$.item) ? this.touchVisual.joystickX : 0) : this.joystickX,
        directionY:this.observationEnabled===false ? 0 : this.cOwnsJoystick() ? (this.usesNativeJoystick($$.item) ? this.touchVisual.joystickY : 0) : this.joystickY,
        pressed:this.usesNativeJoystick($$.item) && (this.touchVisual.joystickActive || this.touchVisual.locked)})
        if (this.usesNativeJoystick($$.item) && (this.touchVisual.locked || this.touchVisual.armed)) {
          Text(this.touchVisual.locked ? '前进锁定' : '松手前进').fontSize(11).fontColor('#FFFFFF')
            .backgroundColor('#CC246AA9').padding(5).borderRadius(8)
            .offset({ y: -this.itemH($$.item)*0.48 })
        }
      }
      .width(this.itemW($$.item)).height(this.itemH($$.item))
      .translate({
        x: this.usesNativeJoystick($$.item) && this.density > 0 && (this.touchVisual.joystickActive || this.touchVisual.locked) ?
          this.touchVisual.centerX/this.density-this.itemX($$.item)-this.itemW($$.item)/2 : 0,
        y: this.usesNativeJoystick($$.item) && this.density > 0 && (this.touchVisual.joystickActive || this.touchVisual.locked) ?
          this.touchVisual.centerY/this.density-this.itemY($$.item)-this.itemH($$.item)/2 : 0
      })
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.itemW($$.item))
    .height(this.itemH($$.item))
    .id(this.touchNodeId_($$.item.id))
    .visibility(this.touchGroupVisible_($$.item.id) ? Visibility.Visible : Visibility.Hidden)
    .zIndex(this.groupRanks.get($$.item.id) ?? 0)
    .position({ x: this.itemX($$.item), y: this.itemY($$.item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，不能拨动摇杆（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      if (!this.admitTouchUi_(event,$$.token,$$.item.id,$$.groupEpoch ?? '0')) return
      // native已经固定本指角色及中心，UI只读取投影；外层命中矩形从不跟随视觉translate移动。
      if (this.cOwnsJoystick()) {
        // MOVE由Native即时解释；外观沿既有16ms快照刷新，不能再按触摸采样率同步
        // 读Native并替换整份ArkUI状态。按下/结束边沿保留即时反馈，输入本身不节流。
        if (event.type !== TouchType.Move) this.touchSession.refreshVisual()
        return
      }
      // 阶段 1.1 多指：摇杆从 DOWN 起锁定一根 fingerId，其他手指不影响。
      // 解决"按住摇杆时另一根手指落在屏幕，touches[0] 错位 → 摇杆瞬间跳变"问题。
      const cx = this.itemW($$.item) / 2
      const cy = this.itemH($$.item) / 2
      const radius = this.itemW($$.item) * 0.34

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
  ButtonView($$: TouchControlViewArgs) {
    ButtonItemView({
      groupVisible:this.touchGroupVisible_($$.item.id),groupRank:this.groupRanks.get($$.item.id) ?? 0,
      nodeId:this.touchNodeId_($$.item.id),
      vis: this.getBtnVis($$.item.id),
      pressedVer: this.btnPressedVer,
      label: this.systemButtonLabel($$.item),
      x: this.itemX($$.item),
      y: this.itemY($$.item),
      w: this.itemW($$.item),
      h: this.itemH($$.item),
      fontSizeVp: this.btnFontSize($$.item),
      borderRadiusVp: this.btnBorderRadius($$.item),
      opacityVal: renderOpacity($$.item, this.profile),
      fgNormal: $$.item.style?.fg ?? '#DDFFFFFF',
      fgPressed: $$.item.style?.fg ?? '#FFFFFFFF',
      bgNormal: $$.item.style?.bg ?? '#30FFFFFF',
      bgPressed: $$.item.style?.bgPressed ?? $$.item.style?.bg ?? '#52FFFFFF',
      onTouchEvent: (event: TouchEvent) => {
        const admitted: boolean = this.admitTouchUi_(event,$$.token,$$.item.id,$$.groupEpoch ?? '0')
        // 只观察input按钮的离散边沿；MOVE和其它控件没有新增日志。准入仍只调用原实现一次。
        if ($$.item.systemAction === 'input' && event.type !== TouchType.Move) {
          this.noteImeRoute('touch-admit', this.isGrabbed ? 'chat' : 'field',
            this.appearanceGeneration, admitted, event.type)
        }
        if (admitted) this.handleButtonTouch($$.item, event)
      },
      onAccessibilityActivate: () => {
        const admitted: boolean = this.admitTouchAction_($$.token,$$.item.id,$$.groupEpoch ?? '0')
        if ($$.item.systemAction === 'input') {
          this.noteImeRoute('accessibility-admit', this.isGrabbed ? 'chat' : 'field',
            this.appearanceGeneration, admitted)
        }
        if (admitted) this.activateButtonFromAccessibility($$.item,$$.groupEpoch ?? '0')
      }
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
                this.emitDragLookVp(dx, dy, event.timestamp)
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
  /** ArkUI局部坐标是vp；只在平台入口转换一次，之后与native schema触控共同使用surface px。
   * BaseEvent.timestamp由SDK声明为系统启动后的ns，不能换成NAPI出队时钟来计算加速度。 */
  private emitDragLookVp(dx: number, dy: number, timestampNs: number): void {
    try {
      const x: number = this.getUIContext().vp2px(dx)
      const y: number = this.getUIContext().vp2px(dy)
      testNapi.sendSourceCursorSample(TOUCH_SOURCE, x, y, timestampNs)
    } catch (_) {}
  }

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
  ScrollWheelView($$: TouchControlViewArgs) {
    Stack() {
      // 视觉：纵向胶囊条，中间画一个浅浅的"双向箭头"或 ⇅ 字符
      Column() {
        Text('▲').fontSize(10 * this.profile.globalScale).fontColor('#88FFFFFF')
        Text($$.item.label).fontSize(11 * $$.item.itemScale * this.profile.globalScale).fontColor('#BBFFFFFF')
        Text('▼').fontSize(10 * this.profile.globalScale).fontColor('#88FFFFFF')
      }
      .width(this.itemW($$.item))
      .height(this.itemH($$.item))
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Center)
      .padding(4)
    }
    .width(this.itemW($$.item))
    .height(this.itemH($$.item))
    .backgroundColor('#28FFFFFF')
    .borderRadius(this.itemW($$.item) / 2)
    .id(this.touchNodeId_($$.item.id))
    .visibility(this.touchGroupVisible_($$.item.id) ? Visibility.Visible : Visibility.Hidden)
    .zIndex(this.groupRanks.get($$.item.id) ?? 0)
    .position({ x: this.itemX($$.item), y: this.itemY($$.item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，滚轮由物理 AXIS 通道处理（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      if (!this.admitTouchUi_(event,$$.token,$$.item.id,$$.groupEpoch ?? '0')) return
      // A.6 阶段3：C 接管滚轮时 ArkTS 直接不处理（滚动由 C 发）
      if (this.cOwnsScroll()) return
      // 阶段 1.5：滚轮控件——纵向 drag → 累计 dy → 每 SCROLL_STEP_VP 触发一次 scroll 事件。
      // 上滑（dy<0）发 +1（hotbar 往左切），下滑（dy>0）发 -1。
      const changed = event.changedTouches
      if (!changed || changed.length === 0) return
      const id = $$.item.id
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

  private hotbarSlotOf(item: ControlItem, localX: number, localY: number): number {
    const w = this.itemW(item)
    const h = this.itemH(item)
    // 与native共用半开有效区域合同；MOVE越界也拒绝，不能clamp成第1/9格。
    return touchHotbarSlot(localX,localY,w,h)
  }

  private sendHotbarSlot(slot: number): void {
    const key = GLFW_KEY_1 + slot
    if (!this.emitTouchKey('hotbar', key, GLFW_PRESS)) return
    // A tap still has a native held edge between the two calls.  If the
    // release is rejected (for example during a surface transition), invoke
    // the source-scoped recovery path instead of silently leaving the slot
    // key held in the external ledger.
    if (!this.emitTouchKey('hotbar', key, GLFW_RELEASE)) {
      this.forceReleaseTouchSource('hotbar-release-rejected')
      return
    }
    if (this.profile.haptic ?? true) hapticTap(6)
  }

  @Builder
  HotbarSelectorView($$: TouchControlViewArgs) {
    Row() {
      ForEach(this.hotbarZones(), (z: number) => {
        Column()
          .layoutWeight(1)
          .height('100%')
          // 首格无左分隔线，其余格画一条极淡竖线示意分区；整体保持高透明，让 MC hotbar 透出
          .border({ width: { left: z === 0 ? 0 : 0.5 }, color: '#33FFFFFF' })
      }, (z: number) => $$.item.id + '_z' + z.toString())
    }
    .width(this.itemW($$.item))
    .height(this.itemH($$.item))
    .backgroundColor('#12FFFFFF')
    .borderRadius(this.btnBorderRadius($$.item))
    .border({ width: 1, color: '#3CFFFFFF' })
    .id(this.touchNodeId_($$.item.id))
    .visibility(this.touchGroupVisible_($$.item.id) ? Visibility.Visible : Visibility.Hidden)
    .zIndex(this.groupRanks.get($$.item.id) ?? 0)
    .position({ x: this.itemX($$.item), y: this.itemY($$.item) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      // 鼠标是并列输入源，不能翻物品栏（见 isPointerSourcedTouch）。
      if (this.isPointerSourcedTouch(event)) return
      if (!this.admitTouchUi_(event,$$.token,$$.item.id,$$.groupEpoch ?? '0')) return
      // A.6 阶段3：C 接管物品栏时 ArkTS 直接不处理（切格数字键由 C 发）
      if (this.cOwnsHotbar()) return
      const changed = event.changedTouches
      if (!changed || changed.length === 0) return
      const id = $$.item.id
      if (event.type === TouchType.Down) {
        if (this.hotbarFingerId.has(id)) return
        const t = changed[0]
        const slot = this.hotbarSlotOf($$.item, t.x, t.y)
        if (slot < 0) return
        this.hotbarFingerId.set(id, t.id)
        this.hotbarLastSlot.set(id, slot)
        this.sendHotbarSlot(slot)
      } else if (event.type === TouchType.Move) {
        const owner = this.hotbarFingerId.get(id)
        if (owner === undefined) return
        const t = event.touches.find((tt: TouchObject) => tt.id === owner)
        if (!t) return
        const slot = this.hotbarSlotOf($$.item, t.x, t.y)
        if (slot < 0) { this.hotbarLastSlot.delete(id); return }
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
  DrawerView($$: TouchControlViewArgs) {
    // 主按钮（永远显示）
    Text($$.item.label || '⋯')
      .width(this.itemW($$.item))
      .height(this.itemH($$.item))
      .fontSize(16 * $$.item.itemScale * this.profile.globalScale)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .fontColor('#FFFFFF')
      .borderRadius(this.itemW($$.item) / 2)
      .backgroundColor(this.drawerOpen.get($$.item.id) ? '#88448AFF' : '#44448AFF')
      .id(this.touchNodeId_($$.item.id))
    .visibility(this.touchGroupVisible_($$.item.id) ? Visibility.Visible : Visibility.Hidden)
    .zIndex(this.groupRanks.get($$.item.id) ?? 0)
      .position({ x: this.itemX($$.item), y: this.itemY($$.item) })
      .hitTestBehavior(HitTestMode.Block)
      .animation({ duration: 200 })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .accessibilityText(effectiveLabel($$.item))
      .accessibilityDescription((this.drawerOpen.get($$.item.id) ?? false) ?
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
        if (this.admitTouchAction_($$.token,$$.item.id,$$.groupEpoch ?? '0')) this.toggleDrawer($$.item)
      })

    // 子项由共同运行投影在根层绘制，不嵌在UI抽屉之后覆盖其它系统业务控件。
  }

  /** 计算子按钮在抽屉中的位置（vp 绝对坐标）。Builder 里禁止命令式语句，所以拆出来。 */
  private drawerChildX(_parent: ControlItem, child: ControlItem, _index: number): number {
    return this.runtimeLayout.find(child.id)?.rectVp.x ?? 0
  }
  private drawerChildY(_parent: ControlItem, child: ControlItem, _index: number): number {
    return this.runtimeLayout.find(child.id)?.rectVp.y ?? 0
  }

  // 方案 E.2：抽屉子按钮同样复用 ButtonItemView（btnPressedVer + @Prop 刷新），触摸回调 handleDrawerChildTouch。
  @Builder
  DrawerChild($$: TouchDrawerChildArgs) {
    ButtonItemView({
      groupVisible:this.touchGroupVisible_($$.item.id),groupRank:this.groupRanks.get($$.item.id) ?? 0,
      nodeId:this.touchNodeId_($$.item.id),
      vis: this.getBtnVis($$.item.id),
      pressedVer: this.btnPressedVer,
      label: effectiveLabel($$.item),
      x: this.drawerChildX($$.parent, $$.item, $$.index),
      y: this.drawerChildY($$.parent, $$.item, $$.index),
      w: this.itemW($$.item),
      h: this.itemH($$.item),
      fontSizeVp: this.btnFontSize($$.item),
      borderRadiusVp: this.btnBorderRadius($$.item),
      opacityVal: renderOpacity($$.item, this.profile),
      fgNormal: $$.item.style?.fg ?? '#DDFFFFFF',
      fgPressed: $$.item.style?.fg ?? '#FFFFFFFF',
      bgNormal: $$.item.style?.bg ?? '#30FFFFFF',
      bgPressed: $$.item.style?.bgPressed ?? $$.item.style?.bg ?? '#52FFFFFF',
      onTouchEvent: (event: TouchEvent) => { if (this.admitTouchUi_(event,$$.token,$$.item.id,$$.groupEpoch ?? '0')) this.handleDrawerChildTouch($$.item, event) },
      onAccessibilityActivate: () => { if (this.admitTouchAction_($$.token,$$.item.id,$$.groupEpoch ?? '0')) this.activateButtonFromAccessibility($$.item,$$.groupEpoch ?? '0') }
    })
  }

  /**
   * 抽屉孩子仍由ArkTS解释，但普通按钮已有的多指持有、拖动瞄准和释放记录不能因嵌套丢失。
   * 共用普通按钮入口；cOwnsButton只查顶层，因此这里不会把孩子错误交给Native，也不会重复发视角增量。
   */
  private handleDrawerChildTouch(c: ControlItem, event: TouchEvent): void {
    this.handleButtonTouch(c, event)
  }

  private itemPxCenterX(c: ControlItem): number {
    return this.itemX(c) + this.itemW(c) / 2
  }
  private itemPxCenterY(c: ControlItem): number {
    return this.itemY(c) + this.itemH(c) / 2
  }

  /** 提示层使用应用vp尺寸，即使游戏GUI变成1档也保持可操作；仅明确选择恢复才调用游戏设置桥。 */
  @Builder
  GuiSizeHint($$: TouchOverlayViewArgs) {
    Column({space:12}) {
      Text('界面大小较小').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').width('100%')
      Text(this.guiMessage).fontSize(16).fontColor('#CBD7E6').maxLines(3).layoutWeight(1).width('100%')
      Row({space:8}) {
        Button('继续保留').fontSize(16).height(48).layoutWeight(1).backgroundColor('#364356')
          .enabled(this.restorePending===0)
          .onClick((): void => {
            // UI快捷动作也属于本次呈现的publication；不能让旧提示节点在新Native表上改变准入/设置。
            if (!this.admitTouchAction_($$.token)) return
            this.guiGuard.keep(this.guiState); this.guiHint=false; this.registerRegions()
          })
        if(this.guiState.canRestore && this.guiGuard.canRestore) {
          Button(this.restorePending>0 ? '恢复中' : '恢复大小').fontSize(16).height(48).layoutWeight(1)
            .enabled(this.restorePending===0).onClick((): void => {
              if (this.admitTouchAction_($$.token)) this.restoreGui()
            })
        } else {
          Button('精细鼠标').fontSize(16).height(48).layoutWeight(1)
            .onClick((): void => {
              if (!this.canOpenMouse_($$.token)) return
              this.guiHint=false; this.openMouse($$.token)
            })
        }
      }.width('100%')
    }.width(this.touchOverlay_('gui-hint').rectVp.width).height(this.touchOverlay_('gui-hint').rectVp.height).padding(16)
      .backgroundColor('#F218202B').borderRadius(16).border({width:1,color:'#5576A3D9'})
      .id(this.touchNodeId_(this.touchOverlay_('gui-hint').id))
      .position({x:this.touchOverlay_('gui-hint').rectVp.x,y:this.touchOverlay_('gui-hint').rectVp.y}).hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent): void => { event.stopPropagation() })
  }

  /** 选择页没有子编辑器替宿主结束事务，必须确认取消后才能释放最后的租约。 */
  private async closeEditorChoice_(): Promise<void> {
    if (!this.mounted || !this.editing || this.editorMode!=='choose' || this.editorChoiceBusy) return
    const appearance: number=this.appearanceGeneration
    this.editorChoiceBusy=true
    try {
      if (!(await getLayoutStore().restoreEditorTransaction())) throw new Error('原编辑事务恢复未确认')
      if (this.mounted && appearance===this.appearanceGeneration) this.finishEditor_(null)
    } catch(error) { this.showEditorError_('关闭操控菜单失败：'+(error as Error).message) }
    finally { if (appearance===this.appearanceGeneration) this.editorChoiceBusy=false }
  }

  /** 游戏中复用同一隔离租约；选择任务不写盘，关闭选择页也不产生方案副本。 */
  @Builder
  EditorOverlay() {
    if (this.editorMode==='choose') {
      Column({space:12}) {
        Text('操控').fontSize(20).fontColor('#FFFFFF')
        Button('编辑按键布局').height(48).width('100%').onClick((): void => { this.editorMode='layout' })
        Button('触控与输入设置').height(48).width('100%').onClick((): void => { this.editorMode='settings' })
        Button('关闭').height(48).width('100%').onClick((): void => { this.closeEditorChoice_() })
      }.padding(20).width(Math.min(360,this.compWidth-24)).backgroundColor('#14201F').borderRadius(16).enabled(!this.editorChoiceBusy)
    } else if (this.editorMode==='settings') {
      InputSettingsEditor({targetProfileName:this.profile.name,screenWidth:this.compWidth,screenHeight:this.compHeight,
        resolvedActionKeys:this.touchSession.actionKeys(),gyroscopeStatus:this.touchSession.gyroscopeStatus(),
        onDone:(result: LayoutProfile | null): void => { this.finishEditor_(result) },
        onInitializationFailed:(message: string): void => { this.editorInitializationFailed_(message) }})
    } else {
      LayoutEditor({targetProfileName:this.profile.name,canRestoreGroups:true,
        screenWidth:this.compWidth,screenHeight:this.compHeight,gameGui:this.guiState,
        onRestoreGroups:(): void => {
          // 这是用户新发起的恢复意图，必须舍弃上次未知回执的序号；维护循环仍重试自己的原身份。
          this.groupRestoreRequested=true
          this.groupRestoreSequence=''
        },
        onDone:(result: LayoutProfile | null): void => { this.finishEditor_(result) },
        onInitializationFailed:(message: string): void => { this.editorInitializationFailed_(message) }})
    }
  }
}

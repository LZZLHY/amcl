/**
 * 虚拟按键布局编辑器：只维护控件、触控组、位置外观和编辑手势。
 * 输入策略/手柄在独立设置页编辑，目录管理由方案库承担；本组件不开草稿试用。
 * 使用V1响应状态绘制，LayoutEditSession保存完整撤销快照，LayoutStore确认持久提交。
 * 编辑草稿带原实体ID/revision，取消或销毁等待在途结果后收口；系统控件与锁定项保持原保护。
 */
import {
  ControlItem, ControlType, LayoutProfile, AlignGroup,
  TriggerMode, VisibilityOverride, effectiveKeys, MAX_LAYOUT_CONTROL_KEYS,
  cloneItem as cloneControlItem, cloneItemWithFreshIds, generateControlId, validateAndNormalizeLayout,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_JOYSTICK_DEAD_ZONE,
  DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  LAYOUT_PROFILE_VERSION, SOURCE_LOOK_PROFILE_VERSION,
  SourceLookPreferences, LookPolicySource, LookParameters, copySourceLookPreferences,
  copyLookParameters, splitLegacyLookPolicy, sourceLookParameters,
  GamepadConfig, GamepadAction, StickRole,
  defaultGamepadConfig, defaultGamepadButtonMap,
  DEFAULT_GAMEPAD_DEAD_ZONE, DEFAULT_TRIGGER_THRESHOLD,
  DEFAULT_BUTTON_SIZE, DEFAULT_BUTTON_OPACITY, DEFAULT_CORNER_RADIUS,
  DEFAULT_GLOBAL_OPACITY,
  effectiveCornerRadius, effectiveOpacity, effectiveLabel, ControlStyle,
  ControlScene, controlScene, setControlScene
} from 'gamecontrol';
import { glfwKeyName, GLFW_KEY_G, GLFW_KEY_SPACE, GLFW_KEY_LEFT_SHIFT, GLFW_KEY_E, GLFW_KEY_ESCAPE } from 'gamecontrol';
import { makeHotbarSelector, computeAutoGuiScale, computeHotbarRectPx } from 'gamecontrol';
import { GameGuiState, projectGameHotbar } from 'gamecontrol'
import { DEFAULT_SNAP_GAP, DEFAULT_SNAP_STRENGTH } from 'gamecontrol';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { KeyPickerSheet } from './KeyPickerSheet';
import { getLayoutStore } from 'gamecontrol';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { TouchConfiguration, normalizeTouchPreferences } from 'gamecontrol';
import { LayoutEditSession, LayoutEditCheckpoint, getDefaultLayout } from 'gamecontrol';
import { EditorTheme } from './TouchEditorTheme';
import { ControlGroup, ControlGroupAction, ControlPhaseBinding, ControlActionPhase, ControlGroupOperation,
  cloneControlGroups, enableLayoutControlGroups, duplicateLayoutControlGroup, removeLayoutControlGroup,
  CONTROL_GROUP_PROFILE_VERSION, TOUCH_PHASE_CAPABILITY, MAX_CONTROL_GROUPS } from 'gamecontrol';

// 撤销栈最大深度

// 已锁定的吸附阈值 → 脱离阈值倍数：脱离阈值 = SNAP_IN × 此值，形成黏滞防抖（横对齐后左右滑动
// 时的垂直小抖动 < 脱离阈值就不会掉出对齐高度）。
const SNAP_OUT_RATIO: number = 2.4

/** 添加目录只有原有普通按钮与物品栏；常用键只是普通按钮的初始绑定，不扩展控件类型。 */
interface EditorAddControlOption {
  id: string
  title: string
  description: string
  search: string
  icon: AppIconName
  common: boolean
  code?: number
}

/** 自动吸附返回值（必须是 interface 而非内联对象字面量类型，ArkTS 严格模式要求） */
interface SnapResult {
  x: number
  y: number
}

/**
 * 单轴对齐候选线。line = 该参考点应落到的目标坐标；refOffset = 拖动控件左上角到其参考点的偏移
 * （左/上=0、中=尺寸/2、右/下=尺寸）；draw = 要绘制的虚线坐标。
 */
interface AlignCandidate {
  line: number
  refOffset: number
  draw: number
}

/** 某一轴当前锁定的对齐线（滞回状态）。 */
interface AxisLock {
  line: number
  refOffset: number
  draw: number
}

/** 单轴吸附解算结果。coord = 吸附后的左上角坐标；guide = 虚线坐标（-1 无）；lock = 新的锁定态。 */
interface AxisSnap {
  coord: number
  guide: number
  lock: AxisLock | null
}


// UI 重绘 2026-07-11 修复：操作 chip 改为独立 @Component。
// 原因：原先 ActionChip 是带参数的 @Builder，label/bg 按值传入 —— ArkUI 对"按值参数 @Builder"的内容
// 不会随状态变化重渲染，导致点「触发/场景/显示/瞄准/锁定」等 chip 后循环出的新状态**在 UI 上不更新**
// （底层值已变、statusMsg 也变，唯独 chip 文字/底色不刷新）。改成 @Component + @Prop 后，父级传入的
// label/bg 变化会可靠触发本组件重渲染。
@Component
struct EditorChip {
  @Prop icon: AppIconName
  @Prop label: string
  @Prop bg: string
  onTap: () => void = () => {}

  build() {
    Row({ space: 4 }) {
      AppIcon({ name: this.icon, iconSize: 16, color: EditorTheme.text })
      Text(this.label).fontSize(14).fontColor(EditorTheme.text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(44)
    .padding({ left: 11, right: 11 })
    .backgroundColor(this.bg)
    .borderRadius(12)
    .justifyContent(FlexAlign.Center)
    .margin(1)
    .onClick(() => { this.onTap() })
  }
}

@Component
export struct LayoutEditor {
  @Prop targetProfileName: string = ''
  private editSession: LayoutEditSession = new LayoutEditSession()
  /** 只有游戏宿主能恢复本局组显隐；独立方案编辑不操作运行态。 */
  @Prop canRestoreGroups: boolean = false
  /** 真正编辑流程中的就地提示；保存/取消仍完全走既有事务，不由教学代为修改。 */
  @State private showLeaveConfirm: boolean = false
  @State private positionXDraft: string = ''
  @State private positionYDraft: string = ''
  @State private positionWidthDraft: string = ''
  @State private positionHeightDraft: string = ''
  /** 只保存触控设置的导航分区，子组件Link回传选择；不成为另一份触控配置。 */
  /** 只关闭引导观察与提示；不保存、退出编辑器或提前归还编辑器的输入暂停租约。 */
  onDone: (profile: LayoutProfile | null) => void = () => {}
  /** 请求宿主在退出编辑、恢复准入后重置运行组态，不写初始定义或直接调用 Native。 */
  onRestoreGroups: () => void = (): void => {}
  /** 进入失败与保存/取消成功分开通知；游戏宿主据此撤销 native 触控暂停。 */
  onInitializationFailed: (message: string) => void = () => {}
  @Prop screenWidth: number = 720
  @Prop screenHeight: number = 360
  @Prop gameGui: GameGuiState = new GameGuiState()
  @Prop resolvedActionKeys: number[] = []
  @Prop gyroscopeStatus: string = 'unknown'

  // ---- 核心数据 ----
  @State controls: ControlItem[] = []
  @State private controlGroups: ControlGroup[] | undefined = undefined
  private defaultControlGroupId: string | undefined = undefined
  private requiredCapabilities: string[] | undefined = undefined
  @State private currentControlGroup: string = ''
  @State private previewControlGroups: string[] = []
  @State private groupNameDraft: string = ''
  @State private groupSearch: string = ''
  @State private deletingGroup: string = ''
  @State private groupActionPhase: ControlActionPhase = 'press'
  @State private groupActionOperation: ControlGroupOperation = 'toggle'
  /** 原数组下标只用于本次选择；未选择时新增一行动作，不合并现有行。 */
  @State private selectedGroupActionIndex: number = -1
  @State private phaseKeyPicker: boolean = false
  private phaseKeyControlId: string = ''
  private phaseKeyPhase: ControlActionPhase = 'press'
  @State globalScale: number = 1.0
  @State profileName: string = '默认'
  /** 草稿绑定读取时的实体及修订，保存不能根据旧名字复活已删除/改名的方案。 */
  private editingProfileId: string | undefined = undefined
  private editingProfileRevision: number | undefined = undefined
  @State lookSensitivity: number = DEFAULT_LOOK_SENSITIVITY
  @State invertY: boolean = DEFAULT_INVERT_Y
  // 方案 C（2026-07-11）：视角平滑 α + 加速强度
  @State lookSmoothing: number = DEFAULT_LOOK_SMOOTHING
  @State lookAccel: number = DEFAULT_LOOK_ACCEL
  /** 显式迁移草稿；undefined保留旧全来源，选中来源只是编辑器偏好不参与运行政策。 */
  @State lookPolicies: SourceLookPreferences | undefined = undefined
  @State selectedLookSource: LookPolicySource = 'touch'
  @State joystickDeadZone: number = DEFAULT_JOYSTICK_DEAD_ZONE
  @State haptic: boolean = true
  @State touch: TouchConfiguration = new TouchConfiguration()
  @State targetDevice: string = 'any'
  // 2026-05-30：全局透明度（0.1..1.0）。
  @State globalOpacity: number = DEFAULT_GLOBAL_OPACITY
  // 物品栏 selector 的一次性自动注入标志；必须跟随编辑器加载/保存，删除后才不会被下次启动复活。
  @State hotbarAutoAdded: boolean = false
  // R5：手柄配置（v3）。深拷贝自 profile.gamepad，缺省走 defaultGamepadConfig()。
  @State gamepad: GamepadConfig = defaultGamepadConfig()

  // ---- 多选（2026-07-16）----
  // 多选模式：开启后点按钮=切换选中（累积），可对多个按钮批量对齐/等间距/改样式/删除。
  // 会话态，不持久化；退出多选或退出编辑器复位。
  @State multiSelectMode: boolean = false
  // 多选集合（按 id，避免删除后下标错位）。插入顺序即选中先后，末项为"主项"（样式滑条初值取它）。
  @State selectedIds: string[] = []
  // 多选成组拖动：拖任一选中项时所有选中项按相同位移整体移动（v1 不吸附，保证可预期）。
  @State groupDragging: boolean = false
  @State groupDragDx: number = 0
  @State groupDragDy: number = 0

  // ---- UI 状态 ----
  @State selectedIdx: number = -1          // 当前选中的 controls 下标，-1 无选中
  @State selectedScaleVal: number = 100    // 选中按钮 itemScale * 100
  @State globalScaleVal: number = 100      // globalScale * 100
  @State globalOpacityVal: number = 100    // globalOpacity * 100
  @State selectedOpacityVal: number = 100  // 选中按钮 opacity * 100（一级/二级共用，保持相等）
  @State sensVal: number = 100             // lookSensitivity * 100
  @State smoothVal: number = 60            // 方案 C：lookSmoothing(α) * 100（越大越跟手）
  @State accelVal: number = 0              // 方案 C：lookAccel * 100
  @State deadZoneVal: number = 18          // joystickDeadZone * 100
  @State ver: number = 0                   // 递增版本号，ForEach key 含此值以强制重渲染
  @State showPanel: boolean = true         // 工具面板可见性
  // 重构 2026-07-16：编辑器只保留**唯一一个面板**（原工具面板 + 所有设置浮层整合于此），
  // activeSheet 表示当前 Tab（面板常驻，靠 showPanel 收起/展开；不再有任何独立浮层）。
  //   'edit'（编辑：添加/选中/全局缩放+批量横幅）| 'style'（样式，含标签）| 'global'（视角+吸附设置）
  //   | 'gamepad'（手柄）| 'profiles'（方案）| 'multi'（多选批量）
  @State activeSheet: string = 'edit'
  /** 添加面板的会话搜索，不持久化、不进入布局内容签名或撤销快照。 */
  @State showKeyPicker: boolean = false    // 改键 sheet 显隐
  @State labelDraft: string = ''
  /** 只为当前32条创建选择UI，全部目录通过翻页与当前方案定位可达。 */
  @State statusMsg: string = ''            // 一行轻量提示
  @State undoCount: number = 0             // 仅用于按钮禁用状态触发刷新

  // ---- 按钮拖拽 ----
  @State dragIdx: number = -1
  @State dragDx: number = 0
  @State dragDy: number = 0
  private dragStartXPct: number = 0
  private dragStartYPct: number = 0

  // ---- 自动对齐 / 吸附（2026-07-16）----
  // 设置项（持久化到 profile）：总开关、相邻间距 vp、灵敏度 vp。
  @State snapEnabled: boolean = true
  @State snapGap: number = DEFAULT_SNAP_GAP
  @State snapStrength: number = DEFAULT_SNAP_STRENGTH
  // 拖动时要绘制的对齐虚线坐标（-1 = 不画）。竖线固定 X、横线固定 Y。
  @State guideX: number = -1
  @State guideY: number = -1
  // 每轴当前锁定的对齐线（滞回：进入用 SNAP_IN、脱离用 SNAP_IN×SNAP_OUT_RATIO）。
  private lockX: AxisLock | null = null
  private lockY: AxisLock | null = null

  // ---- 面板拖动（主工具面板）----
  @State panelX: number = -1   // -1 表示未初始化，aboutToAppear 中设置
  @State panelY: number = -1
  @State panelDragDx: number = 0
  @State panelDragDy: number = 0
  private panelDragStartX: number = 0
  private panelDragStartY: number = 0

  // ---- 撤销栈 ----
  // 每次 commit（拖拽 / 缩放 / 改键 / 切显隐 等）前快照 controls 及随控件增删变化的注入标志。
  private sliderUndoKey: string = ''

  /** 持久化期间串行操作并冻结手势，避免保存的快照落后于用户仍在修改的草稿。 */
  @State private persistenceBusy: boolean = false
  private editorMounted: boolean = false
  private editorReady: boolean = false
  private editorClosed: boolean = false
  private editorGeneration: number = 0
  private editorLeaseHeld: boolean = false
  private editorTransactionOwned: boolean = false
  /** 方案目录操作也属于本次未确认事务；只在离开请求时检查，不在渲染或逐帧路径序列化方案。 */
  private sessionCatalogChanged: boolean = false
  private persistenceTask: Promise<void> | undefined = undefined
  private editorCleanupTask: Promise<void> | undefined = undefined
  private restorationTask: Promise<void> | undefined = undefined

  async aboutToAppear(): Promise<void> {
    this.editorMounted = true
    this.editorClosed = false
    this.editorReady = false
    this.sessionCatalogChanged = false
    this.persistenceBusy = true
    const generation: number = ++this.editorGeneration
    const store = getLayoutStore()
    try {
      const previousCleanup: Promise<void> | undefined = this.editorCleanupTask
      if (previousCleanup !== undefined) await previousCleanup
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.editorCleanupTask = undefined
      this.restorationTask = undefined
      this.persistenceTask = undefined
      await store.waitReady()
      if (!this.editorMounted || generation !== this.editorGeneration) return
      if (!store.beginEditorSession()) throw new Error('布局正在同步，请稍后再试')
      this.editorLeaseHeld = true
      store.beginEditorTransaction()
      this.editorTransactionOwned = true
      const target: LayoutProfile | null=this.targetProfileName.length>0 ? store.getProfile(this.targetProfileName) : store.getActiveProfile()
      if (target===null) throw new Error('方案已删除，请重新选择')
      this.loadConfirmedProfile_(target)
      // 宽屏停靠侧边保留画布，窄屏居中；从顶部利用可用高度，不再把长表单从屏幕中央向下堆。
      this.panelX = this.screenWidth>=900 ? this.screenWidth-this.panelWidth()-16 : (this.screenWidth-this.panelWidth())/2
      this.panelY = 12
      this.editorReady = true
    } catch (error) {
      this.reportPersistenceError_('进入编辑器', error as Error)
      await this.restoreUnfinishedEditor_()
      if (this.editorMounted && generation === this.editorGeneration) {
        try { this.onInitializationFailed(this.statusMsg) }
        catch (callbackError) { this.reportPersistenceError_('通知编辑器进入失败', callbackError as Error) }
      }
    } finally {
      if (this.editorMounted && generation === this.editorGeneration) this.persistenceBusy = false
    }
  }

  /**
   * 组件销毁等价于放弃未确认的编辑事务；先等已发出的存储操作完成，再恢复进入基线。
   * 这段续体不更新已销毁的 @State、不发 onDone；租约保留到回滚结束，防止父导入抢写。
   */
  aboutToDisappear(): void {
    this.editorMounted = false
    this.editorGeneration++
    if (this.editorCleanupTask === undefined) this.editorCleanupTask = this.cleanupDestroyedEditor_()
  }

  private async cleanupDestroyedEditor_(): Promise<void> {
    const pending: Promise<void> | undefined = this.persistenceTask
    if (pending !== undefined) await pending
    await this.restoreUnfinishedEditor_()
  }

  /** 仅成功恢复才能清除事务所有权；失败由 Store 保留真实草稿保护，下一次可重试。 */
  private restoreUnfinishedEditor_(): Promise<void> {
    const existing: Promise<void> | undefined = this.restorationTask
    if (existing !== undefined) return existing
    const task: Promise<void> = this.restoreUnfinishedEditorOnce_()
    this.restorationTask = task
    return task
  }

  private async restoreUnfinishedEditorOnce_(): Promise<void> {
    try {
      if (this.editorTransactionOwned && !this.editorClosed) {
        if (!(await getLayoutStore().restoreEditorTransaction())) throw new Error('恢复进入编辑器前的布局失败')
        this.editorTransactionOwned = false
      }
    } catch (error) {
      this.reportPersistenceError_('恢复原布局', error as Error)
    } finally {
      this.releaseEditorLease_()
    }
  }

  /** 每个组件只归还自己的嵌套租约，完成通知和销毁先后到达也不会重复递减。 */
  private releaseEditorLease_(): void {
    if (!this.editorLeaseHeld) return
    this.editorLeaseHeld = false
    getLayoutStore().endEditorSession()
  }

  /** 错误保留在原状态条；失败不覆盖 controls/gamepad 等当前草稿，也不触发成功回调。 */
  private reportPersistenceError_(action: string, error: Error): void {
    const message: string = action + '失败：' + error.message + '。未确认保存，请重试或取消。'
    hilog.error(0x0000, 'LayoutEditor', '%{public}s', message)
    if (this.editorMounted) this.statusMsg = message
  }

  /**
   * 统一串行入口；UI callback 只发请求，所有 Promise 拒绝在此收口。
   * 操作持有发起时的代次：同一组件重新出现会恢复 mounted，旧续体仍不得提交或关闭新编辑器。
   */
  private runPersistence_(action: string, operation: (generation: number) => Promise<void>, requireReady: boolean = true): void {
    if (!this.editorMounted || this.editorClosed || this.persistenceBusy) return
    if (requireReady && !this.editorReady) {
      this.reportPersistenceError_(action, new Error('编辑器尚未就绪'))
      return
    }
    this.persistenceBusy = true
    this.persistenceTask = this.performPersistence_(action, operation, this.editorGeneration)
  }

  private async performPersistence_(action: string, operation: (generation: number) => Promise<void>,
    generation: number): Promise<void> {
    try {
      await operation(generation)
    } catch (error) {
      if (generation === this.editorGeneration) this.reportPersistenceError_(action, error as Error)
      else hilog.error(0x0000, 'LayoutEditor', '已离开的编辑事务失败：%{public}s', (error as Error).message)
    } finally {
      // 新一代可能正等旧 cleanup，旧 finally 不能提前解冻其操作入口。
      if (this.editorMounted && generation === this.editorGeneration) this.persistenceBusy = false
    }
  }

  /** 成功持久化后载入新方案；其身份和内容已确认，才更新当前草稿与设备基线。 */
  private loadConfirmedProfile_(profile: LayoutProfile, clearUndo: boolean = true): void {
    if (validateAndNormalizeLayout(profile) === null) throw new Error('存储返回的布局数据非法')
    this.editSession.open(profile)
    this.loadProfile(profile, clearUndo)
    this.baselineSig = this.contentSignature()
  }

  /** onDone 只发送一次；异常通知不反过来把已提交存储报告为保存失败。 */
  private completeEditor_(profile: LayoutProfile | null): void {
    if (!this.editorMounted || this.editorClosed) return
    this.editorClosed = true
    this.editorTransactionOwned = false
    this.releaseEditorLease_()
    try { this.onDone(profile) }
    catch (error) {
      const message: string = '布局结果已确认，但关闭编辑器失败：' + (error as Error).message
      hilog.error(0x0000, 'LayoutEditor', '%{public}s', message)
      if (this.editorMounted) this.statusMsg = message
    }
  }

  /** 保存的 profile 是点击时的完整快照；成功后才提交事务，失败保持草稿和编辑器。 */
  private saveEditor_(): void {
    this.runPersistence_('保存布局', async (generation: number): Promise<void> => {
      const store = getLayoutStore()
      const result: LayoutProfile | null = this.buildProfile()
      if (result === null) throw new Error('布局数据非法，已拒绝保存')
      if (this.contentSignature() !== this.baselineSig) {
        result.targetDevice = store.getCurrentDeviceType() === 'tablet' ? 'tablet' : 'phone'
      }
      const saved: LayoutProfile | null=await store.saveEditedProfile(result)
      if (saved===null) throw new Error('方案已更改、删除，或布局能力/预算不符，请重新载入后编辑')
      // 页面已离开时由销毁收口恢复原事务，不让迟到保存关闭下一次编辑界面。
      if (!this.editorMounted || generation !== this.editorGeneration) return
      store.commitEditorTransaction()
      this.completeEditor_(saved)
    })
  }

  /** 取消必须等上一事务恢复被确认；false/reject 都留下当前草稿并允许再次取消。 */
  private cancelEditor_(): void {
    this.runPersistence_('取消编辑', async (generation: number): Promise<void> => {
      if (this.editorTransactionOwned && !(await getLayoutStore().restoreEditorTransaction())) {
        throw new Error('原布局尚未恢复')
      }
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.completeEditor_(null)
    }, false)
  }

  /** 重置成功才记撤销点和替换草稿；失败不制造假“已重置”或多余撤销记录。 */


  /** 方案切换、新建、删除同样等待 Store 持久确认；失败保留当前选中方案和草稿。 */




  /** 期望名只是建议：存储会为重名追加“副本”后缀，选中与提示都以返回方案的实际名字为准。 */


  /** 根据可用画布选择侧栏/窄屏面板宽度，避免把完整设置强塞到固定300vp。 */
  private panelWidth(): number {
    return Math.max(160,Math.min(this.screenWidth-24,this.screenWidth>=900 ? 420 : 380))
  }

  /** 低高度横屏把导航并入滚动区，保留拖动条和底栏，不能让增大的字号把保存按钮挤出屏幕。 */
  private compactPanel(): boolean { return this.screenHeight<400 }
  /** 与ToolPanel的两种结构同步计算，紧凑布局中的标题和Tab不再占固定高度。 */
  private panelChromeH(): number {
    // 标题兼拖动条56vp、导航108vp、底栏64vp；低高度把导航放入唯一滚动区。
    return this.compactPanel() || this.activeSheet === 'add' ? 56 + 64 + 8 : 56 + 108 + 64 + 8
  }
  /** Scroll 内容最小高度（保证面板可用，且骨架 + 此值 + 顶边 <= 屏高时底栏一定可见）。 */
  private panelMinContentH(): number { return Math.min(90,Math.max(0,this.screenHeight-this.panelChromeH()-20)) }
  /** 面板顶部允许的最大 y：再往下拖会导致底栏越出屏幕，故到此为止。 */
  private panelMaxTop(): number {
    const maxTop = this.screenHeight - (this.panelChromeH() + this.panelMinContentH() + 8)
    return maxTop < 0 ? 0 : maxTop
  }
  /** 面板当前（已提交）顶部 y。 */
  private panelTopBase(): number {
    return this.panelY >= 0 ? this.panelY : 12
  }

  /**
   * 工具面板 Scroll 内容的最大高度。用"实时"顶部（含拖动位移）计算——面板往下移动时内容区随之
   * 收缩、靠滚动阅读，从而**整块面板（含常驻底栏）始终不越出屏幕、底栏永不被截断**。
   */
  private panelContentMaxH(): number {
    const liveTop = this.panelTopBase() + this.panelDragDy
    const h = this.screenHeight - liveTop - this.panelChromeH() - 8
    return h < this.panelMinContentH() ? this.panelMinContentH() : h
  }

  // ============= 数据加载 / 保存 =============

  // 从 LayoutProfile 对象加载到 @State。恢复路径也先过统一校验，拒绝把坏数据带进编辑状态。
  private loadProfile(p: LayoutProfile, clearUndo: boolean = true): void {
    const normalized = validateAndNormalizeLayout(p)
    if (!normalized) {
      this.statusMsg = '布局数据非法，已拒绝加载'
      return
    }
    this.controls = normalized.controls.map((c: ControlItem) => cloneControlItem(c))
    this.controlGroups = cloneControlGroups(normalized.controlGroups)
    this.defaultControlGroupId = normalized.defaultControlGroupId
    this.requiredCapabilities = normalized.requiredCapabilities?.slice()
    if (clearUndo) { this.currentControlGroup=''; this.previewControlGroups=[] }
    this.repairEditorGroups_()
    this.globalScale = normalized.globalScale
    this.profileName = normalized.name
    this.editingProfileId = normalized.profileId
    this.editingProfileRevision = normalized.profileRevision
    this.lookSensitivity = normalized.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY
    this.invertY = normalized.invertY ?? DEFAULT_INVERT_Y
    this.lookSmoothing = normalized.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING
    this.lookAccel = normalized.lookAccel ?? DEFAULT_LOOK_ACCEL
    this.lookPolicies = copySourceLookPreferences(normalized.lookPolicies)
    this.joystickDeadZone = normalized.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE
    this.haptic = normalized.haptic ?? true
    this.touch = normalizeTouchPreferences(normalized.touch) ?? new TouchConfiguration()
    this.targetDevice = normalized.targetDevice ?? 'any'
    this.globalOpacity = normalized.globalOpacity ?? DEFAULT_GLOBAL_OPACITY
    this.hotbarAutoAdded = normalized.hotbarAutoAdded ?? false
    this.snapEnabled = normalized.snapEnabled ?? true
    this.snapGap = normalized.snapGap ?? DEFAULT_SNAP_GAP
    this.snapStrength = normalized.snapStrength ?? DEFAULT_SNAP_STRENGTH
    // R5：加载手柄配置（深拷贝，缺省用默认）
    this.gamepad = this.cloneGamepad(normalized.gamepad)
    this.globalScaleVal = Math.round(normalized.globalScale * 100)
    this.globalOpacityVal = Math.round(this.globalOpacity * 100)
    this.sensVal = Math.round(this.lookSensitivity * 100)
    this.smoothVal = Math.round(this.lookSmoothing * 100)
    this.accelVal = Math.round(this.lookAccel * 100)
    this.syncLookSliders()
    this.deadZoneVal = Math.round(this.joystickDeadZone * 100)
    this.selectedIdx = -1
    this.selectedScaleVal = 100
    this.selectedOpacityVal = 100
    if (clearUndo) {
      this.undoCount = 0
    }
    this.sliderUndoKey = ''
    this.ver++
  }

  // 编辑基线内容签名（进入编辑器 / 切换方案时记录）。用于"仅在真正改动过布局时才把 targetDevice
  // 归位为当前设备类型"——纯查看后保存不应把手机布局误标成平板。
  private baselineSig: string = ''

  /** 方案内容签名：忽略 targetDevice / deviceModel（这俩不算"布局内容"改动）。buildProfile 失败返回空串。 */








  /**
   * 配置按语义去重；滑条结束即使值未再变化也必须收口本次撤销组，下次手势才有独立恢复点。
   * 模式由真实Slider回调传入；普通开关仍按一次操作压一份快照。
   */


  private contentSignature(): string {
    const p = this.buildProfile()
    if (!p) return ''
    const clone: LayoutProfile = JSON.parse(JSON.stringify(p)) as LayoutProfile
    clone.targetDevice = 'any'
    clone.deviceModel = ''
    return JSON.stringify(clone)
  }

  // 从 @State 组装方案后立即规范化。返回 null 表示整份方案拒绝保存，不做静默夹取或部分保存。
  private buildProfile(): LayoutProfile | null {
    const candidate: LayoutProfile = {
      version: this.controlGroups !== undefined ? CONTROL_GROUP_PROFILE_VERSION :
        (this.lookPolicies === undefined ? LAYOUT_PROFILE_VERSION : SOURCE_LOOK_PROFILE_VERSION),
      controlGroups: cloneControlGroups(this.controlGroups),
      defaultControlGroupId: this.defaultControlGroupId,
      requiredCapabilities: this.requiredCapabilities?.slice(),
      profileId: this.editingProfileId,
      profileRevision: this.editingProfileRevision,
      name: this.profileName,
      globalScale: this.globalScale,
      lookSensitivity: this.lookSensitivity,
      invertY: this.invertY,
      lookSmoothing: this.lookSmoothing,
      lookAccel: this.lookAccel,
      lookPolicies: copySourceLookPreferences(this.lookPolicies),
      joystickDeadZone: this.joystickDeadZone,
      haptic: this.haptic,
      touch: normalizeTouchPreferences(this.touch),
      globalOpacity: this.globalOpacity,
      targetDevice: this.targetDevice as 'phone' | 'tablet' | 'foldable' | 'any',
      isPreset: false,  // 编辑器永远输出非预设
      // 在方案上编辑保存 → 同步为当前设备型号（导入他机方案后编辑即自动更新此字段）。
      deviceModel: this.currentDeviceModel(),
      hotbarAutoAdded: this.hotbarAutoAdded,
      snapEnabled: this.snapEnabled,
      snapGap: this.snapGap,
      snapStrength: this.snapStrength,
      gamepad: this.cloneGamepad(this.gamepad),
      controls: this.controls.map((c: ControlItem) => cloneControlItem(c))
    }
    return validateAndNormalizeLayout(candidate)
  }

  /** 当前设备型号（deviceInfo.marketName 优先，回退 productModel）。失败返回空串。 */
  private currentDeviceModel(): string {
    try {
      const m = deviceInfo.marketName
      if (m !== undefined && m !== null && m.length > 0) return m
      const pm = deviceInfo.productModel
      return (pm !== undefined && pm !== null) ? pm : ''
    } catch (e) {
      return ''
    }
  }

  /** R5：深拷贝手柄配置；undefined → defaultGamepadConfig()。 */
  private cloneGamepad(g: GamepadConfig | undefined): GamepadConfig {
    if (!g) return defaultGamepadConfig()
    let buttonMap: Record<string, GamepadAction> = {}
    const src = g.buttonMap ?? defaultGamepadButtonMap()
    const keys = Object.keys(src)
    for (let i = 0; i < keys.length; i++) {
      const a = src[keys[i]]
      buttonMap[keys[i]] = { kind: a.kind, code: a.code }
    }
    return {
      enabled: g.enabled ?? true,
      buttonMap: buttonMap,
      leftStick: g.leftStick ?? 'move',
      rightStick: g.rightStick ?? 'look',
      stickDeadZone: g.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE,
      triggerThreshold: g.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD,
      lookScale: g.lookScale ?? 1.0
    }
  }

  // 强制 ForEach 全量刷新（修改 controls 数组引用 + ver）
  private refreshControls(): void {
    this.controls = this.controls.map((c: ControlItem) => cloneControlItem(c))
    this.ver++
  }

  // ============= 撤销栈 =============

  /** 在做任何修改前调用，把当前 controls 快照 push 到撤销栈。 */
  private pushUndo(): void {
    this.editSession.remember(this.buildProfile(),this.currentControlGroup,this.previewControlGroups)
    this.undoCount=this.editSession.count(); this.sliderUndoKey=''
  }

  /** 同一滑条的一次拖动只建立一个 undo 边界。 */
  private beginSliderUndo(key: string): void {
    if (this.sliderUndoKey !== key) {
      this.pushUndo()
      this.sliderUndoKey = key
    }
  }

  /**
   * 官方Slider以Begin/Moving/End/Click区分手势阶段。一根手指持续拖动只记录首次变化前的状态；
   * End或离散Click收口，下一次拖动重新建立边界。刷新回传同值不建快照，但仍消费结束阶段，
   * 防止一次拖动最后的End同值包被去重后把下一次手势并入旧组。
   */
  private prepareSliderChange(key: string, mode: SliderChangeMode | undefined, changed: boolean): boolean {
    if (mode === SliderChangeMode.Begin) this.sliderUndoKey = ''
    if (changed) this.beginSliderUndo(key)
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.sliderUndoKey = ''
    return changed
  }

  private canUndo(): boolean { return this.undoCount > 0 }

  private undo(): void {
    const snapshot: LayoutEditCheckpoint | undefined=this.editSession.takeUndo()
    if (snapshot===undefined) return
    const selected: string=this.selectedItem()?.id ?? ''
    this.loadProfile(snapshot.profile,false)
    this.currentControlGroup=snapshot.currentGroup; this.previewControlGroups=snapshot.previewGroups.slice()
    this.repairEditorGroups_()
    this.selectedIdx=this.controls.findIndex((item: ControlItem): boolean => item.id===selected)
    this.selectGroupPhase_(this.groupActionPhase)
    this.undoCount=this.editSession.count(); this.statusMsg='已撤销'
  }

  // ============= 几何辅助 =============

  private itemW(c: ControlItem): number { return c.baseWidth * c.itemScale * this.globalScale }
  private itemH(c: ControlItem): number { return c.baseHeight * c.itemScale * this.globalScale }
  private itemPxX(c: ControlItem): number { return c.xPct * this.screenWidth }
  private itemPxY(c: ControlItem): number { return c.yPct * this.screenHeight }
  private itemCenterX(c: ControlItem): number { return this.itemPxX(c) + this.itemW(c) / 2 }
  private itemCenterY(c: ControlItem): number { return this.itemPxY(c) + this.itemH(c) / 2 }

  /** 编辑器按钮圆角（px），与 GameControls 渲染口径一致：cornerRadius × 短边一半。 */
  private editBtnBorderRadius(c: ControlItem): number {
    const shortHalf = Math.min(this.itemW(c), this.itemH(c)) / 2
    return effectiveCornerRadius(c) * shortHalf
  }

  /** 编辑器预览透明度 = 按钮自身 × 全局；留地板值 0.35 保证暗按钮在编辑器里仍可见可选。 */
  private editBtnOpacity(c: ControlItem): number {
    const v = effectiveOpacity(c) * this.globalOpacity
    return v < 0.35 ? 0.35 : (v > 1 ? 1 : v)
  }

  /** 编辑器按钮框内字号（px），与 GameControls.btnFontSize 一致。 */
  private editBtnFontSize(c: ControlItem): number {
    const shortSide = Math.min(this.itemW(c), this.itemH(c))
    let fs = shortSide * 0.42
    const label = effectiveLabel(c)
    if (label.length >= 4) fs = shortSide * 0.30
    else if (label.length === 3) fs = shortSide * 0.36
    if (fs < 10) fs = 10
    if (fs > 22) fs = 22
    return fs
  }

  /**
   * 自动对齐引擎（2026-07-16 重写）。给定拖动控件左上角原始坐标 (px, py)，返回吸附后的坐标，
   * 并更新 this.guideX/guideY（虚线）与 this.lockX/lockY（每轴滞回锁）。
   *
   * 设计要点：
   * - X、Y 两轴**独立**解算：竖虚线（固定 X）约束水平位置、横虚线（固定 Y）约束垂直位置，可同时成立形成十字。
   * - 每轴候选线含：与其它可见控件的**边对边 / 中心对中心**对齐、**相邻贴靠间距**（我右缘↔它左缘±gap 等），
   *   以及**屏幕边 / 屏幕中线**。
   * - **滞回锁定**：未锁定时参考点进入某线 SNAP_IN 才锁；已锁定后需离开 SNAP_IN×SNAP_OUT_RATIO 才解锁。
   *   于是"横对齐后左右滑动、垂直轻微抖动"仍稳定停在对齐高度（用户核心诉求）。
   */
  private applySnap(idx: number, px: number, py: number): SnapResult {
    if (!this.snapEnabled) {
      this.lockX = null
      this.lockY = null
      this.guideX = -1
      this.guideY = -1
      return { x: px, y: py }
    }
    const c = this.controls[idx]
    const w = this.itemW(c)
    const h = this.itemH(c)
    const snapIn = this.snapStrength
    const snapOut = this.snapStrength * SNAP_OUT_RATIO
    const gap = this.snapGap

    const xCands = this.buildAxisCandidates(idx, true, w, h, gap)
    const yCands = this.buildAxisCandidates(idx, false, w, h, gap)

    const xr = this.resolveAxis(px, xCands, this.lockX, snapIn, snapOut)
    const yr = this.resolveAxis(py, yCands, this.lockY, snapIn, snapOut)

    this.lockX = xr.lock
    this.lockY = yr.lock
    this.guideX = xr.guide
    this.guideY = yr.guide
    return { x: xr.coord, y: yr.coord }
  }

  /**
   * 生成单轴对齐候选线。isX=true 为竖线（约束水平/X），false 为横线（约束垂直/Y）。
   * mySize/otherSize 取对应轴尺寸；对齐用同名边（左左/中中/右右），相邻贴靠用异名边（我右↔它左±gap）。
   */
  private buildAxisCandidates(idx: number, isX: boolean, w: number, h: number, gap: number): AlignCandidate[] {
    const out: AlignCandidate[] = []
    const mySize = isX ? w : h
    const screenSize = isX ? this.screenWidth : this.screenHeight

    // 屏幕边 + 屏幕中线
    out.push({ line: 0, refOffset: 0, draw: 0 })
    out.push({ line: screenSize / 2, refOffset: mySize / 2, draw: screenSize / 2 })
    out.push({ line: screenSize, refOffset: mySize, draw: screenSize })

    for (let i = 0; i < this.controls.length; i++) {
      if (i === idx) continue
      const o = this.controls[i]
      if (o.hidden) continue   // 隐藏控件不可见，不作为对齐参考
      const oMin = isX ? this.itemPxX(o) : this.itemPxY(o)
      const oSize = isX ? this.itemW(o) : this.itemH(o)
      const oMid = oMin + oSize / 2
      const oMax = oMin + oSize
      // 对齐：左左 / 中中 / 右右（同名边）
      out.push({ line: oMin, refOffset: 0, draw: oMin })
      out.push({ line: oMid, refOffset: mySize / 2, draw: oMid })
      out.push({ line: oMax, refOffset: mySize, draw: oMax })
      // 相邻贴靠：我的 max 边 ↔ 它的 min 边 − gap；我的 min 边 ↔ 它的 max 边 + gap
      out.push({ line: oMin - gap, refOffset: mySize, draw: oMin - gap })
      out.push({ line: oMax + gap, refOffset: 0, draw: oMax + gap })
    }
    return out
  }

  /**
   * 单轴滞回解算。raw = 左上角原始坐标；lock = 该轴当前锁定线（可空）。
   * 先尝试维持旧锁（离开 snapOut 才解锁），再在无锁时用 snapIn 捕获最近候选。
   */
  private resolveAxis(raw: number, cands: AlignCandidate[], lock: AxisLock | null,
                      snapIn: number, snapOut: number): AxisSnap {
    // 1) 维持既有锁：参考点仍在 snapOut 内 → 保持吸附
    if (lock !== null) {
      const dist = Math.abs((raw + lock.refOffset) - lock.line)
      if (dist <= snapOut) {
        return { coord: lock.line - lock.refOffset, guide: lock.draw, lock: lock }
      }
    }
    // 2) 无锁 / 已脱离：取 snapIn 内最近候选
    let best: AlignCandidate | null = null
    let bestDist = snapIn + 1
    for (let i = 0; i < cands.length; i++) {
      const cand = cands[i]
      const d = Math.abs((raw + cand.refOffset) - cand.line)
      if (d <= snapIn && d < bestDist) {
        bestDist = d
        best = cand
      }
    }
    if (best !== null) {
      const newLock: AxisLock = { line: best.line, refOffset: best.refOffset, draw: best.draw }
      return { coord: best.line - best.refOffset, guide: best.draw, lock: newLock }
    }
    return { coord: raw, guide: -1, lock: null }
  }

  /** 拖动/提交结束后清除对齐虚线与滞回锁。 */
  private clearSnapGuides(): void {
    this.lockX = null
    this.lockY = null
    this.guideX = -1
    this.guideY = -1
  }

  // 拖动结束：把 dragDx/dragDy 写入 controls[dragIdx]，含吸附
  private commitDrag(): void {
    const idx = this.dragIdx
    if (idx < 0 || idx >= this.controls.length) return
    const c = this.controls[idx]
    if (c.locked) {
      this.dragIdx = -1
      this.dragDx = 0
      this.dragDy = 0
      this.clearSnapGuides()
      this.refreshControls()
      this.statusMsg = '该按钮已锁定，无法移动'
      return
    }
    // onActionUpdate 已把 dragDx/dragDy 设为**吸附后**的位移；这里直接采用最终吸附结果，
    // 不再二次吸附（否则会与已锁定的滞回态不一致）。
    const snappedX = this.itemPxX(c) + this.dragDx
    const snappedY = this.itemPxY(c) + this.dragDy
    let newXPct = snappedX / this.screenWidth
    let newYPct = snappedY / this.screenHeight
    // clamp
    newXPct = Math.max(0, Math.min(1 - this.itemW(c) / this.screenWidth, newXPct))
    newYPct = Math.max(0, Math.min(1 - this.itemH(c) / this.screenHeight, newYPct))
    this.pushUndo()
    c.xPct = newXPct
    c.yPct = newYPct
    // 用户手动挪动物品栏条 → 标记为"用户已定位"，下次 load 不再自动对齐（尊重手动摆放/手动档 guiScale）。
    if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
    this.dragIdx = -1
    this.dragDx = 0
    this.dragDy = 0
    this.clearSnapGuides()
    this.refreshControls()
  }

  // ============= 选中按钮的修改 =============

  private selectedItem(): ControlItem | null {
    if (this.selectedIdx < 0 || this.selectedIdx >= this.controls.length) return null
    return this.controls[this.selectedIdx]
  }

  /** 改键确认 */
  private applyKeys(keys: number[]): void {
    const item = this.selectedItem()
    if (!item) return
    if (item.phaseBindings !== undefined) { this.openTab('group-actions'); this.statusMsg='此按钮使用分阶段绑定，请选择要修改的阶段'; return }
    // 选择器已即时限制，宿主仍拒绝异常/迟到回调，不能污染草稿后让保存整份失败。
    if (keys.length > MAX_LAYOUT_CONTROL_KEYS) {
      this.statusMsg = '组合键最多支持' + MAX_LAYOUT_CONTROL_KEYS.toString() + '个按键，请减少选择'
      return
    }
    this.pushUndo()
    item.keys = keys.slice()
    // 空数组是显式解除，兼容字段也必须清零，不能让effectiveKeys回退到旧键。
    item.keyOrMouse = keys.length > 0 ? keys[0] : 0
    this.refreshControls()
    this.statusMsg = keys.length === 0 ? '已解除绑定' :
      '键位已改为 ' + keys.map((k: number) => glfwKeyName(k)).join(' + ')
  }

  /** trigger 切换 */
  private cycleTrigger(): void {
    const item = this.selectedItem()
    if (!item) return
    const order: TriggerMode[] = ['press', 'toggle', 'doubleTap', 'longPress']
    const cur = item.trigger ?? 'press'
    const idx = order.indexOf(cur)
    const next = order[(idx + 1) % order.length]
    this.pushUndo()
    item.trigger = next
    if (next !== 'press') item.swipeGroup = undefined
    this.refreshControls()
    this.statusMsg = '触发模式 = ' + next + (next !== 'press' ? '；连滑已关闭' : '')
  }

  /** 显隐切换 */
  private toggleHidden(): void {
    const item = this.selectedItem()
    if (!item) return
    this.pushUndo()
    item.hidden = !item.hidden
    this.refreshControls()
    this.statusMsg = item.hidden ? '已隐藏' : '已显示'
  }

  /** 锁定切换 */
  private toggleLocked(): void {
    const item = this.selectedItem()
    if (!item) return
    this.pushUndo()
    item.locked = !item.locked
    this.refreshControls()
    this.statusMsg = item.locked ? '已锁定' : '已解锁'
  }

  /** 删除 */
  private deleteSelected(): void {
    if (this.selectedIdx < 0) return
    // 系统功能按钮（输入/设置/显示/鼠标）是核心入口，不可删除，仅可移动/缩放/改外观。
    if (this.controls[this.selectedIdx].systemAction !== undefined) {
      this.statusMsg = '系统按钮不可删除'
      return
    }
    this.pushUndo()
    if (this.controls[this.selectedIdx].type === ControlType.HOTBAR_SELECTOR) {
      // 删除 selector 也算“已经自动提供过”，保存该标志后 Store 不会再次注入。
      this.hotbarAutoAdded = true
    }
    this.controls.splice(this.selectedIdx, 1)
    this.selectedIdx = -1
    this.refreshControls()
    this.statusMsg = '已删除'
  }

  /** 复制 */
  private duplicateSelected(): void {
    const item = this.selectedItem()
    if (!item) return
    // 系统功能按钮（输入/设置/显示）每种只应存在一个，禁止复制出多余副本。
    if (item.systemAction !== undefined) {
      this.statusMsg = '系统按钮不可复制'
      return
    }
    this.pushUndo()
    // 根和所有 children 一次性换新 ID；与现有整棵布局共享同一全局命名空间。
    const dup = cloneItemWithFreshIds(item, this.controls)
    // 合法导入和两级放大均可能让控件大于窗口；复制时与拖动使用相同的零下界，保留合法百分比。
    dup.xPct = Math.max(0, Math.min(1 - this.itemW(dup) / this.screenWidth, item.xPct + 0.04))
    dup.yPct = Math.max(0, Math.min(1 - this.itemH(dup) / this.screenHeight, item.yPct + 0.04))
    this.controls.push(dup)
    this.selectedIdx = this.controls.length - 1
    this.refreshControls()
    this.statusMsg = '已复制'
  }

  /**
   * 添加按键（2026-05-30）：在屏幕中央新建一个标准正方形按钮，默认绑定 G（占位，
   * 用户随即可在弹出的"选择按键"里改成全键盘任意键）。新建后自动选中 + 打开改键 sheet。
   * 添加目录的常用键可传入已知初始code，同一笔新增直接写入该键，不另记一次改键撤销。
   *
   * 用户新增的按键**永不自动隐藏**（hideOnInput: []）——接键鼠后也保留显示，
   * 避免"加了个键，插上键盘就消失找不到"。需要隐时用户可在"显示策略"里手动设强隐。
   */
  private addButton(initialCode?: number): void {
    const code: number = initialCode ?? GLFW_KEY_G
    this.pushUndo()
    const id = generateControlId(this.controls)
    const newItem: ControlItem = {
      id,
      controlGroupId: this.controlGroups === undefined ? undefined : this.currentControlGroup,
      label: '',
      type: ControlType.BUTTON,
      keyOrMouse: code,
      keys: [code],
      trigger: 'press',
      // 放屏幕中央偏上，避免压在底部工具面板上
      xPct: 0.5 - (DEFAULT_BUTTON_SIZE / 2) / this.screenWidth,
      yPct: 0.35,
      baseWidth: DEFAULT_BUTTON_SIZE,
      baseHeight: DEFAULT_BUTTON_SIZE,
      itemScale: 1.0,
      isCircle: false,
      style: { cornerRadius: DEFAULT_CORNER_RADIUS },
      alignGroup: AlignGroup.NONE,
      alignIndex: 0,
      grabbedOnly: true,
      hidden: false,
      locked: false,
      // 永不自动隐藏：空数组（非 undefined，避免 migrateProfile 按键码推断成 ['keyboard']）
      hideOnInput: []
    }
    this.controls.push(newItem)
    this.selectedIdx = this.controls.length - 1
    this.selectedScaleVal = 100
    this.refreshControls()
    this.statusMsg = initialCode === undefined ? '已添加按键，请选择要绑定的键' :
      '已添加 ' + glfwKeyName(code) + '，可拖动调整位置'
    // 普通入口继续打开改键；常用键已绑定，不弹第二层，保持一次新增对应一次撤销。
    this.syncSelectedAppearanceVals()
    this.showKeyPicker = initialCode === undefined
  }

  /**
   * F1（2026-07-11）：添加"物品栏直点条"。一个布局里一个足够——已有则选中已有的。
   * 新建时自动对齐到 MC 真实 hotbar（假定自动档 guiScale，最常见；手动档需用户微调）。
   */
  private addHotbar(): void {
    const existing = this.controls.findIndex((c: ControlItem) => c.type === ControlType.HOTBAR_SELECTOR)
    if (existing >= 0) {
      if (this.selectedIdx === existing) {
        // 已选中再点 = 重新对齐到 MC hotbar
        this.pushUndo()
        this.autoAlignHotbar(this.controls[existing])
        this.refreshControls()
        this.statusMsg = '物品栏已重新对齐到 MC hotbar'
      } else {
        this.selectedIdx = existing
        this.syncSelectedAppearanceVals()
        this.statusMsg = '已选中物品栏（再点「物品栏」按钮可重新对齐；也可手动拖动/缩放）'
      }
      return
    }
    this.pushUndo()
    const item = makeHotbarSelector(0.2, 0.9, 300, 36)
    item.id = generateControlId(this.controls)
    if (this.controlGroups !== undefined) item.controlGroupId=this.currentControlGroup
    this.autoAlignHotbar(item)
    this.controls.push(item)
    this.hotbarAutoAdded = true
    this.selectedIdx = this.controls.length - 1
    this.syncSelectedAppearanceVals()
    this.refreshControls()
    this.statusMsg = '已添加物品栏直点条（已按屏幕自动对齐，可微调）'
  }

  /**
   * 游戏内编辑使用最新GUI快照；启动器内编辑只能生成设备预览，并清除手工标记让运行时实际对齐。
   * 预览不修改游戏的GUI档位，base尺寸抵消布局globalScale，避免再次放大真实快捷栏。
   */
  private autoAlignHotbar(item: ControlItem): void {
    const g = this.globalScale > 0 ? this.globalScale : 1.0
    // 显式"对齐到 MC hotbar" = 回到系统自动对齐：清除手动定位标记，之后每次 load 会持续保持对齐。
    item.hotbarUserPlaced = false
    if(this.gameGui.valid) {
      const profile=this.buildProfile()
      if(profile!==null) {
        const projected: ControlItem=projectGameHotbar(profile,[item],this.gameGui,this.screenWidth,this.screenHeight)[0]
        item.xPct=projected.xPct; item.yPct=projected.yPct
        item.baseWidth=projected.baseWidth; item.baseHeight=projected.baseHeight; item.itemScale=1
        return
      }
    }
    try {
      const d = display.getDefaultDisplaySync()
      let wPx = d.width
      let hPx = d.height
      if (hPx > wPx) { const t = wPx; wPx = hPx; hPx = t }   // 游戏恒横屏
      const dens = d.densityPixels > 0 ? d.densityPixels : 3.0
      const gs = computeAutoGuiScale(wPx, hPx)
      const r = computeHotbarRectPx(wPx, hPx, gs)
      item.xPct = r.leftPx / wPx
      item.yPct = r.topPx / hPx
      item.itemScale = 1.0
      item.baseWidth = (r.widthPx / dens) / g
      item.baseHeight = (r.heightPx / dens) / g
    } catch (e) {
      item.xPct = 0.2
      item.yPct = 0.9
      item.itemScale = 1.0
      item.baseWidth = (this.screenWidth * 0.6) / g
      item.baseHeight = item.baseWidth * 22 / 182
    }
  }

  /** label 提交 */
  private applyLabel(): void {
    const item = this.selectedItem()
    if (!item) return
    this.pushUndo()
    item.label = this.labelDraft
    this.refreshControls()
    this.statusMsg = '标签已更新'
  }

  // ============= UI 重构：按钮外观（大小 / 透明度 / 圆角） =============

  /** 确保选中按钮有 style 对象（惰性创建），返回它。 */
  private ensureStyle(item: ControlItem): ControlStyle {
    if (!item.style) {
      item.style = { opacity: DEFAULT_BUTTON_OPACITY, cornerRadius: DEFAULT_CORNER_RADIUS }
    }
    return item.style
  }

  /**
   * 样式当前值（用于滑条初值）：取样式主项（单选=选中项、多选=末项选中）。
   * 这样单选/多选/批量共用同一套样式编辑逻辑，为以后拓展样式字段铺路。
   */
  private curSizePct(): number {
    const item = this.stylePrimary()
    if (!item) return 100
    return Math.round(item.itemScale * 100)
  }
  private curOpacityPct(): number {
    const item = this.stylePrimary()
    if (!item) return 100
    return Math.round(effectiveOpacity(item) * 100)
  }
  private curCornerPct(): number {
    const item = this.stylePrimary()
    if (!item) return Math.round(DEFAULT_CORNER_RADIUS * 100)
    return Math.round(effectiveCornerRadius(item) * 100)
  }

  /** 统一样式应用：对全部样式目标（单选 1 个 / 多选 N 个）逐个写入，一改全改。 */
  private applyOpacity(opPct: number, mode?: SliderChangeMode): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    if (!this.prepareSliderChange('styleOpacity', mode,
      targets.some((item: ControlItem): boolean => effectiveOpacity(item) !== opPct / 100))) return
    for (let t of targets) this.ensureStyle(t).opacity = opPct / 100
    this.selectedOpacityVal = Math.round(opPct)
    this.refreshControls()
  }
  private applyCorner(cornerPct: number, mode?: SliderChangeMode): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    if (!this.prepareSliderChange('styleCorner', mode,
      targets.some((item: ControlItem): boolean => effectiveCornerRadius(item) !== cornerPct / 100))) return
    for (let t of targets) {
      const st = this.ensureStyle(t)
      st.cornerRadius = cornerPct / 100
      // 同步老 isCircle 字段，保持渲染兼容（圆角=100% 视为圆）
      t.isCircle = cornerPct >= 99
    }
    this.refreshControls()
  }
  /** 统一"大小"应用（用 itemScale，对所有控件类型一致；hotbar 标记为用户已定位）。 */
  private applySize(sizePct: number, mode?: SliderChangeMode): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    if (!this.prepareSliderChange('styleSize', mode,
      targets.some((item: ControlItem): boolean => item.itemScale !== sizePct / 100))) return
    for (let t of targets) {
      t.itemScale = sizePct / 100
      if (t.type === ControlType.HOTBAR_SELECTOR) t.hotbarUserPlaced = true
    }
    this.selectedScaleVal = Math.round(sizePct)
    this.refreshControls()
  }

  /** "统一大小"一键：把所有非摇杆/非滚轮按钮统一为标准正方形框（DEFAULT_BUTTON_SIZE + 默认圆角）。 */
  private unifyAllSizes(): void {
    this.pushUndo()
    for (let i = 0; i < this.controls.length; i++) {
      const c = this.controls[i]
      if (c.type === ControlType.BUTTON) {
        c.baseWidth = DEFAULT_BUTTON_SIZE
        c.baseHeight = DEFAULT_BUTTON_SIZE
        c.itemScale = 1.0
        // 统一为正方形框观感：圆角回到默认（轻微圆角），清掉旧的圆形标记
        c.isCircle = false
        if (!c.style) c.style = { opacity: DEFAULT_BUTTON_OPACITY }
        c.style.cornerRadius = DEFAULT_CORNER_RADIUS
        c.style.shape = undefined
      }
    }
    this.refreshControls()
    this.statusMsg = '所有按钮已统一为标准正方形框'
  }

  // ============= 渲染 =============

  /** 编辑眼睛开关不进入 buildProfile；载入/撤销后只修正已不存在的选择。 */
  private repairEditorGroups_(): void {
    const groups: ControlGroup[] = this.controlGroups ?? []
    if (!groups.some((group: ControlGroup): boolean => group.id === this.currentControlGroup))
      this.currentControlGroup=this.defaultControlGroupId ?? ''
    this.previewControlGroups=this.previewControlGroups.filter((id: string): boolean => groups.some((group: ControlGroup): boolean => group.id === id))
    if (this.currentControlGroup.length > 0 && this.previewControlGroups.indexOf(this.currentControlGroup) < 0)
      this.previewControlGroups=this.previewControlGroups.concat([this.currentControlGroup])
    this.groupNameDraft=groups.find((group: ControlGroup): boolean => group.id === this.currentControlGroup)?.name ?? ''
    this.selectedIds=this.selectedIds.filter((id: string): boolean => this.controls.some((item: ControlItem): boolean => item.id === id))
    if (this.selectedIdx >= this.controls.length) this.selectedIdx=-1
    this.deletingGroup=''
  }

  private editorGroupVisible_(item: ControlItem): boolean {
    return this.controlGroups === undefined || item.controlGroupId === undefined ||
      item.controlGroupId === this.currentControlGroup || this.previewControlGroups.indexOf(item.controlGroupId) >= 0
  }

  /** 画布按组层级排序但保留真实 controls 下标，拖动/选择不会误写另一控件。 */
  private editorCanvasOrder_(): number[] {
    const indices: number[]=[]
    for (let index: number=0; index<this.controls.length; index++) indices.push(index)
    if (this.controlGroups === undefined) return indices
    const groups: ControlGroup[]=this.controlGroups
    const rank = (item: ControlItem): number => item.controlGroupId === undefined ? groups.length :
      groups.findIndex((group: ControlGroup): boolean => group.id === item.controlGroupId)
    return indices.sort((a: number,b: number): number => rank(this.controls[a])-rank(this.controls[b]) || a-b)
  }

  /** 组操作只有这一个提交点：先完整校验，再一次撤销快照和整体替换，不制造半个引用图。 */
  private applyGroupDraft_(draft: LayoutProfile | null, message: string): boolean {
    const checked: LayoutProfile | null = draft === null ? null : validateAndNormalizeLayout(draft)
    if (checked === null) { this.statusMsg='组操作超出容量或引用不合法，草稿未修改'; return false }
    const selected: string = this.selectedItem()?.id ?? ''
    this.pushUndo()
    this.controls=checked.controls.map((item: ControlItem): ControlItem => cloneControlItem(item))
    this.controlGroups=cloneControlGroups(checked.controlGroups); this.defaultControlGroupId=checked.defaultControlGroupId
    this.requiredCapabilities=checked.requiredCapabilities?.slice()
    this.selectedIdx=this.controls.findIndex((item: ControlItem): boolean => item.id === selected)
    this.repairEditorGroups_(); this.refreshControls(); this.statusMsg=message
    return true
  }

  private chooseControlGroup_(id: string): void {
    this.currentControlGroup=id; this.repairEditorGroups_(); this.ver++
  }

  private toggleGroupPreview_(id: string): void {
    if (id === this.currentControlGroup) { this.statusMsg='当前编辑组始终显示；请先选择其他组'; return }
    this.previewControlGroups=this.previewControlGroups.indexOf(id) >= 0 ?
      this.previewControlGroups.filter((value: string): boolean => value !== id) : this.previewControlGroups.concat([id])
    this.ver++
  }

  private createControlGroup_(): void {
    const current: LayoutProfile | null=this.buildProfile()
    if (current === null) return
    const draft: LayoutProfile=enableLayoutControlGroups(current)
    if ((draft.controlGroups?.length ?? 0) >= MAX_CONTROL_GROUPS) { this.statusMsg='触控组已达到128组上限'; return }
    const id: string=generateControlId(draft.controls)
    draft.controlGroups!.push({id:id,name:this.groupNameDraft.trim() || '新触控组',initialVisible:false})
    if (this.applyGroupDraft_(draft,'已创建组；画布临时显示，进入游戏时默认隐藏')) this.chooseControlGroup_(id)
  }

  private renameControlGroup_(): void {
    const draft: LayoutProfile | null=this.buildProfile()
    const group: ControlGroup | undefined=draft?.controlGroups?.find((value: ControlGroup): boolean => value.id === this.currentControlGroup)
    if (group === undefined || this.groupNameDraft.trim().length === 0) { this.statusMsg='请输入组名'; return }
    group.name=this.groupNameDraft.trim(); this.applyGroupDraft_(draft,'已修改组名，引用保持原 ID')
  }

  private setGroupInitialVisible_(visible: boolean): void {
    const draft: LayoutProfile | null=this.buildProfile()
    const group: ControlGroup | undefined=draft?.controlGroups?.find((value: ControlGroup): boolean => value.id === this.currentControlGroup)
    if (group === undefined || group.initialVisible === visible) return
    group.initialVisible=visible; this.applyGroupDraft_(draft,'已修改进入游戏时的初始显隐；画布预览独立保留')
  }

  private moveGroupOrder_(delta: number): void {
    const draft: LayoutProfile | null=this.buildProfile()
    const groups: ControlGroup[] | undefined=draft?.controlGroups
    if (groups === undefined) return
    const index: number=groups.findIndex((group: ControlGroup): boolean => group.id === this.currentControlGroup)
    const next: number=index+delta
    if (index < 0 || next < 0 || next >= groups.length) return
    const item: ControlGroup=groups[index]; groups[index]=groups[next]; groups[next]=item
    this.applyGroupDraft_(draft,'已调整组层级，游戏绘制与命中使用同一次序')
  }

  private duplicateControlGroup_(): void {
    const draft: LayoutProfile | null=this.buildProfile()
    if (draft === null) return
    const copied: LayoutProfile | null=duplicateLayoutControlGroup(draft,this.currentControlGroup,(this.currentGroup_()?.name ?? '组')+' 副本')
    if (this.applyGroupDraft_(copied,'已复制组：自引用指向副本，其他目标保留')) this.chooseControlGroup_(copied!.controlGroups![copied!.controlGroups!.length-1].id)
  }

  private groupDeletionDescription_(): string {
    const members: number=this.controls.filter((item: ControlItem): boolean => item.controlGroupId === this.deletingGroup).length
    let references: number=0
    const count = (item: ControlItem): void => {
      for (const action of item.groupActions ?? []) references+=action.targets.filter((id: string): boolean => id === this.deletingGroup).length
      for (const child of item.children ?? []) count(child)
    }
    for (const item of this.controls) count(item)
    return '将处理 '+members+' 个顶层成员及 '+references+' 处动作引用。确认后可一次撤销。'
  }

  private deleteControlGroup_(moveMembers: boolean): void {
    const draft: LayoutProfile | null=this.buildProfile()
    if (draft === null) return
    this.applyGroupDraft_(removeLayoutControlGroup(draft,this.deletingGroup,moveMembers ? this.defaultControlGroupId : undefined),
      moveMembers ? '成员已移到默认组，目标引用已清理' : '组及成员已删除，目标引用已清理')
  }

  /** 移动成员只改变归属；位置、键位、ID、样式原样保留，受保护恢复入口排除。 */
  private moveSelectedToGroup_(): void {
    const draft: LayoutProfile | null=this.buildProfile()
    if (draft === null || this.currentControlGroup.length === 0) return
    const ids: string[]=this.multiSelectMode ? this.selectedIds.slice() : [this.selectedItem()?.id ?? '']
    for (const item of draft.controls) {
      if (ids.indexOf(item.id) >= 0 && item.systemAction !== 'edit' && item.systemAction !== 'visibility') {
        item.controlGroupId=this.currentControlGroup
        // 子项显式归属若曾存在，也统一迁移；不形成跨组 children。
        const inherit = (child: ControlItem): void => { child.controlGroupId=undefined; for(const nested of child.children ?? []) inherit(nested) }
        for (const child of item.children ?? []) inherit(child)
      }
    }
    this.applyGroupDraft_(draft,'所选成员已移动到当前组，位置与绑定保持')
  }

  private currentGroup_(): ControlGroup | undefined {
    return this.controlGroups?.find((group: ControlGroup): boolean => group.id === this.currentControlGroup)
  }
  private filteredControlGroups_(): ControlGroup[] {
    const query: string=this.groupSearch.trim().toLowerCase()
    return (this.controlGroups ?? []).filter((group: ControlGroup): boolean => query.length === 0 || group.name.toLowerCase().indexOf(query) >= 0)
  }

  private phaseName_(phase: string): string {
    return phase === 'press' ? '按下' : phase === 'longPress' ? '长按' : phase === 'click' ? '单击抬起' : '双击确认'
  }
  /** 阶段切换同时读取已保存操作，避免把另一阶段的 hide 无声改成 toggle。 */
  private selectGroupPhase_(phase: ControlActionPhase): void {
    this.groupActionPhase=phase
    this.selectedGroupActionIndex=(this.selectedItem()?.groupActions ?? []).findIndex((action: ControlGroupAction): boolean => action.phase === phase)
    this.groupActionOperation=this.selectedGroupAction_()?.operation ?? 'toggle'
  }

  /** 选择冻结到当前控件的当前阶段；旧下标或另一个阶段不能被编辑续体覆盖。 */
  private selectedGroupAction_(): ControlGroupAction | undefined {
    const action: ControlGroupAction | undefined=this.selectedItem()?.groupActions?.[this.selectedGroupActionIndex]
    return action?.phase === this.groupActionPhase ? action : undefined
  }

  /** 下标列表保留存档顺序；只过滤显示，不归一化操作或目标。 */
  private phaseActionIndices_(): number[] {
    const actions: ControlGroupAction[]=this.selectedItem()?.groupActions ?? []
    const result: number[]=[]
    for (let index: number=0; index<actions.length; index++) if (actions[index].phase === this.groupActionPhase) result.push(index)
    return result
  }

  private groupActionSummary_(index: number): string {
    const action: ControlGroupAction | undefined=this.selectedItem()?.groupActions?.[index]
    if (action === undefined) return ''
    const operation: string=action.operation === 'show' ? '显示' : action.operation === 'hide' ? '隐藏' : '切换'
    return operation + '：' + action.targets.map((id: string): string => this.controlGroups?.find((group: ControlGroup): boolean => group.id === id)?.name ?? id).join(' → ')
  }

  private selectGroupAction_(index: number): void {
    this.selectedGroupActionIndex=index
    this.groupActionOperation=this.selectedGroupAction_()?.operation ?? 'toggle'
  }

  /** 只移动同阶段相邻动作；跨阶段的存档行保持原值，操作可一次撤销。 */
  private moveGroupAction_(delta: number): void {
    const indices: number[]=this.phaseActionIndices_()
    const position: number=indices.indexOf(this.selectedGroupActionIndex)
    const next: number=position+delta
    const profile: LayoutProfile | null=this.buildProfile()
    if (profile === null || position<0 || next<0 || next>=indices.length) return
    const item: ControlItem | undefined=profile.controls.find((control: ControlItem): boolean => control.id === this.selectedItem()?.id)
    if (item?.groupActions === undefined) return
    const a: number=indices[position], b: number=indices[next]
    const old: ControlGroupAction=item.groupActions[a]
    item.groupActions[a]=item.groupActions[b]; item.groupActions[b]=old
    if (this.applyGroupDraft_(profile,'已调整动作顺序')) this.selectGroupAction_(b)
  }
  private phaseTargets_(): string[] {
    return this.selectedGroupAction_()?.targets.slice() ?? []
  }

  private setPhaseTargets_(targets: string[]): void {
    const current: LayoutProfile | null=this.buildProfile(), selected: ControlItem | null=this.selectedItem()
    if (current === null || selected === null || selected.type !== ControlType.BUTTON || selected.systemAction !== undefined) return
    const draft: LayoutProfile=enableLayoutControlGroups(current)
    const item: ControlItem | undefined=draft.controls.find((value: ControlItem): boolean => value.id === selected.id)
    if (item === undefined) return
    const actions: ControlGroupAction[]=item.groupActions ?? []
    const index: number=this.selectedGroupAction_() === undefined ? -1 : this.selectedGroupActionIndex
    if (index<0 && targets.length===0) return
    if (index>=0 && targets.length===0) actions.splice(index,1)
    else {
      const action: ControlGroupAction={phase:this.groupActionPhase,operation:this.groupActionOperation,targets:targets.slice()}
      if (index<0) actions.push(action)
      else actions[index]=action
    }
    item.groupActions=actions
    if (this.applyGroupDraft_(draft,'已更新选中动作；顺序、重复目标和其他动作保持'))
      this.selectedGroupActionIndex=targets.length===0 ? -1 : index<0 ? actions.length-1 : index
  }
  /** 每次选择追加一个目标；重复目标有真实执行意义，删除按具体出现位置操作。 */
  private togglePhaseTarget_(id: string): void {
    this.setPhaseTargets_(this.phaseTargets_().concat([id]))
  }

  private removePhaseTarget_(index: number): void {
    this.setPhaseTargets_(this.phaseTargets_().filter((_id: string, position: number): boolean => position !== index))
  }
  private currentPhaseKeys_(): number[] {
    const item: ControlItem | null=this.selectedItem()
    if (item === null) return []
    if (item.phaseBindings !== undefined) return item.phaseBindings.find((phase: ControlPhaseBinding): boolean => phase.phase === this.groupActionPhase)?.keys.slice() ?? []
    const phase: string=item.trigger === 'longPress' ? 'longPress' : item.trigger === 'doubleTap' ? 'doubleClick' : 'press'
    return phase === this.groupActionPhase ? effectiveKeys(item).slice() : []
  }

  /** 分阶段改键先保全旧普通绑定，再切换明确的新协议；取消选择器不会改变草稿。 */
  private applyPhaseKeys_(keys: number[], autoKeep?: boolean): void {
    const current: LayoutProfile | null=this.buildProfile()
    const id: string=this.phaseKeyControlId || this.selectedItem()?.id || ''
    const targetPhase: ControlActionPhase=this.phaseKeyControlId.length > 0 ? this.phaseKeyPhase : this.groupActionPhase
    if (current === null || keys.length > MAX_LAYOUT_CONTROL_KEYS) return
    const draft: LayoutProfile=enableLayoutControlGroups(current)
    const item: ControlItem | undefined=draft.controls.find((value: ControlItem): boolean => value.id === id)
    if (item === undefined || item.systemAction !== undefined || item.type !== ControlType.BUTTON) return
    if (item.phaseBindings === undefined) {
      const original: number[]=effectiveKeys(item).slice()
      const phase: ControlActionPhase=item.trigger === 'longPress' ? 'longPress' : item.trigger === 'doubleTap' ? 'doubleClick' : 'press'
      item.phaseBindings=original.length > 0 ? [{phase:phase,keys:original,autoKeep:item.trigger === 'toggle'}] : []
    }
    const previous: ControlPhaseBinding | undefined=item.phaseBindings.find((value: ControlPhaseBinding): boolean => value.phase === targetPhase)
    item.phaseBindings=item.phaseBindings.filter((value: ControlPhaseBinding): boolean => value.phase !== targetPhase)
    item.phaseBindings.push({phase:targetPhase,keys:keys.slice(),autoKeep:autoKeep ?? previous?.autoKeep ?? false})
    item.keys=[]; item.keyOrMouse=0; item.trigger='press'
    if (draft.requiredCapabilities!.indexOf(TOUCH_PHASE_CAPABILITY) < 0) draft.requiredCapabilities!.push(TOUCH_PHASE_CAPABILITY)
    this.phaseKeyControlId=''; this.applyGroupDraft_(draft,'已保存本阶段键绑定，其他阶段保持')
  }

  private addPureGroupButton_(): void {
    if (this.controlGroups === undefined) return
    this.addButton(GLFW_KEY_G)
    const item: ControlItem | null=this.selectedItem()
    if (item === null) return
    item.keys=[]; item.keyOrMouse=0; item.label='组开关'
    const target: string=this.controlGroups.find((group: ControlGroup): boolean => group.id !== this.currentControlGroup)?.id ?? this.currentControlGroup
    item.groupActions=[{phase:'press',operation:'toggle',targets:[target]}]
    this.syncSelectedAppearanceVals(); this.refreshControls(); this.openTab('group-actions')
    this.statusMsg='已添加纯组按钮，不发送游戏键；请选择目标组'
  }

  @Builder
  ControlGroupsPanel() {
    Column({space:10}) {
      this.SectionLabel('触控组')
      Text('画布预览与进入游戏时的初始显隐分别设置。当前编辑组始终在画布显示。')
        .fontSize(13).fontColor(EditorTheme.muted).width('100%')
      TextInput({text:this.groupSearch,placeholder:'搜索触控组'}).height(44).fontSize(14)
        .onChange((value: string): void => { this.groupSearch=value })
      ForEach(this.filteredControlGroups_(), (group: ControlGroup) => {
        Row({space:8}) {
          Button(group.name + ' · ' + ((this.controlGroups ?? []).findIndex((value: ControlGroup): boolean => value.id === group.id)+1) +
            (group.id === this.currentControlGroup ? ' · 当前' : '')).layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(group.id === this.currentControlGroup ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(EditorTheme.text).onClick((): void => { this.chooseControlGroup_(group.id) })
          Button(this.previewControlGroups.indexOf(group.id) >= 0 ? '画布显示' : '画布隐藏').height(44).fontSize(12)
            .enabled(group.id !== this.currentControlGroup).onClick((): void => { this.toggleGroupPreview_(group.id) })
        }.width('100%')
      }, (group: ControlGroup): string => group.id)
      if (this.filteredControlGroups_().length === 0) { Text('没有匹配的组；可清空搜索或创建新组').fontColor(EditorTheme.muted).fontSize(13) }
      TextInput({text:this.groupNameDraft,placeholder:'组名（最多64个字符，可同名）'}).height(44).fontSize(14).maxLength(64)
        .onChange((value: string): void => { this.groupNameDraft=value })
      Row({space:8}) {
        Button('新建组').layoutWeight(1).height(44).onClick((): void => { this.createControlGroup_() })
        Button('重命名').layoutWeight(1).height(44).enabled(this.currentGroup_() !== undefined)
          .onClick((): void => { this.renameControlGroup_() })
      }.width('100%')
      if (this.currentGroup_() !== undefined) {
        Row() {
          Text('进入游戏时显示').layoutWeight(1).fontColor(EditorTheme.text).fontSize(14)
          Toggle({type:ToggleType.Switch,isOn:this.currentGroup_()?.initialVisible ?? true})
            .onChange((value: boolean): void => { this.setGroupInitialVisible_(value) })
        }.width('100%')
        Row({space:8}) {
          Button('下层').layoutWeight(1).height(44).onClick((): void => { this.moveGroupOrder_(-1) })
          Button('上层').layoutWeight(1).height(44).onClick((): void => { this.moveGroupOrder_(1) })
          Button('复制组').layoutWeight(1).height(44).onClick((): void => { this.duplicateControlGroup_() })
        }.width('100%')
        Button('仅查看当前组').height(44).width('100%').onClick((): void => { this.previewControlGroups=[this.currentControlGroup]; this.ver++ })
        Button('将所选控件移到当前组').height(44).width('100%').onClick((): void => { this.moveSelectedToGroup_() })
        Button('添加纯组开关按钮').height(44).width('100%').onClick((): void => { this.addPureGroupButton_() })
        if (this.canRestoreGroups) {
          Button('退出编辑后恢复初始显隐').height(44).width('100%').onClick((): void => {
            this.onRestoreGroups(); this.statusMsg='已请求恢复；保存或取消退出编辑后生效'
          })
        }
        Button('删除当前组').height(44).width('100%').enabled(this.currentControlGroup !== this.defaultControlGroupId)
          .onClick((): void => { this.deletingGroup=this.currentControlGroup })
        if (this.currentControlGroup === this.defaultControlGroupId) { Text('默认组负责承接控件，不能删除').fontSize(12).fontColor(EditorTheme.muted) }
      }
      if (this.deletingGroup.length > 0) {
        Text(this.groupDeletionDescription_()).fontSize(14).fontColor(EditorTheme.warning).width('100%')
        Button('成员移到默认组后删除').height(44).width('100%').onClick((): void => { this.deleteControlGroup_(true) })
        Button('连同成员删除').height(44).width('100%').onClick((): void => { this.deleteControlGroup_(false) })
        Button('取消删除').height(44).width('100%').onClick((): void => { this.deletingGroup='' })
      }
      Button('返回布局').height(44).width('100%').onClick((): void => { this.openTab('edit') })
    }.width('100%')
  }

  @Builder
  ControlGroupActionsPanel() {
    Column({space:10}) {
      this.SectionLabel('组动作与分阶段绑定')
      if (!this.selectedIsOrdinaryButton_()) {
        Text('先在画布选择一个普通按钮').fontSize(14).fontColor(EditorTheme.muted)
      } else if (this.controlGroups === undefined) {
        Text('请先创建触控组；现有方案在此之前保持原格式').fontSize(14).fontColor(EditorTheme.muted)
        Button('管理触控组').height(44).onClick((): void => { this.openTab('groups') })
      } else {
        ForEach(['press','longPress','click','doubleClick'], (phase: string) => {
          Button(this.phaseName_(phase)).height(44).width('100%').fontSize(14)
            .backgroundColor(this.groupActionPhase === phase ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(EditorTheme.text).onClick((): void => { this.selectGroupPhase_(phase as ControlActionPhase) })
        }, (phase: string): string => phase)
        Text('本阶段键：' + (this.currentPhaseKeys_().map((key: number): string => glfwKeyName(key)).join(' + ') || '无（可作为纯组按钮）'))
          .fontSize(14).fontColor(EditorTheme.text).width('100%')
        Button('修改本阶段按键').height(44).width('100%').onClick((): void => {
          this.phaseKeyControlId=this.selectedItem()?.id ?? ''; this.phaseKeyPhase=this.groupActionPhase; this.phaseKeyPicker=true
        })
        Row() {
          Text('本阶段按键切换保持').layoutWeight(1).fontSize(14).fontColor(EditorTheme.text)
          Toggle({type:ToggleType.Switch,isOn:this.selectedItem()?.phaseBindings?.find((value: ControlPhaseBinding): boolean => value.phase === this.groupActionPhase)?.autoKeep ?? false})
            .onChange((value: boolean): void => { this.applyPhaseKeys_(this.currentPhaseKeys_(),value) })
        }.width('100%')
        ForEach(this.phaseActionIndices_(), (index: number) => {
          Button(this.groupActionSummary_(index)).height(44).width('100%').fontSize(13)
            .backgroundColor(this.selectedGroupActionIndex === index ? EditorTheme.surfaceActive : EditorTheme.surface)
            .onClick((): void => { this.selectGroupAction_(index) })
        }, (index: number): string => index.toString() + ':' + this.groupActionSummary_(index))
        Row({space:6}) {
          Button('新增动作').height(44).layoutWeight(1).onClick((): void => { this.selectGroupAction_(-1) })
          Button('上移').height(44).layoutWeight(1).enabled(this.selectedGroupAction_() !== undefined)
            .onClick((): void => { this.moveGroupAction_(-1) })
          Button('下移').height(44).layoutWeight(1).enabled(this.selectedGroupAction_() !== undefined)
            .onClick((): void => { this.moveGroupAction_(1) })
        }.width('100%')
        Text(this.selectedGroupAction_() === undefined ? '选择操作，再添加目标以创建新动作' : '编辑选中动作；下列目标按顺序执行')
          .fontSize(12).fontColor(EditorTheme.muted)
        ForEach(this.phaseTargets_(), (id: string,index: number) => {
          Button((index+1).toString()+' · '+(this.controlGroups?.find((group: ControlGroup): boolean => group.id===id)?.name ?? id)+' ×')
            .height(44).width('100%').onClick((): void => { this.removePhaseTarget_(index) })
        }, (id: string,index: number): string => index.toString()+':'+id)
        Row({space:8}) {
          ForEach(['toggle','show','hide'], (operation: string) => {
            Button(operation === 'toggle' ? '切换显示' : operation === 'show' ? '显示' : '隐藏').height(44).layoutWeight(1).fontSize(13)
              .backgroundColor(this.groupActionOperation === operation ? EditorTheme.surfaceActive : EditorTheme.surface)
              .onClick((): void => { this.groupActionOperation=operation as ControlGroupOperation; this.setPhaseTargets_(this.phaseTargets_()) })
          }, (operation: string): string => operation)
        }.width('100%')
        ForEach(this.controlGroups ?? [], (group: ControlGroup) => {
          Button('＋ ' + group.name).height(44).width('100%').fontSize(14)
            .onClick((): void => { this.togglePhaseTarget_(group.id) })
        }, (group: ControlGroup): string => group.id)
        Button('删除选中动作').height(44).width('100%').onClick((): void => { this.setPhaseTargets_([]) })
        Text('动作与目标保持原顺序；重复切换保留次数。取消触摸不触发新动作。').fontSize(12).fontColor(EditorTheme.muted)
      }
      Button('返回布局').height(44).width('100%').onClick((): void => { this.openTab('edit') })
    }.width('100%')
  }

  build() {
    Stack() {
      // 编辑期间只显示草稿，全部真实输入由宿主模态隔离。
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick(() => { this.selectedIdx = -1; this.selectedScaleVal = 100 })

      // 所有按钮（key 含 ver 强制刷新）
      ForEach(this.editorCanvasOrder_(), (index: number) => {
        if (!this.controls[index].hidden && this.editorGroupVisible_(this.controls[index])) {
          this.EditableBtn(this.controls[index], index)
        }
      }, (index: number) => this.controls[index].id + '_v' + this.ver.toString())

      // 自动对齐虚线（仅拖动中显示，松手即消失）：横线约束高度、竖线约束水平位置。
      if (this.dragIdx >= 0 && this.guideY >= 0) {
        Line()
          .width(this.screenWidth).height(1)
          .startPoint([0, 0]).endPoint([this.screenWidth, 0])
          .stroke('#FF448AFF').strokeWidth(1).strokeDashArray([6, 4])
          .position({ x: 0, y: this.guideY })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.dragIdx >= 0 && this.guideX >= 0) {
        Line()
          .width(1).height(this.screenHeight)
          .startPoint([0, 0]).endPoint([0, this.screenHeight])
          .stroke('#FF448AFF').strokeWidth(1).strokeDashArray([6, 4])
          .position({ x: this.guideX, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 工具面板（可拖动 + 可收起）
      this.ToolPanel()

      // 状态条
      if (this.statusMsg.length > 0 && !this.showPanel) {
        Text(this.statusMsg)
          .fontSize(14).fontColor(EditorTheme.warning)
          .backgroundColor('#AA000000').padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .width(Math.max(120, this.screenWidth - 24)).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          .position({ x: 12, y: 80 })
      }


      // 改键 sheet
      if (this.showKeyPicker) {
        KeyPickerSheet({
          currentKeys: this.selectedItem() ? effectiveKeys(this.selectedItem()!) : [],
          onPick: (keys: number[] | null) => {
            this.showKeyPicker = false
            if (keys) this.applyKeys(keys)
          }
        })
      }
      if (this.phaseKeyPicker) {
        KeyPickerSheet({ currentKeys:this.currentPhaseKeys_(), onPick:(keys: number[] | null): void => {
          this.phaseKeyPicker=false
          if (keys !== null) this.applyPhaseKeys_(keys)
        } })
      }

      if (this.showLeaveConfirm) { this.LeaveConfirm() }
    }
    .width('100%').height('100%')
    // 正常编辑覆盖层消费自身交互；Native仍由独立模态隔离，不能只依赖ArkUI命中。
    .hitTestBehavior(HitTestMode.Default)
    .enabled(!this.persistenceBusy)
  }

  @Builder
  EditableBtn(item: ControlItem, index: number) {
    Text(item.type === ControlType.JOYSTICK ? '◐'
      : (item.type === ControlType.HOTBAR_SELECTOR ? '物品栏 ⋯' : effectiveLabel(item)))
      .width(this.itemW(item))
      .height(this.itemH(item))
      // 字号自适应短边，与 GameControls 的渲染口径一致
      .fontSize(this.editBtnFontSize(item))
      .fontWeight(FontWeight.Medium)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      // 面板重绘不重设计画布按键：沿用原预览的白字、蓝色选中/红色锁定提示及虚线框。
      // 几何、透明度和真实控件样式继续取原模型，新主题只用于设置面板自身。
      .fontColor(this.isSel(item, index) ? '#FFFFFFFF' : '#CCFFFFFF')
      .borderRadius(this.editBtnBorderRadius(item))
      .backgroundColor(this.isSel(item, index) ? '#66448AFF'
        : (item.locked ? '#33FF5252' : '#44FFFFFF'))
      // 编辑器预览透明度 = 按钮自身 × 全局，但留地板值 0.35 保证暗按钮仍可见可选。
      .opacity(this.editBtnOpacity(item))
      .border({
        width: this.isSel(item, index) ? 2 : (item.locked ? 1 : 0),
        color: this.isSel(item, index) ? '#448AFF' : '#FF5252',
        style: BorderStyle.Dashed
      })
      .position({
        x: this.itemPxX(item) + this.btnDragOffsetX(item, index),
        y: this.itemPxY(item) + this.btnDragOffsetY(item, index)
      })
      .gesture(
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart(() => {
            if (this.multiSelectMode) {
              // 多选态：拖动 = 成组移动；被拖项未选中则先加入选择。
              if (!this.isMultiSel(item)) this.toggleSelectId(item.id)
              this.groupDragging = true
              this.groupDragDx = 0
              this.groupDragDy = 0
              return
            }
            this.selectForEditor_(index)
            if (item.locked) {
              this.statusMsg = '该按钮已锁定，无法移动'
              return
            }
            this.dragIdx = index
            this.dragStartXPct = item.xPct
            this.dragStartYPct = item.yPct
            this.dragDx = 0
            this.dragDy = 0
            // 每次拖动重置滞回锁与虚线，避免沿用上一次拖动的对齐态。
            this.clearSnapGuides()
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!event) return
            if (this.multiSelectMode) {
              if (this.groupDragging) {
                this.groupDragDx = event.offsetX
                this.groupDragDy = event.offsetY
              }
              return
            }
            if (this.dragIdx === index) {
              // 原始位置（手指位移）→ 自动对齐引擎 → 吸附后位置。把吸附结果写回 dragDx/dragDy，
              // 使按钮渲染即刻贴到对齐线上；手指与按钮的偏差正是"黏滞"手感的来源。
              const rawX = this.itemPxX(item) + event.offsetX
              const rawY = this.itemPxY(item) + event.offsetY
              const snapped = this.applySnap(index, rawX, rawY)
              this.dragDx = snapped.x - this.itemPxX(item)
              this.dragDy = snapped.y - this.itemPxY(item)
            }
          })
          .onActionEnd(() => { if (this.groupDragging) this.commitGroupDrag(); else this.commitDrag() })
          .onActionCancel(() => { if (this.groupDragging) this.commitGroupDrag(); else this.commitDrag() })
      )
      .onClick(() => {
        if (this.multiSelectMode) { this.toggleSelectId(item.id); return }
        this.selectForEditor_(index)
      })
  }

  /**
   * 单选事件的显示入口：同步原属性草稿，并在有足够横向空间时把面板放到所选控件对侧。
   * 只调整编辑器的选择和浮层位置；原控件坐标、锁定判断、拖动/吸附和 Native 输入链均不变。
   * 窄窗口保留用户原面板位置，避免为了换侧让面板或当前控件越界。
   */
  private selectForEditor_(index: number): void {
    this.selectedIdx = index
    this.selectGroupPhase_(this.groupActionPhase)
    this.syncSelectedAppearanceVals()
    const item: ControlItem | null = this.selectedItem()
    if (item !== null && this.screenWidth > this.panelWidth() + this.itemW(item) + 48) {
      const centerX: number = this.itemPxX(item) + this.itemW(item) / 2
      this.panelX = centerX >= this.screenWidth / 2 ? 16 : this.screenWidth - this.panelWidth() - 16
    }
    this.showPanel = true
  }

  // ============= 多选 / 成组拖动 / 批量操作（2026-07-16） =============

  /** 是否处于"选中高亮"（多选态看 selectedIds，单选态看 selectedIdx）。 */
  private isSel(item: ControlItem, index: number): boolean {
    return this.multiSelectMode ? this.selectedIds.includes(item.id) : (this.selectedIdx === index)
  }
  private isMultiSel(item: ControlItem): boolean {
    return this.selectedIds.includes(item.id)
  }

  /** 拖动渲染偏移：单选拖动看 dragIdx；多选成组拖动时所有选中项一起偏移。 */
  private btnDragOffsetX(item: ControlItem, index: number): number {
    if (!this.multiSelectMode) return this.dragIdx === index ? this.dragDx : 0
    return (this.groupDragging && this.isMultiSel(item) && !item.locked) ? this.groupDragDx : 0
  }
  private btnDragOffsetY(item: ControlItem, index: number): number {
    if (!this.multiSelectMode) return this.dragIdx === index ? this.dragDy : 0
    return (this.groupDragging && this.isMultiSel(item) && !item.locked) ? this.groupDragDy : 0
  }

  /** 切换某 id 的选中态（多选）。bump ver 强制列表重渲染。 */
  private toggleSelectId(id: string): void {
    if (this.selectedIds.includes(id)) {
      this.selectedIds = this.selectedIds.filter((x: string) => x !== id)
    } else {
      this.selectedIds = this.selectedIds.concat([id])
    }
    this.ver++
  }

  /** 开/关多选模式。关闭时清空选择集。 */
  private setMultiSelect(on: boolean): void {
    this.multiSelectMode = on
    if (!on) {
      this.selectedIds = []
      this.groupDragging = false
    } else {
      // 进入多选清掉单选高亮，避免两套高亮并存
      this.selectedIdx = -1
    }
    this.ver++
  }

  /** 全选（多选）：把所有非隐藏控件加入选择集。 */
  private selectAllControls(): void {
    let ids: string[] = []
    for (let c of this.controls) if (!c.hidden) ids.push(c.id)
    this.selectedIds = ids
    this.ver++
  }
  private clearSelection(): void {
    this.selectedIds = []
    this.ver++
  }

  /** 当前多选选中的控件列表（按 controls 顺序）。 */
  private multiSelectedItems(): ControlItem[] {
    let out: ControlItem[] = []
    for (let c of this.controls) if (this.selectedIds.includes(c.id)) out.push(c)
    return out
  }

  /** 成组拖动提交：所有选中的非锁定控件按位移整体移动，逐个夹进屏内。 */
  private commitGroupDrag(): void {
    if (!this.groupDragging) return
    const dxPct = this.groupDragDx / this.screenWidth
    const dyPct = this.groupDragDy / this.screenHeight
    if (dxPct !== 0 || dyPct !== 0) {
      this.pushUndo()
      for (let c of this.controls) {
        if (!this.selectedIds.includes(c.id) || c.locked) continue
        let nx = c.xPct + dxPct
        let ny = c.yPct + dyPct
        nx = Math.max(0, Math.min(1 - this.itemW(c) / this.screenWidth, nx))
        ny = Math.max(0, Math.min(1 - this.itemH(c) / this.screenHeight, ny))
        c.xPct = nx
        c.yPct = ny
        if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
      }
      this.refreshControls()
    }
    this.groupDragging = false
    this.groupDragDx = 0
    this.groupDragDy = 0
  }

  /**
   * 批量对齐。mode='auto' 按选中中心包围盒的展开方向自动判轴：X 展开 ≥ Y 展开 → 判为一排 → 统一 Y
   * （水平对齐）；否则统一 X（垂直对齐）。'h' 强制水平对齐（同一水平线），'v' 强制垂直对齐（同一竖线）。
   * 基准取选中项的平均中心。
   */
  private batchAlign(mode: string): void {
    const items = this.multiSelectedItems()
    if (items.length < 2) { this.statusMsg = '请至少选择 2 个按钮'; return }
    let minX = Number.MAX_VALUE, maxX = -Number.MAX_VALUE
    let minY = Number.MAX_VALUE, maxY = -Number.MAX_VALUE
    let sumCX = 0, sumCY = 0
    for (let c of items) {
      const cx = this.itemCenterX(c), cy = this.itemCenterY(c)
      if (cx < minX) minX = cx; if (cx > maxX) maxX = cx
      if (cy < minY) minY = cy; if (cy > maxY) maxY = cy
      sumCX += cx; sumCY += cy
    }
    let axis = mode
    if (mode === 'auto') axis = (maxX - minX) >= (maxY - minY) ? 'h' : 'v'
    this.pushUndo()
    if (axis === 'h') {
      const avgCY = sumCY / items.length
      for (let c of items) {
        let topPx = avgCY - this.itemH(c) / 2
        let yPct = topPx / this.screenHeight
        c.yPct = Math.max(0, Math.min(1 - this.itemH(c) / this.screenHeight, yPct))
        if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
      }
      this.statusMsg = '已水平对齐 ' + items.length.toString() + ' 个按钮'
    } else {
      const avgCX = sumCX / items.length
      for (let c of items) {
        let leftPx = avgCX - this.itemW(c) / 2
        let xPct = leftPx / this.screenWidth
        c.xPct = Math.max(0, Math.min(1 - this.itemW(c) / this.screenWidth, xPct))
        if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
      }
      this.statusMsg = '已垂直对齐 ' + items.length.toString() + ' 个按钮'
    }
    this.refreshControls()
  }

  /**
   * 批量等间距：沿主轴（展开更大的轴）把相邻控件的边到边间距统一为「对齐间距」滑条值（snapGap），
   * 首个控件位置不动，其余依次贴放；同时把副轴对齐到平均中心，形成整齐一排/一列。
   */
  private batchEqualSpacing(): void {
    const items = this.multiSelectedItems()
    if (items.length < 2) { this.statusMsg = '请至少选择 2 个按钮'; return }
    let minX = Number.MAX_VALUE, maxX = -Number.MAX_VALUE
    let minY = Number.MAX_VALUE, maxY = -Number.MAX_VALUE
    let sumCX = 0, sumCY = 0
    for (let c of items) {
      const cx = this.itemCenterX(c), cy = this.itemCenterY(c)
      if (cx < minX) minX = cx; if (cx > maxX) maxX = cx
      if (cy < minY) minY = cy; if (cy > maxY) maxY = cy
      sumCX += cx; sumCY += cy
    }
    const horizontal = (maxX - minX) >= (maxY - minY)
    const gap = this.snapGap
    this.pushUndo()
    if (horizontal) {
      const sorted = items.sort((a: ControlItem, b: ControlItem) => this.itemPxX(a) - this.itemPxX(b))
      const avgCY = sumCY / items.length
      let cursor = this.itemPxX(sorted[0])
      for (let i = 0; i < sorted.length; i++) {
        const c = sorted[i]
        if (i > 0) cursor = cursor + gap
        let leftPx = cursor
        leftPx = Math.max(0, Math.min(this.screenWidth - this.itemW(c), leftPx))
        c.xPct = leftPx / this.screenWidth
        let topPx = avgCY - this.itemH(c) / 2
        c.yPct = Math.max(0, Math.min(1 - this.itemH(c) / this.screenHeight, topPx / this.screenHeight))
        if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
        cursor = this.itemPxX(c) + this.itemW(c)
      }
    } else {
      const sorted = items.sort((a: ControlItem, b: ControlItem) => this.itemPxY(a) - this.itemPxY(b))
      const avgCX = sumCX / items.length
      let cursor = this.itemPxY(sorted[0])
      for (let i = 0; i < sorted.length; i++) {
        const c = sorted[i]
        if (i > 0) cursor = cursor + gap
        let topPx = cursor
        topPx = Math.max(0, Math.min(this.screenHeight - this.itemH(c), topPx))
        c.yPct = topPx / this.screenHeight
        let leftPx = avgCX - this.itemW(c) / 2
        c.xPct = Math.max(0, Math.min(1 - this.itemW(c) / this.screenWidth, leftPx / this.screenWidth))
        if (c.type === ControlType.HOTBAR_SELECTOR) c.hotbarUserPlaced = true
        cursor = this.itemPxY(c) + this.itemH(c)
      }
    }
    this.refreshControls()
    this.statusMsg = '已按 ' + gap.toString() + 'vp 间距' + (horizontal ? '横向' : '纵向') + '等距排列'
  }

  /** 批量删除：跳过系统按钮，含物品栏则置 hotbarAutoAdded。 */
  private batchDelete(): void {
    if (this.selectedIds.length === 0) { this.statusMsg = '未选择任何按钮'; return }
    this.pushUndo()
    let skipSystem = 0
    let deleted = 0
    const kept: ControlItem[] = []
    for (let c of this.controls) {
      if (this.selectedIds.includes(c.id)) {
        if (c.systemAction !== undefined) { skipSystem++; kept.push(c); continue }
        if (c.type === ControlType.HOTBAR_SELECTOR) this.hotbarAutoAdded = true
        deleted++
        continue
      }
      kept.push(c)
    }
    this.controls = kept
    this.selectedIds = []
    this.refreshControls()
    this.statusMsg = '已删除 ' + deleted.toString() + ' 个'
      + (skipSystem > 0 ? '，' + skipSystem.toString() + ' 个系统按钮已跳过' : '')
  }

  /** 批量锁定/解锁。 */
  private batchSetLocked(lock: boolean): void {
    const items = this.multiSelectedItems()
    if (items.length === 0) { this.statusMsg = '未选择任何按钮'; return }
    this.pushUndo()
    for (let c of items) c.locked = lock
    this.refreshControls()
    this.statusMsg = (lock ? '已锁定 ' : '已解锁 ') + items.length.toString() + ' 个'
  }

  /** 批量复制：对每个非系统选中项换新 id 后偏移粘贴，新副本成为新的选择集。 */
  private batchDuplicate(): void {
    const items = this.multiSelectedItems()
    if (items.length === 0) { this.statusMsg = '未选择任何按钮'; return }
    this.pushUndo()
    let newIds: string[] = []
    let dupCount = 0
    for (let src of items) {
      if (src.systemAction !== undefined) continue
      const dup = cloneItemWithFreshIds(src, this.controls)
      // 批量复制与单个复制一致，过大控件贴零边界，不能产生无法保存的负百分比。
      dup.xPct = Math.max(0, Math.min(1 - this.itemW(dup) / this.screenWidth, src.xPct + 0.04))
      dup.yPct = Math.max(0, Math.min(1 - this.itemH(dup) / this.screenHeight, src.yPct + 0.04))
      this.controls.push(dup)
      newIds.push(dup.id)
      dupCount++
    }
    this.selectedIds = newIds
    this.refreshControls()
    this.statusMsg = '已复制 ' + dupCount.toString() + ' 个'
  }

  /** 选中按钮后同步一级/二级面板的滑条初值（缩放 + 透明度），保证两级显示相等。 */
  private syncSelectedAppearanceVals(): void {
    const item = this.selectedItem()
    if (!item) return
    this.sliderUndoKey = ''
    this.selectedScaleVal = Math.round(item.itemScale * 100)
    this.selectedOpacityVal = this.curOpacityPct()
    this.labelDraft = item.label
    this.syncPositionDraft_()
  }

  // 面板拖动结束：提交位置。y 夹到 [0, panelMaxTop] —— 保证底栏永不越出屏幕（再往下只能滚动内容）。
  private commitPanelDrag(): void {
    const w = this.panelWidth()
    let nx = this.panelX + this.panelDragDx
    let ny = this.panelY + this.panelDragDy
    nx = Math.max(-(w - 80), Math.min(this.screenWidth - 80, nx))
    ny = Math.max(0, Math.min(this.panelMaxTop(), ny))
    this.panelX = nx
    this.panelY = ny
    this.panelDragDx = 0
    this.panelDragDy = 0
  }

  // ============= 统一面板 Tab 切换 =============

  /**
   * 切换唯一面板的当前 Tab（面板常驻，靠 showPanel 收起/展开）。
   * tab: 'edit' | 'style' | 'global' | 'gamepad' | 'profiles' | 'multi'
   */
  private openTab(tab: string): void {
    this.sliderUndoKey = ''
    this.activeSheet = tab
    if (tab === 'group-actions') this.selectGroupPhase_(this.groupActionPhase)
    this.showPanel = true
    // 样式 Tab（单选）打开时同步标签草稿，保证 TextInput 显示当前按钮的标签。
    if (tab === 'position') this.syncPositionDraft_()
    if (tab === 'style' && !this.multiSelectMode) {
      const it = this.selectedItem()
      this.labelDraft = it ? it.label : ''
    }
  }

  /** 摇杆快捷入口明确定位移动分区；只改导航，不写touch草稿、撤销或运行配置。 */


  /** 添加入口只展开目录，不预先创建占位按钮，也不改变原单选/多选和撤销状态。 */
  private openAddPanel_(): void {
    this.openTab('add')
  }

  /** 返回完整布局导航时按新骨架夹回顶部，防止在较矮添加面板中下移后把固定底栏推出屏外。 */
  private returnFromAddPanel_(): void {
    this.openTab('edit')
    this.panelY = Math.max(0, Math.min(this.panelTopBase(), this.panelMaxTop()))
  }

  /** 目录条目为明确的有限集合；不提供尚无创建能力的摇杆、触控区或旧抽屉入口。 */
  private addControlOptions_(): EditorAddControlOption[] {
    return [
      { id: 'button', title: '普通按键', description: '绑定键盘键、鼠标键或组合键', search: '普通按钮 按键 button keyboard mouse', icon: AppIconName.Keyboard, common: false },
      { id: 'joystick', title: '移动摇杆', description: '选择已有摇杆，或恢复默认摇杆', search: '', icon: AppIconName.GameController, common: false },
      { id: 'hotbar', title: '物品栏直点条', description: '已存在则选中；再次点按重新对齐', search: '物品栏 快捷栏 hotbar', icon: AppIconName.Hotbar, common: false },
      { id: 'space', title: 'Space', description: '跳跃', search: '空格 space jump 跳跃', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_SPACE },
      { id: 'shift', title: 'Shift', description: '潜行', search: 'shift 潜行 蹲下', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_LEFT_SHIFT },
      { id: 'e', title: 'E', description: '背包', search: 'e 背包 inventory', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_E },
      { id: 'esc', title: 'Esc', description: '游戏菜单', search: 'esc escape 返回 菜单', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_ESCAPE }
    ]
  }

  /** 搜索同时匹配名称、用途和明确别名；不因为控件类型属于另一组而把匹配结果隐藏。 */


  /** 选定后仍走原新增/物品栏入口；仅结束会话多选以便当前新建或既有控件成为明确单选目标。 */
  private addControlFromPanel_(id: string): void {
    const option: EditorAddControlOption | undefined = this.addControlOptions_().find((entry: EditorAddControlOption): boolean => entry.id === id)
    if (option === undefined) { this.statusMsg = '没有可添加的控件，请重新选择'; return }
    this.setMultiSelect(false)
    if (option.id === 'joystick') this.addJoystick_()
    else if (option.id === 'hotbar') this.addHotbar()
    else this.addButton(option.code)
  }

  /** 样式编辑的目标控件集：多选态=选择集，单选态=当前选中项（0/1 个）。 */
  private styleTargets(): ControlItem[] {
    if (this.multiSelectMode) return this.multiSelectedItems()
    const item = this.selectedItem()
    return item ? [item] : []
  }
  /** 样式滑条初值参考的"主项"：目标集末项（最后选中的），无则 null。 */
  private stylePrimary(): ControlItem | null {
    const t = this.styleTargets()
    return t.length > 0 ? t[t.length - 1] : null
  }

  // UI 重绘 2026-07-11（承接 §五 Pencil 设计稿）：可复用「操作 chip」——统一图标库图标（AppIcon，非 emoji）
  // + 文字 + 语义底色，44vp 高圆角操作项。取代旧的一排小 Button，信息层级更清晰、触控更友好。
  // UI 重绘：分区小标题（左侧竖条 + 文字），用于「选中 / 全局」信息分区。
  @Builder
  SectionLabel(text: string) {
    Text(text).fontSize(14).fontWeight(FontWeight.Medium).fontColor(EditorTheme.muted)
      .width('100%').height(28).margin({ top: 8, bottom: 4 })
  }

  // 选中控件的标题文案（用于分区标题）。
  private selectedTitle(): string {
    const item = this.selectedItem()
    if (!item) return ''
    if (item.label && item.label.length > 0) return item.label
    if (item.type === ControlType.JOYSTICK) return '摇杆'
    if (item.type === ControlType.SCROLL_WHEEL) return '滚轮控件'
    if (item.type === ControlType.HOTBAR_SELECTOR) return '物品栏'
    if (item.type === ControlType.DRAWER) return '抽屉'
    return '按键'
  }

  /** 鼠标由系统提供菜单精细操作；编辑面板只展示可保存的几何/外观属性，避免无效的改键、场景或删除选项。 */
  private selectedIsSystemMouse(): boolean { return this.selectedItem()?.systemAction==='mouse' }

  @Builder
  PanelNavigation() {
    // 窄高窗口只保留一套导航；它与内容共享滚动，不复制一份隐藏的控件树。
    this.UnifiedTabBar()
  }

  @Builder
  ToolPanel() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Column().width(4).height(20).borderRadius(2).backgroundColor(EditorTheme.muted)
        if (this.showPanel) {
          Column({ space: 2 }) {
            Text(this.activeSheet === 'add' ? '添加控件' : this.selectedIdx >= 0 ? this.selectedTitle() : '按键设置')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor(EditorTheme.text).maxLines(1)
            Text(this.activeSheet === 'add' ? '添加后绑定，再拖动定位' : this.profileName).fontSize(12).fontColor(EditorTheme.muted).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button() { AppIcon({ name: AppIconName.Minus, iconSize: 20, color: EditorTheme.muted }) }
            .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(12)
            .accessibilityText('收起按键设置面板').onClick((): void => { this.showPanel = false })
        } else {
          Button('按键设置').fontSize(14).height(44).layoutWeight(1).backgroundColor(Color.Transparent)
            .fontColor(EditorTheme.text).onClick((): void => { this.showPanel = true })
          Button() { AppIcon({ name: AppIconName.Undo, iconSize: 20, color: EditorTheme.muted }) }
            .width(44).height(44).backgroundColor(Color.Transparent).enabled(this.canUndo())
            .accessibilityText('撤销').onClick((): void => { this.undo() })
          Button() { AppIcon({ name: AppIconName.Plus, iconSize: 20, color: EditorTheme.accent }) }
            .width(44).height(44).backgroundColor(EditorTheme.surfaceActive)
            .accessibilityText('添加控件').onClick((): void => { this.openAddPanel_() })
          Button('保存退出').height(44).fontSize(14).backgroundColor(EditorTheme.accent)
            .fontColor(EditorTheme.panel).borderRadius(12).onClick((): void => { this.saveEditor_() })
        }
      }.height(56).width('100%').padding({ left: 16, right: 12 })
        .gesture(PanGesture({ fingers: 1, distance: 4 })
          .onActionStart(() => {
            this.panelDragStartX = this.panelX; this.panelDragStartY = this.panelY
            this.panelDragDx = 0; this.panelDragDy = 0
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!event) return
            const baseX: number = this.panelX >= 0 ? this.panelX : (this.screenWidth - this.panelWidth()) / 2
            const baseY: number = this.panelTopBase()
            this.panelDragDx = Math.max(-(baseX + this.panelWidth() - 80), Math.min(this.screenWidth - 80 - baseX, event.offsetX))
            this.panelDragDy = Math.max(-baseY, Math.min(this.panelMaxTop() - baseY, event.offsetY))
          }).onActionEnd(() => { this.commitPanelDrag() }))
      if (this.showPanel) {
        if (!this.compactPanel() && this.activeSheet !== 'add') { this.PanelNavigation() }
        Scroll() {
          Column({ space: 12 }) {
            if (this.compactPanel() && this.activeSheet !== 'add') { this.PanelNavigation() }
            if (this.statusMsg.length > 0) {
              Text(this.statusMsg).fontSize(14).fontColor(EditorTheme.warning).padding(12)
                .width('100%').backgroundColor(EditorTheme.surface).borderRadius(12).id('layout-editor-status')
            }
            if (this.activeSheet === 'add') { this.AddControlPanel() }
            else if (this.activeSheet === 'edit') { this.EditTabContent() }
            else if (this.activeSheet === 'behavior') { this.BehaviorTabContent() }
            else if (this.activeSheet === 'position') { this.PositionTabContent() }
            else if (this.activeSheet === 'style') { this.StyleTabContent() }
            else if (this.activeSheet === 'alignment') { this.AlignmentOptions() }
            else if (this.activeSheet === 'multi') { this.MultiTabContent() }
            else if (this.activeSheet === 'groups') { this.ControlGroupsPanel() }
            else if (this.activeSheet === 'group-actions') { this.ControlGroupActionsPanel() }
          }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 12 })
        }.width('100%').scrollBar(BarState.Auto).constraintSize({ maxHeight: this.panelContentMaxH() })
        if (this.activeSheet === 'add') { this.AddControlFooter() }
        else { this.ActionFooter() }
      }
    }.width(this.panelWidth()).backgroundColor(EditorTheme.panel).borderRadius(EditorTheme.radiusPanel)
      .border({ width: 1, color: EditorTheme.stroke })
      .position({ x: (this.panelX >= 0 ? this.panelX : (this.screenWidth - this.panelWidth()) / 2) + this.panelDragDx,
        y: this.panelTopBase() + this.panelDragDy })
  }

  // 编辑 Tab：多选横幅 + 选中控件编辑 + 全局缩放/透明 + 添加按钮。
  @Builder
  EditTabContent() {
    Column({ space: 12 }) {
      if (this.multiSelectMode) { this.MultiSelectBanner() }
      if (!this.multiSelectMode && this.selectedIdx >= 0 && this.selectedItem() !== null) {
        this.SelectedItemControls()
      } else {
        this.SectionLabel('整体布局')
        Row() { Text('全局缩放').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.globalScaleVal.toString() + '%').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.globalScaleVal, min: 50, max: 200, step: 5 })
          .width('100%').height(28).selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('globalScale', mode, this.globalScale !== value / 100)) return
            this.globalScale = value / 100; this.globalScaleVal = Math.round(value); this.refreshControls()
          })
        Row() { Text('全局透明度').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.globalOpacityVal.toString() + '%').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.globalOpacityVal, min: 20, max: 100, step: 5 })
          .width('100%').height(28).selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('globalOpacity', mode, this.globalOpacity !== value / 100)) return
            this.globalOpacity = value / 100; this.globalOpacityVal = Math.round(value); this.refreshControls()
          })
        Text('点选画面中的按键进行设置，拖动可调整位置。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
      }
      Button('＋ 添加控件').height(48).fontSize(14).width('100%').backgroundColor(EditorTheme.surfaceActive)
        .fontColor(EditorTheme.accent).borderRadius(12).onClick((): void => { this.openAddPanel_() })
      Button('触控组 · ' + (this.controlGroups?.length ?? 0).toString() + ' ›').height(48).fontSize(14).width('100%')
        .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).borderRadius(12)
        .onClick((): void => { this.openTab('groups') })
    }.width('100%')
  }

  /** 第07屏的独立添加目录；仍在唯一面板滚动区中，不新增悬浮层、持久状态或输入订阅。 */
  /** 添加目录直接列出已有能力；普通键选择仍由键盘选择器搜索。 */
  @Builder
  AddControlPanel() {
    Column({space:8}) {
      ForEach(this.addControlOptions_(), (option: EditorAddControlOption) => {
        Button(option.title+' · '+option.description).height(48).width('100%').fontSize(14)
          .fontColor(EditorTheme.text).backgroundColor(EditorTheme.surface).borderRadius(12)
          .id('layout-add-option-'+option.id).onClick((): void => { this.addControlFromPanel_(option.id) })
      }, (option: EditorAddControlOption): string => option.id)
    }.width('100%')
  }

  /** 现阶段一个基础移动摇杆；恢复只增加缺失控件，不重置用户其它布局。 */
  private addJoystick_(): void {
    const existing: number=this.controls.findIndex((item: ControlItem): boolean => item.type===ControlType.JOYSTICK)
    if (existing>=0) { this.selectForEditor_(existing); this.openTab('edit'); return }
    const original: ControlItem | undefined=getDefaultLayout().controls.find((item: ControlItem): boolean => item.type===ControlType.JOYSTICK)
    if (original===undefined) return
    const item: ControlItem=cloneControlItem(original)
    item.id=generateControlId(this.controls)
    if (this.controlGroups!==undefined) item.controlGroupId=this.currentControlGroup || this.defaultControlGroupId
    this.pushUndo(); this.controls=this.controls.concat([item]); this.refreshControls()
    this.selectForEditor_(this.controls.length-1); this.openTab('edit')
    this.statusMsg='已恢复移动摇杆，可拖动和调整大小'
  }

  /** 添加目录固定底部只返回布局；保存/取消仍由原布局底栏处理，不在此另开保存事务。 */
  @Builder
  AddControlFooter() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Back, iconSize: 18, color: EditorTheme.text })
          Text('返回布局').fontSize(14).fontColor(EditorTheme.text)
        }.justifyContent(FlexAlign.Center).width('100%')
      }.width('100%').height(48).backgroundColor(EditorTheme.panel).borderRadius(12)
        .border({ width: 1, color: EditorTheme.stroke }).id('layout-add-back')
        .onClick((): void => { this.returnFromAddPanel_() })
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  // 常驻操作底栏沿用原布局；所有存储动作由有异常收口的串行入口执行。
  @Builder
  ActionFooter() {
    Row({ space: 8 }) {
      Button() { AppIcon({ name: AppIconName.Undo, iconSize: 20, color: EditorTheme.muted }) }
        .width(44).height(48).backgroundColor(Color.Transparent).enabled(this.canUndo())
        .accessibilityText('撤销').onClick((): void => { this.undo() })
      Button('取消').height(48).fontSize(14).padding({ left: 4, right: 4 }).layoutWeight(1)
        .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).borderRadius(12)
        .onClick((): void => { this.requestCancel_() })
      Button(this.persistenceBusy ? '处理中' : '保存').height(48).fontSize(14).padding({ left: 4, right: 4 }).layoutWeight(1)
        .backgroundColor(EditorTheme.accent).fontColor(EditorTheme.panel).borderRadius(12)
        .onClick((): void => { this.saveEditor_() })
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  // UI 重绘 2026-07-11：选中控件区——分区标题 + 大小/透明滑条 + 带字形语义色的操作 chip。
  @Builder
  SelectedItemControls() {
    Column({ space: 12 }) {
      // 动态标题直接在当前UI依赖作用域读取选中状态，不能经Builder按值参数保留首次文本快照。
      // 静态分区仍复用SectionLabel；这里只修正文案刷新，不新增状态、监听或改变选中业务。
      Text('选中 · ' + this.selectedTitle()).fontSize(14).fontWeight(FontWeight.Medium).fontColor(EditorTheme.muted)
        .width('100%').height(28).margin({ top: 8, bottom: 4 })
      if (this.selectedIsSystemMouse()) {
        Text('系统鼠标入口：遵循显示策略与按键显隐，可调整位置与外观，不能复制或删除。')
          .fontSize(14).fontColor(EditorTheme.muted).width('100%')
      } else if (!this.selectedIsOrdinaryButton_()) {
        Text(this.selectedControlDescription_()).fontSize(14).fontColor(EditorTheme.muted).width('100%')
      }
      Row({ space: 8 }) {
        TextInput({ text: this.labelDraft, placeholder: this.selectedSupportsKeyBinding_() ? '显示文字（留空使用键名）' : '显示文字（可选）' })
          .height(44).fontSize(14).layoutWeight(1).backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text)
          .borderRadius(12).onChange((text: string): void => { this.labelDraft = text })
        Button('应用').height(44).fontSize(14).backgroundColor(EditorTheme.surfaceActive).fontColor(EditorTheme.accent)
          .borderRadius(12).onClick((): void => { this.applyLabel() })
      }.width('100%')
      if (this.selectedSupportsKeyBinding_()) {
        Button((this.selectedIsOrdinaryButton_() ? '绑定：' : '聊天绑定：') + this.selectedBindingLabel_()).height(48).width('100%').fontSize(14)
          .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).borderRadius(12)
          .onClick((): void => {
            if (this.selectedItem()?.phaseBindings !== undefined) this.openTab('group-actions')
            else this.showKeyPicker = true
          })
      }
      if (this.selectedIsOrdinaryButton_()) {
        Button('组动作与分阶段绑定 ›').height(44).fontSize(14).width('100%')
          .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.accent).borderRadius(12)
          .onClick((): void => { this.openTab('group-actions') })
        if (this.selectedItem()?.phaseBindings === undefined) {
        Row({ space: 6 }) {
          ForEach(['press', 'toggle', 'doubleTap', 'longPress'], (mode: string): void => {
            Button(this.triggerName_(mode)).fontSize(14).height(44).padding({ left: 4, right: 4 }).layoutWeight(1)
              .backgroundColor(this.selectedTrigger_() === mode ? EditorTheme.surfaceActive : EditorTheme.surface)
              .fontColor(this.selectedTrigger_() === mode ? EditorTheme.accent : EditorTheme.muted).borderRadius(12)
              .onClick((): void => { this.chooseTrigger_(mode as TriggerMode) })
          }, (mode: string): string => mode)
        }.width('100%')
        }
      }
      // 场景与显示仍对专用控件有效，不能随普通按键的绑定/触发入口一起隐藏。
      if (!this.selectedIsSystemMouse()) {
        Button(this.selectedIsOrdinaryButton_() ? '场景、显示策略、瞄准与连滑 ›' : '场景与显示策略 ›').fontSize(14).height(48).width('100%')
          .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).borderRadius(12)
          .onClick((): void => { this.openTab('behavior') })
      }
      Row({ space: 8 }) {
        EditorChip({ icon: AppIconName.Appearance, label: '外观', bg: EditorTheme.surface, onTap: () => { this.openTab('style') } })
        EditorChip({ icon: AppIconName.DragHandle, label: '位置', bg: EditorTheme.surface, onTap: () => { this.openTab('position') } })
        EditorChip({ icon: this.selectedIsLocked() ? AppIconName.Unlock : AppIconName.Lock,
          label: this.lockedLabel(), bg: EditorTheme.surface, onTap: () => { this.toggleLocked() } })
      }
      if (this.selectedItem()?.type === ControlType.HOTBAR_SELECTOR) {
        Text('透明直点条：点击或扫选真实快捷栏。拖动或缩放后保留手动定位。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Button('重新对齐真实快捷栏').height(44).width('100%').fontSize(14)
          .backgroundColor(EditorTheme.surfaceActive).fontColor(EditorTheme.accent).borderRadius(12)
          .onClick((): void => { this.addHotbar() })
      }
      if (this.selectedItem()?.type === ControlType.JOYSTICK) {
        Text('移动行为在独立触控设置中调整。').fontSize(12).fontColor(EditorTheme.muted)
      }
      // 复制/删除继续遵循原业务保护：全部系统入口不可复制或删除，专用非系统控件仍可操作。
      if (this.selectedItem()?.systemAction === undefined) {
        Row({ space: 8 }) {
          EditorChip({ icon: AppIconName.Copy, label: '复制', bg: EditorTheme.surface, onTap: () => { this.duplicateSelected() } })
          EditorChip({ icon: AppIconName.Trash, label: '删除', bg: EditorTheme.surface, onTap: () => { this.deleteSelected() } })
        }
      }
    }.width('100%')
  }

  /**
   * 用户显隐三态循环。强显覆盖场景及全局显隐档，显式hidden、解绑与仅游戏控件能力仍优先。
   * 运行投影解释同一字段，不在编辑器里改写场景或隐藏字段；恢复自动时原场景仍保留。
   */
  private cycleVisibility(): void {
    const item = this.selectedItem()
    if (!item) return
    // 本轮只接入全局显隐，不扩展系统入口的高级行为编辑；已保存策略由加载/投影保留，不再强清。
    if(item.systemAction==='mouse') { this.statusMsg='鼠标入口遵循已保存策略与按键显隐，可移动和调整外观'; return }
    const order: VisibilityOverride[] = ['auto', 'force_show', 'force_hide']
    const cur = item.visibilityOverride ?? 'auto'
    const idx = order.indexOf(cur)
    const next = order[(idx + 1) % order.length]
    this.pushUndo()
    item.visibilityOverride = next === 'auto' ? undefined : next
    this.refreshControls()
    this.statusMsg = '显示策略 = ' + this.visibilityLabelText(next)
  }

  /**
   * 拖动瞄准开关（2026-05-30）：按住该按钮保持 PRESS，手指拖动转视角，抬手才 RELEASE。
   * 典型用法：右键蓄力弓箭/举盾时拖动瞄准。仅对普通按钮有意义。
   */
  private toggleDragLook(): void {
    const item = this.selectedItem()
    if (!item) return
    this.pushUndo()
    item.dragLook = !item.dragLook
    if (item.dragLook) item.swipeGroup = undefined
    this.refreshControls()
    this.statusMsg = item.dragLook ? '已开启拖动瞄准，连滑已关闭' : '已关闭拖动瞄准'
  }

  /** 连滑必须由用户明确分组；不自动把相邻攻击/放置键串成一串。 */
  private cycleSwipeGroup(): void {
    const item = this.selectedItem()
    if (!item || item.type !== ControlType.BUTTON || item.systemAction !== undefined) return
    if ((item.trigger ?? 'press') !== 'press' || item.dragLook === true) {
      this.statusMsg = '连滑需要按住触发，并关闭拖动瞄准'
      return
    }
    const groups: string[] = ['', '1', '2', '3']
    const index: number = groups.indexOf(item.swipeGroup ?? '')
    this.pushUndo()
    const group: string = groups[(index+1)%groups.length]
    item.swipeGroup = group.length > 0 ? group : undefined
    this.refreshControls()
    this.statusMsg = group.length > 0 ? '已加入连滑组 ' + group + '；滑出释放，滑入同组按下' : '连滑已关闭'
  }

  private swipeGroupLabel(): string {
    const item = this.selectedItem()
    return item?.swipeGroup ? '连滑 ' + item.swipeGroup : '连滑关'
  }

  private dragLookLabel(): string {
    const item = this.selectedItem()
    return (item && item.dragLook) ? '瞄准✓' : '瞄准'
  }

  private dragLookBg(): string {
    const item = this.selectedItem()
    return (item && item.dragLook) ? EditorTheme.surfaceActive : EditorTheme.surface
  }

  /**
   * 场景可见性三态循环（2026-05-30）：游戏中 → 菜单 → 始终 → 游戏中。
   *   游戏中 = 仅 grabbed（操作角色时）；菜单 = 仅背包/选项等鼠标可见时；始终 = 两者都显示。
   */
  private cycleScene(): void {
    const item = this.selectedItem()
    if (!item) return
    // 场景编辑仍按系统入口限制；新入口默认兼容游戏/菜单，既有来源的场景设置在加载时保留。
    if(item.systemAction==='mouse') { this.statusMsg='鼠标入口默认用于游戏和菜单，保留已保存的场景设置'; return }
    const order: ControlScene[] = ['game', 'menu', 'always']
    const cur = controlScene(item)
    const next = order[(order.indexOf(cur) + 1) % order.length]
    this.pushUndo()
    setControlScene(item, next)
    this.refreshControls()
    this.statusMsg = '显示场景 = ' + this.sceneLabelText(next)
  }

  private sceneLabel(): string {
    const item = this.selectedItem()
    return this.sceneLabelText(item ? controlScene(item) : 'always')
  }

  private sceneLabelText(s: ControlScene): string {
    if (s === 'game') return '游戏中'
    if (s === 'menu') return '菜单'
    return '始终'
  }

  /** 游戏中 = 蓝；菜单 = 紫；始终 = 绿 */
  private sceneBg(): string {
    const item = this.selectedItem()
    const s = item ? controlScene(item) : 'always'
    if (s === 'game') return EditorTheme.surfaceActive
    if (s === 'menu') return EditorTheme.surfaceActive
    return EditorTheme.surfaceActive
  }

  private visibilityLabel(): string {
    const item = this.selectedItem()
    const ov = item?.visibilityOverride ?? 'auto'
    return this.visibilityLabelText(ov)
  }

  private visibilityLabelText(ov: VisibilityOverride): string {
    if (ov === 'force_show') return '强显'
    if (ov === 'force_hide') return '强隐'
    return '自动'
  }

  /** auto = 灰；force_show = 绿；force_hide = 红，按钮颜色一眼区分 */
  private visibilityBg(): string {
    const item = this.selectedItem()
    const ov = item?.visibilityOverride ?? 'auto'
    if (ov === 'force_show') return EditorTheme.surfaceActive
    if (ov === 'force_hide') return '#44FF5252'
    return EditorTheme.surface
  }

  private triggerLabel(): string {
    const item = this.selectedItem()
    const t = item?.trigger ?? 'press'
    if (t === 'press') return '按住'
    if (t === 'toggle') return '切换'
    if (t === 'doubleTap') return '双击'
    return '长按'
  }

  private lockedLabel(): string {
    const item = this.selectedItem()
    return item?.locked ? '解锁' : '锁定'
  }

  private selectedIsLocked(): boolean {
    const item = this.selectedItem()
    return item?.locked === true
  }

  // ============= R5：手柄配置 =============

  // 手柄逻辑按钮的展示顺序 + 中文名




  /** 某手柄按钮当前动作的展示文案。 */


  /** 改键 sheet 的"当前键"入参（仅 kind==='key' 时给当前 code，否则空）。 */


  /**
   * 将选择器结果写回该手柄按钮：0明确保存为none，其余真实键保存为key，沿原撤销和配置副本更新。
   * 提示复用当前映射的展示函数，与映射行一致显示“无”，不能把解绑值当成GLFW键码暴露给用户。
   */


  /** 循环该手柄按钮的"特殊动作"：键位(进改键) → 上一格 → 下一格 → 无 → 键位。 */








  // 样式 Tab：统一样式编辑器。单选=编辑选中按钮；多选=批量编辑全部选中（一改全改）。
  // 样式字段（大小/透明度/圆角/形状/标签）统一走 styleTargets()，为以后拓展样式铺路。
  @Builder
  StyleTabContent() {
    Column({ space: 12 }) {
      if (this.styleTargets().length === 0) {
        Column({ space: 10 }) {
          Text('先选择一个按键').fontSize(16).fontWeight(FontWeight.Medium).fontColor(EditorTheme.text)
          Text('点选画面中的控件，或开启多选后批量调整外观。').fontSize(14).fontColor(EditorTheme.muted)
            .width('100%').textAlign(TextAlign.Center)
          Button('返回布局选择').fontSize(14).fontColor(EditorTheme.accent).height(44)
            .backgroundColor(EditorTheme.surfaceActive).borderRadius(EditorTheme.radiusSmall)
            .onClick((): void => { this.openTab('edit') })
        }.width('100%').padding({ top: 20, bottom: 20 }).backgroundColor(EditorTheme.surface)
          .borderRadius(EditorTheme.radiusSmall)
      } else {
        Text(this.multiSelectMode
          ? ('批量样式 · 作用于 ' + this.styleTargets().length.toString() + ' 个选中按钮')
          : '按钮外观')
          .fontSize(14).fontColor(EditorTheme.accent).width('100%')

        // 常态与按下态并排示意；尺寸、圆角和透明度来自同一主项，不把预览颜色写入业务草稿。
        Row({ space: 24 }) {
          Column({ space: 6 }) {
            Text(this.previewLabel())
              .width(this.previewSize()).height(this.previewSize()).textAlign(TextAlign.Center)
              .fontSize(14).fontColor(EditorTheme.text).backgroundColor(EditorTheme.surfaceActive)
              .border({ width: 1, color: EditorTheme.accent }).borderRadius(this.previewCorner())
              .opacity(this.curOpacityPct() / 100)
            Text('常态').fontSize(12).fontColor(EditorTheme.muted)
          }.layoutWeight(1).constraintSize({ minHeight: 108 }).justifyContent(FlexAlign.Center)
          Column({ space: 6 }) {
            Text(this.previewLabel())
              .width(this.previewSize()).height(this.previewSize()).textAlign(TextAlign.Center)
              .fontSize(14).fontColor(EditorTheme.panel).backgroundColor(EditorTheme.accent)
              .borderRadius(this.previewCorner()).opacity(this.curOpacityPct() / 100)
            Text('按下').fontSize(12).fontColor(EditorTheme.muted)
          }.layoutWeight(1).constraintSize({ minHeight: 108 }).justifyContent(FlexAlign.Center)
        }.width('100%').padding(10).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)

        // 原三根滑条保留值、范围、步长和真实 SliderChangeMode；只把数值移到标题右侧。
        Column({ space: 2 }) {
          Row() {
            Text('大小').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text(this.curSizePct().toString() + '%').fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: this.curSizePct(), min: 50, max: 200, step: 5 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => { this.applySize(val, mode) })
        }.width('100%')

        Column({ space: 2 }) {
          Row() {
            Text('透明度').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text(this.curOpacityPct().toString() + '%').fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: this.curOpacityPct(), min: 20, max: 100, step: 5 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => { this.applyOpacity(val, mode) })
        }.width('100%')

        Column({ space: 2 }) {
          Row() {
            Text('圆角').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text(this.curCornerPct().toString() + '%').fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: this.curCornerPct(), min: 0, max: 100, step: 5 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => { this.applyCorner(val, mode) })
        }.width('100%')

        // 三种预设继续调用原圆角写入入口；直接在无参 Builder 读取状态，撤销后高亮同步。
        Row({ space: 4 }) {
          Button('方形').fontSize(14).height(44).layoutWeight(1)
            .fontColor(this.cornerPreset() === 'square' ? EditorTheme.accent : EditorTheme.muted)
            .backgroundColor(this.cornerPreset() === 'square' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .borderRadius(EditorTheme.radiusSmall)
            .onClick(() => { this.applyCorner(0) })
          Button('圆角').fontSize(14).height(44).layoutWeight(1)
            .fontColor(this.cornerPreset() === 'round' ? EditorTheme.accent : EditorTheme.muted)
            .backgroundColor(this.cornerPreset() === 'round' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .borderRadius(EditorTheme.radiusSmall)
            .onClick(() => { this.applyCorner(30) })
          Button('圆形').fontSize(14).height(44).layoutWeight(1)
            .fontColor(this.cornerPreset() === 'circle' ? EditorTheme.accent : EditorTheme.muted)
            .backgroundColor(this.cornerPreset() === 'circle' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .borderRadius(EditorTheme.radiusSmall)
            .onClick(() => { this.applyCorner(100) })
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)

        // 标签编辑（单选专属：标签是单个按钮的属性，不做批量）
        if (!this.multiSelectMode && this.selectedItem() !== null) {
          Text('按键标签').fontSize(14).fontColor(EditorTheme.muted).width('100%')
          Row({ space: 6 }) {
            TextInput({ text: this.labelDraft, placeholder: '按钮文字（留空=键名）' })
              .height(44).fontSize(14).layoutWeight(1).fontColor(EditorTheme.text).placeholderColor(EditorTheme.muted)
              .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
              .onChange((v: string) => { this.labelDraft = v })
            Button('应用').fontSize(14).height(44).fontColor(EditorTheme.panel)
              .backgroundColor(EditorTheme.accent).borderRadius(EditorTheme.radiusSmall)
              .onClick(() => { this.applyLabel() })
          }.width('100%')
          Text('留空时使用绑定键名。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }

        Button('统一所有普通按钮大小').fontSize(14).height(44).width('100%').fontColor(EditorTheme.text)
          .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
          .border({ width: 1, color: EditorTheme.stroke }).onClick(() => { this.unifyAllSizes() })
      }
    }
    .width('100%')
  }

  /** 外观面板：当前圆角所属的预设（用于快捷按钮高亮）。 */
  private cornerPreset(): string {
    const c = this.curCornerPct()
    if (c <= 5) return 'square'
    if (c >= 95) return 'circle'
    return 'round'
  }

  /** 外观面板预览方块边长（px，固定预览容器内，按大小% 缩放但夹在合理范围）。 */
  private previewSize(): number {
    const pct = this.curSizePct()
    let s = 64 * pct / 100
    if (s < 24) s = 24
    if (s > 84) s = 84
    return s
  }
  /** 外观面板预览方块圆角（px）。 */
  private previewCorner(): number {
    return this.curCornerPct() / 100 * this.previewSize() / 2
  }
  /** 外观面板预览方块内文字：选中按钮的有效标签（含鼠标左/右、字母键自动名）。 */
  private previewLabel(): string {
    const item = this.stylePrimary()
    if (!item) return ''
    return effectiveLabel(item)
  }

  // 手柄 Tab 内容（原 GamepadPanel，去掉标题栏/容器/关闭按钮）。


  /**
   * 把既有 16 个逻辑按钮分到三个显示组，顺序沿用原目录；该函数不新增或删除任何手柄映射。
   * 数组只在手柄映射页构建时生成，正常游戏与其它设置分区不会执行。
   */


  /** 显式区分“无动作”与特殊循环回到的“键位待选择”，只修饰显示，不改原循环和撤销行为。 */


  // 全局 Tab 内容（原 SettingsPanel，去掉标题栏/容器/跳手柄按钮/关闭按钮）。
  /** 返回当前编辑的完整组；独立参数不覆盖legacy备份，缺席扩展继续原四标量。 */
  private editorLookParameters(): LookParameters {
    if (this.lookPolicies !== undefined) return sourceLookParameters(this.lookPolicies, this.selectedLookSource)
    return { sensitivity: this.lookSensitivity, invertY: this.invertY,
      smoothing: this.lookSmoothing, acceleration: this.lookAccel }
  }

  /** 来源切换只更新滑条观察值，不改变输入政策或建立保存事务。 */
  private syncLookSliders(): void {
    const value: LookParameters = this.editorLookParameters()
    this.sensVal = Math.round(value.sensitivity * 100)
    this.smoothVal = Math.round(value.smoothing * 100)
    this.accelVal = Math.round(value.acceleration * 100)
  }

  /** 选择另一来源结束原滑条一次拖动的撤销边界，不能用同字段名合并两来源的编辑。 */


  /** 用户显式切换政策模式，原值完整复制到四来源；恢复兼容时保留独立参数以便再次选择。 */


  /** 同一来源四参数在草稿内整体替换；保存和真实域激活仍由Store及会话Runtime负责。 */


  /** 来源持久名与产品文字明确区分；外部兼容没有可据此推定的硬件身份。 */




  // 方案 Tab 内容（原 ProfileListPanel，去掉标题栏/容器/关闭按钮）。







  // ============= 多选批量操作 Tab + 横幅 + 统一面板框架（2026-07-16） =============

  /** 多选态常驻横幅（工具面板顶部）：已选数量 + 进入批量 + 退出多选。 */
  @Builder
  MultiSelectBanner() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Copy, iconSize: 16, color: EditorTheme.accent })
        Text('多选中 · 已选 ' + this.selectedIds.length.toString() + ' 个')
          .fontSize(14).fontColor(EditorTheme.accent).fontWeight(FontWeight.Medium).layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Button('批量操作').fontSize(14).fontColor(EditorTheme.accent).height(44).layoutWeight(1)
          .backgroundColor(EditorTheme.surfaceActive).borderRadius(EditorTheme.radiusSmall)
          .onClick(() => { this.openTab('multi') })
        Button('退出多选').fontSize(14).fontColor(EditorTheme.text).height(44).layoutWeight(1)
          .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
          .onClick(() => { this.setMultiSelect(false) })
      }.width('100%')
    }.width('100%').padding(12).backgroundColor(EditorTheme.surface)
      .borderRadius(EditorTheme.radiusSmall).border({ width: 1, color: EditorTheme.stroke })
  }

  // 多选 Tab 内容：开关 + 批量对齐/等间距/样式/锁定/复制/删除。
  @Builder
  MultiTabContent() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('多选模式').fontSize(14).fontColor(EditorTheme.text).width('100%')
          Text('点选累积选择，拖动成组移动。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.multiSelectMode })
          .selectedColor(EditorTheme.accent).switchPointColor(EditorTheme.panel)
          .onChange((b: boolean) => { this.setMultiSelect(b) })
      }.width('100%').constraintSize({ minHeight: 52 })

      if (this.multiSelectMode) {
        Text('已选择 ' + this.selectedIds.length.toString() + ' 个控件').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(EditorTheme.accent).width('100%')
        Row({ space: 8 }) {
          Button('全选').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall).onClick(() => { this.selectAllControls() })
          Button('清空').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall).onClick(() => { this.clearSelection() })
        }.width('100%')

        // 0/1 选择有明确说明；对齐和等距仍由原算法处理，基准固定为选中项平均中心。
        if (this.selectedIds.length === 0) {
          Text('尚未选择控件。点选画面中的按键，或使用“全选”。').fontSize(14).fontColor(EditorTheme.muted)
            .width('100%').padding(12).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        } else if (this.selectedIds.length === 1) {
          Text('再选择至少 1 个控件即可对齐或等间距排列；单个控件仍可改样式、复制或锁定。')
            .fontSize(14).fontColor(EditorTheme.muted).width('100%').padding(12)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        }
        this.SectionLabel('对齐')
        Text('基准：选中控件的平均中心。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Row({ space: 6 }) {
          Button('自动对齐').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('auto') })
          Button('水平对齐').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('h') })
          Button('垂直对齐').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('v') })
        }.width('100%')
        Button('等间距排列 · 间距 ' + this.snapGap.toString() + ' vp').fontSize(14).height(44).fontColor(EditorTheme.text)
          .backgroundColor(EditorTheme.panel).borderRadius(EditorTheme.radiusSmall).width('100%')
          .border({ width: 1, color: EditorTheme.stroke }).enabled(this.selectedIds.length >= 2)
          .onClick(() => { this.batchEqualSpacing() })

        this.SectionLabel('批量')
        Row({ space: 8 }) {
          Button('改样式').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.openTab('style') })
          Button('复制').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchDuplicate() })
        }.width('100%')
        Row({ space: 6 }) {
          Button('锁定').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchSetLocked(true) })
          Button('解锁').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchSetLocked(false) })
          Button('删除').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.danger)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchDelete() })
        }.width('100%')
        Text('成组拖动跳过锁定项；复制与删除跳过系统按钮。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Button('完成多选').fontSize(14).height(44).fontColor(EditorTheme.panel).width('100%')
          .backgroundColor(EditorTheme.accent).borderRadius(EditorTheme.radiusSmall)
          .onClick((): void => { this.setMultiSelect(false); this.openTab('edit') })
      } else {
        Text('开启后可批量对齐、调整外观、复制、锁定和删除控件。').fontSize(14).fontColor(EditorTheme.muted)
          .width('100%').padding(12).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
      }
    }
    .width('100%')
  }

  /** 一级按任务分组；属性、多选和手柄保留原有事务实现，但不再与方案管理挤在一行。 */


  @Builder
  UnifiedTabBar() {
    Row({space:4}) {
      this.TabChip('edit','按键'); this.TabChip('groups','组'); this.TabChip('multi','多选'); this.TabChip('alignment','对齐')
    }.height(44).width('100%')
  }

  /** 吸附属于编辑手势设置，与游戏视角无关。 */
  @Builder
  AlignmentOptions() {
    Column({space:12}) {
        Row() { Column({ space: 3 }) { Text('自动对齐').fontSize(14).fontColor(EditorTheme.text)
          Text('拖动时吸附并显示参考线').fontSize(12).fontColor(EditorTheme.muted) }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.snapEnabled }).selectedColor(EditorTheme.accent)
            .onChange((value: boolean): void => { this.pushUndo(); this.snapEnabled = value })
        }.height(52).width('100%')
        Row() { Text('对齐间距').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.snapGap.toString() + ' vp').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.snapGap, min: 0, max: 100, step: 1 }).width('100%').height(40).enabled(this.snapEnabled)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('snapGap', mode, this.snapGap !== Math.round(value))) return
            this.snapGap = Math.round(value)
          })
        Row() { Text('吸附强度').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.snapStrength.toString() + ' vp').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.snapStrength, min: 2, max: 20, step: 1 }).width('100%').height(40).enabled(this.snapEnabled)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('snapStrength', mode, this.snapStrength !== Math.round(value))) return
            this.snapStrength = Math.round(value)
          })
        Text('对齐参考屏幕边、同组与其它按钮中心。关闭自动对齐后参数保留并禁用。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
    }.width('100%')
  }

  @Builder
  TabChip(tab: string, label: string) {
    Text(label).fontSize(14).fontColor(this.activeSheet === tab ? EditorTheme.accent : EditorTheme.muted)
      .fontWeight(this.activeSheet === tab ? FontWeight.Medium : FontWeight.Normal)
      .layoutWeight(1).height(44).textAlign(TextAlign.Center).borderRadius(12)
      .backgroundColor(this.activeSheet === tab ? EditorTheme.surfaceActive : Color.Transparent)
      .onClick((): void => { this.openTab(tab) })
  }


  /** 普通按钮才消费四触发、拖动瞄准及连滑，显示层共用此判断以免各分区漂移。 */
  private selectedIsOrdinaryButton_(): boolean {
    const item: ControlItem | null = this.selectedItem()
    return item !== null && item.type === ControlType.BUTTON && item.systemAction === undefined
  }

  /** 输入系统按钮在游戏内仍经dispatchButton发送真实聊天keys，必须保留原组合改键契约。 */
  private selectedSupportsKeyBinding_(): boolean {
    const item: ControlItem | null = this.selectedItem()
    return this.selectedIsOrdinaryButton_() ||
      (item !== null && item.type === ControlType.BUTTON && item.systemAction === 'input')
  }

  /** 按实际消费路径解释专用控件；不把占位keyOrMouse或无效trigger包装成可修改行为。 */
  private selectedControlDescription_(): string {
    const item: ControlItem | null = this.selectedItem()
    if (item === null) return ''
    if (item.systemAction === 'input') return '游戏内先发送聊天绑定再打开输入框；菜单中只打开文本输入。'
    if (item.systemAction === 'edit') return '点击进入按键布局编辑；不发送键盘按键，触发方式由系统管理。'
    if (item.systemAction === 'visibility') return '点击切换按键显隐档位；不发送键盘按键，触发方式由系统管理。'
    if (item.type === ControlType.JOYSTICK) return '摇杆按移动方向控制角色；中心与疾跑可在独立触控设置中调整。'
    if (item.type === ControlType.HOTBAR_SELECTOR) return '快捷栏直点条按点击位置选择格位，横向滑动可扫选；不使用单个键位或四触发模式。'
    if (item.type === ControlType.SCROLL_WHEEL) return '滚轮控件通过上下滑动发送滚动，不使用键位或四触发模式。'
    if (item.type === ControlType.DRAWER) return '抽屉入口用于展开或收起子按钮；子按钮保留各自的键位与触发设置。'
    return ''
  }

  /** 键名来自现有GLFW目录；空序列明确展示解绑，不能伪装成一个默认键。 */
  private selectedBindingLabel_(): string {
    const item: ControlItem | null = this.selectedItem()
    if (item === null) return '未选择'
    if (item.phaseBindings !== undefined) {
      const labels: string[]=item.phaseBindings.filter((binding: ControlPhaseBinding): boolean => binding.keys.length>0)
        .map((binding: ControlPhaseBinding): string => this.phaseName_(binding.phase)+'：'+binding.keys.map((key: number): string => glfwKeyName(key)).join(' + ')+(binding.autoKeep ? '（切换保持）' : ''))
      if (labels.length>0) return labels.join('；')
    }
    if ((item.groupActions?.length ?? 0)>0 && (item.phaseBindings !== undefined || effectiveKeys(item).length===0)) return '触控组动作'
    const keys: number[] = effectiveKeys(item)
    return keys.length === 0 ? '未绑定' : keys.map((key: number): string => glfwKeyName(key)).join(' + ')
  }

  private selectedTrigger_(): string { return this.selectedItem()?.trigger ?? 'press' }
  private triggerName_(mode: string): string {
    if (mode === 'toggle') return '切换'
    if (mode === 'doubleTap') return '双击'
    if (mode === 'longPress') return '长按'
    return '按住'
  }

  /** 分段选择一次只记录一个撤销点；与旧循环按钮保持相同的连滑清理规则。 */
  private chooseTrigger_(mode: TriggerMode): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || this.selectedIsSystemMouse() || (item.trigger ?? 'press') === mode) return
    if (item.phaseBindings !== undefined) { this.statusMsg='此按钮使用分阶段绑定，请在组动作面板调整'; return }
    this.pushUndo(); item.trigger = mode
    if (mode !== 'press') item.swipeGroup = undefined
    this.refreshControls()
  }

  /** 编辑数字只在提交时读取，所有持久化仍使用原xPct/yPct和base尺寸字段。 */
  private syncPositionDraft_(): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null) return
    this.positionXDraft = Math.round(this.itemPxX(item)).toString()
    this.positionYDraft = Math.round(this.itemPxY(item)).toString()
    this.positionWidthDraft = Math.round(this.itemW(item)).toString()
    this.positionHeightDraft = Math.round(this.itemH(item)).toString()
  }

  private applyPositionDraft_(): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null) return
    if (item.locked) { this.statusMsg = '控件已锁定，请先解锁'; return }
    const x: number = Number(this.positionXDraft), y: number = Number(this.positionYDraft)
    const w: number = Number(this.positionWidthDraft), h: number = Number(this.positionHeightDraft)
    if (this.positionXDraft.trim().length === 0 || this.positionYDraft.trim().length === 0 || this.positionWidthDraft.trim().length === 0 || this.positionHeightDraft.trim().length === 0 || !Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h) || w < 16 || h < 16) {
      this.statusMsg = '请输入有效的位置和尺寸，宽高不能小于16'; return
    }
    this.pushUndo()
    const scale: number = Math.max(0.01, this.globalScale * item.itemScale)
    item.baseWidth = Math.min(this.screenWidth, w) / scale
    item.baseHeight = Math.min(this.screenHeight, h) / scale
    item.xPct = Math.max(0, Math.min(this.screenWidth - this.itemW(item), x)) / Math.max(1, this.screenWidth)
    item.yPct = Math.max(0, Math.min(this.screenHeight - this.itemH(item), y)) / Math.max(1, this.screenHeight)
    if (item.type === ControlType.HOTBAR_SELECTOR) item.hotbarUserPlaced = true
    this.refreshControls(); this.syncPositionDraft_()
    // 成功应用的是当前草稿，明确覆盖上次校验错误，不暗示已经保存到Store。
    this.statusMsg = '位置与尺寸已应用'
  }

  /** 快速定位是当前视口的一次性编辑，不新增运行时锚点解释或每帧位置计算。 */
  private alignSelectedToScreen_(anchor: string): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || item.locked) { this.statusMsg = '请先选择并解锁控件'; return }
    this.pushUndo()
    const column: number = Number(anchor.substring(0, 1)), row: number = Number(anchor.substring(1, 2))
    item.xPct = Math.max(0, this.screenWidth - this.itemW(item)) * column / 2 / Math.max(1, this.screenWidth)
    item.yPct = Math.max(0, this.screenHeight - this.itemH(item)) * row / 2 / Math.max(1, this.screenHeight)
    if (item.type === ControlType.HOTBAR_SELECTOR) item.hotbarUserPlaced = true
    this.refreshControls(); this.syncPositionDraft_()
    this.statusMsg = '已按当前屏幕完成定位'
  }

  private anchorName_(anchor: string): string {
    const names: string[] = ['左上', '上中', '右上', '左中', '居中', '右中', '左下', '下中', '右下']
    return names[Number(anchor.substring(1, 2)) * 3 + Number(anchor.substring(0, 1))] ?? '居中'
  }

  /** 取消确认不提前修改Store；最终仍调用既有完整目录事务回滚入口。 */
  private requestCancel_(): void {
    if (this.persistenceBusy) return
    if (!this.editorReady) { this.cancelEditor_(); return }
    // 只在明确点击取消时构造现有内容签名；撤销回到原内容时可以直接退出，目录操作仍需确认。
    if (!this.sessionCatalogChanged && this.contentSignature() === this.baselineSig) {
      this.cancelEditor_(); return
    }
    this.showLeaveConfirm = true
  }





  @Builder
  BehaviorTabContent() {
    Column({ space: 12 }) {
      if (this.selectedItem() === null) {
        Text('请先选择按键').fontSize(14).fontColor(EditorTheme.muted)
      } else if (this.selectedIsSystemMouse()) {
        Text('系统鼠标入口可调整外观和位置；行为由系统管理。')
          .fontSize(14).fontColor(EditorTheme.muted).width('100%')
      } else {
        this.SectionLabel('显示场景')
        Row({ space: 6 }) {
          ForEach(['game', 'menu', 'always'], (scene: string): void => {
            Button(this.sceneLabelText(scene as ControlScene)).height(44).fontSize(14).layoutWeight(1).borderRadius(12)
              .backgroundColor(this.selectedScene_() === scene ? EditorTheme.surfaceActive : EditorTheme.surface)
              .fontColor(this.selectedScene_() === scene ? EditorTheme.accent : EditorTheme.muted)
              .onClick((): void => { this.chooseScene_(scene as ControlScene) })
          }, (scene: string): string => scene)
        }.width('100%')
        this.SectionLabel('显示策略')
        Row({ space: 6 }) {
          ForEach(['auto', 'force_show', 'force_hide'], (value: string): void => {
            Button(this.visibilityLabelText(value as VisibilityOverride)).height(44).fontSize(14).layoutWeight(1).borderRadius(12)
              .backgroundColor(this.selectedVisibility_() === value ? EditorTheme.surfaceActive : EditorTheme.surface)
              .fontColor(this.selectedVisibility_() === value ? EditorTheme.accent : EditorTheme.muted)
              .onClick((): void => { this.chooseVisibility_(value as VisibilityOverride) })
          }, (value: string): string => value)
        }.width('100%')
        Text('自动遵循场景；强显越过场景过滤。解绑、隐藏及控件自身能力仍优先。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        if (this.selectedIsOrdinaryButton_()) {
          Row() {
            Column({ space: 3 }) { Text('拖动瞄准').fontSize(14).fontColor(EditorTheme.text)
              Text('按住按键时拖动视角').fontSize(12).fontColor(EditorTheme.muted) }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.selectedItem()?.dragLook === true })
              .selectedColor(EditorTheme.accent).onChange((value: boolean): void => {
                if ((this.selectedItem()?.dragLook === true) !== value) this.toggleDragLook()
              })
          }.height(52).width('100%')
          this.SectionLabel('连滑分组')
          Row({ space: 6 }) {
            ForEach(['', '1', '2', '3'], (group: string): void => {
              Button(group.length === 0 ? '关闭' : '组 ' + group).height(44).fontSize(14).layoutWeight(1).borderRadius(12)
                .backgroundColor((this.selectedItem()?.swipeGroup ?? '') === group ? EditorTheme.surfaceActive : EditorTheme.surface)
                .fontColor((this.selectedItem()?.swipeGroup ?? '') === group ? EditorTheme.accent : EditorTheme.muted)
                .onClick((): void => { this.chooseSwipeGroup_(group) })
            }, (group: string): string => group)
          }.width('100%')
          Text('连滑仅支持普通按住按钮，并与拖动瞄准互斥。滑出释放，滑入同组按下。')
            .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }
      }
    }.width('100%')
  }

  @Builder
  PositionTabContent() {
    Column({ space: 12 }) {
      if (this.selectedItem() === null) {
        Text('请先选择控件').fontSize(14).fontColor(EditorTheme.muted)
      } else {
        this.SectionLabel('位置与尺寸')
        // 字段身份必须常驻可见：已有数值会替代placeholder，不能把坐标与尺寸只写在占位文字中。
        // 仅给原输入框增加标签与vp单位；两列排布、草稿onChange及统一“应用”事务保持原入口。
        Row({ space: 8 }) {
          Column({ space: 6 }) {
            Text('横向 X · vp').fontSize(12).fontColor(EditorTheme.muted)
            TextInput({ text: this.positionXDraft, placeholder: 'X' }).height(44).fontSize(14).width('100%')
              .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).onChange((v: string): void => { this.positionXDraft = v })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Column({ space: 6 }) {
            Text('纵向 Y · vp').fontSize(12).fontColor(EditorTheme.muted)
            TextInput({ text: this.positionYDraft, placeholder: 'Y' }).height(44).fontSize(14).width('100%')
              .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).onChange((v: string): void => { this.positionYDraft = v })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        Row({ space: 8 }) {
          Column({ space: 6 }) {
            Text('宽度 · vp').fontSize(12).fontColor(EditorTheme.muted)
            TextInput({ text: this.positionWidthDraft, placeholder: '宽' }).height(44).fontSize(14).width('100%')
              .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).onChange((v: string): void => { this.positionWidthDraft = v })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Column({ space: 6 }) {
            Text('高度 · vp').fontSize(12).fontColor(EditorTheme.muted)
            TextInput({ text: this.positionHeightDraft, placeholder: '高' }).height(44).fontSize(14).width('100%')
              .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).onChange((v: string): void => { this.positionHeightDraft = v })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        Button('应用位置与尺寸').height(44).fontSize(14).width('100%').backgroundColor(EditorTheme.surfaceActive)
          .fontColor(EditorTheme.accent).borderRadius(12).onClick((): void => { this.applyPositionDraft_() })
        this.SectionLabel('快速定位到当前屏幕')
        ForEach(['0', '1', '2'], (row: string): void => {
          Row({ space: 8 }) {
            ForEach(['0', '1', '2'], (column: string): void => {
              Button(this.anchorName_(column + row)).height(44).fontSize(14).layoutWeight(1)
                .backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text).borderRadius(12)
                .onClick((): void => { this.alignSelectedToScreen_(column + row) })
            }, (column: string): string => column)
          }.width('100%')
        }, (row: string): string => row)
        EditorChip({ icon: this.selectedIsLocked() ? AppIconName.Unlock : AppIconName.Lock,
          label: this.lockedLabel(), bg: EditorTheme.surface, onTap: () => { this.toggleLocked() } })
      }
    }.width('100%')
  }



  /** 仅约束确认卡的滚动视口，保留上下各12vp；不估算文字行数或固定卡片高度。 */
  private leaveConfirmMaxH_(): number { return Math.max(1, this.screenHeight - 24) }

  @Builder
  LeaveConfirm() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('#B0071110')
      // 无固定height/layoutWeight时Scroll按内容自然测量，仅在短窗口截取为可滚动视口。
      // 标题、说明和三项操作在同一滚动内容中；大字体也能滚到按钮，不按固定文字行高猜尺寸。
      Scroll() {
        Column({ space: 16 }) {
          Text('保存这次按键调整？').fontSize(18).fontWeight(FontWeight.Medium).fontColor(EditorTheme.text)
          Text('放弃后保留进入前的布局，本次草稿不会写入方案。')
            .fontSize(14).fontColor(EditorTheme.muted).width('100%')
          Button('保存并退出').height(48).width('100%').fontSize(14).backgroundColor(EditorTheme.accent).fontColor(EditorTheme.panel)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false; this.saveEditor_() })
          Button('继续编辑').height(48).width('100%').fontSize(14).backgroundColor(EditorTheme.surface).fontColor(EditorTheme.text)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false })
          Button('放弃修改').height(48).width('100%').fontSize(14).backgroundColor(Color.Transparent).fontColor(EditorTheme.danger)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false; this.cancelEditor_() })
        }.padding(24).width('100%')
      }.width(Math.min(420, this.screenWidth - 24)).constraintSize({ maxHeight: this.leaveConfirmMaxH_() })
        .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarColor(EditorTheme.stroke)
        .backgroundColor(EditorTheme.panel).borderRadius(20).border({ width: 1, color: EditorTheme.stroke })
    }.width('100%').height('100%')
  }


  /** 只查询目录变更时缓存的预设名单，列表渲染不触发载荷懒加载或磁盘访问。 */



  /** 场景与显示策略是两层独立字段，分段选择只改变本层并压入一个撤销点。 */
  private selectedScene_(): string {
    const item: ControlItem | null = this.selectedItem()
    return item === null ? 'always' : controlScene(item)
  }
  private selectedVisibility_(): string { return this.selectedItem()?.visibilityOverride ?? 'auto' }
  private chooseScene_(scene: ControlScene): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || this.selectedIsSystemMouse() || controlScene(item) === scene) return
    this.pushUndo(); setControlScene(item, scene); this.refreshControls()
  }
  private chooseVisibility_(value: VisibilityOverride): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || this.selectedIsSystemMouse() || (item.visibilityOverride ?? 'auto') === value) return
    this.pushUndo(); item.visibilityOverride = value === 'auto' ? undefined : value; this.refreshControls()
  }
  /** 连滑只向原模型写入明确分组；不自动推断相邻按钮，也不改变其它输入来源。 */
  private chooseSwipeGroup_(group: string): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || item.type !== ControlType.BUTTON || item.systemAction !== undefined) return
    if (!['', '1', '2', '3'].includes(group)) return
    if ((item.trigger ?? 'press') !== 'press' || item.dragLook === true) {
      this.statusMsg = '连滑需要按住触发，并关闭拖动瞄准'; return
    }
    if ((item.swipeGroup ?? '') === group) return
    this.pushUndo(); item.swipeGroup = group.length > 0 ? group : undefined; this.refreshControls()
  }


}

/**
 * LayoutEditor.ets — 虚拟按键布局编辑器
 *
 * 阶段 2.1/2.2/2.3/2.4/2.6 input-system-refactor 升级：
 *   - 增加灵敏度 / Y 倒置 / 死区滑条与开关
 *   - 改键 sheet（KeyPickerSheet）
 *   - trigger 模式下拉
 *   - label 编辑
 *   - hidden / locked 切换
 *   - 撤销栈（≤ 20 步）
 *   - AlignGroup 自动吸附（屏幕边 + 组内对齐线 + 其他按钮中线）
 */
import {
  ControlItem, ControlType, LayoutProfile, AlignGroup,
  TriggerMode, VisibilityOverride, effectiveKeys,
  cloneItem as cloneControlItem, cloneItemWithFreshIds, generateControlId, validateAndNormalizeLayout,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_JOYSTICK_DEAD_ZONE,
  DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  LAYOUT_PROFILE_VERSION,
  GamepadConfig, GamepadAction, StickRole,
  defaultGamepadConfig, defaultGamepadButtonMap,
  DEFAULT_GAMEPAD_DEAD_ZONE, DEFAULT_TRIGGER_THRESHOLD,
  DEFAULT_BUTTON_SIZE, DEFAULT_BUTTON_OPACITY, DEFAULT_CORNER_RADIUS,
  DEFAULT_GLOBAL_OPACITY,
  effectiveCornerRadius, effectiveOpacity, effectiveLabel, ControlStyle,
  ControlScene, controlScene, setControlScene
} from 'gamecontrol';
import { glfwKeyName, GLFW_KEY_G } from 'gamecontrol';
import { makeHotbarSelector, computeAutoGuiScale, computeHotbarRectPx } from 'gamecontrol';
import { DEFAULT_SNAP_GAP, DEFAULT_SNAP_STRENGTH } from 'gamecontrol';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { KeyPickerSheet } from './KeyPickerSheet';
import { getLayoutStore } from 'gamecontrol';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

// 撤销栈最大深度
const UNDO_STACK_MAX: number = 20

// 已锁定的吸附阈值 → 脱离阈值倍数：脱离阈值 = SNAP_IN × 此值，形成黏滞防抖（横对齐后左右滑动
// 时的垂直小抖动 < 脱离阈值就不会掉出对齐高度）。
const SNAP_OUT_RATIO: number = 2.4

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

interface UndoSnapshot {
  controls: ControlItem[]
  hotbarAutoAdded: boolean
  globalScale: number
  lookSensitivity: number
  invertY: boolean
  lookSmoothing: number
  lookAccel: number
  joystickDeadZone: number
  haptic: boolean
  globalOpacity: number
  targetDevice: string
  snapEnabled: boolean
  snapGap: number
  snapStrength: number
  gamepad: GamepadConfig
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
      AppIcon({ name: this.icon, iconSize: 14, color: '#FFFFFF' })
      Text(this.label).fontSize(11).fontColor('#FFFFFF').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(34)
    .padding({ left: 11, right: 11 })
    .backgroundColor(this.bg)
    .borderRadius(17)
    .justifyContent(FlexAlign.Center)
    .margin(3)
    .onClick(() => { this.onTap() })
  }
}

@Component
export struct LayoutEditor {
  onDone: (profile: LayoutProfile | null) => void = () => {}
  /** 进入失败与保存/取消成功分开通知；游戏宿主据此撤销 native 触控暂停。 */
  onInitializationFailed: (message: string) => void = () => {}
  @Prop screenWidth: number = 720
  @Prop screenHeight: number = 360

  // ---- 核心数据 ----
  @State controls: ControlItem[] = []
  @State globalScale: number = 1.0
  @State profileName: string = '默认'
  @State lookSensitivity: number = DEFAULT_LOOK_SENSITIVITY
  @State invertY: boolean = DEFAULT_INVERT_Y
  // 方案 C（2026-07-11）：视角平滑 α + 加速强度
  @State lookSmoothing: number = DEFAULT_LOOK_SMOOTHING
  @State lookAccel: number = DEFAULT_LOOK_ACCEL
  @State joystickDeadZone: number = DEFAULT_JOYSTICK_DEAD_ZONE
  @State haptic: boolean = true
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
  @State gamepadBtnPicker: string = ''     // R5：正在改键的手柄按钮逻辑名（''=未在改键）
  @State showKeyPicker: boolean = false    // 改键 sheet 显隐
  @State labelDraft: string = ''
  @State profileNames: string[] = []
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
  private undoStack: UndoSnapshot[] = []
  private sliderUndoKey: string = ''

  /** 持久化期间串行操作并冻结手势，避免保存的快照落后于用户仍在修改的草稿。 */
  @State private persistenceBusy: boolean = false
  private editorMounted: boolean = false
  private editorReady: boolean = false
  private editorClosed: boolean = false
  private editorGeneration: number = 0
  private editorLeaseHeld: boolean = false
  private editorTransactionOwned: boolean = false
  private persistenceTask: Promise<void> | undefined = undefined
  private editorCleanupTask: Promise<void> | undefined = undefined
  private restorationTask: Promise<void> | undefined = undefined

  async aboutToAppear(): Promise<void> {
    this.editorMounted = true
    this.editorClosed = false
    this.editorReady = false
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
      this.loadConfirmedProfile_(store.getActiveProfile())
      this.profileNames = store.getProfileNames()
      this.panelX = (this.screenWidth - this.panelWidth()) / 2
      // 竖直居中偏上；保持原有面板布局，不因持久化接线调整交互位置。
      this.panelY = Math.max(12, Math.min(this.panelMaxTop(), Math.floor(this.screenHeight / 2 - 150)))
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
      if (!(await store.saveProfile(result))) throw new Error('布局非法或系统预设无法直接保存')
      // 页面已离开时由销毁收口恢复原事务，不让迟到保存关闭下一次编辑界面。
      if (!this.editorMounted || generation !== this.editorGeneration) return
      store.commitEditorTransaction()
      this.completeEditor_(result)
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
  private resetEditorProfile_(): void {
    this.runPersistence_('重置布局', async (generation: number): Promise<void> => {
      const profile: LayoutProfile = await getLayoutStore().resetProfile(this.profileName)
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.pushUndo()
      this.loadConfirmedProfile_(profile, false)
      this.statusMsg = '已重置'
    })
  }

  /** 方案切换、新建、删除同样等待 Store 持久确认；失败保留当前选中方案和草稿。 */
  private switchEditorProfile_(name: string): void {
    this.runPersistence_('切换方案', async (generation: number): Promise<void> => {
      await getLayoutStore().setActiveProfile(name)
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.loadConfirmedProfile_(getLayoutStore().getActiveProfile())
    })
  }

  private deleteEditorProfile_(name: string): void {
    this.runPersistence_('删除方案', async (generation: number): Promise<void> => {
      const store = getLayoutStore()
      if (!(await store.deleteProfile(name))) throw new Error('系统预设无法删除')
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.profileNames = store.getProfileNames()
      if (this.profileName === name) this.loadConfirmedProfile_(store.getActiveProfile())
      this.statusMsg = '已删除'
    })
  }

  private createEditorProfile_(): void {
    this.runPersistence_('新建方案', async (generation: number): Promise<void> => {
      const store = getLayoutStore()
      const profile: LayoutProfile = await store.createProfile('方案' + (this.profileNames.length + 1).toString())
      if (!this.editorMounted || generation !== this.editorGeneration) return
      this.profileNames = store.getProfileNames()
      this.loadConfirmedProfile_(profile)
    })
  }

  /** 面板宽度：不超过屏幕宽度（左右各留 8vp），下限 220vp，默认 300vp。 */
  private panelWidth(): number {
    let w = 300
    const cap = this.screenWidth - 16
    if (cap < w) w = cap
    if (w < 220) w = 220
    return w
  }

  /** 面板固定"骨架"高度（拖动条 + Tab 栏 + 常驻底栏），Scroll 内容之外的部分。 */
  private panelChromeH(): number { return 16 + 32 + 52 }
  /** Scroll 内容最小高度（保证面板可用，且骨架 + 此值 + 顶边 <= 屏高时底栏一定可见）。 */
  private panelMinContentH(): number { return 90 }
  /** 面板顶部允许的最大 y：再往下拖会导致底栏越出屏幕，故到此为止。 */
  private panelMaxTop(): number {
    const maxTop = this.screenHeight - (this.panelChromeH() + this.panelMinContentH() + 8)
    return maxTop < 0 ? 0 : maxTop
  }
  /** 面板当前（已提交）顶部 y。 */
  private panelTopBase(): number {
    return this.panelY >= 0 ? this.panelY : Math.max(12, Math.floor(this.screenHeight / 2 - 150))
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
    this.globalScale = normalized.globalScale
    this.profileName = normalized.name
    this.lookSensitivity = normalized.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY
    this.invertY = normalized.invertY ?? DEFAULT_INVERT_Y
    this.lookSmoothing = normalized.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING
    this.lookAccel = normalized.lookAccel ?? DEFAULT_LOOK_ACCEL
    this.joystickDeadZone = normalized.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE
    this.haptic = normalized.haptic ?? true
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
    this.deadZoneVal = Math.round(this.joystickDeadZone * 100)
    this.selectedIdx = -1
    this.selectedScaleVal = 100
    this.selectedOpacityVal = 100
    if (clearUndo) {
      this.undoStack = []
      this.undoCount = 0
    }
    this.sliderUndoKey = ''
    this.ver++
  }

  // 编辑基线内容签名（进入编辑器 / 切换方案时记录）。用于"仅在真正改动过布局时才把 targetDevice
  // 归位为当前设备类型"——纯查看后保存不应把手机布局误标成平板。
  private baselineSig: string = ''

  /** 方案内容签名：忽略 targetDevice / deviceModel（这俩不算"布局内容"改动）。buildProfile 失败返回空串。 */
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
      version: LAYOUT_PROFILE_VERSION,
      name: this.profileName,
      globalScale: this.globalScale,
      lookSensitivity: this.lookSensitivity,
      invertY: this.invertY,
      lookSmoothing: this.lookSmoothing,
      lookAccel: this.lookAccel,
      joystickDeadZone: this.joystickDeadZone,
      haptic: this.haptic,
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
    const snapshot: UndoSnapshot = {
      controls: this.controls.map((c: ControlItem) => cloneControlItem(c)),
      hotbarAutoAdded: this.hotbarAutoAdded,
      globalScale: this.globalScale,
      lookSensitivity: this.lookSensitivity,
      invertY: this.invertY,
      lookSmoothing: this.lookSmoothing,
      lookAccel: this.lookAccel,
      joystickDeadZone: this.joystickDeadZone,
      haptic: this.haptic,
      globalOpacity: this.globalOpacity,
      targetDevice: this.targetDevice,
      snapEnabled: this.snapEnabled,
      snapGap: this.snapGap,
      snapStrength: this.snapStrength,
      gamepad: this.cloneGamepad(this.gamepad)
    }
    this.undoStack.push(snapshot)
    if (this.undoStack.length > UNDO_STACK_MAX) {
      this.undoStack.shift()
    }
    this.undoCount = this.undoStack.length
    this.sliderUndoKey = ''
  }

  /** 同一滑条的一次拖动只建立一个 undo 边界。 */
  private beginSliderUndo(key: string): void {
    if (this.sliderUndoKey !== key) {
      this.pushUndo()
      this.sliderUndoKey = key
    }
  }

  private canUndo(): boolean { return this.undoCount > 0 }

  private undo(): void {
    if (this.undoStack.length === 0) return
    const snapshot = this.undoStack.pop()!
    this.controls = snapshot.controls
    this.hotbarAutoAdded = snapshot.hotbarAutoAdded
    this.globalScale = snapshot.globalScale
    this.lookSensitivity = snapshot.lookSensitivity
    this.invertY = snapshot.invertY
    this.lookSmoothing = snapshot.lookSmoothing
    this.lookAccel = snapshot.lookAccel
    this.joystickDeadZone = snapshot.joystickDeadZone
    this.haptic = snapshot.haptic
    this.globalOpacity = snapshot.globalOpacity
    this.targetDevice = snapshot.targetDevice
    this.snapEnabled = snapshot.snapEnabled
    this.snapGap = snapshot.snapGap
    this.snapStrength = snapshot.snapStrength
    this.gamepad = this.cloneGamepad(snapshot.gamepad)
    this.globalScaleVal = Math.round(this.globalScale * 100)
    this.globalOpacityVal = Math.round(this.globalOpacity * 100)
    this.sensVal = Math.round(this.lookSensitivity * 100)
    this.smoothVal = Math.round(this.lookSmoothing * 100)
    this.accelVal = Math.round(this.lookAccel * 100)
    this.deadZoneVal = Math.round(this.joystickDeadZone * 100)
    this.undoCount = this.undoStack.length
    this.ver++
    this.statusMsg = '已撤销'
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
    this.pushUndo()
    item.keys = keys.slice()
    // 同步 keyOrMouse 兼容字段（取首键）
    if (keys.length > 0) item.keyOrMouse = keys[0]
    this.refreshControls()
    this.statusMsg = '键位已改为 ' + keys.map((k: number) => glfwKeyName(k)).join(' + ')
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
    this.refreshControls()
    this.statusMsg = '触发模式 = ' + next
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
    // 系统功能按钮（输入/设置/显示）是核心入口，不可删除，仅可移动/缩放/改外观。
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
    dup.xPct = Math.min(1 - this.itemW(dup) / this.screenWidth, item.xPct + 0.04)
    dup.yPct = Math.min(1 - this.itemH(dup) / this.screenHeight, item.yPct + 0.04)
    this.controls.push(dup)
    this.selectedIdx = this.controls.length - 1
    this.refreshControls()
    this.statusMsg = '已复制'
  }

  /**
   * 添加按键（2026-05-30）：在屏幕中央新建一个标准正方形按钮，默认绑定 G（占位，
   * 用户随即可在弹出的"选择按键"里改成全键盘任意键）。新建后自动选中 + 打开改键 sheet。
   *
   * 用户新增的按键**永不自动隐藏**（hideOnInput: []）——接键鼠后也保留显示，
   * 避免"加了个键，插上键盘就消失找不到"。需要隐时用户可在"显示策略"里手动设强隐。
   */
  private addButton(): void {
    this.pushUndo()
    const id = generateControlId(this.controls)
    const newItem: ControlItem = {
      id,
      label: '',
      type: ControlType.BUTTON,
      keyOrMouse: GLFW_KEY_G,
      keys: [GLFW_KEY_G],
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
    this.statusMsg = '已添加按键，请选择要绑定的键'
    // 立即打开改键面板，让用户选全键盘任意键
    this.showKeyPicker = true
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
    this.autoAlignHotbar(item)
    this.controls.push(item)
    this.hotbarAutoAdded = true
    this.selectedIdx = this.controls.length - 1
    this.syncSelectedAppearanceVals()
    this.refreshControls()
    this.statusMsg = '已添加物品栏直点条（已按屏幕自动对齐，可微调）'
  }

  /**
   * 把物品栏条对齐到 MC 真实 hotbar 的物理矩形（§4.5 配方）：读设备物理分辨率 + 自动档 guiScale
   * 算出 hotbar 的物理 px 矩形，再换算成控件存储（xPct/yPct 相对物理尺寸；baseWidth/Height 为 vp，
   * 渲染 = base × itemScale × globalScale，故除以 globalScale 抵消）。display 不可用时退回底部居中默认。
   */
  private autoAlignHotbar(item: ControlItem): void {
    const g = this.globalScale > 0 ? this.globalScale : 1.0
    // 显式"对齐到 MC hotbar" = 回到系统自动对齐：清除手动定位标记，之后每次 load 会持续保持对齐。
    item.hotbarUserPlaced = false
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
  private applyOpacity(opPct: number): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    this.beginSliderUndo('styleOpacity')
    for (let t of targets) this.ensureStyle(t).opacity = opPct / 100
    this.selectedOpacityVal = Math.round(opPct)
    this.refreshControls()
  }
  private applyCorner(cornerPct: number): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    this.beginSliderUndo('styleCorner')
    for (let t of targets) {
      const st = this.ensureStyle(t)
      st.cornerRadius = cornerPct / 100
      // 同步老 isCircle 字段，保持渲染兼容（圆角=100% 视为圆）
      t.isCircle = cornerPct >= 99
    }
    this.refreshControls()
  }
  /** 统一"大小"应用（用 itemScale，对所有控件类型一致；hotbar 标记为用户已定位）。 */
  private applySize(sizePct: number): void {
    const targets = this.styleTargets()
    if (targets.length === 0) return
    this.beginSliderUndo('styleSize')
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

  build() {
    Stack() {
      // 半透明背景，点击取消选中
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick(() => { this.selectedIdx = -1; this.selectedScaleVal = 100 })

      // 所有按钮（key 含 ver 强制刷新）
      ForEach(this.controls, (item: ControlItem, index: number) => {
        if (!item.hidden) {
          this.EditableBtn(item, index)
        }
      }, (item: ControlItem, index: number) => item.id + '_v' + this.ver.toString())

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
      if (this.statusMsg.length > 0) {
        Text(this.statusMsg)
          .fontSize(11).fontColor('#FFD54F')
          .backgroundColor('#AA000000').padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .position({ x: 10, y: 10 })
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

      // R5：手柄按钮改键 sheet（复用 KeyPickerSheet）
      if (this.gamepadBtnPicker.length > 0) {
        KeyPickerSheet({
          currentKeys: this.gamepadBtnCurrentKeys(),
          onPick: (keys: number[] | null) => {
            const btn = this.gamepadBtnPicker
            this.gamepadBtnPicker = ''
            if (keys && keys.length > 0) this.applyGamepadKey(btn, keys[0])
          }
        })
      }
    }
    .width('100%').height('100%')
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
            this.selectedIdx = index
            this.syncSelectedAppearanceVals()
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
        this.selectedIdx = index
        this.syncSelectedAppearanceVals()
      })
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
      dup.xPct = Math.min(1 - this.itemW(dup) / this.screenWidth, src.xPct + 0.04)
      dup.yPct = Math.min(1 - this.itemH(dup) / this.screenHeight, src.yPct + 0.04)
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
    this.showPanel = true
    // 样式 Tab（单选）打开时同步标签草稿，保证 TextInput 显示当前按钮的标签。
    if (tab === 'style' && !this.multiSelectMode) {
      const it = this.selectedItem()
      this.labelDraft = it ? it.label : ''
    }
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
  // + 文字 + 语义底色，34 高圆角胶囊。取代旧的一排小 Button，信息层级更清晰、触控更友好。
  // UI 重绘：分区小标题（左侧竖条 + 文字），用于「选中 / 全局」信息分区。
  @Builder
  SectionLabel(text: string) {
    Row({ space: 6 }) {
      Column().width(3).height(11).borderRadius(2).backgroundColor('#448AFF')
      Text(text).fontSize(10).fontColor('#CCFFFFFF').fontWeight(FontWeight.Medium).maxLines(1)
    }
    .width('100%').height(16).margin({ top: 2, bottom: 1 })
  }

  // 选中控件的标题文案（用于分区标题）。
  private selectedTitle(): string {
    const item = this.selectedItem()
    if (!item) return ''
    if (item.label && item.label.length > 0) return item.label
    if (item.type === ControlType.JOYSTICK) return '摇杆'
    if (item.type === ControlType.SCROLL_WHEEL) return '滚轮'
    if (item.type === ControlType.HOTBAR_SELECTOR) return '物品栏'
    if (item.type === ControlType.DRAWER) return '抽屉'
    return '按键'
  }

  @Builder
  ToolPanel() {
    Column({ space: 0 }) {
      // 拖动横杠（iOS Home Indicator 风格）：拖动移动面板，点击收起/展开
      Row() {
        Column()
          .width(36).height(4)
          .borderRadius(2)
          .backgroundColor('#55FFFFFF')
      }
      .width('100%').height(16)
      .justifyContent(FlexAlign.Center)
      .gesture(
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart(() => {
            this.panelDragStartX = this.panelX
            this.panelDragStartY = this.panelY
            this.panelDragDx = 0
            this.panelDragDy = 0
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!event) return
            // 实时夹取位移：面板整体（含底栏）始终不越出屏幕。y 到 panelMaxTop 为止，
            // 继续下拉不再移动面板，只让内容区收缩、靠滚动阅读。
            const baseX = this.panelX >= 0 ? this.panelX : (this.screenWidth - this.panelWidth()) / 2
            const baseY = this.panelTopBase()
            const w = this.panelWidth()
            let dx = event.offsetX
            let dy = event.offsetY
            dx = Math.max(-(baseX + w - 80), Math.min(this.screenWidth - 80 - baseX, dx))
            dy = Math.max(-baseY, Math.min(this.panelMaxTop() - baseY, dy))
            this.panelDragDx = dx
            this.panelDragDy = dy
          })
          .onActionEnd(() => { this.commitPanelDrag() })
      )
      .onClick(() => { this.showPanel = !this.showPanel })

      // 展开时：Tab 栏 + 当前 Tab 内容（Scroll 限高）+ 常驻操作底栏。
      // 唯一面板：原"工具面板 + 各设置浮层"全部整合于此，同一时刻只有这一个浮窗。
      if (this.showPanel) {
        this.UnifiedTabBar()
        Scroll() {
          Column({ space: 6 }) {
            if (this.activeSheet === 'edit') { this.EditTabContent() }
            else if (this.activeSheet === 'style') { this.StyleTabContent() }
            else if (this.activeSheet === 'global') { this.GlobalTabContent() }
            else if (this.activeSheet === 'gamepad') { this.GamepadTabContent() }
            else if (this.activeSheet === 'profiles') { this.ProfilesTabContent() }
            else if (this.activeSheet === 'multi') { this.MultiTabContent() }
            else { this.EditTabContent() }
          }
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 6 })
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: this.panelContentMaxH() })
        // 常驻底栏：撤销 / 重置 / 取消 / 保存，任何 Tab 都可用。
        this.ActionFooter()
      }
    }
    .width(this.panelWidth())
    .backgroundColor('#EE1A1A1A')
    .borderRadius(14)
    .border({ width: 1, color: '#22FFFFFF' })
    .position({
      x: (this.panelX >= 0 ? this.panelX : (this.screenWidth - this.panelWidth()) / 2) + this.panelDragDx,
      y: this.panelTopBase() + this.panelDragDy
    })
  }

  // 编辑 Tab：多选横幅 + 选中控件编辑 + 全局缩放/透明 + 添加按钮。
  @Builder
  EditTabContent() {
    Column({ space: 5 }) {
      // 多选态常驻横幅：显示已选数量 + 一键进入批量操作 + 退出多选。
      if (this.multiSelectMode) {
        this.MultiSelectBanner()
      }
      // 选中态：分区标题 + 缩放/透明滑条 + 操作 chip（多选态隐藏，改用批量面板）
      if (!this.multiSelectMode && this.selectedIdx >= 0 && this.selectedItem() !== null) {
        this.SelectedItemControls()
      }

      // ===== 全局缩放 / 透明 =====
      this.SectionLabel('全局缩放')
      Row({ space: 4 }) {
        Text('缩放').fontSize(9).fontColor('#AAFFFFFF').width(28)
        Slider({ value: this.globalScaleVal, min: 50, max: 200, step: 5 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .onChange((val: number) => {
            this.beginSliderUndo('globalScale')
            this.globalScale = val / 100
            this.globalScaleVal = Math.round(val)
            this.refreshControls()
          })
        Text(this.globalScaleVal.toString() + '%').fontSize(9).fontColor('#AAFFFFFF').width(30)
      }.height(24)
      Row({ space: 4 }) {
        Text('透明').fontSize(9).fontColor('#AAFFFFFF').width(28)
        Slider({ value: this.globalOpacityVal, min: 20, max: 100, step: 5 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .onChange((val: number) => {
            this.beginSliderUndo('globalOpacity')
            this.globalOpacity = val / 100
            this.globalOpacityVal = Math.round(val)
            this.refreshControls()
          })
        Text(this.globalOpacityVal.toString() + '%').fontSize(9).fontColor('#AAFFFFFF').width(30)
      }.height(24)

      // ===== 添加 =====
      this.SectionLabel('添加')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        EditorChip({ icon: AppIconName.Plus, label: '添加按键', bg: '#4400AA55', onTap: () => { this.addButton() } })
        EditorChip({ icon: AppIconName.Hotbar, label: '物品栏', bg: '#44448AFF', onTap: () => { this.addHotbar() } })
      }
    }
    .width('100%')
  }

  // 常驻操作底栏沿用原布局；所有存储动作由有异常收口的串行入口执行。
  @Builder
  ActionFooter() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      EditorChip({ icon: AppIconName.Undo, label: '撤销', bg: this.canUndo() ? '#4444AAFF' : '#22FFFFFF', onTap: () => { this.undo() } })
      EditorChip({ icon: AppIconName.Refresh, label: '重置', bg: '#55884444', onTap: () => { this.resetEditorProfile_() } })
      EditorChip({ icon: AppIconName.Close, label: '取消', bg: '#55666666', onTap: () => { this.cancelEditor_() } })
      EditorChip({ icon: AppIconName.Save, label: this.persistenceBusy ? '处理中' : '保存', bg: '#4400AA00', onTap: () => { this.saveEditor_() } })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 2, bottom: 8 })
  }

  // UI 重绘 2026-07-11：选中控件区——分区标题 + 大小/透明滑条 + 带字形语义色的操作 chip。
  @Builder
  SelectedItemControls() {
    Column({ space: 4 }) {
      this.SectionLabel('选中 · ' + this.selectedTitle())
      // 按钮缩放
      Row({ space: 4 }) {
        Text('大小').fontSize(9).fontColor('#AAFFFFFF').width(28)
        Slider({ value: this.selectedScaleVal, min: 50, max: 200, step: 5 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .onChange((val: number) => {
            const item = this.selectedItem()
            if (!item) return
            this.beginSliderUndo('selectedScale')
            item.itemScale = val / 100
            // 用户手动缩放物品栏条 → 标记为"用户已定位"，下次 load 不再自动对齐覆盖其尺寸。
            if (item.type === ControlType.HOTBAR_SELECTOR) item.hotbarUserPlaced = true
            this.selectedScaleVal = Math.round(val)
            this.refreshControls()
          })
        Text(this.selectedScaleVal.toString() + '%').fontSize(9).fontColor('#AAFFFFFF').width(30)
      }.height(24)
      // 选中按钮透明度（一级面板；与二级"外观"面板的透明度共用 selectedOpacityVal，保持相等）
      Row({ space: 4 }) {
        Text('透明').fontSize(9).fontColor('#AAFFFFFF').width(28)
        Slider({ value: this.selectedOpacityVal, min: 20, max: 100, step: 5 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .onChange((val: number) => { this.applyOpacity(val) })
        Text(this.selectedOpacityVal.toString() + '%').fontSize(9).fontColor('#AAFFFFFF').width(30)
      }.height(24)
      // 操作 chip：图标 + 语义色（场景蓝 / 瞄准绿 / 外观紫 / 删除红 …），Flex 自动换行不溢出。
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        // 直接实例化 EditorChip（不经带参 @Builder）——保证 label/bg 随状态刷新（触发/场景/显示/瞄准/锁定循环可见）。
        EditorChip({ icon: AppIconName.Keyboard, label: '键位', bg: '#444488FF', onTap: () => { this.showKeyPicker = true } })
        EditorChip({ icon: AppIconName.Trigger, label: this.triggerLabel(), bg: '#447777FF', onTap: () => { this.cycleTrigger() } })
        EditorChip({ icon: AppIconName.Scene, label: this.sceneLabel(), bg: this.sceneBg(), onTap: () => { this.cycleScene() } })
        EditorChip({ icon: AppIconName.Eye, label: this.visibilityLabel(), bg: this.visibilityBg(), onTap: () => { this.cycleVisibility() } })
        EditorChip({ icon: AppIconName.Aim, label: this.dragLookLabel(), bg: this.dragLookBg(), onTap: () => { this.toggleDragLook() } })
        EditorChip({ icon: AppIconName.Tag, label: '标签', bg: '#55666666', onTap: () => {
          const item = this.selectedItem()
          this.labelDraft = item ? item.label : ''
          this.openTab('style')
        } })
        EditorChip({ icon: AppIconName.Appearance, label: '外观', bg: '#44AA66CC', onTap: () => { this.openTab('style') } })
        EditorChip({ icon: AppIconName.Copy, label: '复制', bg: '#4466BB6A', onTap: () => { this.duplicateSelected() } })
        EditorChip({ icon: this.selectedIsLocked() ? AppIconName.Unlock : AppIconName.Lock, label: this.lockedLabel(), bg: '#44FF9800', onTap: () => { this.toggleLocked() } })
        EditorChip({ icon: AppIconName.Trash, label: '删除', bg: '#66FF5252', onTap: () => { this.deleteSelected() } })
      }
    }
  }

  /**
   * Phase C（键鼠适配）：可见性策略三态循环。auto → 强显 → 强隐 → auto
   *
   * ⚠️ **「强显」当前零作用，与「自动」行为完全相同**（只有「强隐」真正生效）。
   * 这是本项目唯一一条用户可感知的"开关不起作用"缺陷：切到强显会看到绿色高亮与
   * 「显示策略 = 强显」的提示，可见性却不变。
   * 完整因果与两条改法见 `gamecontrol/src/main/ets/ControlLayout.ets` 的
   * `VisibilityOverride` 类型注释；处置属产品决定，见提案文档 §9.1。
   * 在那个决定做出之前**不要**只改这里的文案 —— 那会掩盖缺陷而不是修它。
   */
  private cycleVisibility(): void {
    const item = this.selectedItem()
    if (!item) return
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
    this.refreshControls()
    this.statusMsg = item.dragLook ? '已开启：按住拖动瞄准' : '已关闭拖动瞄准'
  }

  private dragLookLabel(): string {
    const item = this.selectedItem()
    return (item && item.dragLook) ? '瞄准✓' : '瞄准'
  }

  private dragLookBg(): string {
    const item = this.selectedItem()
    return (item && item.dragLook) ? '#4466BB6A' : '#44888888'
  }

  /**
   * 场景可见性三态循环（2026-05-30）：游戏中 → 菜单 → 始终 → 游戏中。
   *   游戏中 = 仅 grabbed（操作角色时）；菜单 = 仅背包/选项等鼠标可见时；始终 = 两者都显示。
   */
  private cycleScene(): void {
    const item = this.selectedItem()
    if (!item) return
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
    if (s === 'game') return '#44448AFF'
    if (s === 'menu') return '#44AA66CC'
    return '#4466BB6A'
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
    if (ov === 'force_show') return '#4466BB6A'
    if (ov === 'force_hide') return '#44FF5252'
    return '#44888888'
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
  private gamepadButtonOrder(): string[] {
    return ['A', 'B', 'X', 'Y', 'L1', 'R1', 'L2', 'R2', 'START', 'SELECT', 'L3', 'R3',
            'DPAD_UP', 'DPAD_DOWN', 'DPAD_LEFT', 'DPAD_RIGHT']
  }

  private gamepadBtnDisplayName(btn: string): string {
    if (btn === 'START') return 'Start'
    if (btn === 'SELECT') return 'Select'
    if (btn === 'DPAD_UP') return '十字↑'
    if (btn === 'DPAD_DOWN') return '十字↓'
    if (btn === 'DPAD_LEFT') return '十字←'
    if (btn === 'DPAD_RIGHT') return '十字→'
    return btn
  }

  /** 某手柄按钮当前动作的展示文案。 */
  private gamepadActionLabel(btn: string): string {
    const a = this.gamepad.buttonMap ? this.gamepad.buttonMap[btn] : undefined
    if (!a || a.kind === 'none') return '无'
    if (a.kind === 'hotbarPrev') return '上一格'
    if (a.kind === 'hotbarNext') return '下一格'
    // kind === 'key'
    const code = a.code ?? 0
    if (code === 0) return '无'
    return glfwKeyName(code)
  }

  /** 改键 sheet 的"当前键"入参（仅 kind==='key' 时给当前 code，否则空）。 */
  private gamepadBtnCurrentKeys(): number[] {
    const a = this.gamepad.buttonMap ? this.gamepad.buttonMap[this.gamepadBtnPicker] : undefined
    if (a && a.kind === 'key' && (a.code ?? 0) !== 0) return [a.code as number]
    return []
  }

  /** 改键 sheet 选了一个 GLFW key/鼠标 → 写回该手柄按钮（kind='key'）。 */
  private applyGamepadKey(btn: string, code: number): void {
    this.pushUndo()
    this.ensureButtonMap()
    this.gamepad.buttonMap![btn] = { kind: 'key', code: code }
    this.gamepad = this.cloneGamepad(this.gamepad)
    this.statusMsg = this.gamepadBtnDisplayName(btn) + ' → ' + glfwKeyName(code)
  }

  /** 循环该手柄按钮的"特殊动作"：键位(进改键) → 上一格 → 下一格 → 无 → 键位。 */
  private cycleGamepadSpecial(btn: string): void {
    this.pushUndo()
    this.ensureButtonMap()
    const a = this.gamepad.buttonMap![btn]
    const kind = a ? a.kind : 'none'
    if (kind === 'key') {
      this.gamepad.buttonMap![btn] = { kind: 'hotbarPrev' }
    } else if (kind === 'hotbarPrev') {
      this.gamepad.buttonMap![btn] = { kind: 'hotbarNext' }
    } else if (kind === 'hotbarNext') {
      this.gamepad.buttonMap![btn] = { kind: 'none' }
    } else {
      // none → 回到 key（默认空 code，引导用户点"键位"选）
      this.gamepad.buttonMap![btn] = { kind: 'key', code: 0 }
    }
    this.gamepad = this.cloneGamepad(this.gamepad)
  }

  private ensureButtonMap(): void {
    if (!this.gamepad.buttonMap) {
      this.gamepad.buttonMap = defaultGamepadButtonMap()
    }
  }

  private cycleStick(which: 'left' | 'right'): void {
    this.pushUndo()
    const order: StickRole[] = ['move', 'look', 'none']
    const cur: StickRole = which === 'left'
      ? (this.gamepad.leftStick ?? 'move')
      : (this.gamepad.rightStick ?? 'look')
    const next = order[(order.indexOf(cur) + 1) % order.length]
    if (which === 'left') this.gamepad.leftStick = next
    else this.gamepad.rightStick = next
    this.gamepad = this.cloneGamepad(this.gamepad)
  }

  private stickLabel(role: StickRole | undefined): string {
    if (role === 'move') return '移动'
    if (role === 'look') return '视角'
    return '无'
  }

  // 样式 Tab：统一样式编辑器。单选=编辑选中按钮；多选=批量编辑全部选中（一改全改）。
  // 样式字段（大小/透明度/圆角/形状/标签）统一走 styleTargets()，为以后拓展样式铺路。
  @Builder
  StyleTabContent() {
    Column({ space: 10 }) {
      if (this.styleTargets().length === 0) {
        Row() {
          Text('请先选择按钮（开启多选可批量改样式）')
            .fontSize(11).fontColor('#88FFFFFF')
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 24, bottom: 24 })
      } else {
        Text(this.multiSelectMode
          ? ('批量样式 · 作用于 ' + this.styleTargets().length.toString() + ' 个选中按钮')
          : '按钮外观')
          .fontSize(11).fontColor('#AAFFFFFF').width('100%')

        // 实时预览方块（取样式主项）
        Row() {
          Column() {
            Text(this.previewLabel())
              .width(this.previewSize())
              .height(this.previewSize())
              .textAlign(TextAlign.Center)
              .fontSize(14).fontColor('#FFFFFF')
              .backgroundColor('#88448AFF')
              .borderRadius(this.previewCorner())
              .opacity(this.curOpacityPct() / 100)
          }
          .width(96).height(96)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('#22000000')
          .borderRadius(8)
        }
        .width('100%').justifyContent(FlexAlign.Center)

        // 大小
        Row({ space: 3 }) {
          Text('大小').fontSize(11).fontColor('#AAFFFFFF').width(48)
          Slider({ value: this.curSizePct(), min: 50, max: 200, step: 5 })
            .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
            .onChange((val: number) => { this.applySize(val) })
          Text(this.curSizePct().toString() + '%').fontSize(10).fontColor('#FFFFFF').width(40)
        }.width('100%')

        // 透明度
        Row({ space: 3 }) {
          Text('透明度').fontSize(11).fontColor('#AAFFFFFF').width(48)
          Slider({ value: this.curOpacityPct(), min: 20, max: 100, step: 5 })
            .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
            .onChange((val: number) => { this.applyOpacity(val) })
          Text(this.curOpacityPct().toString() + '%').fontSize(10).fontColor('#FFFFFF').width(40)
        }.width('100%')

        // 圆角度
        Row({ space: 3 }) {
          Text('圆角').fontSize(11).fontColor('#AAFFFFFF').width(48)
          Slider({ value: this.curCornerPct(), min: 0, max: 100, step: 5 })
            .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
            .onChange((val: number) => { this.applyCorner(val) })
          Text(this.curCornerPct().toString() + '%').fontSize(10).fontColor('#FFFFFF').width(40)
        }.width('100%')

        // 圆角快捷：方 / 圆角 / 圆（当前预设蓝色高亮）
        Row({ space: 6 }) {
          Button('方形').fontSize(10).height(28).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor(this.cornerPreset() === 'square' ? '#448AFF' : '#44666666').borderRadius(14)
            .onClick(() => { this.applyCorner(0) })
          Button('圆角').fontSize(10).height(28).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor(this.cornerPreset() === 'round' ? '#448AFF' : '#44666666').borderRadius(14)
            .onClick(() => { this.applyCorner(30) })
          Button('圆形').fontSize(10).height(28).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor(this.cornerPreset() === 'circle' ? '#448AFF' : '#44666666').borderRadius(14)
            .onClick(() => { this.applyCorner(100) })
        }.width('100%')

        // 标签编辑（单选专属：标签是单个按钮的属性，不做批量）
        if (!this.multiSelectMode && this.selectedItem() !== null) {
          Row({ space: 6 }) {
            TextInput({ text: this.labelDraft, placeholder: '按钮文字（留空=键名）' })
              .height(34).fontSize(12).layoutWeight(1)
              .onChange((v: string) => { this.labelDraft = v })
            Button('应用').fontSize(11).height(30).fontColor('#FFFFFF')
              .backgroundColor('#448AFF').borderRadius(15)
              .onClick(() => { this.applyLabel() })
          }.width('100%')
        }

        Row({ space: 6 }) {
          Button('统一所有按钮大小').fontSize(11).height(32).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#55FF9800').borderRadius(16)
            .onClick(() => { this.unifyAllSizes() })
        }.width('100%')
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
  @Builder
  GamepadTabContent() {
    Column({ space: 6 }) {
      Row() {
        Text('启用手柄').fontSize(12).fontColor('#FFFFFF').layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.gamepad.enabled !== false })
          .selectedColor('#66BB6A')
          .onChange((b: boolean) => { this.pushUndo(); this.gamepad.enabled = b; this.gamepad = this.cloneGamepad(this.gamepad) })
      }.width('100%')

      // 摇杆角色 + 参数滑条
      Row({ space: 6 }) {
        Text('左摇杆').fontSize(11).fontColor('#AAFFFFFF').width(48)
        Button(this.stickLabel(this.gamepad.leftStick)).fontSize(10).height(24).fontColor('#FFFFFF')
          .backgroundColor('#447777FF').borderRadius(12).layoutWeight(1)
          .onClick(() => { this.cycleStick('left') })
        Text('右摇杆').fontSize(11).fontColor('#AAFFFFFF').width(48)
        Button(this.stickLabel(this.gamepad.rightStick)).fontSize(10).height(24).fontColor('#FFFFFF')
          .backgroundColor('#447777FF').borderRadius(12).layoutWeight(1)
          .onClick(() => { this.cycleStick('right') })
      }.width('100%')

      Row({ space: 3 }) {
        Text('死区').fontSize(11).fontColor('#AAFFFFFF').width(60)
        Slider({ value: Math.round((this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE) * 100), min: 0, max: 50, step: 1 })
          .layoutWeight(1)
          .onChange((val: number) => { this.beginSliderUndo('gamepadDeadZone'); this.gamepad.stickDeadZone = val / 100; this.gamepad = this.cloneGamepad(this.gamepad) })
        Text(Math.round((this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE) * 100).toString() + '%')
          .fontSize(10).fontColor('#FFFFFF').width(34)
      }.width('100%')

      Row({ space: 3 }) {
        Text('扳机阈值').fontSize(11).fontColor('#AAFFFFFF').width(60)
        Slider({ value: Math.round((this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD) * 100), min: 10, max: 95, step: 5 })
          .layoutWeight(1)
          .onChange((val: number) => { this.beginSliderUndo('gamepadTrigger'); this.gamepad.triggerThreshold = val / 100; this.gamepad = this.cloneGamepad(this.gamepad) })
        Text(Math.round((this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD) * 100).toString() + '%')
          .fontSize(10).fontColor('#FFFFFF').width(34)
      }.width('100%')

      Row({ space: 3 }) {
        Text('右摇杆增益').fontSize(11).fontColor('#AAFFFFFF').width(60)
        Slider({ value: Math.round((this.gamepad.lookScale ?? 1.0) * 100), min: 30, max: 300, step: 10 })
          .layoutWeight(1)
          .onChange((val: number) => { this.beginSliderUndo('gamepadLookScale'); this.gamepad.lookScale = val / 100; this.gamepad = this.cloneGamepad(this.gamepad) })
        Text((this.gamepad.lookScale ?? 1.0).toFixed(1)).fontSize(10).fontColor('#FFFFFF').width(34)
      }.width('100%')

      Divider().color('#33FFFFFF')

      // 按钮映射列表（外层统一面板 Scroll 负责滚动，这里不再嵌套 Scroll，避免手势冲突）
      Column({ space: 3 }) {
        ForEach(this.gamepadButtonOrder(), (btn: string) => {
          Row({ space: 6 }) {
            Text(this.gamepadBtnDisplayName(btn)).fontSize(11).fontColor('#FFFFFF').width(54)
            Text(this.gamepadActionLabel(btn)).fontSize(10).fontColor('#AAFFFFFF').layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('键位').fontSize(9).height(22).fontColor('#FFFFFF')
              .backgroundColor('#444488FF').borderRadius(11)
              .onClick(() => { this.gamepadBtnPicker = btn })
            Button(this.gamepadActionLabel(btn) === '上一格' || this.gamepadActionLabel(btn) === '下一格' || this.gamepadActionLabel(btn) === '无' ? '切换' : '特殊')
              .fontSize(9).height(22).fontColor('#FFFFFF')
              .backgroundColor('#44777777').borderRadius(11)
              .onClick(() => { this.cycleGamepadSpecial(btn) })
          }
          .width('100%').height(30)
          .padding({ left: 6, right: 6 })
          .backgroundColor('#11FFFFFF').borderRadius(6)
        }, (btn: string) => btn)
      }
      .width('100%')

      Button('恢复默认手柄映射').fontSize(11).height(28).fontColor('#FFFFFF')
        .backgroundColor('#44FF9800').borderRadius(14).width('100%')
        .onClick(() => { this.pushUndo(); this.gamepad = defaultGamepadConfig(); this.statusMsg = '手柄映射已恢复默认' })
    }
    .width('100%')
  }

  // 全局 Tab 内容（原 SettingsPanel，去掉标题栏/容器/跳手柄按钮/关闭按钮）。
  @Builder
  GlobalTabContent() {
    Column({ space: 8 }) {
      Row({ space: 3 }) {
        Text('视角灵敏度').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.sensVal, min: 30, max: 300, step: 5 })
          .layoutWeight(1)
          .onChange((val: number) => {
            this.beginSliderUndo('lookSensitivity')
            this.lookSensitivity = val / 100
            this.sensVal = Math.round(val)
          })
        Text((this.sensVal / 100).toFixed(2)).fontSize(11).fontColor('#FFFFFF').width(40)
      }
      // 方案 C：视角跟手度（平滑 α，越大越跟手/越小越平滑）
      Row({ space: 3 }) {
        Text('视角跟手').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.smoothVal, min: 10, max: 100, step: 5 })
          .layoutWeight(1)
          .onChange((val: number) => {
            this.beginSliderUndo('lookSmoothing')
            this.lookSmoothing = val / 100
            this.smoothVal = Math.round(val)
          })
        Text(this.smoothVal.toString() + '%').fontSize(11).fontColor('#FFFFFF').width(40)
      }
      // 方案 C：视角加速（0=关闭，手速越快增益越高）
      Row({ space: 3 }) {
        Text('视角加速').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.accelVal, min: 0, max: 100, step: 5 })
          .layoutWeight(1)
          .onChange((val: number) => {
            this.beginSliderUndo('lookAccel')
            this.lookAccel = val / 100
            this.accelVal = Math.round(val)
          })
        Text(this.accelVal === 0 ? '关' : (this.accelVal.toString() + '%')).fontSize(11).fontColor('#FFFFFF').width(40)
      }
      Row({ space: 3 }) {
        Text('Y 轴倒置').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Toggle({ type: ToggleType.Switch, isOn: this.invertY })
          .selectedColor('#448AFF')
          .onChange((b: boolean) => { this.pushUndo(); this.invertY = b })
      }
      Row({ space: 3 }) {
        Text('摇杆死区').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.deadZoneVal, min: 1, max: 50, step: 1 })
          .layoutWeight(1)
          .onChange((val: number) => {
            this.beginSliderUndo('joystickDeadZone')
            this.joystickDeadZone = val / 100
            this.deadZoneVal = Math.round(val)
          })
        Text(this.deadZoneVal.toString() + '%').fontSize(11).fontColor('#FFFFFF').width(40)
      }
      Row({ space: 3 }) {
        Text('触觉反馈').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Toggle({ type: ToggleType.Switch, isOn: this.haptic })
          .selectedColor('#448AFF')
          .onChange((b: boolean) => { this.pushUndo(); this.haptic = b })
        Text('(预留)').fontSize(9).fontColor('#66FFFFFF')
      }
      // 自动对齐 / 吸附（2026-07-16）
      Divider().color('#33FFFFFF').margin({ top: 2, bottom: 2 })
      Row({ space: 3 }) {
        Text('自动对齐').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Toggle({ type: ToggleType.Switch, isOn: this.snapEnabled })
          .selectedColor('#448AFF')
          .onChange((b: boolean) => { this.pushUndo(); this.snapEnabled = b })
        Text('拖动时对齐并显示虚线').fontSize(9).fontColor('#66FFFFFF')
      }
      Row({ space: 3 }) {
        Text('对齐间距').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.snapGap, min: 0, max: 100, step: 1 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .enabled(this.snapEnabled)
          .onChange((val: number) => {
            this.beginSliderUndo('snapGap')
            this.snapGap = Math.round(val)
          })
        Text(this.snapGap.toString() + 'vp').fontSize(11).fontColor('#FFFFFF').width(40)
      }
      Row({ space: 3 }) {
        Text('吸附强度').fontSize(11).fontColor('#AAFFFFFF').width(70)
        Slider({ value: this.snapStrength, min: 2, max: 20, step: 1 })
          .layoutWeight(1).blockColor('#FFFFFF').selectedColor('#448AFF')
          .enabled(this.snapEnabled)
          .onChange((val: number) => {
            this.beginSliderUndo('snapStrength')
            this.snapStrength = Math.round(val)
          })
        Text(this.snapStrength.toString() + 'vp').fontSize(11).fontColor('#FFFFFF').width(40)
      }
    }
    .width('100%')
  }

  // 方案 Tab 内容（原 ProfileListPanel，去掉标题栏/容器/关闭按钮）。
  @Builder
  ProfilesTabContent() {
    Column({ space: 6 }) {
      Column({ space: 4 }) {
          ForEach(this.profileNames, (name: string) => {
            Row({ space: 8 }) {
              Text(name).fontSize(12)
                .fontColor(name === this.profileName ? '#448AFF' : '#FFFFFF')
                .layoutWeight(1)
              if (name === this.profileName) {
                AppIcon({ name: AppIconName.Check, iconSize: 14, color: '#448AFF', weight: FontWeight.Bold })
              }
              if (this.profileNames.length > 1) {
                Row() {
                  AppIcon({ name: AppIconName.Close, iconSize: 14, color: '#FF5252' })
                }
                .onClick(() => { this.deleteEditorProfile_(name) })
              }
            }
            .width('100%').height(32)
            .padding({ left: 8, right: 8 })
            .backgroundColor(name === this.profileName ? '#22448AFF' : '#00000000')
            .borderRadius(6)
            .onClick(() => { this.switchEditorProfile_(name) })
          }, (name: string) => name)
      }.width('100%')
      Button('+ 新建方案').fontSize(11).height(28).fontColor('#FFFFFF')
        .backgroundColor('#44448AFF').borderRadius(14).width('100%')
        .onClick(() => { this.createEditorProfile_() })
    }
    .width('100%')
  }

  // ============= 多选批量操作 Tab + 横幅 + 统一面板框架（2026-07-16） =============

  /** 多选态常驻横幅（工具面板顶部）：已选数量 + 进入批量 + 退出多选。 */
  @Builder
  MultiSelectBanner() {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Copy, iconSize: 14, color: '#66BB6A' })
      Text('多选中 · 已选 ' + this.selectedIds.length.toString() + ' 个')
        .fontSize(11).fontColor('#66BB6A').fontWeight(FontWeight.Medium).layoutWeight(1)
      Text('批量')
        .fontSize(11).fontColor('#FFFFFF')
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .backgroundColor('#4466BB6A').borderRadius(11)
        .onClick(() => { this.openTab('multi') })
      Text('退出')
        .fontSize(11).fontColor('#FFFFFF')
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .backgroundColor('#55666666').borderRadius(11)
        .onClick(() => { this.setMultiSelect(false) })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .backgroundColor('#2266BB6A').borderRadius(8)
    .alignItems(VerticalAlign.Center)
  }

  // 多选 Tab 内容：开关 + 批量对齐/等间距/样式/锁定/复制/删除。
  @Builder
  MultiTabContent() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('多选模式').fontSize(12).fontColor('#FFFFFF').layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.multiSelectMode })
          .selectedColor('#66BB6A')
          .onChange((b: boolean) => { this.setMultiSelect(b) })
      }.width('100%')
      Text(this.multiSelectMode
        ? ('点按钮切换选中，拖动成组移动 · 已选 ' + this.selectedIds.length.toString() + ' 个')
        : '开启后点按钮可多选，再批量对齐/改样式/删除')
        .fontSize(10).fontColor('#88FFFFFF').width('100%')

      if (this.multiSelectMode) {
        Row({ space: 6 }) {
          Button('全选').fontSize(10).height(28).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44448AFF').borderRadius(14).onClick(() => { this.selectAllControls() })
          Button('清空').fontSize(10).height(28).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44666666').borderRadius(14).onClick(() => { this.clearSelection() })
        }.width('100%')

        Divider().color('#33FFFFFF').margin({ top: 2, bottom: 2 })
        this.SectionLabel('对齐')
        Row({ space: 6 }) {
          Button('自动对齐').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#4466BB6A').borderRadius(15).onClick(() => { this.batchAlign('auto') })
          Button('水平对齐').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44448AFF').borderRadius(15).onClick(() => { this.batchAlign('h') })
          Button('垂直对齐').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44448AFF').borderRadius(15).onClick(() => { this.batchAlign('v') })
        }.width('100%')
        Button('等间距排列（间距 ' + this.snapGap.toString() + 'vp）').fontSize(10).height(30).fontColor('#FFFFFF')
          .backgroundColor('#447777FF').borderRadius(15).width('100%').onClick(() => { this.batchEqualSpacing() })

        Divider().color('#33FFFFFF').margin({ top: 2, bottom: 2 })
        this.SectionLabel('批量')
        Row({ space: 6 }) {
          Button('改样式').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44AA66CC').borderRadius(15).onClick(() => { this.openTab('style') })
          Button('复制').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#4466BB6A').borderRadius(15).onClick(() => { this.batchDuplicate() })
        }.width('100%')
        Row({ space: 6 }) {
          Button('锁定').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44FF9800').borderRadius(15).onClick(() => { this.batchSetLocked(true) })
          Button('解锁').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#44FF9800').borderRadius(15).onClick(() => { this.batchSetLocked(false) })
          Button('删除').fontSize(10).height(30).layoutWeight(1).fontColor('#FFFFFF')
            .backgroundColor('#66FF5252').borderRadius(15).onClick(() => { this.batchDelete() })
        }.width('100%')
      }
    }
    .width('100%')
  }

  /** 统一面板顶部的 Tab 栏。 */
  @Builder
  UnifiedTabBar() {
    Row({ space: 3 }) {
      this.TabChip('edit', '编辑')
      this.TabChip('style', '样式')
      this.TabChip('global', '全局')
      this.TabChip('gamepad', '手柄')
      this.TabChip('profiles', '方案')
      this.TabChip('multi', '多选')
    }
    .width('100%').height(28).margin({ bottom: 4 })
    .padding({ left: 8, right: 8 })
  }

  @Builder
  TabChip(tab: string, label: string) {
    Text(label)
      .fontSize(10)
      .fontColor(this.activeSheet === tab ? '#FFFFFF' : '#AAFFFFFF')
      .fontWeight(this.activeSheet === tab ? FontWeight.Bold : FontWeight.Normal)
      .layoutWeight(1)
      .height(24)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor(this.activeSheet === tab ? '#448AFF' : '#22FFFFFF')
      .onClick(() => { this.openTab(tab) })
  }

}

/** 独立输入设置界面。只编辑触控策略、来源视角与手柄；布局几何和组图原样保留。
 * 保存与取消共用原LayoutStore串行事务；销毁等待在途操作后收口，失败不丢草稿。
 */
import { LayoutProfile, LayoutEditSession, LayoutEditCheckpoint, cloneLayout,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  DEFAULT_JOYSTICK_DEAD_ZONE, SOURCE_LOOK_PROFILE_VERSION, SourceLookPreferences, LookPolicySource,
  LookParameters, copySourceLookPreferences, copyLookParameters, splitLegacyLookPolicy, sourceLookParameters,
  GamepadConfig, GamepadAction, StickRole, defaultGamepadConfig, defaultGamepadButtonMap,
  DEFAULT_GAMEPAD_DEAD_ZONE, DEFAULT_TRIGGER_THRESHOLD, glfwKeyName, getLayoutStore,
  TouchConfiguration, normalizeTouchPreferences, TOUCH_ACTION_NAMES, defaultTouchActionKeys } from 'gamecontrol'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { KeyPickerSheet } from './KeyPickerSheet'
import { AppIconName } from 'commons'
import { AppIcon } from './AppIcon'
import { TouchOptionsEditor } from './TouchOptionsEditor'
import { EditorTheme } from './TouchEditorTheme'

@Component
export struct InputSettingsEditor {
  @Prop targetProfileName: string = ''
  @Prop screenWidth: number = 720
  @Prop screenHeight: number = 360
  @Prop resolvedActionKeys: number[] = []
  @Prop gyroscopeStatus: string = 'unknown'
  onDone: (profile: LayoutProfile | null) => void = (_profile: LayoutProfile | null): void => {}
  onInitializationFailed: (message: string) => void = (_message: string): void => {}
  @State private tab: string = 'touch'
  @State private touchSection: string = 'menu'
  @State private lookPane: string = 'sources'
  @State private gamepadPane: string = 'general'
  @State private gamepadGroup: string = 'abxy'
  @State private selectedGamepadButton: string = 'A'
  @State private gamepadBtnPicker: string = ''
  @State private touchBindingEditIndex: number = -1
  @State private touch: TouchConfiguration = new TouchConfiguration()
  @State private gamepad: GamepadConfig = defaultGamepadConfig()
  @State private lookSensitivity: number = DEFAULT_LOOK_SENSITIVITY
  @State private invertY: boolean = DEFAULT_INVERT_Y
  @State private lookSmoothing: number = DEFAULT_LOOK_SMOOTHING
  @State private lookAccel: number = DEFAULT_LOOK_ACCEL
  @State private lookPolicies: SourceLookPreferences | undefined = undefined
  @State private selectedLookSource: LookPolicySource = 'touch'
  @State private joystickDeadZone: number = DEFAULT_JOYSTICK_DEAD_ZONE
  @State private haptic: boolean = true
  @State private sensVal: number = 100
  @State private smoothVal: number = 60
  @State private accelVal: number = 0
  @State private deadZoneVal: number = 18
  @State private undoCount: number = 0
  @State private statusMsg: string = ''
  @State private profileName: string = ''
  @State private busy: boolean = true
  @State private leaveConfirm: boolean = false
  private session: LayoutEditSession = new LayoutEditSession()
  private original: LayoutProfile | undefined = undefined
  private sliderUndoKey: string = ''
  private baselineSig: string = ''
  private mounted: boolean = false
  private generation: number = 0
  private leaseHeld: boolean = false
  private completed: boolean = false
  private pending: Promise<void> | undefined = undefined
  private cleanupTask: Promise<void> | undefined = undefined

  /** 只读取目标草稿，进入设置不激活另一方案，也不克隆或写盘。 */
  async aboutToAppear(): Promise<void> {
    const generation: number=++this.generation
    this.mounted=true; this.busy=true
    const previous: Promise<void> | undefined=this.cleanupTask
    if (previous!==undefined) await previous
    if (!this.mounted || generation!==this.generation) return
    this.completed=false; this.cleanupTask=undefined; this.pending=undefined
    const store=getLayoutStore()
    try {
      await store.waitReady()
      if (!this.mounted || generation!==this.generation) return
      if (!store.beginEditorSession()) throw new Error('布局正在同步，请稍后重试')
      this.leaseHeld=true
      const profile: LayoutProfile | null=this.targetProfileName.length>0 ? store.getProfile(this.targetProfileName) : store.getActiveProfile()
      if (profile===null) throw new Error('方案已删除，请重新选择')
      this.original=cloneLayout(profile); this.session.open(profile); this.load_(profile)
      this.profileName=profile.name
      this.baselineSig=JSON.stringify(this.buildProfile())
    } catch(error) {
      this.statusMsg='无法打开输入设置：'+(error as Error).message
      if (this.mounted && generation===this.generation) this.onInitializationFailed(this.statusMsg)
    } finally { if (this.mounted && generation===this.generation) this.busy=false }
  }

  /** 退出立即使旧代失效；同一清理任务覆盖重复销毁，等待原保存结果后再退休自己的租约。 */
  aboutToDisappear(): void {
    this.mounted=false; this.generation++
    if (this.cleanupTask===undefined) this.cleanupTask=this.cleanup_()
  }

  /** 迟到写结果不得关闭新页面；销毁后等待原操作，再由原事务恢复或保留失败义务。 */
  private async cleanup_(): Promise<void> {
    const pending: Promise<void> | undefined=this.pending
    if (pending!==undefined) await pending
    try {
      if (this.leaseHeld && !this.completed && !(await getLayoutStore().restoreEditorTransaction()))
        hilog.error(0,'InputSettingsEditor','输入设置退出恢复未确认')
    } catch(error) { hilog.error(0,'InputSettingsEditor','退出恢复失败：%{public}s',(error as Error).message) }
    finally { this.release_() }
  }

  /** 仅归还本组件确实取得的一份嵌套编辑租约；重复完成或销毁不会释放宿主租约。 */
  private release_(): void {
    if (!this.leaseHeld) return
    this.leaseHeld=false; getLayoutStore().endEditorSession()
  }

  /** 将完整快照的设置域投影到V1响应字段；不修改original中的布局几何或组关系。 */
  private load_(profile: LayoutProfile): void {
    this.touch=normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()
    this.gamepad=this.cloneGamepad(profile.gamepad)
    this.lookSensitivity=profile.lookSensitivity ?? DEFAULT_LOOK_SENSITIVITY
    this.invertY=profile.invertY ?? DEFAULT_INVERT_Y
    this.lookSmoothing=profile.lookSmoothing ?? DEFAULT_LOOK_SMOOTHING
    this.lookAccel=profile.lookAccel ?? DEFAULT_LOOK_ACCEL
    this.lookPolicies=copySourceLookPreferences(profile.lookPolicies)
    this.joystickDeadZone=profile.joystickDeadZone ?? DEFAULT_JOYSTICK_DEAD_ZONE
    this.deadZoneVal=Math.round(this.joystickDeadZone*100)
    this.haptic=profile.haptic ?? true; this.syncLookSliders()
  }

  /** 完整原方案只替换设置域；从不以空controls或默认组图重建。 */
  private buildProfile(): LayoutProfile | null {
    if (this.original===undefined) return null
    const profile: LayoutProfile=cloneLayout(this.original)
    profile.touch=normalizeTouchPreferences(this.touch)
    profile.gamepad=this.cloneGamepad(this.gamepad)
    profile.lookPolicies=copySourceLookPreferences(this.lookPolicies)
    profile.lookSensitivity=this.lookSensitivity; profile.invertY=this.invertY
    profile.lookSmoothing=this.lookSmoothing; profile.lookAccel=this.lookAccel
    profile.joystickDeadZone=this.joystickDeadZone; profile.haptic=this.haptic
    if (profile.controlGroups===undefined && profile.lookPolicies!==undefined) profile.version=SOURCE_LOOK_PROFILE_VERSION
    return this.session.validate(profile)
  }

  /** 在实际修改之前记录当前完整方案，更新撤销可用状态并结束上一个滑条合并区间。 */
  private pushUndo(): void {
    this.session.remember(this.buildProfile()); this.undoCount=this.session.count(); this.sliderUndoKey=''
  }
  /** 恢复一个独立检查点中的设置；保留目标身份，后续保存仍接受原revision校验。 */
  private undo_(): void {
    const checkpoint: LayoutEditCheckpoint | undefined=this.session.takeUndo()
    if (checkpoint!==undefined) this.load_(checkpoint.profile)
    this.undoCount=this.session.count(); this.sliderUndoKey=''
  }

  /** 比较已物化默认值的进入基线；纯查看不会因旧配置缺省字段而产生虚假修改提醒。 */
  private dirty_(): boolean {
    if (this.original===undefined) return false
    return JSON.stringify(this.buildProfile())!==this.baselineSig
  }
  /** 有内容变化时显示明确的离开选择；无变化直接结束原编辑事务，忙碌时拒绝重入。 */
  private cancel_(): void {
    if (this.busy) return
    if (this.dirty_()) this.leaveConfirm=true
    else this.run_(false)
  }

  /** 所有保存、取消串行化；失败保留当前表单，成功才通知宿主退出。 */
  private run_(save: boolean): void {
    if (this.busy || !this.mounted || !this.leaseHeld) return
    this.busy=true; this.leaveConfirm=false
    this.pending=this.persist_(save,this.generation)
  }
  /** 等待仓库真实确认后才提交编辑事务；旧generation的完成留给cleanup恢复，不能关闭后来页面。 */
  private async persist_(save: boolean,generation: number): Promise<void> {
    const store=getLayoutStore()
    try {
      let result: LayoutProfile | null=null
      if (save) {
        const draft: LayoutProfile | null=this.buildProfile()
        if (draft===null) throw new Error('设置数据非法')
        result=await store.saveEditedProfile(draft)
        if (result===null) throw new Error('方案已改变或配置不被支持，请重新载入')
      } else if (!(await store.restoreEditorTransaction())) throw new Error('原方案恢复未确认')
      if (!this.mounted || generation!==this.generation) return
      store.commitEditorTransaction(); this.completed=true; this.release_()
      this.onDone(result)
    } catch(error) {
      if (this.mounted && generation===this.generation) this.statusMsg=(error as Error).message
      hilog.error(0,'InputSettingsEditor','%{public}s',(error as Error).message)
    } finally { if (this.mounted && generation===this.generation) this.busy=false }
  }

  /** 只组装当前设置分区、选键浮层和退出确认；不创建输入、游戏帧或传感器订阅。 */
  build() {
    Stack() {
      Column({space:12}) {
        Text('触控与输入设置').fontSize(20).fontColor(EditorTheme.text).width('100%')
        Text(this.profileName).fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Row({space:8}) {
          ForEach(['touch','look','gamepad'], (tab: string) => {
            Button(tab==='touch' ? '触控' : tab==='look' ? '视角与反馈' : '手柄').height(44).layoutWeight(1)
              .fontColor(this.tab===tab ? EditorTheme.accent : EditorTheme.text)
              .backgroundColor(EditorTheme.surface).onClick((): void => { this.tab=tab })
          }, (tab: string): string => tab)
        }.width('100%')
        Scroll() {
          Column({space:12}) {
            if (this.statusMsg.length>0) { Text(this.statusMsg).fontColor(EditorTheme.warning).fontSize(14) }
            if (this.touch.joystickAutoWalk || this.touch.gestureMode!=='buttons') {
              Text('旧方案中的自动前进和空白区域建造/战斗手势已停用；原配置保留用于导出。')
                .fontColor(EditorTheme.warning).fontSize(13)
            }
            if (this.tab==='touch') {
              TouchOptionsEditor({value:this.touch,section:this.touchSection,gyroscopeStatus:this.gyroscopeStatus,
                onRemap:(index: number): void => { this.touchBindingEditIndex=index },
                onChange:(value: TouchConfiguration,key: string,mode?: SliderChangeMode): void => { this.applyTouchChange(value,key,mode) }})
            } else if (this.tab==='look') { this.GlobalTabContent() }
            else { this.GamepadTabContent() }
          }.width('100%')
        // 短分区从滚动视口顶部开始，避免平板默认居中形成大块留白；长分区仍自然滚动。
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
        Row({space:8}) {
          Button('撤销').height(44).layoutWeight(1).enabled(this.undoCount>0).onClick((): void => { this.undo_() })
          Button('取消').height(44).layoutWeight(1).onClick((): void => { this.cancel_() })
          Button('保存').height(44).layoutWeight(1).onClick((): void => { this.run_(true) })
        }.width('100%')
      }.width(Math.min(560,Math.max(1,this.screenWidth-24))).height(Math.max(1,this.screenHeight-24))
        .padding(16).backgroundColor(EditorTheme.panel).borderRadius(16).enabled(!this.busy)
      if (this.touchBindingEditIndex>=0) {
        KeyPickerSheet({currentKeys:this.touchBindingKeys(),currentDescription:this.touchBindingDescription(),allowCombo:false,
          onPick:(keys: number[] | null): void => { this.applyTouchBinding(keys) }})
      }
      if (this.gamepadBtnPicker.length>0) {
        KeyPickerSheet({currentKeys:this.gamepadBtnCurrentKeys(),allowCombo:false,onPick:(keys: number[] | null): void => {
          if (keys!==null && keys.length>1) { this.statusMsg='手柄按钮只支持单键'; return }
          const button: string=this.gamepadBtnPicker; this.gamepadBtnPicker=''
          if (keys!==null) this.applyGamepadKey(button,keys.length>0 ? keys[0] : 0)
        }})
      }
      if (this.leaveConfirm) {
        Column({space:12}) {
          Text('保存这次设置？').fontSize(18).fontColor(EditorTheme.text)
          Button('保存并退出').height(44).onClick((): void => { this.run_(true) })
          Button('继续编辑').height(44).onClick((): void => { this.leaveConfirm=false })
          Button('放弃修改').height(44).onClick((): void => { this.run_(false) })
        }.padding(24).backgroundColor(EditorTheme.panel).borderRadius(16)
      }
    }.width('100%').height('100%').backgroundColor('#80000000').hitTestBehavior(HitTestMode.Default)
  }

  /** 选择器读取专用动作的最终单键；手动覆盖优先于游戏绑定，显式零代表解除。 */
  private touchBindingKeys(): number[] {
    if (this.touchBindingEditIndex < 0 || this.touchBindingEditIndex >= TOUCH_ACTION_NAMES.length) return []
    const name: string = TOUCH_ACTION_NAMES[this.touchBindingEditIndex]
    const automatic: number=this.touch.followGameBindings ?
      (this.resolvedActionKeys[this.touchBindingEditIndex] ?? defaultTouchActionKeys()[this.touchBindingEditIndex]) :
      defaultTouchActionKeys()[this.touchBindingEditIndex]
    const code: number = this.touch.actionOverrides[name] ?? automatic
    return code === 0 ? [] : [code]
  }

  /** 向用户区分手动覆盖、游戏绑定和离线默认参考，不把缺少游戏快照描述为已读到游戏设置。 */
  private touchBindingDescription(): string {
    const name: string=TOUCH_ACTION_NAMES[this.touchBindingEditIndex] ?? ''
    if(this.touch.actionOverrides[name]!==undefined) return '手动绑定'
    if(!this.touch.followGameBindings) return '默认绑定'
    return this.resolvedActionKeys.length>0 ? '游戏绑定' : '默认键参考，自动值在游戏内读取'
  }

  /** 取消选择器只关闭显示；确认单键或显式解除才记录一次撤销并更新动作覆盖。 */
  private applyTouchBinding(keys: number[] | null): void {
    const index: number = this.touchBindingEditIndex
    this.touchBindingEditIndex = -1
    if (keys === null || index < 0 || index >= TOUCH_ACTION_NAMES.length || keys.length > 1) return
    this.pushUndo()
    const next: TouchConfiguration = normalizeTouchPreferences(this.touch) ?? new TouchConfiguration()
    next.actionOverrides[TOUCH_ACTION_NAMES[index]] = keys.length === 0 ? 0 : keys[0]
    this.touch = next
  }

  /** 完整配置按语义去重；Slider结束即使值相同也关闭合并边界，避免下一次拖动丢撤销点。 */
  private applyTouchChange(value: TouchConfiguration, undoKey: string, mode?: SliderChangeMode): void {
    const changed: boolean = JSON.stringify(normalizeTouchPreferences(value)) !== JSON.stringify(normalizeTouchPreferences(this.touch))
    if (undoKey.length > 0) {
      if (!this.prepareSliderChange(undoKey, mode, changed)) return
    } else {
      if (!changed) return
      this.pushUndo()
    }
    this.touch = value
  }

  /** 深复制按钮映射并补齐既有缺省；调用者获得独立草稿，不能透过引用改写原方案。 */
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

  /** 返回现有逻辑按钮的固定展示顺序，不依赖平台硬件键码。 */
  private gamepadButtonOrder(): string[] {
    return ['A', 'B', 'X', 'Y', 'L1', 'R1', 'L2', 'R2', 'START', 'SELECT', 'L3', 'R3',
            'DPAD_UP', 'DPAD_DOWN', 'DPAD_LEFT', 'DPAD_RIGHT']
  }

  /** 将逻辑按钮ID转换为显示名称；未特殊命名的按钮保持其稳定ID文本。 */
  private gamepadBtnDisplayName(btn: string): string {
    if (btn === 'START') return 'Start'
    if (btn === 'SELECT') return 'Select'
    if (btn === 'DPAD_UP') return '十字↑'
    if (btn === 'DPAD_DOWN') return '十字↓'
    if (btn === 'DPAD_LEFT') return '十字←'
    if (btn === 'DPAD_RIGHT') return '十字→'
    return btn
  }

  /** 按实际绑定显示普通键、快捷栏动作或解除状态，不以零键码伪装有效动作。 */
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

  /** 选择器只读取当前手柄按钮的单键；特殊动作和未绑定返回空序列。 */
  private gamepadBtnCurrentKeys(): number[] {
    const a = this.gamepad.buttonMap ? this.gamepad.buttonMap[this.gamepadBtnPicker] : undefined
    if (a && a.kind === 'key' && (a.code ?? 0) !== 0) return [a.code as number]
    return []
  }

  /** 确认单键后复制映射、记录撤销并更新该按钮；零值表示明确解除。 */
  private applyGamepadKey(btn: string, code: number): void {
    this.pushUndo()
    this.ensureButtonMap()
    this.gamepad.buttonMap![btn] = code === 0 ? { kind: 'none' } : { kind: 'key', code: code }
    this.gamepad = this.cloneGamepad(this.gamepad)
    this.statusMsg = this.gamepadBtnDisplayName(btn) + ' → ' + this.gamepadActionLabel(btn)
  }

  /** 沿既有键位/上一格/下一格/无动作循环，只改选中按钮，不影响其它映射。 */
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

  /** 从当前草稿深复制映射，保证局部改键不会借用默认映射对象。 */
  private ensureButtonMap(): void {
    if (!this.gamepad.buttonMap) {
      this.gamepad.buttonMap = defaultGamepadButtonMap()
    }
  }

  /** 循环左或右摇杆的移动/视角/关闭角色，保存和运行采用仍由仓库及会话负责。 */
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

  /** 将摇杆角色转换为用户可读文本，缺省沿原移动语义显示。 */
  private stickLabel(role: StickRole | undefined): string {
    if (role === 'move') return '移动'
    if (role === 'look') return '视角'
    return '无'
  }

  /** 按需构建手柄基本参数与映射分区；所有操作只修改本编辑草稿。 */
  @Builder
  GamepadTabContent() {
    Column({ space: 12 }) {
      // 页内选择只决定构建哪组设置，不改变已确认的手柄角色、按钮或 Native 输入状态。
      Row({ space: 4 }) {
        Button('基本参数').fontSize(14).height(44).layoutWeight(1).borderRadius(EditorTheme.radiusSmall)
          .backgroundColor(this.gamepadPane === 'general' ? EditorTheme.surfaceActive : EditorTheme.surface)
          .fontColor(this.gamepadPane === 'general' ? EditorTheme.accent : EditorTheme.muted)
          .onClick((): void => { this.gamepadPane = 'general' })
        Button('按钮映射').fontSize(14).height(44).layoutWeight(1).borderRadius(EditorTheme.radiusSmall)
          .backgroundColor(this.gamepadPane === 'buttons' ? EditorTheme.surfaceActive : EditorTheme.surface)
          .fontColor(this.gamepadPane === 'buttons' ? EditorTheme.accent : EditorTheme.muted)
          .onClick((): void => { this.gamepadPane = 'buttons' })
      }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)

      if (this.gamepadPane === 'general') {
        Row() {
          Text('启用手柄').fontSize(14).fontColor(EditorTheme.text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.gamepad.enabled !== false })
            .selectedColor(EditorTheme.accent).switchPointColor(EditorTheme.panel)
            .onChange((b: boolean) => { this.pushUndo(); this.gamepad.enabled = b; this.gamepad = this.cloneGamepad(this.gamepad) })
        }.width('100%').constraintSize({ minHeight: 48 })

        // 角色继续走原三态循环；当前按钮明确显示角色，不在 UI 层重写业务映射。
        Row({ space: 12 }) {
          Text('左摇杆').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Button(this.stickLabel(this.gamepad.leftStick ?? 'move')).fontSize(14).height(44).fontColor(EditorTheme.accent)
            .backgroundColor(EditorTheme.surfaceActive).borderRadius(EditorTheme.radiusSmall).constraintSize({ minWidth: 96 })
            .onClick(() => { this.cycleStick('left') })
        }.width('100%')
        Row({ space: 12 }) {
          Text('右摇杆').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Button(this.stickLabel(this.gamepad.rightStick ?? 'look')).fontSize(14).height(44).fontColor(EditorTheme.accent)
            .backgroundColor(EditorTheme.surfaceActive).borderRadius(EditorTheme.radiusSmall).constraintSize({ minWidth: 96 })
            .onClick(() => { this.cycleStick('right') })
        }.width('100%')
        Text('点击角色按“移动 → 视角 → 无”切换。').fontSize(12).fontColor(EditorTheme.muted).width('100%')

        // 三根滑条的范围、步长、模式及 undoKey 与原设置完全相同。
        Column({ space: 2 }) {
          Row() {
            Text('摇杆死区').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text(Math.round((this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE) * 100).toString() + '%')
              .fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: Math.round((this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE) * 100), min: 0, max: 50, step: 1 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => {
              if (!this.prepareSliderChange('gamepadDeadZone', mode, (this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE) !== val / 100)) return
              this.gamepad.stickDeadZone = val / 100; this.gamepad = this.cloneGamepad(this.gamepad)
            })
        }.width('100%')
        Column({ space: 2 }) {
          Row() {
            Text('扳机阈值').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text(Math.round((this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD) * 100).toString() + '%')
              .fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: Math.round((this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD) * 100), min: 10, max: 95, step: 5 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => {
              if (!this.prepareSliderChange('gamepadTrigger', mode, (this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD) !== val / 100)) return
              this.gamepad.triggerThreshold = val / 100; this.gamepad = this.cloneGamepad(this.gamepad)
            })
        }.width('100%')
        Column({ space: 2 }) {
          Row() {
            Text('右摇杆增益').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
            Text((this.gamepad.lookScale ?? 1.0).toFixed(1)).fontSize(14).fontColor(EditorTheme.text)
          }.width('100%')
          Slider({ value: Math.round((this.gamepad.lookScale ?? 1.0) * 100), min: 30, max: 300, step: 10 })
            .width('100%').blockColor(EditorTheme.text).selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
            .onChange((val: number, mode: SliderChangeMode) => {
              if (!this.prepareSliderChange('gamepadLookScale', mode, (this.gamepad.lookScale ?? 1) !== val / 100)) return
              this.gamepad.lookScale = val / 100; this.gamepad = this.cloneGamepad(this.gamepad)
            })
        }.width('100%')
      } else {
        // 分组覆盖原 16 个逻辑按钮，列表和作用对象卡共用真实按钮名，防止特殊动作改到别的按钮。
        Row({ space: 4 }) {
          Button('ABXY').fontSize(13).height(44).layoutWeight(1).borderRadius(EditorTheme.radiusSmall)
            .backgroundColor(this.gamepadGroup === 'abxy' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(this.gamepadGroup === 'abxy' ? EditorTheme.accent : EditorTheme.muted)
            .onClick((): void => { this.gamepadGroup = 'abxy'; this.selectedGamepadButton = 'A' })
          Button('肩键扳机').fontSize(13).height(44).layoutWeight(1).borderRadius(EditorTheme.radiusSmall)
            .backgroundColor(this.gamepadGroup === 'shoulders' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(this.gamepadGroup === 'shoulders' ? EditorTheme.accent : EditorTheme.muted)
            .onClick((): void => { this.gamepadGroup = 'shoulders'; this.selectedGamepadButton = 'L1' })
          Button('功能十字').fontSize(13).height(44).layoutWeight(1).borderRadius(EditorTheme.radiusSmall)
            .backgroundColor(this.gamepadGroup === 'function' ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(this.gamepadGroup === 'function' ? EditorTheme.accent : EditorTheme.muted)
            .onClick((): void => { this.gamepadGroup = 'function'; this.selectedGamepadButton = 'START' })
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        ForEach(this.gamepadButtonsInGroup_(), (btn: string) => {
          Row({ space: 10 }) {
            Text(this.gamepadBtnDisplayName(btn)).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.selectedGamepadButton === btn ? EditorTheme.accent : EditorTheme.text).layoutWeight(1)
            Text(this.gamepadActionLabel(btn)).fontSize(14).fontColor(EditorTheme.muted)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            AppIcon({ name: this.selectedGamepadButton === btn ? AppIconName.Check : AppIconName.ChevronRight,
              iconSize: 16, color: this.selectedGamepadButton === btn ? EditorTheme.accent : EditorTheme.muted })
          }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.selectedGamepadButton === btn ? EditorTheme.surfaceActive : EditorTheme.surface)
            .borderRadius(EditorTheme.radiusSmall)
            .onClick((): void => { this.selectedGamepadButton = btn })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .accessibilityText(this.gamepadBtnDisplayName(btn) + '，' + this.gamepadActionLabel(btn) + '，选择设置')
        }, (btn: string): string => btn)
        Column({ space: 8 }) {
          Text('当前设置：' + this.gamepadBtnDisplayName(this.selectedGamepadButton))
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(EditorTheme.accent).width('100%')
          Text(this.selectedGamepadActionText_()).fontSize(14).fontColor(EditorTheme.text).width('100%')
          Row({ space: 8 }) {
            Button('选择单键').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.text)
              .backgroundColor(EditorTheme.panel).borderRadius(EditorTheme.radiusSmall)
              .border({ width: 1, color: EditorTheme.stroke })
              .onClick((): void => { this.gamepadBtnPicker = this.selectedGamepadButton })
            Button('切换特殊动作').fontSize(14).height(44).layoutWeight(1).fontColor(EditorTheme.accent)
              .backgroundColor(EditorTheme.surfaceActive).borderRadius(EditorTheme.radiusSmall)
              .onClick(() => { this.cycleGamepadSpecial(this.selectedGamepadButton) })
          }.width('100%')
          Button('解除此按钮绑定').fontSize(14).height(44).width('100%').fontColor(EditorTheme.muted)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .onClick((): void => { this.applyGamepadKey(this.selectedGamepadButton, 0) })
          Text('仅作用于 ' + this.gamepadBtnDisplayName(this.selectedGamepadButton) + '。特殊动作按“键位 → 上一格 → 下一格 → 无”切换；选择单键不支持组合键。')
            .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }.width('100%').padding(12).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
      }

      Button('恢复默认手柄配置').fontSize(14).height(44).fontColor(EditorTheme.text)
        .backgroundColor(EditorTheme.panel).border({ width: 1, color: EditorTheme.stroke })
        .borderRadius(EditorTheme.radiusSmall).width('100%')
        .onClick(() => { this.pushUndo(); this.gamepad = defaultGamepadConfig(); this.statusMsg = '手柄映射已恢复默认' })
      Text('恢复默认会同时还原摇杆角色、参数和按钮映射。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
    }
    .width('100%')
  }

  /** 按当前显示分组选择既有逻辑按钮，不改变存档映射顺序或内容。 */
  private gamepadButtonsInGroup_(): string[] {
    const buttons: string[] = this.gamepadButtonOrder()
    if (this.gamepadGroup === 'abxy') return buttons.slice(0, 4)
    if (this.gamepadGroup === 'shoulders') return buttons.slice(4, 8)
    return buttons.slice(8)
  }

  /** 区分等待选键与明确无动作，避免用户将尚未绑定的占位误认为有效按键。 */
  private selectedGamepadActionText_(): string {
    const action: GamepadAction | undefined = this.gamepad.buttonMap ? this.gamepad.buttonMap[this.selectedGamepadButton] : undefined
    if (action && action.kind === 'key' && (action.code ?? 0) === 0) return '键位待选择'
    return '当前动作：' + this.gamepadActionLabel(this.selectedGamepadButton)
  }

  /** 读取当前来源的完整四参数；旧方案继续使用兼容全局值，不自动拆分。 */
  private editorLookParameters(): LookParameters {
    if (this.lookPolicies !== undefined) return sourceLookParameters(this.lookPolicies, this.selectedLookSource)
    return { sensitivity: this.lookSensitivity, invertY: this.invertY,
      smoothing: this.lookSmoothing, acceleration: this.lookAccel }
  }

  /** 将当前来源参数投影到滑条显示值，仅读取草稿，不写Native或持久配置。 */
  private syncLookSliders(): void {
    const value: LookParameters = this.editorLookParameters()
    this.sensVal = Math.round(value.sensitivity * 100)
    this.smoothVal = Math.round(value.smoothing * 100)
    this.accelVal = Math.round(value.acceleration * 100)
  }

  /** 切换编辑目标并结束旧滑条撤销边界，避免两个来源的同名参数被合并成一次操作。 */
  private selectLookSource(source: LookPolicySource): void {
    if (this.selectedLookSource === source) return
    this.selectedLookSource = source; this.sliderUndoKey = ''; this.syncLookSliders()
  }

  /** 首次显式拆分复制原手感到各来源；关闭独立模式仍保留其参数以便再次启用。 */
  private setIndependentLook(enabled: boolean): void {
    if ((this.lookPolicies?.mode === 'independent') === enabled) return
    this.pushUndo()
    if (this.lookPolicies === undefined) this.lookPolicies = splitLegacyLookPolicy(this.editorLookParameters())
    const next: SourceLookPreferences | undefined = copySourceLookPreferences(this.lookPolicies)
    if (next === undefined) { this.statusMsg = '当前视角参数非法，未拆分'; return }
    next.mode = enabled ? 'independent' : 'legacy-global'
    this.lookPolicies = next; this.syncLookSliders()
  }

  /** 整体替换当前来源参数；兼容模式同步旧四标量，独立模式只更新选中来源。 */
  private updateEditorLook(value: LookParameters): void {
    const next: SourceLookPreferences | undefined = copySourceLookPreferences(this.lookPolicies)
    if (next === undefined) {
      this.lookSensitivity = value.sensitivity; this.invertY = value.invertY
      this.lookSmoothing = value.smoothing; this.lookAccel = value.acceleration
    } else if (next.mode === 'legacy-global') {
      next.legacy = copyLookParameters(value)
      this.lookSensitivity = value.sensitivity; this.invertY = value.invertY
      this.lookSmoothing = value.smoothing; this.lookAccel = value.acceleration; this.lookPolicies = next
    } else {
      if (this.selectedLookSource === 'physical') next.physical = copyLookParameters(value)
      else if (this.selectedLookSource === 'touch') next.touch = copyLookParameters(value)
      else if (this.selectedLookSource === 'gamepad') next.gamepad = copyLookParameters(value)
      else next.external = copyLookParameters(value)
      this.lookPolicies = next
    }
    this.syncLookSliders()
  }

  /** 来源标识只用于说明设置归属，不从外部兼容通道推断真实硬件。 */
  private lookSourceName(source: LookPolicySource): string {
    return source === 'physical' ? '物理鼠标' : source === 'touch' ? '触控/陀螺仪' :
      source === 'gamepad' ? '映射手柄' : '外部兼容'
  }

  /** 呈现来源视角与反馈参数；对齐吸附属于布局编辑器，不在此混入布局操作。 */
  @Builder
  GlobalTabContent() {
    Column({ space: 12 }) {
      Row({ space: 6 }) {
        ForEach(['sources', 'feel'], (pane: string): void => {
          Button(pane === 'sources' ? '视角来源' : pane === 'feel' ? '手感与反馈' : '对齐吸附')
            .height(44).fontSize(14).layoutWeight(1).padding({ left: 4, right: 4 }).borderRadius(12)
            .backgroundColor(this.lookPane === pane ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(this.lookPane === pane ? EditorTheme.accent : EditorTheme.muted)
            .onClick((): void => { this.lookPane = pane })
        }, (pane: string): string => pane)
      }.width('100%')
      Text(this.lookPolicies?.mode === 'independent' ? '当前来源：' + this.lookSourceName(this.selectedLookSource) : '当前政策：所有来源兼容设置')
        .fontSize(12).fontColor(EditorTheme.accent).width('100%')
      if (this.lookPane === 'sources') {
        Row() {
          Text('各来源独立视角').fontSize(14).fontColor(EditorTheme.text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.lookPolicies?.mode === 'independent' })
            .selectedColor(EditorTheme.accent).onChange((value: boolean): void => { this.setIndependentLook(value) })
        }.height(48).width('100%')
        if (this.lookPolicies?.mode === 'independent') {
          ForEach([['physical', 'touch'], ['gamepad', 'external']], (sources: string[]): void => {
            Row({ space: 8 }) {
              ForEach(sources, (name: string): void => {
                Button(this.lookSourceName(name as LookPolicySource)).height(44).fontSize(14).layoutWeight(1).borderRadius(12)
                  .backgroundColor(this.selectedLookSource === name ? EditorTheme.surfaceActive : EditorTheme.surface)
                  .fontColor(this.selectedLookSource === name ? EditorTheme.accent : EditorTheme.muted)
                  .onClick((): void => { this.selectLookSource(name as LookPolicySource) })
              }, (name: string): string => name)
            }.width('100%')
          }, (sources: string[]): string => sources.join('-'))
        }
        Text(this.lookPolicies?.mode !== 'independent' ? '开启独立设置会先复制当前手感，旧方案在关闭时保持原政策。' :
          this.selectedLookSource === 'physical' ? '物理鼠标保留原始计数与既有无平滑规则。' :
          this.selectedLookSource === 'touch' ? '陀螺仪继承灵敏度和倒置，独立积分，不叠加手指平滑与加速。' :
          '只修改当前来源；其它来源保留各自参数。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Row() { Text('视角灵敏度').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text((this.sensVal / 100).toFixed(2) + '×').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.sensVal, min: 30, max: 300, step: 5 }).width('100%').height(40)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('lookSensitivity', mode, this.editorLookParameters().sensitivity !== value / 100)) return
            const next: LookParameters = this.editorLookParameters(); next.sensitivity = value / 100; this.updateEditorLook(next)
          })
        Row() { Text('Y 轴倒置').fontSize(14).fontColor(EditorTheme.text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editorLookParameters().invertY }).selectedColor(EditorTheme.accent)
            .onChange((value: boolean): void => { this.pushUndo(); const next: LookParameters = this.editorLookParameters(); next.invertY = value; this.updateEditorLook(next) })
        }.height(48).width('100%')
      } else if (this.lookPane === 'feel') {
        Row() { Text('视角跟手度').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.smoothVal.toString() + '%').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.smoothVal, min: 10, max: 100, step: 5 }).width('100%').height(40)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('lookSmoothing', mode, this.editorLookParameters().smoothing !== value / 100)) return
            const next: LookParameters = this.editorLookParameters(); next.smoothing = value / 100; this.updateEditorLook(next)
          })
        Text('越大越跟手，越小越平滑。陀螺仪不叠加手指平滑和加速。').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Row() { Text('视角加速').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.accelVal === 0 ? '关闭' : this.accelVal.toString() + '%').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.accelVal, min: 0, max: 100, step: 5 }).width('100%').height(40)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('lookAccel', mode, this.editorLookParameters().acceleration !== value / 100)) return
            const next: LookParameters = this.editorLookParameters(); next.acceleration = value / 100; this.updateEditorLook(next)
          })
        Row() { Text('摇杆死区').fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
          Text(this.deadZoneVal.toString() + '%').fontSize(14).fontColor(EditorTheme.text) }.width('100%')
        Slider({ value: this.deadZoneVal, min: 1, max: 50, step: 1 }).width('100%').height(40)
          .selectedColor(EditorTheme.accent).blockColor(EditorTheme.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (!this.prepareSliderChange('joystickDeadZone', mode, this.joystickDeadZone !== value / 100)) return
            this.joystickDeadZone = value / 100; this.deadZoneVal = Math.round(value)
          })
        Row() { Column({ space: 3 }) { Text('触觉反馈').fontSize(14).fontColor(EditorTheme.text)
          Text('设备支持时生效').fontSize(12).fontColor(EditorTheme.muted) }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.haptic }).selectedColor(EditorTheme.accent)
            .onChange((value: boolean): void => { this.pushUndo(); this.haptic = value })
        }.height(52).width('100%')
      }
    }.width('100%')
  }

  /** 同一滑条手势只在首次真实改变前记录检查点。 */
  private beginSliderUndo(key: string): void {
    if (this.sliderUndoKey !== key) {
      this.pushUndo()
      this.sliderUndoKey = key
    }
  }

  /** 按SDK的Begin/Moving/End/Click收口一段撤销；同值结束事件仍会清除合并键。 */
  private prepareSliderChange(key: string, mode: SliderChangeMode | undefined, changed: boolean): boolean {
    if (mode === SliderChangeMode.Begin) this.sliderUndoKey = ''
    if (changed) this.beginSliderUndo(key)
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.sliderUndoKey = ''
    return changed
  }

  /** 绘制静态分区标题；可变选中状态由各Builder直接读取，避免按值标题缓存。 */
  @Builder
  SectionLabel(text: string) {
    Text(text).fontSize(14).fontWeight(FontWeight.Medium).fontColor(EditorTheme.muted)
      .width('100%').height(28).margin({ top: 8, bottom: 4 })
  }
}

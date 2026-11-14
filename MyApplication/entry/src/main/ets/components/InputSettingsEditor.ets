// 编辑器工具按钮明确使用小圆角矩形；后续显式圆角可覆盖此默认值，不跟随系统胶囊造型。
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
import { TouchOptionsEditor, TouchOptionSlider, TouchOptionToggle } from './TouchOptionsEditor'
import { controlProfileSaveLabel } from 'gamecontrol'
import { EditorPalette } from './TouchEditorTheme'

@Component
export struct InputSettingsEditor {
  /** 宿主提供的实例显示palette，不写入用户布局或输入配置。 */
  @Prop palette: EditorPalette = new EditorPalette();
  @Prop targetProfileName: string = ''
  @Prop screenWidth: number = 720
  @Prop screenHeight: number = 360
  @Prop resolvedActionKeys: number[] = []
  @Prop gyroscopeStatus: string = 'unknown'
  onDone: (profile: LayoutProfile | null) => void = (_profile: LayoutProfile | null): void => {}
  onInitializationFailed: (message: string) => void = (_message: string): void => {}
  @Prop initialSection: string = ''
  @State private category: string = 'home'
  @State private lookAdvanced: boolean = false
  @State private gamepadAdvanced: boolean = false
  @State private originallyActive: boolean = true
  private sliderGestureKey: string = ''
  @State private tab: string = 'touch'
  @State private touchSection: string = 'menu'
  @State private gamepadPane: string = 'general'
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
      this.originallyActive=store.getActiveProfile().profileId === profile.profileId
      this.selectCategory_(this.initialSection.length > 0 ? this.initialSection : 'home')
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
    this.haptic=profile.haptic ?? true
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


  /** 导航状态不进入草稿，不制造Undo；六类任务只映射既有设置域。 */
  private selectCategory_(category: string): void {
    const known: string[]=['home','move','look','menu','gesture','gyro','gamepad']
    this.category=known.indexOf(category)>=0 ? category : 'home'
    this.tab=category==='look' ? 'look' : category==='gamepad' ? 'gamepad' : 'touch'
    if (this.tab==='touch' && category!=='home') this.touchSection=category
    this.sliderUndoKey=''; this.sliderGestureKey=''
  }
  private categoryTitle_(category: string): string {
    return category==='move' ? '移动' : category==='look' ? '视角' : category==='menu' ? '菜单与背包' :
      category==='gesture' ? '快捷栏' : category==='gyro' ? '陀螺仪' : category==='gamepad' ? '映射手柄' : '设置目录'
  }
  @Builder
  CategoryDirectory_() {
    Column({space:8}) {
      ForEach(['home','move','look','menu','gesture','gyro','gamepad'],(category: string) => {
        Button(this.categoryTitle_(category)).type(ButtonType.Normal).borderRadius(6).height(44).width('100%').fontColor(this.palette.text)
          .backgroundColor(this.category===category ? this.palette.surfaceActive : this.palette.surface)
          .onClick((): void => { this.selectCategory_(category) })
      },(category: string): string => category)
    }.width('100%')
  }
  private touchLook_(): LookParameters {
    return this.lookPolicies===undefined ? {sensitivity:this.lookSensitivity,invertY:this.invertY,smoothing:this.lookSmoothing,acceleration:this.lookAccel} :
      sourceLookParameters(this.lookPolicies,'touch')
  }
  private setLookNumber_(field: string,value: number,mode: SliderChangeMode): void {
    const next: LookParameters=this.editorLookParameters()
    const old: number=field==='sensitivity' ? next.sensitivity : field==='smoothing' ? next.smoothing : next.acceleration
    if (!this.prepareSliderChange('look-'+field,mode,old!==value)) return
    if (field==='sensitivity') next.sensitivity=value
    else if (field==='smoothing') next.smoothing=value
    else next.acceleration=value
    this.updateEditorLook(next)
  }
  private setStickRole_(side: string,role: StickRole): void {
    if ((side==='left' ? this.gamepad.leftStick : this.gamepad.rightStick)===role) return
    this.pushUndo(); if (side==='left') this.gamepad.leftStick=role; else this.gamepad.rightStick=role
    this.gamepad=this.cloneGamepad(this.gamepad)
  }
  private setGamepadAction_(button: string,kind: 'hotbarPrev' | 'hotbarNext' | 'none'): void {
    if (this.gamepad.buttonMap?.[button]?.kind===kind) return
    this.pushUndo(); this.ensureButtonMap(); this.gamepad.buttonMap![button]={kind:kind}; this.gamepad=this.cloneGamepad(this.gamepad)
    this.statusMsg=this.gamepadBtnDisplayName(button)+' → '+(kind==='hotbarPrev' ? '上一格' : kind==='hotbarNext' ? '下一格' : '无')
  }
  private setGamepadNumber_(field: string,value: number,mode: SliderChangeMode): void {
    const old: number=field==='deadzone' ? this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE :
      field==='threshold' ? this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD : this.gamepad.lookScale ?? 1
    if (!this.prepareSliderChange('gamepad-'+field,mode,old!==value)) return
    if (field==='deadzone') this.gamepad.stickDeadZone=value
    else if (field==='threshold') this.gamepad.triggerThreshold=value
    else this.gamepad.lookScale=value
    this.gamepad=this.cloneGamepad(this.gamepad)
  }
  /** 恢复默认是显式破坏草稿的操作，确认绑定原页面与原配置；一次Undo恢复完整手柄域。 */
  private confirmGamepadReset_(): void {
    const generation: number=this.generation, signature: string=JSON.stringify(this.gamepad)
    this.getUIContext().showAlertDialog({title:'恢复默认手柄配置',message:'将重置左右摇杆、参数和全部按钮映射；可在保存前撤销。',
      primaryButton:{value:'取消',action:(): void=>{}},secondaryButton:{value:'恢复草稿',action:(): void=>{
        if (!this.mounted || generation!==this.generation || JSON.stringify(this.gamepad)!==signature) return
        this.pushUndo(); this.gamepad=defaultGamepadConfig()
      }}})
  }

  /** 只组装当前设置分区、选键浮层和退出确认；不创建输入、游戏帧或传感器订阅。 */
  build() {
    Stack() {
      Column({space:12}) {
        Row({space:8}) {
          Text('手感与输入').fontSize(20).fontColor(this.palette.text).layoutWeight(1)
          Text(this.profileName).fontSize(13).fontColor(this.palette.muted).maxLines(1)
            .textOverflow({overflow:TextOverflow.Ellipsis}).constraintSize({maxWidth:'50%'})
            .copyOption(CopyOptions.LocalDevice).accessibilityText('当前方案：'+this.profileName)
        }.width('100%')
        if (this.original?.isPreset) { Text('预设将在保存时创建完整副本并使用').fontSize(12).fontColor(this.palette.muted) }
        else if (!this.originallyActive) { Text('保存后使用此完整操控方案').fontSize(12).fontColor(this.palette.muted) }
        Row({space:12}) {
          if (this.screenWidth >= 900) {
            Scroll() { this.CategoryDirectory_() }.width(180).height('100%').align(Alignment.TopStart)
          }
          Scroll() {
            Column({space:12}) {
              if (this.statusMsg.length > 0) { Text(this.statusMsg).fontSize(14).fontColor(this.palette.warning).width('100%') }
              if (this.screenWidth < 900 && this.category !== 'home') {
                Button('‹ 设置目录 · '+this.categoryTitle_(this.category)).type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
                  .onClick((): void => { this.selectCategory_('home') })
              }
              if (this.category === 'home') {
                if (this.screenWidth < 900) { this.CategoryDirectory_() }
                TouchOptionToggle({palette:this.palette,label:'专用控件跟随游戏键位',
                  description:'作用于移动、快捷栏和陀螺仪使用识别；普通按钮保持自身绑定，手动覆盖优先。',value:this.touch.followGameBindings,
                  onChange:(value: boolean): void => {
                    if (value === this.touch.followGameBindings) return
                    this.pushUndo(); const next: TouchConfiguration=normalizeTouchPreferences(this.touch) ?? new TouchConfiguration()
                    next.followGameBindings=value; this.touch=next
                  }})
                if (this.touch.joystickAutoWalk || this.touch.gestureMode !== 'buttons') {
                  Text('旧自动前进和空白区域玩法手势已停用；原值保留用于往返导出。').fontSize(13).fontColor(this.palette.warning)
                }
              } else if (this.category === 'look') { this.GlobalTabContent() }
              else if (this.category === 'gamepad') { this.GamepadTabContent() }
              else {
                TouchOptionsEditor({palette:this.palette,value:this.touch,section:this.touchSection,showSectionPicker:false,
                  gyroscopeStatus:this.gyroscopeStatus,joystickDeadZone:this.joystickDeadZone,
                  sourceSensitivity:this.touchLook_().sensitivity,sourceInvertY:this.touchLook_().invertY,resolvedActionKeys:this.resolvedActionKeys,
                  onRemap:(index: number): void => { this.touchBindingEditIndex=index },
                  onDeadZone:(value: number,mode: SliderChangeMode): void => {
                    if (this.prepareSliderChange('joystickDeadZone',mode,this.joystickDeadZone !== value)) this.joystickDeadZone=value
                  },
                  onChange:(value: TouchConfiguration,key: string,mode?: SliderChangeMode): void => { this.applyTouchChange(value,key,mode) }})
                Button('专用键位政策：'+(this.touch.followGameBindings ? '跟随游戏' : '使用默认')+' ›').type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
                  .onClick((): void => { this.selectCategory_('home') })
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).height('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
        }.width('100%').layoutWeight(1)
        Row({space:8}) {
          Button('撤销').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).enabled(this.undoCount>0).onClick((): void => { this.undo_() })
          Button('取消').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.cancel_() })
          Button(controlProfileSaveLabel(this.original?.isPreset === true,this.originallyActive)).type(ButtonType.Normal).borderRadius(6).constraintSize({minHeight:44})
            .layoutWeight(2).onClick((): void => { this.run_(true) })
        }.width('100%')
      }.width(Math.min(this.screenWidth >= 900 ? 1000 : 560,Math.max(1,this.screenWidth-24)))
        .height(Math.max(1,this.screenHeight-24)).padding(16).backgroundColor(this.palette.panel).borderRadius(16).enabled(!this.busy)
      if (this.touchBindingEditIndex>=0) {
        KeyPickerSheet({palette:this.palette,currentKeys:this.touchBindingKeys(),currentDescription:this.touchBindingDescription(),allowCombo:false,
          onPick:(keys: number[] | null): void => { this.applyTouchBinding(keys) }})
      }
      if (this.gamepadBtnPicker.length>0) {
        KeyPickerSheet({palette:this.palette,currentKeys:this.gamepadBtnCurrentKeys(),allowCombo:false,
          onPick:(keys: number[] | null): void => {
            if (keys!==null && keys.length>1) { this.statusMsg='映射手柄只支持单键'; return }
            const button: string=this.gamepadBtnPicker; this.gamepadBtnPicker=''
            if (keys===null) return
            if (keys.length===0) this.setGamepadAction_(button,'none'); else this.applyGamepadKey(button,keys[0])
          }})
      }
      if (this.leaveConfirm) {
        Column({space:12}) {
          Text('放弃尚未保存的输入设置？').fontSize(18).fontColor(this.palette.text)
          Button('继续编辑').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.leaveConfirm=false })
          Button('放弃修改').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.run_(false) })
        }.padding(24).width(Math.min(420,this.screenWidth-24)).backgroundColor(this.palette.panel).borderRadius(16)
      }
    // Default允许分类、滑条和取消按钮参与命中，同时遮挡后方游戏；Block会把所有子控件一起禁用。
    // 游戏输入仍由宿主持有的编辑模态隔离，不靠吞掉设置页面自己的事件实现暂停。
    }.width('100%').height('100%').backgroundColor('#90000000').hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent): void => { event.stopPropagation() })
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
    const common: string[] = ['A','B','X','Y','L1','R1','L2','R2','START','SELECT','L3','R3','DPAD_UP','DPAD_DOWN','DPAD_LEFT','DPAD_RIGHT']
    // 显式数组分支避免向Object.keys传无上下文的对象字面量；缺表不制造临时映射或覆盖存档。
    const saved: string[] = this.gamepad.buttonMap === undefined ? [] : Object.keys(this.gamepad.buttonMap)
    return common.concat(saved.filter((name: string): boolean => common.indexOf(name) < 0))
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


  /** 从当前草稿深复制映射，保证局部改键不会借用默认映射对象。 */
  private ensureButtonMap(): void {
    if (!this.gamepad.buttonMap) {
      this.gamepad.buttonMap = defaultGamepadButtonMap()
    }
  }

  /** 循环左或右摇杆的移动/视角/关闭角色，保存和运行采用仍由仓库及会话负责。 */


  /** 将摇杆角色转换为用户可读文本，缺省沿原移动语义显示。 */
  private stickLabel(role: StickRole | undefined): string {
    if (role === 'move') return '移动'
    if (role === 'look') return '视角'
    return '无'
  }

  /** 按需构建手柄基本参数与映射分区；所有操作只修改本编辑草稿。 */
  @Builder
  GamepadTabContent() {
    Column({space:12}) {
      TouchOptionToggle({palette:this.palette,label:'启用映射手柄',description:'只控制键鼠映射，不关闭游戏的原生手柄API。',value:this.gamepad.enabled!==false,
        onChange:(value: boolean): void => { if (value===(this.gamepad.enabled!==false)) return; this.pushUndo(); this.gamepad.enabled=value; this.gamepad=this.cloneGamepad(this.gamepad) }})
      ForEach(['left','right'],(side: string) => {
        Text(side==='left' ? '左摇杆' : '右摇杆').fontSize(14).fontColor(this.palette.text)
        Row({space:4}) {
          ForEach(['move','look','none'],(role: string) => {
            Button(this.stickLabel(role as StickRole)).type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1)
              .backgroundColor((side==='left' ? this.gamepad.leftStick : this.gamepad.rightStick)===role ? this.palette.surfaceActive : this.palette.surface)
              .fontColor(this.palette.text).onClick((): void => { this.setStickRole_(side,role as StickRole) })
          },(role: string): string => role)
        }.width('100%')
      },(side: string): string => side)
      Button(this.gamepadPane==='buttons' ? '收起按钮映射' : '按钮映射 · '+this.gamepadButtonOrder().length.toString()+' 项 ›').type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
        .onClick((): void => { this.gamepadPane=this.gamepadPane==='buttons' ? 'general' : 'buttons' })
      if (this.gamepadPane==='buttons') {
        ForEach(this.gamepadButtonOrder(),(button: string) => {
          Button(this.gamepadBtnDisplayName(button)+' · '+this.gamepadActionLabel(button)).type(ButtonType.Normal).borderRadius(6).constraintSize({minHeight:44}).width('100%')
            .backgroundColor(this.selectedGamepadButton===button ? this.palette.surfaceActive : this.palette.surface).fontColor(this.palette.text)
            .onClick((): void => { this.selectedGamepadButton=button })
        },(button: string): string => button)
        Text('正在编辑：'+this.gamepadBtnDisplayName(this.selectedGamepadButton)).fontSize(14).fontColor(this.palette.accent)
        Button('选择单键').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.gamepadBtnPicker=this.selectedGamepadButton })
        Row({space:4}) {
          Button('上一格').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.setGamepadAction_(this.selectedGamepadButton,'hotbarPrev') })
          Button('下一格').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.setGamepadAction_(this.selectedGamepadButton,'hotbarNext') })
          Button('无').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.setGamepadAction_(this.selectedGamepadButton,'none') })
        }.width('100%')
      }
      Button(this.gamepadAdvanced ? '收起高级参数' : '高级参数与恢复默认 ›').type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
        .onClick((): void => { this.gamepadAdvanced=!this.gamepadAdvanced })
      if (this.gamepadAdvanced) {
        TouchOptionSlider({palette:this.palette,label:'映射摇杆死区',value:(this.gamepad.stickDeadZone ?? DEFAULT_GAMEPAD_DEAD_ZONE)*100,minimum:0,maximum:50,step:1,suffix:'%',
          onChange:(value: number,mode: SliderChangeMode): void => { this.setGamepadNumber_('deadzone',value/100,mode) }})
        TouchOptionSlider({palette:this.palette,label:'扳机阈值',value:(this.gamepad.triggerThreshold ?? DEFAULT_TRIGGER_THRESHOLD)*100,minimum:10,maximum:95,step:1,suffix:'%',
          onChange:(value: number,mode: SliderChangeMode): void => { this.setGamepadNumber_('threshold',value/100,mode) }})
        TouchOptionSlider({palette:this.palette,label:'摇杆局部视角倍率',value:(this.gamepad.lookScale ?? 1)*100,minimum:30,maximum:300,step:5,suffix:'%',
          onChange:(value: number,mode: SliderChangeMode): void => { this.setGamepadNumber_('scale',value/100,mode) }})
        Text('局部倍率继续与映射手柄来源的视角倍率相乘。额外保存的按钮映射完整保留。').fontSize(12).fontColor(this.palette.muted)
        Button('恢复默认手柄配置…').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').fontColor(this.palette.warning).onClick((): void => { this.confirmGamepadReset_() })
      }
    }.width('100%')
  }

  /** 按当前显示分组选择既有逻辑按钮，不改变存档映射顺序或内容。 */


  /** 区分等待选键与明确无动作，避免用户将尚未绑定的占位误认为有效按键。 */


  /** 读取当前来源的完整四参数；旧方案继续使用兼容全局值，不自动拆分。 */
  private editorLookParameters(): LookParameters {
    if (this.lookPolicies !== undefined) return sourceLookParameters(this.lookPolicies, this.selectedLookSource)
    return { sensitivity: this.lookSensitivity, invertY: this.invertY,
      smoothing: this.lookSmoothing, acceleration: this.lookAccel }
  }

  /** 将当前来源参数投影到滑条显示值，仅读取草稿，不写Native或持久配置。 */


  /** 切换编辑目标并结束旧滑条撤销边界，避免两个来源的同名参数被合并成一次操作。 */
  private selectLookSource(source: LookPolicySource): void {
    if (this.selectedLookSource === source) return
    this.selectedLookSource = source; this.sliderUndoKey = ''; this.sliderGestureKey = ''
  }

  /** 首次显式拆分复制原手感到各来源；关闭独立模式仍保留其参数以便再次启用。 */
  private setIndependentLook(enabled: boolean): void {
    if ((this.lookPolicies?.mode === 'independent') === enabled) return
    this.pushUndo()
    if (this.lookPolicies === undefined) this.lookPolicies = splitLegacyLookPolicy(this.editorLookParameters())
    const next: SourceLookPreferences | undefined = copySourceLookPreferences(this.lookPolicies)
    if (next === undefined) { this.statusMsg = '当前视角参数非法，未拆分'; return }
    next.mode = enabled ? 'independent' : 'legacy-global'
    this.lookPolicies = next
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

  }

  /** 来源标识只用于说明设置归属，不从外部兼容通道推断真实硬件。 */
  private lookSourceName(source: LookPolicySource): string {
    return source === 'physical' ? '物理鼠标' : source === 'touch' ? '触控/陀螺仪' :
      source === 'gamepad' ? '映射手柄' : '外部兼容'
  }

  /** 呈现来源视角与反馈参数；对齐吸附属于布局编辑器，不在此混入布局操作。 */
  @Builder
  GlobalTabContent() {
    Column({space:12}) {
      Text(this.lookPolicies?.mode === 'independent' ? '当前来源：'+this.lookSourceName(this.selectedLookSource) : '共享视角设置 · 影响原兼容政策覆盖的来源')
        .fontSize(14).fontColor(this.palette.accent).width('100%')
      TouchOptionSlider({palette:this.palette,label:'视角灵敏度',value:this.editorLookParameters().sensitivity*100,minimum:30,maximum:300,step:5,suffix:'%',
        onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('sensitivity',value/100,mode) }})
      TouchOptionToggle({palette:this.palette,label:'Y轴倒置',value:this.editorLookParameters().invertY,
        onChange:(value: boolean): void => {
          if (value===this.editorLookParameters().invertY) return
          this.pushUndo(); const next: LookParameters=this.editorLookParameters(); next.invertY=value; this.updateEditorLook(next)
        }})
      if (this.lookPolicies?.mode === 'independent' && this.selectedLookSource === 'physical') {
        Text('物理鼠标使用直接输入，不应用跟手度平滑；原保存值保留。').fontSize(13).fontColor(this.palette.muted)
      } else {
        TouchOptionSlider({palette:this.palette,label:'视角跟手度',value:this.editorLookParameters().smoothing*100,minimum:10,maximum:100,step:5,suffix:'%',
          onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('smoothing',value/100,mode) }})
      }
      TouchOptionSlider({palette:this.palette,label:'视角加速',value:this.editorLookParameters().acceleration*100,minimum:0,maximum:100,step:5,suffix:'%',
        onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('acceleration',value/100,mode) }})
      Text('陀螺仪继承触控来源的灵敏度和Y倒置，独立积分，不叠加手指平滑或加速。').fontSize(12).fontColor(this.palette.muted)
      TouchOptionToggle({palette:this.palette,label:'触觉反馈',description:'方案级，设备支持时生效；关闭不影响按键与释放。',value:this.haptic,
        onChange:(value: boolean): void => { if (value!==this.haptic) { this.pushUndo(); this.haptic=value } }})
      Button(this.lookAdvanced ? '收起来源设置' : '高级 · 各来源独立设置 ›').type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
        .onClick((): void => { this.lookAdvanced=!this.lookAdvanced })
      if (this.lookAdvanced) {
        TouchOptionToggle({palette:this.palette,label:'各来源独立视角',value:this.lookPolicies?.mode === 'independent',
          description:'首次开启复制当前手感；关闭仍保留各来源数值。',onChange:(value: boolean): void => { this.setIndependentLook(value) }})
        if (this.lookPolicies?.mode === 'independent') {
          ForEach(['physical','touch','gamepad','external'],(source: string) => {
            Button(this.lookSourceName(source as LookPolicySource)).type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
              .backgroundColor(this.selectedLookSource===source ? this.palette.surfaceActive : this.palette.surface)
              .fontColor(this.palette.text).onClick((): void => { this.selectLookSource(source as LookPolicySource) })
          },(source: string): string => source)
        }
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
    if (mode === SliderChangeMode.Begin) this.sliderGestureKey = key
    if (mode !== undefined && mode !== SliderChangeMode.Begin && mode !== SliderChangeMode.Click && this.sliderGestureKey !== key) return false
    if (changed) this.beginSliderUndo(key)
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { this.sliderUndoKey = ''; this.sliderGestureKey = '' }
    return changed
  }

  /** 绘制静态分区标题；可变选中状态由各Builder直接读取，避免按值标题缓存。 */
  @Builder
  SectionLabel(text: string) {
    Text(text).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.muted)
      .width('100%').height(28).margin({ top: 8, bottom: 4 })
  }
}

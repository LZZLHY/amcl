// 编辑器工具按钮明确使用小圆角矩形；后续显式圆角可覆盖此默认值，不跟随系统胶囊造型。
/** 独立输入设置界面。只编辑触控策略和来源视角；布局几何和组图原样保留。
 * 保存与取消共用原LayoutStore串行事务；销毁等待在途操作后收口，失败不丢草稿。
 */
import { LayoutProfile, LayoutEditSession, LayoutEditCheckpoint, cloneLayout,
  DEFAULT_LOOK_SENSITIVITY, DEFAULT_INVERT_Y, DEFAULT_LOOK_SMOOTHING, DEFAULT_LOOK_ACCEL,
  DEFAULT_JOYSTICK_DEAD_ZONE, SOURCE_LOOK_PROFILE_VERSION, SourceLookPreferences, LookPolicySource,
  LookParameters, copySourceLookPreferences, copyLookParameters, splitLegacyLookPolicy, sourceLookParameters,
  getLayoutStore,
  TouchConfiguration, normalizeTouchPreferences, TOUCH_ACTION_NAMES, defaultTouchActionKeys } from 'gamecontrol'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { KeyPickerSheet } from './KeyPickerSheet'
import { AppIconName } from 'commons'
import { AppIcon } from './AppIcon'
import { TouchOptionsEditor, TouchOptionSlider, TouchOptionToggle, TouchOptionChoice } from './TouchOptionsEditor'
import { controlProfileSaveLabel, getKeyOptionGroups } from 'gamecontrol'
import { DraftLeaveDecision, LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { LayoutDraftAccess } from '../launcherskill/LayoutDraftAccess';
import { touchFlagDraft, touchNumberDraft, touchChoiceDraft, touchBindingDraft } from '../runtime/TouchOptionDraft';
import { EditorPalette } from './TouchEditorTheme'
import { MobileInputSettings } from './MobileInputSettings'
import { GameSettingsDirectory, GameSettingsRail, InputSettingsColumns, InputSettingsGroup,
  gameSettingsTitle, gameSettingsDetail } from './GameSettingsNavigation'
import { gameSettingsWide, gameSettingsWidth, gameSettingsHeight } from './GameSettingsWindow'

@Component
export struct InputSettingsEditor {
  /** 宿主提供的实例显示palette，不写入用户布局或输入配置。 */
  @Prop palette: EditorPalette = new EditorPalette();
  @Prop targetProfileName: string = ''
  @Prop launcherWorkbench: boolean = false;
  private playerInput_: LayoutDraftAccess = new LayoutDraftAccess();
  private savedPlayerInput_: LayoutProfile | null = null;

  /** 所有以下操作均写当前草稿；保存仍由持有布局事务的编辑器确认。 */
  private inputSnapshot_(): SkillFields {
    const stamp=this.playerInput_.snapshot(JSON.stringify(this.buildProfile()));
    return { 'state':'draft','draftRef':stamp['draftRef'],'draftRevision':stamp['draftRevision'],'name':this.profileName,
      'touch':JSON.stringify(this.touch),'joystickDeadZone':this.joystickDeadZone,'haptic':this.haptic,
      'source':this.selectedLookSource,'independent':this.lookPolicies?.mode==='independent',
      'look':JSON.stringify(this.editorLookParameters()),
      'actions':TOUCH_ACTION_NAMES };
  }

  private async playerInputAction_(method:string,args:SkillFields):Promise<SkillFields> {
    if (!this.launcherWorkbench || !this.mounted || !this.leaseHeld || this.busy) return { 'state':'busy' };
    if (method==='readInputWorkbench') return this.inputSnapshot_();
    if (!this.playerInput_.permits(JSON.stringify(this.buildProfile()),args)) return { 'state':'unavailable','reason':'draftChanged' };
    if (this.skillLeave_?.pending()) return { 'state':'busy','reason':'originalLeavePending' };
    if (this.leaveConfirm || this.touchBindingEditIndex>=0) return { 'state':'needsUser' };
    if (method==='finishInputWorkbench') {
      const decision=args['decision'];
      if (decision==='undo' && this.undoCount>0) { this.undo_(); return this.inputSnapshot_(); }
      if (decision!=='save' && decision!=='discard') return { 'state':'unavailable','reason':'decision' };
      // 同一结束意图覆盖直接提交和退出确认；若持久化期间组件销毁，cleanup 会继续接管原事务。
      const generation=this.generation;
      const leave=LauncherSkillBus.draftLeave(method,():boolean=>this.mounted && generation===this.generation);
      this.skillLeave_=leave;
      let waiting=false;
      try {
        if (decision==='save') this.run_(true); else this.cancel_();
        waiting=this.leaveConfirm;
        if (waiting) return { 'state':'needsUser','surface':'unsavedDraft' };
        if (this.pending) await this.pending;
      } finally {
        if (!waiting) leave.dismiss();
      }
      const saved=this.savedPlayerInput_;
      return { 'state':!this.completed?'unknown':(saved?'ready':'cancelled'),'name':saved?.name??'', 'layoutId':saved?.profileId??'', 'revision':saved?.profileRevision??0 };
    }
    if (method==='setTouchOption') return this.playerTouchOption_(args);
    if (method==='setLookOption') return this.playerLookOption_(args);
    return { 'state':'failed','reason':'unknownOperation' };
  }

  private playerTouchOption_(args: SkillFields): SkillFields {
    const field=String(args['field']); const value=String(args['value']); const n=Number(value);
    const mode=SliderChangeMode.Click;
    let next: TouchConfiguration | undefined=undefined;
    if (['scroll','sprint','bindings','swap','drop','gyroX','gyroY'].includes(field) && (value==='true'||value==='false')) next=touchFlagDraft(this.touch,field,value==='true');
    else if ((field==='menu'&&['direct','touchpad'].includes(value)) || (field==='joystick'&&['fixed','floating'].includes(value)) ||
      (field==='gyroMode'&&['off','aim','always'].includes(value))) next=touchChoiceDraft(this.touch,field==='gyroMode'?'gyro':field,value);
    else if (value.trim() && Number.isSafeInteger(n) && ((field==='menuSpeed'&&n>=30&&n<=300) ||
      (field==='menuHold'&&n>=150&&n<=1000) || (field==='sprintThreshold'&&n>=50&&n<=150) ||
      (field==='hold'&&n>=200&&n<=1500) || (field==='gyroScale'&&n>=10&&n<=300))) {
      next=touchNumberDraft(this.touch,field==='gyroScale'?'gyro':field==='sprintThreshold'?'sprint':field,n);
    } else if (field==='deadZone' && n>=1 && n<=50) {
      this.adjustJoystickDeadZone_(n/100,mode); return this.inputSnapshot_();
    } else if(field==='action') {
      const index=TOUCH_ACTION_NAMES.indexOf(String(args['actionName']));
      if(index<0) return { 'state':'failed','reason':'action' };
      if(value==='inherit'||value==='unbind') next=touchBindingDraft(this.touch,index,value==='unbind');
      else if (value.trim() && getKeyOptionGroups().some((g):boolean=>g.options.some((k):boolean=>k.code===n))) {
        this.touchBindingEditIndex=index;this.applyTouchBinding([n]); return this.inputSnapshot_();
      }
    }
    if(!next) return { 'state':'failed','reason':'touchValue' };
    this.applyTouchChange(next,'',mode); return this.inputSnapshot_();
  }

  private playerLookOption_(args:SkillFields):SkillFields {
    const source=String(args['source']); const field=String(args['field']); const value=String(args['value']);const n=Number(value);
    if (!['physical','touch','external'].includes(source)) return { 'state':'failed','reason':'source' };
    this.selectLookSource(source as LookPolicySource);
    if (field==='independent' && (value==='true'||value==='false')) this.setIndependentLook(value==='true');
    else if(field==='invertY' && (value==='true'||value==='false')) this.setLookInversion_(value==='true');
    else if(field==='haptic' && (value==='true'||value==='false')) this.setHaptic_(value==='true');
    else if(value.trim() && Number.isFinite(n) && ((field==='sensitivity'&&n>=30&&n<=300)||(field==='smoothing'&&n>=10&&n<=100)||
      (field==='acceleration'&&n>=0&&n<=100))) this.setLookNumber_(field,n/100,SliderChangeMode.Click);
    else return { 'state':'failed','reason':'lookValue' };
    return this.inputSnapshot_();
  }

  private adjustJoystickDeadZone_(value:number,mode:SliderChangeMode):void {
    if (this.prepareSliderChange('joystickDeadZone',mode,this.joystickDeadZone !== value)) this.joystickDeadZone=value;
  }
  private setLookInversion_(value:boolean):void {
    if (this.editorLookParameters().invertY===value) return;
    this.pushUndo(); const next: LookParameters=this.editorLookParameters(); next.invertY=value; this.updateEditorLook(next);
  }
  private setHaptic_(value:boolean):void {
    if (value!==this.haptic) { this.pushUndo(); this.haptic=value; }
  }

  @Prop screenWidth: number = 720
  @Prop screenHeight: number = 360
  @Prop resolvedActionKeys: number[] = []
  @Prop gyroscopeStatus: string = 'unknown'
  onDone: (profile: LayoutProfile | null) => void = (_profile: LayoutProfile | null): void => {}
  onInitializationFailed: (message: string) => void = (_message: string): void => {}
  /** 工具切换由游戏宿主重新领取编辑检查点；启动器不展示本局工具。 */
  @Prop inGameSettings: boolean = false
  @Prop allowMobileInput: boolean = false
  @Prop allowLiveResolution: boolean = false
  onOpenGameTool: (tool: string) => void = (_tool: string): void => {}
  private pendingGameTool_: string = ''
  @Prop initialSection: string = ''
  @State private category: string = 'home'
  @State private originallyActive: boolean = true
  private sliderGestureKey: string = ''
  @State private tab: string = 'touch'
  @State private touchSection: string = 'menu'
  @State private touchBindingEditIndex: number = -1
  @State private touch: TouchConfiguration = new TouchConfiguration()
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
  private skillLeave_: DraftLeaveDecision | undefined = undefined;
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
    this.pendingGameTool_=''; this.leaveConfirm=false
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
      this.selectCategory_(this.initialSection.length > 0 ? this.initialSection :
        this.inGameSettings && this.wide_() ? 'look' : 'home')
      this.baselineSig=JSON.stringify(this.buildProfile())
      if (this.launcherWorkbench) {
        this.playerInput_.open();
        LauncherSkillBus.bind('inputWorkbench',this,(m:string,a:SkillFields):Promise<SkillFields>=>this.playerInputAction_(m,a),():boolean=>this.mounted && !this.completed && this.launcherWorkbench);
      }
    } catch(error) {
      this.statusMsg='无法打开输入设置：'+(error as Error).message
      if (this.mounted && generation===this.generation) this.onInitializationFailed(this.statusMsg)
    } finally { if (this.mounted && generation===this.generation) this.busy=false }
  }

  /** 退出立即使旧代失效；同一清理任务覆盖重复销毁，等待原保存结果后再退休自己的租约。 */
  aboutToDisappear(): void {
    if (this.launcherWorkbench) LauncherSkillBus.unbind('inputWorkbench',this);
    this.mounted=false; this.generation++
    if (this.cleanupTask===undefined) this.cleanupTask=this.cleanup_()
    this.skillLeave_?.hold(this.cleanupTask);
    this.skillLeave_?.dismiss();
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
  private keepEditing_(): void {
    this.pendingGameTool_=''; this.leaveConfirm=false;
    this.skillLeave_?.dismiss();
  }

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
    this.skillLeave_?.hold(this.pending);
    this.skillLeave_?.dismiss();
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
      store.commitEditorTransaction(); this.savedPlayerInput_=result; this.completed=true; this.release_()
      if (this.launcherWorkbench) this.playerInput_.complete({ 'state':result?'ready':'cancelled', 'name':result?.name??'',
        'layoutId':result?.profileId??'', 'revision':result?.profileRevision??0 });
      // 原检查点和嵌套租约均已归还，才允许宿主开始新工具的事务。
      const tool: string=this.pendingGameTool_
      this.pendingGameTool_=''
      if (!save && tool.length>0) this.onOpenGameTool(tool)
      else this.onDone(result)
    } catch(error) {
      if (this.mounted && generation===this.generation) {
        this.pendingGameTool_=''; this.statusMsg=(error as Error).message
      }
      hilog.error(0,'InputSettingsEditor','%{public}s',(error as Error).message)
    } finally { if (this.mounted && generation===this.generation) this.busy=false }
  }


  /** 导航状态不进入草稿，不制造Undo；六类任务只映射既有设置域。 */
  private selectCategory_(category: string): void {
    const known: string[]=['home','move','look','menu','gesture','gyro','policy']
    if (this.inGameSettings && this.allowMobileInput) known.push('devices')
    this.category=known.indexOf(category)>=0 ? category : 'home'
    this.tab=category==='look' ? 'look' : 'touch'
    if (this.tab==='touch' && this.category!=='home' && this.category!=='devices') this.touchSection=this.category
    this.sliderUndoKey=''; this.sliderGestureKey=''
  }
  /** 分类之间保留草稿；跨工具切换须走已有的放弃确认，失败时保留当前页面。 */
  private openDestination_(id: string): void {
    if (this.busy || this.completed || this.leaveConfirm || this.touchBindingEditIndex>=0) return
    if (id==='layout' || id==='resolution') {
      if (!this.inGameSettings || (id==='resolution' && !this.allowLiveResolution)) return
      this.pendingGameTool_=id; this.cancel_()
    } else { this.selectCategory_(id) }
  }

  private wide_(): boolean { return gameSettingsWide(this.screenWidth,this.screenHeight) }

  /** 横竖/分屏变化只派生呈现分类，不改导航记录和输入草稿；所有可见位置读取同一个结果。 */
  private effectiveCategory_(): string {
    if (this.category==='home' && this.wide_()) return this.inGameSettings ? 'look' : 'policy'
    return this.category
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
  /** 专用键位开关仍写当前完整方案，历史手势只读提示沿用同一兼容政策。 */
  @Builder
  PolicyCard_() {
    InputSettingsGroup({palette:this.palette,wide:this.wide_(),label:'专用控件'}) {
      TouchOptionToggle({palette:this.palette,wide:this.wide_(),label:'专用控件跟随游戏键位',
        description:'作用于移动、快捷栏和陀螺仪使用识别；普通按钮保持自身绑定，手动覆盖优先。',value:this.touch.followGameBindings,
        onChange:(value: boolean): void => {
          if (value === this.touch.followGameBindings) return
          this.pushUndo(); const next: TouchConfiguration=normalizeTouchPreferences(this.touch) ?? new TouchConfiguration()
          next.followGameBindings=value; this.touch=next
        }})
      if (this.touch.joystickAutoWalk || this.touch.gestureMode !== 'buttons') {
        Text('旧自动前进和空白区域玩法手势已停用；原值保留用于往返导出。').fontSize(13).fontColor(this.palette.warning)
      }
    }
  }

  /** 顺序与共享目录一致，读取当前草稿而非上次保存的配置。 */
  private directorySummaries_(): string[] {
    return [
      (this.lookPolicies?.mode==='independent' ? this.lookSourceName(this.selectedLookSource) : '共享视角')+' · '+Math.round(this.editorLookParameters().sensitivity*100)+'%',
      (this.touch.joystickCenter==='fixed'?'固定中心':'落指浮动')+' · '+Math.round(this.joystickDeadZone*100)+'%',
      (this.touch.menuMode==='direct'?'直接操作':'触摸板')+' · '+Math.round(this.touch.menuSensitivity*100)+'%',
      this.touch.hotbarSwapDoubleTap ? (this.touch.hotbarDropHold?'双击换手 · 长按丢弃':'双击换手') : this.touch.hotbarDropHold ? '长按丢弃':'手势已关闭',
      this.touch.gyroscopeMode==='off'?'已关闭':this.touch.gyroscopeMode==='aim'?'按住启用':'游戏内持续',
      this.touch.followGameBindings?'跟随游戏键位':'使用默认键位'
    ]
  }

  /** 各类始终共享当前草稿。窄窗口返回目录不会写入或结束编辑事务。 */
  @Builder
  PageBody_() {
    Column({space:12}) {
      if (this.statusMsg.length>0) { Text(this.statusMsg).fontSize(14).fontColor(this.palette.warning).width('100%') }
      if (this.effectiveCategory_()==='home') {
        GameSettingsDirectory({palette:this.palette,summaries:this.directorySummaries_(),includeGameTools:this.inGameSettings,allowLiveResolution:this.allowLiveResolution,
          allowMobileInput:this.inGameSettings && this.allowMobileInput,
          onSelect:(id: string): void=>{ this.openDestination_(id) }})
      } else if (this.effectiveCategory_()==='devices' && this.inGameSettings && this.allowMobileInput) {
        MobileInputSettings({ palette:this.palette, showDevices:true })
      } else if (this.effectiveCategory_()==='look') { this.LookPage_() }
      else if (this.effectiveCategory_()==='policy') {
        Column() { this.PolicyCard_() }.width('100%').constraintSize({maxWidth:580})
      } else {
        TouchOptionsEditor({palette:this.palette,value:this.touch,section:this.touchSection,showSectionPicker:false,wide:this.wide_(),
          gyroscopeStatus:this.gyroscopeStatus,joystickDeadZone:this.joystickDeadZone,
          sourceSensitivity:this.touchLook_().sensitivity,sourceInvertY:this.touchLook_().invertY,resolvedActionKeys:this.resolvedActionKeys,
          onRemap:(index: number): void => { this.touchBindingEditIndex=index },
          onDeadZone:(value: number,mode: SliderChangeMode): void => {
            this.adjustJoystickDeadZone_(value,mode)
          },
          onChange:(value: TouchConfiguration,key: string,mode?: SliderChangeMode): void => { this.applyTouchChange(value,key,mode) }})
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  Header_() {
    Row({space:12}) {
      if (!this.wide_() && this.effectiveCategory_()!=='home') {
        Button() { AppIcon({name:AppIconName.Back,iconSize:20,color:this.palette.accent}) }
          .type(ButtonType.Normal).borderRadius(this.palette.radiusSmall).width(44).height(44)
          .backgroundColor(this.palette.surface).accessibilityText('返回设置目录').onClick((): void=>{ this.selectCategory_('home') })
      }
      Column({space:3}) {
        Text(this.effectiveCategory_()==='home' ? (this.inGameSettings?'设置':'手感与输入') : gameSettingsTitle(this.effectiveCategory_()))
          .fontSize(this.wide_()?38:22).fontWeight(FontWeight.Bold).fontColor(this.palette.text)
        if (this.effectiveCategory_()!=='home') { Text(gameSettingsDetail(this.effectiveCategory_())).fontSize(12).fontColor(this.palette.muted) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.wide_() && this.effectiveCategory_()!=='home') {
        AppIcon({name:this.effectiveCategory_()==='look'?AppIconName.Aim:AppIconName.Settings,iconSize:28,color:this.palette.accent})
      } else if (!this.wide_()) {
        Text(this.profileName).fontSize(12).fontColor(this.palette.muted).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
          .constraintSize({maxWidth:'30%'}).copyOption(CopyOptions.LocalDevice).accessibilityText('当前方案：'+this.profileName)
      }
      if (this.inGameSettings) {
        Button('返回游戏').type(ButtonType.Normal).constraintSize({minHeight:44}).fontSize(13).fontColor(this.palette.accent)
          .backgroundColor(Color.Transparent).onClick((): void=>{ this.cancel_() })
      }
    }.width('100%').padding({left:18,right:12,top:this.wide_()?14:4,bottom:this.wide_()?10:4})
  }

  /** 保存文案区分预设副本和用户方案；返回仍经过原有草稿确认。 */
  @Builder
  Actions_() {
    Row({space:8}) {
      if (this.wide_() || this.screenWidth>=600) {
        Text(this.undoCount>0 && this.dirty_() ? '有未保存的修改' : this.original?.isPreset?'保存时创建副本并使用':
          !this.originallyActive?'保存后使用此方案':'已保存到当前方案')
          .fontSize(12).fontColor(this.palette.muted).layoutWeight(1)
      }
      Button('撤销').type(ButtonType.Normal).borderRadius(9).height(44).fontColor(this.palette.text).backgroundColor(this.palette.surface)
        .enabled(this.undoCount>0).onClick((): void=>{ this.undo_() })
      Button('取消').type(ButtonType.Normal).borderRadius(9).height(44)
        .fontColor(this.palette.text).backgroundColor(this.palette.surface).onClick((): void=>{ this.cancel_() })
      Button(controlProfileSaveLabel(this.original?.isPreset===true,this.originallyActive)).type(ButtonType.Normal)
        .borderRadius(9).constraintSize({minHeight:44}).fontColor(this.palette.onAccent).backgroundColor(this.palette.accentFill)
        .onClick((): void=>{ this.run_(true) })
    }.width('100%').justifyContent(FlexAlign.End).padding({left:12,right:12,top:4,bottom:4})
  }

  /** 页面只读取宿主投影的窗口信息，选键和退出确认继续独占编辑表面。 */
  build() {
    Stack() {
      Row() {
        if (this.wide_()) {
          GameSettingsRail({palette:this.palette,selected:this.effectiveCategory_(),profileName:this.profileName,
            allowMobileInput:this.inGameSettings && this.allowMobileInput,
            includeGameTools:this.inGameSettings,allowLiveResolution:this.allowLiveResolution,onSelect:(id:string):void=>{this.openDestination_(id)}})
        }
        Column() {
          this.Header_()
          Divider().strokeWidth(0.5).color(this.palette.stroke)
          // 导航到新类时从顶部开始；编辑同一页或拖动滑条不重置滚动位置。
          ForEach([this.effectiveCategory_()],(id: string) => {
            Scroll() { this.PageBody_() }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
              .padding({left:this.wide_()?20:14,right:this.wide_()?20:14,top:10,bottom:10})
          },(id: string): string=>id)
          // 设备偏好即时保存，方案草稿仍由原目录和返回游戏时的确认流程持有。
          if (this.effectiveCategory_()!=='devices' && (!this.inGameSettings || this.effectiveCategory_()!=='home' || (this.undoCount>0 && this.dirty_()))) {
            Divider().strokeWidth(0.5).color(this.palette.stroke)
            this.Actions_()
          }
        }.height('100%').layoutWeight(1)
      }.width(gameSettingsWidth(this.screenWidth,this.screenHeight)).height(gameSettingsHeight(this.screenWidth,this.screenHeight))
        .id('game-settings-sheet')
        .backgroundColor(this.palette.panel).borderRadius(this.palette.radiusPanel).clip(true)
        .enabled(!this.busy && !this.leaveConfirm && this.touchBindingEditIndex<0)
      if (this.touchBindingEditIndex>=0) {
        KeyPickerSheet({palette:this.palette,currentKeys:this.touchBindingKeys(),currentDescription:this.touchBindingDescription(),allowCombo:false,
          onPick:(keys: number[] | null): void => { this.applyTouchBinding(keys) }})
      }
      if (this.leaveConfirm) {
        Column({space:12}) {
          Text('放弃尚未保存的输入设置？').fontSize(18).fontColor(this.palette.text)
          Button('继续编辑').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.keepEditing_(); })
          Button('放弃修改').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.run_(false) })
        }.padding(24).width(Math.min(420,this.screenWidth-24)).backgroundColor(this.palette.panel).borderRadius(16)
      }
    // Default允许分类、滑条和取消按钮参与命中，同时遮挡后方游戏；Block会把所有子控件一起禁用。
    // 游戏输入仍由宿主持有的编辑模态隔离，不靠吞掉设置页面自己的事件实现暂停。
    }.width('100%').height('100%').backgroundColor(this.palette.overlay).hitTestBehavior(HitTestMode.Default)
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
      else next.external = copyLookParameters(value)
      this.lookPolicies = next
    }

  }

  /** 来源标识只用于说明设置归属，不从外部兼容通道推断真实硬件。 */
  private lookSourceName(source: LookPolicySource): string {
    return source === 'physical' ? '物理鼠标' : source === 'touch' ? '触控/陀螺仪' :
      '外部兼容'
  }

  /** 镜头参数一组共用当前来源。物理鼠标继续直通，旧平滑值保存在草稿内。 */
  @Builder
  GlobalTabContent() {
    Column({space:8}) {
      TouchOptionSlider({palette:this.palette,wide:this.wide_(),label:'视角灵敏度',value:this.editorLookParameters().sensitivity*100,minimum:30,maximum:300,step:5,suffix:'%',
        onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('sensitivity',value/100,mode) }})
      if (this.lookPolicies?.mode === 'independent' && this.selectedLookSource === 'physical') {
        Text('物理鼠标使用直接输入，不应用跟手度平滑；原保存值保留。').fontSize(13).fontColor(this.palette.muted)
      } else {
        TouchOptionSlider({palette:this.palette,wide:this.wide_(),label:'视角跟手度',value:this.editorLookParameters().smoothing*100,minimum:10,maximum:100,step:5,suffix:'%',
          onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('smoothing',value/100,mode) }})
      }
      TouchOptionSlider({palette:this.palette,wide:this.wide_(),label:'视角加速',value:this.editorLookParameters().acceleration*100,minimum:0,maximum:100,step:5,suffix:'%',
        onChange:(value: number,mode: SliderChangeMode): void => { this.setLookNumber_('acceleration',value/100,mode) }})
    }.width('100%')
  }

  @Builder
  LookPrimary_() {
    if (this.lookPolicies?.mode==='independent') {
      InputSettingsGroup({palette:this.palette,wide:this.wide_(),label:'编辑来源'}) {
        ForEach([['touch','physical'],['external']],(pair: string[]) => {
          Row({space:4}) {
            ForEach(pair,(source: string) => {
              TouchOptionChoice({palette:this.palette,wide:this.wide_(),label:this.lookSourceName(source as LookPolicySource),selected:this.selectedLookSource===source,
                onChoose:(): void=>{this.selectLookSource(source as LookPolicySource)}}).layoutWeight(1)
            },(source: string): string => source)
          }.width('100%')
        },(pair: string[]): string => pair[0])
      }
    }
    InputSettingsGroup({palette:this.palette,wide:this.wide_(),label:'镜头参数'}) { this.GlobalTabContent() }
  }

  @Builder
  LookSecondary_() {
    InputSettingsGroup({palette:this.palette,wide:this.wide_(),label:'方向与反馈'}) {
      TouchOptionToggle({palette:this.palette,wide:this.wide_(),label:'Y轴倒置',value:this.editorLookParameters().invertY,
        onChange:(value: boolean): void => {
          if (value===this.editorLookParameters().invertY) return
          this.setLookInversion_(value)
        }})
      TouchOptionToggle({palette:this.palette,wide:this.wide_(),label:'触觉反馈',description:'方案级，设备支持时生效；关闭不影响按键与释放。',value:this.haptic,
        onChange:(value: boolean): void => this.setHaptic_(value)})
    }
    InputSettingsGroup({palette:this.palette,wide:this.wide_(),label:'输入来源'}) {
      TouchOptionToggle({palette:this.palette,wide:this.wide_(),label:'各来源独立视角',value:this.lookPolicies?.mode === 'independent',
        description:this.lookPolicies?.mode==='independent'?'当前编辑：'+this.lookSourceName(this.selectedLookSource):'当前使用共享视角设置',
        onChange:(value:boolean):void=>{this.setIndependentLook(value)}})
      Text('陀螺仪跟随触控来源的灵敏度和 Y 轴方向。').fontSize(12).fontColor(this.palette.muted)
    }
  }

  @Builder
  LookPage_() {
    InputSettingsColumns({wide:this.wide_(),primary:():void=>{this.LookPrimary_()},secondary:():void=>{this.LookSecondary_()}})
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

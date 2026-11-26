// 编辑器工具按钮明确使用小圆角矩形；后续显式圆角可覆盖此默认值，不跟随系统胶囊造型。
/**
 * 虚拟按键布局编辑器：只维护控件、触控组、位置外观和编辑手势。
 * 输入策略在独立设置页编辑，目录管理由方案库承担；本组件不开草稿试用。
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
  GamepadConfig, cloneLegacyGamepadConfig,
  DEFAULT_BUTTON_SIZE, DEFAULT_BUTTON_OPACITY, DEFAULT_CORNER_RADIUS,
  DEFAULT_GLOBAL_OPACITY,
  effectiveCornerRadius, effectiveOpacity, effectiveLabel, ControlStyle,
  ControlScene, controlScene, setControlScene
} from 'gamecontrol';
import { glfwKeyName, GLFW_KEY_G, GLFW_KEY_T, GLFW_KEY_SPACE, GLFW_KEY_LEFT_SHIFT, GLFW_KEY_E, GLFW_KEY_ESCAPE,
  GLFW_KEY_F3, GLFW_KEY_F4, GLFW_KEY_F5, GLFW_KEY_TAB } from 'gamecontrol';
import { makeHotbarSelector, computeAutoGuiScale, computeHotbarRectPx } from 'gamecontrol';
import { GameGuiState, projectGameHotbar } from 'gamecontrol'
import { DEFAULT_SNAP_GAP, DEFAULT_SNAP_STRENGTH } from 'gamecontrol';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { KeyPickerSheet } from './KeyPickerSheet';
import { ControlColorPicker } from './ControlColorPicker';
import { SecondaryGroupEditResult, SecondaryControlRemoval, createSecondaryControlGroup, bindSecondaryControlGroup, makeSecondaryGroupOpener,
  addSecondaryGroupReturn, secondaryGroupOpener, secondaryGroupReturn, secondaryControlGroup,
  canBindSecondaryGroup, moveSecondaryGroupMember, secondaryControlRemovalPlan, removeSecondaryControls,
  SECONDARY_GROUP_PROFILE_VERSION, TOUCH_SECONDARY_GROUP_CAPABILITY, controlColorParts,controlColorWithAlpha,
  controlColorWithRgb,controlRgbHex } from 'gamecontrol';
import { ThemeScrollStyle } from './ThemeScrollStyle';
import { getLayoutStore, getKeyOptionGroups } from 'gamecontrol';
import { DraftLeaveDecision, LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { LayoutDraftAccess, layoutList } from '../launcherskill/LayoutDraftAccess';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { TouchConfiguration, normalizeTouchPreferences } from 'gamecontrol';
import { LayoutEditSession, LayoutEditCheckpoint, getDefaultLayout } from 'gamecontrol';
import { EditorPalette } from './TouchEditorTheme';
import { ControlGroup, ControlGroupAction, ControlPhaseBinding, ControlActionPhase, ControlGroupOperation,
  cloneControlGroups, enableLayoutControlGroups, duplicateLayoutControlGroup, removeLayoutControlGroup,
  CONTROL_GROUP_PROFILE_VERSION, TOUCH_PHASE_CAPABILITY, MAX_CONTROL_GROUPS } from 'gamecontrol';

import { ControlEditCapabilities, ControlEditTarget, controlEditTargets, findControlEditTarget,
  controlUsesPhases, controlEffectivePhases, controlPhaseConversionIssue, controlPhaseConversionDescription,
  convertControlToPhases, controlProfileSaveLabel } from 'gamecontrol'

// 撤销栈最大深度

// 已锁定的吸附阈值 → 脱离阈值倍数：脱离阈值 = SNAP_IN × 此值，形成黏滞防抖（横对齐后左右滑动
// 时的垂直小抖动 < 脱离阈值就不会掉出对齐高度）。
const SNAP_OUT_RATIO: number = 2.4

/** 添加目录只有原有普通按钮与物品栏；常用键只是普通按钮的初始绑定，不扩展控件类型。 */
/** 一次组删除确认冻结源组、编辑器世代和完整草稿；确认按钮捕获这一次对象。 */
interface GroupDeleteReview { groupId: string; secondary: boolean; generation: number; signature: string; }

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
  /** 宿主提供的实例显示palette，不写入用户布局或输入配置。 */
  @Prop palette: EditorPalette = new EditorPalette();
  @Prop icon: AppIconName
  @Prop label: string
  @Prop bg: ResourceColor
  onTap: () => void = () => {}

  build() {
    Row({ space: 4 }) {
      AppIcon({ name: this.icon, iconSize: 16, color: this.palette.text })
      Text(this.label).fontSize(14).fontColor(this.palette.text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
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

/** 面板返回栈的值快照；不借用可变控件对象，删除后按稳定ID重新核对。 */
class CompactEditorRoute {
  page: string = 'edit'
  selectedId: string = ''
  groupId: string = ''
  secondaryId: string = ''
  multi: boolean = false
  selectedIds: string[] = []
}

/** 独立Prop行使动态值正常刷新，避免多参数Builder冻结旧按键名/组名。 */
@Component
struct CompactEditorRow {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop title: string = ''
  @Prop value: string = ''
  onTap: ()=>void = ()=>{}
  build() {
    Button() {
      Row({space:5}) {
        Text(this.title).fontSize(14).fontColor(this.palette.text)
        Text(this.value).fontSize(12).fontColor(this.palette.muted).layoutWeight(1).textAlign(TextAlign.End)
          .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        AppIcon({name:AppIconName.ChevronRight,iconSize:14,color:this.palette.muted})
      }.width('100%')
    }.type(ButtonType.Normal).borderRadius(9).constraintSize({minHeight:44}).width('100%').padding({left:10,right:10})
      .backgroundColor(this.palette.surface)
      .onClick(()=>this.onTap())
  }
}

/**
 * 添加页的两行功能入口：左侧语义图标、主标题和说明，右侧区分“进入”和“已经添加”。
 * 只呈现宿主传入的状态，点击仍走原添加/选中方法，不保存或复制任何控件状态。
 */
@Component
struct CompactEditorActionRow {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop icon: AppIconName = AppIconName.Keyboard
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop checked: boolean = false
  onTap: ()=>void = ()=>{}
  build() {
    Button() {
      Row({space:8}) {
        // 不同SymbolGlyph的字面宽度不同，固定图标槽让“绑定按键”和“返回一级”的两行文本对齐。
        Row(){AppIcon({name:this.icon,iconSize:17,color:this.palette.muted})}
          .width(20).justifyContent(FlexAlign.Center)
        Column({space:2}) {
          Text(this.title).fontSize(13).fontColor(this.palette.text).width('100%')
            .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
          Text(this.description).fontSize(10).fontColor(this.palette.muted).width('100%')
            .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({name:this.checked?AppIconName.Check:AppIconName.ChevronRight,iconSize:14,
          color:this.checked?this.palette.accent:this.palette.muted})
      }.width('100%')
    }.type(ButtonType.Normal).borderRadius(6).width('100%').constraintSize({minHeight:44}).padding({left:1,right:3,top:5,bottom:5})
      .backgroundColor(Color.Transparent).border({width:{bottom:0.5},color:this.palette.stroke})
      .onClick(()=>this.onTap())
  }
}

@Component
export struct LayoutEditor {
  /** 宿主提供的实例显示palette，不写入用户布局或输入配置。 */
  @Prop palette: EditorPalette = new EditorPalette();
  @Prop targetProfileName: string = ''
  @Prop launcherWorkbench: boolean = false;
  private playerDraft_: LayoutDraftAccess = new LayoutDraftAccess();
  private completedPlayerLayout_: LayoutProfile | null = null;

  /** 机器只能编辑启动器独立页面已持有的草稿；游戏内复用同一组件时不注册能力。 */
  private readWorkbench_(query: string, offset: number): SkillFields {
    const stamp = this.playerDraft_.snapshot(this.contentSignature());
    const targets = controlEditTargets(this.controls).filter((entry: ControlEditTarget): boolean =>
      !query || entry.item.label.toLowerCase().includes(query.toLowerCase()) || entry.item.id === query);
    return { 'state':'draft', 'draftRef':stamp['draftRef'], 'draftRevision':stamp['draftRevision'],
      'name':this.profileName, 'width':this.screenWidth,'height':this.screenHeight,'total':targets.length,
      'activeControl':this.selectedItem()?.id ?? '', 'activeGroup':this.currentControlGroup,
      'defaultGroup':this.defaultControlGroupId ?? '',
      'groups':(this.controlGroups ?? []).map((g: ControlGroup): SkillFields => ({'id':g.id,'name':g.name,'visible':g.initialVisible,
        'secondary':g.secondary===true,'hidePrimary':g.hidePrimary===true})),
      'scalePercent':Math.round(this.globalScale*100), 'opacityPercent':Math.round(this.globalOpacity*100),'snap':this.snapEnabled,
      'snapGap':this.snapGap,'snapStrength':this.snapStrength,
      'items':targets.slice(offset,offset+32).map((entry: ControlEditTarget): SkillFields => {
        const item = entry.item;
        return { 'id':item.id,'type':item.type,'name':item.label,'parent':entry.parent?.id ?? '',
          'group':item.controlGroupId ?? '', 'hidden':item.hidden === true,'locked':item.locked === true,
          'x':this.itemPxX(item),'y':this.itemPxY(item),'width':this.itemW(item),'height':this.itemH(item),
          'scene':controlScene(item),'visibility':item.visibilityOverride ?? 'auto','trigger':item.trigger ?? 'press',
          'keys':effectiveKeys(item),'style':JSON.stringify(item.style ?? {}), 'phases':JSON.stringify(item.phaseBindings ?? []),
          'groupActions':JSON.stringify(item.groupActions ?? []),'secondaryAction':JSON.stringify(item.secondaryAction ?? {}),
          'swipeGroup':item.swipeGroup ?? '', 'dragLook':item.dragLook===true };
      }) };
  }

  /** 业务操作若因保护项、排列边界或当前值相同而未改草稿，如实回读，不能冒报修改成功。 */
  private changedWorkbench_(args:SkillFields):SkillFields {
    const snapshot=this.readWorkbench_('',0);
    snapshot['changed']=snapshot['draftRevision']!==args['draftRevision'];
    return snapshot;
  }

  private async skillWorkbench_(method: string,args: SkillFields): Promise<SkillFields> {
    if (!this.launcherWorkbench || !this.editorMounted || !this.editorReady || this.editorClosed || this.persistenceBusy ||
      this.groupDragging || this.dragIdx >= 0) return { 'state':'busy' };
    if (method === 'readControlWorkbench') {
      const offset=Number(args['offset'] ?? 0);
      if (!Number.isSafeInteger(offset) || offset<0) return { 'state':'failed','reason':'offset' };
      return this.readWorkbench_(String(args['search'] ?? ''),offset);
    }
    if (!this.playerDraft_.permits(this.contentSignature(),args)) return { 'state':'unavailable','reason':'draftChanged' };
    if (this.skillLeave_?.pending()) return { 'state':'busy', 'reason':'originalLeavePending' };
    const selected=this.selectedItem();
    if (this.positionDraftDirty || (selected && new ControlEditCapabilities(selected).label && this.labelDraft!==selected.label) ||
      this.showKeyPicker || this.showLeaveConfirm || this.deletingGroup || this.activeSheet==='confirm-delete' || this.activeSheet==='secondary-delete') return { 'state':'needsUser' };
    if (method === 'finishControlWorkbench') {
      const choice = args['decision'];
      if (choice==='undo') { if (!this.canUndo()) return { 'state':'unavailable' }; this.undo(); return this.changedWorkbench_(args); }
      if (choice!=='discard' && choice!=='save' && choice!=='input') return { 'state':'failed','reason':'decision' };
      // 保存同样可能在 flush 中途退场。写入之前建立一次结束意图，退场时才能把同代回滚交给原会话。
      const generation=this.editorGeneration;
      const leave=LauncherSkillBus.draftLeave(method,():boolean=>this.editorMounted && generation===this.editorGeneration);
      this.skillLeave_=leave;
      let waiting=false;
      try {
        if (choice==='discard') this.requestCancel_();
        else if (choice==='save') this.saveEditor_();
        else waiting=this.requestSettings_('home',leave);
        waiting=waiting || this.showLeaveConfirm;
        if (waiting) return { 'state':'needsUser','surface':'unsavedDraft' };
        if (choice==='input' && !this.nextSettingsSection) return { 'state':'unavailable','reason':'inputSettingsUnavailable' };
        const pending=this.persistenceTask; if (pending) await pending;
      } finally {
        if (!waiting) leave.dismiss();
      }
      if (!this.editorClosed) return { 'state':this.nextSettingsSection ? 'needsUser':'unknown' };
      if (choice==='input') return { 'state':'needsUser','reason':'inputSettingsRequested' };
      const saved=this.completedPlayerLayout_;
      return { 'state':saved ? 'ready' : 'cancelled','name':saved?.name ?? '', 'layoutId':saved?.profileId ?? '',
        'revision':saved?.profileRevision ?? 0 };
    }
    if (method==='addWorkbenchControl') {
      const kind=String(args['kind']);
      if (kind==='button') {
        const codes=this.skillKeys_(args['keys']);
        if (!codes || !codes.length) return { 'state':'failed','reason':'keys' };
        this.addButton(codes[0],codes);
      } else {
        if (!this.addControlOptions_().some((item:EditorAddControlOption):boolean=>item.id===kind)) return { 'state':'failed','reason':'kind' };
        this.addControlFromPanel_(kind);
      }
      return this.changedWorkbench_(args);
    }
    if (method==='editWorkbenchGroup') return this.skillGroup_(args);
    if (method==='arrangeWorkbenchSelection') return this.skillBatch_(args);
    const id=String(args['controlId']);
    const target=findControlEditTarget(this.controls,id);
    if (!target) return { 'state':'failed','reason':'missingControl' };
    this.setMultiSelect(false); this.selectControlIdentity_(id,false);
    if (this.selectedItem()?.id!==id) return { 'state':'unavailable','reason':'controlChanged' };
    if (method==='setWorkbenchGeometry') {
      if (target.item.locked) return { 'state':'unavailable','reason':'locked' };
      this.positionXDraft=String(args['x']); this.positionYDraft=String(args['y']);
      this.positionWidthDraft=String(args['width']); this.positionHeightDraft=String(args['height']);
      this.positionDraftDirty=true; this.applyPositionDraft_();
      if (this.positionDraftDirty) { this.syncPositionDraft_(); return { 'state':'failed','reason':'geometry' }; }
    } else if (method==='setWorkbenchAppearance') {
      if (!this.skillStyle_(target.item,args)) return { 'state':'failed','reason':'style' };
    } else if (method==='setWorkbenchBinding') {
      const state=this.skillBinding_(target.item,args); if(state!=='draft') return { 'state':state };
    } else if (method==='editWorkbenchControl') {
      const action=String(args['change']);
      if (action==='select') return this.changedWorkbench_(args);
      if (action==='duplicate') this.duplicateSelected();
      else if (action==='lock' || action==='unlock') { if (!!target.item.locked !== (action==='lock')) this.toggleLocked(); }
      else if (action==='show' || action==='hide') { if (!!target.item.hidden !== (action==='hide')) this.toggleHidden(); }
      else if (action==='remove') {
        if (!new ControlEditCapabilities(target.item).removable) return { 'state':'unavailable','reason':'protected' };
        this.pendingControlDelete=[id]; this.pendingDeleteSignature=JSON.stringify(this.buildProfile()); this.pendingDeleteGeneration=this.editorGeneration;
        this.openTab('confirm-delete'); return { 'state':'needsUser','surface':'confirmDelete' };
      } else return { 'state':'failed','reason':'change' };
    } else return { 'state':'failed','reason':'unknownOperation' };
    return this.changedWorkbench_(args);
  }

  /** 具名样式字段按产品控件能力和原调节范围校验。 */
  private skillStyle_(item: ControlItem,args: SkillFields): boolean {
    const field=String(args['field']); const value=String(args['value']); const number=Number(value);
    const mode=SliderChangeMode.Click; const caps=new ControlEditCapabilities(item);
    if (field==='name' && caps.label && value.length<=64) { this.labelDraft=value; this.applyLabel(); return true; }
    if (['bg','fg','borderColor'].includes(field) && caps.opacity && /^#[0-9a-fA-F]{6}$/.test(value)) {
      this.colorField=field; this.applyAppearanceRgb_(value,mode); return true;
    }
    if (!value.trim() || !Number.isFinite(number)) return false;
    if (field==='scale' && !item.locked && number>=50 && number<=200) this.applySize(number,mode);
    else if (field==='opacity' && caps.opacity && number>=10 && number<=100) this.applyOpacity(number,mode);
    else if (field==='corner' && caps.corner && number>=0 && number<=100) this.applyCorner(number,mode);
    else if (field==='backgroundAlpha' && caps.opacity && number>=0 && number<=100) this.applyBackgroundOpacity_(number,mode);
    else if (field==='borderWidth' && caps.opacity && number>=0 && number<=8) this.applyBorderWidth_(number,mode);
    else if ((field==='globalScale' && number>=50 && number<=200) || (field==='globalOpacity' && number>=10 && number<=100)) this.setOverallStyle_(field,number,mode);
    else if (field==='snap' && (value==='1'||value==='0')) { this.enableWorkbenchSnap_(value==='1'); }
    else if (this.snapEnabled && ((field==='snapGap' && number>=0 && number<=Math.max(100,this.snapGap)) ||
      (field==='snapStrength' && number>=Math.min(2,this.snapStrength) && number<=Math.max(20,this.snapStrength)))) this.setWorkbenchSnap_(field,number,mode);
    else return false;
    return true;
  }

  private enableWorkbenchSnap_(enabled:boolean): void {
    if (this.snapEnabled!==enabled) { this.pushUndo(); this.snapEnabled=enabled; }
  }
  private setWorkbenchSnap_(field:string,value:number,mode:SliderChangeMode): void {
    const v=Math.round(value);const gap=field==='snapGap';
    if(!this.prepareSliderChange(field,mode,(gap?this.snapGap:this.snapStrength)!==v)) return;
    if(gap) this.snapGap=v; else this.snapStrength=v;
  }

  private setOverallStyle_(field:string,value:number,mode:SliderChangeMode): void {
    const scale=field==='globalScale'; const before=scale ? this.globalScale : this.globalOpacity;
    if (!this.prepareSliderChange(field,mode,before!==value/100)) return;
    if (scale) { this.globalScale=value/100; this.globalScaleVal=Math.round(value); }
    else { this.globalOpacity=value/100; this.globalOpacityVal=Math.round(value); }
    this.refreshControls();
  }

  private skillBinding_(item:ControlItem,args:SkillFields): string {
    const field=String(args['field']); const value=String(args['value']); const phase=String(args['phase'] ?? 'press');
    const caps=new ControlEditCapabilities(item,this.selectedChildId.length>0);
    if (field==='scene' && caps.scene && ['game','menu','always'].includes(value)) this.chooseScene_(value as ControlScene);
    else if (field==='visibility' && caps.scene && ['auto','force_show','force_hide'].includes(value)) this.chooseVisibility_(value as VisibilityOverride);
    else if (field==='swipeGroup' && caps.ordinary && ['','1','2','3'].includes(value)) this.chooseSwipeGroup_(value);
    else if (field==='dragLook' && caps.ordinary && (value==='true'||value==='false')) {
      if (!!item.dragLook!==(value==='true')) this.toggleDragLook();
    } else if (field==='trigger' && caps.ordinary && !controlUsesPhases(item) && ['press','toggle','doubleTap','longPress'].includes(value)) this.chooseTrigger_(value as TriggerMode);
    else if (field==='keys' && caps.binding && !controlUsesPhases(item)) {
      const keys=this.skillKeys_(value); if (!keys) return 'failed'; this.applyKeys(keys);
    } else if ((field==='phaseKeys'||field==='groupTargets') && caps.ordinary) {
      if (!['press','longPress','click','doubleClick'].includes(phase)) return 'failed';
      const keys=field==='phaseKeys' ? this.skillKeys_(value) : [];
      const groups=field==='groupTargets' ? layoutList(value,32) : [];
      const operation=String(args['operation'] ?? 'toggle');
      if (!keys || !groups || !['toggle','show','hide'].includes(operation) ||
        !groups.every((id:string):boolean=>!!this.controlGroups?.some((g:ControlGroup):boolean=>g.id===id))) return 'failed';
      if (!controlUsesPhases(item)) { this.requestPhaseConversion_(); return 'needsUser'; }
      this.selectGroupPhase_(phase as ControlActionPhase);
      if (field==='phaseKeys') this.applyPhaseKeys_(keys);
      else {
        const index=Number(args['actionIndex'] ?? -1);
        const actions=item.groupActions ?? [];
        if (!Number.isInteger(index)||index < -1 || index>=actions.length || (index>=0 && actions[index].phase!==phase)) return 'failed';
        this.selectedGroupActionIndex=index;this.groupActionOperation=operation as ControlGroupOperation;this.setPhaseTargets_(groups);
      }
    } else return 'unavailable';
    return 'draft';
  }

  private skillBatch_(args:SkillFields): SkillFields {
    const ids=layoutList(args['controlIds'],128);
    if (!ids || !ids.length || !ids.every((id:string):boolean=>this.controls.some((item:ControlItem):boolean=>item.id===id))) return { 'state':'failed','reason':'invalidControlList' };
    const op=String(args['arrangement']);
    this.setMultiSelect(true); this.selectedIds=ids;
    if (op==='horizontal'||op==='vertical'||op==='auto') this.batchAlign(op==='horizontal'?'h':op==='vertical'?'v':'auto');
    else if (op === 'move') {
      const dx=Number(args['dx']);const dy=Number(args['dy']);
      if (!Number.isFinite(dx) || !Number.isFinite(dy) || Math.abs(dx)>this.screenWidth || Math.abs(dy)>this.screenHeight) return { 'state':'failed','reason':'delta' };
      this.groupDragDx=dx;this.groupDragDy=dy;this.groupDragging=true;this.commitGroupDrag();
    } else if (op === 'style') {
      const target=this.styleTargets()[0];
      if (!target || !['bg','fg','borderColor','scale','opacity','corner','backgroundAlpha','borderWidth'].includes(String(args['field'])) || !this.skillStyle_(target,args)) return { 'state':'failed','reason':'style' };
    }
    else if(op==='space') this.batchEqualSpacing();
    else if(op==='duplicate') this.batchDuplicate();
    else if(op==='lock'||op==='unlock') this.batchSetLocked(op==='lock');
    else if(op==='anchor') {
      const anchor=String(args['anchor']);
      if(ids.length!==1 || !/^[0-2][0-2]$/.test(anchor)) return { 'state':'failed','reason':'anchor' };
      this.setMultiSelect(false);this.selectControlIdentity_(ids[0],false);this.alignSelectedToScreen_(anchor);
    } else if(op==='remove') {
      if (!ids.every((id:string):boolean=>new ControlEditCapabilities(this.controls.find((item:ControlItem):boolean=>item.id===id)!).removable)) return { 'state':'unavailable' };
      this.pendingControlDelete=ids;this.pendingDeleteSignature=JSON.stringify(this.buildProfile());this.pendingDeleteGeneration=this.editorGeneration;
      this.openTab('confirm-delete');return { 'state':'needsUser','surface':'confirmDelete' };
    } else return { 'state':'failed','reason':'arrangement' };
    return this.changedWorkbench_(args);
  }

  private skillGroup_(args:SkillFields): SkillFields {
    const op=String(args['change']); const id=String(args['groupId'] ?? ''); const value=String(args['value'] ?? '');
    if (op==='create' || op==='createSecondary') {
      if (!value.trim() || value.length>64) return { 'state':'failed','reason':'name' };
      if (op==='create') { this.groupNameDraft=value; this.createControlGroup_(); }
      else { this.secondaryNameDraft=value; this.secondaryOpenerDraft=''; this.createSecondary_(); }
    } else {
      const group=this.controlGroups?.find((entry:ControlGroup):boolean=>entry.id===id);
      if (!group) return { 'state':'unavailable','reason':'groupChanged' };
      if (op==='remove') {
        const draft=this.buildProfile();
        if (id===this.defaultControlGroupId || !draft?.controlGroups?.some((g:ControlGroup):boolean=>g.id===id)) return { 'state':'unavailable','reason':'groupChangedOrProtected' };
        return this.beginGroupDeletion_(id) ? { 'state':'needsUser','surface':'groupRemoval','groupId':id } : { 'state':'unavailable','reason':'groupChanged' };
      }
      // 原生显隐组没有展开键、返回键等二级对象。分域前不修改选择，不能落到上一组。
      if (group.secondary!==true && ['addReturn','createOpener','bindOpener','unbindOpener','openerRatio','hideDuringUse','showDuringUse'].includes(op)) {
        return { 'state':'unavailable','reason':'secondaryGroupRequired' };
      }
      this.chooseControlGroup_(id);
      if (op==='rename' && value.trim() && value.length<=64) { this.groupNameDraft=value; this.renameControlGroup_(); }
      else if (op==='showInitially'||op==='hideInitially') this.setGroupInitialVisible_(op==='showInitially');
      else if (op==='raise'||op==='lower') this.moveGroupOrder_(op==='raise'?1:-1);
      else if (op==='duplicate') this.duplicateControlGroup_();
      else {
        if (id===this.defaultControlGroupId) return { 'state':'unavailable','reason':'defaultGroup' };
        if (op==='members') {
          const ids=layoutList(value,128);
          if (!ids || !this.replaceGroupMembers_(id,ids)) return { 'state':'failed','reason':'members' };
          return this.changedWorkbench_(args);
        }
        if (group.secondary!==true) return { 'state':'unavailable','reason':'secondaryGroupRequired' };
        this.openSecondaryEditor_(id);
        if (this.secondaryEditingGroup!==id) return { 'state':'unavailable','reason':'groupChanged' };
        if (op==='addReturn') this.addSecondaryReturn_();
        else if (op==='createOpener') this.createCurrentOpener_();
        else if (op==='bindOpener') {
          if(!this.primarySecondaryCandidates_().some((item:ControlItem):boolean=>item.id===value)) return { 'state':'failed','reason':'invalidOpener' };
          this.bindCurrentSecondary_(value);
        } else if(op==='unbindOpener') this.bindCurrentSecondary_();
        else if(op==='openerRatio' && ['1:1','1:2','2:1'].includes(value)) {
          const opener=this.currentSecondaryOpener_(); if (!opener) return { 'state':'unavailable','reason':'noOpener' };
          this.applySecondaryOpenerRatio_(opener.id,value);
        } else if(op==='hideDuringUse' || op==='showDuringUse') this.toggleSecondaryHide_(op==='hideDuringUse');
        else return { 'state':'failed','reason':'groupAction' };
      }
    }
    return this.changedWorkbench_(args);
  }

  private skillKeys_(value: Object | undefined): number[] | undefined {
    const list=layoutList(value,MAX_LAYOUT_CONTROL_KEYS);
    if (!list) return undefined;
    const keys=list.map((key:string):number=>Number(key));
    const groups=getKeyOptionGroups();
    if(!keys.every((key:number):boolean=>Number.isSafeInteger(key)&&groups.some((group):boolean=>group.options.some((item):boolean=>item.code===key)))) return undefined;
    return keys;
  }

  private editSession: LayoutEditSession = new LayoutEditSession()
  /** 只有游戏宿主能恢复本局组显隐；独立方案编辑不操作运行态。 */
  @Prop canRestoreGroups: boolean = false
  /** 真正编辑流程中的就地提示；保存/取消仍完全走既有事务，不由教学代为修改。 */
  @State private showLeaveConfirm: boolean = false
  private skillLeave_: DraftLeaveDecision | undefined = undefined;
  @State private positionXDraft: string = ''
  @State private positionYDraft: string = ''
  @State private positionWidthDraft: string = ''
  @State private positionHeightDraft: string = ''
  /** 只保存触控设置的导航分区，子组件Link回传选择；不成为另一份触控配置。 */
  /** 只关闭引导观察与提示；不保存、退出编辑器或提前归还编辑器的输入暂停租约。 */
  onDone: (profile: LayoutProfile | null) => void = () => {}
  /** 宿主保留模态租约，只在本编辑器保存/取消真正完成后切到独立设置。 */
  onOpenSettings: (profile: LayoutProfile | null,section: string) => void = (_profile: LayoutProfile | null,_section: string): void => {}
  private nextSettingsSection: string = ''
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
  private groupDeleteReview_: GroupDeleteReview | undefined = undefined
  private keepGroupMembers_: () => void = (): void => {}
  private removeGroupMembers_: () => void = (): void => {}
  private cancelGroupRemoval_: () => void = (): void => {}
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
  /** 子项身份不借父下标；控件列表按ID解析，旧选择不能指向重排后的其他对象。 */
  @State private selectedChildId: string = ''
  @State private allGroups: boolean = false
  @State private controlSearch: string = ''
  @State private positionExpanded: boolean = false
  @State private positionDraftDirty: boolean = false
  @State private previewPressed: boolean = false
  @State private displayAdvanced: boolean = false
  @State private savedPreset: boolean = false
  @State private savedActive: boolean = true
  /** 仅真正保存内容修改时才更新设备标记；纯查看或修改另一域不重写原提示信息。 */
  private originalDeviceModel: string | undefined = undefined
  private sliderGestureKey: string = ''
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
  //   | 'profiles'（方案）| 'multi'（多选批量）
  @State activeSheet: string = 'edit'
  /** 仅存放面板导航，不参与持久JSON；返回恢复实际页面/选择/二级编辑范围。 */
  @State private editorRoutes: CompactEditorRoute[] = []
  @State private secondaryEditingGroup: string = ''
  @State private secondaryNameDraft: string = ''
  @State private secondaryOpenerDraft: string = ''
  @State private secondaryMemberDraft: string[] = []
  @State private colorField: string = ''
  @State private addingButton: boolean = false
  /** 内嵌选择器不遮罩画布；选择改变后废弃旧回调，避免把旧选键写给后来选中的控件。 */
  private inlinePickerGeneration: number = 0
  @State private pendingControlDelete: string[] = []
  private pendingDeleteSignature: string = ''
  private pendingDeleteGeneration: number = 0
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
  @State panelX: number = -1   // 尚未手动拖动时，根据当前画布尺寸选择起点。
  @State panelY: number = -1
  @State panelDragDx: number = 0
  @State panelDragDy: number = 0
  /** 只有明确换边才固定到侧边；自由拖动位置在窗口收缩时夹取，不改写原坐标。 */
  @State private panelDockSide: string = ''

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
      // 新会话从摇杆和上排功能键之间进入；定位由实时窗口推导，首次测量为零时也能恢复。
      this.panelX = -1
      this.panelY = -1
      this.panelDockSide = ''
      this.editorReady = true
      if (this.launcherWorkbench) {
        this.playerDraft_.open();
        LauncherSkillBus.bind('layoutWorkbench',this,(m:string,a:SkillFields):Promise<SkillFields>=>this.skillWorkbench_(m,a),
          ():boolean=>this.editorMounted && !this.editorClosed && this.launcherWorkbench);
      }
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
    if (this.launcherWorkbench) LauncherSkillBus.unbind('layoutWorkbench',this);
    this.editorMounted = false
    this.editorGeneration++
    if (this.editorCleanupTask === undefined) this.editorCleanupTask = this.cleanupDestroyedEditor_()
    this.skillLeave_?.hold(this.editorCleanupTask);
    this.skillLeave_?.dismiss();
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

  /** 错误保留在原状态条；失败不覆盖 控件 等当前草稿，也不触发成功回调。 */
  private reportPersistenceError_(action: string, error: Error): void {
    this.nextSettingsSection=''
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
    this.skillLeave_?.hold(this.persistenceTask);
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
    this.skillLeave_?.dismiss();
    this.completedPlayerLayout_ = profile;
    if (this.launcherWorkbench) this.playerDraft_.complete({ 'state':profile ? 'ready' : 'cancelled',
      'name':profile?.name ?? '', 'layoutId':profile?.profileId ?? '', 'revision':profile?.profileRevision ?? 0 });
    this.editorTransactionOwned = false
    this.releaseEditorLease_()
    try {
      if (this.nextSettingsSection.length>0) this.onOpenSettings(profile,this.nextSettingsSection)
      else this.onDone(profile)
    }
    catch (error) {
      const message: string = '布局结果已确认，但关闭编辑器失败：' + (error as Error).message
      hilog.error(0x0000, 'LayoutEditor', '%{public}s', message)
      if (this.editorMounted) this.statusMsg = message
    }
  }

  /** 保存的 profile 是点击时的完整快照；成功后才提交事务，失败保持草稿和编辑器。 */
  private saveEditor_(): void {
    // 有尚未应用的字段时定位原表单；不让界面显示新值却保存旧控件值。
    const selected: ControlItem | null = this.selectedItem()
    if (this.positionDraftDirty || (selected !== null && new ControlEditCapabilities(selected).label && this.labelDraft !== selected.label)) {
      this.statusMsg = '仍有未应用的名称或位置尺寸，请应用到草稿或放弃输入后保存'
      this.positionExpanded = this.positionDraftDirty; this.openTab('edit'); return
    }
    this.runPersistence_('保存布局', async (generation: number): Promise<void> => {
      const store = getLayoutStore()
      const result: LayoutProfile | null = this.buildProfile()
      if (result === null) throw new Error('布局数据非法，已拒绝保存')
      if (this.contentSignature() !== this.baselineSig) {
        result.targetDevice = store.getCurrentDeviceType() === 'tablet' ? 'tablet' : 'phone'
        result.deviceModel = this.currentDeviceModel()
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

  /** 宽横窗用紧凑检查器，将更多画布留给双手布局；短横屏继续按现有手机规格排布。 */
  private wideToolPanel_(): boolean { return this.screenWidth >= 900 && this.screenHeight >= 400 }

  private panelWidth(): number {
    const ideal: number = this.wideToolPanel_() ? 292 :
      Math.min(268, Math.max(252, Math.round(184 + this.screenWidth * 0.1)))
    return Math.max(1, Math.min(this.screenWidth - 12, ideal))
  }

  /** 手机横屏与平板都保留游戏上下文；临时窄窗和键盘挤压时，仅将分类导航放入正文滚动区。 */
  private compactPanel(): boolean { return this.screenHeight < 260 }

  /** 头部52、操作栏52、常驻分段导航52；极矮视口的导航纳入滚动区域。 */
  private panelChromeH(): number { return this.compactPanel() ? 104 : 156 }

  private panelLeftBase_(): number {
    const right: number = Math.max(6, this.screenWidth - this.panelWidth() - 6)
    if (this.panelDockSide === 'right') return Math.max(6, right - 8)
    if (this.panelDockSide === 'left') return Math.min(14, right)
    if (this.panelX >= 0) return Math.max(6, Math.min(this.panelX, right))
    let initial: number = Math.round(this.screenWidth * (this.screenWidth >= 900 ? 0.205 : 0.18))
    // 游戏按键的百分比表示左上角。按真实缩放后的摇杆右边缘留空间，保留自定义布局的原坐标。
    const stick: ControlItem | undefined = this.controls.find((c: ControlItem): boolean =>
      c.type === ControlType.JOYSTICK && !c.hidden && c.xPct < 0.3)
    if (stick !== undefined) initial = Math.max(initial, this.itemPxX(stick) + this.itemW(stick) + 10)
    return Math.max(6, Math.min(initial, right))
  }

  /** 切换一侧只移动工具窗；按键位置、当前选择、未保存草稿和操作历史均归原编辑会话。 */
  private swapPanelSide_(): void {
    this.panelDockSide = this.panelLeftBase_() + this.panelWidth() / 2 < this.screenWidth / 2 ? 'right' : 'left'
    this.panelDragDx = 0
    this.panelDragDy = 0
  }

  private panelMinContentH(): number { return Math.min(64,Math.max(0,this.screenHeight-this.panelChromeH()-16)) }

  /** 面板顶部允许的最大 y：再往下拖会导致底栏越出屏幕，故到此为止。 */
  private panelMaxTop(): number {
    // 收起时只保留52vp标题；展开后重新按正文与底栏高度裁定显示位置。
    if (this.showPanel === false) return Math.max(0, this.screenHeight - 60)
    const maxTop = this.screenHeight - (this.panelChromeH() + this.panelMinContentH() + 8)
    return maxTop < 0 ? 0 : maxTop
  }
  /** 面板当前（已提交）顶部 y。 */
  private panelTopBase(): number {
    // 初次默认位置和窗口变矮后的已存位置也必须遵守底栏边界，不能只在拖动结束时约束。
    // 保留用户存储的 panelY，只裁定本帧可显示位置；可用高度恢复后仍沿用原定位。
    const requested: number = this.panelY >= 0 ? this.panelY : Math.min(106, Math.round(this.screenHeight * 0.14))
    return Math.max(0, Math.min(requested, this.panelMaxTop()))
  }

  /**
   * 工具面板 Scroll 内容的最大高度。用"实时"顶部（含拖动位移）计算——面板往下移动时内容区随之
   * 收缩、靠滚动阅读，从而**整块面板（含常驻底栏）始终不越出屏幕、底栏永不被截断**。
   */
  private panelContentMaxH(): number {
    const liveTop: number = Math.max(0, Math.min(this.panelMaxTop(), this.panelTopBase() + this.panelDragDy))
    const cap: number = this.wideToolPanel_() ? 428 : this.screenHeight >= 500 ? 500 : 320
    const height: number = Math.min(cap, this.screenHeight - liveTop - 8)
    return Math.max(0, height - this.panelChromeH())
  }

  // ============= 数据加载 / 保存 =============

  // 从 LayoutProfile 对象加载到 @State。恢复路径也先过统一校验，拒绝把坏数据带进编辑状态。
  private loadProfile(p: LayoutProfile, clearUndo: boolean = true): void {
    const normalized = validateAndNormalizeLayout(p)
    if (!normalized) {
      this.statusMsg = '布局数据非法，已拒绝加载'
      return
    }
    this.positionDraftDirty=false; this.labelDraft=''; this.sliderGestureKey=''
    this.controls = normalized.controls.map((c: ControlItem) => cloneControlItem(c))
    this.controlGroups = cloneControlGroups(normalized.controlGroups)
    this.defaultControlGroupId = normalized.defaultControlGroupId
    this.requiredCapabilities = normalized.requiredCapabilities?.slice()
    if (clearUndo) { this.currentControlGroup=''; this.previewControlGroups=[] }
    this.repairEditorGroups_()
    this.globalScale = normalized.globalScale
    this.profileName = normalized.name
    this.originalDeviceModel = normalized.deviceModel
    if (clearUndo) {
      this.savedPreset = normalized.isPreset === true
      this.savedActive = getLayoutStore().getActiveProfile().profileId === normalized.profileId
    }
    this.selectedChildId = ''; this.positionExpanded = false; this.displayAdvanced=false
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
    this.legacyGamepad = normalized.gamepad
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

  // 只透传旧方案的手柄字段，编辑触控布局时保留原值。
  private legacyGamepad: GamepadConfig | undefined = undefined

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
      version: (this.requiredCapabilities?.indexOf(TOUCH_SECONDARY_GROUP_CAPABILITY) ?? -1) >= 0 ? SECONDARY_GROUP_PROFILE_VERSION : this.controlGroups !== undefined ? CONTROL_GROUP_PROFILE_VERSION :
        (this.lookPolicies === undefined ? LAYOUT_PROFILE_VERSION : SOURCE_LOOK_PROFILE_VERSION),
      controlGroups: cloneControlGroups(this.controlGroups),
      defaultControlGroupId: this.defaultControlGroupId,
      requiredCapabilities: this.requiredCapabilities?.slice(),
      profileId: this.editingProfileId,
      profileRevision: this.editingProfileRevision,
      name: this.profileName,
      gamepad: cloneLegacyGamepadConfig(this.legacyGamepad),
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
      isPreset: this.savedPreset,  // 身份保持原目标；Store在保存预设时原子创建用户副本
      // 只读草稿保留原设备提示；真正修改并保存时才由保存事务更新设备标记。
      deviceModel: this.originalDeviceModel,
      hotbarAutoAdded: this.hotbarAutoAdded,
      snapEnabled: this.snapEnabled,
      snapGap: this.snapGap,
      snapStrength: this.snapStrength,
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
    // Begin/Click才证明真实编辑；未开始的Moving/End可能来自程序刷新，不污染合法自定义值。
    if (mode === SliderChangeMode.Begin) this.sliderGestureKey = key
    if (mode !== undefined && mode !== SliderChangeMode.Begin && mode !== SliderChangeMode.Click && this.sliderGestureKey !== key) return false
    if (changed) this.beginSliderUndo(key)
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { this.sliderUndoKey = ''; this.sliderGestureKey = '' }
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
    this.selectControlIdentity_(selected,false)
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
      if (o.hidden || (!this.allGroups && !this.editorGroupVisible_(o))) continue   // 隐藏控件不可见，不作为对齐参考
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
    if (this.selectedChildId.length > 0) return findControlEditTarget(this.controls, this.selectedChildId)?.item ?? null
    if (this.selectedIdx < 0 || this.selectedIdx >= this.controls.length) return null
    return this.controls[this.selectedIdx]
  }

  /** 改键确认 */
  private applyKeys(keys: number[]): void {
    const item = this.selectedItem()
    if (!item) return
    if (controlUsesPhases(item)) { this.openTab('group-actions'); this.statusMsg='此按钮使用分阶段绑定，请选择要修改的阶段'; return }
    // 选择器已即时限制，宿主仍拒绝异常/迟到回调，不能污染草稿后让保存整份失败。
    if (keys.length > MAX_LAYOUT_CONTROL_KEYS) {
      this.statusMsg = '组合键最多支持' + MAX_LAYOUT_CONTROL_KEYS.toString() + '个按键，请减少选择'
      return
    }
    this.pushUndo()
    // 普通键允许解绑；系统聊天必须可用，旧选择器/迟到回调的空值同样解释为恢复默认T。
    const resolved: number[] = item.systemAction === 'input' && keys.length === 0 ? [GLFW_KEY_T] : keys
    item.keys = resolved.slice()
    item.keyOrMouse = resolved.length > 0 ? resolved[0] : 0
    if (item.systemAction === 'input' && keys.length === 0) item.modifiers = 0
    this.refreshControls()
    this.statusMsg = item.systemAction === 'input' && keys.length === 0 ? '已恢复系统聊天默认 T' :
      resolved.length === 0 ? '已解除绑定' : '键位已改为 ' + resolved.map((k: number) => glfwKeyName(k)).join(' + ')
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
    const item: ControlItem | null=this.selectedItem()
    if (item===null) return
    if (!new ControlEditCapabilities(item).removable) { this.statusMsg='系统入口及含系统入口的抽屉不能删除'; return }
    this.removeControls_([item.id])
  }

  /** 复制 */
  private duplicateSelected(): void {
    const item: ControlItem | null=this.selectedItem()
    if (item===null) return
    const ids: string[]=this.duplicateControls_([item])
    if (ids.length>0) this.selectControlIdentity_(ids[0])
  }

  /** 确认后一次创建新键，新增、绑定和初始摆位共同占一个Undo。 */
  private addButton(initialCode?: number, initialKeys?: number[]): void {
    if(initialCode===undefined){this.addingButton=true;this.showKeyPicker=true;return}
    const code: number = initialCode ?? GLFW_KEY_G
    this.pushUndo()
    const id = generateControlId(this.controls)
    const newItem: ControlItem = {
      id,
      controlGroupId: this.controlGroups === undefined ? undefined : this.secondaryEditingGroup || this.currentControlGroup || this.defaultControlGroupId,
      label: '',
      type: ControlType.BUTTON,
      keyOrMouse: code,
      keys: initialKeys?.slice() ?? [code],
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
      grabbedOnly: false,
      hidden: false,
      locked: false,
      // 永不自动隐藏：空数组（非 undefined，避免 migrateProfile 按键码推断成 ['keyboard']）
      hideOnInput: []
    }
    this.placeFreshControl_(newItem)
    this.controls.push(newItem)
    this.selectedChildId = ''; this.selectedIdx = this.controls.length - 1
    this.selectedScaleVal = 100
    this.refreshControls()
    this.statusMsg = initialCode === undefined ? '已添加按键，请选择要绑定的键' :
      '已添加 ' + glfwKeyName(code) + '，可拖动调整位置'
    // 普通入口继续打开改键；常用键已绑定，不弹第二层，保持一次新增对应一次撤销。
    this.syncSelectedAppearanceVals()
    this.showKeyPicker=false;this.syncSecondarySelection_();this.freshControlRoute_()
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
        this.selectedChildId = ''; this.selectedIdx = existing
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
    this.selectedChildId = ''; this.selectedIdx = this.controls.length - 1
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
    if(item.secondaryAction?.kind==='return'&&this.labelDraft.trim().length===0){this.statusMsg='返回一级键需要保留可识别的文字';return}
    if(item.label===this.labelDraft)return
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
    return item.itemScale * 100
  }
  private curOpacityPct(): number {
    const item = this.styleFieldPrimary_('opacity')
    if (!item) return 100
    return effectiveOpacity(item) * 100
  }
  private curCornerPct(): number {
    const item = this.styleFieldPrimary_('corner')
    if (!item) return Math.round(DEFAULT_CORNER_RADIUS * 100)
    return effectiveCornerRadius(item) * 100
  }

  /**
   * 仅格式化界面百分比，去掉0.55乘100产生的浮点尾数；保留导入布局最多两位小数的可读显示。
   * 不改滑条输入、预览值或持久化精度，避免为了修正文案而改写用户的原有比例。
   */
  private percentText_(value: number): string {
    return Number(value.toFixed(2)).toString()+'%'
  }

  /** 统一样式应用：对全部样式目标（单选 1 个 / 多选 N 个）逐个写入，一改全改。 */
  private applyOpacity(opPct: number, mode?: SliderChangeMode): void {
    if (!Number.isFinite(opPct) || opPct<10 || opPct>100) { this.statusMsg='数值超出可保存范围'; return }
    const targets = this.styleTargets().filter((item: ControlItem): boolean => new ControlEditCapabilities(item).opacity)
    if (targets.length === 0) return
    if (!this.prepareSliderChange('styleOpacity', mode,
      targets.some((item: ControlItem): boolean => effectiveOpacity(item) !== opPct / 100))) return
    for (let t of targets) this.ensureStyle(t).opacity = opPct / 100
    this.selectedOpacityVal = Math.round(opPct)
    this.refreshControls()
  }
  private applyCorner(cornerPct: number, mode?: SliderChangeMode): void {
    if (!Number.isFinite(cornerPct) || cornerPct<0 || cornerPct>100) { this.statusMsg='数值超出可保存范围'; return }
    const targets = this.styleTargets().filter((item: ControlItem): boolean => new ControlEditCapabilities(item).corner)
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
    if (!Number.isFinite(sizePct) || sizePct<10 || sizePct>1000) { this.statusMsg='数值超出可保存范围'; return }
    const targets = this.styleTargets().filter((item: ControlItem): boolean => !item.locked)
    if (targets.length === 0) { this.statusMsg = '位置和尺寸已锁定'; return }
    if (!this.prepareSliderChange('styleSize', mode,
      targets.some((item: ControlItem): boolean => item.itemScale !== sizePct / 100))) return
    for (let t of targets) {
      t.itemScale = sizePct / 100
      if (t.type === ControlType.HOTBAR_SELECTOR) t.hotbarUserPlaced = true
    }
    this.selectedScaleVal = Math.round(sizePct)
    this.refreshControls()
  }

  /** 标准尺寸只修改选中可编辑普通按钮的尺寸；不触碰位置、形状、系统项或锁定项。 */
  private unifyAllSizes(): void {
    const targets: ControlItem[] = this.styleTargets().filter((item: ControlItem): boolean =>
      new ControlEditCapabilities(item).ordinary && !item.locked)
    if (targets.length === 0) { this.statusMsg = '没有可修改的普通按钮；系统或锁定项已跳过'; return }
    this.pushUndo()
    for (const item of targets) {
      item.baseWidth = DEFAULT_BUTTON_SIZE; item.baseHeight = DEFAULT_BUTTON_SIZE; item.itemScale = 1
    }
    this.refreshControls()
    this.statusMsg = '已将 ' + targets.length.toString() + ' 个普通按钮设为标准尺寸；位置与外观保持'
  }

  // ============= 渲染 =============

  /** 编辑眼睛开关不进入 buildProfile；载入/撤销后只修正已不存在的选择。 */
  private repairEditorGroups_(): void {
    const groups: ControlGroup[] = this.controlGroups ?? []
    if(this.secondaryEditingGroup.length>0&&!groups.some((group: ControlGroup): boolean=>group.id===this.secondaryEditingGroup&&group.secondary===true)){
      this.secondaryEditingGroup=''
      if(this.activeSheet.startsWith('secondary-'))this.activeSheet='groups'
    }
    if (!groups.some((group: ControlGroup): boolean => group.id === this.currentControlGroup))
      this.currentControlGroup=this.defaultControlGroupId ?? ''
    this.previewControlGroups=this.previewControlGroups.filter((id: string): boolean => groups.some((group: ControlGroup): boolean => group.id === id))
    if (this.currentControlGroup.length > 0 && this.previewControlGroups.indexOf(this.currentControlGroup) < 0)
      this.previewControlGroups=this.previewControlGroups.concat([this.currentControlGroup])
    this.groupNameDraft=groups.find((group: ControlGroup): boolean => group.id === this.currentControlGroup)?.name ?? ''
    this.selectedIds=this.selectedIds.filter((id: string): boolean => findControlEditTarget(this.controls, id) !== undefined)
    if (this.selectedIdx >= this.controls.length) this.selectedIdx=-1
    this.deletingGroup=''
  }

  /** 二级画布使用原全屏坐标，编辑范围与运行mask分开；当前入口保持可选。 */
  private editorGroupVisible_(item: ControlItem): boolean {
    const owner: ControlGroup | undefined=this.controlGroups?.find((group: ControlGroup): boolean=>group.id===item.controlGroupId)
    if(owner?.secondary===true)return owner.id===this.secondaryEditingGroup
    const active: ControlGroup | undefined=this.secondaryEditingDefinition_()
    if(active?.hidePrimary===true)return item.secondaryAction?.kind==='toggle'&&item.secondaryAction.groupId===active.id
    return this.controlGroups===undefined||item.controlGroupId===undefined||item.controlGroupId===this.currentControlGroup||this.previewControlGroups.indexOf(item.controlGroupId)>=0
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
    this.selectControlIdentity_(selected, false)
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
    this.pruneInvisibleSelection_(); this.ver++
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

  /** 普通组和二级组沿各自界面展示确认，动作闭包只属于本次申请。 */
  private beginGroupDeletion_(id: string): boolean {
    const profile=this.buildProfile();
    const group=profile?.controlGroups?.find((entry:ControlGroup):boolean=>entry.id===id);
    if (!this.editorMounted || !profile || !group || id===profile.defaultControlGroupId) return false;
    if (this.deletingGroup && this.groupDeleteReview_) return this.deletingGroup===id &&
      this.groupDeleteReview_.signature===JSON.stringify(profile) && this.groupDeleteReview_.generation===this.editorGeneration;
    const secondary=group.secondary===true;
    this.currentControlGroup=id;
    this.secondaryEditingGroup=secondary?id:'';
    this.openTab(secondary?'secondary-delete':'native-groups');
    const review:GroupDeleteReview={groupId:id,secondary:secondary,generation:this.editorGeneration,signature:JSON.stringify(profile)};
    this.groupDeleteReview_=review;
    this.keepGroupMembers_=():void=>this.deleteControlGroup_(true,review);
    this.removeGroupMembers_=():void=>this.deleteControlGroup_(false,review);
    this.cancelGroupRemoval_=():void=>{if(this.groupDeleteReview_===review)this.clearGroupDeletion_();};
    this.deletingGroup=id;
    return true;
  }

  private clearGroupDeletion_(): void {
    this.groupDeleteReview_=undefined;this.deletingGroup='';
  }

  /** 迟到的旧确认即使正好又选择了同名或同 ID 的组，也不能消费后一次确认。 */
  private deleteControlGroup_(moveMembers:boolean,review:GroupDeleteReview): void {
    const profile=this.buildProfile();
    if (!profile || this.groupDeleteReview_!==review || !this.editorMounted || this.editorGeneration!==review.generation ||
      this.deletingGroup!==review.groupId || this.currentControlGroup!==review.groupId || profile.defaultControlGroupId===review.groupId ||
      this.activeSheet!==(review.secondary?'secondary-delete':'native-groups') ||
      (review.secondary && this.secondaryEditingGroup!==review.groupId) || JSON.stringify(profile)!==review.signature) {
      this.statusMsg='草稿或确认已变化，请重新选择要删除的组';return;
    }
    this.clearGroupDeletion_();
    const updated=removeLayoutControlGroup(profile,review.groupId,moveMembers?profile.defaultControlGroupId:undefined);
    if (this.applyGroupDraft_(updated,moveMembers?'已删除组，普通成员移到默认组':'已删除组及其适用成员')) {
      this.secondaryEditingGroup='';this.currentControlGroup=this.defaultControlGroupId??'';this.selectedIdx=-1;this.selectedChildId='';
      this.editorRoutes=[];this.activeSheet=review.secondary?'groups':'native-groups';
    }
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
    return (this.controlGroups ?? []).filter((group: ControlGroup): boolean => group.secondary!==true && (query.length === 0 || group.name.toLowerCase().indexOf(query) >= 0))
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
    const item: ControlItem | undefined=findControlEditTarget(profile.controls, this.selectedItem()?.id ?? '')?.item
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
    if (!controlUsesPhases(selected)) { this.requestPhaseConversion_(); return }
    const draft: LayoutProfile=enableLayoutControlGroups(current)
    const item: ControlItem | undefined=findControlEditTarget(draft.controls, selected.id)?.item
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
  /** 高亮和保持开关读取同一实际阶段投影，隐式groupActions也保留真实autoKeep。 */
  private currentPhaseAutoKeep_(): boolean {
    const item: ControlItem | null=this.selectedItem()
    return item!==null && (controlEffectivePhases(item).find((binding: ControlPhaseBinding): boolean => binding.phase===this.groupActionPhase)?.autoKeep ?? false)
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
    // 无论接受/拒绝都消耗本次选键身份，取消后的旧控件不能被后来的保持开关借用。
    this.phaseKeyControlId=''
    if (current === null || keys.length > MAX_LAYOUT_CONTROL_KEYS) return
    const original: ControlItem | undefined = findControlEditTarget(current.controls, id)?.item
    if (original === undefined) return
    if (!controlUsesPhases(original)) { this.requestPhaseConversion_(); return }
    if (keys.some((key: number): boolean => !Number.isInteger(key) || !((key >= 32 && key <= 348) || (key >= -8 && key <= -1)))) {
      this.statusMsg = '此键码不能用于阶段按钮，原绑定保持'; return
    }
    const draft: LayoutProfile=enableLayoutControlGroups(current)
    const item: ControlItem | undefined=findControlEditTarget(draft.controls, id)?.item
    if (item === undefined || item.systemAction !== undefined || item.type !== ControlType.BUTTON) return
    const unchanged: ControlPhaseBinding | undefined=controlEffectivePhases(item).find((binding: ControlPhaseBinding): boolean => binding.phase===targetPhase)
    if (unchanged!==undefined && JSON.stringify(unchanged.keys)===JSON.stringify(keys) &&
      (autoKeep===undefined || autoKeep===unchanged.autoKeep)) return
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
        .fontSize(13).fontColor(this.palette.muted).width('100%')
      TextInput({text:this.groupSearch,placeholder:'搜索触控组'}).caretColor(this.palette.accent).height(44).fontSize(14)
        .onChange((value: string): void => { this.groupSearch=value })
      ForEach(this.filteredControlGroups_(), (group: ControlGroup) => {
        Row({space:8}) {
          Button(group.name + ' · ' + ((this.controlGroups ?? []).findIndex((value: ControlGroup): boolean => value.id === group.id)+1) +
            (group.id === this.currentControlGroup ? ' · 当前' : '')).type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(group.id === this.currentControlGroup ? this.palette.surfaceActive : this.palette.surface)
            .fontColor(this.palette.text).onClick((): void => { this.chooseControlGroup_(group.id) })
          Button(this.previewControlGroups.indexOf(group.id) >= 0 ? '画布显示' : '画布隐藏').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12)
            .enabled(group.id !== this.currentControlGroup).onClick((): void => { this.toggleGroupPreview_(group.id) })
        }.width('100%')
      }, (group: ControlGroup): string => group.id)
      if (this.filteredControlGroups_().length === 0) { Text('没有匹配的组；可清空搜索或创建新组').fontColor(this.palette.muted).fontSize(13) }
      TextInput({text:this.groupNameDraft,placeholder:'组名（最多64个字符，可同名）'}).caretColor(this.palette.accent).height(44).fontSize(14).maxLength(64)
        .onChange((value: string): void => { this.groupNameDraft=value })
      Row({space:8}) {
        Button('新建组').type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).onClick((): void => { this.createControlGroup_() })
        Button('重命名').type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).enabled(this.currentGroup_() !== undefined)
          .onClick((): void => { this.renameControlGroup_() })
      }.width('100%')
      if (this.currentGroup_() !== undefined) {
        Row() {
          Text('进入游戏时显示').layoutWeight(1).fontColor(this.palette.text).fontSize(14)
          Toggle({type:ToggleType.Switch,isOn:this.currentGroup_()?.initialVisible ?? true})
            .onChange((value: boolean): void => { this.setGroupInitialVisible_(value) })
        }.width('100%')
        Row({space:8}) {
          Button('下层').type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).onClick((): void => { this.moveGroupOrder_(-1) })
          Button('上层').type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).onClick((): void => { this.moveGroupOrder_(1) })
          Button('复制组').type(ButtonType.Normal).borderRadius(6).layoutWeight(1).height(44).onClick((): void => { this.duplicateControlGroup_() })
        }.width('100%')
        Button('仅查看当前组').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.previewControlGroups=[this.currentControlGroup]; this.ver++ })
        Button('将所选控件移到当前组').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.moveSelectedToGroup_() })
        Button('添加纯组开关按钮').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.addPureGroupButton_() })
        if (this.canRestoreGroups) {
          Button('退出编辑后恢复初始显隐').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => {
            this.onRestoreGroups(); this.statusMsg='已请求恢复；保存或取消退出编辑后生效'
          })
        }
        Button('删除当前组').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').enabled(this.currentControlGroup !== this.defaultControlGroupId)
          .onClick((): void => { this.beginGroupDeletion_(this.currentControlGroup) })
        if (this.currentControlGroup === this.defaultControlGroupId) { Text('默认组负责承接控件，不能删除').fontSize(12).fontColor(this.palette.muted) }
      }
      if (this.deletingGroup.length > 0) {
        Text(this.groupDeletionDescription_()).fontSize(14).fontColor(this.palette.warning).width('100%')
        Button('成员移到默认组后删除').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick(this.keepGroupMembers_)
        Button('连同成员删除').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick(this.removeGroupMembers_)
        Button('取消删除').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick(this.cancelGroupRemoval_)
      }
      Button('返回布局').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.openTab('edit') })
    }.width('100%')
  }

  @Builder
  ControlGroupActionsPanel() {
    Column({space:10}) {
      this.SectionLabel('组动作与分阶段绑定')
      if (!this.selectedIsOrdinaryButton_()) {
        Text('先在画布选择一个普通按钮').fontSize(14).fontColor(this.palette.muted)
      } else if (this.controlGroups === undefined) {
        Text('请先创建触控组；现有方案在此之前保持原格式').fontSize(14).fontColor(this.palette.muted)
        Button('管理触控组').type(ButtonType.Normal).borderRadius(6).height(44).onClick((): void => { this.openTab('groups') })
      } else {
        ForEach(['press','longPress','click','doubleClick'], (phase: string) => {
          Button(this.phaseName_(phase)).type(ButtonType.Normal).borderRadius(6).height(44).width('100%').fontSize(14)
            .backgroundColor(this.groupActionPhase === phase ? this.palette.surfaceActive : this.palette.surface)
            .fontColor(this.palette.text).onClick((): void => { this.selectGroupPhase_(phase as ControlActionPhase) })
        }, (phase: string): string => phase)
        Text('本阶段键：' + (this.currentPhaseKeys_().map((key: number): string => glfwKeyName(key)).join(' + ') || '无（可作为纯组按钮）'))
          .fontSize(14).fontColor(this.palette.text).width('100%')
        Button('修改本阶段按键').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => {
          this.phaseKeyControlId=this.selectedItem()?.id ?? ''; this.phaseKeyPhase=this.groupActionPhase; this.phaseKeyPicker=true
        })
        Row() {
          Text('本阶段按键切换保持').layoutWeight(1).fontSize(14).fontColor(this.palette.text)
          Toggle({type:ToggleType.Switch,isOn:this.currentPhaseAutoKeep_()})
            .onChange((value: boolean): void => { if (value !== this.currentPhaseAutoKeep_()) this.applyPhaseKeys_(this.currentPhaseKeys_(),value) })
        }.width('100%')
        ForEach(this.phaseActionIndices_(), (index: number) => {
          Button(this.groupActionSummary_(index)).type(ButtonType.Normal).borderRadius(6).height(44).width('100%').fontSize(13)
            .backgroundColor(this.selectedGroupActionIndex === index ? this.palette.surfaceActive : this.palette.surface)
            .onClick((): void => { this.selectGroupAction_(index) })
        }, (index: number): string => index.toString() + ':' + this.groupActionSummary_(index))
        Row({space:6}) {
          Button('新增动作').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.selectGroupAction_(-1) })
          Button('上移').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).enabled(this.selectedGroupAction_() !== undefined)
            .onClick((): void => { this.moveGroupAction_(-1) })
          Button('下移').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).enabled(this.selectedGroupAction_() !== undefined)
            .onClick((): void => { this.moveGroupAction_(1) })
        }.width('100%')
        Text(this.selectedGroupAction_() === undefined ? '选择操作，再添加目标以创建新动作' : '编辑选中动作；下列目标按顺序执行')
          .fontSize(12).fontColor(this.palette.muted)
        ForEach(this.phaseTargets_(), (id: string,index: number) => {
          Button((index+1).toString()+' · '+(this.controlGroups?.find((group: ControlGroup): boolean => group.id===id)?.name ?? id)+' ×').type(ButtonType.Normal).borderRadius(6)
            .height(44).width('100%').onClick((): void => { this.removePhaseTarget_(index) })
        }, (id: string,index: number): string => index.toString()+':'+id)
        Row({space:8}) {
          ForEach(['toggle','show','hide'], (operation: string) => {
            Button(operation === 'toggle' ? '切换显示' : operation === 'show' ? '显示' : '隐藏').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).fontSize(13)
              .backgroundColor(this.groupActionOperation === operation ? this.palette.surfaceActive : this.palette.surface)
              .onClick((): void => { this.groupActionOperation=operation as ControlGroupOperation; this.setPhaseTargets_(this.phaseTargets_()) })
          }, (operation: string): string => operation)
        }.width('100%')
        ForEach((this.controlGroups ?? []).filter((group: ControlGroup): boolean=>group.secondary!==true), (group: ControlGroup) => {
          Button('＋ ' + group.name).type(ButtonType.Normal).borderRadius(6).height(44).width('100%').fontSize(14)
            .onClick((): void => { this.togglePhaseTarget_(group.id) })
        }, (group: ControlGroup): string => group.id)
        Button('删除选中动作').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.setPhaseTargets_([]) })
        Text('动作与目标保持原顺序；重复切换保留次数。取消触摸不触发新动作。').fontSize(12).fontColor(this.palette.muted)
      }
      Button('返回布局').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.openTab('edit') })
    }.width('100%')
  }

  build() {
    Stack() {
      // 编辑期间只显示草稿，全部真实输入由宿主模态隔离。
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick(() => { this.selectedIdx = -1; this.selectedChildId = ''; this.selectedScaleVal = 100 })

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
          .stroke(this.palette.accent).strokeWidth(1).strokeDashArray([6, 4])
          .position({ x: 0, y: this.guideY })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.dragIdx >= 0 && this.guideX >= 0) {
        Line()
          .width(1).height(this.screenHeight)
          .startPoint([0, 0]).endPoint([0, this.screenHeight])
          .stroke(this.palette.accent).strokeWidth(1).strokeDashArray([6, 4])
          .position({ x: this.guideX, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 工具面板（可拖动 + 可收起）
      this.ToolPanel()


    }
    .width('100%').height('100%')
    // 正常编辑覆盖层消费自身交互；Native仍由独立模态隔离，不能只依赖ArkUI命中。
    .hitTestBehavior(HitTestMode.Default)
    .enabled(!this.persistenceBusy)
  }

  @Builder
  EditableBtn(item: ControlItem,index: number) {
    Stack() {
      Text(item.type===ControlType.JOYSTICK?'◐':item.type===ControlType.HOTBAR_SELECTOR?'物品栏 ⋯':effectiveLabel(item))
        .width(this.itemW(item)).height(this.itemH(item)).fontSize(this.editBtnFontSize(item)).fontWeight(FontWeight.Medium)
        .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).textAlign(TextAlign.Center)
        .fontColor(item.style?.fg??'#DDFFFFFF').backgroundColor(item.style?.bg??'#30FFFFFF')
        .borderRadius(this.editBtnBorderRadius(item)).border({width:item.type===ControlType.BUTTON?item.style?.borderWidth??0:0,color:item.style?.borderColor??'#DDFFFFFF'})
        .opacity(this.editBtnOpacity(item)).hitTestBehavior(HitTestMode.None)
      Column().width(this.itemW(item)).height(this.itemH(item)).borderRadius(this.editBtnBorderRadius(item))
        .border({width:this.isSel(item,index)?3:item.locked?1:0,color:this.isSel(item,index)?this.palette.accent:this.palette.danger,
          style:this.isSel(item,index)?BorderStyle.Solid:BorderStyle.Dashed}).hitTestBehavior(HitTestMode.None)
      if (this.isSel(item,index)) {
        // 角标与主题外框均为编辑态装饰，不改按键外观草稿或扩大其游戏命中区域。
        Column().width(8).height(8).borderRadius(2).backgroundColor(this.palette.accent)
          .position({x:Math.max(0,this.itemW(item)-8),y:Math.max(0,this.itemH(item)-8)}).hitTestBehavior(HitTestMode.None)
      }
    }.width(this.itemW(item)).height(this.itemH(item))
      .position({
        x: this.itemPxX(item) + this.btnDragOffsetX(item, index),
        y: this.itemPxY(item) + this.btnDragOffsetY(item, index)
      })
      .gesture(
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart(() => {
            if (this.positionDraftDirty) { this.statusMsg='请先应用或放弃位置尺寸输入'; return }
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


  private selectForEditor_(index: number): void {
    if(this.positionDraftDirty){this.statusMsg='请先应用或放弃位置尺寸输入';return}
    if((this.selectedIdx!==index||this.activeSheet!=='edit')&&this.activeSheet!=='confirm-delete'&&this.activeSheet!=='secondary-delete')
      this.editorRoutes=this.editorRoutes.concat([this.captureEditorRoute_()])
    this.pendingControlDelete=[];this.deletingGroup=''
    this.inlinePickerGeneration++;this.showKeyPicker=false;this.phaseKeyPicker=false;this.addingButton=false;this.colorField=''
    this.selectedChildId='';this.selectedIdx=index;this.positionExpanded=false;this.displayAdvanced=false
    this.activeSheet='edit';this.syncSecondarySelection_();this.selectGroupPhase_(this.groupActionPhase);this.syncSelectedAppearanceVals()
    this.showPanel=true
    const item: ControlItem | null=this.selectedItem()
    if(item!==null&&this.screenWidth>this.panelWidth()+this.itemW(item)+32){
      const px: number=this.panelLeftBase_()
      const py: number=this.panelTopBase()
      // 点选会同步换到属性页，此时尚未测出新正文高度。只在该页可达的最大矩形内保守避让。
      if(this.itemPxX(item)<px+this.panelWidth()&&this.itemPxX(item)+this.itemW(item)>px &&
        this.itemPxY(item)<py+this.panelChromeH()+this.panelContentMaxH()&&this.itemPxY(item)+this.itemH(item)>py){
        this.panelDockSide=this.itemCenterX(item)>=this.screenWidth/2?'left':'right'
      }
    }
  }


  // ============= 多选 / 成组拖动 / 批量操作（2026-07-16） =============

  /** 是否处于"选中高亮"（多选态看 selectedIds，单选态看 selectedIdx）。 */
  private isSel(item: ControlItem, index: number): boolean {
    return this.multiSelectMode ? this.selectedIds.includes(item.id) : (this.selectedChildId.length === 0 && this.selectedIdx === index)
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
    this.selectedIds = this.controls.filter((item: ControlItem): boolean => !item.hidden &&
      (this.allGroups || this.editorGroupVisible_(item))).map((item: ControlItem): string => item.id)
    this.statusMsg = (this.allGroups ? '已选择所有组的' : '已选择画布可见的') + this.selectedIds.length.toString() + ' 个控件'
    this.ver++
  }
  private clearSelection(): void {
    this.selectedIds = []
    this.ver++
  }

  /** 当前多选选中的控件列表（按 controls 顺序）。 */
  private multiSelectedItems(): ControlItem[] {
    return controlEditTargets(this.controls).filter((target: ControlEditTarget): boolean =>
      this.selectedIds.indexOf(target.item.id) >= 0).map((target: ControlEditTarget): ControlItem => target.item)
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
    const items = this.geometryTargets_()
    if (items.length < 2) { this.statusMsg = '至少需要 2 个可修改位置的控件；锁定项和子项已跳过'; return }
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
    const items = this.geometryTargets_()
    if (items.length < 2) { this.statusMsg = '至少需要 2 个可修改位置的控件；锁定项和子项已跳过'; return }
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
    const targets: ControlItem[]=this.multiSelectedItems().filter((item: ControlItem): boolean => new ControlEditCapabilities(item).removable)
    if (targets.length===0) { this.statusMsg='没有可删除的选中控件；系统保护项已跳过'; return }
    this.removeControls_(targets.map((item: ControlItem): string => item.id))
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
    this.selectedIds=this.duplicateControls_(this.multiSelectedItems())
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
    let nx = this.panelLeftBase_() + this.panelDragDx
    let ny = this.panelTopBase() + this.panelDragDy
    nx = Math.max(6, Math.min(this.screenWidth-w-6, nx))
    ny = Math.max(0, Math.min(this.panelMaxTop(), ny))
    this.panelDockSide = ''
    this.panelX = nx
    this.panelY = ny
    this.panelDragDx = 0
    this.panelDragDy = 0
  }

  /** 页面切换只改会话导航，不触发保存；同页刷新不压入重复返回项。 */
  private openTab(tab: string): void {
    if (tab!==this.activeSheet && this.groupDeleteReview_) this.clearGroupDeletion_()
    if(tab!==this.activeSheet)this.editorRoutes=this.editorRoutes.concat([this.captureEditorRoute_()])
    this.sliderUndoKey='';this.sliderGestureKey='';this.colorField='';this.activeSheet=tab;this.showPanel=true
    if(tab==='group-actions')this.selectGroupPhase_(this.groupActionPhase)
    if(tab==='position')this.syncPositionDraft_()
    if(tab==='style'&&!this.multiSelectMode)this.labelDraft=this.selectedItem()?.label ?? ''
  }


  /** 摇杆快捷入口明确定位移动分区；只改导航，不写touch草稿、撤销或运行配置。 */


  /** 添加入口只展开目录，不预先创建占位按钮，也不改变原单选/多选和撤销状态。 */
  private openAddPanel_(): void {
    this.openTab('add')
  }

  private returnFromAddPanel_(): void { this.backEditor_() }


  /** 目录条目为明确的有限集合；不提供尚无创建能力的摇杆、触控区或旧抽屉入口。 */
  private addControlOptions_(): EditorAddControlOption[] {
    return [
      { id: 'button', title: '普通按键', description: '绑定键盘键、鼠标键或组合键', search: '普通按钮 按键 button keyboard mouse', icon: AppIconName.Keyboard, common: false },
      { id: 'joystick', title: '移动摇杆', description: '选择已有摇杆，或恢复默认摇杆', search: '', icon: AppIconName.GameController, common: false },
      { id: 'hotbar', title: '物品栏直点条', description: '已存在则选中；再次点按重新对齐', search: '物品栏 快捷栏 hotbar', icon: AppIconName.Hotbar, common: false },
      { id: 'space', title: 'Space', description: '跳跃', search: '空格 space jump 跳跃', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_SPACE },
      { id: 'shift', title: 'Shift', description: '潜行', search: 'shift 潜行 蹲下', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_LEFT_SHIFT },
      { id: 'e', title: 'E', description: '背包', search: 'e 背包 inventory', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_E },
      { id: 'esc', title: 'Esc', description: '游戏菜单', search: 'esc escape 返回 菜单', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_ESCAPE },
      { id: 'f3', title: 'F3', description: '功能键', search: 'f3', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_F3 },
      { id: 'f4', title: 'F4', description: '功能键', search: 'f4', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_F4 },
      { id: 'f5', title: 'F5', description: '功能键', search: 'f5', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_F5 },
      { id: 'tab', title: 'Tab', description: '切换', search: 'tab', icon: AppIconName.Keyboard, common: true, code: GLFW_KEY_TAB }
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
    Text(text).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.muted)
      .width('100%').height(28).margin({ top: 8, bottom: 4 })
  }

  private selectedTitle(): string {
    const item: ControlItem | null=this.selectedItem()
    if(item===null)return ''
    return this.controlTitle_(item)
  }

  /**
   * 画布中的专用控件可以没有文字，管理列表仍须有可读名称；只补界面标题，不写回label或键位。
   * 单键保留用户命名/实际绑定，摇杆、物品栏、滚轮和旧抽屉使用类型名称，空绑定普通键明确说明。
   */
  private controlTitle_(item: ControlItem): string {
    if(item.label.length>0)return item.label
    if(item.type===ControlType.JOYSTICK)return '移动摇杆'
    if(item.type===ControlType.HOTBAR_SELECTOR)return '物品栏'
    if(item.type===ControlType.SCROLL_WHEEL)return '滚轮'
    if(item.type===ControlType.DRAWER)return '抽屉'
    return effectiveLabel(item)||'未绑定按键'
  }


  /** 鼠标由系统提供菜单精细操作；编辑面板只展示可保存的几何/外观属性，避免无效的改键、场景或删除选项。 */
  private selectedIsSystemMouse(): boolean { return this.selectedItem()?.systemAction==='mouse' }

  /** 普通单键立即删除；一级展开键冻结完整范围后在原面板确认，不能只删除可见节点。 */
  private removeControls_(ids: string[]): void {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return
    const permitted: string[]=ids.filter((id: string): boolean=>{
      const item: ControlItem | undefined=findControlEditTarget(profile.controls,id)?.item
      return item!==undefined&&new ControlEditCapabilities(item).removable
    })
    if(permitted.length===0)return
    const plan: SecondaryControlRemoval=secondaryControlRemovalPlan(profile,permitted)
    if(plan.reason.length>0){this.statusMsg=plan.reason;return}
    if(plan.requiresConfirmation){
      this.pendingControlDelete=permitted;this.pendingDeleteSignature=JSON.stringify(profile);this.pendingDeleteGeneration=this.editorGeneration
      this.openTab('confirm-delete');return
    }
    this.applyControlRemoval_(profile,permitted)
  }


  /** 复制子项仍放在原抽屉，顶层复制才有位置偏移；父已选时不重复复制其子树。 */
  private duplicateControls_(items: ControlItem[]): string[] {
    const selected: string[]=items.map((item: ControlItem): string => item.id)
    const targets: ControlEditTarget[]=controlEditTargets(this.controls).filter((target: ControlEditTarget): boolean =>
      selected.indexOf(target.item.id)>=0 && target.item.secondaryAction===undefined && new ControlEditCapabilities(target.item).removable &&
      (target.parent===undefined || (selected.indexOf(target.parent.id)<0 &&
        !(target.parent.children ?? []).some((child: ControlItem): boolean => child.locked === true))))
    if (targets.length===0) { this.statusMsg='没有可复制的对象；系统保护项已跳过'; return [] }
    this.pushUndo(); const ids: string[]=[]
    for (const target of targets) {
      const copy: ControlItem=cloneItemWithFreshIds(target.item,this.controls)
      if (target.parent===undefined) {
        copy.xPct=Math.max(0,Math.min(1-this.itemW(copy)/this.screenWidth,copy.xPct+0.04))
        copy.yPct=Math.max(0,Math.min(1-this.itemH(copy)/this.screenHeight,copy.yPct+0.04)); this.controls.push(copy)
      } else target.parent.children!.push(copy)
      ids.push(copy.id)
    }
    this.refreshControls(); this.statusMsg='已复制 '+ids.length.toString()+' 个对象，锁定与未编辑字段保持'
    return ids
  }

  /** 跨任务前先结束当前草稿；有修改时明确保存，不让设置页加载旧持久内容覆盖草稿。 */
  private requestSettings_(section: string, decision?: DraftLeaveDecision): boolean {
    if (this.persistenceBusy || this.positionDraftDirty) { this.statusMsg='请先应用位置尺寸输入'; return false }
    if (this.skillLeave_?.pending() && decision !== this.skillLeave_) return false;
    const item: ControlItem | null=this.selectedItem()
    if (item!==null && this.labelDraft!==item.label) { this.statusMsg='请先应用名称输入'; return false }
    const generation: number=this.editorGeneration, signature: string=this.contentSignature()
    if (signature===this.baselineSig && !this.sessionCatalogChanged) {
      this.nextSettingsSection=section; this.cancelEditor_(); return false
    }
    const cancel=():void=>{ decision?.dismiss(); };
    this.getUIContext().showAlertDialog({title:'保存布局后前往设置？',message:'将先保存并使用当前操控方案，再编辑同一方案的输入设置。',
      cancel:cancel,primaryButton:{value:'继续编辑',action:cancel},secondaryButton:{value:'保存并前往',action:(): void=>{
        if (!this.editorMounted || generation!==this.editorGeneration || signature!==this.contentSignature() ||
          (decision && (!decision.waiting() || this.skillLeave_!==decision))) { cancel(); return; }
        this.nextSettingsSection=section; this.saveEditor_(); cancel();
      }}})
    return true;
  }

  /** 保存文案与真实Store策略一致，不读取运行期Native状态。 */
  private saveLabel_(): string { return controlProfileSaveLabel(this.savedPreset, this.savedActive) }

  /** 列表与返回按稳定ID选择；当前属于二级组时自动进入它的编辑范围。 */
  private selectControlIdentity_(id: string,navigate: boolean=true): void {
    const target: ControlEditTarget | undefined=findControlEditTarget(this.controls,id)
    if(navigate&&target!==undefined){
      if(this.activeSheet!=='confirm-delete'&&this.activeSheet!=='secondary-delete')this.editorRoutes=this.editorRoutes.concat([this.captureEditorRoute_()])
      this.pendingControlDelete=[];this.deletingGroup='';this.inlinePickerGeneration++
      this.showKeyPicker=false;this.phaseKeyPicker=false;this.addingButton=false;this.colorField=''
    }
    this.selectedChildId=target?.parent===undefined?'':id
    this.selectedIdx=target===undefined?-1:this.controls.findIndex((item: ControlItem): boolean=>item.id===(target.parent?.id??target.item.id))
    this.syncSelectedAppearanceVals();this.syncPositionDraft_();this.positionExpanded=false
    if(navigate&&target!==undefined){this.syncSecondarySelection_();this.activeSheet='edit';this.showPanel=true}
  }


  /** 几何批量基准与目标都排除锁定和自动排布子项；避免仅跳写却仍用其位置改变其他项。 */
  private geometryTargets_(): ControlItem[] {
    return this.multiSelectedItems().filter((item: ControlItem): boolean => !item.locked &&
      findControlEditTarget(this.controls, item.id)?.parent === undefined)
  }

  /** 关闭预览即收缩默认选择范围；明确跨组模式保留用户选择，并持续显示其范围。 */
  private pruneInvisibleSelection_(): void {
    if (this.allGroups) return
    const before: number = this.selectedIds.length
    this.selectedIds = this.selectedIds.filter((id: string): boolean => {
      const target: ControlEditTarget | undefined = findControlEditTarget(this.controls, id)
      return target !== undefined && !target.item.hidden && this.editorGroupVisible_(target.parent ?? target.item)
    })
    if (before !== this.selectedIds.length) this.statusMsg = '已从批量选择移除 ' + (before-this.selectedIds.length).toString() + ' 个不可见控件'
  }

  /** 首次阶段转换冻结完整草稿和目标身份；确认期间发生编辑/销毁就作废，绝不改后来对象。 */
  private requestPhaseConversion_(): void {
    const original: LayoutProfile | null = this.buildProfile(), item: ControlItem | null = this.selectedItem()
    if (original === null || item === null) return
    const issue: string = controlPhaseConversionIssue(item)
    if (issue.length > 0) { this.statusMsg = issue; return }
    const id: string = item.id, signature: string = JSON.stringify(original), generation: number = this.editorGeneration
    this.getUIContext().showAlertDialog({ title: '更换为分阶段动作', message: controlPhaseConversionDescription(item),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '转换草稿', action: (): void => {
        if (!this.editorMounted || generation !== this.editorGeneration || this.selectedItem()?.id !== id ||
          JSON.stringify(this.buildProfile()) !== signature) { this.statusMsg = '草稿已改变，请重新确认转换'; return }
        if (this.applyGroupDraft_(convertControlToPhases(original, id), '已转换草稿；可撤销恢复原触发定义')) this.openTab('group-actions')
      } }
    })
  }

  /** 列表仅过滤显示，所有隐藏/组外/抽屉子项始终保留在原草稿。 */
  private controlListTargets_(): ControlEditTarget[] {
    const query: string = this.controlSearch.trim().toLowerCase()
    return controlEditTargets(this.controls).filter((target: ControlEditTarget): boolean => query.length === 0 ||
      (this.controlTitle_(target.item) + ' ' + target.item.label + ' ' + target.item.id).toLowerCase().includes(query))
  }

  private controlListDetail_(target: ControlEditTarget): string {
    const item: ControlItem = target.item
    const groupId: string | undefined = target.parent?.controlGroupId ?? item.controlGroupId
    const group: string = this.controlGroups?.find((value: ControlGroup): boolean => value.id === groupId)?.name ?? '系统/无组'
    return group + (item.hidden ? ' · 历史隐藏' : item.visibilityOverride === 'force_hide' ? ' · 运行隐藏' : '') +
      (!this.editorGroupVisible_(target.parent ?? item) ? ' · 未预览' : '') + (item.locked ? ' · 位置尺寸锁定' : '') +
      (target.parent === undefined ? '' : ' · 位置由抽屉顺序决定')
  }

  /** 调整抽屉顺序只作用于稳定选中的同父子项，几何由运行投影生成。 */
  private moveChildOrder_(delta: number): void {
    const target: ControlEditTarget | undefined = findControlEditTarget(this.controls, this.selectedChildId)
    const children: ControlItem[] | undefined = target?.parent?.children
    if (children === undefined || target === undefined || target.item.locked) return
    const index: number = children.findIndex((item: ControlItem): boolean => item.id === target.item.id), next: number = index + delta
    if (index < 0 || next < 0 || next >= children.length) return
    if (children[next].locked) { this.statusMsg='相邻子按钮已锁定，不能通过重排移动它'; return }
    this.pushUndo(); const old: ControlItem = children[index]; children[index] = children[next]; children[next] = old
    this.refreshControls(); this.statusMsg = '已调整抽屉子按钮顺序'
  }


  /** 同一属性只对具备实际运行消费者的选中对象开放。 */
  private styleFieldPrimary_(kind: string): ControlItem | null {
    const targets: ControlItem[]=this.styleTargets().filter((item: ControlItem): boolean => {
      const capabilities: ControlEditCapabilities=new ControlEditCapabilities(item)
      return kind==='opacity' ? capabilities.opacity : capabilities.corner
    })
    return targets.length>0 ? targets[targets.length-1] : null
  }

  private styleSupports_(kind: string): boolean {
    return this.styleTargets().some((item: ControlItem): boolean => {
      const capabilities: ControlEditCapabilities = new ControlEditCapabilities(item)
      return kind === 'opacity' ? capabilities.opacity : capabilities.corner
    })
  }

  /** 原绑定与高级阶段共用动作页；首次转换必须显式确认，不因打开面板修改定义。 */
  @Builder
  ActionsTabContent_() {
    Column({space:12}) {
      if (this.selectedItem() === null) { Text('请先选择控件').fontColor(this.palette.muted) }
      else if (this.selectedIsOrdinaryButton_()) {
        Text(this.selectedBindingLabel_()).fontSize(14).fontColor(this.palette.text).width('100%')
        Row() {
          Text('按住时拖动视角').fontSize(14).fontColor(this.palette.text).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.selectedItem()?.dragLook === true}).onChange((v: boolean): void => {
            if (v !== (this.selectedItem()?.dragLook === true)) this.toggleDragLook()
          })
        }.height(48).width('100%')
        if ((this.selectedItem()?.swipeGroup ?? '').length > 0) {
          Text('开启会关闭此键的滑动接力').fontSize(12).fontColor(this.palette.muted).width('100%')
        }
        if (this.selectedUsesPhases_()) { this.ControlGroupActionsPanel() }
        else {
          Button('修改输出绑定').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.showKeyPicker = true })
          Row({space:4}) {
            ForEach(['press','toggle','doubleTap','longPress'],(trigger: string) => {
              Button(this.triggerName_(trigger)).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1)
                .backgroundColor(this.selectedTrigger_() === trigger ? this.palette.surfaceActive : this.palette.surface)
                .fontColor(this.palette.text).onClick((): void => { this.chooseTrigger_(trigger as TriggerMode) })
            },(trigger: string): string => trigger)
          }.width('100%')
          Text('旧双击在第二次按下触发；旧长按保持原移动规则。').fontSize(12).fontColor(this.palette.muted)
          Button('增加触发方式 / 控件组动作').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.requestPhaseConversion_() })
        }
        Text('滑动接力（与拖动视角互斥）').fontSize(13).fontColor(this.palette.muted)
        Row({space:4}) {
          ForEach(['','1','2','3'],(group: string) => {
            Button(group.length === 0 ? '关闭' : '组 '+group).type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1)
              .backgroundColor((this.selectedItem()?.swipeGroup ?? '') === group ? this.palette.surfaceActive : this.palette.surface)
              .fontColor(this.palette.text).onClick((): void => { this.chooseSwipeGroup_(group) })
          },(group: string): string => group)
        }.width('100%')
      } else if (this.selectedItem()?.systemAction === 'input') {
        Text('游戏内先发送聊天绑定再请求聊天输入；菜单只打开文本输入。').fontSize(13).fontColor(this.palette.muted)
        Button('聊天绑定：'+this.selectedBindingLabel_()).type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.showKeyPicker = true })
        Button('恢复默认 T（应用到草稿）').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.applyKeys([84]) })
      } else { Text(this.selectedControlDescription_()).fontSize(14).fontColor(this.palette.muted).width('100%') }
    }.width('100%')
  }

  private selectedUsesPhases_(): boolean { const item: ControlItem | null = this.selectedItem(); return item !== null && controlUsesPhases(item) }

  @Builder
  ControlListPanel_() {
    Column({space:5}) {
      Row(){Text('所有控件').fontSize(14).fontColor(this.palette.text).layoutWeight(1)
        Button('多选').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).onClick(()=>{this.setMultiSelect(true);this.openTab('multi')})}.width('100%')
      TextInput({text:this.controlSearch,placeholder:'搜索名称、键位或ID'}).height(44).fontSize(12).fontColor(this.palette.text).backgroundColor(this.palette.surface)
        .onChange((value: string): void=>{this.controlSearch=value})
      ForEach(this.controlListTargets_(),(target: ControlEditTarget)=>{
        Button(){Column({space:2}){Text((target.parent===undefined?'':'↳ ')+this.controlTitle_(target.item)).fontSize(12).fontColor(this.palette.text).width('100%')
          Text(this.controlListDetail_(target)).fontSize(11).fontColor(this.palette.muted).width('100%')}}.type(ButtonType.Normal).borderRadius(6).width('100%').constraintSize({minHeight:44})
          .padding({top:4,bottom:4,left:1,right:1}).backgroundColor(Color.Transparent).onClick(()=>{
            if(this.multiSelectMode)this.toggleSelectId(target.item.id);else this.selectControlIdentity_(target.item.id)
          })
      },(target: ControlEditTarget): string=>target.item.id+':'+this.ver.toString())
    }.width('100%')
  }


  @Builder
  PanelNavigation() {
    Row({space:4}) {
      Button('按键编辑').type(ButtonType.Normal).borderRadius(8).height(44).fontSize(14).layoutWeight(1)
        .fontColor(this.isGroupPanel_()?this.palette.muted:this.palette.accent)
        .backgroundColor(this.isGroupPanel_()?Color.Transparent:this.palette.surfaceActive).onClick(()=>this.switchMainPanel_(false))
      Button('控件组').type(ButtonType.Normal).borderRadius(8).height(44).fontSize(14).layoutWeight(1)
        .fontColor(this.isGroupPanel_()?this.palette.accent:this.palette.muted)
        .backgroundColor(this.isGroupPanel_()?this.palette.surfaceActive:Color.Transparent).onClick(()=>this.switchMainPanel_(true))
    }.width('100%').height(52).padding({left:8,right:8,top:4,bottom:4})
  }

  /** 唯一浮窗承载导航、选键和确认，不再把键位选择器叠成占屏浮层。 */
  @Builder
  ToolPanel() {
    Column({space:0}) {
      Row({space:4}) {
        if (this.showPanel && this.canBackEditor_()) {
          Button(){AppIcon({name:AppIconName.Back,iconSize:18,color:this.palette.accent})}
            .type(ButtonType.Normal).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
            .accessibilityText('返回').onClick(()=>this.backEditor_())
        } else { AppIcon({name:AppIconName.DragHandle,iconSize:14,color:this.palette.muted}) }
        Column({space:1}) {
          Text(this.secondaryEditingDefinition_()!==undefined?'二级 · '+this.secondaryEditingDefinition_()!.name:'布局编辑')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.palette.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
          Text(this.profileName).fontSize(11).fontColor(this.palette.muted).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(){AppIcon({name:this.panelLeftBase_()+this.panelWidth()/2<this.screenWidth/2?AppIconName.ChevronRight:AppIconName.ChevronLeft,
          iconSize:19,color:this.palette.muted})}.type(ButtonType.Normal).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('将工具窗移至另一侧').id('layout-editor-switch-side').onClick(()=>this.swapPanelSide_())
        Button(){AppIcon({name:this.showPanel?AppIconName.Minus:AppIconName.Plus,iconSize:19,color:this.palette.muted})}
          .type(ButtonType.Normal).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.showPanel?'收起面板':'展开面板').id('layout-editor-toggle-panel').onClick(()=>{this.showPanel=!this.showPanel})
        if (!this.showPanel) {
          Button(){AppIcon({name:AppIconName.Save,iconSize:18,color:this.palette.accent})}
            .type(ButtonType.Normal).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
            .accessibilityText(this.saveLabel_()).onClick(()=>this.saveEditor_())
        }
      }.height(52).width('100%').padding({left:6,right:6})
        .gesture(PanGesture({fingers:1,distance:4}).onActionStart(()=>{this.panelDragDx=0;this.panelDragDy=0})
          .onActionUpdate((event: GestureEvent): void=>{
            const x: number=this.panelLeftBase_()
            this.panelDragDx=Math.max(6-x,Math.min(this.screenWidth-this.panelWidth()-6-x,event.offsetX))
            this.panelDragDy=Math.max(-this.panelTopBase(),Math.min(this.panelMaxTop()-this.panelTopBase(),event.offsetY))
          }).onActionEnd(()=>this.commitPanelDrag()).onActionCancel(()=>this.commitPanelDrag()))
      if(this.showPanel){
        if (!this.compactPanel()) { this.PanelNavigation() }
        if(this.showKeyPicker||this.phaseKeyPicker){
          // 选键器自带局部确认栏。极矮视口滚动整个选键页，让搜索、键位和完成操作都能抵达。
          Scroll() {
            Column() {
              if (this.compactPanel()) { this.PanelNavigation() }
              KeyPickerSheet({palette:this.palette,embedded:true,
                requiredDefaultKey:!this.addingButton&&!this.phaseKeyPicker&&this.selectedItem()?.systemAction==='input'?GLFW_KEY_T:0,
                embeddedHeight:Math.max(240,this.panelContentMaxH()+(this.compactPanel()?0:52)),
                phaseOnly:this.phaseKeyPicker,currentKeys:this.pickerCurrentKeys_(),onPick:this.inlinePickerCallback_()})
            }.width('100%')
          }.width('100%').height(this.panelContentMaxH()+52).align(Alignment.TopStart).scrollBar(BarState.Auto)
        } else {
          Scroll() {
            Column({space:8}) {
              if (this.compactPanel()) { this.PanelNavigation() }
              if(this.statusMsg.length>0){Text(this.statusMsg).fontSize(11).fontColor(this.palette.warning).width('100%').maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis}).id('layout-editor-status')}
              if(this.secondaryEditingDefinition_()!==undefined&&this.activeSheet!=='secondary-group'){
                Row(){Text('当前组内编辑').fontSize(10).fontColor(this.palette.muted).layoutWeight(1)
                  Button('编辑一级').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(()=>this.switchMainPanel_(false))}.width('100%')
              }
              if(this.showLeaveConfirm){this.CompactLeavePanel_()}
              else if(this.activeSheet==='add'){this.AddControlPanel()}
              else if(this.activeSheet==='groups'){this.SecondaryGroupsPanel_()}
              else if(this.activeSheet==='secondary-new'){this.NewSecondaryGroupPanel_()}
              else if(this.activeSheet==='secondary-group'){this.SecondaryWorkspacePanel_()}
              else if(this.activeSheet==='secondary-settings'){this.SecondarySettingsPanel_()}
              else if(this.activeSheet==='secondary-bind'){this.SecondaryBindPanel_()}
              else if(this.activeSheet==='secondary-members'){this.SecondaryMembersPanel_()}
              else if(this.activeSheet==='secondary-delete'){this.SecondaryDeletePanel_()}
              else if(this.activeSheet==='confirm-delete'){this.ConfirmControlDeletePanel_()}
              else if(this.activeSheet==='native-groups'){this.ControlGroupsPanel()}
              else if(this.activeSheet==='more'){this.SelectedMorePanel_()}
              else if(this.activeSheet==='assign-group'){this.AssignGroupPanel_()}
              else if(this.activeSheet==='style'){this.StyleTabContent()}
              else if(this.activeSheet==='position'){this.PositionTabContent()}
              else if(this.activeSheet==='behavior'){this.BehaviorTabContent()}
              else if(this.activeSheet==='group-actions'){this.ActionsTabContent_()}
              else if(this.activeSheet==='alignment'){this.AlignmentOptions()}
              else if(this.activeSheet==='multi'){this.MultiTabContent()}
              else if(this.activeSheet==='list'){this.ControlListPanel_()}
              else if(this.activeSheet==='global'){this.GlobalLayoutPanel_()}
              else {this.EditTabContent()}
            }.width('100%').padding({left:12,right:12,top:4,bottom:8})
          // 平板短页随内容自然收拢，超出上限才滚动；手机维持原固定高度。保存栏始终在正文外。
          }.width('100%').constraintSize({minHeight:this.wideToolPanel_()?0:this.panelContentMaxH(),maxHeight:this.panelContentMaxH()})
            .align(Alignment.TopStart).scrollBar(BarState.Auto).id('layout-editor-tool-content')
          this.ActionFooter()
        }
      }
    }.width(this.panelWidth()).backgroundColor(this.palette.panel).borderRadius(18).border({width:1,color:this.palette.stroke}).clip(true)
      .id('layout-editor-toolbox')
      .position({x:Math.max(6,Math.min(this.screenWidth-this.panelWidth()-6,this.panelLeftBase_()+this.panelDragDx)),
        y:Math.max(0,Math.min(this.panelMaxTop(),this.panelTopBase()+this.panelDragDy))})
  }

  @Builder
  EditTabContent() {
    Column({space:6}) {
      if(this.multiSelectMode){this.MultiTabContent()}
      else if(this.selectedItem()!==null){this.SelectedItemControls()}
      else {
        Text('点选画面上的按键').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
        Text('直接拖动调整位置。拖动标题栏可移开面板。').fontSize(12).fontColor(this.palette.muted).width('100%')
        Row({space:6}) {
          Button('＋ 添加').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).backgroundColor(this.palette.surface).fontColor(this.palette.text).onClick(()=>this.openAddPanel_())
          Button('控件列表').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).backgroundColor(this.palette.surface).fontColor(this.palette.text).onClick(()=>this.openTab('list'))
        }.width('100%')
        CompactEditorRow({palette:this.palette,title:'整体布局',value:this.profileName,onTap:()=>this.openTab('global')})
      }
    }.width('100%')
  }

  @Builder
  AddControlPanel() {
    Column({space:5}) {
      Text(this.secondaryEditingDefinition_()!==undefined?'添加二级按键':'添加按键').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      CompactEditorActionRow({palette:this.palette,icon:AppIconName.Keyboard,title:'绑定按键',
        description:'键盘键、鼠标键或组合键',onTap:()=>this.addControlFromPanel_('button')})
      if(this.secondaryEditingDefinition_()!==undefined){
        CompactEditorActionRow({palette:this.palette,icon:AppIconName.Back,title:'返回一级',
          description:this.currentSecondaryReturn_()===undefined?'可选 · 添加一个返回按键':'已添加 · 点击选中',
          checked:this.currentSecondaryReturn_()!==undefined,onTap:()=>this.addSecondaryReturn_()})
      }
      Text('常用绑定').fontSize(10).fontColor(this.palette.muted).width('100%')
      Flex({wrap:FlexWrap.Wrap}) {
        ForEach(this.addControlOptions_().filter((option: EditorAddControlOption): boolean=>option.common),(option: EditorAddControlOption)=>{
          Button(option.title).type(ButtonType.Normal).borderRadius(6).width('23%').height(44).margin({right:'2%',bottom:4}).fontSize(11).padding(1)
            .backgroundColor(this.palette.surface).fontColor(this.palette.text).borderRadius(5).onClick(()=>this.addControlFromPanel_(option.id))
        },(option: EditorAddControlOption): string=>option.id)
      }.width('100%')
      if(this.secondaryEditingDefinition_()===undefined){
        CompactEditorRow({palette:this.palette,title:'移动摇杆',value:'选择或恢复',onTap:()=>this.addControlFromPanel_('joystick')})
        CompactEditorRow({palette:this.palette,title:'物品栏直点条',value:'选择或恢复',onTap:()=>this.addControlFromPanel_('hotbar')})
      }
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
          AppIcon({ name: AppIconName.Back, iconSize: 18, color: this.palette.text })
          Text('返回布局').fontSize(14).fontColor(this.palette.text)
        }.justifyContent(FlexAlign.Center).width('100%')
      }.type(ButtonType.Normal).borderRadius(6).width('100%').height(48).backgroundColor(this.palette.panel).borderRadius(12)
        .border({ width: 1, color: this.palette.stroke }).id('layout-add-back')
        .onClick((): void => { this.returnFromAddPanel_() })
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  /** 常驻底栏为每个动作保留44vp触点；可用宽度优先给真实保存文案，局部确认沿用各自事务。 */
  @Builder
  ActionFooter() {
    Row({space:2}) {
      if(this.activeSheet==='confirm-delete'){
        Button('取消').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.muted).backgroundColor(Color.Transparent).onClick(()=>this.backEditor_())
        Button('全部删除').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.danger).backgroundColor(this.palette.surface).onClick(()=>this.confirmControlRemoval_())
      } else if(this.activeSheet==='secondary-new'){
        Button('取消').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.backEditor_())
        Button('创建并添加').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(2).backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent)
          .enabled(this.secondaryNameDraft.trim().length>0).onClick(()=>this.createSecondary_())
      } else if(this.activeSheet==='secondary-members'){
        Button('取消').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.backEditor_())
        Button('完成').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent).onClick(()=>this.confirmSecondaryMembers_())
      } else if(this.activeSheet==='position'){
        Button('取消').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.backEditor_())
        Button('应用数值').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent).onClick(()=>this.applyPositionDraft_())
      } else if(this.activeSheet==='secondary-delete'||this.showLeaveConfirm){
        Button('继续编辑').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.backEditor_())
      } else {
        Button(){AppIcon({name:AppIconName.Undo,iconSize:18,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('撤销').enabled(this.canUndo()).onClick(()=>this.undo())
        Button(){AppIcon({name:AppIconName.Plus,iconSize:19,color:this.palette.accent})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('添加按键').onClick(()=>this.openAddPanel_())
        Button('取消').type(ButtonType.Normal).borderRadius(8).height(44).fontSize(13).width(44).padding(0).fontColor(this.palette.muted).backgroundColor(Color.Transparent).onClick(()=>this.requestCancel_())
        Button(this.persistenceBusy?'处理中':this.saveLabel_()).type(ButtonType.Normal).borderRadius(8).height(44).fontSize(12).layoutWeight(1).padding({left:2,right:2})
          .backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent).borderRadius(7).accessibilityText(this.saveLabel_()).onClick(()=>this.saveEditor_())
      }
    }.width('100%').height(52).padding({left:6,right:6,top:4,bottom:4})
  }


  @Builder
  SelectedItemControls() {
    Column({space:4}) {
      Row({space:4}) {
        Text(this.selectedTitle()).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.palette.text).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        Button(){AppIcon({name:AppIconName.Document,iconSize:16,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).onClick(()=>this.openTab('list'))
        Button(){AppIcon({name:AppIconName.More,iconSize:18,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('更多按键设置').onClick(()=>this.openTab('more'))
      }.height(44).width('100%')
      if(this.selectedItem()?.systemAction===undefined){
        Row({space:4}) {
          if(this.selectedItem()?.secondaryAction?.kind==='toggle'){
            Button('解除组绑定').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.muted).backgroundColor(Color.Transparent).onClick(()=>this.unbindSelectedSecondary_())
          } else if(this.selectedItem()?.secondaryAction===undefined&&this.secondaryEditingDefinition_()!==undefined){
            Button('移出本组').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.muted).backgroundColor(Color.Transparent).onClick(()=>this.moveSelectedOutOfSecondary_())
          }
          Button(this.selectedItem()?.secondaryAction?.kind==='toggle'?'删除展开键…':'删除按键').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1)
            .fontColor(this.palette.danger).backgroundColor(Color.Transparent).onClick(()=>this.deleteSelected())
        }.width('100%')
      }
      CompactEditorRow({palette:this.palette,title:this.selectedItem()?.secondaryAction!==undefined?'功能':'绑定',value:this.selectedCompactBinding_(),onTap:()=>this.openSelectedBinding_()})
      Row(){Text('大小').fontSize(12).fontColor(this.palette.muted)
        Slider({value:this.curSizePct(),min:Math.min(50,this.curSizePct()),max:Math.max(200,this.curSizePct()),step:5})
          .height(44).layoutWeight(1).selectedColor(this.palette.accentFill).enabled(!this.selectedIsLocked())
          .onChange((value: number,mode: SliderChangeMode): void=>this.applySize(value,mode))
        Text(this.percentText_(this.curSizePct())).fontSize(11).fontColor(this.palette.text).width(40).textAlign(TextAlign.End)
      }.width('100%')
      if(this.selectedItem()?.secondaryAction?.kind==='toggle'){
        this.SecondaryOpenerRatioPanel_(this.selectedItem()!.id)
      }
      CompactEditorRow({palette:this.palette,title:'外观',value:'',onTap:()=>this.openTab('style')})
      CompactEditorRow({palette:this.palette,title:'位置与尺寸',value:'精确设置',onTap:()=>this.openTab('position')})
      CompactEditorRow({palette:this.palette,title:'所属组',value:this.selectedGroupLabel_(),onTap:()=>this.openSelectedGroup_()})
    }.width('100%')
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

  private sceneLabelText(s: ControlScene): string {
    if (s === 'game') return '游戏中'
    if (s === 'menu') return '菜单'
    return '始终'
  }

  private visibilityLabelText(ov: VisibilityOverride): string {
    if (ov === 'force_show') return '强显'
    if (ov === 'force_hide') return '强隐'
    return '自动'
  }

  private selectedIsLocked(): boolean {
    const item = this.selectedItem()
    return item?.locked === true
  }

  /** 外观控件与原模型能力一致；背景Alpha、整键opacity和真实边框分别修改。 */
  @Builder
  StyleTabContent() {
    Column({space:4}) {
      if(this.styleTargets().length>0){
        if(!this.multiSelectMode&&this.selectedItem()?.systemAction!=='visibility'){
          Row({space:4}){TextInput({text:this.labelDraft,placeholder:'显示文字'}).height(44).fontSize(12).layoutWeight(1).backgroundColor(this.palette.surface).fontColor(this.palette.text)
            .onChange((value: string): void=>{this.labelDraft=value})
            Button('应用').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).onClick(()=>this.applyLabel())}.width('100%')
        }
        if(this.styleSupports_('opacity')){
          Text(this.previewLabel()).width(this.previewWidth_()).height(this.previewHeight_()).fontSize(14).textAlign(TextAlign.Center)
            .fontColor(this.previewItem_()?.style?.fg??'#DDFFFFFF').borderRadius(this.previewCorner())
            .backgroundColor(this.previewPressed?this.previewItem_()?.style?.bgPressed??this.previewItem_()?.style?.bg??'#52FFFFFF':this.previewItem_()?.style?.bg??'#30FFFFFF')
            .border({width:this.previewItem_()?.style?.borderWidth??0,color:this.previewItem_()?.style?.borderColor??'#DDFFFFFF'})
            .opacity(this.curOpacityPct()/100*this.globalOpacity).hitTestBehavior(HitTestMode.None)
          Button(this.previewPressed?'切回常态':'预览按下外观').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.palette.muted).onClick(()=>{this.previewPressed=!this.previewPressed})
        }
        Text('大小 · '+this.percentText_(this.curSizePct())).fontSize(12).fontColor(this.palette.text).width('100%')
        Slider({value:this.curSizePct(),min:Math.min(50,this.curSizePct()),max:Math.max(200,this.curSizePct()),step:5}).height(44).width('100%')
          .selectedColor(this.palette.accentFill).enabled(this.styleTargets().some((item: ControlItem): boolean=>!item.locked)).onChange((v: number,m: SliderChangeMode): void=>this.applySize(v,m))
        if(this.styleSupports_('opacity')){
          Text('整体透明度 · '+this.percentText_(this.curOpacityPct())).fontSize(12).fontColor(this.palette.text).width('100%')
          Slider({value:this.curOpacityPct(),min:Math.min(10,this.curOpacityPct()),max:100,step:1}).height(44).width('100%').selectedColor(this.palette.accentFill)
            .onChange((v: number,m: SliderChangeMode): void=>this.applyOpacity(v,m))
          Text('背景透明度 · '+this.backgroundOpacityPct_().toString()+'%').fontSize(12).fontColor(this.palette.text).width('100%')
          Slider({value:this.backgroundOpacityPct_(),min:0,max:100,step:1}).height(44).width('100%').selectedColor(this.palette.accentFill)
            .onChange((v: number,m: SliderChangeMode): void=>this.applyBackgroundOpacity_(v,m))
          Text('边框粗细 · '+(this.previewItem_()?.style?.borderWidth??0).toString()+' vp').fontSize(12).fontColor(this.palette.text).width('100%')
          Slider({value:this.previewItem_()?.style?.borderWidth??0,min:0,max:Math.max(8,this.previewItem_()?.style?.borderWidth??0),step:0.5}).height(44).width('100%').selectedColor(this.palette.accentFill)
            .onChange((v: number,m: SliderChangeMode): void=>this.applyBorderWidth_(v,m))
          Row({space:4}) {
            ForEach(['bg','fg','borderColor'],(field: string)=>{
              Button(){Row({space:3}){Column().width(12).height(12).borderRadius(3).backgroundColor(controlRgbHex(controlColorParts(this.appearanceFieldColor_(field))))
                Text(field==='bg'?'背景':field==='fg'?'文字':'边框').fontSize(11).fontColor(this.palette.text)}}.type(ButtonType.Normal).borderRadius(6)
                .height(44).layoutWeight(1).backgroundColor(this.colorField===field?this.palette.surfaceActive:this.palette.surface).borderRadius(5)
                .onClick(()=>{this.colorField=this.colorField===field?'':field})
            },(field: string): string=>field)
          }.width('100%')
          if(this.colorField.length>0){ControlColorPicker({palette:this.palette,color:this.appearanceFieldColor_(this.colorField),
            title:this.colorField==='bg'?'背景色':this.colorField==='fg'?'文字色':'边框色',
            onColorChange:(rgb: string,mode: SliderChangeMode): void=>this.applyAppearanceRgb_(rgb,mode),onClose:()=>{this.colorField='' }})}
        }
        if(this.styleSupports_('corner')){
        Text('圆角 · '+this.percentText_(this.curCornerPct())).fontSize(12).fontColor(this.palette.text).width('100%')
          Slider({value:this.curCornerPct(),min:0,max:100,step:5}).height(44).width('100%').selectedColor(this.palette.accentFill).onChange((v: number,m: SliderChangeMode): void=>this.applyCorner(v,m))
          Row({space:4}){Button('方形').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.applyCorner(0))
            Button('圆角').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.applyCorner(30))
            Button('圆形').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.applyCorner(100))}.width('100%')
        }
        CompactEditorRow({palette:this.palette,title:'位置与尺寸',value:'精确设置',onTap:()=>this.openTab('position')})
        if(this.multiSelectMode){Button('普通按键设为标准尺寸').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.unifyAllSizes())}
      }
    }.width('100%')
  }


  /** 外观面板预览方块圆角（px）。 */
  /** 只示意支持按钮外观的对象，按原宽高比缩放；颜色沿ButtonView/DrawerChildView默认合同。 */
  private previewItem_(): ControlItem | null { return this.styleFieldPrimary_('opacity') }
  private previewScale_(): number {
    const item: ControlItem | null=this.previewItem_()
    return item===null ? 1 : Math.min(1,100/Math.max(this.itemW(item),this.itemH(item),1))
  }
  private previewWidth_(): number { const item: ControlItem | null=this.previewItem_(); return item===null ? 1 : this.itemW(item)*this.previewScale_() }
  private previewHeight_(): number { const item: ControlItem | null=this.previewItem_(); return item===null ? 1 : this.itemH(item)*this.previewScale_() }

  private previewCorner(): number {
    const item: ControlItem | null=this.previewItem_()
    return item===null ? 0 : effectiveCornerRadius(item)*Math.min(this.previewWidth_(),this.previewHeight_())/2
  }
  /** 外观面板预览方块内文字：选中按钮的有效标签（含鼠标左/右、字母键自动名）。 */
  private previewLabel(): string {
    const item: ControlItem | null=this.previewItem_()
    return item===null ? '' : effectiveLabel(item)
  }

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
        AppIcon({ name: AppIconName.Copy, iconSize: 16, color: this.palette.accent })
        Text('多选中 · 已选 ' + this.selectedIds.length.toString() + ' 个')
          .fontSize(14).fontColor(this.palette.accent).fontWeight(FontWeight.Medium).layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Button('批量操作').type(ButtonType.Normal).borderRadius(6).fontSize(14).fontColor(this.palette.accent).height(44).layoutWeight(1)
          .backgroundColor(this.palette.surfaceActive).borderRadius(this.palette.radiusSmall)
          .onClick(() => { this.openTab('multi') })
        Button('退出多选').type(ButtonType.Normal).borderRadius(6).fontSize(14).fontColor(this.palette.text).height(44).layoutWeight(1)
          .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
          .onClick(() => { this.setMultiSelect(false) })
      }.width('100%')
    }.width('100%').padding(12).backgroundColor(this.palette.surface)
      .borderRadius(this.palette.radiusSmall).border({ width: 1, color: this.palette.stroke })
  }

  // 多选 Tab 内容：开关 + 批量对齐/等间距/样式/锁定/复制/删除。
  @Builder
  MultiTabContent() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('多选模式').fontSize(14).fontColor(this.palette.text).width('100%')
          Text('点选累积选择，拖动成组移动。').fontSize(12).fontColor(this.palette.muted).width('100%')
        }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.multiSelectMode })
          .selectedColor(this.palette.accentFill).switchPointColor(this.palette.onAccent)
          .onChange((b: boolean) => { this.setMultiSelect(b) })
      }.width('100%').constraintSize({ minHeight: 52 })

      if (this.multiSelectMode) {
        Text('已选择 ' + this.selectedIds.length.toString() + ' 个控件').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.accent).width('100%')
        Row({ space: 8 }) {
          Button(this.allGroups ? '全选所有组' : '全选画布可见').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall).onClick(() => { this.selectAllControls() })
          Button('清空').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall).onClick(() => { this.clearSelection() })
        }.width('100%')

        // 0/1 选择有明确说明；对齐和等距仍由原算法处理，基准固定为选中项平均中心。
        if (this.selectedIds.length === 0) {
          Text('尚未选择控件。点选画面中的按键，或使用“全选”。').fontSize(14).fontColor(this.palette.muted)
            .width('100%').padding(12).backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
        } else if (this.selectedIds.length === 1) {
          Text('再选择至少 1 个控件即可对齐或等间距排列；单个控件仍可改样式、复制或锁定。')
            .fontSize(14).fontColor(this.palette.muted).width('100%').padding(12)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
        }
        this.SectionLabel('对齐')
        Text('基准：选中控件的平均中心。').fontSize(12).fontColor(this.palette.muted).width('100%')
        Row({ space: 6 }) {
          Button('自动对齐').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('auto') })
          Button('水平对齐').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('h') })
          Button('垂直对齐').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length >= 2).onClick(() => { this.batchAlign('v') })
        }.width('100%')
        Button('等间距排列 · 间距 ' + this.snapGap.toString() + ' vp').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).fontColor(this.palette.text)
          .backgroundColor(this.palette.panel).borderRadius(this.palette.radiusSmall).width('100%')
          .border({ width: 1, color: this.palette.stroke }).enabled(this.selectedIds.length >= 2)
          .onClick(() => { this.batchEqualSpacing() })

        this.SectionLabel('批量')
        Row({ space: 8 }) {
          Button('改样式').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.openTab('style') })
          Button('复制').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchDuplicate() })
        }.width('100%')
        Row({ space: 6 }) {
          Button('锁定').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchSetLocked(true) })
          Button('解锁').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.text)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchSetLocked(false) })
          Button('删除').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).layoutWeight(1).fontColor(this.palette.danger)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
            .enabled(this.selectedIds.length > 0).onClick(() => { this.batchDelete() })
        }.width('100%')
        Text('成组拖动跳过锁定项；复制与删除跳过系统按钮。').fontSize(12).fontColor(this.palette.muted).width('100%')
        Button('完成多选').type(ButtonType.Normal).borderRadius(6).fontSize(14).height(44).fontColor(this.palette.onAccent).width('100%')
          .backgroundColor(this.palette.accentFill).borderRadius(this.palette.radiusSmall)
          .onClick((): void => { this.setMultiSelect(false); this.openTab('edit') })
      } else {
        Text('开启后可批量对齐、调整外观、复制、锁定和删除控件。').fontSize(14).fontColor(this.palette.muted)
          .width('100%').padding(12).backgroundColor(this.palette.surface).borderRadius(this.palette.radiusSmall)
      }
    }
    .width('100%')
  }

  /** 一级按任务分组；属性和多选保留原有事务实现，但不再与方案管理挤在一行。 */


  @Builder
  UnifiedTabBar() {
    Row({space:4}) {
      this.TabChip('add','添加'); this.TabChip('multi','多选'); this.TabChip('list','控件'); this.TabChip('alignment','编辑偏好')
    }.height(44).width('100%')
  }

  /** 吸附属于编辑手势设置，与游戏视角无关。 */
  @Builder
  AlignmentOptions() {
    Column({space:12}) {
        Row() { Column({ space: 3 }) { Text('自动对齐').fontSize(14).fontColor(this.palette.text)
          Text('拖动时吸附并显示参考线').fontSize(12).fontColor(this.palette.muted) }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.snapEnabled }).selectedColor(this.palette.accentFill)
            .onChange((value: boolean): void => this.enableWorkbenchSnap_(value))
        }.height(52).width('100%')
        Row() { Text('对齐间距').fontSize(14).fontColor(this.palette.muted).layoutWeight(1)
          Text(this.snapGap.toString() + ' vp' + (this.snapGap > 100 ? ' · 自定义' : '')).fontSize(14).fontColor(this.palette.text) }.width('100%')
        Slider({ value: this.snapGap, min: 0, max: Math.max(100,this.snapGap), step: 1 }).width('100%').height(44).enabled(this.snapEnabled)
          .selectedColor(this.palette.accentFill).blockColor(this.palette.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.setWorkbenchSnap_('snapGap',value,mode)
          })
        Row() { Text('吸附强度').fontSize(14).fontColor(this.palette.muted).layoutWeight(1)
          Text(this.snapStrength.toString() + ' vp' + (this.snapStrength < 2 || this.snapStrength > 20 ? ' · 自定义' : '')).fontSize(14).fontColor(this.palette.text) }.width('100%')
        Slider({ value: this.snapStrength, min: Math.min(2,this.snapStrength), max: Math.max(20,this.snapStrength), step: 1 }).width('100%').height(44).enabled(this.snapEnabled)
          .selectedColor(this.palette.accentFill).blockColor(this.palette.text)
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.setWorkbenchSnap_('snapStrength',value,mode)
          })
        Text('对齐参考屏幕边、同组与其它按钮中心。关闭自动对齐后参数保留并禁用。')
          .fontSize(12).fontColor(this.palette.muted).width('100%')
    }.width('100%')
  }

  @Builder
  TabChip(tab: string, label: string) {
    Text(label).fontSize(14).fontColor(this.activeSheet === tab ? this.palette.accent : this.palette.muted)
      .fontWeight(this.activeSheet === tab ? FontWeight.Medium : FontWeight.Normal)
      .layoutWeight(1).height(44).textAlign(TextAlign.Center).borderRadius(12)
      .backgroundColor(this.activeSheet === tab ? this.palette.surfaceActive : Color.Transparent)
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
    if (controlUsesPhases(item)) {
      const labels: string[] = controlEffectivePhases(item).filter((binding: ControlPhaseBinding): boolean => binding.keys.length > 0)
        .map((binding: ControlPhaseBinding): string => this.phaseName_(binding.phase) + '：' +
          binding.keys.map((key: number): string => glfwKeyName(key)).join(' + ') + (binding.autoKeep ? '（再次触发松开）' : ''))
      return labels.length > 0 ? labels.join('；') : (item.groupActions?.length ?? 0)>0 ? '控件组动作' : '未绑定'
    }
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
    if (controlUsesPhases(item)) { this.statusMsg='此按钮使用分阶段解释，请在动作页调整'; return }
    this.pushUndo(); item.trigger = mode
    if (mode !== 'press') item.swipeGroup = undefined
    this.refreshControls()
  }

  /** 编辑数字只在提交时读取，所有持久化仍使用原xPct/yPct和base尺寸字段。 */
  private syncPositionDraft_(): void {
    this.positionDraftDirty=false
    const item: ControlItem | null=this.selectedItem()
    if (item===null) return
    // 保留完整数值，应用其他字段不能把未编辑的位置/大小取整回写。
    this.positionXDraft=this.itemPxX(item).toString(); this.positionYDraft=this.itemPxY(item).toString()
    this.positionWidthDraft=this.itemW(item).toString(); this.positionHeightDraft=this.itemH(item).toString()
  }

  private applyPositionDraft_(): void {
    const item: ControlItem | null=this.selectedItem()
    if (item===null) return
    if (item.locked) { this.statusMsg='位置与尺寸已锁定，请先解锁'; return }
    const x: number=Number(this.positionXDraft), y: number=Number(this.positionYDraft)
    const width: number=Number(this.positionWidthDraft), height: number=Number(this.positionHeightDraft)
    const scale: number=this.globalScale*item.itemScale
    if ([this.positionXDraft,this.positionYDraft,this.positionWidthDraft,this.positionHeightDraft].some((value: string): boolean => value.trim().length===0) ||
      !Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height) ||
      width/scale<1 || width/scale>4096 || height/scale<1 || height/scale>4096 ||
      (this.selectedChildId.length===0 && (x<0 || y<0 || x>this.screenWidth || y>this.screenHeight))) {
      this.statusMsg='请输入有效数值：位置须在当前视口内，基础宽高须在1至4096范围内'; return
    }
    const sizeChanged: boolean=width!==this.itemW(item) || height!==this.itemH(item)
    const positionChanged: boolean=this.selectedChildId.length===0 && (x!==this.itemPxX(item) || y!==this.itemPxY(item))
    if (!sizeChanged && !positionChanged) { this.positionDraftDirty=false; this.statusMsg='数值未改变'; return }
    this.pushUndo()
    if (width!==this.itemW(item)) item.baseWidth=width/scale
    if (height!==this.itemH(item)) item.baseHeight=height/scale
    if (this.selectedChildId.length===0) {
      if (x!==this.itemPxX(item)) item.xPct=x/Math.max(1,this.screenWidth)
      if (y!==this.itemPxY(item)) item.yPct=y/Math.max(1,this.screenHeight)
    }
    if (item.type===ControlType.HOTBAR_SELECTOR) item.hotbarUserPlaced=true
    this.refreshControls(); this.syncPositionDraft_(); this.statusMsg='位置与尺寸已应用到草稿'
  }

  /** 快速定位是当前视口的一次性编辑，不新增运行时锚点解释或每帧位置计算。 */
  private alignSelectedToScreen_(anchor: string): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || item.locked || this.selectedChildId.length > 0) { this.statusMsg = '请选择可定位且未锁定的顶层控件'; return }
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
    Column({space:12}) {
      if (this.selectedItem() === null) { Text('请先选择控件').fontColor(this.palette.muted) }
      else if (this.selectedItem()?.systemAction !== undefined) {
        Text(this.selectedControlDescription_()).fontSize(14).fontColor(this.palette.text).width('100%')
        Text('系统业务与可达场景固定；已保存的鼠标入口设置保持，不提供会被保存覆盖的选项。')
          .fontSize(13).fontColor(this.palette.muted).width('100%')
      } else {
        this.SectionLabel('何时显示')
        Row({space:4}) {
          ForEach(['game','menu','always'],(scene: string) => {
            Button(this.sceneLabelText(scene as ControlScene)).type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).fontSize(13)
              .backgroundColor(this.selectedScene_() === scene ? this.palette.surfaceActive : this.palette.surface)
              .fontColor(this.palette.text).onClick((): void => { this.chooseScene_(scene as ControlScene) })
          },(scene: string): string => scene)
        }.width('100%')
        this.SectionLabel('显示规则')
        Row({space:4}) {
          ForEach(['auto','force_hide'],(value: string) => {
            Button(this.visibilityLabelText(value as VisibilityOverride)).type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).fontSize(13)
              .backgroundColor(this.selectedVisibility_() === value ? this.palette.surfaceActive : this.palette.surface)
              .fontColor(this.palette.text).onClick((): void => { this.chooseVisibility_(value as VisibilityOverride) })
          },(value: string): string => value)
        }.width('100%')
        Text('当前规则：'+this.visibilityLabelText(this.selectedVisibility_() as VisibilityOverride)).fontSize(13).fontColor(this.palette.accent)
        Button(this.displayAdvanced ? '收起高级显示覆盖' : '高级显示覆盖 ›').type(ButtonType.Normal).borderRadius(6).height(44).width('100%')
          .onClick((): void => { this.displayAdvanced=!this.displayAdvanced })
        if (this.displayAdvanced) {
          Button('强制越过场景和布局档位').type(ButtonType.Normal).borderRadius(6).height(44).width('100%').onClick((): void => { this.chooseVisibility_('force_show') })
        }
        Text('强显只越过场景与布局档位；历史隐藏、组显隐、解绑及专用控件能力仍优先。')
          .fontSize(13).fontColor(this.palette.muted).width('100%')
        if (this.selectedItem()?.hidden) { Button('恢复历史隐藏').type(ButtonType.Normal).borderRadius(6).height(44).onClick((): void => { this.toggleHidden() }) }
      }
    }.width('100%')
  }

  @Builder
  PositionTabContent() {
    Column({space:10}) {
      if (this.selectedItem() !== null) {
        if (this.selectedChildId.length === 0) {
          Row({space:8}) {
            Column({space:4}) {
              Text('横向 X · vp').fontSize(12).fontColor(this.palette.muted)
              TextInput({text:this.positionXDraft}).height(44).width('100%').onChange((v: string): void => {
                if (v !== this.positionXDraft) this.positionDraftDirty = true; this.positionXDraft = v
              })
            }.layoutWeight(1)
            Column({space:4}) {
              Text('纵向 Y · vp').fontSize(12).fontColor(this.palette.muted)
              TextInput({text:this.positionYDraft}).height(44).width('100%').onChange((v: string): void => {
                if (v !== this.positionYDraft) this.positionDraftDirty = true; this.positionYDraft = v
              })
            }.layoutWeight(1)
          }.width('100%')
        } else { Text('位置由父抽屉与子项顺序自动排布，原坐标保留。').fontSize(13).fontColor(this.palette.muted) }
        Row({space:8}) {
          Column({space:4}) {
            Text('宽度 · vp').fontSize(12).fontColor(this.palette.muted)
            TextInput({text:this.positionWidthDraft}).height(44).width('100%').onChange((v: string): void => {
              if (v !== this.positionWidthDraft) this.positionDraftDirty = true; this.positionWidthDraft = v
            })
          }.layoutWeight(1)
          Column({space:4}) {
            Text('高度 · vp').fontSize(12).fontColor(this.palette.muted)
            TextInput({text:this.positionHeightDraft}).height(44).width('100%').onChange((v: string): void => {
              if (v !== this.positionHeightDraft) this.positionDraftDirty = true; this.positionHeightDraft = v
            })
          }.layoutWeight(1)
        }.width('100%')
        Row({space:8}) {
          Button('应用到草稿').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).enabled(!this.selectedIsLocked()).onClick((): void => { this.applyPositionDraft_() })
          Button('放弃数值输入').type(ButtonType.Normal).borderRadius(6).height(44).layoutWeight(1).onClick((): void => { this.syncPositionDraft_() })
        }.width('100%')
        if (this.selectedChildId.length === 0) {
          ForEach(['0','1','2'],(row: string) => {
            Row({space:4}) {
              ForEach(['0','1','2'],(column: string) => {
                Button(this.anchorName_(column+row)).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).enabled(!this.selectedIsLocked())
                  .onClick((): void => { this.alignSelectedToScreen_(column+row) })
              },(column: string): string => column)
            }.width('100%')
          },(row: string): string => row)
        }
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
          Text('保存这次按键调整？').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.palette.text)
          Text('放弃后保留进入前的布局，本次草稿不会写入方案。')
            .fontSize(14).fontColor(this.palette.muted).width('100%')
          Button(this.saveLabel_()).type(ButtonType.Normal).borderRadius(6).height(48).width('100%').fontSize(14).backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false; this.saveEditor_(); this.skillLeave_?.dismiss(); })
          Button('继续编辑').type(ButtonType.Normal).borderRadius(6).height(48).width('100%').fontSize(14).backgroundColor(this.palette.surface).fontColor(this.palette.text)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false; this.skillLeave_?.dismiss(); })
          Button('放弃修改').type(ButtonType.Normal).borderRadius(6).height(48).width('100%').fontSize(14).backgroundColor(Color.Transparent).fontColor(this.palette.danger)
            .borderRadius(12).onClick((): void => { this.showLeaveConfirm = false; this.cancelEditor_(); this.skillLeave_?.dismiss(); })
        }.padding(24).width('100%')
      }.width(Math.min(420, this.screenWidth - 24)).constraintSize({ maxHeight: this.leaveConfirmMaxH_() })
        .align(Alignment.TopStart).scrollBar(BarState.Auto).attributeModifier(new ThemeScrollStyle(this.palette.stroke))
        .backgroundColor(this.palette.panel).borderRadius(20).border({ width: 1, color: this.palette.stroke })
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
    if (item === null || !new ControlEditCapabilities(item).scene || controlScene(item) === scene) return
    this.pushUndo(); setControlScene(item, scene); this.refreshControls()
  }
  private chooseVisibility_(value: VisibilityOverride): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || !new ControlEditCapabilities(item).scene || (item.visibilityOverride ?? 'auto') === value) return
    this.pushUndo(); item.visibilityOverride = value === 'auto' ? undefined : value; this.refreshControls()
  }
  /** 连滑只向原模型写入明确分组；不自动推断相邻按钮，也不改变其它输入来源。 */
  private chooseSwipeGroup_(group: string): void {
    const item: ControlItem | null = this.selectedItem()
    if (item === null || item.type !== ControlType.BUTTON || item.systemAction !== undefined) return
    if (!['', '1', '2', '3'].includes(group)) return
    if ((!controlUsesPhases(item) && (item.trigger ?? 'press') !== 'press') || item.dragLook === true) {
      this.statusMsg = '连滑需要按住触发，并关闭拖动瞄准'; return
    }
    if ((item.swipeGroup ?? '') === group) return
    this.pushUndo(); item.swipeGroup = group.length > 0 ? group : undefined; this.refreshControls()
  }



  /** 返回栈保存导航值快照；对象删除或改组后重新按ID解析，不恢复旧控件对象。 */
  private captureEditorRoute_(): CompactEditorRoute {
    const route: CompactEditorRoute=new CompactEditorRoute()
    route.page=this.activeSheet;route.selectedId=this.selectedItem()?.id??'';route.groupId=this.currentControlGroup
    route.secondaryId=this.secondaryEditingGroup;route.multi=this.multiSelectMode;route.selectedIds=this.selectedIds.slice()
    return route
  }
  private canBackEditor_(): boolean {
    return this.editorRoutes.length>0||this.activeSheet!=='edit'||this.selectedItem()!==null||this.showKeyPicker||this.phaseKeyPicker||this.showLeaveConfirm
  }
  private backEditor_(): void {
    if (this.groupDeleteReview_) this.clearGroupDeletion_()
    if(this.showKeyPicker||this.phaseKeyPicker){this.finishInlineKeyPicker_(null);return}
    if(this.showLeaveConfirm){this.showLeaveConfirm=false;this.skillLeave_?.dismiss();return}
    this.colorField='';this.positionDraftDirty=false;this.pendingControlDelete=[]
    const route: CompactEditorRoute | undefined=this.editorRoutes[this.editorRoutes.length-1]
    if(route===undefined){this.switchMainPanel_(this.activeSheet.startsWith('secondary-')||this.activeSheet==='native-groups');return}
    this.editorRoutes=this.editorRoutes.slice(0,-1);this.activeSheet=route.page
    this.currentControlGroup=route.groupId;this.secondaryEditingGroup=route.secondaryId
    this.multiSelectMode=route.multi;this.selectedIds=route.selectedIds.filter((id: string): boolean=>findControlEditTarget(this.controls,id)!==undefined)
    this.repairEditorGroups_();this.selectControlIdentity_(route.selectedId,false)
    if(this.selectedItem()!==null)this.syncSecondarySelection_()
    this.showPanel=true;this.syncPositionDraft_();this.panelY=Math.max(0,Math.min(this.panelTopBase(),this.panelMaxTop()))
  }
  private switchMainPanel_(groups: boolean): void {
    if (this.groupDeleteReview_) this.clearGroupDeletion_()
    this.inlinePickerGeneration++
    this.editorRoutes=[];this.secondaryEditingGroup='';this.currentControlGroup=this.defaultControlGroupId??''
    this.selectedIdx=-1;this.selectedChildId='';this.multiSelectMode=false;this.selectedIds=[]
    this.showKeyPicker=false;this.phaseKeyPicker=false;this.addingButton=false;this.colorField='';this.showLeaveConfirm=false;this.skillLeave_?.dismiss()
    this.positionDraftDirty=false;this.statusMsg='';this.activeSheet=groups?'groups':'edit';this.repairEditorGroups_()
  }
  private isGroupPanel_(): boolean { return this.activeSheet==='groups'||this.activeSheet==='native-groups'||this.activeSheet.startsWith('secondary-') }
  private secondaryEditingDefinition_(): ControlGroup | undefined {
    return this.controlGroups?.find((group: ControlGroup): boolean=>group.secondary===true&&group.id===this.secondaryEditingGroup)
  }
  private syncSecondarySelection_(): void {
    const item: ControlItem | null=this.selectedItem()
    const group: ControlGroup | undefined=this.controlGroups?.find((value: ControlGroup): boolean=>value.id===item?.controlGroupId&&value.secondary===true)
    this.secondaryEditingGroup=group?.id??''
    if(item!==null)this.currentControlGroup=group?.id??item.controlGroupId??this.defaultControlGroupId??''
    this.repairEditorGroups_()
  }
  private openSecondaryEditor_(id: string,page: string='secondary-group'): void {
    const group: ControlGroup | undefined=this.controlGroups?.find((value: ControlGroup): boolean=>value.id===id&&value.secondary===true)
    if(group===undefined)return
    this.openTab(page);this.currentControlGroup=id;this.secondaryEditingGroup=id
    this.selectedIdx=-1;this.selectedChildId='';this.multiSelectMode=false;this.selectedIds=[];this.chooseControlGroup_(id)
  }
  private groupLabel_(id: string | undefined): string { return this.controlGroups?.find((group: ControlGroup): boolean=>group.id===id)?.name??'未分组' }

  /** 列表直接按稳定组ID查找入口名称；不构建整份草稿，也不改变当前编辑组或选择。 */
  private secondaryOpenerLabel_(groupId: string): string {
    const opener: ControlItem | undefined=this.controls.find((item: ControlItem): boolean=>
      item.secondaryAction?.kind==='toggle'&&item.secondaryAction.groupId===groupId)
    return opener===undefined?'待绑定':this.controlTitle_(opener)
  }
  private selectedCompactBinding_(): string {
    const item: ControlItem | null=this.selectedItem()
    if(item?.secondaryAction!==undefined)return item.secondaryAction.kind==='return'?'返回一级':'展开 '+this.groupLabel_(item.secondaryAction.groupId)
    return this.selectedBindingLabel_()
  }
  private selectedGroupLabel_(): string {
    const item: ControlItem | null=this.selectedItem()
    if(item?.secondaryAction?.kind==='toggle')return '一级展开键'
    if(item?.systemAction==='edit'||item?.systemAction==='visibility')return '系统控件'
    return this.groupLabel_(item?.controlGroupId)
  }
  private openSelectedBinding_(): void {
    const item: ControlItem | null=this.selectedItem();if(item===null)return
    if(item.secondaryAction!==undefined){this.openSecondaryEditor_(item.secondaryAction.groupId);return}
    if(controlUsesPhases(item)){this.openTab('group-actions');return}
    if(new ControlEditCapabilities(item).binding){this.addingButton=false;this.showKeyPicker=true}
    else this.openTab('more')
  }
  private openSelectedGroup_(): void {
    const item: ControlItem | null=this.selectedItem();if(item===null)return
    if(item.secondaryAction!==undefined)this.openSecondaryEditor_(item.secondaryAction.groupId)
    else this.openTab('assign-group')
  }
  private pickerCurrentKeys_(): number[] {
    return this.phaseKeyPicker?this.currentPhaseKeys_():this.addingButton?[]:this.selectedItem()===null?[]:effectiveKeys(this.selectedItem()!).slice()
  }
  /** 选择器取消不生成空占位；新增只在确认时一次创建并记录一个Undo。 */
  private finishInlineKeyPicker_(keys: number[] | null): void {
    this.inlinePickerGeneration++
    const adding: boolean=this.addingButton,phase: boolean=this.phaseKeyPicker
    this.showKeyPicker=false;this.phaseKeyPicker=false;this.addingButton=false
    if(keys===null){this.phaseKeyControlId='';return}
    if(phase){this.applyPhaseKeys_(keys);return}
    if(adding)this.addButton(keys[0]??0,keys)
    else this.applyKeys(keys)
  }
  /** 回调绑定原目标和页面代次。父组件重绘、画布选择或取消不能借后来的选择继续写入。 */
  private inlinePickerCallback_(): (keys: number[] | null)=>void {
    const generation: number=this.inlinePickerGeneration,editor: number=this.editorGeneration
    const target: string=this.phaseKeyPicker?this.phaseKeyControlId:this.addingButton?'':this.selectedItem()?.id??''
    return (keys: number[] | null): void=>{
      if(!this.editorMounted||editor!==this.editorGeneration||generation!==this.inlinePickerGeneration||(!this.showKeyPicker&&!this.phaseKeyPicker))return
      if(target.length>0&&this.selectedItem()?.id!==target)return
      this.finishInlineKeyPicker_(keys)
    }
  }
  private freshControlRoute_(): void {
    const root: CompactEditorRoute=new CompactEditorRoute()
    if(this.secondaryEditingDefinition_()!==undefined){
      root.page='groups';root.groupId=this.defaultControlGroupId??''
      const group: CompactEditorRoute=new CompactEditorRoute();group.page='secondary-group';group.groupId=this.secondaryEditingGroup;group.secondaryId=this.secondaryEditingGroup
      this.editorRoutes=[root,group]
    } else { root.page='edit';root.groupId=this.defaultControlGroupId??'';this.editorRoutes=[root] }
    this.activeSheet='edit';this.showPanel=true
  }
  /** 新控件首次落点避让面板和可见控件，坐标仍直接写全屏百分比；不建立任何父子位置绑定。 */
  private placeFreshControl_(item: ControlItem): void {
    const width: number=this.itemW(item),height: number=this.itemH(item)
    const panelX: number=this.panelLeftBase_()
    // 添加后即切到控件属性页。按即将显示的最大外框留位，浮窗下方仍然可以放新键。
    const panelY: number=this.panelTopBase(), panelHeight: number=this.panelChromeH()+this.panelContentMaxH()
    let bestX: number=8,bestY: number=8,bestScore: number=Number.MAX_VALUE
    const overlap=(x: number,y: number,w: number,h: number,bx: number,by: number,bw: number,bh: number): number=>
      Math.max(0,Math.min(x+w,bx+bw)-Math.max(x,bx))*Math.max(0,Math.min(y+h,by+bh)-Math.max(y,by))
    for(let y: number=8;y+height<=this.screenHeight-8;y+=Math.max(40,height+8)){
      for(let x: number=8;x+width<=this.screenWidth-8;x+=Math.max(44,width+8)){
        let score: number=overlap(x,y,width,height,panelX-8,panelY-8,this.panelWidth()+16,panelHeight+16)*100
        for(const other of this.controls)if(other.id!==item.id&&!other.hidden&&this.editorGroupVisible_(other))
          score+=overlap(x,y,width,height,this.itemPxX(other),this.itemPxY(other),this.itemW(other),this.itemH(other))
        score+=Math.hypot(x-this.screenWidth*0.65,y-this.screenHeight*0.45)*0.01
        if(score<bestScore){bestScore=score;bestX=x;bestY=y}
      }
    }
    item.xPct=bestX/Math.max(1,this.screenWidth);item.yPct=bestY/Math.max(1,this.screenHeight)
  }
  private primarySecondaryCandidates_(): ControlItem[] {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return []
    return profile.controls.filter((item: ControlItem): boolean=>canBindSecondaryGroup(profile,item,this.secondaryEditingGroup))
  }
  private newSecondaryChoices_(): SelectOption[] {
    const choices: SelectOption[]=[{value:'新建同名一级键'}]
    for(const item of this.primarySecondaryCandidates_())choices.push({value:this.controlTitle_(item)})
    return choices
  }
  /** 下拉菜单回调冻结当时的ID顺序；重绘或控件重排不把旧下标解释成另一个按钮。 */
  private newSecondaryChoiceCallback_(): (index: number)=>void {
    const ids: string[]=this.primarySecondaryCandidates_().map((item: ControlItem): string=>item.id)
    return (index: number): void=>{this.secondaryOpenerDraft=index===0?'':ids[index-1]??''}
  }
  private newSecondaryChoiceIndex_(): number {
    return this.secondaryOpenerDraft.length===0?0:this.primarySecondaryCandidates_().findIndex((item: ControlItem): boolean=>item.id===this.secondaryOpenerDraft)+1
  }
  private createSecondary_(): void {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return
    const result: SecondaryGroupEditResult=createSecondaryControlGroup(profile,this.secondaryNameDraft,this.secondaryOpenerDraft||undefined)
    if(result.profile===null){this.statusMsg=result.reason;return}
    if(this.secondaryOpenerDraft.length===0){const opener: ControlItem | undefined=result.profile.controls.find((item: ControlItem): boolean=>item.id===result.controlId);if(opener!==undefined)this.placeFreshControl_(opener)}
    if(!this.applyGroupDraft_(result.profile,'已创建二级组，直接添加按键即可'))return
    this.secondaryEditingGroup=result.groupId;this.currentControlGroup=result.groupId;this.chooseControlGroup_(result.groupId)
    this.selectedIdx=-1;this.selectedChildId='';this.freshControlRoute_();this.activeSheet='add'
  }
  private currentSecondaryReturn_(): ControlItem | undefined {
    return this.controls.find((item: ControlItem): boolean=>item.secondaryAction?.kind==='return'&&item.secondaryAction.groupId===this.secondaryEditingGroup)
  }
  private currentSecondaryOpener_(): ControlItem | undefined {
    return this.controls.find((item: ControlItem): boolean=>item.secondaryAction?.kind==='toggle'&&item.secondaryAction.groupId===this.secondaryEditingGroup)
  }
  private addSecondaryReturn_(): void {
    const existing: ControlItem | undefined=this.currentSecondaryReturn_()
    if(existing!==undefined){this.selectControlIdentity_(existing.id);return}
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return
    const result: SecondaryGroupEditResult=addSecondaryGroupReturn(profile,this.secondaryEditingGroup)
    if(result.profile===null){this.statusMsg=result.reason;return}
    const item: ControlItem | undefined=result.profile.controls.find((value: ControlItem): boolean=>value.id===result.controlId)
    if(item!==undefined)this.placeFreshControl_(item)
    if(this.applyGroupDraft_(result.profile,'已添加返回一级，可任意摆放')){this.selectControlIdentity_(result.controlId,false);this.freshControlRoute_()}
  }
  private bindCurrentSecondary_(id?: string): void {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return
    if(this.applyGroupDraft_(bindSecondaryControlGroup(profile,this.secondaryEditingGroup,id),id===undefined?'已解除绑定，组和按键保留':'已绑定一级展开键'))
      this.activeSheet='secondary-settings'
  }
  /** 未绑定组补建入口也走标准尺寸工厂，再沿原绑定事务提交；不会改动旧入口或成员尺寸。 */
  private createCurrentOpener_(): void {
    const group: ControlGroup | undefined=this.secondaryEditingDefinition_();if(group===undefined)return
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return
    const opener: ControlItem=makeSecondaryGroupOpener(profile,group.name)
    this.placeFreshControl_(opener);profile.controls.push(opener)
    if(this.applyGroupDraft_(bindSecondaryControlGroup(profile,group.id,opener.id),'已添加同名一级展开键'))this.activeSheet='secondary-settings'
  }

  /** 仅顶层、仍绑定有效二级组的展开键可调整比例；旧回调不能误改解绑后的普通按键。 */
  private secondaryOpenerForSizing_(id: string): ControlItem | undefined {
    return this.controls.find((item: ControlItem): boolean=>item.id===id&&item.type===ControlType.BUTTON&&
      item.systemAction===undefined&&item.secondaryAction?.kind==='toggle'&&
      this.controlGroups?.some((group: ControlGroup): boolean=>group.secondary===true&&group.id===item.secondaryAction?.groupId)===true)
  }

  /** 仅高亮实际标准尺寸；历史自定义宽高保持原值，直到用户主动选择比例。 */
  private secondaryOpenerRatio_(id: string): string {
    const item: ControlItem | undefined=this.secondaryOpenerForSizing_(id)
    if(item===undefined)return ''
    if(item.baseWidth===DEFAULT_BUTTON_SIZE&&item.baseHeight===DEFAULT_BUTTON_SIZE)return '1:1'
    if(item.baseWidth===DEFAULT_BUTTON_SIZE&&item.baseHeight===DEFAULT_BUTTON_SIZE*2)return '1:2'
    if(item.baseWidth===DEFAULT_BUTTON_SIZE*2&&item.baseHeight===DEFAULT_BUTTON_SIZE)return '2:1'
    return ''
  }

  /**
   * 比例的1对应普通按键标准边长，只改当前展开键的baseWidth/baseHeight。
   * 保持位置、外观、itemScale、全局倍率和所有二级成员；单次选择共用一项撤销。
   * 同值或失效回调不产生撤销记录，锁定项继续遵守位置与尺寸保护。
   */
  private applySecondaryOpenerRatio_(id: string,ratio: string): void {
    if(ratio!=='1:1'&&ratio!=='1:2'&&ratio!=='2:1')return
    const item: ControlItem | undefined=this.secondaryOpenerForSizing_(id)
    if(item===undefined)return
    if(item.locked){this.statusMsg='位置与尺寸已锁定，请先解锁';return}
    if(this.secondaryOpenerRatio_(id)===ratio)return
    this.pushUndo()
    item.baseWidth=DEFAULT_BUTTON_SIZE*(ratio==='2:1'?2:1)
    item.baseHeight=DEFAULT_BUTTON_SIZE*(ratio==='1:2'?2:1)
    this.refreshControls()
  }
  private unbindSelectedSecondary_(): void {
    const item: ControlItem | null=this.selectedItem(),profile: LayoutProfile | null=this.buildProfile()
    if(profile===null||item?.secondaryAction?.kind!=='toggle')return
    this.applyGroupDraft_(bindSecondaryControlGroup(profile,item.secondaryAction.groupId),'已解除组绑定，原键位恢复，组和成员保留')
  }
  private moveSelectedOutOfSecondary_(): void {
    const item: ControlItem | null=this.selectedItem(),profile: LayoutProfile | null=this.buildProfile()
    if(profile===null||item===null||profile.defaultControlGroupId===undefined)return
    if(this.applyGroupDraft_(moveSecondaryGroupMember(profile,item.id,profile.defaultControlGroupId),'已移回一级，位置和外观保持')){
      this.selectedIdx=-1;this.selectedChildId='';this.activeSheet='secondary-group'
    }
  }
  private toggleSecondaryHide_(value?: boolean): void {
    const profile: LayoutProfile | null=this.buildProfile(),group: ControlGroup | undefined=profile===null?undefined:secondaryControlGroup(profile,this.secondaryEditingGroup)
    if(profile===null||group===undefined)return
    const next: boolean=value??!(group.hidePrimary??false)
    if((group.hidePrimary??false)===next)return
    group.hidePrimary=next;this.applyGroupDraft_(profile,'已更新展开显示方式；当前展开键始终可以再次点击收起')
  }
  private beginSecondaryMembers_(): void {
    this.secondaryMemberDraft=this.controls.filter((item: ControlItem): boolean=>item.controlGroupId===this.secondaryEditingGroup&&item.secondaryAction===undefined).map((item: ControlItem): string=>item.id)
    this.openTab('secondary-members')
  }
  private selectableSecondaryMembers_(): ControlItem[] {
    return this.controls.filter((item: ControlItem): boolean=>item.secondaryAction===undefined&&item.systemAction!=='edit'&&item.systemAction!=='visibility')
  }
  /** 目录的成员集合同时供普通显隐组与二级组编辑器使用，所有目标固定到显式 groupId。 */
  private replaceGroupMembers_(groupId:string,ids:string[]): boolean {
    const profile=this.buildProfile();
    if (!profile || !profile.defaultControlGroupId || groupId===profile.defaultControlGroupId ||
      !profile.controlGroups?.some((g:ControlGroup):boolean=>g.id===groupId) ||
      !ids.every((key:string):boolean=>this.selectableSecondaryMembers_().some((item:ControlItem):boolean=>item.id===key))) return false;
    const assign=(item:ControlItem,id:string):void=>{
      item.controlGroupId=id;
      for(const child of item.children??[]) if(child.controlGroupId!==undefined) assign(child,id);
    };
    for(const item of profile.controls) {
      if(item.secondaryAction!==undefined || item.systemAction==='edit' || item.systemAction==='visibility') continue;
      if(ids.includes(item.id)) assign(item,groupId);
      else if(item.controlGroupId===groupId) assign(item,profile.defaultControlGroupId);
    }
    return this.applyGroupDraft_(profile,'组内成员已更新，全部原坐标保持');
  }

  private confirmSecondaryMembers_(): void {
    if (this.replaceGroupMembers_(this.secondaryEditingGroup,this.secondaryMemberDraft)) this.activeSheet='secondary-group';
  }
  private beginSecondaryDeletion_(id:string=this.secondaryEditingGroup): void {
    if (this.controlGroups?.some((group:ControlGroup):boolean=>group.id===id && group.secondary===true)) this.beginGroupDeletion_(id);
  }
  private confirmControlRemoval_(): void {
    const profile: LayoutProfile | null=this.buildProfile()
    if(profile===null||!this.editorMounted||this.pendingDeleteGeneration!==this.editorGeneration||JSON.stringify(profile)!==this.pendingDeleteSignature){this.statusMsg='草稿已变化，请返回重新选择删除';return}
    this.applyControlRemoval_(profile,this.pendingControlDelete)
  }
  private applyControlRemoval_(profile: LayoutProfile,ids: string[]): void {
    if(!this.applyGroupDraft_(removeSecondaryControls(profile,ids),'已从布局删除，可撤销恢复'))return
    this.pendingControlDelete=[];this.selectedIdx=-1;this.selectedChildId='';this.selectedIds=[];this.multiSelectMode=false;this.editorRoutes=[]
    if(this.secondaryEditingDefinition_()!==undefined)this.activeSheet='secondary-group'
    else {this.secondaryEditingGroup='';this.currentControlGroup=this.defaultControlGroupId??'';this.activeSheet='edit'}
  }
  private pendingDeletionSummary_(): string {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return '草稿不可用，请返回'
    const plan: SecondaryControlRemoval=secondaryControlRemovalPlan(profile,this.pendingControlDelete)
    return (plan.groupIds.length>0?(plan.retainedSystemNames.length>0?'展开键及组内可删除按键会一起删除；系统功能控件保留到一级。':'展开键及其绑定组内的全部按键都会一起删除。'):'所选控件及抽屉内全部子按键都会一起删除。')+
      '共 '+plan.controlIds.length.toString()+' 个控件、'+plan.groupIds.length.toString()+' 个组。'
  }
  /** 单个普通键不确认；复合抽屉和展开键分别说明真实连带范围。 */
  private pendingDeletionTitle_(): string {
    const profile: LayoutProfile | null=this.buildProfile()
    return profile!==null&&secondaryControlRemovalPlan(profile,this.pendingControlDelete).groupIds.length>0?'删除展开键？':'删除控件和子按键？'
  }
  private pendingDeletionMembers_(): string {
    const profile: LayoutProfile | null=this.buildProfile();if(profile===null)return ''
    return secondaryControlRemovalPlan(profile,this.pendingControlDelete).memberNames.slice(0,10).join('、')
  }
  private secondaryMembers_(): ControlItem[] { return this.controls.filter((item: ControlItem): boolean=>item.controlGroupId===this.secondaryEditingGroup) }
  private secondaryGroups_(): ControlGroup[] { return (this.controlGroups??[]).filter((group: ControlGroup): boolean=>group.secondary===true) }

  /** 颜色工具只面向有真实按钮样式消费者的选中项；多选逐项保留各自的非目标颜色和Alpha。 */
  private appearanceFieldColor_(field: string): string {
    const style: ControlStyle | undefined=this.previewItem_()?.style
    return field==='bg'?style?.bg??'#30FFFFFF':field==='fg'?style?.fg??'#DDFFFFFF':style?.borderColor??'#DDFFFFFF'
  }
  private backgroundOpacityPct_(): number { return Math.round(controlColorParts(this.previewItem_()?.style?.bg,'#30FFFFFF').alpha*100) }
  private applyBackgroundOpacity_(value: number,mode: SliderChangeMode): void {
    const targets: ControlItem[]=this.styleTargets().filter((item: ControlItem): boolean=>new ControlEditCapabilities(item).opacity)
    const changed: boolean=targets.some((item: ControlItem): boolean=>controlColorWithAlpha(item.style?.bg,value/100)!==item.style?.bg)
    if(!this.prepareSliderChange('background-alpha',mode,changed))return
    for(const item of targets){const style: ControlStyle=this.ensureStyle(item);style.bg=controlColorWithAlpha(style.bg,value/100)
      if(style.bgPressed!==undefined)style.bgPressed=controlColorWithAlpha(style.bgPressed,value/100,'#52FFFFFF')}
    this.refreshControls()
  }
  private applyBorderWidth_(value: number,mode: SliderChangeMode): void {
    const targets: ControlItem[]=this.styleTargets().filter((item: ControlItem): boolean=>new ControlEditCapabilities(item).opacity)
    if(!this.prepareSliderChange('border-width',mode,targets.some((item: ControlItem): boolean=>(item.style?.borderWidth??0)!==value)))return
    for(const item of targets)this.ensureStyle(item).borderWidth=value
    this.refreshControls()
  }
  private applyAppearanceRgb_(rgb: string,mode: SliderChangeMode): void {
    const field: string=this.colorField;if(field!=='bg'&&field!=='fg'&&field!=='borderColor')return
    const targets: ControlItem[]=this.styleTargets().filter((item: ControlItem): boolean=>new ControlEditCapabilities(item).opacity)
    const changed: boolean=targets.some((item: ControlItem): boolean=>{
      const old: string | undefined=field==='bg'?item.style?.bg:field==='fg'?item.style?.fg:item.style?.borderColor
      return controlColorWithRgb(old,rgb,field==='bg'?'#30FFFFFF':'#DDFFFFFF')!==old
    })
    if(!this.prepareSliderChange('color-'+field,mode,changed))return
    for(const item of targets){
      const style: ControlStyle=this.ensureStyle(item)
      if(field==='bg')style.bg=controlColorWithRgb(style.bg,rgb,'#30FFFFFF')
      else if(field==='fg')style.fg=controlColorWithRgb(style.fg,rgb,'#DDFFFFFF')
      else style.borderColor=controlColorWithRgb(style.borderColor,rgb,'#DDFFFFFF')
    }
    this.refreshControls()
  }

  @Builder
  SecondaryGroupsPanel_() {
    Column({space:5}) {
      Row(){Text('控件组').fontSize(15).fontColor(this.palette.text).layoutWeight(1)
        Button('＋ 二级组').type(ButtonType.Normal).borderRadius(6).fontSize(12).height(44).backgroundColor(Color.Transparent).fontColor(this.palette.accent).onClick(()=>{
          this.secondaryNameDraft='';this.secondaryOpenerDraft='';this.openTab('secondary-new')
        })}.width('100%')
      ForEach(this.secondaryGroups_(),(group: ControlGroup)=>{
        Row({space:4}) {
          Button(){Row({space:7}) {
            AppIcon({name:AppIconName.Layers,iconSize:17,color:this.palette.muted})
            Column({space:2}) {
              Row({space:4}) {
                Text(group.name).fontSize(13).fontColor(this.palette.text).maxLines(1)
                  .textOverflow({overflow:TextOverflow.Ellipsis}).constraintSize({maxWidth:'80%'})
                Text('二级').fontSize(9).fontColor(this.palette.accent).padding({left:4,right:4,top:1,bottom:1})
                  .backgroundColor(this.palette.surfaceActive).borderRadius(3)
              }.width('100%')
              Text(this.controls.filter((item: ControlItem): boolean=>item.controlGroupId===group.id).length.toString()+' 个按键 · '+(group.hidePrimary?'隐藏其他一级':'保留一级'))
                .fontSize(10).fontColor(this.palette.muted).width('100%').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
              Text('入口：'+this.secondaryOpenerLabel_(group.id)).fontSize(10).fontColor(this.palette.muted)
                .width('100%').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({name:AppIconName.ChevronRight,iconSize:13,color:this.palette.muted})
          }.width('100%')}.type(ButtonType.Normal).borderRadius(6).layoutWeight(1).constraintSize({minHeight:54}).backgroundColor(Color.Transparent).padding({left:1,right:1,top:4,bottom:4})
            .onClick(()=>this.openSecondaryEditor_(group.id))
          Button(){AppIcon({name:AppIconName.Trash,iconSize:15,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
            .accessibilityText('删除组 '+group.name).onClick(()=>{this.beginSecondaryDeletion_(group.id)})
        }.width('100%')
      },(group: ControlGroup): string=>group.id+':'+this.ver.toString())
      if(this.secondaryGroups_().length===0){Text('创建一个组，绑定一级展开键后，直接添加二级按键。').fontSize(12).fontColor(this.palette.muted).width('100%')}
      CompactEditorRow({palette:this.palette,title:'原有显隐组',value:'管理与新建',onTap:()=>this.openTab('native-groups')})
    }.width('100%')
  }
  @Builder
  NewSecondaryGroupPanel_() {
    Column({space:7}) {
      Text('新建二级按键组').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      TextInput({text:this.secondaryNameDraft,placeholder:'组名，如 F类键、全键盘'}).height(44).fontSize(12).maxLength(64).backgroundColor(this.palette.surface)
        .fontColor(this.palette.text).onChange((value: string): void=>{this.secondaryNameDraft=value})
      Text('一级展开键').fontSize(11).fontColor(this.palette.muted).width('100%')
      Select(this.newSecondaryChoices_()).selected(this.newSecondaryChoiceIndex_()).value(this.secondaryOpenerDraft.length===0?'新建同名一级键':this.controlTitle_(this.controls.find((item: ControlItem): boolean=>item.id===this.secondaryOpenerDraft)!))
        .width('100%').height(44).font({size:12}).fontColor(this.palette.text).backgroundColor(this.palette.surface)
        .onSelect(this.newSecondaryChoiceCallback_())
      Text('创建后直接添加按键。返回一级键按需添加，不会自动生成。').fontSize(11).fontColor(this.palette.muted).width('100%')
    }.width('100%')
  }
  @Builder
  SecondaryWorkspacePanel_() {
    Column({space:4}) {
      Row({space:3}) {
        Text(this.secondaryMembers_().length.toString()+' 个按键').fontSize(13).fontColor(this.palette.text).layoutWeight(1)
        Button(){AppIcon({name:AppIconName.Settings,iconSize:16,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).onClick(()=>this.openTab('secondary-settings'))
        Button(){AppIcon({name:AppIconName.Trash,iconSize:15,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).onClick(()=>this.beginSecondaryDeletion_())
        Button('编辑一级').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).fontColor(this.palette.accent).backgroundColor(Color.Transparent).padding(1).onClick(()=>this.switchMainPanel_(false))
      }.width('100%')
      if(this.currentSecondaryOpener_()===undefined){Button('未绑定展开键 · 点击绑定').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.openTab('secondary-bind'))}
      Button('＋ 添加按键').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(13).width('100%').backgroundColor(this.palette.surfaceActive).fontColor(this.palette.accent).onClick(()=>this.openAddPanel_())
      ForEach(this.secondaryMembers_(),(item: ControlItem)=>{
        Row({space:3}) {
          Button(this.controlTitle_(item)+'  ›').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.text).backgroundColor(Color.Transparent).padding(1).onClick(()=>this.selectControlIdentity_(item.id))
          Button(){AppIcon({name:AppIconName.Trash,iconSize:15,color:this.palette.muted})}.type(ButtonType.Normal).borderRadius(6).width(44).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('删除 '+this.controlTitle_(item)).onClick(()=>this.removeControls_([item.id]))
        }.width('100%')
      },(item: ControlItem): string=>item.id+':'+this.ver.toString())
      Row(){Button('从已有布局加入').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(()=>this.beginSecondaryMembers_())
        Button('多选').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).fontColor(this.palette.muted).backgroundColor(Color.Transparent).onClick(()=>{
          this.multiSelectMode=true;this.selectedIds=this.secondaryMembers_().map((item: ControlItem): string=>item.id);this.openTab('multi')
        })}.width('100%')
    }.width('100%')
  }
  /** 选中展开键和组设置共用一行比例选择；标明宽高方向，保持小圆角与原面板宽度。 */
  @Builder
  SecondaryOpenerRatioPanel_(controlId: string) {
    Column({space:3}) {
      Text('宽:高 · 跟随整体缩放').fontSize(11).fontColor(this.palette.muted).width('100%')
      Row({space:4}) {
        ForEach(['1:1','1:2','2:1'],(ratio: string)=>{
          Button(ratio+(ratio==='1:1'?' 方形':ratio==='1:2'?' 竖向':' 横向')).type(ButtonType.Normal).borderRadius(6)
            .height(44).fontSize(12).padding(2).layoutWeight(1)
            .fontColor(this.secondaryOpenerRatio_(controlId)===ratio?this.palette.accent:this.palette.text)
            .backgroundColor(this.secondaryOpenerRatio_(controlId)===ratio?this.palette.surfaceActive:this.palette.surface)
            .enabled(this.secondaryOpenerForSizing_(controlId)!==undefined&&this.secondaryOpenerForSizing_(controlId)?.locked!==true)
            .accessibilityText('一级展开键宽高比 '+ratio+(this.secondaryOpenerRatio_(controlId)===ratio?'，已选':''))
            .id('secondary-opener-ratio-'+ratio.replace(':','x'))
            .onClick(()=>this.applySecondaryOpenerRatio_(controlId,ratio))
        },(ratio: string): string=>controlId+':'+ratio+':'+this.ver.toString())
      }.width('100%')
    }.width('100%')
  }

  @Builder
  SecondarySettingsPanel_() {
    Column({space:5}) {
      Text('组设置').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      Row({space:4}){TextInput({text:this.groupNameDraft}).height(44).fontSize(12).layoutWeight(1).maxLength(64).fontColor(this.palette.text).backgroundColor(this.palette.surface).onChange((value: string): void=>{this.groupNameDraft=value})
        Button('应用').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).onClick(()=>this.renameControlGroup_())}.width('100%')
      CompactEditorRow({palette:this.palette,title:'一级展开键',value:this.currentSecondaryOpener_()===undefined?'未绑定':effectiveLabel(this.currentSecondaryOpener_()!),onTap:()=>this.openTab('secondary-bind')})
      if(this.currentSecondaryOpener_()!==undefined){this.SecondaryOpenerRatioPanel_(this.currentSecondaryOpener_()!.id)}
      if(this.currentSecondaryOpener_()!==undefined){Button('解除展开键绑定').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.bindCurrentSecondary_())}
      Row({space:4}){Column({space:2}){Text('展开时隐藏其他一级').fontSize(12).fontColor(this.palette.text)
        Text('保留当前展开键，再点一次收起').fontSize(10).fontColor(this.palette.muted)}.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({type:ToggleType.Switch,isOn:this.secondaryEditingDefinition_()?.hidePrimary??false}).onChange((value: boolean): void=>this.toggleSecondaryHide_(value))}.width('100%').height(44)
      CompactEditorRow({palette:this.palette,title:'返回一级键',value:this.currentSecondaryReturn_()===undefined?'未添加 · 可选':'已添加',onTap:()=>this.currentSecondaryReturn_()===undefined?this.openAddPanel_():this.selectControlIdentity_(this.currentSecondaryReturn_()!.id)})
      Button('删除整个组…').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.danger).backgroundColor(this.palette.surface).onClick(()=>this.beginSecondaryDeletion_())
    }.width('100%')
  }
  @Builder
  SecondaryBindPanel_() {
    Column({space:4}) {
      Button('＋ 新建同名一级展开键').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.accent).onClick(()=>this.createCurrentOpener_())
      ForEach(this.primarySecondaryCandidates_(),(item: ControlItem)=>{
        Button(this.controlTitle_(item)).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').backgroundColor(this.palette.surface).fontColor(this.palette.text).onClick(()=>this.bindCurrentSecondary_(item.id))
      },(item: ControlItem): string=>item.id)
    }.width('100%')
  }
  @Builder
  SecondaryMembersPanel_() {
    Column({space:3}) {
      Text('加入后保留原屏幕位置').fontSize(11).fontColor(this.palette.muted).width('100%')
      ForEach(this.selectableSecondaryMembers_(),(item: ControlItem)=>{
        Button((this.secondaryMemberDraft.indexOf(item.id)>=0?'✓  ':'□  ')+this.controlTitle_(item)).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%')
          .backgroundColor(this.secondaryMemberDraft.indexOf(item.id)>=0?this.palette.surfaceActive:this.palette.surface).fontColor(this.palette.text).onClick(()=>{
            this.secondaryMemberDraft=this.secondaryMemberDraft.indexOf(item.id)>=0?this.secondaryMemberDraft.filter((id: string): boolean=>id!==item.id):this.secondaryMemberDraft.concat([item.id])
          })
      },(item: ControlItem): string=>item.id)
    }.width('100%')
  }
  @Builder
  SecondaryDeletePanel_() {
    Column({space:8}) {
      Text('删除“'+this.groupLabel_(this.deletingGroup)+'”').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      Text('主按键和组会一起删除。请选择如何处理二级成员；返回键随组删除。').fontSize(12).fontColor(this.palette.muted).width('100%')
      if(this.secondaryMembers_().some((item: ControlItem): boolean=>!new ControlEditCapabilities(item).removable)){
        Text('含系统功能的控件会保留到一级，原配置不变。').fontSize(11).fontColor(this.palette.muted).width('100%')
      }
      Button('删除主按键和组 · 成员回一级').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.accent).backgroundColor(this.palette.surfaceActive).onClick(this.keepGroupMembers_)
      Button('删除主按键、组和全部成员').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.danger).backgroundColor(this.palette.surface).onClick(this.removeGroupMembers_)
    }.width('100%')
  }
  @Builder
  ConfirmControlDeletePanel_() {
    Column({space:8}) {
      Text(this.pendingDeletionTitle_()).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      Text(this.pendingDeletionSummary_()).fontSize(12).fontColor(this.palette.text).width('100%')
      Text(this.pendingDeletionMembers_()).fontSize(11).fontColor(this.palette.muted).width('100%')
      Text('控件列表同步移除，保存前可撤销。').fontSize(11).fontColor(this.palette.muted).width('100%')
    }.width('100%')
  }
  @Builder
  CompactLeavePanel_() {
    Column({space:8}) {
      Text('保存这次调整？').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.palette.text).width('100%')
      Button(this.saveLabel_()).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent).onClick(()=>this.saveEditor_())
      Button('放弃修改').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.danger).onClick(()=>this.cancelEditor_())
    }.width('100%')
  }
  @Builder
  SelectedMorePanel_() {
    Column({space:4}) {
      CompactEditorRow({palette:this.palette,title:'外观与位置',value:'颜色、透明、边框',onTap:()=>this.openTab('style')})
      if(this.selectedItem()?.secondaryAction===undefined&&this.selectedItem()?.type===ControlType.BUTTON){
        // 动作配置从更多进入，普通按键的绑定行继续直接打开选键器。
        if (this.selectedIsOrdinaryButton_()) {
          CompactEditorRow({palette:this.palette,title:'触发与拖动',
            value:this.selectedItem()?.dragLook === true ? '拖动视角已开' : '拖动视角已关',
            onTap:()=>this.openTab('group-actions')})
        }
        CompactEditorRow({palette:this.palette,title:'显示规则',value:'',onTap:()=>this.openTab('behavior')})
      }
      Button(this.selectedIsLocked()?'解锁位置尺寸':'锁定位置尺寸').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.toggleLocked())
      if(this.selectedItem()?.secondaryAction===undefined&&this.selectedItem()?.systemAction===undefined){Button('复制按键').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.duplicateSelected())}
      if(this.selectedChildId.length>0){Row(){Button('向前排列').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.moveChildOrder_(-1))
        Button('向后排列').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).layoutWeight(1).onClick(()=>this.moveChildOrder_(1))}.width('100%')}
      if(this.selectedItem()?.hidden){Button('恢复历史隐藏').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.toggleHidden())}
      if(this.selectedItem()?.systemAction===undefined){Button(this.selectedItem()?.secondaryAction?.kind==='toggle'?'删除展开键…':'删除按键').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').fontColor(this.palette.danger).onClick(()=>this.deleteSelected())}
      if(this.selectedControlDescription_().length>0){Text(this.selectedControlDescription_()).fontSize(11).fontColor(this.palette.muted).width('100%')}
      if(this.selectedItem()?.type===ControlType.JOYSTICK||this.selectedItem()?.type===ControlType.HOTBAR_SELECTOR){Button('相关输入设置 ›').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.requestSettings_(this.selectedItem()?.type===ControlType.JOYSTICK?'move':'gesture'))}
    }.width('100%')
  }
  @Builder
  AssignGroupPanel_() {
    Column({space:4}) {
      if(this.selectedItem()?.systemAction==='edit'||this.selectedItem()?.systemAction==='visibility'||this.selectedChildId.length>0){Text('系统恢复入口不归组；抽屉子项继承父组。').fontSize(12).fontColor(this.palette.muted)}
      else {
        ForEach(this.controlGroups??[],(group: ControlGroup)=>{
          Button(group.name).type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>{
            const profile: LayoutProfile | null=this.buildProfile(),id: string=this.selectedItem()?.id??''
            if(profile!==null&&this.applyGroupDraft_(moveSecondaryGroupMember(profile,id,group.id),'已更新所属组，位置保持')){
              this.selectControlIdentity_(id,false);this.syncSecondarySelection_();this.backEditor_()
            }
          })
        },(group: ControlGroup): string=>group.id)
        if(this.controlGroups===undefined){Button('先创建控件组').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).width('100%').onClick(()=>this.openTab('groups'))}
      }
    }.width('100%')
  }
  @Builder
  GlobalLayoutPanel_() {
    Column({space:4}) {
      Text('整体缩放 · '+Math.round(this.globalScale*100).toString()+'%').fontSize(12).fontColor(this.palette.text).width('100%')
      Slider({value:this.globalScale*100,min:50,max:200,step:5}).width('100%').height(44).selectedColor(this.palette.accentFill)
        .onChange((value: number,mode: SliderChangeMode): void=>this.setOverallStyle_('globalScale',value,mode))
      Text('整体透明度 · '+Math.round(this.globalOpacity*100).toString()+'%').fontSize(12).fontColor(this.palette.text).width('100%')
      Slider({value:this.globalOpacity*100,min:10,max:100,step:5}).width('100%').height(44).selectedColor(this.palette.accentFill)
        .onChange((value: number,mode: SliderChangeMode): void=>this.setOverallStyle_('globalOpacity',value,mode))
      CompactEditorRow({palette:this.palette,title:'吸附与对齐',value:'编辑偏好',onTap:()=>this.openTab('alignment')})
      CompactEditorRow({palette:this.palette,title:'全部控件',value:'列表',onTap:()=>this.openTab('list')})
    }.width('100%')
  }

}

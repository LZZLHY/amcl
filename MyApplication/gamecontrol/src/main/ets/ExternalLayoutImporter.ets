/**
 * Pojav/Amethyst、FCL和Zalith 2布局的受限转换与兼容报告。
 * 只读取已经核实的格式字段；不执行源布局宏或动态脚本。所有近似、跳过和层合并都进入预览警告。
 * 原文件从不改写；转换后仍通过AMCL统一校验，非法/过量数据不会产生半份可保存方案。
 */
import { ControlItem, ControlType, LayoutProfile, AlignGroup, LAYOUT_PROFILE_VERSION,
  validateAndNormalizeLayout, utf8ByteLength } from './ControlLayout'
import { TouchConfiguration } from './TouchPreferences'
import { parseMinecraftTouchKey, TOUCH_ACTION_NAMES } from './TouchActionBindings'
import { evaluateLayoutExpression } from './LayoutExpression'
import { ControlGroup, ControlGroupAction, ControlPhaseBinding, ControlActionPhase,
  CONTROL_GROUP_PROFILE_VERSION, TOUCH_GROUP_CAPABILITY, TOUCH_PHASE_CAPABILITY, MAX_CONTROL_GROUPS } from './ControlGroups'

type ForeignObject = Record<string, Object>

export class ExternalLayoutReview {
  format: string = ''
  profile: LayoutProfile | null = null
  warnings: string[] = []
  reason: string = ''
  skipped: number = 0
}

/** JSON形状守卫只允许普通对象，不将数组/标量当作具有任意属性的控件。 */
function object(value: Object | undefined): ForeignObject {
  if (value===null || value===undefined || typeof value!=='object' || Array.isArray(value)) return {}
  return value as ForeignObject
}
/** 非数组视为缺省列表，不遍历任意对象的属性作为控件。 */
function array(value: Object | undefined): Object[] { return Array.isArray(value) ? value as Object[] : [] }
/** 用户文本只读作标签或枚举名字，不参与表达式执行。 */
function string(value: Object | undefined, fallback: string = ''): string { return typeof value==='string' ? value : fallback }
/** 缺省与非法分开处理：缺省可兼容，字符串数值/无穷值拒绝整个转换。 */
function number(value: Object | undefined, fallback: number): number {
  if (value===undefined) return fallback
  if (typeof value!=='number' || !Number.isFinite(value)) throw new Error('坐标或按键字段不是有限数值')
  return value
}
/** 布尔字段不使用truthy转换，源文件的字符串false不能变成开启。 */
function flag(value: Object | undefined, fallback: boolean = false): boolean {
  if (value===undefined) return fallback
  if (typeof value!=='boolean') throw new Error('开关字段不是布尔值')
  return value
}
/** 只约束已经验证过的数值；几何调用方同时登记发生的转换差异。 */
function clamp(value: number, low: number, high: number): number { return Math.max(low,Math.min(high,value)) }

/** 格式识别不代表内容合法；analyzeExternalLayout才负责完整转换和可导入性判定。 */
export function externalLayoutFormat(value: Object): string {
  const root = object(value)
  if (Array.isArray(root['mControlDataList']) || Array.isArray(root['controlDataList']) ||
    Array.isArray(root['mJoystickDataList']) || Array.isArray(root['mDrawerDataList'])) return 'pojav'
  if (Array.isArray(root['viewGroups']) && root['controllerVersion']!==undefined) return 'fcl'
  if (Array.isArray(root['layers']) && root['editorVersion']!==undefined) return 'zalith2'
  return ''
}

/** evdev和LWJGL2只在一部分键位同值；把差异明确列出，不能将FCL数字当GLFW键直接发送。 */
function fclKey(code: number): number | undefined {
  const overrides: Record<string,number> = {
    '96':335,'97':345,'98':331,'99':283,'100':346,'102':268,'103':265,'104':266,'105':263,
    '106':262,'107':269,'108':264,'109':267,'110':260,'111':261,'119':284,'125':343,'126':347,'127':348,
    '1000':-1,'1001':-3,'1002':-2
  }
  const mapped: number | undefined = overrides[code.toString()]
  if (mapped!==undefined) return mapped
  return code>0 && code<96 ? parseMinecraftTouchKey(code.toString()) : undefined
}

/** ZL2使用GLFW常量名字，不使用Android键码；源的滚轮/宏事件留给兼容报告。 */
function zalithKey(value: Object | undefined): number | undefined {
  const name: string = string(value)
  if (name.startsWith('GLFW_KEY_')) {
    let key: string = name.substring(9).toLowerCase().replace(new RegExp('_','g'),'.')
    if (key.startsWith('kp.')) key='keypad.'+key.substring(3)
    return parseMinecraftTouchKey('key.keyboard.'+key)
  }
  if (name.startsWith('GLFW_MOUSE_BUTTON_')) return parseMinecraftTouchKey('key.mouse.'+name.substring(18).toLowerCase())
  return parseMinecraftTouchKey(name)
}

/** 每次导入独占的上下文；警告按原因计数，避免对话框被重复消息淹没。 */
class ExternalControlReader {
  readonly review: ExternalLayoutReview = new ExternalLayoutReview()
  readonly touch: TouchConfiguration = new TouchConfiguration()
  readonly controls: ControlItem[] = []
  private width: number
  private height: number
  private sequence: number = 0
  private warnings: Map<string,number> = new Map()
  private joystickSeen: boolean = false
  private deadZone: number = .18
  private groups: ControlGroup[] | undefined = undefined
  private unsupported: string[] = []
  constructor(width: number,height: number) { this.width=width; this.height=height }

  note(message: string): void { this.warnings.set(message,(this.warnings.get(message) ?? 0)+1) }
  skip(message: string): void { this.review.skipped++; this.note(message) }

  /** 所有ID由本次导入生成，外部UUID、长标签或重复名字都不进入native身份字段。 */
  item(label: string,width: number,height: number,x: number,y: number): ControlItem {
    if (++this.sequence>252) throw new Error('源布局控件过多，需要为系统按钮和快捷栏保留空间')
    let safeLabel: string = ''
    for (const char of label) { if (utf8ByteLength(safeLabel+char)>128) break; safeLabel+=char }
    const w: number = clamp(width,8,Math.min(4096,this.width))
    const h: number = clamp(height,8,Math.min(4096,this.height))
    if (w!==width || h!==height || x<0 || y<0 || x+w>this.width || y+h>this.height) this.note('超出视口的控件尺寸或位置已收回屏内')
    return { id: 'foreign_'+this.sequence.toString(),label:safeLabel,type:ControlType.BUTTON,keyOrMouse:0,
      xPct:clamp(x,0,this.width-w)/this.width,yPct:clamp(y,0,this.height-h)/this.height,
      baseWidth:w,baseHeight:h,itemScale:1,isCircle:false,alignGroup:AlignGroup.NONE,alignIndex:0,
      grabbedOnly:false,trigger:'press' }
  }

  /** 不支持的组合成员使整个动作拒绝，不偷偷保留其中一部分修饰键。 */
  keys(raw: Object[], format: string): number[] | undefined {
    const result: number[] = []
    for (const value of raw) {
      let code: number | undefined = undefined
      if (format==='zalith2') {
        const event = object(value)
        if (string(event['type'])!=='key') return undefined
        code=zalithKey(event['key'])
      } else {
        const key: number = number(value,0)
        if (!Number.isInteger(key)) return undefined
        code=format==='fcl' ? fclKey(key) : (key>0 && key<=512 ? key : (key===-3 ? -1 : (key===-4 ? -2 : (key===-6 ? -3 : undefined))))
        if (key===0) continue
      }
      if (code===undefined) return undefined
      if (code!==0 && result.indexOf(code)<0) result.push(code)
    }
    return result.length<=6 ? result : undefined
  }

  scene(item: ControlItem,scene: string): void {
    const mode: string = scene.toLowerCase()
    item.grabbedOnly=mode==='in_game'; item.menuOnly=mode==='in_menu'
  }

  /** Pojav/Amethyst的安全坐标子集；未知函数/变量只降级位置并报告，绝不eval。 */
  pojavItem(raw: ForeignObject): ControlItem {
    const w: number = number(raw['width'] ?? raw['specifiedWidth'],50)
    const h: number = number(raw['height'] ?? raw['specifiedHeight'],50)
    const variables: Record<string,number> = { 'screen_width':this.width,'screen_height':this.height,
      'width':w,'height':h,'right':this.width-w,'bottom':this.height-h,'margin':2 }
    const x: number | undefined = evaluateLayoutExpression(string(raw['dynamicX'],String(number(raw['x'],this.width/2))),variables)
    const y: number | undefined = evaluateLayoutExpression(string(raw['dynamicY'],String(number(raw['y'],this.height/2))),variables)
    if (x===undefined || y===undefined) this.note('无法解释的动态坐标已放到视口中心，请在编辑器调整')
    const item = this.item(string(raw['name']),w,h,x ?? this.width/2,y ?? this.height/2)
    const game: boolean = flag(raw['displayInGame'],true), menu: boolean = flag(raw['displayInMenu'],true)
    item.hidden=!game && !menu; item.grabbedOnly=game && !menu; item.menuOnly=menu && !game
    item.trigger=flag(raw['isToggle']) ? 'toggle' : 'press'
    item.dragLook=flag(raw['passThruEnabled'])
    if (item.dragLook) this.note('指针穿透转换为按住拖动瞄准，不透传额外点击')
    if (flag(raw['isSwipeable']) && !item.dragLook && item.trigger==='press') item.swipeGroup='foreign'
    const opacity: number = number(raw['opacity'],.6)
    item.style={ opacity:clamp(opacity,.1,1),cornerRadius:clamp(number(raw['cornerRadius'],12)/100,0,1) }
    if (opacity<.1 || opacity>1) this.note('控件透明度已限制在AMCL支持范围内')
    if (raw['bgColor']!==undefined || raw['strokeColor']!==undefined) this.note('源平台配色和边框未全部保留，使用AMCL默认样式')
    return item
  }

  pojavButton(raw: ForeignObject): ControlItem | undefined {
    const item = this.pojavItem(raw)
    const rawKeys: Object[] = array(raw['keycodes'])
    const meaningful: Object[] = rawKeys.filter((value: Object): boolean => value!==0)
    const special: number = meaningful.length===1 ? number(meaningful[0],0) : 0
    if (special===-1 || special===-2 || special===-9) {
      item.systemAction=special===-1 ? 'input' : (special===-2 ? 'visibility' : 'edit')
      item.keyOrMouse=special===-1 ? 84 : 0; item.dragLook=false; item.swipeGroup=undefined
      item.trigger='press'; this.note('启动器功能键转换为AMCL输入、显示或布局设置功能')
    } else if (special===-5) {
      this.touch.menuMode='touchpad'; this.skip('虚拟鼠标切换键改为方案的触摸板模式，请在触控设置切换'); return undefined
    } else if (special===-7 || special===-8) {
      item.type=ControlType.SCROLL_WHEEL; item.keyOrMouse=0; item.dragLook=false; item.swipeGroup=undefined
      this.note('滚轮点击按钮转换为上下滑动的滚轮条')
    } else {
      const keys: number[] | undefined = this.keys(rawKeys,'pojav')
      if (keys===undefined || keys.length===0) { this.skip('不支持或为空的Pojav按键动作已跳过'); return undefined }
      item.keys=keys; item.keyOrMouse=keys[0]
    }
    return item
  }

  /** 单摇杆动作映射共享AMCL专用动作快照；多个不同摇杆策略不能假装已等价。 */
  joystick(item: ControlItem,raw: ForeignObject,format: string): void {
    if (this.joystickSeen) {
      if (format === 'fcl') this.unsupported.push('额外摇杆：当前只能表达一套独立移动策略')
      else this.skip('额外摇杆已跳过：本导入只转换一个独立移动摇杆')
      return
    }
    this.joystickSeen=true; item.type=ControlType.JOYSTICK; item.keyOrMouse=0; item.keys=[]
    item.dragLook=false; item.swipeGroup=undefined; item.grabbedOnly=true; item.menuOnly=false
    this.note('摇杆按AMCL半径与菜单策略转换，需复核死区和锁定手感')
    if (format==='pojav') {
      this.touch.joystickCenter=flag(raw['absolute'],true) ? 'fixed' : 'floating'
      this.touch.joystickAutoWalk=flag(raw['forwardLock']); this.deadZone=.35
      if (this.touch.joystickAutoWalk) this.note('前进锁字段保留，但AMCL已停用自动前进；运行时抬手停止移动')
    } else if (format==='fcl') {
      const event = object(raw['event'])
      this.touch.joystickCenter=string(event['followOption'],'CENTER_FOLLOW')==='FIXED' ? 'fixed' : 'floating'
      this.touch.joystickAutoWalk=flag(event['canLock'])
      if(this.touch.joystickAutoWalk) this.note('前进锁已停用，运行时抬手停止移动')
      this.deadZone=clamp(number(event['deadZone'],0)/100,.01,.95)
      if (flag(event['sneak'],true)) this.note('摇杆中心双击潜行未转换，可另加潜行按钮')
      const fields: string[] = ['upKeycode','leftKeycode','downKeycode','rightKeycode']
      for (let i=0;i<4;i++) {
        if (array(event[fields[i]]).length===0) continue
        const keys = this.keys(array(event[fields[i]]),'fcl')
        if (keys===undefined || keys.length!==1) { this.unsupported.push('摇杆方向组合无法等价转换'); continue }
        this.touch.actionOverrides[TOUCH_ACTION_NAMES[i]]=keys[0]
      }
    } else {
      this.deadZone=clamp(number(raw['deadZoneRatio'],.5),.01,.95)
      this.touch.joystickAutoWalk=flag(raw['canLock'],true)
      if(this.touch.joystickAutoWalk) this.note('前进锁已停用，运行时抬手停止移动')
      const locks = this.keys(array(raw['lockEvents']),'zalith2')
      if (locks===undefined || locks.length>1) this.note('复杂摇杆锁定动作未转换为疾跑')
      else if (locks.length===1) { this.touch.joystickSprint=true; this.touch.actionOverrides['sprint']=locks[0] }
      if (Object.keys(object(raw['directionEvents'])).length>0) this.note('自定义Zalith摇杆方向需在专用动作改键中复核')
      this.touch.joystickSprintThreshold=clamp(1+number(raw['lockThreshold'],.3),.5,1.5)
    }
    this.controls.push(item)
  }

  /** 按坐标格式生成同一几何：FCL位置0..1000，ZL2位置0..10000，都相对可移动空间。 */
  positioned(raw: ForeignObject,format: string,joystick: boolean = false): ControlItem {
    const fcl: boolean = format==='fcl'
    const base = fcl ? object(raw['baseInfo']) : raw
    const size = fcl ? base : object(raw['buttonSize'])
    const position = fcl ? base : object(raw['position'])
    const unit: number = fcl ? 1000 : 10000
    let w: number = 50, h: number = 50
    if (!fcl && joystick) {
      w=string(raw['sizeType'],'percentage')==='dp' ? number(raw['sizeDp'],200) : this.height*number(raw['sizePercentage'],2500)/10000
      h=w
    } else if (string(size[fcl ? 'sizeType' : 'type'],'percentage').toLowerCase()===(fcl ? 'absolute' : 'dp')) {
      w=number(size[fcl ? 'absoluteWidth' : 'widthDp'],50); h=number(size[fcl ? 'absoluteHeight' : 'heightDp'],50)
    } else {
      const pw=object(size['percentageWidth']), ph=object(size['percentageHeight'])
      const wr=string(fcl ? pw['reference'] : size['widthReference'],'screen_height').toLowerCase()
      const hr=string(fcl ? ph['reference'] : size['heightReference'],'screen_height').toLowerCase()
      w=(wr==='screen_width' ? this.width : this.height)*number(fcl ? pw['size'] : size['widthPercentage'],fcl ? 100 : 1200)/unit
      h=(hr==='screen_width' ? this.width : this.height)*number(fcl ? ph['size'] : size['heightPercentage'],fcl ? 100 : 1200)/unit
    }
    const x=(this.width-w)*number(position[fcl ? 'xPosition' : 'x'],0)/unit
    const y=(this.height-h)*number(position[fcl ? 'yPosition' : 'y'],0)/unit
    const label: string = fcl ? string(raw['text']) : string(object(raw['text'])['default'])
    const item=this.item(label,w,h,x,y)
    this.scene(item,string(base['visibilityType'],'always'))
    return item
  }

  readPojav(root: ForeignObject): void {
    for (const value of array(root['mControlDataList'] ?? root['controlDataList'])) {
      const item=this.pojavButton(object(value)); if (item!==undefined) this.controls.push(item)
    }
    for (const value of array(root['mJoystickDataList'])) {
      const raw=object(value); this.joystick(this.pojavItem(raw),raw,'pojav')
    }
    for (const value of array(root['mDrawerDataList'])) {
      const drawer=object(value), item=this.pojavItem(object(drawer['properties']))
      item.type=ControlType.DRAWER; item.keyOrMouse=0; item.keys=[]; item.children=[]
      item.dragLook=false; item.swipeGroup=undefined
      for (const button of array(drawer['buttonProperties'])) {
        const child=this.pojavButton(object(button))
        if (child!==undefined) { child.swipeGroup=undefined; item.children.push(child) }
      }
      if (item.children.length>0) this.controls.push(item)
      this.note('抽屉展开方向转换为AMCL环形菜单')
    }
  }

  readFcl(root: ForeignObject): void {
    if (number(root['controllerVersion'],-1) !== 21) throw new Error('尚未验证该 FCL controllerVersion；当前只接受版本 21')
    const sourceGroups: Object[] = array(root['viewGroups'])
    if (sourceGroups.length + 1 > MAX_CONTROL_GROUPS) throw new Error('触控组超过容量（包含 AMCL 默认组）')
    let total: number = 0
    for (const value of sourceGroups) {
      const data = object(object(value)['viewData'])
      total += array(data['buttonList']).length + array(data['directionList']).length
    }
    if (total > 252) throw new Error('源布局超过252个控件；隐藏组同样计入，未截断导入')
    const mapping: Map<string,string> = new Map<string,string>()
    this.groups = [{ id: 'fcl_default', name: '默认组', initialVisible: true }]
    // 第一遍只建立完整组表，第二遍才解释目标引用；字段和数组顺序不决定引用身份。
    for (let index: number = 0; index < sourceGroups.length; index++) {
      const group = object(sourceGroups[index]), externalId: string = string(group['id'])
      if (externalId.length > 0 && mapping.has(externalId)) throw new Error('FCL 组 ID 重复，目标引用有歧义：组 ' + (index + 1))
      const id: string = 'fcl_group_' + index.toString()
      if (externalId.length > 0) mapping.set(externalId,id)
      const visibility: string = string(group['visibility'],'VISIBLE')
      if (visibility !== 'VISIBLE' && visibility !== 'INVISIBLE') throw new Error('FCL 组初始显隐枚举未知：组 ' + (index + 1))
      const name: string = string(group['name'],'组 ' + (index + 1)).trim() || ('组 ' + (index + 1))
      this.groups.push({ id:id, name:name.substring(0,64), initialVisible:visibility === 'VISIBLE' })
      if (name.length > 64) this.note('过长组名已缩短，组引用仍按稳定ID保存')
    }
    this.note('组关系与四阶段事件保留；样式使用AMCL默认，几何固化为导入视口')
    this.note('FCL手势：长按400ms、单击不超过100ms、相邻点击间隔小于400ms；连滑限同一触控组')
    this.note('多阶段按钮按触摸手势执行；键盘或无障碍激活请配置单阶段入口')
    this.note('Cancel只取消；重复toggle按奇偶执行，与FCL首次懒加载时序有意不同')
    for (let groupIndex: number = 0; groupIndex < sourceGroups.length; groupIndex++) {
      const value: Object = sourceGroups[groupIndex]
      const group=object(value), data=object(group['viewData'])
      const groupId: string = this.groups[groupIndex + 1].id
      for (const value of array(data['buttonList'])) {
        const raw=object(value), events=object(raw['event'])
        const phases: ControlActionPhase[] = ['press','longPress','click','doubleClick']
        const sourcePhases: string[] = ['pressEvent','longPressEvent','clickEvent','doubleClickEvent']
        const bindings: ControlPhaseBinding[] = [], actions: ControlGroupAction[] = []
        let executable: boolean = true
        for (let index: number = 0; index < 4; index++) {
          const event = object(events[sourcePhases[index]])
          const keys: number[] | undefined = this.keys(array(event['outputKeycodes']),'fcl')
          const unsupported: boolean = flag(event['autoClick']) || flag(event['input']) || flag(event['quickInput']) ||
            flag(event['openMenu']) || flag(event['switchMouseMode']) || flag(event['switchTouchMode']) || string(event['outputText']).length > 0
          if (keys === undefined || unsupported) {
            this.unsupported.push('组 ' + (groupIndex + 1) + ' / ' + string(raw['text'],'未命名按钮') + ' / ' + sourcePhases[index] +
              '：含未知键、连点、文本或启动器操作'); executable = false
          }
          if ((keys?.length ?? 0) > 0) bindings.push({ phase:phases[index], keys:keys!, autoKeep:flag(event['autoKeep']) })
          const targets: string[] = []
          const sourceTargets: Object[] = array(event['bindViewGroup'])
          if (sourceTargets.length > 128) throw new Error('单阶段组目标超过128项')
          for (const target of sourceTargets) {
            const mapped: string | undefined = mapping.get(string(target))
            if (mapped === undefined) throw new Error('FCL 组动作引用不存在的目标：组 ' + (groupIndex + 1))
            targets.push(mapped)
          }
          if (targets.length > 0) actions.push({ phase:phases[index], operation:'toggle', targets:targets })
        }
        if (!executable) continue
        if (bindings.length === 0 && actions.length === 0) { this.skip('没有可执行动作的FCL装饰按钮'); continue }
        const item=this.positioned(raw,'fcl')
        item.controlGroupId=groupId; item.keys=[]; item.keyOrMouse=0; item.trigger='press'
        item.phaseBindings=bindings; item.groupActions=actions; item.gesturePolicy='fcl'
        item.dragLook=flag(events['pointerFollow'])
        if (flag(events['swipable']) && !item.dragLook) item.swipeGroup='fcl_swipe'
        if (flag(object(raw['baseInfo'])['Movable'])) this.note('运行中自由移动控件未转换；编辑器仍可调整位置')
        const scene: string = string(object(raw['baseInfo'])['visibilityType'],'ALWAYS').toUpperCase()
        if (scene !== 'ALWAYS' && scene !== 'IN_GAME' && scene !== 'IN_MENU') throw new Error('FCL 控件场景枚举未知')
        this.controls.push(item)
      }
      for (const value of array(data['directionList'])) {
        const raw=object(value), item=this.positioned(raw,'fcl',true); item.controlGroupId=groupId
        this.joystick(item,raw,'fcl')
      }
    }
  }

  readZalith(root: ForeignObject): void {
    this.note('Zalith图层按初始显隐展开；动态层、文本框、穿透与源样式未等价保留')
    for (const value of array(root['layers'])) {
      const layer=object(value), hidden=flag(layer['hide'])
      if (array(layer['textBoxes']).length>0) this.note('Zalith文本显示控件已跳过')
      for (const value of array(layer['normalButtons'])) {
        const raw=object(value), keys=this.keys(array(raw['clickEvents']),'zalith2')
        if (keys===undefined || keys.length===0) { this.skip('含图层、启动器或文本操作的Zalith控件已跳过'); continue }
        const item=this.positioned(raw,'zalith2'); item.keys=keys; item.keyOrMouse=keys[0]; item.hidden=hidden
        const own: string = string(raw['visibilityType'],'always'), parent: string = string(layer['visibilityType'],'always')
        if (own==='always') this.scene(item,parent)
        else if (parent!=='always' && parent!==own) item.hidden=true
        item.trigger=flag(raw['isToggleable']) ? 'toggle' : 'press'
        if (flag(raw['isSwipple']) && item.trigger==='press') item.swipeGroup='foreign'
        this.controls.push(item)
      }
      for (const value of array(layer['joystickButtons'])) {
        const raw=object(value), item=this.positioned(raw,'zalith2',true); item.hidden=hidden
        this.joystick(item,raw,'zalith2')
      }
    }
  }

  finish(name: string): ExternalLayoutReview {
    if (this.unsupported.length > 0) {
      this.review.reason='存在不能等价执行的内容，未生成残缺方案：' + this.unsupported.slice(0,12).join('；')
      this.review.warnings=this.unsupported.slice(); return this.review
    }
    if (this.controls.length===0) { this.review.reason='没有可转换的控件'; return this.review }
    const profile: LayoutProfile = { version:LAYOUT_PROFILE_VERSION,name:name,globalScale:1,controls:this.controls,
      joystickDeadZone:this.deadZone,haptic:true,targetDevice:'any',isPreset:false,touch:this.touch }
    if (this.groups !== undefined) {
      profile.version=CONTROL_GROUP_PROFILE_VERSION; profile.controlGroups=this.groups; profile.defaultControlGroupId='fcl_default'
      profile.requiredCapabilities=[TOUCH_GROUP_CAPABILITY,TOUCH_PHASE_CAPABILITY]
      const targets: Set<string> = new Set<string>()
      for (const item of this.controls) for (const action of item.groupActions ?? []) for (const target of action.targets) targets.add(target)
      for (const group of this.groups) {
        const members: number = this.controls.filter((item: ControlItem): boolean => item.controlGroupId === group.id).length
        this.note(group.name + '：' + (group.initialVisible ? '初始显示' : '初始隐藏') + '，' + members + '个成员')
        if (!group.initialVisible && !targets.has(group.id)) this.note('隐藏组“' + group.name + '”没有静态切换入口，可从系统恢复入口恢复或编辑')
      }
    }
    this.review.profile=validateAndNormalizeLayout(profile)
    if (this.review.profile===null) this.review.reason='转换结果超出AMCL布局边界，已拒绝整份导入'
    this.warnings.forEach((count: number,message: string): void => { this.review.warnings.push(message+'（'+count.toString()+'项）') })
    return this.review
  }
}

/** 统一分析入口；256KiB限制与文件入口一致，未知格式返回明确原因，不尝试猜测键码。 */
export function analyzeExternalLayout(json: string,name: string,width: number = 720,height: number = 360): ExternalLayoutReview {
  const fallback = new ExternalLayoutReview()
  try {
    if (utf8ByteLength(json)>262144) throw new Error('布局文件超过256KiB')
    const root=object(JSON.parse(json) as Object)
    const format: string = externalLayoutFormat(root)
    fallback.format=format
    if (format.length===0) throw new Error('不支持的外部布局格式')
    if (!Number.isFinite(width) || !Number.isFinite(height) || width<64 || height<64) throw new Error('视口尺寸无效')
    const reader = new ExternalControlReader(width,height)
    reader.review.format=format
    if (format==='pojav') reader.readPojav(root)
    else if (format==='fcl') reader.readFcl(root)
    else reader.readZalith(root)
    return reader.finish(name)
  } catch (error) { fallback.reason=(error as Error).message; return fallback }
}

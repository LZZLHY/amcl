/** 游戏线程GUI快照的纯校验/投影；手动校准保留，不把设备全屏或自动档当作游戏实际窗口。 */
import { ControlItem, ControlType, LayoutProfile, cloneItem } from './ControlLayout'
import { TouchControlRect } from './TouchControlGeometry'

export class GameGuiState {
  valid: boolean = false
  estimated: boolean = false
  legacy: boolean = false
  requested: number = 0
  effective: number = 1
  framebufferWidth: number = 0
  framebufferHeight: number = 0
  guiWidth: number = 0
  guiHeight: number = 0
  menu: boolean = false
  revision: number = 0
  canRestore: boolean = false
  requestId: number = 0
  result: number = 0
  unicode: boolean = false
  /** 只读菜单导航尾表：0未知、1选项按钮、2视频按钮、3已进入视频页；矩形使用GUI单位。 */
  navigationKind: number = 0
  navigationX: number = 0
  navigationY: number = 0
  navigationWidth: number = 0
  navigationHeight: number = 0
  navigationScrollable: boolean = false
  navigationScrollKnown: boolean = false
}

/**
 * 未识别加载器的只读兼容路径：只在options明确给出合法guiScale时估算，不能据此提供即时恢复权限。
 * 修改HUD的模组仍需手动校准；这份数据明确标estimated，不能作为游戏已回读的实际窗口值。
 */
export function estimateGameGuiFromOptions(text: string,w: number,h: number,menu: boolean,revision: number,legacy: boolean=false): GameGuiState {
  const result=new GameGuiState()
  if(text.length>1048576 || w<1 || h<1 || !Number.isFinite(w) || !Number.isFinite(h)) return result
  let requested: number=-1
  let unicode: boolean=false
  for(const line of text.split('\n')) {
    if(line.startsWith('guiScale:')) {
      const value: string=line.substring(9).trim()
      if(new RegExp('^[0-9]+$').test(value)) requested=Number(value)
    }
    if(line.startsWith('forceUnicodeFont:')) unicode=line.substring(17).trim()==='true'
  }
  if(!Number.isInteger(requested) || requested<0 || requested>64) return result
  const effective: number=calculateMinecraftGuiScale(w,h,requested,unicode,legacy)
  result.valid=true; result.estimated=true; result.requested=requested; result.effective=effective
  result.framebufferWidth=w; result.framebufferHeight=h
  result.guiWidth=Math.ceil(w/effective); result.guiHeight=Math.ceil(h/effective)
  result.menu=menu; result.revision=revision; result.unicode=unicode; result.legacy=legacy
  return result
}

/** 原13项前缀与19项完整快照均可读；非法前缀失效，未知导航尾表只撤销指引能力。 */
export function parseGameGuiState(values: number[]): GameGuiState {
  const state = new GameGuiState()
  if ((values.length!==13 && values.length!==19) || values.slice(0,13).some((v: number): boolean => !Number.isFinite(v)) || values[0]!==2) return state
  if (!Number.isInteger(values[1]) || values[1]<0 || values[1]>64 || values[2]<1 || values[2]>128 ||
    values[3]<1 || values[4]<1 || values[5]<1 || values[6]<1 || values[8]<1) return state
  for(const index of [3,4,5,6]) if(!Number.isInteger(values[index]) || values[index]>65535) return state
  for(const index of [7,9,12]) if(values[index]!==0 && values[index]!==1) return state
  if(!Number.isSafeInteger(values[8]) || !Number.isSafeInteger(values[10]) || values[10]<0 ||
    !Number.isInteger(values[11]) || values[11]<-1 || values[11]>3) return state
  state.valid=true; state.requested=values[1]; state.effective=values[2]
  state.framebufferWidth=values[3]; state.framebufferHeight=values[4]
  state.guiWidth=values[5]; state.guiHeight=values[6]; state.menu=values[7]===1
  state.revision=values[8]; state.canRestore=values[9]===1
  state.requestId=values[10]; state.result=values[11]; state.unicode=values[12]===1
  if(values.length===19 && values.slice(13).every((v: number): boolean => Number.isFinite(v)) &&
    Number.isInteger(values[13]) && values[13]>=0 && values[13]<=3 && (values[18]===-1 || values[18]===0 || values[18]===1)) {
    const kind: number=values[13]
    const rectValid: boolean=values[14]>=0 && values[15]>=0 && values[16]>0 && values[17]>0 &&
      values[14]+values[16]<=state.guiWidth && values[15]+values[17]<=state.guiHeight
    if(kind===3 || ((kind===1 || kind===2) && rectValid)) {
      state.navigationKind=kind; state.navigationX=values[14]; state.navigationY=values[15]
      state.navigationWidth=values[16]; state.navigationHeight=values[17]; state.navigationScrollable=values[18]===1
      state.navigationScrollKnown=values[18]!==-1
    }
  }
  return state
}

/** 真实按钮GUI矩形按有效缩放→framebuffer→surface/vp投影；边缘裁切，不补造缺失目标。 */
export function projectGameNavigation(state: GameGuiState,widthVp: number,heightVp: number): TouchControlRect {
  const rect: TouchControlRect=new TouchControlRect()
  if(!state.valid || !state.menu || (state.navigationKind!==1 && state.navigationKind!==2) || widthVp<=0 || heightVp<=0) return rect
  const xScale: number=state.effective*widthVp/state.framebufferWidth
  const yScale: number=state.effective*heightVp/state.framebufferHeight
  rect.x=state.navigationX*xScale; rect.y=state.navigationY*yScale
  rect.width=Math.max(0,Math.min(widthVp-rect.x,state.navigationWidth*xScale))
  rect.height=Math.max(0,Math.min(heightVp-rect.y,state.navigationHeight*yScale))
  return rect
}

/** 稳定版世代识别只用于估算；已绑定的游戏实际窗口始终优先，未知快照不伪造精确能力。 */
export function usesLegacyGuiScale(version: string): boolean {
  const match: RegExpExecArray | null=new RegExp('^1\\.([0-9]+)(?:\\.|$|-)').exec(version)
  return match!==null && Number(match[1])<=12
}
/** 原版320×240算法；老ScaledResolution向下偶数（保留1），现代Window向上偶数。 */
export function calculateMinecraftGuiScale(w: number,h: number,requested: number,unicode: boolean,legacy: boolean=false): number {
  if (!Number.isFinite(w) || !Number.isFinite(h) || w<=0 || h<=0 || !Number.isInteger(requested) || requested<0) return 1
  let scale: number = 1
  while (scale!==requested && scale<w && scale<h && Math.floor(w/(scale+1))>=320 && Math.floor(h/(scale+1))>=240) scale++
  if (unicode && scale%2!==0) { if(legacy) { if(scale!==1) scale-- } else scale++ }
  return scale
}

/** 标准格宽20 GUI单位转换为真实surface的vp尺寸，供过小界面提示使用。 */
export function guiTargetSize(state: GameGuiState,widthVp: number): number {
  return state.valid && state.framebufferWidth>0 ? 20*state.effective*widthVp/state.framebufferWidth : 0
}

/**
 * 派生显示/schema矩形，不写用户存档。GUI→buffer→surface/vp按真实比例，支持低分辨率渲染。
 * 180格区域去掉182背景边框；guiWidth来自游戏而不是再猜ceil，手工定位方案保持原样。
 */
export function projectGameHotbar(profile: LayoutProfile,controls: ControlItem[],state: GameGuiState,
  widthVp: number,heightVp: number): ControlItem[] {
  if (!state.valid || widthVp<=0 || heightVp<=0) return controls
  const xf: number = widthVp/state.framebufferWidth
  const yf: number = heightVp/state.framebufferHeight
  const left: number = Math.max(0,(Math.floor(state.guiWidth/2)-90)*state.effective*xf)
  const top: number = Math.max(0,(state.guiHeight-22)*state.effective*yf)
  const width: number = Math.min(widthVp-left,180*state.effective*xf)
  const height: number = Math.min(heightVp-top,22*state.effective*yf)
  if (width<=0 || height<=0) return controls
  return controls.map((item: ControlItem): ControlItem => {
    if (item.type!==ControlType.HOTBAR_SELECTOR || item.hotbarUserPlaced===true) return item
    const copy: ControlItem = cloneItem(item)
    copy.xPct=left/widthVp; copy.yPct=top/heightVp
    copy.baseWidth=width/profile.globalScale; copy.baseHeight=height/profile.globalScale; copy.itemScale=1
    return copy
  })
}

/** 会话内的小GUI保护：同档位只提示一次；用户保留后尊重选择，不设全局最低档位。 */
export class SmallGuiGuard {
  private previous: number = -1
  private accepted: number = -1
  private lastRequested: number = -1
  private lastRevision: number = 0
  target: number = 0
  canRestore: boolean = false
  observe(state: GameGuiState,widthVp: number): boolean {
    if (!state.valid || !state.menu || state.revision===this.lastRevision) return false
    this.lastRevision=state.revision
    if (this.lastRequested!==state.requested) this.accepted=-1
    this.lastRequested=state.requested
    if (guiTargetSize(state,widthVp)>=28) { this.previous=state.requested; return false }
    if (this.accepted===state.requested) return false
    this.target=this.previous>=0 ? this.previous : 0
    // 自动档本身已是可用最大值时，恢复同值不会变大，应提供精细鼠标而不是虚假的恢复按钮。
    this.canRestore=state.canRestore && this.target!==state.requested &&
      calculateMinecraftGuiScale(state.framebufferWidth,state.framebufferHeight,this.target,state.unicode,state.legacy)>state.effective
    this.accepted=state.requested
    return true
  }
  keep(state: GameGuiState): void { this.accepted=state.requested; this.previous=state.requested }
}

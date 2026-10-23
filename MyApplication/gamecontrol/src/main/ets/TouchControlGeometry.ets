/** 游戏控件与教学共用的vp几何。输入是已投影布局和实际surface尺寸，不使用设备全屏尺寸。 */
import { ControlItem, LayoutProfile, HOTBAR_SLOT_COUNT } from './ControlLayout'

export class TouchControlRect {
  x: number=0
  y: number=0
  width: number=0
  height: number=0
  contains(x: number,y: number): boolean {
    return x>=this.x && y>=this.y && x<this.x+this.width && y<this.y+this.height
  }
}
export function touchControlX(item: ControlItem,width: number): number { return item.xPct*width }
export function touchControlY(item: ControlItem,height: number): number { return item.yPct*height }
export function touchControlWidth(item: ControlItem,profile: LayoutProfile): number { return item.baseWidth*item.itemScale*profile.globalScale }
export function touchControlHeight(item: ControlItem,profile: LayoutProfile): number { return item.baseHeight*item.itemScale*profile.globalScale }
export function touchControlRect(item: ControlItem,profile: LayoutProfile,width: number,height: number): TouchControlRect {
  const rect: TouchControlRect=new TouchControlRect()
  rect.x=touchControlX(item,width); rect.y=touchControlY(item,height)
  rect.width=touchControlWidth(item,profile); rect.height=touchControlHeight(item,profile)
  return rect
}
/** 半开区间与游戏快捷栏一致；越界手指不吸附最近格，避免误选。 */
export function touchHotbarSlot(x: number,y: number,width: number,height: number): number {
  if(!Number.isFinite(x) || !Number.isFinite(y) || width<=0 || height<=0 || x<0 || y<0 || x>=width || y>=height) return -1
  return Math.floor(x/(width/HOTBAR_SLOT_COUNT))
}

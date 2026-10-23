/** 教学的共享视口几何。绘制与Native工具栏排除区复用同一结果，不依赖设备型号或整屏像素猜测。 */
import { TouchControlRect } from './TouchControlGeometry'
import { TouchGuideStep } from './TouchGuide'

export class TouchGuideLayout {
  compact: boolean=false
  menuRail: boolean=false
  toolbar: TouchControlRect=new TouchControlRect()
  card: TouchControlRect=new TouchControlRect()
}

/** 手机菜单使用底角简短提示；真实目标旁的提示保持间隔，所有矩形限制在可用视口。 */
export function touchGuideLayout(width: number,height: number,step: number,grabbed: boolean,target: TouchControlRect): TouchGuideLayout {
  const layout: TouchGuideLayout=new TouchGuideLayout()
  if(!Number.isFinite(width) || !Number.isFinite(height) || width<=0 || height<=0) return layout
  layout.compact=Math.min(width,height)<480
  layout.menuRail=layout.compact && !grabbed
  const gap: number=Math.min(8,width/4,height/4)
  layout.toolbar.width=Math.min(layout.compact ? 240 : 320,Math.max(0,width-gap*2))
  layout.toolbar.height=Math.min(52,Math.max(0,height-gap*2))
  layout.toolbar.x=(width-layout.toolbar.width)/2
  layout.toolbar.y=Math.min(12,Math.max(0,height-layout.toolbar.height))
  layout.card.width=Math.min(layout.compact ? 224 : 320,Math.max(0,width-gap*2))
  layout.card.height=Math.min(layout.menuRail ? 60 : layout.compact ? 100 : 160,Math.max(0,height-gap*2))
  const maxX: number=Math.max(gap,width-layout.card.width-gap)
  const maxY: number=Math.max(gap,height-layout.card.height-gap)
  if(step===TouchGuideStep.Menu || step===TouchGuideStep.Scroll) {
    layout.card.x=gap; layout.card.y=layout.menuRail ? maxY : Math.min(84,maxY)
  } else if(step===TouchGuideStep.Hotbar) {
    layout.card.x=Math.max(gap,Math.min(maxX,target.x+target.width/2-layout.card.width/2))
    layout.card.y=Math.max(gap,Math.min(maxY,target.y-layout.card.height-12))
  } else {
    const right: number=target.x+target.width+12
    layout.card.x=right+layout.card.width<=width-gap ? right : Math.max(gap,target.x-layout.card.width-12)
    layout.card.x=Math.min(maxX,layout.card.x)
    layout.card.y=Math.max(gap,Math.min(maxY,Math.max(layout.toolbar.y+layout.toolbar.height+8,target.y-12)))
  }
  return layout
}

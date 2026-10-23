/** entry平台接线。面板实例具有独立owner前缀；失焦/抓取改变后Native也会强制收回菜单持有。 */
import testNapi from 'libentry.so'
import { VirtualMouseModel, VirtualMousePort, RuntimeTouchContext } from 'gamecontrol'

let nextMousePanel: number=1
/** 实例序号在当前JS进程单调增长，Native用其拒绝同publication下旧实例迟到注册；精度耗尽时拒绝创建输入域。 */
function allocateMousePanelPrefix(): string {
  if(!Number.isSafeInteger(nextMousePanel) || nextMousePanel<1) return ''
  return 'mouse-panel-'+(nextMousePanel++).toString()+':'
}
export class EntryVirtualMouse {
  readonly model: VirtualMouseModel
  private enabled: boolean=false
  private density: number=1
  private boundsKey: string=''
  private contextKey: string=''
  private publicationToken: string=''
  private prefix: string=allocateMousePanelPrefix()
  constructor() {
    const port: VirtualMousePort={
      move:(dx: number,dy: number): boolean => {
        if(!this.enabled) return false
        try { return testNapi.moveTouchMenuPointer(dx*this.density,dy*this.density,this.publicationToken,this.prefix) }
        catch (_) { return false }
      },
      wheel:(steps: number): boolean => {
        if(!this.enabled) return false
        try { return testNapi.touchMenuScroll(Math.max(-32,Math.min(32,steps)),this.publicationToken,this.prefix) }
        catch (_) { return false }
      },
      button:(owner: string,code: number,down: boolean): boolean => {
        if(down && !this.enabled) return false
        try { return testNapi.touchMenuButton(this.prefix+owner,code,down,this.publicationToken) }
        catch (_) { return false }
      },
      // 取消没有新按下准入门；后台/关闭后仍必须能退休旧工具事务，不能因enabled=false拒绝收口。
      cancel:(): boolean => {
        if(this.prefix.length===0) return true
        try { return testNapi.cancelTouchMenuMouse(this.prefix) }
        catch (_) { return false }
      }
    }
    this.model=new VirtualMouseModel(port)
  }
  /** active只接受页面真实菜单态；关闭时先取消工具事务，再撤销新按下。 */
  configure(active: boolean,density: number): void {
    if(!active) this.model.cancelAll()
    this.enabled=active && this.prefix.length>0; this.density=Number.isFinite(density) && density>0 ? density : 1
  }
  /** 工具鼠标只能使用当前呈现的publication和同一context；更新身份不自行认领新owner。 */
  setRuntimeContext(context: RuntimeTouchContext, publicationToken: string): void {
    this.contextKey = context.key; this.publicationToken = publicationToken
    if (context.valid) this.density = context.density
    else this.configure(false, 1)
  }
  /** 单独发布本体的移动排除区，避免重建schema打断持续按键；坐标从vp统一转成surface px。 */
  bounds(x: number,y: number,width: number,height: number): void {
    const key: string=[this.contextKey,this.publicationToken,x,y,width,height,this.density].join(',')
    if(key===this.boundsKey) return
    try {
      if(testNapi.setTouchMenuMouseBounds(x*this.density,y*this.density,width*this.density,height*this.density,this.publicationToken,this.prefix)) this.boundsKey=key
    } catch (_) { this.boundsKey='' }
  }
  /** 关闭退休工具旧记录与持有；撤除面板热区不扩大成直接触屏或实体输入的复位。 */
  release(): void { this.model.cancelAll(); this.bounds(0,0,0,0); this.enabled=false }
}

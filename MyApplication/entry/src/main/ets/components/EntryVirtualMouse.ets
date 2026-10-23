/** entry平台接线。面板实例具有独立owner前缀；失焦/抓取改变后Native也会强制收回菜单持有。 */
import testNapi from 'libentry.so'
import { AppLogger } from 'commons'
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
  /** 新owner准入与原触点收尾独立；pending布局不能取消仍合法的移动和松手。 */
  private admitNew: boolean=false
  private density: number=1
  private publicationToken: string=''
  private prefix: string=allocateMousePanelPrefix()
  /** 仅记本次停用已获Native取消确认；重新启用即作废，不按held为空猜测队列已清空。 */
  private inactiveCancellationConfirmed: boolean=false
  /** 新实例从未登记范围；只有成功撤销才恢复true，异常后保留重试。活动范围不做几何缓存。 */
  private boundsCleared: boolean=true
  /** 登记失败按实例节流；不给失败确认伪造applied，也不把每16ms重试写成日志洪水。 */
  private boundsFailures: number=0
  constructor() {
    const port: VirtualMousePort={
      move:(dx: number,dy: number): boolean => {
        if(!this.enabled) return false
        try { return testNapi.moveTouchMenuPointer(dx*this.density,dy*this.density,this.publicationToken,this.prefix) }
        catch (_) { return false }
      },
      wheel:(steps: number): boolean => {
        // 模型按Native既有32格上限拆包；接线只校验，不再截断已被模型记为发送成功的行程。
        if(!this.enabled || !Number.isInteger(steps) || steps===0 || Math.abs(steps)>32) return false
        try { return testNapi.touchMenuScroll(steps,this.publicationToken,this.prefix) }
        catch (_) { return false }
      },
      button:(owner: string,code: number,down: boolean): boolean => {
        if(down && (!this.enabled || !this.admitNew)) return false
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
    this.model.setNewContactAdmission(false)
  }
  /**
   * active只代表页面、菜单和模态等真实生命周期资格，失效时才取消原工具事务。
   * admitNew只是发布等待的新DOWN门：保留已有contacts与held，让MOVE/UP按旧呈现身份收尾。
   * 默认true兼容未使用发布扩展的原调用方；真实GameControls始终传入独立准入值。
   */
  configure(active: boolean,density: number,admitNew: boolean=true): void {
    const nextEnabled: boolean=active && this.prefix.length>0
    // 停用后的16ms同步不反复退休同一作用域；失败则保持原模型和重试义务。
    // 面板系统CANCEL或上次关闭失败后即使已经重开，也须继续取得取消确认，
    // 否则模型的cancelPending会永久拦截后续输入，直到用户再次关闭。
    if ((!nextEnabled && !this.inactiveCancellationConfirmed) || this.model.isCancellationPending()) {
      const cancelled: boolean=this.model.cancelAll()
      if(!nextEnabled) this.inactiveCancellationConfirmed=cancelled
    }
    if(nextEnabled) this.inactiveCancellationConfirmed=false
    this.enabled=nextEnabled; this.density=Number.isFinite(density) && density>0 ? density : 1
    this.admitNew=this.enabled && admitNew
    this.model.setNewContactAdmission(this.admitNew)
  }
  /** 工具鼠标只能使用当前呈现的publication和同一context；更新身份不自行认领新owner。 */
  setRuntimeContext(context: RuntimeTouchContext, publicationToken: string): void {
    this.publicationToken = publicationToken
    if (context.valid) this.density = context.density
    else this.configure(false, 1)
  }
  /**
   * 单独确认本体排除区与Native登记，避免重建schema打断持续按键；坐标从vp统一转成surface px。
   * 不能只按context/token/几何相等跳过调用：按端TouchControls复位会清Native面板登记，
   * 同时保留这些值。几何缓存无法证明登记仍在，会让后续MOVE和DOWN永久被prefix检查拒绝。
   * 现有Native入口对同prefix/publication幂等，重复确认保留当前持有与工具代次；
   * 登记已退休时则重新核真实准入并恢复登记，失败不伪造成功，下一次同步继续尝试。
   */
  bounds(x: number,y: number,width: number,height: number): void {
    // 只去重已确认的撤销/从未登记；正尺寸仍每次进入Native，保留按端reset后的恢复能力。
    // false回执不改变确认状态，异常也不能当作没有发生副作用，因此下一次继续撤销。
    const clearing: boolean=width===0 && height===0
    if(clearing && this.boundsCleared) return
    try {
      if(testNapi.setTouchMenuMouseBounds(x*this.density,y*this.density,width*this.density,height*this.density,this.publicationToken,this.prefix)) {
        this.boundsCleared=clearing
      }
    } catch (error) {
      this.boundsCleared=false
      this.boundsFailures++
      if ((this.boundsFailures & (this.boundsFailures-1)) === 0) {
        try { AppLogger.warn('VirtualMouse', '面板范围登记失败，保留原确认状态并等待重试：' +
          'count=' + this.boundsFailures, error) } catch (_) { /* 诊断失败仍允许原触点安全收口。 */ }
      }
    }
  }
  /** 关闭退休工具旧记录与持有；撤除面板热区不扩大成直接触屏或实体输入的复位。 */
  release(): void {
    this.configure(false,this.density,false); this.bounds(0,0,0,0)
  }
}

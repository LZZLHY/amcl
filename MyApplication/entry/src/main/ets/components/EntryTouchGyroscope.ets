/**
 * 触控陀螺仪订阅生命周期。只有页面活跃、游戏抓取且用户策略允许时订阅，失败保持纯触摸可用。
 * 每次配置/方向/代次变化退休旧回调；off只移除自己的回调，不影响进程里其它传感器使用者。
 */
import { sensor } from '@kit.SensorServiceKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import testNapi from 'libentry.so'
import { TouchConfiguration, TouchGyroscopeIntegrator, TouchGyroscopeDelta } from 'gamecontrol'

export class EntryTouchGyroscope {
  private status: string='idle'
  /** UI只读能力/订阅状态，失败不再只能通过日志发现。 */
  currentStatus(): string { return this.status }
  private signature: string = ''
  private generation: number = 0
  private callback: ((sample: sensor.GyroscopeResponse) => void) | undefined = undefined
  /** Native原policy/resource流的opaque句柄；不把sensor timestamp当跨时钟退休身份。 */
  private lease: string = ''
  /** 原Native退休未确认时保留单一墓碑；禁止新流借用旧资格或让未知false变成成功。 */
  private pendingRetirement: string = ''
  private retirementWarningEmitted: boolean = false
  /** 平台off异常不证明原订阅消失；独立保留失权原callback，只能具名重试它。 */
  private pendingUnsubscription: ((sample: sensor.GyroscopeResponse) => void) | undefined = undefined
  private unsubscribeWarningEmitted: boolean = false
  /** 清理边缘可同步回入stop/configure；同一原资源不能递归off或在清理未返回时再订阅。 */
  private cleaning: boolean = false
  private integrator: TouchGyroscopeIntegrator = new TouchGyroscopeIntegrator()
  private configuring: boolean = false

  /**
   * 返回本次实际完成：开启须取得原Native lease且sensor.on成功返回；关闭须确认原lease
   * 退休且原平台callback完成具名退订。相同签名只复用真实完成，不把Pending/Unavailable
   * 或旧active签名当新定义Applied；日志只观察结果，不决定订阅的成功与失败。
   * 不可用设备仍按原显式配置/context边界重试，不增加时钟或每帧盲建流。
   */
  configure(enabled: boolean, options: TouchConfiguration, rotation: number, schemaGeneration: number): boolean {
    // 同步外部回入只让原调用完成/退休，不递归创建另一条传感器流。
    if (this.configuring) return false
    this.configuring=true
    try { return this.configureCurrent(enabled,options,rotation,schemaGeneration) }
    finally { this.configuring=false }
  }

  private configureCurrent(enabled: boolean, options: TouchConfiguration, rotation: number, schemaGeneration: number): boolean {
    const originalGeneration: number=this.generation
    if (!this.reconcileCleanup()) return false
    let context: string = ''
    let contextReadFailed: boolean = false
    if (enabled && schemaGeneration>0 && typeof testNapi.touchGyroLeaseContext === 'function') {
      try { context = testNapi.touchGyroLeaseContext() }
      catch (_) { contextReadFailed = true }
    }
    if (originalGeneration!==this.generation) return false
    const signature: string = JSON.stringify([enabled,options.gyroscopeMode,options.gyroscopeSensitivity,
      options.gyroscopeInvertX,options.gyroscopeInvertY,rotation,schemaGeneration,context,contextReadFailed])
    if (signature===this.signature) return enabled ? this.status==='active' : this.status==='idle'
    this.stop()
    if (this.pendingRetirement.length>0 || this.pendingUnsubscription!==undefined) return false
    this.signature=signature
    if (!enabled) { this.status='idle'; return true }
    if (schemaGeneration<=0) { this.status='pending'; return false }
    const leased: boolean = typeof testNapi.beginTouchGyroLease === 'function' &&
      typeof testNapi.submitTouchGyroLease === 'function' && typeof testNapi.retireTouchGyroLease === 'function'
    // 新执行契约需要原Native lease；不因一次NotReady/缺端口改走无资格的旧timestamp路径。
    if (!leased && typeof testNapi.sharedLookExecutionSupported === 'function') { this.status='unavailable'; return false }
    if (!leased && typeof testNapi.sendTouchGyroSample !== 'function') { this.status='unavailable'; return false }
    let lease: string = ''
    const acquisitionGeneration: number=this.generation
    if (leased) {
      // 端口异常是可观察的Unavailable；纯资源未Ready是Pending，二者都不借旧无lease入口。
      if (typeof testNapi.touchGyroLeaseContext !== 'function' || context.length===0) {
        this.status=contextReadFailed ? 'unavailable' : 'pending'; return false
      }
      try { lease = testNapi.beginTouchGyroLease(schemaGeneration) }
      catch (_) { this.status='unavailable'; return false }
      if (lease.length===0) { this.status='pending'; return false }
      if (acquisitionGeneration!==this.generation) {
        // begin返回时原来源已停止。返来的原token只能退休，不能成为后来订阅资格。
        this.pendingRetirement=lease; this.retirementWarningEmitted=false
        this.reconcileCleanup(); return false
      }
      this.lease = lease
    }
    const generation: number = ++this.generation
    const callback: (sample: sensor.GyroscopeResponse) => void = (sample: sensor.GyroscopeResponse): void => {
      if (generation!==this.generation) return
      const delta: TouchGyroscopeDelta | undefined = this.integrator.sample(sample.x,sample.y,sample.timestamp,
        rotation,options.gyroscopeSensitivity,options.gyroscopeInvertX,options.gyroscopeInvertY)
      if (delta===undefined || (delta.dx===0 && delta.dy===0)) return
      try {
        if (leased) {
          // delta已由原sensor STARTUP样本完成梯形积分；Native只加工/封序，不再乘dt。
          // SDK timestamp为number，用于该流顺序，opaque lease才是无损资格身份。
          if (!testNapi.submitTouchGyroLease(lease,delta.dx,delta.dy,delta.timeNs)) {
            this.stop(); this.signature=signature
            if (this.pendingRetirement.length===0 && this.pendingUnsubscription===undefined) this.status='retired'
          }
        } else testNapi.sendTouchGyroSample(delta.dx,delta.dy,delta.timeNs,schemaGeneration)
      }
      catch (_) { this.stop(); this.signature=signature }
    }
    this.callback=callback
    try {
      // 官方game频率为20ms；实际周期由传感器硬件决定，积分始终使用样本timestamp。
      sensor.on(sensor.SensorId.GYROSCOPE,callback,{ interval: 20000000 })
    } catch (error) {
      if (generation!==this.generation || this.callback!==callback) return false
      this.stop()
      this.signature=signature
      if (this.pendingRetirement.length===0 && this.pendingUnsubscription===undefined) this.status='unavailable'
      this.reportWarning('Touch gyroscope unavailable: %{public}s',error)
      return false
    }
    // 外部sensor边缘可同步停止/换配置。只有原回调代和lease仍属于本次才确认完成，
    // 旧configure续体不得把后来stop/另一订阅的状态重新写active。
    if (generation!==this.generation || this.callback!==callback || (leased && this.lease!==lease)) return false
    this.status='active'
    try { hilog.info(0x0000,'GameControls','Touch gyroscope subscribed; mode=%{public}s',options.gyroscopeMode) }
    catch (_) { /* 诊断失败不退休已成功的订阅，也不重新sensor.on。 */ }
    // 日志同样可能同步回入原停止边缘；失败本身无应用权，真实失权仍须拒绝旧完成。
    return generation===this.generation && this.callback===callback && (!leased || this.lease===lease)
  }

  /** 原停源结果只读：回入中的begin/on仍未收口，不能凭本地callback已撤销写Completed。 */
  stoppedCleanupComplete(): boolean {
    return !this.configuring && !this.cleaning && this.callback===undefined && this.lease.length===0 &&
      this.pendingRetirement.length===0 && this.pendingUnsubscription===undefined
  }

  /** 只重试已围栏的原callback/token；不configure、重订阅或capture后来Native资源。 */
  reconcileStoppedCleanup(): boolean {
    if (this.configuring || this.callback!==undefined || this.lease.length>0) return false
    this.reconcileCleanup()
    return this.stoppedCleanupComplete()
  }

  /** 先使迟到回调失效，再退订；即使平台off失败也不允许旧传感器数据继续发游戏输入。 */
  stop(): void {
    this.generation++
    const callback = this.callback
    const lease: string = this.lease
    this.callback=undefined
    this.lease=''
    this.integrator.reset()
    if(this.status==='active') this.status='idle'
    // 原Native句柄先进入本对象唯一退休墓碑，再调用可能失败/回入的平台off与诊断。
    // 因此即使退订和日志同时抛错，原回调已失权，原lease也不会因清空active字段而丢失。
    if (lease.length>0) { this.pendingRetirement=lease; this.retirementWarningEmitted=false }
    if (callback!==undefined) {
      this.pendingUnsubscription=callback; this.unsubscribeWarningEmitted=false
    }
    this.reconcileCleanup()
    this.signature=''
  }

  /**
   * 两个独立原资源都确认结束才完成关闭。平台off未知仍继续退休Native lease，防止
   * 诊断/平台异常夺走Native清理；Native已确认也不能代证平台订阅已解除。只复用原
   * 显式stop/configure及既有维护边缘，不加时钟；查询currentStatus不会进入此方法。
   */
  private reconcileCleanup(): boolean {
    if (this.cleaning) return false
    this.cleaning=true
    try {
      this.reconcileUnsubscription()
      this.reconcileRetirement()
      if (this.pendingRetirement.length>0) { this.status='retirement-pending'; return false }
      if (this.pendingUnsubscription!==undefined) { this.status='unsubscribe-pending'; return false }
      if (this.status==='retirement-pending' || this.status==='unsubscribe-pending') this.status='idle'
      return true
    } finally { this.cleaning=false }
  }

  /** 原callback按对象身份重试off；异常保留资格已失效的句柄，不执行无callback的全域退订。 */
  private reconcileUnsubscription(): boolean {
    const original: ((sample: sensor.GyroscopeResponse) => void) | undefined = this.pendingUnsubscription
    if (original===undefined) return true
    try {
      sensor.off(sensor.SensorId.GYROSCOPE,original)
      if (this.pendingUnsubscription===original) this.pendingUnsubscription=undefined
    } catch (error) {
      if (!this.unsubscribeWarningEmitted) {
        this.unsubscribeWarningEmitted=true
        this.reportWarning('Touch gyroscope unsubscribe failed: %{public}s',error)
      }
    }
    return this.pendingUnsubscription===undefined
  }

  /**
   * 只查询/结束原opaque资格。Native对真正签发且已失效的原token幂等true，陌生token或
   * owner不可用false；JS因此不能删除失败墓碑，或根据当前schema/policy重新造句柄。
   * 没有新流时最多一个待退休token，失败可由currentStatus观察，恢复后才允许新订阅。
   */
  private reconcileRetirement(): boolean {
    if (this.pendingRetirement.length===0) return true
    const original: string = this.pendingRetirement
    let confirmed: boolean = false
    try { confirmed = typeof testNapi.retireTouchGyroLease==='function' && testNapi.retireTouchGyroLease(original) }
    catch (error) {
      if (!this.retirementWarningEmitted) {
        this.retirementWarningEmitted=true
        this.reportWarning('Touch gyroscope lease retirement pending: %{public}s',error)
      }
    }
    if (!confirmed) return false
    if (this.pendingRetirement===original) this.pendingRetirement=''
    return true
  }

  /**
   * 日志只有观察权。平台/Native清理失败先由原句柄和状态保留，诊断端口异常不能
   * 中断后续退休或把Pending改成成功；本方法只报告是否写日志，不补另一轮外部调用。
   */
  private reportWarning(message: string, error: Object): boolean {
    try {
      hilog.warn(0x0000,'GameControls',message,String(error))
      return true
    } catch (_) { return false }
  }
}

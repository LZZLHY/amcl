/**
 * PhysicalPointerEcho.ets — 物理光标位置回声：菜单里区分"鼠标镜像触点"与真手指
 *
 * ============================ 它解决什么问题 ============================
 *
 * 架构上物理鼠标与屏幕虚拟按键是两个**并列**的输入端，鼠标不该激活虚拟控件。
 * 但菜单态按设计**不**锁光标，此时平台会把鼠标主键镜像成 TouchEvent 直接投给 ArkUI，
 * 于是鼠标能点到虚拟按键 —— 而"两个并列输入端"要求它不能。
 *
 * ============================ 为什么不能靠事件元数据判别 ============================
 *
 * 这是真机**已证伪**的路线，不要再走一遍：
 *   · native `OH_NativeXComponent_GetTouchEventSourceType` 对 618/618 个包都返回
 *     TOUCHSCREEN，鼠标合成包也一样；
 *   · ArkUI 只承诺"鼠标主键会变成 TouchEvent"，**没承诺** source/sourceTool 保留鼠标身份。
 * 因此 source/sourceTool 在本机不是可判定信息。
 *
 * ============================ 可判定的信息是位置 ============================
 *
 * `onMouse` 在菜单态确实按鼠标身份上报（真机 758 个样本，source=Mouse），所以鼠标当前
 * 在窗口里的坐标是已知的。镜像出来的 TouchEvent 必然落在同一坐标上。于是判据变成
 * "这个触点是否正好落在物理光标处，且时间新鲜"。
 *
 * 误判边界是**有界且可解释**的：只有当用户的真手指恰好按在可见光标所在的几 vp 之内、
 * 且距上一次鼠标活动不到 2s 时才会被当成鼠标。反过来，元数据方案一旦判错，会让整块
 * 触摸屏在插着鼠标时失效 —— 两者的代价不在一个量级。
 *
 * ⚠️ 位置回声**只在菜单态使用**。grabbed 下用它是有害的：光标锁生效时 onMouse 会持续
 * 把位置刷成"新鲜"，于是任何落在该点 ±4vp 内的**真手指**都会被判成鼠标而被拒收 ——
 * 表现为屏幕某一小块区域的虚拟控件间歇性失灵，且极难复现定位。判据在调用方
 * （`GameControls.isPointerSourcedTouch`），不在本文件。
 *
 * ============================ 本文件的来历 ============================
 *
 * 由 `InputModeManager.ets` 拆分而来（多输入端架构改进提案 D2）。
 */

import { getInputDeviceMonitor } from './InputDeviceMonitor'

/** 物理光标位置回声的有效期（ms）。超过它就不再据此拒收触点。 */
const POINTER_ECHO_FRESH_MS: number = 2000
/** 位置重合判定的容差（vp）。镜像事件坐标与光标同源，容差只用来吸收取整。 */
const POINTER_ECHO_SLOP_VP: number = 4

class PhysicalPointerEcho {
  private echoX: number = 0
  private echoY: number = 0
  private echoTs: number = 0

  /** 由 onMouse 在每个带窗口坐标的鼠标事件上调用（Move/Hover/Press/Release 皆可）。 */
  note(windowX: number, windowY: number): void {
    if (!Number.isFinite(windowX) || !Number.isFinite(windowY)) return
    this.echoX = windowX
    this.echoY = windowY
    this.echoTs = Date.now()
  }

  /**
   * 该窗口坐标是否与最近的物理光标位置重合（即"这一触点其实是鼠标"）。
   *
   * 没有鼠标接入时恒为 false —— 纯触摸设备的行为完全不变。
   * 这条依赖设备能力，所以本模块显式依赖 InputDeviceMonitor（单向，无环）。
   */
  isLikelyPhysicalPointerAt(windowX: number, windowY: number): boolean {
    if (!getInputDeviceMonitor().hasMouse()) return false
    if (this.echoTs === 0) return false
    if (!Number.isFinite(windowX) || !Number.isFinite(windowY)) return false
    if (Date.now() - this.echoTs > POINTER_ECHO_FRESH_MS) return false
    return Math.abs(windowX - this.echoX) <= POINTER_ECHO_SLOP_VP &&
      Math.abs(windowY - this.echoY) <= POINTER_ECHO_SLOP_VP
  }
}

let echo: PhysicalPointerEcho | undefined = undefined

/** 进程内单例。HAR 作用域约束见 InputSourceRegistry.ets 的类注释。 */
export function getPhysicalPointerEcho(): PhysicalPointerEcho {
  if (!echo) echo = new PhysicalPointerEcho()
  return echo
}

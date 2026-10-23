/**
 * 悬浮鼠标的交互模型，通过端口连接真实菜单输入；本模块不依赖NAPI和Minecraft对象。
 * 按住按钮与单指锁定使用不同owner，避免抬起一指把另一个明确锁定的按钮也放开。
 */
export interface VirtualMousePort {
  move: (dx: number,dy: number) => boolean
  wheel: (steps: number) => boolean
  button: (owner: string,code: number,down: boolean) => boolean
  /** 取消只退休面板工具作用域；普通UP仍由button(false)配对，不用释放序列冒充CANCEL。 */
  cancel: () => boolean
}

/** 悬浮鼠标上的触点角色在按下时冻结，跨越左右键边界不会换键或重复点击。 */
export type VirtualMousePart = 'move' | 'left' | 'right' | 'wheel'

/** 一次按下的端口身份与输出冻结；逻辑finger编号可以复用，原生持有身份不能复用。 */
class VirtualMouseHold {
  readonly code: number
  readonly portOwner: string
  constructor(code: number,portOwner: string) { this.code=code; this.portOwner=portOwner }
}

/**
 * SDK按下时间冻结触点身份；最新窗口坐标独立保存，供移动权交接时重锚。
 * 非移动owner的位移只更新基线，不排队等待以后补发。ready仅在按键端口确认后置真。
 */
class VirtualMouseContact {
  readonly part: VirtualMousePart
  readonly pressedTime: number
  x: number
  y: number
  ready: boolean = false
  constructor(part: VirtualMousePart,pressedTime: number,x: number,y: number) {
    this.part=part; this.pressedTime=pressedTime; this.x=x; this.y=y
  }
}

/** 仅比较对象身份；reset换代后，旧同步端口回执不能投影到新一轮持有或触点。 */
class VirtualMouseLifetime { readonly marker: number = 0 }

/** 每次滚轮接触独立的发送在途标记；对象身份不随平台finger编号复用。 */
class VirtualMouseWheelFlight {
  sending: boolean = false
}

/** 本体与指针分开定位；屏幕边缘只约束本体，绝不限制指针到达角落。 */
export class FloatingMouseFrame {
  x: number = 0
  y: number = 0
  width: number = 152
  height: number = 208
  compact: boolean = false
}

/** 指针前方留出可见距离；放不下时在另一侧显示，窗口变小时仍保留关闭操作。 */
export function floatingMouseFrame(x: number,y: number,width: number,height: number): FloatingMouseFrame {
  const result: FloatingMouseFrame=new FloatingMouseFrame()
  // 使用实际视口短边，手机横屏与竖向小窗都采用136×152vp；按钮仍保留可操作触达范围。
  // 无效/未就绪视口返回空几何，不能把默认大面板发布成真实原生排除区。
  if(!Number.isFinite(width) || !Number.isFinite(height) || width<=0 || height<=0) {
    result.width=0; result.height=0; return result
  }
  result.compact=Math.min(width,height)<480
  const margin: number=Math.min(8,Math.max(0,(Math.min(width,height)-1)/2))
  result.width=Math.min(result.compact ? 136 : 152,Math.max(1,width-margin*2))
  result.height=Math.min(result.compact ? 152 : 208,Math.max(1,height-margin*2))
  const desiredX: number=x+24+result.width<=width-margin ? x+24 : x-result.width-24
  const desiredY: number=y+28+result.height<=height-margin ? y+28 : y-result.height-28
  result.x=Math.max(margin,Math.min(width-result.width-margin,desiredX))
  result.y=Math.max(margin,Math.min(height-result.height-margin,desiredY))
  return result
}

/**
 * 本体摆位的纯状态机，与游戏指针增益、按键owner和Native端口无关。
 * 单指left/right/move按真实窗口位移1:1随指；wheel稳位。第二个已接受触点加入后，
 * 本轮一直稳位到全部抬手。活动期间只做窗口钳制，不因指针反馈换侧或切换尺寸档。
 */
class VirtualMousePlacement {
  private current: FloatingMouseFrame = new FloatingMouseFrame()
  private initialized: boolean = false
  private active: boolean = false
  private frozen: boolean = false
  private followId: number = -1
  private viewportWidth: number = 0
  private viewportHeight: number = 0
  private preferredWidth: number = 152
  private preferredHeight: number = 208
  private rightSide: boolean = true
  private below: boolean = true
  /** 8vp是本轮设计起点，限制空闲临界点往返换侧；不是平台触摸阈值。 */
  private readonly sideHysteresis: number = 8

  /** 只接受模型已经认领成功的触点；重新落指不能解冻仍有按键指的协作轮次。 */
  begin(id: number,part: VirtualMousePart): void {
    if(this.active) { this.frozen=true; return }
    this.active=true; this.frozen=part==='wheel'; this.followId=id
  }
  /** 本体消耗原始vp差分，端口拒收或游戏灵敏度不改变手指与本体的几何关系。 */
  move(id: number,dx: number,dy: number): void {
    if(!this.active || this.frozen || id!==this.followId || !this.initialized) return
    this.current.x+=dx; this.current.y+=dy; this.clamp()
  }
  /** 移动指抬落期间保留冻结；只有所有工具触点结束才回到指针附近的空闲摆位。 */
  end(remaining: boolean): void {
    if(remaining) return
    this.active=false; this.frozen=false; this.followId=-1
  }
  /** 取消未确认时也保持旧本体稳位；不能以清UI缓存冒充Native已经收口。 */
  freeze(): void { this.active=true; this.frozen=true }
  /** reset确认后丢弃旧几何会话，新一轮从最新有效指针与视口重新建立。 */
  reset(): void {
    this.active=false; this.frozen=false; this.followId=-1; this.initialized=false
  }
  /** 窗口极小时仍返回有限、位于视口内部的本体；本方法从不修改游戏指针。 */
  private clamp(): void {
    const margin: number=Math.min(8,Math.max(0,(Math.min(this.viewportWidth,this.viewportHeight)-1)/2))
    this.current.width=Math.min(this.preferredWidth,Math.max(1,this.viewportWidth-margin*2))
    this.current.height=Math.min(this.preferredHeight,Math.max(1,this.viewportHeight-margin*2))
    this.current.x=Math.max(margin,Math.min(this.viewportWidth-this.current.width-margin,this.current.x))
    this.current.y=Math.max(margin,Math.min(this.viewportHeight-this.current.height-margin,this.current.y))
  }
  /** 返回独立值，调用方的显示/排除区投影不能反向篡改内部摆位状态。 */
  private snapshot(): FloatingMouseFrame {
    const value: FloatingMouseFrame=new FloatingMouseFrame()
    value.x=this.current.x; value.y=this.current.y; value.width=this.current.width
    value.height=this.current.height; value.compact=this.current.compact
    return value
  }
  /**
   * GameControls显示与Native排除区共用此唯一投影。同样输入重复读取幂等。
   * 未就绪视口发布空几何；恢复有效视口时不追补从未显示过的原始位移。
   */
  frame(x: number,y: number,width: number,height: number): FloatingMouseFrame {
    if(!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height) || width<=0 || height<=0) {
      const empty: FloatingMouseFrame=new FloatingMouseFrame(); empty.width=0; empty.height=0
      return empty
    }
    this.viewportWidth=width; this.viewportHeight=height
    if(!this.initialized) {
      this.current=floatingMouseFrame(x,y,width,height)
      this.preferredWidth=this.current.compact ? 136 : 152; this.preferredHeight=this.current.compact ? 152 : 208
      const margin: number=Math.min(8,Math.max(0,(Math.min(width,height)-1)/2))
      this.rightSide=x+24+this.current.width<=width-margin
      this.below=y+28+this.current.height<=height-margin
      this.initialized=true
    } else if(!this.active) {
      this.current.compact=Math.min(width,height)<480
      this.preferredWidth=this.current.compact ? 136 : 152; this.preferredHeight=this.current.compact ? 152 : 208
      this.clamp()
      const margin: number=Math.min(8,Math.max(0,(Math.min(width,height)-1)/2))
      const horizontalSpace: number=width-margin-x-24-this.current.width
      const verticalSpace: number=height-margin-y-28-this.current.height
      if(this.rightSide && horizontalSpace < -this.sideHysteresis) this.rightSide=false
      else if(!this.rightSide && horizontalSpace > this.sideHysteresis) this.rightSide=true
      if(this.below && verticalSpace < -this.sideHysteresis) this.below=false
      else if(!this.below && verticalSpace > this.sideHysteresis) this.below=true
      this.current.x=this.rightSide ? x+24 : x-this.current.width-24
      this.current.y=this.below ? y+28 : y-this.current.height-28
    }
    this.clamp(); return this.snapshot()
  }
}

export class VirtualMouseModel {
  private port: VirtualMousePort
  private held: Map<string,VirtualMouseHold> = new Map<string,VirtualMouseHold>()
  /** 同owner的同步端口回入不能重复发边沿；reset后旧在途对象不能覆盖同名新事务。 */
  private buttonFlights: Map<string,VirtualMouseHold> = new Map<string,VirtualMouseHold>()
  private lifetime: VirtualMouseLifetime = new VirtualMouseLifetime()
  private placement: VirtualMousePlacement = new VirtualMousePlacement()
  private holdSequence: number = 0
  /** 原生取消尚未确认时冻结旧模型，保留owner供重试，不能继续产生新点击。 */
  private cancelPending: boolean = false
  /** 布局等待只关闭新触点/新持有；已有pad与按钮的MOVE、UP继续使用原配对，不靠取消伪造零触点。 */
  private newContactAdmission: boolean = true
  private padId: number = -1
  private lastX: number = 0
  private lastY: number = 0
  private scrollId: number = -1
  private wheelFlight: VirtualMouseWheelFlight | undefined = undefined
  private scrollY: number = 0
  private remainder: number = 0
  private contacts: Map<number,VirtualMouseContact> = new Map<number,VirtualMouseContact>()

  constructor(port: VirtualMousePort) { this.port=port }
  /** 窗口vp输入、窗口vp输出；这里不混入Native density或菜单指针灵敏度。 */
  frame(x: number,y: number,width: number,height: number): FloatingMouseFrame { return this.placement.frame(x,y,width,height) }
  /** 与生命周期取消分开：临时新DOWN门不清contacts、held、padId或滚轮余量。 */
  setNewContactAdmission(admitted: boolean): void { this.newContactAdmission=admitted }
  /** 接收窗口vp坐标，组件跟随指针移动也不会使局部坐标变化被误算成第二次移动。 */
  beginContact(id: number,part: VirtualMousePart,x: number,y: number,pressedTime: number=0): boolean {
    if(this.cancelPending || !this.newContactAdmission || this.contacts.has(id) || !Number.isFinite(x) || !Number.isFinite(y) ||
      !Number.isFinite(pressedTime) || pressedTime<0) return false
    // 滚轮的起点与MOVE必须使用相同坐标边界，不能先存极大基线再让合法终点制造失控循环。
    if(part==='wheel' && Math.abs(y)>1048576) return false
    // 在端口调用前预留触点，禁止同步回入重复认领同一编号；未确认的触点不参与移动权。
    const contact: VirtualMouseContact=new VirtualMouseContact(part,pressedTime,x,y)
    this.contacts.set(id,contact)
    if(part==='left' || part==='right') {
      if(!this.press('finger-'+id.toString(),part==='left' ? -1 : -2,true)) {
        if(this.contacts.get(id)===contact) this.contacts.delete(id)
        return false
      }
    }
    // Native同步取消/reset后允许同编号重新落指，旧返回值不能复活或删除新接触。
    if(this.cancelPending || this.contacts.get(id)!==contact) return false
    contact.ready=true
    if(part==='wheel') this.startWheel(id,y)
    else {
      const owner: VirtualMouseContact | undefined=this.contacts.get(this.padId)
      if(this.padId<0 || (part==='move' && owner!==undefined && owner.part!=='move')) this.claimPad(id,x,y)
    }
    this.placement.begin(id,part)
    return true
  }
  /** 按键区域与移动区共用连续移动入口，所以一根手指即可保持左/右键拖动。 */
  moveContact(id: number,x: number,y: number,pressedTime: number=0): boolean {
    const contact: VirtualMouseContact | undefined=this.contacts.get(id)
    if(this.cancelPending || contact===undefined || !contact.ready || !this.matchesContact(contact,pressedTime) ||
      !Number.isFinite(x) || !Number.isFinite(y)) return false
    if(contact.part==='wheel' && Math.abs(y)>1048576) return false
    const dx: number=x-contact.x; const dy: number=y-contact.y
    // 等待的按键指也更新当前位置，日后接回移动权只从新基线继续，不追补等待行程。
    contact.x=x; contact.y=y; this.placement.move(id,dx,dy)
    return contact.part==='wheel' ? this.moveWheel(id,y) : this.movePad(id,x,y)
  }
  /** 真实UP只释放原触点的按钮与角色；系统CANCEL使用独立cancelAll撤销尚未消费的旧记录。 */
  endContact(id: number,pressedTime: number=0): void {
    const contact: VirtualMouseContact | undefined=this.contacts.get(id)
    if(this.cancelPending || contact===undefined || !contact.ready || !this.matchesContact(contact,pressedTime)) return
    this.press('finger-'+id.toString(),0,false)
    if(this.contacts.get(id)!==contact) return
    this.contacts.delete(id); this.endPad(id); this.endWheel(id)
    this.placement.end(this.hasReadyContacts())
  }
  activeContacts(): boolean { return this.contacts.size>0 }
  /** 几何会话只由已经接受的触点维持；端口调用前的预留仍参与发布零触点门，但不冻结本体。 */
  private hasReadyContacts(): boolean {
    let ready: boolean=false
    this.contacts.forEach((contact: VirtualMouseContact): void => { if(contact.ready) ready=true })
    return ready
  }
  /** 有SDK触点身份的取消也须匹配当前接触；旧CANCEL不能退休reset后同编号的新接触。 */
  hasContact(id: number,pressedTime: number=0): boolean {
    const contact: VirtualMouseContact | undefined=this.contacts.get(id)
    return contact!==undefined && this.matchesContact(contact,pressedTime)
  }
  /**
   * pressedTime是SDK可选的ns身份，只作相等比较，不与墙钟或采样时间混算。
   * 有双方身份时拒绝旧触点；未提供时保留框架原有闭环配对，避免因为可选元数据缺失吞掉真实UP。
   */
  private matchesContact(contact: VirtualMouseContact,pressedTime: number): boolean {
    return Number.isFinite(pressedTime) && pressedTime>=0 &&
      (contact.pressedTime===0 || pressedTime===0 || contact.pressedTime===pressedTime)
  }
  /** 调用方单位是vp；平台端口在唯一入口乘density，模型不混入surface像素换算。 */
  startPad(id: number,x: number,y: number): void {
    if (this.cancelPending || !this.newContactAdmission || this.padId>=0 || !Number.isFinite(x) || !Number.isFinite(y)) return
    this.claimPad(id,x,y)
  }
  /** 移动权与按钮持有分离；显式move接管和既有触点接续都从最新窗口坐标重锚。 */
  private claimPad(id: number,x: number,y: number): void {
    this.padId=id; this.lastX=x; this.lastY=y
  }
  movePad(id: number,x: number,y: number): boolean {
    if (this.cancelPending || id!==this.padId || !Number.isFinite(x) || !Number.isFinite(y)) return false
    const dx: number=x-this.lastX; const dy: number=y-this.lastY
    this.lastX=x; this.lastY=y
    return this.port.move(dx,dy)
  }
  /**
   * owner抬起后优先交给仍在的move指，其次仍在的按键指。布局等待只拒新DOWN，
   * 既有触点的交接继续有效；这里不能再走受newContactAdmission限制的startPad。
   */
  endPad(id: number): void {
    if(id!==this.padId) return
    this.padId=-1
    let nextId: number=-1
    let explicitMove: boolean=false
    this.contacts.forEach((contact: VirtualMouseContact,contactId: number): void => {
      if(contactId===id || !contact.ready || contact.part==='wheel') return
      if(nextId<0 || (!explicitMove && contact.part==='move')) { nextId=contactId; explicitMove=contact.part==='move' }
    })
    const next: VirtualMouseContact | undefined=this.contacts.get(nextId)
    if(next!==undefined) this.claimPad(nextId,next.x,next.y)
  }
  startWheel(id: number,y: number): void {
    if(this.cancelPending || !this.newContactAdmission || this.scrollId>=0 || !Number.isFinite(y) || Math.abs(y)>1048576) return
    this.scrollId=id; this.scrollY=y; this.remainder=0; this.wheelFlight=new VirtualMouseWheelFlight()
  }
  /**
   * 将本接触的真实滚轮位移按12vp一格累计，并按既有Native每包最多32格的合同分包。
   * 只有端口明确接受的格数才从余量扣除，避免合并MOVE经过接线限幅后悄悄丢格。
   * 拒收即停止本次发送，未接受量只允许后续同一接触的真实MOVE重试；UP/CANCEL仍由
   * endWheel/取消路径清空，绝不建立抬手后的异步续滚。坐标沿用Native的有限边界，
   * 拒绝不可信的极大值，不让单次异常样本产生无界循环或污染后续余量。
   */
  moveWheel(id: number,y: number): boolean {
    const flight: VirtualMouseWheelFlight | undefined=this.wheelFlight
    if(this.cancelPending || id!==this.scrollId || flight===undefined || !Number.isFinite(y) || Math.abs(y)>1048576) return false
    const accumulated: number=this.remainder+y-this.scrollY
    if(!Number.isFinite(accumulated)) return false
    this.scrollY=y; this.remainder=accumulated
    // 同接触的同步回入只积入真实新位移；原在途循环取得回执后统一扣量，不能重复发送旧包。
    if(flight.sending) return false
    let emitted: boolean=false
    flight.sending=true
    try {
      while(Math.abs(this.remainder)>=12) {
        const pending: number=Math.trunc(this.remainder/12)
        const packet: number=Math.max(-32,Math.min(32,pending))
        if(!this.port.wheel(packet)) break
        // 同步取消后平台可立即复用同一个id；只认原接触对象，旧回执不能扣新接触余量或续发。
        if(this.cancelPending || this.wheelFlight!==flight) return true
        this.remainder-=packet*12; emitted=true
      }
    } finally { flight.sending=false }
    return emitted
  }
  endWheel(id: number): void { if(id===this.scrollId) { this.scrollId=-1; this.remainder=0; this.wheelFlight=undefined } }
  stepWheel(direction: number): boolean { return !this.cancelPending && this.newContactAdmission && this.port.wheel(direction<0 ? -1 : 1) }
  /** 入端失败不投影为已按下；UP只释放这个owner，不重新读取布局或键位。 */
  press(owner: string,code: number,down: boolean): boolean {
    if(this.cancelPending || this.buttonFlights.has(owner)) return false
    if(down) {
      if(!this.newContactAdmission) return false
      const existing: VirtualMouseHold | undefined=this.held.get(owner)
      if(existing!==undefined) return existing.code===code
      // 序号仅在实例内增长，原生复位/关闭不回拨。失败也不复用已经保留给端口的身份。
      // 到达安全整数上限时明确拒绝，不把精度丢失造成的字符串碰撞传给原生owner集合。
      if(this.holdSequence>=Number.MAX_SAFE_INTEGER) return false
      const portOwner: string=owner+'#'+(++this.holdSequence).toString()
      const hold: VirtualMouseHold=new VirtualMouseHold(code,portOwner)
      const lifetime: VirtualMouseLifetime=this.lifetime
      this.buttonFlights.set(owner,hold)
      let accepted: boolean=false
      try { accepted=this.port.button(portOwner,code,true) }
      finally { if(this.buttonFlights.get(owner)===hold) this.buttonFlights.delete(owner) }
      // 返回true只表示原端口接受过边沿；同步reset/cancel已退休原事务时不能重新投影held。
      if(!accepted || this.cancelPending || this.lifetime!==lifetime) return false
      this.held.set(owner,hold); return true
    }
    const old: VirtualMouseHold | undefined=this.held.get(owner)
    if(old===undefined) return true
    this.buttonFlights.set(owner,old)
    let released: boolean=false
    try { released=this.port.button(old.portOwner,old.code,false) }
    finally { if(this.buttonFlights.get(owner)===old) this.buttonFlights.delete(owner) }
    if(!released) return false
    // 旧UP回执不能删除reset后同逻辑owner已经建立的新按下。
    if(this.held.get(owner)===old) this.held.delete(owner)
    return true
  }
  toggle(code: number): boolean { const id: string='lock-'+code.toString(); return this.press(id,code,!this.held.has(id)) }
  locked(code: number): boolean { return this.held.has('lock-'+code.toString()) }
  down(code: number): boolean { let result: boolean=false; this.held.forEach((value: VirtualMouseHold): void => {if(value.code===code) result=true}); return result }
  /** 明确要求普通释放时逐owner配对；关面板/后台/系统取消必须走cancelAll，而非生成点击式UP。 */
  releaseAll(): void {
    // 普通释放无法证明同步在途DOWN是否已被端口接受，交由真正的工具取消完成该边界。
    if(this.cancelPending || this.buttonFlights.size>0) { this.cancelAll(); return }
    this.padId=-1; this.scrollId=-1; this.remainder=0; this.wheelFlight=undefined; this.contacts.clear()
    this.placement.reset()
    const owners: string[]=Array.from(this.held.keys())
    for(const owner of owners) this.press(owner,this.held.get(owner)?.code ?? 0,false)
  }
  /**
   * 原生先推进工具取消身份，消费端能丢弃尚未poll的PRESS/RELEASE，或仅撤销已提交的工具贡献。
   * 成功回执后才清缓存；失败保持持有和禁止新操作，父层关闭/配置心跳可再次重试。
   */
  cancelAll(): boolean {
    const lifetime: VirtualMouseLifetime=this.lifetime
    this.cancelPending=true; this.placement.freeze()
    if(!this.port.cancel()) return false
    // 原取消调用期间同步reset已经换代时，原回执不能再次清理随后建立的新接触。
    if(this.lifetime===lifetime) this.acknowledgeReset()
    return true
  }
  /** 父层同步只重试未确认取消；重新启用不能跳过此义务，也不能把pending误当作可重新按下。 */
  isCancellationPending(): boolean { return this.cancelPending }
  /** 只有父级已确认native触控域复位时调用，不能靠清UI缓存伪装释放成功。 */
  acknowledgeReset(): void {
    this.lifetime=new VirtualMouseLifetime(); this.buttonFlights.clear(); this.held.clear()
    this.padId=-1; this.scrollId=-1; this.remainder=0; this.wheelFlight=undefined; this.contacts.clear()
    this.placement.reset(); this.cancelPending=false
  }
}

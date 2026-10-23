/** 游戏内引导只观察真实输入结果，不发送按键、不暂停游戏，也不维护另一套触控解释器。 */
export enum TouchGuideStep { Move=0, Hotbar=1, Menu=2, Scroll=3, Mouse=4, Edit=5, Done=6 }

/** 生产输入出口的累计反馈。序号防止把打开引导之前的操作算成教学成果。 */
export class TouchGuideFeedback {
  available: boolean=false
  grabbed: boolean=false
  fingers: number=0
  movement: number=0
  hotbar: number=0
  slot: number=-1
  scroll: number=0
  scrollAmount: number=0
  mouseMove: number=0
  mouseButton: number=0
  mouseCode: number=0
  generation: number=0
}

/** 前15项保持原视觉ABI；教学只在新的完整只读快照可用时启动，不猜测缺失反馈。 */
export function parseTouchGuideFeedback(values: number[]): TouchGuideFeedback {
  const result: TouchGuideFeedback=new TouchGuideFeedback()
  if(values.length<25 || values.some((value: number): boolean => !Number.isFinite(value)) ||
    !Number.isInteger(values[23]) || values[23]<0 || values[23]>10 || (values[24]!==0 && values[24]!==1) ||
    !Number.isInteger(values[17]) || values[17]<-1 || values[17]>8 ||
    (values[22]!==0 && values[22]!==-1 && values[22]!==-2)) return result
  for(const index of [12,15,16,18,20,21]) if(!Number.isSafeInteger(values[index]) || values[index]<0) return result
  result.available=true; result.grabbed=values[24]===1; result.fingers=values[23]; result.generation=values[12]
  result.movement=values[15]; result.hotbar=values[16]; result.slot=values[17]
  result.scroll=values[18]; result.scrollAmount=values[19]; result.mouseMove=values[20]
  result.mouseButton=values[21]; result.mouseCode=values[22]
  return result
}

export class TouchGuide {
  active: boolean=false
  step: TouchGuideStep=TouchGuideStep.Move
  private movementBase: number=0
  private hotbarBase: number=0
  private scrollBase: number=0
  private scrollAmountBase: number=0
  private mouseMoveBase: number=0
  private mouseButtonBase: number=0
  private generation: number=0

  /** 首次教学必须已经进入游戏相对视角状态且没有在途手指；标题菜单不能启动。 */
  start(feedback: TouchGuideFeedback): boolean {
    if(!feedback.available || !feedback.grabbed || feedback.fingers!==0) return false
    this.active=true; this.step=TouchGuideStep.Move; this.baseline(feedback); return true
  }
  stop(): void { this.active=false }
  /** 页面/输入资格中断后重建基线，旧手势或旧schema的结果不能在新页面被追认为完成。 */
  baseline(feedback: TouchGuideFeedback): void {
    this.movementBase=feedback.movement; this.hotbarBase=feedback.hotbar
    this.scrollBase=feedback.scroll; this.scrollAmountBase=feedback.scrollAmount
    this.mouseMoveBase=feedback.mouseMove; this.mouseButtonBase=feedback.mouseButton; this.generation=feedback.generation
  }
  /** 用户先打开真实可滚动列表，再开始本课；不把普通生存背包当成可滚动界面。 */
  beginScroll(feedback: TouchGuideFeedback,enabled: boolean): boolean {
    if(!this.active || this.step!==TouchGuideStep.Menu || feedback.grabbed || !enabled || feedback.fingers!==0) return false
    this.step=TouchGuideStep.Scroll; this.baseline(feedback); return true
  }
  skip(feedback: TouchGuideFeedback): void {
    if(!this.active) return
    this.step=this.step>=TouchGuideStep.Mouse ? TouchGuideStep.Done : this.step+1
    this.baseline(feedback)
  }
  /** 自动推进总在抬手后发生；关闭遮罩不结束用户自己仍在按住的真实游戏操作。 */
  observe(feedback: TouchGuideFeedback): boolean {
    if(!this.active || !feedback.available) return false
    if(this.generation!==feedback.generation) { this.baseline(feedback); return false }
    if(feedback.fingers!==0) return false
    let complete: boolean=false
    if(this.step===TouchGuideStep.Move) complete=feedback.grabbed && feedback.movement>this.movementBase
    else if(this.step===TouchGuideStep.Hotbar) complete=feedback.grabbed && feedback.hotbar>this.hotbarBase && feedback.slot===4
    else if(this.step===TouchGuideStep.Scroll) complete=!feedback.grabbed && feedback.scroll>this.scrollBase &&
      Math.abs(feedback.scrollAmount-this.scrollAmountBase)>=2
    else if(this.step===TouchGuideStep.Mouse) complete=!feedback.grabbed && feedback.mouseMove>this.mouseMoveBase &&
      feedback.mouseButton>this.mouseButtonBase && feedback.mouseCode===-2
    if(complete) { this.skip(feedback); return true }
    return false
  }

}

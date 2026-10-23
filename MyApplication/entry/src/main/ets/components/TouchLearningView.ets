/**
 * 真实游戏上的半透明教学层。只绘制遮罩、指针和文字；真实摇杆、快捷栏、菜单始终由原输入系统处理。
 * 除顶部工具栏外全部不参与命中，工具栏矩形由GameControls登记为ArkUI排除区。
 * 示范手只做视觉动画，不驱动真实控件；进度完全由宿主观察到的真实输入反馈决定。
 */
import { TouchControlRect, TouchGuideStep, TouchGuideLayout, touchGuideLayout } from 'gamecontrol'

@Component
export struct TouchLearningView {
  @Prop @Watch('restartAnimation') step: number=TouchGuideStep.Move
  @Prop @Watch('refreshAnimation') active: boolean=true
  @Prop @Watch('refreshAnimation') fingers: number=0
  @Prop @Watch('refreshAnimation') grabbed: boolean=true
  @Prop mouseOpen: boolean=false
  @Prop scrollEnabled: boolean=true
  @Prop viewWidth: number=720
  @Prop viewHeight: number=400
  @Prop target: TouchControlRect=new TouchControlRect()
  @Prop toolbarX: number=200
  @Prop navigationKind: number=0
  @Prop navigationScrollable: boolean=false
  @Prop navigationScrollKnown: boolean=false
  /** 工具栏意图带本组件实际呈现的publication资格，不能由父层事后读取最新global token。 */
  @Prop publicationToken: string=''
  onClose: (token: string) => void=(_token: string): void => {}
  onSkip: (token: string) => void=(_token: string): void => {}
  onBeginScroll: (token: string) => void=(_token: string): void => {}
  @State private phase: number=0
  private timer: number=-1
  private startedAt: number=0
  private mounted: boolean=false

  aboutToAppear(): void { this.mounted=true; this.restartAnimation() }
  /** 销毁只停止自己的动画，绝不释放用户真实按键、鼠标或编辑器的暂停租约。 */
  aboutToDisappear(): void { this.mounted=false; this.stopAnimation() }
  private stopAnimation(): void { if(this.timer!==-1) { clearInterval(this.timer); this.timer=-1 } }
  private restartAnimation(): void { this.phase=0; this.startedAt=Date.now(); this.stopAnimation(); this.refreshAnimation() }
  /** 只有摇杆和双指滑动需要持续示范；菜单导航没有确定目标，不开动画时钟。 */
  private needsAnimation(): boolean {
    return (this.step===TouchGuideStep.Move && this.grabbed) ||
      (this.step===TouchGuideStep.Scroll && !this.grabbed)
  }
  /** 用户触摸时隐藏示范手让出视线；后台/退出零动画时钟，不额外轮询游戏。 */
  private refreshAnimation(): void {
    if(!this.mounted || !this.active || this.fingers>0 || !this.needsAnimation()) { this.stopAnimation(); return }
    if(this.timer!==-1) return
    this.startedAt=Date.now()
    this.timer=setInterval((): void => {
      if(!this.mounted || !this.active || this.fingers>0 || !this.needsAnimation()) { this.stopAnimation(); return }
      this.phase=((Date.now()-this.startedAt)%2800)/2800
    },32) as number
  }
  private validTarget(): boolean { return this.target.width>0 && this.target.height>0 }
  /** 菜单准备仅对已回读的真实导航按钮画指针；未知页面不把任意中心假装成按钮。 */
  private pointAtTarget(): boolean {
    return this.validTarget() && !(this.step===TouchGuideStep.Menu && !this.grabbed &&
      this.navigationKind!==1 && this.navigationKind!==2)
  }
  private focusX(): number { return Math.max(0,this.target.x-10) }
  private focusY(): number { return Math.max(0,this.target.y-10) }
  private focusWidth(): number { return Math.max(0,Math.min(this.viewWidth-this.focusX(),this.target.width+20)) }
  private focusHeight(): number { return Math.max(0,Math.min(this.viewHeight-this.focusY(),this.target.height+20)) }
  /** 卡片和工具栏使用共享几何，手机菜单提示缩成角落短条，触摸期间让出文字视线。 */
  private layout(): TouchGuideLayout { return touchGuideLayout(this.viewWidth,this.viewHeight,this.step,this.grabbed,this.target) }
  private cardWidth(): number { return this.layout().card.width }
  /** 提示尽量放在目标旁，快捷栏提示位于上方；真实游戏内容始终保留在半透明层下面。 */
  private cardX(): number {
    return this.layout().card.x
  }
  private cardY(): number {
    return this.layout().card.y
  }
  /** 帮助只有五个实际步骤；旧记录中的编辑阶段编号不要求用户修改布局。 */
  private progressLabel(): string { return Math.min(5,this.step+1).toString()+' / 5' }
  private title(): string {
    if(this.step===TouchGuideStep.Move) return '试着移动'
    if(this.step===TouchGuideStep.Hotbar) return '选择手中物品'
    if(this.step===TouchGuideStep.Menu) return '进入可滚动菜单'
    if(this.step===TouchGuideStep.Scroll) return '双指滚动'
    if(this.step===TouchGuideStep.Mouse) return '精确使用鼠标'
    return '操作帮助完成'
  }
  private message(): string {
    const compact: boolean=this.layout().compact
    if(this.step<TouchGuideStep.Menu && !this.grabbed) return '先关闭菜单回到游戏，再继续这一步。'
    if(this.step===TouchGuideStep.Menu) {
      if(!this.scrollEnabled) return compact ? '双指滚动已关闭，可开启或跳过。' : '当前方案关闭了双指滚动。可在操作设置中开启，或跳过这一项。'
      if(this.grabbed) return compact ? '点 Esc，再进入选项 → 视频设置。' : '点Esc打开游戏菜单，再进入视频设置等可以滚动的列表。'
      if(this.navigationKind===1) return '点指向的“选项”，打开游戏设置。'
      if(this.navigationKind===2) return '点指向的“视频设置”，进入真实页面。'
      if(this.navigationKind===3) return !this.navigationScrollKnown || this.navigationScrollable ? '已进入视频设置，点“开始滚动”。' : '本页无需滚动，可换长列表或跳过。'
      return compact ? '进入长列表后点“开始滚动”。' : '进入视频设置等长列表后，点“开始滚动”。普通生存背包本身不能滚动。'
    }
    if(!this.validTarget()) return compact ? '此方案没有对应按键，可跳过或先添加。' : '当前方案没有这个可见控件。可跳过此步，或在操作设置中添加后重新学习。'
    if(this.step===TouchGuideStep.Move) return compact ? '按住摇杆并推动，移动后松手。' : '按住真正的摇杆，向任意方向推动。角色移动后松手，会自动进入下一步。'
    if(this.step===TouchGuideStep.Hotbar) return compact ? '点物品栏第5格，松手继续。' : '点一下真正物品栏的第5格。选中后松手，自动继续。'
    if(this.step===TouchGuideStep.Scroll) return !this.scrollEnabled ?
      (compact ? '双指滚动已关闭，请开启或跳过。' : '当前方案关闭了双指滚动。请在操作设置中开启，或跳过此步。') :
      this.grabbed ? '请回到刚才的列表菜单，继续练习双指滚动。' :
      compact ? '双指上下滑动列表，松手继续。' : '两指放在真实列表上，上下滑动。看内容随手指滚动，抬手后自动继续。'
    if(this.step===TouchGuideStep.Mouse) return this.grabbed ? '先打开背包或菜单，再学习精确鼠标操作。' :
      this.mouseOpen ? (compact ? '拖动底部移动指针，再点右键。' : '拖动鼠标底部移动指针，再试一下右键。左右键按住时可直接拖动；这些操作会作用于真实菜单。') :
      (compact ? '点鼠标展开，可精确操作菜单和容器。' : '点“鼠标”展开悬浮鼠标，可精确操作小按钮和容器。')
    return '已完成操作帮助，可随时从设置重新打开。'
  }
  private handX(): number {
    if(this.step===TouchGuideStep.Scroll) return this.viewWidth*.52
    if(this.step===TouchGuideStep.Mouse && this.mouseOpen) return this.target.x+this.target.width*.5
    const travel: number=this.step===TouchGuideStep.Move ? Math.sin(this.phase*Math.PI)*this.target.width*.25 : 0
    return this.target.x+this.target.width/2+travel
  }
  private handY(): number {
    if(this.step===TouchGuideStep.Scroll) return this.viewHeight*(.64-.23*Math.sin(this.phase*Math.PI))
    if(this.step===TouchGuideStep.Mouse && this.mouseOpen) return this.target.y+this.target.height*.82
    return this.target.y+this.target.height/2
  }
  @Builder
  VisualGuide() {
    Stack({alignContent:Alignment.TopStart}) {
      if(this.pointAtTarget()) {
        Rect().width(this.viewWidth).height(this.focusY()).fill('#4D07140F')
        Rect().width(this.focusX()).height(this.focusHeight()).fill('#4D07140F').position({x:0,y:this.focusY()})
        Rect().width(Math.max(0,this.viewWidth-this.focusX()-this.focusWidth())).height(this.focusHeight()).fill('#4D07140F')
          .position({x:this.focusX()+this.focusWidth(),y:this.focusY()})
        Rect().width(this.viewWidth).height(Math.max(0,this.viewHeight-this.focusY()-this.focusHeight())).fill('#4D07140F')
          .position({x:0,y:this.focusY()+this.focusHeight()})
        Rect().width(this.focusWidth()).height(this.focusHeight()).radius(12).fill('#00000000')
          .stroke('#B7EFCD').strokeWidth(2).position({x:this.focusX(),y:this.focusY()})
      } else {
        Rect().width(this.viewWidth).height(this.viewHeight).fill(this.layout().menuRail ? '#1607140F' : '#4D07140F')
      }
      if(this.pointAtTarget()) {
        Line().width('100%').height('100%').startPoint([this.cardX()+this.cardWidth()/2,this.cardY()+this.layout().card.height/2])
          .endPoint([this.handX(),this.handY()-18]).stroke('#B7EFCD').strokeWidth(1).strokeDashArray([4,5])
      }
      if(this.pointAtTarget() && this.fingers===0 && this.active) {
        Circle().width(28).height(28).fill('#407CDFAD').stroke('#D4FFE7').strokeWidth(2)
          .position({x:this.handX()-14,y:this.handY()-14})
        Image($r('app.media.touch_guide_hand')).width(48).height(64)
          .rotate({angle:this.step===TouchGuideStep.Hotbar ? 180 : 0})
          .position({x:this.handX()-(this.step===TouchGuideStep.Hotbar ? 30 : 19),
            y:this.handY()-(this.step===TouchGuideStep.Hotbar ? 58 : 6)})
        if(this.step===TouchGuideStep.Scroll) {
          Circle().width(28).height(28).fill('#407CDFAD').stroke('#D4FFE7').strokeWidth(2).position({x:this.handX()+28,y:this.handY()-14})
          Image($r('app.media.touch_guide_hand')).width(48).height(64).position({x:this.handX()+23,y:this.handY()-6})
        }
      }
      Column({space:this.layout().compact ? 4 : 8}) {
        if(this.layout().menuRail) {
          Text(this.progressLabel()+' · '+this.message()).fontSize(14).lineHeight(18).maxLines(2)
            .fontColor('#F1FAF3').width('100%')
        } else {
          Text(this.progressLabel()+' · '+this.title()).fontSize(this.layout().compact ? 16 : 18)
            .fontWeight(FontWeight.Medium).fontColor('#F1FAF3').width('100%')
          Text(this.message()).fontSize(this.layout().compact ? 14 : 16).maxLines(this.layout().compact ? 2 : 4)
            .fontColor('#DCECE0').width('100%')
          if(!this.layout().compact) { Text('直接操作游戏 · 达成后自动继续').fontSize(14).fontColor('#A6CDB5').width('100%') }
        }
      }.width(this.cardWidth()).height(this.layout().card.height).padding(this.layout().menuRail ? 8 : this.layout().compact ? 10 : 16)
        .opacity(!this.grabbed && this.fingers>0 ? 0 : 1).backgroundColor('#D020332A').borderRadius(12)
        .border({width:1,color:'#668BB59A'}).position({x:this.cardX(),y:this.cardY()})
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
  build() {
    Stack({alignContent:Alignment.TopStart}) {
      this.VisualGuide()
      Row({space:8}) {
        Button('跳过此步').fontSize(14).height(44).layoutWeight(1).backgroundColor('#C92B4438').fontColor('#F1FAF3')
          .hitTestBehavior(HitTestMode.Block).onClick((): void => { this.onSkip(this.publicationToken) })
        if(this.step===TouchGuideStep.Menu && !this.grabbed) {
          Button('开始滚动').fontSize(14).height(44).layoutWeight(1).backgroundColor('#B7EFCD').fontColor('#153B25')
            .enabled(this.scrollEnabled && (this.navigationKind!==3 || !this.navigationScrollKnown || this.navigationScrollable))
            .hitTestBehavior(HitTestMode.Block).onClick((): void => { this.onBeginScroll(this.publicationToken) })
        }
        Button('关闭引导').fontSize(14).height(44).layoutWeight(1).backgroundColor('#C92B4438').fontColor('#F1FAF3')
          .hitTestBehavior(HitTestMode.Block).onClick((): void => { this.onClose(this.publicationToken) })
      }.width(this.layout().toolbar.width).height(this.layout().toolbar.height)
        .position({x:this.layout().toolbar.x,y:this.layout().toolbar.y})
        .hitTestBehavior(HitTestMode.Default).onTouch((event: TouchEvent): void => { event.stopPropagation() })
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }
}

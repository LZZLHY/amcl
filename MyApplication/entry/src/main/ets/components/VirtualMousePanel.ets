/**
 * 可直接操作的悬浮鼠标本体。移动、左右键拖动、滚轮均以窗口vp坐标驱动共享模型。
 * 本体位置由共享模型投影：单指原始位移随指、两指同轮固定，活动期间只钳制可见边界。
 * 触点在DOWN冻结按键角色；视觉位移、边缘钳制与移动指接力均不能改变已持有的键。
 */
import { AppRoundIconButton } from './AppRoundIconButton';
import { VirtualMouseModel, VirtualMousePort, VirtualMousePart } from 'gamecontrol'
import { AppIconName } from 'commons'
import { AppIcon } from './AppIcon'

const INACTIVE_MOUSE_PORT: VirtualMousePort={
  move:(_dx: number,_dy: number): boolean => false,
  wheel:(_steps: number): boolean => false,
  button:(_owner: string,_code: number,_down: boolean): boolean => false,
  cancel:(): boolean => false
}

@Component
export struct VirtualMousePanel {
  model: VirtualMouseModel=new VirtualMouseModel(INACTIVE_MOUSE_PORT)
  onClose: () => void=(): void => {}
  onInteraction: () => void=(): void => {}
  @Prop @Watch('onModelReset') resetRevision: number=0
  /** 紧凑模式来自父层同一份视口几何，排除区与显示尺寸不使用两套设备推断。 */
  @Prop compact: boolean=false
  @State private leftDown: boolean=false
  @State private rightDown: boolean=false
  @State private shiftLock: boolean=false
  private lastPointerAt: number=0
  private alive: boolean=true

  aboutToAppear(): void { this.alive=true; this.refreshHeld() }
  /** 关闭/销毁统一取消原触点，框架迟到MOVE不能复活旧拖动。 */
  aboutToDisappear(): void { this.alive=false; this.model.cancelAll() }
  private onModelReset(): void { this.refreshHeld() }
  private refreshHeld(): void {
    this.leftDown=this.model.down(-1); this.rightDown=this.model.down(-2); this.shiftLock=this.model.locked(340)
  }
  /** 同一触点从按下到抬起始终使用窗口坐标；局部组件位置跟随指针时不会造成反馈回路。 */
  private touchArea(event: TouchEvent,part: VirtualMousePart): void {
    event.stopPropagation()
    if(!this.alive) return
    this.lastPointerAt=Date.now(); this.onInteraction()
    if(event.type===TouchType.Down) {
      for(const touch of event.changedTouches) this.model.beginContact(touch.id,part,touch.windowX,touch.windowY,touch.pressedTime ?? 0)
    } else if(event.type===TouchType.Move) {
      for(const touch of event.touches) this.model.moveContact(touch.id,touch.windowX,touch.windowY,touch.pressedTime ?? 0)
    } else if(event.type===TouchType.Up) {
      // UP也包含仍在触点的真实窗口样本。先沿原owner更新它们：等待指只刷新交接基线，
      // 当前移动指仍保留本帧真实delta；不能等交接后再把等待期间的行程补发为新owner移动。
      // changedTouches可能与touches使用不同采样机制，结束触点只取changed末点一次，避免先后消费两份尾样本。
      for(const touch of event.touches) {
        if(event.changedTouches.some((changed: TouchObject): boolean => changed.id===touch.id)) continue
        this.model.moveContact(touch.id,touch.windowX,touch.windowY,touch.pressedTime ?? 0)
      }
      // 同批全部末点先按原移动权归约，再统一结束。禁止move/end交错，让同批也抬起的等待指临时取得
      // 移动权并把自己的等待行程输出。旧SDK可选按下身份仍由模型拒绝，迟到UP不能结束新接触。
      for(const touch of event.changedTouches) {
        this.model.moveContact(touch.id,touch.windowX,touch.windowY,touch.pressedTime ?? 0)
      }
      for(const touch of event.changedTouches) {
        this.model.endContact(touch.id,touch.pressedTime ?? 0)
      }
    } else if(event.type===TouchType.Cancel) {
      // 框架没有携带触点时取消整面板；有可选按下身份时，只认当前接触，拒绝迟到的旧CANCEL。
      let current: boolean=event.changedTouches.length===0 && event.touches.length===0
      for(const touch of event.changedTouches) if(this.model.hasContact(touch.id,touch.pressedTime ?? 0)) current=true
      for(const touch of event.touches) if(this.model.hasContact(touch.id,touch.pressedTime ?? 0)) current=true
      if(current) this.model.cancelAll()
    }
    this.refreshHeld(); this.onInteraction()
  }
  /** 无障碍/键盘激活也能点击；真实触控随后产生的onClick不再重复发送。 */
  private activate(code: number): void {
    if(!this.alive || Date.now()-this.lastPointerAt<500) return
    if(this.model.press('accessible',code,true)) this.model.press('accessible',code,false)
    this.onInteraction(); this.refreshHeld()
  }
  @Builder
  MouseKey(label: string,part: VirtualMousePart) {
    // @Builder的多参数按值传递只取得初始值；把leftDown/rightDown作为pressed实参，
    // SDK生成的Text观察闭包只捕获该boolean，不会登记所属组件状态的读取依赖。
    // 标签/角色是固定输入，颜色则在观察闭包内直接读取@State，使真实DOWN/UP及reset反馈可刷新。
    Stack({alignContent:Alignment.Center}) {
      Text(label).fontSize(14).fontColor((part==='left' ? this.leftDown : this.rightDown) ? '#10241F' : '#ECF3F0')
        .textAlign(TextAlign.Center).maxLines(1).hitTestBehavior(HitTestMode.None)
      if(part==='left' ? this.leftDown : this.rightDown) {
        // 标签可能被按键指遮住；仅在端口已接受的持有态显示外缘短条，不用缩放改变触达边界。
        Rect().width(2).height(this.compact ? 18 : 28).radiusWidth(1).radiusHeight(1).fill('#245345')
          .align(part==='left' ? Alignment.Start : Alignment.End)
          .margin({left:part==='left' ? 5 : 0,right:part==='right' ? 5 : 0})
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
    }.height('100%').layoutWeight(1)
      .backgroundColor((part==='left' ? this.leftDown : this.rightDown) ? '#A4E7CC' : '#EB263A38')
      .hitTestBehavior(HitTestMode.Block)
      .onTouch((event: TouchEvent): void => { this.touchArea(event,part) })
      .onClick((): void => { this.activate(part==='left' ? -1 : -2) })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .accessibilityText(label+'，按住并拖动可持续移动指针')
  }
  build() {
    Column({space:4}) {
      Row({space:4}) {
        Button({type:ButtonType.Circle,stateEffect:false}) {
          Stack({alignContent:Alignment.Center}) {
            // 独立SVG viewBox将图形固定在20×20vp盒内；不依赖⇧字体字面、基线或Button默认内边距。
            Image($r('app.media.virtual_mouse_shift')).width(20).height(20).objectFit(ImageFit.Contain)
              .fillColor(this.shiftLock ? '#10241F' : '#EDF5F1').hitTestBehavior(HitTestMode.None)
              .accessibilityLevel('no')
            if(this.shiftLock) {
              // 角标独立定位，不参与主图标的居中计算；锁定前后Shift轮廓保持原位。
              AppIcon({name:AppIconName.Lock,iconSize:9,color:'#10241F'})
                .width(10).height(10).position({x:29,y:4}).hitTestBehavior(HitTestMode.None)
                .accessibilityLevel('no')
            }
          }.width(44).height(44).hitTestBehavior(HitTestMode.None)
        }.width(44).height(44).padding(0).borderRadius(22)
          .backgroundColor(this.shiftLock ? '#A4E7CC' : '#C9253836')
          .accessibilityText(this.shiftLock ? '释放Shift' : '按住Shift')
          // 旧组件销毁后的迟到键盘/无障碍激活也不能创建新工具持有。
          .onClick((): void => { if(!this.alive) return; this.model.toggle(340); this.refreshHeld(); this.onInteraction() })
        Blank()
        // 视觉仍为 32vp、命中由共同按钮保证 44vp；先释放工具持键，再收起面板。
        AppRoundIconButton({ name: AppIconName.Close, color: '#EDF5F1', containerBg: '#C9253836',
          visualDiameter: 32, actionEnabled: this.alive, accessibilityLabel: '收起虚拟鼠标',
          controlId: 'virtual-mouse-close', onAction: (): void => {
            if (!this.alive) return;
            this.model.cancelAll(); this.onClose();
          } })
      }.width('100%').height(44)
      Column({space:1}) {
        Row({space:1}) {
          this.MouseKey('左键','left')
          Column({space:this.compact ? 1 : 4}) {
            // 整条44vp区域都是同一个滑动滚轮；上下箭头与槽内刻线只有方向提示，没有独立点击语义。
            AppIcon({name:AppIconName.ChevronUp,iconSize:12,color:'#B9D6CB'})
              .width(16).height(this.compact ? 12 : 16).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            Column({space:3}) {
              Rect().width(8).height(1).fill('#B9D6CB')
              Rect().width(8).height(1).fill('#EDF5F1')
              Rect().width(8).height(1).fill('#B9D6CB')
            }.width(18).height(this.compact ? 24 : 36).justifyContent(FlexAlign.Center)
              .backgroundColor('#324F48').borderRadius(9).border({width:1,color:'#6684A99C'})
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            AppIcon({name:AppIconName.ChevronDown,iconSize:12,color:'#B9D6CB'})
              .width(16).height(this.compact ? 12 : 16).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          }.width(44).height('100%').justifyContent(FlexAlign.Center).backgroundColor('#ED1B2C2A')
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent): void => { this.touchArea(event,'wheel') })
            .accessibilityText('滚轮，上下滑动滚动当前指针指向的区域')
          this.MouseKey('右键','right')
        }.width('100%').height(this.compact ? 56 : 88)
        Column({space:2}) {
          Text('⠿').fontSize(this.compact ? 18 : 24).fontColor('#D6E8DF')
          Text('移动').fontSize(this.compact ? 12 : 14).fontColor('#AFC5BE')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).backgroundColor('#EB263A38')
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent): void => { this.touchArea(event,'move') })
          .accessibilityText('移动鼠标，拖动此处只移动指针')
      }.width('100%').layoutWeight(1).borderRadius(this.compact ? 20 : 28).clip(true)
        .backgroundColor('#6084A99C').border({width:1,color:'#6684A99C'})
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent): void => { event.stopPropagation() })
  }
}

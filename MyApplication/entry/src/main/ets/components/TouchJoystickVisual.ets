/** 游戏中真实摇杆的外观；纯绘制，不持有触点、不向任何输入出口发键。引导只在它周围画提示。 */
@Component
export struct TouchJoystickVisual {
  @Prop controlWidth: number=120
  @Prop controlHeight: number=120
  @Prop corner: number=1
  @Prop directionX: number=0
  @Prop directionY: number=0
  @Prop pressed: boolean=false
  build() {
    Stack() {
      Stack().width(this.controlWidth*.93).height(this.controlHeight*.93)
        .backgroundColor('#28FFFFFF').borderRadius(this.corner*Math.min(this.controlWidth,this.controlHeight)*.93/2)
        .border({width:1.5,color:'#40FFFFFF'})
      Stack().width(this.controlWidth*.37).height(this.controlHeight*.37)
        .backgroundColor(this.pressed ? '#C0FFFFFF' : '#60FFFFFF')
        .borderRadius(this.corner*Math.min(this.controlWidth,this.controlHeight)*.37/2)
        .offset({x:this.directionX*this.controlWidth*.26,y:this.directionY*this.controlHeight*.26})
    }.width(this.controlWidth).height(this.controlHeight).hitTestBehavior(HitTestMode.None)
  }
}

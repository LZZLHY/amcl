// 编辑器工具按钮明确使用小圆角矩形；后续显式圆角可覆盖此默认值，不跟随系统胶囊造型。
/**
 * 面板内嵌HSV颜色选择器。只维护一次选色的显示草稿，颜色写入及撤销边界由LayoutEditor负责。
 * 不打开系统弹窗，不持有输入owner；触摸的局部坐标来自此色板，滑条/色板共用Begin/End提交语义。
 */
import { controlColorParts,controlRgbHex,controlRgbToHsv,controlHsvToRgb,ControlHsv } from 'gamecontrol'
import { EditorPalette } from './TouchEditorTheme'

@Component
export struct ControlColorPicker {
  @Prop palette: EditorPalette=new EditorPalette()
  @Prop @Watch('syncColor_') color: string='#FFFFFF'
  @Prop title: string='颜色'
  onColorChange: (rgb: string,mode: SliderChangeMode)=>void=()=>{}
  onClose: ()=>void=()=>{}
  @State private hue: number=0
  @State private saturation: number=0
  @State private hsvValue: number=1
  @State private hex: string='#FFFFFF'
  @State private message: string=''
  @State private squareWidth: number=200
  private finger: number=-1
  private tracking: boolean=false
  private presets: string[]=['#FFFFFF','#111827','#EF5350','#FFB74D','#FFEE58','#81C784','#4FC3F7','#BA68C8']

  aboutToAppear(): void { this.syncColor_() }
  /** 自身连续拖动时不让父级回显重置色相；外部撤销/换色才同步到当前显示。 */
  private syncColor_(): void {
    if(this.tracking)return
    const hsv: ControlHsv=controlRgbToHsv(controlColorParts(this.color))
    if(hsv.saturation>0)this.hue=hsv.hue
    this.saturation=hsv.saturation;this.hsvValue=hsv.value;this.hex=controlRgbHex(controlColorParts(this.color))
  }
  private emit_(mode: SliderChangeMode): void {
    this.hex=controlRgbHex(controlHsvToRgb(this.hue,this.saturation,this.hsvValue));this.message=''
    this.onColorChange(this.hex,mode)
  }
  private touch_(event: TouchEvent): void {
    event.stopPropagation()
    if(event.type===TouchType.Down && this.finger<0){
      const point: TouchObject | undefined=event.changedTouches[0];if(point===undefined)return
      this.finger=point.id;this.tracking=true
    }
    if(this.finger<0)return
    const point: TouchObject | undefined=event.changedTouches.find((touch: TouchObject): boolean=>touch.id===this.finger)
    if(event.type===TouchType.Up&&point===undefined)return
    if(point!==undefined && event.type!==TouchType.Cancel){
      this.saturation=Math.max(0,Math.min(1,point.x/Math.max(1,this.squareWidth)))
      this.hsvValue=1-Math.max(0,Math.min(1,point.y/76))
      this.emit_(event.type===TouchType.Down?SliderChangeMode.Begin:event.type===TouchType.Up?SliderChangeMode.End:SliderChangeMode.Moving)
    }
    if(event.type===TouchType.Up||event.type===TouchType.Cancel){this.emit_(SliderChangeMode.End);this.finger=-1;this.tracking=false}
  }
  private choose_(rgb: string): void {
    const hsv: ControlHsv=controlRgbToHsv(controlColorParts(rgb));this.hue=hsv.hue;this.saturation=hsv.saturation;this.hsvValue=hsv.value
    this.emit_(SliderChangeMode.Click)
  }
  private applyHex_(): void {
    const value: string=this.hex.trim().startsWith('#')?this.hex.trim():'#'+this.hex.trim()
    if(!new RegExp('^#[0-9a-fA-F]{6}$').test(value)){this.message='请输入6位RGB颜色';return}
    this.choose_(value)
  }
  build() {
    Column({space:4}) {
      Row({space:4}) {
        Text(this.title).fontSize(11).fontColor(this.palette.muted).layoutWeight(1)
        Button('默认').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.palette.accent).onClick(()=>this.choose_('#FFFFFF'))
        Button('收起').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.palette.muted).onClick(()=>this.onClose())
      }.width('100%')
      Stack({alignContent:Alignment.TopStart}) {
        Column().width('100%').height('100%').backgroundColor(controlRgbHex(controlHsvToRgb(this.hue,1,1)))
        Column().width('100%').height('100%').linearGradient({direction:GradientDirection.Right,colors:[['#FFFFFFFF',0],['#00FFFFFF',1]]})
        Column().width('100%').height('100%').linearGradient({direction:GradientDirection.Bottom,colors:[['#00000000',0],['#FF000000',1]]})
        // 选中点只需一个透明圆环；基础边框在所有受支持系统版本上都可绘制。
        Row().width(10).height(10).borderRadius(5).border({width:2,color:'#FFFFFF'})
          .position({x:Math.max(0,Math.min(this.squareWidth-10,this.saturation*this.squareWidth-5)),y:Math.max(0,Math.min(66,(1-this.hsvValue)*76-5))})
          .hitTestBehavior(HitTestMode.None)
      }.height(76).width('100%').clip(true).borderRadius(5)
        .onAreaChange((_old: Area,current: Area): void=>{this.squareWidth=Number(current.width)})
        .onTouch((event: TouchEvent): void=>this.touch_(event))
        .priorityGesture(PanGesture({fingers:1,distance:0}).onActionUpdate(()=>{}))
        .accessibilityText('颜色饱和度和明度；也可使用下方颜色值输入')
      Slider({value:this.hue,min:0,max:359,step:1}).height(44).width('100%')
        .selectedColor(this.palette.accentFill).onChange((value: number,mode: SliderChangeMode): void=>{
          if(mode===SliderChangeMode.Begin)this.tracking=true
          if(mode!==SliderChangeMode.Begin&&mode!==SliderChangeMode.Click&&!this.tracking)return
          this.hue=value;this.emit_(mode)
          if(mode===SliderChangeMode.End||mode===SliderChangeMode.Click)this.tracking=false
        })
      Flex({wrap:FlexWrap.Wrap,justifyContent:FlexAlign.Start}) {
        ForEach(this.presets,(rgb: string)=>{
          // 固定44vp触区后按浮窗实宽折行，保留原八种颜色顺序。
          Button().type(ButtonType.Normal).width(44).height(44).margin({right:4,bottom:4}).padding(0).borderRadius(8).backgroundColor(rgb)
            .accessibilityText('颜色 '+rgb).onClick(()=>this.choose_(rgb))
        },(rgb: string): string=>rgb)
      }.width('100%')
      Row({space:6}) {
        TextInput({text:this.hex,placeholder:'#RRGGBB'}).height(44).layoutWeight(1).fontSize(12)
          .fontColor(this.palette.text).backgroundColor(this.palette.surface).maxLength(7).onChange((value: string): void=>{this.hex=value})
        Button('应用').type(ButtonType.Normal).borderRadius(6).height(44).fontSize(12).fontColor(this.palette.accent).backgroundColor(this.palette.surfaceActive).onClick(()=>this.applyHex_())
      }.width('100%')
      if(this.message.length>0){Text(this.message).fontSize(11).fontColor(this.palette.warning)}
    }.width('100%').padding(8).backgroundColor(this.palette.surface).borderRadius(6)
  }
}

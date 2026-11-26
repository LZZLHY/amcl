/** 设置目录由手感页与本局分辨率页共用。这里仅投影当前页面，切换事务由宿主负责。 */
import { AppIconName } from 'commons'
import { AppIcon } from './AppIcon'
import { EditorPalette } from './TouchEditorTheme'

interface SettingsDestination {
  id: string
  title: string
  detail: string
  icon: AppIconName
}

/** 专用键位属于方案通用设置；按对象定位可避免类别增删后引用错误的条目。 */
const POLICY_DESTINATION: SettingsDestination = {
  id:'policy', title:'专用键位', detail:'跟随游戏键位与手动覆盖', icon:AppIconName.Keyboard
}
const INPUT_DESTINATIONS: SettingsDestination[] = [
  { id:'look', title:'视角', detail:'镜头灵敏度、跟手度与反馈', icon:AppIconName.Aim },
  { id:'move', title:'移动', detail:'摇杆中心、死区与疾跑', icon:AppIconName.Trigger },
  { id:'menu', title:'菜单与背包', detail:'指针操作与双指滚动', icon:AppIconName.Scene },
  { id:'gesture', title:'快捷栏', detail:'交换副手与丢弃物品', icon:AppIconName.Hotbar },
  { id:'gyro', title:'陀螺仪', detail:'体感辅助瞄准与方向', icon:AppIconName.Refresh },
  POLICY_DESTINATION
]
const GAME_TOOLS: SettingsDestination[] = [
  { id:'layout', title:'编辑按键布局', detail:'编辑游戏画面上的虚拟按键', icon:AppIconName.LayoutList },
  { id:'resolution', title:'游戏分辨率', detail:'仅调整本局游戏的渲染比例', icon:AppIconName.Appearance }
]
/** 移动设备偏好独立于操控方案，只在支持的局内宿主开放。 */
const INPUT_DEVICES: SettingsDestination = {
  id:'devices', title:'输入设备', detail:'查看已连接的设备，输入方式即时保存', icon:AppIconName.GameController
}

/** 详情标题和手机目录使用相同目录项，也保留外部旧入口所用的 gesture 标识。 */
export function gameSettingsTitle(id: string): string {
  if (id === INPUT_DEVICES.id) return INPUT_DEVICES.title
  return INPUT_DESTINATIONS.find((entry: SettingsDestination): boolean => entry.id===id)?.title ??
    GAME_TOOLS.find((entry: SettingsDestination): boolean => entry.id===id)?.title ?? '设置'
}
export function gameSettingsDetail(id: string): string {
  if (id === INPUT_DEVICES.id) return INPUT_DEVICES.detail
  return INPUT_DESTINATIONS.find((entry: SettingsDestination): boolean => entry.id===id)?.detail ??
    GAME_TOOLS.find((entry: SettingsDestination): boolean => entry.id===id)?.detail ?? ''
}

/** 手机只呈现目录项；平板侧栏包裹同一目录，选中颜色、入口资格始终一致。 */
@Component
export struct GameSettingsDirectory {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop selected: string = ''
  @Prop compact: boolean = false
  @Prop summaries: string[] = []
  /** 平板的工具从分类滚动区拆出固定展示；手机仍将两组一次性呈现。 */
  @Prop toolsOnly: boolean = false
  @Prop includeGameTools: boolean = true
  @Prop allowMobileInput: boolean = false
  @Prop allowLiveResolution: boolean = false
  onSelect: (id: string) => void = (_id: string): void => {}

  /** 目录快照按固定分类顺序来自父草稿，工具入口只显示其作用域。 */
  private summary_(id: string): string {
    if (id === INPUT_DEVICES.id) return ''
    const index: number=INPUT_DESTINATIONS.findIndex((entry: SettingsDestination): boolean=>entry.id===id)
    return index>=0 ? this.summaries[index] ?? '' : id==='resolution'?'仅本局':'当前方案'
  }

  @Builder
  Destination_(entry: SettingsDestination) {
    Button() {
      Row({space:12}) {
        AppIcon({name:entry.icon,iconSize:19,color:this.selected===entry.id ? this.palette.accent : this.palette.muted})
        Text(entry.title).fontSize(15).fontColor(this.selected===entry.id ? this.palette.accent : this.palette.text).layoutWeight(1)
        if (!this.compact && this.summary_(entry.id).length>0) {
          Text(this.summary_(entry.id)).fontSize(12).fontColor(this.palette.muted).constraintSize({maxWidth:'36%'})
            .maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
        }
        if (!this.compact) { AppIcon({name:AppIconName.ChevronRight,iconSize:16,color:this.palette.muted}) }
      }.width('100%').padding({left:12,right:12,top:5,bottom:5})
    }.type(ButtonType.Normal).constraintSize({minHeight:this.compact ? 44 : 54}).width('100%')
      .backgroundColor(this.selected===entry.id ? this.palette.surfaceActive : Color.Transparent)
      .borderRadius(this.palette.radiusSmall).onClick((): void => { this.onSelect(entry.id) })
      .accessibilityText(entry.title+(this.selected===entry.id?'，已选择':'')).id(entry.id==='resolution'?'open-game-resolution':'game-settings-nav-'+entry.id)
  }

  @Builder
  Caption_(label: string) {
    Text(label).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.palette.muted)
      .width('100%').padding({left:10,top:this.compact?4:10,bottom:this.compact?2:6})
  }

  build() {
    Column({space:3}) {
      if (!this.toolsOnly) {
        this.Caption_('手感与输入')
        Column({space:1}) {
          if (this.allowMobileInput) { this.Destination_(INPUT_DEVICES) }
          ForEach(INPUT_DESTINATIONS.slice(0,-1),(entry: SettingsDestination) => {
            this.Destination_(entry)
          },(entry: SettingsDestination): string=>entry.id)
        }.width('100%').padding(this.compact ? 0 : 4).borderRadius(this.palette.radiusSmall)
          .backgroundColor(this.compact ? Color.Transparent : this.palette.surface)
        this.Caption_('方案通用')
        Column() { this.Destination_(POLICY_DESTINATION) }.width('100%').padding(this.compact ? 0 : 4)
          .borderRadius(this.palette.radiusSmall).backgroundColor(this.compact ? Color.Transparent : this.palette.surface)
      }
      if (this.includeGameTools) {
        this.Caption_('布局与画面')
        Column({space:1}) {
          ForEach(GAME_TOOLS,(entry: SettingsDestination) => {
            if (entry.id!=='resolution' || this.allowLiveResolution) { this.Destination_(entry) }
          },(entry: SettingsDestination): string=>entry.id)
        }.width('100%').padding(this.compact ? 0 : 4).borderRadius(this.palette.radiusSmall)
          .backgroundColor(this.compact ? Color.Transparent : this.palette.surface)
      }
    }.width('100%')
  }
}

/** 固定标题和当前方案帮助定位；分类列表在短窗口中独立滚动。 */
@Component
export struct GameSettingsRail {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop selected: string = ''
  @Prop profileName: string = ''
  @Prop allowLiveResolution: boolean = false
  @Prop allowMobileInput: boolean = false
  @Prop includeGameTools: boolean = true
  onSelect: (id: string) => void = (_id: string): void => {}
  build() {
    Column({space:5}) {
      Row({space:10}) {
        AppIcon({name:AppIconName.Settings,iconSize:23,color:this.palette.accent})
        Text(this.includeGameTools?'设置':'手感与输入').fontSize(25).fontWeight(FontWeight.Bold).fontColor(this.palette.text)
      }.width('100%').padding({left:8,top:2,bottom:2})
      Scroll() {
        GameSettingsDirectory({palette:this.palette,selected:this.selected,compact:true,includeGameTools:false,allowMobileInput:this.allowMobileInput,
          allowLiveResolution:this.allowLiveResolution,onSelect:(id: string): void=>{ this.onSelect(id) }})
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
      if (this.includeGameTools) {
        GameSettingsDirectory({palette:this.palette,selected:this.selected,compact:true,toolsOnly:true,includeGameTools:true,
          allowLiveResolution:this.allowLiveResolution,onSelect:(id: string): void=>{ this.onSelect(id) }})
      }
      if (this.profileName.length>0) {
        Row({space:6}) {
          Text('当前方案').fontSize(11).fontColor(this.palette.muted)
          Text(this.profileName).fontSize(14).fontColor(this.palette.text).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
            .copyOption(CopyOptions.LocalDevice).accessibilityText('当前方案：'+this.profileName)
        }.width('100%').padding({left:8,right:8,top:6,bottom:6}).borderRadius(this.palette.radiusSmall).backgroundColor(this.palette.panel)
      }
    }.width('20%').constraintSize({minWidth:172,maxWidth:195}).height('100%').padding(8).backgroundColor(this.palette.surface)
  }
}

/** 同一组内容在宽窗口并列而在手机顺排。BuilderParam 保留父编辑器的响应状态与回调。 */
@Component
export struct InputSettingsColumns {
  @Prop wide: boolean = false
  @BuilderParam primary: () => void
  @BuilderParam secondary: () => void
  build() {
    if (this.wide) {
      Row({space:16}) {
        Column({space:12}) { this.primary() }.layoutWeight(1.2)
        Column({space:12}) { this.secondary() }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
    } else {
      Column({space:12}) { this.primary(); this.secondary() }.width('100%')
    }
  }
}

/** 设置项形成实色分组卡，控件本身继续使用当前应用主题。 */
@Component
export struct InputSettingsGroup {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop label: string = ''
  @Prop wide: boolean = false
  @BuilderParam content: () => void
  build() {
    Column({space:6}) {
      Text(this.label).fontSize(this.wide ? 15 : 13).fontWeight(FontWeight.Medium).fontColor(this.palette.muted).width('100%')
      Column({space:6}) { this.content() }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
        .backgroundColor(this.palette.surface).borderRadius(this.wide ? 18 : this.palette.radiusSmall)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

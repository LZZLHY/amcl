/**
 * 独立输入设置中的触控选项：菜单、移动、动作改键、快捷栏增强与陀螺仪。
 * 本组件只读取宿主草稿并回传完整配置，保存和撤销由InputSettingsEditor协调。
 * 仅构建当前分区；不建立输入、帧、定时器或传感器订阅。
 */
import { TouchConfiguration, normalizeTouchPreferences, TOUCH_ACTION_NAMES, TOUCH_ACTION_LABELS, glfwKeyName } from 'gamecontrol'
import { AppIconName } from 'commons'
import { AppIcon } from './AppIcon'
import { EditorTheme } from './TouchEditorTheme'

/** 带说明的开关行。基础类型 Prop 随父草稿同步，不在子组件保存第二份业务配置。 */
@Component
struct TouchOptionToggle {
  @Prop label: string = ''
  @Prop description: string = ''
  @Prop value: boolean = false
  onChange: (value: boolean) => void = (_value: boolean): void => {}

  /** 标签可换行，开关保留独立触达区；程序同步的同值通知由宿主 commit 去重。 */
  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.label).fontSize(14).fontColor(EditorTheme.text).width('100%')
        if (this.description.length > 0) {
          Text(this.description).fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(EditorTheme.accent).switchPointColor(EditorTheme.panel)
        .onChange(this.onChange)
        .accessibilityText(this.label)
    }.width('100%').constraintSize({ minHeight: 52 }).padding({ top: 4, bottom: 4 })
  }
}

/** 统一的数值设置行。只重画颜色和排版，范围、步长、值及手势阶段由调用方原样传入。 */
@Component
struct TouchOptionSlider {
  @Prop label: string = ''
  @Prop value: number = 0
  @Prop minimum: number = 0
  @Prop maximum: number = 100
  @Prop step: number = 1
  @Prop suffix: string = ''
  /** 原样保留官方Slider手势阶段，父编辑器据End/Click划分撤销边界。 */
  onChange: (value: number, mode: SliderChangeMode) => void = (_value: number, _mode: SliderChangeMode): void => {}

  /** 标题和数值独立排版，滑杆保留完整触控高度，不用缩放手段缩小命中区域。 */
  build() {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        Text(this.label).fontSize(14).fontColor(EditorTheme.muted).layoutWeight(1)
        Text(Math.round(this.value).toString() + this.suffix).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(EditorTheme.text)
      }.width('100%')
      Slider({ value: this.value, min: this.minimum, max: this.maximum, step: this.step })
        .blockColor(EditorTheme.text).blockBorderColor(EditorTheme.accent).blockBorderWidth(1)
        .selectedColor(EditorTheme.accent).trackColor(EditorTheme.stroke)
        .width('100%').onChange((value: number, mode: SliderChangeMode): void => { this.onChange(value,mode) })
    }.width('100%').padding({ top: 8, bottom: 2 })
  }
}

/** 分段选项使用显式 selected Prop，避免按值 Builder 参数令模板/撤销后的高亮停在旧值。 */
@Component
struct TouchOptionChoice {
  @Prop label: string = ''
  @Prop selected: boolean = false
  onChoose: () => void = (): void => {}

  /** 自定义文字随选中态同步，整颗按钮保持至少 44vp 高度。 */
  build() {
    Row() {
      Button() {
        Text(this.label).fontSize(14).fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selected ? EditorTheme.accent : EditorTheme.muted)
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 4, right: 4, top: 4, bottom: 4 })
        .backgroundColor(this.selected ? EditorTheme.surfaceActive : EditorTheme.surface)
        .borderRadius(EditorTheme.radiusSmall)
        .onClick(this.onChoose)
        .accessibilityText(this.label + (this.selected ? '，已选择' : ''))
    }.width('100%')
  }
}

@Component
export struct TouchOptionsEditor {
  @State showBindings: boolean = false
  /** 仅同步导航分区；父State保留选择，value/onChange仍是唯一业务草稿入口。 */
  @Link section: string
  /** 分区列表只在用户展开选择器时构建；选择内容不会修改草稿或制造撤销点。 */
  @State private sectionChoicesOpen: boolean = false
  @State private actionSearch: string = ''
  onRemap: (index: number) => void = (_index: number): void => {}
  @Prop value: TouchConfiguration = new TouchConfiguration()
  @Prop gyroscopeStatus: string = 'unknown'
  onChange: (value: TouchConfiguration, undoKey: string, mode?: SliderChangeMode) => void =
    (_value: TouchConfiguration, _undoKey: string, _mode?: SliderChangeMode): void => {}

  /**
   * 程序刷新Toggle/Slider也可能回传其当前值。没有语义变化时不通知宿主，避免模板或撤销之后
   * 又压入一份相同草稿，使用户必须多次撤销；比较归一化快照，不依赖框架包装对象的身份。
   */
  private commit(next: TouchConfiguration, undoKey: string, mode?: SliderChangeMode): void {
    // End可能与最后一次Moving值相同，仍须把它交给宿主关闭撤销组；宿主会跳过同值快照。
    if (mode === undefined && JSON.stringify(next) === JSON.stringify(normalizeTouchPreferences(this.value))) return
    this.onChange(next,undoKey,mode)
  }

  /** 布尔选项走显式字段，不用动态对象索引绕过ArkTS类型或配置校验。 */
  private flag(name: string, enabled: boolean): void {
    const next: TouchConfiguration = normalizeTouchPreferences(this.value) ?? new TouchConfiguration()
    switch (name) {
      case 'scroll': next.menuTwoFingerScroll=enabled; break
      case 'sprint': next.joystickSprint=enabled; break
      case 'bindings': next.followGameBindings=enabled; break
      case 'swap': next.hotbarSwapDoubleTap=enabled; break
      case 'drop': next.hotbarDropHold=enabled; break
      case 'gyroX': next.gyroscopeInvertX=enabled; break
      case 'gyroY': next.gyroscopeInvertY=enabled; break
      default: return
    }
    this.commit(next,'')
  }

  /** 有限枚举循环；标签始终展示当前模式，切换本身不立即发输入。 */
  private cycle(name: string): void {
    const next: TouchConfiguration = normalizeTouchPreferences(this.value) ?? new TouchConfiguration()
    if (name === 'menu') next.menuMode = next.menuMode === 'direct' ? 'touchpad' : 'direct'
    else if (name === 'joystick') next.joystickCenter = next.joystickCenter === 'fixed' ? 'floating' : 'fixed'
    else if (name === 'gyro') next.gyroscopeMode = next.gyroscopeMode === 'off' ? 'aim' :
      (next.gyroscopeMode === 'aim' ? 'always' : 'off')
    else return
    this.commit(next,'')
  }

  /** 一次滑条拖动使用同一undoKey与真实阶段；End/Click后下一次拖动创建新的撤销点。 */
  private number(name: string, value: number, mode: SliderChangeMode): void {
    const next: TouchConfiguration = normalizeTouchPreferences(this.value) ?? new TouchConfiguration()
    if (name === 'menuSpeed') next.menuSensitivity=value/100
    else if (name === 'menuHold') next.menuHoldMs=value
    else if (name === 'sprint') next.joystickSprintThreshold=value/100
    else if (name === 'hold') next.holdMs=value
    else if (name === 'gyro') next.gyroscopeSensitivity=value/100
    else return
    this.commit(next,'touch-' + name,mode)
  }

  /** 删除某项覆盖代表恢复自动；值0代表明确解除绑定，两者在保存和运行时不可混同。 */
  private changeBinding(index: number, unbind: boolean): void {
    const next: TouchConfiguration = normalizeTouchPreferences(this.value) ?? new TouchConfiguration()
    const overrides: Record<string,number> = {}
    for (const name of Object.keys(next.actionOverrides)) {
      if (name !== TOUCH_ACTION_NAMES[index]) overrides[name] = next.actionOverrides[name]
    }
    if (unbind) overrides[TOUCH_ACTION_NAMES[index]] = 0
    next.actionOverrides = overrides
    this.commit(next,'')
  }

  /** 显示语义键名，用户不需要输入GLFW数字。 */
  private actionLabel(index: number): string {
    const code: number | undefined = this.value.actionOverrides[TOUCH_ACTION_NAMES[index]]
    return code === undefined ? '自动' : (code === 0 ? '未绑定' : glfwKeyName(code))
  }

  /** 模式选择可直接看见全部选项；单击不会循环经过用户不需要的中间模式。 */
  private choose(name: string,value: string): void {
    const next: TouchConfiguration=normalizeTouchPreferences(this.value) ?? new TouchConfiguration()
    if(name==='menu') next.menuMode=value==='direct' ? 'direct' : 'touchpad'
    else if(name==='joystick') next.joystickCenter=value==='fixed' ? 'fixed' : 'floating'
    else if(name==='gyro') next.gyroscopeMode=value==='aim' ? 'aim' : value==='always' ? 'always' : 'off'
    this.commit(next,'')
  }

  /** 模板先停留在预览态，只有显式确认才交给宿主生成一次可撤销的草稿修改。 */


  /** 搜索结果仍以原动作数组的位置进入单键选择器，不能用过滤后的下标改写别的动作。 */
  private actionIndex(name: string): number { return TOUCH_ACTION_NAMES.indexOf(name) }

  /** 只过滤这份固定动作目录；搜索不改变动作顺序、已有覆盖或运行绑定。 */
  private actionNames(): string[] {
    return TOUCH_ACTION_NAMES.filter((name: string,index: number): boolean =>
      this.actionSearch.trim().length===0 || TOUCH_ACTION_LABELS[index].includes(this.actionSearch.trim()) || name.toLowerCase().includes(this.actionSearch.trim().toLowerCase()))
  }

  /** 分区摘要读取当前草稿，撤销与模板应用后同步显示，不产生第二份保存状态。 */
  private sectionSummary(id: string): string {
    if(id==='menu') return this.value.menuMode==='direct' ?
      (this.value.menuTwoFingerScroll ? '直接定位 · 识别单指拖动或双指滚动' : '直接操作 · 落指按住，抬指松开') :
      '触摸板 · 滑动移动，轻点点击'
    if(id==='move') return this.value.joystickCenter==='fixed' ? '固定摇杆中心' : '从落指位置建立中心'
    if(id==='gesture') return '快捷栏双击与长按动作'
    if(id==='gyro') return this.value.gyroscopeMode==='off' ? '已关闭' : '游戏内辅助瞄准'
    return id==='actions' ? '跟随游戏、手动覆盖或解除绑定' : '先查看改动，再应用到草稿'
  }

  /** 稳定分区身份只用于显示导航，与任何配置字段或模板身份分离。 */
  private readonly sectionIds: string[] = ['menu', 'move', 'actions', 'gesture', 'gyro']

  /** 为当前选择和展开清单提供同一组中文名称，避免短窗口里出现两套不同入口。 */
  private sectionTitle(id: string): string {
    if (id === 'menu') return '菜单与背包'
    if (id === 'move') return '移动'
    if (id === 'actions') return '动作与改键'
    if (id === 'gesture') return '快捷栏增强'
    if (id === 'gyro') return '陀螺仪辅助'
    return '触控设置'
  }

  /** 模板名称只修饰待应用预览，实际影响正文始终向宿主 describeTemplate 取得。 */


  /** 传感器状态是宿主投影；该文案函数绝不查询硬件或触发重订阅。 */
  private gyroscopeLabel(): string {
    if (this.gyroscopeStatus === 'unavailable') return '上次传感器订阅失败'
    if (this.gyroscopeStatus === 'active') return '传感器可用'
    return '进入游戏后检查设备'
  }

  /**
   * 五个设置分区共用一个选择器；展开后沿宿主滚动区域逐项可达。
   * 清单关闭时不构建其它四个分区，保留低高度窗口的底部撤销/取消/保存空间。
   */
  @Builder
  SectionPicker() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text(this.sectionTitle(this.section)).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(EditorTheme.accent).layoutWeight(1)
        AppIcon({ name: this.sectionChoicesOpen ? AppIconName.ChevronUp : AppIconName.ChevronDown,
          iconSize: 16, color: EditorTheme.muted })
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(EditorTheme.radiusSmall).backgroundColor(EditorTheme.surface)
        .onClick((): void => { this.sectionChoicesOpen = !this.sectionChoicesOpen })
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText('触控设置分区，' + this.sectionTitle(this.section) + (this.sectionChoicesOpen ? '，已展开' : '，展开选择'))
        .id('touch-section-picker')
      if (this.sectionChoicesOpen) {
        Column({ space: 4 }) {
          ForEach(this.sectionIds, (id: string) => {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(this.sectionTitle(id)).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.section === id ? EditorTheme.accent : EditorTheme.text)
                Text(this.sectionSummary(id)).fontSize(12).fontColor(EditorTheme.muted).width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              if (this.section === id) {
                AppIcon({ name: AppIconName.Check, iconSize: 16, color: EditorTheme.accent })
              }
            }.width('100%').constraintSize({ minHeight: 52 }).padding(10)
              .backgroundColor(this.section === id ? EditorTheme.surfaceActive : EditorTheme.panel)
              .borderRadius(EditorTheme.radiusSmall)
              .onClick((): void => { this.section = id; this.sectionChoicesOpen = false })
              .accessibilityRole(AccessibilityRoleType.BUTTON)
              .accessibilityText(this.sectionTitle(id) + '，' + this.sectionSummary(id))
              .id('touch-section-' + id)
          }, (id: string): string => id)
        }.width('100%').padding(4).borderRadius(EditorTheme.radiusSmall)
          .border({ width: 1, color: EditorTheme.stroke }).backgroundColor(EditorTheme.panel)
      }
    }.width('100%')
  }

  /**
   * 四种模式的选择按钮均接收基础类型 Prop，刷新直接来自宿主的新草稿。
   * 分区内容保留原业务条件和范围；本层不新增保存、输入、传感器或生命周期职责。
   */
  build() {
    Column({space:12}) {
      this.SectionPicker()
      if(this.section==='menu') {
        Row({space:4}) {
          TouchOptionChoice({ label:'直接操作', selected:this.value.menuMode==='direct',
            onChoose:(): void => { this.choose('menu','direct') } }).layoutWeight(1)
          TouchOptionChoice({ label:'触摸板', selected:this.value.menuMode==='touchpad',
            onChoose:(): void => { this.choose('menu','touchpad') } }).layoutWeight(1)
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        // 文案按实际策略显示，避免把需要手势识别的模式说明成落指立即按住。
        if(this.value.menuMode==='direct' && !this.value.menuTwoFingerScroll) {
          Text('落指按住左键，贴着屏幕滑动持续拖动，抬手松开。')
            .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        } else if(this.value.menuMode==='direct') {
          Text('开启双指滚动后，先识别手势；单指滑动或长按开始拖动，抬手松开。')
            .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        } else {
          Text('滑动只移动指针；轻点点击，长按后持续拖动，抬手松开。')
            .fontSize(12).fontColor(EditorTheme.muted).width('100%')
        }
        TouchOptionToggle({label:'双指滚动',description:'菜单与背包中的双指手势',value:this.value.menuTwoFingerScroll,
          onChange:(v: boolean): void => { this.flag('scroll',v) }})
        // 悬浮鼠标与触摸板共用menuSensitivity；直接模式也必须能查看、调整其保存值。
        // 这里只恢复已有参数入口，不额外叠加增益，也不改变直接触屏的绝对定位。
        TouchOptionSlider({label:'指针速度',value:this.value.menuSensitivity*100,minimum:30,maximum:300,step:5,suffix:'%',
          onChange:(v: number,mode: SliderChangeMode): void => { this.number('menuSpeed',v,mode) }})
        if(this.value.menuMode==='touchpad' || this.value.menuTwoFingerScroll) {
          TouchOptionSlider({label:'长按开始拖动',value:this.value.menuHoldMs,minimum:150,maximum:1000,step:50,suffix:'ms',
            onChange:(v: number,mode: SliderChangeMode): void => { this.number('menuHold',v,mode) }})
        }
        Text('悬浮鼠标提供左右键拖动、滚轮和 Shift，便于精细操作。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
      }
      if(this.section==='move') {
        Row({space:4}) {
          TouchOptionChoice({ label:'固定中心', selected:this.value.joystickCenter==='fixed',
            onChoose:(): void => { this.choose('joystick','fixed') } }).layoutWeight(1)
          TouchOptionChoice({ label:'落指浮动', selected:this.value.joystickCenter==='floating',
            onChoose:(): void => { this.choose('joystick','floating') } }).layoutWeight(1)
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        TouchOptionToggle({label:'推远时疾跑',description:'推到阈值后触发',value:this.value.joystickSprint,
          onChange:(v: boolean): void => { this.flag('sprint',v) }})
        if(this.value.joystickSprint) {
          TouchOptionSlider({label:'推远阈值',value:this.value.joystickSprintThreshold*100,minimum:50,maximum:150,step:5,suffix:'%',
            onChange:(v: number,mode: SliderChangeMode): void => { this.number('sprint',v,mode) }})
        }
      }
      if(this.section==='actions') {
        TouchOptionToggle({label:'跟随游戏改键',description:'读取当前游戏实例的动作键位',value:this.value.followGameBindings,
          onChange:(v: boolean): void => { this.flag('bindings',v) }})
        Row({ space:8 }) {
          AppIcon({ name:AppIconName.Search,iconSize:18,color:EditorTheme.muted })
          TextInput({placeholder:'搜索前进、攻击、快捷栏…',text:this.actionSearch}).height(44).layoutWeight(1)
            .fontSize(14).fontColor(EditorTheme.text).placeholderColor(EditorTheme.muted)
            .backgroundColor(EditorTheme.surface).padding({left:0,right:0})
            .onChange((text: string): void => { this.actionSearch=text })
        }.width('100%').padding({left:12,right:12}).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        ForEach(this.actionNames(),(name: string) => {
          Column({space:6}) {
            Row({space:8}) {
              Text(TOUCH_ACTION_LABELS[this.actionIndex(name)]).fontSize(14).fontColor(EditorTheme.text).layoutWeight(1)
              Button() {
                Row({space:6}) {
                  AppIcon({name:AppIconName.Keyboard,iconSize:16,
                    color:this.value.actionOverrides[name]===undefined ? EditorTheme.muted : EditorTheme.accent})
                  Text(this.value.actionOverrides[name]===undefined ? '自动 · 修改' : this.actionLabel(this.actionIndex(name)))
                    .fontSize(14).fontColor(this.value.actionOverrides[name]===undefined ? EditorTheme.text : EditorTheme.accent)
                }
              }.constraintSize({minHeight:44}).padding({left:12,right:12,top:6,bottom:6})
                .backgroundColor(this.value.actionOverrides[name]===undefined ? EditorTheme.surface : EditorTheme.surfaceActive)
                .borderRadius(EditorTheme.radiusSmall)
                .onClick((): void => { this.onRemap(this.actionIndex(name)) })
                .accessibilityText(TOUCH_ACTION_LABELS[this.actionIndex(name)]+'，'+this.actionLabel(this.actionIndex(name))+'，修改绑定')
            }.width('100%').constraintSize({minHeight:48})
            if(this.value.actionOverrides[name]!==undefined) {
              Button(this.value.followGameBindings ? '恢复跟随游戏' : '恢复默认绑定')
                .fontSize(13).fontColor(EditorTheme.text).height(44).width('100%')
                .backgroundColor(EditorTheme.panel).borderRadius(EditorTheme.radiusSmall)
                .border({width:1,color:EditorTheme.stroke})
                .onClick((): void => { this.changeBinding(this.actionIndex(name),false) })
            }
          }.width('100%').padding({top:2,bottom:2})
        },(name: string): string => name)
        if(this.actionNames().length===0) {
          Text('未找到匹配动作，请换个关键词。').fontSize(14).fontColor(EditorTheme.muted)
            .width('100%').padding({top:16,bottom:16}).textAlign(TextAlign.Center)
        }
        Text('共 '+TOUCH_ACTION_NAMES.length.toString()+' 项，可滚动查看。专用动作仅支持单键；普通可编辑按钮仍使用其自身绑定。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
      }
      if(this.section==='gesture') {
        TouchOptionToggle({label:'同格双击交换副手',description:'在快捷栏同一格内双击',value:this.value.hotbarSwapDoubleTap,
          onChange:(v: boolean): void => { this.flag('swap',v) }})
        TouchOptionToggle({label:'长按快捷栏丢弃物品',description:'使用下方的长按时长',value:this.value.hotbarDropHold,
          onChange:(v: boolean): void => { this.flag('drop',v) }})
        if(this.value.hotbarDropHold) {
          TouchOptionSlider({label:'长按时长',value:this.value.holdMs,minimum:200,maximum:1500,step:50,suffix:'ms',
            onChange:(v: number,mode: SliderChangeMode): void => { this.number('hold',v,mode) }})
        }
      }
      if(this.section==='gyro') {
        Row({space:4}) {
          TouchOptionChoice({label:'关闭',selected:this.value.gyroscopeMode==='off',
            onChoose:(): void => { this.choose('gyro','off') }}).layoutWeight(1)
          TouchOptionChoice({label:'按住使用时',selected:this.value.gyroscopeMode==='aim',
            onChoose:(): void => { this.choose('gyro','aim') }}).layoutWeight(1)
          TouchOptionChoice({label:'游戏内持续',selected:this.value.gyroscopeMode==='always',
            onChoose:(): void => { this.choose('gyro','always') }}).layoutWeight(1)
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
        Row({space:8}) {
          AppIcon({name:this.gyroscopeStatus==='active' ? AppIconName.CheckCircle : AppIconName.Help,iconSize:18,
            color:this.gyroscopeStatus==='unavailable' ? EditorTheme.warning : EditorTheme.accent})
          Text(this.gyroscopeLabel()).fontSize(14)
            .fontColor(this.gyroscopeStatus==='unavailable' ? EditorTheme.warning : EditorTheme.accent).layoutWeight(1)
        }.width('100%').constraintSize({minHeight:44}).padding(10)
          .backgroundColor(this.gyroscopeStatus==='active' ? EditorTheme.surfaceActive : EditorTheme.surface)
          .borderRadius(EditorTheme.radiusSmall)
        if(this.value.gyroscopeMode!=='off') {
          TouchOptionSlider({label:'灵敏度',value:this.value.gyroscopeSensitivity*100,minimum:10,maximum:300,step:5,suffix:'%',
            onChange:(v: number,mode: SliderChangeMode): void => { this.number('gyro',v,mode) }})
          TouchOptionToggle({label:'横向反转',value:this.value.gyroscopeInvertX,onChange:(v: boolean): void => { this.flag('gyroX',v) }})
          TouchOptionToggle({label:'纵向反转',value:this.value.gyroscopeInvertY,onChange:(v: boolean): void => { this.flag('gyroY',v) }})
        }
        Text(this.gyroscopeStatus==='unavailable' ? '纯触摸仍可使用；切换为关闭后重新启用，将在进入游戏时再次检查。' :
          '菜单、编辑器和后台暂停；启用后进入游戏会检查设备陀螺仪。')
          .fontSize(12).fontColor(EditorTheme.muted).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).backgroundColor(EditorTheme.panel)
  }
}

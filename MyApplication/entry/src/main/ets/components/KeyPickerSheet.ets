/**
 * KeyPickerSheet.ets — 游戏内键位选择浮层。
 *
 * 普通按钮、专用触控动作和手柄映射共用本组件；颜色和圆角来自编辑器主题。
 * 选择、搜索和解除绑定只修改浮层草稿，宿主仍负责撤销、保存以及失败回滚。
 * 确定时通过 onPick 返回 number[]；关闭、遮罩和取消返回 null，不提交草稿。
 *
 * 支持两种模式：
 *   single：单键替换，确定后返回 [code]；解除后确定返回 []，取消返回 null。
 *   combo：勾选组合，确定后按选中顺序返回；全部操作在提交前仅改变选择器内部草稿。
 * 可用区域由宿主容器的 onAreaChange 提供，内容只有一个纵向滚动区，底部操作固定可达。
 */

import { AppRoundIconButton } from './AppRoundIconButton';
import {
  KeyGroup, KeyOption, getKeyOptionGroups, glfwKeyName, MAX_LAYOUT_CONTROL_KEYS
} from 'gamecontrol';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { EditorTheme } from './TouchEditorTheme';

@Component
export struct KeyPickerSheet {
  /** 进入浮层时的按下顺序；本组件复制后编辑，不原地改写宿主传入数组。 */
  @Prop currentKeys: number[] = []
  @Prop currentDescription: string = '当前绑定'
  /** 专用语义动作只接受单键；普通控件继续允许组合键。 */
  @Prop allowCombo: boolean = true
  /** []明确解除绑定，null明确取消；只有确定入口提交草稿数组的副本。 */
  onPick: (keys: number[] | null) => void = () => {}

  /** 分类与搜索均为选择器会话状态，不写入布局或游戏配置。 */
  @State selectedTab: number = 0
  @State pickedKeys: number[] = []
  /** false替换单键，true按点击顺序追加任意键，不限定只有修饰键能组成组合。 */
  @State comboMode: boolean = false
  @State private searchText: string=''
  /** 选择器内即时解释拒绝原因，不让用户确定后才得到整份布局无法保存的笼统错误。 */
  @State private selectionMessage: string = ''
  @State private availableWidth: number=360
  @State private availableHeight: number=600
  // 可拖动：面板相对屏幕中心的偏移（offset 基准）。curDx/Dy 是拖动中的临时增量。
  @State panelDx: number = 0
  @State panelDy: number = 0
  @State curDx: number = 0
  @State curDy: number = 0
  private groups: KeyGroup[] = getKeyOptionGroups()

  /** 搜索跨分组，默认仍定位当前键；不要求用户知道目标属于哪个硬件分组。 */
  private visibleOptions(): KeyOption[] {
    const query: string=this.searchText.trim().toLowerCase()
    if(query.length===0) return this.groups[this.selectedTab].options
    const result: KeyOption[]=[]
    for(const group of this.groups) for(const option of group.options) {
      if(option.name.toLowerCase().includes(query) && !result.some((old: KeyOption): boolean => old.code===option.code)) result.push(option)
    }
    return result
  }
  private panelW(): number { return Math.max(1,Math.min(480,this.availableWidth-24)) }
  /**
   * 大窗口给默认键网格留下完整键行：520vp上限会让搜索、模式与绑定说明占满首屏。
   * 上限提高至680vp，仍逐次夹取在宿主可用高度减24vp内；矮窗口继续由唯一滚动区
   * 吸收内容，固定底栏和选择/取消/解绑契约不变，不额外引入布局测量或订阅。
   */
  private panelH(): number { return Math.max(1,Math.min(680,this.availableHeight-24)) }
  private compactPicker(): boolean { return this.availableHeight<400 }
  private safeOffsetX(): number { const limit: number=Math.max(0,(this.availableWidth-this.panelW())/2-4); return Math.max(-limit,Math.min(limit,this.panelDx+this.curDx)) }
  private safeOffsetY(): number { const limit: number=Math.max(0,(this.availableHeight-this.panelH())/2-4); return Math.max(-limit,Math.min(limit,this.panelDy+this.curDy)) }
  /** 空数组明确解除，null只由取消入口产生；三种结果不得混同。 */
  private confirmChoice(): void {
    const limit: number = this.allowCombo ? MAX_LAYOUT_CONTROL_KEYS : 1
    if (this.pickedKeys.length > limit) {
      this.selectionMessage = this.allowCombo ? '组合键最多支持' + limit.toString() + '个按键，请减少选择' : '此动作只支持单键，请重新选择'
      return
    }
    this.onPick(this.pickedKeys.slice())
  }

  aboutToAppear(): void {
    this.pickedKeys = this.currentKeys.slice()
    // 回显先定位当前键所在分组；打开W的编辑不应先展示“鼠标”，也不需要用户从头找分类。
    if (this.pickedKeys.length > 0) {
      const current: number = this.pickedKeys[this.pickedKeys.length - 1]
      const index: number = this.groups.findIndex((group: KeyGroup): boolean =>
        group.options.some((option: KeyOption): boolean => option.code === current))
      if (index >= 0) this.selectedTab = index
    }
    // 当前已是组合键（≥2 个键）→ 默认进 combo 模式（2026-05-30：不再限定首键须是修饰键，
    // 支持 F3+G 这类纯普通键组合的回显）。
    if (this.allowCombo && this.pickedKeys.length >= 2) {
      this.comboMode = true
    }
  }

  /** 切回单键时保留最后选中的键；与原组合开关契约相同，不在切换时提交宿主。 */
  private setComboMode(enabled: boolean): void {
    this.comboMode = enabled
    if (!enabled && this.pickedKeys.length > 1) {
      this.pickedKeys = [this.pickedKeys[this.pickedKeys.length - 1]]
    }
  }

  /** 解绑先清空浮层草稿，仍需用户点确定；此处不能把[]直接作为已保存结果发出。 */
  private clearPickedKeys(): void {
    this.pickedKeys = []
    this.selectionMessage = ''
  }

  /** 提示解释当前选择规则；上限直接复用布局校验的常量，避免界面和存档容量漂移。 */
  private modeDescription(): string {
    if (!this.allowCombo) return '此动作仅支持一个键；解除绑定后也需要点击确定。'
    return this.comboMode
      ? '最多' + MAX_LAYOUT_CONTROL_KEYS.toString() + '键，按选择顺序按下，倒序释放；再次点选可移除。'
      : '选择一个键替换当前绑定；需要同时按下多个键时切换为组合键。'
  }

  build() {
    Stack() {
      // 遮罩只取消本次选择，不把空数组当作取消，也不让点击穿透到布局画布。
      Column().width('100%').height('100%').backgroundColor('#A6000000')
        .onClick(() => { this.onPick(null) })

      // 面板有确定高度，滚动区只分配标题和底栏之外的剩余空间，避免弹窗高度循环依赖。
      Column({ space: 0 }) {
        this.PickerHeader()
        Scroll() {
          Column({ space: 16 }) {
            this.PickerOptions()
            this.KeyGrid()
          }.width('100%').padding({ top: 8, bottom: 16, right: 4 })
        }
        .scrollBar(BarState.Auto).scrollBarColor(EditorTheme.stroke)
        .layoutWeight(1).width('100%')
        // 所有高度共用这一滚动结构；增加字体或展开键帽时也不会挤掉三个固定操作。
        this.PickerFooter()
      }
      .width(this.panelW()).height(this.panelH())
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .backgroundColor(EditorTheme.panel)
      .borderRadius(EditorTheme.radiusPanel)
      .border({ width: 1, color: EditorTheme.stroke })
      .clip(true)
      .offset({ x: this.safeOffsetX(), y: this.safeOffsetY() })
    }
    .width('100%').height('100%')
    .onAreaChange((_old: Area,current: Area): void => { this.availableWidth=Number(current.width); this.availableHeight=Number(current.height) })
  }

  /** 标题保留原有拖动手势和窗口夹取；矮窗口省去副标题，关闭按钮始终有44vp热区。 */
  @Builder
  PickerHeader() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('键位绑定').fontSize(this.compactPicker() ? 18 : 20)
          .fontColor(EditorTheme.text).fontWeight(FontWeight.Medium)
        if (!this.compactPicker()) {
          Text(this.allowCombo ? '普通按键 · 单键或组合键' : '动作与手柄 · 单键选择')
            .fontSize(12).fontColor(EditorTheme.muted)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column().width(24).height(4).borderRadius(2).backgroundColor(EditorTheme.stroke)
      // 编辑器有自有拖动标题；普通圆按钮不创建导航或提交草稿，取消仍明确返回 null。
      AppRoundIconButton({ name: AppIconName.Close, color: EditorTheme.muted, containerBg: EditorTheme.panel,
        accessibilityLabel: '取消键位选择', controlId: 'key-picker-close', onAction: (): void => { this.onPick(null); } })
    }
    .width('100%').height(this.compactPicker() ? 44 : 60)
    .gesture(
      PanGesture({ fingers: 1, distance: 2 })
        .onActionStart(() => { this.curDx = 0; this.curDy = 0 })
        .onActionUpdate((event: GestureEvent) => {
          if (event) { this.curDx = event.offsetX; this.curDy = event.offsetY }
        })
        .onActionEnd(() => {
          this.panelDx += this.curDx
          this.panelDy += this.curDy
          this.curDx = 0
          this.curDy = 0
        })
    )
  }

  /** 搜索、模式、待应用键帽和完整分类共享草稿；不增加硬件录入或不存在的应用动作分类。 */
  @Builder
  PickerOptions() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Search, iconSize: 18, color: EditorTheme.muted })
        TextInput({ placeholder: '搜索按键，如 Space、F5、右键', text: this.searchText })
          .height(44).layoutWeight(1).fontSize(14)
          .fontColor(EditorTheme.text).placeholderColor(EditorTheme.muted)
          .caretColor(EditorTheme.accent).backgroundColor(EditorTheme.surface)
          .padding({ left: 0, right: 4 })
          .onChange((text: string): void => { this.searchText = text })
      }
      .width('100%').padding({ left: 12, right: 8 }).backgroundColor(EditorTheme.surface)
      .borderRadius(EditorTheme.radiusSmall)

      if (this.allowCombo) {
        Row({ space: 4 }) {
          Button('单键').fontSize(14).height(44).layoutWeight(1)
            .backgroundColor(this.comboMode ? EditorTheme.surface : EditorTheme.surfaceActive)
            .fontColor(this.comboMode ? EditorTheme.muted : EditorTheme.accent)
            .borderRadius(EditorTheme.radiusSmall)
            .accessibilityText('单键模式，选择一个键替换当前绑定')
            .onClick(() => { this.setComboMode(false) })
          Button('组合键').fontSize(14).height(44).layoutWeight(1)
            .backgroundColor(this.comboMode ? EditorTheme.surfaceActive : EditorTheme.surface)
            .fontColor(this.comboMode ? EditorTheme.accent : EditorTheme.muted)
            .borderRadius(EditorTheme.radiusSmall)
            .accessibilityText('组合键模式，最多' + MAX_LAYOUT_CONTROL_KEYS.toString() + '键')
            .onClick(() => { this.setComboMode(true) })
        }.width('100%').padding(4).backgroundColor(EditorTheme.surface)
          .borderRadius(EditorTheme.radiusSmall)
      }

      this.SelectionPreview()
      Text(this.modeDescription()).fontSize(12).fontColor(EditorTheme.muted).width('100%')

      // 八个真实分类完整保留；分类横向滚动，与内容区的纵向滚动互不嵌套竞争。
      Column({ space: 8 }) {
        Text('全部8类 · 左右滑动查看').fontSize(12).fontColor(EditorTheme.muted).width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.groups, (group: KeyGroup, index: number) => {
              Button(group.title).height(44).fontSize(14).padding({ left: 16, right: 16 })
                .backgroundColor(this.selectedTab === index ? EditorTheme.surfaceActive : EditorTheme.surface)
                .fontColor(this.selectedTab === index ? EditorTheme.accent : EditorTheme.muted)
                .borderRadius(EditorTheme.radiusSmall)
                .accessibilityText(group.title + (this.selectedTab === index ? '，已选分类' : '，按键分类'))
                .onClick(() => { this.selectedTab = index })
            }, (group: KeyGroup) => group.title)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 待应用键帽按PRESS顺序排列；来源文字原样来自宿主，明确区分自动、手动和默认绑定。 */
  @Builder
  SelectionPreview() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('待应用的绑定').fontSize(14).fontColor(EditorTheme.text).layoutWeight(1)
        Text(this.currentDescription).fontSize(12).fontColor(EditorTheme.muted)
      }.width('100%')
      if (this.pickedKeys.length === 0) {
        Text('未绑定 · 点击确定后生效').fontSize(14).fontColor(EditorTheme.muted)
          .constraintSize({ minHeight: 44 }).width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(this.pickedKeys, (code: number, index: number) => {
            if (index > 0) {
              Text('+').fontSize(16).fontColor(EditorTheme.muted).margin({ right: 8, bottom: 8 })
            }
            Text(glfwKeyName(code)).fontSize(14).fontColor(EditorTheme.accent)
              .fontWeight(FontWeight.Medium).constraintSize({ minWidth: 44, minHeight: 40 })
              .padding({ left: 12, right: 12, top: 8, bottom: 8 }).textAlign(TextAlign.Center)
              .backgroundColor(EditorTheme.surfaceActive).borderRadius(8)
              .margin({ right: 8, bottom: 8 })
          }, (code: number, index: number) => code.toString() + ':' + index.toString())
        }.width('100%')
      }
    }.width('100%').padding(12).backgroundColor(EditorTheme.surface)
      .borderRadius(EditorTheme.radiusSmall).alignItems(HorizontalAlign.Start)
  }

  /** 网格只绘制当前分类或跨分类搜索结果，滚动交给唯一内容区；无结果也保留恢复搜索的说明。 */
  @Builder
  KeyGrid() {
    Column({ space: 8 }) {
      Text(this.searchText.trim().length > 0 ? '搜索结果 · ' + this.visibleOptions().length.toString() + '项'
        : this.groups[this.selectedTab].title + '按键').fontSize(14).fontColor(EditorTheme.muted).width('100%')
      if (this.visibleOptions().length === 0) {
        Column({ space: 8 }) {
          Text('没有匹配的按键').fontSize(16).fontColor(EditorTheme.text)
          Text('尝试键名、字母或鼠标键，或清空搜索后切换分类。').fontSize(12).fontColor(EditorTheme.muted)
          Button('清空搜索').height(44).fontSize(14).fontColor(EditorTheme.accent)
            .backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
            .onClick(() => { this.searchText = '' })
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      } else {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.visibleOptions(), (option: KeyOption) => {
            Button(option.name).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.isPicked(option.code) ? EditorTheme.accent : EditorTheme.text)
              .backgroundColor(this.isPicked(option.code) ? EditorTheme.surfaceActive : EditorTheme.surface)
              .border({ width: 1, color: this.isPicked(option.code) ? EditorTheme.accent : EditorTheme.stroke })
              .borderRadius(EditorTheme.radiusSmall).constraintSize({ minWidth: 56, minHeight: 44 })
              .padding({ left: 16, right: 16, top: 8, bottom: 8 }).margin({ right: 8, bottom: 8 })
              .accessibilityText(option.name + (this.isPicked(option.code) ? '，已选' : ''))
              .onClick(() => { this.toggleKey(option.code) })
          }, (option: KeyOption) => option.code.toString())
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 限制提示与三项操作常驻底部；解绑只清草稿，取消返回null，确定才调用原确认校验。 */
  @Builder
  PickerFooter() {
    Column({ space: 8 }) {
      if (this.selectionMessage.length > 0) {
        Text(this.selectionMessage).fontSize(12).fontColor(EditorTheme.warning).width('100%')
      }
      Row({ space: 8 }) {
        Button(this.availableWidth < 320 ? '解绑' : '解除绑定')
          .accessibilityText('解除绑定，确认后生效').fontSize(14).height(48).padding({ left: 4, right: 4 })
          .fontColor(EditorTheme.text).backgroundColor(EditorTheme.panel).borderRadius(EditorTheme.radiusSmall)
          .layoutWeight(1).onClick(() => { this.clearPickedKeys() })
        Button('取消').fontSize(14).height(48).padding({ left: 4, right: 4 }).layoutWeight(1)
          .fontColor(EditorTheme.text).backgroundColor(EditorTheme.surface).borderRadius(EditorTheme.radiusSmall)
          .border({ width: 1, color: EditorTheme.stroke }).onClick(() => { this.onPick(null) })
        Button('确定').fontSize(14).fontWeight(FontWeight.Medium).height(48)
          .padding({ left: 4, right: 4 }).layoutWeight(1)
          .backgroundColor(EditorTheme.accent).fontColor(EditorTheme.panel).borderRadius(EditorTheme.radiusSmall)
          .onClick(() => { this.confirmChoice() })
      }.width('100%')
    }.width('100%').padding({ top: 12 })
  }

  /** 每个键只有一个选中投影，网格和键帽共同读取同一有序数组。 */
  private isPicked(code: number): boolean {
    return this.pickedKeys.indexOf(code) >= 0
  }

  /**
   * 点击一个键的处理：
   *   single 模式：替换当前选择（始终只 1 个键）。
   *   combo 模式（2026-05-30 重写）：按点击顺序追加任意键，再点一次取消。
   *     不再限制"非修饰键只能 1 个"——支持 F3+G、F3+N 这类两个普通键的组合。
   *     顺序即 PRESS 顺序（dispatchButton 按 keys[0..n-1] PRESS、倒序 RELEASE），
   *     所以先点 F3 再点 G → [F3,G] → 按下时先 F3 后 G、抬起时先 G 后 F3，正是 F3+G 语义。
   */
  private toggleKey(code: number): void {
    this.selectionMessage = ''
    if (!this.comboMode) {
      this.pickedKeys = [code]
      return
    }
    const idx = this.pickedKeys.indexOf(code)
    if (idx >= 0) {
      // 已选 → 取消（保持其余键的相对顺序）
      this.pickedKeys.splice(idx, 1)
      this.pickedKeys = this.pickedKeys.slice()
      return
    }
    // 未选 → 按点击顺序追加到末尾
    if (this.pickedKeys.length >= MAX_LAYOUT_CONTROL_KEYS) {
      this.selectionMessage = '组合键最多支持' + MAX_LAYOUT_CONTROL_KEYS.toString() + '个按键，请先取消一个已选按键'
      return
    }
    this.pickedKeys = this.pickedKeys.concat([code])
  }
}

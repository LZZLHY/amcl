/**
 * KeyPickerSheet.ets — 改键 UI（阶段 2.1 input-system-refactor）
 *
 * 用法：作为弹窗（Stack 上层 / Sheet）渲染。用户从分组列表里选一个键码，
 * 通过 onPick 回调返回 number[]（组合键序列）；点取消返回 null。
 *
 * 支持两种模式：
 *   single：单键，选中即返回 [code]。
 *   combo：组合键，可以勾选多个修饰键 + 1 个主键，返回 [mods..., main]。
 */

import {
  KeyGroup, KeyOption, getKeyOptionGroups, glfwKeyName
} from 'gamecontrol';

@Component
export struct KeyPickerSheet {
  // 当前已选键序列（PRESS 顺序）
  @Prop currentKeys: number[] = []
  // 键选好后的回调；null = 取消
  onPick: (keys: number[] | null) => void = () => {}

  // 内部状态
  @State selectedTab: number = 0
  @State pickedKeys: number[] = []
  @State comboMode: boolean = false   // false = single（替换），true = combo（追加修饰键）
  // 可拖动：面板相对屏幕中心的偏移（offset 基准）。curDx/Dy 是拖动中的临时增量。
  @State panelDx: number = 0
  @State panelDy: number = 0
  @State curDx: number = 0
  @State curDy: number = 0
  private groups: KeyGroup[] = getKeyOptionGroups()

  aboutToAppear(): void {
    this.pickedKeys = this.currentKeys.slice()
    // 当前已是组合键（≥2 个键）→ 默认进 combo 模式（2026-05-30：不再限定首键须是修饰键，
    // 支持 F3+G 这类纯普通键组合的回显）。
    if (this.pickedKeys.length >= 2) {
      this.comboMode = true
    }
  }

  build() {
    Stack() {
      // 全屏遮罩（点击空白取消）
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick(() => { this.onPick(null) })

      // 可拖动小弹窗（相对屏幕中心，用 offset 平移）
      Column({ space: 6 }) {
        // 可拖动标题栏：左标题 + 中拖动条 + 右关闭
        Row() {
          Text('选择按键').fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold).layoutWeight(1)
          Column().width(20).height(3).borderRadius(2).backgroundColor('#55FFFFFF')
          Text('✕').fontSize(15).fontColor('#FFAAAAAA').width(26).textAlign(TextAlign.Center)
            .onClick(() => { this.onPick(null) })
        }
        .width('100%').height(28)
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

        // 组合键开关
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.comboMode })
            .width(34).height(20)
            .selectedColor('#448AFF')
            .onChange((isOn: boolean) => {
              this.comboMode = isOn
              if (!isOn && this.pickedKeys.length > 1) {
                this.pickedKeys = [this.pickedKeys[this.pickedKeys.length - 1]]
              }
            })
          Text('组合键').fontSize(12).fontColor('#FFFFFFB3').layoutWeight(1)
        }
        .width('100%')

        // 当前选中的键（显示）
        Row({ space: 6 }) {
          Text('当前:').fontSize(11).fontColor('#66FFFFFF')
          Text(this.pickedKeys.length === 0
            ? '(未选)'
            : this.pickedKeys.map((k: number) => glfwKeyName(k)).join(' + '))
            .fontSize(13).fontColor('#FFD54F').fontWeight(FontWeight.Medium).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%').padding(8)
        .backgroundColor('#14FFFFFF').borderRadius(8)

        // Tab 栏（横向滚动，容纳全键盘分组：鼠标/字母/数字/F键/修饰/导航/杂项/小键盘）
        Scroll() {
          Row({ space: 5 }) {
            ForEach(this.groups, (g: KeyGroup, idx: number) => {
              Text(g.title)
                .fontSize(11)
                .fontColor(this.selectedTab === idx ? '#448AFF' : '#FFFFFFB3')
                .fontWeight(this.selectedTab === idx ? FontWeight.Medium : FontWeight.Normal)
                .backgroundColor(this.selectedTab === idx ? '#33448AFF' : '#14FFFFFF')
                .borderRadius(10).padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .onClick(() => { this.selectedTab = idx })
            }, (g: KeyGroup, idx: number) => g.title + idx.toString())
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')

        // 键选项列表（grid 风格，纵向滚动，多余内容可滚）
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.groups[this.selectedTab].options, (opt: KeyOption) => {
              Text(opt.name)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .fontWeight(this.isPicked(opt.code) ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(this.isPicked(opt.code) ? '#448AFF' : '#1FFFFFFF')
                .borderRadius(8)
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .margin(3)
                .onClick(() => { this.toggleKey(opt.code) })
            }, (opt: KeyOption) => opt.code.toString())
          }
        }
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
        .width('100%')

        // 操作按钮
        Row({ space: 8 }) {
          Button('清空').fontSize(12).height(34).fontWeight(FontWeight.Medium)
            .backgroundColor('#1AFFFFFF').fontColor('#FFFFFFB3')
            .borderRadius(16).layoutWeight(1)
            .onClick(() => { this.pickedKeys = [] })
          Button('取消').fontSize(12).height(34).fontWeight(FontWeight.Medium)
            .backgroundColor('#1AFFFFFF').fontColor('#FFFFFFB3')
            .borderRadius(16).layoutWeight(1)
            .onClick(() => { this.onPick(null) })
          Button('确定').fontSize(12).height(34).fontWeight(FontWeight.Medium)
            .backgroundColor('#448AFF').fontColor('#FFFFFF')
            .borderRadius(16).layoutWeight(1)
            .onClick(() => {
              if (this.pickedKeys.length > 0) {
                this.onPick(this.pickedKeys.slice())
              } else {
                this.onPick(null)
              }
            })
        }
        .width('100%')
      }
      .width(320).height(300)
      .padding(14)
      .backgroundColor('#F21C1C1E')
      .borderRadius(14)
      .border({ width: 1, color: '#1FFFFFFF' })
      .offset({ x: this.panelDx + this.curDx, y: this.panelDy + this.curDy })
    }
    .width('100%').height('100%')
  }

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
    this.pickedKeys = this.pickedKeys.concat([code])
  }
}

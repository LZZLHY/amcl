import testNapi from 'libentry.so';
import { GameResolutionState, unavailableGameResolution, parseGameResolutionState, gameResolutionMessage } from '../runtime/GameResolutionState';
import { EditorPalette } from './TouchEditorTheme';
import { GameSettingsRail } from './GameSettingsNavigation';
import { gameSettingsWide, gameSettingsWidth, gameSettingsHeight } from './GameSettingsWindow';

/**
 * 本次游戏的手动比例与故障退出面板。编辑模式只提交会话请求，离开时停止读取状态。
 * 故障守卫传入已锁存的终局状态后，面板只提供退出确认。
 */
@Component
export struct GameResolutionPanel {
  /** 宿主传入纯显示快照；不写会话分辨率、偏好、输入暂停或资源事务。 */
  @Prop palette: EditorPalette = new EditorPalette();
  @Prop screenWidth: number = 360;
  @Prop screenHeight: number = 400;
  /** 守卫确认终局后，退出入口不随后续状态读取失败而消失。 */
  @Prop exitOnly: boolean = false;
  /** 方案名只标识当前编辑环境；本局分辨率不会写入这个方案。 */
  @Prop profileName: string = '';
  onNavigate: (section: string) => void = (_section: string): void => {};
  onReturnGame: () => void = (): void => {};
  onDone: () => void = (): void => {};
  @State private snapshot: GameResolutionState = unavailableGameResolution();
  @State private draft: number = 100;
  @State private error: string = '';
  private timer: number = -1;
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    if (this.exitOnly) return;
    this.refresh();
    this.draft = this.snapshot.requestedPercent;
    this.timer = setInterval((): void => { this.refresh(); }, 250);
  }
  aboutToDisappear(): void {
    this.active = false;
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
  }
  private refresh(): void {
    // 已读到的终局必须保留：后续读失败不能让导航、滑杆或提交按钮重新开放。
    if (!this.active || this.requiresRestart()) return;
    try { this.snapshot = parseGameResolutionState(testNapi.mcGetResolutionState()); }
    catch (_) { this.snapshot = unavailableGameResolution(); }
  }
  private apply(): void {
    // 点击与原生状态回读可能交错：失活、终局或已失去申请资格时不再派发。
    if (!this.active || this.requiresRestart() || !this.snapshot.canRequest) return;
    this.error = '';
    try {
      if (!testNapi.mcRequestResolutionScale(this.draft)) this.error = '当前画面暂不能应用，请等待窗口就绪或重新启动游戏';
      this.refresh();
    } catch (_) { this.error = '分辨率请求未能提交，请重试'; }
  }

  /** 正常编辑面板可能比守卫先看到终局，此时也立即收回调整入口。 */
  private requiresRestart(): boolean {
    return this.exitOnly || this.snapshot.phase === 'restart-required';
  }

  /** 仅实际不可恢复时显示。结束进程会丢失尚未保存的进度，必须由玩家明确确认。 */
  private confirmEndGame(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '结束当前游戏', message: '当前画面无法恢复。结束后需要重新启动，未保存的进度可能丢失。',
        // 预设palette为已验证的HEX；Dialog的颜色类型不接受ResourceColor的number分支。
        buttons: [{ text: '取消', color: this.palette.muted as string }, { text: '结束游戏', color: this.palette.danger as string }]
      }).then((result): void => {
        if (this.active && result.index === 1 && this.requiresRestart()) testNapi.mcForceExit();
      }).catch((): void => { if (this.active) this.error = '结束确认未完成，游戏仍在运行'; });
    } catch (_) { this.error = '结束确认未能打开，游戏仍在运行'; }
  }

  /** 路由只从正常的活动面板发给持有编辑事务的宿主，迟到的点击不能离开故障出口。 */
  private navigate_(section: string): void {
    if (!this.active || this.requiresRestart() || section === 'resolution') return;
    if (section === 'home') this.onDone();
    else if (section === 'game') this.onReturnGame();
    else this.onNavigate(section);
  }

  /** 只有 Native 已核实实际绘制尺寸时才展示生效比例，等待或不可用时保留未知。 */
  private confirmedPercent_(): string {
    return this.snapshot.phase === 'confirmed' ? Math.round(this.snapshot.configuredPercent) + '%' : '—';
  }

  @Builder
  private Header_(wide: boolean) {
    Row({ space: 8 }) {
      if (wide) {
        Text('设置  ›  布局与画面').fontSize(14).fontColor(this.palette.muted).layoutWeight(1)
      } else {
        Button('‹ 设置').type(ButtonType.Normal).height(44).padding({ left: 6, right: 8 })
          .fontSize(15).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .onClick((): void => { this.navigate_('home'); }).accessibilityText('返回设置目录')
        Text('游戏分辨率').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.text)
          .layoutWeight(1).maxLines(2)
        if (this.profileName.length > 0 && this.screenWidth >= 500) {
          Text(this.profileName).fontSize(13).fontColor(this.palette.muted).maxLines(1)
            .constraintSize({ maxWidth: '24%' }).textOverflow({ overflow: TextOverflow.Ellipsis })
            .accessibilityText('当前方案：' + this.profileName)
        }
      }
      Button('返回游戏').type(ButtonType.Normal).height(44).padding({ left: 10, right: 10 })
        .fontSize(14).fontColor(this.palette.text).backgroundColor(Color.Transparent)
        .onClick((): void => { this.navigate_('game'); }).id('resolution-live-return-game')
    }.width('100%')
  }

  @Builder
  private ScaleGroup_() {
    Column({ space: 8 }) {
      Text('渲染比例').fontSize(14).fontColor(this.palette.muted)
      Column({ space: 8 }) {
        Text(Math.round(this.draft) + '%').fontSize(36).fontWeight(FontWeight.Bold).fontColor(this.palette.accent)
        Slider({ value: this.draft, min: 50, max: 100, step: 5 }).width('100%')
          .trackColor(this.palette.stroke).selectedColor(this.palette.accentFill).blockColor(this.palette.accent)
          .onChange((value: number): void => { this.draft = value; }).id('resolution-live-slider')
          .accessibilityText('本次游戏渲染比例，' + Math.round(this.draft) + '%')
        Row() {
          Text('50%').fontSize(13).fontColor(this.palette.muted)
          Blank()
          Text('100%').fontSize(13).fontColor(this.palette.muted)
        }.width('100%')
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
        .backgroundColor(this.palette.surface).borderRadius(16)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private StatusLine_(message: string) {
    Text(message).width('100%').fontSize(15).fontColor(this.palette.text).id('resolution-live-status')
  }

  @Builder
  private StateGroup_() {
    Column({ space: 8 }) {
      Text('本局状态').fontSize(14).fontColor(this.palette.muted)
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Text('当前比例').fontSize(16).fontColor(this.palette.text).layoutWeight(1)
          Text(this.confirmedPercent_()).fontSize(16).fontColor(this.palette.text)
        }.width('100%')
        Divider().strokeWidth(0.5).color(this.palette.stroke)
        this.StatusLine_(gameResolutionMessage(this.snapshot))
        if (this.snapshot.displayWidth > 0 && this.snapshot.displayHeight > 0) {
          Text('显示区域 ' + this.snapshot.displayWidth + ' × ' + this.snapshot.displayHeight)
            .fontSize(13).fontColor(this.palette.muted)
        }
        if (this.error.length > 0) { Text(this.error).fontSize(14).fontColor(this.palette.danger) }
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
        .backgroundColor(this.palette.surface).borderRadius(16)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 正文可滚动，手机横屏、分屏和系统大字下均保留独立的返回和应用操作。 */
  @Builder
  private Content_(wide: boolean) {
    this.Header_(wide)
    Divider().strokeWidth(0.5).color(this.palette.stroke)
    Scroll() {
      Column({ space: wide ? 20 : 12 }) {
        if (wide) {
          Text('游戏分辨率').fontSize(32).fontWeight(FontWeight.Bold).fontColor(this.palette.text)
          Text('调整这一局游戏的渲染比例。').fontSize(15).fontColor(this.palette.muted)
        } else if (this.profileName.length > 0 && this.screenWidth < 500) {
          Text('当前方案：' + this.profileName).fontSize(13).fontColor(this.palette.muted)
        }
        if (wide) {
          Row({ space: 16 }) {
            Column() { this.ScaleGroup_() }.layoutWeight(1)
            Column() { this.StateGroup_() }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        } else {
          this.ScaleGroup_()
          this.StateGroup_()
        }
      }.width('100%').padding({ top: wide ? 18 : 12, bottom: 14 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
    Divider().strokeWidth(0.5).color(this.palette.stroke)
    Row({ space: 8 }) {
      if (this.screenWidth >= 600) {
        Text('仅对当前游戏生效').fontSize(13).fontColor(this.palette.muted).layoutWeight(1)
      } else { Blank() }
      Button('返回').height(44).fontSize(15).fontColor(this.palette.text).backgroundColor(this.palette.surface)
        .onClick((): void => { this.navigate_('home'); }).id('resolution-live-back')
      Button('仅应用到本局游戏').height(44).fontSize(15).fontColor(this.palette.onAccent)
        .backgroundColor(this.palette.accentFill).enabled(this.snapshot.canRequest)
        .onClick((): void => { this.apply(); }).id('resolution-live-apply')
    }.width('100%').padding({ top: 6, bottom: 6 })
  }

  /** 守卫也独立复用此出口。这里没有普通分辨率导航、设置事务或返回游戏操作。 */
  @Builder
  private Failure_() {
    Scroll() {
      Column({ space: 14 }) {
        Text('画面尺寸异常').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.palette.text)
        this.StatusLine_('画面尺寸未能确认，请返回启动器后重新启动游戏')
        if (this.error.length > 0) { Text(this.error).fontSize(14).fontColor(this.palette.danger) }
        Button('结束当前游戏').height(44).width('100%').onClick((): void => { this.confirmEndGame(); })
          .backgroundColor(this.palette.surface).fontColor(this.palette.danger).id('resolution-live-end-game')
      }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
    }.width(Math.max(1, Math.min(400, this.screenWidth - 16)))
      .constraintSize({ maxHeight: Math.max(1, this.screenHeight - 12) }).backgroundColor(this.palette.panel).borderRadius(18)
  }

  build() {
    Stack() {
      if (this.requiresRestart()) {
        this.Failure_()
      } else {
        Row() {
          if (gameSettingsWide(this.screenWidth, this.screenHeight)) {
            GameSettingsRail({ palette: this.palette, selected: 'resolution', profileName: this.profileName,
              allowLiveResolution: true, onSelect: (section: string): void => { this.navigate_(section); } })
          }
          Column() { this.Content_(gameSettingsWide(this.screenWidth, this.screenHeight)) }
            .layoutWeight(1).height('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
            .alignItems(HorizontalAlign.Start)
        }.width(gameSettingsWidth(this.screenWidth,this.screenHeight)).height(gameSettingsHeight(this.screenWidth,this.screenHeight))
          .id('game-settings-sheet')
          .backgroundColor(this.palette.panel).borderRadius(this.palette.radiusPanel).clip(true)
      }
    }.width('100%').height('100%').backgroundColor(this.exitOnly ? Color.Transparent : this.palette.overlay)
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
      .onMouse((event: MouseEvent): void => { event.stopPropagation(); })
  }
}

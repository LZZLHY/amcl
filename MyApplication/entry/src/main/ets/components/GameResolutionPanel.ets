import testNapi from 'libentry.so';
import { GameResolutionState, unavailableGameResolution, parseGameResolutionState, gameResolutionMessage } from '../runtime/GameResolutionState';
import { EditorPalette } from './TouchEditorTheme';

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
    if (!this.active) return;
    try { this.snapshot = parseGameResolutionState(testNapi.mcGetResolutionState()); }
    catch (_) { this.snapshot = unavailableGameResolution(); }
  }
  private apply(): void {
    if (this.requiresRestart()) return;
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

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.requiresRestart() ? '画面尺寸异常' : '本次游戏分辨率').fontSize(20).fontColor(this.palette.text)
        if (!this.requiresRestart()) {
          Text(this.draft + '%').fontSize(20).fontColor(this.palette.text)
          Slider({ value: this.draft, min: 50, max: 100, step: 5 }).width('100%')
            .trackColor(this.palette.surfaceActive).selectedColor(this.palette.accentFill).blockColor(this.palette.accent)
            .onChange((value: number): void => { this.draft = value; }).id('resolution-live-slider')
          // 作用范围直接写在行动上，不在标题下重复解释“本次游戏”。
          Button('仅应用到本局游戏').width('100%').height(44)
            .backgroundColor(this.palette.accentFill).fontColor(this.palette.onAccent)
            .enabled(this.snapshot.canRequest)
            .onClick((): void => { this.apply(); }).id('resolution-live-apply')
        }
        Text(this.requiresRestart() ? '画面尺寸未能确认，请返回启动器后重新启动游戏' : gameResolutionMessage(this.snapshot))
          .fontSize(14).fontColor(this.palette.text).id('resolution-live-status')
        if (!this.requiresRestart() && this.snapshot.displayWidth > 0) {
          Text('显示区域 ' + this.snapshot.displayWidth + ' × ' + this.snapshot.displayHeight)
            .fontSize(13).fontColor(this.palette.muted)
        }
        if (this.error.length > 0) {
          Text(this.error).fontSize(14).fontColor(this.palette.danger)
        }
        if (this.requiresRestart()) {
          Button('结束当前游戏').height(44).width('100%').onClick((): void => { this.confirmEndGame(); })
            .backgroundColor(this.palette.surface).fontColor(this.palette.danger)
            .id('resolution-live-end-game')
        } else {
          Button('返回').height(44).width('100%').onClick((): void => { this.onDone(); }).id('resolution-live-back')
            .backgroundColor(this.palette.surface).fontColor(this.palette.accent)
        }
      }.padding(20).width('100%')
    }.width(Math.min(360, Math.max(160, this.screenWidth - 24)))
      .constraintSize({ maxHeight: Math.max(120, this.screenHeight * 0.9) })
      .backgroundColor(this.palette.panel).borderRadius(16)
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
      .onMouse((event: MouseEvent): void => { event.stopPropagation(); })
  }
}

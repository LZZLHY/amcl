import testNapi from 'libentry.so';
import { parseGameResolutionState } from '../runtime/GameResolutionState';
import { GameResolutionPanel } from './GameResolutionPanel';
import { AppLogger, LOG_DOMAIN_UI, LogTags, ThemeColors } from 'commons';
import { EditorPalette, editorPalette } from './TouchEditorTheme';

/**
 * 无法确认/恢复的几何必须有独立于游戏坐标的退出入口。正常状态完全不参与命中，
 * 每秒只读一次Native状态；终局才显示面板，并通知页面暂停实体输入。旧页面离开即
 * 取消计时，不改变Native会话或把失败清成成功。
 */
@Component
export struct GameResolutionGuard {
  /** 故障出口也消费同一显示快照，不把默认绿色palette重新带回已选主题。 */
  @Prop @Watch('syncPalette_') toolTheme: ThemeColors = {} as ThemeColors;
  @State private palette: EditorPalette = new EditorPalette();
  /** 只在初始化/主题变化时转换，原Native状态轮询不分配颜色对象。 */
  private syncPalette_(): void { this.palette = editorPalette(this.toolTheme); }
  onFailure: () => void = (): void => {};
  @State private fatal: boolean = false;
  @State private widthVp: number = 360;
  @State private heightVp: number = 400;
  private timer: number = -1;
  private active: boolean = false;
  private readFailureWarned: boolean = false;
  aboutToAppear(): void {
    this.syncPalette_();
    this.active = true;
    this.readFailureWarned = false;
    this.timer = setInterval((): void => {
      if (!this.active || this.fatal) return;
      try {
        if (parseGameResolutionState(testNapi.mcGetResolutionState()).phase === 'restart-required') {
          this.fatal = true;
          this.onFailure();
        }
      } catch (error) {
        // 读取失败不制造不可恢复的几何结论；每次显示只记首个异常，原轮询继续。
        if (!this.readFailureWarned) {
          this.readFailureWarned = true;
          AppLogger.warn(LogTags.PAGE_MC_GAME, '暂时无法读取游戏分辨率状态', error, LOG_DOMAIN_UI);
        }
      }
    }, 1000);
  }
  aboutToDisappear(): void {
    this.active = false;
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
  }
  build() {
    Stack() {
      if (this.fatal) {
        GameResolutionPanel({ palette: this.palette, screenWidth: this.widthVp, screenHeight: this.heightVp })
      }
    }.width('100%').height('100%')
      .backgroundColor(this.fatal ? '#CC000000' : Color.Transparent)
      .hitTestBehavior(this.fatal ? HitTestMode.Default : HitTestMode.None)
      .onAreaChange((_old: Area, area: Area): void => {
        this.widthVp = Number(area.width); this.heightVp = Number(area.height);
      })
  }
}

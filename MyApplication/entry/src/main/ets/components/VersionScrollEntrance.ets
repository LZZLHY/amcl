import { UiMotion } from './UiMotion';
import { VersionRowsInitialFrame } from './VersionDownloadRows';

/** 仅负责版本卡片首次滚进视口的合成动效。页面拥有版本身份、已读集合和整组动画的优先权。 */
@Component
export struct VersionScrollEntrance {
  shouldStage: () => boolean = (): boolean => false;
  onFirstVisible: () => boolean = (): boolean => false;
  @BuilderParam content: () => void;
  @State private staged_: boolean = false;
  private alive_: boolean = false;
  private visible_: boolean = false;
  private frame_: VersionRowsInitialFrame | null = null;

  aboutToAppear(): void {
    this.alive_ = true;
    // 懒列表可提前创建行。此处只设置可读的预备姿态，没有实际可见回调就不消费版本身份。
    this.staged_ = this.shouldStage() && !UiMotion.reduced();
  }

  aboutToDisappear(): void {
    this.alive_ = false;
    this.visible_ = false;
    this.settle_();
  }

  private settle_(): void {
    this.frame_?.cancel();
    this.frame_ = null;
    this.staged_ = false;
  }

  private visibility_(ratio: number): void {
    if (!this.alive_) return;
    if (ratio <= 0) {
      this.visible_ = false;
      this.settle_();
      return;
    }
    if (this.visible_) return;
    this.visible_ = true;
    // 真正露出后由父页消费一次；当整组切换、搜索或回看时直接呈现最终内容。
    if (!this.onFirstVisible() || UiMotion.reduced()) { this.settle_(); return; }
    this.staged_ = true;
    const context = this.getUIContext();
    this.frame_ = new VersionRowsInitialFrame(context, (): void => {
      this.frame_ = null;
      context.animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => { this.staged_ = false; });
    });
    try { context.postFrameCallback(this.frame_); }
    catch (_) { this.settle_(); }
  }

  build() {
    // 外层仅测量、不变形；短距离移动不会反向触发自己的可见区回调，子卡片自始即可点击。
    Column() {
      Column() { this.content() }.width('100%')
        .opacity(this.staged_ ? 0.68 : 1).translate({ y: this.staged_ ? 5 : 0 })
    }.width('100%')
    .onVisibleAreaChange([0, 0.02], (_expanding: boolean, ratio: number): void => { this.visibility_(ratio); })
  }
}

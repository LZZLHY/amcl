/**
 * 工作区内容切换的短距离淡入。数据立即切换，只对合成属性做动画，
 * 不截屏、不复制日志列表、不让旧活动内容与新活动按钮同时存在。
 */
import { UiMotion } from './UiMotion';

@Component
export struct ActivityPaneMotion {
  @Prop @Watch('reveal_') identity: string = '';
  @Prop @Watch('visibility_') active: boolean = true;
  @BuilderParam content: () => void = this.empty_;
  @State private alpha: number = 1;
  @State private paneY: number = 0;
  private frame: number = -1;
  private alive: boolean = false;

  @Builder
  private empty_() { Column() {} }
  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; this.cancel_(); }
  private cancel_(): void { if (this.frame >= 0) clearTimeout(this.frame); this.frame = -1; }
  /** 隐藏时收敛到最终状态，返回页面不会补播已经过时的动画。 */
  private visibility_(): void {
    if (!this.active) { this.cancel_(); this.alpha = 1; this.paneY = 0; }
  }
  private reveal_(): void {
    this.cancel_();
    if (!this.alive || !this.active || UiMotion.reduced()) { this.alpha = 1; this.paneY = 0; return; }
    this.alpha = 0.55; this.paneY = 6;
    this.frame = setTimeout((): void => {
      this.frame = -1;
      if (!this.alive || !this.active) return;
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => { this.alpha = 1; this.paneY = 0; });
    }, 16);
  }
  build() {
    Column({ space: 12 }) { this.content() }.width('100%').height('100%')
      .opacity(this.alpha).translate({ y: this.paneY })
  }
}

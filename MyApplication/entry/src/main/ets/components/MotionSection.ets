/**
 * 有界错峰入场容器。只动画 translate/opacity，不逐帧改变布局尺寸。
 * 首帧提交后统一下发入场动画；销毁时清理待执行回调，数据更新不会重复入场。
 */
import { UiMotion } from './UiMotion';

@Component
export struct MotionSection {
  @Prop order: number = 0;
  @Prop animateEntrance: boolean = true;
  @BuilderParam content: () => void = this.emptyContent_;
  @State private enterAlpha: number = 0;
  @State private enterY: number = UiMotion.ENTER_Y;
  private frameTimer: number = -1;
  private alive: boolean = false;

  @Builder
  private emptyContent_() { Column() {} }

  aboutToAppear(): void {
    this.alive = true;
    if (!this.animateEntrance || UiMotion.reduced()) {
      this.enterAlpha = 1; this.enterY = 0;
    }
  }

  /** 一个首帧调度 + 原生 delay 构成错峰，不用多段 setTimeout 串联动画。 */
  private enter_(): void {
    if (this.enterAlpha === 1 || this.frameTimer >= 0) return;
    this.frameTimer = setTimeout((): void => {
      this.frameTimer = -1;
      if (!this.alive) return;
      this.getUIContext().animateTo({ duration: UiMotion.ENTER_MS, delay: UiMotion.stagger(this.order),
        curve: Curve.EaseOut }, (): void => { this.enterAlpha = 1; this.enterY = 0; });
    }, 16);
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.frameTimer >= 0) clearTimeout(this.frameTimer);
    this.frameTimer = -1;
  }

  build() {
    Column() { this.content() }.width('100%')
      .opacity(this.enterAlpha).translate({ y: this.enterY })
      .hitTestBehavior(this.enterAlpha === 0 ? HitTestMode.None : HitTestMode.Default)
      .onAppear(() => { this.enter_(); })
  }
}

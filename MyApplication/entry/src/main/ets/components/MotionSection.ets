/**
 * 有界错峰入场容器。只动画 translate/opacity，不逐帧改变布局尺寸。
 * 首帧提交后统一下发入场动画；可由宿主延后放行，避免启动遮罩下面提前播完。
 * 销毁时清理待执行回调，数据更新和宿主重复放行不会重复入场。
 */
import { UiMotion } from './UiMotion';

@Component
export struct MotionSection {
  @Prop order: number = 0;
  @Prop animateEntrance: boolean = true;
  /**
   * 宿主入场闸门。false 时保留布局但不排队；首次变为 true 后才呈现内容。
   * 默认 true 保持既有页面行为，已经完成的入场不会因后续开关而重新播放。
   */
  @Prop @Watch('onEntranceEnabledChanged_') entranceEnabled: boolean = true;
  @BuilderParam content: () => void = this.emptyContent_;
  @State private enterAlpha: number = 0;
  @State private enterY: number = UiMotion.ENTER_Y;
  private frameTimer: number = -1;
  private alive: boolean = false;

  @Builder
  private emptyContent_() { Column() {} }

  aboutToAppear(): void {
    this.alive = true;
    if (this.entranceEnabled && (!this.animateEntrance || UiMotion.reduced())) {
      this.enterAlpha = 1; this.enterY = 0;
    }
  }

  /**
   * 放行时沿用同一入场入口；撤销放行只清除尚未执行的调度，不回退已完成内容。
   * @Watch 不改写被监听的 entranceEnabled，避免父子状态相互触发。
   */
  private onEntranceEnabledChanged_(): void {
    if (this.entranceEnabled) {
      this.enter_();
    } else if (this.frameTimer >= 0) {
      clearTimeout(this.frameTimer);
      this.frameTimer = -1;
    }
  }

  /**
   * 一个首帧调度 + 原生 delay 构成错峰，不用多段 setTimeout 串联动画。
   * 每次排队和执行前均核对存活/放行状态；关闭动画的宿主直接呈现最终状态。
   */
  private enter_(): void {
    if (!this.alive || !this.entranceEnabled || this.enterAlpha === 1 || this.frameTimer >= 0) return;
    if (!this.animateEntrance || UiMotion.reduced()) {
      this.enterAlpha = 1;
      this.enterY = 0;
      return;
    }
    this.frameTimer = setTimeout((): void => {
      this.frameTimer = -1;
      if (!this.alive || !this.entranceEnabled) return;
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

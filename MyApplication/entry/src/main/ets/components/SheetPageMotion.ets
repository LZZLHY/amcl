/**
 * SheetPageMotion — 同一 Sheet 内保留式分页的共用位移状态。
 *
 * 调用方先挂载前后两页，再用 offset() 将页槽平移；本类只动画化页位置，不拥有业务
 * 状态或子组件，不使用定时器模拟结束。moving 用于阻止转场中重复点击；dispose()
 * 使组件销毁后的框架完成回调失效，不能由旧回调重置新页面或执行宿主返回。
 */
import { FrameCallback, UIContext } from '@kit.ArkUI';

/**
 * 一次性的“初始帧已完成”边界。onIdle 由 SDK 在帧渲染完成后调用，不能用任意毫秒
 * 延迟猜测初次挂载是否完成。取消后清空闭包，帧队列即使稍后回调也不再持有页面上下文。
 */
class SheetMotionInitialFrame extends FrameCallback {
  private action_: (() => void) | null;
  constructor(action: () => void) { super(); this.action_ = action; }
  onIdle(_timeLeftInNano: number): void {
    const action: (() => void) | null = this.action_;
    this.action_ = null;
    if (action !== null) action();
  }
  cancel(): void { this.action_ = null; }
}

@Observed
export class SheetPageMotion {
  position: number = 0;
  viewport: number = 0;
  moving: boolean = false;
  private revision_: number = 0;
  private disposed_: boolean = false;
  private initialFrame_: SheetMotionInitialFrame | null = null;

  /** 初次出现或历史深链直接定位；不在组件生命周期里启动动画。 */
  reset(position: number): void {
    this.revision_++;
    this.initialFrame_?.cancel();
    this.initialFrame_ = null;
    this.disposed_ = false;
    this.position = position;
    this.moving = false;
  }

  /** 实际容器宽度使用 vp，兼容受限 Sheet 和居中路由，不以屏幕宽度代替。 */
  resize(width: number): void {
    if (Number.isFinite(width) && width > 0 && Math.abs(width - this.viewport) > 0.5) this.viewport = width;
  }

  /** 页槽可以是父层固定序号，也可以是子层临时的前后两槽；公式保持一致。 */
  offset(slot: number): number { return (slot - this.position) * this.viewport; }

  /**
   * 统一 280ms 快出慢入横移。调用方先挂载目的页，本方法等一次真实渲染完成后才
   * 改目标位移，保证新节点拥有屏外初始帧；moving 同时覆盖等帧与动画阶段。
   * onFinish 只在当前实例仍存活且没有更新的位移动画时执行。
   */
  move(context: UIContext, target: number, onFinish: () => void = (): void => {}): void {
    if (this.disposed_ || this.moving || this.position === target) return;
    const revision: number = ++this.revision_;
    this.moving = true;
    this.initialFrame_ = new SheetMotionInitialFrame((): void => {
      this.initialFrame_ = null;
      if (this.disposed_ || revision !== this.revision_) return;
      context.animateTo({
        duration: 280,
        curve: Curve.FastOutSlowIn,
        onFinish: (): void => {
          if (this.disposed_ || revision !== this.revision_) return;
          this.moving = false;
          onFinish();
        },
      }, (): void => { this.position = target; });
    });
    context.postFrameCallback(this.initialFrame_);
  }

  /** 不取消外部下载或导出；这里只撤销本视图动画回调的执行资格。 */
  dispose(): void {
    this.revision_++;
    this.initialFrame_?.cancel();
    this.initialFrame_ = null;
    this.disposed_ = true;
    this.moving = false;
  }
}

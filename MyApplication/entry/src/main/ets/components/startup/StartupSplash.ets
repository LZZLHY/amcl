/**
 * AMCL 启动覆盖层：主题纯背景首帧→屏外体素聚斧→真实准备状态下的悬浮→首页归位。
 *
 * 只负责视觉生命周期。ready 必须由宿主在必要准备和首页首轮布局完成后置 true；
 * 动画不能自行宣布业务就绪。onReveal 只允许宿主显现首页，onFinished 才允许
 * 开放输入、焦点和后续弹窗。失败/重试保留已聚合的斧头，不反复播放整个开场。
 */
import { FrameCallback } from '@kit.ArkUI';
import { AXE_ASSEMBLY_MS, AxeSceneFrame, AxeVoxelScene } from './AxeVoxelScene';
import { StartupAssemblyClock, StartupTargetRect } from './StartupTypes';

/**
 * 一次性 vsync 回调。平台 API 无取消方法，因此停止时主动清除闭包；即使窗口
 * 很久以后才投递旧回调，也不再持有组件或触发绘制，不创建后台定时器。
 */
class StartupFrameCallback extends FrameCallback {
  private callback: ((frameTimeNanos: number) => void) | undefined;

  /** 每个实例仅执行一次；重复调度由组件显式续约。 */
  constructor(callback: (frameTimeNanos: number) => void) {
    super();
    this.callback = callback;
  }

  /** 平台回调先释放自身闭包，再将单调帧时间交给组件。 */
  onFrame(frameTimeNanos: number): void {
    const current: ((frameTimeNanos: number) => void) | undefined = this.callback;
    this.callback = undefined;
    if (current !== undefined) {
      current(frameTimeNanos);
    }
  }

  /** 组件消失/后台时切断唯一待执行回调对组件的引用。 */
  dispose(): void {
    this.callback = undefined;
  }
}

/**
 * V1 状态组件，与现有 Index/HomeTab 保持一致。几何时间和顶点均不使用 @State，
 * 逐帧仅向 Canvas 发绘制命令；只有等待提示的阈值变化会触发 ArkUI 结构刷新。
 */
@Component
export struct StartupSplash {
  @Prop @Watch('onInputChanged_') ready: boolean = false;
  @Prop @Watch('onInputChanged_') failed: boolean = false;
  @Prop @Watch('onInputChanged_') isDark: boolean = false;
  @Prop @Watch('onActiveChanged_') active: boolean = true;
  @Prop @Watch('onInputChanged_') reducedMotion: boolean = false;
  @Prop @Watch('onInputChanged_') targetRect: StartupTargetRect = new StartupTargetRect();
  @Prop failureMessage: string = '';
  /** 在首个实际入屏体素已提交后的下一帧通知宿主，只调用一次。 */
  onFirstFrame: () => void = (): void => {};
  /** 开始揭示首页，只改变可见性，宿主继续封锁输入。 */
  onReveal: () => void = (): void => {};
  /** 收尾最终帧已提交后通知宿主解除覆盖层，只调用一次。 */
  onFinished: () => void = (): void => {};
  /** 重试只通知宿主，必要业务状态仍由宿主重新执行并回传。 */
  onRetry: () => void = (): void => {};

  @State private hintLevel_: number = 0;
  @State private firstFrameVisible_: boolean = false;
  @State private exitingUi_: boolean = false;
  private context_: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private scene_: AxeVoxelScene = new AxeVoxelScene();
  private frame_: AxeSceneFrame = new AxeSceneFrame();
  private pendingFrame_: StartupFrameCallback | undefined = undefined;
  private mounted_: boolean = false;
  private canvasReady_: boolean = false;
  private blankFramePassed_: boolean = false;
  private firstMovementPassed_: boolean = false;
  private firstCallbackSent_: boolean = false;
  private finished_: boolean = false;
  private finalFramePassed_: boolean = false;
  private revealed_: boolean = false;
  private lastFrameNanos_: number = 0;
  private elapsedMs_: number = 0;
  private assemblyClock_: StartupAssemblyClock = new StartupAssemblyClock();
  private foregroundMs_: number = 0;
  private exitStartedMs_: number = -1;
  private exitStartedForegroundMs_: number = -1;
  private canvasGlobalX_: number = 0;
  private canvasGlobalY_: number = 0;

  /** 出现时只启用调度资格；Canvas.onReady 后才允许访问尺寸与绘制。 */
  aboutToAppear(): void {
    this.mounted_ = true;
  }

  /** 销毁会切断唯一待执行帧，避免首页进入后继续占用 CPU 或回调旧宿主。 */
  aboutToDisappear(): void {
    this.mounted_ = false;
    this.stopFrames_();
  }

  /**
   * Canvas 初建或改尺寸都会进入这里。首次只画纯背景；后续缩窗直接按同一进度
   * 重绘，不重置聚合、悬浮或收尾，也不会再次触发初始化回调。
   */
  private onCanvasReady_(): void {
    this.canvasReady_ = true;
    this.frame_.width = this.context_.width;
    this.frame_.height = this.context_.height;
    this.drawFrame_();
    this.scheduleFrame_();
  }

  /** 前后台累计时间分开，恢复后第一帧不把后台停留时间计入动画。 */
  private onActiveChanged_(): void {
    this.lastFrameNanos_ = 0;
    if (!this.active) {
      this.stopFrames_();
    } else {
      this.scheduleFrame_();
    }
  }

  /**
   * 失败时撤销尚未结束的收尾，完整保留品牌斧和真实重试入口；ready 变化只唤醒
   * 下一帧，绝不在状态监听回调里直接调用业务完成回调。
   */
  private onInputChanged_(): void {
    if (this.failed && !this.finished_) {
      this.exitStartedMs_ = -1;
      this.exitStartedForegroundMs_ = -1;
      this.exitingUi_ = false;
      this.finalFramePassed_ = false;
    }
    // 静态等待可能正排队200ms的延迟帧；状态变化必须立即唤醒，不能等旧期限。
    this.pendingFrame_?.dispose();
    this.pendingFrame_ = undefined;
    this.scheduleFrame_();
  }

  /** 取消的是闭包，不依赖不存在的 removeFrameCallback API。 */
  private stopFrames_(): void {
    this.pendingFrame_?.dispose();
    this.pendingFrame_ = undefined;
    this.lastFrameNanos_ = 0;
  }

  /**
   * 任意时刻最多有一个待执行回调。减弱动态且正在等待时降到200ms检查一次提示，
   * ready/failed 变化仍会由 @Watch 唤醒；普通动画直接跟随窗口 vsync。
   */
  private scheduleFrame_(): void {
    if (!this.mounted_ || !this.canvasReady_ || !this.active || this.finished_ ||
      this.pendingFrame_ !== undefined) {
      return;
    }
    const next: StartupFrameCallback = new StartupFrameCallback((time: number): void => this.onVsync_(time));
    this.pendingFrame_ = next;
    if (this.reducedMotion && this.firstCallbackSent_ && (!this.ready || this.failed) &&
      this.foregroundMs_ > 200) {
      this.getUIContext().postDelayedFrameCallback(next, 200);
    } else {
      this.getUIContext().postFrameCallback(next);
    }
  }

  /**
   * 前台时间用于真实等待提示；视觉时间对单次卡顿限幅，防止首屏同步准备后
   * 直接跳过聚合。首次空白帧和首个运动帧各至少跨过一次 vsync，再通知宿主。
   */
  private onVsync_(time: number): void {
    this.pendingFrame_ = undefined;
    if (!this.mounted_ || !this.active || this.finished_) {
      return;
    }
    const delta: number = this.lastFrameNanos_ > 0 ? Math.max(0, (time - this.lastFrameNanos_) / 1000000) : 0;
    this.lastFrameNanos_ = time;
    this.foregroundMs_ += delta;
    if (!this.blankFramePassed_) {
      this.blankFramePassed_ = true;
      this.drawFrame_();
      this.scheduleFrame_();
      return;
    }
    this.elapsedMs_ = this.assemblyClock_.advance(delta, this.foregroundMs_, this.ready,
      this.failed, this.reducedMotion, AXE_ASSEMBLY_MS);
    // 回调发生在上一运动帧之后，昂贵准备不会抢在第一块入屏之前运行。
    if (this.firstMovementPassed_ && !this.firstCallbackSent_) {
      this.firstCallbackSent_ = true;
      this.firstFrameVisible_ = true;
      this.onFirstFrame();
      if (!this.mounted_) {
        return;
      }
    }
    const assemblyDone: boolean = this.reducedMotion ? this.elapsedMs_ >= 160 : this.elapsedMs_ >= AXE_ASSEMBLY_MS;
    if (assemblyDone && this.ready && !this.failed && this.exitStartedMs_ < 0) {
      this.exitStartedMs_ = this.elapsedMs_;
      this.exitStartedForegroundMs_ = this.foregroundMs_;
      this.exitingUi_ = true;
      if (!this.revealed_) {
        this.revealed_ = true;
        this.onReveal();
      }
    }
    const hint: number = this.foregroundMs_ >= 10000 ? 2 : this.foregroundMs_ >= 3000 ? 1 : 0;
    if (hint !== this.hintLevel_) {
      this.hintLevel_ = hint;
    }
    this.drawFrame_();
    if (this.scene_.hasVisiblePixels || this.elapsedMs_ >= 500) {
      // 尺寸异常或绘制退化仍须启动业务，不让一个视觉判断阻止整个应用初始化。
      this.firstMovementPassed_ = true;
    }
    const exitDuration: number = this.reducedMotion ? 160 : 380;
    if (this.exitStartedForegroundMs_ >= 0 &&
      this.foregroundMs_ - this.exitStartedForegroundMs_ >= exitDuration && this.ready && !this.failed) {
      if (this.finalFramePassed_) {
        this.finished_ = true;
        this.stopFrames_();
        this.onFinished();
        return;
      }
      // 最终归位图必须提交一次；下一vsync才允许首页原图接管。
      this.finalFramePassed_ = true;
    }
    this.scheduleFrame_();
  }

  /**
   * 背景独立清除并随收尾降低透明度，立体斧仍保持不透明直到交给首页。无有效
   * 锚点（例如外部入口直达其它页面）时采用中心短淡出，不无限等待首页矩形。
   */
  private drawFrame_(): void {
    const width: number = this.context_.width;
    const height: number = this.context_.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    const duration: number = this.reducedMotion ? 160 : 380;
    // 收尾严格按真实前台时间计时，早期聚合的1.5倍速不会压缩380ms归位。
    const exit: number = this.exitStartedForegroundMs_ >= 0
      ? Math.min(1, (this.foregroundMs_ - this.exitStartedForegroundMs_) / duration) : 0;
    this.context_.clearRect(0, 0, width, height);
    this.context_.globalAlpha = 1 - exit * exit * (3 - 2 * exit);
    this.context_.fillStyle = this.isDark ? '#101114' : '#FFFFFF';
    this.context_.fillRect(0, 0, width, height);
    this.context_.globalAlpha = 1;
    this.frame_.width = width;
    this.frame_.height = height;
    this.frame_.elapsedMs = this.blankFramePassed_ ? this.elapsedMs_ : 0;
    this.frame_.exitProgress = exit;
    this.frame_.exitStartedMs = Math.max(0, this.exitStartedMs_);
    this.frame_.targetX = this.targetRect.x - this.canvasGlobalX_ + this.targetRect.width * 0.5;
    this.frame_.targetY = this.targetRect.y - this.canvasGlobalY_ + this.targetRect.height * 0.5;
    this.frame_.targetSize = Math.min(this.targetRect.width, this.targetRect.height);
    this.frame_.hasTarget = this.targetRect.valid && this.frame_.targetSize > 0;
    this.frame_.reducedMotion = this.reducedMotion;
    this.scene_.draw(this.context_, this.frame_);
  }

  /** 单行状态仅在等待过长或失败时出现，正常短启动始终没有文字或进度圈。 */
  private statusText_(): string {
    if (this.failed) {
      return this.failureMessage.length > 0 ? this.failureMessage : '应用准备失败，请重试';
    }
    return this.hintLevel_ >= 2 ? '准备时间较长，请稍候' : '正在准备应用';
  }

  /** 重试不清除视觉进度，避免失败后重复从屏外聚斧。 */
  private retry_(): void {
    this.onRetry();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Canvas(this.context_)
        .width('100%')
        .height('100%')
        .onReady((): void => this.onCanvasReady_())
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.canvasGlobalX_ = Number(newArea.globalPosition.x);
          this.canvasGlobalY_ = Number(newArea.globalPosition.y);
          // 仅位置改变不会触发Canvas.onReady，窗口/安全区改变后在这里更新锚点换算。
          if (this.canvasReady_ && this.active && !this.finished_) {
            this.drawFrame_();
          }
        })
        .accessibilityLevel('no')

      if (this.firstFrameVisible_ && !this.exitingUi_ && (this.failed || this.hintLevel_ > 0)) {
        Column({ space: 18 }) {
          Text(this.statusText_())
            .fontSize(14)
            .fontColor(this.isDark ? '#B4B5BC' : '#60636B')
            .textAlign(TextAlign.Center)
            .maxLines(3)
          if (this.failed) {
            Button('重试')
              .fontSize(15)
              .fontColor(this.isDark ? '#F5F5F7' : '#292B30')
              .backgroundColor(this.isDark ? '#303138' : '#E9EAEE')
              .height(42)
              .padding({ left: 28, right: 28 })
              .onClick((): void => this.retry_())
          }
        }
        .width('80%')
        .position({ x: '10%', y: '67%' })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.Block)
    .accessibilityText(this.failed ? this.statusText_() : '应用启动中')
  }
}

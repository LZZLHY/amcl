/**
 * 版本与 JDK 下载正文的分层退让宿主。
 * 两个辅助插槽按完整自然高度平移，下面的 List 始终保持同一视口和内容首占位；
 * 组件只拥有展示状态，不拥有目录、网络任务、安装动作或用户筛选偏好。
 */
import { ThemeColors } from 'commons';
import { UiMotion } from './UiMotion';
import { LayerRetreatPolicy, RetreatFrame, retreatLayerHeight, retreatLayerOffset,
  retreatStableInset, retreatLeadItemHeight, retreatNeedsTopRestore } from './LayerRetreatPolicy';

@Component
export struct DownloadAuxiliaryList {
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 一个实例只绑定一个 List；外层 Tab 隐藏后也必须拒绝迟到的滚动和动画续体。 */
  @Prop @Watch('resetInteraction_') active: boolean = true;
  /** 查询、筛选、目录身份或辅助层集合变化时，由父页面发布新的展示身份。 */
  @Prop @Watch('reset_') resetKey: string = '';
  @Prop @Watch('resetInteraction_') blocked: boolean = false;
  @Prop firstEnabled: boolean = false;
  @Prop secondEnabled: boolean = false;
  @Prop itemCount: number = 0;
  @Prop hasResults: boolean = false;
  @Prop rowSpacing: number = 8;
  @Prop bottomInset: number = 0;
  /** 插槽不传按值状态参数，父页面保有原 Builder 的状态依赖与业务回调。 */
  @BuilderParam firstLayer: () => void;
  @BuilderParam secondLayer: () => void;
  @BuilderParam items: () => void;
  @BuilderParam empty: () => void;

  @State private hidden_: number = 0;
  @State private anchor_: number = -1;
  @State private firstHeight_: number = 0;
  @State private secondHeight_: number = 0;
  @State private animating_: boolean = false;
  @State private hitHeight_: number = 0;
  private epoch_: number = 0;
  private alive_: boolean = false;
  private dragging_: boolean = false;
  private returning_: boolean = false;
  private scrollable_: boolean = false;
  /** 原生只在索引变化时发通知；保留最近事实，供同索引的数据/视口复位后重新核实。 */
  private firstVisible_: number = -1;
  private lastVisible_: number = -1;
  private viewportWidth_: number = 0;
  private viewportHeight_: number = 0;
  private policy_: LayerRetreatPolicy = new LayerRetreatPolicy();
  private scroller_: Scroller = new Scroller();

  aboutToAppear(): void { this.alive_ = true; this.reset_(); }
  aboutToDisappear(): void {
    this.alive_ = false;
    this.epoch_++;
    this.dragging_ = false;
    this.policy_.reset();
  }

  /** 身份/几何变化重新核实内容资格；保留自然高度等待真实测量，不调用滚动补偿。 */
  private reset_(): void {
    this.resetInteraction_();
    this.anchor_ = -1;
    this.scrollable_ = false;
  }

  /**
   * 可见性或编辑阻塞切换只复位交互。List可能仍保留完全相同的可见索引，
   * 不会再触发onScrollIndex，因此保留该几何下已确认的滚动资格与内容锚点。
   */
  private resetInteraction_(): void {
    this.epoch_++;
    this.hidden_ = 0;
    this.animating_ = false;
    this.hitHeight_ = 0;
    this.dragging_ = false;
    this.returning_ = false;
    this.policy_.reset();
  }

  /** 视觉顺序为上层、下层；退让优先级从靠近结果的下层开始。 */
  private layers_(): number[] {
    return [this.secondEnabled ? this.secondHeight_ : 0, this.firstEnabled ? this.firstHeight_ : 0];
  }
  private total_(): number {
    return (this.firstEnabled ? this.firstHeight_ : 0) + (this.secondEnabled ? this.secondHeight_ : 0);
  }
  private inset_(): number { return retreatStableInset(this.anchor_, this.total_()); }
  private preceding_(): number { return this.secondEnabled ? this.secondHeight_ : 0; }
  private overlayHeight_(hidden: number = this.hidden_): number {
    return (this.firstEnabled ? retreatLayerHeight(this.firstHeight_, hidden, this.preceding_()) : 0)
      + (this.secondEnabled ? retreatLayerHeight(this.secondHeight_, hidden, 0) : 0);
  }

  /** 只有全部实际辅助层已测得自然高度才冻结；短内容没有收起资格。 */
  private freeze_(): void {
    if (this.anchor_ >= 0 || (this.firstEnabled && this.firstHeight_ <= 0)
      || (this.secondEnabled && this.secondHeight_ <= 0)) return;
    this.anchor_ = this.inset_();
  }
  private enabled_(): boolean {
    return this.alive_ && this.active && !this.blocked && this.hasResults && this.itemCount > 0
      && this.anchor_ >= 0 && (this.scrollable_ || this.hidden_ > 0 || this.indexOverflow_());
  }

  /** 缓存范围必须属于当前目录；旧长目录已越界的索引不能给新短目录授予资格。 */
  private indexOverflow_(): boolean {
    return this.itemCount > 0 && this.firstVisible_ >= 0 && this.lastVisible_ >= this.firstVisible_
      && this.lastVisible_ <= this.itemCount
      && (this.firstVisible_ > 1 || this.lastVisible_ < this.itemCount);
  }

  /** 第0项是固定占位；只记真实原生范围，不用隐藏量推算可见行。 */
  private index_(first: number, last: number): void {
    this.firstVisible_ = first;
    this.lastVisible_ = last;
    if (this.hidden_ === 0) this.scrollable_ = this.indexOverflow_();
  }

  /** 收展中的子层受裁剪壳约束，不能把该测量回流成自然高度。 */
  private measure_(first: boolean, area: Area): void {
    const height: number = Number(area.height);
    if (this.hidden_ > 0 || this.animating_ || !Number.isFinite(height) || height <= 0) return;
    if (first && Math.abs(this.firstHeight_ - height) > 0.5) this.firstHeight_ = height;
    if (!first && Math.abs(this.secondHeight_ - height) > 0.5) this.secondHeight_ = height;
  }

  /** 真正到顶时恢复全部自动层；从起点开始的正向帧不能误触发恢复。 */
  private restoreAtStart_(settled: boolean = false): boolean {
    if (!this.alive_ || !this.active || !this.hasResults || this.hidden_ <= 0) return false;
    try {
      const position: OffsetResult = this.scroller_.currentOffset();
      if (!position || !retreatNeedsTopRestore(this.hidden_, position.yOffset,
        this.returning_, settled && !this.dragging_)) return false;
    } catch (_) { return false; }
    this.policy_.reset();
    this.animate_(0);
    return true;
  }

  /** 真实用户帧只改变层端点，原始位移完整放行给正文；惯性不积累新收展预算。 */
  private frame_(offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult {
    if (!this.alive_ || !this.active) return { offsetRemain: offset };
    if (state === ScrollState.Scroll) {
      if (offset < -0.01) this.returning_ = true;
      else if (offset > 0.01) this.returning_ = false;
      if (offset < -0.01 && this.restoreAtStart_()) return { offsetRemain: offset };
      this.freeze_();
    }
    const frame: RetreatFrame = this.policy_.step(offset, this.hidden_, this.layers_(),
      this.enabled_(), state === ScrollState.Scroll);
    this.animate_(frame.hidden);
    return { offsetRemain: frame.offsetRemain };
  }

  /** 世代屏障拒绝旧动画完成回调；当前触点仍有效时才使用本手势的真实位移续播下一层。 */
  private animate_(next: number): void {
    if (next === this.hidden_) return;
    const epoch: number = ++this.epoch_;
    this.hitHeight_ = Math.max(this.hitHeight_, this.overlayHeight_(), this.overlayHeight_(next));
    this.animating_ = true;
    this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut,
      onFinish: (): void => {
        if (epoch !== this.epoch_ || !this.alive_ || !this.active) return;
        this.animating_ = false;
        this.hitHeight_ = 0;
        if (this.restoreAtStart_()) return;
        const nextFrame: RetreatFrame = this.policy_.finishTransition(this.hidden_, this.layers_(),
          this.enabled_(), this.dragging_);
        this.animate_(nextFrame.hidden);
      } }, (): void => { this.hidden_ = next; });
  }

  /** 只观察原生触点，不增加竞争手势；松手或取消废弃尚未播放的预算。 */
  private touch_(event: TouchEvent): void {
    if (!this.alive_ || !this.active) return;
    if (event.type === TouchType.Down) { this.policy_.cancelQueuedContinuation(); this.dragging_ = true; }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.dragging_ = false;
      this.policy_.cancelQueuedContinuation();
    }
  }
  private didScroll_(offset: number, state: ScrollState): void {
    if (!this.alive_ || !this.active) return;
    if (offset < -0.01) this.returning_ = true;
    else if (state === ScrollState.Scroll && offset > 0.01) this.returning_ = false;
    this.restoreAtStart_();
  }
  private stop_(): void {
    if (!this.dragging_) this.policy_.cancelQueuedContinuation();
    this.restoreAtStart_(!this.dragging_);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.hasResults) {
        List({ space: this.rowSpacing, scroller: this.scroller_ }) {
          // 真正参与内容滚动的首项，只在身份/几何复位前跟随自然测量。
          ListItem() { Column().width('100%').height('100%') }
            .height(retreatLeadItemHeight(this.inset_(), this.rowSpacing))
            .id('download-auxiliary-inset').focusable(false)
            .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          this.items()
        }
        .id('download-auxiliary-results').width('100%').height('100%').padding({ left: 16, right: 16 })
        .contentEndOffset(this.bottomInset).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onScrollStart(() => { if (!this.animating_) this.policy_.reset(); })
        .onScrollFrameBegin((offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult => this.frame_(offset, state))
        .onTouch((event: TouchEvent) => { this.touch_(event); })
        .onReachStart(() => { this.restoreAtStart_(); })
        .onDidScroll((offset: number, state: ScrollState) => { this.didScroll_(offset, state); })
        .onScrollStop(() => { this.stop_(); })
        .onScrollIndex((first: number, last: number) => {
          this.index_(first, last);
        })
      } else {
        Column() { this.empty() }
          .width('100%').height('100%').padding({ top: this.inset_() })
      }
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          if (this.firstEnabled) {
            Column() {
              Column() { this.firstLayer() }
                .width('100%').flexShrink(0)
                .height((this.animating_ || this.hidden_ > 0) && this.firstHeight_ > 0 ? this.firstHeight_ : LayoutPolicy.fixAtIdealSize)
                .constraintSize({ minHeight: this.animating_ || this.hidden_ > 0 ? this.firstHeight_ : 0 })
                .translate({ y: retreatLayerOffset(this.firstHeight_, this.hidden_, this.preceding_()) })
                .renderFit(RenderFit.TOP_LEFT).onAreaChange((_, area) => { this.measure_(true, area); })
            }.width('100%').justifyContent(FlexAlign.Start)
            .height(this.firstHeight_ > 0 ? retreatLayerHeight(this.firstHeight_, this.hidden_, this.preceding_()) : LayoutPolicy.fixAtIdealSize)
            .clip(true).enabled(!this.animating_ && this.hidden_ <= this.preceding_())
            .accessibilityLevel(this.animating_ || retreatLayerHeight(this.firstHeight_, this.hidden_, this.preceding_()) <= 0 ? 'no-hide-descendants' : 'auto')
          }
          if (this.secondEnabled) {
            Column() {
              Column() { this.secondLayer() }
                .width('100%').flexShrink(0)
                .height((this.animating_ || this.hidden_ > 0) && this.secondHeight_ > 0 ? this.secondHeight_ : LayoutPolicy.fixAtIdealSize)
                .constraintSize({ minHeight: this.animating_ || this.hidden_ > 0 ? this.secondHeight_ : 0 })
                .translate({ y: retreatLayerOffset(this.secondHeight_, this.hidden_, 0) })
                .renderFit(RenderFit.TOP_LEFT).onAreaChange((_, area) => { this.measure_(false, area); })
            }.width('100%').justifyContent(FlexAlign.Start)
            .height(this.secondHeight_ > 0 ? retreatLayerHeight(this.secondHeight_, this.hidden_, 0) : LayoutPolicy.fixAtIdealSize)
            .clip(true).enabled(!this.animating_ && this.hidden_ <= 0)
            .accessibilityLevel(this.animating_ || retreatLayerHeight(this.secondHeight_, this.hidden_, 0) <= 0 ? 'no-hide-descendants' : 'auto')
          }
        }.width('100%').backgroundColor(this.theme.bgPrimary).clip(true)
        if (this.animating_ && this.hitHeight_ > 0) {
          Column().width('100%').height(this.hitHeight_).hitTestBehavior(HitTestMode.Block)
        }
      }.id('download-auxiliary-overlay').width('100%').height(this.animating_ ? this.hitHeight_
        : (this.total_() > 0 ? this.overlayHeight_() : LayoutPolicy.fixAtIdealSize))
      .clip(true).hitTestBehavior(this.animating_ || this.overlayHeight_() > 0 ? HitTestMode.Default : HitTestMode.None)
    }.id('download-auxiliary-viewport').width('100%').height('100%').clip(true)
    .onAreaChange((_, area) => {
      const width: number = Number(area.width);
      const height: number = Number(area.height);
      if (Math.abs(width - this.viewportWidth_) > 0.5 || Math.abs(height - this.viewportHeight_) > 0.5) {
        this.viewportWidth_ = width;
        this.viewportHeight_ = height;
        this.reset_();
      }
    })
  }
}

/**
 * MarqueeText.ets — 单向无限循环跑马灯 + 用户接管即变有界
 *
 * 设计目标（HomeTab Hero 大版本号场景）：
 *   - 内容能塞下视口 → 退化为普通 Text，零滚动
 *   - 内容溢出（默认行为）→ 自动**单向**循环：滚到第一份末尾后留一段 gap 留白，
 *     无缝接上第二份副本，整体看像新闻条无限往左走，不来回 bounce
 *   - 用户开始横拖 → 停止渲染侧动画，进入"用户模式"
 *     · 若按下时 offsetX 在自然窗口 [0, contentW - viewportW] 内 → 直接 anchored
 *       （左右两端都 clamp）
 *     · 若按下时在过渡区（offsetX 已过 naturalMax，正在跨 gap 准备绕回头）
 *       → 先 free 自由拖；一旦 offsetX 落进自然窗口任一端 → 切 anchored，从此 clamp
 *   - 用户松手 N 秒（默认 2s）后 → 归一化 offsetX 到 [0, cycleWidth) 恢复 auto
 *
 * 历史踩坑（v1 → v2）：
 *   v1 用 onAreaChange 测 Text 宽度 → 始终拿到视口宽，shouldScroll 永远 false。
 *   原因：Text 嵌在 Row 嵌在 Stack(100%) 里，被父级宽度卡住，maxLines(1) 也救不了
 *        —— ArkUI 的 measure 阶段父约束优先。
 *   v2 改用 MeasureText.measureTextSize 静态 API 直接算"无约束"文本宽，
 *        + Text.width(contentW) 显式给宽避免被父级再次 clamp。这条链路稳定。
 *
 * 实现要点：
 *   1. content / fontSize / fontWeight 任一变 → 重测 contentW
 *   2. Stack 视口裁剪；副本只在固定位置布局，共同用 translate 做渲染侧位移。
 *   3. 自动滚动使用原生 Animator 的实际 onFrame 偏移，不再使用 16ms JS interval；
 *      translate 不触发布局，手动接管以最后一帧实际值为准，不根据墙钟猜动画位置。
 *      从任意归一化偏移续播需要第三份副本接力，循环首尾画面保持一致。
 *   4. 用户拖动使用 PanGesture 累计位移：手指左移 → offsetX 增大（与 auto 同向）
 *   5. mode 状态机：auto / free / anchored —— 详见 docstring 顶部
 *
 * 不接管的属性（外层容器自行 padding / margin / alignItems 控制视觉位置）：
 *   - 字体族（默认随 ArkUI 主题）
 *   - 行高（单行场景默认即可）
 *   - 文本对齐（始终左起 — 与原版 Text 一致）
 */

import { systemDateTime } from '@kit.BasicServicesKit';
import { AnimatorResult } from '@kit.ArkUI';
import { UiMotion } from './UiMotion';

@Component
export struct MarqueeText {
  /** 文本内容；变化时重测宽 + 重置滚动位置 */
  @Prop @Watch('onMeasureDepsChange') content: string = '';
  /** 字号（vp） */
  @Prop @Watch('onMeasureDepsChange') fontSize: number = 16;
  /** 字重；接受 number(100-900) / FontWeight 枚举 / string */
  @Prop @Watch('onMeasureDepsChange') fontWeight: number = 400;
  /** 字色 */
  @Prop fontColor: ResourceColor = '#FFFFFF';
  /** 历史属性名保持兼容；实际偏移以 vp/秒推进，默认 60 沿用原滚动速率。 */
  @Prop @Watch('onMotionDepsChange') pixelsPerSec: number = 60;
  /** 用户松手后多久恢复自动滚（ms）。默认 2000 */
  @Prop resumeDelayMs: number = 2000;
  /** 两份副本之间的留白（vp）。值越大"换行感"越明显，太小看起来像粘连 */
  @Prop @Watch('onMotionDepsChange') gapVp: number = 60;

  /** 视口宽（vp） —— 由外层 Stack onAreaChange 测出 */
  @State private viewportW: number = 0;
  /** 单份文本"无约束"实际宽（vp） —— MeasureText 算出，不受父布局影响 */
  @State private contentW: number = 0;
  /** 当前滚动偏移：0 = 第一份副本左对齐视口；增大 = 内容向左滑 */
  @State private offsetX: number = 0;
  /**
   * 'auto'     = 自动单向无限滚（offset 增、到 cycleWidth 折回）
   * 'free'     = 用户在过渡区按下，自由拖直到第一次碰自然边界
   * 'anchored' = 用户已经摸到 [0, naturalMax] 任一端 → 此后 clamp
   */
  @State private mode: string = 'auto';

  /**
   * 宿主页面（Index）是否可见。router.pushUrl 进游戏时 Index 只是被覆盖、并不销毁，
   * 所以 aboutToDisappear 不一定触发。Index 发布宿主和首页页签可见事实，Ability
   * 发布应用前台事实；三者同时成立且组件存活才允许运行动画或用户恢复计时。
   */
  @StorageProp('amclHostPageVisible') @Watch('onVisibilityChange')
  private hostPageVisible: boolean = false;
  @StorageProp('appInForeground') @Watch('onVisibilityChange')
  private appInForeground: boolean = false;
  @StorageProp('amclHomeTabVisible') @Watch('onVisibilityChange')
  private homeTabVisible: boolean = false;

  /** 原生动画资格；仅实际帧值可更新偏移，取消后的在途帧通过世代拒绝。 */
  private alive_: boolean = false;
  private animationRunning_: boolean = false;
  private animationGeneration_: number = 0;
  private animation_: AnimatorResult | undefined = undefined;
  private dragging_: boolean = false;
  /** 隐藏时暂停用户恢复倒计时；回到真正首页继续剩余等待，不能永久停在用户模式。 */
  private resumeRemaining_: number = 0;
  private resumeDeadline_: number = 0;
  private resumeGeneration_: number = 0;
  /** 用户松手后的恢复定时器 id；0 = 未跑 */
  private resumeTimer_: number = 0;

  aboutToAppear() {
    this.alive_ = true;
    this.measureContent();
    this.startTick();
  }

  aboutToDisappear() {
    this.stopAll();
    this.alive_ = false;
    this.dragging_ = false;
    this.resumeRemaining_ = 0;
  }

  /** 任一可见条件消失立即停止；重新满足时延续自动模式或用户松手后的剩余等待。 */
  private onVisibilityChange(): void {
    if (!this.canRun_()) {
      this.stopAll();
      if (this.dragging_) {
        this.dragging_ = false;
        this.resumeRemaining_ = Math.max(0, this.resumeDelayMs);
      }
    } else if (this.mode === 'auto') {
      this.startTick();
    } else if (!this.dragging_) {
      this.scheduleResume_();
    }
  }

  /** 存活、前台和真实首页共同授权动效，未知事实按不可见处理。 */
  private canRun_(): boolean {
    return this.alive_ && this.hostPageVisible && this.appInForeground && this.homeTabVisible;
  }

  /** 用户恢复等待使用 ACTIVE 单调毫秒，避免修改日期影响剩余延时；不用于推算动画帧。 */
  private activeTime_(): number {
    try { return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false); }
    catch (_) { return 0; }
  }

  // ============================================================
  //  measure（内容 / 字号 / 字重 任一变都重算）
  // ============================================================

  private measureContent(): void {
    if (this.content.length === 0) {
      this.contentW = 0;
      return;
    }
    try {
      // 2026-05-23 API NEXT 迁移：MeasureText.measureTextSize / px2vp 全局函数
      // 均弃用，改走 this.getUIContext().getMeasureUtils() / .px2vp。
      // 详见 docs/guides/api-migration-2026-05.md。
      let uiCtx = this.getUIContext()
      // measureTextSize 输入 fontSize 单位是 vp，返回 size 单位是 px
      let size = uiCtx.getMeasureUtils().measureTextSize({
        textContent: this.content,
        fontSize: this.fontSize,
        fontWeight: this.fontWeight,
        maxLines: 1,
        // overflow 给 None，否则 measureTextSize 内部按 Ellipsis 算会得到不准的宽
        overflow: TextOverflow.None,
      });
      let widthPx = size.width as number;
      if (typeof widthPx === 'number' && widthPx > 0) {
        this.contentW = uiCtx.px2vp(widthPx);
      }
    } catch (e) {
      // measure 失败时不滚（contentW=0 → shouldScroll 假），降级到普通 Text
      this.contentW = 0;
    }
  }

  private onMeasureDepsChange(): void {
    this.stopAll();
    this.measureContent();
    this.offsetX = 0;
    this.mode = 'auto';
    this.dragging_ = false;
    this.resumeRemaining_ = 0;
    this.startTick();
  }

  /** 速度/留白变化先冻结旧动画快照，再按新周期续播；用户拖动模式不会被设置变化夺回。 */
  private onMotionDepsChange(): void {
    this.stopTick();
    this.normalizeOffsetX();
    this.startTick();
  }

  // ============================================================
  //  tick
  // ============================================================

  private startTick(): void {
    if (this.animationRunning_ || !this.canRun_() || this.mode !== 'auto' || UiMotion.reduced()
      || !this.shouldScroll() || this.viewportW <= 0 || !Number.isFinite(this.pixelsPerSec)
      || this.pixelsPerSec <= 0) return;
    this.normalizeOffsetX();
    const cycle: number = this.contentW + Math.max(0, this.gapVp);
    if (!Number.isFinite(cycle) || cycle <= 0) return;
    const generation: number = ++this.animationGeneration_;
    const animator: AnimatorResult = this.getUIContext().createAnimator({
      duration: Math.max(1, Math.ceil(cycle / this.pixelsPerSec * 1000)), easing: 'linear', delay: 0,
      iterations: -1, fill: 'forwards', direction: 'normal', begin: this.offsetX, end: this.offsetX + cycle,
    });
    this.animation_ = animator;
    this.animationRunning_ = true;
    // 原生 Animator 的实际帧进度是唯一位置权威，系统动画倍率不需要人工推算。
    // 每帧只更新合成位移；隐藏/用户接管前撤销世代，迟到帧不会覆盖手动位置。
    animator.onFrame = (offset: number): void => {
      if (generation !== this.animationGeneration_ || !this.canRun_() || this.mode !== 'auto') return;
      this.offsetX = offset;
    };
    animator.play();
  }

  /** 取消原生动画后保留最后实际帧；不会使用最终目标或单调时钟估计用户接管位置。 */
  private stopTick(): void {
    if (!this.animationRunning_) return;
    this.animationRunning_ = false;
    this.animationGeneration_++;
    const animator: AnimatorResult | undefined = this.animation_;
    this.animation_ = undefined;
    animator?.cancel();
    this.normalizeOffsetX();
  }

  private stopAll(): void {
    this.stopTick();
    if (this.resumeTimer_ !== 0) {
      this.resumeRemaining_ = Math.max(0, this.resumeDeadline_ - this.activeTime_());
      clearTimeout(this.resumeTimer_);
      this.resumeTimer_ = 0;
    }
    this.resumeGeneration_++;
  }

  // ============================================================
  //  user pan
  //
  //  PanGesture 给的是"累计 offsetX"（相对 down 那一刻的累计位移），不像 Touch
  //  给的是绝对屏幕坐标。所以记下 down 时的 offsetX 作 base，每次 update 用
  //  (base - panOffsetX) 直接算目标 offsetX，比 dx 累加更稳，浮点不会漂。
  //
  //  方向约定：finger 向左 → panOffsetX < 0 → target = base - panOffsetX 增大
  //           （offsetX 增大 = 内容继续往左滑，与 auto 同向，符合手感）
  // ============================================================

  /** pan 开始时的 offsetX，作 base；每次 update 算 target = base - panOffsetX */
  private panBaseOffset_: number = 0;

  private handlePanStart(): void {
    if (!this.canRun_() || !this.shouldScroll()) return;
    this.stopTick();
    this.dragging_ = true;
    this.resumeGeneration_++;
    this.resumeRemaining_ = 0;
    if (this.resumeTimer_ !== 0) {
      clearTimeout(this.resumeTimer_);
      this.resumeTimer_ = 0;
    }
    this.panBaseOffset_ = this.offsetX;
    let nm = this.naturalMax();
    // 按下时已在自然窗口 → 直接 anchored；否则在过渡区 → free 等用户撞边界
    if (this.offsetX >= 0 && this.offsetX <= nm) {
      this.mode = 'anchored';
    } else {
      this.mode = 'free';
    }
  }

  private handlePanUpdate(panOffsetX: number): void {
    if (!this.dragging_ || !this.canRun_()) return;
    let target = this.panBaseOffset_ - panOffsetX;
    let nm = this.naturalMax();
    if (this.mode === 'anchored') {
      target = this.clampToNatural(target, nm);
    } else {
      // free：先用 safetyMax 兜住别让用户把第二份副本也拖出视野
      let safetyMax = this.contentW + this.gapVp + nm;
      if (target < 0) target = 0;
      if (target > safetyMax) target = safetyMax;
      // 第一次落进 [0, nm] → 自动切 anchored，从此 clamp
      if (target <= 0) {
        target = 0;
        this.mode = 'anchored';
      } else if (target <= nm) {
        this.mode = 'anchored';
      }
    }
    this.offsetX = target;
  }

  private handlePanEnd(): void {
    if (!this.dragging_) return;
    this.dragging_ = false;
    this.resumeRemaining_ = Math.max(0, this.resumeDelayMs);
    this.scheduleResume_();
  }

  /** 恢复等待只有一个在途定时器；隐藏/销毁/新手势使旧回调丧失发布资格。 */
  private scheduleResume_(): void {
    if (!this.canRun_() || this.dragging_ || this.mode === 'auto' || this.resumeTimer_ !== 0) return;
    const generation: number = ++this.resumeGeneration_;
    this.resumeDeadline_ = this.activeTime_() + this.resumeRemaining_;
    this.resumeTimer_ = setTimeout(() => {
      if (generation !== this.resumeGeneration_ || !this.canRun_() || this.dragging_) return;
      this.normalizeOffsetX();
      this.mode = 'auto';
      this.resumeTimer_ = 0;
      this.resumeRemaining_ = 0;
      this.startTick();
    }, this.resumeRemaining_);
  }

  // ============================================================
  //  helpers
  // ============================================================

  private clampToNatural(v: number, nm: number): number {
    if (v < 0) return 0;
    if (v > nm) return nm;
    return v;
  }

  /**
   * 把 offsetX 归一化到 [0, cycleWidth)，避免恢复 auto 时一帧 jump。
   * 用 while 而不是 % 是因为 ArkTS 严格模式下浮点取模偶有精度问题；
   * 实际单次最多减 / 加一次，循环成本可忽略。
   */
  private normalizeOffsetX(): void {
    if (this.contentW <= 0) return;
    let cycleWidth = this.contentW + Math.max(0, this.gapVp);
    if (cycleWidth <= 0) return;
    while (this.offsetX >= cycleWidth) this.offsetX -= cycleWidth;
    while (this.offsetX < 0) this.offsetX += cycleWidth;
  }

  private naturalMax(): number {
    let v = this.contentW - this.viewportW;
    return v > 0 ? v : 0;
  }

  private shouldScroll(): boolean {
    return this.contentW > this.viewportW + 0.5;
  }

  // ============================================================
  //  build
  // ============================================================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 副本固定布局，自动/手动偏移仅作用于可动画的 translate，不逐帧触发 position 布局。
      // 内容塞得下时 contentW <= viewportW，offsetX 永远 0，等价普通 Text
      Text(this.content)
        .fontSize(this.fontSize)
        .fontWeight(this.fontWeight)
        .fontColor(this.fontColor)
        .maxLines(1)
        .width(this.contentW > 0 ? this.contentW : undefined)
        .position({ x: 0, y: 0 })
        .translate({ x: -this.offsetX, y: 0 })

      // 第二份副本：仅溢出时画，作"接力位置"用
      // 摆在 (contentW + gap) - offsetX 处；当 offsetX 接近 cycleWidth 时它会
      // 慢慢推到视口左侧，给第一份副本"无缝拼接"的视觉
      if (this.shouldScroll()) {
        Text(this.content)
          .fontSize(this.fontSize)
          .fontWeight(this.fontWeight)
          .fontColor(this.fontColor)
          .maxLines(1)
          .width(this.contentW)
          .position({ x: this.contentW + Math.max(0, this.gapVp), y: 0 })
          .translate({ x: -this.offsetX, y: 0 })
        // 从周期中间续播会越过第二份末尾，第三份补齐该区间；首尾复制画面完全一致。
        Text(this.content)
          .fontSize(this.fontSize)
          .fontWeight(this.fontWeight)
          .fontColor(this.fontColor)
          .maxLines(1)
          .width(this.contentW)
          .position({ x: 2 * (this.contentW + Math.max(0, this.gapVp)), y: 0 })
          .translate({ x: -this.offsetX, y: 0 })
      }
    }
    .width('100%')
    // height 由内层 Text 撑起（Stack 默认 fit content），保持原 56sp 单行高度不变
    .clip(true)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      let w = newArea.width as number;
      if (w > 0 && Math.abs(w - this.viewportW) > 0.5) {
        this.stopTick();
        this.viewportW = w;
        if (!this.shouldScroll()) this.offsetX = 0;
        this.startTick();
      }
    })
    // ⚠️ 用 PanGesture 而不是 onTouch 处理拖动 ——
    //   onTouch 只是 listener，不消费事件，父级 Scroll 仍会同时收到 down/move
    //   导致用户在 MarqueeText 上横滑时整个 HomeTab 跟着上下窜（Scroll 用 y 增量
    //   解读为页面滚动）。
    //   PanGesture 是 gesture 模块成员，被识别后会**独占该次手势**，父级 Scroll
    //   的 PanRecognizer 只能拿 vertical direction，HomeTab 不会再被影响。
    //   distance:1 让识别尽量灵敏，避免用户开始拖时父级先抢到事件。
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
        .onActionStart((_e: GestureEvent) => {
          this.handlePanStart()
        })
        .onActionUpdate((e: GestureEvent) => {
          // PanGesture 给的是累计 offsetX；自己换算每帧增量更稳
          let absX = e.offsetX as number
          this.handlePanUpdate(absX)
        })
        .onActionEnd((_e: GestureEvent) => {
          this.handlePanEnd()
        })
        .onActionCancel(() => {
          this.handlePanEnd()
        })
    )
  }
}

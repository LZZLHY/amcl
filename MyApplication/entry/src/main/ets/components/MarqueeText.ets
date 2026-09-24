/**
 * MarqueeText.ets — 单向无限循环跑马灯 + 用户接管即变有界
 *
 * 设计目标（HomeTab Hero 大版本号场景）：
 *   - 内容能塞下视口 → 退化为普通 Text，零滚动
 *   - 内容溢出（默认行为）→ 自动**单向**循环：滚到第一份末尾后留一段 gap 留白，
 *     无缝接上第二份副本，整体看像新闻条无限往左走，不来回 bounce
 *   - 用户摸屏 → 立刻停 tick，进入"用户模式"
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
 *   2. Stack 视口裁剪；两份 Text 各自显式宽 = contentW，用 .position 摆位置
 *      第一份在 -offsetX；第二份在 contentW + gap - offsetX
 *   3. tick 16ms 推 offsetX += step；到 cycleWidth = contentW + gap 时减一个 cycle
 *      因为第二份副本左缘正好在 cycleWidth 处，减完后视觉位置等于第一份 → 无缝
 *   4. 用户拖动用 onTouch 增量 dx：finger 左移（dx<0）→ offsetX 增大（与 auto 同向）
 *   5. mode 状态机：auto / free / anchored —— 详见 docstring 顶部
 *
 * 不接管的属性（外层容器自行 padding / margin / alignItems 控制视觉位置）：
 *   - 字体族（默认随 ArkUI 主题）
 *   - 行高（单行场景默认即可）
 *   - 文本对齐（始终左起 — 与原版 Text 一致）
 */

import { MeasureText } from '@kit.ArkUI';

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
  /** 自动滚速度（px/秒）。默认 60 ≈ 视觉舒适，不晃眼 */
  @Prop pixelsPerSec: number = 60;
  /** 用户松手后多久恢复自动滚（ms）。默认 2000 */
  @Prop resumeDelayMs: number = 2000;
  /** 两份副本之间的留白（vp）。值越大"换行感"越明显，太小看起来像粘连 */
  @Prop gapVp: number = 60;

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
   * 所以 aboutToDisappear 不会触发，本组件的 16ms 定时器会**在整局游戏期间**继续
   * 每帧写 @State → 每帧让 ArkUI 主线程做一次布局/重绘，而屏幕上根本看不到它。
   * 那条主线程正是物理鼠标 onMouse / onAxisEvent 的派发线程，所以这不只是耗电，
   * 而是直接给键鼠输入加延迟。Index 的 onPageShow/onPageHide 负责发布该标志。
   */
  @StorageProp('amclHostPageVisible') @Watch('onHostPageVisibilityChange')
  private hostPageVisible: boolean = true;

  /** tick 定时器 id；0 = 未跑 */
  private tickTimer_: number = 0;
  /** 用户松手后的恢复定时器 id；0 = 未跑 */
  private resumeTimer_: number = 0;

  aboutToAppear() {
    this.measureContent();
    this.startTick();
  }

  aboutToDisappear() {
    this.stopAll();
  }

  private onHostPageVisibilityChange(): void {
    if (this.hostPageVisible) {
      // 回到前台再重新起；offsetX 保留，视觉上从原位置继续滚。
      this.startTick();
    } else {
      this.stopAll();
    }
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
    this.measureContent();
    this.offsetX = 0;
    this.mode = 'auto';
    // tick 已经在跑（aboutToAppear 起的）—— 无需重启
  }

  // ============================================================
  //  tick
  // ============================================================

  private startTick(): void {
    if (this.tickTimer_ !== 0) return;
    // 宿主页面被游戏页覆盖时不起定时器：看不见的滚动不值得每帧占用 UI 线程。
    if (!this.hostPageVisible) return;
    // 16ms ≈ 60 fps，每帧推进 pixelsPerSec * 16/1000 px
    this.tickTimer_ = setInterval(() => this.tick(), 16);
  }

  private stopTick(): void {
    if (this.tickTimer_ !== 0) {
      clearInterval(this.tickTimer_);
      this.tickTimer_ = 0;
    }
  }

  private stopAll(): void {
    this.stopTick();
    if (this.resumeTimer_ !== 0) {
      clearTimeout(this.resumeTimer_);
      this.resumeTimer_ = 0;
    }
  }

  private tick(): void {
    if (this.mode !== 'auto') return;
    if (this.contentW <= 0 || this.viewportW <= 0) return;
    if (this.contentW <= this.viewportW) return; // 不溢出 → 不滚

    let cycleWidth = this.contentW + this.gapVp;
    let step = this.pixelsPerSec * 16 / 1000;
    let next = this.offsetX + step;
    // 单向无限：到一个 cycle 末尾立刻减一个 cycle，第二份副本接力顶上去，无缝
    if (next >= cycleWidth) {
      next -= cycleWidth;
    }
    this.offsetX = next;
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
    this.stopTick();
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
    if (this.resumeTimer_ !== 0) clearTimeout(this.resumeTimer_);
    this.resumeTimer_ = setTimeout(() => {
      this.normalizeOffsetX();
      this.mode = 'auto';
      this.resumeTimer_ = 0;
      this.startTick();
    }, this.resumeDelayMs);
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
    let cycleWidth = this.contentW + this.gapVp;
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
      // 第一份副本：显式宽 contentW，绝对位置摆在 -offsetX
      // 内容塞得下时 contentW <= viewportW，offsetX 永远 0，等价普通 Text
      Text(this.content)
        .fontSize(this.fontSize)
        .fontWeight(this.fontWeight)
        .fontColor(this.fontColor)
        .maxLines(1)
        .width(this.contentW > 0 ? this.contentW : undefined)
        .position({ x: -this.offsetX, y: 0 })

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
          .position({ x: this.contentW + this.gapVp - this.offsetX, y: 0 })
      }
    }
    .width('100%')
    // height 由内层 Text 撑起（Stack 默认 fit content），保持原 56sp 单行高度不变
    .clip(true)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      let w = newArea.width as number;
      if (w > 0) this.viewportW = w;
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
        .onActionStart((e: GestureEvent) => {
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

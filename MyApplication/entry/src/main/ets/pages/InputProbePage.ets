/**
 * InputProbePage.ets — 键鼠原始输入诊断页（独立页，不需要启动 Minecraft）
 *
 * ============================ 为什么要这一页 ============================
 * 键鼠适配的每一个结论此前都要"进游戏 → 操作 → 拉 hilog → 逐秒对齐普查行"才能拿到，
 * 一轮十几分钟，而且游戏里同时跑着虚拟控件、光标锁、schema 解释器和三条视角通道，
 * 任何观测都要先排除它们的干扰。这一页把观测面缩到最小：**纯 ArkUI 事件回调，
 * 不碰 NAPI、不碰光标锁、不碰虚拟控件**，所见即平台原样投递给应用的东西。
 *
 * 它要回答的核心问题只有一个：
 *   **系统的"鼠标左键与轴事件转触摸事件"兜底转换，在这台设备上到底有没有生效？**
 * 判据不靠推断，靠两个计数器的对照（见下方 verdict()）：
 *   · 按住左键拖动时，onMouse 还在投递 Move（且 rawDelta 非零）→ 转换**已关闭**，
 *     拿到的是原始鼠标数据，可以照 Amethyst 那套 `mouseX += rawDelta` 做无界累加；
 *   · 按住左键拖动时 onMouse 静默、而 onTouch 在刷 → 转换**开启中**，左键已经不是
 *     鼠标事件了，位移只剩被夹取的触点坐标。
 *
 * 已知结论（写在这里避免重复取证）：
 *   · MatePad Pro / HarmonyOS 6.1.0.135 / API 24：转换**开启**，且 easyGo 的
 *     `mouse2TouchEventMode: disabled` 未被解析（module.json5 参考文档："easyGo
 *     当前仅支持平行视界分栏能力"）。按住左键期间 onMouse 连续 3.5 秒零条。
 *   · 待验证：HarmonyOS 7.0 / API 26 上 easyGo 是否生效。
 *
 * 用法：设置 → 连点「开发者工具」6 次 → 诊断·存储 → 键鼠原始输入诊断。
 * 接鼠标后：① 不按键移动；② 按住左键拖 2~3 秒；③ 滚滚轮；④ 读顶部裁决与事件流。
 */

import { deviceInfo } from '@kit.BasicServicesKit';

const MONO: string = 'monospace';
const BG: string = '#0E1117';
const PANEL: string = '#161B22';
const FG: string = '#C9D3DE';
const DIM: string = '#6E7B8A';
const GREEN: string = '#3FB950';
const RED: string = '#F85149';
const AMBER: string = '#D29922';
const MAX_LOG_LINES: number = 16;

/** 一个 1 秒窗口内的分桶计数。字段全部显式，避免 ArkTS 的隐式类型推断问题。 */
class Counters {
  mouseMoveHeld: number = 0;      // 有鼠标键按下时到达的 onMouse Move
  mouseMoveFree: number = 0;      // 无键按下时到达的 onMouse Move
  mouseRawNonZero: number = 0;    // 其中 rawDelta 非零的样本数
  mousePress: number = 0;
  mouseRelease: number = 0;
  touchDown: number = 0;
  touchMove: number = 0;
  touchUp: number = 0;
  axisCb: number = 0;
  axisNonZero: number = 0;

  reset(): void {
    this.mouseMoveHeld = 0;
    this.mouseMoveFree = 0;
    this.mouseRawNonZero = 0;
    this.mousePress = 0;
    this.mouseRelease = 0;
    this.touchDown = 0;
    this.touchMove = 0;
    this.touchUp = 0;
    this.axisCb = 0;
    this.axisNonZero = 0;
  }
}

@Entry
@Component
struct InputProbePage {
  @State deviceLine: string = '';
  @State verdictText: string = '接上鼠标，然后按住左键拖动 2~3 秒';
  @State verdictColor: string = AMBER;
  @State liveLine: string = '';
  @State logLines: string[] = [];
  @State frozen: boolean = false;

  /** 累计量（不清零），用于裁决；窗口量在 flush 时清零。 */
  private total: Counters = new Counters();
  private window: Counters = new Counters();
  private nextFlushMs: number = 0;
  /** 左键是否按住 —— 转换开启时左键不出现在 onMouse，所以两条来源都要看。 */
  private mouseButtonHeld: boolean = false;
  private lastRawDx: number = 0;
  private lastRawDy: number = 0;

  aboutToAppear(): void {
    this.deviceLine = `${deviceInfo.marketName} · ${deviceInfo.osFullName} · API ${deviceInfo.sdkApiVersion} · ${deviceInfo.deviceType}`;
  }

  // ==================== 事件采集 ====================

  private push(line: string): void {
    if (this.frozen) return;
    const next: string[] = this.logLines.slice(0, MAX_LOG_LINES - 1);
    next.unshift(line);
    this.logLines = next;
  }

  private handleMouse(e: MouseEvent): void {
    if (this.frozen) return;
    const action: number = e.action as number;
    const button: number = e.button as number;
    const pressed: MouseButton[] | undefined = e.pressedButtons;
    const heldCount: number = pressed !== undefined ? pressed.length : 0;
    const rawPresent: boolean = e.rawDeltaX !== undefined && e.rawDeltaY !== undefined;
    const dx: number = rawPresent ? (e.rawDeltaX as number) : 0;
    const dy: number = rawPresent ? (e.rawDeltaY as number) : 0;

    if (e.action === MouseAction.Press) {
      this.mouseButtonHeld = true;
      this.total.mousePress++;
      this.window.mousePress++;
      this.push(`M PRESS   button=${button} pressed=[${pressed !== undefined ? pressed.join(',') : ''}]`);
      return;
    }
    if (e.action === MouseAction.Release) {
      this.mouseButtonHeld = heldCount > 0;
      this.total.mouseRelease++;
      this.window.mouseRelease++;
      this.push(`M RELEASE button=${button} pressed=[${pressed !== undefined ? pressed.join(',') : ''}]`);
      return;
    }
    if (e.action !== MouseAction.Move) return;

    const held: boolean = heldCount > 0 || this.mouseButtonHeld;
    if (held) {
      this.total.mouseMoveHeld++;
      this.window.mouseMoveHeld++;
    } else {
      this.total.mouseMoveFree++;
      this.window.mouseMoveFree++;
    }
    if (rawPresent && (dx !== 0 || dy !== 0)) {
      this.total.mouseRawNonZero++;
      this.window.mouseRawNonZero++;
    }
    this.lastRawDx = dx;
    this.lastRawDy = dy;
    this.maybeFlush();
  }

  private handleTouch(e: TouchEvent): void {
    if (this.frozen) return;
    const t: TouchObject | undefined = e.changedTouches !== undefined && e.changedTouches.length > 0
      ? e.changedTouches[0] : undefined;
    const tool: number = e.sourceTool as number;
    const src: number = e.source as number;
    if (e.type === TouchType.Down) {
      this.total.touchDown++;
      this.window.touchDown++;
      // sourceTool / source 是官方给出的唯一"来源"判据。平板实测合成包会被伪装成
      // FINGER + TOUCHSCREEN；若某设备如实上报 MOUSE，这一行就能立刻看出来。
      this.push(
        `T DOWN  tool=${tool}(${this.sourceToolName(tool)}) ` +
        `source=${src}(${this.sourceTypeName(src)}) ` +
        `id=${t !== undefined ? t.id : -1} ` +
        `xy=(${t !== undefined ? t.x.toFixed(3) : '?'},${t !== undefined ? t.y.toFixed(3) : '?'})`);
    } else if (e.type === TouchType.Move) {
      this.total.touchMove++;
      this.window.touchMove++;
    } else {
      this.total.touchUp++;
      this.window.touchUp++;
      this.push(
        `T UP    tool=${tool}(${this.sourceToolName(tool)}) ` +
        `source=${src}(${this.sourceTypeName(src)}) ` +
        `id=${t !== undefined ? t.id : -1}`);
    }
    this.maybeFlush();
  }

  /**
   * 手势层来源判定。
   *
   * 官方 FAQ《PC设备上，页面滚动方向与预期不符》给出的矩阵是**手势层**的：
   *   手指按下滑动     → SourceTool.Finger(1)   + SourceType.TouchScreen(2) + axis 均为 0
   *   鼠标左键按下滑动 → SourceTool.Mouse       + SourceType.Mouse(1)       + axis 均为 0
   *   鼠标滚轮         → SourceTool.Mouse       + SourceType.Mouse(1)       + axis 非 0
   *   触摸板按下滑动   → SourceTool.TouchPad(9) + SourceType.Unknown(0)     + axis 为 0
   *   触摸板双指       → SourceTool.TouchPad(9) + SourceType.Unknown(0)     + axis 非 0
   *
   * 这与我们在 native 侧测到的"合成包全报 TOUCHSCREEN + FINGER"矛盾。两处不是同一层：
   * native 读的是 OH_NativeXComponent_TouchEvent，这里读的是 ArkUI 手势事件。
   * 若手势层如实上报 Mouse，那么"鼠标左键拖动 vs 真手指"就有了**文档支持的确定判据**，
   * 不必再依赖"整数坐标 + 指针位置重合"这类启发式。
   *
   * 刻意放在独立的小条带上，不与主采集区共用：手势识别会吞掉 MOVE，
   * 放在一起会污染 onTouch/onMouse 的观测。
   */
  private handlePan(phase: string, e: GestureEvent): void {
    if (this.frozen) return;
    let vy: number = 0;
    let vx: number = 0;
    // BaseGestureEvent 的轴值：滚轮驱动的 Pan 才非零，是区分"滚轮"与"左键拖动"的判据。
    try { vy = e.axisVertical !== undefined ? e.axisVertical as number : 0; } catch (err) { vy = 0; }
    try { vx = e.axisHorizontal !== undefined ? e.axisHorizontal as number : 0; } catch (err) { vx = 0; }
    const src: number = e.source as number;
    const tool: number = e.sourceTool as number;
    this.push(
      `P ${phase} source=${src}(${this.sourceTypeName(src)}) ` +
      `tool=${tool}(${this.sourceToolName(tool)}) ` +
      `axis=(${vx.toFixed(2)},${vy.toFixed(2)}) ` +
      `offset=(${(e.offsetX as number).toFixed(1)},${(e.offsetY as number).toFixed(1)})`);
  }

  /** SourceType（ts-gesture-settings）：Unknown=0 Mouse=1 TouchScreen=2 Key=3(22+) Joystick=4(22+) */
  private sourceTypeName(v: number): string {
    if (v === 0) return 'Unknown';
    if (v === 1) return 'Mouse';
    if (v === 2) return 'TouchScreen';
    return `?${v}`;
  }

  /** SourceTool：Unknown=0 Finger=1 Pen=2 MOUSE=3 TOUCHPAD=4 JOYSTICK=5（ArkUI 编号） */
  private sourceToolName(v: number): string {
    if (v === 0) return 'Unknown';
    if (v === 1) return 'Finger';
    if (v === 2) return 'Pen';
    if (v === 3) return 'MOUSE';
    if (v === 4) return 'TOUCHPAD';
    if (v === 5) return 'JOYSTICK';
    // 真机曾观测到 ArkUI 在 sourceTool 上填 native TouchPointToolType 的编号
    // （MOUSE=7 / LENS=8），两套编号都要能认出来。
    if (v === 7) return 'MOUSE(nativeEnum)';
    if (v === 8) return 'LENS(nativeEnum)';
    return `?${v}`;
  }

  private handleAxis(e: AxisEvent): void {
    if (this.frozen) return;
    let vy: number = 0;
    try { vy = e.getVerticalAxisValue(); } catch (err) { vy = 0; }
    let vx: number = 0;
    try { vx = e.getHorizontalAxisValue(); } catch (err) { vx = 0; }
    this.total.axisCb++;
    this.window.axisCb++;
    if (vy !== 0 || vx !== 0) {
      this.total.axisNonZero++;
      this.window.axisNonZero++;
    }
    this.push(`A action=${e.action as number} v=${vy.toFixed(3)} h=${vx.toFixed(3)}`);
    this.maybeFlush();
  }

  // ==================== 裁决 ====================

  private maybeFlush(): void {
    const now: number = Date.now();
    if (this.nextFlushMs === 0) {
      this.nextFlushMs = now + 500;
      return;
    }
    if (now < this.nextFlushMs) return;
    this.nextFlushMs = now + 500;
    this.liveLine =
      `1s  mouse[held=${this.window.mouseMoveHeld} free=${this.window.mouseMoveFree} rawNz=${this.window.mouseRawNonZero}]` +
      `  touch[d=${this.window.touchDown} m=${this.window.touchMove} u=${this.window.touchUp}]` +
      `  axis[cb=${this.window.axisCb} nz=${this.window.axisNonZero}]` +
      `  lastRaw=(${this.lastRawDx},${this.lastRawDy})`;
    this.window.reset();
    this.updateVerdict();
  }

  /**
   * 裁决只用累计量，且只在"确实做过一次按住拖动"之后才给结论 ——
   * 没有数据时必须说"还没数据"，不能给一个看起来像结论的默认值。
   */
  private updateVerdict(): void {
    const heldMoves: number = this.total.mouseMoveHeld;
    const touchMoves: number = this.total.touchMove;
    if (heldMoves === 0 && touchMoves === 0) {
      this.verdictText = '还没有拖动样本：按住左键拖 2~3 秒';
      this.verdictColor = AMBER;
      return;
    }
    if (heldMoves > 0 && this.total.mouseRawNonZero > 0) {
      this.verdictText =
        `✅ 转换已关闭：按住键时 onMouse 仍在投递（${heldMoves} 条），rawDelta 非零 ${this.total.mouseRawNonZero} 条` +
        `${touchMoves > 0 ? `（同时有 ${touchMoves} 条 touch MOVE，需确认是手指还是合成包）` : ''}`;
      this.verdictColor = GREEN;
      return;
    }
    if (heldMoves === 0 && touchMoves > 0) {
      this.verdictText =
        `❌ 转换开启中：按住键期间 onMouse 零投递，位移只以 touch MOVE 出现（${touchMoves} 条）`;
      this.verdictColor = RED;
      return;
    }
    this.verdictText =
      `⚠️ onMouse 有 ${heldMoves} 条但 rawDelta 恒为 0 —— 通道在、相对量不可用`;
    this.verdictColor = AMBER;
  }

  private resetAll(): void {
    this.total.reset();
    this.window.reset();
    this.logLines = [];
    this.liveLine = '';
    this.mouseButtonHeld = false;
    this.nextFlushMs = 0;
    this.verdictText = '已清零：按住左键拖 2~3 秒';
    this.verdictColor = AMBER;
  }

  build() {
    Column({ space: 8 }) {
      Text('键鼠原始输入诊断').fontSize(18).fontColor(FG).fontWeight(FontWeight.Bold)
      Text(this.deviceLine).fontSize(11).fontColor(DIM).fontFamily(MONO)

      Text(this.verdictText)
        .fontSize(13).fontColor(this.verdictColor).fontFamily(MONO)
        .width('100%').padding(10).backgroundColor(PANEL).borderRadius(8)

      Text(this.liveLine.length > 0 ? this.liveLine : '（等待事件…）')
        .fontSize(11).fontColor(FG).fontFamily(MONO)
        .width('100%').padding(8).backgroundColor(PANEL).borderRadius(8)

      Row({ space: 10 }) {
        Button(this.frozen ? '继续采集' : '暂停采集')
          .type(ButtonType.Capsule).fontSize(13)
          .onClick(() => { this.frozen = !this.frozen; })
        Button('清零').type(ButtonType.Capsule).fontSize(13)
          .onClick(() => { this.resetAll(); })
        Button('返回').type(ButtonType.Capsule).fontSize(13)
          .onClick(() => { this.getUIContext().getRouter().back(); })
      }

      // 采集区：所有事件都绑在这块上。刻意不放任何可点击子组件，
      // 避免 ArkUI 的手势识别把 MOVE 吃掉而让观测失真。
      Stack() {
        Column() {
          Text('↓ 在这块区域内操作鼠标 / 手指 ↓').fontSize(12).fontColor(DIM).margin({ bottom: 6 })
          ForEach(this.logLines, (line: string) => {
            Text(line).fontSize(10).fontColor(FG).fontFamily(MONO).width('100%').maxLines(1)
          }, (line: string, index: number) => `${index}-${line}`)
        }
        .width('100%').height('100%').padding(10).alignItems(HorizontalAlign.Start)
      }
      .width('100%').layoutWeight(1)
      .backgroundColor(PANEL).borderRadius(10)
      .onMouse((e: MouseEvent) => { this.handleMouse(e); })
      .onTouch((e: TouchEvent) => { this.handleTouch(e); })
      .onAxisEvent((e: AxisEvent) => { this.handleAxis(e); })

      // 手势层来源判定条带。单独一块，避免手势识别吞掉主采集区的 MOVE。
      Text('↓ 在这条上拖动 / 滚滚轮：手势层来源判定 ↓')
        .fontSize(11).fontColor(DIM).fontFamily(MONO)
        .width('100%').height(52).padding(8)
        .textAlign(TextAlign.Center)
        .backgroundColor(PANEL).borderRadius(8)
        .gesture(
          PanGesture({ distance: 1 })
            .onActionStart((e: GestureEvent) => { this.handlePan('start ', e); })
            .onActionUpdate((e: GestureEvent) => { this.handlePan('update', e); })
            .onActionEnd((e: GestureEvent) => { this.handlePan('end   ', e); })
        )
    }
    .width('100%').height('100%').padding(12).backgroundColor(BG)
  }
}

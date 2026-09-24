/**
 * DevConsole.ets — 开发者探针的统一终端输出面板
 *
 * 为什么要有这个组件（2026-08-01）：
 *   RenderPage / VulkanPage 的结果区原本各自写着 `.backgroundColor('#F5F5F5')` +
 *   一个不设 fontColor 的 Text。浅色模式下勉强能看，**深色模式下就是白底白字**
 *   —— 系统给 Text 的默认前景色随深色模式变成浅色，而面板底色被硬编码成近白，
 *   结果探针输出完全看不见（用户实测反馈）。
 *
 *   DevToolsPage 早就有一套好用的终端面板（深色底 + 状态胶囊 + 逐行着色），
 *   但那是页面内的私有 @Builder，别的页面用不上。于是把它抽成共享组件，
 *   让所有探针页面共用同一套观感，也不必再各自维护一份配色常量。
 *
 * 设计取舍：终端面板**固定深色**，不跟随明暗主题。
 *   理由：这是"控制台"语义，深色底 + 绿/红语义色是开发者的既有心智模型；
 *   跟着浅色主题变白反而让 ✅/❌ 的语义色对比度下降。页面其余部分（标题、
 *   背景、按钮）仍然走 resolveTheme，只有这块保持终端观感。
 *
 * 迁移备注：DevToolsPage 自己的 @Builder ConsoleView 暂未改为引用本组件 ——
 *   它额外耦合了 currentToolDef()/runLabel 等页面内状态，改动面大且那页已在正常
 *   工作。后续要统一时，把它的 ConsoleView 换成 DevConsole 即可，配色常量已在
 *   本文件导出，届时删掉 DevToolsPage 里的重复常量。
 */

// ==================== 终端配色（GitHub Dark 系，与 DevToolsPage 一致）====================
export const CONSOLE_BG: string = '#0E1117'      // 面板主体底色
export const CONSOLE_PANEL: string = '#161B22'   // 顶部标题条底色
export const CONSOLE_FG: string = '#C9D3DE'      // 普通正文
export const CONSOLE_DIM: string = '#6E7B8A'     // 次要/提示文字
export const CONSOLE_GREEN: string = '#3FB950'   // 成功行
export const CONSOLE_RED: string = '#F85149'     // 失败行
export const CONSOLE_CYAN: string = '#39C5CF'    // 标题/分节行
export const CONSOLE_OK_BG: string = '#102A17'   // DONE 胶囊背景
export const CONSOLE_ERR_BG: string = '#2A1213'  // FAILED 胶囊背景
export const CONSOLE_IDLE_BG: string = '#1C2230' // IDLE/RUNNING 胶囊背景
export const CONSOLE_AMBER: string = '#D29922'   // RUNNING
export const CONSOLE_MONO: string = 'monospace'
export const CONSOLE_RADIUS: number = 14

@Component
export struct DevConsole {
  /** 面板标题条上显示的探针标识，例如 'sdl3-window' / 'vulkan'。 */
  @Prop label: string = ''
  /** 探针输出正文（多行，用 \n 分隔）。 */
  @Prop content: string = ''
  /** 是否正在运行（决定状态胶囊显示 RUNNING）。 */
  @Prop running: boolean = false
  /** content 为空时显示的引导文字。 */
  @Prop hint: string = '点击上方按钮开始（结果同时写入 hilog + amcl_launcher.log）'

  build() {
    Column() {
      // ---- 顶部标题条：>_ 标识 + 探针名 + 状态胶囊 ----
      Row({ space: 8 }) {
        Text('>_')
          .fontSize(12)
          .fontColor(CONSOLE_DIM)
          .fontFamily(CONSOLE_MONO)
        Text(this.label.length > 0 ? '控制台输出 · ' + this.label : '控制台输出')
          .fontSize(11)
          .fontColor(CONSOLE_DIM)
          .fontFamily(CONSOLE_MONO)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Circle({ width: 7, height: 7 }).fill(this.statusColor())
          Text(this.statusLabel())
            .fontSize(11)
            .fontColor(this.statusColor())
            .fontFamily(CONSOLE_MONO)
            .fontWeight(FontWeight.Bold)
        }
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .backgroundColor(this.statusBg())
        .borderRadius(20)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(40)
      .padding({ left: 14, right: 12 })
      .backgroundColor(CONSOLE_PANEL)
      .alignItems(VerticalAlign.Center)

      // ---- 正文：逐行着色，等宽字体 ----
      Scroll() {
        Column({ space: 3 }) {
          if (this.content.length === 0) {
            Text(this.hint)
              .width('100%')
              .fontSize(12)
              .fontColor(CONSOLE_DIM)
              .fontFamily(CONSOLE_MONO)
          } else {
            ForEach(this.lines(), (ln: string, i: number) => {
              // 空行给一个空格，否则 Text 高度塌陷、行距看起来不均
              Text(ln.length === 0 ? ' ' : ln)
                .width('100%')
                .fontSize(12)
                .lineHeight(18)
                .fontFamily(CONSOLE_MONO)
                .fontColor(this.lineColor(ln))
                .textAlign(TextAlign.Start)
            }, (ln: string, i: number) => i.toString())
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(CONSOLE_BG)
    .borderRadius(CONSOLE_RADIUS)
    .clip(true)
  }

  // ==================== 状态派生 ====================
  // 判据与 DevToolsPage 保持一致：优先看成功标记，其次失败标记。
  // 探针报告都用 ✅ / ❌ 打标，所以这套关键词匹配足够。

  private isOk(): boolean {
    if (this.running) return false
    return this.content.indexOf('✅') >= 0
      || this.content.indexOf('NATIVE_RW_OK') >= 0
      || this.content.indexOf('PASS') >= 0
      || this.content.indexOf('成功') >= 0
  }

  private isFail(): boolean {
    if (this.running || this.isOk()) return false
    return this.content.indexOf('❌') >= 0
      || this.content.indexOf('FAIL') >= 0
      || this.content.indexOf('失败') >= 0
      || this.content.indexOf('异常') >= 0
      || this.content.indexOf('not permitted') >= 0
  }

  private statusLabel(): string {
    if (this.running) return 'RUNNING'
    if (this.isOk()) return 'DONE'
    if (this.isFail()) return 'FAILED'
    return 'IDLE'
  }

  private statusColor(): string {
    if (this.running) return CONSOLE_AMBER
    if (this.isOk()) return CONSOLE_GREEN
    if (this.isFail()) return CONSOLE_RED
    return CONSOLE_DIM
  }

  private statusBg(): string {
    if (this.isOk()) return CONSOLE_OK_BG
    if (this.isFail()) return CONSOLE_ERR_BG
    return CONSOLE_IDLE_BG
  }

  private lines(): string[] {
    return this.content.length === 0 ? [] : this.content.split('\n')
  }

  /** 单行着色：成功绿 / 失败红 / 分节标题青 / 其余常规前景色。 */
  private lineColor(ln: string): string {
    if (ln.indexOf('✅') >= 0 || ln.indexOf(' OK') >= 0 || ln.indexOf('PASS') >= 0
      || ln.indexOf('NATIVE_RW_OK') >= 0 || ln.indexOf('成功') >= 0) {
      return CONSOLE_GREEN
    }
    if (ln.indexOf('❌') >= 0 || ln.indexOf('FAIL') >= 0 || ln.indexOf('失败') >= 0
      || ln.indexOf('异常') >= 0 || ln.indexOf('not permitted') >= 0) {
      return CONSOLE_RED
    }
    // '=====' 包裹的分节标题、以及 '⚠️' 提示行用青色，便于快速扫读结构
    if (ln.indexOf('=====') >= 0 || ln.indexOf('⚠️') >= 0) {
      return CONSOLE_CYAN
    }
    return CONSOLE_FG
  }
}

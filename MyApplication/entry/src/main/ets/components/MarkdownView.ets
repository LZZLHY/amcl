/**
 * MarkdownView.ets — 轻量 Markdown 渲染器（消息中心与诊断体验 · M1）
 *
 * 为什么自己写：ArkUI 没有内置 Markdown 组件。备选方案都被否掉了 ——
 *   - `Web` 组件加载 HTML：为了渲染一段文本引入整个浏览器内核，且要处理 XSS，
 *     攻击面与体量都不划算（AI 输出是第三方内容）。
 *   - `StyledString`：需要命令式 controller，与本项目的声明式风格不搭，
 *     而且块级结构（标题/列表/代码块）仍然得自己切。
 *
 * 支持的语法子集**有实测依据**，不是凭空取的。对真机跑出的那份 AI 输出
 * （`.tmp-logshare/ai-answer.md`，38 行）做过统计：`###`×3、`####`×2、
 * `#####`×2、`**加粗**`×9、行内代码×12、围栏代码块×2、有序列表×4、
 * 无序列表×3、分隔线×4，引用/表格/链接/图片均为 0。
 *
 * 未覆盖的语法（表格、链接、引用、图片）**降级为纯文本原样显示**，绝不丢内容 ——
 * AI 输出不受我们控制，将来完全可能冒出表格。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §2.1–§2.4
 * 创建日期：2026-07-30
 */

import { ThemeColors } from 'commons';

// ============================================================================
//  数据模型
// ============================================================================

/** 块级元素类型。 */
export enum MdKind {
  /** 标题，level 1~6。 */
  Heading,
  /** 普通段落。 */
  Paragraph,
  /** 列表项（有序 / 无序）。 */
  ListItem,
  /** 围栏代码块。 */
  Code,
  /** 分隔线。 */
  Divider,
}

/** 一个块级元素。 */
export interface MdBlock {
  kind: MdKind;
  /** 正文（代码块为原始多行文本；分隔线为空串）。 */
  text: string;
  /** 标题级别 1~6；非标题为 0。 */
  level: number;
  /** 列表项是否有序。 */
  ordered: boolean;
  /** 列表项的显示序号 / 项目符号（如 '1.' 或 '•'）。 */
  marker: string;
  /** 代码块语言标记（可为空串）。 */
  lang: string;
  /** 列表缩进层级（0 起）。 */
  indent: number;
}

/** 行内片段。ArkUI 的 Span 不支持背景色，所以行内代码只能靠字体 + 颜色区分。 */
export interface MdSpan {
  text: string;
  bold: boolean;
  code: boolean;
}

// ============================================================================
//  行内解析
// ============================================================================

/**
 * 解析行内代码，并把外层的加粗状态透传下去。
 *
 * 单独抽出来是因为实测样本里出现了 `**\`fml.toml\`配置项警告**` —— **加粗里套着
 * 行内代码**。如果只在顶层扫一遍，反引号会被当成加粗正文里的字面量原样显示。
 */
function pushCodeAware(out: MdSpan[], src: string, bold: boolean): void {
  let buf = '';
  let i = 0;
  while (i < src.length) {
    if (src.charAt(i) === '`') {
      let end = src.indexOf('`', i + 1);
      if (end > i) {
        if (buf.length > 0) {
          let t: MdSpan = { text: buf, bold: bold, code: false };
          out.push(t);
          buf = '';
        }
        let c: MdSpan = { text: src.substring(i + 1, end), bold: bold, code: true };
        out.push(c);
        i = end + 1;
        continue;
      }
      // 未闭合的反引号：当字面量，不丢字
      buf += src.charAt(i);
      i++;
      continue;
    }
    buf += src.charAt(i);
    i++;
  }
  if (buf.length > 0) {
    let t: MdSpan = { text: buf, bold: bold, code: false };
    out.push(t);
  }
}

/**
 * 把一行文本切成行内片段。
 *
 * 顶层同时认反引号和 `**`：先遇到哪个就先处理哪个，这样
 * `` `a**b` `` 里的 `**` 不会被误当成加粗起点。
 * 所有未闭合的标记都退化为字面量输出。
 */
export function parseMarkdownInline(src: string): MdSpan[] {
  let out: MdSpan[] = [];
  if (src.length === 0) return out;
  let buf = '';
  let i = 0;
  while (i < src.length) {
    let ch = src.charAt(i);

    // 行内代码（优先级最高：代码里的 ** 是字面量）
    if (ch === '`') {
      let end = src.indexOf('`', i + 1);
      if (end > i) {
        if (buf.length > 0) {
          let t: MdSpan = { text: buf, bold: false, code: false };
          out.push(t);
          buf = '';
        }
        let c: MdSpan = { text: src.substring(i + 1, end), bold: false, code: true };
        out.push(c);
        i = end + 1;
        continue;
      }
      buf += ch;
      i++;
      continue;
    }

    // 加粗
    if (ch === '*' && i + 1 < src.length && src.charAt(i + 1) === '*') {
      let end = src.indexOf('**', i + 2);
      if (end > i + 1) {
        if (buf.length > 0) {
          let t: MdSpan = { text: buf, bold: false, code: false };
          out.push(t);
          buf = '';
        }
        // 加粗正文里可能还有行内代码
        pushCodeAware(out, src.substring(i + 2, end), true);
        i = end + 2;
        continue;
      }
      buf += '**';
      i += 2;
      continue;
    }

    buf += ch;
    i++;
  }
  if (buf.length > 0) {
    let t: MdSpan = { text: buf, bold: false, code: false };
    out.push(t);
  }
  return out;
}

// ============================================================================
//  块级解析
// ============================================================================

/** 是不是分隔线（--- / *** / ___，允许更长）。 */
function isDividerLine(line: string): boolean {
  let t = line.trim();
  if (t.length < 3) return false;
  let c = t.charAt(0);
  if (c !== '-' && c !== '*' && c !== '_') return false;
  for (let i = 0; i < t.length; i++) {
    if (t.charAt(i) !== c) return false;
  }
  return true;
}

/** 建一个默认块，避免到处写全字段字面量。 */
function makeBlock(kind: MdKind, text: string): MdBlock {
  let b: MdBlock = {
    kind: kind, text: text, level: 0,
    ordered: false, marker: '', lang: '', indent: 0,
  };
  return b;
}

/**
 * 块级解析。
 *
 * 容错是硬要求：未闭合的围栏、`#######`（7 个）这种越界标题、乱缩进，
 * 一律降级成段落，**任何输入都不抛异常**。
 */
export function parseMarkdown(src: string): MdBlock[] {
  let blocks: MdBlock[] = [];
  if (!src || src.length === 0) return blocks;

  let lines = src.split('\n');
  let para: string[] = [];

  let i = 0;
  while (i < lines.length) {
    let raw = lines[i];
    let line = raw.replace(/\r$/, '');
    let trimmed = line.trim();

    // ---- 围栏代码块 ----
    if (trimmed.startsWith('```')) {
      // 先把攒着的段落吐出去
      if (para.length > 0) {
        blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
        para = [];
      }
      let lang = trimmed.substring(3).trim();
      let body: string[] = [];
      i++;
      let closed = false;
      while (i < lines.length) {
        let cur = lines[i].replace(/\r$/, '');
        if (cur.trim().startsWith('```')) { closed = true; i++; break; }
        body.push(cur);
        i++;
      }
      // 未闭合也照样成块（流式输出时代码块常常是「写了一半」的状态）
      let cb = makeBlock(MdKind.Code, body.join('\n'));
      cb.lang = lang;
      cb.ordered = closed;   // 复用字段记录是否已闭合，UI 不依赖它，仅便于调试
      blocks.push(cb);
      continue;
    }

    // ---- 空行：段落分隔 ----
    if (trimmed.length === 0) {
      if (para.length > 0) {
        blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
        para = [];
      }
      i++;
      continue;
    }

    // ---- 分隔线 ----
    if (isDividerLine(trimmed)) {
      if (para.length > 0) {
        blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
        para = [];
      }
      blocks.push(makeBlock(MdKind.Divider, ''));
      i++;
      continue;
    }

    // ---- 标题 ----
    let h = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (h !== null) {
      if (para.length > 0) {
        blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
        para = [];
      }
      let hb = makeBlock(MdKind.Heading, h[2].trim());
      hb.level = h[1].length;
      blocks.push(hb);
      i++;
      continue;
    }

    // ---- 列表项 ----
    let li = line.match(/^(\s*)([-*+]|\d{1,3}\.)\s+(.*)$/);
    if (li !== null) {
      if (para.length > 0) {
        blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
        para = [];
      }
      let lead = li[1].length;
      let mark = li[2];
      let lb = makeBlock(MdKind.ListItem, li[3]);
      lb.indent = Math.min(Math.floor(lead / 2), 3);
      lb.ordered = mark.endsWith('.');
      lb.marker = lb.ordered ? mark : '•';
      blocks.push(lb);
      i++;
      continue;
    }

    // ---- 普通行：攒进当前段落 ----
    // 缩进的续行（样本里 ② 下面有两格缩进的接续说明）会自然并进同一段落，
    // 不会被拆成一堆独立小段。
    para.push(trimmed);
    i++;
  }

  if (para.length > 0) {
    blocks.push(makeBlock(MdKind.Paragraph, para.join('\n')));
  }
  return blocks;
}

// ============================================================================
//  组件
// ============================================================================

@Component
export struct MarkdownView {
  /** Markdown 原文。流式输出时会持续变化。 */
  @Prop @Watch('onContentChanged_') content: string = ''
  /** 主题色。 */
  @Prop theme: ThemeColors = new ThemeColors()
  /** 正文字号（标题按比例放大）。 */
  @Prop baseFontSize: number = 12
  /** 代码块超过多少行折叠，0 = 不折叠。 */
  @Prop maxCodeLines: number = 12

  @State private blocks: MdBlock[] = []
  /** 已展开的代码块 key 列表。 */
  @State private expandedCode: string[] = []

  /** 上次解析时的内容长度，用于按增量节流。 */
  private lastParsedLen: number = -1
  /** 尾随定时器 id，-1 = 无。 */
  private parseTimer: number = -1

  aboutToAppear(): void {
    this.doParse_()
  }

  aboutToDisappear(): void {
    if (this.parseTimer >= 0) {
      clearTimeout(this.parseTimer)
      this.parseTimer = -1
    }
  }

  /**
   * 内容变化时按增量节流重解析。
   *
   * 流式输出一个 chunk 可能只有几个字，逐 chunk 全量重解析会把主线程打满。
   * 策略：增量 ≥ 200 字符立刻解析；否则起一个 300 ms 的尾随定时器 ——
   * 这个定时器保证**流结束后一定会再解析一次**，不会停在半解析状态。
   */
  private onContentChanged_(): void {
    let len = this.content.length
    // 内容变短说明是换了一份内容（比如撤回后复位），必须立刻重解析
    if (this.lastParsedLen < 0 || len < this.lastParsedLen || len - this.lastParsedLen >= 200) {
      this.doParse_()
      return
    }
    if (this.parseTimer >= 0) return
    this.parseTimer = setTimeout(() => {
      this.parseTimer = -1
      this.doParse_()
    }, 300)
  }

  private doParse_(): void {
    this.blocks = parseMarkdown(this.content)
    this.lastParsedLen = this.content.length
  }

  private headingSize_(level: number): number {
    if (level <= 1) return this.baseFontSize + 7
    if (level === 2) return this.baseFontSize + 5
    if (level === 3) return this.baseFontSize + 3
    if (level === 4) return this.baseFontSize + 2
    if (level === 5) return this.baseFontSize + 1
    return this.baseFontSize
  }

  private headingWeight_(level: number): number {
    return level <= 3 ? 700 : 600
  }

  private codeKey_(idx: number): string {
    return 'code-' + idx
  }

  private isCodeExpanded_(idx: number): boolean {
    return this.expandedCode.includes(this.codeKey_(idx))
  }

  private toggleCode_(idx: number): void {
    let key = this.codeKey_(idx)
    let next: string[] = []
    let removed = false
    for (let i = 0; i < this.expandedCode.length; i++) {
      if (this.expandedCode[i] === key) { removed = true; continue }
      next.push(this.expandedCode[i])
    }
    if (!removed) next.push(key)
    this.expandedCode = next
  }

  build() {
    Column({ space: 6 }) {
      ForEach(this.blocks, (b: MdBlock, idx: number) => {
        if (b.kind === MdKind.Heading) {
          this.HeadingBlock_(b)
        } else if (b.kind === MdKind.Code) {
          this.CodeBlock_(b, idx)
        } else if (b.kind === MdKind.Divider) {
          this.DividerBlock_()
        } else if (b.kind === MdKind.ListItem) {
          this.ListItemBlock_(b)
        } else {
          this.ParagraphBlock_(b)
        }
      }, (b: MdBlock, idx: number) => idx + ':' + b.kind + ':' + b.text.length)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  HeadingBlock_(b: MdBlock) {
    Text() {
      ForEach(parseMarkdownInline(b.text), (s: MdSpan, i: number) => {
        Span(s.text)
          .fontFamily(s.code ? 'HarmonyHeiTi-Mono, monospace' : '')
          .fontColor(s.code ? this.theme.primary : this.theme.textPrimary)
      }, (s: MdSpan, i: number) => i + ':' + (s.code ? 'c' : 't'))
    }
    .fontSize(this.headingSize_(b.level))
    .fontWeight(this.headingWeight_(b.level))
    .fontColor(this.theme.textPrimary)
    .lineHeight(this.headingSize_(b.level) + 8)
    .width('100%')
    .margin({ top: b.level <= 3 ? 6 : 2 })
  }

  @Builder
  ParagraphBlock_(b: MdBlock) {
    Text() {
      ForEach(parseMarkdownInline(b.text), (s: MdSpan, i: number) => {
        Span(s.text)
          .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
          // §2.4：Span 不支持 backgroundColor，行内代码只能靠等宽字体 + 强调色区分
          .fontFamily(s.code ? 'HarmonyHeiTi-Mono, monospace' : '')
          .fontColor(s.code ? this.theme.primary
            : (s.bold ? this.theme.textPrimary : this.theme.textSecondary))
      }, (s: MdSpan, i: number) => i + ':' + (s.bold ? 'b' : '') + (s.code ? 'c' : ''))
    }
    .fontSize(this.baseFontSize)
    .lineHeight(this.baseFontSize + 7)
    .width('100%')
    .textAlign(TextAlign.Start)
  }

  @Builder
  ListItemBlock_(b: MdBlock) {
    Row({ space: 6 }) {
      Text(b.marker)
        .fontSize(this.baseFontSize)
        .fontWeight(b.ordered ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.theme.textHint)
        .lineHeight(this.baseFontSize + 7)
        .constraintSize({ minWidth: b.ordered ? 18 : 10 })

      Text() {
        ForEach(parseMarkdownInline(b.text), (s: MdSpan, i: number) => {
          Span(s.text)
            .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontFamily(s.code ? 'HarmonyHeiTi-Mono, monospace' : '')
            .fontColor(s.code ? this.theme.primary
              : (s.bold ? this.theme.textPrimary : this.theme.textSecondary))
        }, (s: MdSpan, i: number) => i + ':' + (s.bold ? 'b' : '') + (s.code ? 'c' : ''))
      }
      .fontSize(this.baseFontSize)
      .lineHeight(this.baseFontSize + 7)
      .layoutWeight(1)
      .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: b.indent * 14 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  DividerBlock_() {
    Row()
      .width('100%')
      .height(1)
      .backgroundColor(this.theme.divider)
      .margin({ top: 4, bottom: 4 })
  }

  @Builder
  CodeBlock_(b: MdBlock, idx: number) {
    Column({ space: 4 }) {
      if (b.lang.length > 0) {
        Text(b.lang)
          .fontSize(this.baseFontSize - 2)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textHint)
      }
      // 代码块内不参与行内解析：`**` 在代码里是字面量
      Scroll() {
        Text(this.codeBodyOf_(b, idx))
          .fontSize(this.baseFontSize - 1)
          .fontFamily('HarmonyHeiTi-Mono, monospace')
          .lineHeight(this.baseFontSize + 5)
          .fontColor(this.theme.textPrimary)
          .textAlign(TextAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.TopStart)

      if (this.codeFoldable_(b)) {
        Text(this.isCodeExpanded_(idx)
          ? '收起代码'
          : ('展开剩余 ' + (this.codeLineCount_(b) - this.maxCodeLines) + ' 行'))
          .fontSize(this.baseFontSize - 1)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.primary)
          .onClick(() => { this.toggleCode_(idx) })
      }
    }
    .width('100%')
    .padding(10)
    .borderRadius(8)
    .backgroundColor(this.theme.bgCard)
    .alignItems(HorizontalAlign.Start)
  }

  private codeLineCount_(b: MdBlock): number {
    if (b.text.length === 0) return 0
    return b.text.split('\n').length
  }

  private codeFoldable_(b: MdBlock): boolean {
    return this.maxCodeLines > 0 && this.codeLineCount_(b) > this.maxCodeLines
  }

  /** 折叠状态下只给前 maxCodeLines 行。 */
  private codeBodyOf_(b: MdBlock, idx: number): string {
    if (!this.codeFoldable_(b) || this.isCodeExpanded_(idx)) return b.text
    let lines = b.text.split('\n')
    let keep: string[] = []
    for (let i = 0; i < this.maxCodeLines && i < lines.length; i++) {
      keep.push(lines[i])
    }
    return keep.join('\n')
  }
}

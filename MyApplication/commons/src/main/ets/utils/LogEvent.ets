/**
 * 日志事件的只读语义层。原文行号和文本始终保留，不改写任何日志文件。
 * 支持 Minecraft/Fabric/Forge/AMCL 文本头及官方 LegacyXMLLayout；无前缀续行
 * 归属前一条有头事件，因此依赖建议、异常链和 WARN 的堆栈不会被逐行筛选拆散。
 * XML 只提取白名单属性和 CDATA/内置实体，不解析 DTD、外部实体或执行内容。
 */
export interface LogEventLine { number: number; text: string; }
export interface LogEventRecord {
  startLine: number;
  endLine: number;
  level: number;
  timestamp: string;
  thread: string;
  logger: string;
  format: string;
  title: string;
  lines: LogEventLine[];
  incomplete: boolean;
}

const TEXT_LEVEL = new RegExp('(?:\\[|/|^\\s*)(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|[DIWEF])(?:\\]|[ :])', 'i');
const TEXT_START = new RegExp('^\\s*(?:\\[(?:[0-9]{2}:[0-9]{2}|[0-9]{4}[-/]|[0-9]{1,2}[A-Za-z]{3}[0-9]{4}|TRACE\\]|DEBUG\\]|INFO\\]|WARN\\]|ERROR\\]|FATAL\\])|\\[[A-Z][A-Z0-9_-]+\\])', 'i');
const XML_START = new RegExp('^\\s*<(?:log4j:)?Event\\b', 'i');
const THROWABLE = new RegExp('^\\s*(?:Exception in thread\\s+"[^"\\r\\n]*"\\s+)?(?:[a-zA-Z_$][\\w$]*[./])+[\\w$]*(?:Exception|Error|Throwable)(?::|$)');

/** 统一的显示级别：普通=0，警告=1，错误/致命=2。不会由词汇 error 推测崩溃。 */
export function severityOfLogName(name: string): number {
  const value: string = name.toUpperCase();
  if (value === 'ERROR' || value === 'FATAL' || value === 'E' || value === 'F') return 2;
  return value === 'WARN' || value === 'WARNING' || value === 'W' ? 1 : 0;
}

/** 仅解码 XML 的标准实体。顺序最后处理 amp，避免把二次转义文本再次解释为标签。 */
function xmlText(value: string): string {
  return value.replace(new RegExp('&lt;', 'g'), '<').replace(new RegExp('&gt;', 'g'), '>')
    .replace(new RegExp('&quot;', 'g'), '"').replace(new RegExp('&apos;', 'g'), "'")
    .replace(new RegExp('&amp;', 'g'), '&');
}

/** 属性名只由调用方固定传入；限制到当前标签，避免在消息正文中误取 level。 */
function xmlAttribute(header: string, key: string): string {
  const match: RegExpMatchArray | null = header.substring(0, header.indexOf('>') + 1 || header.length)
    .match(new RegExp('\\b' + key + '\\s*=\\s*["\']([^"\']*)["\']', 'i'));
  return match === null ? '' : xmlText(match[1]);
}

/** 返回显式头部级别，-1 表示没有头部；XML 的级别与文本共用同一策略。 */
export function explicitLogLevel(text: string): number {
  if (XML_START.test(text)) {
    const name: string = xmlAttribute(text, 'level');
    return name.length > 0 ? severityOfLogName(name) : -1;
  }
  const match: RegExpMatchArray | null = text.match(TEXT_LEVEL);
  return match === null ? -1 : severityOfLogName(match[1]);
}

/** 裸 JVM 失败与异常顶行可独立成事件；普通提到 Exception 的散文不命中。 */
export function logLineSeverity(text: string): number {
  const explicit: number = explicitLogLevel(text);
  if (explicit >= 0) return explicit;
  if (THROWABLE.test(text) || new RegExp('^\\s*(?:Error:|Caused by:|Suppressed:|at [\\w.$/]+\\(|\\.\\.\\. \\d+ more)').test(text)
    || text.toLowerCase().indexOf('# a fatal error has been detected') >= 0) return 2;
  return 0;
}

/** 新事件边界只认行首头部。带级别的消息正文不会任意切断上一事件。 */
export function isLogEventHeader(text: string): boolean {
  return XML_START.test(text) || TEXT_START.test(text);
}

/** 标题是可读摘要，原 XML 与所有续行仍在 lines 中供原文定位/导出。 */
export function logEventTitle(event: LogEventRecord): string {
  if (event.format === 'xml') {
    const body: string = event.lines.map((line: LogEventLine): string => line.text).join('\n');
    const message: RegExpMatchArray | null = body.match(new RegExp('<(?:log4j:)?Message[^>]*>([\\s\\S]*?)</(?:log4j:)?Message>', 'i'));
    if (message !== null) return xmlText(message[1].replace(new RegExp('^<!\\[CDATA\\[|\\]\\]>$', 'g'), '')).trim().substring(0, 500);
  }
  return (event.lines[0]?.text ?? '').trim().substring(0, 500);
}

/**
 * 每个文件独立持有一个解析器。feed 返回已结束事件，当前行保存在下一事件中；
 * finish 在 EOF/文件切换时取走最后一个事件。单事件超预算明确报错，绝不静默节选。
 */
export class LogEventParser {
  private current: LogEventRecord | undefined = undefined;
  private grouped: boolean = false;
  private xmlClosed: boolean = false;
  private characters: number = 0;

  feed(text: string, lineNumber: number): LogEventRecord | undefined {
    const header: boolean = isLogEventHeader(text);
    const boundary: boolean = this.current !== undefined && (header || this.xmlClosed || !this.grouped);
    let completed: LogEventRecord | undefined = undefined;
    if (boundary) completed = this.finish();
    if (this.current === undefined) {
      const xml: boolean = XML_START.test(text);
      const time: RegExpMatchArray | null = text.match(new RegExp('^\\s*\\[([^\\]]+)\\]'));
      const thread: RegExpMatchArray | null = text.match(new RegExp('\\[([^\\]]+)/(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\\]', 'i'));
      this.current = { startLine: lineNumber, endLine: lineNumber, level: logLineSeverity(text),
        timestamp: xml ? xmlAttribute(text, 'timestamp') : time?.[1] ?? '',
        thread: xml ? xmlAttribute(text, 'thread') : thread?.[1] ?? '',
        logger: xml ? xmlAttribute(text, 'logger') : '', format: xml ? 'xml' : header ? 'text' : 'plain',
        title: '', lines: [], incomplete: false };
      this.grouped = header || THROWABLE.test(text) || new RegExp('^\\s*(?:Error:|# A fatal error)', 'i').test(text);
    }
    this.characters += text.length;
    if (this.characters > 8 * 1024 * 1024) throw new Error('单个日志事件超过 8 MiB，请导出完整 ZIP 查看');
    this.current.lines.push({ number: lineNumber, text: text });
    this.current.endLine = lineNumber;
    this.xmlClosed = this.current.format === 'xml' && new RegExp('</(?:log4j:)?Event\\s*>', 'i').test(text);
    return completed;
  }

  /** EOF 时没有 XML 结束标签只说明该事件未写完；已经保存的行仍可读取。 */
  finish(): LogEventRecord | undefined {
    const result: LogEventRecord | undefined = this.current;
    if (result !== undefined) {
      result.incomplete = result.format === 'xml' && !this.xmlClosed;
      result.title = logEventTitle(result);
    }
    this.current = undefined; this.grouped = false; this.xmlClosed = false; this.characters = 0;
    return result;
  }

  /**
   * 跟随输出时预览尚未结束的事件，保留解析器和 UTF-8/续行状态等待下一批追加。
   * partialLine 只加到副本，不提前消费，避免追加到同一行时重复或丢字。
   */
  snapshot(partialLine: string, lineNumber: number): LogEventRecord | undefined {
    const current = this.current;
    if (current === undefined && partialLine.length === 0) return undefined;
    const result: LogEventRecord = { startLine: current?.startLine ?? lineNumber, endLine: current?.endLine ?? lineNumber,
      level: current?.level ?? logLineSeverity(partialLine), timestamp: current?.timestamp ?? '',
      thread: current?.thread ?? '', logger: current?.logger ?? '', format: current?.format ?? 'plain',
      title: '', lines: current?.lines.slice() ?? [], incomplete: partialLine.length > 0 || current?.format === 'xml' && !this.xmlClosed };
    if (partialLine.length > 0) { result.lines.push({ number: lineNumber, text: partialLine }); result.endLine = lineNumber; }
    result.title = logEventTitle(result);
    return result;
  }
}

/** 搜索整条事件，避免搜索标题后遗漏解释；调用方决定是否额外展示相邻事件。 */
export function logEventMatches(event: LogEventRecord, minLevel: number, query: string): boolean {
  if (event.level < minLevel) return false;
  const keyword: string = query.trim().toLowerCase();
  return keyword.length === 0 || event.lines.some((line: LogEventLine): boolean => line.text.toLowerCase().indexOf(keyword) >= 0)
    || event.title.toLowerCase().indexOf(keyword) >= 0;
}

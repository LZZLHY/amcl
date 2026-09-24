/** LogShare SSE 按行分帧；只输出正文和白名单粗状态，工具结果与思维链不进入回答。 */
export interface LogShareSseSink {
  onDelta: (text: string) => void;
  onDone: (text: string) => void;
  onError: (message: string) => void;
  /** 仅输出白名单粗状态，绝不传出 status 中的 reasoning/tool 参数和正文。 */
  onStatus?: (status: string, position: number) => void;
}
interface SseDelta { content?: string; }
interface SseChoice { delta?: SseDelta; }
interface SsePayload { choices?: SseChoice[]; status?: string; error?: string; message?: string; success?: boolean; }
interface SseStatusPayload { type?: string; position?: number; }

export class LogShareSseParser {
  private sink: LogShareSseSink;
  private buffer: string = '';
  private eventName: string = '';
  private dataLines: string[] = [];
  private answer: string = '';
  private settled: boolean = false;
  /** 行、整帧和回答各自有界；短 data 行也不能绕过整帧上限。 */
  private frameSize: number = 0;
  private afterCr: boolean = false;
  private firstCharacter: boolean = true;
  constructor(sink: LogShareSseSink) { this.sink = sink; }
  feed(text: string): void {
    // 支持 LF、单 CR 与跨包 CRLF；BOM 只允许出现在流开头，正文空格保持原样。
    for (let i = 0; i < text.length && !this.settled; i++) {
      const ch: string = text.charAt(i);
      if (this.firstCharacter) { this.firstCharacter = false; if (ch === '\uFEFF') continue; }
      if (this.afterCr) { this.afterCr = false; if (ch === '\n') continue; }
      if (ch === '\r' || ch === '\n') {
        const line: string = this.buffer; this.buffer = ''; this.afterCr = ch === '\r'; this.line(line);
      } else {
        this.buffer += ch;
        if (this.buffer.length + this.frameSize > 1024 * 1024) this.fail('AI 响应单帧过大');
      }
    }
  }
  /** EOF 不补造分帧空行，半截 done 不能冒充正常完成。 */
  end(): void {
    if (this.settled) return;
    this.fail('AI 响应在完成标记前中断，请重试');
  }
  private line(line: string): void {
    if (line.length === 0) { this.dispatch(); return; }
    this.frameSize += line.length + 1;
    if (this.frameSize > 1024 * 1024) { this.fail('AI 响应单帧过大'); return; }
    if (line.startsWith(':')) return;
    const colon: number = line.indexOf(':');
    const field: string = colon < 0 ? line : line.substring(0, colon);
    let value: string = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field === 'event') this.eventName = value;
    if (field === 'data') this.dataLines.push(value);
  }
  private dispatch(): void {
    if (this.settled) return;
    const eventName = this.eventName;
    const data = this.dataLines.join('\n');
    this.eventName = ''; this.dataLines = []; this.frameSize = 0;
    if (eventName === 'status') {
      try {
        const status = JSON.parse(data) as SseStatusPayload;
        if (status.type === 'queued') this.sink.onStatus?.('queued',
          typeof status.position === 'number' && Number.isFinite(status.position) ? Math.max(0, Math.floor(status.position)) : 0);
        else if (status.type === 'thinking' || status.type === 'tool' || status.type === 'tool_result') this.sink.onStatus?.('analyzing', 0);
        else if (status.type === 'limit') this.sink.onStatus?.('limit', 0);
      } catch (e) { /* 非正文状态帧损坏不把内部内容降级成可见回答。 */ }
      return;
    }
    // 官网仅声明默认正文、status、error、done；未知命名事件不能被降级为正文。
    if (eventName !== '' && eventName !== 'message' && eventName !== 'done' && eventName !== 'error') return;
    if (data === '[DONE]' && (eventName === '' || eventName === 'message')) { this.complete(); return; }
    if (data.length === 0) {
      if (eventName === 'done') this.complete();
      else if (eventName === 'error') this.fail('AI 分析失败');
      return;
    }
    try {
      const payload = JSON.parse(data) as SsePayload;
      if (eventName === 'error' || payload.success === false || typeof payload.error === 'string') {
        this.fail(payload.error ?? payload.message ?? 'AI 分析失败'); return;
      }
      if (eventName === 'done') {
        if (payload.status !== undefined && payload.status !== 'completed' && payload.status !== 'done') this.fail('AI 分析未完成：' + payload.status);
        else this.complete();
        return;
      }
      const delta = payload.choices?.[0]?.delta?.content;
      if (typeof delta !== 'string' || delta.length === 0) return;
      if (this.answer.length + delta.length > 1024 * 1024) { this.fail('AI 分析内容过长'); return; }
      this.answer += delta; this.sink.onDelta(delta);
    } catch (e) { this.fail('AI 响应格式无效'); }
  }
  private complete(): void {
    if (this.answer.length === 0) { this.fail('AI 未返回分析内容'); return; }
    this.settled = true; this.sink.onDone(this.answer);
  }
  /** 先封闭并释放缓冲再通知；迟到 dataEnd、重复 done 和后续错误不重复终态。 */
  private fail(message: string): void {
    if (!this.settled) { this.settled = true; this.buffer = ''; this.dataLines = []; this.sink.onError(message); }
  }
}

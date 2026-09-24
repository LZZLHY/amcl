/** 按文件流读取完整日志事件；分页不拆异常链，所有显示行保留原文件位置。 */
import { EvidenceTextCursor, evidenceFileStamp, LogEventParser, LogEventRecord,
  LogEventLine, logEventMatches, logLineSeverity } from 'commons';

export interface LogReadSource { path: string; compressed: boolean; }
export interface LogSpan {
  text: string;
  color: string;
}

export interface LogRow {
  key: number;
  lineNumber: number;
  continuation: boolean;
  text: string;
  level: number;
  /** 合并阅读时保留文件身份与文件内行号；lineNumber 仍用于兼容累计扫描计数。 */
  sourcePath?: string;
  sourceLineNumber?: number;
  sourceStart?: boolean;
  matches?: LogMatchRange[];
  matchKeyword?: string;
  /** 同一事件的所有显示块共享只读对象，复制/折叠不会重读或改写原件。 */
  event?: LogEventRecord;
  eventId?: string;
  eventStart?: boolean;
}

/** 命中区间先在完整逻辑行计算，再裁剪到视觉块，确保搜索与着色语义一致。 */
export interface LogMatchRange { start: number; end: number; }
function matchRanges(text: string, query: string, start: number = 0, end: number = text.length): LogMatchRange[] {
  const out: LogMatchRange[] = [];
  if (query.length === 0) return out;
  const lower: string = text.toLowerCase();
  let at: number = lower.indexOf(query);
  while (at >= 0 && at < end) {
    if (at + query.length > start) out.push({ start: Math.max(start, at) - start, end: Math.min(end, at + query.length) - start });
    at = lower.indexOf(query, at + query.length);
  }
  return out;
}

/** 顺序扫描状态只在当前阅读会话存活；离页、来源变化或取消时必须关闭游标。 */
class LogScanState {
  sourceIndex: number = 0;
  cursor: EvidenceTextCursor | undefined = undefined;
  pending: string = '';
  eof: boolean = false;
  lineNumber: number = 0;
  sourceLineNumber: number = 0;
  matched: number = 0;
  nextSkip: number = 0;
  parser: LogEventParser = new LogEventParser();
  queued: LogEventRecord | undefined = undefined;
}
interface LogCachedPage {
  rows: LogRow[]; lineCount: number; matchingLines: number; matchingEvents: number; hasNext: boolean; pageStart: number;
}

/** 跟随读取只保存最新窗口与一个未结束事件，游标在轮询之间保留 UTF-8 与字节偏移。 */
class LiveLogState {
  path: string = '';
  cursor: EvidenceTextCursor = new EvidenceTextCursor();
  parser: LogEventParser = new LogEventParser();
  pending: string = '';
  lineNumber: number = 0;
  events: LogEventRecord[] = [];
  characters: number = 0;
}

const TOKEN_PATTERN = new RegExp('\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b|\\b(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\\b|\\[[DIWEF]\\]|[\\w.$]+(?:Exception|Error)\\b|[\\w$]+\\.java:\\d+', 'g');

export function logLevel(text: string): number {
  return logLineSeverity(text);
}

export function logSpans(row: LogRow, keyword: string): LogSpan[] {
  const spans: LogSpan[] = [];
  const base = row.level === 2 ? '#FCA5A5' : row.level === 1 ? '#FCD38A' : '#CBD5E1';
  const pattern = new RegExp(TOKEN_PATTERN.source, 'g');
  let cursor = 0;
  let match = pattern.exec(row.text);
  while (match !== null) {
    if (match.index > cursor) spans.push({ text: row.text.slice(cursor, match.index), color: base });
    const token = match[0];
    let color = '#7DD3FC';
    if (token.indexOf('Exception') >= 0 || token.indexOf('Error') >= 0) color = '#F0ABFC';
    else if (new RegExp('ERROR|FATAL|\\[[EF]\\]').test(token)) color = '#FB7185';
    else if (new RegExp('WARN|\\[W\\]').test(token)) color = '#FBBF24';
    else if (new RegExp('INFO|\\[I\\]').test(token)) color = '#6EE7B7';
    else if (new RegExp('DEBUG|TRACE|\\[D\\]').test(token)) color = '#A78BFA';
    spans.push({ text: token, color: color });
    cursor = match.index + token.length;
    match = pattern.exec(row.text);
  }
  if (cursor < row.text.length) spans.push({ text: row.text.slice(cursor), color: base });
  if (row.text.length === 0) spans.push({ text: ' ', color: base });
  if (keyword.length === 0) return spans;
  const highlighted: LogSpan[] = [];
  const query = keyword.toLowerCase();
  const ranges: LogMatchRange[] = row.matchKeyword === query && row.matches !== undefined
    ? row.matches : matchRanges(row.text, query);
  let spanOffset: number = 0;
  for (const span of spans) {
    let start: number = 0;
    for (const range of ranges) {
      const left: number = Math.max(0, range.start - spanOffset);
      const right: number = Math.min(span.text.length, range.end - spanOffset);
      if (right <= left) continue;
      if (left > start) highlighted.push({ text: span.text.slice(start, left), color: span.color });
      highlighted.push({ text: span.text.slice(left, right), color: '#FDE047' });
      start = right;
    }
    if (start < span.text.length) highlighted.push({ text: span.text.slice(start), color: span.color });
    spanOffset += span.text.length;
  }
  return highlighted;
}

export class ActivityLogModel implements IDataSource {
  private rows: LogRow[] = [];
  private visible: number[] = [];
  private filtered: number[] = [];
  private listeners: DataChangeListener[] = [];
  private generation: number = 0;
  lineCount: number = 0;
  matchingLines: number = 0;
  matchingEvents: number = 0;
  hasNextPage: boolean = false;
  pageStart: number = 0;
  private activeCursor: EvidenceTextCursor | undefined = undefined;
  private scanKey: string = '';
  private idleScan: LogScanState | undefined = undefined;
  private pageCache: Map<number, LogCachedPage> = new Map<number, LogCachedPage>();
  private collapsed: boolean = false;
  private expanded: Set<string> = new Set<string>();
  private individuallyCollapsed: Set<string> = new Set<string>();
  private live: LiveLogState | undefined = undefined;
  /** 实际累计读取字节用于验证追加通道，没有新字节时不会伪装成重新读取。 */
  liveBytesRead: number = 0;

  totalCount(): number { return this.visible.length; }
  getData(index: number): LogRow { return this.rows[this.visible[index]]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }
  private notify(): void { for (const listener of this.listeners) listener.onDataReloaded(); }

  /** 取消仅终止读取和释放游标；已经显示的原文保持到下一页成功发布。 */
  cancel(): void {
    this.generation++; this.activeCursor?.cancel(); this.discardIdle_();
    this.releaseLive_();
    this.scanKey = ''; this.pageCache.clear();
  }
  private discardIdle_(): void {
    const cursor: EvidenceTextCursor | undefined = this.idleScan?.cursor;
    this.idleScan = undefined;
    if (cursor !== undefined) { cursor.cancel(); cursor.close().catch((): void => {}); }
  }

  /** 折叠只改变可见行，不删掉消息/异常链；事件首行的操作仍能复制完整事件。 */
  setCollapsed(value: boolean): void {
    this.collapsed = value; this.expanded.clear(); this.individuallyCollapsed.clear(); this.applyVisibility_();
  }
  toggleEvent(id: string): void {
    if (this.isEventExpanded(id)) { this.expanded.delete(id); this.individuallyCollapsed.add(id); }
    else { this.individuallyCollapsed.delete(id); this.expanded.add(id); }
    this.applyVisibility_();
  }
  isEventExpanded(id: string): boolean { return this.expanded.has(id) || !this.collapsed && !this.individuallyCollapsed.has(id); }
  /** 横向阅读按本页最长显示块计算宽度；视觉块已限长，不创建无限宽 Text。 */
  maxLineLength(): number { return this.rows.reduce((maximum: number, row: LogRow): number => Math.max(maximum, row.text.length), 0); }
  private applyVisibility_(): void {
    this.visible = [];
    for (const index of this.filtered) {
      const row: LogRow = this.rows[index];
      if (this.isEventExpanded(row.eventId ?? '') || row.eventStart === true
        || (row.event?.format !== 'xml' && (row.event?.lines.length ?? 0) <= 4)) this.visible.push(index);
    }
    this.notify();
  }
  private publishPage_(page: LogCachedPage): void {
    this.rows = page.rows; this.filtered = page.rows.map((row: LogRow, index: number): number => index);
    this.lineCount = page.lineCount; this.matchingLines = page.matchingLines;
    this.matchingEvents = page.matchingEvents; this.hasNextPage = page.hasNext; this.pageStart = page.pageStart;
    this.applyVisibility_();
  }

  /** 显示块只服务排版；搜索先在完整事件判断，再按完整逻辑行计算命中高亮。 */
  private appendEvent_(rows: LogRow[], event: LogEventRecord, source: string, query: string): void {
    const id: string = source + '#' + event.startLine;
    for (const line of event.lines) {
      for (let offset: number = 0; offset < Math.max(1, line.text.length);) {
        let end: number = Math.min(line.text.length, offset + 2048);
        const last: number = line.text.charCodeAt(end - 1);
        if (end < line.text.length && last >= 0xD800 && last <= 0xDBFF) end--;
        const row: LogRow = { key: rows.length, lineNumber: line.number, continuation: offset > 0,
          sourcePath: source, sourceLineNumber: line.number,
          sourceStart: rows.length === 0 || rows[rows.length - 1].sourcePath !== source,
          text: line.text.substring(offset, end), level: event.level,
          event: event, eventId: id, eventStart: line.number === event.startLine && offset === 0,
          matches: matchRanges(line.text, query, offset, end), matchKeyword: query };
        rows.push(row); offset = Math.max(offset + 1, end);
      }
    }
  }

  /**
   * 每次取出一个完整事件。解析器只读取到下一个事件头或 EOF，不将不同文件的续行串接。
   * 普通与 gzip 使用同一个异步游标；下一页保存当前解码器和预读事件，顺序翻页不从头重扫。
   */
  private async nextEvent_(scan: LogScanState, generation: number): Promise<LogEventRecord | undefined> {
    const cursor: EvidenceTextCursor | undefined = scan.cursor;
    if (cursor === undefined) return undefined;
    while (!scan.eof || scan.pending.length > 0) {
      if (generation !== this.generation) return undefined;
      if (scan.pending.indexOf('\n') < 0 && !scan.eof) {
        const chunk = await cursor.read();
        if (generation !== this.generation) return undefined;
        scan.pending += chunk.text; scan.eof = chunk.eof;
        if (scan.pending.length > 8 * 1024 * 1024) throw new Error('单行超过 8 MiB，请导出完整 ZIP 查看');
        if (!scan.eof && scan.pending.indexOf('\n') < 0) continue;
      }
      if (scan.pending.length === 0) break;
      const newline: number = scan.pending.indexOf('\n');
      let line: string = newline >= 0 ? scan.pending.substring(0, newline) : scan.pending;
      scan.pending = newline >= 0 ? scan.pending.substring(newline + 1) : '';
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      scan.lineNumber++; scan.sourceLineNumber++;
      const event: LogEventRecord | undefined = scan.parser.feed(line, scan.sourceLineNumber);
      // 长模组清单也定期让出 UI 线程；取消后不会发布旧结果。
      if (scan.sourceLineNumber % 1024 === 0) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
      if (event !== undefined) return event;
    }
    return scan.parser.finish();
  }

  /**
   * 每页最多 300 个完整事件。skipMatches 使用事件序号；匹配事件的全部续行都保留。
   * 文件身份/筛选变化使缓存失效；短页缓存最多四页，大页不缓存，防止长期持有巨型堆栈。
   */
  async loadEvidence(sources: LogReadSource[], minLevel: number, keyword: string,
    skipMatches: number = 0, fromLine: number = 0): Promise<boolean> {
    this.releaseLive_();
    const generation: number = ++this.generation;
    this.activeCursor?.cancel();
    let key: string;
    try {
      key = JSON.stringify(sources.map((source: LogReadSource): string => source.path + ':' + source.compressed
        + ':' + evidenceFileStamp(source.path))) + ':' + minLevel + ':' + keyword.toLowerCase() + ':' + fromLine;
    } catch (e) { this.discardIdle_(); this.pageCache.clear(); throw (e as Error); }
    if (key !== this.scanKey) { this.discardIdle_(); this.pageCache.clear(); this.scanKey = key; }
    const cached: LogCachedPage | undefined = this.pageCache.get(skipMatches);
    if (cached !== undefined) { this.publishPage_(cached); return true; }
    let scan: LogScanState;
    if (this.idleScan !== undefined && this.idleScan.nextSkip === skipMatches) {
      scan = this.idleScan; this.idleScan = undefined;
    } else { this.discardIdle_(); scan = new LogScanState(); }
    const rows: LogRow[] = [];
    const query: string = keyword.toLowerCase();
    let kept: number = 0; let keptLines: number = 0; let hasNext: boolean = false; let pageChars: number = 0;
    try {
      while (scan.sourceIndex < sources.length) {
        const source: LogReadSource = sources[scan.sourceIndex];
        if (scan.cursor === undefined) {
          scan.cursor = new EvidenceTextCursor(); this.activeCursor = scan.cursor;
          await scan.cursor.open(source.path, source.compressed);
        }
        this.activeCursor = scan.cursor;
        const event: LogEventRecord | undefined = scan.queued ?? await this.nextEvent_(scan, generation);
        scan.queued = undefined;
        if (generation !== this.generation) return false;
        if (event === undefined) {
          await scan.cursor.close(); scan.cursor = undefined; this.activeCursor = undefined;
          scan.sourceIndex++; scan.sourceLineNumber = 0; scan.pending = ''; scan.eof = false;
          scan.parser = new LogEventParser(); continue;
        }
        if (event.endLine < fromLine || !logEventMatches(event, minLevel, query)) continue;
        if (kept >= 300) { scan.queued = event; hasNext = true; break; }
        scan.matched++;
        if (scan.matched <= skipMatches) continue;
        pageChars += event.lines.reduce((sum: number, line: LogEventLine): number => sum + line.text.length, 0);
        if (pageChars > 16 * 1024 * 1024) throw new Error('本页完整事件超过阅读预算，请缩小搜索范围或导出 ZIP');
        kept++; keptLines += event.lines.length;
        this.appendEvent_(rows, event, source.path, query);
      }
      if (generation !== this.generation) return false;
      const page: LogCachedPage = { rows: rows, lineCount: scan.lineNumber, matchingLines: keptLines,
        matchingEvents: kept, hasNext: hasNext, pageStart: skipMatches };
      if (pageChars <= 1024 * 1024) {
        if (this.pageCache.size >= 4) this.pageCache.delete(Array.from(this.pageCache.keys())[0]);
        this.pageCache.set(skipMatches, page);
      }
      this.publishPage_(page);
      if (hasNext) { scan.nextSkip = skipMatches + kept; this.idleScan = scan; }
      return true;
    } catch (e) {
      if (generation !== this.generation) return false;
      throw (e as Error);
    } finally {
      if (this.activeCursor === scan.cursor) this.activeCursor = undefined;
      if (this.idleScan !== scan && scan.cursor !== undefined) await scan.cursor.close();
    }
  }

  /** 活跃读取的 finally 负责关闭，空闲游标可立即异步释放，避免关闭正在使用的 fd。 */
  private releaseLive_(): void {
    const state: LiveLogState | undefined = this.live;
    this.live = undefined;
    if (state === undefined) return;
    state.cursor.cancel();
    if (this.activeCursor !== state.cursor) state.cursor.close().catch((): void => {});
  }

  /**
   * 首次顺序扫描以取得真实行号，后续仅从上次偏移追加。最新窗口最多 300 个事件，
   * 旧事件按总字符预算释放；压缩文件、替换、截短与取消都明确终止，不猜测新来源。
   */
  async loadLive(source: LogReadSource, minLevel: number, keyword: string): Promise<boolean> {
    if (source.compressed) throw new Error('压缩归档不能跟随，请选择正在写入的日志');
    const generation: number = ++this.generation;
    this.discardIdle_(); this.pageCache.clear(); this.scanKey = '';
    if (this.live === undefined || this.live.path !== source.path) {
      this.releaseLive_();
      const next = new LiveLogState(); next.path = source.path; this.live = next;
      this.liveBytesRead = 0; this.activeCursor = next.cursor;
      try { await next.cursor.open(source.path, false, true); }
      catch (e) { this.releaseLive_(); await next.cursor.close(); this.activeCursor = undefined; throw e as Error; }
      if (generation !== this.generation || this.live !== next) {
        await next.cursor.close(); if (this.activeCursor === next.cursor) this.activeCursor = undefined; return false;
      }
    }
    if (this.live === undefined) return false;
    const state: LiveLogState = this.live;
    this.activeCursor = state.cursor;
    try {
      await state.cursor.refreshLive();
      let eof: boolean = false;
      while (!eof) {
        const chunk = await state.cursor.read(); eof = chunk.eof;
        if (generation !== this.generation) return false;
        this.liveBytesRead += chunk.bytesRead; state.pending += chunk.text;
        if (state.pending.length > 8 * 1024 * 1024) throw new Error('追加日志单行过长，请导出 ZIP 查看');
        let newline: number = state.pending.indexOf('\n');
        while (newline >= 0) {
          let line: string = state.pending.substring(0, newline); state.pending = state.pending.substring(newline + 1);
          if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
          const event = state.parser.feed(line, ++state.lineNumber);
          if (event !== undefined) {
            state.events.push(event);
            state.characters += event.lines.reduce((sum: number, item: LogEventLine): number => sum + item.text.length, 0);
            while (state.events.length > 299 || state.events.length > 1 && state.characters > 4 * 1024 * 1024) {
              const removed = state.events.shift();
              if (removed !== undefined) state.characters -= removed.lines.reduce((sum: number, item: LogEventLine): number => sum + item.text.length, 0);
            }
          }
          if (state.lineNumber % 1024 === 0) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
          if (generation !== this.generation) return false;
          newline = state.pending.indexOf('\n');
        }
      }
      const visible: LogEventRecord[] = state.events.slice();
      const current = state.parser.snapshot(state.pending, state.lineNumber + 1);
      if (current !== undefined) visible.push(current);
      const rows: LogRow[] = []; let events: number = 0; let lines: number = 0;
      for (const event of visible) {
        if (!logEventMatches(event, minLevel, keyword)) continue;
        this.appendEvent_(rows, event, source.path, keyword.toLowerCase()); events++; lines += event.lines.length;
      }
      this.publishPage_({ rows: rows, lineCount: state.lineNumber, matchingLines: lines, matchingEvents: events, hasNext: false, pageStart: 0 });
      return true;
    } catch (e) { if (generation !== this.generation) return false; this.releaseLive_(); throw e as Error; }
    finally {
      if (this.activeCursor === state.cursor) this.activeCursor = undefined;
      if (this.live !== state) await state.cursor.close();
    }
  }

  /** 已在内存的脱敏预览也使用同一解析器；大文件生产入口应优先调用流式 loadEvidence。 */
  async setText(text: string): Promise<boolean> {
    this.cancel(); const generation: number = ++this.generation;
    const parser: LogEventParser = new LogEventParser(); const rows: LogRow[] = [];
    let start: number = 0; let lineNumber: number = 0;
    while (start < text.length) {
      let end: number = text.indexOf('\n', start); if (end < 0) end = text.length;
      let line: string = text.substring(start, end); if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      const event: LogEventRecord | undefined = parser.feed(line, ++lineNumber);
      if (event !== undefined) this.appendEvent_(rows, event, '', '');
      start = end + 1;
      if (lineNumber % 1000 === 0) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
        if (generation !== this.generation) return false;
      }
    }
    const tail: LogEventRecord | undefined = parser.finish();
    if (tail !== undefined) this.appendEvent_(rows, tail, '', '');
    if (generation !== this.generation) return false;
    this.rows = rows; this.lineCount = lineNumber; this.filter(0, ''); return true;
  }

  /** 内存预览筛选按事件选择，全逻辑行高亮，绝不把异常链或跨视觉块关键词截断。 */
  filter(minLevel: number, keyword: string): void {
    const query: string = keyword.toLowerCase(); const visible: number[] = [];
    let events: number = 0; let lines: number = 0;
    for (let index: number = 0; index < this.rows.length;) {
      const event: LogEventRecord | undefined = this.rows[index].event;
      const id: string = this.rows[index].eventId ?? '';
      const first: number = index;
      while (index < this.rows.length && this.rows[index].eventId === id) index++;
      if (event === undefined || !logEventMatches(event, minLevel, query)) continue;
      events++; lines += event.lines.length;
      for (let item: number = first; item < index;) {
        const lineNumber: number = this.rows[item].sourceLineNumber ?? 0;
        const logical: string = event.lines.find((line: LogEventLine): boolean => line.number === lineNumber)?.text ?? '';
        let offset: number = 0;
        while (item < index && this.rows[item].sourceLineNumber === lineNumber) {
          const row: LogRow = this.rows[item];
          row.matches = matchRanges(logical, query, offset, offset + row.text.length); row.matchKeyword = query;
          offset += row.text.length; visible.push(item++);
        }
      }
    }
    this.filtered = visible; this.matchingEvents = events; this.matchingLines = lines; this.applyVisibility_();
  }
  firstErrorIndex(): number {
    for (let index: number = 0; index < this.visible.length; index++) if (this.getData(index).level === 2) return index;
    return -1;
  }
}

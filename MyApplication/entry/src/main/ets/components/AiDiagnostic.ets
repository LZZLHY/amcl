/**
 * LogShare 1.8.x 公开回答中的结构化诊断块解析器。
 *
 * 官方 PromptBuilder 要求最终正文末尾使用一个独立的 ```json 代码块，字段为：
 * rootCause（非空字符串）、confidence（0 到 1 的数字）、evidence（字符串数组）
 * 和 steps（字符串数组）。结构化块只是 UI 增强信息，正文 Markdown 始终由调用方
 * 保留；任何不符合契约的内容都返回 undefined，让 UI 安全地回退到 Markdown。
 * thinking、tool 调用和 tool 参数只存在 SSE 状态帧，本文件不会读取或推断它们。
 */

const MAX_BLOCK_LENGTH: number = 64 * 1024;
const MAX_FIELD_LENGTH: number = 4000;
const MAX_ITEMS: number = 8;

/** 供 UI 使用的安全模型；confidence 保留为文本以便统一显示小数。 */
export interface AiStructuredDiagnosis {
  rootCause: string;
  confidence: string;
  troubleshooting: string[];
  evidence: string[];
  caveats: string[];
}

/** 读取一个严格的字符串字段；缺失与非法类型都返回 undefined。 */
function readString(record: Record<string, Object>, key: string, limit: number): string | undefined {
  const raw: Object | undefined = record[key];
  if (typeof raw !== 'string') return undefined;
  const value: string = raw.trim();
  if (value.length === 0 || value.length > limit) return undefined;
  return value;
}

/**
 * 读取字符串数组。数组超出上限或含有对象、数字等非字符串项时整体拒绝，
 * 而不是静默截断或把对象拼成人工描述，避免 UI 展示看似可靠但并非服务端给出的证据。
 * 字段缺失时返回空数组；字段存在但类型错误时返回 undefined。
 */
function readStringList(record: Record<string, Object>, key: string): string[] | undefined {
  const raw: Object | undefined = record[key];
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) return undefined;
  const values: Object[] = raw as Object[];
  if (values.length > MAX_ITEMS) return undefined;
  const result: string[] = [];
  for (const item of values) {
    if (typeof item !== 'string') return undefined;
    const value: string = item.trim();
    if (value.length === 0 || value.length > MAX_FIELD_LENGTH) return undefined;
    result.push(value);
  }
  return result;
}

/** 官方 steps 优先；只在缺失时尝试同义 troubleshooting，不接受任意 cause 别名。 */
function readSteps(record: Record<string, Object>): string[] | undefined {
  const rawSteps: Object | undefined = record['steps'];
  if (rawSteps === undefined) return readStringList(record, 'troubleshooting');
  // 如果官方字段存在但格式错误，不能被非官方别名掩盖。
  return readStringList(record, 'steps');
}

/** 解析已取出的 JSON 文本；rootCause 只接受官方的非空字符串类型。 */
function readDiagnosisObject(candidate: string): AiStructuredDiagnosis | undefined {
  if (candidate.trim().length === 0 || candidate.length > MAX_BLOCK_LENGTH) return undefined;
  try {
    const value: Record<string, Object> = JSON.parse(candidate) as Record<string, Object>;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;

    const rootCause: string | undefined = readString(value, 'rootCause', MAX_FIELD_LENGTH);
    if (rootCause === undefined) return undefined;

    // 官方字段是 number；字符串、布尔值和对象都拒绝，避免把模型自由文本伪装成分数。
    const rawConfidence: Object | undefined = value['confidence'];
    let confidence: string = '';
    if (rawConfidence !== undefined) {
      if (typeof rawConfidence !== 'number' || !Number.isFinite(rawConfidence)
        || rawConfidence < 0 || rawConfidence > 1) return undefined;
      confidence = rawConfidence.toString();
    }

    const evidence: string[] | undefined = readStringList(value, 'evidence');
    if (evidence === undefined) return undefined;
    const steps: string[] | undefined = readSteps(value);
    if (steps === undefined) return undefined;

    // caveats 是可选补充，只在服务端明确给出字符串数组时展示。
    const caveats: string[] | undefined = readStringList(value, 'caveats');
    if (caveats === undefined) return undefined;
    return { rootCause: rootCause, confidence: confidence, troubleshooting: steps,
      evidence: evidence, caveats: caveats };
  } catch (e) {
    // JSON 截断、语法异常或未知响应格式都回退到原 Markdown。
    return undefined;
  }
}

/** 返回一行的边界，统一处理 LF 与 CRLF；末尾没有换行时也能识别代码围栏。 */
function lineEnd(source: string, start: number): number {
  const end: number = source.indexOf('\n', start);
  return end < 0 ? source.length : end;
}

/**
 * 扫描完整回答的 fenced code block，支持反引号/波浪线与更长围栏。
 * 非 JSON 围栏必须消费到同种且足够长的闭合行；缩进代码/内联围栏不提升为卡片。
 * 取最后一个合法 JSON 诊断，避免前文示例覆盖末尾结论；原 Markdown 不被改写。
 */
export function parseAiStructuredDiagnosis(markdown: string): AiStructuredDiagnosis | undefined {
  let start: number = 0;
  let fence: string = '';
  let fenceLength: number = 0;
  let contentStart: number = 0;
  let json: boolean = false;
  let result: AiStructuredDiagnosis | undefined = undefined;
  const opening = new RegExp('^ {0,3}(`{3,}|~{3,})(.*)$');
  const closing = new RegExp('^ {0,3}(`{3,}|~{3,})[ \t]*$');
  while (start < markdown.length) {
    const end: number = lineEnd(markdown, start);
    const line: string = markdown.substring(start, end).replace(new RegExp('\\r$'), '');
    if (fence.length === 0) {
      const match = opening.exec(line);
      if (match !== null) {
        const marker: string = match[1];
        const info: string = match[2].trim();
        // CommonMark 的反引号开围栏信息串不能再含反引号。
        if (marker.charAt(0) !== '`' || info.indexOf('`') < 0) {
          fence = marker.charAt(0); fenceLength = marker.length;
          json = info.toLowerCase() === 'json'; contentStart = end + 1;
        }
      }
    } else {
      const match = closing.exec(line);
      if (match !== null && match[1].charAt(0) === fence && match[1].length >= fenceLength) {
        if (json && start - contentStart <= MAX_BLOCK_LENGTH) {
          const parsed = readDiagnosisObject(markdown.substring(contentStart, start));
          if (parsed !== undefined) result = parsed;
        }
        fence = ''; json = false;
      }
    }
    start = end + 1;
  }
  return result;
}

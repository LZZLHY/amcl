/**
 * Redact.ets — 日志脱敏工具
 *
 * 在把第三方 API 响应体（OAuth / Xbox / Mojang 错误响应等）写入 hilog 或
 * amcl_log 前，强制过一遍 redactToken()，识别常见 token 形式（JWT、OAuth
 * access_token、Bearer header、长 base64）并打码，**只保留前后各 6 字符 +
 * 长度提示**，便于调试时还能粗略匹配但不能反推原值。
 *
 * 设计原则：
 *   - **深度防御**：当前 OAuth/XBL/Mojang 错误体里不会含 token（实测确认），
 *     但上游协议可能变化、本地代理工具可能把成功 body 串到错误路径。一旦泄漏
 *     到 hilog，OHOS 默认权限下任意应用可读取。所以这是"未来万一"的兜底。
 *   - **零误改业务字符串**：普通错误消息（"network unreachable" 之类）保持
 *     不变。
 *   - **零外部依赖**：使用字符串扫描与明确上下文的正则，不引第三方 npm。
 *
 * 创建日期：2026-05-10（LOG-P0-2）
 * 关联：docs/guides/logging-system-review-and-plan.md 问题 5
 */

/**
 * 常见 token 模式（按特异性从高到低排序）：
 * 1. JWT：eyJ<base64>.<base64>.<base64> 三段，OAuth id_token 标准
 * 2. OAuth JSON 字段：明确写 access_token / refresh_token / id_token 的 JSON
 * 3. Bearer header：Authorization: Bearer <opaque>
 * 4. 长不透明 base64：≥40 字符的 base64-like，可能是 Xbox token / 加密负载
 *
 * 注意第 4 条**最容易误伤合法 URL**（CDN URL 里 hash + path 也可能 ≥40
 * 字符且字符集匹配）。所以我们：
 *   - 只识别**纯**的连续 base64 字符（不允许 / 或 .，避免吃整段 URL 路径）
 *   - 长度阈值卡到 40，留点容忍空间
 */
const JWT_PATTERN = /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g;
const OAUTH_JSON_PATTERN = /"(access_token|refresh_token|id_token|Token)"\s*:\s*"[^"]{8,}"/g;
const BEARER_PATTERN = new RegExp("[Bb]earer\\s+[^\\s\"'<>,;}]+", 'g');
const BASIC_PATTERN = new RegExp("([Aa]uthorization:\\s*[Bb]asic\\s+)([^\\s\"'<>,;}]+)", 'g');
const CONTEXT_SECRET_PATTERN = new RegExp('("?(?:password|passwd|access_token|refresh_token|id_token|client_secret|token|authorization)"?\\s*[:=]\\s*)(?:"([^"\\r\\n]*)"|\'([^\'\\r\\n]*)\'|([^\\s,;}]+))', 'gi');

/**
 * 把 token-like 子串替换成 `<前6字符>***[<总长>chars]***<后6字符>`。
 * 短于 16 字符的整体替换为 `***REDACTED***`。
 */
function isMaskedToken(value: string): boolean {
  return value === '***REDACTED***'
    || new RegExp('^[\\s\\S]{6}\\*\\*\\*\\[[0-9]+chars\\]\\*\\*\\*[\\s\\S]{6}$').test(value);
}
function maskToken(match: string): string {
  if (isMaskedToken(match)) return match;
  if (match.length <= 16) return '***REDACTED***';
  let head = match.substring(0, 6);
  let tail = match.substring(match.length - 6);
  return `${head}***[${match.length}chars]***${tail}`;
}

/**
 * 判断一个 UTF-16 码元是否属于长 token 兜底规则的 ASCII 字符集。
 * 不接受斜杠、点、空白或非 ASCII 字符，保持原规则的 URL/行边界；
 * 等号只作为末尾至多两个 padding 字符处理，不属于 token 主体。
 */
function isOpaqueTokenCode(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
    || (code >= 97 && code <= 122) || code === 95 || code === 43 || code === 45;
}

/** 判断技术摘要允许的十六进制字符；只用于无上下文的兜底豁免。 */
function isHexTokenCode(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 70)
    || (code >= 97 && code <= 102);
}

/**
 * 线性处理长度至少 40 的连续不透明 token，语义与原长 base64 规则一致。
 *
 * 大日志可能包含数 MiB 的单个连续字段。对这样的字段使用无界重复正则，
 * 会在部分 JS 引擎中耗尽匹配栈，阻断整个预览、导出或上传。这里逐码元推进，
 * 每个输入位置至多消费一次，不递归、不回溯，也不截断或跳过未检查正文。
 *
 * 纯十六进制串保留，用于 SHA 等排障摘要；有 password/token 等明确上下文的
 * 凭据已由前面的专用规则处理，因此不会利用该豁免恢复已脱敏凭据。
 * 仅在真正替换时收集片段，全部未命中时直接返回原字符串，避免按字符建数组。
 */
function redactOpaqueTokenRuns(text: string): string {
  const parts: string[] = [];
  let cursor: number = 0;
  let copiedThrough: number = 0;
  while (cursor < text.length) {
    if (!isOpaqueTokenCode(text.charCodeAt(cursor))) {
      cursor++;
      continue;
    }
    const start: number = cursor;
    let onlyHex: boolean = true;
    while (cursor < text.length && isOpaqueTokenCode(text.charCodeAt(cursor))) {
      if (!isHexTokenCode(text.charCodeAt(cursor))) onlyHex = false;
      cursor++;
    }
    if (cursor - start < 40) continue;

    const bodyEnd: number = cursor;
    // padding 属于匹配内容，但不计入 40 字符的主体门槛；第三个等号保留在正文中。
    while (cursor < text.length && cursor - bodyEnd < 2 && text.charCodeAt(cursor) === 61) cursor++;
    if (onlyHex && cursor === bodyEnd) continue;

    parts.push(text.substring(copiedThrough, start));
    parts.push(maskToken(text.substring(start, cursor)));
    copiedThrough = cursor;
  }
  if (parts.length === 0) return text;
  parts.push(text.substring(copiedThrough));
  return parts.join('');
}

/**
 * OAuth JSON 字段单独处理：保留字段名，只 mask value。
 * 输入形如 `"access_token":"eyJhbGc..."`，输出 `"access_token":"eyJhbG***[N]***xxx"`。
 */
function maskOAuthJsonField(match: string): string {
  // 匹配 `"key":"value"`，提取 key 和 value
  let m = match.match(/^"([^"]+)"\s*:\s*"([^"]+)"$/);
  if (!m) return '***REDACTED***';
  let key = m[1];
  let value = m[2];
  return `"${key}":"${maskToken(value)}"`;
}

/**
 * 主入口：识别 s 中的 token-like 子串并打码。
 * 不修改输入，返回新字符串。空串 / null / undefined 直接返回。
 *
 * 使用：
 *   let preview = redactToken(resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body);
 *   hilog.warn(0x0000, TAG, 'OAuth failed: %{public}s', preview);
 */
export function redactToken(s: string | null | undefined): string {
  if (s === null || s === undefined) return '';
  if (s.length === 0) return s;

  let result = s;
  // 顺序敏感：先处理 JWT（最特异），再 OAuth JSON 字段，再 Bearer header，
  // 最后 long base64 兜底。这样 JWT 不会被 long-base64 拆碎。
  result = result.replace(JWT_PATTERN, maskToken);
  result = result.replace(OAUTH_JSON_PATTERN, maskOAuthJsonField);
  result = result.replace(BEARER_PATTERN, (match: string) => {
    // 保留 "Bearer " 前缀，只 mask token 部分
    let idx = match.search(/\s/);
    if (idx < 0) return maskToken(match);
    let prefix = match.substring(0, idx);
    let token = match.substring(idx).trim();
    return `${prefix} ${maskToken(token)}`;
  });
  result = result.replace(BASIC_PATTERN, (match: string, prefix: string, value: string): string => prefix + maskToken(value));
  result = result.replace(CONTEXT_SECRET_PATTERN, (match: string, prefix: string,
    doubleQuoted: string, singleQuoted: string, plain: string): string => {
    const value: string = doubleQuoted ?? singleQuoted ?? plain ?? '';
    // 已脱敏值保持幂等；认证方案名与其凭据由专用规则分别处理。
    if (isMaskedToken(value) || value.toLowerCase() === 'bearer' || value.toLowerCase() === 'basic') return match;
    const schemeEnd: number = value.indexOf(' ');
    if (schemeEnd > 0 && new RegExp('^(Bearer|Basic) ', 'i').test(value)
      && isMaskedToken(value.substring(schemeEnd + 1))) return match;
    const quote: string = doubleQuoted !== undefined ? '"' : singleQuoted !== undefined ? "'" : '';
    return prefix + quote + maskToken(value) + quote;
  });
  result = redactOpaqueTokenRuns(result);
  return result;
}

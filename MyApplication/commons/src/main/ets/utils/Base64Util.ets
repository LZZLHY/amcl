/**
 * Base64Util.ets — 纯 JS Base64 编解码（标准 / URL-safe 无 padding）
 *
 * 选择"纯 JS"实现而非 `util.Base64Helper`：
 *   - hvigorw test (Node v8) 环境下 `util.Base64Helper` 行为不稳，曾出现空串
 *   - 生产环境性能差异可忽略（账户字段通常 < 1KB）
 *
 * RFC 4648 标准 + RFC 7515 base64url（无 padding）。
 *
 * 创建日期：2026-05-09（M2 Phase B：抽出共享）
 */

const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 反查表（一次性构建）。索引为字符 charCode，值为 6-bit 数字；非法字符为 -1。 */
const B64_REVERSE: Int8Array = (() => {
  let arr = new Int8Array(128);
  for (let i = 0; i < 128; i++) arr[i] = -1;
  for (let i = 0; i < B64_ALPHABET.length; i++) {
    arr[B64_ALPHABET.charCodeAt(i)] = i;
  }
  return arr;
})();

// ============================================================
//  标准 base64
// ============================================================

/** 字节数组 → 标准 base64 字符串（含 = padding）。 */
export function encodeStandardBase64(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  let n = bytes.length;
  while (i + 3 <= n) {
    let b0 = bytes[i];
    let b1 = bytes[i + 1];
    let b2 = bytes[i + 2];
    out += B64_ALPHABET.charAt(b0 >> 2);
    out += B64_ALPHABET.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += B64_ALPHABET.charAt(((b1 & 0x0f) << 2) | (b2 >> 6));
    out += B64_ALPHABET.charAt(b2 & 0x3f);
    i += 3;
  }
  if (i < n) {
    let b0 = bytes[i];
    if (i + 1 === n) {
      out += B64_ALPHABET.charAt(b0 >> 2);
      out += B64_ALPHABET.charAt((b0 & 0x03) << 4);
      out += '==';
    } else {
      let b1 = bytes[i + 1];
      out += B64_ALPHABET.charAt(b0 >> 2);
      out += B64_ALPHABET.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
      out += B64_ALPHABET.charAt((b1 & 0x0f) << 2);
      out += '=';
    }
  }
  return out;
}

/** 标准 base64 字符串 → 字节数组。容错：跳过非法字符；padding 可省。 */
export function decodeStandardBase64(s: string): Uint8Array {
  // 先剥 padding 和非法字符（也容错 base64url）
  let clean: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c === 0x3D /* '=' */) break;
    if (c === 0x2D /* '-' */) c = 0x2B; // base64url '-' → '+'
    else if (c === 0x5F /* '_' */) c = 0x2F; // base64url '_' → '/'
    let v = c < 128 ? B64_REVERSE[c] : -1;
    if (v < 0) continue;  // 容错：跳过空白等
    clean.push(v);
  }
  // 每 4 个 6-bit char 解码 3 字节
  let outLen = (clean.length * 6) >> 3;
  let out = new Uint8Array(outLen);
  let oi = 0;
  let i = 0;
  while (i + 4 <= clean.length) {
    let v0 = clean[i];
    let v1 = clean[i + 1];
    let v2 = clean[i + 2];
    let v3 = clean[i + 3];
    out[oi++] = (v0 << 2) | (v1 >> 4);
    out[oi++] = ((v1 & 0x0f) << 4) | (v2 >> 2);
    out[oi++] = ((v2 & 0x03) << 6) | v3;
    i += 4;
  }
  // 尾部 2-3 个剩余字符
  let rem = clean.length - i;
  if (rem === 2) {
    let v0 = clean[i];
    let v1 = clean[i + 1];
    out[oi++] = (v0 << 2) | (v1 >> 4);
  } else if (rem === 3) {
    let v0 = clean[i];
    let v1 = clean[i + 1];
    let v2 = clean[i + 2];
    out[oi++] = (v0 << 2) | (v1 >> 4);
    out[oi++] = ((v1 & 0x0f) << 4) | (v2 >> 2);
  }
  // 修正 outLen（如果有 padding 导致 oi < outLen）
  if (oi < outLen) {
    return out.subarray(0, oi);
  }
  return out;
}

// ============================================================
//  RFC 7515 base64url（无 padding）
// ============================================================

/** 字节数组 → base64url 无 padding（PKCE / JWS 常用）。 */
export function base64UrlNoPad(bytes: Uint8Array): string {
  let b64 = encodeStandardBase64(bytes);
  // ArkTS strict 不允许链式 replace 调用 RegExp，用循环替换
  let out = '';
  for (let i = 0; i < b64.length; i++) {
    let c = b64.charAt(i);
    if (c === '=') continue;
    if (c === '+') out += '-';
    else if (c === '/') out += '_';
    else out += c;
  }
  return out;
}

// ============================================================
//  UTF-8 字符串 ↔ 字节数组（不依赖 util.TextEncoder/Decoder）
// ============================================================

/** UTF-8 字符串 → 字节数组（手写编码，绕开 util.* 在 CLI 测试下的兼容问题）。 */
export function stringToUtf8(s: string): Uint8Array {
  // 估上界：每个 code point 最多 4 字节
  let buf = new Uint8Array(s.length * 4);
  let p = 0;
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    // 处理代理对（UTF-16 → UTF-32 code point）
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      let c2 = s.charCodeAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        i++;
      }
    }
    if (c < 0x80) {
      buf[p++] = c;
    } else if (c < 0x800) {
      buf[p++] = 0xC0 | (c >> 6);
      buf[p++] = 0x80 | (c & 0x3F);
    } else if (c < 0x10000) {
      buf[p++] = 0xE0 | (c >> 12);
      buf[p++] = 0x80 | ((c >> 6) & 0x3F);
      buf[p++] = 0x80 | (c & 0x3F);
    } else {
      buf[p++] = 0xF0 | (c >> 18);
      buf[p++] = 0x80 | ((c >> 12) & 0x3F);
      buf[p++] = 0x80 | ((c >> 6) & 0x3F);
      buf[p++] = 0x80 | (c & 0x3F);
    }
  }
  return buf.subarray(0, p);
}

/** 字节数组 (UTF-8 编码) → 字符串。容错：非法字节按 U+FFFD 替换符。 */
export function utf8ToString(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  let n = bytes.length;
  while (i < n) {
    let b = bytes[i++];
    let cp: number;
    if (b < 0x80) {
      cp = b;
    } else if ((b & 0xE0) === 0xC0 && i < n) {
      cp = ((b & 0x1F) << 6) | (bytes[i++] & 0x3F);
    } else if ((b & 0xF0) === 0xE0 && i + 1 < n) {
      cp = ((b & 0x0F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
    } else if ((b & 0xF8) === 0xF0 && i + 2 < n) {
      cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3F) << 12)
        | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
    } else {
      cp = 0xFFFD;  // 非法字节
    }
    if (cp < 0x10000) {
      out += String.fromCharCode(cp);
    } else {
      // BMP 外 → 代理对
      let v = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (v >> 10));
      out += String.fromCharCode(0xDC00 + (v & 0x3FF));
    }
  }
  return out;
}

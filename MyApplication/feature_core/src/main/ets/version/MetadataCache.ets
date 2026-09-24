/**
 * MetadataCache.ets — Phase 2 (ETag/条件请求缓存)
 *
 * 目标：把 version_manifest_v2.json / asset_index.json / Forge file_list.json
 *      等元数据走 If-None-Match / If-Modified-Since，命中 304 直接返回本地缓存。
 *
 * 当前状态（Phase 2.2 + 2.3 已完成，纯函数库）：
 *   - urlHash / parseConditionalHeaders / buildConditionalRequest /
 *     isCacheValid / serializeMeta / deserializeMeta 全部为真实实现
 *   - 上游持久化层 MetadataCacheStore 调用这些纯函数完成 304 短路 + TTL 过期
 *
 * 测试：entry/src/test/MetadataCache.test.ets
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 2
 *
 * 创建日期：2026-05-05
 */

// ============================================================
//  公开 interface
// ============================================================

/**
 * 缓存元数据：每条响应附带的 HTTP 缓存控制字段 + 时间戳。
 * 持久化到 filesDir/metadata-cache/<urlHash>.meta（JSON 序列化）。
 */
export interface CacheMeta {
  /** 原始 URL（也用于反查 / 调试） */
  url: string;
  /** ETag 头原值（含引号 / 弱标识 W/ 前缀） */
  etag?: string;
  /** Last-Modified 头原值（HTTP 格式日期串） */
  lastModified?: string;
  /** 客户端写入缓存的时间戳（Date.now() 毫秒） */
  fetchedAt: number;
  /** Content-Type，可选；展示用 */
  contentType?: string;
}

// ============================================================
//  内部工具
// ============================================================

/**
 * FNV-1a 64-bit hash（非加密，仅用于文件名稳定性）。
 * 选 FNV 而非 SHA-256：ArkTS cryptoFramework 是 Promise，纯函数 urlHash 必须同步。
 * 16 位 hex（64 位）碰撞概率对 ~1000 个缓存条目可忽略。
 */
function fnv1a64Hex(input: string): string {
  // FNV-1a 64-bit constants
  let hashHi = 0xcbf29ce4;  // high 32 bits of offset basis
  let hashLo = 0x84222325;  // low 32 bits of offset basis
  // prime = 0x100000001b3
  // 我们用 (hi, lo) 模拟 64-bit 乘法

  for (let i = 0; i < input.length; i++) {
    let c = input.charCodeAt(i);
    // XOR with byte (low 32 bits only, FNV spec)
    hashLo = (hashLo ^ c) >>> 0;

    // multiply by 0x100000001b3 = 0x01_00000001b3
    // = (1 << 40) + 0x1b3
    // 64-bit multiply: (hashHi << 32 | hashLo) * (0x01 << 32 + 0x000001b3)
    // 简化：拆解为 hashLo * 0x000001b3 + hashLo * (1 << 40) + hashHi * 0x000001b3 << 32
    let prime = 0x000001b3;
    // newHashLo = hashLo * prime  (lower 32 bits)
    let mulLo = Math.imul(hashLo & 0xffff, prime) >>> 0;
    let mulMidHi = (Math.imul((hashLo >>> 16), prime) >>> 0);
    let newLo = (mulLo + ((mulMidHi & 0xffff) << 16)) >>> 0;
    let newHi = ((mulMidHi >>> 16) + Math.imul(hashHi, prime)) >>> 0;
    // add hashLo << 8 to high (since prime offset bit is at 40 → (1<<40) means hi += hashLo << 8)
    newHi = (newHi + ((hashLo << 8) >>> 0)) >>> 0;
    // also the carry from hashLo * (1 << 40)'s low part: equivalent to (hashLo >> 24) into high
    newHi = (newHi + (hashLo >>> 24)) >>> 0;

    hashHi = newHi;
    hashLo = newLo;
  }

  // 转 16 位 hex（高 32 位 + 低 32 位）
  let hi = ('00000000' + hashHi.toString(16)).slice(-8);
  let lo = ('00000000' + hashLo.toString(16)).slice(-8);
  return hi + lo;
}

/** 大小写不敏感地查 headers，返回首个匹配值 */
function headerLookup(headers: Record<string, string>, name: string): string | undefined {
  let target = name.toLowerCase();
  for (let key of Object.keys(headers)) {
    if (key.toLowerCase() === target) return headers[key];
  }
  return undefined;
}

// ============================================================
//  公开纯函数
// ============================================================

/**
 * URL → 16 位 hex 文件名 hash（确定性，同 URL 同 hash）。
 * 用 FNV-1a 64-bit；非加密，但对"区分 URL 选缓存文件"用途足够。
 */
export function urlHash(url: string): string {
  return fnv1a64Hex(url);
}

/**
 * 解析 HTTP 响应头：提取 ETag / Last-Modified / Content-Type。
 * 头名大小写不敏感。E-Tag（带连字符）非标准，本函数不识别。
 */
export function parseConditionalHeaders(headers: Record<string, string>): Partial<CacheMeta> {
  let r: Partial<CacheMeta> = {};
  let etag = headerLookup(headers, 'ETag');
  if (etag !== undefined) r.etag = etag;
  let lm = headerLookup(headers, 'Last-Modified');
  if (lm !== undefined) r.lastModified = lm;
  let ct = headerLookup(headers, 'Content-Type');
  if (ct !== undefined) r.contentType = ct;
  return r;
}

/**
 * 已有 meta 时构造条件请求头：
 *   - 有 etag → 'If-None-Match'
 *   - 有 lastModified → 'If-Modified-Since'
 */
export function buildConditionalRequest(meta: CacheMeta): Record<string, string> {
  let r: Record<string, string> = {};
  if (meta.etag !== undefined && meta.etag.length > 0) {
    r['If-None-Match'] = meta.etag;
  }
  if (meta.lastModified !== undefined && meta.lastModified.length > 0) {
    r['If-Modified-Since'] = meta.lastModified;
  }
  return r;
}

/**
 * 缓存是否仍在有效期内。
 *   - maxAgeMs === -1 → 永不过期（约定）
 *   - now < fetchedAt（时钟回拨）→ 保守失效
 *   - now - fetchedAt < maxAgeMs → 严格小于视为有效
 */
export function isCacheValid(meta: CacheMeta, maxAgeMs: number, now: number): boolean {
  if (maxAgeMs === -1) return true;       // 永不过期约定
  if (maxAgeMs <= 0) return false;        // 0 / 负值视为永远过期
  if (now < meta.fetchedAt) return false; // 时钟回拨保守失效
  let age = now - meta.fetchedAt;
  return age < maxAgeMs;
}

/** 序列化为 JSON 字符串（写入 .meta 文件）。 */
export function serializeMeta(meta: CacheMeta): string {
  return JSON.stringify(meta);
}

/**
 * 反序列化。损坏 JSON / 缺关键字段（url 或 fetchedAt）时返回 null。
 * 多余字段被忽略。
 */
export function deserializeMeta(json: string): CacheMeta | null {
  if (json.length === 0) return null;
  let obj: Record<string, Object> | null = null;
  try {
    let parsed = JSON.parse(json) as Object;
    if (typeof parsed !== 'object' || parsed === null) return null;
    obj = parsed as Record<string, Object>;
  } catch (e) {
    return null;
  }

  let url = obj['url'];
  let fetchedAt = obj['fetchedAt'];
  if (typeof url !== 'string' || typeof fetchedAt !== 'number') return null;

  let result: CacheMeta = {
    url: url as string,
    fetchedAt: fetchedAt as number,
  };

  let etag = obj['etag'];
  if (typeof etag === 'string') result.etag = etag as string;
  let lm = obj['lastModified'];
  if (typeof lm === 'string') result.lastModified = lm as string;
  let ct = obj['contentType'];
  if (typeof ct === 'string') result.contentType = ct as string;

  return result;
}

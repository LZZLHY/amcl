/*
 * MetadataCache.test.ets — Phase 2 (ETag 缓存) 纯函数单元测试
 *
 * TDD 红阶段：本文件先于 MetadataCache.ets 创建。
 * 当前预期：编译失败（Cannot find module 'feature_core'）。
 *
 * 覆盖范围（仅纯函数，不涉及文件 I/O 或网络）：
 *   - urlHash(url)                            URL → 16 位 hex 文件名
 *   - parseConditionalHeaders(headers)        响应头 → CacheMeta 字段
 *   - buildConditionalRequest(meta)           CacheMeta → request headers
 *   - isCacheValid(meta, maxAgeMs, now)       过期判定（注入 now 便于测试）
 *   - serializeMeta(meta) / deserializeMeta   JSON 往返
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 2
 *
 * 创建日期：2026-05-05
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  urlHash,
  parseConditionalHeaders,
  buildConditionalRequest,
  isCacheValid,
  serializeMeta,
  deserializeMeta,
  CacheMeta,
} from 'feature_core';

export default function metadataCacheTest() {

  // ============================================================
  //  urlHash
  // ============================================================
  describe('MetadataCache.urlHash', () => {

    it('相同 URL 哈希结果稳定一致', 0, () => {
      let h1 = urlHash('https://piston-meta.mojang.com/mc/game/version_manifest_v2.json');
      let h2 = urlHash('https://piston-meta.mojang.com/mc/game/version_manifest_v2.json');
      expect(h1).assertEqual(h2);
    });

    it('不同 URL 哈希不同', 0, () => {
      let h1 = urlHash('https://example.com/a');
      let h2 = urlHash('https://example.com/b');
      expect(h1 === h2).assertFalse();
    });

    it('哈希长度固定 16（hex）', 0, () => {
      let h = urlHash('https://example.com/some/path');
      expect(h.length).assertEqual(16);
    });

    it('哈希仅含 hex 字符', 0, () => {
      let h = urlHash('https://example.com/test');
      let isHex = /^[0-9a-f]+$/.test(h);
      expect(isHex).assertTrue();
    });

    it('空字符串也能产生有效哈希', 0, () => {
      let h = urlHash('');
      expect(h.length).assertEqual(16);
    });

    it('查询字符串影响哈希', 0, () => {
      let h1 = urlHash('https://example.com/a?v=1');
      let h2 = urlHash('https://example.com/a?v=2');
      expect(h1 === h2).assertFalse();
    });
  });

  // ============================================================
  //  parseConditionalHeaders
  // ============================================================
  describe('MetadataCache.parseConditionalHeaders', () => {

    it('提取 ETag', 0, () => {
      let headers: Record<string, string> = {
        'etag': '"abc123"',
        'content-type': 'application/json',
      };
      let parsed = parseConditionalHeaders(headers);
      expect(parsed.etag).assertEqual('"abc123"');
    });

    it('大小写不敏感（ETag / etag / E-Tag）', 0, () => {
      let h1: Record<string, string> = { 'ETag': '"x"' };
      let h2: Record<string, string> = { 'etag': '"x"' };
      let h3: Record<string, string> = { 'E-Tag': '"x"' };
      expect(parseConditionalHeaders(h1).etag).assertEqual('"x"');
      expect(parseConditionalHeaders(h2).etag).assertEqual('"x"');
      // E-Tag 形式（带连字符）：已不规范，不要求支持，只确认 ETag/etag 两种常见形式即可
    });

    it('提取 Last-Modified', 0, () => {
      let headers: Record<string, string> = {
        'last-modified': 'Wed, 21 Oct 2026 07:28:00 GMT',
      };
      let parsed = parseConditionalHeaders(headers);
      expect(parsed.lastModified).assertEqual('Wed, 21 Oct 2026 07:28:00 GMT');
    });

    it('提取 Content-Type', 0, () => {
      let headers: Record<string, string> = {
        'content-type': 'application/json; charset=utf-8',
      };
      let parsed = parseConditionalHeaders(headers);
      expect(parsed.contentType).assertEqual('application/json; charset=utf-8');
    });

    it('缺少所有头时返回空 partial', 0, () => {
      let parsed = parseConditionalHeaders({});
      expect(parsed.etag === undefined).assertTrue();
      expect(parsed.lastModified === undefined).assertTrue();
      expect(parsed.contentType === undefined).assertTrue();
    });

    it('Weak ETag 保留原样（W/"xxx"）', 0, () => {
      let headers: Record<string, string> = {
        'etag': 'W/"abc123"',
      };
      let parsed = parseConditionalHeaders(headers);
      expect(parsed.etag).assertEqual('W/"abc123"');
    });
  });

  // ============================================================
  //  buildConditionalRequest
  // ============================================================
  describe('MetadataCache.buildConditionalRequest', () => {

    it('有 ETag 时填 If-None-Match', 0, () => {
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        etag: '"abc"',
        fetchedAt: Date.now(),
      };
      let headers = buildConditionalRequest(meta);
      expect(headers['If-None-Match']).assertEqual('"abc"');
    });

    it('有 Last-Modified 时填 If-Modified-Since', 0, () => {
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
        fetchedAt: Date.now(),
      };
      let headers = buildConditionalRequest(meta);
      expect(headers['If-Modified-Since']).assertEqual('Wed, 21 Oct 2026 07:28:00 GMT');
    });

    it('两者都有时同时填', 0, () => {
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        etag: '"abc"',
        lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
        fetchedAt: Date.now(),
      };
      let headers = buildConditionalRequest(meta);
      expect(headers['If-None-Match']).assertEqual('"abc"');
      expect(headers['If-Modified-Since']).assertEqual('Wed, 21 Oct 2026 07:28:00 GMT');
    });

    it('两者都无时返回空对象', 0, () => {
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: Date.now(),
      };
      let headers = buildConditionalRequest(meta);
      expect(Object.keys(headers).length).assertEqual(0);
    });
  });

  // ============================================================
  //  isCacheValid
  // ============================================================
  describe('MetadataCache.isCacheValid', () => {

    it('未过期 → true', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now - 1000,  // 1s 前
      };
      expect(isCacheValid(meta, 60000, now)).assertTrue();  // 1分钟内
    });

    it('已过期 → false', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now - 70000,  // 70s 前
      };
      expect(isCacheValid(meta, 60000, now)).assertFalse();  // 1分钟外
    });

    it('刚好等于 maxAgeMs → false（严格小于）', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now - 60000,  // 恰好 60s 前
      };
      expect(isCacheValid(meta, 60000, now)).assertFalse();
    });

    it('fetchedAt 在未来（时钟回拨）→ false（保守失效）', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now + 10000,
      };
      expect(isCacheValid(meta, 60000, now)).assertFalse();
    });

    it('maxAgeMs = 0 → 永远过期', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now,
      };
      expect(isCacheValid(meta, 0, now)).assertFalse();
    });

    it('maxAgeMs = -1 → 永不过期（约定）', 0, () => {
      let now = 1_700_000_000_000;
      let meta: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: now - 365 * 24 * 3600 * 1000,  // 一年前
      };
      expect(isCacheValid(meta, -1, now)).assertTrue();
    });
  });

  // ============================================================
  //  serializeMeta / deserializeMeta
  // ============================================================
  describe('MetadataCache serialize/deserialize', () => {

    it('完整 meta 往返一致', 0, () => {
      let original: CacheMeta = {
        url: 'https://example.com/x',
        etag: '"abc"',
        lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
        fetchedAt: 1_700_000_000_000,
        contentType: 'application/json',
      };
      let json = serializeMeta(original);
      let restored = deserializeMeta(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.url).assertEqual(original.url);
        expect(restored.etag).assertEqual(original.etag);
        expect(restored.lastModified).assertEqual(original.lastModified);
        expect(restored.fetchedAt).assertEqual(original.fetchedAt);
        expect(restored.contentType).assertEqual(original.contentType);
      }
    });

    it('最小 meta 往返一致', 0, () => {
      let original: CacheMeta = {
        url: 'https://example.com/x',
        fetchedAt: 1_700_000_000_000,
      };
      let json = serializeMeta(original);
      let restored = deserializeMeta(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.url).assertEqual(original.url);
        expect(restored.fetchedAt).assertEqual(original.fetchedAt);
        expect(restored.etag === undefined).assertTrue();
      }
    });

    it('损坏的 JSON 返回 null', 0, () => {
      expect(deserializeMeta('not-json') === null).assertTrue();
      expect(deserializeMeta('') === null).assertTrue();
      expect(deserializeMeta('{invalid}') === null).assertTrue();
    });

    it('缺少必填字段返回 null', 0, () => {
      // 缺 url
      expect(deserializeMeta('{"fetchedAt":123}') === null).assertTrue();
      // 缺 fetchedAt
      expect(deserializeMeta('{"url":"x"}') === null).assertTrue();
    });

    it('额外字段被忽略', 0, () => {
      let json = '{"url":"x","fetchedAt":123,"unknownField":"ignore me"}';
      let restored = deserializeMeta(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.url).assertEqual('x');
        expect(restored.fetchedAt).assertEqual(123);
      }
    });
  });
}

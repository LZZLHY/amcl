import { DiagnosticPolicy } from 'commons';
﻿/**
 * MetadataCacheStore.ets — Phase 2.3 (P2-2)
 *
 * 持久化元数据缓存（version_manifest / version.json / asset_index / Forge file_list 等）。
 * 落地格式：`<filesDir>/metadata-cache/<urlHash>.meta` + `.body`
 *   - `.meta`：CacheMeta 序列化 JSON（包括 url / fetchedAt / 可选 etag/lastModified/contentType）
 *   - `.body`：原始响应正文
 *
 * 职责边界：
 *   - 纯文件 IO 封装，读写 + 过期判定委托给 `MetadataCache.ets` 的纯函数
 *   - 不涉及网络请求；`McDownloader.httpGet` 负责在 cache miss 时 fetchText + put
 *   - 与 LayoutStore / DownloadHistoryStore 一致的 `init(context) → getXxxStore()` 风格
 *
 * 当前行为说明（Phase 2.3b 已完成）：
 *   - `DownloadManager.fetchTextEx` 暴露 `statusCode` + `headers`，`put(url, body, responseHeaders?)`
 *     在写入时调 `parseConditionalHeaders` 把 ETag / Last-Modified / Content-Type 提取进 CacheMeta。
 *   - 缓存策略：TTL（按 maxAgeMs 过期）+ 304 短路（`getMeta` 给上游做 If-None-Match / If-Modified-Since）。
 *     content-addressed URL（piston-meta/<sha1>/...）用 maxAge=-1 永久命中；latest manifest 走 6h TTL + ETag。
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 2.3
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  urlHash,
  isCacheValid,
  serializeMeta,
  deserializeMeta,
  parseConditionalHeaders,
  CacheMeta,
} from './MetadataCache';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = 'MetadataCacheStore';

export class MetadataCacheStore {
  private dir_: string = '';
  private ready_: boolean = false;

  /** 幂等初始化；在 EntryAbility.onCreate / Index.aboutToAppear 阶段调一次即可。 */
  init(context: common.Context): void {
    if (this.ready_) return;
    this.dir_ = context.filesDir + '/metadata-cache';
    try {
      fs.mkdirSync(this.dir_, true);
    } catch (e) {
      // 已存在是常态，忽略
    }
    this.ready_ = true;
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'init: dir=%{public}s', this.dir_);
  }

  isReady(): boolean {
    return this.ready_;
  }

  getDir(): string {
    return this.dir_;
  }

  private metaPath(url: string): string { return this.dir_ + '/' + urlHash(url) + '.meta'; }
  private bodyPath(url: string): string { return this.dir_ + '/' + urlHash(url) + '.body'; }

  /**
   * 尝试读取缓存 body。命中条件：
   *   - 已 init
   *   - `.meta` 和 `.body` 文件都存在
   *   - 反序列化成功 + `url` 与调用方一致（防 hash 碰撞）
   *   - `isCacheValid(meta, maxAgeMs, now)` 返回 true
   *
   * 任一步失败即返回 null。
   *
   * @param maxAgeMs -1 = 永不过期；>0 = TTL 毫秒；0/负数 视为永远过期
   */
  get(url: string, maxAgeMs: number): string | null {
    if (!this.ready_) return null;
    let mPath = this.metaPath(url);
    let bPath = this.bodyPath(url);
    try {
      let metaJson = fs.readTextSync(mPath);
      let meta = deserializeMeta(metaJson);
      if (!meta || meta.url !== url) return null;
      if (!isCacheValid(meta, maxAgeMs, Date.now())) return null;
      let body = fs.readTextSync(bPath);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'cache HIT: %{public}s (age=%{public}dms)',
        url, Date.now() - meta.fetchedAt);
      return body;
    } catch (e) {
      return null;
    }
  }

  /**
   * Phase 2.3: 读取已存的 `CacheMeta`（不判断过期）。
   * 用途：TTL 已过期但 cache 仍存时，调用方需 `meta.etag` / `meta.lastModified`
   *       构造 `If-None-Match` / `If-Modified-Since` 走 304 短路。
   *
   * 返回 null：未 init / 文件缺失 / JSON 损坏 / url 不匹配（hash 碰撞）。
   */
  getMeta(url: string): CacheMeta | null {
    if (!this.ready_) return null;
    try {
      let metaJson = fs.readTextSync(this.metaPath(url));
      let meta = deserializeMeta(metaJson);
      if (!meta || meta.url !== url) return null;
      return meta;
    } catch (e) {
      return null;
    }
  }

  /**
   * Phase 2.3: 读取 body 不做有效期检查（304 命中后用）。
   * 通常仅当先调 `getMeta` 拿到 etag、再发 304 命中后调用。
   */
  getBody(url: string): string | null {
    if (!this.ready_) return null;
    try {
      return fs.readTextSync(this.bodyPath(url));
    } catch (e) {
      return null;
    }
  }

  /**
   * Phase 2.3: 304 命中后刷新 `fetchedAt`，让 TTL 重新计时。
   * 仅 meta 写盘，不动 body。失败静默。
   */
  touch(url: string): void {
    if (!this.ready_) return;
    let meta = this.getMeta(url);
    if (!meta) return;
    meta.fetchedAt = Date.now();
    try {
      this.writeText(this.metaPath(url), serializeMeta(meta));
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'cache TOUCH: %{public}s', url);
    } catch (e) {
      AppLogger.warn(TAG, 'cache TOUCH failed', e, LOG_DOMAIN_DOWNLOAD);
    }
  }

  /**
   * 写入 body + meta。无响应头时只写 url + fetchedAt；有则调 `parseConditionalHeaders` 提取。
   * 任何 IO 失败只告警，不抛异常（缓存失败不应破坏业务）。
   *
   * M-3 修复：原子化写盘 — 先写 `.tmp` 再 rename。
   *   - 旧实现先写 body 再写 meta，进程被杀 / 写 meta 失败时残留孤儿 body，
   *     `get()` 找不到 meta 当 miss 走 fallback 重下，body 文件永远泄漏。
   *   - 新流程：
   *     1. body 写 `bTmp`，meta 写 `mTmp`（任一失败 → 清 .tmp 退出）
   *     2. rename `bTmp → bPath`（同分区 rename 是原子操作）
   *     3. rename `mTmp → mPath`
   *     如果第 3 步失败，bPath 已更新但 mPath 还指旧 meta — get() 检查
   *     `meta.url === url` 通过，但 body 已被覆写。这是无害场景：要么旧 url
   *     的新 body 暂时被读到（旁路缓存，下次 TTL 过期重下），要么新 url
   *     的 meta 还没更新 → get() 走 fallback。不会产生孤儿。
   *
   *   失败时清理 .tmp 残留，防磁盘占用累积。
   */
  put(url: string, body: string, responseHeaders?: Record<string, string>): void {
    if (!this.ready_) return;
    if (body.length === 0) return;
    let meta: CacheMeta = { url, fetchedAt: Date.now() };
    if (responseHeaders) {
      let extracted = parseConditionalHeaders(responseHeaders);
      if (extracted.etag !== undefined) meta.etag = extracted.etag;
      if (extracted.lastModified !== undefined) meta.lastModified = extracted.lastModified;
      if (extracted.contentType !== undefined) meta.contentType = extracted.contentType;
    }
    let mPath = this.metaPath(url);
    let bPath = this.bodyPath(url);
    let mTmp = mPath + '.tmp';
    let bTmp = bPath + '.tmp';
    try {
      // 1. 写入两个临时文件
      this.writeText(bTmp, body);
      this.writeText(mTmp, serializeMeta(meta));
      // 2. 原子 rename（同分区 POSIX 保证原子）
      fs.renameSync(bTmp, bPath);
      fs.renameSync(mTmp, mPath);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'cache PUT: %{public}s (%{public}d bytes)', url, body.length);
    } catch (e) {
      AppLogger.warn(TAG, `cache PUT failed for ${url}`, e, LOG_DOMAIN_DOWNLOAD);
      // 清理 .tmp 残留
      try { fs.unlinkSync(bTmp); } catch (_) { /* */ }
      try { fs.unlinkSync(mTmp); } catch (_) { /* */ }
    }
  }

  /** 清空所有或指定 URL 的缓存（用于调试 / 用户手动刷新）。 */
  clear(url?: string): void {
    if (!this.ready_) return;
    if (url !== undefined) {
      try { fs.unlinkSync(this.metaPath(url)); } catch (e) { /* */ }
      try { fs.unlinkSync(this.bodyPath(url)); } catch (e) { /* */ }
      return;
    }
    try {
      let files = fs.listFileSync(this.dir_);
      for (let f of files) {
        try { fs.unlinkSync(this.dir_ + '/' + f); } catch (e) { /* */ }
      }
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'cache cleared: %{public}d files', files.length);
    } catch (e) {
      // dir 不存在也算已清空
    }
  }

  // 2026-05-23 ArkTS 严格模式：fs.openSync / writeSync / closeSync 都报
  // 'Function may throw'。用 FileUtils.writeTextFile（已包装）。
  // 详见 docs/guides/api-migration-2026-05.md。
  private writeText(path: string, content: string): void {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } catch (e) {
      AppLogger.warn(TAG, `writeText ${path} failed`, e, LOG_DOMAIN_DOWNLOAD);
      throw e as Error;
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) { /* ignore */ }
      }
    }
  }
}

// ============================================================
//  Singleton
// ============================================================

let _instance: MetadataCacheStore | null = null;

export function getMetadataCacheStore(): MetadataCacheStore {
  if (_instance === null) {
    _instance = new MetadataCacheStore();
  }
  return _instance;
}

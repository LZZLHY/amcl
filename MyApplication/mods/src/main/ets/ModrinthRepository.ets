/**
 * ModrinthRepository.ets — Modrinth API 适配器（P1-MODS Phase 1.2）
 *
 * 文档：docs/guides/mod-download-system-plan.md §四.1 / §七.2
 *
 * 关键设计：
 *   - 依赖注入：DownloadManager + MetadataCacheStore + sourceModeProvider + UA
 *     便于未来由 SourceProber 动态切换主源、由 PreferenceManager 切 UA 版本
 *   - 缓存策略（与 MetadataCacheStore 协作）：
 *     • search：TTL 10min + ETag/304（2026-07-03：原不缓存，为加速列表加载改为短 TTL）
 *     • getProject：TTL 2h + ETag/304
 *     • getVersions：TTL 30min + ETag/304
 *     • getVersion：TTL 24h（单版本 id 理论不变）
 *   - 错误统一包装为 ModRepoError；404 在 lookupVersionBySha1 中视为 null
 *   - 纯函数层在 ModrinthUrls.ets，已单测；本类只负责 HTTP + 缓存编排
 *
 * 创建日期：2026-05-11
 */

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { DownloadManager } from 'feature_core';
import { MetadataCacheStore } from 'feature_core';
import { buildConditionalRequest } from 'feature_core';
import {
  ModSource,
  RemoteProject,
  RemoteVersion,
} from './ModTypes';
import {
  IRemoteModRepository,
  SearchOptions,
  SearchResult,
  SortBy,
  ModRepoError,
  ModRepoErrorKind,
} from './RemoteModRepository';
import {
  ModrinthSourceMode,
  UrlSet,
  buildModrinthFacets,
  buildSearchUrl,
  buildProjectUrl,
  buildProjectsByIdsUrl,
  buildVersionsUrl,
  buildVersionUrl,
  buildVersionFileSha1Url,
  mapModrinthHit,
  mapModrinthProject,
  mapModrinthVersion,
  ModrinthSearchResponseRaw,
  ModrinthProjectRaw,
  ModrinthVersionRaw,
} from './ModrinthUrls';

const TAG = 'ModrinthRepository';

// TTL 常量（毫秒）
const TTL_PROJECT_MS  = 2 * 60 * 60 * 1000;   // 2h
const TTL_VERSIONS_MS = 30 * 60 * 1000;       // 30min
const TTL_VERSION_MS  = 24 * 60 * 60 * 1000;  // 24h（单版本 immutable）
// 2026-07-03：search 结果加短 TTL 磁盘缓存（复用 cachedFetch 的 TTL+ETag/304 基础设施）。
// 列表加载慢的真正主因是 search 每次都打网络；同一搜索词/翻页在 TTL 内复用缓存 → 秒开，
// TTL 过期后走 304 条件请求（Modrinth 支持 ETag）几乎零流量。榜单短时间内基本不变，10min 安全。
// 用户关闭 cacheRemoteMeta 时 cachedFetch 自动退化为无缓存 fetchText。
const TTL_SEARCH_MS   = 10 * 60 * 1000;       // 10min

// 请求超时 30s（与 fetchTextEx 默认一致）
const FETCH_TIMEOUT_SECONDS = 30;

// ============================================================
//  ModrinthRepository
// ============================================================

/** 源模式提供者：允许运行期由 SourceProber 热切 MCIM_FIRST / OFFICIAL_FIRST */
export type ModrinthSourceModeProvider = () => ModrinthSourceMode;
/** 缓存开关：每次条件请求前调用，false 时退化为无缓存 fetchText（用户偏好 cacheRemoteMeta=off） */
export type CacheEnabledProvider = () => boolean;

export class ModrinthRepository implements IRemoteModRepository {
  readonly source: ModSource = ModSource.MODRINTH;

  private downloadManager_: DownloadManager;
  private cacheStore_: MetadataCacheStore;
  private sourceModeProvider_: ModrinthSourceModeProvider;
  private cacheEnabledProvider_: CacheEnabledProvider;
  private userAgent_: string;

  /**
   * @param downloadManager     复用现有单例（带 CA bundle / 多源 fallback）
   * @param cacheStore          复用现有 MetadataCacheStore（TTL + ETag/304）
   * @param sourceModeProvider  每次请求前调用，返回当前偏好（便于运行期热切）
   * @param userAgent           符合 Modrinth 规范：`AMCL/1.0.0 (https://github.com/<repo>)`
   * @param cacheEnabledProvider 可选：返回 false 时所有 cachedFetch 退化为无缓存 fetchText
   *                             （用户在 SettingsTab 关掉 cacheRemoteMeta 时生效）
   */
  constructor(
    downloadManager: DownloadManager,
    cacheStore: MetadataCacheStore,
    sourceModeProvider: ModrinthSourceModeProvider,
    userAgent: string,
    cacheEnabledProvider?: CacheEnabledProvider,
  ) {
    this.downloadManager_ = downloadManager;
    this.cacheStore_ = cacheStore;
    this.sourceModeProvider_ = sourceModeProvider;
    this.userAgent_ = userAgent;
    this.cacheEnabledProvider_ = cacheEnabledProvider !== undefined
      ? cacheEnabledProvider : (() => true);
  }

  isAvailable(): boolean {
    // CA bundle 就绪是任何 HTTPS 调用的前置；Modrinth 是 https 端点
    return this.downloadManager_.isCaBundleInitialized();
  }

  // ============================================================
  //  search
  // ============================================================

  async search(opt: SearchOptions): Promise<SearchResult> {
    this.assertReady();
    let facets = buildModrinthFacets(opt.kind, opt.gameVersion, opt.loaders, opt.categories);
    let sortStr = sortByToModrinthIndex(opt.sortBy);
    let urls = buildSearchUrl(opt.query, facets, sortStr, opt.offset, opt.pageSize, this.mode());
    AppLogger.info(TAG, `search: q="${opt.query}" kind=${opt.kind} gv=${opt.gameVersion !== undefined ? opt.gameVersion : '-'}`, LOG_DOMAIN_DOWNLOAD);

    // 短 TTL 缓存（复用 cachedFetch 的 TTL+ETag/304）：同一搜索词/翻页在 TTL 内秒开。
    let body = await this.cachedFetch(urls, TTL_SEARCH_MS);
    let raw = this.parseJson<ModrinthSearchResponseRaw>(body);
    let hits: RemoteProject[] = [];
    for (let h of raw.hits) {
      try { hits.push(mapModrinthHit(h)); }
      catch (e) { AppLogger.warn(TAG, 'skip hit', e as Object, LOG_DOMAIN_DOWNLOAD); }
    }
    return {
      hits,
      totalHits: raw.total_hits,
      offset: raw.offset,
      pageSize: raw.limit,
    };
  }

  // ============================================================
  //  getProject
  // ============================================================

  async getProject(idOrSlug: string): Promise<RemoteProject> {
    this.assertReady();
    let urls = buildProjectUrl(idOrSlug, this.mode());
    let body = await this.cachedFetch(urls, TTL_PROJECT_MS);
    let raw = this.parseJson<ModrinthProjectRaw>(body);
    return mapModrinthProject(raw);
  }

  // ============================================================
  //  getProjectsByIds — 批量直取（中文搜索按 slug 直取用）
  // ============================================================

  /**
   * 按 id/slug 批量取工程。走短 TTL 缓存（同 search）。个别条目映射失败跳过，不影响整体。
   * 空输入直接返回空数组。失败抛 ModRepoError（调用方可降级为纯关键词搜索）。
   */
  async getProjectsByIds(ids: string[]): Promise<RemoteProject[]> {
    this.assertReady();
    if (ids.length === 0) return [];
    let urls = buildProjectsByIdsUrl(ids, this.mode());
    let body = await this.cachedFetch(urls, TTL_SEARCH_MS);
    let arr = this.parseJson<ModrinthProjectRaw[]>(body);
    let result: RemoteProject[] = [];
    for (let raw of arr) {
      try { result.push(mapModrinthProject(raw)); }
      catch (e) { AppLogger.warn(TAG, 'skip project', e as Object, LOG_DOMAIN_DOWNLOAD); }
    }
    return result;
  }

  // ============================================================
  //  getVersions
  // ============================================================

  async getVersions(
    projectId: string,
    loaders?: string[],
    gameVersions?: string[],
  ): Promise<RemoteVersion[]> {
    this.assertReady();
    let urls = buildVersionsUrl(projectId, loaders, gameVersions, this.mode());
    let body = await this.cachedFetch(urls, TTL_VERSIONS_MS);
    let arr = this.parseJson<ModrinthVersionRaw[]>(body);
    let result: RemoteVersion[] = [];
    let mode = this.mode();
    for (let v of arr) result.push(mapModrinthVersion(v, mode));
    return result;
  }

  // ============================================================
  //  getVersion
  // ============================================================

  async getVersion(versionId: string): Promise<RemoteVersion> {
    this.assertReady();
    let urls = buildVersionUrl(versionId, this.mode());
    let body = await this.cachedFetch(urls, TTL_VERSION_MS);
    let raw = this.parseJson<ModrinthVersionRaw>(body);
    return mapModrinthVersion(raw, this.mode());
  }

  // ============================================================
  //  lookupVersionBySha1（可选能力，IRemoteModRepository 规约支持）
  // ============================================================

  async lookupVersionBySha1(sha1: string): Promise<RemoteVersion | null> {
    this.assertReady();
    let urls = buildVersionFileSha1Url(sha1, this.mode());
    try {
      let body = await this.fetchText(urls);
      let raw = this.parseJson<ModrinthVersionRaw>(body);
      return mapModrinthVersion(raw, this.mode());
    } catch (e) {
      let err = e instanceof ModRepoError
        ? (e as ModRepoError)
        : ModRepoError.fromUnknown(ModSource.MODRINTH, e as Object);
      if (err.httpStatus === 404) return null;
      throw err;
    }
  }

  // ============================================================
  //  内部工具
  // ============================================================

  /** 取当前源偏好；每次调用都重算，允许运行期热切 */
  private mode(): ModrinthSourceMode {
    return this.sourceModeProvider_();
  }

  private assertReady(): void {
    if (!this.downloadManager_.isCaBundleInitialized()) {
      throw new ModRepoError(ModSource.MODRINTH, ModRepoErrorKind.UNKNOWN,
        'CA bundle 未初始化，请在 EntryAbility.onCreate 中调 initializeCaBundle(context)');
    }
  }

  /** 无缓存的纯 GET，用于 search / lookupVersionBySha1 */
  private async fetchText(urls: UrlSet): Promise<string> {
    let reqHeaders: Record<string, string> = { 'User-Agent': this.userAgent_ };
    try {
      let resp = await this.downloadManager_.fetchTextEx(
        urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqHeaders);
      if (resp.statusCode >= 200 && resp.statusCode < 300) return resp.body;
      throw new ModRepoError(ModSource.MODRINTH,
        resp.statusCode >= 500 ? ModRepoErrorKind.HTTP_SERVER : ModRepoErrorKind.HTTP_CLIENT,
        'HTTP ' + resp.statusCode, resp.statusCode);
    } catch (e) {
      if (e instanceof ModRepoError) throw e;
      throw ModRepoError.fromUnknown(ModSource.MODRINTH, e as Object);
    }
  }

  /** 带 TTL + ETag/304 的 GET；命中新鲜缓存直接返回 */
  private async cachedFetch(urls: UrlSet, ttlMs: number): Promise<string> {
    // 修复：用户偏好 cacheRemoteMeta=off 时退化为无缓存请求
    if (!this.cacheEnabledProvider_()) {
      return this.fetchText(urls);
    }
    // 1. TTL 内直接返回
    let cached = this.cacheStore_.get(urls.primary, ttlMs);
    if (cached !== null) return cached;

    // 2. TTL 过期但 meta 还在 → 条件请求
    let reqHeaders: Record<string, string> = { 'User-Agent': this.userAgent_ };
    let meta = this.cacheStore_.getMeta(urls.primary);
    if (meta !== null) {
      let cond = buildConditionalRequest(meta);
      let keys = Object.keys(cond);
      for (let k of keys) reqHeaders[k] = cond[k];
    }

    // 3. 发请求
    try {
      let resp = await this.downloadManager_.fetchTextEx(
        urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqHeaders);

      // 304：用缓存 body + touch
      if (resp.statusCode === 304) {
        let body = this.cacheStore_.getBody(urls.primary);
        if (body !== null) {
          this.cacheStore_.touch(urls.primary);
          AppLogger.info(TAG, `cache 304 hit: ${urls.primary}`, LOG_DOMAIN_DOWNLOAD);
          return body;
        }
        // 304 但磁盘 body 读不到（极端），走一次无条件 GET
        AppLogger.warn(TAG, `304 but body missing; force reload: ${urls.primary}`, null, LOG_DOMAIN_DOWNLOAD);
        let reqPlain: Record<string, string> = { 'User-Agent': this.userAgent_ };
        let resp2 = await this.downloadManager_.fetchTextEx(
          urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqPlain);
        if (resp2.statusCode >= 200 && resp2.statusCode < 300) {
          this.cacheStore_.put(urls.primary, resp2.body, resp2.headers);
          return resp2.body;
        }
        throw new ModRepoError(ModSource.MODRINTH, ModRepoErrorKind.HTTP_SERVER,
          '304 reload HTTP ' + resp2.statusCode, resp2.statusCode);
      }

      // 200：写缓存 + 返回
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        this.cacheStore_.put(urls.primary, resp.body, resp.headers);
        return resp.body;
      }

      // 其他非 2xx
      throw new ModRepoError(ModSource.MODRINTH,
        resp.statusCode >= 500 ? ModRepoErrorKind.HTTP_SERVER : ModRepoErrorKind.HTTP_CLIENT,
        'HTTP ' + resp.statusCode, resp.statusCode);
    } catch (e) {
      if (e instanceof ModRepoError) throw e;
      throw ModRepoError.fromUnknown(ModSource.MODRINTH, e as Object);
    }
  }

  /** 统一 JSON 解析：失败包成 ModRepoErrorKind.PARSE */
  private parseJson<T>(body: string): T {
    try {
      return JSON.parse(body) as T;
    } catch (e) {
      throw new ModRepoError(ModSource.MODRINTH, ModRepoErrorKind.PARSE,
        'Invalid JSON from Modrinth: ' + (e as Error).message, 0,
        body.length > 200 ? body.substring(0, 200) + '...' : body);
    }
  }
}

// ============================================================
//  工具：SortBy → Modrinth `index` 值
// ============================================================

function sortByToModrinthIndex(s: SortBy): string {
  switch (s) {
    case SortBy.RELEVANCE: return 'relevance';
    case SortBy.DOWNLOADS: return 'downloads';
    case SortBy.FOLLOWS:   return 'follows';
    case SortBy.NEWEST:    return 'newest';
    case SortBy.UPDATED:   return 'updated';
    default:               return 'relevance';
  }
}

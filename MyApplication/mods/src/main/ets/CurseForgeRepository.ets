/**
 * CurseForgeRepository.ets — CurseForge API 适配器（P1-MODS Phase 2.1b）
 *
 * 文档：docs/guides/mod-download-system-plan.md §四.2 / §七.3
 *
 * 关键设计：
 *   - **仅走 MCIM 镜像**（mod.mcimirror.top/curseforge/v1）：本启动器不内置 CurseForge API Key，
 *     直连官方端点会被 401。MCIM 不可用时由 isAvailable() 返回 false，路由器跳过本源。
 *   - 依赖注入：DownloadManager + MetadataCacheStore + UA。
 *   - 缓存策略（与 Modrinth 一致）：
 *     • search：不缓存
 *     • getProject：TTL 2h + ETag/304
 *     • getVersions：TTL 30min + ETag/304
 *     • getVersion：TTL 24h（单 fileId 不变）
 *   - 错误统一包装为 ModRepoError；MCIM 不可达视为 NETWORK 错。
 *   - 纯函数层在 CurseForgeUrls.ets，已单测；本类只负责 HTTP + 缓存编排。
 *
 * **CurseForge 特殊点**：
 *   - 所有响应都包一层 `{ data: ... , pagination?: ... }`，需要 unwrap。
 *   - file.downloadUrl 可能为空（作者禁用第三方下载）→ 调 /download-url 兜底。
 *
 * 创建日期：2026-05-11
 */

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { http } from '@kit.NetworkKit';
import { DownloadManager } from 'feature_core';
import { MetadataCacheStore } from 'feature_core';
import { buildConditionalRequest } from 'feature_core';
import {
  ModSource,
  ResourceKind,
  RemoteProject,
  RemoteVersion,
  toCurseForgeClassId,
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
  CFUrlSet,
  CURSEFORGE_API_MCIM,
  buildCurseForgeSearchUrl,  buildCurseForgeSearchBySlugUrl,
  buildCurseForgeProjectUrl,
  buildCurseForgeFilesUrl,
  buildCurseForgeFileUrl,
  buildCurseForgeFileDownloadUrl,
  buildCurseForgeFileDownloadUrls,
  buildForgeCdnUrlFromFileId,
  nonEmptyStr,
  toCurseForgeModLoaderType,
  toCurseForgeSortField,
  mapCurseForgeMod,
  mapCurseForgeFileAsVersion,
  extractSha1FromCfHashes,
  CFSearchResponseRaw,
  CFModResponseRaw,
  CFFilesResponseRaw,
  CFFileResponseRaw,
  CFFileRaw,
  CFDownloadUrlResponseRaw,
  CFFingerprintMatchesResponseRaw,
} from './CurseForgeUrls';

const TAG = 'CurseForgeRepository';

// TTL 常量（毫秒）
const TTL_PROJECT_MS  = 2 * 60 * 60 * 1000;
const TTL_VERSIONS_MS = 30 * 60 * 1000;
const TTL_VERSION_MS  = 24 * 60 * 60 * 1000;
const TTL_DOWNLOAD_URL_MS = 60 * 60 * 1000;  // 1h（CurseForge CDN 链 TTL 不长）
// 2026-07-03：search 加短 TTL 磁盘缓存，同 Modrinth（复用 cachedFetch 的 TTL+ETag/304）。
const TTL_SEARCH_MS   = 10 * 60 * 1000;       // 10min

const FETCH_TIMEOUT_SECONDS = 30;
const PAGE_SIZE_FILES = 50;

// ============================================================
//  CurseForgeRepository
// ============================================================

/** 缓存开关：每次条件请求前调用，false 时退化为无缓存 fetchText（用户偏好 cacheRemoteMeta=off） */
export type CacheEnabledProvider = () => boolean;

/**
 * CurseForge 文件下载解析结果：真实文件名 + 下载 URL 列表（含镜像，按优先级）。
 * 用于整合包安装：既要 URL 下载，也要真实 fileName 落地到 mods/<fileName>。
 */
export interface CfFileDownloadInfo {
  urls: string[];
  filename: string;
  size: number;
  sha1?: string;
}

export class CurseForgeRepository implements IRemoteModRepository {
  readonly source: ModSource = ModSource.CURSEFORGE;

  private downloadManager_: DownloadManager;
  private cacheStore_: MetadataCacheStore;
  private userAgent_: string;
  /** MCIM 端点是否可用；由外部 ModSourceProber（Phase 2.2 接入）决定，缺省视为可用 */
  private mcimAvailable_: () => boolean;
  private cacheEnabledProvider_: CacheEnabledProvider;

  /**
   * @param downloadManager   复用现有单例
   * @param cacheStore        复用现有 MetadataCacheStore（TTL + ETag/304）
   * @param userAgent         `AMCL/<ver> (https://github.com/<repo>)`
   * @param mcimAvailable     可选闭包：MCIM 不可用时 isAvailable() 短路；默认 () => true
   * @param cacheEnabledProvider 可选：返回 false 时所有 cachedFetch 退化为无缓存 fetchText
   *                             （用户在 SettingsTab 关掉 cacheRemoteMeta 时生效）
   */
  constructor(
    downloadManager: DownloadManager,
    cacheStore: MetadataCacheStore,
    userAgent: string,
    mcimAvailable?: () => boolean,
    cacheEnabledProvider?: CacheEnabledProvider,
  ) {
    this.downloadManager_ = downloadManager;
    this.cacheStore_ = cacheStore;
    this.userAgent_ = userAgent;
    this.mcimAvailable_ = mcimAvailable !== undefined ? mcimAvailable : (() => true);
    this.cacheEnabledProvider_ = cacheEnabledProvider !== undefined
      ? cacheEnabledProvider : (() => true);
  }

  isAvailable(): boolean {
    if (!this.downloadManager_.isCaBundleInitialized()) return false;
    return this.mcimAvailable_();
  }

  // ============================================================
  //  search
  // ============================================================

  async search(opt: SearchOptions): Promise<SearchResult> {
    this.assertReady();

    let classId = toCurseForgeClassId(opt.kind);
    let modLoaderType = 0;
    if ((opt.kind === ResourceKind.MOD || opt.kind === ResourceKind.MODPACK)
        && opt.loaders !== undefined && opt.loaders.length > 0) {
      // CurseForge 只支持单 loader 过滤；取第一个有效值
      for (let l of opt.loaders) {
        let n = toCurseForgeModLoaderType(l);
        if (n !== 0) { modLoaderType = n; break; }
      }
    }
    let sortField = toCurseForgeSortField(opt.sortBy);
    let urls = buildCurseForgeSearchUrl(
      opt.query,
      classId,
      opt.gameVersion,
      modLoaderType,
      sortField,
      true,  // sortOrder = desc
      opt.offset,
      opt.pageSize,
    );
    AppLogger.info(TAG, `search: q="${opt.query}" kind=${opt.kind} gv=${opt.gameVersion !== undefined ? opt.gameVersion : '-'} loader=${modLoaderType}`, LOG_DOMAIN_DOWNLOAD);

    // 短 TTL 缓存（复用 cachedFetch）：同一搜索词/翻页在 TTL 内秒开。
    let body = await this.cachedFetch(urls, TTL_SEARCH_MS);
    let raw = this.parseJson<CFSearchResponseRaw>(body);
    let hits: RemoteProject[] = [];
    for (let m of raw.data) {
      try { hits.push(mapCurseForgeMod(m)); }
      catch (e) {
        AppLogger.warn(TAG, 'skip mod', e as Object, LOG_DOMAIN_DOWNLOAD);
      }
    }
    return {
      hits,
      totalHits: raw.pagination !== undefined ? raw.pagination.totalCount : hits.length,
      offset: raw.pagination !== undefined ? raw.pagination.index : opt.offset,
      pageSize: raw.pagination !== undefined ? raw.pagination.pageSize : opt.pageSize,
    };
  }

  // ============================================================
  //  getProject
  // ============================================================

  async getProject(idOrSlug: string): Promise<RemoteProject> {
    this.assertReady();
    let urls = buildCurseForgeProjectUrl(idOrSlug);
    let body = await this.cachedFetch(urls, TTL_PROJECT_MS);
    let raw = this.parseJson<CFModResponseRaw>(body);
    return mapCurseForgeMod(raw.data);
  }

  /**
   * 按 slug 解析 CurseForge 工程（拿到真实数字 modId + 真实网址 + 真实分类）。
   * 用于"只知 slug、需切到 CurseForge 下载 / 打开 CF 页面"的双源场景。未命中返回 null。
   * 不按 classId 过滤：跨源分类可能不一致，gameId+slug 已足够定位。
   */
  async getProjectBySlug(slug: string): Promise<RemoteProject | null> {
    this.assertReady();
    if (slug.length === 0) return null;
    let urls = buildCurseForgeSearchBySlugUrl(slug);
    let body = await this.fetchText(urls);
    let raw = this.parseJson<CFSearchResponseRaw>(body);
    if (raw.data === undefined || raw.data.length === 0) return null;
    let want = slug.toLowerCase();
    for (let m of raw.data) {
      let mapped = mapCurseForgeMod(m);
      if (mapped.slug.toLowerCase() === want) return mapped;
    }
    // **精确匹配不到就返回 null**，绝不退回 raw.data[0]：
    // 若 slug 过滤未被镜像端正确执行（返回的是热门榜而非按 slug 命中），退回首条
    // 会解析到一个**完全无关的 mod**（这正是"iris 解析到别的模组"的成因之一）。
    return null;
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

    let modLoaderType = 0;
    if (loaders !== undefined && loaders.length > 0) {
      for (let l of loaders) {
        let n = toCurseForgeModLoaderType(l);
        if (n !== 0) { modLoaderType = n; break; }
      }
    }
    let gv: string | undefined = undefined;
    if (gameVersions !== undefined && gameVersions.length > 0) {
      gv = gameVersions[0];
    }

    let result: RemoteVersion[] = [];
    let index = 0;
    const MAX_PAGES = 4;
    for (let page = 0; page < MAX_PAGES; page++) {
      let urls = buildCurseForgeFilesUrl(projectId, gv, modLoaderType, index, PAGE_SIZE_FILES);
      let body = await this.cachedFetch(urls, TTL_VERSIONS_MS);
      let raw = this.parseJson<CFFilesResponseRaw>(body);
      for (let f of raw.data) {
        try { result.push(mapCurseForgeFileAsVersion(f)); }
        catch (e) {
          AppLogger.warn(TAG, 'skip file', e as Object, LOG_DOMAIN_DOWNLOAD);
        }
      }
      let pagination = raw.pagination;
      if (pagination === undefined
          || raw.data.length < PAGE_SIZE_FILES
          || index + raw.data.length >= pagination.totalCount) {
        break;
      }
      index += raw.data.length;
    }
    return result;
  }

  // ============================================================
  //  getVersion（单文件元数据）
  // ============================================================

  async getVersion(versionId: string): Promise<RemoteVersion> {
    this.assertReady();
    // CurseForge 单 file 端点需要 modId — 从 versionId 推不出来，
    // 调用方应已先 getProject/getVersions 拿到完整 RemoteVersion；
    // 这里只用于"已知 modId+fileId"二步式调用，此时调用方应自己传 `${modId}/${fileId}`。
    let parts = versionId.split('/');
    if (parts.length !== 2) {
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.HTTP_CLIENT,
        'CurseForge getVersion 需 versionId="<modId>/<fileId>"，收到："' + versionId + '"');
    }
    let urls = buildCurseForgeFileUrl(parts[0], parts[1]);
    let body = await this.cachedFetch(urls, TTL_VERSION_MS);
    let raw = this.parseJson<CFFileResponseRaw>(body);
    return mapCurseForgeFileAsVersion(raw.data);
  }

  // ============================================================
  //  resolveFileDownloadUrl — CurseForge 专属
  // ============================================================

  /**
   * 当 RemoteFile.url 为空（作者禁用第三方下载）时，调
   * `/mods/{modId}/files/{fileId}/download-url` 拿真实 CDN 链。
   *
   * 返回的 URL 可能是 `edge.forgecdn.net` / `mediafilez.forgecdn.net`，
   * 调用方应再过一遍 `buildCurseForgeFileDownloadUrls` 获取 mcim+官方 双源。
   *
   * 失败时（404 / 网络） throw ModRepoError；调用方可降级到"打开浏览器跳官方"。
   */
  async resolveFileDownloadUrl(modId: string, fileId: string): Promise<string> {
    this.assertReady();
    let urls = buildCurseForgeFileDownloadUrl(modId, fileId);
    let body = await this.cachedFetch(urls, TTL_DOWNLOAD_URL_MS);
    let raw = this.parseJson<CFDownloadUrlResponseRaw>(body);
    if (raw.data === undefined || raw.data.length === 0) {
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.PARSE,
        'CurseForge /download-url 返回空 data');
    }
    return raw.data;
  }

  /**
   * 解析整合包内 CF 文件的下载信息（URL 列表 + 真实文件名）。
   *
   * 策略（针对"作者禁用第三方下载"做了兜底）：
   *   1. 先调 `/mods/{modId}/files/{fileId}` 拿文件元数据（fileName + 可选 downloadUrl）。
   *   2. downloadUrl 非空 → 直接镜像化（mcim 主、官方 CDN 备）。
   *   3. downloadUrl 为空（作者禁用分发）→ 用 fileId 反推 CDN 直链
   *      `edge.forgecdn.net/files/<id1>/<id2>/<fileName>`，再镜像化。
   *      文件实际仍在 CDN 上，故此法对绝大多数被禁用的 mod 有效。
   *   4. 仍拿不到（如 fileName 缺失）→ 退回 `/download-url` 端点最后一搏。
   *
   * 全部失败时 throw ModRepoError（调用方记入缺失清单）。
   */
  async resolveFileDownloadInfo(modId: string, fileId: string, _gameVersion?: string, _loader?: string): Promise<CfFileDownloadInfo> {
    this.assertReady();
    const id = fileId.indexOf('/') >= 0 ? fileId.substring(fileId.lastIndexOf('/') + 1) : fileId;
    const urls = buildCurseForgeFileUrl(modId, id);
    const body = await this.cachedFetch(urls, TTL_VERSION_MS);
    const raw = this.parseJson<CFFileResponseRaw>(body);
    if (raw.data === undefined || raw.data === null || String(raw.data.id) !== id || String(raw.data.modId) !== modId)
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.PARSE, 'CurseForge 返回的文件身份不符');
    const info = this.buildInfoFromCfFile_(raw.data);
    if (info === null) throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.PARSE, '该指定文件没有可用下载地址，请手动选择其他版本');
    return info;
  }





  /**
   * 从 CFFileRaw 构造下载信息：downloadUrl 非空则镜像化，为 null/空则按 fileId 反推 CDN。
   * 拿不到任何 URL → 返回 null。
   */
  private buildInfoFromCfFile_(file: CFFileRaw): CfFileDownloadInfo | null {
    // 注意：mcim 对"作者禁用第三方下载"的文件，downloadUrl 返回 JSON null（非字段缺失），
    // 必须用 nonEmptyStr 同时判 null（否则 .length 抛 "Cannot read property length of null"）。
    let fileName = nonEmptyStr(file.fileName);
    let officialUrl = nonEmptyStr(file.downloadUrl);
    if (officialUrl.length === 0 && fileName.length > 0 && file.id > 0) {
      officialUrl = buildForgeCdnUrlFromFileId(file.id, fileName);
    }
    if (officialUrl.length === 0) return null;

    let urlSet = buildCurseForgeFileDownloadUrls(officialUrl);
    let urls: string[] = [];
    if (urlSet.primary.length > 0) urls.push(urlSet.primary);
    for (let m of urlSet.mirrors) urls.push(m);

    let finalName = fileName;
    if (finalName.length === 0) {
      let q = officialUrl.indexOf('?');
      let clean = q >= 0 ? officialUrl.substring(0, q) : officialUrl;
      finalName = clean.substring(clean.lastIndexOf('/') + 1).split('%20').join(' ');
    }
    return { urls: urls, filename: finalName, size: file.fileLength, sha1: extractSha1FromCfHashes(file.hashes) ?? undefined };
  }

  // ============================================================
  //  lookupByFingerprint — CF Murmur2 指纹反查（用户导入的 CF 模组链接源）
  // ============================================================

  /**
   * 用 CurseForge 文件指纹(computeCurseForgeFingerprint 算出)反查该文件属于哪个 mod/file。
   *
   * 走 `POST /fingerprints`(元数据 GET 引擎不支持 POST body，故此处用 NetworkKit http 直连
   * MCIM 镜像)。命中 → 映射为 RemoteVersion(含 projectId / id / sha1)；未命中 / 失败 → null。
   *
   * 用途：手动导入的 CF 模组 Modrinth sha1 反查落空时，用指纹链接 CF 源 → 可检查更新 + 收编。
   */
  async lookupByFingerprint(fingerprint: number): Promise<RemoteVersion | null> {
    this.assertReady();
    if (fingerprint <= 0) return null;
    let url = CURSEFORGE_API_MCIM + '/fingerprints';
    let payload = JSON.stringify({ fingerprints: [fingerprint] });
    let httpReq = http.createHttp();
    try {
      let resp = await httpReq.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': this.userAgent_,
        },
        extraData: payload,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        AppLogger.warn(TAG, `fingerprint lookup HTTP ${resp.responseCode}`, null, LOG_DOMAIN_DOWNLOAD);
        return null;
      }
      let text = typeof resp.result === 'string' ? resp.result as string : '';
      if (text.length === 0) return null;
      let raw = JSON.parse(text) as CFFingerprintMatchesResponseRaw;
      if (raw === null || raw.data === undefined || raw.data === null) return null;
      let matches = raw.data.exactMatches;
      if (matches === undefined || matches === null || matches.length === 0) return null;
      let file = matches[0].file;
      if (file === undefined || file === null) return null;
      return mapCurseForgeFileAsVersion(file);
    } catch (e) {
      AppLogger.warn(TAG, `fingerprint lookup failed (fp=${fingerprint})`, e as Object, LOG_DOMAIN_DOWNLOAD);
      return null;
    } finally {
      try { httpReq.destroy(); } catch (e) { /* ignore */ }
    }
  }

  // ============================================================
  //  内部工具
  // ============================================================

  private assertReady(): void {
    if (!this.downloadManager_.isCaBundleInitialized()) {
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.UNKNOWN,
        'CA bundle 未初始化，请在 EntryAbility.onCreate 中调 initializeCaBundle(context)');
    }
    if (!this.mcimAvailable_()) {
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.NETWORK,
        'CurseForge 暂不可用：MCIM 镜像未通过健康检查');
    }
  }

  /** 无缓存的纯 GET（search 用）*/
  private async fetchText(urls: CFUrlSet): Promise<string> {
    let reqHeaders: Record<string, string> = { 'User-Agent': this.userAgent_ };
    try {
      let resp = await this.downloadManager_.fetchTextEx(
        urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqHeaders);
      if (resp.statusCode >= 200 && resp.statusCode < 300) return resp.body;
      throw new ModRepoError(ModSource.CURSEFORGE,
        resp.statusCode >= 500 ? ModRepoErrorKind.HTTP_SERVER : ModRepoErrorKind.HTTP_CLIENT,
        'HTTP ' + resp.statusCode, resp.statusCode);
    } catch (e) {
      if (e instanceof ModRepoError) throw e;
      throw ModRepoError.fromUnknown(ModSource.CURSEFORGE, e as Object);
    }
  }

  /** 带 TTL + ETag/304 的 GET */
  private async cachedFetch(urls: CFUrlSet, ttlMs: number): Promise<string> {
    // 修复：用户偏好 cacheRemoteMeta=off 时退化为无缓存请求
    if (!this.cacheEnabledProvider_()) {
      return this.fetchText(urls);
    }
    let cached = this.cacheStore_.get(urls.primary, ttlMs);
    if (cached !== null) return cached;

    let reqHeaders: Record<string, string> = { 'User-Agent': this.userAgent_ };
    let meta = this.cacheStore_.getMeta(urls.primary);
    if (meta !== null) {
      let cond = buildConditionalRequest(meta);
      let keys = Object.keys(cond);
      for (let k of keys) reqHeaders[k] = cond[k];
    }

    try {
      let resp = await this.downloadManager_.fetchTextEx(
        urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqHeaders);

      if (resp.statusCode === 304) {
        let body = this.cacheStore_.getBody(urls.primary);
        if (body !== null) {
          this.cacheStore_.touch(urls.primary);
          AppLogger.info(TAG, `cache 304 hit: ${urls.primary}`, LOG_DOMAIN_DOWNLOAD);
          return body;
        }
        AppLogger.warn(TAG, `304 but body missing; force reload: ${urls.primary}`, null, LOG_DOMAIN_DOWNLOAD);
        let reqPlain: Record<string, string> = { 'User-Agent': this.userAgent_ };
        let resp2 = await this.downloadManager_.fetchTextEx(
          urls.primary, urls.mirrors, FETCH_TIMEOUT_SECONDS, reqPlain);
        if (resp2.statusCode >= 200 && resp2.statusCode < 300) {
          this.cacheStore_.put(urls.primary, resp2.body, resp2.headers);
          return resp2.body;
        }
        throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.HTTP_SERVER,
          '304 reload HTTP ' + resp2.statusCode, resp2.statusCode);
      }

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        this.cacheStore_.put(urls.primary, resp.body, resp.headers);
        return resp.body;
      }

      throw new ModRepoError(ModSource.CURSEFORGE,
        resp.statusCode >= 500 ? ModRepoErrorKind.HTTP_SERVER : ModRepoErrorKind.HTTP_CLIENT,
        'HTTP ' + resp.statusCode, resp.statusCode);
    } catch (e) {
      if (e instanceof ModRepoError) throw e;
      throw ModRepoError.fromUnknown(ModSource.CURSEFORGE, e as Object);
    }
  }

  /** 统一 JSON 解析：失败包成 ModRepoErrorKind.PARSE */
  private parseJson<T>(body: string): T {
    try {
      return JSON.parse(body) as T;
    } catch (e) {
      let err = e as Error;
      throw new ModRepoError(ModSource.CURSEFORGE, ModRepoErrorKind.PARSE,
        'Invalid JSON from CurseForge: '
        + (err.message !== undefined ? err.message : String(e)),
        0,
        body.length > 200 ? body.substring(0, 200) + '...' : body);
    }
  }
}

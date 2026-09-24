/**
 * CurseForgeUrls.ets — CurseForge API / CDN 的 URL 构造、参数编码、响应映射（纯函数）
 *
 * P1-MODS Phase 2.1a：拆出纯函数层，方便在 hvigor test 下直接单测，不依赖 HTTP。
 *
 * 文档：docs/guides/mod-download-system-plan.md §四.2 / §七.3
 *
 * 镜像规则（参见 mod.mcimirror.top 文档）：
 *   API:  `api.curseforge.com/v1/*`           → `mod.mcimirror.top/curseforge/v1/*`
 *   CDN:  `edge.forgecdn.net/...`             → `mod.mcimirror.top/...`
 *         `mediafilez.forgecdn.net/...`       → `mod.mcimirror.top/...`
 *
 * **关键设计决策**：本启动器**不内置 CurseForge API Key**，因此：
 *   - 所有元数据请求**仅走 MCIM 镜像**（primary=mcim, mirrors=[]）；
 *   - MCIM 不可用时由仓库适配器返回"CurseForge 暂不可用"错误，**不**降级到官方端点；
 *   - 只有 CDN 文件下载时，才把官方 forgecdn URL 作为 mirror（CDN 不需要 Key）。
 *
 * 创建日期：2026-05-11
 */

import {
  ModSource,
  ResourceKind,
  VersionChannel,
  DependencyType,
  RemoteProject,
  RemoteVersion,
  RemoteFile,
  RemoteDependency,
  fromCurseForgeClassId,
} from './ModTypes';
import { SortBy } from './RemoteModRepository';

// ============================================================
//  常量
// ============================================================

export const CURSEFORGE_API_OFFICIAL = 'https://api.curseforge.com/v1';
export const CURSEFORGE_API_MCIM = 'https://mod.mcimirror.top/curseforge/v1';

/** CurseForge Minecraft gameId（API 文档 §gameId） */
export const CURSEFORGE_GAME_ID = 432;

/** 已知的 CurseForge CDN 主机；MCIM 把它们都映射到 mod.mcimirror.top */
export const CURSEFORGE_CDN_HOSTS: string[] = [
  'edge.forgecdn.net',
  'mediafilez.forgecdn.net',
];

export const MCIM_CDN_PREFIX = 'https://mod.mcimirror.top/';

// ============================================================
//  ModLoaderType（CurseForge API 枚举值）
// ============================================================

/**
 * CurseForge `modLoaderType` 数字编码 ↔ AMCL/Modrinth 通用 loader 字符串。
 *   0 = Any         → '' (传 0 表示不限)
 *   1 = Forge       → 'forge'
 *   2 = Cauldron    → '' (无对应)
 *   3 = LiteLoader  → 'liteloader'
 *   4 = Fabric      → 'fabric'
 *   5 = Quilt       → 'quilt'
 *   6 = NeoForge    → 'neoforge'
 *
 * 参考：https://docs.curseforge.com/rest-api/#tocS_ModLoaderType
 */
export function toCurseForgeModLoaderType(loader: string): number {
  switch (loader.toLowerCase()) {
    case 'forge':       return 1;
    case 'liteloader':  return 3;
    case 'fabric':      return 4;
    case 'quilt':       return 5;
    case 'neoforge':    return 6;
    default:            return 0;
  }
}

export function fromCurseForgeModLoaderType(t: number): string {
  switch (t) {
    case 1: return 'forge';
    case 3: return 'liteloader';
    case 4: return 'fabric';
    case 5: return 'quilt';
    case 6: return 'neoforge';
    default: return '';
  }
}

// ============================================================
//  releaseType / relationType / sortField 数字编码
// ============================================================

/**
 * CurseForge file `releaseType` 数字 → VersionChannel。
 *   1 = Release  →  RELEASE
 *   2 = Beta     →  BETA
 *   3 = Alpha    →  ALPHA
 *   未知 → 保守回退 RELEASE（避免被排序误置后）
 */
export function parseCurseForgeReleaseType(t: number): VersionChannel {
  switch (t) {
    case 1: return VersionChannel.RELEASE;
    case 2: return VersionChannel.BETA;
    case 3: return VersionChannel.ALPHA;
    default: return VersionChannel.RELEASE;
  }
}

/**
 * CurseForge file dependency `relationType` 数字 → DependencyType。
 *   1 = EmbeddedLibrary    →  EMBEDDED   （已自带，UI 不提示）
 *   2 = OptionalDependency →  OPTIONAL
 *   3 = RequiredDependency →  REQUIRED
 *   4 = Tool               →  OPTIONAL   （工具类，按可选处理）
 *   5 = Incompatible       →  INCOMPATIBLE
 *   6 = Include            →  EMBEDDED   （和 Embedded 同义）
 */
export function parseCurseForgeRelationType(t: number): DependencyType {
  switch (t) {
    case 1: return DependencyType.EMBEDDED;
    case 2: return DependencyType.OPTIONAL;
    case 3: return DependencyType.REQUIRED;
    case 4: return DependencyType.OPTIONAL;
    case 5: return DependencyType.INCOMPATIBLE;
    case 6: return DependencyType.EMBEDDED;
    default: return DependencyType.OPTIONAL;
  }
}

/**
 * AMCL 抽象排序键 → CurseForge `sortField` 数字。
 *   1 = Featured    （RELEVANCE 时近似默认推荐）
 *   2 = Popularity  （FOLLOWS：CurseForge 没 followers，用人气分）
 *   3 = LastUpdated （NEWEST / UPDATED 都映射到此；CurseForge search 不暴露 date_created）
 *   4 = Name
 *   5 = Author
 *   6 = TotalDownloads（DOWNLOADS）
 *   7 = Category
 *   8 = GameVersion
 */
export function toCurseForgeSortField(s: SortBy): number {
  switch (s) {
    case SortBy.RELEVANCE:  return 1;
    case SortBy.FOLLOWS:    return 2;
    case SortBy.NEWEST:     return 3;
    case SortBy.UPDATED:    return 3;
    case SortBy.DOWNLOADS:  return 6;
    default:                return 6;
  }
}

// ============================================================
//  URL 构造结果
// ============================================================

export interface CFUrlSet {
  primary: string;
  mirrors: string[];
}

/**
 * 把可能为 null/undefined 的字符串归一化为"非空串或空串"。
 *
 * **为何需要**：mcim 镜像对 CurseForge 字段（尤其作者禁用分发时的 `downloadUrl`）会返回
 * JSON `null`（而非字段缺失）。ArkTS 里 `null !== undefined` 为 `true`，只判 `undefined`
 * 会让 `null` 漏过，随后访问 `.length` 抛 "Cannot read property length of null"。
 */
export function nonEmptyStr(v: string | undefined | null): string {
  return (v !== undefined && v !== null && v.length > 0) ? v : '';
}

/**
 * 元数据请求统一仅走 MCIM（无 mirrors）。
 * 调用方在 MCIM 不可用时由 Repository.isAvailable() 返回 false 即可。
 */
function makeMcimOnlyUrlSet(path: string, qs: string): CFUrlSet {
  return { primary: CURSEFORGE_API_MCIM + path + qs, mirrors: [] };
}

// ============================================================
//  URL 构造：/mods/search / /mods/{id} / /mods/{id}/files / /mods/{id}/files/{fid}
// ============================================================

/**
 * GET /mods/search 端点。
 *
 * 必传参数（CurseForge API 强制）：
 *   gameId      : 432
 *   classId     : 6 (Mod) / 12 (ResourcePack) / 6552 (Shader) / ...
 *   sortField   : 1..8（见 toCurseForgeSortField）
 *   sortOrder   : 'asc' / 'desc'
 *   index       : 0-based 偏移
 *   pageSize    : ≤ 50，且 (index + pageSize) ≤ 10000
 *
 * 可选过滤：
 *   searchFilter   : 关键词
 *   gameVersion    : "1.20.4"
 *   modLoaderType  : 0..6（0=Any 时建议省略）
 */
export function buildCurseForgeSearchUrl(
  query: string,
  classId: number,
  gameVersion: string | undefined,
  modLoaderType: number,
  sortField: number,
  sortOrderDesc: boolean,
  index: number,
  pageSize: number,
): CFUrlSet {
  let qs = '?gameId=' + CURSEFORGE_GAME_ID;
  qs += '&classId=' + classId;
  qs += '&sortField=' + sortField;
  qs += '&sortOrder=' + (sortOrderDesc ? 'desc' : 'asc');
  qs += '&index=' + index;
  qs += '&pageSize=' + pageSize;
  if (query.length > 0) {
    qs += '&searchFilter=' + encodeURIComponent(query);
  }
  if (gameVersion !== undefined && gameVersion.length > 0) {
    qs += '&gameVersion=' + encodeURIComponent(gameVersion);
  }
  if (modLoaderType !== 0) {
    qs += '&modLoaderType=' + modLoaderType;
  }
  return makeMcimOnlyUrlSet('/mods/search', qs);
}

/**
 * 按 slug 精确查 CurseForge 工程（用于"已知 slug、需解析数字 modId / 真实网址"的场景，
 * 如双源切换到 CurseForge 下载、打开 CF 页面）。CurseForge v1 search 支持 `slug` 过滤。
 *
 * **不带 classId**：跨源映射时资源在两站的分类可能不同（如 Iris 在 Modrinth 归 mod、
 * 在 CurseForge 也归 mc-mods，但有的资源两边分类不一致），带 classId 过滤会查不到。
 * gameId + slug 已足够唯一定位。
 */
export function buildCurseForgeSearchBySlugUrl(slug: string): CFUrlSet {
  let qs = '?gameId=' + CURSEFORGE_GAME_ID;
  qs += '&slug=' + encodeURIComponent(slug);
  qs += '&pageSize=20';
  return makeMcimOnlyUrlSet('/mods/search', qs);
}

/** GET /mods/{modId} */
export function buildCurseForgeProjectUrl(modId: string): CFUrlSet {
  return makeMcimOnlyUrlSet('/mods/' + encodeURIComponent(modId), '');
}

/**
 * GET /mods/{modId}/files
 *
 * 可选过滤同 search。pageSize 默认 50（CurseForge 单页上限）。
 */
export function buildCurseForgeFilesUrl(
  modId: string,
  gameVersion: string | undefined,
  modLoaderType: number,
  index: number,
  pageSize: number,
): CFUrlSet {
  let qs = '?index=' + index + '&pageSize=' + pageSize;
  if (gameVersion !== undefined && gameVersion.length > 0) {
    qs += '&gameVersion=' + encodeURIComponent(gameVersion);
  }
  if (modLoaderType !== 0) {
    qs += '&modLoaderType=' + modLoaderType;
  }
  return makeMcimOnlyUrlSet('/mods/' + encodeURIComponent(modId) + '/files', qs);
}

/** GET /mods/{modId}/files/{fileId} */
export function buildCurseForgeFileUrl(modId: string, fileId: string): CFUrlSet {
  let path = '/mods/' + encodeURIComponent(modId)
           + '/files/' + encodeURIComponent(fileId);
  return makeMcimOnlyUrlSet(path, '');
}

/**
 * GET /mods/{modId}/files/{fileId}/download-url
 *
 * 当 file.downloadUrl 为 null（部分作者禁用第三方下载）时调用，返回真实 CDN 链接。
 */
export function buildCurseForgeFileDownloadUrl(modId: string, fileId: string): CFUrlSet {
  let path = '/mods/' + encodeURIComponent(modId)
           + '/files/' + encodeURIComponent(fileId)
           + '/download-url';
  return makeMcimOnlyUrlSet(path, '');
}

// ============================================================
//  CDN URL 镜像化
// ============================================================

/**
 * 把 `https://edge.forgecdn.net/...` / `https://mediafilez.forgecdn.net/...`
 * 转成 `https://mod.mcimirror.top/...`。非已知 CDN 主机原样返回。
 */
export function mirrorifyCurseForgeCdn(url: string): string {
  for (let host of CURSEFORGE_CDN_HOSTS) {
    let prefix = 'https://' + host + '/';
    if (url.startsWith(prefix)) {
      return MCIM_CDN_PREFIX + url.substring(prefix.length);
    }
  }
  return url;
}

/**
 * 用 fileId 反推 CurseForge CDN 直链。
 *
 * **场景**：部分作者在 CurseForge 后台禁用第三方下载（`allowModDistribution=false`），
 * 此时 `/download-url` 端点与 file.downloadUrl 都返回空，但文件本身**仍在 CDN 上**。
 * CurseForge CDN 路径规律固定：
 *   id1 = floor(fileId / 1000)
 *   id2 = fileId % 1000
 *   https://edge.forgecdn.net/files/<id1>/<id2>/<fileName>
 *
 * 例：fileId=4671986 → /files/4671/986/<fileName>（与 mcim 实测路径吻合）。
 *
 * fileName 中的空格按 CDN 约定编码为 %20；其余字符保持原样（CurseForge CDN 不做额外编码）。
 */
export function buildForgeCdnUrlFromFileId(fileId: number, fileName: string): string {
  let id1 = Math.floor(fileId / 1000);
  let id2 = fileId % 1000;
  let encodedName = fileName.split(' ').join('%20');
  return 'https://edge.forgecdn.net/files/' + id1 + '/' + id2 + '/' + encodedName;
}

/**
 * 构造 RemoteFile 的下载 URL 列表（primary + mirrors）。
 *
 * 与 Modrinth 不同：CurseForge 不需要 Key 即可走 CDN，所以官方 CDN 永远是有效 fallback。
 * 默认策略：MCIM_FIRST = mcim 主、官方 CDN 备（与 Modrinth 一致）。
 *
 * 输入是空串则返回空 URL（调用方应再调 /download-url 端点重新解析）。
 */
export function buildCurseForgeFileDownloadUrls(officialUrl: string): CFUrlSet {
  if (officialUrl.length === 0) return { primary: '', mirrors: [] };
  let mcim = mirrorifyCurseForgeCdn(officialUrl);
  if (mcim === officialUrl) {
    // 不是已知 CDN 主机：MCIM 没镜像，只能走原 URL
    return { primary: officialUrl, mirrors: [] };
  }
  return { primary: mcim, mirrors: [officialUrl] };
}

// ============================================================
//  响应原始结构（CurseForge API v1）
// ============================================================
//
//  字段命名严格对照 docs.curseforge.com/rest-api/，保持 camelCase。
//  设为 export 便于单测精确构造 fixture。
//

export interface CFFileHashRaw {
  value: string;
  /** 1 = Sha1, 2 = Md5 */
  algo: number;
}

export interface CFFileDependencyRaw {
  modId: number;
  /** 1=EmbeddedLibrary, 2=Optional, 3=Required, 4=Tool, 5=Incompatible, 6=Include */
  relationType: number;
}

export interface CFSortableGameVersionRaw {
  gameVersionName: string;
  gameVersionPadded?: string;
  gameVersion?: string;
  gameVersionReleaseDate?: string;
  gameVersionTypeId?: number;
}

export interface CFFileRaw {
  id: number;
  modId: number;
  displayName: string;
  fileName: string;
  /** 1/2/3 — 见 parseCurseForgeReleaseType */
  releaseType: number;
  /** ISO-8601 时间串 */
  fileDate: string;
  fileLength: number;
  downloadCount: number;
  /** 部分作者禁用第三方分发时为 null/'' */
  downloadUrl?: string;
  /** 形如 ['1.20.4','Fabric'] — Fabric/Forge/Quilt 大写名混在版本里，需要拆分 */
  gameVersions: string[];
  sortableGameVersions?: CFSortableGameVersionRaw[];
  dependencies: CFFileDependencyRaw[];
  hashes: CFFileHashRaw[];
  isAvailable: boolean;
}

export interface CFFileIndexRaw {
  gameVersion: string;
  fileId: number;
  filename: string;
  releaseType: number;
  /** 0/1/4/5/6 — 0 表示 Any（可能根本不存在该字段） */
  modLoader?: number;
}

export interface CFCategoryRaw {
  id: number;
  name: string;
  slug: string;
  classId?: number;
}

export interface CFAuthorRaw {
  id: number;
  name: string;
  url?: string;
}

export interface CFLogoRaw {
  url: string;
}

export interface CFLinksRaw {
  websiteUrl?: string;
  sourceUrl?: string;
  issuesUrl?: string;
  wikiUrl?: string;
}

export interface CFModRaw {
  id: number;
  gameId: number;
  name: string;
  slug: string;
  summary: string;
  classId: number;
  downloadCount: number;
  thumbsUpCount?: number;
  primaryCategoryId?: number;
  categories: CFCategoryRaw[];
  authors: CFAuthorRaw[];
  logo?: CFLogoRaw;
  links?: CFLinksRaw;
  latestFilesIndexes: CFFileIndexRaw[];
  latestFiles?: CFFileRaw[];
  /** ISO-8601 */
  dateModified: string;
  dateReleased?: string;
  dateCreated?: string;
  isAvailable: boolean;
}

export interface CFPaginationRaw {
  index: number;
  pageSize: number;
  resultCount: number;
  totalCount: number;
}

export interface CFSearchResponseRaw {
  data: CFModRaw[];
  pagination: CFPaginationRaw;
}

export interface CFModResponseRaw {
  data: CFModRaw;
}

export interface CFFilesResponseRaw {
  data: CFFileRaw[];
  pagination: CFPaginationRaw;
}

export interface CFFileResponseRaw {
  data: CFFileRaw;
}

/** /mods/{id}/files/{fid}/download-url 响应：data 是字符串 */
export interface CFDownloadUrlResponseRaw {
  data: string;
}

/** POST /fingerprints 响应：exactMatches[].file 是命中的 CFFileRaw。 */
export interface CFFingerprintMatchRaw {
  id: number;
  file: CFFileRaw;
}
export interface CFFingerprintDataRaw {
  exactMatches: CFFingerprintMatchRaw[];
}
export interface CFFingerprintMatchesResponseRaw {
  data: CFFingerprintDataRaw;
}

// ============================================================
//  响应映射：Raw JSON → Domain 结构
// ============================================================

/** hashes[] → sha1 字符串；不存在则 null */
export function extractSha1FromCfHashes(hashes: CFFileHashRaw[]): string | null {
  for (let h of hashes) {
    if (h.algo === 1 && h.value.length > 0) return h.value;
  }
  return null;
}

/** hashes[] → md5 字符串；不存在则 null（algo=2） */
export function extractMd5FromCfHashes(hashes: CFFileHashRaw[]): string | null {
  for (let h of hashes) {
    if (h.algo === 2 && h.value.length > 0) return h.value;
  }
  return null;
}

/**
 * 从 sortableGameVersions / gameVersions 数组里拆出 loader 字符串和真实 MC 版本字符串。
 *
 * CurseForge 把 loader 和版本号塞在同一个 gameVersions 数组里：
 *   ["1.20.4", "Fabric", "Quilt"]  → loaders=['fabric','quilt'], gameVersions=['1.20.4']
 */
function extractLoadersFromGameVersions(arr: string[]): string[] {
  let loaders: string[] = [];
  for (let v of arr) {
    let lc = v.toLowerCase();
    if (lc === 'forge' || lc === 'fabric' || lc === 'quilt'
        || lc === 'neoforge' || lc === 'liteloader') {
      loaders.push(lc);
    }
  }
  return loaders;
}

/**
 * CurseForge 的 gameVersions 偶尔会塞入非 MC 版本号的字符串
 * （如 "Client"/"Server" 归类、loader 名、"Java 17" 等）。本正则过滤掉这些非 `x.y` 形态的串。
 *
 * ⚠️ 已知局限：纯数字形态的 mod 元数据版本（如 "6.0"）与真实 MC 版本（如 "1.20"）格式完全一致，
 * 正则无法区分，这类仍会漏进结果。影响很小（仅让项目展示的"支持 MC 版本"多出个别噪声项），
 * 暂不强行用版本上界硬编码区分（会与纪元判定逻辑耦合、且可能误伤真实版本）。
 */
const RE_MC_VERSION = /^\d+\.\d+(\.\d+)?(?:[-\w.]*)?$/;
function extractGameVersionsFromGameVersions(arr: string[]): string[] {
  let out: string[] = [];
  for (let v of arr) {
    if (RE_MC_VERSION.test(v)) {
      out.push(v);
    }
  }
  return out;
}

/** CFFile → RemoteFile（默认作为 primary） */
export function mapCurseForgeFile(file: CFFileRaw, isPrimary: boolean): RemoteFile {
  let officialUrl = nonEmptyStr(file.downloadUrl);
  let urls = buildCurseForgeFileDownloadUrls(officialUrl);
  let rf: RemoteFile = {
    url: urls.primary,
    mirrors: urls.mirrors,
    filename: file.fileName,
    size: file.fileLength,
    isPrimary,
  };
  let sha1 = extractSha1FromCfHashes(file.hashes);
  if (sha1 !== null) rf.sha1 = sha1;
  return rf;
}

/** CFFileDependency → RemoteDependency */
export function mapCurseForgeDependency(d: CFFileDependencyRaw): RemoteDependency {
  return {
    projectId: String(d.modId),
    dependencyType: parseCurseForgeRelationType(d.relationType),
  };
}

/** CFFile → RemoteVersion（同时映射 loader 拆分 + dependencies） */
export function mapCurseForgeFileAsVersion(file: CFFileRaw): RemoteVersion {
  let primary = mapCurseForgeFile(file, true);
  let deps: RemoteDependency[] = [];
  if (file.dependencies !== undefined) {
    for (let d of file.dependencies) deps.push(mapCurseForgeDependency(d));
  }
  let loaders = extractLoadersFromGameVersions(file.gameVersions);
  let gameVersions = extractGameVersionsFromGameVersions(file.gameVersions);
  return {
    source: ModSource.CURSEFORGE,
    id: String(file.id),
    projectId: String(file.modId),
    name: file.displayName,
    versionNumber: file.fileName,
    changelog: '',
    versionType: parseCurseForgeReleaseType(file.releaseType),
    gameVersions,
    loaders,
    files: [primary],
    dependencies: deps,
    datePublished: file.fileDate,
    downloads: file.downloadCount,
  };
}

/**
 * CFMod → RemoteProject。
 *
 * loader 推断：优先 latestFilesIndexes[].modLoader（CurseForge search 必给）；
 * 实在没有就从 latestFiles[].gameVersions 里扒（fallback）。
 *
 * gameVersions 推断：latestFilesIndexes[].gameVersion 去重后的数组。
 */
export function mapCurseForgeMod(mod: CFModRaw): RemoteProject {
  // ---------- loaders ----------
  let loaderSet: Set<string> = new Set<string>();
  if (mod.latestFilesIndexes !== undefined) {
    for (let idx of mod.latestFilesIndexes) {
      if (idx.modLoader !== undefined) {
        let l = fromCurseForgeModLoaderType(idx.modLoader);
        if (l.length > 0) loaderSet.add(l);
      }
    }
  }
  // 没拿到 → 从 latestFiles.gameVersions 兜底
  if (loaderSet.size === 0 && mod.latestFiles !== undefined) {
    for (let f of mod.latestFiles) {
      let ls = extractLoadersFromGameVersions(f.gameVersions);
      for (let l of ls) loaderSet.add(l);
    }
  }
  let loaders: string[] = [];
  loaderSet.forEach((l: string) => { loaders.push(l); });

  // ---------- gameVersions ----------
  let gvSet: Set<string> = new Set<string>();
  let gameVersions: string[] = [];
  if (mod.latestFilesIndexes !== undefined) {
    for (let idx of mod.latestFilesIndexes) {
      if (!gvSet.has(idx.gameVersion)) {
        gvSet.add(idx.gameVersion);
        gameVersions.push(idx.gameVersion);
      }
    }
  }

  // ---------- ResourceKind ----------
  let kind = fromCurseForgeClassId(mod.classId);
  if (kind === null) kind = ResourceKind.MOD;  // 保守回退

  // ---------- categories ----------
  let categories: string[] = [];
  if (mod.categories !== undefined) {
    for (let c of mod.categories) categories.push(c.slug);
  }

  // ---------- author / icon / website ----------
  let author = '';
  if (mod.authors !== undefined && mod.authors.length > 0) {
    author = mod.authors[0].name;
  }
  let iconUrl = '';
  if (mod.logo !== undefined && mod.logo !== null) iconUrl = mod.logo.url;
  let websiteUrl = '';
  // mcim 镜像会对部分字段返回 JSON null（非缺字段）；links 须同时判 null（同 1000234 的坑），
  // 否则 `null !== undefined` 为 true 后访问 .websiteUrl 抛 "Cannot read property of null"。
  if (mod.links !== undefined && mod.links !== null) {
    websiteUrl = nonEmptyStr(mod.links.websiteUrl);
  }

  return {
    source: ModSource.CURSEFORGE,
    id: String(mod.id),
    slug: mod.slug,
    kind,
    title: mod.name,
    summary: mod.summary,
    author,
    iconUrl,
    downloads: mod.downloadCount,
    follows: mod.thumbsUpCount !== undefined ? mod.thumbsUpCount : 0,
    categories,
    loaders,
    gameVersions,
    websiteUrl,
    dateModified: mod.dateModified,
  };
}

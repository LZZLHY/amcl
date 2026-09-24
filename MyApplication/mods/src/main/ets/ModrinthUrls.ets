/**
 * ModrinthUrls.ets — Modrinth API / CDN 的 URL 构造、facets 编码、响应映射（纯函数）
 *
 * P1-MODS Phase 1.2：拆出纯函数层，方便在 hvigor test 下直接单测，不依赖 HTTP。
 *
 * 文档：docs/guides/mod-download-system-plan.md §四.1 / §七.2
 *
 * 镜像规则（参见 mod.mcimirror.top 文档）：
 *   API:  `api.modrinth.com/v2/*`    → `mod.mcimirror.top/modrinth/v2/*`
 *   CDN:  `cdn.modrinth.com/*`        → `mod.mcimirror.top/*`
 *
 * 创建日期：2026-05-11
 */

import {
  ModSource,
  ResourceKind,
  VersionChannel,
  RemoteProject,
  RemoteVersion,
  RemoteFile,
  RemoteDependency,
  parseVersionChannel,
  parseDependencyType,
  toModrinthType,
} from './ModTypes';

// ============================================================
//  常量
// ============================================================

export const MODRINTH_API_OFFICIAL = 'https://api.modrinth.com/v2';
export const MODRINTH_API_MCIM = 'https://mod.mcimirror.top/modrinth/v2';
export const MODRINTH_CDN_OFFICIAL_PREFIX = 'https://cdn.modrinth.com/';
export const MCIM_CDN_PREFIX = 'https://mod.mcimirror.top/';

// ============================================================
//  源偏好
// ============================================================

export enum ModrinthSourceMode {
  /** 默认：MCIM 镜像优先，官方作为 fallback */
  MCIM_FIRST = 'mcim',
  /** 官方优先，MCIM 作为 fallback */
  OFFICIAL_FIRST = 'official',
}

// ============================================================
//  URL 构造结果（primary + mirrors）
// ============================================================

export interface UrlSet {
  primary: string;
  mirrors: string[];
}

function makeUrlSet(officialUrl: string, mcimUrl: string, mode: ModrinthSourceMode): UrlSet {
  if (mode === ModrinthSourceMode.MCIM_FIRST) {
    return { primary: mcimUrl, mirrors: [officialUrl] };
  }
  return { primary: officialUrl, mirrors: [mcimUrl] };
}

// ============================================================
//  facets 编码
// ============================================================

/**
 * 构造 Modrinth `facets` 参数（URL 未编码）。
 *
 * 规则：
 *   - kind → `project_type:<modrinth_type>`
 *   - loaders（仅 MOD/RESOURCE_PACK 以外尊重但通常为空）→ `categories:<loader>`
 *   - gameVersion → `versions:<ver>`
 *   - categories → `categories:<cat>`
 *
 * 输出是 `[["a"],["b"]]` 的 JSON 串，调用方自己做 `encodeURIComponent`。
 *
 * 注意：Modrinth 把 loaders 归并到 `categories` facet（不是独立 facet），
 * 这是 Modrinth v2 API 的历史设计。
 */
export function buildModrinthFacets(
  kind: ResourceKind,
  gameVersion?: string,
  loaders?: string[],
  categories?: string[],
): string {
  let groups: string[][] = [];
  // project_type
  groups.push(['project_type:' + toModrinthType(kind)]);
  // loader：MOD / 整合包 按 loader 过滤（resourcepack/shader/datapack 不依赖 loader）
  if ((kind === ResourceKind.MOD || kind === ResourceKind.MODPACK)
      && loaders !== undefined && loaders.length > 0) {
    let g: string[] = [];
    for (let l of loaders) {
      if (l.length === 0) continue;
      g.push('categories:' + l);
    }
    if (g.length > 0) groups.push(g);
  }
  // game version
  if (gameVersion !== undefined && gameVersion.length > 0) {
    groups.push(['versions:' + gameVersion]);
  }
  // 额外分类
  if (categories !== undefined && categories.length > 0) {
    for (let c of categories) {
      if (c.length === 0) continue;
      groups.push(['categories:' + c]);
    }
  }
  return JSON.stringify(groups);
}

// ============================================================
//  URL 构造：/search / /project / /version / /version_file
// ============================================================

/**
 * /search 端点。
 *   GET /v2/search?query=...&facets=...&index=<sort>&offset=...&limit=...
 *
 * index 值：relevance / downloads / follows / newest / updated（Modrinth 约定）
 */
export function buildSearchUrl(
  query: string,
  facetsJson: string,
  sortIndex: string,
  offset: number,
  limit: number,
  mode: ModrinthSourceMode,
): UrlSet {
  let qs = '?';
  qs += 'query=' + encodeURIComponent(query);
  qs += '&index=' + encodeURIComponent(sortIndex);
  qs += '&offset=' + offset;
  qs += '&limit=' + limit;
  if (facetsJson.length > 0 && facetsJson !== '[]') {
    qs += '&facets=' + encodeURIComponent(facetsJson);
  }
  return makeUrlSet(
    MODRINTH_API_OFFICIAL + '/search' + qs,
    MODRINTH_API_MCIM + '/search' + qs,
    mode,
  );
}

/** /project/{slug-or-id} */
export function buildProjectUrl(idOrSlug: string, mode: ModrinthSourceMode): UrlSet {
  let path = '/project/' + encodeURIComponent(idOrSlug);
  return makeUrlSet(MODRINTH_API_OFFICIAL + path, MODRINTH_API_MCIM + path, mode);
}

/**
 * /projects?ids=["a","b",...] —— 批量取工程（中文搜索按 slug 直取用）。
 * ids 既可传 project id 也可传 slug（Modrinth 两者都接受）。
 */
export function buildProjectsByIdsUrl(ids: string[], mode: ModrinthSourceMode): UrlSet {
  let qs = '?ids=' + encodeURIComponent(JSON.stringify(ids));
  return makeUrlSet(
    MODRINTH_API_OFFICIAL + '/projects' + qs,
    MODRINTH_API_MCIM + '/projects' + qs,
    mode,
  );
}

/**
 * /project/{id}/version?loaders=[]&game_versions=[]
 *
 * Modrinth 的 loaders / game_versions 是 URL-encoded JSON 字符串数组。
 */
export function buildVersionsUrl(
  projectId: string,
  loaders: string[] | undefined,
  gameVersions: string[] | undefined,
  mode: ModrinthSourceMode,
): UrlSet {
  let path = '/project/' + encodeURIComponent(projectId) + '/version';
  let qs = '';
  if (loaders !== undefined && loaders.length > 0) {
    qs += (qs.length === 0 ? '?' : '&') + 'loaders=' + encodeURIComponent(JSON.stringify(loaders));
  }
  if (gameVersions !== undefined && gameVersions.length > 0) {
    qs += (qs.length === 0 ? '?' : '&') + 'game_versions=' + encodeURIComponent(JSON.stringify(gameVersions));
  }
  return makeUrlSet(
    MODRINTH_API_OFFICIAL + path + qs,
    MODRINTH_API_MCIM + path + qs,
    mode,
  );
}

/** /version/{versionId} */
export function buildVersionUrl(versionId: string, mode: ModrinthSourceMode): UrlSet {
  let path = '/version/' + encodeURIComponent(versionId);
  return makeUrlSet(MODRINTH_API_OFFICIAL + path, MODRINTH_API_MCIM + path, mode);
}

/** /version_file/{sha1}?algorithm=sha1 */
export function buildVersionFileSha1Url(sha1: string, mode: ModrinthSourceMode): UrlSet {
  let path = '/version_file/' + encodeURIComponent(sha1) + '?algorithm=sha1';
  return makeUrlSet(MODRINTH_API_OFFICIAL + path, MODRINTH_API_MCIM + path, mode);
}

// ============================================================
//  CDN URL 镜像化
// ============================================================

/**
 * 把 `https://cdn.modrinth.com/...` 转成 `https://mod.mcimirror.top/...`。
 * 非 cdn.modrinth.com 的 URL 原样返回。
 *
 * 用途：ModrinthFile → RemoteFile 时合成下载备源（DownloadFileSpec.urls）。
 */
export function mirrorifyModrinthCdn(url: string): string {
  if (url.startsWith(MODRINTH_CDN_OFFICIAL_PREFIX)) {
    return MCIM_CDN_PREFIX + url.substring(MODRINTH_CDN_OFFICIAL_PREFIX.length);
  }
  return url;
}

/**
 * 构造 RemoteFile 的下载 URL 列表（primary + mirrors）：
 *   - mode=MCIM_FIRST → [mcimUrl, officialUrl]
 *   - mode=OFFICIAL_FIRST → [officialUrl, mcimUrl]
 *
 * 若非 cdn.modrinth.com 的 URL，只返回 [officialUrl]（MCIM 不镜像未知 CDN）。
 */
export function buildFileDownloadUrls(officialUrl: string, mode: ModrinthSourceMode): UrlSet {
  if (!officialUrl.startsWith(MODRINTH_CDN_OFFICIAL_PREFIX)) {
    return { primary: officialUrl, mirrors: [] };
  }
  let mcimUrl = mirrorifyModrinthCdn(officialUrl);
  if (mode === ModrinthSourceMode.MCIM_FIRST) {
    return { primary: mcimUrl, mirrors: [officialUrl] };
  }
  return { primary: officialUrl, mirrors: [mcimUrl] };
}

// ============================================================
//  响应映射：Raw JSON → Domain 结构
// ============================================================

// Raw 结构（对应 Modrinth API 响应）— 导出便于单测精确构造。
// 字段按 Modrinth v2 文档命名，保持 snake_case。

export interface ModrinthHitRaw {
  project_id: string;
  project_type: string;
  slug: string;
  title: string;
  description: string;
  categories: string[];
  display_categories: string[];
  versions: string[];
  downloads: number;
  follows: number;
  icon_url: string;
  author: string;
  date_modified: string;
}

export interface ModrinthProjectRaw {
  id: string;
  slug: string;
  project_type: string;
  title: string;
  description: string;
  categories: string[];
  additional_categories: string[];
  loaders: string[];
  game_versions: string[];
  downloads: number;
  followers: number;
  icon_url: string;
  team: string;
  source_url: string;
  issues_url: string;
  wiki_url: string;
  updated: string;
}

export interface ModrinthVersionRaw {
  id: string;
  project_id: string;
  name: string;
  version_number: string;
  changelog: string;
  version_type: string;
  game_versions: string[];
  loaders: string[];
  dependencies: ModrinthDependencyRaw[];
  files: ModrinthFileRaw[];
  date_published: string;
  downloads: number;
}

export interface ModrinthFileRaw {
  url: string;
  filename: string;
  primary: boolean;
  size: number;
  hashes: Record<string, string>;
  file_type?: string;
}

export interface ModrinthDependencyRaw {
  project_id?: string;
  version_id?: string;
  file_name?: string;
  dependency_type: string;
}

export interface ModrinthSearchResponseRaw {
  hits: ModrinthHitRaw[];
  offset: number;
  limit: number;
  total_hits: number;
}

// ---------- Hit → RemoteProject ----------

/**
 * Modrinth search hit → RemoteProject。
 *
 * Loader 拆分：Modrinth 把 loader 混在 `categories` 里。我们扫描已知 loader 名字
 * 拆出来到 RemoteProject.loaders，剩下的放 RemoteProject.categories。
 */
export function mapModrinthHit(h: ModrinthHitRaw): RemoteProject {
  let loaders: string[] = [];
  let realCategories: string[] = [];
  let known = KNOWN_LOADERS;
  // categories / versions 在 search 响应里几乎一定存在；但仍要防 null
  if (Array.isArray(h.categories)) {
    for (let c of h.categories) {
      if (known.has(c)) loaders.push(c);
      else realCategories.push(c);
    }
  }
  return {
    source: ModSource.MODRINTH,
    id: h.project_id,
    slug: h.slug,
    kind: mapModrinthProjectType(h.project_type),
    title: h.title,
    summary: h.description,
    author: typeof h.author === 'string' ? h.author : '',
    iconUrl: typeof h.icon_url === 'string' ? h.icon_url : '',
    downloads: typeof h.downloads === 'number' ? h.downloads : 0,
    follows: typeof h.follows === 'number' ? h.follows : 0,
    categories: realCategories,
    loaders,
    gameVersions: Array.isArray(h.versions) ? h.versions : [],
    websiteUrl: 'https://modrinth.com/' + h.project_type + '/' + h.slug,
    dateModified: typeof h.date_modified === 'string' ? h.date_modified : '',
  };
}

/** /project/{id} → RemoteProject（字段命名不同 hit，单独映射） */
export function mapModrinthProject(p: ModrinthProjectRaw): RemoteProject {
  let loaders: string[] = [];
  // /project 响应里 loaders 直接给出；但 categories 仍可能混 loader，做兜底。
  // Modrinth 偶尔返回 JSON null（特别是 additional_categories），用 Array.isArray 守卫。
  if (Array.isArray(p.loaders)) {
    for (let l of p.loaders) loaders.push(l);
  }
  let realCategories: string[] = [];
  let known = KNOWN_LOADERS;
  if (Array.isArray(p.categories)) {
    for (let c of p.categories) {
      if (!known.has(c)) realCategories.push(c);
    }
  }
  if (Array.isArray(p.additional_categories)) {
    for (let c of p.additional_categories) {
      if (!known.has(c)) realCategories.push(c);
    }
  }
  return {
    source: ModSource.MODRINTH,
    id: p.id,
    slug: p.slug,
    kind: mapModrinthProjectType(p.project_type),
    title: p.title,
    summary: p.description,
    author: typeof p.team === 'string' ? p.team : '',
    iconUrl: typeof p.icon_url === 'string' ? p.icon_url : '',
    downloads: typeof p.downloads === 'number' ? p.downloads : 0,
    follows: typeof p.followers === 'number' ? p.followers : 0,
    categories: realCategories,
    loaders,
    gameVersions: Array.isArray(p.game_versions) ? p.game_versions : [],
    websiteUrl: 'https://modrinth.com/' + p.project_type + '/' + p.slug,
    dateModified: typeof p.updated === 'string' ? p.updated : '',
  };
}

function mapModrinthProjectType(t: string): ResourceKind {
  switch (t) {
    case 'mod':          return ResourceKind.MOD;
    case 'resourcepack': return ResourceKind.RESOURCE_PACK;
    case 'shader':       return ResourceKind.SHADER;
    case 'datapack':     return ResourceKind.DATAPACK;
    case 'modpack':      return ResourceKind.MODPACK;
    default:             return ResourceKind.MOD;  // 保守回退
  }
}

// Modrinth 已知 loader 集合（用于从 categories 中拆分）
const KNOWN_LOADERS: Set<string> = new Set<string>([
  'fabric', 'forge', 'neoforge', 'quilt', 'liteloader',
  'modloader', 'rift', 'risugami\'s-modloader',
  'optifine',
  // 着色器加载器（Modrinth 把它当 loader 用）
  'iris', 'optifine-shader', 'canvas',
  // 资源包自家格式
  'minecraft',
]);

// ---------- Version → RemoteVersion ----------

export function mapModrinthVersion(v: ModrinthVersionRaw, mode: ModrinthSourceMode): RemoteVersion {
  // Modrinth 偶尔会把数组字段返回 JSON null（特别是 dependencies / loaders / game_versions），
  // 我们的 raw 类型签名是 array | undefined，但 null 既不等于 undefined 也不可迭代，
  // 直接 for-of null 会抛 "Cannot read property [Symbol.iterator] of null"。
  // 这里全部用 Array.isArray 守卫，行为等价于"undefined / null 视为空"。
  let files: RemoteFile[] = [];
  if (Array.isArray(v.files)) {
    for (let f of v.files) files.push(mapModrinthFile(f, mode));
  }
  let deps: RemoteDependency[] = [];
  if (Array.isArray(v.dependencies)) {
    for (let d of v.dependencies) deps.push(mapModrinthDependency(d));
  }
  let channel: VersionChannel = parseVersionChannel(v.version_type);
  return {
    source: ModSource.MODRINTH,
    id: v.id,
    projectId: v.project_id,
    name: typeof v.name === 'string' && v.name.length > 0 ? v.name : v.version_number,
    versionNumber: v.version_number,
    changelog: typeof v.changelog === 'string' ? v.changelog : '',
    versionType: channel,
    gameVersions: Array.isArray(v.game_versions) ? v.game_versions : [],
    loaders: Array.isArray(v.loaders) ? v.loaders : [],
    files,
    dependencies: deps,
    datePublished: typeof v.date_published === 'string' ? v.date_published : '',
    downloads: typeof v.downloads === 'number' ? v.downloads : 0,
  };
}

export function mapModrinthFile(f: ModrinthFileRaw, mode: ModrinthSourceMode): RemoteFile {
  // ⚠️ 2026-07-31：改为**遵循 ModSourceProber 实测出的 mode**。
  //
  // 此前这里收下 `mode` 参数却**完全不用**，硬写 `OFFICIAL_FIRST`（v7.2 依据是"mcim 的
  // /data/ 通道对热门大文件缓存未命中、卡死 0 字节"）。那个结论是某一天的单次观测，而
  // ModSourceProber 每次会话都真实测量两侧 RTT —— 把它的结论丢掉等于白测。
  //
  // 真机实证这个硬编码今天正在造成伤害（2026-07-31 00:20，sodium-neoforge 1.2MB）：
  //   探针：`Modrinth probe done: mode=mcim rttMcim=256 rttOfficial=708`  ← 判定镜像更快
  //   实际：`attempt begin: source=https://cdn.modrinth.com/...`          ← 官方仍在前
  //   结果：官方对本设备返回 **307 → cdn-alt.modrinth.com**，而设备 shell 裸 openssl 对
  //         cdn-alt 是 0 字节立即失败（`Failed to connect ... after 6001 ms`）；
  //         整个 1,204,654 字节最终花了 **104,309ms = 11.5KB/s**。
  //
  // 遵循 mode 后：探针说 mcim 更快就 mcim 优先、官方兜底；探针说官方更快就保持原行为。
  // 两个源都会进候选，只是顺序由实测决定，不再由一句写死的注释决定。
  // 注：CurseForge 文件不走这里（仍镜像 /files/ 优先，缓存命中快）。
  let urls = buildFileDownloadUrls(f.url, mode);
  let rf: RemoteFile = {
    url: urls.primary,
    mirrors: urls.mirrors,
    filename: f.filename,
    size: f.size,
    isPrimary: f.primary,
  };
  // hashes 字段：Modrinth 常给 {sha1, sha512}；偶尔为 null 或 undefined。
  if (f.hashes !== undefined && f.hashes !== null) {
    let s1 = f.hashes['sha1'];
    if (typeof s1 === 'string' && s1.length > 0) rf.sha1 = s1;
    let s5 = f.hashes['sha512'];
    if (typeof s5 === 'string' && s5.length > 0) rf.sha512 = s5;
  }
  return rf;
}

export function mapModrinthDependency(d: ModrinthDependencyRaw): RemoteDependency {
  let out: RemoteDependency = {
    dependencyType: parseDependencyType(d.dependency_type),
  };
  // Modrinth API 的 project_id / version_id / file_name 在未设置时返回 JSON null，
  // 不是 undefined。typeof null === 'object'，length 是属性访问，对 null 取属性会抛
  // "Cannot read property length of null"。所以这里必须先 typeof string 守卫。
  if (typeof d.project_id === 'string' && d.project_id.length > 0) out.projectId = d.project_id;
  if (typeof d.version_id === 'string' && d.version_id.length > 0) out.versionId = d.version_id;
  if (typeof d.file_name === 'string' && d.file_name.length > 0) out.fileName = d.file_name;
  return out;
}

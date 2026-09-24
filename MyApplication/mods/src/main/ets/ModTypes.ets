/**
 * ModTypes.ets — 模组下载子系统的核心类型与纯函数（P1-MODS Phase 1.1）
 *
 * 文档：docs/guides/mod-download-system-plan.md §六 / §七
 *
 * 设计要点：
 *   - 所有"枚举字符串"（source / dependencyType / versionType）使用 string-valued enum，
 *     与项目现有 `ModLoaderType` 风格一致，避开 ArkTS 严格模式对 union literal 的限制。
 *   - 仅放纯类型 + 无副作用纯函数：本文件不引入 fileIo / hilog / NAPI，
 *     便于在 hvigor test（Node v8 + hypium）下直接跑单元测试。
 *   - 路径函数返回值不带尾部斜杠，与 `MetadataCacheStore` / `FileUtils` 保持一致。
 *
 * 创建日期：2026-05-11
 */

// ============================================================
//  ResourceKind — 资源类型（mod / 资源包 / 光影 / 数据包 / 整合包）
// ============================================================

export enum ResourceKind {
  MOD = 'mod',
  RESOURCE_PACK = 'resourcepack',
  SHADER = 'shader',
  /** V2：数据包（需指定 world，仅声明，安装路径由 ModpackInstaller 单独处理） */
  DATAPACK = 'datapack',
  /** V3：整合包（解压 + 解析 manifest + 批量下载，由 ModpackInstaller 单独处理） */
  MODPACK = 'modpack',
}

/** 远程数据源 */
export enum ModSource {
  MODRINTH = 'modrinth',
  CURSEFORGE = 'curseforge',
}

/** 依赖关系类型（Modrinth + CurseForge 通用） */
export enum DependencyType {
  REQUIRED = 'required',
  OPTIONAL = 'optional',
  INCOMPATIBLE = 'incompatible',
  EMBEDDED = 'embedded',
}

/** 版本通道（release > beta > alpha） */
export enum VersionChannel {
  RELEASE = 'release',
  BETA = 'beta',
  ALPHA = 'alpha',
}

/**
 * 已装模组的「完整性 / 来源链接」状态（LocalModScanner 计算，InstalledResourcesSheet 展示）。
 *
 * 判定原则：**"损坏"只能对有可信基准哈希(安装清单)的模组下结论；无基准只能是 UNKNOWN，绝不判损坏。**
 */
export enum ModIntegrity {
  /** 有安装清单基准；日常快检 size 一致 / 全量校验 sha1 一致 → 完好。 */
  VERIFIED = 'verified',
  /** 无清单但经反查(sha1 / CF fingerprint)命中源已链接(导入模组被收编)，等同可信、可检查更新。 */
  LINKED = 'linked',
  /** 有清单基准 + 全量校验 sha1 不符 + 当前哈希反查不到任何源版本 → 判定损坏(可一键修复)。 */
  CORRUPT = 'corrupt',
  /** 无清单且反查不到源 → 未知来源：不可检查更新，**绝不判损坏**。 */
  UNKNOWN = 'unknown',
  /** 有清单但 size 与期望不符、尚未全量哈希确认(日常快检中间态，提示用户"校验完整性")。 */
  RECHECK = 'recheck',
}

// ============================================================
//  RemoteProject / RemoteVersion / RemoteFile / RemoteDependency
// ============================================================

/**
 * 远程项目元数据（一个 mod / 资源包 / 光影 / 整合包，跨源结构统一）。
 *
 * 字段对照：
 *   - Modrinth: project_id / slug / project_type / categories / loaders /
 *     versions / icon_url / downloads / followers / updated
 *   - CurseForge: id / slug / classId / categories / latestFilesIndexes 推 loader
 */
export interface RemoteProject {
  source: ModSource;
  /** Modrinth project_id（base62 短串） / CurseForge modId（数字字符串化） */
  id: string;
  /** 全小写、跨源使用 normalizeSlug 归一化后用于去重的标识 */
  slug: string;
  kind: ResourceKind;
  title: string;
  /** 简介（首段或 description 字段） */
  summary: string;
  author: string;
  iconUrl: string;
  downloads: number;
  follows: number;
  /** 不含 loader（loader 单独字段） */
  categories: string[];
  /** ['fabric', 'forge', 'neoforge', 'quilt'] 子集 */
  loaders: string[];
  /** 项目支持的所有 MC 版本字符串 */
  gameVersions: string[];
  /** 用户点击"打开网页"跳转的 URL（项目主页） */
  websiteUrl: string;
  /** ISO-8601 / RFC-3339 时间串（"2024-02-10T03:14:15.926Z"） */
  dateModified: string;

  /**
   * 中文译名（由 ModTranslationStore 在搜索后回填）。
   * 形如 "工业时代2 (Industrial Craft 2)"；未命中翻译库时为 undefined。
   */
  chineseName?: string;
  /**
   * MC 百科条目 id（命中翻译库时 > 0）。用于排序时的"有中文名"加分 + 拼 mcmod 网址。
   */
  wikiId?: number;
  /**
   * 译名库登记的 CurseForge / Modrinth 原始 slug（命中翻译库时回填）。
   * 用于"打开网页"时跨源跳转（项目本身只属于一个源，另一源的网址靠它拼）。
   */
  cfSlug?: string;
  mrSlug?: string;
  /**
   * 跨源合并发现的"另一数据源"信息（同一资源同时存在于 Modrinth + CurseForge 时，
   * mergeProjects 把被去重掉的那一源的 source/id/slug 挂到保留项上）。
   * 用于：详情页双源标签、按源下载（切到另一源重新拉版本）。
   * altId 是该源的真实工程 id（CurseForge 数字串 / Modrinth base62），可直接喂 getVersions。
   */
  altSource?: ModSource;
  altId?: string;
  altSlug?: string;
}

/**
 * 取项目的展示标题：命中中文译名优先，否则用原始英文标题。
 * UI（ModCard / ModDetailSheet）统一通过本函数取标题，避免各处重复判空。
 */
export function displayTitleOf(p: RemoteProject): string {
  if (p.chineseName !== undefined && p.chineseName.length > 0) return p.chineseName;
  return p.title;
}

// ============================================================
//  纯函数：资源网站 URL 构造（"打开网页" / 跨源跳转 / mcmod 百科）
// ============================================================

/** MC 百科（mcmod.cn）条目页 URL；wikiId<=0 返回空串 */
export function mcmodClassUrl(wikiId: number): string {
  if (wikiId <= 0) return '';
  return 'https://www.mcmod.cn/class/' + wikiId + '.html';
}

/** ResourceKind → Modrinth 网站路径段 */
function modrinthWebSegment(kind: ResourceKind): string {
  switch (kind) {
    case ResourceKind.MOD:           return 'mod';
    case ResourceKind.RESOURCE_PACK: return 'resourcepack';
    case ResourceKind.SHADER:        return 'shader';
    case ResourceKind.DATAPACK:      return 'datapack';
    case ResourceKind.MODPACK:       return 'modpack';
    default:                         return 'mod';
  }
}

/** ResourceKind → CurseForge 网站路径段 */
function curseforgeWebSegment(kind: ResourceKind): string {
  switch (kind) {
    case ResourceKind.MOD:           return 'mc-mods';
    case ResourceKind.RESOURCE_PACK: return 'texture-packs';
    case ResourceKind.SHADER:        return 'shaders';
    case ResourceKind.DATAPACK:      return 'data-packs';
    case ResourceKind.MODPACK:       return 'modpacks';
    default:                         return 'mc-mods';
  }
}

/** 由 kind + slug 拼 Modrinth 工程页 URL；slug 空返回空串 */
export function modrinthWebUrl(kind: ResourceKind, slug: string): string {
  if (slug.length === 0) return '';
  return 'https://modrinth.com/' + modrinthWebSegment(kind) + '/' + slug;
}

/** 由 kind + slug 拼 CurseForge 工程页 URL；slug 空返回空串 */
export function curseforgeWebUrl(kind: ResourceKind, slug: string): string {
  if (slug.length === 0) return '';
  return 'https://www.curseforge.com/minecraft/' + curseforgeWebSegment(kind) + '/' + slug;
}

/** 单文件版本（一个 mod 的一个版本，可能含多文件如 sources.jar，但通常 primary 唯一） */
export interface RemoteVersion {
  source: ModSource;
  id: string;
  projectId: string;
  /** 显示名（"0.5.8 (1.20.4)"） */
  name: string;
  /** 数字版本号（"0.5.8"） */
  versionNumber: string;
  /** 变更日志原文（可能含 markdown） */
  changelog: string;
  versionType: VersionChannel;
  gameVersions: string[];
  loaders: string[];
  files: RemoteFile[];
  dependencies: RemoteDependency[];
  /** ISO-8601 时间串 */
  datePublished: string;
  /** 该版本的累计下载数（部分源给 0） */
  downloads: number;
}

export interface RemoteFile {
  /** 主下载 URL（CDN 直链；Modrinth: cdn.modrinth.com；CurseForge: edge.forgecdn.net） */
  url: string;
  /** 备源（mcim 镜像 URL 等），与 url 一起组成 DownloadFileSpec.urls */
  mirrors: string[];
  filename: string;
  /** Modrinth 总有；CurseForge 看 hashes[] 是否含 sha1 */
  sha1?: string;
  /** Modrinth 总有；CurseForge 通常缺 */
  sha512?: string;
  /** CurseForge 专属 Murmur2 fingerprint（V2 反查时用） */
  fingerprint?: number;
  size: number;
  /** 是否为该版本的主分发文件（true 表示 UI 默认下载它） */
  isPrimary: boolean;
}

export interface RemoteDependency {
  /** 任一源都至少给 projectId / versionId / fileName 之一 */
  projectId?: string;
  versionId?: string;
  fileName?: string;
  dependencyType: DependencyType;
}

// ============================================================
//  本地模组（LocalModScanner 输出，ModListPage / Resolver 消费）
// ============================================================

export interface LocalMod {
  filePath: string;
  filename: string;
  /** .jar = true ; .jar.disabled = false */
  enabled: boolean;
  sizeBytes: number;
  /** 用于反查 Modrinth `/version_files` */
  sha1: string;

  // ManifestParser 解析后字段（缺失时 ModListPage 仅显示文件名）
  modid?: string;
  name?: string;
  version?: string;
  description?: string;
  author?: string;
  /** modid 列表（fabric.mod.json depends 字段 / mods.toml dependencies） */
  dependencies?: string[];

  // ModUpdateChecker 写入字段
  remoteSource?: ModSource;
  remoteProjectId?: string;
  remoteSlug?: string;
  /**
   * sha1 反查命中的具体远端版本 id（如 Modrinth `J3HzDe2P`）。
   * Phase 3 LocalModScanner 写入；ModDetailSheet picker step 用它在版本列表中
   * 标记已装行（"已装"灰 chip），并禁止重选当前已装版本。
   */
  remoteVersionId?: string;
  latestVersion?: RemoteVersion;
  hasUpdate?: boolean;

  // ===== 完整性 / 来源链接（LocalModScanner + InstalledModIndex 写入）=====
  /** 是否有安装清单基准（经本启动器下载 / 反查命中后被收编）。 */
  managed?: boolean;
  /** 安装清单里的权威期望 sha1（判损坏的基准）。 */
  expectedSha1?: string;
  /** 完整性/来源状态。缺省视为 UNKNOWN。 */
  integrity?: ModIntegrity;
}

// ============================================================
//  纯函数 1：资源类型 ↔ Modrinth/CurseForge 映射
// ============================================================

/** Modrinth project_type 字符串 → ResourceKind；未知返回 null */
export function fromModrinthType(t: string): ResourceKind | null {
  switch (t) {
    case 'mod':           return ResourceKind.MOD;
    case 'resourcepack':  return ResourceKind.RESOURCE_PACK;
    case 'shader':        return ResourceKind.SHADER;
    case 'datapack':      return ResourceKind.DATAPACK;
    case 'modpack':       return ResourceKind.MODPACK;
    default:              return null;
  }
}

/** ResourceKind → Modrinth project_type 字符串（用于构造 facets） */
export function toModrinthType(kind: ResourceKind): string {
  switch (kind) {
    case ResourceKind.MOD:           return 'mod';
    case ResourceKind.RESOURCE_PACK: return 'resourcepack';
    case ResourceKind.SHADER:        return 'shader';
    case ResourceKind.DATAPACK:      return 'datapack';
    case ResourceKind.MODPACK:       return 'modpack';
    default:                         return 'mod';
  }
}

/** CurseForge classId → ResourceKind；未知返回 null */
export function fromCurseForgeClassId(id: number): ResourceKind | null {
  switch (id) {
    case 6:    return ResourceKind.MOD;
    case 12:   return ResourceKind.RESOURCE_PACK;
    case 6552: return ResourceKind.SHADER;
    case 6945: return ResourceKind.DATAPACK;
    case 4471: return ResourceKind.MODPACK;
    default:   return null;
  }
}

/** ResourceKind → CurseForge classId（用于 search 端点 query 参数） */
export function toCurseForgeClassId(kind: ResourceKind): number {
  switch (kind) {
    case ResourceKind.MOD:           return 6;
    case ResourceKind.RESOURCE_PACK: return 12;
    case ResourceKind.SHADER:        return 6552;
    case ResourceKind.DATAPACK:      return 6945;
    case ResourceKind.MODPACK:       return 4471;
    default:                         return 6;
  }
}

// ============================================================
//  纯函数 2：版本通道字符串映射
// ============================================================

/** Modrinth version_type ('release'/'beta'/'alpha') → enum；CurseForge releaseType
 *  数字映射为 1=release / 2=beta / 3=alpha，由仓库适配器自行先转字符串再调本函数。 */
export function parseVersionChannel(s: string): VersionChannel {
  switch (s) {
    case 'release': return VersionChannel.RELEASE;
    case 'beta':    return VersionChannel.BETA;
    case 'alpha':   return VersionChannel.ALPHA;
    default:        return VersionChannel.RELEASE;
  }
}

// ============================================================
//  纯函数 3：依赖类型字符串映射
// ============================================================

/** Modrinth dependency_type / CurseForge relationType 字符串 → enum */
export function parseDependencyType(s: string): DependencyType {
  switch (s) {
    case 'required':     return DependencyType.REQUIRED;
    case 'optional':     return DependencyType.OPTIONAL;
    case 'incompatible': return DependencyType.INCOMPATIBLE;
    case 'embedded':     return DependencyType.EMBEDDED;
    default:             return DependencyType.OPTIONAL;
  }
}

// ============================================================
//  纯函数 4：安装目录解析
// ============================================================

/**
 * 计算资源在磁盘上的安装目录（不含尾部斜杠，不创建实际目录）。
 *
 * 行为：
 *   - versionIsolation = true：`<mcDir>/versions/<versionId>/<sub>`
 *   - versionIsolation = false：`<mcDir>/<sub>`
 *   - sub 来自资源类型（mod=mods / resourcepack=resourcepacks / shader=shaderpacks）
 *
 * DATAPACK / MODPACK 抛出错误（V2/V3 由 ModpackInstaller 单独处理）。
 *
 * @param mcDir       .minecraft 根目录绝对路径，不带尾部 `/`，如 `/data/storage/.../.minecraft`
 * @param versionId   当前选中的已装版本 id（如 `1.20.4-fabric-0.16.10`）
 * @param versionIsolation  PreferenceManager.versionIsolation（默认 true）
 */
export function resourceKindToInstallDir(
  kind: ResourceKind,
  mcDir: string,
  versionId: string,
  versionIsolation: boolean,
): string {
  let base: string;
  if (versionIsolation) {
    if (versionId.length === 0) {
      throw new Error('resourceKindToInstallDir: versionId required when versionIsolation=true');
    }
    base = mcDir + '/versions/' + versionId;
  } else {
    base = mcDir;
  }
  switch (kind) {
    case ResourceKind.MOD:           return base + '/mods';
    case ResourceKind.RESOURCE_PACK: return base + '/resourcepacks';
    case ResourceKind.SHADER:        return base + '/shaderpacks';
    case ResourceKind.DATAPACK:
      throw new Error('datapack 安装需指定 world，留待 V2 实现');
    case ResourceKind.MODPACK:
      throw new Error('modpack 走 ModpackInstaller.installAsNewVersion');
    default:
      throw new Error('unknown ResourceKind: ' + (kind as string));
  }
}

// ============================================================
//  纯函数 5：跨源 slug 归一化（双源合并去重）
// ============================================================

/**
 * 把 slug 归一为跨源比较的稳定 key：
 *   - 全小写
 *   - 去前缀 `mc-` / `minecraft-`
 *   - 去后缀 `-fabric` / `-forge` / `-neoforge` / `-quilt` / `-mod`
 *
 * 例：
 *   `Sodium`           → `sodium`
 *   `sodium-fabric`    → `sodium`
 *   `mc-just-enough-items` → `just-enough-items`
 *   `JEI-Mod`          → `jei`（小写后去 `-mod`）
 *
 * 注意：只去一次前缀和一次后缀，避免对真实名字的过度剥离（如 `mod-menu` 仅去后缀变 `menu`，
 * 这是预期行为；该 mod 的官方 slug 是 `modmenu`，不会冲突）。
 */
export function normalizeSlug(slug: string): string {
  if (slug.length === 0) return '';
  let s = slug.toLowerCase();
  // 去前缀（只剥一层）
  if (s.startsWith('mc-')) {
    s = s.substring(3);
  } else if (s.startsWith('minecraft-')) {
    s = s.substring(10);
  }
  // 去后缀（只剥一层；注意顺序：长后缀优先，避免 `-neoforge` 被 `-forge` 误剥）
  const suffixes: string[] = ['-neoforge', '-fabric', '-forge', '-quilt', '-mod'];
  for (let suf of suffixes) {
    if (s.length > suf.length && s.endsWith(suf)) {
      s = s.substring(0, s.length - suf.length);
      break;
    }
  }
  return s;
}

// ============================================================
//  纯函数 6：选主分发文件
// ============================================================

/**
 * 从 RemoteVersion.files 选用户应该下载的那个文件：
 *   1. 优先 `isPrimary=true` 的第一个；
 *   2. 否则取 size 最大的（去掉 `-sources.jar` / `-javadoc.jar` 噪声）；
 *   3. 空数组 → 返回 null。
 *
 * 该函数不假设 files 已排序，保证 stable: 输入相同 → 输出相同。
 */
export function pickPrimaryFile(files: RemoteFile[]): RemoteFile | null {
  if (files.length === 0) return null;
  // 1. 主文件
  for (let f of files) {
    if (f.isPrimary) return f;
  }
  // 2. 过滤掉常见非主文件后取 size 最大
  let candidates: RemoteFile[] = [];
  for (let f of files) {
    let n = f.filename.toLowerCase();
    if (n.endsWith('-sources.jar') || n.endsWith('-javadoc.jar') || n.endsWith('-dev.jar')) {
      continue;
    }
    candidates.push(f);
  }
  let pool = candidates.length > 0 ? candidates : files;
  let best = pool[0];
  for (let i = 1; i < pool.length; i++) {
    if (pool[i].size > best.size) best = pool[i];
  }
  return best;
}

// ============================================================
//  纯函数 7：跨源合并去重
// ============================================================

/**
 * 把 Modrinth + CurseForge 的搜索结果合并成单一列表：
 *   - 按 normalizeSlug 去重（同 slug 只保留先出现的那个）
 *   - Modrinth 永远排在 CurseForge 之前传入，从而 Modrinth 优先（覆盖率好 + sha1 全）
 *   - 不做排序：调用方按 downloads/follows/updated 自定排序
 *
 * 复杂度 O(m + c)；用 Set<string> 而非 Map 节省内存（仅判断"是否已见"）。
 */
export function mergeProjects(
  modrinth: RemoteProject[],
  curseforge: RemoteProject[],
): RemoteProject[] {
  let byKey: Map<string, RemoteProject> = new Map<string, RemoteProject>();
  let result: RemoteProject[] = [];
  for (let p of modrinth) {
    let key = normalizeSlug(p.slug);
    if (key.length === 0) continue;
    if (byKey.has(key)) continue;
    byKey.set(key, p);
    result.push(p);
  }
  for (let p of curseforge) {
    let key = normalizeSlug(p.slug);
    if (key.length === 0) continue;
    let kept = byKey.get(key);
    if (kept !== undefined) {
      // 跨源同名：把被去重的另一源信息挂到保留项（供详情页双源标签 / 按源下载用）
      if (kept.source !== p.source && kept.altSource === undefined) {
        kept.altSource = p.source;
        kept.altId = p.id;
        kept.altSlug = p.slug;
      }
      continue;
    }
    byKey.set(key, p);
    result.push(p);
  }
  return result;
}

// ============================================================
//  纯函数 8：版本通道排序键
// ============================================================

/**
 * release(0) < beta(1) < alpha(2)，用于"优先 release"的排序。
 * 复用：ModDependencyResolver 选默认推荐版本时按此键升序找最小（即 release）。
 */
export function versionChannelRank(c: VersionChannel): number {
  switch (c) {
    case VersionChannel.RELEASE: return 0;
    case VersionChannel.BETA:    return 1;
    case VersionChannel.ALPHA:   return 2;
    default:                     return 3;
  }
}

// ============================================================
//  纯函数 9：模组版本「新旧」统一判定（单一事实源）
// ============================================================

/** 把版本号拆成「字母段 / 数字段」的 token 序列（PCL2 CompareVersion 同款）。 */
function modVersionTokens_(s: string): string[] {
  let m = s.toLowerCase().match(/[a-z]+|[0-9]+/g);
  return m === null ? [] : m;
}

/**
 * 单个 token 的可比较数值：
 *   - 纯数字 → 其数值（>= 0）
 *   - 预发布词按"越早越小"映射为负数（release 段缺省=0，故 release > 任何预发布）
 *   - 其他字母 token → 0（落到字符串比较兜底）
 */
function modTokenValue_(t: string): number {
  if (/^[0-9]+$/.test(t)) return Number.parseInt(t, 10);
  switch (t) {
    case 'rc':           return -1;
    case 'pre':          return -2;
    case 'snapshot':     return -3;
    case 'experimental': return -4;
    case 'beta':         return -5;
    case 'alpha':        return -6;
    default:             return 0;
  }
}

/**
 * 比较两个模组版本号字符串的新旧（PCL2 CompareVersion 同款语义）。
 * 返回 >0 = a 更新，<0 = a 更旧，0 = 等同/无法判定。
 *
 * 例：('0.9.1','0.8.12')>0；('0.9.1','0.9.1-beta.2')>0（正式 > beta）；('1.21.1','1.21')>0。
 */
export function compareModVersionNumber(a: string, b: string): number {
  let xs = modVersionTokens_(a);
  let ys = modVersionTokens_(b);
  let n = Math.max(xs.length, ys.length);
  for (let i = 0; i < n; i++) {
    let xt = i < xs.length ? xs[i] : '0';
    let yt = i < ys.length ? ys[i] : '0';
    if (xt === yt) continue;
    let xv = modTokenValue_(xt);
    let yv = modTokenValue_(yt);
    if (xv === 0 && yv === 0) {
      // 两边都是无法识别的字母 token → 字符串比较兜底
      return xt > yt ? 1 : -1;
    }
    if (xv !== yv) return xv > yv ? 1 : -1;
  }
  return 0;
}

/**
 * 模组版本「新旧」的**统一判定**（下载页选最新 / 模组管理查更新 共用，杜绝两处分叉）：
 *   1. 主键：版本号（compareModVersionNumber）—— 0.9.1 永远比 0.8.12 新，与日期无关；
 *   2. 同版本号再比 datePublished（镜像把日期戳成一样时不影响主键判定）。
 * 返回 >0 = a 更新。
 */
export function compareModVersionFreshness(a: RemoteVersion, b: RemoteVersion): number {
  let c = compareModVersionNumber(a.versionNumber, b.versionNumber);
  if (c !== 0) return c;
  if (a.datePublished > b.datePublished) return 1;
  if (a.datePublished < b.datePublished) return -1;
  return 0;
}

/** 优先稳定通道（release > beta > alpha），同通道按版本号/日期选新版本。 */
export function pickLatestModVersion(versions: RemoteVersion[]): RemoteVersion | null {
  if (versions.length === 0) return null;
  let channel = 3;
  for (const version of versions) channel = Math.min(channel, versionChannelRank(version.versionType));
  const candidates = versions.filter((v: RemoteVersion): boolean => versionChannelRank(v.versionType) === channel);
  let best = candidates[0];
  for (let i = 1; i < candidates.length; i++) {
    if (compareModVersionFreshness(candidates[i], best) > 0) best = candidates[i];
  }
  return best;
}

/**
 * ModSourceRouter.ets — 多数据源路由器（P1-MODS Phase 2.2）
 *
 * 文档：docs/guides/mod-download-system-plan.md §七.4
 *
 * 职责：
 *   - **search**：并发查询所有可用数据源，结果合并 + 跨源 slug 去重 + 重排
 *   - **repoFor(source)**：按 RemoteProject.source 拿到对应仓库（用于 getVersions / getProject）
 *   - **isAvailable**：任一源可用即真
 *
 * 容错策略：
 *   - 任一源失败 **不阻塞** 另一源（仿 Promise.allSettled，ArkTS 下用 then/catch 包装）
 *   - 全部源失败 → 抛 ModRepoError（保留首个错误）
 *   - 没有可用源（isAvailable 全 false）→ 抛 NETWORK 错
 *
 * 排序策略：
 *   - 合并后按 SortBy 重排（与单源结果不同：单源已排序但跨源插入会乱序）
 *   - DOWNLOADS / FOLLOWS：数字降序
 *   - NEWEST / UPDATED：dateModified 字符串降序（ISO-8601 字典序 = 时间序）
 *   - RELEVANCE：保持各源相对顺序，跨源按 round-robin 交错（避免某源刷屏）
 *
 * 创建日期：2026-05-11
 */

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { toSimplifiedChinese } from 'commons';
import {
  ModSource,
  ResourceKind,
  RemoteProject,
  RemoteVersion,
  mergeProjects,
} from './ModTypes';
import {
  IRemoteModRepository,
  SearchOptions,
  SearchResult,
  SortBy,
  ModRepoError,
  ModRepoErrorKind,
} from './RemoteModRepository';
import { ModTranslationStore, isChineseText, ChineseSearchResolution, searchSimilarity } from './ModTranslation';

const TAG = 'ModSourceRouter';

// ============================================================
//  内部类型
// ============================================================

interface SearchSettled {
  source: ModSource;
  ok: boolean;
  result: SearchResult | null;
  error: Error | null;
}

// ============================================================
//  ModSourceRouter
// ============================================================

export class ModSourceRouter implements IRemoteModRepository {
  /** 取首个仓库的 source，仅为满足 IRemoteModRepository.source 字段 — 实际无具体意义 */
  readonly source: ModSource;

  private repos_: IRemoteModRepository[];
  /** 模组译名库（moddata-amcl.txt）：mod / 资源包 / 光影 / 数据包 用 */
  private modStore_: ModTranslationStore | null;
  /** 整合包译名库（modpackdata-amcl.txt）：仅整合包用，避免与模组库交叉错配 */
  private modpackStore_: ModTranslationStore | null;

  /**
   * @param repos  仓库列表（先后顺序决定 slug 冲突优先级）。
   * @param modStore      可选模组译名库（注入后启用中文搜索 + 译名回填 + 双源）。
   * @param modpackStore  可选整合包译名库（同上，仅作用于整合包搜索）。
   */
  constructor(
    repos: IRemoteModRepository[],
    modStore?: ModTranslationStore,
    modpackStore?: ModTranslationStore,
  ) {
    if (repos.length === 0) {
      throw new Error('ModSourceRouter requires at least one IRemoteModRepository');
    }
    this.repos_ = repos;
    this.source = repos[0].source;
    this.modStore_ = modStore !== undefined ? modStore : null;
    this.modpackStore_ = modpackStore !== undefined ? modpackStore : null;
  }

  /** 运行期注入 / 替换译名库（UI 异步加载完成后回填）。两库分别按资源类型生效。 */
  setTranslationStores(
    modStore: ModTranslationStore | null,
    modpackStore: ModTranslationStore | null,
  ): void {
    this.modStore_ = modStore;
    this.modpackStore_ = modpackStore;
  }

  /** 按资源类型选译名库：整合包→整合包库，其余→模组库 */
  private storeFor(kind: ResourceKind): ModTranslationStore | null {
    return kind === ResourceKind.MODPACK ? this.modpackStore_ : this.modStore_;
  }

  isAvailable(): boolean {
    for (let r of this.repos_) {
      if (r.isAvailable()) return true;
    }
    return false;
  }

  /**
   * 按 RemoteProject.source 拿对应仓库；找不到返回 null。
   *
   * 调用方在拿到 RemoteProject 后、做 getVersions/getProject 等"已知源"操作时，
   * 应通过本方法路由，而不是落到本类的 IRemoteModRepository 实现。
   */
  repoFor(source: ModSource): IRemoteModRepository | null {
    for (let r of this.repos_) {
      if (r.source === source) return r;
    }
    return null;
  }

  /** 暴露所有源（UI 选择"仅 Modrinth"等场景用） */
  allRepos(): IRemoteModRepository[] {
    return this.repos_.slice();
  }

  // ============================================================
  //  search — 双源合并
  // ============================================================

  async search(opt: SearchOptions): Promise<SearchResult> {
    let actives: IRemoteModRepository[] = [];
    for (let r of this.repos_) {
      if (r.isAvailable()) actives.push(r);
    }
    if (actives.length === 0) {
      throw new ModRepoError(this.source, ModRepoErrorKind.NETWORK,
        '没有可用的数据源（CA bundle 未就绪 / MCIM 健康检查失败）');
    }

    // 中文搜索：把中文关键词解析成英文关键词再投喂两源（Modrinth/CurseForge 不索引中文）。
    // 按资源类型选译名库（整合包用整合包库，其余用模组库）
    let store = this.storeFor(opt.kind);

    // 繁→简归一 → 解析各源英文关键词 + Modrinth 直取 slug（PCL 同款：多候选 + 按 slug 直取）。
    // relevanceQuery 用于最终相关度排序：中文时用归一后的中文词（与 enrich 的中文名比对）。
    let hasCjk = opt.query.length > 0 && isChineseText(opt.query);
    let isChinese = store !== null && hasCjk;
    let relevanceQuery = opt.query;
    let resolution: ChineseSearchResolution | null = null;
    if (isChinese && store !== null) {
      let normQuery = toSimplifiedChinese(opt.query).trim();
      relevanceQuery = normQuery;
      resolution = store.resolveChineseSearch(normQuery);
      AppLogger.info(TAG,
        `中文搜索解析："${opt.query}" → cf="${resolution.cfKeyword}" mr="${resolution.mrKeyword}" slugs=${resolution.mrSlugs.length}`,
        LOG_DOMAIN_DOWNLOAD);
    }

    // 并发跑：每源可能贡献两条 settled（关键词搜索 + Modrinth 按 slug 直取）。
    // 用 then/catch 包成统一 SearchSettled，避免 Promise.allSettled 在 ArkTS 上的辨别难题。
    let pending: Promise<SearchSettled>[] = [];
    for (let r of actives) {
      let src = r.source;
      // 决定本源的关键词 / 是否直取
      let effQuery = opt.query;
      let runKeyword = true;
      let directSlugs: string[] = [];
      if (isChinese && resolution !== null) {
        if (src === ModSource.MODRINTH) {
          effQuery = resolution.mrKeyword;
          // 直取仅首页；上限 40（覆盖同名系列足够，避免 100 个 slug 的巨型请求拖慢首屏）
          if (opt.offset === 0) directSlugs = resolution.mrSlugs.slice(0, 40);
        } else if (src === ModSource.CURSEFORGE) {
          effQuery = resolution.cfKeyword;
        } else {
          effQuery = '';
        }
        runKeyword = effQuery.length > 0;
      }
      // 关键词搜索
      if (runKeyword) {
        let kwOpt = (isChinese && resolution !== null) ? cloneOptWithQuery(opt, effQuery) : opt;
        pending.push(this.settledOf_(src, r.search(kwOpt)));
      }
      // Modrinth 按 slug 直取（仅中文 + 首页 + 该源支持批量取）
      if (directSlugs.length > 0 && r.getProjectsByIds !== undefined) {
        pending.push(this.settledOf_(src, this.directHits_(r, directSlugs, opt)));
      }
    }

    if (pending.length === 0) {
      // 中文但两源都无关键词/直取 slug → 优雅返回空结果（UI 提示"请尝试英文名"）
      return { hits: [], totalHits: 0, offset: opt.offset, pageSize: opt.pageSize };
    }

    let settled = await Promise.all(pending);

    // 收集成功结果 + 记录失败
    let perSource: RemoteProject[][] = [];
    let totalHits = 0;
    let firstErr: Error | null = null;
    for (let s of settled) {
      if (s.ok && s.result !== null) {
        perSource.push(s.result.hits);
        totalHits += s.result.totalHits;
      } else if (s.error !== null) {
        let msg = s.error.message !== undefined ? s.error.message : String(s.error);
        AppLogger.warn(TAG, `source ${s.source} failed: ${msg}`, null, LOG_DOMAIN_DOWNLOAD);
        if (firstErr === null) firstErr = s.error;
      }
    }
    if (perSource.length === 0) {
      // 全军覆没：抛首个错（已带 source 信息）
      if (firstErr instanceof ModRepoError) throw firstErr;
      throw ModRepoError.fromUnknown(this.source,
        firstErr !== null ? firstErr as Object : 'all sources failed');
    }

    // 合并去重（按 slug 归一化；保留先到 source）
    let merged: RemoteProject[];
    if (perSource.length === 1) {
      merged = perSource[0];
    } else {
      merged = perSource[0];
      for (let i = 1; i < perSource.length; i++) {
        merged = mergeProjects(merged, perSource[i]);
      }
    }

    // 译名回填（命中翻译库的项写入 chineseName / wikiId / 跨源 slug；就地修改共享引用）。
    // 放在排序之前，使 RELEVANCE 评分能用到"有中文名"加分。
    if (store !== null) {
      for (let p of merged) store.enrich(p);
      // 跨源按 mcmod 百科 id 合并：Modrinth/CurseForge slug 不同（如 iris / irisshaders）
      // 时 mergeProjects 的 slug 去重配不上对，但同一 wikiId 即同一资源 → 折叠成一行，
      // 并把被折叠那一源的**真实 id/slug** 挂为 alt（按源下载/打开页面无需再猜 slug）。
      merged = dedupCrossSource(merged);
    }

    // 重排：
    //   - 中文搜索：**强制**按"名称相似度(主导) + 下载量对数 + 中文名加分"排序（对齐 PCL），
    //     忽略用户的下载量/更新排序选择——否则高下载的无关 mod(如小地图)会淹没相关结果。
    //   - 非中文多源：按用户 sortBy 跨源重排；非中文单源：保持源端排序。
    if (isChinese) {
      merged = merged.slice().sort((a: RemoteProject, b: RemoteProject): number => {
        let sb = scoreChineseRelevance(b, relevanceQuery, opt.kind);
        let sa = scoreChineseRelevance(a, relevanceQuery, opt.kind);
        if (sb > sa) return 1;
        if (sb < sa) return -1;
        return weightedDownloads(b, opt.kind) - weightedDownloads(a, opt.kind);
      });
    } else if (perSource.length > 1) {
      merged = sortMergedHits(merged, opt.sortBy, perSource, opt.kind, relevanceQuery);
    }

    // totalHits 是各源之和，去重后实际可能更少；仅作"约 N 条"提示用
    let adjustedTotalHits = totalHits;
    if (perSource.length > 1) {
      let deduped = merged.length;
      let raw = 0;
      for (let arr of perSource) raw += arr.length;
      if (raw > 0 && deduped < raw) {
        adjustedTotalHits = Math.round(totalHits * deduped / raw);
      }
    }
    return {
      hits: merged,
      totalHits: adjustedTotalHits,
      offset: opt.offset,
      pageSize: opt.pageSize,
    };
  }

  /** 把返回 SearchResult 的 promise 包成 SearchSettled（then/catch 归一，失败不阻塞其他源）。 */
  private settledOf_(src: ModSource, p: Promise<SearchResult>): Promise<SearchSettled> {
    return p.then((sr: SearchResult): SearchSettled => {
      let s: SearchSettled = { source: src, ok: true, result: sr, error: null };
      return s;
    }).catch((e: Error): SearchSettled => {
      let s: SearchSettled = { source: src, ok: false, result: null, error: e };
      return s;
    });
  }

  /** Modrinth 按 slug 直取 → 包装成 SearchResult（totalHits=命中数，仅首页用）。 */
  private async directHits_(r: IRemoteModRepository, slugs: string[], opt: SearchOptions): Promise<SearchResult> {
    let hits = await r.getProjectsByIds!(slugs);
    return { hits: hits, totalHits: hits.length, offset: 0, pageSize: opt.pageSize };
  }

  // ============================================================
  //  其余 IRemoteModRepository 方法 — 不带 source 信息时按 fallback 逐个试
  // ============================================================

  /**
   * 不带 source 时按 repos 顺序试 getProject。第一个成功即返回。
   * **正确用法**是 `router.repoFor(project.source).getProject(...)`，本方法仅作兜底。
   */
  async getProject(idOrSlug: string): Promise<RemoteProject> {
    return this.fallback<RemoteProject>(
      'getProject',
      (r: IRemoteModRepository) => r.getProject(idOrSlug),
    );
  }

  async getVersions(
    projectId: string,
    loaders?: string[],
    gameVersions?: string[],
  ): Promise<RemoteVersion[]> {
    return this.fallback<RemoteVersion[]>(
      'getVersions',
      (r: IRemoteModRepository) => r.getVersions(projectId, loaders, gameVersions),
    );
  }

  async getVersion(versionId: string): Promise<RemoteVersion> {
    return this.fallback<RemoteVersion>(
      'getVersion',
      (r: IRemoteModRepository) => r.getVersion(versionId),
    );
  }

  /** 通用 fallback：按 repos 顺序逐个试，记录最后一个错误 */
  private async fallback<T>(
    op: string,
    invoke: (r: IRemoteModRepository) => Promise<T>,
  ): Promise<T> {
    let lastErr: Error | null = null;
    for (let r of this.repos_) {
      if (!r.isAvailable()) continue;
      try {
        return await invoke(r);
      } catch (e) {
        lastErr = e as Error;
        let msg = lastErr.message !== undefined ? lastErr.message : String(e);
        AppLogger.info(TAG, `fallback ${op} on ${r.source} failed: ${msg}; trying next`, LOG_DOMAIN_DOWNLOAD);
      }
    }
    if (lastErr !== null) {
      if (lastErr instanceof ModRepoError) throw lastErr;
      throw ModRepoError.fromUnknown(this.source, lastErr as Object);
    }
    throw new ModRepoError(this.source, ModRepoErrorKind.NETWORK,
      'No available repository for ' + op);
  }
}

// ============================================================
//  排序：合并后跨源重排
// ============================================================

/**
 * 跨源下载量归一化权重。
 *
 * CurseForge 与 Modrinth 的下载量量纲差异巨大（同一资源 CF 计数常是 Modrinth 数倍），
 * 直接比原始 downloads 会让 CF 永远霸榜。这里按资源类型给两源不同乘数抹平差异
 * （对照 PCL `ResourceSearcher.GetDownloadCountMult`）。
 *
 * kind 缺省（旧调用方）时返回 1，保持纯下载量比较的向后兼容。
 */
export function downloadMult(kind: ResourceKind | undefined, source: ModSource): number {
  if (kind === undefined) return 1;
  let cf = source === ModSource.CURSEFORGE;
  switch (kind) {
    case ResourceKind.MOD:
    case ResourceKind.MODPACK:        return cf ? 1 : 5;
    case ResourceKind.DATAPACK:       return cf ? 10 : 1;
    case ResourceKind.RESOURCE_PACK:
    case ResourceKind.SHADER:         return cf ? 1 : 4;
    default:                          return 1;
  }
}

/** 加权下载量 */
function weightedDownloads(p: RemoteProject, kind: ResourceKind | undefined): number {
  return p.downloads * downloadMult(kind, p.source);
}

/**
 * 文本相似度（轻量启发式，无需依赖外部分词器）：
 *   完全相等 → 1；包含整串 → 0.85；按词命中比例 → 0~0.7；都不沾 → 0。
 */
function textSimilarity(query: string, target: string): number {
  let q = query.trim().toLowerCase();
  let t = target.trim().toLowerCase();
  if (q.length === 0 || t.length === 0) return 0;
  if (t === q) return 1;
  if (t.indexOf(q) >= 0) return 0.85;
  let words = q.split(/\s+/);
  if (words.length === 0) return 0;
  let matched = 0;
  for (let w of words) {
    if (w.length > 0 && t.indexOf(w) >= 0) matched++;
  }
  return 0.7 * matched / words.length;
}

/**
 * 相关度排序分（对照 PCL：相似度 + 下载量对数 + 有中文名加分）。
 *   = max(标题/中文名/slug 的相似度)  [0~1]
 *   + log10(max(加权下载量,1)) / 9      [≈0~1，10 亿下载约 1 分]
 *   + (命中翻译库 ? 0.2 : 0)
 */
export function scoreRelevance(
  p: RemoteProject,
  query: string,
  kind: ResourceKind | undefined,
): number {
  let simTitle = textSimilarity(query, p.title);
  let simSlug = textSimilarity(query, p.slug.replace(/-/g, ' '));
  let simCn = p.chineseName !== undefined ? textSimilarity(query, p.chineseName) : 0;
  let sim = Math.max(simTitle, Math.max(simSlug, simCn));

  let dl = Math.log10(Math.max(weightedDownloads(p, kind), 1)) / 9;
  let cnBonus = (p.wikiId !== undefined && p.wikiId > 0) ? 0.2 : 0;
  return sim + dl + cnBonus;
}

/** 取一个工程用于中文相似度比对的别名集合：中文名括号前按 '/' 拆；无中文名回退英文标题。 */
function chineseAliasesOf(p: RemoteProject): string[] {
  let name = (p.chineseName !== undefined && p.chineseName.length > 0) ? p.chineseName : p.title;
  let idx = name.indexOf(' (');
  let head = idx >= 0 ? name.substring(0, idx) : name;
  let parts: string[] = head.split('/').map((x: string) => x.trim()).filter((x: string) => x.length > 0);
  return parts.length > 0 ? parts : [name];
}

/**
 * 中文搜索专用相关度分（对齐 PCL 的 Score）：
 *   = searchSimilarity(query, 中文名别名)   [主导项，精确匹配可达 ~2+，远超下载量]
 *   + log10(加权下载量)/9                    [≈0~1，做量级微调 / 同相似度时的排序]
 *   + (命中翻译库 ? 0.2 : 0)
 * 用移植自 PCL 的 searchSimilarity（而非上限仅 1 的 textSimilarity），保证"名称匹配"稳压
 * "高下载但无关"的结果。用户混输英文时也兼顾英文标题 / slug 的相似度。
 */
export function scoreChineseRelevance(
  p: RemoteProject,
  query: string,
  kind: ResourceKind | undefined,
): number {
  let sim = 0;
  for (let a of chineseAliasesOf(p)) {
    let s = searchSimilarity(a, query);
    if (s > sim) sim = s;
  }
  // 兼顾英文标题 / slug（用户可能中英混输；纯中文时这两项为 0）
  let simEn = Math.max(
    searchSimilarity(p.title, query),
    searchSimilarity(p.slug.split('-').join(' '), query));
  if (simEn > sim) sim = simEn;

  let dl = Math.log10(Math.max(weightedDownloads(p, kind), 1)) / 9;
  let cnBonus = (p.wikiId !== undefined && p.wikiId > 0) ? 0.2 : 0;
  return sim + dl + cnBonus;
}

/**
 * 跨源合并后重排。
 *
 * - DOWNLOADS：按**加权**下载量降序（抹平 CF/Modrinth 量纲差异）
 * - FOLLOWS：按 follows 降序
 * - NEWEST / UPDATED：按 dateModified 字符串降序（ISO-8601 字典序 = 时间序）
 * - RELEVANCE：
 *     · 有搜索词 → 按 scoreRelevance 降序（相似度 + 下载量对数 + 中文名加分）
 *     · 无搜索词 → 保持各源相对顺序，跨源 round-robin 交错，避免单源刷屏
 *
 * @param kind   资源类型，用于下载量加权；缺省时不加权（向后兼容旧测试）
 * @param query  当前（已做中文改写的）搜索词，用于 RELEVANCE 评分；缺省/空串退化为 round-robin
 *
 * 注意：传入的 `merged` 已经做过 slug 去重；本函数不修改长度。
 */
export function sortMergedHits(
  merged: RemoteProject[],
  sortBy: SortBy,
  perSource: RemoteProject[][],
  kind?: ResourceKind,
  query?: string,
): RemoteProject[] {
  if (sortBy === SortBy.DOWNLOADS) {
    let copy = merged.slice();
    copy.sort((a: RemoteProject, b: RemoteProject) =>
      weightedDownloads(b, kind) - weightedDownloads(a, kind));
    return copy;
  }
  if (sortBy === SortBy.FOLLOWS) {
    let copy = merged.slice();
    copy.sort((a: RemoteProject, b: RemoteProject) => b.follows - a.follows);
    return copy;
  }
  if (sortBy === SortBy.NEWEST || sortBy === SortBy.UPDATED) {
    let copy = merged.slice();
    copy.sort((a: RemoteProject, b: RemoteProject) => {
      if (b.dateModified > a.dateModified) return 1;
      if (b.dateModified < a.dateModified) return -1;
      return 0;
    });
    return copy;
  }
  // RELEVANCE
  let q = query !== undefined ? query.trim() : '';
  if (q.length > 0) {
    // 有搜索词：按相关度分降序；同分时按加权下载量兜底，保证稳定。
    let copy = merged.slice();
    copy.sort((a: RemoteProject, b: RemoteProject) => {
      let sb = scoreRelevance(b, q, kind);
      let sa = scoreRelevance(a, q, kind);
      if (sb > sa) return 1;
      if (sb < sa) return -1;
      return weightedDownloads(b, kind) - weightedDownloads(a, kind);
    });
    return copy;
  }
  // 无搜索词：round-robin 交错保留各源相对位置，并跳过已被去重过滤掉的项
  return roundRobinInterleave(perSource, merged);
}

/**
 * 把 perSource 数组按 round-robin 取出来，但只保留出现在 keep 集合内的项。
 *
 * keep 集合用 `source + ':' + id` 作 key（与 mergeProjects 内部去重键一致）。
 */
function roundRobinInterleave(
  perSource: RemoteProject[][],
  keep: RemoteProject[],
): RemoteProject[] {
  let keepSet: Set<string> = new Set<string>();
  for (let p of keep) keepSet.add(p.source + ':' + p.id);

  let result: RemoteProject[] = [];
  let cursors: number[] = [];
  for (let i = 0; i < perSource.length; i++) cursors.push(0);

  let total = keep.length;
  while (result.length < total) {
    let pushedThisRound = false;
    for (let i = 0; i < perSource.length; i++) {
      let arr = perSource[i];
      while (cursors[i] < arr.length) {
        let cand = arr[cursors[i]];
        cursors[i]++;
        let key = cand.source + ':' + cand.id;
        if (keepSet.has(key)) {
          result.push(cand);
          keepSet.delete(key);  // 避免重复推同一项
          pushedThisRound = true;
          break;
        }
      }
    }
    if (!pushedThisRound) break;  // 所有 cursor 都到尽头
  }
  return result;
}

/** 克隆 SearchOptions 但替换 query（用于中文搜索改写，避免修改调用方对象） */
function cloneOptWithQuery(opt: SearchOptions, query: string): SearchOptions {
  let o: SearchOptions = {
    query,
    kind: opt.kind,
    sortBy: opt.sortBy,
    offset: opt.offset,
    pageSize: opt.pageSize,
  };
  if (opt.gameVersion !== undefined) o.gameVersion = opt.gameVersion;
  if (opt.loaders !== undefined) o.loaders = opt.loaders;
  if (opt.categories !== undefined) o.categories = opt.categories;
  return o;
}

/**
 * 跨源折叠重复项（按 mcmod 库给出的"两站 slug 对"作规范键）。
 *
 * 背景：mergeProjects 只能按归一化 slug 去重，但同一资源两站 slug 常不同
 * （Iris=iris / irisshaders）。enrich 命中库条目时会把该条目登记的 cfSlug + mrSlug
 * **都**写到项目上；因此"两站 slug 对"对同一资源的两行是一致的 → 用它作规范键折叠。
 *
 * 不再用 wikiId（行号）作键：补充库条目的 id 置 0、且行号会与主库 class id 撞号，
 * 用 slug 对更稳。仅当项目同时带 cfSlug + mrSlug（库确知两源）时才参与折叠。
 *
 * 折叠规则：保留先出现的（merge 顺序：Modrinth 优先），把被折叠那一源的**真实 id/slug**
 * 挂为保留项的 alt（覆盖 enrich 设的 slug-only alt，使按源下载/打开页面拿到真实 id）。
 */
function dedupCrossSource(merged: RemoteProject[]): RemoteProject[] {
  let byKey: Map<string, RemoteProject> = new Map<string, RemoteProject>();
  let result: RemoteProject[] = [];
  for (let p of merged) {
    let key = canonicalModKey(p);
    if (key.length === 0) {
      result.push(p);
      continue;
    }
    let kept = byKey.get(key);
    if (kept === undefined) {
      byKey.set(key, p);
      result.push(p);
    } else if (kept.source !== p.source) {
      // 同一资源的另一源行：挂真实 id/slug 为 alt（升级 enrich 的 slug-only alt），丢弃该行
      kept.altSource = p.source;
      kept.altId = p.id;
      kept.altSlug = p.slug;
    }
    // kept.source === p.source（同源重复）→ 直接丢弃 p
  }
  return result;
}

/** 规范模组键：仅当库确知两源 slug 时返回 "cf\u0000mr"（小写），否则空串（不参与折叠）。 */
function canonicalModKey(p: RemoteProject): string {
  if (p.cfSlug !== undefined && p.cfSlug.length > 0
      && p.mrSlug !== undefined && p.mrSlug.length > 0) {
    return p.cfSlug.toLowerCase() + '\u0000' + p.mrSlug.toLowerCase();
  }
  return '';
}

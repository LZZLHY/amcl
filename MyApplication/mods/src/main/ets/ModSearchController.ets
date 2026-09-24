/**
 * ModSearchController.ets — 模组搜索页业务逻辑控制器（P1-MODS Phase 1.6）
 *
 * 文档：docs/guides/mod-download-system-plan.md §八.2
 *
 * 职责：
 *   - 封装 "类别 / 搜索词 / MC 版本 / Loader / 排序 / 分页" 这套可变状态
 *   - 调用 IRemoteModRepository.search 并合并分页结果
 *   - 管理 in-flight 标记防止重复请求；用户输入去抖由 UI 层负责
 *   - 纯逻辑层，**不** import UI Kit —— 便于 hypium 单测（Node v8 下运行）
 *
 * 典型 UI 绑定：
 *   ctrl.setQuery('sodium')
 *   ctrl.setKind(ResourceKind.MOD)
 *   ctrl.setGameVersion('1.20.4')
 *   ctrl.setLoader('fabric')
 *   await ctrl.loadFirstPage()        // 首次搜索，清空 hits
 *   await ctrl.loadNextPage()         // 用户滚到底部时加载下一页
 *
 * 创建日期：2026-05-11
 */

import {
  ResourceKind,
  RemoteProject,
  ModSource,
} from './ModTypes';
import {
  IRemoteModRepository,
  SearchOptions,
  SearchResult,
  SortBy,
  ModRepoErrorKind,
  ModRepoErrorFacts,
  describeModRepoError,
} from './RemoteModRepository';

/**
 * 控制器输出状态（不可变快照，由 controller.getState() 返回）。
 * UI 层每次查询后做 shallow copy 塞入 @State，拒绝直接持有 controller 实例。
 */
export interface ModSearchState {
  kind: ResourceKind;
  query: string;
  gameVersion: string;
  /** 单选 loader，为空表示不过滤；UI 常见选项：fabric / forge / neoforge / quilt */
  loader: string;
  sortBy: SortBy;

  /** 已累积的结果（多页拼接） */
  hits: RemoteProject[];
  /** 远端声明的总结果数（可能略大于 hits.length，因为还没加载完） */
  totalHits: number;
  /** 下一页起始 offset（首次为 0） */
  nextOffset: number;
  /** 是否还有更多数据可加载 */
  hasMore: boolean;

  /** 加载中标记（loadFirstPage / loadNextPage 期间为 true） */
  loading: boolean;
  /** 最后一次错误消息（null 表示无错误）。⚠️ 只给人看，**不得**用它做判定。 */
  errorMessage: string | null;

  // —— 批次 D2：结构化失败分类。产品早就有这个答案，过去在 catch 块里被压成了一句 message。
  //    没有它，DNS 失败 / 429 限流 / 5xx / JSON 解析失败在状态里完全不可区分，
  //    而这四者的处置完全不同（契约 §4.1 / §4.3 的第 4 层）。
  /** 失败分类（null 表示无错误） */
  errorKind: ModRepoErrorKind | null;
  /** 失败归属到哪个源（null = 无错误，或抛出方不在仓库层） */
  errorSource: ModSource | null;
  /** HTTP 状态码；0 表示不适用。`http_client` + 429 才能认出限流 */
  httpStatus: number;

  // —— 批次 D6-3：回显实际请求体。
  /**
   * 最后一次真正发出的 `SearchOptions`（`buildSearchOptions` 的产物）。
   *
   * ⭐ 它解决 §3.4 那个顺序敏感陷阱：`setKind(k)` 在 k∉{MOD,MODPACK} 时会清空 loader，
   * 于是"过滤没生效"与"过滤按契约被丢弃"在结果里长得一模一样。回显实际请求体之后
   * 两者才可区分 —— 不回显的搜索报告无法支撑任何关于过滤的结论。
   */
  lastRequest: SearchOptions | null;
}

// ============================================================
//  默认值
// ============================================================

const DEFAULT_PAGE_SIZE = 20;

export function makeInitialSearchState(): ModSearchState {
  return {
    kind: ResourceKind.MOD,
    query: '',
    gameVersion: '',
    loader: '',
    sortBy: SortBy.DOWNLOADS,
    hits: [],
    totalHits: 0,
    nextOffset: 0,
    hasMore: true,
    loading: false,
    errorMessage: null,
    errorKind: null,
    errorSource: null,
    httpStatus: 0,
    lastRequest: null,
  };
}

// ============================================================
//  纯函数：构造 SearchOptions
// ============================================================

/**
 * 从 state + 分页参数构造 SearchOptions。
 * 纯函数，便于单测 + UI 预览 request body。
 */
export function buildSearchOptions(
  state: ModSearchState,
  offset: number,
  pageSize: number,
): SearchOptions {
  let loaders: string[] = [];
  if (state.loader.length > 0
      && (state.kind === ResourceKind.MOD || state.kind === ResourceKind.MODPACK)) {
    loaders.push(state.loader);
  }
  let opt: SearchOptions = {
    query: state.query,
    kind: state.kind,
    sortBy: state.sortBy,
    offset,
    pageSize,
  };
  if (state.gameVersion.length > 0) opt.gameVersion = state.gameVersion;
  if (loaders.length > 0) opt.loaders = loaders;
  return opt;
}

/**
 * 按失败分类给用户一句**有区分度**的话（批次 D2-3）。
 *
 * 纯函数（无 UI Kit 依赖）⇒ 可单独喂样本，UI 只负责显示返回值。
 *
 * 顺带解决一处真实的用户可见缺陷：在此之前 `http_client` 429（被上游限流，等一会就好）
 * 与 `network`（本机根本没网）对用户是**同一句**"网络异常"，于是用户会去重启路由器。
 *
 * ⚠️ 这里出现中文是对的：机器可读的 id 在 `state.errorKind` 里，文案是它的**派生显示**。
 * 反过来做（状态里只存中文）才是契约 §2.3 要禁的形状 —— 那样 agent 会去匹配中文串。
 */
export function describeSearchFailureForUser(
  kind: ModRepoErrorKind | null,
  httpStatus: number,
  fallbackMessage: string,
): string {
  if (kind === null) return fallbackMessage;
  if (kind === ModRepoErrorKind.NETWORK) {
    return '连不上服务器。请检查网络连接后重试。';
  }
  if (kind === ModRepoErrorKind.HTTP_CLIENT) {
    if (httpStatus === 429) return '请求过于频繁，被服务器限流了。等待一会儿再试即可。';
    if (httpStatus === 403 || httpStatus === 401) return '服务器拒绝了本次请求（可能需要更换下载源）。';
    if (httpStatus === 404) return '这个接口在上游不存在了。';
    return `请求被拒绝（HTTP ${httpStatus}）。`;
  }
  if (kind === ModRepoErrorKind.HTTP_SERVER) {
    return `上游服务器出错（HTTP ${httpStatus}），通常稍后会自行恢复。`;
  }
  if (kind === ModRepoErrorKind.PARSE) {
    // 这一层才是产品缺陷：上游改了响应结构，AMCL 需要跟着改（契约 §4.3 第 4 层）。
    return '上游返回的数据格式无法识别，可能是接口改版了。这是 AMCL 需要修复的问题。';
  }
  if (kind === ModRepoErrorKind.UNSUPPORTED) {
    return '当前数据源不支持这个操作。';
  }
  return fallbackMessage;
}

/**
 * 在已有 hits 上追加新一页 hits，保持去重（按 source+id 复合键）。
 * 纯函数：不修改输入数组，返回新数组。
 */
export function mergePagedHits(
  existing: RemoteProject[],
  incoming: RemoteProject[],
): RemoteProject[] {
  let seen: Set<string> = new Set<string>();
  for (let p of existing) seen.add(p.source + ':' + p.id);
  let result: RemoteProject[] = [];
  for (let p of existing) result.push(p);
  for (let p of incoming) {
    let key = p.source + ':' + p.id;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(p);
  }
  return result;
}

// ============================================================
//  ModSearchController 类
// ============================================================

export class ModSearchController {
  private repo_: IRemoteModRepository;
  private state_: ModSearchState = makeInitialSearchState();
  private pageSize_: number;
  /** 用于打断陈旧请求：query/kind 等变化时 ++epoch，响应到达时对比 epoch */
  private epoch_: number = 0;
  /** 用户是否手动选过排序；未选过时按"有无搜索词"自动切默认排序（对照 PCL） */
  private sortExplicit_: boolean = false;

  constructor(repo: IRemoteModRepository, pageSize: number = DEFAULT_PAGE_SIZE) {
    this.repo_ = repo;
    this.pageSize_ = pageSize;
  }

  /** 当前状态只读快照（UI 层 shallow copy 后塞入 @State） */
  getState(): ModSearchState {
    return {
      kind: this.state_.kind,
      query: this.state_.query,
      gameVersion: this.state_.gameVersion,
      loader: this.state_.loader,
      sortBy: this.state_.sortBy,
      hits: this.state_.hits.slice(),
      totalHits: this.state_.totalHits,
      nextOffset: this.state_.nextOffset,
      hasMore: this.state_.hasMore,
      loading: this.state_.loading,
      // ⚠️ 这份快照是**逐字段手写**的：漏拷一个新字段的表现是"它永远为 null"，
      // 而那看起来完全正常 —— 没有任何编译错误、没有运行期异常、报告照常输出。
      // ⇒ 单测一律**穿过 getState() 断言**，不读内部状态（批次 D2-6）。
      errorMessage: this.state_.errorMessage,
      errorKind: this.state_.errorKind,
      errorSource: this.state_.errorSource,
      httpStatus: this.state_.httpStatus,
      // lastRequest 是 buildSearchOptions 的产物（纯函数、每次新建），拷引用即可：
      // 控制器自己不会再改它。
      lastRequest: this.state_.lastRequest,
    };
  }

  // ============================================================
  //  输入 setter：改任一条件都会重置分页 + 作废 in-flight
  // ============================================================

  setQuery(q: string): void {
    if (q === this.state_.query) return;
    this.state_.query = q;
    // 未手动选过排序时：有搜索词按相关度，无搜索词按下载量（对照 PCL）。
    if (!this.sortExplicit_) {
      this.state_.sortBy = q.trim().length > 0 ? SortBy.RELEVANCE : SortBy.DOWNLOADS;
    }
    this.resetPagination();
  }

  setKind(k: ResourceKind): void {
    if (k === this.state_.kind) return;
    this.state_.kind = k;
    // loader 仅对 MOD / MODPACK 有意义；切到资源包/光影/数据包时清空
    if (k !== ResourceKind.MOD && k !== ResourceKind.MODPACK) this.state_.loader = '';
    this.resetPagination();
  }

  setGameVersion(v: string): void {
    if (v === this.state_.gameVersion) return;
    this.state_.gameVersion = v;
    this.resetPagination();
  }

  setLoader(l: string): void {
    if (l === this.state_.loader) return;
    this.state_.loader = l;
    this.resetPagination();
  }

  setSortBy(s: SortBy): void {
    this.sortExplicit_ = true;
    if (s === this.state_.sortBy) return;
    this.state_.sortBy = s;
    this.resetPagination();
  }

  private resetPagination(): void {
    this.state_.hits = [];
    this.state_.totalHits = 0;
    this.state_.nextOffset = 0;
    this.state_.hasMore = true;
    this.clearErrorFields_();
    this.epoch_++;
  }

  /**
   * 清空四个失败字段（批次 D2-5）。
   *
   * ⚠️ 它存在的理由是**清零点有三处** —— `resetPagination` / `loadPage` 开头 /
   * `clearError`，而 D2 一次加了三个字段。任何一处只清 `errorMessage`，
   * 上一次失败的 `errorKind` 就会活到下一次查询里，让报告把旧失败归因给新请求；
   * 而 `errorMessage` 已经清了，界面上看起来"错误已经没了"。
   * ⇒ 四个字段只在这一个函数里清，新增失败字段也只改这里。
   */
  private clearErrorFields_(): void {
    this.state_.errorMessage = null;
    this.state_.errorKind = null;
    this.state_.errorSource = null;
    this.state_.httpStatus = 0;
  }

  // ============================================================
  //  loadFirstPage / loadNextPage
  // ============================================================

  /** 首次查询；每次输入变化后调用（UI 层负责去抖） */
  async loadFirstPage(): Promise<void> {
    this.resetPagination();
    return this.loadPage(0);
  }

  /** 加载下一页；已无更多时短路 */
  async loadNextPage(): Promise<void> {
    if (!this.state_.hasMore) return;
    if (this.state_.loading) return;
    return this.loadPage(this.state_.nextOffset);
  }

  private async loadPage(offset: number): Promise<void> {
    let myEpoch = this.epoch_;
    this.state_.loading = true;
    this.clearErrorFields_();
    let opt = buildSearchOptions(this.state_, offset, this.pageSize_);
    // 批次 D6-3：回显**实际**发出的请求体。刻意在 try 之前就记下 ——
    // 失败路径同样需要它：没有请求体，"过滤没生效"与"过滤按契约被丢弃"不可区分。
    this.state_.lastRequest = opt;
    try {
      let res: SearchResult = await this.repo_.search(opt);
      // 期间输入已经变化 → 丢弃这次结果
      if (myEpoch !== this.epoch_) return;
      this.state_.hits = mergePagedHits(this.state_.hits, res.hits);
      this.state_.totalHits = res.totalHits;
      // 关键修复（双源分页）：按"请求的单源页大小"推进 offset，而不是按合并去重后的
      // 条数。ModSourceRouter 用同一个 offset 同时查两源，若按合并后条数（≈2×pageSize
      // 去重）推进，下一页两源都会跳过 [pageSize, 合并条数) 区间的条目，造成漏项 + 排序错乱。
      // 单源场景下 res.hits.length === pageSize_，两种算法等价，无行为变化。
      let advanced = res.hits.length >= this.pageSize_ ? this.pageSize_ : res.hits.length;
      this.state_.nextOffset = offset + advanced;
      // 没拿到完整 page 或已覆盖 totalHits → 没更多
      this.state_.hasMore = res.hits.length >= this.pageSize_
        && this.state_.nextOffset < res.totalHits;
    } catch (e) {
      if (myEpoch !== this.epoch_) return;
      // 批次 D2：保留产品已经分好的类，不再压成一句 message。
      // 提取逻辑在 describeModRepoError（纯函数，可单独喂样本）——
      // 这里只做搬运，不做判断（契约 §8.3.1）。
      let facts: ModRepoErrorFacts = describeModRepoError(e as Object);
      this.state_.errorMessage = facts.message;
      this.state_.errorKind = facts.kind;
      this.state_.errorSource = facts.source;
      this.state_.httpStatus = facts.httpStatus;
    } finally {
      // 只在"本次仍是当前请求"时清 loading。
      // 关键修复（空态闪现）：首屏会先跑一次无译名搜索 A，译名就绪后重搜 B（epoch++）。
      // 若 A 在 B 之后才 resolve 却无条件把 loading 清成 false，此刻 B 尚未回填、hits 仍为空，
      // UI 会瞬间命中"暂无结果"分支闪现，等 B 回来才出列表。故陈旧请求(myEpoch≠epoch)不动 loading，
      // 由当前请求 B 负责在自己 resolve 时清 loading。
      // 之前担心的"setQuery 后不触发 loadFirstPage 导致 loading 卡死"在本项目不存在——
      // 所有 setXxx(epoch++) 之后 UI 都会同步调用 triggerSearch→loadFirstPage(重置 loading=true 并最终清掉)。
      if (myEpoch === this.epoch_) {
        this.state_.loading = false;
      }
    }
  }

  /** 清空错误（用户手动"重试"后调） */
  clearError(): void {
    this.clearErrorFields_();
  }
}

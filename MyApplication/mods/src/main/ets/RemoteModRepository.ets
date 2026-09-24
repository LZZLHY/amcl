/**
 * RemoteModRepository.ets — 远程模组仓库抽象（P1-MODS Phase 1.1）
 *
 * 文档：docs/guides/mod-download-system-plan.md §七.1
 *
 * 设计要点：
 *   - 用 interface 而非 abstract class，保持纯类型零运行时开销，方便测试 mock。
 *   - SearchOptions / SearchResult 共享给 ModrinthRepository / CurseForgeRepository / ModSourceRouter。
 *   - 排序枚举与 Modrinth / CurseForge 字段对齐：调用方传 enum，仓库各自映射到平台字符串。
 *   - 错误统一封装成 ModRepoError（kind + cause），UI 层据此切换文案 / 重试策略。
 *
 * 创建日期：2026-05-11
 */

import {
  ModSource,
  ResourceKind,
  RemoteProject,
  RemoteVersion,
} from './ModTypes';

// ============================================================
//  排序键
// ============================================================

export enum SortBy {
  RELEVANCE = 'relevance',
  DOWNLOADS = 'downloads',
  FOLLOWS = 'follows',
  NEWEST = 'newest',
  UPDATED = 'updated',
}

// ============================================================
//  搜索参数 / 结果
// ============================================================

export interface SearchOptions {
  /** 用户输入的关键字，可空（"" 表示按 sortBy 浏览全部） */
  query: string;
  kind: ResourceKind;
  /** MC 版本字符串，如 "1.20.4"；undefined 表示不限 */
  gameVersion?: string;
  /** ['fabric'] / ['forge'] / ['neoforge'] / ['quilt']；空数组表示不限 */
  loaders?: string[];
  /** 分类 facet（如 'performance'、'optimization'）；空数组表示不限 */
  categories?: string[];
  sortBy: SortBy;
  /** 0-based 偏移，对应 Modrinth `offset` / CurseForge `index` */
  offset: number;
  /** 单页条数，建议 20；CurseForge 最大 50 */
  pageSize: number;
}

export interface SearchResult {
  /** 本页命中（已映射成跨源统一结构 RemoteProject） */
  hits: RemoteProject[];
  /** 总命中数（用于分页 UI 计算"还有多少页"；CurseForge 上限 10000） */
  totalHits: number;
  offset: number;
  pageSize: number;
}

// ============================================================
//  错误模型
// ============================================================

/** 错误分类，对 UI 提示文案 / 调用方重试决策有用 */
export enum ModRepoErrorKind {
  /** 网络层失败（DNS/超时/SSL） — UI 文案"网络连接异常" */
  NETWORK = 'network',
  /** HTTP 4xx，含 401/403/404/429 — UI 文案"接口请求被拒绝" */
  HTTP_CLIENT = 'http_client',
  /** HTTP 5xx — UI 文案"远程服务暂时不可用" */
  HTTP_SERVER = 'http_server',
  /** 响应 JSON 解析失败 — UI 文案"接口数据格式异常"（隐藏，仅日志） */
  PARSE = 'parse',
  /** 该源不支持的能力（如 CurseForge 不支持 sha1 反查 V1） */
  UNSUPPORTED = 'unsupported',
  /** 其他未分类异常 */
  UNKNOWN = 'unknown',
}

export class ModRepoError extends Error {
  readonly source: ModSource;
  readonly kind: ModRepoErrorKind;
  readonly httpStatus: number;
  readonly cause?: string;

  constructor(source: ModSource, kind: ModRepoErrorKind, message: string,
              httpStatus: number = 0, cause?: string) {
    super(message);
    this.name = 'ModRepoError';
    this.source = source;
    this.kind = kind;
    this.httpStatus = httpStatus;
    this.cause = cause;
  }

  /** 便利构造：从底层 Error 推断 kind（用于 catch 块兜底） */
  static fromUnknown(source: ModSource, e: Object): ModRepoError {
    if (e instanceof ModRepoError) return e as ModRepoError;
    let msg = (e as Error).message !== undefined
      ? (e as Error).message
      : String(e);
    // 简单启发：DownloadManager.fetchText 抛出 `[NetworkError] ...` / `[HttpError] ...` 形式
    let kind = ModRepoErrorKind.UNKNOWN;
    let httpStatus = 0;
    if (msg.indexOf('[Http') >= 0 || msg.indexOf(' http=') >= 0) {
      // 试图抠出 status
      let m = /http=(\d+)/.exec(msg);
      if (m) httpStatus = parseInt(m[1], 10);
      kind = httpStatus >= 500 ? ModRepoErrorKind.HTTP_SERVER : ModRepoErrorKind.HTTP_CLIENT;
    } else if (msg.indexOf('[Network') >= 0 || msg.indexOf('Timeout') >= 0
               || msg.indexOf('SslError') >= 0 || msg.indexOf('DnsError') >= 0) {
      kind = ModRepoErrorKind.NETWORK;
    }
    return new ModRepoError(source, kind, msg, httpStatus, msg);
  }
}

// ============================================================
//  失败事实的提取（批次 D2）
// ============================================================

/**
 * 从一个抛出物里取出**结构化**的失败事实。
 *
 * 文档：docs/guides/test-automation-contract.md §4.1（分类不得在边界处降级为字符串）
 *
 * 起因：`ModSearchController.loadPage` 的 catch 块过去只取 `.message`，
 * 于是 DNS 失败 / 429 限流 / 5xx / JSON 解析失败在状态里**完全不可区分** ——
 * 而这四者的处置完全不同：前两者与 AMCL 无关，`parse` 意味着**上游改了响应结构**
 * （那一层才是产品缺陷）。产品早就有这个答案，只是在传递途中丢了。
 *
 * 为什么单独成一个导出的纯函数（契约 §8.3.1）：判定逻辑内联在 catch 块里就只能
 * 通过"构造一个会抛的假仓库 + 跑完整个控制器"来测，而它本身是个纯粹的映射。
 * ⇒ 抽出来之后可以直接喂样本，反向用例（喂一个恒定 unknown 的实现必须失败）才立得住。
 */
export interface ModRepoErrorFacts {
  /** 给人看的一句话。**不得**用它做判定。 */
  message: string;
  /** 给机器判定的分类。 */
  kind: ModRepoErrorKind;
  /** 失败归属到哪个源；非 `ModRepoError` 时为 null（不猜）。 */
  source: ModSource | null;
  /** HTTP 状态码；无则 0。 */
  httpStatus: number;
}

export function describeModRepoError(e: Object): ModRepoErrorFacts {
  if (e instanceof ModRepoError) {
    const err = e as ModRepoError;
    // ⚠️ 逐字取用，**不**在这里重新推断一遍：`ModRepoError.fromUnknown` 已经是
    // 唯一的启发式分类器，这里再推一次就成了第二个分类器（契约 §1.1）。
    return {
      message: err.message,
      kind: err.kind,
      source: err.source,
      httpStatus: err.httpStatus,
    };
  }
  // 不是 ModRepoError ⇒ 抛出方在仓库层之外（仓库层的抛出都经 fromUnknown 包过）。
  // 这里刻意**不**套用消息启发式：那套启发式需要一个 source 才能构造，而控制器
  // 无从知道是哪个源。编一个源比留空更糟 —— 归因链第 3 层会据此指向错误的对象。
  const err = e as Error;
  const message: string = err !== undefined && err !== null
    && err.message !== undefined && err.message.length > 0
    ? err.message : String(e);
  return {
    message,
    kind: ModRepoErrorKind.UNKNOWN,
    source: null,
    httpStatus: 0,
  };
}

// ============================================================
//  仓库接口
// ============================================================

/**
 * 远程模组仓库抽象（Modrinth / CurseForge 各实现一份）。
 *
 * 实现注意：
 *   - search 不缓存（实时性优先）；getProject TTL=2h；getVersions TTL=30min
 *     （由 MetadataCacheStore 统一管理，仓库实现自行调用 get/put）
 *   - 多源 fallback 全部走 `DownloadManager.fetchText` 的 `mirrors` 参数
 *   - 不做"同名拒绝"（DownloadManager.isTaskActiveByName 是文件下载层的事）
 *   - 抛出统一为 ModRepoError；UnboundPromise / SyntaxError 等通过 fromUnknown 兜底
 */
export interface IRemoteModRepository {
  readonly source: ModSource;

  /** 当前数据源是否可用（如 ranking.modSource 不可用时短路） */
  isAvailable(): boolean;

  /** 搜索项目；不缓存。失败抛 ModRepoError。 */
  search(opt: SearchOptions): Promise<SearchResult>;

  /** 项目详情；TTL=2h。 */
  getProject(idOrSlug: string): Promise<RemoteProject>;

  /**
   * 项目的版本列表；TTL=30min。
   * @param loaders        过滤 loader（fabric/forge/neoforge/quilt）；空数组=不限
   * @param gameVersions   过滤 MC 版本；空数组=不限
   */
  getVersions(projectId: string, loaders?: string[], gameVersions?: string[]): Promise<RemoteVersion[]>;

  /** 单版本详情（依赖解析 / 历史版本展开用） */
  getVersion(versionId: string): Promise<RemoteVersion>;

  /** 仅 Modrinth 实现：sha1 反查（"我装的这个 jar 在 Modrinth 是哪个版本"） */
  lookupVersionBySha1?(sha1: string): Promise<RemoteVersion | null>;

  /**
   * 仅 Modrinth 实现：按 id/slug 批量取工程（中文搜索"按 slug 直取"用，
   * 保证匹配到的 mod 一定出现，不依赖源的文本分词）。
   */
  getProjectsByIds?(ids: string[]): Promise<RemoteProject[]>;

  /** 仅 Modrinth 实现：批量"找最新版本"（检查更新批量调用） */
  batchLatestVersions?(
    hashes: string[],
    loaders: string[],
    gameVersions: string[],
  ): Promise<Map<string, RemoteVersion>>;
}

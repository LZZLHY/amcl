import { DiagnosticPolicy } from 'commons';
/**
 * McDownloader.ets — MC 游戏文件下载器（Stage 3b — 委托 C++ NAPI 引擎）
 *
 * 历史演变：
 *   v1（P9）：完全 ArkTS 实现，http.createHttp + PCL2 风格滑动并发
 *   v2（v3 Stage 3b）：核心下载委托给 DownloadManager + libcurl NAPI 引擎
 *   v3（2026-05-06，Phase 2.3+3.5）：元数据也走 NAPI（fetchText）+ TTL 磁盘缓存
 *
 * 当前职责（瘦身版）：
 *   1. 编排：从 version.json 构造 DownloadTaskSpec（URL 映射 / sha1 / size）
 *   2. 过滤：libraries rules 判定（OHOS 伪装 Linux）
 *   3. 元数据下载：version_manifest / version.json / asset index 走 DownloadManager.fetchText
 *      （Phase 3.5），并接入 MetadataCacheStore（Phase 2.3）按 TTL 缓存
 *   4. 进度适配：把 DownloadTaskView 的 byte 级进度映射成 ProgressCallback 事件
 *
 * 已删除（功能迁移到 NAPI 引擎）：
 *   - httpDownloadStreamWithProgress / httpDownloadSmall
 *   - downloadOneFile（多源重试）
 *   - slidingDownload（PCL 滑动并发调度）
 *   - updateSpeed / resetSpeed / 自建速度统计
 *   - withTimeout / isHttp4xxError
 *   - 元数据 http.createHttp 路径（改走 fetchText，2026-05-06）
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BMCLAPI_BASE, MOJANG_META, MOJANG_RESOURCES, MOJANG_LIBRARIES } from 'commons';
import { CancelledError } from 'commons';
import {
  DownloadManager, DownloadTaskSpec, DownloadFileSpec, DownloadTaskView,
  DownloadCheck, FetchTextRichResult,
} from './DownloadManager';
import { getMetadataCacheStore } from '../version/MetadataCacheStore';
import { buildConditionalRequest } from '../version/MetadataCache';
import { basename, formatSpeed } from 'commons';
import { shouldUseBmclapiFirst, buildSortedUrls } from './SourceProber';
import {
  mavenToRelativePath, safeBaseName, safeRelPath, isSafeHttpUrl, isValidSha1,
} from '../modloader/MavenUtils';
import { ActivityLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = LogTags.UTIL_DOWNLOADER;

function useBmclapi(): boolean {
  return shouldUseBmclapiFirst();
}

// ============ 元数据请求超时（秒，Phase 3.5 起走 fetchText NAPI） ============
const META_TIMEOUT_SECONDS = 30;

// ============ 元数据缓存 TTL（毫秒，Phase 2.3） ============
/** version_manifest_v2.json — latest 列表，约每周更新（新 MC 发布时）。6 小时 TTL 保守。 */
const MANIFEST_CACHE_MS = 6 * 60 * 60 * 1000;
/** 按 sha1 寻址的 URL（version.json / assetIndex）永远不变 → 永不过期。 */
const IMMUTABLE_CACHE_MS = -1;

function requireSafeSegment(value: string, field: string): string {
  let safe = safeBaseName(value);
  if (safe.length === 0) throw new Error(field + ' 包含不安全路径段');
  return safe;
}

function requireSafeRelativePath(value: string, field: string): string {
  let safe = safeRelPath(value);
  if (safe.length === 0) throw new Error(field + ' 包含不安全相对路径');
  return safe;
}

function requireSha1(value: string, field: string): string {
  if (!isValidSha1(value)) throw new Error(field + ' 不是合法 SHA-1');
  return value.toLowerCase();
}

function validatedUrls(urls: string[], field: string): string[] {
  let result: string[] = [];
  for (let url of urls) {
    if (!isSafeHttpUrl(url)) throw new Error(field + ' 包含不安全 URL');
    if (result.indexOf(url) < 0) result.push(url);
  }
  if (result.length === 0) throw new Error(field + ' 没有可用 URL');
  return result;
}

export interface DownloadProgress {
  stage: string;
  current: number;
  total: number;
  fileName: string;
  /** 人类可读的速度字符串，如 "1.2 MB/s"。仅供 UI 文案；机器侧请用 speedBps。 */
  speed?: string;
  /** Phase 6.5 重构后新增：直接的 bytes/s 数值，省去下游解析。0 表示空闲或未知。 */
  speedBps?: number;
  error?: string;
  etaSeconds?: number;
  bytesDone?: number;
  bytesTotal?: number;
}

export type ProgressCallback = (progress: DownloadProgress) => void;

interface VersionEntry { id: string; type: string; url: string; }
interface VersionLatest { release: string; snapshot: string; }
interface VersionManifest { latest: VersionLatest; versions: VersionEntry[]; }
// 2026-05-06：Phase 7 解锁 export 以支持 McDownloader.filterLibraries 的纯函数单元测试。
export interface LibraryDownload { path: string; url: string; sha1: string; size: number; }
export interface LibraryDownloads { artifact?: LibraryDownload; }
export interface RuleOs { name: string; }
export interface LibraryRule { action: string; os?: RuleOs; }
export interface LibraryEntry { name: string; downloads?: LibraryDownloads; rules?: LibraryRule[]; url?: string; }
interface ClientDownload { url: string; sha1: string; size: number; }
interface VersionDownloads { client: ClientDownload; }
interface AssetIndex { id: string; url: string; sha1: string; size: number; totalSize: number; }
export interface VersionJson { id: string; downloads: VersionDownloads; libraries: LibraryEntry[]; assetIndex?: AssetIndex; }
interface AssetObject { hash: string; size: number; }

/**
 * asset index 的顶层结构。
 *
 * `virtual` / `map_to_resources` 是**老版本布局标记**，AMCL 此前完全没读它们
 * （2026-08-04 补齐，对齐 PCL2 `ModMinecraft.vb:2310-2325 McAssetsListGet`）：
 *
 *   - `virtual: true`（≤1.6.4 的 `legacy` 索引）：按**资源名**落到 `<mcDir>/assets/virtual/legacy/<name>`
 *   - `map_to_resources: true`（pre-1.6 索引）：同上（PCL2 落在 `PathIndie\resources\`，
 *     但它的 `${game_assets}` 仍指向 virtual\legacy，我们统一到后者，见 downloadAssets 注释）
 *   - 都没有（1.7+ 现代索引）：按 hash 落到 `<mcDir>/assets/objects/<hash 前 2 位>/<hash>`
 *
 * 为什么必须支持：实测 1.6.4 用的 `legacy.json` **就是** `virtual: true`，而且它
 * 1120 个条目里只有 596 个唯一 hash —— 524 个条目共享 hash。只按 hash 落盘的话，
 * 磁盘上只会出现 596 个文件、且文件名是 hash，游戏按名字一个都找不到，
 * 表现就是"老版本装完没有声音 / 语言文件"。
 */
interface AssetIndexData {
  objects: Record<string, AssetObject>;
  virtual?: boolean;
  map_to_resources?: boolean;
}

/** assets 落盘布局。 */
enum AssetLayout {
  /** 1.7+ ：assets/objects/<hash 前 2 位>/<hash> */
  OBJECTS = 'objects',
  /** ≤1.6.4 的 legacy 索引 / pre-1.6 索引：assets/virtual/legacy/<资源名> */
  VIRTUAL = 'virtual',
}

export interface FetchVersionInfoResult {
  versionJson: VersionJson;
  rawJson: string;
}

export class McDownloader {
  private mcDir: string;
  private onProgress: ProgressCallback | null = null;
  private cancelled = false;
  private currentSpeed: string = '';
  private currentSpeedBps: number = 0;       // Phase 6.5: 给下游免去 parseSpeed 重复解析
  private activeTaskId: number = 0;          // 正在运行的 NAPI task id，支持 cancel
  /** 本实例创建过且尚未确认 purge 的全部 native owner（成功自动 purge 也会幂等移除）。 */
  private ownedTaskIds: number[] = [];
  private readonly mgr: DownloadManager = DownloadManager.instance();

  /**
   * 归属的活动主键（活动账本 · L2-b）；0 = 不归属。
   *
   * 由任务适配器用自己的 `startedAtMs` 赋值。填了它，本次下载在 native 侧产生的
   * 日志（`DL_MULTI` 的 URL / 换源 / 重试 / 失败原因）才会被分流进该活动的账本 ——
   * 那正是排查下载失败最有价值的部分。
   */
  activityId: number = 0;

  /**
   * `activityId` 对应的 logger 缓存（活动账本 · 缺陷 1 修复）。
   *
   * `ActivityLogger.activityId` 是 readonly，而本类的 `activityId` 是**构造后**才被
   * 适配器赋值的，所以不能在构造里一次性 new 好，只能在用的时候比对、变了再重建。
   * 不每次都 new 是因为进度类日志在循环里高频调用。
   */
  private alogCache_: ActivityLogger = new ActivityLogger(0);

  /** 取绑定当前活动的 logger；`activityId` 变了会自动重建。 */
  private alog(): ActivityLogger {
    if (this.alogCache_.id() !== this.activityId) {
      this.alogCache_ = new ActivityLogger(this.activityId);
    }
    return this.alogCache_;
  }

  constructor(mcDir: string) { this.mcDir = mcDir; }

  setProgressCallback(cb: ProgressCallback) { this.onProgress = cb; }

  /** v5: 返回当前活跃的 NAPI taskId（用于 DownloadTask 调用 deleteTaskFiles 等） */
  getActiveTaskId(): number { return this.activeTaskId; }

  private trackTask_(taskId: number): void {
    if (taskId <= 0) return;
    this.activeTaskId = taskId;
    if (this.ownedTaskIds.indexOf(taskId) < 0) this.ownedTaskIds.push(taskId);
  }

  /** 仅在高层任务已终态时调用；任一 native execution 未收敛则保留该 id 并返回 false。 */
  purgeNativeOwners(): boolean {
    let retained: number[] = [];
    for (let taskId of this.ownedTaskIds) {
      let purged = false;
      try { purged = this.mgr.purgeTask(taskId); } catch (e) { purged = false; }
      if (!purged) retained.push(taskId);
    }
    this.ownedTaskIds = retained;
    if (this.activeTaskId > 0 && retained.indexOf(this.activeTaskId) < 0) this.activeTaskId = 0;
    return retained.length === 0;
  }

  /**
   * 取消：同时取消 NAPI 当前任务。NAPI cancelTask 幂等，下次 start 会走断点续传。
   */
  cancel() {
    this.cancelled = true;
    if (this.activeTaskId > 0) {
      try {
        this.mgr.cancel(this.activeTaskId);
      } catch (e) {
        this.alog().warn(TAG, `cancel task ${this.activeTaskId} threw`, e, LOG_DOMAIN_DOWNLOAD);
      }
      this.activeTaskId = 0;
    }
  }

  private report(stage: string, current: number, total: number, fileName: string,
                 error?: string, etaSeconds?: number, bytesDone?: number, bytesTotal?: number) {
    if (this.onProgress) {
      this.onProgress({ stage, current, total, fileName,
        speed: this.currentSpeed, speedBps: this.currentSpeedBps, error,
        etaSeconds, bytesDone, bytesTotal });
    }
  }

  private reportFromView(stage: string, current: number, total: number, fileName: string, v: DownloadTaskView) {
    this.updateSpeedFromView(v);
    if (this.onProgress) {
      this.onProgress({ stage, current, total, fileName,
        speed: this.currentSpeed, speedBps: this.currentSpeedBps,
        etaSeconds: v.etaSeconds, bytesDone: v.bytesDone, bytesTotal: v.bytesTotal });
    }
  }

  /** 从 DownloadTaskView 刷新 currentSpeed（字符串）+ currentSpeedBps（数值） */
  private updateSpeedFromView(v: DownloadTaskView) {
    this.currentSpeedBps = v.speedBps > 0 ? v.speedBps : 0;
    this.currentSpeed = this.currentSpeedBps > 0 ? formatSpeed(this.currentSpeedBps) : '';
  }

  // ============================================================
  //  元数据 HTTP（Phase 3.5: 走 C++ NAPI 引擎；Phase 2.3: TTL 磁盘缓存）
  // ============================================================

  /**
   * 拉取元数据文本（manifest / version.json / assetIndex / Forge file_list 等）。
   *
   * Phase 2.3：三段式缓存策略
   *   1. TTL 内 cache hit → 直接返回 body，0 网络
   *   2. TTL 过期但有 cache + ETag/Last-Modified → 发 If-None-Match / If-Modified-Since
   *      → 304 命中 → touch + 返回旧 body（仅一次 HEAD-like 往返，无 body 传输）
   *      → 200 → 用新 body 覆盖 cache + 返回
   *   3. 完全无 cache → 直接 GET，写入 cache
   * Phase 3.5：委托给 `DownloadManager.fetchTextEx` → C++ `engine.fetchToBufferEx`（libcurl），
   *            与文件下载共享 CA bundle / UA / 坏主机黑名单。
   *
   * @param primaryUrl  首选 URL（也是缓存 key）
   * @param mirrors     次源 URL 列表；主源失败时由 NAPI 内部依次 fallback
   * @param maxAgeMs    缓存 TTL 毫秒；0 = 不缓存；-1 = 永不过期（content-addressed URL）；>0 = TTL
   */
  private async httpGet(
    primaryUrl: string,
    mirrors?: string[],
    maxAgeMs: number = 0,
  ): Promise<string> {
    if (!isSafeHttpUrl(primaryUrl)) throw new Error('元数据 URL 不安全');
    let mirrorList: string[] = [];
    let inputMirrors: string[] = mirrors !== undefined ? mirrors : [];
    for (let mirror of inputMirrors) {
      if (!isSafeHttpUrl(mirror)) throw new Error('元数据镜像 URL 不安全');
      if (mirror !== primaryUrl && mirrorList.indexOf(mirror) < 0) mirrorList.push(mirror);
    }

    // Phase 2.3 step 1: TTL 内直接命中
    if (maxAgeMs !== 0) {
      let store = getMetadataCacheStore();
      if (store.isReady()) {
        let cached = store.get(primaryUrl, maxAgeMs);
        if (cached !== null) return cached;
      }
    }

    // Phase 2.3 step 2: 检查是否有"过期但有 ETag"的旧 cache，构造条件请求头
    let reqHeaders: Record<string, string> | undefined = undefined;
    if (maxAgeMs !== 0) {
      let store = getMetadataCacheStore();
      if (store.isReady()) {
        let oldMeta = store.getMeta(primaryUrl);
        if (oldMeta && (oldMeta.etag !== undefined || oldMeta.lastModified !== undefined)) {
          let conditional = buildConditionalRequest(oldMeta);
          if (Object.keys(conditional).length > 0) {
            reqHeaders = conditional;
          }
        }
      }
    }

    // Phase 3.5 + 2.3: 单次调用 NAPI（含可选条件头）
    let resp: FetchTextRichResult = await this.mgr.fetchTextEx(
      primaryUrl, mirrorList, META_TIMEOUT_SECONDS, reqHeaders);

    // Phase 2.3 step 2-cont: 304 → 用本地 body + touch fetchedAt
    if (resp.statusCode === 304) {
      let store = getMetadataCacheStore();
      let cachedBody = store.isReady() ? store.getBody(primaryUrl) : null;
      if (cachedBody !== null) {
        store.touch(primaryUrl);
        this.alog().info(TAG, `304 Not Modified, using cached body: ${primaryUrl}`, LOG_DOMAIN_DOWNLOAD);
        return cachedBody;
      }
      // 服务端说 304 但本地 cache 已被清 → 异常，fallthrough 到一次普通 GET
      this.alog().warn(TAG, `304 received but local cache missing, refetching: ${primaryUrl}`, null, LOG_DOMAIN_DOWNLOAD);
      // 2026-05-23 ArkTS 严格模式：fetchText 报 'Function may throw'（网络层）。
      // 包 try-catch + rethrow，让上层 cacheGetText 的 try-catch 接住。
      let plain: string;
      try {
        plain = await this.mgr.fetchText(primaryUrl, mirrorList, META_TIMEOUT_SECONDS);
      } catch (e) {
        this.alog().warn(TAG, 'fetchText fallback failed', e, LOG_DOMAIN_DOWNLOAD);
        throw e as Error;
      }
      if (maxAgeMs !== 0 && plain.length > 0) {
        try { if (store.isReady()) store.put(primaryUrl, plain); } catch (e) { /* */ }
      }
      return plain;
    }

    // Phase 2.3 step 3: 200 OK → 写 cache（含 ETag / Last-Modified 提取）
    if (maxAgeMs !== 0 && resp.body.length > 0) {
      try {
        let store = getMetadataCacheStore();
        if (store.isReady()) store.put(primaryUrl, resp.body, resp.headers);
      } catch (e) { /* non-fatal */ }
    }

    return resp.body;
  }

  // ============================================================
  //  拆分后的公开方法（供 DownloadTask 编排调用）
  // ============================================================

  /**
   * 获取版本信息：下载 manifest → 查找版本 → 下载 version.json
   * 返回解析后的 VersionJson 对象和原始 JSON 字符串。
   */
  async fetchVersionInfo(version: string): Promise<FetchVersionInfoResult> {
    this.cancelled = false;
    let safeVersion = requireSafeSegment(version, 'version');
    this.report('获取版本信息', 0, 2, 'version_manifest_v2.json');

    let bmcl = useBmclapi();
    let manifestPrimary = bmcl
      ? BMCLAPI_BASE + '/mc/game/version_manifest_v2.json'
      : MOJANG_META + '/mc/game/version_manifest_v2.json';
    let manifestFallback = bmcl
      ? MOJANG_META + '/mc/game/version_manifest_v2.json'
      : BMCLAPI_BASE + '/mc/game/version_manifest_v2.json';
    // 单次调用走 NAPI 多源 fallback；缓存 6 小时（Phase 2.3 + 3.5）
    let manifestJson = await this.httpGet(manifestPrimary, [manifestFallback], MANIFEST_CACHE_MS);
    if (!manifestJson.startsWith('{')) {
      throw new Error('非 JSON 响应: ' + manifestJson.substring(0, 100));
    }
    let manifest: VersionManifest = JSON.parse(manifestJson) as VersionManifest;

    let versionEntry: VersionEntry | undefined = undefined;
    for (let v of manifest.versions) {
      if (v.id === safeVersion) { versionEntry = v; break; }
    }
    if (!versionEntry) throw new Error('版本 ' + safeVersion + ' 未找到');

    this.report('获取版本详情', 1, 2, safeVersion + '.json');
    // version JSON URL 也替换为 BMCLAPI 镜像
    let versionUrl = versionEntry.url;
    if (bmcl && versionUrl.indexOf('piston-meta.mojang.com') >= 0) {
      versionUrl = versionUrl.replace('https://piston-meta.mojang.com', BMCLAPI_BASE);
    }
    if (bmcl && versionUrl.indexOf('launchermeta.mojang.com') >= 0) {
      versionUrl = versionUrl.replace('https://launchermeta.mojang.com', BMCLAPI_BASE);
    }
    // version.json 按 sha1 寻址 → 永不过期（Phase 2.3），NAPI 做镜像 fallback（Phase 3.5）
    let versionMirrors = versionUrl !== versionEntry.url ? [versionEntry.url] : [];
    let rawJson = await this.httpGet(versionUrl, versionMirrors, IMMUTABLE_CACHE_MS);
    if (!rawJson.startsWith('{')) {
      throw new Error('非 JSON 响应: ' + rawJson.substring(0, 100));
    }
    let versionJson: VersionJson = JSON.parse(rawJson) as VersionJson;
    let returnedVersionId = requireSafeSegment(versionJson.id, 'versionJson.id');
    if (returnedVersionId !== safeVersion) {
      throw new Error('versionJson.id 与请求版本不一致');
    }

    this.alog().info(TAG, `Fetched version info: ${safeVersion} (libs=${versionJson.libraries.length})`, LOG_DOMAIN_DOWNLOAD);
    let result: FetchVersionInfoResult = { versionJson: versionJson, rawJson: rawJson };
    return result;
  }

  /**
   * 下载 client.jar 到指定目录。
   *
   * 委托 DownloadManager（libcurl NAPI 引擎）：
   *   - 多源容错：BMCLAPI 为主、Mojang 官方为备用源
   *   - client 专用 4 连接硬上限（恢复 beta.5 连接规模，不回退统一下载器）
   *   - sha1 + size 校验（引擎内部 FileChecker）
   *   - 断点续传（.download-meta 序列化分段进度）
   *
   * @param versionJson 版本信息
   * @param destDir 目标目录（jar 保存为 destDir/<version>.jar）
   * @returns 结果摘要字符串
   */
  async downloadClientJar(versionJson: VersionJson, destDir: string): Promise<string> {
    let version = requireSafeSegment(versionJson.id, 'versionJson.id');
    let clientPath = destDir + '/' + version + '.jar';
    let clientSize = versionJson.downloads.client.size;
    if (clientSize <= 0) throw new Error('client.size 非法');
    let clientSha1 = requireSha1(versionJson.downloads.client.sha1, 'client.sha1');

    this.ensureDir(destDir);

    // H-1 修复：删除 ArkTS 层 fileIsValid 短路。原实现只比 size 不比 SHA1，
    // 会让"size 正确但内容损坏"的文件被静默接受。统一交引擎 preCheckExistingFile
    // 做 size+SHA1 校验，正确性优先于节省单次 NAPI 调度开销（< 1ms）。
    // 命中的文件会瞬间转 Finished，不会真正发起 HTTP。

    let urls = validatedUrls(buildSortedUrls(
      BMCLAPI_BASE + '/version/' + version + '/client',
      versionJson.downloads.client.url
    ), 'client.urls');

    let totalMB = (clientSize / 1048576).toFixed(1);
    this.report('下载 client.jar', 0, clientSize, '0/' + totalMB + ' MB');

    // ⚠️ 2026-07-30：**移除** 2026-07-29 加的 `maxConnections: 4`。
    //
    // 那次改动的理由是「bb7f9aef 把 >=8MiB 默认文件改成追到 16 连接后，client.jar 掉到
    // 0.34~0.51MiB/s」，于是把 client 钉回 4 条。但真机历史日志证明病因判错了：
    //   2026-07-14 23:30  36.3MB / 7.3s  = 4.99MB/s   （旧速度地板驱动的 maybeGrowThreads）
    //   2026-07-15 16:35  36.3MB / 4.0s  = 8.99MB/s   （bb7f9aef：>=8MiB → target=16）
    //   2026-07-29 16:59  38.9MB / 82.4s = 0.47MB/s   （target 仍 16，但叠加了 07-16 大改）
    //   2026-07-30 22:53  37.4MB / 21.8s = 1.71MB/s   （被钉成 4 条之后）
    // 三次的 `Source ranking: bmclapiFirst` 都是 false，源顺序不是变量。同一次 22:53 的
    // `perform PERF` 显示单连接吞吐没变：piston-data 平均 487KB/s、BMCLAPI 平均 535KB/s
    // （峰值 2996KB/s、TTFB 115ms），而 `adaptive split ... active=3->4` 出现 8 次、
    // 并发全程没超过 4。也就是说 8.99MB/s ÷ 500KB/s ≈ 18 条连接才是它当初快的原因，
    // 16 连接在 07-29 变慢是被 07-16 那批分段/拆段重写（最小拆段 256KB + 按 ETA 拆半，
    // 在 1~2s TTFB 的源上 TTFB 占比过半，正是 2026-07-15 审查文档 P-05 预言的成本模型缺失）
    // 拖垮的，不是「连接多了不好」。把上限砍到 4 等于把速度锁死在原来的 1/5。
    //
    // 去掉后 client.jar 回到默认路径，等价于 07-15 测到 8.99MB/s 的那套配置：
    //   · net_file.cpp `size >= kSaturateFileBytes(8MiB)` → target_connections_ = 16；
    //   · piece_min_bytes 仍是默认 2MiB（不是高并发模式的 384KB），不产生 TTFB 碎片；
    //   · isHighParallel() 为 false → 不启用多源轮询钉源，交给 pickBestSource 按吞吐收敛，
    //     BMCLAPI 与 Mojang 不会被强制各占一半段。
    // 实际能到多少还受 engine.cpp 每主机并发闸门（kWorkerHostInitialLimit=4）约束：
    // client 只有 2 个源 → 上限 4+4=8 条。那个常量影响所有下载，单独评估，不在本次一起动。
    let file: DownloadFileSpec = {
      localPath: clientPath,
      urls: urls,
      allowedRoot: destDir,
      check: { sha1: clientSha1, size: clientSize },
    };
    let spec: DownloadTaskSpec = {
      name: `client.jar ${version}`,
      files: [file],
      activityId: this.activityId,
    };

    try {
      await this.mgr.createAndWait(spec, (v: DownloadTaskView) => {
        this.trackTask_(v.taskId);
        let dlMB = (v.bytesDone / 1048576).toFixed(1);
        let pct = Math.round((v.progress || 0) * 100);
        this.reportFromView('下载 client.jar', v.bytesDone, clientSize,
          `${dlMB}/${totalMB} MB (${pct}%) ${this.currentSpeed}`, v);
      });
    } catch (e) {
      if (this.cancelled) throw new CancelledError();
      throw new Error('client.jar 下载失败: ' + (e as Error).message);
    } finally {
      this.activeTaskId = 0;
    }

    if (this.cancelled) throw new CancelledError();
    return `✅ client.jar (${totalMB} MB)`;
  }

  /**
   * 下载 libraries 到 mcDir/libraries/。
   *
   * 整个 libraries 集合作为**一个** DownloadTask 提交给 NAPI 引擎：
   *   - 多个 NetFile（一个 lib 一个），共享 Engine 的 worker pool
   *   - 小 lib 单段直下，大 lib 多段分下（NetFile.Config.piece_min_bytes=1MB）
   *   - 每 lib 独立 sha1+size 校验
   *
   * 失败语义：任一 lib 最终失败（所有源耗尽）→ 整个 task 进 Failed 状态 →
   * createAndWait reject。Stage 3c 再细化成 "部分失败 + 继续" 的策略。
   */
  async downloadLibraries(versionJson: VersionJson, onlyMissing: boolean = false): Promise<string> {
    let safeVersionId = requireSafeSegment(versionJson.id, 'versionJson.id');
    let libs = McDownloader.filterLibraries(versionJson.libraries);
    let libTotal = libs.length;
    let files: DownloadFileSpec[] = [];
    let librariesRoot = this.mcDir + '/libraries';
    let seenPaths: Set<string> = new Set<string>();
    this.ensureDir(librariesRoot);

    // H-1 修复：删除 fileIsValid 短路。所有文件都提交给引擎，引擎的
    // preCheckExistingFile 会做 size+SHA1 校验：命中即转 Finished、不发 HTTP，
    // 不命中则真实下载。原 ArkTS 短路只比 size，会让 SHA1 不匹配的损坏文件被接受。
    //
    // onlyMissing（2026-06-07，给 RepairTask 用）：仅补【磁盘上不存在】的库，跳过已存在的。
    //   原因：Forge 的部分依赖库是安装器本地处理产物，磁盘 sha1 与 json 声明【天然不一致】，
    //   若按引擎 sha1 预检会被判"需重下"，而标准镜像没有这些件 → 整任务失败。补全场景下
    //   我们只关心"文件在不在"，存在即视为可用（真·内容损坏会在启动前 ZIP 头校验里被删除、
    //   再转为缺失被本方法补回）。
    for (let lib of libs) {
      // OHOS 用自带 lwjgl-ohos 替换全部原版 LWJGL；jinput 手柄库 OHOS 也不用（输入走 XComponent）。
      // 这些库在 LaunchProfileBuilder.buildClasspath 里本就被跳过（不进 classpath、不计入完整性
      // 校验），故下载也必须一致跳过。
      // ⚠️ 2026-06-13 修复（1.7.10 等 ≤1.12 安装失败根因）：老 MC 的 lwjgl-platform / jinput-platform
      //   是【natives 打包 jar】——真实产物只有带 classifier 的 *-natives-<os>.jar，不带 classifier
      //   的基础 jar（lwjgl-platform-2.9.1.jar）在所有仓库都 404。上一版（1000170）放开老格式库下载后，
      //   会按坐标拼出这个不存在的基础 jar 路径 → 全源 404 → 拖垮整批 libraries 下载、安装失败。
      //   OHOS 不需要这些原版 natives（用自带 lwjgl-ohos），直接跳过。
      let coord = lib.name
      if (coord.indexOf('org.lwjgl') === 0
        || coord.indexOf('net.java.jinput') === 0
        || coord.indexOf('net.java.jutils') === 0) {
        continue
      }
      if (lib.downloads && lib.downloads.artifact) {
        // ---- 现代格式：downloads.artifact 自带 path/url/sha1/size ----
        let artifact = lib.downloads.artifact;
        let artifactPath = requireSafeRelativePath(artifact.path, 'library artifact.path');
        let artifactSha1 = requireSha1(artifact.sha1, 'library artifact.sha1');
        if (artifact.size <= 0) throw new Error('library artifact.size 非法: ' + lib.name);
        let libPath = librariesRoot + '/' + artifactPath;

        if (onlyMissing && this.fileSize(libPath) > 0) continue;
        if (seenPaths.has(libPath)) continue;
        seenPaths.add(libPath);

        let libDir = libPath.substring(0, libPath.lastIndexOf('/'));
        this.ensureDir(libDir);

        let urls = validatedUrls(buildSortedUrls(
          BMCLAPI_BASE + '/maven/' + artifactPath,
          artifact.url || (MOJANG_LIBRARIES + '/' + artifactPath)
        ), 'library artifact.urls');

        files.push({
          localPath: libPath,
          urls: urls,
          allowedRoot: librariesRoot,
          check: { sha1: artifactSha1, size: artifact.size },
        });
      } else {
        // ---- 老格式（FML legacy，如 1.8.9 Forge）：仅 name + 可选 url 仓库根，无 downloads.artifact ----
        //
        // 2026-06-13 修复：原先这里 `if (!lib.downloads || !lib.downloads.artifact) continue;`
        // 把所有老格式库直接跳过 → RepairTask"修复"对 1.8.9 等老 Forge 的依赖库（launchwrapper /
        // asm-all / scala-* / akka / typesafe-config / jline 等）根本不下载 → 修复后完整性校验
        // 仍报缺失。这些库在老 FML 的 version.json 里只声明 name（+ 偶有仓库根 url），需用坐标
        // 重构 maven 路径并做多源回退。死链 files.minecraftforge.net 重写为 maven.minecraftforge.net。
        let relPath = requireSafeRelativePath(mavenToRelativePath(lib.name), 'legacy maven path');
        let libPath = librariesRoot + '/' + relPath;

        if (onlyMissing && this.fileSize(libPath) > 0) continue;
        if (seenPaths.has(libPath)) continue;
        seenPaths.add(libPath);

        let libDir = libPath.substring(0, libPath.lastIndexOf('/'));
        this.ensureDir(libDir);

        let candidates: string[] = [];
        // BMCLAPI /maven 镜像（同时代理 forge maven + central，国内最稳）优先
        candidates.push(BMCLAPI_BASE + '/maven/' + relPath);
        // lib 自带仓库根（死链 files.minecraftforge.net 重写为现役 maven.minecraftforge.net）
        if (lib.url && lib.url.length > 0) {
          let root = lib.url
            .replace('http://files.minecraftforge.net/maven/', 'https://maven.minecraftforge.net/')
            .replace('https://files.minecraftforge.net/maven/', 'https://maven.minecraftforge.net/');
          if (isSafeHttpUrl(root)) {
            if (!root.endsWith('/')) root += '/';
            let u = root + relPath;
            if (isSafeHttpUrl(u) && candidates.indexOf(u) < 0) candidates.push(u);
          }
        }
        // 通用兜底源：forge maven（FML 专属库）+ 阿里云（central 镜像）+ Mojang 官方库
        let extras = [
          'https://maven.minecraftforge.net/' + relPath,
          'https://maven.aliyun.com/repository/public/' + relPath,
          MOJANG_LIBRARIES + '/' + relPath,
        ];
        for (let u of extras) {
          if (candidates.indexOf(u) < 0) candidates.push(u);
        }

        let safeCandidates = validatedUrls(candidates, 'legacy library.urls');
        // 老格式无 sha1/size → 不传 check，引擎只校验非空 + PK 头（合法 JAR）。
        files.push({
          localPath: libPath,
          urls: safeCandidates,
          allowedRoot: librariesRoot,
        });
      }
    }

    let toCheck = files.length;
    if (toCheck === 0) {
      return `✅ libraries: 0 (共 ${libTotal})`;
    }

    this.alog().info(TAG, `Downloading/verifying ${toCheck} libraries...`, LOG_DOMAIN_DOWNLOAD);
    this.report('下载 libraries', 0, libTotal, toCheck + ' 校验/下载');

    // v5.1 S2-1: 引擎内部已有 30 次重试 + 1 次 NetFile Retried，无需 ArkTS 层叠加。
    // 失败后由 DownloadTask.retry() 处理，用户可手动重试。
    if (this.cancelled) throw new CancelledError();

    // B-2 修复（2026-05-26）：拼上 versionJson.id 防止两个 MC 版本同时下载时因
    // 文件数偶然相等被 DownloadManager.isTaskActiveByName 误判为重复任务。
    // 详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-2
    let spec: DownloadTaskSpec = {
      name: `libraries ${safeVersionId} (${toCheck} files)`,
      files: files,
      activityId: this.activityId,
    };

    try {
      await this.mgr.createAndWait(spec, (v: DownloadTaskView) => {
        this.trackTask_(v.taskId);
        // H-1 修复：filesDone 现在反映"引擎校验/下载完成"的真实数量
        let done = v.filesDone;
        let curName = basename(v.currentFile) || `${done}/${libTotal}`;
        this.reportFromView('下载 libraries', done, libTotal,
          curName + ' ' + this.currentSpeed, v);
      });
    } finally {
      this.activeTaskId = 0;
    }

    if (this.cancelled) throw new CancelledError();
    // H-1 修复：原 "新下载 / 已存在" 区分依赖 ArkTS 短路；现在所有文件由引擎统一校验，
    // ArkTS 无法区分"原本已存在"和"刚下载"，只能给汇总数。
    return `✅ libraries: ${toCheck} 校验/下载 (共 ${libTotal})`;
  }

  /**
   * 下载 assets 到 mcDir/assets/。
   *
   * Asset 的特殊性：
   *   - 每个对象的文件名就是它的 sha1 —— 校验天然靠谱
   *   - 一般几千个小文件（<1MB），piece_limit=1 单段下载即可，不分段
   *   - BMCLAPI 为主，Mojang resources.download 为备
   *
   * asset index 也走 fetchText NAPI（Phase 3.5），按 sha1 寻址永久缓存（Phase 2.3）。
   */
  async downloadAssets(versionJson: VersionJson): Promise<string> {
    if (!versionJson.assetIndex) return 'ℹ️ 无 asset index';

    // assetIndex.id 决定我们写到磁盘的文件名，必须是安全段 —— 这条保留硬校验。
    let assetIndexId = requireSafeSegment(versionJson.assetIndex.id, 'assetIndex.id');
    // ⚠️ 2026-08-04：sha1 / size 从「非法就整体抛」改为「降级」。
    //   BMCLAPI 的 `/v1/packages/<sha1>/<id>.json` 需要 sha1；sha1 不合法时只是
    //   拿不到这个镜像 URL，官方 `assetIndex.url` 依然可用，没有任何理由整段失败。
    //   size 同理：它只用来判断本地缓存是否还有效，size 未知 → 当作"必须重下"。
    //   PCL2 在这两处都不做格式校验（ModMinecraft.vb McAssetsListGet 直接用），
    //   7-15 之前的 AMCL 也不做。
    let indexSha1Raw = versionJson.assetIndex.sha1;
    let assetIndexSha1 = isValidSha1(indexSha1Raw) ? indexSha1Raw.toLowerCase() : '';
    let indexSize = versionJson.assetIndex.size;
    let indexesRoot = this.mcDir + '/assets/indexes';
    let objectsRoot = this.mcDir + '/assets/objects';
    this.ensureDir(indexesRoot);
    this.ensureDir(objectsRoot);

    // 1) asset index（元数据，单次 NAPI 调用 + 内部多源 fallback；URL 按 sha1 寻址 → 永不过期）
    //
    // H-1 修复说明：这里 fileIsValid 是保留的 — asset_index 通过 sha1 寻址 URL 拉取
    //   （`/v1/packages/<sha1>/<id>.json`），收到的内容隐式校验了 sha1。本地缓存路径
    //   下 JSON.parse 失败也会触发重下，覆盖了"内容损坏"场景。比走完整 NAPI 任务的
    //   开销小一个数量级，且依赖的整数 size 比对足够触发"应该重下"判断。
    let assetIndexPath = indexesRoot + '/' + assetIndexId + '.json';
    // size 未知（<=0）时 fileIsValid 必然不成立 → 强制重下，与旧行为一致。
    if (!this.fileIsValid(assetIndexPath, indexSize)) {
      // sha1 不合法 → 只用官方 URL（镜像那条按 sha1 寻址，没法拼）。
      let indexCandidates: string[] = assetIndexSha1.length > 0
        ? buildSortedUrls(
            BMCLAPI_BASE + '/v1/packages/' + assetIndexSha1 + '/' + assetIndexId + '.json',
            versionJson.assetIndex.url)
        : [versionJson.assetIndex.url];
      let indexUrls = validatedUrls(indexCandidates, 'assetIndex.urls');
      let primary = indexUrls[0];
      let mirrors = indexUrls.slice(1);
      let content = await this.httpGet(primary, mirrors, IMMUTABLE_CACHE_MS);
      if (content.length === 0) throw new Error('所有源均无法获取 asset index（尝试了 ' + indexUrls.length + ' 个源）');
      this.writeFile(assetIndexPath, content);
    }

    // 2) 解析 asset index
    let assetIndexContent = this.readFileContent(assetIndexPath);
    if (assetIndexContent.length === 0) return '⚠️ asset index 为空';

    let assetData = JSON.parse(assetIndexContent) as AssetIndexData;
    let objects = assetData.objects;
    let assetKeys = Object.keys(objects);
    let assetTotal = assetKeys.length;

    // ---- 2.5) 判定落盘布局（对齐 PCL2 ModMinecraft.vb:2310-2325 McAssetsListGet）----
    //
    // Mojang 的历史包袱，不是我们的选择：
    //   pre-1.6  → map_to_resources：按**资源名**落地
    //   ≤1.6.4   → virtual：按**资源名**落到 assets/virtual/legacy/
    //   1.7+     → 按 hash 落到 assets/objects/<2>/<hash>
    //
    // 之前 AMCL 只实现了第三种，于是 1.6.4 这类版本装完「没有声音、语言文件缺失」：
    // 实测 legacy.json 有 1120 个条目但只有 596 个唯一 hash（524 个条目共享 hash），
    // 按 hash 落盘后磁盘上只有 596 个以 hash 命名的文件，游戏按名字一个都找不到。
    //
    // 与 PCL2 的**一处刻意偏差**：PCL2 把 `map_to_resources` 索引落到
    // `Instance.PathIndie\resources\`，同时又把 `${game_assets}` 指向
    // `assets\virtual\legacy`（ModLaunch.vb:1661，原注释「1.5.2 的 pre-1.6 资源索引
    // 应与 legacy 合并」）。既然启动参数指向后者，我们就把两种老索引统一落到
    // virtual/legacy —— 下载落点与游戏读取点始终一致，也少一个需要外部注入的目录。
    let layout: AssetLayout =
      (assetData.map_to_resources === true || assetData.virtual === true)
        ? AssetLayout.VIRTUAL
        : AssetLayout.OBJECTS;
    let layoutRoot = layout === AssetLayout.OBJECTS
      ? objectsRoot
      : this.mcDir + '/assets/virtual/legacy';
    if (layout !== AssetLayout.OBJECTS) {
      this.ensureDir(layoutRoot);
      this.alog().info(TAG,
        `asset index '${assetIndexId}' uses legacy layout=${layout} root=${layoutRoot}`,
        LOG_DOMAIN_DOWNLOAD);
    } else {
      // 预建 256 个 hash prefix 目录（避免每次 mkdirSync 都走 FS）
      for (let i = 0; i < 256; i++) {
        this.ensureDir(objectsRoot + '/' + i.toString(16).padStart(2, '0'));
      }
    }

    // 3) 构造 NAPI 文件规格
    // H-1 修复：删除 fileIsValid 短路。所有 asset 都提交给引擎，
    // 已存在且 sha1 匹配的会被 preCheckExistingFile 瞬间转 Finished、不发 HTTP。
    //
    // ⚠️ 2026-08-04：**逐条容错，不再整批抛**。
    //   07-16 那版对每个对象做 `requireSha1` + `size<=0 throw`，任何一条不合规就让
    //   整个 assets 阶段在下载一个字节之前抛出，进而整个版本安装失败。PCL2 从不这样：
    //   它把 size=0 记成 `ActualSize:=-1`（未知）照样下，也不校验 hash 格式
    //   （`New FileChecker(ActualSize:=If(Size=0,-1,Size), Hash:=Hash)`）；
    //   7-15 之前的 AMCL 同样没有这些校验。现在改成跳过坏条目并计数告警，
    //   既保住路径安全，也不让一条脏数据毁掉整次安装。
    let files: DownloadFileSpec[] = [];
    let seenPaths: Set<string> = new Set<string>();
    let ensuredDirs: Set<string> = new Set<string>();
    let skippedBadHash = 0;
    let skippedBadName = 0;
    let skippedBadUrl = 0;
    let unknownSize = 0;
    for (let key of assetKeys) {
      let obj = objects[key];
      let rawHash = obj.hash;
      if (!isValidSha1(rawHash)) { skippedBadHash++; continue; }
      let hash = rawHash.toLowerCase();
      let prefix = hash.substring(0, 2);

      // 落地路径：按布局决定。named 布局用**资源名**（可能带多级目录）。
      let destPath: string;
      if (layout === AssetLayout.OBJECTS) {
        destPath = objectsRoot + '/' + prefix + '/' + hash;
      } else {
        let relName = safeRelPath(key);
        if (relName.length === 0) { skippedBadName++; continue; }
        destPath = layoutRoot + '/' + relName;
      }
      if (seenPaths.has(destPath)) continue;
      seenPaths.add(destPath);

      // named 布局的父目录要现建（objects 布局的 256 个前缀目录已预建）
      if (layout !== AssetLayout.OBJECTS) {
        let slash = destPath.lastIndexOf('/');
        if (slash > 0) {
          let parent = destPath.substring(0, slash);
          if (!ensuredDirs.has(parent)) {
            ensuredDirs.add(parent);
            this.ensureDir(parent);
          }
        }
      }

      // URL 与布局无关：始终按 hash 寻址（PCL2 也是
      // `DlSourceAssetsGet($"https://resources.download.minecraft.net/{Left(Hash,2)}/{Hash}")`）。
      let urls: string[];
      try {
        urls = validatedUrls(buildSortedUrls(
          BMCLAPI_BASE + '/assets/' + prefix + '/' + hash,
          MOJANG_RESOURCES + '/' + prefix + '/' + hash
        ), 'asset object.urls');
      } catch (e) {
        skippedBadUrl++;
        seenPaths.delete(destPath);
        continue;
      }

      // size 缺失或非正 → 不传 size，只靠 sha1 校验（PCL2 的 ActualSize=-1 语义）。
      // 先归一到 0 再判断，这样 `size` 字段整体缺失（undefined）也走同一分支并被计数。
      let objSize: number = obj.size > 0 ? obj.size : 0;
      let check: DownloadCheck = objSize > 0
        ? { sha1: hash, size: objSize }
        : { sha1: hash };
      if (objSize <= 0) unknownSize++;

      files.push({
        localPath: destPath,
        urls: urls,
        allowedRoot: layoutRoot,
        check: check,
      });
    }

    let skippedTotal = skippedBadHash + skippedBadName + skippedBadUrl;
    if (skippedTotal > 0 || unknownSize > 0) {
      this.alog().warn(TAG,
        `assets index '${assetIndexId}': skipped ${skippedTotal} entr(ies) `
        + `(badHash=${skippedBadHash} badName=${skippedBadName} badUrl=${skippedBadUrl}), `
        + `${unknownSize} without a usable size (sha1-only check)`,
        null, LOG_DOMAIN_DOWNLOAD);
    }

    let toCheck = files.length;
    this.report('下载 assets', 0, assetTotal, toCheck + ' 校验/下载');

    if (toCheck === 0) {
      this.report('下载 assets', assetTotal, assetTotal, '完成');
      return `✅ assets: 0 (共 ${assetTotal})`;
    }

    this.alog().info(TAG, `Downloading/verifying ${toCheck} assets...`, LOG_DOMAIN_DOWNLOAD);

    // v5.1 S2-1: 引擎内部已有 30 次重试 + 1 次 NetFile Retried，无需 ArkTS 层叠加。
    // 失败后由 DownloadTask.retry() 处理，用户可手动重试。
    if (this.cancelled) throw new CancelledError();

    // B-2 修复（2026-05-26）：拼上 assetIndex.id 让不同 asset 索引的并发能区分；
    // 同 asset 索引（多个 MC 版本可能共享同一个，如 1.19.x 系列共享 '1.19'）则
    // 仍互斥 —— 它们落地到同一个 assets/objects 目录，并发会触发 rename 竞态。
    // 详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-2
    let spec: DownloadTaskSpec = {
      name: `assets ${assetIndexId} (${toCheck} files)`,
      files: files,
      activityId: this.activityId,
    };
    this.alog().info(TAG,
      `assets task: index=${assetIndexId} layout=${layout} files=${toCheck}/${assetTotal}`,
      LOG_DOMAIN_DOWNLOAD);

    try {
      await this.mgr.createAndWait(spec, (v: DownloadTaskView) => {
        this.trackTask_(v.taskId);
        // H-1 修复：filesDone 反映引擎已完成（含 preCheck 命中）的真实数量
        let done = v.filesDone;
        let curName = basename(v.currentFile) || `${done}/${assetTotal}`;
        this.reportFromView('下载 assets', done, assetTotal,
          curName + ' ' + this.currentSpeed, v);
      });
    } finally {
      this.activeTaskId = 0;
    }

    if (this.cancelled) throw new CancelledError();
    this.report('下载 assets', assetTotal, assetTotal, '完成');
    // H-1 修复：原 "新下载 / 已存在" 区分依赖 ArkTS 短路；现在所有文件由引擎统一校验。
    let skippedNote = skippedTotal > 0 ? `，跳过 ${skippedTotal} 条无效条目` : '';
    return `✅ assets: ${toCheck} 校验/下载 (共 ${assetTotal})${skippedNote}`;
  }

  // ============================================================
  //  过滤 libraries
  // ============================================================

  /**
   * 过滤 libraries
   * - 无 rules → 包含
   * - java-objc-bridge → 强制包含（MC 的 eoy 类直接引用 ca.weblite.objc.Client）
   *   我们通过提供 dummy libobjc.A.so 来防止 JNA 加载崩溃
   * - 其他有 rules 的 → 标准 allow/disallow 判断（伪装为 Linux）
   *
   * 2026-05-06：Phase 7 解锁为 public static 以支持纯函数单元测试（零 IO / 零 NAPI）。
   */
  static filterLibraries(libraries: LibraryEntry[]): LibraryEntry[] {
    let result: LibraryEntry[] = [];
    for (let lib of libraries) {
      if (!lib.rules) { result.push(lib); continue; }
      // java-objc-bridge 必须保留（MC 硬依赖）
      if (lib.name.indexOf('java-objc-bridge') >= 0) {
        result.push(lib);
        continue;
      }
      // 标准 rules 判断
      let dominated_allow = false;
      let dominated_disallow = false;
      for (let rule of lib.rules) {
        if (rule.action === 'allow') {
          if (!rule.os || rule.os.name === 'linux') dominated_allow = true;
        } else if (rule.action === 'disallow') {
          if (rule.os && rule.os.name === 'linux') dominated_disallow = true;
        }
      }
      if (dominated_allow && !dominated_disallow) {
        result.push(lib);
      } else {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'Excluded library by rules: %{public}s', lib.name);
      }
    }
    return result;
  }

  // ============================================================
  //  文件工具
  // ============================================================

  private ensureDir(dir: string) {
    try { fs.mkdirSync(dir, true); } catch (e) { /* 已存在 */ }
  }

  private fileSize(path: string): number {
    try { return fs.statSync(path).size; } catch (e) { return -1; }
  }

  private fileIsValid(path: string, expectedSize?: number): boolean {
    let size = this.fileSize(path);
    if (size <= 0) return false;
    if (expectedSize !== undefined && expectedSize > 0 && size !== expectedSize) return false;
    return true;
  }

  // 2026-05-23 ArkTS 严格模式：fs.openSync / writeSync / closeSync 报
  // 'Function may throw'。详见 docs/guides/api-migration-2026-05.md。
  private writeFile(path: string, content: string) {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } catch (e) {
      this.alog().warn(TAG, `writeFile ${path} failed`, e, LOG_DOMAIN_DOWNLOAD);
      throw e as Error;
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) { /* ignore */ }
      }
    }
  }

  /**
   * 读全文件内容（UTF-8 解码）。
   *
   * M-6 修复：原实现固定 4MB 缓冲，对超大 asset_index（MC 1.21+ 接近或超过 4MB）
   * 会**静默截断** → JSON.parse 抛错且根因难定位。
   * 新实现先 `statSync` 拿真实大小再按需分配；分配上限 64MB 防御性兜底
   * （asset_index 实测远小于此），超限直接报错返回空字符串。
   */
  private readFileContent(path: string): string {
    try {
      let stat = fs.statSync(path);
      const MAX_SIZE = 64 * 1024 * 1024;  // 64MB 防御上限
      if (stat.size <= 0) return '';
      if (stat.size > MAX_SIZE) {
        this.alog().warn(TAG, `readFileContent: file too large (${stat.size} bytes, max ${MAX_SIZE}): ${path}`, null, LOG_DOMAIN_DOWNLOAD);
        return '';
      }
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let buf = new ArrayBuffer(stat.size);
        // 大文件可能需多次 read 才能填满（OHOS readSync 不保证一次读完）
        let total = 0;
        while (total < stat.size) {
          let n = fs.readSync(file.fd, buf, { offset: total, length: stat.size - total });
          if (n <= 0) break;
          total += n;
        }
        // 2026-05-23 API NEXT 迁移：`new util.TextDecoder(...)` + `decodeWithStream`
        // 在 API 12+ 起被弃用，官方推荐 `util.TextDecoder.create(encoding)`
        // + `decodeToString(buffer)`。语义等价。
        // 详见 docs/guides/api-migration-2026-05.md。
        let decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(buf, 0, total));
      } finally { fs.closeSync(file); }
    } catch (e) { return ''; }
  }
}

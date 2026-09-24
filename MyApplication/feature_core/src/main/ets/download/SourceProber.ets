/**
 * SourceProber.ets — 下载源探测与智能选择
 *
 * 下载前对各源发送小文件 GET 测速，根据 RTT 和可用性排序源优先级。
 * 参考 HMCL AutoDownloadProvider（区域自动选）+ XMCL（RTT 探测）。
 *
 * M-5 修复：原实现用 @kit.NetworkKit 的 http 直接发 GET，证书走 OHOS 系统 CA；
 * 而实际下载（Engine）走 cacert.pem 自带 CA。两者证书库不一致时探测说 BMCLAPI
 * 通但下载因 SSL 校验失败（或反向），导致源选择与实际可达性脱节。
 *
 * 修复改为统一走 `DownloadManager.fetchTextEx` —— 即调引擎自身的 NAPI fetch，
 * 与所有下载路径共用 cacert + curl_share + bad host 黑名单。
 */

import { AppLogger, BMCLAPI_BASE, MOJANG_RESOURCES } from 'commons';
import { DownloadManager } from './DownloadManager';

const TAG = 'SourceProber';

export interface SourceProbeResult {
  id: string;
  name: string;
  baseUrl: string;
  rttMs: number;
  available: boolean;
  httpStatus: number;
}

export interface SourceRanking {
  results: SourceProbeResult[];
  bmclapiFirst: boolean;
  probedAt: number;
}

const PROBE_TIMEOUT_MS = 8000;
const PROBE_MAX_AGE_MS = 30 * 60 * 1000;

const PROBE_ASSET_HASH = 'bdf48ef6b5d0d23bbb02e17d04865216179f510a';
const PROBE_ASSET_PREFIX = 'bd';

/**
 * auto 模式下「官方源算不算慢」的门槛（毫秒）。
 * 直接沿用 PCL2 的常量：`DlPreferMojang = DeltaTime < 4000`（ModDownload.vb:237）。
 */
const PREFER_MOJANG_MAX_RTT_MS = 4000;

let cachedRanking: SourceRanking | null = null;

// ============================================================================
//  版本下载源偏好（2026-08-04 新增）
//
//  在此之前，MC 版本 / libraries / assets 的源顺序**完全**由本文件的 RTT 探测决定，
//  没有任何地方读用户偏好 —— 设置页里那个 auto/mcim/official 开关只作用于模组
//  （PreferenceManager.modSource → ModrinthSourceMode），结构上不可能影响版本下载。
//  用户选了"官方"却仍走 BMCLAPI，就是因为这条链根本不存在。
//
//  更糟的是 `shouldUseBmclapiFirst()` 在**没有探测缓存时无条件返回 true**。
//  2026-08-04 真机上探测因 fd 耗尽（见 net_file.cpp 的 fd 治理注释）两个源全部失败，
//  于是源顺序永久钉死在"镜像优先"，任何切换都不可能生效。
//
//  设计对齐 PCL2 的 `ToolDownloadSource`（ModDownload.vb:1212-1223）：
//    0 尽量使用镜像源 / 1 优先官方、慢了换镜像 / 2 尽量使用官方源
//  它的 `DlSourceOrder(OfficialUrls, MirrorUrls)` 只做**重排**，两个源始终都在列表里。
//  我们照搬这个关键性质：偏好只影响顺序，永不删源 —— 所以"强制官方"在官方挂掉时
//  仍会自动回退到镜像，用户的选择被尊重，可用性也不受损。
// ============================================================================

/**
 * 当前偏好：
 *   'auto'     = RTT 探测决定（默认）
 *   'mirror'   = 镜像 BMCLAPI 优先
 *   'official' = 官方 Mojang 优先
 */
let sourcePreference: string = 'auto';

/** 归一化脏数据到 'auto'。 */
function normalizeMode(mode: string): string {
  return (mode === 'mirror' || mode === 'official') ? mode : 'auto';
}

/**
 * 注入用户的版本下载源偏好。由 Index 在读盘时和用户切换时各调一次
 * （与 `setJdkDownloadSource` 同款注入模式，避免 feature_core 反向依赖 feature_system）。
 */
export function setMcSourcePreference(mode: string): void {
  let normalized = normalizeMode(mode);
  if (normalized === sourcePreference) return;
  sourcePreference = normalized;
  // 偏好变了就丢掉探测缓存：从 official/mirror 切回 auto 时，应该重新探一次，
  // 而不是沿用切换之前那份可能已过时的排名。
  cachedRanking = null;
  AppLogger.info(TAG, 'MC download source preference set to ' + normalized);
}

export function getMcSourcePreference(): string {
  return sourcePreference;
}

async function probeSource(id: string, name: string, baseUrl: string, url: string): Promise<SourceProbeResult> {
  let startMs = Date.now();
  let result: SourceProbeResult = {
    id, name, baseUrl, rttMs: -1, available: false, httpStatus: 0
  };

  // M-5 修复：改走引擎 fetchTextEx —— 与下载实际链路同 CA、同 share、同 bad host 黑名单。
  // Range:bytes=0-0 让 server 仅返回 1 字节（206 Partial Content）；
  // 老镜像不支持 Range 时会回 200 全文（最多几 KB asset），不会爆。
  // fetchTextEx 把 200-299 / 304 视为 ok，206 也属 200-299 → available=true。
  try {
    let timeoutSec = Math.floor(PROBE_TIMEOUT_MS / 1000);
    let resp = await DownloadManager.instance().fetchTextEx(
      url, [], timeoutSec,
      { 'Range': 'bytes=0-0' } as Record<string, string>);
    result.httpStatus = resp.statusCode;
    result.rttMs = Date.now() - startMs;
    result.available = resp.statusCode >= 200 && resp.statusCode < 400;
  } catch (e) {
    result.rttMs = Date.now() - startMs;
    result.available = false;
    AppLogger.warn(TAG, 'Probe ' + id + ' failed: ' + ((e as Error).message || String(e)));
  }

  AppLogger.info(TAG, 'Probe ' + id + ': rtt=' + result.rttMs + 'ms available='
    + (result.available ? 'true' : 'false') + ' http=' + result.httpStatus);
  return result;
}

/**
 * 探测所有源的可用性和延迟。
 * 使用一个已知的 asset 小文件做 Range:bytes=0-0 请求（只取 1 字节），测 RTT。
 */
export async function probeAllSources(): Promise<SourceRanking> {
  AppLogger.info(TAG, 'Starting source probe...');

  let bmclapiUrl = BMCLAPI_BASE + '/assets/' + PROBE_ASSET_PREFIX + '/' + PROBE_ASSET_HASH;
  let mojangUrl = MOJANG_RESOURCES + '/' + PROBE_ASSET_PREFIX + '/' + PROBE_ASSET_HASH;

  let probeResults = await Promise.all([
    probeSource('bmclapi', 'BMCLAPI 镜像', BMCLAPI_BASE, bmclapiUrl),
    probeSource('mojang', 'Mojang 官方', MOJANG_RESOURCES, mojangUrl),
  ]);
  let bmclapi = probeResults[0];
  let mojang = probeResults[1];

  let results = [bmclapi, mojang];
  let bmclapiFirst: boolean;

  // ⚠️ 2026-08-04：auto 的判据从「比 RTT」改成 PCL2 的「官方优先，除非官方明显慢」。
  //
  //   PCL2（ModDownload.vb:229-240 DlClientListMojangMain）：
  //       DlPreferMojang = (拉 Mojang 版本清单的耗时 < 4000ms)
  //   然后 ModDownload.vb:1214-1218：
  //       DlSourcePreferMojang = 设置==2 OrElse (设置==1 AndAlso DlPreferMojang)
  //   默认设置就是 1，所以**PCL2 默认是官方优先**，只有官方慢到 4 秒以上才让镜像上位。
  //
  //   为什么这条对 assets 是决定性的：PCL2 只在**实际选中的源是 bmclapi** 时才
  //   `Thread.Sleep(100)` 节流（ModNet.vb:1822/1842）。官方源不节流。所以官方优先时
  //   5000 个 asset 能直接铺到 64 并发，镜像优先时被压到约 20 条/秒。
  //   而 AMCL 原来的「谁 RTT 低选谁」在国内网络下几乎必然选中 BMCLAPI（真机实测
  //   bmclapi RTT 明显低于 Mojang），于是天天走在被节流的那条路上 —— 这正是
  //   assets「4~5 个文件/秒、4750 个要跑十几分钟」的直接原因之一。
  //
  //   4000ms 这个阈值直接沿用 PCL2 的常量；我们量的是 1 字节 Range GET 的 RTT，
  //   比 PCL2 量的整份清单下载更宽松，所以只要官方**可达且没有异常慢**就走官方。
  if (mojang.available && mojang.rttMs >= 0 && mojang.rttMs < PREFER_MOJANG_MAX_RTT_MS) {
    bmclapiFirst = false;          // 官方可用且不慢 → 官方优先（PCL2 默认行为）
  } else if (bmclapi.available) {
    bmclapiFirst = true;           // 官方不可用/太慢，镜像能用 → 镜像优先
  } else if (mojang.available) {
    bmclapiFirst = false;          // 只有官方能用（哪怕慢）
  } else {
    bmclapiFirst = true;           // 都不可用：保持镜像优先的历史默认
  }

  let ranking: SourceRanking = {
    results,
    bmclapiFirst,
    probedAt: Date.now(),
  };

  // ⚠️ 2026-08-04：两个源**都**探不通时不要写缓存。
  //   这一轮探测没有任何信息量 —— 真机上它就是被 fd 耗尽后瘫痪的 libcurl 打挂的
  //   （两个 URL 都返回 "A libcurl function was given a bad argument"）。
  //   把这种结果缓存下来，等于让接下来 30 分钟的源顺序全按一个凭空的默认值走，
  //   而且下一次 ensureRanking 因为命中缓存**不会重探**，问题被固化。
  //   不缓存 → 下次调用会重新探测，网络恢复后能立刻反映真实排名。
  if (!bmclapi.available && !mojang.available) {
    AppLogger.warn(TAG, 'Source probe: both sources unreachable; ranking NOT cached so the next call re-probes');
    return ranking;
  }

  cachedRanking = ranking;
  AppLogger.info(TAG, 'Source probe complete (PCL2 rule: official-first unless official >= '
    + PREFER_MOJANG_MAX_RTT_MS + 'ms): bmclapiFirst=' + (bmclapiFirst ? 'true' : 'false')
    + ' bmclapiRtt=' + bmclapi.rttMs + ' mojangRtt=' + mojang.rttMs);
  return ranking;
}

/**
 * 获取缓存的源排名。如果未探测或已过期（>30 分钟），返回 null。
 */
export function getCachedRanking(): SourceRanking | null {
  if (!cachedRanking) return null;
  if (Date.now() - cachedRanking.probedAt > PROBE_MAX_AGE_MS) return null;
  return cachedRanking;
}

/**
 * 获取源排名，如果未缓存则自动探测。
 *
 * 用户已显式指定源时**直接跳过探测**：探测结果反正不会被采用，还要白等最多 8 秒
 * （PROBE_TIMEOUT_MS）。真机上这 8 秒全花在每次下载开始前，纯粹是浪费。
 */
export async function ensureRanking(): Promise<SourceRanking> {
  if (sourcePreference !== 'auto') {
    let forced: SourceRanking = {
      results: [],
      bmclapiFirst: sourcePreference === 'mirror',
      probedAt: Date.now(),
    };
    return forced;   // 不写 cachedRanking：这不是探测结论
  }
  let cached = getCachedRanking();
  if (cached) return cached;
  return probeAllSources();
}

/**
 * 是否应优先使用 BMCLAPI 镜像。
 *
 * 优先级：**用户显式选择 > RTT 探测缓存 > 默认镜像优先**。
 * 用户选了就无条件照办 —— 探测结果、探测失败、缓存过期一律不得覆盖它。
 */
export function shouldUseBmclapiFirst(): boolean {
  if (sourcePreference === 'mirror') return true;
  if (sourcePreference === 'official') return false;
  let cached = getCachedRanking();
  if (!cached) return true;
  return cached.bmclapiFirst;
}

/**
 * 构建按优先级排序的 URL 列表（用于 NAPI 引擎的 DownloadFileSpec.urls）。
 *
 * 注意语义：这里只**重排**，两个源永远都在列表里（对齐 PCL2 的 DlSourceOrder）。
 * 所以"强制官方"在官方源挂掉时仍会自动回退到镜像 —— 尊重用户选择，但不牺牲可用性。
 * 引擎侧的多源 fallback（NetFile::pickBestSource）负责实际的切换。
 *
 * @param bmclapiUrl BMCLAPI 镜像 URL
 * @param mojangUrl Mojang 官方 URL
 */
export function buildSortedUrls(bmclapiUrl: string, mojangUrl: string): string[] {
  if (shouldUseBmclapiFirst()) {
    return [bmclapiUrl, mojangUrl];
  } else {
    return [mojangUrl, bmclapiUrl];
  }
}

export function clearCache(): void {
  cachedRanking = null;
}

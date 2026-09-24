/**
 * ModSourceProber.ets — Modrinth 源偏好探测（P1-MODS Phase 1.3）
 *
 * 文档：docs/guides/mod-download-system-plan.md §四.4
 *
 * 设计要点：
 *   - 独立于 features/download/SourceProber.ets：Mod 下载失败（尤其 CurseForge/MCIM
 *     不稳定）不应回流到 MC 下载排序。主 SourceProber 只关心 BMCLAPI vs Mojang。
 *   - Lazy probe：只在首次进入 Mod 页面时触发，不拖慢启动。
 *   - In-flight 合并：多个并发 ensureRanking 共享同一次网络请求。
 *   - 失败降级：两端点都不可用时保守选 MCIM_FIRST（国内用户居多）。
 *   - 30min 缓存：与主 SourceProber 一致的新鲜度策略。
 *
 * 端点：
 *   MCIM：    https://mod.mcimirror.top/modrinth/v2/tag/category
 *   官方：    https://api.modrinth.com/v2/tag/category
 *   （tag/category 是最小体量且 mcim 已全量镜像的端点，适合 RTT 探测）
 *
 * 创建日期：2026-05-11
 */

import { http } from '@kit.NetworkKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { ModrinthSourceMode } from './ModrinthUrls';

const TAG = 'ModSourceProber';

// 探测端点（GET，期望 200 + 较小 body）
const PROBE_URL_MCIM     = 'https://mod.mcimirror.top/modrinth/v2/tag/category';
const PROBE_URL_OFFICIAL = 'https://api.modrinth.com/v2/tag/category';

const PROBE_TIMEOUT_MS = 5000;
const CACHE_MAX_AGE_MS = 30 * 60 * 1000;  // 30min

// ============================================================
//  数据结构
// ============================================================

export interface ModSourceRanking {
  mode: ModrinthSourceMode;
  /** MCIM RTT；-1 表示失败或未探测 */
  rttMcim: number;
  /** Modrinth 官方 RTT；-1 表示失败或未探测 */
  rttOfficial: number;
  /** 探测时间戳（Date.now 毫秒） */
  probedAt: number;
}

interface ProbeResult {
  ok: boolean;
  rtt: number;
  httpStatus: number;
}

// ============================================================
//  模块级状态
// ============================================================

let cached_: ModSourceRanking | null = null;
let inflight_: Promise<ModSourceRanking> | null = null;

// ============================================================
//  公开 API
// ============================================================

/**
 * 同步读：返回当前偏好模式。
 * 没有 probe 过 / 缓存过期 → 返回 MCIM_FIRST（保守默认）。
 * 调用方无需等待；实际 probe 应由 UI 首次进入 Mod 页面时异步触发。
 */
export function getModrinthSourceMode(): ModrinthSourceMode {
  if (cached_ === null) return ModrinthSourceMode.MCIM_FIRST;
  if (Date.now() - cached_.probedAt > CACHE_MAX_AGE_MS) return ModrinthSourceMode.MCIM_FIRST;
  return cached_.mode;
}

/** 同步读：完整排名（含 RTT，调试面板用）；没有缓存则返回 null */
export function getCachedModRanking(): ModSourceRanking | null {
  if (cached_ === null) return null;
  if (Date.now() - cached_.probedAt > CACHE_MAX_AGE_MS) return null;
  return cached_;
}

/**
 * 同步读：MCIM 镜像是否已知可用。
 *
 * 复用 Modrinth 探测结果：Modrinth `mod.mcimirror.top` 与 CurseForge `mod.mcimirror.top`
 * 共用同一主机和证书，rttMcim >= 0 表示该主机最近通过了健康检查。
 *
 * - 已探测且 mcim 通：返回 true（CurseForgeRepository.isAvailable 不阻塞）
 * - 已探测但 mcim 失败：返回 false（CurseForgeRepository.search 立刻短路抛错，
 *   不浪费用户等待 30s 超时）
 * - 未探测过：返回 true（保守默认，让首次进入能尝试一次；后续 probe 完成后再决策）
 */
export function isMcimAvailable(): boolean {
  if (cached_ === null) return true;
  if (Date.now() - cached_.probedAt > CACHE_MAX_AGE_MS) return true;
  return cached_.rttMcim >= 0;
}

/**
 * 首次 / 缓存过期时触发 probe；已有 fresh 缓存直接返回。
 * 并发调用共享同一次 probe（in-flight 合并）。
 */
export async function ensureModrinthRanking(): Promise<ModSourceRanking> {
  let fresh = getCachedModRanking();
  if (fresh !== null) return fresh;
  if (inflight_ !== null) return inflight_;
  inflight_ = doProbe();
  try {
    return await inflight_;
  } finally {
    inflight_ = null;
  }
}

/**
 * 强制重新探测（手动刷新源按钮用）。
 *
 * 关键修复：以前仅清 `cached_` 不清 `inflight_`，导致用户在探测进行中点刷新时，
 * `ensureModrinthRanking` 短路返回 **首次** 未完成的 promise，所谓的"refresh"
 * 完全没起作用。现在同时清两个，强制走一次新 probe。
 */
export async function refreshModrinthRanking(): Promise<ModSourceRanking> {
  cached_ = null;
  inflight_ = null;
  return ensureModrinthRanking();
}

/** 清缓存 / 测试用 */
export function clearModrinthRankingCache(): void {
  cached_ = null;
  inflight_ = null;
}

// ============================================================
//  纯函数：由 RTT 数据推导偏好（便于单测）
// ============================================================

/**
 * 纯函数：从两端点探测结果推导偏好模式。
 *
 * 规则：
 *   - 两端都 OK：RTT 小的胜；相等时 MCIM_FIRST（国内用户居多）
 *   - 只 MCIM OK → MCIM_FIRST
 *   - 只官方 OK → OFFICIAL_FIRST
 *   - 两端都失败 → MCIM_FIRST（保守默认，请求时 fallback 再尝试）
 */
export function decideModrinthMode(
  mcimOk: boolean, mcimRtt: number,
  officialOk: boolean, officialRtt: number,
): ModrinthSourceMode {
  if (mcimOk && officialOk) {
    return mcimRtt <= officialRtt
      ? ModrinthSourceMode.MCIM_FIRST
      : ModrinthSourceMode.OFFICIAL_FIRST;
  }
  if (mcimOk) return ModrinthSourceMode.MCIM_FIRST;
  if (officialOk) return ModrinthSourceMode.OFFICIAL_FIRST;
  return ModrinthSourceMode.MCIM_FIRST;
}

// ============================================================
//  内部：doProbe
// ============================================================

async function doProbe(): Promise<ModSourceRanking> {
  AppLogger.info(TAG, 'Starting Modrinth source probe...', LOG_DOMAIN_DOWNLOAD);
  let results = await Promise.all([
    probeEndpoint('mcim', PROBE_URL_MCIM),
    probeEndpoint('official', PROBE_URL_OFFICIAL),
  ]);
  let mcim = results[0];
  let official = results[1];

  let mode = decideModrinthMode(mcim.ok, mcim.rtt, official.ok, official.rtt);

  let ranking: ModSourceRanking = {
    mode,
    rttMcim: mcim.ok ? mcim.rtt : -1,
    rttOfficial: official.ok ? official.rtt : -1,
    probedAt: Date.now(),
  };
  cached_ = ranking;
  AppLogger.info(TAG, `Modrinth probe done: mode=${mode} rttMcim=${ranking.rttMcim} rttOfficial=${ranking.rttOfficial}`, LOG_DOMAIN_DOWNLOAD);
  return ranking;
}

async function probeEndpoint(id: string, url: string): Promise<ProbeResult> {
  let start = Date.now();
  let result: ProbeResult = { ok: false, rtt: -1, httpStatus: 0 };
  let req = http.createHttp();
  try {
    let resp = await req.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: PROBE_TIMEOUT_MS,
      readTimeout: PROBE_TIMEOUT_MS,
    });
    result.httpStatus = resp.responseCode;
    result.rtt = Date.now() - start;
    result.ok = resp.responseCode >= 200 && resp.responseCode < 400;
  } catch (e) {
    result.rtt = Date.now() - start;
    result.ok = false;
    AppLogger.warn(TAG, `Probe ${id} failed: ${(e as Error).message !== undefined ? (e as Error).message : String(e)}`, null, LOG_DOMAIN_DOWNLOAD);
  } finally {
    try { req.destroy(); } catch (e) { /* ignore */ }
  }
  AppLogger.info(TAG, `Probe ${id}: rtt=${result.rtt}ms ok=${result.ok ? 'true' : 'false'} http=${result.httpStatus}`, LOG_DOMAIN_DOWNLOAD);
  return result;
}

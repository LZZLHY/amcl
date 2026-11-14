/**
 * Minecraft 版本页和安装任务共享的版本清单请求。网络候选分别验证和缓存，防止镜像
 * 正文或条件响应被当作一次快速的官方直连取样。
 */
import { AppLogger, BMCLAPI_BASE } from 'commons';
import { DownloadManager } from '../download/DownloadManager';
import { canRelayPublicMcMetadata, fetchMcVersionListSources, getMcSourcePreference, isOfficialMcSourceOnly,
  observeDirectMojangManifest } from '../download/SourceProber';
import { getRelayClient } from '../download/RelayClient';
import { buildConditionalRequest } from './MetadataCache';
import { getMetadataCacheStore } from './MetadataCacheStore';

const TAG = 'McVersionManifest';
const OFFICIAL = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json';
const OLD_OFFICIAL = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
const MIRROR = BMCLAPI_BASE + '/mc/game/version_manifest_v2.json';
const FETCH_TIMEOUT_SECONDS = 30;
const SHAPE_TAG = '[Shape]';

export interface McManifestLatest {
  release: string;
  snapshot: string;
}

export interface McManifestVersion {
  id: string;
  type: string;
  url: string;
  releaseTime: string;
}

export interface McVersionManifest {
  latest: McManifestLatest;
  versions: McManifestVersion[];
}

/** 只有完整且结构可用的上游清单才能结束候选竞争或改变优先级。 */
function parseManifest(body: string, requiredVersion: string): McVersionManifest {
  try {
    const value = JSON.parse(body) as McVersionManifest;
    if (!value || !value.latest || typeof value.latest.release !== 'string' ||
      typeof value.latest.snapshot !== 'string' || !Array.isArray(value.versions) || value.versions.length < 200) {
      throw new Error('版本清单缺少必要字段或条目过少');
    }
    if (!value.versions.every((version: McManifestVersion): boolean => version !== null &&
      typeof version.id === 'string' && typeof version.type === 'string' &&
      typeof version.url === 'string' && typeof version.releaseTime === 'string')) {
      throw new Error('版本清单含有不完整条目');
    }
    if (requiredVersion.length > 0 && !value.versions.some((version: McManifestVersion): boolean =>
      version.id === requiredVersion && typeof version.url === 'string' && version.url.length > 0)) {
      throw new Error('版本 ' + requiredVersion + ' 未找到');
    }
    return value;
  } catch (error) {
    throw new Error(SHAPE_TAG + ' ' + (error as Error).message);
  }
}

/** 旧缓存可能把备用源正文写进主源键，新的键只写各自经过验证的响应。 */
function cacheKey(url: string): string {
  return 'mc-version-manifest:' + url;
}

/** 明确来源只读新官方键，自动/镜像档仍可离线使用已存在的旧磁盘清单。 */
function readCached(requiredVersion: string, maxAgeMs: number, stale: boolean): McVersionManifest | null {
  const store = getMetadataCacheStore();
  if (!store.isReady()) return null;
  let keys = [cacheKey(OFFICIAL)];
  if (!isOfficialMcSourceOnly()) {
    keys = getMcSourcePreference() === 'mirror'
      ? [cacheKey(MIRROR), cacheKey(OFFICIAL), MIRROR, OFFICIAL, OLD_OFFICIAL]
      : [cacheKey(OFFICIAL), cacheKey(MIRROR), OFFICIAL, OLD_OFFICIAL, MIRROR];
  }
  for (const key of keys) {
    const body = stale ? store.getBody(key) : store.get(key, maxAgeMs);
    if (body === null) continue;
    try { return parseManifest(body, requiredVersion); }
    catch (error) { /* 损坏或缺少所选版本的缓存不能挡住有效候选。 */ }
  }
  return null;
}

/**
 * 每个候选只连接本源。条件请求绑定同源缓存；304 无可用正文时重取同一来源。
 * 只有新鲜官方 2xx 正文经过验证、全程保持直连模式，才报告 PCL 风格的四秒观察。
 */
async function fetchCandidate(url: string, requiredVersion: string): Promise<McVersionManifest> {
  const store = getMetadataCacheStore();
  const key = cacheKey(url);
  const meta = store.isReady() ? store.getMeta(key) : null;
  const direct = url === OFFICIAL && !getRelayClient().isEnabled();
  const headers = meta !== null ? buildConditionalRequest(meta) : undefined;
  const manager = DownloadManager.instance();
  const allowRelay = url === OFFICIAL && !direct && canRelayPublicMcMetadata([url]);
  const startedAt = Date.now();
  let response = await manager.fetchTextEx(url, [], FETCH_TIMEOUT_SECONDS, headers, undefined, allowRelay);
  if (response.statusCode === 304) {
    const cached = store.isReady() ? store.getBody(key) : null;
    if (cached !== null) {
      try {
        const value = parseManifest(cached, requiredVersion);
        store.touch(key);
        return value;
      } catch (error) { /* 无有效同源缓存时重取正文。 */ }
    }
    // 残缺缓存的修复也受此候选的原始时间预算约束。
    const remainingMs = FETCH_TIMEOUT_SECONDS * 1000 - (Date.now() - startedAt);
    if (remainingMs <= 0) throw new Error('版本清单条件请求超时');
    response = await manager.fetchTextEx(url, [], Math.max(1, Math.ceil(remainingMs / 1000)),
      undefined, undefined, allowRelay);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new Error('版本清单 HTTP ' + response.statusCode.toString());
  }
  if (url === MIRROR && isOfficialMcSourceOnly()) throw new Error('版本清单镜像已被当前来源策略禁止');
  const value = parseManifest(response.body, requiredVersion);
  if (direct && !getRelayClient().isEnabled()) observeDirectMojangManifest(Date.now() - startedAt);
  if (store.isReady()) store.put(key, response.body, response.headers);
  return value;
}

/** 保留 TTL、手动刷新与离线缓存，安装调用还要求清单实际含所选版本。 */
export async function loadMcVersionManifest(maxAgeMs: number, forceRefresh: boolean = false,
  requiredVersion: string = ''): Promise<McVersionManifest> {
  if (!forceRefresh) {
    const cached = readCached(requiredVersion, maxAgeMs, false);
    if (cached !== null) return cached;
  }
  try {
    return await fetchMcVersionListSources(
      (): Promise<McVersionManifest> => fetchCandidate(OFFICIAL, requiredVersion),
      (): Promise<McVersionManifest> => fetchCandidate(MIRROR, requiredVersion));
  } catch (error) {
    const message = (error as Error).message;
    const cached = readCached(requiredVersion, maxAgeMs, true);
    if (cached !== null) {
      AppLogger.warn(TAG, 'Using cached Minecraft manifest after request failure: ' + message);
      return cached;
    }
    if (message.startsWith(SHAPE_TAG)) throw new Error('版本清单解析失败：' + message.substring(SHAPE_TAG.length).trim());
    throw new Error('无法获取版本列表，请检查网络连接（' + message + '）');
  }
}

/**
 * McVersionService.ets — MC 版本列表服务
 *
 * 从 Mojang API (launchermeta.mojang.com) 获取 MC 版本列表。
 * 支持 BMCLAPI 镜像加速。
 * 版本类型：release（正式版）、snapshot（快照）、old_beta、old_alpha
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BMCLAPI_BASE } from 'commons';
import { DownloadManager } from '../download/DownloadManager';
import { getMetadataCacheStore } from './MetadataCacheStore';
import { buildConditionalRequest } from './MetadataCache';

const TAG = 'McVersionService'

const MOJANG_MANIFEST = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json'
const BMCLAPI_MANIFEST = BMCLAPI_BASE + '/mc/game/version_manifest_v2.json'

// 2026-07-03：版本清单磁盘缓存 TTL。进程内已有 cachedList（同会话秒开），本 TTL 只影响
// 跨冷启动——TTL 内直接读盘秒开、过期后走 ETag/304 条件请求几乎零流量。快照约每周更新，
// 30min 内的滞后可接受；「刷新」按钮走 forceRefresh 绕过 TTL；网络失败回退旧缓存（离线可用）。
const TTL_MANIFEST_MS = 30 * 60 * 1000
const FETCH_TIMEOUT_SECONDS = 30

/** 「字节已到手，但解析/读字段失败」的标记。与网络失败分流，见 parseText。 */
const SHAPE_TAG = '[Shape]'

function isShapeError(message: string): boolean {
  return message.indexOf(SHAPE_TAG) === 0
}

function stripShapeTag(message: string): string {
  return isShapeError(message) ? message.substring(SHAPE_TAG.length).trim() : message
}

export interface McVersion {
  id: string;
  type: string;          // 'release' | 'snapshot' | 'old_beta' | 'old_alpha'
  url: string;           // 版本详情 JSON URL
  releaseTime: string;   // ISO 时间字符串
  displayDate: string;   // 格式化后的日期（如 "2023-12-07"）
}

export interface McVersionLatest {
  release: string;
  snapshot: string;
}

export interface McVersionList {
  latest: McVersionLatest;
  versions: McVersion[];
}

// Waiter list: 多个并发 getVersionList 调用合并到同一个 in-flight fetch
type Waiter = (list: McVersionList | null, err: Error | null) => void;

export class McVersionService {
  private cachedList: McVersionList | null = null;
  private inflightWaiters: Waiter[] | null = null;  // null=空闲；非 null=有 fetch 进行中

  /**
   * 获取版本列表（带缓存）。
   *
   * R11（D13-1）：原本用 `while (loading) await sleep(100)` 轮询，每 100ms 唤醒一次。
   * 现改成 Promise waiter list：第一个调用方启动真实 fetch，后续并发调用方直接挂在
   * waiter 队列上，fetch 完成时一次性 resolve/reject 全部。零轮询，零浪费 CPU。
   */
  async getVersionList(forceRefresh: boolean = false): Promise<McVersionList> {
    if (this.cachedList && !forceRefresh) {
      return this.cachedList
    }
    // 已有 in-flight fetch：挂队列等结果（与首发 caller 共享同一次网络请求）
    if (this.inflightWaiters !== null) {
      return new Promise<McVersionList>((resolve, reject) => {
        this.inflightWaiters!.push((list, err) => {
          if (err) reject(err); else resolve(list as McVersionList);
        });
      });
    }
    // 首发 caller：启动 fetch，建立 waiter 队列
    this.inflightWaiters = [];
    try {
      const list = await this.fetchManifest(forceRefresh);
      this.cachedList = list;
      // 唤醒所有等待者（成功路径）
      let waiters = this.inflightWaiters;
      this.inflightWaiters = null;
      for (let w of waiters) {
        try { w(list, null); } catch (e) { /* ignore listener throws */ }
      }
      return list;
    } catch (e) {
      // 唤醒所有等待者（失败路径）
      let waiters = this.inflightWaiters || [];
      this.inflightWaiters = null;
      let err = e as Error;
      for (let w of waiters) {
        try { w(null, err); } catch (e2) { /* ignore */ }
      }
      throw err;
    }
  }

  /**
   * 获取正式版列表
   */
  async getReleases(): Promise<McVersion[]> {
    const list = await this.getVersionList()
    return list.versions.filter(v => v.type === 'release')
  }

  /**
   * 获取快照版列表
   */
  async getSnapshots(): Promise<McVersion[]> {
    const list = await this.getVersionList()
    return list.versions.filter(v => v.type === 'snapshot')
  }

  /**
   * 按类型筛选
   */
  async getByTypes(types: string[]): Promise<McVersion[]> {
    const list = await this.getVersionList()
    return list.versions.filter(v => types.includes(v.type))
  }

  /**
   * 清除缓存
   */
  clearCache() {
    this.cachedList = null
  }

  private async fetchManifest(forceRefresh: boolean = false): Promise<McVersionList> {
    // Phase 9 (ARCH-1 闭环)：走 NAPI fetchText 多源 fallback（BMCLAPI 优先，Mojang 兜底）
    // 2026-07-03：叠加 MetadataCacheStore 磁盘缓存 + ETag/304 条件请求 + 网络失败回退旧缓存，
    // 加速冷启动首次打开「版本」页（进程内 cachedList 已覆盖同会话复用）。
    const store = getMetadataCacheStore()
    const cacheReady = store.isReady()
    const primary = BMCLAPI_MANIFEST
    const mirrors = [MOJANG_MANIFEST]

    // 1. 非强制刷新且磁盘缓存在 TTL 内 → 直接读盘解析返回（零网络）
    if (cacheReady && !forceRefresh) {
      const cached = store.get(primary, TTL_MANIFEST_MS)
      if (cached !== null) {
        try {
          hilog.info(0x0000, TAG, 'manifest disk cache HIT (TTL)')
          return this.parseText(cached)
        } catch (e) {
          // 「corrupt」只是其中一种可能：解析失败也可能是**代码侧读错字段**（release 属性名
          // 混淆曾把 raw.latest 改成不存在的名字），此时重新下载一次不会有任何帮助。
          hilog.warn(0x0000, TAG, 'cached manifest unreadable, refetch: %{public}s', (e as Error).message)
        }
      }
    }

    // 2. 构造条件请求头（有 meta 时带 If-None-Match / If-Modified-Since 走 304 短路）
    let headers: Record<string, string> = {}
    if (cacheReady) {
      const meta = store.getMeta(primary)
      if (meta !== null) {
        const cond = buildConditionalRequest(meta)
        for (const k of Object.keys(cond)) headers[k] = cond[k]
      }
    }

    // 3. 发请求（多镜像 fallback）
    try {
      hilog.info(0x0000, TAG, 'Fetching manifest from: %{public}s (mirrors=1)', BMCLAPI_MANIFEST)
      const resp = await DownloadManager.instance().fetchTextEx(primary, mirrors, FETCH_TIMEOUT_SECONDS, headers)

      // 304：清单未变更 → 用磁盘 body + touch 续期
      if (resp.statusCode === 304 && cacheReady) {
        const body = store.getBody(primary)
        if (body !== null) {
          store.touch(primary)
          hilog.info(0x0000, TAG, 'manifest 304, reuse cached body')
          return this.parseText(body)
        }
        // 304 但磁盘 body 丢失（极端）→ 无条件重取一次
        const resp2 = await DownloadManager.instance().fetchTextEx(primary, mirrors, FETCH_TIMEOUT_SECONDS, {})
        if (resp2.statusCode >= 200 && resp2.statusCode < 300) {
          if (cacheReady) store.put(primary, resp2.body, resp2.headers)
          return this.parseText(resp2.body)
        }
        throw new Error('manifest 304 reload HTTP ' + resp2.statusCode)
      }

      // 200：写缓存 + 解析返回
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (cacheReady) store.put(primary, resp.body, resp.headers)
        return this.parseText(resp.body)
      }
      throw new Error('manifest HTTP ' + resp.statusCode)
    } catch (e) {
      const cause: string = (e as Error).message
      // 解析失败与网络失败必须分开报。混在一起的代价实测过：release 属性名混淆把
      // raw.latest 改了名，UI 却显示"请检查网络连接"，而网络检测同时显示一切正常 ——
      // 唯一的真相只存在于一行 warn 日志里。
      if (isShapeError(cause)) {
        hilog.error(0x0000, TAG, 'manifest parsed but unreadable (NOT a network problem): %{public}s', cause)
        throw new Error('版本清单解析失败（已拿到数据，不是网络问题）：' + stripShapeTag(cause))
      }

      // 网络失败 → 回退旧磁盘缓存（哪怕已过期）：离线 / 服务波动时仍能看到上次的版本列表
      if (cacheReady) {
        const stale = store.getBody(primary)
        if (stale !== null) {
          try {
            hilog.warn(0x0000, TAG, 'network failed, serving STALE manifest cache: %{public}s', cause)
            return this.parseText(stale)
          } catch (e2) {
            hilog.error(0x0000, TAG, 'STALE cache also unreadable: %{public}s', (e2 as Error).message)
          }
        }
      }
      hilog.warn(0x0000, TAG, 'Failed to fetch manifest: %{public}s', cause)
      throw new Error('无法获取版本列表，请检查网络连接（' + cause + '）')
    }
  }

  /**
   * JSON.parse + parseManifest，失败一律打上 SHAPE_TAG。
   *
   * 这个标记是"数据没到"与"数据到了但读不出来"的唯一分界线；上层靠它决定要不要退回
   * 旧缓存（读不出来时退回去只会用同一套代码再失败一次，并把真正的错误吞掉）。
   */
  private parseText(text: string): McVersionList {
    try {
      return this.parseManifest(JSON.parse(text) as McVersionManifestRaw)
    } catch (e) {
      throw new Error(SHAPE_TAG + ' ' + (e as Error).message)
    }
  }

  private parseManifest(raw: McVersionManifestRaw): McVersionList {
    let versions: McVersion[] = []
    for (let v of raw.versions) {
      let mv: McVersion = {
        id: v.id,
        type: v.type,
        url: v.url,
        releaseTime: v.releaseTime,
        displayDate: this.formatDate(v.releaseTime),
      }
      versions.push(mv)
    }
    hilog.info(0x0000, TAG, 'Parsed %{public}d versions, latest release: %{public}s',
      versions.length, raw.latest.release)
    let result: McVersionList = {
      latest: raw.latest,
      versions: versions,
    }
    return result
  }

  private formatDate(isoStr: string): string {
    try {
      const d = new Date(isoStr)
      const y = d.getFullYear()
      const m = String(d.getMonth() + 1).padStart(2, '0')
      const day = String(d.getDate()).padStart(2, '0')
      return y + '-' + m + '-' + day
    } catch (e) {
      return isoStr.substring(0, 10)
    }
  }
}

// Raw JSON 接口
interface McVersionManifestRaw {
  latest: McVersionLatest;
  versions: McVersionEntryRaw[];
}

interface McVersionEntryRaw {
  id: string;
  type: string;
  url: string;
  time: string;
  releaseTime: string;
  sha1: string;
  complianceLevel: number;
}

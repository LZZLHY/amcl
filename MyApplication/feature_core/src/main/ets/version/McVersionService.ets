/**
 * McVersionService.ets — MC 版本列表服务
 *
 * 从 Mojang API (launchermeta.mojang.com) 获取 MC 版本列表。
 * 支持 BMCLAPI 镜像加速。
 * 版本类型：release（正式版）、snapshot（快照）、old_beta、old_alpha
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { McManifestVersion, loadMcVersionManifest } from './McVersionManifest';
import { isOfficialMcSourceOnly } from '../download/SourceProber';

const TAG = 'McVersionService';
/** 版本页的磁盘缓存窗口；显式刷新仍触发真实条件请求。 */
const TTL_MANIFEST_MS = 30 * 60 * 1000;

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
  /** 官方模式不能继续复用此前允许镜像时产生的页面快照。 */
  private cachedOfficialOnly: boolean = false;
  private inflightWaiters: Waiter[] | null = null;  // null=空闲；非 null=有 fetch 进行中

  /**
   * 获取版本列表（带缓存）。
   *
   * R11（D13-1）：原本用 `while (loading) await sleep(100)` 轮询，每 100ms 唤醒一次。
   * 现改成 Promise waiter list：第一个调用方启动真实 fetch，后续并发调用方直接挂在
   * waiter 队列上，fetch 完成时一次性 resolve/reject 全部。零轮询，零浪费 CPU。
   */
  async getVersionList(forceRefresh: boolean = false): Promise<McVersionList> {
    const officialOnly = isOfficialMcSourceOnly();
    if (this.cachedList && !forceRefresh && (!officialOnly || this.cachedOfficialOnly)) {
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
      this.cachedOfficialOnly = officialOnly;
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

  /** 使用安装入口同一清单策略；显示日期只在页面服务中生成。 */
  private async fetchManifest(forceRefresh: boolean): Promise<McVersionList> {
    const raw = await loadMcVersionManifest(TTL_MANIFEST_MS, forceRefresh);
    const versions = raw.versions.map((version: McManifestVersion): McVersion => ({
      id: version.id,
      type: version.type,
      url: version.url,
      releaseTime: version.releaseTime,
      displayDate: this.formatDate(version.releaseTime),
    }));
    hilog.info(0x0000, TAG, 'Parsed %{public}d versions, latest release: %{public}s',
      versions.length, raw.latest.release);
    const latest: McVersionLatest = { release: raw.latest.release, snapshot: raw.latest.snapshot };
    const result: McVersionList = { latest: latest, versions: versions };
    return result;
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

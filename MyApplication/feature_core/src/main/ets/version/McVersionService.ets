/**
 * McVersionService.ets — MC 版本列表服务
 *
 * 从 Mojang API (launchermeta.mojang.com) 获取 MC 版本列表。
 * 支持 BMCLAPI 镜像加速。
 * 版本类型：release（正式版）、snapshot（快照）、old_beta、old_alpha
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { McManifestVersion, McVersionManifest, readCachedMcVersionManifest, refreshMcVersionManifest } from './McVersionManifest';
import { getMcSourcePreference, isOfficialMcSourceOnly } from '../download/SourceProber';

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

export class McVersionService {
  private cachedList: McVersionList | null = null;
  private cachedSource: string = '';
  /** 同一服务的重叠调用共享同一来源请求；更换来源后发起独立复核。 */
  private pending: Map<string, Promise<McVersionList>> = new Map<string, Promise<McVersionList>>();

  /** 网关意图和显式官方源使用同一官方清单权限，自动与镜像保留各自的优先序。 */
  private sourceMode(): string {
    return isOfficialMcSourceOnly() ? 'official' : getMcSourcePreference();
  }

  /** 读取当前来源可展示的快照。过期磁盘正文只用于首显，后台检查仍须访问网络。 */
  peekVersionList(): McVersionList | null {
    if (this.cachedList !== null && this.cachedSource === this.sourceMode()) return this.cachedList;
    const stored = readCachedMcVersionManifest('', -1);
    return stored === null ? null : this.toVersionList(stored);
  }

  /** 发起条件请求；网络失败保持上次成功快照并向页面报告失败，不把旧数据当作已复核。 */
  async refreshVersionList(): Promise<McVersionList> {
    const source = this.sourceMode();
    const existing = this.pending.get(source);
    if (existing !== undefined) return existing;
    const request = this.refreshForSource(source);
    this.pending.set(source, request);
    try {
      return await request;
    } finally {
      this.pending.delete(source);
    }
  }

  /** 异步返回后重新核对权限，防止已撤销来源的旧响应覆盖当前首屏。 */
  private async refreshForSource(source: string): Promise<McVersionList> {
    const raw = await refreshMcVersionManifest();
    if (source !== this.sourceMode()) throw new Error('版本清单下载来源已更改');
    this.cachedList = this.toVersionList(raw);
    this.cachedSource = source;
    return this.cachedList;
  }

  /** 其他调用保留已有的内存命中、磁盘 TTL、强制刷新与失败时离线回退语义。 */
  async getVersionList(forceRefresh: boolean = false): Promise<McVersionList> {
    const source = this.sourceMode();
    if (!forceRefresh) {
      if (this.cachedList !== null && this.cachedSource === source) return this.cachedList;
      const stored = readCachedMcVersionManifest('', TTL_MANIFEST_MS);
      if (stored !== null) {
        this.cachedList = this.toVersionList(stored);
        this.cachedSource = source;
        return this.cachedList;
      }
    }
    try {
      return await this.refreshVersionList();
    } catch (error) {
      const cached = readCachedMcVersionManifest('', TTL_MANIFEST_MS, true);
      if (cached !== null) {
        hilog.warn(0x0000, TAG, 'Using cached Minecraft list: %{public}s', (error as Error).message);
        this.cachedList = this.toVersionList(cached);
        this.cachedSource = this.sourceMode();
        return this.cachedList;
      }
      throw error as Error;
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

  /** 内存与磁盘快照均使用页面既有的日期和版本投影。 */
  private toVersionList(raw: McVersionManifest): McVersionList {
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

/**
 * ModpackSnapshot.ets — 已装整合包清单快照（持久化）
 *
 * 文档：docs/guides/modpack-install-plan.md §六 / §七.7
 *
 * 安装整合包后把"装了什么"落到 `versions/<name>/.amcl-modpack.json`，用途：
 *   - 版本管理里标识"这是个整合包版本"
 *   - 复查本次安装的缺失项（不完整提示）
 *   - **更新整合包（V2）**：比对新旧清单做增量（删旧加新、清理 overrides、保留用户数据）
 *
 * 纯类型 + 文件 IO（读写 JSON），无网络 / NAPI。
 *
 * 创建日期：2026-06-15
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = 'ModpackSnapshot';

/** 快照文件名（落在版本目录根）。 */
export const MODPACK_SNAPSHOT_FILE = '.amcl-modpack.json';

/** 整合包图标文件名（落在版本目录根，安装时从项目 iconUrl 下载）。 */
export const MODPACK_ICON_FILE = 'amcl-modpack-icon.png';

/** 取整合包版本的图标绝对路径；不存在返回空串。 */
export function getModpackIconPath(mcDir: string, versionId: string): string {
  if (versionId.length === 0) return '';
  let p = mcDir + '/versions/' + versionId + '/' + MODPACK_ICON_FILE;
  try {
    if (fs.statSync(p).isFile()) return p;
  } catch (e) { /* not exists */ }
  return '';
}

/** 安装时未能装上的项（缺失清单）。 */
export interface ModpackMissingItem {
  /** 给用户看的名字（文件名 / CF 项目文件 id）。 */
  name: string;
  /** 缺失原因（下载失败 / CF 禁用直链 / 文件下架等）。 */
  reason: string;
  /** 可选：手动下载链接（让用户自行补齐）。 */
  url?: string;
}

/** 已装整合包快照。 */
export interface ModpackSnapshot {
  source: string;              // 'modrinth' | 'curseforge' | 'local'
  /** 在线安装时记录的项目 id（更新时复查最新版本用）。 */
  projectId?: string;
  name: string;
  packVersion: string;
  gameVersion: string;
  loaderType: string;
  loaderVersion: string;
  /** 本次下载落地的文件实例相对路径（更新 diff 用）。 */
  installedFiles: string[];
  /** overrides 铺下的文件实例相对路径（更新清理用）。 */
  overrideFiles: string[];
  /** 本次未装成功的项。 */
  missing: ModpackMissingItem[];
  /** 安装完成时间戳（ms）。 */
  installedAt: number;
  /** 整合包推荐 JVM 参数（user_jvm_args.txt 解析，空串/缺省=无）。持久化便于复查/重应用。 */
  recommendedJvmArgs?: string;
  /** 推荐最大内存 MB（从 -Xmx 解析，0/缺省=无）。 */
  recommendedMaxMemMb?: number;
}

/** 写快照到 versionDir/.amcl-modpack.json。失败仅告警，不抛（快照非关键路径）。 */
export function writeModpackSnapshot(versionDir: string, snap: ModpackSnapshot): void {
  let path = versionDir + '/' + MODPACK_SNAPSHOT_FILE;
  try {
    let json = JSON.stringify(snap);
    let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, json);
    fs.closeSync(file);
    AppLogger.info(TAG, `wrote snapshot: ${path} (${snap.installedFiles.length} files, ${snap.missing.length} missing)`, LOG_DOMAIN_DOWNLOAD);
  } catch (e) {
    let err = e as Error;
    AppLogger.warn(TAG, `writeModpackSnapshot failed: ${path}`, err, LOG_DOMAIN_DOWNLOAD);
  }
}

/** 读快照；不存在 / 解析失败返回 null。 */
export function readModpackSnapshot(versionDir: string): ModpackSnapshot | null {
  let path = versionDir + '/' + MODPACK_SNAPSHOT_FILE;
  try {
    let content = fs.readTextSync(path);
    return JSON.parse(content) as ModpackSnapshot;
  } catch (e) {
    return null;
  }
}

/** 该版本是否为整合包安装（存在快照文件）。 */
export function isModpackVersion(versionDir: string): boolean {
  try {
    let st = fs.statSync(versionDir + '/' + MODPACK_SNAPSHOT_FILE);
    return st.isFile();
  } catch (e) {
    return false;
  }
}

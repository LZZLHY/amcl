/**
 * InstalledModIndex.ets — 已装模组「安装清单」(持久化基准哈希，单一事实源)
 *
 * 为什么需要：判定一个模组"是否损坏"必须先有可信的【期望哈希基准】。
 *   - 经本启动器下载的模组：下载时源(Modrinth/CurseForge)提供了权威 sha1，本清单把它连同
 *     source/projectId/versionId 一并落盘 → 之后任意时刻可"重新哈希 + 比对期望值"判损坏。
 *   - 用户手动导入、经反查(sha1 / CF Murmur2 fingerprint)命中源的模组：把命中时的当前哈希
 *     作为基准写入(收编)，从此同样可被完整性校验 + 检查更新。
 *   - 反查不到源的导入模组：不写清单 → 永远不参与损坏判定(没有基准无法区分"损坏"与"不认识")。
 *
 * 存储：与模组同目录的 sidecar JSON `<modsDir>/.amcl-mods-index.json`(镜像 ModpackSnapshot 的做法)。
 *   - 与模组文件同盘同目录 → 版本隔离天然分文件、切换存储位置(沙箱/外部)也跟着走。
 *   - key = baseName(去掉 .disabled 的文件名) → 启用/禁用改名不丢链接。
 *
 * 纯类型 + 文件 IO(读写 JSON)，无网络 / NAPI。
 *
 * 创建日期：2026-07-03(模组完整性/来源链接)
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { ModSource } from './ModTypes';
import { modInstallationActive } from './ModInstallTransaction';

const TAG = 'InstalledModIndex';

/** 清单文件名(落在 mods 目录根)。 */
export const INSTALLED_MOD_INDEX_FILE = '.amcl-mods-index.json';

/** 单个已装模组的安装记录(基准)。 */
export interface InstalledModEntry {
  /** 去掉 .disabled 的文件名，作为清单 key(启用/禁用改名不影响)。 */
  baseName: string;
  source: ModSource;
  /** 源工程 id(Modrinth base62 / CurseForge 数字串)。 */
  projectId: string;
  /** 源版本 id(Modrinth version id / CurseForge fileId)。检查更新/修复重下用。 */
  versionId: string;
  /** 权威期望 sha1(下载时源提供，或反查命中时的当前哈希)。判损坏的基准。 */
  expectedSha1: string;
  /** 期望文件大小(字节)。日常快检用(截断型损坏零哈希暴露)。 */
  expectedSize: number;
  /** CurseForge Murmur2 fingerprint(仅 CF 收编时可填，便于 CF 反查/校验)。 */
  cfFingerprint?: number;
  /** 展示名(修复任务标题用)。 */
  displayName?: string;
  /** 写入时间戳(ms)。 */
  at: number;
}

interface IndexFileShape {
  version: number;
  entries: InstalledModEntry[];
}

const INDEX_VERSION = 1;

/** 内存表示：baseName -> entry。 */
export class InstalledModIndex {
  private map_: Map<string, InstalledModEntry> = new Map<string, InstalledModEntry>();

  /** 去掉末尾 `.disabled`，得到 key。 */
  static baseNameOf(filename: string): string {
    const SUF = '.disabled';
    return filename.endsWith(SUF) ? filename.substring(0, filename.length - SUF.length) : filename;
  }

  get(baseName: string): InstalledModEntry | null {
    let e = this.map_.get(baseName);
    return e !== undefined ? e : null;
  }

  /** 按文件名(可能带 .disabled)取记录。 */
  getByFilename(filename: string): InstalledModEntry | null {
    return this.get(InstalledModIndex.baseNameOf(filename));
  }

  has(baseName: string): boolean {
    return this.map_.has(baseName);
  }

  upsert(entry: InstalledModEntry): void {
    this.map_.set(entry.baseName, entry);
  }

  remove(baseName: string): void {
    this.map_.delete(baseName);
  }

  entries(): InstalledModEntry[] {
    let arr: InstalledModEntry[] = [];
    this.map_.forEach((e: InstalledModEntry) => arr.push(e));
    return arr;
  }

  size(): number {
    return this.map_.size;
  }
}

// ============================================================
//  文件读写(sidecar JSON，best-effort：失败仅告警不抛)
// ============================================================

/** 读清单；不存在 / 解析失败返回空 index(不抛)。 */
export function readInstalledModIndex(modsDir: string): InstalledModIndex {
  let idx = new InstalledModIndex();
  let path = modsDir + '/' + INSTALLED_MOD_INDEX_FILE;
  try {
    let content = fs.readTextSync(path);
    let shape = JSON.parse(content) as IndexFileShape;
    if (shape && Array.isArray(shape.entries)) {
      for (let e of shape.entries) {
        if (e && typeof e.baseName === 'string' && e.baseName.length > 0) {
          idx.upsert(e);
        }
      }
    }
  } catch (e) {
    // 不存在是常态(还没装过 / 老数据)
  }
  return idx;
}

/** 写清单到 `<modsDir>/.amcl-mods-index.json`。失败仅告警(非关键路径)。 */
export function writeInstalledModIndex(modsDir: string, idx: InstalledModIndex): void {
  // The transaction commits its own index with the files; stale background scans must not replace it.
  if (modInstallationActive(modsDir)) return;
  let path = modsDir + '/' + INSTALLED_MOD_INDEX_FILE;
  try {
    // 确保目录存在(首次安装时 mods/ 可能刚建)
    try { fs.mkdirSync(modsDir, true); } catch (e) { /* 已存在 */ }
    let shape: IndexFileShape = { version: INDEX_VERSION, entries: idx.entries() };
    let json = JSON.stringify(shape);
    let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, json);
    fs.closeSync(file);
    AppLogger.info(TAG, `wrote index: ${path} (${idx.size()} entries)`, LOG_DOMAIN_DOWNLOAD);
  } catch (e) {
    AppLogger.warn(TAG, `writeInstalledModIndex failed: ${path}`, e as Object, LOG_DOMAIN_DOWNLOAD);
  }
}

/**
 * 便捷：读清单 → upsert 一条 → 写回。安装/更新成功后调用。
 * 失败仅告警(不影响下载主流程)。
 */
export function recordInstalledMod(modsDir: string, entry: InstalledModEntry): void {
  let idx = readInstalledModIndex(modsDir);
  idx.upsert(entry);
  writeInstalledModIndex(modsDir, idx);
}

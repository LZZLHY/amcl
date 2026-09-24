/**
 * LocalModScanner.ets — 扫描已装本地资源（mods / resourcepacks / shaderpacks）
 * 并通过 sha1 反查 Modrinth 把 RemoteSource + RemoteProjectId 写回 LocalMod
 *
 * 文档：docs/guides/mod-download-system-plan.md §三.B（Phase 3 LocalModScanner 轻量版）
 *
 * 用途：
 *   - 喂给 ModDependencyResolver 的 `installed: LocalMod[]` 参数，让 BFS 把
 *     "当前版本已经装过的依赖项"标记 alreadyInstalled=true，避免在 ModDetailSheet
 *     的依赖列表里重复出现 + 在 install 时跳过下载
 *   - 给未来 ModListPage（已装管理 UI）提供数据源
 *
 * Phase 3 轻量版（本次落地）的取舍：
 *   ✅ 列文件名 / 大小 / .jar vs .jar.disabled 启用态
 *   ✅ sha1 反查 Modrinth → 写入 remoteSource + remoteProjectId
 *   这里只负责文件、完整性与来源识别；包内依赖和兼容性由游戏实际加载器解释。
 *   Modrinth 反查未命中时可使用注入的 CurseForge 指纹仓库。
 *
 * 这覆盖：
 *   - Modrinth 上一键安装的所有 mod / 资源包 / 光影（sha1 一定命中）
 *   - 用户手动从 Modrinth 网页下载放进去的（也命中）
 *   - 不命中的：CurseForge-only 文件、整合包带的、jar 被改过的 → 这些项 alreadyInstalled=false
 *     仍可下载，最坏情况是依赖列表里多出一项，不会损坏数据
 *
 * 设计要点：
 *   - 纯异步，不阻塞 UI；调用方决定缓存生命周期（见 ModBrowsePage 的使用模式）
 *   - 对单个文件 sha1 反查失败做 individual swallow + hilog warn —— 不让一个坏 jar
 *     阻塞整个扫描；Phase 3 完整版会引入持久化缓存以避免重复 hash
 *   - 仅 ResourceKind.MOD 才扫描 mods/，资源包 / 光影目录的查询保留接口但当前只
 *     被 VersionManagerSheet 的"资源数量"统计用，依赖去重只对 MOD 有意义
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

import { LocalMod, ModSource, ModIntegrity, ResourceKind, resourceKindToInstallDir } from './ModTypes';
import { ModrinthRepository } from './ModrinthRepository';
import { CurseForgeRepository } from './CurseForgeRepository';
import { computeFileSha1 } from 'feature_core';
import { computeCurseForgeFingerprint } from './CurseForgeFingerprint';
import {
  InstalledModIndex, InstalledModEntry,
  readInstalledModIndex, writeInstalledModIndex,
} from './InstalledModIndex';

const TAG = 'LocalModScanner';

/** 扫描入参：定位 mods/ 目录的所有信息 */
export interface ScanRequest {
  /** .minecraft 根目录（不带尾部 /） */
  mcDir: string;
  /** 当前选中的版本 id；versionIsolation=true 时决定 mods/ 路径 */
  versionId: string;
  versionIsolation: boolean;
  /** 资源类型（默认 MOD；其它 kind 当前仅扫文件不反查 sha1） */
  kind?: ResourceKind;
  /**
   * sha1 反查上限 —— 大量本地 mod 时避免 N 次 HTTP 串行。-1 = 不限。
   * 默认 64：足够覆盖典型用户的 mods/ 目录。
   */
  lookupLimit?: number;
  /**
   * 全量校验模式（用户点「校验完整性」触发）。
   *   - false（默认，日常快检）：已收编(有清单)的模组只比对 size、**不重算 sha1**；
   *     仅未收编的模组做 sha1/指纹反查尝试链接。省哈希开销。
   *   - true（全量）：对已收编模组也重算 sha1 与清单基准比对，判定损坏；不符再反查当前哈希
   *     消歧（换版本 vs 真损坏）。
   */
  fullVerify?: boolean;
}

/**
 * 扫描结果。包含两个并列字段：
 *   - mods：已找到并尽力反查的 LocalMod 列表（即使 sha1 反查失败也保留文件级信息）
 *   - lookedUpCount / hitCount：诊断用统计数字
 */
export interface ScanResult {
  mods: LocalMod[];
  /** 实际尝试 sha1 反查的文件数（受 lookupLimit 限制） */
  lookedUpCount: number;
  /** 反查命中（写入了 remoteSource / remoteProjectId）的数量 */
  hitCount: number;
}

/**
 * 调用方关心的最常用便捷接口：扫描当前版本的 mods/，返回反查后的 LocalMod[]。
 *
 * 当 modrinth=null 时退化为"只扫文件、不反查"模式，仍会返回 LocalMod[] 但
 * remoteSource / remoteProjectId 全为空 —— 此时 ModDependencyResolver 的
 * isProjectInstalled 永不命中，等价于 Phase 1/2 的旧行为。
 */
export async function scanInstalledMods(
  req: ScanRequest,
  modrinth: ModrinthRepository | null,
  curseforge?: CurseForgeRepository | null,
): Promise<ScanResult> {
  let scanner = new LocalModScanner(modrinth, curseforge !== undefined ? curseforge : null);
  return scanner.scan(req);
}

/**
 * Phase 3 轻量级 LocalModScanner。无状态，每次扫描重新读盘 + 反查。
 * 之所以做成 class 而非纯函数：未来加内存缓存 / 反查结果持久化（mods.cache.json）
 * 时把缓存挂在实例上即可，外部 API 保持稳定。
 */
export class LocalModScanner {
  private modrinth_: ModrinthRepository | null;
  private curseforge_: CurseForgeRepository | null;

  constructor(modrinth: ModrinthRepository | null, curseforge?: CurseForgeRepository | null) {
    this.modrinth_ = modrinth;
    this.curseforge_ = curseforge !== undefined ? curseforge : null;
  }

  /**
   * 扫描指定 kind 的安装目录，返回 LocalMod[]（含完整性/来源链接）+ 诊断统计。
   *
   * 完整性/链接模型（仅 MOD 类）：
   *   - 读取 `<dir>/.amcl-mods-index.json` 安装清单（收编过的模组的基准哈希 + 源链接）。
   *   - 已收编(清单命中)：
   *       · 日常快检(fullVerify=false)：只比对 size —— 一致=VERIFIED，不一致=RECHECK（提示校验）。
   *       · 全量(fullVerify=true)：重算 sha1 与基准比对 —— 一致=VERIFIED；不一致则反查当前哈希，
   *         命中源(换了版本)→重链+更新基准=VERIFIED；反查全落空→CORRUPT。
   *     更新检查所需的 source/projectId/versionId 直接取清单，**无需哈希**。
   *   - 未收编：算 sha1 → Modrinth 反查；miss → CF Murmur2 指纹反查。命中即"链接"并收编进清单
   *     (baseline=当前 sha1)=LINKED；全落空=UNKNOWN（**绝不判损坏**）。
   */
  async scan(req: ScanRequest): Promise<ScanResult> {
    let kind = req.kind !== undefined ? req.kind : ResourceKind.MOD;
    let dir: string;
    try {
      dir = resourceKindToInstallDir(kind, req.mcDir, req.versionId, req.versionIsolation);
    } catch (e) {
      AppLogger.warn(TAG, `unsupported kind for scan: ${kind}`, null, LOG_DOMAIN_DOWNLOAD);
      return { mods: [], lookedUpCount: 0, hitCount: 0 };
    }

    let entries: string[] = [];
    try {
      entries = fs.listFileSync(dir);
    } catch (e) {
      AppLogger.debug(TAG, `scan dir missing: ${dir}`, LOG_DOMAIN_DOWNLOAD);
      return { mods: [], lookedUpCount: 0, hitCount: 0 };
    }

    let validExts = isResourcePackOrShader(kind) ? ['.zip'] : ['.jar', '.jar.disabled'];
    let files: string[] = [];
    for (let name of entries) {
      let lower = name.toLowerCase();
      for (let ext of validExts) {
        if (lower.endsWith(ext)) { files.push(name); break; }
      }
    }

    let mods: LocalMod[] = [];
    for (let name of files) {
      let path = dir + '/' + name;
      let sizeBytes = 0;
      try {
        sizeBytes = fs.statSync(path).size;
      } catch (e) {
        AppLogger.warn(TAG, `stat failed: ${path}`, null, LOG_DOMAIN_DOWNLOAD);
        continue;
      }
      mods.push({
        filePath: path, filename: name,
        enabled: !name.toLowerCase().endsWith('.disabled'),
        sizeBytes, sha1: '',
      });
    }

    // 完整性/链接仅对 MOD 类有意义（资源包/光影不参与）
    if (kind !== ResourceKind.MOD || mods.length === 0) {
      return { mods, lookedUpCount: 0, hitCount: 0 };
    }

    let idx = readInstalledModIndex(dir);
    let fullVerify = req.fullVerify === true;
    let limit = req.lookupLimit !== undefined ? req.lookupLimit : 64;
    let unmanagedBudget = limit < 0 ? mods.length : limit;
    let dirty = false;           // 清单是否被 adopt/re-link 修改
    let lookedUpCount = 0;
    let hitCount = 0;

    let tasks = mods.map(async (m: LocalMod): Promise<void> => {
      let baseName = InstalledModIndex.baseNameOf(m.filename);
      let entry = idx.get(baseName);

      // ---------- 已收编（清单命中）----------
      if (entry !== null) {
        m.managed = true;
        m.expectedSha1 = entry.expectedSha1;
        m.remoteSource = entry.source;
        m.remoteProjectId = entry.projectId;
        m.remoteVersionId = entry.versionId;

        if (!fullVerify) {
          // 日常快检：只看 size
          m.integrity = (m.sizeBytes === entry.expectedSize)
            ? ModIntegrity.VERIFIED : ModIntegrity.RECHECK;
          return;
        }
        // 全量：重算 sha1 与基准比对
        let sha = '';
        try { sha = await computeFileSha1(m.filePath); } catch (e) { sha = ''; }
        m.sha1 = sha;
        if (sha.length > 0 && sha === entry.expectedSha1) {
          m.integrity = ModIntegrity.VERIFIED;
          return;
        }
        // 不符 → 反查当前哈希消歧：命中源=换了版本(重链)，全落空=损坏
        lookedUpCount++;
        let relinked = await this.reverseLink_(m, sha);
        if (relinked !== null) {
          // 用户换了版本 / 合法变体：更新基准
          entry.source = relinked.source;
          entry.projectId = relinked.projectId;
          entry.versionId = relinked.versionId;
          m.remoteSource = relinked.source;
          m.remoteProjectId = relinked.projectId;
          m.remoteVersionId = relinked.versionId;
          entry.expectedSha1 = sha;
          entry.expectedSize = m.sizeBytes;
          if (relinked.cfFingerprint > 0) entry.cfFingerprint = relinked.cfFingerprint;
          idx.upsert(entry);
          dirty = true;
          hitCount++;
          m.integrity = ModIntegrity.VERIFIED;
        } else {
          m.integrity = ModIntegrity.CORRUPT;
        }
        return;
      }

      // ---------- 未收编：尝试反查链接 ----------
      if (this.modrinth_ === null || unmanagedBudget <= 0) {
        m.integrity = ModIntegrity.UNKNOWN;
        return;
      }
      unmanagedBudget--;
      lookedUpCount++;
      let sha = '';
      try { sha = await computeFileSha1(m.filePath); } catch (e) { sha = ''; }
      m.sha1 = sha;
      if (sha.length === 0) { m.integrity = ModIntegrity.UNKNOWN; return; }

      let link = await this.reverseLink_(m, sha);
      if (link === null) {
        m.integrity = ModIntegrity.UNKNOWN;
        return;
      }
      // 命中 → 链接 + 收编进清单（baseline=当前 sha1）
      hitCount++;
      m.remoteSource = link.source;
      m.remoteProjectId = link.projectId;
      m.remoteVersionId = link.versionId;
      m.managed = true;
      m.expectedSha1 = sha;
      m.integrity = ModIntegrity.LINKED;
      let newEntry: InstalledModEntry = {
        baseName, source: link.source, projectId: link.projectId, versionId: link.versionId,
        expectedSha1: sha, expectedSize: m.sizeBytes, displayName: link.displayName, at: Date.now(),
      };
      if (link.cfFingerprint > 0) newEntry.cfFingerprint = link.cfFingerprint;
      idx.upsert(newEntry);
      dirty = true;
    });
    await Promise.all(tasks);

    if (dirty) writeInstalledModIndex(dir, idx);

    AppLogger.info(TAG,
      `scan done: dir=${dir} files=${mods.length} lookedUp=${lookedUpCount} hits=${hitCount} full=${fullVerify ? 'yes' : 'no'}`,
      LOG_DOMAIN_DOWNLOAD);
    return { mods, lookedUpCount, hitCount };
  }

  /**
   * 反查文件对应的源版本：先 Modrinth sha1，miss 则 CF Murmur2 指纹。
   * 命中返回 {source, projectId, versionId, cfFingerprint, displayName}；全落空返回 null。
   */
  private async reverseLink_(m: LocalMod, sha1: string): Promise<ReverseLink | null> {
    // 1) Modrinth sha1
    if (this.modrinth_ !== null && sha1.length > 0) {
      try {
        let ver = await this.modrinth_.lookupVersionBySha1(sha1);
        if (ver !== null && ver.projectId.length > 0) {
          return { source: ModSource.MODRINTH, projectId: ver.projectId, versionId: ver.id, cfFingerprint: 0, displayName: ver.name };
        }
      } catch (e) {
        AppLogger.warn(TAG, `modrinth lookup failed for ${m.filename}`, e as Object, LOG_DOMAIN_DOWNLOAD);
      }
    }
    // 2) CurseForge Murmur2 指纹
    if (this.curseforge_ !== null) {
      try {
        let fp = await computeCurseForgeFingerprint(m.filePath);
        if (fp > 0) {
          let ver = await this.curseforge_.lookupByFingerprint(fp);
          if (ver !== null && ver.projectId.length > 0) {
            return { source: ModSource.CURSEFORGE, projectId: ver.projectId, versionId: ver.id, cfFingerprint: fp, displayName: ver.name };
          }
        }
      } catch (e) {
        AppLogger.warn(TAG, `curseforge fingerprint lookup failed for ${m.filename}`, e as Object, LOG_DOMAIN_DOWNLOAD);
      }
    }
    return null;
  }
}

/** reverseLink_ 的返回结构。 */
interface ReverseLink {
  source: ModSource;
  projectId: string;
  versionId: string;
  /** CF 命中时的指纹（用于收编 cfFingerprint）；Modrinth 为 0。 */
  cfFingerprint: number;
  displayName: string;
}

// ============================================================
//  纯函数：kind 与 ext 映射
// ============================================================

/** 资源包 / 光影 用 .zip；mod 用 .jar / .jar.disabled */
function isResourcePackOrShader(kind: ResourceKind): boolean {
  return kind === ResourceKind.RESOURCE_PACK || kind === ResourceKind.SHADER;
}

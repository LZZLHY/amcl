/**
 * InstalledLoaderResolver.ets — 已装版本的 loader / MC 版本解析（权威优先 + 缓存）
 *
 * 背景（整合包 / 重命名版本暴露的架构缺陷）：
 *   AMCL 历史上靠**版本名字符串**(`detectLoaderFromId` / `extractGameVersionFromId`)识别
 *   loader 与 MC 版本——只对约定命名 (fabric-loader-X-Y / 1.20.4-forge-...) 有效。整合包用
 *   自定义名(如 "Fabulously Optimized")、或用户重命名版本后，名字里既无 loader 关键字、也无
 *   版本号 → 被误判为原版 / MC 版本显示成整合包名，进而首页显示错、JDK 路由错（纪元判 UNKNOWN
 *   → 错 JDK → Fabric 拒绝启动）、往该版本下模组被"请先装 Fabric/Forge"拦截等。
 *
 *   本模块对**本地已装版本**改为权威源优先：
 *     1. 整合包快照 `.amcl-modpack.json`（安装时写入精确 gameVersion / loaderType）——最权威；
 *     2. `versions/<id>/<id>.json` 内容（mainClass/libraries / clientVersion，与启动链路同源）；
 *     3. 版本名兜底（约定命名 / json 缺失时）。
 *
 * 缓存：版本的 loader / MC 版本在安装后不再变化，按 `mcDir|versionId` 缓存；版本集合变化
 *   (新装/删除/重命名)时由调用方 `invalidateInstalledLoaderCache()` 清空。
 *
 * 创建日期：2026-06-15（2026-06-23 改为快照/内容优先 + 新增 MC 版本解析）
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { VersionParser, safeBaseName } from 'feature_core';
import { detectLoaderFromId, detectLoaderFromVersionJson, extractGameVersionFromId } from './VersionIdUtils';
import { readModpackSnapshot } from './ModpackSnapshot';

const loaderCache_: Map<string, string> = new Map();
const mcVerCache_: Map<string, string> = new Map();

/** 继承仅允许版本目录下的单个目录项，防止异常清单导致越界读取。 */
interface InheritedVersionMetadata { inheritsFrom?: string; }

/**
 * 解析本地已装版本的 loader：'fabric' / 'forge' / 'neoforge' / 'quilt' / ''（原版）。
 * 权威源优先：整合包快照 → version.json 内容 → 版本名兜底。
 * 与 `detectLoaderFromId` 返回值域一致，可直接替换其在本地版本场景的调用。
 *
 * @param mcDir .minecraft 根目录（不带尾部 /）
 * @param versionId 版本目录名
 */
export function resolveInstalledLoader(mcDir: string, versionId: string): string {
  if (versionId.length === 0) return '';
  let key = mcDir + '|' + versionId;
  let cached = loaderCache_.get(key);
  if (cached !== undefined) return cached;
  let loader = resolveLoaderUncached_(mcDir, versionId);
  loaderCache_.set(key, loader);
  return loader;
}

function resolveLoaderUncached_(mcDir: string, versionId: string, visited: string[] = []): string {
  // 继承链只用于读取权威元数据；循环或超深链保持“未知”，不猜成某个加载器。
  if (safeBaseName(versionId).length === 0 || visited.indexOf(versionId) >= 0 || visited.length >= 16) return '';
  visited.push(versionId);
  let versionDir = mcDir + '/versions/' + versionId;
  // 1. 整合包快照（权威）：安装时写入的精确 loaderType
  let snap = readModpackSnapshot(versionDir);
  if (snap !== null && snap.loaderType.length > 0 && snap.loaderType !== 'none') {
    return snap.loaderType;
  }
  // 2. version.json 内容（mainClass/libraries，与启动同源）
  let jsonRead = false;
  try {
    let text = fs.readTextSync(versionDir + '/' + versionId + '.json');
    jsonRead = true;
    let byContent = detectLoaderFromVersionJson(text);
    if (byContent.length > 0) return byContent;
    const metadata = JSON.parse(text) as InheritedVersionMetadata;
    if (metadata.inheritsFrom !== undefined && safeBaseName(metadata.inheritsFrom).length > 0)
      return resolveLoaderUncached_(mcDir, metadata.inheritsFrom, visited);
  } catch (e) {
    jsonRead = false;
  }
  // 内容读到了但判定为原版（无 loader 信号）→ 就是原版
  if (jsonRead) return '';
  // 3. json 读不到 → 名字兜底（约定命名）
  return detectLoaderFromId(versionId);
}

/**
 * 解析本地已装版本的真实 MC 版本号（如 "1.20.1"）。
 * 权威源优先：整合包快照 gameVersion → version.json 内容(clientVersion 等) → 版本名兜底。
 * 用于替换"对已装版本名直接 extractGameVersionFromId"的场景（整合包/重命名名拿不到版本号）。
 *
 * @returns MC 版本号；彻底判不出时回退到对版本名的解析（可能为原串）。
 */
export function resolveInstalledMcVersion(mcDir: string, versionId: string): string {
  if (versionId.length === 0) return '';
  let key = mcDir + '|' + versionId;
  let cached = mcVerCache_.get(key);
  if (cached !== undefined) return cached;
  let v = resolveMcVersionUncached_(mcDir, versionId);
  mcVerCache_.set(key, v);
  return v;
}

function resolveMcVersionUncached_(mcDir: string, versionId: string, visited: string[] = []): string {
  if (safeBaseName(versionId).length === 0 || visited.indexOf(versionId) >= 0 || visited.length >= 16) return '';
  visited.push(versionId);
  let versionDir = mcDir + '/versions/' + versionId;
  // 1. 整合包快照（权威）
  let snap = readModpackSnapshot(versionDir);
  if (snap !== null && snap.gameVersion.length > 0) return snap.gameVersion;
  // 2. version.json 内容（clientVersion / --fml.mcVersion / inheritsFrom / id）
  let byContent = VersionParser.detectVanillaVersion(versionDir + '/' + versionId + '.json');
  if (byContent !== null && byContent.length > 0) {
    // detectVanillaVersion 把 inheritsFrom 当候选返回；它也可能是另一个自定义版本名。
    // 此时继续读父元数据，不能把那个目录名作为 MC 版本交给模组仓库筛选。
    try {
      const metadata = JSON.parse(fs.readTextSync(versionDir + '/' + versionId + '.json')) as InheritedVersionMetadata;
      if (metadata.inheritsFrom === byContent && safeBaseName(byContent).length > 0)
        return resolveMcVersionUncached_(mcDir, byContent, visited);
    } catch (e) { /* 读取失败沿用现有内容和名称回退，不扩大文件访问范围。 */ }
    // detectVanillaVersion 可能退化到 id（自定义名）或返回 "1.20.1-fabric-x"，归一化成纯版本号
    let norm = extractGameVersionFromId(byContent);
    if (norm.length > 0) return norm;
  }
  // 3. 名字兜底
  return extractGameVersionFromId(versionId);
}

/** 清空解析缓存（版本集合变化时调用：scanVersions / 安装完成 / 重命名 / 删除）。 */
export function invalidateInstalledLoaderCache(): void {
  loaderCache_.clear();
  mcVerCache_.clear();
}

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

import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { VersionParser, safeBaseName, parseMavenName, verifiedVanillaMetadata } from 'feature_core';
import { detectLoaderFromId, detectLoaderFromVersionJson, extractGameVersionFromId } from './VersionIdUtils';
import { readModpackSnapshot } from './ModpackSnapshot';

const loaderCache_: Map<string, string> = new Map();
const mcVerCache_: Map<string, string> = new Map();
const gameIdCache_: Map<string, string> = new Map();

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

/** 显示用官方标识须保留 pre/rc、远古版及愚人节后缀，不能按资源搜索规则截断。 */
export function resolveInstalledGameId(mcDir: string, versionId: string): string {
  if (versionId.length === 0) return '';
  const key = mcDir + '|' + versionId;
  const cached = gameIdCache_.get(key);
  if (cached !== undefined) return cached;
  const game = resolveMcVersionUncached_(mcDir, versionId, [], false);
  gameIdCache_.set(key, game);
  return game;
}

function resolveMcVersionUncached_(mcDir: string, versionId: string, visited: string[] = [],
  normalizeForSearch: boolean = true): string {
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
        return resolveMcVersionUncached_(mcDir, byContent, visited, normalizeForSearch);
    } catch (e) { /* 读取失败沿用现有内容和名称回退，不扩大文件访问范围。 */ }
    // detectVanillaVersion 可能退化到 id（自定义名）或返回 "1.20.1-fabric-x"，归一化成纯版本号
    if (!normalizeForSearch) return byContent;
    let norm = extractGameVersionFromId(byContent);
    if (norm.length > 0) return norm;
  }
  // 3. 名字兜底
  return normalizeForSearch ? extractGameVersionFromId(versionId) : versionId;
}

/** 清空解析缓存（版本集合变化时调用：scanVersions / 安装完成 / 重命名 / 删除）。 */
export function invalidateInstalledLoaderCache(): void {
  loaderCache_.clear();
  mcVerCache_.clear();
  gameIdCache_.clear();
}


/** 安装内容中的精确身份；加载器版本缺少确定坐标时保留空值，不能把标签当作版本。 */
export interface InstalledVersionIdentity {
  gameVersion: string;
  loader: string;
  loaderVersion: string;
}
interface InstalledLibraryMetadata { name?: string; }

/** 仅接纳产品实际安装器的主 Maven 坐标。同一清单内出现不同版本视为不能确证。 */
function exactLoaderVersion(libraries: InstalledLibraryMetadata[], loader: string, game: string): string {
  let result = '';
  for (const lib of libraries) {
    if (!lib || typeof lib.name !== 'string') continue;
    const coordinate = parseMavenName(lib.name);
    if (!coordinate) continue;
    const artifact = coordinate.groupId + ':' + coordinate.artifactId;
    if (!(loader === 'fabric' && artifact === 'net.fabricmc:fabric-loader') &&
      !(loader === 'quilt' && artifact === 'org.quiltmc:quilt-loader') &&
      !(loader === 'forge' && artifact === 'net.minecraftforge:forge') &&
      !(loader === 'neoforge' && artifact === 'net.neoforged:neoforge')) continue;
    let version = coordinate.version;
    if (loader === 'forge') {
      if (!version.startsWith(game + '-')) return '';
      version = version.substring(game.length + 1);
    }
    if (!version || (result && result !== version)) return '';
    result = version;
  }
  return result;
}

/** 从原始清单与快照证明身份。循环、不可读或只有自定义实例名时返回未知；不复用按名字猜测的显示缓存。 */
export function inspectInstalledVersion(root: string, version: string, parents: string[] = []): InstalledVersionIdentity | null {
  if (!version || version !== safeBaseName(version) || parents.includes(version) || parents.length >= 16) return null;
  const dir = root + '/versions/' + version;
  const path = dir + '/' + version + '.json';
  try {
    const directory = fs.lstatSync(dir);
    const file = fs.lstatSync(path);
    if (!directory.isDirectory() || directory.isSymbolicLink() || !file.isFile() || file.isSymbolicLink()
      || file.size <= 0 || file.size > 8 * 1024 * 1024) return null;
    const text = fs.readTextSync(path);
    const metadata = JSON.parse(text) as Record<string, Object>;
    const parent = metadata['inheritsFrom'];
    let inherited: InstalledVersionIdentity | null = null;
    if (typeof parent === 'string' && parent) {
      inherited = inspectInstalledVersion(root, parent as string, parents.concat([version]));
      if (!inherited) return null;
    }
    const snapshot = readModpackSnapshot(dir);
    let game = VersionParser.vanillaVersionFromMetadata(metadata, false) ?? '';
    if (inherited && (game === parent || !game)) game = inherited.gameVersion;
    const declared = snapshot?.gameVersion ?? '';
    if (declared && game && declared !== game) return null;
    game = declared || game;
    if (!game || safeBaseName(game) !== game) return null;
    let loader = detectLoaderFromVersionJson(text) || inherited?.loader || '';
    const snapshotLoader = snapshot?.loaderType ?? '';
    if (snapshotLoader && loader && snapshotLoader !== loader) return null;
    loader = snapshotLoader || loader;
    if (!loader) {
      // 未知自定义启动器不能因缺少已知加载器信号被报作原版。
      const cls = metadata['mainClass'];
      if (cls !== 'net.minecraft.client.main.Main' && cls !== 'net.minecraft.client.Minecraft') return null;
      loader = 'vanilla';
    }
    const libs = metadata['libraries'];
    let loaderVersion = Array.isArray(libs) ? exactLoaderVersion(libs as InstalledLibraryMetadata[], loader, game) : '';
    const declaredLoaderVersion = snapshot?.loaderVersion ?? '';
    if (loaderVersion && declaredLoaderVersion && loaderVersion !== declaredLoaderVersion) return null;
    if (!loaderVersion && inherited?.loader === loader) loaderVersion = inherited.loaderVersion;
    return { gameVersion: game, loader: loader, loaderVersion: declaredLoaderVersion || loaderVersion };
  } catch (_) { return null; }
}


interface OriginClient { sha1: string; size: number; }
interface OriginDownloads { client?: OriginClient; }
/**
 * 原版清单仅允许实例 id 与官方发布 id 不同。按字段比较忽略缩进与顶层顺序，
 * 新增/删改库、JVM 参数、下载校验或未识别的其他字段都不能获得官方内容身份。
 */
function sameVanillaManifest(local: Record<string, Object>, authority: Record<string, Object>): boolean {
  const keys = Object.keys(local);
  if (keys.length !== Object.keys(authority).length) return false;
  return keys.every((key: string): boolean => key === 'id' ||
    (authority[key] !== undefined && JSON.stringify(local[key]) === JSON.stringify(authority[key])));
}

function immutableFileStamp(stat: fs.Stat): string {
  return String(stat.ino) + ':' + stat.size + ':' +
    String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/**
 * 老的原版清单只有实例 id。它仅用于找候选；以官方清单声明的客户端和本地真实 JAR 串流摘要核实。
 * 该异步检查只供明确的身份查询；启动、列表扫描和普通 UI 不因此触网或读取整份游戏。
 */
export async function inspectLegacyVanilla(root: string, version: string, hint: string = ''): Promise<InstalledVersionIdentity | null> {
  if (!version || version !== safeBaseName(version)) return null;
  const dir = root + '/versions/' + version;
  const path = dir + '/' + version + '.json';
  const jar = dir + '/' + version + '.jar';
  try {
    const directory = fs.lstatSync(dir);
    const file = fs.lstatSync(path);
    const clientFile = fs.lstatSync(jar);
    if (!directory.isDirectory() || directory.isSymbolicLink() || !file.isFile() || file.isSymbolicLink()
      || file.size <= 0 || file.size > 1024 * 1024 || !clientFile.isFile() || clientFile.isSymbolicLink()) return null;
    const localText = fs.readTextSync(path);
    const local = JSON.parse(localText) as Record<string, Object>;
    const localId = local['id'];
    if (typeof localId !== 'string' || !localId || !local['mainClass'] || detectLoaderFromVersionJson(localText)
      || VersionParser.vanillaVersionFromMetadata(local, false) !== null || readModpackSnapshot(dir) !== null) return null;
    const id = hint || (localId as string);
    if (id !== safeBaseName(id)) return null;
    const officialText = await verifiedVanillaMetadata(id);
    if (!officialText) return null;
    const official = JSON.parse(officialText) as Record<string, Object>;
    const claimed = (local['downloads'] as OriginDownloads)?.client;
    const known = (official['downloads'] as OriginDownloads)?.client;
    if (official['id'] !== id || !claimed || !known || !/^[a-f0-9]{40}$/.test(known.sha1)
      || !Number.isSafeInteger(known.size) || known.size <= 0 || known.size > 512 * 1024 * 1024
      || known.size !== claimed.size || known.sha1 !== claimed.sha1 || known.size !== clientFile.size
      || !sameVanillaManifest(local, official)) return null;
    // 文件服务异步计算完整 JAR 摘要，避免旧大版本校验在首页主线程同步读到 EOF。
    const jarSha1 = (await hash.hash(jar, 'sha1')).toLowerCase();
    if (jarSha1 !== known.sha1 || immutableFileStamp(fs.lstatSync(jar)) !== immutableFileStamp(clientFile)
      || immutableFileStamp(fs.lstatSync(path)) !== immutableFileStamp(file) || fs.lstatSync(dir).ino !== directory.ino) return null;
    return { gameVersion: id, loader: 'vanilla', loaderVersion: '' };
  } catch (_) { return null; }
}

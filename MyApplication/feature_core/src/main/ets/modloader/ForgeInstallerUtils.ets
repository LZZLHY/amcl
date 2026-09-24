/**
 * ForgeInstallerUtils.ets — Forge 安装器工具函数
 *
 * 参照 PCL (McDownloadForgelikeLoader) 提取的核心逻辑：
 * - 从 installer jar 解压后读取 install_profile.json + version.json
 * - 合并 JSON 并提取 libraries 列表
 * - 预下载 Mappings
 * - 旧版 Forge 直接解压安装
 * - 复制 maven/ 目录到 libraries/
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  mavenToRelativePath,
  safeBaseName,
  safeRelPath,
  isSafeHttpUrl,
  MavenLibEntry,
} from './MavenUtils';
import { BMCLAPI_BASE, BMCLAPI_HOST, MOJANG_META } from 'commons';
import { DownloadManager } from '../download/DownloadManager';
import { fileExistsAndNonEmpty } from 'commons';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';

const TAG = LogTags.MOD_FORGE_INSTALLER;
const BMCLAPI_MAVEN = BMCLAPI_BASE + '/maven';
const MOJANG_VERSION_MANIFEST = MOJANG_META + '/mc/game/version_manifest_v2.json';
const BMCLAPI_VERSION_MANIFEST = BMCLAPI_BASE + '/mc/game/version_manifest_v2.json';
const NEW_FORGE_LOADER_THRESHOLD = 20;
const SHA1_HEX_LEN = 40;

/**
 * 归一化 `install_profile.json` 里指向**安装器内部条目**的路径（`json` / `install.filePath`）。
 *
 * Forge 用 **ZIP 条目绝对形式**表示自身内部路径 —— 旧版 install_profile 的
 * `"json": "/version.json"` 就带前导 `/`。而 `safeRelPath` 按设计拒绝一切以 `/`
 * 开头的输入（`MavenUtils.ets:56`），两者直接对接会把**每一个**走 Legacy 方式 1 的
 * 旧版 Forge 都判成"路径不安全"。
 *
 * 真机实证（2026-08-08 14:38:20，1.12.2-14.23.5.2864）：安装器已下载并校验通过
 * （sha1 命中）、解压成功（`profile=yes versionJson=yes`），下一步立刻
 *   `模组加载器安装失败: install_profile.json 的 json 路径不安全`
 * → 整个下载任务被拒、版本目录被清理。100% 复现，与网络无关。
 *
 * 参照实现（PCL2，本文件 installLegacyForge 的注释里早已抄下这一行）：
 *   `GetJson(ReadFile(Installer.GetEntry(Json("json").TrimStart("/"))))`
 * —— `TrimStart("/")` 正是这里缺掉的那一步。新版分支
 * `ForgelikeInstaller.writeVersionJson` 也是先剥前导 `/` 再拼路径，本函数把两条
 * 分支的处理收敛为单一实现。
 *
 * @returns 剥掉前导 `/` 后经 `safeRelPath` 校验的相对路径；
 *          输入为空 → `''`；剥完为空或校验不过 → `''`（调用方按"原始非空但结果为空"判不安全）
 */
export function normalizeInstallerEntryPath(raw: string): string {
  if (raw.length === 0) return '';
  let p = raw;
  while (p.length > 0 && p.charAt(0) === '/') p = p.substring(1);
  if (p.length === 0) return '';
  return safeRelPath(p);
}

/** `.sha1` 侧车探测结果：拿到的 sha1 + 命中它的源在 urls 里的下标（-1 = 全部失败）。 */
export class InstallerSha1Probe {
  sha1: string = '';
  sourceIndex: number = -1;
}

/**
 * 并发探测 installer 的 `.sha1` 侧车文件，返回 sha1 + 命中源下标。**不抛异常**。
 *
 * `.sha1` 与 jar 同目录同源，因此"哪个源有 .sha1"基本等价于"哪个源真的托管了这个工件"，
 * 调用方可据此把命中源提到 URL 列表最前，省掉一次 HEAD 404 + 一次 GET 404 的空转。
 *
 * 超时固定 6s：这只是个 40 字节的侧车文件，6s 拿不到就是拿不到。三个源并发，
 * 总耗时 = 最慢那个的 6s 而不是三者相加 —— 串行 + 默认 30s 超时曾让用户在
 * "下载安装器"之前干等半分钟且最终 `sha1=(none)`。
 *
 * 2026-08-08：从 ForgelikeInstaller 的 private 方法提到此处，供**新旧两条分支共用**。
 * 旧版分支此前用的是「一次 fetchText(primary, mirrors) + 默认 30s + 失败抛异常」，
 * 既慢又会把"拿不到 sha1"升级成安装失败（见 ForgeService.checkInstallerArtifact）。
 */
export async function probeInstallerSha1(urls: string[]): Promise<InstallerSha1Probe> {
  let out = new InstallerSha1Probe();
  if (urls.length === 0) return out;
  const SHA1_PROBE_TIMEOUT_SECONDS = 6;
  let mgr = DownloadManager.instance();
  let probes: Promise<string>[] = [];
  for (let url of urls) {
    probes.push(
      mgr.fetchText(url + '.sha1', [], SHA1_PROBE_TIMEOUT_SECONDS)
        .then((text: string): string => {
          let m = /([0-9a-fA-F]{40})/.exec(text);
          return (m && m[1]) ? m[1].toLowerCase() : '';
        })
        .catch((e: Object): string => {
          AppLogger.warn(TAG, `installer sha1 probe failed: ${url}.sha1 err=${(e as Error)?.message ?? String(e)}`,
            null, LOG_DOMAIN_MODLOADER);
          return '';
        })
    );
  }
  let results: string[] = await Promise.all(probes);
  for (let i = 0; i < results.length; i++) {
    if (results[i].length === SHA1_HEX_LEN) {
      out.sha1 = results[i];
      out.sourceIndex = i;
      return out;
    }
  }
  return out;
}

/**
 * 把 `index` 指向的源移到列表最前，其余保持相对顺序。index 越界/已在首位时原样返回。
 * 纯偏好调整——引擎的多源 fallback 与坏主机熔断行为不受影响。
 */
export function preferSourceFirst(urls: string[], index: number): string[] {
  if (index <= 0 || index >= urls.length) return urls;
  let out: string[] = [urls[index]];
  for (let i = 0; i < urls.length; i++) {
    if (i !== index) out.push(urls[i]);
  }
  return out;
}

/**
 * 旧版 Forge 安装结果
 */
export class LegacyForgeInstallResult {
  success: boolean = false;
  versionId: string = '';
  error: string = '';

  constructor(success: boolean, versionId: string, error: string = '') {
    this.success = success;
    this.versionId = versionId;
    this.error = error;
  }
}

/**
 * 判断是否为新版 Forge（loaderVersion 首段 >= 20）
 * 参照 PCL: IsNeoForge OrElse LoaderVersion.BeforeFirst(".") >= 20
 */
export function isNewForgeVersion(loaderVersion: string): boolean {
  let dotIdx = loaderVersion.indexOf('.');
  let firstPart = dotIdx >= 0 ? loaderVersion.substring(0, dotIdx) : loaderVersion;
  let num = parseInt(firstPart);
  if (isNaN(num)) return true;
  return num >= NEW_FORGE_LOADER_THRESHOLD;
}

// fileExistsAndNonEmpty 已迁移到 utils/FileUtils（2026-05-06 D5-3 同期收尾）。
// 本模块内调用 import 版本；外部调用方（ForgeService）也已改为从 FileUtils 导入。
export { fileExistsAndNonEmpty };

/** 候选 JDK 大版本（installer 用；8 是 legacy 直解压路径专用，不参与新版 installer 选择）。 */
const INSTALLER_JDK_CANDIDATES: number[] = [17, 21, 25];

/**
 * 枚举【已安装】的 JDK 大版本（检查 filesDir/jdk/<major>/release 标记 + libjvm.so）。
 * 供 Forge / NeoForge installer 的 JDK 自动匹配复用（与 JdkManager.isInstalled 同口径的轻量版）。
 */
export function installedJdkMajors(filesDir: string): number[] {
  let out: number[] = [];
  for (let m of INSTALLER_JDK_CANDIDATES) {
    let root = filesDir + '/jdk/' + m;
    let releaseOk = fileExistsAndNonEmpty(root + '/release');
    let jvmOk = fileExistsAndNonEmpty(root + '/lib/server/libjvm.so');
    if (releaseOk && jvmOk) out.push(m);
  }
  return out;
}

/**
 * 解压 zip/jar 文件到目标目录（OHOS zlib API）
 *
 * 超时按归档大小自适应：Forge installer 等小包仍是 ~120s；大整合包（数百 MB）
 * 解压远超 120s，固定超时会误判失败，故每 100MB 追加 60s，封顶 20 分钟。
 * @param timeoutMs 显式超时（ms）；不传则按文件大小推算。
 */
export function decompressFile(zipPath: string, targetDir: string, timeoutMs?: number): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
    let limit = (timeoutMs !== undefined && timeoutMs > 0) ? timeoutMs : computeDecompressTimeout(zipPath);
    let timedOut = false;
    let timer = setTimeout(() => {
      // 平台 API 无取消句柄：只记录超时，必须等底层回调后才能 settle/由调用方清理。
      timedOut = true;
    }, limit);
    zlib.decompressFile(zipPath, targetDir, (err: BusinessError) => {
      clearTimeout(timer);
      if (err) {
        reject(new Error('解压失败: ' + err.message));
        return;
      }
      try {
        scanExtractedTree(targetDir, zipPath);
      } catch (e) {
        reject(e as Error);
        return;
      }
      if (timedOut) {
        reject(new Error('解压超时（' + Math.round(limit / 1000) + '秒；底层操作已等待完成）'));
      } else {
        resolve();
      }
    });
  });
}

class ExtractScanStats {
  entries: number = 0;
  bytes: number = 0;
}

const MAX_EXTRACTED_FILES = 200000;
const MAX_EXTRACTED_BYTES = 16 * 1024 * 1024 * 1024;
const MIN_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024;

/** 解压后做可枚举范围内的最强校验：拒绝链接/特殊文件、限制数量与总大小。 */
function scanExtractedTree(targetDir: string, archivePath: string): void {
  let archiveSize = 0;
  try { archiveSize = fs.statSync(archivePath).size; } catch (e) { /* 默认下限 */ }
  let byteLimit = Math.min(MAX_EXTRACTED_BYTES, Math.max(MIN_EXTRACTED_BYTES, archiveSize * 200));
  let root = targetDir;
  while (root.length > 1 && root.endsWith('/')) root = root.substring(0, root.length - 1);
  let rootStat = fs.lstatSync(root);
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
    throw new Error('解压目标不是普通目录');
  }
  let stats = new ExtractScanStats();
  scanExtractedDir_(root, root, stats, byteLimit, 0);
}

function scanExtractedDir_(root: string, dir: string, stats: ExtractScanStats,
  byteLimit: number, depth: number): void {
  if (depth > 64) throw new Error('解压目录层级过深');
  let entries = fs.listFileSync(dir);
  for (let name of entries) {
    if (safeBaseName(name) !== name) throw new Error('解压产物包含非法文件名');
    let path = dir + '/' + name;
    if (!path.startsWith(root + '/')) throw new Error('解压产物越过目标目录');
    let rel = path.substring(root.length + 1);
    if (safeRelPath(rel) !== rel) throw new Error('解压产物包含非法相对路径');
    stats.entries += 1;
    if (stats.entries > MAX_EXTRACTED_FILES) throw new Error('解压文件或目录数量超限');
    let st = fs.lstatSync(path);
    if (st.isSymbolicLink()) throw new Error('解压产物包含符号链接: ' + rel);
    if (st.isDirectory()) {
      scanExtractedDir_(root, path, stats, byteLimit, depth + 1);
    } else if (st.isFile()) {
      if (st.size < 0) throw new Error('解压产物文件大小无效: ' + rel);
      stats.bytes += st.size;
      if (stats.bytes > byteLimit) throw new Error('解压后总大小超限');
    } else {
      throw new Error('解压产物包含非普通文件: ' + rel);
    }
  }
}

/** 按归档字节数推算解压超时：120s 起步，每 100MB +60s，封顶 1200s。 */
function computeDecompressTimeout(zipPath: string): number {
  let sizeMb = 0;
  try { sizeMb = fs.statSync(zipPath).size / (1024 * 1024); } catch (e) { /* 取不到大小用默认 */ }
  let ms = 120000 + Math.round(sizeMb / 100) * 60000;
  return Math.min(ms, 1200000);
}

/**
 * 从解压后的 installer 目录中读取 JSON 文件
 */
function readJsonFile(path: string): Record<string, Object> | null {
  try {
    let text = fs.readTextSync(path);
    return JSON.parse(text) as Record<string, Object>;
  } catch (e) {
    return null;
  }
}

/**
 * 某 library 是否带【可下载的真实 artifact URL】（downloads.artifact.url 或顶层 url 非空）。
 * 用于区分"生成态/捆绑态"（url 空，如 Forge binarypatcher 的 :client、legacy 自带 maven/ 的 forge jar）
 * 与"真实可下载工件"（如现代 Forge 的 :universal，published 到 maven.minecraftforge.net）。
 */
function libHasArtifactUrl(lib: Record<string, Object>): boolean {
  let downloads = lib['downloads'] as Record<string, Object> | undefined;
  if (downloads && downloads['artifact']) {
    let artifact = downloads['artifact'] as Record<string, Object>;
    let artUrl = artifact['url'] as string | undefined;
    if (artUrl && artUrl.length > 0) return true;
  }
  let libUrl = lib['url'] as string | undefined;
  return libUrl !== undefined && libUrl.length > 0;
}

/**
 * 从 install_profile.json + version.json 中提取所有 libraries
 * 参照 PCL: Json.Merge(Json2) 后 McLibListGetWithJson(Json, True)
 */
export function extractLibrariesFromInstallerJson(
  profilePath: string, versionJsonPath: string, forgeVersion: string, extraSkipPrefix?: string
): MavenLibEntry[] {
  let result: MavenLibEntry[] = [];
  let seenNames = new Set<string>();
  let profileObj = readJsonFile(profilePath);
  let versionObj = readJsonFile(versionJsonPath);

  // 从 install_profile.json 的 libraries 提取
  if (profileObj && profileObj['libraries']) {
    let libs = profileObj['libraries'] as Array<Record<string, Object>>;
    for (let lib of libs) {
      let name = (lib['name'] as string) || '';
      if (name.length === 0 || seenNames.has(name)) continue;
      // Forge 自身坐标：:client（binarypatcher 生成、url 空）/ legacy 自带（maven/ 内、url 空）跳过；
      // 但 :universal（现代 Forge 真实 maven 工件，有 url）必须下载——只按"无可下载 URL"跳过。
      if (name.indexOf('net.minecraftforge:forge:' + forgeVersion) >= 0 && !libHasArtifactUrl(lib)) continue;
      // NeoForge 等：跳过加载器自身（generated）坐标，避免去 maven 下载不存在的 client jar
      if (extraSkipPrefix && extraSkipPrefix.length > 0 && name.indexOf(extraSkipPrefix) >= 0) continue;
      seenNames.add(name);
      let entry: MavenLibEntry = { name: name };
      let libUrl = lib['url'] as string | undefined;
      if (libUrl) entry.url = libUrl;
      // 尝试从 downloads.artifact 获取 url / sha1 / size
      let downloads = lib['downloads'] as Record<string, Object> | undefined;
      if (downloads && downloads['artifact']) {
        let artifact = downloads['artifact'] as Record<string, Object>;
        let artUrl = artifact['url'] as string | undefined;
        if (artUrl && artUrl.length > 0) {
          // 显式真实下载 URL（Forge 重定位库的 url ≠ 坐标重构路径，必须原样用）。
          entry.directUrl = artUrl;
          // BUG-6 fix: 从完整 URL 中正确提取 Maven 仓库根 URL（作 repoHint 兜底）
          // 旧逻辑截取 lastIndexOf('/') 导致路径翻倍（如 .../5.0.4/ + net/.../5.0.4/xxx.jar）
          let relPath = mavenToRelativePath(name);
          if (relPath && artUrl.endsWith(relPath)) {
            entry.url = artUrl.substring(0, artUrl.length - relPath.length);
          } else if (relPath && artUrl.endsWith('/' + relPath)) {
            entry.url = artUrl.substring(0, artUrl.length - relPath.length - 1);
          }
          // else: 保留 lib['url']（不覆盖）
        }
        let artPath = artifact['path'] as string | undefined;
        if (artPath && artPath.length > 0) {
          let storagePath = safeRelPath(artPath);
          if (storagePath.length === 0) throw new Error('install_profile artifact.path 不安全');
          entry.storagePath = storagePath;
        }
        let artSha1 = artifact['sha1'] as string | undefined;
        if (artSha1 && artSha1.length === 40) entry.sha1 = artSha1;
        let artSize = artifact['size'] as number | undefined;
        if (artSize && artSize > 0) entry.size = artSize;
      }
      result.push(entry);
    }
  }

  // 从 version.json 的 libraries 提取
  if (versionObj && versionObj['libraries']) {
    let libs = versionObj['libraries'] as Array<Record<string, Object>>;
    for (let lib of libs) {
      let name = (lib['name'] as string) || '';
      if (name.length === 0 || seenNames.has(name)) continue;
      if (name.indexOf('net.minecraftforge:forge:' + forgeVersion) >= 0 && !libHasArtifactUrl(lib)) continue;
      if (extraSkipPrefix && extraSkipPrefix.length > 0 && name.indexOf(extraSkipPrefix) >= 0) continue;
      seenNames.add(name);
      let entry: MavenLibEntry = { name: name };
      let libUrl = lib['url'] as string | undefined;
      if (libUrl) entry.url = libUrl;
      let downloads = lib['downloads'] as Record<string, Object> | undefined;
      if (downloads && downloads['artifact']) {
        let artifact = downloads['artifact'] as Record<string, Object>;
        let artUrl = artifact['url'] as string | undefined;
        if (artUrl && artUrl.length > 0) {
          entry.directUrl = artUrl;
          let relPath = mavenToRelativePath(name);
          if (relPath && artUrl.endsWith(relPath)) {
            entry.url = artUrl.substring(0, artUrl.length - relPath.length);
          } else if (relPath && artUrl.endsWith('/' + relPath)) {
            entry.url = artUrl.substring(0, artUrl.length - relPath.length - 1);
          }
        }
        let artPath = artifact['path'] as string | undefined;
        if (artPath && artPath.length > 0) {
          let storagePath = safeRelPath(artPath);
          if (storagePath.length === 0) throw new Error('version.json artifact.path 不安全');
          entry.storagePath = storagePath;
        }
        let artSha1 = artifact['sha1'] as string | undefined;
        if (artSha1 && artSha1.length === 40) entry.sha1 = artSha1;
        let artSize = artifact['size'] as number | undefined;
        if (artSize && artSize > 0) entry.size = artSize;
      }
      result.push(entry);
    }
  }

  AppLogger.info(TAG, `Extracted ${result.length} libraries from installer JSON`, LOG_DOMAIN_MODLOADER);
  return result;
}

/**
 * 预下载 Mappings（PCL 核心步骤）
 * 参照 PCL: If Json("data")("MOJMAPS") IsNot Nothing Then
 *   下载原版 Json 文件 → 获取 client_mappings URL → 下载到对应 Maven 路径
 */
export async function preDownloadMappings(
  installProfilePath: string, gameVersion: string, libDir: string
): Promise<void> {
  let profileObj = readJsonFile(installProfilePath);
  if (!profileObj) return;

  let data = profileObj['data'] as Record<string, Object> | undefined;
  if (!data) return;

  let mojmaps = data['MOJMAPS'] as Record<string, string> | undefined;
  if (!mojmaps) return;

  let clientSpec = mojmaps['client'] || '';
  if (clientSpec.length === 0) return;

  // clientSpec 格式: [net.minecraft:client:1.20.1-20230612.114412:mappings@txt]
  let specInner = clientSpec.replace(/^\[/, '').replace(/\]$/, '');
  let atIdx = specInner.indexOf('@');
  let ext = atIdx >= 0 ? specInner.substring(atIdx + 1) : 'jar';
  let coordPart = atIdx >= 0 ? specInner.substring(0, atIdx) : specInner;

  // 计算本地路径（Maven 坐标转文件路径）
  let relPath = mavenToRelativePath(coordPart + '@' + ext);
  if (relPath.length === 0) {
    AppLogger.warn(TAG, `Cannot parse MOJMAPS coord: ${clientSpec}`, null, LOG_DOMAIN_MODLOADER);
    return;
  }
  let localPath = libDir + '/' + relPath;

  // 检查是否已存在
  if (fileExistsAndNonEmpty(localPath)) {
    AppLogger.info(TAG, `Mappings already exists: ${localPath}`, LOG_DOMAIN_MODLOADER);
    return;
  }

  // 获取原版 JSON → 从中提取 client_mappings 下载地址
  // Phase 9 (ARCH-1 闭环)：全部走 NAPI fetchText（享受多源 fallback + 坏主机黑名单）
  AppLogger.info(TAG, 'Downloading version manifest to get client_mappings URL...', LOG_DOMAIN_MODLOADER);
  let mappingsUrl = '';
  let mgr = DownloadManager.instance();
  let manifestUrls = [BMCLAPI_VERSION_MANIFEST, MOJANG_VERSION_MANIFEST];
  for (let mUrl of manifestUrls) {
    try {
      let manifestText = await mgr.fetchText(mUrl);
      let manifest = JSON.parse(manifestText) as Record<string, Object>;
      let versions = manifest['versions'] as Array<Record<string, string>>;
      let versionUrl = '';
      for (let v of versions) {
        if (v['id'] === gameVersion) {
          versionUrl = v['url'] || '';
          break;
        }
      }
      if (versionUrl.length === 0) continue;

      // BMCLAPI 加速: 替换 piston-meta/launchermeta 域名
      let bmclapiVersionUrl = versionUrl
        .replace('piston-meta.mojang.com', BMCLAPI_HOST)
        .replace('launchermeta.mojang.com', BMCLAPI_HOST);

      // 合并 bmclapi + 官方 versionUrl 为单次多源调用（NAPI 自动 fallback）
      let versionMirrors: string[] = [];
      if (bmclapiVersionUrl !== versionUrl) versionMirrors.push(versionUrl);
      let versionText = await mgr.fetchText(bmclapiVersionUrl, versionMirrors);

      let versionJson = JSON.parse(versionText) as Record<string, Object>;
      let downloads = versionJson['downloads'] as Record<string, Object> | undefined;
      if (downloads && downloads['client_mappings']) {
        let cm = downloads['client_mappings'] as Record<string, string>;
        mappingsUrl = cm['url'] || '';
      }
      if (mappingsUrl.length > 0) break;
    } catch (e) {
      AppLogger.warn(TAG, `Failed to get manifest from ${mUrl}`, e, LOG_DOMAIN_MODLOADER);
    }
  }

  if (mappingsUrl.length === 0) {
    AppLogger.warn(TAG, `Could not find client_mappings URL for ${gameVersion}`, null, LOG_DOMAIN_MODLOADER);
    return;
  }

  // 下载 mappings 文件
  AppLogger.info(TAG, `Downloading mappings: ${mappingsUrl} → ${localPath}`, LOG_DOMAIN_MODLOADER);
  let destDir = localPath.substring(0, localPath.lastIndexOf('/'));
  try { fs.mkdirSync(destDir, true); } catch (e) { /* exists */ }

  // 优先 BMCLAPI 镜像
  let bmclapiMappingsUrl = mappingsUrl
    .replace('piston-data.mojang.com', BMCLAPI_HOST)
    .replace('launcher.mojang.com', BMCLAPI_HOST);

  let mappingDownloaded = false;
  // 保留循环 + 单源 fetchText：每个源需要逐一做"HTML/JSON 错误页"内容校验后才能
  // 判定是否成功（NAPI 引擎不感知 body 内容，仅校验 HTTP 200 + sha1/size）。
  for (let url of [bmclapiMappingsUrl, mappingsUrl]) {
    try {
      let text = await mgr.fetchText(url);
      // BUG-3 fix: 校验内容非 HTML/JSON 错误页（真正的 mappings 不以 '<' 或 '{' 开头）
      if (text.length > 0 && (text.charAt(0) === '<' || text.charAt(0) === '{')) {
        AppLogger.warn(TAG, `Mappings response looks like error page (starts with ${text.charAt(0)}), skipping source`, null, LOG_DOMAIN_MODLOADER);
        continue;
      }
      let f = fs.openSync(localPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(f.fd, text); } finally { fs.closeSync(f); }
      if (fileExistsAndNonEmpty(localPath)) {
        mappingDownloaded = true;
        break;
      }
    } catch (e) {
      AppLogger.warn(TAG, `Mappings download failed from ${url}`, e, LOG_DOMAIN_MODLOADER);
    }
  }
  AppLogger.info(TAG, `Mappings download: ${mappingDownloaded ? 'ok' : 'failed'}`, LOG_DOMAIN_MODLOADER);
}

/**
 * 递归复制 maven/ 目录内容到 libraries/
 * 参照 PCL: CopyDirectory(InstallerAddress & "_unrar\maven\", McFolder & "libraries\")
 */
export function copyMavenToLibraries(mavenDir: string, libDir: string): void {
  try {
    fs.statSync(mavenDir);
  } catch (e) {
    AppLogger.info(TAG, 'No maven/ directory in installer, skipping', LOG_DOMAIN_MODLOADER);
    return;
  }
  let copied = copyDirRecursive(mavenDir, libDir);
  AppLogger.info(TAG, `Copied ${copied} files from maven/ to libraries/`, LOG_DOMAIN_MODLOADER);
}

/**
 * 旧版 Forge 安装（PCL Legacy 方式 1 / 方式 2）
 * 参照 PCL:
 *   Legacy 方式 1: install_profile.json 无 "install" 字段
 *     → 读取 json 字段指向的 version.json，写入 versions/ 目录
 *     → 解压 maven/ 到 libraries/
 *   Legacy 方式 2: install_profile.json 有 "install" 字段
 *     → 解压 install.filePath 指向的 jar 到 libraries/
 *     → 将 versionInfo 写入 versions/ 目录
 */
export function installLegacyForge(
  gameVersion: string, loaderVersion: string, forgeVersion: string,
  versionId: string, mcDir: string, installerTempDir: string,
  installProfilePath: string, versionJsonFromInstaller: string
): LegacyForgeInstallResult {
  AppLogger.info(TAG, `Installing legacy Forge: ${forgeVersion}`, LOG_DOMAIN_MODLOADER);
  if (safeBaseName(gameVersion) !== gameVersion || safeBaseName(versionId) !== versionId) {
    return new LegacyForgeInstallResult(false, versionId, '版本标识包含不安全路径字符');
  }

  let profileObj = readJsonFile(installProfilePath);
  if (!profileObj) {
    return new LegacyForgeInstallResult(false, versionId, '无法读取 install_profile.json');
  }

  let versionDir = mcDir + '/versions/' + versionId;
  try { fs.mkdirSync(versionDir, true); } catch (e) { /* exists */ }
  let libDir = mcDir + '/libraries';
  try { fs.mkdirSync(libDir, true); } catch (e) { /* exists */ }

  let installField = profileObj['install'] as Record<string, string> | undefined;
  if (!installField) {
    // Legacy 方式 1: install_profile.json 无 "install" 字段
    // 参照 PCL: JsonVersion = GetJson(ReadFile(Installer.GetEntry(Json("json").TrimStart("/"))))
    AppLogger.info(TAG, 'Legacy method 1: extracting version.json from json field', LOG_DOMAIN_MODLOADER);
    let jsonRefRaw = (profileObj['json'] as string || '');
    // ⚠️ 必须先剥前导 '/' 再做安全校验：旧版 install_profile 的 json 字段是 ZIP 条目绝对形式
    //   （"/version.json"），直接喂 safeRelPath 会被判非法 → 每个 Legacy 方式 1 的旧版 Forge
    //   都装不上（真机 1.12.2-14.23.5.2864 实证）。详见 normalizeInstallerEntryPath。
    let jsonRef = normalizeInstallerEntryPath(jsonRefRaw);
    if (jsonRefRaw.length > 0 && jsonRef.length === 0) {
      return new LegacyForgeInstallResult(false, versionId,
        'install_profile.json 的 json 路径不安全: ' + jsonRefRaw);
    }
    let jsonSourcePath = jsonRef.length > 0
      ? installerTempDir + '/' + jsonRef
      : versionJsonFromInstaller;

    let versionJson = readJsonFile(jsonSourcePath);
    if (!versionJson) {
      return new LegacyForgeInstallResult(false, versionId, '无法读取版本 JSON: ' + jsonSourcePath);
    }
    versionJson['id'] = versionId;

    // 写入 version.json
    // 2026-05-23 ArkTS 严格模式：fs.openSync / writeSync / closeSync 都报
    // 'Function may throw'。包 try-catch + hilog + rethrow，finally 关 fd。
    // 详见 docs/guides/api-migration-2026-05.md。
    let destJsonPath = versionDir + '/' + versionId + '.json';
    let f: fs.File | null = null;
    try {
      f = fs.openSync(destJsonPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(versionJson));
    } catch (e) {
      AppLogger.warn(TAG, `write ${destJsonPath} failed`, e, LOG_DOMAIN_MODLOADER);
      throw e as Error;
    } finally {
      if (f) {
        try { fs.closeSync(f); } catch (_) { /* ignore */ }
      }
    }

    // 复制 maven/ 到 libraries/
    let mavenDir = installerTempDir + '/maven';
    copyMavenToLibraries(mavenDir, libDir);

    AppLogger.info(TAG, `Legacy method 1 complete: ${versionId}`, LOG_DOMAIN_MODLOADER);
    return new LegacyForgeInstallResult(true, versionId);
  } else {
    // Legacy 方式 2: install_profile.json 有 "install" 字段
    // 参照 PCL: 解压 install.filePath jar → 写入 versionInfo
    AppLogger.info(TAG, 'Legacy method 2: extracting jar from install.filePath', LOG_DOMAIN_MODLOADER);

    let filePath = installField['filePath'] || '';
    let mavenPath = installField['path'] || '';

    // 解压指定的 jar 文件到 libraries
    if (mavenPath.length > 0) {
      let relPath = mavenToRelativePath(mavenPath);
      if (relPath.length > 0) {
        let destJar = libDir + '/' + relPath;
        let destJarDir = destJar.substring(0, destJar.lastIndexOf('/'));
        try { fs.mkdirSync(destJarDir, true); } catch (e) { /* exists */ }

        // 同 json 字段：install.filePath 也可能带前导 '/'（ZIP 条目绝对形式），先归一化再校验。
        let safeFilePath = normalizeInstallerEntryPath(filePath);
        if (filePath.length > 0 && safeFilePath.length === 0) {
          return new LegacyForgeInstallResult(false, versionId, 'install.filePath 不安全: ' + filePath);
        }
        let srcJar = safeFilePath.length > 0 ? installerTempDir + '/' + safeFilePath : '';
        if (srcJar.length > 0 && fileExistsAndNonEmpty(srcJar)) {
          // 2026-05-23 ArkTS 严格模式：fs.copyFileSync 报 'Function may throw'。
          try {
            fs.copyFileSync(srcJar, destJar);
          } catch (e) {
            AppLogger.error(TAG, `copyFileSync ${srcJar} -> ${destJar} failed`, e, LOG_DOMAIN_MODLOADER);
            throw e as Error;
          }
          AppLogger.info(TAG, `Copied forge jar: ${destJar}`, LOG_DOMAIN_MODLOADER);
        }
      }
    }

    // 写入 version.json（从 versionInfo 字段）
    // 若 versionInfo 缺失，不能伪装成功：无 version.json 后续启动必失败
    let versionInfo = profileObj['versionInfo'] as Record<string, Object> | undefined;
    if (!versionInfo) {
      AppLogger.error(TAG, 'Legacy method 2 failed: install_profile.json has "install" field but no "versionInfo"', null, LOG_DOMAIN_MODLOADER);
      return new LegacyForgeInstallResult(
        false, versionId,
        '旧版 Forge 安装器缺少 versionInfo 字段，无法生成 version.json'
      );
    }
    versionInfo['id'] = versionId;
    if (!versionInfo['inheritsFrom']) {
      versionInfo['inheritsFrom'] = gameVersion;
    }
    let destJsonPath = versionDir + '/' + versionId + '.json';
    try {
      let f = fs.openSync(destJsonPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(f.fd, JSON.stringify(versionInfo)); } finally { fs.closeSync(f); }
    } catch (e) {
      AppLogger.error(TAG, 'Failed to write version.json', e, LOG_DOMAIN_MODLOADER);
      return new LegacyForgeInstallResult(
        false, versionId,
        '写入 version.json 失败: ' + (e as Error).message
      );
    }

    // 校验写入结果
    try {
      let st = fs.statSync(destJsonPath);
      if (st.size < 100) {
        return new LegacyForgeInstallResult(
          false, versionId,
          '生成的 version.json 过小（' + st.size + ' bytes），可能 versionInfo 字段不完整'
        );
      }
    } catch (e) {
      return new LegacyForgeInstallResult(
        false, versionId,
        'version.json 写入后不可读: ' + (e as Error).message
      );
    }

    AppLogger.info(TAG, `Legacy method 2 complete: ${versionId}`, LOG_DOMAIN_MODLOADER);
    return new LegacyForgeInstallResult(true, versionId);
  }
}

/**
 * 递归复制目录。R10: 加 depth 守卫（最大 32 层），防止符号链接循环导致栈溢出。
 * Forge installer maven 目录通常深度 < 10，32 层足够冗余。
 */
function copyDirRecursive(src: string, dest: string, depth: number = 0): number {
  if (depth > 32) throw new Error('copyDirRecursive 目录层级超限');
  let srcRoot = fs.lstatSync(src);
  if (srcRoot.isSymbolicLink() || !srcRoot.isDirectory()) {
    throw new Error('复制源不是普通目录: ' + src);
  }
  try { fs.mkdirSync(dest, true); } catch (e) { /* exists */ }
  let destRoot = fs.lstatSync(dest);
  if (destRoot.isSymbolicLink() || !destRoot.isDirectory()) {
    throw new Error('复制目标不是普通目录: ' + dest);
  }
  let count = 0;
  let entries = fs.listFileSync(src);
  for (let name of entries) {
    if (safeBaseName(name) !== name) throw new Error('复制源包含非法文件名');
    let srcPath = src + '/' + name;
    let destPath = dest + '/' + name;
    let st = fs.lstatSync(srcPath);
    if (st.isSymbolicLink()) throw new Error('拒绝复制符号链接: ' + srcPath);
    if (st.isDirectory()) {
      count += copyDirRecursive(srcPath, destPath, depth + 1);
    } else if (st.isFile()) {
      let needCopy = true;
      try {
        let destSt = fs.lstatSync(destPath);
        if (destSt.isSymbolicLink() || !destSt.isFile()) {
          throw new Error('复制目标存在非普通文件: ' + destPath);
        }
        if (destSt.size === st.size && destSt.size > 0) needCopy = false;
      } catch (e) {
        let message = (e as Error).message;
        if (message.indexOf('复制目标存在非普通文件') >= 0) throw e as Error;
      }
      if (needCopy) {
        let dir = destPath.substring(0, destPath.lastIndexOf('/'));
        try { fs.mkdirSync(dir, true); } catch (e) { /* exists */ }
        fs.copyFileSync(srcPath, destPath);
        count++;
      }
    } else {
      throw new Error('拒绝复制非普通文件: ' + srcPath);
    }
  }
  return count;
}

import { DiagnosticPolicy } from 'commons';
/**
 * MavenUtils.ets — Maven 坐标解析 + 库文件下载工具
 *
 * 将 Maven 坐标（如 "net.fabricmc:fabric-loader:0.16.10"）转换为：
 *   - 相对路径: net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar
 *   - 下载 URL: https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar
 *
 * 支持多 Maven 仓库镜像 + BMCLAPI 加速。
 */

import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BMCLAPI_BASE } from 'commons';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';
import { DownloadManager, DownloadTaskView } from '../download/DownloadManager';
import { buildSpecsForLibs, parseDoneEventToBatchResult } from './MavenSpecBuilder';
import { formatError } from 'commons';

const TAG = LogTags.MOD_MAVEN;

const CONNECT_TIMEOUT = 10000;
const READ_TIMEOUT = 30000;
const TOTAL_TIMEOUT = 60000;

// 远端元数据进入本地路径/网络层前的统一边界。只接受已经规范的正斜杠相对路径，
// 绝不尝试“修复”不可信输入，避免不同调用方产生不一致的路径语义。
const MAX_SAFE_SEGMENT_LENGTH = 255;
const MAX_SAFE_RELATIVE_PATH_LENGTH = 4096;
const MAX_SAFE_URL_LENGTH = 4096;

function containsControlCharacter(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    let code = value.charCodeAt(i);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

/** canonical 单文件名校验：拒绝分隔符、点段、盘符、NUL/控制字符和过长输入。 */
export function safeBaseName(name: string): string {
  if (name.length === 0 || name.length > MAX_SAFE_SEGMENT_LENGTH) return '';
  if (containsControlCharacter(name)) return '';
  if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) return '';
  if (name === '.' || name === '..' || /^[a-zA-Z]:/.test(name)) return '';
  return name;
}

/** canonical 相对路径校验：拒绝绝对/盘符/反斜杠/空段/点段/NUL/控制字符。 */
export function safeRelPath(path: string): string {
  if (path.length === 0 || path.length > MAX_SAFE_RELATIVE_PATH_LENGTH) return '';
  if (containsControlCharacter(path) || path.indexOf('\\') >= 0) return '';
  if (path.startsWith('/') || /^[a-zA-Z]:/.test(path)) return '';
  let segments = path.split('/');
  for (let segment of segments) {
    if (safeBaseName(segment).length === 0) return '';
  }
  return path;
}

/** 兼容旧调用名；新代码统一使用 safeBaseName。 */
export function safePathSegment(segment: string): string {
  return safeBaseName(segment);
}

/** 兼容旧调用名；新代码统一使用 safeRelPath。 */
export function safeRelativePath(path: string): string {
  return safeRelPath(path);
}

/** 下载调用层的基本 URL 校验：仅允许无控制/空白字符的 HTTP(S) 绝对 URL。 */
export function isSafeHttpUrl(url: string): boolean {
  if (url.length === 0 || url.length > MAX_SAFE_URL_LENGTH) return false;
  if (containsControlCharacter(url) || /\s/.test(url)) return false;
  return /^https?:\/\/[^\/?#]+(?:[\/?#].*)?$/.test(url);
}

export function isValidSha1(value: string): boolean {
  return /^[0-9a-fA-F]{40}$/.test(value);
}

// 默认 Maven 仓库列表 — 同时被 MavenSpecBuilder 复用，故 export
//
// 阿里云公共镜像置于最前：实测老 Forge（1.14 等）的通用依赖（guava/asm/gson/
// log4j/jsr305/commons-* 等）在 BMCLAPI /maven 与 /libraries 都会 302 到 USTC
// cernet 镜像（OHOS 设备不可达），而国外 forge maven / Maven Central 从设备又
// 慢又限流，导致引擎对这些库"no available sources (all failed)"提前放弃。阿里云
// public 仓库代理了 Central + jcenter，绝大多数通用库都能命中，是设备可达且快速
// 的国内源。少数 forge 私有 artifact（binarypatcher/installertools 等）仍由
// forge maven / BMCLAPI 兜底。
export const DEFAULT_MAVEN_REPOS: string[] = [
  'https://maven.aliyun.com/repository/public/',
  'https://maven.fabricmc.net/',
  'https://maven.minecraftforge.net/',
  'https://maven.neoforged.net/releases/',
  'https://libraries.minecraft.net/',
  'https://repo1.maven.org/maven2/',
];

// BMCLAPI Maven 镜像
export const BMCLAPI_MAVEN = BMCLAPI_BASE + '/maven/';

// BMCLAPI libraries 镜像（PCL2 同时用 /maven 与 /libraries 两个端点；二者命中/缓存策略
// 不同：/maven 对冷门 artifact 会 302 到 USTC cernet 镜像，而 /libraries 是 BMCLAPI 自己的
// 库镜像，往往不经该重定向。多一条不经 cernet 的路，提升老 Forge 冷门依赖的下载成功率）。
export const BMCLAPI_LIBRARIES = BMCLAPI_BASE + '/libraries/';

// ============================================================
//  maven-metadata.xml 版本列表（Forge / NeoForge 共享）
// ============================================================

/**
 * 解析 maven-metadata.xml 的 `<version>` 列表（保留原始顺序）。
 * 2026-06-28：从 ForgeService / NeoForgeService 各自一份收敛到此处（单一事实源）。
 */
export function parseMavenMetadataVersions(xml: string): string[] {
  let out: string[] = [];
  let re = /<version>([^<]+)<\/version>/g;
  let m = re.exec(xml);
  while (m !== null) { out.push(m[1]); m = re.exec(xml); }
  return out;
}

/**
 * 多镜像拉取 maven-metadata.xml 并合并去重（保留首次出现顺序）。返回空数组表示全部源失败
 * （由调用方决定缓存 / 抛错）。
 *
 * 共享策略（原 Forge/NeoForge 各写一份）：**官方源 + BMCLAPI 镜像都拉、合并去重**，
 * 不"首个非空即返回"——避免某镜像 metadata 落后时丢掉新版本（Forge 1.20.1 曾因此不可见）。
 */
export async function fetchMergedMavenVersions(urls: string[], label: string): Promise<string[]> {
  let merged: string[] = [];
  let mgr = DownloadManager.instance();
  for (let url of urls) {
    if (!isSafeHttpUrl(url)) {
      AppLogger.warn(TAG, `${label} metadata URL rejected`, null, LOG_DOMAIN_MODLOADER);
      continue;
    }
    try {
      let xml = await mgr.fetchText(url);
      let vers = parseMavenMetadataVersions(xml);
      if (vers.length > 0) {
        for (let v of vers) { if (merged.indexOf(v) < 0) merged.push(v); }
        AppLogger.info(TAG, `${label} metadata: url=${url} count=${vers.length}`, LOG_DOMAIN_MODLOADER);
      } else {
        AppLogger.warn(TAG, `${label} metadata empty: ${url}`, null, LOG_DOMAIN_MODLOADER);
      }
    } catch (e) {
      AppLogger.warn(TAG, `${label} metadata fetch failed: url=${url} err=${(e as Error).message}`, null, LOG_DOMAIN_MODLOADER);
    }
  }
  return merged;
}

// ============================================================
//  Maven 坐标解析
// ============================================================

export interface MavenCoordinate {
  groupId: string;       // "net.fabricmc"
  artifactId: string;    // "fabric-loader"
  version: string;       // "0.16.10"
  classifier?: string;   // 可选分类符（如 "sources"）
  extension: string;     // 文件扩展名，默认 "jar"
}

/**
 * 解析 Maven 坐标字符串
 * 支持格式：
 *   - "group:artifact:version"
 *   - "group:artifact:version:classifier"
 *   - "group:artifact:version:classifier@ext"
 *   - "group:artifact:version@ext"
 */
export function parseMavenName(name: string): MavenCoordinate | null {
  if (name.length === 0 || name.length > 1024 || containsControlCharacter(name)
      || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) return null;
  let ext = 'jar';
  let coordStr = name;

  // 检查 @extension（只允许一个 @，且 extension 必须是安全单段）
  let atIdx = name.indexOf('@');
  if (atIdx >= 0) {
    if (name.indexOf('@', atIdx + 1) >= 0) return null;
    ext = name.substring(atIdx + 1);
    coordStr = name.substring(0, atIdx);
  }

  let parts = coordStr.split(':');
  if (parts.length < 3 || parts.length > 4) return null;
  if (safeBaseName(ext).length === 0) return null;
  for (let part of parts) {
    if (safeBaseName(part).length === 0) return null;
  }
  let groupSegments = parts[0].split('.');
  for (let groupSegment of groupSegments) {
    if (safeBaseName(groupSegment).length === 0) return null;
  }

  let coord: MavenCoordinate = {
    groupId: parts[0],
    artifactId: parts[1],
    version: parts[2],
    extension: ext,
  };

  if (parts.length === 4) {
    coord.classifier = parts[3];
  }

  return coord;
}

/**
 * Maven 坐标 → 相对路径
 * 例: net.fabricmc:fabric-loader:0.16.10 → net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar
 */
export function mavenToRelativePath(name: string): string {
  let coord = parseMavenName(name);
  if (!coord) return '';

  let groupPath = coord.groupId.split('.').join('/');
  let fileName = coord.artifactId + '-' + coord.version;
  if (coord.classifier) {
    fileName += '-' + coord.classifier;
  }
  fileName += '.' + coord.extension;

  let relativePath = groupPath + '/' + coord.artifactId + '/' + coord.version + '/' + fileName;
  return safeRelPath(relativePath);
}

/**
 * Maven 坐标 → 完整下载 URL
 * @param name Maven 坐标
 * @param repoUrl Maven 仓库 URL（末尾带 /）
 */
export function mavenToUrl(name: string, repoUrl: string): string {
  let relPath = mavenToRelativePath(name);
  if (!relPath || !isSafeHttpUrl(repoUrl)) return '';
  let base = repoUrl.endsWith('/') ? repoUrl : repoUrl + '/';
  let url = base + relPath;
  return isSafeHttpUrl(url) ? url : '';
}

// ============================================================
//  库去重支撑（按 groupId:artifactId 去重，保留最高版本）
//
//  背景：原版 MC（如 1.21.6）和模组加载器（Fabric loader 0.19.2）可能各自声明
//  同一个 Maven 库的不同版本（实测 vanilla 1.21.6 自带 org.ow2.asm:asm:9.6，
//  Fabric 带 asm:9.9）。VersionJsonMerger 简单拼接两份 libraries 会让两个版本
//  同时进 classpath，Fabric loader 的 LoaderUtil.verifyClasspath 检测到重复 ASM
//  类直接抛 IllegalStateException 拒绝启动。
//
//  标准做法（HMCL MaintainTask.unique / PCL2 MergeJson / Modrinth daedalus）：
//  以 groupId:artifactId(:classifier) 为 key 去重，版本不同时**保留最高版本**
//  （等价于"用加载器版本替换/升级 vanilla 版本"，因为加载器版本通常更高）。
// ============================================================

/**
 * 比较两个 Maven 版本号字符串。返回 >0 表示 a>b，<0 表示 a<b，0 相等。
 *
 * 规则（覆盖 MC 生态实际出现的版本格式即可，非完整 Maven 规范）：
 *   - 以 '.' / '-' / '+' 切分为段
 *   - 两段都是纯数字 → 按数值比较（9 > 6，10 > 9）
 *   - 一段数字一段非数字 → 数字段视为更大（正式版 > 预览段）
 *   - 都非数字 → 字典序
 *   - 段缺失视为空字符串（如 9.9.1 > 9.9）
 */
export function compareMavenVersions(a: string, b: string): number {
  if (a === b) return 0;
  let pa = a.split(/[-.+]/);
  let pb = b.split(/[-.+]/);
  let n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    let sa = i < pa.length ? pa[i] : '';
    let sb = i < pb.length ? pb[i] : '';
    if (sa === sb) continue;
    let na = parseInt(sa, 10);
    let nb = parseInt(sb, 10);
    let aIsNum = sa.length > 0 && !isNaN(na) && String(na) === sa;
    let bIsNum = sb.length > 0 && !isNaN(nb) && String(nb) === sb;
    if (aIsNum && bIsNum) {
      if (na !== nb) return na > nb ? 1 : -1;
    } else if (aIsNum && !bIsNum) {
      return 1;
    } else if (!aIsNum && bIsNum) {
      return -1;
    } else {
      return sa < sb ? -1 : 1;
    }
  }
  return 0;
}

export interface LibraryGav {
  key: string;       // groupId:artifactId[:classifier]
  version: string;
}

/**
 * 从 Maven 布局的库文件路径解析 groupId:artifactId(:classifier) + version。
 *
 * 仅处理 `.../libraries/<group...>/<artifact>/<version>/<file>` 这种标准 Maven 布局；
 * 其它路径（MC 主 jar、lwjgl-ohos、stub-objc-bridge）返回 null，调用方不应对其去重。
 *
 * 例：.../libraries/org/ow2/asm/asm/9.6/asm-9.6.jar
 *     → { key: "org.ow2.asm:asm", version: "9.6" }
 */
export function parseLibraryPathGav(path: string): LibraryGav | null {
  let norm = path.replace(/\\/g, '/');
  let marker = '/libraries/';
  let idx = norm.indexOf(marker);
  if (idx < 0) return null;
  let rel = norm.substring(idx + marker.length);
  let segs = rel.split('/').filter((s: string) => s.length > 0);
  if (segs.length < 4) return null;
  let fileName = segs[segs.length - 1];
  let version = segs[segs.length - 2];
  let artifactId = segs[segs.length - 3];
  let groupId = segs.slice(0, segs.length - 3).join('.');
  if (groupId.length === 0 || artifactId.length === 0 || version.length === 0) return null;

  let key = groupId + ':' + artifactId;
  // classifier：文件名去掉 "<artifact>-<version>" 前缀和扩展名后剩下的部分（如 natives-linux）。
  // 带 classifier 的 native 库与主 jar 分到不同 key，避免被误删。
  let dot = fileName.lastIndexOf('.');
  let base = dot >= 0 ? fileName.substring(0, dot) : fileName;
  let prefix = artifactId + '-' + version;
  if (base.length > prefix.length + 1 && base.substring(0, prefix.length) === prefix
      && base.charAt(prefix.length) === '-') {
    let classifier = base.substring(prefix.length + 1);
    if (classifier.length > 0) key = key + ':' + classifier;
  }
  let result: LibraryGav = { key: key, version: version };
  return result;
}

// ============================================================
//  源测速探针（解决 BMCLAPI /maven 对 Forge 内容冷缓存、慢但不死，
//  引擎按 1KB/s 低速线判定为"可用"从不切换到更快镜像的问题）
// ============================================================

const PROBE_BYTES = 512 * 1024;     // 取前 512KB 测速，足以反映吞吐
const PROBE_TIMEOUT_MS = 8000;

/**
 * 探测某 URL 的下载速度（KB/s）。用 Range 只取前 512KB，超时/失败/非 2xx 返回 0。
 * 纯测速，不落盘。用于在 Forge 安装前选出对本机最快的源。
 */
export async function probeUrlSpeedKBps(url: string): Promise<number> {
  if (!isSafeHttpUrl(url)) return 0;
  return new Promise<number>((resolve: (v: number) => void) => {
    let req = http.createHttp();
    let started = Date.now();
    let settled = false;
    let finish = (v: number): void => {
      if (settled) return;
      settled = true;
      try { req.destroy(); } catch (e) { /* ignore */ }
      resolve(v);
    };
    let timer = setTimeout(() => { finish(0); }, PROBE_TIMEOUT_MS);
    req.request(url, {
      method: http.RequestMethod.GET,
      header: { 'Range': 'bytes=0-' + (PROBE_BYTES - 1) } as Record<string, string>,
      connectTimeout: 5000,
      readTimeout: PROBE_TIMEOUT_MS,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    }).then((resp: http.HttpResponse) => {
      clearTimeout(timer);
      let ms = Date.now() - started;
      let bytes = (resp.result instanceof ArrayBuffer) ? (resp.result as ArrayBuffer).byteLength : 0;
      let ok = (resp.responseCode === 200 || resp.responseCode === 206) && bytes > 0 && ms > 0;
      let kbps = ok ? Math.round(bytes / 1024 / (ms / 1000)) : 0;
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'probe %{public}s -> http=%{public}d bytes=%{public}d %{public}dms %{public}dKB/s',
        url, resp.responseCode, bytes, ms, kbps);
      finish(kbps);
    }).catch((e: Object) => {
      clearTimeout(timer);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'probe failed %{public}s: %{public}s', url, formatError(e));
      finish(0);
    });
  });
}

// ============================================================
//  库文件下载
// ============================================================

export interface LibDownloadResult {
  success: boolean;
  path: string;
  error?: string;
}

export interface MavenLibEntry {
  name: string;
  url?: string;
  sha1?: string;
  size?: number;
  // 部分 Forge"重定位"库（如 eventbus:1.0.0-service、accesstransformers:1.0.5-shadowed）的
  // **下载 URL 与本地存储路径不同**：坐标里的"版本"其实是带 classifier 的伪版本（用于 classpath
  // 定位），真实 artifact 在另一个 maven 路径（version=1.0.0, classifier=service）。Forge 官方
  // 安装器/PCL 都直接用 install_profile/version.json 里 downloads.artifact 显式给出的 url+path，
  // 不从坐标重构。下面两个字段承载这份显式信息：
  //   directUrl   — downloads.artifact.url，真实下载地址（完整 URL，非仓库根）
  //   storagePath — downloads.artifact.path，本地存储相对路径（classpath 据此定位）
  // 缺省（普通库 url 与坐标一致）时为 undefined，行为与旧逻辑完全一致。
  directUrl?: string;
  storagePath?: string;
}

export interface LibBatchDownloadResult {
  ok: number;
  failed: number;
  errors: string[];
  failedNames: string[];
}

/**
 * 下载单个 Maven 库到 libraries/ 目录
 * @param name Maven 坐标
 * @param repoUrl 优先使用的 Maven 仓库 URL
 * @param libDir libraries 根目录（如 .minecraft/libraries）
 * @returns 下载结果
 */
export async function downloadMavenLibrary(
  name: string, repoUrl: string | undefined, libDir: string,
  expectedSha1?: string, expectedSize?: number
): Promise<LibDownloadResult> {
  let relPath = mavenToRelativePath(name);
  if (!relPath) {
    let errResult: LibDownloadResult = { success: false, path: '', error: 'Invalid maven coordinate: ' + name };
    return errResult;
  }
  if (repoUrl !== undefined && !isSafeHttpUrl(repoUrl)) {
    return { success: false, path: '', error: 'Invalid maven repository URL' };
  }
  if (expectedSha1 !== undefined && expectedSha1.length > 0 && !isValidSha1(expectedSha1)) {
    return { success: false, path: '', error: 'Invalid SHA-1 for ' + name };
  }

  let destPath = libDir + '/' + relPath;

  // 已存在则跳过（校验 PK magic + 可选 SHA1，防止损坏文件永久残留）
  try {
    let stat = fs.statSync(destPath);
    if (stat.size > 0 && isValidJarFile(destPath)) {
      // 如果有期望 SHA1，校验一下
      if (expectedSha1 && isValidSha1(expectedSha1)) {
        let actual = await computeFileSha1(destPath);
        if (actual !== expectedSha1.toLowerCase()) {
          AppLogger.warn(TAG, `Existing file SHA1 mismatch, will re-download: ${name} (expected=${expectedSha1} actual=${actual})`, null, LOG_DOMAIN_MODLOADER);
          try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
        } else {
          return { success: true, path: destPath } as LibDownloadResult;
        }
      } else {
        return { success: true, path: destPath } as LibDownloadResult;
      }
    } else if (stat.size > 0) {
      // PK magic 不通过 → 删除重下
      AppLogger.warn(TAG, `Existing file invalid (bad magic), will re-download: ${name} (${stat.size} bytes)`, null, LOG_DOMAIN_MODLOADER);      try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
    } else {
      try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
    }
  } catch (e) { /* not exists */ }

  // 确保目录存在
  let destDir = destPath.substring(0, destPath.lastIndexOf('/'));
  try { fs.mkdirSync(destDir, true); } catch (e) { /* exists */ }

  // 构建下载 URL 列表（多源容错）
  let urls: string[] = [];

  // 1. BMCLAPI 镜像优先
  urls.push(BMCLAPI_MAVEN + relPath);

  // 2. 指定仓库
  if (repoUrl) {
    let repoCandidate = mavenToUrl(name, repoUrl);
    if (repoCandidate.length > 0 && urls.indexOf(repoCandidate) < 0) urls.push(repoCandidate);
  }

  // 3. 默认仓库列表
  for (let repo of DEFAULT_MAVEN_REPOS) {
    let url = mavenToUrl(name, repo);
    if (url.length > 0 && urls.indexOf(url) < 0) {
      urls.push(url);
    }
  }

  // 逐个尝试下载
  let lastErr = '';
  for (let url of urls) {
    try {
      await httpDownloadFile(url, destPath);
      // 验证文件大小 > 0 且是合法 JAR/ZIP（PK 头）
      let stat = fs.statSync(destPath);
      if (stat.size > 0) {
        if (!isValidJarFile(destPath)) {
          AppLogger.warn(TAG, `Downloaded file is not a valid JAR (bad magic), discarding: ${name} from ${url} (${stat.size} bytes)`, null, LOG_DOMAIN_MODLOADER);
          try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
          lastErr = 'Not a valid JAR file (CDN error page?) from ' + url;
          continue;
        }
        // BUG-2 fix: 可选 size + SHA1 校验
        if (expectedSize && expectedSize > 0 && stat.size !== expectedSize) {
          AppLogger.warn(TAG, `Size mismatch: ${name} from ${url} (expected=${expectedSize} actual=${stat.size})`, null, LOG_DOMAIN_MODLOADER);
          try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
          lastErr = 'Size mismatch from ' + url;
          continue;
        }
        if (expectedSha1 && isValidSha1(expectedSha1)) {
          let actual = await computeFileSha1(destPath);
          if (actual !== expectedSha1.toLowerCase()) {
            AppLogger.warn(TAG, `SHA1 mismatch: ${name} from ${url} (expected=${expectedSha1} actual=${actual})`, null, LOG_DOMAIN_MODLOADER);
            try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
            lastErr = 'SHA1 mismatch from ' + url;
            continue;
          }
        }
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'Downloaded: %{public}s (%{public}d bytes)', name, stat.size);
        let okResult: LibDownloadResult = { success: true, path: destPath };
        return okResult;
      }
      // 空文件，删除后尝试下一个源
      try { fs.unlinkSync(destPath); } catch (e) { /* ignore */ }
    } catch (e) {
      lastErr = (e as Error).message || String(e);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'Failed from %{public}s: %{public}s', url, lastErr);
      try { fs.unlinkSync(destPath); } catch (e2) { /* ignore */ }
    }
  }

  let failResult: LibDownloadResult = { success: false, path: destPath, error: 'All sources failed for ' + name + ': ' + lastErr };
  return failResult;
}

/**
 * 批量下载 Maven 库
 *
 * Phase 1.5（ARCH-1，2026-05-05）：从 ArkTS HTTP 顺序下载迁移到 NAPI 引擎。
 *
 * 现在的行为：
 *   - 用 buildSpecsForLibs 把 libs 转成 DownloadFileSpec[]
 *   - 走 DownloadManager.createAndWait（C++ 引擎 64 并发 + 多源 fallback +
 *     断点续传 + 坏主机黑名单 + 引擎层 sha1/size 校验）
 *   - 用 parseDoneEventToBatchResult 把完成事件转回 LibBatchDownloadResult
 *
 * 接口契约保持 100% 向后兼容：onProgress 签名、LibBatchDownloadResult 字段
 * 不变。Forge / Fabric 调用方零改动。
 *
 * 异常路径 fallback：DownloadManager 抛异常（如 CA bundle 未初始化）时，
 * 退回到老的 ArkTS HTTP 顺序下载（保留 downloadMavenLibrary 单库实现）。
 * 这避免了引擎初始化失败导致整个 Forge 安装失败。
 */
/**
 * A-01 修复（2026-07-29）：从上一轮结果里挑出**仅失败**的库，供重试使用。
 *
 * 背景：ForgelikeInstaller / ForgeService 的「第一轮有失败就重试」过去把**完整原始列表**
 * 再提交一遍。旧版 Forge 与 Fabric 的库条目没有 `downloads.artifact`，
 * `ForgeInstallerUtils` 因此不填 sha1/size，`buildSpecForLib` 就不带 check；而 native 侧
 * 对「无 checker 且目标已存在」的文件在提交阶段会拒绝（N-01）。于是第二轮重下第一轮
 * **已成功落地**的库时逐个必然失败 → `r2.failed > 0` 恒成立 → 整个加载器安装被判失败，
 * 且装过一次后磁盘上就有这些库，此后第一轮就必失败，形成永久闭环。
 *
 * N-01 已在 native 侧改为原子替换提交，本函数进一步消除无意义的重复下载：
 * 重试只针对真正失败的坐标，既省流量，也不再让成功项参与二次判定。
 *
 * @returns `result.failedNames` 命中的库子集；顺序与 `libs` 一致。空数组表示无需重试。
 */
export function selectFailedLibs(
  libs: MavenLibEntry[], result: LibBatchDownloadResult
): MavenLibEntry[] {
  let failedNames = result.failedNames;
  if (failedNames === undefined || failedNames.length === 0) return [];
  let wanted: Set<string> = new Set<string>();
  for (let n of failedNames) wanted.add(n);
  let subset: MavenLibEntry[] = [];
  for (let lib of libs) {
    if (wanted.has(lib.name)) subset.push(lib);
  }
  return subset;
}

/**
 * 批量下载依赖库的进度回调。
 *
 * @param done     已完成的**文件数**（用于 "(3/28)" 这类文案）
 * @param total    文件总数
 * @param name     当前文件名
 * @param fraction 2026-07-30 新增：**字节加权**完成比例（0~1）；字节总量未知时为 -1，
 *                 调用方应回退到 `done / total`。
 *
 * 为什么要多这一个参数：真机实测（hdc，2026-07-30 20:58:46~21:00:10）28 个 NeoForge
 * 依赖库里 27 个在 14s 内完成，剩下 6.98MB 的 `neoforge-…-universal.jar` 单独跑了 84s。
 * 纯文件计数会让进度停在 27/28 静止 84 秒，用户看到的就是"卡在模组依赖库上"。
 * 字节加权能让进度条在这 84 秒里持续推进。
 */
export type MavenLibsProgressCallback =
  (done: number, total: number, name: string, fraction: number) => void;

export async function downloadMavenLibraries(
  libs: MavenLibEntry[],
  libDir: string,
  onProgress?: MavenLibsProgressCallback,
  preferRealSource: boolean = false
): Promise<LibBatchDownloadResult> {
  if (libs.length === 0) {
    return { ok: 0, failed: 0, errors: [], failedNames: [] };
  }

  // 1. 构造 specs（纯函数，可测试）。preferRealSource=true 时把各库的真实仓库
  //    （maven central / forge maven）排到 BMCLAPI 前面——用于本机实测 BMCLAPI
  //    /maven 代理对 Forge 内容明显更慢的场景（见 probeUrlSpeedKBps）。
  let buildResult = buildSpecsForLibs(libs, libDir, preferRealSource);

  // 2. 走 DownloadManager.createAndWait
  if (buildResult.specs.length > 0) {
    let mgr = DownloadManager.instance();
    if (!mgr.isCaBundleInitialized()) {
      // CA bundle 未初始化 — 引擎走不通，回退到旧逻辑
      AppLogger.warn(TAG, `CA bundle not initialized, falling back to ArkTS HTTP for ${libs.length} libraries`, null, LOG_DOMAIN_MODLOADER);
      return await downloadMavenLibrariesLegacy(libs, libDir, onProgress);
    }

    try {
      let view = await mgr.createAndWait({
        name: 'Maven libraries (' + buildResult.specs.length + ')',
        files: buildResult.specs,
      }, (v: DownloadTaskView): void => {
        if (onProgress !== undefined) {
          let name = v.currentFiles.length > 0 ? v.currentFiles[0] : v.currentFile;
          // 字节加权优先；bytesTotal 尚未确定（首个响应前）时给 -1 让调用方回退文件计数。
          let fraction = -1;
          if (v.bytesTotal > 0) {
            fraction = v.bytesDone / v.bytesTotal;
            if (fraction < 0) fraction = 0;
            if (fraction > 1) fraction = 1;
          }
          onProgress(v.filesDone, v.filesTotal, name, fraction);
        }
      });
      // 3. 把 view 转回 LibBatchDownloadResult
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      // 把 buildSpecsForLibs 报告的非法坐标合并到失败结果
      for (let n of buildResult.invalidNames) {
        if (result.failedNames.indexOf(n) >= 0) continue;
        result.failed++;
        result.failedNames.push(n);
        result.errors.push(n + ': invalid maven coordinate');
      }
      // ok 不能因非法坐标膨胀（合法 specs 已经计入 ok 了，非法的本就不在 libs 路径里）
      let durMs = view.durationMs;
      let kbps = durMs > 0 ? Math.round(view.bytesDone / 1024 / (durMs / 1000)) : 0;
      AppLogger.info(TAG, `downloadMavenLibraries via NAPI: ok=${result.ok} failed=${result.failed} bytes=${view.bytesDone} durMs=${durMs} KBps=${kbps} (success=${view.success ? 'true' : 'false'})`, LOG_DOMAIN_MODLOADER);
      return result;
    } catch (e) {
      let msg = (e as Error).message || formatError(e);
      // 引擎抛异常（如 cancelAndAwait 路径被外部触发，或 NAPI 层错误）
      // 这里不做重试，直接归报为全部失败 — 调用方会展示给用户
      AppLogger.error(TAG, `downloadMavenLibraries via NAPI threw: ${msg}`, null, LOG_DOMAIN_MODLOADER);
      let failedNames: string[] = [];
      let errors: string[] = [];
      for (let lib of libs) {
        failedNames.push(lib.name);
        errors.push(lib.name + ': ' + msg);
      }
      return { ok: 0, failed: libs.length, errors: errors, failedNames: failedNames };
    }
  }

  // 全部坐标非法（buildResult.specs 为空）
  let allInvalidErrors: string[] = [];
  for (let n of buildResult.invalidNames) {
    allInvalidErrors.push(n + ': invalid maven coordinate');
  }
  return {
    ok: 0,
    failed: buildResult.invalidNames.length,
    errors: allInvalidErrors,
    failedNames: buildResult.invalidNames,
  };
}

/**
 * 向后兼容的 fallback：当 DownloadManager 不可用时（CA bundle 未抽取等极端场景），
 * 用老的 ArkTS HTTP 顺序下载维持基础可用性。
 *
 * 不应在常规路径走到这里 — 走到说明 EntryAbility.onCreate 没正确初始化 CA bundle。
 */
async function downloadMavenLibrariesLegacy(
  libs: MavenLibEntry[],
  libDir: string,
  onProgress?: MavenLibsProgressCallback
): Promise<LibBatchDownloadResult> {
  let ok = 0;
  let failed = 0;
  let errors: string[] = [];
  let failedNames: string[] = [];

  for (let i = 0; i < libs.length; i++) {
    let lib = libs[i];
    if (onProgress) {
      // legacy 顺序下载没有字节总量 → fraction=-1，调用方回退文件计数。
      onProgress(i, libs.length, lib.name, -1);
    }

    let result = await downloadMavenLibrary(lib.name, lib.url, libDir, lib.sha1, lib.size);
    if (result.success) {
      ok++;
    } else {
      failed++;
      failedNames.push(lib.name);
      if (result.error) errors.push(lib.name + ': ' + result.error);
      AppLogger.warn(TAG, `Library download failed (legacy): ${lib.name}`, null, LOG_DOMAIN_MODLOADER);
    }
  }

  if (onProgress) {
    onProgress(libs.length, libs.length, 'done', 1);
  }

  let batchResult: LibBatchDownloadResult = { ok, failed, errors, failedNames };
  return batchResult;
}

// ============================================================
//  JAR 文件校验
// ============================================================

/**
 * 检查文件是否为合法 JAR（ZIP 格式）：读取开头 4 字节检查 PK magic。
 * JAR/ZIP 文件开头必须是 PK\x03\x04（local file header）或 PK\x05\x06（空 archive）。
 * CDN 错误页（HTML/XML）通常以 '<' 或 '{' 开头，会被正确拒绝。
 */
function isValidJarFile(path: string): boolean {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(4);
    let bytesRead = fs.readSync(file.fd, buf, { offset: 0, length: 4 });
    fs.closeSync(file);
    file = null;
    if (bytesRead < 4) return false;
    let header = new Uint8Array(buf);
    // PK\x03\x04 = local file header, PK\x05\x06 = empty archive EOCD
    if (!(header[0] === 0x50 && header[1] === 0x4B
      && ((header[2] === 0x03 && header[3] === 0x04)
        || (header[2] === 0x05 && header[3] === 0x06)))) {
      return false;
    }
    return hasValidZipEocd(path);
  } catch (e) {
    if (file) { try { fs.closeSync(file); } catch (e2) { /* */ } }
    return false;
  }
}

/**
 * 检查 ZIP 文件末尾是否有合法的 End of Central Directory 签名（0x06054b50）。
 * 参考 HMCL ZIP_INTEGRITY_CHECK_HANDLER: 拦截 CDN 错误页和传输截断文件。
 */
function hasValidZipEocd(path: string): boolean {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let stat = fs.statSync(path);
    if (stat.size < 22) { fs.closeSync(file); file = null; return false; }
    let searchLen = Math.min(stat.size, 65557);
    let buf = new ArrayBuffer(searchLen);
    fs.readSync(file.fd, buf, { offset: stat.size - searchLen, length: searchLen });
    fs.closeSync(file);
    file = null;
    let view = new Uint8Array(buf);
    for (let i = view.length - 22; i >= 0; i--) {
      if (view[i] === 0x50 && view[i + 1] === 0x4B
          && view[i + 2] === 0x05 && view[i + 3] === 0x06) {
        return true;
      }
    }
    return false;
  } catch (e) {
    if (file) { try { fs.closeSync(file); } catch (e2) { /* */ } }
    return false;
  }
}

const HASH_CHUNK_SIZE = 256 * 1024;

/**
 * 计算文件 SHA1 哈希值（hex 小写）。
 *
 * 工程注意：本函数曾在 ForgeService 内重复实现一份（D5-3，self-inspection 报告），
 * 2026-05-06 收敛到这里 — Forge installer.jar 校验 / Maven 库校验都用这一份。
 * 直读 256KB 块；异常直接抛（cryptoFramework / fileIo 原生消息），调用方按需包装。
 */
// 2026-05-23 ArkTS 严格模式：cryptoFramework.createMd / fs.openSync / readSync /
// updateSync / closeSync / digestSync 都报 'Function may throw'。整体包一层
// try-catch + log + rethrow。详见 docs/guides/api-migration-2026-05.md。
export async function computeFileSha1(path: string): Promise<string> {
  let file: fs.File | null = null;
  try {
    let md = cryptoFramework.createMd('SHA1');
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let buffer = new ArrayBuffer(HASH_CHUNK_SIZE);
    while (true) {
      let n = fs.readSync(file.fd, buffer);
      if (n <= 0) break;
      let chunk: cryptoFramework.DataBlob = { data: new Uint8Array(buffer, 0, n) };
      md.updateSync(chunk);
    }
    let digest = md.digestSync();
    let hex = '';
    for (let i = 0; i < digest.data.length; i++) {
      let b = digest.data[i];
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    return hex;
  } catch (e) {
    AppLogger.warn(TAG, `computeFileSha1 ${path} failed`, e, LOG_DOMAIN_MODLOADER);
    throw e as Error;
  } finally {
    if (file) {
      try { fs.closeSync(file); } catch (_) { /* ignore */ }
    }
  }
}

// ============================================================
//  HTTP 下载工具
// ============================================================

function httpDownloadFile(url: string, destPath: string): Promise<void> {
  if (!isSafeHttpUrl(url)) return Promise.reject(new Error('Unsafe download URL rejected'));
  return new Promise<void>((resolve: Function, reject: Function) => {
    // 删除旧文件
    try { fs.unlinkSync(destPath); } catch (e) { /* ignore */ }

    let httpRequest = http.createHttp();
    let done = false;
    let timer = setTimeout(() => {
      if (!done) {
        done = true;
        try { httpRequest.destroy(); } catch (e) { /* ignore */ }
        reject(new Error('Timeout: ' + url));
      }
    }, TOTAL_TIMEOUT);

    httpRequest.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: CONNECT_TIMEOUT,
      readTimeout: READ_TIMEOUT,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    }).then((resp) => {
      if (done) return;
      done = true;
      clearTimeout(timer);

      if (resp.responseCode !== 200) {
        try { httpRequest.destroy(); } catch (e) { /* ignore */ }
        reject(new Error('HTTP ' + resp.responseCode + ' for ' + url));
        return;
      }

      let data = resp.result as ArrayBuffer;
      let file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
      try { httpRequest.destroy(); } catch (e) { /* ignore */ }
      resolve();
    }).catch((e: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { httpRequest.destroy(); } catch (e2) { /* ignore */ }
      reject(e);
    });
  });
}

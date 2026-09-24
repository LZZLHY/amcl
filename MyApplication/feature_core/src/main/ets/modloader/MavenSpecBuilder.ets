/**
 * MavenSpecBuilder.ets — Maven 库 → DownloadFileSpec 转换器（Phase 1, ARCH-1）
 *
 * 职责：把 Forge / Fabric 安装时拉到的 Maven 坐标列表转成 DownloadManager 所需的
 * DownloadFileSpec[]，让依赖库下载走 NAPI 引擎（享受 64 并发 + 多源 fallback +
 * 断点续传 + 坏主机黑名单）。
 *
 * 当前状态（Phase 1.4 已完成）：buildMavenUrls / buildSpecForLib / buildSpecsForLibs +
 * parseDoneEventToBatchResult 全部就绪；MavenUtils.downloadMavenLibraries 通过
 * DownloadManager.createAndWait 委托到 NAPI 引擎，已替换原 ArkTS HTTP 顺序下载。
 *
 * 设计要点：
 *   - 多源 URL 顺序：BMCLAPI 优先 → directUrl → repoHint → 兜底仓库（去重）
 *   - 镜像相对路径统一归一化为**纯坐标路径**（剥掉 `/releases/`、`/maven2/` 这类
 *     仓库路径前缀），否则 BMCLAPI 镜像 URL 恒 404 —— 详见 KNOWN_MAVEN_REPO_BASES
 *   - 加载器自有 group（neoforged / minecraftforge / fabricmc / quiltmc）不追加
 *     通用仓库，只留它自己的上游 —— 详见 LOADER_OWNED_GROUP_PREFIXES
 *   - sha1 仅在长度 === 40 时写入 check（与 MavenUtils 现有约束一致）
 *   - size 仅在 > 0 时写入 check
 *   - libDir 末尾斜杠规范化，避免双斜杠 //
 *   - 纯函数：零 I/O、零 NAPI 调用，可在 localUnit 跑
 *
 * 测试：entry/src/test/MavenSpecBuilder.test.ets
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 1
 *
 * 创建日期：2026-05-05
 */

import { DownloadFileSpec, DownloadCheck, DownloadTaskView } from '../download/DownloadManager';
import {
  MavenLibEntry,
  LibBatchDownloadResult,
  parseMavenName,
  mavenToRelativePath,
  safeRelPath,
  isSafeHttpUrl,
  isValidSha1,
  DEFAULT_MAVEN_REPOS,
  BMCLAPI_MAVEN,
  BMCLAPI_LIBRARIES,
} from './MavenUtils';

// ============================================================
//  公开 interface
// ============================================================

/** buildSpecsForLibs 的返回结果 */
export interface MavenSpecResult {
  /** 合法的 lib → 对应 DownloadFileSpec */
  specs: DownloadFileSpec[];
  /** 非法 / 无法解析的 Maven 坐标 */
  invalidNames: string[];
  /** localPath → 原始 Maven 坐标，供 parseDoneEventToBatchResult 反查失败 lib name */
  pathToName: Map<string, string>;
}

// ============================================================
//  内部工具
// ============================================================

/** 规范化目录路径：末尾不含 '/'，方便后续统一拼接 '/' + relPath */
function normalizeDir(dir: string): string {
  let normalized = dir;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

function pushSafeUrl(urls: string[], url: string): void {
  if (isSafeHttpUrl(url) && urls.indexOf(url) < 0) urls.push(url);
}

// ============================================================
//  公开函数
// ============================================================

/**
 * 已知 Maven 仓库根（含**路径前缀**）。用于把 `downloads.artifact.url` 归一化成
 * 纯 Maven 坐标相对路径（`net/neoforged/...`），再拿去拼各镜像。
 *
 * ⚠️ 2026-07-30 修复（NeoForge 依赖库必然绕开国内镜像的根因）
 *
 * 旧实现只剥 `scheme://host/`，于是 NeoForge 的
 *   https://maven.neoforged.net/releases/net/neoforged/fancymodloader/loader/11.0.13/loader-11.0.13.jar
 * 被剥成 `releases/net/neoforged/...`，拼上 BMCLAPI 得到
 *   https://bmclapi2.bangbang93.com/maven/releases/net/neoforged/...      → 恒 404
 *   https://bmclapi2.bangbang93.com/libraries/releases/net/neoforged/...  → 恒 404
 * 而 repoHint（`https://maven.neoforged.net/releases/`）再拼一次还会造出
 *   https://maven.neoforged.net/releases/releases/net/neoforged/...       → 恒 404
 *
 * 真机取证（hdc，2026-07-30 20:58:46~21:00:10，版本 26.2-neoforge-26.2.0.40-beta）：
 * 8 个 NeoForge 制品 × 2 个 BMCLAPI 端点 = 16 次必然 404，全部回退到
 * maven.neoforged.net（新加坡 CDN77，单连接实测 15~52KB/s 且反复 Connection reset
 * by peer），28 个依赖库 12.15MB 耗时 84.8s（140KB/s），其中 6.98MB 的
 * universal.jar 单独占 84s。逐条复核 BMCLAPI 正确路径：7/8 制品返回 200
 * （loader / earlydisplay / accesstransformers / at-parser / JarJarMetadata /
 * JarJarSelector / mergetool），仅 `26.2.0.40-beta` 这个 beta 的 universal.jar
 * 确实未被镜像收录（已发布版本如 21.1.9 / 21.1.209 的 universal.jar 均为 200）。
 *
 * PCL2 的做法（`Modules/Minecraft/ModMinecraft.vb` McLibNetFilesFromTokens）正是
 * 显式剥掉这段路径前缀：
 *   .Replace("maven.neoforged.net/releases", "maven")
 *   .Replace("maven.minecraftforge.net", "maven")
 *   .Replace("maven.fabricmc.net", "maven")
 * 这里取同样语义，但用**完整仓库根白名单 + 最长匹配**而不是字符串替换：
 * 未在白名单里的主机（用户自建仓库、整合包私有源）不猜它的布局，沿用旧的
 * "只剥 host" 行为，避免误伤重定位库。
 *
 * ⚠️ 必须**延迟构建**，不能写成模块级数组字面量。
 *   本文件与 MavenUtils 是**循环 import**（MavenUtils 导入 buildSpecsForLibs /
 *   parseDoneEventToBatchResult，本文件导入 BMCLAPI_MAVEN / DEFAULT_MAVEN_REPOS 等）。
 *   模块级初始化器在加载期求值，循环下 MavenUtils 的 `export const BMCLAPI_MAVEN`
 *   可能仍处于 TDZ →
 *     E ArkCompiler: ReferenceError: BMCLAPI_MAVEN is not initialized
 *   而 feature_core 在启动链里被引入，于是**整个应用起不来**（2026-07-30 真机实测，
 *   jscrash-com.amcl.launcher-*.log）。放进函数体内首次调用时才解引用即可规避。
 */
let knownMavenRepoBases_: string[] | null = null;

function knownMavenRepoBases(): string[] {
  if (knownMavenRepoBases_ === null) {
    knownMavenRepoBases_ = [
      'https://maven.neoforged.net/releases/',
      'https://maven.quiltmc.org/repository/release/',
      'https://maven.aliyun.com/repository/public/',
      'https://repo.maven.apache.org/maven2/',
      'https://repo1.maven.org/maven2/',
      'https://files.minecraftforge.net/maven/',
      'https://maven.minecraftforge.net/',
      'https://maven.fabricmc.net/',
      'https://maven.neoforged.net/',
      'https://libraries.minecraft.net/',
      BMCLAPI_MAVEN,
      BMCLAPI_LIBRARIES,
    ];
  }
  return knownMavenRepoBases_;
}

/**
 * 加载器"自有"制品所属的 group 前缀 → 它唯一的真实上游仓库。
 *
 * 这些 group 只存在于对应加载器的 Maven，把 Central / 阿里云 / Mojang libraries
 * 拼进候选链是纯浪费：每条都要付一次 DNS+TLS+404 往返。真机日志里单个 NeoForge 库
 * 的候选链有 2 条 BMCLAPI(404) + 1 条可用 + 6 条恒 404。
 *
 * PCL2 用的是同一条规则（`ModDownload.vb` DlSourceLibraryGet）：
 *   If {"minecraftforge", "fabricmc", "neoforged"}.Any(Function(k) Original.Contains(k)) Then '不添加原版源
 * 差别是我们额外保留该加载器自己的仓库作为兜底（PCL2 那条分支只留两个 BMCLAPI 端点），
 * 这样"BMCLAPI 尚未收录新版本"时仍有真实上游可走 —— 正是本次 beta 的情形。
 *
 * ⚠️ 只收敛加载器自有 group。老 Forge 的通用依赖（com/google、org/ow2/asm、
 * org/apache/logging 等）不在此列，仍走完整 DEFAULT_MAVEN_REPOS —— 阿里云优先那条
 * 结论（BMCLAPI 对冷门 artifact 会 302 到设备不可达的 USTC cernet）必须保留。
 */
const LOADER_OWNED_GROUP_PREFIXES: string[] = [
  'net/neoforged/',
  'net/minecraftforge/',
  'net/fabricmc/',
  'org/quiltmc/',
];
const LOADER_OWNED_GROUP_REPOS: string[] = [
  'https://maven.neoforged.net/releases/',
  'https://maven.minecraftforge.net/',
  'https://maven.fabricmc.net/',
  'https://maven.quiltmc.org/repository/release/',
];

/** 命中加载器自有 group 时返回它唯一的上游仓库根，否则返回空串。 */
function loaderOwnedRepo(relPath: string): string {
  for (let i = 0; i < LOADER_OWNED_GROUP_PREFIXES.length; i++) {
    if (relPath.startsWith(LOADER_OWNED_GROUP_PREFIXES[i])) return LOADER_OWNED_GROUP_REPOS[i];
  }
  return '';
}

/** 剥掉已知仓库根（最长匹配）。未命中返回空串。 */
function stripKnownRepoBase(url: string): string {
  let best = '';
  for (let base of knownMavenRepoBases()) {
    if (base.length > best.length && url.startsWith(base)) best = base;
  }
  return best.length > 0 ? url.substring(best.length) : '';
}

/**
 * 从完整 URL 提取可用于**拼接其它镜像**的 Maven 相对路径。
 * 用于把 Forge / NeoForge 显式 directUrl 的真实路径套到各镜像上。解析失败返回空串。
 *
 * 已知仓库根 → 连路径前缀一起剥（`/releases/`、`/maven2/`、`/repository/public/` …）；
 * 未知主机 → 只剥 `scheme://host/`（旧行为，保持兼容）。
 */
function relPathFromUrl(url: string): string {
  if (!isSafeHttpUrl(url)) return '';
  let clean = url;
  let qIdx = clean.indexOf('?');
  if (qIdx >= 0) clean = clean.substring(0, qIdx);
  let hIdx = clean.indexOf('#');
  if (hIdx >= 0) clean = clean.substring(0, hIdx);
  let stripped = stripKnownRepoBase(clean);
  if (stripped.length > 0) return safeRelPath(stripped);
  let m = clean.match(/^https?:\/\/[^/]+\/(.*)$/);
  if (m === null || m.length < 2) return '';
  return safeRelPath(m[1]);
}

/**
 * 构造单个 Maven 坐标的多源 URL 列表。
 * 顺序：[BMCLAPI /maven + /libraries] → [directUrl] → [repoHint] → [兜底仓库（去重）]
 * 兜底仓库：加载器自有 group 只取它自己的上游，其余用 DEFAULT_MAVEN_REPOS。
 * 非法坐标返回空数组。
 *
 * directUrl（Forge downloads.artifact.url，真实下载地址）若给出且其路径与坐标重构路径
 * 不同（重定位库，如 eventbus:1.0.0-service 真实在 .../1.0.0/eventbus-1.0.0-service.jar），
 * 则**以 directUrl 的真实路径为准**套各镜像 + 保证 directUrl 本身在候选里——否则坐标重构
 * 路径在所有源 404。
 */
export function buildMavenUrls(
  coordinate: string, repoHint: string | undefined, preferRealSource: boolean = false,
  directUrl?: string
): string[] {
  let coord = parseMavenName(coordinate);
  if (coord === null) return [];

  let relPath = safeRelPath(mavenToRelativePath(coordinate));
  if (relPath.length === 0) return [];

  // directUrl 的真实路径（可能与坐标重构路径不同 = 重定位库）。仅可信 HTTP(S) URL
  // 且其路径通过严格相对路径校验时，才允许拿来构造镜像 URL。
  let safeDirectUrl = (directUrl !== undefined && isSafeHttpUrl(directUrl)) ? directUrl : '';
  let directRel = safeDirectUrl.length > 0 ? relPathFromUrl(safeDirectUrl) : '';
  let mirrorRel = directRel.length > 0 ? directRel : relPath;

  let bmclapiUrl = BMCLAPI_MAVEN + mirrorRel;
  let bmclapiLibUrl = BMCLAPI_LIBRARIES + mirrorRel;
  let urls: string[] = [];

  // repoHint（库自身声明的真实仓库，如 maven central / forge maven）
  let hintUrl: string = '';
  if (repoHint !== undefined && isSafeHttpUrl(repoHint)) {
    let base = repoHint.endsWith('/') ? repoHint : repoHint + '/';
    let candidate = base + mirrorRel;
    if (isSafeHttpUrl(candidate)) hintUrl = candidate;
  }

  // 2026-07-30：加载器自有 group 只保留"它自己的上游仓库"作为兜底，其余通用仓库
  // 对这些坐标恒 404（见 LOADER_OWNED_GROUP_PREFIXES 注释）。
  let ownerRepo = loaderOwnedRepo(mirrorRel);
  let fallbackRepos: string[] = ownerRepo.length > 0 ? [ownerRepo] : DEFAULT_MAVEN_REPOS;

  if (preferRealSource) {
    pushSafeUrl(urls, safeDirectUrl);
    pushSafeUrl(urls, hintUrl);
    for (let repo of fallbackRepos) {
      let base = repo.endsWith('/') ? repo : repo + '/';
      pushSafeUrl(urls, base + mirrorRel);
    }
    pushSafeUrl(urls, bmclapiUrl);
    pushSafeUrl(urls, bmclapiLibUrl);
  } else {
    pushSafeUrl(urls, bmclapiUrl);
    pushSafeUrl(urls, bmclapiLibUrl);
    pushSafeUrl(urls, safeDirectUrl);
    pushSafeUrl(urls, hintUrl);
    for (let repo of fallbackRepos) {
      let base = repo.endsWith('/') ? repo : repo + '/';
      pushSafeUrl(urls, base + mirrorRel);
    }
  }

  return urls;
}

/**
 * 单个 lib → DownloadFileSpec。
 * - localPath = libDir + '/' + relPath（自动规范斜杠）
 * - urls 走 buildMavenUrls
 * - check.sha1：仅在 expectedSha1 为 40 位十六进制时写入（保持与 MavenUtils 一致约束）
 * - check.size：仅在 expectedSize > 0 时写入
 * 非法坐标返回 null。
 */
export function buildSpecForLib(
  lib: MavenLibEntry, libDir: string, preferRealSource: boolean = false
): DownloadFileSpec | null {
  // 本地存储路径：优先用 Forge 显式 storagePath（重定位库的 classpath 据此定位），
  // 否则从坐标重构。
  let relPath = (lib.storagePath !== undefined && lib.storagePath.length > 0)
    ? safeRelPath(lib.storagePath)
    : safeRelPath(mavenToRelativePath(lib.name));
  if (relPath.length === 0) return null;

  let urls = buildMavenUrls(lib.name, lib.url, preferRealSource, lib.directUrl);
  if (urls.length === 0) return null;

  let normalizedDir = normalizeDir(libDir);
  if (normalizedDir.length === 0) return null;
  let localPath = normalizedDir + '/' + relPath;

  // 构造 check（仅在合法值时填充）
  let check: DownloadCheck | undefined = undefined;
  let hasSha1 = lib.sha1 !== undefined && isValidSha1(lib.sha1);
  let hasSize = lib.size !== undefined && lib.size > 0;
  if (hasSha1 || hasSize) {
    let c: DownloadCheck = {};
    if (hasSha1) c.sha1 = lib.sha1;
    if (hasSize) c.size = lib.size;
    check = c;
  }

  let spec: DownloadFileSpec = {
    localPath: localPath,
    urls: urls,
    allowedRoot: normalizedDir,
  };
  if (check !== undefined) spec.check = check;
  return spec;
}

/**
 * 批量构造 specs；非法坐标分离到 invalidNames，pathToName 反查映射用于
 * 失败回报阶段把 localPath 转回原始 Maven 坐标。
 */
export function buildSpecsForLibs(
  libs: MavenLibEntry[], libDir: string, preferRealSource: boolean = false
): MavenSpecResult {
  let specs: DownloadFileSpec[] = [];
  let invalidNames: string[] = [];
  let pathToName: Map<string, string> = new Map<string, string>();
  let seenPaths: Set<string> = new Set<string>();

  for (let lib of libs) {
    let spec = buildSpecForLib(lib, libDir, preferRealSource);
    if (spec === null) {
      invalidNames.push(lib.name);
      continue;
    }
    // 同一目标只提交一次，避免同一 task 内多个 NetFile 并发截断/写入同一路径。
    if (seenPaths.has(spec.localPath)) continue;
    seenPaths.add(spec.localPath);
    specs.push(spec);
    pathToName.set(spec.localPath, lib.name);
  }

  let result: MavenSpecResult = {
    specs: specs,
    invalidNames: invalidNames,
    pathToName: pathToName,
  };
  return result;
}

/**
 * 把 DownloadManager 完成事件转回 LibBatchDownloadResult（保持向后兼容）。
 *
 * 行为约定：
 *   - libs.length === 0：直接返回空结果（无失败、无错误）
 *   - view.success === true 且 failedFiles 空：全部计入 ok
 *   - 有 failedFiles：对每个 failedFile，反查 pathToName 拿原始 lib name；
 *     未在 pathToName 的（防御性，不应发生）跳过不计入
 *   - view.success === false 但 failedFiles 空（如 CA bundle 未初始化等任务级失败）：
 *     全部 lib 视为失败，错误信息走 view.errorMessage
 *   - ok = libs.length - failed（保证 ok + failed <= libs.length）
 */
export function parseDoneEventToBatchResult(
  view: DownloadTaskView,
  libs: MavenLibEntry[],
  pathToName: Map<string, string>
): LibBatchDownloadResult {
  let failedNames: string[] = [];
  let errors: string[] = [];

  if (libs.length === 0) {
    return { ok: 0, failed: 0, errors: errors, failedNames: failedNames };
  }

  let failedFiles = view.failedFiles;
  if (failedFiles !== undefined && failedFiles.length > 0) {
    // 有具体失败文件：精准反查
    for (let f of failedFiles) {
      let name = pathToName.get(f.localPath);
      if (name === undefined) {
        // 防御性：localPath 不在我们生成的 pathToName 里 — 跳过不计入
        continue;
      }
      if (failedNames.indexOf(name) >= 0) continue;  // 同一 lib 多次错误去重
      failedNames.push(name);
      let kind = (f.lastError !== undefined) ? f.lastError.kind : 'Unknown';
      let msg = (f.lastError !== undefined) ? f.lastError.message : '';
      errors.push(name + ': ' + kind + (msg.length > 0 ? ' (' + msg + ')' : ''));
    }
  } else if (!view.success) {
    // 任务级失败（如 CA bundle 未初始化）— 没有具体文件信息，全部归为失败
    let topMsg = view.errorMessage.length > 0 ? view.errorMessage : 'task failed without file detail';
    for (let lib of libs) {
      failedNames.push(lib.name);
      errors.push(lib.name + ': ' + topMsg);
    }
  }

  let failed = failedNames.length;
  let ok = libs.length - failed;
  if (ok < 0) ok = 0;  // 防御性：不会发生但保护

  let result: LibBatchDownloadResult = {
    ok: ok,
    failed: failed,
    errors: errors,
    failedNames: failedNames,
  };
  return result;
}

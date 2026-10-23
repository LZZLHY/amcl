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

import { DownloadFileSpec, DownloadCheck, DownloadTaskView, compileDownloadFiles } from '../download/DownloadManager';
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
  /** 同内容别名仍逐输入结算；旧单值映射继续保留给既有调用方。 */
  pathToNames?: Map<string, string[]>;
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
 * 未在白名单里的主机（用户自建仓库、整合包私有源）不猜布局，仅保留明确直链
 * 或仓库hint，不把未知来源路径套到公共镜像。
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
 * 未知仓库没有已证明的镜像关系，返回空串并保留原直链，不能猜路径后送其他仓库。
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
  return '';
}

/**
 * 已知仓库工件的候选准备原语，同时服务坐标安装与电脑导出。输入仍是远端语义，
 * 不改本地storagePath，也不因“目录看起来像Maven”替换未知私有来源。
 */
function buildArtifactCandidates(relative: string, direct: string, hint: string, preferReal: boolean): string[] {
  const urls: string[] = [];
  const mirrors = [BMCLAPI_MAVEN + relative, BMCLAPI_LIBRARIES + relative];
  const owner = loaderOwnedRepo(relative);
  const repositories = owner.length > 0 ? [owner] : DEFAULT_MAVEN_REPOS;
  if (!preferReal) for (const url of mirrors) pushSafeUrl(urls, url);
  pushSafeUrl(urls, direct);
  pushSafeUrl(urls, hint);
  for (const repository of repositories) {
    pushSafeUrl(urls, (repository.endsWith('/') ? repository : repository + '/') + relative);
  }
  if (preferReal) for (const url of mirrors) pushSafeUrl(urls, url);
  return urls;
}

/** 只有已登记仓库根才能产生等价候选；未知URL保持唯一原直链。 */
export function buildMavenArtifactUrls(url: string, preferRealSource: boolean = false): string[] {
  if (!isSafeHttpUrl(url)) return [];
  const relative = relPathFromUrl(url);
  return relative.length > 0 ? buildArtifactCandidates(relative, url, '', preferRealSource) : [url];
}

/** sidecar后缀属于路径，必须置于原query之前；不能把令牌/query文字改成文件后缀。 */
export function artifactSidecarUrl(url: string, suffix: string): string {
  const fragment = url.indexOf('#');
  const address = fragment < 0 ? url : url.substring(0, fragment);
  const tail = fragment < 0 ? '' : url.substring(fragment);
  const query = address.indexOf('?');
  return (query < 0 ? address + suffix : address.substring(0, query) + suffix + address.substring(query)) + tail;
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
  if (safeDirectUrl.length > 0 && directRel.length === 0) return [safeDirectUrl];
  let mirrorRel = directRel.length > 0 ? directRel : relPath;


  // repoHint（库自身声明的真实仓库，如 maven central / forge maven）
  let hintUrl: string = '';
  if (repoHint !== undefined && isSafeHttpUrl(repoHint)) {
    let base = repoHint.endsWith('/') ? repoHint : repoHint + '/';
    let candidate = base + mirrorRel;
    if (isSafeHttpUrl(candidate)) hintUrl = candidate;
    // 未登记仓库根可能是私有制品库，坐标本身不授予其它镜像等价性。没有已知
    // 官方directUrl时仅使用明确仓库，不拿通用Maven布局猜公开镜像的相同内容。
    if (safeDirectUrl.length === 0 && !knownMavenRepoBases().some((known: string): boolean => known === base)) {
      return hintUrl.length > 0 ? [hintUrl] : [];
    }
  }

  return buildArtifactCandidates(mirrorRel, safeDirectUrl, hintUrl, preferRealSource);
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
  let pathToNames: Map<string, string[]> = new Map<string, string[]>();
  let positions: Map<string, number> = new Map<string, number>();
  let conflicts: Set<string> = new Set<string>();

  for (let lib of libs) {
    let spec = buildSpecForLib(lib, libDir, preferRealSource);
    if (spec === null) {
      invalidNames.push(lib.name);
      continue;
    }
    let names = pathToNames.get(spec.localPath);
    if (names === undefined) { names = []; pathToNames.set(spec.localPath, names); }
    if (names.indexOf(lib.name) < 0) names.push(lib.name);
    if (!pathToName.has(spec.localPath)) pathToName.set(spec.localPath, lib.name);
    if (conflicts.has(spec.localPath)) { invalidNames.push(lib.name); continue; }
    const previous = positions.get(spec.localPath);
    if (previous === undefined) {
      positions.set(spec.localPath, specs.length); specs.push(spec);
    } else {
      // 两项相同内容可合并传输，但不能在去重时丢掉不同摘要/size/约束。只比较
      // 当前一对，避免批量数千库反复编译全部前缀形成二次方开销。
      try { specs[previous] = compileDownloadFiles([specs[previous], spec])[0]; }
      catch (_) {
        conflicts.add(spec.localPath);
        for (const name of names) if (invalidNames.indexOf(name) < 0) invalidNames.push(name);
      }
    }
  }

  let result: MavenSpecResult = {
    specs: specs.filter((spec: DownloadFileSpec): boolean => !conflicts.has(spec.localPath)),
    invalidNames: invalidNames,
    pathToName: pathToName,
    pathToNames: pathToNames,
  };
  return result;
}

/**
 * 把 DownloadManager 完成事件转回 LibBatchDownloadResult（保持向后兼容）。
 *
 * 行为约定：
 *   - libs.length === 0：直接返回空结果（无失败、无错误）
 *   - view.success === true 且 failedFiles 空：合法输入计入 ok，非法坐标仍计入 failed
 *   - 有 failedFiles：对每个 failedFile，反查 pathToName 拿原始 lib name；
 *     只有全部失败路径都能映射到当前输入时，才把其他库认定为成功。
 *   - 取消、未知失败路径、或 false 但没有可解释文件失败：整个输入保守计为失败；
 *     无法确认完成的文件不能因失败清单缺失而被假报成功。
 *   - invalidNames 与文件失败在同一处按坐标去重；failed 统计输入条目，failedNames
 *     只保存唯一坐标，重复输入也不会被漏计为成功。ok + failed 始终等于输入条目数。
 */
export function parseDoneEventToBatchResult(
  view: DownloadTaskView,
  libs: MavenLibEntry[],
  pathToName: Map<string, string>,
  invalidNames: string[] = [],
  pathToNames?: Map<string, string[]>
): LibBatchDownloadResult {
  let failedNames: string[] = [];
  let errors: string[] = [];

  if (libs.length === 0) {
    return { ok: 0, failed: 0, errors: errors, failedNames: failedNames };
  }

  let inputNames: Set<string> = new Set<string>();
  for (let lib of libs) inputNames.add(lib.name);
  let failureMessages: Map<string, string> = new Map<string, string>();
  let hasUnmappedFailure = false;
  let failedFiles = view.failedFiles;
  if (failedFiles !== undefined && failedFiles.length > 0) {
    // 有完整路径身份的失败可以精准反查；映射指向本批次以外坐标也视为清单不可信。
    for (let f of failedFiles) {
      const primary = pathToName.get(f.localPath);
      const aliases = pathToNames?.get(f.localPath) ?? (primary === undefined ? [] : [primary]);
      if (aliases.length === 0 || aliases.some((name: string): boolean => !inputNames.has(name))) {
        hasUnmappedFailure = true;
        continue;
      }
      let kind = (f.lastError !== undefined) ? f.lastError.kind : 'Unknown';
      let msg = (f.lastError !== undefined) ? f.lastError.message : '';
      let httpStatus = (f.lastError !== undefined) ? f.lastError.httpStatus : 0;
      for (const name of aliases) {
        if (!failureMessages.has(name)) failureMessages.set(name, kind + (httpStatus > 0 ? ' http=' + httpStatus : '')
          + (msg.length > 0 ? ' (' + msg + ')' : ''));
      }
    }
  }

  if (view.aborted || hasUnmappedFailure || (!view.success && failureMessages.size === 0)) {
    // 只有可解释的完整终态清单才支持部分成功。已有具体错误保留，其他条目补保守原因。
    let topMsg = view.errorMessage.length > 0 ? view.errorMessage : 'task failed without file detail';
    if (view.aborted) topMsg = 'download aborted: ' + topMsg;
    else if (hasUnmappedFailure) topMsg = 'unmapped failed file: ' + topMsg;
    for (let lib of libs) {
      if (!failureMessages.has(lib.name)) failureMessages.set(lib.name, topMsg);
    }
  }

  // 构造阶段拒绝的坐标从未交给 Native；成功和 reject 两条路径都必须在这里合并，
  // 不能在外层只增加 failed 却保留原 ok，或对同一非法输入重复累计。
  for (let name of invalidNames) {
    if (inputNames.has(name)) failureMessages.set(name, 'invalid maven coordinate');
  }
  failureMessages.forEach((message: string, name: string): void => {
    failedNames.push(name);
    errors.push(name + ': ' + message);
  });
  let failed = 0;
  for (let lib of libs) if (failureMessages.has(lib.name)) failed++;
  let ok = libs.length - failed;

  let result: LibBatchDownloadResult = {
    ok: ok,
    failed: failed,
    errors: errors,
    failedNames: failedNames,
  };
  return result;
}

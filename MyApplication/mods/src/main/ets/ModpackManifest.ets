/**
 * ModpackManifest.ets — 整合包清单解析（Modrinth .mrpack / CurseForge .zip）
 *
 * 文档：docs/guides/modpack-install-plan.md §六 / §七.1
 *
 * 职责：把两种整合包清单（modrinth.index.json / manifest.json）解析并**归一化**为
 *       统一的 `ModpackPlan`，供 ModpackInstaller 编排安装。
 *
 * 设计要点：
 *   - **纯类型 + 纯函数**：不碰 fileIo / 网络 / NAPI，便于 hvigor test（Node + hypium）单测。
 *   - 解析阶段就把"已知问题"收进 warnings（如缺 loader、字段缺失），不抛异常中断。
 *   - env 过滤：Modrinth 文件 `env.client === 'unsupported'` 的不进 plan（纯服务端文件）。
 *   - CurseForge 文件无直链，仅记录 (projectID, fileID)，URL 由 ModpackInstaller 后续解析。
 *
 * 创建日期：2026-06-15
 */

import {
  safeBaseName as canonicalSafeBaseName,
  safeRelPath as canonicalSafeRelPath,
} from 'feature_core';

// ============================================================
//  归一化数据模型（两格式都映射到这里）
// ============================================================

/** 整合包使用的加载器类型（字符串值对齐 feature_core ModLoaderType，便于映射） */
export enum ModpackLoader {
  NONE = 'none',
  FABRIC = 'fabric',
  FORGE = 'forge',
  NEOFORGE = 'neoforge',
  QUILT = 'quilt',
}

/** 文件在客户端的需求级别 */
export enum ModpackEnv {
  REQUIRED = 'required',
  OPTIONAL = 'optional',
  UNSUPPORTED = 'unsupported',
}

/** 需下载的单个文件（mod / 资源 / 配置等，path 是实例相对路径） */
export interface ModpackFile {
  /** 实例相对路径，如 'mods/sodium.jar'、'config/foo.json' */
  path: string;
  /** 下载 URL（Modrinth 直链；CurseForge 解析后填）。可为空表示待解析。 */
  urls: string[];
  /** Modrinth 提供 sha1；CurseForge 无。 */
  sha1?: string;
  /** 保留来源的强哈希，收据/补齐复查不能只剩文件名。 */
  sha512?: string;
  /** 文件字节数；未知为 0。 */
  size: number;
  /** 客户端需求级别。 */
  env: ModpackEnv;
  /** CurseForge 专用：项目 ID（URL 解析用）。 */
  cfProjectId?: number;
  /** CurseForge 专用：文件 ID（URL 解析用）。 */
  cfFileId?: number;
  /** 给用户看的名字（缺失提示用）。 */
  fileNameHint?: string;
}

/** 解析/下载缺失事实；保存来源身份和落点，供原实例补齐与手动下载使用。 */
export interface ModpackProblem {
  name: string;
  reason: string;
  url?: string;
  path?: string;
  cfProjectId?: number;
  cfFileId?: number;
  required?: boolean;
}

/** 来源明确声明的必需本地内容；root 相对已选归档候选根，缺省为 '.'，摘要须精确核验。 */
export interface ModpackLocalFile {
  path: string;
  sha1: string;
  root?: string;
}

/** 用户选择与缺失条目使用来源精确身份，CF 解析前后文件名变化不改变其 key。 */
export function modpackFileKey(file: ModpackFile): string {
  return file.cfProjectId !== undefined && file.cfFileId !== undefined
    ? 'cf:' + file.cfProjectId + ':' + file.cfFileId : file.path;
}

/** 归一化后的统一安装计划 */
export interface ModpackPlan {
  source: string;              // 'modrinth' | 'curseforge' | 'local'
  name: string;                // 整合包名（默认版本名）
  packVersion: string;         // 整合包自身版本（更新比对用）
  gameVersion: string;         // MC 版本
  loaderType: ModpackLoader;
  loaderVersion: string;       // loaderType=NONE 时为空
  summary: string;
  files: ModpackFile[];
  /** ZIP 内要铺到实例的 overrides 目录（按顺序后者覆盖前者）。 */
  overrideDirs: string[];
  /** 无法构造下载文件的清单条目也必须进入最终缺失统计，不能只藏在 warnings。 */
  problems: ModpackProblem[];
  /** PC 实例导入只发布用户内容，不允许源实例 JSON/JAR/控制元数据覆盖新构建。 */
  contentOnly?: boolean;
  /** 源实例目录 ID；目标名称可由用户修改，过滤源 JSON/JAR 仍使用此身份。 */
  instanceVersionId?: string;
  /** 仅校验来源确实声明为必需的本地文件，不把全部未声明内容自动提升为必需项。 */
  requiredLocalFiles?: ModpackLocalFile[];
}

/** 解析结果：计划 + 解析阶段已知的告警（缺字段 / 跳过的文件等）。 */
export interface ParsedModpack {
  plan: ModpackPlan;
  warnings: string[];
}

// ============================================================
//  Modrinth .mrpack —— modrinth.index.json 原始结构
// ============================================================

interface MrIndexFileEnv {
  client?: string;
  server?: string;
}

interface MrIndexHashes {
  sha1?: string;
  sha512?: string;
}

interface MrIndexFile {
  path?: string;
  hashes?: MrIndexHashes;
  env?: MrIndexFileEnv;
  downloads?: string[];
  fileSize?: number;
}

interface MrIndexRaw {
  formatVersion?: number;
  game?: string;
  name?: string;
  versionId?: string;
  summary?: string;
  dependencies?: Record<string, string>;
  files?: MrIndexFile[];
}

// ============================================================
//  CurseForge .zip —— manifest.json 原始结构
// ============================================================

interface CfModLoader {
  id?: string;
  primary?: boolean;
}

interface CfMinecraft {
  version?: string;
  modLoaders?: CfModLoader[];
}

interface CfManifestFile {
  projectID?: number;
  fileID?: number;
  required?: boolean;
}

interface CfManifestRaw {
  minecraft?: CfMinecraft;
  manifestType?: string;
  manifestVersion?: number;
  name?: string;
  version?: string;
  author?: string;
  files?: CfManifestFile[];
  overrides?: string;
}

// ============================================================
//  解析：Modrinth .mrpack
// ============================================================

/**
 * 解析 modrinth.index.json 文本 → ParsedModpack。
 * 解析失败（JSON 非法 / 缺关键字段）抛 Error；可恢复问题进 warnings。
 */
export function parseModrinthIndex(jsonText: string): ParsedModpack {
  let raw: MrIndexRaw;
  try {
    raw = JSON.parse(stripModpackTextBom(jsonText)) as MrIndexRaw;
  } catch (e) {
    throw new Error('modrinth.index.json 解析失败：非法 JSON');
  }
  let warnings: string[] = [];

  if (raw === null || typeof raw !== 'object' || raw.formatVersion !== 1 || raw.game !== 'minecraft') {
    throw new Error('不支持的 Modrinth 格式：需要 formatVersion=1、game=minecraft');
  }
  if (!Array.isArray(raw.files)) throw new Error('Modrinth 清单 files 必须是数组');
  let problems: ModpackProblem[] = [];

  let deps: Record<string, string> | undefined = raw.dependencies;
  if (deps !== undefined && (deps === null || typeof deps !== 'object' || Array.isArray(deps))) {
    throw new Error('Modrinth dependencies 必须是版本对象');
  }
  let gameVersion: string = depGet(deps, 'minecraft');
  if (gameVersion.length === 0) {
    throw new Error('modrinth.index.json 缺少 dependencies.minecraft');
  }
  if (safeBaseName(gameVersion) !== gameVersion) throw new Error('清单 Minecraft 版本名称不安全');
  // 未知依赖不能静默退化为原版；只检查容器声明，不解释模组内部兼容性。
  let dependencyNames: string[] = deps === undefined ? [] : Object.keys(deps);
  for (let key of dependencyNames) {
    if (['minecraft', 'fabric-loader', 'quilt-loader', 'forge', 'neoforge'].indexOf(key) < 0) {
      throw new Error('暂不支持清单依赖：' + key);
    }
  }

  // loader：按优先级取第一个出现的（一个整合包只会有一个 loader）
  let loaderType: ModpackLoader = ModpackLoader.NONE;
  let loaderVersion: string = '';
  let fabric: string = depGet(deps, 'fabric-loader');
  let quilt: string = depGet(deps, 'quilt-loader');
  let forge: string = depGet(deps, 'forge');
  let neoforge: string = depGet(deps, 'neoforge');
  if ([fabric, quilt, forge, neoforge].filter((version: string): boolean => version.length > 0).length > 1) {
    throw new Error('整合包声明了多个互斥加载器，无法确定基础版本');
  }
  if (fabric.length > 0) {
    loaderType = ModpackLoader.FABRIC; loaderVersion = fabric;
  } else if (quilt.length > 0) {
    loaderType = ModpackLoader.QUILT; loaderVersion = quilt;
  } else if (neoforge.length > 0) {
    loaderType = ModpackLoader.NEOFORGE; loaderVersion = neoforge;
  } else if (forge.length > 0) {
    loaderType = ModpackLoader.FORGE; loaderVersion = forge;
  } else {
    warnings.push('整合包未声明 mod 加载器，将作为原版安装');
  }

  let files: ModpackFile[] = [];
  let rawFiles: MrIndexFile[] = raw.files ?? [];
  for (let f of rawFiles) {
    let rawPath: string = f.path ?? '';
    if (typeof rawPath !== 'string' || rawPath.length === 0) {
      problems.push({ name: '未命名文件', reason: '清单缺少有效 path', required: true }); continue;
    }
    // 安全校验：拒绝绝对路径 / 盘符 / .. 逃逸（防 zip-slip 写出实例目录外）
    let path: string = safeRelPath(rawPath);
    if (path.length === 0) {
      problems.push({ name: rawPath, reason: '清单文件路径不安全，未写入实例', required: true }); continue;
    }
    let env: ModpackEnv = mrEnvOf(f.env);
    // 纯服务端文件不装到客户端
    if (env === ModpackEnv.UNSUPPORTED) { continue; }
    let downloads: string[] = f.downloads ?? [];
    if (!Array.isArray(downloads)) throw new Error('清单文件 downloads 必须是数组');
    // 空地址保留在计划中；必需项计入缺失，可选项仍可由用户明确取消选择。
    for (let url of downloads) {
      if (typeof url !== 'string' || !url.startsWith('https://')) throw new Error('整合包下载地址必须为 HTTPS');
    }
    let hashes: MrIndexHashes = f.hashes ?? {};
    let file: ModpackFile = {
      path,
      urls: downloads,
      size: f.fileSize ?? 0,
      env,
      fileNameHint: baseName(path),
    };
    if (hashes.sha1 !== undefined && hashes.sha1.length > 0) file.sha1 = hashes.sha1;
    if (hashes.sha512 !== undefined && hashes.sha512.length > 0) file.sha512 = hashes.sha512;
    if (file.sha1 !== undefined && !new RegExp('^[a-fA-F0-9]{40}$').test(file.sha1)) {
      throw new Error('整合包文件 SHA-1 无效：' + path);
    }
    if (file.sha512 !== undefined && !new RegExp('^[a-fA-F0-9]{128}$').test(file.sha512)) {
      throw new Error('整合包文件 SHA-512 无效：' + path);
    }
    if (file.sha1 === undefined) throw new Error('Modrinth 文件缺少必需的 SHA-1：' + path);
    if (!Number.isSafeInteger(file.size) || file.size < 0) throw new Error('清单文件大小无效：' + path);
    if (files.some((existing: ModpackFile): boolean => existing.path === path)) {
      throw new Error('整合包清单包含重复目标路径：' + path);
    }
    files.push(file);
  }

  let plan: ModpackPlan = {
    source: 'modrinth',
    name: (raw.name !== undefined && raw.name.length > 0) ? raw.name : 'Modrinth 整合包',
    packVersion: raw.versionId ?? '',
    gameVersion,
    loaderType,
    loaderVersion,
    summary: raw.summary ?? '',
    files,
    overrideDirs: ['overrides', 'client-overrides'],
    problems,
  };
  return { plan, warnings };
}

/** Modrinth env.client → ModpackEnv（缺省按 required） */
function mrEnvOf(env?: MrIndexFileEnv): ModpackEnv {
  let client: string = (env !== undefined && env.client !== undefined) ? env.client : 'required';
  if (client === 'unsupported') return ModpackEnv.UNSUPPORTED;
  if (client === 'optional') return ModpackEnv.OPTIONAL;
  if (client !== 'required') throw new Error('不支持的客户端环境声明：' + client);
  return ModpackEnv.REQUIRED;
}

// ============================================================
//  解析：CurseForge .zip
// ============================================================

/**
 * 解析 CurseForge manifest.json 文本 → ParsedModpack。
 * 文件 URL 留空（urls=[]），由 ModpackInstaller 通过 (projectID, fileID) 解析。
 */
export function parseCurseForgeManifest(jsonText: string): ParsedModpack {
  let raw: CfManifestRaw;
  try {
    raw = JSON.parse(stripModpackTextBom(jsonText)) as CfManifestRaw;
  } catch (e) {
    throw new Error('manifest.json 解析失败：非法 JSON');
  }
  let warnings: string[] = [];

  if (raw === null || typeof raw !== 'object' || raw.manifestType !== 'minecraftModpack' || raw.manifestVersion !== 1) {
    throw new Error('不支持的 CurseForge 格式：需要 minecraftModpack、manifestVersion=1');
  }
  if (!Array.isArray(raw.files)) throw new Error('CurseForge 清单 files 必须是数组');
  let problems: ModpackProblem[] = [];

  let mc: CfMinecraft = raw.minecraft ?? {};
  let gameVersion: string = mc.version ?? '';
  if (typeof gameVersion !== 'string' || gameVersion.length === 0) {
    throw new Error('manifest.json 缺少 minecraft.version');
  }
  if (safeBaseName(gameVersion) !== gameVersion) throw new Error('CurseForge Minecraft 版本名称不安全');

  // modLoaders：取 primary，否则首个
  let loaderId: string = '';
  let loaders: CfModLoader[] = mc.modLoaders ?? [];
  for (let l of loaders) {
    if (l.primary === true && l.id !== undefined && l.id.length > 0) { loaderId = l.id; break; }
  }
  if (loaderId.length === 0 && loaders.length > 0) {
    let first: CfModLoader = loaders[0];
    loaderId = first.id ?? '';
  }
  let loaderType: ModpackLoader = ModpackLoader.NONE;
  let loaderVersion: string = '';
  if (loaderId.length > 0) {
    let parsed: LoaderIdParts = parseCfLoaderId(loaderId);
    loaderType = parsed.type;
    loaderVersion = parsed.version;
    if (loaderType === ModpackLoader.NONE) {
      throw new Error('暂不支持整合包声明的加载器：' + loaderId);
    }
  } else {
    warnings.push('整合包未声明 mod 加载器，将作为原版安装');
  }

  let files: ModpackFile[] = [];
  let rawFiles: CfManifestFile[] = raw.files ?? [];
  let byIdentity: Map<string, ModpackFile> = new Map<string, ModpackFile>();
  for (let f of rawFiles) {
    let pid: number = f.projectID ?? 0;
    let fid: number = f.fileID ?? 0;
    if (!Number.isSafeInteger(pid) || !Number.isSafeInteger(fid) || pid <= 0 || fid <= 0) {
      problems.push({ name: 'CF 文件 ' + pid + '/' + fid, reason: '清单 projectID/fileID 无效', required: f.required !== false });
      continue;
    }
    let env: ModpackEnv = (f.required === false) ? ModpackEnv.OPTIONAL : ModpackEnv.REQUIRED;
    // 有些导出器重复写同一精确文件。只合并 project/file 双身份完全相同的项，
    // 顺序保留首次出现位置；任何 required 声明都优先，不能被后来的 optional 降级。
    let identity = pid + ':' + fid;
    let previous = byIdentity.get(identity);
    if (previous !== undefined) {
      if (env === ModpackEnv.REQUIRED) previous.env = ModpackEnv.REQUIRED;
      continue;
    }
    let file: ModpackFile = {
      path: '',            // CF 文件名/路径在解析下载 URL 时确定（落到 mods/）
      urls: [],            // 待 ModpackInstaller 解析
      size: 0,
      env,
      cfProjectId: pid,
      cfFileId: fid,
      fileNameHint: 'CF 文件 ' + pid + '/' + fid,
    };
    files.push(file);
    byIdentity.set(identity, file);
  }

  if (raw.overrides !== undefined && typeof raw.overrides !== 'string') throw new Error('CurseForge overrides 必须为目录字符串');
  let overridesRaw: string = (raw.overrides !== undefined && raw.overrides.length > 0) ? raw.overrides : 'overrides';
  let overrides: string = normalizeModpackOverrideDirectory(overridesRaw);
  let overrideDirs: string[] = [];
  if (overrides.length === 0) {
    problems.push({ name: overridesRaw, reason: 'overrides 路径不安全，未应用覆盖文件', required: true });
  } else {
    overrideDirs.push(overrides);
  }
  let plan: ModpackPlan = {
    source: 'curseforge',
    name: (raw.name !== undefined && raw.name.length > 0) ? raw.name : 'CurseForge 整合包',
    packVersion: raw.version ?? '',
    gameVersion,
    loaderType,
    loaderVersion,
    summary: '',
    files,
    overrideDirs,
    problems,
  };
  return { plan, warnings };
}

interface LoaderIdParts { type: ModpackLoader; version: string; }

/**
 * 解析 CurseForge modLoader id（形如 "forge-47.2.0" / "fabric-0.16.10" /
 * "neoforge-20.4.190" / "quilt-0.26.0"）→ 类型 + 版本。
 * loader 名不含 '-'，第一个 '-' 后即版本。
 */
export function parseCfLoaderId(id: string): LoaderIdParts {
  let dash: number = id.indexOf('-');
  let name: string = dash >= 0 ? id.substring(0, dash) : id;
  let version: string = dash >= 0 ? id.substring(dash + 1) : '';
  let type: ModpackLoader = ModpackLoader.NONE;
  switch (name.toLowerCase()) {
    case 'forge':    type = ModpackLoader.FORGE; break;
    case 'fabric':   type = ModpackLoader.FABRIC; break;
    case 'neoforge': type = ModpackLoader.NEOFORGE; break;
    case 'quilt':    type = ModpackLoader.QUILT; break;
    default:         type = ModpackLoader.NONE; break;
  }
  return { type, version };
}

// ============================================================
//  工具
// ============================================================

/** 取路径最后一段（文件名）。 */
function baseName(path: string): string {
  let i: number = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

/**
 * 统一走 feature_core canonical 校验；保留 mods API 名称避免调用方迁移。
 */
export function safeRelPath(path: string): string {
  return canonicalSafeRelPath(path);
}

export function safeBaseName(name: string): string {
  return canonicalSafeBaseName(name);
}

/** 仅移除文本开头的 UTF-8 BOM；不改 JSON 正文、路径或字符串内部的同码位字符。 */
export function stripModpackTextBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.substring(1) : text;
}

/**
 * 只在 CF 的“目录”字段兼容无歧义别名，不放宽通用文件路径策略。点根返回显式 '.'
 * 标记，由安装器限定在已验证归档根内应用且排除控制清单；不自动探测其他目录。
 * 允许前导 './'、尾分隔符与 Windows 反斜杠，仍拒绝绝对路径、盘符和任意 '..'。
 */
export function normalizeModpackOverrideDirectory(value: string): string {
  if (value.length === 0 || value.startsWith('/') || value.startsWith('\\') || /^[a-zA-Z]:/.test(value)) return '';
  let normalized = value.replace(/\\/g, '/');
  while (normalized.startsWith('./')) normalized = normalized.substring(2);
  while (normalized.endsWith('/')) normalized = normalized.substring(0, normalized.length - 1);
  if (normalized === '.' || normalized.length === 0) return '.';
  return canonicalSafeRelPath(normalized);
}

/** 从 Record<string,string> 安全取值（key 可含横线，走索引签名访问），缺省空串。 */
function depGet(deps: Record<string, string> | undefined, key: string): string {
  if (deps === undefined) return '';
  let v: string | undefined = deps[key];
  if (v !== undefined && typeof v !== 'string') throw new Error('清单依赖版本必须是字符串：' + key);
  return v ?? '';
}

/**
 * 按清单文本类型选择解析器。
 * @param manifestKind 'modrinth' | 'curseforge'
 */
export function parseModpackManifest(manifestKind: string, jsonText: string): ParsedModpack {
  if (manifestKind === 'modrinth') return parseModrinthIndex(jsonText);
  if (manifestKind === 'curseforge') return parseCurseForgeManifest(jsonText);
  throw new Error('未知整合包清单类型：' + manifestKind);
}

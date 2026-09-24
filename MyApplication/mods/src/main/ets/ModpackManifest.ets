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
    raw = JSON.parse(jsonText) as MrIndexRaw;
  } catch (e) {
    throw new Error('modrinth.index.json 解析失败：非法 JSON');
  }
  let warnings: string[] = [];

  let deps: Record<string, string> | undefined = raw.dependencies;
  let gameVersion: string = depGet(deps, 'minecraft');
  if (gameVersion.length === 0) {
    throw new Error('modrinth.index.json 缺少 dependencies.minecraft');
  }

  // loader：按优先级取第一个出现的（一个整合包只会有一个 loader）
  let loaderType: ModpackLoader = ModpackLoader.NONE;
  let loaderVersion: string = '';
  let fabric: string = depGet(deps, 'fabric-loader');
  let quilt: string = depGet(deps, 'quilt-loader');
  let forge: string = depGet(deps, 'forge');
  let neoforge: string = depGet(deps, 'neoforge');
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
    if (rawPath.length === 0) { warnings.push('跳过一个缺少 path 的文件条目'); continue; }
    // 安全校验：拒绝绝对路径 / 盘符 / .. 逃逸（防 zip-slip 写出实例目录外）
    let path: string = safeRelPath(rawPath);
    if (path.length === 0) { warnings.push('跳过一个非法路径的文件条目：' + rawPath); continue; }
    let env: ModpackEnv = mrEnvOf(f.env);
    // 纯服务端文件不装到客户端
    if (env === ModpackEnv.UNSUPPORTED) { continue; }
    let downloads: string[] = f.downloads ?? [];
    if (downloads.length === 0) {
      warnings.push('文件缺少下载地址，已跳过：' + path);
      continue;
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
  };
  return { plan, warnings };
}

/** Modrinth env.client → ModpackEnv（缺省按 required） */
function mrEnvOf(env?: MrIndexFileEnv): ModpackEnv {
  let client: string = (env !== undefined && env.client !== undefined) ? env.client : 'required';
  if (client === 'unsupported') return ModpackEnv.UNSUPPORTED;
  if (client === 'optional') return ModpackEnv.OPTIONAL;
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
    raw = JSON.parse(jsonText) as CfManifestRaw;
  } catch (e) {
    throw new Error('manifest.json 解析失败：非法 JSON');
  }
  let warnings: string[] = [];

  let mc: CfMinecraft = raw.minecraft ?? {};
  let gameVersion: string = mc.version ?? '';
  if (gameVersion.length === 0) {
    throw new Error('manifest.json 缺少 minecraft.version');
  }

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
      warnings.push('无法识别的加载器标识：' + loaderId);
    }
  } else {
    warnings.push('整合包未声明 mod 加载器，将作为原版安装');
  }

  let files: ModpackFile[] = [];
  let rawFiles: CfManifestFile[] = raw.files ?? [];
  for (let f of rawFiles) {
    let pid: number = f.projectID ?? 0;
    let fid: number = f.fileID ?? 0;
    if (pid <= 0 || fid <= 0) { warnings.push('跳过一个缺少 projectID/fileID 的文件条目'); continue; }
    let env: ModpackEnv = (f.required === false) ? ModpackEnv.OPTIONAL : ModpackEnv.REQUIRED;
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
  }

  let overridesRaw: string = (raw.overrides !== undefined && raw.overrides.length > 0) ? raw.overrides : 'overrides';
  let overrides: string = safeRelPath(overridesRaw);
  let overrideDirs: string[] = [];
  if (overrides.length === 0) {
    warnings.push('忽略非法 overrides 路径：' + overridesRaw);
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

/** 从 Record<string,string> 安全取值（key 可含横线，走索引签名访问），缺省空串。 */
function depGet(deps: Record<string, string> | undefined, key: string): string {
  if (deps === undefined) return '';
  let v: string | undefined = deps[key];
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

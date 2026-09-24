/**
 * ModInstaller.ets — 模组文件落地 / 启用-禁用 / 删除（P1-MODS Phase 1.5）
 *
 * 文档：docs/guides/mod-download-system-plan.md §七.5
 *
 * 职责：
 *   - installBatch：把 RemoteFile[] 编排成 DownloadFileSpec[]，走 DownloadManager.createAndWait
 *     下载到目标版本目录（mods / resourcepacks / shaderpacks）
 *   - setEnabled：rename `.jar` ↔ `.jar.disabled`（HMCL / PCL2 通用约定）
 *   - delete：物理删除已装模组文件
 *   - ensureDir：创建目标目录（递归）
 *
 * 设计要点：
 *   - 把可测逻辑（路径构造、文件名后缀切换）拆成纯函数，便于 hypium 单测
 *   - HTTP 下载通路完全复用 DownloadManager，不引入新网络栈
 *   - 不直接依赖 PreferenceManager / Index.ets — 调用方传必要参数
 *
 * 创建日期：2026-05-11
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { ActivityLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import {
  DownloadManager,
  DownloadFileSpec,
  DownloadTaskSpec,
  DownloadTaskView,
  DownloadListener,
  DownloadCheck,
} from 'feature_core';
import {
  RemoteFile,
  ResourceKind,
  resourceKindToInstallDir,
} from './ModTypes';
import { safeBaseName } from './ModpackManifest';
import { modTransactionPending } from './ModInstallTransaction';

interface RootedDownloadFileSpec extends DownloadFileSpec {
  allowedRoot: string;
}

const TAG = 'ModInstaller';

// ============================================================
//  纯函数 1：启用/禁用文件名切换
// ============================================================

/** 已启用 mod 的文件名后缀（约定：HMCL / PCL2 / Fabric Loader 全支持） */
const SUFFIX_DISABLED = '.disabled';

/** 是否被禁用（以 `.jar.disabled` / `.zip.disabled` 结尾） */
export function isDisabledFilename(name: string): boolean {
  return name.endsWith(SUFFIX_DISABLED);
}

/**
 * 把 `.jar` → `.jar.disabled`；已经 `.disabled` 则原样返回。
 * 同时支持 `.zip`（资源包）等其他扩展。
 */
export function disableFilename(name: string): string {
  if (isDisabledFilename(name)) return name;
  return name + SUFFIX_DISABLED;
}

/**
 * 把 `.jar.disabled` → `.jar`；未禁用则原样返回。
 */
export function enableFilename(name: string): string {
  if (!isDisabledFilename(name)) return name;
  return name.substring(0, name.length - SUFFIX_DISABLED.length);
}

/**
 * 按期望状态返回切换后的文件名。
 *   enabled=true  → 去掉 .disabled 后缀
 *   enabled=false → 追加 .disabled 后缀
 */
export function toggleEnabledFilename(name: string, enabled: boolean): string {
  return enabled ? enableFilename(name) : disableFilename(name);
}

// ============================================================
//  纯函数 2：DownloadFileSpec 构造
// ============================================================

/** 单个 RemoteFile + 目标目录 → DownloadFileSpec（本函数不做 IO） */
export function buildDownloadSpec(file: RemoteFile, targetDir: string): DownloadFileSpec {
  if (file.url.length === 0) {
    throw new Error('ModInstaller.buildDownloadSpec: file "' + file.filename
      + '" has empty download URL (CurseForge author may have disabled third-party downloads)');
  }
  let filename = safeBaseName(file.filename);
  if (filename.length === 0 || filename !== file.filename) {
    throw new Error('ModInstaller.buildDownloadSpec: unsafe filename rejected');
  }
  let localPath = targetDir + '/' + filename;
  let urls: string[] = [file.url];
  if (file.mirrors !== undefined) {
    for (let m of file.mirrors) {
      if (m.length > 0) urls.push(m);
    }
  }
  let spec: RootedDownloadFileSpec = {
    localPath,
    urls,
    allowedRoot: targetDir,
  };
  // 模组多源时开高并发模式（16）。注意这只是**上限**，不是"一定切 16 段"：
  //   · initSegments 的实际段数 = min(maxConnections, ceil(size / piece_min))，
  //     piece_min（高并发路径）= 256KiB（对齐 PCL2 FilePieceLimit）。于是
  //     1.2MB 模组 → 5 段、2.6MB → 11 段、8MB → 16 段；小文件不会被切碎。
  //   · 段数不足时也不会盲目补段：maybeGrowThreads 保留 PCL2 的速度地板门控
  //     （聚合速度 ≥ max(256KB/s, 峰值/2) 就一条也不加）。
  //   · Modrinth 的源顺序由 ModSourceProber 实测决定（见 ModrinthUrls.mapModrinthFile）。
  //     CurseForge 文件仍镜像 /files/ 优先（缓存命中快）。
  //
  // ⚠️ 2026-07-31：8 → 16，依据是同一台平板（MatePad Pro）同一条劣质国际路由上的
  //   真机实测——Modrinth 的两个源最终都 302/307 汇聚到 cdn-alt.modrinth.com
  //   （解析到 203.10.96.211，RTT 395ms、TTFB 实测可达 11.5s、单连接仅 1~2KB/s；
  //   国内 bmclapi 同期 0s 返回，证明是国际路由问题而非设备网络问题）：
  //     1 段（修复前）  sodium 1.2MB / 646s =  1.8 KB/s
  //     5 段            sodium 1.2MB / 236s =  5.1 KB/s   （每段 1.02 KB/s）
  //     8 段            iris   2.6MB / 227s = 12.1 KB/s   （每段 1.51 KB/s）
  //   段数 ×1.6 换来吞吐 ×2.4（**超线性**）：说明这类路由是**丢包受限**而非带宽/限流
  //   受限，每条连接各自独立跑拥塞控制，加连接仍有明显收益，远未触及 CDN 限流天花板。
  //   （对照 engine 里"同一 CDN 并发越多越慢"的旧结论：那组数据来自 1.7MB/s 的**健康**
  //     路由，加连接只造成互抢；两种情形不矛盾，判据是当前是否已接近带宽上限。）
  //   16 亦是 kHighParallelMaxConnections 的硬上限，不会再往上扩。
  // 单连接 TCP 窗口由 SO_RCVBUF 放大 + 强制 HTTP/1.1 保证（net_thread sockoptEnlargeRcvbuf）。
  if (urls.length > 1) {
    spec.maxConnections = 16;
  }
  if (file.sha1 !== undefined && file.sha1.length > 0) {
    let check: DownloadCheck = { sha1: file.sha1, size: file.size };
    spec.check = check;
  } else if (file.size > 0) {
    let check: DownloadCheck = { size: file.size };
    spec.check = check;
  }
  return spec;
}

/** 批量构造 DownloadFileSpec[]（按目标目录） */
export function buildDownloadSpecs(files: RemoteFile[], targetDir: string): DownloadFileSpec[] {
  let result: DownloadFileSpec[] = [];
  for (let f of files) result.push(buildDownloadSpec(f, targetDir));
  return result;
}

// ============================================================
//  纯函数 3：任务名
// ============================================================

/**
 * 统一的模组下载任务名，UI 展示 + 去重用。
 *
 * 形如：`mod: sodium-0.5.8.jar`
 *      `mod: sodium + 2 deps`（批量）
 *      `resourcepack: Faithful.zip`
 *
 * 与 MC 版本下载任务名（"MC 1.20.4..."）天然互斥，不会 DownloadManager 同名拒绝。
 */
export function buildTaskName(kind: ResourceKind, primaryFilename: string, extraCount: number): string {
  let kindLabel: string;
  switch (kind) {
    case ResourceKind.MOD:           kindLabel = 'mod'; break;
    case ResourceKind.RESOURCE_PACK: kindLabel = 'resourcepack'; break;
    case ResourceKind.SHADER:        kindLabel = 'shader'; break;
    case ResourceKind.DATAPACK:      kindLabel = 'datapack'; break;
    case ResourceKind.MODPACK:       kindLabel = 'modpack'; break;
    default:                         kindLabel = 'resource'; break;
  }
  if (extraCount <= 0) return kindLabel + ': ' + primaryFilename;
  return kindLabel + ': ' + primaryFilename + ' + ' + extraCount + ' deps';
}

// ============================================================
//  ModInstaller 类（混合 IO + 下载编排）
// ============================================================

export interface InstallBatchRequest {
  kind: ResourceKind;
  /** .minecraft 根目录（不带尾部 /） */
  mcDir: string;
  /** 当前选中的版本 id（与 versionIsolation 配合） */
  versionId: string;
  versionIsolation: boolean;
  /** 主文件（一般是用户选的那个 mod 版本） */
  primary: RemoteFile;
  /** 依赖文件（可空） */
  dependencies: RemoteFile[];
}

export class ModInstaller {
  /**
   * 归属的活动主键（活动账本 · L2-b）；0 = 不归属。
   * 由 ResourceInstallTask 用自己的 startedAtMs 赋值。
   */
  activityId: number = 0;

  /**
   * `activityId` 对应的 logger 缓存（活动账本 · 缺陷 1 修复）。
   * `ActivityLogger.activityId` 是 readonly，而本类的 `activityId` 是构造后才被
   * 赋值的，因此只能在用的时候比对、变了再重建。
   */
  private alogCache_: ActivityLogger = new ActivityLogger(0);

  /** 取绑定当前活动的 logger；`activityId` 变了会自动重建。 */
  private alog(): ActivityLogger {
    if (this.alogCache_.id() !== this.activityId) {
      this.alogCache_ = new ActivityLogger(this.activityId);
    }
    return this.alogCache_;
  }
  private downloadManager_: DownloadManager;

  constructor(downloadManager: DownloadManager) {
    this.downloadManager_ = downloadManager;
  }

  /**
   * 下载并落地模组 + 依赖。
   *
   * 流程：
   *   1. 计算目标目录（resourceKindToInstallDir）
   *   2. 确保目录存在（递归 mkdir）
   *   3. 构造 DownloadFileSpec[]（含 sha1 校验）
   *   4. 走 DownloadManager.createAndWait；UI 进度由 onProgress 外传
   *
   * @throws ModRepoError / Error 网络或磁盘失败
   */
  async installBatch(req: InstallBatchRequest, onProgress?: DownloadListener): Promise<DownloadTaskView> {
    let targetDir = resourceKindToInstallDir(req.kind, req.mcDir, req.versionId, req.versionIsolation);
    this.ensureDir(targetDir);

    let all: RemoteFile[] = [req.primary];
    for (let d of req.dependencies) all.push(d);
    let files = buildDownloadSpecs(all, targetDir);

    let name = buildTaskName(req.kind, req.primary.filename, req.dependencies.length) + ' @ ' + targetDir;
    let spec: DownloadTaskSpec = { name, files, activityId: this.activityId };

    this.alog().info(TAG, `installBatch: ${name} -> ${targetDir} (${files.length} files)`, LOG_DOMAIN_DOWNLOAD);
    return this.downloadManager_.createAndWait(spec, onProgress);
  }

  /**
   * 启用 / 禁用已装模组文件：rename `.jar` ↔ `.jar.disabled`。
   *
   * 如果目标文件已经处于请求的状态，直接返回 true；
   * 如果文件不存在，返回 false。
   *
   * @param filePath 当前文件绝对路径（可能是 `.jar` 或 `.jar.disabled`）
   * @param enabled  期望状态
   * @returns        实际切换后的新路径（未改变时返回原路径），或 null 表示文件缺失
   */
  setEnabled(filePath: string, enabled: boolean): string | null {
    if (modTransactionPending(filePath.substring(0, filePath.lastIndexOf('/'))))
      throw new Error('此目录正在安装或恢复模组，请等待完成');
    // 拆 basename + dir
    let idx = filePath.lastIndexOf('/');
    if (idx < 0) return null;
    let dir = filePath.substring(0, idx);
    let name = filePath.substring(idx + 1);
    if (safeBaseName(name) !== name) {
      throw new Error('ModInstaller.setEnabled failed: unsafe filename rejected');
    }
    let newName = toggleEnabledFilename(name, enabled);
    if (safeBaseName(newName) !== newName) {
      throw new Error('ModInstaller.setEnabled failed: unsafe target filename rejected');
    }
    let newPath = dir + '/' + newName;
    // 不需要改名
    if (newName === name) {
      // 校验文件存在
      try { fs.statSync(filePath); return filePath; }
      catch (e) { return null; }
    }
    try { fs.statSync(filePath); }
    catch (e) { return null; }
    // 关键修复：rename 前明确拒绝覆盖。OHOS renameSync 在目标已存在时行为未文档化，
    // 可能直接覆盖导致数据丢失。已知场景：用户手动放置 mod.jar + mod.jar.disabled 同名两个版本。
    let collision = false;
    try {
      fs.statSync(newPath);
      collision = true;
    } catch (e) { /* not exists: 安全 */ }
    if (collision) {
      let msg = 'target already exists, refusing to overwrite: ' + newPath;
      this.alog().error(TAG, `setEnabled aborted: ${msg}`, null, LOG_DOMAIN_DOWNLOAD);
      throw new Error('ModInstaller.setEnabled failed: ' + msg);
    }
    try {
      fs.renameSync(filePath, newPath);
      this.alog().info(TAG, `setEnabled: ${filePath} -> ${newPath} (enabled=${enabled ? 'true' : 'false'})`, LOG_DOMAIN_DOWNLOAD);
      return newPath;
    } catch (e) {
      let msg = errorMessage(e);
      this.alog().error(TAG, `setEnabled rename failed: ${msg}`, null, LOG_DOMAIN_DOWNLOAD);
      throw new Error('ModInstaller.setEnabled failed: ' + msg);
    }
  }

  /** 物理删除已装文件；不存在返回 false。 */
  delete(filePath: string): boolean {
    if (modTransactionPending(filePath.substring(0, filePath.lastIndexOf('/'))))
      throw new Error('此目录正在安装或恢复模组，请等待完成');
    try { fs.statSync(filePath); }
    catch (e) { return false; }
    try {
      fs.unlinkSync(filePath);
      this.alog().info(TAG, `delete: ${filePath}`, LOG_DOMAIN_DOWNLOAD);
      return true;
    } catch (e) {
      let msg = errorMessage(e);
      this.alog().error(TAG, `delete failed: ${msg}`, null, LOG_DOMAIN_DOWNLOAD);
      throw new Error('ModInstaller.delete failed: ' + msg);
    }
  }

  /** 递归 mkdir；已存在不报错。 */
  ensureDir(dir: string): void {
    try { fs.mkdirSync(dir, true); }
    catch (e) {
      // 已存在是常态，忽略；其他错再拋
      try { let st = fs.statSync(dir); if (st.isDirectory()) return; } catch (ee) { /* */ }
      throw new Error('ModInstaller.ensureDir failed: ' + errorMessage(e));
    }
  }
}

// ============================================================
//  错误消息提取（ArkTS 严格模式下 catch(e) 的 e 类型受限）
// ============================================================

function errorMessage(e: Object): string {
  let err = e as Error;
  if (err.message !== undefined && err.message.length > 0) return err.message;
  return String(e);
}

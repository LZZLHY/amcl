/**
 * ModpackInstaller.ets — 整合包安装编排器（P2：Modrinth .mrpack 闭环）
 *
 * 文档：docs/guides/modpack-install-plan.md §七.2
 *
 * 流程（installFromArchive）：
 *   1. 解压 archive 到临时目录（zlib，复用 feature_core decompressFile）
 *   2. 读清单（modrinth.index.json / manifest.json）→ 解析为 ModpackPlan
 *   3. 版本名去重（与 existingVersions 比对，冲突追加序号）
 *   4. 建带 loader 的隔离版本（McVersionTask.start()，内部跑 prepare→...→modloader→merge）
 *   5. 按 file.path 批量下文件到 versions/<name>/（DownloadManager.createAndWait）；
 *      失败文件进 missing 清单（决策4：装能装的，不整包失败）
 *   6. 铺 overrides（递归复制 overrides/ 再 client-overrides/，后者覆盖前者）
 *   7. 写快照（.amcl-modpack.json）
 *   8. 清理临时目录
 *
 * 设计要点：
 *   - 复用现有积木：McVersionTask（建版本+装 loader）/ DownloadManager（批量下载）/
 *     decompressFile（解压）。整合包文件路径非固定 mods/，故**不复用 ModInstaller.installBatch**，
 *     按 file.path 自行构造 DownloadFileSpec。
 *   - P2 仅走 Modrinth；CurseForge（需 fileID→url 解析）留 P5，遇到先抛清晰提示。
 *   - 特殊脚本/推荐参数解析留 P6；P2 的 overrides 全量保真复制已能保留 scripts/kubejs/config。
 *
 * 创建日期：2026-06-15
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { ActivityLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { removeDirRecursive } from 'commons';
import {
  DownloadManager,
  DownloadFileSpec,
  DownloadTaskSpec,
  DownloadTaskView,
  DownloadFailedFile,
  DownloadCheck,
  McVersionTask,
  ModLoaderType,
  decompressFile,
  UnifiedTaskView,
} from 'feature_core';
import {
  ModpackPlan, ModpackFile, ModpackLoader,
  parseModrinthIndex, parseCurseForgeManifest, safeRelPath, safeBaseName,
} from './ModpackManifest';
import { mirrorifyModrinthCdn } from './ModrinthUrls';
import {
  ModpackSnapshot, ModpackMissingItem, writeModpackSnapshot, MODPACK_ICON_FILE,
} from './ModpackSnapshot';
import { processModpackLaunchConfig } from './ModpackPostProcessor';

const TAG = 'ModpackInstaller';

/**
 * 全局基础版本构建锁。并发安装多个整合包时,"建基础版本"这段必须串行,因为：
 *   ① DownloadTask 用共享的 `mcDir/download-temp`,`cleanTempDir()` 删整个目录——
 *      并发时第二个会删掉第一个正在用的 vanilla json/jar（实测 RLCraft 被 ATM9 冲掉）。
 *   ② Forge 安装 fork 一个嵌入式 JVM,同进程无法并发跑两个 JVM。
 * 仅串行"建基础版本";archive 下载 / CF 解析 / mod 批量下载仍并发（互不冲突）。
 */
let baseBuildLock_: Promise<void> = Promise.resolve();

/** CurseForge 文件解析结果（projectID/fileID → 下载直链 + 文件名）。 */
export interface CfFileResolution {
  size: number;
  sha1?: string;
  /** 下载 URL（含镜像，按优先级）。 */
  urls: string[];
  /** 文件名（用于落 mods/<filename>）。 */
  filename: string;
}

/** CurseForge 文件解析器（由调用方用已构造的 CF 仓库提供，解耦 installer）。
 *  gameVersion/loader 供"精确 fileId 已删除时回退到兼容版本"使用。 */
export type CfFileResolver = (
  projectId: number, fileId: number, gameVersion: string, loader: string,
) => Promise<CfFileResolution>;

/** 安装请求。 */
export interface ModpackInstallRequest {
  /** 整合包 archive（.mrpack / .zip）的真实沙箱路径。若为空则用 archiveUrl 先下载。 */
  archivePath?: string;
  /** 在线安装：整合包 archive 的下载地址（archivePath 为空时使用）。 */
  archiveUrl?: string;
  /** 在线安装：archive 的镜像备源（与 archiveUrl 一起做多源容错）。 */
  archiveMirrors?: string[];
  /** 在线安装：保存的文件名（默认从 URL 推断）。 */
  archiveFilename?: string;
  /** .minecraft 根目录（不带尾部 /）。 */
  mcDir: string;
  /** 应用 filesDir（McVersionTask / loader 安装需要）。 */
  filesDir: string;
  /** 已存在的版本名（用于去重）。 */
  existingVersions: string[];
  /** 覆盖默认版本名（默认取整合包名）。 */
  versionName?: string;
  /** 在线安装时的项目 id（写入快照，更新用）。 */
  projectId?: string;
  /** 在线安装时的项目图标 URL（安装后下载到版本目录，版本列表/详情显示用）。 */
  iconUrl?: string;
  /** CurseForge 文件解析器（CF 整合包必需；Modrinth 不需要）。 */
  resolveCfFile?: CfFileResolver;
  /** 阶段进度回调（P3 adapter 用）。phase ∈ pack/extracting/preparing/resolving/base/files/overrides/done */
  onPhase?: (p: ModpackProgress) => void;
}

/** 阶段进度详情（供 UI 显示进度条颗粒度 / 速度 / 字节 / 剩余时间）。 */
export interface ModpackProgress {
  phase: string;
  message: string;
  /** 单位计数（文件数等），无则 0。 */
  current: number;
  total: number;
  /** 字节进度（archive 下载 / 基础版本 / 文件批量），未知 0。 */
  bytesDone: number;
  bytesTotal: number;
  /** 当前速度 B/s，未知/空闲 0。 */
  speedBps: number;
  /** 剩余秒数，-1 未知。 */
  etaSeconds: number;
  /** 阶段内细粒度进度 0~1（base/files 用于驱动总进度条），未知 -1。 */
  innerProgress: number;
}

/** 安装结果。 */
export interface ModpackInstallResult {
  versionName: string;
  plan: ModpackPlan;
  missing: ModpackMissingItem[];
  warnings: string[];
  /** 整合包推荐 JVM 参数（user_jvm_args.txt 解析，空串=无）。 */
  recommendedJvmArgs: string;
  /** 推荐最大内存 MB（从 -Xmx 解析，0=无）。 */
  recommendedMaxMemMb: number;
}

/** reserveAndBuildBase_ 的返回：最终落地的版本名 + 目录。 */
interface VersionReservation {
  versionName: string;
  versionDir: string;
}

export class ModpackInstaller {
  /**
   * 归属的活动主键（活动账本 · L2-b）；0 = 不归属。
   * 由 ModpackInstallTask 用 view.startedAtMs 赋值。
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
  private ownedDmTaskIds_: number[] = [];
  private ownedBaseTasks_: McVersionTask[] = [];

  private rememberDmTask_(taskId: number): void {
    if (taskId > 0 && this.ownedDmTaskIds_.indexOf(taskId) < 0) {
      this.ownedDmTaskIds_.push(taskId);
    }
  }

  /** 释放本复合安装器历次 archive/icon/files/base 子任务的 native owner。 */
  purgeNativeOwners(): boolean {
    let retainedIds: number[] = [];
    let dm = DownloadManager.instance();
    for (let taskId of this.ownedDmTaskIds_) {
      let purged = false;
      try { purged = dm.purgeTask(taskId); } catch (e) { purged = false; }
      if (!purged) retainedIds.push(taskId);
    }
    this.ownedDmTaskIds_ = retainedIds;

    let retainedBase: McVersionTask[] = [];
    for (let task of this.ownedBaseTasks_) {
      let purged = false;
      try { purged = task.purgeNativeOwner(); } catch (e) { purged = false; }
      if (!purged) retainedBase.push(task);
    }
    this.ownedBaseTasks_ = retainedBase;
    return retainedIds.length === 0 && retainedBase.length === 0;
  }

  /**
   * 从 archive 安装整合包。
   * @throws Error 致命失败（解压失败 / 清单非法 / 基础版本建立失败）。文件级失败不抛，进 missing。
   */
  async installFromArchive(req: ModpackInstallRequest): Promise<ModpackInstallResult> {
    // 同一个 token 同时隔离归档下载与解压目录，避免并发安装互删同名 archive/解压产物。
    let stamp = Date.now().toString() + '-' + Math.floor(Math.random() * 1000000).toString();
    let tempDir = req.filesDir + '/modpack-temp/' + stamp;
    let archiveStagingDir = req.filesDir + '/modpack-cache/.staging-' + stamp;
    let archivePath = '';

    this.phase_(req, 'pack', '正在准备整合包文件...', 0, 1);

    // 本次新建的版本目录（仅致命失败时回滚清理；成功 / 文件级失败都保留）
    let createdVersionDir = '';
    try {
      // 0. 本地路径优先；在线归档只写本次安装独占的 staging，并由 finally 清理。
      archivePath = await this.resolveArchive_(req, archiveStagingDir, stamp);
      this.phase_(req, 'extracting', '正在解压整合包...', 0, 1);

      // 1. 解压
      try { removeDirRecursive(tempDir); } catch (e) { /* */ }
      ensureDir(tempDir);
      await decompressFile(archivePath, tempDir);
      // 解压后定位整合包根（支持清单在解压根或单层子目录里）+ 校验清单存在
      let baseDir = findModpackRoot(tempDir);
      if (baseDir.length === 0) {
        throw new Error('无效整合包：未找到 modrinth.index.json 或 manifest.json');
      }
      let manifestKind = detectManifestKind(baseDir);

      // 2. 解析
      this.phase_(req, 'preparing', '正在解析清单...', 0, 1);
      let parsed = parseManifestFromDir(baseDir, manifestKind);
      let plan = parsed.plan;
      let warnings = parsed.warnings;
      let missing: ModpackMissingItem[] = [];

      // CurseForge：文件无直链，先用解析器把 (projectID, fileID) → 下载 URL + 文件名
      if (plan.source === 'curseforge') {
        if (req.resolveCfFile === undefined) {
          throw new Error('CurseForge 整合包需要文件解析器（内部错误）');
        }
        this.phase_(req, 'resolving', '正在解析 CurseForge 文件...', 0, plan.files.length);
        await this.resolveCfFiles_(req, plan, missing);
      }

      // 3+4. 在基础版本构建锁内：算唯一名 + 占位目录 + 建带 loader 的隔离版本。
      //      去重与占位必须串行（见 baseBuildLock_ 注释），否则并发安装会算出同名互相覆盖。
      let baseName = (req.versionName !== undefined && req.versionName.length > 0) ? req.versionName : plan.name;
      this.phase_(req, 'base', '正在创建基础版本（含加载器）...', 0, 1);
      let reserved = await this.reserveAndBuildBase_(plan, baseName, req);
      let versionName = reserved.versionName;
      let versionDir = reserved.versionDir;
      createdVersionDir = versionDir;

      this.alog().info(TAG, `install start: name=${versionName} mc=${plan.gameVersion} loader=${plan.loaderType}/${plan.loaderVersion} files=${plan.files.length}`, LOG_DOMAIN_DOWNLOAD);

      // 4.5 清理残留：Fabric/Quilt 安装会按约定名(fabric-loader-<l>-<g>)另建一个版本目录,
      // 整合包用自定义版本名时它会变成残留。仅当该约定名版本是【本次新建】(不在 existingVersions)
      // 且 != 整合包版本名时删除,绝不误删用户原有的同名加载器版本。
      this.cleanupStrayLoaderVersion_(plan, versionName, req);

      // 5. 批量下文件 → versions/<name>/<file.path>
      let installedFiles: string[] = [];
      await this.downloadFiles_(req, plan, versionDir, missing, installedFiles);

      // 6. 铺 overrides（异步复制，避免大整合包上千文件同步复制阻塞 JS 线程）
      this.phase_(req, 'overrides', '正在应用覆盖文件...', 0, 1);
      let overrideFiles: string[] = [];
      for (let od of plan.overrideDirs) {
        let src = baseDir + '/' + od;
        if (dirExists(src)) {
          await copyTreeContents(src, versionDir, overrideFiles);
        }
      }

      // 6.5 特殊脚本/推荐参数（决策5）：解析 Forge user_jvm_args.txt（已随 overrides 落地）
      let post = processModpackLaunchConfig(versionDir);
      for (let n of post.notes) warnings.push(n);

      // 7. 写快照
      let snap: ModpackSnapshot = {
        source: plan.source,
        projectId: req.projectId,
        name: versionName,
        packVersion: plan.packVersion,
        gameVersion: plan.gameVersion,
        loaderType: plan.loaderType,
        loaderVersion: plan.loaderVersion,
        installedFiles,
        overrideFiles,
        missing,
        installedAt: Date.now(),
        recommendedJvmArgs: post.recommendedJvmArgs,
        recommendedMaxMemMb: post.recommendedMaxMemMb,
      };
      writeModpackSnapshot(versionDir, snap);

      // 下载整合包图标到版本目录（best-effort，供版本列表/详情显示；失败不影响安装）
      if (req.iconUrl !== undefined && req.iconUrl.length > 0) {
        await this.downloadIcon_(req.iconUrl, versionDir);
      }

      this.phase_(req, 'done', '整合包安装完成', 1, 1);
      this.alog().info(TAG, `install done: ${versionName} (${installedFiles.length} files, ${missing.length} missing)`, LOG_DOMAIN_DOWNLOAD);

      return {
        versionName, plan, missing, warnings,
        recommendedJvmArgs: post.recommendedJvmArgs,
        recommendedMaxMemMb: post.recommendedMaxMemMb,
      };
    } catch (e) {
      // 致命失败：回滚本次新建的半成品版本目录，避免版本列表里残留坏版本。
      // 名字是本次去重后保证唯一、不在 existingVersions 的，删它不会动用户原有版本。
      if (createdVersionDir.length > 0) {
        try { removeDirRecursive(createdVersionDir); } catch (ee) { /* */ }
      }
      throw e as Error;
    } finally {
      // 8. 只清理本次安装独占的目录；本地导入 archive 从未位于其中，不会被误删。
      try { removeDirRecursive(tempDir); } catch (e) { /* */ }
      try { removeDirRecursive(archiveStagingDir); } catch (e) { /* */ }
    }
  }

  // ============================================================
  //  内部
  // ============================================================

  /**
   * 解析出可用的本地 archive 路径：
   * - 若 req.archivePath 指向存在的文件 → 直接用（本地导入）。
   * - 否则下载到本次安装独占的 archiveStagingDir，finally 必定清理。
   */
  private async resolveArchive_(req: ModpackInstallRequest, archiveStagingDir: string,
    installToken: string): Promise<string> {
    if (req.archivePath !== undefined && req.archivePath.length > 0 && fileExists(req.archivePath)) {
      return req.archivePath;
    }
    let url = req.archiveUrl ?? '';
    if (url.length === 0) {
      throw new Error('整合包来源无效：缺少本地路径与下载地址');
    }
    let filename = req.archiveFilename ?? '';
    if (filename.length === 0) {
      let q = url.indexOf('?');
      let clean = q >= 0 ? url.substring(0, q) : url;
      filename = clean.substring(clean.lastIndexOf('/') + 1);
      if (filename.length === 0) filename = 'modpack.mrpack';
    }
    let safeArchiveFilename = safeBaseName(filename);
    if (safeArchiveFilename.length === 0 || safeArchiveFilename !== filename) {
      throw new Error('整合包 archiveFilename 不安全');
    }
    filename = safeArchiveFilename;
    // 每次安装使用独占目录；不要在共享 cache 中 unlink 固定文件名，否则并发安装会互删。
    ensureDir(archiveStagingDir);
    let dest = archiveStagingDir + '/' + filename;

    this.phase_(req, 'pack', '正在下载整合包文件...', 0, 1);
    // 多源容错：archiveUrl 主源 + archiveMirrors 备源（对齐 ModInstaller 多源策略）
    let archiveUrls: string[] = [url];
    if (req.archiveMirrors !== undefined) {
      for (let m of req.archiveMirrors) {
        if (m.length > 0 && archiveUrls.indexOf(m) < 0) archiveUrls.push(m);
      }
    }
    let archiveSpecFile: DownloadFileSpec = {
      localPath: dest,
      urls: archiveUrls,
      allowedRoot: archiveStagingDir,
    };
    // 多源才多段（对齐 ModInstaller：单源不设 maxConnections，避免单源多段 Range 边界）
    if (archiveUrls.length > 1) archiveSpecFile.maxConnections = 8;
    let spec: DownloadTaskSpec = {
      name: 'modpack-archive: ' + filename + ' [' + installToken + ']',
      files: [archiveSpecFile],
      activityId: this.activityId,
    };
    try {
      await DownloadManager.instance().createAndWait(spec, (v: DownloadTaskView): void => {
        this.rememberDmTask_(v.taskId);
        let inner = v.bytesTotal > 0 ? v.bytesDone / v.bytesTotal : -1;
        this.phase_(req, 'pack', '正在下载整合包文件...', 0, 1,
          v.bytesDone, v.bytesTotal, v.speedBps, v.etaSeconds, inner);
      });
    } catch (e) {
      let err = e as Error;
      throw new Error('整合包文件下载失败：' + (err.message !== undefined ? err.message : String(e)));
    }
    return dest;
  }

  /**
   * 解析 CurseForge 文件：把每个 (cfProjectId, cfFileId) → 下载 URL + 文件名，
   * 填回 file.urls / file.path（mods/<filename>）。解析失败的进 missing 并从 plan.files 移除。
   * 限并发避免打爆 API。
   */
  private async resolveCfFiles_(req: ModpackInstallRequest, plan: ModpackPlan, missing: ModpackMissingItem[]): Promise<void> {
    let resolver = req.resolveCfFile!;
    let CONCURRENCY = 8;
    let resolved: ModpackFile[] = [];
    let idx = 0;
    let done = 0;
    let total = plan.files.length;
    let worker = async (): Promise<void> => {
      while (true) {
        let i = idx;
        idx++;
        if (i >= plan.files.length) break;
        let f = plan.files[i];
        if (f.cfProjectId === undefined || f.cfFileId === undefined) {
          // 理论上 CF 解析器保证 id 存在；防御性记入缺失，且推进进度避免卡在 <100%
          missing.push({ name: f.fileNameHint ?? 'CurseForge 文件', reason: '缺少 projectID/fileID（清单异常）' });
          done++;
          this.phase_(req, 'resolving', '正在解析 CurseForge 文件...', done, total);
          continue;
        }
        try {
          let r: CfFileResolution = await resolver(f.cfProjectId, f.cfFileId, plan.gameVersion, plan.loaderType as string);
          let fname: string = safeBaseName(r.filename);
          if (r.urls.length === 0 || fname.length === 0) {
            missing.push({ name: f.fileNameHint ?? ('CF ' + f.cfProjectId + '/' + f.cfFileId), reason: 'CurseForge 未返回下载地址（作者可能禁用第三方下载）' });
          } else {
            f.urls = r.urls;
            f.size = r.size;
            f.sha1 = r.sha1;
            f.path = 'mods/' + fname;
            f.fileNameHint = fname;
            resolved.push(f);
          }
        } catch (e) {
          let err = e as Error;
          missing.push({ name: f.fileNameHint ?? ('CF ' + f.cfProjectId + '/' + f.cfFileId), reason: (err.message !== undefined && err.message.length > 0) ? err.message : 'CurseForge 解析失败' });
        }
        done++;
        this.phase_(req, 'resolving', '正在解析 CurseForge 文件...', done, total);
      }
    };
    let workers: Promise<void>[] = [];
    let n = Math.min(CONCURRENCY, plan.files.length);
    for (let k = 0; k < n; k++) workers.push(worker());
    await Promise.all(workers);
    plan.files = resolved;
    this.alog().info(TAG, `CF resolve: ${resolved.length} ok, ${missing.length} failed`, LOG_DOMAIN_DOWNLOAD);
  }

  /** 下载整合包图标到版本目录（best-effort，失败仅告警）。 */
  private async downloadIcon_(url: string, versionDir: string): Promise<void> {
    let dest = versionDir + '/' + MODPACK_ICON_FILE;
    let spec: DownloadTaskSpec = {
      name: 'modpack-icon: ' + versionDir.substring(versionDir.lastIndexOf('/') + 1),
      files: [{ localPath: dest, urls: [url], allowedRoot: versionDir }],
      activityId: this.activityId,
    };
    try {
      await DownloadManager.instance().createAndWait(spec, (v: DownloadTaskView): void => {
        this.rememberDmTask_(v.taskId);
      });
    } catch (e) {
      let err = e as Error;
      this.alog().warn(TAG, `modpack icon download failed: ${err.message}`, null, LOG_DOMAIN_DOWNLOAD);
    }
  }

  /**
   * 在基础版本构建锁内完成：算唯一版本名 → 占位目录 → 建带 loader 的隔离版本。
   *
   * 去重必须串行且基于**磁盘实际目录**（叠加 req.existingVersions）：调用方传入的
   * existingVersions 是任务创建时的快照，并发安装时会过期，两个安装会算出同名互相覆盖。
   * 锁内先 mkdir 占位，后到的安装在 listFileSync 时即可看到，从而拿到下一个序号。
   * 失败抛错（基础版本是硬前提）。
   */
  private async reserveAndBuildBase_(plan: ModpackPlan, baseName: string, req: ModpackInstallRequest):
    Promise<VersionReservation> {
    let loaderType: ModLoaderType | null = toModLoaderType(plan.loaderType);
    // 串行化：共享 download-temp + Forge 嵌入式 JVM 不可并发（见 baseBuildLock_ 注释）
    let release: () => void = () => {};
    let prev = baseBuildLock_;
    baseBuildLock_ = new Promise<void>((resolve: () => void) => { release = resolve; });
    await prev;

    let versionName = '';
    let versionDir = '';
    try {
      // 去重集合 = 调用方快照 ∪ 磁盘实际版本目录（杜绝并发撞名）
      let existing = new Set<string>();
      for (let e of req.existingVersions) existing.add(e);
      try {
        let dirs = fs.listFileSync(req.mcDir + '/versions');
        for (let d of dirs) existing.add(d);
      } catch (e) { /* versions 目录可能尚不存在 */ }
      let existingArr: string[] = [];
      existing.forEach((v: string): void => { existingArr.push(v); });

      versionName = uniqueVersionName(sanitizeVersionName(baseName), existingArr);
      versionDir = req.mcDir + '/versions/' + versionName;
      ensureDir(versionDir);  // 锁内立即占位，后到的并发安装看得到 → 不会撞名

      let task = new McVersionTask(plan.gameVersion, loaderType, plan.loaderVersion, versionName, req.mcDir, req.filesDir);
      this.ownedBaseTasks_.push(task);
      // 转发基础版本下载的细粒度进度（含 loader），让 base 阶段进度条不再卡死、显示速度
      task.onProgress = (mv: UnifiedTaskView): void => {
        let label = mv.currentLabel.length > 0 ? ('基础版本：' + mv.currentLabel) : '正在创建基础版本（含加载器）...';
        let inner = mv.progress > 0 ? mv.progress / 100 : -1;
        this.phase_(req, 'base', label, mv.filesDone, mv.filesTotal,
          mv.bytesDone, mv.bytesTotal, mv.speedBps, mv.etaSeconds, inner);
      };
      await task.start();
    } catch (e) {
      // 建版本失败：释放占位目录，把名字让出来
      if (versionDir.length > 0) {
        try { removeDirRecursive(versionDir); } catch (ee) { /* */ }
      }
      let err = e as Error;
      throw new Error('创建基础版本失败：' + (err.message !== undefined ? err.message : String(e)));
    } finally {
      release();
    }
    return { versionName, versionDir };
  }

  /**
   * 清理 Fabric/Quilt 安装按约定名(fabric-loader-<l>-<g> / quilt-loader-<l>-<g>)另建的版本目录残留。
   * Forge/NeoForge 走沙箱不产生残留；vanilla 无 loader 目录。
   * 仅删【本次新建】(不在 existingVersions) 且 != 整合包版本名的目录，绝不动用户原有版本。
   */
  private cleanupStrayLoaderVersion_(plan: ModpackPlan, versionName: string, req: ModpackInstallRequest): void {
    let prefix = '';
    if (plan.loaderType === ModpackLoader.FABRIC) prefix = 'fabric-loader-';
    else if (plan.loaderType === ModpackLoader.QUILT) prefix = 'quilt-loader-';
    else return;
    if (plan.loaderVersion.length === 0) return;
    let conventionId = prefix + plan.loaderVersion + '-' + plan.gameVersion;
    if (conventionId === versionName) return;  // 与目标重合，就是目标本身
    for (let ev of req.existingVersions) {
      if (ev === conventionId) return;  // 用户原有版本，不动
    }
    let strayDir = req.mcDir + '/versions/' + conventionId;
    if (dirExists(strayDir)) {
      try {
        removeDirRecursive(strayDir);
        this.alog().info(TAG, `cleaned stray loader version: ${conventionId}`, LOG_DOMAIN_DOWNLOAD);
      } catch (e) {
        let err = e as Error;
        this.alog().warn(TAG, `cleanup stray loader version failed: ${conventionId}`, err, LOG_DOMAIN_DOWNLOAD);
      }
    }
  }

  /**
   * 批量下载整合包文件到 versionDir/<file.path>。
   * 失败文件进 missing（决策4），不抛错。
   */
  private async downloadFiles_(req: ModpackInstallRequest, plan: ModpackPlan, versionDir: string,
    missing: ModpackMissingItem[], installedFiles: string[]): Promise<void> {
    // 过滤掉无 URL 的（理论上 Modrinth 都有；防御）
    let files: ModpackFile[] = [];
    for (let f of plan.files) {
      if (f.urls.length === 0) {
        missing.push({ name: f.fileNameHint ?? f.path, reason: '无可用下载地址' });
        continue;
      }
      // 写时再校验一次路径安全（防 zip-slip / CF 文件名穿越；解析阶段已校验，这里兜底）
      let safe = safeRelPath(f.path);
      if (safe.length === 0) {
        missing.push({ name: f.fileNameHint ?? f.path, reason: '非法文件路径，已跳过' });
        continue;
      }
      f.path = safe;
      files.push(f);
    }
    if (files.length === 0) return;

    // 预创建父目录（引擎一般会建，但保险）
    let specs: DownloadFileSpec[] = [];
    for (let f of files) {
      let localPath = versionDir + '/' + f.path;
      ensureParentDir(localPath);
      // 套用下载底层能力：Modrinth 清单只给官方 cdn.modrinth.com 直链，追加 mcim 镜像兜底
      // （官方优先，对齐 ModInstaller 的 OFFICIAL_FIRST；CF 文件 urls 已含镜像，不动）。
      let urls: string[] = f.urls.slice();
      if (plan.source === 'modrinth') {
        for (let u of f.urls) {
          let m = mirrorifyModrinthCdn(u);
          if (m !== u && urls.indexOf(m) < 0) urls.push(m);
        }
      }
      let spec: DownloadFileSpec = { localPath, urls, allowedRoot: versionDir };
      if (urls.length > 1) spec.maxConnections = 8;
      if (f.sha1 !== undefined && f.sha1.length > 0) {
        let check: DownloadCheck = { sha1: f.sha1, size: f.size };
        spec.check = check;
      } else if (f.size > 0) {
        let check: DownloadCheck = { size: f.size };
        spec.check = check;
      }
      specs.push(spec);
    }

    this.phase_(req, 'files', '正在下载模组/资源（' + specs.length + ' 个文件）...', 0, specs.length);

    let dirBase = versionDir.substring(versionDir.lastIndexOf('/') + 1);
    let taskName = 'modpack-files: ' + dirBase + ' [' + specs.length + ']';
    let taskSpec: DownloadTaskSpec = { name: taskName, files: specs };

    // 捕获最终 view（失败时也能读 failedFiles）
    let finalView: DownloadTaskView | null = null;
    let onProgress = (v: DownloadTaskView): void => {
      this.rememberDmTask_(v.taskId);
      finalView = v;
      let inner = v.filesTotal > 0 ? v.filesDone / v.filesTotal : -1;
      this.phase_(req, 'files', '正在下载模组/资源...', v.filesDone, v.filesTotal,
        v.bytesDone, v.bytesTotal, v.speedBps, v.etaSeconds, inner);
    };

    let batchFailed = false;
    try {
      let view = await DownloadManager.instance().createAndWait(taskSpec, onProgress);
      finalView = view;
    } catch (e) {
      // 批量里有文件失败 → reject，但成功的已落地；从 finalView.failedFiles 提缺失项
      batchFailed = true;
      let err = e as Error;
      if (err.message === '已取消') {
        throw new Error('整合包安装已取消');
      }
      this.alog().warn(TAG, `modpack file batch had failures: ${err.message}`, null, LOG_DOMAIN_DOWNLOAD);
    }

    // 汇总：失败文件进 missing；其余视为已装
    // 先建 localPath → 直链 映射，失败时把原始下载地址带进 missing.url（供用户手动补齐）
    let urlByPath = new Map<string, string>();
    for (let f of files) {
      if (f.urls.length > 0) urlByPath.set(versionDir + '/' + f.path, f.urls[0]);
    }
    let failedPaths = new Set<string>();
    if (finalView !== null) {
      let fv: DownloadTaskView = finalView;
      let failed: DownloadFailedFile[] = fv.failedFiles;
      for (let ff of failed) {
        failedPaths.add(ff.localPath);
        let reason = (ff.lastError !== undefined && ff.lastError.message !== undefined && ff.lastError.message.length > 0)
          ? ff.lastError.message : '下载失败';
        let item: ModpackMissingItem = { name: ff.basename, reason };
        let u = urlByPath.get(ff.localPath);
        if (u !== undefined && u.length > 0) item.url = u;
        missing.push(item);
      }
    }
    // 批量失败但拿不到 finalView（createAndWait 在任何 onProgress 之前 reject）时，
    // failedFiles 无从获取。此时绝不能把全部文件当作已安装——改为磁盘存在性作为权威判据：
    // 只有确实落盘的文件才计入 installedFiles，其余进 missing，避免"零 mod 却报完整安装"。
    let trustView = finalView !== null;
    for (let f of files) {
      let localPath = versionDir + '/' + f.path;
      if (failedPaths.has(localPath)) continue;
      let onDisk = false;
      try { onDisk = fs.statSync(localPath).size > 0; } catch (e) { onDisk = false; }
      if (trustView && !batchFailed) {
        // 正常成功路径：view 已确认终态，沿用原逻辑（未列入 failed 即视为已装）。
        installedFiles.push(f.path);
      } else if (onDisk) {
        installedFiles.push(f.path);
      } else {
        let item: ModpackMissingItem = { name: f.path, reason: '下载失败或文件缺失' };
        let u = urlByPath.get(localPath);
        if (u !== undefined && u.length > 0) item.url = u;
        missing.push(item);
      }
    }
  }

  private phase_(req: ModpackInstallRequest, phase: string, message: string, current: number, total: number,
    bytesDone?: number, bytesTotal?: number, speedBps?: number, etaSeconds?: number, innerProgress?: number): void {
    if (req.onPhase !== undefined) {
      let p: ModpackProgress = {
        phase, message, current, total,
        bytesDone: bytesDone ?? 0,
        bytesTotal: bytesTotal ?? 0,
        speedBps: speedBps ?? 0,
        etaSeconds: etaSeconds ?? -1,
        innerProgress: innerProgress ?? -1,
      };
      try { req.onPhase(p); } catch (e) { /* */ }
    }
  }
}

// ============================================================
//  模块工具
// ============================================================

/** ModpackLoader → feature_core ModLoaderType（NONE→null=原版）。 */
export function toModLoaderType(l: ModpackLoader): ModLoaderType | null {
  switch (l) {
    case ModpackLoader.FABRIC:   return ModLoaderType.FABRIC;
    case ModpackLoader.FORGE:    return ModLoaderType.FORGE;
    case ModpackLoader.NEOFORGE: return ModLoaderType.NEOFORGE;
    case ModpackLoader.QUILT:    return ModLoaderType.QUILT;
    default:                     return null;
  }
}

/** 探测临时目录里的清单类型。 */
export function detectManifestKind(dir: string): string {
  if (fileExists(dir + '/modrinth.index.json')) return 'modrinth';
  if (fileExists(dir + '/manifest.json')) return 'curseforge';
  return 'none';
}

/**
 * 找到整合包真正的根目录：清单可能在解压根，也可能整体包在单层子目录里
 * （如 `PackName/modrinth.index.json` + `PackName/overrides/`）。对齐 PCL2 的
 * ArchiveBaseFolder 处理，避免这类包被误判为"无效整合包"。
 * @returns 含清单的目录绝对路径；找不到返回空串。
 */
export function findModpackRoot(tempDir: string): string {
  if (detectManifestKind(tempDir) !== 'none') return tempDir;
  let entries: string[] = [];
  try { entries = fs.listFileSync(tempDir); } catch (e) { return ''; }
  for (let name of entries) {
    let sub = tempDir + '/' + name;
    let isDir = false;
    try { isDir = fs.statSync(sub).isDirectory(); } catch (e) { continue; }
    if (isDir && detectManifestKind(sub) !== 'none') return sub;
  }
  return '';
}

function parseManifestFromDir(dir: string, kind: string) {
  if (kind === 'modrinth') {
    return parseModrinthIndex(fs.readTextSync(dir + '/modrinth.index.json'));
  }
  return parseCurseForgeManifest(fs.readTextSync(dir + '/manifest.json'));
}

/** 版本名非法字符替换（与文件系统目录名安全）。 */
export function sanitizeVersionName(name: string): string {
  // 非法字符、控制字符 + 启动链路破坏字符统一替换；点段最终由 canonical basename 拒绝。
  let out = name.replace(/[\\/:*?"<>|!;\x00-\x1f\x7f]/g, '_').trim();
  if (out.length === 0 || safeBaseName(out) !== out) out = '整合包';
  return out;
}

/** 与已存在版本名去重：冲突时追加 ' (2)' / ' (3)' ... */
export function uniqueVersionName(base: string, existing: string[]): string {
  let set = new Set<string>();
  for (let e of existing) set.add(e);
  if (!set.has(base)) return base;
  let i = 2;
  while (set.has(base + ' (' + i + ')')) i++;
  return base + ' (' + i + ')';
}

function fileExists(path: string): boolean {
  try { return fs.statSync(path).isFile(); } catch (e) { return false; }
}

function dirExists(path: string): boolean {
  try { return fs.statSync(path).isDirectory(); } catch (e) { return false; }
}

function ensureDir(dir: string): void {
  try { fs.mkdirSync(dir, true); }
  catch (e) {
    try { if (fs.statSync(dir).isDirectory()) return; } catch (ee) { /* */ }
    throw new Error('mkdir failed: ' + dir);
  }
}

/** 为某文件路径创建父目录。 */
function ensureParentDir(filePath: string): void {
  let i = filePath.lastIndexOf('/');
  if (i <= 0) return;
  ensureDir(filePath.substring(0, i));
}

/**
 * 把 srcDir 的**内容**递归复制进 destDir（不含 srcDir 本身那层）。
 * 文件覆盖已存在的（client-overrides 覆盖 overrides）。
 * relPaths 收集复制下的文件实例相对路径（供快照/更新清理用）。
 * 用异步 fs.copyFile：大整合包（上千 config/kubejs 文件）不再同步阻塞 JS 线程。
 */
async function copyTreeContents(srcDir: string, destDir: string, relPaths: string[]): Promise<void> {
  await copyTreeInto_(srcDir, destDir, '', relPaths);
}

async function copyTreeInto_(srcDir: string, destDir: string, relPrefix: string, relPaths: string[]): Promise<void> {
  let srcRoot = fs.lstatSync(srcDir);
  if (srcRoot.isSymbolicLink() || !srcRoot.isDirectory()) {
    throw new Error('override 复制源不是普通目录');
  }
  ensureDir(destDir);
  let destRoot = fs.lstatSync(destDir);
  if (destRoot.isSymbolicLink() || !destRoot.isDirectory()) {
    throw new Error('override 复制目标不是普通目录');
  }
  let entries = fs.listFileSync(srcDir);
  for (let name of entries) {
    if (safeBaseName(name) !== name) throw new Error('override 包含非法文件名');
    let src = srcDir + '/' + name;
    let dst = destDir + '/' + name;
    let rel = relPrefix.length > 0 ? relPrefix + '/' + name : name;
    if (safeRelPath(rel) !== rel) throw new Error('override 相对路径不安全');
    let st = fs.lstatSync(src);
    if (st.isSymbolicLink()) throw new Error('拒绝复制 override 符号链接: ' + rel);
    if (st.isDirectory()) {
      await copyTreeInto_(src, dst, rel, relPaths);
    } else if (st.isFile()) {
      // 仅允许覆盖既有普通文件；拒绝跟随目标符号链接或覆盖目录/特殊文件。
      try {
        let existing = fs.lstatSync(dst);
        if (existing.isSymbolicLink() || !existing.isFile()) {
          throw new Error('override 复制目标存在非普通文件: ' + rel);
        }
      } catch (e) {
        let message = (e as Error).message;
        if (message.indexOf('override 复制目标存在非普通文件') >= 0) throw e as Error;
        // lstat 不存在时由 copyFile 创建；权限等错误会在 copyFile 阶段继续抛出。
      }
      await fs.copyFile(src, dst);
      let copied = fs.lstatSync(dst);
      if (copied.isSymbolicLink() || !copied.isFile() || copied.size !== st.size) {
        throw new Error('override 复制后类型或大小校验失败: ' + rel);
      }
      relPaths.push(rel);
    } else {
      throw new Error('拒绝复制 override 非普通文件: ' + rel);
    }
  }
}

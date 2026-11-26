/**
 * 整合包安装编排器：持久准备清单、确认选择、独占实例安装和原实例补齐。
 * 安装只持有数据和服务；页面可随时销毁。取消先等待下载/解压/基础版本收敛，再清理自有材料。
 * 缺失文件保留精确身份并提交部分收据；目录、格式或持久记录错误属于致命失败，保留恢复现场。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ActivityLogger, LOG_DOMAIN_DOWNLOAD, ensureDirSync, removeDirRecursive,
  MODPACK_PENDING_FILE } from 'commons';
import { DownloadManager, DownloadFileSpec, DownloadTaskSpec, DownloadTaskView,
  McVersionTask, ModLoaderType, decompressFile, UnifiedTaskView, computeFileSha1, computeFileSha512,
  claimVersionInstall, newVersionInstallOwner, isSupportedInstallerLoader } from 'feature_core';
import { ModpackPlan, ModpackFile, ModpackLoader, ModpackEnv, ModpackProblem,
  parseModrinthIndex, parseCurseForgeManifest, safeRelPath, safeBaseName, modpackFileKey } from './ModpackManifest';
import { ModpackPackageCandidate, discoverModpackPackages, materializeModpackPackage, preflightModpackArchive } from './ModpackPackage';
import { parseInstancePackage, discoverInstanceDataRoots, isInstanceContentPath } from './ModpackInstance';
import { buildModpackDownloadUrls } from './ModpackDownloadUrls';
import { ModpackSnapshot, ModpackMissingItem, writeModpackSnapshot, readModpackSnapshot,
  MODPACK_ICON_FILE, MODPACK_SNAPSHOT_FILE } from './ModpackSnapshot';
import { processModpackLaunchConfig } from './ModpackPostProcessor';
import { ModpackInstallSession, ModpackOverrideReceipt, modpackWorkDir, saveModpackSession, loadModpackSession,
  recoverModpackSessionForWrite, loadRecoveryPreview, hasModpackOverrideJournalEvidence, cleanupDismissedModpackWork, releaseLegacyModpackImport,
  writeModpackJsonAtomic, ModpackSourceReceipt, saveModpackSource, loadModpackSource, ModpackRecoveryKind,
  assertModpackRecoveryAvailable, readModpackRecoveryDismissal, saveModpackRecoveryDismissal } from './ModpackInstallSession';
import { assertNoModpackJournalWriter } from './ModpackOverrideJournal';
import { disableFilename } from './ModInstaller';

const TAG = 'ModpackInstaller';
/** CF 文件的精确解析结果；目录来自模块/项目元数据，绝不把 ZIP 一律塞进 mods。 */
export interface CfFileResolution {
  size: number;
  sha1?: string;
  urls: string[];
  filename: string;
  targetDirectory: string;
}
export type CfFileResolver = (projectId: number, fileId: number, gameVersion: string, loader: string) => Promise<CfFileResolution>;

/** 一次安装的不可变来源上下文。sessionId 用于重试/进程恢复，不能用显示标题当身份。 */
export interface ModpackInstallRequest {
  /** 仅正文使用源站；自家网关仍可用。入队后和恢复记录合并，不能在重试时隐式放宽。 */
  officialFilesOnly?: boolean;
  archivePath?: string;
  archiveUrl?: string;
  archiveMirrors?: string[];
  archiveFilename?: string;
  displayName?: string;
  archiveSha1?: string;
  archiveSha512?: string;
  archiveSize?: number;
  mcDir: string;
  filesDir: string;
  existingVersions: string[];
  versionName?: string;
  projectId?: string;
  sourceVersionId?: string;
  sessionId?: string;
  iconUrl?: string;
  selectedOptional?: string[];
  resolveCfFile?: CfFileResolver;
  onPhase?: (p: ModpackProgress) => void;
}
export interface ModpackProgress {
  phase: string;
  message: string;
  current: number;
  total: number;
  bytesDone: number;
  bytesTotal: number;
  speedBps: number;
  etaSeconds: number;
  innerProgress: number;
}
export interface ModpackInstallResult {
  versionName: string;
  plan: ModpackPlan;
  missing: ModpackMissingItem[];
  warnings: string[];
  recommendedJvmArgs: string;
  recommendedMaxMemMb: number;
}
/** 实例标记只包含 owner；完整计划保存在应用私有工作根。 */
interface ModpackPendingOwner { id: string; }

export class ModpackInstaller {
  activityId: number = 0;
  private session_: ModpackInstallSession | undefined = undefined;
  private cancelled_: boolean = false;
  private dmIds_: number[] = [];
  private baseTasks_: McVersionTask[] = [];
  private activeBase_: McVersionTask | undefined = undefined;

  getSession(): ModpackInstallSession | undefined { return this.session_; }
  beginAttempt(): void { this.cancelled_ = false; }
  isCancelled(): boolean { return this.cancelled_; }

  /** 只发取消请求；调用方仍须等待当前执行 Promise 和 native owner 释放后再允许删除。 */
  requestCancel(): void {
    this.cancelled_ = true;
    for (let id of this.dmIds_) { try { DownloadManager.instance().cancel(id); } catch (e) { /* 已结束 */ } }
    const base = this.activeBase_;
    if (base !== undefined) base.cancel(false).catch((): void => {});
  }

  private checkCancelled_(): void {
    if (this.cancelled_) throw new Error('整合包安装已取消');
  }

  /** 保留无法释放的 owner；失败时上层不得清理或启动下一轮。 */
  purgeNativeOwners(): boolean {
    let ids: number[] = [];
    for (let id of this.dmIds_) {
      let done = false;
      try { done = DownloadManager.instance().purgeTask(id); } catch (e) { /* 保留 */ }
      if (!done) ids.push(id);
    }
    this.dmIds_ = ids;
    let bases: McVersionTask[] = [];
    for (let base of this.baseTasks_) {
      let done = false;
      try { done = base.purgeNativeOwner(); } catch (_) { /* 基础任务的桥异常同样保留owner。 */ }
      if (!done) bases.push(base);
    }
    this.baseTasks_ = bases;
    return ids.length === 0 && bases.length === 0;
  }

  /**
   * native 终态通知不等于文件句柄已释放。执行中的 prepare/execute/cancel 调用栈
   * 默认持续持有 Registry/实例预约，直到所有 dmId 和基础安装 owner 实际退出。
   * 显式只探测清理的调用者可传 false，维持原约30秒失败且不删除材料的行为；
   * purgeNativeOwners 仍是同步、可拒绝的清理入口，不将有限超时伪装成空闲。
   */
  async settleNativeOwners(retainOwner: boolean = true): Promise<void> {
    let attempt = 0;
    while (true) {
      if (this.purgeNativeOwners()) return;
      if (!retainOwner && attempt >= 120) throw new Error('整合包下载仍在收敛，已保留文件，请稍后继续');
      if (retainOwner) {
        // 先等当前全部直接文件 ID；循环重新核验基础安装 owner，不能清空其集合
        // 或仅等待 activeBase_，后者可早于基础 Native 的真正收尾被解除。
        for (const id of this.dmIds_.slice()) await DownloadManager.instance().awaitTaskReleased(id, true);
        if (this.purgeNativeOwners()) return;
        if (attempt === 120) {
          try { new ActivityLogger(this.activityId).warn(TAG,
            '整合包 owner 收敛超过30秒，继续保留执行资格和实例预约', null, LOG_DOMAIN_DOWNLOAD); }
          catch (_) { /* 诊断日志失败不能放走仍持有资源的执行栈。 */ }
        }
      }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 250); });
      attempt++;
    }
  }

  private remember_(id: number): void {
    if (id > 0 && this.dmIds_.indexOf(id) < 0) this.dmIds_.push(id);
    if (this.cancelled_) { try { DownloadManager.instance().cancel(id); } catch (e) { /* 已结束 */ } }
  }

  /**
   * 下载并验证归档、解析清单与 CF 文件信息，然后原子保存可确认的计划。
   * 已有 session 只从原工作根恢复；不会重新选择包版本或另建 (2) 实例。
   */
  async prepare(req: ModpackInstallRequest): Promise<ModpackInstallSession> {
    const id = this.session_?.id ?? req.sessionId ?? newVersionInstallOwner();
    assertModpackRecoveryAvailable(req.filesDir, id);
    if (this.session_ !== undefined) {
      this.retargetInstance_(req, this.session_);
      return this.finishPackagePreparation_(req, this.session_);
    }
    let work = modpackWorkDir(req.filesDir, id);
    if (fileExists(work + '/session.json')) {
      // 只有用户实际发起恢复才在原执行环境校验和归并旧 WAL。浏览列表不进入这个写入口。
      let restored = recoverModpackSessionForWrite(req.filesDir, id);
      if (req.versionName !== undefined && req.versionName.length > 0 && safeBaseName(req.versionName) === req.versionName) {
        // 用户可在版本管理中重命名实例；只有新目录收据的安装身份相同才允许迁移恢复指针。
        let moved = readModpackSnapshot(req.mcDir + '/versions/' + req.versionName);
        if (moved?.installId === id) { restored.versionName = req.versionName; restored.mcDir = req.mcDir; }
      }
      if (restored.mcDir !== req.mcDir) throw new Error('恢复计划与当前安装根不一致');
      // 新计划把用户在下载详情选择的名称和包作者名称分开保存。旧会话没有此字段时，
      // 继续使用它原有的最终目录/清单名，不能套用今天的默认名重建另一实例。
      req.versionName = restored.requestedVersionName ?? req.versionName;
      req.officialFilesOnly = req.officialFilesOnly === true || restored.officialFilesOnly === true;
      if (req.officialFilesOnly === true && restored.officialFilesOnly !== true) {
        // 已准备好且等待可选内容确认的旧计划会提前返回；收紧策略必须先刷盘，不能
        // 等进入下载阶段才保存，否则用户确认前退出、再次恢复自动档时会丢失约束。
        restored.officialFilesOnly = true;
        saveModpackSession(req.filesDir, restored);
      }
      this.session_ = restored;
      this.retargetInstance_(req, restored);
      return this.finishPackagePreparation_(req, restored);
    }
    ensureDirSync(work);
    if (fileExists(work + '/source.json')) {
      let saved = loadModpackSource(req.filesDir, id);
      if (saved.mcDir !== req.mcDir) throw new Error('归档恢复来源与安装根不一致');
      req.archivePath = saved.archivePath; req.archiveUrl = saved.archiveUrl;
      req.archiveMirrors = saved.archiveMirrors; req.archiveSha1 = saved.archiveSha1;
      req.archiveSha512 = saved.archiveSha512; req.archiveSize = saved.archiveSize;
      req.projectId = saved.projectId; req.sourceVersionId = saved.sourceVersionId; req.iconUrl = saved.iconUrl;
      req.versionName = saved.requestedVersionName ?? req.versionName;
      req.officialFilesOnly = req.officialFilesOnly === true || saved.officialFilesOnly === true;
      if (req.officialFilesOnly === true && saved.officialFilesOnly !== true) {
        // 冷恢复时允许收紧旧归档的策略，并在任何新网络请求之前持久化；再次退出后
        // 即使页面回到自动档，也不能丢掉用户已经选择的更严格约束。
        saved.officialFilesOnly = true;
        saveModpackSource(req.filesDir, saved);
      }
    } else {
      let source: ModpackSourceReceipt = { schemaVersion: 1, id: id, mcDir: req.mcDir,
        title: req.displayName ?? req.archiveFilename ?? '整合包', requestedVersionName: req.versionName,
        officialFilesOnly: req.officialFilesOnly === true,
        archivePath: req.archivePath,
        archiveUrl: req.archiveUrl, archiveMirrors: req.archiveMirrors, archiveSha1: req.archiveSha1,
        archiveSha512: req.archiveSha512, archiveSize: req.archiveSize, projectId: req.projectId,
        sourceVersionId: req.sourceVersionId, iconUrl: req.iconUrl };
      saveModpackSource(req.filesDir, source);
    }
    this.checkCancelled_();
    this.phase_(req, 'pack', '正在准备整合包归档', 0, 1);
    let archive = work + '/archive.zip';
    if (req.archivePath !== undefined && req.archivePath.length > 0) {
      // 选择器已直接交付本任务归档；旧来源和其他借读文件仍需复制。
      if (req.archivePath !== archive) await fs.copyFile(req.archivePath, archive);
    } else {
      if ((req.archiveUrl ?? '').length === 0) throw new Error('整合包来源无效');
      let urls: string[] = [req.archiveUrl!];
      for (let url of (req.archiveMirrors ?? [])) if (urls.indexOf(url) < 0) urls.push(url);
      urls = buildModpackDownloadUrls(urls, false, req.officialFilesOnly === true);
      if (urls.length === 0) throw new Error('仅源站模式下没有可用的官方归档地址，请重新选择来源');
      let file: DownloadFileSpec = { localPath: archive, allowedRoot: work, urls: urls,
        check: { sha1: req.archiveSha1, size: req.archiveSize } };
      let spec: DownloadTaskSpec = { name: 'modpack-archive:' + id, files: [file], activityId: this.activityId };
      await DownloadManager.instance().createAndWait(spec, (view: DownloadTaskView): void => {
        this.remember_(view.taskId);
        this.phase_(req, 'pack', '正在下载整合包归档', view.filesDone, view.filesTotal, view);
      });
    }
    await this.settleNativeOwners();
    this.checkCancelled_();
    // 本地输入也核对已提供的归档元数据；SHA-1 已足以绑定来源归档和其中 overrides。
    if (req.archiveSize !== undefined && req.archiveSize > 0 && fs.statSync(archive).size !== req.archiveSize) {
      throw new Error('整合包归档大小与所选文件不一致');
    }
    if (req.archiveSha1 !== undefined && req.archiveSha1.length > 0
      && (await computeFileSha1(archive)).toLowerCase() !== req.archiveSha1.toLowerCase()) {
      throw new Error('整合包归档 SHA-1 与所选文件不一致');
    }
    if (req.archiveSha512 !== undefined && req.archiveSha512.length > 0
      && (await computeFileSha512(archive)).toLowerCase() !== req.archiveSha512.toLowerCase()) {
      throw new Error('整合包归档 SHA-512 与所选文件不一致');
    }
    this.checkCancelled_();
    this.phase_(req, 'extracting', '正在解压归档；取消会等待此步骤安全结束', 0, 1);
    let extracted = work + '/extracted';
    // 这是本任务独占目录，平台解压 Promise 收敛后才允许下一次重建。
    removeDirRecursive(extracted);
    ensureDirSync(extracted);
    // 中央目录预检在平台第一次写出条目之前执行，拒绝穿越、链接与展开预算越界。
    preflightModpackArchive(archive);
    await decompressFile(archive, extracted);
    this.checkCancelled_();
    let candidates = await discoverModpackPackages(work, (): boolean => this.cancelled_);
    candidates = this.expandDataRoots_(work, candidates);
    if (candidates.length === 0) throw new Error('归档内没有可识别的客户端整合包或完整实例；请确认包含清单、内层整合包或 versions 目录');
    if (candidates.length > 64) throw new Error('归档客户端候选过多，请选择单独的整合包或实例归档');
    // 多候选先保存发现结果并交还队列。未选择时的占位计划绝不进入基础构建或实例预约。
    const plan: ModpackPlan = { source: 'selection', name: req.displayName ?? '整合包', packVersion: '',
      gameVersion: '', loaderType: ModpackLoader.NONE, loaderVersion: '', summary: '', files: [], overrideDirs: [], problems: [] };
    let session: ModpackInstallSession = {
      schemaVersion: 1, id: id, mcDir: req.mcDir, versionName: '', requestedVersionName: req.versionName, plan: plan,
      officialFilesOnly: req.officialFilesOnly === true,
      warnings: [], missing: [], selectedOptional: [],
      confirmed: false, baseReady: false, overridesApplied: false, complete: false,
      installedFiles: [], overrideFiles: [], projectId: req.projectId ?? '',
      sourceVersionId: req.sourceVersionId ?? '', archiveSha1: req.archiveSha1 ?? '',
      archiveSize: fs.statSync(archive).size, iconUrl: req.iconUrl ?? '', createdAt: Date.now(),
      packageCandidates: candidates, packageOrigins: candidates.slice(), selectedPackageId: candidates.length === 1 ? candidates[0].id : '',
      packageReady: false, packageArchiveSha1: await computeFileSha1(archive),
    };
    this.session_ = session;
    // 先保存原始计划，即使 CF 查询期间取消/退出，仍有可恢复的精确 project/file ID。
    saveModpackSession(req.filesDir, session);
    return this.finishPackagePreparation_(req, session);
  }

  /** 实例与MMC的游戏数据根有歧义时展开为真正可选择的候选，不在适配器异常里要求盲选。 */
  private expandDataRoots_(work: string, candidates: ModpackPackageCandidate[]): ModpackPackageCandidate[] {
    const expanded: ModpackPackageCandidate[] = [];
    for (const candidate of candidates) {
      if (candidate.kind === 'multimc' && candidate.gameDir === undefined) {
        for (const data of ['minecraft', '.minecraft']) {
          if (dirExists(work + '/' + candidate.root + '/' + data)) expanded.push(this.withDataRoot_(candidate, data, data));
        }
        continue;
      }
      if (candidate.kind !== 'instance' || candidate.gameDir !== undefined) { expanded.push(candidate); continue; }
      for (const data of discoverInstanceDataRoots(work + '/' + candidate.root, candidate.versionId ?? '')) {
        expanded.push(this.withDataRoot_(candidate, data.path, data.title));
      }
    }
    return expanded;
  }

  /** 显式复制结构化候选，保留归档来源链；ArkTS 不允许展开普通对象。 */
  private withDataRoot_(candidate: ModpackPackageCandidate, data: string, title: string): ModpackPackageCandidate {
    return { id: candidate.id + ':data:' + data, kind: candidate.kind, root: candidate.root,
      title: candidate.title + ' · ' + title, versionId: candidate.versionId, gameDir: data,
      archiveChain: candidate.archiveChain, archivePath: candidate.archivePath, archiveDepth: candidate.archiveDepth };
  }

  /** 只持久化用户在任务详情选择的候选；解析与网络仍由下一次取得运行槽后执行。 */
  selectPackage(req: ModpackInstallRequest, id: string): void {
    const session = this.session_;
    if (session === undefined || session.versionName.length > 0 || session.packageReady !== false)
      throw new Error('当前安装不能更改整合包来源');
    if (!(session.packageCandidates ?? []).some((candidate: ModpackPackageCandidate): boolean => candidate.id === id))
      throw new Error('请选择原归档中的客户端或实例');
    session.selectedPackageId = id;
    saveModpackSession(req.filesDir, session);
  }

  /** 尚未创建实例时可返回初始来源选择；已写入的实例绝不换成另一包继续覆盖。 */
  restartPackageSelection(req: ModpackInstallRequest): void {
    const session = this.session_;
    if (session === undefined || session.versionName.length > 0 || (session.packageOrigins ?? []).length === 0)
      throw new Error('已创建实例不能切换来源，请新建独立安装任务');
    session.packageCandidates = session.packageOrigins!.slice();
    session.selectedPackageId = '';
    session.packageReady = false;
    session.packageRoot = undefined;
    session.confirmed = false;
    session.selectedOptional = [];
    saveModpackSession(req.filesDir, session);
  }

  /** 将固定载荷解释为同一安装计划；内包与完整实例不另建下载器或第二种提交事务。 */
  private async finishPackagePreparation_(req: ModpackInstallRequest, session: ModpackInstallSession): Promise<ModpackInstallSession> {
    if (session.packageReady !== false) return session;
    if ((session.selectedPackageId ?? '').length === 0) return session;
    const candidate = (session.packageCandidates ?? []).find((item: ModpackPackageCandidate): boolean => item.id === session.selectedPackageId);
    if (candidate === undefined) throw new Error('持久选择不属于该归档，已停止安装');
    const work = modpackWorkDir(req.filesDir, session.id);
    if (safeRelPath(candidate.root) !== candidate.root) throw new Error('整合包有效载荷路径无效');
    if (session.packageArchiveSha1 !== undefined
      && (await computeFileSha1(work + '/archive.zip')) !== session.packageArchiveSha1)
      throw new Error('恢复归档内容发生变化，请重新导入原始整合包');
    if (candidate.kind === 'archive') {
      const previous = session.packageCandidates ?? [];
      const previousId = session.selectedPackageId;
      this.phase_(req, 'resolving', '正在展开所选整合包', 0, 1);
      const discovered = this.expandDataRoots_(work,
        await materializeModpackPackage(work, candidate, (): boolean => this.cancelled_));
      this.checkCancelled_();
      if (discovered.length === 0) throw new Error('所选内包没有可识别的客户端或实例');
      if (discovered.length > 64) throw new Error('所选内包中的客户端候选过多');
      session.packageCandidates = discovered;
      session.selectedPackageId = discovered.length === 1 ? discovered[0].id : '';
      saveModpackSession(req.filesDir, session);
      try { return await this.finishPackagePreparation_(req, session); }
      catch (error) {
        // 单一子载荷的语义检查可能失败；回滚并持久保存父候选，不能丢掉同归档的好包。
        session.packageCandidates = previous;
        session.selectedPackageId = previousId;
        session.packageReady = false;
        session.packageRoot = undefined;
        saveModpackSession(req.filesDir, session);
        throw error as Error;
      }
    }
    const root = work + '/' + candidate.root;
    const parsed = candidate.kind === 'modrinth' ? parseModrinthIndex(fs.readTextSync(root + '/modrinth.index.json'))
      : candidate.kind === 'curseforge' ? parseCurseForgeManifest(fs.readTextSync(root + '/manifest.json'))
      : parseInstancePackage(root, candidate.kind, candidate.versionId, candidate.gameDir);
    const loader = toModLoaderType(parsed.plan.loaderType);
    if (loader !== null && !isSupportedInstallerLoader(loader))
      throw new Error('当前启动器尚不支持该整合包的加载器：' + parsed.plan.loaderType);
    this.validateOverrideLayout_(root, parsed.plan);
    this.checkCancelled_();
    session.plan = parsed.plan;
    session.warnings = parsed.warnings;
    session.missing = parsed.plan.problems.slice();
    session.packageRoot = candidate.root;
    session.packageReady = true;
    saveModpackSession(req.filesDir, session);
    if (session.plan.files.some((file: ModpackFile): boolean => file.cfProjectId !== undefined))
      await this.resolveCfFiles_(req, session, false);
    this.checkCancelled_();
    saveModpackSession(req.filesDir, session);
    return session;
  }

  /** 按安装身份寻找重命名后的实例，不依赖任务标题或调用方仍缓存的旧版本目录名。 */
  private retargetInstance_(req: ModpackInstallRequest, session: ModpackInstallSession): void {
    if (session.mcDir !== req.mcDir) throw new Error('恢复计划与当前安装根不一致');
    if (session.versionName.length === 0) return;
    const name = findModpackInstanceName(session.mcDir, session.id, session.versionName);
    if (name.length > 0 && name !== session.versionName) {
      session.versionName = name;
      saveModpackSession(req.filesDir, session);
    }
  }

  /**
   * 固定下载详情中的名称和可选内容。名称只属于安装意图，不能覆写包作者的 plan.name；
   * 最终目录由 reserve_ 原子预约并持久保存，恢复已有实例时禁止重新选择名称。
   */
  confirm(req: ModpackInstallRequest, name: string, selected: string[]): void {
    let session = this.session_;
    if (session === undefined) throw new Error('整合包清单尚未准备');
    if (session.packageReady === false) throw new Error('请先选择归档中的客户端或实例');
    if (session.versionName.length > 0) throw new Error('已创建实例不能在恢复时改名');
    let nameError = validateModpackVersionName(name);
    if (nameError.length > 0) throw new Error(nameError);
    let safe = name.trim();
    req.versionName = safe;
    session.selectedOptional = selected.slice();
    session.confirmed = true;
    // 确认名称在预约前也持久保存，以便进程重启后保持用户意图。
    session.requestedVersionName = safe;
    saveModpackSession(req.filesDir, session);
  }

  /** 非 UI 消费者的便捷接口；不默认安装可选项。产品任务先 prepare，再由详情确认调用 execute。 */
  async installFromArchive(req: ModpackInstallRequest): Promise<ModpackInstallResult> {
    this.beginAttempt();
    let session = await this.prepare(req);
    if (!session.confirmed) this.confirm(req, req.versionName ?? sanitizeVersionName(session.plan.name), req.selectedOptional ?? []);
    return this.execute(req);
  }

  /**
   * 只在本安装 owner 的实例目录中执行。失败/保留取消留下 pending；最终收据成功后才移除。
   * 恢复与部分完成补齐始终使用 session.versionName，绝不以标题再算一个新目录。
   */
  async execute(req: ModpackInstallRequest): Promise<ModpackInstallResult> {
    let session = await this.prepare(req);
    if (!session.confirmed) throw new Error('请先确认整合包安装内容');
    this.checkCancelled_();
    await this.verifyPackagePayload_(req, session);
    let release = this.reserve_(req, session);
    let versionDir = req.mcDir + '/versions/' + session.versionName;
    try {
      session.complete = false;
      session.missing = session.plan.problems.filter((p: ModpackProblem): boolean => p.required !== false);
      saveModpackSession(req.filesDir, session);
      if (session.plan.files.some((file: ModpackFile): boolean => file.cfProjectId !== undefined))
        await this.resolveCfFiles_(req, session, true);
      this.checkCancelled_();
      if (!session.baseReady) {
        this.phase_(req, 'base', '正在创建基础版本和加载器', 0, 1);
        let base = new McVersionTask(session.plan.gameVersion, toModLoaderType(session.plan.loaderType),
          session.plan.loaderVersion, session.versionName, req.mcDir, req.filesDir, session.id);
        this.baseTasks_.push(base);
        base.view.startedAtMs = this.activityId;
        this.activeBase_ = base;
        base.onProgress = (v: UnifiedTaskView): void => {
          let progress: ModpackProgress = { phase: 'base', message: '基础版本：' + v.currentLabel,
            current: v.filesDone, total: v.filesTotal, bytesDone: v.bytesDone, bytesTotal: v.bytesTotal,
            speedBps: v.speedBps, etaSeconds: v.etaSeconds, innerProgress: v.progress / 100 };
          req.onPhase?.(progress);
        };
        try { await base.start(); } finally { this.activeBase_ = undefined; }
        await this.settleNativeOwners();
        this.checkCancelled_();
        session.baseReady = true;
        saveModpackSession(req.filesDir, session);
      }
      this.assertOwner_(versionDir, session.id);
      await this.downloadFiles_(req, session, versionDir);
      this.checkCancelled_();
      if (!session.overridesApplied) {
        this.phase_(req, 'overrides', '正在应用覆盖文件', 0, 1);
        const work = modpackWorkDir(req.filesDir, session.id);
        let root = session.packageRoot !== undefined ? work + '/' + session.packageRoot : findModpackRoot(work + '/extracted');
        if (root.length === 0) throw new Error('恢复所需的整合包覆盖文件不存在，请保留当前实例并重新导入归档');
        for (let dir of session.plan.overrideDirs) {
          let src = dir === '.' ? root : root + '/' + dir;
          if (!dirExists(src)) {
            // 无额外配置的标准包可合法省略空覆盖目录；有真实内容却落在别处时须明确诊断。
            if (session.plan.source === 'modrinth') continue;
            if (session.plan.contentOnly === true || this.hasInstanceData_(root, session.plan.instanceVersionId)
              || this.hasInstanceData_(root + '/.minecraft', session.plan.instanceVersionId))
              throw new Error('整合包声明的覆盖目录不存在：' + dir + '；归档内容目录与清单不一致');
            continue;
          }
          let layer = dir;
          if (dirExists(src + '/.minecraft') && this.hasInstanceData_(src + '/.minecraft', session.plan.instanceVersionId)) {
            if (this.hasInstanceData_(src, session.plan.instanceVersionId)) throw new Error('覆盖目录同时含共享内容与 .minecraft 内容，不能猜选数据根');
            // 仅存在一个有实际游戏内容的包装根时剥离这一层；来源校验仍引用原归档路径。
            src += '/.minecraft';
            layer = (dir === '.' ? '__root__' : dir) + '/.minecraft';
          }
          await this.copyOverrides_(req, session, src, versionDir, '', layer);
        }
        session.overridesApplied = true;
        saveModpackSession(req.filesDir, session);
      }
      this.checkCancelled_();
      // 覆盖文件是包作者声明的最终内容，已提供同路径内容时不再保留下载阶段的缺失记录。
      session.missing = session.missing.filter((p: ModpackProblem): boolean =>
        p.path === undefined || session.overrideFiles.indexOf(p.path) < 0);
      await this.downloadIcon_(req, session, versionDir);
      this.checkCancelled_();
      let post = processModpackLaunchConfig(versionDir);
      for (let note of post.notes) if (session.warnings.indexOf(note) < 0) session.warnings.push(note);
      let snapshot: ModpackSnapshot = {
        schemaVersion: 2, installId: session.id, sourceVersionId: session.sourceVersionId,
        source: session.plan.source, projectId: session.projectId, name: session.versionName,
        packVersion: session.plan.packVersion, gameVersion: session.plan.gameVersion,
        loaderType: session.plan.loaderType, loaderVersion: session.plan.loaderVersion,
        files: session.plan.files, selectedOptional: session.selectedOptional,
        installedFiles: session.installedFiles, overrideFiles: session.overrideFiles,
        missing: session.missing, warnings: session.warnings, installedAt: Date.now(),
        recommendedJvmArgs: post.recommendedJvmArgs, recommendedMaxMemMb: post.recommendedMaxMemMb,
      };
      this.checkCancelled_();
      // 收据是提交边界；写失败保留 pending，不产生“已完成”的假终态。
      writeModpackSnapshot(versionDir, snapshot);
      session.complete = true;
      saveModpackSession(req.filesDir, session);
      fs.unlinkSync(versionDir + '/' + MODPACK_PENDING_FILE);
      await this.cleanupCommittedCache_(req, session);
      this.phase_(req, 'done', session.missing.length > 0 ? '安装完成，部分内容待补齐' : '整合包安装完成', 1, 1);
      new ActivityLogger(this.activityId).info(TAG, 'install committed: ' + session.id
        + ' missing=' + session.missing.length, LOG_DOMAIN_DOWNLOAD);
      return { versionName: session.versionName, plan: session.plan, missing: session.missing,
        warnings: session.warnings, recommendedJvmArgs: post.recommendedJvmArgs,
        recommendedMaxMemMb: post.recommendedMaxMemMb };
    } finally {
      // 未收敛时不删除现场，也不释放内存预约；持久 pending 不能代替当前执行租约。
      try { await this.settleNativeOwners(); } finally { release(); }
    }
  }

  /** 在创建实例之前复核有效载荷和本地内容身份；已交付补齐不再依赖已回收的覆盖缓存。 */
  private async verifyPackagePayload_(req: ModpackInstallRequest, session: ModpackInstallSession): Promise<void> {
    if (session.overridesApplied || session.packageRoot === undefined) return;
    const work = modpackWorkDir(req.filesDir, session.id);
    const assertPath = (relative: string, directory: boolean): string => {
      if (safeRelPath(relative) !== relative) throw new Error('恢复载荷路径不安全');
      let current = work;
      const parts = relative.split('/');
      for (let i = 0; i < parts.length; i++) {
        current += '/' + parts[i];
        const stat = fs.lstatSync(current);
        if (stat.isSymbolicLink() || ((i < parts.length - 1 || directory) ? !stat.isDirectory() : !stat.isFile()))
          throw new Error('恢复载荷包含链接或非普通路径：' + relative);
      }
      return current;
    };
    assertPath(session.packageRoot, true);
    this.validateOverrideLayout_(work + '/' + session.packageRoot, session.plan);
    if (session.packageArchiveSha1 !== undefined
      && (await computeFileSha1(assertPath('archive.zip', false))) !== session.packageArchiveSha1)
      throw new Error('整合包归档已变化，已停止恢复写入');
    const selected = (session.packageCandidates ?? []).find((item: ModpackPackageCandidate): boolean => item.id === session.selectedPackageId);
    for (const link of selected?.archiveChain ?? []) {
      if (link.path === 'archive.zip' && link.sha1 === session.packageArchiveSha1) continue;
      if ((await computeFileSha1(assertPath(link.path, false))) !== link.sha1)
        throw new Error('内层整合包来源已变化，已停止恢复写入');
    }
    for (const file of session.plan.requiredLocalFiles ?? []) {
      this.checkCancelled_();
      const fileRoot = file.root ?? '.';
      const relative = session.packageRoot + '/' + (fileRoot === '.' ? '' : fileRoot + '/') + file.path;
      if ((await computeFileSha1(assertPath(relative, false))).toLowerCase() !== file.sha1.toLowerCase())
        throw new Error('整合包本地内容哈希不符：' + file.path);
    }
    this.checkCancelled_();
  }

  /** 判断覆盖根是否含实际用户内容；未知模组目录也保留，说明/图标/启动器附件不制造冲突。 */
  private hasInstanceData_(root: string, versionId?: string): boolean {
    if (!dirExists(root)) return false;
    for (const name of fs.listFileSync(root)) {
      if (name === '.minecraft' || !isInstanceContentPath(name, versionId)) continue;
      const path = root + '/' + name;
      const stat = fs.lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error('覆盖来源包含链接');
      if (stat.isDirectory() && fs.listFileSync(path).length > 0) return true;
      if (stat.isFile() && !/^(?:readme|license|licence|changelog|使用说明|说明)(?:[._ -].*)?$/i.test(name)
        && !/\.(?:png|jpe?g|gif|webp|ico)$/i.test(name)) return true;
    }
    return false;
  }

  /** 结构矛盾在基础游戏下载和实例预约之前报告；合法空覆盖层仍可缺省。 */
  private validateOverrideLayout_(root: string, plan: ModpackPlan): void {
    for (const layer of plan.overrideDirs) {
      if (layer !== '.' && safeRelPath(layer) !== layer) throw new Error('覆盖根不是安全的相对目录');
      const source = layer === '.' ? root : root + '/' + layer;
      if (!dirExists(source)) {
        if (plan.source !== 'modrinth' && (plan.contentOnly === true
          || this.hasInstanceData_(root, plan.instanceVersionId) || this.hasInstanceData_(root + '/.minecraft', plan.instanceVersionId)))
          throw new Error('整合包声明的覆盖目录不存在：' + layer + '；归档内容目录与清单不一致');
        continue;
      }
      if (dirExists(source + '/.minecraft') && this.hasInstanceData_(source + '/.minecraft', plan.instanceVersionId)
        && this.hasInstanceData_(source, plan.instanceVersionId)) throw new Error('覆盖目录同时含共享内容与 .minecraft 内容，不能猜选数据根');
    }
  }

  /** 同步预约，目录存在必须重新取名；恢复仅认可同 installId 的 pending/收据。 */
  private reserve_(req: ModpackInstallRequest, session: ModpackInstallSession): () => void {
    ensureDirSync(req.mcDir + '/versions');
    let created = false;
    if (session.versionName.length === 0) {
      let existing = fs.listFileSync(req.mcDir + '/versions').concat(req.existingVersions);
      let base = sanitizeVersionName(session.requestedVersionName ?? req.versionName ?? session.plan.name);
      while (true) {
        let name = uniqueVersionName(base, existing);
        try {
          fs.mkdirSync(req.mcDir + '/versions/' + name);
          session.versionName = name;
          created = true;
          break;
        } catch (e) {
          if (!dirExists(req.mcDir + '/versions/' + name)) throw e as Error;
          existing.push(name);
        }
      }
    }
    let versionDir = req.mcDir + '/versions/' + session.versionName;
    let release = claimVersionInstall(req.mcDir, session.versionName, session.id);
    try {
      if (!created) {
        if (!dirExists(versionDir)) {
          if (session.baseReady) throw new Error('原整合包实例已被删除，不能补齐不存在的实例');
          ensureDirSync(versionDir);
        } else {
          let receipt = readModpackSnapshot(versionDir);
          if (pathExists(versionDir + '/' + MODPACK_PENDING_FILE)) this.assertOwner_(versionDir, session.id);
          else if (receipt?.installId !== session.id) throw new Error('实例没有匹配的安装收据，已停止恢复写入');
        }
      }
      let owner: ModpackPendingOwner = { id: session.id };
      writeModpackJsonAtomic(versionDir + '/' + MODPACK_PENDING_FILE, owner);
      saveModpackSession(req.filesDir, session);
      return release;
    } catch (e) { release(); throw e as Error; }
  }

  private assertOwner_(versionDir: string, id: string): void {
    let owner = JSON.parse(fs.readTextSync(versionDir + '/' + MODPACK_PENDING_FILE)) as ModpackPendingOwner;
    if (owner.id !== id) throw new Error('实例目录属于另一项安装，已停止写入');
  }

  /** CF 解析失败不丢弃原始条目，补齐时仍能用原 project/file ID 重试，绝不自动换版本。 */
  private async resolveCfFiles_(req: ModpackInstallRequest, session: ModpackInstallSession, selectedOnly: boolean): Promise<void> {
    let index = 0;
    let done = 0;
    let resolver = req.resolveCfFile;
    let worker = async (): Promise<void> => {
      while (index < session.plan.files.length) {
        this.checkCancelled_();
        let file = session.plan.files[index++];
        if (selectedOnly && !this.selected_(session, file)) continue;
        if (file.urls.length > 0 && file.path.length > 0) continue;
        try {
          if (resolver === undefined) throw new Error('CurseForge 文件解析服务不可用');
          let info = await resolver(file.cfProjectId ?? 0, file.cfFileId ?? 0,
            session.plan.gameVersion, session.plan.loaderType as string);
          this.checkCancelled_();
          if (safeBaseName(info.filename) !== info.filename || info.filename.length === 0) throw new Error('来源文件名不安全');
          if (['mods', 'resourcepacks', 'shaderpacks', 'saves'].indexOf(info.targetDirectory) < 0) throw new Error('来源未提供可识别的资源目录');
          file.path = info.targetDirectory + '/' + info.filename;
          file.fileNameHint = info.filename;
          file.urls = info.urls.slice();
          file.sha1 = info.sha1;
          file.size = info.size;
        } catch (e) {
          this.checkCancelled_();
          if (selectedOnly || file.env === ModpackEnv.REQUIRED) this.addMissing_(session, file, (e as Error).message);
        }
        done++;
        this.phase_(req, 'resolving', '正在解析 CurseForge 精确文件', done, session.plan.files.length);
      }
    };
    let workers: Promise<void>[] = [];
    // 工人各自捕获普通文件错误；取消也必须等全部在途元数据查询退出，不能提前销毁服务。
    for (let i = 0; i < Math.min(8, session.plan.files.length); i++) workers.push(worker().catch((): void => {}));
    await Promise.all(workers);
    this.checkCancelled_();
    saveModpackSession(req.filesDir, session);
  }

  private selected_(session: ModpackInstallSession, file: ModpackFile): boolean {
    return file.env === ModpackEnv.REQUIRED || (file.env === ModpackEnv.OPTIONAL
      && session.selectedOptional.indexOf(modpackFileKey(file)) >= 0);
  }

  private addMissing_(session: ModpackInstallSession, file: ModpackFile, reason: string): void {
    let item: ModpackMissingItem = {
      name: file.fileNameHint ?? file.path, path: file.path, reason: reason,
      cfProjectId: file.cfProjectId, cfFileId: file.cfFileId, required: file.env === ModpackEnv.REQUIRED,
    };
    item.url = file.urls.length > 0 ? file.urls[0] : (file.cfProjectId !== undefined && file.cfFileId !== undefined
      ? 'https://www.curseforge.com/projects/' + file.cfProjectId + '/files/' + file.cfFileId : undefined);
    let key = modpackFileKey(file);
    session.missing = session.missing.filter((old: ModpackProblem): boolean =>
      (old.cfFileId !== undefined ? ('cf:' + old.cfProjectId + ':' + old.cfFileId) : (old.path ?? '')) !== key);
    session.missing.push(item);
  }

  /** 检查传输事实，不分析 JAR 内部依赖；所有校验都在 staging 中完成后才激活文件。 */
  private async matches_(path: string, file: ModpackFile): Promise<boolean> {
    try {
      let stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || (file.size > 0 && stat.size !== file.size)) return false;
      if (file.sha1 !== undefined && file.sha1.length > 0
        && (await computeFileSha1(path)).toLowerCase() !== file.sha1.toLowerCase()) return false;
      if (file.sha512 !== undefined && file.sha512.length > 0
        && (await computeFileSha512(path)).toLowerCase() !== file.sha512.toLowerCase()) return false;
      return (file.sha1 ?? '').length > 0 || (file.sha512 ?? '').length > 0 || (file.size > 0 && stat.size === file.size);
    } catch (e) { return false; }
  }

  /** 补件也尊重玩家对模组做的禁用改名；冲突只记缺件，不生成另一个启用文件。 */
  private async preserveDisabled_(session: ModpackInstallSession, file: ModpackFile, target: string, disabled: string): Promise<void> {
    if (pathExists(target) || !await this.matches_(disabled, file)) {
      this.addMissing_(session, file, '检测到已禁用模组与清单冲突，已保留现有文件；请核对模组目录');
    } else if (session.installedFiles.indexOf(file.path) < 0) {
      session.installedFiles.push(file.path);
    }
  }

  /** 批量下载到独占 staging，逐文件校验/激活；已安装内容和用户改动在补齐时不被覆盖。 */
  private async downloadFiles_(req: ModpackInstallRequest, session: ModpackInstallSession, versionDir: string): Promise<void> {
    let stage = modpackWorkDir(req.filesDir, session.id) + '/files';
    ensureDirSync(stage);
    let pending: ModpackFile[] = [];
    let specs: DownloadFileSpec[] = [];
    let paths = new Set<string>();
    for (let file of session.plan.files) {
      if (!this.selected_(session, file)) continue;
      if (file.path.length === 0 || safeRelPath(file.path) !== file.path) {
        let reason = '未解析出安全的文件路径';
        // CF 精确文件元数据失败时路径仍为空。仅在同一项目和文件 ID 上保留此前的真实错误，
        // 例如元数据 404；不放宽非空不安全路径，也不从旧记录继承可选状态或地址。
        if (file.path.length === 0 && file.cfProjectId !== undefined && file.cfFileId !== undefined) {
          const previous = session.missing.find((item: ModpackProblem): boolean =>
            item.cfProjectId === file.cfProjectId && item.cfFileId === file.cfFileId
            && typeof item.reason === 'string' && item.reason.trim().length > 0);
          if (previous !== undefined) reason = previous.reason;
        }
        this.addMissing_(session, file, reason); continue;
      }
      if (paths.has(file.path)) throw new Error('整合包文件目标重复：' + file.path);
      paths.add(file.path);
      if (session.overrideFiles.indexOf(file.path) >= 0) continue;
      let target = versionDir + '/' + file.path;
      const disabled = disabledModTarget(file.path, target);
      if (disabled.length > 0) {
        await this.preserveDisabled_(session, file, target, disabled);
        continue;
      }
      if (session.installedFiles.indexOf(file.path) >= 0
        && (fileExists(target) || (file.path.startsWith('saves/') && dirExists(target.substring(0, target.length - 4))))) continue;
      if (await this.matches_(target, file)) {
        if (session.installedFiles.indexOf(file.path) < 0) session.installedFiles.push(file.path);
        continue;
      }
      if (pathExists(target)) { this.addMissing_(session, file, '目标已存在不同内容，保留用户文件；请移走后再补齐'); continue; }
      if (file.urls.length === 0) { this.addMissing_(session, file, '没有可用下载地址'); continue; }
      // 每次 Native 提交都约束来源：旧 session 可保留带镜像的精确计划，恢复不能因此
      // 绕过用户的官方选择。保持来源元数据和强哈希原样，不写坏持久计划来迎合当前设置。
      let urls = buildModpackDownloadUrls(file.urls, session.plan.source === 'modrinth',
        req.officialFilesOnly === true || session.officialFilesOnly === true);
      if (urls.length === 0) { this.addMissing_(session, file, '仅源站模式下没有可用的官方文件地址'); continue; }
      let local = stage + '/' + file.path;
      ensureDirSync(local.substring(0, local.lastIndexOf('/')));
      let spec: DownloadFileSpec = { localPath: local, allowedRoot: stage, urls: urls,
        check: { sha1: file.sha1, size: file.size } };
      pending.push(file); specs.push(spec);
    }
    this.checkCancelled_();
    if (specs.length > 0) {
      let spec: DownloadTaskSpec = { name: 'modpack-files:' + session.id, files: specs, activityId: this.activityId };
      try {
        await DownloadManager.instance().createAndWait(spec, (view: DownloadTaskView): void => {
          this.remember_(view.taskId);
          this.phase_(req, 'files', '正在下载整合包内容', view.filesDone, view.filesTotal, view);
        });
      } catch (e) {
        this.checkCancelled_();
        new ActivityLogger(this.activityId).warn(TAG, '部分文件下载未完成', e as Error, LOG_DOMAIN_DOWNLOAD);
      }
      await this.settleNativeOwners();
    }
    for (let file of pending) {
      this.checkCancelled_();
      let local = stage + '/' + file.path;
      if (!await this.matches_(local, file)) { this.addMissing_(session, file, '文件未下载完成或大小/哈希不符'); continue; }
      let target = versionDir + '/' + file.path;
      // 下载期间用户可能创建同名文件，激活之前再次检查，不依赖开始时的快照。
      if (pathExists(target)) { this.addMissing_(session, file, '目标在下载期间已被创建，已保留现有内容'); continue; }
      ensureInstanceParent(versionDir, file.path);
      this.assertOwner_(versionDir, session.id);
      if (file.path.startsWith('saves/') && file.path.toLowerCase().endsWith('.zip')) {
        // 地图解压进入实例 saves 的独占子目录，不覆盖已有世界；底层 Promise 收敛后再处理取消。
        let worldName = safeBaseName(file.path.substring(6, file.path.length - 4));
        let worldDir = versionDir + '/saves/' + worldName;
        if (dirExists(worldDir)) { this.addMissing_(session, file, '同名世界已存在，未覆盖'); continue; }
        // 世界目录只能在 saves 所在文件系统内原子改名。应用私有工作根与外部游戏根
        // 可以位于不同设备；归档保留在私有根，解压暂存放到本 owner 的实例 saves 中。
        let worldStageRel = 'saves/.amcl-map-' + session.id;
        let worldStage = versionDir + '/' + worldStageRel;
        if (pathExists(worldStage) && !dirExists(worldStage)) throw new Error('地图暂存不是普通目录');
        this.assertOwner_(versionDir, session.id);
        removeDirRecursive(worldStage);
        ensureInstanceParent(versionDir, worldStageRel + '/level.dat');
        await decompressFile(local, worldStage);
        this.checkCancelled_();
        let worldRoot = worldStage;
        if (!fileExists(worldStage + '/level.dat')) {
          let candidates = fs.listFileSync(worldStage).filter((name: string): boolean =>
            fileExists(worldStage + '/' + name + '/level.dat'));
          if (candidates.length !== 1) { this.addMissing_(session, file, '地图归档没有唯一的 level.dat，未改动存档'); continue; }
          worldRoot = worldStage + '/' + candidates[0];
        }
        if (pathExists(worldDir)) { this.addMissing_(session, file, '同名世界在下载期间出现，未覆盖'); continue; }
        fs.renameSync(worldRoot, worldDir);
        if (worldRoot !== worldStage) removeDirRecursive(worldStage);
      } else {
        // 已下载的私有缓存继续用于恢复；先复制、校验、刷盘到目标旁边，再同文件系统
        // 改名发布，避免 app files -> 外部 Download 的 EXDEV，取消也不会留半写入最终文件。
        let staged = await this.copyForActivation_(local, versionDir, file.path, session);
        // 下载和暂存均有异步等待，最终改名前复核期间出现的禁用选择。
        const disabled = disabledModTarget(file.path, target);
        if (disabled.length > 0) {
          await this.preserveDisabled_(session, file, target, disabled);
          fs.unlinkSync(staged);
          continue;
        }
        if (pathExists(target)) {
          this.addMissing_(session, file, '目标在复制期间已被创建，已保留现有内容');
          fs.unlinkSync(staged);
          continue;
        }
        fs.renameSync(staged, target);
      }
      if (session.installedFiles.indexOf(file.path) < 0) session.installedFiles.push(file.path);
      saveModpackSession(req.filesDir, session);
    }
  }

  /**
   * 将已收敛的私有下载复制到最终目标所在文件系统。源文件仍保留到收据提交，进程
   * 中断可以复用缓存；返回的暂存文件已验证大小/SHA-1并刷盘，调用方再检查目标占用，
   * 只执行同目录 rename。owner、父目录与暂存类型前后复核，禁止跟随已有链接。
   */
  private async copyForActivation_(source: string, versionDir: string, relative: string,
    session: ModpackInstallSession): Promise<string> {
    this.checkCancelled_();
    ensureInstanceParent(versionDir, relative);
    this.assertOwner_(versionDir, session.id);
    let sourceStat = fs.lstatSync(source);
    if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) throw new Error('安装源不是普通文件');
    let digest = await computeFileSha1(source);
    let staged = versionDir + '/' + relative + '.amcl-copy-' + session.id;
    if (pathExists(staged) && !fileExists(staged)) throw new Error('安装暂存不是普通文件');
    await fs.copyFile(source, staged);
    this.checkCancelled_();
    let stagedStat = fs.lstatSync(staged);
    if (!stagedStat.isFile() || stagedStat.isSymbolicLink() || stagedStat.size !== sourceStat.size
      || await computeFileSha1(staged) !== digest) {
      throw new Error('安装暂存复制校验失败：' + relative);
    }
    let copied = fs.openSync(staged, fs.OpenMode.READ_WRITE);
    try { fs.fsyncSync(copied.fd); } finally { fs.closeSync(copied); }
    ensureInstanceParent(versionDir, relative);
    this.assertOwner_(versionDir, session.id);
    return staged;
  }

  /** 覆盖复制逐文件可取消。目录/链接/控制元数据不允许被包内容改写，恢复不覆盖用户新文件。 */
  private async copyOverrides_(req: ModpackInstallRequest, session: ModpackInstallSession,
    srcDir: string, versionDir: string, prefix: string, layer: string): Promise<void> {
    let stat = fs.lstatSync(srcDir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('覆盖源不是普通目录');
    for (let name of fs.listFileSync(srcDir)) {
      this.checkCancelled_();
      if (safeBaseName(name) !== name) throw new Error('覆盖文件名不安全');
      let rel = prefix.length > 0 ? prefix + '/' + name : name;
      // 根覆盖层只复制实例内容；附带的清单、启动器、账号和 PC 运行层均不激活。
      if ((session.plan.contentOnly === true || layer === '.' || layer.endsWith('/.minecraft'))
        && !isInstanceContentPath(rel, session.plan.instanceVersionId)) continue;
      // 额外 .minecraft 包装层具有不同的 gameDir 语义，不能原样错放后提交完成收据。
      if (prefix.length === 0 && name === '.minecraft')
        throw new Error('覆盖目录额外包含 .minecraft 游戏根，请选择完整实例或正确的覆盖内容根');
      if (safeRelPath(rel) !== rel || rel.startsWith('.amcl-')
        || rel === session.versionName + '.json' || rel === session.versionName + '.jar') {
        throw new Error('覆盖文件试图改写启动器实例元数据：' + rel);
      }
      let src = srcDir + '/' + name;
      let dst = versionDir + '/' + rel;
      let entry = fs.lstatSync(src);
      if (entry.isSymbolicLink()) throw new Error('拒绝覆盖符号链接');
      if (entry.isDirectory()) {
        ensureDirSync(dst);
        let targetDir = fs.lstatSync(dst);
        if (!targetDir.isDirectory() || targetDir.isSymbolicLink()) throw new Error('覆盖目标不是普通目录');
        await this.copyOverrides_(req, session, src, versionDir, rel, layer);
      } else if (entry.isFile()) {
        ensureInstanceParent(versionDir, rel);
        if (pathExists(dst)) {
          let old = fs.lstatSync(dst);
          if (!old.isFile() || old.isSymbolicLink()) throw new Error('覆盖目标不是普通文件：' + rel);
        }
        // 作者覆盖也跟随玩家实际使用的文件名，原有内容校验和覆盖层顺序照常执行。
        const activePath = dst;
        const disabled = disabledModTarget(rel, activePath);
        if (disabled.length > 0) {
          if (pathExists(activePath)) throw new Error('启用和禁用模组同时存在，已保留：' + rel);
          dst = disabled;
        }
        let digest = await computeFileSha1(src);
        let actual = fileExists(dst) ? await computeFileSha1(dst) : '';
        if (!new RegExp('^[a-f0-9]{40}$').test(digest)
          || (fileExists(dst) && !new RegExp('^[a-f0-9]{40}$').test(actual))) throw new Error('覆盖内容摘要读取失败：' + rel);
        let records = session.overrideReceipts ?? [];
        session.overrideReceipts = records;
        let source = (layer === '.' ? '__root__' : layer) + '/' + rel;
        let record = records.find((item: ModpackOverrideReceipt): boolean => item.source === source);
        let history = records.filter((item: ModpackOverrideReceipt): boolean => item.path === rel);
        let latest = history.length > 0 ? history[history.length - 1] : undefined;
        // 先验证最后一次激活/激活意图，防止重放早期覆盖层时回退 client-overrides，
        // 也防止将用户在失败后改过的文件误当作“任务以前复制过，所以可以覆盖”。
        if (latest !== undefined && actual !== latest.sha1
          && (latest.committed || actual !== latest.previousSha1)) throw new Error('覆盖目标已有用户修改，已保留：' + rel);
        if (record !== undefined) {
          if (record.sha1 !== digest) throw new Error('恢复覆盖来源发生变化：' + rel);
          if (record.committed || actual === record.sha1) {
            record.committed = true;
            if (session.overrideFiles.indexOf(rel) < 0) session.overrideFiles.push(rel);
            saveModpackSession(req.filesDir, session);
            continue;
          }
        } else {
          if (latest === undefined && actual.length > 0 && actual !== digest) {
            let downloaded = session.plan.files.find((file: ModpackFile): boolean => file.path === rel);
            // 只有仍匹配精确下载清单的文件可以接受第一次作者覆盖；旧覆盖记录和
            // 用户文件没有可证明的上一份摘要时拒绝覆盖，保留现场供用户处理。
            if (session.installedFiles.indexOf(rel) < 0 || downloaded === undefined
              || !await this.matches_(dst, downloaded)) throw new Error('覆盖目标已有用户文件，已保留：' + rel);
          }
          record = { path: rel, source: source, previousSha1: actual, sha1: digest, committed: false };
          records.push(record);
          saveModpackSession(req.filesDir, session);
        }
        this.checkCancelled_();
        // 临时文件与目标同目录，成功复制后原子激活，取消不会留下半写入配置。
        let staging = dst + '.amcl-copy-' + session.id;
        await fs.copyFile(src, staging);
        this.checkCancelled_();
        if (fs.statSync(staging).size !== entry.size) throw new Error('覆盖文件复制不完整：' + rel);
        if (await computeFileSha1(staging) !== digest) throw new Error('覆盖暂存校验失败：' + rel);
        let copied = fs.openSync(staging, fs.OpenMode.READ_WRITE);
        try { fs.fsyncSync(copied.fd); } finally { fs.closeSync(copied); }
        // copyFile 是异步边界，再次检查目标内容，避免复制期间产生的用户修改被替换。
        let beforeCommit = fileExists(dst) ? await computeFileSha1(dst) : '';
        if (beforeCommit !== record.previousSha1) throw new Error('覆盖目标在复制期间发生变化，已保留：' + rel);
        this.checkCancelled_();
        ensureInstanceParent(versionDir, rel);
        if (pathExists(dst) && (!fs.lstatSync(dst).isFile() || fs.lstatSync(dst).isSymbolicLink()))
          throw new Error('覆盖目标在复制期间变成非普通文件：' + rel);
        if (disabledModTarget(rel, activePath) !== disabled || (disabled.length > 0 && pathExists(activePath)))
          throw new Error('复制期间模组启用状态发生变化，请重试：' + rel);
        fs.renameSync(staging, dst);
        let parent = fs.openSync(dst.substring(0, dst.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
        try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
        record.committed = true;
        if (session.overrideFiles.indexOf(rel) < 0) session.overrideFiles.push(rel);
        saveModpackSession(req.filesDir, session);
      } else { throw new Error('拒绝覆盖特殊文件：' + rel); }
    }
  }

  /** 图标仍沿用安装后展示能力；使用工作区 staging，不让失败图标污染版本元数据。 */
  private async downloadIcon_(req: ModpackInstallRequest, session: ModpackInstallSession, versionDir: string): Promise<void> {
    if (session.iconUrl.length === 0 || fileExists(versionDir + '/' + MODPACK_ICON_FILE)) return;
    let work = modpackWorkDir(req.filesDir, session.id);
    let path = work + '/icon.png';
    try {
      let spec: DownloadTaskSpec = { name: 'modpack-icon:' + session.id, activityId: this.activityId,
        files: [{ localPath: path, urls: [session.iconUrl], allowedRoot: work }] };
      await DownloadManager.instance().createAndWait(spec, (view: DownloadTaskView): void => { this.remember_(view.taskId); });
      await this.settleNativeOwners();
      this.checkCancelled_();
      ensureInstanceParent(versionDir, MODPACK_ICON_FILE);
      let staged = await this.copyForActivation_(path, versionDir, MODPACK_ICON_FILE, session);
      if (!pathExists(versionDir + '/' + MODPACK_ICON_FILE)) fs.renameSync(staged, versionDir + '/' + MODPACK_ICON_FILE);
      else fs.unlinkSync(staged);
    } catch (e) {
      this.checkCancelled_();
      new ActivityLogger(this.activityId).warn(TAG, '整合包图标下载失败，不影响内容安装', e as Error, LOG_DOMAIN_DOWNLOAD);
      await this.settleNativeOwners();
    }
  }

  /**
   * 收据提交后保留小型计划和来源身份，释放已应用的归档/覆盖缓存。
   * 部分安装保留失败文件的 native 续传材料；缓存清理失败只记日志，不推翻已交付实例。
   */
  private async cleanupCommittedCache_(req: ModpackInstallRequest, session: ModpackInstallSession): Promise<void> {
    if (!session.overridesApplied || !this.purgeNativeOwners()) return;
    let work = modpackWorkDir(req.filesDir, session.id);
    try {
      removeDirRecursive(work + '/extracted');
      // 内包和完整实例的展开层同样只属于本安装；收据提交后补齐仅依赖持久计划。
      removeDirRecursive(work + '/payloads');
      if (session.missing.length === 0) removeDirRecursive(work + '/files');
      if (req.archivePath !== undefined) await releaseLegacyModpackImport(req.filesDir, session.id, req.archivePath);
      try { fs.unlinkSync(work + '/archive.zip'); } catch (e) { /* 不存在或稍后清理 */ }
    } catch (e) {
      new ActivityLogger(this.activityId).warn(TAG, '已提交整合包的缓存清理未完成', e as Error, LOG_DOMAIN_DOWNLOAD);
    }
  }

  /** 用户明确选择清理时调用；已有正式收据的实例绝不递归删除。 */
  async discard(req: ModpackInstallRequest): Promise<void> {
    await this.settleNativeOwners();
    let session = this.session_;
    if (session === undefined) {
      // 冷恢复任务可能尚在排队，先读取持久计划，不能只删工作根而遗留失联 pending。
      if (req.sessionId === undefined) return;
      const work = modpackWorkDir(req.filesDir, req.sessionId);
      if (fileExists(work + '/session.json')) {
        session = recoverModpackSessionForWrite(req.filesDir, req.sessionId);
        this.retargetInstance_(req, session);
        this.session_ = session;
      } else {
        // 缺基座但仍有 WAL 时，无法证明哪些字节只是可再生暂存，保留原件等待人工核对。
        if (hasModpackOverrideJournalEvidence(req.filesDir, req.sessionId)) throw new Error('覆盖日志缺少基座，无法安全清理');
        const released = await releaseLegacyModpackImport(req.filesDir, req.sessionId);
        removeDirRecursive(work);
        if (!released) throw new Error('已取消，旧导入来源未能核实，已保留');
        return;
      }
    }
    if (session.versionName.length > 0) {
      let dir = req.mcDir + '/versions/' + session.versionName;
      let receipt = readModpackSnapshot(dir);
      if (receipt?.installId === session.id) {
        // 补齐取消只结束本轮写入，不删除已经交付给用户的实例和存档。
        try { this.assertOwner_(dir, session.id); fs.unlinkSync(dir + '/' + MODPACK_PENDING_FILE); } catch (e) { /* 已结束 */ }
        removeDirRecursive(modpackWorkDir(req.filesDir, session.id) + '/files');
        session.missing = receipt.missing.slice();
        session.complete = true;
        saveModpackSession(req.filesDir, session);
        return;
      }
      this.assertOwner_(dir, session.id);
      removeDirRecursive(dir);
    }
    if (hasModpackOverrideJournalEvidence(req.filesDir, session.id)) {
      // 迁移后的旧 WAL 仍用于追溯。显式取消只关闭恢复入口并清理缓存，不删历史原件。
      saveModpackRecoveryDismissal(req.filesDir, session.id, 'install');
      if (!await cleanupDismissedModpackWork(req.filesDir, session.id)) throw new Error('已放弃安装，暂存未完全清理');
    } else {
      const work = modpackWorkDir(req.filesDir, session.id);
      const released = await releaseLegacyModpackImport(req.filesDir, session.id);
      removeDirRecursive(work);
      if (!released) throw new Error('已取消，旧导入来源未能核实，已保留');
    }
    this.session_ = undefined;
  }

  private phase_(req: ModpackInstallRequest, phase: string, message: string, current: number,
    total: number, view?: DownloadTaskView, inner?: number): void {
    let progress: ModpackProgress = { phase: phase, message: message, current: current, total: total,
      bytesDone: view?.bytesDone ?? 0, bytesTotal: view?.bytesTotal ?? 0, speedBps: view?.speedBps ?? 0,
      etaSeconds: view?.etaSeconds ?? -1,
      innerProgress: inner ?? (phase === 'pack' && view !== undefined && view.bytesTotal > 0
        ? view.bytesDone / view.bytesTotal : (total > 0 ? current / total : -1)) };
    req.onPhase?.(progress);
  }
}

/** 优先确认持久记录上的目录名，必要时按原安装身份查找重命名后的目录。 */
function findModpackInstanceName(mcDir: string, id: string, knownName: string): string {
  const versions = mcDir + '/versions';
  const matches = (name: string): boolean => {
    if (safeBaseName(name) !== name || !dirExists(versions + '/' + name)) return false;
    if (readModpackSnapshot(versions + '/' + name)?.installId === id) return true;
    try {
      const owner = JSON.parse(fs.readTextSync(versions + '/' + name + '/' + MODPACK_PENDING_FILE)) as ModpackPendingOwner;
      return owner.id === id;
    } catch (_) { return false; }
  };
  if (knownName.length > 0 && matches(knownName)) return knownName;
  let found: string[] = [];
  try { found = fs.listFileSync(versions).filter((name: string): boolean => matches(name)); } catch (_) { return ''; }
  if (found.length > 1) throw new Error('存在多个相同安装身份的实例，请先处理重复副本');
  return found[0] ?? '';
}

interface ModpackRecoveryInspection {
  kind: ModpackRecoveryKind;
  mcDir?: string;
  committedName?: string;
}

/** 放弃路径只认可本安装的 v2 真实提交收据，旧展示 reader 允许的链接及摘要不足以撤销 pending。 */
function hasCommittedRecoveryReceipt(dir: string, id: string): boolean {
  const path = dir + '/' + MODPACK_SNAPSHOT_FILE;
  if (!fs.accessSync(path)) return false;
  if (!fileExists(path)) throw new Error('整合包提交收据不是普通文件');
  const receipt = readModpackSnapshot(dir);
  if (receipt === null || receipt.schemaVersion !== 2 || typeof receipt.installId !== 'string'
    || typeof receipt.gameVersion !== 'string' || receipt.gameVersion.length === 0
    || !Number.isFinite(receipt.installedAt) || receipt.installedAt <= 0
    || !Array.isArray(receipt.missing) || !Array.isArray(receipt.installedFiles) || !Array.isArray(receipt.overrideFiles)) {
    throw new Error('无法确认整合包实例的提交收据');
  }
  return receipt.installId === id;
}

/** 确认框读摘要，最终提交在原执行环境完整校验；两者均不改写实例位置。 */
function readModpackRecoveryInspection(filesDir: string, id: string, previewOnly: boolean): ModpackRecoveryInspection {
  const work = modpackWorkDir(filesDir, id);
  const hasSession = fs.accessSync(work + '/session.json');
  if (!hasSession) {
    // 归档准备未完成时，只有持久来源也可以放弃。不存在或无效的来源不能凭空建立放弃记录。
    if (!previewOnly && hasModpackOverrideJournalEvidence(filesDir, id)) throw new Error('覆盖日志缺少基座，无法安全放弃');
    loadModpackSource(filesDir, id);
    return { kind: 'install' };
  }
  let session: ModpackInstallSession | undefined = undefined;
  try { session = previewOnly ? loadRecoveryPreview(filesDir, id) : loadModpackSession(filesDir, id); }
  catch (error) {
    // 有旧 WAL 时必须先通过精确校验，不能从来源回退后把无法读取的日志当缓存清理。
    if (!previewOnly && hasModpackOverrideJournalEvidence(filesDir, id)) throw error as Error;
  }
  const mcDir = session?.mcDir ?? loadModpackSource(filesDir, id).mcDir;
  if (mcDir.length === 0) throw new Error('整合包恢复根目录无效');
  // 已知计划还未预约实例时无需扫目录。仅有来源回退的损坏计划可能已经提交，按原 ID 查收据。
  const knownName = session?.versionName ?? '';
  const name = session !== undefined && knownName.length === 0 ? '' : findModpackInstanceName(mcDir, id, knownName);
  if (name.length > 0) {
    const dir = mcDir + '/versions/' + name;
    if (hasCommittedRecoveryReceipt(dir, id)) return { kind: 'repair', mcDir: mcDir, committedName: name };
  }
  return { kind: 'install' };
}

/** 只有当前实例中匹配安装 ID 的提交收据才能使用「不再补齐」。 */
export function inspectModpackRecovery(filesDir: string, id: string): ModpackRecoveryKind {
  const dismissed = readModpackRecoveryDismissal(filesDir, id);
  if (dismissed !== undefined) return dismissed;
  return readModpackRecoveryInspection(filesDir, id, true).kind;
}

/** 以独立 owner 短暂锁住已提交实例，防止停止或重新开启补齐越过正在运行的安装。 */
export function claimCommittedModpackRepair(mcDir: string, name: string, id: string): () => void {
  if (mcDir.length === 0 || name.length === 0 || safeBaseName(name) !== name) throw new Error('整合包实例路径不安全');
  const release = claimVersionInstall(mcDir, name, newVersionInstallOwner());
  try {
    const versions = mcDir + '/versions';
    const dir = versions + '/' + name;
    if (!dirExists(mcDir) || !dirExists(versions) || !dirExists(dir) || !hasCommittedRecoveryReceipt(dir, id))
      throw new Error('整合包实例已变化，请重新检查提交记录');
    return release;
  } catch (e) { release(); throw e as Error; }
}

/** 已等执行收敛后再落放弃状态，持久成功才能清缓存。只为已提交的匹配实例收尾其 pending 标记。 */
export function commitModpackRecoveryAbandonment(filesDir: string, id: string, expected: ModpackRecoveryKind): void {
  assertNoModpackJournalWriter(modpackWorkDir(filesDir, id), id);
  const dismissed = readModpackRecoveryDismissal(filesDir, id);
  if (dismissed === expected) return;
  const current = readModpackRecoveryInspection(filesDir, id, false);
  if (dismissed !== undefined || current.kind !== expected) throw new Error('安装状态已变化，请刷新后重新确认');
  const mcDir = current.mcDir;
  const name = current.committedName;
  if (mcDir !== undefined && name !== undefined) {
    const release = claimCommittedModpackRepair(mcDir, name, id);
    try {
      const pending = mcDir + '/versions/' + name + '/' + MODPACK_PENDING_FILE;
      if (fs.accessSync(pending)) {
        if (!fileExists(pending)) throw new Error('整合包实例待提交记录不是普通文件');
        const owner = JSON.parse(fs.readTextSync(pending)) as ModpackPendingOwner;
        if (owner.id !== id) throw new Error('该整合包实例正在由另一项安装处理');
        fs.unlinkSync(pending);
      }
    } finally { release(); }
  }
  saveModpackRecoveryDismissal(filesDir, id, expected);
}

/** 清单加载器枚举到基础安装接口；不支持的加载器由统一安装器给出清晰错误。 */
export function toModLoaderType(loader: ModpackLoader): ModLoaderType | null {
  if (loader === ModpackLoader.FABRIC) return ModLoaderType.FABRIC;
  if (loader === ModpackLoader.FORGE) return ModLoaderType.FORGE;
  if (loader === ModpackLoader.NEOFORGE) return ModLoaderType.NEOFORGE;
  if (loader === ModpackLoader.QUILT) return ModLoaderType.QUILT;
  return null;
}
export function detectManifestKind(dir: string): string {
  if (fileExists(dir + '/modrinth.index.json')) return 'modrinth';
  if (fileExists(dir + '/manifest.json')) return 'curseforge';
  return 'none';
}
/** 旧会话的目录回退；新安装统一使用持久化包装发现候选，不调用这个历史深度策略。 */
export function findModpackRoot(dir: string): string {
  if (detectManifestKind(dir) !== 'none') return dir;
  let roots: string[] = [];
  for (let name of fs.listFileSync(dir)) {
    let sub = dir + '/' + name;
    if (dirExists(sub) && detectManifestKind(sub) !== 'none') roots.push(sub);
  }
  if (roots.length > 1) throw new Error('归档中存在多个整合包清单，请选择单独的客户端归档');
  return roots.length === 1 ? roots[0] : '';
}
export function sanitizeVersionName(name: string): string {
  let out = name.replace(new RegExp('[\\\\/:*?"<>|!;\\x00-\\x1f\\x7f]', 'g'), '_').trim();
  return out.length > 0 && safeBaseName(out) === out ? out : '整合包';
}
/**
 * 下载详情和安装服务共用的名称校验。首尾留白按普通版本习惯修剪；禁止目录分隔、
 * 控制字符和启动链路破坏字符，保留安全中文。已明确输入的非法名称须显示错误，
 * 不能静默改成另一个用户未选择的名称。自动默认名先经 sanitizeVersionName 生成。
 */
export function validateModpackVersionName(name: string): string {
  let trimmed = name.trim();
  if (trimmed.length === 0) return '版本名称不能为空';
  if (trimmed.length > 120) return '版本名称不能超过 120 个字符';
  if (sanitizeVersionName(trimmed) !== trimmed) return '版本名称包含不支持的字符';
  return '';
}
export function uniqueVersionName(base: string, existing: string[]): string {
  let set = new Set<string>(existing);
  if (!set.has(base)) return base;
  let index = 2;
  while (set.has(base + ' (' + index + ')')) index++;
  return base + ' (' + index + ')';
}
function fileExists(path: string): boolean {
  try { let st = fs.lstatSync(path); return st.isFile() && !st.isSymbolicLink(); } catch (e) { return false; }
}
function pathExists(path: string): boolean {
  try { fs.lstatSync(path); return true; } catch (e) { return false; }
}

/** 未发现禁用文件才能按启用名发布。读取失败交给现有失败流程，避免重新启用玩家的模组。 */
function disabledModTarget(relative: string, target: string): string {
  if (!relative.startsWith('mods/') || !/\.(jar|zip)$/i.test(relative)) return '';
  const disabled = disableFilename(target);
  try {
    const stat = fs.lstatSync(disabled);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('禁用模组不是普通文件：' + relative);
    return disabled;
  } catch (error) {
    const code = String((error as BusinessError).code);
    if (code === '13900002' || code === 'ENOENT') return '';
    throw error as Error;
  }
}

/** 逐层拒绝目标父目录链接；只做字符串包含检查不足以阻止写入被重定向到实例外。 */
function ensureInstanceParent(root: string, relative: string): void {
  if (safeRelPath(relative) !== relative) throw new Error('实例文件路径不安全');
  let current = root;
  let parts = relative.split('/');
  for (let index = 0; index < parts.length; index++) {
    if (index > 0) current += '/' + parts[index - 1];
    ensureDirSync(current);
    let stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('实例文件父目录不是普通目录');
  }
}
function dirExists(path: string): boolean {
  try { let st = fs.lstatSync(path); return st.isDirectory() && !st.isSymbolicLink(); } catch (e) { return false; }
}

/**
 * 安装、更新和修复共用的模组事务：锁定目录后重新解析环境与依赖，逐文件下载到暂存目录，
 * 校验完整组合后再统一提交。任何传输或校验失败都保留旧文件；native 全部收敛后才清理暂存。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DownloadManager, DownloadTaskSpec, DownloadFileSpec, DownloadTaskView, computeFileSha1,
} from 'feature_core';
import { AppLogger, LOG_DOMAIN_DOWNLOAD, removeDirRecursive } from 'commons';
import { RemoteVersion, RemoteFile, ModSource, ResourceKind, LocalMod, pickPrimaryFile, resourceKindToInstallDir } from './ModTypes';
import { ModSourceRouter } from './ModSourceRouter';
import { CurseForgeRepository } from './CurseForgeRepository';
import { makeResolverFromRouter, dependencyPlanErrors, isModVersionCompatible, ResolveOptions } from './ModDependencyResolver';
import { resolveInstalledLoader, resolveInstalledMcVersion } from './InstalledLoaderResolver';
import { resolveInstalledLoaderVersion } from './InstalledLoaderVersion';
import { LocalModScanner } from './LocalModScanner';
import { ModrinthRepository } from './ModrinthRepository';
import { buildDownloadSpec } from './ModInstaller';
import { ModDescriptor, ModEnvironment, readModDescriptors, validateModSet } from './ModManifest';
import { InstalledModEntry, InstalledModIndex, readInstalledModIndex, INSTALLED_MOD_INDEX_FILE } from './InstalledModIndex';
import {
  normalizeModDirectory, withModDirectoryLock, recoverModTransaction, createModStaging, commitModFiles,
  ModFileChange, modFileExists, writeModFile, hasModRecoveryJournal, ensureModDirectory,
} from './ModInstallTransaction';

const TAG = 'ModInstallService';
interface IndexShape { version: number; entries: InstalledModEntry[]; }
interface ModFingerprint { name: string; sha1: string; }

export interface ModInstallRequest {
  mcDir: string;
  versionId: string;
  versionIsolation: boolean;
  root: RemoteVersion;
  title: string;
  router: ModSourceRouter;
  optionalIds: string[];
  /** Explicit update/repair source; the service rechecks that it still exists. */
  oldPath?: string;
  wasEnabled?: boolean;
}

/** 计划内每个实际下载文件的身份；已安装且兼容的依赖不会出现在此清单中。 */
export interface ModInstallFile {
  title: string;
  projectId: string;
  versionId: string;
  source: string;
  file: RemoteFile;
}

/** 安装事务的显示回调。index 稳定对应计划清单，单文件进度不从总进度估算。 */
export interface ModInstallObserver {
  phase: (text: string) => void;
  fileProgress: (index: number, view: DownloadTaskView) => void;
  cancelled: () => boolean;
  files: (files: ModInstallFile[]) => void;
}

/** 同一安装事务内文件工人的共享状态；失败先取消在途任务，再等待所有工人和 native 收敛。 */
class ModTransferBatch {
  next: number = 0;
  owners: number[] = [];
  error: Error | null = null;
}

interface PlannedModFile {
  version: RemoteVersion;
  file: RemoteFile;
  title: string;
  enabled: boolean;
  oldNames: string[];
  stagedRelative: string;
}

/** 构造安装和组合检查的实际环境；缺少加载器版本时提前失败，避免下载后才被空值误拒绝。 */
export function installedModEnvironment(mcDir: string, versionId: string, javaVersion: string = ''): ModEnvironment {
  const loader = resolveInstalledLoader(mcDir, versionId);
  const game = resolveInstalledMcVersion(mcDir, versionId);
  const loaderVersion = resolveInstalledLoaderVersion(mcDir, versionId, loader, game);
  if (loader.length > 0 && loaderVersion.length === 0)
    throw new Error('无法确认目标版本的 ' + loader + ' 加载器版本，请先修复该游戏版本的安装元数据');
  return { gameVersion: game, loader: loader, loaderVersion: loaderVersion, javaVersion: javaVersion };
}

export async function inspectInstalledModSet(dir: string, environment: ModEnvironment): Promise<string[]> {
  const descriptors: ModDescriptor[] = [];
  let names: string[] = [];
  try { names = fs.listFileSync(dir); } catch (e) { if (modFileExists(dir)) throw e as Error; return []; }
  for (const name of names) {
    if (!name.toLowerCase().endsWith('.jar')) continue;
    descriptors.push(...await readModDescriptors(dir + '/' + name, environment.loader));
  }
  return validateModSet(descriptors, environment);
}

export class ModInstallService {
  async install(request: ModInstallRequest, observer: ModInstallObserver, activityId: number = 0): Promise<void> {
    const dir = normalizeModDirectory(resourceKindToInstallDir(ResourceKind.MOD, request.mcDir, request.versionId, request.versionIsolation));
    await withModDirectoryLock<void>(dir, async (): Promise<void> => {
      ensureModDirectory(dir);
      await recoverModTransaction(dir);
      if (hasModRecoveryJournal(dir)) throw new Error('上次模组事务已结束，但暂存清理尚未完成，请稍后重试');
      this.checkCancelled(observer);
      const environment = installedModEnvironment(request.mcDir, request.versionId);
      if (environment.loader.length === 0 || !isModVersionCompatible(request.root, environment.loader, environment.gameVersion))
        throw new Error('所选文件不支持目标版本 ' + environment.loader + ' / MC ' + environment.gameVersion);
      observer.phase('正在核对已装模组与依赖');
      const initialFiles = await this.fingerprint(dir);
      const mr = request.router.repoFor(ModSource.MODRINTH);
      const cf = request.router.repoFor(ModSource.CURSEFORGE);
      const scanner = new LocalModScanner(mr === null ? null : mr as ModrinthRepository, cf === null ? null : cf as CurseForgeRepository);
      const scan = await scanner.scan({ mcDir: request.mcDir, versionId: request.versionId,
        versionIsolation: request.versionIsolation, kind: ResourceKind.MOD, fullVerify: true, lookupLimit: -1 });
      this.checkCancelled(observer);
      const primary = pickPrimaryFile(request.root.files);
      if (primary === null) throw new Error('主模组没有可下载文件');
      const oldPrimary = scan.mods.filter((m: LocalMod): boolean => m.remoteSource === request.root.source && m.remoteProjectId === request.root.projectId);
      const enabled = request.wasEnabled ?? (oldPrimary.length === 0 || oldPrimary.some((m: LocalMod): boolean => m.enabled));
      if (request.oldPath !== undefined && !scan.mods.some((m: LocalMod): boolean => m.filePath === request.oldPath))
        throw new Error('待更新文件已变化，请刷新后重试');
      const root = enabled ? request.root : JSON.parse(JSON.stringify(request.root)) as RemoteVersion;
      if (!enabled) root.dependencies = [];
      const options: ResolveOptions = { gameVersion: environment.gameVersion, loader: environment.loader,
        installed: scan.mods, followOptional: false, selectedOptionalIds: request.optionalIds.slice() };
      const resolved = await makeResolverFromRouter(request.router).resolve(root, options);
      const failures = dependencyPlanErrors(resolved);
      if (failures.length > 0) throw new Error('必需依赖尚未解决：\n' + failures.join('\n'));
      const planned: PlannedModFile[] = [];
      planned.push(await this.planFile(request.root, request.title, enabled, scan.mods, request, 'download/0'));
      for (const dep of resolved.dependencies) {
        if (dep.selected !== true || dep.alreadyInstalled || dep.version === null) continue;
        planned.push(await this.planFile(dep.version, dep.project?.title ?? dep.projectId, true, scan.mods, request, 'download/' + planned.length));
      }
      this.checkCancelled(observer);
      observer.files(planned.map((item: PlannedModFile): ModInstallFile => ({ title: item.title,
        projectId: item.version.projectId, versionId: item.version.id, source: item.version.source, file: item.file })));
      const staging = createModStaging(dir);
      const batch = new ModTransferBatch();
      let downloadReleased = true;
      try {
        const specs: DownloadFileSpec[] = [];
        for (const item of planned) {
          const parent = staging + '/' + item.stagedRelative.substring(0, item.stagedRelative.lastIndexOf('/'));
          ensureModDirectory(parent);
          specs.push(buildDownloadSpec(item.file, parent));
        }
        observer.phase('正在下载模组及前置（暂存）');
        // 每个文件都有真实 native 任务与进度；工人在事务 owner 内启动，不嵌套占用注册表槽位。
        downloadReleased = false;
        const workers: Promise<void>[] = [];
        for (let i = 0; i < Math.min(3, specs.length); i++)
          workers.push(this.downloadFiles(specs, planned, batch, observer, activityId));
        await Promise.all(workers);
        downloadReleased = await this.releaseBatch(batch);
        if (!downloadReleased) throw new Error('下载线程仍在结束，已保留暂存文件，请稍后重试');
        if (batch.error !== null) throw batch.error;
        this.checkCancelled(observer);
        observer.phase('正在检查模组组合');
        const removed = new Set<string>();
        for (const item of planned) for (const old of item.oldNames) removed.add(old);
        const descriptors: ModDescriptor[] = [];
        for (const m of scan.mods) {
          if (m.enabled && !removed.has(m.filename)) descriptors.push(...await readModDescriptors(m.filePath, environment.loader));
        }
        for (const item of planned) {
          const read = await readModDescriptors(staging + '/' + item.stagedRelative, environment.loader);
          if (item.enabled) descriptors.push(...read);
        }
        const errors = validateModSet(descriptors, environment);
        if (errors.length > 0) throw new Error('模组组合无法启动，原文件已保留：\n' + errors.join('\n'));
        const index = readInstalledModIndex(dir);
        const changes: ModFileChange[] = [];
        for (const item of planned) {
          for (const old of item.oldNames) index.remove(InstalledModIndex.baseNameOf(old));
          const sha1 = await computeFileSha1(staging + '/' + item.stagedRelative);
          const entry: InstalledModEntry = { baseName: item.file.filename, source: item.version.source, projectId: item.version.projectId,
            versionId: item.version.id, expectedSha1: sha1, expectedSize: fs.statSync(staging + '/' + item.stagedRelative).size,
            displayName: item.title, at: Date.now() };
          index.upsert(entry);
          changes.push({ stagedRelative: item.stagedRelative, newName: item.file.filename + (item.enabled ? '' : '.disabled'),
            oldNames: item.oldNames, sha1: sha1 });
        }
        ensureModDirectory(staging + '/download/index');
        const indexRelative = 'download/index/' + INSTALLED_MOD_INDEX_FILE;
        const shape: IndexShape = { version: 1, entries: index.entries() };
        writeModFile(staging + '/' + indexRelative, JSON.stringify(shape));
        changes.push({ stagedRelative: indexRelative, newName: INSTALLED_MOD_INDEX_FILE, oldNames: [INSTALLED_MOD_INDEX_FILE],
          sha1: await computeFileSha1(staging + '/' + indexRelative) });
        this.checkCancelled(observer);
        if (await this.fingerprint(dir) !== initialFiles) throw new Error('安装期间本地模组发生变化，已保留原文件，请刷新后重试');
        observer.phase('正在提交完整模组组合');
        await commitModFiles(dir, staging, changes);
        AppLogger.info(TAG, 'mod plan committed: root=' + request.root.id + ' files=' + planned.length + ' dir=' + dir, LOG_DOMAIN_DOWNLOAD);
      } finally {
        if (!downloadReleased) downloadReleased = await this.releaseBatch(batch);
        if (downloadReleased && !hasModRecoveryJournal(dir) && modFileExists(staging)) removeDirRecursive(staging);
      }
    });
  }

  /**
   * 有界文件工人：每次只领取一个索引，终态后再领取下一个。首次失败负责取消其他文件；
   * 工人吞下已保存的错误，让 Promise.all 等齐所有在途回调后再由事务统一抛出。
   */
  private async downloadFiles(specs: DownloadFileSpec[], planned: PlannedModFile[], batch: ModTransferBatch,
    observer: ModInstallObserver, activityId: number): Promise<void> {
    while (batch.next < specs.length && batch.error === null && !observer.cancelled()) {
      const index = batch.next++;
      const item = planned[index];
      // 同一项目/版本可能同时装入不同实例，名称也带上真实目的路径，避免 native journal 按名对账串组。
      const spec: DownloadTaskSpec = { name: 'mod-file:' + item.version.source + ':' + item.version.projectId + ':' + item.version.id + ':' + specs[index].localPath,
        files: [specs[index]], activityId: activityId };
      try {
        await DownloadManager.instance().createAndWait(spec, (view: DownloadTaskView): void => {
          if (view.taskId > 0 && batch.owners.indexOf(view.taskId) < 0) batch.owners.push(view.taskId);
          observer.fileProgress(index, view);
          if ((observer.cancelled() || batch.error !== null) && view.taskId > 0 && !view.finished)
            DownloadManager.instance().cancel(view.taskId);
        });
      } catch (e) {
        if (batch.error === null) batch.error = new Error(item.title + '：' + (e as Error).message);
        for (const id of batch.owners) {
          try { DownloadManager.instance().cancel(id); }
          catch (cancelError) { AppLogger.warn(TAG, '取消同组下载失败，仍等待其终态：' + id, cancelError as Error, LOG_DOMAIN_DOWNLOAD); }
        }
      }
    }
  }

  /** 所有 native owner 都释放后才允许移除 staging；某个尚未收敛不掩盖其他 owner 的释放尝试。 */
  private async releaseBatch(batch: ModTransferBatch): Promise<boolean> {
    let released = true;
    for (const id of batch.owners) if (!await this.releaseDownload(id)) released = false;
    return released;
  }

  private async planFile(version: RemoteVersion, title: string, enabled: boolean, installed: LocalMod[], request: ModInstallRequest,
    subdir: string): Promise<PlannedModFile> {
    let file = pickPrimaryFile(version.files);
    if (file === null) throw new Error(title + ' 没有可下载文件');
    if (file.url.length === 0 && version.source === ModSource.CURSEFORGE) {
      const repo = request.router.repoFor(version.source) as CurseForgeRepository | null;
      if (repo === null) throw new Error('CurseForge 来源不可用');
      const info = await repo.resolveFileDownloadInfo(version.projectId, version.id);
      file = { url: info.urls[0] ?? '', mirrors: info.urls.slice(1), filename: info.filename,
        size: info.size, isPrimary: true, sha1: info.sha1, sha512: file.sha512, fingerprint: file.fingerprint };
    }
    if (file.url.length === 0) throw new Error(title + ' 的下载地址不可用');
    const oldNames = installed.filter((m: LocalMod): boolean => (m.remoteSource === version.source && m.remoteProjectId === version.projectId)
      || m.filename === file!.filename || m.filename === file!.filename + '.disabled'
      || (version.id === request.root.id && m.filePath === request.oldPath)).map((m: LocalMod): string => m.filename);
    return { version: version, file: file, title: title, enabled: enabled, oldNames: oldNames,
      stagedRelative: subdir + '/' + file.filename };
  }

  private checkCancelled(observer: ModInstallObserver): void {
    if (observer.cancelled()) throw new Error('模组安装已取消');
  }

  private async releaseDownload(id: number): Promise<boolean> {
    if (id <= 0) return true;
    for (let attempt = 0; attempt < 30; attempt++) {
      if (DownloadManager.instance().purgeTask(id)) return true;
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
    }
    return false;
  }

  private async fingerprint(dir: string): Promise<string> {
    const names = fs.listFileSync(dir).filter((name: string): boolean => name.endsWith('.jar') || name.endsWith('.jar.disabled')).sort();
    const entries: ModFingerprint[] = [];
    for (const name of names) {
      const stat = fs.lstatSync(dir + '/' + name);
      if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('拒绝操作非普通模组文件：' + name);
      entries.push({ name: name, sha1: await computeFileSha1(dir + '/' + name) });
    }
    return JSON.stringify(entries);
  }
}

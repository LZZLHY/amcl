/**
 * ResourceInstallTask.ets — Mod / Shader / RPack / Datapack / Modpack 适配器
 *
 * 把 `ModInstaller.installBatch` 包装为 `UnifiedDownloadAdapter`，
 * 让 ModBrowsePage 安装入口走 `registry.enqueue(new ResourceInstallTask(...))`。
 *
 * 设计要点：
 *   - retry 直接重跑 installBatch（请求是 immutable，闭包内捕获 once）
 *   - 当前不支持 pause / resume（底层 DownloadManager 支持，但 mod 批量场景实际意义弱）
 *   - cancel 通过 DownloadManager.cancel(taskId) 透传
 *   - 多个 ResourceInstallTask 可同时跑（DownloadManager 已支持多任务）
 */

import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
} from 'feature_core';
import { DownloadManager, DownloadTaskView } from 'feature_core';
import { ModInstaller, InstallBatchRequest } from './ModInstaller';
import { ResourceKind, resourceKindToInstallDir } from './ModTypes';
import { DownloadTaskRegistry } from 'feature_core';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = 'ResourceInstallTask';

/** ResourceKind -> TaskCategory */
function kindToCategory(k: ResourceKind): TaskCategory {
  switch (k) {
    case ResourceKind.MOD:           return TaskCategory.MOD;
    case ResourceKind.SHADER:        return TaskCategory.SHADER;
    case ResourceKind.RESOURCE_PACK: return TaskCategory.RESOURCE_PACK;
    case ResourceKind.DATAPACK:      return TaskCategory.DATAPACK;
    case ResourceKind.MODPACK:       return TaskCategory.MODPACK;
    default:                          return TaskCategory.MOD;
  }
}

/** kind -> 中文标签（用于 subtitle） */
function kindLabel(k: ResourceKind): string {
  switch (k) {
    case ResourceKind.MOD:           return '模组';
    case ResourceKind.SHADER:        return '光影';
    case ResourceKind.RESOURCE_PACK: return '资源包';
    case ResourceKind.DATAPACK:      return '数据包';
    case ResourceKind.MODPACK:       return '整合包';
    default:                          return '资源';
  }
}

export interface ResourceInstallTaskInit {
  /** 用户友好的项目名（"Sodium" / "BSL Shaders"） */
  projectTitle: string;
  /** 项目图标 URL（可空）；用于下载卡片显示真实图标。 */
  iconUrl?: string;
  /** 安装请求体 */
  request: InstallBatchRequest;
}

/** 详情面板用：单个文件的展示数据 */
export interface ResourceFileEntry {
  filename: string;
  sizeBytes: number;
}

export interface ResourceFileProvider {
  getCurrentDmView(): DownloadTaskView | null;
  getFileEntries(): ResourceFileEntry[];
}

export class ResourceInstallTask implements UnifiedDownloadAdapter, ResourceFileProvider {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private projectTitle_: string;
  private request_: InstallBatchRequest;
  private taskId_: number = 0;
  /** 当前的 DownloadTaskView，cancel 时透传 taskId */
  private currentDmView_: DownloadTaskView | null = null;

  constructor(init: ResourceInstallTaskInit) {
    this.projectTitle_ = init.projectTitle;
    this.request_ = init.request;

    let cat = kindToCategory(init.request.kind);
    let label = kindLabel(init.request.kind);
    // The destination is part of identity, including installations into different Minecraft roots.
    let versionTag = '@dir=' + resourceKindToInstallDir(init.request.kind, init.request.mcDir, init.request.versionId, init.request.versionIsolation);
    this.view.id = cat + ':' + init.projectTitle + '@' + init.request.primary.filename + versionTag;
    this.view.category = cat;
    this.view.title = init.projectTitle;
    if (init.iconUrl !== undefined && init.iconUrl.length > 0) {
      this.view.iconUrl = init.iconUrl;
    }
    let depExtra = init.request.dependencies.length > 0
      ? ' · +' + init.request.dependencies.length + ' 依赖'
      : '';
    this.view.subtitle = label + ' · ' + init.request.primary.filename + depExtra;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canCancel = true;
    this.view.canViewDetail = true;
  }

  start(): Promise<void> {
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.errorMessage = '';
    this.view.errorKind = '';
    // 2026-08-04 修复「无法取消下载」：终态分支会置 canCancel=false，而这里过去不复位，
    // 于是重试起来的下载在 TaskCard 上根本没有取消按钮（`if (view.canCancel)` 不成立）。
    this.view.canCancel = true;
    this.view.canRetry = false;
    let installer = new ModInstaller(DownloadManager.instance());
    // 活动账本（L2-b）：用 registry 出队时设的 startedAtMs 作为 activityId，
    // 与活动记录主键一致
    installer.activityId = this.view.startedAtMs;
    return installer.installBatch(this.request_, (v: DownloadTaskView) => {
      this.currentDmView_ = v;
      this.taskId_ = v.taskId;
      this.syncView_(v);
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
    }).then((finalView: DownloadTaskView) => {
      this.currentDmView_ = finalView;
      this.syncView_(finalView);
      this.view.state = UnifiedTaskState.DONE;
      this.view.canCancel = false;
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
    }).catch((e: Error) => {
      let msg = e.message !== undefined ? e.message : String(e);
      let isCancelled = msg.indexOf('已取消') >= 0 || msg.indexOf('cancel') >= 0;
      this.view.state = isCancelled ? UnifiedTaskState.ABORTED : UnifiedTaskState.ERROR;
      this.view.errorMessage = msg;
      this.view.canCancel = false;
      this.view.canRetry = !isCancelled;
      try { DownloadTaskRegistry.instance().notifyChange(); } catch (e2) { /* ignore */ }
      throw e;
    });
  }

  cancel(_cleanupFiles: boolean): Promise<void> {
    let tid = this.taskId_;
    if (tid > 0) {
      try {
        DownloadManager.instance().cancel(tid);
        AppLogger.info(TAG, `cancel taskId=${tid} title=${this.projectTitle_}`, LOG_DOMAIN_DOWNLOAD);
      } catch (e) {
        let err = e as Error;
        AppLogger.warn(TAG, 'cancel threw', err as Object, LOG_DOMAIN_DOWNLOAD);
      }
    }
    // ModInstaller 不支持文件清理；NAPI cancel 后 createAndWait reject，start() 的 catch 把状态设为 ABORTED
    return Promise.resolve();
  }

  /** 资源安装不支持 pause（一般文件小、批量短，不需要） */
  pause(): Promise<void> {
    return Promise.resolve();
  }

  resume(): Promise<void> {
    return Promise.resolve();
  }

  retry(): Promise<void> {
    // ⚠️ 2026-07-29：不能在此校验 view.state ∈ {ERROR, ABORTED}。
    //   DownloadTaskRegistry.drainQueue_ 会在调用本方法**之前**把 view.state 置为
    //   pending.startState（PREPARING），这条守卫恒不满足 → 静默 return → 重试永不启动。
    //   准入已由 Registry.retry()（查 canRetry）+ scheduleAction_（查重入）完成。
    if (!this.purgeNativeOwner()) {
      return Promise.reject(new Error('旧资源下载任务仍在收敛，请稍后重试'));
    }
    return this.start();
  }

  purgeNativeOwner(): boolean {
    if (this.taskId_ <= 0) return true;
    let purged = DownloadManager.instance().purgeTask(this.taskId_);
    if (purged) {
      this.taskId_ = 0;
      this.currentDmView_ = null;
    }
    return purged;
  }

  dispose(): void {
    this.currentDmView_ = null;
  }

  /** 详情子视图查 currentFiles 等用 */
  getCurrentDmView(): DownloadTaskView | null {
    return this.currentDmView_;
  }

  /**
   * 详情子视图（Resource files panel）渲染用：返回 [primary, ...deps] 顺序的文件列表。
   * 每个 entry 含 filename + size（字节）。该列表是 immutable 的（请求一旦提交不再变化）。
   */
  getFileEntries(): ResourceFileEntry[] {
    let arr: ResourceFileEntry[] = [];
    arr.push({ filename: this.request_.primary.filename, sizeBytes: this.request_.primary.size });
    for (let d of this.request_.dependencies) {
      arr.push({ filename: d.filename, sizeBytes: d.size });
    }
    return arr;
  }

  // ============================================================
  //  DownloadTaskView -> UnifiedTaskView
  // ============================================================

  private syncView_(v: DownloadTaskView): void {
    // state
    if (v.finished) {
      // 终态由 then/catch 设置
    } else if (v.taskId === 0) {
      this.view.state = UnifiedTaskState.PREPARING;
    } else {
      this.view.state = UnifiedTaskState.DOWNLOADING;
    }
    // ⚠️ DownloadTaskView.progress 是 0.0~1.0 区间（fraction），
    // 而 UnifiedTaskView.progress 是 0~100 区间（percent），需要换算。
    this.view.progress = v.progress * 100;
    this.view.bytesDone = v.bytesDone;
    this.view.bytesTotal = v.bytesTotal;
    this.view.filesDone = v.filesDone;
    this.view.filesTotal = v.filesTotal;
    this.view.speedBps = v.speedBps;
    this.view.etaSeconds = v.etaSeconds;
    this.view.durationMs = v.durationMs;

    // currentLabel
    if (v.currentFile && v.currentFile.length > 0) {
      this.view.currentLabel = v.currentFile;
    } else if (v.currentFiles && v.currentFiles.length > 0) {
      this.view.currentLabel = v.currentFiles[0];
    } else {
      this.view.currentLabel = '';
    }

    // errorKind / message
    this.view.errorKind = v.errorKind || '';
    this.view.errorMessage = v.errorMessage || '';
  }
}

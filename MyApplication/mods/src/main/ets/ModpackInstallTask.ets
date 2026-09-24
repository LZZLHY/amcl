/**
 * ModpackInstallTask.ets — 整合包安装的统一下载任务适配器（P3）
 *
 * 文档：docs/guides/modpack-install-plan.md §七.3
 *
 * 把 `ModpackInstaller.installFromArchive` 包装成 `UnifiedDownloadAdapter`，
 * 让整合包安装和 MC / mod / JDK 任务在同一个 `DownloadTasksSheet` 里以橙色
 * MODPACK 卡片展示多阶段进度。
 *
 * 阶段映射（installer onPhase → view）：
 *   extracting → EXTRACTING（解压）
 *   preparing  → PREPARING（解析清单）
 *   base       → DOWNLOADING（建带 loader 的基础版本，期间进度不细分）
 *   files      → DOWNLOADING（按 filesDone/filesTotal 流式推进，占进度大头）
 *   overrides  → EXTRACTING（铺覆盖文件）
 *   done       → DONE
 *
 * 取消/暂停：整合包安装是复合流程（建版本 + 批量下载 + 复制），无法干净中断，
 * 故 canCancel/canPause/canResume = false；失败可 retry（整体重跑）。
 *
 * 创建日期：2026-06-15
 */

import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
  DownloadTaskRegistry,
} from 'feature_core';
import { ModpackInstaller, ModpackInstallRequest, ModpackInstallResult, CfFileResolver, ModpackProgress } from './ModpackInstaller';
import { ModpackMissingItem } from './ModpackSnapshot';

const TAG = 'ModpackInstallTask';

/** 构造参数。 */
export interface ModpackInstallTaskInit {
  /** registry 唯一 id（默认 'modpack:' + 标题）。 */
  id?: string;
  /** 卡片标题（整合包名）。 */
  title: string;
  /** 卡片副标题（来源 / 版本等）。 */
  subtitle?: string;
  /** 远程图标 URL（在线安装时可填项目图标）。 */
  iconUrl?: string;
  /** archive 路径 + 安装上下文（透传给 ModpackInstaller）。本地导入用 archivePath；在线用 archiveUrl。 */
  archivePath?: string;
  archiveUrl?: string;
  /** 在线安装：archive 镜像备源（多源容错）。 */
  archiveMirrors?: string[];
  archiveFilename?: string;
  mcDir: string;
  filesDir: string;
  existingVersions: string[];
  versionName?: string;
  projectId?: string;
  /** CurseForge 文件解析器（CF 整合包必需）。 */
  resolveCfFile?: CfFileResolver;
}

export class ModpackInstallTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();

  private init_: ModpackInstallTaskInit;
  private installer_: ModpackInstaller = new ModpackInstaller();
  /** 安装结果（含缺失清单），完成后供 UI 复查。 */
  private result_: ModpackInstallResult | null = null;

  constructor(init: ModpackInstallTaskInit) {
    this.init_ = init;
    this.view.id = (init.id !== undefined && init.id.length > 0) ? init.id : ('modpack:' + init.title);
    this.view.category = TaskCategory.MODPACK;
    this.view.title = init.title;
    this.view.subtitle = init.subtitle ?? '整合包';
    this.view.iconUrl = init.iconUrl ?? '';
    this.view.state = UnifiedTaskState.WAITING;
    this.view.canPause = false;
    this.view.canResume = false;
    this.view.canCancel = false;
    this.view.canRetry = false;
    // 详情视图已支持 MODPACK 分支（TaskDetailView.ModpackInfoPanel_），可查看
    this.view.canViewDetail = true;
  }

  /** 完成后取安装结果（缺失清单等）。 */
  getResult(): ModpackInstallResult | null {
    return this.result_;
  }

  start(): Promise<void> {
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.progress = 0;
    this.view.errorKind = '';
    this.view.errorMessage = '';
    // 运行中不该显示可点的重试按钮（Registry 也会兜一次，这里保持 adapter 自洽）。
    // canCancel 保持 false：整合包安装是复合流程，cancel() 目前是空实现，
    // 给出一个点了没反应的取消按钮比没有按钮更糟。
    this.view.canRetry = false;
    this.notify_();

    let req: ModpackInstallRequest = {
      archivePath: this.init_.archivePath,
      archiveUrl: this.init_.archiveUrl,
      archiveMirrors: this.init_.archiveMirrors,
      archiveFilename: this.init_.archiveFilename,
      mcDir: this.init_.mcDir,
      filesDir: this.init_.filesDir,
      existingVersions: this.init_.existingVersions,
      versionName: this.init_.versionName,
      projectId: this.init_.projectId,
      iconUrl: this.init_.iconUrl,
      resolveCfFile: this.init_.resolveCfFile,
      onPhase: (p: ModpackProgress): void => {
        this.onPhase_(p);
      },
    };

    // 活动账本（L2-b）：与活动记录同一主键（recordModpackActivity_ 用的也是 startedAtMs）
    this.installer_.activityId = this.view.startedAtMs;
    return this.installer_.installFromArchive(req).then((res: ModpackInstallResult) => {
      this.result_ = res;
      this.view.state = UnifiedTaskState.DONE;
      this.view.progress = 100;
      this.view.canRetry = false;
      // 标题用真正落地的版本名；缺失则在状态行提示
      this.view.title = res.versionName;
      if (res.missing.length > 0) {
        this.view.currentLabel = '完成（' + res.missing.length + ' 项缺失）';
        this.view.subtitle = '整合包 · 部分内容缺失';
      } else {
        this.view.currentLabel = '安装完成';
      }
      this.notify_();
      AppLogger.info(TAG, `done: ${res.versionName}, missing=${res.missing.length}`, LOG_DOMAIN_DOWNLOAD);
    }).catch((e: Error) => {
      this.view.state = UnifiedTaskState.ERROR;
      this.view.errorKind = 'ModpackInstall';
      this.view.errorMessage = (e.message !== undefined && e.message.length > 0) ? e.message : String(e);
      this.view.canRetry = true;
      this.notify_();
      AppLogger.warn(TAG, `failed: ${this.init_.title}`, e, LOG_DOMAIN_DOWNLOAD);
      throw e;
    });
  }

  cancel(cleanupFiles: boolean): Promise<void> {
    // 复合流程不可干净中断；仅作占位（registry 调用约定需返回 Promise）。
    return Promise.resolve();
  }

  pause(): Promise<void> { return Promise.resolve(); }
  resume(): Promise<void> { return Promise.resolve(); }

  retry(): Promise<void> {
    // ⚠️ 2026-07-29：同 JdkInstallTask/ResourceInstallTask —— 不能在此校验 view.state。
    //   Registry.drainQueue_ 调用本方法前已把 state 置为 PREPARING，
    //   `state !== ERROR` 恒成立 → 静默 return → 重试永不启动。
    if (!this.installer_.purgeNativeOwners()) {
      return Promise.reject(new Error('旧整合包下载任务仍在收敛，请稍后重试'));
    }
    return this.start();
  }

  purgeNativeOwner(): boolean {
    return this.installer_.purgeNativeOwners();
  }

  dispose(): void { /* 无长生命周期资源 */ }

  // ============================================================
  //  内部
  // ============================================================

  private onPhase_(p: ModpackProgress): void {
    this.view.currentLabel = p.message;
    // 通用字段（TaskCard / 详情页自动渲染速度 / 字节 / 文件 / 剩余时间）
    this.view.speedBps = p.speedBps;
    this.view.etaSeconds = p.etaSeconds;
    this.view.bytesDone = p.bytesDone;
    this.view.bytesTotal = p.bytesTotal;
    this.view.filesDone = p.current;
    this.view.filesTotal = p.total;
    switch (p.phase) {
      case 'pack':
        // archive 下载：0%→3%（字节细粒度）
        this.view.state = UnifiedTaskState.DOWNLOADING;
        this.view.progress = p.innerProgress >= 0 ? Math.round(p.innerProgress * 3) : 1;
        break;
      case 'extracting':
        this.view.state = UnifiedTaskState.EXTRACTING;
        this.view.progress = 3;
        this.clearTransfer_();
        break;
      case 'preparing':
        this.view.state = UnifiedTaskState.PREPARING;
        this.view.progress = 4;
        this.clearTransfer_();
        break;
      case 'resolving':
        // CF 文件解析：占 4%（窄带，细节交给文件计数 filesDone/Total 显示，避免 4↔5 抖动）
        this.view.state = UnifiedTaskState.PREPARING;
        this.view.speedBps = 0; this.view.bytesDone = 0; this.view.bytesTotal = 0;
        this.view.progress = 4;
        break;
      case 'base':
        // 建基础版本（含 loader，最大下载块）：5%→55%，由 McVersionTask 细粒度驱动
        this.view.state = UnifiedTaskState.DOWNLOADING;
        this.view.progress = p.innerProgress >= 0 ? 5 + Math.round(p.innerProgress * 50) : 5;
        break;
      case 'files':
        // 批量下模组/资源：55%→96%
        this.view.state = UnifiedTaskState.DOWNLOADING;
        this.view.progress = p.innerProgress >= 0 ? 55 + Math.round(p.innerProgress * 41) : 55;
        break;
      case 'overrides':
        this.view.state = UnifiedTaskState.EXTRACTING;
        this.view.progress = 97;
        this.clearTransfer_();
        break;
      case 'done':
        this.view.progress = 100;
        this.clearTransfer_();
        break;
      default:
        break;
    }
    this.notify_();
  }

  /** 清掉传输态字段（非下载阶段不显示速度 / 字节 / 文件计数）。 */
  private clearTransfer_(): void {
    this.view.speedBps = 0;
    this.view.etaSeconds = -1;
    this.view.bytesDone = 0;
    this.view.bytesTotal = 0;
    this.view.filesDone = 0;
    this.view.filesTotal = 0;
  }

  private notify_(): void {
    try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
  }
}

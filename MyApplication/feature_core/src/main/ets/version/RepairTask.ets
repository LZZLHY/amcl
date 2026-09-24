/**
 * RepairTask.ets — 版本文件【补全/修复】任务（方案 B）
 *
 * 与 McVersionTask（整版安装，需先从 manifest 解析）不同：本任务**直接读磁盘上已合并的
 * version.json**（versions/<id>/<id>.json，里面每个 client/library/assetIndex 都自带
 * url + sha1 + size），把这些文件清单交给统一下载器（McDownloader → C++ 原生引擎）。
 *
 * 为什么这样就是"自动补全"：原生引擎对每个文件做 `preCheckExistingFile`（size + sha1
 * 预检）——已存在且校验通过的文件瞬间转 Finished、不发 HTTP，只真正下载缺失/损坏的。
 * 因此重跑一遍下载清单 = 仅补全坏的文件。
 *
 * 覆盖范围：
 *   - 原版 + 模组版本通用（不依赖 loader 类型，不重装 loader，不查 manifest）。
 *   - 仅能修复"version.json 里带 downloads/url 的文件"（client / 官方库 / assets）。
 *     Forge 安装器现生成的产物（-client/-srg/-extra 等无 url）不在此列——那类需整版重装，
 *     校验报告里它们会以"损坏/缺失"呈现，提示用户重新安装 Forge。
 *
 * 作为 UnifiedDownloadAdapter 接入统一下载 UI（DownloadTasksSheet / FAB / 统计条）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
} from '../download/UnifiedDownloadTask';
import { DownloadTaskRegistry } from '../download/DownloadTaskRegistry';
import { McDownloader, VersionJson, DownloadProgress } from '../download/McDownloader';
import { CancelledError } from 'commons';
import { formatError } from 'commons';

const TAG = 'RepairTask';

export class RepairTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private mcDir_: string;
  private versionName_: string;
  private downloader_: McDownloader | null = null;
  /** retry/终态后仍保留 owner 集合，直到 Registry 确认 native purge。 */
  private ownedDownloaders_: McDownloader[] = [];
  private cancelled_: boolean = false;
  /** 总阶段数（client?/libraries/assets，运行时按 json 内容确定）与当前阶段序号（0-based）。 */
  private totalPhases_: number = 1;
  private phaseOrdinal_: number = 0;

  constructor(versionName: string, mcDir: string) {
    this.versionName_ = versionName;
    this.mcDir_ = mcDir;
    this.view.id = 'repair:' + versionName;
    this.view.category = TaskCategory.MC_VERSION;   // 复用 MC 蓝主题
    this.view.title = versionName;
    this.view.subtitle = '修复文件';
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canViewDetail = false;
    this.view.canCancel = true;
    this.view.canPause = false;
  }

  async start(): Promise<void> {
    this.cancelled_ = false;
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.currentLabel = '读取版本信息';
    this.view.errorMessage = '';
    // 2026-08-04 修复「无法取消下载」：abort_/fail_/完成分支都会置 canCancel=false，
    // 这里必须复位，否则重试起来的修复任务在 TaskCard 上没有取消按钮。
    this.view.canCancel = true;
    this.view.canRetry = false;
    this.notify_();

    // 1) 读取并解析磁盘上的合并 version.json
    let vj: VersionJson;
    try {
      let jsonPath = this.mcDir_ + '/versions/' + this.versionName_ + '/' + this.versionName_ + '.json';
      vj = JSON.parse(fs.readTextSync(jsonPath)) as VersionJson;
    } catch (e) {
      this.fail_('读取版本配置失败：' + formatError(e));
      throw e as Error;
    }

    // 2) 确定阶段数：client（有 downloads.client.url 才修）+ libraries + assets（有 assetIndex 才修）
    let hasClient = !!(vj.downloads && vj.downloads.client && vj.downloads.client.url
      && vj.downloads.client.url.length > 0);
    let hasAssets = !!(vj.assetIndex && vj.assetIndex.id && vj.assetIndex.id.length > 0);
    this.totalPhases_ = (hasClient ? 1 : 0) + 1 /* libraries */ + (hasAssets ? 1 : 0);
    if (this.totalPhases_ <= 0) this.totalPhases_ = 1;

    let dl = new McDownloader(this.mcDir_);
    this.ownedDownloaders_.push(dl);
    this.downloader_ = dl;
    dl.setProgressCallback((p: DownloadProgress) => this.onPhaseProgress_(p));

    this.view.state = UnifiedTaskState.DOWNLOADING;
    this.phaseOrdinal_ = 0;
    this.notify_();

    // 关键：三个阶段【相互独立】，单阶段失败不阻断其余阶段。
    //
    // 背景（2026-06-07 真机修复）：Forge 版本的部分依赖库是安装器本地处理产物 /
    // Forge maven 专属件，磁盘 sha1 与 json 声明不一致 → 引擎预检判定"需重下" →
    // 标准镜像（BMCLAPI/Mojang）没有这些件 → 整个 libraries 任务原子失败。原实现
    // 串行 await + throw，会让 libraries 阶段的失败直接中断、**assets 阶段根本跑不到**，
    // 导致"只是 assets 缺失"在任何 Forge 版本上都补不了。改为逐阶段容错：记录失败但继续，
    // 最后汇总。这样 assets 总能被补全；Forge 库补不了则提示需重装。
    let failed: string[] = [];
    let succeeded = 0;

    if (hasClient) {
      let r = await this.runPhase_(() => dl.downloadClientJar(vj, this.mcDir_ + '/versions/' + this.versionName_));
      if (r === 'cancelled') { this.abort_(); return; }
      if (r === 'ok') succeeded++; else failed.push('主程序');
      this.phaseOrdinal_++;
    }

    let rl = await this.runPhase_(() => dl.downloadLibraries(vj, true /* onlyMissing：只补缺失库，避开 Forge sha1 误判 */));
    if (rl === 'cancelled') { this.abort_(); return; }
    if (rl === 'ok') succeeded++; else failed.push('依赖库');
    this.phaseOrdinal_++;

    if (hasAssets) {
      let ra = await this.runPhase_(() => dl.downloadAssets(vj));
      if (ra === 'cancelled') { this.abort_(); return; }
      if (ra === 'ok') succeeded++; else failed.push('游戏资源');
      this.phaseOrdinal_++;
    }

    this.downloader_ = null;

    if (failed.length === 0) {
      this.view.state = UnifiedTaskState.DONE;
      this.view.progress = 100;
      this.view.currentLabel = '修复完成';
      this.view.canCancel = false;
      this.view.canRetry = false;
    } else if (succeeded > 0) {
      // 部分成功：assets 等已补全，但有阶段（多为 Forge 库）无法自动补全 —— 标 DONE 并提示。
      this.view.state = UnifiedTaskState.DONE;
      this.view.progress = 100;
      this.view.currentLabel = '已补全可修复文件；' + failed.join('、') + '无法自动补全（可能是 Forge 安装产物，需重装该版本）';
      this.view.canCancel = false;
      this.view.canRetry = true;
    } else {
      this.fail_('修复失败：' + failed.join('、') + ' 均无法补全（无可用下载源）');
    }
    this.notify_();
  }

  /** 跑单个阶段：成功返回 'ok'；被取消返回 'cancelled'；其它异常返回 'failed'（不抛）。 */
  private async runPhase_(fn: () => Promise<string>): Promise<string> {
    try {
      await fn();
      return 'ok';
    } catch (e) {
      if (this.cancelled_ || e instanceof CancelledError) return 'cancelled';
      hilog.warn(0x0000, TAG, 'repair phase failed (continue): %{public}s', formatError(e));
      return 'failed';
    }
  }

  private abort_(): void {
    this.downloader_ = null;
    this.view.state = UnifiedTaskState.ABORTED;
    this.view.currentLabel = '已取消';
    this.view.canCancel = false;
    this.view.canRetry = true;
    this.notify_();
  }

  cancel(_cleanupFiles: boolean): Promise<void> {
    this.cancelled_ = true;
    if (this.downloader_) {
      try { this.downloader_.cancel(); } catch (e) { /* ignore */ }
    }
    return Promise.resolve();
  }

  /** 补全任务不支持暂停/恢复（引擎层断点续传已覆盖"重跑只补缺"的语义）。 */
  pause(): Promise<void> { return Promise.resolve(); }
  resume(): Promise<void> { return Promise.resolve(); }

  /** 重试 = 重新跑一遍补全（引擎仍只下缺失/损坏文件）。 */
  retry(): Promise<void> {
    if (!this.purgeNativeOwner()) {
      return Promise.reject(new Error('旧修复下载任务仍在收敛，请稍后重试'));
    }
    return this.start();
  }

  purgeNativeOwner(): boolean {
    let retained: McDownloader[] = [];
    for (let downloader of this.ownedDownloaders_) {
      if (!downloader.purgeNativeOwners()) retained.push(downloader);
    }
    this.ownedDownloaders_ = retained;
    return retained.length === 0;
  }

  dispose(): void { this.downloader_ = null; this.ownedDownloaders_ = []; }

  // ============================================================
  //  内部
  // ============================================================

  private onPhaseProgress_(p: DownloadProgress): void {
    // 阶段内进度 → 全局进度：((已完成阶段 + 当前阶段内分数) / 总阶段数) * 100
    let intra = p.total > 0 ? Math.min(1, p.current / p.total) : 0;
    let overall = ((this.phaseOrdinal_ + intra) / this.totalPhases_) * 100;
    this.view.progress = Math.max(0, Math.min(100, overall));
    this.view.bytesDone = p.bytesDone !== undefined ? p.bytesDone : 0;
    this.view.bytesTotal = p.bytesTotal !== undefined ? p.bytesTotal : 0;
    this.view.speedBps = p.speedBps !== undefined ? p.speedBps : 0;
    this.view.etaSeconds = p.etaSeconds !== undefined ? p.etaSeconds : -1;
    this.view.currentLabel = p.fileName && p.fileName.length > 0
      ? p.stage + ' · ' + p.fileName : p.stage;
    this.notify_();
  }

  private fail_(msg: string): void {
    this.view.state = UnifiedTaskState.ERROR;
    this.view.errorMessage = msg;
    this.view.canRetry = true;
    this.view.canCancel = false;
    hilog.error(0x0000, TAG, 'repair %{public}s failed: %{public}s', this.versionName_, msg);
    this.notify_();
  }

  private notify_(): void {
    try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* ignore */ }
  }
}

/**
 * JdkInstaller.ets — 单次 JDK 下载/安装任务（per-task）
 *
 * 2026-05-26 重构（B-1 修复）：从 JdkManager 拆出"任务状态"为独立类。
 * 每个 JdkInstallTask 持有自己的 JdkInstaller 实例 —— 多 JDK 并发互不影响。
 *
 * 职责：
 *   - 下载 zip → SHA-256 校验 → 解压到目标目录
 *   - cancel token / progress callback / DownloadManager taskId 全部 per-instance
 *
 * 不持有的：
 *   - 只读 / 磁盘探测：仍在 JdkManager（getJdkDir, isInstalled, listVersions ...）
 *
 * 构造入口：JdkManager.createInstaller(version) → JdkInstaller。
 *
 * 设计要点：
 *   - 下载到独立目录 → 逐卷/全包校验 → staging 解压验证 → receipt 和目录一起发布
 *   - "已装则跳过下载"逻辑通过 init.isInstalledFn 注入，保留原幂等语义
 *
 * 详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md § B-1
 */

import { validateRuntimeTree } from './JdkTreeValidation';
import { JdkDirectoryLease } from './JdkDirectoryLease';
import { RuntimeDownload, RuntimePart, RuntimeInstallReceipt } from './RuntimeCatalogTypes';
import { RuntimeCatalogRepository } from './RuntimeCatalogRepository';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { removeDirRecursive } from 'commons';
import { ensureDirSync } from 'commons';
import { isJdkSlotVersion } from 'commons';
import { ActivityLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import {
  DownloadManager,
  DownloadTaskSpec,
  DownloadFileSpec,
  DownloadTaskView,
  formatSpeed as fmtSpeed,
  formatBytes as fmtBytes,
  safeBaseName,
  safeRelPath,
  decompressFile,
} from 'feature_core';
import {
  JdkVersionConfig, JdkDownloadCallback, JdkStatusCallback,
  RELEASE_BASE_URL, MIRROR_TEMPLATES, GITEE_RELEASE_BASE,
  getJdkDownloadSource,
} from './JdkManager';

const TAG = 'JdkInstaller';
const MAX_SAFE_URL_LENGTH = 4096;

function containsControlCharacter(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    let code = value.charCodeAt(i);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function isSafeHttpUrl(url: string): boolean {
  if (url.length === 0 || url.length > MAX_SAFE_URL_LENGTH) return false;
  if (containsControlCharacter(url) || /\s/.test(url)) return false;
  return /^https?:\/\/[^\/?#]+(?:[\/?#].*)?$/.test(url);
}

function isValidSha256(value: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(value);
}

function parentDirectory(path: string): string {
  let index = path.lastIndexOf('/');
  return index > 0 ? path.substring(0, index) : '';
}

function isPathInsideRoot(path: string, root: string): boolean {
  if (containsControlCharacter(path) || path.indexOf('\\') >= 0) return false;
  let prefix = root.endsWith('/') ? root : root + '/';
  if (!path.startsWith(prefix)) return false;
  let relative = path.substring(prefix.length);
  return safeRelPath(relative) === relative;
}

/** JdkInstaller 构造参数（由 JdkManager.createInstaller 注入） */
export interface JdkInstallerInit {
  context: Context;
  version: string;
  config: JdkVersionConfig;
  targetDir: string;
  /** 用于"已装则跳过下载"的探测函数（通常 = () => manager.isInstalled(version)） */
  isInstalledFn: () => boolean;
  /**
   * 强制重装：跳过"已装则跳过下载"的幂等门。
   *
   * 用于「更新」——那条路的前提是**已装且可用**（新语义下 tag 过期仍算可用），
   * 不跳过幂等门的话点了会瞬间报"安装完成"而什么都没做。
   * 缺省 false，普通安装路径行为不变。
   */
  forceReinstall?: boolean;
}

/**
 * 单次 JDK 下载/安装任务。所有字段实例化，多 installer 并发安全。
 *
 * 不变量：
 *   - 同一 installer 实例不能并发跑两个 downloadAndInstall（用 downloading_ 自旋锁）
 *   - cancel 在下载阶段同步生效（cancel NAPI 任务 + 设标志）；
 *     校验 / 解压前的检查点会响应；zlib.decompressFile 不可中断，解压完后才清理
 */
export class JdkInstaller {
  /**
   * 归属的活动主键（活动账本 · L2-b）；0 = 不归属。
   * 由 JdkInstallTask 用自己的 startedAtMs 赋值。
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
  private context_: Context;
  private version_: string;
  private config_: JdkVersionConfig;
  private targetDir_: string;
  private isInstalledFn_: () => boolean;
  private forceReinstall_: boolean = false;

  private downloading_: boolean = false;
  private cancelRequested_: boolean = false;
  private currentDmTaskId_: number = 0;
  /** Gitee 多卷并行下载时各卷的 DM taskId（供 requestCancel 一次性全部取消）。 */
  private giteeTaskIds_: number[] = [];
  /** 本 installer 创建过、尚未确认 native purge 的 owner。 */
  private ownedDmTaskIds_: number[] = [];
  /** 执行收敛超时后保留的独占下载目录；后续重试或删除任务触发的 purge 成功后才能清理。 */
  private deferredDownloadCleanup_: string[] = [];
  private onDownload_: JdkDownloadCallback | null = null;
  private onStatus_: JdkStatusCallback | null = null;
  /** 本次下载见过的最大 bytesDone。用于识别"分段重下导致字节回退"并在 UI 说明。 */
  private peakBytesDone_: number = 0;

  constructor(init: JdkInstallerInit) {
    this.context_ = init.context;
    this.version_ = init.version;
    // 构造入口本身也冻结描述，保证排队期间目录/调用者对象变化不会更换包或来源。
    this.config_ = JSON.parse(JSON.stringify(init.config)) as JdkVersionConfig;
    this.targetDir_ = init.targetDir;
    this.isInstalledFn_ = init.isInstalledFn;
    this.forceReinstall_ = init.forceReinstall === true;
  }

  /** 设置进度回调；传 null 解绑（adapter dispose 时用） */
  setDownloadCallback(cb: JdkDownloadCallback | null): void {
    this.onDownload_ = cb;
  }

  /** 可选：状态回调（"已就绪 ✅"等粗粒度提示），UI 大多走 onDownload 即可 */
  setStatusCallback(cb: JdkStatusCallback | null): void {
    this.onStatus_ = cb;
  }

  isDownloading(): boolean { return this.downloading_; }
  isCancelRequested(): boolean { return this.cancelRequested_; }

  private rememberDmTask_(taskId: number): void {
    if (taskId <= 0) return;
    if (this.ownedDmTaskIds_.indexOf(taskId) < 0) this.ownedDmTaskIds_.push(taskId);
  }

  /** Registry/retry owner barrier；native 已被成功自动 purge 时 DownloadManager 会幂等返回 true。 */
  purgeNativeOwners(): boolean {
    let retained: number[] = [];
    let dm = DownloadManager.instance();
    for (let taskId of this.ownedDmTaskIds_) {
      let purged = false;
      try { purged = dm.purgeTask(taskId); } catch (e) { purged = false; }
      if (!purged) retained.push(taskId);
    }
    this.ownedDmTaskIds_ = retained;
    if (retained.length === 0 && this.deferredDownloadCleanup_.length > 0) {
      const roots = this.deferredDownloadCleanup_;
      this.deferredDownloadCleanup_ = [];
      for (const root of roots) {
        try { removeDirRecursive(root); } catch (e) {
          // owner 已经退出，只是文件系统清理失败；保留路径给下次幂等回收，不影响屏障结论。
          this.deferredDownloadCleanup_.push(root);
        }
      }
    }
    return retained.length === 0;
  }

  /**
   * createAndWait 只保证逻辑终态，取消/失败时 curl 和 worker 可能仍持有路径。
   * 复用既有 purge 的 execution-settled 屏障。默认执行模式持续持有 writer 和外层
   * Registry action；约五秒的有限探测只供明确不拥有执行资格的调用者选择。
   * 路径/来源复用、哈希及 finally 清理均属于执行流程，不能因逻辑终态提前开始。
   */
  private async waitForNativeOwners_(retainOwner: boolean = true): Promise<boolean> {
    if (retainOwner) {
      if (this.purgeNativeOwners()) return true;
      for (const taskId of this.ownedDmTaskIds_.slice()) {
        await DownloadManager.instance().awaitTaskReleased(taskId, true);
      }
      // 仍由原方法逐项删除已释放身份和处理遗留目录，保持其幂等语义。
      return this.purgeNativeOwners();
    }
    for (let attempt = 0; attempt < 50; attempt++) {
      if (this.purgeNativeOwners()) return true;
      if (attempt < 49) await new Promise<void>((resolve): void => { setTimeout((): void => resolve(),100); });
    }
    return false;
  }

  /**
   * 用户请求取消下载。
   * 立刻把下载阶段的 NAPI 任务 cancel 掉；校验 / 解压阶段在下一个检查点退出。
   * 解压本身（zlib.decompressFile）不可中断；解压完成后才检查 cancel 并清理已落地文件。
   */
  requestCancel(): void {
    if (!this.downloading_) return;
    this.cancelRequested_ = true;
    if (this.currentDmTaskId_ > 0) {
      try {
        DownloadManager.instance().cancel(this.currentDmTaskId_);
        this.alog().info(TAG, `requestCancel: cancelled DM task ${this.currentDmTaskId_}`, LOG_DOMAIN_LAUNCH);
      } catch (e) { /* ignore */ }
    }
    // Gitee 多卷并行：逐个取消在跑的分卷任务
    this.cancelAllGiteeTasks();
  }

  /** 取消所有正在跑的 Gitee 并行分卷任务（并发下载失败/用户取消时用）。 */
  private cancelAllGiteeTasks(): void {
    for (const id of this.giteeTaskIds_) {
      if (id > 0) {
        try { DownloadManager.instance().cancel(id); } catch (e) { /* ignore */ }
      }
    }
  }

  private report(ready: boolean, progress: string): void {
    this.lastMessage_ = progress;
    if (this.onStatus_) {
      this.onStatus_({ ready, progress });
    }
  }

  private reportDownload(phase: string, percent: number, speedKBs: number, message: string): void {
    this.lastMessage_ = message;
    if (this.onDownload_) {
      this.onDownload_({ version: this.version_, phase, percent, speedKBs, message });
    }
  }

  /** 同时保留状态和下载回调的最后原因；adapter 不再把 boolean false 压成模糊失败。 */
  private lastMessage_: string = '';
  getFailureReason(): string { return this.lastMessage_; }

  /** 在任何删除/下载前校验所有会进入路径、URL 或完整性检查的配置字段。 */
  private validateInputs(): string {
    const info = this.config_;
    if (!isJdkSlotVersion(this.version_)) return 'JDK version 不是有效数字槽位';
    if (safeBaseName(info.tag).length === 0) return 'JDK tag 不是安全路径段';
    if (safeBaseName(info.dataFile).length === 0) return 'JDK asset 文件名不安全';
    if (info.sha256 === undefined || !isValidSha256(info.sha256)) {
      return 'JDK SHA-256 格式非法';
    }
    if (info.sizeBytes === undefined || !Number.isSafeInteger(info.sizeBytes) || info.sizeBytes <= 0) return 'JDK sizeBytes 非法';
    if (info.giteeParts !== undefined) {
      for (let part of info.giteeParts) {
        if (safeBaseName(part).length === 0) return 'JDK Gitee 分卷文件名不安全';
      }
    }
    if (info.giteePartSizes !== undefined) {
      if (info.giteeParts === undefined || info.giteePartSizes.length !== info.giteeParts.length) {
        return 'JDK Gitee 分卷大小列表不匹配';
      }
      for (let size of info.giteePartSizes) {
        if (size <= 0) return 'JDK Gitee 分卷大小非法';
      }
    }
    const installRoot = this.context_.filesDir + '/jdk';
    if (!isPathInsideRoot(this.targetDir_, installRoot)) return 'JDK targetDir 超出受控安装根目录';
    if (this.targetDir_ !== installRoot + '/' + this.version_) return 'JDK 目标目录与租约槽位不一致';
    return '';
  }

  // ============================================================
  //  主流程
  // ============================================================

  async downloadAndInstall(): Promise<boolean> {
    this.lastMessage_ = '';
    if (this.downloading_) {
      // 这条分支是"重试点了没反应"的一个真实嫌疑：若上一轮因异常未走到 finally，
      // downloading_ 会永久为 true，之后所有重试都在这里被自旋锁静默挡回。
      this.alog().warn(TAG,
        `downloadAndInstall rejected: already downloading (JDK ${this.version_})`,
        null, LOG_DOMAIN_LAUNCH);
      this.report(false, '已有下载任务进行中');
      return false;
    }
    this.alog().info(TAG, `downloadAndInstall start: JDK ${this.version_}`, LOG_DOMAIN_LAUNCH);
    const info = this.config_;
    if (!info.available) {
      this.report(false, 'JDK ' + this.version_ + ' 尚未发布，敬请期待');
      return false;
    }
    const validationError = this.validateInputs();
    if (validationError.length > 0) {
      this.report(false, 'JDK ' + this.version_ + ' 配置非法: ' + validationError);
      this.alog().error(TAG, validationError, null, LOG_DOMAIN_LAUNCH);
      return false;
    }

    this.downloading_ = true;
    this.cancelRequested_ = false;
    this.currentDmTaskId_ = 0;
    this.peakBytesDone_ = 0;
    const stepLabel = 'JDK ' + this.version_;
    const targetDir = this.targetDir_;
    const installRoot = this.context_.filesDir + '/jdk';
    const token = this.version_ + '-' + Date.now().toString() + '-'
      + Math.floor(Math.random() * 1000000000).toString();
    const downloadRoot = this.context_.cacheDir + '/jdk-install-staging/' + token;
    const extractRoot = installRoot + '/.staging-' + token;
    const zipPath = downloadRoot + '/archive.zip';
    let writerLease: JdkDirectoryLease | null = null;

    try {
      // ⚠️ 2026-08-29：`forceReinstall_` 必须参与这道门。
      // 这道门原本的意思是"已装就跳过下载"（幂等）。而「更新」这条路的前提恰恰是
      // **已装且可用**（新语义下 stale-advisory 仍算已装，见 JdkUpdatePolicy.ets），
      // 所以不绕过它的话，用户点「更新」会直接命中 `isInstalledFn_() == true`
      // 而跳过整段下载 —— 表现是"点了没反应、瞬间说安装完成"，且不报错。
      if (this.forceReinstall_ || !this.isInstalledFn_()) {
        writerLease = JdkDirectoryLease.writer(this.context_.filesDir, this.version_);
        // 下载和解压都只写唯一 staging；旧安装在新内容校验完成前保持不动。
        this.report(false, '准备安全安装目录...');
        // ⚠️ 必须用幂等的 ensureDirSync：installRoot（filesDir/jdk）在任何装过一次 JDK 的
        //   设备上都已存在，而 fs.mkdirSync(path, true) 对【已存在的目标目录】仍抛 EEXIST
        //   ("File exists")。曾经这里直接 rethrow，导致所有 JDK 的下载在开始前就失败。
        ensureDirSync(downloadRoot);
        ensureDirSync(installRoot);
        try { removeDirRecursive(extractRoot) } catch (e) {}

        const ok = await this.downloadJdkArchive(zipPath, stepLabel);
        if (!ok) return false;

        const installedOk = await this.completeJdkInstall(zipPath, targetDir, extractRoot, stepLabel);
        if (!installedOk) return false;
      }

      // 最后 marker 验证
      if (this.isInstalledFn_()) {
        this.reportDownload('verifying', 100, 0, stepLabel + ' 安装完成 ✅');
        this.report(true, stepLabel + ' 安装完成 ✅');
        return true;
      }
      this.report(false, '❌ ' + stepLabel + ' 安装验证失败');
      return false;
    } catch (error) {
      let err = error as Error;
      this.alog().error(TAG, 'Download failed', error as Object, LOG_DOMAIN_LAUNCH);
      this.reportDownload('downloading', 0, 0, '下载失败: ' + err.message);
      return false;
    } finally {
      // 尤其是取消阶段，Promise 返回不代表原生文件写者退出。执行模式持续等 owner，
      // 在真实释放前保留 writer/Registry 资格，不能只保留目录却放走外层执行栈。
      if (await this.waitForNativeOwners_()) {
        try { removeDirRecursive(downloadRoot) } catch (e) {}
      } else {
        this.deferredDownloadCleanup_.push(downloadRoot);
        this.alog().warn(TAG,'原生下载仍在结束，暂时保留独占目录：' + downloadRoot,null,LOG_DOMAIN_LAUNCH);
      }
      if (writerLease !== null) writerLease.release();
      this.currentDmTaskId_ = 0;
      this.giteeTaskIds_ = [];
      try { removeDirRecursive(extractRoot) } catch (e) {}
      this.downloading_ = false;
    }
  }

  // ============================================================
  //  走 DownloadManager 下载单个 JDK zip
  // ============================================================
  //
  // 设计：
  //   - 把 4 个镜像同时装入 spec.urls，引擎内部逐个 fallback
  //   - 填 sizeBytes 为 DownloadCheck.size，下载期间 size mismatch 会快速失败
  //   - SHA-1 不填（项目选择 SHA-256，由 ArkTS 层 verifyArchiveIntegrity 完成）
  //   - onProgress 接收引擎事件并转换为现有 JdkDownloadCallback 语义
  // ============================================================

  /**
   * v7.7 / v7.9：优先从 Gitee 国内镜像下载。
   *   - 单卷：单连接全量 GET（Gitee 不支持 Range → maxConnections=1）。
   *   - 多卷（v7.9 新）：各卷**并行**下载（每卷仍单连接全量 GET），2+ 条连接同时占满带宽 ≈ N 倍
   *     单卷速度；全部完成后按序二进制拼接成 zipPath。任一卷失败即取消其余卷 + 清理并返回 false，
   *     由调用方回退 GitHub 代理多段下载。最终 SHA-256 仍由 completeJdkInstall 在 zipPath 上统一把关
   *     （拼接错/内容错都会被拦下）。
   */
  private async tryGiteeDownload(zipPath: string, stepLabel: string): Promise<boolean> {
    const info = this.config_;
    const parts = info.giteeParts;
    if (parts === undefined || parts.length === 0) return false;
    const sizes = info.giteePartSizes;
    // 总大小（用于跨卷平滑进度）：优先各卷之和，否则退回 info.sizeBytes。
    let totalBytes = 0;
    if (sizes !== undefined && sizes.length === parts.length) {
      for (const s of sizes) totalBytes += s;
    } else if (info.sizeBytes !== undefined) {
      totalBytes = info.sizeBytes;
    }
    if (parts.length === 1) {
      return await this.downloadGiteeSingle(zipPath, stepLabel, totalBytes);
    }
    return await this.downloadGiteeParallel(zipPath, stepLabel, totalBytes);
  }

  /** 单卷 Gitee 下载：单连接全量 GET，直接落地到 zipPath。 */
  private async downloadGiteeSingle(zipPath: string, stepLabel: string, totalBytes: number): Promise<boolean> {
    const info = this.config_;
    const parts = info.giteeParts as string[];
    const sizes = info.giteePartSizes;
    const dm = DownloadManager.instance();
    try {
      if (this.cancelRequested_) return false;
      const url = GITEE_RELEASE_BASE + '/' + info.tag + '/' + parts[0];
      if (!isSafeHttpUrl(url)) throw new Error('Unsafe Gitee JDK URL');
      const partSize = (sizes !== undefined && sizes.length > 0) ? sizes[0] : 0;
      const allowedRoot = parentDirectory(zipPath);
      const fileSpec: DownloadFileSpec = (partSize > 0)
        ? { localPath: zipPath, urls: [url], allowedRoot: allowedRoot, maxConnections: 1, check: { size: partSize } }
        : { localPath: zipPath, urls: [url], allowedRoot: allowedRoot, maxConnections: 1 };
      const spec: DownloadTaskSpec = {
        name: 'JDK ' + this.version_ + ' Gitee',
        files: [fileSpec],
        activityId: this.activityId,
      };
      const label = stepLabel + ' Gitee';
      const view = await dm.createAndWait(spec, (v: DownloadTaskView) => {
        if (v.taskId > 0) {
          this.currentDmTaskId_ = v.taskId;
          this.rememberDmTask_(v.taskId);
        }
        // 无 Range 全量 GET → 引擎报 bytesTotal=-1，用已知大小算进度。
        if (totalBytes > 0) {
          const done = Math.max(0, v.bytesDone);
          const percent = Math.min(99, Math.max(0, Math.round(done / totalBytes * 100)));
          const speedKBs = Math.max(0, Math.round(v.speedBps / 1024));
          this.reportDownload('downloading', percent, speedKBs,
            label + ' ' + percent + '% ' + fmtBytes(done) + '/' + fmtBytes(totalBytes)
            + ' [' + fmtSpeed(v.speedBps) + ']');
        } else {
          this.bridgeProgress(label, v);
        }
      });
      this.currentDmTaskId_ = 0;
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 下载资源仍在结束，请稍后重试');
      if (this.cancelRequested_) return false;
      this.alog().info(TAG, `JDK ${this.version_} Gitee single ok: ${view.bytesDone} bytes`, LOG_DOMAIN_LAUNCH);
      return true;
    } catch (e) {
      this.alog().warn(TAG, `JDK ${this.version_} Gitee single download error`, e as Object, LOG_DOMAIN_LAUNCH);
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 下载资源仍在结束，已保留下载现场，请稍后重试');
      try { fs.unlinkSync(zipPath) } catch (e2) {}
      try { fs.unlinkSync(zipPath + '.download-meta') } catch (e2) {}
      return false;
    }
  }

  /**
   * 多卷 Gitee 并行下载：为每卷起一个独立单连接任务同时跑（Promise.all），进度按「各卷 bytesDone
   * 之和 / 总大小」聚合、速度按各卷之和显示。全部完成后按序拼接成 zipPath。任一卷失败/取消 →
   * 取消其余卷 + 清临时文件，返回 false 回退 GitHub。
   */
  private async downloadGiteeParallel(zipPath: string, stepLabel: string, totalBytes: number): Promise<boolean> {
    const info = this.config_;
    const parts = info.giteeParts as string[];
    const sizes = info.giteePartSizes;
    const dm = DownloadManager.instance();
    const n = parts.length;
    const partPaths: string[] = [];
    const partDone: number[] = [];
    const partSpeed: number[] = [];
    for (let i = 0; i < n; i++) { partPaths.push(zipPath + '.p' + i); partDone.push(0); partSpeed.push(0); }
    this.giteeTaskIds_ = [];
    const tasks: Promise<DownloadTaskView>[] = [];
    try {
      for (let i = 0; i < n; i++) {
        const idx = i;
        const url = GITEE_RELEASE_BASE + '/' + info.tag + '/' + parts[idx];
        if (!isSafeHttpUrl(url)) throw new Error('Unsafe Gitee JDK part URL');
        const dest = partPaths[idx];
        const partSize = (sizes !== undefined && idx < sizes.length) ? sizes[idx] : 0;
        const allowedRoot = parentDirectory(zipPath);
        const fileSpec: DownloadFileSpec = (partSize > 0)
          ? { localPath: dest, urls: [url], allowedRoot: allowedRoot, maxConnections: 1, check: { size: partSize } }
          : { localPath: dest, urls: [url], allowedRoot: allowedRoot, maxConnections: 1 };
        const spec: DownloadTaskSpec = {
          name: 'JDK ' + this.version_ + ' Gitee ' + (idx + 1) + '/' + n,
          files: [fileSpec],
          activityId: this.activityId,
        };
        tasks.push(dm.createAndWait(spec, (v: DownloadTaskView) => {
          if (v.taskId > 0) {
            if (this.giteeTaskIds_.indexOf(v.taskId) < 0) this.giteeTaskIds_.push(v.taskId);
            this.rememberDmTask_(v.taskId);
          }
          partDone[idx] = Math.max(0, v.bytesDone);
          partSpeed[idx] = Math.max(0, v.speedBps);
          this.reportGiteeAggregate(stepLabel, partDone, partSpeed, totalBytes);
        }));
      }
      const views = await Promise.all(tasks);
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 分卷资源仍在结束，请稍后重试');
      this.giteeTaskIds_ = [];
      if (this.cancelRequested_) {
        for (const p of partPaths) { try { fs.unlinkSync(p) } catch (e) {} }
        return false;
      }
      for (let i = 0; i < views.length; i++) {
        this.alog().info(TAG,
          `JDK ${this.version_} Gitee part ${i + 1}/${n} ok: ${views[i].bytesDone} bytes`,
          LOG_DOMAIN_LAUNCH);
      }
      this.reportDownload('downloading', 99, 0, stepLabel + ' 合并分卷…');
      this.concatParts(partPaths, zipPath);
      for (const p of partPaths) { try { fs.unlinkSync(p) } catch (e) {} }
      return true;
    } catch (e) {
      this.alog().warn(TAG, `JDK ${this.version_} Gitee parallel download error`, e as Object, LOG_DOMAIN_LAUNCH);
      this.cancelAllGiteeTasks();   // 某卷失败，取消其余仍在跑的卷
      await Promise.allSettled(tasks);
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 分卷资源仍在结束，已保留下载现场，请稍后重试');
      this.giteeTaskIds_ = [];
      for (const p of partPaths) { try { fs.unlinkSync(p) } catch (e2) {} }
      try { fs.unlinkSync(zipPath) } catch (e2) {}
      try { fs.unlinkSync(zipPath + '.download-meta') } catch (e2) {}
      return false;
    }
  }

  /** 多卷并行进度聚合：percent = Σ各卷已下 / 总大小；speed = Σ各卷速度。 */
  private reportGiteeAggregate(stepLabel: string, partDone: number[], partSpeed: number[], totalBytes: number): void {
    if (totalBytes <= 0) return;
    let done = 0; for (const d of partDone) done += d;
    let sp = 0; for (const s of partSpeed) sp += s;
    const percent = Math.min(99, Math.max(0, Math.round(done / totalBytes * 100)));
    const speedKBs = Math.max(0, Math.round(sp / 1024));
    this.reportDownload('downloading', percent, speedKBs,
      stepLabel + ' 步骤 1/3：下载（Gitee 分卷并行）' + percent + '% '
      + fmtBytes(done) + '/' + fmtBytes(totalBytes) + ' [' + fmtSpeed(sp) + ']');
  }

  /** 按序把分卷文件二进制拼接成 dest（覆盖写，1MB 分块拷贝避免大文件一次性入内存）。 */
  private concatParts(parts: string[], dest: string): void {
    let out: fs.File | null = null;
    try {
      out = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const buf = new ArrayBuffer(1024 * 1024);
      for (const p of parts) {
        let inp: fs.File | null = null;
        try {
          inp = fs.openSync(p, fs.OpenMode.READ_ONLY);
          while (true) {
            const n = fs.readSync(inp.fd, buf);
            if (n <= 0) break;
            fs.writeSync(out.fd, buf, { length: n });
          }
        } catch (e) {
          throw e as Error;
        } finally {
          if (inp) {
            try { fs.closeSync(inp); } catch (_) { /* 关闭失败不覆盖实际拼接错误 */ }
          }
        }
      }
    } catch (e) {
      // 保留异常传播：tryGiteeDownload 的外层 catch 会清理残留文件并回退 GitHub 镜像。
      throw e as Error;
    } finally {
      if (out) {
        try { fs.closeSync(out); } catch (_) { /* 关闭失败不覆盖实际拼接错误 */ }
      }
    }
  }

  /**
   * 按下载源偏好构造 GitHub 直链的候选 URL 列表（喂给下载引擎的 urls[]，引擎会再按 RTT 重排/回退）。
   *   - 'github' → GitHub 源站直连（`{url}`）排首位（开代理/VPN 用户满速，比任何镜像都快），
   *                代理镜像作回退；
   *   - 其余（auto / gitee 回退 / mirror）→ 沿用 MIRROR_TEMPLATES 原序（代理镜像优先、直连兜底）。
   */
  private buildGithubUrls(ghUrl: string, source: string): string[] {
    if (!isSafeHttpUrl(ghUrl)) throw new Error('Unsafe GitHub JDK URL');
    const urls: string[] = [];
    const pushUrl = (url: string): void => {
      if (!isSafeHttpUrl(url)) throw new Error('Unsafe JDK mirror URL');
      if (urls.indexOf(url) < 0) urls.push(url);
    };
    if (source === 'github') {
      // ⚠️ 2026-07-29 修复「选了源站却在跑镜像」：
      //   旧实现把 6 个代理镜像也塞进 urls[]，只是让源站排首位。但 urls[] 对引擎是
      //   **等价候选池**——SourceProber/pickBestSource 会按 RTT/吞吐重排，且
      //   initSegments 还按 `i % nsrc` 把 16 段轮询钉到各镜像上。结果用户明确选择
      //   「GitHub 源站」，实际却是 16 段散在 6 个代理上跑（日志实锤：
      //   `downloaded via 6 mirror(s)` + 887 条 gh.ddlc.top 的 429）。
      //   这也正是「每次卡在 70% 上下」的根源：16 段按 i%6 分配 → 快源的 10~12 段
      //   先完成（≈70%），剩下钉在限流镜像上的 4~6 段被 429 反复拒绝，进度就停在那里。
      //   语义厘清：'github' = 只用源站直连，不掺代理（要代理请选 'mirror' 或 'auto'）。
      pushUrl(ghUrl);
    } else if (source === 'mirror') {
      // ⚠️ 2026-07-29：'mirror' = **只用代理镜像**，绝不掺 GitHub 源站直连。
      //   MIRROR_TEMPLATES 的最后一项是 '{url}'（源站兜底），此前 mirror 分支把它
      //   一并 push 进 urls[] → github.com 成了第 6 个等价候选源。而它又在
      //   engine.cpp 的 kProtectedHostSubstr 白名单里**永不熔断**，于是设备直连
      //   GitHub 不通时（真机：Failed to connect ... after 6001 ms）它被反复重选、
      //   每次白等 6 秒，成了最大的时间黑洞（实测失败 49 次，居各源之首），
      //   表现为尾段长期卡住（8x%~99%）。
      //   语义厘清：用户选了镜像就只走镜像；要源站请选 'github'，要两者兼顾选 'auto'。
      for (const tpl of MIRROR_TEMPLATES) {
        if (tpl === '{url}') continue;   // 跳过源站直连
        pushUrl(tpl.replace('{url}', ghUrl));
      }
    } else {
      // auto：代理镜像优先 + 源站兜底（保持原有行为）
      for (const tpl of MIRROR_TEMPLATES) {
        pushUrl(tpl.replace('{url}', ghUrl));
      }
    }
    return urls;
  }

  private async downloadJdkArchive(zipPath: string, stepLabel: string): Promise<boolean> {
    const info = this.config_;
    const source = info.downloadSource !== undefined ? info.downloadSource : getJdkDownloadSource();
    if (info.downloads !== undefined) return this.downloadCatalogArchive(zipPath,stepLabel,source);

    // v7.8：按用户下载源偏好决定是否 Gitee 优先。
    //   auto / gitee → 先试 Gitee（国内直连、单连接就快）；github / mirror → 跳过 Gitee 直接走 GitHub。
    // Gitee 成功即返回；失败自动回退到下面的 GitHub 多镜像下载（gitee 强制模式失败也回退，保证可用）。
    const giteeAvailable = info.giteeParts !== undefined && info.giteeParts.length > 0;
    const giteeFirst = giteeAvailable && (source === 'auto' || source === 'gitee');
    if (giteeFirst) {
      const okGitee = await this.tryGiteeDownload(zipPath, stepLabel);
      if (okGitee) return true;
      if (this.cancelRequested_) return false;
      this.alog().warn(TAG, `JDK ${this.version_} Gitee download failed (source=${source}), fallback to GitHub mirrors`, null, LOG_DOMAIN_LAUNCH);
      this.reportDownload('downloading', 0, 0, stepLabel + ' Gitee 不可用，改用 GitHub 镜像…');
    }

    const ghUrl = RELEASE_BASE_URL + '/' + info.tag + '/' + info.dataFile;
    const urls: string[] = this.buildGithubUrls(ghUrl, source);

    let file: DownloadFileSpec;
    const allowedRoot = parentDirectory(zipPath);
    if (allowedRoot.length === 0) throw new Error('Invalid JDK download staging root');
    // 并发按【候选源数量】定：
    //   多源（auto/mirror，6 个代理）→ 16 段，engine 按 i%nsrc 分散到各镜像抵消单 IP 限速；
    //   单源（'github' 源站直连）→ 6 段。16 条连接全压 GitHub 同一主机反而触发对端限速/切流，
    //   6 条在实测里既能吃满带宽又不至于被掐（且尾段仍可由 maybeGrowThreads 自适应补位）。
    const maxConn = urls.length > 1 ? 16 : 6;
    if (info.sizeBytes !== undefined && info.sizeBytes > 0) {
      file = {
        localPath: zipPath,
        urls: urls,
        allowedRoot: allowedRoot,
        check: { size: info.sizeBytes },
        maxConnections: maxConn,
      };
    } else {
      file = {
        localPath: zipPath,
        urls: urls,
        allowedRoot: allowedRoot,
        maxConnections: maxConn,
      };
    }

    const spec: DownloadTaskSpec = {
      name: 'JDK ' + this.version_ + ' (' + info.dataFile + ')',
      files: [file],
      activityId: this.activityId,
    };

    this.reportDownload('downloading', 0, 0,
      stepLabel + (urls.length > 1 ? ' 连接下载引擎中（多镜像并行）...' : ' 连接 GitHub 源站中...'));

    const dm = DownloadManager.instance();
    try { dm.initializeCaBundle(this.context_); } catch (e) { /* 不影响主流程 */ }

    try {
      const view = await dm.createAndWait(spec, (v: DownloadTaskView) => {
        // 记录 taskId 让 requestCancel 能透传给 NAPI cancel，并保留到 Registry purge。
        if (v.taskId > 0) {
          this.currentDmTaskId_ = v.taskId;
          this.rememberDmTask_(v.taskId);
        }
        this.bridgeProgress(stepLabel, v);
      });
      this.currentDmTaskId_ = 0;
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 下载资源仍在结束，请稍后重试');
      this.alog().info(TAG,
        `JDK ${this.version_} downloaded: ${view.bytesDone} bytes via ${urls.length} mirror(s)`,
        LOG_DOMAIN_LAUNCH);
      return true;
    } catch (e) {
      const err = e as Error;
      this.alog().error(TAG, 'JDK download via DownloadManager failed', e as Object, LOG_DOMAIN_LAUNCH);
      this.reportDownload('downloading', 0, 0,
        stepLabel + ' 下载失败：' + err.message);
      if (!await this.waitForNativeOwners_()) throw new Error('JDK 下载资源仍在结束，已保留下载现场，请稍后重试');
      try { fs.unlinkSync(zipPath) } catch (e2) {}
      try { fs.unlinkSync(zipPath + '.download-meta') } catch (e2) {}
      return false;
    }
  }

  /**
   * 通用目录下载：来源先过滤，再创建引擎任务。分卷逐个验证自身 SHA，拼接后仍验全包。
   * 每次失败先等所有已创建任务结束，再清理文件；不会留下后台任务向已删除路径继续写。
   * 配置由工厂深拷贝冻结，因此刷新目录只影响后续任务。
   */
  private async downloadCatalogArchive(zipPath: string, label: string, preference: string): Promise<boolean> {
    const candidates: RuntimeDownload[] = [];
    for (const d of this.config_.downloads!) {
      if (d.sourceId === 'web' && this.config_.webEnabled !== true) continue;
      if (preference === 'web' && d.sourceId !== 'web') continue;
      if ((preference === 'github' || preference === 'mirror') && d.sourceId !== 'github') continue;
      candidates.push(d);
    }
    candidates.sort((a: RuntimeDownload,b: RuntimeDownload): number => {
      const order: string[] = preference === 'web' ? ['web'] : ['gitee','github','web'];
      return order.indexOf(a.sourceId) - order.indexOf(b.sourceId);
    });
    const dm = DownloadManager.instance(); dm.initializeCaBundle(this.context_);
    for (const source of candidates) {
      const paths: string[] = [];
      try {
        if (this.cancelRequested_) return false;
        const parts: RuntimePart[] = source.transport === 'single-file'
          ? [{ url:source.url!,sizeBytes:this.config_.sizeBytes!,sha256:this.config_.sha256! }]
          : source.parts!;
        const done: number[] = parts.map((): number => 0);
        const speeds: number[] = parts.map((): number => 0);
        const tasks: Promise<void>[] = [];
        this.giteeTaskIds_ = [];
        for (let i = 0; i < parts.length; i++) {
          const part = parts[i]; const path = source.transport === 'single-file' ? zipPath : zipPath + '.p' + i;
          paths.push(path);
          const urls: string[] = source.sourceId === 'github' ? this.buildGithubUrls(part.url,preference) : [part.url];
          const file: DownloadFileSpec = { localPath:path,urls:urls,allowedRoot:parentDirectory(zipPath),
            maxConnections:source.sourceId === 'gitee' ? 1 : (urls.length > 1 ? 16 : 6),check:{size:part.sizeBytes} };
          const spec: DownloadTaskSpec = { name:label + ' ' + source.sourceId + ' ' + (i + 1) + '/' + parts.length,
            files:[file],activityId:this.activityId };
          const index = i;
          const task = async (): Promise<void> => {
            if (this.cancelRequested_) throw new Error('已取消');
            let nativeId = 0;
            try { await dm.createAndWait(spec,(view: DownloadTaskView): void => {
              if (view.taskId > 0) {
                nativeId = view.taskId;
                this.currentDmTaskId_ = view.taskId; this.rememberDmTask_(view.taskId);
                if (this.giteeTaskIds_.indexOf(view.taskId) < 0) this.giteeTaskIds_.push(view.taskId);
              }
              done[index] = Math.max(0,view.bytesDone); speeds[index] = Math.max(0,view.speedBps);
              let bytes = 0; let speed = 0;
              for (const count of done) bytes += count;
              for (const rate of speeds) speed += rate;
              const percent = Math.min(99,Math.floor(bytes / this.config_.sizeBytes! * 100));
              this.reportDownload('downloading',percent,Math.round(speed / 1024),label + ' ' + source.sourceId + ' ' + percent + '%');
            }); } finally {
              // 分卷的 SHA256 本身也不能与原写者重叠；只等待本卷，不能在一卷内
              // 等整个集合，否则它的校验错误无法及时通知外层取消其余在途分卷。
              if (nativeId > 0) {
                let released = false;
                try { released = dm.purgeTask(nativeId); } catch (_) { /* 桥异常不是释放事实。 */ }
                if (!released) await dm.awaitTaskReleased(nativeId, true);
              }
            }
            if (fs.statSync(path).size !== part.sizeBytes || await this.computeFileSha256(path) !== part.sha256) {
              throw new Error('下载文件身份不符：' + source.sourceId + ' 分卷 ' + (index + 1));
            }
          };
          tasks.push(task());
        }
        // 保留 Gitee 每卷单连接、各卷并行的吞吐；失败时先取消并等待全部写者终止，
        // 再进入外层清理/来源回退，避免旧任务继续写入已经复用的 .pN 路径。
        try { await Promise.all(tasks); }
        catch (e) { this.cancelAllGiteeTasks(); await Promise.allSettled(tasks); throw e as Error; }
        // 所有 Promise 结束只证明终态回调已送达。必须再释放真实 native owner，
        // 才能读取/拼接分卷，或在后续来源中复用同一组 .pN 路径。
        if (!await this.waitForNativeOwners_()) {
          this.report(false,'JDK 下载资源仍在结束，已保留下载现场，请稍后重试'); return false;
        }
        this.currentDmTaskId_ = 0; this.giteeTaskIds_ = [];
        if (this.cancelRequested_) return false;
        if (source.transport === 'concat-parts') this.concatParts(paths,zipPath);
        return true;
      } catch (e) {
        this.alog().warn(TAG,'目录下载来源失败：' + source.sourceId,e as Object,LOG_DOMAIN_LAUNCH);
        if (!await this.waitForNativeOwners_()) {
          this.report(false,'JDK 下载资源仍在结束，已保留下载现场，请稍后重试'); return false;
        }
        try { fs.unlinkSync(zipPath); } catch (ignored) { /* 尚未生成完整文件。 */ }
        try { fs.unlinkSync(zipPath + '.download-meta'); } catch (ignored) { /* 旧断点不可跨来源复用。 */ }
      } finally {
        this.giteeTaskIds_ = [];
        // 超时失败时原路径仍由 native 持有，外层会保留整个目录；不能边写边删除分卷/sidecar。
        const released = this.purgeNativeOwners();
        for (const path of paths) if (released && path !== zipPath) {
          try { fs.unlinkSync(path); } catch (ignored) { /* 失败/取消后尽力清理已结束分卷。 */ }
          try { fs.unlinkSync(path + '.download-meta'); } catch (ignored) { /* 分卷 sidecar 同步退役。 */ }
        }
      }
    }
    this.report(false,'❌ ' + label + ' 所选来源不可用，旧安装已保留');
    return false;
  }

  /**
   * 将 DownloadTaskView 转换为 JdkDownloadCallback 需要的 phase / percent / speedKBs / message
   *
   * ⚠️ 2026-07-29「进度条停住但速度在变」的说明：
   *   引擎的 overallProgress = Σ各段 done / 总大小（LoaderDownload::computeProgress）。
   *   某个段被 429/超时打断重试时会 resetDone() 归零，Σdone **真实回退**，
   *   于是进度条要么倒退、要么（被上层 Math.max 夹住后）冻在原地不动，
   *   而速度取的是各段瞬时速率之和，其它段仍在跑 → 速度照常跳。
   *   这不是 UI 卡死，是「有段在重下」。所以这里把**净重下的字节量**显式说出来，
   *   让用户看到"卡住"期间引擎到底在干什么，而不是干瞪一个不动的百分比。
   */
  private bridgeProgress(stepLabel: string, view: DownloadTaskView): void {
    if (view.finished) return;  // 终态交给 createAndWait 的 resolve/reject 处理

    // 探测期可见化（2026-07-29）：引擎在 NetFile::start 里要先确定文件大小
    //   （无 expected_size 时逐个源 HEAD + Range:0-0 探测，mirror 模式 6 个源串行）。
    //   这期间 file_size_ 未定 → native 报 bytesTotal=-1 → overallProgress 回退成
    //   filesDone/filesTotal = 0/1 = 0%。旧文案显示"下载 0%"，用户会以为卡死。
    //   这里据 bytesTotal<=0 识别该阶段，明确告知正在做什么。
    //   注：JDK 已配置精确 sizeBytes，命中 native 的 expected_size 快路径后基本不会
    //   进入此分支；保留是为了无 size 配置的下载（以及镜像探测兜底）仍有可见反馈。
    if (view.bytesTotal <= 0 && view.bytesDone <= 0) {
      this.reportDownload('downloading', 0, 0,
        stepLabel + ' 步骤 1/3：正在测试下载源可用性…');
      return;
    }

    const percent = Math.min(99, Math.max(0, Math.round(view.progress * 100)));
    const speedKBs = Math.max(0, Math.round(view.speedBps / 1024));
    const sizeStr = view.bytesTotal > 0
      ? fmtBytes(view.bytesDone) + '/' + fmtBytes(view.bytesTotal)
      : fmtBytes(view.bytesDone);
    const speedStr = fmtSpeed(view.speedBps);
    const etaStr = view.etaSeconds > 0 ? '剩 ' + view.etaSeconds + 's ' : '';

    // 检测"字节数退回去了"= 有分段在重下。用峰值与当前值的差额作为提示量。
    if (view.bytesDone > this.peakBytesDone_) this.peakBytesDone_ = view.bytesDone;
    const regressed = this.peakBytesDone_ - view.bytesDone;
    // 阈值 256KB：滤掉正常的统计抖动，只在真的有段回滚时提示。
    const retryHint = regressed > 256 * 1024
      ? ' · 有分段重下 ' + fmtBytes(regressed)
      : '';
    const threadHint = view.activeThreads > 0 ? ' · ' + view.activeThreads + ' 线程' : '';

    this.reportDownload('downloading', percent, speedKBs,
      stepLabel + ' 步骤 1/3：下载 ' + percent + '% ' + sizeStr + ' [' + speedStr + '] '
      + etaStr + threadHint + retryHint);
  }

  /** 期望的 zip 字节数（用于阶段提示文案）；未配置时回退到 dataSizeMB。 */
  private expectedZipBytes_(): number {
    const info = this.config_;
    if (info.sizeBytes !== undefined && info.sizeBytes > 0) return info.sizeBytes;
    return info.dataSizeMB * 1024 * 1024;
  }

  // ============================================================
  //  下载完成后：SHA-256 校验 → 解压 → 验证 lib/modules → 清理 zip
  // ============================================================

  private async completeJdkInstall(
    zipPath: string, targetDir: string, extractRoot: string, stepLabel: string
  ): Promise<boolean> {
    if (this.cancelRequested_) {
      this.reportDownload('verifying', 0, 0, stepLabel + ' 已取消');
      return false;
    }

    const integrityOk = await this.verifyArchiveIntegrity(zipPath, stepLabel);
    if (!integrityOk) return false;

    if (this.cancelRequested_) {
      this.reportDownload('extracting', 0, 0, stepLabel + ' 已取消');
      return false;
    }

    // 只解压到安装根下的唯一 staging。完整性与 boot artifact 验证通过后才发布到 targetDir。
    this.reportDownload('extracting', 0, 0,
      stepLabel + ' 步骤 3/3：解压安装（无进度可报，可能需要 2-5 分钟，请勿关闭）...');
    try { removeDirRecursive(extractRoot) } catch (e) {}
    ensureDirSync(extractRoot);

    // 解压是一个不可中断、不报进度的原子调用（zlib.decompressFile），期间 UI 会完全静止
    // 数分钟。挂一个心跳 ticker 汇报已用时 + 目标目录已落地的条目数，让用户看得出它在动。
    let extractTick = 0;
    const extractStartMs = Date.now();
    const heartbeat = setInterval(() => {
      extractTick++;
      let landed = 0;
      try { landed = fs.listFileSync(extractRoot).length } catch (e) { landed = 0 }
      const secs = Math.round((Date.now() - extractStartMs) / 1000);
      // 解压占总轴 95~100，这里在 0~99 内缓慢爬（对数式），只为"看起来在动"，不谎报完成。
      const pseudo = Math.min(99, extractTick * 3);
      this.reportDownload('extracting', pseudo, 0,
        stepLabel + ' 步骤 3/3：解压安装中… 已用 ' + secs + 's'
        + (landed > 0 ? '（已展开 ' + landed + ' 个顶层条目）' : '') + '，请勿关闭');
    }, 2000);

    try {
      // 共享安全解压：超时仅记账，等待底层回调后才 settle，并执行 containment/数量/大小/文件类型扫描。
      await decompressFile(zipPath, extractRoot, 300000);
    } catch (error) {
      const err = error as Error;
      this.alog().error(TAG, 'Extract failed', error as Object, LOG_DOMAIN_LAUNCH);
      this.report(false, '❌ ' + stepLabel + ' 解压失败: ' + err.message);
      try { removeDirRecursive(extractRoot) } catch (e) {}
      return false;
    } finally {
      clearInterval(heartbeat);
    }

    if (this.cancelRequested_) {
      this.alog().info(TAG, `JDK ${this.version_} extract finished but cancel requested; cleaning staging`, LOG_DOMAIN_LAUNCH);
      this.reportDownload('extracting', 100, 0, stepLabel + ' 已取消，清理中...');
      try { removeDirRecursive(extractRoot) } catch (e) {}
      return false;
    }

    // 摘要证明是预期 ZIP；这里再证明实际解压结果满足槽位、文件头与架构契约。
    // 必须在 rename 前验证，失败保留旧安装，不以 modules 的体积代替 native 有效性。
    const contentError = validateRuntimeTree(extractRoot, this.version_);
    if (contentError.length > 0) {
      this.alog().error(TAG, 'JDK staging content invalid: ' + contentError, null, LOG_DOMAIN_LAUNCH);
      this.report(false, '❌ ' + stepLabel + ' 内容校验失败：' + contentError);
      try { removeDirRecursive(extractRoot) } catch (e) { /* 失败现场由安装日志记录；旧目标不动。 */ }
      return false;
    }

    // 受管 receipt 与实际字节身份一起写 staging；写失败必须终止，不能发布无来源安装。
    if (this.config_.runtime !== undefined && this.config_.build !== undefined) {
      if (!RuntimeCatalogRepository.instance(this.context_).isBuildAllowed(this.config_.build.id)) {
        this.report(false,'该 JDK 构建已撤回或被回退指令停止发布，旧安装已保留'); return false;
      }
      const receipt: RuntimeInstallReceipt = { schemaVersion:1,runtimeId:this.config_.runtime.id,
        javaMajor:Number(this.version_),buildId:this.config_.build.id,
        recommendationRevision:this.config_.runtime.recommendationRevision,
        archiveSha256:this.config_.sha256!,archiveSizeBytes:this.config_.sizeBytes!,
        installedAt:new Date().toISOString(),origin:'catalog',runtime:this.config_.runtime,build:this.config_.build };
      const file = fs.openSync(extractRoot + '/.amcl-runtime-receipt.json',fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd,JSON.stringify(receipt)); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    }
    // release-tag 戳也先写 staging，随目录一起发布，兼容旧状态读取和旧客户端。
    try {
      let stampPath = extractRoot + '/.amcl_release_tag';
      let sf = fs.openSync(stampPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(sf.fd, this.config_.tag) } finally { fs.closeSync(sf) }
    } catch (e) {
      this.alog().warn(TAG, `JDK ${this.version_} stamp write failed (non-fatal)`, e as Object, LOG_DOMAIN_LAUNCH);
    }

    // 同文件系统备份 + rename；staging 与收据一次提交，失败恢复可用的旧安装。
    const backupDir = targetDir + '.backup-' + Date.now() + '-' +
      Math.floor(Math.random() * 1000000);
    let targetExisted = false;
    let backupCreated = false;
    let useLease: JdkDirectoryLease | null = null;
    try {
      useLease = JdkDirectoryLease.publication(this.context_.filesDir, this.version_);
      try {
        fs.statSync(targetDir);
        targetExisted = true;
      } catch (e) { /* first install */ }
      if (targetExisted) {
        fs.renameSync(targetDir, backupDir);
        backupCreated = true;
      }
      fs.renameSync(extractRoot, targetDir);
    } catch (e) {
      this.alog().error(TAG, 'JDK staging publish failed', e as Object, LOG_DOMAIN_LAUNCH);
      if (backupCreated) {
        try {
          fs.renameSync(backupDir, targetDir);
          backupCreated = false;
        } catch (restoreError) {
          this.alog().error(TAG, 'JDK publish rollback failed; backup retained at ' + backupDir,
            restoreError as Object, LOG_DOMAIN_LAUNCH);
        }
      }
      this.report(false, '❌ ' + stepLabel + ' 安装发布失败：' + (e as Error).message);
      try { removeDirRecursive(extractRoot) } catch (e2) {}
      return false;
    } finally {
      if (useLease !== null) useLease.release();
    }
    if (backupCreated) {
      try { removeDirRecursive(backupDir) } catch (e) {
        this.alog().warn(TAG, 'JDK old-version backup cleanup failed: ' + backupDir,
          e as Object, LOG_DOMAIN_LAUNCH);
      }
    }

    try { fs.unlinkSync(zipPath) } catch (e) {}
    this.alog().info(TAG, `JDK ${this.version_} published to ${targetDir}`, LOG_DOMAIN_LAUNCH);
    this.reportDownload('extracting', 100, 0, stepLabel + ' 完成 ✅');
    return true;
  }

  // ============================================================
  //  完整性校验（SHA-256）
  // ============================================================

  private async verifyArchiveIntegrity(zipPath: string, stepLabel: string): Promise<boolean> {
    const info = this.config_;
    const expected = info.sha256;

    if (!expected || expected.length === 0) {
      this.alog().warn(TAG,
        `JDK ${this.version_} 缺少可信 SHA-256，拒绝安装并保留旧版本`,
        null, LOG_DOMAIN_LAUNCH);
      return false;
    }
    if (!isValidSha256(expected)) {
      this.alog().error(TAG, 'Invalid configured JDK SHA-256', null, LOG_DOMAIN_LAUNCH);
      return false;
    }

    // 阶段名写清楚：这一步要把整个 zip（~120MB）读一遍算摘要，耗时可达数秒，
    // 期间没有网络活动。不说明的话用户会以为"下载卡住了"。
    this.reportDownload('verifying', 0, 0,
      stepLabel + ' 步骤 2/3：校验文件完整性（SHA-256，约 ' + fmtBytes(this.expectedZipBytes_()) + '）...');
    this.alog().debug(TAG, `Computing SHA-256 for ${zipPath} (expected=${expected})`, LOG_DOMAIN_LAUNCH);

    try {
      let actual = await this.computeFileSha256(zipPath);
      let expectedLower = expected.toLowerCase();
      if (actual !== expectedLower) {
        this.alog().error(TAG,
          `❌ SHA-256 mismatch for JDK ${this.version_}: expected=${expectedLower} actual=${actual}`,
          null, LOG_DOMAIN_LAUNCH);
        this.report(false,
          '❌ ' + stepLabel + ' 校验和不匹配，可能镜像被劫持');
        return false;
      }
      this.alog().info(TAG, `✅ SHA-256 verified for JDK ${this.version_}`, LOG_DOMAIN_LAUNCH);
      return true;
    } catch (e) {
      this.alog().error(TAG, 'Failed to compute SHA-256', e as Object, LOG_DOMAIN_LAUNCH);
      this.report(false, '❌ ' + stepLabel + ' SHA-256 计算失败');
      return false;
    }
  }

  // ArkTS 严格模式：cryptoFramework.createMd / fs.openSync / readSync / md.updateSync /
  // closeSync / digestSync 全报 'Function may throw'。整个函数包 try-catch + finally 关 fd。
  private async computeFileSha256(path: string): Promise<string> {
    const CHUNK_SIZE = 256 * 1024;  // 256 KB 分块，避免大文件 OOM
    let file: fs.File | null = null;
    try {
      let md = cryptoFramework.createMd('SHA256');
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let buffer = new ArrayBuffer(CHUNK_SIZE);
      while (true) {
        let n = fs.readSync(file.fd, buffer);
        if (n <= 0) break;
        let chunk: cryptoFramework.DataBlob = { data: new Uint8Array(buffer, 0, n) };
        md.updateSync(chunk);
      }
      let digest = md.digestSync();
      let hex = '';
      for (let i = 0; i < digest.data.length; i++) {
        let b = digest.data[i];
        hex += (b < 16 ? '0' : '') + b.toString(16);
      }
      return hex;
    } catch (e) {
      this.alog().warn(TAG, `computeFileSha256 ${path} failed`, e as Object, LOG_DOMAIN_LAUNCH);
      throw e as Error;
    } finally {
      if (file) {
        try { fs.closeSync(file) } catch (_) { /* ignore */ }
      }
    }
  }
}

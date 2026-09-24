/**
 * ForgeRepairTask.ets — Forge 版本【数据安全】修复（v3 · 复用完整合并流水线）
 *
 * 背景与设计（2026-06-07 真机定位后重写）：
 *   AMCL 采用 PCL2 式「安装时合并」——把 vanilla + forge 的 version.json 合并成一份
 *   **自包含**清单（无 inheritsFrom，~97 个库）。一旦这份清单被「裸跑 ForgeService.install」
 *   覆盖成未合并的 forge 清单（带 inheritsFrom，仅 ~40 个 forge 库），vanilla 那半边（log4j /
 *   jopt 等）就丢了，启动时 ModLauncher 报 "Module ... not found" 闪退。
 *
 *   正确修复 = 把【合并】这一步重新做一遍。关键洞察：未合并的 forge 清单里带 `inheritsFrom`，
 *   它直接告诉我们【真实 MC 版本】（如 26.1.1），无需从文件夹名猜测（文件夹名 26.1 ≠ 真实 26.1.1）。
 *
 * 流程：
 *   1. 快照保护用户数据（saves/mods/config/...，再入安全，绝不丢）。
 *   2. 若 forge 生成产物（forge-client.jar）缺失/损坏 → 跑 ForgeService.install 重建它
 *      （它会写出 inheritsFrom 形态的 forge 清单）；否则跳过（省去重装）。
 *   3. 读当前 version.json：若带 inheritsFrom（未合并）→ 取真实 MC 版本，拉 vanilla json+jar，
 *      用 VersionJsonMerger.merge 合成自包含清单（恢复 vanilla 那半边的库）。
 *   4. 增量补全合并清单里缺失的库 + assets。
 *   5. 还原用户数据（try/finally 兜底，绝不丢）。
 *
 * 全程只动共享 libraries/ + 版本目录里的 <id>.json/<id>.jar；用户数据被快照保护。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import {
  UnifiedDownloadAdapter, UnifiedTaskView, UnifiedTaskState, TaskCategory,
} from '../download/UnifiedDownloadTask';
import { DownloadTaskRegistry } from '../download/DownloadTaskRegistry';
import { ModLoaderType } from '../modloader/ModLoaderTypes';
import { isNewForgeVersion } from '../modloader/ForgeInstallerUtils';
import { DownloadTask } from '../download/DownloadTask';
import { McDownloader, VersionJson, DownloadProgress, FetchVersionInfoResult } from '../download/McDownloader';
import { VersionJsonMerger } from './VersionJsonMerger';
import { VersionFileVerifier } from './VersionFileVerifier';
import { removeDirRecursive, writeTextFile, removeVersionInstallCommit } from 'commons';
import { formatError } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';

const TAG = 'ForgeRepairTask';

/**
 * 安装器自管、无需快照保护的版本目录子项（其余一律当用户数据保留）。
 *
 * `.amcl-install-complete` 是 `writeVersionInstallCommit` 写的安装提交标记，属安装器元数据
 * 而非用户数据。放进本表后不再被当成"存档"搬来搬回——否则重装成功后会用旧标记覆盖
 * DownloadTask 刚写的新标记。
 */
const INSTALL_OWNED: string[] = ['natives', 'data', 'downloads', 'logs', '.amcl-install-complete'];

export class ForgeRepairTask implements UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView = new UnifiedTaskView();
  private versionName_: string;
  private gameVersion_: string;
  private loaderVersion_: string;
  private mcDir_: string;
  private filesDir_: string;
  private ownedDownloaders_: McDownloader[] = [];
  /** 重装流水线（生成产物缺失时才创建）；purgeNativeOwner 需要连它一起释放 native 路径所有权。 */
  private reinstallTask_: DownloadTask | null = null;

  constructor(versionName: string, gameVersion: string, loaderVersion: string, mcDir: string, filesDir: string) {
    this.versionName_ = versionName;
    this.gameVersion_ = gameVersion;
    this.loaderVersion_ = loaderVersion;
    this.mcDir_ = mcDir;
    this.filesDir_ = filesDir;
    this.view.id = 'repair:' + versionName;
    this.view.category = TaskCategory.MC_VERSION;
    this.view.title = versionName;
    this.view.subtitle = '修复 Forge（保留存档/模组）';
    this.view.state = UnifiedTaskState.PREPARING;
    this.view.canViewDetail = false;
    this.view.canCancel = false;   // 修复是原子操作，不支持中途取消
    this.view.canPause = false;
  }

  async start(): Promise<void> {
    let versionDir = this.mcDir_ + '/versions/' + this.versionName_;
    let preserveDir = this.mcDir_ + '/versions/.amcl-repair-' + this.versionName_;
    let tmpDir = this.mcDir_ + '/.amcl-repair-tmp/' + this.versionName_;
    let jsonPath = versionDir + '/' + this.versionName_ + '.json';

    let preserved: string[] = [];
    // 清单/主 jar 的回滚清单：重装期间被移进快照区，成功即清空、失败则在 finally 里移回。
    // 与 `preserved`（用户数据）分开管理 —— 用户数据无论成败都要还原，安装产物只在失败时还原。
    let installArtifacts: string[] = [];
    let failMsg = '';
    // 运行中不该显示可点的重试按钮；canCancel 保持 false（修复是原子操作，见构造函数）。
    this.view.errorMessage = '';
    this.view.canRetry = false;
    try {
      // ---- 1) 快照保护用户数据（再入安全：先恢复上一轮可能滞留的数据，绝不清空）----
      this.view.state = UnifiedTaskState.PREPARING;
      this.view.currentLabel = '保护存档 / 模组…';
      this.notify_();
      this.recoverStranded_(preserveDir, versionDir);
      try { fs.mkdirSync(preserveDir, true); } catch (e) { /* */ }
      try {
        let children = fs.listFileSync(versionDir);
        for (let c of children) {
          if (c === this.versionName_ + '.json' || c === this.versionName_ + '.jar') continue;   // 清单/主 jar 单独处理
          if (INSTALL_OWNED.indexOf(c) >= 0) continue;
          try { fs.renameSync(versionDir + '/' + c, preserveDir + '/' + c); preserved.push(c); }
          catch (e) { AppLogger.warn(TAG, `preserve ${c} failed`, e, LOG_DOMAIN_MODLOADER); }
        }
      } catch (e) { /* 版本目录可能不存在 */ }
      AppLogger.info(TAG, `preserved ${preserved.length} user-data items for ${this.versionName_}`, LOG_DOMAIN_MODLOADER);

      // ---- 2) 生成产物损坏/缺失 → 走「与全新安装完全相同的流水线」重装一次 ----
      //
      // 旧版 Forge（≤1.12）没有 binarypatcher、不产出 -client.jar，forgeClientArtifactBroken
      // 对它恒为 true，故先按纪元过滤；旧版的清单问题由下面第 3 步的重做合并覆盖。
      //
      // ⚠️ 2026-08-08 方向更正（对齐 PCL2）：这里原来是**原地**调
      //   `ModLoaderManager.install(FORGE, …, this.mcDir_)`，即把真实 .minecraft 直接交给
      //   安装引擎。两个问题：
      //     ① `ForgelikeProcessorRunner` 把 `{MINECRAFT_JAR}` 拼成
      //        `mcDir/versions/<gameVersion>/<gameVersion>.jar`，而 AMCL 采用「安装时合并」，
      //        真实 .minecraft 里**从来不存在**这个原版版本目录（原版 json/jar 只落在
      //        `download-temp/`，产物是 `versions/<versionName>/<versionName>.jar`）。
      //        全新安装能跑通，是因为 ModloaderPhase 在沙箱里专门造了一份原版 json+jar
      //        （见 ModloaderPhase 的注释）；修复路径绕过了沙箱，于是 jarsplitter /
      //        binarypatcher 拿到不存在的输入必然失败。
      //     ② ForgelikeInstaller 的 Step 6b 会**先**把未合并的 forge 清单写进
      //        `versions/<id>/<id>.json` 再跑 processors。processors 一失败就抛出，第 3 步的
      //        重做合并被跳过 → 修复反而把清单从「自包含」退化成「带 inheritsFrom」，
      //        正是本任务存在的意义所反的方向。
      //
      //   PCL2 的做法（`Modules/Minecraft/ModCrash.vb:1071`，CrashReason.Forge安装不完整）：
      //     "由于安装的 Forge 文件丢失，导致游戏无法正常运行。请**重新安装一次相同版本的
      //      Forge**，然后再启动游戏。"
      //   它的「补全文件」(`ModDownload.vb` DlClientFix) 只做三件事——补支持库、补资源文件、
      //   补 client.jar，**从不重跑安装器去重建生成产物**；生成产物缺失一律引导重装。
      //   （PCL2 之所以没有 ①，是因为它保留 inheritsFrom 布局、原版是独立安装的前置版本，
      //     `ModMinecraft.vb:713-716` 缺前置会直接报「需要安装 X 作为前置版本」。AMCL 选择
      //     合并，代价就是原版 jar 必须由沙箱提供。）
      //
      //   故此处改为复用 `DownloadTask` —— 与用户手动下载该版本走的是**同一条**
      //   PreparePhase→Client→Libraries→Assets→ModloaderPhase(沙箱)→MergePhase 流水线，
      //   processors 拿到沙箱里的原版 jar，且只在全部成功后才发布到 versions/<name>/。
      //   语义等价于 PCL2 的「重新安装一次相同版本的 Forge」，但对用户是一键，
      //   且存档/模组由本任务的快照保护兜住。
      if (isNewForgeVersion(this.loaderVersion_)
          && VersionFileVerifier.forgeClientArtifactBroken(this.mcDir_, this.gameVersion_, this.loaderVersion_)) {
        this.view.state = UnifiedTaskState.DOWNLOADING;
        this.view.currentLabel = '重装 Forge（生成产物缺失）…';
        this.notify_();
        // 删掉损坏产物目录，避免安装器因「文件够大就算完整」而跳过重建
        let forgeGenDir = this.mcDir_ + '/libraries/net/minecraftforge/forge/'
          + this.gameVersion_ + '-' + this.loaderVersion_;
        try { removeDirRecursive(forgeGenDir); } catch (e) { /* */ }
        // 把清单/主 jar 移进快照区，两个作用：
        //   ① DownloadTask 的前置检查 `isVersionInstalled`（jar+json 都在即算已装）会抛
        //      「版本 X 已存在」——移走 jar/json 正好让它判为未安装，重装得以进行；
        //   ② DownloadTask 失败时会清掉 versions/<name>/，移走后可在 finally 里回滚，
        //      让「修复失败」不至于把整个版本从列表里弄没（见 restore 分支）。
        // 同时显式清掉安装提交标记，表达"本版本正在重装"的意图，不依赖 ① 的副作用。
        removeVersionInstallCommit(this.mcDir_, this.versionName_);
        for (let a of [this.versionName_ + '.json', this.versionName_ + '.jar']) {
          try {
            fs.renameSync(versionDir + '/' + a, preserveDir + '/' + a);
            installArtifacts.push(a);
          } catch (e) { /* 不存在则无需回滚 */ }
        }
        // ⚠️ O-02 修复（2026-07-29）保留：失败必须 throw 而非 return —— return 位于外层 try 内，
        //   finally 跑完会直接返回函数，把下面 `if (failMsg.length > 0)` 整段跳过，导致
        //   start() 正常 resolve（registry 报成功）、view 卡在非终态无法清理、
        //   view.id='repair:<name>' 被永久占用。
        try {
          await this.runFullReinstall_();
        } catch (e) {
          failMsg = 'Forge 重装失败：' + formatError(e);
          throw new Error(failMsg);
        }
        // 重装成功 → 清单/主 jar 已由 MergePhase 重新写出，快照里的旧副本作废
        for (let a of installArtifacts) { this.removePath_(preserveDir + '/' + a); }
        installArtifacts = [];
      }

      // ---- 3) 若 version.json 是未合并形态（带 inheritsFrom）→ 重做合并，恢复完整清单 ----
      let inheritsFrom = this.readInheritsFrom_(jsonPath);
      if (inheritsFrom.length > 0) {
        this.view.currentLabel = '合并版本清单（拉取原版 ' + inheritsFrom + '）…';
        this.notify_();
        await this.remerge_(jsonPath, inheritsFrom, versionDir, tmpDir);
      } else {
        AppLogger.info(TAG, 'version.json already self-contained (no inheritsFrom), skip remerge', LOG_DOMAIN_MODLOADER);
      }

      // ---- 4) 增量补全合并清单里缺失的库 + assets（非破坏性，引擎只下缺的）----
      this.view.currentLabel = '补全依赖库 / 资源…';
      this.notify_();
      try {
        let vj = JSON.parse(fs.readTextSync(jsonPath)) as VersionJson;
        let dl = new McDownloader(this.mcDir_);
        this.ownedDownloaders_.push(dl);
        dl.setProgressCallback((pp: DownloadProgress) => this.onDlProgress_(pp, 70, 100));
        await dl.downloadLibraries(vj, true /* onlyMissing */);
        if (vj.assetIndex && vj.assetIndex.id && vj.assetIndex.id.length > 0) {
          await dl.downloadAssets(vj);
        }
      } catch (e) {
        AppLogger.warn(TAG, 'post-merge lib/asset completion failed', e, LOG_DOMAIN_MODLOADER);
      }
    } catch (e) {
      // O-02：try 内已设定的具体 failMsg 优先，避免被泛化前缀覆盖成
      // "修复失败：Forge 安装器重建失败：…" 这类重复措辞。
      if (failMsg.length === 0) failMsg = '修复失败：' + formatError(e);
    } finally {
      // ---- 5) 还原用户数据（无论成败都执行，绝不丢）----
      //   installArtifacts 非空 = 重装未成功收尾，把清单/主 jar 移回去，避免
      //   DownloadTask 失败时清掉 versions/<name>/ 让整个版本从列表里消失。
      //   两者共用 restoreUserData_ 的"逐项 rename 回去 + 删快照目录"逻辑。
      this.restoreUserData_(preserveDir, versionDir, preserved.concat(installArtifacts));
      try { removeDirRecursive(tmpDir); } catch (e) { /* */ }
    }

    if (failMsg.length > 0) { this.fail_(failMsg + '\n（存档 / 模组已原样保留）'); return; }
    this.view.state = UnifiedTaskState.DONE;
    this.view.progress = 100;
    this.view.currentLabel = '修复完成（存档 / 模组已保留）';
    this.notify_();
  }

  cancel(_c: boolean): Promise<void> { return Promise.resolve(); }
  pause(): Promise<void> { return Promise.resolve(); }
  resume(): Promise<void> { return Promise.resolve(); }
  retry(): Promise<void> {
    if (!this.purgeNativeOwner()) {
      return Promise.reject(new Error('旧 Forge 修复下载任务仍在收敛，请稍后重试'));
    }
    return this.start();
  }
  purgeNativeOwner(): boolean {
    let retained: McDownloader[] = [];
    for (let downloader of this.ownedDownloaders_) {
      if (!downloader.purgeNativeOwners()) retained.push(downloader);
    }
    this.ownedDownloaders_ = retained;
    // 重装流水线自己持有一个 McDownloader + engine task，也必须释放，否则
    // 下次 retry 会撞 native 的 `final path is already owned by task N`。
    let taskPurged = true;
    if (this.reinstallTask_ !== null) {
      taskPurged = this.reinstallTask_.purgeNativeOwners();
      if (taskPurged) this.reinstallTask_ = null;
    }
    return retained.length === 0 && taskPurged;
  }
  dispose(): void {
    this.ownedDownloaders_ = [];
    if (this.reinstallTask_ !== null) { this.reinstallTask_.onStateChange = null; }
  }

  // ============================================================
  //  合并：用 inheritsFrom 指向的真实 MC 版本，拉 vanilla json+jar，与 forge 清单合并
  // ============================================================
  private async remerge_(forgeJsonPath: string, realMcVersion: string, versionDir: string, tmpDir: string): Promise<void> {
    try { fs.mkdirSync(tmpDir, true); } catch (e) { /* */ }
    // 把当前（未合并的 forge）清单复制到临时路径作为 loaderJson（合并输出会覆盖原 <id>.json）
    let loaderJsonTmp = tmpDir + '/loader.json';
    writeTextFile(loaderJsonTmp, fs.readTextSync(forgeJsonPath));

    // 拉 vanilla version.json + client jar
    let dl = new McDownloader(this.mcDir_);
    this.ownedDownloaders_.push(dl);
    dl.setProgressCallback((pp: DownloadProgress) => this.onDlProgress_(pp, 55, 70));
    let info: FetchVersionInfoResult = await dl.fetchVersionInfo(realMcVersion);
    let vanillaJsonTmp = tmpDir + '/' + realMcVersion + '.json';
    writeTextFile(vanillaJsonTmp, info.rawJson);
    await dl.downloadClientJar(info.versionJson, tmpDir);   // → tmpDir/<realMcVersion>.jar
    let vanillaJar = tmpDir + '/' + realMcVersion + '.jar';

    // 合并 → 写出自包含的 versions/<id>/<id>.json + 复制 vanilla jar 为 <id>.jar
    VersionJsonMerger.merge(vanillaJsonTmp, loaderJsonTmp, this.versionName_, versionDir, vanillaJar);
    AppLogger.info(TAG, `remerge done for ${this.versionName_} (mc=${realMcVersion})`, LOG_DOMAIN_MODLOADER);  }

  /**
   * 跑一次完整重装：与用户手动下载该版本**同一条** DownloadTask 流水线
   * （Prepare→Client→Libraries→Assets→ModloaderPhase「沙箱」→Merge）。
   *
   * 用沙箱是关键：processors 的 `{MINECRAFT_JAR}` 需要 `versions/<gameVersion>/<gameVersion>.jar`，
   * 只有 ModloaderPhase 会造出来（详见调用处注释）。进度映射到 0~65%，
   * 后面第 3/4 步（重做合并 / 补库与资源）继续往后推。
   */
  private async runFullReinstall_(): Promise<void> {
    let task = new DownloadTask(
      this.gameVersion_, ModLoaderType.FORGE, this.loaderVersion_,
      this.versionName_, this.mcDir_, this.filesDir_);
    this.reinstallTask_ = task;
    task.onStateChange = (t: DownloadTask): void => {
      this.view.progress = Math.max(0, Math.min(65, t.progress * 0.65));
      this.view.currentLabel = '重装 Forge · ' + (t.phase || '');
      this.view.bytesDone = t.bytesDone;
      this.view.bytesTotal = t.bytesTotal;
      this.view.etaSeconds = t.etaSeconds;
      this.notify_();
    };
    try {
      await task.start();
    } finally {
      task.onStateChange = null;
    }
  }

  /** 读 version.json 的 inheritsFrom（无则返回 ''）。 */
  private readInheritsFrom_(jsonPath: string): string {
    try {
      let obj = JSON.parse(fs.readTextSync(jsonPath)) as Record<string, Object>;
      let inh = obj['inheritsFrom'];
      return (typeof inh === 'string') ? inh as string : '';
    } catch (e) { return ''; }
  }

  // ============================================================
  //  数据保护
  // ============================================================
  private recoverStranded_(preserveDir: string, versionDir: string): void {
    let children: string[] = [];
    try { children = fs.listFileSync(preserveDir); } catch (e) { return; }
    if (children.length === 0) { try { removeDirRecursive(preserveDir); } catch (e) { /* */ } return; }
    try { fs.mkdirSync(versionDir, true); } catch (e) { /* */ }
    let recovered = 0;
    for (let c of children) {
      this.removePath_(versionDir + '/' + c);
      try { fs.renameSync(preserveDir + '/' + c, versionDir + '/' + c); recovered++; }
      catch (e) { AppLogger.error(TAG, `recoverStranded ${c} failed`, e, LOG_DOMAIN_MODLOADER); }
    }
    try { removeDirRecursive(preserveDir); } catch (e) { /* */ }
    AppLogger.warn(TAG, `recovered ${recovered} stranded items from interrupted repair`, null, LOG_DOMAIN_MODLOADER);
  }

  private restoreUserData_(preserveDir: string, versionDir: string, preserved: string[]): void {
    try { fs.mkdirSync(versionDir, true); } catch (e) { /* */ }
    for (let c of preserved) {
      this.removePath_(versionDir + '/' + c);
      try { fs.renameSync(preserveDir + '/' + c, versionDir + '/' + c); }
      catch (e) { AppLogger.error(TAG, `restore ${c} failed`, e, LOG_DOMAIN_MODLOADER); }
    }
    try { removeDirRecursive(preserveDir); } catch (e) { /* */ }
  }

  private removePath_(path: string): void {
    try {
      let st = fs.statSync(path);
      if (st.isDirectory()) removeDirRecursive(path); else fs.unlinkSync(path);
    } catch (e) { /* 不存在 */ }
  }

  // ============================================================
  //  进度映射
  // ============================================================
  private onDlProgress_(p: DownloadProgress, lo: number, hi: number): void {
    let frac = p.total > 0 ? Math.min(1, p.current / p.total) : 0;
    this.view.progress = Math.max(lo, Math.min(hi, lo + frac * (hi - lo)));
    this.view.currentLabel = p.fileName && p.fileName.length > 0 ? p.stage + ' · ' + p.fileName : p.stage;
    this.view.speedBps = p.speedBps !== undefined ? p.speedBps : 0;
    this.notify_();
  }

  private fail_(msg: string): void {
    this.view.state = UnifiedTaskState.ERROR;
    this.view.errorMessage = msg;
    this.view.canRetry = true;
    AppLogger.error(TAG, `forge repair ${this.versionName_} failed: ${msg}`, null, LOG_DOMAIN_MODLOADER);
    this.notify_();
  }

  private notify_(): void {
    try { DownloadTaskRegistry.instance().notifyChange(); } catch (e) { /* */ }
  }
}

/**
 * ModloaderPhase.ets — Phase 6.3 第 5 阶段（可选）：安装 Forge / Fabric
 *
 * 仅当 state.loaderType !== null 时被加入 PhaseRunner 序列。
 *
 * 统一沙箱（Forge 2026-05-05 落地，Fabric 2026-08-08 补齐）：
 *   1. 创建独立沙箱 filesDir/forge-install-sandbox/<sid>，内建 versions/<gv>/ + libraries/
 *   2. **仅 Forge/NeoForge** 复制 vanilla json/jar 进沙箱 —— 其 processors 的 {MINECRAFT_JAR}
 *      被拼成 mcDir/versions/<gv>/<gv>.jar，而 AMCL "安装时合并"后真实 .minecraft 里没有这个
 *      原版版本目录。Fabric 是纯 API（不跑 installer、不碰原版 jar），跳过这次 ~15MB 拷贝
 *   3. 调 ModLoaderManager.install，把加载器装进沙箱
 *   4. 把 sandbox 目录写到 state.installSandboxDir，MergePhase 据此迁 sandbox/libraries 回真实
 *      mcDir；DownloadTask 的 finally 无条件删沙箱
 *
 * 为什么 Fabric 也要沙箱：FabricService 写的是 mcDir/versions/<Fabric 规范名>，而规范名
 *   `fabric-loader-<loader>-<gv>` 未必等于用户自定义的 versionName。装在真实 mcDir 时，改名
 *   安装会残留一个只有 json、无 jar、无 commit marker 的 `fabric-loader-.../` 目录且无人清理，
 *   还会被 ModLoaderManager.detectModLoader 认成"已安装的 Fabric 版本"。PCL2 同样把所有加载器
 *   （含 Fabric）装进临时假 .minecraft（ModDownloadLib.vb:1934-1944），合并后整体丢弃。
 *
 * 进度桥接：ModLoaderManager.install 传入的 progress callback 内部
 *   是 { current, total, message } 字段；这里直接转成 PhaseProgress。
 *
 * 取消：ModLoaderManager 当前没有 cancel 接口，phase.cancel 只翻 cancelled 标志。
 *       Forge installer 在子进程里跑，cancel 时只能等其退出（5-30s）。
 *
 * 创建日期：2026-05-06
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import {
  IDownloadPhase, PhaseContext, PhaseProgress,
} from '../PhaseRunner';
import { DownloadFlowState } from './DownloadFlowState';
import { AppLogger, CancelledError } from 'commons';
import { writeTextFile, fileExistsAndNonEmpty } from 'commons';
import { ModLoaderManager } from '../../modloader/ModLoaderManager';
import { ModLoaderType, ModLoaderInstallProgress } from '../../modloader/ModLoaderTypes';
import { safePathSegment } from '../../modloader/MavenUtils';

const TAG = 'ModloaderPhase';

export class ModloaderPhase implements IDownloadPhase {
  readonly name: string = 'modloader';
  readonly weight: number;
  private state_: DownloadFlowState;
  private manager_: ModLoaderManager;

  constructor(state: DownloadFlowState, manager: ModLoaderManager, weight: number = 10) {
    this.state_ = state;
    this.manager_ = manager;
    this.weight = weight;
  }

  async run(_ctx: PhaseContext, onProgress: (p: PhaseProgress) => void): Promise<void> {
    if (this.state_.cancelled) throw new CancelledError();
    if (this.state_.loaderType === null) {
      throw new Error('ModloaderPhase 不应在 vanilla 路径中被跑（请在 PhaseRunner 序列中条件加入）');
    }
    let info = this.state_.versionInfo;
    if (info === null) throw new Error('ModloaderPhase: state.versionInfo 为空');
    let safeGameVersion = safePathSegment(this.state_.gameVersion);
    if (safeGameVersion.length === 0) throw new Error('ModloaderPhase: gameVersion 路径段不安全');

    let phaseName = this.name;
    let loaderLabel = this.state_.loaderType === ModLoaderType.FABRIC ? 'Fabric'
      : (this.state_.loaderType === ModLoaderType.NEOFORGE ? 'NeoForge' : 'Forge');
    onProgress({
      phase: phaseName,
      progress: 0,
      speedBps: 0,
      message: loaderLabel + ' 安装',
    });

    // ============================================================
    //  安装沙箱（**所有**加载器统一走，2026-08-08 起含 Fabric）
    //
    //  在内部存储 filesDir 下建独立沙箱，加载器装到沙箱，再由 MergePhase 把 sandbox/libraries
    //  迁回真实 mcDir；DownloadTask 的 finally 无条件删沙箱。沙箱在内部存储还顺带规避了
    //  外部存储(sdcardfs)的 zipfs/chmod 问题。
    //
    //  ⚠️ 2026-08-08：Fabric 原本是**例外**，直接装真实 mcDir。但 `FabricService` 写的是
    //    `mcDir + '/versions/' + versionId`，而这个 versionId 是 Fabric **规范名**
    //    `fabric-loader-<loader>-<gv>`，**不是**用户自定义的 versionName。于是给 Fabric 版本
    //    改名安装时，真实 versions/ 下会多留一个 `fabric-loader-.../`（只有 json、无 jar、
    //    无 commit marker）且无人清理，而 ModLoaderManager.detectModLoader 又能把它认成
    //    "已安装的 Fabric 版本" → 版本列表里冒出一个永远不完整的条目。
    //
    //    PCL2 没有这个问题，因为它**一律**把加载器装进临时假 .minecraft：
    //    `ModDownloadLib.vb:1934-1944` 里 OptiFine / Forge / NeoForge / Fabric / LiteLoader
    //    的目标目录全都是 `TempMcFolder & "versions\..."`，MergeJson 之后临时区整体丢弃，
    //    `McFolderSelected` 下永远只多出一个目录。AMCL 少统一了 Fabric 这一支，现补上。
    // ============================================================
    let sandboxSid = Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
    let installSandboxDir = this.state_.filesDir + '/forge-install-sandbox/' + sandboxSid;
    ModloaderPhase.ensureDir(installSandboxDir);
    // 立即登记，确保后续 copy/校验失败抛出时 DownloadTask 的 finally 仍能清理沙箱目录，
    // 否则每次失败重试都会残留一个 forge-install-sandbox/<sid> 目录。
    this.state_.installSandboxDir = installSandboxDir;
    let sandboxVersionsDir = installSandboxDir + '/versions/' + safeGameVersion;
    ModloaderPhase.ensureDir(sandboxVersionsDir);
    ModloaderPhase.ensureDir(installSandboxDir + '/libraries');
    let installBaseMcDir: string = installSandboxDir;

    // Forge/NeoForge 要在设备上跑 processors，而 install_profile 的 `{MINECRAFT_JAR}` 被
    // ForgelikeProcessorRunner 拼成 `<mcDir>/versions/<gv>/<gv>.jar`（见该文件 token 构建处）。
    // AMCL 采用"安装时合并"，真实 .minecraft 里从不存在这个原版版本目录，故必须在沙箱里
    // 人为造一份原版 json+jar —— 与 PCL2 `ModDownloadLib.vb:1261-1272` 在临时假 .minecraft 里
    // 复制 vanilla json/jar 并改名 `<Inherit>` 是同一手法。
    //
    // Fabric 是纯 API（只读远端元数据、只写自己的 version.json，不跑 installer、不碰原版 jar），
    // 故只给它建上面的 versions/ + libraries/ 骨架，**跳过**这次 ~15MB 的原版 jar 拷贝。
    if (this.state_.loaderType === ModLoaderType.FORGE
        || this.state_.loaderType === ModLoaderType.NEOFORGE) {
      // 复制 vanilla JSON + jar
      let sandboxJsonPath = sandboxVersionsDir + '/' + safeGameVersion + '.json';
      let sandboxJarPath = sandboxVersionsDir + '/' + safeGameVersion + '.jar';
      let tempJarPath = this.state_.tempVersionDir + '/' + safeGameVersion + '.jar';

      AppLogger.info(TAG, loaderLabel + ' sandbox install: dir=' + installSandboxDir);
      // 2026-05-23 ArkTS 严格模式：fs.copyFileSync 会报 'Function may throw'。
      // 包 try-catch + hilog + rethrow 保留原"沙箱准备失败让上层中止"的行为，
      // 仅多一行可观测性日志。详见 docs/guides/api-migration-2026-05.md。
      try {
        fs.copyFileSync(this.state_.tempJsonPath, sandboxJsonPath);
        fs.copyFileSync(tempJarPath, sandboxJarPath);
      } catch (e) {
        AppLogger.error(TAG, 'Forge sandbox copy failed: ' + (e as Error).message);
        throw e as Error;
      }

      // 校验沙箱 jar
      let jarSize = 0;
      try { jarSize = fs.statSync(sandboxJarPath).size; } catch (e) { /* */ }
      if (jarSize < 1024 * 1024) {
        throw new Error('原版 jar 复制到沙箱失败或文件过小: ' + jarSize + ' bytes');
      }
    } else {
      AppLogger.info(TAG, loaderLabel + ' sandbox install (no vanilla jar needed): dir=' + installSandboxDir);
    }

    if (this.state_.cancelled) throw new CancelledError();

    // launcher_profiles.json 双保险
    let profilesPath = installBaseMcDir + '/launcher_profiles.json';
    let exists = false;
    try { fs.statSync(profilesPath); exists = true; } catch (e) { /* */ }
    if (!exists) {
      writeTextFile(profilesPath,
        '{"profiles":{"default":{"name":"default","type":"custom"}},"selectedProfile":"default"}');
    }

    // 调 ModLoaderManager.install
    let result = await this.manager_.install(
      this.state_.loaderType,
      safeGameVersion,
      this.state_.loaderVersion,
      installBaseMcDir,
      (progress: ModLoaderInstallProgress): void => {
        let prog = (progress.total > 0) ? (progress.current / progress.total) : 0;
        if (prog > 1) prog = 1;
        if (prog < 0) prog = 0;
        onProgress({
          phase: phaseName,
          progress: prog,
          speedBps: 0,
          message: progress.message,
          current: progress.current,
          total: progress.total,
        });
      },
      this.state_.filesDir,
    );

    if (!result.success) {
      throw new Error('模组加载器安装失败: ' + (result.error || '未知错误'));
    }
    if (this.state_.cancelled) throw new CancelledError();

    // 找 loader 生成的 version.json；versionId 可能来自远端元数据，必须先拒绝路径语义。
    let safeVersionId = safePathSegment(result.versionId);
    if (safeVersionId.length === 0) throw new Error('模组加载器返回了不安全的 versionId');
    let loaderJsonPath = this.findLoaderJson(safeVersionId, installBaseMcDir);
    if (loaderJsonPath === null) {
      throw new Error('未找到模组加载器 version.json: ' + safeVersionId);
    }
    this.state_.loaderJsonPath = loaderJsonPath;

    let label = this.state_.loaderType === ModLoaderType.FABRIC ? 'Fabric 安装完成' : 'Forge 安装完成';
    onProgress({
      phase: phaseName,
      progress: 1.0,
      speedBps: 0,
      message: label,
    });
    AppLogger.info(TAG, 'ModloaderPhase done: versionId=' + safeVersionId + ' json=' + loaderJsonPath);
  }

  /** 在 baseMcDir/versions/ 下查找 loader 生成的 version.json */
  private findLoaderJson(versionId: string, baseMcDir: string): string | null {
    let path1 = baseMcDir + '/versions/' + versionId + '/' + versionId + '.json';
    if (fileExistsAndNonEmpty(path1)) return path1;

    // 扫描兄弟目录
    let versionsDir = baseMcDir + '/versions';
    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        if (safePathSegment(name).length === 0) continue;
        if (name === this.state_.gameVersion) continue;
        if (name === this.state_.versionName) continue;
        if (name.indexOf('forge') >= 0 || name.indexOf('fabric') >= 0) {
          let jsonPath = versionsDir + '/' + name + '/' + name + '.json';
          if (fileExistsAndNonEmpty(jsonPath)) {
            AppLogger.info(TAG, 'Found loader json by scan: ' + jsonPath);
            return jsonPath;
          }
        }
      }
    } catch (e) { /* dir not exists */ }
    return null;
  }

  private static ensureDir(dir: string): void {
    try { fs.mkdirSync(dir, true); } catch (e) { /* exists */ }
  }


}

/**
 * ForgeService.ets — Forge 模组加载器安装/管理服务（薄分发器）
 *
 * 版本列表 / 安装入口的品牌适配层；真正的安装由两条路径承担：
 *
 *   新版 Forge (≥1.13 / loaderVersion 首段≥20):
 *     构造 ForgelikeProfile（坐标 / 端点 / JDK / 校验后缀）→ 委派共享引擎
 *     ForgelikeInstaller（与 NeoForge 同一套：下载 installer → 解压 → 预下库 →
 *     自实现 processors（每个干净 classpath 的独立 JVM）→ 校验 → 清理）。
 *     仅保留 Forge 品牌特有的 1.17.1×37.0.x securejarhandler 不兼容前置。
 *
 *   旧版 Forge (≤1.12 / loaderVersion 首段<20，FML legacy):
 *     直接解压 installer 的 maven/ + 写 version.json + 补下 FML 依赖库，
 *     无 processors / 无 Java 子进程（installLegacyForge）。引擎不覆盖此路径。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ModLoaderType, ModLoaderVersion,
  ModLoaderInstallProgress, ModLoaderInstallCallback,
  ModLoaderInstallResult, IModLoaderService,
} from './ModLoaderTypes';
import {
  downloadMavenLibraries,
  selectFailedLibs,
  MavenLibEntry,
  computeFileSha1,
  compareMavenVersions,
  fetchMergedMavenVersions,
} from './MavenUtils';
import {
  isNewForgeVersion,
  decompressFile as decompressZipFile,
  extractLibrariesFromInstallerJson,
  installLegacyForge,
  LegacyForgeInstallResult,
  probeInstallerSha1,
  preferSourceFirst,
  InstallerSha1Probe,
} from './ForgeInstallerUtils';
import { BMCLAPI_BASE } from 'commons';
import { requiredJdkMajorForMc } from 'commons';
import {
  DownloadManager, DownloadFileSpec, DownloadTaskSpec, DownloadCheck, DownloadTaskView,
} from '../download/DownloadManager';
import { ForgelikeInstaller, ForgelikeProfile } from './ForgelikeInstaller';
import { removeDirRecursive, fileExistsAndNonEmpty, formatSpeed } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';

const TAG = 'ForgeService';

const FORGE_MAVEN = 'https://maven.minecraftforge.net';
const BMCLAPI_MAVEN = BMCLAPI_BASE + '/maven';
const BMCLAPI_LIBRARIES_BASE = BMCLAPI_BASE + '/libraries';
const FORGE_METADATA_URL = FORGE_MAVEN + '/net/minecraftforge/forge/maven-metadata.xml';
const BMCLAPI_METADATA_URL = BMCLAPI_MAVEN + '/net/minecraftforge/forge/maven-metadata.xml';
const MIN_JAR_SIZE = 10000;
const MIN_JSON_SIZE = 100;
const MIN_RAWFILE_SIZE = 1000;
const SHA1_HEX_LEN = 40;
const MAX_DOWNLOAD_ERROR_CHARS = 800;

class ForgeJsonValidationResult {
  ok: boolean = false;
  reason: string = '';

  constructor(ok: boolean, reason: string) {
    this.ok = ok;
    this.reason = reason;
  }
}

class ForgeInstallerArtifactCheckResult {
  success: boolean = false;
  reason: string = '';
  size: number = 0;
  zipOk: boolean = false;
  expectedSha1: string = '';
  actualSha1: string = '';
  sha1Ok: boolean = false;

  constructor(
    success: boolean,
    reason: string,
    size: number,
    zipOk: boolean,
    expectedSha1: string,
    actualSha1: string,
    sha1Ok: boolean
  ) {
    this.success = success;
    this.reason = reason;
    this.size = size;
    this.zipOk = zipOk;
    this.expectedSha1 = expectedSha1;
    this.actualSha1 = actualSha1;
    this.sha1Ok = sha1Ok;
  }
}

class ForgeGeneratedArtifactsCheckResult {
  ok: boolean = false;
  skipped: boolean = false;
  required: number = 0;
  found: number = 0;
  missingPaths: string[] = [];
  reason: string = '';

  constructor(
    ok: boolean,
    skipped: boolean,
    required: number,
    found: number,
    missingPaths: string[],
    reason: string
  ) {
    this.ok = ok;
    this.skipped = skipped;
    this.required = required;
    this.found = found;
    this.missingPaths = missingPaths;
    this.reason = reason;
  }
}

export class ForgeService implements IModLoaderService {
  private cachedVersions: string[] | null = null;

  async getSupportedGameVersions(): Promise<string[]> {
    let versions = await this.getAllForgeVersions();
    let gameVersions: string[] = [];
    for (let v of versions) {
      let gv = v.split('-')[0];
      if (gv && gameVersions.indexOf(gv) < 0) {
        gameVersions.push(gv);
      }
    }
    return gameVersions;
  }

  async getLoaderVersions(gameVersion: string): Promise<ModLoaderVersion[]> {
    let versions = await this.getAllForgeVersions();
    let result: ModLoaderVersion[] = [];
    let prefix = gameVersion + '-';
    AppLogger.info(TAG, `getLoaderVersions: gameVersion=${gameVersion} prefix=${prefix} total=${versions.length}`, LOG_DOMAIN_MODLOADER);
    for (let v of versions) {
      if (v.indexOf(prefix) !== 0) continue;
      let loaderVer = v.substring(prefix.length);
      let mlv: ModLoaderVersion = {
        loader: ModLoaderType.FORGE,
        loaderVersion: loaderVer,
        gameVersion: gameVersion,
        stable: true,
        displayName: 'Forge ' + loaderVer,
      };
      result.push(mlv);
    }
    result.sort((a: ModLoaderVersion, b: ModLoaderVersion) =>
      compareMavenVersions(b.loaderVersion, a.loaderVersion));
    return result;
  }

  /**
   * 构造新版 Forge 的 ForgelikeProfile（驱动共享引擎 ForgelikeInstaller）。
   * Forge maven 版本号带 mc 前缀（artifactVersion = "1.20.4-49.0.30"），与 NeoForge 不同。
   */
  private static buildForgeProfile(gameVersion: string, loaderVersion: string): ForgelikeProfile {
    let artifactVersion = gameVersion + '-' + loaderVersion;
    let profile: ForgelikeProfile = {
      loaderName: 'Forge',
      gameVersion: gameVersion,
      loaderVersion: loaderVersion,
      artifactVersion: artifactVersion,
      groupPath: 'net/minecraftforge/forge',
      artifactId: 'forge',
      // 只跳生成态 patched client（maven 上不存在）；universal / forge 自身作为 library 正常下载。
      loaderCoordPrefix: 'net.minecraftforge:forge:' + artifactVersion + ':client',
      // 2026-07-30：与 NeoForge 一致补上 BMCLAPI `/libraries` 端点（与 `/maven` 命中/回源策略
      //   不同），避免 BMCLAPI 某一端点未收录时只剩国外单源。
      installerUrls: [
        BMCLAPI_MAVEN + '/net/minecraftforge/forge/' + artifactVersion + '/forge-' + artifactVersion + '-installer.jar',
        BMCLAPI_LIBRARIES_BASE + '/net/minecraftforge/forge/' + artifactVersion + '/forge-' + artifactVersion + '-installer.jar',
        FORGE_MAVEN + '/net/minecraftforge/forge/' + artifactVersion + '/forge-' + artifactVersion + '-installer.jar',
      ],
      versionId: gameVersion + '-forge-' + loaderVersion,
      versionDirToken: 'forge',
      // 安装器 JDK 按 MC 纪元自动匹配（与游戏运行时同套：≤1.20.4→17 / 1.20.5+→21 / 26.1+→25），
      // 再由引擎从设备已装集挑 ≥required 的最低版本。fork 子进程现走 jvmInit（含 sigchain），
      // 21/25 不再 init 期 SIGSEGV，故无需再固定 17。
      requiredJdkMajor: requiredJdkMajorForMc(gameVersion),
      installerMaxConnections: 16,                  // Forge 官方 maven 支持 Range，多段逼近带宽
      // universal = Forge mod 代码（真实 maven 工件，预下载而来），稳定后缀，安装期硬校验。
      // patched client（forge-<ver>-client.jar，binarypatcher 生成）由 install_profile.data.PATCHED
      // 权威决定，引擎单独校验（不在此后缀列表，避免版本结构变化时误判）。
      runtimeRequiredJarSuffixes: ['-universal.jar'],
    };
    return profile;
  }

  async install(
    gameVersion: string, loaderVersion: string,
    mcDir: string, callback?: ModLoaderInstallCallback,
    filesDirOverride?: string
  ): Promise<ModLoaderInstallResult> {
    let forgeVersion = gameVersion + '-' + loaderVersion;
    let versionId = gameVersion + '-forge-' + loaderVersion;
    let installerPath = mcDir + '/forge-installer.jar';
    // filesDir 用于定位 JDK / fonts.conf 等用户级资源，必须是真实 app filesDir
    //（沙箱场景下 mcDir 反推会得到 forge-install-temp 目录）。
    let filesDir = filesDirOverride !== undefined && filesDirOverride.length > 0
      ? filesDirOverride
      : mcDir.substring(0, mcDir.lastIndexOf('/'));

    // ================================================================
    // 新版 Forge（≥1.13，loaderVersion 首段≥20）→ 共享引擎 ForgelikeInstaller
    //   与 NeoForge 完全同一套「下载 installer → 解压 → 预下库 → 自实现 processors
    //  （每个 processor 干净 classpath 的独立 JVM）→ 校验 → 清理」，取代旧的 bangbang93
    //   bootstrapper 同进程跑法（installer.jar shaded joptsimple/gson 泄漏隐患）。
    //   仅保留 Forge 品牌特有的 1.17.1×37.0.x securejarhandler 不兼容前置。
    // ================================================================
    if (isNewForgeVersion(loaderVersion)) {
      let compatError = this.checkJdkCompatibility(gameVersion, loaderVersion);
      if (compatError.length > 0) {
        this.report(callback, 'error', 0, 0, compatError);
        return { success: false, versionId: versionId, error: compatError };
      }
      AppLogger.info(TAG, `Forge(new) → ForgelikeInstaller: ${forgeVersion}`, LOG_DOMAIN_MODLOADER);
      return ForgelikeInstaller.install(
        ForgeService.buildForgeProfile(gameVersion, loaderVersion), mcDir, filesDir, callback);
    }

    // ================================================================
    // 旧版 Forge（≤1.12，FML legacy）：直接解压安装，无 processors / 无 Java 子进程
    //   （ForgelikeInstaller 只覆盖新版，旧版保留在此）。
    // ================================================================
    AppLogger.info(TAG, `Forge(legacy) install: version=${forgeVersion}`, LOG_DOMAIN_MODLOADER);
    let existingVersionId = this.findExistingForgeVersionDir(mcDir, gameVersion, loaderVersion);
    if (existingVersionId) {
      let existingJsonPath = mcDir + '/versions/' + existingVersionId + '/' + existingVersionId + '.json';
      let existingJsonCheck = this.validateVersionJson(existingJsonPath);
      let existingForgeJar = this.checkForgeLibraryJar(mcDir, forgeVersion);
      let existingGenerated = this.checkForgeGeneratedArtifacts(mcDir, existingVersionId);
      if (existingJsonCheck.ok && existingForgeJar && existingGenerated.ok) {
        this.report(callback, 'checking', 0, 8, '检测到 Forge 已完整安装，跳过重复安装...');
        this.report(callback, 'done', 8, 8, 'Forge ' + loaderVersion + ' 已安装，无需重复安装。');
        let installed: ModLoaderInstallResult = { success: true, versionId: existingVersionId };
        return installed;
      }
      AppLogger.warn(TAG,
        `Existing Forge install incomplete, reinstalling: ${existingVersionId}`,
        null, LOG_DOMAIN_MODLOADER);
    }
    try {
      // ================================================================
      // Step 1: 下载 Forge installer jar（BMCLAPI 镜像优先，失败回退官方源）
      // 参照 PCL McDownloadForgelikeLoader: 准备下载 → 下载主文件
      // ================================================================
      this.report(callback, 'downloading_installer', 0, 8, '下载 Forge 安装器...');
      let downloadErrors: string[] = [];
      // 2026-07-30：补 BMCLAPI `/libraries` 端点（与 `/maven` 命中/回源策略不同），
      //   避免某一端点未收录时只剩国外单源。
      let installerRel = '/net/minecraftforge/forge/' + forgeVersion
        + '/forge-' + forgeVersion + '-installer.jar';
      // 探测到 `.sha1` 的源会被提到最前（preferSourceFirst），故不是 const。
      let installerUrls: string[] = [
        BMCLAPI_MAVEN + installerRel,
        BMCLAPI_LIBRARIES_BASE + installerRel,
        FORGE_MAVEN + installerRel,
      ];

      // Phase 9 (ARCH-1 闭环)：installer.jar 走 NAPI 引擎多源下载（断点续传 +
      // 坏主机黑名单 + 增量 SHA1）。先取期望 sha1（任一镜像成功即可），再调
      // createAndWait 一次性下完。后续 checkInstallerArtifact 仍跑一遍 ZIP 头
      // 校验作为额外保险（NAPI 仅校验 sha1 + size，不感知 PK/EOCD）。
      // v4.8：撤掉之前的"前 512KB 测速探针"。它测到的是 BMCLAPI 的突发速度（实测 460KB/s），
      // 但真实下载会撞上 BMCLAPI 节点抖动 403（302→后端节点偶发 403，HMCL issue #4010 同款）
      // + 官方源 5s 无数据 stall——探针既误导又多打一次请求。改回 HMCL/PCL2 做法：固定多源顺序
      // （BMCLAPI 优先 + 官方兜底）+ 引擎多轮重试轮换节点/续传分段（kMaxFileRetries 已 3→8）。
      let preferRealSource = false;

      let mgr = DownloadManager.instance();
      // 2026-08-08：与新版分支共用 probeInstallerSha1（并发 + 6s 超时 + 不抛异常）。
      //   旧实现是「一次 fetchText(primary, mirrors) + 默认 30s + 失败抛异常」：某一源挂住时
      //   要白等 30s 才开始下安装器，且抛出的异常会被记进 downloadErrors 并（配合上面已修的
      //   checkInstallerArtifact）把整次安装判死。命中 `.sha1` 的源同时提到 URL 最前。
      let shaProbe: InstallerSha1Probe = await probeInstallerSha1(installerUrls);
      let expectedSha1: string = shaProbe.sha1;
      installerUrls = preferSourceFirst(installerUrls, shaProbe.sourceIndex);
      let primaryInstallerUrl = installerUrls[0];

      let downloaded = false;
      try { fs.unlinkSync(installerPath); } catch (e) { /* not exists */ }
      let check: DownloadCheck | undefined = undefined;
      if (expectedSha1.length === SHA1_HEX_LEN) {
        check = { sha1: expectedSha1 };
      }
      let installerFile: DownloadFileSpec = {
        localPath: installerPath, urls: installerUrls, allowedRoot: mcDir,
        // v4.9 (2026-06-06)：Forge installer.jar 用高并发分段下载。
        // 设备实测：BMCLAPI /maven 对该文件间歇性 403，引擎回落到官方 Forge maven
        // （支持 Range 但单连接仅 ~30KB/s），默认 4 段只有 ~120KB/s，8MB 安装器要 60~300s。
        // 本机网络可达 6MB/s，瓶颈在镜像单连接限速 → 多开并行段逼近真实上限（对齐 PCL2
        // "速度低时追加线程"）。16 由引擎钳制到 worker 池上限与文件大小。
        maxConnections: 16,
      };
      if (check !== undefined) installerFile.check = check;
      let installerSpec: DownloadTaskSpec = {
        name: 'Forge 安装器 ' + forgeVersion,
        files: [installerFile],
      };
      try {
        AppLogger.info(TAG, `NAPI installer download: urls=${installerUrls.length} sha1=${expectedSha1.length === SHA1_HEX_LEN ? expectedSha1 : '(none)'}`, LOG_DOMAIN_MODLOADER);
        // createAndWait: success → resolve(view)；其它（含 aborted / 全源失败）→ reject(Error)
        // 2026-07-30：补字节级进度回调。此前无 onProgress，整个安装器下载期间 UI 恒定停在
        //   'downloading_installer' 的 0/8 = 0%（新版分支同款问题，见 ForgelikeInstaller）。
        await mgr.createAndWait(installerSpec, (v: DownloadTaskView): void => {
          let total = v.bytesTotal > 0 ? v.bytesTotal : 0;
          let frac = total > 0 ? v.bytesDone / total : 0;
          if (frac < 0) frac = 0;
          if (frac > 1) frac = 1;
          let doneMb = (v.bytesDone / 1048576).toFixed(1);
          let totalMb = total > 0 ? (total / 1048576).toFixed(1) : '?';
          let speed = v.speedBps > 0 ? ' ' + formatSpeed(v.speedBps) : '';
          this.report(callback, 'downloading_installer', frac, 8,
            '下载 Forge 安装器 (' + doneMb + '/' + totalMb + ' MB)' + speed);
        });
        // 后置 ZIP/EOCD/PK + sha1 校验（防御性，NAPI 已做 sha1，但保留 PK/EOCD 检查作额外保险）
        let postCheck = await this.checkInstallerArtifact(installerPath, expectedSha1);
        this.logInstallerArtifactCheck(primaryInstallerUrl, postCheck);
        if (postCheck.success) {
          downloaded = true;
        } else {
          downloadErrors.push('[postCheck] ' + postCheck.reason);
          try { fs.unlinkSync(installerPath); } catch (e2) { /* */ }
        }
      } catch (e) {
        let reason = (e as Error).message || String(e);
        AppLogger.warn(TAG, `NAPI installer download failed: ${reason}`, null, LOG_DOMAIN_MODLOADER);
        downloadErrors.push('[NAPI] ' + reason);
        try { fs.unlinkSync(installerPath); } catch (e2) { /* */ }
      }

      if (!downloaded) {
        let detail = this.compactDownloadErrors(downloadErrors);
        let errMsg = '下载 Forge 安装器失败';
        if (detail.length > 0) errMsg += '\n' + detail;
        this.report(callback, 'error', 0, 0, errMsg);
        let r: ModLoaderInstallResult = { success: false, versionId: versionId, error: errMsg };
        return r;
      }

      // ================================================================
      // Step 2: 解压 installer jar → 提取 install_profile.json + version.json
      // 参照 PCL: Installer = New ZipArchive(...)
      //           Json = GetJson(ReadFile(Installer.GetEntry("install_profile.json")))
      //           Json2 = GetJson(ReadFile(Installer.GetEntry("version.json")))
      //           Json.Merge(Json2)
      // ================================================================
      this.report(callback, 'extracting', 1, 8, '解压 Forge 安装器...');
      let installerTempDir = mcDir + '/forge-install-temp';
      try { removeDirRecursive(installerTempDir); } catch (e) { /* */ }
      try { fs.mkdirSync(installerTempDir, true); } catch (e) { /* */ }
      await decompressZipFile(installerPath, installerTempDir);

      let installProfilePath = installerTempDir + '/install_profile.json';
      let versionJsonFromInstaller = installerTempDir + '/version.json';
      let installProfileExists = fileExistsAndNonEmpty(installProfilePath);
      let versionJsonExists = fileExistsAndNonEmpty(versionJsonFromInstaller);
      AppLogger.info(TAG, `Extracted installer: profile=${installProfileExists ? 'yes' : 'no'} versionJson=${versionJsonExists ? 'yes' : 'no'}`, LOG_DOMAIN_MODLOADER);

      // ================================================================
      // 旧版 Forge（PCL Legacy 方式）：直接解压安装，不需要运行 installer
      // 参照 PCL: If Not IsNeoForge AndAlso LoaderVersion.BeforeFirst(".") < 20
      //   Legacy 方式 1: install_profile.json 无 "install" 字段 → 直接解压 maven/
      //   Legacy 方式 2: install_profile.json 有 "install" 字段 → 解压指定 jar
      // ================================================================
      // 走到此处必为旧版 Forge（新版已在方法开头委派给 ForgelikeInstaller 并 return）。
      {
        this.report(callback, 'installing', 2, 8, '安装旧版 Forge（直接解压）...');
        let legacyResult = installLegacyForge(
          gameVersion, loaderVersion, forgeVersion, versionId,
          mcDir, installerTempDir, installProfilePath, versionJsonFromInstaller);

        // 旧版 Forge（FML legacy）依赖库下载（2026-06-13 修复"完整性校验缺 16 个库"根因）：
        // installLegacyForge 只写 version.json + 复制 installer 内置 maven/（仅 Forge 自身产物），
        // 而 FML 的依赖库（launchwrapper / asm-all / scala-* / akka / typesafe-config / jline 等）
        // 既不在 installer 的 maven/ 内、也不属于原版库 → 此前从不被下载 → 启动前完整性校验必报
        // 缺失（新版 Forge 分支本就会下，旧版分支漏了）。这里补上：从写好的 version.json 提取依赖
        // 库，走与新版同一套多源下载（BMCLAPI / forge maven / 阿里云回退）。Forge 自身产物已在磁盘
        // → downloadMavenLibrary 的"已存在则跳过"会自动略过，无重复下载。
        if (legacyResult.success) {
          let libDir = mcDir + '/libraries';
          try { fs.mkdirSync(libDir, true); } catch (e) { /* exists */ }
          try {
            let writtenJson = mcDir + '/versions/' + versionId + '/' + versionId + '.json';
            let libEntriesRaw = extractLibrariesFromInstallerJson(installProfilePath, writtenJson, forgeVersion);
            // OHOS 用自带 lwjgl-ohos，跳过原版 LWJGL/jinput/jutils（含不存在基础 jar 的 *-platform
            // natives 库，否则全源 404 拖垮安装）。与 LaunchProfileBuilder classpath 跳过口径一致。
            let libEntries: MavenLibEntry[] = [];
            for (let e of libEntriesRaw) {
              if (e.name.indexOf('org.lwjgl') === 0
                || e.name.indexOf('net.java.jinput') === 0
                || e.name.indexOf('net.java.jutils') === 0) {
                continue;
              }
              libEntries.push(e);
            }
            AppLogger.info(TAG, `Legacy Forge: ensuring ${libEntries.length} dependency libs (filtered from ${libEntriesRaw.length})`, LOG_DOMAIN_MODLOADER);
            if (libEntries.length > 0) {
              this.report(callback, 'pre_download_libs', 4, 8, '下载旧版 Forge 依赖库...');
              let libResult = await downloadMavenLibraries(libEntries, libDir,
                (done: number, total: number, name: string, fraction: number) => {
                  // 字节加权优先（见 MavenLibsProgressCallback），拿不到字节总量才回退文件计数。
                  let frac = fraction >= 0 ? fraction : (total > 0 ? done / total : 0);
                  this.report(callback, 'pre_download_libs', 4 + frac * 3, 8,
                    '下载依赖库 (' + done + '/' + total + '): ' + name);
                }, preferRealSource);
              if (libResult.failed > 0) {
                // ⚠️ A-01 修复（2026-07-29）：只重试失败项。旧实现重下整批，而旧版 Forge 的
                //   FML 依赖全部无 sha1/size（不带 check），native 对"无 checker 且目标已存在"
                //   的提交会拒绝（N-01）→ 第二轮把第一轮成功项逐个判失败 → 永久失败闭环。
                let retryLibs = selectFailedLibs(libEntries, libResult);
                AppLogger.warn(TAG,
                  `Legacy Forge libs: ${libResult.failed} failed, retrying ${retryLibs.length} of ${libEntries.length}`,
                  null, LOG_DOMAIN_MODLOADER);
                this.report(callback, 'pre_download_libs', 4, 8,
                  libResult.failed + ' 个库下载失败，正在重试...');
                // 空子集 = 失败项全为非法坐标，重试无意义，沿用第一轮结论。
                let retry = retryLibs.length > 0
                  ? await downloadMavenLibraries(retryLibs, libDir,
                      (done: number, total: number, name: string, fraction: number) => {
                        let frac = fraction >= 0 ? fraction : (total > 0 ? done / total : 0);
                        this.report(callback, 'pre_download_libs', 4 + frac * 3, 8,
                          '重试依赖库 (' + done + '/' + total + '): ' + name);
                      }, preferRealSource)
                  : libResult;
                if (retry.failed > 0) {
                  let names = (retry.failedNames || []).slice(0, 5).join(', ');
                  legacyResult = new LegacyForgeInstallResult(false, versionId,
                    '旧版 Forge 依赖库下载失败（' + names
                    + (retry.failed > 5 ? ' 等 ' + retry.failed + ' 个' : '') + '），请检查网络后重试');
                }
              }
            }
          } catch (e) {
            AppLogger.error(TAG, `Legacy Forge dependency download failed: ${(e as Error).message}`, e as Object, LOG_DOMAIN_MODLOADER);
            legacyResult = new LegacyForgeInstallResult(false, versionId,
              '旧版 Forge 依赖库下载异常: ' + (e as Error).message);
          }
        }

        // 清理临时文件
        try { fs.unlinkSync(installerPath); } catch (e) { /* */ }
        try { removeDirRecursive(installerTempDir); } catch (e) { /* */ }
        if (legacyResult.success) {
          this.report(callback, 'done', 8, 8, 'Forge ' + loaderVersion + ' 安装完成（旧版模式）！');
        } else {
          this.report(callback, 'error', 8, 8, legacyResult.error || '旧版 Forge 安装失败');
        }
        let r: ModLoaderInstallResult = {
          success: legacyResult.success,
          versionId: legacyResult.versionId,
          error: legacyResult.error,
        };
        return r;
      }

      // [已迁移] 新版 Forge 安装（Step3–9：预下库 / mappings / maven / processors / 校验）
      // 已整体迁移到共享引擎 ForgelikeInstaller（见方法开头的 isNewForgeVersion 分支）。
      // 此处原 bangbang93 bootstrapper 同进程跑 processors 的实现已删除。
    } catch (e) {
      let msg = (e as Error).message || String(e);
      AppLogger.error(TAG, `Forge install failed: ${msg}`, e as Object, LOG_DOMAIN_MODLOADER);
      this.report(callback, 'error', 0, 0, '安装失败: ' + msg, msg);
      let r: ModLoaderInstallResult = { success: false, versionId: versionId, error: msg };
      return r;
    }
  }

  private validateVersionJson(jsonPath: string): ForgeJsonValidationResult {
    try {
      let st = fs.statSync(jsonPath);
      if (st.size <= MIN_JSON_SIZE) {
        return new ForgeJsonValidationResult(false, 'json 文件过小: ' + st.size + ' bytes');
      }
      let content = fs.readTextSync(jsonPath);
      let data = JSON.parse(content) as Record<string, Object>;
      let id = data['id'] as string;
      if (!id || id.length === 0) {
        return new ForgeJsonValidationResult(false, 'json 缺少 id 字段');
      }
      return new ForgeJsonValidationResult(true, '');
    } catch (e) {
      return new ForgeJsonValidationResult(false, (e as Error).message || String(e));
    }
  }

  private isLikelyZipArchive(path: string): boolean {
    try {
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let buf = new ArrayBuffer(4);
        let len = fs.readSync(file.fd, buf);
        if (len < 4) return false;
        let bytes = new Uint8Array(buf, 0, 4);
        // ZIP/JAR header: PK\x03\x04 / PK\x05\x06 / PK\x07\x08
        return bytes[0] === 0x50 && bytes[1] === 0x4b &&
          ((bytes[2] === 0x03 && bytes[3] === 0x04) ||
            (bytes[2] === 0x05 && bytes[3] === 0x06) ||
            (bytes[2] === 0x07 && bytes[3] === 0x08));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return false;
    }
  }

  /**
   * `.sha1` 侧车探测已收敛到 ForgeInstallerUtils.probeInstallerSha1（并发 + 6s + 不抛异常），
   * 与新版 forge-like 分支共用同一实现。原 ForgeService.fetchInstallerSha1 已删除。
   */

  private async checkInstallerArtifact(
    installerPath: string,
    expectedSha1: string
  ): Promise<ForgeInstallerArtifactCheckResult> {
    let size = 0;
    try {
      size = fs.statSync(installerPath).size;
    } catch (e) {
      return new ForgeInstallerArtifactCheckResult(
        false,
        'installer 文件不存在',
        0,
        false,
        expectedSha1,
        '',
        false
      );
    }

    if (size <= MIN_JAR_SIZE) {
      return new ForgeInstallerArtifactCheckResult(
        false,
        'installer 文件过小: ' + size + ' bytes',
        size,
        false,
        expectedSha1,
        '',
        false
      );
    }

    let zipOk = this.isLikelyZipArchive(installerPath);
    if (!zipOk) {
      return new ForgeInstallerArtifactCheckResult(
        false,
        'installer 文件头非 ZIP/JAR',
        size,
        false,
        expectedSha1,
        '',
        false
      );
    }

    // ⚠️ 2026-08-08：这里原本返回 success=false，把「**没有期望值可比**」当成了「校验不通过」。
    //   后果：`.sha1` 侧车任何一次拿不到（三源全 404 / 超时）→ 已经完整下好并通过 ZIP 头校验的
    //   安装器被 `fs.unlinkSync` 删掉 → `downloaded=false` → 直接报「下载 Forge 安装器失败」，
    //   且没有任何重试。新版分支 ForgelikeInstaller.checkInstallerArtifact 的语义一直是
    //   「无 sha1 → 仅 ZIP 头校验」，两条分支对同一件事结论相反。此处对齐新版。
    if (!expectedSha1 || expectedSha1.length !== SHA1_HEX_LEN) {
      return new ForgeInstallerArtifactCheckResult(
        true,
        '无期望 SHA1，仅通过 ZIP 头校验',
        size,
        true,
        expectedSha1,
        '',
        false
      );
    }

    let actualSha1 = await computeFileSha1(installerPath);
    let sha1Ok = actualSha1 === expectedSha1;
    if (!sha1Ok) {
      return new ForgeInstallerArtifactCheckResult(
        false,
        'SHA1 不匹配',
        size,
        true,
        expectedSha1,
        actualSha1,
        false
      );
    }

    return new ForgeInstallerArtifactCheckResult(
      true,
      '',
      size,
      true,
      expectedSha1,
      actualSha1,
      true
    );
  }

  private logInstallerArtifactCheck(url: string, check: ForgeInstallerArtifactCheckResult): void {
    AppLogger.info(TAG,
      `Installer artifact check: url=${url} size=${check.size} zipOk=${check.zipOk ? 'yes' : 'no'} sha1Ok=${check.sha1Ok ? 'yes' : 'no'} expected=${check.expectedSha1} actual=${check.actualSha1} success=${check.success ? 'yes' : 'no'} reason=${check.reason}`,
      LOG_DOMAIN_MODLOADER
    );
  }

  private compactDownloadErrors(errors: string[]): string {
    if (errors.length === 0) return '';
    let merged = errors.join('\n');
    if (merged.length <= MAX_DOWNLOAD_ERROR_CHARS) return merged;
    return merged.substring(0, MAX_DOWNLOAD_ERROR_CHARS) + '...';
  }

  /**
   * 检查 Forge library jar 是否存在（在 libraries/ 中的多种可能路径）
   */
  private checkForgeLibraryJar(mcDir: string, forgeVersion: string): boolean {
    let libDir = mcDir + '/libraries/net/minecraftforge/forge/' + forgeVersion;
    try {
      let files = fs.listFileSync(libDir);
      for (let f of files) {
        if (f.endsWith('.jar')) {
          try {
            let st = fs.statSync(libDir + '/' + f);
            if (st.size > MIN_RAWFILE_SIZE) return true;
          } catch (e) { /* */ }
        }
      }
    } catch (e) { /* */ }
    return false;
  }

  /**
   * 校验新版 Forge（BootstrapLauncher）运行所需的关键 processor 产物是否真实存在：
   * - net.minecraft:client:*:extra
   * - net.minecraft:client:*:srg
   * - net.minecraftforge:forge:*:client
   */
  private checkForgeGeneratedArtifacts(mcDir: string, versionId: string): ForgeGeneratedArtifactsCheckResult {
    let versionJsonPath = mcDir + '/versions/' + versionId + '/' + versionId + '.json';
    let versionJson = '';
    try {
      versionJson = fs.readTextSync(versionJsonPath);
    } catch (e) {
      return new ForgeGeneratedArtifactsCheckResult(
        false, false, 0, 0, [], '无法读取 version.json: ' + versionJsonPath
      );
    }

    // 旧版 Forge（非 BootstrapLauncher）不适用此检查
    if (versionJson.indexOf('cpw.mods.bootstraplauncher.BootstrapLauncher') < 0) {
      return new ForgeGeneratedArtifactsCheckResult(true, true, 0, 0, [], '');
    }

    let requiredCoords = this.collectRequiredGeneratedCoords(versionJson);
    if (requiredCoords.length === 0) {
      // 某些 Forge（实测 1.20.1-47.x）的 launch version.json 不在 libraries 的 "name" 字段里
      // 直接列出 srg/extra/forge-client 坐标——它们通过 jvm args 的模块路径/占位符引用。
      // 旧逻辑在此硬判失败：installer 明明 rc=0 且产物齐全（日志逐个 FIXED），却被误判为
      // “文件完整性校验未通过”，随后已装好的版本目录被删除（用户白等数分钟）。
      // 改为退回“按已知目录结构扫描真实生成产物”，与本类“以文件实际存在为主”的判定哲学一致。
      AppLogger.warn(TAG,
        'No generated coords parsed from version.json; fallback to libraries dir-scan', null, LOG_DOMAIN_MODLOADER);
      return this.checkGeneratedArtifactsByDirScan(mcDir);
    }

    let libDir = mcDir + '/libraries';
    let found = 0;
    let missing: string[] = [];
    // Forge processor 产物（srg/extra/client jar）通常在数百 KB 到数十 MB 之间
    // 使用更严格的最小大小阈值（4KB），避免 zlib 损坏导致的截断文件被误判为有效
    let minGeneratedArtifactSize = 4096;
    for (let coord of requiredCoords) {
      let path = this.mavenCoordToPath(coord, libDir);
      let ok = false;
      try {
        let st = fs.statSync(path);
        ok = st.size > minGeneratedArtifactSize;
        if (!ok && st.size > 0) {
          AppLogger.warn(TAG, `Generated artifact too small (likely corrupted): ${path} (${st.size} bytes)`, null, LOG_DOMAIN_MODLOADER);
        }
      } catch (e) {
        ok = false;
      }
      AppLogger.info(TAG, `Generated artifact check: ${coord} -> ${path} ${ok ? 'OK' : 'MISSING'}`, LOG_DOMAIN_MODLOADER);
      if (ok) {
        found++;
      } else {
        missing.push(path);
      }
    }

    let okAll = missing.length === 0;
    return new ForgeGeneratedArtifactsCheckResult(
      okAll,
      false,
      requiredCoords.length,
      found,
      missing,
      okAll ? '' : '关键 processor 产物不完整'
    );
  }

  /**
   * 退路校验：当无法从 version.json 解析出生成产物坐标时（不同 Forge 版本 json 结构差异），
   * 直接按已知目录结构扫描 processors 真实产出的关键 jar：
   *   - libraries/net/minecraft/client/<mcver>/client-<mcver>-srg.jar   （SRG 重映射后的 MC，核心）
   *   - libraries/net/minecraft/client/<mcver>/client-<mcver>-extra.jar （资源 extra，参考）
   *   - libraries/net/minecraftforge/forge/<fv>/forge-<fv>-client.jar    （Forge 补丁 client，核心）
   *
   * 判定：srg + forge-client 同时存在（且 > 4KB）即认定 processors 跑完——这两个是
   * BootstrapLauncher 运行的硬产物；extra 个别版本可能不产出，故仅记录不强制。
   */
  private checkGeneratedArtifactsByDirScan(mcDir: string): ForgeGeneratedArtifactsCheckResult {
    let libDir = mcDir + '/libraries';
    let minSize = 4096;

    let srgFound = false;
    let extraFound = false;
    let mcClientDir = libDir + '/net/minecraft/client';
    try {
      let vers = fs.listFileSync(mcClientDir);
      for (let v of vers) {
        let dir = mcClientDir + '/' + v;
        if (this.fileBiggerThan(dir + '/client-' + v + '-srg.jar', minSize)) srgFound = true;
        if (this.fileBiggerThan(dir + '/client-' + v + '-extra.jar', minSize)) extraFound = true;
      }
    } catch (e) { /* 目录不存在 → 视为未生成 */ }

    let forgeClientFound = false;
    let forgeDir = libDir + '/net/minecraftforge/forge';
    try {
      let vers = fs.listFileSync(forgeDir);
      for (let v of vers) {
        if (this.fileBiggerThan(forgeDir + '/' + v + '/forge-' + v + '-client.jar', minSize)) {
          forgeClientFound = true;
        }
      }
    } catch (e) { /* 目录不存在 → 视为未生成 */ }

    let missing: string[] = [];
    if (!srgFound) missing.push(mcClientDir + '/*/client-*-srg.jar');
    if (!forgeClientFound) missing.push(forgeDir + '/*/forge-*-client.jar');
    let ok = srgFound && forgeClientFound;
    let found = (srgFound ? 1 : 0) + (extraFound ? 1 : 0) + (forgeClientFound ? 1 : 0);
    AppLogger.info(TAG,
      `Generated artifacts dir-scan: srg=${srgFound ? 'yes' : 'no'} extra=${extraFound ? 'yes' : 'no'} forgeClient=${forgeClientFound ? 'yes' : 'no'} ok=${ok ? 'yes' : 'no'}`,
      LOG_DOMAIN_MODLOADER);
    return new ForgeGeneratedArtifactsCheckResult(
      ok, false, 2, found, missing,
      ok ? '' : '目录扫描未找到关键 processor 产物（srg / forge-client）'
    );
  }

  private fileBiggerThan(path: string, minSize: number): boolean {
    try {
      return fs.statSync(path).size > minSize;
    } catch (e) {
      return false;
    }
  }

  private collectRequiredGeneratedCoords(versionJson: string): string[] {
    let mcExtra = '';
    let mcSrg = '';
    let forgeClient = '';
    let coordRegex = /"name"\s*:\s*"([^"]+)"/g;
    let m = coordRegex.exec(versionJson);
    while (m !== null) {
      let coord = m[1];
      if (mcExtra.length === 0 && this.isMinecraftClientClassifier(coord, 'extra')) {
        mcExtra = coord;
      } else if (mcSrg.length === 0 && this.isMinecraftClientClassifier(coord, 'srg')) {
        mcSrg = coord;
      } else if (forgeClient.length === 0 && this.isForgeClientClassifier(coord)) {
        forgeClient = coord;
      }
      m = coordRegex.exec(versionJson);
    }

    let out: string[] = [];
    if (mcExtra.length > 0) out.push(mcExtra);
    if (mcSrg.length > 0) out.push(mcSrg);
    if (forgeClient.length > 0) out.push(forgeClient);
    return out;
  }

  private isMinecraftClientClassifier(coord: string, classifier: string): boolean {
    let parts = this.splitMavenCoord(coord);
    if (parts.length < 4) return false;
    return parts[0] === 'net.minecraft'
      && parts[1] === 'client'
      && parts[3] === classifier;
  }

  private isForgeClientClassifier(coord: string): boolean {
    let parts = this.splitMavenCoord(coord);
    if (parts.length < 4) return false;
    return parts[0] === 'net.minecraftforge'
      && parts[1] === 'forge'
      && parts[3] === 'client';
  }

  private splitMavenCoord(coord: string): string[] {
    let clean = coord;
    let at = clean.indexOf('@');
    if (at >= 0) clean = clean.substring(0, at);
    return clean.split(':');
  }

  private mavenCoordToPath(coord: string, libDir: string): string {
    let clean = coord;
    if (clean.startsWith('[') && clean.endsWith(']')) {
      clean = clean.substring(1, clean.length - 1);
    }
    let ext = 'jar';
    let at = clean.indexOf('@');
    if (at >= 0) {
      ext = clean.substring(at + 1);
      clean = clean.substring(0, at);
    }
    let parts = clean.split(':');
    if (parts.length < 3) {
      return libDir + '/' + clean.replace(/\./g, '/');
    }
    let group = parts[0].replace(/\./g, '/');
    let artifact = parts[1];
    let version = parts[2];
    let classifier = parts.length >= 4 ? parts.slice(3).join(':') : '';
    let file = artifact + '-' + version + (classifier.length > 0 ? '-' + classifier : '') + '.' + ext;
    return libDir + '/' + group + '/' + artifact + '/' + version + '/' + file;
  }

  private findExistingForgeVersionDir(mcDir: string, gameVersion: string, loaderVersion: string): string | null {
    let versionsDir = mcDir + '/versions';
    let exact1 = gameVersion + '-forge-' + loaderVersion;
    let exact2 = gameVersion + '-forge-' + gameVersion + '-' + loaderVersion;
    for (let name of [exact1, exact2]) {
      let jsonPath = versionsDir + '/' + name + '/' + name + '.json';
      let check = this.validateVersionJson(jsonPath);
      if (check.ok) return name;
    }
    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        if (name.indexOf('forge') < 0) continue;
        if (name.indexOf(gameVersion) < 0) continue;
        if (name.indexOf(loaderVersion) < 0) continue;
        let jsonPath = versionsDir + '/' + name + '/' + name + '.json';
        let check = this.validateVersionJson(jsonPath);
        if (check.ok) return name;
      }
    } catch (e) { /* versions dir missing */ }
    return null;
  }

  async uninstall(versionId: string, mcDir: string): Promise<boolean> {
    let dir = mcDir + '/versions/' + versionId;
    try {
      try { fs.unlinkSync(dir + '/' + versionId + '.json'); } catch (e) { /* */ }
      try { fs.rmdirSync(dir); } catch (e) { /* */ }
      return true;
    } catch (e) { return false; }
  }

  private async getAllForgeVersions(): Promise<string[]> {
    if (this.cachedVersions) return this.cachedVersions;
    // 官方源 + BMCLAPI 镜像合并去重（不"首个非空即返回"，避免镜像落后丢新版本，如 1.20.1）。
    let merged = await fetchMergedMavenVersions([FORGE_METADATA_URL, BMCLAPI_METADATA_URL], 'Forge');
    if (merged.length > 0) {
      this.cachedVersions = merged;
      let first3 = merged.slice(0, 3).join(', ');
      let last3 = merged.slice(-3).join(', ');
      AppLogger.info(TAG, `Forge versions merged: ${merged.length} first=[${first3}] last=[${last3}]`, LOG_DOMAIN_MODLOADER);
      return merged;
    }
    throw new Error('无法获取 Forge 版本列表');
  }

  private report(cb: ModLoaderInstallCallback | undefined,
    phase: string, current: number, total: number, message: string, error?: string) {
    if (cb) {
      let p: ModLoaderInstallProgress = { phase, current, total, message, error };
      cb(p);
    }
  }

  /**
   * Forge 与 JDK 兼容性 fail-fast 检查（仅 1.17.1 早期 37.0.x × securejarhandler 0.9.44 不兼容）。
   * 安装/运行时 JDK 路由由 ForgelikeInstaller / JdkManager 接管。
   */
  private checkJdkCompatibility(gameVersion: string, loaderVersion: string): string {
    if (gameVersion === '1.17.1' && compareMavenVersions(loaderVersion, '37.1.0') < 0) {
      return 'Forge ' + gameVersion + '-' + loaderVersion
        + ' 已知与 JDK17 不兼容（securejarhandler API 差异）。'
        + '\n请改用 Forge 37.1.0 及以上版本。';
    }
    return '';
  }
}

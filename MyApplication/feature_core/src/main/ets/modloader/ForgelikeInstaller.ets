/**
 * ForgelikeInstaller.ets — Forge-like 加载器「新版安装器」共享引擎（Forge ≥1.13 / NeoForge）
 *
 * Forge 与 NeoForge 安装器同构（install_profile.json + version.json + processors，跑
 * com.bangbang93.ForgeInstaller bootstrapper）。本引擎把「下载 installer → 解压 → 预下库 →
 * 复制内置 maven → 预下 mappings → 跑 bootstrapper → 校验产物 → 清理」这段**品牌无关**流程
 * 收敛到一处，由 ForgelikeProfile 注入差异（坐标 / 端点 / 版本号 / 目录命名 / JDK）。
 *
 * 设计（见 docs/adaptation/NeoForge适配方案.md §0）：Forge 与 NeoForge 两个 Service **平级**，
 * 都依赖本引擎，互不依赖。NeoForge 全是新版流程（无旧版直解压分支），故引擎只覆盖新版。
 *
 * 校验哲学（沿用 ForgeService）：以**文件实际存在**为主、installRc 仅作参考——OHOS JDK 的 zlib
 * 实现会让 installer 因 SHA1 不匹配 exit(1)，但产物可能已正确生成。安装期判定从宽（避免误删好
 * 安装），真正的完整性兜底交给启动期的 LaunchProfileBuilder / PreLaunchValidator。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ModLoaderInstallProgress, ModLoaderInstallCallback, ModLoaderInstallResult,
} from './ModLoaderTypes';
import { downloadMavenLibraries, selectFailedLibs, computeFileSha1, MavenLibEntry } from './MavenUtils';
import {
  decompressFile, extractLibrariesFromInstallerJson, preDownloadMappings, copyMavenToLibraries,
  installedJdkMajors, probeInstallerSha1, preferSourceFirst, InstallerSha1Probe,
} from './ForgeInstallerUtils';
import { forgeNative } from './ForgelikeNative';
import { ForgelikeProcessorRunner } from './ForgelikeProcessorRunner';
import {
  DownloadManager, DownloadFileSpec, DownloadTaskSpec, DownloadCheck, DownloadTaskView,
} from '../download/DownloadManager';
import { removeDirRecursive, fileExistsAndNonEmpty, formatSpeed } from 'commons';
import { resolveFontconfigSource, FONTCONFIG_MIN_SIZE_BYTES } from 'commons';
import { pickInstalledJdkMajor } from 'commons';
import { detectMcEra, McEra } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';

const TAG = 'ForgelikeInstaller';

const MIN_JAR_SIZE = 10000;
const MIN_JSON_SIZE = 100;
const MIN_RAWFILE_SIZE = 1000;
const SHA1_HEX_LEN = 40;
const MIN_GENERATED_ARTIFACT_SIZE = 4096;
const FORGE_INSTALLER_XMX_FALLBACK_MB = 2048;
const FORGE_INSTALLER_XMX_MIN_MB = 1024;
const FORGE_INSTALLER_XMX_MAX_MB = 4096;
const FORGE_INSTALLER_XMX_STEP_MB = 256;

/** 品牌差异描述符：Forge / NeoForge 各自填好后驱动同一引擎。 */
export interface ForgelikeProfile {
  loaderName: string;          // 显示名："Forge" | "NeoForge"
  gameVersion: string;         // MC 版本，如 "1.20.4"
  loaderVersion: string;       // 加载器自身版本：forge "49.0.30" / neoforge "20.4.196"
  artifactVersion: string;     // maven 版本段：forge "1.20.4-49.0.30" / neoforge "20.4.196"
  groupPath: string;           // maven group 路径："net/minecraftforge/forge" | "net/neoforged/neoforge"
  artifactId: string;          // maven artifact："forge" | "neoforge"
  loaderCoordPrefix: string;   // 跳过加载器自身坐标的前缀（去 maven 下载会 404）
  installerUrls: string[];     // installer jar 多源 URL（BMCLAPI 镜像优先）
  versionId: string;           // 生成的版本目录名："<game>-neoforge-<loader>"
  versionDirToken: string;     // 目录差分识别 token："forge" | "neoforge"
  requiredJdkMajor: number;    // 安装该版本所需的最低 JDK 大版本（17/21/25）；引擎据此 + 已装集自动选 JDK
  // installer.jar 下载并发段数。NeoForge 镜像链（BMCLAPI→USTC）不支持 Range 且并发限流（429），
  // 用 1；Forge 官方 maven 支持 Range 但单连接限速，用多段（16）逼近真实带宽。
  installerMaxConnections: number;
  // 安装期硬校验的【运行时必需、稳定后缀】加载器 jar 后缀（相对 <artifactId>-<artifactVersion>）：
  //   两个品牌都用 ['-universal.jar']——universal 含 mod 代码、由 fml 从 libraryDirectory 发现，
  //   不在 version.json libraries，启动前校验看不到，必须安装期校验。
  // patched MC client jar 不在此列：其坐标随版本/品牌变（26.x=minecraft-client-patched /
  //   1.21.x=neoforge:client / Forge=forge:client），由 install_profile 的 data.PATCHED 权威决定，
  //   安装期单独按 ForgelikeProcessorResult.patchedClientPath 校验（见 missingRuntimeLoaderJars）。
  runtimeRequiredJarSuffixes: string[];
}

class CheckResult {
  ok: boolean;
  reason: string;
  constructor(ok: boolean, reason: string) { this.ok = ok; this.reason = reason; }
}

export class ForgelikeInstaller {
  /**
   * 执行一次新版 forge-like 安装。
   * @param filesDir 真实 app filesDir（定位 JDK / fonts.conf / bootstrapper），沙箱场景必须显式传。
   */
  static async install(
    profile: ForgelikeProfile, mcDir: string, filesDir: string,
    callback?: ModLoaderInstallCallback
  ): Promise<ModLoaderInstallResult> {
    const versionId = profile.versionId;
    const installerPath = mcDir + '/' + profile.artifactId + '-installer.jar';
    const installerXmxMb = ForgelikeInstaller.resolveInstallerXmxMb();

    // 自动匹配 JDK：从已安装集里挑能满足 requiredJdkMajor 的最低 JDK（复用游戏 JDK 同套逻辑）。
    // 例：NeoForge 1.21.6 需 ≥21，设备装了 17+25 → 选 25（NeoForge 官方："任意更高 JDK 均可"）。
    let installed = installedJdkMajors(filesDir);
    let chosenMajor = pickInstalledJdkMajor(profile.requiredJdkMajor, installed);
    let installerJdk = chosenMajor > 0 ? String(chosenMajor) : String(profile.requiredJdkMajor);
    AppLogger.info(TAG, `install start: ${profile.loaderName} ${profile.artifactVersion} mc=${profile.gameVersion} requiredJdk=${profile.requiredJdkMajor} installed=[${installed.join(',')}] chosenJdk=${installerJdk} xmx=${installerXmxMb} mcDir=${mcDir} filesDir=${filesDir}`, LOG_DOMAIN_MODLOADER);

    // 前置：所选 JDK 运行时就绪（没有任一可用 JDK 时给出明确"需安装"提示）
    if (chosenMajor === 0) {
      let jdkErr = '安装 ' + profile.loaderName + ' 需要 JDK ' + profile.requiredJdkMajor
        + ' 或更高（如 25）。当前已安装: ' + (installed.length > 0 ? installed.join(', ') : '无')
        + '。\n请先在下载页安装 JDK ' + profile.requiredJdkMajor + ' 再重试。';
      AppLogger.error(TAG, `no compatible JDK: required=${profile.requiredJdkMajor} installed=[${installed.join(',')}]`, null, LOG_DOMAIN_MODLOADER);
      ForgelikeInstaller.report(callback, 'error', 0, 0, jdkErr);
      return { success: false, versionId: versionId, error: jdkErr };
    }
    let jdkErr = ForgelikeInstaller.ensureJdkRuntimeReady(filesDir, installerJdk);
    if (jdkErr.length > 0) {
      AppLogger.error(TAG, `JDK not ready: ${jdkErr}`, null, LOG_DOMAIN_MODLOADER);
      ForgelikeInstaller.report(callback, 'error', 0, 0, jdkErr);
      return { success: false, versionId: versionId, error: jdkErr };
    }

    // 已完整安装 → 跳过（必须含运行时必需 jar：universal + patched client，否则视为不完整、重装）
    let existing = ForgelikeInstaller.findExistingVersionDir(mcDir, profile);
    if (existing) {
      let jsonOk = ForgelikeInstaller.validateVersionJson(mcDir + '/versions/' + existing + '/' + existing + '.json');
      let runtimeMissing = ForgelikeInstaller.missingRuntimeLoaderJars(mcDir, profile);
      if (jsonOk.ok && runtimeMissing.length === 0) {
        ForgelikeInstaller.report(callback, 'done', 8, 8, profile.loaderName + ' ' + profile.loaderVersion + ' 已安装，无需重复安装。');
        return { success: true, versionId: existing };
      }
      AppLogger.warn(TAG, `Existing ${profile.loaderName} install incomplete (runtimeMissing=[${runtimeMissing.join(',')}]), reinstalling: ${existing}`, null, LOG_DOMAIN_MODLOADER);
    }

    try {
      // Step 1: 下载 installer（多源 NAPI + sha1 + ZIP 头校验）
      ForgelikeInstaller.report(callback, 'downloading_installer', 0, 8, '下载 ' + profile.loaderName + ' 安装器...');
      let downloadErrors: string[] = [];
      let mgr = DownloadManager.instance();
      let expectedSha1 = '';
      // 2026-07-30：`.sha1` 与 jar 同目录同源，逐源探测能顺带告诉我们**哪个源真的有这个工件**。
      //   真机实测（26.2.0.40-beta）：BMCLAPI 对该 beta 的 `.sha1` 与 jar 都是 404，而引擎仍把
      //   BMCLAPI 排在首位 → 先付一次 HEAD 404（1.37s，determineFileSize 的串行探测）再付一次
      //   GET 404（0.34s）才轮到真正可用的 maven.neoforged.net。把命中 `.sha1` 的源提到最前即可
      //   省掉这两次空转；顺序只是偏好，引擎的多源 fallback 行为不变。
      let shaProbe: InstallerSha1Probe = await probeInstallerSha1(profile.installerUrls);
      expectedSha1 = shaProbe.sha1;
      let installerUrls = preferSourceFirst(profile.installerUrls, shaProbe.sourceIndex);
      AppLogger.info(TAG, `installer download: urls=${installerUrls.length} url0=${installerUrls[0]} sha1=${expectedSha1.length === SHA1_HEX_LEN ? expectedSha1 : '(none)'}`, LOG_DOMAIN_MODLOADER);
      try { fs.unlinkSync(installerPath); } catch (e) { /* */ }
      // maxConnections=1：NeoForge installer 的镜像链 BMCLAPI 302→USTC(cernet.mirrors.ustc.edu.cn)
      // **不支持 Range**（Accept-Ranges 为空）且**并发限流（连续多请求返回 429）**。引擎默认多段
      // 并行（16）会被 USTC 立即 429 → 该源判失败，而唯一回退 maven.neoforged.net 在部分设备
      // 上 TLS 握手失败（SslFail）→ "no available sources"。安装器仅 ~6MB，单连接顺序拉取既匹配
      // 镜像能力（无 Range 多段也无意义）又避开 429，是这条链最稳的拉法。
      // maxConnections 由 profile 注入（NeoForge=1 规避镜像 429/no-Range；Forge=16 逼近带宽）。
      // 详见 ForgelikeProfile.installerMaxConnections 注释。
      let installerFile: DownloadFileSpec = {
        localPath: installerPath, urls: installerUrls, allowedRoot: mcDir,
        maxConnections: profile.installerMaxConnections,
      };
      if (expectedSha1.length === SHA1_HEX_LEN) {
        let chk: DownloadCheck = { sha1: expectedSha1 };
        installerFile.check = chk;
      }
      let installerSpec: DownloadTaskSpec = {
        name: profile.loaderName + ' 安装器 ' + profile.artifactVersion,
        files: [installerFile],
      };
      let downloaded = false;
      try {
        // ⚠️ 2026-07-30 修复「模组安装器长时间卡 0%」：这里原来是无参 `createAndWait(installerSpec)`，
        //   整个安装器下载期间一次进度回调都没有。上面 report(..., 0, 8, ...) 是唯一一帧，
        //   ModloaderPhase 把它折成 0/8 = 0% → UI 真的**恒定停在 0%**。
        //   真机实测该阶段 184.1s（3.60MB / 19.5KB/s，BMCLAPI 无此 beta + 单连接 + 低速掐断），
        //   用户看到的就是三分多钟的 0%。补上字节级回调，让 UI 至少能反映真实进度与速度。
        await mgr.createAndWait(installerSpec, (v: DownloadTaskView): void => {
          let total = v.bytesTotal > 0 ? v.bytesTotal : 0;
          let frac = total > 0 ? v.bytesDone / total : 0;
          if (frac < 0) frac = 0;
          if (frac > 1) frac = 1;
          let doneMb = (v.bytesDone / 1048576).toFixed(1);
          let totalMb = total > 0 ? (total / 1048576).toFixed(1) : '?';
          let speed = v.speedBps > 0 ? ' ' + formatSpeed(v.speedBps) : '';
          // current 用小数（0~1）落在 'downloading_installer' 这一步内，与 Step 3 的 `2 + frac` 同款；
          // ModloaderPhase 按 current/total 折算阶段内进度。
          ForgelikeInstaller.report(callback, 'downloading_installer', frac, 8,
            '下载 ' + profile.loaderName + ' 安装器 (' + doneMb + '/' + totalMb + ' MB)' + speed);
        });
        let postOk = await ForgelikeInstaller.checkInstallerArtifact(installerPath, expectedSha1);
        if (postOk.ok) {
          downloaded = true;
        } else {
          downloadErrors.push(postOk.reason);
          try { fs.unlinkSync(installerPath); } catch (e) { /* */ }
        }
      } catch (e) {
        downloadErrors.push((e as Error).message || String(e));
        try { fs.unlinkSync(installerPath); } catch (e2) { /* */ }
      }
      if (!downloaded) {
        let errMsg = '下载 ' + profile.loaderName + ' 安装器失败';
        if (downloadErrors.length > 0) errMsg += '\n' + downloadErrors.join('\n').substring(0, 600);
        AppLogger.error(TAG, `installer download failed: ${downloadErrors.join(' | ').substring(0, 600)}`, null, LOG_DOMAIN_MODLOADER);
        ForgelikeInstaller.report(callback, 'error', 0, 0, errMsg);
        return { success: false, versionId: versionId, error: errMsg };
      }
      AppLogger.info(TAG, `installer downloaded ok: ${installerPath}`, LOG_DOMAIN_MODLOADER);

      // Step 2: 解压
      ForgelikeInstaller.report(callback, 'extracting', 1, 8, '解压安装器...');
      let installerTempDir = mcDir + '/forge-install-temp';
      try { removeDirRecursive(installerTempDir); } catch (e) { /* */ }
      try { fs.mkdirSync(installerTempDir, true); } catch (e) { /* */ }
      await decompressFile(installerPath, installerTempDir);
      let installProfilePath = installerTempDir + '/install_profile.json';
      let versionJsonFromInstaller = installerTempDir + '/version.json';
      if (!fileExistsAndNonEmpty(installProfilePath)) {
        let errMsg = profile.loaderName + ' 安装器缺少 install_profile.json，安装器可能损坏';
        ForgelikeInstaller.report(callback, 'error', 0, 0, errMsg);
        return { success: false, versionId: versionId, error: errMsg };
      }

      // Step 3: 预下载 libraries（跳过加载器自身 generated 坐标）
      ForgelikeInstaller.report(callback, 'pre_download_libs', 2, 8, '预下载 ' + profile.loaderName + ' 依赖库...');
      let libDir = mcDir + '/libraries';
      try { fs.mkdirSync(libDir, true); } catch (e) { /* */ }
      try {
        let libEntries = extractLibrariesFromInstallerJson(
          installProfilePath, versionJsonFromInstaller, profile.artifactVersion, profile.loaderCoordPrefix);
        // OHOS 用自带 lwjgl-ohos，跳过原版 LWJGL/jinput/jutils
        let filtered: MavenLibEntry[] = [];
        for (let e of libEntries) {
          if (e.name.indexOf('org.lwjgl') === 0
            || e.name.indexOf('net.java.jinput') === 0
            || e.name.indexOf('net.java.jutils') === 0) continue;
          filtered.push(e);
        }
        AppLogger.info(TAG, `Extracted ${filtered.length} libs (from ${libEntries.length})`, LOG_DOMAIN_MODLOADER);
        // ⚠️ 2026-08-08：新版 forge-like 的 install_profile + version.json **一定**声明依赖库
        //   （真机 NeoForge 26.1.2.94 是 30 → 28）。为 0 只可能是 readJsonFile 静默返回 null
        //   （JSON 解析失败 / 文件缺失）。旧代码 `if (filtered.length > 0)` 会把这种情况当成
        //   "没什么要下的"直接跳过，一个库都不下也不报错，然后在 Step 7 抛出
        //   `processor 解析失败（缺 jar/Main-Class）` —— 把解析问题伪装成 processor 问题，
        //   排查方向被完全带偏。这里改为显式硬失败。
        if (filtered.length === 0) {
          throw new Error(profile.loaderName + ' 依赖库下载失败（install_profile.json / version.json 未解析出任何依赖库，'
            + '安装器可能损坏，请重试或换源）');
        }
        {
          let r1 = await downloadMavenLibraries(filtered, libDir,
            (done: number, total: number, name: string, fraction: number) => {
              // 字节加权优先（fraction >= 0）；否则回退文件计数。见 MavenLibsProgressCallback：
              // 最后一个大库（如 6.98MB 的 universal.jar）会独占几十秒，纯文件计数会静止。
              let frac = fraction >= 0 ? fraction : (total > 0 ? done / total : 0);
              ForgelikeInstaller.report(callback, 'pre_download_libs', 2 + frac, 8, '预下载依赖库 (' + done + '/' + total + '): ' + name);
            });
          if (r1.failed > 0) {
            // ⚠️ A-01 修复（2026-07-29）：重试只提交**失败项**，绝不重下已成功落地的库。
            //   旧实现把完整 `filtered` 再提交一遍，而加载器库多数不带 check（无 sha1/size），
            //   native 对"无 checker 且目标已存在"的提交会拒绝（N-01）→ 第二轮把第一轮的
            //   成功项逐个判失败 → r2.failed>0 恒成立 → 加载器安装永久失败且自我触发。
            let retryLibs = selectFailedLibs(filtered, r1);
            ForgelikeInstaller.report(callback, 'pre_download_libs', 2, 8, r1.failed + ' 个库下载失败，正在重试...');
            AppLogger.warn(TAG,
              `Pre-download libs: ${r1.failed} failed, retrying ${retryLibs.length} of ${filtered.length}`,
              null, LOG_DOMAIN_MODLOADER);
            // retryLibs 为空只可能是失败项全是"非法坐标"（buildSpecsForLibs 的 invalidNames，
            // 不在 libs 里能反查到名字）—— 那类重试也救不回来，直接沿用第一轮结论。
            let r2 = retryLibs.length > 0
              ? await downloadMavenLibraries(retryLibs, libDir,
                  (done: number, total: number, name: string, fraction: number) => {
                    let frac = fraction >= 0 ? fraction : (total > 0 ? done / total : 0);
                    ForgelikeInstaller.report(callback, 'pre_download_libs', 2 + frac, 8, '重试依赖库 (' + done + '/' + total + '): ' + name);
                  })
              : r1;
            if (r2.failed > 0) {
              let names = (r2.failedNames || []).slice(0, 5).join(', ');
              throw new Error(profile.loaderName + ' 依赖库下载失败（' + names + (r2.failed > 5 ? ' 等 ' + r2.failed + ' 个' : '') + '），请检查网络后重试');
            }
          }
        }
      } catch (e) {
        // ⚠️ 2026-08-08：这里原来是「消息不含『依赖库下载失败』就当 non-fatal 吞掉」。
        //   自实现 processors 之后，依赖库是**运行 processor 的前置**（processor 的 jar 和
        //   classpath 全在这批库里），任何一步失败都不可能"继续也没事"：
        //     · extractLibrariesFromInstallerJson 抛的 'install_profile artifact.path 不安全'
        //     · buildSpecsForLibs / 引擎抛的 NAPI 层异常
        //   都会被吞掉 → 一个库都没下 → Step 7 报 `processor 解析失败（缺 jar/Main-Class）`。
        //   真正 optional 的是 Step 4（mappings）与 Step 5（内置 maven），它们各自有 catch。
        //   故此处改为一律硬失败，并保留原有消息以免重复包装。
        let msg = (e as Error).message || String(e);
        AppLogger.error(TAG, `Pre-download libraries failed (fatal): ${msg}`, null, LOG_DOMAIN_MODLOADER);
        if (msg.indexOf('依赖库下载失败') >= 0) throw new Error(msg);
        throw new Error(profile.loaderName + ' 依赖库下载失败：' + msg);
      }

      // Step 4: 预下载 mappings
      ForgelikeInstaller.report(callback, 'pre_download_mappings', 3, 8, '预下载 Mappings...');
      try { await preDownloadMappings(installProfilePath, profile.gameVersion, libDir); }
      catch (e) { AppLogger.warn(TAG, `Pre-download mappings failed (non-fatal): ${(e as Error).message}`, null, LOG_DOMAIN_MODLOADER); }

      // Step 5: 提取内置 maven/
      ForgelikeInstaller.report(callback, 'extract_maven', 4, 8, '提取内置 Maven 库文件...');
      try { copyMavenToLibraries(installerTempDir + '/maven', libDir); }
      catch (e) { AppLogger.warn(TAG, `Extract maven failed (non-fatal): ${(e as Error).message}`, null, LOG_DOMAIN_MODLOADER); }

      // Step 6: 准备环境 + JIT 前置
      ForgelikeInstaller.report(callback, 'preparing', 5, 8, '准备安装环境...');
      let jitOk = false;
      try { jitOk = forgeNative().checkJitAvailable(); }
      catch (e) { AppLogger.warn(TAG, `checkJitAvailable failed: ${(e as Error).message}`, null, LOG_DOMAIN_MODLOADER); }
      if (!jitOk) {
        throw new Error('JIT 权限不可用，无法运行 ' + profile.loaderName + ' 安装器。\n'
          + '请在设备设置中启用“允许可写代码内存”（JIT）权限后重试。');
      }
      await ForgelikeInstaller.ensureRawFile('fonts.conf', filesDir + '/fonts.conf', true);
      ForgelikeInstaller.ensureRuntimePrerequisites(filesDir, installerJdk);
      let versionDirsBefore = ForgelikeInstaller.listVersionDirs(mcDir);

      // Step 6b: 写入 version.json。install_profile.json 的 "json" 字段指向 installer 内 version.json
      //   （已随 Step 2 解压到 installerTempDir）。这替代了原 bootstrapper(ClientInstall) 的"写版本"职责。
      let versionWriteErr = ForgelikeInstaller.writeVersionJson(
        profile, mcDir, installerTempDir, versionJsonFromInstaller);
      if (versionWriteErr.length > 0) {
        ForgelikeInstaller.report(callback, 'error', 0, 0, versionWriteErr);
        return { success: false, versionId: versionId, error: versionWriteErr };
      }

      // Step 7: **自实现** processors 执行（FCL/HMCL 思路）——抛开 bangbang93 bootstrapper。
      //   bootstrapper 同进程跑所有 processor，其 URLClassLoader 以系统类加载器为父，会把
      //   installer.jar 内 shaded 的第三方库（joptsimple/gson）泄漏进 processor 造成类加载冲突
      //   （NoSuchMethodError → 级联失败）。改为逐个 processor 用 runJavaProcessor fork 出**干净
      //   classpath（只含该 processor 声明的 jar）**的独立 JVM，与桌面端/FCL 完全一致，根除冲突。
      //   详见 ForgelikeProcessorRunner 文件头。
      ForgelikeInstaller.report(callback, 'installing', 5, 8, '运行 ' + profile.loaderName + ' 安装步骤（processors）...');
      let installerLogPath = mcDir + '/forge-installer.log';
      let installRc = -1;
      let procResult = await ForgelikeProcessorRunner.run(
        installProfilePath, installerTempDir, mcDir, libDir, filesDir,
        profile.gameVersion, installerJdk, installerXmxMb, profile.loaderName, callback);
      if (procResult.success) {
        installRc = 0;
        AppLogger.info(TAG, `${profile.loaderName} processors done: ran=${procResult.ranCount}`, LOG_DOMAIN_MODLOADER);
      } else {
        AppLogger.error(TAG, `${profile.loaderName} processors failed: ${procResult.error}`, null, LOG_DOMAIN_MODLOADER);
        ForgelikeInstaller.report(callback, 'error', 0, 0, procResult.error);
        return { success: false, versionId: versionId, error: procResult.error };
      }

      // Step 8: 检查结果（文件存在为主）
      ForgelikeInstaller.report(callback, 'checking', 6, 8, '检查安装结果...');
      let versionDirsAfter = ForgelikeInstaller.listVersionDirs(mcDir);
      let added = ForgelikeInstaller.computeAdded(versionDirsBefore, versionDirsAfter);
      let foundVersionId = ForgelikeInstaller.findVersionDirFromDiff(mcDir, profile, added);
      let newVersionDetected = foundVersionId !== null;
      if (!foundVersionId) {
        let exist = ForgelikeInstaller.findExistingVersionDir(mcDir, profile);
        if (exist) { foundVersionId = exist; newVersionDetected = true; }
      }
      if (!foundVersionId) foundVersionId = versionId;

      let jsonCheck = ForgelikeInstaller.validateVersionJson(mcDir + '/versions/' + foundVersionId + '/' + foundVersionId + '.json');
      let generated = ForgelikeInstaller.checkGeneratedArtifacts(mcDir, profile);
      // 运行时必需 jar（universal + patched client）—— fml 启动时从 libraryDirectory 发现，
      // 不在 version.json libraries，故启动前校验看不到，必须在安装期硬校验，杜绝"装成功但启动缺类"。
      let runtimeMissing = ForgelikeInstaller.missingRuntimeLoaderJars(mcDir, profile, procResult.patchedClientPath);
      // 安装成功标准：version.json 有效 + 检测到新版本目录 + 运行时必需 jar 齐全。
      let filesOk = jsonCheck.ok && runtimeMissing.length === 0;
      let success = filesOk && newVersionDetected;
      if (filesOk && !success) { success = true; }

      AppLogger.info(TAG,
        `Install check: loader=${profile.loaderName} rc=${installRc} newVer=${newVersionDetected ? 'yes' : 'no'} verId=${foundVersionId} jsonOk=${jsonCheck.ok ? 'yes' : 'no'} generated=${generated ? 'yes' : 'no'} runtimeMissing=[${runtimeMissing.join(',')}]`,
        LOG_DOMAIN_MODLOADER);

      // Step 9: 清理（保留 installer log）
      ForgelikeInstaller.report(callback, 'cleanup', 7, 8, '清理临时文件...');
      try { fs.unlinkSync(installerPath); } catch (e) { /* */ }
      try { removeDirRecursive(installerTempDir); } catch (e) { /* */ }

      if (success) {
        ForgelikeInstaller.report(callback, 'done', 8, 8, profile.loaderName + ' ' + profile.loaderVersion + ' 安装完成！');
        return { success: true, versionId: foundVersionId };
      }
      let errDetail = ForgelikeInstaller.extractErrorFromLog(installerLogPath);
      let headline = profile.loaderName + ' 安装失败';
      if (installRc <= -117) {
        headline = profile.loaderName + ' 安装失败（JVM 崩溃，疑似缺 JIT 权限）。\n'
          + '请前往：设置 → 应用和元服务 → AMCL → 权限 → 开启“允许可写代码内存”';
      } else if (!filesOk) {
        headline = profile.loaderName + ' 安装失败（产物不完整）';
      }
      let errMsg = headline
        + '\n- installRc: ' + installRc
        + '\n- 新版本目录: ' + (newVersionDetected ? 'yes' : 'no')
        + '\n- version.json: ' + (jsonCheck.ok ? 'yes' : 'no')
        + '\n- 生成产物: ' + (generated ? 'yes' : 'no')
        + (runtimeMissing.length > 0 ? '\n- 缺少运行时 jar: ' + runtimeMissing.join(', ') : '');
      if (errDetail.length > 0) errMsg += '\n' + errDetail;
      ForgelikeInstaller.report(callback, 'error', 8, 8, errMsg);
      AppLogger.error(TAG, `Install failed: ${errMsg}`, null, LOG_DOMAIN_MODLOADER);
      return { success: false, versionId: versionId, error: errMsg };
    } catch (e) {
      let msg = (e as Error).message || String(e);
      AppLogger.error(TAG, `${profile.loaderName} install failed: ${msg}`, e as Object, LOG_DOMAIN_MODLOADER);
      ForgelikeInstaller.report(callback, 'error', 0, 0, '安装失败: ' + msg, msg);
      return { success: false, versionId: versionId, error: msg };
    }
  }

  // ==================== 校验 / 工具 ====================

  private static report(cb: ModLoaderInstallCallback | undefined,
    phase: string, current: number, total: number, message: string, error?: string): void {
    if (cb) {
      let p: ModLoaderInstallProgress = { phase, current, total, message, error };
      cb(p);
    }
  }

  private static resolveInstallerXmxMb(): number {
    let recommended = FORGE_INSTALLER_XMX_FALLBACK_MB;
    try {
      let dev = forgeNative().getRecommendedXmx();
      if (dev > 0) recommended = dev;
    } catch (e) { /* fallback */ }
    let clamped = Math.max(FORGE_INSTALLER_XMX_MIN_MB, Math.min(FORGE_INSTALLER_XMX_MAX_MB, recommended));
    let rounded = Math.floor(clamped / FORGE_INSTALLER_XMX_STEP_MB) * FORGE_INSTALLER_XMX_STEP_MB;
    return rounded < FORGE_INSTALLER_XMX_MIN_MB ? FORGE_INSTALLER_XMX_MIN_MB : rounded;
  }

  private static ensureJdkRuntimeReady(filesDir: string, jdkVersion: string): string {
    let jdkRoot = filesDir + '/jdk/' + jdkVersion;
    // 与 jvmInit 实际依赖对齐（方案 B 后 fork 子进程走 JNI_CreateJavaVM，不再用 libjli.so）：
    //   release（下载完成标记）+ lib/server/libjvm.so（HotSpot）+ lib/modules（引导模块镜像，
    //   模块化 JDK 17/21/25 必需，jvmInit 缺它直接 fail）。
    let required = [
      jdkRoot + '/release',
      jdkRoot + '/lib/server/libjvm.so',
      jdkRoot + '/lib/modules',
    ];
    let missing: string[] = [];
    for (let p of required) {
      try { if (fs.statSync(p).size <= 0) missing.push(p); } catch (e) { missing.push(p); }
    }
    if (missing.length === 0) return '';
    return '安装前置检查失败：JDK ' + jdkVersion + ' 运行时未就绪。'
      + '\n请先在下载页安装 JDK ' + jdkVersion + ' 再重试。\n缺失: ' + missing.join(', ');
  }

  private static ensureRuntimePrerequisites(filesDir: string, jdkVersion: string): void {
    let jdkLibDir = filesDir + '/jdk/' + jdkVersion + '/lib';
    try { fs.mkdirSync(jdkLibDir, true); } catch (e) { /* */ }
    let fcDest = jdkLibDir + '/libfontconfig.so.1';
    try {
      if (fs.statSync(fcDest).size > FONTCONFIG_MIN_SIZE_BYTES) return;
    } catch (e) { /* 可选文件不存在，继续查找来源 */ }

    // Forge/NeoForge processors 是 headless 构建工具；jvmInit 对 fork child 也无条件注入
    // -Djava.awt.headless=true。fontconfig 仅作兼容性预载，不是安装前置条件。当前发布的
    // JDK 21/25 与部分 OHOS 系统本来就不提供该库，因此缺失时不能误导用户“重装 JDK”。
    let fcSrc = resolveFontconfigSource(filesDir);
    if (!fcSrc) {
      AppLogger.warn(TAG,
        '未找到可选的 libfontconfig.so；processor JVM 已启用 headless，继续安装（JDK ' + jdkVersion + '）',
        null, LOG_DOMAIN_MODLOADER);
      return;
    }

    try {
      fs.copyFileSync(fcSrc, fcDest);
      if (fs.statSync(fcDest).size <= FONTCONFIG_MIN_SIZE_BYTES) {
        try { fs.unlinkSync(fcDest); } catch (e) { /* */ }
        AppLogger.warn(TAG,
          '可选的 libfontconfig.so.1 复制后过小，已忽略并继续 headless 安装（JDK ' + jdkVersion + '）',
          null, LOG_DOMAIN_MODLOADER);
      }
    } catch (e) {
      try { fs.unlinkSync(fcDest); } catch (unlinkError) { /* */ }
      AppLogger.warn(TAG,
        '可选的 libfontconfig.so.1 部署失败，已忽略并继续 headless 安装（JDK ' + jdkVersion + '）',
        null, LOG_DOMAIN_MODLOADER);
    }
  }

  private static async ensureRawFile(rawName: string, destPath: string, forceRewrite: boolean): Promise<void> {
    if (forceRewrite) {
      try { fs.unlinkSync(destPath); } catch (e) { /* */ }
    } else {
      try {
        let st = fs.statSync(destPath);
        let minSize = rawName.endsWith('.jar') ? MIN_RAWFILE_SIZE : 1;
        if (st.size >= minSize) return;
      } catch (e) { /* */ }
    }
    let context = AppStorage.get<Context>('uiAbilityContext');
    if (!context) throw new Error('uiAbilityContext 未就绪');
    let data = await context.resourceManager.getRawFileContent(rawName);
    let f = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(f.fd, data.buffer); } finally { fs.closeSync(f); }
    if (fs.statSync(destPath).size <= 0) throw new Error(rawName + ' 写入后为空');
  }

  /**
   * 写入 version.json：install_profile.json 的 "json" 字段（如 "/version.json"）指向 installer 内
   * 的版本清单，已随 Step 2 解压到 installerTempDir。把它写到 versions/<id>/<id>.json 并修正 id。
   * 替代原 bootstrapper(ClientInstall) 的写版本职责。返回 '' 表示成功，否则为错误信息。
   */
  private static writeVersionJson(
    profile: ForgelikeProfile, mcDir: string, installerTempDir: string, versionJsonFromInstaller: string
  ): string {
    // 优先用 install_profile 的 "json" 指向；回退到解压出的 version.json
    let jsonSrc = versionJsonFromInstaller;
    try {
      let prof = JSON.parse(fs.readTextSync(installerTempDir + '/install_profile.json')) as Record<string, Object>;
      let jref = prof['json'] as string | undefined;
      if (jref && jref.length > 0) {
        let cleaned = jref.charAt(0) === '/' ? jref.substring(1) : jref;
        jsonSrc = installerTempDir + '/' + cleaned;
      }
    } catch (e) { /* 用回退 */ }
    if (!fileExistsAndNonEmpty(jsonSrc)) {
      return profile.loaderName + ' 安装失败：installer 内未找到 version.json (' + jsonSrc + ')';
    }
    let versionObj: Record<string, Object>;
    try {
      versionObj = JSON.parse(fs.readTextSync(jsonSrc)) as Record<string, Object>;
    } catch (e) {
      return profile.loaderName + ' 安装失败：version.json 解析失败: ' + (e as Error).message;
    }
    versionObj['id'] = profile.versionId;
    let versionDir = mcDir + '/versions/' + profile.versionId;
    try { fs.mkdirSync(versionDir, true); } catch (e) { /* exists */ }
    let dest = versionDir + '/' + profile.versionId + '.json';
    let f: fs.File | null = null;
    try {
      f = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(versionObj));
    } catch (e) {
      return profile.loaderName + ' 安装失败：写 version.json 失败: ' + (e as Error).message;
    } finally {
      if (f) { try { fs.closeSync(f); } catch (e2) { /* */ } }
    }
    if (!fileExistsAndNonEmpty(dest)) {
      return profile.loaderName + ' 安装失败：version.json 写入后不存在';
    }
    AppLogger.info(TAG, `Wrote version.json: ${dest}`, LOG_DOMAIN_MODLOADER);
    return '';
  }

  private static listVersionDirs(mcDir: string): string[] {
    let out: string[] = [];
    try {
      let entries = fs.listFileSync(mcDir + '/versions');
      for (let name of entries) {
        try { if (fs.statSync(mcDir + '/versions/' + name).isDirectory()) out.push(name); } catch (e) { /* */ }
      }
    } catch (e) { /* */ }
    out.sort();
    return out;
  }

  private static computeAdded(before: string[], after: string[]): string[] {
    let set = new Set<string>(before);
    let added: string[] = [];
    for (let n of after) { if (!set.has(n)) added.push(n); }
    return added;
  }

  private static findVersionDirFromDiff(mcDir: string, profile: ForgelikeProfile, added: string[]): string | null {
    let versionsDir = mcDir + '/versions';
    if (added.indexOf(profile.versionId) >= 0) {
      if (ForgelikeInstaller.validateVersionJson(versionsDir + '/' + profile.versionId + '/' + profile.versionId + '.json').ok) {
        return profile.versionId;
      }
    }
    for (let name of added) {
      if (name.indexOf(profile.versionDirToken) < 0) continue;
      if (name.indexOf(profile.gameVersion) < 0) continue;
      if (ForgelikeInstaller.validateVersionJson(versionsDir + '/' + name + '/' + name + '.json').ok) {
        return name;
      }
    }
    return null;
  }

  private static findExistingVersionDir(mcDir: string, profile: ForgelikeProfile): string | null {
    let versionsDir = mcDir + '/versions';
    if (ForgelikeInstaller.validateVersionJson(versionsDir + '/' + profile.versionId + '/' + profile.versionId + '.json').ok) {
      return profile.versionId;
    }
    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        if (name.indexOf(profile.versionDirToken) < 0) continue;
        if (name.indexOf(profile.gameVersion) < 0) continue;
        if (name.indexOf(profile.loaderVersion) < 0) continue;
        if (ForgelikeInstaller.validateVersionJson(versionsDir + '/' + name + '/' + name + '.json').ok) return name;
      }
    } catch (e) { /* */ }
    return null;
  }

  private static validateVersionJson(jsonPath: string): CheckResult {
    try {
      if (fs.statSync(jsonPath).size <= MIN_JSON_SIZE) return new CheckResult(false, 'json 过小');
      let data = JSON.parse(fs.readTextSync(jsonPath)) as Record<string, Object>;
      let id = data['id'] as string;
      if (!id || id.length === 0) return new CheckResult(false, 'json 缺 id');
      return new CheckResult(true, '');
    } catch (e) {
      return new CheckResult(false, (e as Error).message || String(e));
    }
  }

  /**
   * 关键 processor 产物目录扫描：SRG 重映射 client + 加载器 patched client。
   * 与 ForgeService 同口径（dir-scan），坐标按 profile 参数化。
   */
  private static checkGeneratedArtifacts(mcDir: string, profile: ForgelikeProfile): boolean {
    let libDir = mcDir + '/libraries';
    let minSize = MIN_GENERATED_ARTIFACT_SIZE;
    let srgFound = false;
    let mcClientDir = libDir + '/net/minecraft/client';
    try {
      for (let v of fs.listFileSync(mcClientDir)) {
        if (ForgelikeInstaller.fileBiggerThan(mcClientDir + '/' + v + '/client-' + v + '-srg.jar', minSize)) srgFound = true;
      }
    } catch (e) { /* */ }
    let loaderClientFound = false;
    let loaderDir = libDir + '/' + profile.groupPath;
    try {
      for (let v of fs.listFileSync(loaderDir)) {
        if (ForgelikeInstaller.fileBiggerThan(loaderDir + '/' + v + '/' + profile.artifactId + '-' + v + '-client.jar', minSize)) loaderClientFound = true;
      }
    } catch (e) { /* */ }
    AppLogger.info(TAG, `Generated dir-scan: srg=${srgFound ? 'y' : 'n'} loaderClient=${loaderClientFound ? 'y' : 'n'}`, LOG_DOMAIN_MODLOADER);
    return srgFound && loaderClientFound;
  }

  private static fileBiggerThan(path: string, minSize: number): boolean {
    try { return fs.statSync(path).size > minSize; } catch (e) { return false; }
  }

  /**
   * 启动期 fml 会从 libraryDirectory（按 --fml.neoForgeVersion）发现并加载的【运行时必需】加载器 jar：
   *   · <artifactId>-<ver>-universal.jar —— 加载器 mod 代码（net.neoforged.neoforge.* 等），**下载**而来，
   *     坐标稳定（后缀 -universal.jar），由 profile.runtimeRequiredJarSuffixes 驱动校验；
   *   · patched MC client —— **生成**而来，坐标随版本/品牌变（26.x=net.neoforged:minecraft-client-patched /
   *     1.21.x=net.neoforged:neoforge:<ver>:client / Forge=net.minecraftforge:forge:<ver>:client），
   *     由 install_profile.data.PATCHED 权威决定。安装后用 runner 回传的 patchedClientPath 校验；
   *     已装快速校验路径（无 install_profile）则按纪元推断坐标（expectedPatchedClientPath）。
   * 这些 jar **不在 version.json libraries**（fml 自行发现），启动前的 version.json 完整性校验看不到，
   * 故必须在**安装期**显式校验，否则会出现"安装成功但启动 NoClassDefFound"的静默坑。
   * @param patchedClientPath install_profile.data.PATCHED 解析出的绝对路径（runner 回传）；空=按纪元推断。
   * 返回缺失项文件名数组（空=齐全）。
   */
  private static missingRuntimeLoaderJars(mcDir: string, profile: ForgelikeProfile, patchedClientPath: string = ''): string[] {
    let libDir = mcDir + '/libraries';
    let dir = libDir + '/' + profile.groupPath + '/' + profile.artifactVersion;
    let prefix = profile.artifactId + '-' + profile.artifactVersion;
    let missing: string[] = [];
    // 1) 稳定后缀（universal）——由 profile 注入。
    for (let suffix of profile.runtimeRequiredJarSuffixes) {
      if (!ForgelikeInstaller.fileBiggerThan(dir + '/' + prefix + suffix, MIN_GENERATED_ARTIFACT_SIZE)) {
        missing.push(prefix + suffix);
      }
    }
    // 2) patched MC client——坐标权威来自 install_profile.data.PATCHED（runner 回传）；否则按纪元推断。
    let patched = patchedClientPath.length > 0
      ? patchedClientPath
      : ForgelikeInstaller.expectedPatchedClientPath(libDir, profile);
    if (!ForgelikeInstaller.fileBiggerThan(patched, MIN_GENERATED_ARTIFACT_SIZE)) {
      missing.push(ForgelikeInstaller.baseName(patched));
    }
    return missing;
  }

  /**
   * 无 install_profile（已装快速校验）时按 MC 纪元推断 patched client jar 的预期绝对路径：
   *   · NeoForge + YEARLY（26.x）：net/neoforged/minecraft-client-patched/<ver>/minecraft-client-patched-<ver>.jar
   *   · 其余（NeoForge CLASSIC 1.20.2–1.21.x / Forge）：<groupPath>/<ver>/<artifactId>-<ver>-client.jar
   * 与 install_profile.data.PATCHED 的实际坐标一致（权威路径优先用 runner 回传值）。
   */
  private static expectedPatchedClientPath(libDir: string, profile: ForgelikeProfile): string {
    let ver = profile.artifactVersion;
    if (profile.loaderName === 'NeoForge' && detectMcEra(profile.gameVersion) === McEra.YEARLY) {
      return libDir + '/net/neoforged/minecraft-client-patched/' + ver + '/minecraft-client-patched-' + ver + '.jar';
    }
    return libDir + '/' + profile.groupPath + '/' + ver + '/' + profile.artifactId + '-' + ver + '-client.jar';
  }

  private static baseName(path: string): string {
    let i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  private static isLikelyZipArchive(path: string): boolean {
    try {
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let buf = new ArrayBuffer(4);
        if (fs.readSync(file.fd, buf) < 4) return false;
        let b = new Uint8Array(buf, 0, 4);
        return b[0] === 0x50 && b[1] === 0x4b &&
          ((b[2] === 0x03 && b[3] === 0x04) || (b[2] === 0x05 && b[3] === 0x06) || (b[2] === 0x07 && b[3] === 0x08));
      } finally { fs.closeSync(file); }
    } catch (e) { return false; }
  }

  /**
   * `.sha1` 侧车探测与源偏好已提到 ForgeInstallerUtils（`probeInstallerSha1` /
   * `preferSourceFirst`），供新旧两条 Forge 分支共用 —— 旧版分支此前是「串行 + 默认 30s +
   * 抛异常」的另一套实现，慢且会把"拿不到 sha1"升级成安装失败。
   */

  private static async checkInstallerArtifact(installerPath: string, expectedSha1: string): Promise<CheckResult> {
    let size = 0;
    try { size = fs.statSync(installerPath).size; } catch (e) { return new CheckResult(false, 'installer 不存在'); }
    if (size <= MIN_JAR_SIZE) return new CheckResult(false, 'installer 过小: ' + size);
    if (!ForgelikeInstaller.isLikelyZipArchive(installerPath)) return new CheckResult(false, 'installer 文件头非 ZIP/JAR');
    if (expectedSha1.length !== SHA1_HEX_LEN) return new CheckResult(true, ''); // 无 sha1 → 仅 ZIP 头校验
    let actual = await computeFileSha1(installerPath);
    if (actual !== expectedSha1) return new CheckResult(false, 'installer SHA1 不匹配');
    return new CheckResult(true, '');
  }

  private static extractErrorFromLog(logPath: string): string {
    try {
      let lines = fs.readTextSync(logPath).split('\n');
      let errors: string[] = [];
      for (let line of lines) {
        let t = line.trim();
        if (t.indexOf('ERROR') >= 0 || t.indexOf('FAILED') >= 0 || t.indexOf('Exception') >= 0
          || t.indexOf('not found') >= 0 || t.indexOf('Cannot') >= 0) errors.push(t);
      }
      return errors.slice(-5).join('\n').substring(0, 500);
    } catch (e) { return ''; }
  }
}

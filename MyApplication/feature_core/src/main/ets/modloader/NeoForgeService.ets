/**
 * NeoForgeService.ets — NeoForge 模组加载器安装/管理服务
 *
 * 与 Fabric/Forge **平级**的独立 IModLoaderService；安装走共享引擎 ForgelikeInstaller
 * （Forge 与 NeoForge 安装器同构，见 docs/adaptation/NeoForge适配方案.md §0）。NeoForge 全是
 * 新版流程（无旧版直解压分支）。
 *
 * 版本号方案（NeoForge 官方，按 MC 纪元分两套）：
 *   · CLASSIC（MC 1.x.y）：NeoForge `<minor>.<patch>.<build>`（三段）↔ MC `1.<minor>[.<patch>]`
 *     （省去 MC 前导 1；patch=0 对应无 patch 的 MC，如 21.0.x ↔ 1.21）。仅支持 MC ≥ 1.20.2。
 *   · YEARLY（MC YY.D[.H]，2026 新纪元）：NeoForge `<YY>.<D>.<H>.<build>`（四段）↔ MC `YY.D[.H]`
 *     （H=0 对应无 hotfix 的 drop，如 26.2.0.x ↔ 26.2；26.1.2.x ↔ 26.1.2）。YEARLY 全支持。
 *   实测 maven-metadata：CLASSIC=三段（21.11.42 / 20.2.12-beta），YEARLY=四段
 *   （26.1.2.76 / 26.2.0.7-beta），段数即纪元判据。
 *
 * 端点：官方 maven.neoforged.net + BMCLAPI 镜像（多源回退）。
 * 版本目录命名：`<gameVersion>-neoforge-<loaderVersion>`（与 detectLoaderFromId 一致）。
 */

import {
  ModLoaderType, ModLoaderVersion,
  ModLoaderInstallCallback, ModLoaderInstallResult, IModLoaderService,
} from './ModLoaderTypes';
import { ForgelikeInstaller, ForgelikeProfile } from './ForgelikeInstaller';
import { fetchMergedMavenVersions } from './MavenUtils';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BMCLAPI_BASE } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';
import { detectMcEra, McEra, parseMcVersionParts } from 'commons';
import { requiredJdkMajorForMc } from 'commons';

const TAG = 'NeoForgeService';


const NEOFORGE_MAVEN = 'https://maven.neoforged.net/releases';
const NEOFORGE_GROUP_PATH = 'net/neoforged/neoforge';
const NEOFORGE_METADATA_URL = NEOFORGE_MAVEN + '/' + NEOFORGE_GROUP_PATH + '/maven-metadata.xml';
const BMCLAPI_NEOFORGE_METADATA_URL = BMCLAPI_BASE + '/maven/' + NEOFORGE_GROUP_PATH + '/maven-metadata.xml';

export interface NeoForgeVersionIdInfo {
  loaderVersion: string;
  gameVersion: string;
}

export class NeoForgeService implements IModLoaderService {
  private cachedVersions: string[] | null = null;

  async getSupportedGameVersions(): Promise<string[]> {
    let versions = await this.getAllNeoForgeVersions();
    let games: string[] = [];
    for (let v of versions) {
      let gv = NeoForgeService.neoVersionToGameVersion(v);
      if (gv.length > 0 && games.indexOf(gv) < 0) games.push(gv);
    }
    return games;
  }

  async getLoaderVersions(gameVersion: string): Promise<ModLoaderVersion[]> {
    let prefix = NeoForgeService.gameVersionToNeoPrefix(gameVersion);
    if (prefix.length === 0) {
      // 不受支持的 MC 版本（< 1.20.2 或无法解析）→ 空列表
      return [];
    }
    let versions = await this.getAllNeoForgeVersions();
    let result: ModLoaderVersion[] = [];
    for (let v of versions) {
      if (v.indexOf(prefix) !== 0) continue;
      let mlv: ModLoaderVersion = {
        loader: ModLoaderType.NEOFORGE,
        loaderVersion: v,
        gameVersion: gameVersion,
        stable: v.indexOf('-beta') < 0 && v.indexOf('-alpha') < 0 && v.indexOf('-rc') < 0,
        displayName: 'NeoForge ' + v,
      };
      result.push(mlv);
    }
    result.sort((a: ModLoaderVersion, b: ModLoaderVersion) =>
      NeoForgeService.compareNeoVersion(b.loaderVersion, a.loaderVersion));
    AppLogger.info(TAG, `getLoaderVersions: ${gameVersion} prefix=${prefix} → ${result.length}`, LOG_DOMAIN_MODLOADER);
    return result;
  }

  async install(
    gameVersion: string, loaderVersion: string,
    mcDir: string, callback?: ModLoaderInstallCallback,
    filesDirOverride?: string
  ): Promise<ModLoaderInstallResult> {
    let filesDir = filesDirOverride !== undefined && filesDirOverride.length > 0
      ? filesDirOverride
      : mcDir.substring(0, mcDir.lastIndexOf('/'));
    // 2026-07-30：补上 BMCLAPI 的 `/libraries` 端点。此前只有 `/maven` + 官方 maven 两个源，
    //   BMCLAPI 一旦没收录该版本（真机实测 26.2.0.40-beta 就是 404）就只剩国外单源可用，
    //   3.60MB 的安装器实测跑了 184.1s。`/libraries` 是 BMCLAPI 自己的库镜像、与 `/maven`
    //   命中/回源策略不同（已复核 `/libraries/net/neoforged/neoforge/21.1.9/...-installer.jar`
    //   返回 200），多一条国内候选。
    let installerRel = NEOFORGE_GROUP_PATH + '/' + loaderVersion + '/neoforge-' + loaderVersion + '-installer.jar';
    let installerUrls: string[] = [
      BMCLAPI_BASE + '/maven/' + installerRel,
      BMCLAPI_BASE + '/libraries/' + installerRel,
      NEOFORGE_MAVEN + '/' + installerRel,
    ];
    let profile: ForgelikeProfile = {
      loaderName: 'NeoForge',
      gameVersion: gameVersion,
      loaderVersion: loaderVersion,
      artifactVersion: loaderVersion,
      groupPath: NEOFORGE_GROUP_PATH,
      artifactId: 'neoforge',
      // 仅跳过【生成态】的 patched client 坐标（`:client`，由 binarypatcher 产出、maven 上不存在）。
      // 不能跳整个 `net.neoforged:neoforge:<ver>` —— 那会连**运行时必需的 universal jar**
      // （`:universal`，含 net.neoforged.neoforge.*，真实 maven 工件）一起漏下，导致启动期
      // NoClassDefFoundError: IMinecraftExtension。
      loaderCoordPrefix: 'net.neoforged:neoforge:' + loaderVersion + ':client',
      installerUrls: installerUrls,
      versionId: gameVersion + '-neoforge-' + loaderVersion,
      versionDirToken: 'neoforge',
      // 安装器 JDK 按 MC 纪元自动匹配（≤1.20.4→17 / 1.20.5+→21 / 26.1+→25），引擎再从设备已装集
      // 挑 ≥required 的最低版本。fork 子进程现走 jvmInit（含 sigchain），21/25 不再 init 期
      // SIGSEGV，故无需再固定 17。运行时 JDK 仍由 JdkManager.resolveLaunchJdk 启动时单独匹配。
      requiredJdkMajor: requiredJdkMajorForMc(gameVersion),
      // NeoForge 镜像链（BMCLAPI→USTC）不支持 Range + 并发限流 → 单连接顺序拉取最稳。
      installerMaxConnections: 1,
      // universal（含 net.neoforged.neoforge.*，fml 从 libraryDirectory 发现）不在 version.json，
      // 安装期硬校验（稳定后缀）。patched client（坐标随版本变：26.x=minecraft-client-patched /
      // 1.21.x=neoforge:client）由 install_profile.data.PATCHED 权威决定，引擎单独校验。
      runtimeRequiredJarSuffixes: ['-universal.jar'],
    };
    AppLogger.info(TAG, `NeoForge install: ${gameVersion}-neoforge-${loaderVersion} installerJdk=${profile.requiredJdkMajor}`, LOG_DOMAIN_MODLOADER);
    return ForgelikeInstaller.install(profile, mcDir, filesDir, callback);
  }

  async uninstall(versionId: string, mcDir: string): Promise<boolean> {
    let dir = mcDir + '/versions/' + versionId;
    try {
      try { fs.unlinkSync(dir + '/' + versionId + '.json'); } catch (e) { /* */ }
      try { fs.rmdirSync(dir); } catch (e) { /* */ }
      return true;
    } catch (e) { return false; }
  }

  /** 版本目录名解析：`<game>-neoforge-<loader>`。 */
  static parseNeoForgeVersionId(versionId: string): NeoForgeVersionIdInfo | null {
    let idx = versionId.indexOf('-neoforge-');
    if (idx <= 0) return null;
    let gameVersion = versionId.substring(0, idx);
    let loaderVersion = versionId.substring(idx + '-neoforge-'.length);
    if (gameVersion.length === 0 || loaderVersion.length === 0) return null;
    return { loaderVersion: loaderVersion, gameVersion: gameVersion };
  }

  // ==================== 内部 ====================

  private async getAllNeoForgeVersions(): Promise<string[]> {
    if (this.cachedVersions) return this.cachedVersions;
    let merged = await fetchMergedMavenVersions(
      [BMCLAPI_NEOFORGE_METADATA_URL, NEOFORGE_METADATA_URL], 'NeoForge');
    if (merged.length > 0) { this.cachedVersions = merged; return merged; }
    throw new Error('无法获取 NeoForge 版本列表');
  }

  /**
   * 三段（CLASSIC）或四段（YEARLY）的纯数字段；异常返回 null。
   * 复用 commons.parseMcVersionParts 统一“剥 -beta/+snapshot 后缀 + 逐段转数字”逻辑，
   * 仅在其上加 NeoForge 特有的“必须 3 或 4 段”约束。
   */
  private static numericParts(neoVersion: string): number[] | null {
    let nums = parseMcVersionParts(neoVersion);
    if (nums === null) return null;
    if (nums.length < 3 || nums.length > 4) return null;  // 仅 3（CLASSIC）/ 4（YEARLY）段
    return nums;
  }

  /**
   * NeoForge 版本 → MC 版本：
   *   · 四段 YY.D.H.build（YY≥22）→ MC YY.D[.H]（H=0 省略）。YEARLY 全支持。
   *   · 三段 minor.patch.build → MC 1.minor[.patch]（patch=0 省略）。仅 ≥1.20.2。
   * 注：NeoForge 版本号首段是 MC minor（如 21）而非 "1"，故不能直接用 detectMcEra 判纪元，
   *     改以段数区分（四段=YEARLY，三段=CLASSIC）。
   */
  private static neoVersionToGameVersion(neoVersion: string): string {
    let nums = NeoForgeService.numericParts(neoVersion);
    if (nums === null) return '';
    if (nums.length === 4) {
      // YEARLY（新纪元）
      let yy = nums[0];
      if (yy < 22) return '';   // 四段但首段非年份 → 异常，跳过
      let d = nums[1];
      let h = nums[2];
      return h === 0 ? (yy + '.' + d) : (yy + '.' + d + '.' + h);
    }
    // CLASSIC（三段）
    let minor = nums[0];
    let patch = nums[1];
    if (!NeoForgeService.isSupportedMc(minor, patch)) return '';
    return patch === 0 ? ('1.' + minor) : ('1.' + minor + '.' + patch);
  }

  /**
   * MC 版本 → NeoForge 版本前缀：
   *   · CLASSIC 1.minor[.patch] → "minor.patch."（无 patch → "minor.0."）。仅 ≥1.20.2。
   *   · YEARLY YY.D[.H] → "YY.D.H."（无 H → "YY.D.0."）。
   * 纪元判定复用 commons.detectMcEra（SSOT），版本拆段复用 commons.parseMcVersionParts。
   * 不支持 / UNKNOWN（快照等）返回 ''。
   */
  private static gameVersionToNeoPrefix(gameVersion: string): string {
    let parts = parseMcVersionParts(gameVersion);
    if (parts === null || parts.length < 2) return '';
    let era = detectMcEra(gameVersion);
    if (era === McEra.YEARLY) {
      // parts = [YY, D, H?]
      let yy = parts[0];
      let d = parts[1];
      let h = parts.length >= 3 ? parts[2] : 0;
      return yy + '.' + d + '.' + h + '.';
    }
    if (era === McEra.CLASSIC) {
      // parts = [1, minor, patch?]
      let minor = parts[1];
      let patch = parts.length >= 3 ? parts[2] : 0;
      if (!NeoForgeService.isSupportedMc(minor, patch)) return '';
      return minor + '.' + patch + '.';
    }
    return '';  // UNKNOWN
  }

  /** 仅 CLASSIC 用：支持 MC ≥ 1.20.2（1.20.1 建议用 Forge）。YEARLY 纪元全支持，不走本判定。 */
  private static isSupportedMc(minor: number, patch: number): boolean {
    if (minor > 20) return true;
    if (minor === 20 && patch >= 2) return true;
    return false;
  }

  /** installer/运行时 JDK 大版本由 commons.requiredJdkMajorForMc 统一决定（见 install）。 */

  private static compareNeoVersion(a: string, b: string): number {
    let na = NeoForgeService.numericParts(a);
    let nb = NeoForgeService.numericParts(b);
    if (na === null && nb === null) return a < b ? -1 : (a > b ? 1 : 0);
    if (na === null) return -1;
    if (nb === null) return 1;
    let len = Math.max(na.length, nb.length);
    for (let i = 0; i < len; i++) {
      let x = i < na.length ? na[i] : 0;
      let y = i < nb.length ? nb[i] : 0;
      if (x !== y) return x > y ? 1 : -1;
    }
    // 数字段相同，按后缀（正式版 > beta/alpha/rc）
    let sa = a.indexOf('-') >= 0 ? 0 : 1;
    let sb = b.indexOf('-') >= 0 ? 0 : 1;
    return sa - sb;
  }
}

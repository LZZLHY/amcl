/**
 * FabricService.ets — Fabric 模组加载器安装/管理服务
 *
 * 基于 Fabric Meta API（https://meta.fabricmc.net/）实现：
 *   1. 获取 Fabric Loader 版本列表
 *   2. 获取指定 MC 版本 + Loader 版本的 profile JSON
 *   3. 下载 Fabric 专属 libraries（从 maven.fabricmc.net）
 *   4. 生成带 inheritsFrom 的 version.json
 *
 * Fabric 安装流程（纯 API 驱动，无需运行 installer jar）：
 *   Step 1: GET /v2/versions/loader/{game}/{loader}/profile/json → 获得完整 version.json
 *   Step 2: 解析 libraries 列表，下载所有依赖到 .minecraft/libraries/
 *   Step 3: 将 profile JSON 保存为 versions/{versionId}/{versionId}.json
 *
 * 版本 ID 格式：fabric-loader-{loaderVersion}-{gameVersion}
 * 例：fabric-loader-0.16.10-1.20.4
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ModLoaderType,
  ModLoaderVersion,
  ModLoaderInstallProgress,
  ModLoaderInstallCallback,
  ModLoaderInstallResult,
  IModLoaderService,
} from './ModLoaderTypes';
import {
  downloadMavenLibraries,
  selectFailedLibs,
  MavenLibEntry,
} from './MavenUtils';
import { BMCLAPI_BASE } from 'commons';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';
import { DownloadManager } from '../download/DownloadManager';

const TAG = LogTags.MOD_FABRIC;

// ============================================================
//  Fabric Meta API 地址
// ============================================================

const FABRIC_META_BASE = 'https://meta.fabricmc.net';
const BMCLAPI_FABRIC_META = BMCLAPI_BASE + '/fabric-meta';

// ============================================================
//  Fabric Meta API 响应接口
// ============================================================

interface FabricGameVersion {
  version: string;
  stable: boolean;
}

interface FabricLoaderVersionEntry {
  separator: string;
  build: number;
  maven: string;
  version: string;
  stable: boolean;
}

interface FabricLoaderForGame {
  loader: FabricLoaderVersionEntry;
}

interface FabricProfileLibrary {
  name: string;
  url?: string;
  md5?: string;
  sha1?: string;
  sha256?: string;
  sha512?: string;
  size?: number;
}

interface FabricProfileArguments {
  game: string[];
  jvm: string[];
}

interface FabricProfileJson {
  id: string;
  inheritsFrom: string;
  releaseTime: string;
  time: string;
  type: string;
  mainClass: string;
  arguments: FabricProfileArguments;
  libraries: FabricProfileLibrary[];
}

export interface FabricVersionIdInfo {
  loaderVersion: string;
  gameVersion: string;
}

// ============================================================
//  FabricService 实现
// ============================================================

export class FabricService implements IModLoaderService {
  private cachedGameVersions: string[] | null = null;
  private cachedLoaderVersions: Map<string, ModLoaderVersion[]> = new Map();

  /**
   * 获取 Fabric 支持的 MC 版本列表
   */
  async getSupportedGameVersions(): Promise<string[]> {
    if (this.cachedGameVersions) return this.cachedGameVersions;

    // Phase 9 (ARCH-1 闭环)：走 NAPI fetchText 多源 fallback
    let primaryUrl = BMCLAPI_FABRIC_META + '/v2/versions/game';
    let mirrorUrls = [FABRIC_META_BASE + '/v2/versions/game'];
    try {
      let json = await DownloadManager.instance().fetchText(primaryUrl, mirrorUrls);
      let versions: FabricGameVersion[] = JSON.parse(json) as FabricGameVersion[];
      let result: string[] = [];
      for (let v of versions) {
        result.push(v.version);
      }
      this.cachedGameVersions = result;
      AppLogger.info(TAG, `Fabric supported game versions: ${result.length}`, LOG_DOMAIN_MODLOADER);
      return result;
    } catch (e) {
      AppLogger.warn(TAG, 'Failed to fetch game versions', e, LOG_DOMAIN_MODLOADER);
      throw new Error('无法获取 Fabric 支持的游戏版本列表');
    }
  }

  /**
   * 获取指定 MC 版本可用的 Fabric Loader 版本列表
   */
  async getLoaderVersions(gameVersion: string): Promise<ModLoaderVersion[]> {
    let cached = this.cachedLoaderVersions.get(gameVersion);
    if (cached) return cached;

    // Phase 9 (ARCH-1 闭环)：走 NAPI fetchText 多源 fallback
    let primaryUrl = BMCLAPI_FABRIC_META + '/v2/versions/loader/' + gameVersion;
    let mirrorUrls = [FABRIC_META_BASE + '/v2/versions/loader/' + gameVersion];
    try {
      let json = await DownloadManager.instance().fetchText(primaryUrl, mirrorUrls);
      let entries: FabricLoaderForGame[] = JSON.parse(json) as FabricLoaderForGame[];
      let result: ModLoaderVersion[] = [];
      for (let entry of entries) {
        let mlv: ModLoaderVersion = {
          loader: ModLoaderType.FABRIC,
          loaderVersion: entry.loader.version,
          gameVersion: gameVersion,
          stable: entry.loader.stable,
          displayName: 'Fabric ' + entry.loader.version,
        };
        result.push(mlv);
      }
      this.cachedLoaderVersions.set(gameVersion, result);
      AppLogger.info(TAG, `Fabric loader versions for ${gameVersion}: ${result.length}`, LOG_DOMAIN_MODLOADER);
      return result;
    } catch (e) {
      AppLogger.warn(TAG, 'Failed to fetch loader versions', e, LOG_DOMAIN_MODLOADER);
      throw new Error('无法获取 Fabric Loader 版本列表 (MC ' + gameVersion + ')');
    }
  }

  /**
   * 安装 Fabric 到指定 MC 版本
   *
   * @param gameVersion MC 版本号（如 "1.20.4"）
   * @param loaderVersion Fabric Loader 版本号（如 "0.16.10"）
   * @param mcDir .minecraft 根目录
   * @param callback 进度回调
   * @param filesDirOverride 沙箱场景下的真实 filesDir (Fabric 内部不需要 filesDir,
   *   该参数仅为与 IModLoaderService 接口对齐, 保留无操作以备未来扩展)
   */
  async install(
    gameVersion: string,
    loaderVersion: string,
    mcDir: string,
    callback?: ModLoaderInstallCallback,
    filesDirOverride?: string
  ): Promise<ModLoaderInstallResult> {
    // filesDirOverride: Fabric 安装链路无 JDK 等用户级资源依赖, 无需消费此参数.
    void filesDirOverride;
    let versionId = 'fabric-loader-' + loaderVersion + '-' + gameVersion;

    try {
      // Step 1: 获取 profile JSON
      this.reportProgress(callback, 'downloading_profile', 0, 3,
        '获取 Fabric 配置文件...');

      let profileJson = await this.fetchProfileJson(gameVersion, loaderVersion);
      AppLogger.info(TAG, `Got Fabric profile: id=${profileJson.id} mainClass=${profileJson.mainClass} libs=${profileJson.libraries.length}`, LOG_DOMAIN_MODLOADER);

      // Step 2: 下载 Fabric libraries
      this.reportProgress(callback, 'downloading_libraries', 1, 3,
        '下载 Fabric 依赖库 (0/' + profileJson.libraries.length + ')...');

      let libDir = mcDir + '/libraries';
      try { fs.mkdirSync(libDir, true); } catch (e) { /* exists */ }

      let libs: MavenLibEntry[] = [];
      for (let lib of profileJson.libraries) {
        let entry: MavenLibEntry = { name: lib.name, url: lib.url };
        // ⚠️ A-03 修复（2026-07-29）：Fabric Meta 的 profile.libraries 会给出 sha1/size，
        //   旧实现只透传 {name, url} 把它们丢掉了。后果有两条：
        //   ① 引擎对这些库零校验（无 checker 时 FileChecker 整体被跳过）；
        //   ② 全部 Fabric 库都成了 no-check spec，给第二个 MC 版本装 Fabric 时共享库
        //      已在磁盘上，逐个撞 N-01 的提交拒绝。
        //   下游 buildSpecForLib 自己会用 isValidSha1 / size>0 过滤，这里原样带上即可。
        if (lib.sha1 !== undefined) entry.sha1 = lib.sha1;
        if (lib.size !== undefined) entry.size = lib.size;
        libs.push(entry);
      }

      let dlResult = await downloadMavenLibraries(libs, libDir,
        (done: number, total: number, name: string, fraction: number) => {
          // Fabric 的阶段进度是固定的 1/3，字节比例只用于文案（让"卡住"的观感有个真实读数）。
          let pct = fraction >= 0 ? ', ' + Math.round(fraction * 100) + '%' : '';
          this.reportProgress(callback, 'downloading_libraries', 1, 3,
            '下载依赖库 (' + done + '/' + total + pct + ') ' + name);
        });

      if (dlResult.failed > 0) {
        // ⚠️ A-02 修复（2026-07-29）：库下载失败**必须**让安装失败。
        //   旧实现只 warn 并注释"部分库可能是可选的" —— 对 Fabric 不成立：
        //   profile.libraries 全是 classpath 必需项（fabric-loader / intermediary /
        //   asm / sponge-mixin）。旧行为会写出 version.json 并 return success=true，
        //   产出一个"已安装"但 libraries 里 0 个 jar 的版本，启动时
        //   ClassNotFoundException: net.fabricmc.loader.impl.launch.knot.KnotClient。
        //   先只重试失败项（A-01 同款），仍失败才判定安装失败。
        let retryLibs = selectFailedLibs(libs, dlResult);
        AppLogger.warn(TAG,
          `Fabric libs: ${dlResult.failed}/${libs.length} failed, retrying ${retryLibs.length}`,
          null, LOG_DOMAIN_MODLOADER);
        this.reportProgress(callback, 'downloading_libraries', 1, 3,
          dlResult.failed + ' 个依赖库下载失败，正在重试...');
        let retry = retryLibs.length > 0
          ? await downloadMavenLibraries(retryLibs, libDir,
              (done: number, total: number, name: string, fraction: number) => {
                let pct = fraction >= 0 ? ', ' + Math.round(fraction * 100) + '%' : '';
                this.reportProgress(callback, 'downloading_libraries', 1, 3,
                  '重试依赖库 (' + done + '/' + total + pct + ') ' + name);
              })
          : dlResult;
        if (retry.failed > 0) {
          let names = (retry.failedNames || []).slice(0, 5).join(', ');
          throw new Error('Fabric 依赖库下载失败（' + names
            + (retry.failed > 5 ? ' 等 ' + retry.failed + ' 个' : '') + '），请检查网络后重试');
        }
      }

      // Step 3: 保存 version.json
      this.reportProgress(callback, 'generating_json', 2, 3,
        '生成版本配置文件...');

      let versionDir = mcDir + '/versions/' + versionId;
      try { fs.mkdirSync(versionDir, true); } catch (e) { /* exists */ }

      let jsonPath = versionDir + '/' + versionId + '.json';
      let jsonContent = JSON.stringify(profileJson, null, 2);
      let file = fs.openSync(jsonPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, jsonContent);
      } finally {
        fs.closeSync(file);
      }

      AppLogger.info(TAG, `Fabric installed: ${versionId} (${jsonContent.length} bytes)`, LOG_DOMAIN_MODLOADER);

      // 完成
      this.reportProgress(callback, 'done', 3, 3,
        'Fabric ' + loaderVersion + ' 安装完成');

      let result: ModLoaderInstallResult = {
        success: true,
        versionId: versionId,
      };
      return result;

    } catch (e) {
      let errMsg = (e as Error).message || String(e);
      AppLogger.error(TAG, 'Fabric install failed', e, LOG_DOMAIN_MODLOADER);

      this.reportProgress(callback, 'error', 0, 0,
        '安装失败: ' + errMsg, errMsg);

      let result: ModLoaderInstallResult = {
        success: false,
        versionId: versionId,
        error: errMsg,
      };
      return result;
    }
  }

  /**
   * 卸载 Fabric 版本（删除版本目录）
   */
  async uninstall(versionId: string, mcDir: string): Promise<boolean> {
    let versionDir = mcDir + '/versions/' + versionId;
    try {
      // 删除 json
      try { fs.unlinkSync(versionDir + '/' + versionId + '.json'); } catch (e) { /* ignore */ }
      // 删除 jar（如果有）
      try { fs.unlinkSync(versionDir + '/' + versionId + '.jar'); } catch (e) { /* ignore */ }
      // 删除目录
      try { fs.rmdirSync(versionDir); } catch (e) { /* ignore */ }
      AppLogger.info(TAG, `Uninstalled: ${versionId}`, LOG_DOMAIN_MODLOADER);
      return true;
    } catch (e) {
      AppLogger.error(TAG, 'Uninstall failed', e, LOG_DOMAIN_MODLOADER);
      return false;
    }
  }

  /**
   * 检查指定 MC 版本是否已安装 Fabric
   */
  getInstalledFabricVersions(mcDir: string): string[] {
    let versionsDir = mcDir + '/versions';
    let result: string[] = [];
    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        if (name.indexOf('fabric-loader-') === 0) {
          // 验证 json 文件存在
          let jsonPath = versionsDir + '/' + name + '/' + name + '.json';
          try {
            let stat = fs.statSync(jsonPath);
            if (stat.size > 0) {
              result.push(name);
            }
          } catch (e) { /* json missing */ }
        }
      }
    } catch (e) { /* versions dir missing */ }
    return result;
  }

  /**
   * 从版本 ID 解析 Fabric 信息
   * 格式: fabric-loader-{loaderVersion}-{gameVersion}
   */
  static parseFabricVersionId(versionId: string): FabricVersionIdInfo | null {
    let prefix = 'fabric-loader-';
    if (versionId.indexOf(prefix) !== 0) return null;

    let rest = versionId.substring(prefix.length);
    // rest = "0.16.10-1.20.4"
    // loader 版本和 game 版本都可能含 "."，用第一个 "-" 后跟数字的位置来分割
    // 简化：Fabric loader 版本格式是 x.y.z，MC 版本格式是 1.x.y
    // 所以找最后一个以 "1." 开头的段作为 game version
    let dashIdx = rest.lastIndexOf('-1.');
    if (dashIdx < 0) {
      // 尝试旧版 MC（如 24w...）
      dashIdx = rest.indexOf('-');
    }
    if (dashIdx <= 0) return null;

    let loaderVersion = rest.substring(0, dashIdx);
    let gameVersion = rest.substring(dashIdx + 1);

    let info: FabricVersionIdInfo = { loaderVersion: loaderVersion, gameVersion: gameVersion };
    return info;
  }

  // ============================================================
  //  内部方法
  // ============================================================

  private async fetchProfileJson(gameVersion: string, loaderVersion: string): Promise<FabricProfileJson> {
    let path = '/v2/versions/loader/' + gameVersion + '/' + loaderVersion + '/profile/json';
    // Phase 9 (ARCH-1 闭环)：走 NAPI fetchText 多源 fallback
    let primaryUrl = BMCLAPI_FABRIC_META + path;
    let mirrorUrls = [FABRIC_META_BASE + path];
    try {
      let json = await DownloadManager.instance().fetchText(primaryUrl, mirrorUrls);
      let profile: FabricProfileJson = JSON.parse(json) as FabricProfileJson;
      return profile;
    } catch (e) {
      AppLogger.warn(TAG, 'Failed to fetch profile', e, LOG_DOMAIN_MODLOADER);
      throw new Error('无法获取 Fabric 配置文件');
    }
  }

  private reportProgress(callback: ModLoaderInstallCallback | undefined,
    phase: string, current: number, total: number, message: string, error?: string) {
    if (callback) {
      let progress: ModLoaderInstallProgress = {
        phase, current, total, message, error,
      };
      callback(progress);
    }
  }
}

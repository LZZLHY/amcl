/**
 * ModLoaderManager.ets — 模组加载器统一管理入口
 *
 * 统一管理所有模组加载器（Fabric / Forge / NeoForge / OptiFine / Quilt）。
 * 提供统一的安装、卸载、查询接口，内部根据类型分发到对应的 Service。
 *
 * 使用方式：
 *   let manager = new ModLoaderManager()
 *   let versions = await manager.getLoaderVersions(ModLoaderType.FABRIC, '1.20.4')
 *   let result = await manager.install(ModLoaderType.FABRIC, '1.20.4', '0.16.10', mcDir, callback)
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ModLoaderType,
  ModLoaderVersion,
  ModLoaderInstallCallback,
  ModLoaderInstallResult,
  InstalledModLoader,
} from './ModLoaderTypes';
import { FabricService } from './FabricService';
import { ForgeService } from './ForgeService';
import { NeoForgeService } from './NeoForgeService';

const TAG = 'ModLoaderManager';

export class ModLoaderManager {
  private fabricService: FabricService = new FabricService();
  private forgeService: ForgeService = new ForgeService();
  private neoForgeService: NeoForgeService = new NeoForgeService();
  // private optiFineService: OptiFineService = new OptiFineService();

  // ============================================================
  //  统一查询接口
  // ============================================================

  /**
   * 获取指定加载器支持的 MC 版本列表
   */
  async getSupportedGameVersions(loaderType: ModLoaderType): Promise<string[]> {
    switch (loaderType) {
      case ModLoaderType.FABRIC:
        return this.fabricService.getSupportedGameVersions();
      case ModLoaderType.FORGE:
        return this.forgeService.getSupportedGameVersions();
      case ModLoaderType.NEOFORGE:
        return this.neoForgeService.getSupportedGameVersions();
      default:
        throw new Error('暂不支持 ' + loaderType + ' 加载器');
    }
  }

  /**
   * 获取指定 MC 版本可用的加载器版本列表
   */
  async getLoaderVersions(loaderType: ModLoaderType, gameVersion: string): Promise<ModLoaderVersion[]> {
    switch (loaderType) {
      case ModLoaderType.FABRIC:
        return this.fabricService.getLoaderVersions(gameVersion);
      case ModLoaderType.FORGE:
        return this.forgeService.getLoaderVersions(gameVersion);
      case ModLoaderType.NEOFORGE:
        return this.neoForgeService.getLoaderVersions(gameVersion);
      default:
        throw new Error('暂不支持 ' + loaderType + ' 加载器');
    }
  }

  // ============================================================
  //  安装/卸载
  // ============================================================

  /**
   * 安装模组加载器
   *
   * @param filesDirOverride 沙箱场景显式传入真实 filesDir.
   *   当 mcDir = filesDir/forge-install-temp/<sid> 时, 必须传, 否则 ForgeService
   *   反推会得到错误的 forge-install-temp 路径, JDK / fonts.conf 找不到.
   *   不传时具体 Service 回退到 mcDir 反推 (旧行为 100% 兼容).
   */
  async install(
    loaderType: ModLoaderType,
    gameVersion: string,
    loaderVersion: string,
    mcDir: string,
    callback?: ModLoaderInstallCallback,
    filesDirOverride?: string
  ): Promise<ModLoaderInstallResult> {
    hilog.info(0x0000, TAG, 'Installing %{public}s %{public}s for MC %{public}s',
      loaderType, loaderVersion, gameVersion);

    switch (loaderType) {
      case ModLoaderType.FABRIC:
        return this.fabricService.install(gameVersion, loaderVersion, mcDir, callback, filesDirOverride);
      case ModLoaderType.FORGE:
        return this.forgeService.install(gameVersion, loaderVersion, mcDir, callback, filesDirOverride);
      case ModLoaderType.NEOFORGE:
        return this.neoForgeService.install(gameVersion, loaderVersion, mcDir, callback, filesDirOverride);
      default:
        let result: ModLoaderInstallResult = {
          success: false,
          versionId: '',
          error: '暂不支持 ' + loaderType + ' 加载器',
        };
        return result;
    }
  }

  /**
   * 卸载模组加载器版本
   */
  async uninstall(loaderType: ModLoaderType, versionId: string, mcDir: string): Promise<boolean> {
    hilog.info(0x0000, TAG, 'Uninstalling %{public}s: %{public}s', loaderType, versionId);

    switch (loaderType) {
      case ModLoaderType.FABRIC:
        return this.fabricService.uninstall(versionId, mcDir);
      case ModLoaderType.FORGE:
        return this.forgeService.uninstall(versionId, mcDir);
      case ModLoaderType.NEOFORGE:
        return this.neoForgeService.uninstall(versionId, mcDir);
      default:
        return false;
    }
  }

  // ============================================================
  //  已安装版本查询
  // ============================================================

  /**
   * 扫描 .minecraft/versions/ 目录，找出所有已安装的模组加载器版本
   */
  scanInstalledModLoaders(mcDir: string): InstalledModLoader[] {
    let result: InstalledModLoader[] = [];
    let versionsDir = mcDir + '/versions';

    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        let info = this.detectModLoader(name, versionsDir);
        if (info) {
          result.push(info);
        }
      }
    } catch (e) { /* versions dir missing */ }

    hilog.info(0x0000, TAG, 'Found %{public}d installed mod loaders', result.length);
    return result;
  }

  /**
   * 判断一个版本是否是模组加载器版本，并返回加载器信息
   */
  detectModLoader(versionId: string, versionsDir: string): InstalledModLoader | null {
    // Fabric: fabric-loader-{loaderVersion}-{gameVersion}
    let fabricInfo = FabricService.parseFabricVersionId(versionId);
    if (fabricInfo) {
      // 验证 json 文件存在
      let jsonPath = versionsDir + '/' + versionId + '/' + versionId + '.json';
      try {
        let stat = fs.statSync(jsonPath);
        if (stat.size > 0) {
          let info: InstalledModLoader = {
            type: ModLoaderType.FABRIC,
            loaderVersion: fabricInfo.loaderVersion,
            gameVersion: fabricInfo.gameVersion,
            versionId: versionId,
          };
          return info;
        }
      } catch (e) { /* json missing */ }
    }

    // NeoForge: {gameVersion}-neoforge-{loaderVersion}（先于 Forge，'neoforge' 含子串 'forge'）
    let neoInfo = NeoForgeService.parseNeoForgeVersionId(versionId);
    if (neoInfo) {
      let jsonPath = versionsDir + '/' + versionId + '/' + versionId + '.json';
      try {
        let stat = fs.statSync(jsonPath);
        if (stat.size > 0) {
          let info: InstalledModLoader = {
            type: ModLoaderType.NEOFORGE,
            loaderVersion: neoInfo.loaderVersion,
            gameVersion: neoInfo.gameVersion,
            versionId: versionId,
          };
          return info;
        }
      } catch (e) { /* json missing */ }
    }

    // Forge: {gameVersion}-forge-{loaderVersion}
    if (versionId.indexOf('-forge-') >= 0) {
      let parts = versionId.split('-forge-');
      if (parts.length === 2) {
        let jsonPath = versionsDir + '/' + versionId + '/' + versionId + '.json';
        try {
          let stat = fs.statSync(jsonPath);
          if (stat.size > 0) {
            let info: InstalledModLoader = {
              type: ModLoaderType.FORGE,
              loaderVersion: parts[1],
              gameVersion: parts[0],
              versionId: versionId,
            };
            return info;
          }
        } catch (e) { /* json missing */ }
      }
    }

    // 预留：NeoForge 检测
    // if (versionId.indexOf('neoforge-') === 0) { ... }

    // 预留：OptiFine 检测
    // if (versionId.indexOf('OptiFine') >= 0) { ... }

    return null;
  }

  /**
   * 获取当前支持的模组加载器类型列表
   */
  getSupportedLoaderTypes(): ModLoaderType[] {
    return [
      ModLoaderType.FABRIC,
      ModLoaderType.FORGE,
      ModLoaderType.NEOFORGE,
      // 未来添加：
      // ModLoaderType.OPTIFINE,
    ];
  }

  /**
   * 获取加载器的中文显示名
   */
  static getLoaderDisplayName(type: ModLoaderType): string {
    switch (type) {
      case ModLoaderType.FABRIC: return 'Fabric';
      case ModLoaderType.FORGE: return 'Forge';
      case ModLoaderType.NEOFORGE: return 'NeoForge';
      case ModLoaderType.OPTIFINE: return 'OptiFine';
      case ModLoaderType.QUILT: return 'Quilt';
      default: return type;
    }
  }
}

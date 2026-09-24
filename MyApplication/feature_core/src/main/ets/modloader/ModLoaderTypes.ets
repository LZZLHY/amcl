/**
 * ModLoaderTypes.ets — 模组加载器共用类型定义
 *
 * 所有模组加载器（Fabric / Forge / NeoForge / OptiFine）共用的接口和枚举。
 * 为未来扩展预留统一的抽象。
 */

// ============================================================
//  模组加载器类型枚举
// ============================================================

export enum ModLoaderType {
  FABRIC = 'fabric',
  FORGE = 'forge',
  NEOFORGE = 'neoforge',
  OPTIFINE = 'optifine',
  QUILT = 'quilt',
}

// ============================================================
//  模组加载器版本信息
// ============================================================

export interface ModLoaderVersion {
  loader: ModLoaderType;
  loaderVersion: string;     // 加载器自身版本号（如 "0.16.10"）
  gameVersion: string;       // 适配的 MC 版本（如 "1.20.4"）
  stable: boolean;           // 是否为稳定版
  displayName: string;       // 界面显示名（如 "Fabric 0.16.10"）
}

// ============================================================
//  安装进度回调
// ============================================================

export interface ModLoaderInstallProgress {
  phase: string;             // "downloading_profile" | "downloading_libraries" | "generating_json" | "done" | "error"
  current: number;           // 当前进度
  total: number;             // 总量
  message: string;           // 描述信息
  error?: string;            // 错误信息
}

export type ModLoaderInstallCallback = (progress: ModLoaderInstallProgress) => void;

// ============================================================
//  安装结果
// ============================================================

export interface ModLoaderInstallResult {
  success: boolean;
  versionId: string;         // 生成的版本 ID（如 "fabric-loader-0.16.10-1.20.4"）
  error?: string;
}

// ============================================================
//  已安装的模组加载器信息（从 version.json 中解析）
// ============================================================

export interface InstalledModLoader {
  type: ModLoaderType;
  loaderVersion: string;
  gameVersion: string;
  versionId: string;         // 版本目录名
}

// ============================================================
//  Maven 库定义（Fabric/Forge 的 libraries 格式）
// ============================================================

export interface MavenLibrary {
  name: string;              // Maven 坐标，如 "net.fabricmc:fabric-loader:0.16.10"
  url?: string;              // Maven 仓库 URL，如 "https://maven.fabricmc.net/"
  sha1?: string;
  sha256?: string;
  md5?: string;
  size?: number;
}

// ============================================================
//  模组加载器服务接口（所有加载器都要实现）
// ============================================================

export interface IModLoaderService {
  /** 获取该加载器支持的 MC 版本列表 */
  getSupportedGameVersions(): Promise<string[]>;

  /** 获取指定 MC 版本可用的加载器版本列表 */
  getLoaderVersions(gameVersion: string): Promise<ModLoaderVersion[]>;

  /** 安装加载器到指定 MC 版本.
   *  filesDirOverride: 当 mcDir 是临时沙箱(如 filesDir/forge-install-temp/<sid>)时,
   *    显式指定真实 filesDir 用于推导 JDK / fonts.conf 路径.
   *    不传时回退到 mcDir.substring(0, mcDir.lastIndexOf('/')) (旧行为 100% 兼容). */
  install(gameVersion: string, loaderVersion: string,
    mcDir: string, callback?: ModLoaderInstallCallback,
    filesDirOverride?: string): Promise<ModLoaderInstallResult>;

  /** 卸载（删除生成的版本目录） */
  uninstall(versionId: string, mcDir: string): Promise<boolean>;
}

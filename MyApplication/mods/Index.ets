/**
 * mods HAR 公共 API 入口（barrel）。
 * 三层架构 C 步：模组域。依赖 commons + feature_core，native-free。
 */
export * from './src/main/ets/ModTypes';
export * from './src/main/ets/VersionIdUtils';
export * from './src/main/ets/RemoteModRepository';
export * from './src/main/ets/ModrinthRepository';
export * from './src/main/ets/ModrinthUrls';
export * from './src/main/ets/CurseForgeRepository';
export * from './src/main/ets/CurseForgeUrls';
export * from './src/main/ets/ModSourceRouter';
export * from './src/main/ets/ModSourceProber';
export * from './src/main/ets/ModTranslation';
export * from './src/main/ets/ModDependencyResolver';
export * from './src/main/ets/ModSearchController';
export * from './src/main/ets/ModInstaller';
export * from './src/main/ets/InstalledLoaderResolver';
export * from './src/main/ets/ModpackManifest';
export * from './src/main/ets/ModpackSnapshot';
export * from './src/main/ets/ModpackPostProcessor';
export * from './src/main/ets/ModpackInstaller';
export * from './src/main/ets/ModpackInstallTask';
export * from './src/main/ets/LocalModScanner';
export * from './src/main/ets/InstalledModIndex';
export * from './src/main/ets/CurseForgeFingerprint';
export * from './src/main/ets/ResourceInstallTask';
export * from './src/main/ets/ModManifest';
export * from './src/main/ets/ModVersionRange';
export * from './src/main/ets/ModInstallService';
export * from './src/main/ets/ModInstallTask';
export * from './src/main/ets/ModInstallTransaction';
export * from './src/main/ets/ModUpdatePolicy';

// 显式消歧：以下名称在多个文件中重复 export（定义相同），显式指定来源以解决 export * 歧义。
export { CacheEnabledProvider } from './src/main/ets/ModrinthRepository';
export { MCIM_CDN_PREFIX } from './src/main/ets/ModrinthUrls';


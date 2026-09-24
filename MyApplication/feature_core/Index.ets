/**
 * feature_core HAR 公共 API 入口（barrel）。
 *
 * 三层架构重构（C 步）：核心域 download + version + modloader 合并为一个 HAR
 * （三者循环依赖，HAR 禁环，故合并；环在模块内部消化）。消费方统一 `import { X } from 'feature_core'`。
 * 依赖 commons；native 经 DownloadNativeEngine 注入解耦（entry 注入 testNapi 实现）。
 */

// ---- download 域 ----
export * from './src/main/ets/download/DownloadManager';
export * from './src/main/ets/download/DownloadTask';
export * from './src/main/ets/download/DownloadTaskRegistry';
export * from './src/main/ets/download/UnifiedDownloadTask';
export * from './src/main/ets/download/DownloadHistory';
export * from './src/main/ets/download/SourceProber';
export * from './src/main/ets/download/NetworkDiagnostics';
export * from './src/main/ets/download/RelayClient';
export * from './src/main/ets/download/PhaseRunner';
export * from './src/main/ets/download/McDownloader';
export * from './src/main/ets/download/phases/DownloadFlowState';
export * from './src/main/ets/download/phases/PreparePhase';
export * from './src/main/ets/download/phases/ClientPhase';
export * from './src/main/ets/download/phases/LibrariesPhase';
export * from './src/main/ets/download/phases/AssetsPhase';
export * from './src/main/ets/download/phases/ModloaderPhase';
export * from './src/main/ets/download/phases/MergePhase';

// ---- version 域 ----
export * from './src/main/ets/version/McVersionService';
export * from './src/main/ets/version/McVersionTask';
export * from './src/main/ets/version/VersionParser';
export * from './src/main/ets/version/MinecraftLoggingConfig';
export * from './src/main/ets/version/VersionFileVerifier';
export * from './src/main/ets/version/VersionJsonMerger';
export * from './src/main/ets/version/VersionMetaService';
export * from './src/main/ets/version/MetadataCache';
export * from './src/main/ets/version/MetadataCacheStore';
export * from './src/main/ets/version/RepairTask';
export * from './src/main/ets/version/ForgeRepairTask';
export * from './src/main/ets/version/VersionOrdering';

// ---- modloader 域 ----
export * from './src/main/ets/modloader/ModLoaderTypes';
export * from './src/main/ets/modloader/ModLoaderManager';
export * from './src/main/ets/modloader/MavenUtils';
export * from './src/main/ets/modloader/MavenSpecBuilder';
export * from './src/main/ets/modloader/ForgeService';
export * from './src/main/ets/modloader/ForgeInstallerUtils';
export * from './src/main/ets/modloader/ForgelikeNative';
export * from './src/main/ets/modloader/ForgelikeInstaller';
export * from './src/main/ets/modloader/NeoForgeService';
export * from './src/main/ets/modloader/FabricService';

export * from './src/main/ets/download/RelayNativeBridge';

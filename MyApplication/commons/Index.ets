/**
 * commons HAR 公共 API 入口（barrel）。
 *
 * 三层架构重构（C 步）：公共能力层抽成独立 HAR。消费方统一 `import { X } from 'commons'`，
 * 不再用相对路径深入 commons 内部。新增公共文件后，记得在此 re-export。
 *
 * 约束：commons 无业务、无 native（AppLogger 经 NativeLogSink 注入解耦）、不依赖 features/products。
 */

// ---- common：常量 / 主题 / 图标 / 设备形态 ----
export * from './src/main/ets/common/Constants';
export * from './src/main/ets/common/DiagnosticPolicy';
export * from './src/main/ets/common/ChineseVariant';
export * from './src/main/ets/common/GameLanguages';
export * from './src/main/ets/common/Errors';
export * from './src/main/ets/common/IconCatalog';
export * from './src/main/ets/common/LogTags';
export * from './src/main/ets/common/ProductIdentity';
export * from './src/main/ets/common/RemoteImageCache';
export * from './src/main/ets/common/SheetSizes';
export * from './src/main/ets/common/Theme';
export * from './src/main/ets/common/device/DeviceProfile';
export * from './src/main/ets/common/DistributionPolicy';

// ---- utils：纯工具 ----
export * from './src/main/ets/utils/AppLogger';
export * from './src/main/ets/utils/Base64Util';
export * from './src/main/ets/utils/DiagnosticBundle';
export * from './src/main/ets/utils/ErrorFormat';
export * from './src/main/ets/utils/FileUtils';
export * from './src/main/ets/utils/FontconfigUtils';
export * from './src/main/ets/utils/ActivityLedger';
export * from './src/main/ets/utils/ActivityStorage';
export * from './src/main/ets/utils/EvidenceTypes';
export * from './src/main/ets/utils/EvidencePresentation';
export * from './src/main/ets/utils/SessionEvidence';
export * from './src/main/ets/utils/EvidenceIo';
export * from './src/main/ets/utils/EvidenceExportSnapshot';
export * from './src/main/ets/utils/EvidenceExcerpt';
export * from './src/main/ets/utils/SessionCapture';
export * from './src/main/ets/utils/SessionEnvironment';
export * from './src/main/ets/utils/SessionRetention';
export * from './src/main/ets/utils/GameLogPaths';
export * from './src/main/ets/utils/LogExport';
export * from './src/main/ets/utils/LogErrorSignal';
export * from './src/main/ets/utils/LogEvent';
export * from './src/main/ets/utils/LogExportBudget';
export * from './src/main/ets/utils/LogNoiseFilter';
export * from './src/main/ets/utils/McVersionUtils';
export * from './src/main/ets/utils/PathUtils';
export * from './src/main/ets/utils/Redact';
export * from './src/main/ets/utils/SandboxProbe';

export { ProcessPreferences } from './src/main/ets/utils/ProcessPreferences';
export { LaunchPreferenceSnapshot, LaunchPreferenceStore, LaunchPreferenceValue, ReadOnlyLaunchPreferences,
  GameLayoutCommitSink, GameLayoutLaunchPreferences, copyLaunchPreferenceSnapshot } from './src/main/ets/utils/PreferenceSnapshot';

export { createLaunchPreferenceStores } from './src/main/ets/utils/PreferenceSnapshot';

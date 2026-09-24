/**
 * feature_system HAR 公共 API 入口（barrel）。
 * 三层架构 C 步：系统/平台域。依赖 commons + feature_core；native 经 SystemNativeBridge 注入。
 */
export * from './src/main/ets/SystemNativeBridge';
export * from './src/main/ets/GameStorage';
export * from './src/main/ets/HapticUtil';
export * from './src/main/ets/PreferenceManager';
export * from './src/main/ets/StorageProbe';
export * from './src/main/ets/PhoneStorageProbe';
export * from './src/main/ets/VulkanCapability';
export * from './src/main/ets/AlbumSaver';

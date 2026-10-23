/**
 * update HAR 公共 API 入口。三层架构 C 步：更新检查域。依赖 commons + feature_core。
 */
export * from './src/main/ets/UpdateChecker';
export * from './src/main/ets/AppUpdatePolicy';
export * from './src/main/ets/ChangelogTypes';
export * from './src/main/ets/ChangelogService';
export * from './src/main/ets/SideloadUpdateModels';
export * from './src/main/ets/GitHubUpdateAssetResolver';
export * from './src/main/ets/SideloadTransactionPolicy';

import { DownloadTaskRegistry, LocalVersionInventory, McVersionService, McVersionTask, UnifiedTaskView, ModLoaderManager, ModLoaderType } from 'feature_core';

import { RemoteVersion } from 'mods';

/** 返回真正提交的父任务与关联子任务。子任务可以在父安装完成后才取得队列身份。 */
export interface VersionCompanionTask {
  view: UnifiedTaskView;
  completion: Promise<void>;
}
export interface VersionInstallation {
  adapter: McVersionTask;
  completion?: Promise<void>;
  companion?: Promise<VersionCompanionTask>;
}

export interface VersionCompanionSelection {
  version: RemoteVersion;
  iconUrl: string;
}

/** 当前启动器实例拥有的版本操作；读取库存不改选中项，提交复用页面的准入与任务所有者。 */
export interface LauncherVersionAccess {
  filesDir: string;
  root: () => string;
  initialized: () => boolean;
  ready: () => boolean;
  blockReason: () => string;
  taskBlock: () => string;
  selected: () => string;
  inventory: () => Promise<LocalVersionInventory>;
  catalog: McVersionService;
  loaders: ModLoaderManager;
  supportedLoaders: () => ModLoaderType[];
  loaderAdmission: (game: string, loader: ModLoaderType | null) => string;
  suggestedName: (game: string, loader: ModLoaderType | null, version: string) => string;
  companion: (game: string) => Promise<VersionCompanionSelection | null>;
  registry: DownloadTaskRegistry;
  select: (version: string) => Promise<boolean>;
  install: (gameVersion: string, versionName: string, loader: ModLoaderType | null,
    loaderVersion: string, api: RemoteVersion | null, apiIcon?: string) => VersionInstallation;
}

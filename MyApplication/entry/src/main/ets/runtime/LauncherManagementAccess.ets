import { LocalVersionInventory } from 'feature_core';
import { VersionLaunchOverride } from 'feature_system';
import { ResourceKind } from 'mods';
import { OrphanCleanupPlan } from './OrphanCleanup';

/** 当前首页的管理操作。版本确认的代次属于页面，切换窗口后须重新确认。 */
export interface LauncherManagementAccess {
  root: () => string;
  block: (confirmingDeletion: boolean, closingDownloads?: boolean) => string;
  inventory: () => Promise<LocalVersionInventory>;
  gameBusy: () => boolean;
  prepareOrphan: (version: string) => Promise<OrphanCleanupPlan>;
  removeOrphan: (plan: OrphanCleanupPlan) => Promise<Record<string,Object>>;
  prepareRename: (from: string) => VersionRenameConfirmation | undefined;
  prompt: (version: string) => number;
  pending: (version: string, epoch: number) => boolean;
  cancel: () => void;
  remove: () => Promise<boolean>;
  browse: (kind: ResourceKind) => boolean;
  library: (version: string, kind: ResourceKind) => void;
  accounts: () => void;
  home: () => boolean;
  settings: (version: string) => VersionLaunchOverride;
  jdkChoices: () => string[];
  saveJdk: (version: string, value: string) => Promise<boolean>;
  saveResolution: (version: string, percent: number) => Promise<void>;
}

/** 首页捕获实际根与原目录身份，确认时必须仍是同一实例。 */
export type VersionRenameConfirmation = (from: string, to: string) => boolean;

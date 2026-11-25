import { UnifiedDownloadAdapter } from 'feature_core';
import { ModSearchState, RemoteProject, RemoteVersion, RemoteFile, ResourceKind, SortBy } from 'mods';

/** 详情选项投影没有下载地址；仅真实准备完成的计划可入队。 */
export interface ResourceDependencyChoice {
  key: string; displayName: string; dependencyType: string; selected: boolean; alreadyInstalled: boolean; versionNumber?: string;
}
export interface ResourceDetailSelection {
  project: RemoteProject; selected: RemoteVersion | null; file: RemoteFile | null; versions: RemoteVersion[];
  deps: ResourceDependencyChoice[]; name: string; ready: boolean; loading: boolean; error: boolean; saveOnly: boolean;
  session: number; revision: number; root: string; target: string; isolation: boolean; sourcePolicy: string;
}
export type ResourceEnqueued = (task: UnifiedDownloadAdapter, completion: Promise<void>) => void;
export interface LocalPackDraft { archive: string; root: string; name: string; valid: boolean; }

/** 页面为控件与调试适配提供同一个查询、选版、依赖、提交 owner；文件系统和产品规则留在业务端。 */
export interface ResourceBrowseAccess {
  available: () => boolean;
  kind: () => ResourceKind;
  contextKey: () => string;
  filesDir: () => string;
  search: (query: string, loader: string | undefined, game: string | undefined, sort: SortBy | undefined) => Promise<void>;
  next: () => Promise<void>;
  view: () => ModSearchState;
  detail: () => ResourceDetailSelection | null;
  open: (project: RemoteProject) => Promise<void>;
  pick: (version: RemoteVersion) => Promise<void>;
  toggle: (key: string) => Promise<void>;
  rename: (name: string) => void;
  submit: (capture: ResourceEnqueued) => void;
  saveSelectedFile?: () => Promise<string>;
  confirmDependencies?: (project: string, files: string[], target: string) => Promise<boolean>;
  dismiss: () => void;
  local: () => LocalPackDraft | null;
  importLocal: (stillCurrent: () => boolean) => Promise<string>;
  renameLocal: (name: string) => void;
  submitLocal: (capture: ResourceEnqueued) => void;
}

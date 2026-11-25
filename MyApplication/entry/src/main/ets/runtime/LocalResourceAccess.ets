import { InstalledResourceRow } from '../components/InstalledResourceData';
import { ResourceKind } from 'mods';

/** 资源管理页绑定的行来自当前目录的真实扫描，所有改动交给页面已有的安装器。 */
export interface LocalResourceAccess {
  active: boolean; shared: boolean; ready: boolean; error: boolean; epoch: number; directory: string; version: string; kind: ResourceKind;
  rows: InstalledResourceRow[]; togglable: boolean; pending: string; confirmation: number;
  toggle: (row: InstalledResourceRow, enabled: boolean) => Promise<Record<string,Object>>;
  prompt: (name: string) => number;
  remove: () => boolean;
  cancel: () => void;
  back: () => void;
}

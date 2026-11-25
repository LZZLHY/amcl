/**
 * 日志占用管理：异步统计实际字节，按游戏实例/普通活动分组。空间阈值只提醒，
 * 不静默削减每版本保留承诺；保留/删除仍由 ActivityLedger 的统一保护规则执行。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ledgerReadSnapshotAsync, LedgerState } from './ActivityLedger';
import { acquireEvidenceLease, releaseEvidenceLease, writeEvidenceTextAtomic } from './EvidenceIo';

export interface ActivityStorageItem { activityId: number; title: string; bytes: number; pinned: boolean; running: boolean; }
export interface ActivityStorageGroup { key: string; title: string; bytes: number; items: ActivityStorageItem[]; }
export interface ActivityStorageSummary { bytes: number; groups: ActivityStorageGroup[]; issues: string[]; }
interface StorageAlert { bytes: number; }

/**
 * 复用账本异步索引的可信目录计量，不先同步重建再独立递归统计第二遍。
 * 逐活动租约保护原清单读取；writing/unknown或清单在读取期间变化均保留未知值(-1)，
 * 不把已知部分伪装成完整总量。原件不可读的目录仍由issues说明，不制造空成功。
 */
export async function readActivityStorage(filesDir: string, cancelled: () => boolean): Promise<ActivityStorageSummary> {
  const result: ActivityStorageSummary = { bytes: 0, groups: [], issues: [] };
  const groups: Map<string, ActivityStorageGroup> = new Map<string, ActivityStorageGroup>();
  const snapshot = await ledgerReadSnapshotAsync(filesDir, cancelled);
  for (const entry of snapshot.entries) {
    if (cancelled()) throw new Error('占用统计已取消');
    let leased: boolean = false;
    try {
      acquireEvidenceLease(filesDir, entry.activityId); leased = true;
      // 原清单读取已由snapshot租约保护；此处只消费独立内存副本，不二次读盘制造跨轮混合状态。
      const manifest = snapshot.manifests.get(entry.activityId);
      if (cancelled()) throw new Error('占用统计已取消');
      if (manifest === undefined) throw new Error('清单不可读，目录原件仍保留');
      const trusted: boolean = entry.bytesState === 'current' && entry.manifestDigest === JSON.stringify(manifest);
      const bytes: number = trusted ? entry.bytes : -1;
      if (!trusted) result.issues.push(manifest.title + '：' + (entry.bytesState === 'writing'
        ? '日志仍在写入，完整占用尚未确认' : '目录占用无法核实，请刷新重试'));
      const key: string = manifest.category === 'launch' ? manifest.mcDir + '\n' + manifest.gameVersionId : 'other:' + manifest.category;
      let group: ActivityStorageGroup | undefined = groups.get(key);
      if (group === undefined) {
        group = { key: key, title: manifest.category === 'launch' ? manifest.gameVersionId || manifest.title
          : manifest.category === 'download' ? '游戏下载' : manifest.category === 'mod_install' ? '模组安装' : manifest.category,
          bytes: 0, items: [] };
        result.groups.push(group);
        groups.set(key, group);
      }
      group.bytes = group.bytes < 0 || bytes < 0 ? -1 : group.bytes + bytes;
      result.bytes = result.bytes < 0 || bytes < 0 ? -1 : result.bytes + bytes;
      group.items.push({ activityId: entry.activityId, title: manifest.title, bytes: bytes,
        pinned: manifest.pinned === true, running: manifest.state === LedgerState.RUNNING });
    } catch (e) {
      if (cancelled()) throw e as Error;
      result.bytes = -1;
      result.issues.push('活动 ' + entry.activityId + '：' + (e as Error).message);
    } finally { if (leased) releaseEvidenceLease(filesDir, entry.activityId); }
  }
  result.groups.sort((a: ActivityStorageGroup, b: ActivityStorageGroup): number => b.bytes - a.bytes);
  return result;
}

/** 明确缺少配置时按产品默认值处理；权限拒绝、损坏和无法核对的回读保留为未知。 */
export function readConfirmedActivityAlert(filesDir: string, useDefaultIfMissing: boolean = true): number | undefined {
  try {
    const value = JSON.parse(fs.readTextSync(filesDir + '/logs/storage-alert.json')) as StorageAlert;
    return value && Number.isSafeInteger(value.bytes) && value.bytes >= 0 ? value.bytes : undefined;
  } catch (e) {
    return useDefaultIfMissing && (e as BusinessError).code === 13900002 ? 0 : undefined;
  }
}
/** 页面保留原显示偏好；严格查询与设置回执直接使用上面的读取方法。 */
export function activityStorageAlert(filesDir: string): number {
  return readConfirmedActivityAlert(filesDir) ?? 0;
}
export function setActivityStorageAlert(filesDir: string, bytes: number): void {
  if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error('空间提醒阈值无效');
  const value: StorageAlert = { bytes: bytes };
  writeEvidenceTextAtomic(filesDir + '/logs/storage-alert.json', JSON.stringify(value));
}

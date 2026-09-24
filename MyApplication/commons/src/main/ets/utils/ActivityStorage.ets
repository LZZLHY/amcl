/**
 * 日志占用管理：异步统计实际字节，按游戏实例/普通活动分组。空间阈值只提醒，
 * 不静默削减每版本保留承诺；保留/删除仍由 ActivityLedger 的统一保护规则执行。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ledgerList, ledgerManifest, ledgerDirOf, LedgerState } from './ActivityLedger';
import { acquireEvidenceLease, releaseEvidenceLease, writeEvidenceTextAtomic } from './EvidenceIo';

export interface ActivityStorageItem { activityId: number; title: string; bytes: number; pinned: boolean; running: boolean; }
export interface ActivityStorageGroup { key: string; title: string; bytes: number; items: ActivityStorageItem[]; }
export interface ActivityStorageSummary { bytes: number; groups: ActivityStorageGroup[]; issues: string[]; }
interface StorageAlert { bytes: number; }

/** 每层仅持有文件名，异步 stat 不把整个大日志读进内存；取消在每次 I/O 前检查。 */
async function directoryBytes(directory: string, cancelled: () => boolean, depth: number = 0): Promise<number> {
  if (depth > 8) throw new Error('日志目录层级超过统计范围');
  let bytes: number = 0;
  const names: string[] = await fs.listFile(directory);
  for (const name of names) {
    if (cancelled()) throw new Error('占用统计已取消');
    const path: string = directory + '/' + name;
    const stat = await fs.stat(path);
    bytes += stat.isDirectory() ? await directoryBytes(path, cancelled, depth + 1) : stat.size;
  }
  return bytes;
}

/** 逐活动租约防止统计期间自动淘汰；单局无法统计时保留错误，不把它算成成功的零字节。 */
export async function readActivityStorage(filesDir: string, cancelled: () => boolean): Promise<ActivityStorageSummary> {
  const result: ActivityStorageSummary = { bytes: 0, groups: [], issues: [] };
  for (const entry of ledgerList(filesDir)) {
    if (cancelled()) throw new Error('占用统计已取消');
    const manifest = ledgerManifest(filesDir, entry.activityId);
    if (manifest === null) { result.issues.push('活动 ' + entry.activityId + ' 清单不可读'); continue; }
    acquireEvidenceLease(filesDir, entry.activityId);
    try {
      const bytes: number = await directoryBytes(ledgerDirOf(filesDir, entry.activityId), cancelled);
      const key: string = manifest.category === 'launch' ? manifest.mcDir + '\n' + manifest.gameVersionId : 'other:' + manifest.category;
      let group: ActivityStorageGroup | undefined = result.groups.find((item: ActivityStorageGroup): boolean => item.key === key);
      if (group === undefined) {
        group = { key: key, title: manifest.category === 'launch' ? manifest.gameVersionId || manifest.title
          : manifest.category === 'download' ? '游戏下载' : manifest.category === 'mod_install' ? '模组安装' : manifest.category,
          bytes: 0, items: [] };
        result.groups.push(group);
      }
      group.bytes += bytes; result.bytes += bytes;
      group.items.push({ activityId: entry.activityId, title: manifest.title, bytes: bytes,
        pinned: manifest.pinned === true, running: manifest.state === LedgerState.RUNNING });
    } catch (e) { if (cancelled()) throw e as Error; result.issues.push(manifest.title + '：' + (e as Error).message); }
    finally { releaseEvidenceLease(filesDir, entry.activityId); }
  }
  result.groups.sort((a: ActivityStorageGroup, b: ActivityStorageGroup): number => b.bytes - a.bytes);
  return result;
}

/** 0 表示不提醒；配置损坏回到显式关闭，不据此删除任何内容。 */
export function activityStorageAlert(filesDir: string): number {
  try {
    const value = JSON.parse(fs.readTextSync(filesDir + '/logs/storage-alert.json')) as StorageAlert;
    return Number.isSafeInteger(value.bytes) && value.bytes >= 0 ? value.bytes : 0;
  } catch (e) { return 0; }
}
export function setActivityStorageAlert(filesDir: string, bytes: number): void {
  if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error('空间提醒阈值无效');
  const value: StorageAlert = { bytes: bytes };
  writeEvidenceTextAtomic(filesDir + '/logs/storage-alert.json', JSON.stringify(value));
}

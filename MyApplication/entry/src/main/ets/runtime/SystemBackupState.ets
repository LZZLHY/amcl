import { bundleManager } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AtomicFileWriter } from 'commons';

type CallbackKind = 'backup' | 'restore';
interface BackupCallbackRecord { kind: CallbackKind; timestamp: number; }
interface BackupConfiguration { allowToBackupRestore?: boolean; }
type BackupInfo = Record<string, Object>;

/** 两个固定缓存文件各自由相应的系统回调写入，避免跨进程覆盖另一种操作。 */
function callbackPath(cacheDir: string, kind: CallbackKind): string {
  return cacheDir + '/amcl-system-' + kind + '-callback.json';
}

export function observeSystemBackupCallback(cacheDir: string, kind: CallbackKind): void {
  if (!cacheDir) return;
  const value: BackupCallbackRecord = { kind: kind, timestamp: Date.now() };
  try {
    AtomicFileWriter.write(callbackPath(cacheDir, kind), JSON.stringify(value));
  } catch (_) { /* 可清除的诊断缓存不能阻碍系统处理备份、恢复。 */ }
}

function readCallback(cacheDir: string, kind: CallbackKind): BackupInfo {
  if (!cacheDir) return { 'state': 'unreadable' };
  try {
    const path = callbackPath(cacheDir, kind);
    const file = fs.lstatSync(path);
    if (!file.isFile() || file.isSymbolicLink() || file.size <= 0 || file.size > 512) return { 'state': 'unreadable' };
    const row = JSON.parse(fs.readTextSync(path)) as BackupCallbackRecord;
    if (!row || row.kind !== kind || !Number.isSafeInteger(row.timestamp) || row.timestamp <= 0) return { 'state': 'unreadable' };
    return { 'state': 'observed', 'at': row.timestamp };
  } catch (error) {
    return { 'state': (error as BusinessError).code === 13900002 ? 'notObserved' : 'unreadable' };
  }
}

/** 查询当前安装包的真实扩展配置。回调说明应用被系统调用过，系统最终备份、恢复结果仅由系统报告。 */
export async function readSystemBackupStatus(cacheDir: string): Promise<BackupInfo> {
  if (!canIUse('SystemCapability.FileManagement.StorageService.Backup')) {
    return { 'state': 'unavailable', 'reason': 'systemCapabilityUnavailable' };
  }
  try {
    const profiles = await bundleManager.getProfileByExtensionAbility('entry', 'EntryBackupAbility', 'ohos.extension.backup');
    if (profiles.length !== 1) return { 'state':'unknown', 'reason':'profileUnavailable' };
    const profile = JSON.parse(profiles[0]) as BackupConfiguration;
    if (!profile || typeof profile.allowToBackupRestore !== 'boolean') return { 'state':'unknown', 'reason':'profileUnavailable' };
    return { 'state': 'ready', 'allowed':profile.allowToBackupRestore, 'initiator':'system',
      'lastBackupCallback':readCallback(cacheDir,'backup'), 'lastRestoreCallback':readCallback(cacheDir,'restore'),
      'systemOutcome':'notReportedByExtension' };
  } catch (_) {
    return { 'state':'unknown', 'reason':'profileUnavailable' };
  }
}

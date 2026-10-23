/**
 * 启动准备失败的既有单局交接队列。游戏只发布小型原文；启动器耐久恢复canonical和历史后清同身份原件。
 * 每活动独立原子文件避免跨进程整份队列覆盖；schema1旧ActivityRecord继续兼容，不能伪造旧PID/nonce。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger, LOG_DOMAIN_LAUNCH, writeEvidenceTextAtomicAsync, ledgerManifestAsync,
  ledgerEnsureLegacyLaunchAsync, ledgerEndAsync, LedgerState, ensureEvidenceDirectoryAsync } from 'commons';
import { readRecoveryTextAsync } from 'launch';
import { getDownloadHistoryStore, ActivityRecord, ActivityStatus, ActivityCategory } from 'feature_core';

interface GameFailurePublication { schema: number; activityId: number; producerPid: number; runNonce: string; record: ActivityRecord; }

export class DesktopGameResults {
  private static importing: Promise<string> | undefined = undefined;
  /** 只通知已经耐久提交的活动ID；崩溃后仍由canonical清单/原始队列重建，不依赖本数组。 */
  private static committedIds: number[] = [];
  static takeCommittedIds(): number[] { const ids = DesktopGameResults.committedIds.slice(); DesktopGameResults.committedIds = []; return ids; }

  /** 在可能关闭游戏进程的操作之前await；失败抛出，调用方不得把launchRecorded提前置true。 */
  static async queue(context: common.Context, record: ActivityRecord): Promise<void> {
    const directory = context.filesDir + '/desktop-results';
    await ensureEvidenceDirectoryAsync(directory);
    const manifest = await ledgerManifestAsync(context.filesDir, record.startedAt);
    const publication: GameFailurePublication = { schema: 2, activityId: record.startedAt, producerPid: process.pid,
      runNonce: manifest?.runNonce ?? '', record: record };
    const path = directory + '/' + record.startedAt + '.json';
    const existing = await readRecoveryTextAsync(path, 65536);
    if (existing.length > 0) {
      const parsed = JSON.parse(existing) as GameFailurePublication;
      const previous = parsed.schema === 2 ? parsed.record : JSON.parse(existing) as ActivityRecord;
      if (JSON.stringify(previous) !== JSON.stringify(record)) throw new Error('同活动失败原件已存在且内容不同，双方事实保留');
      return;
    }
    const text = JSON.stringify(publication);
    if (text.length > 65536) throw new Error('游戏失败交接超出小型原件上限，保留本进程失败事实');
    await writeEvidenceTextAtomicAsync(path, text);
  }

  /** 同一进程只有一轮导入；失败原件保留，下次明确空闲唤醒继续真实持久恢复。 */
  static importPending(context: common.Context): Promise<string> {
    if (DesktopGameResults.importing !== undefined) return DesktopGameResults.importing;
    const job = DesktopGameResults.importInternal_(context); DesktopGameResults.importing = job;
    job.then((): void => { if (DesktopGameResults.importing === job) DesktopGameResults.importing = undefined; },
      (): void => { if (DesktopGameResults.importing === job) DesktopGameResults.importing = undefined; });
    return job;
  }

  private static async importInternal_(context: common.Context): Promise<string> {
    const directory = context.filesDir + '/desktop-results';
    let names: string[];
    try { names = await fs.listFile(directory); }
    catch (error) { if ((error as BusinessError).code === 13900002) return ''; throw error as Error; }
    if (names.length === 0) return '';
    const store = getDownloadHistoryStore(); await store.init(context);
    let message = ''; let failure: Error | undefined = undefined;
    for (const name of names) {
      if (!new RegExp('^[1-9][0-9]*[.]json$').test(name)) continue;
      const path = directory + '/' + name;
      try {
        const text = await readRecoveryTextAsync(path, 65536); if (text.length === 0) continue;
        const envelope = JSON.parse(text) as GameFailurePublication;
        const record = envelope.schema === 2 ? envelope.record : JSON.parse(text) as ActivityRecord;
        if (record === undefined || record === null || !Number.isSafeInteger(record.startedAt) || record.startedAt <= 0
          || name !== record.startedAt + '.json' || record.category !== ActivityCategory.LAUNCH
          || record.status !== ActivityStatus.FAILED || typeof record.versionName !== 'string') throw new Error('失败交接原件身份无效');
        let manifest = await ledgerManifestAsync(context.filesDir, record.startedAt);
        if (envelope.schema === 2) {
          if (envelope.activityId !== record.startedAt || !Number.isSafeInteger(envelope.producerPid) || envelope.producerPid <= 0
            || typeof envelope.runNonce !== 'string') throw new Error('失败交接生产者身份无效');
          if (manifest !== null && ((manifest.ownerPid ?? 0) > 0 && envelope.producerPid !== manifest.ownerPid
            || (manifest.runNonce ?? '') !== envelope.runNonce)) throw new Error('失败交接与账本PID/nonce不匹配，原文保留');
          if (manifest === null && envelope.runNonce.length > 0) throw new Error('已有绑定失败原件对应清单缺失，不能重新建立另一个身份');
        }
        if (manifest === null) manifest = await ledgerEnsureLegacyLaunchAsync(context.filesDir, record.startedAt,
          { category: 'launch', title: record.versionName, gameVersionId: record.gameVersion, mcDir: record.mcDir ?? '' });
        if (manifest.state === LedgerState.CRASHED && manifest.outcomeSource.startsWith('platform.')) {
          // 已精确归属的平台崩溃优先；旧失败交接不能把CRASHED重新降成普通启动失败。
          record.status = ActivityStatus.CRASHED; record.errorMessage = manifest.outcomeSummary;
          record.endedAt = manifest.endedAt; record.durationEstimated = manifest.endTimeEstimated === true;
          record.durationMs = record.durationEstimated ? 0 : Math.max(0, manifest.endedAt - manifest.startedAt);
        } else await ledgerEndAsync(context.filesDir, record.startedAt, { state: LedgerState.FAILED, source: 'launch-preparation',
          summary: record.errorMessage ?? '游戏启动失败', endedAt: record.endedAt ?? 0 });
        await store.upsertLaunchSession(record);
        if (!DesktopGameResults.committedIds.includes(record.startedAt)) DesktopGameResults.committedIds.push(record.startedAt);
        // 最后再读当前文件，较新或不同原件不能被旧导入回调清走；失败原件从未借内存Set永久屏蔽。
        if (await readRecoveryTextAsync(path, 65536) === text) {
          await fs.unlink(path);
          const parent = await fs.open(directory, fs.OpenMode.READ_ONLY);
          try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
        }
        message = record.errorMessage ?? '游戏启动失败';
      } catch (error) {
        failure = error as Error;
        AppLogger.warn('DesktopGameResults', '失败交接尚未完成，原文保留: ' + name, error, LOG_DOMAIN_LAUNCH);
      }
    }
    if (failure !== undefined) throw failure;
    return message;
  }
}

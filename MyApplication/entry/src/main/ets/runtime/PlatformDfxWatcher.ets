/**
 * PlatformDfxWatcher.ets — HarmonyOS 平台退出/崩溃事件接收器（日志系统 U05）
 *
 * HiAppEvent 的 APP_CRASH/APP_KILLED 由系统在进程退出后异步投递。
 * 回调只做一件事：把事件原文写入 filesDir/logs/platform-events，
 * 后续由 ActivityLedger 在冷启动时按时间和 activityId 归档。
 *
 * 约束：
 *   - 不在 watcher 回调里上传、分析、读取游戏日志或修改游戏状态；
 *   - 不把 external_log 的路径直接显示给用户；
 *   - 文件名只使用系统时间和进程内序号，正文 JSON 作为私有本地证据；
 *   - 重复注册同名 watcher 前先 remove，避免系统以同名覆盖造成事件丢失。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { AbilityConstant } from '@kit.AbilityKit';
import { process, util } from '@kit.ArkTS';
import { ensureDirSync, writeEvidenceTextAtomic, writeEvidenceTextAtomicAsync, setLedgerProcessRunNonce,
  ledgerLaunchManifestsAsync, LedgerState } from 'commons';

const TAG: string = 'amcl_platform_dfx';
interface ProcessRun { pid: number; nonce: string; startedAt: number; }

export class PlatformDfxWatcher {
  private static watcher: hiAppEvent.Watcher | undefined = undefined;
  private static outputDir: string = '';
  private static sequence: number = 0;
  private static filesDir: string = '';
  private static previousRun: ProcessRun | undefined = undefined;
  /** 平台原件写入串行队列，所有FileIO真正异步执行；失败原件/暂存现场由下次恢复核实。 */
  private static persistence: Promise<void> = Promise.resolve();
  private static recoveryWake: (() => void) | undefined = undefined;

  /** 装配层注入有界唤醒端口；回调只通知owner，不在系统回调内匹配账本或上传内容。 */
  static setRecoveryWake(callback: () => void): void { PlatformDfxWatcher.recoveryWake = callback; }
  static flushPending(): Promise<void> { return PlatformDfxWatcher.persistence; }

  /** 原件file+directory同步成功才唤醒；没有64条截断，未归属证据保持原始字节。 */
  private static queuePersistence_(operation: () => Promise<void>): void {
    const previous = PlatformDfxWatcher.persistence;
    const job: Promise<void> = previous.catch((): void => {}).then(operation);
    PlatformDfxWatcher.persistence = job;
    job.catch((): void => { /* 原件写失败不消费任何恢复义务，下一次冷启动重新核实。 */ });
  }

  /** 在 EntryAbility.onCreate 尽早注册，应用重启后系统才会投递上次事件。 */
  static start(filesDir: string, owner: string = 'host'): void {
    if (!filesDir || filesDir.length === 0) return;
    PlatformDfxWatcher.filesDir = filesDir;
    PlatformDfxWatcher.outputDir = filesDir + '/logs/platform-events';
    try { ensureDirSync(PlatformDfxWatcher.outputDir); } catch (e) { return; }
    if (PlatformDfxWatcher.watcher !== undefined) return;
    const runPath: string = filesDir + '/logs/dfx-' + owner + '-run.json';
    try { PlatformDfxWatcher.previousRun = JSON.parse(fs.readTextSync(runPath)) as ProcessRun; }
    catch (e) { PlatformDfxWatcher.previousRun = undefined; }
    const run: ProcessRun = { pid: process.pid, nonce: util.generateRandomUUID(true), startedAt: Date.now() };
    setLedgerProcessRunNonce(run.nonce);
    try { writeEvidenceTextAtomic(runPath, JSON.stringify(run)); } catch (e) { /* 无身份记录时不猜上次活动 */ }

    const watcher: hiAppEvent.Watcher = {
      name: TAG,
      appEventFilters: [
        { domain: hiAppEvent.domain.OS,
          names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_KILLED] },
      ],
      onReceive: (domain: string, groups: Array<hiAppEvent.AppEventGroup>): void => {
        PlatformDfxWatcher.persist_(domain, groups);
      },
    };
    try {
      hiAppEvent.addWatcher(watcher);
      PlatformDfxWatcher.watcher = watcher;
    } catch (e) {
      PlatformDfxWatcher.watcher = undefined;
    }
  }

  /** 记录 UIAbility.onCreate 收到的上次退出原因，避免只依赖异步 APP_KILLED。 */
  static recordLastExit(filesDir: string, reason: AbilityConstant.LastExitReason, message: string): void {
    if (!filesDir || reason === AbilityConstant.LastExitReason.UNKNOWN) return;
    PlatformDfxWatcher.filesDir = filesDir;
    PlatformDfxWatcher.outputDir = filesDir + '/logs/platform-events';
    try { ensureDirSync(PlatformDfxWatcher.outputDir); } catch (e) { return; }
    PlatformDfxWatcher.sequence++;
    const stamp: number = Date.now();
    const path: string = PlatformDfxWatcher.outputDir + '/event-'
      + stamp + '-' + process.pid + '-' + PlatformDfxWatcher.sequence + '-' + util.generateRandomUUID() + '-exit.json';
    const payload: Record<string, Object> = {
      'schema': 1, 'domain': 'OS', 'name': 'LAST_EXIT_REASON',
      'receivedAt': stamp, 'reasonCode': reason,
      'reason': PlatformDfxWatcher.lastExitReasonName_(reason), 'message': message,
    };
    const previous = PlatformDfxWatcher.previousRun;
    PlatformDfxWatcher.queuePersistence_(async (): Promise<void> => {
      if (previous !== undefined) {
        for (const manifest of await ledgerLaunchManifestsAsync(filesDir)) {
          if (manifest?.runNonce !== previous.nonce || manifest.ownerPid !== previous.pid) continue;
          if (manifest.state !== LedgerState.RUNNING && manifest.state !== LedgerState.INTERRUPTED) continue;
          payload['activityId'] = manifest.activityId; payload['runNonce'] = previous.nonce; break;
        }
      }
      await writeEvidenceTextAtomicAsync(path, JSON.stringify(payload));
      // 跨进程唤醒提示在原件之后发布；提示可覆盖，原件不可覆盖，owner一次归档全部未消费事件。
      await writeEvidenceTextAtomicAsync(filesDir + '/logs/platform-events/publication.json', JSON.stringify({ schema: 1, publication: path }));
      PlatformDfxWatcher.recoveryWake?.();
    });
  }

  private static lastExitReasonName_(reason: AbilityConstant.LastExitReason): string {
    if (reason === AbilityConstant.LastExitReason.NORMAL) return 'NORMAL';
    if (reason === AbilityConstant.LastExitReason.CPP_CRASH) return 'CPP_CRASH';
    if (reason === AbilityConstant.LastExitReason.JS_ERROR) return 'JS_ERROR';
    if (reason === AbilityConstant.LastExitReason.APP_FREEZE) return 'APP_FREEZE';
    if (reason === AbilityConstant.LastExitReason.RESOURCE_CONTROL) return 'RESOURCE_CONTROL';
    if (reason === AbilityConstant.LastExitReason.PERFORMANCE_CONTROL) return 'PERFORMANCE_CONTROL';
    if (reason === AbilityConstant.LastExitReason.UPGRADE) return 'UPGRADE';
    if (reason === AbilityConstant.LastExitReason.USER_REQUEST) return 'USER_REQUEST';
    if (reason === AbilityConstant.LastExitReason.SIGNAL) return 'SIGNAL';
    return 'UNKNOWN';
  }

  /** 只持久化系统给出的原始事件；后续读取方按事件类型做字段白名单。 */
  private static persist_(domain: string, groups: Array<hiAppEvent.AppEventGroup>): void {
    if (PlatformDfxWatcher.outputDir.length === 0) return;
    for (const group of groups) {
      for (const info of group.appEventInfos) {
        PlatformDfxWatcher.sequence++;
        const stamp: number = Date.now();
        const path: string = PlatformDfxWatcher.outputDir + '/event-'
          + stamp + '-' + process.pid + '-' + PlatformDfxWatcher.sequence + '-' + util.generateRandomUUID() + '.json';
        let paramsText: string = '{}';
        try { paramsText = JSON.stringify(info.params); } catch (e) { /* 只保留事件名称 */ }
        let eventAt: number = 0;
        try {
          const params = JSON.parse(paramsText) as Record<string, Object>;
          const value = params['time'];
          if (typeof value === 'number' && value > 0) eventAt = value as number;
        } catch (e) { /* 无原始时间时保留 receivedAt */ }
        const payload: Record<string, Object> = {
          'schema': 1,
          'domain': domain,
          'name': group.name,
          'receivedAt': stamp,
          'eventAt': eventAt,
          'params': JSON.parse(paramsText) as Object,
        };
        const text: string = JSON.stringify(payload);
        PlatformDfxWatcher.queuePersistence_(async (): Promise<void> => {
          await writeEvidenceTextAtomicAsync(path, text);
          await writeEvidenceTextAtomicAsync(PlatformDfxWatcher.outputDir + '/publication.json', JSON.stringify({ schema: 1, publication: path }));
          PlatformDfxWatcher.recoveryWake?.();
        });
      }
    }
  }

}

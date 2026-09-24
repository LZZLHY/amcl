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
import { ensureDirSync, writeEvidenceTextAtomic, archivePlatformEventFiles_, setLedgerProcessRunNonce,
  listActivityIds, ledgerManifest, LedgerState } from 'commons';

const TAG: string = 'amcl_platform_dfx';
const MAX_PENDING_EVENTS: number = 64;
interface ProcessRun { pid: number; nonce: string; startedAt: number; }

export class PlatformDfxWatcher {
  private static watcher: hiAppEvent.Watcher | undefined = undefined;
  private static outputDir: string = '';
  private static sequence: number = 0;
  private static filesDir: string = '';
  private static previousRun: ProcessRun | undefined = undefined;

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
      + stamp + '-' + process.pid + '-' + PlatformDfxWatcher.sequence + '-exit.json';
    const payload: Record<string, Object> = {
      'schema': 1, 'domain': 'OS', 'name': 'LAST_EXIT_REASON',
      'receivedAt': stamp, 'reasonCode': reason,
      'reason': PlatformDfxWatcher.lastExitReasonName_(reason), 'message': message,
    };
    const previous = PlatformDfxWatcher.previousRun;
    if (previous !== undefined) {
      for (const id of listActivityIds(filesDir)) {
        const manifest = ledgerManifest(filesDir, id);
        if (manifest?.category !== 'launch' || manifest.runNonce !== previous.nonce
          || manifest.ownerPid !== previous.pid) continue;
        if (manifest.state !== LedgerState.RUNNING && manifest.state !== LedgerState.INTERRUPTED) continue;
        payload['activityId'] = id; payload['runNonce'] = previous.nonce;
        break;
      }
    }
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(payload));
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = undefined;
      PlatformDfxWatcher.trimPending_();
    } catch (e) {
      if (file !== undefined) {
        try { fs.closeSync(file); } catch (ignored) { /* 保留主错误 */ }
      }
    }
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
          + stamp + '-' + process.pid + '-' + PlatformDfxWatcher.sequence + '.json';
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
        let file: fs.File | undefined = undefined;
        try {
          file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
          if (fs.writeSync(file.fd, JSON.stringify(payload)) <= 0) throw new Error('平台事件写入失败');
          fs.fsyncSync(file.fd);
          fs.closeSync(file);
          file = undefined;
          archivePlatformEventFiles_(PlatformDfxWatcher.filesDir);
          PlatformDfxWatcher.trimPending_();
        } catch (e) {
          if (file !== undefined) {
            try { fs.closeSync(file); } catch (ignored) { /* 保留主错误 */ }
          }
        }
      }
    }
  }

  /** pending 事件不能无限堆积；优先保留最新事件，已归档文件不会出现在这里。 */
  private static trimPending_(): void {
    if (PlatformDfxWatcher.outputDir.length === 0) return;
    let names: string[] = [];
    try { names = fs.listFileSync(PlatformDfxWatcher.outputDir); } catch (e) { return; }
    const events: string[] = names.filter((name: string): boolean =>
      name.startsWith('event-') && name.endsWith('.json'));
    if (events.length <= MAX_PENDING_EVENTS) return;
    events.sort((a: string, b: string): number => {
      const at: number = Number(a.substring(6).split('-')[0]);
      const bt: number = Number(b.substring(6).split('-')[0]);
      return at - bt;
    });
    const removeCount: number = events.length - MAX_PENDING_EVENTS;
    for (let i = 0; i < removeCount; i++) {
      try { fs.unlinkSync(PlatformDfxWatcher.outputDir + '/' + events[i]); } catch (e) { /* 下次继续 */ }
    }
  }
}

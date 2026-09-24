/**
 * JVM 退出请求事实的读取边界。原生 hook 只原子发布有界 JSON；启动器确认游戏锁已释放后
 * 才读取、按本局身份归档，并交给 SessionOutcomeResolver 裁决。它不是 waitpid/OS 退出码。
 * 不删除原生记录，归档或历史写盘失败后仍可按 activityId 幂等重试。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger, LOG_DOMAIN_LAUNCH, ledgerManifest, ledgerDirOf,
  ensureDirSync, writeEvidenceTextAtomic, LedgerOutcome } from 'commons';
import { McSessionInfo } from './SessionMarker';

/** 与原生 schema=1 固定协议一致；exitCode 表示 JVM 请求的代码，不是 OS 观察结果。 */
export interface JvmExitEvidence {
  schema: number;
  activityId: number;
  pid: number;
  parentPid: number;
  exitCode: number;
  source: string;
  timestamp: number;
}

/** 只接受非空普通文件；原生使用临时文件 rename 发布，不读取未完成的临时记录。 */
function readBoundedText(path: string): string | undefined {
  try {
    const stat = fs.statSync(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 4096) return undefined;
    const text: string = fs.readTextSync(path);
    return text.length > 0 && text.length <= 4096 ? text : undefined;
  } catch (e) { return undefined; }
}

/** 避免浮点主键、负值或类型强转参与活动身份比较。 */
function positiveInteger(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

/**
 * 按原生活动文件名、账本游戏 PID、可选 capture-game 和时间同时确认归属。
 * 调用者须先确认游戏锁空闲；不能因读到退出“请求”就认为仍持锁的游戏已死亡。
 * 账本或身份缺失时不猜；未完成、损坏、异局记录返回 undefined，原文件保持不变。
 */
export function readJvmExitEvidence(filesDir: string, activityId: number): JvmExitEvidence | undefined {
  if (filesDir.length === 0 || !positiveInteger(activityId)) return undefined;
  const manifest = ledgerManifest(filesDir, activityId);
  if (manifest === null || manifest.category !== 'launch' || manifest.activityId !== activityId
    || manifest.startedAt !== activityId) return undefined;
  const text: string | undefined = readBoundedText(filesDir + '/game-exits/' + activityId + '.json');
  if (text === undefined) return undefined;
  let evidence: JvmExitEvidence;
  try { evidence = JSON.parse(text) as JvmExitEvidence; } catch (e) { return undefined; }
  if (evidence === null || evidence === undefined || evidence.schema !== 1 || evidence.source !== 'jvm-exit'
    || evidence.activityId !== activityId || !positiveInteger(evidence.pid) || !positiveInteger(evidence.parentPid)
    || evidence.pid === evidence.parentPid || manifest.ownerPid !== evidence.pid
    || typeof evidence.exitCode !== 'number' || !Number.isInteger(evidence.exitCode)
    || evidence.exitCode < -2147483648 || evidence.exitCode > 2147483647
    || !positiveInteger(evidence.timestamp) || evidence.timestamp < manifest.startedAt
    || evidence.timestamp > Date.now()) return undefined;
  const ledgerDir: string = ledgerDirOf(filesDir, activityId);
  const capturePath: string = ledgerDir + '/capture-game.json';
  try {
    if (fs.accessSync(capturePath)) {
      const captureText: string | undefined = readBoundedText(capturePath);
      if (captureText === undefined) return undefined;
      const capture = JSON.parse(captureText) as Record<string, Object>;
      if (capture['schema'] !== 1 || capture['activityId'] !== activityId || capture['pid'] !== evidence.pid) {
        return undefined;
      }
    }
  } catch (e) { return undefined; }
  try {
    ensureDirSync(ledgerDir + '/jvm');
    const archive: string = ledgerDir + '/jvm/process-exit.json';
    // 内容未变化时不重新写盘，避免每次前台恢复都改变证据摘要/mtime。
    if (readBoundedText(archive) !== text) writeEvidenceTextAtomic(archive, text);
  } catch (e) {
    AppLogger.warn('JvmExitEvidence', '退出事实归档失败，原生记录保留等待重试', e, LOG_DOMAIN_LAUNCH);
  }
  return evidence;
}

/**
 * 恢复 marker 尚未写入就退出的游戏。仅扫描正式数字文件名，保留所有原始记录；
 * 结果中的 endedAt 来自该局退出请求时间，不能把下次打开启动器的时刻算作游戏时长。
 */
export function listJvmExitSessions(filesDir: string): McSessionInfo[] {
  const sessions: McSessionInfo[] = [];
  let names: string[] = [];
  try { names = fs.listFileSync(filesDir + '/game-exits'); } catch (e) { return sessions; }
  for (const name of names) {
    if (!new RegExp('^[1-9][0-9]*[.]json$').test(name)) continue;
    const id: number = Number(name.substring(0, name.length - 5));
    if (!positiveInteger(id) || id.toString() + '.json' !== name) continue;
    const evidence = readJvmExitEvidence(filesDir, id);
    const manifest = ledgerManifest(filesDir, id);
    if (evidence === undefined || manifest === null) continue;
    const session: McSessionInfo = { startedAt: id, version: manifest.gameVersionId || manifest.title,
      mcDir: manifest.mcDir, endedAt: evidence.timestamp };
    sessions.push(session);
  }
  return sessions.sort((a: McSessionInfo, b: McSessionInfo): number => a.startedAt - b.startedAt);
}

/** 恢复展示去重回执不是终态。结局变化（如晚到平台崩溃）即不匹配，必须重新处理。 */
export function hasSessionRecoveryReceipt(filesDir: string, activityId: number, outcome: LedgerOutcome): boolean {
  const text = readBoundedText(ledgerDirOf(filesDir, activityId) + '/launcher/recovery-receipt.json');
  if (text === undefined) return false;
  try {
    const receipt = JSON.parse(text) as Record<string, Object>;
    return receipt['schema'] === 1 && receipt['activityId'] === activityId
      && receipt['state'] === outcome.state && receipt['source'] === outcome.source
      && receipt['summary'] === outcome.summary;
  } catch (e) { return false; }
}

/** 历史 upsert 完成后才写入；失败抛回 UI 保留重试机会，原生文件始终不删除。 */
export function writeSessionRecoveryReceipt(filesDir: string, activityId: number, outcome: LedgerOutcome): void {
  const directory: string = ledgerDirOf(filesDir, activityId) + '/launcher';
  const receipt: Record<string, Object> = { 'schema': 1, 'activityId': activityId,
    'state': outcome.state, 'source': outcome.source, 'summary': outcome.summary };
  const text: string = JSON.stringify(receipt);
  if (text.length > 4096) throw new Error('恢复回执超过有界长度，保留原始证据等待重试');
  ensureDirSync(directory);
  writeEvidenceTextAtomic(directory + '/recovery-receipt.json', text);
}

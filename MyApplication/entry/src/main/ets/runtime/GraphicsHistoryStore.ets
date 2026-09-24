/** 窗口无关的图形验证历史。游戏进程只写单局outcome，启动器在确认旧PID/锁已退出后
 * 合并有界历史。历史只是AUTO排序提示，不能制造surface/context能力或覆盖显式选择。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { writeEvidenceTextAtomic } from 'commons';
import { GraphicsHistoryHint, graphicsProfileById } from 'launch';
import { GraphicsRecoveryTicket, graphicsFailureRetryable } from './GraphicsRecoveryPolicy';

export interface GraphicsHistoryOutcome {
  id: string; parentPid: number; childPid: number; activityId: number; createdAt: number;
  scopeHash: string; profile: string; status: string; stage: string; code: string;
  presentCount: number; automatic: boolean; diagnosticInjected: boolean;
}
interface GraphicsHistoryRow {
  scopeHash: string; profile: string; successAt: number; failureAt: number; failures: number;
  lastActivity: number; updatedAt: number;
}
const DAY: number = 86400000;
function hashValid(value: string): boolean { return new RegExp('^[0-9a-f]{64}$').test(value); }
function idValid(value: string): boolean {
  return new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(value);
}
/** 独立校验实际回执，出帧后异常不训练启动失败；注入属性沿整条冷重试链传播。 */
export function graphicsHistoryOutcomePermitted(ticket: GraphicsRecoveryTicket, value: GraphicsHistoryOutcome,
  parentPid: number, expectedId: string, now: number): boolean {
  const profile = graphicsProfileById(value.profile);
  return idValid(value.id) && value.id === expectedId && value.id === ticket.id
    && value.parentPid === ticket.parentPid && value.parentPid === parentPid
    && value.activityId === ticket.activityId && value.childPid > 0 && value.childPid !== parentPid
    && value.createdAt >= ticket.createdAt && value.createdAt <= now && now - value.createdAt < 7 * DAY
    && hashValid(value.scopeHash) && value.automatic && !value.diagnosticInjected && ticket.diagnosticInjected !== true
    && profile !== undefined && String(profile.api) === 'OPENGL' && String(profile.lifecycle) !== 'retired'
    && ((value.status === 'presented' && value.presentCount >= 300 && value.stage === '' && value.code === '')
      || (value.status === 'startup-failed' && graphicsFailureRetryable(value.stage, value.code, value.presentCount)));
}
export class GraphicsHistoryStore {
  private static outcomePath(filesDir: string, id: string): string {
    if (!idValid(id)) throw new Error('Invalid graphics outcome identity');
    return filesDir + '/graphics-recovery/' + id + '.outcome.json';
  }
  /** 一局只提交一份可学习事实，不在每帧写磁盘，不包含账号、JVM原始参数或游戏路径。 */
  static report(filesDir: string, outcome: GraphicsHistoryOutcome): void {
    const path = GraphicsHistoryStore.outcomePath(filesDir, outcome.id);
    if (fs.accessSync(path)) return;
    const value: Record<string, Object> = { 'schema': 1, 'id': outcome.id, 'parentPid': outcome.parentPid,
      'childPid': outcome.childPid, 'activityId': outcome.activityId, 'createdAt': outcome.createdAt,
      'scopeHash': outcome.scopeHash, 'profile': outcome.profile, 'status': outcome.status,
      'stage': outcome.stage, 'code': outcome.code, 'presentCount': outcome.presentCount,
      'automatic': outcome.automatic, 'diagnosticInjected': outcome.diagnosticInjected };
    writeEvidenceTextAtomic(path, JSON.stringify(value));
  }
  static outcome(filesDir: string, id: string): GraphicsHistoryOutcome | undefined {
    try {
      const path = GraphicsHistoryStore.outcomePath(filesDir, id);
      if (fs.statSync(path).size > 4096) return undefined;
      const v: Record<string, Object> = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
      if (v === null || v['schema'] !== 1 || v['id'] !== id) return undefined;
      for (const key of ['scopeHash', 'profile', 'status', 'stage', 'code']) if (typeof v[key] !== 'string') return undefined;
      for (const key of ['parentPid', 'childPid', 'activityId', 'createdAt', 'presentCount'])
        if (typeof v[key] !== 'number' || !Number.isSafeInteger(v[key] as number) || (v[key] as number) < 0) return undefined;
      if (typeof v['automatic'] !== 'boolean' || typeof v['diagnosticInjected'] !== 'boolean') return undefined;
      return { id: id, parentPid: v['parentPid'] as number, childPid: v['childPid'] as number,
        activityId: v['activityId'] as number, createdAt: v['createdAt'] as number, scopeHash: v['scopeHash'] as string,
        profile: v['profile'] as string, status: v['status'] as string, stage: v['stage'] as string,
        code: v['code'] as string, presentCount: v['presentCount'] as number,
        automatic: v['automatic'] as boolean, diagnosticInjected: v['diagnosticInjected'] as boolean };
    } catch (_) { return undefined; }
  }
  private static rows(filesDir: string, now: number): GraphicsHistoryRow[] {
    const rows: GraphicsHistoryRow[] = [];
    try {
      const path = filesDir + '/graphics-history.json';
      if (fs.statSync(path).size > 65536) return rows;
      const document: Record<string, Object> = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
      if (document === null || document['schema'] !== 1 || !Array.isArray(document['rows'])) return rows;
      const raw: Object[] = document['rows'] as Object[];
      if (raw.length > 64) return rows;
      for (const item of raw) {
        const v: Record<string, Object> = item as Record<string, Object>;
        if (v === null || typeof v['scopeHash'] !== 'string' || !hashValid(v['scopeHash'] as string)
          || typeof v['profile'] !== 'string' || graphicsProfileById(v['profile'] as string) === undefined) continue;
        let valid: boolean = true;
        for (const key of ['successAt', 'failureAt', 'failures', 'lastActivity', 'updatedAt'])
          if (typeof v[key] !== 'number' || !Number.isSafeInteger(v[key] as number) || (v[key] as number) < 0) valid = false;
        if (!valid || (v['updatedAt'] as number) > now || now - (v['updatedAt'] as number) > 7 * DAY
          || (v['failures'] as number) > 2) continue;
        rows.push({ scopeHash: v['scopeHash'] as string, profile: v['profile'] as string,
          successAt: v['successAt'] as number, failureAt: v['failureAt'] as number, failures: v['failures'] as number,
          lastActivity: v['lastActivity'] as number, updatedAt: v['updatedAt'] as number });
      }
    } catch (_) { /* 可选缓存损坏或首次不存在，回到静态排序。 */ }
    return rows;
  }
  /** 重复启动失败只降权24小时；到期整组回到静态排序重新评估，避免成功fallback永远霸占首位。 */
  static hints(filesDir: string, scope: string, now: number): GraphicsHistoryHint[] {
    const hints: GraphicsHistoryHint[] = [];
    if (!hashValid(scope)) return hints;
    const rows = GraphicsHistoryStore.rows(filesDir, now).filter((row: GraphicsHistoryRow): boolean => row.scopeHash === scope);
    for (const row of rows) if (row.failures >= 2 && now - row.failureAt >= DAY) return hints;
    for (const row of rows) {
      const failed: boolean = row.failures >= 2 && now - row.failureAt < DAY;
      const recentSuccess: boolean = row.successAt > 0 && now >= row.successAt && now - row.successAt < DAY;
      hints.push({ profile: row.profile, scopeHash: scope, priority: failed ? -1 : recentSuccess ? 1 : 0,
        reason: failed ? 'repeated-startup-failure' : recentSuccess ? 'verified-presentation' : 'reevaluation-window' });
    }
    return hints;
  }
  /** 仅由父进程在确认子PID和进程锁退出后调用；重复/乱序回执不重复训练，最多64项。 */
  static learn(filesDir: string, ticket: GraphicsRecoveryTicket, outcome: GraphicsHistoryOutcome,
    parentPid: number, expectedId: string, now: number): boolean {
    if (!graphicsHistoryOutcomePermitted(ticket, outcome, parentPid, expectedId, now)) return false;
    const rows = GraphicsHistoryStore.rows(filesDir, now);
    let row = rows.find((value: GraphicsHistoryRow): boolean => value.scopeHash === outcome.scopeHash && value.profile === outcome.profile);
    if (row !== undefined && (row.lastActivity === outcome.activityId || row.updatedAt >= outcome.createdAt)) return false;
    if (row === undefined) {
      row = { scopeHash: outcome.scopeHash, profile: outcome.profile, successAt: 0, failureAt: 0,
        failures: 0, lastActivity: 0, updatedAt: 0 }; rows.push(row);
    }
    if (outcome.status === 'presented') {
      // 持续成功不续租优先权；24小时后仍有机会按静态建议重评。曾被隔离的路线真正成功
      // 后可以开始新的验证周期，但一份重复回执不能刷新周期或抹掉失败。
      if (row.successAt === 0 || row.failures >= 2) row.successAt = outcome.createdAt;
      row.failures = 0;
    }
    else { row.failures = now - row.failureAt < DAY ? Math.min(2, row.failures + 1) : 1; row.failureAt = outcome.createdAt; }
    row.lastActivity = outcome.activityId; row.updatedAt = outcome.createdAt;
    rows.sort((left: GraphicsHistoryRow, right: GraphicsHistoryRow): number => right.updatedAt - left.updatedAt);
    const encoded: Record<string, Object>[] = [];
    for (const value of rows.slice(0, 64)) encoded.push({ 'scopeHash': value.scopeHash, 'profile': value.profile,
      'successAt': value.successAt, 'failureAt': value.failureAt, 'failures': value.failures,
      'lastActivity': value.lastActivity, 'updatedAt': value.updatedAt });
    const document: Record<string, Object> = { 'schema': 1, 'rows': encoded };
    writeEvidenceTextAtomic(filesDir + '/graphics-history.json', JSON.stringify(document)); return true;
  }
}

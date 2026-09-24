/** 游戏会话与普通活动分别保留，下载活动不能挤掉游戏日志。 */
export const SESSION_RETENTION_DEFAULT: number = 5;
export const SESSION_RETENTION_MAX: number = 100;
/** 每版本单独保留最近的早期启动记录，不消耗完整游戏日志名额，也不受下载预算挤占。 */
export const EARLY_SESSION_RETENTION: number = 5;

export function normalizeSessionRetention(value: number): number {
  if (!Number.isFinite(value)) return SESSION_RETENTION_DEFAULT;
  return Math.max(SESSION_RETENTION_DEFAULT, Math.min(SESSION_RETENTION_MAX, Math.floor(value)));
}

export interface RetentionCandidate {
  activityId: number;
  category: string;
  versionKey: string;
  running: boolean;
  abnormal: boolean;
  bytes: number;
  hasGame: boolean;
}

/** 返回可删除的 id；运行中会话独立于已完成会话的数量窗口。 */
export function sessionRetentionVictims(entries: RetentionCandidate[], limit: number,
  activityLimit: number, activityBytes: number): number[] {
  const sorted = entries.slice().sort((a: RetentionCandidate, b: RetentionCandidate): number => b.activityId - a.activityId);
  const versions = new Map<string, number>();
  const earlyVersions = new Map<string, number>();
  const other: RetentionCandidate[] = [];
  const victims: number[] = [];
  const countLimit = normalizeSessionRetention(limit);
  for (const entry of sorted) {
    if (entry.running) continue;
    // 两个启动窗口独立计数：有游戏正文的会话保留用户指定 N 局，早期记录保留固定窗口。
    // 运行中条目已在上方排除，既不被清理，也不提前占用已结束会话名额。
    if (entry.category !== 'launch') { other.push(entry); continue; }
    if (!entry.hasGame) {
      const earlyCount: number = (earlyVersions.get(entry.versionKey) ?? 0) + 1;
      earlyVersions.set(entry.versionKey, earlyCount);
      if (earlyCount > EARLY_SESSION_RETENTION) victims.push(entry.activityId);
      continue;
    }
    const count = (versions.get(entry.versionKey) ?? 0) + 1;
    versions.set(entry.versionKey, count);
    if (count > countLimit) victims.push(entry.activityId);
  }
  // 普通活动仍按异常优先、数量与体积预算保留。
  other.sort((a: RetentionCandidate, b: RetentionCandidate): number => {
    if (a.abnormal !== b.abnormal) return a.abnormal ? -1 : 1;
    return b.activityId - a.activityId;
  });
  let count = 0;
  let bytes = 0;
  for (const entry of other) {
    // 被淘汰项不占保留预算。单条过大时仍继续检查后续小活动，避免级联清空全部账本。
    const size: number = Math.max(0, entry.bytes);
    if (count + 1 > activityLimit || bytes + size > activityBytes) {
      victims.push(entry.activityId);
    } else {
      count++;
      bytes += size;
    }
  }
  return victims;
}

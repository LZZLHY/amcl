/**
 * 恢复协调元数据：输入消费、历史投影和结果展示分别持久确认。
 * 文件只供启动器 owner 使用，不属于原始日志或分享正文；原生 journal 永不由此删除。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ledgerDirOf, LedgerOutcome, LedgerState, writeEvidenceTextAtomicAsync, ensureEvidenceTextDurableAsync,
  evidenceHex, stringToUtf8, ensureEvidenceDirectoryAsync } from 'commons';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { McSessionInfo } from './SessionMarker';

/** 单活动检查点；inputKey记录小型发布原文，不能用mtime/大小推断正文没有变化。 */
export interface SessionRecoveryState {
  schema: number;
  activityId: number;
  inputKey: string;
  /** 单独绑定生产者/归属身份，平台附件补齐不引起全部未归属事件重新发现。 */
  producerInputKey?: string;
  policy: number;
  outcomeRevision: number;
  historyRevision: number;
  presentationRevision: number;
  /** 历史补迁仅投影列表；真实退出/新证据义务才自动展示，不能伪造已显示回执。 */
  presentationMode?: string;
  /** 绑定提交产物；manifest业务key排除pin等独立元数据，不因用户保留日志触发重新裁决。 */
  committedOutcomeKey?: string;
  committedManifestRevision?: number;
  committedEvidenceRevision?: number;
  committedEvidenceKey?: string;
  outcome?: LedgerOutcome;
  session: McSessionInfo;
}

/** owner队列只保留未完成义务；冷启动迁移游标使失败后无需重新裁决已经完成的活动。 */
export interface SessionRecoveryQueue {
  schema: number;
  activeIds: number[];
  pendingIds: number[];
  resultIds: number[];
  bootstrapIds: number[];
  bootstrapCursor: number;
  /** ended历史迁移单独持久排队，不属于首页必要提交或自动错误Sheet。旧schema缺省为空。 */
  historyIds?: number[];
}

/** 严格数字主键过滤，损坏队列不能通过浮点/类型强转建立恢复义务。 */
export function recoveryIds(values: number[]): number[] {
  return Array.from(new Set<number>(values.filter((id: number): boolean =>
    typeof id === 'number' && Number.isSafeInteger(id) && id > 0)));
}

/** 小型JSON读失败必须抛出，只有确实不存在才返回空，避免把磁盘故障消费为空输入。 */
export async function readRecoveryTextAsync(path: string, limit: number = 262144): Promise<string> {
  let stat: fs.Stat;
  try { stat = await fs.stat(path); }
  catch (error) {
    // 当前SDK @ohos.file.fs.d.ts 明确13900002为ENOENT；权限/存储失败绝不能解释成不存在。
    if ((error as BusinessError).code === 13900002) return '';
    throw error as Error;
  }
  if (!stat.isFile() || stat.size <= 0 || stat.size > limit) throw new Error('恢复协调记录损坏或超过读取上限，原件保留');
  await ensureEvidenceTextDurableAsync(path);
  const text: string = await fs.readText(path);
  if (text.length === 0 || text.length > limit) throw new Error('恢复协调记录读取不完整，原件保留');
  return text;
}

/**
 * 小型发布正文计算真正异步SHA-256，固定长度key不会让合法检查点超过自身读取上限。
 * 缺失的可选发布记录使用空串的真实摘要：CryptoFramework的Md.update拒绝零长度DataBlob，
 * 官方Md契约允许省略update并直接digest。此处只跳过没有字节的更新，仍创建真实SHA256
 * 实例并异步完成digest；非空update或digest失败继续抛出，不能用占位key确认恢复输入。
 */
export async function recoveryTextDigestAsync(value: string): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  const bytes: Uint8Array = stringToUtf8(value);
  if (bytes.byteLength > 0) await digest.update({ data: bytes });
  return evidenceHex((await digest.digest()).data);
}

/** 没有旧检查点时只建立未消费状态；不借展示回执冒充已核验当前生产者输入。 */
export async function readRecoveryStateAsync(filesDir: string, session: McSessionInfo): Promise<SessionRecoveryState> {
  const text = await readRecoveryTextAsync(ledgerDirOf(filesDir, session.startedAt) + '/launcher/recovery-state.json');
  if (text.length === 0) return { schema: 1, activityId: session.startedAt, inputKey: '', policy: 0,
    outcomeRevision: 0, historyRevision: 0, presentationRevision: 0, session: session };
  const state = JSON.parse(text) as SessionRecoveryState;
  if (state === null || state.schema !== 1 || state.activityId !== session.startedAt
    || typeof state.inputKey !== 'string' || state.producerInputKey !== undefined && typeof state.producerInputKey !== 'string'
    || !Number.isSafeInteger(state.policy) || state.policy < 0
    || !Number.isSafeInteger(state.outcomeRevision)
    || !Number.isSafeInteger(state.historyRevision) || !Number.isSafeInteger(state.presentationRevision)
    || state.outcomeRevision < 0 || state.historyRevision < 0 || state.presentationRevision < 0
    || state.historyRevision > state.outcomeRevision || state.presentationRevision > state.outcomeRevision) {
    throw new Error('恢复检查点身份或消费游标无效，原件保留等待修复');
  }
  if (state.presentationMode !== undefined && state.presentationMode !== 'auto' && state.presentationMode !== 'history') {
    throw new Error('恢复检查点展示义务类型无效，原件保留');
  }
  const outcome = state.outcome;
  if (state.outcomeRevision > 0 && (outcome === undefined || outcome === null)
    || outcome !== undefined && (outcome === null || typeof outcome !== 'object'
      || [LedgerState.SUCCESS, LedgerState.FAILED, LedgerState.ABORTED, LedgerState.CRASHED, LedgerState.INTERRUPTED].indexOf(outcome.state) < 0
      || typeof outcome.source !== 'string' || typeof outcome.summary !== 'string'
      || outcome.errorKind !== undefined && typeof outcome.errorKind !== 'string'
      || outcome.endedAt !== undefined && (!Number.isSafeInteger(outcome.endedAt) || outcome.endedAt < 0))) {
    throw new Error('恢复检查点结局字段无效，原件保留等待修复');
  }
  if (state.committedOutcomeKey !== undefined && typeof state.committedOutcomeKey !== 'string'
    || state.committedEvidenceKey !== undefined && typeof state.committedEvidenceKey !== 'string'
    || state.committedManifestRevision !== undefined && (!Number.isSafeInteger(state.committedManifestRevision) || state.committedManifestRevision < 0)
    || state.committedEvidenceRevision !== undefined && (!Number.isSafeInteger(state.committedEvidenceRevision) || state.committedEvidenceRevision < 0)) {
    throw new Error('恢复检查点产物身份无效，原件保留等待修复');
  }
  state.session = session;
  return state;
}

/** 完整耐久写入后才能发布内存消费状态；异步核验并复用既有普通launcher目录，文件/链接冲突继续失败。 */
export async function writeRecoveryStateAsync(filesDir: string, state: SessionRecoveryState): Promise<void> {
  const directory: string = ledgerDirOf(filesDir, state.activityId) + '/launcher';
  const text: string = JSON.stringify(state);
  if (text.length > 262144) throw new Error('恢复检查点超过持久读取上限，原件和待办保留');
  await ensureEvidenceDirectoryAsync(directory);
  await writeEvidenceTextAtomicAsync(directory + '/recovery-state.json', text);
}

/** 队列只由启动器进程串行写；游戏进程通过已有单局journal发布，不抢写本文件。 */
export async function readRecoveryQueueAsync(filesDir: string): Promise<SessionRecoveryQueue> {
  const text = await readRecoveryTextAsync(filesDir + '/logs/recovery/queue.json', 2 * 1024 * 1024);
  if (text.length === 0) return { schema: 1, activeIds: [], pendingIds: [], resultIds: [], bootstrapIds: [], bootstrapCursor: 0 };
  const queue = JSON.parse(text) as SessionRecoveryQueue;
  if (queue === null || queue.schema !== 1 || !Array.isArray(queue.activeIds)
    || !Array.isArray(queue.pendingIds) || !Array.isArray(queue.resultIds) || !Array.isArray(queue.bootstrapIds)
    || !Number.isSafeInteger(queue.bootstrapCursor) || queue.bootstrapCursor < 0
    || queue.bootstrapCursor > queue.bootstrapIds.length) throw new Error('恢复队列损坏，保留现场并停止消费');
  if (queue.historyIds !== undefined && !Array.isArray(queue.historyIds)) throw new Error('恢复历史队列损坏，原件保留');
  queue.historyIds = queue.historyIds ?? [];
  for (const ids of [queue.activeIds, queue.pendingIds, queue.resultIds, queue.bootstrapIds, queue.historyIds]) {
    if (ids.some((id: number): boolean => typeof id !== 'number' || !Number.isSafeInteger(id) || id <= 0)) {
      throw new Error('恢复队列活动身份损坏，原件保留并停止消费');
    }
    if (new Set<number>(ids).size !== ids.length) throw new Error('恢复队列活动身份重复，迁移游标不可确认');
  }
  queue.activeIds = recoveryIds(queue.activeIds); queue.pendingIds = recoveryIds(queue.pendingIds);
  queue.resultIds = recoveryIds(queue.resultIds); queue.bootstrapIds = recoveryIds(queue.bootstrapIds);
  return queue;
}

/** 队列更新先异步确认可复用的普通目录；失败不得清marker、结束待办或向首页宣布恢复完成。 */
export async function writeRecoveryQueueAsync(filesDir: string, queue: SessionRecoveryQueue): Promise<void> {
  const text = JSON.stringify(queue);
  if (text.length > 2 * 1024 * 1024) throw new Error('恢复队列超过持久读取上限，原始待办保留');
  await ensureEvidenceDirectoryAsync(filesDir + '/logs/recovery');
  await writeEvidenceTextAtomicAsync(filesDir + '/logs/recovery/queue.json', text);
}

/** 日志分享编排唯一入口。页面只负责选择/预览，适配器不再自行收集日志。 */
import { common } from '@kit.AbilityKit';
import { EvidenceExportSnapshot, snapshotShareFiles, EVIDENCE_REDACTION_VERSION, AppLogger, LOG_DOMAIN_UI,
  ensureDirSync, writeEvidenceTextAtomic, evidenceTextDigest } from 'commons';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LogShareMetadata, LogShareRecord, LogSharePreflight, submitLogFiles, loadShareRecords,
  addShareRecord, isShareRecordCurrent, isValidLogShareId, canonicalLogShareUrl, LogShareSubmitResult,
  verifyLogShareFiles, verifyLogShareContents, updateShareVerification, logShareExportBudgetBytes,
  LOGSHARE_MULTIFILE_EXPANSION_BUDGET_BYTES } from './LogShareClient';
import { LogShareRequestError } from './LogShareErrors';
import { uploadCrashLog, CrashLogUploadResult, AuthorUploadIdentity } from './CrashLogUploader';

const pendingCredentials: Map<string, LogShareRecord> = new Map<string, LogShareRecord>();
const submissions: Map<string, Promise<LogShareRecord>> = new Map<string, Promise<LogShareRecord>>();
/** 作者反馈端点独立于 LogShare；这是其本地快照安全预算，不是 LogShare 服务端限额。 */
const AUTHOR_UPLOAD_LOCAL_SAFE_BYTES: number = 12 * 1024 * 1024;
/** 用具名槽承接异步回调写入，避免 ArkTS 把局部变量按初始 undefined 缩窄为 never。 */
interface ShareReceiptSlot { record?: LogShareRecord; }
const listeners: Map<number, (record: LogShareRecord) => void> = new Map<number, (record: LogShareRecord) => void>();
let listenerId: number = 0;

/** 只观察核对结果，不暴露任务控制权；sheet 关闭时解绑。 */
export function subscribeEvidenceShare(listener: (record: LogShareRecord) => void): number {
  const id: number = ++listenerId; listeners.set(id, listener); return id;
}
export function unsubscribeEvidenceShare(id: number): void { listeners.delete(id); }

/** 保存失败后保留内存凭据；下一次操作先补存，不能再次 POST 生成孤儿分享。 */
export async function flushPendingShareCredentials(context: common.UIAbilityContext): Promise<void> {
  for (const key of Array.from(pendingCredentials.keys())) {
    if (!key.startsWith(context.filesDir + '/')) continue;
    const record = pendingCredentials.get(key);
    if (record === undefined) continue;
    await addShareRecord(context, record);
    pendingCredentials.delete(key);
  }
}

export async function shareEvidenceSnapshot(context: common.UIAbilityContext,
  snapshot: EvidenceExportSnapshot, metadata: LogShareMetadata, preflight?: LogSharePreflight,
  allowUnknownRetry: boolean = false): Promise<LogShareRecord> {
  const key: string = context.filesDir + '/' + snapshot.activityId + '/' + snapshot.digest + '/' + (preflight?.apiBaseUrl ?? 'auto');
  const current = submissions.get(key);
  if (current !== undefined) return current;
  const task: Promise<LogShareRecord> = submitSnapshot_(context, snapshot, metadata, key, preflight, allowUnknownRetry);
  submissions.set(key, task);
  try { return await task; } finally { submissions.delete(key); }
}

async function submitSnapshot_(context: common.UIAbilityContext, snapshot: EvidenceExportSnapshot,
  metadata: LogShareMetadata, key: string, preflight?: LogSharePreflight, allowUnknownRetry: boolean = false): Promise<LogShareRecord> {
  await flushPendingShareCredentials(context);
  const records = await loadShareRecords(context);
  const existing = records.find((record: LogShareRecord): boolean => isShareRecordCurrent(record)
    && record.activityId === snapshot.activityId && record.snapshotDigest === snapshot.digest && record.redactionVersion === EVIDENCE_REDACTION_VERSION
    && (preflight === undefined || record.apiBaseUrl === preflight.apiBaseUrl));
  if (existing !== undefined) {
    if (existing.accepted === false) throw new LogShareRequestError('上次上传响应未通过校验，撤回凭据已保留；请先在分享记录核对或撤回', 'verification');
    return existing;
  }
  // files 解析器限制附件总量，实例 maxLength/maxLines 则逐文件检查；读取前先按
  // 冻结收据拒绝单文件超限，避免错误地用 maxLength 限制全部附件之和。
  if (preflight !== undefined && preflight.limits.ok && snapshot.files.some((file): boolean =>
    file.bytes > preflight.limits.maxBytes || file.lines > preflight.limits.maxLines)) {
    throw new LogShareRequestError('单个日志文件超过分享服务限额，请减少该文件或导出完整 ZIP', 'limit');
  }
  const exportBudget: number = preflight !== undefined && preflight.limits.ok
    ? logShareExportBudgetBytes(preflight.limits) : LOGSHARE_MULTIFILE_EXPANSION_BUDGET_BYTES;
  const files = await snapshotShareFiles(snapshot, exportBudget, Number.MAX_SAFE_INTEGER);
  metadata.snapshot = snapshot.digest;
  // 在 POST 前留下小型尝试记录。进程在响应前退出后，下一次快捷点击也不能盲重投。
  const attemptPath: string = shareAttemptPath_(context, snapshot.activityId + '/' + snapshot.digest);
  if (fs.accessSync(attemptPath) && fs.readTextSync(attemptPath) === 'pending' && !allowUnknownRetry) {
    throw new LogShareRequestError('上次发送结果尚未确认。请先检查分享记录；高级选项可在再次确认风险后重试。', 'unknown-outcome');
  }
  writeEvidenceTextAtomic(attemptPath, 'pending');
  const receiptSlot: ShareReceiptSlot = {};
  const result = await submitLogFiles(files, 'amcl-launcher', metadata, preflight, {
    deferVerification: true,
    onAccepted: async (receipt: LogShareSubmitResult): Promise<void> => {
      const accepted: LogShareRecord = {
        activityId: snapshot.activityId, id: receipt.id,
        url: receipt.ok ? receipt.url : canonicalLogShareUrl(receipt.apiBaseUrl ?? '', receipt.id), token: receipt.token,
        accepted: receipt.ok, sharedAt: Date.now(), versionId: metadata.mcVersion,
        apiBaseUrl: receipt.apiBaseUrl, storageTimeSec: receipt.storageTimeSec,
        selectedPaths: receipt.uploadedPaths ?? snapshot.files.map((file): string => file.name), snapshotRevision: snapshot.revision,
        snapshotDigest: snapshot.digest, redactionVersion: snapshot.redactionVersion,
        remoteFilesVerified: false, verificationError: receipt.ok ? '正在核对远端文件清单' : receipt.error,
        contentReceipts: receipt.uploadedReceipts, contentVerification: 'pending',
      };
      // token 到达即保存，失败只保留待保存队列，不等待远端 GET，更不重发 POST。
      receiptSlot.record = accepted; pendingCredentials.set(key, accepted);
      await addShareRecord(context, accepted);
      writeEvidenceTextAtomic(attemptPath, 'received'); pendingCredentials.delete(key);
    },
  });
  if (!result.ok) {
    if (result.errorStage !== 'unknown-outcome' && result.errorStage !== 'persist') writeEvidenceTextAtomic(attemptPath, 'not-sent-or-rejected');
    throw new LogShareRequestError(result.error, result.errorStage === 'persist' ? 'persist'
      : receiptSlot.record?.accepted === false ? 'verification' : result.errorStage ?? 'response',
      result.networkCode ?? 0, result.httpStatus ?? 0, result.apiCode ?? '');
  }
  const record = receiptSlot.record;
  if (record === undefined) throw new LogShareRequestError('接收凭据未保存，已停止后续操作', 'persist');
  // 链接在凭据落盘后立即可用；后台核对有自己的错误处理和撤回墓碑保护。
  verifySavedShare_(context, record);
  return record;
}

/** 路径只使用固定目录与 key 的摘要；尝试标记不包含日志正文、链接 token 或绝对源路径。 */
function shareAttemptPath_(context: common.UIAbilityContext, key: string): string {
  const directory: string = context.filesDir + '/logs/share-attempts';
  ensureDirSync(directory); return directory + '/' + evidenceTextDigest(key) + '.state';
}

/** 核对失败不取消已生成的分享。只保存状态，不再次上传任何文件。 */
async function verifySavedShare_(context: common.UIAbilityContext, record: LogShareRecord): Promise<void> {
  try {
    const result = record.contentReceipts !== undefined
      ? await verifyLogShareContents(record.id, record.contentReceipts, record.apiBaseUrl ?? '')
      : await verifyLogShareFiles(record.id, record.selectedPaths ?? [], record.apiBaseUrl ?? '');
    if (!await updateShareVerification(context, record, result)) return;
    record.remoteFilesVerified = result.verified; record.verificationError = result.warning;
    record.contentVerification = result.contentStatus ?? 'names-only'; record.receivedReceipts = result.received;
    for (const listener of Array.from(listeners.values())) {
      try { listener(record); } catch (e) { /* 页面失效不能影响其他观察者。 */ }
    }
  } catch (e) { AppLogger.warn('EvidenceShare', '分享已保存，后台核对状态暂未写入', e, LOG_DOMAIN_UI); }
}

/** 已知接收但本地保存失败时只补写原凭据；不重新计算快照或发 POST。 */
export async function retryPendingEvidenceShare(context: common.UIAbilityContext, activityId: number): Promise<LogShareRecord | undefined> {
  const key = Array.from(pendingCredentials.keys()).find((candidate: string): boolean =>
    candidate.startsWith(context.filesDir + '/') && pendingCredentials.get(candidate)?.activityId === activityId);
  const record = key === undefined ? undefined : pendingCredentials.get(key);
  await flushPendingShareCredentials(context);
  if (record !== undefined && (record.accepted === false || !isShareRecordCurrent(record))) {
    throw new LogShareRequestError('凭据已保存，但链接未通过校验或已过期，请在分享记录核对或撤回', 'verification');
  }
  if (record !== undefined && record.accepted !== false) verifySavedShare_(context, record);
  return record;
}

/** 作者反馈采用同一快照和 files[] 协议；用户选择此目标才会发送。 */
export async function submitEvidenceToAuthor(snapshot: EvidenceExportSnapshot,
  message: string, kind: string = 'manual', identity?: AuthorUploadIdentity): Promise<CrashLogUploadResult> {
  // 作者反馈端点不是 LogShare；沿用其独立的本地导出安全预算。
  const files = await snapshotShareFiles(snapshot, AUTHOR_UPLOAD_LOCAL_SAFE_BYTES, 200000);
  return uploadCrashLog({ files: files, kind: kind, message: message, identity: identity,
    metaJson: JSON.stringify({ 'activityId': snapshot.activityId, 'snapshot': snapshot.digest,
      'redactionVersion': snapshot.redactionVersion }) });
}

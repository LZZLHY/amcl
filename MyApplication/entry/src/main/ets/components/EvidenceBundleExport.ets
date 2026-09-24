/** ZIP 与在线分享复用同一份冻结、脱敏的多文件证据。 */
import { common } from '@kit.AbilityKit';
import { listSessionEvidence, EvidenceFileRecord, EvidenceUploadSelection, EvidenceExportSnapshot,
  createEvidenceExportSnapshot, disposeEvidenceExportSnapshot, normalizeEvidenceSelection, verifySessionCaptureRotations } from 'commons';
import { GameArchiveIO, ImportResult } from './GameArchiveIO';

export async function exportSessionEvidenceZip(context: common.UIAbilityContext,
  activityId: number, publicSummary: string): Promise<ImportResult> {
  let snapshot: EvidenceExportSnapshot | undefined = undefined;
  try {
    await verifySessionCaptureRotations(context.filesDir, activityId);
    const files: EvidenceFileRecord[] = listSessionEvidence(context.filesDir, activityId);
    const selection: EvidenceUploadSelection = { activityId: activityId, revision: 0,
      selectedFileIds: normalizeEvidenceSelection(files, files.map((file: EvidenceFileRecord): string => file.fileId)),
      createdAt: Date.now(), includePublicSummary: true };
    snapshot = await createEvidenceExportSnapshot(context.filesDir, context.tempDir, selection, publicSummary);
    return await GameArchiveIO.exportDirZip(context, snapshot.directory, 'amcl-evidence-' + activityId);
  } catch (e) {
    return { ok: false, cancelled: false, name: '', message: '证据导出失败：' + (e as Error).message };
  } finally {
    if (snapshot !== undefined) { try { disposeEvidenceExportSnapshot(snapshot); } catch (e) { /* 已清理 */ } }
  }
}

/**
 * 阅读页异步收据核验。枚举不重新签发收据，正文通过异步分块 hash 核对固定原始摘要。
 * 读取租约覆盖完整操作；离页取消会停止下一份读取，并始终关闭 fd/归还租约。
 * 外发继续调用原冻结快照服务，不把页面内的可读结论当作上传授权或完整性凭据。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { EvidenceFileRecord, EvidenceFileState, evidenceFileStamp, hashEvidenceRange,
  listSessionEvidence, acquireEvidenceLease, releaseEvidenceLease } from 'commons';

export async function loadActivityEvidence(filesDir: string, activityId: number,
  cancelled: () => boolean): Promise<EvidenceFileRecord[]> {
  acquireEvidenceLease(filesDir, activityId);
  try {
    const files: EvidenceFileRecord[] = listSessionEvidence(filesDir, activityId, false);
    for (const file of files) {
      if (cancelled()) throw new Error('活动读取已取消');
      if (file.verification !== 'pending') continue;
      let handle: fs.File | undefined = undefined;
      try {
        if (!(file.rawSha256 ?? '').length || file.rawBytes === undefined) throw new Error('历史文件没有固定的归档校验收据');
        const stamp: string = evidenceFileStamp(file.localPath);
        handle = await fs.open(file.localPath, fs.OpenMode.READ_ONLY);
        const stat = await fs.stat(handle.fd);
        if (stat.size !== file.rawBytes) throw new Error('文件长度与归档收据不符');
        const digest: string = await hashEvidenceRange(handle.fd, stat.size, -1, cancelled);
        if (digest !== file.rawSha256 || evidenceFileStamp(file.localPath) !== stamp) throw new Error('文件内容与归档收据不符或仍在变化');
        file.verification = 'verified';
      } catch (e) {
        file.verification = 'unverified'; file.state = EvidenceFileState.PARTIAL;
        file.reason = (e as Error).message;
      } finally { if (handle !== undefined) await fs.close(handle); }
    }
    return files;
  } finally { releaseEvidenceLease(filesDir, activityId); }
}

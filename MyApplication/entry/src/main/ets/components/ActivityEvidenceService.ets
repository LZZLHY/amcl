/**
 * 阅读页异步收据核验。枚举不重新签发收据，正文通过异步分块 hash 核对固定原始摘要。
 * 读取租约覆盖完整操作；离页取消会停止下一份读取，并始终关闭 fd/归还租约。
 * 外发继续调用原冻结快照服务，不把页面内的可读结论当作上传授权或完整性凭据。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { EvidenceFileRecord, EvidenceFileState, evidenceFileStampAsync, hashEvidenceRange,
  listSessionEvidenceAsync, acquireEvidenceLease, releaseEvidenceLease, ledgerManifestAsync, LedgerState } from 'commons';

/**
 * 仅缓存详情阅读的严格核验收据，不保存正文或打开句柄。最多128项，按最早插入项回收；
 * key包含路径+期望SHA/长度，value包含实际inode/纳秒mtime/ctime，修改/替换原件自动失效。
 * 外发冻结仍由原独立服务逐份核验，不消费此缓存，也不把阅读成功当成上传授权。
 */
const verifiedReadFiles: Map<string, string> = new Map<string, string>();
const MAX_VERIFIED_READ_FILES: number = 128;

/** 缺少任一高精度字段时不允许复用；秒级时间与长度相同不能证明原件没有被改写。 */
function preciseFileIdentity_(stat: fs.Stat): string {
  if (!stat.isFile() || stat.mtimeNs === undefined || stat.ctimeNs === undefined) return '';
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs) + ':' + String(stat.ctimeNs);
}

/** 严格收据只在打开句柄与路径身份均稳定时复用；失败项立即失效，缓存不延长资源生命周期。 */
function rememberVerifiedRead_(key: string, identity: string): void {
  if (identity.length === 0) return;
  if (!verifiedReadFiles.has(key) && verifiedReadFiles.size >= MAX_VERIFIED_READ_FILES) {
    verifiedReadFiles.delete(Array.from(verifiedReadFiles.keys())[0]);
  }
  verifiedReadFiles.set(key, identity);
}

export async function loadActivityEvidence(filesDir: string, activityId: number,
  cancelled: () => boolean): Promise<EvidenceFileRecord[]> {
  acquireEvidenceLease(filesDir, activityId);
  try {
    const manifest = await ledgerManifestAsync(filesDir, activityId);
    const activitySealed: boolean = manifest !== null && manifest.state !== LedgerState.RUNNING;
    // 枚举、指纹与正文核验都走真实异步端口，索引缺失时也不借同步递归回退阻塞页面。
    const files: EvidenceFileRecord[] = await listSessionEvidenceAsync(filesDir, activityId, false);
    for (const file of files) {
      if (cancelled()) throw new Error('活动读取已取消');
      if (file.verification !== 'pending') continue;
      let handle: fs.File | undefined = undefined;
      const cacheKey: string = file.localPath + '|' + (file.rawSha256 ?? '') + '|' + String(file.rawBytes);
      try {
        if (!(file.rawSha256 ?? '').length || file.rawBytes === undefined) throw new Error('历史文件没有固定的归档校验收据');
        const stamp: string = await evidenceFileStampAsync(file.localPath);
        handle = await fs.open(file.localPath, fs.OpenMode.READ_ONLY);
        const stat = await fs.stat(handle.fd);
        if (stat.size !== file.rawBytes) throw new Error('文件长度与归档收据不符');
        const openedIdentity: string = preciseFileIdentity_(stat);
        const pathStat = await fs.lstat(file.localPath);
        const pathIdentity: string = preciseFileIdentity_(pathStat);
        const cacheable: boolean = activitySealed && file.state === EvidenceFileState.COMPLETE && !pathStat.isSymbolicLink()
          && Number.isSafeInteger(file.rawBytes) && new RegExp('^[a-fA-F0-9]{64}$').test(file.rawSha256 ?? '')
          && openedIdentity.length > 0 && openedIdentity === pathIdentity;
        const reused: boolean = cacheable && verifiedReadFiles.get(cacheKey) === openedIdentity;
        if (!reused) {
          const digest: string = await hashEvidenceRange(handle.fd, stat.size, -1, cancelled);
          if (digest !== file.rawSha256) throw new Error('文件内容与归档收据不符或仍在变化');
        }
        // 即使命中缓存也复核打开后的fd与路径；rename/原位改写不能借命中窗口获得verified。
        const afterIdentity: string = preciseFileIdentity_(await fs.stat(handle.fd));
        const afterPath = await fs.lstat(file.localPath);
        if (await evidenceFileStampAsync(file.localPath) !== stamp
          || cacheable && (afterPath.isSymbolicLink() || openedIdentity !== afterIdentity
            || openedIdentity !== preciseFileIdentity_(afterPath))) throw new Error('文件内容与归档收据不符或仍在变化');
        if (cancelled()) throw new Error('活动读取已取消');
        if (cacheable) rememberVerifiedRead_(cacheKey, openedIdentity);
        file.verification = 'verified';
      } catch (e) {
        verifiedReadFiles.delete(cacheKey);
        if (cancelled()) throw e as Error;
        file.verification = 'unverified'; file.state = EvidenceFileState.PARTIAL;
        file.reason = (e as Error).message;
      } finally { if (handle !== undefined) await fs.close(handle); }
    }
    if (cancelled()) throw new Error('活动读取已取消');
    return files;
  } finally { releaseEvidenceLease(filesDir, activityId); }
}

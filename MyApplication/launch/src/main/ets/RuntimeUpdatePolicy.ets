import { RuntimeDefinition, RuntimeBuild, RuntimeInstallReceipt } from './RuntimeCatalogTypes';

/** JDK 更新的独立节流/延后策略。失败检查不写成功时间；时钟回拨不能永久压制检查。 */
export function runtimeCheckDue(now: number, lastSuccess: number): boolean {
  return lastSuccess <= 0 || !Number.isFinite(lastSuccess) || now < lastSuccess || now - lastSuccess >= 86400000;
}
/** 新的推荐目标可以重新提示；只增加镜像时 fingerprint 不变，不打断用户的延后选择。 */
export function runtimePromptDue(now: number, deferredAt: number, deferredTarget: string, target: string): boolean {
  return target !== deferredTarget || runtimeCheckDue(now,deferredAt);
}

/** 回退只作用于明确命中的受管构建；普通更新不额外限制，导入项由外层始终排除。 */
export function runtimeRecommendationApplies(runtime: RuntimeDefinition | undefined, installedTag: string,
  builds: RuntimeBuild[]): boolean {
  if (installedTag.startsWith('imported:')) return false;
  if (runtime === undefined || runtime.rollback === undefined) return true;
  for (const id of runtime.rollback.fromBuildIds) {
    const build = builds.find((b: RuntimeBuild): boolean => b.id === id && b.runtimeId === runtime.id);
    if (installedTag === id || (build !== undefined && build.legacyTags.indexOf(installedTag) >= 0)) return true;
  }
  return false;
}

/** buildId 相同但收据字节身份不同，必须显式标记不一致，不能退回同名戳而误判 current。 */
export function runtimeReceiptStamp(receipt: RuntimeInstallReceipt, build: RuntimeBuild, expectedTag: string): string {
  if (typeof receipt.buildId !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(receipt.buildId) ||
    typeof receipt.archiveSha256 !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(receipt.archiveSha256) ||
    !Number.isSafeInteger(receipt.archiveSizeBytes) || receipt.archiveSizeBytes <= 0) return 'identity-mismatch:invalid-receipt';
  if (receipt.buildId !== build.id) return receipt.buildId;
  return receipt.archiveSha256 === build.archive.sha256 && receipt.archiveSizeBytes === build.archive.sizeBytes
    ? expectedTag : 'identity-mismatch:' + receipt.buildId;
}

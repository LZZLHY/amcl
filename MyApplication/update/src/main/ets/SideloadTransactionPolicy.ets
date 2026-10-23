/** 自更新恢复判据。持久化文件读取后先核对结构和内部路径，不把历史文件当作可信命令输入。 */
import { SideloadUpdateTransaction, SideloadUpdatePhase } from './SideloadUpdateModels';
import { AppUpdatePolicy } from './AppUpdatePolicy';

export class SideloadTransactionPolicy {
  /** 拒绝旧格式、目录逃逸和不完整身份；调用方隔离损坏文件而不阻止主应用启动。 */
  static validate(value: SideloadUpdateTransaction, root: string, allowSameVersionTest: boolean = false): boolean {
    if (!value || (value.schema !== 1 && value.schema !== 2) || typeof value.id !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.id)) return false;
    // schema2 强制持久修订与尝试所有者；旧schema1保持只读可迁移，不能凭缺字段生成执行权。
    if (value.schema === 2 && (!Number.isSafeInteger(value.revision) || (value.revision ?? 0) < 1 ||
      typeof value.ownerAttemptId !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.ownerAttemptId))) return false;
    if (value.installId !== undefined && !new RegExp('^[0-9a-f]{32}$').test(value.installId)) return false;
    if (value.installProtocol !== undefined && value.installProtocol !== 1 && value.installProtocol !== 2) return false;
    if (value.activityId !== undefined && (!Number.isSafeInteger(value.activityId) || value.activityId <= 0)) return false;
    if (!value.asset || !Number.isInteger(value.asset.versionCode) || typeof value.sameVersionTest !== 'boolean' ||
      value.asset.versionCode < value.beforeVersionCode ||
      (value.asset.versionCode === value.beforeVersionCode && !(value.sameVersionTest && allowSameVersionTest) &&
        !AppUpdatePolicy.canInstall(value.beforeVersionCode,value.beforeVersionName ?? '',value.asset.versionCode,value.asset.versionName,value.updateChannel ?? '')) ||
      (value.sameVersionTest && value.asset.versionCode !== value.beforeVersionCode) ||
      !Number.isInteger(value.beforeVersionCode) || !Number.isInteger(value.beforeUid) || value.beforeUid <= 0 ||
      !new RegExp('^[0-9a-f]{64}$').test(value.asset.sha256)) return false;
    const directory = root + '/tasks/' + value.id;
    if (value.unsignedPath !== directory + '/unsigned.hap' || value.signedPath !== directory + '/signed.hap') return false;
    // ArkTS不能把enum当作运行时类对象交给Object.values，阶段集合明确列出并按枚举类型比较。
    const phases: SideloadUpdatePhase[] = [SideloadUpdatePhase.Idle, SideloadUpdatePhase.Resolving, SideloadUpdatePhase.Queued,
      SideloadUpdatePhase.PreparingMaterial, SideloadUpdatePhase.Transferring, SideloadUpdatePhase.DispatchIntent,
      SideloadUpdatePhase.StorageBlocked, SideloadUpdatePhase.Downloading, SideloadUpdatePhase.Verifying,
      SideloadUpdatePhase.Downloaded, SideloadUpdatePhase.Signing, SideloadUpdatePhase.Ready, SideloadUpdatePhase.Installing, SideloadUpdatePhase.AwaitingRestart,
      SideloadUpdatePhase.Verified, SideloadUpdatePhase.Failed, SideloadUpdatePhase.Cancelled, SideloadUpdatePhase.ConfirmationPending];
    if (phases.indexOf(value.phase) < 0 || !Number.isFinite(value.createdAt) ||
      !Number.isFinite(value.updatedAt) || value.updatedAt < value.createdAt) return false;
    if (value.phase === SideloadUpdatePhase.Ready || value.phase === SideloadUpdatePhase.Transferring || value.phase === SideloadUpdatePhase.DispatchIntent || value.phase === SideloadUpdatePhase.Installing || value.phase === SideloadUpdatePhase.Verified || value.phase === SideloadUpdatePhase.ConfirmationPending) {
      if (!new RegExp('^[0-9a-f]{64}$').test(value.signedSha256) ||
        !new RegExp('^[0-9a-f]{40}$').test(value.expectedPayloadIdentity)) return false;
    }
    if (value.phase === SideloadUpdatePhase.DispatchIntent || value.phase === SideloadUpdatePhase.Installing || value.phase === SideloadUpdatePhase.Verified || value.phase === SideloadUpdatePhase.ConfirmationPending) {
      if (!new RegExp('^[0-9a-f]{32}$').test(value.restartNonce)) return false;
    }
    return true;
  }

  /** 目标版本、UID 与编译载荷必须匹配；同 code 还必须证明实际版本名已从原发行改变。 */
  static confirms(value: SideloadUpdateTransaction, version: number, uid: number, payload: string, id: string, nonce: string,
    allowSameVersionTest: boolean = false, versionName: string = ''): boolean {
    const releaseChanged = !value.sameVersionTest && version === value.beforeVersionCode &&
      AppUpdatePolicy.canInstall(value.beforeVersionCode,value.beforeVersionName ?? '',value.asset.versionCode,value.asset.versionName,value.updateChannel ?? '') &&
      versionName === value.asset.versionName;
    const versionMatches = (!value.sameVersionTest && version > value.beforeVersionCode) ||
      releaseChanged || (value.sameVersionTest && allowSameVersionTest && version === value.beforeVersionCode);
    // 跨版本冷启动以系统版本、UID 和包内编译身份构成独立证明；携带了 Want 时仍须完整匹配。
    // 同一发行的诊断实验仍强制 nonce。生产同 code 由实际 versionName 改变及包内身份作证明；
    // 冷启动可确认目标已运行，但执行器的 BMS 终态仍由 Coordinator 单独核实才能清 fence。
    // schema2安装执行权与缓存目录独立，aa携带的是installId；schema1仍只匹配原事务ID。
    const executionId = value.installProtocol === 2 ? value.installId ?? '' : value.id;
    const launchMatches = id === executionId && nonce === value.restartNonce && nonce.length === 32;
    const manualUpgrade = !value.sameVersionTest && id === '' && nonce === '';
    return (value.phase === SideloadUpdatePhase.DispatchIntent || value.phase === SideloadUpdatePhase.Installing || value.phase === SideloadUpdatePhase.ConfirmationPending) && versionMatches &&
      version === value.asset.versionCode && uid === value.beforeUid && payload === value.expectedPayloadIdentity &&
      (launchMatches || manualUpgrade);
  }
}

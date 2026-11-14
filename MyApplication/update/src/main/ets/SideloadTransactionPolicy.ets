/** 自更新恢复判据。持久化文件读取后先核对结构和内部路径，不把历史文件当作可信命令输入。 */
import { SideloadUpdateTransaction, SideloadUpdatePhase, SideloadUpdateAsset } from './SideloadUpdateModels';
import { AppUpdatePolicy } from './AppUpdatePolicy';
import { parseAppRuntimeRequirements } from 'commons';

export class SideloadTransactionPolicy {
  /** 冷启动只恢复已经冻结的人工原件身份；此判据本身不创建新用户安装许可。 */
  static manualDeveloper(asset: SideloadUpdateAsset): boolean {
    const base = asset.baseStable;
    return asset.releaseKind === 'developer' && asset.source === 'website-upload' &&
      typeof asset.artifactId === 'string' && new RegExp('^[A-Za-z0-9_:-]{1,160}$').test(asset.artifactId) &&
      asset.tag === '' && asset.legacyUniversal === false && base !== undefined && base.tag === 'v' + base.versionName &&
      AppUpdatePolicy.validBaseline(asset.versionName,asset.versionCode,base.versionName,base.versionCode) &&
      asset.name === 'amcl-v' + asset.versionName + '-' + asset.product + '-unsigned.hap' &&
      asset.url === asset.websiteUrl && asset.websiteUrl === 'https://amcl.lovedhy.cn/api/packages/files/' + asset.sha256 + '/' + encodeURIComponent(asset.name);
  }
  /** 拒绝旧格式、目录逃逸和不完整身份；调用方隔离损坏文件而不阻止主应用启动。 */
  static validate(value: SideloadUpdateTransaction, root: string, allowSameVersionTest: boolean = false): boolean {
    if (!value || (value.schema !== 1 && value.schema !== 2) || typeof value.id !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.id)) return false;
    // schema2 强制持久修订与尝试所有者；旧schema1保持只读可迁移，不能凭缺字段生成执行权。
    if (value.schema === 2 && (!Number.isSafeInteger(value.revision) || (value.revision ?? 0) < 1 ||
      typeof value.ownerAttemptId !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.ownerAttemptId))) return false;
    if (value.installId !== undefined && (typeof value.installId !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.installId))) return false;
    if (value.installProtocol !== undefined && value.installProtocol !== 1 && value.installProtocol !== 2) return false;
    if(value.requiredHostProtocol!==undefined && (!Number.isInteger(value.requiredHostProtocol) || value.requiredHostProtocol<1 || value.requiredHostProtocol>999)) return false;
    if(value.requiredHostProtocols!==undefined && (!Array.isArray(value.requiredHostProtocols) || value.requiredHostProtocols.length>8 ||
      value.requiredHostProtocols.some((item: number,index: number): boolean => !Number.isInteger(item) || item<1 || item>999 || value.requiredHostProtocols!.indexOf(item)!==index))) return false;
    if (value.activityId !== undefined && (!Number.isSafeInteger(value.activityId) || value.activityId <= 0)) return false;
    if(value.runtimeIntentId!==undefined && (typeof value.runtimeIntentId!=='string' || !new RegExp('^[0-9a-f]{32}$').test(value.runtimeIntentId)))return false;
    if(value.subscriptionRevision!==undefined && (!Number.isSafeInteger(value.subscriptionRevision)||value.subscriptionRevision<0))return false;
    if (!value.asset || !Number.isInteger(value.asset.versionCode) || typeof value.sameVersionTest !== 'boolean' ||
      value.asset.versionCode < value.beforeVersionCode ||
      (value.asset.versionCode === value.beforeVersionCode && !(value.sameVersionTest && allowSameVersionTest) &&
        !AppUpdatePolicy.canInstall(value.beforeVersionCode,value.beforeVersionName ?? '',value.asset.versionCode,value.asset.versionName,value.updateChannel ?? '',SideloadTransactionPolicy.manualDeveloper(value.asset))) ||
      (value.sameVersionTest && value.asset.versionCode !== value.beforeVersionCode) ||
      !Number.isInteger(value.beforeVersionCode) || !Number.isInteger(value.beforeUid) || value.beforeUid <= 0 ||
      typeof value.asset.sha256 !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(value.asset.sha256)) return false;
    // journal是恢复输入；显式坏能力声明不能借历史缺字段默认值继续获得执行或回退资格。
    if(value.asset.runtimeHostProtocols!==undefined && (!Array.isArray(value.asset.runtimeHostProtocols) || value.asset.runtimeHostProtocols.length===0 ||
      value.asset.runtimeHostProtocols.length>8 || value.asset.runtimeHostProtocols.some((item: number,index: number): boolean =>
        !Number.isInteger(item) || item<1 || item>999 || value.asset.runtimeHostProtocols!.indexOf(item)!==index))) return false;
    if(value.asset.runtimePlanProtocol!==undefined && (!Number.isInteger(value.asset.runtimePlanProtocol) || value.asset.runtimePlanProtocol<0 || value.asset.runtimePlanProtocol>2)) return false;
    try { parseAppRuntimeRequirements(value.asset.runtimeRequiredCapabilities,value.asset.runtimeRequiredMajors); }
    catch (_) { return false; }
    const directory = root + '/tasks/' + value.id;
    if (value.unsignedPath !== directory + '/unsigned.hap' || value.signedPath !== directory + '/signed.hap') return false;
    // ArkTS不能把enum当作运行时类对象交给Object.values，阶段集合明确列出并按枚举类型比较。
    const phases: SideloadUpdatePhase[] = [SideloadUpdatePhase.Idle, SideloadUpdatePhase.Resolving, SideloadUpdatePhase.Queued,
      SideloadUpdatePhase.PreparingMaterial, SideloadUpdatePhase.Transferring, SideloadUpdatePhase.DispatchIntent,
      SideloadUpdatePhase.StorageBlocked, SideloadUpdatePhase.Downloading, SideloadUpdatePhase.Verifying,
      SideloadUpdatePhase.Downloaded, SideloadUpdatePhase.Signing, SideloadUpdatePhase.Ready, SideloadUpdatePhase.Installing, SideloadUpdatePhase.AwaitingRestart,
      SideloadUpdatePhase.Verified, SideloadUpdatePhase.Superseded, SideloadUpdatePhase.Failed, SideloadUpdatePhase.Cancelled, SideloadUpdatePhase.ConfirmationPending];
    if (phases.indexOf(value.phase) < 0 || !Number.isFinite(value.createdAt) ||
      !Number.isFinite(value.updatedAt) || value.updatedAt < value.createdAt) return false;
    if (value.phase === SideloadUpdatePhase.Ready || value.phase === SideloadUpdatePhase.Transferring || value.phase === SideloadUpdatePhase.DispatchIntent || value.phase === SideloadUpdatePhase.Installing || value.phase === SideloadUpdatePhase.Verified || value.phase === SideloadUpdatePhase.Superseded || value.phase === SideloadUpdatePhase.ConfirmationPending) {
      if (typeof value.signedSha256 !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(value.signedSha256) ||
        typeof value.expectedPayloadIdentity !== 'string' || !new RegExp('^[0-9a-f]{40}$').test(value.expectedPayloadIdentity)) return false;
      if(value.requiredHostProtocol!==undefined && (value.asset.runtimeHostProtocols ?? [1]).indexOf(value.requiredHostProtocol)<0) return false;
      if((value.requiredHostProtocols ?? []).some((item: number): boolean => (value.asset.runtimeHostProtocols ?? [1]).indexOf(item)<0)) return false;
    }
    if (value.phase === SideloadUpdatePhase.DispatchIntent || value.phase === SideloadUpdatePhase.Installing || value.phase === SideloadUpdatePhase.Verified || value.phase === SideloadUpdatePhase.Superseded || value.phase === SideloadUpdatePhase.ConfirmationPending) {
      if (typeof value.restartNonce !== 'string' || !new RegExp('^[0-9a-f]{32}$').test(value.restartNonce)) return false;
    }
    if(value.legacySuperseded!==undefined){
      const historical=value.legacySuperseded,current=historical?.current;
      if(value.phase!==SideloadUpdatePhase.Superseded||value.completion!==undefined||value.runtimeIntentId!==undefined||historical===null||historical.schema!==1||
        !Number.isFinite(historical.recordedAt)||historical.recordedAt<=0||current===undefined||current===null||current.product!==value.asset.product||current.uid!==value.beforeUid||
        !Number.isSafeInteger(current.versionCode)||current.versionCode<value.asset.versionCode||typeof current.versionName!=='string'||current.versionName.length===0||
        typeof current.sourceRevision!=='string'||!new RegExp('^[0-9a-f]{40}$').test(current.sourceRevision)||!Array.isArray(current.runtimeHostProtocols)||current.runtimeHostProtocols.length===0||current.runtimeHostProtocols.length>8||
        current.runtimeHostProtocols.some((item: number,index: number): boolean=>!Number.isInteger(item)||item<1||item>999||current.runtimeHostProtocols.indexOf(item)!==index))return false;
    }
    if(value.phase===SideloadUpdatePhase.Superseded&&value.completion===undefined&&value.legacySuperseded===undefined)return false;
    if(value.completion!==undefined){
      const completion=value.completion,event=completion?.event;
      if((value.phase!==SideloadUpdatePhase.Verified && value.phase!==SideloadUpdatePhase.Superseded) || completion===null || completion.schema!==1 || event===null || event===undefined ||
        event.transactionId!==value.id || event.installId!==value.installId || event.assetSha256!==value.asset.sha256 ||
        event.product!==value.asset.product || event.versionName!==value.asset.versionName || event.versionCode!==value.asset.versionCode ||
        event.sourceRevision!==value.expectedPayloadIdentity || event.uid!==value.beforeUid || event.runtimeIntentId!==value.runtimeIntentId ||
        !Number.isFinite(event.verifiedAt) || event.verifiedAt<=0 || !Number.isInteger(completion.terminalCode) ||
        ['bms-success','bms-failure','pre-install-failed','revoked'].indexOf(completion.terminalKind)<0 ||
        typeof completion.terminalBmSubmitted!=='boolean' || typeof completion.executionReleased!=='boolean' ||
        typeof completion.runtimeClosed!=='boolean' || typeof completion.subscriptionCommitted!=='boolean' ||
        typeof completion.intentConfirmed!=='boolean' || typeof completion.done!=='boolean' || ['target','superseded'].indexOf(completion.mode)<0 ||
        completion.subscriptionResult!==undefined && ['applied','newer-selection-or-legacy','not-required'].indexOf(completion.subscriptionResult)<0 ||
        (value.phase===SideloadUpdatePhase.Superseded)!==(completion.mode==='superseded') ||
        completion.done && !(completion.executionReleased&&completion.runtimeClosed&&completion.subscriptionCommitted&&completion.intentConfirmed))return false;
      if(completion.mode==='superseded'){
        const current=completion.superseder;
        if(current===undefined || current===null || current.product!==value.asset.product || current.uid!==value.beforeUid ||
          !Number.isSafeInteger(current.versionCode) || current.versionCode<=value.asset.versionCode || typeof current.versionName!=='string' || current.versionName.length===0 ||
          typeof current.sourceRevision!=='string' || !new RegExp('^[0-9a-f]{40}$').test(current.sourceRevision) || !Array.isArray(current.runtimeHostProtocols) || current.runtimeHostProtocols.length===0 || current.runtimeHostProtocols.length>8 ||
          current.runtimeHostProtocols.some((item: number,index: number): boolean=>!Number.isInteger(item)||item<1||item>999||current.runtimeHostProtocols.indexOf(item)!==index))return false;
      }
    }
    return true;
  }

  /** 目标版本、UID 与编译载荷必须匹配；同 code 还必须证明实际版本名已从原发行改变。 */
  static confirms(value: SideloadUpdateTransaction, version: number, uid: number, payload: string, id: string, nonce: string,
    allowSameVersionTest: boolean = false, versionName: string = ''): boolean {
    const releaseChanged = !value.sameVersionTest && version === value.beforeVersionCode &&
      AppUpdatePolicy.canInstall(value.beforeVersionCode,value.beforeVersionName ?? '',value.asset.versionCode,value.asset.versionName,value.updateChannel ?? '',SideloadTransactionPolicy.manualDeveloper(value.asset)) &&
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

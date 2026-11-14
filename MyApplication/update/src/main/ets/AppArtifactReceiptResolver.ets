/**
 * 手动原始 HAP 的精确官网收据。输入 SHA 来自已复制到内部目录的实际文件，服务端只返回
 * 该产品的同一原件；本模块不查询最新版、不写推荐缓存，也不为路由直接授予安装资格。
 */
import { AppArtifactReceipt, SideloadUpdateAsset } from './SideloadUpdateModels';
import { AppUpdatePolicy } from './AppUpdatePolicy';
import { GitHubUpdateAssetResolver } from './GitHubUpdateAssetResolver';
import { UpdateManifest } from './UpdateChecker';
import { parseAppRuntimeRequirements } from 'commons';

export class AppArtifactReceiptResolver {
  /** 精确地址不接受任意 URL；只有从实际文件计算的64位摘要可以进入查询。 */
  static url(product: string, sha256: string): string {
    if (typeof sha256 !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(sha256)) throw new Error('安装包摘要无效');
    return 'https://amcl.lovedhy.cn/api/packages/artifact?product=' +
      GitHubUpdateAssetResolver.assetProduct(product) + '&sha256=' + sha256;
  }

  /**
   * 解析来源分支并冻结身份。GitHub 来源仍严格匹配既有仓库、tag和文件名；人工开发者
   * 原件不伪造 GitHub 地址或镜像记录。撤回、错误产品、损坏审计及基线漂移均失败关闭。
   */
  static parse(body: string, product: string, sha256: string): SideloadUpdateAsset {
    const receipt = JSON.parse(body) as AppArtifactReceipt;
    const wanted = GitHubUpdateAssetResolver.assetProduct(product);
    if (!receipt || receipt.schema !== 1 || receipt.kind !== 'app-artifact' || receipt.verified !== true ||
      (receipt.revoked !== undefined && typeof receipt.revoked !== 'boolean') || receipt.revoked === true || receipt.product !== wanted || receipt.sha256 !== sha256 ||
      !new RegExp('^[0-9a-f]{64}$').test(receipt.sha256) ||
      typeof receipt.artifactId !== 'string' || !new RegExp('^[A-Za-z0-9_:-]{1,160}$').test(receipt.artifactId) ||
      !Number.isSafeInteger(receipt.sizeBytes) || receipt.sizeBytes < 1 || receipt.sizeBytes > 2 * 1024 * 1024 * 1024 ||
      !Number.isSafeInteger(receipt.versionCode) || receipt.versionCode < 1 ||
      receipt.releaseKind !== AppUpdatePolicy.releaseKind(receipt.versionName)) throw new Error('官方原件摘要或收据身份无效');
    const file = 'amcl-v' + receipt.versionName + '-' + wanted + '-unsigned.hap';
    const legacy = 'amcl-v' + receipt.versionName + '-unsigned.hap';
    if ((receipt.name !== file && !(wanted === 'sideload' && receipt.releaseKind !== 'developer' && receipt.name === legacy)) ||
      receipt.websiteUrl !== 'https://amcl.lovedhy.cn/api/packages/files/' + sha256 + '/' + encodeURIComponent(receipt.name)) {
      throw new Error('官方原件地址不匹配');
    }
    const audit = receipt.audit;
    if (!audit || audit.bundleName !== 'com.amcl.launcher' || audit.product !== wanted ||
      audit.versionName !== receipt.versionName || audit.versionCode !== receipt.versionCode ||
      typeof audit.sourceRevision !== 'string' || !new RegExp('^[0-9a-f]{40}$').test(audit.sourceRevision) || !Number.isInteger(audit.minApi) || audit.minApi < 1 ||
      audit.abi !== 'arm64-v8a' || !Array.isArray(audit.deviceTypes) || audit.deviceTypes.length === 0 ||
      audit.deviceTypes.some((value: string): boolean => typeof value !== 'string' || value.length === 0)) throw new Error('官方原件缺少真实包内审计');
    // 仅真正的历史缺字段可使用保守默认；显式null/错误类型是坏收据，不能吞掉。
    const protocols = audit.runtimeHostProtocols === undefined ? [1] : audit.runtimeHostProtocols;
    const planProtocol=audit.runtimePlanProtocol === undefined ? 0 : audit.runtimePlanProtocol;
    const requirements = parseAppRuntimeRequirements(audit.runtimeRequiredCapabilities,audit.runtimeRequiredMajors);
    if(!Number.isInteger(planProtocol) || planProtocol<0 || planProtocol>2)throw new Error('原件App/JDK恢复协议声明无效');
    if (!Array.isArray(protocols) || protocols.length === 0 || protocols.length > 8 ||
      protocols.some((value: number): boolean => !Number.isSafeInteger(value) || value < 1 || value > 999) ||
      protocols.some((value: number, index: number): boolean => protocols.indexOf(value) !== index)) throw new Error('原件运行时宿主声明无效');
    let tag = receipt.tag ?? '', url = receipt.githubUrl ?? '';
    if (receipt.releaseKind === 'developer') {
      const base = receipt.baseStable;
      if (receipt.source !== 'website-upload' || tag !== '' || url !== '' || base === undefined ||
        base.tag !== 'v' + base.versionName || !AppUpdatePolicy.validBaseline(receipt.versionName, receipt.versionCode, base.versionName, base.versionCode)) {
        throw new Error('开发者原件来源或正式基线无效');
      }
      // 内部 tag 留空，不能把一个官网 releaseId 伪装成可由 GitHub 发现的 tag。
      url = receipt.websiteUrl;
    } else {
      if ((receipt.releaseKind !== 'stable' && receipt.releaseKind !== 'preview') || receipt.source !== 'github' ||
        tag !== 'v' + receipt.versionName || url !== 'https://github.com/LZZLHY/amcl/releases/download/' +
          encodeURIComponent(tag) + '/' + encodeURIComponent(receipt.name)) throw new Error('GitHub 原件来源无效');
      if (receipt.releaseKind === 'preview' && receipt.baseStable !== undefined &&
        !AppUpdatePolicy.validBaseline(receipt.versionName, receipt.versionCode, receipt.baseStable.versionName, receipt.baseStable.versionCode)) {
        throw new Error('预览原件正式基线无效');
      }
    }
    return { tag: tag, name: receipt.name, url: url, websiteUrl: receipt.websiteUrl,
      sha256: sha256, sizeBytes: receipt.sizeBytes, versionCode: receipt.versionCode, versionName: receipt.versionName,
      product: wanted, legacyUniversal: receipt.name === legacy, releaseKind: receipt.releaseKind,
      source: receipt.source, artifactId: receipt.artifactId, baseStable: receipt.baseStable,
      sourceRevision: audit.sourceRevision, runtimeHostProtocols: protocols.slice().sort((left: number,right: number): number => left-right),runtimePlanProtocol:planProtocol,
      runtimeRequiredCapabilities:requirements.runtimeRequiredCapabilities,runtimeRequiredMajors:requirements.runtimeRequiredMajors };
  }

  /** 仅用作手动面板展示；没有 delivery，普通推荐解析不能消费该值启动开发者安装。 */
  static manifest(asset: SideloadUpdateAsset, channel: string): UpdateManifest {
    return { tag: asset.tag, versionCode: asset.versionCode, versionName: asset.versionName,
      url: asset.websiteUrl ?? '', notes: asset.releaseKind === 'developer' ? '开发者构建，仅通过手动安装；安装后暂停应用自动更新检查。' : '',
      mandatory: false, schema: 1, date: '', sizeBytes: asset.sizeBytes, changelogUrl: '', notesEntries: [],
      updateChannel: AppUpdatePolicy.channel(channel), prerelease: asset.releaseKind !== 'stable' };
  }
}

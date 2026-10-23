/**
 * 从既有AMCL发布仓的指定tag取得安装资产身份，避免把发布页URL当成HAP。
 * GitHub返回的SHA-256用于下载校验，产品、文件名和仓库路径同时约束；不携带开发者令牌。
 */
import { http } from '@kit.NetworkKit';
import { UpdateManifest } from './UpdateChecker';
import { SideloadUpdateAsset, SideloadMirror } from './SideloadUpdateModels';
import { AppUpdatePolicy } from './AppUpdatePolicy';

export class GitHubUpdateAssetResolver {
  /** 默认工程消费通用sideload资产；desktop必须有明确desktop资产，不能按渠道混选。 */
  static assetProduct(product: string): string {
    if (product === 'default' || product === 'sideload') return 'sideload';
    if (product === 'desktop') return 'desktop';
    throw new Error('当前产品不使用侧载自更新');
  }

  /** 纯解析与选择便于用错产品、缺摘要、重复资产做真实负向验收。 */
  static parse(body: string, manifest: UpdateManifest, product: string): SideloadUpdateAsset {
    const wanted = GitHubUpdateAssetResolver.assetProduct(product);
    const object = JSON.parse(body) as Record<string, Object>;
    if (object['tag_name'] !== manifest.tag || !Array.isArray(object['assets'])) throw new Error('发布版本身份不一致');
    if(object['draft']===true || typeof object['prerelease']!=='boolean' || object['prerelease']!==AppUpdatePolicy.prerelease(manifest.tag) ||
      !AppUpdatePolicy.accepts(manifest.tag,manifest.updateChannel,object['prerelease'] as boolean,manifest.updateChannel ?? 'stable')) throw new Error('发布阶段与当前更新通道不一致');
    const assets = object['assets'] as Record<string, Object>[];
    const explicitName = 'amcl-' + manifest.tag + '-' + wanted + '-unsigned.hap';
    const legacyName = 'amcl-' + manifest.tag + '-unsigned.hap';
    let matches = assets.filter((asset: Record<string, Object>): boolean => asset['name'] === explicitName);
    let legacy = false;
    if (matches.length === 0 && wanted === 'sideload') {
      matches = assets.filter((asset: Record<string, Object>): boolean => asset['name'] === legacyName);
      legacy = matches.length > 0;
    }
    if (matches.length !== 1) throw new Error('未找到唯一的本产品更新包');
    const selected = matches[0];
    const url = String(selected['browser_download_url'] ?? '');
    const name = String(selected['name'] ?? '');
    const prefix = 'https://github.com/LZZLHY/amcl/releases/download/' + encodeURIComponent(manifest.tag) + '/';
    if (url !== prefix + encodeURIComponent(name)) throw new Error('更新包不是指定仓库的发布资产');
    const digest = String(selected['digest'] ?? '');
    if (!new RegExp('^sha256:[0-9a-fA-F]{64}$').test(digest)) throw new Error('发布资产缺少可靠的SHA-256');
    const size = selected['size'];
    if (typeof size !== 'number' || !Number.isInteger(size) || size <= 0 || size > 2 * 1024 * 1024 * 1024) {
      throw new Error('更新包大小无效');
    }
    return { tag: manifest.tag, name: name, url: url, sha256: digest.substring(7).toLowerCase(),
      sizeBytes: size, versionCode: manifest.versionCode, versionName: manifest.versionName,
      product: wanted, legacyUniversal: legacy };
  }

  /** 仅向固定公开GitHub API请求指定tag，错误阻止自动安装，原浏览器下载入口仍可使用。 */
  static async resolve(manifest: UpdateManifest, product: string): Promise<SideloadUpdateAsset> {
    if (manifest.delivery !== undefined) return GitHubUpdateAssetResolver.fromDelivery(manifest, product);
    if (!manifest.tag || manifest.tag.length > 128 || !Number.isInteger(manifest.versionCode)) throw new Error('更新版本信息无效');
    const request = http.createHttp();
    try {
      const result = await request.request('https://api.github.com/repos/LZZLHY/amcl/releases/tags/' + encodeURIComponent(manifest.tag),
        { method: http.RequestMethod.GET, header: { 'Accept': 'application/vnd.github+json', 'User-Agent': 'AMCL' },
          expectDataType: http.HttpDataType.STRING, connectTimeout: 15000, readTimeout: 15000 });
      if (result.responseCode !== 200 || typeof result.result !== 'string' || result.result.length > 512 * 1024) {
        throw new Error('无法核实发布资产，请稍后重试');
      }
      return GitHubUpdateAssetResolver.parse(result.result, manifest, product);
    } finally { request.destroy(); }
  }

  /** 官网发布就绪收据携带完整资产身份，客户端不再依赖匿名 GitHub API 临时解析。 */
  static fromDelivery(manifest: UpdateManifest, product: string): SideloadUpdateAsset {
    const wanted = GitHubUpdateAssetResolver.assetProduct(product);
    const delivery = manifest.delivery;
    if (delivery === undefined || delivery.schema !== 1 || delivery.ready !== true || !Array.isArray(delivery.assets)) {
      throw new Error('更新资源尚未同步完成');
    }
    const matches = delivery.assets.filter((asset: SideloadUpdateAsset): boolean => asset.product === wanted);
    if (matches.length !== 1) throw new Error('本产品更新包尚未同步完成');
    const asset = matches[0];
    const prefix = 'https://github.com/LZZLHY/amcl/releases/download/' + encodeURIComponent(manifest.tag) + '/';
    const name = 'amcl-' + manifest.tag + '-' + wanted + '-unsigned.hap';
    const legacy = 'amcl-' + manifest.tag + '-unsigned.hap';
    if (asset.tag !== manifest.tag || asset.versionCode !== manifest.versionCode || asset.versionName !== manifest.versionName ||
      (asset.name !== name && !(wanted === 'sideload' && asset.name === legacy)) ||
      asset.url !== prefix + encodeURIComponent(asset.name) || !new RegExp('^[0-9a-f]{64}$').test(asset.sha256) ||
      !Number.isInteger(asset.sizeBytes) || asset.sizeBytes < 1 || asset.sizeBytes > 2 * 1024 * 1024 * 1024 ||
      asset.websiteUrl !== 'https://amcl.lovedhy.cn/api/packages/files/' + asset.sha256 + '/' + encodeURIComponent(asset.name) ||
      !Array.isArray(asset.mirrors)) throw new Error('更新发布身份校验失败');
    const mirrors = asset.mirrors.filter((mirror: SideloadMirror): boolean => mirror.ready === true && mirror.projectId === 'amcl' &&
      ((mirror.provider === 'miawa' && mirror.filePath === 'amcl/' + manifest.tag + '/' + asset.name) ||
       (mirror.provider === 'fyhub' && typeof mirror.assetId === 'string' && new RegExp('^[A-Za-z0-9_:-]{1,128}$').test(mirror.assetId))));
    if (mirrors.length === 0 || mirrors.length > 2 || (mirrors.length === 2 && mirrors[0].provider === mirrors[1].provider)) {
      throw new Error('尚无已就绪的主镜像');
    }
    return { tag: asset.tag, versionCode: asset.versionCode, versionName: manifest.versionName, product: wanted,
      name: asset.name, url: asset.url, sha256: asset.sha256, sizeBytes: asset.sizeBytes, legacyUniversal: asset.name === legacy,
      websiteUrl: asset.websiteUrl, mirrors: mirrors };
  }
}

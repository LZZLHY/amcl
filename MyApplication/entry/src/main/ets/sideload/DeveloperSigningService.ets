/**
 * 华为授权后的自动签名准备。保留现装私钥、复用有效证书，缺失或过期时自动申请。
 * 不创建同包名的新应用，不删除旧证书/Profile，不把登录成功当作覆盖安装身份成立。
 * 调试Profile不要求AGC注册身份；只在需要换钥时尝试注册身份，最终仍核实际覆盖身份。
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import testNapi from 'libentry.so';
import { DeveloperAuthSession } from './DeveloperAuthSession';
import { SigningVault, SigningDraft, SigningMaterialBundle } from './SigningVault';
import { SideloadFiles } from './SideloadFiles';
import { SigningPreparationError, SigningPreparationIssue } from './SigningPreparationError';
import { OriginalSigningRecovery } from './OriginalSigningRecovery';

/** 对外请求采用显式DTO，避免ArkTS把Record<Object>的值推断为无声明对象。 */
interface CertificateRequest { csr: string; certName: string; certType: string; }
interface DeviceRequest { deviceName: string; udid: string; deviceType: string; }
interface ProfileRequest {
  certList: string[]; packageName: string; deviceList: string[]; provisionName: string;
  appId: string; provisionType: string; reqSource: string; aclPermissionList: string[];
}
interface MaterialUrlRequest { sourceUrls: string; }
interface ProfileIdentity { bundleName: string; appIdentifier: string; }
interface TestProfileRequest {
  certList: string[]; packageName: string; deviceList: string[]; provisionName: string; aclPermissionList: string[];
}

export class DeveloperSigningService {
  /**
   * tools已由更新服务校验固定摘要。活动检查在每次外部动作后执行；取消不会触发后续云端写入。
   * 返回材料仅进入HUKS保险库，ViewModel不接触私钥、密码、CSR或认证头。
   */
  static async prepare(context: common.UIAbilityContext, auth: DeveloperAuthSession, vault: SigningVault,
    udid: string, signer: string, runner: string, jdk: string, assertActive: () => void,
    refreshMaterial: boolean = false): Promise<void> {
    const installed = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
    const identifier = installed.signatureInfo.appIdentifier;
    if (refreshMaterial) vault.retireDraft(); // 仅退役未完成草稿，现装私钥仍保留在完整保险库中。
    let draft = await vault.readDraft(); assertActive();
    if (draft !== undefined && draft.appIdentifier !== identifier) { vault.retireDraft(); draft = undefined; }
    if (draft === undefined) {
      draft = await OriginalSigningRecovery.restore(context, auth, vault.available() ? vault : undefined,
        installed.name, installed.signatureInfo.appId, identifier, signer, runner, jdk,
        (team: string, source: string): Promise<Uint8Array> => DeveloperSigningService.download(auth, team, source),
        assertActive, vault.available());
      assertActive();
    }
    let team = draft !== undefined && auth.teamIds().includes(draft.teamId) ? draft.teamId : auth.preferredTeamId();
    if (!team) throw new SigningPreparationError(SigningPreparationIssue.Permission, '当前授权没有可用开发者团队，请重新登录后重试');
    const originalKey = draft?.originalAppId === installed.signatureInfo.appId;
    let registeredIdentity = false;
    // 同公钥调试更新与HoKit一样直接申请Test Profile，不把AGC应用列表变成额外前置条件。
    // 无法续用公钥时，注册身份是可选的换钥路径；查询不可用仍可尝试官方调试Profile。
    if (!originalKey && identifier) {
      for (const candidate of auth.teamIds()) {
        try {
          const response = await auth.request('/api/amis/app-manage/v1/manage/app/brief-info/list?packageNames=' +
            encodeURIComponent(installed.name), http.RequestMethod.GET, candidate);
          assertActive();
          const apps = response['appInfos'] as Record<string, Object>[];
          if (Array.isArray(apps) && apps.some((app: Record<string, Object>): boolean =>
            app !== null && typeof app === 'object' && typeof app['appId'] === 'string' && app['appId'] === identifier)) {
            team = candidate; registeredIdentity = true; break;
          }
        } catch (error) {
          assertActive();
          if (DeveloperAuthSession.isExpired(error as Error)) throw error as Error;
          // 该可选查询失败不等于账号错误。实际证书/Profile请求仍会报告明确的服务或权限错误。
        }
      }
    }
    if (draft === undefined) draft = await DeveloperSigningService.generateDraft(context, team, identifier, signer, runner, jdk, assertActive);
    if (draft.teamId !== team) {
      draft.teamId = team; draft.originalCertificateId = undefined; draft.originalCertificateObjectId = undefined;
      draft.profileObjectId = undefined; draft.profileCertificateId = undefined; draft.profileDeviceId = undefined;
    }
    await vault.saveDraft(draft, assertActive); assertActive();
    const certName = 'amcl_update_' + draft.id;
    // 官方证书列表使用POST空JSON对象，与调试侧载工具的请求正文一致。
    const certificateQuery: Record<string, string> = {};
    const certificates = await auth.request('/api/cps/harmony-cert-manage/v1/cert/list', http.RequestMethod.POST, team, certificateQuery);
    const reusable = draft.originalCertificateId !== undefined && Number.isFinite(draft.originalCertificateValidFrom) &&
      Number.isFinite(draft.originalCertificateValidUntil) && Date.now() >= (draft.originalCertificateValidFrom ?? Infinity) &&
      Date.now() < (draft.originalCertificateValidUntil ?? 0);
    let certificate = reusable ? DeveloperSigningService.find(certificates['certList'], 'id', draft.originalCertificateId ?? '') : undefined;
    if (certificate === undefined) certificate = DeveloperSigningService.find(certificates['certList'], 'certName', certName);
    assertActive();
    if (certificate === undefined) {
      const request: CertificateRequest = { csr: draft.csr, certName: certName, certType: '1' };
      await auth.request('/api/cps/harmony-cert-manage/v1/cert/add', http.RequestMethod.POST, team, request); assertActive();
      const created = await auth.request('/api/cps/harmony-cert-manage/v1/cert/list', http.RequestMethod.POST, team, certificateQuery);
      certificate = DeveloperSigningService.find(created['certList'], 'certName', certName);
    }
    if (certificate === undefined || !certificate['id'] || !certificate['certObjectId']) throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务尚未返回有效证书，请重试更新');
    const certificateId = String(certificate['id']);
    const certificateBytes = await DeveloperSigningService.download(auth, team, String(certificate['certObjectId'])); assertActive();
    let deviceId = '';
    for (let page = 1; page <= 20; page++) {
      const response = await auth.request('/api/cps/device-manage/v1/device/list?encodeFlag=0&start=' + page + '&pageSize=100', http.RequestMethod.GET, team); assertActive();
      const list = response['list'] as Record<string, Object>[];
      const device = DeveloperSigningService.find(list, 'udid', udid, true);
      if (device !== undefined) { deviceId = String(device['id'] ?? ''); break; }
      if (!Array.isArray(list) || list.length < 100) break;
      if (page === 20) throw new SigningPreparationError(SigningPreparationIssue.Service, '暂时无法完成设备授权查询，请重试更新');
    }
    if (!deviceId) {
      // 官方IDE将手机、平板都映射为注册类型4，接口不接收UI设备名称phone/tablet。
      const request: DeviceRequest = { deviceName: 'AMCL_' + draft.id.substring(0, 12), udid: udid, deviceType: '4' };
      await auth.request('/api/cps/device-manage/v1/device/add', http.RequestMethod.POST, team, request); assertActive();
      const response = await auth.request('/api/cps/device-manage/v1/device/list?encodeFlag=0&start=1&pageSize=100', http.RequestMethod.GET, team);
      const device = DeveloperSigningService.find(response['list'], 'udid', udid, true);
      if (device !== undefined) deviceId = String(device['id'] ?? '');
    }
    if (!deviceId) throw new SigningPreparationError(SigningPreparationIssue.Service, '设备授权尚未准备完成，请重试更新');
    const mode = registeredIdentity ? 'registered' : 'debug';
    let source = '';
    if (draft.profileObjectId && draft.profileCertificateId === certificateId && draft.profileDeviceId === deviceId &&
      (draft.profileMode ?? 'debug') === mode) source = draft.profileObjectId;
    if (!source) {
      let profile: Record<string, Object>;
      if (registeredIdentity) {
        const request: ProfileRequest = { certList: [certificateId], packageName: installed.name, deviceList: [deviceId],
          provisionName: certName, appId: identifier, provisionType: '1', reqSource: 'IDE',
          aclPermissionList: ['ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY'] };
        profile = await auth.request('/api/cps/provision-manage/v1/provision/add', http.RequestMethod.POST, team, request);
      } else {
        const request: TestProfileRequest = { certList: [certificateId], packageName: installed.name, deviceList: [deviceId],
          provisionName: installed.name, aclPermissionList: ['ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY'] };
        profile = await auth.request('/api/cps/provision-manage/v1/ide/test/provision/add', http.RequestMethod.POST, team, request);
      }
      assertActive();
      if (profile['provisionInfo'] !== undefined) profile = profile['provisionInfo'] as Record<string, Object>;
      source = String(profile['provisionObjectId'] ?? profile['provisionFileUrl'] ?? '');
    }
    if (!source) throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务尚未返回应用授权，请重试更新');
    draft.profileObjectId = source; draft.profileCertificateId = certificateId; draft.profileDeviceId = deviceId; draft.profileMode = mode;
    await vault.saveDraft(draft, assertActive); assertActive();
    const profileBytes = await DeveloperSigningService.download(auth, team, source); assertActive();
    // 信任来自本轮官方授权请求；仅提取该响应的真实identifier，不把旧ID写进新Profile。
    const profileIdentity = await DeveloperSigningService.profileIdentity(context, profileBytes, signer, runner, jdk, assertActive);
    if (profileIdentity.bundleName !== installed.name || (!originalKey && (!identifier || profileIdentity.appIdentifier !== identifier))) {
      throw new SigningPreparationError(SigningPreparationIssue.Identity, '自动签名与当前安装身份不一致，覆盖安装尚未执行，请重试更新');
    }
    const base64 = new util.Base64Helper();
    const material: SigningMaterialBundle = { schema: 1, keyAlias: draft.keyAlias, keyPassword: draft.keyPassword,
      storePassword: draft.storePassword, signAlg: draft.signAlg, p12Base64: draft.p12Base64,
      certificateBase64: base64.encodeToStringSync(certificateBytes), profileBase64: base64.encodeToStringSync(profileBytes) };
    if (originalKey) await vault.importBundle(JSON.stringify(material), assertActive);
    else await vault.storeVerifiedCloudMaterial(material, { teamId: team, appIdentifier: profileIdentity.appIdentifier,
      bundleName: installed.name, verifiedAt: Date.now() }, assertActive);
    vault.finishDraft(assertActive);
  }

  /** 无可复用密钥时自动生成；草稿由调用者加密，重试继续用同一份，不要求用户选择文件。 */
  private static async generateDraft(context: common.UIAbilityContext, team: string, identifier: string, signer: string,
    runner: string, jdk: string, assertActive: () => void): Promise<SigningDraft> {
    const id = util.generateRandomUUID().replace(new RegExp('-', 'g'), ''), root = context.filesDir + '/sideload-update/key-' + id;
    SideloadFiles.ensureDirectory(root);
    try {
      const code = await testNapi.runJavaProcessor(context.filesDir, jdk, 512, runner + ':' + signer, 'AmclSigningRunner',
        ['--generate-key', root, root + '/result.json'], root, root + '/runtime.log'); assertActive();
      if (code !== 0 || !fs.accessSync(root + '/result.json')) throw new SigningPreparationError(SigningPreparationIssue.Preparation, '本机签名准备未完成，请重新打开 AMCL 后重试');
      const draft = JSON.parse(fs.readTextSync(root + '/result.json')) as SigningDraft;
      if (!draft.p12Base64 || !draft.csr || !draft.keyAlias || !draft.keyPassword || !draft.storePassword) throw new SigningPreparationError(SigningPreparationIssue.Preparation, '本机签名准备失败，请重试更新');
      draft.schema = 1; draft.id = id; draft.teamId = team; draft.appIdentifier = identifier; return draft;
    } finally {
      for (const name of ['result.json', 'new.p12', 'new.csr']) if (fs.accessSync(root + '/' + name)) fs.unlinkSync(root + '/' + name);
    }
  }

  /** 这里只读本轮官方下载的Profile身份；CMS、证书、设备、ACL和有效期仍由实际签名/系统安装验证。 */
  private static async profileIdentity(context: common.UIAbilityContext, bytes: Uint8Array, signer: string, runner: string,
    jdk: string, assertActive: () => void): Promise<ProfileIdentity> {
    const root = context.filesDir + '/sideload-update/key-' + util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    SideloadFiles.ensureDirectory(root);
    try {
      SideloadFiles.write(root + '/profile-check.p7b', bytes);
      const code = await testNapi.runJavaProcessor(context.filesDir, jdk, 512, runner + ':' + signer, 'AmclSigningRunner',
        ['--inspect-profile-identity', root + '/profile-check.p7b', root + '/profile-check.json'], root, root + '/runtime.log'); assertActive();
      if (code !== 0 || !fs.accessSync(root + '/profile-check.json')) throw new SigningPreparationError(SigningPreparationIssue.Preparation, '签名授权校验未完成，请重试更新');
      const identity = JSON.parse(fs.readTextSync(root + '/profile-check.json')) as ProfileIdentity;
      if (typeof identity.bundleName !== 'string' || typeof identity.appIdentifier !== 'string') throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回的授权文件无法读取，请重试更新');
      return identity;
    } finally {
      for (const name of ['profile-check.p7b', 'profile-check.json', 'runtime.log']) if (fs.accessSync(root + '/' + name)) fs.unlinkSync(root + '/' + name);
      if (fs.listFileSync(root).length === 0) fs.rmdirSync(root);
    }
  }

  /** 查询必须唯一匹配，云端同名冲突不能任意选择一份材料。 */
  private static find(raw: Object, field: string, expected: string, ignoreCase: boolean = false): Record<string, Object> | undefined {
    if (!Array.isArray(raw)) throw new SigningPreparationError(SigningPreparationIssue.Response,
      '签名服务返回的材料列表不完整，请重试获取签名');
    const values = (raw as Record<string, Object>[]).filter((row: Record<string, Object>): boolean => {
      const actual = String(row[field] ?? '');
      return ignoreCase ? actual.toUpperCase() === expected.toUpperCase() : actual === expected;
    });
    if (values.length > 1) throw new Error('华为签名材料出现重复记录，请检查开发者后台');
    return values.length === 1 ? values[0] : undefined;
  }

  /**
   * 下载授权来自固定华为API的已认证响应，与官方CLI一样允许服务端选择CDN。
   * 标准URL解析兼容默认443端口；拒绝凭据、非HTTPS及本地/IP目标，不携带账号认证头。
   */
  private static materialUrl(value: Object): string {
    if (typeof value !== 'string' || value.length === 0 || value.length > 16384 ||
      new RegExp('[\\x00-\\x20\\x7f\\\\]').test(value)) {
      throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回的下载地址格式异常，请重试更新');
    }
    let parsed: url.URL;
    try { parsed = url.URL.parseURL(value); }
    catch (_) { throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回的下载地址格式异常，请重试更新'); }
    const host = parsed.hostname.toLowerCase().replace(new RegExp('\\.$'), '');
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || (parsed.port && parsed.port !== '443') ||
      !new RegExp('^[a-z0-9-]+(?:\\.[a-z0-9-]+)+$').test(host) || new RegExp('^[0-9.]+$').test(host) ||
      new RegExp('(?:^|\\.)(localhost|local|internal|lan|test|invalid)$').test(host)) {
      throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回的下载地址不受支持，请重试更新');
    }
    return value; // 不重写带签名的路径和查询串，解析结果只用于目标检查。
  }

  /** 临时下载URL不保存、不打印；保留官方摘要及后续证书/Profile验签，材料不进入通用下载队列。 */
  private static async download(auth: DeveloperAuthSession, team: string, source: string): Promise<Uint8Array> {
    const downloadRequest: MaterialUrlRequest = { sourceUrls: source };
    const response = await auth.request('/api/amis/app-manage/v1/objects/url/reapply', http.RequestMethod.POST, team, downloadRequest);
    const urls = response['urlsInfo'] as Record<string, Object>[];
    if (!Array.isArray(urls) || urls.length !== 1) throw new Error('证书下载地址无效');
    const sourceUrl = DeveloperSigningService.materialUrl(urls[0]['newUrl']);
    const request = http.createHttp();
    try {
      const result = await request.request(sourceUrl, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000, readTimeout: 15000 });
      if (result.responseCode !== 200 || !(result.result instanceof ArrayBuffer) || result.result.byteLength > 128 * 1024) {
        throw new Error('证书下载失败');
      }
      const bytes = new Uint8Array(result.result);
      const expected = String(urls[0]['sha256'] ?? '').toLowerCase();
      // 官方下载API的sha256是可选值；有值必须核实，没有时由后续证书/Profile验签兜底。
      if (!expected) return bytes;
      if (!new RegExp('^[0-9a-f]{64}$').test(expected)) throw new Error('证书完整性摘要无效');
      const digest = cryptoFramework.createMd('SHA256'); await digest.update({ data: bytes });
      const actual = (await digest.digest()).data;
      let hash = ''; for (const byte of actual) hash += byte.toString(16).padStart(2, '0');
      if (hash !== expected) throw new Error('证书完整性检查失败');
      return bytes;
    } finally { request.destroy(); }
  }
}

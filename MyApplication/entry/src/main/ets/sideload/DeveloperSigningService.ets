/**
 * 华为授权后的签名材料准备。先查询当前账号是否拥有已装appIdentifier对应的应用，再申请材料。
 * 不创建同包名的新应用，不删除旧证书/Profile，不把登录成功当作覆盖安装身份成立。
 * 首次由其他安装工具随机签名的应用可能无法在账号下找到相同身份，此时保留原签名导入出口。
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import testNapi from 'libentry.so';
import { DeveloperAuthSession } from './DeveloperAuthSession';
import { SigningVault, SigningDraft, SigningMaterialBundle } from './SigningVault';
import { SideloadFiles } from './SideloadFiles';

/** 对外请求采用显式DTO，避免ArkTS把Record<Object>的值推断为无声明对象。 */
interface CertificateRequest { csr: string; certName: string; certType: string; }
interface DeviceRequest { deviceName: string; udid: string; deviceType: string; }
interface ProfileRequest {
  certList: string[]; packageName: string; deviceList: string[]; provisionName: string;
  appId: string; provisionType: string; reqSource: string; aclPermissionList: string[];
}
interface MaterialUrlRequest { sourceUrls: string; }

export class DeveloperSigningService {
  /**
   * tools已由更新服务校验固定摘要。活动检查在每次外部动作后执行；取消不会触发后续云端写入。
   * 返回材料仅进入HUKS保险库，ViewModel不接触私钥、密码、CSR或认证头。
   */
  static async prepare(context: common.UIAbilityContext, auth: DeveloperAuthSession, vault: SigningVault,
    udid: string, signer: string, runner: string, jdk: string, assertActive: () => void): Promise<void> {
    const installed = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
    const identifier = installed.signatureInfo.appIdentifier;
    let team = '';
    for (const candidate of auth.teamIds()) {
      assertActive();
      const response = await auth.request('/api/amis/app-manage/v1/manage/app/brief-info/list?packageNames=' +
        encodeURIComponent(installed.name), http.RequestMethod.GET, candidate);
      const apps = response['appInfos'] as Record<string, Object>[];
      if (Array.isArray(apps) && apps.some((app: Record<string, Object>): boolean =>
        identifier.length > 0 && String(app['appId'] ?? '') === identifier)) {
        team = candidate; break;
      }
    }
    if (!team) throw new Error('此账号未找到与当前安装匹配的应用身份。请使用原安装账号，或导入原安装工具的签名配置');
    assertActive();
    let draft = await vault.readDraft();
    if (draft !== undefined && (draft.teamId !== team || draft.appIdentifier !== identifier)) {
      throw new Error('已有签名准备记录属于另一个账号，请切回原账号或导入签名配置');
    }
    if (draft === undefined) {
      const id = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
      const root = context.filesDir + '/sideload-update/key-' + id;
      SideloadFiles.ensureDirectory(root);
      const resultPath = root + '/result.json';
      try {
        const code = await testNapi.runJavaProcessor(context.filesDir, jdk, 512, runner + ':' + signer,
          'AmclSigningRunner', ['--generate-key', root, resultPath], root, root + '/runtime.log');
        assertActive();
        if (code === -7 || code === -8) throw new Error('请重新打开 AMCL 后继续准备证书');
        if (code !== 0 || !fs.accessSync(resultPath)) throw new Error('本机签名密钥生成失败');
        draft = JSON.parse(fs.readTextSync(resultPath)) as SigningDraft;
        if (!draft.p12Base64 || !draft.csr || !draft.keyAlias || !draft.keyPassword || !draft.storePassword) {
          throw new Error('本机签名密钥生成失败');
        }
        draft.schema = 1; draft.id = id; draft.teamId = team; draft.appIdentifier = identifier;
        // JVM/加密跨await结束后仍核本轮许可；取消或运行代次变化不能提交旧草稿。
        await vault.saveDraft(draft, assertActive);
      } finally {
        // 固定生成的明文文件即使JVM或加密失败也回收；云端重试只使用已加密草稿。
        for (const name of ['result.json', 'new.p12', 'new.csr']) {
          if (fs.accessSync(root + '/' + name)) fs.unlinkSync(root + '/' + name);
        }
      }
    }
    const certName = 'amcl_update_' + draft.id;
    const certificates = await auth.request('/api/cps/harmony-cert-manage/v1/cert/list', http.RequestMethod.POST, team);
    let certificate = DeveloperSigningService.find(certificates['certList'], 'certName', certName);
    assertActive();
    if (certificate === undefined) {
      const certRequest: CertificateRequest = { csr: draft.csr, certName: certName, certType: '1' };
      await auth.request('/api/cps/harmony-cert-manage/v1/cert/add', http.RequestMethod.POST, team,
        certRequest);
      assertActive();
      const created = await auth.request('/api/cps/harmony-cert-manage/v1/cert/list', http.RequestMethod.POST, team);
      certificate = DeveloperSigningService.find(created['certList'], 'certName', certName);
    }
    if (certificate === undefined || !certificate['id'] || !certificate['certObjectId']) throw new Error('未取得有效的华为调试证书');
    const certificateBytes = await DeveloperSigningService.download(auth, team, String(certificate['certObjectId']));
    let deviceId = '';
    // 有界分页，避免大账号漏掉已有设备后反复注册；只匹配本机UDID。
    for (let page = 1; page <= 20; page++) {
      assertActive();
      const response = await auth.request('/api/cps/device-manage/v1/device/list?encodeFlag=0&start=' + page + '&pageSize=100',
        http.RequestMethod.GET, team);
      const list = response['list'] as Record<string, Object>[];
      const device = DeveloperSigningService.find(list, 'udid', udid, true);
      if (device !== undefined) { deviceId = String(device['id'] ?? ''); break; }
      if (!Array.isArray(list) || list.length < 100) break;
      if (page === 20) throw new Error('账号设备记录过多，请在开发者后台确认当前设备');
    }
    assertActive();
    if (!deviceId) {
      const deviceRequest: DeviceRequest = { deviceName: 'AMCL_' + draft.id.substring(0, 12), udid: udid, deviceType: 'phone' };
      await auth.request('/api/cps/device-manage/v1/device/add', http.RequestMethod.POST, team,
        deviceRequest);
      // 新记录必须从服务返回列表核实，不把UDID当作设备记录ID。
      const response = await auth.request('/api/cps/device-manage/v1/device/list?encodeFlag=0&start=1&pageSize=100', http.RequestMethod.GET, team);
      const device = DeveloperSigningService.find(response['list'], 'udid', udid, true);
      if (device !== undefined) deviceId = String(device['id'] ?? '');
    }
    if (!deviceId) throw new Error('无法核实当前设备的调试授权');
    assertActive();
    const profiles = await auth.request('/api/cps/provision-manage/v1/provision/list?encodeFlag=0&start=1&pageSize=100',
      http.RequestMethod.GET, team);
    let profile = DeveloperSigningService.find(profiles['list'], 'provisionName', certName);
    if (profile === undefined) {
      const profileRequest: ProfileRequest = { certList: [String(certificate['id'])], packageName: installed.name, deviceList: [deviceId],
          provisionName: certName, appId: identifier, provisionType: '1', reqSource: 'IDE',
          aclPermissionList: ['ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY'] };
      profile = await auth.request('/api/cps/provision-manage/v1/ide/real/provision/add', http.RequestMethod.POST, team, profileRequest);
      if (profile['provisionInfo'] !== undefined) profile = profile['provisionInfo'] as Record<string, Object>;
    }
    assertActive();
    const source = String(profile['provisionFileUrl'] ?? '');
    if (!source) throw new Error('未取得当前应用的调试Profile');
    const profileBytes = await DeveloperSigningService.download(auth, team, source);
    assertActive();
    const base64 = new util.Base64Helper();
    const material: SigningMaterialBundle = { schema: 1, keyAlias: draft.keyAlias, keyPassword: draft.keyPassword,
      storePassword: draft.storePassword, signAlg: draft.signAlg, p12Base64: draft.p12Base64,
      certificateBase64: base64.encodeToStringSync(certificateBytes), profileBase64: base64.encodeToStringSync(profileBytes) };
    // 来源证明只由已验证官方API链建立，不复用用户JSON导入入口；取消后不提交迟到材料。
    await vault.storeVerifiedCloudMaterial(material, { teamId: team, appIdentifier: identifier,
      bundleName: installed.name, verifiedAt: Date.now() }, assertActive);
  }

  /** 查询必须唯一匹配，云端同名冲突不能任意选择一份材料。 */
  private static find(raw: Object, field: string, expected: string, ignoreCase: boolean = false): Record<string, Object> | undefined {
    if (!Array.isArray(raw)) return undefined;
    const values = (raw as Record<string, Object>[]).filter((row: Record<string, Object>): boolean => {
      const actual = String(row[field] ?? '');
      return ignoreCase ? actual.toUpperCase() === expected.toUpperCase() : actual === expected;
    });
    if (values.length > 1) throw new Error('华为签名材料出现重复记录，请检查开发者后台');
    return values.length === 1 ? values[0] : undefined;
  }

  /** 临时下载URL不保存、不打印；只接收华为HTTPS材料，摘要不匹配时拒绝进入保险库。 */
  private static async download(auth: DeveloperAuthSession, team: string, source: string): Promise<Uint8Array> {
    const downloadRequest: MaterialUrlRequest = { sourceUrls: source };
    const response = await auth.request('/api/amis/app-manage/v1/objects/url/reapply', http.RequestMethod.POST, team, downloadRequest);
    const urls = response['urlsInfo'] as Record<string, Object>[];
    if (!Array.isArray(urls) || urls.length !== 1) throw new Error('证书下载地址无效');
    const url = String(urls[0]['newUrl'] ?? '');
    const host = new RegExp('^https://([a-zA-Z0-9.-]+)/').exec(url);
    if (host === null || !new RegExp('(^|\\.)(huawei\\.com|dbankcdn\\.cn|myhuaweicloud\\.com|hicloud\\.com)$').test(host[1])) {
      throw new Error('证书下载来源无效');
    }
    const request = http.createHttp();
    try {
      const result = await request.request(url, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
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

/** 自动保留现装公钥：优先使用本机保险库，其次使用构建期已核实的公开默认模板。 */
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import testNapi from 'libentry.so';
import { stringToUtf8 } from 'commons';
import { DeveloperAuthSession } from './DeveloperAuthSession';
import { SigningDraft, SigningVault } from './SigningVault';
import { SideloadFiles } from './SideloadFiles';
import { SigningPreparationError, SigningPreparationIssue } from './SigningPreparationError';

interface SigningTemplate { provider: string; appIdSha256: string; privatePem: string; csr: string; }
interface TemplateCatalog { schema: number; templates: SigningTemplate[]; }
interface RestoredKeyResult extends SigningDraft { error?: string; }
interface AvailableCertificate { teamId: string; certificateBase64: string; id: string; objectId: string; }
interface RestoreKeyInput {
  bundleName: string; appId: string; defaultTeamId: string; privatePem: string; csr: string;
  certificates: AvailableCertificate[]; provider: string; materialDirectory: string; allowProfileContinuation: boolean;
}

export class OriginalSigningRecovery {
  /** 模板在构建期核验，手机更新不下载第三方安装器，也不读取其他应用的账号或私有目录。 */
  private static async template(context: common.UIAbilityContext, appId: string): Promise<SigningTemplate | undefined> {
    let catalog: TemplateCatalog;
    try {
      const bytes = context.resourceManager.getRawFileContentSync('sideload/public-signing-templates.json');
      if (bytes.byteLength > 64 * 1024) throw new Error('Template size');
      catalog = JSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as TemplateCatalog;
      if (catalog.schema !== 1 || !Array.isArray(catalog.templates)) throw new Error('Template format');
    } catch (_) { throw new SigningPreparationError(SigningPreparationIssue.Preparation, '更新签名组件异常，请重新打开 AMCL 后重试'); }
    const digest = cryptoFramework.createMd('SHA256'); await digest.update({ data: stringToUtf8(appId) });
    let hash = ''; for (const byte of (await digest.digest()).data) hash += byte.toString(16).padStart(2, '0');
    return catalog.templates.find((value: SigningTemplate): boolean => value.appIdSha256 === hash);
  }

  /** 当前账号可为同一私钥签发新证书；旧叶指纹变化不阻止续期，空证书列表也允许建草稿。 */
  static async restore(context: common.UIAbilityContext, auth: DeveloperAuthSession, vault: SigningVault | undefined,
    bundleName: string, appId: string, identifier: string, signer: string, runner: string, jdk: string,
    download: (team: string, source: string) => Promise<Uint8Array>, assertActive: () => void,
    allowProfileContinuation: boolean = false): Promise<SigningDraft | undefined> {
    if (bundleName !== 'com.amcl.launcher' || !appId) return undefined;
    const useSavedKey = vault !== undefined && vault.available();
    const template = useSavedKey ? undefined : await OriginalSigningRecovery.template(context, appId);
    assertActive();
    if (!useSavedKey && template === undefined) return undefined;
    const teams = auth.teamIds();
    if (teams.length === 0) throw new SigningPreparationError(SigningPreparationIssue.Permission, '当前授权没有可用的开发者团队，请重新登录后重试');
    const certificates: AvailableCertificate[] = [];
    const base64 = new util.Base64Helper(); let total = 0;
    for (const team of teams) {
      let response: Record<string, Object>;
      // 列表接口需要空JSON对象；不能用空字符串替代，否则请求在本机参数检查时失败。
      const certificateQuery: Record<string, string> = {};
      try { response = await auth.request('/api/cps/harmony-cert-manage/v1/cert/list', http.RequestMethod.POST, team, certificateQuery); }
      catch (error) {
        assertActive(); if (DeveloperAuthSession.isExpired(error as Error)) throw error as Error;
        continue; // 复用查询失败可以申请新证书；其他团队不可访问不应阻断本人团队。
      }
      assertActive();
      const list = response['certList'] as Record<string, Object>[];
      if (!Array.isArray(list)) continue;
      for (const certificate of list) {
        if (certificate === null || typeof certificate !== 'object') continue;
        if (typeof certificate['certObjectId'] !== 'string' || typeof certificate['id'] !== 'string') continue;
        // 有界复用查询不是准入门槛；未找到可复用证书时继续自动申请，不要求用户提供文件。
        if (certificates.length >= 32 || total >= 2 * 1024 * 1024) break;
        let bytes: Uint8Array;
        try { bytes = await download(team, certificate['certObjectId'] as string); }
        catch (error) { assertActive(); if (DeveloperAuthSession.isExpired(error as Error)) throw error as Error; continue; }
        assertActive();
        if (total + bytes.byteLength > 2 * 1024 * 1024) break;
        total += bytes.byteLength;
        certificates.push({ teamId: team, certificateBase64: base64.encodeToStringSync(bytes), id: certificate['id'] as string, objectId: certificate['certObjectId'] as string });
      }
    }
    const id = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    const root = context.filesDir + '/sideload-update/key-' + id;
    SideloadFiles.ensureDirectory(root);
    const input: RestoreKeyInput = { bundleName: bundleName, appId: appId, defaultTeamId: auth.preferredTeamId(),
      privatePem: template?.privatePem ?? '', csr: template?.csr ?? '', certificates: certificates,
      provider: useSavedKey ? 'cached-key' : 'bundled-template', materialDirectory: root, allowProfileContinuation: allowProfileContinuation };
    try {
      if (useSavedKey && vault !== undefined) { await vault.materialize(root); assertActive(); }
      SideloadFiles.write(root + '/restore-input.json', JSON.stringify(input));
      const code = await testNapi.runJavaProcessor(context.filesDir, jdk, 512, runner + ':' + signer,
        'AmclSigningRunner', ['--restore-original-key', root + '/restore-input.json', root + '/result.json'], root, root + '/runtime.log');
      assertActive();
      if (code !== 0 || !fs.accessSync(root + '/result.json')) throw new SigningPreparationError(SigningPreparationIssue.Preparation, '自动签名准备未完成，请重新打开 AMCL 后重试');
      const restored = JSON.parse(fs.readTextSync(root + '/result.json')) as RestoredKeyResult;
      if (restored.error !== undefined) throw new SigningPreparationError(SigningPreparationIssue.Preparation, '自动签名准备失败，当前安装已保留，请重试更新');
      if (!restored.teamId || !teams.includes(restored.teamId) || (!allowProfileContinuation && restored.originalAppId !== appId) ||
        !restored.p12Base64 || !restored.csr || !restored.keyAlias || !restored.keyPassword || !restored.storePassword) {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '自动签名结果不完整，请重试更新');
      }
      restored.schema = 1; restored.id = id; restored.appIdentifier = identifier;
      return restored;
    } finally {
      if (vault !== undefined) vault.clearTemporary(root);
      for (const name of ['restore-input.json', 'result.json', 'runtime.log']) if (fs.accessSync(root + '/' + name)) fs.unlinkSync(root + '/' + name);
      if (fs.listFileSync(root).length === 0) fs.rmdirSync(root);
    }
  }
}

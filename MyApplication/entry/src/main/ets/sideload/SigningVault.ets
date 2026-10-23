/**
 * 用户签名材料的独立HUKS保险库。导入文件只提供材料，不能自称云端可信来源。
 * 本域统一完整写入、加密来源绑定和不可覆盖的旧密文备份；秘密仅在私有签名窗口提取。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { HuksAesGcm256Provider, EncryptedBlob } from 'account';
import { decodeStandardBase64, stringToUtf8 } from 'commons';
import { SideloadFiles } from './SideloadFiles';

/** 用户可导入的旧格式材料，兼容既有安装工具；未知来源字段一律不带入可信记录。 */
export interface SigningMaterialBundle {
  schema: number; keyAlias: string; keyPassword: string; storePassword: string; signAlg: string;
  p12Base64: string; certificateBase64: string; profileBase64: string;
}

/** 已由官方在线应用/团队查询与材料下载建立的绑定，只能由内部签名服务创建。 */
export interface SigningCloudBinding {
  teamId: string; appIdentifier: string; bundleName: string; verifiedAt: number;
}

/** 可公开给协调器的材料证据，不包含私钥、口令、CSR或开发者令牌。 */
export interface SigningMaterialProof {
  schema: number; origin: string; teamId: string; appIdentifier: string; bundleName: string;
  certificateSha256: string; profileSha256: string; verifiedAt: number; revision: string;
  /** 每次可信存储生成的公开随机修订；不公布可猜口令摘要，同证书的换材也必须重签。 */
  recordId?: string;
}

/** 新保险库把材料与来源一起GCM认证，旧schema1解密后按Imported保守迁移。 */
interface StoredSigningMaterial { schema: number; material: SigningMaterialBundle; proof: SigningMaterialProof; }

/** 首次申请被中断时复用同一密钥和云端名称，不因重试重复申请证书。 */
export interface SigningDraft {
  schema: number; id: string; teamId: string; appIdentifier: string; keyAlias: string;
  keyPassword: string; storePassword: string; signAlg: string; p12Base64: string; csr: string;
}

/** JVM一次性配置；来源由Vault解密得到，不能从用户导入JSON复制origin声明。 */
interface SigningRunnerConfig {
  keyAlias: string; keyPassword: string; storePassword: string; signAlg: string;
  materialOrigin: string; cloudAppIdentifier: string; cloudBundleName: string;
  cloudCertificateSha256: string; cloudProfileSha256: string; cloudVerifiedAt: number; materialRevision: string;
  materialRecordId: string;
}

export class SigningVault {
  private cipher: HuksAesGcm256Provider = new HuksAesGcm256Provider('amcl_sideload_signing_v1');
  private root: string;

  /** Context只提取私有filesDir，不持有窗口或失效UI对象。 */
  constructor(context: common.UIAbilityContext) {
    this.root = context.filesDir + '/sideload-update';
    SideloadFiles.ensureDirectory(this.root);
  }

  /** 有界解析用户材料；只接受旧schema1和白名单字段，未知来源/证明不能提升权限。 */
  private parse(body: string): SigningMaterialBundle {
    if (stringToUtf8(body).byteLength > 64 * 1024) throw new Error('签名材料文件过大');
    const value = JSON.parse(body) as Record<string, Object>;
    if (value === null || Array.isArray(value) || value['schema'] !== 1) throw new Error('不支持的签名材料格式');
    const required: string[] = ['keyAlias', 'keyPassword', 'storePassword', 'signAlg', 'p12Base64', 'certificateBase64', 'profileBase64'];
    for (const name of required) if (typeof value[name] !== 'string') throw new Error('签名材料不完整');
    if (!(value['keyAlias'] as string).length || (value['keyAlias'] as string).length > 256) throw new Error('签名别名无效');
    if (value['signAlg'] !== 'SHA256withECDSA' && value['signAlg'] !== 'SHA256withRSA') throw new Error('不支持的签名算法');
    for (const name of ['p12Base64', 'certificateBase64', 'profileBase64']) {
      const size = decodeStandardBase64(value[name] as string).length;
      if (size === 0 || size > 64 * 1024) throw new Error('签名材料大小无效');
    }
    return { schema: 1, keyAlias: value['keyAlias'] as string, keyPassword: value['keyPassword'] as string,
      storePassword: value['storePassword'] as string, signAlg: value['signAlg'] as string,
      p12Base64: value['p12Base64'] as string, certificateBase64: value['certificateBase64'] as string,
      profileBase64: value['profileBase64'] as string };
  }

  /** 用户明确导入的新材料只记Imported；取消后不提交迟到的加密结果。 */
  async importBundle(body: string, beforeCommit?: () => void): Promise<void> {
    const material = this.parse(body);
    const proof = await this.createProof(material, undefined, util.generateRandomUUID().replace(new RegExp('-', 'g'), ''));
    await this.store(material, proof, true, beforeCommit);
  }

  /** 内部云端入口：必须在当前已验证官方会话下调用，API绑定随材料一起加密。 */
  async storeVerifiedCloudMaterial(material: SigningMaterialBundle, binding: SigningCloudBinding,
    beforeCommit?: () => void): Promise<void> {
    if (!binding.teamId || !binding.appIdentifier || !binding.bundleName ||
      !Number.isFinite(binding.verifiedAt) || binding.verifiedAt <= 0 || binding.verifiedAt > Date.now()) {
      throw new Error('云端签名绑定未核实');
    }
    const normalized = this.parse(JSON.stringify(material));
    const proof = await this.createProof(normalized, binding, util.generateRandomUUID().replace(new RegExp('-', 'g'), ''));
    await this.store(normalized, proof, false, beforeCommit);
  }

  /**
   * 摘要绑定实际证书/Profile、来源与本次存储修订；同cer/Profile而不同p12/别名/算法/口令
   * 的显式导入也更换recordId。旧只读格式采用空recordId稳定兼容，不每次读取随机化。
   */
  private async createProof(material: SigningMaterialBundle, binding?: SigningCloudBinding, recordId: string = ''): Promise<SigningMaterialProof> {
    const certificateSha = await this.hashBytes(decodeStandardBase64(material.certificateBase64));
    const profileSha = await this.hashBytes(decodeStandardBase64(material.profileBase64));
    const origin = binding === undefined ? 'imported' : 'cloud-bound';
    const identifier = binding?.appIdentifier ?? '';
    const revision = await this.hashBytes(stringToUtf8(origin + '|' + certificateSha + '|' + profileSha + '|' + identifier +
      (recordId.length > 0 ? '|' + recordId : '')));
    return { schema: 1, origin: origin, teamId: binding?.teamId ?? '', appIdentifier: identifier,
      bundleName: binding?.bundleName ?? '', certificateSha256: certificateSha, profileSha256: profileSha,
      verifiedAt: binding?.verifiedAt ?? 0, revision: revision, recordId: recordId };
  }

  /** 仅处理本域小材料的SHA，不一次读入HAP；大包仍使用SideloadFiles流式算法。 */
  private async hashBytes(bytes: Uint8Array): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: bytes });
    let text = '';
    for (const byte of (await digest.digest()).data) text += byte.toString(16).padStart(2, '0');
    return text;
  }

  /** 每次替换前留旧密文独立备份，不覆盖已退役文件，不把私钥明文用于备份。 */
  private retainEncrypted(path: string): void {
    if (!fs.accessSync(path)) return;
    if (!fs.statSync(path).isFile() || fs.statSync(path).size > 160 * 1024) throw new Error('原签名记录无法安全备份');
    const backup = path + '.retired-' + util.generateRandomUUID() + '.json';
    if (fs.accessSync(backup)) throw new Error('签名备份身份冲突');
    SideloadFiles.write(backup, fs.readTextSync(path));
  }

  /** 加密和来源证明一起提交；云端重试有旧密文时只使用旧key，明确用户导入才允许重建缺失key。 */
  private async store(material: SigningMaterialBundle, proof: SigningMaterialProof, explicitImport: boolean,
    beforeCommit?: () => void): Promise<void> {
    beforeCommit?.();
    const record: StoredSigningMaterial = { schema: 2, material: material, proof: proof };
    const body = JSON.stringify(record);
    if (stringToUtf8(body).byteLength > 64 * 1024) throw new Error('签名材料超过安全加密边界');
    const path = this.root + '/signing-vault.json';
    const hasHistory = fs.accessSync(path) || fs.accessSync(this.root + '/signing-draft.json');
    if (explicitImport) this.retainEncrypted(path);
    const encrypted = await this.cipher.encrypt(body, explicitImport || !hasHistory);
    beforeCommit?.();
    if (!explicitImport) this.retainEncrypted(path);
    SideloadFiles.write(path, JSON.stringify(encrypted));
  }

  /** 文件存在只代表有待校验记录；实际解密、来源和身份仍在签名前检查。 */
  available(): boolean { return fs.accessSync(this.root + '/signing-vault.json'); }

  /** 用户明确更新材料时将旧文件移到唯一备份，不覆盖上一次退役记录。 */
  invalidate(): void {
    for (const name of ['signing-vault.json', 'signing-draft.json']) {
      const path = this.root + '/' + name;
      if (!fs.accessSync(path)) continue;
      const backup = path + '.retired-' + util.generateRandomUUID() + '.json';
      if (fs.accessSync(backup)) throw new Error('签名备份身份冲突');
      fs.renameSync(path, backup);
    }
    const directory = fs.openSync(this.root, fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory); }
  }

  /** 草稿只有首次明确创建可建立key；加密前后核实许可，旧代次不得提交迟到草稿。 */
  async saveDraft(draft: SigningDraft, beforeCommit?: () => void): Promise<void> {
    beforeCommit?.();
    const hasHistory = fs.accessSync(this.root + '/signing-vault.json') || fs.accessSync(this.root + '/signing-draft.json');
    const encrypted = await this.cipher.encrypt(JSON.stringify(draft), !hasHistory);
    beforeCommit?.();
    SideloadFiles.write(this.root + '/signing-draft.json', JSON.stringify(encrypted));
  }

  /** 解密旧草稿只能使用已存在key；丢失密钥时给恢复原配置的出口，不创建替代key。 */
  async readDraft(): Promise<SigningDraft | undefined> {
    const path = this.root + '/signing-draft.json';
    if (!fs.accessSync(path)) return undefined;
    if (!fs.statSync(path).isFile() || fs.statSync(path).size > 160 * 1024) throw new Error('签名准备记录过大');
    const value = JSON.parse(await this.cipher.decrypt(JSON.parse(fs.readTextSync(path)) as EncryptedBlob)) as SigningDraft;
    if (value.schema !== 1 || !new RegExp('^[0-9a-f]{32}$').test(value.id) || !value.p12Base64 || !value.csr) {
      throw new Error('签名准备记录无法读取，请导入原签名配置');
    }
    return value;
  }

  /** 读取认证后的记录并重算材料哈希；旧格式一律不会隐式变成cloud-bound。 */
  private async readMaterial(): Promise<StoredSigningMaterial> {
    const path = this.root + '/signing-vault.json';
    if (!fs.statSync(path).isFile() || fs.statSync(path).size > 160 * 1024) throw new Error('签名记录无法读取');
    const body = await this.cipher.decrypt(JSON.parse(fs.readTextSync(path)) as EncryptedBlob);
    const value = JSON.parse(body) as StoredSigningMaterial;
    if (value.schema !== 2) {
      const legacy = this.parse(body);
      return { schema: 2, material: legacy, proof: await this.createProof(legacy) };
    }
    const material = this.parse(JSON.stringify(value.material));
    const saved = value.proof;
    if (saved === undefined || saved.schema !== 1 ||
      (saved.origin !== 'imported' && saved.origin !== 'cloud-bound')) throw new Error('签名来源记录无法核实');
    let binding: SigningCloudBinding | undefined = undefined;
    if (saved.origin === 'cloud-bound') {
      if (!saved.teamId || !saved.appIdentifier || !saved.bundleName ||
        !Number.isFinite(saved.verifiedAt) || saved.verifiedAt <= 0) throw new Error('签名来源绑定无效');
      binding = { teamId: saved.teamId, appIdentifier: saved.appIdentifier, bundleName: saved.bundleName, verifiedAt: saved.verifiedAt };
    }
    const recordId = saved.recordId ?? '';
    if (typeof recordId !== 'string' || (recordId.length > 0 && !new RegExp('^[0-9a-f]{32}$').test(recordId))) throw new Error('签名材料修订记录无效');
    const proof = await this.createProof(material, binding, recordId);
    if (proof.certificateSha256 !== saved.certificateSha256 || proof.profileSha256 !== saved.profileSha256 ||
      proof.revision !== saved.revision) throw new Error('签名材料身份发生变化');
    return { schema: 2, material: material, proof: proof };
  }

  /** 提供仅含公有哈希/来源的证明，供热Ready安装前判断材料是否已更换。 */
  async readProof(): Promise<SigningMaterialProof> { return (await this.readMaterial()).proof; }
  async materialRevision(): Promise<string> { return (await this.readProof()).revision; }

  /** 临时提取和证明来自同一次认证读取；密码不进JNI argv，返回值不含任何秘密。 */
  async materialize(destination: string): Promise<SigningMaterialProof> {
    const stored = await this.readMaterial();
    const material = stored.material;
    const proof = stored.proof;
    SideloadFiles.ensureDirectory(destination);
    SideloadFiles.write(destination + '/material.p12', decodeStandardBase64(material.p12Base64));
    SideloadFiles.write(destination + '/material.cer', decodeStandardBase64(material.certificateBase64));
    SideloadFiles.write(destination + '/material.p7b', decodeStandardBase64(material.profileBase64));
    const config: SigningRunnerConfig = { keyAlias: material.keyAlias, keyPassword: material.keyPassword,
      storePassword: material.storePassword, signAlg: material.signAlg, materialOrigin: proof.origin,
      cloudAppIdentifier: proof.appIdentifier, cloudBundleName: proof.bundleName,
      cloudCertificateSha256: proof.certificateSha256, cloudProfileSha256: proof.profileSha256,
      cloudVerifiedAt: proof.verifiedAt, materialRevision: proof.revision, materialRecordId: proof.recordId ?? '' };
    SideloadFiles.write(destination + '/config.json', JSON.stringify(config));
    return proof;
  }

  /** 清理本域固定材料和完整writer的本次命名空间，不递归删除未知路径或用户原文件。 */
  clearTemporary(destination: string): void {
    for (const name of ['config.json', 'material.p12', 'material.cer', 'material.p7b', 'verified.cer', 'verified.p7b', 'profile-check.json']) {
      const path = destination + '/' + name;
      try { if (fs.accessSync(path)) fs.unlinkSync(path); } catch (_) { /* 继续清其他材料，启动时再次处理。 */ }
    }
    try {
      for (const name of fs.listFileSync(destination)) {
        if (!new RegExp('^(config\\.json|material\\.(p12|cer|p7b)|verified\\.(cer|p7b)|profile-check\\.json)\\.[0-9a-fA-F-]{36}\\.pending-dir$').test(name)) continue;
        const directory = destination + '/' + name;
        const content = directory + '/content.pending';
        const items = fs.listFileSync(directory);
        if (items.some((item: string): boolean => item !== 'content.pending')) continue;
        if (fs.accessSync(content)) fs.unlinkSync(content);
        fs.rmdirSync(directory);
      }
    } catch (_) { /* 仅保留当前UID可访问现场，不扩大清理到未知目录。 */ }
  }
}

/**
 * 本机华为开发者登录凭据仓库。与签名证书分开保存，不能用证书存在推断账号仍登录。
 * 只持久化经过服务端验证的JWT；访问令牌由每轮在线检查重新取得，不进入普通日志。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { HuksAesGcm256Provider, EncryptedBlob } from 'account';
import { SideloadFiles } from './SideloadFiles';

export interface DeveloperCredential {
  schema: number;
  jwt: string;
  expiresAt: number;
  savedAt: number;
}

/** 仅本域明确坏格式或原key缺失使用；暂态FileIO/HUKS异常不冒充登录过期。 */
export class DeveloperCredentialInvalidError extends Error {}

export class DeveloperAuthVault {
  private cipher: HuksAesGcm256Provider = new HuksAesGcm256Provider('amcl_sideload_auth_v1');
  private path: string;

  /** 固定应用私有路径和独立HUKS别名，保留原Minecraft账户及原签名材料的密钥身份。 */
  constructor(context: common.UIAbilityContext) {
    const root = context.filesDir + '/sideload-update';
    SideloadFiles.ensureDirectory(root);
    this.path = root + '/developer-auth.json';
  }

  /**
   * 缺文件表示从未保存登录；空JWT表示已失效，供UI准确区别“未登录”和“登录已过期”。
   * @throws 私有文件、格式或HUKS读取失败交给会话恢复分类，保留原记录。
   */
  async read(): Promise<DeveloperCredential | undefined> {
    if (!fs.accessSync(this.path)) return undefined;
    if (!fs.statSync(this.path).isFile() || fs.statSync(this.path).size > 64 * 1024) throw new DeveloperCredentialInvalidError('登录记录格式无效');
    const body = fs.readTextSync(this.path);
    let encrypted: EncryptedBlob;
    try { encrypted = JSON.parse(body) as EncryptedBlob; }
    catch (_) { throw new DeveloperCredentialInvalidError('登录记录格式无效'); }
    if (encrypted === null || typeof encrypted.iv !== 'string' || typeof encrypted.tag !== 'string' || typeof encrypted.ciphertext !== 'string') {
      throw new DeveloperCredentialInvalidError('登录记录格式无效');
    }
    if (!(await this.cipher.hasExistingKey())) throw new DeveloperCredentialInvalidError('原登录密钥已丢失，请重新登录');
    // 查询/解密RPC异常继续传播；不能从任意平台错误推断服务端登录已过期。
    const plain = await this.cipher.decrypt(encrypted);
    let value: DeveloperCredential;
    try { value = JSON.parse(plain) as DeveloperCredential; }
    catch (_) { throw new DeveloperCredentialInvalidError('登录记录格式无效'); }
    if (value === null || value.schema !== 1 || typeof value.jwt !== 'string' || value.jwt.length > 16384 ||
      !Number.isFinite(value.expiresAt) || value.expiresAt < 0 || !Number.isFinite(value.savedAt)) {
      throw new DeveloperCredentialInvalidError('登录记录已失效');
    }
    return value;
  }

  /**
   * 加密完成后再次核对会话代次，取消或退出不能让迟到登录覆盖新一轮凭据。
   * freshLogin只由已完成官方JWT/团队验证的新登录传入；自动失效标记没有重新建key的权限。
   * 原key明确丢失时，新登录可新建此登录域key，但先保留旧密文，签名域密钥不受影响。
   * @throws 密钥查询/加密、旧记录备份或可靠提交失败，调用方不能宣告登录已保存。
   */
  async save(value: DeveloperCredential, current: () => boolean, freshLogin: boolean = false): Promise<void> {
    if (!current()) return;
    const hasRecord = fs.accessSync(this.path);
    let allowCreate = !hasRecord;
    if (freshLogin && hasRecord) {
      // hasKeyItem抛错仍直接传播；暂态RPC错误不能被当成明确丢失。
      allowCreate = !(await this.cipher.hasExistingKey());
    }
    if (!current()) return;
    const encrypted = await this.cipher.encrypt(JSON.stringify(value), allowCreate);
    if (!current()) return;
    if (hasRecord && allowCreate) {
      if (!fs.statSync(this.path).isFile() || fs.statSync(this.path).size > 64 * 1024) throw new Error('原登录记录无法安全保留');
      const backup = this.path + '.retired-' + util.generateRandomUUID() + '.json';
      if (fs.accessSync(backup)) throw new Error('登录备份身份冲突');
      SideloadFiles.write(backup, fs.readTextSync(this.path));
    }
    if (current()) SideloadFiles.write(this.path, JSON.stringify(encrypted));
  }
}

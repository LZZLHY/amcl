/**
 * authlib-injector官方原件的消费身份与提取器。固定内容地址避免HAP升级后仍复用旧版
 * 非空JAR；第三方账号与离线本地外观共享同一原件，不链接或修改第三方实现。
 * 上游来源/许可见deps.lock的[authlib-injector]与docs/CREDITS.md。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { AUTHLIB_INJECTOR_JAR_NAME, evidenceHex, evidenceFileDigestSync } from 'commons';

export const AUTHLIB_INJECTOR_VERSION: string = '1.2.8';
export const AUTHLIB_INJECTOR_SHA256: string = '9c7f4343e6c82034958ffb48c14a2cb0c85928be7283103ce17da00c6d5a7b10';
export const AUTHLIB_INJECTOR_BYTES: number = 349681;

/**
 * 先核已有内容地址；需要提取时验证包内原件。失败不使用旧agent“将就启动”。临时文件与目标
 * 位于同一应用目录，写完fsync和SHA复验后rename，异常只清本次独有临时文件。
 */
export async function ensureAuthlibInjectorArtifact(context: common.UIAbilityContext, filesDir: string): Promise<string> {
  // SDK同步可抛接口与Promise拒绝统一转交调用方，不能吞掉完整性/IO错误。
  try {
    const path: string = filesDir + '/authlib-injector-' + AUTHLIB_INJECTOR_SHA256 + '.jar';
    try {
      if (fs.statSync(path).isFile() && fs.statSync(path).size === AUTHLIB_INJECTOR_BYTES &&
          evidenceFileDigestSync(path) === AUTHLIB_INJECTOR_SHA256) return path;
    } catch (_) { /* 缺失或损坏时从当前HAP中核验提取，不沿用无摘要旧路径。 */ }
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent(AUTHLIB_INJECTOR_JAR_NAME);
    if (bytes.byteLength !== AUTHLIB_INJECTOR_BYTES) throw new Error('包内authlib-injector大小不匹配');
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: bytes });
    if (evidenceHex((await digest.digest()).data) !== AUTHLIB_INJECTOR_SHA256) throw new Error('包内authlib-injector摘要不匹配');
    const pending: string = path + '.pending-' + util.generateRandomUUID();
    try {
      const file = fs.openSync(pending, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        let written: number = 0;
        while (written < buffer.byteLength) {
          const count: number = fs.writeSync(file.fd, buffer.slice(written));
          if (count <= 0) throw new Error('authlib-injector写入不完整');
          written += count;
        }
        fs.fsyncSync(file.fd);
      } finally { fs.closeSync(file); }
      if (evidenceFileDigestSync(pending) !== AUTHLIB_INJECTOR_SHA256) throw new Error('authlib-injector写入后校验失败');
      fs.renameSync(pending, path);
      return path;
    } finally {
      try { if (fs.accessSync(pending)) fs.unlinkSync(pending); } catch (_) { /* 只清理自己的pending，正式旧JAR保留。 */ }
    }
  } catch (error) { throw error as Error; }
}

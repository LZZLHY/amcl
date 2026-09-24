/** 官方 logging.client 配置的下载、SHA-1 校验与参数生成。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ensureDirSync } from 'commons';
import { MinecraftLoggingClient } from './VersionParser';
import { VersionFileVerifier } from './VersionFileVerifier';

export function minecraftLoggingPath(mcDir: string, client: MinecraftLoggingClient): string {
  const file = client.file;
  if (!file || !new RegExp('^[a-zA-Z0-9_.-]+$').test(file.id) || file.id === '.' || file.id === '..'
    || !new RegExp('^[a-fA-F0-9]{40}$').test(file.sha1) || !(file.size > 0 && file.size <= 1024 * 1024)) {
    throw new Error('logging.client 文件元数据无效');
  }
  return mcDir + '/assets/log_configs/' + file.id;
}

export function minecraftLoggingArgument(mcDir: string, client: MinecraftLoggingClient): string {
  if (client.argument.indexOf('${path}') < 0 || !client.argument.startsWith('-D')
    || new RegExp('[\\r\\n\\u0000]').test(client.argument)) throw new Error('logging.client.argument 无效');
  return client.argument.split('${path}').join(minecraftLoggingPath(mcDir, client));
}

/** 已安装版本启动时也补齐；网络失败保留旧文件，校验失败不能覆盖有效配置。 */
export async function ensureMinecraftLoggingConfig(mcDir: string,
  client: MinecraftLoggingClient | undefined): Promise<void> {
  if (client === undefined) return;
  const target: string = minecraftLoggingPath(mcDir, client);
  try {
    if (fs.statSync(target).size === client.file.size
      && (await VersionFileVerifier.sha1File(target)).toLowerCase() === client.file.sha1.toLowerCase()) return;
  } catch (e) { /* 缺失或损坏后按元数据修复 */ }
  if (!client.file.url.startsWith('https://')) throw new Error('日志配置下载地址必须使用 HTTPS');
  ensureDirSync(mcDir + '/assets/log_configs');
  const temporary: string = target + '.partial-' + Date.now();
  const request = http.createHttp();
  try {
    const result = await request.request(client.file.url, { method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: 1024 * 1024,
      connectTimeout: 10000, readTimeout: 30000 });
    if (result.responseCode !== 200 || !(result.result instanceof ArrayBuffer)
      || result.result.byteLength !== client.file.size) throw new Error('日志配置下载大小或 HTTP 状态不符');
    const output = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      if (fs.writeSync(output.fd, result.result) !== client.file.size) throw new Error('日志配置文件短写');
      fs.fsyncSync(output.fd);
    } finally { fs.closeSync(output); }
    if ((await VersionFileVerifier.sha1File(temporary)).toLowerCase() !== client.file.sha1.toLowerCase()) {
      throw new Error('日志配置 SHA-1 校验失败');
    }
    fs.renameSync(temporary, target);
  } finally {
    request.destroy();
    try { fs.unlinkSync(temporary); } catch (e) { /* 已成功改名 */ }
  }
}

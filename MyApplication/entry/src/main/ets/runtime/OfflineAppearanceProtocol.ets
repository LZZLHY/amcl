/**
 * 离线外观的纯协议边界。这里只解析有上限的 HTTP 请求和构造 Yggdrasil 纹理声明，
 * 不打开端口、不读取账号/文件，也不提供认证。生产服务器与宿主测试共用这些函数。
 */
import { encodeStandardBase64, stringToUtf8 } from 'commons';

/** 一条请求最多16KiB头、4KiB正文；PNG只出现在响应，不接受上传。 */
export const OFFLINE_HTTP_HEADER_LIMIT: number = 16384;
export const OFFLINE_HTTP_BODY_LIMIT: number = 4096;

/** pending 表示等待TCP后续分片；error不应继续累积或尝试另一种解析。 */
export interface OfflineHttpRequest {
  state: string;
  method: string;
  target: string;
  body: Uint8Array;
}

/** 只接受受控相对资产命名，摘要同时是文件名和内容身份，不允许URI/路径拼接逃逸。 */
export function offlineAssetPath(filesDir: string, relativePath: string, sha256: string): string {
  if (!new RegExp('^[0-9a-f]{64}$').test(sha256) ||
      relativePath !== 'account-textures/' + sha256 + '.png' || filesDir.length === 0) {
    throw new Error('离线外观资产引用无效');
  }
  return filesDir + '/' + relativePath;
}

/** 序列化边界统一无连字符UUID；不能从名字重新生成或用账号列表ID替代。 */
export function offlineProfileId(uuid: string): string {
  const compact: string = uuid.replace(new RegExp('-', 'g'), '').toLowerCase();
  if (!new RegExp('^[0-9a-f]{32}$').test(compact)) throw new Error('离线账号UUID无效');
  return compact;
}

/** 原样保留UTF-8正文的字节边界，避免中文用户名使Content-Length被当作字符数。 */
export function parseOfflineHttpRequest(bytes: Uint8Array): OfflineHttpRequest {
  const empty: OfflineHttpRequest = { state: 'pending', method: '', target: '', body: new Uint8Array(0) };
  if (bytes.byteLength > OFFLINE_HTTP_HEADER_LIMIT + OFFLINE_HTTP_BODY_LIMIT + 4) {
    empty.state = 'error'; return empty;
  }
  let split: number = -1;
  for (let i: number = 0; i + 3 < bytes.byteLength; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
      split = i; break;
    }
  }
  if (split < 0) { if (bytes.byteLength > OFFLINE_HTTP_HEADER_LIMIT) empty.state = 'error'; return empty; }
  if (split > OFFLINE_HTTP_HEADER_LIMIT) { empty.state = 'error'; return empty; }
  let headers: string = '';
  for (let i: number = 0; i < split; i++) {
    // 请求行/头部仅接受ASCII；正文通过独立UTF-8解码。
    if (bytes[i] > 127 || bytes[i] === 0) { empty.state = 'error'; return empty; }
    headers += String.fromCharCode(bytes[i]);
  }
  const lines: string[] = headers.split('\r\n');
  const first: string[] = lines[0].split(' ');
  if (first.length !== 3 || !new RegExp('^(GET|HEAD|POST)$').test(first[0]) ||
      first[1].length > 2048 || !first[1].startsWith('/') ||
      (first[2] !== 'HTTP/1.1' && first[2] !== 'HTTP/1.0')) {
    empty.state = 'error'; return empty;
  }
  let length: number = 0, lengthSeen: boolean = false;
  for (let i: number = 1; i < lines.length; i++) {
    const colon: number = lines[i].indexOf(':');
    if (colon <= 0) { empty.state = 'error'; return empty; }
    const name: string = lines[i].substring(0, colon).trim().toLowerCase();
    const value: string = lines[i].substring(colon + 1).trim();
    // 不支持chunked或重复长度，避免模棱两可的请求边界；响应统一Connection: close。
    if (name === 'transfer-encoding' || (name === 'content-length' && lengthSeen)) {
      empty.state = 'error'; return empty;
    }
    if (name === 'content-length') {
      if (!new RegExp('^[0-9]+$').test(value)) { empty.state = 'error'; return empty; }
      lengthSeen = true; length = Number(value);
    }
  }
  if (!Number.isSafeInteger(length) || length > OFFLINE_HTTP_BODY_LIMIT ||
      (first[0] !== 'POST' && length !== 0)) { empty.state = 'error'; return empty; }
  if (bytes.byteLength < split + 4 + length) return empty;
  return { state: 'complete', method: first[0], target: first[1], body: bytes.slice(split + 4, split + 4 + length) };
}

/** 皮肤模型只能附在SKIN节点，披风和皮肤独立可选，允许cape-only。 */
interface OfflineSkinMetadata { model: string; }
interface OfflineTextureUrl { url: string; metadata?: OfflineSkinMetadata; }
interface OfflineTextureMap { SKIN?: OfflineTextureUrl; CAPE?: OfflineTextureUrl; }
interface OfflineTexturePayload {
  timestamp: number;
  profileId: string;
  profileName: string;
  textures: OfflineTextureMap;
}

/** 返回待签名的最终Base64字符串；签名器必须签它的UTF-8字节而不是PNG或原始JSON。 */
export function offlineTextureValue(root: string, uuid: string, name: string, model: string,
  skinHash: string, capeHash: string, timestamp: number): string {
  const textures: OfflineTextureMap = {};
  if (skinHash.length > 0) {
    textures.SKIN = model === 'SLIM' ? { url: root + 'textures/' + skinHash, metadata: { model: 'slim' } } :
      { url: root + 'textures/' + skinHash };
  }
  if (capeHash.length > 0) textures.CAPE = { url: root + 'textures/' + capeHash };
  const payload: OfflineTexturePayload = { timestamp: timestamp, profileId: offlineProfileId(uuid), profileName: name, textures: textures };
  return encodeStandardBase64(stringToUtf8(JSON.stringify(payload)));
}

/** API20已有getEncoded()提供X.509/SPKI DER；不使用API26才支持的RSA getEncodedPem。 */
export function offlinePublicKeyPem(encoded: Uint8Array): string {
  const base64: string = encodeStandardBase64(encoded);
  let body: string = '';
  for (let i: number = 0; i < base64.length; i += 64) body += base64.substring(i, i + 64) + '\n';
  return '-----BEGIN PUBLIC KEY-----\n' + body + '-----END PUBLIC KEY-----\n';
}

/** Content-Length按编码字节计算；二进制响应由服务端使用同一函数拼头后发送。 */
export function offlineResponseHead(status: string, type: string, length: number): string {
  return 'HTTP/1.1 ' + status + '\r\nContent-Type: ' + type + '\r\nContent-Length: ' + length +
    '\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n';
}

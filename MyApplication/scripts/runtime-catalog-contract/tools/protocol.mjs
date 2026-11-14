/**
 * 目录 v1 的发行端契约。只使用 Node 标准库；签名覆盖原始 payload 字节。
 * 校验分为结构、固定身份、单调代次与可信公钥四层。未知 adapter 可以保留，
 * 是否可安装由客户端自己的能力表决定；目录不能携带路径、脚本或 JVM 参数。
 */
import { createHash, createPublicKey, sign, verify } from 'node:crypto';

export const MAX_CATALOG_BYTES = 1024 * 1024;
export const TYPE = 'amcl-runtime-catalog+jws';
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
/** fixture只可用隔离密钥；比较真实SPKI，不能改kid或另提供keys文件后误用生产私钥。 */
export function assertIsolatedFixtureKey(key,pinnedKeys){
  const spki=createPublicKey(key).export({type:'spki',format:'der'});
  assert(!pinnedKeys.keys.some(item=>typeof item.spki==='string'&&spki.equals(Buffer.from(item.spki,'base64'))),
    'FIXTURE_KEY_IS_PRODUCTION');
}
import { validateCatalog as validateV1, validateTransition as transitionV1, buildIdentity, runtimeIdentity } from '../lib/catalog-validation.mjs';
import { validateCatalogV2, validateTransitionV2 } from '../lib/catalog-v2.mjs';
export { buildIdentity, runtimeIdentity };
/** schema是签名payload的一部分；v1仍严格拒绝v2新增字段，绝不静默降级解释。 */
export function validateCatalog(c,channel){return c?.schemaVersion===2?validateCatalogV2(c,channel):validateV1(c,channel);}
/** 两投影不能逐字比较；发布工具按独立版本命名空间各自核对前代。 */
export function validateTransition(previous,next){
  if(previous&&previous.schemaVersion!==next.schemaVersion)throw Error('catalog format namespace mismatch');
  return next.schemaVersion===2?validateTransitionV2(previous,next):transitionV1(previous,next);
}
function assert(test, message) { if (!test) throw new Error(message); }
function object(x, name, keys) {
  assert(x !== null && typeof x === 'object' && !Array.isArray(x),name+': expected object');
  assert(Object.keys(x).every(k=>keys.includes(k)),name+': unknown field');
}
function id(x,name) { assert(typeof x==='string' && /^[a-z0-9][a-z0-9._-]{0,95}$/.test(x),name+': invalid id'); }

/** 解码前检查长度与规范编码，拒绝宽松 base64 对无效字符/多余位的容忍。 */
export function decode64(text) {
  assert(typeof text === 'string' && /^[A-Za-z0-9_-]+$/.test(text), 'invalid base64url');
  const bytes = Buffer.from(text, 'base64url');
  assert(bytes.toString('base64url') === text, 'noncanonical base64url'); return bytes;
}
export function signCatalog(catalog, key, kid) {
  validateCatalog(catalog); id(kid,'kid');
  const protectedHeader = Buffer.from(JSON.stringify({ alg:'ES256', typ:TYPE, kid })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(catalog)).toString('base64url');
  const signature = sign('sha256', Buffer.from(protectedHeader + '.' + payload), { key, dsaEncoding:'ieee-p1363' }).toString('base64url');
  return { protected:protectedHeader, payload, signature };
}

/** 只信任调用者固定公钥集；不能从待验证目录接受 jwk/x5u 或替换算法。 */
export function verifyEnvelope(bytes, keys, channel, now = Date.now(), allowExpired = false) {
  assert(Buffer.byteLength(bytes) <= MAX_CATALOG_BYTES, 'catalog too large');
  const envelope = JSON.parse(bytes);
  object(envelope,'JWS',['protected','payload','signature']);
  const header = JSON.parse(decode64(envelope.protected));
  object(header,'header',['alg','typ','kid']);
  assert(header.alg === 'ES256' && header.typ === TYPE, 'untrusted algorithm/type');
  const trusted = keys.keys.find(k => k.kid === header.kid);
  assert(trusted && trusted.algorithm === 'ES256', 'untrusted key');
  const pub = createPublicKey({key:Buffer.from(trusted.spki,'base64'),format:'der',type:'spki'});
  assert(pub.asymmetricKeyType === 'ec' && pub.asymmetricKeyDetails.namedCurve === 'prime256v1','wrong key curve');
  const signature = decode64(envelope.signature);
  assert(signature.length === 64 && verify('sha256',Buffer.from(envelope.protected+'.'+envelope.payload),{key:pub,dsaEncoding:'ieee-p1363'},signature),'bad signature');
  const catalog = validateCatalog(JSON.parse(decode64(envelope.payload)),channel);
  assert(Date.parse(catalog.issuedAt) <= now + 300000,'catalog issued in future');
  assert(allowExpired || Date.parse(catalog.expiresAt) > now,'catalog expired');
  return catalog;
}

/**
 * 历史签名只证明当时推荐的逐build宿主身份，绝不恢复旧下载头/有效期。保存原始JWS而非
 * 自报协议映射，首次v2迁移和legacy激活都能用固定公钥重算；未知/冲突仍由闭包拒绝。
 */
export function verifyRuntimeHostHistory(raw,keys){
  assert(Buffer.byteLength(raw)<=4*MAX_CATALOG_BYTES,'runtime host history too large');
  const value=JSON.parse(raw);
  assert(value?.schemaVersion===1&&Array.isArray(value.entries)&&value.entries.length>0&&value.entries.length<=128,'invalid runtime host history');
  return value.entries.map(entry=>{
    assert(entry&&typeof entry.raw==='string'&&/^[0-9a-f]{64}$/.test(entry.sha256)&&sha256(entry.raw)===entry.sha256&&
      ['stable','preview'].includes(entry.channel),'invalid historical signed catalog identity');
    return verifyEnvelope(entry.raw,keys,entry.channel,Date.now(),true);
  });
}

/**
 * 组合计划的有界槽位身份。v2只保存目录inode和两份元数据的完整SHA-256/字节数，
 * 不把合法的大receipt复制进before/history。旧[ino,tag,receipt]按原UTF-8文本语义比较，
 * 已经持久化的旧字符串保持原样，不能以迁移为由改写原始before或历史效果链。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { stringToUtf8 } from 'commons';
import { RUNTIME_INSTALL_RECEIPT_LIMIT } from 'launch';

interface MetadataDigest { size: number; sha256: string; }
interface SlotIdentity {
  schemaVersion: number; kind: string; inode: string;
  tagSize: number; tagSha256: string; receiptSize: number; receiptSha256: string;
}
interface ParsedSlotIdentity { value: SlotIdentity; legacy: boolean; }
interface SlotIoError { code?: number | string; message?: string; }
// 兼容旧记录最多65536个UTF-16码元的tag文本；只保留有界摘要，不把该预算复制进新计划。
const TAG_LIMIT: number = 262144;
const EMPTY_SHA256: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
function missing(error: Object): boolean {
  const detail = error as SlotIoError;
  return detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT';
}
function hex(bytes: Uint8Array): string {
  let result = '';
  for (const value of bytes) result += value.toString(16).padStart(2,'0');
  return result;
}
/** 旧记录包含文本，编码为原UTF-8字节再求摘要；不把JS字符数当字节数。 */
function textDigest(value: string, limit: number): MetadataDigest {
  const bytes = stringToUtf8(value);
  if (bytes.byteLength > limit) throw new Error('旧JDK槽位身份元数据超过预算');
  if (bytes.byteLength === 0) return {size:0,sha256:EMPTY_SHA256};
  const digest = cryptoFramework.createMd('SHA256'); digest.updateSync({data:bytes});
  return {size:bytes.byteLength,sha256:hex(digest.digestSync().data)};
}
/**
 * 只读真实普通文件；缺失与空文件分别记录。用同一NOFOLLOW fd流式计算完整摘要，读前后
 * 核对inode、长度和变更时间，短读/替换/权限故障不能被解释为“没有收据”。
 */
function metadataDigest(path: string, limit: number): MetadataDigest {
  let pathStat: fs.Stat;
  try { pathStat = fs.lstatSync(path); } catch (error) {
    if (missing(error as Object)) return {size:-1,sha256:''};
    throw error as Error;
  }
  if (!pathStat.isFile() || pathStat.size < 0 || pathStat.size > limit) throw new Error('JDK槽位身份元数据类型或大小无效');
  const file = fs.openSync(path,fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const before = fs.statSync(file.fd);
    if (!before.isFile() || before.ino !== pathStat.ino || before.size !== pathStat.size) throw new Error('JDK元数据在读取前改变');
    const digest = cryptoFramework.createMd('SHA256'); const buffer = new ArrayBuffer(65536);
    let offset = 0;
    while (offset < before.size) {
      const wanted = Math.min(buffer.byteLength,before.size - offset);
      const read = fs.readSync(file.fd,buffer,{length:wanted});
      if (!Number.isSafeInteger(read) || read <= 0 || read > wanted) throw new Error('JDK元数据未完整读取');
      digest.updateSync({data:new Uint8Array(buffer,0,read)}); offset += read;
    }
    const after = fs.statSync(file.fd); const current = fs.lstatSync(path);
    if (before.ino !== after.ino || before.size !== after.size || before.mtime !== after.mtime || before.ctime !== after.ctime ||
      current.ino !== before.ino || current.size !== before.size || !current.isFile()) throw new Error('JDK元数据在读取期间改变');
    return {size:offset,sha256:offset === 0 ? EMPTY_SHA256 : hex(digest.digestSync().data)};
  } finally { fs.closeSync(file); }
}
function validDigest(size: number, sha256: string, limit: number): boolean {
  return Number.isSafeInteger(size) && size >= -1 && size <= limit && typeof sha256 === 'string' &&
    (size === -1 ? sha256 === '' : new RegExp('^[0-9a-f]{64}$').test(sha256));
}
function parse(value: string): ParsedSlotIdentity {
  if (typeof value !== 'string' || value.length === 0 || value.length > 131072) throw new Error('JDK槽位身份记录长度无效');
  const legacy = JSON.parse(value) as string[];
  if (Array.isArray(legacy)) {
    if (legacy.length !== 3 || legacy.some((part: string): boolean => typeof part !== 'string') ||
      !new RegExp('^[0-9]{1,32}$').test(legacy[0])) throw new Error('旧JDK槽位身份格式无效');
    const tag = textDigest(legacy[1],TAG_LIMIT); const receipt = textDigest(legacy[2],RUNTIME_INSTALL_RECEIPT_LIMIT);
    return {legacy:true,value:{schemaVersion:2,kind:'amcl-jdk-slot',inode:legacy[0],tagSize:tag.size,tagSha256:tag.sha256,
      receiptSize:receipt.size,receiptSha256:receipt.sha256}};
  }
  const compact = JSON.parse(value) as SlotIdentity;
  const fields = ['schemaVersion','kind','inode','tagSize','tagSha256','receiptSize','receiptSha256'];
  if (compact === null || typeof compact !== 'object' || Object.keys(compact).some((key: string): boolean => fields.indexOf(key) < 0) ||
    compact.schemaVersion !== 2 || compact.kind !== 'amcl-jdk-slot' || typeof compact.inode !== 'string' ||
    !new RegExp('^[0-9]{1,32}$').test(compact.inode) || !validDigest(compact.tagSize,compact.tagSha256,TAG_LIMIT) ||
    !validDigest(compact.receiptSize,compact.receiptSha256,RUNTIME_INSTALL_RECEIPT_LIMIT)) throw new Error('JDK槽位紧凑身份格式无效');
  return {legacy:false,value:compact};
}
/** 用于readPlan验证身份版本；不改写传入字符串。 */
export function validateJdkSlotIdentity(value: string): void { parse(value); }

/** 所有新观察都使用常量大小的v2记录；收据上限与生产receipt读取契约一致为1MiB。 */
export function jdkSlotIdentity(filesDir: string, major: string): string {
  const path = filesDir + '/jdk/' + major; const directory = fs.lstatSync(path);
  if (!directory.isDirectory()) throw new Error('JDK槽位不是独立真实目录');
  const tag = metadataDigest(path + '/.amcl_release_tag',TAG_LIMIT);
  const receipt = metadataDigest(path + '/.amcl-runtime-receipt.json',RUNTIME_INSTALL_RECEIPT_LIMIT);
  const current = fs.lstatSync(path);
  if (!current.isDirectory() || current.ino !== directory.ino) throw new Error('JDK槽位在观察期间改变');
  const value: SlotIdentity = {schemaVersion:2,kind:'amcl-jdk-slot',inode:directory.ino.toString(),
    tagSize:tag.size,tagSha256:tag.sha256,receiptSize:receipt.size,receiptSha256:receipt.sha256};
  return JSON.stringify(value);
}
/** 旧语义将缺失与空文本等同；只在一侧确为legacy时保留该兼容，不削弱两个v2记录的比较。 */
export function sameJdkSlotIdentity(observed: string, expected: string): boolean {
  const a = parse(observed); const b = parse(expected);
  if (a.legacy || b.legacy) {
    for (const record of [a.value,b.value]) {
      if (record.tagSize === -1) { record.tagSize = 0; record.tagSha256 = EMPTY_SHA256; }
      if (record.receiptSize === -1) { record.receiptSize = 0; record.receiptSha256 = EMPTY_SHA256; }
    }
  }
  return a.value.inode === b.value.inode && a.value.tagSize === b.value.tagSize && a.value.tagSha256 === b.value.tagSha256 &&
    a.value.receiptSize === b.value.receiptSize && a.value.receiptSha256 === b.value.receiptSha256;
}

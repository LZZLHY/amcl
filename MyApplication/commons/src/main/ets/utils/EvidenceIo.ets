/** 证据文件 IO：固定范围、内容摘要、原子元数据和活动保留租约。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { stringToUtf8 } from './Base64Util';
import { AtomicFileWriter, AtomicWriteError } from './AtomicFileWriter';

const IO_CHUNK: number = 64 * 1024;
/** 准备代次失效属于尚未提交的重试，不能被改写为partial成功或吞成普通IO缺失。 */
export class EvidencePreparationStaleError extends Error {
  constructor() { super('恢复准备的游戏边界或运行事实已变化，旧候选保留等待重新核验'); this.name = 'EvidencePreparationStaleError'; }
}

/** guard只读owner代次；native rename在途仍须由game-admission互斥保护，检查不是原子CAS，已发布失效走unknown。 */
export function assertEvidencePreparationCurrent(isCurrent: (() => boolean) | undefined): void {
  if (isCurrent !== undefined && !isCurrent()) throw new EvidencePreparationStaleError();
}
const leases: Map<string, number> = new Map<string, number>();
/** 删除由启动器owner在首个await之前认领；认领后不允许新读取或提交进入同一活动。 */
const deleting: Set<string> = new Set<string>();
/** 不反向import账本；持久写完成后由账本装配的观察者标记该局占用失效。 */
let mutationObserver: ((path: string) => void) | undefined = undefined;
let leaseReleaseObserver: ((filesDir: string, activityId: number) => void) | undefined = undefined;
/** 已发布但目录同步失败的路径必须先重新确认耐久，不能借内容相同走无写快路径。 */
const uncertainWrites: Set<string> = new Set<string>();
/** 普通原件copy已rename而父目录同步/发布资格未确认时共用unknown登记，不删除或假回滚新目标。 */
export function noteEvidencePublicationUnknown(path: string): void {
  uncertainWrites.add(path); if (mutationObserver !== undefined) mutationObserver(path);
}

/** 每个进程独立安装；游戏进程不获得启动器维护权限。 */
export function setEvidenceMutationObserver(observer: (path: string) => void): void { mutationObserver = observer; }
export function setEvidenceLeaseReleaseObserver(observer: (filesDir: string, activityId: number) => void): void { leaseReleaseObserver = observer; }
/** 返回false时保留现有reader；本函数不await，检查与claim在同一owner事件循环内完成。 */
export function tryClaimEvidenceDeletion(filesDir: string, activityId: number): boolean {
  const key: string = filesDir + '/' + activityId;
  if (deleting.has(key) || (leases.get(key) ?? 0) > 0) return false;
  deleting.add(key); return true;
}
/** 删除完成或失败后释放本轮claim；失败目录仍存在，调用方必须标记占用待重查。 */
export function releaseEvidenceDeletion(filesDir: string, activityId: number): void { deleting.delete(filesDir + '/' + activityId); }
export function isEvidenceDeleting(filesDir: string, activityId: number): boolean { return deleting.has(filesDir + '/' + activityId); }
/** 写入和pin由相同owner调用；不能在异步删除期间复活同一目录。 */
export function assertEvidenceWritable(filesDir: string, activityId: number): void {
  if (isEvidenceDeleting(filesDir, activityId)) throw new Error('活动日志正在删除，请稍后重试');
}

/** 租约只保护本进程中的清理；分享在 await 前持有，并在 finally 释放。 */
export function acquireEvidenceLease(filesDir: string, activityId: number): void {
  const key: string = filesDir + '/' + activityId;
  if (deleting.has(key)) throw new Error('活动日志正在删除，暂时无法读取或导出');
  leases.set(key, (leases.get(key) ?? 0) + 1);
}
export function releaseEvidenceLease(filesDir: string, activityId: number): void {
  const key: string = filesDir + '/' + activityId;
  const count: number = (leases.get(key) ?? 0) - 1;
  if (count <= 0) { leases.delete(key); if (leaseReleaseObserver !== undefined) leaseReleaseObserver(filesDir, activityId); }
  else leases.set(key, count);
}
export function hasEvidenceLease(filesDir: string, activityId: number): boolean {
  return (leases.get(filesDir + '/' + activityId) ?? 0) > 0;
}

/**
 * 普通私有证据目录的真正异步ensure。FileIO.mkdir(path,true)仍可能对已有目标报13900015，
 * 只有实际收到该EEXIST后，且重新lstat证明目标是真目录而非符号链接时才允许复用。
 * 创建成功也核实最终路径类型；文件占位、链接、权限错误及核验期间消失均原样失败，
 * 不通过access预判吞掉异常，也不覆盖、删除或循环重建其他写者的目录。
 * 本函数不适用于原子写的独占pending-dir；那些命名空间必须原始mkdir成功才取得所有权。
 */
export async function ensureEvidenceDirectoryAsync(path: string): Promise<void> {
  try { await fs.mkdir(path, true); }
  catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
  const current = await fs.lstat(path);
  if (!current.isDirectory() || current.isSymbolicLink()) throw new Error('证据目录路径不是普通目录，原始资料未改动');
}

export function evidenceHex(bytes: Uint8Array): string {
  let result: string = '';
  for (const value of bytes) result += value.toString(16).padStart(2, '0');
  return result;
}
/**
 * 文本内容的SHA-256；空串也是有效的内容身份。Md接口明确允许省略update直接digest，
 * 当前真机的零长度DataBlob会在native Update处失败，因此空UTF-8仅做digestSync，
 * 不补造占位字节，也不捕获/吞掉非空消息的加密错误。
 */
export function evidenceTextDigest(value: string): string {
  const digest = cryptoFramework.createMd('SHA256');
  const bytes: Uint8Array = stringToUtf8(value);
  if (bytes.byteLength > 0) digest.updateSync({ data: bytes });
  return evidenceHex(digest.digestSync().data);
}

/** 采集基线的内容身份，固定块读取，避免秒级时间戳碰撞。 */
export function evidenceFileDigestSync(path: string): string {
  const opened = fs.openSync(path, fs.OpenMode.READ_ONLY);
  const digest = cryptoFramework.createMd('SHA256');
  try {
    const length: number = fs.statSync(opened.fd).size;
    let position: number = 0;
    while (position < length) {
      const buffer = new ArrayBuffer(Math.min(IO_CHUNK, length - position));
      const got: number = fs.readSync(opened.fd, buffer, { offset: position, length: buffer.byteLength });
      if (got <= 0) throw new Error('基线文件读取不完整');
      digest.updateSync({ data: new Uint8Array(buffer, 0, got) });
      position += got;
    }
    return evidenceHex(digest.digestSync().data);
  } finally { fs.closeSync(opened); }
}

export async function hashGzipEvidenceContent(path: string): Promise<string> {
  const gzip = zlib.createGZipSync();
  const digest = cryptoFramework.createMd('SHA256');
  try {
    await gzip.gzopen(path, 'rb');
    while (true) {
      const buffer = new ArrayBuffer(IO_CHUNK);
      const got: number = await gzip.gzfread(buffer, 1, IO_CHUNK);
      if (got < 0) throw new Error('gzip 分片损坏');
      if (got === 0) break;
      await digest.update({ data: new Uint8Array(buffer, 0, got) });
    }
    return evidenceHex((await digest.digest()).data);
  } finally { await gzip.gzcloser(); }
}

/** 纳秒时间是变更提示，SHA-256 才是内容身份；inode 防止路径替换。 */
export function evidenceFileStamp(path: string | number): string {
  const stat = fs.statSync(path);
  if (!stat.isFile()) throw new Error('证据路径不是普通文件');
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime)
    + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/** 证据与更新共用完整提交算法；保留TypedError以便调用方识别发布后持久性未知。 */
export function writeEvidenceTextAtomic(path: string, text: string): void {
  const lease = acquireWriteLease_(path);
  try {
    AtomicFileWriter.write(path, text); uncertainWrites.delete(path);
    if (mutationObserver !== undefined) mutationObserver(path);
  } catch (error) {
    if (error instanceof AtomicWriteError && error.published) { uncertainWrites.add(path); if (mutationObserver !== undefined) mutationObserver(path); }
    throw error as Error;
  } finally { releaseWriteLease_(lease); }
}

interface EvidenceWriteLease { filesDir: string; activityId: number; }
/** 原子写在首个await前持租约，异步删除不能穿过“写完检查→rename”之间的空隙。 */
function acquireWriteLease_(path: string): EvidenceWriteLease | undefined {
  const marker: string = '/logs/ledger/'; const position: number = path.indexOf(marker);
  if (position < 0) return undefined;
  const idText: string = path.substring(position + marker.length).split('/')[0];
  if (!new RegExp('^[1-9][0-9]*$').test(idText)) return undefined;
  const lease: EvidenceWriteLease = { filesDir: path.substring(0, position), activityId: Number(idText) };
  acquireEvidenceLease(lease.filesDir, lease.activityId); return lease;
}
function releaseWriteLease_(lease: EvidenceWriteLease | undefined): void {
  if (lease !== undefined) releaseEvidenceLease(lease.filesDir, lease.activityId);
}
/** 只对本进程实知不确定发布重同步；正常无变化恢复无需新增fsync。 */
export async function ensureEvidenceTextDurableAsync(path: string): Promise<void> {
  if (!uncertainWrites.has(path)) return;
  const lease = acquireWriteLease_(path);
  try {
    const file = await fs.open(path, fs.OpenMode.READ_WRITE);
    try { await fs.fsync(file.fd); } finally { await fs.close(file); }
    const parent = await fs.open(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
    try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
    uncertainWrites.delete(path);
  } finally { releaseWriteLease_(lease); }
}
/** 同步兼容入口只在已知不确定提交时重同步；无变化的正常路径仍零写入。 */
export function ensureEvidenceTextDurable(path: string): void {
  if (!uncertainWrites.has(path)) return;
  const lease = acquireWriteLease_(path);
  try {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE);
    try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    const parent = fs.openSync(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
    uncertainWrites.delete(path);
  } catch (_) { throw new AtomicWriteError(true); }
  finally { releaseWriteLease_(lease); }
}

/**
 * owner使用的真正异步原子写：独占临时目录、短写循环、文件fsync、rename及父目录fsync。
 * 与同步AtomicFileWriter保持同一发布失败分类；rename之后的异常保留新目标，禁止假回滚。
 * 临时命名空间只清理本次创建的空目录，不递归清理其他写者现场。
 */
export async function writeEvidenceTextAtomicAsync(path: string, text: string,
  publishGuard: (() => boolean) | undefined = undefined): Promise<void> {
  const lease = acquireWriteLease_(path);
  let temporaryDirectory: string = '';
  let temporary: string = '';
  let owned: boolean = false;
  let published: boolean = false;
  let file: fs.File | undefined = undefined;
  let parent: fs.File | undefined = undefined;
  try {
    assertEvidencePreparationCurrent(publishGuard);
    const slash: number = path.lastIndexOf('/');
    if (slash <= 0 || slash === path.length - 1 || new RegExp('[\\r\\n\\x00]').test(path)) throw new Error('原子写入路径无效');
    // pending-dir的EEXIST是他人的命名空间，不能按ensure语义复用；只换新UUID有界重试。
    for (let attempt: number = 0; attempt < 8; attempt++) {
      temporaryDirectory = path + '.' + util.generateRandomUUID() + '.pending-dir';
      try { await fs.mkdir(temporaryDirectory); owned = true; break; }
      catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    }
    if (!owned) throw new Error('独占临时目录连续冲突，原始目标未提交');
    temporary = temporaryDirectory + '/content.pending';
    file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
    const bytes: Uint8Array = stringToUtf8(text);
    let offset: number = 0;
    while (offset < bytes.byteLength) {
      const chunk: Uint8Array = bytes.slice(offset, Math.min(offset + IO_CHUNK, bytes.byteLength));
      const written: number = await fs.write(file.fd, chunk.buffer as ArrayBuffer);
      if (!Number.isInteger(written) || written <= 0 || written > chunk.byteLength) throw new Error('文件写入未取得有效字节数');
      offset += written;
    }
    await fs.fsync(file.fd); await fs.close(file); file = undefined;
    assertEvidencePreparationCurrent(publishGuard);
    await fs.rename(temporary, path); published = true;
    // async rename派发到落盘之间也可能失效。已发布时继续沿unknown路径保留目标，绝不假称回滚。
    assertEvidencePreparationCurrent(publishGuard);
    parent = await fs.open(path.substring(0, slash), fs.OpenMode.READ_ONLY);
    await fs.fsync(parent.fd); await fs.close(parent); parent = undefined;
    uncertainWrites.delete(path);
    try { await fs.rmdir(temporaryDirectory); } catch (_) { /* 只留下本轮空命名空间。 */ }
    if (mutationObserver !== undefined) mutationObserver(path);
  } catch (error) {
    if (file !== undefined) { try { await fs.close(file); } catch (_) {} }
    if (parent !== undefined) { try { await fs.close(parent); } catch (_) {} }
    if (!published && owned) { try { await fs.unlink(temporary); } catch (_) {} }
    if (owned) { try { await fs.rmdir(temporaryDirectory); } catch (_) {} }
    if (published) { uncertainWrites.add(path); if (mutationObserver !== undefined) mutationObserver(path); }
    if (!published && error instanceof EvidencePreparationStaleError) throw error;
    throw new AtomicWriteError(published);
  } finally { releaseWriteLease_(lease); }
}

/** 同步基线摘要的异步等价实现；固定句柄/长度，读取期间变化不签发稳定身份。 */
export async function evidenceFileDigestAsync(path: string): Promise<string> {
  const opened = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const before: string = await evidenceFileStampAsync(opened.fd);
    const digest: string = await hashEvidenceRange(opened.fd, (await fs.stat(opened.fd)).size);
    if (before !== await evidenceFileStampAsync(opened.fd)) throw new Error('证据在核验期间发生变化');
    return digest;
  } finally { await fs.close(opened); }
}
/** 元数据仅用作变化提示；真正完整性仍依赖固定SHA-256收据。 */
export async function evidenceFileStampAsync(path: string | number): Promise<string> {
  const stat = await fs.stat(path);
  if (!stat.isFile()) throw new Error('证据路径不是普通文件');
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/** 读取固定的字节范围并校验短读；每次 IO 有界，取消后不再读取下一块。 */
export async function hashEvidenceRange(fd: number, length: number,
  destinationFd: number = -1, cancelled?: () => boolean): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  let position: number = 0;
  while (position < length) {
    if (cancelled !== undefined && cancelled()) throw new Error('证据核验已取消');
    const buffer = new ArrayBuffer(Math.min(IO_CHUNK, length - position));
    const got: number = await fs.read(fd, buffer, { offset: position, length: buffer.byteLength });
    if (cancelled !== undefined && cancelled()) throw new Error('证据核验已取消');
    if (got <= 0) throw new Error('证据在冻结期间被截断');
    const data = new Uint8Array(buffer, 0, got);
    await digest.update({ data: data });
    if (destinationFd >= 0) {
      let written: number = 0;
      while (written < got) {
        const count: number = await fs.write(destinationFd, data.slice(written).buffer as ArrayBuffer);
        if (count <= 0) throw new Error('冻结证据时磁盘短写');
        written += count;
      }
    }
    position += got;
  }
  return evidenceHex((await digest.digest()).data);
}

export interface EvidenceTextPage {
  text: string;
  eof: boolean;
  bytesRead: number;
}

/** 顺序文本游标，同时支持 gzip；UTF-8 解码状态跨块保留，内存与文件大小无关。 */
export class EvidenceTextCursor {
  private file: fs.File | undefined = undefined;
  private gzip: zlib.GZip | undefined = undefined;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  private position: number = 0;
  private length: number = 0;
  private ended: boolean = false;
  private cancelled: boolean = false;
  private live: boolean = false;
  private path: string = '';
  private inode: string = '';
  private stamp: string = '';

  async open(path: string, compressed: boolean = false, live: boolean = false): Promise<void> {
    if (live && compressed) throw new Error('压缩归档不支持跟随追加');
    this.live = live; this.path = path;
    if (compressed) {
      this.gzip = zlib.createGZipSync();
      await this.gzip.gzopen(path, 'rb');
    } else {
      this.file = await fs.open(path, fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(this.file.fd);
      this.length = stat.size; this.inode = String(stat.ino); this.stamp = evidenceFileStamp(path);
    }
  }

  async read(maxBytes: number = IO_CHUNK): Promise<EvidenceTextPage> {
    if (this.cancelled) throw new Error('证据读取已取消');
    if (this.ended) return { text: '', eof: true, bytesRead: 0 };
    const request: number = Math.max(1, Math.min(maxBytes, IO_CHUNK));
    const buffer = new ArrayBuffer(request);
    let got: number = 0;
    if (this.gzip !== undefined) {
      got = await this.gzip.gzfread(buffer, 1, request);
      if (got < 0) throw new Error('gzip 证据解压失败');
      this.ended = got === 0 || await this.gzip.gzeof() === 1;
    } else if (this.file !== undefined) {
      const remaining: number = this.length - this.position;
      if (remaining > 0) got = await fs.read(this.file.fd, buffer, {
        offset: this.position, length: Math.min(request, remaining),
      });
      if (got <= 0 && remaining > 0) throw new Error('证据读取期间被截断');
      this.position += got;
      this.ended = this.position >= this.length;
    } else throw new Error('证据游标尚未打开');
    if (this.cancelled) throw new Error('证据读取已取消');
    const text: string = this.decoder.decodeToString(new Uint8Array(buffer, 0, got), { stream: this.live || !this.ended });
    return { text: text, eof: this.ended, bytesRead: got };
  }

  cancel(): void { this.cancelled = true; }
  /** 普通快照长度固定；仅显式 live 游标扩展到新 EOF，保留解码器和偏移，不重复读取旧正文。 */
  async refreshLive(): Promise<number> {
    if (!this.live || this.file === undefined || this.cancelled) throw new Error('跟随读取未就绪');
    const stat = await fs.stat(this.path);
    if (String(stat.ino) !== this.inode || stat.size < this.length) throw new Error('日志已被替换或截短，请重新选择文件');
    const current: string = evidenceFileStamp(this.path);
    if (stat.size === this.length && current !== this.stamp) throw new Error('日志原位内容发生变化，请重新读取');
    this.length = stat.size; this.stamp = current; this.ended = this.position >= this.length;
    return this.length;
  }
  async close(): Promise<void> {
    if (this.file !== undefined) { await fs.close(this.file); this.file = undefined; }
    if (this.gzip !== undefined) { await this.gzip.gzcloser(); this.gzip = undefined; }
  }
}

/** 有界完整读取用于网络正文；恰好等于预算时额外读一字节确认 EOF。 */
export async function readEvidenceTextBounded(path: string, compressed: boolean,
  maxBytes: number): Promise<EvidenceTextPage> {
  const cursor = new EvidenceTextCursor();
  const parts: string[] = [];
  let count: number = 0;
  let eof: boolean = false;
  try {
    await cursor.open(path, compressed);
    while (!eof && count < maxBytes) {
      const page = await cursor.read(Math.min(IO_CHUNK, maxBytes - count));
      parts.push(page.text); count += page.bytesRead; eof = page.eof;
    }
    if (!eof && count === maxBytes) {
      const probe = await cursor.read(1);
      eof = probe.bytesRead === 0 && probe.eof;
      if (eof) parts.push(probe.text);
    }
    return { text: parts.join(''), eof: eof, bytesRead: count };
  } finally { await cursor.close(); }
}

/** 证据文件 IO：固定范围、内容摘要、原子元数据和活动保留租约。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { stringToUtf8 } from './Base64Util';

const IO_CHUNK: number = 64 * 1024;
let writeSequence: number = 0;
const leases: Map<string, number> = new Map<string, number>();

/** 租约只保护本进程中的清理；分享在 await 前持有，并在 finally 释放。 */
export function acquireEvidenceLease(filesDir: string, activityId: number): void {
  const key: string = filesDir + '/' + activityId;
  leases.set(key, (leases.get(key) ?? 0) + 1);
}
export function releaseEvidenceLease(filesDir: string, activityId: number): void {
  const key: string = filesDir + '/' + activityId;
  const count: number = (leases.get(key) ?? 0) - 1;
  if (count <= 0) leases.delete(key); else leases.set(key, count);
}
export function hasEvidenceLease(filesDir: string, activityId: number): boolean {
  return (leases.get(filesDir + '/' + activityId) ?? 0) > 0;
}

export function evidenceHex(bytes: Uint8Array): string {
  let result: string = '';
  for (const value of bytes) result += value.toString(16).padStart(2, '0');
  return result;
}
export function evidenceTextDigest(value: string): string {
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: stringToUtf8(value) });
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

export function writeEvidenceTextAtomic(path: string, text: string): void {
  const temporary: string = path + '.tmp-' + Date.now() + '-' + (++writeSequence);
  let opened: fs.File | undefined = undefined;
  try {
    opened = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    const bytes: Uint8Array = stringToUtf8(text);
    let position: number = 0;
    while (position < bytes.length) {
      const chunk: ArrayBuffer = bytes.slice(position, Math.min(position + IO_CHUNK, bytes.length)).buffer as ArrayBuffer;
      const written: number = fs.writeSync(opened.fd, chunk);
      if (written <= 0) throw new Error('证据元数据短写');
      position += written;
    }
    fs.fsyncSync(opened.fd);
    fs.closeSync(opened); opened = undefined;
    fs.renameSync(temporary, path);
    const parent: fs.File = fs.openSync(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(parent.fd); } finally { fs.closeSync(parent); }
  } catch (e) {
    if (opened !== undefined) fs.closeSync(opened);
    try { fs.unlinkSync(temporary); } catch (ignored) { /* 可能尚未创建 */ }
    throw new Error('证据元数据保存失败：' + (e as Error).message);
  }
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

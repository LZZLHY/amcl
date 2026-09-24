/** Bounded random access ZIP reader. Reads metadata/nested JARs without extracting a mod. */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

export interface ModZipEntry {
  name: string;
  method: number;
  compressedSize: number;
  size: number;
  offset: number;
  crc: number;
  flags: number;
}

export function modBytesText(bytes: ArrayBuffer): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes));
}

export function modCrc32(bytes: ArrayBuffer): number {
  let crc = 0xffffffff;
  for (const byte of new Uint8Array(bytes)) {
    crc ^= byte;
    for (let j = 0; j < 8; j++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export async function inflateModEntry(input: ArrayBuffer, size: number): Promise<ArrayBuffer> {
  const output = new ArrayBuffer(size + 1);
  const zip = await zlib.createZip();
  const init: zlib.ZStream = { nextIn: input, availableIn: input.byteLength };
  const state = await zip.inflateInit2(init, -15);
  if (state !== zlib.ReturnStatus.OK) throw new Error('无法初始化模组 ZIP 解压');
  try {
    const stream: zlib.ZStream = { nextOut: output, availableOut: output.byteLength };
    const status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
    const finalStream = await zip.getZStream();
    if (status !== zlib.ReturnStatus.STREAM_END || finalStream.totalOut !== size
      || finalStream.totalIn !== input.byteLength) throw new Error('模组 ZIP 条目长度不符');
    return output.slice(0, size);
  } finally {
    const end: zlib.ZStream = {};
    await zip.inflateEnd(end);
  }
}

export class ModZipReader {
  private path_: string;
  private memory_: ArrayBuffer | undefined;
  private size_: number;
  private entries_: ModZipEntry[] = [];

  constructor(path: string, memory?: ArrayBuffer) {
    this.path_ = path;
    this.memory_ = memory;
    this.size_ = memory !== undefined ? memory.byteLength : fs.statSync(path).size;
  }

  private read(offset: number, length: number): ArrayBuffer {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0
      || offset + length > this.size_) throw new Error('模组 ZIP 范围越界：' + this.path_);
    if (this.memory_ !== undefined) return this.memory_.slice(offset, offset + length);
    const file = fs.openSync(this.path_, fs.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(length);
    try {
      let done = 0;
      while (done < length) {
        const part = new ArrayBuffer(length - done);
        const n = fs.readSync(file.fd, part, { offset: offset + done, length: length - done });
        if (n <= 0) throw new Error('模组 ZIP 读取不完整：' + this.path_);
        new Uint8Array(buffer).set(new Uint8Array(part, 0, n), done);
        done += n;
      }
    } finally { fs.closeSync(file); }
    return buffer;
  }

  load(): void {
    const tailSize = Math.min(this.size_, 65557);
    if (tailSize < 22) throw new Error('不是完整的模组 JAR：' + this.path_);
    const tail = new DataView(this.read(this.size_ - tailSize, tailSize));
    let end = -1;
    for (let p = tailSize - 22; p >= 0; p--) {
      if (tail.getUint32(p, true) === 0x06054b50 && p + 22 + tail.getUint16(p + 20, true) === tailSize) {
        end = p; break;
      }
    }
    if (end < 0 || tail.getUint16(end + 4, true) !== 0 || tail.getUint16(end + 6, true) !== 0)
      throw new Error('模组 ZIP 中央目录无效：' + this.path_);
    const count = tail.getUint16(end + 10, true);
    const directorySize = tail.getUint32(end + 12, true);
    const directoryOffset = tail.getUint32(end + 16, true);
    if (count === 65535 || directorySize > 16 * 1024 * 1024 || directoryOffset === 0xffffffff)
      throw new Error('模组 ZIP 中央目录超出可验证范围：' + this.path_);
    if (directoryOffset + directorySize > this.size_ - tailSize + end)
      throw new Error('模组 ZIP 中央目录重叠：' + this.path_);
    const bytes = this.read(directoryOffset, directorySize);
    const view = new DataView(bytes);
    let pos = 0;
    const entries: ModZipEntry[] = [];
    for (let i = 0; i < count; i++) {
      if (pos + 46 > bytes.byteLength || view.getUint32(pos, true) !== 0x02014b50)
        throw new Error('模组 ZIP 中央条目无效');
      const nameLength = view.getUint16(pos + 28, true);
      const recordLength = 46 + nameLength + view.getUint16(pos + 30, true) + view.getUint16(pos + 32, true);
      if (pos + recordLength > bytes.byteLength) throw new Error('模组 ZIP 条目越界');
      const name = modBytesText(bytes.slice(pos + 46, pos + 46 + nameLength));
      const entry: ModZipEntry = { name: name, flags: view.getUint16(pos + 8, true), method: view.getUint16(pos + 10, true),
        compressedSize: view.getUint32(pos + 20, true), size: view.getUint32(pos + 24, true),
        offset: view.getUint32(pos + 42, true), crc: view.getUint32(pos + 16, true) };
      entries.push(entry);
      pos += recordLength;
    }
    if (pos !== directorySize) throw new Error('模组 ZIP 中央目录长度不符');
    this.entries_ = entries;
  }

  names(): string[] { return this.entries_.map((e: ModZipEntry): string => e.name); }

  async entry(name: string, limit: number = 1024 * 1024): Promise<ArrayBuffer | undefined> {
    const candidates = this.entries_.filter((e: ModZipEntry): boolean => e.name === name);
    if (candidates.length === 0) return undefined;
    if (candidates.length !== 1) throw new Error('模组 ZIP 包含重复条目：' + name);
    const e = candidates[0];
    if (e.size > limit || e.compressedSize > limit || (e.flags & 1) !== 0 || (e.method !== 0 && e.method !== 8))
      throw new Error('无法安全读取模组条目：' + name);
    const header = new DataView(this.read(e.offset, 30));
    if (header.getUint32(0, true) !== 0x04034b50 || header.getUint16(8, true) !== e.method)
      throw new Error('模组 ZIP 本地条目与目录不符：' + name);
    const nameLength = header.getUint16(26, true);
    if (modBytesText(this.read(e.offset + 30, nameLength)) !== name) throw new Error('模组 ZIP 文件名不符');
    const input = this.read(e.offset + 30 + nameLength + header.getUint16(28, true), e.compressedSize);
    const output = e.method === 0 ? input : await inflateModEntry(input, e.size);
    if (output.byteLength !== e.size || modCrc32(output) !== e.crc) throw new Error('模组 ZIP 校验失败：' + name);
    return output;
  }
}

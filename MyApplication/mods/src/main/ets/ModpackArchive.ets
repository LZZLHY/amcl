/**
 * 整合包 ZIP 的只读预检。只读尾部与中央目录，并核对每个 local header；在平台解压前
 * 拒绝越界路径、链接、重名、加密、多磁盘和重叠数据。ZIP64 数值保持安全整数，不截断。
 * 本模块不执行归档内容，也不解压 JAR。调用者仍须等待平台解压结束，再核对实际产物。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeRelPath } from 'feature_core';

export interface ModpackArchiveEntry {
  path: string;
  directory: boolean;
  size: number;
  compressedSize: number;
  crc32: number;
  localOffset: number;
  dataEnd: number;
}
export interface ModpackArchiveSummary {
  entries: number;
  uncompressedBytes: number;
  compressedBytes: number;
  files: ModpackArchiveEntry[];
}
const MAX_ENTRIES = 200000;
const MAX_BYTES = 16 * 1024 * 1024 * 1024;
const MAX_CENTRAL = 32 * 1024 * 1024;

/** 在入口与短循环中检查取消；不持有平台解压句柄，因此取消只影响本只读调用。 */
function checkCancel(cancelled: () => boolean): void {
  if (cancelled()) throw new Error('整合包发现已取消');
}
function safeNumber(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('ZIP 尺寸或偏移无效');
  return value;
}
function u64(view: DataView, offset: number): number {
  if (offset + 8 > view.byteLength) throw new Error('ZIP64 字段截断');
  return safeNumber(view.getUint32(offset, true) + view.getUint32(offset + 4, true) * 4294967296);
}
/** readSync 的 offset 是文件内读取位置；短读必须补全，绝不把未读的零填充当作文件内容。 */
function readAt(fd: number, offset: number, length: number, fileSize: number): Uint8Array {
  safeNumber(offset); safeNumber(length);
  if (offset + length > fileSize) throw new Error('ZIP 字段超出文件边界');
  const result = new Uint8Array(length);
  let done = 0;
  while (done < length) {
    const block = new ArrayBuffer(length - done);
    const count = fs.readSync(fd, block, { offset: offset + done, length: length - done });
    if (count <= 0 || count > length - done) throw new Error('ZIP 读取不完整');
    result.set(new Uint8Array(block, 0, count), done); done += count;
  }
  return result;
}
/** ZIP 中目录可带一个末尾斜杠；其他路径必须是原样安全相对路径，不能静默修复穿越。 */
function entryPath(name: Uint8Array): string {
  let value: string;
  try { value = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(name); }
  catch (_) { throw new Error('ZIP 文件名不是支持的 UTF-8 编码'); }
  if (value.endsWith('/')) value = value.substring(0, value.length - 1);
  if (value.length === 0 || safeRelPath(value) !== value || value.indexOf(':') >= 0) {
    throw new Error('ZIP 包含不安全路径');
  }
  return value;
}
interface CentralLocation { offset: number; size: number; count: number; end: number; }
/** EOCD 必须结束于文件尾（包括注释）；不接受多磁盘或不一致的 ZIP64 回退字段。 */
function locateCentral(fd: number, size: number): CentralLocation {
  const length = Math.min(size, 65557);
  const tail = readAt(fd, size - length, length, size);
  const view = new DataView(tail.buffer);
  let position = -1;
  for (let i = length - 22; i >= 0; i--) {
    if (view.getUint32(i, true) === 0x06054b50 && i + 22 + view.getUint16(i + 20, true) === length) {
      position = i; break;
    }
  }
  if (position < 0) throw new Error('归档没有完整 ZIP 中央目录');
  if (view.getUint16(position + 4, true) !== 0 || view.getUint16(position + 6, true) !== 0) throw new Error('不支持多磁盘 ZIP');
  let count = view.getUint16(position + 10, true);
  if (view.getUint16(position + 8, true) !== count) throw new Error('ZIP 条目计数不一致');
  let centralSize = view.getUint32(position + 12, true);
  let offset = view.getUint32(position + 16, true);
  let end = size - length + position;
  if (count === 65535 || centralSize === 0xffffffff || offset === 0xffffffff) {
    if (end < 20) throw new Error('ZIP64 locator 缺失');
    const locator = new DataView(readAt(fd, end - 20, 20, size).buffer);
    if (locator.getUint32(0, true) !== 0x07064b50 || locator.getUint32(4, true) !== 0 || locator.getUint32(16, true) !== 1) throw new Error('ZIP64 locator 无效');
    const zip64Offset = u64(locator, 8);
    const record = new DataView(readAt(fd, zip64Offset, 56, size).buffer);
    if (record.getUint32(0, true) !== 0x06064b50 || u64(record, 4) < 44
      || zip64Offset + 12 + u64(record, 4) !== end - 20
      || record.getUint32(16, true) !== 0 || record.getUint32(20, true) !== 0) throw new Error('ZIP64 结束记录无效');
    count = u64(record, 32);
    if (u64(record, 24) !== count) throw new Error('ZIP64 条目计数不一致');
    centralSize = u64(record, 40); offset = u64(record, 48); end = zip64Offset;
  }
  if (count > MAX_ENTRIES || centralSize > MAX_CENTRAL || offset + centralSize !== end) throw new Error('ZIP 中央目录大小、数量或边界超限');
  return { offset, size: centralSize, count, end };
}
interface ZipSizes { size: number; compressed: number; offset: number; }
/** ZIP64 extra 的字段按相应 sentinel 顺序出现，不能假设三项永远齐全。 */
function zipSizes(extra: Uint8Array, size: number, compressed: number, offset: number): ZipSizes {
  const view = new DataView(extra.buffer, extra.byteOffset, extra.byteLength);
  let cursor = 0;
  while (cursor + 4 <= extra.length) {
    const tag = view.getUint16(cursor, true), length = view.getUint16(cursor + 2, true);
    if (cursor + 4 + length > extra.length) throw new Error('ZIP extra 字段截断');
    if (tag === 1) {
      const values = new DataView(extra.buffer, extra.byteOffset + cursor + 4, length);
      let field = 0;
      if (size === 0xffffffff) { size = u64(values, field); field += 8; }
      if (compressed === 0xffffffff) { compressed = u64(values, field); field += 8; }
      if (offset === 0xffffffff) offset = u64(values, field);
      return { size, compressed, offset };
    }
    cursor += 4 + length;
  }
  if (size === 0xffffffff || compressed === 0xffffffff || offset === 0xffffffff) throw new Error('ZIP64 必需尺寸缺失');
  return { size, compressed, offset };
}

/**
 * 最外层和每个受控内包解压前调用。只返回经校验的中央目录事实；累计预算由发现器统一管理。
 * 加密、非 STORE/DEFLATE、Unix 特殊文件、文件/目录别名和 local/central 头不一致均拒绝。
 */
export function preflightModpackArchive(path: string, cancelled: () => boolean = (): boolean => false): ModpackArchiveSummary {
  checkCancel(cancelled);
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 22) throw new Error('整合包归档不是有效普通 ZIP 文件');
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const central = locateCentral(file.fd, stat.size);
    const bytes = readAt(file.fd, central.offset, central.size, stat.size);
    const view = new DataView(bytes.buffer);
    const names = new Map<string, boolean>();
    // 中央目录可省略父目录条目。预算按最终会实际创建的唯一目录/文件计数，
    // 不能只统计 central.count，否则少量深路径可以在多层内包中放大实际产物数。
    const materialized = new Set<string>();
    const result: ModpackArchiveSummary = { entries: 0, uncompressedBytes: 0, compressedBytes: stat.size, files: [] };
    let cursor = 0;
    for (let index = 0; index < central.count; index++) {
      checkCancel(cancelled);
      if (cursor + 46 > bytes.length || view.getUint32(cursor, true) !== 0x02014b50) throw new Error('ZIP 中央目录条目无效');
      const flags = view.getUint16(cursor + 8, true), method = view.getUint16(cursor + 10, true);
      if ((flags & 0x2041) !== 0 || (method !== 0 && method !== 8)) throw new Error('不支持加密或此压缩方式的整合包');
      if (view.getUint16(cursor + 34, true) !== 0) throw new Error('不支持多磁盘 ZIP 条目');
      const nameLength = view.getUint16(cursor + 28, true), extraLength = view.getUint16(cursor + 30, true);
      const end = cursor + 46 + nameLength + extraLength + view.getUint16(cursor + 32, true);
      if (end > bytes.length || nameLength === 0) throw new Error('ZIP 文件名或条目截断');
      const rawName = bytes.slice(cursor + 46, cursor + 46 + nameLength);
      const name = entryPath(rawName);
      const components = name.split('/');
      for (let part = 1; part <= components.length; part++) materialized.add(components.slice(0, part).join('/'));
      if (materialized.size > MAX_ENTRIES) throw new Error('ZIP 实际目录与文件数量超限');
      const attrs = view.getUint32(cursor + 38, true), unixType = (attrs >>> 16) & 0xf000;
      if (unixType !== 0 && unixType !== 0x4000 && unixType !== 0x8000) throw new Error('ZIP 包含链接或特殊文件');
      const directory = rawName[rawName.length - 1] === 47 || (attrs & 16) !== 0 || unixType === 0x4000;
      if (names.has(name)) throw new Error('ZIP 包含重复目标：' + name);
      names.set(name, directory);
      const sizes = zipSizes(bytes.slice(cursor + 46 + nameLength, cursor + 46 + nameLength + extraLength),
        view.getUint32(cursor + 24, true), view.getUint32(cursor + 20, true), view.getUint32(cursor + 42, true));
      // STORE 没有压缩变换，两个长度必须相同；平台不能按另一个长度复制输出而绕过预算。
      if (method === 0 && sizes.size !== sizes.compressed) throw new Error('ZIP STORE 压缩与原始长度不一致');
      if (directory && sizes.size !== 0) throw new Error('ZIP 目录含非空内容');
      result.uncompressedBytes = safeNumber(result.uncompressedBytes + sizes.size);
      if (result.uncompressedBytes > MAX_BYTES) throw new Error('整合包解压大小超过 16 GiB 限制');
      const localBytes = readAt(file.fd, sizes.offset, 30 + nameLength, stat.size);
      const local = new DataView(localBytes.buffer);
      if (local.getUint32(0, true) !== 0x04034b50 || local.getUint16(6, true) !== flags
        || local.getUint16(8, true) !== method || local.getUint16(26, true) !== nameLength) throw new Error('ZIP 本地头与中央目录不一致');
      for (let byte = 0; byte < nameLength; byte++) if (localBytes[30 + byte] !== rawName[byte]) throw new Error('ZIP 本地文件名与中央目录不一致');
      if ((flags & 8) === 0 && local.getUint32(14, true) !== view.getUint32(cursor + 16, true)) throw new Error('ZIP CRC 字段不一致');
      const localExtraLength = local.getUint16(28, true);
      const localSizes = zipSizes(readAt(file.fd, sizes.offset + 30 + nameLength, localExtraLength, stat.size),
        local.getUint32(22, true), local.getUint32(18, true), 0);
      // descriptor 模式允许 local 暂写 0，非零及 ZIP64 已知值仍须与中央目录一致，
      // 避免平台按另一套 local 尺寸展开时绕过预先计入的解压预算。
      if (((flags & 8) === 0 || localSizes.size !== 0) && localSizes.size !== sizes.size
        || ((flags & 8) === 0 || localSizes.compressed !== 0) && localSizes.compressed !== sizes.compressed) throw new Error('ZIP 本地尺寸与中央目录不一致');
      const dataEnd = safeNumber(sizes.offset + 30 + nameLength + local.getUint16(28, true) + sizes.compressed);
      if (dataEnd > central.offset) throw new Error('ZIP 文件数据越过中央目录');
      result.files.push({ path: name, directory, size: sizes.size, compressedSize: sizes.compressed,
        crc32: view.getUint32(cursor + 16, true), localOffset: sizes.offset, dataEnd });
      cursor = end;
    }
    if (cursor !== bytes.length) throw new Error('ZIP 中央目录存在未解释数据');
    const ordered = result.files.slice().sort((a: ModpackArchiveEntry, b: ModpackArchiveEntry): number => a.localOffset - b.localOffset);
    for (let index = 1; index < ordered.length; index++) if (ordered[index].localOffset < ordered[index - 1].dataEnd) throw new Error('ZIP 条目数据重叠');
    for (const item of result.files) {
      const parts = item.path.split('/');
      for (let i = 1; i < parts.length; i++) if (names.get(parts.slice(0, i).join('/')) === false) throw new Error('ZIP 文件被用作父目录');
    }
    const after = fs.lstatSync(path);
    if (after.size !== stat.size || after.mtime !== stat.mtime || after.isSymbolicLink()) throw new Error('ZIP 在预检期间发生变化');
    result.entries = materialized.size;
    return result;
  } finally { fs.closeSync(file); }
}

/**
 * 游戏导出的有界文件I/O：快照→ZIP64 STORE→独立读回→系统文档URI。
 * Native数据面批量读取与计算；Kit兼容路径按64KiB分块。取消后等实际I/O收口才返回。
 * 任务负责人拥有快照/归档目录，只有本模块Promise结束后才能清理；这里不删除源和目标。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ExportNativeContext, tryNativeWriteArchive, tryNativeVerifyArchive, tryNativeHashFile } from './ExportNativeArchive';
import { stringToUtf8 } from 'commons';
import { ExportPlannedFile, EXPORT_ZIP_CHUNK, EXPORT_ZIP_MAX_ENTRIES, EXPORT_ZIP_FLAGS,
  exportZipPath, exportZipInteger, exportZipReadU64, exportZipCrc32, exportZipLocalHeader,
  exportZipDescriptor, exportZipCentralHeader, exportZipEnd } from 'feature_core';

/** SHA1供上游依赖身份比对，SHA256供快照和最终归档复核；未请求算法为空，空文件仍有真实摘要。 */
export interface ExportFileHashes { size: number; sha1: string; sha256: string; }
export interface ExportUriReceipt { size: number; sha256: string; readbackVerified: boolean; }
interface ZipWrittenEntry { offset: number; crc: number; }

/** 取消不会关闭其他异步调用持有的fd；只在当前操作返回后由相同owner收尾。 */
function assertActive(cancelled: () => boolean): void {
  if (cancelled()) throw new Error('已取消导出');
}

/** Md结果显式转换为小写十六进制，不把任意二进制按文本解码。 */
function hex(bytes: Uint8Array): string {
  let text = ''; for (const value of bytes) text += value.toString(16).padStart(2, '0'); return text;
}

/** 同时核对inode、长度及纳秒mtime/ctime，避免路径被替换或同秒内覆盖时假装稳定。 */
function stamp(stat: fs.Stat): string {
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/** 对普通路径使用NOFOLLOW；URI按系统授权打开，不尝试把它改写成沙箱路径。
 * @throws 文件权限、路径或系统I/O错误向任务负责人传播。
 */
async function openRead(path: string): Promise<fs.File> {
  return fs.open(path, fs.OpenMode.READ_ONLY | (path.indexOf('://') < 0 ? fs.OpenMode.NOFOLLOW : 0));
}

/** 短写必须继续写剩余子片；offset若有表示文件位置，并不是buffer内部偏移。
 * @throws 写入或取消错误向任务负责人传播。
 */
async function writeAll(fd: number, bytes: Uint8Array, cancelled: () => boolean): Promise<void> {
  let written = 0;
  while (written < bytes.length) {
    assertActive(cancelled);
    const part = bytes.slice(written, Math.min(bytes.length, written + EXPORT_ZIP_CHUNK));
    const count = await fs.write(fd, part.buffer);
    if (count <= 0 || count > part.length) throw new Error('归档文件写入不完整');
    written += count;
  }
}

/** 校验器的随机读取也处理短读；EOF绝不能填零后继续解析。
 * @throws 截断、权限或取消错误向任务负责人传播。
 */
async function readExact(fd: number, offset: number, length: number, cancelled: () => boolean): Promise<Uint8Array> {
  exportZipInteger(offset); exportZipInteger(length);
  const bytes = new Uint8Array(length); let received = 0;
  while (received < length) {
    assertActive(cancelled);
    const buffer = new ArrayBuffer(length - received);
    const count = await fs.read(fd, buffer, { offset: offset + received, length: buffer.byteLength });
    if (count <= 0 || count > buffer.byteLength) throw new Error('归档被截断或读取失败');
    bytes.set(new Uint8Array(buffer, 0, count), received); received += count;
  }
  return bytes;
}

/** 比较原始UTF-8字节，损坏编码不能经有损解码后恰好匹配计划中的另一个路径。 */
function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) if (left[index] !== right[index]) return false;
  return true;
}

/** 校验计划自身；忽略大小写的重复路径会在Windows目标上覆盖，必须在写第一个header前阻断。 */
function validateFiles(files: ExportPlannedFile[]): void {
  if (files.length === 0 || files.length > EXPORT_ZIP_MAX_ENTRIES) throw new Error('归档条目数必须介于1与200000之间');
  const paths = new Map<string, boolean>();
  for (const file of files) {
    const name = exportZipPath(file.archivePath, file.directory);
    const key = (file.directory ? name.substring(0, name.length - 1) : name).toLowerCase();
    if (paths.has(key)) throw new Error('归档计划包含重复或大小写冲突路径');
    paths.set(key, file.directory); exportZipInteger(file.size);
    if (stringToUtf8(name).length > 65535) throw new Error('归档UTF-8路径过长');
    if (file.directory && file.size !== 0) throw new Error('空目录不能携带文件字节');
    if (!file.directory && !new RegExp('^[0-9a-f]{64}$').test(file.sha256)) throw new Error('归档快照缺少可信SHA256');
  }
  for (const key of paths.keys()) {
    const parts = key.split('/'); let parent = '';
    for (let index = 0; index < parts.length - 1; index++) {
      parent += (index === 0 ? '' : '/') + parts[index];
      if (paths.get(parent) === false) throw new Error('归档中的文件与目录前缀冲突');
    }
  }
}

/** 快照目录及全部父片段均须为真实目录，不沿symlink读取任务目录以外的数据。
 * @throws 快照路径异常或取消时阻止打包。
 */
async function snapshotPath(root: string, file: ExportPlannedFile, cancelled: () => boolean): Promise<string> {
  assertActive(cancelled);
  const rootStat = await fs.lstat(root);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('导出快照根目录无效');
  const relative = exportZipPath(file.archivePath, file.directory);
  const parts = relative.split('/').filter((value: string): boolean => value.length > 0);
  let current = root;
  for (let index = 0; index < parts.length; index++) {
    assertActive(cancelled); current += '/' + parts[index]; const stat = await fs.lstat(current);
    if (stat.isSymbolicLink()) throw new Error('导出快照包含符号链接');
    if (index < parts.length - 1 || file.directory) {
      if (!stat.isDirectory()) throw new Error('导出快照目录发生变化');
    } else if (!stat.isFile()) throw new Error('导出快照包含特殊文件');
  }
  return current;
}

/** 已打开fd的摘要核心；调用者拥有句柄，读回中途的I/O错误不能降级为“不支持读回”。
 * @throws 摘要计算、读取或文件变化错误向句柄owner传播。
 */
async function hashOpenedFile(opened: fs.File, path: string, cancelled: () => boolean,
  needSha1: boolean = true, needSha256: boolean = true): Promise<ExportFileHashes> {
    // 用途只决定CPU摘要工作，不跳过原fd/path前后身份、读取完整性、取消或owner关闭责任。
    if (!needSha1 && !needSha256) throw new Error('文件摘要至少需要一种算法');
    const before = await fs.stat(opened.fd); if (!before.isFile()) throw new Error('摘要输入不是普通文件');
    exportZipInteger(before.size);
    // 路径来源与SDK fd/path复核保持原协议。普通文件借用fd给Native，避免每块两次摘要桥接；
    // URI提供方仍沿Kit读取能力，不能假定其fd具有原生pread语义。
    if (path.indexOf('://') < 0) {
      const native = await tryNativeHashFile(opened.fd, before.size, needSha1, cancelled, needSha256);
      if (native !== undefined) {
        assertActive(cancelled);
        if (native.size !== before.size || stamp(before) !== stamp(await fs.stat(opened.fd)) ||
          stamp(before) !== stamp(await fs.stat(path))) throw new Error('摘要读取期间文件发生变化');
        return native;
      }
    }
    const sha1 = needSha1 ? cryptoFramework.createMd('SHA1') : undefined;
    const sha256 = needSha256 ? cryptoFramework.createMd('SHA256') : undefined;
    let size = 0;
    while (size < before.size) {
      assertActive(cancelled); const buffer = new ArrayBuffer(Math.min(EXPORT_ZIP_CHUNK, before.size - size));
      const count = await fs.read(opened.fd, buffer, { length: buffer.byteLength });
      if (count <= 0 || count > buffer.byteLength) throw new Error('摘要输入被截断');
      const bytes = new Uint8Array(buffer, 0, count);
      if (sha1 !== undefined) await sha1.update({ data: bytes });
      if (sha256 !== undefined) await sha256.update({ data: bytes });
      size += count;
    }
    assertActive(cancelled);
    if (stamp(before) !== stamp(await fs.stat(opened.fd)) || stamp(before) !== stamp(await fs.stat(path))) throw new Error('摘要读取期间文件发生变化');
    return { size: size, sha1: sha1 === undefined ? '' : hex((await sha1.digest()).data),
      sha256: sha256 === undefined ? '' : hex((await sha256.digest()).data) };
}

/** 通用异步哈希。读取前后比较fd及路径身份，读取期间缩短/增长/替换均作为失败。
 * @throws 文件读取、摘要计算和取消错误交由任务负责人处理。
 */
export async function hashExportFile(path: string, cancelled: () => boolean): Promise<ExportFileHashes> {
  assertActive(cancelled); const opened = await openRead(path);
  try { return await hashOpenedFile(opened, path, cancelled); } finally { await fs.close(opened); }
}

/**
 * 上游依赖检查只消费真实长度与SHA1，不为未被消费的SHA256额外计算。仍复用完全相同的
 * 只读NOFOLLOW打开、fd/path前后身份复核、Native/Kit完整读取、取消和finally关闭核心。
 * 结果sha256明确为空，禁止拿它代替冻结快照所需的双摘要；快照和URI读回不调用此入口。
 * @throws 文件读取、摘要计算、身份变化和取消错误交由原依赖检查负责人处理。
 */
export async function hashExportDependencyFile(path: string, cancelled: () => boolean): Promise<ExportFileHashes> {
  assertActive(cancelled); const opened = await openRead(path);
  try { return await hashOpenedFile(opened, path, cancelled, true, false); } finally { await fs.close(opened); }
}

/** 仅接受Coordinator同一私有work中的固定快照/归档，Native与Kit路径必须指向同一结果。 */
function assertNativeLocation(context: ExportNativeContext, snapshotRoot: string, archivePath: string): void {
  const root = context.filesDir.replace(/\/+$/, '') + '/' + context.workRelative;
  if (snapshotRoot !== root + '/snapshot' || archivePath !== root + '/export.zip') throw new Error('Native导出工作路径不一致');
}

/**
 * 将已冻结且带SHA256的快照写成ZIP64；归档目标由本任务独占且必须尚不存在。
 * 写入同时核对每个快照摘要，完成fsync/close后返回；失败留下自有工作文件供负责人处理。
 * @throws 计划、快照、写入、同步或取消错误交由任务负责人处理。
 */
export async function writeExportArchive(snapshotRoot: string, archivePath: string, files: ExportPlannedFile[],
  cancelled: () => boolean, onProgress: (files: number, bytes: number) => void,
  nativeContext?: ExportNativeContext): Promise<void> {
  validateFiles(files); assertActive(cancelled);
  if (nativeContext !== undefined) assertNativeLocation(nativeContext, snapshotRoot, archivePath);
  if (await tryNativeWriteArchive(nativeContext, files, cancelled, onProgress)) return;
  if (await fs.access(archivePath)) throw new Error('临时归档目标已存在，拒绝覆盖');
  const archive = await fs.open(archivePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const written: ZipWrittenEntry[] = []; let position = 0; let total = 0; let completed = 0;
    for (const file of files) {
      assertActive(cancelled); const source = await snapshotPath(snapshotRoot, file, cancelled);
      const name = stringToUtf8(exportZipPath(file.archivePath, file.directory));
      const header = exportZipLocalHeader(name, file.size); const offset = position;
      await writeAll(archive.fd, header, cancelled); position += header.length;
      let crc = 0; let size = 0;
      if (!file.directory) {
        const input = await openRead(source);
        try {
          const before = await fs.stat(input.fd); if (!before.isFile() || before.size !== file.size) throw new Error('导出快照大小变化');
          const sha = cryptoFramework.createMd('SHA256');
          while (size < file.size) {
            assertActive(cancelled); const buffer = new ArrayBuffer(Math.min(EXPORT_ZIP_CHUNK, file.size - size));
            const count = await fs.read(input.fd, buffer, { length: buffer.byteLength });
            if (count <= 0 || count > buffer.byteLength) throw new Error('导出快照读取不完整');
            const bytes = new Uint8Array(buffer, 0, count); crc = exportZipCrc32(crc, bytes); await sha.update({ data: bytes });
            await writeAll(archive.fd, bytes, cancelled); size += count; position += count; total += count;
            exportZipInteger(position); onProgress(completed, total);
          }
          if (hex((await sha.digest()).data) !== file.sha256 || stamp(before) !== stamp(await fs.stat(input.fd)) ||
            stamp(before) !== stamp(await fs.stat(source))) throw new Error('导出快照在打包期间发生变化');
        } finally { await fs.close(input); }
      }
      await writeAll(archive.fd, exportZipDescriptor(crc, size), cancelled); position += 24;
      written.push({ offset: offset, crc: crc }); completed++; onProgress(completed, total);
    }
    const centralOffset = position;
    for (let index = 0; index < files.length; index++) {
      const file = files[index]; const entry = written[index];
      const header = exportZipCentralHeader(stringToUtf8(exportZipPath(file.archivePath, file.directory)),
        file.size, entry.crc, entry.offset, file.directory);
      await writeAll(archive.fd, header, cancelled); position += header.length; exportZipInteger(position);
    }
    await writeAll(archive.fd, exportZipEnd(files.length, position - centralOffset, centralOffset), cancelled);
    assertActive(cancelled); await fs.fsync(archive.fd);
  } finally { await fs.close(archive); }
}

/** 统一的结构断言防止解析器接受签名正确、内部位移却越过目录或文件末尾的伪归档。 */
function requireZip(condition: boolean): void {
  if (!condition) throw new Error('归档结构、条目或摘要与文件计划不一致');
}

/**
 * 独立读取中央目录、每个local header和data descriptor，再逐块计算CRC/SHA256。
 * 不调用writer重新生成头来比较，防止同一编码错误在自检时被复制。仅接受本模块明确产出的
 * 单磁盘ZIP64 STORE子集；entry位置必须连续且唯一，拒绝隐藏文件、前置数据和尾随载荷。
 * @throws 归档结构、内容、文件I/O或取消错误交由任务负责人处理。
 */
export async function verifyExportArchive(archivePath: string, files: ExportPlannedFile[],
  cancelled: () => boolean, nativeContext?: ExportNativeContext): Promise<void> {
  validateFiles(files);
  if (nativeContext !== undefined) assertNativeLocation(nativeContext,
    nativeContext.filesDir.replace(/\/+$/, '') + '/' + nativeContext.workRelative + '/snapshot', archivePath);
  if (await tryNativeVerifyArchive(nativeContext, files, cancelled)) return;
  const archive = await openRead(archivePath);
  try {
    const before = await fs.stat(archive.fd); const length = before.size; exportZipInteger(length); requireZip(length >= 98);
    const tail = new DataView((await readExact(archive.fd, length - 98, 98, cancelled)).buffer);
    requireZip(tail.getUint32(0, true) === 0x06064b50 && exportZipReadU64(tail, 4) === 44 &&
      tail.getUint16(12, true) === 45 && tail.getUint16(14, true) === 45 && tail.getUint32(16, true) === 0 &&
      tail.getUint32(20, true) === 0 && exportZipReadU64(tail, 24) === files.length && exportZipReadU64(tail, 32) === files.length);
    const centralSize = exportZipReadU64(tail, 40); const centralStart = exportZipReadU64(tail, 48);
    requireZip(centralStart + centralSize === length - 98 && tail.getUint32(56, true) === 0x07064b50 &&
      tail.getUint32(60, true) === 0 && exportZipReadU64(tail, 64) === length - 98 && tail.getUint32(72, true) === 1 &&
      tail.getUint32(76, true) === 0x06054b50 && tail.getUint32(80, true) === 0 &&
      tail.getUint16(84, true) === 65535 && tail.getUint16(86, true) === 65535 &&
      tail.getUint32(88, true) === 0xffffffff && tail.getUint32(92, true) === 0xffffffff && tail.getUint16(96, true) === 0);
    let centralPosition = centralStart; let nextLocal = 0;
    for (const file of files) {
      assertActive(cancelled); requireZip(centralPosition + 46 <= length - 98);
      const fixed = new DataView((await readExact(archive.fd, centralPosition, 46, cancelled)).buffer);
      const nameLength = fixed.getUint16(28, true); const extraLength = fixed.getUint16(30, true);
      requireZip(fixed.getUint32(0, true) === 0x02014b50 && fixed.getUint16(6, true) === 45 &&
        fixed.getUint16(8, true) === EXPORT_ZIP_FLAGS && fixed.getUint16(10, true) === 0 &&
        fixed.getUint32(20, true) === 0xffffffff && fixed.getUint32(24, true) === 0xffffffff &&
        extraLength === 28 && fixed.getUint16(32, true) === 0 && fixed.getUint16(34, true) === 0 &&
        fixed.getUint32(38, true) === (file.directory ? 16 : 0) && fixed.getUint32(42, true) === 0xffffffff &&
        centralPosition + 46 + nameLength + extraLength <= length - 98);
      const name = await readExact(archive.fd, centralPosition + 46, nameLength, cancelled);
      requireZip(sameBytes(name, stringToUtf8(exportZipPath(file.archivePath, file.directory))));
      const extra = new DataView((await readExact(archive.fd, centralPosition + 46 + nameLength, extraLength, cancelled)).buffer);
      requireZip(extra.getUint16(0, true) === 1 && extra.getUint16(2, true) === 24 &&
        exportZipReadU64(extra, 4) === file.size && exportZipReadU64(extra, 12) === file.size);
      const localOffset = exportZipReadU64(extra, 20); requireZip(localOffset === nextLocal && localOffset + 50 + nameLength + file.size + 24 <= centralStart);
      const local = new DataView((await readExact(archive.fd, localOffset, 30, cancelled)).buffer);
      requireZip(local.getUint32(0, true) === 0x04034b50 && local.getUint16(4, true) === 45 &&
        local.getUint16(6, true) === EXPORT_ZIP_FLAGS && local.getUint16(8, true) === 0 && local.getUint32(14, true) === 0 &&
        local.getUint32(18, true) === 0xffffffff && local.getUint32(22, true) === 0xffffffff &&
        local.getUint16(26, true) === nameLength && local.getUint16(28, true) === 20);
      requireZip(sameBytes(await readExact(archive.fd, localOffset + 30, nameLength, cancelled), name));
      const localExtra = new DataView((await readExact(archive.fd, localOffset + 30 + nameLength, 20, cancelled)).buffer);
      requireZip(localExtra.getUint16(0, true) === 1 && localExtra.getUint16(2, true) === 16 &&
        exportZipReadU64(localExtra, 4) === file.size && exportZipReadU64(localExtra, 12) === file.size);
      const dataOffset = localOffset + 50 + nameLength; const sha = cryptoFramework.createMd('SHA256'); let size = 0; let crc = 0;
      while (size < file.size) {
        const bytes = await readExact(archive.fd, dataOffset + size, Math.min(EXPORT_ZIP_CHUNK, file.size - size), cancelled);
        crc = exportZipCrc32(crc, bytes); await sha.update({ data: bytes }); size += bytes.length;
      }
      requireZip(crc === fixed.getUint32(16, true));
      const digest = hex((await sha.digest()).data); if (!file.directory) requireZip(digest === file.sha256);
      const descriptor = new DataView((await readExact(archive.fd, dataOffset + size, 24, cancelled)).buffer);
      requireZip(descriptor.getUint32(0, true) === 0x08074b50 && descriptor.getUint32(4, true) === crc &&
        exportZipReadU64(descriptor, 8) === size && exportZipReadU64(descriptor, 16) === size);
      nextLocal = dataOffset + size + 24; centralPosition += 46 + nameLength + extraLength;
    }
    requireZip(nextLocal === centralStart && centralPosition === centralStart + centralSize &&
      stamp(before) === stamp(await fs.stat(archive.fd)) && stamp(before) === stamp(await fs.stat(archivePath)));
    assertActive(cancelled);
  } finally { await fs.close(archive); }
}

/**
 * Picker URI只允许写入新建的空文件，不TRUNC任何非空目标。先关闭并flush，再尽力重新打开读回。
 * 文档provider不支持读回时明确返回false；成功写入的长度和摘要仍来自实际流，而非计划估算。
 * 写中失败/取消没有跨provider原子rename保证，错误明确提示可能留下半成品，不能宣称旧文件已恢复。
 * @throws 目标非空、复制/同步/读回失败或取消错误交由任务负责人展示。
 */
export async function copyExportArchiveToUri(archivePath: string, uri: string, cancelled: () => boolean,
  onProgress: (bytes: number) => void): Promise<ExportUriReceipt> {
  assertActive(cancelled); const source = await openRead(archivePath); let target: fs.File | undefined = undefined;
  let changed = false; let result: ExportUriReceipt = { size: 0, sha256: '', readbackVerified: false };
  try {
    const before = await fs.stat(source.fd); if (!before.isFile()) throw new Error('导出归档不是普通文件'); exportZipInteger(before.size);
    target = await fs.open(uri, fs.OpenMode.READ_WRITE);
    if ((await fs.stat(target.fd)).size !== 0) throw new Error('目标文件已有内容，请另选新文件；未覆盖原文件');
    const sha = cryptoFramework.createMd('SHA256'); let total = 0;
    while (total < before.size) {
      assertActive(cancelled); const buffer = new ArrayBuffer(Math.min(EXPORT_ZIP_CHUNK, before.size - total));
      const count = await fs.read(source.fd, buffer, { length: buffer.byteLength });
      if (count <= 0 || count > buffer.byteLength) throw new Error('归档复制读取不完整');
      const bytes = new Uint8Array(buffer, 0, count); changed = true;
      await writeAll(target.fd, bytes, cancelled); await sha.update({ data: bytes }); total += count; onProgress(total);
    }
    assertActive(cancelled); await fs.fsync(target.fd);
    if ((await fs.stat(target.fd)).size !== total || stamp(before) !== stamp(await fs.stat(source.fd)) ||
      stamp(before) !== stamp(await fs.stat(archivePath))) throw new Error('复制期间归档或目标大小发生变化');
    await fs.close(target); target = undefined;
    result = { size: total, sha256: hex((await sha.digest()).data), readbackVerified: false };
  } catch (error) {
    const message = (error as Error).message;
    throw new Error(message + (changed ? '；目标可能留下未完成文件，请在文件管理器删除后重新另存' : ''));
  } finally {
    // 即使目标close报错，源fd仍必须获得一次独立close机会。
    try { if (target !== undefined) await fs.close(target); } finally { await fs.close(source); }
  }
  let readback: fs.File | undefined = undefined;
  // 只允许官方基础文件IO中明确的授权/功能限制降级：13900001=操作未授权、
  // 13900012=Permission denied、13900031=Function not implemented。13900002代表
  // 目标不存在，13900005代表I/O故障；这些故障及未知异常均不能伪装成“不支持读回”。
  // 来源：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-filemanagement
  try { readback = await openRead(uri); } catch (error) {
    assertActive(cancelled);
    const code = (error as BusinessError).code;
    if (code === 13900001 || code === 13900012 || code === 13900031) return result;
    throw error as Error;
  }
  try {
    const actual = await hashOpenedFile(readback, uri, cancelled, false);
    if (actual.size !== result.size || actual.sha256 !== result.sha256) throw new Error('目标文件读回校验失败，请删除未完成文件后重新另存');
    result.readbackVerified = true;
  } finally { await fs.close(readback); }
  assertActive(cancelled); return result;
}

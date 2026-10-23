/**
 * Forge/NeoForge 生成 JAR 的结构与内容完整性检查。先复制到私有独占目录，严格验证
 * ZIP 中央目录、local header、边界及名称，再调用 SDK 解压并逐文件核对 CRC32/大小。
 * 本模块证明归档完整与所需类/资源存在；上游 SHA 或本地来源摘要由调用者另外绑定，
 * 不能把 CRC32/结构检查冒充官方产物认证。这里只消费经典 ZIP，generated JAR 的 ZIP64
 * 输入明确拒绝；外层游戏包仍使用独立 ExportArchiveIO 的 ZIP64 writer。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { utf8ToString } from 'commons';
import { exportZipCrc32 } from 'feature_core';

const JAR_CHUNK = 65536;
const MAX_JAR_BYTES = 1024 * 1024 * 1024;
const MAX_JAR_EXPANDED = 2 * 1024 * 1024 * 1024;
const MAX_JAR_ENTRY_BYTES = 512 * 1024 * 1024;
const MAX_JAR_ENTRIES = 60000;
const MAX_CENTRAL_BYTES = 32 * 1024 * 1024;

/** 所有位置来自已经检查过的经典u32字段；不接受符号链接或任何特殊文件。 */
interface JarEntry {
  name: string; nameBytes: Uint8Array; directory: boolean; method: number; flags: number;
  crc: number; compressed: number; size: number; localOffset: number;
}

/** 上层的取消是协作式请求，不会提前释放正在运行的 SDK 解压 owner。 */
function jarActive(isCancelled: () => boolean): void {
  if (isCancelled()) throw new Error('已取消生成 JAR 校验');
}
function jarRequire(condition: boolean, reason: string): void {
  if (!condition) throw new Error('生成 JAR 无效：' + reason);
}
function jarStamp(stat: fs.Stat): string {
  return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

/** 固定长度随机读取处理短读，不能用零填充缓冲区继续解释截断的结构。
 * @throws 取消、截断或FileIO错误向校验owner传播。
 */
async function jarRead(fd: number, offset: number, length: number, isCancelled: () => boolean): Promise<Uint8Array> {
  jarRequire(Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(length) && length >= 0 && length <= JAR_CHUNK,
    '元数据读取越界');
  const out = new Uint8Array(length); let done = 0;
  while (done < length) {
    jarActive(isCancelled); const buffer = new ArrayBuffer(length - done);
    const count = await fs.read(fd, buffer, { offset: offset + done, length: buffer.byteLength });
    jarRequire(count > 0 && count <= buffer.byteLength, '归档被截断'); out.set(new Uint8Array(buffer, 0, count), done); done += count;
  }
  return out;
}

/** 字节名比较发生在解码前，local/central不能通过有损替换字符折叠为同一路径。 */
function jarBytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) if (left[index] !== right[index]) return false;
  return true;
}

/** 严格UTF-8拒绝过长编码、孤立代理项和非法延续字节，SDK解压器不能获得另一种路径解释。 */
function jarUtf8(bytes: Uint8Array, utf8: boolean): string {
  for (let index = 0; index < bytes.length; index++) {
    const first = bytes[index]; if (first < 128) continue;
    jarRequire(utf8, '非ASCII名称缺少UTF-8标记');
    let following = 0; let code = 0; let minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) { following = 1; code = first & 31; minimum = 128; }
    else if (first >= 0xe0 && first <= 0xef) { following = 2; code = first & 15; minimum = 2048; }
    else if (first >= 0xf0 && first <= 0xf4) { following = 3; code = first & 7; minimum = 65536; }
    else throw new Error('生成 JAR 无效：文件名不是规范UTF-8');
    jarRequire(index + following < bytes.length, 'UTF-8名称被截断');
    for (let part = 0; part < following; part++) {
      const next = bytes[++index]; jarRequire((next & 0xc0) === 0x80, 'UTF-8名称含非法延续字节'); code = code * 64 + (next & 63);
    }
    jarRequire(code >= minimum && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff), '文件名不是规范UTF-8');
  }
  return utf8ToString(bytes);
}

/** 只允许标准正斜杠相对路径；拒绝绝对名、盘符、空段、点段、反斜杠和控制字符。 */
function jarPath(name: string, directory: boolean): string {
  const value = directory ? name.substring(0, name.length - 1) : name;
  jarRequire(value.length > 0 && value.length <= 4096 && !value.startsWith('/') && !/[\\:\u0000-\u001f\u007f]/.test(value), '条目名称不安全');
  for (const part of value.split('/')) jarRequire(part.length > 0 && part !== '.' && part !== '..', '条目路径越界');
  return value;
}

/** ZIP扩展字段按TLV核对完整长度；ZIP64和Unicode替代名称会产生第二套尺寸/路径解释，均拒绝。 */
function jarExtra(bytes: Uint8Array): void {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); let offset = 0;
  while (offset < bytes.length) {
    jarRequire(offset + 4 <= bytes.length, 'ZIP扩展字段被截断'); const kind = view.getUint16(offset, true); const size = view.getUint16(offset + 2, true);
    jarRequire(kind !== 1, '生成JAR暂不支持ZIP64');
    jarRequire(kind !== 0x7075, '不支持第二套Unicode替代文件名');
    jarRequire(offset + 4 + size <= bytes.length, 'ZIP扩展字段越界'); offset += 4 + size;
  }
}

/**
 * 从EOCD定位中央目录，再按实际local offset检查每项范围、描述符和连续布局。
 * 不信任SDK对危险ZIP的容错；全部验证通过前不把输入交给系统解压器。
 * @throws 归档非法、超限、截断或取消时阻断解压。
 */
async function jarInspect(path: string, isCancelled: () => boolean): Promise<JarEntry[]> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const length = (await fs.stat(file.fd)).size; jarRequire(length >= 22 && length <= MAX_JAR_BYTES, 'JAR大小超出限制');
    const tailSize = Math.min(length, JAR_CHUNK); const tail = await jarRead(file.fd, length - tailSize, tailSize, isCancelled);
    const tailView = new DataView(tail.buffer); let ending = -1;
    for (let index = tailSize - 22; index >= 0; index--) {
      if (tailView.getUint32(index, true) === 0x06054b50 && index + 22 + tailView.getUint16(index + 20, true) === tailSize) {
        ending = index; break;
      }
    }
    jarRequire(ending >= 0, '未找到完整中央目录尾');
    const count = tailView.getUint16(ending + 10, true); const centralSize = tailView.getUint32(ending + 12, true);
    const centralStart = tailView.getUint32(ending + 16, true); const endOffset = length - tailSize + ending;
    jarRequire(tailView.getUint16(ending + 4, true) === 0 && tailView.getUint16(ending + 6, true) === 0 &&
      tailView.getUint16(ending + 8, true) === count, '不支持多磁盘JAR');
    jarRequire(count !== 65535 && centralSize !== 0xffffffff && centralStart !== 0xffffffff, '生成JAR暂不支持ZIP64');
    jarRequire(count > 0 && count <= MAX_JAR_ENTRIES && centralSize <= MAX_CENTRAL_BYTES && centralStart + centralSize === endOffset,
      '中央目录数量、尺寸或范围异常');
    const entries: JarEntry[] = []; const paths = new Map<string, boolean>(); let cursor = centralStart; let expanded = 0;
    for (let index = 0; index < count; index++) {
      jarRequire(cursor + 46 <= endOffset, '中央目录被截断');
      const fixed = new DataView((await jarRead(file.fd, cursor, 46, isCancelled)).buffer);
      jarRequire(fixed.getUint32(0, true) === 0x02014b50, '中央目录签名错误');
      const nameSize = fixed.getUint16(28, true); const extraSize = fixed.getUint16(30, true); const commentSize = fixed.getUint16(32, true);
      const flags = fixed.getUint16(8, true); const method = fixed.getUint16(10, true); const localOffset = fixed.getUint32(42, true);
      const compressed = fixed.getUint32(20, true); const size = fixed.getUint32(24, true);
      jarRequire((flags & ~0x080e) === 0 && (method === 0 || method === 8), '不支持加密、压缩方法或ZIP标记');
      jarRequire(fixed.getUint16(34, true) === 0 && nameSize > 0 && nameSize <= 4096 && extraSize <= 16384 &&
        cursor + 46 + nameSize + extraSize + commentSize <= endOffset, '中央目录条目越界');
      jarRequire(compressed !== 0xffffffff && size !== 0xffffffff && localOffset !== 0xffffffff, '生成JAR暂不支持ZIP64');
      jarRequire(size <= MAX_JAR_ENTRY_BYTES && compressed <= MAX_JAR_BYTES &&
        (compressed > 0 || size === 0) && (size <= 65536 || size <= compressed * 1024), '条目大小或膨胀比例超限');
      if (method === 0) jarRequire(compressed === size, 'STORE条目长度不一致');
      const mode = (fixed.getUint32(38, true) >>> 16) & 0xf000;
      jarRequire(mode === 0 || mode === 0x8000 || mode === 0x4000, 'JAR含链接或特殊文件');
      const nameBytes = await jarRead(file.fd, cursor + 46, nameSize, isCancelled);
      const name = jarUtf8(nameBytes, (flags & 0x0800) !== 0); const directory = name.endsWith('/'); const key = jarPath(name, directory);
      jarRequire(!paths.has(key), 'JAR含重复条目'); paths.set(key, directory);
      jarRequire((mode !== 0x4000 || directory) && (!directory || size === 0), '目录属性或长度异常');
      jarExtra(await jarRead(file.fd, cursor + 46 + nameSize, extraSize, isCancelled));
      expanded += size; jarRequire(expanded <= MAX_JAR_EXPANDED, 'JAR展开总大小超限');
      entries.push({ name, nameBytes, directory, method, flags, crc: fixed.getUint32(16, true), compressed, size, localOffset });
      cursor += 46 + nameSize + extraSize + commentSize;
    }
    jarRequire(cursor === endOffset, '中央目录长度不匹配');
    for (const key of paths.keys()) {
      const parts = key.split('/'); let prefix = '';
      for (let index = 0; index < parts.length - 1; index++) {
        prefix += (index === 0 ? '' : '/') + parts[index]; jarRequire(paths.get(prefix) !== false, '文件与目录路径冲突');
      }
    }
    let next = 0;
    for (const entry of entries.slice().sort((left: JarEntry, right: JarEntry): number => left.localOffset - right.localOffset)) {
      jarRequire(entry.localOffset === next && next + 30 <= centralStart, 'local条目重叠或含隐藏载荷');
      const local = new DataView((await jarRead(file.fd, next, 30, isCancelled)).buffer);
      const nameSize = local.getUint16(26, true); const extraSize = local.getUint16(28, true);
      jarRequire(local.getUint32(0, true) === 0x04034b50 && local.getUint16(6, true) === entry.flags &&
        local.getUint16(8, true) === entry.method && nameSize === entry.nameBytes.length && extraSize <= 16384, 'local与中央目录不一致');
      const dataStart = next + 30 + nameSize + extraSize; const dataEnd = dataStart + entry.compressed;
      jarRequire(dataEnd <= centralStart, '条目数据越界');
      jarRequire(jarBytesEqual(entry.nameBytes, await jarRead(file.fd, next + 30, nameSize, isCancelled)), 'local文件名不同');
      jarExtra(await jarRead(file.fd, next + 30 + nameSize, extraSize, isCancelled));
      if ((entry.flags & 8) === 0) {
        jarRequire(local.getUint32(14, true) === entry.crc && local.getUint32(18, true) === entry.compressed &&
          local.getUint32(22, true) === entry.size, 'local校验字段不一致'); next = dataEnd;
      } else {
        jarRequire((local.getUint32(14, true) === 0 || local.getUint32(14, true) === entry.crc) &&
          (local.getUint32(18, true) === 0 || local.getUint32(18, true) === entry.compressed) &&
          (local.getUint32(22, true) === 0 || local.getUint32(22, true) === entry.size), 'local描述符前置字段不一致');
        jarRequire(dataEnd + 12 <= centralStart, '数据描述符被截断');
        const first = new DataView((await jarRead(file.fd, dataEnd, 4, isCancelled)).buffer).getUint32(0, true);
        const descriptorOffset = dataEnd + (first === 0x08074b50 ? 4 : 0); jarRequire(descriptorOffset + 12 <= centralStart, '数据描述符越界');
        const descriptor = new DataView((await jarRead(file.fd, descriptorOffset, 12, isCancelled)).buffer);
        jarRequire(descriptor.getUint32(0, true) === entry.crc && descriptor.getUint32(4, true) === entry.compressed &&
          descriptor.getUint32(8, true) === entry.size, '数据描述符不一致'); next = descriptorOffset + 12;
      }
    }
    jarRequire(next === centralStart, '中央目录前含额外数据'); return entries;
  } finally { await fs.close(file); }
}

/** 将外部可变输入复制成独占原件，消除“检查安全ZIP后被换成穿越ZIP再解压”的时间窗口。
 * @throws 源变化、短写、空间或取消错误均阻止后续SDK解压。
 */
async function jarFreeze(source: string, target: string, isCancelled: () => boolean): Promise<void> {
  const input = await fs.open(source, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW); let output: fs.File | undefined = undefined;
  try {
    const before = await fs.stat(input.fd); jarRequire(before.isFile() && before.size >= 22 && before.size <= MAX_JAR_BYTES, '源JAR不是受支持的普通文件');
    output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
    let position = 0;
    while (position < before.size) {
      jarActive(isCancelled); const buffer = new ArrayBuffer(Math.min(JAR_CHUNK, before.size - position));
      const count = await fs.read(input.fd, buffer, { length: buffer.byteLength }); jarRequire(count > 0 && count <= buffer.byteLength, '源JAR被截断');
      let written = 0;
      while (written < count) {
        jarActive(isCancelled); const amount = await fs.write(output.fd, buffer.slice(written, count));
        jarRequire(amount > 0 && amount <= count - written, 'JAR工作副本短写'); written += amount;
      }
      position += count;
    }
    jarRequire(jarStamp(before) === jarStamp(await fs.stat(input.fd)) && jarStamp(before) === jarStamp(await fs.stat(source)), '复制期间源JAR变化');
    await fs.fsync(output.fd);
  } finally { try { if (output !== undefined) await fs.close(output); } finally { await fs.close(input); } }
}

/** 自有目录的清理不跟随任何符号链接；只在SDK和所有fd的Promise均已结束后调用。
 * @throws 无法安全清理时向调用者报告，不能扩大到共享scratch父目录。
 */
async function jarRemove(path: string): Promise<void> {
  const stat = await fs.lstat(path);
  if (stat.isSymbolicLink() || !stat.isDirectory()) { await fs.unlink(path); return; }
  for (const child of await fs.listFile(path)) {
    jarRequire(child.length > 0 && child !== '.' && child !== '..' && !/[\\/\u0000]/.test(child), '临时目录名称异常'); await jarRemove(path + '/' + child);
  }
  await fs.rmdir(path);
}

/** 解压输出沿每个父分量核验，SDK不得把检查结果改写为链接/特殊文件再供哈希器跟随。
 * @throws 文件缺失、链接或目录替换使本次JAR验证失败。
 */
async function jarExtracted(root: string, entry: JarEntry): Promise<string> {
  let current = root; const parts = jarPath(entry.name, entry.directory).split('/');
  for (let index = 0; index < parts.length; index++) {
    current += '/' + parts[index]; const stat = await fs.lstat(current);
    jarRequire(!stat.isSymbolicLink(), '解压输出包含链接');
    jarRequire(index < parts.length - 1 || entry.directory ? stat.isDirectory() : stat.isFile(), '解压输出类型不同');
  }
  return current;
}

/**
 * 校验生成JAR的统一接口：scratchDir仅作为父容器，本次只拥有其下新建的唯一子目录。
 * 必需entry与prefix均须至少找到一个非空普通文件；空目录不能冒充可运行的类或资源。
 * SDK decompressFile不可中断，取消发生后仍await它结束，之后才删除其输出并向上返回取消。
 * @throws 结构、CRC、必需内容、文件I/O、SDK或取消错误交由导出任务负责人展示。
 */
async function runJarVerification(path: string, scratchDir: string, expectedEntries: string[],
  expectedEntryPrefixes: string[], isCancelled: () => boolean, retainedTarget?: string): Promise<void> {
  jarActive(isCancelled);
  jarRequire(scratchDir.startsWith('/') && !scratchDir.split('/').some((part: string): boolean => part === '.' || part === '..'), '校验临时目录不安全');
  let exists = false;
  try { const stat = await fs.lstat(scratchDir); jarRequire(stat.isDirectory() && !stat.isSymbolicLink(), '校验父目录不是普通目录'); exists = true; }
  catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
  if (!exists) await fs.mkdir(scratchDir, true);
  const owner = scratchDir + '/jar-' + util.generateRandomUUID(); await fs.mkdir(owner);
  try {
    // SDK文档要求待解压路径以.zip结尾；仅私有工作副本改后缀，原JAR名称和字节保持不变。
    const frozen = owner + '/input.zip'; await jarFreeze(path, frozen, isCancelled); const entries = await jarInspect(frozen, isCancelled);
    for (const required of expectedEntries) {
      jarPath(required, false); jarRequire(entries.some((entry: JarEntry): boolean => !entry.directory && entry.name === required && entry.size > 0), '缺少必需条目 ' + required);
    }
    for (const prefix of expectedEntryPrefixes) {
      const canonical = jarPath(prefix.endsWith('/') ? prefix : prefix + '/', true) + '/';
      jarRequire(entries.some((entry: JarEntry): boolean => !entry.directory && entry.name.startsWith(canonical) && entry.size > 0), '缺少必需资源前缀 ' + prefix);
    }
    // 持久解包模式只接管本次mkdir成功的新目录；已有目标无论是否为空都不能覆盖。
    jarActive(isCancelled); const output = retainedTarget ?? owner + '/contents'; await fs.mkdir(output);
    // 不采用Promise.race或超时reject：只有实际SDK调用结算，finally才有权清理这棵输出树。
    await zlib.decompressFile(frozen, output); jarActive(isCancelled);
    for (const entry of entries) {
      jarActive(isCancelled); const extracted = await jarExtracted(output, entry); if (entry.directory) continue;
      const opened = await fs.open(extracted, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const before = await fs.stat(opened.fd); jarRequire(before.size === entry.size, '解压条目长度不同'); let read = 0; let crc = 0;
        while (read < entry.size) {
          jarActive(isCancelled); const buffer = new ArrayBuffer(Math.min(JAR_CHUNK, entry.size - read));
          const count = await fs.read(opened.fd, buffer, { length: buffer.byteLength }); jarRequire(count > 0 && count <= buffer.byteLength, '解压条目被截断');
          crc = exportZipCrc32(crc, new Uint8Array(buffer, 0, count)); read += count;
        }
        jarRequire(crc === entry.crc && jarStamp(before) === jarStamp(await fs.stat(opened.fd)), '解压条目CRC或身份不符');
      } finally { await fs.close(opened); }
    }
    jarActive(isCancelled);
  } finally { await jarRemove(owner); }
}

/** 仅校验模式的独占输入和解压内容全部随本次owner收口，返回后不留下额外副本。
 * @throws 归档、内容、I/O或取消错误由导出owner处理。
 */
export async function verifyExportJar(path: string, scratchDir: string, expectedEntries: string[],
  expectedEntryPrefixes: string[], isCancelled: () => boolean): Promise<void> {
  await runJarVerification(path, scratchDir, expectedEntries, expectedEntryPrefixes, isCancelled);
}

/**
 * 已验证解包模式：targetDir必须尚不存在，成功后保留其中所有已验证字节供profile/内嵌件读取。
 * 与仅校验模式共用完整结构预检、SDK owner等待及CRC读回，不重复解压同一安装器。
 * 新目标mkdir成功后的失败现场保留给外层任务；只有SDK真正结算后本Promise才结束，外层才能清理。
 * @throws 已有目标、归档/内容异常、I/O或取消错误均不授予targetDir可信完成身份。
 */
export async function extractVerifiedExportJar(path: string, targetDir: string, expectedEntries: string[],
  expectedEntryPrefixes: string[], isCancelled: () => boolean): Promise<void> {
  jarActive(isCancelled);
  jarRequire(targetDir.startsWith('/') && !targetDir.endsWith('/') && targetDir.lastIndexOf('/') > 0 &&
    !targetDir.split('/').some((part: string): boolean => part === '.' || part === '..'), '解压目标不安全');
  let exists = false;
  try { await fs.lstat(targetDir); exists = true; }
  catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
  jarRequire(!exists, '解压目标已存在，拒绝接管');
  await runJarVerification(path, targetDir.substring(0, targetDir.lastIndexOf('/')), expectedEntries,
    expectedEntryPrefixes, isCancelled, targetDir);
}

/**
 * 当前 HAP 的应用 ABI 检查：确认唯一公开 provider，并检查首方未剥离产物中没有
 * 隐藏的第二份展开器，并证明权威TLS槽采用原生ELF TLS。只读本轮包、实际 native
 * 输出和 provider 输入，不扫描 SDK；元数据通过不等于目标线程生命周期验证通过。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { listZipEntryNames, readUniqueZipEntry } from './zip-entry-buffer.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const unwind = name => /^(?:_Unwind_|__unw_|unw_)/.test(name);
const providerName = 'libs/arm64-v8a/libc++_shared.so';
const required = ['__cxa_guard_acquire', '__cxa_throw', '__gxx_personality_v0', '_Unwind_RaiseException',
  '_Unwind_Resume', 'amcl_unwind_register_image', 'amcl_unwind_unregister_image'];
export const authoritativeTlsSlot = '_ZN4amcl10tlsstorage6detail4slotE';
// 对应tls_thread_storage.h的ThreadSlot：AArch64两个指针、一个unsigned Phase及尾部对齐。
const authoritativeTlsBytes = 24;

/** 所有 ELF 表偏移必须能无损表示，且完整处于当前文件；损坏字段不能通过 Buffer 截断补齐。 */
function range(bytes, offset, size) {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 0 || size < 0 || offset > bytes.length - size)
    throw Error('ABI ELF range is invalid');
}
const u64 = (bytes, offset) => { range(bytes, offset, 8); const result = Number(bytes.readBigUInt64LE(offset)); range(bytes, result, 0); return result; };
/** 地址、符号大小和TLS偏移不是文件偏移，不能误用文件长度限制；仍禁止JS精度截断。 */
const integer64 = (bytes, offset) => {
  range(bytes, offset, 8);
  const result = Number(bytes.readBigUInt64LE(offset));
  if (!Number.isSafeInteger(result)) throw Error('ABI ELF integer exceeds exact numeric range');
  return result;
};

/** 共用的有界符号读取器，保留UND供TLS混合模型检查；定义判定由调用方显式完成。
 * offset仅供元数据反例定位，value/size/type来自同一个真实ELF表项，不从字符串猜类型。
 */
export function elfAbiSymbolRecords(bytes, includePrivate = false) {
  if (bytes.length < 64 || bytes.toString('hex', 0, 6) !== '7f454c460201' || bytes.readUInt16LE(18) !== 183)
    throw Error('ABI checker requires ELF64 little-endian AArch64');
  const start = u64(bytes, 40), stride = bytes.readUInt16LE(58), count = bytes.readUInt16LE(60);
  if (!start || stride !== 64 || !count) throw Error('ABI artifact lacks supported symbol metadata');
  range(bytes, start, stride * count);
  const records = [];
  for (let index = 0; index < count; ++index) {
    const header = start + index * stride, kind = bytes.readUInt32LE(header + 4);
    if (kind !== 11 && !(includePrivate && kind === 2)) continue;
    const offset = u64(bytes, header + 24), size = u64(bytes, header + 32), link = bytes.readUInt32LE(header + 40);
    if (link >= count || u64(bytes, header + 56) !== 24 || size % 24) throw Error('ABI symbol table stride/link is invalid');
    range(bytes, offset, size);
    const stringHeader = start + link * stride;
    if (bytes.readUInt32LE(stringHeader + 4) !== 3) throw Error('ABI symbols do not reference a string table');
    const strings = u64(bytes, stringHeader + 24), length = u64(bytes, stringHeader + 32);
    range(bytes, strings, length);
    for (let at = offset; at < offset + size; at += 24) {
      const binding = bytes[at + 4] >> 4, visibility = bytes[at + 5] & 3;
      if (!includePrivate && (![1, 2, 10].includes(binding) || ![0, 3].includes(visibility))) continue;
      const name = bytes.readUInt32LE(at);
      if (name >= length) throw Error('ABI symbol name offset is invalid');
      const end = bytes.indexOf(0, strings + name);
      if (end < 0 || end >= strings + length) throw Error('ABI symbol name has no bounded terminator');
      records.push({ name: bytes.toString('utf8', strings + name, end), binding, visibility,
        type: bytes[at + 4] & 15, sectionIndex: bytes.readUInt16LE(at + 6),
        value: integer64(bytes, at + 8), size: integer64(bytes, at + 16), offset: at, tableKind: kind });
    }
  }
  return records;
}

/** 只把真实定义计入供应者；普通UND/weak UND、字符串常量和隐藏动态名字不能伪装公开实现。 */
export function elfAbiSymbols(bytes, includePrivate = false) {
  return new Set(elfAbiSymbolRecords(bytes, includePrivate).filter(symbol => symbol.sectionIndex !== 0).map(symbol => symbol.name));
}

/** 证实常驻宿主的权威槽是原生TLS对象。STT_TLS的st_value是PT_TLS内偏移，不能拿
 * 普通符号的虚拟地址公式检验；同时核所属节，防止只改type/名字就伪装成有效槽。
 * records在产品调用中由同一source缓冲区的共用读取器产生，避免首方大符号表重复解析。
 */
export function assertAuthoritativeTls(bytes, records = elfAbiSymbolRecords(bytes, true)) {
  const emulated = records.filter(symbol => symbol.name === `__emutls_v.${authoritativeTlsSlot}` ||
    symbol.name === `__emutls_t.${authoritativeTlsSlot}`);
  if (emulated.length) throw Error('Authoritative TLS slot has emulated TLS control/template symbols');
  const definitions = records.filter(symbol => symbol.name === authoritativeTlsSlot && symbol.sectionIndex !== 0);
  const identities = new Set(definitions.map(symbol => `${symbol.type}:${symbol.sectionIndex}:${symbol.value}:${symbol.size}`));
  if (!definitions.length || identities.size !== 1) throw Error('Authoritative TLS slot requires one consistent defined symbol');
  const slot = definitions[0];
  if (slot.type !== 6 || slot.size !== authoritativeTlsBytes || slot.value % 8)
    throw Error('Authoritative TLS slot must be an aligned 24-byte STT_TLS definition');
  const phoff = u64(bytes, 32), phsize = bytes.readUInt16LE(54), phcount = bytes.readUInt16LE(56);
  if (!phcount || phsize !== 56) throw Error('Authoritative TLS requires supported program headers');
  range(bytes, phoff, phsize * phcount);
  const segments = [];
  for (let index = 0; index < phcount; ++index) {
    const at = phoff + index * phsize;
    if (bytes.readUInt32LE(at) !== 7) continue;
    const offset = u64(bytes, at + 8), address = integer64(bytes, at + 16);
    const fileSize = integer64(bytes, at + 32), memorySize = integer64(bytes, at + 40), alignment = integer64(bytes, at + 48);
    range(bytes, offset, fileSize);
    if (fileSize > memorySize || !Number.isSafeInteger(address + memorySize) || alignment < 8 ||
        (BigInt(alignment) & (BigInt(alignment) - 1n)) !== 0n)
      throw Error('Authoritative TLS PT_TLS size/alignment is invalid');
    segments.push({ address, fileSize, memorySize, alignment });
  }
  if (segments.length !== 1) throw Error('Authoritative TLS requires exactly one PT_TLS segment');
  const tls = segments[0];
  if (slot.value > tls.memorySize - slot.size) throw Error('Authoritative TLS slot exceeds PT_TLS memory');
  const shoff = u64(bytes, 40), shsize = bytes.readUInt16LE(58), shcount = bytes.readUInt16LE(60);
  if (slot.sectionIndex >= shcount || slot.sectionIndex >= 0xff00 || shsize !== 64)
    throw Error('Authoritative TLS slot has an invalid defining section');
  const section = shoff + slot.sectionIndex * shsize;
  range(bytes, section, shsize);
  const kind = bytes.readUInt32LE(section + 4), flags = bytes.readBigUInt64LE(section + 8);
  const address = integer64(bytes, section + 16), size = integer64(bytes, section + 32);
  const relative = address - tls.address;
  if (![1, 8].includes(kind) || (flags & 0x402n) !== 0x402n || relative < 0 ||
      slot.value < relative || slot.value - relative > size - slot.size)
    throw Error('Authoritative TLS slot is not covered by its allocated TLS section');
  return { symbol: authoritativeTlsSlot, type: 'STT_TLS', bytes: slot.size, offset: slot.value,
    tlsMemoryBytes: tls.memorySize, nativeTls: true };
}

/** SDK strip 可以改变节表位置/数量，不能改变程序头和运行载荷；允许差异仅限对应 ELF 头字段。 */
export function assertSameLoadImage(source, packaged) {
  const phoff = u64(source, 32), stride = source.readUInt16LE(54), count = source.readUInt16LE(56);
  if (!count || stride !== 56 || packaged.readUInt16LE(54) !== stride || packaged.readUInt16LE(56) !== count || u64(packaged, 32) !== phoff)
    throw Error('ABI program header identity changed');
  range(source, phoff, stride * count); range(packaged, phoff, stride * count);
  if (!source.subarray(phoff, phoff + stride * count).equals(packaged.subarray(phoff, phoff + stride * count)))
    throw Error('ABI program headers changed during packaging');
  for (let index = 0; index < count; ++index) {
    const at = phoff + index * stride;
    if (source.readUInt32LE(at) !== 1) continue;
    const offset = u64(source, at + 8), size = u64(source, at + 32);
    range(source, offset, size); range(packaged, offset, size);
    const left = source.subarray(offset, offset + size), right = packaged.subarray(offset, offset + size);
    if (left.equals(right)) continue;
    for (let byte = 0; byte < size; ++byte) {
      const absolute = offset + byte;
      if (left[byte] !== right[byte] && !(absolute >= 40 && absolute < 48) && !(absolute >= 58 && absolute < 64))
        throw Error(`ABI runtime byte changed during packaging at ${absolute}`);
    }
  }
}

/** 复用同一包缓冲区，不重复复制大型 HAP；所有首方输入还须与包内实际装载内容一致。 */
export function checkApplicationAbi(archive, { root, product, target = product }) {
  const view = archive instanceof ArrayBuffer ? archive :
    (archive.byteOffset === 0 && archive.byteLength === archive.buffer.byteLength ? archive.buffer : archive.buffer.slice(archive.byteOffset, archive.byteOffset + archive.byteLength));
  const names = listZipEntryNames(view).filter(name => /^libs\/arm64-v8a\/.*\.so$/.test(name));
  if (!names.includes(providerName)) throw Error('Application ABI provider is missing');
  const providers = [], bridges = [], bridgeInputs = [];
  let authoritativeTls;
  let packagedProvider;
  for (const name of names) {
    const bytes = readUniqueZipEntry(view, name), symbols = elfAbiSymbols(bytes);
    const definedUnwind = [...symbols].filter(unwind);
    if (definedUnwind.length && name !== providerName)
      throw Error(`${name}: duplicate public unwind provider: ${definedUnwind.slice(0, 4).join(', ')}`);
    if (definedUnwind.length) providers.push({ name, symbols: definedUnwind });
    if (name === providerName) {
      for (const symbol of required) if (!symbols.has(symbol)) throw Error(`Application ABI provider missing ${symbol}`);
      packagedProvider = bytes;
    } else if (/^lib(?:entry|amcl_[^/]+)\.so$/.test(path.posix.basename(name))) {
      bridgeInputs.push({ name, bytes });
    }
  }
  if (providers.length !== 1 || providers[0].name !== providerName)
    throw Error(`Multiple public unwind providers: ${providers.map(item => item.name).join(', ')}`);
  // 先完成包内公共绑定判定，再核未剥离来源，避免旧反例被“本地输出已更新”掩盖根本冲突。
  for (const { name, bytes } of bridgeInputs) {
    const basename = path.posix.basename(name);
    let sourcePath = path.join(root, 'entry/build', product, 'intermediates/cmake', target, 'obj/arm64-v8a', basename);
    let lockedSource;
    let sourceFolder;
    if (['libamcl_zstdjni_std.so', 'libamcl_zstdjni_dh.so'].includes(basename)) {
      sourceFolder = path.join(root, 'prebuilt/mod-natives/zstd-jni');
      const manifest = JSON.parse(fs.readFileSync(path.join(sourceFolder, 'artifacts.json'), 'utf8'));
      const matches = manifest.artifacts?.filter(item => item.filename === basename);
      if (matches?.length === 1) lockedSource = matches[0].unstripped;
    } else if (basename === 'libamcl_lwjgl_jemalloc.so') {
      // jemalloc 是独立构建的 HAP 私有提供方。加载节来自实际包，非公开符号来自同一链接产物。
      sourceFolder = path.join(root, 'prebuilt/jemalloc');
      const manifest = JSON.parse(fs.readFileSync(path.join(sourceFolder, 'build-provenance.json'), 'utf8'));
      if (manifest.elf?.soname === basename) lockedSource = manifest.unstripped;
    }
    if (basename === 'libamcl_sdl_controller.so') {
      // 辅助手柄 SDL 独立交叉编译；源目录中交付未剥离 ELF，保留局部 unwind 表的完整审计。
      const proof = JSON.parse(fs.readFileSync(path.join(root,'prebuilt/sdl3/controller-build-provenance.json'),'utf8'));
      lockedSource = proof.artifacts.raw;
      sourcePath = path.join(root,'entry/libs/arm64-v8a',basename);
    }
    if (sourceFolder) {
      if (lockedSource?.path !== `symbols/${basename}` || !Number.isSafeInteger(lockedSource.size) ||
          lockedSource.size <= 0 || !/^[0-9a-f]{64}$/.test(lockedSource.sha256))
        throw Error(`${basename} ABI requires a unique unstripped source`);
      sourcePath = path.join(sourceFolder, lockedSource.path);
    }
    const source = fs.readFileSync(sourcePath);
    if (lockedSource && (source.length !== lockedSource.size || hash(source) !== lockedSource.sha256))
      throw Error(`${basename} ABI unstripped source identity mismatch`);
    assertSameLoadImage(source, bytes);
    const records = elfAbiSymbolRecords(source, true);
    if (lockedSource && !records.some(record => record.tableKind === 2 && record.name && record.sectionIndex !== 0))
      throw Error(`${basename} ABI source lacks private symbol table`);
    const privateCopies = records.filter(symbol => symbol.sectionIndex !== 0 && unwind(symbol.name)).map(symbol => symbol.name);
    if (privateCopies.length) throw Error(`${name}: private static unwinder duplicates: ${privateCopies.slice(0, 4).join(', ')}`);
    if (path.posix.basename(name) === 'libentry.so') authoritativeTls = assertAuthoritativeTls(source, records);
    bridges.push(name);
  }
  if (!authoritativeTls) throw Error('Application ABI lacks libentry authoritative TLS evidence');
  const provenance = JSON.parse(fs.readFileSync(path.join(root, 'prebuilt/abi/build-provenance.json'), 'utf8'));
  const source = fs.readFileSync(path.join(root, 'entry/libs/arm64-v8a/libc++_shared.so'));
  if (hash(source) !== provenance.artifactSha256 || source.length !== provenance.artifactBytes)
    throw Error('Application ABI input disagrees with its build provenance');
  assertSameLoadImage(source, packagedProvider);
  return { provider: providerName, inputSha256: hash(source), packagedSha256: hash(packagedProvider),
    checkedFirstPartyImages: bridges, authoritativeTls,
    scope: 'one application unwinder, native authoritative TLS metadata and exact runtime bytes; no runtime qualification implied' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const argument = name => { const at = process.argv.indexOf(name); if (at < 0 || !process.argv[at + 1]) throw Error(`${name} required`); return process.argv[at + 1]; };
    const hap = argument('--hap'), product = argument('--product');
    const target = /^entry-(.+)-(?:signed|unsigned)\.hap$/.exec(path.basename(hap))?.[1];
    if (!target) throw Error('Unexpected SDK HAP filename');
    const result = checkApplicationAbi(fs.readFileSync(hap), { root: argument('--root'), product, target });
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

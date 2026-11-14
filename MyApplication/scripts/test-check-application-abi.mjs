/** ABI 门禁的实际 ELF 字节反例：公开/私有副本、UND、剥离差异与载荷篡改分别验证。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { checkApplicationAbi, elfAbiSymbols, assertSameLoadImage } from './check-application-abi.mjs';
import { elfAbiFixture, entryAbiFixture, providerFixtureSymbols } from './fixtures/elf-abi-fixture.mjs';
import { createWorkspaceTemp } from './lib/workspace-paths.mjs';
import './test-application-tls-artifact.mjs';

const root = createWorkspaceTemp('application-abi-', { kind: 'run', root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..') });
const provider = elfAbiFixture(providerFixtureSymbols), entry = entryAbiFixture();
const native = path.join(root, 'entry/build/default/intermediates/cmake/default/obj/arm64-v8a');
fs.mkdirSync(native, { recursive: true });
fs.mkdirSync(path.join(root, 'entry/libs/arm64-v8a'), { recursive: true });
fs.mkdirSync(path.join(root, 'prebuilt/abi'), { recursive: true });
fs.writeFileSync(path.join(native, 'libentry.so'), entry);
fs.writeFileSync(path.join(root, 'entry/libs/arm64-v8a/libc++_shared.so'), provider);
fs.writeFileSync(path.join(root, 'prebuilt/abi/build-provenance.json'), JSON.stringify({ artifactBytes: provider.length,
  artifactSha256: createHash('sha256').update(provider).digest('hex') }));

/** 最小 stored ZIP，只承载本次明确的 ELF 数据；不调用签名器或编译工具。 */
function archive(entries) {
  let offset = 0; const local = [], central = [];
  for (const [name, bytes] of entries) {
    const label = Buffer.from(name), header = Buffer.alloc(30), directory = Buffer.alloc(46);
    header.writeUInt32LE(0x04034b50); header.writeUInt32LE(bytes.length, 18); header.writeUInt32LE(bytes.length, 22);
    header.writeUInt16LE(label.length, 26);
    directory.writeUInt32LE(0x02014b50); directory.writeUInt32LE(bytes.length, 20); directory.writeUInt32LE(bytes.length, 24);
    directory.writeUInt16LE(label.length, 28); directory.writeUInt32LE(offset, 42);
    local.push(header, label, bytes); central.push(directory, label); offset += header.length + label.length + bytes.length;
  }
  const table = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(table.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, table, end]);
}
const check = (entryBytes = entry, providerBytes = provider, extra = []) => checkApplicationAbi(archive([
  ['libs/arm64-v8a/libentry.so', entryBytes], ['libs/arm64-v8a/libc++_shared.so', providerBytes], ...extra]), { root, product: 'default' });
assert.equal(check().checkedFirstPartyImages.length, 1);
assert.equal(check().authoritativeTls.nativeTls, true);
const emulatedSlot = entryAbiFixture([], ['__emutls_v._ZN4amcl10tlsstorage6detail4slotE']);
fs.writeFileSync(path.join(native, 'libentry.so'), emulatedSlot);
assert.throws(() => check(), /Authoritative TLS slot has emulated/);
fs.writeFileSync(path.join(native, 'libentry.so'), entry);
assert.throws(() => check(elfAbiFixture(['_Unwind_RaiseException'])), /duplicate public/);
fs.writeFileSync(path.join(native, 'libentry.so'), entryAbiFixture([], ['_Unwind_Resume']));
assert.throws(() => check(), /private static unwinder/);
fs.writeFileSync(path.join(native, 'libentry.so'), entry);
assert.throws(() => check(entry, elfAbiFixture(providerFixtureSymbols.slice(1))), /missing __cxa_guard/);
assert.throws(() => check(entry, provider, [['libs/arm64-v8a/libc++_shared.so', provider]]), /exactly once/);

const undefinedSymbol = elfAbiFixture(['_Unwind_RaiseException']);
undefinedSymbol.writeUInt16LE(0, 256 + 24 + 6);
assert(!elfAbiSymbols(undefinedSymbol).has('_Unwind_RaiseException'));
const corrupt = elfAbiFixture(); corrupt.writeUInt32LE(99, 2048 + 64 + 40);
assert.throws(() => elfAbiSymbols(corrupt), /stride\/link/);
const changed = Buffer.from(provider); changed[200] ^= 1;
assert.throws(() => check(entry, changed), /runtime byte changed/);
const sectionOnly = Buffer.from(provider); sectionOnly.writeUInt16LE(0, 62);
assertSameLoadImage(provider, sectionOnly);
const changedHeader = Buffer.from(provider); changedHeader[68] ^= 1;
assert.throws(() => assertSameLoadImage(provider, changedHeader), /program headers changed/);

// 锁定预编译JNI必须指向自己的未剥离来源，不能为绕过检查复制到CMake目录或跳过私有符号。
const zstdName = 'libamcl_zstdjni_std.so', zstdRoot = path.join(root, 'prebuilt/mod-natives/zstd-jni');
fs.mkdirSync(path.join(zstdRoot, 'symbols'), { recursive: true });
const zstd = elfAbiFixture([], ['zstd_internal_helper']);
const zstdSource = path.join(zstdRoot, 'symbols', zstdName);
function zstdLock(bytes) {
  fs.writeFileSync(zstdSource, bytes);
  fs.writeFileSync(path.join(zstdRoot, 'artifacts.json'), JSON.stringify({ artifacts: [{ filename: zstdName,
    unstripped: { path: 'symbols/' + zstdName, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') } }] }));
}
zstdLock(zstd);
assert(check(entry, provider, [['libs/arm64-v8a/' + zstdName, zstd]]).checkedFirstPartyImages.includes('libs/arm64-v8a/' + zstdName));
fs.writeFileSync(zstdSource, Buffer.concat([zstd, Buffer.from([1])]));
assert.throws(() => check(entry, provider, [['libs/arm64-v8a/' + zstdName, zstd]]), /unstripped source identity/);
const privateUnwind = elfAbiFixture([], ['_Unwind_Resume']); zstdLock(privateUnwind);
assert.throws(() => check(entry, provider, [['libs/arm64-v8a/' + zstdName, privateUnwind]]), /private static unwinder/);
fs.writeFileSync(path.join(zstdRoot, 'artifacts.json'), JSON.stringify({ artifacts: [] }));
assert.throws(() => check(entry, provider, [['libs/arm64-v8a/' + zstdName, zstd]]), /unique unstripped source/);
console.log('PASS application ABI: real ELF public/private duplicate, UND, malformed metadata and payload identity controls');

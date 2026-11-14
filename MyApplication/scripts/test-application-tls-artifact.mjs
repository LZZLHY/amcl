/** 原生权威TLS槽的结构反例与可选真实SDK夹具。默认仅执行小型字节测试，不扫描SDK。
 * 显式--clang/--sysroot/--output时才编译最小目标共享库，保留命令/版本/源与产物SHA。
 * 输出必须为仓外绝对目录，测试不安装、不运行目标ELF，也不赋予目标线程退出资格。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { assertAuthoritativeTls, authoritativeTlsSlot, elfAbiSymbolRecords, assertSameLoadImage } from './check-application-abi.mjs';
import { elfAbiFixture, entryAbiFixture } from './fixtures/elf-abi-fixture.mjs';

const slotRecord = bytes => elfAbiSymbolRecords(bytes, true).find(symbol => symbol.name === authoritativeTlsSlot);
const mutate = change => { const bytes = entryAbiFixture(); change(bytes, slotRecord(bytes).offset); return bytes; };
let checks = 0;
const reject = (bytes, pattern) => { assert.throws(() => assertAuthoritativeTls(bytes), pattern); ++checks; };
assert.equal(assertAuthoritativeTls(entryAbiFixture()).bytes, 24); ++checks;
reject(elfAbiFixture(), /defined symbol/);
reject(mutate((bytes, at) => { bytes[at + 4] = 1; }), /STT_TLS/);
reject(mutate((bytes, at) => { bytes.writeBigUInt64LE(23n, at + 16); }), /24-byte/);
reject(mutate((bytes, at) => { bytes.writeBigUInt64LE(24n, at + 8); }), /exceeds PT_TLS/);
reject(mutate((bytes, at) => { bytes.writeBigUInt64LE(1n, at + 8); }), /aligned/);
reject(mutate((bytes, at) => { bytes.writeBigUInt64LE(1n << 53n, at + 8); }), /exact numeric range/);
reject(mutate((bytes, at) => { bytes.writeUInt16LE(0, at + 6); }), /defined symbol/);
reject(mutate((bytes, at) => { bytes.writeUInt16LE(0xfff1, at + 6); }), /defining section/);
reject(mutate(bytes => { bytes.writeBigUInt64LE(3n, 2048 + 5 * 64 + 8); }), /TLS section/);
reject(mutate(bytes => { bytes.writeBigUInt64LE(16n, 2048 + 5 * 64 + 32); }), /TLS section/);
reject(mutate(bytes => { bytes.writeUInt32LE(0, 120); }), /exactly one PT_TLS/);
reject(mutate(bytes => { bytes.writeUInt32LE(7, 64); }), /exactly one PT_TLS/);
reject(mutate(bytes => { bytes.writeBigUInt64LE(25n, 120 + 32); }), /PT_TLS size/);
reject(mutate(bytes => { bytes.writeBigUInt64LE(12n, 120 + 48); }), /PT_TLS size\/alignment/);
for (const prefix of ['__emutls_v.', '__emutls_t.']) {
  const bytes = entryAbiFixture([], [prefix + authoritativeTlsSlot]);
  reject(bytes, /emulated TLS/);
  const control = elfAbiSymbolRecords(bytes, true).find(symbol => symbol.name === prefix + authoritativeTlsSlot);
  bytes.writeUInt16LE(0, control.offset + 6); reject(bytes, /emulated TLS/); // UND控制块也表示另一个寻址合同。
}
assert(assertAuthoritativeTls(entryAbiFixture([], ['__emutls_v.unrelated_tls_value'])).nativeTls); ++checks;
const duplicate = entryAbiFixture([authoritativeTlsSlot]);
reject(duplicate, /consistent defined symbol/);
const dynamicSlot = elfAbiSymbolRecords(duplicate, true).find(symbol => symbol.name === authoritativeTlsSlot && symbol.tableKind === 11);
duplicate[dynamicSlot.offset + 4] = 0x16; duplicate.writeUInt16LE(5, dynamicSlot.offset + 6);
duplicate.writeBigUInt64LE(0n, dynamicSlot.offset + 8); duplicate.writeBigUInt64LE(24n, dynamicSlot.offset + 16);
assert(assertAuthoritativeTls(duplicate).nativeTls); ++checks; // 同一定义出现在dynsym/symtab不是两份槽。
console.log(`PASS authoritative TLS metadata: ${checks} positive/negative controls`);

/** 正常quick门只导入/调用检查器，绝不自动发起这个SDK编译分支。 */
if (process.argv.includes('--clang')) {
  const argument = name => {
    const index = process.argv.indexOf(name);
    if (index < 0 || !process.argv[index + 1]) throw Error(`${name} required for SDK fixture mode`);
    return process.argv[index + 1];
  };
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const clang = path.resolve(argument('--clang')), sysroot = path.resolve(argument('--sysroot'));
  const requestedOutput = argument('--output');
  if (!path.isAbsolute(requestedOutput)) throw Error('SDK TLS fixture output must be an absolute external directory');
  const output = path.resolve(requestedOutput), relative = path.relative(root, output);
  if (!relative || (!relative.startsWith('..' + path.sep) && !path.isAbsolute(relative)))
    throw Error('SDK TLS fixture output must be outside the project');
  fs.mkdirSync(output, { recursive: true });
  const identity = file => ({ path: file, bytes: fs.statSync(file).size,
    sha256: createHash('sha256').update(fs.readFileSync(file)).digest('hex') });
  const receipt = { startedAt: new Date().toISOString(), compiler: identity(clang), commands: [], outputs: [],
    targetRuntimeQualified: false, core: identity(path.join(root, 'entry/src/main/cpp/jvm/tls_thread_storage.h')) };
  const run = args => {
    const startedAt = new Date().toISOString();
    const result = spawnSync(clang, args, { encoding: 'utf8', windowsHide: true });
    receipt.commands.push({ args, startedAt, finishedAt: new Date().toISOString(), status: result.status,
      stdout: result.stdout, stderr: result.stderr, error: result.error?.message });
    if (result.error || result.status !== 0) throw Error(`SDK TLS fixture failed: ${result.error?.message ?? result.stderr}`);
    return result.stdout;
  };
  try {
    receipt.version = run(['--version']);
    const common = ['--target=aarch64-linux-ohos', `--sysroot=${sysroot}`, '-std=c++17', '-O2', '-fPIC',
      '-fvisibility=hidden', '-Wall', '-Wextra', '-Werror'];
    const input = path.join(root, 'scripts/fixtures/application-tls-slot.cpp');
    const other = path.join(root, 'scripts/fixtures/application-tls-other.cpp');
    receipt.inputs = [identity(input), identity(other)];
    const nativeObject = path.join(output, 'native.o'), emulatedObject = path.join(output, 'emulated.o'), otherObject = path.join(output, 'other.o');
    run([...common, '-fno-emulated-tls', '-c', input, '-o', nativeObject]);
    run([...common, '-c', input, '-o', emulatedObject]);
    run([...common, '-c', other, '-o', otherObject]);
    const link = (name, objects) => {
      const file = path.join(output, name);
      run([...common, '-nostdlib', '-shared', ...objects, '-o', file]);
      receipt.outputs.push(identity(file)); return fs.readFileSync(file);
    };
    const native = link('native.so', [nativeObject]);
    const emulated = link('emulated.so', [emulatedObject]);
    const unrelated = link('native-with-unrelated-emutls.so', [nativeObject, otherObject]);
    // 同槽混合TU时符号名字不同，不能依赖链接器报错。换导出函数名仅避免夹具入口重名。
    const mixedObject = path.join(output, 'mixed-emulated.o');
    run([...common, '-Dapplication_tls_slot_fixture=application_tls_mixed_fixture', '-c', input, '-o', mixedObject]);
    const mixed = link('mixed-slot.so', [nativeObject, mixedObject]);
    assert(assertAuthoritativeTls(native).nativeTls);
    assert(assertAuthoritativeTls(unrelated).nativeTls);
    assert.throws(() => assertAuthoritativeTls(emulated), /emulated TLS/);
    assert.throws(() => assertAuthoritativeTls(mixed), /emulated TLS/);
    // 真实strip副本只由明确选择的SDK工具生成；运行载荷和程序头必须原字节相同。
    const strip = path.join(path.dirname(clang), process.platform === 'win32' ? 'llvm-strip.exe' : 'llvm-strip');
    const strippedPath = path.join(output, 'native-stripped.so');
    const stripping = spawnSync(strip, ['--strip-unneeded', path.join(output, 'native.so'), '-o', strippedPath], { encoding: 'utf8', windowsHide: true });
    receipt.strip = { tool: identity(strip), status: stripping.status, stdout: stripping.stdout, stderr: stripping.stderr };
    if (stripping.error || stripping.status !== 0) throw Error(`SDK fixture strip failed: ${stripping.error?.message ?? stripping.stderr}`);
    assertSameLoadImage(native, fs.readFileSync(strippedPath)); receipt.outputs.push(identity(strippedPath));
    receipt.state = 'PASS'; receipt.nativeTls = assertAuthoritativeTls(native);
    console.log('PASS real SDK native/emulated/mixed/unrelated TLS artifacts and stripped PT_LOAD identity');
  } catch (error) { receipt.state = 'FAIL'; receipt.failure = error.message; throw error; }
  finally { receipt.finishedAt = new Date().toISOString(); fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2)); }
}

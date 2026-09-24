/**
 * JNA 三个独立 native ABI 槽的来源/交付门禁。工作树核对锁定完整字节，HAP 核对所有
 * SHF_ALLOC 非NOBITS节，允许SDK strip去掉调试节而不允许机器码、动态符号或数据漂移。
 * 不通过主版本字符串相同冒充内容来源一致；manifest由已核验上游JAR条目生成。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {readUniqueZipEntry} from './zip-entry-buffer.mjs';
import {stripComments} from './lib/source-noise.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

/** 严格读取ELF64 little-endian节表；不接受缺失/越界表后得到“零节相等”的假阳性。 */
export function jnaAllocatedSections(bytes) {
  const range = (at, length) => {
    if (!Number.isSafeInteger(at) || !Number.isSafeInteger(length) || at < 0 || length < 0 || at > bytes.length - length) throw Error('JNA ELF section range invalid');
  };
  range(0, 64);
  if (bytes.subarray(0, 6).toString('hex') !== '7f454c460201' || bytes.readUInt16LE(18) !== 183) throw Error('JNA ELF must be AArch64 little endian');
  const offset = Number(bytes.readBigUInt64LE(40));
  const size = bytes.readUInt16LE(58), count = bytes.readUInt16LE(60), stringsIndex = bytes.readUInt16LE(62);
  if (size !== 64 || count < 10 || stringsIndex >= count) throw Error('JNA ELF section table invalid');
  range(offset, size * count);
  const header = index => {
    const p = offset + size * index;
    return {name: bytes.readUInt32LE(p), type: bytes.readUInt32LE(p + 4), flags: bytes.readBigUInt64LE(p + 8),
      address: Number(bytes.readBigUInt64LE(p + 16)), offset: Number(bytes.readBigUInt64LE(p + 24)), size: Number(bytes.readBigUInt64LE(p + 32))};
  };
  const strings = header(stringsIndex); range(strings.offset, strings.size);
  const result = {};
  for (let i = 0; i < count; ++i) {
    const section = header(i);
    if (!(section.flags & 2n) || section.type === 8) continue;
    if (section.name >= strings.size) throw Error('JNA ELF section name invalid');
    const end = bytes.indexOf(0, strings.offset + section.name);
    if (end < 0 || end >= strings.offset + strings.size) throw Error('JNA ELF section name unterminated');
    const name = bytes.toString('ascii', strings.offset + section.name, end);
    if (Object.hasOwn(result, name)) throw Error('JNA ELF duplicate section');
    range(section.offset, section.size);
    result[name] = {address: section.address, size: section.size, sha256: sha256(bytes.subarray(section.offset, section.offset + section.size))};
  }
  if (!result['.text'] || !result['.rodata'] || !result['.dynsym']) throw Error('JNA ELF required positive sections missing');
  return result;
}

/** 与同一清单逐节比较；真实上游字节与SDK剥离后字节都必须维持相同运行内容。 */
export function verifyJnaNative(bytes, slot, exact = false) {
  if (exact && (sha256(bytes) !== slot.artifactSha256 || bytes.length !== slot.artifactSize)) throw Error('JNA locked bytes mismatch: ' + slot.filename);
  const actual = jnaAllocatedSections(bytes);
  const expected = slot.allocatedSections;
  if (Object.keys(actual).length !== Object.keys(expected).length) throw Error('JNA allocated section set mismatch: ' + slot.filename);
  for (const [name, value] of Object.entries(expected)) {
    if (JSON.stringify(actual[name]) !== JSON.stringify(value)) throw Error('JNA allocated section mismatch: ' + slot.filename + '/' + name);
  }
  return {filename: slot.filename, protocol: slot.protocol, sha256: sha256(bytes), bytes: bytes.length};
}

/** 守住实际resolver→失败传播→同次属性冻结的接线，不把helper中的错误码要求复制到调用点。 */
export function verifyJnaWiring(source) {
  const launcher = stripComments(source, {lang: 'c'});
  const resolve = launcher.indexOf('ResolveJnaBootstrap(classpath, hapNativeDir)');
  const properties = launcher.indexOf('g_runtimeBootstrapProperties = amcl::jvm::RuntimeBootstrapProperties(', resolve);
  const freeze = launcher.indexOf('FreezeBootstrapProperties(finalJvmArgs', properties);
  const failure = launcher.slice(resolve, properties).match(/if\s*\(!jnaBootstrap\.ok\)\s*\{([\s\S]*?)\n\s*\}/)?.[1] ?? '';
  if (resolve < 0 || properties <= resolve || freeze <= properties ||
      !failure.includes('recordGraphicsLaunchFailure(-5, "bootstrap", "jna_runtime_artifact_missing"') ||
      !/\breturn\s+-5\s*;/.test(failure) ||
      !launcher.slice(properties, freeze).includes(', jnaBootstrap);')) throw Error('JNA production resolution wiring missing');
}

/** 检查现役源/同步副本并可选检查精确HAP；不隐式寻找“最新包”。 */
export function checkJnaRuntime(hapPath) {
  const manifestPath = path.join(root, 'prebuilt/jna/manifest.json');
  const manifestBytes = fs.readFileSync(manifestPath);
  const manifest = JSON.parse(manifestBytes);
  const lock = fs.readFileSync(path.join(root, 'deps.lock'), 'utf8').split('[jna-runtime]')[1]?.split(/^\[/m)[0] ?? '';
  const expectedHash = lock.match(/^manifest_sha256\s*=\s*([a-f0-9]{64})\s*$/m)?.[1];
  if (expectedHash !== sha256(manifestBytes)) throw Error('JNA manifest/deps.lock identity mismatch');
  if (manifest.schemaVersion !== 1 || manifest.abi !== 'arm64-v8a' || manifest.slots.length !== 3) throw Error('JNA manifest schema/slots invalid');
  const expectedNames = ['jnidispatch_v5', 'jnidispatch_v6', 'jnidispatch'];
  if (manifest.slots.some((slot, i) => slot.libraryName !== expectedNames[i] || slot.filename !== 'lib' + slot.libraryName + '.so')) throw Error('JNA slot name mismatch');
  const results = [];
  const hap = hapPath ? fs.readFileSync(path.resolve(hapPath)) : undefined;
  for (const slot of manifest.slots) {
    for (const directory of ['prebuilt/jna', 'entry/libs/arm64-v8a']) verifyJnaNative(fs.readFileSync(path.join(root, directory, slot.filename)), slot, true);
    if (hap) results.push(verifyJnaNative(readUniqueZipEntry(hap, 'libs/arm64-v8a/' + slot.filename), slot));
  }
  const launcher = fs.readFileSync(path.join(root, 'entry/src/main/cpp/jvm/mc_launcher.cpp'), 'utf8');
  verifyJnaWiring(launcher);
  return {manifestSha256: expectedHash, sourceSlots: expectedNames, hap: hapPath ? path.resolve(hapPath) : null, artifacts: results};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(checkJnaRuntime(process.argv[2]), null, 2));
}

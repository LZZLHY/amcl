/** 校验实际zstd-JNI制品与构建输入，不将导出总数等同完整Java API/设备资格。 */
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {locateReadelf} from './check-lwjgl-native-surface.mjs';
import {allocatedElfIdentity} from './check-hap-native-providers.mjs';
import {assertSameLoadImage, elfAbiSymbolRecords} from './check-application-abi.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (ok, message) => { if (!ok) throw new Error(message); };

/** SDK stage前核编译配方/适配源码、148项精确导出及唯一libc依赖；不执行任何目标指令。 */
export function checkZstdArtifacts({root = ROOT, readelf = locateReadelf()} = {}) {
  const folder = join(root, 'prebuilt/mod-natives/zstd-jni');
  const spec = JSON.parse(readFileSync(join(folder, 'build-inputs.json'), 'utf8'));
  const lock = JSON.parse(readFileSync(join(folder, 'artifacts.json'), 'utf8'));
  const dependency = readFileSync(join(root, 'deps.lock'), 'utf8').split('[zstd-jni]')[1]?.split(/\n\[/)[0];
  requireValue(dependency, 'zstd dependency lock section missing');
  for (const [key, name] of [['inputs', 'build-inputs.json'], ['bindings', 'verified-bindings.json'], ['artifacts', 'artifacts.json']]) {
    const matches = [...dependency.matchAll(new RegExp(`^${key}_sha256\\s*=\\s*([0-9a-f]{64})\\s*$`, 'gm'))];
    requireValue(matches.length === 1 && matches[0][1] === hash(readFileSync(join(folder, name))), 'zstd registry identity mismatch: ' + key);
  }
  requireValue(lock.schemaVersion === 1 && lock.artifacts?.length === 2 && spec.variants?.length === 2, 'Incomplete zstd input/lock');
  requireValue(lock.inputContractSha256 === hash(readFileSync(join(folder, 'build-inputs.json'))), 'zstd build input snapshot mismatch');
  requireValue(lock.sourceCommit === spec.source.commit && lock.sourceArchiveSha256 === spec.source.sha256 &&
    lock.recipeSha256 === hash(readFileSync(join(root, 'scripts/build-zstd-jni-ohos.py'))), 'zstd source/recipe identity mismatch');
  for (const file of ['qsort_context.c', 'qsort_context.h'])
    requireValue(lock.adapterSources?.[file] === hash(readFileSync(join(folder, file))), 'zstd adapter source identity mismatch');
  for (const header of spec.jniHeaders)
    requireValue(header.sha256 === hash(readFileSync(join(root, header.path))), 'zstd target JNI header identity mismatch');
  for (const record of lock.artifacts) {
    const variant = spec.variants.filter(x => x.filename === record.filename && x.id === record.id);
    requireValue(variant.length === 1, 'zstd artifact has no unique source variant');
    const path = join(folder, 'arm64-v8a', record.filename), bytes = readFileSync(path);
    requireValue(bytes.length === record.size && hash(bytes) === record.sha256, 'zstd artifact byte mismatch');
    allocatedElfIdentity(bytes);
    requireValue(record.unstripped?.path === `symbols/${record.filename}`, 'zstd unstripped source path missing');
    const raw = readFileSync(join(folder, record.unstripped.path));
    requireValue(raw.length === record.unstripped.size && hash(raw) === record.unstripped.sha256, 'zstd unstripped source byte mismatch');
    const privateSymbols = elfAbiSymbolRecords(raw, true);
    requireValue(privateSymbols.some(s => s.tableKind === 2), 'zstd unstripped source has no private symbols');
    requireValue(!privateSymbols.some(s => s.sectionIndex !== 0 && /^(?:_Unwind_|__unw_|unw_)/.test(s.name)), 'zstd private unwinder duplicate');
    assertSameLoadImage(raw, bytes);
    const symbols = execFileSync(readelf, ['--dyn-symbols', '--wide', path], {encoding: 'utf8'});
    const exported = new Set();
    for (const line of symbols.split(/\r?\n/)) {
      const p = line.trim().split(/\s+/);
      if (p.length >= 8 && p[6] !== 'UND' && p[7].startsWith('Java_')) exported.add(p[7].split('@')[0]);
    }
    requireValue(JSON.stringify([...exported].sort()) === JSON.stringify([...variant[0].jniExports].sort()) &&
      JSON.stringify([...exported].sort()) === JSON.stringify([...record.jniExports].sort()), 'zstd exact JNI exports mismatch');
    requireValue(!symbols.includes('GLIBC_'), 'zstd artifact still requires glibc versions');
    const dynamic = execFileSync(readelf, ['-d', path], {encoding: 'utf8'});
    const needed = [...dynamic.matchAll(/Shared library: \[([^\]]+)\]/g)].map(m => m[1]);
    const sonames = [...dynamic.matchAll(/\(SONAME\).*?\[([^\]]+)\]/g)].map(m => m[1]);
    requireValue(needed.join(',') === 'libc.so' && sonames.length === 1 && sonames[0] === record.filename &&
      !/\((?:RPATH|RUNPATH)\)/.test(dynamic), 'zstd SONAME/dependency/search-path mismatch');
  }
  return lock;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
  try { checkZstdArtifacts({root: option('--root') || ROOT, readelf: option('--readelf') || locateReadelf()}); console.log('[zstd-artifacts] PASS two exact OHOS JNI variants'); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}

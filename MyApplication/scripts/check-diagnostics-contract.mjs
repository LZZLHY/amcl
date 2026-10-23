import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { PRODUCT_ROOT, productDefinition } from './product-contract.mjs';
import { diagnosticProfile } from './diagnostic-profile.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { readZipEntryNames, parseTestNapiNames } from './check-release-no-test-symbols.mjs';
import { verifyHapSignature, readElfIdentity, readElfSectionNames } from './check-mg-build-contract.mjs';

const hash = buffer => createHash('sha256').update(buffer).digest('hex');
export const extraTestNames = ['runVulkanSelfTest', 'runJvmEmbedTest', 'isJvmTestRunning', 'downloadEngineSelfTest', 'probeNativePath'];
export function evaluateDiagnosticMetadata(observed, expected, product) {
  const { nativeGlValidation = false, ...diagnostics } = observed ?? {};
  const issues = [];
  if (typeof nativeGlValidation !== 'boolean' || (nativeGlValidation && product !== 'desktop')) issues.push('invalid native GL validation identity');
  if (JSON.stringify(diagnostics) !== JSON.stringify(expected)) issues.push('diagnostic metadata drift');
  return issues;
}
/** 只证明实际GLFW消费观察正文编入/裁剪；不以mask、其它DSO或源码名称代证执行。 */
export function evaluateInputTraceProducer(glfw, enabled) {
  return glfw.includes(Buffer.from('AMCL_LOOK_GLFW obs=')) === enabled ? []
    : [`GLFW producer AMCL_INPUT_TRACE inclusion mismatch: expected present=${enabled}`];
}

/**
 * VMA是所有产品共享的锁定native，不能借宿主diagnostics mask证明其内部已静默。
 * 无条件成功trace的固定前缀来自真实旧生产ELF；生产重建必须在预处理期裁掉正文，
 * 包审计直接检查所装入的VMA载荷，防止源码修正后仍打包旧库。
 */
export function evaluateVmaProductionLog(bytes) {
  return bytes.includes(Buffer.from('[AMCL_VULKAN_VMA]'))
    ? ['VMA: synchronous allocation trace remains in the shared production native'] : [];
}

/**
 * 检查真实 GLFW ELF 自己的诊断 getter 与窗口创建入口。复用现役 MG 的 ELF 身份/节名读取，
 * dynsym 字段沿用 SDL 符号门的读取方式；只核这两个既有 consumer 所需的范围和版本边界。
 * 源码 visibility、--undefined 保留、rodata 字符串及其它 DSO 同名出口均不能代替本表定义。
 * 结果只授产物动态导出元数据；不会执行 getter，也不证明设备 namespace、实际查询/返回值、
 * p_create 的同 provider 或原 dlclose 路由。L2 的运行时 same-provider 门仍必须独立成立。
 */
export function evaluateDiagnosticGetter(bytes) {
  const name = 'amclDiagnosticBuildIdentity';
  const required = [name, 'glfwCreateWindow'];
  const errorBound = 'artifact-ELF dynamic-export fields/VERSYM default bit only; no hash-table validation or runtime lookup/return/provider qualification';
  const fail = message => ({ issues: [`GLFW diagnostic getter: ${message}`], symbol: null, errorBound });
  try {
    // 所有偏移先过安全整数/完整范围；不把截断表、默认项宽或全 Buffer 尾部当成合法表。
    const range = (offset, size) => {
      if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 0 || size < 0 ||
          offset > bytes.length - size) throw Error('invalid/truncated ELF range');
    };
    const u64 = offset => {
      range(offset, 8);
      const value = bytes.readBigUInt64LE(offset);
      if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw Error('ELF offset exceeds safe integer range');
      return Number(value);
    };
    range(0, 64);
    const phoff = u64(32), phsize = bytes.readUInt16LE(54), phcount = bytes.readUInt16LE(56);
    if (phsize !== 56 || !phcount) throw Error('invalid ELF program-header table');
    range(phoff, phsize * phcount);
    const loads = [], dynamics = [];
    for (let i = 0; i < phcount; ++i) {
      const p = phoff + i * phsize, type = bytes.readUInt32LE(p);
      const row = { offset: u64(p + 8), address: u64(p + 16), size: u64(p + 32), flags: bytes.readUInt32LE(p + 4) };
      range(row.offset, row.size);
      if (type === 1) loads.push(row);
      if (type === 2) dynamics.push(row);
    }
    if (dynamics.length !== 1 || dynamics[0].size % 16) throw Error('missing/duplicate/invalid PT_DYNAMIC');
    const identity = readElfIdentity(bytes);
    if (identity.type !== 3 || identity.machine !== 183 || identity.soname !== 'libglfw.so')
      throw Error('expected ELF64 little-endian AArch64 DYN libglfw.so');
    const shoff = u64(40), shsize = bytes.readUInt16LE(58), shcount = bytes.readUInt16LE(60);
    if (shsize !== 64 || !shcount) throw Error('invalid ELF section-header table');
    range(shoff, shsize * shcount);
    const names = readElfSectionNames(bytes), sections = [];
    if (names.length !== shcount) throw Error('missing ELF section names');
    for (let i = 0; i < shcount; ++i) {
      const p = shoff + i * shsize;
      const row = { index: i, name: names[i], type: bytes.readUInt32LE(p + 4), flags: bytes.readBigUInt64LE(p + 8),
        address: u64(p + 16), offset: u64(p + 24), size: u64(p + 32), link: bytes.readUInt32LE(p + 40), entsize: u64(p + 56) };
      if (row.type !== 8) range(row.offset, row.size);
      sections.push(row);
    }
    const tables = sections.filter(row => row.type === 11);
    if (tables.length !== 1 || tables[0].name !== '.dynsym') throw Error('missing/duplicate dynamic-symbol table');
    const table = tables[0], strings = sections[table.link];
    if (table.entsize !== 24 || !table.size || table.size % 24 || !strings || strings.type !== 3 ||
        !(table.flags & 2n) || !(strings.flags & 2n))
      throw Error('invalid dynsym entry size/string-table link');
    // 同一 PT_DYNAMIC 的 loader 指针必须回绑此表，防伪造旁置 DYNSYM 节供审核通过。
    const tags = new Map(); let terminated = false;
    for (let p = dynamics[0].offset; p < dynamics[0].offset + dynamics[0].size; p += 16) {
      const tag = bytes.readBigInt64LE(p), value = u64(p + 8);
      if (tag === 0n) { terminated = true; break; }
      if ([5n, 6n, 10n, 11n, 0x6ffffff0n].includes(tag)) {
        if (tags.has(tag)) throw Error('duplicate dynamic symbol/string pointer');
        tags.set(tag, value);
      }
    }
    const mapped = section => loads.some(row => section.address >= row.address &&
      section.address - row.address <= row.size - section.size &&
      row.offset + (section.address - row.address) === section.offset);
    if (!terminated || tags.get(6n) !== table.address || tags.get(5n) !== strings.address ||
        tags.get(11n) !== 24 || tags.get(10n) !== strings.size || !mapped(table) || !mapped(strings))
      throw Error('PT_DYNAMIC dynsym/dynstr binding mismatch');
    const versions = sections.filter(row => row.type === 0x6fffffff);
    const count = table.size / 24;
    if (versions.length > 1 || (versions.length &&
        (versions[0].link !== table.index || versions[0].size !== count * 2 || versions[0].entsize !== 2 ||
         tags.get(0x6ffffff0n) !== versions[0].address || !mapped(versions[0]))) ||
        (!versions.length && tags.has(0x6ffffff0n)))
      throw Error('invalid/duplicate VERSYM table');
    const rows = [];
    for (let index = 0; index < count; ++index) {
      const p = table.offset + index * 24, offset = bytes.readUInt32LE(p);
      if (offset >= strings.size) throw Error('dynsym name outside dynstr');
      const start = strings.offset + offset, end = bytes.indexOf(0, start);
      if (end < start || end >= strings.offset + strings.size) throw Error('unterminated dynsym name');
      const symbolName = required.find(candidate => bytes.subarray(start, end).equals(Buffer.from(candidate)));
      if (!symbolName) continue;
      const info = bytes[p + 4], shndx = bytes.readUInt16LE(p + 6), value = u64(p + 8), size = u64(p + 16);
      const owner = sections[shndx], version = versions.length ? bytes.readUInt16LE(versions[0].offset + index * 2) : 1;
      const executable = owner && owner.type !== 8 && (owner.flags & 6n) === 6n && value >= owner.address &&
        value - owner.address < owner.size && size <= owner.size - (value - owner.address) &&
        loads.some(row => (row.flags & 1) && value >= row.address && value - row.address < row.size &&
          size <= row.size - (value - row.address));
      rows.push({ name: symbolName, bind: info >> 4, type: info & 15, visibility: bytes[p + 5] & 3, shndx,
        value: '0x' + value.toString(16), nonzero: value !== 0, executable: Boolean(executable),
        versionIndex: version & 0x7fff, versionHidden: (version & 0x8000) !== 0 });
    }
    // 两个精确名字共用一个严格判据且必须都来自传入的唯一 GLFW 对象；不能拿只有
    // getter 的数据对象或无窗口函数的 DSO 充 provider，亦不能跨 DSO 补足缺失项。
    const symbols = {};
    for (const candidate of required) {
      const matches = rows.filter(row => row.name === candidate);
      if (matches.length !== 1) return fail(`expected one exact own dynsym definition of ${candidate}; got ${matches.length}`);
      const row = matches[0];
      if (row.bind !== 1 || row.type !== 2 || row.visibility !== 0 || row.shndx === 0 ||
          !row.nonzero || !row.executable || row.versionIndex === 0 || row.versionHidden)
        return fail(`${candidate} must be defined FUNC/GLOBAL/DEFAULT, nonzero own executable code and default symbol version`);
      symbols[candidate] = row;
    }
    return { issues: [], symbol: symbols[name], symbols, errorBound };
  } catch (error) { return fail(`invalid ELF dynamic-symbol evidence: ${error.message}`); }
}
export function evaluateDiagnosticHap(buffer, product, mode, requested = 'none') {
  const build = diagnosticProfile(product, mode, requested);
  const issues = [];
  const read = name => readUniqueZipEntry(buffer, name);
  const metadata = JSON.parse(read('resources/rawfile/product-profile.json'));
  const module = JSON.parse(read('module.json'));
  issues.push(...evaluateDiagnosticMetadata(metadata.build, build, product));
  if (metadata.name !== product || metadata.developerDiagnostics !== (product === 'default')) issues.push('diagnostic product identity mismatch');
  if (module.app.buildMode !== mode || module.app.debug !== (mode === 'debug')) issues.push('HAP compiler mode/debug identity mismatch');
  const entry = read('libs/arm64-v8a/libentry.so');
  const glfw = read('libs/arm64-v8a/libglfw.so');
  issues.push(...evaluateVmaProductionLog(read('libs/arm64-v8a/liblwjgl_vma.so')));
  issues.push(...evaluateInputTraceProducer(glfw, build.flags.AMCL_INPUT_TRACE === 'ON'));
  // WSI 是独立 DSO，其资源 trace 直接消费诊断 mask；不能借 entry/glfw 的身份替它证明。
  const wsi = read('libs/arm64-v8a/libamcl_vulkan_wsi.so');
  const marker = `AMCL_DIAGNOSTICS_V1:product=${product};mask=${build.mask};`;
  for (const [name, bytes] of [['entry', entry], ['glfw', glfw], ['vulkan-wsi', wsi]]) {
    if (!bytes.includes(Buffer.from(marker))) issues.push(`${name}: native diagnostic identity mismatch`);
  }
  const testNames = [...parseTestNapiNames(readFileSync(resolve(PRODUCT_ROOT, 'entry/src/main/cpp/napi/napi_tests.cpp'), 'utf8')), ...extraTestNames];
  if (!testNames.length) throw new Error('test symbol positive control missing');
  const tests = build.flags.MC_OHOS_BUILD_TESTS === 'ON';
  const jar = read('resources/rawfile/amcl-launcher.jar');
  const developer = productDefinition(product).developerDiagnostics;
  for (const name of ['mg_multidraw_bench_run', 'mg_multidraw_bench_progress', 'glfwAMCLMobileGluesBenchmarkRunV1']) {
    if (glfw.includes(Buffer.from(`${name}\0`)) !== developer) issues.push(`benchmark ABI ${name}: expected present=${developer}`);
  }
  if (readZipEntryNames(jar).some(name => /\/AmclAgentProbe(?:\$.*)?\.class$/.test(name)) !== developer) issues.push('Java agent probe product inclusion mismatch');
  const jarManifest = readUniqueZipEntry(jar, 'META-INF/MANIFEST.MF').toString();
  if (jarManifest.includes('Premain-Class:') !== developer) issues.push('Java agent manifest product mismatch');
  for (const name of testNames) {
    // NAPI property names are null-terminated; do not mistake C++ mangled names.
    if (entry.includes(Buffer.from(`${name}\0`)) !== tests) issues.push(`test NAPI ${name}: expected present=${tests}`);
  }
  if (readZipEntryNames(buffer).includes('libs/arm64-v8a/libfakejvm.so') !== tests) issues.push('fake JVM test image inclusion mismatch');
  for (const [text, flag] of [['[MG-FRAME-STATS]', 'AMCL_MG_FRAME_STATS'], ['[MG-UPLOAD-PROBE]', 'AMCL_MG_UPLOAD_PROBE']]) {
    if (glfw.includes(Buffer.from(text)) !== (build.flags[flag] === 'ON')) issues.push(`MG producer ${flag} inclusion mismatch`);
  }
  if (!developer) {
    const pages = read('resources/base/profile/main_pages.json').toString();
    const abc = read('ets/modules.abc');
    for (const name of ['DevToolsPage', 'InputProbePage', 'RenderPage', 'VulkanPage']) {
      if (pages.includes(name) || abc.includes(Buffer.from(`pages/${name}`))) issues.push(`production developer page remains: ${name}`);
    }
  }
  return issues;
}

export function auditDiagnosticBuild({ product, mode, requested = 'none', hap, hapKind, verifySignature = false }) {
  const build = diagnosticProfile(product, mode, requested);
  const buffer = readFileSync(hap);
  const nativeGlValidation = JSON.parse(readUniqueZipEntry(buffer, 'resources/rawfile/product-profile.json')).build?.nativeGlValidation === true;
  const issues = evaluateDiagnosticHap(buffer, product, mode, requested);
  // 正常 HAP 门无条件核唯一 GLFW 的导出；plain metadata fixture 不在这里获得 ELF 资格。
  // 签名是否核验、mask/tests 是否开启都不能跳过生产 getter 接缝。失败先报原始产物问题，
  // 再读宿主 CMake 状态会掩盖历史包真实的导出缺口，因此此项独立失败关闭。
  const diagnosticGetter = evaluateDiagnosticGetter(readUniqueZipEntry(buffer, 'libs/arm64-v8a/libglfw.so'));
  if (diagnosticGetter.issues.length) throw new Error(diagnosticGetter.issues.join('\n'));
  const cachePath = resolve(PRODUCT_ROOT, `entry/.cxx/${product}/${product}/${mode}/arm64-v8a/CMakeCache.txt`);
  const cacheBytes = readFileSync(cachePath);
  const cache = Object.fromEntries([...cacheBytes.toString().matchAll(/^([^#/:=\n]+):[^=\n]+=(.*)$/gm)].map(m => [m[1], m[2].trim()]));
  for (const [flag, expected] of Object.entries({ ...build.flags, AMCL_BUILD_PRODUCT: product,
    AMCL_DESKTOP_NATIVE_GL_VALIDATE: nativeGlValidation ? 'ON' : 'OFF',
    AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON', AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
    AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
    AMCL_INPUT_COMPILED_FORMAL_DESKTOP: product === 'desktop' ? 'ON' : 'OFF',
    AMCL_NATIVE_DESKTOP_ONLY: 'OFF',
    AMCL_API26_LINK_PROBE: 'OFF',
    AMCL_MG_UPLOAD_SCHEDULER_LAB: 'OFF', CMAKE_BUILD_TYPE: mode === 'debug' ? 'Debug' : 'Release' })) {
    if (cache[flag] !== expected) issues.push(`CMake ${flag}: expected ${expected}, got ${cache[flag]}`);
  }
  const native = {};
  for (const name of ['libentry.so', 'libglfw.so', 'libamcl_input_runtime.so', 'libamcl_vulkan_wsi.so']) {
    const staged = readFileSync(resolve(PRODUCT_ROOT, `entry/build/${product}/intermediates/stripped_native_libs/${product}/arm64-v8a/${name}`));
    const packed = readUniqueZipEntry(buffer, `libs/arm64-v8a/${name}`);
    if (hash(staged) !== hash(packed)) issues.push(`${name}: HAP does not contain current native image`);
    native[name] = hash(packed);
  }
  if (issues.length) throw new Error(issues.join('\n'));
  return { schema: 1, purpose: 'diagnostic-build-contract', product, ...build,
    nativeGlValidation, diagnosticGetter,
    releasable: false, // Release qualification remains the existing MG/source/APP audit.
    hapSha256: hash(buffer), cacheSha256: hash(cacheBytes), native,
    sourceHead: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: PRODUCT_ROOT, encoding: 'utf8' }).trim(),
    // 大型开发工作树可能超过 Node 默认的 1 MiB；完整读取后再散列，超出上限仍报错，不截断来源证据。
    sourceStatusSha256: hash(execFileSync('git', ['status', '--porcelain=v1', '--untracked-files=all'],
      { cwd: PRODUCT_ROOT, maxBuffer: 32 * 1024 * 1024 })),
    signature: verifySignature ? verifyHapSignature({ root: PRODUCT_ROOT, hapPath: resolve(hap), hapKind }) : null };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = (key, fallback) => { const i = process.argv.indexOf(`--${key}`); return i < 0 ? fallback : process.argv[i + 1]; };
  try {
    const report = auditDiagnosticBuild({ product: arg('product', 'default'), mode: arg('mode', 'debug'),
      requested: process.env.AMCL_DIAGNOSTICS ?? 'none', hap: arg('hap'), hapKind: arg('hap-kind', 'signed'),
      verifySignature: process.argv.includes('--verify-signature') });
    if (arg('verify-provenance') && JSON.stringify(JSON.parse(readFileSync(arg('verify-provenance')))) !== JSON.stringify(report)) throw new Error('diagnostic provenance no longer matches current evidence');
    if (arg('write-provenance')) writeFileSync(arg('write-provenance'), JSON.stringify(report, null, 2) + '\n');
    console.log(`[diagnostics-contract] PASS ${report.product}/${report.mode} mask=${report.mask}`);
  } catch (error) { console.error(`[diagnostics-contract] FAIL ${error.message}`); process.exitCode = 1; }
}

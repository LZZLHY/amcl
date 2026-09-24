import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { PRODUCT_ROOT, productDefinition } from './product-contract.mjs';
import { diagnosticProfile } from './diagnostic-profile.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { readZipEntryNames, parseTestNapiNames } from './check-release-no-test-symbols.mjs';
import { verifyHapSignature } from './check-mg-build-contract.mjs';

const hash = buffer => createHash('sha256').update(buffer).digest('hex');
export const extraTestNames = ['runVulkanSelfTest', 'runJvmEmbedTest', 'isJvmTestRunning', 'downloadEngineSelfTest', 'probeNativePath'];
export function evaluateDiagnosticMetadata(observed, expected, product) {
  const { nativeGlValidation = false, ...diagnostics } = observed ?? {};
  const issues = [];
  if (typeof nativeGlValidation !== 'boolean' || (nativeGlValidation && product !== 'desktop')) issues.push('invalid native GL validation identity');
  if (JSON.stringify(diagnostics) !== JSON.stringify(expected)) issues.push('diagnostic metadata drift');
  return issues;
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
  for (const name of ['libentry.so', 'libglfw.so', 'libamcl_vulkan_wsi.so']) {
    const staged = readFileSync(resolve(PRODUCT_ROOT, `entry/build/${product}/intermediates/stripped_native_libs/${product}/arm64-v8a/${name}`));
    const packed = readUniqueZipEntry(buffer, `libs/arm64-v8a/${name}`);
    if (hash(staged) !== hash(packed)) issues.push(`${name}: HAP does not contain current native image`);
    native[name] = hash(packed);
  }
  if (issues.length) throw new Error(issues.join('\n'));
  return { schema: 1, purpose: 'diagnostic-build-contract', product, ...build,
    nativeGlValidation,
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

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readElfIdentity } from './check-mg-build-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { assertExternalOutputPath, workspacePath } from './lib/workspace-paths.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const wsiExports = ['vkGetInstanceProcAddr', 'amclVulkanSetAdmission', 'amclVulkanAdmissionGranted',
  'vkGetDeviceProcAddr', 'amclVulkanCreateSurface', 'amclVulkanWindowHasLiveSurface',
  'amclVulkanGetStats', 'amclVulkanGetDeviceProcAddr'];
const glfwExports = ['glfwInitVulkanLoader', 'glfwVulkanSupported', 'glfwGetRequiredInstanceExtensions',
  'glfwGetInstanceProcAddress', 'glfwGetPhysicalDevicePresentationSupport', 'glfwCreateWindowSurface',
  'glfwOHOS_BindGraphicsRuntimeV1', 'glfwOHOS_GraphicsGlProcV1', 'glfwOHOS_GraphicsEglProcV1',
  'glfwOHOS_PublishGraphicsObserverV1', 'glfwOHOS_GraphicsRuntimeJsonV1', 'glfwOHOS_GraphicsFailureJsonV1'];
const windowExports = ['amclWindowHostPublish', 'amclWindowHostUpdateSize', 'amclWindowHostClear',
  'amclWindowHostReadSnapshot', 'amclWindowHostGetBroker', 'amclWindowHostAcquire',
  'amclWindowHostRelease', 'amclWindowHostGetStats'];
const glHostExports = ['glGetString', 'eglGetProcAddress', 'glXGetProcAddress', 'glXGetProcAddressARB',
  'amclGlHostInitializeV1', 'amclGlHostGetInitReportV1', 'amclGlHostGetProcAddressV1', 'amclGlHostGetEglProcAddressV1',
  'amclGlHostSourceIdentityV1'];
const runtimeExports = ['amclGraphicsBindRuntimeV1', 'amclGraphicsGlProcV1', 'amclGraphicsEglProcV1',
  'amclGraphicsReadPresentSequenceV1', 'amclGraphicsDispatchPresentV1', 'amclGraphicsRegisterPresentSinkV1',
  'amclGraphicsBoundProfileV1', 'amclGraphicsBoundApiV1', 'amclGraphicsRuntimeOwnerV1',
  'amclGraphicsPublishObserverV1', 'amclGraphicsPresentedV1', 'amclGraphicsSwapV1',
  'amclGraphicsFatalV1', 'amclGraphicsForegroundV1', 'amclGraphicsRuntimeJsonV1', 'amclGraphicsFailureJsonV1', 'amclGraphicsObservationEnabledV1', 'amclGraphicsInspectContextV1', 'glXGetProcAddress', 'glXGetProcAddressARB'];

export function graphicsRuntimeIssues(images, options = {}) {
  const issues = [];
  const wsi = images['libamcl_vulkan_wsi.so'];
  const glfw = images['libglfw.so'];
  const entry = images['libentry.so'];
  const windowHost = images['libamcl_window_host.so'];
  const glHost = images['libamcl_gl_host.so'];
  const runtime = images['libamcl_graphics_runtime.so'];
  // 宿主的MobileGL路径依赖真实呈现序列。检查动态导出表，不能用.rodata里同名字串代替。
  const mobilegl = images['libmobilegl.so'];
  if (!mobilegl || mobilegl.machine !== 183 || !mobilegl.exports.includes('mobileglGetPresentedSequenceV1'))
    issues.push('MobileGL missing actual-presentation evidence ABI');
  const requiredImages = { 'libamcl_vulkan_wsi.so': wsi, 'libamcl_window_host.so': windowHost,
    'libamcl_gl_host.so': glHost, 'libamcl_graphics_runtime.so': runtime, 'libglfw.so': glfw, 'libentry.so': entry };
  for (const [name, image] of Object.entries(requiredImages)) {
    if (!image) { issues.push(`${name}: missing HAP member`); continue; }
    if (image.soname !== name || image.machine !== 183) issues.push(`${name}: wrong SONAME or architecture`);
    if (!image.runpath?.includes('$ORIGIN')) issues.push(`${name}: missing installed sibling RUNPATH`);
    if (image.runpath?.some(value => /[A-Za-z]:[\\/]/.test(value))) issues.push(`${name}: host build directory in RUNPATH`);
  }
  if (!wsi || !windowHost || !glfw || !entry) return issues;
  if (!glHost || !runtime) return issues;
  // 这些库都在游戏provider选定前进入依赖闭包。即使dlopen使用RTLD_LOCAL，闭包内
  // 的系统/UI EGL符号仍可能先解析到本方；不能只检查DT_NEEDED“不链接EGL”便放行。
  // 真正翻译器由绑定器按需装入，允许它在自己的DSO中导出所属EGL实现。
  for (const [name, image] of [['Runtime', runtime], ['entry', entry], ['WindowHost', windowHost]]) {
    for (const symbol of image.exports) {
      if (/^egl[A-Z]/.test(symbol)) issues.push(`${name}: startup EGL provider export ${symbol}`);
    }
  }
  // 公共运行时只依赖窗口broker和系统支持库；导出实现不得重复落入GLFW或entry。
  for (const symbol of runtimeExports) {
    if (!runtime.exports.includes(symbol)) issues.push(`Runtime missing public ABI ${symbol}`);
    if (glfw.exports.includes(symbol) || entry.exports.includes(symbol)) issues.push(`Runtime implementation duplicated outside its DSO: ${symbol}`);
  }
  for (const library of runtime.needed) {
    if (/glfw|libentry|SDL|EGL|GLES|mobilegl|gl_host|GLv4/i.test(library)) issues.push(`Runtime has frontend/translator dependency ${library}`);
  }
  if (!runtime.needed.includes('libamcl_window_host.so')) issues.push('Runtime: missing WindowHost dependency');
  for (const symbol of wsiExports) if (!wsi.exports.includes(symbol)) issues.push(`WSI missing definition ${symbol}`);
  for (const symbol of windowExports) if (!windowHost.exports.includes(symbol)) issues.push(`WindowHost missing definition ${symbol}`);
  if (glHost) for (const symbol of glHostExports) if (!glHost.exports.includes(symbol)) issues.push(`GL host missing definition ${symbol}`);
  for (const symbol of glfwExports) if (!glfw.exports.includes(symbol)) issues.push(`GLFW missing facade ${symbol}`);
  for (const library of wsi.needed) {
    if (/glfw|libentry|SDL|EGL|GLES|mobilegl|GLv4/i.test(library)) issues.push(`WSI has renderer dependency ${library}`);
  }
  for (const library of windowHost.needed) {
    if (/glfw|SDL|EGL|GLES|mobilegl|GLv4/i.test(library)) issues.push(`WindowHost has renderer dependency ${library}`);
  }
  if (glHost) for (const library of glHost.needed) {
    if (/glfw|SDL|EGL|GLES|mobilegl|GLv4/i.test(library)) issues.push(`GL host has renderer dependency ${library}`);
  }
  if (glHost && (glHost.undefined ?? []).some(symbol => /(?:^|\b)(?:egl|gl)[A-Z]/.test(symbol))) {
    issues.push('GL host has undefined GL/EGL provider symbols');
  }
  for (const symbol of wsi.exports) {
    if (/^(?:glfw|egl|gl[A-Z]|mg_)/.test(symbol)) issues.push(`WSI contains GL/window facade ${symbol}`);
  }
  for (const [name, image] of [['GLFW', glfw], ['entry', entry]]) {
    if (!image.needed.includes('libamcl_vulkan_wsi.so')) issues.push(`${name}: missing physical WSI dependency`);
    if (!image.needed.includes('libamcl_window_host.so')) issues.push(`${name}: missing physical WindowHost dependency`);
    if (!image.needed.includes('libamcl_graphics_runtime.so')) issues.push(`${name}: missing neutral runtime dependency`);
    // 翻译器已改为按已选计划动态绑定，仍须在包中，但不得成为窗口/入口库的强制装载依赖。
    if (image.needed.includes('libamcl_gl_host.so') || image.needed.includes('libmobilegl.so')) {
      issues.push(`${name}: eager translator dependency bypasses runtime binding`);
    }
  }
  for (const symbol of glfw.exports) {
    if (/^(?:gl[A-Z]|egl[A-Z]|glXGetProcAddress)/.test(symbol)) {
      issues.push(`GLFW duplicates GL/EGL provider export ${symbol}`);
    }
  }
  for (const symbol of wsiExports) {
    if (glfw.exports.includes(symbol)) issues.push(`WSI implementation duplicated in GLFW: ${symbol}`);
  }
  return issues;
}

export function auditGraphicsRuntime(hap, evidenceDir) {
  // 库调用与 CLI 使用同一边界，避免历史调用者通过导出函数重新创建仓内解包树。
  evidenceDir = assertExternalOutputPath(evidenceDir);
  const archive = fs.readFileSync(hap);
  fs.mkdirSync(evidenceDir, { recursive: true });
  const llvm = process.env.AMCL_LLVM_BIN || 'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin';
  const executable = name => path.join(llvm, name + (process.platform === 'win32' ? '.exe' : ''));
  const product = process.argv.includes('--product') ? process.argv[process.argv.indexOf('--product') + 1] : '';
  const images = {};
  const imageNames = ['libamcl_vulkan_wsi.so', 'libamcl_window_host.so', 'libamcl_gl_host.so', 'libamcl_graphics_runtime.so', 'libglfw.so', 'libentry.so', 'libmobilegl.so'];
  for (const name of imageNames) {
    const bytes = readUniqueZipEntry(archive, `libs/arm64-v8a/${name}`);
    const file = path.join(evidenceDir, name);
    fs.writeFileSync(file, bytes);
    const dynamic = execFileSync(executable('llvm-readelf'), ['-d', file], { encoding: 'utf8' });
    const symbols = execFileSync(executable('llvm-nm'), ['--dynamic', '--defined-only', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    const undefinedSymbols = execFileSync(executable('llvm-nm'), ['--dynamic', '--undefined-only', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    images[name] = { ...readElfIdentity(bytes), size: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      needed: [...dynamic.matchAll(/\(NEEDED\).*?\[([^\]]+)\]/g)].map(m => m[1]),
      runpath: [...dynamic.matchAll(/\((?:RUNPATH|RPATH)\).*?\[([^\]]+)\]/g)].map(m => m[1]),
      exports: symbols.split(/\r?\n/).filter(line => /\s[TW]\s/.test(line))
        .map(line => line.trim().split(/\s+/).pop()?.split('@')[0]).filter(Boolean),
      undefined: undefinedSymbols.split(/\r?\n/).map(line => line.trim().split(/\s+/).pop()?.split('@')[0]).filter(Boolean) };
  }
  const issues = graphicsRuntimeIssues(images, { product });
  const report = { schema: 1, capturedAt: new Date().toISOString(), hap: path.resolve(hap),
    hapSha256: createHash('sha256').update(archive).digest('hex'), images, issues,
    verdict: issues.length ? 'FAIL' : 'PASS', scope: 'HAP physical linkage and exports; no game rendering verdict' };
  fs.writeFileSync(path.join(evidenceDir, 'graphics-runtime.json'), JSON.stringify(report, null, 2) + '\n');
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = flag => { const at = process.argv.indexOf(flag); return at < 0 ? '' : process.argv[at + 1]; };
  try {
    if (!arg('--hap')) throw new Error('--hap is required; no source-only fallback');
    // 解包和产物审计只写外部会话；显式 --out 也不能重新创建仓内临时目录。
    const report = auditGraphicsRuntime(path.resolve(arg('--hap')), assertExternalOutputPath(arg('--out') || workspacePath('run', 'graphics-artifact')));
    console.log(`graphics-runtime-artifact ${report.verdict}: physical WSI DSO, loader exports, GLFW/entry dependency closure`);
    if (report.issues.length) { console.error(report.issues.join('\n')); process.exitCode = 1; }
  } catch (error) { console.error(error.message); process.exitCode = 2; }
}

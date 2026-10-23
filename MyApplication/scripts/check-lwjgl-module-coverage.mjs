#!/usr/bin/env node
/**
 * 检查实际随包 LWJGL JAR 的模块配套及全部必需 C API。
 * 固定 Minecraft manifest 只能说明原版启动需求，本门覆盖 modern manifest 的每个
 * JAR（包括模组使用的额外模块）。JNI 的完整入口交给 native-surface；C API 从
 * 锁定生成源码的 apiGetFunctionAddress 提取，Optional/GPU/音频过程表不作静态导出。
 * 源码模式验证预编译库与构建接线；--hap 模式读取刚生成的包，验证 CMake 产物。
 */
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { basename, dirname, join, relative, resolve, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { stripComments } from './lib/source-noise.mjs';
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { assertPinnedLwjglSource, locateReadelf, runNativeSurfaceCheck } from './check-lwjgl-native-surface.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const KINDS = new Set(['jni', 'c-api', 'system-dispatch', 'bridge']);

/**
 * 锁定绑定源码和 AMCL 装载接线已经成立的提供方事实，不能由 policy 的自报类别改写。
 * policy 负责说明支持范围，本表负责保证门禁不会因重分类、改库名或删源码范围而缩减。
 * 新增实际模块必须先确认其绑定形态再扩本表；C API 的完整扫描范围不接受自选锚点替代。
 */
const VERIFIED_BINDINGS = new Map([
  ['lwjgl.jar', { module: 'core', kind: 'jni', artifact: 'liblwjgl.so' }],
  ['lwjgl-egl.jar', { module: 'egl', kind: 'bridge', artifact: 'libamcl_lwjgl_egl.so', stage: 'cmake', requiredSymbols: ['eglGetProcAddress'] }],
  ['lwjgl-freetype.jar', { module: 'freetype', kind: 'c-api', artifact: 'libfreetype.so', requiredSource: 'all-generated' }],
  ['lwjgl-glfw.jar', { module: 'glfw', kind: 'bridge', artifact: 'libglfw.so', stage: 'cmake', requiredSource: ['GLFW.java', 'GLFWNativeEGL.java', 'GLFWVulkan.java'] }],
  ['lwjgl-nanovg.jar', { module: 'nanovg', kind: 'jni', artifact: 'liblwjgl_nanovg.so' }],
  ['lwjgl-openal.jar', { module: 'openal', kind: 'system-dispatch', artifact: 'libopenal.so', stage: 'cmake', requiredSymbols: ['alGetProcAddress', 'alcGetProcAddress', 'alcOpenDevice'] }],
  ['lwjgl-opengl.jar', { module: 'opengl', kind: 'jni', artifact: 'liblwjgl_opengl.so' }],
  ['lwjgl-opengles.jar', { module: 'opengles', kind: 'jni', artifact: 'liblwjgl_opengles.so' }],
  ['lwjgl-sdl.jar', { module: 'sdl', kind: 'c-api', artifact: 'libSDL3.so', requiredSource: 'all-generated' }],
  ['lwjgl-shaderc.jar', { module: 'shaderc', kind: 'c-api', artifact: 'libshaderc.so', requiredSource: 'all-generated' }],
  ['lwjgl-spng.jar', { module: 'spng', kind: 'jni', artifact: 'liblwjgl_spng.so' }],
  ['lwjgl-spvc.jar', { module: 'spvc', kind: 'c-api', artifact: 'libspirv-cross.so', requiredSource: 'all-generated' }],
  ['lwjgl-stb.jar', { module: 'stb', kind: 'jni', artifact: 'liblwjgl_stb.so' }],
  ['lwjgl-tinyfd.jar', { module: 'tinyfd', kind: 'jni', artifact: 'liblwjgl_tinyfd.so' }],
  ['lwjgl-vma.jar', { module: 'vma', kind: 'jni', artifact: 'liblwjgl_vma.so' }],
  // VK.java 首先按 org.lwjgl.vulkan.libname 装载 AMCL WSI shim；系统 libvulkan
  // 是 shim 的下游，不能以“系统能力”分类跳过本包的第一提供方和 bootstrap 入口。
  ['lwjgl-vulkan.jar', { module: 'vulkan', kind: 'bridge', artifact: 'libamcl_vulkan_wsi.so', stage: 'cmake', requiredSymbols: ['vkGetInstanceProcAddr'] }],
]);

/** 遍历锁定生成目录。排序使报错和收据不依赖文件系统枚举顺序。 */
function javaFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? javaFiles(path) : entry.name.endsWith('.java') ? [path] : [];
  }).sort();
}

/**
 * apiGetFunctionAddress 必须成功，Optional 则允许返回 0。只读完整调用的第二个
 * 字符串参数；支持 SDL.getLibrary() 这样的第一参数，剥注释避免文档伪造入口。
 * 上游若修改生成形式而使调用无法解析，明确失败，不能悄悄缩小必需函数集合。
 */
export function requiredFunctionsFromJava(input) {
  const text = stripComments(input, { lang: 'c' });
  const calls = [...text.matchAll(/\bapiGetFunctionAddress\s*\(/g)];
  const values = [...text.matchAll(/\bapiGetFunctionAddress\s*\((?:[^()";]|\([^()]*\))*?,\s*"([A-Za-z_][A-Za-z_0-9]*)"\s*\)/g)]
    .map((match) => match[1]);
  if (calls.length !== values.length) throw new Error('unrecognized required apiGetFunctionAddress invocation');
  return [...new Set(values)].sort();
}

/** 只有已定义、可外部查询的动态函数才能满足 dlsym；UND/LOCAL/HIDDEN 均不能算。 */
export function definedFunctionExports(symbolText) {
  return new Set([...symbolText.matchAll(/\b(?:FUNC|IFUNC)\s+(?:GLOBAL|WEAK)\s+(?:DEFAULT|PROTECTED)\s+(?!UND\b)\S+\s+(\S+)/g)]
    .map((match) => match[1].split('@')[0]));
}

/**
 * 所有提供方都必须是 OHOS 所需的 AArch64 ELF DSO。EGL 桥的依赖方向额外收紧：
 * 它只公开地址查询，不能因 DT_NEEDED 提前加载 entry/GLFW/runtime 或系统 EGL，
 * 否则 late-load 会退化成加载时选择后端，破坏当前会话的 owner 与 profile 决议。
 */
export function validateModuleElf(artifact, text) {
  const problems = [];
  if (!/Class:\s+ELF64/.test(text) || !/Machine:\s+AArch64/.test(text) || !/Type:\s+DYN/.test(text)) {
    problems.push(`${artifact}: expected ELF64 AArch64 shared object`);
  }
  const exported = definedFunctionExports(text);
  if (artifact === 'libamcl_lwjgl_egl.so') {
    const needed = [...text.matchAll(/Shared library: \[([^\]]+)\]/g)].map((match) => match[1]);
    // C++ 共享服务 ABI 使用编译器运行库；只允许平台 C/C++/dl，绝不放行图形提供方。
    const badNeeded = needed.filter((name) => !['libc.so', 'libc++_shared.so', 'libdl.so'].includes(name));
    if (badNeeded.length) problems.push(`${artifact}: late-load bridge has forbidden NEEDED ${badNeeded.join(',')}`);
    const extra = [...exported].filter((name) => name !== 'eglGetProcAddress');
    if (extra.length) problems.push(`${artifact}: bridge must export only eglGetProcAddress, extra=${extra.join(',')}`);
    if (!exported.has('eglGetProcAddress')) problems.push(`${artifact}: bridge must define eglGetProcAddress`);
  }
  return { problems, exported };
}

/**
 * 一份清单只能包含实际 JAR，新增 JAR 不允许漏分类；每个条目说明其真实提供形态。
 * C API 统一扫描整个 generated 树，禁止把 shaderc 缩成 Shaderc.java 的少量锚点。
 */
export function validateModulePolicy(policy, manifest) {
  const problems = [];
  if (policy?.schema !== 1 || policy?.slot !== 'modern' || !Array.isArray(policy?.modules)) {
    return ['unsupported LWJGL module coverage policy'];
  }
  const expected = (manifest?.jars || []).map((item) => item.name).sort();
  const actual = policy.modules.map((item) => item.jar).sort();
  if (expected.join('|') !== actual.join('|') || new Set(actual).size !== actual.length) {
    problems.push(`module policy must classify every actual modern JAR exactly once: expected=${expected.join(',')} actual=${actual.join(',')}`);
  }
  const manifestNatives = (manifest?.natives || []).map((native) => native.name).sort();
  const jniProviders = policy.modules.filter((entry) => entry.kind === 'jni').map((entry) => entry.artifact).sort();
  if (manifestNatives.join('|') !== jniProviders.join('|')) {
    problems.push('every modern native manifest entry must have exactly one owning JNI module');
  }
  for (const entry of policy.modules) {
    const binding = VERIFIED_BINDINGS.get(entry.jar);
    if (!binding) problems.push(`${String(entry.jar)}: no verified binding/provider contract`);
    else {
      // 这些字段改变会影响真实检查路径，必须与已核实绑定一致。尤其 stage 不能把
      // 预编译 C API 伪装成 CMake 尚未生成的库，systemLibrary 不能绕过随包提供方检查。
      for (const key of ['module', 'kind', 'artifact', 'systemLibrary', 'stage']) {
        if (entry[key] !== binding[key]) problems.push(`${entry.jar}: verified ${key} must be ${String(binding[key])}`);
      }
      if (Array.isArray(binding.requiredSource)) {
        if (!Array.isArray(entry.requiredSource) ||
            [...entry.requiredSource].sort().join('|') !== [...binding.requiredSource].sort().join('|')) {
          problems.push(`${entry.jar}: requiredSource must preserve all verified binding files`);
        }
      } else if (entry.requiredSource !== binding.requiredSource) {
        problems.push(`${entry.jar}: requiredSource must be ${String(binding.requiredSource)}`);
      }
      if (binding.requiredSymbols) {
        if (!Array.isArray(entry.requiredSymbols) ||
            !binding.requiredSymbols.every((name) => entry.requiredSymbols.includes(name))) {
          problems.push(`${entry.jar}: requiredSymbols must preserve verified bootstrap functions ${binding.requiredSymbols.join(',')}`);
        }
      }
    }
    if (!/^[a-z0-9-]+\.jar$/.test(entry.jar || '') || !/^[a-z0-9]+$/.test(entry.module || '') || !KINDS.has(entry.kind)) {
      problems.push(`${String(entry.jar)}: invalid module classification`);
    }
    if (!entry.scope || typeof entry.scope !== 'string') problems.push(`${entry.jar}: missing support scope`);
    if (entry.artifact && !/^lib[A-Za-z0-9_-]+\.so$/.test(entry.artifact)) problems.push(`${entry.jar}: invalid provider name`);
    if (!entry.artifact && !entry.systemLibrary) problems.push(`${entry.jar}: missing native/system provider`);
    if (entry.kind === 'jni' && !(manifest?.natives || []).some((native) => native.name === entry.artifact)) {
      problems.push(`${entry.jar}: JNI provider ${entry.artifact} is absent from modern native manifest`);
    }
    if (entry.kind === 'c-api' && entry.requiredSource !== 'all-generated') {
      problems.push(`${entry.jar}: C API must inspect all-generated bindings`);
    }
    if (entry.kind === 'system-dispatch' && !entry.scope.includes('查询') && !entry.scope.includes('取得')) {
      problems.push(`${entry.jar}: dynamic-dispatch scope must explain provider lookup`);
    }
  }
  return problems;
}

/** 单库校验可供负控制注入导出集合；不接受其他库同名函数替代默认提供方。 */
export function verifyRequiredFunctions(label, required, actual) {
  const missing = [...new Set(required)].filter((name) => !actual.has(name)).sort();
  return missing.length ? [`${label}: missing required defined exports (${missing.length}): ${missing.join(',')}`] : [];
}

/**
 * 从实际 JAR 对应的完整生成源码取得必需项，并确认 Functions.class 确实引用这些
 * 字符串。这样源码/JAR 版本错配或删掉绑定类会失败，不能仅凭源码声称支持。
 */
export function collectModuleRequirements(root, entry, jarBytes) {
  const required = new Set(entry.requiredSymbols || []);
  if (!entry.requiredSource) return [...required].sort();
  const generated = join(root, 'prebuilt', 'lwjgl3', 'lwjgl3_src', 'modules', 'lwjgl', entry.module, 'src', 'generated', 'java');
  const files = javaFiles(generated).filter((path) => entry.requiredSource === 'all-generated' || entry.requiredSource.includes(basename(path)));
  if (!files.length) throw new Error(`${entry.jar}: required generated Java sources are missing`);
  for (const path of files) {
    const text = readFileSync(path, 'utf8');
    const functions = requiredFunctionsFromJava(text);
    if (!functions.length) continue;
    const className = relative(generated, path).replaceAll('\\', '/').replace(/\.java$/, '$Functions.class');
    const classBytes = readUniqueZipEntry(jarBytes, className);
    for (const name of functions) {
      if (!classBytes.includes(Buffer.from(name, 'utf8'))) throw new Error(`${entry.jar}: actual ${className} does not reference ${name}`);
      required.add(name);
    }
  }
  if (!required.size) throw new Error(`${entry.jar}: empty required-function collection`);
  return [...required].sort();
}

/**
 * 同时支持工作树与最终 HAP。CMake 库在源码模式尚未生成，只确认其构建产物契约，
 * 最终 HAP 模式必须读取 ELF 和全部必需导出。每次解析只信本次目录/包的同名提供方。
 */
export function checkModuleCoverage({ root = ROOT, policy, manifest, hapBytes, inspectExports } = {}) {
  policy ??= JSON.parse(readFileSync(join(root, 'prebuilt/lwjgl3/module-coverage.policy.json'), 'utf8'));
  manifest ??= JSON.parse(readFileSync(join(root, 'prebuilt/lwjgl3/modern-slot.manifest.json'), 'utf8'));
  const problems = validateModulePolicy(policy, manifest);
  const modules = [];
  if (problems.length) return { ok: false, problems, modules };
  // ELF 导出注入属于内存夹具边界。所有真实 source/HAP 入口必须取得锁定 Git 身份，
  // 防止修改工作树生成源码以后，既缩减扫描集合又把同一次检查当作完整覆盖证明。
  if (!inspectExports) {
    try { assertPinnedLwjglSource({ root, manifest }); }
    catch (error) { return { ok: false, problems: [...problems, error.message], modules }; }
  }
  let scratch = '';
  let readelf = '';
  const cache = new Map();
  try {
    if (!inspectExports) readelf = locateReadelf();
    if (hapBytes && !inspectExports) scratch = mkdtempSync(join(workspaceTempRoot(), 'amcl-lwjgl-modules-'));
    const exportsOf = (entry) => {
      if (cache.has(entry.artifact)) return cache.get(entry.artifact);
      let bytes;
      let path = join(root, 'entry/libs/arm64-v8a', entry.artifact);
      if (hapBytes) {
        bytes = readUniqueZipEntry(hapBytes, `libs/arm64-v8a/${entry.artifact}`);
        if (scratch) { path = join(scratch, entry.artifact); writeFileSync(path, bytes); }
      }
      let exported;
      if (inspectExports) exported = inspectExports(entry.artifact, bytes);
      else {
        const inspection = validateModuleElf(entry.artifact,
          execFileSync(readelf, ['--file-header', '--dynamic', '--dyn-syms', '--wide', path], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
        problems.push(...inspection.problems);
        exported = inspection.exported;
      }
      cache.set(entry.artifact, exported);
      return exported;
    };
    for (const entry of policy.modules) {
      try {
        const jarBytes = hapBytes ? readUniqueZipEntry(hapBytes, `resources/rawfile/lwjgl/${entry.jar}`) :
          readFileSync(join(root, 'prebuilt/lwjgl3/jars', entry.jar));
        const required = collectModuleRequirements(root, entry, jarBytes);
        if (entry.systemLibrary) {
          // 系统 Vulkan 不随应用重打包；能力查询在设备上执行，源码/包门不伪造设备能力。
          modules.push({ jar: entry.jar, kind: entry.kind, systemLibrary: entry.systemLibrary, required: 0 });
          continue;
        }
        if (entry.stage === 'cmake' && !hapBytes) {
          modules.push({ jar: entry.jar, kind: entry.kind, artifact: entry.artifact, required: required.length, pending: 'final-HAP-export-check' });
          continue;
        }
        // JNI 的完整集合由 native-surface 从同一锁定 C 源验证，仍读取库以确保配套存在。
        const actual = exportsOf(entry);
        problems.push(...verifyRequiredFunctions(entry.jar, required, actual));
        modules.push({ jar: entry.jar, kind: entry.kind, artifact: entry.artifact, required: required.length, exports: actual.size });
      } catch (error) {
        problems.push(`${entry.jar}: ${error.message}`);
      }
    }
  } catch (error) {
    problems.push(error.message);
  } finally {
    if (scratch) {
      const base = resolve(workspaceTempRoot());
      const rel = relative(base, resolve(scratch));
      if (!rel || rel === '..' || rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(rel)) {
        problems.push(`refusing unsafe module scratch removal: ${scratch}`);
      } else rmSync(scratch, { recursive: true, force: true });
    }
  }
  return { ok: problems.length === 0, problems, modules };
}

/** 正常入口输出可审查的每模块计数；错误明确阻断构建，不产生“部分成功”退出码。 */
export function runModuleCoverageCheck(options = {}) {
  const result = checkModuleCoverage(options);
  for (const entry of result.modules) console.log(`[lwjgl-module-coverage] ${entry.jar}: ${entry.kind} ${entry.artifact || entry.systemLibrary}, required=${entry.required}${entry.pending ? ', final-HAP deferred' : ''}`);
  if (!result.ok) throw new Error(result.problems.join('\n'));
  console.log(`[lwjgl-module-coverage] OK: ${result.modules.length} actual JARs classified${options.hapBytes ? ', final HAP providers verified' : ''}`);
  return result;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const index = process.argv.indexOf('--hap');
  if (index >= 0 && !process.argv[index + 1]) throw new Error('--hap requires the selected HAP');
  const hapBytes = index >= 0 ? readFileSync(resolve(process.argv[index + 1])) : undefined;
  runModuleCoverageCheck({ hapBytes });
  if (!hapBytes) runNativeSurfaceCheck({ output: join(ROOT, 'entry/libs/arm64-v8a') });
}

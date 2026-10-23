#!/usr/bin/env node
/**
 * 模块配套门禁的正负控制。先用当前真实 JAR 与 ELF 取得正控，再在内存中删除提供方、
 * 旁支函数或改变 ELF 身份；不改工程制品、不初始化 JVM，也不伪称设备渲染已验证。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  checkModuleCoverage, collectModuleRequirements, definedFunctionExports,
  requiredFunctionsFromJava, validateModuleElf, validateModulePolicy, verifyRequiredFunctions,
} from './check-lwjgl-module-coverage.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const policy = JSON.parse(readFileSync(join(root, 'prebuilt/lwjgl3/module-coverage.policy.json'), 'utf8'));
const manifest = JSON.parse(readFileSync(join(root, 'prebuilt/lwjgl3/modern-slot.manifest.json'), 'utf8'));

// 词法正反例：Optional 不会导致误报，注释中的假入口也不能改变覆盖集合。
assert.deepEqual(requiredFunctionsFromJava(`
  // apiGetFunctionAddress(X, "not_real")
  long required = apiGetFunctionAddress(SDL.getLibrary(), "SDL_Init");
  long optional = apiGetFunctionAddressOptional(SDL.getLibrary(), "SDL_Optional");
`), ['SDL_Init']);
assert.throws(() => requiredFunctionsFromJava('apiGetFunctionAddress(lib, variable)'), /unrecognized/);
const elfHeader = 'Class: ELF64\nType: DYN (Shared object file)\nMachine: AArch64\n';
const defined = '  1: 00000000 4 FUNC GLOBAL DEFAULT 12 required\n';
const unusable = '  2: 00000000 0 FUNC GLOBAL DEFAULT UND undefined\n' +
  '  3: 00000000 4 FUNC LOCAL DEFAULT 12 private\n' +
  '  4: 00000000 4 FUNC GLOBAL HIDDEN 12 hidden\n';
assert.deepEqual([...definedFunctionExports(defined + unusable)], ['required']);
assert.match(verifyRequiredFunctions('fixture', ['undefined'], definedFunctionExports(defined + unusable))[0], /undefined/);
assert.equal(validateModuleElf('fixture.so', elfHeader + defined).problems.length, 0);
assert.match(validateModuleElf('fixture.so', elfHeader.replace('AArch64', 'X86-64') + defined).problems[0], /AArch64/);
const bridgeElf = elfHeader + defined.replace('required', 'eglGetProcAddress') + 'Shared library: [libc.so]\nShared library: [libc++_shared.so]\n';
assert.deepEqual(validateModuleElf('libamcl_lwjgl_egl.so', bridgeElf).problems, []);
assert.match(validateModuleElf('libamcl_lwjgl_egl.so', bridgeElf + 'Shared library: [libEGL.so]\n').problems.join(), /forbidden NEEDED/);
assert.match(validateModuleElf('libamcl_lwjgl_egl.so', bridgeElf + defined).problems.join(), /must export only/);
assert.match(validateModuleElf('libamcl_lwjgl_egl.so', elfHeader).problems.join(), /must define eglGetProcAddress/);

assert.deepEqual(validateModulePolicy(policy, manifest), []);
const missingModule = structuredClone(policy);
missingModule.modules = missingModule.modules.filter((entry) => entry.module !== 'opengles');
assert.match(validateModulePolicy(missingModule, manifest).join(), /every actual modern JAR/);
const unknownJar = structuredClone(manifest);
unknownJar.jars.push({ name: 'lwjgl-new-module.jar' });
assert.match(validateModulePolicy(policy, unknownJar).join(), /every actual modern JAR/);
const narrowed = structuredClone(policy);
narrowed.modules.find((entry) => entry.module === 'shaderc').requiredSource = ['Shaderc.java'];
assert.match(validateModulePolicy(narrowed, manifest).join(), /all-generated/);
// policy 是范围说明而不是降低检查强度的开关：跨 kind、自选少量符号、改提供库和
// stage 均不能把四个完整 C API 的检查缩成几个锚点或推迟到不存在的 CMake 阶段。
for (const module of ['shaderc', 'freetype', 'sdl', 'spvc']) {
  const crossKind = structuredClone(policy);
  const reclassified = crossKind.modules.find((entry) => entry.module === module);
  reclassified.kind = 'bridge'; reclassified.requiredSource = ['Shaderc.java'];
  assert.match(validateModulePolicy(crossKind, manifest).join(), /verified kind/, `${module} 跨类别拒绝`);
  assert.equal(checkModuleCoverage({ root, policy: crossKind, manifest }).ok, false, `${module} 真实门拒绝缩减`);
  const selectedSymbols = structuredClone(policy);
  const anchorOnly = selectedSymbols.modules.find((entry) => entry.module === module);
  delete anchorOnly.requiredSource; anchorOnly.requiredSymbols = ['selected_anchor'];
  assert.match(validateModulePolicy(selectedSymbols, manifest).join(), /requiredSource/, `${module} 自选锚点拒绝`);
  const wrongProvider = structuredClone(policy);
  wrongProvider.modules.find((entry) => entry.module === module).artifact = 'liblwjgl.so';
  assert.match(validateModulePolicy(wrongProvider, manifest).join(), /verified artifact/, `${module} 改默认提供方拒绝`);
  const deferred = structuredClone(policy);
  deferred.modules.find((entry) => entry.module === module).stage = 'cmake';
  assert.match(validateModulePolicy(deferred, manifest).join(), /verified stage/, `${module} 伪造延迟检查拒绝`);
}
for (const removed of ['GLFW.java', 'GLFWNativeEGL.java', 'GLFWVulkan.java']) {
  const reducedGlfw = structuredClone(policy);
  const glfw = reducedGlfw.modules.find((entry) => entry.module === 'glfw');
  glfw.requiredSource = glfw.requiredSource.filter((name) => name !== removed);
  assert.match(validateModulePolicy(reducedGlfw, manifest).join(), /preserve all verified binding files/, removed);
}
for (const module of ['egl', 'openal', 'vulkan']) {
  const emptyBootstrap = structuredClone(policy);
  emptyBootstrap.modules.find((entry) => entry.module === module).requiredSymbols = [];
  assert.match(validateModulePolicy(emptyBootstrap, manifest).join(), /preserve verified bootstrap/, `${module} 清空锚点拒绝`);
  const absentBootstrap = structuredClone(policy);
  delete absentBootstrap.modules.find((entry) => entry.module === module).requiredSymbols;
  assert.match(validateModulePolicy(absentBootstrap, manifest).join(), /preserve verified bootstrap/, `${module} 删除锚点拒绝`);
}
const bypassWsi = structuredClone(policy);
const wrongVulkan = bypassWsi.modules.find((entry) => entry.module === 'vulkan');
wrongVulkan.kind = 'system-dispatch'; wrongVulkan.systemLibrary = 'libvulkan.so';
delete wrongVulkan.artifact; delete wrongVulkan.stage;
assert.match(validateModulePolicy(bypassWsi, manifest).join(), /verified (kind|artifact|systemLibrary)/,
  '系统 Vulkan 不能替代实际首先装载的 WSI shim');
const missingNative = structuredClone(manifest);
missingNative.natives = missingNative.natives.filter((entry) => entry.name !== 'liblwjgl_nanovg.so');
assert.match(validateModulePolicy(policy, missingNative).join(), /JNI provider/);

// 正控执行真实 ELF 工具，证明读取手段能识别当前已存在的提供方；计数是本轮锁定输入的
// 回归身份，不是规范里永久写死的模块数量。升级时必须审查绑定集合并更新这些断言。
const real = checkModuleCoverage({ root, policy, manifest });
assert.equal(real.ok, true, real.problems.join('\n'));
for (const [module, count] of [['shaderc', 155], ['freetype', 210], ['sdl', 1037], ['spvc', 168]]) {
  assert.equal(real.modules.find((entry) => entry.jar === `lwjgl-${module}.jar`).required, count, module);
}

/** 构造内存 ZIP，只用于控制真实 HAP 读取路径；不写临时包，也不用于声称产物通过。 */
function storedZip(entries) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const [name, payload] of entries) {
    const bytes = Buffer.from(payload);
    const fileName = Buffer.from(name);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); header.writeUInt16LE(20, 4);
    header.writeUInt32LE(bytes.length, 18); header.writeUInt32LE(bytes.length, 22);
    header.writeUInt16LE(fileName.length, 26);
    local.push(header, fileName, bytes);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50, 0); record.writeUInt16LE(20, 4); record.writeUInt16LE(20, 6);
    record.writeUInt32LE(bytes.length, 20); record.writeUInt32LE(bytes.length, 24);
    record.writeUInt16LE(fileName.length, 28); record.writeUInt32LE(offset, 42);
    central.push(record, fileName);
    offset += header.length + fileName.length + bytes.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.size, 8); end.writeUInt16LE(entries.size, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}

const entries = new Map();
const byArtifact = new Map();
for (const entry of policy.modules) {
  const jar = readFileSync(join(root, 'prebuilt/lwjgl3/jars', entry.jar));
  entries.set(`resources/rawfile/lwjgl/${entry.jar}`, jar);
  if (entry.artifact) {
    entries.set(`libs/arm64-v8a/${entry.artifact}`, Buffer.from(`fixture:${entry.artifact}`));
    byArtifact.set(entry.artifact, new Set(collectModuleRequirements(root, entry, jar)));
  }
}
for (const name of ['glfwGetEGLDisplay', 'glfwGetEGLContext', 'glfwGetEGLSurface', 'glfwGetEGLConfig']) {
  assert.equal(byArtifact.get('libglfw.so').has(name), true, `NativeEGL 必需集合包含 ${name}`);
}
const fullHapFixture = storedZip(entries);
const inspect = (name, bytes) => {
  assert.equal(bytes.toString(), `fixture:${name}`, '必须检查从本次包读取的提供方');
  return byArtifact.get(name);
};
assert.equal(checkModuleCoverage({ root, policy, manifest, hapBytes: fullHapFixture, inspectExports: inspect }).ok, true);
for (const missing of ['liblwjgl_opengles.so', 'liblwjgl_nanovg.so', 'libamcl_lwjgl_egl.so', 'libamcl_vulkan_wsi.so']) {
  const broken = new Map(entries); broken.delete(`libs/arm64-v8a/${missing}`);
  const report = checkModuleCoverage({ root, policy, manifest, hapBytes: storedZip(broken), inspectExports: inspect });
  assert.equal(report.ok, false, missing);
  assert.match(report.problems.join(), new RegExp(missing.replaceAll('.', '\\.')));
}
// 删除原来 45 个 Shaderc 主函数之外的 GLSLang、resource limits、SPV 入口，均必须拒绝。
// 同名函数放在另一库也不算满足 Shaderc.getLibrary() 的默认提供方契约。
for (const [artifact, missing] of [
  ['libshaderc.so', 'glslang_program_create'],
  ['libshaderc.so', 'glslang_default_resource'],
  ['libshaderc.so', 'spvValidateWithOptions'],
  ['libfreetype.so', 'FT_Get_Char_Index'],
  ['libSDL3.so', 'SDL_CreateWindow'],
  ['libspirv-cross.so', 'spvc_compiler_compile'],
  ['libglfw.so', 'glfwGetEGLConfig'],
  ['libamcl_vulkan_wsi.so', 'vkGetInstanceProcAddr'],
]) {
  assert.equal(byArtifact.get(artifact).has(missing), true, `负控入口必须真实存在：${missing}`);
  const report = checkModuleCoverage({ root, policy, manifest, hapBytes: fullHapFixture,
    inspectExports: (name, bytes) => {
      const symbols = new Set(inspect(name, bytes));
      if (name === artifact) symbols.delete(missing);
      else symbols.add(missing);
      return symbols;
    } });
  assert.equal(report.ok, false, missing);
  assert.match(report.problems.join(), new RegExp(missing));
}
console.log('[test-lwjgl-module-coverage] actual-provider positive, full-JAR classification, HAP missing providers, shaderc/FreeType/SDL/SPVC/NativeEGL removals and ELF direction controls passed');

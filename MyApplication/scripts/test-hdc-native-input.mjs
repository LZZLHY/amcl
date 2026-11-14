/**
 * HDC 路径迁移回归：执行真实 Hvigor 插件与 CMake 解析器，构造旧库移走后的 Ninja
 * 失败，再用插件产生的新参数在同一目录重配并构建。仅替换 Cargo/SDK 上下文；
 * 不读取签名、不修改生产缓存。成功回收私有夹具，失败保留现场和外置收据。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = assertExternalOutputPath(process.env.AMCL_TEST_OUTPUT_DIR ?? resolveWorkspacePath('run', 'hdc-native-input'));
fs.mkdirSync(output, { recursive: true });
const fixture = fs.mkdtempSync(path.join(output, 'fixture-'));
const require = createRequire(import.meta.url);
const nativeRoot = process.env.DEVECO_SDK_HOME ? path.join(process.env.DEVECO_SDK_HOME, 'default/openharmony/native') :
  'D:/Huawei/command-line-tools/sdk/default/openharmony/native';
const cmake = process.env.CMAKE ?? (process.platform === 'win32' ? path.join(nativeRoot, 'build-tools/cmake/bin/cmake.exe') : 'cmake');
const ninja = process.env.NINJA ?? (process.platform === 'win32' ? path.join(nativeRoot, 'build-tools/cmake/bin/ninja.exe') : 'ninja');
const compiled = compiler.transpileModule(fs.readFileSync(path.join(root, 'entry/hvigorfile.ts'), 'utf8'), {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true,
});
assert.equal(compiled.diagnostics?.length ?? 0, 0, '真实 Hvigor 插件须可转译');
const results = [];

/** 执行整个生产插件，再仅触发 diagnosticProfile 回调；外部构建命令由替身接管。 */
function evaluate(archive, product = 'default', previousArguments = '') {
  const exports = {}, env = {}, calls = [];
  const profile = { targets: [{ name: product, config: { buildOption: {
    externalNativeOptions: { arguments: previousArguments },
  } } }] };
  const context = { getBuildMode: () => 'debug', getBuildProfileOpt: () => profile,
    setBuildProfileOpt: value => assert.equal(value, profile) };
  vm.runInNewContext(compiled.outputText, { exports, __dirname: path.join(root, 'entry'),
    process: { argv: ['node', 'hvigorw', '-p', `product=${product}`], env, execPath: process.execPath },
    require: name => {
      if (name === '@ohos/hvigor-ohos-plugin') return { hapTasks: {}, OhosPluginId: { OHOS_HAP_PLUGIN: 'hap' } };
      if (name === 'node:child_process') return { execFileSync: (_exe, args) => {
        calls.push(args[0]);
        if (args[0].endsWith('diagnostic-profile.mjs')) return '-DMC_OHOS_BUILD_TESTS=OFF';
        if (args[0].endsWith('build-hdc-core.mjs')) return archive + '\n';
        throw new Error('意外生产调用：' + args[0]);
      } };
      return require(name);
    }, console });
  exports.default.plugins.find(plugin => plugin.pluginId === 'diagnosticProfile').apply({
    afterNodeEvaluate: callback => callback({ getContext: () => context }),
  });
  const args = profile.targets[0].config.buildOption.externalNativeOptions.arguments;
  return { env, args, calls,
    fingerprint: args.match(/-DAMCL_HDC_CORE_ARCHIVE_PATH_SHA256=([a-f0-9]{64})(?:\s|$)/)?.[0].trim() };
}

/** 每条真实 CMake/Ninja 命令保存输出，失败时保留 fixture，不涉及生产源码或库。 */
function run(label, executable, args, env = {}) {
  const childEnv = { ...process.env };
  delete childEnv.AMCL_HDC_CORE_ARCHIVE;
  Object.assign(childEnv, env);
  const result = spawnSync(executable, args, { encoding: 'utf8', cwd: fixture, env: childEnv, timeout: 30000 });
  if (result.error) throw result.error;
  fs.writeFileSync(path.join(output, `${label}.log`), (result.stdout ?? '') + (result.stderr ?? ''));
  return result;
}

let success = false;
try {
  const archiveA = path.join(fixture, '旧缓存 A 空格', 'libamcl_hdc_core.a');
  const archiveB = path.join(fixture, '新缓存 B 空格', 'libamcl_hdc_core.a');
  for (const file of [archiveA, archiveB]) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, '同一库字节；本回归只验证配置及依赖路径');
  }
  const a = evaluate(archiveA), b = evaluate(archiveB, 'default', a.args);
  assert.ok(a.fingerprint && b.fingerprint, '生产插件必须暴露 SDK 可跟踪的摘要参数');
  assert.notEqual(a.fingerprint, b.fingerprint, '库路径改变必须改变 SDK 配置参数');
  assert.equal(b.fingerprint, evaluate(archiveB).fingerprint, '相同路径不得无条件失效缓存');
  assert.equal(b.args.match(/AMCL_HDC_CORE_ARCHIVE_PATH_SHA256=/g).length, 1, '重评配置不得残留旧摘要');
  assert.ok(!b.args.includes(archiveB), '空格路径通过环境传递，参数仅携带安全摘要');
  results.push('真实 Hvigor 插件：路径变化、相同路径稳定、旧摘要替换、空格路径通过');

  // 无编译器的小工程仍由真实 Ninja 跟踪库文件，并读取生产解析器的结果。
  const sourceDir = path.join(fixture, 'source'), buildDir = path.join(fixture, 'build');
  fs.mkdirSync(sourceDir);
  const cmakeModule = path.join(root, 'entry/src/main/cpp/cmake/AmclHdcArchive.cmake').replaceAll('\\', '/');
  fs.writeFileSync(path.join(sourceDir, 'CMakeLists.txt'), `cmake_minimum_required(VERSION 3.16)
project(HdcPathInput NONE)
include("${cmakeModule}")
amcl_resolve_hdc_archive()
add_library(amcl_hdc_core STATIC IMPORTED)
set_target_properties(amcl_hdc_core PROPERTIES IMPORTED_LOCATION "\${AMCL_HDC_CORE_ARCHIVE}")
file(GENERATE OUTPUT "\${CMAKE_BINARY_DIR}/archive.txt" CONTENT "$<TARGET_PROPERTY:amcl_hdc_core,IMPORTED_LOCATION>")
add_custom_target(archive_input ALL DEPENDS "\${AMCL_HDC_CORE_ARCHIVE}")
`);
  const configure = binding => ['-S', sourceDir, '-B', buildDir, '-GNinja', `-DCMAKE_MAKE_PROGRAM=${ninja}`, binding.fingerprint];
  assert.equal(run('01-configure-a', cmake, configure(a), a.env).status, 0);
  assert.equal(run('02-build-a', cmake, ['--build', buildDir], a.env).status, 0);
  fs.unlinkSync(archiveA);
  const stale = run('03-stale-negative', cmake, ['--build', buildDir], b.env);
  assert.notEqual(stale.status, 0, '仅变环境而未重配时必须复现旧路径缺失');
  assert.match(stale.stderr + stale.stdout, /missing and no known rule/);
  assert.equal(run('04-configure-b', cmake, configure(b), b.env).status, 0);
  assert.equal(fs.readFileSync(path.join(buildDir, 'archive.txt'), 'utf8'), b.env.AMCL_HDC_CORE_ARCHIVE);
  assert.equal(run('05-build-b', cmake, ['--build', buildDir], b.env).status, 0);
  results.push('真实 CMake/Ninja：复现移走旧库的失败，同一构建目录重新配置后引用新库成功');

  const mismatch = run('06-mismatch-negative', cmake, configure(a), b.env);
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stderr, /HDC archive path identity mismatch/);
  const missing = run('07-missing-negative', cmake, configure(a), a.env);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /Complete HDC archive missing/);
  assert.equal(run('08-legacy-positive', cmake, ['-S', sourceDir, '-B', path.join(fixture, 'legacy'), '-GNinja',
    `-DCMAKE_MAKE_PROGRAM=${ninja}`, `-DAMCL_HDC_CORE_ARCHIVE=${b.env.AMCL_HDC_CORE_ARCHIVE}`]).status, 0);
  const store = evaluate(archiveB, 'store', b.args);
  assert.ok(!store.calls.some(file => file.endsWith('build-hdc-core.mjs')));
  assert.ok(!store.args.includes('AMCL_HDC_CORE_ARCHIVE_PATH_SHA256'));
  results.push('环境与摘要不一致、缺失文件拒绝；独立 -D 路径及 store 不构建 HDC 保持兼容');
  success = true;
} finally {
  const receipt = { success, time: new Date().toISOString(), sourceRoot: root, results,
    fixture, fixtureRemoved: success, scope: 'Hvigor hook and real CMake/Ninja path regression; not an SDK application build' };
  if (success) fs.rmSync(fixture, { recursive: true });
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(receipt, null, 2) + '\n');
}
console.log(JSON.stringify({ success, results, receipt: path.join(output, 'result.json') }, null, 2));

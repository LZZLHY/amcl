import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { PRODUCT_ROOT } from './product-contract.mjs';
import { DIAGNOSTIC_FLAGS } from './diagnostic-profile.mjs';
import { workspacePath } from './lib/workspace-paths.mjs';

// 仅改变宿主测试生成头/脚本的位置，产品诊断策略与原始 CMake 输入保持相同。
const dir = workspacePath('build', 'diagnostics-cmake');
mkdirSync(dir, { recursive: true });
const script = resolve(dir, 'test.cmake');
writeFileSync(script, `set(CMAKE_CURRENT_BINARY_DIR "${dir.replaceAll('\\', '/')}")\ninclude("${PRODUCT_ROOT.replaceAll('\\', '/')}/entry/src/main/cpp/cmake/ProductDiagnostics.cmake")\n`);
const cmake = process.env.CMAKE ?? (process.platform === 'win32'
  ? 'D:/Huawei/command-line-tools/sdk/default/openharmony/native/build-tools/cmake/bin/cmake.exe' : 'cmake');
function run(product, mode, args = []) {
  return spawnSync(cmake, [`-DAMCL_BUILD_PRODUCT=${product}`, `-DCMAKE_BUILD_TYPE=${mode}`, ...args, '-P', script], { encoding: 'utf8', cwd: dir });
}
for (const product of ['sideload', 'store', 'desktop']) {
  for (const mode of ['Debug', 'Release']) {
    assert.equal(run(product, mode).status, 0);
    for (const flag of Object.values(DIAGNOSTIC_FLAGS)) {
      const bad = run(product, mode, [`-D${flag}=ON`]);
      assert.notEqual(bad.status, 0, `${product}/${mode}/${flag} must reject`);
      assert.match(bad.stderr, /default-only/);
    }
  }
}
assert.match(run('default', 'Debug', ['-DMC_OHOS_BUILD_TESTS=AUTO']).stdout, /mask=3;/);
assert.match(run('default', 'Release', ['-DMC_OHOS_BUILD_TESTS=AUTO']).stdout, /mask=1;/);
assert.match(run('default', 'Release', ['-DAMCL_MG_FRAME_STATS=ON']).stdout, /mask=9;/);
// 用实际生成头核对编译输入，不能只凭 JS 计算出的 mask 宣称原生开关生效。
assert.match(run('default', 'Release', ['-DAMCL_VULKAN_WSI_TRACE=ON']).stdout, /mask=513;/);
assert.match(readFileSync(resolve(dir, 'product_diagnostics_config.h'), 'utf8'), /#define AMCL_DIAGNOSTICS_MASK 513\b/);
assert.match(run('default', 'Debug', ['-DMC_OHOS_BUILD_TESTS=AUTO', '-DAMCL_VULKAN_WSI_TRACE=ON']).stdout, /mask=515;/);
assert.match(readFileSync(resolve(dir, 'product_diagnostics_config.h'), 'utf8'), /#define AMCL_DIAGNOSTICS_MASK 515\b/);
assert.notEqual(run('unknown', 'Debug').status, 0);
console.log('CMake product diagnostics: direct configuration bypass rejection and default positive controls PASS');

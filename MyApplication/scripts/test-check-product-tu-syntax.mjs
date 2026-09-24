#!/usr/bin/env node

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import assert from 'node:assert/strict';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const sourceRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fixtureParent = mkdtempSync(join(workspaceTempRoot(), 'product-tu syntax '));
// 父目录故意包含全部排除关键字；它们只有出现在工程 cpp 相对路径里才应排除。
const fixtureRoot = join(fixtureParent, 'build', 'third_party', 'openal-soft', 'mobileglues', 'project');

try {
  const scriptsDir = join(fixtureRoot, 'scripts');
  const cppDir = join(fixtureRoot, 'entry/src/main/cpp');
  const platformDir = join(cppDir, 'platform');
  mkdirSync(scriptsDir, { recursive: true });
  mkdirSync(platformDir, { recursive: true });

  const checker = join(scriptsDir, 'check-product-tu-syntax.mjs');
  const fakeCompiler = join(fixtureRoot, 'fake compiler.mjs');
  const source = join(platformDir, 'touch_input.cpp');
  copyFileSync(join(sourceRoot, 'scripts/check-product-tu-syntax.mjs'), checker);
  writeFileSync(source, '// fixture\n');
  writeFileSync(join(platformDir, 'api26_input_link_probe.cpp'), '// fixture\n');
  writeFileSync(fakeCompiler, `
import assert from 'node:assert/strict';
const args = process.argv.slice(2);
assert.ok(args.includes('--gcc-toolchain=D:/Huawei/DevEco Studio/sdk/default/hms/native/BiSheng'));
assert.ok(args.includes('--sysroot=D:/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot'));
assert.ok(args.includes('-ID:/Huawei/DevEco Studio/sdk/default/hms/native/sysroot/usr/include'));
assert.ok(args.includes('-DAL_API='));
assert.ok(args.includes('-DFOO="none"'));
assert.ok(args.includes('-fsyntax-only'));
assert.ok(!args.includes('-c'));
assert.ok(!args.includes('-o'));
`);

  const command = `"${process.execPath}" "${fakeCompiler}" ` +
    '--gcc-toolchain="D:/Huawei/DevEco Studio/sdk/default/hms/native/BiSheng" ' +
    '--sysroot="D:/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot" ' +
    '-I"D:/Huawei/DevEco Studio/sdk/default/hms/native/sysroot/usr/include" ' +
    '-DAL_API="" -DFOO=\\"none\\" -o touch.o -c ' + `"${source}"`;

  for (const product of ['store', 'desktop']) {
    const buildDir = join(
      fixtureRoot, 'entry/.cxx', product, product, 'release/arm64-v8a');
    mkdirSync(buildDir, { recursive: true });
    writeFileSync(join(buildDir, 'compile_commands.json'), JSON.stringify([{
      directory: buildDir,
      file: source,
      command,
    }]));
  }

  const run = (product) => spawnSync(process.execPath, [
    checker, '--product', product, '--target', product, '--mode', 'release', '--abi', 'arm64-v8a',
  ], { encoding: 'utf8' });

  const store = run('store');
  assert.equal(store.status, 0, `${store.stdout}\n${store.stderr}`);
  assert.match(store.stdout, /PASS: 1 个产品 TU/);
  assert.doesNotMatch(store.stderr, /api26_input_link_probe/);

  // 真正位于本工程的构建生成物/第三方源码仍须排除，不能为了接纳新父目录而删掉排除规则。
  const storeDb = join(fixtureRoot, 'entry/.cxx/store/store/release/arm64-v8a/compile_commands.json');
  const storeDirectory = dirname(storeDb);
  const ownEntry = { directory: storeDirectory, file: source, command };
  const excluded = ['build/generated.cpp', 'third_party/vendor.cpp',
    'openal/openal-soft/vendor.cpp', 'mobileglues/vendor.cpp'];
  const foreignSource = join(fixtureParent, 'other-project/entry/src/main/cpp/platform/touch_input.cpp');
  mkdirSync(dirname(foreignSource), { recursive: true });
  writeFileSync(foreignSource, '// foreign checkout\n');
  const mustNotRun = `"${process.execPath}" -e "process.exit(73)"`;
  const skippedEntries = excluded.map(file => {
    const absolute = join(cppDir, file);
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, '// not a first-party product TU\n');
    return { directory: storeDirectory, file: absolute, command: mustNotRun };
  });
  writeFileSync(storeDb, JSON.stringify([ownEntry, ...skippedEntries,
    { directory: storeDirectory, file: foreignSource, command: mustNotRun }]));
  const bounded = run('store');
  assert.equal(bounded.status, 0, bounded.stdout + bounded.stderr);
  assert.match(bounded.stdout, /PASS: 1 个产品 TU/);
  // 仅外部同名 TU 不能构成“本工程已检查”；保留零选中硬失败，避免借其他克隆凑完整性。
  writeFileSync(storeDb, JSON.stringify([{ directory: storeDirectory, file: foreignSource, command }]));
  const foreignOnly = run('store');
  assert.equal(foreignOnly.status, 2, foreignOnly.stdout + foreignOnly.stderr);
  assert.match(foreignOnly.stderr, /选中 0 个 TU/);
  writeFileSync(storeDb, JSON.stringify([ownEntry]));

  const desktop = run('desktop');
  assert.equal(desktop.status, 1, `${desktop.stdout}\n${desktop.stderr}`);
  assert.match(desktop.stderr, /platform\/api26_input_link_probe\.cpp/);

  const mobileFiles = ['glfw/glfw_egl.cpp','glfw/mg_benchmark_cache.cpp',
    'platform/mg_config.cpp','platform/mg_config_migration.cpp'];
  for (const file of [...mobileFiles,'glfw/desktop_egl.cpp']) {
    mkdirSync(dirname(join(cppDir,file)),{recursive:true});
    writeFileSync(join(cppDir,file),'// fixture\n');
  }
  const desktopDir = join(fixtureRoot,'entry/.cxx/desktop/desktop/release/arm64-v8a');
  const storeDir = join(fixtureRoot,'entry/.cxx/store/store/release/arm64-v8a');
  const rows = files => files.map(file=>({directory:desktopDir,file:join(cppDir,file),command}));
  const setDesktop = (files,flags) => {
    writeFileSync(join(desktopDir,'compile_commands.json'),JSON.stringify(rows(files)));
    writeFileSync(join(desktopDir,'CMakeCache.txt'),flags);
    return run('desktop');
  };
  const nativeFlags='AMCL_NATIVE_DESKTOP_ONLY:BOOL=ON\nAMCL_API26_LINK_PROBE:BOOL=OFF\n';
  const nativeFiles=['platform/touch_input.cpp','glfw/desktop_egl.cpp'];
  const native = setDesktop(nativeFiles,nativeFlags);
  assert.equal(native.status,0,native.stderr);
  assert.match(setDesktop(nativeFiles.slice(0,1),nativeFlags).stderr,/glfw\/desktop_egl.cpp/);
  assert.match(setDesktop(nativeFiles,nativeFlags.replace('LINK_PROBE:BOOL=OFF','LINK_PROBE:BOOL=ON')).stderr,/api26_input_link_probe/);
  assert.notEqual(setDesktop(nativeFiles,'').status,0,'missing actual flags cannot exempt mobile files');
  writeFileSync(join(storeDir,'CMakeCache.txt'),'AMCL_NATIVE_DESKTOP_ONLY:BOOL=OFF\nAMCL_API26_LINK_PROBE:BOOL=OFF\n');
  writeFileSync(join(storeDir,'compile_commands.json'),JSON.stringify(rows(['platform/touch_input.cpp',...mobileFiles])));
  assert.equal(run('store').status,0);
  writeFileSync(join(storeDir,'compile_commands.json'),JSON.stringify(rows(['platform/touch_input.cpp',...mobileFiles.filter(f=>!f.endsWith('mg_config.cpp'))])));
  assert.match(run('store').stderr,/platform\/mg_config.cpp/);

  console.log('test-check-product-tu-syntax: PASS');
} finally {
  rmSync(fixtureParent, { recursive: true, force: true });
}

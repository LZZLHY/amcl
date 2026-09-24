#!/usr/bin/env node
// Execute the pure policy on a host compiler, or at minimum syntax-check it
// with the configured OHOS SDK compiler. Every compiler artifact stays in a
// unique temporary directory and is removed on success or failure.

import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const source = join(root, 'entry', 'src', 'main', 'cpp', 'tests', 'host',
  'mg_benchmark_cache_policy_test.cpp');
const migrationTest = join(root, 'entry', 'src', 'main', 'cpp', 'tests', 'host',
  'mg_config_migration_test.cpp');
const migrationSource = join(root, 'entry', 'src', 'main', 'cpp', 'platform',
  'mg_config_migration.cpp');
const includeDir = join(root, 'entry', 'src', 'main', 'cpp', 'glfw');
const platformIncludeDir = join(root, 'entry', 'src', 'main', 'cpp', 'platform');
const cJsonSource = join(root, 'prebuilt', 'mobileglues', 'mg_src',
  'MobileGlues-cpp', 'config', 'cJSON.c');
const cJsonIncludeDir = join(root, 'prebuilt', 'mobileglues', 'mg_src',
  'MobileGlues-cpp', 'config');

function probeCompiler(candidate) {
  if (candidate.length === 0) return null;
  if ((candidate.includes('/') || candidate.includes('\\')) && !existsSync(candidate)) {
    return null;
  }
  const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
  if (probe.status !== 0) return null;
  return `${probe.stdout ?? ''}\n${probe.stderr ?? ''}`;
}

function findHostCompiler() {
  for (const candidate of [process.env.CXX ?? '', 'clang++', 'g++', 'c++']) {
    const version = probeCompiler(candidate);
    if (version === null || /\bOHOS\b/i.test(version)) continue;
    return candidate;
  }
  return '';
}

function findHostCCompiler() {
  for (const candidate of [process.env.CC ?? '', 'clang', 'gcc', 'cc']) {
    const version = probeCompiler(candidate);
    if (version === null || /\bOHOS\b/i.test(version)) continue;
    return candidate;
  }
  return '';
}

function decodePropertiesPath(value) {
  return value.trim().replace(/\\\\/g, '\\').replace(/\\:/g, ':');
}

function configuredOhosSdkRoots() {
  const roots = [process.env.OHOS_SDK_HOME ?? '', process.env.DEVECO_SDK_HOME ?? ''];
  const propertiesPath = join(root, 'local.properties');
  if (existsSync(propertiesPath)) {
    const match = readFileSync(propertiesPath, 'utf8').match(/^\s*hwsdk\.dir\s*=\s*(.+)\s*$/m);
    if (match !== null) roots.push(decodePropertiesPath(match[1]));
  }
  if (process.platform === 'win32') {
    roots.push(
      'D:\\Huawei\\command-line-tools\\sdk\\default\\openharmony',
      'D:\\Huawei\\DevEco Studio\\sdk\\default\\openharmony',
    );
  }
  return [...new Set(roots.filter((value) => value.length > 0))];
}

function findOhosCompiler() {
  const explicit = process.env.OHOS_CXX ?? '';
  if (explicit.length > 0 && probeCompiler(explicit) !== null) {
    return { compiler: explicit, sdkRoot: resolve(explicit, '..', '..', '..', '..') };
  }
  for (const sdkRoot of configuredOhosSdkRoots()) {
    const compiler = join(sdkRoot, 'native', 'llvm', 'bin',
      process.platform === 'win32' ? 'clang++.exe' : 'clang++');
    if (probeCompiler(compiler) !== null) return { compiler, sdkRoot };
  }
  return null;
}

function findMsvcEnvironment() {
  if (process.platform !== 'win32') return '';
  const candidates = [
    'C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe',
    'D:\\Microsoft Visual Studio\\Installer\\vswhere.exe',
  ];
  for (const vswhere of candidates) {
    if (!existsSync(vswhere)) continue;
    const query = spawnSync(vswhere, [
      '-latest', '-products', '*',
      '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property', 'installationPath',
    ], { encoding: 'utf8' });
    if (query.status !== 0) continue;
    const installation = (query.stdout ?? '').trim();
    const vcvars = join(installation, 'VC', 'Auxiliary', 'Build', 'vcvars64.bat');
    if (existsSync(vcvars)) return vcvars;
  }
  return '';
}

function appendIdentityField(name, value) {
  const text = String(value);
  return `${name}=${Buffer.byteLength(text, 'utf8')}:${text}\n`;
}

function identityCacheKey(identity) {
  const canonical = [
    ['schema', identity.cacheSchema],
    ['benchmarkReport', identity.benchmarkReportVersion],
    ['renderer', identity.renderer],
    ['driver', identity.driver],
    ['frontend', identity.frontendVersion],
    ['mobileglues', identity.mobileGluesVersion],
    ['mobilegluesCommit', identity.mobileGluesCommit],
    ['mobilegluesBuild', identity.mobileGluesBuildIdentity],
    ['hostBuild', identity.hostBuildIdentity],
    ['hostAbi', identity.hostAbi],
  ].map(([name, value]) => appendIdentityField(name, value)).join('');
  let hash = 14695981039346656037n;
  for (const byte of Buffer.from(canonical, 'utf8')) {
    hash ^= BigInt(byte);
    hash = BigInt.asUintN(64, hash * 1099511628211n);
  }
  return hash.toString(16).padStart(16, '0');
}

function verifyIdentityMirror() {
  const first = {
    cacheSchema: 3,
    benchmarkReportVersion: 3,
    renderer: 'fixture-renderer',
    driver: 'fixture-driver',
    frontendVersion: 'fixture-frontend',
    mobileGluesVersion: '2.0.0.0:type=10:suffix=',
    mobileGluesCommit: '1'.repeat(40),
    mobileGluesBuildIdentity: `schema=1:source=${'1'.repeat(40)}:worktree=${'c'.repeat(64)}:state=dirty:options=${'d'.repeat(64)}`,
    hostBuildIdentity: `source=${'a'.repeat(40)}:state=clean:compiler=fixture`,
    hostAbi: 'glfw-amcl-mg-benchmark-v3',
  };
  const firstKey = identityCacheKey(first);
  const commitKey = identityCacheKey({ ...first, mobileGluesCommit: '2'.repeat(40) });
  const worktreeKey = identityCacheKey({
    ...first,
    mobileGluesBuildIdentity: `schema=1:source=${'1'.repeat(40)}:worktree=${'e'.repeat(64)}:state=dirty:options=${'d'.repeat(64)}`,
  });
  const hostKey = identityCacheKey({
    ...first,
    hostBuildIdentity: `source=${'b'.repeat(40)}:state=clean:compiler=fixture`,
  });
  const abiKey = identityCacheKey({ ...first, hostAbi: 'glfw-amcl-mg-benchmark-v4' });
  if (!/^[0-9a-f]{16}$/.test(firstKey) || firstKey === commitKey ||
      firstKey === worktreeKey || firstKey === hostKey || firstKey === abiKey) {
    throw new Error('JavaScript identity fixture did not invalidate cache identity');
  }
}

function reportFailure(result, label) {
  process.stderr.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  throw new Error(`${label} failed with status ${result.status ?? 'unknown'}`);
}

const temp = mkdtempSync(join(tmpdir(), 'amcl-mg-cache-policy-'));
try {
  verifyIdentityMirror();

  const compiler = findHostCompiler();
  const msvcEnvironment = compiler.length === 0 ? findMsvcEnvironment() : '';
  const executable = join(temp, process.platform === 'win32' ? 'policy-test.exe' : 'policy-test');
  const migrationExecutable = join(temp,
    process.platform === 'win32' ? 'config-migration-test.exe' : 'config-migration-test');
  let compileOnly = false;

  if (msvcEnvironment.length > 0) {
    const commandFile = join(temp, 'compile-policy-test.cmd');
    writeFileSync(commandFile,
      `@call "${msvcEnvironment}" >nul\r\n` +
      '@if errorlevel 1 exit /b %errorlevel%\r\n' +
      `@cl /nologo /std:c++17 /EHsc /W4 /WX "${source}" /I"${includeDir}" /I"${platformIncludeDir}" /Fe:"${executable}"\r\n` +
      '@if errorlevel 1 exit /b %errorlevel%\r\n' +
      `@cl /nologo /TC /W4 /WX /c "${cJsonSource}" /I"${cJsonIncludeDir}" /Fo:"${join(temp, 'cjson.obj')}"\r\n` +
      '@if errorlevel 1 exit /b %errorlevel%\r\n' +
      `@cl /nologo /std:c++17 /EHsc /W4 /WX "${migrationTest}" "${migrationSource}" "${join(temp, 'cjson.obj')}" /I"${platformIncludeDir}" /I"${cJsonIncludeDir}" /Fe:"${migrationExecutable}"\r\n`,
    'utf8');
    const compile = spawnSync(process.env.ComSpec ?? 'cmd.exe',
      ['/d', '/c', commandFile], { cwd: temp, encoding: 'utf8' });
    if (compile.status !== 0) reportFailure(compile, 'MSVC policy compile');
  } else if (compiler.length > 0) {
    const compile = spawnSync(compiler, [
      '-std=c++17', '-O0', '-Wall', '-Wextra', '-Werror', source,
      '-I', includeDir, '-I', platformIncludeDir, '-o', executable,
    ], { cwd: temp, encoding: 'utf8' });
    if (compile.status !== 0) reportFailure(compile, 'host policy compile');

    const cCompiler = findHostCCompiler();
    if (cCompiler.length === 0) throw new Error('host C compiler not found for cJSON fixture');
    const cJsonObject = join(temp, 'cjson.o');
    const compileCJson = spawnSync(cCompiler, [
      '-std=c99', '-O0', '-Wall', '-Wextra', '-Werror', '-c', cJsonSource,
      '-I', cJsonIncludeDir, '-o', cJsonObject,
    ], { cwd: temp, encoding: 'utf8' });
    if (compileCJson.status !== 0) reportFailure(compileCJson, 'host cJSON fixture compile');
    const compileMigration = spawnSync(compiler, [
      '-std=c++17', '-O0', '-Wall', '-Wextra', '-Werror', migrationTest,
      migrationSource, cJsonObject, '-I', platformIncludeDir,
      '-I', cJsonIncludeDir, '-o', migrationExecutable,
    ], { cwd: temp, encoding: 'utf8' });
    if (compileMigration.status !== 0) {
      reportFailure(compileMigration, 'host config-migration compile');
    }
  } else {
    const ohos = findOhosCompiler();
    if (ohos === null) {
      throw new Error('no host C++17 compiler or configured OHOS SDK compiler found');
    }
    const sysroot = join(ohos.sdkRoot, 'native', 'sysroot');
    if (!existsSync(sysroot)) throw new Error(`OHOS sysroot not found: ${sysroot}`);
    const compile = spawnSync(ohos.compiler, [
      '--target=aarch64-linux-ohos', `--sysroot=${sysroot}`,
      '-std=c++17', '-Wall', '-Wextra', '-Werror', '-fsyntax-only', source,
      '-I', includeDir, '-I', platformIncludeDir,
    ], { cwd: temp, encoding: 'utf8' });
    if (compile.status !== 0) reportFailure(compile, 'OHOS policy syntax check');

    const ohosCCompiler = join(dirname(ohos.compiler),
      process.platform === 'win32' ? 'clang.exe' : 'clang');
    if (!existsSync(ohosCCompiler)) {
      throw new Error(`OHOS C compiler not found: ${ohosCCompiler}`);
    }
    const compileCJson = spawnSync(ohosCCompiler, [
      '--target=aarch64-linux-ohos', `--sysroot=${sysroot}`,
      '-std=c99', '-Wall', '-Wextra', '-Werror', '-fsyntax-only', cJsonSource,
      '-I', cJsonIncludeDir,
    ], { cwd: temp, encoding: 'utf8' });
    if (compileCJson.status !== 0) {
      reportFailure(compileCJson, 'OHOS cJSON syntax check');
    }
    const compileMigration = spawnSync(ohos.compiler, [
      '--target=aarch64-linux-ohos', `--sysroot=${sysroot}`,
      '-std=c++17', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
      migrationTest, migrationSource, '-I', platformIncludeDir,
      '-I', cJsonIncludeDir,
    ], { cwd: temp, encoding: 'utf8' });
    if (compileMigration.status !== 0) {
      reportFailure(compileMigration, 'OHOS config-migration syntax check');
    }
    console.log('[test-ohos-runtime-cache-policy] PASS (OHOS compile-only + config migration + identity mirror)');
    compileOnly = true;
  }

  if (!compileOnly) {
    const runEnv = compiler.includes('/') || compiler.includes('\\')
      ? { ...process.env, PATH: `${dirname(compiler)}${delimiter}${process.env.PATH ?? ''}` }
      : process.env;
    const run = spawnSync(executable, [], { cwd: temp, encoding: 'utf8', env: runEnv });
    process.stdout.write(run.stdout ?? '');
    process.stderr.write(run.stderr ?? '');
    if (run.status !== 0) {
      throw new Error(`policy executable failed with status ${run.status ?? 'unknown'}`);
    }
    const migrationRun = spawnSync(migrationExecutable, [], {
      cwd: temp, encoding: 'utf8', env: runEnv,
    });
    process.stdout.write(migrationRun.stdout ?? '');
    process.stderr.write(migrationRun.stderr ?? '');
    if (migrationRun.status !== 0) {
      throw new Error(`config-migration executable failed with status ${migrationRun.status ?? 'unknown'}`);
    }
    console.log('[test-ohos-runtime-cache-policy] identity mirror: PASS');
  }
} catch (error) {
  console.error(`[test-ohos-runtime-cache-policy] ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  rmSync(temp, { recursive: true, force: true });
}

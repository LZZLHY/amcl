#!/usr/bin/env node
/**
 * 宿主真实 JNI Invocation 退出协议测试。逐用例启动 native 子进程以隔离 JVM 退出，
 * 核对 OS exit code、native hook 记录、Java shutdown hook 和正常返回四种独立证据。
 * 仅创建/删除自身唯一临时目录，不构建 HAP、不访问设备、不加载 AMCL 生产退出 hook。
 * 用法：node scripts/test-jvm-exit-invocation.mjs [--java-home <完整宿主 JDK>]
 */
import assert from 'node:assert/strict';
import { existsSync, readFileSync, mkdtempSync, mkdirSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('..', import.meta.url));
const fixture = path.join(root, 'tests/host/jvm_exit_invocation');
const temp = mkdtempSync(path.join(tmpdir(), 'amcl-jvm-exit-invocation-'));
const args = process.argv.slice(2);

/** 所有子命令前台执行且有超时；失败原样报告，不能把编译器/JVM 缺失当成跳过通过。 */
function run(program, argv, env = process.env, expectedStatus = 0, timeout = 60000) {
  const result = spawnSync(program, argv, { cwd: temp, env, encoding: 'utf8', timeout, maxBuffer: 1024 * 1024 });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  assert.equal(result.error, undefined, `${program}: ${result.error}`);
  assert.equal(result.signal, null, `${program}: terminated by signal ${result.signal}`);
  assert.equal(result.status, expectedStatus, `${program}: exit status ${result.status}, expected ${expectedStatus}`);
  return result;
}

/** 只在当前子进程读取已有 MSVC 环境；不安装工具或修改全局环境变量。 */
function msvcEnvironment() {
  const finder = [
    'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe',
    'D:/Microsoft Visual Studio/Installer/vswhere.exe',
  ].find(existsSync);
  let vcvars = process.env.AMCL_VCVARS64;
  if (!vcvars && finder) {
    const installation = run(finder, ['-latest', '-products', '*', '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).stdout.trim();
    vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
  }
  if (!vcvars || !existsSync(vcvars)) throw new Error('Existing MSVC environment not found; set AMCL_VCVARS64');
  const result = spawnSync(process.env.ComSpec ?? 'cmd.exe', ['/d', '/s', '/c',
    `"call "${vcvars}" >nul && set"`], { encoding: 'utf8', windowsVerbatimArguments: true, timeout: 60000 });
  if (result.error || result.status !== 0) throw new Error(`MSVC initialization failed: ${result.error ?? result.stderr}`);
  const env = {};
  for (const [key, value] of Object.entries(process.env)) env[key.toUpperCase()] = value;
  for (const line of result.stdout.split(/\r?\n/)) {
    const index = line.indexOf('=');
    if (index > 0) env[line.slice(0, index).toUpperCase()] = line.slice(index + 1);
  }
  return env;
}

try {
  assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--java-home'),
    'Usage: test-jvm-exit-invocation.mjs [--java-home <host JDK>]');
  let javaHome = args[1] ?? process.env.AMCL_JVM_TEST_JAVA_HOME ?? process.env.JAVA_HOME;
  if (!javaHome) {
    const properties = run('java', ['-XshowSettings:properties', '-version']);
    javaHome = /\bjava\.home\s*=\s*(.+)/.exec(properties.stdout + properties.stderr)?.[1].trim();
  }
  if (!javaHome) throw new Error('Cannot determine host JDK; pass --java-home');
  javaHome = path.resolve(javaHome);
  const windows = process.platform === 'win32';
  const java = path.join(javaHome, 'bin', windows ? 'java.exe' : 'java');
  const javac = path.join(javaHome, 'bin', windows ? 'javac.exe' : 'javac');
  const jvmCandidates = windows ? ['bin/server/jvm.dll', 'jre/bin/server/jvm.dll']
    : ['lib/server/libjvm.so', 'jre/lib/amd64/server/libjvm.so', 'lib/server/libjvm.dylib'];
  const jvm = jvmCandidates.map((name) => path.join(javaHome, name)).find(existsSync);
  assert.ok(jvm, 'Selected JDK has no known server JVM library: ' + javaHome);
  assert.ok(existsSync(path.join(javaHome, 'include/jni.h')), 'Selected JDK lacks JNI headers');
  run(java, ['-version']);
  const classes = path.join(temp, 'classes');
  mkdirSync(classes);
  run(javac, ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', classes,
    path.join(fixture, 'JniExitFixture.java')]);
  const binary = path.join(temp, windows ? 'jvm-exit-test.exe' : 'jvm-exit-test');
  const source = path.join(fixture, 'jvm_exit_invocation.cpp');
  if (windows) {
    run('cl.exe', ['/nologo', '/utf-8', '/std:c++17', '/EHsc', '/W4', '/WX', '/D_CRT_SECURE_NO_WARNINGS',
      `/I${path.join(javaHome, 'include')}`, `/I${path.join(javaHome, 'include/win32')}`, source,
      `/Fo${path.join(temp, 'jvm-exit-test.obj')}`, `/Fe${binary}`], msvcEnvironment());
  } else {
    const platformInclude = process.platform === 'darwin' ? 'darwin' : 'linux';
    run(process.env.CXX ?? 'c++', ['-std=c++17', '-Wall', '-Wextra', '-Werror',
      '-I' + path.join(javaHome, 'include'), '-I' + path.join(javaHome, 'include', platformInclude),
      source, '-o', binary, ...(process.platform === 'darwin' ? [] : ['-ldl'])]);
  }

  // 加入该 JDK 的 bin 只影响测试进程，以供 Windows JVM 查找其已有依赖。
  const env = { ...process.env };
  // 基线不受启动此脚本的宿主隐式 JVM 参数污染；两个负例只向各自 native 子进程注入。
  // 不读改系统环境，也不假定 launcher 专用的 JDK_JAVA_OPTIONS 被 Invocation API 消费。
  for (const name of Object.keys(env)) {
    if (['_JAVA_OPTIONS', 'JAVA_TOOL_OPTIONS'].includes(name.toUpperCase())) delete env[name];
  }
  if (windows) {
    for (const name of Object.keys(env)) if (name.toUpperCase() === 'PATH') delete env[name];
    env.PATH = path.join(javaHome, 'bin') + path.delimiter + (process.env.PATH ?? process.env.Path ?? '');
  }
  const cases = [
    { name: 'system-exit-0', action: 'system-exit-0', mode: 'exit', code: 0, shutdown: true },
    { name: 'system-exit-7', action: 'system-exit-7', mode: 'exit', code: 7, shutdown: true },
    { name: 'runtime-halt-9', action: 'runtime-halt-9', mode: 'exit', code: 9, shutdown: false },
    { name: 'main-return', action: 'main-return', mode: 'exit', code: 0, shutdown: true },
    { name: 'returning-hook-exit-7', action: 'system-exit-7', mode: 'return', code: 7, shutdown: true },
    { name: 'returning-hook-halt-9', action: 'runtime-halt-9', mode: 'return', code: 9, shutdown: false },
    { name: 'env-user-options-exit-7', action: 'system-exit-7', mode: 'exit', code: 7,
      shutdown: true, hook: false, environment: { _JAVA_OPTIONS: 'exit' } },
    { name: 'env-tool-options-exit-7', action: 'system-exit-7', mode: 'exit', code: 7,
      shutdown: true, hook: true, environment: { JAVA_TOOL_OPTIONS: 'exit' } },
  ];
  for (const sample of cases) {
    const marker = path.join(temp, sample.name + '.native');
    const shutdownMarker = path.join(temp, sample.name + '.java');
    const childEnv = { ...env, ...(sample.environment ?? {}) };
    const result = run(binary, [jvm, classes, sample.action, sample.mode, marker, shutdownMarker], childEnv, sample.code, 20000);
    assert.match(result.stdout, new RegExp('FIXTURE_READY action=' + sample.action));
    const actual = readFileSync(marker, 'utf8');
    const expectsHook = sample.hook ?? sample.action !== 'main-return';
    const expected = !expectsHook ? '' : `EXIT_HOOK code=${sample.code}\n`
      + (sample.mode === 'return' ? `HOOK_RETURNS code=${sample.code}\n` : '');
    assert.equal(actual, expected, sample.name + ': exact native callback trace');
    assert.equal(existsSync(shutdownMarker), sample.shutdown, sample.name + ': Java shutdown hook presence');
    if (sample.shutdown) assert.equal(readFileSync(shutdownMarker, 'utf8'), 'SHUTDOWN_HOOK\n');
    if (sample.action === 'main-return') {
      assert.match(result.stdout, /MAIN_RETURNED\r?\nDESTROY_RETURNED code=0/);
    } else {
      assert.doesNotMatch(result.stdout, /MAIN_RETURNED|DESTROY_RETURNED/);
    }
    if (sample.environment) assert.match(result.stderr, /Picked up (?:_JAVA_OPTIONS|JAVA_TOOL_OPTIONS): exit/);
    console.log(`PASS ${sample.name}: OS=${sample.code}, invocationHook=${expectsHook}, shutdownHook=${sample.shutdown}`);
  }
  console.log('[jvm-exit-invocation] PASS ' + cases.length + ' real host JVM cases; JNI semantics only, not OHOS/appspawn or production-hook verification');
} catch (error) {
  console.error('[jvm-exit-invocation] FAIL ' + (error.stack ?? error));
  process.exitCode = 1;
} finally {
  // 只删除本脚本 mkdtemp 的真实精确路径；不接受外部提供目录作为递归清理目标。
  const resolved = realpathSync(temp);
  assert.equal(path.dirname(resolved), realpathSync(tmpdir()));
  assert.ok(path.basename(resolved).startsWith('amcl-jvm-exit-invocation-'));
  rmSync(resolved, { recursive: true, force: true });
}

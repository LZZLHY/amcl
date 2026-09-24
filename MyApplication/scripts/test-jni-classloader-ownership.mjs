#!/usr/bin/env node
/**
 * 运行真实 JVM/JNI 所有权回归，而不是仅检查源码包含某个字符串。
 * 产品 CallbackBridge、jni_registry.cpp、jni_reregister.c 原样参与编译；仅日志、设备输入
 * 和 Windows 的 POSIX 兼容层由测试桩替换。每个用例使用全新 JVM，支持 MSVC 与 POSIX CC。
 * 所有编译产物位于唯一临时目录；失败保留诊断文本，退出时只清理本次创建的精确目录。
 */
import { existsSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('..', import.meta.url));
const cpp = join(root, 'entry/src/main/cpp');
const fixture = join(cpp, 'tests/host/jni_bridge');
const temp = mkdtempSync(join(tmpdir(), 'amcl-jni-ownership-'));

/** 同步前台执行，并打印编译/运行原始输出；任何失败都终止，禁止降级为“静态检查通过”。 */
function run(program, args, env = process.env) {
  const result = spawnSync(program, args, { cwd: temp, env, encoding: 'utf8', timeout: 120000 });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  if (result.error || result.status !== 0) throw new Error(`${program} failed: ${result.error ?? result.status}`);
  return result.stdout ?? '';
}

/** 读取已安装 MSVC 的环境，不安装工具链、不改用户全局 PATH。 */
function msvcEnvironment() {
  const vswhere = [
    'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe',
    'D:/Microsoft Visual Studio/Installer/vswhere.exe',
  ].find(existsSync);
  if (!vswhere) throw new Error('MSVC vswhere not found; real JNI test requires a host C/C++ compiler');
  const installation = run(vswhere, ['-latest', '-products', '*',
    '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
  const vcvars = join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
  if (!existsSync(vcvars)) throw new Error(`MSVC environment not found: ${vcvars}`);
  const result = spawnSync(process.env.ComSpec ?? 'cmd.exe', ['/d', '/s', '/c',
    `"call "${vcvars}" >nul && set"`], { encoding: 'utf8', windowsVerbatimArguments: true });
  if (result.status !== 0) throw new Error(`MSVC initialization failed: ${result.stderr}`);
  // Windows 环境变量名不区分大小写：避免同时传递 Path/PATH 导致 Node 选中错误旧值。
  const env = {};
  for (const [key, value] of Object.entries(process.env)) env[key.toUpperCase()] = value;
  for (const line of result.stdout.split(/\r?\n/)) {
    const index = line.indexOf('=');
    if (index > 0) env[line.slice(0, index).toUpperCase()] = line.slice(index + 1);
  }
  return env;
}

try {
  const classes = join(temp, 'classes');
  const callbackClasses = join(temp, 'callback-classes');
  const missingClasses = join(temp, 'missing-method-classes');
  for (const path of [classes, callbackClasses, missingClasses]) mkdirSync(path);
  const java = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'java.exe' : 'java') : 'java';
  const javac = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'javac.exe' : 'javac') : 'javac';
  // -source/-target 8 也允许 JDK 8 自身参与回归，现代 Java 编译器给出的 bootstrap warning 不影响产物。
  run(javac, ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', classes, join(fixture, 'NativeOwnershipTest.java')]);
  run(javac, ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', callbackClasses,
    join(root, 'prebuilt/lwjgl3/ohos-glfw/src/org/lwjgl/glfw/CallbackBridge.java')]);
  run(javac, ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', missingClasses,
    join(fixture, 'missing_methods/org/lwjgl/glfw/CallbackBridge.java')]);

  let hostLibrary;
  if (process.platform === 'win32') {
    const env = msvcEnvironment();
    hostLibrary = join(temp, 'bridge_host_fixture.dll');
    const common = ['/nologo', '/LD', '/MD', '/W4', '/D_CRT_SECURE_NO_WARNINGS',
      '/DAMCL_JNI_BRIDGE_HOST_TEST', '/DJNIEXPORT=__declspec(dllexport)', `/I${join(fixture, 'win32')}`];
    run('cl.exe', [...common, '/std:c++17', '/EHsc', join(fixture, 'bridge_host_fixture.cpp'),
      join(cpp, 'jvm/jni_registry.cpp'), '/link', `/OUT:${hostLibrary}`], env);
    run('cl.exe', [...common, '/TC', '/std:c11', join(cpp, 'glfw/jni_reregister.c'),
      '/link', `/OUT:${join(temp, 'jni_reregister.dll')}`], env);
  } else {
    hostLibrary = join(temp, 'libbridge_host_fixture.so');
    const common = ['-shared', '-fPIC', '-D_GNU_SOURCE', '-DAMCL_JNI_BRIDGE_HOST_TEST', '-O0', '-g'];
    run(process.env.CXX ?? 'c++', [...common, '-std=c++17', join(fixture, 'bridge_host_fixture.cpp'),
      join(cpp, 'jvm/jni_registry.cpp'), '-o', hostLibrary]);
    run(process.env.CC ?? 'cc', [...common, '-std=c11', join(cpp, 'glfw/jni_reregister.c'),
      '-ldl', '-o', join(temp, 'libjni_reregister.so')]);
  }

  const cases = ['child-first', 'delegated-parent', 'parent-preload-conflict', 'two-isolated-consumers',
    'missing', 'wrong-pid', 'bad-address', 'bad-symbol', 'bad-text', 'overflow', 'trailing-data',
    'bad-abi', 'bad-magic', 'bad-size', 'bad-session', 'bad-reserved', 'null-bind', 'foreign-bind', 'revoked', 'missing-method'];
  for (const name of cases) {
    const output = run(java, [`-Djava.library.path=${temp}`, '-cp', classes,
      'NativeOwnershipTest', name, hostLibrary, name === 'missing-method' ? missingClasses : callbackClasses]);
    if (!output.includes(`PASS ${name} `)) throw new Error(`case did not prove completion: ${name}`);
  }
  console.log(`[test-jni-classloader-ownership] PASS ${cases.length} real JVM/JNI cases`);
} catch (error) {
  console.error(`[test-jni-classloader-ownership] FAIL ${error.stack ?? error}`);
  process.exitCode = 1;
} finally {
  // temp 是本脚本的 mkdtemp 返回值，绝不使用 workspace/home 或用户提供的路径递归删除。
  rmSync(temp, { recursive: true, force: true });
}

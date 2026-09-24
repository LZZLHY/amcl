#!/usr/bin/env node
/**
 * 编译并执行 SDL 宿主归属回归：输入只来自 pinned SDL.c 和下游 0013 补丁。
 * 不改第三方源码树、不构建共享 SDL/HAP；测试抽取真实 InitSubSystem、递归计数和
 * host-runtime 函数，仅以宿主桩替代设备子系统，检验初始化入口和失败回滚顺序。
 * --repo 严格指定含锁定 commit 的只读 SDL 仓库；默认无仓库时采用逐字节冻结的上游
 * fixture，--fixture-only 强制离线路径。任何输入损坏或缺编译器均失败，不降级为 PASS。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stripComments, stripStringLiterals } from './lib/source-noise.mjs';
import { loadSdlHostFixture, selectSdlHostSourceRepo, testSdlHostSourceRejections,
  verifySdlHostFixture } from './lib/sdl3-host-runtime-sources.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const patchName = '0013-openharmony-host-runtime-ownership.patch';
const patchFile = path.join(root, 'prebuilt/sdl3/patches', patchName);
const repoArg = process.argv.indexOf('--repo');
assert.ok(repoArg < 0 || (process.argv[repoArg + 1] && !process.argv[repoArg + 1].startsWith('--')), '--repo 必须带目录');
const repo = selectSdlHostSourceRepo({
  explicitRepo: repoArg >= 0 ? path.resolve(process.argv[repoArg + 1]) : undefined,
  fixtureOnly: process.argv.includes('--fixture-only'),
  candidates: [path.join(root, 'prebuilt/sdl3/sdl3_src'), path.resolve(root, '../sdl3-ohos')],
});
const pin = fs.readFileSync(path.join(root, 'deps.lock'), 'utf8')
  .match(/^\[sdl3-native\]\s*$[\s\S]*?^commit\s*=\s*([a-f0-9]{40})/m)?.[1];
assert.ok(pin, 'SDL 必须使用锁定 commit');

/** 运行前台命令并保留原始错误；没有宿主编译能力不能冒充运行测试通过。 */
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} 失败: ${result.error?.message ?? result.status}\n${result.stdout ?? ''}\n${result.stderr ?? ''}`);
  }
  return result.stdout;
}

/**
 * 在内存中严格应用 unified hunks；匹配旧正文而非信任行号偏移，且每段恰好命中一次。
 * 这既避免修改上游 worktree，也让补丁锚点漂移成为测试错误。
 */
function patchedFile(patch, name, original) {
  const block = patch.split(/^diff --git /m).find((part) => part.startsWith(`a/${name} b/${name}\n`));
  assert.ok(block, `补丁必须包含 ${name}`);
  if (original === null) {
    assert.ok(block.includes('--- /dev/null\n'));
    return block.split('\n').filter((line) => line.startsWith('+') && !line.startsWith('+++')).map((line) => line.slice(1)).join('\n') + '\n';
  }
  let output = original;
  for (const hunk of block.split(/^@@[^\n]*\n/m).slice(1)) {
    const lines = hunk.split('\n').filter((line) => /^[ +\-]/.test(line));
    const before = lines.filter((line) => !line.startsWith('+')).map((line) => line.slice(1)).join('\n') + '\n';
    const after = lines.filter((line) => !line.startsWith('-')).map((line) => line.slice(1)).join('\n') + '\n';
    assert.ok(output.includes(before), `hunk 必须匹配实际基线 ${name}: ${before.slice(0, 90)}`);
    assert.equal(output.indexOf(before), output.lastIndexOf(before), 'hunk 旧正文必须唯一');
    output = output.replace(before, after);
  }
  return output;
}

/** 用共享 C 词法器剥注释与字符串，再按平衡花括号提取真实生产函数。 */
function extractFunction(source, name) {
  const mask = stripStringLiterals(stripComments(source, { lang: 'c' }), { lang: 'c' });
  const start = new RegExp(`(?:static\\s+)?(?:inline\\s+)?(?:bool|void|int)\\s+${name}\\s*\\([^;{}]*\\)\\s*\\{`).exec(mask);
  assert.ok(start, `生产函数不存在: ${name}`);
  let end = start.index + start[0].length;
  let depth = 1;
  while (depth && end < mask.length) {
    if (mask[end] === '{') depth++;
    if (mask[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0);
  return source.slice(start.index, end);
}

/**
 * MSVC 不必处于 PATH；通过微软固定的 vswhere 入口解析 vcvars64 环境。
 * cmd 仅用于读取环境，编译和可执行文件始终使用参数数组，不拼接文件操作命令。
 */
function compilerEnvironment() {
  if (process.platform !== 'win32') return { compiler: process.env.CXX || 'c++', env: process.env, msvc: false };
  const vswhere = path.join(process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Microsoft Visual Studio/Installer/vswhere.exe');
  const installation = run(vswhere, ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
  const vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
  assert.ok(fs.existsSync(vcvars));
  const output = run(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${vcvars}" >nul && set"`], { windowsVerbatimArguments: true });
  const env = { ...process.env };
  for (const key of Object.keys(env)) if (key.toLowerCase() === 'path') delete env[key];
  for (const line of output.split(/\r?\n/)) {
    const separator = line.indexOf('=');
    if (separator > 0) env[line.slice(0, separator)] = line.slice(separator + 1);
  }
  return { compiler: 'cl.exe', env, msvc: true };
}

const patch = fs.readFileSync(patchFile, 'utf8').replace(/\r\n/g, '\n');
assert.ok(fs.readFileSync(path.join(root, 'prebuilt/sdl3/patches/series'), 'utf8').split(/\r?\n/).includes(patchName));
const header = patchedFile(patch, 'src/core/openharmony/SDL_amclhostruntime.h', null);
const fixture = loadSdlHostFixture(root, pin);
testSdlHostSourceRejections(fixture, pin);
let sources = fixture.buffers;
if (repo) {
  // 读 commit 对象而非脏工作树；缺 pin 直接失败，同步比对 fixture 防止两套测试漂移。
  sources = new Map(fixture.manifest.files.map(({ path: name }) =>
    [name, Buffer.from(run('git', ['-C', repo, 'show', `${pin}:${name}`]), 'utf8')]));
  verifySdlHostFixture(fixture.manifest, sources, pin);
  for (const [name, bytes] of sources) assert.ok(bytes.equals(fixture.buffers.get(name)), `repo/fixture 字节不同: ${name}`);
}
console.log(`[SDL host-runtime] input=${repo ? 'git+verified-fixture' : 'verified-fixture'} commit=${pin}`);
const original = sources.get('src/SDL.c').toString('utf8');
const core = patchedFile(patch, 'src/SDL.c', original);
const events = patchedFile(patch, 'src/events/SDL_events.c', sources.get('src/events/SDL_events.c').toString('utf8'));
const init = extractFunction(core, 'SDL_InitSubSystem');
const pump = extractFunction(events, 'SDL_PumpEventsInternal');
assert.ok(init.indexOf('SDL_AMCL_PrepareHostRuntime()') < init.indexOf('if (!SDL_MainIsReady)'));
assert.ok(pump.indexOf('SDL_AMCL_ValidateEventThread(true)') < pump.indexOf('SDL_assert(SDL_IsMainThread())'));
const wait = extractFunction(events, 'SDL_WaitEventTimeoutNS');
assert.ok(wait.indexOf('SDL_AMCL_ValidateEventThread(false)') < wait.indexOf('if (timeoutNS > 0)'));
assert.ok(wait.indexOf('SDL_AMCL_ValidateEventThread(false)') < wait.indexOf('SDL_PeepEventsInternal('));
assert.ok(extractFunction(core, 'SDL_Quit').indexOf('SDL_AMCL_RetireHostRuntime()') < extractFunction(core, 'SDL_Quit').indexOf('SDL_bInMainQuit = true'));
assert.ok(!/JNI_OnLoad|dlopen\s*\(|__attribute__\s*\(\(constructor/.test(header + core.slice(core.indexOf('static AMCL_SdlHostRuntime'), core.indexOf('// Private helper to increment'))));

const productionFunctions = [
  'SDL_AMCL_HostError', 'SDL_AMCL_PrepareHostRuntime', 'SDL_AMCL_RetireHostRuntime',
  'SDL_AMCL_ValidateEventThread', 'SDL_IncrementSubsystemRefCount', 'SDL_DecrementSubsystemRefCount',
  'SDL_ShouldInitSubsystem', 'SDL_InitOrIncrementSubsystem', 'SDL_SetMainReady', 'SDL_InitSubSystem', 'SDL_Init',
].map((name) => extractFunction(core, name)).join('\n\n');
const harness = fs.readFileSync(path.join(root, 'prebuilt/sdl3/tests/host-runtime-test.cpp'), 'utf8');
assert.equal(harness.split('/* AMCL_PRODUCTION_FUNCTIONS */').length, 2);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'amcl-sdl-host-'));
try {
  fs.writeFileSync(path.join(temporary, 'SDL_amclhostruntime.h'), header);
  fs.writeFileSync(path.join(temporary, 'host-runtime-test.cpp'), harness.replace('/* AMCL_PRODUCTION_FUNCTIONS */', productionFunctions));
  const compiler = compilerEnvironment();
  const executable = path.join(temporary, compiler.msvc ? 'host-runtime-test.exe' : 'host-runtime-test');
  const compileArgs = compiler.msvc
    ? ['/nologo', '/std:c++17', '/EHsc', '/W4', '/WX', '/utf-8', 'host-runtime-test.cpp', `/Fe:${executable}`]
    : ['-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror', 'host-runtime-test.cpp', '-o', executable];
  process.stdout.write(run(compiler.compiler, compileArgs, { cwd: temporary, env: compiler.env }));
  process.stdout.write(run(executable, [], { cwd: temporary, env: compiler.env }));
  console.log('[SDL host-runtime] pinned entrypoint, state, recursion, thread and rollback tests PASS');
} finally {
  // 只清理本次 mkdtemp 创建且已经验证前缀的测试目录，不触碰仓库或用户资料。
  assert.ok(temporary.startsWith(path.join(os.tmpdir(), 'amcl-sdl-host-')));
  fs.rmSync(temporary, { recursive: true, force: true });
}

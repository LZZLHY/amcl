#!/usr/bin/env node
/**
 * 公开仓库首次构建的依赖入口。复用 setup_deps.sh 的 MobileGlues、LWJGL、
 * OpenAL/OHAudio 和 SDL 准备流程，并补齐该脚本尚未覆盖的 MobileGL 及 glslang
 * External 依赖。所有版本来自 deps.lock / 子模块 gitlink / known_good.json。
 * 默认准备依赖；--check 仅检查现有目录，不联网、不修改文件。
 * 不覆盖有修改的第三方工作树，不修改锁文件，不编译或安装 HarmonyOS SDK。
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// MobileGL 的 LFS 内容仅供可选 trace_replay 工具使用；普通 HAP 不消费这些
// 大型回放夹具。保留 LFS 指针，避免源码 checkout 隐式下载与构建无关的文件。
const environment = { ...process.env, GIT_LFS_SKIP_SMUDGE: '1' };
const checkOnly = process.argv.includes('--check');
if (process.argv.slice(2).some(arg => arg !== '--check')) throw new Error('Usage: node scripts/prepare-public-deps.mjs [--check]');
const lock = {};
let section;
for (const line of fs.readFileSync(path.join(root, 'deps.lock'), 'utf8').split(/\r?\n/)) {
  const header = line.match(/^\[([^\]]+)\]/);
  if (header) { section = lock[header[1]] = {}; continue; }
  const field = line.match(/^([\w]+)\s*=\s*([^#]*?)(?:\s*#.*)?$/);
  if (section && field) section[field[1]] = field[2].trim();
}
/** Git 输出只用于版本校验；失败时保留命令错误并退出，避免伪造“依赖已准备”。 */
function git(cwd, ...args) {
  return execFileSync('git', ['-c', 'core.longpaths=true', '-C', cwd, ...args],
    { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env: environment }).trim();
}
function run(command, args, cwd = root) {
  console.log(`[public-deps] ${path.basename(command)} ${args.join(' ')}`);
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', env: environment });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${path.basename(command)} failed: ${result.status}`);
}
function assertPin(relative, pin, allowPatched = false) {
  const directory = path.join(root, relative);
  if (!fs.existsSync(path.join(directory, '.git'))) throw new Error(`Dependency not initialized: ${relative}`);
  const head = git(directory, 'rev-parse', 'HEAD');
  if (head !== pin) throw new Error(`${relative}: expected ${pin}, got ${head}`);
  if (!allowPatched && git(directory, 'status', '--porcelain', '--untracked-files=no')) {
    throw new Error(`Dependency has local changes; preserve them before preparing: ${relative}`);
  }
}

const modules = [['mobileglues', 'prebuilt/mobileglues/mg_src'],
  ['lwjgl-natives', 'prebuilt/lwjgl3/lwjgl3_src'], ['mobilegl', 'prebuilt/mobilegl/src']];
for (const [name, relative] of modules) {
  const pin = lock[name]?.commit;
  if (!/^[a-f0-9]{40}$/.test(pin ?? '')) throw new Error(`Invalid ${name}.commit`);
  // .gitmodules 必须位于公开仓库根目录，且索引里必须存在 160000 gitlink。
  // 仅复制 MyApplication/.gitmodules 无法让 Git 恢复嵌套工程的依赖。
  const indexed = git(root, 'ls-files', '--stage', '--', relative).match(/^160000\s+([a-f0-9]{40})\s/);
  if (indexed?.[1] !== pin) throw new Error(`Missing/mismatched public gitlink: ${relative}; clone the complete public repository, not a ZIP or a copied subfolder`);
  const directory = path.join(root, relative);
  if (!checkOnly) {
    if (fs.existsSync(path.join(directory, '.git')) && git(directory, 'status', '--porcelain', '--untracked-files=no')) {
      throw new Error(`Refusing to update dirty dependency: ${relative}`);
    }
    run('git', ['-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--filter=blob:none', '--depth', '64', '--', relative]);
  }
  assertPin(relative, pin);
}

if (!checkOnly) {
  // Git for Windows 自带 Bash，避免误用 Windows 的 WSL bash 占位命令。
  let bash = process.env.AMCL_BASH || 'bash';
  if (process.platform === 'win32' && !process.env.AMCL_BASH) {
    const execPath = git(root, '--exec-path');
    const bundled = path.resolve(execPath, '../../..', 'bin/bash.exe');
    if (!fs.existsSync(bundled)) throw new Error('Set AMCL_BASH to Git for Windows bin/bash.exe');
    bash = bundled;
  }
  run(bash, ['setup_deps.sh']);
}
assertPin('entry/src/main/cpp/openal/openal-soft', lock['openal-soft'].commit, true);
// OpenAL 的两处 OHAudio 接线由 setup_deps.sh 修改；版本相符不能代替补丁已应用。
const alc = fs.readFileSync(path.join(root, 'entry/src/main/cpp/openal/openal-soft/alc/alc.cpp'), 'utf8');
if (!alc.includes('#include "ohaudio.h"') || !alc.includes('OHAudioBackendFactory::getFactory')) {
  throw new Error('OpenAL OHAudio wiring missing; preserve the existing directory and rerun setup in a clean checkout');
}
// 只允许受版本控制的 OHAudio 补丁；发现其他本地补丁时明确失败，不能
// 因为 HEAD 正确且出现两个标识符，就把任意 OpenAL 工作树称作锁定源码。
const openal = path.join(root, 'entry/src/main/cpp/openal/openal-soft');
const lf = text => text.replace(/\r\n/g, '\n');
const upstreamFile = relative => execFileSync('git', ['-C', openal, 'show', `HEAD:${relative}`], { encoding: 'utf8' });
const expectedAlc = lf(upstreamFile('alc/alc.cpp'))
  .replace('#include "backends/null.h"\n', '#include "backends/null.h"\n#if HAVE_OHAUDIO\n#include "ohaudio.h"\n#endif\n')
  .replace(/^(.*BackendInfo\{"null", NullBackendFactory::getFactory\}.*)$/m,
    '#if HAVE_OHAUDIO\n    BackendInfo{"ohaudio", OHAudioBackendFactory::getFactory},\n#endif\n$1');
const expectedConfig = lf(upstreamFile('config_backends.h.in'));
const changedOpenal = git(openal, 'diff', 'HEAD', '--name-only').split('\n').filter(Boolean);
if (lf(alc) !== expectedAlc || lf(fs.readFileSync(path.join(openal, 'config_backends.h.in'), 'utf8')) !== expectedConfig
    || changedOpenal.some(relative => relative !== 'alc/alc.cpp')) {
  throw new Error('OpenAL worktree differs from the exact OHAudio recipe in setup_deps.sh');
}
assertPin('prebuilt/sdl3/sdl3_src', lock['sdl3-native'].commit);
const mg = path.join(root, 'prebuilt/mobileglues/mg_src');
for (const relative of ['MobileGlues-cpp/3rdparty/glslang', 'MobileGlues-cpp/3rdparty/SPIRV-Cross',
  'MobileGlues-cpp/3rdparty/xxhash', 'MobileGlues-cpp/include/ska']) {
  const pin = git(mg, 'ls-files', '--stage', '--', relative).match(/^160000\s+([a-f0-9]{40})\s/)?.[1];
  assertPin(`prebuilt/mobileglues/mg_src/${relative}`, pin);
}

const mobile = path.join(root, 'prebuilt/mobilegl/src');
// Diligent/tracy/apitrace 是可选开发工具；Asio 则由生产着色器编译线程池消费。
// 只初始化当前 OHOS 配方实际消费的依赖，避开开发工具的额外大型源码。
const nested = ['3rdparty/glslang', '3rdparty/SPIRV-Cross', '3rdparty/xxHash',
  '3rdparty/VulkanMemoryAllocator', '3rdparty/Vulkan-Headers',
  '3rdparty/Vulkan-Utility-Libraries', '3rdparty/SPIRV-Reflect', '3rdparty/asio', 'include/ska'];
if (!checkOnly) run('git', ['-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--depth', '1', '--', ...nested], mobile);
for (const relative of nested) {
  const pin = git(mobile, 'ls-files', '--stage', '--', relative).match(/^160000\s+([a-f0-9]{40})\s/)?.[1];
  assertPin(`prebuilt/mobilegl/src/${relative}`, pin);
}
// known_good 描述的 External 不是 Git 子模块。只准备编译需要的两个项目，并且
// 同时核对 deps.lock，拒绝“上游已漂移但本仓还没更新”的混合依赖组合。
const glslang = path.join(mobile, '3rdparty/glslang');
const known = JSON.parse(fs.readFileSync(path.join(glslang, 'known_good.json'), 'utf8'));
for (const [name, lockKey] of [['spirv-tools', 'spirv_tools_commit'],
  ['spirv-tools/external/spirv-headers', 'spirv_headers_commit']]) {
  const dependency = known.commits.find(item => item.name === name);
  if (!dependency || dependency.commit !== lock.mobilegl[lockKey] || dependency.site !== 'github') {
    throw new Error(`MobileGL known_good/deps.lock mismatch: ${name}`);
  }
  const directory = path.resolve(glslang, dependency.subdir);
  if (!directory.startsWith(glslang + path.sep)) throw new Error('External dependency path escapes glslang');
  if (!checkOnly && !fs.existsSync(path.join(directory, '.git'))) {
    if (fs.existsSync(directory) && fs.readdirSync(directory).length) throw new Error(`Nonempty dependency directory: ${dependency.subdir}`);
    fs.mkdirSync(directory, { recursive: true });
    run('git', ['init', '--quiet'], directory);
    run('git', ['remote', 'add', 'origin', `https://github.com/${dependency.subrepo}.git`], directory);
  }
  if (!checkOnly) {
    // 上次 git init/fetch 被网络中断后允许继续，但已有源码改动仍由 assertPin 拦截。
    const head = spawnSync('git', ['-C', directory, 'rev-parse', '--verify', 'HEAD'], { encoding: 'utf8', env: environment });
    if (head.status !== 0 || head.stdout.trim() !== dependency.commit) {
      const untracked = git(directory, 'ls-files', '--others', '--exclude-standard');
      const dirty = head.status === 0 ? git(directory, 'status', '--porcelain', '--untracked-files=no') : '';
      if (untracked || dirty) throw new Error(`Uncommitted files in dependency: ${name}`);
      run('git', ['fetch', '--depth', '1', '--no-tags', `https://github.com/${dependency.subrepo}.git`, dependency.commit], directory);
      run('git', ['checkout', '--quiet', '--detach', dependency.commit], directory);
    }
  }
  assertPin(path.relative(root, directory), dependency.commit);
}
run(process.execPath, ['scripts/check-mobilegl-pin.mjs', '--offline']);
// 公开快照交付的固定产物仍须通过原工程的来源与字节校验，不能仅检查文件存在。
run(process.execPath, ['scripts/check-mobilegl-build-contract.mjs',
  ...(checkOnly ? [] : ['--prepare']), '--product', 'default']);
run(process.execPath, ['scripts/check-mg-snapshot.mjs']);
run(process.execPath, ['scripts/check-sdl3-artifact.mjs']);
console.log('[public-deps] PASS: locked HAP source dependencies and MobileGL/SDL artifacts verified. Next run Hvigor; this is not a HAP build result.');

/** 路径策略回归：验证真实文件系统边界、克隆隔离与环境覆盖，避免仅断言实现字符串。 */
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolveWorkspacePath, assertExternalOutputPath, workspacePath } from './lib/workspace-paths.mjs';

const fixture = mkdtempSync(path.join(os.tmpdir(), 'amcl-path-policy-'));
try {
  const workspace = path.join(fixture, 'workspace');
  const project = path.join(workspace, 'MyApplication');
  mkdirSync(path.join(project, '.git'), { recursive: true });
  mkdirSync(path.join(workspace, '.workspace'), { recursive: true });
  writeFileSync(path.join(workspace, 'AGENTS.md'), '# Fixture workspace');
  const options = { root: project, env: {} };
  const output = resolveWorkspacePath('build', 'native', options);
  assert.equal(path.dirname(output), path.join(workspace, '.workspace/build'));
  assert.equal(output, resolveWorkspacePath('build', 'native', options), '同一克隆缓存位置必须稳定');
  assert.notEqual(output, resolveWorkspacePath('build', 'native', { root: path.join(workspace, 'clone'), env: {} }));
  assert.equal(existsSync(output), false, '只解析路径不得创建输出');

  const detached = path.join(fixture, 'standalone');
  mkdirSync(path.join(detached, '.git'), { recursive: true });
  const fallback = resolveWorkspacePath('build', 'native', { root: detached, env: {} });
  assert.ok(fallback.startsWith(path.join(os.tmpdir(), 'amcl-workspace/build')));
  assert.ok(!fallback.startsWith(detached + path.sep));
  const run = path.join(workspace, '.workspace/run/task');
  assert.equal(resolveWorkspacePath('run', 'capture', { root: project, env: { AMCL_RUN_DIR: run } }), path.join(run, 'capture'));
  const custom = path.join(fixture, 'custom');
  assert.equal(path.dirname(resolveWorkspacePath('build', 'native', { root: detached, env: { AMCL_WORKSPACE_ROOT: custom } })), path.join(custom, '.workspace/build'));

  assert.throws(() => assertExternalOutputPath(path.join(project, 'logs'), { root: project }), /outside the project/);
  assert.throws(() => resolveWorkspacePath('run', 'capture', { root: project, env: { AMCL_RUN_DIR: project } }), /outside the project/);
  assert.throws(() => resolveWorkspacePath('build', 'native', { root: project, env: { AMCL_WORKSPACE_ROOT: project } }), /outside the project/);
  assert.throws(() => resolveWorkspacePath('run', 'capture', { root: project, env: { AMCL_RUN_DIR: './relative' } }), /absolute/);
  for (const id of ['../escape', 'a/b', 'CON', '']) assert.throws(() => resolveWorkspacePath('build', id, options), /Invalid/);
  assert.throws(() => workspacePath('build', 'test', '../escape'), /Invalid output suffix/);

  // 外层公开仓库也不能放临时输出；仅比较 MyApplication 子目录不足以保证公开仓干净。
  const publicRoot = path.join(fixture, 'public');
  const nested = path.join(publicRoot, 'MyApplication');
  mkdirSync(path.join(publicRoot, '.git'), { recursive: true });
  mkdirSync(nested);
  assert.throws(() => assertExternalOutputPath(path.join(publicRoot, '.tmp'), { root: nested }), /outside Git repositories/);
  // Windows junction 无需管理员权限；Unix 使用目录符号链接，检测目标真实位置而非表面路径。
  const link = path.join(workspace, '.workspace/redirect');
  symlinkSync(project, link, process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => assertExternalOutputPath(path.join(link, 'new/log'), { root: project }), /outside the project/);

  const helper = fileURLToPath(new URL('./lib/workspace-paths.mjs', import.meta.url));
  const cli = spawnSync(process.execPath, [helper, 'build', 'native', project], { encoding: 'utf8', env: { ...process.env, AMCL_WORKSPACE_ROOT: workspace, AMCL_RUN_DIR: '' } });
  assert.equal(cli.status, 0, cli.stderr);
  assert.equal(cli.stdout.trim(), output);
  // 有人把全局 TEMP/TMPDIR 指向仓内时必须失败，不能因为使用了系统 API 就默认它安全。
  const badTemp = spawnSync(process.execPath, [helper, 'build', 'native', detached], {
    encoding: 'utf8', env: { ...process.env, AMCL_WORKSPACE_ROOT: '', AMCL_RUN_DIR: '', TEMP: detached, TMP: detached, TMPDIR: detached },
  });
  assert.notEqual(badTemp.status, 0);
  assert.match(badTemp.stderr, /outside the project/);
  // Python 会从 WSL 直接运行，不能依赖 Node；在同一真实夹具上校验它与 Node 的策略相同。
  const pythonHelper = fileURLToPath(new URL('./lib/workspace_paths.py', import.meta.url));
  const pythonCode = `import importlib.util,sys,pathlib,json
spec=importlib.util.spec_from_file_location('workspace_paths',sys.argv[1])
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
helper.PROJECT_ROOT=pathlib.Path(sys.argv[2]).resolve()
result=helper.workspace_path('build','native')
assert not result.exists()
try: helper.external_output_path(helper.PROJECT_ROOT/'cache')
except ValueError: pass
else: raise AssertionError('repository output accepted')
try: helper.external_output_path(pathlib.Path(sys.argv[3])/'new/log')
except ValueError: pass
else: raise AssertionError('symlink escape accepted')
with helper.temporary_directory(prefix='policy-fixture-') as temporary:
 assert str(temporary).startswith(str(helper.workspace_path('build','host-tests')))
 assert pathlib.Path(temporary).exists()
assert not pathlib.Path(temporary).exists()
print(result)`;
  const python = spawnSync(process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),
    ['-c', pythonCode, pythonHelper, project, link], {
      encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', AMCL_WORKSPACE_ROOT: workspace, AMCL_RUN_DIR: '' },
    });
  assert.equal(python.status, 0, python.stdout + python.stderr);
  assert.equal(python.stdout.trim(), output, 'Node/Python checkout 缓存身份必须相同');
  // 实际 CLI 必须在编译、HAP 读取或报告生成前拒绝仓内显式输出，不能只测 helper 而漏接调用口。
  const sourceRoot = fileURLToPath(new URL('../', import.meta.url));
  const rejectedOutput = path.join(sourceRoot, 'diagnostics', 'path-policy-negative', 'report.json');
  for (const [script, arguments_] of [
    ['benchmark-graphics-observer.py', ['--out', rejectedOutput]],
    ['graphics-profile-inventory.mjs', ['--out', rejectedOutput]],
    ['check-graphics-runtime-artifact.mjs', ['--hap', 'missing-fixture.hap', '--out', rejectedOutput]],
  ]) {
    const executable = script.endsWith('.py') ? (process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3')) : process.execPath;
    const rejected = spawnSync(executable, [path.join(sourceRoot, 'scripts', script), ...arguments_], {
      encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
    });
    assert.notEqual(rejected.status, 0, script);
    assert.match(rejected.stderr, /outside the project/, script);
    assert.equal(existsSync(rejectedOutput), false);
  }
  console.log('workspace path policy: discovery, external fallback, clone isolation, explicit paths and symlink escape PASS');
} finally {
  // fixture 是本测试独占的系统临时目录，先核验前缀再删除；绝不清理用户指定的输出根。
  assert.equal(path.dirname(fixture), path.resolve(os.tmpdir()));
  assert.ok(path.basename(fixture).startsWith('amcl-path-policy-'));
  rmSync(fixture, { recursive: true, force: true });
}

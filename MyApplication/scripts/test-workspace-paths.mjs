/** 路径策略回归：验证真实文件系统边界、克隆隔离与环境覆盖，避免仅断言实现字符串。 */
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolveWorkspacePath, assertExternalOutputPath, workspacePath } from './lib/workspace-paths.mjs';

// 夹具也走当前路由；维护工作区由 AMCL_RUN_DIR 显式收口，公开克隆可使用系统临时退路。
const fixtureParent = resolveWorkspacePath('run', 'path-policy-fixtures');
mkdirSync(fixtureParent, { recursive: true });
const fixture = mkdtempSync(path.join(fixtureParent, 'amcl-path-policy-'));
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

  // 夹具现在可能位于真实维护工作区D根之内，不能把其子目录误当“没有祖先标记”的
  // 独立clone。路径解析本来不要求root已存在：取同盘上不存在的逻辑根，既隔离祖先
  // 发现，也不在任务容器外创建任何文件或软件数据。
  const detached = path.join(path.parse(fixture).root, `amcl-standalone-${path.basename(fixture)}`);
  assert.equal(existsSync(detached), false);
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
  // 同一份真实路由文件交给 JS 与 Python，而非只断言源码字符串或各自复制期望算法。
  const routingFile = path.join(workspace, '.workspace/storage-routing.json');
  const canonical = path.join(workspace, '.workspace');
  const physicalStorage = path.join(fixture, 'new-storage');
  const routing = { schemaVersion: 1, status: 'ACTIVE_TEMPORARY_E_NEW_OUTPUTS_ONLY',
    canonicalStorageRoot: canonical, newStorageRoot: physicalStorage };
  const pythonRouteCode = `import importlib.util,sys,pathlib
spec=importlib.util.spec_from_file_location('workspace_paths',sys.argv[1])
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
helper.PROJECT_ROOT=pathlib.Path(sys.argv[2]).resolve()
print(helper.external_output_path(sys.argv[5]) if sys.argv[5] else helper.workspace_path(sys.argv[3],sys.argv[4]))`;
  const pythonRoute = (kind, env = {}, root = project, explicit = '') => spawnSync(
    process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),
    ['-B', '-c', pythonRouteCode, pythonHelper, root, kind, 'native', explicit], {
      encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', AMCL_WORKSPACE_ROOT: '', AMCL_RUN_DIR: '', ...env },
    });
  const sameRoute = (kind, env = {}, root = project) => {
    const javascript = resolveWorkspacePath(kind, 'native', { root, env });
    const python = pythonRoute(kind, env, root);
    assert.equal(python.status, 0, python.stdout + python.stderr);
    assert.equal(python.stdout.trim(), javascript, 'ACTIVE/环境/停用下 JS 与 Python 必须返回同一路径');
    return javascript;
  };
  const rejectedRouting = () => {
    assert.throws(() => resolveWorkspacePath('build', 'native', options), /Invalid storage routing/);
    const python = pythonRoute('build');
    assert.notEqual(python.status, 0);
    assert.match(python.stderr, /Invalid storage routing/);
  };
  const oldEvidence = path.join(canonical, 'old-evidence.txt');
  writeFileSync(oldEvidence, 'existing bytes stay here');
  writeFileSync(routingFile, JSON.stringify(routing));
  assert.equal(path.dirname(sameRoute('build')), path.join(physicalStorage, 'build'));
  assert.equal(path.dirname(sameRoute('wt')), path.join(physicalStorage, 'wt'));
  assert.equal(sameRoute('run', { AMCL_RUN_DIR: run }), path.join(physicalStorage, 'run/task/native'));
  assert.equal(path.dirname(sameRoute('build', { AMCL_WORKSPACE_ROOT: workspace })), path.join(physicalStorage, 'build'));
  assert.equal(existsSync(physicalStorage), false, '路由只计算新路径，不创建或迁移历史输出');
  assert.equal(existsSync(oldEvidence), true);

  // D SDK交接场景：旧控制根仍E，而新资料已明确回canonical D。执行真实JS helper/CLI，
  // 不能因legacy newStorageRoot还在就把调用者显式D的AMCL_RUN_DIR重新映回旧物理根。
  const restoredOutputRouting = { ...routing, status: 'ACTIVE_D_OUTPUT_DIRECTIVE_LEGACY_E_CONTROL',
    newOutputStorageRoot: canonical, resourceRegistryRoot: physicalStorage };
  writeFileSync(routingFile, JSON.stringify(restoredOutputRouting));
  assert.equal(resolveWorkspacePath('run', 'native', { root: project, env: { AMCL_RUN_DIR: run } }), path.join(run, 'native'));
  assert.equal(path.dirname(resolveWorkspacePath('build', 'native', options)), path.join(canonical, 'build'));
  const restoredCli = spawnSync(process.execPath, [helper, 'run', 'native', project], {
    encoding: 'utf8', env: { ...process.env, AMCL_WORKSPACE_ROOT: workspace, AMCL_RUN_DIR: run },
  });
  assert.equal(restoredCli.status, 0, restoredCli.stderr);
  assert.equal(restoredCli.stdout.trim(), path.join(run, 'native'));
  assert.equal(readFileSync(oldEvidence, 'utf8'), 'existing bytes stay here');
  writeFileSync(routingFile, JSON.stringify(routing));

  // 显式外部环境容器与 --out 是独立约定，不因工程路由被改写。
  assert.equal(path.dirname(sameRoute('build', { AMCL_WORKSPACE_ROOT: custom })), path.join(custom, '.workspace/build'));
  assert.equal(sameRoute('run', { AMCL_RUN_DIR: path.join(custom, 'capture') }), path.join(custom, 'capture/native'));
  const explicit = path.join(canonical, 'explicit-report.json');
  assert.equal(assertExternalOutputPath(explicit, { root: project }), explicit);
  assert.equal(pythonRoute('run', {}, project, explicit).stdout.trim(), explicit);
  const explicitCli = spawnSync(process.execPath, [helper, 'run', 'native', project, explicit], {
    encoding: 'utf8', env: { ...process.env, AMCL_WORKSPACE_ROOT: '', AMCL_RUN_DIR: '' },
  });
  assert.equal(explicitCli.status, 0, explicitCli.stderr);
  assert.equal(explicitCli.stdout.trim(), explicit);

  // 坏 JSON、相对物理根、canonical 冒充和重叠根都必须失败，不能默默写回旧 D 类容器。
  writeFileSync(routingFile, '{ broken');
  rejectedRouting();
  for (const invalid of [
    { ...routing, newStorageRoot: 'relative' },
    { ...routing, canonicalStorageRoot: path.join(fixture, 'unrelated') },
    { ...routing, newStorageRoot: path.join(canonical, 'nested') },
    { ...routing, newStorageRoot: link },
  ]) {
    writeFileSync(routingFile, JSON.stringify(invalid));
    rejectedRouting();
  }
  writeFileSync(routingFile, JSON.stringify({ ...routing, status: 'INACTIVE' }));
  assert.equal(sameRoute('build'), output, '显式停用时恢复原路径策略');
  writeFileSync(routingFile, JSON.stringify(routing));
  // 最近标记工作区拥有自己的约定；其无路由文件时不越级借用外层路由。
  const innerWorkspace = path.join(workspace, 'nested-workspace');
  const innerProject = path.join(innerWorkspace, 'MyApplication');
  mkdirSync(path.join(innerProject, '.git'), { recursive: true });
  mkdirSync(path.join(innerWorkspace, '.workspace'));
  writeFileSync(path.join(innerWorkspace, 'AGENTS.md'), '# Nested fixture workspace');
  assert.equal(path.dirname(sameRoute('build', {}, innerProject)), path.join(innerWorkspace, '.workspace/build'));
  assert.equal(readFileSync(oldEvidence, 'utf8'), 'existing bytes stay here');
  // Windows 常见的 UTF8 BOM 不改变有效配置；未知状态拼写则必须失败，不能当停用回流。
  writeFileSync(routingFile, '\uFEFF' + JSON.stringify(routing));
  assert.equal(path.dirname(sameRoute('build')), path.join(physicalStorage, 'build'));
  for (const status of ['ACTVE', 'ACTIVEbroken', 'disabled']) {
    writeFileSync(routingFile, JSON.stringify({ ...routing, status }));
    rejectedRouting();
  }
  writeFileSync(routingFile, JSON.stringify(routing));
  // 直接调用公开的 workspacePath(...parts)，证明任务根通过后，suffix 中的链接仍
  // 不能回流。复制被测模块到夹具工程只改变其 PROJECT_ROOT，不改写实现；正常兄弟
  // 路径先成功，再以同一份配置触发负控，避免导入/启动错误冒充预期拒绝。
  const fixtureHelper = path.join(project, 'scripts/lib/workspace-paths.mjs');
  mkdirSync(path.dirname(fixtureHelper), { recursive: true });
  writeFileSync(fixtureHelper, readFileSync(helper));
  const suffixEnv = { ...process.env, AMCL_WORKSPACE_ROOT: '', AMCL_RUN_DIR: run };
  const suffixProbe = suffix => spawnSync(process.execPath, ['--input-type=module', '-e',
    `const helper = await import(${JSON.stringify(pathToFileURL(fixtureHelper).href)}); console.log(helper.workspacePath('run', 'native', ${JSON.stringify(suffix)}, 'report.json'));`],
    { encoding: 'utf8', env: suffixEnv });
  const suffixBase = path.join(physicalStorage, 'run/task/native');
  mkdirSync(suffixBase, { recursive: true });
  const normalSuffix = suffixProbe('ordinary');
  assert.equal(normalSuffix.status, 0, normalSuffix.stderr);
  assert.equal(normalSuffix.stdout.trim(), path.join(suffixBase, 'ordinary/report.json'));
  symlinkSync(canonical, path.join(suffixBase, 'linked'), process.platform === 'win32' ? 'junction' : 'dir');
  const escapedSuffix = suffixProbe('linked');
  assert.notEqual(escapedSuffix.status, 0);
  assert.match(escapedSuffix.stderr, /escapes newStorageRoot/);
  const pythonSuffixCode = `import importlib.util,sys,pathlib
spec=importlib.util.spec_from_file_location('workspace_paths',sys.argv[1])
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
helper.PROJECT_ROOT=pathlib.Path(sys.argv[2]).resolve()
print(helper.workspace_path('run','native','linked','report.json'))`;
  const escapedPythonSuffix = spawnSync(process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),
    ['-B', '-c', pythonSuffixCode, pythonHelper, project],
    { encoding: 'utf8', env: { ...suffixEnv, PYTHONDONTWRITEBYTECODE: '1' } });
  assert.notEqual(escapedPythonSuffix.status, 0);
  assert.match(escapedPythonSuffix.stderr, /escapes newStorageRoot/);
  // 新根子目录即使指回仓外 canonical（原外置检查会放行），也不能造成物理回流。
  symlinkSync(canonical, path.join(physicalStorage, 'wt'), process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => resolveWorkspacePath('wt', 'native', options), /escapes newStorageRoot/);
  const rejectedMappedEscape = pythonRoute('wt');
  assert.notEqual(rejectedMappedEscape.status, 0);
  assert.match(rejectedMappedEscape.stderr, /escapes newStorageRoot/);
  console.log('workspace path policy: discovery, clone isolation, external fallback, cross-language ACTIVE/INACTIVE routing, malformed refusal and explicit/link boundaries PASS');
} finally {
  // 只回收本测试独占且已核前缀的子目录，绝不清理共享父容器或用户指定输出根。
  assert.equal(path.dirname(fixture), path.resolve(fixtureParent));
  assert.ok(path.basename(fixture).startsWith('amcl-path-policy-'));
  rmSync(fixture, { recursive: true, force: true });
}

#!/usr/bin/env node
/**
 * 布局门禁的行为/负向测试：只在外部独占夹具创建模拟项目及链接。
 * 允许工程工具缓存、正常依赖、项目 AGENTS 和凭据目录；禁止名称的任何物理类型均不能绕过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { checkWorkspaceLayout } from './check-workspace-layout.mjs';
import { createWorkspaceTemp, assertExternalOutputPath } from './lib/workspace-paths.mjs';

const fixture = createWorkspaceTemp('workspace-layout-');
const project = path.join(fixture, 'project');
const script = fileURLToPath(new URL('./check-workspace-layout.mjs', import.meta.url));
let checks = 0;
const check = (name, callback) => { callback(); checks++; console.log(`[workspace-layout-test] PASS ${name}`); };
try {
  fs.mkdirSync(project);
  for (const item of ['.git', '.secrets', '.hvigor', '.idea', 'node_modules', 'oh_modules',
    'docs/testing/evidence', 'entry/.cxx', 'entry/build', 'entry/src/tmp_algorithm',
    'prebuilt/mobilegl/src/.tmp-upstream', 'docker/scripts']) fs.mkdirSync(path.join(project, item), { recursive: true });
  fs.writeFileSync(path.join(project, 'AGENTS.md'), 'project rules');
  check('工程必需项和源码中的 tmp 名称允许', () => assert.deepEqual(checkWorkspaceLayout(project), []));

  const forbidden = ['.vscode', '.cursor', '.codex', '.claude', '.kiro', '.codegenie', '.logs', '.ua',
    '.tmp', '.tmp-build', '.tmp-anything', '.codex-repair', 'diagnostics', 'artifacts',
    'validation-packages', 'semantic-review', 'tmp_hypium', 'META-INF', 'docker/output'];
  check('明确禁止目录逐个被捕获', () => {
    for (const name of forbidden) {
      const item = path.join(project, name);
      fs.mkdirSync(item, { recursive: true });
      const findings = checkWorkspaceLayout(project);
      assert.deepEqual(findings.map(value => value.path), [name]);
      fs.rmdirSync(item);
    }
  });
  check('普通文件和大小写变体也不能伪装成空目录', () => {
    const item = path.join(project, '.VSCODE');
    fs.writeFileSync(item, 'not a directory');
    assert.equal(checkWorkspaceLayout(project)[0].kind, 'file');
    fs.unlinkSync(item);
  });
  check('目录联接/符号链接与失效链接由 lstat 检出', () => {
    const target = path.join(fixture, 'link-target');
    fs.mkdirSync(target);
    for (const name of ['.codex', 'docker/output']) {
      const link = path.join(project, name);
      fs.symlinkSync(target, link, process.platform === 'win32' ? 'junction' : 'dir');
      assert.equal(checkWorkspaceLayout(project)[0].kind, 'link/junction');
      fs.unlinkSync(link);
    }
    const broken = path.join(project, '.tmp-broken');
    fs.symlinkSync(target, broken, process.platform === 'win32' ? 'junction' : 'dir');
    fs.rmdirSync(target);
    assert.equal(checkWorkspaceLayout(project)[0].path, '.tmp-broken');
    fs.unlinkSync(broken);
  });
  check('CLI 违规退出非零，清理后退出零', () => {
    fs.mkdirSync(path.join(project, '.logs'));
    const failed = spawnSync(process.execPath, [script, '--root', project], { encoding: 'utf8' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /\.logs/);
    fs.rmdirSync(path.join(project, '.logs'));
    const passed = spawnSync(process.execPath, [script, '--root', project], { encoding: 'utf8' });
    assert.equal(passed.status, 0, passed.stderr);
  });
  console.log(`[workspace-layout-test] ${checks}/${checks} groups passed`);
} finally {
  // 只删除本测试通过 helper 独占创建的外部目录；不碰共享父目录或主项目。
  assertExternalOutputPath(fixture);
  if (fs.lstatSync(fixture).isSymbolicLink()) throw new Error('Refusing linked fixture cleanup');
  fs.rmSync(fixture, { recursive: true, force: true });
}

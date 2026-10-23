#!/usr/bin/env node
/**
 * 公开导出的真实Git小仓集成回归。构造四个真实gitlink，执行现役导出器，
 * 检查新增HDC身份、公开白名单、错误提交和脏源在写入前被拒绝。
 * 只替换与本测试无关的MobileGL二进制验收边界；不授予真实制品验收资格。
 * 本任务显式AMCL_RUN_DIR外置，独立克隆则使用系统临时目录，不改全局TEMP。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const tools = path.dirname(fileURLToPath(import.meta.url));
const parent = process.env.AMCL_RUN_DIR || os.tmpdir();
fs.mkdirSync(parent, { recursive: true });
const fixture = fs.mkdtempSync(path.join(parent, 'public-source-test-'));
const source = path.join(fixture, 'source');
const target = path.join(fixture, 'public');
const destination = path.join(target, 'MyApplication');
const script = path.join(target, 'tools/sync-source-snapshot.mjs');
const dependencies = ['prebuilt/lwjgl3/lwjgl3_src', 'prebuilt/mobileglues/mg_src',
  'prebuilt/mobilegl/src', 'prebuilt/hdc/muka-rust-hdc'];

/** 写入只属于本轮独占fixture的材料，不遍历或覆盖用户工程。 */
function write(root, relative, text) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}
/** Git参数保持独立，失败保留完整fixture供定位，不通过shell拼接命令。 */
function git(root, ...args) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function initialize(root) {
  fs.mkdirSync(root, { recursive: true });
  git(root, 'init');
  git(root, 'config', 'user.name', 'AMCL public export fixture');
  git(root, 'config', 'user.email', 'fixture@example.invalid');
  git(root, 'config', 'core.autocrlf', 'false');
}
function run(...args) {
  return spawnSync(process.execPath, [script, '--source', source, ...args], { encoding: 'utf8' });
}
function rejected(result, pattern) {
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, pattern);
}

initialize(source);
for (const dependency of dependencies) {
  const directory = path.join(source, dependency);
  initialize(directory);
  write(directory, 'LICENSE', 'Public test fixture license\n');
  git(directory, 'add', 'LICENSE');
  git(directory, 'commit', '-m', 'fixture dependency');
  git(source, 'update-index', '--add', '--cacheinfo', `160000,${git(directory, 'rev-parse', 'HEAD')},${dependency}`);
}
// 工件检查本身由原工具负责；此处只隔离它，防止导出回归下载大型图形依赖。
write(source, 'scripts/check-mobilegl-build-contract.mjs', 'export function verifyDist() {}\n');
write(source, 'entry/src/main/ets/PublicCode.ets', 'export const publicValue = 1;\n');
write(source, 'entry/src/main/resources/rawfile/locked-input.bin', 'fixture binary input\n');
write(source, 'entry/src/main/private.p12', 'DO-NOT-EXPORT\n');
write(source, 'entry/.secrets/token.txt', 'DO-NOT-EXPORT\n');
write(source, 'docs/private-device.log', 'DO-NOT-EXPORT\n');
write(source, 'build-dependencies.local.json', '{"private":"DO-NOT-EXPORT"}\n');
write(source, 'build-dependencies.local.json.example', '{"schemaVersion":1}\n');
write(source, 'gate0-evidence.lock', '{"capabilities":{}}\n');
for (const name of ['libmobilegl.so', 'libmobilegl.unstripped.so', 'build-provenance.json']) {
  write(source, `prebuilt/mobilegl/dist/${name}`, 'locked test input\n');
}
git(source, 'add', '.');
git(source, 'commit', '-m', 'fixture frozen source');
const commit = git(source, 'rev-parse', 'HEAD');
fs.mkdirSync(path.dirname(script), { recursive: true });
fs.mkdirSync(destination, { recursive: true });
fs.copyFileSync(path.join(tools, 'sync-source-snapshot.mjs'), script);

const success = run('--write', '--require-clean', '--expected-commit', commit);
assert.equal(success.status, 0, success.stderr);
const manifestFile = path.join(destination, 'SOURCE_SNAPSHOT.json');
const before = fs.readFileSync(manifestFile);
const manifest = JSON.parse(before);
assert.equal(manifest.sourceCommit, commit);
assert.equal(manifest.sourceDirty, false);
assert.deepEqual(manifest.dependencyWorktrees.map(item => item.path), dependencies);
assert.equal(manifest.dependencyWorktrees.at(-1).baseCommit,
  git(path.join(source, dependencies.at(-1)), 'rev-parse', 'HEAD'));
for (const relative of ['entry/src/main/private.p12', 'entry/.secrets/token.txt',
  'docs/private-device.log', 'build-dependencies.local.json']) {
  assert.equal(fs.existsSync(path.join(destination, relative)), false, relative);
}
assert(fs.existsSync(path.join(destination, 'build-dependencies.local.json.example')));
rejected(run('--write', '--require-clean', '--expected-commit', '0'.repeat(40)), /Expected source commit/);
assert(fs.readFileSync(manifestFile).equals(before));
write(source, 'entry/src/main/ets/PublicCode.ets', 'export const publicValue = 2;\n');
rejected(run('--write', '--require-clean', '--expected-commit', commit), /clean source checkout/);
assert(fs.readFileSync(manifestFile).equals(before));
// 不启用clean保护时，导出器仍须识别子仓HEAD与源索引gitlink不一致。
write(path.join(source, dependencies.at(-1)), 'LICENSE', 'Changed dependency\n');
git(path.join(source, dependencies.at(-1)), 'add', 'LICENSE');
git(path.join(source, dependencies.at(-1)), 'commit', '-m', 'unrecorded dependency');
rejected(run(), /Source gitlink mismatch: prebuilt\/hdc\/muka-rust-hdc/);
console.log(`PASS public source export: four real gitlinks, whitelist, commit and clean rejection; fixture=${fixture}`);

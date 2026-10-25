#!/usr/bin/env node
/**
 * 人工发行导出的真实Git集成回归。用小型独占源仓、公开仓和四个gitlink验证
 * 冻结来源、两阶段计划、增改删/重命名、公开贡献保护和失败零写入。
 * 唯一替身是MobileGL制品门禁；它仍实际校验fixture制品，不能授予真实库资格。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { safeRelative } from './lib/source-export.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const parent = process.env.AMCL_RUN_DIR || os.tmpdir();
fs.mkdirSync(parent, { recursive: true });
const fixture = fs.mkdtempSync(path.join(parent, 'manual-source-test-'));
const source = path.join(fixture, 'source'), target = path.join(fixture, 'public');
const script = path.join(target, 'tools/sync-source-snapshot.mjs');
const dependencies = ['prebuilt/lwjgl3/lwjgl3_src', 'prebuilt/mobileglues/mg_src', 'prebuilt/mobilegl/src', 'prebuilt/hdc/muka-rust-hdc'];
const tests = []; let planNumber = 0;

/** 文件操作仅发生在亲建fixture；源码字节、Git元数据和输出计划分开管理。 */
function write(root, relative, text) {
  const file = path.join(root, relative); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
}
function git(root, ...args) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, `${args[0]}: ${result.stderr}`); return result.stdout.trim();
}
function initialize(root) {
  fs.mkdirSync(root, { recursive: true }); git(root, 'init');
  git(root, 'config', 'user.name', 'AMCL manual export fixture'); git(root, 'config', 'user.email', 'fixture@example.invalid');
  git(root, 'config', 'core.autocrlf', 'false');
}
function commit(root, message) { git(root, 'add', '.'); git(root, 'commit', '-m', message); return git(root, 'rev-parse', 'HEAD'); }
function run(...args) { return spawnSync(process.execPath, [script, '--source', source, '--expected-commit', git(source, 'rev-parse', 'HEAD'), ...args], { encoding: 'utf8' }); }
function successful(result) { assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout); }
function rejected(result, pattern) { assert.notEqual(result.status, 0); assert.match(result.stderr, pattern); }
function preview() {
  const plan = path.join(fixture, `plan-${++planNumber}.json`);
  const value = successful(run('--plan', plan)); return { plan, value };
}
function apply(plan) { return successful(run('--plan', plan, '--write')); }
function record(name, action) { action(); tests.push(name); }
function publicStatus() { return git(target, 'status', '--porcelain', '--untracked-files=all'); }

initialize(source);
write(source, '.gitignore', '/prebuilt/mobilegl/dist/\n');
for (const dependency of dependencies) {
  const directory = path.join(source, dependency); initialize(directory); write(directory, 'LICENSE', 'Fixture public license\n');
  const pin = commit(directory, 'dependency baseline');
  git(source, 'update-index', '--add', '--cacheinfo', `160000,${pin},${dependency}`);
}
write(source, '.gitmodules', dependencies.map((dependency, index) => `[submodule "fixture-${index}"]\n path = ${dependency}\n url = https://example.invalid/dependency-${index}.git\n`).join(''));
write(source, 'scripts/check-mobilegl-build-contract.mjs', "import fs from 'node:fs'; export function verifyDist(){if(fs.readFileSync('prebuilt/mobilegl/dist/libmobilegl.so','utf8')!=='LOCKED\\n')throw new Error('bad fixture locked artifact');}\n");
write(source, 'AppScope/app.json5', '{"app":{"versionName":"9.9.9","versionCode":999}}\n');
write(source, 'config/products.json', '{"products":{}}\n'); write(source, 'deps.lock', '[fixture]\ncommit = PENDING\n'); write(source, 'toolchain.lock', '{}\n');
write(source, 'gate0-evidence.lock', '{"capabilities":{}}\n');
write(source, 'docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md', 'Reviewed public build/test input\n');
write(source, 'docs/private-diagnostic.md', 'PRIVATE-NOT-EXPORTED\n');
write(source, 'entry/src/main/ets/PublicCode.ets', 'export const value = 1;\n');
write(source, 'entry/src/main/ets/Old.ets', 'export const old = 1;\n');
write(source, 'JavaCpuAgent/src/CpuAgent.java', 'class CpuAgent {}\n');
write(source, 'JavaAudioServiceAgent/src/AudioAgent.java', 'class AudioAgent {}\n');
write(source, 'entry/src/main/private.p12', 'PRIVATE-NOT-EXPORTED\n');
write(source, 'entry/.secrets/token.txt', 'PRIVATE-NOT-EXPORTED\n');
write(source, 'build-dependencies.local.json.example', '{"schemaVersion":1}\n');
for (const name of ['libmobilegl.so', 'libmobilegl.unstripped.so', 'build-provenance.json']) write(source, `prebuilt/mobilegl/dist/${name}`, name === 'libmobilegl.so' ? 'LOCKED\n' : name.endsWith('.json') ? '{}\n' : 'fixture artifact\n');
commit(source, 'frozen version source');

initialize(target);
fs.cpSync(path.join(repository, 'tools'), path.join(target, 'tools'), { recursive: true });
write(target, 'README.md', 'PUBLIC GUIDE\n'); write(target, 'MyApplication/README.md', 'PUBLIC APP GUIDE\n');
for (const relative of ['build-profile.json5.template', 'scripts/prepare-public-deps.mjs', 'docs/BUILD_SNAPSHOT.md']) write(target, `MyApplication/${relative}`, 'Public-owned build input\n');
for (const relative of ['scripts/check-public-snapshot.mjs', 'scripts/product-contract.mjs']) {
  fs.mkdirSync(path.dirname(path.join(target, 'MyApplication', relative)), { recursive: true });
  fs.copyFileSync(path.join(repository, 'MyApplication', relative), path.join(target, 'MyApplication', relative));
}
commit(target, 'public tooling baseline');

record('unsafe paths rejected', () => {
  for (const value of ['../outside', 'a/../b', 'C:/outside', '.git/config', 'NUL.txt', 'a\\b', 'a.']) assert.throws(() => safeRelative(value));
});
record('write requires reviewed external plan', () => { rejected(run('--write'), /existing, reviewed/); assert.equal(publicStatus(), ''); });
record('wrong frozen source rejected before writes', () => {
  const result = spawnSync(process.execPath, [script, '--source', source, '--expected-commit', '0'.repeat(40)], { encoding: 'utf8' });
  rejected(result, /Expected source commit/); assert.equal(publicStatus(), '');
});
record('untracked source is not silently exported', () => {
  write(source, 'entry/Untracked.ets', 'untracked\n'); rejected(run(), /clean source checkout/);
  fs.unlinkSync(path.join(source, 'entry/Untracked.ets')); assert.equal(publicStatus(), '');
});
const initial = preview();
record('preview leaves public checkout unchanged', () => {
  assert.equal(publicStatus(), ''); assert(initial.value.actions.some(action => action.type === 'gitlink'));
  assert(!initial.value.inventory.some(item => item.path === 'entry/Untracked.ets'));
});
record('initial export includes complete first-party roots and protects private inputs', () => {
  apply(initial.plan);
  for (const relative of ['JavaCpuAgent/src/CpuAgent.java', 'JavaAudioServiceAgent/src/AudioAgent.java', 'docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md', 'DEPENDENCY_INPUTS.json']) assert(fs.existsSync(path.join(target, 'MyApplication', relative)));
  for (const relative of ['entry/src/main/private.p12', 'entry/.secrets/token.txt', 'docs/private-diagnostic.md']) assert.equal(fs.existsSync(path.join(target, 'MyApplication', relative)), false);
  assert.equal(fs.readFileSync(path.join(target, 'MyApplication/README.md'), 'utf8'), 'PUBLIC APP GUIDE\n');
  const snapshot = JSON.parse(fs.readFileSync(path.join(target, 'MyApplication/SOURCE_SNAPSHOT.json')));
  assert.equal(snapshot.sourceDirty, false); assert.equal(snapshot.exporter.schemaVersion, 2); assert.equal(snapshot.dependencyWorktrees.length, 4);
  // 导出器负责新gitlink的空目录；测试不能用额外mkdir掩盖AD状态或后续git add丢引用。
  for (const dependency of dependencies) assert(fs.existsSync(path.join(target, 'MyApplication', dependency)));
  for (const dependency of snapshot.dependencyWorktrees) assert.equal(git(target, 'ls-files', '--stage', '--', `MyApplication/${dependency.path}`).split(' ')[1], dependency.baseCommit);
  const checked = spawnSync(process.execPath, [path.join(target, 'MyApplication/scripts/check-public-snapshot.mjs')], { encoding: 'utf8' });
  assert.equal(checked.status, 0, checked.stderr);
  commit(target, 'manual source release');
});
record('repeat preview is idempotent', () => { assert.equal(preview().value.actions.length, 0); assert.equal(publicStatus(), ''); });
record('derived dependency report can be regenerated after public commit', () => {
  const result = spawnSync(process.execPath, [path.join(target, 'tools/dependency-inputs.mjs'), '--check', '--json'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).check, 'match');
});
record('executable Git mode is exported even without changing file content', () => {
  write(source, 'scripts/fixture-executable.sh', '#!/bin/sh\nexit 0\n');
  fs.chmodSync(path.join(source, 'scripts/fixture-executable.sh'), 0o755);
  git(source, 'add', 'scripts/fixture-executable.sh'); git(source, 'update-index', '--chmod=+x', '--', 'scripts/fixture-executable.sh'); git(source, 'commit', '-m', 'executable fixture');
  apply(preview().plan);
  assert.match(git(target, 'ls-files', '--stage', '--', 'MyApplication/scripts/fixture-executable.sh'), /^100755 /);
  commit(target, 'release executable fixture');
  fs.chmodSync(path.join(source, 'scripts/fixture-executable.sh'), 0o644);
  git(source, 'update-index', '--chmod=-x', '--', 'scripts/fixture-executable.sh'); git(source, 'commit', '-m', 'mode-only change');
  // Windows本机不按文件系统执行位判断Git，仍必须在公开索引体现100644。
  const changed = preview(); assert(changed.value.actions.some(action => action.path.endsWith('/fixture-executable.sh') && action.afterMode === '100644'));
  apply(changed.plan); assert.match(git(target, 'ls-files', '--stage', '--', 'MyApplication/scripts/fixture-executable.sh'), /^100644 /);
  commit(target, 'release mode-only change');
});
record('new release metadata remains a valid public PR baseline', () => {
  const result = spawnSync(process.execPath, [path.join(target, 'tools/check-public-contribution.mjs'), '--base', git(target, 'rev-parse', 'HEAD'), '--json'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).ok, true);
});
record('committed source rename and deletion apply precisely', () => {
  fs.renameSync(path.join(source, 'entry/src/main/ets/Old.ets'), path.join(source, 'entry/src/main/ets/Renamed.ets'));
  write(source, 'entry/src/main/ets/PublicCode.ets', 'export const value = 2;\n'); commit(source, 'source rename and update');
  const next = preview(); assert(next.value.actions.some(action => action.type === 'delete' && action.path.endsWith('/Old.ets')));
  apply(next.plan); assert.equal(fs.existsSync(path.join(target, 'MyApplication/entry/src/main/ets/Old.ets')), false);
  assert(fs.existsSync(path.join(target, 'MyApplication/entry/src/main/ets/Renamed.ets'))); commit(target, 'next source release');
});
record('committed public contribution conflicts are preserved', () => {
  write(target, 'MyApplication/entry/src/main/ets/PublicCode.ets', 'export const value = 99;\n'); commit(target, 'public proposed contribution');
  const before = fs.readFileSync(path.join(target, 'MyApplication/SOURCE_SNAPSHOT.json'));
  rejected(run(), /Public changes conflict/); assert(fs.readFileSync(path.join(target, 'MyApplication/SOURCE_SNAPSHOT.json')).equals(before)); assert.equal(publicStatus(), '');
});
record('contribution adopted by private source is retained on release', () => {
  write(source, 'entry/src/main/ets/PublicCode.ets', 'export const value = 99;\n'); commit(source, 'adopt public contribution');
  const adopted = preview(); assert(!adopted.value.actions.some(action => action.path.endsWith('/PublicCode.ets')));
  apply(adopted.plan); commit(target, 'release adopted contribution');
});
record('public baseline drift invalidates an existing plan', () => {
  const planned = preview(); write(target, 'README.md', 'UPDATED PUBLIC GUIDE\n'); commit(target, 'public-only guide');
  rejected(run('--plan', planned.plan, '--write'), /plan drift/); assert.equal(publicStatus(), '');
});
record('locked artifact failure produces no partial synchronization', () => {
  write(source, 'prebuilt/mobilegl/dist/libmobilegl.so', 'BROKEN\n'); rejected(run(), /bad fixture locked artifact|Command failed/);
  assert.equal(publicStatus(), ''); write(source, 'prebuilt/mobilegl/dist/libmobilegl.so', 'LOCKED\n');
});
record('new source root requires an explicit ownership review', () => {
  write(source, 'NewModule/Main.ets', 'new source\n'); commit(source, 'new unclassified module');
  rejected(run(), /Unclassified source path/); assert.equal(publicStatus(), '');
  git(source, 'rm', '--', 'NewModule/Main.ets'); commit(source, 'finish ownership negative control');
});
record('missing public test input is rejected before apply', () => {
  git(source, 'rm', '--', 'docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md'); commit(source, 'missing required document');
  rejected(run(), /Missing public build\/test input/); assert.equal(publicStatus(), '');
  write(source, 'docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md', 'Reviewed public build/test input\n'); commit(source, 'restore required input');
});
record('source changed after preview invalidates the plan', () => {
  const planned = preview(); write(source, 'entry/src/main/ets/New.ets', 'export const next = 1;\n'); commit(source, 'source advanced after preview');
  rejected(run('--plan', planned.plan, '--write'), /plan drift/); assert.equal(publicStatus(), '');
});
record('public uncommitted changes are never overwritten', () => {
  write(target, 'README.md', 'UNCOMMITTED GUIDE\n'); rejected(run(), /clean, exclusive public candidate/);
  git(target, 'restore', '--', 'README.md'); assert.equal(publicStatus(), '');
});
record('external junction cannot redirect a plan back into a repository', () => {
  const redirected = path.join(fixture, 'redirected-plan');
  fs.symlinkSync(target, redirected, process.platform === 'win32' ? 'junction' : 'dir');
  rejected(run('--plan', path.join(redirected, 'private-plan.json')), /physically outside/);
  assert.equal(fs.existsSync(path.join(target, 'private-plan.json')), false); assert.equal(publicStatus(), '');
});
if (process.platform === 'win32') record('unavailable plan drive fails without an ancestor-loop hang', () => {
  const drive = [...'ZYXWVUTSRQPONMLKJIHGFED'].find(letter => !fs.existsSync(`${letter}:/`));
  assert(drive, 'fixture needs an unavailable Windows drive');
  const result = spawnSync(process.execPath, [script, '--source', source, '--expected-commit', git(source, 'rev-parse', 'HEAD'), '--plan', `${drive}:/unavailable/plan.json`], { encoding: 'utf8', timeout: 3000 });
  assert.equal(result.error, undefined); rejected(result, /Cannot resolve plan parent/);
});
record('Git write failure restores replaced files and preserves the original index', () => {
  const planned = preview(), before = fs.readFileSync(path.join(target, 'MyApplication/SOURCE_SNAPSHOT.json'));
  const index = git(target, 'rev-parse', '--git-path', 'index');
  const indexFile = path.resolve(target, index), indexBytes = fs.readFileSync(indexFile);
  // 使用本测试亲建仓的标准index.lock让第一次索引写入失败；不模拟成功，也不改用户仓。
  fs.writeFileSync(indexFile + '.lock', 'fixture exclusive lock\n', { flag: 'wx' });
  const result = run('--plan', planned.plan, '--write');
  rejected(result, /Apply failed; preimages restored/);
  fs.unlinkSync(indexFile + '.lock');
  assert(fs.readFileSync(path.join(target, 'MyApplication/SOURCE_SNAPSHOT.json')).equals(before));
  assert(fs.readFileSync(indexFile).equals(indexBytes)); assert.equal(publicStatus(), '');
  assert.equal(fs.existsSync(path.join(target, 'MyApplication/entry/src/main/ets/New.ets')), false);
});

const receipt = { test: 'manual-source-export', result: 'passed', completedAt: new Date().toISOString(), tests,
  qualification: 'small Git fixtures and export only; no SDK/HAP/download/device verification', fixtureRemoved: true };
fs.writeFileSync(path.join(parent, 'manual-source-export-receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
const resolved = fs.realpathSync(fixture), allowed = fs.realpathSync(parent);
assert(resolved.startsWith(allowed + path.sep)); assert(path.basename(resolved).startsWith('manual-source-test-'));
fs.rmSync(resolved, { recursive: true });
console.log(`PASS manual source export: ${tests.length} real Git scenarios; no application publication`);

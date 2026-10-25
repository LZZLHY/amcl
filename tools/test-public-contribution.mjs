#!/usr/bin/env node
/**
 * 用真实小型 Git 仓验证贡献检查：官方基线必须完整，但工作树的正常源码修改、
 * 新文件及删除均可检验；清单伪造、损坏配置、JS 语法和缺失基线必须明确失败。
 * 输出可用 AMCL_RUN_DIR 外置；成功后保存小型收据并回收本轮独占夹具，失败保留现场。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const tools = path.dirname(fileURLToPath(import.meta.url));
const configuredParent = process.env.AMCL_RUN_DIR || os.tmpdir();
fs.mkdirSync(configuredParent, { recursive: true });
const parent = fs.realpathSync(configuredParent);
const fixture = fs.mkdtempSync(path.join(parent, 'public-contribution-test-'));
const script = path.join(fixture, 'tools/check-public-contribution.mjs');
const manifestPath = 'MyApplication/SOURCE_SNAPSHOT.json';
const checks = [];

/** 仅写本轮独占目录的精确文件，不借用真实源码或第三方工作树作为可写夹具。 */
function write(relative, contents) {
  const file = path.join(fixture, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

/** Git 参数通过 argv 传入，确保夹具路径和错误不会被 shell 再解释。 */
function git(...args) {
  const result = spawnSync('git', ['-C', fixture, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function run(base, extra = []) {
  const args = base === null ? [] : ['--base', base];
  const result = spawnSync(process.execPath, [script, ...args, '--json', ...extra], { encoding: 'utf8' });
  const report = JSON.parse(result.stdout);
  return { ...result, report };
}

/** 每个断言同时核对退出码和结构化状态，避免只看日志包含 PASS。 */
function passed(name, result) {
  assert.equal(result.status, 0, JSON.stringify(result.report));
  assert.equal(result.report.ok, true);
  checks.push(name);
  return result.report;
}
function rejected(name, result, pattern) {
  assert.notEqual(result.status, 0);
  assert.equal(result.report.ok, false);
  assert.match(result.report.failures.join('\n'), pattern);
  checks.push(name);
}

try {
  git('init');
  git('config', 'user.name', 'AMCL contribution fixture');
  git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'core.autocrlf', 'false');
  write('tools/check-public-contribution.mjs', fs.readFileSync(path.join(tools, 'check-public-contribution.mjs')));
  write('MyApplication/scripts/product-contract.mjs', fs.readFileSync(path.join(tools, '../MyApplication/scripts/product-contract.mjs')));
  const originals = new Map([
    ['entry/src/main/ets/Feature.ets', 'export const featureValue = 1;\n'],
    ['scripts/proposal.mjs', 'export const value = 1;\n'],
    ['config/example.json', '{"valid":true}\n'],
    // 跨 cat-file stdout 块的 CRLF/UTF-8 输入验证规范化状态不会在块边界丢字节。
    ['tests/text.txt', ('鸿蒙 contribution\r\n').repeat(15000)],
    ['prebuilt/library/local-worktree.patch', '--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n'],
  ]);
  const entries = [];
  for (const [relative, contents] of originals) {
    write(`MyApplication/${relative}`, contents);
    entries.push({ path: relative, normalization: 'lf',
      sha256: createHash('sha256').update(contents.replace(/\r\n/g, '\n')).digest('hex') });
  }
  const dependency = 'prebuilt/library/source';
  const dependencyCommit = 'b'.repeat(40);
  // 模拟 checkout 留下的空子模块目录；完全缺失目录会被 Git 正确报告为删除。
  fs.mkdirSync(path.join(fixture, 'MyApplication', dependency), { recursive: true });
  const patch = 'prebuilt/library/local-worktree.patch';
  const manifest = {
    schema: 1, sourceCommit: 'a'.repeat(40), sourceDirty: false, entries,
    dependencyWorktrees: [{ path: dependency, baseCommit: dependencyCommit, patch,
      patchSha256: createHash('sha256').update(originals.get(patch)).digest('hex') }],
  };
  write(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  git('add', '.');
  git('update-index', '--add', '--cacheinfo', `160000,${dependencyCommit},MyApplication/${dependency}`);
  git('commit', '-m', 'fixture published version');
  const base = git('rev-parse', 'HEAD');

  const original = passed('original base including gitlink, CRLF and patch identities', run(base));
  assert.equal(original.changes.length, 0);
  assert.equal(original.notRun.length, 3);

  write('MyApplication/entry/src/main/ets/Feature.ets', 'export const featureValue = 2;\n');
  const modified = passed('uncommitted application change without manifest rewrite', run(base));
  assert(modified.changes.some(item => item.path.endsWith('Feature.ets')));
  write('MyApplication/entry/src/main/ets/Feature.ets', originals.get('entry/src/main/ets/Feature.ets'));

  write('proposal.json5', '// contributed config\n{"items":[1,2,],}\n');
  const added = passed('untracked JSON5 contribution', run(base));
  assert(added.checks.some(item => item.path === 'proposal.json5' && item.check === 'JSON/JSON5 parse'));
  fs.unlinkSync(path.join(fixture, 'proposal.json5'));

  write('MyApplication/scripts/proposal.mjs', 'export const = ;\n');
  rejected('changed JavaScript syntax failure', run(base), /proposal\.mjs/);
  write('MyApplication/scripts/proposal.mjs', originals.get('scripts/proposal.mjs'));
  write('new-proposal.mjs', 'const broken = ;\n');
  rejected('untracked JavaScript syntax failure', run(base), /new-proposal\.mjs/);
  fs.unlinkSync(path.join(fixture, 'new-proposal.mjs'));

  write('MyApplication/config/example.json', '{"broken":}\n');
  rejected('changed JSON parse failure', run(base), /example\.json/);
  fs.unlinkSync(path.join(fixture, 'MyApplication/config/example.json'));
  const deletion = passed('explicit source deletion', run(base));
  assert(deletion.checks.some(item => item.path.endsWith('example.json') && item.check === 'deleted'));
  write('MyApplication/config/example.json', originals.get('config/example.json'));

  write(manifestPath, JSON.stringify({ ...manifest, note: 'contributor must not rewrite official identity' }));
  rejected('official snapshot rewrite', run(base), /只由维护者发版/);
  write(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  rejected('missing base argument', run(null), /--base/);
  rejected('abbreviated base rejected', run(base.slice(0, 7)), /40位/);
  rejected('unknown base rejected', run('f'.repeat(40)), /Git rev-parse/);
  rejected('unknown option rejected', run(base, ['--unsafe']), /用法/);

  const damaged = structuredClone(manifest);
  damaged.entries[0].sha256 = '0'.repeat(64);
  write(manifestPath, JSON.stringify(damaged));
  git('add', manifestPath);
  git('commit', '-m', 'fixture corrupted baseline');
  rejected('corrupted Git baseline cannot prove original identity', run(git('rev-parse', 'HEAD')), /原版哈希不符/);

  // 恢复实际工作树即可重新针对旧发行基线检查，无需改写任何 Git 历史。
  write(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  passed('trusted old baseline independent of current index', run(base));

  const receipt = path.join(parent, path.basename(fixture) + '.receipt.json');
  const result = { ok: true, completedAt: new Date().toISOString(),
    checks, fixture, fixtureRemoved: false, notRun: original.notRun };
  fs.writeFileSync(receipt, JSON.stringify(result, null, 2) + '\n');
  // 只回收本轮 mkdtemp 的子目录，父路径已 realpath；拒绝扩大到共享父目录。
  assert.equal(path.dirname(fixture), parent);
  assert(path.basename(fixture).startsWith('public-contribution-test-'));
  assert.equal(fs.realpathSync(fixture), fixture);
  fs.rmSync(fixture, { recursive: true });
  result.fixtureRemoved = true;
  fs.writeFileSync(receipt, JSON.stringify(result, null, 2) + '\n');
  console.log(`PASS public contribution: ${checks.length} integration cases; receipt=${receipt}; own fixture removed`);
} catch (error) {
  console.error(`Contribution test failed; fixture preserved at ${fixture}`);
  throw error;
}

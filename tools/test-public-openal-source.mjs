/** 使用真实上游工作树和完整 patch series 验证来源检查；所有反控修改仅在亲建测试工作树。 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { verifyPublicOpenalSource } from '../MyApplication/scripts/lib/public-openal-source.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const value = flag => { const i = process.argv.indexOf(flag); return i >= 0 ? process.argv[i + 1] : undefined; };
const donor = path.resolve(value('--openal'));
const output = path.resolve(value('--out'));
assert(!output.startsWith(root + path.sep));
fs.mkdirSync(output, { recursive: true });
const fixture = path.join(output, 'worktree');
assert(!fs.existsSync(fixture));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const git = (directory, ...args) => execFileSync('git', ['-C', directory, ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const head = git(donor, 'rev-parse', 'HEAD').trim();
const originalDiff = hash(git(donor, 'diff', 'HEAD', '--'));
const patchDirectory = path.join(root, 'MyApplication/prebuilt/openal-soft/patches');
const patches = fs.readFileSync(path.join(patchDirectory, 'series'), 'utf8').split(/\r?\n/)
  .map(line => line.replace(/#.*/, '').trim()).filter(Boolean);
const proof = { startedAt: new Date().toISOString(), sourceCommit: head, cases: [], passed: false };
const verify = () => verifyPublicOpenalSource({ openal: fixture, expectedCommit: head, patchDirectory, temporaryRoot: path.join(output, 'indexes') });
const rejected = (name, expectedMessage) => {
  let failure;
  try { verify(); } catch (error) { failure = error; }
  assert(failure && failure.message.includes(expectedMessage), name);
  proof.cases.push({ name, rejected: true, message: failure.message });
  // 反控预期失败已被核实；只回收该测试亲建的临时 index，实际源码单独恢复。
  const directory = failure.evidenceDirectory;
  assert(path.resolve(directory).startsWith(path.join(output, 'indexes') + path.sep));
  for (const filename of ['index', 'index.lock', 'failure.json']) {
    const target = path.join(directory, filename); if (fs.existsSync(target)) fs.unlinkSync(target);
  }
  fs.rmdirSync(directory);
};
try {
  git(donor, 'worktree', 'add', '--detach', fixture, head);
  for (const patch of patches) git(fixture, 'apply', '--whitespace=nowarn', path.join(patchDirectory, patch));
  const positive = verify();
  assert.equal(positive.patches.length, 2);
  assert.deepEqual(positive.changedFiles, ['alc/alc.cpp', 'alc/backends/base.h']);
  proof.cases.push({ name: 'both real current patches accepted', passed: true });
  const alc = path.join(fixture, 'alc/alc.cpp'), savedAlc = fs.readFileSync(alc);
  fs.appendFileSync(alc, '\n// unrelated change that retains all known OHAudio symbols\n');
  rejected('unrelated change inside approved file', 'source differs');
  fs.writeFileSync(alc, savedAlc);
  git(fixture, 'apply', '--reverse', path.join(patchDirectory, patches[1]));
  rejected('missing actual limiter patch', 'changed-file set differs');
  git(fixture, 'apply', path.join(patchDirectory, patches[1]));
  const config = path.join(fixture, 'config_backends.h.in'), savedConfig = fs.readFileSync(config);
  fs.appendFileSync(config, '\n#define UNAPPROVED_BACKEND 1\n');
  rejected('extra changed tracked file', 'changed-file set differs');
  fs.writeFileSync(config, savedConfig);
  const extra = path.join(fixture, 'unapproved-source.cpp');
  fs.writeFileSync(extra, '// intentional isolated negative control\n');
  rejected('untracked source injection', 'untracked source');
  fs.unlinkSync(extra);
  verify();
  assert.equal(git(donor, 'rev-parse', 'HEAD').trim(), head);
  assert.equal(hash(git(donor, 'diff', 'HEAD', '--')), originalDiff);
  // 仅恢复亲建测试树的已知三个文件，再用 Git 的普通工作树收尾，不裸删对象银行。
  git(fixture, 'restore', '--source=HEAD', '--worktree', '--', 'alc/alc.cpp', 'alc/backends/base.h', 'config_backends.h.in');
  assert.equal(git(fixture, 'status', '--porcelain').trim(), '');
  git(donor, 'worktree', 'remove', fixture);
  proof.passed = true;
} finally {
  proof.finishedAt = new Date().toISOString();
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(proof, null, 2) + '\n');
}
console.log(JSON.stringify({ passed: proof.passed, cases: proof.cases.length, donorUnchanged: true }));

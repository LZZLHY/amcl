/**
 * 以固定上游提交和当前受管 patch series 重建预期 OpenAL 索引，逐文件核对实际源码。
 * 不修改工作树/主索引，不用包含某个标识符或手写旧补丁片段代替完整来源验证。
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const lf = text => text.replace(/\r\n/g, '\n');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

export function verifyPublicOpenalSource({ openal, expectedCommit, patchDirectory, temporaryRoot }) {
  if (!/^[a-f0-9]{40}$/.test(expectedCommit)) throw new Error('Invalid fixed OpenAL source commit');
  fs.mkdirSync(temporaryRoot, { recursive: true });
  const directory = fs.mkdtempSync(path.join(temporaryRoot, 'index-'));
  const index = path.join(directory, 'index');
  const environment = { ...process.env, GIT_INDEX_FILE: index };
  const git = (args, alternate = false, input) => execFileSync('git', ['-C', openal, ...args], {
    encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env: alternate ? environment : process.env, input
  }).trim();
  let passed = false;
  const evidence = { expectedCommit, patches: [], changedFiles: [] };
  try {
    if (git(['rev-parse', 'HEAD']) !== expectedCommit) throw new Error('OpenAL source commit changed');
    const series = fs.readFileSync(path.join(patchDirectory, 'series'), 'utf8');
    const names = series.split(/\r?\n/).map(line => line.replace(/#.*/, '').trim()).filter(Boolean);
    if (!names.length || new Set(names).size !== names.length) throw new Error('Invalid OpenAL patch series');
    git(['read-tree', expectedCommit], true);
    for (const name of names) {
      if (!/^[A-Za-z0-9_.-]+\.patch$/.test(name) || name.includes('..')) throw new Error('Unsafe OpenAL patch name');
      const file = path.join(patchDirectory, name);
      if (fs.lstatSync(file).isSymbolicLink()) throw new Error('Linked OpenAL patch is not allowed');
      // 固定本次实际读到的 patch 字节，Git 只写本调用独占的临时 index。
      const bytes = fs.readFileSync(file);
      evidence.patches.push({ name, sha256: hash(bytes) });
      git(['apply', '--cached', '--whitespace=nowarn', '-'], true, Buffer.from(lf(bytes.toString('utf8'))));
    }
    const expected = git(['diff', '--cached', '--name-only', expectedCommit], true).split('\n').filter(Boolean).sort();
    const actual = git(['diff', expectedCommit, '--name-only']).split('\n').filter(Boolean).sort();
    if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error('OpenAL changed-file set differs from fixed patch series');
    if (git(['ls-files', '--others', '--exclude-standard'])) throw new Error('OpenAL has untracked source outside the fixed recipe');
    for (const relative of expected) {
      const wanted = execFileSync('git', ['-C', openal, 'show', ':' + relative], { encoding: 'utf8', env: environment, maxBuffer: 16 * 1024 * 1024 });
      const actualBytes = fs.readFileSync(path.join(openal, relative), 'utf8');
      if (lf(actualBytes) !== lf(wanted)) throw new Error('OpenAL source differs from fixed patch series: ' + relative);
    }
    if (git(['rev-parse', 'HEAD']) !== expectedCommit) throw new Error('OpenAL source changed during verification');
    evidence.changedFiles = expected;
    passed = true;
    return evidence;
  } catch (error) {
    // 未知失败保留最小预期索引和来源摘要，调用者可据此诊断；不清理实际源码。
    fs.writeFileSync(path.join(directory, 'failure.json'), JSON.stringify({ ...evidence, error: error.message }, null, 2) + '\n');
    error.evidenceDirectory = directory;
    throw error;
  } finally {
    if (passed) {
      for (const file of [index, index + '.lock']) if (fs.existsSync(file)) fs.unlinkSync(file);
      fs.rmdirSync(directory);
    }
  }
}

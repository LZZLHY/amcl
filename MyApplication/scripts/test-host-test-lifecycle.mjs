/**
 * 宿主测试收尾的真实进程回归：成功退出才删、失败/显式调试保留、异步写入与句柄先结束、
 * 越界及目录身份替换拒绝。所有故意失败现场只在本回归独占域内生成并核验。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { PROJECT_ROOT } from './lib/workspace-paths.mjs';

const scope = createHostTestScope('lifecycle-regression-');
const helper = new URL('./lib/host-test-lifecycle.mjs', import.meta.url).href;
const fixture = new URL('./lib/sideload-coordinator-fixture.mjs', import.meta.url).href;

/** 子进程自然退出必须经过 beforeExit；父进程检查实际目录，而非只断言清理函数被调用。 */
function runChild(name, source, extraEnv = {}) {
  const parent = path.join(scope.directory, name);
  fs.mkdirSync(parent);
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', source], {
    encoding: 'utf8', timeout: 30000,
    env: { ...process.env, AMCL_TEST_OUTPUT_DIR: parent, AMCL_KEEP_TEST_OUTPUT: '', ...extraEnv }
  });
  assert.equal(result.error, undefined, result.error?.message);
  return { ...result, parent, entries: fs.readdirSync(parent) };
}

// 人工异步边界在 beforeExit 才解除；写回成功且关闭 fd 后目录才允许被删除。
const success = runChild('success', `
import fs from 'node:fs';
import path from 'node:path';
import { createHostTestScope } from ${JSON.stringify(helper)};
const scope = createHostTestScope('case-');
const file = fs.openSync(path.join(scope.directory, 'pending.txt'), 'w');
scope.defer(async () => {
  await new Promise(resolve => setTimeout(resolve, 20));
  fs.writeSync(file, 'async boundary completed');
  fs.closeSync(file);
  fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR, 'settled.txt'), 'write and close finished');
});
`);
assert.equal(success.status, 0, success.stderr);
assert.deepEqual(success.entries, ['settled.txt']);
assert.equal(fs.readFileSync(path.join(success.parent, 'settled.txt'), 'utf8'), 'write and close finished');

// beforeExit 的 async 回调仅 await Promise 仍可能直接 exit 0；真实子进程故意没有任何持活
// handle，通用生命周期必须用 ref'ed deadline 等到超时，再以失败退出并留下原现场。
const stalled = runChild('stalled-teardown', `
import fs from 'node:fs';import path from 'node:path';
import { createHostTestScope } from ${JSON.stringify(helper)};
const scope=createHostTestScope('case-',{teardownTimeoutMs:40});
fs.writeFileSync(path.join(scope.directory,'evidence.txt'),'unsettled teardown evidence');
scope.defer(()=>new Promise(()=>{}));
`);
assert.equal(stalled.status, 1, stalled.stdout + stalled.stderr);
assert.match(stalled.stderr, /teardown timed out after 40ms/);
assert.equal(stalled.entries.length, 1, '超时保留独占现场');
assert.equal(fs.readFileSync(path.join(stalled.parent, stalled.entries[0], 'evidence.txt'), 'utf8'), 'unsettled teardown evidence');

const common = `import fs from 'node:fs';import path from 'node:path';
import { createHostTestScope } from ${JSON.stringify(helper)};
const scope = createHostTestScope('case-');fs.writeFileSync(path.join(scope.directory, 'evidence.txt'), 'preserved');
scope.defer(async()=>{fs.writeFileSync(path.join(scope.directory,'evidence.txt'),'teardown changed evidence');});`;
for (const [name, suffix, env, expectedStatus] of [
  ['failure', `throw new Error('intentional assertion failure');`, {}, 1],
  ['exit-code', `process.exitCode=2;`, {}, 2],
  ['teardown-failure', `scope.defer(async()=>{throw new Error('intentional teardown failure');});`, {}, 1],
  ['keep', '', { AMCL_KEEP_TEST_OUTPUT: '1' }, 0]
]) {
  const result = runChild(name, common + suffix, env);
  assert.equal(result.status, expectedStatus, result.stderr);
  assert.equal(result.entries.length, 1, name + ' must retain its own directory');
  assert.equal(fs.readFileSync(path.join(result.parent, result.entries[0], 'evidence.txt'), 'utf8'),
    name === 'teardown-failure' ? 'teardown changed evidence' : 'preserved',
    '失败/调试保留不得由取消业务或放行 gate 改写原现场');
}

assert.throws(() => createHostTestScope('case-', { parent: PROJECT_ROOT }), /outside the project/);
assert.throws(() => createHostTestScope('case-', { parent: 'relative-output' }), /absolute/);
for (const teardownTimeoutMs of [0, -1, NaN, Infinity, '10', 60001]) {
  assert.throws(() => createHostTestScope('case-', { parent: scope.directory, teardownTimeoutMs }), /teardownTimeoutMs/);
}
const guarded = createHostTestScope('guard-', { parent: scope.directory, automatic: false });
const original = guarded.directory + '-original', external = path.join(scope.directory, 'protected');
fs.mkdirSync(external);fs.writeFileSync(path.join(external, 'keep.txt'), 'outside guarded scope');
fs.renameSync(guarded.directory, original);
fs.symlinkSync(external, guarded.directory, process.platform === 'win32' ? 'junction' : 'dir');
await assert.rejects(guarded.close(), /directory identity changed/);
assert.equal(fs.readFileSync(path.join(external, 'keep.txt'), 'utf8'), 'outside guarded scope');
assert.equal(fs.existsSync(original), true, '身份改变时连原目录也不猜测删除');
const linkScope = createHostTestScope('link-', { parent: scope.directory, automatic: false });
fs.symlinkSync(external, path.join(linkScope.directory, 'external-link'), process.platform === 'win32' ? 'junction' : 'dir');
await linkScope.close();
assert.equal(fs.existsSync(linkScope.directory), false);
assert.equal(fs.readFileSync(path.join(external, 'keep.txt'), 'utf8'), 'outside guarded scope', '内部链接仅删除链接本身');

// 运行真实 sideload fixture：JAR 已独占提取、签名 Promise 仍在 gate 等待，且有真实打开句柄。
// 子进程不显式放行 gate 或关闭 fd；共享 fixture 的收尾必须负责完成真实 finally 后删除整轮目录。
const actual = runChild('actual-fixture', `
import assert from 'node:assert/strict';
import { fixture, settle } from ${JSON.stringify(fixture)};
const f=await fixture({delaySign:true});f.render();await settle();
assert.equal(f.counters.sign,1);
f.kitfs.openSync('/sandbox/open-at-end.txt',f.kitfs.OpenMode.CREATE|f.kitfs.OpenMode.WRITE_ONLY);
`);
assert.equal(actual.status, 0, actual.stdout + actual.stderr);
assert.deepEqual(actual.entries, [], '真实异步签名与文件句柄收尾完成后才清除 JAR/case');
const failedFixture = runChild('failed-fixture', `
import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import { fixture, settle } from ${JSON.stringify(fixture)};
const f=await fixture({delaySign:true});f.render();await settle();
const journal=f.kitfs.readTextSync('/sandbox/sideload-update/transaction.json');
fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR,'journal-sha.txt'),createHash('sha256').update(journal).digest('hex'));
process.exitCode=3;
`);
assert.equal(failedFixture.status, 3, failedFixture.stdout + failedFixture.stderr);
const failedRun = failedFixture.entries.find(name => name.startsWith('sideload-owner-'));
assert.ok(failedRun, '非零退出保留真实待签名运行域');
const failedCase = fs.readdirSync(path.join(failedFixture.parent, failedRun)).find(name => name.startsWith('case-'));
const journal = fs.readFileSync(path.join(failedFixture.parent, failedRun, failedCase, 'sideload-update/transaction.json'));
assert.equal(createHash('sha256').update(journal).digest('hex'),
  fs.readFileSync(path.join(failedFixture.parent, 'journal-sha.txt'), 'utf8'), '失败退出不能先取消 owner 改写原事务');
console.log('PASS host test lifecycle: real process success cleanup, failure/debug/teardown-fault retention, ref deadline rejects stalled teardown, async write/fd join, ownership/junction rejection and no-follow removal, real sideload pending-sign teardown');

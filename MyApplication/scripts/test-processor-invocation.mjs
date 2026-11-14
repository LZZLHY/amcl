/**
 * 执行完整生产 ProcessorInvocation ArkTS：定时器、Native Promise及取消边界可控。
 * 证明回调取消不会提前完成Promise/释放安装者，也不在结束后留下轮询定时器。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = path.resolve(import.meta.dirname, '..');
const source = 'feature_core/src/main/ets/modloader/ProcessorInvocation.ets';
const lease = makePureEtsLoader()('feature_core/src/main/ets/version/VersionInstallLease.ets');
const compiled = compiler.transpileModule(fs.readFileSync(path.join(root, source), 'utf8'), {
  fileName: source, compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 },
  reportDiagnostics: true,
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);

function fixture() {
  const timers = new Map(); let nextTimer = 0;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'setInterval', 'clearInterval', compiled.outputText)(name => {
    assert.equal(name, '../version/VersionInstallLease'); return lease;
  }, module, module.exports, (action, milliseconds) => {
    assert.equal(milliseconds, 250); timers.set(++nextTimer, action); return nextTimer;
  }, id => { assert.ok(timers.delete(id)); });
  return { invoke: module.exports.invokeInstallerProcessor, timers,
    tick: () => { for (const action of timers.values()) action(); } };
}
const args = ['/files', '21', 2048, '/classpath.jar', 'Main', ['中文'], '/cwd', '/log'];
let tests = 0;

{
  const f = fixture(); let called = 0;
  const bridge = { runJavaProcessor: async (...actual) => {
    called++; assert.deepEqual(actual, args);
    return 7;
  }, cancelJavaProcessor: () => { throw Error('unexpected cancellation'); } };
  assert.equal(await f.invoke(bridge, ...args), 7); assert.equal(called, 1); assert.equal(f.timers.size, 0); tests++;
}
{
  const f = fixture(); const cancelled = new Error('cancelled before native');
  const bridge = { runJavaProcessor: () => { throw Error('must not run'); } };
  await assert.rejects(f.invoke(bridge, ...args, () => { throw cancelled; }), error => error === cancelled);
  assert.equal(f.timers.size, 0); tests++;
}
for (const nativeReject of [false, true]) {
  const f = fixture(); let resolveNative, rejectNative, requestId, stopped = false, checks = 0, completed = false, cancelCalls = 0;
  const reason = new Error('cancelled while Java is active');
  const native = new Promise((resolve, reject) => { resolveNative = resolve; rejectNative = reject; });
  const bridge = { runJavaProcessor: (...actual) => {
    requestId = actual[8]; assert.equal(actual[9], 60000); return native;
  }, cancelJavaProcessor: id => {
    assert.equal(id, requestId); ++cancelCalls;
    if (cancelCalls === 1) throw Error('temporary transport failure');
    stopped = true; return true;
  } };
  const running = f.invoke(bridge, ...args, () => { if (++checks > 1) throw reason; }, 60000);
  const observed = running.then(() => { completed = true; }, error => { completed = true; return error; });
  assert.equal(f.timers.size, 1); f.tick(); assert.equal(cancelCalls, 1); f.tick(); assert.equal(cancelCalls, 2);
  await Promise.resolve(); assert.equal(completed, false, 'cancel intent must not release owner before native wait finishes');
  assert.equal(stopped, true);
  if (nativeReject) rejectNative(new Error('native completion failure')); else resolveNative(-10001);
  assert.equal(await observed, reason); assert.equal(f.timers.size, 0); tests++;
}
{
  const f = fixture(); const failure = new Error('native startup failure');
  const bridge = { runJavaProcessor: () => Promise.reject(failure), cancelJavaProcessor: () => false };
  await assert.rejects(f.invoke(bridge, ...args, () => {}), error => error === failure);
  assert.equal(f.timers.size, 0); tests++;
}
console.log(`PASS production processor invocation: ${tests} complete/error/cancel/retry cases, preserved first error and no premature owner release/timer leak`);

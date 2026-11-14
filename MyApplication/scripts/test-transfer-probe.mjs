/** 执行真实ArkTS包装/桥接方法，验证边界、观察代次与真实Native收敛前的owner保留。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

assert.equal(process.argv[2], '--output');
const output = assertExternalOutputPath(process.argv[3], { root: PROJECT_ROOT });
const passed = [], inputs = [];
function actualMethod(relative, className, name, bindings) {
  const filename = path.join(PROJECT_ROOT, relative), source = fs.readFileSync(filename, 'utf8');
  inputs.push({ path: relative, sha256: crypto.createHash('sha256').update(source).digest('hex') });
  const ast = compiler.createSourceFile(filename, source, compiler.ScriptTarget.Latest, true);
  const type = ast.statements.find(node => node.name?.getText(ast) === className);
  const method = type.members.find(node => node.name?.getText(ast) === name); assert.ok(method);
  const result = compiler.transpileModule('class Harness {' + method.getText(ast) + '}', {
    compilerOptions: { target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true });
  assert.equal((result.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
  return new Function(...Object.keys(bindings), result.outputText + ';return Harness;')(...Object.values(bindings));
}
let active = 0, calls = [], responder;
const Native = { probeTransfer(...args) { calls.push(args); return responder(...args); } };
const Wrapper = actualMethod('feature_core/src/main/ets/download/DownloadManager.ets', 'DownloadManager', 'probeTransfer', {
  dlEngine: () => Native, ProcessActivityCoordinator: { instance: () => ({ acquireFileTask() {
    active++; let released = false; return () => { assert.equal(released, false); released = true; active--; };
  } }) }
});
const wrapper = new Wrapper(); wrapper.caBundleInitialized_ = true;
const sample = { httpStatus: 206, receivedBytes: 262144, elapsedMs: 900, ttfbMs: 100,
  completedSample: true, rangeHonored: true, errorKind: '' };
responder = async () => sample;
assert.deepEqual(await wrapper.probeTransfer('https://official.example/file', 1048576), sample);
assert.deepEqual(calls.pop(), ['https://official.example/file', 1048576, 262144, 5, 'amcl/0.1 (OHOS; libcurl/8.10.1)']);
assert.equal(active, 0); passed.push('defaults and all metrics pass through production wrapper');
for (const args of [[0], [1048576, 524289], [1048576, 262144, 9], [NaN], [1048576, 1.5]]) {
  const before = calls.length; await assert.rejects(wrapper.probeTransfer('https://official.example/file', ...args), /bounds/);
  assert.equal(calls.length, before); assert.equal(active, 0);
}
passed.push('invalid limits never acquire a process owner or call Native');
await assert.rejects(wrapper.probeTransfer('https://official.example/file', 1048576, 262144, 5, 'amcl/test', () => false), /ObserverCancelled/);
assert.equal(active, 0); passed.push('cancelled observer before start sends zero HTTP work');
let releaseNative, current = true;
responder = () => new Promise(resolve => { releaseNative = resolve; });
const pending = wrapper.probeTransfer('https://official.example/file', 1048576, 262144, 5, 'amcl/test', () => current);
assert.equal(active, 1); current = false; await Promise.resolve(); assert.equal(active, 1);
releaseNative(sample); await assert.rejects(pending, /ObserverCancelled/); assert.equal(active, 0);
passed.push('late observer cancellation rejects publication only and retains owner until actual Native settlement');
current = true;
responder = () => new Promise(resolve => { releaseNative = resolve; });
const publication = wrapper.probeTransfer('https://official.example/file', 1048576, 262144, 1, 'amcl/test', () => current);
assert.equal(active, 1);
await assert.rejects(publication, /ProbeDeadlineExceeded/); assert.equal(active, 1);
releaseNative(sample); await new Promise(resolve => setImmediate(resolve)); assert.equal(active, 0);
passed.push('publication timeout remains bounded while retaining the real queued Native owner until settlement');
responder = () => { throw new Error('synchronous bridge failure'); };
await assert.rejects(wrapper.probeTransfer('https://official.example/file', 1048576), /synchronous bridge failure/);
assert.equal(active, 0); passed.push('synchronous bridge failure releases the owner once');
responder = async () => { throw new Error('Native boundary failure'); };
await assert.rejects(wrapper.probeTransfer('https://official.example/file', 1048576), /Native boundary failure/);
assert.equal(active, 0); passed.push('Native exceptional completion releases the owner once');
wrapper.caBundleInitialized_ = false;
await assert.rejects(wrapper.probeTransfer('https://official.example/file', 1048576), /CA bundle/);
assert.equal(active, 0); passed.push('CA initialization remains mandatory');
const bridgeCalls = [];
const Bridge = actualMethod('entry/src/main/ets/runtime/ProcessRuntime.ets', 'EntryDownloadEngine', 'probeTransfer', {
  testNapi: { downloadProbeTransfer(...args) { bridgeCalls.push(args); return Promise.resolve(sample); } }
});
assert.deepEqual(await new Bridge().probeTransfer('https://official.example/file', 4096, 2048, 3, 'amcl/custom'), sample);
assert.deepEqual(bridgeCalls[0], ['https://official.example/file', 4096, 2048, 3, 'amcl/custom']);
passed.push('real HAP bridge forwards every measurement argument to the new NAPI entry');
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify({ recordedAt: new Date().toISOString(), passed: passed.length, cases: passed, inputs }, null, 2));
for (const item of passed) console.log('PASS ' + item);

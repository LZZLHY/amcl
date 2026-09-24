#!/usr/bin/env node
/** 直接回放实际采样函数，确保 hdc 断线/错误不被错误解释成游戏或启动器死亡。 */
import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('./device-automation/capture-runtime-process.mjs', import.meta.url), 'utf8');
const start = source.indexOf('function sample() {');
const end = source.indexOf('\nfunction finish(', start);
assert.ok(start >= 0 && end > start, '生产采样入口发生变化时测试必须拒绝静默失效');
const factory = new Function('hdc', 'summary', 'console', source.slice(start, end) + '\nreturn sample;');

// 只替换设备命令边界，不在测试里复制 header/错误判定；不访问任何真实设备或文件输出。
function observe(stdout, status = 0, timedOut = false) {
  const summary = { samples: [], observationFailures: 0, retainedLines: 0 };
  factory({ shell(command) {
    assert.equal(command, 'ps -A -o PID,PPID,NAME');
    return { stdout, stderr: '', status, timedOut };
  } }, summary, { log() {} })();
  return summary;
}
for (const result of [
  observe('[Fail][E001005] Device not found or connected'),
  observe(''), observe('PID PPID NAME\n', 1), observe('PID PPID NAME\n', 0, true),
]) {
  assert.equal(result.observationFailures, 1);
  assert.equal(result.samples[0].available, false);
  assert.equal(result.samples[0].processes, null);
}
const empty = observe('   PID   PPID NAME\n 1 0 init\n');
assert.equal(empty.samples[0].available, true);
assert.deepEqual(empty.samples[0].processes, []);
const alive = observe('   PID   PPID NAME\n 1 0 init\n 101 566 com.amcl.launcher\n 102 566 com.amcl.launcher:game\n');
assert.equal(alive.observationFailures, 0);
assert.equal(alive.samples[0].processes.length, 2);
assert.ok(alive.samples[0].processes.every(line => line.includes('com.amcl.launcher')));
console.log('PASS runtime process capture: transport failures are unavailable, never false process death');

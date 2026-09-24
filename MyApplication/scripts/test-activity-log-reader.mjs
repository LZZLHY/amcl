import assert from 'node:assert/strict';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const fixture = evidenceRuntime();
const { ActivityLogModel, logLevel, logSpans } = fixture.load('entry/src/main/ets/components/ActivityLogModel.ets');
const model = new ActivityLogModel();
const rows = () => Array.from({ length: model.totalCount() }, (_, i) => model.getData(i));
for (const text of ['[2026-09-10 20:00:00][E][AMCL] failed', '[20:00:00] [Render thread/ERROR]: test',
  '\tat net.minecraft.Game.main(Game.java:12)', 'Caused by: java.lang.IllegalStateException: test']) {
  assert.equal(logLevel(text), 2, text);
}
assert.equal(logLevel('[20:00:00] [main/WARN]: hello'), 1);
assert.equal(logLevel('[20:00:00] [main/INFO]: no error'), 0);
assert.equal(logLevel('errorKind=none'), 0);
await model.setText('first\r\n\r\n[20:00:00] [main/WARN]: 中文\nCaused by: java.lang.Exception: last\n');
assert.equal(model.lineCount, 4);
model.filter(1, '');
assert.deepEqual(rows().map(r => r.lineNumber), [3, 4]);
model.filter(0, '中文');
assert.deepEqual(rows().map(r => r.lineNumber), [3, 4], '命中标题应保留完整事件续行');
model.filter(0, '');
assert.equal(model.firstErrorIndex(), -1, 'WARN 事件的 Caused by 续行继承 WARN，不能单独升级为错误');
for (const row of rows()) assert.equal(logSpans(row, '').map(s => s.text).join(''), row.text || ' ');
assert.ok(logSpans(model.getData(2), '').some(s => s.color === '#FBBF24'));
assert.ok(logSpans(model.getData(2), '中文').some(s => s.color === '#FDE047'));
// More than the former 128 KiB preview and former 16 MiB archive boundary.
const body = 'prefix ' + '0123456789'.repeat(20) + '\n';
const large = 'BEGIN\n' + body.repeat(90000) + 'END';
await model.setText(large);
assert.equal(model.lineCount, 90002);
assert.equal(model.getData(0).text, 'BEGIN');
assert.equal(model.getData(model.totalCount() - 1).text, 'END');
model.filter(0, 'END');
assert.equal(model.getData(0).lineNumber, 90002);
const long = 'x'.repeat(2047) + '😀boundary'.repeat(1000);
await model.setText(long);
assert.equal(rows().map(r => r.text).join(''), long);
assert.ok(rows().every(r => !/[\uD800-\uDBFF]$/.test(r.text)), 'visual chunks must not split a surrogate pair');
model.filter(0, 'x😀boundary');
assert.equal(model.matchingLines, 1);
assert.equal(rows().map(r => r.text).join(''), long);
const oldLoad = model.setText(large);
await model.setText('new document');
assert.equal(await oldLoad, false);
assert.equal(model.getData(0).text, 'new document');
await model.setText('');
assert.equal(model.lineCount, 0);
assert.equal(model.totalCount(), 0);
console.log('PASS: full 18 MiB document, original line numbers, levels/spans, long Unicode lines, filtering and cancelled loads');

fixture.close();

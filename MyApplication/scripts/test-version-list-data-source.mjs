/** 执行真实版本视图数据源及页面拖拽方法，验证SDK交换通知、业务插入顺序和监听生命周期。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionListDataSource.ets', import.meta.url), 'utf8');
const compiled = compiler.transpileModule(source, { compilerOptions: {
  target: compiler.ScriptTarget.ES2022, module: compiler.ModuleKind.CommonJS,
} }).outputText;
const exported = {}; new Function('exports', compiled)(exported);
const DataSource = exported.VersionListDataSource;
/** 仅读取生产视图主键，用于核对每次SDK通知后的真正索引顺序。 */
const read = value => Array.from({ length: value.totalCount() }, (_, index) => value.getData(index));

test('完整替换保留主键，复制输入并通知已注册的真实视图监听者', () => {
  const data = new DataSource(); let reloads = 0;
  const listener = { onDataReloaded() { reloads++; }, onDataMove() { assert.fail('替换不能伪造移动'); } };
  data.registerDataChangeListener(listener); const ids = ['26.3', '1.12.2-forge']; data.replace(ids);
  ids.reverse(); assert.deepEqual(read(data), ['26.3', '1.12.2-forge']); assert.equal(reloads, 1);
  data.unregisterDataChangeListener(listener); data.replace(['26.3']); assert.equal(reloads, 1);
});

test('非相邻业务插入以相邻交换通知SDK，每次通知与实际getData一致且主键不变', () => {
  const data = new DataSource(); const initial = ['a', 'b', 'c', 'd', 'e']; data.replace(initial);
  let mirrored = initial.slice(), moves = 0;
  data.registerDataChangeListener({ onDataReloaded() { assert.fail('拖拽不能重建整个数据集'); },
    onDataMove(from, to) {
      assert.equal(Math.abs(from-to), 1, 'SDK交换两点，非相邻插入必须分解');
      [mirrored[from], mirrored[to]] = [mirrored[to], mirrored[from]]; moves++;
      assert.deepEqual(read(data), mirrored, '通知抵达时Native索引镜像与实际数据一致');
    } });
  assert.equal(data.relocate(0, 4), true); assert.deepEqual(read(data), ['b', 'c', 'd', 'e', 'a']);
  assert.equal(data.relocate(4, 1), true); assert.deepEqual(read(data), ['b', 'a', 'c', 'd', 'e']);
  assert.equal(moves, 7); assert.deepEqual([...read(data)].sort(), initial);
});

test('越界或小数移动不改变任何主键，越界读取不制造空版本', () => {
  const data = new DataSource(); data.replace(['a', 'b']);
  for (const pair of [[-1, 1], [0, 2], [0.5, 1], [0, Number.NaN]]) assert.equal(data.relocate(...pair), false);
  assert.deepEqual(read(data), ['a', 'b']); assert.throws(() => data.getData(2), /索引越界/);
});

test('真实页面移除插入与视图交换通知同步，最终顺序可由原持久化入口继续消费', () => {
  const view = fs.readFileSync(new URL('../entry/src/main/ets/components/VersionManagerSheet.ets', import.meta.url), 'utf8');
  const start = view.indexOf('  private relocateVersionRow_('), end = view.indexOf('\n  /**', start);
  assert.ok(start > 0 && end > start);
  const code = compiler.transpileModule('class Probe {\n' + view.slice(start, end)
    + '\n}\nmodule.exports=Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} }; new Function('module', code)(module);
  const subject = new module.exports(); const data = new DataSource();
  subject.orderVersions = ['a', 'b', 'c', 'd']; data.replace(subject.orderVersions);
  subject.versionRowsDataSource_ = data;
  subject.refreshVersionRows_ = () => data.replace(subject.orderVersions);
  subject.relocateVersionRow_(0, 3); assert.deepEqual(subject.orderVersions, ['b', 'c', 'd', 'a']);
  assert.deepEqual(read(data), subject.orderVersions);
  subject.relocateVersionRow_(3, 1); assert.deepEqual(read(data), subject.orderVersions);
});

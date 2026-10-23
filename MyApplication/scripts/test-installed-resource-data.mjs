/**
 * 执行真实行模型、全量搜索投影和共享工作闸门，覆盖大清单、禁用项、稳定引用及取消收敛。
 * 只替换宿主没有的 ArkUI 装饰器，不复制生产搜索算法，也不创建真实网络或磁盘模组目录。
 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';
const load = loader();
const { InstalledResourceData, InstalledResourceRow } = load('entry/src/main/ets/components/InstalledResourceData.ets');
const { InstalledResourceWork } = load('entry/src/main/ets/components/InstalledResourceWork.ets');
const values = (index) => ({
  filePath: `/instance/mods/mod-${index}.jar${index % 3 === 0 ? '.disabled' : ''}`,
  filename: `Fabric-Library-${index}.jar${index % 3 === 0 ? '.disabled' : ''}`,
  displayName: `Fabric-Library-${index}`, enabled: index % 3 !== 0,
  sizeBytes: index, iconUrl: '', updateState: 'none', latestVersionNumber: '', updatingPct: 0, integrity: 'unknown',
});
const data = new InstalledResourceData();
let reloads = 0;
const listener = { onDataReloaded() { reloads++; } };
data.registerDataChangeListener(listener);
data.registerDataChangeListener(listener);
const rows = Array.from({ length: 2000 }, (_, index) => new InstalledResourceRow(values(index)));
data.replace(rows);
assert.equal(data.totalCount(), 2000);
assert.equal(reloads, 1, '一个监听器只能登记一次');
assert.equal(data.filter('  FABRIC 1998  '), 1);
assert.equal(data.getData(0).enabled, false, '第64项之后的禁用模组仍可离线搜索');
assert.equal(data.getData(0), rows[1998], '过滤保留原始资源对象，不按投影下标另造记录');
data.filter('does-not-exist');
assert.equal(data.totalCount(), 0);
assert.equal(data.allRows().length, 2000, '空结果不丢原始清单');
data.filter('');
assert.equal(data.totalCount(), 2000);
assert.equal(data.getData(1998), rows[1998]);
const original = data.find(rows[0].filePath);
original.iconUrl = 'https://example.invalid/icon';
assert.equal(reloads, 4, '单行状态变更不要求全量列表通知');
data.replace(rows.map((row, index) => new InstalledResourceRow({ ...values(index), integrity: 'verified' })));
assert.equal(data.find(rows[0].filePath), original, '刷新相同路径维持ObjectLink绑定实例');
assert.equal(original.integrity, 'verified');
data.unregisterDataChangeListener(listener);
const count = reloads;
data.filter('fabric');
assert.equal(reloads, count);
data.replace([new InstalledResourceRow(values(2100))]);
assert.equal(data.find(rows[0].filePath), undefined, '切换目录清理旧路径索引');

const gate = new InstalledResourceWork(3);
let active = 0;
let peak = 0;
let completed = 0;
await Promise.all(Array.from({ length: 50 }, () => gate.run(async () => {
  peak = Math.max(peak, ++active);
  await new Promise(resolve => setTimeout(resolve, 1));
  active--;
  completed++;
}, () => false)));
assert.equal(peak, 3);
assert.equal(completed, 50);
const single = new InstalledResourceWork(1);
let unlock;
const first = single.run(() => new Promise(resolve => { unlock = resolve; }), () => false);
let cancelled = false;
let ran = false;
const queued = single.run(async () => { ran = true; }, () => cancelled);
cancelled = true;
unlock();
await Promise.all([first, queued]);
assert.equal(ran, false, '离页后的等待项不得再发起请求');
await assert.rejects(single.run(async () => { throw new Error('expected'); }, () => false), /expected/);
await single.run(async () => { ran = true; }, () => false);
assert.equal(ran, true, '失败必须归还预算，不阻塞下一轮');
console.log('PASS: 2000项全量/禁用离线搜索、清空恢复、稳定行实例、旧路径清理、50项三槽并发、排队取消与失败收敛');

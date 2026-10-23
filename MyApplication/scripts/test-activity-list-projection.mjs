/** 执行实际页面刷新方法与真实LazyForEach数据源，核验离页、重入、失败和分组语义。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/DownloadHistoryPage.ets', import.meta.url), 'utf8');
const ast = compiler.createSourceFile('DownloadHistoryPage.ets', source, compiler.ScriptTarget.Latest, true);
const component = ast.statements.find(node => node.name?.text === 'DownloadHistoryPage');
const snippets = ['refreshRecords', 'onPageShow', 'onPageHide', 'aboutToDisappear'].map(name => {
  const node = component.members.find(node => node.name?.text === name); assert.ok(node?.body, name);
  return source.slice(node.getStart(ast), node.end);
}).join('\n');
const code = compiler.transpileModule('class Probe {' + snippets + '}\nmodule.exports=Probe;',
  { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { resolve, reject, promise }; };
const turn = () => new Promise(resolve => setImmediate(resolve));

/**
 * 无参数创建历史页面Probe，实际执行生产refreshRecords及show/hide/disappear，读取策略不在夹具复制。
 * 历史owner端口只返回受控Promise，requests保存取消检查与兑现接口；AppStorage发布仅记入revisions。
 * 分组更新端口只计数，行数据源的真实分组/监听规则在后续独立用例直接加载生产类验证。
 * 返回实例和请求集合，用例改变页面代次后再兑现旧请求；无文件/FD/真实定时器，操作收尾后由GC回收。
 */
function fixture() {
  const requests = [], revisions = []; const module = { exports: {} };
  const store = { init: async () => {}, readSnapshotAsync(cancelled) {
    const result = deferred(); requests.push({ ...result, cancelled }); return result.promise;
  } };
  new Function('module', 'getDownloadHistoryStore', 'activityStorageAlert', 'AppStorage', code)(module,
    () => store, () => 0, { setOrCreate: (key, value) => revisions.push([key, value]) });
  const subject = new module.exports(); Object.assign(subject, { hostVisible: true, refreshing: false,
    selectionBusy: false, refreshGeneration_: 0, refreshAgain_: false, context: { filesDir: '/sandbox' },
    records: [{ startedAt: 1, status: 'success' }], availability: new Map([[1, true]]), ledgerBytes: 10,
    detailRevision: 0, loaded: false, loadError: '', updateGroups_() { this.groupPublishes = (this.groupPublishes ?? 0) + 1; } });
  return { subject, requests, revisions };
}

test('路由隐藏拒绝旧记录/占用/错误；快速返回合并新读取且只有新结果能刷新详情', async () => {
  const f = fixture(); const first = f.subject.refreshRecords(); await turn();
  f.subject.onPageHide(); f.subject.onPageShow(); assert.equal(f.requests.length, 1);
  f.requests[0].resolve({ records: [{ startedAt: 2 }], ledgerIds: [2], ledgerBytes: 999 }); await first; await turn();
  assert.equal(f.requests.length, 2); assert.equal(f.requests[0].cancelled(), true);
  assert.equal(f.subject.records[0].startedAt, 1); assert.equal(f.subject.ledgerBytes, 10); assert.equal(f.revisions.length, 0);
  f.requests[1].resolve({ records: [{ startedAt: 3 }], ledgerIds: [3], ledgerBytes: 30 }); await turn();
  assert.equal(f.subject.records[0].startedAt, 3); assert.equal(f.subject.ledgerBytes, 30);
  assert.equal(f.subject.detailRevision, 1); assert.equal(f.subject.availability.has(1), false);
  assert.equal(f.subject.availability.get(3), true);
});

test('真正读取失败保留旧列表并显示错误，销毁后的失败不能覆盖页面或补发请求', async () => {
  const f = fixture(); const first = f.subject.refreshRecords(); await turn();
  f.requests[0].reject(new Error('disk unavailable')); await first;
  assert.equal(f.subject.records[0].startedAt, 1); assert.match(f.subject.loadError, /disk unavailable/);
  const next = f.subject.refreshRecords(); await turn(); f.subject.refreshRecords(); f.subject.aboutToDisappear();
  f.requests[1].reject(new Error('cancelled old read')); await next; await turn();
  assert.equal(f.requests.length, 2); assert.equal(f.subject.hostVisible, false); assert.equal(f.subject.loadError, '');
  assert.equal(f.subject.detailRevision, 0);
});

test('同页重复元数据刷新合并为一次后续真实读取，忙碌/隐藏不读取目录', async () => {
  const f = fixture(); const first = f.subject.refreshRecords(); await turn();
  f.subject.refreshRecords(); f.subject.refreshRecords();
  f.requests[0].resolve({ records: [], ledgerIds: [], ledgerBytes: 0 }); await first; await turn();
  assert.equal(f.requests.length, 2); f.requests[1].resolve({ records: [], ledgerIds: [], ledgerBytes: 0 }); await turn();
  f.subject.selectionBusy = true; await f.subject.refreshRecords(); assert.equal(f.requests.length, 2);
  f.subject.selectionBusy = false; f.subject.onPageHide(); await f.subject.refreshRecords(); assert.equal(f.requests.length, 2);
});

test('真正行数据源保持日期/顺序/组尾/刷新身份，注销监听者后不更新，不执行任何IO', () => {
  const rowsSource = fs.readFileSync(new URL('../entry/src/main/ets/components/ActivityListDataSource.ets', import.meta.url), 'utf8');
  const compiled = compiler.transpileModule(rowsSource, { compilerOptions: { target: compiler.ScriptTarget.ES2022,
    module: compiler.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} }; new Function('module', 'exports', 'require', compiled)(module, module.exports,
    () => ({ activityCategory: record => record.category }));
  const rows = new module.exports.ActivityListDataSource(); let reloads = 0;
  const listener = { onDataReloaded() { reloads++; } }; rows.registerDataChangeListener(listener);
  const a = { startedAt: 30, category: 'launch' }, b = { startedAt: 20, category: 'download' }, c = { startedAt: 10, category: 'launch' };
  const groups = [{ key: 'today', label: '今天', records: [a, b] }, { key: 'before', label: '昨天', records: [c] }];
  rows.replace(groups, 1); assert.equal(rows.totalCount(), 5); assert.equal(reloads, 1);
  assert.equal(rows.getData(0).header, true); assert.equal(rows.getData(0).groupCount, 2);
  assert.equal(rows.getData(1).record, a); assert.equal(rows.getData(1).lastInGroup, false);
  assert.equal(rows.getData(2).record, b); assert.equal(rows.getData(2).lastInGroup, true);
  assert.equal(rows.getData(4).groupIndex, 1); const oldKey = rows.getData(1).key;
  rows.replace(groups, 2); assert.notEqual(rows.getData(1).key, oldKey); assert.equal(rows.getData(1).record.startedAt, 30);
  rows.unregisterDataChangeListener(listener); rows.replace([], 3); assert.equal(reloads, 2); assert.equal(rows.totalCount(), 0);
  assert.throws(() => rows.getData(0), /索引越界/); assert.deepEqual(groups[0].records, [a, b]);
});

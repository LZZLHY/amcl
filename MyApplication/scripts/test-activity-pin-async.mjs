/** 执行两个生产pin入口；仅替换持久owner Promise，验证await、忙态、失败及离页拒旧。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
/** 返回可控制的持久写完成边界；Promise未兑现时代表owner尚未确认，不模拟实际pin文件写入。 */
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

/**
 * file/componentName定位生产组件，names选择实际方法，operation替换唯一的ledgerSetPinnedAsync端口。
 * 从源码AST抽取并转译方法，返回新Probe实例；缺少方法即断言失败，pin/忙态/代次规则均来自生产代码。
 * 页面字段由各夹具初始化；此层不加载ArkUI树或真实账本，不能把其成功计数当作设备/磁盘验收。
 */
function load(file, componentName, names, operation) {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/' + file, import.meta.url), 'utf8');
  const ast = compiler.createSourceFile(componentName + '.ets', source, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.name?.text === componentName);
  const snippets = names.map(name => { const node = component.members.find(node => node.name?.text === name);
    assert.ok(node?.body, name); return source.slice(node.getStart(ast), node.end); }).join('\n');
  const code = compiler.transpileModule('class Probe {' + snippets + '}\nmodule.exports=Probe;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} }; new Function('module', 'ledgerSetPinnedAsync', code)(module, operation);
  return new module.exports();
}

/**
 * 无参数创建占用面板夹具，执行生产pin_与aboutToDisappear；每次owner请求保存参数并返回新pending。
 * refresh_仅计数，返回subject/calls/刷新读数，供用例控制持久成功、失败和离页后的旧回调。
 * 页面销毁不取消owner写入，用例必须兑现或拒绝并等待原操作；夹具没有文件、FD或动画资源。
 */
function panelFixture() {
  const calls = []; let refreshes = 0;
  const subject = load('components/ActivityStoragePanel.ets', 'ActivityStoragePanel', ['pin_', 'aboutToDisappear'],
    (...args) => { const pending = deferred(); calls.push({ args, ...pending }); return pending.promise; });
  Object.assign(subject, { context: { filesDir: '/sandbox' }, busy: false, active: true, generation: 0, error: '',
    refresh_: async () => { refreshes++; } });
  return { subject, calls, refreshes: () => refreshes };
}

test('占用面板在durable Promise完成前忙碌、不刷新、不重复写，成功后刷新真实占用', async () => {
  const f = panelFixture(); const pending = f.subject.pin_({ activityId: 7, pinned: false });
  assert.equal(f.subject.busy, true); assert.equal(f.refreshes(), 0); assert.deepEqual(f.calls[0].args, ['/sandbox', 7, true]);
  await f.subject.pin_({ activityId: 7, pinned: false }); assert.equal(f.calls.length, 1);
  f.calls[0].resolve(); await pending; assert.equal(f.subject.busy, false); assert.equal(f.refreshes(), 1);
});

test('占用面板保存失败保留原按钮/错误，离页后的失败不发布，重新显示不会永久busy', async () => {
  const f = panelFixture(); const pending = f.subject.pin_({ activityId: 7, pinned: false });
  f.calls[0].reject(new Error('durability-unknown')); await pending;
  assert.match(f.subject.error, /durability-unknown/); assert.equal(f.refreshes(), 0); assert.equal(f.subject.busy, false);
  const hidden = f.subject.pin_({ activityId: 7, pinned: false }); f.subject.aboutToDisappear();
  f.calls[1].reject(new Error('old disk error')); await hidden; assert.equal(f.subject.error, ''); assert.equal(f.subject.busy, false);
});

/**
 * 创建活动7的详情pin夹具，执行生产togglePinned_/notifyBusy_/hostVisibilityChanged_。
 * 只替换持久写、宿主通知和提示端口；calls保留每次输入与pending，busy/toasts/changes观测发布顺序。
 * onMetadataChanged端口额外断言发布前已解除保存忙态，不直接修改生产页面的pin或代次判断。
 * 用例可隐藏宿主或换活动后再兑现旧写入；await操作收尾后实例即可释放，不持有真实读取租约。
 */
function workspaceFixture() {
  const calls = [], toasts = [], busy = []; let changes = 0;
  const subject = load('pages/ActivityLogPage.ets', 'ActivityLogWorkspace', ['togglePinned_', 'notifyBusy_', 'hostVisibilityChanged_'],
    (...args) => { const pending = deferred(); calls.push({ args, ...pending }); return pending.promise; });
  Object.assign(subject, { context: { filesDir: '/sandbox' }, pageActive: true, pinSaving_: false, pinGeneration_: 0,
    activityId: 7, pinned: false, sharing: false, exportingEvidence: false,
    hostVisible: true, stopFollowing_() {}, model: { cancel() {} }, readGeneration: 0,
    evidenceGeneration: 0, diagnosisGeneration: 0,
    onBusyChanged: value => busy.push(value), toast_: value => toasts.push(value), onMetadataChanged: () => {
      assert.equal(subject.pinSaving_, false, '宿主刷新前先解除保存忙态'); changes++;
    } });
  return { subject, calls, toasts, busy, changes: () => changes };
}

test('详情保存完成前不改变pin/通知宿主，成功解除忙态后才发布同活动元数据', async () => {
  const f = workspaceFixture(); const pending = f.subject.togglePinned_();
  assert.equal(f.subject.pinSaving_, true); assert.equal(f.subject.pinned, false); assert.equal(f.changes(), 0);
  await f.subject.togglePinned_(); assert.equal(f.calls.length, 1);
  f.calls[0].resolve(); await pending; assert.equal(f.subject.pinned, true); assert.equal(f.changes(), 1);
  assert.equal(f.subject.pinSaving_, false); assert.equal(f.busy.at(-1), false); assert.equal(f.toasts.length, 1);
});

test('详情owner失败不翻按钮；隐藏/换活动后的旧结果不更新pin、通知或toast', async () => {
  const failed = workspaceFixture(); const pending = failed.subject.togglePinned_();
  failed.calls[0].reject(new Error('disk failure')); await pending;
  assert.equal(failed.subject.pinned, false); assert.equal(failed.subject.pinSaving_, false); assert.equal(failed.changes(), 0);
  assert.match(failed.toasts[0], /disk failure/);
  for (const kind of ['hide', 'replace']) {
    const f = workspaceFixture(); const old = f.subject.togglePinned_();
    if (kind === 'hide') { f.subject.hostVisible = false; f.subject.hostVisibilityChanged_(); }
    else f.subject.activityId = 8;
    f.calls[0].resolve(); await old;
    assert.equal(f.subject.pinned, false); assert.equal(f.changes(), 0); assert.equal(f.toasts.length, 0);
  }
});

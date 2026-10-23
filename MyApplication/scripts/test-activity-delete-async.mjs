/** 执行真实clear/remove UI方法；异步owner可控，验证成功前等待、失败保留和离页拒旧。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
/** 返回由用例显式兑现/拒绝的owner完成边界；只控制等待时序，不实现任何目录删除。 */
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
/** 让已经派发的Promise回调进入下一轮事件循环，不把宿主等待时长当成设备性能。 */
const turn = () => new Promise(resolve => setImmediate(resolve));

/**
 * file/name指定仓库内生产组件，methods指定必须存在的方法，bindings只提供被调用的边界端口。
 * 从真实AST抽取原方法并转译为独立Probe，返回新实例；方法缺失立即断言失败，不手抄删除策略。
 * 本层不创建ArkUI或文件系统资源，组件初始字段与系统替身由调用夹具补齐，仅证明页面交接契约。
 */
function load(file, name, methods, bindings) {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/' + file, import.meta.url), 'utf8');
  const ast = compiler.createSourceFile(name + '.ets', source, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.name?.text === name);
  const snippets = methods.map(name => { const node = component.members.find(node => node.name?.text === name);
    assert.ok(node?.body, name); return source.slice(node.getStart(ast), node.end); }).join('\n');
  const code = compiler.transpileModule('class Probe {' + snippets + '}\nmodule.exports=Probe;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} }; new Function('module', ...Object.keys(bindings), code)(module, ...Object.values(bindings));
  return new module.exports();
}

/**
 * 无参数创建历史清空页面夹具：执行生产clearAll/确认/可清理判断/隐藏方法。
 * 账本删除、保护原因、历史清空和系统对话框由端口替身承接，返回pending及可观测调用/事件集合。
 * 用例通过reason/choice控制保护与取消，通过pending兑现真实方法的await边界；不声称删除了磁盘。
 * 隐藏只撤销页面发布资格，不取消已派发owner；用例须等待操作收尾。本夹具不占外置目录或FD。
 */
function clearFixture() {
  const pending = deferred(), events = []; let calls = 0, dialogs = 0, protectedReason = '', choice = 1;
  const subject = load('pages/DownloadHistoryPage.ets', 'DownloadHistoryPage', ['clearAll', 'canClear_', 'confirmClearAll_', 'onPageHide'], {
    ledgerClearAsync: () => { calls++; return pending.promise; }, ledgerClearBlockReasonAsync: async () => protectedReason,
    getDownloadHistoryStore: () => ({ clear: async () => { events.push('history'); } }), formatLogBytes: String,
    hilog: { warn() {} }, TAG: 'test',
  });
  Object.assign(subject, { loaded: true, clearing: false, confirmingClear_: false, selectionBusy: false, refreshing: false,
    hostVisible: true, records: [{ startedAt: 1 }], ledgerBytes: 100, clearGeneration_: 0, refreshGeneration_: 0, refreshAgain_: false,
    context: { filesDir: '/sandbox' }, theme: { primary: '#fff', error: '#f00' }, clearError: '',
    safeToast_: message => events.push(message), refreshRecords: async () => { events.push('refresh'); },
    getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => { dialogs++; return { index: choice }; } }) }),
  });
  return { subject, pending, events, calls: () => calls, dialogs: () => dialogs,
    reason: value => { protectedReason = value; }, choice: value => { choice = value; } };
}

test('clear等待真实目录删除结束后才清历史和提示；失败保留历史并释放忙态', async () => {
  const f = clearFixture(); const pending = f.subject.clearAll(); assert.equal(f.subject.clearing, true);
  assert.deepEqual(f.events, []); await f.subject.clearAll(); assert.equal(f.calls(), 1);
  f.pending.resolve(); await pending; assert.equal(f.events[0], 'history'); assert.equal(f.subject.clearing, false);
  const failure = clearFixture(); const failed = failure.subject.clearAll(); failure.pending.reject(new Error('partial delete EIO')); await failed;
  assert.equal(failure.events.includes('history'), false); assert.match(failure.subject.clearError, /partial delete/); assert.equal(failure.subject.clearing, false);
});

test('受保护活动/取消不进入删除；离页后已派发的事务收尾但不发布旧提示', async () => {
  const protectedCase = clearFixture(); protectedCase.reason('日志正在读取或导出'); await protectedCase.subject.confirmClearAll_();
  assert.equal(protectedCase.calls(), 0); assert.equal(protectedCase.dialogs(), 0);
  const cancelled = clearFixture(); cancelled.choice(0); await cancelled.subject.confirmClearAll_(); assert.equal(cancelled.calls(), 0);
  const hidden = clearFixture(); const pending = hidden.subject.clearAll(); hidden.subject.onPageHide(); hidden.pending.resolve(); await pending;
  assert.deepEqual(hidden.events, ['history']); assert.equal(hidden.subject.clearing, false);
});

/**
 * 创建活动7的详情删除夹具，执行实际removeLedger_，删除端口返回受控Promise并计数。
 * canDelete_只替换页面的忙态准入，toast/close只收集发布事实；保留策略和物理删除由owner测试验证。
 * 返回实例、pending及观测集合，供用例模拟隐藏或切换活动；旧回调仍收尾，但不能关闭新活动。
 * 用例负责兑现/拒绝并等待pending操作，夹具本身没有计时器、句柄或文件需要清理。
 */
function removeFixture() {
  const pending = deferred(), events = []; let calls = 0;
  const subject = load('pages/ActivityLogPage.ets', 'ActivityLogWorkspace', ['removeLedger_'], {
    ledgerRemoveAsync: () => { calls++; return pending.promise; }, hilog: { warn() {} }, TAG: 'test',
  });
  Object.assign(subject, { context: { filesDir: '/sandbox' }, activityId: 7, pinGeneration_: 0, pageActive: true, deleting: false,
    canDelete_: () => !subject.deleting, toast_: value => events.push(value), close_: () => events.push('close') });
  return { subject, pending, events, calls: () => calls };
}

test('单条删除await完成前不close/toast、不重复派发，失败保留当前详情', async () => {
  const f = removeFixture(); const pending = f.subject.removeLedger_(); assert.equal(f.subject.deleting, true); assert.deepEqual(f.events, []);
  await f.subject.removeLedger_(); assert.equal(f.calls(), 1); f.pending.resolve(); await pending;
  assert.equal(f.events.at(-1), 'close'); assert.equal(f.subject.deleting, false);
  const failed = removeFixture(); const failing = failed.subject.removeLedger_(); failed.pending.reject(new Error('delete EIO')); await failing;
  assert.deepEqual(failed.events, ['delete EIO']); assert.equal(failed.subject.deleting, false);
});

test('单条删除离页/换活动后仍由owner完成，旧回调不得关闭另一个活动或发布成功', async () => {
  for (const kind of ['hide', 'replace']) {
    const f = removeFixture(); const pending = f.subject.removeLedger_();
    if (kind === 'hide') { f.subject.pageActive = false; f.subject.pinGeneration_++; } else f.subject.activityId = 8;
    f.pending.resolve(); await pending; assert.deepEqual(f.events, []); assert.equal(f.subject.deleting, false);
  }
});

/**
 * 创建单条删除确认夹具，执行生产确认、删除、准入及host可见性方法；不复写确认控制流。
 * 对话框和异步清单是端口替身，返回可变entries、受控dialog及选项/调用计数，供注入unknown与取消。
 * 清单中的数字只代表本用例输入，不作为实际磁盘占用证明；实际可信计量另由账本IO回归覆盖。
 * 用例在对话框打开期间改变活动或可见代次，再兑现并等待操作，以核实owner派发资格没有越代。
 */
function confirmationFixture() {
  const dialog = deferred(), events = [], entries = [{ activityId: 7, bytes: 123, bytesState: 'current' }];
  let options, calls = 0;
  const subject = load('pages/ActivityLogPage.ets', 'ActivityLogWorkspace',
    ['requestRemoveLedger_', 'removeLedger_', 'canDelete_', 'hostVisibilityChanged_'], {
      ledgerRemovalBlockReason: () => '', ledgerRemovalBlockReasonAsync: async () => '', ledgerListAsync: async () => entries,
      ledgerRemoveAsync: async () => { calls++; }, formatLogBytes: String, ledgerStateLabel: String,
      hilog: { warn() {} }, TAG: 'test',
    });
  Object.assign(subject, { context: { filesDir: '/sandbox' }, activityId: 7, pinGeneration_: 0, pageActive: true,
    hostVisible: true, loading: false, reading: false, sharing: false, copying: false, exportingEvidence: false,
    pinSaving_: false, deleting: false, confirmingRemoval_: false, manifest: { title: 'fixture', state: 1 },
    theme: { primary: '#fff', error: '#f00' }, shareError: '', toast_: value => events.push(value), close_: () => events.push('close'),
    stopFollowing_() {}, model: { cancel() {} }, readGeneration: 0, evidenceGeneration: 0, diagnosisGeneration: 0,
    getUIContext: () => ({ getPromptAction: () => ({ showDialog(value) { options = value; return dialog.promise; } }) }),
  });
  return { subject, dialog, entries, events, options: () => options, calls: () => calls };
}

test('真实单条确认复用异步可信占用，取消/换活动/隐藏不派发删除', async () => {
  for (const kind of ['cancel', 'replace', 'hide']) {
    const f = confirmationFixture(); const pending = f.subject.requestRemoveLedger_(); await turn();
    assert.match(f.options().message, /123/); assert.equal(f.subject.confirmingRemoval_, true); assert.equal(f.calls(), 0);
    if (kind === 'replace') f.subject.activityId = 8;
    if (kind === 'hide') { f.subject.hostVisible = false; f.subject.hostVisibilityChanged_(); }
    f.dialog.resolve({ index: kind === 'cancel' ? 0 : 1 }); await pending;
    assert.equal(f.calls(), 0); assert.equal(f.subject.confirmingRemoval_, false); assert.deepEqual(f.events, []);
  }
});

test('未知计量不显示少算数字，实际确认后只派发一次删除并等待原owner', async () => {
  const f = confirmationFixture(); f.entries[0].bytesState = 'unknown';
  const pending = f.subject.requestRemoveLedger_(); await turn(); assert.match(f.options().message, /暂不可读/);
  await f.subject.requestRemoveLedger_(); assert.equal(f.calls(), 0);
  f.dialog.resolve({ index: 1 }); await pending; assert.equal(f.calls(), 1); assert.equal(f.events.at(-1), 'close');
});

/** 执行真实保留组件方法，检验异步刷新/确认/取消与纯策略统计，不镜像生产算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/LogRetentionSettings.ets', import.meta.url), 'utf8');
const ast = compiler.createSourceFile('LogRetentionSettings.ets', source, compiler.ScriptTarget.Latest, true);
const component = ast.statements.find(node => node.name?.text === 'LogRetentionSettings');
const snippets = component.members.filter(node => node.body && node.name?.text !== 'build')
  .map(node => source.slice(node.getStart(ast), node.end)).join('\n');
const code = compiler.transpileModule('class Probe {' + snippets + '}\nmodule.exports=Probe;',
  { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const turn = () => new Promise(resolve => setImmediate(resolve));

/**
 * 无参数创建保留设置Probe，执行真实刷新、确认和保存方法；不创建ArkUI树或复写容量估算/淘汰集合比较。
 * 清单、当前设置、victim列表和持久设置是受控owner端口，calls记录到达次数，hooks可挂起读取/保存。
 * 返回entries/victimSets及对话框选择控制，供制造unknown、确认后集合变化和保存失败；计量数字只是夹具输入。
 * 显隐/销毁由实际方法推进代次，用例须等待所有Promise收尾；夹具不写文件或建立实际读取租约。
 */
function fixture() {
  const calls = { lists: 0, reads: 0, victims: 0, saves: [], maintenance: 0, dialogs: [] };
  let retained = 5, entriesHook, saveHook, dialogIndex = 1;
  const entries = [
    { activityId: 1, category: 'launch', state: 1, bytes: 100, hasGame: true, versionKey: 'A', bytesState: 'current' },
    { activityId: 2, category: 'launch', state: 1, bytes: 300, hasGame: true, versionKey: 'A', bytesState: 'current' },
    { activityId: 3, category: 'launch', state: 1, bytes: 1000, hasGame: true, versionKey: 'B', bytesState: 'current' },
    { activityId: 4, category: 'download', state: 1, bytes: 50, hasGame: false, versionKey: '', bytesState: 'current' },
  ];
  const victimSets = [];
  const module = { exports: {} };
  new Function('module', 'ledgerSessionRetentionAsync', 'ledgerListAsync', 'ledgerRetentionVictimsAsync',
    'ledgerSetSessionRetentionAsync', 'LedgerState', 'formatLogBytes', code)(module,
    async () => { calls.reads++; return retained; }, async (_root, cancelled) => { calls.lists++; return entriesHook ? entriesHook(cancelled) : entries; },
    async () => { calls.victims++; return victimSets.shift() ?? []; }, async (_root, value) => {
      calls.saves.push(value); await saveHook?.(); retained = value; calls.maintenance++;
    }, { RUNNING: 0 }, value => String(value));
  const subject = new module.exports();
  Object.assign(subject, { context: { filesDir: '/sandbox' }, active_: false, settingsVisible_: true, hostVisible_: true,
    foreground_: true, readGeneration_: 0, saveGeneration_: 0, saving: false, loading_: false, retained: 5,
    actualBytes: 0, sessionCount: 0, estimatedPerSlot: 0, versionCount: 0, errorText: '', theme: { primary: '#fff', error: '#f00' },
    getUIContext: () => ({ getPromptAction: () => ({ showDialog: async options => { calls.dialogs.push(options); return { index: dialogIndex }; } }) }),
  });
  return { subject, calls, entries, victimSets, entriesHook: value => { entriesHook = value; },
    saveHook: value => { saveHook = value; }, dialogIndex: value => { dialogIndex = value; } };
}

test('首开只读一次异步索引并按各版本均值估算，无同步全字节/逐victim统计', async () => {
  const f = fixture(); f.subject.aboutToAppear(); await turn();
  assert.equal(f.calls.lists, 1); assert.equal(f.calls.reads, 1); assert.equal(f.subject.actualBytes, 1450);
  assert.equal(f.subject.sessionCount, 3); assert.equal(f.subject.versionCount, 2); assert.equal(f.subject.estimatedPerSlot, 1200);
  assert.equal(f.subject.errorText, ''); assert.equal(f.subject.loading_, false);
});

test('未显示设置Tab不读取，隐藏/销毁拒绝在途结果；unknown不被当成完整数字或空间估算', async () => {
  const f = fixture(); f.subject.settingsVisible_ = false; f.subject.aboutToAppear(); await turn(); assert.equal(f.calls.lists, 0);
  const gate = deferred(); f.entriesHook(() => gate.promise); f.subject.settingsVisible_ = true; f.subject.visibilityChanged_(); await turn();
  f.subject.foreground_ = false; f.subject.visibilityChanged_(); gate.resolve(f.entries); await turn();
  assert.equal(f.subject.actualBytes, 0); assert.equal(f.subject.loading_, false);
  f.entriesHook(undefined); f.entries[0].bytesState = 'unknown'; f.subject.foreground_ = true; f.subject.visibilityChanged_(); await turn();
  assert.equal(f.subject.actualBytes, -1); assert.equal(f.subject.estimatedPerSlot, -1); assert.match(f.subject.errorText, /无法核实/);
  f.subject.aboutToDisappear(); const count = f.calls.lists; await f.subject.refresh(); assert.equal(f.calls.lists, count);
});

test('取消与确认期间新增淘汰项均不保存/删除，只对已确认同集合提交一次设置和维护', async () => {
  const cancelled = fixture(); cancelled.subject.active_ = true; cancelled.victimSets.push([1]); cancelled.dialogIndex(0);
  await cancelled.subject.save(37); assert.deepEqual(cancelled.calls.saves, []); assert.equal(cancelled.calls.maintenance, 0);
  const expanded = fixture(); expanded.subject.active_ = true; expanded.victimSets.push([1], [1, 2]);
  await expanded.subject.save(37); assert.deepEqual(expanded.calls.saves, []); assert.match(expanded.subject.errorText, /已变化/);
  const accepted = fixture(); accepted.subject.active_ = true; accepted.victimSets.push([1], [1]);
  await accepted.subject.save(37); assert.deepEqual(accepted.calls.saves, [37]); assert.equal(accepted.calls.maintenance, 1);
  assert.match(accepted.calls.dialogs[0].message, /100/); assert.equal(accepted.subject.retained, 37);
});

test('真实持久Promise完成前维持saving、不重复派发；失败回读原设置且错误不被refresh覆盖', async () => {
  const f = fixture(); f.subject.active_ = true; const gate = deferred(); f.saveHook(() => gate.promise);
  const pending = f.subject.save(37); await turn(); assert.equal(f.subject.saving, true); assert.equal(f.subject.retained, 5);
  await f.subject.save(100); assert.deepEqual(f.calls.saves, [37]); gate.reject(new Error('disk unavailable')); await pending;
  assert.equal(f.subject.saving, false); assert.equal(f.subject.retained, 5); assert.match(f.subject.errorText, /disk unavailable/);
  assert.equal(f.calls.maintenance, 0);
});

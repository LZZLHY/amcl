/**
 * 版本JVM编辑正文的定向宿主夹具：执行真实非Builder方法和实际字段初值，
 * 仅替换父层读/写、UIContext弹窗与导航边缘，不打开真实偏好或运行ArkUI DSL。
 * 输出必须显式落仓外；结束复核组件字节，父层SDK/设备验收仍独立负责。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

const FILE = 'entry/src/main/ets/components/VersionJvmArgsEditor.ets';
const file = path.join(PROJECT_ROOT, FILE), source = fs.readFileSync(file, 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');
const before = hash(fs.readFileSync(file));
const index = process.argv.indexOf('--output');
assert.ok(index >= 0 && process.argv[index + 1], '必须显式传 --output <E盘仓外目录>');
const base = assertExternalOutputPath(process.argv[index + 1]);
const startedAt = new Date().toISOString();
const output = path.join(base, 'run-' + startedAt.replace(/[-:.]/g, '') + '-' + process.pid);
fs.mkdirSync(output, { recursive: true });
const groups = [];
const { ThemeColors } = makePureEtsLoader()('commons/src/main/ets/common/Theme.ets');

/** 从真实Struct提取字段与非Builder方法；装饰器由宿主模拟生命周期，不复制业务状态机。 */
const ast = compiler.createSourceFile(FILE, source, compiler.ScriptTarget.Latest, true);
const owner = ast.statements.find(node => node.name?.getText(ast) === 'VersionJvmArgsEditor');
assert.ok(owner?.members, '必须存在真实组件');
const body = owner.members.filter(member => member.name?.getText(ast) !== 'build')
  .map(member => member.getText(ast).replace(/@\w+(?:\([^)]*\))?\s*/g, '')).join('\n');
const compiled = compiler.transpileModule('export class ActualEditor {\n' + body + '\n}', {
  fileName: FILE, reportDiagnostics: true,
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
const exports = {};
new Function('exports', 'ThemeColors', 'formatError', compiled.outputText)(exports, ThemeColors, String);

/** 手动完成的是父层Promise，不自行实现编辑/保存/退出判定。 */
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
const settle = async () => { for (let n = 0; n < 12; n++) await Promise.resolve(); };
function fixture({ defaultSave = false, defaultLoad = false, appear = true } = {}) {
  const view = new exports.ActualEditor();
  const calls = { reads: [], writes: [], saved: [], back: 0, close: 0, registered: [], blocked: [], dialogs: [] };
  let reader = () => '-Dold=1', saver = async () => {}, dialog = async () => ({ index: 0 });
  Object.assign(view, { versionId: 'A', ownerKey: 'owner-A', visible: true,
    onSaved: (version, value) => calls.saved.push([version, value]), onBack: () => calls.back++,
    onClose: () => calls.close++, onRegisterDismiss: handler => calls.registered.push(handler),
    onNavigationBlocked: blocked => calls.blocked.push(blocked),
    getUIContext: () => ({ getPromptAction: () => ({ showDialog: options => { calls.dialogs.push(options); return dialog(); } }) }) });
  if (!defaultLoad) view.loadValue = version => { calls.reads.push(version); return reader(version); };
  if (!defaultSave) view.saveValue = (version, value) => { calls.writes.push([version, value]); return saver(version, value); };
  const f = { view, calls, reader: value => { reader = value; }, saver: value => { saver = value; },
    dialog: value => { dialog = value; }, handler: () => calls.registered.filter(x => typeof x === 'function').at(-1),
    switchOwner: (version, ownerKey) => { view.versionId = version; view.ownerKey = ownerKey; view.onSessionChanged_(); } };
  if (appear) view.aboutToAppear();
  return f;
}
async function group(name, action) { await action(); groups.push(name); console.log('PASS ' + name); }
let failure;
try {
  await group('挂载和visible共同控制真实读取；确认值与草稿只来自父owner', () => {
    const f = fixture({ appear: false }); f.view.visible = false; f.view.aboutToAppear(); assert.equal(f.calls.reads.length, 0);
    f.view.visible = true; f.view.onSessionChanged_(); assert.deepEqual(f.calls.reads, ['A']);
    assert.equal(f.view.draft_, '-Dold=1'); assert.equal(f.view.confirmed_, '-Dold=1'); assert.equal(f.view.isDirty_(), false);
    assert.equal(f.calls.writes.length, 0); assert.equal(typeof f.handler(), 'function');
  });
  await group('load抛错明确失败且不能保存，重试才建立确认态', async () => {
    const f = fixture({ appear: false }); f.reader(() => { throw Error('read failed'); }); f.view.aboutToAppear();
    assert.equal(f.view.loaded_, false); assert.match(f.view.loadError_, /读取失败/); f.view.changeDraft_('bad'); await f.view.save_();
    assert.equal(f.calls.writes.length, 0); f.reader(() => '-Dretry=1'); f.view.load_(); assert.equal(f.view.draft_, '-Dretry=1');
  });
  await group('缺少load和返回非文本均不伪造空确认值', () => {
    const f = fixture({ defaultLoad: true }); assert.equal(f.view.loaded_, false); assert.match(f.view.loadError_, /读取回调/);
    const invalid = fixture({ appear: false }); invalid.reader(() => undefined); invalid.view.aboutToAppear();
    assert.equal(invalid.view.loaded_, false); assert.match(invalid.view.loadError_, /有效/);
  });
  await group('保存trim且等待真实Promise，阻断同帧重复、输入和全部退出入口', async () => {
    const f = fixture(), gate = deferred(); f.saver(() => gate.promise); f.view.changeDraft_('  -Dpath="a b"  ');
    const task = f.view.save_(); await f.view.save_(); f.view.changeDraft_('overwrite'); await f.view.requestDismiss_(true); f.handler()();
    assert.deepEqual(f.calls.writes, [['A', '-Dpath="a b"']]); assert.equal(f.view.draft_, '  -Dpath="a b"  ');
    assert.equal(f.calls.saved.length, 0); assert.equal(f.calls.back + f.calls.close + f.calls.dialogs.length, 0);
    assert.equal(f.calls.blocked.at(-1), true); gate.resolve(); await task;
    assert.deepEqual(f.calls.saved, [['A', '-Dpath="a b"']]); assert.equal(f.calls.back, 1); assert.equal(f.view.confirmed_, '-Dpath="a b"');
    assert.equal(f.calls.blocked.at(-1), false); assert.equal(f.calls.registered.at(-1), undefined);
  });
  await group('保存失败保留草稿和旧确认，修改清错且明确重试可保存空文本', async () => {
    const f = fixture(); f.saver(async () => { throw Error('disk'); }); f.view.changeDraft_('-Dnew=1'); await f.view.save_();
    assert.equal(f.view.draft_, '-Dnew=1'); assert.equal(f.view.confirmed_, '-Dold=1'); assert.match(f.view.saveError_, /草稿已保留/);
    assert.equal(f.calls.saved.length + f.calls.back, 0); assert.equal(f.view.saving_, false);
    f.view.changeDraft_('  '); assert.equal(f.view.saveError_, ''); f.saver(async () => {}); await f.view.save_(); assert.deepEqual(f.calls.saved, [['A', '']]);
  });
  await group('默认saveValue明确reject且不通知保存成功', async () => {
    const f = fixture({ defaultSave: true }); f.view.changeDraft_('new'); await f.view.save_();
    assert.match(f.view.saveError_, /保存回调/); assert.equal(f.calls.saved.length + f.calls.back, 0); assert.equal(f.view.isDirty_(), true);
  });
  await group('干净取消走Back，注册默认关闭走Close，不访问存储或弹确认', async () => {
    const back = fixture(); await back.view.requestDismiss_(true); assert.equal(back.calls.back, 1);
    const close = fixture(); close.handler()(); await settle(); assert.equal(close.calls.close, 1);
    assert.equal(back.calls.writes.length + close.calls.writes.length + back.calls.dialogs.length + close.calls.dialogs.length, 0);
  });
  await group('dirty继续编辑保留原始草稿，放弃才恢复确认值并返回', async () => {
    const f = fixture(); f.view.changeDraft_('  dirty '); f.dialog(async () => ({ index: 0 })); await f.view.requestDismiss_(true);
    assert.equal(f.view.draft_, '  dirty '); assert.equal(f.calls.back, 0); assert.equal(f.view.isDirty_(), true);
    f.dialog(async () => ({ index: 1 })); await f.view.requestDismiss_(true);
    assert.equal(f.view.draft_, '-Dold=1'); assert.equal(f.calls.back, 1); assert.equal(f.calls.writes.length, 0);
    assert.equal(f.calls.dialogs[0].buttons[1].text, '放弃修改');
  });
  await group('dirty关闭与返回共用确认，确认在途不重复弹出或派发保存', async () => {
    const f = fixture(), gate = deferred(); f.dialog(() => gate.promise); f.view.changeDraft_('dirty'); f.handler()();
    await f.view.requestDismiss_(true); await f.view.save_(); f.view.changeDraft_('ignored');
    assert.equal(f.calls.dialogs.length, 1); assert.equal(f.calls.writes.length, 0); assert.equal(f.view.draft_, 'dirty');
    gate.resolve({ index: 1 }); await settle(); assert.equal(f.calls.close, 1); assert.equal(f.calls.back, 0);
  });
  await group('原生退出确认取消或拒绝都保留草稿', async () => {
    const f = fixture(); f.view.changeDraft_('dirty'); f.dialog(async () => { throw Error('dismissed'); }); await f.view.requestDismiss_(false);
    assert.equal(f.view.draft_, 'dirty'); assert.equal(f.view.confirming_, false); assert.equal(f.calls.back + f.calls.close, 0);
  });
  await group('visible=false只撤销资格与注册，不补写；旧handler和迟到输入失效', () => {
    const f = fixture(), handler = f.handler(); f.view.changeDraft_('dirty'); f.view.visible = false; f.view.onSessionChanged_();
    handler(true); f.view.changeDraft_('late'); assert.equal(f.view.draft_, 'dirty'); assert.equal(f.calls.writes.length + f.calls.back, 0);
    assert.equal(f.calls.registered.at(-1), undefined); const unregisters = f.calls.registered.filter(x => x === undefined).length;
    f.view.aboutToDisappear(); assert.equal(f.calls.registered.filter(x => x === undefined).length, unregisters);
  });
  await group('旧保存成功不覆盖新version/owner，物理完成后必须显式重读', async () => {
    const f = fixture(), gate = deferred(); f.saver(() => gate.promise); f.view.changeDraft_('request-A'); const task = f.view.save_();
    f.switchOwner('B', 'owner-B'); assert.equal(f.view.loaded_, false); assert.match(f.view.loadError_, /上一笔/);
    gate.resolve(); await task; assert.equal(f.calls.saved.length + f.calls.back, 0); assert.equal(f.view.draft_, '');
    f.reader(version => '-D' + version); f.view.load_(); assert.equal(f.view.draft_, '-DB'); assert.equal(f.calls.blocked.at(-1), false);
  });
  await group('相同version的新owner同样隔离旧保存失败', async () => {
    const f = fixture(), gate = deferred(); f.saver(() => gate.promise); f.view.changeDraft_('old'); const task = f.view.save_();
    f.switchOwner('A', 'new-owner'); gate.reject(Error('old rejection')); await task;
    assert.equal(f.view.saveError_, ''); assert.equal(f.calls.saved.length + f.calls.back + f.calls.close, 0);
  });
  await group('退出确认迟到不能关闭新owner，也不能清其草稿', async () => {
    const f = fixture(), gate = deferred(); f.dialog(() => gate.promise); f.view.changeDraft_('A'); const task = f.view.requestDismiss_(true);
    f.reader(() => 'B-confirmed'); f.switchOwner('B', 'owner-B'); f.view.changeDraft_('B-draft'); gate.resolve({ index: 1 }); await task;
    assert.equal(f.view.draft_, 'B-draft'); assert.equal(f.calls.back + f.calls.close, 0);
  });
  await group('卸载后保存成功/失败均不发布UI结果或导航', async () => {
    for (const reject of [false, true]) {
      const f = fixture(), gate = deferred(); f.saver(() => gate.promise); f.view.changeDraft_('pending'); const task = f.view.save_();
      f.view.aboutToDisappear(); if (reject) gate.reject(Error('late')); else gate.resolve(); await task;
      assert.equal(f.calls.saved.length + f.calls.back + f.calls.close, 0); assert.equal(f.view.saveError_, ''); assert.equal(f.view.pendingSave_, 0);
    }
  });
  await group('同步load回调重入切owner，旧读取返回不能压过新确认态', () => {
    const f = fixture({ appear: false }); f.reader(version => { if (version === 'A') { f.switchOwner('B', 'owner-B'); return 'old-A'; } return 'new-B'; });
    f.view.aboutToAppear(); assert.equal(f.view.draft_, 'new-B'); assert.equal(f.view.confirmed_, 'new-B');
  });
  await group('onSaved同步改变owner时不随后导航关闭新正文', async () => {
    const f = fixture(); f.view.onSaved = (version, value) => { f.calls.saved.push([version, value]); f.reader(() => 'B'); f.switchOwner('B', 'owner-B'); };
    f.view.changeDraft_('A-new'); await f.view.save_(); assert.deepEqual(f.calls.saved, [['A', 'A-new']]); assert.equal(f.calls.back, 0); assert.equal(f.view.draft_, 'B');
  });
} catch (error) { failure = error; }
const after = hash(fs.readFileSync(file));
if (after !== before && !failure) failure = new Error('组件在执行期间变化，拒绝发布中间源码PASS');
const receipt = { state: failure ? 'FAIL' : 'PASS', startedAt, finishedAt: new Date().toISOString(),
  groups, groupCount: groups.length, source: FILE, sourceSha256: before, finalSourceSha256: after,
  sourceStable: before === after, output, sdkCompilation: false, deviceEvidence: false,
  failure: failure ? String(failure.stack ?? failure) : undefined };
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
if (failure) { console.error(failure); process.exitCode = 1; }
else console.log('PASS version JVM editor ' + groups.length + ' actual lifecycle groups; receipt ' + path.join(output, 'receipt.json'));

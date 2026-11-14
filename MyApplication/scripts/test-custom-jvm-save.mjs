/**
 * 全局 JVM 参数及设置父层交付的定向宿主回归。
 *
 * 直接转译并执行生产 PreferenceManager、Index 成员和真实事件闭包，只替换平台
 * Preferences、Context、目录准备及弹窗边缘。缓存与磁盘分别模拟，flush 可控暂停、
 * 部分落盘或拒绝，验证确认值屏障、串行、单键回滚及原 owner 的重试语义。
 * 不运行 ArkUI Builder、不使用真实用户偏好，不替代 SDK 编译或设备界面验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const P = 'feature_system/src/main/ets/PreferenceManager.ets';
const I = 'entry/src/main/ets/pages/Index.ets';
const sources = [P, I, 'scripts/test-custom-jvm-save.mjs', 'scripts/lib/load-pure-ets.mjs',
  'scripts/lib/ets-compiler.mjs', 'scripts/lib/workspace-paths.mjs'];
const sourceHashes = () => Object.fromEntries(sources.map(name => [name, createHash('sha256')
  .update(fs.readFileSync(path.join(PROJECT_ROOT, name))).digest('hex')]));
const outputIndex = process.argv.indexOf('--output');
const output = assertExternalOutputPath(outputIndex < 0
  ? resolveWorkspacePath('run', 'custom-jvm-save') : process.argv[outputIndex + 1]);
fs.mkdirSync(output, { recursive: true });
const startedAt = new Date().toISOString(), initialHashes = sourceHashes(), groups = [];
const passed = name => { groups.push(name); console.log('PASS ' + name); };
const settle = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };

/** 创建手动控制的异步平台边缘；每个句柄只对应本 fixture 的一次 get 或 flush。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

/** 转译真实源并检查语法；内存负控不能以语法错误代替行为断言被命中。 */
function compile(source, fileName) {
  const result = compiler.transpileModule(source, { fileName, reportDiagnostics: true,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0, fileName);
  return result.outputText;
}

/** 每次装载产生独立进程静态状态；同 preferencesDir 的多个 manager 仍共用同一平台 store。 */
function fixture(overrides = {}) {
  for (const [name, source] of Object.entries(overrides)) compile(source, name);
  const stores = new Map(); let game = false;
  const context = owner => ({ filesDir: '/sandbox/' + owner, preferencesDir: '/preferences/' + owner });
  const main = context('main');
  function storage(ctx = main) {
    if (stores.has(ctx.preferencesDir)) return stores.get(ctx.preferencesDir);
    const cache = new Map([['customJvmArgs', '-Dold=1'], ['themeMode', 2]]), disk = new Map(cache);
    const flushes = [], reads = [], calls = []; let rejectPut = false, rejectRollback = false;
    const store = {
      getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
      get: async (key, fallback) => { const step = reads.shift(); if (step) await step.promise;
        return cache.has(key) ? cache.get(key) : fallback; },
      put: async (key, value) => { calls.push(['put', key, value]); cache.set(key, value);
        if (rejectPut) { rejectPut = false; throw new Error('put rejected'); } },
      putSync: (key, value) => { calls.push(['rollback', key, value]);
        if (rejectRollback) { rejectRollback = false; throw new Error('rollback put rejected'); }
        cache.set(key, value); },
      flush: async () => { calls.push(['flush']); const values = new Map(cache), step = flushes.shift();
        try { if (step) await step.promise; }
        catch (error) { if (step.partial) for (const [key, value] of values) disk.set(key, value); throw error; }
        for (const [key, value] of values) disk.set(key, value); },
    };
    const state = { store, cache, disk, calls, flushes, reads,
      rejectNextPut: () => { rejectPut = true; }, rejectNextRollback: () => { rejectRollback = true; } };
    stores.set(ctx.preferencesDir, state); return state;
  }
  const commons = { ProcessPreferences: { open: ctx => storage(ctx).store, isGameProcess: () => game }, formatError: String };
  const load = makePureEtsLoader({ commons, '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } }, overrides);
  const PreferenceManager = load(P).PreferenceManager;
  return { manager: (ctx = main) => new PreferenceManager(ctx), storage, context, main, setGame: value => { game = value; } };
}

/** 只抽 Index 原有成员/属性回调并执行，跳过 ArkUI build，避免另写一份测试用业务实现。 */
const indexSource = fs.readFileSync(path.join(PROJECT_ROOT, I), 'utf8');
const indexAst = compiler.createSourceFile(I, indexSource, compiler.ScriptTarget.Latest, true);
function indexMembers(names, globals = {}) {
  const owner = indexAst.statements.find(n => n.members?.some(m => m.name?.getText(indexAst) === 'handleStorageLocationChange'));
  assert.ok(owner, 'Index actual class');
  const members = names.map(name => {
    const member = owner.members.find(m => m.name?.getText(indexAst) === name);
    assert.ok(member, 'Index actual member ' + name); return member.getText(indexAst);
  });
  const exports = {};
  new Function('exports', ...Object.keys(globals), compile('export class Harness {\n' + members.join('\n') + '\n}', I))
    (exports, ...Object.values(globals));
  return exports.Harness;
}
function indexCallback(name) {
  let callback;
  const visit = node => {
    if (node.kind === compiler.SyntaxKind.PropertyAssignment && node.name?.getText(indexAst) === name
      && node.initializer.kind === compiler.SyntaxKind.ArrowFunction) callback = node.initializer;
    compiler.forEachChild(node, visit);
  };
  visit(indexAst); assert.ok(callback, 'Index actual callback ' + name);
  const exports = {};
  // 事件箭头捕获所属组件的 this；先在真实 page 作为 this 的工厂中建立闭包，
  // 不能对一个已经在模块顶层创建的箭头调用 .call 来伪造它的词法 this。
  new Function('exports', compile('export function bindCallback() { return (' + callback.getText(indexAst) + '); }', I))(exports);
  return function (...args) { return exports.bindCallback.call(this)(...args); };
}

{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate); let finished = false;
  const saving = f.manager().saveCustomJvmArgs('  -Dnew=2  ').then(() => { finished = true; }); await settle();
  assert.equal(s.cache.get('customJvmArgs'), '-Dnew=2'); assert.equal(s.disk.get('customJvmArgs'), '-Dold=1');
  assert.equal(finished, false); assert.equal(f.manager({ ...f.main }).customJvmArgs, '-Dold=1');
  gate.resolve(); await saving;
  assert.equal(f.manager().customJvmArgs, '-Dnew=2'); assert.equal(s.disk.get('customJvmArgs'), '-Dnew=2');
  assert.equal(s.disk.get('themeMode'), 2);
  passed('成功必须等待 flush；新 manager 仍读旧确认值；首尾空白归一且其他键不变');
}
{
  const f = fixture(), s = f.storage(); s.rejectNextPut();
  await assert.rejects(f.manager().saveCustomJvmArgs('-Dnew=2'), /put rejected/);
  assert.equal(f.manager().customJvmArgs, '-Dold=1'); assert.equal(s.disk.get('customJvmArgs'), '-Dold=1');
  assert.deepEqual(s.calls.filter(call => call[0] === 'rollback'), [['rollback', 'customJvmArgs', '-Dold=1']]);
  assert.equal(s.disk.get('themeMode'), 2); await f.manager().saveCustomJvmArgs('');
  assert.equal(f.manager().customJvmArgs, ''); assert.equal(s.disk.get('customJvmArgs'), '');
  passed('put 失败只回滚本键并向调用者拒绝；显式重试可清空参数');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const saving = f.manager().saveCustomJvmArgs('-Dnew=2'), failed = assert.rejects(saving, /flush rejected/);
  await settle(); gate.reject(new Error('flush rejected')); await failed;
  assert.equal(f.manager().customJvmArgs, '-Dold=1'); assert.equal(s.disk.get('customJvmArgs'), '-Dold=1');
  await f.manager().saveCustomJvmArgs('-Dnew=2'); assert.equal(s.disk.get('customJvmArgs'), '-Dnew=2');
  passed('flush 失败等待单键回滚，旧缓存/磁盘恢复后允许下一次保存');
}
for (const rollbackKind of ['flush', 'put']) {
  const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); first.partial = true;
  s.flushes.push(first); if (rollbackKind === 'flush') s.flushes.push(rollback); else s.rejectNextRollback();
  const saving = f.manager().saveCustomJvmArgs('-Dnew=2'), failed = assert.rejects(saving, /磁盘回滚尚未确认/);
  await settle(); first.reject(new Error('partial disk failure')); await settle();
  if (rollbackKind === 'flush') rollback.reject(new Error('rollback flush failure'));
  await failed;
  assert.equal(s.disk.get('customJvmArgs'), '-Dnew=2', '真实模拟部分写盘，不能把 getter 的旧值当磁盘结论');
  assert.equal(f.manager().customJvmArgs, '-Dold=1');
  const before = s.calls.filter(call => call[0] === 'put').length;
  await f.manager().saveCustomJvmArgs('-Dold=1');
  assert.equal(s.calls.filter(call => call[0] === 'put').length, before + 1, '回滚未知时同值重试不得跳过 IO');
  assert.equal(s.disk.get('customJvmArgs'), '-Dold=1');
  passed('回滚 ' + rollbackKind + ' 失败保持旧确认屏障和磁盘未知，同值重试真正恢复持久值');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const first = f.manager().saveCustomJvmArgs('-Dfirst=1'), same = f.manager().saveCustomJvmArgs('-Dfirst=1');
  const second = f.manager().saveCustomJvmArgs('-Dsecond=2'); await settle();
  assert.deepEqual(s.calls.filter(call => call[0] === 'put'), [['put', 'customJvmArgs', '-Dfirst=1']]);
  gate.resolve(); await Promise.all([first, same, second]);
  assert.deepEqual(s.calls.filter(call => call[0] === 'put'),
    [['put', 'customJvmArgs', '-Dfirst=1'], ['put', 'customJvmArgs', '-Dsecond=2']]);
  assert.equal(s.disk.get('customJvmArgs'), '-Dsecond=2');
  passed('同目录跨 manager 请求串行，已确认的相同值幂等，后续不同草稿最后提交');
}
{
  const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); s.flushes.push(first, rollback);
  const a = f.manager().saveCustomJvmArgs('-Dfirst=1'), failed = assert.rejects(a, /first rejected/);
  const b = f.manager().saveCustomJvmArgs('-Dsecond=2'); await settle(); first.reject(new Error('first rejected')); await settle();
  assert.equal(s.calls.filter(call => call[0] === 'put').length, 1, '后继保存必须等待原 owner 的回滚');
  rollback.resolve(); await failed; await b; assert.equal(s.disk.get('customJvmArgs'), '-Dsecond=2');
  passed('前笔失败及其回滚完成前不执行后继保存，失败不堵死队列');
}
{
  const f = fixture(), other = f.context('other'), a = f.storage(), b = f.storage(other), ga = deferred(), gb = deferred();
  a.flushes.push(ga); b.flushes.push(gb);
  const ra = f.manager().saveCustomJvmArgs('-Dmain=1'), rb = f.manager(other).saveCustomJvmArgs('-Dother=2'); await settle();
  assert.equal(a.calls.filter(call => call[0] === 'put').length, 1); assert.equal(b.calls.filter(call => call[0] === 'put').length, 1);
  ga.resolve(); await ra; assert.equal(f.manager(other).customJvmArgs, '-Dold=1');
  gb.resolve(); await rb; assert.equal(b.disk.get('customJvmArgs'), '-Dother=2');
  passed('不同 preferencesDir 的 owner 独立运行，一方续体不清除另一方屏障');
}
{
  const f = fixture(), manager = f.manager(), s = f.storage(); f.setGame(true);
  await assert.rejects(manager.saveCustomJvmArgs('-Dbad=1'), /启动器/);
  assert.equal(s.calls.length, 0); f.setGame(false);
  await assert.rejects(f.manager({}).saveCustomJvmArgs('-Dbad=1'), /启动器/);
  await assert.rejects(manager.saveCustomJvmArgs(7), /启动器/);
  const read = deferred(); s.reads.push(read);
  const pending = manager.saveCustomJvmArgs('-Dbad=1'), failed = assert.rejects(pending, /身份已改变/);
  await settle(); f.setGame(true); read.resolve(); await failed; assert.equal(s.calls.length, 0);
  passed('游戏角色、缺失 owner、非法输入均在写入前拒绝；异步读取后的角色变化再次检查');
}
{
  const callback = indexCallback('onCustomJvmArgsChange'), f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const page = { customJvmArgs: '-Dold=1', getPrefManager_: () => f.manager() };
  const saving = callback.call(page, '-DfromUi=1'); await settle(); assert.equal(page.customJvmArgs, '-Dold=1');
  gate.resolve(); await saving; assert.equal(page.customJvmArgs, '-DfromUi=1');
  s.rejectNextPut(); await assert.rejects(callback.call(page, '-Dfailed=1'), /put rejected/);
  assert.equal(page.customJvmArgs, '-DfromUi=1');
  passed('实际 Index 事件回调等待专用 API 后才发布确认值，失败原样交还编辑器');
}
{
  const calls = [], StorageLocation = { SANDBOX: 'sandbox', EXTERNAL: 'external' };
  const GameStorage = { hasVersions: () => true };
  const Harness = indexMembers(['promptSwitchStorage'], { StorageLocation, GameStorage });
  const page = new Harness(); Object.assign(page, { theme: { primary: '#0067D9', error: '#BE3F30' },
    mcRoot: () => '/mc', applyStorageSwitch: (...args) => calls.push(args),
    getUIContext: () => ({ getPromptAction: () => ({ showDialog: async () => { calls.push(['dialog']); return { index: 1 }; } }) }) });
  page.promptSwitchStorage('external', false); page.promptSwitchStorage('external', true);
  assert.deepEqual(calls, [['external', false], ['external', true]], '明确 false 不能重复询问');
  page.promptSwitchStorage('external'); await settle(); assert.deepEqual(calls.slice(-2), [['dialog'], ['external', true]]);
  GameStorage.hasVersions = () => false; page.promptSwitchStorage('external', true);
  assert.deepEqual(calls.at(-1), ['external', false], '无版本时保留原有直接切换语义');
  const forwarded = []; indexCallback('onStorageLocationChange').call({ handleStorageLocationChange: (...args) => forwarded.push(args) }, 'external', false);
  assert.deepEqual(forwarded, [['external', false]]);
  passed('实际存储确认与事件闭包保留可选迁移意图，旧调用仍询问，无版本仍直接切换');
}
{
  const calls = [], StorageLocation = { SANDBOX: 'sandbox', EXTERNAL: 'external' }, permission = deferred(), phone = deferred();
  let tablet = true;
  const GameStorage = { isTabletSilent: () => tablet, isExternalAvailable: () => true,
    requestDownloadPermission: () => permission.promise, migrateLegacyExternalFolder: () => calls.push(['prepare-tablet']),
    writeExternalHint: () => calls.push(['hint']), ensurePhoneExternalDir: () => phone.promise };
  const Harness = indexMembers(['handleStorageLocationChange'], { StorageLocation, GameStorage, parseStorageLocation: value => value,
    AppLogger: { warn() {} }, LOG_DOMAIN_LAUNCH: 1 });
  const page = new Harness(); Object.assign(page, { storageLocation: 'sandbox', context: {}, getPrefManager_: () => ({}),
    toast_: message => calls.push(['toast', message]), promptSwitchStorage: (...args) => calls.push(['prompt', ...args]) });
  page.handleStorageLocationChange('external', false); assert.deepEqual(calls, []);
  permission.resolve(true); await settle(); assert.deepEqual(calls.at(-1), ['prompt', 'external', false]);
  tablet = false; calls.length = 0; page.handleStorageLocationChange('external', true); assert.deepEqual(calls, []);
  phone.resolve('/download'); await settle(); assert.deepEqual(calls.at(-1), ['prompt', 'external', true]);
  passed('平板权限与手机目录准备完成以后才转交原迁移意图，不绕过原外部准备步骤');
}

/** 两个内存负控仍执行生产方法：缺失 flush 等待或确认值屏障都必须被实际行为识别。 */
{
  const original = fs.readFileSync(path.join(PROJECT_ROOT, P), 'utf8').replaceAll('\r\n', '\n');
  const anchor = "await this.pref.put('customJvmArgs', normalized);\n        await this.pref.flush();";
  assert.ok(original.includes(anchor));
  const f = fixture({ [P]: original.replace(anchor, anchor.replace('await this.pref.flush()', 'void this.pref.flush()')) });
  const s = f.storage(), gate = deferred(); s.flushes.push(gate); let finished = false;
  const saving = f.manager().saveCustomJvmArgs('-Dnew=2').then(() => { finished = true; }); await settle();
  assert.throws(() => assert.equal(finished, false), assert.AssertionError); gate.resolve(); await saving;
  passed('编译成功的负控移除 flush 等待，会触发真实完成时序断言');
}
{
  const original = fs.readFileSync(path.join(PROJECT_ROOT, P), 'utf8');
  const anchor = "? state.original : this.pref.getSync('customJvmArgs', '');";
  assert.ok(original.includes(anchor));
  const f = fixture({ [P]: original.replace(anchor, "? this.pref.getSync('customJvmArgs', '') : this.pref.getSync('customJvmArgs', '');") });
  const s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const saving = f.manager().saveCustomJvmArgs('-Dnew=2'); await settle();
  assert.throws(() => assert.equal(f.manager().customJvmArgs, '-Dold=1'), assert.AssertionError);
  gate.resolve(); await saving; passed('编译成功的负控移除 getter 屏障，会触发新 manager 的真实读取断言');
}

assert.deepEqual(sourceHashes(), initialHashes, '回归期间生产源码与提取器身份发生变化');
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ startedAt, finishedAt: new Date().toISOString(),
  status: 'PASS', groups, sourceHashes: initialHashes,
  scope: 'actual production ETS methods and Index callbacks; controlled Preferences/Context/storage-preparation boundaries',
  notAttested: ['real preferences/disk failures', 'ArkUI rendering', 'SDK/HAP/APP build', 'device storage permissions and migration'] }, null, 2) + '\n');
console.log('PASS custom JVM settings ' + groups.length + ' groups; receipt ' + path.join(output, 'receipt.json'));

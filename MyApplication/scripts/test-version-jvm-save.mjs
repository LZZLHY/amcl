#!/usr/bin/env node
/**
 * 单版本JVM显式保存的宿主回归：执行真实PreferenceManager与Index事件闭包，只替换
 * Preferences平台边缘。缓存、磁盘、putSync和flush分别可控，验证共享JSON记录的
 * 确认屏障、串行、字段级回滚、未知恢复与旧void写入口兼容，不镜像生产保存算法。
 * 不执行ArkUI布局、不访问用户偏好，也不替代SDK编译与设备验证；所有运行输出外置。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const P = 'feature_system/src/main/ets/PreferenceManager.ets', I = 'entry/src/main/ets/pages/Index.ets';
const outputAt = process.argv.indexOf('--output');
const output = assertExternalOutputPath(outputAt < 0 ? resolveWorkspacePath('run', 'version-jvm-save') : process.argv[outputAt + 1]);
fs.mkdirSync(output, { recursive: true });
const inputs = [P, I, 'scripts/test-version-jvm-save.mjs', 'scripts/lib/ets-compiler.mjs', 'scripts/lib/load-pure-ets.mjs'];
const hashes = () => Object.fromEntries(inputs.map(file => [file, createHash('sha256')
  .update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex')]));
const startedAt = new Date().toISOString(), sourceHashes = hashes(), groups = [];
const passed = text => { groups.push(text); console.log('PASS ' + text); };
const settle = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };
const initial = () => ({ xmx: 2048, jdkVersion: '17', customJvmArgs: '-Dold=1', gameLanguage: 'en_us', renderScalePercent: 75 });
const key = version => 'verLaunch.' + version;
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject }; }

/** 每个fixture模拟独立进程，同目录多个manager共用生产静态owner与平台store。 */
function fixture(sourceOverrides = {}) {
  const pure = makePureEtsLoader();
  const policy = pure('commons/src/main/ets/common/GameResolutionPolicy.ets');
  const languages = pure('commons/src/main/ets/common/GameLanguages.ets');
  const stores = new Map(); let game = false;
  const context = owner => ({ preferencesDir: '/version-jvm/' + owner });
  const main = context('main');
  const storage = (ctx = main) => {
    if (stores.has(ctx.preferencesDir)) return stores.get(ctx.preferencesDir);
    const cache = new Map([[key('a'), JSON.stringify(initial())], [key('b'), JSON.stringify(initial())],
      ['customJvmArgs', '-Dglobal=1'], ['unrelated', 'keep']]);
    const disk = new Map(cache), calls = [], flushes = [];
    let writeFailures = 0, readFailures = 0, failBeforeCache = false;
    const store = {
      getSync(name, fallback) { if (readFailures > 0) { readFailures--; throw new Error('read rejected'); }
        return cache.has(name) ? cache.get(name) : fallback; },
      putSync(name, value) { calls.push(['putSync', name, value]);
        if (failBeforeCache && writeFailures > 0) { writeFailures--; throw new Error('put rejected before cache'); }
        cache.set(name, value);
        if (writeFailures > 0) { writeFailures--; throw new Error('put rejected'); } },
      deleteSync(name) { calls.push(['deleteSync', name]);
        if (failBeforeCache && writeFailures > 0) { writeFailures--; throw new Error('delete rejected before cache'); }
        cache.delete(name);
        if (writeFailures > 0) { writeFailures--; throw new Error('delete rejected'); } },
      async flush() { calls.push(['flush']); const snapshot = new Map(cache), step = flushes.shift();
        try { if (step) await step.promise; }
        catch (error) { if (step.partial) { disk.clear(); for (const pair of snapshot) disk.set(...pair); } throw error; }
        disk.clear(); for (const pair of snapshot) disk.set(...pair); },
    };
    const state = { cache, disk, store, calls, flushes,
      failWrites: (count, beforeCache = false) => { writeFailures = count; failBeforeCache = beforeCache; },
      failReads: count => { readFailures = count; } };
    stores.set(ctx.preferencesDir, state); return state;
  };
  const load = makePureEtsLoader({ commons: { ...policy, ...languages, formatError: String,
    ProcessPreferences: { open: ctx => storage(ctx).store, isGameProcess: () => game } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } } }, sourceOverrides);
  const { PreferenceManager } = load(P);
  return { manager: (ctx = main) => new PreferenceManager(ctx), storage, main, context, setGame: value => { game = value; } };
}
const raw = (store, version = 'a', disk = false) => JSON.parse((disk ? store.disk : store.cache).get(key(version)) || '{}');

/** 抽取生产Index闭包，不执行Builder，也不另写测试保存回调。 */
function indexCallback(name) {
  const source = fs.readFileSync(path.join(PROJECT_ROOT, I), 'utf8');
  const ast = compiler.createSourceFile(I, source, compiler.ScriptTarget.Latest, true); let callback;
  const visit = node => {
    if (node.kind === compiler.SyntaxKind.PropertyAssignment && node.name?.getText(ast) === name
      && node.initializer.kind === compiler.SyntaxKind.ArrowFunction) callback = node.initializer;
    compiler.forEachChild(node, visit);
  }; visit(ast); assert(callback, 'actual Index callback');
  const result = compiler.transpileModule('export function bindCallback() { return (' + callback.getText(ast) + '); }',
    { fileName: I, reportDiagnostics: true, compilerOptions: { module: compiler.ModuleKind.CommonJS } });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
  const exports = {}; new Function('exports', result.outputText)(exports);
  return function (...args) { return exports.bindCallback.call(this)(...args); };
}

{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate); let finished = false;
  const save = f.manager().saveVersionJvmArgs('a', '  -Dnew=2  ').then(() => { finished = true; }); await settle();
  assert.equal(raw(s).customJvmArgs, '-Dnew=2'); assert.equal(raw(s, 'a', true).customJvmArgs, '-Dold=1');
  assert.equal(f.manager({ ...f.main }).getVersionOverride('a').customJvmArgs, '-Dold=1'); assert.equal(finished, false);
  gate.resolve(); await save;
  assert.deepEqual(raw(s, 'a', true), { ...initial(), customJvmArgs: '-Dnew=2' });
  assert.equal(f.manager().getVersionOverride('a').customJvmArgs, '-Dnew=2');
  assert.equal(s.disk.get('customJvmArgs'), '-Dglobal=1'); assert.equal(s.disk.get('unrelated'), 'keep');
  passed('成功等待实际flush，同目录新manager仍读取旧确认值，只修改固定实例JVM字段');
}
for (const failure of ['put', 'flush']) {
  const f = fixture(), s = f.storage();
  if (failure === 'put') s.failWrites(1);
  else { const bad = deferred(); bad.reject(new Error('flush rejected')); s.flushes.push(bad); }
  await assert.rejects(f.manager().saveVersionJvmArgs('a', '-Dbad=1'), /rejected/);
  assert.deepEqual(raw(s, 'a', true), initial()); assert.deepEqual(f.manager().getVersionOverride('a'), initial());
  await f.manager().saveVersionJvmArgs('a', ''); assert.equal(raw(s, 'a', true).customJvmArgs, '');
  passed(failure + '失败拒绝并等待字段回滚，原队列仍可重试并恢复仅用全局参数');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const save = f.manager().saveVersionJvmArgs('a', '-Dpending=1'), rejected = assert.rejects(save, /flush rejected/);
  await settle();
  const first = f.manager().getVersionOverride('a'); first.jdkVersion = '21'; f.manager().setVersionOverride('a', first);
  const second = f.manager().getVersionOverride('a'); second.gameLanguage = 'zh_cn'; second.xmx = 4096;
  second.customJvmArgs = '-DstaleVoidMustNotWin=1'; f.manager().setVersionOverride('a', second);
  assert.deepEqual(raw(s), { ...initial(), customJvmArgs: '-Dpending=1', jdkVersion: '21', gameLanguage: 'zh_cn', xmx: 4096 });
  gate.reject(new Error('flush rejected')); await rejected;
  assert.deepEqual(raw(s, 'a', true), { ...initial(), jdkVersion: '21', gameLanguage: 'zh_cn', xmx: 4096 });
  passed('多个旧void字段更新不覆盖在途JVM，也不互带旧快照；失败只还原JVM并保留同期字段');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const save = f.manager().saveVersionJvmArgs('a', '-Dpending=1'); await settle();
  const changed = f.manager().getVersionOverride('a'); changed.jdkVersion = '21'; f.manager().setVersionOverride('a', changed);
  assert.equal(f.manager().getVersionOverride('a').jdkVersion, '21');
  const restored = f.manager().getVersionOverride('a'); restored.jdkVersion = '17'; f.manager().setVersionOverride('a', restored);
  assert.equal(raw(s).jdkVersion, '17'); assert.equal(f.manager().getVersionOverride('a').customJvmArgs, '-Dold=1');
  gate.resolve(); await save; assert.equal(raw(s, 'a', true).jdkVersion, '17');
  passed('旧void字段同步可读，JVM保存期间明确选回原值不会被误判为未改动');
}
for (const failure of ['put', 'flush']) {
  const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); first.partial = true;
  s.flushes.push(first); if (failure === 'flush') s.flushes.push(rollback);
  const save = f.manager().saveVersionJvmArgs('a', '-Dpartial=1'), rejected = assert.rejects(save, /磁盘回滚尚未确认/);
  await settle(); if (failure === 'put') s.failWrites(1, true);
  first.reject(new Error('partial write rejected')); await settle(); if (failure === 'flush') rollback.reject(new Error('rollback rejected'));
  await rejected;
  assert.equal(raw(s, 'a', true).customJvmArgs, '-Dpartial=1');
  assert.equal(f.manager({ ...f.main }).getVersionOverride('a').customJvmArgs, '-Dold=1');
  const count = s.calls.filter(c => c[0] === 'putSync').length;
  await f.manager().saveVersionJvmArgs('a', '-Dold=1');
  assert(s.calls.filter(c => c[0] === 'putSync').length > count); assert.equal(raw(s, 'a', true).customJvmArgs, '-Dold=1');
  passed('回滚' + failure + '失败保留确认屏障与磁盘未知，同值重试仍实际写盘');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const a = f.manager().saveVersionJvmArgs('a', '-Dfirst=1'), b = f.manager({ ...f.main }).saveVersionJvmArgs('a', '-Dsecond=2');
  await settle(); assert.equal(s.calls.filter(c => c[0] === 'putSync').length, 1); gate.resolve(); await Promise.all([a, b]);
  assert.equal(raw(s, 'a', true).customJvmArgs, '-Dsecond=2');
  passed('同目录跨manager请求串行，后继保存读取前笔已确认记录');
}
for (const firstKind of ['resolution', 'jvm']) {
  const f = fixture(), s = f.storage(), first = deferred(), second = deferred(); s.flushes.push(first, second);
  const a = firstKind === 'resolution' ? f.manager().saveResolutionScalePercent(50, 'a') : f.manager().saveVersionJvmArgs('a', '-Dnew=1');
  const b = firstKind === 'resolution' ? f.manager().saveVersionJvmArgs('a', '-Dnew=1') : f.manager().saveResolutionScalePercent(50, 'a');
  await settle(); assert.equal(s.calls.filter(c => c[0] === 'putSync').length, 1); first.resolve(); await a; await settle();
  assert.equal(s.calls.filter(c => c[0] === 'putSync').length, 2); second.resolve(); await b;
  assert.deepEqual(raw(s, 'a', true), { ...initial(), customJvmArgs: '-Dnew=1', renderScalePercent: 50 });
  passed(firstKind + '先行与另一字段共用队列和确认屏障，后笔合并而非覆盖整记录');
}
{
  const f = fixture(), s = f.storage(), first = deferred(), rollback = deferred(); first.partial = true; s.flushes.push(first, rollback);
  const save = f.manager().saveVersionJvmArgs('a', '-Dunknown=1'), rejected = assert.rejects(save, /回滚尚未确认/);
  await settle(); first.reject(new Error('first')); await settle(); rollback.reject(new Error('rollback')); await rejected;
  const changed = f.manager().getVersionOverride('a'); changed.jdkVersion = '25'; f.manager().setVersionOverride('a', changed);
  await f.manager().saveResolutionScalePercent(100, 'a');
  assert.deepEqual(raw(s, 'a', true), { ...initial(), jdkVersion: '25', renderScalePercent: 100 });
  const after = f.manager().getVersionOverride('a'); after.customJvmArgs = '-Dlegacy=1'; f.manager().setVersionOverride('a', after);
  assert.equal(raw(s).customJvmArgs, '-Dlegacy=1', '后续成功共享记录确认应解除旧JVM保护');
  passed('JVM回滚未知后分辨率提交保留同期JDK与旧JVM确认值，成功后解除保护');
}
{
  const f = fixture(), s = f.storage(), first = deferred(); first.partial = true; s.flushes.push(first);
  const save = f.manager().saveResolutionScalePercent(50, 'a'), rejected = assert.rejects(save, /恢复尚未确认/);
  await settle(); s.failWrites(1, true); first.reject(new Error('resolution failed')); await rejected;
  assert.equal(raw(s).renderScalePercent, 50, '回滚put在改缓存前失败，留下未确认新比例');
  assert.equal(f.manager().getVersionOverride('a').renderScalePercent, 75);
  await f.manager().saveVersionJvmArgs('a', '-Dafter=1');
  assert.deepEqual(raw(s, 'a', true), { ...initial(), customJvmArgs: '-Dafter=1' });
  passed('分辨率回滚未知后JVM保存仅采用旧比例确认值，不顺带提交未确认分辨率缓存');
}
{
  const f = fixture(), other = f.context('other'), a = f.storage(), b = f.storage(other), ga = deferred(), gb = deferred();
  a.flushes.push(ga); b.flushes.push(gb);
  const sa = f.manager().saveVersionJvmArgs('a', '-Dmain=1'), sb = f.manager(other).saveVersionJvmArgs('b', '-Dother=2');
  await settle(); assert.equal(raw(a).customJvmArgs, '-Dmain=1'); assert.equal(raw(b, 'b').customJvmArgs, '-Dother=2');
  ga.resolve(); await sa; assert.equal(f.manager(other).getVersionOverride('b').customJvmArgs, '-Dold=1'); gb.resolve(); await sb;
  assert.deepEqual(raw(a, 'b', true), initial()); assert.deepEqual(raw(b, 'a', true), initial());
  passed('不同目录owner独立，固定版本与其他实例保持隔离');
}
{
  const f = fixture(), s = f.storage(), manager = f.manager();
  for (const [version, value] of [['', 'x'], ['  ', 'x'], ['a', 1]]) await assert.rejects(manager.saveVersionJvmArgs(version, value), /启动器/);
  f.setGame(true); await assert.rejects(manager.saveVersionJvmArgs('a', 'x'), /启动器/); f.setGame(false);
  await assert.rejects(f.manager({}).saveVersionJvmArgs('a', 'x'), /启动器/);
  const queued = manager.saveVersionJvmArgs('a', 'x'), rejected = assert.rejects(queued, /进程已改变/);
  f.setGame(true); await rejected; f.setGame(false); assert.equal(s.calls.length, 0);
  s.cache.set(key('a'), '{broken'); await assert.rejects(manager.saveVersionJvmArgs('a', 'x'));
  s.cache.set(key('a'), JSON.stringify(initial())); s.failReads(1); await assert.rejects(manager.saveVersionJvmArgs('a', 'x'), /read rejected/);
  assert.equal(s.calls.length, 0);
  passed('空版本、非法输入、缺owner、游戏进程与排队后角色变化拒绝；坏记录和读取失败不猜默认覆盖');
}
{
  const f = fixture(), s = f.storage(); s.cache.delete(key('new')); s.disk.delete(key('new'));
  await f.manager().saveVersionJvmArgs('new', '-Dnew=1'); await f.manager().saveVersionJvmArgs('new', '');
  assert.equal(s.cache.has(key('new')), false); assert.equal(s.disk.has(key('new')), false);
  passed('原来不存在的实例清空唯一覆盖后删除空记录，保留继承模型');
}
{
  const f = fixture(), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const callback = indexCallback('onSaveVersionJvmArgs'), page = { getPrefManager_: () => f.manager() };
  let done = false; const save = callback.call(page, 'a', '-Dindex=1').then(() => { done = true; }); await settle();
  assert.equal(done, false); gate.resolve(); await save; assert.equal(raw(s, 'a', true).customJvmArgs, '-Dindex=1');
  s.failWrites(1); await assert.rejects(callback.call(page, 'a', '-Dbad=1'), /put rejected/);
  assert.equal(raw(s, 'a', true).customJvmArgs, '-Dindex=1');
  passed('生产Index回调返回专用Promise，等待耐久结果且不吞失败');
}

/** 负控只修改内存中的生产源码；必须编译成功且由真实完成/读取时序断言识别。 */
{
  const source = fs.readFileSync(path.join(PROJECT_ROOT, P), 'utf8').replaceAll('\r\n', '\n');
  const anchor = 'this.writeVersionOverrideSync_(key, next);\n        await this.pref.flush();'; assert(source.includes(anchor));
  const f = fixture({ [P]: source.replace(anchor, anchor.replace('await this.pref.flush()', 'void this.pref.flush()')) });
  const s = f.storage(), gate = deferred(); s.flushes.push(gate); let done = false;
  const save = f.manager().saveVersionJvmArgs('a', '-Dearly=1').then(() => { done = true; }); await settle();
  assert.throws(() => assert.equal(done, false), assert.AssertionError); gate.resolve(); await save;
  passed('负控移除实际flush等待，会命中完成时序断言');
}
{
  const source = fs.readFileSync(path.join(PROJECT_ROOT, P), 'utf8');
  const anchor = 'if (this.resolutionWrites?.originals.has(key)) return this.resolutionWrites.originals.get(key) as LaunchPreferenceValue;';
  assert(source.includes(anchor)); const f = fixture({ [P]: source.replace(anchor, '') }), s = f.storage(), gate = deferred(); s.flushes.push(gate);
  const save = f.manager().saveVersionJvmArgs('a', '-Dvisible=1'); await settle();
  assert.throws(() => assert.equal(f.manager().getVersionOverride('a').customJvmArgs, '-Dold=1'), assert.AssertionError);
  gate.resolve(); await save; passed('负控移除共享getter屏障，会命中新manager读取确认值断言');
}

assert.deepEqual(hashes(), sourceHashes, '测试期间生产源码或夹具身份发生变化');
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ status: 'PASS', startedAt, finishedAt: new Date().toISOString(),
  groups, sourceHashes, scope: 'actual production PreferenceManager and Index callback; controlled platform cache/disk/flush',
  notAttested: ['real disk failures', 'ArkUI layout/close guard', 'SDK build', 'device behavior'] }, null, 2) + '\n');
console.log('PASS version JVM save ' + groups.length + ' groups; receipt ' + path.join(output, 'receipt.json'));

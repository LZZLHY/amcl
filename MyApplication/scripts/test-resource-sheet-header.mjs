/**
 * 资源详情 Sheet 顶部顺序的源码绑定回归。
 *
 * 执行真实 build、正文 Builder、标题计算和层级切换方法；声明接收器只隔离 ArkUI
 * 绘制与标题组件边界。验证实际声明顺序及布局输入，不把宿主记录当成像素或真机证据。
 * 负控从生产 AST 取回指示条并放回正文，必须由同一顺序断言检出，不能靠语法错误通过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent, actionUiReceiver } from './lib/unified-actions-fixture.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

const outputAt = process.argv.indexOf('--output');
assert.ok(outputAt >= 0 && process.argv[outputAt + 1], '请用 --output 指定仓库外证据目录');
const startedAt = new Date().toISOString();
// 每次独占收据目录，后续组合候选的重跑不能覆盖这轮成功或失败的原始结果。
const output = path.join(assertExternalOutputPath(process.argv[outputAt + 1]),
  'run-' + startedAt.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + process.pid);
fs.mkdirSync(output, { recursive: true });
const file = 'entry/src/main/ets/components/ModDetailSheet.ets';
const typesFile = 'mods/src/main/ets/ModTypes.ets';
const sources = [file, typesFile, 'scripts/lib/unified-actions-fixture.mjs'];
const hash = value => createHash('sha256').update(value).digest('hex');
const hashes = () => Object.fromEntries(sources.map(name => [name, hash(fs.readFileSync(path.join(PROJECT_ROOT, name)))]));
const initialHashes = hashes(), groups = [];
const pass = name => { groups.push(name); console.log('PASS ' + name); };
const types = makePureEtsLoader({ commons: {} })(typesFile);
const kinds = [types.ResourceKind.MOD, types.ResourceKind.RESOURCE_PACK, types.ResourceKind.SHADER, types.ResourceKind.MODPACK];
const methods = ['ANIM_DURATION_MS', 'build', 'ImmersiveTitleContent1_', 'modDetailTitle_', 'requestModBack_',
  'selectedGroupVersions', 'versionSupportsMc', 'gotoPicker', 'gotoFiles', 'backToPicker', 'backToMain'];

/**
 * 资源详情、选择器和文件正文在本测试中是既有业务端口，仅记录原 Builder 的调用次数。
 * 头部结构和三槽平移仍执行真实生产声明，不在夹具中重写布局或导航决策。
 */
function fixture(kind, mutate) {
  const ui = actionUiReceiver();
  const callbacks = { closed: 0, animated: [] };
  const Sheet = loadActionComponent(file, 'ModDetailSheet', { methods, render: true, mutate,
    globals: { ...ui.globals, Curve: { FastOutSlowIn: 'original-fast-out-slow-in' } },
    dependencies: { mods: types, './ImmersiveTitleScaffold': { ImmersiveTitleScaffold: options => {
      ui.records.push({ type: 'ImmersiveTitleScaffold', args: [options], modifiers: {} });
    } } },
  });
  const view = new Sheet();
  const project = { id: 'fixture-resource', title: 'Entity Culling', kind };
  const versions = [{ id: 'new', gameVersions: ['1.21.11'] }, { id: 'old', gameVersions: ['1.20.4'] }];
  const dependencies = [{ id: 'existing-dependency', selected: true }], selectedVersion = versions[0];
  Object.assign(view, { project, allVersions: versions, dependencies, selectedVersion,
    currentStep: 'main', selectedMcGroup: '', slidePct: 0, viewportW: 375,
    theme: { divider: '#75808A', bgPrimary: '#F7F8FA' },
    onClose: () => { callbacks.closed++; },
    getUIContext: () => ({ animateTo(options, change) { callbacks.animated.push(options); change(); } }),
  });
  for (const name of ['MainStep', 'PickerStep', 'GroupFilesStep']) view[name] = () => {
    ui.records.push({ type: 'business-' + name, args: [], modifiers: {} });
  };
  return { ui, view, callbacks, project, versions, dependencies, selectedVersion };
}

/**
 * 调用真实 build 后才由标题端口执行真实 content 闭包。分开这两个时刻可以直接证明
 * 指示条属于标题外层，正文即使再次进入也不会重复创建它；不能只检查源码字符串顺序。
 */
function renderAndCheck(f) {
  const { ui, view } = f;
  ui.clear(); view.build();
  const headerIndex = ui.records.findIndex(record => record.type === 'ImmersiveTitleScaffold');
  assert.ok(headerIndex >= 0, '必须建立原有标题宿主');
  assert.equal(ui.records.filter(record => record.type === 'ImmersiveTitleScaffold').length, 1);
  const indicators = ui.records.filter(record => record.modifiers.id?.[0] === 'mod-detail-drag-indicator');
  assert.equal(indicators.length, 1, '标题外层必须有且仅有一个指示条');
  const indicator = indicators[0];
  assert.ok(ui.records.indexOf(indicator) < headerIndex, '指示条必须在标题宿主之前声明');
  assert.deepEqual(indicator.modifiers.width, [36]); assert.deepEqual(indicator.modifiers.height, [4]);
  assert.deepEqual(indicator.modifiers.accessibilityLevel, ['no']);
  assert.equal(Object.keys(indicator.modifiers).some(name => /gesture|onClick|onTouch/.test(name)), false);
  // 原生包装器位于条与标题之间，真实布局链必须分配剩余高度，不能使用额外的100%占高。
  const wrapperIndex = ui.records.findLastIndex((record, index) => index < headerIndex && record.type === 'Column');
  assert.ok(wrapperIndex > ui.records.indexOf(indicator), '标题必须包在指示条之后的原生Column里');
  const remaining = ui.records.slice(headerIndex + 1).find(record => record.modifiers.layoutWeight?.[0] === 1);
  assert.ok(remaining, '原生标题包装器必须使用layoutWeight分配剩余高度');
  assert.equal(remaining.modifiers.height, undefined, '包装器不能再声明100%高度');
  const options = ui.records[headerIndex].args[0];
  assert.equal(options.titleId, 'mod-detail-title');
  assert.equal(options.backId, 'mod-detail-back'); assert.equal(options.closeId, 'mod-detail-close');
  assert.equal(options.showClose, true); assert.equal(options.showBack, view.currentStep !== 'main');
  const bodyStart = ui.records.length;
  options.content();
  const body = ui.records.slice(bodyStart);
  assert.equal(body.filter(record => record.type === 'Stack').length, 1, '正文保留同一个三槽Stack');
  assert.equal(body.filter(record => record.modifiers.id?.[0] === 'mod-detail-drag-indicator').length, 0,
    '正文不能重复创建指示条');
  for (const name of ['MainStep', 'PickerStep', 'GroupFilesStep']) {
    assert.equal(body.filter(record => record.type === 'business-' + name).length, 1, name + '原Builder仅调用一次');
  }
  const offsets = body.filter(record => record.modifiers.translate).map(record => record.modifiers.translate[0].x);
  assert.deepEqual(offsets, [-view.slidePct * view.viewportW, (1 - view.slidePct) * view.viewportW,
    (2 - view.slidePct) * view.viewportW], '三槽继续使用原position和真实视口宽度');
  assert.equal(view.project, f.project); assert.equal(view.allVersions, f.versions);
  assert.equal(view.dependencies, f.dependencies); assert.equal(view.selectedVersion, f.selectedVersion);
  return options;
}

/** 用真实生产AST定位声明块；负控只回退条的位置或剩余高度，不改业务方法与测试断言。 */
function rollbackSource(source, rollbackWeight = false) {
  const ast = compiler.createSourceFile(file, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members && node.name?.getText(ast) === 'ModDetailSheet');
  const build = owner.members.find(node => node.name?.getText(ast) === 'build');
  const outer = build.body.statements.find(node => node.kind === compiler.SyntaxKind.Block);
  if (rollbackWeight) {
    const weight = outer.statements.find(node => node.getText(ast).startsWith('width(')
      && node.getText(ast).includes('.layoutWeight(1)'));
    assert.ok(weight, '负控必须命中真实原生包装器');
    const changed = weight.getText(ast).replace('.layoutWeight(1)', ".height('100%')");
    return source.slice(0, weight.getStart(ast)) + changed + source.slice(weight.end);
  }
  const rowAt = outer.statements.findIndex(node => node.getText(ast) === 'Row()');
  assert.ok(rowAt >= 0 && outer.statements[rowAt + 1].kind === compiler.SyntaxKind.Block);
  const begin = outer.statements[rowAt].getStart(ast), end = outer.statements[rowAt + 2].end;
  const originalIndicator = source.slice(begin, end);
  const body = owner.members.find(node => node.name?.getText(ast) === 'ImmersiveTitleContent1_').body;
  // 插入点在删除点之后：先插入再删除，两个AST坐标均来自本次同一源码，避免偏移推算。
  const withOldBodyIndicator = source.slice(0, body.getStart(ast) + 1) + '\n' + originalIndicator + '\n'
    + source.slice(body.getStart(ast) + 1);
  return withOldBodyIndicator.slice(0, begin) + withOldBodyIndicator.slice(end);
}

let failure;
try {
  for (const kind of kinds) {
    const f = fixture(kind);
    for (const step of ['main', 'picker', 'files']) {
      Object.assign(f.view, { currentStep: step, slidePct: ['main', 'picker', 'files'].indexOf(step), selectedMcGroup: '1.21.11' });
      const options = renderAndCheck(f);
      assert.equal(options.contextLabel, step === 'main' ? '' : 'Entity Culling');
      assert.equal(options.title, step === 'main' ? 'Entity Culling' : step === 'picker' ? '选择版本 · 2' : 'MC 1.21.11 · 1');
    }
  }
  pass('四类资源三层真实Builder：唯一顶部指示条、标题之前、剩余高度及原槽位身份');

  for (const kind of kinds) {
    const f = fixture(kind), { view, callbacks } = f;
    view.gotoPicker(); assert.equal(view.currentStep, 'picker'); assert.equal(view.slidePct, 1);
    view.gotoFiles('1.21.11'); assert.equal(view.currentStep, 'files'); assert.equal(view.slidePct, 2);
    let options = renderAndCheck(f); options.onBack();
    assert.equal(view.currentStep, 'picker'); assert.equal(view.slidePct, 1); assert.equal(callbacks.closed, 0);
    options = renderAndCheck(f); options.onBack();
    assert.equal(view.currentStep, 'main'); assert.equal(view.slidePct, 0); assert.equal(callbacks.closed, 0);
    for (const step of ['main', 'picker', 'files']) {
      view.currentStep = step; options = renderAndCheck(f); options.onClose();
    }
    assert.equal(callbacks.closed, 3, '每层关闭继续透传原onClose');
    assert.ok(callbacks.animated.every(options => options.duration === 280 && options.curve === 'original-fast-out-slow-in'));
    assert.equal(view.project, f.project); assert.equal(view.selectedVersion, f.selectedVersion);
  }
  pass('四类资源的真实版本进入/返回动画与关闭回调保持原行为');

  for (const rollbackWeight of [false, true]) {
    const f = fixture(types.ResourceKind.MOD, source => rollbackSource(source, rollbackWeight));
    assert.throws(() => renderAndCheck(f), rollbackWeight
      ? /包装器必须使用layoutWeight/ : /标题外层必须有且仅有一个指示条/,
    '回退生产位置或高度分配必须被同一行为断言识别，不能靠转译错误充当失败');
  }
  pass('负控：把条放回标题正文或移除剩余高度分配均由实际声明断言检出');
} catch (error) { failure = error; }

const finalHashes = hashes(), sourceStable = JSON.stringify(initialHashes) === JSON.stringify(finalHashes);
if (!sourceStable && !failure) failure = new Error('测试期间生产源码变化，本轮结果不能绑定新候选');
const receipt = { schemaVersion: 1, kind: 'source-bound-resource-sheet-header-tests', startedAt,
  finishedAt: new Date().toISOString(), sourceRoot: PROJECT_ROOT, state: failure ? 'FAIL' : 'PASS', groups,
  resourceKinds: kinds, stepCount: 3, sourceStable, sourceHashes: initialHashes, finalSourceHashes: finalHashes,
  harnessSha256: hash(fs.readFileSync(new URL(import.meta.url))), failure: failure ? String(failure.stack ?? failure) : undefined,
  limitations: ['Actual production declaration order and callbacks executed; no ArkUI pixel/layout engine or device gesture execution'] };
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
if (failure) { console.error(failure.stack ?? failure); process.exitCode = 1; }
console.log(JSON.stringify({ state: receipt.state, groups: groups.length, sourceStable, receipt: path.join(output, 'receipt.json') }));

/**
 * 统一圆形动作的真实生产行为回归。
 * 保存原生 options/普通 Button 的真实回调后再改禁用、隐藏、菜单及生命周期状态，验证迟到事件。
 * 声明接收器执行真实 build/Builder 分支并记录正文/附件调用；不模拟系统导航或宣称真机视觉通过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';
import { loadActionComponent, actionUiReceiver, builderSourceLex } from './lib/unified-actions-fixture.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

const outputIndex = process.argv.indexOf('--output');
if (outputIndex < 0) throw new Error('请用 --output 指定仓库外证据目录');
const output = assertExternalOutputPath(process.argv[outputIndex + 1]);
fs.mkdirSync(output, { recursive: true });
const startedAt = new Date().toISOString(), groups = [];
const pass = name => { groups.push(name); console.log('PASS ' + name); };
const files = ['commons/src/main/ets/common/IconCatalog.ets', 'commons/src/main/ets/common/ImmersiveLight.ets',
  'commons/src/main/ets/common/DockLight.ets', 'entry/src/main/ets/components/AppTitleAction.ets',
  'entry/src/main/ets/components/AppRoundIconButton.ets', 'entry/src/main/ets/components/ImmersiveTitleScaffold.ets',
  'entry/src/main/ets/components/ImmersiveLightRuntime.ets', 'entry/src/main/ets/components/VersionManagerSheet.ets',
  'entry/src/main/ets/components/GameExportSheet.ets', 'entry/src/main/ets/pages/tabs/HomeTab.ets'];
const hashes = () => Object.fromEntries(files.map(file => [file,
  createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex')]));
const initial = hashes();
globalThis.$r = value => value;
const pure = makePureEtsLoader();
const common = { ...pure(files[0]), ...pure(files[1]), ...pure(files[2]) };
const actionData = makePureEtsLoader({ commons: common })('entry/src/main/ets/components/AppTitleAction.ets');
const { DockLightMode: M, AppIconName: I, ImmersiveLightPreferences: Preferences,
  encodeImmersiveLightPreferences: encode } = common;
const theme = { textPrimary: '#102030', textSecondary: '#607080', bgCard: '#fafafa',
  bgPrimary: '#f1f2f3', textOnPrimary: '#fff', error: '#c30' };
const colors = { Transparent: 'transparent' };

/** 每个能力场景获得独立生产 runtime，设备能力缓存与配置解码不会跨 fixture 污染。 */
function fixture(available = true, immersive = true, mutate) {
  const ui = actionUiReceiver();
  const metrics = [];
  const runtime = makePureEtsLoader({ commons: common, feature_system: {}, './DockLightMaterial': {
    readDockLightCapabilities: () => ({ floatingSupported: available, immersiveSupported: immersive, queryFailed: false }),
    dockLightStatus: () => '',
  } })('entry/src/main/ets/components/ImmersiveLightRuntime.ets');
  const design = { HdsNavigation: ui.globals.HdsNavigation,
    HdsNavigationTitleMode: { MINI: 'mini', MODAL: 'modal' },
    IconStyleMode: { SMALL: 100, LARGE: 101 }, TextStyleMode: { NORMAL: 200 },
    get hdsMaterial() { assert.ok(available, '旧系统访问了新材质枚举'); return {
      MaterialType: { NONE: 0, ADAPTIVE: 100 },
      MaterialLevel: { ADAPTIVE: 10, EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 },
    }; },
  };
  const dependencies = { commons: common, './AppTitleAction': actionData,
    './AppRoundIconButton': { AppRoundIconButton: ui.globals.AppRoundIconButton },
    './AppIcon': { AppIcon: ui.globals.AppIcon }, './ImmersiveLightRuntime': runtime,
    // LengthMetrics只作为真实SDK边界记录原vp请求，不把该对象当系统布局坐标或真机排版证据。
    '@kit.ArkUI': { LengthMetrics: { vp(value) { metrics.push(value); return { value, unit: 'vp' }; } } },
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: version => {
      assert.equal(version, '6.1.0'); return available;
    } } }, '@kit.UIDesignKit': design };
  const globals = { ...ui.globals, Color: colors, $r: globalThis.$r };
  const Header = loadActionComponent('entry/src/main/ets/components/ImmersiveTitleScaffold.ets',
    'ImmersiveTitleScaffold', { dependencies, globals, render: true, mutate });
  const Round = loadActionComponent('entry/src/main/ets/components/AppRoundIconButton.ets',
    'AppRoundIconButton', { dependencies, globals, render: true });
  const view = new Header(); view.theme = theme; view.surfaceColor = theme.bgPrimary;
  view.getUIContext = () => ({ getHostContext: () => undefined }); view.aboutToAppear();
  return { ui, view, Header, Round, runtime, dependencies, globals, metrics };
}

// 普通按钮保持44vp命中下限、原视觉圆和业务回调；禁用和退休后投递的旧事件不能执行。
{
  const f = fixture(), round = new f.Round(); let calls = 0;
  round.theme = theme; round.visualDiameter = 28; round.name = I.Close; round.controlId = 'round-close';
  round.accessibilityLabel = '关闭任务详情'; round.badge = '3'; round.onAction = () => calls++;
  round.aboutToAppear(); round.build();
  assert.equal(round.hitDiameter_(), 44);
  round.visualDiameter = 52; assert.equal(round.hitDiameter_(), 52); round.visualDiameter = 28;
  const clickNode = f.ui.records.find(record => record.modifiers.onClick);
  assert.ok(clickNode, '真实 Button 必须接入生产点击回调');
  const click = clickNode.modifiers.onClick[0];
  assert.deepEqual(clickNode.modifiers.enabled, [true]);
  assert.deepEqual(clickNode.modifiers.accessibilityText, ['关闭任务详情']);
  assert.deepEqual(clickNode.modifiers.id, ['round-close']);
  assert.ok(f.ui.records.some(record => record.type === 'Text' && record.args[0] === '3'));
  assert.ok(f.ui.records.some(record => record.modifiers.hitTestBehavior?.[0] === 'HitTestMode.None'), '角标不能吃掉点击');
  click(); assert.equal(calls, 1);
  round.actionEnabled = false; click(); assert.equal(calls, 1, '禁用前排队的点击必须重新校验');
  round.actionEnabled = true; round.onAction = () => { calls += 10; }; click(); assert.equal(calls, 11, '回调采用当前实例');
  round.aboutToDisappear(); click(); assert.equal(calls, 11, '已退休普通按钮必须拒绝旧事件');
  round.aboutToAppear(); click(); assert.equal(calls, 21);
  round.badge = ''; f.ui.clear(); round.build();
  assert.equal(f.ui.records.some(record => record.type === 'Text' && record.args[0] === '3'), false);
  const resourceLabel = { id: 10001, type: 10003, params: ['app.string.chat_input_close'], bundleName: '', moduleName: '' };
  round.accessibilityLabel = resourceLabel; f.ui.clear(); round.build();
  assert.equal(f.ui.records.find(record => record.modifiers.onClick).modifiers.accessibilityText[0], resourceLabel,
    '真实modifier必须保留Resource原身份交给系统，不能把本地化资源强转成字符串');
  round.accessibilityLabel = ''; f.ui.clear(); round.build();
  assert.equal(f.ui.records.find(record => record.modifiers.onClick).modifiers.accessibilityText[0], '关闭');
}
pass('真实普通Button/无障碍modifier：string及Resource原值、命中下限、角标、禁用和退休事件');

// 同一标题可以同时返回和关闭；原生事件必须按投递时的可见性/禁用状态重新判定。
{
  const { view } = fixture(); let back = 0, close = 0, external = 0;
  view.showClose = true; view.showExternal = true;
  view.onBack = () => back++; view.onClose = () => close++; view.onExternal = () => external++;
  const options = view.nativeTitleOptions_();
  const backClick = options.content.backIcon.action;
  const closeClick = options.content.menu.value.find(item => item.content.componentId === view.closeId).content.action;
  const externalClick = options.content.menu.value.find(item => item.content.componentId === 'app-title-external').content.action;
  assert.equal(view.hasBack_(), true); assert.equal(view.hasClose_(), true);
  backClick(); closeClick(); externalClick(); assert.deepEqual([back, close, external], [1, 1, 1]);
  view.backEnabled = view.closeEnabled = view.externalEnabled = false;
  backClick(); closeClick(); externalClick(); assert.deepEqual([back, close, external], [1, 1, 1]);
  view.backEnabled = view.closeEnabled = view.externalEnabled = true;
  view.showBack = view.showClose = view.showExternal = false;
  backClick(); closeClick(); externalClick(); assert.deepEqual([back, close, external], [1, 1, 1]);
  view.modal = true; assert.equal(view.hasBack_(), false); assert.equal(view.hasClose_(), true);
  backClick(); closeClick(); assert.deepEqual([back, close], [1, 2]);
  view.modal = false; view.showBack = view.showClose = view.showExternal = true;
  view.aboutToDisappear(); backClick(); closeClick(); externalClick();
  assert.deepEqual([back, close, external], [1, 2, 1], '原生标题退休后不能执行队列中的旧回调');
}
pass('双动作标题、modal关闭及原生返回/关闭/外跳的禁用与隐藏迟到事件');

/** 执行生产原生项回调，随后删除/禁用/原位改id；不能沿用旧对象或数组下标执行别的业务。 */
function exerciseMenu(f) {
  const { view } = f, calls = [];
  const original = { id: 'rename', label: '重命名', icon: I.Edit, badge: '7' };
  view.menuActions = [original, { id: 'refresh', label: '刷新', icon: I.Refresh }, { id: 'export', label: '导出' }];
  view.onMenuAction = id => calls.push('old:' + id);
  const items = view.menuItems_(), rename = items.find(item => item.content.componentId === 'rename');
  assert.deepEqual(rename.badge, { value: '7', accessibilityText: '重命名，7' });
  assert.equal(items.find(item => item.content.componentId === 'export').content.type, 200);
  rename.content.action(); assert.deepEqual(calls, ['old:rename']);
  view.menuActions = [{ id: 'refresh', label: '刷新' }, { id: 'rename', label: '新标题', enabled: false }];
  rename.content.action(); assert.deepEqual(calls, ['old:rename'], '旧options不能越过新disabled');
  view.menuActions[1].enabled = true; view.onMenuAction = id => calls.push('new:' + id);
  rename.content.action(); assert.deepEqual(calls, ['old:rename', 'new:rename']);
  view.menuActions = [{ id: 'refresh', label: '刷新' }]; rename.content.action();
  assert.deepEqual(calls, ['old:rename', 'new:rename'], '删除项不能派发');
  original.id = 'refresh'; rename.content.action();
  assert.deepEqual(calls, ['old:rename', 'new:rename'], '旧描述对象改id不能把旧点击转给新项');
  const current = view.menuItems_().find(item => item.content.componentId === 'refresh').content.action;
  view.aboutToDisappear(); current(); assert.deepEqual(calls, ['old:rename', 'new:rename'], '退休标题的有效id也必须拒绝');
}
exerciseMenu(fixture());
pass('原生项按稳定id重查当前规格和回调、删除/禁用/重排/原位改id及文字项角标');

// 旧系统真实普通Builder产出的圆形与文字回调，也必须遵循同一稳定id规则。
{
  const { view, ui } = fixture(false), calls = [];
  const original = { id: 'rename', label: '重命名', icon: I.Edit };
  const textAction = { id: 'save', label: '保存' };
  view.menuActions = [original, textAction]; view.content = () => {};
  view.onMenuAction = id => calls.push(id); view.build();
  const iconClick = ui.records.find(record => record.type === 'AppRoundIconButton' && record.args[0].controlId === 'rename').args[0].onAction;
  const textClick = ui.records.find(record => record.type === 'Button' && record.args[0] === '保存').modifiers.onClick[0];
  iconClick(); textClick(); assert.deepEqual(calls, ['rename', 'save']);
  view.menuActions = [{ id: 'save', label: '保存', enabled: false }, { id: 'rename', label: '新标题', enabled: false }];
  iconClick(); textClick(); assert.deepEqual(calls, ['rename', 'save']);
  view.menuActions = [{ id: 'other', label: '其它' }]; original.id = textAction.id = 'other';
  iconClick(); textClick(); assert.deepEqual(calls, ['rename', 'save'], '普通分支也不能沿用可变旧描述的id');
}
pass('真实旧系统Builder的圆形与文字回调按稳定id拒绝迟到改派');

// 新旧系统及总开关/模块关闭使用同一正文BuilderParam，真实分支每次只调用一次并保留编辑对象。
for (const available of [false, true]) {
  const f = fixture(available, false), { view, ui } = f;
  const preferences = new Preferences(); preferences.titleButtons = true; preferences.navigationMode = M.EXQUISITE;
  const draft = { value: '尚未提交的编辑' }; let bodyCalls = 0, accessoryCalls = 0;
  view.content = () => { bodyCalls++; assert.equal(draft.value, '尚未提交的编辑'); };
  view.headerAccessory = () => accessoryCalls++; view.accessoryHeight = 48; view.subtitle = '辅助说明';
  view.title = '版本管理'; view.titleId = 'version-title'; view.backId = 'version-back'; view.showClose = true;
  view.menuActions = [{ id: 'messages', label: '消息', icon: I.Notification, badge: '2' },
    { id: 'save', label: '保存', enabled: false }];
  for (const state of ['on', 'off', 'module-off', 'on-again']) {
    preferences.enabled = state !== 'off'; preferences.titleButtons = state !== 'module-off';
    view.rawConfig = encode(preferences); ui.clear(); const beforeBody = bodyCalls, beforeAccessory = accessoryCalls;
    view.build(); assert.equal(bodyCalls, beforeBody + 1, state + '正文必须保留且恰调用一次');
    if (available) {
      assert.equal(ui.records.some(record => record.type === 'HdsNavigation'), true);
      const options = ui.records.find(record => record.modifiers.titleBar).modifiers.titleBar[0];
      assert.equal(options.content.bottomBuilder.height, 72); options.content.bottomBuilder.builder();
      assert.equal(options.style.systemMaterialEffect.materialType, state === 'off' || state === 'module-off' ? 0 : 100);
      assert.equal(options.style.systemMaterialEffect.materialLevel, state === 'off' || state === 'module-off' ? 10 : 2);
    } else {
      assert.equal(ui.records.some(record => record.type === 'HdsNavigation'), false);
      const button = ui.records.find(record => record.type === 'AppRoundIconButton' && record.args[0].controlId === 'messages');
      assert.equal(button.args[0].badge, '2'); assert.equal(button.args[0].accessibilityLabel, '消息');
      assert.ok(ui.records.some(record => record.type === 'Button' && record.args[0] === '保存' && record.modifiers.enabled[0] === false));
    }
    assert.equal(accessoryCalls, beforeAccessory + 1);
  }
  assert.equal(draft.value, '尚未提交的编辑');
}
pass('真实build/Builder声明分支：旧系统、新系统降级、总关闭/模块关闭与重开均保留正文和固定附件');

// 执行HomeTab真实PageHeader，而非用subIcon外框/假资源替代原30vp Image。
// 原生stackBuilder由测试显式模拟平台调用；这里证明原闭包与声明输入，不证明实际同行/遮挡。
for (const available of [false, true]) {
  const f = fixture(available), { view, ui } = f;
  const Home = loadActionComponent(files[9], 'HomeTab', { methods: ['PageHeader'], render: true,
    dependencies: {}, globals: f.globals });
  const home = new Home(); home.theme = theme; let brandCalls = 0, bodyCalls = 0;
  view.title = 'AMCL'; view.showBack = false; view.brandWidth = 36;
  view.headerBrand = () => { brandCalls++; home.PageHeader(); };
  view.content = () => bodyCalls++; view.build(); assert.equal(view.accessoryHeight_(), 0);
  assert.equal(bodyCalls, 1);
  if (available) {
    const options = ui.records.find(record => record.modifiers.titleBar).modifiers.titleBar[0];
    assert.equal(options.content.subIcon, undefined, '原生subIcon不能冒充启动测量图片');
    assert.deepEqual(options.padding.start, { value: 64, unit: 'vp' }); assert.deepEqual(f.metrics, [64]);
    assert.equal(options.content.bottomBuilder, undefined, '品牌不能增加一整行附件');
    assert.equal(brandCalls, 0, '装饰槽由平台builder回调实际进入');
    assert.equal(typeof options.content.stackBuilder, 'function'); options.content.stackBuilder();
    assert.ok(ui.records.some(record => record.modifiers.height?.[0] === 56 &&
      record.modifiers.hitTestBehavior?.[0] === 'HitTestMode.None'), '装饰行声明必须不处理输入');
  } else {
    assert.deepEqual(f.metrics, [], '普通旧系统分支不构造原生标题padding');
  }
  assert.equal(brandCalls, 1);
  const images = ui.records.filter(record => record.type === 'Image'); assert.equal(images.length, 1);
  assert.equal(images[0].args[0], 'app.media.amcl_axe');
  assert.deepEqual(images[0].modifiers.width, [30]); assert.deepEqual(images[0].modifiers.height, [30]);
  assert.deepEqual(images[0].modifiers.syncLoad, [true]);
  assert.ok(ui.records.some(record => record.type === 'Column' && record.modifiers.width?.[0] === 36 &&
    record.modifiers.height?.[0] === 36), '原36vp底板必须保留');
  view.showBack = true; ui.clear(); view.build();
  assert.equal(brandCalls, 1, '显示返回时不再运行装饰品牌闭包');
}
pass('真实Home PageHeader的30vp Image经headerBrand/stackBuilder进入新旧分支，装饰行不处理输入且不造附件高度');

// 复杂业务层只抽取生产导航命令，其他文件/任务入口不在本组执行；不重写草稿或文件业务。
{
  const Manager = loadActionComponent(files[7], 'VersionManagerSheet', { methods: [
    'managerNavigationBlocked_', 'requestManagerBack_', 'requestManagerClose_'], dependencies: {} });
  const manager = new Manager(), calls = [];
  Object.assign(manager, { pageMotion_: { moving: false }, currentStep: 'export',
    onClose: () => calls.push('close'), backToList: () => calls.push('list'), backToDetail: () => calls.push('detail') });
  manager.requestManagerBack_(); manager.requestManagerClose_(); assert.deepEqual(calls, [], '导出处理器未就绪不能旁路离开');
  manager.exportDismissHandler_ = back => calls.push(back ? 'export-back' : 'export-close');
  manager.requestManagerBack_(); manager.requestManagerClose_(); assert.deepEqual(calls, ['export-back', 'export-close']);
  manager.pageMotion_.moving = true; manager.requestManagerBack_(); manager.requestManagerClose_(); assert.equal(calls.length, 2);
  manager.pageMotion_.moving = false; manager.currentStep = 'files'; manager.filesNavigationBlocked_ = true;
  manager.requestManagerBack_(); manager.requestManagerClose_(); assert.equal(calls.length, 2, '子层确认/事务不能被移出的标题绕过');
  manager.filesNavigationBlocked_ = false; manager.requestManagerBack_(); manager.requestManagerClose_();
  assert.deepEqual(calls.slice(2), ['detail', 'close']);
  manager.currentStep = 'detail'; manager.requestManagerBack_(); assert.equal(calls.at(-1), 'list');
  const Export = loadActionComponent(files[8], 'GameExportSheet', { methods: [
    'activeTask_', 'requestBack_', 'requestClose_', 'requestLeave_'], dependencies: {} });
  const panel = new Export(), exits = [];
  Object.assign(panel, { busy_: false, savingLeave_: false, draftSaving_: false, pageMotion_: { moving: false },
    showLeaveConfirm_: false, taskState_: 'idle', dirty_: true, source_: {}, layer_: 'main', step_: 0,
    onBack: () => exits.push('back'), onClose: () => exits.push('close') });
  panel.requestClose_(); assert.equal(panel.showLeaveConfirm_, true); assert.deepEqual(exits, []);
  panel.requestBack_(); assert.equal(panel.showLeaveConfirm_, false); assert.deepEqual(exits, []);
  panel.taskState_ = 'running'; panel.requestClose_(); assert.deepEqual(exits, ['close'], '活动导出只收起，不执行取消');
  panel.busy_ = true; panel.requestBack_(); panel.requestClose_(); assert.deepEqual(exits, ['close']);
}
pass('版本管理实际返回/关闭保留导出dismiss和子层导航屏障；真实导出草稿确认与活动任务收起');

// 负控只撤掉生产菜单方法的disabled护栏；必须由行为断言失败，解析或装载错误不能算检出。
const mutated = fixture(true, true, source => source.replace(
  /action !== undefined && action\.enabled !== false/, 'action !== undefined'));
assert.throws(() => exerciseMenu(mutated), error => error instanceof assert.AssertionError && /disabled/.test(error.message));
const missingBody = fixture(true, true, source => source.replace('Column() { this.content() }', 'Column() {}'));
let missingBodyCalls = 0; missingBody.view.content = () => missingBodyCalls++;
assert.throws(() => { missingBody.view.build(); assert.equal(missingBodyCalls, 1, '正文闭包缺失'); },
  error => error instanceof assert.AssertionError && /正文闭包缺失/.test(error.message));
pass('内存撤回disabled护栏和删除真实正文闭包的负控均被行为断言拒绝');

/**
 * 真实SDK不允许多@BuilderParam组件使用尾随闭包。扫描生产声明及入口，而非靠函数名统计覆盖。
 * 共享标题还必须显式接入非空content；实际布局和闭包绑定由SDK编译另证，不能由源转译冒充。
 */
const builderEntryContract = (() => {
  const directory = path.join(PROJECT_ROOT, 'entry/src/main/ets');
  const walk = folder => fs.readdirSync(folder, { withFileTypes: true }).flatMap(entry => entry.isDirectory()
    ? walk(path.join(folder, entry.name)) : entry.name.endsWith('.ets') ? [path.join(folder, entry.name)] : []);
  const sources = new Map(walk(directory).map(file => [path.relative(PROJECT_ROOT, file).replaceAll('\\', '/'), fs.readFileSync(file, 'utf8')]));
  const specs = new Map(), declarations = new Map();
  for (const [file, source] of sources) {
    // 生产具名Builder保留DSL，参数箭头仅转调；不遮蔽或替换真实正文来让宿主解析通过。
    const ast = compiler.createSourceFile(file, source, compiler.ScriptTarget.Latest, true);
    declarations.set(file, ast);
    for (const owner of ast.statements.filter(node => node.members && node.name)) {
      const slots = owner.members.filter(member => member.kind === compiler.SyntaxKind.PropertyDeclaration &&
        (compiler.getAllDecorators?.(member) ?? []).some(decorator => decorator.expression.getText(ast).split('(')[0] === 'BuilderParam'))
        .map(member => member.name.getText(ast));
      if (slots.length > 1) specs.set(owner.name.getText(ast), { file, slots });
    }
  }
  assert.ok(specs.get('ImmersiveTitleScaffold')?.slots.includes('content'), '必须读取共同宿主的真实多BuilderParam声明');
  const references = [], relevant = new Set([...specs.values()].map(spec => spec.file));
  function validate(file, source, capture = false) {
    const { tokens, pairs } = builderSourceLex(source);
    for (let index = 0; index < tokens.length - 1; index++) {
      const name = tokens[index].value;
      if (!specs.has(name) || tokens[index + 1].value !== '(') continue;
      const paren = index + 1, endParen = pairs.get(paren), line = source.slice(0, tokens[index].start).split('\n').length;
      assert.notEqual(tokens[endParen + 1]?.value, '{', file + ':' + line + ' 多BuilderParam组件不得使用尾随闭包：' + name);
      if (name !== 'ImmersiveTitleScaffold') continue;
      const object = paren + 1, endObject = pairs.get(object);
      assert.ok(tokens[object]?.value === '{' && endObject === endParen - 1, file + ' 共同标题必须使用显式单个参数对象');
      const content = [];
      for (let cursor = object + 1; cursor < endObject; cursor++) {
        if (tokens[cursor].value === 'content' && tokens[cursor + 1]?.value === ':') content.push(cursor);
        if (['(', '[', '{'].includes(tokens[cursor].value)) cursor = pairs.get(cursor);
      }
      assert.equal(content.length, 1, file + ' 正文必须显式传入唯一content');
      const property = content[0]; let arrow = property + 2;
      while (arrow < endObject && tokens[arrow].value !== '=>') {
        if (['(', '['].includes(tokens[arrow].value)) arrow = pairs.get(arrow);
        arrow++;
      }
      const body = arrow + 1, endBody = pairs.get(body);
      assert.ok(tokens[arrow]?.value === '=>' && tokens[body]?.value === '{' && endBody > body + 1,
        file + ' content必须使用箭头仅转调父@Builder');
      const transfer = tokens.slice(body + 1, endBody).map(token => token.value);
      assert.ok(transfer[0] === 'this' && transfer[1] === '.' && /^[A-Za-z_$][\w$]*$/.test(transfer[2]) &&
        transfer[3] === '(' && transfer[4] === ')' && (transfer.length === 5 || transfer.length === 6 && transfer[5] === ';'),
        file + ' content必须使用箭头仅转调父@Builder，不能内联DSL或改用漂移this的函数引用');
      const ast = declarations.get(file), scope = ast.statements.find(owner => owner.members &&
        owner.getStart(ast) <= tokens[index].start && owner.end >= tokens[index].start);
      const builder = scope?.members.find(member => member.name?.getText(ast) === transfer[2]);
      assert.ok(builder?.body && (compiler.getAllDecorators?.(builder) ?? []).some(decorator => decorator.expression.getText(ast) === 'Builder'),
        file + ' content必须指向同一父组件真实@Builder：' + transfer[2]);
      const builderBody = sources.get(file).slice(builder.body.getStart(ast), builder.body.end);
      assert.ok(builderSourceLex(builderBody).tokens.length > 2, file + ' 父@Builder不得丢失原正文');
      if (capture) references.push({ file, name, line, tokens, start: index, paren, endParen, object, endObject, property, body, endBody,
        parentBuilder: transfer[2], builderBody, bodySha256: createHash('sha256').update(builderBody).digest('hex') });
      relevant.add(file);
    }
  }
  for (const [file, source] of sources) validate(file, source, true);
  assert.ok(references.length > 0);
  // 从当前真实消费者保留同一正文，把具名content机械挪回尾随；词法入口门必须精确拒绝。
  const sample = references.find(item => item.file.endsWith('/AboutPage.ets')) ?? references[0];
  const original = sources.get(sample.file), t = sample.tokens;
  let removeStart = t[sample.property].start, removeEnd = t[sample.endBody].end;
  if (t[sample.endBody + 1]?.value === ',') removeEnd = t[sample.endBody + 1].end;
  else if (t[sample.property - 1]?.value === ',') removeStart = t[sample.property - 1].start;
  const withoutContent = original.slice(t[sample.object].start, removeStart) + original.slice(removeEnd, t[sample.endObject].end);
  const bare = original.slice(t[sample.start].start, t[sample.paren].end) + withoutContent + ')';
  const oldCall = bare + ' ' + original.slice(t[sample.body].start, t[sample.endBody].end);
  const trailing = original.slice(0, t[sample.start].start) + oldCall + original.slice(t[sample.endParen].end);
  assert.throws(() => validate(sample.file, trailing),
    error => error instanceof assert.AssertionError && /多BuilderParam组件不得使用尾随闭包/.test(error.message));
  const missing = original.slice(0, t[sample.start].start) + bare + original.slice(t[sample.endParen].end);
  assert.throws(() => validate(sample.file, missing),
    error => error instanceof assert.AssertionError && /正文必须显式传入唯一content/.test(error.message));
  // 把同一生产Builder原正文塞回参数箭头；必须拒绝这种已被SDK实际否定的inline DSL形态。
  const inline = original.slice(0, t[sample.body].start) + sample.builderBody + original.slice(t[sample.endBody].end);
  assert.throws(() => validate(sample.file, inline),
    error => error instanceof assert.AssertionError && /content必须使用箭头仅转调父@Builder/.test(error.message));
  const direct = original.slice(0, t[sample.property + 1].end) + ' this.' + sample.parentBuilder + original.slice(t[sample.endBody].end);
  assert.throws(() => validate(sample.file, direct),
    error => error instanceof assert.AssertionError && /content必须使用箭头仅转调父@Builder/.test(error.message));
  const sourceHashes = Object.fromEntries([...relevant].sort().map(file => [file,
    createHash('sha256').update(sources.get(file)).digest('hex')]));
  for (const [file, digest] of Object.entries(sourceHashes)) {
    assert.equal(createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex'), digest,
      '入口约束检查期间生产源码变化：' + file);
  }
  return { definitions: Object.fromEntries(specs), entries: references.map(({ file, name, line, parentBuilder, bodySha256 }) => ({ file, name, line, parentBuilder, bodySha256 })),
    sourceHashes, negativeSample: sample.file, limitations: '入口约束检查实际语法与真实父Builder引用，不证明SDK编译、布局或执行绑定' };
})();
pass('生产多BuilderParam禁尾随、content箭头仅转调真实父Builder；尾随/丢正文/内联DSL/错误this引用负控均拒绝');

assert.deepEqual(hashes(), initial, '测试期间核心生产源码变化，请在稳定后重新执行');
fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify({ status: 'passed', startedAt,
  finishedAt: new Date().toISOString(), groups, sourceHashes: initial, builderEntryContract,
  scope: 'production methods and production Builder control flow with declaration receivers; no pixels/native navigation/GPU claim',
  limits: ['声明接收器不证明布局尺寸或系统命中', 'SDK与设备观感由正常构建及指定设备独立验证'] }, null, 2) + '\n');

#!/usr/bin/env node
/**
 * 执行真实编辑器方法，验证精确位置输入与触发方式重绘没有旁路撤销和原存档单位。
 * UI布局由正式ArkTS编译和真机验证；宿主仅替换选择对象、几何读取和状态提示边界。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/LayoutEditor.ets'), 'utf8');
const pure = makePureEtsLoader();
const model = pure('gamecontrol/src/main/ets/ControlLayout.ets');
const keys = pure('gamecontrol/src/main/ets/GlfwKeys.ets');
const { ControlType, controlScene, setControlScene } = model;
let passed = 0;
const check = name => { passed++; console.log('PASS ' + name); };

/** 方法提取跳过注释和字符串的括号，运行对象来自生产实现而非测试重新实现。 */
function method(name) {
  const match = new RegExp('^  (?:private )?' + name + '\\s*\\(', 'm').exec(source);
  assert.ok(match, '真实方法不存在：' + name);
  let i = source.indexOf('{', match.index), depth = 0, quote = '', line = false, block = false;
  for (; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (line) { if (c === '\n') line = false; continue; }
    if (block) { if (c === '*' && n === '/') { block = false; i++; } continue; }
    if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue; }
    if (c === '/' && n === '/') { line = true; i++; continue; }
    if (c === '/' && n === '*') { block = true; i++; continue; }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return source.slice(match.index, i + 1);
  }
  throw Error('真实方法不完整：' + name);
}
const names = ['syncPositionDraft_', 'applyPositionDraft_', 'alignSelectedToScreen_', 'chooseTrigger_', 'requestCancel_',
  'chooseScene_', 'chooseVisibility_', 'chooseSwipeGroup_', 'addButton', 'addHotbar', 'setMultiSelect',
  'openAddPanel_', 'returnFromAddPanel_', 'addControlOptions_', 'addJoystick_', 'selectForEditor_', 'addControlFromPanel_',
  'openTab', 'compactPanel', 'panelChromeH', 'panelMinContentH', 'panelMaxTop', 'panelTopBase'];
const compiled = compiler.transpileModule('class Subject {\n' + names.map(method).join('\n') + '\n}\nmodule.exports=Subject;', {
  compilerOptions: { target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS }, reportDiagnostics: true,
});
assert.equal((compiled.diagnostics ?? []).filter(x => x.category === compiler.DiagnosticCategory.Error).length, 0);
const module = { exports: {} };
// 图标枚举只是UI外部边界；按键码、ID、新控件结构和物品栏仍使用真实生产模型。
const bindings = { ...model, ...keys, cloneControlItem:model.cloneItem, AppIconName: { Keyboard: 1, Hotbar: 2, GameController: 3 } };
new Function('module', ...Object.keys(bindings), compiled.outputText)(module, ...Object.values(bindings));

/** 几何端口使用本轮给定画布和布局比例；undo及存储边界被计数以发现误提交。 */
function fixture(type = ControlType.BUTTON) {
  const item = { type, baseWidth: 80, baseHeight: 80, itemScale: 0.8, xPct: 0.1, yPct: 0.2, trigger: 'press', swipeGroup: '2' };
  const view = new module.exports();
  Object.assign(view, { screenWidth: 1000, screenHeight: 600, globalScale: 1.25,
    undoCalls: 0, refreshCalls: 0, cancelCalls: 0, statusMsg: '', editorReady: true, persistenceBusy: false,
    baselineSig: 'original', sessionCatalogChanged: false, contentSignature: () => 'changed',
    positionXDraft: '120', positionYDraft: '160', positionWidthDraft: '120', positionHeightDraft: '64',
    selectedItem: () => item, selectedIsSystemMouse: () => item.systemAction === 'mouse',
    pushUndo: () => { view.undoCalls++; }, refreshControls: () => { view.refreshCalls++; },
    cancelEditor_: () => { view.cancelCalls++; },
    itemW: x => x.baseWidth * x.itemScale * view.globalScale,
    itemH: x => x.baseHeight * x.itemScale * view.globalScale,
    itemPxX: x => x.xPct * view.screenWidth, itemPxY: x => x.yPct * view.screenHeight,
  });
  return { view, item };
}

{
  const { view, item } = fixture(); view.applyPositionDraft_();
  assert.equal(item.xPct, 0.12); assert.equal(item.yPct, 160 / 600);
  assert.equal(item.baseWidth, 120); assert.equal(item.baseHeight, 64);
  assert.equal(view.undoCalls, 1); assert.equal(view.refreshCalls, 1);
  check('精确位置沿原百分比字段提交，尺寸正确抵消全局与单项比例，只有一个撤销点');
}
for (const invalid of ['', 'NaN', '-1', '15']) {
  const { view, item } = fixture(); const before = structuredClone(item);
  view.positionWidthDraft = invalid; view.applyPositionDraft_();
  assert.deepEqual(item, before); assert.equal(view.undoCalls, 0); assert.ok(view.statusMsg);
  check('无效尺寸拒绝且不制造撤销：' + JSON.stringify(invalid));
}
{
  const { view } = fixture(); view.positionWidthDraft = '15'; view.applyPositionDraft_();
  const error = view.statusMsg; assert.ok(error);
  view.positionWidthDraft = '120'; view.applyPositionDraft_();
  assert.equal(view.statusMsg, '位置与尺寸已应用'); assert.notEqual(view.statusMsg, error); assert.equal(view.undoCalls, 1);
  view.positionHeightDraft = 'NaN'; view.applyPositionDraft_(); const secondError = view.statusMsg;
  view.alignSelectedToScreen_('11');
  assert.equal(view.statusMsg, '已按当前屏幕完成定位'); assert.notEqual(view.statusMsg, secondError);
  assert.equal(view.undoCalls, 2);
  check('尺寸错误修正应用或快速定位成功后替换旧错误提示，失败不制造撤销');
}
{
  const { view, item } = fixture(); item.locked = true; const before = structuredClone(item); view.applyPositionDraft_();
  assert.deepEqual(item, before); assert.equal(view.undoCalls, 0); check('锁定项拒绝数字位置变更');
}
{
  const { view, item } = fixture(ControlType.HOTBAR_SELECTOR); view.positionXDraft = '9999'; view.positionYDraft = '-99'; view.applyPositionDraft_();
  assert.equal(item.xPct, (1000 - 120) / 1000); assert.equal(item.yPct, 0); assert.equal(item.hotbarUserPlaced, true);
  check('物品栏精确移动夹取边界并保留手工定位身份');
}
{
  const { view, item } = fixture(); view.alignSelectedToScreen_('22');
  assert.equal(item.xPct, 0.92); assert.equal(item.yPct, 520 / 600); assert.equal(view.undoCalls, 1);
  view.alignSelectedToScreen_('11'); assert.equal(item.xPct, 0.46); assert.equal(item.yPct, 260 / 600);
  check('当前视口快速定位在原百分比语义内落到边缘和中心');
}
{
  const { view, item } = fixture(); view.chooseTrigger_('press'); assert.equal(view.undoCalls, 0);
  view.chooseTrigger_('doubleTap'); assert.equal(item.trigger, 'doubleTap'); assert.equal(item.swipeGroup, undefined); assert.equal(view.undoCalls, 1);
  item.systemAction = 'mouse'; view.chooseTrigger_('toggle'); assert.equal(item.trigger, 'doubleTap');
  check('直接触发选择只记一项撤销、清除不兼容连滑并保护系统鼠标');
}
{
  const { view } = fixture(); view.requestCancel_(); assert.equal(view.showLeaveConfirm, true); assert.equal(view.cancelCalls, 0);
  view.showLeaveConfirm = false; view.persistenceBusy = true; view.requestCancel_(); assert.equal(view.showLeaveConfirm, false);
  view.persistenceBusy = false; view.editorReady = false; view.requestCancel_(); assert.equal(view.cancelCalls, 1);
  check('取消确认不提前写Store，处理中拒绝重入，初始化失败保留既有取消恢复入口');
}
{
  const { view } = fixture(); view.contentSignature = () => 'original'; view.requestCancel_();
  assert.equal(view.cancelCalls, 1); assert.notEqual(view.showLeaveConfirm, true);
  view.sessionCatalogChanged = true; view.requestCancel_();
  assert.equal(view.cancelCalls, 1); assert.equal(view.showLeaveConfirm, true);
  check('无调整或撤销回原内容直接退出，目录事务即使当前草稿一致仍要求确认');
}
{
  const { view, item } = fixture(); view.chooseScene_('menu'); view.chooseVisibility_('force_show');
  assert.equal(controlScene(item), 'menu'); assert.equal(item.visibilityOverride, 'force_show');
  view.chooseVisibility_('auto'); assert.equal(item.visibilityOverride, undefined); assert.equal(controlScene(item), 'menu');
  const before = view.undoCalls; view.chooseScene_('menu'); assert.equal(view.undoCalls, before);
  item.systemAction = 'mouse'; view.chooseScene_('game'); view.chooseVisibility_('force_hide');
  assert.equal(controlScene(item), 'menu'); assert.equal(item.visibilityOverride, undefined);
  check('场景与三态显示独立提交，重复选择不记撤销且系统鼠标固定语义不被改写');
}
{
  const { view, item } = fixture(); view.chooseSwipeGroup_('3'); assert.equal(item.swipeGroup, '3'); assert.equal(view.undoCalls, 1);
  item.dragLook = true; view.chooseSwipeGroup_('1'); assert.equal(item.swipeGroup, '3'); assert.equal(view.undoCalls, 1);
  item.dragLook = false; item.trigger = 'toggle'; view.chooseSwipeGroup_('1'); assert.equal(item.swipeGroup, '3');
  item.trigger = 'press'; view.chooseSwipeGroup_(''); assert.equal(item.swipeGroup, undefined);
  view.chooseSwipeGroup_('invalid'); assert.equal(item.swipeGroup, undefined); assert.equal(view.undoCalls, 2);
  check('明确连滑组只接受原普通按住入口，拒绝瞄准、其它触发与非法组');
}

/** 添加用同一个生产Subject；仅把UI刷新和屏幕自动对齐的外部几何端口计数，不重写创建逻辑。 */
function addFixture() {
  const { view } = fixture();
  Object.assign(view, { controls: [], selectedIdx: -1, selectedIds: [], multiSelectMode: false, groupDragging: false,
    ver: 0, showPanel: false, activeSheet: 'edit', addControlSearch: '', panelY: 12, panelDragDy: 0,
    showKeyPicker: false, appearanceSyncs: 0, autoAlignCalls: 0, selectedScaleVal: 100,
    syncSelectedAppearanceVals() { view.appearanceSyncs++; },
    autoAlignHotbar() { view.autoAlignCalls++; },
  });
  return view;
}
{
  const view = addFixture(); view.multiSelectMode = true; view.addControlSearch = '旧搜索'; view.openAddPanel_();
  assert.equal(view.activeSheet, 'add'); assert.equal(view.showPanel, true); assert.equal(view.addControlSearch, '旧搜索');
  assert.equal(view.controls.length, 0); assert.equal(view.undoCalls, 0); assert.equal(view.multiSelectMode, true);
  check('添加入口只打开独立目录并清搜索，不创建控件、不改选择或撤销');
}
{
  const view = addFixture();
  assert.deepEqual(view.addControlOptions_().map(option=>option.id),['button','joystick','hotbar','space','shift','e','esc']);
  check('简化添加目录直接列出基础能力，无额外搜索状态');
}
{
  const view = addFixture(); view.openAddPanel_(); view.addControlFromPanel_('button');
  assert.equal(view.controls.length, 1); assert.equal(view.controls[0].type, ControlType.BUTTON);
  assert.deepEqual(view.controls[0].keys, [keys.GLFW_KEY_G]); assert.equal(view.showKeyPicker, true);
  assert.equal(view.selectedIdx, 0); assert.equal(view.undoCalls, 1); assert.equal(view.activeSheet, 'add');
  assert.equal(view.controls[0].hidden, false); assert.deepEqual(view.controls[0].hideOnInput, []);
  check('普通添加沿原G占位/新ID/一次撤销/选中并打开键位选择器');
}
for (const [id, code] of [['space', keys.GLFW_KEY_SPACE], ['shift', keys.GLFW_KEY_LEFT_SHIFT], ['e', keys.GLFW_KEY_E], ['esc', keys.GLFW_KEY_ESCAPE]]) {
  const view = addFixture(); view.multiSelectMode = true; view.selectedIds = ['old']; view.addControlFromPanel_(id);
  assert.equal(view.controls.length, 1); assert.deepEqual(view.controls[0].keys, [code]); assert.equal(view.controls[0].keyOrMouse, code);
  assert.equal(view.controls[0].type, ControlType.BUTTON); assert.equal(view.undoCalls, 1); assert.equal(view.selectedIdx, 0);
  assert.equal(view.showKeyPicker, false); assert.equal(view.multiSelectMode, false); assert.deepEqual(view.selectedIds, []);
  check('常用键 ' + id + ' 直接绑定普通按钮、明确单选、仅一笔新增撤销');
}
{
  const view = addFixture(); view.addControlFromPanel_('hotbar');
  assert.equal(view.controls.length, 1); assert.equal(view.controls[0].type, ControlType.HOTBAR_SELECTOR);
  assert.equal(view.selectedIdx, 0); assert.equal(view.undoCalls, 1); assert.equal(view.autoAlignCalls, 1);
  const id = view.controls[0].id; view.selectedIdx = -1; view.addControlFromPanel_('hotbar');
  assert.equal(view.controls.length, 1); assert.equal(view.controls[0].id, id); assert.equal(view.selectedIdx, 0);
  assert.equal(view.undoCalls, 1); assert.equal(view.autoAlignCalls, 1);
  view.addControlFromPanel_('hotbar'); assert.equal(view.controls.length, 1); assert.equal(view.undoCalls, 2); assert.equal(view.autoAlignCalls, 2);
  check('物品栏新建自动对齐，已有先选中，再点才重对齐，不创建重复控件');
}
{
  const view = addFixture(); view.addControlFromPanel_('drawer');
  assert.equal(view.controls.length, 0); assert.equal(view.undoCalls, 0); assert.ok(view.statusMsg);
  view.openAddPanel_(); view.panelY = 350; view.returnFromAddPanel_();
  assert.equal(view.activeSheet, 'edit'); assert.equal(view.showPanel, true); assert.ok(view.panelY <= view.panelMaxTop());
  assert.equal(view.undoCalls, 0);
  check('未知/旧类型不能创建；返回布局夹回新骨架内且不污染撤销');
}
console.log('PASS ' + passed + ' layout editor panel production groups');

{
  const view=addFixture();view.selectedItem=()=>view.controls[view.selectedIdx]??null;
  view.selectForEditor_=index=>{view.selectedIdx=index;};
  view.addControlFromPanel_('joystick');assert.equal(view.controls.length,1);assert.equal(view.controls[0].type,ControlType.JOYSTICK);
  const id=view.controls[0].id;view.addControlFromPanel_('joystick');assert.equal(view.controls.length,1);assert.equal(view.controls[0].id,id);
  assert.equal(view.undoCalls,1);check('恢复基础摇杆只新增缺失项，重复选择不重置布局');
}

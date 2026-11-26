/**
 * 触控修复的组合回归：执行生产模型、真实Store/V2和实际编辑器方法。
 * 平台/绘制边缘替身只提供输入与记录结果，不复制保存、转换或批量修改算法。
 * 本脚本不代表真实ArkUI、传感器或Minecraft消费已通过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { fixture as storageFixture } from './lib/game-layout-fixture.mjs';
import { compactEditorFixture } from './lib/compact-editor-fixture.mjs';
import { actionUiReceiver, loadActionComponent } from './lib/unified-actions-fixture.mjs';

const load=makePureEtsLoader();
const model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const editing=load('gamecontrol/src/main/ets/ControlEditing.ets');
const groups=load('gamecontrol/src/main/ets/ControlGroups.ets');
const candidates=load('gamecontrol/src/main/ets/LayoutCandidate.ets');
let cases=0;
function pass(name) { cases++; console.log('PASS '+name); }

// 系统聊天保留有效自定义绑定，旧空值恢复默认T；普通键仍允许解绑，原输入不被原地修改。
for (const keys of [[84],[341,89],[]]) {
  const profile=model.getDefaultLayout();
  const chat=profile.controls.find(item=>item.systemAction==='input');
  chat.keys=keys.slice(); chat.keyOrMouse=keys[0]??0;
  const before=JSON.stringify(profile), result=candidates.buildLayoutCandidate(profile);
  assert.ok(result.profile,result.reason);
  assert.deepEqual(model.effectiveKeys(result.profile.controls.find(item=>item.systemAction==='input')),keys.length?keys:[84]);
  assert.equal(JSON.stringify(profile),before);
}
{
  const profile=model.getDefaultLayout(), ordinary=profile.controls.find(item=>item.id==='atk');
  ordinary.keys=[];ordinary.keyOrMouse=0;
  const candidate=candidates.buildLayoutCandidate(profile);assert.ok(candidate.profile);
  assert.deepEqual(model.effectiveKeys(candidate.profile.controls.find(item=>item.id==='atk')),[]);
}
pass('候选保全聊天T和自定义组合，旧空值恢复T；普通解绑与原对象保持');

{
  const profile=model.getDefaultLayout(), button=profile.controls.find(item=>item.id==='atk');
  button.keys=[32,341];button.keyOrMouse=32;button.trigger='doubleTap';
  const before=JSON.stringify(profile);
  assert.equal(editing.controlUsesPhases(button),false);
  assert.match(editing.controlPhaseConversionDescription(button),/第二次按下.*第二次合格抬起/s);
  const next=editing.convertControlToPhases(profile,button.id);
  assert.ok(next);assert.equal(next.version,5);
  assert.deepEqual(next.controls.find(item=>item.id===button.id).phaseBindings,[{phase:'doubleClick',keys:[32,341],autoKeep:false}]);
  assert.ok(next.requiredCapabilities.includes('touch-phases-v1'));assert.equal(JSON.stringify(profile),before);
  for (const unsupported of [1,512,-9,-16]) {
    button.keys=[32,unsupported];assert.match(editing.controlPhaseConversionIssue(button),/不支持/);
    assert.equal(editing.convertControlToPhases(profile,button.id),null);
  }
  button.keys=[32];button.modifiers=2;assert.equal(editing.convertControlToPhases(profile,button.id),null);
  const copy=model.cloneLayoutWithFreshGroupIds(model.getDefaultLayout());
  assert.notEqual(copy.controls[0].id,model.getDefaultLayout().controls[0].id,'无组复制也应分配控件新身份');
  pass('旧触发显式转换保序、完整能力升级、窄码域与修饰拒绝，无组复制换身份');
}

/** 提取真实编辑方法；不执行ArkUI DSL，Undo记录和屏幕是测试提供的边缘。 */
function editorFixture() {
  const source=fs.readFileSync(new URL('../entry/src/main/ets/components/LayoutEditor.ets',import.meta.url),'utf8');
  const ast=compiler.createSourceFile('LayoutEditor.ets',source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='LayoutEditor');
  const names=['selectedItem','editorGroupVisible_','selectAllControls','multiSelectedItems','geometryTargets_',
    'styleTargets','unifyAllSizes','batchAlign','batchEqualSpacing','itemW','itemH','itemPxX','itemPxY','itemCenterX','itemCenterY',
    'requestPhaseConversion_','selectControlIdentity_','applyGroupDraft_','refreshControls','chooseTrigger_','currentPhaseAutoKeep_',
    'selectedBindingLabel_','phaseName_','moveChildOrder_','secondaryEditingDefinition_','captureEditorRoute_','syncSecondarySelection_'];
  const declarations=names.map(name=>{const fn=owner.members.find(node=>node.name?.getText(ast)===name);assert.ok(fn,name);return fn.getText(ast);});
  const route=ast.statements.find(node=>node.name?.getText(ast)==='CompactEditorRoute').getText(ast);
  const code=compiler.transpileModule(route+'\nclass Subject{'+declarations.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
  const bindings={...model,...editing,...groups,...load('gamecontrol/src/main/ets/GlfwKeys.ets'),cloneControlItem:model.cloneItem};
  const module={exports:{}};new Function('module',...Object.keys(bindings),code)(module,...Object.values(bindings));
  const profile=model.enableLayoutControlGroups(model.getDefaultLayout());
  profile.controlGroups.push({id:'hidden_group',name:'未预览',initialVisible:false});
  const view=new module.exports(), undo=[],dialogs=[];
  Object.assign(view,{controls:profile.controls,controlGroups:profile.controlGroups,defaultControlGroupId:profile.defaultControlGroupId,
    secondaryEditingGroup:'',editorRoutes:[],activeSheet:'edit',inlinePickerGeneration:0,
    requiredCapabilities:profile.requiredCapabilities,currentControlGroup:profile.defaultControlGroupId,previewControlGroups:[profile.defaultControlGroupId],
    selectedIdx:-1,selectedChildId:'',selectedIds:[],allGroups:false,multiSelectMode:false,ver:0,screenWidth:1000,screenHeight:600,globalScale:1,
    editorMounted:true,editorGeneration:1,statusMsg:'',groupActionPhase:'press',
    buildProfile(){return model.cloneLayout({...profile,controls:this.controls,controlGroups:this.controlGroups,requiredCapabilities:this.requiredCapabilities});},
    pushUndo(){undo.push(this.buildProfile());},repairEditorGroups_(){},syncSelectedAppearanceVals(){},syncPositionDraft_(){},openTab(tab){this.activeSheet=tab;},
    getUIContext(){return {showAlertDialog(dialog){dialogs.push(dialog);}};},selectedIsSystemMouse(){return this.selectedItem()?.systemAction==='mouse';},
  });
  return {view,undo,dialogs,profile};
}

{
  const {view}=editorFixture();
  let a=view.controls.find(item=>item.id==='atk'), b=view.controls.find(item=>item.id==='place');
  b.controlGroupId='hidden_group';view.selectAllControls();assert.ok(view.selectedIds.includes(a.id));assert.ok(!view.selectedIds.includes(b.id));
  view.allGroups=true;view.selectAllControls();assert.ok(view.selectedIds.includes(b.id));
  view.selectedIds=[a.id,b.id];a.yPct=.1;b.yPct=.8;b.locked=true;const original=JSON.stringify(b);
  view.batchAlign('h');assert.equal(JSON.stringify(b),original,'锁定项不能被批量对齐或作为唯一第二目标');
  b.locked=false;view.batchAlign('h');assert.equal(a.yPct,b.yPct);
  // refreshControls按生产合同深复制数组；后续用户编辑须重新获取当前对象，不能修改旧引用。
  a=view.controls.find(item=>item.id==='atk');b=view.controls.find(item=>item.id==='place');
  const system=view.controls.find(item=>item.systemAction==='edit');system.baseWidth=123;system.style={shape:'circle',cornerRadius:1};
  a.style={shape:'diamond',cornerRadius:.7,opacity:.1};a.isCircle=true;b.locked=true;
  view.multiSelectMode=true;view.selectedIds=[a.id,b.id,system.id];const systemBefore=JSON.stringify(system),bBefore=JSON.stringify(b);
  view.unifyAllSizes();const changed=view.controls.find(item=>item.id===a.id);
  assert.equal(changed.baseWidth,model.DEFAULT_BUTTON_SIZE);assert.deepEqual(JSON.parse(JSON.stringify(changed.style)),a.style);assert.equal(changed.isCircle,true);
  assert.equal(JSON.stringify(view.controls.find(item=>item.id===b.id)),bBefore);assert.equal(JSON.stringify(view.controls.find(item=>item.id===system.id)),systemBefore);
  pass('真实编辑器可见范围、几何锁定、标准尺寸字段边界');
}

{
  const {view,dialogs,undo}=editorFixture();view.selectedIdx=view.controls.findIndex(item=>item.id==='atk');
  view.selectedItem().trigger='doubleTap';const before=JSON.stringify(view.buildProfile());
  view.requestPhaseConversion_();assert.equal(dialogs.length,1);dialogs[0].primaryButton.action();
  assert.equal(JSON.stringify(view.buildProfile()),before);assert.equal(undo.length,0);
  view.requestPhaseConversion_();dialogs[1].secondaryButton.action();
  assert.equal(undo.length,1);assert.ok(view.selectedItem().phaseBindings);assert.equal(view.activeSheet,'group-actions');
  // 迟到确认不得改写已经变化的控件或整份草稿。
  const second=editorFixture();second.view.selectedIdx=second.view.controls.findIndex(item=>item.id==='atk');
  second.view.requestPhaseConversion_();second.view.selectedItem().label='确认期间改变';second.dialogs[0].secondaryButton.action();
  assert.equal(second.undo.length,0);assert.equal(second.view.selectedItem().phaseBindings,undefined);
  pass('实际首次阶段转换入口：取消零修改、确认一笔Undo、迟到确认拒绝');
}

{
  const {view}=editorFixture();const parent=model.cloneItem(view.controls.find(item=>item.id==='atk'));
  parent.id='drawer';parent.type=model.ControlType.DRAWER;parent.keys=[];parent.keyOrMouse=0;
  const child=model.cloneItem(view.controls.find(item=>item.id==='place'));child.id='child';child.hidden=true;
  parent.children=[child];view.controls.push(parent);view.selectControlIdentity_('child',false);
  assert.equal(view.selectedItem().id,'child');assert.equal(view.selectedItem().hidden,true);
  const source=view.buildProfile(),next=editing.convertControlToPhases(source,'child');assert.ok(next);
  assert.ok(editing.findControlEditTarget(next.controls,'child').item.phaseBindings);
  assert.equal(editing.findControlEditTarget(next.controls,'child').item.hidden,true);
  pass('隐藏抽屉子项稳定ID选择及阶段转换保留隐藏与归属');
}

/** 生产浮窗产生入口和开关回调，声明接收器仅隔离 ArkUI 绘制。 */
async function exerciseButtonDragEditor(store, profile) {
  const ui = actionUiReceiver();
  const rows = [];
  const panel = loadActionComponent('entry/src/main/ets/components/LayoutEditor.ets', 'LayoutEditor', {
    methods: ['SelectedItemControls', 'SelectedMorePanel_', 'ActionsTabContent_', 'BehaviorTabContent', 'SectionLabel', 'ActionFooter'],
    render: true,
    globals: { ...ui.globals, Color: {Transparent: 'transparent'}, TextAlign: {End: 'end'}, ToggleType: {Switch: 'switch'},
      Slider: ui.globals.Column, Blank: ui.globals.Column,
      type: value => ui.globals.Button().type(value),
      Toggle: props => ui.globals.Button('拖动开关', props),
      CompactEditorRow: props => { rows.push(props); return ui.globals.Row(); } },
    dependencies: { gamecontrol: {...model, ...editing}, commons: load('commons/src/main/ets/common/IconCatalog.ets'),
      './AppIcon': {AppIcon: ui.globals.AppIcon} },
  }).prototype;
  const render = (view, builder) => {
    rows.length = 0;
    ui.clear();
    panel[builder].call(view);
  };
  const row = title => {
    const matches = rows.filter(item => item.title === title);
    assert.equal(matches.length, 1, title);
    return matches[0];
  };
  const button = label => {
    const matches = ui.records.filter(item => item.type === 'Button' &&
      (item.args[0] === label || item.modifiers.accessibilityText?.[0] === label));
    assert.equal(matches.length, 1, label);
    return matches[0];
  };
  const select = (view, id) => view.selectControlIdentity_(id);
  const openMore = view => {
    render(view, 'SelectedItemControls');
    button('更多按键设置').modifiers.onClick[0]();
    assert.equal(view.activeSheet, 'more');
    render(view, 'SelectedMorePanel_');
  };
  const openDrag = (view, isOn) => {
    openMore(view);
    assert.equal(row('触发与拖动').value, isOn ? '拖动视角已开' : '拖动视角已关');
    row('触发与拖动').onTap();
    assert.equal(view.activeSheet, 'group-actions');
    render(view, 'ActionsTabContent_');
    const toggle = button('拖动开关');
    assert.equal(toggle.args[1].isOn, isOn);
    assert.ok(ui.records.indexOf(toggle) < ui.records.indexOf(button('修改输出绑定')), '按住时拖动视角应在动作页前部');
    button('双击');
    button('组 1');
    return toggle.modifiers.onChange[0];
  };
  const {view} = compactEditorFixture(profile, store);
  view.SectionLabel = panel.SectionLabel;
  await view.aboutToAppear();
  assert.equal(view.editorReady, true, view.statusMsg);
  select(view, 'atk');
  const original = view.buildProfile();
  render(view, 'SelectedItemControls');
  row('绑定').onTap();
  assert.equal(view.showKeyPicker, true);
  assert.equal(view.activeSheet, 'edit', '普通按键绑定仍直接打开选键器');
  view.backEditor_();
  assert.equal(view.showKeyPicker, false);
  const turnOnLeft = openDrag(view, false);
  turnOnLeft(false);
  assert.equal(view.undoCount, 0, '重复派发当前值不记撤销');
  turnOnLeft(true);
  assert.equal(view.selectedItem().dragLook, true);
  assert.equal(view.selectedItem().swipeGroup, undefined);
  assert.deepEqual(view.controls.find(item => item.id === 'place'), original.controls.find(item => item.id === 'place'));
  assert.equal(view.undoCount, 1);
  view.undo();
  assert.equal(view.selectedItem().id, 'atk');
  assert.equal(view.selectedItem().swipeGroup, '1');
  assert.deepEqual(view.buildProfile(), original, '一次撤销恢复此键的瞄准与接力');
  view.backEditor_();
  assert.equal(view.activeSheet, 'more');
  render(view, 'SelectedMorePanel_');
  row('显示规则').onTap();
  assert.equal(view.activeSheet, 'behavior');
  render(view, 'BehaviorTabContent');
  assert.ok(ui.records.some(item => item.type === 'Text' && item.args[0] === '何时显示'));
  view.backEditor_();
  view.backEditor_();
  assert.equal(view.activeSheet, 'edit');
  assert.equal(view.selectedItem().id, 'atk');
  assert.equal(view.undoCount, 0, '选择、进页和返回不写草稿');

  select(view, 'place');
  openDrag(view, false)(true);
  assert.deepEqual(view.controls.find(item => item.id === 'atk'), original.controls.find(item => item.id === 'atk'));
  let saved;
  view.onDone = confirmed => { saved = confirmed; };
  render(view, 'ActionFooter');
  button('保存').modifiers.onClick[0]();
  await view.persistenceTask;
  assert.equal(saved?.profileId, profile.profileId, view.statusMsg);
  assert.equal(saved.profileRevision, profile.profileRevision + 1);
  assert.equal(store.isEditorActive(), false);

  const reopened = compactEditorFixture(store.getProfile(profile.name), store).view;
  await reopened.aboutToAppear();
  assert.equal(reopened.editorReady, true, reopened.statusMsg);
  select(reopened, 'atk');
  openDrag(reopened, false);
  assert.equal(reopened.selectedItem().swipeGroup, '1');
  select(reopened, 'place');
  openDrag(reopened, true);
  assert.equal(reopened.selectedItem().swipeGroup, undefined);
  reopened.aboutToDisappear();
  await reopened.editorCleanupTask;
  assert.equal(store.isEditorActive(), false);
  pass('真实紧凑入口、左右拖动独立、接力互斥、撤销与保存重开');
}

// 真实Store链覆盖此前“组件测试替换Store”漏掉的候选规范化，并验证删除与复制事务。
const f=storageFixture();
try {
  const source=model.getDefaultLayout();source.name='触控回归';source.isPreset=false;
  Object.assign(source.controls.find(item=>item.id==='atk'),{dragLook:false,swipeGroup:'1'});
  Object.assign(source.controls.find(item=>item.id==='place'),{dragLook:false,swipeGroup:'2'});
  source.touch={menuSensitivity:1.73,actionOverrides:{attack:77}};source.gamepad={buttonMap:{MODE:{kind:'key',code:88}}};
  source.controls.find(item=>item.systemAction==='input').keys=[341,89];
  f.ownerData.set('control_layout',new Map([['profiles',JSON.stringify([source])],['active_profile',source.name]]));
  await f.launchV2();const store=f.child.store;
  const before=store.getProfile(source.name);const changed=model.cloneLayout(before);changed.touch.menuSensitivity=1.9;
  const saved=await store.saveEditedProfile(changed);assert.ok(saved);store.commitEditorTransaction();
  const reloaded=store.getProfile(saved.name);
  assert.deepEqual(model.effectiveKeys(reloaded.controls.find(item=>item.systemAction==='input')),[341,89]);
  assert.deepEqual(reloaded.controls,before.controls,'只改输入设置不能清布局绑定或几何');
  await exerciseButtonDragEditor(store, reloaded);
  const copySource=store.getProfile(saved.name);
  const copied=await store.createProfile('明确复制',copySource);store.commitEditorTransaction();
  assert.deepEqual(copied.touch,copySource.touch);assert.deepEqual(copied.gamepad,copySource.gamepad);
  assert.notEqual(copied.controls[0].id,copySource.controls[0].id);assert.notEqual(copied.profileId,copySource.profileId);
  const stale=store.reviewProfileDeletion(copied.name);assert.ok(stale);
  const edit=model.cloneLayout(copied);edit.touch.menuSensitivity=2;
  assert.ok(await store.saveEditedProfile(edit));store.commitEditorTransaction();
  assert.equal(await store.deleteReviewedProfile(stale),false);assert.ok(store.getProfile(copied.name));
  const current=store.reviewProfileDeletion(copied.name);assert.ok(current);
  assert.equal(await store.deleteReviewedProfile(current),true);store.commitEditorTransaction();
  assert.equal(store.getProfile(copied.name),null);assert.equal(store.getActiveProfile().name,current.fallbackName);
  assert.equal(await store.deleteReviewedProfile(current),false,'重复旧确认不能删除新对象');
  assert.equal(store.reviewProfileDeletion(store.getPresetProfileNames()[0]),null);
  const running=await f.owner.journal.importPending(f.disk.context);
  assert.equal(running.deferred,true,'游戏仍活动时不能导入其未结束的配置事务');
  f.state.lock=0;
  const imported=await f.owner.journal.importPending(f.disk.context);
  assert.equal(imported.imported,1,JSON.stringify(imported));
  assert.deepEqual(model.effectiveKeys(f.owner.store.getProfile(source.name).controls.find(item=>item.systemAction==='input')),[341,89]);
  const restarted = f.restartOwner();
  await restarted.store.init(f.disk.context);
  const persisted = restarted.store.getProfile(source.name);
  const left = persisted.controls.find(item => item.id === 'atk'), right = persisted.controls.find(item => item.id === 'place');
  assert.deepEqual([left.dragLook, left.swipeGroup, right.dragLook, right.swipeGroup], [false, '1', true, undefined]);
  pass('真实Store→候选→V2重载/owner合并：拖动设置和聊天持久化、完整复制、删除修订CAS与回退');
} finally { f.disk.close(); }

console.log('PASS touch editing contract: '+cases+' production paths');

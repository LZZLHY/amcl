/** 执行真实编辑器的组操作、build/load 和撤销方法；只替换屏幕显示与设备名称端口。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const load=makePureEtsLoader();
const model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const groups=load('gamecontrol/src/main/ets/ControlGroups.ets');
const source=fs.readFileSync(new URL('../entry/src/main/ets/components/LayoutEditor.ets',import.meta.url),'utf8');
const ast=compiler.createSourceFile('LayoutEditor.ets',source,compiler.ScriptTarget.Latest,true);
const owner=ast.statements.find(n=>n.name?.getText(ast)==='LayoutEditor');
const names=['buildProfile','loadProfile','cloneGamepad','currentDeviceModel','selectedItem','refreshControls','pushUndo','undo',
  'repairEditorGroups_','editorGroupVisible_','editorCanvasOrder_','applyGroupDraft_','chooseControlGroup_','toggleGroupPreview_',
  'createControlGroup_','renameControlGroup_','setGroupInitialVisible_','moveGroupOrder_','duplicateControlGroup_',
  'groupDeletionDescription_','deleteControlGroup_','moveSelectedToGroup_','currentGroup_','filteredControlGroups_',
  'phaseName_','selectGroupPhase_','selectedGroupAction_','phaseActionIndices_','groupActionSummary_','selectGroupAction_','moveGroupAction_','removePhaseTarget_','selectedBindingLabel_','phaseTargets_','setPhaseTargets_','togglePhaseTarget_','currentPhaseKeys_','applyPhaseKeys_'];
const declarations=names.map(name=>{const method=owner.members.find(n=>n.name?.getText(ast)===name);assert.ok(method,name);return method.getText(ast);});
const edit=load('gamecontrol/src/main/ets/LayoutEditSession.ets');
const bindings={...model,...groups,...edit,...load('gamecontrol/src/main/ets/GlfwKeys.ets'),
  ...load('gamecontrol/src/main/ets/TouchPreferences.ets'),...load('gamecontrol/src/main/ets/LookPreferences.ets'),
  ...load('entry/src/main/ets/components/LayoutCatalogPaging.ets'),cloneControlItem:model.cloneItem,
  deviceInfo:{marketName:'host fixture'},UNDO_STACK_MAX:20};
const compiled=compiler.transpileModule('class Subject{'+declarations.join('\n')+'}\nmodule.exports=Subject;',
  {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
const module={exports:{}};new Function('module',...Object.keys(bindings),compiled)(module,...Object.values(bindings));
const view=new module.exports();
Object.assign(view,{selectedIds:[],selectedIdx:-1,profileNames:[],previewControlGroups:[],currentControlGroup:'',ver:0,
  groupNameDraft:'',groupSearch:'',deletingGroup:'',groupActionPhase:'press',groupActionOperation:'toggle',phaseKeyControlId:'',
  multiSelectMode:false,editSession:new edit.LayoutEditSession(),selectedGroupActionIndex:-1,undoCount:0,syncLookSliders(){}});
const initial=model.getDefaultLayout();initial.name='编辑测试';view.loadProfile(initial);
view.groupNameDraft='工具';view.createControlGroup_();
assert.equal(view.controlGroups.length,2);assert.equal(view.undoCount,1);
const tools=view.currentControlGroup;assert.equal(view.currentGroup_().initialVisible,false);
view.toggleGroupPreview_(view.defaultControlGroupId);assert.equal(view.buildProfile().controlGroups[1].initialVisible,false);
view.selectedIdx=view.controls.findIndex(item=>!item.systemAction&&item.type===0);
const originalItem=model.cloneItem(view.selectedItem());view.moveSelectedToGroup_();
assert.equal(view.selectedItem().controlGroupId,tools);
assert.equal(view.selectedItem().xPct,originalItem.xPct);assert.deepEqual(view.selectedItem().keys,originalItem.keys);
view.groupActionOperation='hide';view.setPhaseTargets_([tools]);
assert.equal(view.buildProfile().controls[view.selectedIdx].groupActions[0].targets[0],tools);
view.phaseKeyControlId=view.selectedItem().id;view.phaseKeyPhase='click';view.groupActionPhase='press';
view.applyPhaseKeys_([69]);assert.equal(view.selectedItem().phaseBindings.find(p=>p.phase==='click').keys[0],69);
assert.equal(view.buildProfile().version,5);
const beforeCopy=JSON.stringify(view.buildProfile());view.duplicateControlGroup_();
const copy=view.currentControlGroup;assert.notEqual(copy,tools);
assert.ok(view.controls.some(item=>item.controlGroupId===copy&&item.groupActions?.[0].targets[0]===copy));
view.undo();assert.equal(JSON.stringify(view.buildProfile()),beforeCopy);
view.chooseControlGroup_(tools);view.deletingGroup=tools;const beforeDelete=JSON.stringify(view.buildProfile());
assert.match(view.groupDeletionDescription_(),/1.*成员/);view.deleteControlGroup_(true);
assert.equal(view.controlGroups.some(g=>g.id===tools),false);
assert.equal(view.controls.some(c=>c.groupActions?.some(a=>a.targets.includes(tools))),false);
view.undo();assert.equal(JSON.stringify(view.buildProfile()),beforeDelete);
assert.equal(view.currentControlGroup,tools);
view.groupNameDraft='重命名';view.renameControlGroup_();assert.equal(view.currentGroup_().id,tools);
view.moveGroupOrder_(-1);assert.equal(view.controlGroups[0].id,tools);
const saved=view.buildProfile();assert.ok(model.validateAndNormalizeLayout(JSON.parse(JSON.stringify(saved))));
console.log('PASS actual editor group operations: separate preview/initial state, member move, phase binding, copy/delete/undo and stable rename/order');

/**
 * 真机回归：首次build尚无schema时，确认marker分支仍必须订阅组修订。
 * 提取生产条件直接执行，用getter记录其真实读取依赖；不复制ArkUI渲染器，
 * 此处只证明分支可被@State通知，实际didLayout和Native ACK仍交真机验证。
 */
{
  const text=fs.readFileSync(new URL('../entry/src/main/ets/components/GameControls.ets',import.meta.url),'utf8');
  const tree=compiler.createSourceFile('GameControls.ets',text,compiler.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>n.name?.getText(tree)==='GameControls');
  const build=component.members.find(n=>n.name?.getText(tree)==='build');
  const conditions=[];
  const visit=n=>{if(compiler.isIfStatement(n)&&n.thenStatement.getText(tree).includes('.id(this.touchGroupMarkerId_())'))conditions.push(n.expression.getText(tree));compiler.forEachChild(n,visit);};
  visit(build);assert.equal(conditions.length,1);
  assert.match(component.members.find(n=>n.name?.getText(tree)==='groupRevision').getText(tree),/@State/);
  const check=condition=>{
    const reads=[];let revision='';
    const subject={groupSchema:undefined,get groupRevision(){reads.push('revision');return revision;}};
    const evaluate=new Function('return ('+condition+');');
    assert.equal(evaluate.call(subject),false);assert.ok(reads.includes('revision'),'首次分支必须建立可观察依赖');
    subject.groupSchema={groups:[{}]};revision='2';assert.equal(evaluate.call(subject),true);
    subject.groupSchema=undefined;revision='';assert.equal(evaluate.call(subject),false);
  };
  check(conditions[0]);
  assert.throws(()=>check('this.groupSchema !== undefined'),/可观察依赖/,'撤回修复须重现marker永不挂载的依赖缺口');
}

/** 同名方案保存增加修订后卡片必须换键，未改内容保持键；实际三个布局分支都使用此入口。 */
{
  const text=fs.readFileSync(new URL('../entry/src/main/ets/pages/LayoutListPage.ets',import.meta.url),'utf8');
  const tree=compiler.createSourceFile('LayoutListPage.ets',text,compiler.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>n.name?.getText(tree)==='LayoutListPage');
  const key=component.members.find(n=>n.name?.getText(tree)==='profileCardKey_');assert.ok(key);
  const js=compiler.transpileModule('class Subject{'+key.getText(tree)+'}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};new Function('module',js)(module);const page=new module.exports();
  const profile={name:'同名组方案',profileRevision:3};page.getProfile=()=>profile;
  const before=page.profileCardKey_(profile.name);assert.equal(page.profileCardKey_(profile.name),before);
  profile.profileRevision++;assert.notEqual(page.profileCardKey_(profile.name),before,'复制组保存后不能复用旧缩略图');
  assert.equal((text.match(/\(name: string\) => this\.profileCardKey_\(name\)/g)||[]).length,3);
}
console.log('PASS device regressions: first-render group marker observes revision; same-name saved profile refreshes all catalog card layouts');

/** 固定命中根不能带按下scale；检查真正Builder属性链，而不是另造一份理想组件树。 */
{
  const text=fs.readFileSync(new URL('../entry/src/main/ets/components/GameControls.ets',import.meta.url),'utf8');
  const tree=compiler.createSourceFile('GameControls.ets',text,compiler.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>n.name?.getText(tree)==='ButtonItemView');
  let anchor;
  const visit=n=>{if(compiler.isCallExpression(n)&&compiler.isPropertyAccessExpression(n.expression)&&
    n.expression.name.text==='id'&&n.arguments[0]?.getText(tree)==='this.nodeId')anchor=n;compiler.forEachChild(n,visit);};
  visit(component);assert.ok(anchor);
  while(anchor.parent&&(compiler.isPropertyAccessExpression(anchor.parent)||compiler.isCallExpression(anchor.parent)))anchor=anchor.parent;
  const names=[];let current=anchor;
  while(compiler.isCallExpression(current)&&compiler.isPropertyAccessExpression(current.expression)){
    names.push(current.expression.name.text);current=current.expression.expression;
  }
  // ArkTS容器结束后的首个属性在AST中是独立width(...)调用，后续属性才是普通链。
  if(compiler.isCallExpression(current)&&compiler.isIdentifier(current.expression))names.push(current.expression.text);
  assert.ok(names.includes('id')&&names.includes('width')&&names.includes('height'),JSON.stringify({names,kind:compiler.SyntaxKind[current.kind],text:anchor.getText(tree).slice(0,220)}));
  assert.equal(names.includes('scale'),false,'组确认锚点不得随按下动画变形');
  assert.match(component.getText(tree),/\.scale\(/,'内部按下视觉仍须保留');

  const controls=tree.statements.find(n=>n.name?.getText(tree)==='GameControls');
  const method=controls.members.find(n=>n.name?.getText(tree)==='releaseControlInputs');
  const js=compiler.transpileModule('class Subject{'+method.getText(tree)+'}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};new Function('module',js)(module);const view=new module.exports();
  for(const name of ['buttonFingerIds','longPressTimers','arktsButtonOutputs','accessibilityToggleStates','toggleStates',
    'longPressFired','dragLookFinger','dragLookLastX','dragLookLastY','lastTapAt','btnVisMap'])view[name]=new Map();
  const own={pressed:true},other={pressed:true};view.btnVisMap.set('hidden',own);view.btnVisMap.set('other',other);
  assert.equal(view.releaseControlInputs('hidden'),true);assert.equal(own.pressed,false);assert.equal(other.pressed,true);
  assert.equal(view.releaseControlInputs('hidden'),false);
}
console.log('PASS fixed hit rectangle and native-only hidden visual retirement');

// 编辑一行动作必须保留其他行、操作顺序与重复目标；不能把show/hide压成一次toggle。
view.selectedIdx=view.controls.findIndex(item=>item.type===0&&!item.systemAction);
const first=view.controlGroups[0].id,second=view.controlGroups[1].id;
view.selectedItem().groupActions=[{phase:'press',operation:'show',targets:[first]},
  {phase:'press',operation:'hide',targets:[second]}, {phase:'press',operation:'toggle',targets:[first,first]},
  {phase:'click',operation:'show',targets:[second]}];
view.selectGroupPhase_('press');view.selectGroupAction_(1);view.setPhaseTargets_([second,first]);
assert.deepEqual(view.selectedItem().groupActions.map(a=>a.operation),['show','hide','toggle','show']);
assert.deepEqual(view.selectedItem().groupActions[2].targets,[first,first]);
view.selectGroupAction_(2);view.removePhaseTarget_(1);assert.deepEqual(view.selectedItem().groupActions[2].targets,[first]);
view.undo();assert.deepEqual(view.selectedItem().groupActions[2].targets,[first,first]);
view.selectGroupPhase_('press');view.selectGroupAction_(2);view.moveGroupAction_(-1);
assert.deepEqual(view.selectedItem().groupActions.map(a=>a.operation),['show','toggle','hide','show']);
view.selectedItem().phaseBindings=[{phase:'click',keys:[69],autoKeep:true}];
view.selectedItem().keys=[];view.selectedItem().keyOrMouse=0;
assert.match(view.selectedBindingLabel_(),/单击抬起.*E.*切换保持/);
view.selectedItem().phaseBindings=[];assert.equal(view.selectedBindingLabel_(),'触控组动作');
console.log('PASS ordered mixed group actions, duplicate target identity, per-row undo and truthful phase summary');

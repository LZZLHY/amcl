/** 提取生产schema条目构建循环与无障碍激活方法，验证层级绑定不泄漏原键位或游戏手势。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const load=makePureEtsLoader(),model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const groups=load('gamecontrol/src/main/ets/ControlGroups.ets'),secondary=load('gamecontrol/src/main/ets/SecondaryControlGroups.ets');
const geometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets'),gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const source=fs.readFileSync(new URL('../entry/src/main/ets/components/GameControls.ets',import.meta.url),'utf8');
const ast=compiler.createSourceFile('GameControls.ets',source,compiler.ScriptTarget.Latest,true),owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls');
const method=name=>owner.members.find(n=>n.name?.getText(ast)===name).getText(ast);
const send=owner.members.find(n=>n.name?.getText(ast)==='sendControlSchema');
const loop=send.body.statements.find(n=>compiler.isForOfStatement(n)&&n.expression.getText(ast)==='layout.entries').getText(ast);
function subject(loopText=loop,accessibility=method('activateButtonFromAccessibility')) {
  const code=compiler.transpileModule('class Subject{'+method('triggerCode')+'\n'+accessibility+
    '\nentries(profile,layout,swipeGroups){const controls=[];'+loopText+';return controls;}}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};new Function('module','effectiveKeys','GLFW_PRESS','GLFW_RELEASE',code)(module,model.effectiveKeys,1,0);return new module.exports();
}
const context=new geometry.RuntimeTouchContext();Object.assign(context,{valid:true,widthPx:1600,heightPx:720,density:2,key:'runtime-binding'});
const groupCompiler=makePureEtsLoader({'gamecontrol':{...model,...groups,...geometry}})('entry/src/main/ets/components/TouchGroupSchemaCompiler.ets');
for(const config of [{dragLook:true,trigger:'press'},{swipeGroup:'1',trigger:'press'},{trigger:'toggle'},{trigger:'longPress'}]){
  const original=model.getDefaultLayout(),key=original.controls.find(c=>c.keyOrMouse===69&&!c.systemAction);Object.assign(key,config);
  const result=secondary.createSecondaryControlGroup(original,'入口',key.id);assert.ok(result.profile,result.reason);
  const profile=result.profile,before=JSON.stringify(profile),runtime=geometry.projectRuntimeTouchLayout(profile,context,new gui.GameGuiState(),true,0,new Map());
  const view=subject(),entries=view.entries(profile,runtime,['1']),entry=entries.find(c=>c.id===key.id);
  assert.deepEqual([entry.keyOrMouse,entry.keys,entry.trigger,entry.dragLook,entry.swipeGroup],[0,[],0,false,0]);
  assert.equal(JSON.stringify(profile),before,'运行投影不能改写解绑备份');
  const schema=groupCompiler.compileTouchGroups(profile,runtime,entries);
  const emitted=[],intents=[];Object.assign(view,{groupSchema:schema,runtimeLayout:runtime,uiPublicationToken:'pub',groupRegistration:'producer',groupCommandSequence:0,
    pendingGroupCommands:new Map(),admitTouchAction_:()=>true,dispatchGroupIntent_:intent=>intents.push(intent),syncTouchGroups_(){},
    emitAccessibilityKeys:(keys,action)=>{emitted.push({keys,action});return true;},setPressed(){},reportGroupIssue_(){},
    accessibilityToggleStates:new Map(),toggleStates:new Map(),controlClient:{currentToken:()=>''}});
  view.activateButtonFromAccessibility(profile.controls.find(c=>c.id===key.id),'epoch');
  assert.equal(intents.length,1);assert.equal(intents[0].phase,0);assert.deepEqual(emitted,[]);
  view.groupSchema=undefined;view.activateButtonFromAccessibility(profile.controls.find(c=>c.id===key.id),'epoch');assert.deepEqual(emitted,[]);
}
// 撤回运行条目隔离会重新编译旧键位，证明正例确实依赖生产修复。
const withdrawn=subject(loop.replace('const secondary: boolean=item.secondaryAction!==undefined','const secondary: boolean=false'));
const p=secondary.createSecondaryControlGroup(model.getDefaultLayout(),'入口','key_E').profile;
const runtime=geometry.projectRuntimeTouchLayout(p,context,new gui.GameGuiState(),true,0,new Map());
assert.notEqual(withdrawn.entries(p,runtime,[]).find(c=>c.id==='key_E').keyOrMouse,0);
console.log('PASS actual secondary runtime binding: backup keys/trigger/dragLook/swipe isolated, accessibility invokes group phase, missing schema fails closed, withdrawal exposes old key');

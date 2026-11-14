/** 直接运行原生持久模型和生产schema编译器，验证二级绑定、删除、复制和旧格式兼容。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const load=makePureEtsLoader(),model=load('gamecontrol/src/main/ets/ControlLayout.ets');
const groups=load('gamecontrol/src/main/ets/ControlGroups.ets'),secondary=load('gamecontrol/src/main/ets/SecondaryControlGroups.ets');
const editing=load('gamecontrol/src/main/ets/ControlEditing.ets');
const source=model.getDefaultLayout(),before=JSON.stringify(source);
const created=secondary.createSecondaryControlGroup(source,'F类键');
assert.ok(created.profile,created.reason);let profile=created.profile;
assert.equal(JSON.stringify(source),before);assert.equal(profile.version,6);
assert.equal(secondary.secondaryGroupReturn(profile,created.groupId),undefined);
assert.equal(profile.controls.filter(c=>c.controlGroupId===created.groupId).length,0);
assert.deepEqual([secondary.secondaryGroupOpener(profile,created.groupId).baseWidth,
  secondary.secondaryGroupOpener(profile,created.groupId).baseHeight],[48,48]);
const f3=profile.controls.find(c=>c.keyOrMouse===292),oldF3=structuredClone(f3);
profile=secondary.moveSecondaryGroupMember(profile,f3.id,created.groupId);assert.ok(profile);
assert.equal(profile.controls.find(c=>c.id===f3.id).xPct,oldF3.xPct);
assert.equal(profile.controls.find(c=>c.id===f3.id).yPct,oldF3.yPct);
const originalE=profile.controls.find(c=>c.keyOrMouse===69&&c.systemAction===undefined);
// 绑定已有按钮不覆盖用户尺寸；只有主动选择展开键比例时才采用标准倍数。
originalE.baseWidth=63;originalE.baseHeight=41;originalE.itemScale=1.25;
const oldKeys=model.effectiveKeys(originalE);
profile=secondary.bindSecondaryControlGroup(profile,created.groupId,originalE.id);assert.ok(profile);
const opener=secondary.secondaryGroupOpener(profile,created.groupId);
assert.equal(opener.id,originalE.id);assert.deepEqual(model.effectiveKeys(opener),oldKeys);
assert.deepEqual([opener.baseWidth,opener.baseHeight,opener.itemScale],[63,41,1.25]);
assert.equal(model.hasControlAction(opener),true);assert.deepEqual(editing.controlEffectivePhases(opener),[]);
assert.equal(new editing.ControlEditCapabilities(opener).binding,false);
assert.equal(profile.controls.find(c=>c.id===created.controlId).secondaryAction,undefined);
let unbound=secondary.bindSecondaryControlGroup(profile,created.groupId);assert.ok(unbound);
assert.deepEqual(model.effectiveKeys(unbound.controls.find(c=>c.id===opener.id)),oldKeys);
assert.ok(model.validateAndNormalizeLayout(unbound),'未绑定组也可保存');
const added=secondary.addSecondaryGroupReturn(profile,created.groupId);assert.ok(added.profile);profile=added.profile;
assert.equal(secondary.addSecondaryGroupReturn(profile,created.groupId).profile.controls.length,profile.controls.length);
const copied=model.cloneLayoutWithFreshGroupIds(profile);
const newGroup=copied.controlGroups.find(g=>g.name==='F类键');
assert.notEqual(newGroup.id,created.groupId);
assert.ok(secondary.secondaryGroupOpener(copied,newGroup.id));assert.ok(secondary.secondaryGroupReturn(copied,newGroup.id));
assert.deepEqual(model.validateAndNormalizeLayout(JSON.parse(JSON.stringify(profile))),profile);
const plan=secondary.secondaryControlRemovalPlan(profile,[opener.id]);
assert.equal(plan.requiresConfirmation,true);assert.ok(plan.controlIds.includes(f3.id));assert.ok(plan.controlIds.includes(added.controlId));
assert.ok(plan.memberNames.includes('F3'),'确认使用可读键名，不展示生成ID代替键名');
const removed=secondary.removeSecondaryControls(profile,[opener.id]);assert.ok(removed);
for(const id of plan.controlIds)assert.equal(removed.controls.some(c=>c.id===id),false);
assert.equal(removed.controlGroups.some(g=>g.id===created.groupId),false);
const kept=model.removeLayoutControlGroup(profile,created.groupId,profile.defaultControlGroupId);assert.ok(kept);
assert.equal(kept.controls.some(c=>c.id===opener.id||c.id===added.controlId),false,'组删除不能残留无动作主按键');
assert.equal(kept.controls.find(c=>c.id===f3.id).controlGroupId,kept.defaultControlGroupId);
const single=secondary.removeSecondaryControls(profile,[f3.id]);assert.ok(single);
assert.ok(secondary.secondaryGroupOpener(single,created.groupId));assert.equal(secondary.secondaryControlRemovalPlan(profile,[f3.id]).requiresConfirmation,false);
const compound=structuredClone(profile),drawer=structuredClone(compound.controls.find(c=>c.id===f3.id));
drawer.id='test_compound';drawer.type=3;drawer.label='抽屉';
const childA=structuredClone(compound.controls.find(c=>c.id===f3.id)),childB=structuredClone(childA);
childA.id='child_a';childB.id='child_b';childB.locked=true;drawer.children=[childA,childB];compound.controls.push(drawer);
assert.ok(model.validateAndNormalizeLayout(compound));
assert.equal(secondary.secondaryControlRemovalPlan(compound,[drawer.id]).requiresConfirmation,true);
assert.ok(secondary.secondaryControlRemovalPlan(compound,[childA.id]).reason.includes('锁定'));
assert.equal(secondary.removeSecondaryControls(compound,[childA.id]),null);
assert.ok(secondary.removeSecondaryControls(compound,[drawer.id]));
const withSystem=structuredClone(profile),chat=withSystem.controls.find(c=>c.systemAction==='input');
chat.controlGroupId=created.groupId;chat.keys=[341,89];chat.keyOrMouse=341;
const savedChat=structuredClone(chat),systemPlan=secondary.secondaryControlRemovalPlan(withSystem,[opener.id]);
assert.ok(systemPlan.retainedSystemNames.length>0);assert.equal(systemPlan.controlIds.includes(chat.id),false);
const systemRemoved=secondary.removeSecondaryControls(withSystem,[opener.id]);assert.ok(systemRemoved);
const preservedChat=systemRemoved.controls.find(c=>c.id===chat.id);assert.equal(preservedChat.controlGroupId,systemRemoved.defaultControlGroupId);
preservedChat.controlGroupId=created.groupId;assert.deepEqual(preservedChat,savedChat,'系统成员保留原绑定与位置，不能删除后补默认');
const withHotbar=structuredClone(profile),hotbar=model.makeHotbarSelector(.2,.8,300,36);hotbar.id='group_hotbar';hotbar.controlGroupId=created.groupId;
withHotbar.controls.push(hotbar);withHotbar.hotbarAutoAdded=false;
const noHotbar=model.removeLayoutControlGroup(withHotbar,created.groupId);assert.ok(noHotbar);assert.equal(noHotbar.hotbarAutoAdded,true);
for(const mutate of [
 p=>p.version=5,
 p=>p.requiredCapabilities=p.requiredCapabilities.filter(c=>c!==groups.TOUCH_SECONDARY_GROUP_CAPABILITY),
 p=>p.controlGroups.find(g=>g.secondary).initialVisible=true,
 p=>p.controls.find(c=>c.id===opener.id).secondaryAction.groupId='missing',
 p=>p.controls.find(c=>c.id===opener.id).controlGroupId=created.groupId,
 p=>p.controls.find(c=>c.id===opener.id).hidden=true,
 p=>p.controls.find(c=>c.id===f3.id).groupActions=[{phase:'press',operation:'show',targets:[created.groupId]}]
]){const broken=structuredClone(profile);mutate(broken);assert.equal(model.validateAndNormalizeLayout(broken),null);}
const styled=structuredClone(profile);styled.controls.find(c=>c.id===f3.id).style={bg:'#00FFFFFF',fg:'#FF123456',opacity:.4,borderWidth:0,borderColor:'#FFABCDEF'};
const normalized=model.validateAndNormalizeLayout(styled);assert.ok(normalized);assert.deepEqual(normalized.controls.find(c=>c.id===f3.id).style,model.cloneItem(styled.controls.find(c=>c.id===f3.id)).style);
styled.controls.find(c=>c.id===f3.id).style.borderWidth=13;assert.equal(model.validateAndNormalizeLayout(styled),null);
const geometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets'),gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const context=new geometry.RuntimeTouchContext();Object.assign(context,{valid:true,widthPx:1440,heightPx:720,density:2,key:'secondary-test'});
const runtime=geometry.projectRuntimeTouchLayout(profile,context,new gui.GameGuiState(),true,0,new Map());
const compiler=makePureEtsLoader({'gamecontrol':{...model,...groups,...geometry}})('entry/src/main/ets/components/TouchGroupSchemaCompiler.ets');
const schema=compiler.compileTouchGroups(profile,runtime,runtime.entries.map(e=>({id:e.item.id})));
const slot=runtime.entries.findIndex(e=>e.item.id===opener.id),backSlot=runtime.entries.findIndex(e=>e.item.id===added.controlId);
assert.ok(slot>=0&&backSlot>=0,'纯功能键不能被空键热区过滤掉');
assert.deepEqual(schema.controls[slot].bindings[0].keys,[]);
assert.equal(schema.controls[slot].bindings[0].actions[0].operation,3);
assert.equal(schema.controls[backSlot].bindings[0].actions[0].operation,4);
assert.equal(schema.groups[schema.controls[slot].secondaryTarget].secondary,true);
assert.ok(model.validateAndNormalizeLayout(source));assert.equal(model.validateAndNormalizeLayout(source).version,3);
console.log('PASS secondary groups: v6 persistence, no implicit return, arbitrary coordinates, bind/unbind, schema-only actions, copy, cascade/delete-keep, old formats and strict rejection');

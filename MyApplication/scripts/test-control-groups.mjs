/** 直接回放生产组模型、复制/删除、候选补齐和序列化；不使用镜像算法作期望。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
const load = makePureEtsLoader();
const model = load('gamecontrol/src/main/ets/ControlLayout.ets');
const groups = load('gamecontrol/src/main/ets/ControlGroups.ets');
const nativeGroupContract=fs.readFileSync(new URL('../entry/src/main/cpp/platform/touch_group_state.h',import.meta.url),'utf8');
for(const [nativeName,value] of [['kMaxTouchGroups',groups.MAX_CONTROL_GROUPS],['kMaxTouchGroupTargets',groups.MAX_CONTROL_GROUP_TARGETS],
  ['kMaxTouchGroupOperations',groups.MAX_CONTROL_GROUP_OPERATIONS]]) {
  assert.equal(Number(new RegExp(nativeName+' = (\\d+)').exec(nativeGroupContract)?.[1]),value,'ArkTS/Native预算镜像必须一致');
}
const candidate = load('gamecontrol/src/main/ets/LayoutCandidate.ets');
const look = load('gamecontrol/src/main/ets/LookPreferences.ets');
const legacy = model.getDefaultLayout();
const original = JSON.stringify(legacy);
const base = model.enableLayoutControlGroups(legacy);
assert.equal(JSON.stringify(legacy), original);
assert.equal(base.version, 5);
assert.ok(model.validateAndNormalizeLayout(base));
assert.equal(model.validateAndNormalizeLayout(legacy).version, 3);
base.controlGroups.push({ id: 'tools', name: '工具', initialVisible: false });
const button = model.cloneItemWithFreshIds(base.controls.find(item => item.systemAction === undefined && item.type === 0), base.controls);
Object.assign(button, { label: '关闭工具', controlGroupId: 'tools', keyOrMouse: 0, keys: [],
  groupActions: [{ phase: 'press', operation: 'hide', targets: ['tools'] },
    { phase: 'click', operation: 'show', targets: [base.defaultControlGroupId] }] });
base.controls.push(button);
assert.equal(model.hasControlAction(button), true);
assert.deepEqual(model.effectiveKeys(button), []);
const normalized = model.validateAndNormalizeLayout(base);
assert.ok(normalized);
assert.ok(candidate.buildLayoutCandidate(base).profile);
const serialized = model.validateAndNormalizeLayout(JSON.parse(JSON.stringify(normalized)));
assert.deepEqual(serialized, normalized);
const cloned = model.cloneLayout(base);
cloned.controlGroups[1].name = '另一个名字';
cloned.controls.at(-1).groupActions[0].targets[0] = base.defaultControlGroupId;
assert.equal(base.controlGroups[1].name, '工具');
assert.equal(base.controls.at(-1).groupActions[0].targets[0], 'tools');
const copiedGroup = model.duplicateLayoutControlGroup(base, 'tools', '工具副本');
assert.ok(copiedGroup);
const copiedId = copiedGroup.controlGroups.at(-1).id;
assert.notEqual(copiedId, 'tools');
assert.deepEqual(copiedGroup.controls.at(-1).groupActions.map(a => a.targets), [[copiedId], [base.defaultControlGroupId]]);
const copiedProfile = model.cloneLayoutWithFreshGroupIds(base);
assert.ok(model.validateAndNormalizeLayout(copiedProfile));
assert.notEqual(copiedProfile.defaultControlGroupId, base.defaultControlGroupId);
assert.deepEqual(copiedProfile.controls.at(-1).groupActions.map(a => a.targets),
  [[copiedProfile.controlGroups[1].id], [copiedProfile.defaultControlGroupId]]);
const moved = model.removeLayoutControlGroup(base, 'tools', base.defaultControlGroupId);
assert.ok(moved);
assert.equal(moved.controls.at(-1).controlGroupId, base.defaultControlGroupId);
assert.equal(moved.controls.at(-1).groupActions.length, 1);
assert.equal(model.removeLayoutControlGroup(base, base.defaultControlGroupId), null);
const deleted = model.removeLayoutControlGroup(base, 'tools');
assert.equal(deleted.controls.some(c => c.id === button.id), false);
assert.equal(base.controls.some(c => c.id === button.id), true);

/** 每个非法例修改一项生产约束，必须整份拒绝，不能静默降写或部分保存。 */
for (const mutate of [
  p => { p.version = 4; },
  p => { p.controlGroups.push({ ...p.controlGroups[0] }); },
  p => { p.controlGroups[1].futureBehavior = true; },
  p => { p.controls.at(-1).groupActions[0].futureBehavior = true; },
  p => { p.controls.at(-1).groupActions[0].targets = ['missing']; },
  p => { p.controls.at(-1).groupActions[0].targets = Array(129).fill('tools'); },
  p => { p.controls.at(-1).groupActions[0].operation = 'script'; },
  p => { p.controls.at(-1).controlGroupId = 'missing'; },
  p => { p.requiredCapabilities.push('future-protocol'); },
  p => { p.controls.find(c => c.systemAction === 'visibility').controlGroupId = 'tools'; },
]) {
  const bad = structuredClone(base); mutate(bad);
  assert.equal(model.validateAndNormalizeLayout(bad), null, JSON.stringify(bad.controlGroups));
}
const phases = model.cloneLayout(base);
phases.requiredCapabilities.push(groups.TOUCH_PHASE_CAPABILITY);
phases.controls.at(-1).phaseBindings = [
  { phase: 'press', keys: [87], autoKeep: false },
  { phase: 'click', keys: [69], autoKeep: true }];
assert.ok(model.validateAndNormalizeLayout(phases));
phases.requiredCapabilities.pop();
assert.equal(model.validateAndNormalizeLayout(phases), null);
const both = model.cloneLayout(base);
both.lookPolicies = look.splitLegacyLookPolicy({ sensitivity: 1, invertY: false, smoothing: 0.6, acceleration: 0 });
assert.equal(model.validateAndNormalizeLayout(both).version, 5);
assert.equal(model.legacyLookCompatibleLayout(both), null);
console.log('PASS control groups: v3 compatibility, v5 graph/roundtrip, lookPolicies, clone isolation, remapping, deletion and rejection');

const importer=load('gamecontrol/src/main/ets/ExternalLayoutImporter.ets');
const source={controllerVersion:21,viewGroups:[
  {id:'base',name:'基础',visibility:'VISIBLE',viewData:{buttonList:[
    {text:'工具',baseInfo:{},event:{pressEvent:{bindViewGroup:['tools','extra']}}},
    {text:'W后单击切组',baseInfo:{},event:{pressEvent:{outputKeycodes:[17]},clickEvent:{bindViewGroup:['tools']}}}
  ]}},
  {id:'tools',name:'工具',visibility:'INVISIBLE',viewData:{buttonList:[
    {text:'关闭',baseInfo:{},event:{pressEvent:{bindViewGroup:['tools']}}}
  ]}},
  {id:'extra',name:'工具',visibility:'INVISIBLE',viewData:{buttonList:[]}}
]};
const imported=importer.analyzeExternalLayout(JSON.stringify(source),'FCL groups');
assert.ok(imported.profile,imported.reason);
assert.equal(imported.profile.version,5);
assert.equal(imported.profile.controlGroups.length,4);
assert.equal(imported.profile.controlGroups[2].initialVisible,false);
assert.equal(imported.profile.controls[2].hidden,undefined,'组隐藏不能压到成员自身 hidden');
assert.deepEqual(imported.profile.controls[0].keys,[]);
assert.equal(imported.profile.controls[0].keyOrMouse,0);
assert.deepEqual(imported.profile.controls[0].groupActions[0].targets,['fcl_group_1','fcl_group_2']);
assert.deepEqual(imported.profile.controls[1].phaseBindings[0].keys,[87]);
assert.equal(imported.profile.controls[1].groupActions[0].phase,'click');
assert.ok(imported.warnings.some(text=>text.includes('懒加载')));
for(const mutate of [
  p=>{p.controllerVersion=22;},
  p=>{p.viewGroups[1].id='base';},
  p=>{p.viewGroups[0].viewData.buttonList[0].event.pressEvent.bindViewGroup=['missing'];},
  p=>{p.viewGroups[0].viewData.buttonList[0].event.pressEvent.autoClick=true;},
  p=>{p.viewGroups[1].visibility='SOMETHING_NEW';},
  p=>{p.viewGroups[0].viewData.buttonList=Array(253).fill(p.viewGroups[0].viewData.buttonList[0]);}
]) {const bad=structuredClone(source);mutate(bad);assert.equal(importer.analyzeExternalLayout(JSON.stringify(bad),'bad').profile,null);}
const geometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const context=new geometry.RuntimeTouchContext();Object.assign(context,{valid:true,widthPx:1440,heightPx:720,density:2,key:'test'});
const runtime=geometry.projectRuntimeTouchLayout(imported.profile,context,new gui.GameGuiState(),true,0,new Map());
assert.equal(runtime.entries.length,3,'隐藏组也必须进入静态几何');
const compilerLoad=makePureEtsLoader({'gamecontrol':{...model,...groups,...geometry}});
const compiler=compilerLoad('entry/src/main/ets/components/TouchGroupSchemaCompiler.ets');
const schema=compiler.compileTouchGroups(imported.profile,runtime,runtime.entries.map(e=>({id:e.item.id})),false);
assert.equal(schema.controls.length,3);
assert.equal(schema.controls[0].phases,true);
assert.deepEqual(schema.controls[0].bindings[0].actions,[{target:2,operation:0},{target:3,operation:0}]);
assert.deepEqual(schema.controls[1].bindings[0].keys,[87]);
assert.equal(schema.controls[1].bindings[2].actions.length,1);
assert.equal(schema.groups[2].initialVisible,false);
assert.equal(compiler.compileTouchGroups(legacy,runtime,[]),undefined);
assert.equal('trial' in schema,false);assert.equal('editorSession' in schema,false);
console.log('PASS FCL groups: direct two-pass references, pure buttons, four phases, complete static geometry/compiler and unsupported refusal');

/** 执行原ABI检查器和真实跨语言源文件：撤回任一新接口/关键字段的keep必须真实失败。 */
{
  const root=path.resolve(import.meta.dirname,'..'),scope=createHostTestScope('touch-groups-abi-');
  const names=['scripts/check-napi-obfuscation.mjs','entry/obfuscation-rules.txt',
    'entry/src/main/cpp/napi/napi_input.cpp','entry/src/main/cpp/napi/napi_touch_groups.inc'];
  for(const name of names){const target=path.join(scope.directory,name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(path.join(root,name),target);}
  const rulePath=path.join(scope.directory,names[1]),checkPath=path.join(scope.directory,names[0]);
  const rules=fs.readFileSync(rulePath,'utf8'),checker=fs.readFileSync(checkPath,'utf8');
  const run=()=>{const value=spawnSync(process.execPath,[checkPath,'--json'],{encoding:'utf8',timeout:20000});
    assert.ifError(value.error);return {code:value.status,report:JSON.parse(value.stdout)};};
  assert.equal(run().code,0);
  for(const name of ['restoreTouchGroups','groups','initialVisible','epochs','revision']){
    fs.writeFileSync(rulePath,rules.replace(new RegExp('^'+name+'\\r?$','gm'),''));
    const result=run();assert.equal(result.code,1);assert.ok(result.report.missing.includes(name),'实际ABI检查须识别 '+name);
  }
  // 原先只扫.cpp/.h会漏过整个.inc。该撤回版本真实放行缺groups字段，证明新负例针对覆盖缺口。
  fs.writeFileSync(rulePath,rules.replace(/^groups\r?$/gm,''));
  assert.ok(checker.includes('|hpp|inc)'));
  fs.writeFileSync(checkPath,checker.replace('|hpp|inc)','|hpp)'));
  assert.equal(run().code,0,'撤回.inc扫描重现静默放行');
  fs.writeFileSync(rulePath,rules);fs.writeFileSync(checkPath,checker);assert.equal(run().code,0);
  console.log('PASS actual NAPI ABI gate: group exports and .inc wire fields, removed-keep rejection, withdrawn .inc scan reproduces gap');
}

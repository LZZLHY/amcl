/**
 * 来源政策迁移回归：执行真实模型、LayoutStore和会话Runtime，只桩Preferences/Native边缘。
 * 验证旧格式不被静默拆分、用户显式复制原手感、逐域真实回执和失败/停止/端口变更边界。
 * 本测试不能替代真实NAPI、三ABI或设备体验验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { fixture as gameLayoutFixture } from './lib/game-layout-fixture.mjs';

/** 每例隔离进程HAR缓存，真实保存事务与定义投递均照生产运行。 */
function fixture() {
  const env=environment(),layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const policy=env.load('gamecontrol/src/main/ets/LookPreferences.ets');
  const {LayoutStore}=env.load('gamecontrol/src/main/ets/LayoutStore.ets');
  const {InputConfigurationRuntime}=env.load('gamecontrol/src/main/ets/InputConfigurationRuntime.ets');
  const native=env.load('gamecontrol/src/main/ets/InputConfigurationNativePort.ets');
  const p=layout.getDefaultLayout();p.name='source-policy';p.isPreset=false;p.profileId='source-policy';p.profileRevision=1;
  const store=new LayoutStore();store.profiles=[p];store.activeName=p.name;store._ready=true;
  const values=new Map();let fail=false;
  store.pref={get:async(k,v)=>values.get(k)??v,put:async(k,v)=>values.set(k,v),putSync:(k,v)=>values.set(k,v),
    flush:async()=>{if(fail){fail=false;throw Error('save-failure');}}};
  return {layout,policy,store,native,Runtime:InputConfigurationRuntime,fail:()=>{fail=true;}};
}

/** 完整Native值替身只控制写入和查询故障，Runtime仍自行生成operation/缓存/回执。 */
async function acceptedWriteThenLostConfirmation(kind) {
  const f=fixture(),actual=new Map(),calls=[];let throwBinding=false,arm=false;
  const sink={applyLookConfiguration:c=>{
    calls.push('global');for(const source of ['physical','touch','gamepad','external'])actual.set(source,{...c});
    if(arm&&kind!=='source')throwBinding=true;return true;
  },applySourceLookConfiguration:(source,c)=>{
    calls.push(source);actual.set(source,{...c});if(arm&&kind==='source'&&source==='touch')throwBinding=true;return true;
  }};
  const port={binding:()=>{
    if(throwBinding){throwBinding=false;throw Error('post-write binding unavailable');}
    return new f.native.InputConfigurationNativeBinding(1,sink);
  }};
  const runtime=new f.Runtime(port);runtime.start(f.store,303);
  let p=f.store.getActiveProfile();
  if(kind==='global-only') {
    p.lookSensitivity=2;arm=true;await f.store.saveProfile(p);assert.equal(actual.get('touch').sensitivity,2);
    arm=false;p=f.store.getActiveProfile();p.lookSensitivity=1;await f.store.saveProfile(p);
    assert.equal(actual.get('touch').sensitivity,1,'全来源旧缓存也不能遮住已写但未确认的新值');
  } else {
    p.version=4;p.lookPolicies=f.policy.splitLegacyLookPolicy({sensitivity:1,invertY:false,smoothing:.6,acceleration:0});
    p.lookPolicies.touch.sensitivity=2;await f.store.saveProfile(p);assert.equal(actual.get('touch').sensitivity,2);
    p=f.store.getActiveProfile();arm=true;
    if(kind==='global')p.lookPolicies.mode='legacy-global';else p.lookPolicies.touch.sensitivity=1;
    await f.store.saveProfile(p);assert.equal(actual.get('touch').sensitivity,1);
    assert.equal(runtime.snapshot().activationState,'Pending');arm=false;p=f.store.getActiveProfile();
    p.lookPolicies.mode='independent';p.lookPolicies.touch.sensitivity=2;await f.store.saveProfile(p);
    assert.equal(actual.get('touch').sensitivity,2,'原成功缓存不能盖掉实际写入但确认丢失的值');
  }
  assert.equal(runtime.snapshot().activationState,'Applied');runtime.stop();
}

{
  const f=fixture(),old=f.store.getActiveProfile();old.lookSensitivity=2;old.invertY=true;old.lookSmoothing=.3;old.lookAccel=.4;
  const normalized=f.layout.validateAndNormalizeLayout(old);
  assert.equal(normalized.version,3);assert.equal(normalized.lookPolicies,undefined);
  const fields={sensitivity:2,invertY:true,smoothing:.3,acceleration:.4};
  const preferences=f.policy.splitLegacyLookPolicy(fields);
  for(const source of ['physical','touch','gamepad','external'])assert.deepEqual(preferences[source],fields);
  preferences.touch.sensitivity=1;assert.equal(preferences.physical.sensitivity,2);assert.equal(preferences.legacy.sensitivity,2);
  old.version=4;old.lookPolicies=preferences;const checked=f.layout.validateAndNormalizeLayout(old);
  assert.equal(checked.version,4);assert.deepEqual(checked.lookPolicies,preferences);
  const invalids=[{...preferences,version:2},{...preferences,touch:{sensitivity:1}}, {...preferences,physical:{...fields,smoothing:NaN}},
    {...preferences,newSource:fields},{...preferences,touch:{...fields,unknownPolicy:true}}];
  for(const invalid of invalids)assert.equal(f.layout.validateAndNormalizeLayout({...old,lookPolicies:invalid}),null);
  assert.equal(f.layout.validateAndNormalizeLayout({...old,version:3}),null,'旧阅读器格式不能误标独立政策');
  checked.controls[0].label='迁移后的编辑';
  const compatible=f.layout.legacyLookCompatibleLayout(checked);
  assert.equal(compatible.version,3);assert.equal(compatible.lookPolicies,undefined);
  assert.equal(compatible.controls[0].label,'迁移后的编辑');assert.equal(compatible.profileId,checked.profileId);
  assert.deepEqual([compatible.lookSensitivity,compatible.invertY,compatible.lookSmoothing,compatible.lookAccel],[2,true,.3,.4]);
  assert.equal(checked.lookPolicies.touch.sensitivity,1,'兼容导出不改原独立政策');
  console.log('PASS old v3 retains global values; explicit v4 copies all sources, strict format and independent deep copies');
}

{
  // 运行完整生产编辑器的全部非Builder方法和原字段；仅真正UI子组件/Kit呈现边缘不装载。
  // 这里没有复制拆分/改值/撤销/组装算法，负控可直接替换生产函数再执行同一轨迹。
  const gc={},env=environment({imports:{gamecontrol:gc,'./KeyPickerSheet':{},'./AppIcon':{},'./TouchOptionsEditor':{}}});
  for(const name of ['GlfwKeys','ControlLayout','LookPreferences','TouchPreferences','GameGuiGeometry','LayoutEditSession','TouchActionBindings'])
    Object.assign(gc,env.load('gamecontrol/src/main/ets/'+name+'.ets'));
  gc.getLayoutStore=()=>({});
  const {InputSettingsEditor}=env.load('entry/src/main/ets/components/InputSettingsEditor.ets',true);
  const editor=new InputSettingsEditor(),old=gc.getDefaultLayout();old.isPreset=false;old.profileId='editor-look';old.profileRevision=1;
  old.lookSensitivity=2;old.lookSmoothing=.3;old.lookAccel=.4;editor.original=gc.cloneLayout(old);editor.session.open(old);editor.load_(old);
  assert.equal(editor.buildProfile().version,3);
  editor.setIndependentLook(true);assert.equal(editor.buildProfile().version,4);
  editor.selectLookSource('gamepad');assert.equal(editor.sensVal,200);
  editor.pushUndo();const parameters=editor.editorLookParameters();parameters.sensitivity=1.5;editor.updateEditorLook(parameters);
  const draft=editor.buildProfile();assert.equal(draft.lookPolicies.gamepad.sensitivity,1.5);
  assert.equal(draft.lookPolicies.touch.sensitivity,2);assert.equal(draft.lookPolicies.legacy.sensitivity,2);
  editor.undo_();assert.equal(editor.buildProfile().lookPolicies.gamepad.sensitivity,2);
  editor.setIndependentLook(false);assert.equal(editor.buildProfile().lookPolicies.mode,'legacy-global');
  editor.undo_();assert.equal(editor.buildProfile().lookPolicies.mode,'independent');
  // 两来源同一个滑条名也必须有独立撤销边界；撤销手柄不能顺带撤回先前触控修改。
  editor.selectLookSource('touch');editor.beginSliderUndo('lookSensitivity');
  let value=editor.editorLookParameters();value.sensitivity=1.5;editor.updateEditorLook(value);
  editor.selectLookSource('gamepad');editor.beginSliderUndo('lookSensitivity');
  value=editor.editorLookParameters();value.sensitivity=3;editor.updateEditorLook(value);editor.undo_();
  assert.equal(editor.buildProfile().lookPolicies.touch.sensitivity,1.5);
  assert.equal(editor.buildProfile().lookPolicies.gamepad.sensitivity,2);
  console.log('PASS full production editor old load/explicit split/source selection/save assembly/undo/compat restore');
}

{
  const first=fixture(),later=fixture(),actual=[],calls=[];let armed=false,handoff=false,runtime;
  let profile=later.store.getActiveProfile();profile.lookSensitivity=3;await later.store.saveProfile(profile);
  const sink={applyLookConfiguration:c=>{
    actual[0]=c.sensitivity;calls.push(c.sensitivity);if(armed&&c.sensitivity===2){armed=false;handoff=true;}return true;
  }};
  const port={binding:()=>{
    if(handoff){handoff=false;runtime.stop();runtime.start(later.store,505);}
    return new first.native.InputConfigurationNativeBinding(1,sink);
  }};
  runtime=new first.Runtime(port);runtime.start(first.store,404);armed=true;
  profile=first.store.getActiveProfile();profile.lookSensitivity=2;await first.store.saveProfile(profile);
  assert.equal(runtime.snapshot().sessionId,505);assert.equal(actual[0],3);
  const before=calls.length;profile=later.store.getActiveProfile();profile.lookSensitivity=2;await later.store.saveProfile(profile);
  assert.equal(calls.length,before+1);assert.equal(actual[0],2,'端口查询同步换会话后旧续体不能盖新签名');
  runtime.stop();console.log('PASS actual post-binding query stop/rebind cannot stamp old completion into the new session');
}

{
  const f=fixture(),calls=[],global=[];let rejectTouch=true;
  f.native.setControlNativeSink({applyLookConfiguration:c=>{global.push({...c});return true;},
    applySourceLookConfiguration:(source,c)=>{calls.push([source,{...c}]);return source!=='touch'||!rejectTouch;}});
  const runtime=new f.Runtime();runtime.start(f.store,101);assert.equal(global.length,1);
  const p=f.store.getActiveProfile();p.version=4;p.lookPolicies=f.policy.splitLegacyLookPolicy({sensitivity:1,invertY:false,smoothing:.6,acceleration:0});
  assert.equal(await f.store.saveProfile(p),true);
  let states=runtime.status();assert.equal(states.length,4);assert.equal(states.filter(s=>s.pending).length,1);
  assert.equal(states.find(s=>s.name==='look-touch').pending,true);assert.equal(runtime.snapshot().activationState,'Pending');
  const before=calls.length;rejectTouch=false;runtime.reconcile();assert.equal(calls.length,before+1,'只重试失败域');
  assert.equal(calls.at(-1)[0],'touch');assert.equal(runtime.snapshot().activationState,'Applied');
  const next=f.store.getActiveProfile();next.lookPolicies.gamepad.sensitivity=2;await f.store.saveProfile(next);
  assert.equal(calls.length,before+2);assert.equal(calls.at(-1)[0],'gamepad');assert.equal(global.length,1);
  const stable=calls.length,revision=runtime.status()[0].appliedRevision;
  f.fail();const failed=f.store.getActiveProfile();failed.lookPolicies.physical.sensitivity=3;
  await assert.rejects(f.store.saveProfile(failed),/save-failure/);assert.equal(calls.length,stable);assert.equal(runtime.status()[0].appliedRevision,revision);
  f.native.setControlNativeSink(null);runtime.reconcile();assert.ok(runtime.status().every(s=>s.pending));
  runtime.stop();assert.deepEqual(runtime.status(),[]);
  console.log('PASS actual save/partial independent receipts/retry unchanged domains; save failure, absent port and original stop');
}

{
  const f=fixture(),calls=[];
  f.native.setControlNativeSink({applyLookConfiguration:()=>true});
  const runtime=new f.Runtime();runtime.start(f.store,202);
  const p=f.store.getActiveProfile();p.version=4;p.lookPolicies=f.policy.splitLegacyLookPolicy({sensitivity:1,invertY:false,smoothing:.6,acceleration:0});
  await f.store.saveProfile(p);assert.ok(runtime.status().every(s=>s.pending));
  f.native.setControlNativeSink({applyLookConfiguration:()=>{throw Error('must not fallback');},
    applySourceLookConfiguration:(s,c)=>{calls.push(s);if(s==='physical')runtime.stop();return true;}});
  runtime.reconcile();assert.deepEqual(calls,['physical']);assert.deepEqual(runtime.status(),[]);
  console.log('PASS missing single-source port stays pending, no global fallback; synchronous stop fences remaining source writes');
}

for(const kind of ['global','source','global-only'])await acceptedWriteThenLostConfirmation(kind);
console.log('PASS global/single-source Native accepted but post-binding throws: restoring old desired reasserts actual values');

{
  // 真正entry适配类逐字转译，验证HAR持久名不会当UI序号传给Native枚举。
  const source=fs.readFileSync(new URL('../entry/src/main/ets/runtime/ProcessRuntime.ets',import.meta.url),'utf8');
  const ast=compiler.createSourceFile('ProcessRuntime.ets',source,compiler.ScriptTarget.Latest,true);
  const nativeSink=ast.statements.find(node=>node.name?.getText(ast)==='EntryControlNativeSink');assert.ok(nativeSink);
  const result=compiler.transpileModule(nativeSink.getText(ast)+'\nmodule.exports=EntryControlNativeSink;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((result.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const calls=[],module={exports:{}};
  new Function('module','testNapi',result.outputText)(module,{applySourceLookConfiguration:(...values)=>{calls.push(values);return true;}});
  const sink=new module.exports(),parameters={sensitivity:2,invertY:true,smoothing:.3,acceleration:.4};
  for(const source of ['physical','touch','gamepad','external'])assert.equal(sink.applySourceLookConfiguration(source,parameters),true);
  assert.deepEqual(calls.map(call=>call[0]),[3,1,2,0]);
  assert.ok(calls.every(call=>JSON.stringify(call.slice(1))===JSON.stringify([2,true,.3,.4])));
  console.log('PASS actual Entry Native sink maps physical3/touch1/gamepad2/untagged compat0 with complete parameter group');
}

{
  // 真实父子启动快照、净修改journal、冲突合并和持久确认；只用既有明确文件/SDK边缘。
  const f=fixture(),data=gameLayoutFixture();
  try {
    const p=f.store.getActiveProfile();p.version=4;
    p.lookPolicies=f.policy.splitLegacyLookPolicy({sensitivity:2,invertY:true,smoothing:.3,acceleration:.4});
    data.ownerData.set('control_layout',new Map([['profiles',JSON.stringify([p])],['active_profile',p.name]]));
    await data.owner.store.init(data.disk.context);await data.launchV2();
    assert.deepEqual(data.child.store.getActiveProfile().lookPolicies,p.lookPolicies);
    assert.equal(data.child.xmlOpens(),0,'child不得因新政策回写父XML');
    const child=data.child.store.getActiveProfile();child.lookPolicies.touch.sensitivity=1;
    child.controls[0].label='游戏中的后续编辑';await data.child.store.saveProfile(child);
    data.state.lock=0;data.state.failOwnerFlushCount=1;
    await assert.rejects(data.owner.journal.importPending(data.disk.context),/owner disk failure/);
    assert.equal(data.owner.store.getActiveProfile().lookPolicies.touch.sensitivity,2);
    assert.equal((await data.owner.journal.importPending(data.disk.context)).imported,1);
    const merged=data.owner.store.getActiveProfile();assert.equal(merged.lookPolicies.touch.sensitivity,1);
    assert.equal(merged.lookPolicies.physical.sensitivity,2);assert.equal(merged.controls[0].label,'游戏中的后续编辑');
    assert.equal((await data.owner.journal.importPending(data.disk.context)).imported,0,'同一净修改确认后不重导');
    const full=JSON.parse(data.owner.store.exportToJson(merged.name));assert.equal(full.version,4);
    const review=data.owner.store.analyzeImport(JSON.stringify(full));assert.equal(review.ok,true);assert.equal(review.legacy,false);
    const old=JSON.parse(data.owner.store.exportToJson(merged.name,true));assert.equal(old.version,3);
    assert.equal(old.controls[0].label,'游戏中的后续编辑');assert.equal(old.lookSensitivity,2);
    assert.deepEqual(data.owner.store.getActiveProfile().lookPolicies,merged.lookPolicies);
    console.log('PASS real V2 snapshot/child journal/owner flush failure/retry/idempotency and current-edit-preserving v3/v4 exports');
  } finally { data.disk.close(); }
}

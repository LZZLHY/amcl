/** 执行生产Store/Runtime/Delivery/纯投影；只注入存储与Native边界，不复制激活算法。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {PROJECT_ROOT,assertExternalOutputPath,workspacePath} from './lib/workspace-paths.mjs';
import {environment} from './lib/ets-runtime-fixture.mjs';
const started=new Date().toISOString(),evidence={layer:'actual ArkTS Store/Runtime/GC/Controller; Native and SDK boundaries only, not device acceptance',scenes:[],negatives:[]};
const CONTROLS='entry/src/main/ets/components/GameControls.ets';
const DELIVERY='gamecontrol/src/main/ets/InputConfiguration.ets';
const RUNTIME='gamecontrol/src/main/ets/InputConfigurationRuntime.ets';
// AST/撤回锚点统一换行，不写回文件；正式 source SHA 仍使用下面读取的原始字节。
const read=relative=>fs.readFileSync(path.join(PROJECT_ROOT,relative),'utf8').replaceAll('\r\n','\n');
/** 撤回只改内存源码，锚点必须唯一，不能拿编译/导入失败冒充业务反控。 */
function replaceOnce(source,from,to){assert.equal(source.split(from).length-1,1,'唯一撤回锚点');return source.replace(from,to);}
function fixture(options={}){
  const env=environment(options),layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const {LayoutStore}=env.load('gamecontrol/src/main/ets/LayoutStore.ets');
  const {InputConfigurationRuntime}=env.load('gamecontrol/src/main/ets/InputConfigurationRuntime.ets');
  const model=env.load('gamecontrol/src/main/ets/InputConfiguration.ets');
  const port=env.load('gamecontrol/src/main/ets/InputConfigurationNativePort.ets');
  const store=new LayoutStore(),profile=layout.getDefaultLayout();
  Object.assign(profile,{name:'owned-policy',isPreset:false,profileId:'saved-policy',profileRevision:1});
  store.profiles=[profile];store.activeName=profile.name;store._ready=true;
  const data=new Map();let failSave=false;
  store.pref={get:async(k,f)=>data.get(k)??f,put:async(k,v)=>data.set(k,v),putSync:(k,v)=>data.set(k,v),
    flush:async()=>{if(failSave){failSave=false;throw Error('disk failure');}}};
  return {env,store,InputConfigurationRuntime,model,port,layout,data,failSave:()=>failSave=true};
}
{
  // 控件可先于仓库init续体完成而挂接；报告资格要在原会话准备时建立，不能订阅
  // undefined后永远沉默，也不能等保存时从global current偷取后来provider。
  const f=fixture(),calls=[];
  f.port.setControlNativeSink({applyLookConfiguration:config=>{calls.push(config);return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.prepareStatus(f.store,0);
  const snapshots=[];const subscription=f.store.addInputPolicyStatusListener(value=>snapshots.push(value));
  assert.ok(subscription);assert.equal(calls.length,0,'Preparing报告不读默认定义或应用Native');
  const generation=snapshots.at(-1).generation;
  assert.equal(runtime.bindSession(711),true);assert.equal(snapshots.at(-1).sessionId,711);
  runtime.start(f.store,711);
  assert.equal(runtime.snapshot().generation,generation,'加载就绪沿原准备代，不清掉早到观察');
  const changed=f.store.getActiveProfile();changed.lookSensitivity=1.5;await f.store.saveProfile(changed);
  assert.equal(snapshots.at(-1).definitionState,'Saved');assert.equal(snapshots.at(-1).profileRevision,2);
  assert.equal(snapshots.at(-1).sessionId,711);assert.equal(calls.length,2);
  runtime.stop();assert.equal(snapshots.at(-1).identityStage,'Retired');
  console.log('PASS report qualification before layout await, zero Native during prepare, original subscriber survives actual activation');
}
{
  const f=fixture();f.port.setControlNativeSink({applyLookConfiguration:()=>true});
  const runtime=new f.InputConfigurationRuntime();runtime.prepareStatus(f.store,0);
  let stopOnBind=false;
  f.store.addInputPolicyStatusListener(value=>{if(stopOnBind&&value.sessionId===712)runtime.stop();});
  stopOnBind=true;
  assert.equal(runtime.bindSession(712),false,'同步观察停止不能让原bind冒成功');
  assert.equal(f.store.inputPolicyStatus(),undefined);
  console.log('PASS synchronous preparing observer retirement cannot claim a completed session binding');
}
{
  const f=fixture(),calls=[];f.port.setControlNativeSink({applyLookConfiguration:c=>{calls.push({...c});return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,0);
  const preparing=runtime.snapshot(),operation=preparing.operationId;
  assert.equal(preparing.sessionId,0);assert.equal(preparing.identityStage,'Preparing');
  assert.match(f.model.inputPolicyStatusMessage(preparing),/等待游戏会话身份确认/);
  const before=calls.length;assert.equal(runtime.bindSession(1001),true);assert.equal(runtime.bindSession(1001),true);
  assert.equal(runtime.bindSession(1002),false);assert.equal(runtime.snapshot().operationId,operation);assert.equal(calls.length,before);
  const snapshots=[];f.store.addInputPolicyStatusListener(s=>snapshots.push(s));
  const read=f.store.inputPolicyStatus();read.profileId='corrupt';assert.equal(runtime.snapshot().profileId,'saved-policy');
  for(let i=0;i<4;i++){runtime.snapshot();f.store.inputPolicyStatus();}assert.equal(calls.length,before,'纯观察不能重试/应用');
  runtime.stop();assert.equal(snapshots.at(-1).sessionId,1001);assert.equal(snapshots.at(-1).identityStage,'Retired');
  assert.equal(runtime.bindSession(1001),false);assert.equal(f.store.inputPolicyStatus(),undefined);
  console.log('PASS Preparing0 binds original generation/op once, reads inert/deep copy and original Retired report');
}
{
  const f=fixture(),calls=[];let accepting=true;
  f.port.setControlNativeSink({applyLookConfiguration:c=>{calls.push({...c});return accepting;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,2001);
  const old=runtime.snapshot();f.failSave();const failed=f.store.getActiveProfile();failed.lookSensitivity=2;
  await assert.rejects(f.store.saveProfile(failed),/disk failure/);assert.equal(runtime.snapshot().operationId,old.operationId);
  accepting=false;const changed=f.store.getActiveProfile();changed.lookSensitivity=2;assert.equal(await f.store.saveProfile(changed),true);
  const saved=runtime.snapshot();assert.equal(saved.profileId,old.profileId);assert.equal(saved.profileRevision,2);assert.equal(saved.definitionState,'Saved');
  const look=saved.domains.find(s=>s.name==='native-look');assert.equal(look.pending,true);assert.equal(look.stage,'Waiting');assert.equal(look.reason,'NotApplied');
  assert.equal(look.desiredProfileRevision,2);assert.equal(look.appliedProfileRevision,1);assert.notEqual(saved.operationId,old.operationId);
  assert.equal(saved.look.mode,'LegacyGlobalLookCompat');assert.equal(saved.look.parameters.sensitivity,2);
  assert.ok(saved.look.exceptions.includes('PhysicalRelativeSmoothingAlpha1'));
  accepting=true;runtime.reconcile();assert.equal(runtime.snapshot().domains[0].pending,false);
  assert.equal(runtime.snapshot().operationId,saved.operationId,'重试不新分配激活操作');runtime.stop();
  console.log('PASS saved stable identity/revision survives unknown false; real Waiting then same-op Applied, no save-failure publication');
}
{
  const f=fixture({commons:{AppLogger:{warn(){throw Error('observer logger failure');},error(){},info(){}}}}),calls=[];
  f.port.setControlNativeSink({applyLookConfiguration:c=>{calls.push(c.sensitivity);return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,3001);
  let stage='Waiting',reason='ContactsEnding';
  f.store.addInputConfigurationListener(()=>false,'touch-controls',()=>Object.assign(new f.model.InputConfigurationProgress(),
    {stage,reason,operationId:'touch-op-original',candidateId:'candidate-original',token:''}));
  f.store.addInputPolicyStatusListener(()=>{throw Error('visual subscriber failure');});
  const changed=f.store.getActiveProfile();changed.lookSensitivity=2;assert.equal(await f.store.saveProfile(changed),true,
    'consumer/log/只读观察失败不能回滚已确认保存');
  let report=runtime.snapshot();assert.equal(report.domains.find(s=>s.name==='native-look').pending,false);
  assert.match(f.model.inputPolicyStatusMessage(report),/方案已保存.*等待旧接触结束/);
  const op=report.operationId;stage='Waiting';reason='UiConfirmation';runtime.reconcile();report=runtime.snapshot();
  assert.equal(report.operationId,op);assert.equal(report.domains.find(s=>s.name==='touch-controls').operationId,'touch-op-original');
  assert.match(f.model.inputPolicyStatusMessage(report),/等待页面布局确认/);assert.equal(calls.filter(x=>x===2).length,1);
  runtime.stop();console.log('PASS partial domains and real publication stage explain saved/pending; observation/log failures independent');
}
{
  const f=fixture();f.port.setControlNativeSink({applyLookConfiguration:()=>true});
  const old=new f.InputConfigurationRuntime();old.start(f.store,4001);const messages=[];
  f.store.addInputPolicyStatusListener(s=>messages.push(s.sessionId));
  const later=new f.InputConfigurationRuntime();later.start(f.store,4002);old.stop();later.reconcile();
  assert.equal(f.store.inputPolicyStatus().sessionId,4002);assert.deepEqual(messages,[4001],
    'provider替换不能把旧订阅自动改绑后来会话');later.stop();
  console.log('PASS original Store registration fences later provider/old stop/old subscriber');
}

/** 暂无法读取端口资格不会保旧 Applied；恢复同一真实端口时只确认原成功值，不重复写。 */
{
  const f=fixture();let unavailable=false,writes=0;
  const sink={applyLookConfiguration:()=>{writes++;return true;}};
  const runtime=new f.InputConfigurationRuntime({binding:()=>{if(unavailable)throw Error('binding observation unavailable');return {generation:7,sink};}});
  runtime.start(f.store,4003);const op=runtime.snapshot().operationId;unavailable=true;runtime.reconcile();
  let domain=runtime.snapshot().domains[0];assert.equal(domain.pending,true);assert.equal(domain.reason,'StatusUnavailable');
  unavailable=false;runtime.reconcile();domain=runtime.snapshot().domains[0];assert.equal(domain.pending,false);assert.equal(domain.stage,'Applied');
  assert.equal(runtime.snapshot().operationId,op);assert.equal(writes,1);runtime.stop();
  evidence.scenes.push({name:'unknown-binding-recovery-no-native-rewrite',writes,op});
  console.log('PASS unknown binding cannot keep stale Applied; same-binding recovery confirms without duplicate Native write');
}

/** 旧持久四字段保持原值/格式；运行兼容投影一次完整调用，不把反馈修改误判为 look 政策变化。 */
{
  const f=fixture(),calls=[];f.port.setControlNativeSink({applyLookConfiguration:c=>{calls.push({...c});return true;}});
  const profile=f.store.getActiveProfile();Object.assign(profile,{lookSensitivity:1.7,invertY:true,lookSmoothing:.35,lookAccel:.8});
  await f.store.saveProfile(profile);const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,4004);
  assert.deepEqual(calls,[{sensitivity:1.7,invertY:true,smoothing:.35,acceleration:.8}]);
  const feedback=f.store.getActiveProfile();feedback.haptic=false;feedback.controls[0].label+='颜色';feedback.controls[0].style={bg:'#abcdef'};
  await f.store.saveProfile(feedback);const report=runtime.snapshot();assert.equal(calls.length,1);
  assert.deepEqual(report.difference,{lookChanged:false,touchChanged:false,gamepadChanged:false});
  const durable=[...f.data.values()].filter(v=>typeof v==='string').join('\n');
  assert.ok(durable.includes('lookSensitivity'));assert.ok(!durable.includes('LegacyGlobalLookCompat'));
  assert.ok(!durable.includes('activationState'));assert.ok(!durable.includes('definitionDeliveryRevision'));
  assert.equal(f.store.getActiveProfile().lookSmoothing,.35);assert.equal(f.store.getActiveProfile().lookAccel,.8);
  evidence.scenes.push({name:'legacy-four-field-atomic-compat-no-storage-format-change',calls,difference:report.difference});runtime.stop();
  console.log('PASS legacy global look exact four-field atomic package and durable values preserved; feedback does not reset unrelated domain');
}

/**
 * AST 原文装载选中的生产成员；缺席的 ArkUI 容器只以 SDK 数值边界提供。
 * 既保留 configurationListener 的闭包，也保留真正 schema 投影/节点确认/订阅文字函数。
 */
function members(relative,ownerName,names,deps,overrides={}){
  const source=overrides[relative]??read(relative),ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)===ownerName);assert.ok(owner,ownerName);
  const body=names.map(name=>{const m=owner.members.find(n=>n.name?.getText(ast)===name);assert.ok(m,name);return m.getText(ast);}).join('\n');
  const output=compiler.transpileModule('class Subject{'+body+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((output.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,'原成员必须可编译');
  const module={exports:{}};new Function('module',...Object.keys(deps),output.outputText)(module,...Object.values(deps));return new module.exports();
}
/** 保存用真正 LayoutStore，触控应用用真正 GameControls，Native 只提供可编程回执/记录。 */
function uiFixture(overrides={}){
  const f=fixture({sourceOverrides:Object.fromEntries(Object.entries(overrides).map(([p,s])=>[p,()=>s]))});
  const game=Object.assign({},f.layout,f.model,...['TouchPreferences','TouchActionBindings','RuntimeTouchLayout','InputSurfaceContext',
    'GameGuiGeometry','TouchGuide','TouchGyroscope','TouchControlGeometry','LayoutCandidate'].map(n=>f.env.load('gamecontrol/src/main/ets/'+n+'.ets')));
  const trace=[];let serial=0,query=0,ack=true,throwInstall=false,contacts=0,onAck=()=>{};
  let state={version:1,status:'idle',surface:'7',session:'3',policy:'1',schemaGeneration:'1',grabEpoch:'1',grabbed:false,
    token:'',operationId:'',candidateId:'',fenced:false,nativeTouches:0,modalCount:0,density:2,transform:0};
  const native={touchPublicationState:()=>{query++;return {...state};},beginTouchPublication:(op,candidate)=>{
    state={...state,status:'fenced',fenced:true,operationId:op,candidateId:candidate,token:String(++serial)};trace.push(['begin',op,candidate]);return {...state};},
    publishTouchSchema:(_schema,op)=>{state={...state,status:'committed'};trace.push(['install',op]);
      trace.push(['schema',structuredClone(_schema)]);
      if(throwInstall){throwInstall=false;throw Error('commit reply lost');}return {...state};},
    confirmTouchPublication:(op,token)=>{trace.push(['ack',op,token,ack]);if(!ack)return false;state={...state,status:'idle',fenced:false};onAck();return true;}};
  const load=makePureEtsLoader({'libentry.so':{__esModule:true,default:native},gamecontrol:game,
    '@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}},overrides);
  const {TouchSurfaceController,TouchSurfaceCandidate}=load('entry/src/main/ets/components/TouchSurfaceController.ets');
  const surface=new game.InputSurfaceContextStore(),publisher=surface.beginPublisher('original-page');
  const value=new game.InputSurfaceContextCandidate();Object.assign(value,{windowId:45,displayId:0,widthPx:2400,heightPx:1600,density:2,
    transform:0,refreshRateHz:60,provisional:false});surface.publish(publisher,value);
  const deps={...game,TouchSurfaceCandidate,getInputSurfaceContextStore:()=>surface,hasEntryTouchModal:()=>false,
    releaseEntryTouchModal:()=>true,getLayoutStore:()=>f.store};
  const view=members(CONTROLS,'GameControls',['configurationListener','subscribeConfigurationStatus_','retireConfigurationStatus_',
    'registerRegions','sendControlSchema','addUiBlock','triggerCode','presentTouchCandidate_','confirmTouchLayout_','touchNodeId_','touchMarkerId_',
    'retireHiddenMouse_','mouseEntryVisible_','mouseEntryPresented_','closeMouse'],deps,overrides);
  Object.assign(view,{mounted:true,pageActive:true,editing:false,editorOpening:false,imeOpen:false,fieldImeOpen:false,isGrabbed:false,
    layoutObserverRegistered:true,appearanceGeneration:1,profileVer:0,presentedCandidateId:'',uiPublicationToken:'',touchStatusMessage:'',
    configurationStatusMessage:'',compWidth:1200,compHeight:800,density:2,desiredProfile:f.store.getActiveProfile(),profile:f.store.getActiveProfile(),
    runtimeLayout:new game.RuntimeTouchLayout(),guiHint:false,guiState:new game.GameGuiState(),globalVisMode:0,drawerOpen:new Map(),
    syncGuideBounds(){},syncMouseBounds(){},realGameVersion:'1.21.11',unresolvedSurfaceModal:undefined});
  // 候选构值与绑定完成必须来自同一个真实Session；原维护scope不借后来current，也不补空adopt方法。
  const maintenance=load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
  const originLease=maintenance.startEntryTouchInputMaintenance();
  view.touchSession=members('entry/src/main/ets/components/EntryTouchSession.ets','EntryTouchSession',
    ['schemaOptions','adoptConfirmedTouchBindings','actionKeys','setRuntimeContext','setGuiViewport','setTouchAdmission'],
    {...game,isEntryTouchInputMaintenanceCurrent:maintenance.isEntryTouchInputMaintenanceCurrent},overrides);
  Object.assign(view.touchSession,{bindings:new game.TouchBindingSnapshot(),follow:true,bindingActivation:'',originLease,
    bindingOptionsText:'key_key.forward:key.keyboard.r',touchAdmitted:true,refreshBindings(){}});
  view.getUIContext=()=>({vp2px:()=>2,getComponentUtils:()=>({getRectangleById:id=>{
    if(id===view.touchMarkerId_())return {size:{width:2,height:2}};
    // 原didLayout必须同时测真实兼容overlay；不能因旧夹具只认识控件而绕开其确认分支。
    const entry=view.runtimeLayout.entries.find(e=>view.touchNodeId_(e.item.id)===id);
    const overlay=view.runtimeLayout.overlays.find(e=>view.touchNodeId_(e.id)===id);
    const rect=entry?.rectPx??overlay?.rectPx;assert.ok(rect,'实际候选节点 '+id);
    return {size:{width:rect.width,height:rect.height},localOffset:{x:rect.x,y:rect.y}};}})});
  view.touchSurface=new TouchSurfaceController((candidate,token)=>view.presentTouchCandidate_(candidate,token),()=>contacts,()=>{});
  assert.equal(view.touchSurface.status().stage,'Waiting');assert.equal(view.touchSurface.status().reason,'NoCandidate',
    '没有候选不能凭 applied/desired 都缺席冒充 Applied');
  const look=[];f.port.setControlNativeSink({applyLookConfiguration:c=>{look.push({...c});return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,5001);
  // 挂接入口取 aboutToAppear 的两条原生产语句，避免测试手写另一套订阅链。
  const ast=compiler.createSourceFile(CONTROLS,overrides[CONTROLS]??read(CONTROLS),compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls'),appear=owner.members.find(n=>n.name?.getText(ast)==='aboutToAppear');
  const bootstrap=appear.body.statements.filter(n=>n.getText(ast).startsWith('const configurationSurface:')||
    n.getText(ast).startsWith('store.addInputConfigurationListener(this.configurationListener')||
    n.getText(ast).startsWith('this.subscribeConfigurationStatus_')).map(n=>n.getText(ast)).join('\n');assert.ok(bootstrap.includes('subscribeConfigurationStatus_'));
  const js=compiler.transpileModule(bootstrap,{compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
  new Function('store',js).call(view,f.store);
  assert.notEqual(view.touchSurface.status().reason,'NoCandidate','实际GC必须建立候选：'+view.touchStatusMessage);
  const initialTouch=view.touchSurface.status();
  assert.equal(view.touchSession.bindingActivation,'','UI确认前候选不采用绑定');
  view.confirmTouchLayout_();
  assert.equal(view.touchSession.actionKeys()[0],82,'REAL_UI_CONFIRMED_BINDING');
  assert.deepEqual(JSON.parse(view.touchSession.bindingActivation),
    ['saved-policy',1,initialTouch.operationId,initialTouch.desiredCandidateId,initialTouch.token],
    '真实确认完成必须采用原方案修订、操作、候选和token');
  // 后续Runtime重试等价候选时，Controller的在途operation已经结束；完成断言应在原confirm接点
  // 观察原operation，等价请求仍必须保持同一candidate/token，不能要求它捏造已结束的在途身份。
  runtime.reconcile();
  assert.deepEqual(JSON.parse(view.touchSession.bindingActivation).slice(3),
    [initialTouch.desiredCandidateId,initialTouch.token]);
  return {...f,view,runtime,trace,look,queries:()=>query,contacts:n=>contacts=n,ack:v=>ack=v,
    onAck:callback=>onAck=callback,loseCommit:()=>throwInstall=true};
}

/** 历史原active走真实load而非被主动选择门拒绝的热切；原文/字段与安全投影各自保留。 */
async function loadUnsupportedActive(f){
  const legacy=f.layout.getDefaultLayout();
  Object.assign(legacy,{name:'历史子摇杆😀',isPreset:false,profileId:'legacy_unsupported_active',profileRevision:1,
    deviceModel:'legacy-device',lookSensitivity:1.7,snapGap:12});
  legacy.controls=[{...legacy.controls[0],label:'原抽屉',type:f.layout.ControlType.DRAWER,
    children:[{...legacy.controls[0],id:'child_joystick',label:'原子摇杆',type:f.layout.ControlType.JOYSTICK}]}];
  assert.ok(f.layout.validateAndNormalizeLayout(legacy),'历史模型合法才能作为旧能力树反例');
  const original=JSON.stringify([legacy]);f.data.set('profiles',original);f.data.set('active_profile',legacy.name);
  await f.store.load();assert.equal(f.store.getActiveProfile().name,legacy.name);
  assert.match(f.store.getProfileCompatibility(legacy.name),/^UnsupportedFeature/);
  f.store.publishInputConfiguration();
  return {legacy,original};
}
/** 原不支持定义只在同候选完成后终结，真实后继metadata仍按原Store命令确认。 */
async function unsupportedActive(overrides={}){
  const f=uiFixture(overrides),{legacy,original}=await loadUnsupportedActive(f);
  const beforeAck=f.view.touchSurface.status();
  assert.equal(beforeAck.stage,'Waiting');assert.equal(beforeAck.reason,'UiConfirmation');
  assert.equal(beforeAck.terminalRejection,false,'安全禁用也不能借能力判据跳过原Native/UI完成');
  assert.equal(f.view.runtimeLayout.entries.length,0);
  const installed=f.trace.filter(row=>row[0]==='schema').at(-1)[1];
  assert.equal(installed.controls.length,1);assert.equal(installed.controls[0].handledBy,1);assert.deepEqual(installed.controls[0].keys,[]);
  f.ack(false);f.view.confirmTouchLayout_();f.runtime.reconcile();
  assert.equal(f.runtime.snapshot().domains.find(state=>state.name==='touch-controls').pending,true);
  f.ack(true);f.view.confirmTouchLayout_();f.runtime.reconcile();
  let snapshot=f.runtime.snapshot(),touch=snapshot.domains.find(state=>state.name==='touch-controls');
  assert.equal(touch.stage,'Rejected','UNSUPPORTED_DEFINITION_REJECTED');
  assert.equal(touch.pending,false,'UNSUPPORTED_TERMINAL_NOT_PENDING');assert.equal(touch.reason,'UnsupportedFeature');
  assert.equal(touch.terminalRejection,true);assert.equal(touch.completedOperationId,beforeAck.operationId);
  assert.equal(touch.candidateId,beforeAck.candidateId);assert.equal(touch.token,beforeAck.token);
  assert.equal(touch.completedProfileId,legacy.profileId);assert.equal(touch.completedProfileRevision,1);
  assert.equal(touch.appliedRevision,0);assert.equal(touch.appliedProfileId,'','原不支持定义不能记为已采用');
  assert.equal(snapshot.activationState,'PartiallyApplied');
  assert.equal(snapshot.domains.find(state=>state.name==='native-look').stage,'Applied','其它有效域不被一起拒绝');
  assert.match(f.view.configurationStatusMessage,/触控布局：方案功能不支持，已安全禁用/);
  assert.doesNotMatch(f.view.configurationStatusMessage,/待生效|已登记输入域已生效/);
  assert.match(f.view.touchStatusMessage,/UnsupportedFeature/);
  const calls=f.trace.length,queries=f.queries();
  for(let i=0;i<8;i++){f.runtime.reconcile();f.runtime.snapshot();f.store.inputPolicyStatus();}
  assert.equal(f.trace.length,calls,'永久不支持完成后不盲目重新安装/分配operation');
  assert.equal(f.queries(),queries,'完成定义的delivery不会反复调用触控应用listener');
  assert.equal(f.data.get('profiles'),original,'原历史库字节不能被状态报告或安全投影覆盖');
  const exported=JSON.parse(f.store.exportToJson(legacy.name));
  assert.equal(exported.controls[0].children[0].type,f.layout.ControlType.JOYSTICK);
  assert.equal(exported.controls[0].children[0].label,'原子摇杆');assert.equal(exported.deviceModel,'legacy-device');
  assert.equal(exported.lookSensitivity,1.7);assert.equal(exported.snapGap,12);
  // 改名是既有确认metadata命令。有效输入/能力相同，仅显式请求前移本域定义身份，
  // 仍绑定原candidate/operation/token；不能因旧target修订永久留下Pending。
  const completion=structuredClone(touch);await f.store.renameProfile(legacy.name,'历史改名😀');f.runtime.reconcile();
  snapshot=f.runtime.snapshot();touch=snapshot.domains.find(state=>state.name==='touch-controls');
  assert.equal(touch.stage,'Rejected');assert.equal(touch.pending,false);
  assert.equal(touch.completedOperationId,completion.completedOperationId);assert.equal(touch.candidateId,completion.candidateId);
  assert.equal(touch.token,completion.token);assert.equal(touch.completedProfileRevision,2);
  assert.equal(f.trace.filter(row=>row[0]==='install').length,f.trace.slice(0,calls).filter(row=>row[0]==='install').length);
  return {f,original,completion,legacy};
}
{
  const result=await unsupportedActive();
  evidence.scenes.push({name:'historical-active-safe-disabled-terminal',completion:result.completion});
  result.f.runtime.stop();result.f.view.touchSurface.dispose();
  console.log('PASS real historical active load→safe schema→Native/UI ACK→terminal Rejected, unrelated look Applied, original/export retained and equivalent rename');
}

/** 已终结不支持定义修复后正常采用；dispose保持原公开token失权。 */
{
  const {f}=await unsupportedActive(),fixed=f.store.getActiveProfile();
  fixed.controls[0].children[0].type=f.layout.ControlType.BUTTON;
  fixed.controls[0].children[0].keyOrMouse=65;fixed.controls[0].children[0].keys=[65];
  assert.equal(await f.store.saveProfile(fixed),true);const pending=f.view.touchSurface.status();
  assert.equal(pending.stage,'Waiting');assert.equal(pending.terminalRejection,false);
  f.view.confirmTouchLayout_();f.runtime.reconcile();
  const touch=f.runtime.snapshot().domains.find(state=>state.name==='touch-controls');
  assert.equal(touch.stage,'Applied');assert.equal(touch.pending,false);assert.equal(touch.terminalRejection,false);
  const controller=f.view.touchSurface;controller.dispose();
  const old=controller.status();assert.equal(old.stage,'Retired');assert.equal(old.terminalRejection,false);
  f.runtime.stop();
  console.log('PASS valid repaired definition returns Applied; retired original controller cannot retain terminal capability permission');
}

/** A仍在等原UI确认时保存修复B；原A只收口自己，不代签B能力或绑定。 */
{
  const f=uiFixture();await loadUnsupportedActive(f);const a=f.view.touchSurface.status();
  const fixed=f.store.getActiveProfile();fixed.controls[0].children[0].type=f.layout.ControlType.BUTTON;
  fixed.controls[0].children[0].keyOrMouse=65;fixed.controls[0].children[0].keys=[65];
  assert.equal(await f.store.saveProfile(fixed),true);const before=f.view.touchSurface.status();
  assert.equal(before.reason,'PreviousPublication');assert.equal(before.terminalRejection,false);
  assert.equal(before.candidateId,a.candidateId);assert.notEqual(before.desiredCandidateId,a.candidateId);
  f.view.confirmTouchLayout_();const b=f.view.touchSurface.status();
  assert.equal(b.stage,'Waiting');assert.equal(b.reason,'UiConfirmation');assert.equal(b.terminalRejection,false);
  assert.notEqual(b.candidateId,a.candidateId);assert.equal(f.view.touchSurface.confirm(a.candidateId,a.token),false);
  f.view.confirmTouchLayout_();f.runtime.reconcile();
  const state=f.runtime.snapshot().domains.find(value=>value.name==='touch-controls');
  assert.equal(state.stage,'Applied');assert.equal(state.pending,false);assert.equal(state.appliedProfileRevision,2);
  assert.equal(state.terminalRejection,false);f.runtime.stop();f.view.touchSurface.dispose();
  console.log('PASS unsupported in-flight A and supported B preserve original candidates/ACK; A capability cannot settle B');
}

/** reader边缘故意返回旧完成缓存；原Delivery必须核定义身份，不信相同stage/token文字。 */
function staleCapabilityDelivery(overrides={}){
  const f=fixture({sourceOverrides:Object.fromEntries(Object.entries(overrides).map(([p,s])=>[p,()=>s]))});
  const delivery=new f.model.InputConfigurationDelivery(),profile=f.store.getActiveProfile();
  const progress=Object.assign(new f.model.InputConfigurationProgress(),{stage:'Rejected',reason:'UnsupportedFeature',
    terminalRejection:true,completedOperationId:'original-op',candidateId:'original-candidate',desiredCandidateId:'original-candidate',
    token:'original-token',targetProfileId:profile.profileId,targetProfileRevision:1,
    completedProfileId:profile.profileId,completedProfileRevision:1,capabilityIssue:'UnsupportedFeature:old candidate'});
  delivery.add('touch-controls',()=>true,()=>progress);delivery.publish(profile);
  assert.equal(delivery.status()[0].pending,false);
  const later=f.layout.cloneLayout(profile);later.profileRevision=2;delivery.publish(later);
  const state=delivery.status()[0];
  assert.equal(state.pending,true,'OLD_CAPABILITY_CANNOT_SETTLE_NEW_DEFINITION');
  assert.equal(state.terminalRejection,false);assert.equal(state.stage,'Waiting');
}
staleCapabilityDelivery();

/** Native确认同步退休原controller时，不保存其token/完成能力；读取仍为原Retired。 */
function retiredDuringAck(overrides={}){
  const f=uiFixture(overrides),changed=f.store.getActiveProfile();changed.controls[0].xPct+=.01;
  // saveProfile的Promise完成后才能测试实际新候选；续体只操作原fixture/controller。
  return f.store.saveProfile(changed).then(()=>{
    const controller=f.view.touchSurface;f.onAck(()=>controller.dispose());f.view.confirmTouchLayout_();
    assert.equal(controller.token(),'','RETIRED_ACK_CANNOT_RESTORE_TOKEN');
    assert.equal(controller.status().stage,'Retired');assert.equal(controller.status().terminalRejection,false);f.runtime.stop();
  });
}
await retiredDuringAck();

/** 撤回只改原candidate关联；必须先编译并由完整旧active行为断言识别错误Applied。 */
for(const [name,relative,needle,replacement] of [
  ['capability-not-bound-to-original-candidate',CONTROLS,
    'new TouchSurfaceCandidate(profile,layout,schema,issue)','new TouchSurfaceCandidate(profile,layout,schema)'],
  ['current-page-issue-cannot-stamp-original-candidate',CONTROLS,
    'new TouchSurfaceCandidate(profile,layout,schema,issue)',
    'new TouchSurfaceCandidate(profile,layout,schema,layoutCapabilityIssue(this.profile))'],
  ['capability-lost-when-candidate-frozen','entry/src/main/ets/components/TouchSurfaceController.ets',
    'new TouchSurfaceCandidate(candidate.profile,candidate.layout,candidate.schema,candidate.capabilityIssue)',
    'new TouchSurfaceCandidate(candidate.profile,candidate.layout,candidate.schema)']
]){
  const changed=replaceOnce(read(relative),needle,replacement);let failure;
  try{await unsupportedActive({[relative]:changed});}catch(error){failure=error;}
  assert.ok(failure instanceof assert.AssertionError&&failure.message.includes('UNSUPPORTED_DEFINITION_REJECTED'),
    name+'必须转译成功后命中实际错误Applied断言: '+failure);
  evidence.negatives.push({name,assertion:'UNSUPPORTED_DEFINITION_REJECTED',message:failure.message,
    sourceSHA256:crypto.createHash('sha256').update(changed).digest('hex')});
}
for(const [name,relative,needle,replacement,run,expected] of [
  ['old-terminal-cannot-complete-new-definition',DELIVERY,
    'progress.completedProfileId === state.desiredProfileId && progress.completedProfileRevision === state.desiredProfileRevision',
    'true',staleCapabilityDelivery,'OLD_CAPABILITY_CANNOT_SETTLE_NEW_DEFINITION'],
  ['retired-confirmation-cannot-restore-token','entry/src/main/ets/components/TouchSurfaceController.ets',
    'if (!this.active || this.disposed || this.publication !== publication) return false',
    'void publication',retiredDuringAck,'RETIRED_ACK_CANNOT_RESTORE_TOKEN']
]){
  const changed=replaceOnce(read(relative),needle,replacement);let failure;
  try{await run({[relative]:changed});}catch(error){failure=error;}
  assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(expected),name+'必须先转译再命中行为断言: '+failure);
  evidence.negatives.push({name,assertion:expected,message:failure.message,
    sourceSHA256:crypto.createHash('sha256').update(changed).digest('hex')});
}

/** 首次保存改变真正命中坐标，旧接触结束后安装；ACK false/丢失必须保留原发布资格。 */
async function savedPendingSequence(overrides={}){
  const f=uiFixture(overrides),initial=f.runtime.snapshot(),initialBindings=f.view.touchSession.bindingActivation;f.contacts(1);
  const changed=f.store.getActiveProfile();changed.controls[0].xPct+=.01;assert.equal(await f.store.saveProfile(changed),true);
  let report=f.runtime.snapshot(),touch=report.domains.find(s=>s.name==='touch-controls');
  assert.equal(report.definitionState,'Saved');assert.equal(report.profileId,initial.profileId);assert.equal(report.profileRevision,2);
  assert.equal(touch.stage,'Waiting');assert.equal(touch.reason,'ContactsEnding');assert.equal(touch.pending,true);
  assert.match(f.view.configurationStatusMessage,/方案已保存.*等待旧接触结束/,'SAVED_PENDING_UI');
  const op=touch.operationId,candidate=touch.candidateId,policyOp=report.operationId,installed=f.trace.filter(x=>x[0]==='install').length;
  const queries=f.queries();for(let i=0;i<5;i++){f.runtime.snapshot();f.store.inputPolicyStatus();f.view.touchSurface.status();}
  assert.equal(f.queries(),queries,'观察不得查询推进Native');assert.equal(f.look.length,1,'未变视角域不重置');
  f.contacts(0);f.loseCommit();f.view.touchSurface.reconcile();f.runtime.reconcile();
  assert.equal(f.trace.filter(x=>x[0]==='install').length,installed+1,'丢安装回执只能查询同一operation，不能双安装');
  report=f.runtime.snapshot();touch=report.domains.find(s=>s.name==='touch-controls');
  assert.equal(touch.operationId,op);assert.equal(touch.candidateId,candidate);assert.equal(touch.targetProfileRevision,2);
  assert.equal(touch.reason,'UiConfirmation');assert.match(f.view.configurationStatusMessage,/方案已保存.*等待页面布局确认/);
  f.ack(false);f.view.confirmTouchLayout_();f.runtime.reconcile();
  assert.equal(f.runtime.snapshot().domains.find(s=>s.name==='touch-controls').pending,true,'ACK_FALSE_PENDING');
  assert.equal(f.view.touchSurface.status().operationId,op,'ACK_FALSE_PENDING 原操作不能被当作已结束后重建');
  assert.equal(f.view.touchSurface.admits(f.view.uiPublicationToken),false);
  assert.equal(f.view.touchSession.bindingActivation,initialBindings,'ACK false不能提前采用保存后的候选绑定');
  f.ack(true);f.view.confirmTouchLayout_();
  assert.deepEqual(JSON.parse(f.view.touchSession.bindingActivation),
    [initial.profileId,2,op,candidate,f.view.uiPublicationToken],'保存后的真实UI确认采用原修订与原发布身份');
  f.runtime.reconcile();report=f.runtime.snapshot();
  assert.equal(report.operationId,policyOp);assert.equal(report.domains.find(s=>s.name==='touch-controls').pending,false);
  assert.match(f.view.configurationStatusMessage,/方案已保存.*已生效/);
  const beforeFailure=report.operationId,message=f.view.configurationStatusMessage;f.failSave();const fail=f.store.getActiveProfile();fail.controls[0].xPct+=.01;
  await assert.rejects(f.store.saveProfile(fail),/disk failure/);assert.equal(f.runtime.snapshot().operationId,beforeFailure);assert.equal(f.view.configurationStatusMessage,message);
  const oldCallback=f.store.policyStatusObservers[0].listener;f.view.retireConfigurationStatus_();f.view.appearanceGeneration++;
  f.view.configurationStatusMessage='new appearance';oldCallback(report);assert.equal(f.view.configurationStatusMessage,'new appearance','旧appearance迟到报告作废');
  f.runtime.stop();return {profileId:report.profileId,revision:report.profileRevision,policyOp,touchOp:op,candidate,trace:f.trace};
}
evidence.scenes.push({name:'saved-contact-commit-lost-ack-false-real-ui',result:await savedPendingSequence()});
console.log('PASS actual Store→Runtime→GC schema→Controller→didLayout→readonly UI: saved pending/contact/install/ACK isolation');

/** 新保存 B 在 A 等待 didLayout 时到达：报告分开原在途 A 与 desired B，旧 token 不能确认 B。 */
{
  const f=uiFixture(),initialBindings=f.view.touchSession.bindingActivation;const a=f.store.getActiveProfile();a.controls[0].xPct+=.01;await f.store.saveProfile(a);
  const old=f.view.touchSurface.status(),b=f.store.getActiveProfile();b.controls[0].xPct+=.01;await f.store.saveProfile(b);
  let report=f.runtime.snapshot(),touch=report.domains.find(s=>s.name==='touch-controls');
  assert.equal(report.profileRevision,3);assert.equal(touch.targetProfileRevision,2);assert.equal(touch.reason,'PreviousPublication');
  assert.notEqual(touch.desiredCandidateId,old.candidateId);assert.match(f.view.configurationStatusMessage,/方案已保存.*等待上一布局操作结束/);
  f.view.confirmTouchLayout_();const newer=f.view.touchSurface.status();assert.notEqual(newer.operationId,old.operationId);
  assert.equal(f.view.touchSession.bindingActivation,initialBindings,'确认A同步推进B时，旧续体不能把A绑定盖到B');
  assert.equal(f.view.touchSurface.confirm(old.candidateId,old.token),false,'旧token不得确认 B');f.runtime.reconcile();
  assert.equal(f.runtime.snapshot().domains.find(s=>s.name==='touch-controls').pending,true);
  f.view.confirmTouchLayout_();
  assert.deepEqual(JSON.parse(f.view.touchSession.bindingActivation),
    ['saved-policy',3,newer.operationId,newer.desiredCandidateId,newer.token],'只有B自己的真实确认采用B绑定');
  f.runtime.reconcile();assert.equal(f.runtime.snapshot().domains.find(s=>s.name==='touch-controls').pending,false);
  evidence.scenes.push({name:'original-publication-A-later-save-B',old,newer});f.runtime.stop();
  console.log('PASS saved revision B and in-flight publication A retain separate identities; late A cannot acknowledge B');
}

/** 原 Native 调用同步发布新确认定义：旧完成即使 true 也不能替后来 op 盖 Applied。 */
function reentrantOperation(options={}){
  const f=fixture(options);let publish=false;const seen=[];
  f.port.setControlNativeSink({applyLookConfiguration:c=>{seen.push(c.sensitivity);
    if(publish){publish=false;const later=f.store.getActiveProfile();later.profileRevision=3;later.lookSensitivity=3;
      f.store.profiles=[later];f.store.publishInputConfiguration(true);}return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store,6001);publish=true;
  const older=f.store.getActiveProfile();older.profileRevision=2;older.lookSensitivity=2;f.store.profiles=[older];f.store.publishInputConfiguration(true);
  let report=runtime.snapshot(),look=report.domains.find(s=>s.name==='native-look');
  assert.equal(report.profileRevision,3);assert.equal(look.pending,true);assert.equal(look.stage,'Waiting','REENTRANT_OLD_COMPLETION');
  assert.equal(runtime.progress.stage,'Waiting','REENTRANT_OLD_COMPLETION 原应用权威也不能写后来operation成功');
  assert.equal(look.targetProfileRevision,3);const op=report.operationId;runtime.reconcile();report=runtime.snapshot();
  assert.equal(report.operationId,op);assert.equal(report.domains[0].pending,false);assert.deepEqual(seen,[1,2,3]);runtime.stop();return {op,seen};
}
evidence.scenes.push({name:'native-synchronous-new-definition',result:reentrantOperation()});
console.log('PASS original Native completion cannot claim later saved operation; same-op actual maintenance applies latest');

/** 捕获的旧进度 reader 直接执行，正常退订之外仍只能观察原 controller 的退休。 */
function readerScopeSequence(overrides={}){
  const f=uiFixture(overrides),reader=f.store.inputConfigurationDelivery.subscribers.find(s=>s.name==='touch-controls').progress;
  const original=reader();f.view.touchSurface.dispose();
  f.view.touchSurface=new f.view.touchSurface.constructor(()=>{},()=>0,()=>{});
  const later=f.view.touchSurface.status(),retired=reader();assert.equal(later.reason,'NoCandidate');
  assert.equal(retired.stage,'Retired','OLD_CONTROLLER_READER 不能借后来控制器报告');
  f.runtime.stop();return {original,later,retired};
}
evidence.scenes.push({name:'original-controller-progress-reader',result:readerScopeSequence()});

/** 反控只撤真实生产的一个资格边界，保留下层时序；必须击中具名用户行为断言。 */
for(const [name,relative,mutate,run,expected] of [
  ['saved-is-not-application',CONTROLS,s=>replaceOnce(s,'this.configurationStatusMessage = inputPolicyStatusMessage(snapshot)',
    "this.configurationStatusMessage = '方案已保存；已生效'"),o=>savedPendingSequence(o),'SAVED_PENDING_UI'],
  ['false-ack-is-not-completion','entry/src/main/ets/components/TouchSurfaceController.ets',s=>replaceOnce(s,
    'if (!testNapi.confirmTouchPublication(publication.operationId, token)) return false','testNapi.confirmTouchPublication(publication.operationId, token)'),
    o=>savedPendingSequence(o),'ACK_FALSE_PENDING'],
  ['confirmed-binding-cannot-be-noop',CONTROLS,s=>replaceOnce(s,
    'this.touchSession.adoptConfirmedTouchBindings(candidate.profile,candidate.schema.touch,completedOperation,candidate.id,token)',
    'void candidate'),o=>savedPendingSequence(o),'REAL_UI_CONFIRMED_BINDING'],
  ['old-controller-cannot-borrow-new-progress',CONTROLS,s=>replaceOnce(s,
    "'touch-controls', () => configurationSurface.status()","'touch-controls', () => this.touchSurface.status()"),
    o=>readerScopeSequence(o),'OLD_CONTROLLER_READER'],
  ['old-native-cannot-claim-new-op',RUNTIME,s=>replaceOnce(s,
    // 现在写后查询也核同一资格；撤回共同operation判据才能真实撤掉整个政策，
    // 不能只撤一处调用后因第二道正确检查仍保护而把“未失败”当负控成立。
    'return this.store === store && this.generation === generation && this.snapshotValue.operationId === operation',
    'return this.store === store && this.generation === generation'),
    o=>reentrantOperation({sourceOverrides:{[RUNTIME]:()=>o[RUNTIME]}}),'REENTRANT_OLD_COMPLETION']
]){
  const changed=mutate(read(relative));let failure;try{await run({[relative]:changed});}catch(error){failure=error;}
  assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(expected),name+'必须触达行为断言: '+failure);
  evidence.negatives.push({name,assertion:expected,message:failure.message,sourceSHA256:crypto.createHash('sha256').update(changed).digest('hex')});
}
// 正式只读文字解释每个gyro原资源等待；纯查询不能把Pending改成Applied或制造Native调用。
{
  const f=fixture(), value=new f.model.InputPolicyActivationSnapshot();
  value.profileId='gyro-policy';value.definitionState='Saved';value.identityStage='Bound';
  const state=new f.model.InputConfigurationStatus();state.name='touch-gyro';state.stage='Waiting';state.pending=true;
  value.domains=[state];const messages=[];
  for(const [reason,expected] of [
    ['unsubscribe-pending',/原传感器订阅关闭确认/],['retirement-pending',/原陀螺仪输入流结束确认/],
    ['unavailable',/传感器或输入端暂不可用/],['pending',/有效陀螺仪输入资源/],
    ['InputNotAdmitted',/游戏准入恢复/],['SourceInactive',/游戏前台与来源恢复/],
    ['NativeVisualUnavailable',/输入状态确认/],['OutcomeUnknown',/采用结果待确认/]
  ]){
    state.reason=reason;const before=JSON.stringify(value),message=f.model.inputPolicyStatusMessage(value);
    assert.match(message,/方案已保存，待生效；陀螺仪：/);assert.match(message,expected);
    assert.doesNotMatch(message,/touch-gyro|unsubscribe-pending|retirement-pending|InputNotAdmitted|已生效/);
    assert.equal(JSON.stringify(value),before,'报告解释只读，不推进或改状态');messages.push({reason,message});
  }
  evidence.scenes.push({name:'gyro-original-resource-waiting-messages',messages});
  console.log('PASS gyro report: Chinese domain/original resources and admission reasons, no Applied claim or state writes');
}
const sources=[DELIVERY,RUNTIME,'gamecontrol/src/main/ets/LayoutStore.ets','gamecontrol/src/main/ets/InputConfigurationNativePort.ets',
  'gamecontrol/src/main/ets/ControlLayout.ets',CONTROLS,'entry/src/main/ets/components/TouchSurfaceController.ets',
  'entry/src/main/ets/components/EntryTouchSession.ets','scripts/test-input-policy-activation.mjs'];
evidence.sources=Object.fromEntries(sources.map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT,p))).digest('hex')]));
const at=process.argv.indexOf('--output'),base=at<0?workspacePath('run','input-policy-activation'):assertExternalOutputPath(process.argv[at+1]);
const output=path.join(base,'run-'+process.pid+'-'+crypto.randomUUID().slice(0,8));fs.mkdirSync(output,{recursive:true});
evidence.started=started;evidence.completed=new Date().toISOString();fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify(evidence,null,2)+'\n');
console.log('[input-policy-activation] PASS real production UI sequences and '+evidence.negatives.length+' executable withdrawal negatives; evidence='+output);

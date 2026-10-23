/** G2真实Session/gyro/触控候选/配置投递；OS sensor与Native回执是外部边缘，不证明硬件。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {environment} from './lib/ets-runtime-fixture.mjs';
import {PROJECT_ROOT,workspacePath} from './lib/workspace-paths.mjs';

const sessionPath='entry/src/main/ets/components/EntryTouchSession.ets';
const gyroPath='entry/src/main/ets/components/EntryTouchGyroscope.ets';
const modules=['ControlLayout','TouchPreferences','TouchActionBindings','RuntimeTouchLayout','TouchGuide','GameGuiGeometry','TouchGyroscope','InputConfiguration'];
const bound=[sessionPath,'entry/src/main/ets/components/EntryTouchGyroscope.ets','entry/src/main/ets/components/EntryTouchInputMaintenance.ets',
  'entry/src/main/ets/components/TouchSurfaceController.ets','entry/src/main/ets/components/GameControls.ets','gamecontrol/src/main/ets/LayoutStore.ets',
  ...modules.map(n=>'gamecontrol/src/main/ets/'+n+'.ets'),'scripts/test-gyro-policy-activation.mjs','scripts/lib/ets-runtime-fixture.mjs',
  'scripts/lib/load-pure-ets.mjs','scripts/lib/ets-compiler.mjs'];
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT,p))).digest('hex');
const before=Object.fromEntries(bound.map(p=>[p,sha(p)]));const startedAt=new Date().toISOString();
function fixture(overrides={}){
  const plain=makePureEtsLoader({commons:{AppLogger:{warn(){}}}});
  const game=Object.assign({},...modules.map(n=>plain('gamecontrol/src/main/ets/'+n+'.ets')));
  const callbacks=[],offCalls=[],activeCallbacks=new Set(),submits=[],retires=[],begins=[];let allowRetire=true,rejectSchema=false,serial=0;
  const sensorEdge={onRegister:()=>{},onUnregister:()=>{}};
  const logEdge={info:()=>{},warn:()=>{}};
  let state={version:1,status:'idle',surface:'1',session:'3',policy:'2',schemaGeneration:'1',grabEpoch:'1',grabbed:true,
    token:'0',operationId:'',candidateId:'',fenced:false,nativeTouches:0,density:1,transform:0};let oldState={...state};
  const native={maintainTouchInput:()=>true,touchInteractionVisual:()=>{const a=Array(25).fill(0);a[12]=Number(state.schemaGeneration);a[24]=1;return a;},
    sharedLookExecutionSupported:()=>true,touchGyroLeaseContext:()=> 'resource-policy-A',
    beginTouchGyroLease:s=>{const t='gyro:'+ ++serial;begins.push({s,t});return t;},
    retireTouchGyroLease:t=>{retires.push(t);return allowRetire;},submitTouchGyroLease:(...v)=>{submits.push(v);return true;},
    touchPublicationState:()=>({...state}),beginTouchPublication:(op,candidate)=>{oldState={...state};state={...state,status:'fenced',fenced:true,operationId:op,candidateId:candidate,token:'touch:'+ ++serial};return {...state};},
    publishTouchSchema:()=>{state={...state,status:rejectSchema?'invalid':'committed'};return {...state};},
    confirmTouchPublication:()=>{state={...state,status:'idle',fenced:false};return true;},
    abortTouchPublication:()=>{state={...oldState,operationId:'',candidateId:'',fenced:false};return {...state};}};
  const timers=new Map();let timerId=0;
  const env=environment({sourceOverrides:overrides,imports:{gamecontrol:game,'libentry.so':{__esModule:true,default:native},
    '@ohos.file.fs':{__esModule:true,default:{readTextSync:()=> 'key_key.forward:key.keyboard.r'}},
    '@kit.SensorServiceKit':{sensor:{SensorId:{GYROSCOPE:2},on:(id,cb)=>{callbacks.push(cb);activeCallbacks.add(cb);sensorEdge.onRegister(id,cb);},
      off:(id,cb)=>{offCalls.push({id,callback:cb});sensorEdge.onUnregister(id,cb);activeCallbacks.delete(cb);}}},
    '@kit.PerformanceAnalysisKit':{hilog:{info:()=>logEdge.info(),warn:()=>logEdge.warn()}}},
    globals:{setInterval:cb=>{timers.set(++timerId,cb);return timerId;},clearInterval:id=>timers.delete(id)}});
  const maintenance=env.load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
  const scope=maintenance.startEntryTouchInputMaintenance();
  const {EntryTouchSession}=env.load(sessionPath);const session=new EntryTouchSession();
  // 仓库薄方法逐字生产提取，实际投递仍用InputConfigurationDelivery；持久IO不在本目标。
  const storeSource=fs.readFileSync(path.join(PROJECT_ROOT,'gamecontrol/src/main/ets/LayoutStore.ets'),'utf8');
  const ast=compiler.createSourceFile('store.ets',storeSource,compiler.ScriptTarget.Latest,true),owner=ast.statements.find(n=>n.name?.getText(ast)==='LayoutStore');
  const names=['addInputConfigurationListener','removeInputConfigurationListener','addInputConfigurationDefinitionListener','removeInputConfigurationDefinitionListener','publishInputConfiguration','reconcileInputConfiguration','invalidateInputConfiguration'];
  const bodies=names.map(name=>owner.members.find(m=>m.name?.getText(ast)===name).getText(ast)).join('\n');
  const js=compiler.transpileModule('class Store{'+bodies+'}\nmodule.exports=Store;', {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const mod={exports:{}};new Function('module',js)(mod);const store=new mod.exports();store._ready=true;store.inputConfigurationDelivery=new game.InputConfigurationDelivery();
  let current=game.getDefaultLayout();store.getActiveProfile=()=>game.cloneLayout(current);game.getLayoutStore=()=>store;
  session.startSources(true);session.setGrabbed(true);session.setTouchAdmission(true);
  const {TouchSurfaceController,TouchSurfaceCandidate}=env.load('entry/src/main/ets/components/TouchSurfaceController.ets');let presented;
  const controller=new TouchSurfaceController((candidate,token)=>{presented={candidate,token};},()=>0,()=>{});
  const layout=new game.RuntimeTouchLayout();Object.assign(layout.context,{key:'same-surface',valid:true,density:1,transform:0,widthPx:1000,heightPx:1000});
  function candidate(p){return new TouchSurfaceCandidate(p,layout,{schemaVersion:3,compWidth:1000,compHeight:1000,grabbed:true,controls:[],touch:session.schemaOptions(p)});}
  store.addInputConfigurationListener(p=>controller.request(candidate(p)),'touch-controls',()=>controller.status());
  function publish(p){current=p;store.publishInputConfiguration(true);}
  function confirm(){assert.ok(presented);assert.equal(controller.confirm(presented.candidate.id,presented.token),true);session.setTouchAdmission(controller.admits(presented.token));store.reconcileInputConfiguration();}
  function tick(){session.maintainSources();store.reconcileInputConfiguration();}
  function sample(){const cb=callbacks.at(-1);assert.ok(cb);cb({x:0,y:1,z:0,timestamp:1e9});cb({x:0,y:1,z:0,timestamp:1e9+20000000});return submits.at(-1)?.[1];}
  function profile(sensitivity,scale=1){const p=game.cloneLayout(game.getDefaultLayout());p.profileId='gyro';p.profileRevision=sensitivity;
    p.globalScale=scale;p.touch={gyroscopeMode:'always',gyroscopeSensitivity:sensitivity};return p;}
  return {game,session,store,controller,publish,confirm,tick,sample,profile,callbacks,offCalls,activeCallbacks,submits,retires,begins,
    native,sensorEdge,logEdge,maintenance,scope,timers,retire:v=>{allowRetire=v;},reject:v=>{rejectSchema=v;},candidate,state:()=>({...state})};
}
function pending(overrides={}){const f=fixture(overrides),a=f.profile(1);f.publish(a);f.confirm();f.tick();assert.equal(f.session.gyroscopeStatus(),'active');
  f.retire(false);f.publish(f.profile(2));f.tick();const statuses=f.store.inputConfigurationDelivery.status();
  assert.equal(statuses.find(s=>s.name==='touch-controls').pending,false);
  const gyro=statuses.find(s=>s.name==='touch-gyro');assert.ok(gyro&&gyro.pending,'GYRO_PENDING_MUST_HAVE_OWN_RECEIPT');
  return statuses;}
function rejected(overrides={}){const f=fixture(overrides),a=f.profile(1);f.publish(a);f.confirm();f.tick();assert.ok(Math.abs(f.sample()+7.2)<1e-8);
  f.reject(true);f.candidate(f.profile(2,1.2)); // 仅纯构值，不是配置发布或真实完成。
  f.controller.request(f.candidate(f.profile(2,1.2)));assert.equal(f.controller.admits(f.controller.token()),true);
  f.tick();assert.ok(Math.abs(f.sample()+7.2)<1e-8,'REJECTED_CANDIDATE_CANNOT_ADOPT_GYRO_B');
  return {status:f.session.gyroscopeStatus(),submits:f.submits};}
function restore(){const f=fixture(),a=f.profile(1);f.publish(a);f.confirm();f.tick();
  f.reject(true);f.publish(f.profile(2,1.2));f.tick();assert.equal(f.controller.admits(f.controller.token()),true);
  assert.ok(Math.abs(f.sample()+14.4)<1e-8,'独立gyro域可确认已发布B，不能借几何Rejected抹去其真实完成');
  f.retire(false);f.publish(a);f.tick();let states=f.store.inputConfigurationDelivery.status();
  assert.equal(states.find(s=>s.name==='touch-controls').pending,false);
  assert.equal(states.find(s=>s.name==='touch-gyro').pending,true,'RESTORE_A_GYRO_WAITING_ORIGINAL_RETIRE');
  const before=f.submits.length,old=f.callbacks.at(-1);old({x:0,y:1,z:0,timestamp:2e9});old({x:0,y:1,z:0,timestamp:2e9+20000000});
  assert.equal(f.submits.length,before,'退休墓碑期间旧sensor不继续产样本');
  f.retire(true);f.tick();states=f.store.inputConfigurationDelivery.status();assert.equal(states.find(s=>s.name==='touch-gyro').pending,false);
  assert.ok(Math.abs(f.sample()+7.2)<1e-8,'恢复A必须真实重新采用A政策');return states;}
function reentry(){const f=fixture(),a=f.profile(1);f.publish(a);f.confirm();f.tick();
  const original=f.native.beginTouchGyroLease;let once=false;
  f.native.beginTouchGyroLease=s=>{const t=original(s);if(!once){once=true;f.publish(f.profile(3));}return t;};
  f.publish(f.profile(2));f.tick();let states=f.store.inputConfigurationDelivery.status();
  assert.equal(states.find(s=>s.name==='touch-gyro').appliedProfileRevision,3,'NEW_DEFINITION_OPERATION_AFTER_REENTRY');
  assert.ok(Math.abs(f.sample()+21.6)<1e-8);return states;}
function stopDuringSensor(){const f=fixture();f.sensorEdge.onRegister=()=>f.session.stopSources();f.publish(f.profile(1));
  assert.equal(f.session.gyroscopeStatus(),'idle','STOP_DURING_SENSOR_CANNOT_REVIVE_ACTIVE');
  assert.equal(f.store.inputConfigurationDelivery.status().some(s=>s.name==='touch-gyro'),false);
  const before=f.submits.length,cb=f.callbacks.at(-1);cb({x:0,y:1,z:0,timestamp:1e9});cb({x:0,y:1,z:0,timestamp:1e9+20000000});
  assert.equal(f.submits.length,before);return {status:f.session.gyroscopeStatus(),retires:f.retires};}
/**
 * 真正生产Session停止路径：sensor.off与诊断同时失败时，原Native句柄仍须尝试退休。
 * 未确认的原token只能保墓碑；旧sensor闭包立即失权，恢复由同一原token确认后再建新流。
 */
function offAndLogFailure(overrides={}){const f=fixture(overrides),a=f.profile(1);f.publish(a);f.confirm();f.tick();
  const original=f.begins.at(-1).t,old=f.callbacks.at(-1),beginCount=f.begins.length;let offCalls=0,logCalls=0;
  f.sensorEdge.onUnregister=()=>{offCalls++;throw Error('controlled sensor.off failure');};
  f.logEdge.warn=()=>{logCalls++;throw Error('controlled hilog.warn failure');};f.retire(false);
  assert.doesNotThrow(()=>f.session.stopSources(),'OFF_LOG_FAILURE_CANNOT_SKIP_NATIVE_RETIRE');
  assert.equal(f.session.gyroscopeStatus(),'retirement-pending','OFF_LOG_FAILURE_MUST_KEEP_RETIREMENT_RECEIPT');
  assert.equal(f.retires.at(-1),original);assert.equal(offCalls,1);assert.equal(logCalls,1);
  const before=f.submits.length;old({x:0,y:1,z:0,timestamp:2e9});old({x:0,y:1,z:0,timestamp:2e9+20000000});
  assert.equal(f.submits.length,before,'停止先围栏旧sensor回调，不等待off或Native确认');
  // 每次显式start/tick只尝试原墓碑，没有确认时不会调用begin或让旧配置Applied。
  f.session.startSources(true);f.tick();assert.equal(f.begins.length,beginCount);
  assert.equal(f.retires.every(t=>t===original),true);
  const gyro=f.store.inputConfigurationDelivery.status().find(s=>s.name==='touch-gyro');assert.equal(gyro.pending,true);
  f.retire(true);f.tick();assert.equal(f.session.gyroscopeStatus(),'unsubscribe-pending');assert.equal(f.begins.length,beginCount);
  f.sensorEdge.onUnregister=()=>{offCalls++;};f.tick();assert.equal(f.session.gyroscopeStatus(),'active');assert.equal(f.begins.length,beginCount+1);
  return {original,offCalls,logCalls,retires:f.retires,begins:f.begins};}
/** Native退休异常与诊断异常分开：重复查询不重试，后续维护只重试原句柄并限一次告警。 */
function retirementAndLogFailure(overrides={}){const f=fixture(overrides);f.publish(f.profile(1));f.confirm();f.tick();
  const original=f.begins.at(-1).t,beginCount=f.begins.length;let logCalls=0;
  f.logEdge.warn=()=>{logCalls++;throw Error('controlled retirement hilog.warn failure');};
  f.native.retireTouchGyroLease=t=>{f.retires.push(t);throw Error('controlled Native retirement failure');};
  assert.doesNotThrow(()=>f.session.stopSources(),'RETIRE_LOG_FAILURE_CANNOT_SKIP_PENDING_RECEIPT');
  assert.equal(f.session.gyroscopeStatus(),'retirement-pending');assert.equal(f.retires.at(-1),original);
  const attempts=f.retires.length;f.session.gyroscopeStatus();f.store.inputConfigurationDelivery.status();
  assert.equal(f.retires.length,attempts,'只读状态不推进退休');
  f.session.startSources(true);f.tick();assert.equal(f.begins.length,beginCount);assert.equal(logCalls,1);
  assert.equal(f.retires.every(t=>t===original),true);
  f.native.retireTouchGyroLease=t=>{f.retires.push(t);return true;};f.tick();
  assert.equal(f.session.gyroscopeStatus(),'active');assert.equal(f.begins.length,beginCount+1);
  return {original,logCalls,retires:f.retires,begins:f.begins};}
function pureFollow(){const f=fixture();f.session.setDirectory('world');const a=f.profile(1),before=f.session.actionKeys();
  assert.equal(before[0],82);const b=f.profile(2);b.touch.followGameBindings=false;
  const schema=f.session.schemaOptions(b);assert.equal(schema.actions[0],87);
  assert.equal(f.session.actionKeys()[0],82,'PURE_CANDIDATE_CANNOT_ADOPT_FOLLOW');
  f.session.adoptConfirmedTouchBindings(b,schema,'op','candidate','token');assert.equal(f.session.actionKeys()[0],87);
  assert.equal(f.session.follow,false);return {old:before[0],candidate:schema.actions[0],adopted:f.session.actionKeys()[0]};}
/**
 * 三个真实即时失权边缘按同一状态序列检查：Applied→同步Waiting→真实维护后Applied。
 * 只读报告不触发Native/sensor；off已确认关闭和未确认退休分开，外部off回入只能留下
 * 新定义/新epoch自己的报告，旧setter续体不得把它覆盖成旧Applied或Waiting。
 */
function lifecycleProgress(overrides={}){
  const results={};
  for(const boundary of ['setActive','setGrabbed','setTouchAdmission']){
    const reason=boundary==='setActive'?'SourceInactive':'InputNotAdmitted';
    const label='GYRO_'+boundary.toUpperCase()+'_IMMEDIATE_WAIT';
    const read=f=>f.store.inputConfigurationDelivery.status().find(s=>s.name==='touch-gyro');
    const start=()=>{const f=fixture(overrides);f.publish(f.profile(1));f.confirm();f.tick();assert.equal(read(f).pending,false);return f;};
    const f=start(),original=read(f),old=f.callbacks.at(-1),originalLease=f.begins.at(-1).t;
    let maintenanceCalls=0;f.native.maintainTouchInput=()=>{maintenanceCalls++;return true;};
    const beginCount=f.begins.length,retireCount=f.retires.length,sensorCount=f.callbacks.length;
    f.session[boundary](false);
    const closed=read(f);
    assert.equal(f.session.gyroscopeStatus(),'idle');
    assert.equal(closed.stage,'Waiting',label);assert.equal(closed.pending,true,label);assert.equal(closed.reason,reason);
    assert.equal(closed.operationId,original.operationId,'资格变化不借后来定义改写原operation');
    assert.equal(f.begins.length,beginCount);assert.equal(f.retires.length,retireCount+1);assert.equal(f.retires.at(-1),originalLease);
    assert.equal(maintenanceCalls,0,'即时报告修正不新增Native维护');
    const attempts=f.retires.length,beforeSamples=f.submits.length;
    read(f);f.session.gyroscopeStatus();
    old({x:0,y:1,z:0,timestamp:2e9});old({x:0,y:1,z:0,timestamp:2e9+20000000});
    assert.equal(f.retires.length,attempts);assert.equal(f.submits.length,beforeSamples);assert.equal(f.callbacks.length,sensorCount);
    f.session[boundary](true);assert.equal(read(f).pending,true,'重新获得资格本身不伪造采用完成');
    f.tick();const restored=read(f);assert.equal(restored.pending,false);assert.equal(restored.stage,'Applied');
    assert.equal(restored.operationId,original.operationId);assert.equal(f.begins.length,beginCount+1);
    assert.ok(Math.abs(f.sample()+7.2)<1e-8,'恢复从新sensor基线真实采用原政策');

    // off的完成是原lease已关闭。资格关闭不能撤回该完成，也不能新增订阅或Native动作。
    const off=f.profile(2);off.touch.gyroscopeMode='off';f.publish(off);f.tick();
    const offApplied=read(f);assert.equal(offApplied.pending,false);assert.equal(offApplied.stage,'Applied');
    const offBegins=f.begins.length,offRetires=f.retires.length,offMaintenance=maintenanceCalls;
    f.session[boundary](false);const offClosed=read(f);
    assert.equal(offClosed.stage,'Applied','off已确认关闭保留其完成事实');assert.equal(offClosed.pending,false);
    assert.equal(offClosed.operationId,offApplied.operationId);assert.equal(f.begins.length,offBegins);
    assert.equal(f.retires.length,offRetires);assert.equal(maintenanceCalls,offMaintenance);
    f.session[boundary](true);f.tick();assert.equal(read(f).pending,false);assert.equal(f.begins.length,offBegins);

    // 切off但原Native退休未知时只能保Waiting，失权与恢复不得把原墓碑盖成Clean。
    const waiting=start(),retiredToken=waiting.begins.at(-1).t,waitingBegins=waiting.begins.length;
    waiting.retire(false);const pendingOff=waiting.profile(2);pendingOff.touch.gyroscopeMode='off';waiting.publish(pendingOff);waiting.tick();
    const offPending=read(waiting);assert.equal(offPending.pending,true);assert.equal(waiting.session.gyroscopeStatus(),'retirement-pending');
    waiting.session[boundary](false);assert.equal(read(waiting).pending,true);assert.equal(read(waiting).operationId,offPending.operationId);
    waiting.session[boundary](true);waiting.tick();assert.equal(read(waiting).pending,true);assert.equal(waiting.begins.length,waitingBegins);
    assert.equal(waiting.retires.every(token=>token===retiredToken),true,'未知关闭只重试原Native token');
    waiting.retire(true);waiting.tick();assert.equal(read(waiting).pending,false);assert.equal(waiting.begins.length,waitingBegins);

    // 平台off同步发布后来定义；旧setter只能先写原缓存，返回后不能覆盖后来operation。
    const reentrant=start();let changed=false;
    reentrant.sensorEdge.onUnregister=()=>{if(!changed){changed=true;reentrant.publish(reentrant.profile(3));}};
    const previousOperation=read(reentrant).operationId;reentrant.session[boundary](false);const newer=read(reentrant);
    assert.equal(newer.targetProfileRevision,3);assert.notEqual(newer.operationId,previousOperation);
    assert.equal(newer.stage,'Waiting');assert.equal(newer.reason,reason);assert.equal(newer.pending,true);
    reentrant.session[boundary](true);reentrant.tick();assert.equal(read(reentrant).appliedProfileRevision,3);
    assert.ok(Math.abs(reentrant.sample()+21.6)<1e-8);

    // 平台off同步退休来源epoch，迟到setter也不得把已退休报告改回Waiting。
    const retired=start();retired.sensorEdge.onUnregister=()=>retired.session.stopSources();
    retired.session[boundary](false);assert.equal(read(retired),undefined);
    assert.equal(retired.session.gyroProgress.stage,'Retired','只读核生产缓存，未写私有状态');
    retired.session[boundary](false);assert.equal(retired.session.gyroProgress.stage,'Retired');
    results[boundary]={original,closed,restored,offApplied,offClosed,offPending,newer,retiredStage:retired.session.gyroProgress.stage};
  }
  return results;
}
/** 日志失败只失去观察，不改变sensor.on成功或失败的真实回执，也不驱动再次订阅。 */
function observerFailure(overrides={}){
  const f=fixture(overrides);let infoCalls=0;
  f.logEdge.info=()=>{infoCalls++;throw Error('controlled subscribe info failure');};
  f.publish(f.profile(1));f.confirm();f.tick();
  assert.equal(f.session.gyroscopeStatus(),'active','INFO_FAILURE_CANNOT_RETIRE_SUCCESSFUL_SENSOR');
  assert.equal(f.store.inputConfigurationDelivery.status().find(s=>s.name==='touch-gyro').pending,false);
  assert.equal(f.callbacks.length,1);assert.equal(f.offCalls.length,0);assert.equal(f.retires.length,0);
  f.tick();f.tick();assert.equal(f.callbacks.length,1);assert.equal(infoCalls,1,'日志失败不触发新sensor.on或重写成功日志');
  assert.ok(Math.abs(f.sample()+7.2)<1e-8);
  const unavailable=fixture(overrides);let warnCalls=0;
  unavailable.sensorEdge.onRegister=()=>{throw Error('controlled sensor.on failure');};
  unavailable.logEdge.warn=()=>{warnCalls++;throw Error('controlled configure warning failure');};
  assert.doesNotThrow(()=>{unavailable.publish(unavailable.profile(1));unavailable.confirm();unavailable.tick();});
  const progress=unavailable.store.inputConfigurationDelivery.status().find(s=>s.name==='touch-gyro');
  assert.equal(progress.reason,'unavailable','CONFIGURE_WARN_FAILURE_CANNOT_CHANGE_OUTCOME');assert.equal(progress.pending,true);
  assert.equal(unavailable.callbacks.length,1,'失败日志不能清空签名使既有维护盲重试sensor.on');assert.equal(warnCalls,1);
  assert.equal(unavailable.activeCallbacks.size,0);assert.equal(unavailable.offCalls[0].callback,unavailable.callbacks[0]);
  return {infoCalls,onCalls:f.callbacks.length,successfulStatus:f.session.gyroscopeStatus(),warnCalls,unavailableProgress:progress};
}
/** Native退休真实确认而OS off未知时只保原callback；恢复必须先具名off完成再允许新订阅。 */
function platformUnsubscription(overrides={}){
  const f=fixture(overrides);f.publish(f.profile(1));f.confirm();f.tick();
  const original=f.callbacks.at(-1),token=f.begins.at(-1).t,beginCount=f.begins.length,onCount=f.callbacks.length;
  let failing=true,warnCalls=0;
  f.sensorEdge.onUnregister=(_id,cb)=>{assert.equal(cb,original,'未知off只重试原callback');if(failing)throw Error('controlled platform off failure');};
  f.logEdge.warn=()=>{warnCalls++;throw Error('controlled unsubscribe warning failure');};
  const off=f.profile(2);off.touch.gyroscopeMode='off';f.publish(off);
  const read=()=>f.store.inputConfigurationDelivery.status().find(s=>s.name==='touch-gyro');
  const pendingOff=read();assert.equal(pendingOff.pending,true,'OS_OFF_UNKNOWN_CANNOT_CONFIRM_CLOSED');
  assert.equal(pendingOff.stage,'Waiting');assert.equal(pendingOff.reason,'unsubscribe-pending');
  assert.equal(f.session.gyroscopeStatus(),'unsubscribe-pending');assert.deepEqual(f.retires,[token],'OS失败仍退休原Native');
  assert.equal(f.activeCallbacks.has(original),true,'fixture在异常off后保原OS注册，未推断异常代表取消');
  const readAttempts=f.offCalls.length,beforeSamples=f.submits.length;
  read();f.session.gyroscopeStatus();assert.equal(f.offCalls.length,readAttempts,'只读查询不推进off');
  original({x:0,y:1,z:0,timestamp:2e9});original({x:0,y:1,z:0,timestamp:2e9+20000000});assert.equal(f.submits.length,beforeSamples);
  f.tick();f.tick();assert.equal(read().pending,true);assert.equal(f.callbacks.length,onCount);assert.equal(f.begins.length,beginCount);
  assert.equal(f.offCalls.every(call=>call.id===2&&call.callback===original),true);assert.equal(warnCalls,1,'原callback诊断失败不反复输出');
  f.publish(f.profile(3));f.tick();assert.equal(f.callbacks.length,onCount,'开启定义也须等原callback退休');assert.equal(f.begins.length,beginCount);
  const restoredOff=f.profile(1);restoredOff.profileRevision=4;restoredOff.touch.gyroscopeMode='off';f.publish(restoredOff);failing=false;f.tick();
  const closed=read();assert.equal(closed.pending,false);assert.equal(closed.stage,'Applied');assert.equal(f.session.gyroscopeStatus(),'idle');
  assert.equal(f.activeCallbacks.size,0);assert.equal(f.callbacks.length,onCount);assert.equal(f.begins.length,beginCount);
  const reopened=f.profile(2);reopened.profileRevision=5;f.publish(reopened);f.tick();
  assert.equal(read().pending,false);assert.equal(f.callbacks.length,onCount+1);assert.equal(f.begins.length,beginCount+1);
  assert.notEqual(f.callbacks.at(-1),original);assert.equal(f.activeCallbacks.has(original),false);
  const afterRestore=f.submits.length;original({x:0,y:1,z:0,timestamp:3e9});original({x:0,y:1,z:0,timestamp:3e9+20000000});
  assert.equal(f.submits.length,afterRestore);assert.ok(Math.abs(f.sample()+14.4)<1e-8);
  return {pendingOff,closed,warnCalls,offAttempts:f.offCalls.length,allRetriedOriginal:f.offCalls.every(call=>call.callback===original),onCount:f.callbacks.length};
}
function platformCleanup(overrides={}){return {observerFailure:observerFailure(overrides),platformUnsubscription:platformUnsubscription(overrides)};}
/** 实际Session→gyro→维护scope组合：无前端时保留并回收原失败资源，不建立新订阅。 */
function stoppedSources(overrides={}){
 const results={};
 for(const mode of ['host','frontend','background']){
  const f=fixture(overrides);f.publish(f.profile(1));f.confirm();f.tick();
  const old=f.callbacks.at(-1),token=f.begins.at(-1).t,beginCount=f.begins.length;
  let offFails=true;
  f.sensorEdge.onUnregister=(_id,cb)=>{assert.equal(cb,old);if(offFails)throw Error('原callback暂时无法退订');};
  f.retire(false);
  let receipt;
  if(mode==='host')receipt=f.maintenance.stopEntryTouchInputMaintenance(f.scope);
  else if(mode==='frontend')assert.equal(f.session.stopSources(),false);
  else f.session.setActive(false);
  assert.equal(f.timers.size,0,'所有停源路径立即撤16ms时钟');
  assert.equal(f.activeCallbacks.has(old),true,'off异常不能冒充订阅已经消失');
  const before=f.submits.length;old({x:0,y:1,z:0,timestamp:4e9});old({x:0,y:1,z:0,timestamp:4e9+20000000});
  assert.equal(f.submits.length,before,'尚未退订的原callback已失去游戏输入资格');
  let later,laterStops=0;
  if(receipt){
   assert.equal(receipt.complete(),false);assert.equal(receipt.waiting(),true);
   later=f.maintenance.startEntryTouchInputMaintenance();
   assert.equal(f.maintenance.registerEntryTouchInputMaintenanceSource(later,f.session),false,'旧对象不能取得新scope');
   f.maintenance.registerEntryTouchInputMaintenanceSource(later,{stopSources(){laterStops++;return true;},reconcileStoppedSources(){return true;}});
   assert.equal(receipt.reconcile(),false);
  }
  offFails=false;f.retire(true);
  if(receipt)assert.equal(receipt.reconcile(),true);
  else assert.equal(f.maintenance.reconcileEntryTouchInputMaintenanceCleanup(f.scope),true);
  assert.equal(f.activeCallbacks.size,0,'FRONTEND_STOP_MUST_RETAIN_PENDING_FOR_HOST');
  assert.equal(f.session.gyro.stoppedCleanupComplete(),true);
  assert.ok(f.retires.every(value=>value===token));assert.equal(f.begins.length,beginCount);
  assert.equal(laterStops,0,'旧清理回执不停止后来会话');
  if(later)f.maintenance.stopEntryTouchInputMaintenance(later);
  else f.maintenance.stopEntryTouchInputMaintenance(f.scope);
  results[mode]={offAttempts:f.offCalls.length,retireAttempts:f.retires.length,newSubscriptions:0};
 }
 // 在真实sensor.on原调用栈停止宿主：没有等到configure退栈前，receipt不能提前完成。
 const f=fixture(overrides);let receipt;
 f.sensorEdge.onRegister=()=>{receipt=f.maintenance.stopEntryTouchInputMaintenance(f.scope);assert.equal(receipt.complete(),false);};
 f.publish(f.profile(1));f.confirm();f.tick();
 assert.ok(receipt);assert.equal(receipt.reconcile(),true);assert.equal(f.activeCallbacks.size,0);
 assert.equal(f.session.gyro.stoppedCleanupComplete(),true);assert.equal(f.begins.length,1);
 results.inflightSensorOn={completedOnlyAfterReturn:true};
 return results;
}
const cases={pending,rejected,restore,reentry,stopDuringSensor,offAndLogFailure,retirementAndLogFailure,pureFollow,lifecycleProgress,platformCleanup,stoppedSources};const selected=process.argv[2]??'all';
const output=workspacePath('run','gyro-policy-next',selected+'-'+process.pid);fs.mkdirSync(output,{recursive:true});
try{const results={};for(const[name,run]of Object.entries(cases))if(selected==='all'||selected===name)results[name]=run();
  if(selected==='all'){
    // 撤掉实际Session的Pending登记保留，真实维护链应再也找不到旧off资源，命中资源断言。
    let lostPending;
    try { stoppedSources({[sessionPath]:source=>source.replace(
      'if (this.gyro.stoppedCleanupComplete() && this.originLease!==undefined)',
      'if (this.originLease!==undefined)')}); } catch(error) { lostPending=error; }
    assert.ok(lostPending instanceof assert.AssertionError &&
      lostPending.message.includes('FRONTEND_STOP_MUST_RETAIN_PENDING_FOR_HOST'),'原对象撤登记负控须击中真实资源未回收');
    const negatives=[['premature-candidate-gyro',rejected,'REJECTED_CANDIDATE_CANNOT_ADOPT_GYRO_B',s=>s.replace('const options: TouchConfiguration = normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()','const options: TouchConfiguration = normalizeTouchPreferences(profile.touch) ?? new TouchConfiguration()\n    this.gyroOptions=options')],
      ['void-as-applied',pending,'GYRO_PENDING_MUST_HAVE_OWN_RECEIPT',s=>s.replace('const completed: boolean=this.gyro.configure(gyroEnabled,this.gyroOptions,this.rotation,values[12])','this.gyro.configure(gyroEnabled,this.gyroOptions,this.rotation,values[12])\n      const completed: boolean=true')]];
    results.negatives=[];for(const[name,run,label,mutation]of negatives){let failure;try{run({[sessionPath]:mutation});}catch(e){failure=e;}
      assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(label),name+'需命中行为断言');results.negatives.push({name,assertion:label,failure:failure.message});}
    // 撤回平台异常诊断隔离，执行同一完整生产清理方法，证明日志异常仍不能跳过Native退休。
    const oldStop=s=>{
      const warning="this.reportWarning('Touch gyroscope unsubscribe failed: %{public}s',error)";
      assert.equal(s.split(warning).length-1,1,'原平台诊断隔离必须存在且唯一');
      return s.replace(warning,"hilog.warn(0x0000,'GameControls','Touch gyroscope unsubscribe failed: %{public}s',String(error))");
    };
    const oldRetireLog=s=>s.replace("this.reportWarning('Touch gyroscope lease retirement pending: %{public}s',error)",
      "hilog.warn(0x0000,'GameControls','Touch gyroscope lease retirement pending: %{public}s',String(error))");
    for(const[name,run,label,mutation]of [['off-log-stop-before',offAndLogFailure,'OFF_LOG_FAILURE_CANNOT_SKIP_NATIVE_RETIRE',oldStop],
      ['retire-log-before',retirementAndLogFailure,'RETIRE_LOG_FAILURE_CANNOT_SKIP_PENDING_RECEIPT',oldRetireLog]]){
      let failure;try{run({[gyroPath]:mutation});}catch(e){failure=e;}
      assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(label),name+'需命中真实停止行为断言');
      results.negatives.push({name,assertion:label,failure:failure.message});
    }
  }
  if(selected==='all'||selected==='lifecycleProgress'){
    results.negatives??=[];
    for(const boundary of ['setActive','setGrabbed','setTouchAdmission']){
      // 逐一撤回原setter的缓存前移，执行同一生产方法；反控必须命中该边缘的行为断言。
      const reason=boundary==='setActive'?'SourceInactive':'InputNotAdmitted';
      const leading=boundary==='setActive'?'    if (!active) {':boundary==='setGrabbed'?'    if (!grabbed) {':'    if (!admitted) {';
      const anchor=leading+"\n      this.waitForGyroAdmission('"+reason+"')";
      const mutation=s=>{const source=s.replaceAll('\r\n','\n');assert.equal(source.split(anchor).length-1,1,'撤回必须命中唯一原setter');return source.replace(anchor,leading);};
      const label='GYRO_'+boundary.toUpperCase()+'_IMMEDIATE_WAIT';let failure;
      try{lifecycleProgress({[sessionPath]:mutation});}catch(error){failure=error;}
      assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(label),boundary+'撤回需命中即时报告断言');
      results.negatives.push({name:'stale-progress-'+boundary,assertion:label,failure:failure.message});
    }
  }
  if(selected==='all'||selected==='platformCleanup'){
    results.negatives??=[];
    const unsafeInfo=s=>{const source=s.replaceAll('\r\n','\n');
      const anchor="    try { hilog.info(0x0000,'GameControls','Touch gyroscope subscribed; mode=%{public}s',options.gyroscopeMode) }\n    catch (_) { /* 诊断失败不退休已成功的订阅，也不重新sensor.on。 */ }";
      assert.equal(source.split(anchor).length-1,1,'原成功日志隔离必须存在且唯一');
      return source.replace(anchor,"    hilog.info(0x0000,'GameControls','Touch gyroscope subscribed; mode=%{public}s',options.gyroscopeMode)");};
    const unsafeWarning=s=>{const anchor="this.reportWarning('Touch gyroscope unavailable: %{public}s',error)";
      assert.equal(s.split(anchor).length-1,1);return s.replace(anchor,"hilog.warn(0x0000,'GameControls','Touch gyroscope unavailable: %{public}s',String(error))");};
    const forgottenCallback=s=>{const source=s.replaceAll('\r\n','\n'),anchor="    } catch (error) {\n      if (!this.unsubscribeWarningEmitted)";
      assert.equal(source.split(anchor).length-1,1,'原callback失败保留边缘必须唯一');
      return source.replace(anchor,"    } catch (error) {\n      this.pendingUnsubscription=undefined\n      if (!this.unsubscribeWarningEmitted)");};
    for(const[name,run,label,mutation]of [['subscribe-info-controls-outcome',observerFailure,'INFO_FAILURE_CANNOT_RETIRE_SUCCESSFUL_SENSOR',unsafeInfo],
      ['configure-warning-controls-outcome',observerFailure,'CONFIGURE_WARN_FAILURE_CANNOT_CHANGE_OUTCOME',unsafeWarning],
      ['forget-off-unknown-callback',platformUnsubscription,'OS_OFF_UNKNOWN_CANNOT_CONFIRM_CLOSED',forgottenCallback]]){
      let failure;try{run({[gyroPath]:mutation});}catch(error){failure=error;}
      assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(label),name+'需命中真实生产行为断言');
      results.negatives.push({name,assertion:label,failure:failure.message});
    }
  }
  const after=Object.fromEntries(bound.map(p=>[p,sha(p)]));assert.deepEqual(after,before,'实际ETS依赖运行期间不可漂移');
  fs.writeFileSync(path.join(output,'result.json'),JSON.stringify({startedAt,finishedAt:new Date().toISOString(),sourcesBefore:before,sourcesAfter:after,
    drift:[],results,scope:'actual production ETS + controlled sensor/Native; no hardware or Native owner proof'},null,2)+'\n');console.log('GYRO_POLICY_PASS '+Object.keys(results).join(',')+' evidence='+output);}
catch(error){fs.writeFileSync(path.join(output,'failure.log'),error.stack+'\n');console.error(error.stack);process.exitCode=1;}

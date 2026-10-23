/**
 * 设备应用连接的源绑定宿主验收。完整装载Registry/Monitor/Manager/Runtime/SourceClient生产类，
 * 仅替换SDK设备清单Promise、Native端口回执和计时器。所有贡献归约、资格、轴读取与压力墓碑
 * 均由生产正文执行；此测试不声明Native设备generation、真实consumer或OS队列来源已被证明。
 * 直接执行：node scripts/test-device-connection-runtime.mjs。收据由workspace helper外置，
 * 可用AMCL_RUN_DIR选择仓外目录；不改变JAVA_HOME、SDK、用户临时目录或任何生产文件。
 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {environment as productionEnvironment} from './lib/ets-runtime-fixture.mjs';
import {workspacePath} from './lib/workspace-paths.mjs';

const root=path.resolve(import.meta.dirname,'..');
const prefix='gamecontrol/src/main/ets/',PREFIX=prefix,noop=()=>{};
const flush=async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
const sourcePaths=['gamecontrol/Index.ets',...['InputDeviceConnectionLease.ets','InputDeviceMonitor.ets','GamepadManager.ets','GameInputRuntime.ets','SourceControlClient.ets'].map(name=>prefix+name)];
const sha=relative=>createHash('sha256').update(fs.readFileSync(path.join(root,relative))).digest('hex');
const before=Object.fromEntries(sourcePaths.map(relative=>[relative,sha(relative)]));
const started=new Date(),timezone=Intl.DateTimeFormat().resolvedOptions().timeZone;
const results=[],fixtures=[];

/** 每场拥有真实生产模块的独立缓存；mutation只改内存副本并由原fixture核锚点/语法。 */
function environment(imports={},mutations={}) {
  const env=productionEnvironment({imports,sourceOverrides:mutations});
  return {...env,timers:env.timer};
}

/** 外部出口检查置于生产调用以外，防异常处理把禁用出口误作普通拒绝后放过。 */
async function test(name,fn) {
  const firstFixture=fixtures.length;await fn();
  for(const f of fixtures.slice(firstFixture))assert.deepEqual(f.rawCalls,[],name+': scoped path used raw outlet');
  results.push(name);console.log('PASS '+name);
}

/** 原SDK Promise完成次序可控，Monitor flags/lease/ticket一律由真实候选决定。 */
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}


await test('exact object, known hardware0 vs explicit missing compat0, invalid and remove/inventory fencing',()=>{
 const env=environment(),m=env.load(prefix+'InputDeviceConnectionLease.ets'),r=new m.InputDeviceConnectionRegistry();
 const zero=r.observeAdd(0).originalConnection,c=r.capture(new m.InputDeviceIdentityEvidence(0,false,true));
 assert.equal(r.capture(new m.InputDeviceIdentityEvidence(0,true,false)).status,'NativePending');assert.notEqual(c.connection,zero);
 assert.equal(r.reader.allowsLegacyDeviceField(zero),false);assert.equal(r.reader.allowsLegacyDeviceField(c.connection),true);
 assert.equal(r.capture(new m.InputDeviceIdentityEvidence(NaN,false,true)).status,'Invalid');
 const copied=new m.InputDeviceConnectionLease(new m.InputDeviceIdentityEvidence(0,true,false),zero.applicationScope);assert.equal(r.reader.accepts(copied),false);
 const first=r.observeAdd(7).originalConnection,ticket=r.beginInventory();r.retireCurrent(7);assert.equal(r.acceptsInventory(ticket),false);
 const later=r.beginInventory();assert.equal(r.inventoryConnection(later,7),undefined);const second=r.observeAdd(7).originalConnection;
 assert.notEqual(first,second);assert.equal(r.reader.accepts(first),false);assert.equal(r.reader.accepts(second),true);
});

await test('real Source client inflight retire/reset/public token/release reentry and pending tombstone',()=>{
 const env=environment(),m=env.load(prefix+'InputDeviceConnectionLease.ets'),{SourceControlClient}=env.load(prefix+'SourceControlClient.ets');
 const r=new m.InputDeviceConnectionRegistry(),old=r.observeAdd(7).originalConnection;let client,next=0,allow=false,inside=false,reset=false;const active=new Set(),released=[];
 const port={acquire:(source,device,control,codes)=>{const token=String(++next);active.add(token);if(reset){active.clear();client.dropAfterNativeReset();}else client.releaseConnection(old);return token;},
  release:token=>{released.push(token);if(!inside){inside=true;client.reconcileRetirements();inside=false;}if(!allow)return false;active.delete(token);return true;}};
 client=new SourceControlClient(2,port,r.reader);assert.equal(client.acquireForConnection(old,'A',[65]),'');assert.deepEqual([...active],['1']);assert.equal(released.length,1,'reentrant cleanup cannot recursively release');
 r.retireCurrent(7);const fresh=r.observeAdd(7).originalConnection;port.acquire=(s,d,c,codes)=>{const t=String(++next);active.add(t);return t;};
 assert.equal(client.acquireForConnection(fresh,'A',[65]),'2');allow=true;client.reconcileRetirements();assert.deepEqual([...active],['2']);
 assert.equal(client.releaseToken('2'),true);assert.deepEqual([...active],[]);assert.equal(client.acquireForConnection(fresh,'A',[65]),'3');
 client.releaseConnection(fresh);reset=true;const third=r.observeAdd(8).originalConnection;
 port.acquire=(s,d,c,codes)=>{const t=String(++next);active.add(t);active.clear();client.dropAfterNativeReset();return t;};
 assert.equal(client.acquireForConnection(third,'A',[65]),'');assert.equal(client.releaseConnection(third),true);
});

await test('real Monitor list await and sync detail reentry never revive removed or bind new sameid',async()=>{
 let listener;const pending=[];let detailHook=noop;const sdk={on:(name,fn)=>listener=fn,getDeviceList:()=>{const d=deferred();pending.push(d);return d.promise;},getDeviceInfoSync:id=>{detailHook(id);return {sources:['gamepad']};}};
 const env=environment({'@ohos.multimodalInput.inputDevice':{default:sdk}}),monitor=env.load(prefix+'InputDeviceMonitor.ets').getInputDeviceMonitor();
 monitor.ensureStarted();pending.shift().resolve([7]);await flush();const old=monitor.captureConnection(7,true,false).connection;assert.ok(old);
 let removed;monitor.addConnectionListener(event=>{if(!event.added)removed=event.originalConnection;});listener({type:'remove',deviceId:7});pending.shift().resolve([7]);await flush();
 assert.equal(removed,old);assert.equal(monitor.connectionReader().accepts(old),false);assert.equal(monitor.captureConnection(7,true,false).connection,undefined);
 listener({type:'add',deviceId:7});const fresh=monitor.captureConnection(7,true,false).connection;assert.notEqual(fresh,old);
 detailHook=id=>{detailHook=noop;listener({type:'remove',deviceId:id});listener({type:'add',deviceId:id});};pending.shift().resolve([7]);await flush();
 assert.equal(monitor.connectionReader().accepts(fresh),false);assert.equal(monitor.sourcesForConnection(fresh),undefined);
 assert.notEqual(monitor.captureConnection(7,true,false).connection,fresh);
});

await test('real Runtime axis fact freezes eight values and original activation across beforeSample/old timer',()=>{
 const env=environment(),m=env.load(prefix+'InputDeviceConnectionLease.ets'),{GamepadManager}=env.load(prefix+'GamepadManager.ets'),{GameInputRuntime}=env.load(prefix+'GameInputRuntime.ets');
 const registry=new m.InputDeviceConnectionRegistry(),connection=registry.observeAdd(7).originalConnection,calls=[];
 const cfg={enabled:true,leftStick:'none',rightStick:'look',buttonMap:{R2:{kind:'key',code:65}},stickDeadZone:0,lookScale:1};
 const emitter={lookExecutionMode:'neutral-rate-v1',emitKey:noop,emitMouse:noop,emitScroll:noop,emitLookDelta:noop,
  emitControlForConnection:(lease,id,code,action)=>{calls.push(['control',lease,id,code,action]);return true;},
  emitLookVelocityForConnection:(lease,child,x,y)=>{calls.push(['velocity',lease,child,x,y]);return true;},
  retireLookForConnection:(lease,child)=>{calls.push(['retire',lease,child]);return true;},advanceLookExecution:()=>{calls.push(['advance']);return true;}};
 const pad=new GamepadManager(cfg,emitter,registry.reader);let before=noop;const runtime=new GameInputRuntime(pad,()=>100,noop,()=>before());
 const store={addInputConfigurationListener:fn=>fn({gamepad:cfg},1),removeInputConfigurationListener:noop,reconcileInputConfiguration:noop};
 runtime.start(store);runtime.setState(true,true);
 let reads=0;const axis=new Map([[2,.5],[4,0]]);const fact=runtime.captureAxisForConnection(connection,which=>{reads++;return axis.get(which);});
 assert.equal(reads,8);axis.set(4,1);runtime.handleAxisFact(fact);assert.equal(calls.some(x=>x[0]==='control'),false);
 assert.ok(calls.some(x=>x[0]==='velocity'));assert.ok(env.timers.size>0);
 const oldTimer=[...env.timers.values()][0].fn;runtime.setState(false,false);runtime.setState(true,true);calls.length=0;oldTimer();assert.equal(calls.length,0);
 const second=runtime.captureAxisForConnection(connection,which=>which===4?1:0);before=()=>{runtime.setState(false,false);runtime.setState(true,true);};
 runtime.handleAxisFact(second);assert.equal(calls.some(x=>x[0]==='control'),false,'beforeSample reentry does not authorize old axis in new activation');
 const zero=registry.observeAdd(0).originalConnection;assert.equal(runtime.captureAxisForConnection(zero,()=>1),undefined,'known0 NativePending cannot claim a mapped output');
});

await test('scope/client safe MAX without reuse, actual UTF8 budget and called-unknown acquire remains pending',()=>{
 const env=environment({}, {[prefix+'InputDeviceConnectionLease.ets']:s=>s.replace('let nextApplicationScope: number = 1','let nextApplicationScope: number = Number.MAX_SAFE_INTEGER'),
  [prefix+'SourceControlClient.ets']:s=>s.replace('let nextControlClientId: number = 1','let nextControlClientId: number = Number.MAX_SAFE_INTEGER')});
 const m=env.load(prefix+'InputDeviceConnectionLease.ets'),r=new m.InputDeviceConnectionRegistry();const last=r.observeAdd(1).originalConnection;
 assert.equal(last.applicationScope,Number.MAX_SAFE_INTEGER);assert.equal(r.observeAdd(2).originalConnection,undefined);
 assert.equal(r.capture(new m.InputDeviceIdentityEvidence(2,true,false)).status,'Exhausted');
 const {SourceControlClient}=env.load(prefix+'SourceControlClient.ets'),client=new SourceControlClient(2,{acquire:()=>'',release:()=>true},r.reader);
 assert.throws(()=>new SourceControlClient(2,{acquire:()=>'',release:()=>true},r.reader),/exhausted/);
 const normal=environment(),types=normal.load(prefix+'InputDeviceConnectionLease.ets'),registry=new types.InputDeviceConnectionRegistry();const lease=registry.observeAdd(7).originalConnection;
 const Client=normal.load(prefix+'SourceControlClient.ets').SourceControlClient;let acquires=0;
 // 边界先记录真实已接受副作用再抛异常；空串不代表Native无持有，Client不能猜token补发。
 const boundaryHeld=new Set();
 const unknown=new Client(2,{acquire:()=>{acquires++;boundaryHeld.add('undisclosed-native-token');throw Error('accepted result unknown');},release:()=>{throw Error('must not guess unknown token');}},registry.reader);
 assert.equal(unknown.acquireForConnection(lease,'A',[65]),'');assert.equal(unknown.reconcileRetirements(),false);
 assert.equal(unknown.acquireForConnection(lease,'A',[65]),'');assert.equal(acquires,1);assert.equal(boundaryHeld.size,1);
 // 先发生边界真正RESET，再通知Client对账；仅调用helper不能伪造Native已经撤销的事实。
 boundaryHeld.clear();unknown.dropAfterNativeReset();assert.equal(unknown.reconcileRetirements(),true);
 const budget=new Client(2,{acquire:(s,d,name)=>{acquires++;assert.ok(Buffer.byteLength(name,'utf8')<=192);return 'x';},release:()=>true},registry.reader);
 assert.equal(budget.acquireForConnection(lease,'界'.repeat(100),[65]),'');assert.equal(budget.acquireForConnection(lease,'\ud800',[65]),'');
 assert.equal(budget.acquireForConnection(lease,'ok',[65]),'x');
});

/** 每组有独立模块表/Registry；native记录只证明应用出口，不能称consumer cache或游戏采用。 */
function managerFixture(){
  const env=environment();
  const pure=env.load(PREFIX+'InputDeviceConnectionLease.ets');
  const f={env,pure,rawCalls:[],manager:env.load(PREFIX+'GamepadManager.ets'),client:env.load(PREFIX+'SourceControlClient.ets'),registry:new pure.InputDeviceConnectionRegistry()};
  fixtures.push(f);return f;
}
function open(f,id){return f.registry.observeAdd(id).originalConnection;}
function axis(f,connection,values){f.pad.handleAxisForConnection(connection,new f.pure.GamepadAxisSnapshot(code=>values.get(code)??0));}
/** 禁止出口必须记录并返回确定成功，再在调用外断言；生产catch不能吞掉测试失败。 */
function ordinaryEmitter(f){
  const record=kind=>(...values)=>{f.rawCalls.push([kind,...values]);return true;};
  return {emitKey:record('key'),emitMouse:record('mouse'),emitScroll:record('scroll'),emitLookDelta:record('look')};
}


await test('scoped A/B same-code contributors; retire A preserves B; new same ID rejects old snapshot',()=>{
  const f=managerFixture(),a=open(f,7),b=open(f,8),active=new Map();let next=1;
  const client=new f.client.SourceControlClient(2,{acquire:(source,device,control,codes)=>{const token=String(next++);active.set(token,{device,control,codes});return token;},release:token=>{active.delete(token);return true;}},f.registry.reader);
  f.pad=new f.manager.GamepadManager(undefined,{...ordinaryEmitter(f),emitControlForConnection:(lease,control,code,action)=>action===1?client.acquireForConnection(lease,control,[code]).length>0:client.releaseForConnection(lease,control),releaseConnectionControls:lease=>client.releaseConnection(lease),reconcileConnectionControls:()=>client.reconcileRetirements()},f.registry.reader);
  axis(f,a,new Map([[f.manager.AXIS_ABS_Y,-1]]));axis(f,b,new Map([[f.manager.AXIS_ABS_Y,-1]]));
  assert.equal(active.size,2);assert.equal([...f.pad.outputAggregates.values()][0].contributors.size,2);
  f.registry.retireCurrent(7);assert.equal(f.pad.releaseConnection(a),true);assert.equal(active.size,1);assert.equal([...active.values()][0].device,8);
  const fresh=open(f,7);axis(f,fresh,new Map([[f.manager.AXIS_ABS_Y,-1]]));assert.equal(active.size,2);
  const before=next;axis(f,a,new Map([[f.manager.AXIS_ABS_Y,-1]]));f.pad.handleButtonForConnection(a,2301,true);assert.equal(next,before);
  assert.equal(f.pad.hasConnectionState(a),false);assert.equal(f.pad.hasConnectionState(fresh),true);
});

await test('true PRESS synchronous retire keeps exact pending UP under pressure without a live aggregate',()=>{
  const f=managerFixture(),old=open(f,7),active=new Map(),calls=[];let first=true,releaseFails=true;
  f.pad=new f.manager.GamepadManager(undefined,{...ordinaryEmitter(f),emitControlForConnection:(lease,control,code,action)=>{
    calls.push([lease.applicationScope,control,code,action]);
    if(action===1){active.set(control,lease);if(first){first=false;f.registry.retireCurrent(7);f.pad.releaseConnection(old);}return true;}
    if(releaseFails)return false;active.delete(control);return true;
  }},f.registry.reader);
  f.pad.handleButtonForConnection(old,2301,true);
  assert.equal(active.size,1);assert.equal(f.pad.outputAggregates.size,0);assert.equal(f.pad.hasConnectionState(old),true);
  assert.equal(f.pad.reconcileConnectionCleanup(),false);
  const fresh=open(f,7);f.pad.handleButtonForConnection(fresh,2301,true);assert.equal(active.size,2);
  releaseFails=false;assert.equal(f.pad.reconcileConnectionCleanup(),true);assert.equal(active.size,1);assert.equal([...active.values()][0],fresh);
  assert.equal(f.pad.hasConnectionState(old),false);assert.equal([...f.pad.outputAggregates.values()][0].contributors.size,1);
  assert.equal(calls.filter(row=>row[3]===0).every(row=>row[0]===old.applicationScope),true);
});

await test('SourceClient Acquiring then Manager retire preserves original token cleanup owner and truthful Pending',()=>{
  const f=managerFixture(),old=open(f,7),active=new Set(),released=[];let allowRelease=false,client;
  client=new f.client.SourceControlClient(2,{acquire:()=>{active.add('1');f.registry.retireCurrent(7);assert.equal(f.pad.releaseConnection(old),false);return '1';},release:token=>{released.push(token);if(!allowRelease)return false;active.delete(token);return true;}},f.registry.reader);
  f.pad=new f.manager.GamepadManager(undefined,{...ordinaryEmitter(f),emitControlForConnection:(lease,control,code,action)=>action===1?client.acquireForConnection(lease,control,[code]).length>0:client.releaseForConnection(lease,control),releaseConnectionControls:lease=>client.releaseConnection(lease),reconcileConnectionControls:()=>client.reconcileRetirements()},f.registry.reader);
  f.pad.handleButtonForConnection(old,2301,true);assert.equal(f.pad.outputAggregates.size,0);assert.deepEqual([...active],['1']);assert.equal(f.pad.reconcileConnectionCleanup(),false);
  allowRelease=true;assert.equal(f.pad.reconcileConnectionCleanup(),true);assert.deepEqual([...active],[]);assert.equal(released.every(token=>token==='1'),true);
});

await test('eight axes precede emitters; native-rate reentry stops trigger and retries only original child',()=>{
  const f=managerFixture(),old=open(f,7),events=[],reads=[];let retireFails=true,rateRetires=true;
  f.pad=new f.manager.GamepadManager(undefined,{...ordinaryEmitter(f),lookExecutionMode:'neutral-rate-v1',
    emitControlForConnection:(...values)=>{events.push(['control',...values]);return true;},
    emitLookVelocityForConnection:(lease,child,x,y)=>{assert.deepEqual(reads,[0,1,2,3,4,5,6,7]);events.push(['rate',lease.applicationScope,child,x,y]);if(rateRetires){rateRetires=false;f.registry.retireCurrent(7);f.pad.releaseConnection(lease);}return true;},
    retireLookForConnection:(lease,child)=>{events.push(['retire',lease.applicationScope,child]);return !retireFails;},
    advanceLookExecution:()=>{events.push(['advance']);return true;}
  },f.registry.reader);
  const snapshot=new f.pure.GamepadAxisSnapshot(code=>{reads.push(code);return code===f.manager.AXIS_ABS_Z||code===f.manager.AXIS_ABS_GAS?1:0;});
  f.pad.handleAxisForConnection(old,snapshot);assert.equal(events.some(row=>row[0]==='control'),false);assert.equal(f.pad.outputAggregates.size,0);
  assert.equal(f.pad.hasConnectionState(old),true);const oldChild=events.find(row=>row[0]==='rate')[2];
  const before=events.length;f.pad.advanceMappedLook(1);assert.equal(events.slice(before).some(row=>row[0]==='advance'||row[0]==='rate'),false);
  const fresh=open(f,7);axis(f,fresh,new Map([[f.manager.AXIS_ABS_Z,1]]));const freshChild=events.filter(row=>row[0]==='rate').at(-1)[2];assert.notEqual(freshChild,oldChild);
  retireFails=false;f.pad.reconcileConnectionCleanup();assert.equal(f.pad.hasConnectionState(old),false);assert.equal(f.pad.hasConnectionState(fresh),true);
  assert.equal(events.filter(row=>row[0]==='retire').every(row=>row[1]===old.applicationScope&&row[2]===oldChild),true);
});

await test('known hardware0 stays NativePending; explicit missing0 is separate; scoped delta never uses raw fallback',()=>{
  const f=managerFixture(),zero=open(f,0),valid=open(f,7);let controls=0;
  f.pad=new f.manager.GamepadManager(undefined,{...ordinaryEmitter(f),emitControlForConnection:()=>{controls++;return true;}},f.registry.reader);
  assert.equal(f.pad.acceptsConnection(zero),false);f.pad.handleButtonForConnection(zero,2301,true);axis(f,zero,new Map([[f.manager.AXIS_ABS_Y,-1]]));assert.equal(controls,0);
  const compat=f.registry.capture(new f.pure.InputDeviceIdentityEvidence(0,false,true)).connection;assert.notEqual(compat,zero);assert.equal(f.pad.acceptsConnection(compat),true);
  f.pad.handleButtonForConnection(compat,2301,true);assert.equal(controls,1);
  axis(f,valid,new Map([[f.manager.AXIS_ABS_Z,1]]));f.pad.advanceMappedLook(.016,1000000);
  // 没有emitLookDeltaForConnection时保持该明确缺口，不通过无lease的emitLookDelta产生输出。
});


/** 原inventory与监听扇出由Monitor生产实现维护；观察异常不能改变原change对象。 */
await test('actual Monitor newest inventory and original remove fanout survive errors and sameid add',async()=>{
  let listener;const pending=[];
  const sdk={on:(_name,fn)=>listener=fn,getDeviceList:()=>{const next=deferred();pending.push(next);return next.promise;},getDeviceInfoSync:()=>({sources:['gamepad']})};
  const env=environment({'@ohos.multimodalInput.inputDevice':{default:sdk}});
  const monitor=env.load(prefix+'InputDeviceMonitor.ets').getInputDeviceMonitor();
  monitor.ensureStarted();pending.shift().resolve([7]);await flush();
  const original=monitor.captureConnection(7,true,false).connection;
  monitor.refreshCapability();const earlier=pending.shift();monitor.refreshCapability();const later=pending.shift();
  later.resolve([8]);await flush();
  const other=monitor.captureConnection(8,true,false).connection;
  assert.deepEqual(monitor.sourcesForConnection(other),['gamepad']);
  earlier.resolve([7]);await flush();
  assert.equal(monitor.sourcesForConnection(original),undefined,'old list cannot replace newest same-capability descriptions');
  assert.deepEqual(monitor.sourcesForConnection(other),['gamepad']);
  let fresh,observed;
  const bad=event=>{if(!event.added){monitor.removeConnectionListener(bad);listener({type:'add',deviceId:8});fresh=monitor.captureConnection(8,true,false).connection;throw Error('one observer fails');}};
  monitor.addConnectionListener(bad);
  monitor.addConnectionListener(event=>{if(!event.added)observed={connection:event.originalConnection,sources:monitor.sourcesForConnection(event.originalConnection)};});
  listener({type:'remove',deviceId:8});
  assert.equal(observed.connection,other);assert.deepEqual(observed.sources,['gamepad']);
  assert.notEqual(fresh,other);assert.equal(monitor.connectionReader().accepts(other),false);assert.equal(monitor.connectionReader().accepts(fresh),true);
  assert.equal(monitor.sourcesForConnection(other),undefined);
});

await test('real Manager reset inside acquire and new state on same lease never prune or release the new token',()=>{
  const f=managerFixture(),lease=open(f,7),active=new Set();
  const keys=f.env.load(prefix+'OhosKeyCodes.ets');let first=true,next=0,client;
  client=new f.client.SourceControlClient(2,{acquire:()=>{
    const token=String(++next);active.add(token);
    if(first){first=false;active.clear();f.pad.dropHeldStateAfterNativeReset('actual-boundary-reset');f.pad.handleButtonForConnection(lease,keys.OHOS_BUTTON_B,true);}
    return token;
  },release:token=>{active.delete(token);return true;}},f.registry.reader);
  const cfg={enabled:true,leftStick:'none',rightStick:'none',buttonMap:{A:{kind:'key',code:65},B:{kind:'key',code:66}}};
  f.pad=new f.manager.GamepadManager(cfg,{...ordinaryEmitter(f),
    emitControlForConnection:(connection,control,code,action)=>action===1?client.acquireForConnection(connection,control,[code])!=='':client.releaseForConnection(connection,control),
    releaseConnectionControls:connection=>client.releaseConnection(connection),reconcileConnectionControls:()=>client.reconcileRetirements(),
    dropControlsAfterNativeReset:()=>client.dropAfterNativeReset()},f.registry.reader);
  f.pad.handleButtonForConnection(lease,keys.OHOS_BUTTON_A,true);
  assert.deepEqual([...active],['2']);assert.equal(f.pad.hasConnectionState(lease),true);
  assert.equal(f.pad.outputAggregates.size,1);assert.equal([...f.pad.outputAggregates.values()][0].code,66);
  assert.equal(f.pad.reconcileConnectionCleanup(),true);assert.deepEqual([...active],['2']);
  f.pad.releaseConnection(lease);assert.deepEqual([...active],[]);
});

/** 同一原Runtime fact经过实际beforeSample回入；只记录出口，不复制准入实现。 */
function runtimeReentryAssertion(env) {
  const m=env.load(prefix+'InputDeviceConnectionLease.ets');
  const {GamepadManager}=env.load(prefix+'GamepadManager.ets');
  const {GameInputRuntime}=env.load(prefix+'GameInputRuntime.ets');
  const registry=new m.InputDeviceConnectionRegistry(),lease=registry.observeAdd(7).originalConnection;
  const outputs=[];
  const cfg={enabled:true,leftStick:'none',rightStick:'none',buttonMap:{R2:{kind:'key',code:65}}};
  const pad=new GamepadManager(cfg,{emitKey:()=>true,emitMouse:()=>true,emitScroll:()=>true,emitLookDelta:noop,
    emitControlForConnection:(...values)=>{outputs.push(values);return true;}},registry.reader);
  let runtime;
  runtime=new GameInputRuntime(pad,()=>100,noop,()=>{runtime.setState(false,false);runtime.setState(true,true);});
  runtime.start({addInputConfigurationListener:fn=>fn({gamepad:cfg},1),removeInputConfigurationListener:noop,reconcileInputConfiguration:noop});
  runtime.setState(true,true);
  const fact=runtime.captureAxisForConnection(lease,which=>which===4?1:0);
  runtime.handleAxisFact(fact);
  assert.equal(outputs.length,0,'old axis cannot borrow new activation after beforeSample');
}

/** 缺少scoped delta端口必须保持缺口；accepted raw调用在生产catch外仍可识别。 */
function forbiddenRawAssertion(env) {
  const m=env.load(prefix+'InputDeviceConnectionLease.ets');
  const {GamepadManager,AXIS_ABS_Z}=env.load(prefix+'GamepadManager.ets');
  const registry=new m.InputDeviceConnectionRegistry(),lease=registry.observeAdd(7).originalConnection,raw=[];
  const record=(...values)=>{raw.push(values);return true;};
  const pad=new GamepadManager(undefined,{emitKey:record,emitMouse:record,emitScroll:record,emitLookDelta:record},registry.reader);
  pad.handleAxisForConnection(lease,new m.GamepadAxisSnapshot(axis=>axis===AXIS_ABS_Z?1:0));
  pad.advanceMappedLook(.016,1000000);
  assert.equal(raw.length,0,'scoped origin cannot use accepted raw fallback');
}

await test('compiled beforeSample-reentry and caught-emitter raw-fallback negatives fail real side-effect assertions',()=>{
  const runtimePath=prefix+'GameInputRuntime.ets',managerPath=prefix+'GamepadManager.ets';
  runtimeReentryAssertion(environment());forbiddenRawAssertion(environment());
  const missingRecheck=environment({}, {[runtimePath]:text=>{
    const anchor='if (!this.acceptsAxisFact(fact)) return';
    assert.equal(text.split(anchor).length-1,2,'two actual post-reentry guards');
    return text.replaceAll(anchor,'');
  }});
  const rawFallback=environment({}, {[managerPath]:text=>text.replace('this.emitter.emitLookDeltaForConnection?.(','this.emitter.emitLookDelta(')});
  // 先完整转译两个生产类，再期待实际输出数量断言；异常和锚点错误不算行为反控。
  missingRecheck.load(runtimePath);rawFallback.load(managerPath);
  const outputFailure=error=>error.code==='ERR_ASSERTION'&&error.actual>0&&error.expected===0;
  assert.throws(()=>runtimeReentryAssertion(missingRecheck),outputFailure);
  assert.throws(()=>forbiddenRawAssertion(rawFallback),outputFailure);
});

/** 原压力墓碑经公共token释放；真实port同步维护回入不得再次调用同一token。 */
function publicReleaseReentryAssertion(env) {
  const m=env.load(prefix+'InputDeviceConnectionLease.ets'),Client=env.load(prefix+'SourceControlClient.ets').SourceControlClient;
  const registry=new m.InputDeviceConnectionRegistry(),lease=registry.observeAdd(7).originalConnection;
  let calls=0,allow=false,inside=false,client;
  client=new Client(2,{acquire:()=> 'boundary-token',release:token=>{
    assert.equal(token,'boundary-token');calls++;
    if(allow&&!inside){inside=true;client.reconcileRetirements();inside=false;}return allow;
  }},registry.reader);
  assert.equal(client.acquireForConnection(lease,'A',[65]),'boundary-token');
  assert.equal(client.releaseForConnection(lease,'A'),false);
  calls=0;allow=true;assert.equal(client.releaseToken('boundary-token'),true);
  assert.equal(calls,1,'public release and retirement must share native token inflight guard');
  assert.equal(client.reconcileRetirements(),true);
}

/** 原timer的Native清理安装了新look事实；新事实有效但不能授权旧timer继续推进。 */
function timerCleanupReentryAssertion(env) {
  const m=env.load(prefix+'InputDeviceConnectionLease.ets');
  const Manager=env.load(prefix+'GamepadManager.ets').GamepadManager,Runtime=env.load(prefix+'GameInputRuntime.ets').GameInputRuntime;
  const registry=new m.InputDeviceConnectionRegistry(),lease=registry.observeAdd(7).originalConnection,events=[];
  const cfg={enabled:true,leftStick:'none',rightStick:'look',buttonMap:{},stickDeadZone:0};
  let runtime,armed=false,phase='initial';
  const pad=new Manager(cfg,{lookExecutionMode:'neutral-rate-v1',emitKey:()=>true,emitMouse:()=>true,emitScroll:()=>true,emitLookDelta:noop,
    emitLookVelocityForConnection:(...values)=>{events.push(['rate',phase,...values]);return true;},
    retireLookForConnection:()=>true,advanceLookExecution:()=>{events.push(['advance',phase]);return true;},
    reconcileConnectionControls:()=>{
      if(armed){armed=false;phase='new-activation';runtime.setState(false,false);runtime.setState(true,true);
        runtime.handleAxisFact(runtime.captureAxisForConnection(lease,axis=>axis===2?.5:0));phase='after-cleanup';}
      return true;
    }},registry.reader);
  runtime=new Runtime(pad,()=>100,noop);
  runtime.start({addInputConfigurationListener:fn=>fn({gamepad:cfg},1),removeInputConfigurationListener:noop,reconcileInputConfiguration:noop});
  runtime.setState(true,true);runtime.handleAxisFact(runtime.captureAxisForConnection(lease,axis=>axis===2?1:0));
  const oldTimer=[...env.timers.values()][0].fn;events.length=0;armed=true;oldTimer();
  assert.equal(events.filter(row=>row[0]==='rate'&&row[1]==='new-activation').length,1,'new activation accepts its new fact');
  assert.equal(events.filter(row=>row[0]==='advance'&&row[1]==='after-cleanup').length,0,'old timer must stop after cleanup reentry');
  // 回入已经建立真实新timer；原续体不能清掉其字段，稳定新timer仍能正常推进。
  const currentTimer=[...env.timers.entries()].find(([id])=>id===runtime.timer)?.[1];
  assert.ok(currentTimer,'new activation retains its scheduled timer');
  currentTimer.fn();
  assert.equal(events.filter(row=>row[0]==='advance'&&row[1]==='after-cleanup').length,1);
}

await test('public token and old timer cleanup reentry are fenced; compiled original-shape negatives fail',()=>{
  publicReleaseReentryAssertion(environment());timerCleanupReentryAssertion(environment());
  const clientPath=prefix+'SourceControlClient.ets',runtimePath=prefix+'GameInputRuntime.ets';
  const bypassSharedGuard=environment({}, {[clientPath]:text=>text.replace('!this.releaseNativeToken(intent.token)','!this.port.release(intent.token)')});
  const bypassCleanupEpoch=environment({}, {[runtimePath]:text=>{
    const comment=text.indexOf('// 精确token/子流清理也会调用Native');assert.ok(comment>=0);
    const guard='if (this.admissionExhausted || activation !== this.admissionEpoch || !this.active) return';
    const position=text.indexOf(guard,comment);assert.ok(position>comment);
    return text.slice(0,position)+text.slice(position+guard.length);
  }});
  bypassSharedGuard.load(clientPath);bypassCleanupEpoch.load(runtimePath);
  assert.throws(()=>publicReleaseReentryAssertion(bypassSharedGuard),error=>error.code==='ERR_ASSERTION'&&error.actual===2&&error.expected===1);
  assert.throws(()=>timerCleanupReentryAssertion(bypassCleanupEpoch),error=>error.code==='ERR_ASSERTION'&&error.actual===1&&error.expected===0);
});

/**
 * 正常UP边缘使用真实Client token与Manager共同按钮/WASD正文。Native端只提供明确回执、
 * RESET和同步原输入事实；没有第二份lease、贡献算法或“当前owner”测试替代实现。
 */
function normalUpReentryAssertion(env,kind='button',mode='accepted',sibling=false) {
  const types=env.load(prefix+'InputDeviceConnectionLease.ets');
  const manager=env.load(prefix+'GamepadManager.ets'),Client=env.load(prefix+'SourceControlClient.ets').SourceControlClient;
  const registry=new types.InputDeviceConnectionRegistry(),lease=registry.observeAdd(7).originalConnection;
  const active=new Map(),calls=[],raw=[];let pad,client,next=0,first=true,replayCallback=false;
  const down=()=>kind==='button'?pad.handleButtonForConnection(lease,2301,true):
    pad.handleAxisForConnection(lease,new types.GamepadAxisSnapshot(axis=>axis===manager.AXIS_ABS_Y?-1:0));
  const up=()=>kind==='button'?pad.handleButtonForConnection(lease,2301,false):
    pad.handleAxisForConnection(lease,new types.GamepadAxisSnapshot(()=>0));
  client=new Client(2,{acquire:(_source,_device,control,codes)=>{
    const token=String(++next);active.set(token,{control,codes});calls.push(['acquire',token,control]);
    if(!replayCallback&&next===(sibling?3:2)){
      replayCallback=true;
      if(mode==='replay-up')up();
      if(mode==='replay-sibling')pad.handleButtonForConnection(lease,2302,true);
    }
    return token;
  },release:token=>{
    calls.push(['release',token]);const initial=first;first=false;
    const refused=initial&&(mode==='rejected'||mode==='retry-reentry');
    if(!refused)active.delete(token);
    if(initial){
      if(mode!=='retry-reentry')down();
      if(mode==='cancelled')up();
      if(mode==='retired'){registry.retireCurrent(7);pad.releaseConnection(lease);}
      if(mode==='reset'){
        active.clear();pad.dropHeldStateAfterNativeReset('actual-boundary-reset');down();
      }
    }
    if(!initial&&mode==='retry-reentry'&&next===1)down();
    if(initial&&mode==='uncertain')throw Error('accepted release result unknown');
    return !refused;
  }},registry.reader);
  const cfg={enabled:true,leftStick:'move',rightStick:'none',buttonMap:{A:{kind:'key',code:65},B:{kind:'key',code:66}}};
  const rawOutlet=(...values)=>{raw.push(values);return true;};
  pad=new manager.GamepadManager(cfg,{emitKey:rawOutlet,emitMouse:rawOutlet,emitScroll:rawOutlet,emitLookDelta:rawOutlet,
    emitControlForConnection:(connection,control,code,action)=>action===1?client.acquireForConnection(connection,control,[code])!=='':client.releaseForConnection(connection,control),
    releaseConnectionControls:connection=>client.releaseConnection(connection),reconcileConnectionControls:()=>client.reconcileRetirements(),
    dropControlsAfterNativeReset:()=>client.dropAfterNativeReset()},registry.reader);
  let siblingToken;
  if(sibling){pad.handleButtonForConnection(lease,2302,true);siblingToken=[...active.keys()][0];}
  down();const originalToken=String(next);up();
  if(mode==='rejected'||mode==='uncertain'||mode==='retry-reentry'){
    assert.equal(next,sibling?2:1,'unconfirmed old UP cannot lend its token to new DOWN');
    assert.equal(mode==='uncertain'?active.size===0:active.has(originalToken),true);
    assert.equal(pad.reconcileConnectionCleanup(),true,'existing stable maintenance acknowledges old UP then applies original desired');
  }
  if(mode==='replay-up'){
    assert.equal(active.size,0);assert.equal(pad.reconcileConnectionCleanup(),true);
    assert.equal(next,2,'latest same-control UP during desired replay must cancel it without a future PRESS');
    assert.equal(pad.hasConnectionState(lease),false);assert.deepEqual(raw,[]);return;
  }
  if(mode==='cancelled'||mode==='retired'){
    assert.equal(active.size,0);assert.equal(next,1,'later UP/retire cancels queued desired before any new token');
    assert.equal(pad.hasConnectionState(lease),false,kind+' '+mode+': no cancelled/retired desired state remains');assert.deepEqual(raw,[]);
    return;
  }
  assert.equal(next,sibling?3:2,'accepted original UP followed by original reentrant DOWN obtains a new actual token');
  assert.equal(active.has(originalToken),false);assert.equal(active.has(String(next)),true);
  if(sibling)assert.equal(active.has(siblingToken),true,'other same-lease control token stays held');
  const currentToken=String(next),beforeRepeat=next;down();assert.equal(next,beforeRepeat,'later duplicate DOWN is grounded in the new actual token');
  up();assert.equal(active.has(currentToken),false,'final UP releases the new token exactly');
  if(sibling){assert.equal(active.has(siblingToken),true);pad.handleButtonForConnection(lease,2302,false);}
  assert.equal(active.size,0);assert.equal(pad.hasConnectionState(lease),false);assert.deepEqual(raw,[]);
}

await test('normal scoped button/move UP reentry, reject/unknown, reset/cancel/retire and sibling preserve exact new token',()=>{
  for(const kind of ['button','move'])for(const mode of ['accepted','rejected','uncertain','cancelled','retired','reset','retry-reentry','replay-up'])
    normalUpReentryAssertion(environment(),kind,mode);
  normalUpReentryAssertion(environment(),'button','accepted',true);
  normalUpReentryAssertion(environment(),'button','replay-sibling',true);
  normalUpReentryAssertion(environment(),'move','replay-sibling',true);
});

await test('compiled old duplicate-DOWN and changed-fence UP shape reproduces the real ghost blocker',()=>{
  const managerPath=prefix+'GamepadManager.ets';
  const old=environment({}, {[managerPath]:text=>{
    const gate='if (state.releasingControls.has(contributorId) || (!replaying && state.pendingControlReentry.has(btn)))';
    assert.equal(text.split(gate).length-1,1);
    const init='state.pendingControlReentry.set(btn, new Set<string>())';assert.equal(text.split(init).length-1,1);
    const commit='if (state.pressedControls.get(btn) === record) state.pressedControls.delete(btn)';assert.equal(text.split(commit).length-1,1);
    return text.replace(gate,'if (false)').replace(init,'').replace(commit,'if (!this.acceptsStateSample(state, fence)) return true\n      '+commit);
  }});
  old.load(managerPath);
  assert.throws(()=>normalUpReentryAssertion(old),error=>error.code==='ERR_ASSERTION'&&error.actual===1&&error.expected===2);
  const oldMove=environment({}, {[managerPath]:text=>{
    const gate='if (state.releasingControls.has(contributorId) || (!replaying && state.pendingMoveReentry.has(key)))';
    const init='state.pendingMoveReentry.set(key, false)';
    const commit='if (this.releaseMappedOutput(record, contributorId, deviceId, state)) {\n        state.activeMoveKeys.delete(key)';
    const normal=text.replaceAll('\r\n','\n');
    assert.equal(normal.split(gate).length-1,1);assert.equal(normal.split(init).length-1,1);assert.equal(normal.split(commit).length-1,1);
    return normal.replace(gate,'if (false)').replace(init,'').replace(commit,
      'if (this.releaseMappedOutput(record, contributorId, deviceId, state)) {\n        if (!this.acceptsStateSample(state, fence)) return\n        state.activeMoveKeys.delete(key)');
  }});
  const losesLatestUp=environment({}, {[managerPath]:text=>{
    const normal=text.replaceAll('\r\n','\n'),anchor='if (isDown) desired.add(contributor)\n      else desired.delete(contributor)';
    assert.equal(normal.split(anchor).length-1,1);
    return normal.replace(anchor,'desired.add(contributor)');
  }});
  const retiresOnSiblingSample=environment({}, {[managerPath]:text=>text.replace(
    'if (!this.acceptsStateSample(state, fence) && stillDesired?.() !== true)',
    'if (!this.acceptsStateSample(state, fence))')});
  oldMove.load(managerPath);losesLatestUp.load(managerPath);retiresOnSiblingSample.load(managerPath);
  assert.throws(()=>normalUpReentryAssertion(oldMove,'move'),error=>error.code==='ERR_ASSERTION'&&error.actual===1&&error.expected===2);
  assert.throws(()=>normalUpReentryAssertion(losesLatestUp,'button','replay-up'),error=>error.code==='ERR_ASSERTION'&&error.actual===1&&error.expected===0);
  assert.throws(()=>normalUpReentryAssertion(retiresOnSiblingSample,'button','replay-sibling',true),
    error=>error.code==='ERR_ASSERTION'&&error.actual===false&&error.expected===true);
});

await test('all twenty-two production GamepadManager ETS test bodies preserve ownership and analog stability',()=>{
  let count=0;
  const hypium={describe:(_name,callback)=>callback(),it:(name,_timeout,callback)=>{callback();count++;console.log('PASS production ETS '+name);},expect:value=>({assertEqual:expected=>assert.equal(value,expected),assertTrue:()=>assert.equal(value,true),assertFalse:()=>assert.equal(value,false)})};
  environment({'@ohos/hypium':hypium}).load('entry/src/test/GamepadManager.test.ets').default();
  assert.equal(count,22);
});

/** 对照必须完成真实正文转译后命中行为断言；语法错误、锚点缺失不能算反控成功。 */
await test('compiled wrong-object and known0-native-admission negatives fail actual authority assertions',()=>{
  const source=prefix+'InputDeviceConnectionLease.ets';
  const checkObject=env=>{
    const m=env.load(source),registry=new m.InputDeviceConnectionRegistry(),original=registry.observeAdd(7).originalConnection;
    const copied=new m.InputDeviceConnectionLease(new m.InputDeviceIdentityEvidence(7,true,false),original.applicationScope);
    assert.equal(registry.reader.accepts(copied),false,'copied object must not acquire authority');
  };
  const checkZero=env=>{
    const m=env.load(source),registry=new m.InputDeviceConnectionRegistry(),original=registry.observeAdd(0).originalConnection;
    assert.equal(registry.reader.allowsLegacyDeviceField(original),false,'known hardware0 has no legacy Native outlet');
  };
  checkObject(environment());checkZero(environment());
  const wrongObject=environment({}, {[source]:text=>text.replace('this.current.get(connection.rawPlatformId) === connection','this.current.has(connection.rawPlatformId)')});
  const zeroNative=environment({}, {[source]:text=>text.replace('(connection.compatibility || connection.rawPlatformId > 0)','(connection.compatibility || connection.rawPlatformId >= 0)')});
  // load先于assert.throws，故所有编译诊断与mutation锚点错误都会直接令整组失败。
  wrongObject.load(source);zeroNative.load(source);
  const authorityFailure=error=>error.code==='ERR_ASSERTION'&&error.actual===true&&error.expected===false;
  assert.throws(()=>checkObject(wrongObject),authorityFailure);
  assert.throws(()=>checkZero(zeroNative),authorityFailure);
});

const after=Object.fromEntries(sourcePaths.map(relative=>[relative,sha(relative)]));
assert.deepEqual(after,before,'production input changed while source-bound evidence was executing');
const out=workspacePath('run','device-connection-runtime');
fs.mkdirSync(out,{recursive:true});
const receipt={startedAtUtc:started.toISOString(),finishedAtUtc:new Date().toISOString(),timezone,node:process.version,
  scope:'actual application production ETS bodies; SDK/Native facts only; not formal SDK typecheck or device generation',
  checks:results,sourceHashes:before,sourceStableDuringRun:true,knownHardwareZeroNativePending:true,
  osQueuedFirstArrivalGenerationProven:false,actualOriginalManagerEtsCases:22,
  normalUpHandoffCases:19,compiledBehaviorNegatives:10,
  fixtures:{'scripts/lib/ets-runtime-fixture.mjs':sha('scripts/lib/ets-runtime-fixture.mjs'),'scripts/lib/ets-compiler.mjs':sha('scripts/lib/ets-compiler.mjs')},
  testSha256:sha('scripts/test-device-connection-runtime.mjs')};
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n',{flag:'wx'});
console.log('DEVICE_CONNECTION_RUNTIME_PASS '+results.length+' groups + twenty-two production ETS cases; '+path.join(out,'receipt.json'));

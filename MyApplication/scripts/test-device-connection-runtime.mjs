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
const sourcePaths=['gamecontrol/Index.ets',...['InputDeviceConnectionLease.ets','InputDeviceMonitor.ets','GameInputRuntime.ets','SourceControlClient.ets'].map(name=>prefix+name)];
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

await test('mobile device list, full keyboard and physical controller readiness follow actual inventory', async () => {
  let changed;
  let ids = [4, 1, 2, 3];
  let unavailable;
  let keyboardType = 2;
  let typeUnavailable = false;
  const info = new Map([
    [1, { name: '触控板', sources: ['touchpad'] }],
    [2, { name: '音量键', sources: ['keyboard'] }],
    [3, { name: '虚拟手柄', sources: ['joystick'], isVirtual: true }],
    [4, { name: '屏幕', sources: ['touchscreen'] }],
    [5, { name: '蓝牙键盘', sources: ['keyboard'] }],
    [6, { name: '手柄一', sources: ['joystick'] }],
    [7, { name: '手柄二', sources: ['joystick'] }],
  ]);
  const sdk = {
    on: (_topic, listener) => { changed = listener; },
    getDeviceList: async () => ids.slice(),
    getDeviceInfoSync: id => {
      if (id === unavailable) throw Error('detail temporarily unavailable');
      return info.get(id);
    },
    getKeyboardTypeSync: id => {
      if (typeUnavailable) throw Error('cannot classify keyboard');
      return id === 5 ? keyboardType : 1;
    },
    KeyboardType: { ALPHABETIC_KEYBOARD: 2 },
  };
  const monitor = environment({ '@ohos.multimodalInput.inputDevice': { default: sdk } })
    .load(prefix + 'InputDeviceMonitor.ets').getInputDeviceMonitor();
  let notices = 0;
  const observe = () => notices++;
  monitor.addDeviceListListener(observe);
  monitor.ensureStarted();
  await flush();
  assert.deepEqual(monitor.connectedDevices().map(row => row.id), [1, 2, 4]);
  assert.deepEqual(monitor.mobileControlCapability(), { mouse: true, keyboard: false, gamepad: false });
  assert.equal(monitor.hasKeyboard(), true, 'desktop source bits keep their original meaning');
  ids = [1, 5, 6, 7];
  await monitor.refreshCapability();
  const rows = monitor.connectedDevices();
  assert.equal(rows[2].name, '手柄一');
  rows[2].sources.length = 0;
  assert.deepEqual(monitor.connectedDevices()[2].sources, ['joystick']);
  assert.deepEqual(monitor.mobileControlCapability(), { mouse: true, keyboard: true, gamepad: true });
  ids = [1, 5, 7];
  const previousCount = notices;
  changed({ type: 'remove', deviceId: 6 });
  await flush();
  assert.ok(notices > previousCount, 'removing one of two controllers updates list while capabilities stay constant');
  assert.equal(monitor.mobileControlCapability().gamepad, true);
  assert.deepEqual(monitor.connectedDevices().map(row => row.name), ['触控板', '蓝牙键盘', '手柄二']);
  unavailable = 5;
  await monitor.refreshCapability();
  assert.equal(monitor.mobileControlCapability().keyboard, true, 'same keyboard is still in the inventory');
  assert.equal(monitor.sourcesForConnection(monitor.captureConnection(5, true, false).connection), undefined,
    'an old display description cannot authorize delivery on a temporarily unconfirmed source');
  unavailable = undefined;
  typeUnavailable = true;
  await monitor.refreshCapability();
  assert.equal(monitor.mobileControlCapability().keyboard, true, 'same full keyboard survives a failed type query');
  typeUnavailable = false;
  keyboardType = 1;
  await monitor.refreshCapability();
  assert.equal(monitor.mobileControlCapability().keyboard, false, 'successful new type replaces old type');
  keyboardType = 2;
  await monitor.refreshCapability();
  assert.equal(monitor.mobileControlCapability().keyboard, true);
  typeUnavailable = true;
  changed({ type: 'remove', deviceId: 5 });
  changed({ type: 'add', deviceId: 5 });
  await flush();
  assert.equal(monitor.mobileControlCapability().keyboard, false, 'new lease cannot inherit same-ID full keyboard');
  monitor.removeDeviceListListener(observe);
  const finalCount = notices;
  await monitor.refreshCapability();
  assert.equal(notices, finalCount);
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

await test('public token and retirement share the same inflight guard',()=>{
  publicReleaseReentryAssertion(environment());
  const clientPath=prefix+'SourceControlClient.ets';
  const changed=environment({}, {[clientPath]:text=>text.replace('!this.releaseNativeToken(intent.token)','!this.port.release(intent.token)')});
  assert.throws(()=>publicReleaseReentryAssertion(changed),assert.AssertionError);
});

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
  osQueuedFirstArrivalGenerationProven:false,

  fixtures:{'scripts/lib/ets-runtime-fixture.mjs':sha('scripts/lib/ets-runtime-fixture.mjs'),'scripts/lib/ets-compiler.mjs':sha('scripts/lib/ets-compiler.mjs')},
  testSha256:sha('scripts/test-device-connection-runtime.mjs')};
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n',{flag:'wx'});
console.log('DEVICE_CONNECTION_RUNTIME_PASS '+results.length+' groups; '+path.join(out,'receipt.json'));

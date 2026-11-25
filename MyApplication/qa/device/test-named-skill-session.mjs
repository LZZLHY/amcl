// 走真实设备会话的 grant → claim → 共享业务对象 → reply。系统上下文和回传 API 不参与。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { loadActionComponent } from '../../scripts/lib/unified-actions-fixture.mjs';
import { verifySkillCases } from '../../scripts/lib/skill-business-check.mjs';
import { actions, session, root, dir, disk, context, grant, signal, installGrant, model, send, reply, load } from './session-fixture.mjs';

const catalog = new URL('../../config/launcher-skill/', import.meta.url);
const methods = fs.readdirSync(catalog).filter(name => name.endsWith('.json'))
  .flatMap(name => JSON.parse(fs.readFileSync(new URL(name,catalog),'utf8').replace(/^\uFEFF/,'')));
const permissions = methods.map(m => 'skill.' + m.name);
const bus = load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus;
const owner = {};
bus.attach(owner, () => true);
const unexpected = async () => { throw Error('具名方法误投递给了旧 QA 动作'); };
let device = model();
function open(list) {
  installGrant({...grant,actions:list});
  return device.activate(context,signal,false);
}
function id(n) { return n.toString(16).padStart(32,'0'); }
let seq = 0;
async function call(action, args, requestId = id(seq+1)) {
  seq++;
  send(seq, requestId, action, args);
  await device.tick();
  const actual = reply(seq);
  assert.equal(actual.action,action); assert.equal(actual.sequence,seq);
  assert.equal(actual.id,requestId); assert.equal(actual.session,session); assert.deepEqual(actual.args,args);
  return actual;
}
for (const invalid of [['skill.*'], ['skill.call'], ['skill.constructor'], ['skill.'], [permissions[0],permissions[0]]]) {
  assert.equal(open(invalid),false);
}
assert.equal(open([...actions,...permissions]),true);
assert.deepEqual(JSON.parse(disk.get(root+'/hello-'+session+'.json')).actions,[...actions,...permissions]);
device.bind(owner,unexpected,unexpected);
let executions = 0;
for (const method of methods) {
  const args = Object.fromEntries(method.args.map(a => [a.name, a.enum?.[0] ??
    (a.type === 'integer' ? 7 : a.type === 'boolean' ? false : 'sample')]));
  if (method.name === 'getLauncherHandoff') args.method = 'chooseLocalModpack';
  const payload = {state:'ready', nested:{method:method.name, detail:[false,3]}, retained:'业务所有者回读'};
  let matched = false;
  bus.bind(method.domain,owner,async (name, values) => {
    executions++; assert.equal(name,method.name); assert.deepEqual(values,args);
    matched = true;
    return payload;
  });
  const r = await call('skill.'+method.name,args);
  assert.equal(matched,true,method.name); assert.equal(r.status,'ok'); assert.deepEqual(r.data,payload);
}
assert.equal(executions,methods.length);
const action = 'skill.addOfflinePlayer';
let state = 'ready';
bus.bind('accounts',owner,async (_name, args) => {
  executions++;
  return {state, reason:'fromOwner', readback:args.playerName.length};
});
for (const [business,transport] of Object.entries({ready:'ok', draft:'ok', accepted:'accepted', needsUser:'needsUser',
    failed:'rejected', unavailable:'rejected', busy:'rejected', initializing:'rejected', cancelled:'rejected',
    partial:'unknown', unknown:'unknown', waiting:'unknown'})) {
  state = business;
  const r = await call(action,{playerName:'demo'});
  assert.equal(r.status,transport); assert.deepEqual(r.data,{state,reason:'fromOwner',readback:4}); assert.equal(r.reason,'fromOwner');
}
state = 'ready';
const longName = '🟦'.repeat(8192);
const long = await call(action,{playerName:longName});
assert.equal(long.status,'ok'); assert.equal(long.data.readback,16384);
const unit = executions;
for (const args of [{playerName:longName+'x'}, {playerName:'\u0000'}, {playerName:true}, {extra:1}, {playerName:'demo',extra:1}]) {
  assert.equal((await call(action,args)).status,'rejected');
}
const duplicate = await call(action,{playerName:'changed'},long.id);
assert.equal(duplicate.status,'rejected'); assert.equal(executions,unit);

// 设备执行后、宿主尚未取得回执时重发同一字节，原序号与回执保持，业务对象只执行一次。
const held = await call(action,{playerName:'owned'});
const count = executions;
send(seq,held.id,action,held.args);
await device.tick();
assert.deepEqual(reply(seq),held); assert.equal(executions,count);
// 进程死亡且只保留 claim 时，重启读取原授权，即使 grant 很大也不重派原业务。
const orphanId = id(seq+1);
disk.set(dir+'/claim-'+(seq+1)+'.json', JSON.stringify([orphanId,action,JSON.stringify({playerName:'interrupted'})]));
device = model(); device.bind(owner,unexpected,unexpected);
assert.equal(device.activate(context,{},true),false); // 普通冷恢复不开启显式唤醒，但恢复原请求循环。
const unknown = await call(action,{playerName:'interrupted'},orphanId);
assert.equal(unknown.status,'unknown'); assert.equal(executions,count);

disk.clear(); disk.set(root,null); seq=0; device=model(); device.bind(owner,unexpected,unexpected);
assert.equal(open(['skill.listPlayerAccounts']),true);
assert.equal((await call(action,{playerName:'unauthorized'})).status,'rejected');
assert.equal(executions,count);
assert.equal((await call('skill.*',{})).status,'rejected');
bus.detach(owner);
const unavailable = await call('skill.listPlayerAccounts',{});
assert.equal(unavailable.status,'rejected'); assert.equal(unavailable.data.state,'unavailable');
assert.equal(executions,count);
console.log('PASS '+methods.length+' named methods via device session, grants, original owners, typed arguments, full result, reconnect and durable claim');

// 真实设备会话进入具名入口。模拟的用户决定可长期等待，观察不导航，写入仍受排他保护。
disk.clear(); disk.set(root,null); seq=0; device=model(); device.bind(owner,unexpected,unexpected);
bus.attach(owner,()=>true,randomUUID);
const handoffAction='skill.getLauncherHandoff', pickerAction='skill.chooseLocalModpack';
assert.equal(open([handoffAction,pickerAction,'skill.getLauncherState','skill.setLauncherMemory']),true);
let decide, prompts=0, writes=0;
bus.bind('browse',owner,async (method)=>{
  prompts++; bus.awaitingUser(method);
  return new Promise(resolve=>{decide=resolve;});
});
bus.bind('shell',owner,async ()=>({state:'ready',initialized:true}));
bus.bind('settings',owner,async ()=>{writes++; return {state:'ready'};});
const hold = await call(pickerAction,{});
assert.equal(hold.data.state,'needsUser');assert.equal(hold.data.method,'chooseLocalModpack');
const ticket={method:hold.data.method,operationRef:hold.data.operationRef};
assert.equal((await call('skill.getLauncherState',{})).data.initialized,true);
assert.equal((await call('skill.setLauncherMemory',{megabytes:1024})).data.state,'busy');
assert.equal(writes,0);assert.equal((await call(handoffAction,ticket)).data.state,'needsUser');
assert.equal((await call(handoffAction,{...ticket,method:'selectGameInstance'})).status,'rejected');
const expired = (await call(handoffAction,{...ticket,method:'getLauncherState'})).data;
assert.equal(expired.state,'unknown');
decide({state:'cancelled',reason:'fileNotSelected'});
await new Promise(resolve=>setImmediate(resolve));
const settled = (await call(handoffAction,ticket)).data;
assert.equal(settled.state,'ready'); assert.deepEqual(settled.outcome,{state:'cancelled',reason:'fileNotSelected'});
assert.equal(prompts,1);verifySkillCases('getLauncherHandoff',settled,expired);
assert.equal((await call('skill.setLauncherMemory',{megabytes:1024})).data.state,'ready');assert.equal(writes,1);
bus.detach(owner);bus.attach({},()=>true,randomUUID);
assert.equal((await call(handoffAction,ticket)).data.reason,'handoffNotRetained');
console.log('PASS foreground handoff, scoped queries, original outcome and write exclusion');

// 从真实 JDK 删除路径证明：写出 needsUser 后设备仍持有原授权，直至这个确认及其业务真正结束。
const DownloadTab = loadActionComponent('entry/src/main/ets/pages/tabs/DownloadTab.ets','DownloadTab',{
  methods:['runtimeSkill_','manageRuntimeSlot_','runtimeSkillActive_','slotView_'],
  dependencies:{'../../launcherskill/SettingsSkillValues':load('entry/src/main/ets/launcherskill/SettingsSkillValues.ets'),
    '../../launcherskill/LauncherSkillBus':{LauncherSkillBus:bus}}, globals:{AppStorage:{get:()=>true}}
});
const originalNow=Date.now;
try {
  for (const mode of ['close','expires','destroy']) {
    const page = new DownloadTab(), changes=[];
    let now=originalNow(), decideSlot, shown=0;
    Date.now=()=>now;
    Object.assign(page,{hostVisible:true,dlSubTab:5,skillInteractive:()=>true,slotDialogBusy_:false,jdkCatalogStatus:'',
      jdkChecking:false,jdkImporting:false,jdkChannel:'stable',jdkActionEpoch_:0,importRef_:'',importOutcome_:{state:'unavailable'},
      jdkVersions:[{version:'17',installed:true,available:true,userImported:false,repairRequired:false,rollback:false,updateAvailable:true,
        installedTag:'A',expectedTag:'B',path:'/memory/demo',stateText:'ok'}],
      isJdkDownloading:()=>false,readSlotIdentity:()=>'fixture-slot',theme:{},
      getUIContext:()=>({getPromptAction:()=>({showDialog:()=>{shown++;return new Promise(resolve=>{decideSlot=resolve;});}})}),
      onJdkDelete:major=>{changes.push(major);return true;}
    });
    const original={...grant,expiresAt:now+2000,actions:['skill.manageJavaRuntime',handoffAction]};
    const replacement={...original,session:'b'.repeat(32),expiresAt:now+120000};
    const otherSignal={parameters:{amclQaSession:replacement.session}};
    const host={};
    bus.attach(host,()=>true,randomUUID);
    bus.bind('runtimeSlots',page,(method,args)=>page.runtimeSkill_(method,args));
    disk.clear();disk.set(root,null);installGrant(original);
    const qa=model();
    qa.bind(host,unexpected,unexpected);
    assert.equal(qa.activate(context,signal,false),true);
    send(1,id(1),'skill.manageJavaRuntime',{major:'17',operation:'remove'});
    await qa.tick();const originalResponse=reply(1);
    assert.equal(originalResponse.data.reason,'awaitingUser');assert.deepEqual(changes,[]);
    if (mode==='expires') now+=2500; else disk.set(root+'/close-'+session+'.txt',session);
    if (mode==='destroy') qa.detach(context);
    await qa.tick();
    assert.equal(qa.activate(context,signal,false),false);assert.equal(disk.has(dir+'/closed.json'),false);
    installGrant(replacement);
    assert.equal(qa.activate(context,otherSignal,false),false);
    assert.equal(disk.has(root+'/'+replacement.session+'/grant.json'),false);
    decideSlot({index:mode==='expires'?0:1});
    await new Promise(resolve=>setImmediate(resolve));
    assert.deepEqual(changes,mode==='expires'?[]:['17']);assert.equal(shown,1);
    await qa.tick();
    assert.equal(qa.activate(context,otherSignal,false),true);
    assert.equal(JSON.parse(disk.get(dir+'/closed.json')).session,session);
    assert.deepEqual(reply(1),originalResponse);assert.equal(shown,1);
    bus.detach(host);
  }
} finally { Date.now=originalNow; }
// 真正冷启动没有任何旧 Promise 可恢复。仅原会话关闭信号可按原件封账；迟到决定不能被新身份重放。
const archivedReply=disk.get(dir+'/reply-1.json');
disk.delete(dir+'/closed.json');disk.set(root+'/close-'+session+'.txt',session);
const cold=model();cold.bind({},unexpected,unexpected);
assert.equal(cold.activate(context,signal,true),false);
assert.equal(JSON.parse(disk.get(dir+'/closed.json')).closed,true);assert.equal(disk.get(dir+'/reply-1.json'),archivedReply);
assert.equal(cold.sessionDirectory(),'');
console.log('PASS real JDK handoff delays closure/replacement until original decision, including expiry, destruction and cold sealing');
await import('./picker-session-cases.mjs');
await import('./draft-leave-session-cases.mjs');

/** 执行真实官方脚本、平台回传适配和业务分派，仅以假件替换系统回调与页面宿主。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const replies = [];
let rejectReport = false;
globalThis.canIUse = () => true;
const kit = { scriptManager: { async completeArkTSScriptInApp(context,code,result) {
  assert.equal(context,info.context); assert.equal(code,info.requestCode);
  if (rejectReport) throw Error('test platform unavailable');
  replies.push(result);
} } };
const info = {context:{},requestCode:'platform-request'};
const deliveryErrors=[];
const deps = {'@kit.AbilityKit':kit,commons:{LogTags:{ENTRY_ABILITY:'EntryAbility'},AppLogger:{warn:(_,msg)=>deliveryErrors.push(msg)}}};
const load = makePureEtsLoader(deps);
const dir = 'entry/src/main/ets/launcherskill/';
const base = load(dir+'LauncherSkillBus.ets');
const bus = base.LauncherSkillBus;
const args = load(dir+'SkillArguments.ets');
const named = load(dir+'NamedSkill.ets');
deps['../../../src/main/ets/launcherskill/PlatformReport'] = load(dir+'PlatformReport.ets');
const entry = new (load('entry/skills/amcl-launcher/scripts/LauncherSkill.ets').default)();
const host = {}, old = {}, current = {}, sub = {};
let permitted = false, count = 0;
bus.attach(host,()=>permitted);
bus.bind('shell', current, async (name,body) => {count++;return {state:'ready',action:name,threshold:body.thresholdMiB};});
await entry.setActivityAlert(info,'256');
assert.equal(replies.at(-1).result.state,'unavailable');assert.equal(count,0);
permitted=true;
for(const invalid of [[],['2e3'],['256','unexpected'],['3.2'],['17']]) {
  await entry.setActivityAlert(info,...invalid);
  assert.equal(replies.at(-1).result.reason,'invalidArguments');
}
assert.equal(count,0);
await entry.setActivityAlert(info,'256');
assert.deepEqual(replies.at(-1).result,{state:'ready',action:'setActivityAlert',threshold:256});
rejectReport=true;
await assert.rejects(entry.setActivityAlert(info,'512'),/platform unavailable/);
assert.equal(count,2,'lost platform callback never replays business effect');
assert.equal(deliveryErrors.length,1);assert.ok(deliveryErrors[0].includes('setActivityAlert'));
assert.ok(!deliveryErrors[0].includes('platform-request') && !deliveryErrors[0].includes('512'));
rejectReport=false;
const words=[{name:'enabled',kind:'boolean',required:true},{name:'choice',kind:'string',required:false,choices:['dark','light']}];
assert.deepEqual(args.parseSkillArguments(['false',''],words),{enabled:false});
assert.equal(args.parseSkillArguments(['0'],words),undefined);
assert.equal(args.parseSkillArguments(['true','system'],words),undefined);

let opens=0, childCalls=0, ready;
bus.bindOpener('child',host,()=>{opens++;setTimeout(()=>bus.bind('child',sub,async()=>{childCalls++;return {state:'ready',child:true};}),2);return true;});
bus.bind('parent',old,async()=>({state:'failed'}));
bus.bind('parent',current,async()=>bus.forward(current,'child','childAction',{}));
bus.unbind('parent',old);
assert.deepEqual(await bus.call('parent','parentAction',{}),{state:'ready',child:true});
assert.equal(opens,1);assert.equal(childCalls,1);
bus.bind('hold',current,()=>new Promise(resolve=>{ready=resolve;}));
const inFlight=bus.call('hold','get',{});
assert.equal((await bus.call('shell','get',{})).state,'busy');
ready({state:'ready'});await inFlight;
assert.equal((await bus.forward(current,'child','get',{})).state,'unavailable');

let late=0;
bus.bindOpener('late',host,()=>{setTimeout(()=>bus.detach(host),5);return true;});
assert.equal((await bus.call('late','save',{})).state,'unavailable');
bus.bind('late',sub,async()=>{late++;return {state:'ready'};});
await new Promise(r=>setTimeout(r,5));
assert.equal(late,0);
bus.attach({},()=>true);
bus.bind('shell',current,async()=>({state:'ready'}));
bus.attach({},()=>true);
assert.equal((await bus.call('shell','save',{})).state,'unavailable','new launcher does not inherit previous owners');
// 从每一个真实脚本方法进入；固定的 domain、方法、参数类型和平台回执必须全部吻合。
const contractDir=new URL('../config/launcher-skill/',import.meta.url);
const methods=fs.readdirSync(contractDir).filter(n=>n.endsWith('.json')).flatMap(n=>JSON.parse(fs.readFileSync(new URL(n,contractDir),'utf8').replace(/^\uFEFF/,'')));
for (const method of methods) {
  let calls=0;
  const values=method.args.map(a=>a.enum?.[0] ?? (a.type==='boolean'?true:a.type==='integer'?7:'value'));
  bus.bind(method.domain, current, async(name,body)=>{
    calls++;assert.equal(name,method.name); assert.deepEqual(body,Object.fromEntries(method.args.map((a,i)=>[a.name,values[i]])));
    return {state:'ready'};
  });
  await entry[method.name](info,...values.map(String));
  assert.equal(calls,1);assert.equal(replies.at(-1).result.state,'ready');
  await entry[method.name](info,...values.map(String),'unregisteredArgument');
  assert.equal(calls,1);assert.equal(replies.at(-1).result.reason,'invalidArguments');
  // QA 的命名标量必须进入同一对象，不能二次触发平台回报或放宽传输类型。
  const input=Object.fromEntries(method.args.map((a,i)=>[a.name,values[i]]));
  const reports=replies.length;
  assert.ok(named.isLauncherSkillMethod(method.name));
  assert.deepEqual(await named.callNamedLauncherSkill(method.name,input),{state:'ready'});
  assert.equal(calls,2);assert.equal(replies.length,reports);
  assert.equal((await named.callNamedLauncherSkill(method.name,{...input,unregisteredArgument:true})).reason,'invalidArguments');
  for (const a of method.args) {
    const bad=a.type==='string'?123:String(input[a.name]);
    assert.equal((await named.callNamedLauncherSkill(method.name,{...input,[a.name]:bad})).reason,'invalidArguments');
  }
  assert.equal(calls,2);
}
assert.equal(named.isLauncherSkillMethod('toString'),false);
assert.equal((await named.callNamedLauncherSkill('unknown',{})).reason,'unknownMethod');
console.log('PASS all '+methods.length+' registered public methods entered via the generated ArkTS class');
console.log('PASS official method, positional types, platform ack failure, host admission, owner replacement, guarded forwarding and late-page cancellation');

/** 在真实版本租约和真实业务入口上重现批量清理、重试换代、整合包确认调度和重复补齐。 */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { verifySkillCases } from '../../scripts/lib/skill-business-check.mjs';
import { readFileSync } from 'node:fs';
import ts from '../../scripts/lib/ets-compiler.mjs';
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';

const base='entry/src/main/ets/',common=base+'launcherskill/';
const lease=makePureEtsLoader()('feature_core/src/main/ets/version/VersionInstallLease.ets');
let next=1,paths=new Map(),allow=true,root='/mc',orphans=[],installed=[],confirm=async()=>true,iteration=0,onInventory=()=>{},onMove=()=>{},deleteFail='';
const mkdir=(p,directory=true)=>{paths.set(p,{ino:BigInt(9007199254740992)+BigInt(next++),ctime:1,mtime:1,size:2,directory,symlink:false});};
function children(p){if(!paths.has(p))throw Error('missing');return [...paths.keys()].filter(k=>k.startsWith(p+'/')&&!k.slice(p.length+1).includes('/')).map(k=>k.slice(p.length+1));}
const fs={accessSync:p=>paths.has(p),listFileSync:children,lstatSync(p){const st=paths.get(p);if(!st)throw Error('absent');return {...st,isFile:()=>!st.directory,isDirectory:()=>st.directory,isSymbolicLink:()=>st.symlink};},
  renameSync(from,to){if(paths.has(to)||!paths.has(from))throw Error('bad rename');for(const path of [...paths.keys()])if(path===from||path.startsWith(from+'/')){paths.set(to+path.slice(from.length),paths.get(path));paths.delete(path);}onMove(from,to);},
  unlinkSync(p){if(p.endsWith(deleteFail)&&deleteFail)throw Error('denied');paths.delete(p);},rmdirSync(p){assert.equal(children(p).length,0);paths.delete(p);}};
const core={...lease,safeBaseName:s=>/^[\w.-]+$/.test(s)?s:'',isTerminalState:s=>['done','aborted','error'].includes(s),
  McVersionTask:class {},TaskCategory:{MC_VERSION:'mc',MODPACK:'modpack',MOD:'mod',SHADER:'shader',RESOURCE_PACK:'rp',DATAPACK:'dp'},
  UnifiedTaskState:{WAITING:'waiting',DONE:'done',ABORTED:'aborted',ERROR:'error'},isInProgressState:()=>false,aggregateProgress:()=>0};
const deps={'@kit.CoreFileKit':{fileIo:fs},'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},feature_core:core};
const load=makePureEtsLoader(deps),{clearOrphanInstances:clear}=load(base+'runtime/OrphanCleanup.ets');
function reset(){paths=new Map();root='/mc';orphans=['a','b'];installed=['live'];allow=true;iteration=0;onMove=()=>{};onInventory=()=>{};confirm=async()=>true;deleteFail='';
 for(const p of ['/mc','/mc/versions','/mc/versions/a','/mc/versions/b','/mc/versions/live'])mkdir(p);}
const access={current:()=>allow,root:()=>root,inventory:async()=>{iteration++;onInventory(iteration);return {orphans,installed,error:''}},reserved:()=>false,confirm:m=>confirm(m)};
const run=()=>clear(access,['a','b']);
reset();let owned=lease.claimVersionInstall(root,'b','ongoing-install-without-metadata');
assert.equal((await run()).reason,'instanceInUse');assert.ok(paths.has('/mc/versions/a'));assert.ok(paths.has('/mc/versions/b'));
const released=lease.claimVersionInstall(root,'a','other');released();owned();
reset();confirm=async()=>{mkdir('/mc/versions/a');return true;};assert.equal((await run()).state,'failed');assert.ok(paths.has('/mc/versions/b'));
reset();onInventory=i=>{if(i===2){installed.push('moved');}};assert.equal((await run()).state,'failed');assert.ok(paths.has('/mc/versions/a'));
reset();confirm=async()=>{root='/changed';return true;};assert.equal((await run()).state,'failed');assert.equal(paths.size,5);
reset();mkdir('/mc/versions/b/saves');assert.equal((await run()).reason,'userContentPresent');assert.ok(paths.has('/mc/versions/b/saves'));assert.ok(paths.has('/mc/versions/a'));
reset();confirm=async()=>false;assert.equal((await run()).state,'cancelled');assert.ok(paths.has('/mc/versions/a'));
reset();mkdir('/mc/versions/b/b.jar',false);deleteFail='b.jar';let r=await run();assert.equal(r.state,'partial');assert.deepEqual(r.removed,['a']);assert.ok(paths.has('/mc/versions/b/b.jar'));
reset();mkdir('/mc/versions/b/b.jar',false);deleteFail='b.jar';
r=await clear(access,['b'],false);assert.equal(r.state,'partial');assert.deepEqual(r.removed,[]);assert.deepEqual(r.remaining,['b']);
const definitions=JSON.parse(readFileSync(new URL('../../config/launcher-skill/instances.json',import.meta.url),'utf8').replace(/^\uFEFF/,''));
for (const name of ['requestInstanceDeletion','clearIncompleteInstances']) {
  const method=definitions.find(m=>m.name===name);
  assert.ok(method.results.includes(r.state));assert.deepEqual(method.requiredOutput.partial,['removed','remaining']);
}
reset();r=await run();assert.equal(r.state,'ready');assert.deepEqual(r.removed,['a','b']);assert.ok(paths.has('/mc/versions/live'));
reset();owned=lease.claimVersionInstall(root,'a','writing');r=await clear(access,['a'],false);assert.equal(r.reason,'instanceInUse');owned();assert.ok(paths.has('/mc/versions/a'));
r=await clear(access,['a'],false);assert.deepEqual(r.removed,['a']);assert.ok(paths.has('/mc/versions/b'));
console.log('PASS orphan batch holds every true install claim, closes intermediate claims, rechecks root/identity/inventory, preserves worlds and reports partial I/O');

class Pack {}
const mods={ModpackInstallTask:Pack,modpackFileKey:v=>v.id};
const {TaskPanelSkill}=makePureEtsLoader({...deps,mods,'../components/DownloadTaskSnapshot':load(base+'components/DownloadTaskSnapshot.ets')})(common+'TaskPanelSkill.ets');
const adapter=new Pack();const id='pack:test';let native=true,workStart,resolveWork,rejectWork,dispatches=0,commitChoice;
adapter.view={id,title:'pack',startedAtMs:14,state:'paused',category:'modpack',canResume:true};
adapter.packageCandidates=()=>[];adapter.optionalFiles=()=>[];adapter.canChooseOtherPackage=()=>false;adapter.requiresPackageSelection=()=>false;adapter.getSession=()=>({id});
adapter.confirmAndResume=(reg,commit,started)=>{commit();commitChoice=true;return reg.resume(id,started);};
const other=new Pack();other.view={...adapter.view,id:'pack:other'};
const reg={getAdapter:key=>native?(key===id?adapter:key===other.view.id?other:null):null,listAll:()=>[adapter.view,other.view],resume(_,started){
 dispatches++;workStart=started;return new Promise((resolve,reject)=>{resolveWork=resolve;rejectWork=reject;});},
 retry(_,started){return this.resume(id,started);}};
const task=new TaskPanelSkill(reg,{active:()=>true,confirm:async()=>true});
let resolveHandoff;
const handoffPanel=new TaskPanelSkill(reg,{active:()=>true,recover:()=>new Promise(resolve=>{resolveHandoff=resolve;})});
adapter.view.canRecoverExternally=true;
const handoffRef=(await handoffPanel.run('listDownloadQueue',{})).tasks[0].ref;
const handoff=handoffPanel.run('controlDownloadTask',{action:'externalRecovery',ref:handoffRef});
resolveHandoff({state:'unknown',reason:'destinationUnconfirmed'});assert.equal((await handoff).state,'unknown');
adapter.view.canRecoverExternally=false;
async function newRef(){return (await task.run('listDownloadQueue',{})).tasks[0].ref;}
let ref=await newRef();
let reply=await task.run('controlDownloadTask',{ref,action:'resume'});assert.equal(reply.state,'accepted');assert.equal(reply.started,false);assert.equal(dispatches,1);
assert.equal((await task.run('controlDownloadTask',{ref,action:'resume'})).operationRef,reply.operationRef);assert.equal(dispatches,1);
workStart(adapter);adapter.view.state='downloading';
let live=await task.run('controlDownloadTask',{ref,action:'resume'});assert.equal(live.started,true);assert.equal(live.phase,'downloading');
adapter.view.state='done';resolveWork();await Promise.resolve();
adapter.view.startedAtMs=15;adapter.view.state='error';
let retained=await task.run('controlDownloadTask',{ref,action:'resume'});assert.equal(retained.activityId,14);assert.equal(retained.phase,'done');assert.equal(retained.outcome,'returned');
adapter.view.state='error';adapter.view.canRetry=true;ref=await newRef();reply=await task.run('controlDownloadTask',{ref,action:'retry'});
assert.equal(reply.originalActivityId,15);assert.equal(reply.activityId,0);adapter.view.startedAtMs=16;workStart(adapter);
native=false;resolveWork();await Promise.resolve();reply=await task.run('controlDownloadTask',{ref,action:'retry'});assert.equal(reply.outcome,'unknown');assert.equal(reply.activityId,16);
native=true;adapter.view.state='paused';adapter.view.requiresConfirmation=true;ref=await newRef();
let choice=(await task.run('getModpackChoices',{ref})).choiceRef;
let picked='';
adapter.requiresPackageSelection=()=>true;
adapter.packageCandidates=()=>[{id:'primary',title:'Primary'}];
adapter.packageSelected=id=>picked===id;
adapter.selectPackage=id=>{picked=id;};
choice=(await task.run('getModpackChoices',{ref})).choiceRef;
const choose=index=>task.run('changeModpackChoice',{ref,choiceRef:choice,kind:'package',index});
const invalidChoice=await choose(3);
assert.equal(invalidChoice.reason,'choiceUnavailable');
const changedChoice=await choose(0);
assert.equal(picked,'primary'); assert.notEqual(changedChoice.choiceRef,choice);
verifySkillCases('changeModpackChoice',changedChoice,invalidChoice);
choice=changedChoice.choiceRef;
const otherRef=(await handoffPanel.run('listDownloadQueue',{})).tasks.find(row=>row.id===other.view.id).ref;
const beforeConfirmation=dispatches;
reply=await task.run('confirmModpackChoices',{ref,choiceRef:choice});assert.equal(reply.state,'accepted');assert.equal(reply.choiceState,'committed');assert.ok(commitChoice);
const deniedConfirmation=await handoffPanel.run('confirmModpackChoices',{ref:otherRef,choiceRef:choice});
assert.equal(deniedConfirmation.reason,'operationConflict');
assert.equal((await task.run('confirmModpackChoices',{ref,choiceRef:choice})).operationRef,choice);
assert.equal(dispatches,beforeConfirmation+1);
verifySkillCases('confirmModpackChoices',reply,deniedConfirmation);
rejectWork(Error('scheduled refused'));await Promise.resolve();
adapter.view.startedAtMs++;reply=await task.run('confirmModpackChoices',{ref,choiceRef:choice});assert.equal(reply.state,'failed');assert.equal(reply.outcome,'rejected');assert.equal(reply.originalActivityId,16);assert.equal(reply.activityId,0);
ref=await newRef();
choice=(await task.run('getModpackChoices',{ref})).choiceRef;
reply=await task.run('confirmModpackChoices',{ref,choiceRef:choice});assert.equal(reply.selectedRef,ref);
workStart(adapter);adapter.view.state='done';resolveWork();await Promise.resolve();
const returned=await task.run('confirmModpackChoices',{ref,choiceRef:choice});
assert.equal(returned.state,'ready');assert.equal(returned.outcome,'returned');
const after=await handoffPanel.run('confirmModpackChoices',{ref:otherRef,choiceRef:choice});
assert.equal(after.state,'failed');assert.equal(after.selectedTaskId,undefined);
// 原行、尚未分号的排队重试和出队的新尝试是三个不同的可见对象。
const guarded=new TaskPanelSkill(reg,{active:()=>true,confirm:()=>new Promise(resolve=>{finishDecision=resolve})});
let finishDecision,removed=0,queueCancels=0;
reg.purgeFinished=()=>{removed++;return 1};
reg.cancel=async(_,cleanup,start)=>{queueCancels++;adapter.view.startedAtMs++;adapter.view.state='aborted';start(adapter)};
adapter.view.state='error';adapter.view.canCancel=true;other.view.state='paused';
const getRow=async()=>(await guarded.run('listDownloadQueue',{})).tasks.find(row=>row.id===id);
const oldRow=await getRow(), oldActivity=oldRow.activityId;
const cancel=guarded.run('controlDownloadTask',{ref:oldRow.ref,action:'cancel'});
Object.assign(adapter.view,{state:'waiting',activityRelation:'retry',parentActivityId:oldActivity});
finishDecision(true);assert.equal((await cancel).reason,'taskChanged');assert.equal(queueCancels,0);
assert.equal((await guarded.run('getDownloadTaskDetail',{ref:oldRow.ref})).reason,'taskChanged');
const waiting=await getRow();assert.equal(waiting.activityId,0);
assert.equal((await guarded.run('getDownloadTaskDetail',{ref:waiting.ref})).phase,'waiting');
adapter.view.startedAtMs++;adapter.view.state='downloading';
assert.equal((await guarded.run('getDownloadTaskDetail',{ref:waiting.ref})).reason,'taskChanged');
adapter.view.state='error';
const clearPending=guarded.run('clearFinishedTasks',{});
adapter.view.startedAtMs++;finishDecision(true);
assert.equal((await clearPending).reason,'queueChanged');assert.equal(removed,0);
adapter.view.state='waiting';adapter.view.parentActivityId=adapter.view.startedAtMs;
const fresh=await getRow(), freshCancel=guarded.run('controlDownloadTask',{ref:fresh.ref,action:'cancel'});
finishDecision(true);const cancelled=await freshCancel;
assert.equal(queueCancels,1);assert.equal(cancelled.activityId,adapter.view.startedAtMs);
assert.equal(cancelled.originalActivityId,0);
console.log('PASS deferred resume/retry return immediately, exact queue admission vs natural completion, lost owner is unknown, committed modpack choice with rejected schedule remains failed');

const src=readFileSync(new URL('../../entry/src/main/ets/components/VersionManagerSheet.ets',import.meta.url),'utf8');
const ast=ts.createSourceFile('v.ets',src,ts.ScriptTarget.Latest,true);
const real=ast.statements.find(x=>x.name?.text==='VersionManagerSheet').members.find(x=>x.name?.text==='repairModpack_').getText(ast);
const js=ts.transpileModule('class P {'+real+'}\nmodule.exports=P;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
const module={exports:{}};let existing={},created=0,reopens=0,throwReopen=false,admit=true;
const queue={getAdapter:()=>existing,enqueue(item){if(admit)existing=item;return Promise.resolve();}};
class NewPack{constructor(){created++;this.view={id:'modpack:pack',startedAtMs:54};}}
new Function('module','result','getDownloadTaskRegistry','reopenModpackRepair','ModpackInstallTask','resolveCurseForgeFileSourcePreference','getRelayClient','CurseForgeFileSourceMode','createModpackFileResolver',js)(module,
 (state,reason)=>({state,reason}),()=>queue,()=>{reopens++;if(throwReopen)throw Error('invalid');},NewPack,()=>'',()=>({isEnabled:()=>false}),{OFFICIAL_ONLY:'official',OFFICIAL_FIRST:'first'},()=>()=>undefined);
const panel=Object.assign(new module.exports(),{detailModpackSnap_:{installId:'pack'},getAbilityCtx:()=>({filesDir:'/app'}),safeToast(){},onClose(){},onOpenDownloadTask(){},getUIContext(){return {getPromptAction:()=>({showToast(){}})};}});
assert.equal(panel.repairModpack_().state,'needsUser');assert.equal(reopens,0);assert.equal(created,0);
existing=null;throwReopen=true;assert.equal(panel.repairModpack_().reason,'repairReopenRejected');assert.equal(created,0);
throwReopen=false;admit=false;assert.equal(panel.repairModpack_().state,'unknown');
existing=null;admit=true;assert.equal(panel.repairModpack_().activityId,54);
console.log('PASS original modpack receipt reopen, existing finished card never attributed to a newly requested repair');

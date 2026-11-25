// 执行实际调试适配器。可变沙箱和产品回调用于模拟换目标、后台任务以及页面确认被取消。
import assert from 'node:assert/strict';
import {makePureEtsLoader} from '../../scripts/lib/load-pure-ets.mjs';

let dir = 'session', epoch = 0, pending = '', deleted = 0, gameBusy = false, name = 'demo';
let inode = 10, resources = '', busy = false, canBrowse = true, canHome = true;
const files = new Set(['/mc/versions/demo','/mc/versions/demo/demo.json','/mc/versions/demo/demo.jar','/mods/a.jar']);
const fs = { accessSync:p=>files.has(p), lstatSync:p=>{
  if (!files.has(p)) throw Error('missing');
  return {dev:1,ino:inode,size:10,ctime:15,mtime:15,isSymbolicLink:()=>false,
    isDirectory:()=>p==='/mc/versions/demo',isFile:()=>p!=='/mc/versions/demo'};
}};
const state={WAITING:'waiting',PREPARING:'preparing',DOWNLOADING:'downloading',EXTRACTING:'extracting',VERIFYING:'verifying'};
const load=makePureEtsLoader({'entry/ProductQa':{ProductQa:{sessionDirectory:()=>dir}},'@kit.CoreFileKit':{fileIo:fs},
  commons:{validateVersionName:name=>name.startsWith('.')?'invalid':''},
  feature_core:{safeBaseName:n=>/[\\/]/.test(n)?'':n,versionInstallNameError:()=>'',UnifiedTaskState:state,
    TaskCategory:{MC_VERSION:'mc'},claimVersionInstall:()=>{if(busy)throw Error('locked');return ()=>{};}},
  mods:{ResourceKind:{MOD:'mod',RESOURCE_PACK:'resourcepack',SHADER:'shader',MODPACK:'modpack',DATAPACK:'datapack'},
    toggleEnabledFilename:(filename,on)=>on?filename.replace(/\.disabled$/,''):filename+'.disabled'}});
const Manager=load('entry/src/main/ProductQaManagement.ets').ProductQaManagement;
const management=new Manager();
const port={root:()=>'/mc',block:()=>'',gameBusy:()=>gameBusy,inventory:async()=>({installed:[name]}),
  prompt:v=>{pending=v;return ++epoch;},pending:(v,n)=>v===pending&&epoch===n,
  remove:async()=>{deleted++;files.delete('/mc/versions/'+pending);pending='';return true;},
  cancel:()=>{pending='';},settings:()=>({jdkVersion:'auto',renderScalePercent:80}),jdkChoices:()=>['8','17'],
  saveJdk:async(v,c)=>c==='17',saveResolution:async()=>{},browse:k=>{resources=k;return canBrowse;},home:()=>canHome,prepareRename:v=>(from,to)=>from===v&&to==='other'};
const action=(a,args,id='one')=>management.run(port,a,JSON.stringify(args),id).then(JSON.parse);
let orphanWrites=0;
port.prepareOrphan=async version=>({root:'/mc',names:[version],items:[{content:[]}]});
port.removeOrphan=async plan=>{orphanWrites++;return {state:'ready',removed:plan.names,remaining:[]};};
const prepared=await action('versions.orphans.prepare',{version:'orphan'},'orphan-plan');
assert.equal(prepared.reason,'CONFIRM_ORPHAN_CLEANUP');
assert.deepEqual(prepared.data.files,[]);
assert.equal(orphanWrites,0);
let decision={version:'orphan',planId:'orphan-plan'};
assert.equal((await action('versions.orphans.confirm',{...decision,version:'other'})).reason,'STALE_CONFIRMATION');
gameBusy=true;assert.equal((await action('versions.orphans.confirm',decision)).reason,'GAME_SESSION_ACTIVE_OR_UNKNOWN');gameBusy=false;
assert.deepEqual((await action('versions.orphans.confirm',decision)).data.removed,['orphan']);
assert.equal((await action('versions.orphans.confirm',decision)).reason,'STALE_CONFIRMATION');
assert.equal(orphanWrites,1);
assert.equal((await action('resources.open',{kind:'modpack'})).status,'accepted');assert.equal(resources,'modpack');
assert.equal((await action('resources.open',{kind:'nonsense'})).status,'rejected');
canBrowse=false;assert.equal((await action('resources.open',{kind:'mod'})).reason,'RESOURCE_NAVIGATION_UNAVAILABLE');
assert.equal((await action('launcher.home',{})).data.page,'home');
canHome=false;assert.equal((await action('launcher.home',{})).reason,'DOWNLOAD_TASK_CONFIRMATION_PENDING');
assert.equal((await action('settings.jdk',{version:name,choice:'27'})).status,'rejected');
assert.equal((await action('settings.jdk',{version:name,choice:'17'})).status,'ok');
const prepare=()=>action('versions.delete.prepare',{version:name});
const confirm=()=>action('versions.delete.confirm',{planId:'one',version:name});
assert.equal((await action('versions.rename',{version:name,newName:'other'})).status,'ok');
assert.equal((await action('versions.rename',{version:name,newName:'refused'})).status,'rejected');
await prepare();
assert.equal(JSON.parse(await new Manager().run(port,'versions.delete.confirm',JSON.stringify({planId:'one',version:name}),'next')).reason,'STALE_CONFIRMATION');
assert.equal(deleted,0,'新页面即使打开相同目标和同代弹窗也不能使用旧令牌');
await prepare();epoch++;assert.equal((await confirm()).status,'rejected');
await prepare();inode++;assert.equal((await confirm()).reason,'TARGET_CHANGED');
await prepare();gameBusy=true;assert.equal((await confirm()).status,'needsUser');gameBusy=false;
await prepare();dir='another';assert.equal((await confirm()).reason,'STALE_CONFIRMATION');dir='session';
await prepare();assert.equal((await confirm()).data.removed,true);assert.equal(deleted,1);
assert.equal((await confirm()).status,'rejected');assert.equal(deleted,1);

const view={id:'url:private',category:'misc',title:'not exposed',state:'downloading',startedAtMs:55,canPause:true,canResume:false};
const alias=load('entry/src/main/QaTaskIdentity.ets').qaTaskId(dir,view);
let finish,paused=0;
const reg={cancel:async()=>{},listAll:()=>[view],get:id=>id===view.id?view:null,pause:id=>{assert.equal(id,view.id);paused++;return new Promise(r=>{finish=r;});}};
const control=load('entry/src/main/QaTaskControl.ets').QaTaskControl;
const call=(act,args)=>JSON.parse(control.run(reg,dir,act,args,'cmd'));
const req={command:'pause',taskId:alias,activityId:55};
assert.equal(call('tasks.control',{...req,activityId:1}).status,'rejected');
assert.equal(call('tasks.control',{...req,command:'resume'}).status,'rejected');
assert.equal(call('tasks.control',req).status,'accepted');assert.equal(paused,1);
assert.equal(call('tasks.controlState',{operationId:'cmd'}).data.outcome,'pending');
finish();await Promise.resolve();assert.equal(call('tasks.controlState',{operationId:'cmd'}).data.outcome,'returned');

view.startedAtMs=0;view.state='waiting';view.canCancel=true;
assert.equal(call('tasks.control',{taskId:alias,activityId:0,command:'cancel'}).status,'rejected');
const objectRef=load('entry/src/main/QaTaskIdentity.ets').qaTaskRef(dir,view,'firstList');
assert.equal(call('tasks.control',{taskId:alias,activityId:0,command:'cancel',taskRef:objectRef}).status,'accepted');
assert.equal(call('tasks.control',{taskId:alias,activityId:0,command:'cancel',taskRef:'outdated'}).status,'rejected');

const lib=new (load('entry/src/main/ProductQaLibrary.ets').ProductQaLibrary)();
const row={filename:'a.jar',filePath:'/mods/a.jar',sizeBytes:10,enabled:true};
const access={active:true,ready:true,error:false,epoch:1,directory:'/mods',version:name,kind:'mod',rows:[row],togglable:true,pending:'',confirmation:0,
 prompt(n){this.pending=n;return ++this.confirmation;},remove(){return files.delete(row.filePath);},cancel(){this.pending='';},
 async toggle(r,on){files.delete(r.filePath);files.add('/mods/a.jar.disabled');return {state:'ready'};}};
const invoke=(a,obj,id)=>lib.run(access,a,JSON.stringify(obj),id).then(JSON.parse);
let result=await invoke('library.list',{},'list');assert.deepEqual(result.data.items.map(x=>x.filename),['a.jar']);
const ref=result.data.items[0].ref;
await invoke('library.delete.prepare',{ref},'plan');inode++;
assert.equal((await invoke('library.delete.confirm',{ref,planId:'plan'},'confirm')).reason,'RESOURCE_CHANGED');
access.pending='';result=await invoke('library.list',{},'new');
assert.equal((await invoke('library.toggle',{ref:result.data.items[0].ref,enabled:false},'off')).status,'ok');
assert.equal(files.has('/mods/a.jar.disabled'),true);
console.log('PASS: registry task capabilities, destructive confirmation identity/epoch, live settings, resource file replacement and toggle');

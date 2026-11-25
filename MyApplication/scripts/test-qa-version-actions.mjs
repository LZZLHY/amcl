// 执行真实库存、参数处理、任务归属与冷恢复。平台提供受控文件系统和模拟队列边界。
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const texts = new Map(), directories = new Set(['/mc/versions/good','/mc/versions/partial']);
const listeners = new Set(), adapters = new Map(), activities = new Map();
const fs = {
  async listFile() { return ['partial', 'download-temp', '.hidden', 'good']; },
  async stat(path) {
    if (directories.has(path)) return { isDirectory: () => true, mtime: 42 };
    return { size: 2000000 };
  },
  async readText(path) { return path.includes('/good/') ? '{"id":"good","mainClass":"mc"}' : '{}'; },
  lstatSync(path) {
    if (!directories.has(path) && !texts.has(path)) throw Object.assign(Error('missing'), { code: 13900002 });
    return { isFile: () => texts.has(path), isSymbolicLink: () => false, size: texts.get(path)?.length ?? 0 };
  },
  accessSync: path => texts.has(path) || directories.has(path),
  readTextSync: path => texts.get(path),
};
const coreKit = { fileIo: fs };
const common = { isVersionInstalled: () => false, LogTags: {MOD_MAVEN:'Maven'},
  writeEvidenceTextAtomic: (p,s) => texts.set(p,s), ledgerManifest: (_p,id) => activities.get(id) ?? null,
  LedgerState: { SUCCESS:1, FAILED:2, ABORTED:3 }};
const maven = makePureEtsLoader({ commons: common,'@kit.CoreFileKit':coreKit, '@kit.NetworkKit':{},
  '@kit.PerformanceAnalysisKit':{},'@kit.CryptoArchitectureKit':{},'../download/DownloadManager':{},
  '../download/SourceProber':{},'./MavenSpecBuilder':{} })('feature_core/src/main/ets/modloader/MavenUtils.ets');
const library = makePureEtsLoader({commons:common,'@kit.CoreFileKit':coreKit,'../modloader/MavenUtils':maven})(
  'feature_core/src/main/ets/version/LocalVersionInventory.ets');
const inventory = () => library.readLocalVersionInventory('/mc',()=>[]);
assert.deepEqual(await inventory(), { installed:['good'], orphans:['partial'], error:'' });
assert.notEqual(library.versionInstallNameError('/mc','..'),'');
assert.notEqual(library.versionInstallNameError('/mc','.private'),'');
const core = {...library,...maven, ActivityCategory:{DOWNLOAD:'download'},TaskCategory:{MC_VERSION:'mc'},
  UnifiedTaskState:{DONE:'done',ERROR:'error',ABORTED:'aborted',WAITING:'waiting',VERIFYING:'verifying'}, ModLoaderType:{FABRIC:'fabric',FORGE:'forge'},
  listMcInstallRecovery:()=>[]};
let identity = {gameVersion:'1.0',loader:'vanilla',loaderVersion:''};
const loadAdapter = () => makePureEtsLoader({mods:{inspectInstalledVersion:()=>identity,inspectLegacyVanilla:async()=>null},commons:common,'@kit.CoreFileKit':coreKit,feature_core:core})(
  'entry/src/main/ProductQaVersions.ets').ProductQaVersions;
function deferred(){let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j;});return {promise,resolve,reject};}
const companions = new Map();
let blocked='LAUNCHER_NOT_INTERACTIVE', downloadPanel=false;
let adapter = loadAdapter(), selected='initial', installs=0, active=true, session='/qa/session-a', admission='';
const registry = { get:id=>adapters.get(id)?.view??null, getAdapter:id=>adapters.get(id)??null,
  listAll:()=>[...adapters.values()].map(a=>a.view), addListener:f=>listeners.add(f),removeListener:f=>listeners.delete(f)};
const port = {filesDir:'/files', initialized:()=>true, ready:()=>active&&!downloadPanel, blockReason:()=>downloadPanel?'DOWNLOAD_TASKS_OPEN':active?'':blocked,
  taskBlock:()=>active?'':blocked, selected:()=>selected, root:()=>'/mc', inventory,
  select:async v=>{selected=v;return true;}, registry, catalog:{getVersionList:async()=>({versions:[{id:'1.0',type:'release'}]})},
  supportedLoaders:()=>['fabric','forge'],loaderAdmission:()=>admission,suggestedName:(g,l,v)=>l?g+'-'+l+'-'+v:g,
  loaders:{getSupportedGameVersions:async()=>['1.0'],getLoaderVersions:async loader=>[{loader,gameVersion:'1.0',loaderVersion:'one',stable:true}]},
  companion:async()=>({version:{id:'compatible'},iconUrl:'https://example.invalid/fabric.png'}),
  install(game,name,loader,version,api,icon){ installs++;
    const a={startedAtMs:0,view:{id:'mc:'+name,category:'mc',title:name,state:'waiting',bytesDone:0,bytesTotal:0,startedAtMs:0},loader,version,api,icon};
    adapters.set('mc:'+name,a);const submission={adapter:a};
    if(api){const gate=deferred();companions.set(name,gate);submission.companion=gate.promise;}
    return submission; }};
const run=async(action,args={},id='r123')=>JSON.parse(await adapter.run(port,action,JSON.stringify(args),id,()=>session));
assert.deepEqual((await run('versions.list')).data,{installed:['good'],orphans:['partial'],selected:''});
assert.equal(selected,'initial');
downloadPanel=true;
assert.equal((await run('versions.list')).status,'ok');
assert.equal((await run('versions.inspect',{version:'good'})).status,'ok');
assert.equal((await run('versions.select',{version:'good'})).reason,'DOWNLOAD_TASKS_OPEN');
downloadPanel=false;
assert.equal((await run('versions.inspect',{version:'good'})).data.gameVersion,'1.0');
identity=null;assert.equal((await run('versions.inspect',{version:'good'})).status,'unknown');
active=false;blocked='VERSION_SCAN_PENDING';assert.equal((await run('versions.list')).status,'unknown');
blocked='LAUNCHER_NOT_INTERACTIVE';assert.equal((await run('versions.list')).status,'needsUser');active=true;
assert.equal((await run('versions.select',{version:'partial'})).status,'rejected');
assert.equal((await run('versions.select',{version:'good',ifSelected:'someone-else'})).reason,'SELECTION_CHANGED');
assert.equal((await run('versions.select',{version:'good'})).data.selected,'good');
assert.equal((await run('versions.remote',{gameVersion:'missing'})).data.total,0);
assert.equal((await run('versions.remote',{offset:-1})).status,'rejected');
assert.equal((await run('versions.install',{gameVersion:'missing'})).reason,'REMOTE_VERSION_NOT_FOUND');
assert.equal((await run('versions.install',{gameVersion:'1.0',versionName:'partial'})).reason,'TARGET_UNAVAILABLE');
assert.equal((await run('versions.install',{gameVersion:'1.0',loader:'quilt',loaderVersion:'one'})).status,'rejected');
assert.deepEqual((await run('loaders.list')).data.loaders,['fabric','forge']);
assert.deepEqual((await run('loaders.games',{loader:'fabric'})).data.versions,['1.0']);
assert.deepEqual((await run('loaders.versions',{loader:'forge',gameVersion:'1.0'})).data.versions,[{id:'one',stable:true}]);
assert.equal((await run('versions.install',{gameVersion:'1.0',loader:'fabric',loaderVersion:'bad'})).reason,'LOADER_VERSION_NOT_FOUND');
admission='INSTALLER_JDK_REQUIRED';assert.equal((await run('versions.install',{gameVersion:'1.0',loader:'forge',loaderVersion:'one'})).status,'needsUser');admission='';
active=false;assert.equal((await run('versions.install',{gameVersion:'1.0'})).status,'needsUser');active=true;
assert.equal(installs,0);
const originalCatalog = port.catalog.getVersionList;
port.catalog.getVersionList=async()=>{session='/qa/changed';return {versions:[{id:'1.0',type:'release'}]};};
assert.equal((await run('versions.install',{gameVersion:'1.0'})).reason,'LAUNCHER_CHANGED');assert.equal(installs,0);
session='/qa/session-a';port.catalog.getVersionList=originalCatalog;
const accepted=await run('versions.install',{gameVersion:'1.0'});
assert.equal(accepted.status,'accepted');assert.equal(installs,1);
const argumentsForTask={taskId:accepted.data.taskId,installRequestId:accepted.data.installRequestId};
assert.equal((await run('tasks.get',argumentsForTask)).data.state,'waiting');
assert.equal((await run('tasks.get',{...argumentsForTask,installRequestId:'foreign'})).status,'unknown');
assert.equal((await run('versions.install',{gameVersion:'1.0'})).status,'rejected');assert.equal(installs,1);
const original=adapters.get('mc:1.0');original.startedAtMs=320;Object.assign(original.view,{startedAtMs:320,state:'downloading',bytesDone:65,bytesTotal:100});
for(const f of [...listeners])f();assert.equal(listeners.size,0);
assert.equal((await run('tasks.get',argumentsForTask)).data.bytesDone,65);
adapters.set('secret',{view:{id:'secret:/private/path?token=hidden',title:'ab',category:'export',state:'waiting',bytesDone:0,bytesTotal:0,startedAtMs:0}});
const listing=await run('tasks.list');assert.equal(listing.data.total,2);assert.doesNotMatch(JSON.stringify(listing),/private|secret|token/);
assert.equal((await run('tasks.list',{offset:1,limit:1})).data.tasks[0].taskId,listing.data.tasks[1].taskId);
// 原队列已销毁时仅接受同活动、同根、同版本、同加载器的耐久终态。
adapters.clear();adapter=loadAdapter();
assert.equal((await run('tasks.get',argumentsForTask)).status,'unknown');
const proof={activityId:320,mcDir:'/wrong',gameVersionId:'1.0',loaderType:'vanilla',loaderVersion:'',title:'1.0',
  category:'download',outcomeSource:'task.owner',state:1,taskFacts:{totalBytes:100}};
activities.set(320,proof);assert.equal((await run('tasks.get',argumentsForTask)).status,'unknown');
proof.mcDir='/mc';assert.equal((await run('tasks.get',argumentsForTask)).data.state,'done');
assert.equal((await run('versions.install',{gameVersion:'1.0'})).reason,'REQUEST_ALREADY_RECORDED');assert.equal(installs,1);
const fabric=await run('versions.install',{gameVersion:'1.0',loader:'fabric',loaderVersion:'one'},'fabric');
assert.equal(fabric.status,'accepted');assert.equal(adapters.get(fabric.data.taskId).api.id,'compatible');
assert.equal(adapters.get(fabric.data.taskId).icon,'https://example.invalid/fabric.png');
port.companion=async()=>null;
assert.equal((await run('versions.install',{gameVersion:'1.0',loader:'fabric',loaderVersion:'one',versionName:'other'},'next')).reason,'FABRIC_API_UNAVAILABLE');
assert.equal((await run('versions.install',{gameVersion:'1.0',loader:'fabric',loaderVersion:'one',versionName:'other',withFabricApi:false},'next')).status,'accepted');
console.log('PASS production inventory, read-only parity, loader filters, fresh targets, queue observation, cold identity, safe summaries and Fabric option');

// 模拟父任务完成时子任务尚未生成、已开始但尚在写入、拒绝入队、以及进程重启后的精确父子证据。
const settle=()=>new Promise(resolve=>setImmediate(resolve));
async function fabricCase(id,start){
 port.companion=async()=>({version:{id:'compatible'},iconUrl:''});
 const accepted=await run('versions.install',{gameVersion:'1.0',loader:'fabric',loaderVersion:'one',versionName:id},id);
 const q={taskId:accepted.data.taskId, installRequestId:id};
 const parent=adapters.get(q.taskId);parent.startedAtMs=start;
 Object.assign(parent.view,{state:'done',startedAtMs:start});
 for(const fn of [...listeners])fn();
 activities.set(start,{...proof,activityId:start,title:id,loaderType:'fabric',loaderVersion:'one'});
 assert.equal((await run('tasks.get',q)).data.state,'waiting');
 return {q,gate:companions.get(id),parent};
}
const slow=await fabricCase('slow',501), end=deferred();
const child={view:{id:'mod-plan:private',parentActivityId:501,activityRelation:'companion',activityMcDir:'/mc',
 activityGameVersion:'slow',title:'Fabric API',startedAtMs:502,state:'downloading',bytesDone:11,bytesTotal:30},completion:end.promise};
adapters.set(child.view.id,child);slow.gate.resolve(child);await settle();
assert.equal((await run('tasks.get',slow.q)).data.state,'downloading');
child.view.state='done';assert.equal((await run('tasks.get',slow.q)).data.state,'verifying');
end.resolve();await settle();assert.equal((await run('tasks.get',slow.q)).data.state,'done');
adapter=loadAdapter();assert.equal((await run('tasks.get',slow.q)).status,'unknown','只有父活动已成功仍不授予整条完成');
const childProof={activityId:502,parentActivityId:500,relation:'companion',category:'mod_install',title:'Fabric API',mcDir:'/mc',gameVersionId:'slow',outcomeSource:'task.owner',state:1};
activities.set(502,childProof);assert.equal((await run('tasks.get',slow.q)).status,'unknown');
childProof.parentActivityId=501;assert.equal((await run('tasks.get',slow.q)).data.state,'done');
childProof.state=2;assert.equal((await run('tasks.get',slow.q)).data.state,'error');
const failed=await fabricCase('failed',504);failed.gate.reject(Error('not admitted'));await settle();
assert.equal((await run('tasks.get',failed.q)).data.state,'error');adapter=loadAdapter();
assert.equal((await run('tasks.get',failed.q)).data.state,'error');
// 目录扫描挂起时，用户的拖动应在最后一次文件读取完成后生效。
const oldList=fs.listFile,oldStat=fs.stat,oldRead=fs.readText,paused=deferred();
fs.listFile=async()=>['a','b'];fs.stat=async()=>({isDirectory:()=>true,mtime:42,size:2000000});
fs.readText=async()=>{await paused.promise;return '{"id":"valid","mainClass":"mc"}';};
let order=['a','b'];const scanning=library.readLocalVersionInventory('/mc',()=>order);
order=['b','a'];paused.resolve();assert.deepEqual((await scanning).installed,['b','a']);
Object.assign(fs,{listFile:oldList,stat:oldStat,readText:oldRead});
console.log('PASS captured Fabric API child identity, child failure, partial/cold evidence and latest drag order after asynchronous scan');

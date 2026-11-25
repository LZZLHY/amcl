/** 运行实际 Skill 分派、活动认领和同一业务 port；系统选择器和 SDK 文件 I/O 单独替换。 */
import assert from 'node:assert/strict';
import ts from '../../scripts/lib/ets-compiler.mjs';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { verifySkillCases } from '../../scripts/lib/skill-business-check.mjs';
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';

const data = new Map(), entries = new Map();
let serial = 1;
const dir = path => entries.set(path,{ ino:serial++, mtime:1, ctime:1, size:0, dir:true });
const file = path => entries.set(path,{ ino:serial++, mtime:1, ctime:1, size:32, dir:false });
dir('/app'); dir('/mc'); dir('/mc/versions'); dir('/mc/versions/one'); dir('/mc/versions/two');
const fs = {
  accessSync: path=>entries.has(path), mkdirSync(path) { if(entries.has(path)) throw Error('exists'); dir(path); },
  lstatSync(path) {
    const v=entries.get(path);
    if(!v) throw Object.assign(Error('not found'),{code:13900002});
    return {...v, isDirectory:()=>v.dir, isFile:()=>!v.dir, isSymbolicLink:()=>!!v.link};
  }, readTextSync:path=>data.get(path),
};
const atomic={write(path,text){file(path);data.set(path,text);}};
const activity=new Map(); const running=new Map(); const listeners=new Set();
class VersionTask {}
class PackTask {}
const registry={get:id=>running.get(id)?.view??null,getAdapter:id=>running.get(id)??null,listAll:()=>[...running.values()].map(v=>v.view),
  addListener:f=>listeners.add(f), removeListener:f=>listeners.delete(f), pause:async id=>{running.get(id).view.state='paused';},
  purgeFinished(){let n=0;for(const [id,a] of running)if(a.view.state==='done'){running.delete(id);n++;}return n;}};
const core={safeBaseName:v=>v&&v!=='.'&&v!=='..'&&!/[\/\\]/.test(v)?v:'',claimVersionInstall:()=>()=>{},
  versionInstallNameError:()=>'',listMcInstallRecovery:()=>[],ModLoaderType:{FABRIC:'fabric'},McVersionTask:VersionTask,
  TaskCategory:{MC_VERSION:'mc',MODPACK:'modpack',MOD:'mod',SHADER:'shader',RESOURCE_PACK:'resourcepack',DATAPACK:'datapack'},getDownloadTaskRegistry:()=>registry,isTerminalState:s=>s==='done',
  UnifiedTaskState:{WAITING:'waiting',DONE:'done',ERROR:'error',ABORTED:'aborted'},isInProgressState:s=>s==='downloading',aggregateProgress:()=>41};
const mods={classifyVersion:id=>id.includes('22w')?'snapshot':'release',ResourceKind:{MODPACK:'modpack'},ModpackInstallTask:PackTask,modpackFileKey:f=>f.id,
  inspectInstalledVersion:(_,name)=>({gameVersion:'1.20.1',loader:name==='one'?'fabric':'vanilla',loaderVersion:'0.15'})};
const kit={'@kit.CoreFileKit':{fileIo:fs},'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},'feature_core':core,mods,
  commons:{validateVersionName:n=>n.startsWith('.')?'invalid':'',AtomicFileWriter:atomic,LedgerState:{SUCCESS:1,ABORTED:3},ledgerManifest:(_,id)=>activity.get(id)??null}};
const folder='entry/src/main/ets/launcherskill/';
const fixture=makePureEtsLoader(kit);
const {LauncherLibrary}=fixture(folder+'LauncherLibrary.ets');
const {SkillFileScope}=fixture(folder+'SkillFileScope.ets');
const {BrowseSkill}=fixture(folder+'BrowseSkill.ets');
const {TaskPanelSkill}=makePureEtsLoader({...kit,'./TaskControlOperations':fixture(folder+'TaskControlOperations.ets'),'../components/DownloadTaskSnapshot':fixture('entry/src/main/ets/components/DownloadTaskSnapshot.ets')})(folder+'TaskPanelSkill.ets');
let selected='two', list=['one','two'], root='/mc', interactive=true, busy=false, scoped=true, confirm=async()=>true;
const view = (id, n) => ({id,startedAtMs:n,state:'downloading',title:'owned',canPause:true});
const submission = new VersionTask();submission.view=view('mc:new',85);submission.dlState={phaseDetails:[]};
let installs=0, launches=0, lastPage='';
const versions={ filesDir:'/app',root:()=>root,selected:()=>selected,initialized:()=>true,ready:()=>interactive,blockReason:()=>'modal',taskBlock:()=>'',
  inventory:async()=>({installed:list,orphans:[],error:''}),supportedLoaders:()=>['fabric'],loaderAdmission:()=>'',
  loaders:{getLoaderVersions:async()=>[{gameVersion:'1.20.1',loader:'fabric',loaderVersion:'0.15',stable:true}]},
  catalog:{getVersionList:async()=>({versions:[{id:'1.20.1',type:'release',displayDate:'2023'},{id:'22w1',type:'snapshot',displayDate:'2022'}]})},
  select:async v=>{selected=v;return true;},registry,install(){installs++;running.set('mc:new',submission);return {adapter:submission,completion:Promise.resolve()};}};
const currentSettings={jdkVersion:'auto',gameLanguage:'zh_cn',renderScalePercent:0};
const manager={ gameBusy:()=>busy, settings:()=>currentSettings,jdkChoices:()=>['17'],saveJdk:async(_,j)=>(currentSettings.jdkVersion=j,true),
  saveResolution:async(_,v)=>{currentSettings.renderScalePercent=v;},prepareRename:()=> (a,b)=>{list=list.map(v=>v===a?b:v);return true;},
  prompt(){},remove:async()=>true};
let storeAction='checking', remoteGame=0, exportTask=null, selectTarget=true, menu, selectedStore='';
let pushRoute=async()=>{},repairOutcome={state:'unknown',reason:'admissionPending'};
const {canPerformStoreManagerAction}=fixture('entry/src/main/ets/components/StoreManagerUiPolicy.ets');
const storeFile=readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8');
const storeAst=ts.createSourceFile('Index.ets',storeFile,ts.ScriptTarget.Latest,true);
const storeOwner=storeAst.statements.find(node=>node.name?.text==='Index');
const storeMethods=['handleStoreManagerAction_','openStoreExport_','returnExistingGame_','jumpToDownloadSub'].map(name=>
  storeOwner.members.find(m=>m.name?.getText(storeAst)===name).getText(storeAst));
const storeClass=ts.transpileModule('class Page {'+storeMethods.join('\n')+'}\nreturn Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
const Page=new Function('canPerformStoreManagerAction','getGameExportCoordinator','existingGameSessionHost','testNapi',storeClass)(
  canPerformStoreManagerAction,()=>({getTask:()=>exportTask}),()=>undefined,{desktopGameProcessState:()=>remoteGame});
const storePage=Object.assign(new Page(),{storeManagerAction_:storeAction,showTasksSheet:false,mcRoot:()=>'/mc',mcVersion:'one',
  versionIsolation:true,theme:{actionText:'#000'},getUIContext:()=>({getRouter:()=>({pushUrl:opts=>pushRoute(opts)}),
    getPromptAction:()=>({showActionMenu:()=>menu})}),context:{filesDir:'/app',startAbility:()=>pushRoute()},
  versionActionBlock_:()=>'',recoveryPresentationEpoch_:1,storeCheckGeneration_:0,storeReadyVersions_:['two'],
  selectManagedVersion_:async name=>{selectedStore=name;return selectTarget},repairVersionFiles:()=>repairOutcome,
  refreshStoreManager_(){this.storeCheckGeneration_++},safeToast_(){},tabController:{changeIndex(){}},dlNavCounter_:0});
const ui={focus:async()=>true,window:()=>({windowId:0,visibility:'unobserved'}),current:()=>scoped,homeSummary:()=>({state:'ready',selected}),loader:n=>n==='one'?'fabric':'vanilla',
  reorder:v=>list=v,currentOrder:()=>list,open:async p=>(lastPage=p,true),runningAllowed:()=>true,storeAction:()=>storeAction,performStoreAction:awaitUser=>storePage.handleStoreManagerAction_(awaitUser),
  launch:async(_,observer)=>{launches++;observer.beginChecks();observer.bind(99,false);observer.sent();},
  confirm:message=>confirm(message),graphicsResult:id=>({state:'ready',activityId:id}),effectiveSettings:()=>({memoryMiB:2048}),showCatalogVersion:(id,type)=>{lastPage=id+'/'+type;}};
let lib=new LauncherLibrary(()=>versions,()=>manager,ui);
const contracts=new Map(JSON.parse(readFileSync(new URL('../../config/launcher-skill/instances.json',import.meta.url),'utf8').replace(/^\uFEFF/,'' )).map(m=>[m.name,m]));
// 对照实际业务回包。通用入口异常可产生四种输送状态，成功/受理/接力取决于具体方法。
const universal=['failed','unknown','busy','unavailable'];
const cmd=async(m,a={})=>{
  const value=await lib.run(m,a);
  assert.ok([...contracts.get(m).results,...universal].includes(value.state),m+' undeclared outcome '+value.state);
  return value;
};
const currentTasks=await cmd('getLauncherTasks');
assert.deepEqual(currentTasks.tasks,[]);
versions.taskBlock=()=>'notReady';
const blockedTasks=await cmd('getLauncherTasks');
assert.equal(blockedTasks.reason,'launcherUnavailable');
verifySkillCases('getLauncherTasks',currentTasks,blockedTasks);
versions.taskBlock=()=>'';
assert.deepEqual((await cmd('listInstances',{loader:'fabric'})).instances,['one']);
const originalLoader=ui.loader;
ui.loader=instance=>instance==='two'?'neoforge':originalLoader(instance);
const neoList=await cmd('listInstances',{loader:'neoforge'});
assert.deepEqual(neoList.instances,['two']);
assert.deepEqual((await cmd('listInstances',{loader:'forge'})).instances,[]);
ui.loader=originalLoader;
const originalInventory=versions.inventory;
versions.inventory=async()=>({installed:[],orphans:[],error:'scan'});
const unreadableList=await cmd('listInstances');
assert.equal(unreadableList.reason,'inventoryUnavailable');
versions.inventory=originalInventory;
verifySkillCases('listInstances',neoList,unreadableList);
assert.equal(selected,'two');assert.equal((await cmd('inspectGameInstance',{instance:'one'})).loader,'fabric');
assert.equal((await cmd('selectGameInstance',{instance:'one'})).selected,'one');
assert.equal((await cmd('selectGameInstance',{instance:'../escape'})).state,'failed');
assert.deepEqual((await cmd('moveInstanceBefore',{instance:'two',before:'one'})).order,['two','one']);
assert.equal((await cmd('getLauncherHome')).selected,'one');assert.equal((await cmd('focusRunningGame')).reason,'existingWindowFocusRequested');
assert.equal((await cmd('openInstancePanel',{instance:'one',panel:'saves'})).state,'needsUser');assert.equal(lastPage,'saves');
assert.ok(!contracts.get('openInstancePanel').results.includes('ready'),'打开实例面板的成功交接是 needsUser');
assert.equal((await cmd('listGameCatalog',{category:'snapshot'})).versions[0].id,'22w1');
assert.equal((await cmd('listGameLoaders',{gameVersion:'1.20.1',loader:'fabric'})).versions[0].version,'0.15');
await cmd('showCatalogVersion',{gameVersion:'22w1'});assert.equal(lastPage,'22w1/snapshot');
assert.equal((await cmd('setInstanceJdk',{instance:'one',jdk:'17'})).state,'ready');
assert.equal((await cmd('setInstanceResolution',{instance:'one',percent:70})).percent,70);
assert.equal((await cmd('getInstanceSettings',{instance:'one'})).resolution,70);
const storeDenied=await cmd('performStoreManagerAction',{action:'checking'});
assert.equal(storeDenied.reason,'actionUnavailable');
assert.equal(storePage.showTasksSheet,false);
storeAction=storePage.storeManagerAction_='downloads';
assert.equal((await cmd('performStoreManagerAction',{action:'checking'})).reason,'actionChanged');
const storeAccepted=await cmd('performStoreManagerAction',{action:storeAction});
assert.equal(storeAccepted.state,'accepted');assert.equal(storePage.showTasksSheet,true);
verifySkillCases('performStoreManagerAction',storeAccepted,storeDenied);
const store=action=>{storeAction=storePage.storeManagerAction_=action;return cmd('performStoreManagerAction',{action});};
assert.equal((await store('session')).state,'failed');
remoteGame=1;pushRoute=async()=>{throw Error('denied')};assert.equal((await store('session')).state,'failed');
assert.equal((await store('export')).state,'failed');
assert.equal((await store('progress')).state,'failed');
exportTask={id:'original',state:'running',request:{mcRoot:'/mc',versionId:'one'}};
assert.equal((await store('progress')).state,'failed');
let releaseRoute;pushRoute=()=>new Promise(resolve=>{releaseRoute=resolve});
for (const action of ['session','export','progress']) {
  let finished=false;const pending=store(action).then(result=>{finished=true;return result});
  await Promise.resolve();assert.equal(finished,false);releaseRoute();
  assert.equal((await pending).state,'accepted');
}
exportTask.state='done';assert.equal((await store('progress')).state,'failed');
for (const action of ['storage','check','download']) assert.equal((await store(action)).state,'accepted');
storePage.tabController.changeIndex=()=>{throw Error('unavailable')};
assert.equal((await store('download')).state,'failed');
const {LauncherSkillBus}=fixture(folder+'LauncherSkillBus.ets');
const busOwner={};LauncherSkillBus.attach(busOwner,()=>true,randomUUID);
LauncherSkillBus.bind('library',busOwner,(method,args)=>cmd(method,args));
async function startMenu(action) {
  let resolveMenu,rejectMenu;
  menu=new Promise((resolve,reject)=>{resolveMenu=resolve;rejectMenu=reject});
  storeAction=storePage.storeManagerAction_=action;
  const handoff=await LauncherSkillBus.call('library','performStoreManagerAction',{action});
  assert.equal(handoff.reason,'awaitingUser');assert.ok(handoff.operationRef);
  const get=()=>LauncherSkillBus.call('handoffReceipt','getLauncherHandoff',{method:'performStoreManagerAction',operationRef:handoff.operationRef});
  assert.equal((await get()).reason,'awaitingUser');
  return async(index,error)=>{if(error)rejectMenu(error);else resolveMenu({index});
    // 等原业务派发和同一次决策结账，跨越宿主下一轮事件即可回读。
    await new Promise(resolve=>setImmediate(resolve));return (await get()).outcome;};
}
let finishMenu=await startMenu('choose');
assert.equal((await finishMenu(0,Error('cancel'))).state,'cancelled');assert.equal(selectedStore,'');
finishMenu=await startMenu('repair');assert.equal((await finishMenu(0,Error('platform failure'))).state,'failed');
finishMenu=await startMenu('choose');storePage.recoveryPresentationEpoch_++;assert.equal((await finishMenu(0)).state,'failed');
assert.equal(selectedStore,'');selectTarget=false;finishMenu=await startMenu('choose');assert.equal((await finishMenu(0)).state,'failed');
selectTarget=true;finishMenu=await startMenu('choose');assert.equal((await finishMenu(0)).state,'accepted');assert.equal(selectedStore,'two');
finishMenu=await startMenu('repair');assert.equal((await finishMenu(1)).state,'unknown');
repairOutcome={state:'accepted'};finishMenu=await startMenu('repair');assert.equal((await finishMenu(1)).state,'accepted');
finishMenu=await startMenu('repair');assert.equal((await finishMenu(0)).state,'accepted');assert.equal(storePage.showVersionManager,true);
LauncherSkillBus.detach(busOwner);
const install={operationRef:'original-install',gameVersion:'1.20.1',instance:'new',loader:'fabric',loaderVersion:'0.15',withFabricApi:false};
assert.equal((await cmd('installGameInstance',install)).activityId,85);
lib=new LauncherLibrary(()=>versions,()=>manager,ui);
assert.equal((await cmd('installGameInstance',install)).activityId,85);assert.equal(installs,1);
assert.equal((await cmd('installGameInstance',{...install,instance:'another'})).reason,'operationRefConflict');
assert.equal((await cmd('getLauncherOperation',{operationRef:'original-install'})).taskId,'mc:new');
// 槽满时 Registry 会在重试出队前保留父活动号，查询始终绑定第一次安装。
activity.set(85,{activityId:85,state:2,outcomeSource:'task.owner'});
Object.assign(submission.view,{state:'waiting',activityRelation:'retry',parentActivityId:85});
const previous=await cmd('getLauncherOperation',{operationRef:'original-install'});
assert.equal(previous.activityState,2);assert.equal(previous.activityId,85);assert.equal(previous.taskState,undefined);
assert.equal((await cmd('installGameInstance',install)).taskState,undefined);assert.equal(installs,1);
submission.view.startedAtMs=86;submission.view.state='downloading';
assert.equal((await cmd('getLauncherOperation',{operationRef:'original-install'})).taskState,undefined);
const missingOperation=await cmd('getLauncherOperation',{operationRef:'not-submitted'});
verifySkillCases('getLauncherOperation',previous,missingOperation);
const launch={instance:'one',operationRef:'original-launch'};
assert.equal((await cmd('launchGameInstance',launch)).activityId,99);assert.equal((await cmd('launchGameInstance',launch)).activityId,99);assert.equal(launches,1);
confirm=async()=>false;assert.equal((await cmd('requestInstanceDeletion',{instance:'one'})).state,'cancelled');
confirm=async()=>{dir('/mc/versions/one');return true;};assert.equal((await cmd('requestInstanceDeletion',{instance:'one'})).reason,'instanceChanged');
assert.equal((await cmd('getGraphicsRecovery',{activityId:99})).activityId,99);
interactive=false;assert.equal((await cmd('selectGameInstance',{instance:'two'})).state,'needsUser');interactive=true;
console.log('PASS inventory/filter/order, true owner navigation/config, authorized catalog, persistent launch/install replay, changed delete target');

const identities=new SkillFileScope();dir('/mc/owned');file('/mc/owned/item');
const token=identities.list('/mc','/mc/owned','one'),ref=identities.row('item');assert.ok(token&&ref);
assert.equal(identities.resolve('/mc','/mc/owned','one',token,ref),'item');
assert.equal(identities.resolve('/mc','/mc/owned','two',token,ref),'');
file('/mc/owned/item');assert.equal(identities.resolve('/mc','/mc/owned','one',token,ref),'');
entries.get('/mc/owned').link=true;assert.equal(identities.list('/mc','/mc/owned','one'),'');
console.log('PASS file references reject symlink scopes, changed inode, other instance and stale handles');

const tasks=new TaskPanelSkill(registry,{active:()=>true,confirm:async()=>true,detail(){},recover(){}});
const t=(await tasks.run('listDownloadQueue',{filter:'all'})).tasks[0];
assert.equal((await tasks.run('getDownloadTaskDetail',{ref:t.ref})).id,'mc:new');
submission.view.startedAtMs++;assert.equal((await tasks.run('controlDownloadTask',{ref:t.ref,action:'pause'})).reason,'taskChanged');
let tr=(await tasks.run('listDownloadQueue',{})).tasks[0].ref;
const paused=await tasks.run('controlDownloadTask',{ref:tr,action:'pause'});
assert.equal(paused.operationRef,tr);
assert.equal((await cmd('getTaskControlOperation',{operationRef:tr})).phase,'paused');
assert.equal((await tasks.run('controlDownloadTask',{ref:tr,action:'pause'})).operationRef,tr);
submission.view.state='done';assert.equal((await tasks.run('clearFinishedTasks',{})).removed,1);
console.log('PASS real queue projection, task controls refuse stale retry generations, clearing bound terminal objects');

const project={id:'p',source:'modrinth',title:'project',summary:'desc',kind:'mod'};
const version={id:'v',projectId:'p',source:'modrinth',versionNumber:'v1',loaders:['fabric'],gameVersions:['1.20.1'],files:[{filename:'file.jar',size:17,isPrimary:true}]};
const state={kind:'mod',hits:[project],totalHits:1,query:'',gameVersion:'',loader:'',hasMore:false,nextOffset:1,loading:false,errorMessage:null,errorKind:null,httpStatus:0};
let detail=null, available=true, resourceContext='root', dispatched=0;
const browsePort={filesDir:()=>'/app',available:()=>available,kind:()=>state.kind,contextKey:()=>resourceContext,view:()=>state,detail:()=>detail,
  search:async q=>{state.query=q;state.lastRequest={query:q};},open:async()=>{detail={project,versions:[version],session:3,revision:1,ready:true,loading:false,error:false,target:'one',root:'/mc',deps:[],file:{filename:'a.jar',url:'https://example.invalid',size:3}};},
  pick:async v=>{detail.selected=v;},submit(capture){dispatched++;const task={view:view('mod:p',52)};running.set(task.view.id,task);capture(task,Promise.resolve());},dismiss(){detail=null;}};
const browse=new BrowseSkill(()=>browsePort);
const hit=await browse.run('searchResources',{kind:'mod',query:'demo'});
const searchArgs={searchRef:hit.searchRef,project:'p',source:'modrinth'};
state.lastRequest={...state.lastRequest};state.hits=[];state.loading=true;
assert.equal((await browse.run('nextResourcePage',searchArgs)).reason,'searchPending');
assert.equal((await browse.run('getResourceVersions',searchArgs)).versions[0].id,'v');
detail.versions=Array.from({length:68},(_,i)=>({...version,id:'v'+i}));
detail.error=true; // 推荐文件不兼容，其他客户端候选仍可读取。
const remaining=await browse.run('getResourceVersions',{...searchArgs,offset:50});
assert.equal(remaining.total,68);assert.equal(remaining.versions[17].id,'v67');
detail.versions=[version];detail.error=false;state.loading=false;
detail.session++;assert.equal((await browse.run('closeResourceDetails',searchArgs)).reason,'searchChanged');
detail.session--;
const prepared=await browse.run('prepareResourceInstall',{...searchArgs,version:'v'});detail.target='other';
assert.equal((await browse.run('installResourcePlan',{...searchArgs,planRef:prepared.planRef})).reason,'planChanged');assert.equal(dispatched,0);
detail.target='one';const originalFile=detail.file;
const digestPlan=await browse.run('prepareResourceInstall',{...searchArgs,version:'v'});
detail.file={...originalFile,sha1:'replaced'};
assert.equal((await browse.run('installResourcePlan',{...searchArgs,planRef:digestPlan.planRef})).reason,'planChanged');
assert.equal(dispatched,0);detail.file=originalFile;
const current=await browse.run('prepareResourceInstall',{...searchArgs,version:'v'});
const added=await browse.run('installResourcePlan',{...searchArgs,planRef:current.planRef});
assert.equal(added.state,'accepted');assert.equal((await browse.run('getResourceInstall',{operationRef:added.operationRef})).activityId,52);
assert.equal((await browse.run('installResourcePlan',{...searchArgs,planRef:current.planRef})).state,'failed');assert.equal(dispatched,1);
resourceContext='other';
assert.equal((await browse.run('nextResourcePage',searchArgs)).reason,'searchChanged');
const closed=await browse.run('closeResourceDetails',searchArgs);
assert.equal(detail,null);
const staleClose=await browse.run('closeResourceDetails',searchArgs);
assert.equal(staleClose.reason,'searchChanged');
verifySkillCases('closeResourceDetails',closed,staleClose);
console.log('PASS resource search/version/plan/submit, target/source staleness and original task ownership');
const {ResourceOperation} = fixture(folder+'ResourceOperation.ets');
for (const missing of [[],[{name:'outside'}]]) {
  const key=randomUUID(),task=new PackTask();
  task.view={...view('modpack:'+key,601),title:'original name',category:'modpack',activityCategory:'modpack',activityGameVersion:'1.20.1',requiresConfirmation:true,canResume:true};
  task.getSession=()=>({complete:task.view.state==='done'});
  task.getResult=()=>task.view.state==='done'?{versionName:'user-selected (2)',missing}:null;
  task.canChooseOtherPackage=()=>false;running.set(task.view.id,task);
  ResourceOperation.claim('/app',key);
  ResourceOperation.watch('/app',key,task,Promise.resolve());await Promise.resolve();
  task.view.state='paused';for(const fn of [...listeners])fn();
  assert.equal(ResourceOperation.read('/app',key).requiresConfirmation,true);
  task.view.state='done';task.view.title='user-selected (2)';task.view.canResume=false;task.view.requiresConfirmation=false;
  activity.set(601,{activityId:601,title:'original name',category:'modpack',gameVersionId:'1.20.1',state:1,outcomeSource:'task.owner'});
  for(const fn of [...listeners])fn();await Promise.resolve();
  running.delete(task.view.id);
  const cold=ResourceOperation.read('/app',key);
  assert.deepEqual([cold.phase,cold.instance,cold.missingCount,cold.completeness],['done','user-selected (2)',missing.length,missing.length?'partial':'complete']);
  activity.set(601,{activityId:601,title:'another task',category:'modpack',gameVersionId:'1.20.1',state:1,outcomeSource:'task.owner'});
  assert.equal(ResourceOperation.read('/app',key).state,'unknown');
  assert.throws(()=>ResourceOperation.claim('/app',key));
}
console.log('PASS modpack admission/pause, user completion, persisted original attribution and complete/partial outcomes across detached views');

// 同一正常构建入口继续运行目录租约、控制回执与整合包既有任务换代回归。
await import('./test-skill-task-ownership.mjs');

/** 在原动作分派上替换页面和 HDC/系统边界，覆盖查询来源、过期确认、依赖选择与真实任务身份。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';

const dir='/sandbox/session';
const owned=new Map(),listeners=new Set(),disk=new Map();
const registry={getAdapter:id=>owned.get(id),addListener:f=>listeners.add(f),removeListener:f=>listeners.delete(f),
  notify:()=>{for (const callback of [...listeners]) callback();}};
const page={};let dispatch,detail=null,draft=null,active=true,kind='mod',view,context='root',imports=0,submits=0,latest,resolvePicker;
const core={getDownloadTaskRegistry:()=>registry,TaskCategory:{MODPACK:'modpack',MC_VERSION:'mc'},ActivityCategory:{MODPACK:'pack',MOD_INSTALL:'mod'},
  isTerminalState:s=>['done','aborted','error'].includes(s),safeBaseName:s=>s};
const ledger=new Map(),versions=[{source:'modrinth',projectId:'p',id:'v',versionNumber:'3.4',loaders:['fabric'],gameVersions:['1.20.1']}];
let file={url:'https://secret.invalid/token',filename:'tool.jar',sha1:'a'.repeat(40)};
const deps={'entry/ProductQa':{ProductQa:{sessionDirectory:()=>dir,bindSurface:(_,owner,f)=>{assert.equal(owner,page);dispatch=f;},unbindSurface(){}}},
 'feature_core':core,'mods':{ResourceKind:{MOD:'mod',MODPACK:'modpack',SHADER:'shader',RESOURCE_PACK:'resourcepack'},modpackFileKey:f=>f.key},
 'commons':{AtomicFileWriter:{write:(p,s)=>disk.set(p,s)},ledgerManifestAsync:async(_,id)=>ledger.get(id),
   LedgerState:{SUCCESS:1,FAILED:2,ABORTED:3}},'@kit.CoreFileKit':{fileIo:{
   accessSync:p=>disk.has(p),lstatSync:p=>({isFile:()=>true,isSymbolicLink:()=>false,size:disk.get(p).length}),readTextSync:p=>disk.get(p)}}};
const Resource=makePureEtsLoader(deps)('entry/src/main/ProductQaResources.ets').ProductQaResources;
function task(pack=false){
  const options=[{key:'server/path/private/abc',path:'mods/plugin.jar',selected:false}];
  return {view:{id:pack?'pack:1':'/sensitive/root@url',state:'running',startedAtMs:23,title:'name',category:pack?'modpack':'mod',
    requiresConfirmation:pack,activityGameVersion:'game'},getSession:()=>({id:'pack',complete:false}),getResult:()=>null,getInstallName:()=> 'name',
    requiresPackageSelection:()=>false,canChooseOtherPackage:()=>false,packageCandidates:()=>[],optionalFiles:()=>options,optionalSelected:f=>f.selected,
    setOptionalSelected:(f,sel)=>{f.selected=sel;},confirmAndResume:async function(_registry,committed){this.view.requiresConfirmation=false;committed();}};
}
function enqueue(capture,pack){
  latest=task(pack);submits++;owned.set(latest.view.id,latest);registry.notify();capture(latest,Promise.resolve());
}
const port={available:()=>active,filesDir:()=>'/sandbox',kind:()=>kind,contextKey:()=>context,
  search:async(query,loader,game,sort)=>{view={lastRequest:{loaders:[loader],gameVersion:game},kind,query,sortBy:sort,
    hits:[{id:'p',source:'modrinth',kind,title:'Pack',websiteUrl:'https://secret.invalid'}],hasMore:false,nextOffset:1,totalHits:1,loading:false,errorMessage:null,httpStatus:0};},
  next:async()=>{},view:()=>view,detail:()=>detail,local:()=>draft,
  open:async(p)=>{detail={project:p,versions,selected:versions[0],file,session:1,revision:1,loading:false,error:false,ready:true,
    name:'name',root:'/sensitive',target:'instance',sourcePolicy:'official',isolation:true,
    deps:[{key:'opt',dependencyType:'optional',displayName:'optional',selected:false,alreadyInstalled:false}]};},
  pick:async(v)=>{detail.selected=v;detail.revision++;},toggle:async()=>{detail.deps[0].selected=!detail.deps[0].selected;detail.revision++;},
  rename:n=>{detail.name=n;},submit:c=>{enqueue(c,kind==='modpack');detail=null;},dismiss:()=>{detail=null;},
  importLocal:()=>{imports++;return new Promise(r=>{resolvePicker=r;});},
  renameLocal:n=>{draft.name=n;},submitLocal:c=>{enqueue(c,true);draft=null;}};
Resource.bind(page,()=>port);
let id=0;
async function run(action,args){return JSON.parse(await dispatch(action,JSON.stringify(args),(++id).toString(16).padStart(32,'0')));}
// 只确认导航实际挂载的类型，不把未就绪、错分类或其他详情冒充原目标。
assert.equal((await run('resources.status',{kind:'bad'})).status,'rejected');
assert.equal((await run('resources.status',{kind:'shader'})).reason,'RESOURCE_PAGE_PENDING');
active=false;assert.equal((await run('resources.status',{kind:'mod'})).data.ready,false);active=true;
assert.deepEqual((await run('resources.status',{kind:'mod'})).data,
  {kind:'mod',ready:true,detailOpen:false,detailOwned:false,localDetailOpen:false});
const search=await run('resources.search',{kind:'mod',query:'q',sort:'relevance',loader:'fabric',gameVersion:'1.20.1'});
assert.equal(search.status,'ok');assert(!JSON.stringify(search).includes('https://'));const searchId=search.data.searchId;
assert.equal((await run('resources.versions',{searchId,source:'curseforge',projectId:'p'})).status,'rejected');
// 已确认结果在同筛选的后台刷新中保持可打开。分页不能假认刷新后的游标。
view.lastRequest={...view.lastRequest};view.hits=[];view.loading=true;
assert.equal((await run('resources.next',{searchId})).reason,'SEARCH_PENDING');
const versionArgs={searchId,source:'modrinth',projectId:'p'};
assert.equal((await run('resources.versions',versionArgs)).data.versions[0].versionId,'v');
assert.equal((await run('resources.status',{kind:'mod'})).data.detailOwned,true);
const originals=detail.versions;
detail.versions=Array.from({length:68},(_,i)=>({...originals[0],id:'v'+i}));
const second=await run('resources.versions',{...versionArgs,offset:50,limit:50});
assert.equal(second.data.total,68);assert.equal(second.data.versions[17].versionId,'v67');
detail.versions=originals;view.loading=false;
context='other-root';assert.equal((await run('resources.plan',{...versionArgs,versionId:'v'})).status,'rejected');
detail.session++;assert.equal((await run('resources.dismiss',{searchId})).reason,'DETAIL_CHANGED');
detail.session--;assert.equal((await run('resources.dismiss',{searchId})).data.dismissed,true);
context='root';
const fresh=await run('resources.search',{kind:'mod',query:'q',sort:'relevance',loader:'fabric',gameVersion:'1.20.1'});
const currentSearch=fresh.data.searchId;
view.nextOffset=0;view.hasMore=true;
assert.equal((await run('resources.next',{searchId:currentSearch})).reason,'SEARCH_PAGE_RESET');
view.nextOffset=1;view.hasMore=false;
assert.equal((await run('resources.versions',{...versionArgs,searchId:currentSearch})).status,'ok');
const planArgs={...versionArgs,searchId:currentSearch,versionId:'v'};
assert.equal((await run('resources.plan',{...planArgs,versionId:'not-in-list'})).status,'rejected');
const plan=await run('resources.plan',planArgs);assert.equal(plan.data.dependencies[0].selected,false);
const option=await run('resources.option',{planId:plan.data.planId,key:'opt',selected:true});
assert.equal(option.data.dependencies[0].selected,true);assert.equal((await run('resources.install',{planId:plan.data.planId})).status,'rejected');
context='other-root';assert.equal((await run('resources.install',{planId:option.data.planId})).status,'rejected');context='root';
detail.file={...file,sha1:'b'.repeat(40)};assert.equal((await run('resources.install',{planId:option.data.planId})).status,'rejected');
const final=await run('resources.plan',planArgs);const install=await run('resources.install',{planId:final.data.planId});
assert.equal(install.status,'accepted');assert.equal(submits,1);assert(!JSON.stringify(install).includes('/sensitive'));
const op=install.data.operationId;assert.equal((await run('resources.task',{operationId:op})).data.activityId,23);
owned.clear();assert.equal((await run('resources.task',{operationId:op})).status,'unknown');
ledger.set(23,{activityId:23,title:'wrong',gameVersionId:'game',outcomeSource:'task.owner',state:1,category:'mod'});
assert.equal((await run('resources.task',{operationId:op})).status,'unknown');
ledger.get(23).title='name';assert.equal((await run('resources.task',{operationId:op})).data.state,'done');
// UI retry 复用原 adapter 对象的新活动不能覆盖第一次的失败，热查和冷查均认原账本。
ledger.get(23).state=2;latest.view.startedAtMs=24;latest.view.state='done';owned.set(latest.view.id,latest);
assert.equal((await run('resources.task',{operationId:op})).data.state,'error');
owned.clear();assert.equal((await run('resources.task',{operationId:op})).data.activityId,23);
kind='modpack';assert.equal((await run('modpacks.importLocal',{url:'https://secret.invalid'})).status,'rejected');
assert.equal(imports,0);const pick=await run('modpacks.importLocal',{});const pid=pick.data.operationId;assert.equal(pick.status,'needsUser');
assert.equal((await run('modpacks.importStatus',{operationId:pid})).data.state,'waitingForPicker');
draft={archive:'/sandbox/authorized/abc',root:'/sensitive',name:'pack',valid:true};resolvePicker('selected');await Promise.resolve();
assert.equal((await run('modpacks.importStatus',{operationId:pid})).data.state,'selected');
let lp=await run('modpacks.localPlan',{operationId:pid,versionName:'my-pack'});
draft.name='user-changed';assert.equal((await run('modpacks.installLocal',{operationId:pid,planId:lp.data.planId})).status,'rejected');
lp=await run('modpacks.localPlan',{operationId:pid});const pack=(await run('modpacks.installLocal',{operationId:pid,planId:lp.data.planId})).data.operationId;
const choices=await run('modpacks.options',{operationId:pack});
assert.equal(choices.data.optional[0].name,'plugin.jar');assert(!JSON.stringify(choices).includes('server/path'));
const changed=await run('modpacks.choose',{operationId:pack,choiceId:choices.data.choiceId,key:'optional-0',selected:true});
assert.equal(changed.data.optional[0].selected,true);assert.equal((await run('modpacks.confirm',{operationId:pack,choiceId:choices.data.choiceId})).status,'rejected');
latest.optionalFiles()[0].selected=false;
assert.equal((await run('modpacks.confirm',{operationId:pack,choiceId:changed.data.choiceId})).status,'rejected');
const valid=await run('modpacks.options',{operationId:pack});
assert.equal((await run('modpacks.confirm',{operationId:pack,choiceId:valid.data.choiceId})).status,'accepted');
assert.equal(latest.view.requiresConfirmation,false);
// 整合包注册表 DONE 可以携带缺失文件，热/冷缺完整性证明均不得返回完成。
latest.view.state='done';assert.equal((await run('resources.task',{operationId:pack})).reason,'PACK_COMPLETENESS_UNPROVEN');
owned.clear();ledger.set(23,{activityId:23,title:'name',gameVersionId:'game',category:'pack',outcomeSource:'task.owner',state:1});
const unproven=await run('resources.task',{operationId:pack});assert.equal(unproven.status,'unknown');assert.equal(unproven.data.completeness,'unknown');
owned.set(latest.view.id,latest);latest.view.state='paused';
latest.view.requiresConfirmation=true;
const late=await run('modpacks.options',{operationId:pack});
let rejectResume; latest.confirmAndResume=function(_,committed){this.view.requiresConfirmation=false;committed();return new Promise((_,reject)=>{rejectResume=reject;});};
const accepted=await run('modpacks.confirm',{operationId:pack,choiceId:late.data.choiceId});
assert.equal(accepted.status,'accepted');assert.equal(accepted.data.confirmation.resumeState,'pending');
rejectResume(Error('blocked after confirmed choice'));await Promise.resolve();
const failed=(await run('resources.task',{operationId:accepted.data.confirmation.id})).data.confirmation;
assert.deepEqual([failed.choiceState,failed.resumeState],['committed','failed']);
assert.equal((await run('resources.task',{operationId:pack})).data.confirmation.id,failed.id);
latest.view.requiresConfirmation=true;
const throwing=await run('modpacks.options',{operationId:pack});latest.confirmAndResume=()=>{throw Error('product confirmation refused');};
const refused=await run('modpacks.confirm',{operationId:pack,choiceId:throwing.data.choiceId});
assert.equal(refused.status,'rejected');assert.deepEqual([refused.data.confirmation.choiceState,refused.data.confirmation.resumeState],['unknown','failed']);
async function installPack() {
  const picked=(await run('modpacks.importLocal',{})).data.operationId;
  draft={archive:'/sandbox/owned/'+picked,root:'/sensitive',name:'my-instance',valid:true};
  resolvePicker('selected');await Promise.resolve();
  const viewed=(await run('modpacks.localPlan',{operationId:picked})).data.planId;
  return (await run('modpacks.installLocal',{operationId:picked,planId:viewed})).data.operationId;
}
async function confirmChoice(operation) {
  const options=await run('modpacks.options',{operationId:operation});
  const accepted=await run('modpacks.confirm',{operationId:operation,choiceId:options.data.choiceId});
  assert.equal(accepted.status,'accepted'); return accepted.data.confirmation.id;
}
// 首次入队已兑现且仍在选择界面。覆盖人工续跑、多轮 QA 续跑和直接杀进程（无最后一次热查询）。
for (const manual of [true,false]) for (const missing of [[],[{name:'unavailable'}]]) {
  const original=await installPack(), queries=[original];
  let stage=0;
  latest.view.state='paused';
  latest.requiresPackageSelection=()=>stage===0;
  latest.packageCandidates=()=>[{id:'sub-package',title:'sub package',kind:'client'}];
  latest.packageSelected=()=>true;
  latest.confirmAndResume=async function(_,committed){
    this.view.requiresConfirmation=false; committed?.();
    if (++stage===1) {
      this.view.state='paused'; this.view.requiresConfirmation=true;
    } else {
      this.getSession=()=>({id:'pack',complete:true});this.getResult=()=>({versionName:'my-instance (2)',missing});
      this.view.title='my-instance (2)'; this.view.state='done';
    }
    registry.notify();
  };
  if (manual) {
    await latest.confirmAndResume(registry); await latest.confirmAndResume(registry);
  } else {
    queries.push(await confirmChoice(original)); queries.push(await confirmChoice(queries[1]));
  }
  await Promise.resolve();
  assert.equal(listeners.size,0);
  const trace=JSON.parse(disk.get(dir+'/resource-'+original+'.json'));
  assert.deepEqual([trace.activity,trace.category,trace.title,trace.version,trace.instance],[23,'pack','name','game','my-instance (2)']);
  owned.clear();
  for (const query of queries) {
    const cold=await run('resources.task',{operationId:query});
    assert.equal(cold.status,'ok');assert.equal(cold.data.state,'done');assert.equal(cold.data.instance,'my-instance (2)');
    assert.equal(cold.data.completeness,missing.length?'partial':'complete');assert.equal(cold.data.missingCount,missing.length);
    if (query!==original) assert.equal(cold.data.confirmation.id,query);
    owned.set(latest.view.id,latest);
    const hot=await run('resources.task',{operationId:query});
    for (const field of ['state','instance','complete','completeness','missingCount']) assert.equal(hot.data[field],cold.data[field]);
    owned.clear();
  }
}
// 已终止的活动释放监听。即使 Registry 重用同一个对象且重试成功，也读回前一代的取消/异常。
for (const [terminal,ledgerState] of [['aborted',3],['error',2]]) {
  const original=await installPack();
  latest.view.state=terminal;latest.view.requiresConfirmation=false;registry.notify();await Promise.resolve();
  assert.equal(listeners.size,0);
  ledger.get(23).state=ledgerState;
  latest.view.state='waiting';latest.view.parentActivityId=23;latest.view.activityRelation='retry';registry.notify();
  assert.equal((await run('resources.task',{operationId:original})).data.state,terminal);
  latest.view.startedAtMs=24;latest.view.state='done';
  latest.getSession=()=>({id:'retry',complete:true});latest.getResult=()=>({versionName:'retry',missing:[]});
  registry.notify();
  assert.equal((await run('resources.task',{operationId:original})).data.state,terminal);
  owned.clear();
  const cold=await run('resources.task',{operationId:original});assert.equal(cold.data.state,terminal);
  assert.equal(cold.data.completeness,'unknown');assert.equal(cold.data.instance,'');
}
active=false;assert.equal((await run('resources.search',{kind:'modpack',query:'q'})).status,'needsUser');
console.log('PASS resource search/versions, plan binding, stale source/target/file/selection, exact registry and cold ledger, picker boundary, real pack choice/confirm dispatch');

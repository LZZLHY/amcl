/**
 * DS01–DS11 的生产边界回归。只替换平台/网络及安装阶段执行，不复制队列、
 * 下载计划、恢复记录、校验选择和页面消费算法。全部文件放在仓外宿主测试夹具。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {loader,root,ts,fileIo,productionPathPolicy} from './mod-install-test-runtime.mjs';
import {workspaceTempRoot} from './lib/workspace-paths.mjs';
import {runDownloadManagerSessionRegression} from '../tests/download-system/manager-session.mjs';
import {runDownloadSourceLifecycleRegression} from '../tests/download-system/source-lifecycle.mjs';
import {runSharedOwnerReleaseRegression} from '../tests/download-system/shared-release.mjs';
import {runBusinessOwnerReleaseRegression} from '../tests/download-system/business-owner-release.mjs';
const fixture=fs.mkdtempSync(path.join(workspaceTempRoot(),'download-system-'));
const slash=p=>p.replaceAll('\\','/');
const mcRoot=slash(path.join(fixture,'mc')),filesRoot=slash(path.join(fixture,'files'));
fs.mkdirSync(mcRoot,{recursive:true});fs.mkdirSync(filesRoot,{recursive:true});
const hash=v=>crypto.createHash('sha1').update(v).digest('hex');
const turn=()=>new Promise(resolve=>setImmediate(resolve));
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const cases=[];const pass=name=>{cases.push(name);console.log('PASS: '+name);};
const log={info(){},warn(){},error(){},debug(){},flush(){}};
class ActivityLogger {constructor(id){this.value=id;}id(){return this.value;}info(){}warn(){}error(){}}
class CancelledError extends Error {constructor(){super('已取消');}static is(e){return /已取消/.test(e.message);}}
function remove(p){assert.ok(path.resolve(p).startsWith(path.resolve(fixture)+path.sep));fs.rmSync(p,{recursive:true,force:true});}
const io={...fileIo,fsyncSync(fd){if(!fs.fstatSync(fd).isDirectory())fs.fsyncSync(fd);}};
const common={AppLogger:log,ActivityLogger,CancelledError,LOG_DOMAIN_DOWNLOAD:0,LOG_DOMAIN_LAUNCH:0,
  LogTags:{SVC_DOWNLOAD_TASK:'DownloadTask',UTIL_DOWNLOADER:'McDownloader'},removeDirRecursive:remove,
  ensureDirSync:p=>fs.mkdirSync(p,{recursive:true}),isVersionInstalled:()=>false,
  writeVersionInstallCommit(){},removeVersionInstallCommit(){},
  basename:p=>path.posix.basename(p??''),formatSpeed:n=>String(n),formatError:e=>e.message,DiagnosticPolicy:{isDeveloperBuild:()=>false},
  BMCLAPI_BASE:'https://mirror.invalid',MOJANG_META:'https://meta.invalid',MOJANG_RESOURCES:'https://resources.invalid',MOJANG_LIBRARIES:'https://libraries.invalid'};
const policy={...productionPathPolicy(),isSafeHttpUrl:url=>/^https?:\/\//.test(url),isValidSha1:v=>typeof v==='string'&&/^[a-fA-F0-9]{40}$/.test(v),
  isValidJarFile:p=>{try{return fs.readFileSync(p).subarray(0,4).equals(Buffer.from('PK\x03\x04'));}catch{return false;}},
  computeFileSha1:async p=>hash(fs.readFileSync(p))};
let submitted=[];
const dm={purgeTask:()=>true,cancel:()=>true,isCaBundleInitialized:()=>true,
  async createAndWait(spec,progress){submitted.push(spec);const view={taskId:submitted.length,filesDone:spec.files.length,filesTotal:spec.files.length,
    currentFile:spec.files[0]?.localPath??'',bytesDone:1,bytesTotal:1,progress:1,speedBps:0,etaSeconds:0,failedFiles:[]};progress?.(view);return view;}};
class DormantDownloader {cancel(){}purgeNativeOwners(){return true;} getActiveTaskId(){return 0;} }
let starts=0;
let beforePhases;
class BoundaryRunner {async run(){starts++;beforePhases?.();}cancel(){}}
const extra={commons:common,'@kit.CoreFileKit':{fileIo:io},'@kit.CryptoArchitectureKit':{cryptoFramework:{}},
  '../download/McDownloader':{McDownloader:DormantDownloader},'../modloader/ModLoaderManager':{ModLoaderManager:class {}},
  './DownloadManager':{DownloadManager:{instance:()=>dm}},'../modloader/MavenUtils':policy,
  './SourceProber':{ensureRanking:async()=>({bmclapiFirst:false}),shouldUseBmclapiFirst:()=>false,buildSortedUrls:(a,b)=>[b,a],
    useOrderedMcDownload:()=>false},
  '../version/McVersionManifest':{},
  '../version/MetadataCacheStore':{getMetadataCacheStore:()=>({get:()=>null})},'../version/MetadataCache':{},'./PhaseRunner':{PhaseRunner:BoundaryRunner}};
for(const name of ['PreparePhase','ClientPhase','LibrariesPhase','AssetsPhase','ModloaderPhase','MergePhase'])extra['./phases/'+name]={[name]:class {}};
const load=loader(extra),U=load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
const Registry=load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry;
const McTask=load('feature_core/src/main/ets/version/McVersionTask.ets').McVersionTask;
const Lease=load('feature_core/src/main/ets/version/VersionInstallLease.ets');
const Sessions=load('feature_core/src/main/ets/version/McInstallSession.ets');

// 安装计划已确定的加载器在任何文件落盘前就应正确进入卡片与阶段名。
for (const [loader, label] of [['fabric','Fabric'],['forge','Forge'],['neoforge','NeoForge'],['quilt','Quilt']]) {
  const task = new McTask('26.2', loader, 'test-loader-version', '自定义显示名', mcRoot, filesRoot);
  assert.equal(task.view.activityLoaderType, loader);
  assert.equal(task.view.subtitle, label + ' test-loader-version');
  assert.equal(task.getTask().phaseDetails.find(detail => detail.phase === 'modloader').label, label + ' 安装');
}
pass('实例名称不影响四类加载器任务的副标题与安装阶段');
function adapter(id,gate){const view=new U.UnifiedTaskView();view.id=id;view.title=id;view.canCancel=true;
  return {view,async start(){await gate.promise;view.state=U.UnifiedTaskState.DONE;},async cancel(){},purgeNativeOwner:()=>true,dispose(){}};}

// DS03：完整 Registry→McVersionTask→DownloadTask 路线；最后的下载阶段为受控执行边界。
let reg=new Registry();Registry._instance=reg;reg.maxConcurrent=1;let gate=deferred();
let blocked=reg.enqueue(adapter('blocker',gate));
const queued=new McTask('1.20.1',null,'','queued',mcRoot,filesRoot);
const waiting=reg.enqueue(queued).catch(e=>e);await reg.cancel(queued.view.id,false);await waiting;
assert.equal(queued.getTask().phase,'aborted');
const parentActivity=queued.view.startedAtMs;
const queuedRetry=reg.retry(queued.view.id);
assert.equal(queued.view.state,U.UnifiedTaskState.WAITING);
assert.equal(queued.view.startedAtMs,parentActivity);
let cancelledOwner, cancelledActivity;
await reg.cancel(queued.view.id,false,owner=>{cancelledOwner=owner;cancelledActivity=owner.view.startedAtMs;});
await queuedRetry;
assert.equal(cancelledOwner,queued);assert.ok(cancelledActivity>parentActivity);assert.equal(cancelledActivity,queued.view.startedAtMs);
gate.resolve();await blocked;await turn();
await reg.retry(queued.view.id);await turn();
assert.equal(starts,1);assert.equal(queued.view.state,U.UnifiedTaskState.DONE);assert.equal(reg.runningIds_.length,0);
pass('排队取消后重试真正执行并完成，无准备中空任务');

// 原生回调只代表当前阶段。复现 assets 的 0 秒 ETA 被 Fabric 任务沿用的真机场景。
const fabricProgress=new McTask('26.3','fabric','0.20.1','fabric-progress',mcRoot,filesRoot);
const activeDownload=fabricProgress.getTask();
activeDownload.handlePhaseProgress({phase:'assets',progress:1,speedBps:226202,message:'游戏资源完成',
  bytesDone:485135675,bytesTotal:485135675,etaSeconds:0});
assert.equal(fabricProgress.view.bytesTotal,485135675);
assert.equal(fabricProgress.view.etaSeconds,0);
activeDownload.handlePhaseProgress({phase:'modloader',progress:0.33,speedBps:0,message:'Fabric 依赖下载',
  current:1,total:3});
assert.equal(activeDownload.phaseDetails.find(detail=>detail.phase==='assets').status,'done');
assert.equal(activeDownload.speed,'');
assert.equal(fabricProgress.view.bytesDone,0);
assert.equal(fabricProgress.view.bytesTotal,0);
assert.equal(fabricProgress.view.etaSeconds,-1);
activeDownload.handlePhaseProgress({phase:'assets',progress:1,speedBps:1,message:'迟到的资源进度',
  bytesDone:485135675,bytesTotal:485135675,etaSeconds:0});
assert.equal(activeDownload.phase,'modloader');
assert.equal(fabricProgress.view.bytesTotal,0);
assert.equal(fabricProgress.view.etaSeconds,-1);
pass('切换到加载器时清除旧阶段统计，迟到事件不会恢复虚假的 0 秒 ETA');

// DS08：另一 owner 的用户文件与 pending，即使收到清理请求也必须保留。
reg=new Registry();Registry._instance=reg;reg.maxConcurrent=1;gate=deferred();blocked=reg.enqueue(adapter('blocker',gate));
const foreignDir=mcRoot+'/versions/foreign';fs.mkdirSync(foreignDir+'/saves',{recursive:true});fs.writeFileSync(foreignDir+'/saves/user.dat','keep');
const release=Lease.claimVersionInstall(mcRoot,'foreign','another');
const foreign=new McTask('1.20.1',null,'','foreign',mcRoot,filesRoot);const foreignWaiting=reg.enqueue(foreign).catch(e=>e);
await reg.cancel(foreign.view.id,true);await foreignWaiting;await turn();
assert.equal(fs.readFileSync(foreignDir+'/saves/user.dat','utf8'),'keep');release();gate.resolve();await blocked;await turn();
pass('未取得目录归属的清理取消保留外来实例');

// DS07：两个等同一 stale owner 的请求，只允许第一项取得准入。
reg=new Registry();Registry._instance=reg;reg.maxConcurrent=3;let released=false;
const old=adapter('same',deferred());old.view.state=U.UnifiedTaskState.ERROR;old.purgeNativeOwner=()=>released;
reg.adapters_.set('same',old);reg.orderedIds_.push('same');const ga=deferred(),gb=deferred();
const a=adapter('same',ga),b=adapter('same',gb);let invoked=0;for(const ad of [a,b]){const start=ad.start;ad.start=async()=>{invoked++;return start();};}
const pa=reg.enqueue(a),pb=reg.enqueue(b);const denied=assert.rejects(pb,/等待|占用|进行中/);released=true;
await new Promise(r=>setTimeout(r,360));await denied;assert.equal(invoked,1);assert.equal(reg.listAll().length,1);assert.equal(reg.getAdapter('same'),a);
ga.resolve();await pa;await turn();pass('异步释放窗口的重复准入不覆盖新 owner');

/** 页面只提取原方法体；不复制或改写被审查的类型与活动分支。 */
function methodClass(relative,names,bindings={}){const source=fs.readFileSync(path.join(root,relative),'utf8');
  const body=names.map(name=>{const found=new RegExp('^  (?:private |public )?(?:static )?(?:async )?'+name+'\\(','m').exec(source);assert.ok(found,name);
    const ast=ts.createSourceFile('slice.ts','class Subject {\n'+source.slice(found.index),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
    return ast.statements.find(ts.isClassDeclaration).members[0].getText(ast);}).join('\n');
  const exports={};vm.runInNewContext(ts.transpileModule('class Subject {\n'+body+'\n}\nexports.Subject=Subject;',
    {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports,console,...bindings});return exports.Subject;}
const Repair=load('feature_core/src/main/ets/version/RepairTask.ets').RepairTask;
const repair=new Repair('existing',mcRoot);repair.view.state=U.UnifiedTaskState.DONE;
const Detail=methodClass('entry/src/main/ets/components/TaskDetailView.ets',['mcAdapter_','mcPhaseList_'],{McVersionTask:McTask});
const detail=new Detail();Object.assign(detail,{view:repair.view,registry_:{getAdapter:()=>repair}});assert.equal(detail.mcPhaseList_().length,0);
const Index=methodClass('entry/src/main/ets/pages/Index.ets',['syncStatusFromRegistry_'],{...U,McVersionTask:McTask,RepairTask:Repair,ForgeRepairTask:class {},
  ActivityCategory:{JDK:'jdk',MODPACK:'modpack',REPAIR:'repair'},ActivityStatus:{SUCCESS:'success',FAILED:'failed',ABORTED:'aborted'}});
const index=new Index();Object.assign(index,{registry:{listAll:()=>[repair.view],getAdapter:()=>repair},registryTerminalProjection_:new Map(),scanVersions(){}});
assert.doesNotThrow(()=>index.syncStatusFromRegistry_());pass('修复 adapter 不进入普通 MC 专属详情或历史接口');
let repairs=0;Object.assign(index,{scanVersions(){repairs++;}});
index.registryTerminalProjection_.clear();repair.view.startedAtMs=101;index.syncStatusFromRegistry_();index.syncStatusFromRegistry_();
repair.view.startedAtMs=102;index.syncStatusFromRegistry_();assert.equal(repairs,2);
// 导出准备终态不是Minecraft安装成功，不能触发版本扫描或追加游戏下载历史。
const exportPrepare=new U.UnifiedTaskView();exportPrepare.id='export-prepare:owner';exportPrepare.category=U.TaskCategory.GAME_EXPORT;
exportPrepare.state=U.UnifiedTaskState.DONE;exportPrepare.startedAtMs=103;
const originalList=index.registry.listAll;index.registry.listAll=()=>[exportPrepare];
index.scanVersions=()=>{throw new Error('导出准备不得扫描安装结果');};
index.syncStatusFromRegistry_();assert.equal(repairs,2);index.registry.listAll=originalList;
pass('导出准备DONE不冒充游戏下载历史或版本安装');
// 执行统一面板真实恢复方法：导出只携固定源/任务身份，不能从旧卡片重用Picker目标URI。
let recoveryRoute,closed=0,store=false,restore=true,routeStatus='ok',taskOwner;
const appView=new U.UnifiedTaskView();
Object.assign(appView,{id:'app-update:'+'a'.repeat(64),category:U.TaskCategory.APP_UPDATE,parentActivityId:207,startedAtMs:208,canRecoverExternally:true});
const sourceExport={id:'103-export-owner',request:{mcRoot:'/mc',versionId:'source-ver'}};
const exchange={...U,isQueuedRetry:load('entry/src/main/ets/launcherskill/LibraryResult.ets').isQueuedRetry,DistributionPolicy:{isStore:()=>store},getDownloadTaskRegistry:()=>({getAdapter:id=>taskOwner?.view.id===id?taskOwner:null}),
  getGameExportCoordinator:()=>({restoreTask:async()=>restore,getTask:()=>sourceExport})};
const TaskSheet=methodClass('entry/src/main/ets/components/DownloadTasksSheet.ets',['recoverTask_'],exchange);
const sheet=new TaskSheet();const nav={
  async pushUrl(value){if(routeStatus==='reject') throw Error('navigation rejected');recoveryRoute=value;},
  getState(){return {name:routeStatus==='changed'?'Index':recoveryRoute.url};},
  getParams(){return routeStatus==='wrongSource'?{}:recoveryRoute.params;}
};
Object.assign(sheet,{skillAlive_:true,registry_:exchange.getDownloadTaskRegistry(),onClose(){closed++;},getUIContext:()=>({getRouter:()=>nav})});
Object.assign(exportPrepare,{id:'export-prepare:'+sourceExport.id,exportTaskId:sourceExport.id,exportMcRoot:'/mc',exportVersionId:'source-ver',exportVersionIsolation:false,canRecoverExternally:true});
taskOwner={view:exportPrepare};
exportPrepare.exportMcRoot='';assert.equal((await sheet.recoverTask_(exportPrepare)).reason,'missingExportIdentity');assert.equal(closed,0);
exportPrepare.exportMcRoot='/mc';restore=false;assert.equal((await sheet.recoverTask_(exportPrepare)).reason,'originalExportUnavailable');assert.equal(closed,0);
restore=true;assert.equal((await sheet.recoverTask_(exportPrepare)).destinationReached,true);assert.equal(closed,1);assert.equal(recoveryRoute.url,'pages/GameExportPage');
assert.deepEqual(Object.keys(recoveryRoute.params).sort(),['mcRoot','taskId','versionId','versionIsolation']);
assert.equal(recoveryRoute.params.taskId,sourceExport.id);assert.equal(recoveryRoute.params.mcRoot,'/mc');
routeStatus='reject';assert.equal((await sheet.recoverTask_(exportPrepare)).state,'unknown');
taskOwner={view:appView};assert.equal((await sheet.recoverTask_(exportPrepare)).reason,'taskChanged');
assert.equal((await sheet.recoverTask_(appView)).state,'unknown');
routeStatus='changed';assert.equal((await sheet.recoverTask_(appView)).state,'unknown');
routeStatus='wrongSource';assert.equal((await sheet.recoverTask_(appView)).state,'unknown');
routeStatus='ok';assert.equal((await sheet.recoverTask_(appView)).destinationReached,true);assert.equal(recoveryRoute.url,'pages/SoftwareUpdatePage');
const RecoveryPage=methodClass('entry/src/main/ets/pages/SoftwareUpdatePage.ets',['bindRecoverySource_'],exchange);
const recoveryPage=new RecoveryPage();recoveryPage.bindRecoverySource_({...recoveryRoute.params,recoveryActivityId:999});
assert.equal(recoveryPage.checkRecoveryOnShow_,undefined);
recoveryPage.bindRecoverySource_(recoveryRoute.params);
assert.equal(recoveryPage.recoveryTaskId_,appView.id);assert.equal(recoveryPage.recoveryParent_,207);assert.equal(recoveryPage.checkRecoveryOnShow_,true);
store=true;assert.equal((await sheet.recoverTask_(appView)).state,'failed');store=false;
pass('导出恢复和更新重查仅认原对象、活动与实际到达的目标页，残缺/拒绝/换代不签收');
// 标题抽取同时带上真实模组另存判据；只注入活动类别常量，仍执行生产分支。
const ExportHero=methodClass('entry/src/main/ets/components/TaskDetailView.ets',
  ['heroTitleText_','isHeroError_','isModFileSave_','exportPreparedCount_'],{...U,ActivityCategory:{RESOURCE_MANAGE:'resource_manage'}});
const exportHero=new ExportHero();assert.match(exportHero.heroTitleText_(exportPrepare),/电脑文件准备完成/);
assert(!exportHero.heroTitleText_(exportPrepare).includes('安装完成'));
Object.assign(exportPrepare,{filesDone:3,filesTotal:0});exportHero.view=exportPrepare;
assert.equal(exportHero.exportPreparedCount_(),'已校验 3 项');exportPrepare.filesDone=4;
assert.equal(exportHero.exportPreparedCount_(),'已校验 4 项');
const modFileSave=new U.UnifiedTaskView();Object.assign(modFileSave,{category:U.TaskCategory.MOD,
  activityCategory:'resource_manage',state:U.UnifiedTaskState.DONE,currentLabel:'文件已保存并核对'});
assert.equal(exportHero.heroTitleText_(modFileSave),'文件已保存并核对');
pass('统一任务详情只声明电脑文件准备完成，不声明安装或整包保存成功');
// Forge 修复显式委托同一 owner，生产 DownloadTask 不得将现有用户目录当作新安装残留。
const FullRepair=methodClass('feature_core/src/main/ets/version/ForgeRepairTask.ets',['runFullReinstall_'],
  {DownloadTask:load('feature_core/src/main/ets/download/DownloadTask.ets').DownloadTask,ModLoaderType:{FORGE:'forge'}});
const full=new FullRepair();Object.assign(full,{gameVersion_:'1.20.1',loaderVersion_:'47',versionName_:'repair-owned',
  mcDir_:mcRoot,filesDir_:filesRoot,repairOwner_:'repair-owner',view:new U.UnifiedTaskView(),notify_(){}});
fs.mkdirSync(mcRoot+'/versions/repair-owned',{recursive:true});fs.writeFileSync(mcRoot+'/versions/repair-owned/user.cfg','USER');
const repairRelease=Lease.claimVersionInstall(mcRoot,'repair-owned','repair-owner');
await full.runFullReinstall_();repairRelease();assert.equal(fs.readFileSync(mcRoot+'/versions/repair-owned/user.cfg','utf8'),'USER');
pass('修复每次重试单独结账，Forge 子流水线继承租约并保留用户目录');

// DS05/06：真实计划函数提交损坏库；索引必须核验正文，坏缓存可重新获取。
const Mc=load('feature_core/src/main/ets/download/McDownloader.ets').McDownloader;
const libRoot=slash(path.join(fixture,'libs'));fs.mkdirSync(libRoot+'/libraries/sample',{recursive:true});
const correct=Buffer.from('PK\x03\x04right'),wrong=Buffer.from('PK\x03\x04wrong');fs.writeFileSync(libRoot+'/libraries/sample/library.jar',wrong);
const version={id:'repair',libraries:[{name:'sample:library:1',downloads:{artifact:{path:'sample/library.jar',url:'https://example.invalid/lib',sha1:hash(correct),size:correct.length}}}]};
submitted=[];await new Mc(libRoot).downloadLibraries(version,true);assert.equal(submitted[0].files.length,1);assert.equal(submitted[0].shareFiles,true);
assert.equal(hash(fs.readFileSync(libRoot+'/libraries/sample/library.jar')),hash(wrong));pass('修复把损坏官方库送入真实校验计划，不提前删除旧文件');
const assetRoot=slash(path.join(fixture,'assets'));fs.mkdirSync(assetRoot+'/assets/indexes',{recursive:true});
const oldHash=hash('old!'),newHash=hash('new!');
const oldIndex=JSON.stringify({objects:{sound:{hash:oldHash,size:4}}}),newIndex=JSON.stringify({objects:{sound:{hash:newHash,size:4}}});
const indexFile=assetRoot+'/assets/indexes/shared.json';fs.writeFileSync(indexFile,oldIndex);
const assets=new Mc(assetRoot);let fetched=0;assets.httpGet=async()=>{fetched++;return newIndex;};submitted=[];
const assetVersion={id:'new',libraries:[],assetIndex:{id:'shared',url:'https://example.invalid/index',sha1:hash(newIndex),size:Buffer.byteLength(newIndex)}};
await assets.downloadAssets(assetVersion);assert.equal(fetched,1);assert.equal(submitted[0].files[0].check.sha1,newHash);
fs.writeFileSync(indexFile,'!'.repeat(newIndex.length));await assets.downloadAssets(assetVersion);await assets.downloadAssets(assetVersion);
assert.equal(fetched,2);assert.equal(fs.readFileSync(indexFile,'utf8'),newIndex);
assets.httpGet=async()=>oldIndex;fs.writeFileSync(indexFile,'!'.repeat(newIndex.length));await assert.rejects(assets.downloadAssets(assetVersion),/校验失败/);
assert.equal(fs.readFileSync(indexFile,'utf8'),'!'.repeat(newIndex.length));pass('错误哈希/坏 JSON 重取，正确缓存复用，所有坏源不激活');

// DS11：持久意图让重建对象复用 client 暂存，不同意图仍保持隔离；旧根不能恢复。
const coldA=new McTask('1.20.1',null,'','resume',mcRoot,filesRoot);
Sessions.saveMcInstallSession(filesRoot,coldA.getTask().installSession_);
const coldB=new McTask('1.20.1',null,'','resume',mcRoot,filesRoot);
const other=new McTask('1.20.2',null,'','another',mcRoot,filesRoot);
assert.equal(coldA.getTask().tempDir,coldB.getTask().tempDir);assert.notEqual(coldA.getTask().tempDir,other.getTask().tempDir);
assert.equal(Sessions.listMcInstallRecovery(filesRoot,mcRoot+'/other').length,0);
// 模拟 mkdir 后、owner marker 之前退出：只有空目录可以继续，旧 client 暂存必须保留到阶段执行。
fs.mkdirSync(mcRoot+'/versions/resume');fs.mkdirSync(coldA.getTask().tempDir,{recursive:true});
fs.writeFileSync(coldA.getTask().tempDir+'/client.amcl.part','partial');
beforePhases=()=>assert.equal(fs.readFileSync(coldB.getTask().tempDir+'/client.amcl.part','utf8'),'partial');
await coldB.start();beforePhases=undefined;assert.equal(coldB.view.state,U.UnifiedTaskState.DONE);
pass('冷启动重建复用持久暂存身份，其他版本与根隔离');

// DS10：失败必须 reject 且保留原因；重试使用新活动，页面只更新JDK展示，不重复开结账。
let ok=false;const activities=[];const inst={setDownloadCallback(cb){this.cb=cb;},requestCancel(){},isDownloading:()=>false,
  purgeNativeOwners:()=>true,getFailureReason:()=> '磁盘已满',async downloadAndInstall(){activities.push(this.activityId);return ok;}};
const Jdk=loader({commons:common,feature_core:{...U,DownloadTaskRegistry:{instance:()=>({notifyChange(){}})}},'./JdkManager':{},'./JdkInstaller':{}})('launch/src/main/ets/JdkInstallTask.ets').JdkInstallTask;
const jdk=new Jdk('21',{createInstaller:()=>inst},111);await assert.rejects(jdk.start(),/磁盘已满/);assert.equal(jdk.view.errorMessage,'磁盘已满');
jdk.view.startedAtMs=222;ok=true;await jdk.retry();assert.deepEqual(activities,[111,222]);
let begun=0,ended=0,refreshes=0;Object.assign(index,{registry:{listAll:()=>[jdk.view],getAdapter:()=>jdk},beginActivity_(){begun++;},addActivity_(){ended++;},updateJdkReadyState(){refreshes++;}});
index.syncStatusFromRegistry_();index.syncStatusFromRegistry_();assert.equal(begun,0);assert.equal(ended,0);assert.equal(refreshes,1);
pass('JDK 失败原因与新尝试活动身份完整传递');

// DS01：实际协调器加实际 DownloadManager 入口，Native 传输为可控批次边界。
const transportLoad=loader({commons:common,'@kit.AbilityKit':{}});
const DM=transportLoad('feature_core/src/main/ets/download/DownloadManager.ets');
const Shared=transportLoad('feature_core/src/main/ets/download/SharedDownloadCoordinator.ets').SharedDownloadCoordinator;

/**
 * 原生合同按属性存在性检查可选字段。检查生产快照的原始对象，不能经过 JSON 序列化，
 * 否则 undefined 会被抹去，重复漏掉真机已经发生的 maxConnections/摘要/大小错误。
 */
const optionalSpec={localPath:'/trusted/spec.jar',allowedRoot:'/trusted',urls:['https://example.invalid/spec.jar']};
for(const check of [undefined,{}, {sha1:'a'.repeat(40)}, {size:0}, {sha1:undefined,size:undefined}]){
  const input={...optionalSpec,maxConnections:undefined,check};
  const copy=DM.copyDownloadFileSpec(input);
  assert.equal(Object.hasOwn(copy,'maxConnections'),false);
  assert.equal(Object.hasOwn(copy,'check'),check!==undefined);
  if(check!==undefined){assert.equal(Object.hasOwn(copy.check,'sha1'),check.sha1!==undefined);
    assert.equal(Object.hasOwn(copy.check,'size'),check.size!==undefined);}
  assert.notEqual(copy.urls,input.urls);
}
for(const value of [1,16,0,17,NaN]){
  const copy=DM.copyDownloadFileSpec({...optionalSpec,maxConnections:value});
  assert.equal(Object.hasOwn(copy,'maxConnections'),true);assert.ok(Object.is(copy.maxConnections,value));
}
// 提供的非法值必须留给 Native 拒绝，合法缺省才省略；不把 false/0 当“没提供”。
let capturedSpec;
const strictCoordinator=new Shared({async run(spec){capturedSpec=spec;
  for(const file of spec.files){assert.equal(Object.hasOwn(file,'maxConnections'),false);
    if(file.check){for(const key of ['sha1','size'])if(Object.hasOwn(file.check,key))assert.notEqual(file.check[key],undefined);}}
  const view=new DM.DownloadTaskView();view.taskId=777;view.success=true;view.finished=true;
  view.filesTotal=view.filesDone=spec.files.length;return view;},cancel:()=>true,purge:()=>true});
await strictCoordinator.run({name:'optional-fields',activityId:0,files:[{...optionalSpec,check:{sha1:undefined,size:4}}]});
assert.equal(capturedSpec.files[0].check.size,4);assert.equal(Object.hasOwn(capturedSpec.files[0].check,'sha1'),false);
// 实际 DownloadManager 的 create/register/start 事务也调用同一复制规则；边界后立即
// 注入可识别错误，证明规格真正抵达 createTask，同时不启动任何模拟传输/定时进度。
let nativeBoundarySpec;
DM.setDownloadNativeEngine({createTask(spec){nativeBoundarySpec=spec;throw new Error('captured native boundary');}});
const boundaryManager=new DM.DownloadManager();boundaryManager.caBundleInitialized_=true;
await assert.rejects(boundaryManager.createAndWait({name:'plain-archive',files:[{
  ...optionalSpec,maxConnections:undefined,check:{sha1:undefined,size:0},
}]}),/captured native boundary/);
assert.equal(Object.hasOwn(nativeBoundarySpec.files[0],'maxConnections'),false);
assert.equal(Object.hasOwn(nativeBoundarySpec.files[0].check,'sha1'),false);
assert.equal(nativeBoundarySpec.files[0].check.size,0);DM.setDownloadNativeEngine(null);
pass('shared/native file snapshots preserve omitted optional properties and retain explicitly invalid values');
const jobs=[];let cancellations=0;
const backend={run(spec,progress){const gate=deferred(),view=new DM.DownloadTaskView();view.taskId=jobs.length+1;view.filesTotal=spec.files.length;
  for(const file of spec.files)assert.equal(Object.hasOwn(file,'maxConnections'),false,'普通库不应产生显式undefined连接参数');
  const job={spec,view,gate,progress};jobs.push(job);progress(view);return gate.promise;},
  cancel(id){cancellations++;const job=jobs[id-1];job.view.aborted=true;job.gate.reject(new Error('已取消'));return true;},purge:()=>true};
const manager=new DM.DownloadManager();manager.shared_=new Shared(backend);
const sharedFile=name=>({localPath:'/trusted/'+name,allowedRoot:'/trusted',urls:['https://example.invalid/'+name],check:{sha1:'a'.repeat(40),size:4}});
let va,vb;const first=manager.createAndWait({name:'a',shareFiles:true,files:[sharedFile('same'),sharedFile('own')]},v=>{va=v;});
const firstResult=first.catch(e=>e);const second=manager.createAndWait({name:'b',shareFiles:true,files:[sharedFile('same')]},v=>{vb=v;});
assert.equal(jobs.length,1);assert.notEqual(va.taskId,vb.taskId);
await assert.rejects(manager.createAndWait({name:'authorized-shared',shareFiles:true,files:[{
  ...sharedFile('authorized'),bearerToken:'fixture-only',authorizedPolicy:{singleUse:true,maxHttpAttempts:1,
    validForNewRequestMs:1000,maxBytes:4}}]}),/受限授权/);
await assert.rejects(manager.createAndWait({name:'different-hard-limit',shareFiles:true,
  files:[{...sharedFile('same'),maxConnections:1}]}),/不兼容/);
assert.equal(jobs.length,1,'拒绝权限/硬约束冲突前不能登记新批次');
jobs[0].view.speedBps=100;jobs[0].view.currentFile='own';jobs[0].view.currentFiles=['own'];jobs[0].progress(jobs[0].view);
assert.equal(vb.progressEstimated,true);assert.equal(vb.physicalSpeedBps,100);assert.equal(vb.speedBps,50);
assert.equal(vb.currentFile,'','子集不能借用其他消费者的当前文件名');
await assert.rejects(manager.createAndWait({name:'conflict',shareFiles:true,files:[{...sharedFile('same'),check:{sha1:'b'.repeat(40),size:4}}]}),/不兼容/);
manager.cancel(va.taskId);await firstResult;assert.equal(cancellations,0);assert.equal(manager.purgeTask(va.taskId),true);
jobs[0].view.success=true;jobs[0].view.filesDone=2;jobs[0].view.finished=true;jobs[0].gate.resolve(jobs[0].view);
await second;assert.equal(vb.success,true);assert.equal(vb.filesTotal,1);assert.equal(manager.purgeTask(vb.taskId),true);
pass('同内容批次复用、身份冲突拒绝、单订阅取消不影响其他消费者');
let vc;const last=manager.createAndWait({name:'last',shareFiles:true,files:[sharedFile('last')]},v=>{vc=v;});
const lastResult=assert.rejects(last,/已取消/);manager.cancel(vc.taskId);await lastResult;assert.equal(cancellations,1);assert.equal(manager.purgeTask(vc.taskId),true);
pass('最后订阅者取消实际 Native 批次并收敛');
const failed=manager.createAndWait({name:'mixed',shareFiles:true,files:[sharedFile('good'),sharedFile('bad')]});
const failedResult=assert.rejects(failed,/bad/);const good=manager.createAndWait({name:'only-good',shareFiles:true,files:[sharedFile('good')]});
// 与 LoaderDownload::settleFile_ 的实际契约一致：filesDone 包含成功和失败两个终结文件。
const mixed=jobs[2];mixed.view.finished=true;mixed.view.filesDone=2;mixed.view.failedFiles=[{localPath:'/trusted/bad',basename:'bad',triedUrls:[],lastError:{message:'bad'}}];
mixed.gate.reject(new Error('bad'));await failedResult;assert.equal((await good).success,true);
pass('共享批次中其他文件失败不污染成功文件的消费者');
// Maven 只 await 结果，没有 adapter 主动清理。终态下一事件轮回收，错误的同步
// Promise 消费仍能读到快照；取消其他订阅者的隔离行为已在上面沿相同实现验证。
let transientId;const transient=manager.createAndWait({name:'detail-before-release',shareFiles:true,files:[sharedFile('detail')]},v=>{transientId=v.taskId;});
const detailResult=transient.catch(()=>assert.ok(manager.getTask(transientId)?.finished));
jobs[3].view.finished=true;jobs[3].view.errorMessage='detail';jobs[3].gate.reject(new Error('detail'));await detailResult;
let nextNative=100;
const unattended=new Shared({async run(spec,progress){const view=new DM.DownloadTaskView();view.taskId=nextNative++;view.success=true;view.finished=true;
  view.filesTotal=view.filesDone=spec.files.length;progress(view);return view;},cancel:()=>true,purge:()=>true});
for(let i=0;i<100;i++)await unattended.run({name:'maven:'+i,files:[sharedFile('maven-'+i)]});
await new Promise(resolve=>setTimeout(resolve,10));
assert.equal(unattended.requests_.size,0);assert.equal(manager.getTask(transientId),null);
pass('仅消费 Promise 的调用方自动释放终态记录，当前错误详情链保持可读');
for(const name of await runDownloadManagerSessionRegression())pass('Manager session: '+name);
for(const name of await runDownloadSourceLifecycleRegression())pass('Source lifecycle: '+name);
for(const name of await runSharedOwnerReleaseRegression(DM))pass('Shared release: '+name);
for(const name of await runBusinessOwnerReleaseRegression())pass('Business owner: '+name);
// normal/CI 既有下载门禁串行执行进程生存期专项；两个专项各自装配独立的真实生产模块
// 与 Native/平台边缘，不复用本文件的 Manager/Registry 单例。任何导入/断言失败都会
// 阻断本入口；各自输出 14/11 组结果，原 DS 核心 cases 的 52 组口径保持不变。
await import('./test-process-activity-coordinator.mjs');
await import('./test-download-process-lifetime.mjs');
fs.writeFileSync(path.join(fixture,'results.json'),JSON.stringify({checkedAt:new Date().toISOString(),cases},null,2));
console.log('Download system regression passed: '+cases.length+' groups; evidence '+fixture);

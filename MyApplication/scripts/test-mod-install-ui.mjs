import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {loader,root,ts} from './mod-install-test-runtime.mjs';
const load=loader({'./ModSourceRouter':{}}),T=load('mods/src/main/ets/ModTypes.ets'),R=load('mods/src/main/ets/ModDependencyResolver.ets');
const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/ModBrowsePage.ets'),'utf8');
function method(name){const match=new RegExp('^  private (?:async )?'+name+'\\(','m').exec(source);assert.ok(match,name);
  const parsed=ts.createSourceFile('page.ts','class Page {\n'+source.slice(match.index),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
  const node=parsed.statements.find(ts.isClassDeclaration).members[0];assert.equal(node.name.getText(parsed),name);return node.getText(parsed);}
const primary={url:'https://example.invalid/root.jar',mirrors:[],filename:'root.jar',size:2,isPrimary:true};
const version={id:'root-v',projectId:'root',source:'modrinth',versionNumber:'1.0',gameVersions:['1.21.11'],loaders:['fabric'],files:[primary],dependencies:[]};
const project={id:'root',source:'modrinth',kind:'mod',title:'root'};
let releaseResolve,enteredResolve,releaseInstall;
const startedResolve=new Promise(r=>enteredResolve=r),pendingResolve=new Promise(r=>releaseResolve=r),pendingInstall=new Promise(r=>releaseInstall=r);
const submitted=[];
/** 执行真实页面收尾方法，仅隔离registry/存储端口以注入忙态与IO错误。 */
const io={beginError:false,endError:false,receiptError:false,rows:new Map(),receipts:new Map(),history:[],endCalls:0};
const historyStore={async waitReady(){},listStored:()=>io.history,async add(record){io.history.push({...record});}};
class Task {constructor(request){this.request=request;this.view={filesDone:2,bytesDone:2};}}
const registry={enqueue:async task=>{submitted.push(task);await pendingInstall;}};
const exported={};
// 安装准备现在由真实loadChosenDetail内部扫描；连同其生产投影/准入方法一起抽取，
// 不能用测试替身预先宣告ready，否则会绕过本次新增的安装计划门控。
const js=ts.transpileModule('class Page {\n'+['buildDeclaredDepRows','buildDepRows','detailInstallIssue','loadChosenDetail','confirmInstallFromSheet','invalidateLocalScanCache','executeInstall','recordHistory'].map(method).join('\n')+'\n}\nexports.Page=Page;',
  {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
vm.runInNewContext(js,{exports:exported,...T,...R,ModInstallTask:Task,ResourceInstallTask:Task,
  getDownloadTaskRegistry:()=>registry,resolveInstalledLoader:()=> 'fabric',resolveInstalledMcVersion:()=> '1.21.11',
  ActivityCategory:{MOD_INSTALL:'mod_install'},LedgerState:{SUCCESS:1,FAILED:2},DiagnosticPolicy:{isDeveloperBuild:()=>false},
  AppLogger:{warn(){}},LOG_DOMAIN_DOWNLOAD:1,TAG:'ModBrowsePage',getDownloadHistoryStore:()=>historyStore,
  ledgerBeginAsync:async(_dir,id,meta)=>{if(io.beginError)throw Error('清理忙态fixture');io.rows.set(id,{...meta,activityId:id,runNonce:'nonce-'+id,state:0});return true;},
  ledgerManifestAsync:async(_dir,id)=>io.rows.get(id)||null,ledgerDirOf:(dir,id)=>dir+'/logs/ledger/'+id,
  writeEvidenceTextAtomicAsync:async(file,text)=>{if(io.receiptError)throw Error('原件IO故障fixture');io.receipts.set(file,text);},
  ledgerEndAsync:async(_dir,id,outcome)=>{io.endCalls++;if(io.endError)throw Error('关闭IO故障fixture');io.rows.set(id,{...io.rows.get(id),...outcome});},
  makeResolverFromRouter:()=>({resolve:async()=>{enteredResolve();await pendingResolve;return {dependencies:[],conflicts:[],depthExceeded:false};}})});
const page=new exported.Page();Object.assign(page,{router_:{repoFor:()=>({})},detailProject_:project,detailFetchEpoch_:1,detailLoading_:true,detailError_:'',detailOptionalIds_:[],
  detailPreparingInstall_:false,detailInstallReady_:false,detailInstallError_:'',detailDependenciesResolved_:false,detailPreparedMcDir_:'',detailPreparedVersionId_:'',
  targetMcDir_:'/original',targetVersionId_:'target-original',versionIsolation:true,detailSelectedVersion_:version,detailPrimaryFile_:null,detailInstalledPrimary_:null,
  detailResolvedDeps_:[],downloadingProjectIds_:new Set(),localScanCache_:new Map(),localScanCacheEpoch_:0,messages:[],history:[],
  toast(text){this.messages.push(text);},onStatusMessage(){},getOrScanInstalled:async()=>[],hasValidCurrentVersion:()=>true,uiCtx:()=>undefined,kindLabelOf:()=> '模组',recordHistory(...args){this.history.push(args);}});
const loading=page.loadChosenDetail(version,1);await startedResolve;
// 目录和选中文件已可读，但依赖计划未完成，真实提交入口仍必须拒绝。
assert.equal(page.detailLoading_,false);assert.equal(page.detailPreparingInstall_,true);assert.equal(page.detailPrimaryFile_,primary);
page.confirmInstallFromSheet();assert.equal(submitted.length,0,'Install preparation must block click at the submit boundary');
releaseResolve();await loading;assert.equal(page.detailPreparingInstall_,false);assert.equal(page.detailInstallReady_,true);assert.equal(page.detailPrimaryFile_,primary);
// 安装完成必须退休所有旧扫描，既清现有缓存，也使尚未结束的旧IO失去回填资格。
page.localScanCache_.set('/original::target-original::1',[]);const scanEpoch=page.localScanCacheEpoch_;
const install=page.executeInstall(project,version,primary,[]);assert.equal(submitted.length,1);
page.targetMcDir_='/changed';page.targetVersionId_='changed';page.versionIsolation=false;releaseInstall();await install;
assert.equal(page.localScanCacheEpoch_,scanEpoch+1);assert.equal(page.localScanCache_.size,0,'安装结束应清除已装文件快照');
assert.equal(submitted[0].request.mcDir,'/original');assert.equal(submitted[0].request.versionId,'target-original');assert.equal(submitted[0].request.versionIsolation,true);
assert.equal(page.history[0][7],'1.21.11','History uses the original game snapshot');
// 后续各单点反例必须恢复与已准备计划一致的目标；否则“目标变化”会掩盖被测守卫缺失。
page.targetMcDir_='/original';page.targetVersionId_='target-original';page.versionIsolation=true;
assert.equal(page.detailPreparedMcDir_,page.targetMcDir_);assert.equal(page.detailPreparedVersionId_,page.targetVersionId_);
assert.equal(page.downloadingProjectIds_.size,0);assert.equal(page.detailInstallReady_,true);
page.detailError_='required missing';page.confirmInstallFromSheet();assert.equal(submitted.length,1,'Unresolved required dependency must block UI submission');
assert.equal(page.messages.at(-1),'required missing','目录错误必须由对应守卫拒绝');
// 安装错误单独门控，不能依赖目录错误偶然拦住尚未完成的计划。
page.detailError_='';page.detailInstallError_='required missing';page.confirmInstallFromSheet();assert.equal(submitted.length,1,'Unresolved install dependency must block UI submission');
assert.equal(page.messages.at(-1),'required missing','安装错误不能借目标变化或其它阻断偶然通过');
page.detailInstallError_='';
page.detailError_='';page.detailSelectedVersion_={...version,loaders:['forge'],gameVersions:['1.20.4']};page.confirmInstallFromSheet();assert.equal(submitted.length,1,'Chosen file must match actual target');

// Execute the real task constructor to ensure nested input data is also snapshotted.
class View {}
let captured;
class Service {async install(request){captured=request;}}
// 本用例只验证构造时的深快照；任务/成员实际调度由独立的 registry 回归覆盖。
const taskRegistry={clearAttachedTasks(){},notifyChange(){},notifyChangeImmediate(){}};
const taskLoad=loader({feature_core:{getDownloadTaskRegistry:()=>taskRegistry,UnifiedTaskView:View,UnifiedTaskState:{PREPARING:'preparing',VERIFYING:'verifying',DOWNLOADING:'downloading',DONE:'done'},TaskCategory:{MOD:'mod'}},'./ModInstallService':{ModInstallService:Service}});
const RealTask=taskLoad('mods/src/main/ets/ModInstallTask.ets').ModInstallTask;
const original={mcDir:'/original',versionId:'v',versionIsolation:true,root:JSON.parse(JSON.stringify(version)),title:'root',router:{},optionalIds:['optional']};
const task=new RealTask(original);original.root.files[0].filename='changed.jar';original.optionalIds.push('changed');await task.start();
assert.equal(captured.root.files[0].filename,'root.jar');assert.deepEqual(Array.from(captured.optionalIds),['optional']);
// 开账busy位于真实try/finally，不能留下永久下载标记，也不能在基线前启动producer。
function finalizerPage(){return Object.assign(new exported.Page(),{router_:{},targetMcDir_:'/fixture',targetVersionId_:'v',versionIsolation:true,
 detailOptionalIds_:[],detailInstalledPrimary_:null,downloadingProjectIds_:new Set(),localScanCache_:new Map(),localScanCacheEpoch_:0,
 recordedHistoryKeys_:new Set(),historyFinalizationJobs_:new Map(),historyTerminalFacts_:new Map(),historySavedKeys_:new Set(),
 uiCtx:()=>({filesDir:'/fixture',getApplicationContext:()=>({filesDir:'/fixture'})}),kindLabelOf:()=> '模组',onStatusMessage(){},toast(){}});}
{
 const subject=finalizerPage(),before=submitted.length;io.beginError=true;
 await assert.rejects(subject.executeInstall(project,version,primary,[]),/清理忙态/);io.beginError=false;
 assert.equal(subject.downloadingProjectIds_.has(project.id),false);assert.equal(submitted.length,before);
 assert.equal(subject.localScanCacheEpoch_,1,'失败收尾同样退休旧扫描');assert.equal(subject.localScanCache_.size,0);
}
// 已完成安装的真实SUCCESS先耐久保存；关闭失败既不变FAILED，也不阻断原事实的阶段重试。
{
 io.rows.clear();io.history.length=0;const subject=finalizerPage();io.endError=true;
 await subject.executeInstall(project,version,primary,[]);const id=[...io.rows.keys()][0],record=io.history[0];
 assert.equal(record.status,'success');assert.equal(subject.recordedHistoryKeys_.has(id),false);
 const receipt=JSON.parse(io.receipts.get('/fixture/logs/ledger/'+id+'/task-terminal.json'));
 assert.equal(receipt.runNonce,io.rows.get(id).runNonce);assert.equal(receipt.outcome.state,1);
 assert.equal(receipt.outcome.endedAt,record.endedAt);assert.equal(subject.downloadingProjectIds_.size,0);
 io.endError=false;
 await subject.recordHistory(project,'模组',id,0,0,'failed','后续IO异常不能改安装结果','1.21.11','fabric','/fixture');
 assert.equal(io.rows.get(id).state,1);assert.equal(io.rows.get(id).endedAt,record.endedAt);
 assert.equal(io.history.length,1,'只补canonical，不重复追加已经持久的历史');assert(subject.recordedHistoryKeys_.has(id));
 const calls=io.endCalls;await subject.recordHistory(project,'模组',id,0,0,'failed','重复入口','1.21.11','fabric','/fixture');
 assert.equal(io.endCalls,calls,'完整成功后才以dedup返回');
}
console.log('PASS: real Mod page busy cleanup, fixed durable SUCCESS, independent history/canonical retries and post-commit dedup');
console.log('PASS: original page methods block early/error/wrong-file submission, snapshot destination/history, and real task deep-copies root/optional choices');

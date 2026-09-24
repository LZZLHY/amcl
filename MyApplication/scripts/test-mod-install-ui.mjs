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
class Task {constructor(request){this.request=request;this.view={filesDone:2,bytesDone:2};}}
const registry={enqueue:async task=>{submitted.push(task);await pendingInstall;}};
const exported={};
const js=ts.transpileModule('class Page {\n'+['loadChosenDetail','confirmInstallFromSheet','executeInstall'].map(method).join('\n')+'\n}\nexports.Page=Page;',
  {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
vm.runInNewContext(js,{exports:exported,...T,...R,ModInstallTask:Task,ResourceInstallTask:Task,
  getDownloadTaskRegistry:()=>registry,resolveInstalledLoader:()=> 'fabric',resolveInstalledMcVersion:()=> '1.21.11',
  makeResolverFromRouter:()=>({resolve:async()=>{enteredResolve();await pendingResolve;return {dependencies:[],conflicts:[],depthExceeded:false};}})});
const page=new exported.Page();Object.assign(page,{router_:{repoFor:()=>({})},detailProject_:project,detailFetchEpoch_:1,detailLoading_:true,detailError_:'',detailOptionalIds_:[],
  targetMcDir_:'/original',targetVersionId_:'target-original',versionIsolation:true,detailSelectedVersion_:version,detailPrimaryFile_:null,detailInstalledPrimary_:null,
  detailResolvedDeps_:[],downloadingProjectIds_:new Set(),localScanCache_:new Map(),messages:[],history:[],
  toast(text){this.messages.push(text);},onStatusMessage(){},buildDepRows:deps=>deps,hasValidCurrentVersion:()=>true,uiCtx:()=>undefined,kindLabelOf:()=> '模组',recordHistory(...args){this.history.push(args);}});
const loading=page.loadChosenDetail(version,1,[]);await startedResolve;page.confirmInstallFromSheet();assert.equal(submitted.length,0,'Loading must block click at the submit boundary');
releaseResolve();await loading;assert.equal(page.detailLoading_,false);assert.equal(page.detailPrimaryFile_,primary);
const install=page.executeInstall(project,version,primary,[]);assert.equal(submitted.length,1);
page.targetMcDir_='/changed';page.targetVersionId_='changed';page.versionIsolation=false;releaseInstall();await install;
assert.equal(submitted[0].request.mcDir,'/original');assert.equal(submitted[0].request.versionId,'target-original');assert.equal(submitted[0].request.versionIsolation,true);
assert.equal(page.history[0][7],'1.21.11','History uses the original game snapshot');
page.detailError_='required missing';page.confirmInstallFromSheet();assert.equal(submitted.length,1,'Unresolved required dependency must block UI submission');
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
console.log('PASS: original page methods block early/error/wrong-file submission, snapshot destination/history, and real task deep-copies root/optional choices');

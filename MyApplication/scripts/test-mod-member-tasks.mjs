/**
 * 模组依赖任务生命周期回归：使用生产 Registry 与 ModInstallTask，仅替换安装外部边界。
 * 单槽队列验证依赖视图不占调度槽；独立字节进度、整组终态、取消、重试、清理全部实际执行。
 * 另从生产安装服务抽取类，执行其文件工人，验证首个失败后会等待并取消在途任务。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { loader, root, ts } from './mod-install-test-runtime.mjs';

const turn=()=>new Promise(resolve=>setImmediate(resolve));
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const coreLoad=loader();
const U=coreLoad('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
const Registry=coreLoad('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry;
const registry=new Registry();registry.maxConcurrent=1;
const cancelled=[];let attempts=0;let control;let callback;
const file=(name,size)=>({url:'https://example.invalid/'+name+'.jar',mirrors:[],filename:name+'.jar',size,isPrimary:true});
const items=[{title:'Iris',projectId:'iris',versionId:'iv',source:'modrinth',file:file('iris',100)},
  {title:'Sodium',projectId:'sodium',versionId:'sv',source:'modrinth',file:file('sodium',200)}];
class Service {
  async install(request,observer){
    attempts++;control=deferred();callback=observer;observer.files(items);
    observer.fileProgress(0,{taskId:attempts*10,progress:0.5,bytesDone:50,bytesTotal:100,filesDone:0,filesTotal:1,speedBps:10,etaSeconds:5,currentFile:'iris.jar',finished:false,errorKind:'',errorMessage:''});
    observer.fileProgress(1,{taskId:attempts*10+1,progress:0.1,bytesDone:20,bytesTotal:200,filesDone:0,filesTotal:1,speedBps:20,etaSeconds:9,currentFile:'sodium.jar',finished:false,errorKind:'',errorMessage:''});
    await control.promise;
    if(observer.cancelled())throw new Error('已取消');
  }
}
const native={purgeTask:()=>true,cancel:id=>cancelled.push(id)};
const load=loader({feature_core:{...U,DownloadManager:{instance:()=>native},getDownloadTaskRegistry:()=>registry},
  './ModInstallService':{ModInstallService:Service}});
const Task=load('mods/src/main/ets/ModInstallTask.ets').ModInstallTask;
const request={mcDir:'/game',versionId:'v',versionIsolation:true,title:'Iris',router:{},optionalIds:[],
  root:{id:'iv',projectId:'iris',source:'modrinth',versionNumber:'1',files:[items[0].file],dependencies:[]}};
const task=new Task(request);
const first=registry.enqueue(task);const firstResult=first.catch(error=>error);
await turn();assert.equal(attempts,1);
let views=registry.listAll();assert.equal(views.length,2);
const member=views.find(v=>v.title==='Sodium');assert.ok(member);assert.notEqual(member.id,task.view.id);
assert.equal(task.view.bytesDone,50);assert.equal(member.bytesDone,20);assert.equal(member.bytesTotal,200);
assert.equal(registry.activeCount(),2);assert.equal(registry.waitingCount(),0);
assert.equal(registry.runningIds_.length,1,'成员不占调度槽');
assert.equal(registry.getAdapter(member.id).getFileEntries()[0].filename,'sodium.jar');
// 依赖卡片取消要取消同组两条 native 下载，并在整组收敛后同步进入取消终态。
await registry.cancel(member.id);assert.deepEqual(cancelled,[10,11]);control.resolve();await firstResult;await turn();
assert.ok(registry.listAll().every(v=>v.state===U.UnifiedTaskState.ABORTED));
const retry=registry.retry(member.id);await turn();assert.equal(attempts,2);
assert.equal(registry.listAll().length,2,'重试替换成员，不能积累旧卡片');
assert.equal(registry.runningIds_.length,1);
// 提交前的文件终态不能让卡片提前成功，且原生进度只属于该依赖。
callback.fileProgress(1,{taskId:21,progress:1,bytesDone:200,bytesTotal:200,filesDone:1,filesTotal:1,speedBps:0,etaSeconds:0,currentFile:'sodium.jar',finished:true,errorKind:'',errorMessage:''});
assert.equal(registry.get(member.id).state,U.UnifiedTaskState.VERIFYING);
assert.equal(task.view.bytesDone,50);
control.resolve();await retry;await turn();
assert.ok(registry.listAll().every(v=>v.state===U.UnifiedTaskState.DONE));
registry.remove(task.view.id);assert.equal(registry.listAll().length,0);

/** 文件工人使用生产方法，注入可控网络终态，证明 Promise 不会在另一个文件还运行时提前结束。 */
const filename=path.join(root,'mods/src/main/ets/ModInstallService.ets');
const source=ts.createSourceFile(filename,fs.readFileSync(filename,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const selected=source.statements.filter(n=>ts.isClassDeclaration(n)&&['ModInstallService','ModTransferBatch'].includes(n.name?.text));
const pending=new Map();const started=[];const stopped=[];
const manager={createAndWait(spec,listener){const d=deferred(),id=started.length+1;started.push(spec.name);pending.set(id,d);listener({taskId:id,finished:false});return d.promise;},
  cancel(id){stopped.push(id);pending.get(id)?.reject(new Error('cancelled'));},purgeTask:()=>true};
const exported={};
vm.runInNewContext(ts.transpileModule(selected.map(n=>n.getText(source)).join('\n'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
  {exports:exported,DownloadManager:{instance:()=>manager},AppLogger:{warn(){}},LOG_DOMAIN_DOWNLOAD:0,TAG:'test',setTimeout});
const service=new exported.ModInstallService();
const batch={next:0,owners:[],error:null};
const planned=[0,1,2,3].map(i=>({title:'file'+i,version:{source:'modrinth',projectId:'same-project',id:'same-version'}}));
const specs=planned.map((_,i)=>({localPath:'/staging/'+i,urls:[],allowedRoot:'/staging'}));
const observer={fileProgress(){},cancelled:()=>false};
const workers=[service.downloadFiles(specs,planned,batch,observer,1),service.downloadFiles(specs,planned,batch,observer,1)];
assert.equal(started.length,2);assert.notEqual(started[0],started[1],'同一模组的不同目的路径须保留独立 native journal 名称');pending.get(1).reject(new Error('network failed'));
await Promise.all(workers);assert.equal(started.length,2,'首个失败后不启动剩余文件');
assert.ok(stopped.includes(2));assert.match(batch.error.message,/file0.*network failed/);
console.log('PASS: real registry single-slot dependency cards, per-file progress, commit barrier, group cancel/retry/cleanup and joined native failure cancellation');

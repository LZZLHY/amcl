/**
 * 整合包专项回归：执行生产清单、安装器、任务、收据、目录策略及 Registry。
 * 网络/基础版本构建/平台解压为可控边界；真实文件只写工作区临时夹具，绝不操作用户实例。
 * 正常、取消、收据故障、重启恢复和补齐均沿同一生产链运行，不复制产品安装算法。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {loader,root,ts,fileIo,productionPathPolicy} from './mod-install-test-runtime.mjs';
import {resolveWorkspacePath} from './lib/workspace-paths.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';
import {actionUiReceiver,loadActionComponent} from './lib/unified-actions-fixture.mjs';

// 小型汇总留在独占运行根；大体积游戏/安装夹具只属于本次 scope，成功后按所有权回收。
// 失败或 AMCL_KEEP_TEST_OUTPUT=1 时复用现有生命周期的保现场语义，不清理历史运行根。
const reportParent=resolveWorkspacePath('run','modpack-regression');fs.mkdirSync(reportParent,{recursive:true});
const reportRoot=fs.mkdtempSync(path.join(reportParent,'run-'));
const scope=createHostTestScope('fixtures-',{parent:reportRoot,automatic:false});
const fixture=scope.directory;
const cases=[];
let failure;
try {
const slash=p=>p.replaceAll('\\','/');
const digest=(data,algorithm='sha1')=>crypto.createHash(algorithm).update(data).digest('hex');
const log={info(){},warn(){},error(){},debug(){}};
class ActivityLogger {constructor(id){this.value=id;}id(){return this.value;}info(){}warn(){}}
const passed=(name)=>{cases.push(name);console.log('PASS: '+name);};

/** 生产删除函数的宿主替代先验证绝对路径边界；不借测试之名扩大递归删除范围。 */
let removeFault='';
function remove(dir){const p=path.resolve(dir);assert.ok(p.startsWith(path.resolve(fixture)+path.sep));
  if(p===removeFault)throw new Error('injected removal failure');
  fs.rmSync(p,{recursive:true,force:true});}
function mkdir(dir){fs.mkdirSync(dir,{recursive:true});}
let receiptFault=false;
const io={...fileIo,mkdirSync:(p,recursive=false)=>fs.mkdirSync(p,{recursive}),copyFile:fs.promises.copyFile,
  // Windows 不支持目录 fsync；只替换该平台边界，普通文件依然执行真实刷盘。
  fsyncSync(fd){if(!fs.fstatSync(fd).isDirectory())fs.fsyncSync(fd);},
  openSync(p,flags){if(receiptFault&&p.endsWith('.amcl-modpack.json.writing'))throw new Error('injected receipt disk full');return fileIo.openSync(p,flags);}};
const common={AppLogger:log,ActivityLogger,LOG_DOMAIN_DOWNLOAD:0,ensureDirSync:mkdir,removeDirRecursive:remove};
const coreLoad=loader({'@kit.CoreFileKit':{fileIo:io},commons:common});
const U=coreLoad('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
const Lease=coreLoad('feature_core/src/main/ets/version/VersionInstallLease.ets');
const Paths=coreLoad('commons/src/main/ets/utils/InstancePaths.ets');
const Registry=coreLoad('feature_core/src/main/ets/download/DownloadTaskRegistry.ets').DownloadTaskRegistry;
const {ProcessActivityCoordinator}=coreLoad('feature_core/src/main/ets/download/ProcessActivityCoordinator.ets');
const registry=new Registry();registry.maxConcurrent=1;
let archiveManifest;
let archiveFormat='modrinth';
let overrides={};
let downloaded=[];
let baseBuilds=0;
let extracts=0;
let nextTask=1;
let afterBase;
let failures=new Set();
let pendingDownload;
let onDownloadEntered;
const cancelled=new Set();
const bodies=new Map();
const archiveBytes=Buffer.from('controlled archive bytes');
const worldArchiveBytes=Buffer.from('controlled world zip');

/** 故障下载不会生成目标，成功下载写入来源样本原字节；收到取消后必须结束在途 Promise。 */
const dm={purgeTask:()=>true,cancel:id=>{cancelled.add(id);pendingDownload?.resolve();return true;},
  async createAndWait(spec,progress){
    const id=nextTask++;downloaded.push(spec);
    const view={taskId:id,bytesTotal:100,bytesDone:0,speedBps:1,etaSeconds:1,filesDone:0,filesTotal:spec.files.length,failedFiles:[]};
    progress?.(view);
    if(pendingDownload&&spec.name.startsWith('modpack-files:')){onDownloadEntered?.();await pendingDownload.promise;}
    if(cancelled.has(id))throw new Error('已取消');
    for(const file of spec.files){
      if(failures.has(path.basename(file.localPath))){view.failedFiles.push({localPath:file.localPath,basename:path.basename(file.localPath),lastError:{message:'fixture unavailable'}});continue;}
      mkdir(path.dirname(file.localPath));
      fs.writeFileSync(file.localPath,spec.name.startsWith('modpack-archive:')?archiveBytes:(bodies.get(file.urls[0])??Buffer.from('fixture bytes')));
      view.filesDone++;
    }
    view.bytesDone=view.bytesTotal;progress?.(view);
    if(view.failedFiles.length)throw new Error('fixture unavailable');return view;
  }};
class Base {
  constructor(game,loader,version,name,mc,files,owner){Object.assign(this,{name,mc,owner,view:{}});}
  async start(){baseBuilds++;const release=Lease.claimVersionInstall(this.mc,this.name,this.owner);try{
    const dir=this.mc+'/versions/'+this.name;mkdir(dir);fs.writeFileSync(dir+'/'+this.name+'.jar',Buffer.alloc(1048600));fs.writeFileSync(dir+'/'+this.name+'.json','{}');
    afterBase?.(dir);
    this.onProgress?.({currentLabel:'base',progress:100,filesDone:1,filesTotal:1,bytesDone:1,bytesTotal:1,speedBps:0,etaSeconds:0});
  }finally{release();}}
  async cancel(){}purgeNativeOwner(){return true;}
}
const core={...productionPathPolicy(),...U,...Lease,DownloadManager:{instance:()=>dm},McVersionTask:Base,
  isSupportedInstallerLoader:()=>true,
  DownloadTaskRegistry:{instance:()=>registry},getDownloadTaskRegistry:()=>registry,ProcessActivityCoordinator,
  computeFileSha1:async p=>digest(fs.readFileSync(p)),computeFileSha512:async p=>digest(fs.readFileSync(p),'sha512'),
  ModLoaderType:{FABRIC:'fabric',FORGE:'forge',NEOFORGE:'neoforge',QUILT:'quilt'},
  async decompressFile(archive,dest){extracts++;mkdir(dest);
    // 平台解压边界的地图样本；目录选择、level.dat判据与发布仍执行生产安装器。
    if(fs.readFileSync(archive).equals(worldArchiveBytes)){mkdir(dest+'/world');fs.writeFileSync(dest+'/world/level.dat','world data');return;}
    fs.writeFileSync(dest+'/'+(archiveFormat==='modrinth'?'modrinth.index.json':'manifest.json'),JSON.stringify(archiveManifest));
    for(const [rel,body]of Object.entries(overrides)){mkdir(path.dirname(dest+'/'+rel));fs.writeFileSync(dest+'/'+rel,body);}}};
// 这些生命周期用例原本就隔离平台解压；包装发现另由真实ZIP专项覆盖。
// 保持这个边界显式，避免用伪ZIP字节去冒充生产中央目录预检。
const controlledPackage={preflightModpackArchive(){},async discoverModpackPackages(){return [
  {id:'controlled-root',kind:archiveFormat,root:'extracted',title:'Controlled archive',archiveChain:[]}];}};
const load=loader({feature_core:core,commons:common,'@kit.CoreFileKit':{fileIo:io},'./ModpackPackage':controlledPackage,
  // 宿主只替代 TaskPool 提交边界，交付判定和缓存清理仍执行工作线程的真实业务入口。
  './ModpackRecoveryTasks':{
    async readModpackRecoveryKind(filesDir,id){return I.inspectModpackRecovery(filesDir,id);},
    async cleanupModpackRecoveryWork(filesDir,id){return Sessions.cleanupDismissedModpackWork(filesDir,id);},
  }});
const M=load('mods/src/main/ets/ModpackManifest.ets');
const I=load('mods/src/main/ets/ModpackInstaller.ets');
const {ModpackInstallTask:Task,abandonModpackRecovery,reopenModpackRepair}=load('mods/src/main/ets/ModpackInstallTask.ets');
const Sessions=load('mods/src/main/ets/ModpackInstallSession.ets');
const Snapshot=load('mods/src/main/ets/ModpackSnapshot.ets');
const Types=load('mods/src/main/ets/ModTypes.ets');
const mrFile=(name,env='required',body='content '+name)=>{const data=Buffer.from(body),url='https://example.invalid/'+name;bodies.set(url,data);
  return {path:'mods/'+name,env:{client:env},hashes:{sha1:digest(data),sha512:digest(data,'sha512')},fileSize:data.length,downloads:[url]};};
const mr=(name,files=[])=>({formatVersion:1,game:'minecraft',name,versionId:'1',dependencies:{minecraft:'1.20.1','fabric-loader':'0.16.0'},files});
function request(name){const dir=slash(path.join(fixture,name));mkdir(dir);const archivePath=dir+'/input.zip';fs.writeFileSync(archivePath,archiveBytes);
  return {archivePath,mcDir:dir+'/mc',filesDir:dir+'/files',existingVersions:[],sessionId:Lease.newVersionInstallOwner()};}
const turn=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}

// 格式/路径/必需文件观察必须保留；服务端专用与用户没选的 optional 则不是缺失。
assert.throws(()=>M.parseModrinthIndex(JSON.stringify({...mr('bad'),formatVersion:999})),/不支持/);
assert.throws(()=>M.parseModrinthIndex(JSON.stringify({...mr('bad'),game:'other'})),/不支持/);
assert.throws(()=>M.parseCurseForgeManifest(JSON.stringify({minecraft:{version:'1.20.1'},files:[]})),/不支持/);
const badFile={...mrFile('bad.jar'),path:'../outside.jar'};
assert.equal(M.parseModrinthIndex(JSON.stringify(mr('bad',[badFile]))).plan.problems.length,1);
passed('unsupported formats rejected and invalid required paths remain structured problems');

// 来源限制必须真正到达生产 Native 规格，不能仅断言新 URL helper 的实现。
// 先经真实任务准备并暂停，随后模拟进程重启，消费带旧镜像候选的持久清单继续安装。
const strictOfficial='https://cdn.modrinth.com/data/strict/versions/1/strict.jar?sig=A%2Bb';
const strictMirror='https://mod.mcimirror.top/data/strict/versions/1/strict.jar?sig=A%2Bb';
const strictBody=Buffer.from('strict official file');bodies.set(strictOfficial,strictBody);
const strictRequired=mrFile('strict.jar','required',strictBody.toString());strictRequired.downloads=[strictOfficial];
archiveManifest=mr('Strict Sources',[strictRequired,mrFile('strict-optional.jar','optional')]);overrides={};
const strictReq={...request('strict-sources'),officialFilesOnly:true,versionName:'Strict Sources',
  archivePath:undefined,archiveUrl:'https://mod.mcimirror.top/data/pack/versions/1/pack.mrpack',
  archiveMirrors:['https://cdn.modrinth.com/data/pack/versions/1/pack.mrpack']};
const strictStart=downloaded.length;
const strictTask=new Task({...strictReq,title:'Strict Sources'});await registry.enqueue(strictTask);await turn();
assert.equal(strictTask.view.requiresConfirmation,true);
assert.deepEqual(Array.from(downloaded[strictStart].files[0].urls),['https://cdn.modrinth.com/data/pack/versions/1/pack.mrpack']);
let strictSession=strictTask.getSession();assert.equal(strictSession.officialFilesOnly,true);
// 旧会话已解析且停在确认页时，收紧来源必须在提前返回前刷盘；下一进程使用自动档
// 仍应读到严格意图，不以“后来真的开始下载时才会保存”作为恢复保障。
const legacyStrict=Sessions.loadModpackSession(strictReq.filesDir,strictReq.sessionId);
legacyStrict.officialFilesOnly=false;Sessions.saveModpackSession(strictReq.filesDir,legacyStrict);
await new I.ModpackInstaller().prepare({...strictReq,officialFilesOnly:true});
const afterColdAuto=await new I.ModpackInstaller().prepare({...strictReq,officialFilesOnly:false});
assert.equal(afterColdAuto.officialFilesOnly,true);
assert.equal(Sessions.loadModpackSession(strictReq.filesDir,strictReq.sessionId).officialFilesOnly,true);
strictSession.plan.files[0].urls=[strictMirror,strictOfficial];
Sessions.saveModpackSession(strictReq.filesDir,strictSession);strictTask.confirmSelection();
await new I.ModpackInstaller().installFromArchive({...strictReq,officialFilesOnly:false});
const strictContent=downloaded.slice(strictStart).find(spec=>spec.name.startsWith('modpack-files:'));
assert.deepEqual(Array.from(strictContent.files[0].urls),[strictOfficial]);
assert.equal(fs.readFileSync(strictReq.mcDir+'/versions/Strict Sources/mods/strict.jar','utf8'),strictBody.toString());
assert.equal(Sessions.loadModpackSession(strictReq.filesDir,strictReq.sessionId).officialFilesOnly,true);
passed('official archive and restarted manifest submit no MCIM candidate, preserve signed query and persist the stronger choice');
baseBuilds=0;

archiveManifest=mr('Pack',[mrFile('required.jar'),mrFile('optional.jar','optional'),mrFile('server.jar','unsupported')]);
overrides={'overrides/config/pack.cfg':'base','client-overrides/config/pack.cfg':'client','overrides/scripts/demo.zs':'script'};
let req={...request('confirm'),versionName:'My Pack'};let task=new Task({...req,title:'Pack'});const identity=task.view.id;
await registry.enqueue(task);await turn();assert.equal(task.view.requiresConfirmation,true);assert.equal(baseBuilds,0);
assert.equal(registry.runningIds_.length,0,'确认阶段必须归还唯一调度槽');
assert.equal(task.view.canCancel,true);assert.equal(task.view.canResume,false);
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1);
assert.deepEqual(Sessions.listModpackRecoveryPreview(req.filesDir,()=>false),Sessions.listModpackRecovery(req.filesDir));
task.setOptionalSelected(task.optionalFiles()[0],true);task.confirmSelection();await registry.resume(identity);await turn();
let session=task.getSession(),dir=req.mcDir+'/versions/My Pack';
assert.equal(task.view.state,U.UnifiedTaskState.DONE);assert.ok(fs.existsSync(dir+'/mods/required.jar'));
assert.equal(session.plan.name,'Pack','自定义实例名不能覆盖包作者的清单名');
assert.equal(session.requestedVersionName,'My Pack');
assert.ok(fs.existsSync(dir+'/mods/optional.jar'));assert.ok(!fs.existsSync(dir+'/mods/server.jar'));
assert.equal(fs.readFileSync(dir+'/config/pack.cfg','utf8'),'client');assert.equal(fs.readFileSync(dir+'/scripts/demo.zs','utf8'),'script');
assert.equal(fs.existsSync(dir+'/'+Paths.MODPACK_PENDING_FILE),false);
assert.equal(Snapshot.readModpackSnapshot(dir).schemaVersion,2);
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,0);
assert.equal(Sessions.listModpackRecoveryPreview(req.filesDir,()=>false).length,0);
assert.equal(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/archive.zip'),false);
assert.equal(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/extracted'),false);
assert.ok(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/session.json'));
passed('real Registry releases confirmation slot, preserves explicit optional choice and client override order');


// 模拟“收据与 complete 已刷盘，但进程在移除 pending 之前退出”的窄窗口。
Sessions.writeModpackJsonAtomic(dir+'/'+Paths.MODPACK_PENDING_FILE,{id:session.id});
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1);
assert.equal(Sessions.listModpackRecoveryPreview(req.filesDir,()=>false).length,1);
await new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id});
assert.equal(Paths.hasPendingModpackInstall(dir),false);assert.equal(Sessions.listModpackRecovery(req.filesDir).length,0);
assert.equal(Sessions.listModpackRecoveryPreview(req.filesDir,()=>false).length,0);
passed('restart recovers the committed-receipt/pending-removal crash window without hidden unlaunchable instances');

// 全局隔离关闭也使用实例根；普通版本仍保持共享目录，旧整合包收据继续兼容。
assert.equal(Paths.resolveInstanceGameDir(req.mcDir,'My Pack',false),dir);
assert.equal(Types.resourceKindToInstallDir(Types.ResourceKind.MOD,req.mcDir,'My Pack',false),dir+'/mods');
assert.equal(Paths.resolveInstanceGameDir(req.mcDir,'ordinary',false),req.mcDir);
const Flow=coreLoad('feature_core/src/main/ets/download/phases/DownloadFlowState.ets').DownloadFlowState;
assert.notEqual(new Flow('a',null,'','a',req.mcDir,req.filesDir).tempDir,new Flow('b',null,'','b',req.mcDir,req.filesDir).tempDir);
let release=Lease.claimVersionInstall(req.mcDir,'Busy','first');assert.throws(()=>Lease.claimVersionInstall(req.mcDir,'Busy','second'),/另一项/);
let nested=Lease.claimVersionInstall(req.mcDir,'Busy','first');nested();release();Lease.claimVersionInstall(req.mcDir,'Busy','second')();
passed('instance directory and resource consumers agree; download roots and cross-category ownership are isolated');

// 普通/整合包共享实际 processor 槽，失败和等待期间的取消都不能阻塞后继。
const processorGate=deferred(),processorOrder=[];
const firstProcessor=Lease.withInstallerProcessorLock(async()=>{processorOrder.push('first');await processorGate.promise;throw new Error('fixture processor failure');}).catch(e=>e);
let cancelQueued=true;
const nextProcessor=Lease.withInstallerProcessorLock(async()=>{if(cancelQueued)throw new Error('cancelled before native');processorOrder.push('second');}).catch(e=>e);
await turn();assert.deepEqual(processorOrder,['first']);processorGate.resolve();await Promise.all([firstProcessor,nextProcessor]);
await Lease.withInstallerProcessorLock(async()=>{processorOrder.push('third');});assert.deepEqual(processorOrder,['first','third']);
passed('shared installer processor queue serializes native work and releases on failure or queued cancellation');

// 归档已可解压也必须验证来源哈希；错误在任何解压/版本创建之前失败。
req=request('hash');let extractsBefore=extracts;
await assert.rejects(new I.ModpackInstaller().installFromArchive({...req,archiveSha1:'f'.repeat(40)}),/SHA-1/);
assert.equal(extracts,extractsBefore);
await assert.rejects(new I.ModpackInstaller().installFromArchive({...request('hash512'),archiveSha512:'f'.repeat(128)}),/SHA-512/);
assert.equal(extracts,extractsBefore);
archiveManifest=mr('Online');overrides={};req=request('online');downloaded=[];
await new I.ModpackInstaller().installFromArchive({...req,archivePath:undefined,archiveUrl:'https://example.invalid/archive',archiveSha1:digest(archiveBytes),archiveSize:archiveBytes.length});
assert.equal(downloaded[0].files[0].check.sha1,digest(archiveBytes));
assert.equal(downloaded[0].files[0].check.size,archiveBytes.length);
passed('archive SHA-1/SHA-512 mismatches stop before extraction and metadata reaches native download spec');

// 缺下载地址必须显示部分完成且可补齐，警告和精确计划进入最终收据。
const missing={...mrFile('missing.jar'),downloads:[]};archiveManifest=mr('Partial',[missing,mrFile('skip.jar','optional')]);req=request('partial');
task=new Task({...req,title:'Partial',requireConfirmation:false});await task.start();
assert.equal(task.getResult().missing.length,1);assert.match(task.view.currentLabel,/待补齐/);assert.equal(task.view.canRetry,true);
assert.equal(fs.existsSync(req.mcDir+'/versions/Partial/mods/skip.jar'),false);
assert.equal(Snapshot.readModpackSnapshot(req.mcDir+'/versions/Partial').missing.length,1);
passed('required missing file cannot report full success; unselected optional files are not installed');

// 部分完成后再恢复，原实例补齐失败的文件，用户配置与存档保持原字节。
archiveManifest=mr('Repair',[mrFile('good.jar'),mrFile('retry.jar')]);overrides={'overrides/config/user.cfg':'pack defaults'};
req=request('repair');failures=new Set(['retry.jar']);let installer=new I.ModpackInstaller();let result=await installer.installFromArchive(req);
assert.equal(result.missing.length,1);session=installer.getSession();dir=req.mcDir+'/versions/Repair';
mkdir(dir+'/saves/world');fs.writeFileSync(dir+'/saves/world/level.dat','user world');fs.writeFileSync(dir+'/config/user.cfg','user edits');
failures.clear();downloaded=[];const baseBefore=baseBuilds;
const resumed=new I.ModpackInstaller();result=await resumed.installFromArchive({...req,sessionId:session.id});
assert.equal(result.versionName,'Repair');assert.equal(result.missing.length,0);assert.equal(baseBuilds,baseBefore);
assert.equal(fs.readFileSync(dir+'/config/user.cfg','utf8'),'user edits');assert.equal(fs.readFileSync(dir+'/saves/world/level.dat','utf8'),'user world');
assert.equal(downloaded.flatMap(s=>s.files).length,1);assert.equal(fs.existsSync(req.mcDir+'/versions/Repair (2)'),false);
passed('restart-style repair downloads only missing files into original instance and preserves user config/world');

// 同名 standard loader 目录是用户内容；新的安装不会再运行猜测式残留删除。
archiveManifest=mr('Safe');overrides={};req=request('stray');const stray=req.mcDir+'/versions/fabric-loader-0.16.0-1.20.1';
mkdir(stray+'/saves/world');fs.writeFileSync(stray+'/saves/world/level.dat','original');
await new I.ModpackInstaller().installFromArchive(req);assert.equal(fs.readFileSync(stray+'/saves/world/level.dat','utf8'),'original');
passed('standard loader instance created after caller snapshot is never deleted');

// 收据保存失败不是成功：pending 留存且可重新提交，内容无需再次下载。
archiveManifest=mr('Receipt',[mrFile('receipt.jar')]);req=request('receipt');installer=new I.ModpackInstaller();receiptFault=true;
await assert.rejects(installer.installFromArchive(req),/收据保存失败/);receiptFault=false;session=installer.getSession();
assert.ok(fs.existsSync(req.mcDir+'/versions/Receipt/'+Paths.MODPACK_PENDING_FILE));downloaded=[];
const Precheck=methodClass('launch/src/main/ets/PreLaunchValidator.ets',['runModInstallState'],{
  hasPendingModpackInstall:Paths.hasPendingModpackInstall,normalizeModDirectory:p=>p,modInstallationActive:()=>false,
  withModDirectoryLock:async(p,operation)=>operation(),recoverModTransaction:async()=>{throw new Error('不应越过整合包 pending');}});
const blockedLaunch=await Precheck.runModInstallState({gameDir:req.mcDir+'/versions/Receipt'});
assert.equal(blockedLaunch.status,'fail');assert.match(blockedLaunch.detail,/整合包安装尚未完成/);
await new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id});assert.equal(downloaded.length,0);
assert.equal(fs.existsSync(req.mcDir+'/versions/Receipt/'+Paths.MODPACK_PENDING_FILE),false);
passed('receipt failure retains pending recovery state and next attempt commits without redownloading');

// 取消/暂停发生于真实任务下载等待中，Registry 不把暂停改成 ERROR，恢复继续原版本。
archiveManifest=mr('Cancel',[mrFile('cancel.jar')]);req=request('cancel');pendingDownload=deferred();const entered=deferred();onDownloadEntered=entered.resolve;
task=new Task({...req,title:'Cancel',requireConfirmation:false});const running=registry.enqueue(task);const settled=running.catch(e=>e);
await entered.promise;await registry.pause(task.view.id);await settled;await turn();
assert.equal(task.view.state,U.UnifiedTaskState.PAUSED);assert.ok(task.view.canResume);
pendingDownload=undefined;onDownloadEntered=undefined;await registry.resume(task.view.id);await turn();
assert.equal(task.view.state,U.UnifiedTaskState.DONE);assert.equal(task.getResult().versionName,'Cancel');
passed('pause joins in-flight download, retains original directory and resumes through Registry');

// 补齐已交付实例时选择“清理取消”，只能清理本轮暂存，不能删除既有用户世界。
archiveManifest=mr('Delivered',[mrFile('delivered.jar'),mrFile('again.jar')]);req=request('delivered');failures=new Set(['again.jar']);
installer=new I.ModpackInstaller();await installer.installFromArchive(req);session=installer.getSession();dir=req.mcDir+'/versions/Delivered';
mkdir(dir+'/saves/keep');fs.writeFileSync(dir+'/saves/keep/level.dat','must survive');failures.clear();
pendingDownload=deferred();const enteredRepair=deferred();onDownloadEntered=enteredRepair.resolve;
task=new Task({...req,sessionId:session.id,title:'Delivered',requireConfirmation:false});
const repairing=registry.enqueue(task).catch(e=>e);await enteredRepair.promise;await registry.cancel(task.view.id,true);await repairing;await turn();
assert.equal(fs.readFileSync(dir+'/saves/keep/level.dat','utf8'),'must survive');
assert.equal(Snapshot.readModpackSnapshot(dir).missing.length,1);assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1);
assert.equal(fs.existsSync(dir+'/'+Paths.MODPACK_PENDING_FILE),false);pendingDownload=undefined;onDownloadEntered=undefined;
passed('cancel-and-clean during repair preserves delivered instance, user world and actionable missing receipt');

// 已交付补齐停在同一个正式实例；关闭提醒必须独立于可手动核对的缺件收据和用户数据。
const deliveredReceiptPath=dir+'/.amcl-modpack.json';
const deliveredReceipt=fs.readFileSync(deliveredReceiptPath);
// 同 ID 但结构不完整的收据不能证明已交付，也不能用来撤销仍阻止启动的 pending 标记。
const deliveredPending=dir+'/'+Paths.MODPACK_PENDING_FILE;
fs.writeFileSync(deliveredPending,JSON.stringify({id:session.id}));
fs.writeFileSync(deliveredReceiptPath,JSON.stringify({...JSON.parse(deliveredReceipt),missing:null}));
await assert.rejects(abandonModpackRecovery(req.filesDir,session.id,'repair'),/提交收据/);
assert.ok(fs.existsSync(deliveredPending));
assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,session.id),undefined);
fs.writeFileSync(deliveredReceiptPath,deliveredReceipt);
assert.equal(I.inspectModpackRecovery(req.filesDir,session.id),'repair');
await assert.rejects(abandonModpackRecovery(req.filesDir,session.id,'install'));
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1,'交付状态变化后必须重新确认');
assert.equal(await abandonModpackRecovery(req.filesDir,session.id,'repair'),true);
assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,session.id),'repair');
const reloadedSessions=loader({feature_core:core,commons:common,'@kit.CoreFileKit':{fileIo:io}})('mods/src/main/ets/ModpackInstallSession.ets');
assert.equal(reloadedSessions.listModpackRecoveryPreview(req.filesDir,()=>false).length,0);
assert.equal(fs.existsSync(deliveredPending),false);
assert.deepEqual(fs.readFileSync(deliveredReceiptPath),deliveredReceipt);
assert.equal(fs.readFileSync(dir+'/saves/keep/level.dat','utf8'),'must survive');
passed('stop supplementing survives fresh disk scans and preserves the delivered receipt and user world');

// 从版本管理明确补齐同一已交付实例时才能撤销关闭。错误目标既不能使记录重新出现，也不能替换旧任务。
assert.equal(registry.getAdapter(task.view.id),task);
assert.throws(()=>reopenModpackRepair(req.filesDir,session.id,req.mcDir,'Wrong instance'),/实例已变化/);
assert.equal(registry.getAdapter(task.view.id),task);
assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,session.id),'repair');
reopenModpackRepair(req.filesDir,session.id,req.mcDir,'Delivered');
assert.equal(registry.getAdapter(task.view.id),null);
assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,session.id),undefined);
assert.deepEqual(Array.from(reloadedSessions.listModpackRecovery(req.filesDir),item=>item.id),[session.id]);
assert.deepEqual(fs.readFileSync(deliveredReceiptPath),deliveredReceipt);
const manualRepairStart=downloaded.length;
const manualRepair=new Task({title:'Delivered',filesDir:req.filesDir,mcDir:req.mcDir,sessionId:session.id,
  versionName:'Delivered',existingVersions:[],requireConfirmation:false});
await registry.enqueue(manualRepair);await turn();
assert.equal(manualRepair.getResult().missing.length,0);
assert.equal(downloaded.slice(manualRepairStart).flatMap(spec=>spec.files).length,1);
assert.ok(fs.existsSync(dir+'/mods/again.jar'));
assert.equal(fs.readFileSync(dir+'/saves/keep/level.dat','utf8'),'must survive');
passed('explicit repair reopens only the original delivered instance and downloads only its remaining file');

// 来源记录在清单之前持久化；错误归档可以在进程重启后从同一来源继续，而不是丢失任务。
req=request('early-recovery');archiveManifest=mr('Early');overrides={};
const brokenReq={...req,archiveSha1:'f'.repeat(40),displayName:'Early'};
await assert.rejects(new I.ModpackInstaller().installFromArchive(brokenReq),/SHA-1/);
const recovery=Sessions.listModpackRecovery(req.filesDir);assert.equal(recovery.length,1);assert.equal(recovery[0].title,'Early');
await assert.rejects(new I.ModpackInstaller().prepare({mcDir:req.mcDir,filesDir:req.filesDir,existingVersions:[],sessionId:req.sessionId}),/SHA-1/);
passed('archive-stage source identity survives process recreation and retains original checksum');

// 同一恢复根的两条仅来源记录互相独立；放弃的会话保留持久事实，外部原始归档仍可重新选择。
const otherEarlyId=Lease.newVersionInstallOwner();
await assert.rejects(new I.ModpackInstaller().installFromArchive({...brokenReq,sessionId:otherEarlyId,displayName:'Keep'}),/SHA-1/);
const earlyWork=Sessions.modpackWorkDir(req.filesDir,req.sessionId);
assert.equal(I.inspectModpackRecovery(req.filesDir,req.sessionId),'install');
assert.ok(fs.existsSync(earlyWork+'/archive.zip'));
assert.equal(await abandonModpackRecovery(req.filesDir,req.sessionId,'install'),true);
assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,req.sessionId),'install');
assert.deepEqual(Array.from(reloadedSessions.listModpackRecovery(req.filesDir),item=>item.id),[otherEarlyId]);
assert.equal(fs.existsSync(earlyWork+'/archive.zip'),false);
assert.deepEqual(fs.readFileSync(req.archivePath),archiveBytes);
const obsoleteTask=new Task({...req,title:'Early',requireConfirmation:false});
await assert.rejects(obsoleteTask.start(),/已放弃/);
passed('source-only abandon cleans its private archive, retains the original input and leaves other sessions visible');

// 持久关闭与物理清理是两个结果。清理失败不让已经成功放弃的记录重新回到列表。
req=request('abandon-cleanup-failure');archiveManifest=mr('Keep temporary data');
installer=new I.ModpackInstaller();await installer.prepare(req);
const blockedStage=Sessions.modpackWorkDir(req.filesDir,req.sessionId)+'/extracted';
assert.ok(fs.existsSync(blockedStage));
removeFault=path.resolve(blockedStage);
try {assert.equal(await abandonModpackRecovery(req.filesDir,req.sessionId,'install'),false);}
finally {removeFault='';}
assert.equal(reloadedSessions.listModpackRecoveryPreview(req.filesDir,()=>false).length,0);
assert.ok(fs.existsSync(blockedStage));
passed('cleanup errors retain temporary evidence while the committed abandon stays hidden');

// 让真实取消请求先抵达下载端口，再人为延迟传输释放；关闭事实与暂存清理都必须等待当前写者退出。
archiveManifest=mr('Abandon active',[mrFile('held-abandon.jar')]);overrides={};req=request('abandon-active');
pendingDownload=deferred();const enteredAbandon=deferred();onDownloadEntered=enteredAbandon.resolve;
const cancelSeen=deferred();const originalCancel=dm.cancel;
dm.cancel=id=>{cancelled.add(id);cancelSeen.resolve();return true;};
task=new Task({...req,title:'Abandon active',requireConfirmation:false});
const activeAbandon=registry.enqueue(task).catch(error=>error);
try {
  await enteredAbandon.promise;
  const work=Sessions.modpackWorkDir(req.filesDir,req.sessionId);
  const stopping=abandonModpackRecovery(req.filesDir,req.sessionId,'install');
  await Promise.race([cancelSeen.promise,stopping.then(()=>assert.fail('先安全收敛，才能完成放弃'))]);
  assert.equal(Sessions.readModpackRecoveryDismissal(req.filesDir,req.sessionId),undefined);
  assert.ok(fs.existsSync(work+'/archive.zip'));
  await assert.rejects(abandonModpackRecovery(req.filesDir,req.sessionId,'install'),/正在停止/);
  const startedCount=downloaded.length;
  await registry.resume(task.view.id);
  assert.equal(downloaded.length,startedCount,'取消收敛期间不能启动第二次下载');
  pendingDownload.resolve();
  assert.equal(await stopping,true);
  await activeAbandon;await turn();
  assert.equal(task.view.canResume,false);
  assert.equal(task.view.canRetry,false);
  assert.equal(reloadedSessions.listModpackRecovery(req.filesDir).length,0);
  assert.equal(fs.existsSync(work+'/archive.zip'),false);
} finally {
  pendingDownload?.resolve();pendingDownload=undefined;onDownloadEntered=undefined;dm.cancel=originalCancel;
}
passed('abandon cancels a real active task, waits for settlement and gates further resume/retry');

// 实例父目录被外部目录链接替代时，暂存验证可以成功，激活仍必须拒绝越界。
archiveManifest=mr('Link',[mrFile('link.jar')]);req=request('link');const outside=req.filesDir+'/outside';mkdir(outside);
afterBase=versionDir=>fs.symlinkSync(outside,versionDir+'/mods','junction');
await assert.rejects(new I.ModpackInstaller().installFromArchive(req),/父目录不是普通目录/);afterBase=undefined;
assert.equal(fs.existsSync(outside+'/link.jar'),false);
passed('verified downloads cannot be activated through a directory link outside the instance');

// CF 文件保存精确 project/file 身份，并按解析出的 resourcepacks 路径激活。
archiveFormat='curseforge';archiveManifest={manifestType:'minecraftModpack',manifestVersion:1,name:'CF',version:'1',
  minecraft:{version:'1.20.1',modLoaders:[{id:'forge-47.2.0',primary:true}]},files:[{projectID:10,fileID:20,required:true}],overrides:'overrides'};
req=request('cf');const resource=Buffer.from('resource pack');bodies.set('https://example.invalid/resource.zip',resource);
const calls=[];await new I.ModpackInstaller().installFromArchive({...req,resolveCfFile:async(pid,fid)=>{calls.push([pid,fid]);return {filename:'resource.zip',targetDirectory:'resourcepacks',urls:['https://example.invalid/resource.zip'],sha1:digest(resource),size:resource.length};}});
assert.deepEqual(calls,[[10,20]]);assert.ok(fs.existsSync(req.mcDir+'/versions/CF/resourcepacks/resource.zip'));
assert.equal(fs.existsSync(req.mcDir+'/versions/CF/mods/resource.zip'),false);
passed('CurseForge exact file identity and resource directory survive the full install pipeline');

/** 页面/仓库方法使用生产 AST 抽取，宿主只提供输入/输出边界和观察器。 */
function methodClass(relative,names,bindings={}){
  const source=fs.readFileSync(path.join(root,relative),'utf8');
  const methods=names.map(name=>{const match=new RegExp('^  (?:private |public )?(?:static )?(?:async )?'+name+'\\(','m').exec(source);assert.ok(match,name);
    const ast=ts.createSourceFile('slice.ts','class Subject {\n'+source.slice(match.index),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
    return ast.statements.find(ts.isClassDeclaration).members[0].getText(ast);});
  const exports={};vm.runInNewContext(ts.transpileModule('class Subject {\n'+methods.join('\n')+'\n}\nexports.Subject=Subject;',
    {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports,console,...bindings});return exports.Subject;
}
const C=load('mods/src/main/ets/CurseForgeUrls.ets');const Repo=load('mods/src/main/ets/RemoteModRepository.ets');
const raw=(id,server=false)=>({id,modId:10,displayName:'File '+id,fileName:id+'.zip',releaseType:1,fileDate:'2026-09-27T00:00:00Z',fileLength:10,downloadCount:1,
  downloadUrl:'https://example.invalid/'+id,gameVersions:['1.20.1','Forge'],dependencies:[],hashes:[],isAvailable:true,isServerPack:server});
assert.equal(C.mapCurseForgeFileAsVersion(raw(1,true)).isServerPack,true);
const V=methodClass('mods/src/main/ets/CurseForgeRepository.ets',['getVersions'],{...C,AppLogger:log,PAGE_SIZE_FILES:50,TTL_VERSIONS_MS:1,LOG_DOMAIN_DOWNLOAD:0});
// 方法级分页边界仍注入真实构造器的缺省来源回调，避免缺字段异常被当成分页产品回归。
let pages=0;const v=new V();Object.assign(v,{fileSourceModeProvider_:()=>C.CurseForgeFileSourceMode.MIRROR_FIRST,
  assertReady(){},parseJson:JSON.parse,async cachedFetch(){const index=pages++*50;return JSON.stringify({data:Array.from({length:50},(_,i)=>raw(index+i,index+i===249)),pagination:{totalCount:250,index,pageSize:50}});}});
assert.equal((await v.getVersions('10')).length,249);assert.equal(pages,5);
passed('server distributions remain identified/excluded and CurseForge history continues beyond 200 files');

const Controller=load('mods/src/main/ets/ModSearchController.ets').ModSearchController;
const supportsCustomResourceSave=kind=>['mod','resourcepack','shader'].includes(kind);
const Filter=methodClass('entry/src/main/ets/pages/ModBrowsePage.ets',
  ['applyFiltersToController','usesCustomResourceSave_','currentBrowseKind_','activeLoaderFilter_'],{...Types,...Repo,supportsCustomResourceSave});
const f=new Filter();Object.assign(f,{ctrl_:new Controller({}),kindIdx_:3,queryInput_:'known pack',gameVersionInput_:'1.20.1',loaderInput_:'',sortExplicit_:false,sortInput_:Repo.SortBy.DOWNLOADS});
f.applyFiltersToController();assert.equal(f.ctrl_.getState().sortBy,Repo.SortBy.RELEVANCE);assert.equal(f.ctrl_.getState().loader,'');
f.sortExplicit_=true;f.sortInput_=Repo.SortBy.UPDATED;f.applyFiltersToController();assert.equal(f.ctrl_.getState().sortBy,Repo.SortBy.UPDATED);
const browseSource=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/ModBrowsePage.ets'),'utf8');
// 结果区已收口到BrowseResults_。按真实build的AST定位两个调用，避免旧loading条件改名
// 或注释中同名文本让indexOf误报；导入入口仍必须先于加载/错误/空态/列表共用的结果区。
const browseAst=ts.createSourceFile('ModBrowsePage.ets',browseSource,ts.ScriptTarget.Latest,true);
const browseComponent=browseAst.statements.find(node=>node.name?.getText(browseAst)==='ModBrowsePage');
const browseBuild=browseComponent.members.find(node=>node.name?.getText(browseAst)==='build');
const browseCalls=new Map();
function locateBrowseCall(node){
  if(ts.isCallExpression(node)&&['this.ModpackImportRow','this.BrowseResults_'].includes(node.expression.getText(browseAst)))
    browseCalls.set(node.expression.getText(browseAst),node.getStart(browseAst));
  ts.forEachChild(node,locateBrowseCall);
}
locateBrowseCall(browseBuild);
assert.ok(browseCalls.has('this.ModpackImportRow')&&browseCalls.has('this.BrowseResults_'),'真实build必须保留导入与结果入口');
assert.ok(browseCalls.get('this.ModpackImportRow')<browseCalls.get('this.BrowseResults_'),'导入入口必须先于所有结果分支');
assert.doesNotMatch(browseSource,/return this\.resolveCfFileForModpack_/);
passed('keyword relevance and explicit sort survive page projection; import precedes result branches and task service is detached');

/** 替换 TaskPool 提交边界，执行页面真实方法以复现切类、安装终态与后台结果的竞争。 */
const scans=[];
class RecoveryScanControl {
  cancelled=false;
  cancel(){this.cancelled=true;}
  isCancelled(){return this.cancelled;}
}
const RecoveryBrowse=methodClass('entry/src/main/ets/pages/ModBrowsePage.ets',
  ['openModpackRecovery_','closeModpackRecovery_','refreshModpackRecovery_','readModpackRecovery_',
    'retireModpackRecoveryScan_','externalKindChanged_','syncDefaultResourceTarget_','currentBrowseKind_'],{
    LocalModScanControl:RecoveryScanControl, AppLogger:log, TAG:'RecoveryBrowse', LOG_DOMAIN_DOWNLOAD:0,
    ResourceKind:Types.ResourceKind,supportsCustomResourceSave,
    scanModpackRecovery(filesDir,control){
      return new Promise((resolve,reject)=>{scans.push({filesDir,control,resolve,reject});});
    },
  });
const recoveryBrowse=new RecoveryBrowse();
Object.assign(recoveryBrowse,{hostVisible:true,inited_:true,kindIdx_:0,defaultKindIdx:0,debounceTimer_:0,modpackRecovery_:[],
  mcDir:'',currentMcVersion:'',availableVersions:[],targetValid_:false,customSaveKindIndices_:[],
  uiCtx:()=>({filesDir:'/sandbox'}),closeDetail(){},resetRetreatGeometry_(){},applyFiltersToController(){}});
recoveryBrowse.refreshModpackRecovery_();
assert.equal(scans.length,0,'普通模组首屏不能提交恢复扫描');
recoveryBrowse.defaultKindIdx=3;recoveryBrowse.externalKindChanged_();
recoveryBrowse.refreshModpackRecovery_();
assert.equal(scans.length,0,'浏览整合包及面板关闭时的任务终态都不能提交扫描');
recoveryBrowse.openModpackRecovery_();
assert.equal(scans.length,1);assert.equal(scans[0].filesDir,'/sandbox');
assert.equal(recoveryBrowse.modpackRecoveryLoading_,true);
recoveryBrowse.defaultKindIdx=0;recoveryBrowse.externalKindChanged_();
assert.equal(scans[0].control.isCancelled(),true);
recoveryBrowse.defaultKindIdx=3;recoveryBrowse.externalKindChanged_();
assert.equal(scans.length,1,'回到分类不会预扫描');
recoveryBrowse.openModpackRecovery_();
scans[0].resolve([{id:'old-page'}]);await new Promise(setImmediate);
assert.equal(recoveryBrowse.modpackRecovery_.length,0);assert.equal(recoveryBrowse.modpackRecoveryLoading_,true);
recoveryBrowse.refreshModpackRecovery_();recoveryBrowse.refreshModpackRecovery_();
assert.equal(scans.length,2,'一轮读取期间合并终态刷新请求');
scans[1].resolve([{id:'pre-terminal'}]);await new Promise(setImmediate);
assert.equal(scans.length,3);assert.equal(recoveryBrowse.modpackRecovery_.length,0);
scans[2].reject(new Error('fixture TaskPool failure'));await new Promise(setImmediate);
assert.equal(recoveryBrowse.modpackRecoveryLoading_,false);assert.equal(recoveryBrowse.modpackRecoveryFailed_,true);
recoveryBrowse.refreshModpackRecovery_();scans[3].resolve([{id:'current'}]);await new Promise(setImmediate);
assert.equal(recoveryBrowse.modpackRecovery_[0].id,'current');
assert.equal(recoveryBrowse.modpackRecoveryFailed_,false);assert.equal(recoveryBrowse.modpackRecoveryLoading_,false);
recoveryBrowse.closeModpackRecovery_();recoveryBrowse.refreshModpackRecovery_();
assert.equal(scans.length,4,'关闭面板后不再读取');
passed('only the open recovery panel reads candidates and discards retired or superseded results; failures can retry');

// 执行恢复列表实际 Builder 的两个点击回调，系统弹窗由宿主提供可控确认结果。
// 验证兄弟控件各自携带会话身份，并且点叉、关闭面板和确认放弃是不同动作。
const recoveryUi=actionUiReceiver();
recoveryUi.globals.List=recoveryUi.globals.Column;
recoveryUi.globals.ListItem=recoveryUi.globals.Column;
recoveryUi.globals.LoadingProgress=recoveryUi.globals.Column;
recoveryUi.globals.Color={Transparent:'transparent'};
for(const name of ['alignItems','borderRadius','enabled','focusable','accessibilityText','onClick']) {
  recoveryUi.globals[name]=(...args)=>recoveryUi.globals.Column()[name](...args);
}
const recoveryDialogs=[],dismissals=[],resumes=[];
let nextDismissChoice=Promise.resolve({index:0});
const RecoveryActions=loadActionComponent('entry/src/main/ets/pages/ModBrowsePage.ets','ModBrowsePage',{
  methods:['ImmersiveTitleContent2_','confirmDismissModpack_','modpackRecoveryVisible_'],render:true,
  globals:{...recoveryUi.globals,TAG:'RecoveryActions'},
  dependencies:{
    commons:{AppIconName:{Close:'close'},AppLogger:log,LOG_DOMAIN_DOWNLOAD:0},
    '../components/AppIcon':{AppIcon:recoveryUi.globals.AppIcon},
    mods:{
      async readModpackRecoveryKind(_filesDir,id){return id==='delivered'?'repair':'install';},
      async abandonModpackRecovery(filesDir,id,kind){dismissals.push([filesDir,id,kind]);return true;},
    },
  },
});
const recoveryActions=new RecoveryActions();
const unfinishedItem={id:'unfinished',title:'Unfinished',versionName:'',confirmed:false,missingCount:0};
const deliveredItem={id:'delivered',title:'Delivered',versionName:'My Delivered',confirmed:true,missingCount:1};
Object.assign(recoveryActions,{
  theme:{},hostVisible:true,kindIdx_:3,showModpackRecovery_:true,detailDisposed_:false,modpackDismissId_:'',modpackRecoveryEpoch_:0,
  modpackRecovery_:[unfinishedItem,deliveredItem],uiCtx:()=>({filesDir:'/sandbox'}),
  getUIContext:()=>({getPromptAction:()=>({showDialog(options){recoveryDialogs.push(options);return nextDismissChoice;}})}),
  resumeModpack_:item=>resumes.push(item.id),refreshModpackRecovery_(){},toast(){},
});
recoveryActions.ImmersiveTitleContent2_();
const rowActions=recoveryUi.records.filter(record=>typeof record.modifiers.onClick?.[0]==='function');
assert.equal(rowActions.length,4);
rowActions[0].modifiers.onClick[0]();
rowActions[3].modifiers.onClick[0]();await turn();
assert.deepEqual(resumes,['unfinished']);
assert.match(recoveryDialogs[0].title,/不再补齐「My Delivered」/);
assert.deepEqual(dismissals,[]);

// 异步弹窗打开后退出，再投递旧确认，也不能操作文件或把另一条当成选中的记录。
const staleDismissChoice=deferred();nextDismissChoice=staleDismissChoice.promise;
rowActions[1].modifiers.onClick[0]();await turn();
assert.match(recoveryDialogs[1].title,/放弃安装「Unfinished」/);
recoveryUi.clear();recoveryActions.ImmersiveTitleContent2_();
const busyActions=recoveryUi.records.filter(record=>typeof record.modifiers.onClick?.[0]==='function');
assert.deepEqual(busyActions.map(record=>record.modifiers.enabled?.[0]),[false,false,true,false]);
assert.ok(recoveryUi.records.some(record=>record.modifiers.accessibilityText?.[0]==='正在处理安装记录'));
recoveryActions.showModpackRecovery_=false;recoveryActions.modpackRecoveryEpoch_++;
staleDismissChoice.resolve({index:1});await turn();
assert.deepEqual(dismissals,[]);
recoveryActions.showModpackRecovery_=true;nextDismissChoice=Promise.resolve({index:1});
rowActions[1].modifiers.onClick[0]();await turn();
assert.deepEqual(dismissals,[['/sandbox','unfinished','install']]);
assert.deepEqual(recoveryActions.modpackRecovery_.map(item=>item.id),['delivered']);
assert.deepEqual(resumes,['unfinished']);
passed('recovery row renders separate resume and dismiss actions, and only the current confirmed row is removed');

/**
 * 执行浏览页的真实入口：设置全局根与其他资源的临时目标故意不同，防止删除位置控件后
 * 仍把整合包送进过期的 targetMcDir_。文件选择的宿主边界用 Promise 模拟，任务使用生产类。
 * 恢复另用旧根验证实例身份；全局设置的变化不能把原实例补齐改成异地的新安装。
 */
let pickLocalArchive;
const localArchiveChoice=new Promise(resolve=>{pickLocalArchive=resolve;});
const Browse=methodClass('entry/src/main/ets/pages/ModBrowsePage.ets',
  ['installModpackFromSheet','importLocalModpack_','confirmLocalModpack_','resumeModpack_','closeModpackRecovery_',
    'retireModpackRecoveryScan_','setHeaderCollapsed','resolveCurseForgeFileMode','onlyOfficialModpackFiles_'],{
    ...Types,CurseForgeFileSourceMode:C.CurseForgeFileSourceMode,
    resolveCurseForgeFileSourcePreference:C.resolveCurseForgeFileSourcePreference,getRelayClient:()=>({isEnabled:()=>false,status:()=>({active:false})}),
    ModpackInstallTask:Task,newVersionInstallOwner:Lease.newVersionInstallOwner,
    createModpackFileResolver:()=>async()=>undefined,getDownloadTaskRegistry:()=>registry,
    sanitizeVersionName:I.sanitizeVersionName,validateModpackVersionName:I.validateModpackVersionName,
    displayTitleOf:p=>p.title,
    GameArchiveIO:{importResourceFile:()=>localArchiveChoice},
    Curve:{FastOutSlowIn:'fast-out-slow-in'},
  });
const browserTasks=[],browserLayoutCalls=[];const browser=new Browse();
Object.assign(browser,{mcDir:'/settings/current',targetMcDir_:'/resource-picker/old',availableVersions:[],
  cacheRemoteMeta:true,queryInput_:'pack query',loaderInput_:'forge',headerCollapsed_:false,
  uiCtx:()=>({filesDir:slash(fixture)+'/browser-files'}),onStatusMessage(){},toast(message){throw new Error(message);},
  dismissLocalDraft_(){this.localArchiveOwner_?.(true);this.localArchiveOwner_=undefined;},
  ownLocalArchive_:()=>()=>{},
  runModpackInstall_(task,_lock,capture){browserTasks.push(task);capture?.(task,Promise.resolve());},
  getUIContext:()=>({animateTo(_options,apply){apply();}}),
  listScroller_:{scrollTo(){throw new Error('filter toggle must not scroll away results');}},
  // 本组验证安装目标和筛选选择保留，几何/手势策略由独立退让回归验证；明确记录这两个
  // 布局端口被原setHeaderCollapsed调用，不用缺方法中断安装流程，也不复制布局算法。
  freezeRetreatAnchor_(){browserLayoutCalls.push('freeze');},resetRetreat_(){browserLayoutCalls.push('reset');},
});
browser.installModpackFromSheet({id:'pack',title:'Pack',source:Types.ModSource.MODRINTH,iconUrl:''},
  {id:'pack-v'},{url:'https://example.invalid/pack.mrpack',filename:'pack.mrpack',size:1});
assert.equal(browserTasks[0].getInstallRoot(),'/settings/current');
assert.equal(browserTasks[0].getInstallName(),'Pack');
browser.mcDir='/settings/changed';
const importing=browser.importLocalModpack_();browser.mcDir='/settings/changed-after-picker';
pickLocalArchive({cancelled:false,ok:true,name:'local.mrpack'});await importing;
assert.equal(browserTasks.length,1,'本地选择文件后先打开下载详情，不直接入队');
assert.equal(browser.showLocalModpackDetail_,true);browser.localModpackName_='Local Custom';browser.confirmLocalModpack_();
assert.equal(browserTasks[1].getInstallRoot(),'/settings/changed','Local import snapshots the settings root before awaiting the picker');
assert.equal(browserTasks[1].getInstallName(),'Local Custom');
// 执行生产具名处理和真实名称校验，纠错应复用本次最初的文件引用。
const PreparePack=methodClass('entry/src/main/ets/launcherskill/BrowseSkill.ets',['run'],{
  ResourceKind:Types.ResourceKind,LauncherSkillBus:{awaitingUser(){}},util:{generateRandomUUID:crypto.randomUUID},
  textArg:(args,key)=>args[key]??'',result:(state,reason)=>({state,reason}),validateModpackVersionName:I.validateModpackVersionName});
const prepare=new PreparePack();let draft=null;
prepare.access=()=>({available:()=>true,kind:()=>Types.ResourceKind.MODPACK,detail:()=>null,local:()=>draft,contextKey:()=>'/mc',
  importLocal:async()=>{draft={name:'Original',archive:'/copy/pack',root:'/mc',valid:true};return 'selected';},
  renameLocal:name=>{draft.name=name;draft.valid=!I.validateModpackVersionName(name);}});
const chosen=await prepare.run('chooseLocalModpack',{});
const planArgs={selectionRef:chosen.selectionRef,instance:'A'.repeat(121)};
assert.equal((await prepare.run('prepareLocalModpack',planArgs)).reason,'invalidInstance');assert.equal(draft.name,'Original');
planArgs.instance='Corrected';assert.equal((await prepare.run('prepareLocalModpack',planArgs)).instance,'Corrected');
passed('invalid modpack name retains the original selection and accepts a corrected name');
browser.resumeModpack_({id:'persisted-pack',title:'Persisted',mcDir:'/original/instance-root'});
assert.equal(browserTasks[2].getInstallRoot(),'/original/instance-root','Recovery keeps the original instance root');
browser.setHeaderCollapsed(true);assert.equal(browser.headerCollapsed_,true);
browser.setHeaderCollapsed(false);assert.equal(browser.headerCollapsed_,false);
assert.deepEqual(browserLayoutCalls,['freeze','reset','freeze','reset'],'每次真实筛选开关均先冻结并复位布局');
assert.equal(browser.queryInput_,'pack query');assert.equal(browser.loaderInput_,'forge');
passed('new online/local packs follow settings root; recovery retains original instance and filter toggle preserves search/selection without scrolling results');

const Sync=methodClass('entry/src/main/ets/pages/Index.ets',['syncStatusFromRegistry_'],{...U,ActivityCategory:{MODPACK:'modpack'}});
let views=[];const sync=new Sync();let finished=0;Object.assign(sync,{registry:{listAll:()=>views},registryTerminalProjection_:new Map(),applyModpackResult_(){finished++;},scanVersions(){}});
views=[{id:'modpack:identity',category:U.TaskCategory.MODPACK,state:U.UnifiedTaskState.DONE,startedAtMs:1,title:'Pack'}];sync.syncStatusFromRegistry_();
views=[{...views[0],startedAtMs:2}];sync.syncStatusFromRegistry_();assert.equal(finished,2);
passed('each attempt completes its activity/configuration/refresh notification exactly once');

// DS02：覆盖阶段自身中断，与“覆盖全部完成后的文件补齐”不同。恢复必须保留用户改动，
// 用户恢复原字节后允许继续，并保持 client-overrides 对基础层的合法覆盖顺序。
archiveFormat='modrinth';archiveManifest=mr('OverrideRecovery');overrides={'overrides/config/a.cfg':'PACK-A','overrides/config/b.cfg':'PACK-B',
  'client-overrides/config/a.cfg':'CLIENT-A'};req=request('override-recovery');
const originalCopy=io.copyFile;let copied=0;
io.copyFile=async(src,dst)=>{if(src.endsWith('/b.cfg'))throw new Error('second override failed');copied++;return originalCopy(src,dst);};
installer=new I.ModpackInstaller();await assert.rejects(installer.installFromArchive(req),/second override/);session=installer.getSession();
const recoveryConfig=req.mcDir+'/versions/OverrideRecovery/config/a.cfg';
assert.equal(fs.readFileSync(recoveryConfig,'utf8'),'PACK-A');fs.writeFileSync(recoveryConfig,'USER-EDIT');io.copyFile=originalCopy;
await assert.rejects(new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id}),/用户修改/);
assert.equal(fs.readFileSync(recoveryConfig,'utf8'),'USER-EDIT');fs.writeFileSync(recoveryConfig,'PACK-A');
await new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id});
assert.equal(fs.readFileSync(recoveryConfig,'utf8'),'CLIENT-A');
passed('interrupted overrides preserve user edits and resume ordered client overrides after conflict resolution');

// 激活已完成、committed 记录还没刷盘：通过写前摘要识别，不重复复制、不误报用户冲突。
archiveManifest=mr('OverrideCommit');overrides={'overrides/config/a.cfg':'COMMITTED'};req=request('override-commit');
const committedConfig=req.mcDir+'/versions/OverrideCommit/config/a.cfg';const originalOpen=io.openSync;let journalFault=true;
io.openSync=(p,flags)=>{if(journalFault&&p.endsWith('/session.json.writing')&&fs.existsSync(committedConfig))throw new Error('override commit receipt fault');return originalOpen(p,flags);};
installer=new I.ModpackInstaller();await assert.rejects(installer.installFromArchive(req),/commit receipt fault/);session=installer.getSession();
journalFault=false;io.openSync=originalOpen;copied=0;io.copyFile=async(src,dst)=>{copied++;return originalCopy(src,dst);};
await new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id});io.copyFile=originalCopy;
assert.equal(copied,0);assert.equal(fs.readFileSync(committedConfig,'utf8'),'COMMITTED');
passed('write-ahead override receipt recovers rename-before-commit without recopying');

/** 无可选内容的包沿生产 Registry 连续完成；名称来自入队值，外部草稿改变不影响任务。 */
archiveManifest=mr('Author Name',[mrFile('continuous.jar')]);overrides={};
req={...request('continuous'),versionName:'Sheet Name'};task=new Task({...req,title:'Store Name'});
req.versionName='Later Edit';await registry.enqueue(task);await turn();
assert.equal(task.view.state,U.UnifiedTaskState.DONE);assert.equal(task.view.requiresConfirmation,false);
assert.equal(task.getResult().versionName,'Sheet Name');assert.equal(task.getSession().plan.name,'Author Name');
assert.equal(task.getInstallName(),'Sheet Name');
passed('required-only pack installs continuously with captured sheet name and original author name');

/** 可选项等待期间关闭进程，用来源与会话恢复同一名称，不要求重新命名。 */
archiveManifest=mr('Persistent Author',[mrFile('choice.jar','optional')]);req={...request('persisted-name'),versionName:'Saved Choice'};
task=new Task({...req,title:'Store Name'});await registry.enqueue(task);await turn();
assert.equal(task.view.requiresConfirmation,true);let restoredTask=new Task({...req,versionName:undefined,title:'Store Name'});
await restoredTask.start();assert.equal(restoredTask.getInstallName(),'Saved Choice');
restoredTask.setOptionalSelected(restoredTask.optionalFiles()[0],true);restoredTask.confirmSelection();await restoredTask.start();
assert.equal(restoredTask.getResult().versionName,'Saved Choice');assert.equal(restoredTask.getSession().plan.name,'Persistent Author');
assert.equal(I.validateModpackVersionName(''), '版本名称不能为空');
assert.ok(I.validateModpackVersionName('bad/name').length>0);assert.equal(I.validateModpackVersionName('我的整合包'),'');
passed('name intent survives pending optional selection and restart; invalid manual names remain rejected');

/** 模拟私有缓存与外部实例为两个设备：跨根 rename 必须失败，同目录发布继续正常。 */
archiveManifest=mr('CrossVolume',[mrFile('volume.jar')]);overrides={'overrides/config/volume.cfg':'external config'};
req=request('cross-volume');const originalRename=io.renameSync;let forbiddenCrossRenames=0;
io.renameSync=(source,target)=>{
  if(source.startsWith(req.filesDir+'/')&&target.startsWith(req.mcDir+'/')){
    forbiddenCrossRenames++;throw new Error('Cross-device link');
  }
  return originalRename(source,target);
};
try{
  const result=await new I.ModpackInstaller().installFromArchive({...req,iconUrl:'https://example.invalid/icon'});
  const installed=req.mcDir+'/versions/'+result.versionName;
  assert.ok(fs.existsSync(installed+'/mods/volume.jar'));assert.equal(fs.readFileSync(installed+'/config/volume.cfg','utf8'),'external config');
  assert.ok(fs.existsSync(installed+'/'+Snapshot.MODPACK_ICON_FILE));assert.equal(forbiddenCrossRenames,0);
}finally{io.renameSync=originalRename;}
passed('private-cache to external-instance publication copies/verifies locally; content, overrides and icon never rename across devices');

/** CF 地图的目录发布也必须留在 saves 文件系统，不能只修复普通模组的单文件 rename。 */
archiveFormat='curseforge';archiveManifest={manifestType:'minecraftModpack',manifestVersion:1,name:'WorldVolume',version:'1',
  minecraft:{version:'1.20.1',modLoaders:[{id:'fabric-0.16.0',primary:true}]},files:[{projectID:900,fileID:901,required:true}],overrides:'overrides'};
overrides={};req=request('world-volume');bodies.set('https://example.invalid/world.zip',worldArchiveBytes);
io.renameSync=(source,target)=>{if(source.startsWith(req.filesDir+'/')&&target.startsWith(req.mcDir+'/'))throw new Error('Cross-device link');return originalRename(source,target);};
try{
  const result=await new I.ModpackInstaller().installFromArchive({...req,resolveCfFile:async()=>({filename:'World.zip',targetDirectory:'saves',
    urls:['https://example.invalid/world.zip'],sha1:digest(worldArchiveBytes),size:worldArchiveBytes.length})});
  assert.equal(fs.readFileSync(req.mcDir+'/versions/'+result.versionName+'/saves/World/level.dat','utf8'),'world data');
}finally{io.renameSync=originalRename;}
passed('map extraction and world-directory activation stay on the external saves filesystem');

/** 复制增加异步边界，目标在复制期间出现时必须保留用户文件，并记录可补齐缺失。 */
archiveFormat='modrinth';archiveManifest=mr('CopyRace',[mrFile('race.jar')]);req=request('copy-race');
const copyBeforeRace=io.copyFile;io.copyFile=async(source,target)=>{await copyBeforeRace(source,target);
  if(source.includes('/files/mods/race.jar'))fs.writeFileSync(req.mcDir+'/versions/CopyRace/mods/race.jar','USER-CREATED');};
try{
  const result=await new I.ModpackInstaller().installFromArchive(req);
  assert.equal(fs.readFileSync(req.mcDir+'/versions/CopyRace/mods/race.jar','utf8'),'USER-CREATED');
  assert.equal(result.missing.length,1);assert.match(result.missing[0].reason,/复制期间/);
}finally{io.copyFile=copyBeforeRace;}
passed('a user file created during target-side copying remains intact and becomes an explicit missing item');

// 部分交付任务仍在内存时重命名，补齐必须按安装身份定位新目录，不能误报用户删实例。
archiveManifest=mr('BeforeRename',[mrFile('rename.jar')]);overrides={};req=request('renamed-repair');failures=new Set(['rename.jar']);
task=new Task({...req,title:'BeforeRename',requireConfirmation:false});await task.start();session=task.getSession();
const renamedOld=req.mcDir+'/versions/BeforeRename',renamedNew=req.mcDir+'/versions/AfterRename';
fs.renameSync(renamedOld,renamedNew);fs.renameSync(renamedNew+'/BeforeRename.json',renamedNew+'/AfterRename.json');fs.renameSync(renamedNew+'/BeforeRename.jar',renamedNew+'/AfterRename.jar');
failures=new Set();await task.retry();assert.equal(task.view.state,U.UnifiedTaskState.DONE);assert.equal(task.getResult().versionName,'AfterRename');
assert.ok(fs.existsSync(renamedNew+'/mods/rename.jar'));assert.equal(fs.existsSync(renamedOld),false);
passed('hot repair discovers the renamed instance by install identity and fills its original missing file');

// 冷队列从未加载内存Session；清理前必须读持久owner，不能只删恢复工作根留下pending。
archiveManifest=mr('ColdPending',[mrFile('cold.jar')]);overrides={};req=request('cold-pending');afterBase=()=>{throw new Error('fixture stop after base');};
installer=new I.ModpackInstaller();await assert.rejects(installer.installFromArchive(req),/stop after base/);afterBase=undefined;session=installer.getSession();
assert.ok(fs.existsSync(req.mcDir+'/versions/ColdPending/'+Paths.MODPACK_PENDING_FILE));
await new I.ModpackInstaller().discard({...req,sessionId:session.id});assert.equal(fs.existsSync(req.mcDir+'/versions/ColdPending'),false);
assert.equal(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)),false);
passed('cold queued cleanup loads the persistent owner and leaves no unlaunchable orphan pending instance');

// 同名实例或归属不符的 pending 可能包含用户世界；关闭会话只处理其恢复身份，不能递归删除版本目录。
archiveManifest=mr('ForeignOwner',[mrFile('foreign-owner.jar')]);overrides={};req=request('foreign-owner');
afterBase=()=>{throw new Error('fixture stop before owner replacement');};
installer=new I.ModpackInstaller();
await assert.rejects(installer.installFromArchive(req),/stop before owner replacement/);afterBase=undefined;
dir=req.mcDir+'/versions/ForeignOwner';
const foreignPending=dir+'/'+Paths.MODPACK_PENDING_FILE;
const foreignOwner=JSON.stringify({id:Lease.newVersionInstallOwner()});
fs.writeFileSync(foreignPending,foreignOwner);
mkdir(dir+'/saves/world');fs.writeFileSync(dir+'/saves/world/level.dat','foreign user world');
await abandonModpackRecovery(req.filesDir,req.sessionId,'install');
assert.equal(fs.readFileSync(foreignPending,'utf8'),foreignOwner);
assert.equal(fs.readFileSync(dir+'/saves/world/level.dat','utf8'),'foreign user world');
assert.equal(reloadedSessions.listModpackRecovery(req.filesDir).length,0);
passed('abandon with a conflicting instance owner preserves the other pending marker and user world');

console.log('Modpack regression passed: '+cases.length+' groups; summary '+path.join(reportRoot,'summary.json'));
} catch(error) {
  failure=error;
  throw error;
} finally {
  // 所有生产异步方法和故障恢复断言结束后才关闭 scope；任何非零退出也保留原始夹具。
  // 汇总位于 scope 外，回收游戏 JAR/会话后仍保留本轮断言结论与原现场路径。
  const summary={checkedAt:new Date().toISOString(),state:failure||process.exitCode?'FAIL':'PASS',
    total:cases.length,cases,fixture,keepRequested:process.env.AMCL_KEEP_TEST_OUTPUT==='1',
    ...(failure?{error:failure.stack??String(failure)}:{})};
  const report=path.join(reportRoot,'summary.json');
  fs.writeFileSync(report,JSON.stringify(summary,null,2)+'\n');
  try {await scope.close({success:summary.state==='PASS'});}
  catch(error) {
    // 资源/目录身份收尾失败不能变成静默成功，原现场由生命周期保留供复核。
    fs.writeFileSync(report,JSON.stringify({...summary,state:'FAIL',cleanupError:error.stack??String(error)},null,2)+'\n');
    throw error;
  }
}

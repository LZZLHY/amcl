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
import {workspaceTempRoot} from './lib/workspace-paths.mjs';

const parent=workspaceTempRoot();fs.mkdirSync(parent,{recursive:true});
const fixture=fs.mkdtempSync(path.join(parent,'modpack-regression-'));
const slash=p=>p.replaceAll('\\','/');
const digest=(data,algorithm='sha1')=>crypto.createHash(algorithm).update(data).digest('hex');
const log={info(){},warn(){},error(){},debug(){}};
class ActivityLogger {constructor(id){this.value=id;}id(){return this.value;}info(){}warn(){}}
const cases=[];
const passed=(name)=>{cases.push(name);console.log('PASS: '+name);};

/** 生产删除函数的宿主替代先验证绝对路径边界；不借测试之名扩大递归删除范围。 */
function remove(dir){const p=path.resolve(dir);assert.ok(p.startsWith(path.resolve(fixture)+path.sep));fs.rmSync(p,{recursive:true,force:true});}
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
  DownloadTaskRegistry:{instance:()=>registry},getDownloadTaskRegistry:()=>registry,
  computeFileSha1:async p=>digest(fs.readFileSync(p)),computeFileSha512:async p=>digest(fs.readFileSync(p),'sha512'),
  ModLoaderType:{FABRIC:'fabric',FORGE:'forge',NEOFORGE:'neoforge',QUILT:'quilt'},
  async decompressFile(archive,dest){extracts++;mkdir(dest);
    // 平台解压边界的地图样本；目录选择、level.dat判据与发布仍执行生产安装器。
    if(fs.readFileSync(archive).equals(worldArchiveBytes)){mkdir(dest+'/world');fs.writeFileSync(dest+'/world/level.dat','world data');return;}
    fs.writeFileSync(dest+'/'+(archiveFormat==='modrinth'?'modrinth.index.json':'manifest.json'),JSON.stringify(archiveManifest));
    for(const [rel,body]of Object.entries(overrides)){mkdir(path.dirname(dest+'/'+rel));fs.writeFileSync(dest+'/'+rel,body);}}};
const load=loader({feature_core:core,commons:common,'@kit.CoreFileKit':{fileIo:io}});
const M=load('mods/src/main/ets/ModpackManifest.ets');
const I=load('mods/src/main/ets/ModpackInstaller.ets');
const Task=load('mods/src/main/ets/ModpackInstallTask.ets').ModpackInstallTask;
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

archiveManifest=mr('Pack',[mrFile('required.jar'),mrFile('optional.jar','optional'),mrFile('server.jar','unsupported')]);
overrides={'overrides/config/pack.cfg':'base','client-overrides/config/pack.cfg':'client','overrides/scripts/demo.zs':'script'};
let req={...request('confirm'),versionName:'My Pack'};let task=new Task({...req,title:'Pack'});const identity=task.view.id;
await registry.enqueue(task);await turn();assert.equal(task.view.requiresConfirmation,true);assert.equal(baseBuilds,0);
assert.equal(registry.runningIds_.length,0,'确认阶段必须归还唯一调度槽');
assert.equal(task.view.canCancel,true);assert.equal(task.view.canResume,false);
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1);
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
assert.equal(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/archive.zip'),false);
assert.equal(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/extracted'),false);
assert.ok(fs.existsSync(Sessions.modpackWorkDir(req.filesDir,session.id)+'/session.json'));
passed('real Registry releases confirmation slot, preserves explicit optional choice and client override order');


// 模拟“收据与 complete 已刷盘，但进程在移除 pending 之前退出”的窄窗口。
Sessions.writeModpackJsonAtomic(dir+'/'+Paths.MODPACK_PENDING_FILE,{id:session.id});
assert.equal(Sessions.listModpackRecovery(req.filesDir).length,1);
await new I.ModpackInstaller().installFromArchive({...req,sessionId:session.id});
assert.equal(Paths.hasPendingModpackInstall(dir),false);assert.equal(Sessions.listModpackRecovery(req.filesDir).length,0);
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

// 来源记录在清单之前持久化；错误归档可以在进程重启后从同一来源继续，而不是丢失任务。
req=request('early-recovery');archiveManifest=mr('Early');overrides={};
const brokenReq={...req,archiveSha1:'f'.repeat(40),displayName:'Early'};
await assert.rejects(new I.ModpackInstaller().installFromArchive(brokenReq),/SHA-1/);
const recovery=Sessions.listModpackRecovery(req.filesDir);assert.equal(recovery.length,1);assert.equal(recovery[0].title,'Early');
await assert.rejects(new I.ModpackInstaller().prepare({mcDir:req.mcDir,filesDir:req.filesDir,existingVersions:[],sessionId:req.sessionId}),/SHA-1/);
passed('archive-stage source identity survives process recreation and retains original checksum');

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
let pages=0;const v=new V();Object.assign(v,{assertReady(){},parseJson:JSON.parse,async cachedFetch(){const index=pages++*50;return JSON.stringify({data:Array.from({length:50},(_,i)=>raw(index+i,index+i===249)),pagination:{totalCount:250,index,pageSize:50}});}});
assert.equal((await v.getVersions('10')).length,249);assert.equal(pages,5);
passed('server distributions remain identified/excluded and CurseForge history continues beyond 200 files');

const Controller=load('mods/src/main/ets/ModSearchController.ets').ModSearchController;
const Filter=methodClass('entry/src/main/ets/pages/ModBrowsePage.ets',['applyFiltersToController'],{...Types,...Repo});
const f=new Filter();Object.assign(f,{ctrl_:new Controller({}),kindIdx_:3,queryInput_:'known pack',gameVersionInput_:'1.20.1',loaderInput_:'',sortExplicit_:false,sortInput_:Repo.SortBy.DOWNLOADS});
f.applyFiltersToController();assert.equal(f.ctrl_.getState().sortBy,Repo.SortBy.RELEVANCE);assert.equal(f.ctrl_.getState().loader,'');
f.sortExplicit_=true;f.sortInput_=Repo.SortBy.UPDATED;f.applyFiltersToController();assert.equal(f.ctrl_.getState().sortBy,Repo.SortBy.UPDATED);
const browseSource=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/ModBrowsePage.ets'),'utf8');
assert.ok(browseSource.indexOf('this.ModpackImportRow()')<browseSource.indexOf('if (this.view_.loading &&'));
assert.doesNotMatch(browseSource,/return this\.resolveCfFileForModpack_/);
passed('keyword relevance and explicit sort survive page projection; import precedes result branches and task service is detached');

/**
 * 执行浏览页的真实入口：设置全局根与其他资源的临时目标故意不同，防止删除位置控件后
 * 仍把整合包送进过期的 targetMcDir_。文件选择的宿主边界用 Promise 模拟，任务使用生产类。
 * 恢复另用旧根验证实例身份；全局设置的变化不能把原实例补齐改成异地的新安装。
 */
let pickLocalArchive;
const localArchiveChoice=new Promise(resolve=>{pickLocalArchive=resolve;});
const Browse=methodClass('entry/src/main/ets/pages/ModBrowsePage.ets',
  ['installModpackFromSheet','importLocalModpack_','confirmLocalModpack_','resumeModpack_','setHeaderCollapsed'],{
    ...Types,ModpackInstallTask:Task,newVersionInstallOwner:Lease.newVersionInstallOwner,
    createModpackFileResolver:()=>async()=>undefined,getDownloadTaskRegistry:()=>registry,
    sanitizeVersionName:I.sanitizeVersionName,validateModpackVersionName:I.validateModpackVersionName,
    displayTitleOf:p=>p.title,
    GameArchiveIO:{importResourceFile:()=>localArchiveChoice},
    Curve:{FastOutSlowIn:'fast-out-slow-in'},
  });
const browserTasks=[];const browser=new Browse();
Object.assign(browser,{mcDir:'/settings/current',targetMcDir_:'/resource-picker/old',availableVersions:[],
  cacheRemoteMeta:true,queryInput_:'pack query',loaderInput_:'forge',headerCollapsed_:false,
  uiCtx:()=>({filesDir:slash(fixture)+'/browser-files'}),onStatusMessage(){},toast(message){throw new Error(message);},
  runModpackInstall_(task){browserTasks.push(task);},
  getUIContext:()=>({animateTo(_options,apply){apply();}}),
  listScroller_:{scrollTo(){throw new Error('filter toggle must not scroll away results');}},
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
browser.resumeModpack_({id:'persisted-pack',title:'Persisted',mcDir:'/original/instance-root'});
assert.equal(browserTasks[2].getInstallRoot(),'/original/instance-root','Recovery keeps the original instance root');
browser.setHeaderCollapsed(true);assert.equal(browser.headerCollapsed_,true);
browser.setHeaderCollapsed(false);assert.equal(browser.headerCollapsed_,false);
assert.equal(browser.queryInput_,'pack query');assert.equal(browser.loaderInput_,'forge');
passed('new online/local packs follow settings root; recovery retains original instance and filter toggle preserves search/selection without scrolling results');

const Sync=methodClass('entry/src/main/ets/pages/Index.ets',['syncStatusFromRegistry_'],{...U,ActivityCategory:{MODPACK:'modpack'}});
let views=[];const sync=new Sync();let finished=0;Object.assign(sync,{registry:{listAll:()=>views},ledgerBegun_:new Set(),mcTerminalRecorded_:new Set(),beginActivity_(){},recordModpackActivity_(){finished++;},applyModpackResult_(){},scanVersions(){}});
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

fs.writeFileSync(path.join(fixture,'results.json'),JSON.stringify({checkedAt:new Date().toISOString(),total:cases.length,cases},null,2));
console.log('Modpack regression passed: '+cases.length+' groups; evidence '+fixture);

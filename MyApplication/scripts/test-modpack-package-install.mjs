/**
 * 包装发现、实例选择、内容过滤与原安装事务的组合回归。输入是真实ZIP，
 * 只替换OHOS解压回调、实际游戏构建和网络；中央目录、生产安全扫描、计划、
 * Task/Session/Installer/收据与真实文件IO都执行产品代码，成功回收自有夹具。
 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {loader, fileIo, productionPathPolicy} from './mod-install-test-runtime.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';
import {resolveWorkspacePath} from './lib/workspace-paths.mjs';
const parent=process.env.AMCL_TEST_OUTPUT_DIR||resolveWorkspacePath('run','modpack-package-install');
fs.mkdirSync(parent,{recursive:true});const report=fs.mkdtempSync(path.join(parent,'run-'));
const scope=createHostTestScope('fixtures-',{parent:report,automatic:false});
const fixture=scope.directory.replaceAll('\\','/'), helper=path.join(import.meta.dirname,'fixtures/modpack-install-fixtures.py');
const python=process.env.AMCL_PYTHON||'python', cases=[];let success=false;
try{
execFileSync(python,[helper,'generate',fixture],{stdio:'pipe'});
const digest=p=>crypto.createHash('sha1').update(fs.readFileSync(p)).digest('hex');
const io={...fileIo,copyFile:fs.promises.copyFile,mkdirSync:(p,r=false)=>fs.mkdirSync(p,{recursive:r}),
 lstatSync(p){const s=fs.lstatSync(p);return {...s,mtime:s.mtimeMs,isFile:()=>s.isFile(),isDirectory:()=>s.isDirectory(),isSymbolicLink:()=>s.isSymbolicLink()};},
 fsyncSync(fd){if(!fs.fstatSync(fd).isDirectory())fs.fsyncSync(fd);}};
class ActivityLogger{info(){}warn(){}}
const common={ActivityLogger,LOG_DOMAIN_DOWNLOAD:0,LogTags:{MOD_FORGE_INSTALLER:'Archive'},
 ensureDirSync:p=>fs.mkdirSync(p,{recursive:true}),removeDirRecursive(p){assert.ok(path.resolve(p).startsWith(path.resolve(fixture)+path.sep));fs.rmSync(p,{recursive:true,force:true});}};
const baseLoad=loader({'@kit.CoreFileKit':{fileIo:io},commons:common});
const U=baseLoad('feature_core/src/main/ets/download/UnifiedDownloadTask.ets'), lease=baseLoad('feature_core/src/main/ets/version/VersionInstallLease.ets');
const identity=baseLoad('feature_core/src/main/ets/export/ExportVersionResolver.ets');
let builds=0,downloads=0;const starts=[];
class Base{constructor(game,loader,version,name,mc){Object.assign(this,{game,loader,version,name,mc,view:{}});}
 async start(){builds++;starts.push({game:this.game,loader:this.loader,version:this.version});const dir=this.mc+'/versions/'+this.name;fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(dir+'/'+this.name+'.json','{"runtime":"OHOS"}');fs.writeFileSync(dir+'/'+this.name+'.jar','NEW');}
 purgeNativeOwner(){return true;}async cancel(){}}
const dm={purgeTask:()=>true,async createAndWait(spec,progress){downloads++;progress?.({taskId:downloads,filesDone:0,filesTotal:spec.files.length,bytesDone:0,bytesTotal:6,speedBps:0,etaSeconds:0});
 for(const item of spec.files){fs.mkdirSync(path.dirname(item.localPath),{recursive:true});fs.writeFileSync(item.localPath,'REMOTE');}}};
const archiveLoad=loader({'@kit.CoreFileKit':{fileIo:io},commons:common,'./MavenUtils':productionPathPolicy(),
 '../download/DownloadManager':{DownloadManager:{instance:()=>dm}},'../download/SourceProber':{},
 '@kit.BasicServicesKit':{zlib:{decompressFile(zip,dest,callback){try{execFileSync(python,[helper,'extract',zip,dest],{stdio:'pipe'});callback();}catch(e){callback({message:e.message});}}}}});
const archive=archiveLoad('feature_core/src/main/ets/modloader/ForgeInstallerUtils.ets');
const core={...productionPathPolicy(),...U,...lease,...identity,McVersionTask:Base,isSupportedInstallerLoader:()=>true,
 ModLoaderType:{FABRIC:'fabric',FORGE:'forge',NEOFORGE:'neoforge',QUILT:'quilt'},
 DownloadTaskRegistry:{instance:()=>({notifyChange(){}})},DownloadManager:{instance:()=>dm},decompressFile:archive.decompressFile,
 computeFileSha1:async p=>digest(p),computeFileSha512:async p=>crypto.createHash('sha512').update(fs.readFileSync(p)).digest('hex')};
const load=loader({'@kit.CoreFileKit':{fileIo:io},commons:common,feature_core:core});
const {ModpackInstallTask:Task}=load('mods/src/main/ets/ModpackInstallTask.ets');
const Sessions=load('mods/src/main/ets/ModpackInstallSession.ets');
const make=(name,id=name)=>({title:name,sessionId:id,archivePath:fixture+'/'+name+'.zip',mcDir:fixture+'/run-'+id+'/mc',filesDir:fixture+'/run-'+id+'/files',existingVersions:[],requireConfirmation:false,
 resolveCfFile:async()=>({filename:'remote.jar',targetDirectory:'mods',size:6,sha1:crypto.createHash('sha1').update('REMOTE').digest('hex'),urls:['https://example.invalid/remote.jar']})});
const passed=name=>{cases.push(name);console.log('PASS '+name);};
for(const name of ['standard','pcl','hmcl-main','deep','full','full-wrapped','overrides-dot','overrides-slash','minecraft-layer','mcbbs']){
 const before=builds,req=make(name),task=new Task(req);await task.start();assert.equal(task.view.state,'done',name);assert.equal(task.getResult().missing.length,0);
 const dir=req.mcDir+'/versions/'+task.getResult().versionName;assert.equal(fs.readFileSync(dir+'/mods/content.jar','utf8'),'MOD');
 assert.equal(fs.readFileSync(dir+'/config/pack.cfg','utf8'),'CONFIG');assert.equal(builds-before,1);
 assert.equal(fs.existsSync(dir+'/PCL.exe'),false);assert.equal(fs.existsSync(dir+'/user_jvm_args.txt'),false);
 assert.equal(fs.readFileSync(dir+'/'+task.getResult().versionName+'.jar','utf8'),'NEW');passed(name+' installs selected content into a new OHOS instance');
}
for(const name of ['full-multiple','data-choice']){
 const req=make(name),task=new Task(req),before=builds;await task.start();assert.equal(task.view.state,'paused');assert.equal(task.requiresPackageSelection(),true);assert.equal(builds,before);
 const candidate=task.packageCandidates().find(c=>c.versionId==='Pack'&&(name==='full-multiple'||c.gameDir==='versions/Pack'));assert.ok(candidate);
 task.selectPackage(candidate.id);assert.equal(task.packageSelected(candidate.id),true);task.confirmSelection();
 // 确认选择的来源先持久保存，重建Task模拟进程退出后继续同一候选。
 const restored=new Task(req);await restored.start();assert.equal(restored.view.state,'done');assert.equal(restored.getSession().selectedPackageId,candidate.id);
 const dir=req.mcDir+'/versions/'+restored.getResult().versionName;assert.ok(fs.existsSync(dir+'/mods/content.jar'));assert.equal(fs.existsSync(dir+'/mods/shared.jar'),false);assert.equal(fs.existsSync(dir+'/mods/other.jar'),false);
 passed(name+' pauses without building, persists the explicit payload and resumes the chosen data root');
}
{const req=make('multiple-archives'),task=new Task(req),before=builds;await task.start();assert.equal(task.view.state,'paused');
 assert.ok(task.packageCandidates().every(c=>c.kind==='archive'));assert.equal(builds,before);
 assert.equal(fs.existsSync(req.filesDir+'/modpack-work/'+req.sessionId+'/payloads'),false);
 const chosen=task.packageCandidates()[1];task.selectPackage(chosen.id);task.confirmSelection();
 const restored=new Task(req);await restored.start();assert.equal(restored.view.state,'done');
 assert.ok(fs.existsSync(req.mcDir+'/versions/'+restored.getResult().versionName+'/mods/content.jar'));
 assert.equal(fs.existsSync(req.filesDir+'/modpack-work/'+req.sessionId+'/payloads'),false);
 passed('multiple archives wait without expanding, restore the selected inner archive and reclaim committed payloads');}
{const req=make('multiple-archives','archive-tamper'),task=new Task(req);await task.start();const chosen=task.packageCandidates()[0];
 const inner=req.filesDir+'/modpack-work/'+req.sessionId+'/'+chosen.archivePath;fs.appendFileSync(inner,'changed');
 task.selectPackage(chosen.id);task.confirmSelection();await assert.rejects(new Task(req).start(),/变化/);
 passed('a deferred inner archive cannot be substituted while waiting for user selection');}
{const req=make('bad-and-good'),task=new Task(req);await task.start();task.selectPackage(task.packageCandidates().find(c=>c.archivePath.endsWith('/Bad.mrpack')).id);
 task.confirmSelection();await assert.rejects(task.start(),/minecraft/);assert.equal(task.packageCandidates().length,2);
 const cold=new Task(req);await assert.rejects(cold.start(),/minecraft/);assert.ok(cold.canChooseOtherPackage());cold.chooseOtherPackage();
 cold.selectPackage(cold.packageCandidates().find(c=>c.archivePath.endsWith('/Good.mrpack')).id);cold.confirmSelection();await cold.start();
 assert.equal(cold.view.state,'done');passed('a malformed selected inner package retains durable parent choices and can switch to a good package after restart');}
for(const [name,pattern]of [['ambiguous-layer',/不能猜选/],['missing-layer',/覆盖目录不存在/]]){
 const task=new Task(make(name));await assert.rejects(task.start(),pattern);assert.equal(task.view.state,'error');passed(name+' reports a structural conflict instead of silently dropping data');
}
{const task=new Task(make('empty-overrides'));await task.start();assert.equal(task.view.state,'done');passed('a standard pack without extra overrides remains valid');}
{const before=downloads,task=new Task(make('duplicate-cf'));await task.start();assert.equal(task.view.state,'done');assert.equal(task.getSession().plan.files.length,1);assert.equal(downloads-before,1);passed('equivalent CurseForge rows merge before download while required intent wins');}
{const task=new Task(make('multimc'));await task.start();assert.equal(task.view.state,'done');passed('MultiMC content joins the same instance transaction');}
{const req=make('full-multiple','binding'),task=new Task(req);await task.start();task.selectPackage(task.packageCandidates()[0].id);task.confirmSelection();await task.start();
 const session=task.getSession();session.packageRoot='extracted';Sessions.saveModpackSession(req.filesDir,session);assert.throws(()=>Sessions.loadModpackSession(req.filesDir,req.sessionId),/载荷不一致/);passed('recovery rejects a selected payload whose persisted root is rebound');}
success=true;
}finally{fs.writeFileSync(path.join(report,'summary.json'),JSON.stringify({checkedAt:new Date().toISOString(),success,total:cases.length,cases},null,2));await scope.close({success});}

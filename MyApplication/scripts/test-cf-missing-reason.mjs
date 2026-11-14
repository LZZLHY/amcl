/**
 * 精确CF元数据错误→真实Repository/工厂→生产resolve/download消费者回归。
 * HTTP只在SDK端口注入已观察的404/对照200；解析、身份、路径和missing更新运行生产代码。
 * 仅使用独占小文件，不生成ZIP、不请求网络，不授予手机或整合包安装资格。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileIo,mocks,productionPathPolicy,root} from './mod-install-test-runtime.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {assertExternalOutputPath,resolveWorkspacePath} from './lib/workspace-paths.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';

const intent=process.env.AMCL_TEST_OUTPUT_DIR||resolveWorkspacePath('run','cf-missing-reason');
if(!path.isAbsolute(intent))throw Error('CF missing test output parent must be absolute');
const parent=assertExternalOutputPath(intent);fs.mkdirSync(parent,{recursive:true});
const report=fs.mkdtempSync(path.join(parent,'run-')),scope=createHostTestScope('fixtures-',{parent:report,automatic:false});
const fixture=scope.directory.replaceAll('\\','/'),cases=[];
const refIndex=process.argv.indexOf('--source-ref'),sourceRef=refIndex<0?undefined:process.argv[refIndex+1];
if(refIndex>=0&&!sourceRef)throw Error('--source-ref requires an exact Git identity');
const installerPath='mods/src/main/ets/ModpackInstaller.ets';
const old=sourceRef?{[installerPath]:execFileSync('git',['-C',root,'show',sourceRef+':'+installerPath],{encoding:'utf8',maxBuffer:1024*1024})}:{};
let failure,mode='404',serial=0,httpCalls=[],downloadSpecs=[];
const body=Buffer.from('HOST-CF-CONTROL'),hash=b=>crypto.createHash('sha1').update(b).digest('hex');
function owned(p){assert.ok(path.resolve(p).startsWith(path.resolve(fixture)+path.sep));}
const handles=new Set();
const io={...fileIo,copyFile:fs.promises.copyFile,mkdirSync:(p,r=false)=>{owned(p);fs.mkdirSync(p,{recursive:r});},
 openSync(p,flags){owned(p);const f=fileIo.openSync(p,flags);handles.add(f.fd);return f;},
 closeSync(file){const fd=typeof file==='number'?file:file.fd;assert.ok(handles.delete(fd));return fileIo.closeSync(file);},
 fsyncSync(fd){assert.ok(handles.has(fd));if(!fs.fstatSync(fd).isDirectory())fs.fsyncSync(fd);}};
class ActivityLogger{info(){}warn(){}}
const common={...mocks.commons,APP_NAME:'AMCL',APP_VERSION:'host',ActivityLogger,LOG_DOMAIN_DOWNLOAD:0,
 ensureDirSync:p=>{owned(p);fs.mkdirSync(p,{recursive:true});},removeDirRecursive(){throw Error('Cleanup is only owned by test lifecycle');}};
/** 真实Repository消费状态码，测试不直接替它抛解析异常或指定missing文本。 */
const dm={purgeTask:()=>true,isCaBundleInitialized:()=>true,cancel(){},
 async fetchTextEx(url){httpCalls.push(url);
  if(mode==='404')return{statusCode:404,body:'{"error":"Not Found","code":404,"detail":"File not found: File with fileId 6706114 not found"}',headers:{}};
  const data={id:9000001,modId:42,displayName:'Independent null URL control',fileName:mode==='unsafe'?'../escape.jar':'control.jar',downloadUrl:null,
   fileLength:body.length,hashes:[{algo:1,value:hash(body)}],gameVersions:['1.7.10','Forge'],dependencies:[],releaseType:1,fileDate:'2026-10-31T00:00:00Z',isServerPack:false,isAvailable:true};
  if(mode==='identity')data.modId=43;
  return{statusCode:200,body:JSON.stringify({data}),headers:{}};},
 async createAndWait(spec,onProgress){downloadSpecs.push(spec);onProgress?.({taskId:1});for(const f of spec.files){owned(f.localPath);fs.mkdirSync(path.dirname(f.localPath),{recursive:true});fs.writeFileSync(f.localPath,body);}return{taskId:1};}};
const core={...productionPathPolicy(),DownloadManager:{instance:()=>dm},getMetadataCacheStore:()=>({get(){throw Error('disabled cache must not be consulted');}}),
 computeFileSha1:async p=>hash(fs.readFileSync(p))};
// 组合候选的会话模块导入恢复摘要实现，沿用公共宿主平台口提供 Crypto Kit。
const deps={'@kit.CoreFileKit':{fileIo:io},'@kit.ArkTS':mocks['@kit.ArkTS'],
 '@kit.CryptoArchitectureKit':mocks['@kit.CryptoArchitectureKit'],
 '@kit.NetworkKit':{http:{createHttp(){throw Error('No direct HTTP client expected');}}},
 './ModSourceProber':{isMcimAvailable:()=>true},commons:common,feature_core:core};
const base=makePureEtsLoader(deps);deps.commons={...common,...base('commons/src/main/ets/utils/InstancePaths.ets')};
core.ExportVersionResolver=base('feature_core/src/main/ets/export/ExportVersionResolver.ets').ExportVersionResolver;
const load=makePureEtsLoader(deps,old),M=load('mods/src/main/ets/ModpackManifest.ets');
const Factory=load('mods/src/main/ets/ModpackSource.ets'),Sessions=load('mods/src/main/ets/ModpackInstallSession.ets');
const Installer=load(installerPath).ModpackInstaller;

/** 用生产CF清单解析器建计划，不伪填路径或从相邻fileId选择替代版本。 */
function setup(projectId=32274,fileId=6706114){
 const id='cf'+(++serial),dir=fixture+'/'+id,filesDir=dir+'/files',mcDir=dir+'/mc',versionDir=mcDir+'/versions/Owner';fs.mkdirSync(versionDir,{recursive:true});
 fs.writeFileSync(versionDir+'/.amcl-modpack-pending.json',JSON.stringify({id}));
 const plan=M.parseCurseForgeManifest(JSON.stringify({manifestType:'minecraftModpack',manifestVersion:1,name:'host exact CF',version:'control',
  minecraft:{version:'1.7.10',modLoaders:[{id:'forge-10.13.4.1614',primary:true}]},files:[{projectID:projectId,fileID:fileId,required:true}],overrides:'overrides'})).plan;
 const session={schemaVersion:1,id,mcDir,versionName:'Owner',plan,warnings:[],missing:[],selectedOptional:[],confirmed:true,baseReady:true,overridesApplied:false,complete:false,
  installedFiles:[],overrideFiles:[],projectId:'',sourceVersionId:'',archiveSha1:'a'.repeat(40),archiveSize:0,iconUrl:'',createdAt:1};
 return{session,filesDir,versionDir,installer:new Installer(),req:{filesDir,mcDir,resolveCfFile:Factory.createModpackFileResolver(false,true)}};
}
async function resolve(s){await s.installer.resolveCfFiles_(s.req,s.session,false);}
async function consume(s){await s.installer.downloadFiles_(s.req,s.session,s.versionDir);assert.equal(handles.size,0);}
function passed(name){cases.push(name);console.log('PASS '+name);}

try{
 if(!process.argv.includes('--null-url-only')){
  mode='404';let s=setup();const before=downloadSpecs.length;await resolve(s);
  assert.match(s.session.missing[0].reason,/HTTP 404/);assert.equal(s.session.plan.files[0].path,'');assert.ok(httpCalls.every(u=>u.includes('/mods/32274/files/6706114')));
  const precise=s.session.missing[0].reason;await consume(s);
  // 真实旧实现先通过Repository404/空path等断言，再在这条业务原因保留断言失败。
  assert.equal(s.session.missing[0].reason,precise,'downstream must preserve the actual exact-file failure');
  assert.equal(s.session.missing[0].required,true);assert.equal(s.session.missing[0].cfProjectId,32274);assert.equal(s.session.missing[0].cfFileId,6706114);
  assert.equal(downloadSpecs.length,before);assert.equal(s.session.missing[0].url,'https://www.curseforge.com/projects/32274/files/6706114');
  Sessions.saveModpackSession(s.filesDir,s.session);const cold=Sessions.loadModpackSession(s.filesDir,s.session.id);assert.equal(cold.missing[0].reason,precise);assert.equal(cold.missing[0].required,true);
  passed('actual Repository404 -> resolver -> empty path consumer preserves exact required missing reason and cold session');
  s.session.missing[0].required=false;s.session.missing[0].url='https://stale.invalid/old';s.session.missing[0].name='stale';await consume(s);
  assert.equal(s.session.missing[0].required,true);assert.notEqual(s.session.missing[0].name,'stale');assert.match(s.session.missing[0].url,/32274\/files\/6706114$/);passed('only reason is retained; current required/name/url are rebuilt');
  for(const variant of ['unsafe-nonempty','non-cf','other-id','empty-reason','whitespace-reason']){
   const x=setup(),file=x.session.plan.files[0];x.session.missing=[{name:'old',path:'',reason:'HTTP 404',cfProjectId:32274,cfFileId:6706114,required:false}];
   if(variant==='unsafe-nonempty')file.path='../escape.jar';
   if(variant==='non-cf'){delete file.cfProjectId;delete file.cfFileId;}
   if(variant==='other-id')x.session.missing[0].cfFileId=1;
   if(variant==='empty-reason')x.session.missing[0].reason='';
   if(variant==='whitespace-reason')x.session.missing[0].reason='  ';
   await consume(x);assert.equal(x.session.missing.at(-1).reason,'未解析出安全的文件路径');assert.equal(x.session.installedFiles.length,0);passed(variant+' retains generic safe-path rejection');
  }
  for(const m of ['unsafe','identity']){
   mode=m;const x=setup(42,9000001);await resolve(x);const reason=x.session.missing[0].reason;assert.match(reason,m==='unsafe'?/文件名不安全/:/身份不符/);await consume(x);
   assert.equal(x.session.missing[0].reason,reason);assert.equal(x.session.plan.files[0].path,'');passed('actual '+m+' metadata failure is neither guessed nor bypassed');
  }
 }
 mode='null';const x=setup(42,9000001);await resolve(x);assert.equal(x.session.missing.length,0);const file=x.session.plan.files[0];
 assert.equal(file.path,'mods/control.jar');assert.ok(file.urls.some(u=>u==='https://edge.forgecdn.net/files/9000/1/control.jar'));assert.ok(file.urls.every(u=>!u.includes('mcimirror')));
 await consume(x);assert.equal(x.session.missing.length,0);assert.equal(x.session.installedFiles.length,1);assert.equal(hash(fs.readFileSync(x.versionDir+'/mods/control.jar')),hash(body));
 passed('verified exact metadata with null downloadUrl keeps safe official CDN construction and real file activation');
}catch(error){failure=error;throw error;}
finally{
 assert.equal(handles.size,0);fs.writeFileSync(path.join(report,'summary.json'),JSON.stringify({at:new Date().toISOString(),source:sourceRef??'current independent worktree',state:failure?'FAIL':'PASS',cases,httpCalls,downloadTasks:downloadSpecs.length,
  scope:'Production CF parser/factory/Repository/Installer/Session; HTTP and directoryfsync are host boundaries, no network/pack/device qualification',...(failure?{error:String(failure)}:{})},null,2)+'\n');
 await scope.close({success:!failure});console.log('RESULT '+path.join(report,'summary.json'));
}

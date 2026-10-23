/** 执行真实ArkTS清单/lease/cache实现，替身仅提供SDK HTTP、时钟和沙箱IO边界。 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),require=createRequire(import.meta.url);
const ts=require(path.join(process.env.DEVECO_SDK_HOME,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file,deps,globals={}) {const js=ts.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
  const exports={};vm.runInNewContext(js,{exports,require:name=>{if(!(name in deps))throw new Error('Unmocked '+name);return deps[name];},Object,Number,RegExp,JSON,Date,Array,Map,Uint8Array,ArrayBuffer,Promise,console,setTimeout,clearTimeout,...globals});return exports;}
const logger={info(){},warn(){},error(){}},types=load('update/src/main/ets/ChangelogTypes.ets',{});
const resolver=load('update/src/main/ets/GitHubUpdateAssetResolver.ets',{'@kit.NetworkKit':{},'./AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets',{})});
const sha='a'.repeat(64),tag='v2.0.0',name='amcl-v2.0.0-sideload-unsigned.hap';
const asset={tag,name,url:'https://github.com/LZZLHY/amcl/releases/download/'+tag+'/'+name,sha256:sha,sizeBytes:100,versionCode:2,versionName:'2.0.0',product:'sideload',legacyUniversal:false,
  websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+sha+'/'+name,mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/'+tag+'/'+name}]};
const manifest={versionCode:2,versionName:'2.0.0',tag,notes:'2.0.0\n- 修复：有效摘要',schema:1,notesEntries:[null,{type:'future',text:'正常条目'}],delivery:{schema:1,ready:true,assets:[asset]}};
const calls=[];
const checker=load('update/src/main/ets/UpdateChecker.ets',{commons:{UPDATE_MANIFEST_URLS:[],AppLogger:logger,formatError:String,DistributionPolicy:{allowSideloadUpdates:()=>true},DiagnosticPolicy:{hasTestHooks:()=>false}},
  './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets',{}),'./GitHubUpdateAssetResolver':resolver,'./ChangelogTypes':types,'@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelfSync:()=>({versionCode:1})}},
  feature_core:{DownloadManager:{instance:()=>({fetchText:async(url,mirrors,timeout,limit)=>{calls.push({url,mirrors,limit});return url.includes('bad')?'<html>not a manifest</html>':JSON.stringify(manifest);}})}}}).UpdateChecker;
assert.equal(checker.parseManifest(JSON.stringify(manifest)).notesEntries[0].type,'notice');
assert.equal(checker.parseManifest(JSON.stringify({...manifest,versionCode:2.5})),null);
const checked=await checker.checkForUpdate(['https://official.test/bad','https://official.test/good']);
assert.equal(checked.hasUpdate,true);assert.equal(calls.length,2);assert.equal(calls[0].limit,8191);
console.log('PASS actual manifest core/display isolation and invalid 200 source fallback');

let mono=0,miawaCalls=0,releaseMiawa;
const secondReady=new Promise(resolve=>releaseMiawa=resolve);
const base64={decodeSync:value=>new Uint8Array(Buffer.from(value,'base64')),encodeToStringSync:value=>Buffer.from(value).toString('base64')};
const providers=load('entry/src/main/ets/sideload/SideloadMirrorProviders.ets',{'@kit.NetworkKit':{},'@kit.ArkTS':{util:{Base64Helper:class{decodeSync(value){return base64.decodeSync(value);}encodeToStringSync(value){return base64.encodeToStringSync(value);}}}},'libentry.so':{default:{downloadSteadyTime:()=>mono,solveSideloadPow:async(modulus,base,count)=>{assert.equal(modulus.slice(-2),'11');assert.equal(base.slice(-2),'03');assert.equal(count,3);return '0'.repeat(766)+'10';}}}});
const sources=load('entry/src/main/ets/sideload/SideloadDownloadSources.ets',{'./SideloadMirrorProviders':providers,'./SideloadMirrorTypes':{}}).SideloadDownloadSources;
// 真实宁泽解析仍执行；只替换HTTP响应，包含坏长度/坏URL/缺token的负向输入。
let catalogs=0,authorizations=0;
sources.json=async(url)=>{if(url.includes('launchers')){catalogs++;return{data:[{tag_name:tag,assets:[{name,size:100,sha256:sha}]}]};}authorizations++;return{data:{download_token:'m'.repeat(43),download_url:'/download/amcl/'+tag+'/'+name}};};
const leased=await sources.miawa(asset);assert.equal(leased.authorizedPolicy.singleUse,true);assert.equal(leased.authorizedPolicy.maxHttpAttempts,1);
assert.equal(leased.assetKey,sources.identity(asset));
mono=301000;await sources.transfer(asset,leased,()=>true,async renewed=>{assert.ok(renewed.leaseGeneration>leased.leaseGeneration);});
assert.equal(catalogs,1);assert.equal(authorizations,2);mono=0;
const integer=Buffer.alloc(384);integer[383]=3;const encoded=integer.toString('base64url');integer[383]=17;const modulus=integer.toString('base64url');
let auth={download_token:'f'.repeat(43),download_url:'https://node.example.test/asset',range_concurrency_limit:2,max_bytes:100,expires_at:new Date(Date.now()+300000).toISOString()};
sources.json=async url=>url.endsWith('/assets')?{data:{assets:[{asset_id:'asset:1',available:true,version:tag,file_name:name,size_bytes:100,digest_sha256:'sha256:'+sha}]}}:
  url.endsWith('/challenges')?{data:{asset_id:'asset:1',challenge_id:'challenge:1',algorithm:'rsa-repeated-squaring-v1',encoding:'base64url-uint-be-384',iterations:3,modulus,base:encoded}}:{data:auth};
const fy=await sources.fyhub(asset);assert.equal(fy.authorizedPolicy.maxBytes,100);assert.equal(fy.authorizedPolicy.singleUse,false);
for(const changed of [{max_bytes:99},{range_concurrency_limit:0},{download_token:'bad'},{download_url:'http://127.0.0.1/file'},{expires_at:'2000-01-01T00:00:00Z'}]){
  const old=auth;auth={...old,...changed};await assert.rejects(sources.fyhub(asset));auth=old;
}
await assert.rejects(sources.transfer({...asset,product:'desktop'},leased,()=>true,async()=>{}),/身份不匹配/);
sources.json=async()=>({data:{download_token:'bad',download_url:'https://evil.test/file'}});await assert.rejects(sources.miawa(asset));
const originalMiawa=sources.miawa;
sources.miawa=async()=>{miawaCalls++;if(miawaCalls===1)await secondReady;return{label:'宁泽镜像',provider:'miawa',token:'m'.repeat(43),url:'https://miawa.cn/file',leaseDeadlineMs:mono+295000,
  assetKey:sources.identity(asset),leaseGeneration:miawaCalls,
  authorizedPolicy:{singleUse:true,maxHttpAttempts:1,validForNewRequestMs:295000,maxBytes:100}};};
sources.fyhub=async()=>({label:'枫源镜像',url:'https://fyhub.cn/file'});
const order=[];await sources.download(asset,()=>true,async source=>{order.push(source.label);if(source.label==='枫源镜像'){releaseMiawa();await Promise.resolve();mono=301000;throw new Error('first source failed');}});
assert.equal(miawaCalls,2);assert.equal(order.join(','),'枫源镜像,宁泽镜像');
let transfers=0;await sources.transfer(asset,await sources.miawa(asset),()=>true,async()=>{transfers++;if(transfers===1){const error=new Error('consumed');error.detail={needsNewLease:true};throw error;}});
assert.equal(transfers,2);assert.equal(miawaCalls,4);
let busyTransfers=0;const beforeBusy=miawaCalls;
await assert.rejects(sources.transfer(asset,await sources.miawa(asset),()=>true,async()=>{busyTransfers++;const error=new Error('busy node');error.detail={needsNewLease:true,httpStatus:503,retryAfterMs:60000};throw error;}),/busy/);
assert.equal(busyTransfers,1);assert.equal(miawaCalls,beforeBusy+1);
await assert.rejects(sources.transfer(asset,await sources.miawa(asset),()=>true,async()=>{throw new Error('must not request cooled node');}),/退避/);
sources.miawa=originalMiawa;
console.log('PASS actual lease selection refreshes expired standby and permits bounded consumed-lease renewal');

const files=new Map(),descriptors=new Map();let nextFd=1,failWrite=false;const fetches=[];
const release={versionName:'2.0.0',versionCode:2,zh:{entries:[null,{type:'fixed',text:'正常中文'}]},en:{entries:[{type:'added',text:'English fallback'}]}};
const body=JSON.stringify({schema:1,releases:[null,release]});
const kit={fileIo:{OpenMode:{READ_ONLY:0},accessSync:name=>files.has(name),statSync:name=>({size:Buffer.byteLength(files.get(name)),isFile:()=>true}),mkdirSync(){},
  openSync:name=>{const fd=nextFd++;descriptors.set(fd,{bytes:Buffer.from(files.get(name)),position:0});return{fd};},
  readSync:(fd,target)=>{const file=descriptors.get(fd),n=Math.min(7,target.byteLength,file.bytes.length-file.position);new Uint8Array(target).set(file.bytes.subarray(file.position,file.position+n));file.position+=n;return n;},closeSync:file=>descriptors.delete(file.fd)}};
function changelogFixture() {return load('update/src/main/ets/ChangelogService.ets',{'@kit.AbilityKit':{},'@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}},'@kit.CoreFileKit':kit,
  commons:{UPDATE_MANIFEST_URLS:[],AppLogger:logger,LOG_DOMAIN_DOWNLOAD:1,DistributionPolicy:{allowPublisherServices:()=>true},CHANGELOG_JSON_URLS:['https://official.test/api','https://official.test/static'],CHANGELOG_RAWFILE:'snapshot',
    AtomicFileWriter:{write:(name,text)=>{if(failWrite)throw new Error('durability unknown');files.set(name,text);}}},'./ChangelogTypes':types,
  feature_core:{DownloadManager:{instance:()=>({fetchTextEx:async(url,mirrors,timeout,headers)=>{fetches.push({url,headers});return url.endsWith('/api')?{statusCode:200,body:'null',headers:{etag:'wrong'}}:{statusCode:200,body,headers:{etag:'foreign'}};}})}}},
  {AppStorage:{get:()=>({filesDir:'/private',resourceManager:{getRawFileContent:async()=>new TextEncoder().encode(body)}})}});}
const log=changelogFixture();assert.equal(log.parseChangelog(body,'test').releases[0].entries.length,1);
assert.equal(log.parseChangelog(JSON.stringify({schema:1,releases:[{...release,zh:{entries:[null]}}]}),'test').releases[0].entries[0].text,'English fallback');
await log.ChangelogService.load();for(let i=0;i<20;i++)await Promise.resolve();
const record=JSON.parse(files.get('/private/changelog/cache-v2.json'));assert.equal(record.etag,'');assert.equal(record.body,body);assert.equal(fetches.length,2);
files.set('/private/changelog/cache-v2.json','broken');files.set('/private/changelog/changelog.json',body);files.set('/private/changelog/changelog.etag','stale');fetches.length=0;failWrite=true;
const again=changelogFixture();await again.ChangelogService.load();for(let i=0;i<20;i++)await Promise.resolve();
assert.equal(fetches[0].headers['If-None-Match'],undefined);assert.equal(descriptors.size,0);
console.log('PASS actual changelog null/locale isolation, short reads, atomic body/ETag binding, fallback and failed-cache condition-header exclusion');
// 正常构建沿此既有门禁执行真实来源代次/首页排队回归，避免新测试只被人工跑过一次。
await import('./test-sideload-prompt-source.mjs');
// 当前推荐头与静态快照之间的优先级属于同一交付门禁；覆盖真实 fetchText 的
// HTTP 状态透传，防止合法旧快照漏更或明确空推荐被历史静态头重新激活。
await import('./test-app-update-source-freshness.mjs');

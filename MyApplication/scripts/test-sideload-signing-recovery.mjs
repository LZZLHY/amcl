/** 真实恢复编排：随包模板、保险库私钥、空证书列表和取消。密码学由Java真实向量验证。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
const root=path.resolve(import.meta.dirname,'..'),appId='com.amcl.launcher_fixture';
function compile(name,modules){
 const file=path.join(root,'entry/src/main/ets/sideload',name+'.ets'),exports={};
 const code=compiler.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
 vm.runInNewContext(code,{exports,require:key=>{assert(key in modules,'unexpected '+key);return modules[key];},console,Uint8Array,ArrayBuffer});return exports;
}
const errors=compile('SigningPreparationError',{});
function fixture({certificates=true,invalidSource=false,wrongTeam=false,cancelAfterNative=false,nativeFailure=false,cached=false,reuseFailure=false}={}){
 const files=new Map(),directories=new Set();let nativeCalls=0,active=true,materialized=0,requests=0;
 const catalog={schema:1,templates:[{provider:'fixture',appIdSha256:crypto.createHash('sha256').update(appId).digest('hex'),privatePem:'fixture-only',csr:'fixture-only'}]};
 const modules={
  '@kit.AbilityKit':{},'@kit.NetworkKit':{http:{RequestMethod:{POST:'POST'}}},
  '@kit.ArkTS':{util:{TextDecoder:class{decodeWithStream(b){return new TextDecoder().decode(b);}},
   Base64Helper:class{encodeToStringSync(b){return Buffer.from(b).toString('base64');}},generateRandomUUID:()=> 'a'.repeat(32)}},
  '@kit.CoreFileKit':{fileIo:{accessSync:p=>files.has(p),readTextSync:p=>files.get(p),unlinkSync:p=>files.delete(p),
   listFileSync:p=>[...files.keys()].filter(name=>name.startsWith(p+'/')),rmdirSync:p=>{assert(![...files.keys()].some(name=>name.startsWith(p+'/')));directories.delete(p);}}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd(){const h=crypto.createHash('sha256');return{async update(v){h.update(v.data);},async digest(){return{data:new Uint8Array(h.digest())};}};}}},
  'commons':{stringToUtf8:s=>new TextEncoder().encode(s)},'./SigningPreparationError':errors,
  './SideloadFiles':{SideloadFiles:{ensureDirectory:p=>directories.add(p),write:(p,v)=>files.set(p,v)}},
  'libentry.so':{default:{async runJavaProcessor(_f,_j,_m,_cp,_main,args){nativeCalls++;assert.equal(args[0],'--restore-original-key');
   const input=JSON.parse(files.get(args[1]));assert.equal(input.defaultTeamId,'fixture-team');assert.equal(input.certificates.length,certificates&&!reuseFailure?1:0);
   if(certificates&&!reuseFailure)assert.equal(input.certificates[0].teamId,'fixture-team');
   assert.equal(input.provider,cached?'cached-key':'bundled-template');
   assert.equal(input.allowProfileContinuation,cached);assert.equal(input.fingerprint,undefined);
   if(cached)assert(files.has(input.materialDirectory+'/material.p12'));
   const output=nativeFailure?{error:'KEY_RECOVERY_FAILED'}:{teamId:wrongTeam?'foreign-team':'fixture-team',originalAppId:input.appId,
    p12Base64:'fixture-p12',csr:'fixture-csr',keyAlias:'fixture',keyPassword:'fixture-only',storePassword:'fixture-only'};
   files.set(args[2],JSON.stringify(output));if(cancelAfterNative)active=false;return 0;
  }}},
  './DeveloperAuthSession':{DeveloperAuthSession:{isExpired:()=>false}},
 };
 const {OriginalSigningRecovery:Recovery}=compile('OriginalSigningRecovery',modules);
 const context={filesDir:'/sandbox',resourceManager:{getRawFileContentSync(name){assert(!cached,'cached key needs no public template');assert.equal(name,'sideload/public-signing-templates.json');return new TextEncoder().encode(invalidSource?'bad':JSON.stringify(catalog));}}};
 const auth={teamIds:()=>['fixture-team'],preferredTeamId:()=> 'fixture-team',async request(url){requests++;assert(url.endsWith('/cert/list'));if(reuseFailure)throw Error('optional reuse unavailable');return{certList:certificates?[{id:'fixture-id',certObjectId:'fixture-object',teamId:'untrusted-row-team'}]:[]};}};
 const vault={available:()=>true,async materialize(dir){materialized++;files.set(dir+'/material.p12','fixture-only');},clearTemporary(dir){files.delete(dir+'/material.p12');}};
 const restore=id=>Recovery.restore(context,auth,cached?vault:undefined,'com.amcl.launcher',id,'original-random-identifier',
  '/signer','/runner','/jdk',async(team,object)=>{assert.equal(team,'fixture-team');assert.equal(object,'fixture-object');return new Uint8Array([1,2,3]);},
  ()=>{if(!active)throw Error('cancelled fixture');},cached);
 return{restore,files,directories,nativeCalls:()=>nativeCalls,materialized:()=>materialized,requests:()=>requests};
}
{
 const f=fixture();assert.equal(await f.restore('unknown-key'),undefined);assert.equal(f.nativeCalls(),0);assert.equal(f.requests(),0);
}
for(const options of [{},{certificates:false},{cached:true},{cached:true,certificates:false},{reuseFailure:true}]){
 const f=fixture(options),draft=await f.restore(appId);assert.equal(draft.teamId,'fixture-team');assert.equal(draft.appIdentifier,'original-random-identifier');
 assert.equal(draft.originalAppId,appId);assert.equal(f.nativeCalls(),1);assert.equal(f.materialized(),options.cached?1:0);
 assert.equal(f.files.size,0);assert.equal(f.directories.size,0);
}
for(const [options,issue] of [[{wrongTeam:true},'response'],[{nativeFailure:true},'preparation'],[{invalidSource:true},'preparation']]){
 const f=fixture(options);await assert.rejects(f.restore(appId),e=>e.issue===issue);assert.equal(f.files.size,0);assert.equal(f.directories.size,0);
}
for(const cached of [true,false]){
 const f=fixture({cached,cancelAfterNative:true});await assert.rejects(f.restore(appId),/cancelled/);assert.equal(f.files.size,0);assert.equal(f.directories.size,0);
}
console.log('PASS automatic signing recovery: bundled/saved key, empty certificates, authorized team, errors and cancellation cleanup; no runtime third-party download');

/** 执行真实材料下载边界：仅消费认证API响应，标准URL解析不把CDN变动/默认443误判成来源错误。 */
function downloadFixture(address,{hash='',status=200}={}){
 const calls=[],bytes=Uint8Array.from([1,2,3]);let destroyed=0;
 const modules={
  '@kit.AbilityKit':{},'@kit.CoreFileKit':{},'libentry.so':{default:{}},
  '@kit.ArkTS':{url:{URL:{parseURL:value=>new URL(value)}}},
  '@kit.NetworkKit':{http:{RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{ARRAY_BUFFER:1},
   createHttp:()=>({destroy(){destroyed++;},async request(target,options){calls.push({target,options});return{responseCode:status,result:bytes.buffer};}})}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd(){const h=crypto.createHash('sha256');return{async update(v){h.update(v.data);},async digest(){return{data:new Uint8Array(h.digest())};}};}}},
  './SigningPreparationError':errors,'./SideloadFiles':{},'./OriginalSigningRecovery':{},
  './DeveloperAuthSession':{DeveloperAuthSession:{isExpired:()=>false}}
 };
 const {DeveloperSigningService:Service}=compile('DeveloperSigningService',modules);
 const auth={async request(api,method,team,body){assert.equal(api,'/api/amis/app-manage/v1/objects/url/reapply');
  assert.equal(method,'POST');assert.equal(team,'fixture-team');assert.equal(body.sourceUrls,'fixture-object');return{urlsInfo:[{newUrl:address,sha256:hash}]};}};
 return{run:()=>Service.download(auth,'fixture-team','fixture-object'),Service,modules,calls,destroyed:()=>destroyed};
}
for(const address of ['https://example.huawei.com/cert','https://CDN.example.com:443/cert?signature=fixture-only',
 'https://bucket.obs.cn-north-4.huaweicloud.com/cert']){
 const f=downloadFixture(address);assert.deepEqual(Array.from(await f.run()),[1,2,3]);
 assert.equal(f.calls[0].target,address);assert.equal(f.calls[0].options.header,undefined);assert.equal(f.destroyed(),1);
}
for(const address of ['',{},'http://cdn.example.com/cert','https://u:p@cdn.example.com/cert','https://cdn.example.com:8443/cert',
 'https://127.0.0.1/cert','https://127.1/cert','https://0x7f000001/cert','https://[::1]/cert','https://localhost./cert',
 'https://a.local/cert','https://a.internal./cert','https://cdn.example.com\\@127.0.0.1/cert','https://cdn.example.com/\ncert']){
 const f=downloadFixture(address);await assert.rejects(f.run(),e=>e.issue==='response');assert.equal(f.calls.length,0);
}
{
 const digest=crypto.createHash('sha256').update(Uint8Array.from([1,2,3])).digest('hex');
 await downloadFixture('https://cdn.example.com/cert',{hash:digest}).run();
 for(const options of [{hash:'0'.repeat(64)},{hash:'bad'},{status:503}]){
  const f=downloadFixture('https://cdn.example.com/cert?signature=fixture-only',options);
  await assert.rejects(f.run(),e=>!e.message.includes('fixture-only'));assert.equal(f.destroyed(),1);
 }
}
console.log('PASS material URL: authenticated API source, HTTPS/public host, default port, no account headers and digest verification');

/** 真实prepare在未注册设备上提交官方类型码，并将查回的云端记录ID交给Profile；已注册设备不重复新增。 */
for(const alreadyRegistered of [false,true]){
 const f=downloadFixture('https://cdn.example.com/cert');let registered=alreadyRegistered,addCount=0,profileCount=0;
 f.modules['@kit.AbilityKit'].bundleManager={BundleFlag:{GET_BUNDLE_INFO_WITH_SIGNATURE_INFO:1},
  getBundleInfoForSelfSync:()=>({name:'com.amcl.launcher',signatureInfo:{appId:'fixture-app',appIdentifier:'fixture-identifier'}})};
 // 材料下载已由上方独立真实边界验证，本例只替换二进制边界以观察注册请求，不创建密码学材料。
 f.Service.download=async()=>Uint8Array.from([1,2,3]);
 const draft={id:'fixture',appIdentifier:'fixture-identifier',teamId:'fixture-team',originalAppId:'fixture-app',
  originalCertificateId:'fixture-cert',originalCertificateValidFrom:1,originalCertificateValidUntil:Date.now()+60000};
 const auth={teamIds:()=>['fixture-team'],preferredTeamId:()=> 'fixture-team',async request(api,method,team,body){
  assert.equal(team,'fixture-team');
  if(api.endsWith('/cert/list'))return{certList:[{id:'fixture-cert',certObjectId:'fixture-object'}]};
  if(api.includes('/device/list?'))return{list:registered?[{udid:'fixture-udid',id:'cloud-device-id'}]:[]};
  if(api.endsWith('/device/add')){assert.equal(body.deviceType,'4');assert.equal(body.udid,'fixture-udid');registered=true;addCount++;return{};}
  assert(api.endsWith('/ide/test/provision/add'));assert.deepEqual(Array.from(body.deviceList),['cloud-device-id']);
  profileCount++;throw Error('fixture reached profile');
 }};
 await assert.rejects(f.Service.prepare({},auth,{async readDraft(){return draft;},async saveDraft(){}},
  'fixture-udid','signer','runner','jdk',()=>{}),/fixture reached profile/);
 assert.equal(addCount,alreadyRegistered?0:1);assert.equal(profileCount,1);
}
console.log('PASS device registration: actual prepare uses official phone/tablet type and cloud device ID, existing registration reused');

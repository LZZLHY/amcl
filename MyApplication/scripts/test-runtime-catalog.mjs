/**
 * 直接执行生产 ArkTS parser / JWS / repository，通过 Node OpenSSL 校验 DER 转换，
 * SDK I/O 替身仅提供加密和文件/网络边界，不复写被测目录逻辑。设备平台验签仍需真机验收。
 * 可选 --source-ref <Git提交> 读取真实旧 Repository 作为撤回负对照；其余验证器与 SDK 边界相同。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync,sign,verify,createPublicKey } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { legacyRuntimeCatalogText } from './lib/legacy-runtime-catalog-fixture.mjs';

// 负对照只替换明确提交中的真实生产 Repository，不删除条件或拼造一份“错误实现”。
const sourceRefIndex=process.argv.indexOf('--source-ref');
const sourceRef=sourceRefIndex<0?undefined:process.argv[sourceRefIndex+1];
// 负控明确要求真实Repository经过Native opt-in；旧提交仍能下载/验签，但应在业务
// 断言中失败，而不是利用新Native签名不兼容造成编译失败来冒充复现。
const requireRelayRoute=process.argv.includes('--require-relay-route');
if(sourceRefIndex>=0&&!sourceRef)throw new Error('--source-ref 需要明确的 Git 提交');
const repositoryPath='launch/src/main/ets/RuntimeCatalogRepository.ets';
const sourceOverrides=sourceRef===undefined?{}:{[repositoryPath]:execFileSync('git',[
  '-C',fileURLToPath(new URL('..',import.meta.url)),'show',sourceRef+':'+repositoryPath
],{encoding:'utf8',maxBuffer:1024*1024})};

// 本套包含 v1 畸形输入与 loaderProtocol 回退，固定原始协议；正式 v2 另在下方经过同一 parser。
const builtin=legacyRuntimeCatalogText();
const pair=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const trusted={schemaVersion:1,keys:[{kid:'test',algorithm:'ES256',spki:pair.publicKey.export({format:'der',type:'spki'}).toString('base64')}]};
const bytes=value=>new Uint8Array(Buffer.from(value));
const envelopes=c=>{
  const protectedHeader=Buffer.from(JSON.stringify({alg:'ES256',typ:'amcl-runtime-catalog+jws',kid:'test'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify(c)).toString('base64url');
  return JSON.stringify({protected:protectedHeader,payload,signature:sign('sha256',Buffer.from(protectedHeader+'.'+payload),{key:pair.privateKey,dsaEncoding:'ieee-p1363'}).toString('base64url')});
};
const files=new Map(),calls=[];let remote='';let cryptoCalls=0;let failRename=false;let networkGate=null;let cryptoGate=null;let gateway=false;let flipGateway=false;
// 只在故障用例按URL设置真实格式响应，生产解析、验签和候选顺序继续由Repository执行。
let responseForUrl=null;
const offsets=new Map();let shortWrite=0,zeroWrite=false,failDisplay=false,failDirectorySync=false;const synced=[];
const fileIo={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:0,NOFOLLOW:8},
  statSync:p=>{if(!files.has(p))throw Error('ENOENT');return{size:Buffer.byteLength(files.get(p)),isFile:()=>true};},
  readTextSync:p=>{if(!files.has(p))throw Error('ENOENT');return files.get(p).toString();},
  openSync:(p,flags)=>{if(flags&4){files.set(p,'');offsets.set(p,0);}return{fd:p};},
  writeSync:(fd,value)=>{if(zeroWrite)return 0;const bytes=Buffer.from(value);const n=shortWrite?Math.min(shortWrite,bytes.length):bytes.length;
    const before=Buffer.from(files.get(fd)||'');files.set(fd,Buffer.concat([before,bytes.subarray(0,n)]));return n;},
  closeSync:()=>{},fsyncSync:fd=>{synced.push(fd);if(failDirectorySync&&fd==='/app/runtime-catalog')throw Error('directory fsync failure');},
  renameSync:(a,b)=>{if(failRename||(failDisplay&&/\/(stable|preview)\.json$/.test(b)))throw Error('I/O');files.set(b,files.get(a));files.delete(a);}};
fileIo.lstatSync=fileIo.statSync;
const sdkDependencies={
  // 本套覆盖目录完整性/缓存/宿主ABI；行为要求由test-runtime-compatibility执行真实新App配置验证。
  './RuntimeHostProtocol':{runtimeHostProtocols:()=>[1,2],runtimeRequiredCapabilities:()=>[]},
  '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder('utf-8',{fatal:true}).decode(b)})},
    TextEncoder:class{encodeInto(t){return bytes(Buffer.from(t));}},
    Base64Helper:class{decodeSync(t){return bytes(Buffer.from(t,'base64'));}encodeToStringSync(b){return Buffer.from(b).toString('base64');}}}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createAsyKeyGenerator:()=>({convertKey:async b=>({pubKey:createPublicKey({key:Buffer.from(b.data),type:'spki',format:'der'})})}),
    createVerify:algorithm=>{assert.equal(algorithm,'ECC256|SHA256');let key;return{init:async k=>{key=k;},verify:async(d,s)=>{cryptoCalls++;if(cryptoGate){const gate=cryptoGate;cryptoGate=null;await gate();}return verify('sha256',d.data,key,s.data);}};}}},
  '@kit.NetworkKit':{http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'string'},createHttp:()=>({request:async(url,options)=>{calls.push({url,options});const response=responseForUrl?responseForUrl(url):{statusCode:200,body:remote};if(networkGate)await networkGate();return{responseCode:response.statusCode,result:response.body};},destroy:()=>{}})}},
  feature_core:{getRelayClient:()=>({isEnabled:()=>gateway}),DownloadManager:{instance:()=>({initializeCaBundle:()=>{},
    // 只替换Native网络边界；目录候选、验签、防回退和提交仍执行实际ArkTS Repository。
    async fetchTextEx(url,mirrors,timeout,headers,maxResponseBytes,allowRelay){
      calls.push({url,options:{maxLimit:maxResponseBytes},native:true,mirrors,timeout,headers,allowRelay});
      if(flipGateway){gateway=true;flipGateway=false;}
      const response=responseForUrl?responseForUrl(url):{statusCode:200,body:remote};
      if(networkGate)await networkGate();return{...response,headers:{}};
    }})}},
  '@kit.BasicServicesKit':{deviceInfo:{sdkApiVersion:20}},'@kit.CoreFileKit':{fileIo},
  commons:{ensureDirSync:()=>{},AppLogger:{info:()=>{},warn:()=>{}}}
};
const load=makePureEtsLoader(sdkDependencies,sourceOverrides);
const validation=load('launch/src/main/ets/RuntimeCatalogValidation.ets');
const api=load('launch/src/main/ets/RuntimeCatalogRepository.ets');
const scheduling=load('launch/src/main/ets/RuntimeUpdatePolicy.ets');
const c=validation.parseRuntimeCatalog(builtin,'stable');
const shipping=validation.parseRuntimeCatalog(fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8'),'stable');
assert.equal(shipping.schemaVersion,2);
assert.deepEqual(shipping.runtimes.map(item=>item.javaMajor),[8,17,21,25]);
let count=0;function check(name,body){body();count++;}
check('legacy builtin',()=>assert.equal(c.runtimes.length,4));
check('24h success throttling and clock rollback',()=>{
  assert.equal(scheduling.runtimeCheckDue(10000,9000),false);
  assert.equal(scheduling.runtimeCheckDue(10000,0),true);
  assert.equal(scheduling.runtimeCheckDue(10000,11000),true);
  assert.equal(scheduling.runtimeCheckDue(86410000,10000),true);
});
check('deferral follows target identity, not mirror changes',()=>{
  assert.equal(scheduling.runtimePromptDue(10000,9000,'17:old','17:old'),false);
  assert.equal(scheduling.runtimePromptDue(10000,9000,'17:old','17:new'),true);
});
check('receipt matching buildId must also match hash and size',()=>{
  const build=c.builds[0],good={buildId:build.id,archiveSha256:build.archive.sha256,archiveSizeBytes:build.archive.sizeBytes};
  assert.equal(scheduling.runtimeReceiptStamp(good,build,'expected'),'expected');
  assert.match(scheduling.runtimeReceiptStamp({...good,archiveSha256:'0'.repeat(64)},build,'expected'),/^identity-mismatch:/);
  assert.match(scheduling.runtimeReceiptStamp({...good,archiveSizeBytes:1},build,'expected'),/^identity-mismatch:/);
  assert.match(scheduling.runtimeReceiptStamp({},build,'expected'),/^identity-mismatch:/);
});
check('rollback only matches explicit managed IDs and requires independent revision',()=>{
  const next=structuredClone(c);next.catalogRevision++;
  const r=next.runtimes[1];r.rollback={fromBuildIds:['17-runtime-audio-rc2'],reason:'回退已定位的回归'};
  next.builds.find(b=>b.id==='17-runtime-audio-rc2').status='withdrawn';
  validation.parseRuntimeCatalog(JSON.stringify(next),'stable');
  assert.throws(()=>validation.validateRuntimeTransition(c,next));r.recommendationRevision++;
  validation.validateRuntimeTransition(c,next);
  assert.equal(scheduling.runtimeRecommendationApplies(r,'17-runtime-audio-rc2',next.builds),true);
  assert.equal(scheduling.runtimeRecommendationApplies(r,'unaffected-build',next.builds),false);
  assert.equal(scheduling.runtimeRecommendationApplies(r,'imported:anything',next.builds),false);
  r.rollback.fromBuildIds=[next.builds[0].id];assert.throws(()=>validation.parseRuntimeCatalog(JSON.stringify(next),'stable'));
});
for(const change of [x=>x.schemaVersion=2,x=>x.runtimes[1].javaMajor=8,x=>x.builds[0].archive.sha256='',
  x=>x.builds[0].downloads[1].parts[0].sizeBytes++,x=>x.builds[0].archive.fileName='../x.zip',
  x=>x.builds[0].downloads[0].url='http://example.com',x=>x.catalogRevision=1.2,x=>x.runtimes[0].installScript='x',
  x=>x.builds=null,x=>x.builds[0].archive=null,x=>x.runtimes[0].javaMajor='8',
  x=>x.builds[0].downloads[0].url='https://amcl.lovedhy.cn/runtimes/disguised.zip']) {
  check('bad payload',()=>{const bad=structuredClone(c);change(bad);assert.throws(()=>validation.parseRuntimeCatalog(JSON.stringify(bad),'stable'));});
}
check('new major supported by same adapter',()=>assert.equal(validation.supportsRuntime({...c.runtimes[1],javaMajor:29},20),true));
check('unknown adapter and API filtered',()=>{assert.equal(validation.supportsRuntime({...c.runtimes[1],adapter:'future-v2'},20),false);assert.equal(validation.supportsRuntime(c.runtimes[1],19),false);});
// 平台/布局准入与每build宿主选择分开；未知协议保留槽位展示但不能被选作下载。
check('host protocols 1 and 2 select builds; unknown protocols do not',()=>{
  for(const runtime of c.runtimes) {
    for(const loaderProtocol of [1,2,3,999]) {
      const altered={...runtime,loaderProtocol};
      const catalog={...c,runtimes:c.runtimes.map(r=>r.id===runtime.id?altered:r)};
      assert.equal(validation.runtimeBuildForHost(catalog,altered,[1,2])!==undefined,loaderProtocol<=2);
    }
    for(const changed of [{minimumApi:21},{minimumCatalogProtocol:3},{arch:'x86_64'},{libc:'glibc'},{os:'linux'},{adapter:'unknown'}])
      assert.equal(validation.supportsRuntime({...runtime,...changed},20),false);
  }
});
for(let i=0;i<16;i++) {assert.deepEqual(await api.verifyRuntimeEnvelope(envelopes(c),trusted,'stable'),c);count++;}
await assert.rejects(api.verifyRuntimeEnvelope(envelopes(c),{keys:[]},'stable'));
const e=JSON.parse(envelopes(c)); e.signature=e.signature.slice(0,-2)+'AA';await assert.rejects(api.verifyRuntimeEnvelope(JSON.stringify(e),trusted,'stable'));count+=2;
check('web off before request construction',()=>{
  for(const preference of ['auto','github','gitee','mirror','web']) assert(api.runtimeCatalogUrls('stable',preference,false).every(x=>!x.includes('amcl.lovedhy.cn')));
  assert(api.runtimeCatalogUrls('preview','web',true)[0].includes('/preview.json'));
  assert.equal(api.runtimeCatalogUrls('stable','web',false).length,0,'独立来源未允许时不能暗中当auto请求代理');
});
check('gateway catalog only uses fixed first-party cache and GitHub, independent of saved source and web opt-in',()=>{
  for(const preference of ['auto','github','gitee','mirror','web']){
    const urls=api.runtimeCatalogUrls('stable',preference,false,1,true);
    assert.equal(urls.length,2);assert.equal(urls[0],'https://amcl.lovedhy.cn/runtimes/catalog/v1/stable.json');
    assert.equal(urls[1],'https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/catalog/v1/stable.json');
  }
});
const context={filesDir:'/app',resourceManager:{getRawFileContentSync:n=>bytes(Buffer.from(n.endsWith('builtin.json')?builtin:JSON.stringify(trusted)))}};

// 每个换源场景拥有独立生产模块缓存；文件/加密/HTTP替身复用，业务防倒退仍由真实 Repository 执行。
// 先接受高推荐代次，再令磁盘缓存缺失或倒退，验证换源不会把可信内存基线丢给旧缓存或旧推荐。
// 负对照同时收集两种缓存失效，防止首条断言遮掉另一条具有独立入口的回归证据。
const recommendationFailures=[];
for(const cacheState of ['missing','older']) {
  try {
    files.clear();calls.length=0;
    const caseApi=makePureEtsLoader(sdkDependencies,sourceOverrides)(repositoryPath);
    const caseRepository=caseApi.RuntimeCatalogRepository.instance(context);
    await caseRepository.configure('preview','github',false);
    const accepted=structuredClone(c);accepted.channel='preview';accepted.catalogRevision+=10;
    const runtime=accepted.runtimes.find(item=>item.javaMajor===17);runtime.recommendationRevision+=10;
    runtime.recommendedBuildId=accepted.builds.find(item=>item.runtimeId===runtime.id&&item.provenance.kind==='source-build').id;
    remote=envelopes(accepted);assert.equal((await caseRepository.refresh()).ok,true);
    const stale=structuredClone(accepted);stale.catalogRevision++;stale.runtimes.find(item=>item.javaMajor===17).recommendationRevision--;
    stale.runtimes.find(item=>item.javaMajor===17).recommendedBuildId=c.runtimes.find(item=>item.javaMajor===17).recommendedBuildId;
    assert.throws(()=>validation.validateRuntimeTransition(accepted,stale),'测试候选必须确实违反生产推荐防倒退合同');
    if(cacheState==='missing')files.delete('/app/runtime-catalog/preview.json');
    else {
      const older=structuredClone(c);older.channel='preview';older.catalogRevision++;
      files.set('/app/runtime-catalog/preview.json',envelopes(older));
    }
    await caseRepository.configure('preview','mirror',false);
    remote=envelopes(stale);
    assert.equal((await caseRepository.refresh()).ok,false,cacheState+'缓存不能令换源接受已倒退的推荐');
    assert.equal(caseRepository.snapshot().catalogRevision,accepted.catalogRevision,'缓存和失败刷新必须保留已接受的目录');
    assert.equal(caseRepository.buildFor('17').id,runtime.recommendedBuildId,'失败后仍保持同一可信推荐，不转为旧版下载');
    count++;
  } catch(error) {
    recommendationFailures.push({cacheState,error:error.message});
    console.error('FAIL recommendation baseline '+cacheState+': '+error.message);
  }
}
assert.deepEqual(recommendationFailures,[],'换源时两种缓存失效均须保持生产推荐防倒退');
files.clear();calls.length=0;remote='';
const repository=api.RuntimeCatalogRepository.instance(context);await repository.configure('stable','github',false);
const next=structuredClone(c);next.catalogRevision++;remote=envelopes(next);
assert.equal((await repository.refresh()).ok,true);assert.equal(calls[0].options.maxLimit,1048576);assert.equal(repository.snapshot().catalogRevision,next.catalogRevision);count++;
if(sourceRef===undefined||requireRelayRoute){
  assert.equal(calls[0].native,true,'JDK目录必须经过真实Repository调用Native metadata，不得停留在直连NetworkKit');
  assert.equal(calls[0].allowRelay,true,'只有明确opt-in才允许Native为可信JDK目录使用自有网关');
  assert.deepEqual(calls[0].mirrors,[],'当前候选的回源不能由Native偷偷注入第三方镜像');
  count++;
}
const previousCache=files.get('/app/runtime-catalog/stable.json');remote=envelopes(c);
assert.equal((await repository.refresh()).ok,false);assert.equal(files.get('/app/runtime-catalog/stable.json'),previousCache);count++;
const newest=structuredClone(next);newest.catalogRevision++;remote=envelopes(newest);failRename=true;
assert.equal((await repository.refresh()).ok,false);assert.equal(repository.snapshot().catalogRevision,next.catalogRevision);assert.equal(files.get('/app/runtime-catalog/stable.json'),previousCache);count++;
// 请求返回前切换通道：旧结果既不能覆盖新通道，也不能写旧请求的成功缓存。
failRename=false;let releaseNetwork;
networkGate=()=>new Promise(resolve=>{releaseNetwork=resolve;});remote=envelopes(newest);
const oldRequest=repository.refresh();await repository.configure('preview','github',false);
const callsBefore=calls.length;releaseNetwork();assert.equal((await oldRequest).ok,false);assert.equal(calls.length,callsBefore);
assert.equal(files.get('/app/runtime-catalog/stable.json'),previousCache);
networkGate=null;const preview=structuredClone(newest);preview.channel='preview';remote=envelopes(preview);
assert.equal((await repository.refresh()).ok,true);assert.equal(repository.snapshot().channel,'preview');count++;
await repository.configure('stable','github',false);remote=envelopes(next);
assert.equal((await repository.refresh()).ok,false,'不能通过切换通道降低全局代次');count++;
await repository.configure('preview','github',false);
const withdrawn=structuredClone(preview);withdrawn.catalogRevision++;
withdrawn.runtimes[1].recommendationRevision++;
withdrawn.runtimes[1].rollback={fromBuildIds:['17-runtime-audio-rc2'],reason:'fixture rollback'};
withdrawn.builds.find(b=>b.id==='17-runtime-audio-rc2').status='withdrawn';remote=envelopes(withdrawn);
assert.equal((await repository.refresh()).ok,true);assert.equal(repository.isBuildAllowed('17-runtime-audio-rc2'),false);
await repository.configure('stable','github',false);
assert.equal(repository.isBuildAllowed('17-runtime-audio-rc2'),false,'切通道不能遗忘已接受的撤回');count++;
assert.equal(repository.buildFor('17'),undefined,'低于已知全局代次的缓存不能提供新下载推荐');
// 目录不能用于下载时仍须保留槽位供页面展示，避免预览/稳定切换后只剩导入卡片。
assert.equal(repository.definitions().length,4,'旧目录的槽位仍可展示，下载权限须单独判定');count++;
await repository.configure('preview','github',false);
const revived=structuredClone(withdrawn);revived.catalogRevision++;revived.runtimes[1].recommendationRevision++;delete revived.runtimes[1].rollback;
revived.builds.find(b=>b.id==='17-runtime-audio-rc2').status='available';remote=envelopes(revived);
assert.equal((await repository.refresh()).ok,false);assert.equal(repository.isBuildAllowed('17-runtime-audio-rc2'),false);count++;
// 缓存系统验签是异步的。同参 configure 和直接 refresh 都必须等待同一次加载，
// 否则先提交的远程高代次目录可能被尚未结束的旧缓存覆盖。
let releaseCrypto;cryptoGate=()=>new Promise(resolve=>{releaseCrypto=resolve;});
const loading=repository.configure('stable','github',false);
await new Promise(setImmediate);
assert.equal(typeof releaseCrypto,'function');
let joined=false;const joining=repository.configure('stable','github',false).then(()=>{joined=true;});
const stableLatest=structuredClone(withdrawn);stableLatest.channel='stable';stableLatest.catalogRevision++;
remote=envelopes(stableLatest);const beforeCache=calls.length;const waitsForCache=repository.refresh();
await new Promise(setImmediate);
assert.equal(joined,false,'重复配置必须等待缓存验签');
assert.equal(calls.length,beforeCache,'缓存未加载完不能抢先刷新');
releaseCrypto();await Promise.all([loading,joining]);
assert.equal((await waitsForCache).ok,true);assert.equal(repository.snapshot().catalogRevision,stableLatest.catalogRevision);count++;

// 通道更换后新刷新不能复用仍在等待网络的旧通道 Promise；旧请求也不能清掉新请求句柄。
let releaseOldNetwork;networkGate=()=>{networkGate=null;return new Promise(resolve=>{releaseOldNetwork=resolve;});};
remote=envelopes(stableLatest);const oldStable=repository.refresh();await new Promise(setImmediate);
await repository.configure('preview','github',false);
const previewLatest=structuredClone(stableLatest);previewLatest.channel='preview';previewLatest.catalogRevision++;
remote=envelopes(previewLatest);const newPreview=repository.refresh();
let timer;const deadline=new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('新通道等待了旧通道请求')),1000);});
try {assert.equal((await Promise.race([newPreview,deadline])).ok,true);}finally{clearTimeout(timer);releaseOldNetwork();}
assert.equal((await oldStable).ok,false);assert.equal(repository.snapshot().channel,'preview');
assert.equal(repository.snapshot().catalogRevision,previewLatest.catalogRevision);count++;

// 过期的所选通道目录仍保留槽位与撤回知识，但绝不提供新的下载；失败刷新也不清空它。
const expired=structuredClone(previewLatest);expired.catalogRevision++;expired.expiresAt=new Date(Date.now()-1000).toISOString().replace(/\.\d{3}Z$/,'Z');
files.set('/app/runtime-catalog/preview.json',envelopes(expired));
await repository.configure('preview','mirror',false);
assert.equal(repository.snapshot().channel,'preview');assert.equal(repository.definitions().length,4);
assert.equal(repository.buildFor('8'),undefined);assert.match(repository.recommendationUnavailableReason(),/过期/);
remote='{}';assert.equal((await repository.refresh()).ok,false);assert.equal(repository.definitions().length,4);count++;

// 首次切至无缓存的预览通道，仅以随包槽位占位，不能冒用稳定通道推荐提示安装/降级。
// 此处使用全新生产模块缓存，不能沿用先前已接受过preview的单例来冒充“首次进入”。
files.clear();
const firstPreviewApi=makePureEtsLoader(sdkDependencies,sourceOverrides)(repositoryPath);
const firstPreviewRepository=firstPreviewApi.RuntimeCatalogRepository.instance(context);
await firstPreviewRepository.configure('preview','github',false);
assert.equal(firstPreviewRepository.definitions().length,4);assert.equal(firstPreviewRepository.buildFor('8'),undefined);
assert.match(firstPreviewRepository.recommendationUnavailableReason(),/尚未获取/);count++;
// v2把宿主要求绑定到build；使用明确旧宿主反例，验证兼容1推荐与展示槽不会被新包挤掉。
files.clear();
const modern=structuredClone(c);modern.schemaVersion=2;modern.catalogRevision+=100;modern.channel='preview';
for(const build of modern.builds)build.requiredHostProtocol=1;
for(const runtime of modern.runtimes){
  const oldId=runtime.recommendedBuildId;
  const newer=structuredClone(modern.builds.find(build=>build.id===oldId));
  newer.id=oldId+'-host2';newer.requiredHostProtocol=2;newer.legacyTags=[];modern.builds.push(newer);
  runtime.recommendedBuildIds=[newer.id,oldId];delete runtime.recommendedBuildId;delete runtime.loaderProtocol;
  runtime.minimumCatalogProtocol=2;
}
validation.parseRuntimeCatalog(JSON.stringify(modern),'preview');
const modernApi=makePureEtsLoader({...sdkDependencies,'./RuntimeHostProtocol':{runtimeHostProtocols:()=>[1],runtimeRequiredCapabilities:()=>[]}})(repositoryPath),modernRepository=modernApi.RuntimeCatalogRepository.instance(context);
await modernRepository.configure('preview','github',false);remote=envelopes(modern);
assert.equal((await modernRepository.refresh()).ok,true);assert.equal(modernRepository.definitions().length,4);
assert.equal(modernRepository.buildFor('17').requiredHostProtocol,1);assert.equal(modernRepository.buildForHost('17',[1,2]).requiredHostProtocol,2);
assert.match(modernRepository.hostUpgradeReason('17'),/需要先更新 AMCL/);
assert(files.has('/app/runtime-catalog/v2/preview.json'),'v2必须独立缓存命名空间');
const changedRequirement=structuredClone(modern);changedRequirement.catalogRevision++;changedRequirement.builds[0].requiredHostProtocol=9;
assert.throws(()=>validation.validateRuntimeTransition(modern,changedRequirement));
const stopped=structuredClone(modern);stopped.catalogRevision++;stopped.runtimes[0].recommendationRevision++;stopped.runtimes[0].recommendedBuildIds=[];
validation.parseRuntimeCatalog(JSON.stringify(stopped),'preview');validation.validateRuntimeTransition(modern,stopped);count+=7;
// 使用新单例和真实签名目录经过生产Repository，确认兼容门实际约束下载选择。
// 同一包仅作为固定目录夹具，不能据此给真实候选授予协议2运行资格。
files.clear();
const protocolApi=makePureEtsLoader(sdkDependencies,sourceOverrides)(repositoryPath);
const protocolRepository=protocolApi.RuntimeCatalogRepository.instance(context);
await protocolRepository.configure('preview','github',false);
const protocolCatalog=structuredClone(c);protocolCatalog.channel='preview';protocolCatalog.catalogRevision++;
for(const runtime of protocolCatalog.runtimes) {runtime.loaderProtocol=2;runtime.recommendationRevision++;}
remote=envelopes(protocolCatalog);assert.equal((await protocolRepository.refresh()).ok,true);
for(const runtime of protocolCatalog.runtimes)
  assert.equal(protocolRepository.buildFor(String(runtime.javaMajor))?.id,runtime.recommendedBuildId);
count++;
const unknownProtocol=structuredClone(protocolCatalog);unknownProtocol.catalogRevision++;
for(const runtime of unknownProtocol.runtimes) {runtime.loaderProtocol=3;runtime.recommendationRevision++;}
remote=envelopes(unknownProtocol);assert.equal((await protocolRepository.refresh()).ok,true);
for(const runtime of unknownProtocol.runtimes) assert.equal(protocolRepository.buildFor(String(runtime.javaMajor)),undefined);
assert.equal(protocolRepository.definitions().length,4);count++;
await protocolRepository.configure('stable','github',false);
const stableProtocol=structuredClone(c);stableProtocol.catalogRevision=unknownProtocol.catalogRevision+1;
remote=envelopes(stableProtocol);assert.equal((await protocolRepository.refresh()).ok,true);
for(const runtime of stableProtocol.runtimes)
  assert.equal(protocolRepository.buildFor(String(runtime.javaMajor))?.id,runtime.recommendedBuildId);
count++;

// 耐久知识与可丢弃展示缓存分离。真实生产Repository和ES256继续执行，密钥仅为本测试信任根。
function freshRepository(){return makePureEtsLoader(sdkDependencies,sourceOverrides)(repositoryPath).RuntimeCatalogRepository.instance(context);}
function withdrawnFloor(){const value=structuredClone(c);value.catalogRevision+=200;value.builds.find(b=>b.id==='17-runtime-audio-rc2').status='withdrawn';return value;}
files.clear();shortWrite=11;
let durable=freshRepository();await durable.configure('stable','github',false);remote=envelopes(withdrawnFloor());
assert.equal((await durable.refresh()).ok,true);assert.equal(JSON.parse(files.get('/app/runtime-catalog/accepted.json').toString()).envelopes.length,1);
assert.doesNotThrow(()=>JSON.parse(files.get('/app/runtime-catalog/stable.json').toString()));
assert(synced.includes('/app/runtime-catalog'),'rename后必须同步目录');shortWrite=0;count++;
// 展示缓存丢失/损坏都不能复活撤回，也不能回落到随包推荐。
for(const cacheFailure of ['missing','corrupt']){
  if(cacheFailure==='missing')files.delete('/app/runtime-catalog/stable.json');else files.set('/app/runtime-catalog/stable.json','{broken');
  durable=freshRepository();await durable.configure('stable','github',false);remote=envelopes(c);
  assert.equal((await durable.refresh()).ok,false);assert.equal(durable.isBuildAllowed('17-runtime-audio-rc2'),false);
  assert.equal(durable.snapshot().catalogRevision,withdrawnFloor().catalogRevision);count++;
}
// 信任账本先提交，即使展示副本写失败，新进程仍恢复同一个最高代次。
files.clear();durable=freshRepository();await durable.configure('stable','github',false);remote=envelopes(withdrawnFloor());failDisplay=true;
assert.equal((await durable.refresh()).ok,false);failDisplay=false;durable=freshRepository();await durable.configure('stable','github',false);
assert.equal(durable.isBuildAllowed('17-runtime-audio-rc2'),false);remote=envelopes(c);assert.equal((await durable.refresh()).ok,false);count++;
// 零写/父目录同步失败不得当作成功；同进程仍保留已验证知识，重试首先同步它，拒绝旧目录。
for(const fault of ['zero','directory']){
  files.clear();durable=freshRepository();await durable.configure('stable','github',false);remote=envelopes(withdrawnFloor());
  zeroWrite=fault==='zero';failDirectorySync=fault==='directory';assert.equal((await durable.refresh()).ok,false);
  zeroWrite=false;failDirectorySync=false;remote=envelopes(c);assert.equal((await durable.refresh()).ok,false);
  assert.equal(durable.isBuildAllowed('17-runtime-audio-rc2'),false);count++;
}
// 同轮第一来源遇到短暂目录同步故障，后备来源已成功耐久提交时必须立即恢复准入，
// 不能refresh返回ok而留下旧ledgerFailure，迫使用户再检查一次才能继续。
files.clear();durable=freshRepository();await durable.configure('stable','auto',false);
const transientCatalog=structuredClone(c);transientCatalog.catalogRevision+=201;remote=envelopes(transientCatalog);
const originalSync=fileIo.fsyncSync;let transientDirectoryFailure=true;
fileIo.fsyncSync=fd=>{if(transientDirectoryFailure&&fd==='/app/runtime-catalog'){
  transientDirectoryFailure=false;throw Error('one transient directory sync failure');}return originalSync(fd);};
try {
  assert.equal((await durable.refresh()).ok,true);
  assert.equal(durable.recommendationUnavailableReason(),'');
  assert.notEqual(durable.buildFor('17'),undefined);
  const accepted=JSON.parse(files.get('/app/runtime-catalog/accepted.json').toString());
  assert.equal(JSON.parse(Buffer.from(JSON.parse(accepted.envelopes[0]).payload,'base64url')).catalogRevision,transientCatalog.catalogRevision);
} finally { fileIo.fsyncSync=originalSync; }
count++;
files.set('/app/runtime-catalog/accepted.json','{unknown');durable=freshRepository();await durable.configure('stable','github',false);
const beforeCorruptCalls=calls.length;assert.equal((await durable.refresh()).ok,false);assert.match(durable.recommendationUnavailableReason(),/信任记录损坏/);
assert.equal(durable.buildFor('17'),undefined);assert.equal(calls.length,beforeCorruptCalls);assert.equal(durable.definitions().length,4);count++;
// UTF-8短写可能落在多字节字符中；存储层以字节续写，不能按JS字符数截断。
shortWrite=1;load('launch/src/main/ets/RuntimeCatalogStore.ets').writeRuntimeCatalogAtomic('/app','/app/runtime-catalog','/app/runtime-catalog/utf8.json','中文更新');
assert.equal(files.get('/app/runtime-catalog/utf8.json').toString(),'中文更新');shortWrite=0;count++;

/** 两种格式使用同一真实目录内容，只转换协议规定的推荐/宿主字段，不修改业务校验。 */
function projection(channel,version,revision){
  const value=structuredClone(c);value.channel=channel;value.catalogRevision=revision;
  if(version===2){value.schemaVersion=2;for(const build of value.builds)build.requiredHostProtocol=1;
    for(const runtime of value.runtimes){runtime.recommendedBuildIds=[runtime.recommendedBuildId];delete runtime.recommendedBuildId;delete runtime.loaderProtocol;runtime.minimumCatalogProtocol=2;}}
  return value;
}
function storedProjection(channel,version){
  return JSON.parse(files.get('/app/runtime-catalog/accepted.json').toString()).envelopes
    .map(raw=>JSON.parse(Buffer.from(JSON.parse(raw).payload,'base64url').toString()))
    .find(value=>value.channel===channel&&value.schemaVersion===version);
}
// 独立审查真实反例：在另一通道冷启动时，旧展示cache也不能降低同projection的耐久原文。
for(const version of [1,2])for(const channel of ['stable','preview']){
  files.clear();let repository=freshRepository();await repository.configure(channel,'github',false);
  const old=projection(channel,version,10),latest=structuredClone(old);latest.catalogRevision=11;
  latest.builds.find(build=>build.id==='17-runtime-audio-rc2').status='withdrawn';remote=envelopes(latest);
  assert.equal((await repository.refresh()).ok,true);files.set('/app/runtime-catalog/'+(version===2?'v2/':'')+channel+'.json',envelopes(old));
  repository=freshRepository();await repository.configure(channel==='stable'?'preview':'stable','github',false);
  assert.equal(storedProjection(channel,version).catalogRevision,11);repository=freshRepository();await repository.configure(channel,'github',false);
  assert.equal(repository.snapshot().catalogRevision,11);assert.equal(repository.isBuildAllowed('17-runtime-audio-rc2'),false);count++;
}
// 全局低代不是丢弃v2证据的理由：较新v1无法逐build表达旧v2携带的宿主要求。
for(const newerChannel of ['stable','preview']){
  files.clear();const older=projection('preview',2,10),newer=projection(newerChannel,1,11);
  older.builds.find(build=>build.id==='17-runtime-audio-rc2').requiredHostProtocol=2;
  files.set('/app/runtime-catalog/'+newerChannel+'.json',envelopes(newer));files.set('/app/runtime-catalog/v2/preview.json',envelopes(older));
  let repository=freshRepository();await repository.configure(newerChannel,'github',false);
  assert.equal(repository.snapshot().catalogRevision,11,'较老v2不能倒退较新v1展示');
  assert.equal(storedProjection('preview',2).builds.find(build=>build.id==='17-runtime-audio-rc2').requiredHostProtocol,2);
  repository=freshRepository();await repository.configure('preview','github',false);
  const drift=structuredClone(older);drift.catalogRevision=12;drift.builds.find(build=>build.id==='17-runtime-audio-rc2').requiredHostProtocol=1;remote=envelopes(drift);
  assert.equal((await repository.refresh()).ok,false,'冷启动后仍拒绝旧v2绑定的宿主要求漂移');
  const good=structuredClone(older);good.catalogRevision=12;remote=envelopes(good);assert.equal((await repository.refresh()).ok,true);count++;
}
// 同代次的另一份有效签名也不能漂移同projection内容；签名有效不代替原身份单调约束。
files.clear();durable=freshRepository();await durable.configure('preview','github',false);const fixed=projection('preview',2,20);remote=envelopes(fixed);assert.equal((await durable.refresh()).ok,true);
const sameRevision=structuredClone(fixed);sameRevision.builds[0].notes.push('signed but drifted');files.set('/app/runtime-catalog/v2/preview.json',envelopes(sameRevision));
durable=freshRepository();await durable.configure('stable','github',false);assert.deepEqual(storedProjection('preview',2),fixed);count++;
// 在第一个原站请求返回期间打开网关：旧auto候选里的代理不能继续发HTTP，已验签但
// 已失去发布权的响应也不能刷新持久推荐。此处执行真实Repository而非仅断言URL helper。
const changingApi=makePureEtsLoader(sdkDependencies)(repositoryPath);
const changingRepo=changingApi.RuntimeCatalogRepository.instance({...context,filesDir:'/gateway-changing'});
await changingRepo.configure('stable','auto',false);calls.length=0;remote=envelopes(c);flipGateway=true;
try{const changed=await changingRepo.refresh();assert.equal(changed.ok,false);assert.equal(calls.length,1);
  assert.match(changed.error,/方式|设置/);assert.equal(files.has('/gateway-changing/runtime-catalog/stable.json'),false);
  assert.equal(files.has('/gateway-changing/runtime-catalog/accepted.json'),false,'过期传输同意的响应也不能推进耐久信任ledger');count++;}
finally{gateway=false;flipGateway=false;}
// 首个v2镜像误放有效v1时，必须继续查后续v2，而不能把真实签名误当格式匹配。
// 两通道都经过实际下载入口，错误正文不得抢先写入accepted.json。
for(const channel of ['stable','preview']){
  files.clear();calls.length=0;
  const legacy={...structuredClone(c),channel};
  const modernCandidate={...structuredClone(modern),channel};
  const legacyEnvelope=envelopes(legacy),modernEnvelope=envelopes(modernCandidate);
  const checked=freshRepository();await checked.configure(channel,'auto',false);
  let requestIndex=0;
  responseForUrl=url=>({statusCode:200,body:requestIndex++===0?legacyEnvelope:modernEnvelope});
  try{
    assert.equal((await checked.refresh()).ok,true);
    assert.equal(checked.snapshot().schemaVersion,2);
    assert.equal(calls.length,2);
    assert(calls.every(call=>call.url.includes('/catalog/v2/')));
    const accepted=JSON.parse(files.get('/app/runtime-catalog/accepted.json').toString());
    assert.deepEqual(accepted.envelopes,[modernEnvelope]);
    count++;
  }finally{responseForUrl=null;}

  // 正常缺少v2仍允许沿v1继续。反向错配同样必须拒绝，两个命名空间不互相冒充。
  for(const reverseMismatch of [false,true]){
    files.clear();calls.length=0;
    const fallback=freshRepository();await fallback.configure(channel,'github',false);
    responseForUrl=url=>url.includes('/catalog/v2/')
      ? {statusCode:404,body:'not found'}
      : {statusCode:200,body:reverseMismatch?modernEnvelope:legacyEnvelope};
    try{
      assert.equal((await fallback.refresh()).ok,!reverseMismatch);
      assert.equal(calls.length,2);
      if(reverseMismatch)assert.equal(files.has('/app/runtime-catalog/accepted.json'),false);
      else assert.equal(fallback.snapshot().schemaVersion,1);
      count++;
    }finally{responseForUrl=null;}
  }
}
console.log(JSON.stringify({passed:count,realDerVerifications:cryptoCalls,scope:'production ArkTS + Node OpenSSL test trust anchor; durable ledger, cold restart, namespace mismatch, gateway switching and native response budgets; OHOS remains device validation'},null,2));

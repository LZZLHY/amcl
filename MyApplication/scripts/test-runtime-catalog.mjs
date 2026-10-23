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

// 负对照只替换明确提交中的真实生产 Repository，不删除条件或拼造一份“错误实现”。
const sourceRefIndex=process.argv.indexOf('--source-ref');
const sourceRef=sourceRefIndex<0?undefined:process.argv[sourceRefIndex+1];
if(sourceRefIndex>=0&&!sourceRef)throw new Error('--source-ref 需要明确的 Git 提交');
const repositoryPath='launch/src/main/ets/RuntimeCatalogRepository.ets';
const sourceOverrides=sourceRef===undefined?{}:{[repositoryPath]:execFileSync('git',[
  '-C',fileURLToPath(new URL('..',import.meta.url)),'show',sourceRef+':'+repositoryPath
],{encoding:'utf8',maxBuffer:1024*1024})};

const builtin=fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8');
const pair=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const trusted={schemaVersion:1,keys:[{kid:'test',algorithm:'ES256',spki:pair.publicKey.export({format:'der',type:'spki'}).toString('base64')}]};
const bytes=value=>new Uint8Array(Buffer.from(value));
const envelopes=c=>{
  const protectedHeader=Buffer.from(JSON.stringify({alg:'ES256',typ:'amcl-runtime-catalog+jws',kid:'test'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify(c)).toString('base64url');
  return JSON.stringify({protected:protectedHeader,payload,signature:sign('sha256',Buffer.from(protectedHeader+'.'+payload),{key:pair.privateKey,dsaEncoding:'ieee-p1363'}).toString('base64url')});
};
const files=new Map(),calls=[];let remote='';let cryptoCalls=0;let failRename=false;let networkGate=null;let cryptoGate=null;
const fileIo={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},
  statSync:p=>{if(!files.has(p))throw Error('ENOENT');return{size:Buffer.byteLength(files.get(p))};},
  readTextSync:p=>{if(!files.has(p))throw Error('ENOENT');return files.get(p);},
  openSync:p=>({fd:p}),writeSync:(fd,s)=>files.set(fd,s),closeSync:()=>{},fsyncSync:()=>{},
  renameSync:(a,b)=>{if(failRename)throw Error('I/O');files.set(b,files.get(a));files.delete(a);}};
const sdkDependencies={
  '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder('utf-8',{fatal:true}).decode(b)})},
    TextEncoder:class{encodeInto(t){return bytes(Buffer.from(t));}},
    Base64Helper:class{decodeSync(t){return bytes(Buffer.from(t,'base64'));}encodeToStringSync(b){return Buffer.from(b).toString('base64');}}}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createAsyKeyGenerator:()=>({convertKey:async b=>({pubKey:createPublicKey({key:Buffer.from(b.data),type:'spki',format:'der'})})}),
    createVerify:algorithm=>{assert.equal(algorithm,'ECC256|SHA256');let key;return{init:async k=>{key=k;},verify:async(d,s)=>{cryptoCalls++;if(cryptoGate){const gate=cryptoGate;cryptoGate=null;await gate();}return verify('sha256',d.data,key,s.data);}};}}},
  '@kit.NetworkKit':{http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'string'},createHttp:()=>({request:async(url,options)=>{calls.push({url,options});const result=remote;if(networkGate)await networkGate();return{responseCode:200,result};},destroy:()=>{}})}},
  '@kit.BasicServicesKit':{deviceInfo:{sdkApiVersion:20}},'@kit.CoreFileKit':{fileIo},
  commons:{ensureDirSync:()=>{},AppLogger:{info:()=>{},warn:()=>{}}}
};
const load=makePureEtsLoader(sdkDependencies,sourceOverrides);
const validation=load('launch/src/main/ets/RuntimeCatalogValidation.ets');
const api=load('launch/src/main/ets/RuntimeCatalogRepository.ets');
const scheduling=load('launch/src/main/ets/RuntimeUpdatePolicy.ets');
const c=validation.parseRuntimeCatalog(builtin,'stable');
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
for(let i=0;i<16;i++) {assert.deepEqual(await api.verifyRuntimeEnvelope(envelopes(c),trusted,'stable'),c);count++;}
await assert.rejects(api.verifyRuntimeEnvelope(envelopes(c),{keys:[]},'stable'));
const e=JSON.parse(envelopes(c)); e.signature=e.signature.slice(0,-2)+'AA';await assert.rejects(api.verifyRuntimeEnvelope(JSON.stringify(e),trusted,'stable'));count+=2;
check('web off before request construction',()=>{
  for(const preference of ['auto','github','gitee','mirror','web']) assert(api.runtimeCatalogUrls('stable',preference,false).every(x=>!x.includes('amcl.lovedhy.cn')));
  assert(api.runtimeCatalogUrls('preview','web',true)[0].includes('/preview.json'));
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
files.delete('/app/runtime-catalog/preview.json');
const firstPreviewApi=makePureEtsLoader(sdkDependencies,sourceOverrides)(repositoryPath);
const firstPreviewRepository=firstPreviewApi.RuntimeCatalogRepository.instance(context);
await firstPreviewRepository.configure('preview','github',false);
assert.equal(firstPreviewRepository.definitions().length,4);assert.equal(firstPreviewRepository.buildFor('8'),undefined);
assert.match(firstPreviewRepository.recommendationUnavailableReason(),/尚未获取/);count++;
console.log(JSON.stringify({passed:count,realDerVerifications:cryptoCalls,scope:'production ArkTS + Node OpenSSL; OHOS platform crypto remains device validation'},null,2));

/**
 * 直接执行生产跨App计划和生产JdkInstaller。复用现有安装器内存Kit/下载边界，不复制计划算法；
 * 注入宿主[1,2]验证返回组合，真实生成能力由独立产物契约验证。
 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createHash,generateKeyPairSync,sign,verify} from 'node:crypto';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {runLateJournalRegression} from './test-app-jdk-late-journal.mjs';
let harness=fs.readFileSync(new URL('./test-runtime-catalog-install.mjs',import.meta.url),'utf8');
harness=harness.slice(0,harness.indexOf('const results=[];')).replace(/^import[^\n]+\n/gm,'');
const fixtureBase=JSON.parse(fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8'));
const lateJournal=await runLateJournalRegression();
const signaturePair=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
/** 真实测试信任根签名，仅证明大目录仍在协议1MiB上限内，不伪造线上签名。 */
function signedCatalogBytes(catalog){
  const header=Buffer.from(JSON.stringify({alg:'ES256',typ:'amcl-runtime-catalog+jws',kid:'large-test'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify(catalog)).toString('base64url'),message=Buffer.from(header+'.'+payload);
  const signature=sign('sha256',message,{key:signaturePair.privateKey,dsaEncoding:'ieee-p1363'});
  assert(verify('sha256',message,{key:signaturePair.publicKey,dsaEncoding:'ieee-p1363'},signature));
  return Buffer.byteLength(JSON.stringify({protected:header,payload,signature:signature.toString('base64url')}));
}
const body=`
const context={filesDir:'/app',cacheDir:'/cache'};
let imported=false,sourceChanged=false,sourceKind='source-build',sourceManifest='c'.repeat(64),replacementId='compatible-host1';const target={product:'sideload',versionName:'1.0.6',versionCode:1000910,sha256:'a'.repeat(64),sourceRevision:'b'.repeat(40),runtimeHostProtocols:[1],runtimePlanProtocol:2};
const initialOpen=io.openSync,initialStat=io.statSync;io.OpenMode.READ_WRITE=8;
io.openSync=(p,flags)=>{const file=initialOpen(p,flags);file.tryLock=()=>{};file.unlock=()=>{};return file;};
io.statSync=value=>initialStat(handles.has(value)?handles.get(value).p:value);
const slotCrypto={cryptoFramework:{createMd:()=>{const h=createHash('sha256');return{updateSync:value=>h.update(value.data),digestSync:()=>({data:new Uint8Array(h.digest())})};}}};
const replacement=()=>{const c=config();c.tag=replacementId;c.runtime.loaderProtocol=1;c.build={id:replacementId,requiredHostProtocol:1};return c;};
class Manager {
 listVersions(){return [{version:'17',installed:files.has('/app/jdk/17/valid'),userImported:imported,installedTag:imported?'imported:fixture':'installed-host2'}];}
 isStructurallyPresent(){return files.has('/app/jdk/17/valid');}
 isInstalled(){return this.isStructurallyPresent();}
 compatibilityConfig(){return replacement();}
}
const catalogRepository={recommendationUnavailableReason:()=>'',snapshot:()=>({schemaVersion:2,runtimes:[{id:'java17-ohos-aarch64',javaMajor:17,recommendedBuildIds:[replacementId]}],builds:[{id:'installed-host2',legacyTags:[],requiredHostProtocol:2},{id:replacementId,runtimeId:'java17-ohos-aarch64',status:'available',requiredHostProtocol:1,validationLevel:sourceChanged?'artifact-audited':'device-matrix-tested',provenance:{kind:sourceKind,manifestSha256:sourceManifest},archive:{sha256:hash(data),sizeBytes:data.length}}]}),buildForHost:()=>({id:replacementId}),isBuildAllowed:()=>!withdrawn};
const ActualJournal=load('launch/src/main/ets/JdkInstallJournal.ets').JdkInstallJournal;
const ActualStorage=load('launch/src/main/ets/JdkInstallStorage.ets').JdkInstallStorage;
const receiptLimit=load('launch/src/main/ets/RuntimeCatalogTypes.ets').RUNTIME_INSTALL_RECEIPT_LIMIT;assert.equal(receiptLimit,1048576);
const receiptCodec=load('launch/src/main/ets/RuntimeReceiptCodec.ets');
const declaration=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io}})('launch/src/main/ets/RuntimeHostDeclaration.ets');
const Bridge=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io,statfs:{getFreeSizeSync:()=>10*1024*1024*1024}},'@kit.CryptoArchitectureKit':slotCrypto,commons:{...load('commons/src/main/ets/common/RuntimeRequirementPolicy.ets'),ensureDirSync:ensure,stringToUtf8:value=>new Uint8Array(Buffer.from(value))},
 launch:{...receiptCodec,...declaration,RUNTIME_INSTALL_RECEIPT_LIMIT:receiptLimit,JdkManager:Manager,JdkInstaller:Installer,JdkDirectoryLease:{appPlan:()=>({release(){}}),writer:()=>({descriptor:()=>10,release(){}})},JdkInstallStorage:ActualStorage,RuntimeCatalogRepository:{instance:()=>catalogRepository},runtimeRecommendationIds:r=>r.recommendedBuildIds,runtimeRequiredHost:(_c,b)=>b.requiredHostProtocol,runtimeHostProtocols:()=>[1,2],runtimeRequiredCapabilities:()=>[]}
})('entry/src/main/ets/runtime/AppJdkUpdatePlanRuntime.ets').AppJdkUpdatePlanRuntime;
function setup(){reset();ensure('/app/jdk');ensure('/cache');imported=false;sourceChanged=false;sourceKind='source-build';sourceManifest='c'.repeat(64);replacementId='compatible-host1';files.set('/cache/app.signed.hap',Buffer.from('signed'));files.set('/app/jdk/17/.amcl_release_tag',Buffer.from('installed-host2'));files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from(JSON.stringify({origin:'catalog',build:{requiredHostProtocol:2},runtime:{loaderProtocol:2}})));}
function signedPath(id){const path='/app/sideload-update/tasks/'+id+'/signed.hap';ensure('/app/sideload-update/tasks/'+id);files.set(path,Buffer.from('signed'));return path;}
let passed=0;
// 设备验证等级不能代替源码来源。计划准备必须在下载前拒绝历史包或缺少构建清单的包。
for(const kind of ['legacy','missing-manifest']){
  setup();if(kind==='legacy')sourceKind='legacy';else sourceManifest='';
  await assert.rejects(Bridge.prepare(context,'source-'+kind,target),/合格兼容构建/);
  assert.equal(requests.length,0);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(Bridge.pending(context),false);passed++;
}
// prepare后资格改变也须在切槽前挡住；保留原计划和旧JDK，让原事务能够等待目录修复。
setup();await Bridge.prepare(context,'source-drift',target);Bridge.markAppSigned(context,'source-drift',target,signedPath('source-drift'));
sourceManifest='';await assert.rejects(Bridge.restore(context,'source-drift',target),/资格/);
assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(Bridge.pending(context),true);passed++;
// 同通道仍有合格后备时应继续选后备，不把首项资格不足误判为整个通道不可用。
setup();const sourceSnapshot=catalogRepository.snapshot;
catalogRepository.snapshot=()=>{const c=sourceSnapshot(),legacy=structuredClone(c.builds[1]);legacy.id='legacy-first';legacy.provenance.kind='legacy';c.builds.push(legacy);c.runtimes[0].recommendedBuildIds.unshift(legacy.id);return c;};
try{await Bridge.prepare(context,'source-fallback',target);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].replacement.build.id,replacementId);passed++;}
finally{catalogRepository.snapshot=sourceSnapshot;}
setup();await Bridge.prepare(context,'case1',target);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert(files.has('/cache/app-runtime-plan/case1/jdk-17.zip'));assert.equal(requests.length,1);
await assert.rejects(Bridge.restore(context,'case1',target),/先完成/);passed++;
Bridge.markAppSigned(context,'case1',target,signedPath('case1'));await Bridge.restore(context,'case1',target);assert.equal(files.get('/app/jdk/17/valid').toString(),'new');assert.equal(Bridge.pending(context),true);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).phase,'ready-to-install');passed++;
assert.throws(()=>Bridge.verified(context,'case1',{...target,sha256:'b'.repeat(64)}),/其他原件/);assert.equal(Bridge.pending(context),true);Bridge.verified(context,'case1',target);assert.equal(Bridge.pending(context),false);passed++;
setup();await Bridge.prepare(context,'withdrawn',target);Bridge.markAppSigned(context,'withdrawn',target,signedPath('withdrawn'));withdrawn=true;await assert.rejects(Bridge.restore(context,'withdrawn',target),/撤回/);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();await Bridge.prepare(context,'drift',target);Bridge.markAppSigned(context,'drift',target,signedPath('drift'));files.set('/app/jdk/17/.amcl_release_tag',Buffer.from('unexpected'));await assert.rejects(Bridge.restore(context,'drift',target),/身份/);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();imported=true;await assert.rejects(Bridge.prepare(context,'import',target),/来源或宿主要求未知/);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();await Bridge.prepare(context,'tampered',target);Bridge.markAppSigned(context,'tampered',target,signedPath('tampered'));files.set('/cache/app-runtime-plan/tampered/jdk-17.zip',Buffer.from('bad'));await assert.rejects(Bridge.restore(context,'tampered',target));assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();await assert.rejects(Bridge.prepare(context,'legacy-target',{...target,runtimePlanProtocol:0}),/reader协议2/);assert.equal(requests.length,0);passed++;
// 来源门只约束新切槽；目标已经兼容时，保留历史JDK，不为了App变更额外下载安装。
setup();sourceKind='legacy';const noRestore={...target,runtimeHostProtocols:[1,2],runtimePlanProtocol:0};await Bridge.prepare(context,'normal',noRestore);assert.equal(Bridge.pending(context),false);Bridge.markAppSigned(context,'normal',noRestore,signedPath('normal'));await Bridge.restore(context,'normal',noRestore);assert.equal(Bridge.pending(context),false);assert.equal(requests.length,0);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();await Bridge.prepare(context,'recover-high',target);Bridge.markAppSigned(context,'recover-high',target,signedPath('recover-high'));const write=io.writeSync;let failHigh=true;
io.writeSync=(fd,value,options)=>{if(failHigh&&handles.get(fd).p.endsWith('update-runtime-plan.json.writing')&&String(value).includes('"complete":true')){failHigh=false;throw Error('high journal interrupted');}return write(fd,value,options);};
await assert.rejects(Bridge.restore(context,'recover-high',target),/high journal/);assert.equal(files.get('/app/jdk/17/valid').toString(),'new');io.writeSync=write;Bridge.recoverPendingSlots(context,'recover-high',target.sha256);await Bridge.prepare(context,'recover-high',target);Bridge.markAppSigned(context,'recover-high',target,signedPath('recover-high'));await Bridge.restore(context,'recover-high',target);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).phase,'ready-to-install');passed++;
setup();await Bridge.prepare(context,'ready-withdraw',target);Bridge.markAppSigned(context,'ready-withdraw',target,signedPath('ready-withdraw'));await Bridge.restore(context,'ready-withdraw',target);withdrawn=true;await assert.rejects(Bridge.prepare(context,'ready-withdraw',target),/撤回/);await assert.rejects(Bridge.restore(context,'ready-withdraw',target),/撤回/);assert.equal(Bridge.pending(context),true);passed++;
setup();await Bridge.prepare(context,'ready-replaced',target);Bridge.markAppSigned(context,'ready-replaced',target,signedPath('ready-replaced'));await Bridge.restore(context,'ready-replaced',target);files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from('{}'));await assert.rejects(Bridge.restore(context,'ready-replaced',target),/外部替换/);passed++;
setup();await Bridge.prepare(context,'grade-drop',target);Bridge.markAppSigned(context,'grade-drop',target,signedPath('grade-drop'));sourceChanged=true;await assert.rejects(Bridge.restore(context,'grade-drop',target),/资格/);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');passed++;
setup();await Bridge.prepare(context,'bad-path',target);let corrupted=JSON.parse(files.get('/app/update-runtime-plan.json'));corrupted.entries[0].archive='/outside/private.zip';files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(corrupted)));assert.throws(()=>Bridge.pending(context),/冻结原件/);passed++;
setup();await Bridge.prepare(context,'bad-signed',target);corrupted=JSON.parse(files.get('/app/update-runtime-plan.json'));corrupted.signedPath='/outside/private.hap';files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(corrupted)));assert.throws(()=>Bridge.pending(context),/路径/);passed++;
setup();await Bridge.prepare(context,'no-effect',target);Bridge.markAppSigned(context,'no-effect',target,signedPath('no-effect'));files.set('/cache/app-runtime-plan/no-effect/jdk-17.zip',Buffer.from('bad'));await assert.rejects(Bridge.restore(context,'no-effect',target));assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).phase,'restoring');Bridge.cancelNoInvocation(context,'no-effect',target);assert.equal(Bridge.pending(context),false);await Bridge.prepare(context,'new-after-no-effect',target);assert.equal(Bridge.pending(context),true);passed++;
setup();await Bridge.prepare(context,'slot-death',target);Bridge.markAppSigned(context,'slot-death',target,signedPath('slot-death'));const rename=io.renameSync;let deathImage;
io.renameSync=(a,b)=>{rename(a,b);if(a==='/app/jdk/17'&&b.includes('.backup-'))deathImage={files:new Map([...files].map(([p,v])=>[p,Buffer.from(v)])),dirs:new Set(dirs)};};
// 用旧生产journal制造真实双rename中间快照，升级后的统一入口必须仍能恢复它。
const legacyStage='/app/jdk/.staging-legacy-death';ensure(legacyStage);files.set(legacyStage+'/valid',Buffer.from('new'));
files.set(legacyStage+'/.amcl_release_tag',Buffer.from('compatible-host1'));
await ActualJournal.publish(context.filesDir,'17',legacyStage);assert(deathImage);io.renameSync=rename;files=deathImage.files;dirs=deathImage.dirs;assert.equal(files.has('/app/jdk/17/valid'),false);
Bridge.recoverPendingSlots(context,'slot-death',target.sha256);assert.equal(files.get('/app/jdk/17/valid').toString(),'old','Java签名前的早恢复必须找回唯一JDK17');
await Bridge.prepare(context,'slot-death',target);Bridge.markAppSigned(context,'slot-death',target,signedPath('slot-death'));await Bridge.restore(context,'slot-death',target);assert.equal(files.get('/app/jdk/17/valid').toString(),'new');passed++;
setup();await Bridge.prepare(context,'high-withdraw',target);Bridge.markAppSigned(context,'high-withdraw',target,signedPath('high-withdraw'));const highWrite=io.writeSync;let highStop=true;
io.writeSync=(fd,value,options)=>{if(highStop&&handles.get(fd).p.endsWith('update-runtime-plan.json.writing')&&String(value).includes('"complete":true')){highStop=false;throw Error('high interrupted before qualification retry');}return highWrite(fd,value,options);};
await assert.rejects(Bridge.restore(context,'high-withdraw',target));io.writeSync=highWrite;withdrawn=true;await assert.rejects(Bridge.prepare(context,'high-withdraw',target),/撤回/);await assert.rejects(Bridge.restore(context,'high-withdraw',target),/撤回/);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).phase,'restoring');passed++;
setup();await Bridge.prepare(context,'ready-grade',target);Bridge.markAppSigned(context,'ready-grade',target,signedPath('ready-grade'));await Bridge.restore(context,'ready-grade',target);sourceChanged=true;await assert.rejects(Bridge.restore(context,'ready-grade',target),/资格/);passed++;
// 已切槽构建撤回后，要证明真实恢复能够最终完成，不能只断言pending+抛错。
setup();await Bridge.prepare(context,'replan',target);Bridge.markAppSigned(context,'replan',target,signedPath('replan'));await Bridge.restore(context,'replan',target);
const originalBefore=JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].before;
withdrawn=true;await assert.rejects(Bridge.prepare(context,'replan',target),/合格兼容构建/);assert.throws(()=>Bridge.cancelNoInvocation(context,'replan',target),/未知槽位效果/);
replacementId='compatible-host1-fixed';withdrawn=false;await Bridge.prepare(context,'replan',target);
let replanned=JSON.parse(files.get('/app/update-runtime-plan.json'));assert.equal(replanned.entries[0].before,originalBefore);assert.equal(replanned.entries[0].history.length,1);assert.equal(replanned.entries[0].history[0].frozen.buildId,'compatible-host1');assert.equal(replanned.entries[0].history[0].replacement,undefined);assert.notEqual(replanned.entries[0].activeFrom,originalBefore);assert.equal(replanned.entries[0].complete,false);
Bridge.markAppSigned(context,'replan',target,signedPath('replan'));await Bridge.restore(context,'replan',target);assert.equal(JSON.parse(files.get('/app/jdk/17/.amcl-runtime-receipt.json')).buildId,replacementId);Bridge.verified(context,'replan',target);assert.equal(Bridge.pending(context),false);passed++;
// 新步骤已持久化后下载失败，重新读取持久记录的重试不得丢掉原before或重复追加历史。
setup();await Bridge.prepare(context,'replan-cold',target);Bridge.markAppSigned(context,'replan-cold',target,signedPath('replan-cold'));await Bridge.restore(context,'replan-cold',target);replacementId='compatible-host1-fixed';mode='hash';
await assert.rejects(Bridge.prepare(context,'replan-cold',target));assert.equal(Bridge.pending(context),true);replanned=JSON.parse(files.get('/app/update-runtime-plan.json'));assert.equal(replanned.entries[0].history.length,1);mode='';
await Bridge.prepare(context,'replan-cold',target);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].history.length,1);Bridge.markAppSigned(context,'replan-cold',target,signedPath('replan-cold'));await Bridge.restore(context,'replan-cold',target);Bridge.verified(context,'replan-cold',target);assert.equal(Bridge.pending(context),false);passed++;
// 当前物理安装不是冻结步骤的旧/新身份时，不能靠重规划篡改original before而认领。
setup();await Bridge.prepare(context,'replan-unknown',target);Bridge.markAppSigned(context,'replan-unknown',target,signedPath('replan-unknown'));await Bridge.restore(context,'replan-unknown',target);files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from('{}'));replacementId='compatible-host1-fixed';await assert.rejects(Bridge.prepare(context,'replan-unknown',target),/未知JDK槽位效果/);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].history,undefined);passed++;
// 历史效果链被改坏必须保留现场；用户不能靠写入activeFrom跳过真实身份验证。
setup();await Bridge.prepare(context,'replan-history',target);Bridge.markAppSigned(context,'replan-history',target,signedPath('replan-history'));await Bridge.restore(context,'replan-history',target);replacementId='compatible-host1-fixed';await Bridge.prepare(context,'replan-history',target);replanned=JSON.parse(files.get('/app/update-runtime-plan.json'));replanned.entries[0].history[0].from='forged';files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(replanned)));assert.throws(()=>Bridge.pending(context),/效果链断裂/);passed++;
// 身份只保存完整元数据SHA/长度，单字节同长度变化也不能落入原身份；legacy原before保持原文。
const identityApi=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},'@kit.CryptoArchitectureKit':slotCrypto,commons:{stringToUtf8:value=>new Uint8Array(Buffer.from(value))},launch:{RUNTIME_INSTALL_RECEIPT_LIMIT:receiptLimit}})('entry/src/main/ets/runtime/JdkSlotIdentity.ets');
setup();const identity=identityApi.jdkSlotIdentity('/app','17');assert.equal(JSON.parse(identity).schemaVersion,2);assert(identity.length<1024);
const legacyBefore=JSON.stringify(['1',files.get('/app/jdk/17/.amcl_release_tag').toString(),files.get('/app/jdk/17/.amcl-runtime-receipt.json').toString()]);
assert.equal(identityApi.sameJdkSlotIdentity(identity,legacyBefore),true);files.set('/app/jdk/17/.amcl_release_tag',Buffer.from('installed-host3'));assert.equal(identityApi.sameJdkSlotIdentity(identityApi.jdkSlotIdentity('/app','17'),identity),false);passed++;
// 大UTF-8元数据同长度单字节改变也必须被完整摘要发现；不只哈希前64KiB。
setup();let huge=Buffer.from(JSON.stringify({data:'中'.repeat(40000)+'aaa'}));files.set('/app/jdk/17/.amcl-runtime-receipt.json',huge);const hugeId=identityApi.jdkSlotIdentity('/app','17');
assert.equal(JSON.parse(hugeId).receiptSize,huge.length);huge=Buffer.from(huge);huge[huge.length-4]='b'.charCodeAt(0);files.set('/app/jdk/17/.amcl-runtime-receipt.json',huge);assert.equal(identityApi.sameJdkSlotIdentity(identityApi.jdkSlotIdentity('/app','17'),hugeId),false);passed++;
// 新记录区分缺失和空文件；旧legacy明确保持两者同为空文本的既有语义。
setup();files.delete('/app/jdk/17/.amcl_release_tag');files.delete('/app/jdk/17/.amcl-runtime-receipt.json');const absent=identityApi.jdkSlotIdentity('/app','17'),emptyLegacy=JSON.stringify(['1','','']);
assert.equal(identityApi.sameJdkSlotIdentity(absent,emptyLegacy),true);files.set('/app/jdk/17/.amcl_release_tag',Buffer.alloc(0));files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.alloc(0));const empty=identityApi.jdkSlotIdentity('/app','17');assert.equal(identityApi.sameJdkSlotIdentity(absent,empty),false);assert.equal(identityApi.sameJdkSlotIdentity(empty,emptyLegacy),true);passed++;
// 类型/超限/短读/真实I/O异常一律保留为未知，不得吞掉并伪造成“没有receipt”。
setup();const lstat=io.lstatSync;io.lstatSync=p=>p.endsWith('/.amcl-runtime-receipt.json')?{isFile:()=>false,size:10}:lstat(p);try{assert.throws(()=>identityApi.jdkSlotIdentity('/app','17'),/元数据类型或大小/);}finally{io.lstatSync=lstat;}passed++;
setup();files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.alloc(1048577));assert.throws(()=>identityApi.jdkSlotIdentity('/app','17'),/元数据类型或大小/);passed++;
setup();const read=io.readSync;io.readSync=()=>0;try{assert.throws(()=>identityApi.jdkSlotIdentity('/app','17'),/未完整读取/);}finally{io.readSync=read;}passed++;
setup();io.lstatSync=p=>{if(p.endsWith('/.amcl-runtime-receipt.json'))throw Error('EIO');return lstat(p);};try{assert.throws(()=>identityApi.jdkSlotIdentity('/app','17'),/EIO/);}finally{io.lstatSync=lstat;}passed++;
setup();await Bridge.prepare(context,'legacy-identity',target);let legacyPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));legacyPlan.entries[0].before=legacyBefore;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(legacyPlan)));
Bridge.markAppSigned(context,'legacy-identity',target,signedPath('legacy-identity'));await Bridge.restore(context,'legacy-identity',target);
const legacyEffect=JSON.stringify(['1',files.get('/app/jdk/17/.amcl_release_tag').toString(),files.get('/app/jdk/17/.amcl-runtime-receipt.json').toString()]);
const legacyConfig=JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].replacement;replacementId='compatible-host1-fixed';await Bridge.prepare(context,'legacy-identity',target);
legacyPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));legacyPlan.entries[0].history[0]={from:legacyBefore,replacement:legacyConfig,installedIdentity:legacyEffect};legacyPlan.entries[0].activeFrom=legacyEffect;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(legacyPlan)));
await Bridge.prepare(context,'legacy-identity',target);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].before,legacyBefore);Bridge.markAppSigned(context,'legacy-identity',target,signedPath('legacy-identity'));await Bridge.restore(context,'legacy-identity',target);Bridge.verified(context,'legacy-identity',target);assert.equal(Bridge.pending(context),false);passed++;
// 独立审查的合法大清单经真实Installer形成178KiB收据，重规划仍须走到Verified，而非放大before限制。
const smallConfig=Manager.prototype.compatibilityConfig;
function actualReplacement(){
  const c=config(),r=structuredClone(fixtureBase.runtimes.find(r=>r.javaMajor===17)),b=structuredClone(fixtureBase.builds.find(b=>b.runtimeId===r.id&&b.provenance.kind==='source-build'));
  r.minimumCatalogProtocol=2;r.recommendedBuildIds=[replacementId];delete r.recommendedBuildId;delete r.loaderProtocol;
  b.id=replacementId;b.requiredHostProtocol=1;b.legacyTags=[];b.validationLevel='device-matrix-tested';b.archive={type:'zip',fileName:'runtime.zip',sizeBytes:data.length,sha256:hash(data)};
  b.notes=Array.from({length:24},()=> '中'.repeat(1000));b.provenance.evidence=Array.from({length:24},()=> '证'.repeat(1000));
  const parts=Array.from({length:16},(_,i)=>({url:'https://gitee.com/fixture/'+i+'a'.repeat(1950),sizeBytes:i===15?data.length-15:1,sha256:'c'.repeat(64)}));
  b.downloads=[{sourceId:'github',transport:'single-file',url:'https://github.com/test.zip'},{sourceId:'gitee',transport:'concat-parts',parts}];return {...c,tag:replacementId,runtime:r,build:b,downloads:b.downloads};
}
setup();Manager.prototype.compatibilityConfig=actualReplacement;let largeResult;
try{
  const actual=actualReplacement(),catalog={schemaVersion:2,channel:'preview',catalogRevision:2,issuedAt:fixtureBase.issuedAt,expiresAt:fixtureBase.expiresAt,runtimes:[actual.runtime],builds:[actual.build]};
  load('launch/src/main/ets/RuntimeCatalogValidation.ets').parseRuntimeCatalog(JSON.stringify(catalog),'preview');const envelopeBytes=signedCatalogBytes(catalog);assert(envelopeBytes<1048576);
  await Bridge.prepare(context,'large-receipt',target);Bridge.markAppSigned(context,'large-receipt',target,signedPath('large-receipt'));await Bridge.restore(context,'large-receipt',target);
  const receiptBytes=files.get('/app/jdk/17/.amcl-runtime-receipt.json').length;assert(receiptBytes>65536&&receiptBytes<1048576);const original=JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].before;
  replacementId='compatible-host1-fixed';await Bridge.prepare(context,'large-receipt',target);const p=JSON.parse(files.get('/app/update-runtime-plan.json')),historyBytes=Buffer.byteLength(JSON.stringify(p.entries[0].history));
  assert.equal(p.entries[0].before,original);assert(historyBytes<4096);assert(p.entries[0].activeFrom.length<1024);const planBytes=files.get('/app/update-runtime-plan.json').length;assert(planBytes<1048576);
  Bridge.markAppSigned(context,'large-receipt',target,signedPath('large-receipt'));await Bridge.restore(context,'large-receipt',target);Bridge.verified(context,'large-receipt',target);assert.equal(Bridge.pending(context),false);largeResult={envelopeBytes,receiptBytes,historyBytes,planBytes};passed++;
}finally{Manager.prototype.compatibilityConfig=smallConfig;}
// 更高人工维修App结束的是原计划的Superseded结果，不能冒用旧目标Verified。
const superseder={product:'sideload',versionName:'1.0.7',versionCode:1000911,sourceRevision:'c'.repeat(40),uid:1001,runtimeHostProtocols:[1,2]};
setup();Bridge.superseded(context,'no-plan',target,superseder);assert.equal(Bridge.pending(context),false);passed++;
setup();await Bridge.prepare(context,'superseded-before',target);Bridge.superseded(context,'superseded-before',target,superseder);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(Bridge.pending(context),false);passed++;
setup();await Bridge.prepare(context,'superseded-restored',target);Bridge.markAppSigned(context,'superseded-restored',target,signedPath('superseded-restored'));await Bridge.restore(context,'superseded-restored',target);Bridge.superseded(context,'superseded-restored',target,{...superseder,runtimeHostProtocols:[2,1]});assert.equal(Bridge.pending(context),false);passed++;
// 原计划已重规划而当前仍停在历史已知效果，更高App兼容它时也可结束；不执行旧撤回包。
setup();await Bridge.prepare(context,'superseded-history',target);Bridge.markAppSigned(context,'superseded-history',target,signedPath('superseded-history'));await Bridge.restore(context,'superseded-history',target);replacementId='compatible-host1-fixed';await Bridge.prepare(context,'superseded-history',target);Bridge.superseded(context,'superseded-history',target,superseder);assert.equal(Bridge.pending(context),false);passed++;
for(const change of [{versionCode:target.versionCode},{versionCode:target.versionCode-1},{product:'desktop'},{sourceRevision:''},{uid:0},{runtimeHostProtocols:[1]},{runtimeHostProtocols:[1,2,2]}]){
  setup();await Bridge.prepare(context,'superseded-invalid',target);assert.throws(()=>Bridge.superseded(context,'superseded-invalid',target,{...superseder,...change}),/取代App/);assert.equal(Bridge.pending(context),true);passed++;
}
setup();await Bridge.prepare(context,'superseded-binding',target);assert.throws(()=>Bridge.superseded(context,'another-id',target,superseder),/其他原件/);assert.throws(()=>Bridge.superseded(context,'superseded-binding',{...target,sha256:'f'.repeat(64)},superseder),/其他原件/);assert.equal(Bridge.pending(context),true);passed++;
setup();await Bridge.prepare(context,'superseded-unknown',target);Bridge.markAppSigned(context,'superseded-unknown',target,signedPath('superseded-unknown'));await Bridge.restore(context,'superseded-unknown',target);files.set('/app/jdk/17/.amcl_release_tag',Buffer.from('unknown-effect'));assert.throws(()=>Bridge.superseded(context,'superseded-unknown',target,superseder),/未知或不兼容/);assert.equal(Bridge.pending(context),true);passed++;
setup();await Bridge.prepare(context,'superseded-receipt-drift',target);Bridge.markAppSigned(context,'superseded-receipt-drift',target,signedPath('superseded-receipt-drift'));await Bridge.restore(context,'superseded-receipt-drift',target);const receiptDrift=JSON.parse(files.get('/app/jdk/17/.amcl-runtime-receipt.json'));receiptDrift.build.notes=['unknown metadata drift'];files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from(JSON.stringify(receiptDrift)));assert.throws(()=>Bridge.superseded(context,'superseded-receipt-drift',target,superseder),/未知或不兼容/);assert.equal(Bridge.pending(context),true);passed++;
setup();await Bridge.prepare(context,'superseded-host',target);const installedCheck=Manager.prototype.isInstalled;Manager.prototype.isInstalled=()=>false;try{assert.throws(()=>Bridge.superseded(context,'superseded-host',target,superseder),/未知或不兼容/);assert.equal(Bridge.pending(context),true);}finally{Manager.prototype.isInstalled=installedCheck;}passed++;
setup();await Bridge.prepare(context,'superseded-slotset',target);const inventory=Manager.prototype.listVersions;Manager.prototype.listVersions=()=>[{version:'17'},{version:'21'}];try{assert.throws(()=>Bridge.superseded(context,'superseded-slotset',target,superseder),/槽位集合/);assert.equal(Bridge.pending(context),true);}finally{Manager.prototype.listVersions=inventory;}passed++;
setup();await Bridge.prepare(context,'superseded-journal',target);ensure('/app/jdk/.locks');files.set('/app/jdk/.locks/21.journal',Buffer.from('unknown'));assert.throws(()=>Bridge.superseded(context,'superseded-journal',target,superseder),/未知恢复现场/);assert.equal(files.get('/app/jdk/.locks/21.journal').toString(),'unknown');assert.equal(Bridge.pending(context),true);passed++;
// Native恢复失败或仍有未决记录都不能清账；此处只替换Native存在性/恢复结果，不替换桥判定。
for(const recovery of ['failed','pending']){
  setup();await Bridge.prepare(context,'superseded-recovery',target);const pending=ActualStorage.recoveryRequired,recover=ActualStorage.recoverWithWriter;
  ActualStorage.recoveryRequired=()=>true;ActualStorage.recoverWithWriter=()=>{if(recovery==='failed')throw Error('native recovery failed');};
  try{assert.throws(()=>Bridge.superseded(context,'superseded-recovery',target,superseder),/recovery failed|单槽恢复尚未完成/);assert.equal(Bridge.pending(context),true);}finally{ActualStorage.recoveryRequired=pending;ActualStorage.recoverWithWriter=recover;}passed++;
}
// 桥已完成unlink但父目录同步失败：可信Superseded调用重放无plan分支，必须再次同步后才返回。
setup();await Bridge.prepare(context,'superseded-sync',target);const originalSync=io.fsyncSync;let syncFailure=true;
io.fsyncSync=fd=>{if(syncFailure&&handles.get(fd)?.p==='/app'){syncFailure=false;throw Error('superseded directory sync failed');}return originalSync(fd);};
try{assert.throws(()=>Bridge.superseded(context,'superseded-sync',target,superseder),/directory sync failed/);assert.equal(Bridge.pending(context),false);Bridge.superseded(context,'superseded-sync',target,superseder);}finally{io.fsyncSync=originalSync;}passed++;
// Reader版本独立于宿主协议：新切槽必须plan2，未知reader不被数字大小默认为兼容。
for(const reader of [0,1]){setup();await assert.rejects(Bridge.prepare(context,'reader-new-'+reader,{...target,runtimePlanProtocol:reader}),/reader协议2/);assert.equal(Bridge.pending(context),false);assert.equal(requests.length,0);passed++;}
setup();await assert.rejects(Bridge.prepare(context,'reader-unknown',{...target,runtimePlanProtocol:3}),/宿主能力身份/);passed++;
function sizedReceipt(size){const value={schemaVersion:1,build:{requiredHostProtocol:2},runtime:{loaderProtocol:2},padding:''};value.padding='x'.repeat(size-Buffer.byteLength(JSON.stringify(value)));return Buffer.from(JSON.stringify(value));}
// 无需切槽的普通旧App仍可用；但已有大receipt不能在更新后留给0/1 reader。
for(const reader of [0,1]){
  setup();const ordinary={...target,runtimePlanProtocol:reader,runtimeHostProtocols:[1,2]};await Bridge.prepare(context,'reader-ordinary-'+reader,ordinary);assert.equal(Bridge.pending(context),false);
  files.set('/app/jdk/17/.amcl-runtime-receipt.json',sizedReceipt(65536));Bridge.assertTargetDataCompatibility(context,ordinary);
  files.set('/app/jdk/17/.amcl-runtime-receipt.json',sizedReceipt(65537));files.set('/app/runtime-app-intent.json',Buffer.from('intent-owned-by-App'));
  assert.throws(()=>Bridge.assertTargetDataCompatibility(context,ordinary),/读取能力不足/);await assert.rejects(Bridge.prepare(context,'reader-ordinary-'+reader,ordinary),/读取能力不足/);
  assert.equal(Bridge.pending(context),false);assert.equal(files.get('/app/runtime-app-intent.json').toString(),'intent-owned-by-App');passed++;
}
setup();files.set('/app/jdk/17/.amcl-runtime-receipt.json',sizedReceipt(receiptLimit));Bridge.assertTargetDataCompatibility(context,{...target,runtimeHostProtocols:[1,2]});files.set('/app/jdk/17/.amcl-runtime-receipt.json',sizedReceipt(receiptLimit+1));assert.throws(()=>Bridge.assertTargetDataCompatibility(context,{...target,runtimeHostProtocols:[1,2]}),/元数据类型或大小/);passed++;
// 最终EX内重核必须再次看当前物理数据；阶段标签/先前prepare不构成新数据许可。
setup();const oldOrdinary={...target,runtimePlanProtocol:1,runtimeHostProtocols:[1,2]};await Bridge.prepare(context,'reader-recheck',oldOrdinary);files.set('/app/jdk/17/.amcl-runtime-receipt.json',sizedReceipt(70000));await assert.rejects(Bridge.restore(context,'reader-recheck',oldOrdinary),/读取能力不足/);passed++;
setup();const storagePending=ActualStorage.recoveryRequired;ActualStorage.recoveryRequired=()=>true;try{assert.throws(()=>Bridge.assertTargetDataCompatibility(context,target),/单槽恢复尚未完成/);}finally{ActualStorage.recoveryRequired=storagePending;}passed++;
// 既有plan1保原binding继续小包恢复；夹具仅将已持久化目标reader设为旧记录的1。
setup();await Bridge.prepare(context,'reader-existing',target);let oldPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));oldPlan.target.runtimePlanProtocol=1;const oldTarget={...target,runtimePlanProtocol:1};const oldBefore=oldPlan.entries[0].before;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(oldPlan)));
await Bridge.prepare(context,'reader-existing',oldTarget);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).target.runtimePlanProtocol,1);assert.equal(JSON.parse(files.get('/app/update-runtime-plan.json')).entries[0].before,oldBefore);Bridge.markAppSigned(context,'reader-existing',oldTarget,signedPath('reader-existing'));await Bridge.restore(context,'reader-existing',oldTarget);Bridge.verified(context,'reader-existing',oldTarget);assert.equal(Bridge.pending(context),false);passed++;
// 旧plan1的冻结大收据不能新增发布；有序推荐可跳过大项，选择旧reader可读的小项继续至终态。
const originalSnapshot=catalogRepository.snapshot,originalCompatibility=Manager.prototype.compatibilityConfig;
for(const installed of [false,true]){
  setup();replacementId='reader-large';const large=actualReplacement(),small=smallConfig.call(new Manager());small.tag='reader-small';small.build={id:'reader-small',requiredHostProtocol:1};
  const current=originalSnapshot();current.runtimes[0].recommendedBuildIds=['reader-large','reader-small'];current.builds=[...['reader-large','reader-small'].map(id=>({id,runtimeId:'java17-ohos-aarch64',status:'available',requiredHostProtocol:1,validationLevel:'device-matrix-tested',provenance:{kind:'source-build',manifestSha256:'c'.repeat(64)},archive:{sha256:hash(data),sizeBytes:data.length}}))];
  catalogRepository.snapshot=()=>structuredClone(current);Manager.prototype.compatibilityConfig=(_major,id)=>structuredClone(id==='reader-large'?large:small);
  try{
    await Bridge.prepare(context,'reader-replan-'+installed,target);if(installed){Bridge.markAppSigned(context,'reader-replan-'+installed,target,signedPath('reader-replan-'+installed));await Bridge.restore(context,'reader-replan-'+installed,target);}
    oldPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));oldPlan.target.runtimePlanProtocol=1;const before=oldPlan.entries[0].before;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(oldPlan)));
    await Bridge.prepare(context,'reader-replan-'+installed,oldTarget);const repaired=JSON.parse(files.get('/app/update-runtime-plan.json'));assert.equal(repaired.target.runtimePlanProtocol,1);assert.equal(repaired.entries[0].before,before);assert.equal(repaired.entries[0].replacement.build.id,'reader-small');
    Bridge.markAppSigned(context,'reader-replan-'+installed,oldTarget,signedPath('reader-replan-'+installed));await Bridge.restore(context,'reader-replan-'+installed,oldTarget);assert(files.get('/app/jdk/17/.amcl-runtime-receipt.json').length<=65536);Bridge.verified(context,'reader-replan-'+installed,oldTarget);assert.equal(Bridge.pending(context),false);passed++;
  }finally{catalogRepository.snapshot=originalSnapshot;Manager.prototype.compatibilityConfig=originalCompatibility;}
}
// 旧plan1的不变大收据槽也有可达修复路径，原before保持legacy原文，不在最后安装时才堵死。
setup();ensure('/app/jdk/21');files.set('/app/jdk/21/valid',Buffer.from('old21'));files.set('/app/jdk/21/.amcl_release_tag',Buffer.from('installed-host2'));files.set('/app/jdk/21/.amcl-runtime-receipt.json',Buffer.from(JSON.stringify({build:{requiredHostProtocol:2},runtime:{loaderProtocol:2}})));
const knownLarge=actualReplacement();knownLarge.build.provenance.evidence=[];knownLarge.build.downloads=[{sourceId:'github',transport:'single-file',url:'https://github.com/test.zip'}];
const legacyData=receiptCodec.serializeRuntimeInstallReceipt(knownLarge.runtime,knownLarge.build,17,knownLarge.sha256,knownLarge.sizeBytes,new Date().toISOString());assert(Buffer.byteLength(legacyData)>65536&&legacyData.length<65536);files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from(legacyData));
const legacyOriginal=JSON.stringify(['1',files.get('/app/jdk/17/.amcl_release_tag').toString(),legacyData]);const versions=Manager.prototype.listVersions;
Manager.prototype.listVersions=()=>['17','21'].map(version=>({version,installed:true,userImported:false,installedTag:'installed-host2'}));
Manager.prototype.compatibilityConfig=(major,id)=>{const value=smallConfig.call(new Manager());value.tag=id;value.runtime={...value.runtime,id:'java'+major+'-ohos-aarch64',javaMajor:Number(major),loaderProtocol:1};value.build={id,requiredHostProtocol:1};return value;};
catalogRepository.snapshot=()=>({schemaVersion:2,runtimes:['17','21'].map(major=>({id:'java'+major+'-ohos-aarch64',javaMajor:Number(major),recommendedBuildIds:['reader-small-'+major]})),builds:[knownLarge.build,...['17','21'].map(major=>({id:'reader-small-'+major,runtimeId:'java'+major+'-ohos-aarch64',status:'available',requiredHostProtocol:1,validationLevel:'device-matrix-tested',provenance:{kind:'source-build',manifestSha256:'c'.repeat(64)},archive:{sha256:hash(data),sizeBytes:data.length}}))]});
try{
  await Bridge.prepare(context,'reader-unchanged',target);oldPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));oldPlan.target.runtimePlanProtocol=1;oldPlan.entries.find(e=>e.major==='17').before=legacyOriginal;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(oldPlan)));
  await Bridge.prepare(context,'reader-unchanged',oldTarget);const corrected=JSON.parse(files.get('/app/update-runtime-plan.json'));assert.equal(corrected.entries.find(e=>e.major==='17').before,legacyOriginal);assert.equal(corrected.entries.find(e=>e.major==='17').replacement.build.id,'reader-small-17');
  Bridge.markAppSigned(context,'reader-unchanged',oldTarget,signedPath('reader-unchanged'));await Bridge.restore(context,'reader-unchanged',oldTarget);Bridge.verified(context,'reader-unchanged',oldTarget);assert.equal(Bridge.pending(context),false);passed++;
}finally{Manager.prototype.listVersions=versions;Manager.prototype.compatibilityConfig=originalCompatibility;catalogRepository.snapshot=originalSnapshot;}
// 没有小收据替代时，旧plan1只能明确保留，不得继续发布原大收据或改写目标reader为2。
setup();replacementId='reader-large';const onlyLarge=actualReplacement();const largeOnlySnapshot=originalSnapshot();
catalogRepository.snapshot=()=>structuredClone(largeOnlySnapshot);Manager.prototype.compatibilityConfig=()=>structuredClone(onlyLarge);
try{
  await Bridge.prepare(context,'reader-no-small',target);oldPlan=JSON.parse(files.get('/app/update-runtime-plan.json'));oldPlan.target.runtimePlanProtocol=1;files.set('/app/update-runtime-plan.json',Buffer.from(JSON.stringify(oldPlan)));Bridge.markAppSigned(context,'reader-no-small',oldTarget,signedPath('reader-no-small'));const before=files.get('/app/update-runtime-plan.json').toString(),calls=requests.length;
  await assert.rejects(Bridge.prepare(context,'reader-no-small',oldTarget),/reader预算变化/);await assert.rejects(Bridge.restore(context,'reader-no-small',oldTarget),/目标reader预算改变/);
  assert.equal(files.get('/app/update-runtime-plan.json').toString(),before);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(requests.length,calls);assert.equal(Bridge.pending(context),true);passed++;
}finally{catalogRepository.snapshot=originalSnapshot;Manager.prototype.compatibilityConfig=originalCompatibility;}
assert.equal(handles.size,0);assert.equal(leases,0);console.log(JSON.stringify({passed:passed+lateJournal.passed,planCases:passed,lateJournal,largeResult,scope:'production AppJdkUpdatePlanRuntime + JdkInstaller; plan2/legacy reader budgets, shared producer codec, compact identities and terminal recovery; SDK/DM/Manager boundaries; injected host pair'},null,2));
`;
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
await new AsyncFunction('assert','createHash','makePureEtsLoader','fixtureBase','signedCatalogBytes','lateJournal',harness+body)(assert,createHash,makePureEtsLoader,fixtureBase,signedCatalogBytes,lateJournal);

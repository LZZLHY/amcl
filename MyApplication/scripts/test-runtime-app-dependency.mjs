/**
 * 真实耐久意图/AtomicWriter的代次、完成和admission故障回归。平台只替换Kit文件映射、
 * 真实宿主集合与Manager资格port；不会把这些假JDK文件当作实际JVM/真机运行证明。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {fixture} from './lib/sideload-coordinator-fixture.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const f=await fixture(),context=f.context,io=f.kitfs;let protocols=[1],eligible=false;
const atomic=f.load('commons/src/main/ets/utils/AtomicFileWriter.ets');
const dependencies={'@kit.CoreFileKit':{fileIo:io},'@kit.ArkTS':{util:{generateRandomUUID:()=>crypto.randomUUID()}},
  commons:{...atomic,...f.load('commons/src/main/ets/utils/Base64Util.ets')},'./RuntimeCatalogRepository':{},'./RuntimeHostProtocol':{runtimeHostProtocols:()=>protocols}};
const load=makePureEtsLoader(dependencies),api=load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
const validation=load('launch/src/main/ets/RuntimeCatalogValidation.ets');
const c={schemaVersion:2,channel:'preview',runtimes:[{id:'java17',javaMajor:17,recommendedBuildIds:['new2','old1']}],
  builds:[{id:'new2',runtimeId:'java17',requiredHostProtocol:2,status:'available',archive:{sha256:'a'.repeat(64),sizeBytes:100}},
    {id:'old1',runtimeId:'java17',requiredHostProtocol:1,status:'available',archive:{sha256:'b'.repeat(64),sizeBytes:101}}]};
const repository={snapshot:()=>structuredClone(c),recommendationUnavailableReason:()=>'',isBuildAllowed:id=>c.builds.find(b=>b.id===id)?.status==='available',
  buildFor:major=>{const runtime=c.runtimes.find(r=>String(r.javaMajor)===major);return runtime&&validation.runtimeBuildForHost(c,runtime,protocols);}};
const manager={isInstalled:()=>eligible},intentPath=context.filesDir+'/runtime-app-intent.json';
const binding={transactionId:'b'.repeat(32),assetSha256:'c'.repeat(64),product:'sideload',versionName:'2.0.0',versionCode:2};
const event=generation=>({...binding,installId:'d'.repeat(32),sourceRevision:'e'.repeat(40),uid:42,verifiedAt:Date.now()+1,runtimeIntentId:generation});
const read=()=>JSON.parse(io.readTextSync(intentPath));
function remember(){protocols=[1];eligible=false;return api.remember(context,repository,api.requirements(repository,['17']));}
function confirmed(){const generation=remember();api.bindApp(context,generation,binding);api.markAppVerified(context,event(generation));protocols=[1,2];return generation;}
function receipt(major='17',buildId='new2',sha='a'.repeat(64),size=100){const directory=f.mapped('/sandbox/jdk/'+major);fs.mkdirSync(directory,{recursive:true});
  fs.writeFileSync(directory+'/.amcl-runtime-receipt.json',JSON.stringify({schemaVersion:1,origin:'catalog',javaMajor:Number(major),runtimeId:'java'+major,buildId,archiveSha256:sha,archiveSizeBytes:size}));}
let passed=0;
{
  const generation=remember();assert.match(generation,/^[0-9a-f]{32}$/);assert.equal(api.hasVerifiedIntent(context),false);
  assert.throws(()=>api.markAppVerified(context,event(generation)),/不匹配/,'unbound historic success cannot authorize a new choice');
  api.bindApp(context,generation,binding);assert.throws(()=>api.bindApp(context,generation,{...binding,transactionId:'f'.repeat(32)}),/另一App/);
  api.markAppVerified(context,event(generation));protocols=[1,2];assert.equal(api.hasVerifiedIntent(context),true);
  const first=api.takeIfCompatible(context,repository,'preview'),second=api.takeIfCompatible(context,repository,'preview');
  assert.equal(first.kind,'ready');assert.deepEqual(first.items,second.items);assert.equal(read().generation,generation);passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0];
  const token=api.beginDelivery(context,generation,item);assert.match(token,/^[0-9a-f]{32}$/);assert.equal(api.beginDelivery(context,generation,item),'');
  // 预约后/producer开始前的死亡：新模块只读同一真实文件，必须保留并要求明确重试。
  const cold=makePureEtsLoader(dependencies)('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  assert.equal(cold.takeIfCompatible(context,repository,'preview').kind,'interrupted');
  cold.retryInterrupted(context,generation,['17']);const retry=cold.beginDelivery(context,generation,item);assert.notEqual(retry,token);
  cold.completeDelivery(context,generation,item,retry,repository,manager,'failed','admission refused');
  assert.equal(cold.takeIfCompatible(context,repository,'preview').kind,'interrupted');assert.equal(read().intents[0].state,'retry');passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],token=api.beginDelivery(context,generation,item);
  api.completeDelivery(context,generation,item,token,repository,manager,'aborted');assert.equal(read().phase,'complete');
  assert.equal(api.takeIfCompatible(context,repository,'preview').kind,'none','resolved ABORTED cannot restart automatically');passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],token=api.beginDelivery(context,generation,item);
  assert.throws(()=>api.completeDelivery(context,generation,item,token,repository,manager,'done'),/未核实/);
  receipt();eligible=true;api.completeDelivery(context,generation,item,token,repository,manager,'done');assert.equal(read().phase,'complete');
  assert.equal(api.takeIfCompatible(context,repository,'preview').kind,'none');passed++;
}
{
  const old=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],token=api.beginDelivery(context,old,item);
  const fresh=confirmed();receipt();eligible=true;assert.equal(api.completeDelivery(context,old,item,token,repository,manager,'done'),false);
  assert.equal(read().generation,fresh);assert.equal(read().intents[0].state,'pending');
  api.reconcileInstalled(context,repository,manager);assert.equal(read().phase,'complete','only the new generation reconciles its own installed target');passed++;
}
{
  const old=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],token=api.beginDelivery(context,old,item);
  c.builds[0].archive.sha256='f'.repeat(64);const fresh=confirmed();
  assert.equal(api.completeDelivery(context,old,item,token,repository,manager,'failed','late'),false);assert.equal(read().generation,fresh);assert.equal(read().intents[0].state,'pending');
  c.builds[0].archive.sha256='a'.repeat(64);passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],token=api.beginDelivery(context,generation,item);
  receipt();eligible=true;c.builds[0].status='withdrawn';assert.throws(()=>api.completeDelivery(context,generation,item,token,repository,manager,'done'),/未核实/);
  assert.equal(read().intents[0].state,'delivering');c.builds[0].status='available';api.reconcileInstalled(context,repository,manager);assert.equal(read().phase,'complete');passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],rename=io.renameSync;
  io.renameSync=(a,b)=>{if(b===intentPath)throw Error('disk refused before publish');return rename(a,b);};
  assert.throws(()=>api.beginDelivery(context,generation,item));io.renameSync=rename;assert.equal(read().intents[0].state,'pending');passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0],open=io.openSync,sync=io.fsyncSync,dirs=new Set();let fail=true;
  io.openSync=(p,m)=>{const file=open(p,m);if(p===context.filesDir)dirs.add(file.fd);return file;};
  io.fsyncSync=fd=>{if(fail&&dirs.has(fd))throw Error('directory sync interrupted');return sync(fd);};
  assert.throws(()=>api.beginDelivery(context,generation,item));fail=false;io.openSync=open;io.fsyncSync=sync;
  assert.equal(read().intents[0].state,'delivering');assert.equal(api.takeIfCompatible(context,repository,'preview').kind,'interrupted');passed++;
}
{
  const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0];api.beginDelivery(context,generation,item);
  // producer已提交但ack尚未执行即死亡：只靠实际Manager和原build/SHA收据认领，不重复安装。
  receipt();eligible=true;api.reconcileInstalled(context,repository,manager);assert.equal(read().phase,'complete');passed++;
}
{
  confirmed();const raw=read();raw.generation=null;fs.writeFileSync(f.mapped(intentPath),JSON.stringify(raw));assert.throws(()=>api.hasVerifiedIntent(context),/格式|绑定/);
  fs.writeFileSync(f.mapped(intentPath),JSON.stringify({schemaVersion:1,appVerified:true,intents:[]}));assert.throws(()=>api.hasVerifiedIntent(context),/旧JDK/);passed++;
}
{
  confirmed();const raw=read();raw.createdAt-=86400001;fs.writeFileSync(f.mapped(intentPath),JSON.stringify(raw));assert.equal(api.takeIfCompatible(context,repository,'preview').kind,'changed');
  assert.equal(io.accessSync(intentPath),true,'expired choice is retained for explicit recovery/reselection');passed++;
}
{
  const generation=remember();api.bindApp(context,generation,binding);
  api.markAppVerified(context,{...event(generation),verifiedAt:Date.now()-3600000});
  assert.equal(api.hasVerifiedIntent(context),true,'wall clock rollback cannot revoke the exact generation and transaction completion');passed++;
}
f.coordinator.setAbilityForeground(false);console.log(JSON.stringify({passed,scope:'production AtomicWriter, generation/App binding, durable reservation, failed admission/cold ack/ABORTED/withdrawal; no JVM/device execution'},null,2));

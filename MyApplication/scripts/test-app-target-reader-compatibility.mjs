/**
 * 真实意图writer与Coordinator验证目标旧reader准入：active不丢、完成原件先归档后移出，
 * 最终EX/fence内重核关闭签名后竞入窗口。平台安装/JDK资格仍为显式port，不替代设备。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fixture,settle,target} from './lib/sideload-coordinator-fixture.mjs';
const intent='/sandbox/runtime-app-intent.json',fence='/sandbox/sideload-update/install-fence.json';
const repository={recommendationUnavailableReason:()=>'',snapshot:()=>({schemaVersion:2,channel:'preview',runtimes:[{id:'java17',javaMajor:17,recommendedBuildIds:['new2']}],
  builds:[{id:'new2',runtimeId:'java17',requiredHostProtocol:2,status:'available',archive:{sha256:'a'.repeat(64),sizeBytes:100}}]}),isBuildAllowed:()=>true};
function active(f){f.environment.hostProtocols=[1];const api=f.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  const generation=api.remember(f.context,repository,api.requirements(repository,['17']));return {api,generation};}
function arm(f){fs.writeFileSync(f.mapped(fence),JSON.stringify({schema:2,protocol:2,state:'preparing',installId:'b'.repeat(32),nonce:'c'.repeat(32)}));}
function complete(f,api,generation){const raw=JSON.parse(f.kitfs.readTextSync(intent));raw.phase='complete';raw.intents[0].state='cancelled';fs.writeFileSync(f.mapped(intent),JSON.stringify(raw));}
let passed=0;
{
  const f=await fixture(),{api}=active(f),before=f.kitfs.readTextSync(intent);arm(f);
  for(const protocol of [0,1]){assert.throws(()=>api.assertTargetCompatibility(f.context,protocol),/旧版/);assert.throws(()=>api.prepareTarget(f.context,protocol),/旧版/);assert.equal(f.kitfs.readTextSync(intent),before);}
  api.prepareTarget(f.context,2);assert.equal(f.kitfs.readTextSync(intent),before);assert.throws(()=>api.prepareTarget(f.context,3),/无效/);
  assert.throws(()=>api.remember(f.context,repository,api.requirements(repository,['17'])),/安装尚未完成/,'durable fence prevents a later generation entering after final compatibility check');
  f.coordinator.setAbilityForeground(false);passed++;
}
{
  const f=await fixture(),{api,generation}=active(f);complete(f,api,generation);const before=f.kitfs.readTextSync(intent);arm(f);
  api.prepareTarget(f.context,1);assert.equal(f.kitfs.accessSync(intent),false);
  const archives=f.kitfs.listFileSync('/sandbox').filter(name=>name.includes('.legacy-return-'));assert.equal(archives.length,1);assert.equal(f.kitfs.readTextSync('/sandbox/'+archives[0]),before);
  api.prepareTarget(f.context,0);assert.equal(f.kitfs.listFileSync('/sandbox').filter(name=>name.includes('.legacy-return-')).length,1,'retry with absent fixed entry is idempotent');
  f.coordinator.setAbilityForeground(false);passed++;
}
{
  const f=await fixture(),{api,generation}=active(f);complete(f,api,generation);arm(f);const before=f.kitfs.readTextSync(intent),rename=f.kitfs.renameSync;
  f.kitfs.renameSync=(a,b)=>{if(b.includes('.legacy-return-'))throw Error('archive publish failed');return rename(a,b);};
  assert.throws(()=>api.prepareTarget(f.context,1),error=>error.kind==='not-committed');assert.equal(f.kitfs.readTextSync(intent),before,'archive failure never deletes original');
  f.kitfs.renameSync=rename;api.prepareTarget(f.context,1);f.coordinator.setAbilityForeground(false);passed++;
}
{
  const f=await fixture(),{api,generation}=active(f);complete(f,api,generation);arm(f);const unlink=f.kitfs.unlinkSync,sync=f.kitfs.fsyncSync;let removed=false,synced=0;
  f.kitfs.unlinkSync=p=>{unlink(p);if(p===intent)removed=true;};f.kitfs.fsyncSync=fd=>{if(removed)throw Error('post unlink directory sync failed');return sync(fd);};
  assert.throws(()=>api.prepareTarget(f.context,1),/directory/);assert.equal(f.kitfs.accessSync(intent),false);
  f.kitfs.fsyncSync=fd=>{synced++;return sync(fd);};api.prepareTarget(f.context,1);assert(synced>0,'absent-file retry still confirms parent-directory persistence');
  f.coordinator.setAbilityForeground(false);passed++;
}
{
  const original=JSON.stringify({schemaVersion:1,channel:'preview',appVerified:false,intents:[]}),f=await fixture({initialIntent:original}),api=f.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  arm(f);assert.throws(()=>api.prepareTarget(f.context,1),/旧JDK许可/);assert.equal(f.kitfs.readTextSync(intent),original,'old schema1 is preserved until explicit abandonment');
  api.archiveLegacy(f.context,original);api.prepareTarget(f.context,1);assert.equal(f.kitfs.accessSync(intent),false,'explicitly archived old permission can leave the old reader entry safely');f.coordinator.setAbilityForeground(false);passed++;
}
{
  const f=await fixture({revokeProofKind:'no-invocation'}),api=f.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  const executor=f.coordinator.executor,prepare=executor.prepare.bind(executor);executor.prepare=async(...args)=>{
    active(f);await prepare(...args);
  };
  const ui=f.render();await settle();assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,0,'post-sign new active intent is rejected under EX/fence before BMS dispatch');
  assert.match(f.coordinator.snapshot().message,/旧版/);assert.equal(JSON.parse(f.kitfs.readTextSync(intent)).phase,'active');assert.equal(f.counters.planRestored??0,0,'active permission blocks before any JDK slot restoration');
  const abandoned=api.unconfirmedIntent(f.context);assert(abandoned);api.archiveUnusable(f.context,abandoned.body);assert.equal(JSON.parse(f.kitfs.readTextSync(intent)).phase,'archived');
  ui.dispose();f.coordinator.setAbilityForeground(false);passed++;
}
{
  const asset={...target,runtimePlanProtocol:2},f=await fixture({candidate:{...asset,delivery:{schema:1,ready:true,assets:[asset]}},actualRuntimePlanProtocol:2}),{api}=active(f);
  const before=f.kitfs.readTextSync(intent),ui=f.render();await settle();assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1,'real target declaration2 permits preserving the active schema2 ledger');
  assert.equal(f.coordinator.state().asset.runtimePlanProtocol,2);assert.equal(f.kitfs.readTextSync(intent),before);assert(f.counters.planDataChecked>0);
  ui.dispose();f.coordinator.setAbilityForeground(false);passed++;
}
{
  const f=await fixture(),{api}=active(f),unconfirmed=api.unconfirmedIntent(f.context);api.archiveUnusable(f.context,unconfirmed.body);
  const marker=f.kitfs.readTextSync(intent);arm(f);api.prepareTarget(f.context,1);assert.equal(f.kitfs.accessSync(intent),false,'even a no-permission schema2 marker must leave the old reader entry');
  const archived=f.kitfs.listFileSync('/sandbox').find(name=>name.includes('.legacy-return-'));assert.equal(f.kitfs.readTextSync('/sandbox/'+archived),marker);f.coordinator.setAbilityForeground(false);passed++;
}
const result={passed,scope:'production intent writer/AtomicWriter and Coordinator; platform EX/BMS/JDK metadata ports, no SDK/device qualification'};
if(process.env.AMCL_TEST_OUTPUT_DIR)fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR,'app-target-reader-compatibility-results.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));

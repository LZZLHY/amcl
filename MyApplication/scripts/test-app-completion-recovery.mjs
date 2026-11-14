/**
 * 真实子进程在每个App完成窗口直接exit，父进程按留下的真实journal/意图/fence冷重建。
 * Coordinator/Repository/AtomicWriter/RuntimeAppDependency均运行生产源码；HDC/BMS/JDK计划
 * 仍是显式平台port，不把本组称为手机安装或JDK运行验证。成功后父scope回收自有子目录。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fixture,record,target,payload,settle} from './lib/sideload-coordinator-fixture.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';

function task(intentId){const value=record('confirmation-pending');return {...value,schema:2,revision:1,ownerAttemptId:value.id,
  installProtocol:2,installId:'a'.repeat(32),asset:{...target,runtimeHostProtocols:[1,2],runtimePlanProtocol:1,sourceRevision:payload},
  beforeVersionCode:1,beforeVersionName:'3.0.0-dev1',beforeUid:42,installedIdentityVerified:true,confirmedAt:Date.now(),runtimeIntentId:intentId,requiredHostProtocols:[2],subscriptionRevision:0};}
function terminal(value){return {kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'trusted platform fixture',installId:value.installId,nonce:value.restartNonce};}
const actual={version:2,versionName:'2.0.0',payload,uid:42,hostProtocols:[1,2]};

if(process.argv[2]==='--child'){
  const directory=path.resolve(process.argv[3]),input=JSON.parse(fs.readFileSync(path.join(directory,'input.json'),'utf8'));
  const facts=input.superseded?{...actual,version:3,versionName:'3.0.0',payload:'f'.repeat(40)}:actual;
  const value=task(input.intentId),f=await fixture({journal:value,runtimePlanPending:input.planPending,initialIntent:input.intent,initialEnvironment:facts});
  const identity=f.coordinator.executionIdentity(f.coordinator.state());
  const {InstallFence}=f.load('entry/src/main/ets/sideload/InstallFence.ets');new InstallFence('/sandbox').arm(identity);
  f.storage.set('fixtureAppUpdateChannel','preview');
  const snapshot=()=>{
    const checkpoint={stage:input.stage,journal:JSON.parse(f.kitfs.readTextSync('/sandbox/sideload-update/transaction.json')),
      intent:f.kitfs.accessSync('/sandbox/runtime-app-intent.json')?JSON.parse(f.kitfs.readTextSync('/sandbox/runtime-app-intent.json')):undefined,
      fence:f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json')?f.kitfs.readTextSync('/sandbox/sideload-update/install-fence.json'):undefined,
      planPending:f.runtimePlanApi.pending(f.context),preference:f.storage.get('fixtureAppUpdateChannel'),actual:facts};
    fs.writeFileSync(path.join(directory,'checkpoint.json'),JSON.stringify(checkpoint));process.exit(77);
  };
  const rename=f.kitfs.renameSync;f.kitfs.renameSync=(a,b)=>{
    const next=b.endsWith('/transaction.json')?JSON.parse(f.kitfs.readTextSync(a)):undefined;
    const isFinal=next?.phase==='verified'||next?.phase==='superseded';
    if(input.stage==='before-verified'&&isFinal&&next.completion&&!next.completion.executionReleased)snapshot();
    rename(a,b);
    if(input.stage==='after-verified'&&isFinal&&next.completion&&!next.completion.executionReleased)snapshot();
    if(input.stage==='after-intent-step'&&next?.completion?.intentConfirmed&&!next.completion.done)snapshot();
    if(input.stage==='after-done'&&next?.completion?.done)snapshot();
  };
  const executor=f.coordinator.executor,complete=executor.complete.bind(executor);
  executor.complete=(...args)=>{if(input.stage==='before-fence')snapshot();complete(...args);if(input.stage==='after-fence')snapshot();};
  const planVerified=f.runtimePlanApi.verified;
  f.runtimePlanApi.verified=(...args)=>{if(input.stage==='before-plan')snapshot();planVerified(...args);if(input.stage==='after-plan')snapshot();};
  const superseded=f.runtimePlanApi.superseded;
  f.runtimePlanApi.superseded=(...args)=>{if(input.stage==='before-plan')snapshot();superseded(...args);if(input.stage==='after-plan')snapshot();};
  const put=f.storage.set.bind(f.storage);f.storage.set=(key,value)=>{if(key==='fixtureAppUpdateChannel'&&input.stage==='before-preference')snapshot();
    const result=put(key,value);if(key==='fixtureAppUpdateChannel'&&input.stage==='after-preference')snapshot();return result;};
  const api=f.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency,mark=api.markAppVerified;
  api.markAppVerified=(...args)=>{const result=mark(...args);if(input.stage==='after-intent')snapshot();return result;};
  const supersedeIntent=api.supersedeApp;
  api.supersedeApp=(...args)=>{const result=supersedeIntent(...args);if(input.stage==='after-intent')snapshot();return result;};
  const cleanup=executor.cleanupPayload.bind(executor);executor.cleanupPayload=async(...args)=>{if(input.stage==='remote-cleanup')snapshot();return cleanup(...args);};
  f.setObservation(terminal(value));f.coordinator.setAbilityForeground(true);f.coordinator.recover(value.installId,value.restartNonce);
  for(let i=0;i<10;i++)await settle();throw Error('completion crash checkpoint not reached: '+input.stage+' '+JSON.stringify(f.coordinator.snapshot()));
} else {
  const scope=createHostTestScope('app-completion-death-'),results=[];
  const pre=await fixture({initialEnvironment:{hostProtocols:[1]}}),api=pre.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  const repository={recommendationUnavailableReason:()=>'',snapshot:()=>({schemaVersion:2,channel:'preview',runtimes:[{id:'java17',javaMajor:17,recommendedBuildIds:['new2']}],
    builds:[{id:'new2',runtimeId:'java17',requiredHostProtocol:2,status:'available',archive:{sha256:'f'.repeat(64),sizeBytes:100}}]}),isBuildAllowed:()=>true};
  const generation=api.remember(pre.context,repository,api.requirements(repository,['17'])),original=task(generation);
  api.bindApp(pre.context,generation,{transactionId:original.id,assetSha256:original.asset.sha256,product:original.asset.product,versionName:original.asset.versionName,versionCode:original.asset.versionCode});
  const intent=JSON.parse(pre.kitfs.readTextSync('/sandbox/runtime-app-intent.json'));
  let reference;
  const cases=['before-verified','after-verified','before-fence','after-fence','before-plan','after-plan','before-preference','after-preference','after-intent','after-intent-step','after-done','remote-cleanup'].map(stage=>({stage,superseded:false}));
  cases.push(...['after-verified','after-fence','after-plan','after-done'].map(stage=>({stage,superseded:true})));
  for(const item of cases){const {stage,superseded}=item;
    const directory=path.join(scope.directory,(superseded?'superseded-':'')+stage);fs.mkdirSync(directory);
    fs.writeFileSync(path.join(directory,'input.json'),JSON.stringify({stage,superseded,intentId:generation,intent,planPending:true}));
    const child=spawnSync(process.execPath,[import.meta.filename,'--child',directory],{env:{...process.env,AMCL_TEST_OUTPUT_DIR:directory},encoding:'utf8',timeout:30000});
    assert.equal(child.status,77,stage+' must exit at the real boundary\n'+child.stdout+'\n'+child.stderr);
    const checkpoint=JSON.parse(fs.readFileSync(path.join(directory,'checkpoint.json'),'utf8'));
    if(stage==='after-fence'&&!superseded)reference=checkpoint;
    const cold=await fixture({journal:checkpoint.journal,runtimePlanPending:checkpoint.planPending,initialFence:checkpoint.fence,initialIntent:checkpoint.intent,initialEnvironment:checkpoint.actual});
    assert.equal(cold.coordinator.storageBlocked,false,'valid cold terminal is never recast as corrupt storage');
    cold.storage.set('fixtureAppUpdateChannel',checkpoint.preference);cold.setObservation(terminal(checkpoint.journal));cold.coordinator.setAbilityForeground(true);
    cold.coordinator.recover(checkpoint.journal.installId,checkpoint.journal.restartNonce);for(let i=0;i<5;i++)await settle();
    await cold.coordinator.resumeVerifiedCompletion();for(let i=0;i<3;i++)await settle();
    const closed=cold.coordinator.state();assert.equal(closed.phase,superseded?'superseded':'verified',stage);assert.equal(closed.completion?.done,true,stage);
    assert.equal(cold.runtimePlanApi.pending(cold.context),false,stage);assert.equal(cold.coordinator.needsAttention(),false,stage);
    assert.equal(cold.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false,stage);assert.equal(cold.storage.get('fixtureAppUpdateChannel'),superseded?'preview':'stable',stage);
    const continued=JSON.parse(cold.kitfs.readTextSync('/sandbox/runtime-app-intent.json'));
    if(superseded){assert.equal(continued.completion,undefined);assert.equal(continued.phase,'complete');assert(continued.intents.every(item=>item.state==='cancelled'));assert.equal(cold.counters.planVerified??0,0);}
    else assert.equal(continued.completion.runtimeIntentId,generation,stage);
    assert.equal(continued.binding.transactionId,closed.id);assert.equal(cold.counters.dispatch,0);assert.equal(cold.counters.sign,0);
    const revision=closed.revision;await cold.coordinator.resumeVerifiedCompletion();assert.equal(cold.coordinator.state().revision,revision,'completed replay is idempotent');
    results.push({stage,superseded,passed:true,phase:closed.phase,done:closed.completion.done});cold.coordinator.setAbilityForeground(false);
  }
  for(const change of [{uid:43},{product:'desktop'},{payload:'e'.repeat(40)},{versionName:'different'}]){
    const cold=await fixture({journal:reference.journal,runtimePlanPending:true,initialIntent:reference.intent,initialEnvironment:{...actual,...change}});
    cold.setObservation(terminal(reference.journal));cold.coordinator.setAbilityForeground(true);await settle();
    await assert.rejects(cold.coordinator.resumeVerifiedCompletion());assert.equal(cold.coordinator.state().completion.done,false);
    assert.equal(cold.runtimePlanApi.pending(cold.context),true);assert.equal(cold.coordinator.needsAttention(),true);assert.equal(cold.counters.planVerified??0,0);cold.coordinator.setAbilityForeground(false);
  }
  {
    const cold=await fixture({journal:reference.journal,runtimePlanPending:true,initialIntent:reference.intent,initialEnvironment:actual});
    cold.setObservation({...terminal(reference.journal),code:5});cold.coordinator.setAbilityForeground(true);await settle();
    await assert.rejects(cold.coordinator.resumeVerifiedCompletion(),/终态/);assert.equal(cold.runtimePlanApi.pending(cold.context),true);cold.coordinator.setAbilityForeground(false);
  }
  pre.coordinator.setAbilityForeground(false);
  if(process.env.AMCL_TEST_OUTPUT_DIR)fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR,'app-completion-recovery-results.json'),JSON.stringify({passed:results.length,results},null,2)+'\n');
  console.log(JSON.stringify({passed:results.length,scope:'actual child process death and cold production Coordinator/intent files; platform effect ports mocked'},null,2));
}

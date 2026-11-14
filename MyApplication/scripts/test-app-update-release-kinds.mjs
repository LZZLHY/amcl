/**
 * 三类App发行的真实策略、官网精确原件和Coordinator集成回归。Kit、Java处理器、BMS
 * 与JDK跨域桥由既有受控夹具承接；不联网、不接真机，不把替身当成系统安装证据。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';
import { fixture, record, settle, target, payload } from './lib/sideload-coordinator-fixture.mjs';

/** 使用真实官网约定构造不可变开发原件；仅数据生成，不复制生产准入或恢复算法。 */
function developer(versionName='2.0.0-dev1') {
  const name='amcl-v'+versionName+'-sideload-unsigned.hap';
  const websiteUrl='https://amcl.lovedhy.cn/api/packages/files/'+target.sha256+'/'+name;
  return {...target,tag:'',versionName,name,url:websiteUrl,websiteUrl,releaseKind:'developer',source:'website-upload',
    artifactId:'website:dev1',baseStable:{tag:'v1.0.0',versionName:'1.0.0',versionCode:2}};
}
function candidate(asset) {return {...asset,updateChannel:'stable',delivery:{schema:1,ready:true,assets:[asset]}};}
{
  const f=await fixture(),{AppUpdatePolicy:p}=f.load('update/src/main/ets/AppUpdatePolicy.ets');
  assert.equal(p.releaseKind('2.0.0-dev1'),'developer');assert.equal(p.releaseKind('2.0.0-pre1'),'preview');
  for(const name of ['2.0.0-dev0','2.0.0-dev01','2.0.0-dev9007199254740992'])assert.equal(p.validVersion(name),false);
  assert.equal(p.accepts('v2.0.0-dev1','preview',true,'preview'),false);
  assert.equal(p.accepts('v2.0.0-dev1','stable',false,'stable'),false);
  assert.equal(p.compare('2.0.0-dev10','2.0.0-dev2')>0,true);
  assert.equal(p.compare('2.0.0-dev10','2.0.0-pre1'),0);
  assert.equal(p.validBaseline('2.0.0-dev1',2,'1.0.0',2),true);
  assert.equal(p.validBaseline('2.0.0-dev1',3,'1.0.0',2),false);
  assert.equal(p.validBaseline('1.0.0-dev1',2,'1.0.0',2),false);
  for(const [from,to,channel,manual,allowed] of [
    ['1.0.0','2.0.0-dev1','stable',false,false],['1.0.0','2.0.0-dev1','stable',true,true],
    ['2.0.0-pre2','2.0.0-dev1','preview',true,true],['3.0.0-pre1','2.0.0-dev2','preview',true,false],
    ['2.0.0-dev1','2.0.0-dev2','stable',true,true],['2.0.0-dev2','2.0.0-dev1','stable',true,false],
    ['2.0.0-dev2','2.0.0-dev2','stable',true,false],['2.0.0-dev2','1.0.0','stable',false,true],
    ['2.0.0-dev2','2.0.0-pre1','preview',false,true]])assert.equal(p.canInstall(2,from,2,to,channel,manual),allowed,from+'→'+to);
  assert.equal(p.canInstall(3,'2.0.0-dev1',2,'1.0.0','stable',true),false);
  f.coordinator.setAbilityForeground(false);
}
console.log('PASS release kinds: immutable same-code family, independent numeric dev sequence, explicit cross-type admission');

{
  const f=await fixture({candidate:candidate(developer())});
  const {AppArtifactReceiptResolver:r}=f.load('update/src/main/ets/AppArtifactReceiptResolver.ets');
  // 独立JSON收据负控直接执行生产解析器；完整集成在下方使用真实下载边界取得同形收据。
  const a=developer(),receipt={schema:1,kind:'app-artifact',verified:true,releaseKind:'developer',source:'website-upload',
    artifactId:'website:dev1',versionName:a.versionName,versionCode:a.versionCode,product:a.product,name:a.name,
    sha256:a.sha256,sizeBytes:a.sizeBytes,websiteUrl:a.websiteUrl,baseStable:a.baseStable,
    audit:{bundleName:'com.amcl.launcher',versionName:a.versionName,versionCode:a.versionCode,product:a.product,
      sourceRevision:payload,minApi:20,abi:'arm64-v8a',deviceTypes:['phone'],runtimeHostProtocols:[1]}};
  assert.equal(r.parse(JSON.stringify(receipt),'sideload',a.sha256).tag,'');
  for(const mutate of [
    v=>v.product='desktop',v=>v.sha256='f'.repeat(64),v=>v.source='github',v=>v.githubUrl='https://github.com/fake',
    v=>v.revoked=true,v=>v.revoked='false',v=>v.revoked=null,v=>v.revoked=0,v=>v.verified=false,v=>v.baseStable.versionCode=1,v=>v.baseStable.versionName='2.0.0',
    v=>v.audit.sourceRevision='',v=>v.audit.sourceRevision=[payload],v=>v.audit.runtimeHostProtocols=[0],v=>v.audit.runtimeHostProtocols=[1,1],
    v=>v.audit.runtimeHostProtocols=null,v=>v.audit.runtimeHostProtocols='1',v=>v.audit.runtimePlanProtocol=null,v=>v.audit.runtimePlanProtocol='0',
    v=>v.websiteUrl='https://amcl.lovedhy.cn/uploads/arbitrary.hap',v=>v.name='other.hap'
  ]) {const bad=structuredClone(receipt);mutate(bad);assert.throws(()=>r.parse(JSON.stringify(bad),'sideload',a.sha256));}
  assert.throws(()=>r.parse(JSON.stringify(receipt),'desktop',a.sha256));
  assert.throws(()=>r.url('sideload','../escape'));
  const missing=structuredClone(receipt);delete missing.audit.runtimeHostProtocols;delete missing.audit.runtimePlanProtocol;
  assert.equal(r.parse(JSON.stringify(missing),'sideload',a.sha256).runtimeHostProtocols.join(','),'1');
  assert.equal(r.parse(JSON.stringify(missing),'sideload',a.sha256).runtimePlanProtocol,0);
  const falseRevoked=structuredClone(receipt);falseRevoked.revoked=false;assert.equal(r.parse(JSON.stringify(falseRevoked),'sideload',a.sha256).sha256,a.sha256);
  const {GitHubUpdateAssetResolver:github}=f.load('update/src/main/ets/GitHubUpdateAssetResolver.ets');
  for(const protocol of [0,1,2]){const value=structuredClone(receipt);value.audit.runtimePlanProtocol=protocol;
    assert.equal(r.parse(JSON.stringify(value),'sideload',a.sha256).runtimePlanProtocol,protocol);
    assert.equal(github.fromDelivery(candidate({...target,runtimePlanProtocol:protocol}),'sideload').runtimePlanProtocol,protocol);}
  const future=structuredClone(receipt);future.audit.runtimePlanProtocol=3;assert.throws(()=>r.parse(JSON.stringify(future),'sideload',a.sha256));
  assert.throws(()=>github.fromDelivery(candidate({...target,runtimePlanProtocol:3}),'sideload'));
  for(const field of ['runtimeHostProtocols','runtimePlanProtocol']) {
    const bad=candidate({...target,[field]:null});assert.throws(()=>github.fromDelivery(bad,'sideload'));
  }
  assert.throws(()=>github.fromDelivery(candidate({...target,sha256:[target.sha256]}),'sideload'));
  const {SideloadTransactionPolicy:transactionPolicy}=f.load('update/src/main/ets/SideloadTransactionPolicy.ets');
  for(const protocol of [0,1,2,3]){const value=record('downloaded');value.asset.runtimePlanProtocol=protocol;
    assert.equal(transactionPolicy.validate(value,'/sandbox/sideload-update'),protocol<3);}
  for(const field of ['runtimeHostProtocols','runtimePlanProtocol']) {
    const bad=record('downloaded');bad.asset[field]=null;assert.equal(transactionPolicy.validate(bad,'/sandbox/sideload-update'),false);
  }
  // 此JSON由官网实际hapFixture→HAP审计→HTTP原件收据链产生，双方各自仓库保留同字节样本，
  // CI无需读取维护者旁仓；客户端生产解析器必须消费该真实服务端输出，而不是只测自造DTO。
  const web=JSON.parse(fs.readFileSync(path.join(import.meta.dirname,'fixtures/app-artifact-developer.json'),'utf8'));
  const parsed=r.parse(JSON.stringify(web),'sideload',web.sha256);
  assert.equal(parsed.versionName,'1.0.7-dev1');assert.equal(parsed.runtimeHostProtocols.join(','),'1');
  assert.equal(parsed.artifactId,'developer-fixture');
  f.coordinator.setAbilityForeground(false);
}
console.log('PASS artifact receipts: exact product/hash, audited HAP, immutable baseline, withdrawn and forged source rejection');

{
  const f=await fixture();f.environment.versionName='2.0.0-dev1';
  const {UpdateChecker:c}=f.load('update/src/main/ets/UpdateChecker.ets');
  const before=f.counters.fetch??0;
  assert.equal((await c.checkForUpdate(['https://fixture.invalid/manifest'],'sideload','stable')).hasUpdate,false);
  assert.equal(f.counters.fetch??0,before,'developer default must not fetch any update head');
  assert.equal(c.hasCachedUpdate(1,2,'2.0.0-dev1','2.0.0','stable'),false);
  assert.equal(c.supportsHost(candidate(target),'sideload',1),true);
  assert.equal(c.supportsHost(candidate(target),'sideload',2),false);
  const explicit=candidate({...target,runtimeHostProtocols:[1,2]});
  assert.equal(c.supportsHost(explicit,'sideload',2),true);
  await c.checkForUpdate(['https://fixture.invalid/manifest'],'sideload','stable',true);
  assert((f.counters.fetch??0)>before,'explicit exit is the only public-head request');
  f.coordinator.setAbilityForeground(false);
}
console.log('PASS installed developer: auto request and cached red-dot stop; explicit exit alone reads a public target');

for(const before of ['1.0.0','2.0.0-pre1','2.0.0-dev1']) {
  const a=developer(before.includes('dev')?'2.0.0-dev2':'2.0.0-dev1'),f=await fixture({candidate:candidate(a)});
  f.environment.version=2;f.environment.versionName=before;
  assert.equal(f.coordinator.requestUpdate({manifest:candidate(a),autoStart:true}),'rejected','route cannot manufacture manual intent');
  fs.writeFileSync(f.mapped('/sandbox/developer.hap'),'unsigned candidate fixture');
  const prepared=await f.coordinator.preparePickedPackage('/sandbox/developer.hap','stable');
  const {SideloadUpdateViewModel:ViewModel}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const ui=new ViewModel();ui.initialize(f.context,{manifest:prepared.manifest,importToken:prepared.token,autoStart:true});
  f.coordinator.setAbilityForeground(true);ui.onForeground();ui.onShown();await settle();
  assert.equal(f.counters.download,0);assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);
  assert(f.counters.planPrepared>=1);assert(f.counters.planRestored>=1,'restore bridge executes before bm under existing fence');
  const task=f.coordinator.state();assert.equal(task.asset.releaseKind,'developer');assert.equal(task.asset.tag,'');
  f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'fixture terminal',installId:task.installId,nonce:task.restartNonce});
  f.environment.payload=payload;f.coordinator.recover(task.installId,task.restartNonce);await settle();
  assert.notEqual(f.coordinator.state().phase,'verified','same code plus old name cannot confirm');
  f.environment.versionName=a.versionName;f.coordinator.recover();await settle();
  assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.counters.planVerified,1);
  assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false);
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
console.log('PASS manual developer: official local original only, same pipeline, plan bridge, real-name/BMS double proof and fence closure');

{
  const name='amcl-v1.0.0-sideload-unsigned.hap',asset={...target,tag:'v1.0.0',versionName:'1.0.0',name,
    url:'https://github.com/LZZLHY/amcl/releases/download/v1.0.0/'+name,
    websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+target.sha256+'/'+name,
    mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/v1.0.0/'+name}]};
  const f=await fixture({candidate:candidate(asset)});f.environment.version=2;f.environment.versionName='2.0.0-dev1';
  f.storage.set('fixtureAppUpdateChannel','preview');
  const ui=f.render();await settle();assert.equal(f.counters.dispatch,1,JSON.stringify(f.coordinator.snapshot()));
  assert.equal(f.storage.get('fixtureAppUpdateChannel'),'preview','unconfirmed return cannot commit a new subscription');
  const task=f.coordinator.state();f.environment.payload=payload;f.environment.versionName='1.0.0';
  f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'fixture terminal',installId:task.installId,nonce:task.restartNonce});
  f.coordinator.recover();await settle();
  assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.storage.get('fixtureAppUpdateChannel'),'stable');
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
console.log('PASS developer exit: original subscription stays during pending; actual target identity and BMS proof commit the explicit destination');

{
  // 推荐声称支持协议2，实际HAP仅支持1：必须在真正签名和bm之前被包内检查拒绝。
  const f=await fixture({candidate:candidate({...target,runtimeHostProtocols:[1,2]})});
  const {SideloadUpdateViewModel:ViewModel}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const ui=new ViewModel();ui.initialize(f.context,{manifest:candidate({...target,runtimeHostProtocols:[1,2]}),autoStart:true,requiredHostProtocol:2});
  f.coordinator.setAbilityForeground(true);ui.onForeground();ui.onShown();await settle();
  assert.equal(f.counters.sign,0);assert.equal(f.counters.dispatch,0);
  assert.match(f.coordinator.snapshot().message,/实际不支持/);
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
console.log('PASS JDK dependency: compatible recommendation filter and actual-HAP protocol proof before signing/installing');

{
  const f=await fixture({usableSigningJdks:[]});
  assert.equal(f.kitfs.accessSync('/sandbox/jdk/17/lib/server/libjvm.so'),true,'file presence is deliberately insufficient');
  const ui=f.render();await settle();assert.equal(f.counters.sign,0);assert.equal(f.counters.dispatch,0);
  assert(f.counters.jdkEligibilityChecks>=3);assert.match(f.coordinator.snapshot().message,/JDK 17/);
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
console.log('PASS signing JDK eligibility: physical libjvm alone cannot bypass the manager host/structure decision');

{
  // 直接提取真实页面业务方法，平台只提供router和偏好。不能只在测试里重写“退出dev”规则。
  const source=fs.readFileSync(new URL('../entry/src/main/ets/pages/SoftwareUpdatePage.ets',import.meta.url),'utf8');
  const ast=compiler.createSourceFile('SoftwareUpdatePage.ets',source,compiler.ScriptTarget.Latest,true);
  const component=ast.statements.find(node=>node.name?.getText(ast)==='SoftwareUpdatePage');
  const methods=['chooseChannel','syncConfirmedChannel','exitDeveloper','check','startUpdate'].map(name=>{
    const member=component?.members?.find(node=>node.name?.getText(ast)===name);assert(member,'real page method '+name);return member.getText(ast);
  }).join('\n');
  const f=await fixture(),{UpdateChecker:c}=f.load('update/src/main/ets/UpdateChecker.ets');f.environment.versionName='2.0.0-dev1';
  const routes=[],preferences={appUpdateChannel:'preview',async selectAppUpdateChannel(value){this.appUpdateChannel=value;},resetAppUpdateCheck(){},rememberAppUpdate(){throw Error('developer must not write recommendation cache');}};
  const exported={};
  const js=compiler.transpileModule('class PageHarness {\n'+methods+'\n}\nexports.PageHarness=PageHarness;',{
    compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  vm.runInNewContext(js,{exports:exported,UpdateChecker:{
    checkForUpdate:(_urls,product,channel,exit)=>c.checkForUpdate(['https://fixture.invalid/manifest'],product,channel,exit),
    supportsHosts:c.supportsHosts,canInstall:c.canInstall,isStableReturn:c.isStableReturn,targetKey:c.targetKey},
    DistributionPolicy:{isStore:()=>false},ProductBuildProfile:{product:'sideload'},Number,Array,JSON});
  const page=new exported.PageHarness();Object.assign(page,{preferences,channel:'preview',candidate:undefined,
    generation:0,channelSelectionGeneration:0,visible:true,importing:false,checking:false,developerInstalled:true,developerExitRequested:false,
    requirementValid:true,requiredHostProtocol:1,requiredHostProtocols:[1],getUIContext:()=>({getRouter:()=>({pushUrl:value=>{routes.push(value);return Promise.resolve();}})})});
  await page.check();assert.equal(f.counters.fetch??0,0);
  page.exitDeveloper('stable');await settle();assert((f.counters.fetch??0)>0);assert(page.candidate);
  assert.equal(preferences.appUpdateChannel,'preview','destination remains uncommitted while update has not succeeded');
  page.startUpdate();assert.equal(routes.length,1);assert.equal(routes[0].params.requiredHostProtocols.join(','),'1');
  page.requiredHostProtocols=[1,2];await page.check();assert.equal(page.candidate,undefined);assert.match(page.status,/尚无支持/);
  const prior=f.counters.fetch;page.chooseChannel('preview');await settle();assert.equal(f.counters.fetch,prior,'plain subscription choice in developer does not fetch');
  f.coordinator.setAbilityForeground(false);
}
console.log('PASS SoftwareUpdatePage: real explicit-exit commands, no dev cache/head side effects, complete JDK requirement filter and route propagation');

for(const options of [{runtimePlanPending:true},{runtimePlanUnreadable:true}]) {
  const original=record('downloaded'),f=await fixture({journal:original,...options});
  const changed=candidate({...target,sha256:'f'.repeat(64),websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+'f'.repeat(64)+'/'+target.name});
  assert.equal(f.coordinator.requestUpdate({manifest:changed,autoStart:true}),'rejected');
  assert.equal(f.coordinator.state().id,original.id);assert.equal(f.coordinator.state().asset.sha256,original.asset.sha256);
  assert.equal(f.counters.download,0);assert.equal(f.counters.dispatch,0);f.coordinator.setAbilityForeground(false);
}
console.log('PASS pending compatibility plan: unreadable or different-target requests preserve the original app transaction and never start a new effect');

{
  // 单槽journal的真实rename恢复由JDK域验证；这里将“恢复前不可选签名JDK”作为明确跨域
  // 边界，证明真实Coordinator先以原owner调用早恢复，再选JDK/inspect/签名/安装。
  const original={...record('failed'),asset:{...target},beforeVersionCode:1,beforeVersionName:'1.0.0',updateChannel:'stable'},
    f=await fixture({journal:original,runtimePlanPending:true,signingJdkNeedsPlanRecovery:true});
  const ui=f.render();await settle();assert.equal(f.coordinator.state().id,original.id);
  assert.equal(f.counters.planRecoveryOwner,original.id);assert(f.counters.planRecovery>0);
  assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
console.log('PASS early signing recovery: same-HAP retry retains original owner and recovers pending slots before choosing the signing JDK');

for(const proofKind of ['pre-install-failed','revoked','']) {
  // 真实Coordinator推进到restore；JDK边界模拟已进入restoring但在第一槽切换前因撤回失败。
  // 只替换执行器的独立结构化证据，不能靠页面phase/throw本身推断系统从未执行。
  const f=await fixture({runtimeRestoreFailure:'准备的兼容JDK已被撤回，尚未切换首槽',revokeProofKind:proofKind});
  const ui=f.render();await settle();const original=f.coordinator.state();
  assert.equal(f.counters.dispatch,0);
  if(proofKind) {
    assert.equal(original.phase,'failed');assert.equal(f.counters.planNoInvocationCancelled,1);
    assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false);
    assert.equal(f.coordinator.requestCancel(original.ownerAttemptId),true,'explicit cancellation is available');
    const tag='v3.0.0',name='amcl-'+tag+'-sideload-unsigned.hap',hash='f'.repeat(64),next={...target,tag,versionName:'3.0.0',versionCode:3,name,sha256:hash,
      url:'https://github.com/LZZLHY/amcl/releases/download/'+tag+'/'+name,websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+hash+'/'+name,
      mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/'+tag+'/'+name}]};
    assert.equal(f.coordinator.requestUpdate({manifest:candidate(next),autoStart:true}),'started','new explicit target is no longer blocked by an unchanged failed plan');
    f.coordinator.cancel(); // 只核新目标准入；此用例不消费另一个包的模拟下载/元数据。
  } else {
    assert.equal(original.phase,'confirmation-pending');assert.equal(f.counters.planNoInvocationCancelled??0,0);
    assert.equal(f.counters.complete??0,0);assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),true);
    assert.equal(f.coordinator.requestCancel(original.ownerAttemptId),false,'unknown outcome cannot acquire cancellation authority');
  }
  ui.dispose();f.coordinator.setAbilityForeground(false);
}
{
  const original={...record('confirmation-pending'),installProtocol:2,installId:'e'.repeat(32)},
    f=await fixture({journal:original,runtimePlanPending:true,revokeProofKind:'pre-install-failed'});
  f.coordinator.setAbilityForeground(true);await f.coordinator.reconcile();
  assert.equal(f.coordinator.state().phase,'failed');assert.equal(f.counters.planNoInvocationCancelled,1);
  assert.equal(f.counters.dispatch,0);f.coordinator.setAbilityForeground(false);
}
console.log('PASS NoInvocation plan closure: pre-first-slot failure and trusted revoke release unchanged plan; unknown outcome retains fence; cold reconcile uses the same authority');

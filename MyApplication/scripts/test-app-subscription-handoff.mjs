/** 真实Preferences owner/CAS、Coordinator和页面选择链：一次flush失败不能让旧完成回放覆盖后来选择。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {fixture,record,target,payload,settle,deferred} from './lib/sideload-coordinator-fixture.mjs';
function preferences(){
  const values=new Map([['appUpdateChannel','stable'],['appUpdateChannelRevision',0]]);let persisted=new Map(values),failures=0,gate;
  const calls=[];
  const store={getSync:(key,fallback)=>values.has(key)?values.get(key):fallback,putSync:(key,value)=>values.set(key,value),
    async flush(){calls.push([...values]);if(failures>0){failures--;throw Error('controlled Preferences.flush');}if(gate)await gate.promise;persisted=new Map(values);}};
  const load=makePureEtsLoader({commons:{ProcessPreferences:{open:()=>store,isGameProcess:()=>false}},'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}});
  const Manager=load('feature_system/src/main/ets/PreferenceManager.ets').PreferenceManager;
  return {Manager,values,calls,persisted:()=>persisted,fail(count){failures=count;},gate(value){gate=value;}};
}
{
  const p=preferences(),old=record('confirmation-pending');Object.assign(old,{schema:2,revision:1,ownerAttemptId:old.id,
    installProtocol:2,installId:'a'.repeat(32),asset:{...target},beforeVersionCode:1,beforeVersionName:'3.0.0-dev1',updateChannel:'preview',
    installedIdentityVerified:true,subscriptionRevision:0,confirmedAt:Date.now()});
  const f=await fixture({journal:old,preferenceFactory:p.Manager,initialEnvironment:{version:2,versionName:'2.0.0',payload,uid:42}});
  p.fail(1);f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'trusted platform fixture',installId:old.installId,nonce:old.restartNonce});
  f.coordinator.setAbilityForeground(true);f.coordinator.recover(old.installId,old.restartNonce);for(let i=0;i<3;i++)await settle();
  assert.equal(f.coordinator.state().completion.subscriptionCommitted,false);assert.equal(f.coordinator.needsAttention(),true);
  assert.equal(new p.Manager(f.context).appUpdateChannel,'stable','failed completion flush exposes confirmed rollback, not in-flight cache');
  const source=fs.readFileSync(new URL('../entry/src/main/ets/pages/SoftwareUpdatePage.ets',import.meta.url),'utf8'),ast=compiler.createSourceFile('SoftwareUpdatePage.ets',source,compiler.ScriptTarget.Latest,true);
  const node=ast.statements.find(n=>n.name?.getText(ast)==='SoftwareUpdatePage'),method=['chooseChannel','syncConfirmedChannel'].map(name=>node.members.find(n=>n.name?.getText(ast)===name).getText(ast)).join('\n');
  const js=compiler.transpileModule('class Page {'+method+'}\nexports.Page=Page;',{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const exported={};vm.runInNewContext(js,{exports:exported,DistributionPolicy:{isStore:()=>false},ProductBuildProfile:{product:'sideload'}});
  const page=new exported.Page();Object.assign(page,{preferences:new p.Manager(f.context),channel:'stable',generation:0,channelSelectionGeneration:0,importing:false,checking:false,developerInstalled:false,check(){}});
  await page.chooseChannel('stable');assert.equal(p.values.get('appUpdateChannelRevision'),1,'explicit reaffirmation also supersedes the old completion');
  assert.equal(p.persisted().get('appUpdateChannel'),'stable');assert.equal(p.persisted().get('appUpdateChannelRevision'),1);
  await f.coordinator.reconcileInstallation(false);await settle();
  assert.equal(f.coordinator.state().completion.done,true);assert.equal(f.coordinator.state().completion.subscriptionResult,'newer-selection-or-legacy');
  assert.equal(p.persisted().get('appUpdateChannel'),'stable');f.coordinator.setAbilityForeground(false);
}
{
  const p=preferences(),context={preferencesDir:'/serial-subscription'},first=new p.Manager(context),second=new p.Manager(context),gate=deferred();
  p.gate(gate);const old=first.commitAppUpdateChannel('preview',0);for(let i=0;i<3;i++)await Promise.resolve();
  assert.equal(first.appUpdateChannel,'stable','pending automatic write is not a confirmed setting');
  const later=second.selectAppUpdateChannel('stable');gate.resolve();p.gate(undefined);await Promise.all([old,later]);
  assert.equal(p.persisted().get('appUpdateChannel'),'stable');assert.equal(p.persisted().get('appUpdateChannelRevision'),1);
  assert.equal(await first.commitAppUpdateChannel('preview',0),false);assert.equal(await first.commitAppUpdateChannel('preview'),false,'old journal cannot manufacture a revision');
  assert.equal(p.persisted().get('appUpdateChannel'),'stable');
}
{
  const p=preferences(),manager=new p.Manager({preferencesDir:'/rollback-subscription'});p.fail(2);
  await assert.rejects(manager.commitAppUpdateChannel('preview',0),/回滚/);assert.equal(manager.appUpdateChannel,'stable');
  await manager.selectAppUpdateChannel('stable');assert.equal(await manager.commitAppUpdateChannel('preview',0),false);
  assert.equal(p.persisted().get('appUpdateChannel'),'stable');
}
{
  const p=preferences(),manager=new p.Manager({preferencesDir:'/failed-choice-subscription'});p.fail(1);
  await assert.rejects(manager.selectAppUpdateChannel('preview'),/未保存/);
  assert.equal(manager.appUpdateSelectionRevision(),0,'confirmed rollback does not manufacture a later user revision');
  assert.equal(await manager.commitAppUpdateChannel('preview',manager.appUpdateSelectionRevision()),true,'a new explicit App exit can still commit against its confirmed baseline');
  assert.equal(p.persisted().get('appUpdateChannel'),'preview');
  const gate=deferred();p.gate(gate);const inFlight=manager.selectAppUpdateChannel('stable');
  assert.throws(()=>manager.appUpdateSelectionRevision(),/尚未确认/,'new transaction must not freeze an unconfirmed user selection');
  gate.resolve();p.gate(undefined);await inFlight;assert.equal(manager.appUpdateSelectionRevision(),1);
}
{
  const p=preferences(),manager=new p.Manager({preferencesDir:'/hide-show-subscription'}),gate=deferred();p.gate(gate);
  const source=fs.readFileSync(new URL('../entry/src/main/ets/pages/SoftwareUpdatePage.ets',import.meta.url),'utf8'),ast=compiler.createSourceFile('SoftwareUpdatePage.ets',source,compiler.ScriptTarget.Latest,true);
  const node=ast.statements.find(n=>n.name?.getText(ast)==='SoftwareUpdatePage');
  const methods=['chooseChannel','syncConfirmedChannel','onPageShow','onPageHide'].map(name=>node.members.find(n=>n.name?.getText(ast)===name).getText(ast)).join('\n');
  const js=compiler.transpileModule('class Page {'+methods+'}\nexports.Page=Page;',{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const exported={};vm.runInNewContext(js,{exports:exported,DistributionPolicy:{isStore:()=>false},ProductBuildProfile:{product:'sideload'},UpdateChecker:{automaticAllowed:()=>true},SideloadUpdateService:{get:()=>({needsAttention:()=>false})}});
  const page=new exported.Page();Object.assign(page,{preferences:manager,context:{},channel:'stable',generation:0,channelSelectionGeneration:0,visible:true,importing:false,checking:false,developerInstalled:false,developerExitRequested:false,check(){},applyTheme(){}});
  const choosing=page.chooseChannel('preview');for(let i=0;i<3;i++)await Promise.resolve();page.onPageHide();page.onPageShow();
  assert.equal(page.channel,'stable','return before flush still exposes only confirmed baseline');gate.resolve();p.gate(undefined);await choosing;
  assert.equal(page.channel,'preview','flush after route generation change still refreshes confirmed local channel');
  page.onPageHide();page.channel='stable';page.onPageShow();assert.equal(page.channel,'preview');
  page.developerInstalled=true;page.developerExitRequested=true;page.channel='stable';page.syncConfirmedChannel();assert.equal(page.channel,'stable','explicit developer exit candidate is not reset by unrelated page projection');
  const devGate=deferred();p.gate(devGate);const devChoice=page.chooseChannel('preview');for(let i=0;i<3;i++)await Promise.resolve();
  page.onPageHide();page.developerInstalled=true;page.syncConfirmedChannel();assert.equal(page.channel,'stable');
  devGate.resolve();p.gate(undefined);await devChoice;
  assert.equal(page.channel,'preview','later explicit persisted choice supersedes the old developer exit local target across hide');
}
console.log('PASS subscription handoff: flush/rollback and later choice CAS, durable serial value+revision, failed choice repair, hide/show projection and developer exit preservation');

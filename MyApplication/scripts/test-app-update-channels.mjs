/** 执行真实通道策略、偏好及导入/恢复协调器；平台文件与账号替身均受现有沙箱夹具约束。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { fixture,record,settle,target,payload } from './lib/sideload-coordinator-fixture.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
function load(file,dependencies={}) {
  const exports={};const js=compiler.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  vm.runInNewContext(js,{exports,require:name=>{if(!(name in dependencies))throw Error('Unmocked '+name);return dependencies[name];},console,Map,Date,Number,RegExp,JSON,Promise});return exports;
}
const {AppUpdatePolicy:policy}=load('update/src/main/ets/AppUpdatePolicy.ets');
assert.equal(policy.accepts('v2.0.0',undefined,undefined,'stable'),true);
assert.equal(policy.accepts('v2.0.0-beta.1',undefined,undefined,'stable'),false);
assert.equal(policy.accepts('v2.0.0-beta.1','preview',true,'preview'),true);
assert.equal(policy.accepts('v2.0.0-beta.1','stable',false,'stable'),false);
assert.equal(policy.accepts('v2.0.0',undefined,false,'preview'),false);
assert.equal(policy.accepts('v2.0.0','preview',false,'preview'),true);
assert(policy.urls('desktop','preview').every(url=>url.includes('/desktop/preview.json')));
// 用户指定的新命名按数字排序；旧历史可读，歧义/非法编号不进入同 code 安装。
assert.equal(policy.accepts('v1.0.6-pre1','preview',true,'preview'),true);
assert.equal(policy.accepts('v1.0.6-pre1','stable',false,'stable'),false);
assert(policy.compare('1.0.6-pre10','1.0.6-pre2')>0);
assert(policy.compare('1.0.6','1.0.6-pre10')>0);
for(const name of ['1.0.6-pre0','1.0.6-pre01','1.0.6-pre-1','1.0.6-pre9007199254740992'])assert.equal(policy.validVersion(name),false);
for(const [from,to,channel,allowed] of [
 ['1.0.5','1.0.6-pre1','preview',true],['1.0.6-pre1','1.0.6-pre2','preview',true],
 ['1.0.6-pre2','1.0.6-pre1','preview',false],['1.0.6-pre2','1.0.5','stable',true],
 ['1.0.6-pre2','1.0.5','preview',false],['1.0.5','1.0.6','stable',false],
 ['1.0.6-pre1','1.0.6-pre1','preview',false]])assert.equal(policy.canInstall(100,from,100,to,channel),allowed);
assert.equal(policy.canInstall(101,'1.0.6-pre1',100,'1.0.5','stable'),false);

// 使用真实PreferenceManager方法，只替代平台Preferences对象。
const values=new Map(),store={getSync:(key,fallback)=>values.has(key)?values.get(key):fallback,putSync:(key,value)=>values.set(key,value),flush:()=>Promise.resolve()};
const {PreferenceManager}=load('feature_system/src/main/ets/PreferenceManager.ets',{commons:{ProcessPreferences:{open:()=>store,isGameProcess:()=>false}},'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}});
const preferences=new PreferenceManager({preferencesDir:'/fixture'});
assert.equal(preferences.appUpdateChannel,'stable');preferences.jdkChannel='preview';assert.equal(preferences.appUpdateChannel,'stable');
preferences.rememberAppUpdate('sideload','stable',10,'v10:a');preferences.deferAppUpdate('sideload','stable','v10:a');
assert(preferences.appUpdateDeferredAt('sideload','stable')>0);
assert.equal(preferences.appUpdateLatestSeen('sideload','preview'),0);assert.equal(preferences.appUpdateLatestSeen('desktop','stable'),0);
preferences.rememberAppUpdate('sideload','stable',11,'v11:b');assert.equal(preferences.appUpdateDeferredAt('sideload','stable'),0);
preferences.deferAppUpdate('sideload','stable','v10:a');assert.equal(preferences.appUpdateDeferredAt('sideload','stable'),0);
preferences.appUpdateChannel='preview';preferences.rememberAppUpdate('sideload','preview',20,'beta');preferences.appUpdateChannel='stable';
assert.equal(preferences.appUpdateLatestSeen('sideload','stable'),11);assert.equal(preferences.appUpdateLatestSeen('sideload','preview'),20);
console.log('PASS App channels: legacy stable, explicit preview, stable convergence, product/cache/deferred identity isolation');

for(const tamper of [false,true]) {
  const f=await fixture();const picked='/sandbox/picked.hap';fs.writeFileSync(f.mapped(picked),'unsigned candidate fixture');
  const prepared=await f.coordinator.preparePickedPackage(picked,'stable');
  assert.equal(f.counters.download,0);assert.equal(f.counters.sign,0);assert.equal(f.counters.dispatch,0);
  if(tamper)fs.writeFileSync(f.mapped('/sandbox/sideload-update/imports/'+prepared.token+'/candidate.hap'),'bad candidate');
  const {SideloadUpdateViewModel:ViewModel}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const ui=new ViewModel();ui.initialize(f.context,{manifest:prepared.manifest,importToken:prepared.token,autoStart:true});
  f.coordinator.setAbilityForeground(true);ui.onForeground();ui.onShown();await settle();
  assert.equal(f.counters.download,0);
  assert.equal(f.counters.dispatch,tamper?0:1);assert.equal(f.counters.sign,tamper?0:1);
  if(tamper)assert.equal(ui.phase,'failed');ui.dispose();f.coordinator.setAbilityForeground(false);
}
{
  const f=await fixture();fs.writeFileSync(f.mapped('/sandbox/wrong.hap'),'different unsigned bytes');
  await assert.rejects(f.coordinator.preparePickedPackage('/sandbox/wrong.hap','stable'),/摘要/);
  assert.equal(f.counters.sign,0);assert.equal(f.counters.dispatch,0);
}
console.log('PASS manual import: same installation owner without download; bad bytes and post-check corruption never sign/install');
{
  const f=await fixture({journal:record('installing')});f.coordinator.setAbilityForeground(true);
  await new Promise(resolve=>setTimeout(resolve,1150));
  assert(f.counters.observe>0);assert.equal(f.counters.revoke,0);assert.equal(f.counters.dispatch,0);
  f.coordinator.setAbilityForeground(false);const count=f.counters.observe;
  await new Promise(resolve=>setTimeout(resolve,30));assert.equal(f.counters.observe,count);
}
console.log('PASS automatic recovery: pending results are observed without revoke or repeat install; background stops scheduling');

/** 同 code 的真实协调器回归：下载、签名和派发次数不变；旧进程即使载荷/nonce匹配也不能成功。 */
for(const [before,next,channel] of [['1.0.5','1.0.6-pre1','preview'],['1.0.6-pre1','1.0.6-pre2','preview'],['1.0.6-pre2','1.0.5','stable']]) {
 const tag='v'+next,name='amcl-'+tag+'-sideload-unsigned.hap';
 const asset={...target,tag,versionName:next,versionCode:100,name,url:'https://github.com/LZZLHY/amcl/releases/download/'+tag+'/'+name,
  websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+target.sha256+'/'+name,mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/'+tag+'/'+name}]};
 const candidate={...asset,updateChannel:channel,prerelease:next.includes('-'),delivery:{schema:1,ready:true,assets:[asset]}};
 const f=await fixture({candidate});f.environment.version=100;f.environment.versionName=before;
 const {UpdateChecker}=f.load('update/src/main/ets/UpdateChecker.ets');
 const checked=await UpdateChecker.checkForUpdate(['https://fixture.invalid/manifest'],'sideload',channel);
 assert.equal(checked.hasUpdate,true);assert.equal(UpdateChecker.hasCachedUpdate(100,100,before,next,channel),true);
 const ui=f.render();await settle();assert.equal(f.counters.dispatch,1);assert.equal(f.counters.sign,1);assert.equal(f.counters.download,1);
 const task=f.coordinator.state();assert.equal(task.sameVersionTest,false);assert.equal(task.beforeVersionName,before);
 f.environment.payload=payload;
 f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'trusted fixture terminal',installId:task.installId,nonce:task.restartNonce});
 f.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.notEqual(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),true);
 f.environment.versionName=next;f.coordinator.recover();await settle();
 assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false);
 assert.equal(f.counters.dispatch,1);assert.equal(UpdateChecker.hasCachedUpdate(100,100,next,next,channel),false);ui.dispose();
}
console.log('PASS equal code: stable→pre1→pre2 and preview→stable use production admission; old versionName never confirms installation');
